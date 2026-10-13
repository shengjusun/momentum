/**
 * 云端同步编排服务（统一 merge 模型）
 *
 * @description
 *   本服务是**唯一**的云端同步出口：所有入口（自动防抖 / 立即同步 / 冷启动 / 登录 /
 *   热启动 / 切前台 / 开启开关 / 登出预上传）都必须调用 `requestMerge`，
 *   禁止任何绕过同步锁的裸 upload / download。
 *
 * 单条记录模型（不变）：
 *   云端每用户一条 `UserSyncData`（主键 uid），4 个 Text 字段整包 JSON + updatedAt。
 *
 * 统一 merge 流程（每次同步完全一致，无方向分叉）：
 *   1. 就绪 gate：CloudDB 已初始化 + 本地快照已就绪（否则保留脏标记退出，不发任何网络请求）
 *   2. 拉取云端完整记录（查询失败 ≠ 云端无数据，按失败处理并保留脏标记）
 *   3. 顶层 goals / taskList 做条目级并集合并：
 *      - 同 id 两端都存在：对比条目 updatedAt，值大者胜出；缺失则用 createTime 兜底；
 *        **完全相等或双方都缺失 → 本地优先**；墓碑 OR（任一方 isDeleted=true 结果即为 true）
 *      - 仅一端存在：保留该端条目
 *      - 里程碑 / L2 任务 / L3 步骤**不递归合并**，整块跟随所属目标
 *   4. **先落地合并结果**（统一顺序，覆盖"无需上传"分支也要落地）
 *   5. hash 指纹对比「合并结果 × 云端原始数据包」（canonical JSON，免疫键序差异）
 *      - 不相等 → 云端 upsert
 *      - 相等 → 云端已是最新，不上传
 *   6. 收尾：
 *      - 上传成功 → 水位 = 本次真正写入云端的 updatedAt；由调用方清除持久化脏标记
 *      - 无需上传 → 水位 = 云端当前 updatedAt（推进水位，避免每次重复 merge）；同样算同步成功
 *      - 上传失败 / 拉取失败 / 解析失败 → **水位不变 + 保留脏标记**，等下次重试
 *
 * 水位（lastSyncTime）语义：
 *   - 本机专属游标，**仅持久保存在本机**，绝不进入 4 段 JSON 载荷
 *   - 判据用**等值**（云端 updatedAt !== 水位？）而非大小比较，天然免疫跨设备时钟偏差
 *
 * 并发模型：
 *   同步锁 isSyncing + **单槽 pending 去重**。同步运行期间的新请求不丢弃，
 *   只置 pending 标记；本轮结束后自动补跑一次（用最新的本地快照）。
 *
 * 落地语义（⚠️ 必须遵守，否则出现反复上传 / 死循环）：
 *   - 落地期间**不得改写条目 updatedAt**（否则伪造"本机更新"→ 指纹永不相等）
 *   - 落地期间**不得打 SYNC_NEEDED 脏标记**（否则 merge → 落地 → 触发 → merge 死循环）
 */

import { CloudDBService, UserSyncRecord } from './CloudDBService'
import { Logger } from '../utils/Logger'
import { common } from '@kit.AbilityKit'

/** 本次同步的最终结局（调用方据此决定"是否清脏标记 / 是否提示用户"） */
export type SyncOutcome =
  /** 合并完成且与云端达成一致（可能上传过，也可能无需上传）→ 清除持久化脏标记 */
  'ok' |
  /** 就绪 gate 未通过（CloudDB 未初始化 / 本地快照未就绪）→ 保留脏标记，就绪后补触发 */
  'not_ready' |
  /** 拉取云端失败（网络 / 权限 / 对象类型未部署）→ 保留脏标记 + 提示用户 */
  'pull_failed' |
  /** 上传失败 → 保留脏标记 + 提示用户 */
  'upload_failed' |
  /** 云端数据解析失败（本地未被修改）→ 保留脏标记 + 提示用户 */
  'parse_failed' |
  /** 无意义调用（uid 为空）→ 不提示、保留脏标记 */
  'idle'

export interface SyncResult {
  outcome: SyncOutcome
  /** 本轮是否真正发起过云端上传 */
  uploaded: boolean
  /** 本轮结束后应写入本机的水位（0 表示水位保持不变） */
  lastSyncTime: number
  /** 失败原因（仅用于日志 / 兜底提示） */
  errorMsg: string
}

/**
 * 本地数据包
 * ⚠️ `lastSyncTime` 是本机水位游标，**只作为本地载体传递**，
 *    绝不写进 goalsJson / todosJson / settingsJson / profileJson 任何一段载荷。
 */
export interface SyncDataBundle {
  goalsJson: string
  todosJson: string
  settingsJson: string
  profileJson: string
  lastSyncTime: number
  /**
   * 本地是否存在尚未成功上传的改动（持久化脏标记 SYNC_NEEDED 的运行时值）
   * 准入判据之一：`(云端 updatedAt !== lastSyncTime) || dirty` 才需要执行合并
   */
  dirty: boolean
}

/** 本地快照提供者：在"真正执行 merge 的那一刻"取最新快照（pending 补跑时必须重新取） */
export type SyncDataProvider = () => SyncDataBundle

export interface SyncApplyCallback {
  applyGoals: (data: Record<string, Object>) => void
  applyTodos: (data: Record<string, Object>) => void
  applySettings: (data: Record<string, Object>) => void
  applyProfile: (data: Record<string, Object>) => void
}

/** 云端字段应用单元（先解析后应用，保证原子性） */
interface ParsedCloudField {
  name: string
  data: Record<string, Object>
  apply: (data: Record<string, Object>) => void
}

/** 顶层参与条目并集合并的两个数组字段 */
const GOALS_ARRAY_KEY: string = 'goals'
const TODOS_ARRAY_KEY: string = 'taskList'

/** L2 任务状态字面量（与 `model/BaseTypes.TaskStatus` 保持一致，此处避免反向依赖 model 层） */
const TASK_STATUS_COMPLETED: string = 'completed'
const TASK_STATUS_PENDING: string = 'pending'

/**
 * 载荷自洽化结果
 * `fixed*` 仅用于日志观测，不参与业务判定
 */
interface ReconcileResult {
  goalsJson: string
  todosJson: string
  /** 被修正完成事实的 (L2 任务 ⇄ L4 待办) 对数 */
  fixedPairs: number
  /** 被重算 progress 的 L1 目标数 */
  fixedProgress: number
}

export class CloudSyncService {
  private static readonly tag: string = 'CloudSyncService'
  private static instance: CloudSyncService | null = null

  /** 同步锁：串行执行 merge */
  private isSyncing: boolean = false
  /** 单槽 pending：同步期间到来的请求只置标记（自动去重），本轮结束后补跑一次 */
  private pending: boolean = false
  /** 进行中的同步链 Promise（并发调用共享同一个等待对象） */
  private inFlight: Promise<SyncResult> | null = null

  private constructor() {}

  static getInstance(): CloudSyncService {
    if (CloudSyncService.instance === null) {
      CloudSyncService.instance = new CloudSyncService()
    }
    return CloudSyncService.instance
  }

  /** 是否正在同步（供上层做就绪/并发判断） */
  isBusy(): boolean {
    return this.isSyncing
  }

  async init(context: common.Context): Promise<boolean> {
    return CloudDBService.getInstance().init(context)
  }

  /**
   * 删除云端同步记录（设置页"一键删除所有数据"专用）
   * 未登录（uid 为空）或 CloudDB 未初始化时返回 false
   */
  async deleteCloudRecord(uid: string): Promise<boolean> {
    if (uid.length === 0) {
      return false
    }
    const dbService: CloudDBService = CloudDBService.getInstance()
    if (!dbService.isInitialized()) {
      Logger.warn(CloudSyncService.tag, 'deleteCloudRecord: CloudDB not initialized')
      return false
    }
    return dbService.deleteRecord(uid)
  }

  /**
   * 统一同步入口（所有入口唯一调用点）
   * - 未在同步中：启动同步链（isSyncing + 单槽 pending 循环）
   * - 已在同步中：置 pending 标记（去重）并复用当前同步链的等待对象
   */
  async requestMerge(uid: string, dataProvider: SyncDataProvider,
    callback: SyncApplyCallback): Promise<SyncResult> {
    if (this.isSyncing) {
      this.pending = true
      Logger.info(CloudSyncService.tag,
        'requestMerge: sync in progress, queued as pending (latest snapshot will be used)')
      if (this.inFlight !== null) {
        return this.inFlight
      }
      return { outcome: 'not_ready', uploaded: false, lastSyncTime: 0, errorMsg: 'sync in progress' }
    }
    this.isSyncing = true
    this.inFlight = this.runLoop(uid, dataProvider, callback)
    return this.inFlight
  }

  /**
   * 同步链：至少执行一次 merge；若期间有 pending 请求，则用最新快照补跑
   * 保证"同步期间发生的本地变更"不会被丢弃
   */
  private async runLoop(uid: string, dataProvider: SyncDataProvider,
    callback: SyncApplyCallback): Promise<SyncResult> {
    let result: SyncResult = { outcome: 'idle', uploaded: false, lastSyncTime: 0, errorMsg: '' }
    try {
      let runAgain: boolean = true
      while (runAgain) {
        this.pending = false
        result = await this.runMergeOnce(uid, dataProvider, callback)
        runAgain = this.pending
        if (runAgain) {
          Logger.info(CloudSyncService.tag,
            'runLoop: pending request detected, running one more merge with fresh snapshot')
        }
      }
      return result
    } catch (e) {
      const msg: string = (e as Error).message
      Logger.error(CloudSyncService.tag, 'runLoop failed: ' + msg)
      return { outcome: 'upload_failed', uploaded: false, lastSyncTime: 0, errorMsg: msg }
    } finally {
      this.isSyncing = false
      this.inFlight = null
      this.pending = false
    }
  }

  /**
   * 执行一次完整 merge（拉取 → 合并 → 落地 → 按需上传）
   */
  private async runMergeOnce(uid: string, dataProvider: SyncDataProvider,
    callback: SyncApplyCallback): Promise<SyncResult> {
    if (uid.length === 0) {
      return { outcome: 'idle', uploaded: false, lastSyncTime: 0, errorMsg: 'uid is empty' }
    }

    const dbService: CloudDBService = CloudDBService.getInstance()
    // 就绪 gate 之一：CloudDB 未初始化 → 不发任何网络请求，保留脏标记
    if (!dbService.isInitialized()) {
      Logger.warn(CloudSyncService.tag, 'merge skipped: CloudDB not initialized (dirty flag kept)')
      return { outcome: 'not_ready', uploaded: false, lastSyncTime: 0, errorMsg: 'CloudDB not initialized' }
    }

    // 就绪 gate 之二：本地快照必须已就绪（provider 已注册）
    // 空串只可能来自"provider 未注入"，不是合法业务数据；此时合并会把空本地当成真实数据
    const data: SyncDataBundle = dataProvider()
    if (data.goalsJson.length === 0 && data.todosJson.length === 0) {
      Logger.warn(CloudSyncService.tag, 'merge skipped: local snapshot not ready (dirty flag kept)')
      return { outcome: 'not_ready', uploaded: false, lastSyncTime: 0, errorMsg: 'local snapshot not ready' }
    }

    // 第一步：拉取云端完整记录
    let cloudRecord: UserSyncRecord | null = null
    let downloadError: string = ''
    try {
      cloudRecord = await dbService.downloadRecord(uid)
    } catch (e) {
      downloadError = (e as Error).message
    }
    if (downloadError.length > 0) {
      // 查询失败 ≠ 云端无数据：禁止把失败当成"首传"，否则弱网下会拿本地数据覆盖云端
      const realError: string = dbService.lastError
      const msg: string = realError.length > 0 ? realError : downloadError
      Logger.error(CloudSyncService.tag, 'merge pull failed (dirty flag kept): ' + msg)
      return { outcome: 'pull_failed', uploaded: false, lastSyncTime: 0, errorMsg: 'pull failed: ' + msg }
    }

    // 准入判据（§2.2）：`云端 updatedAt !== 本机水位` 或 `本地有未上传改动` 才需要合并；
    // 两者均不成立 → 两端本已一致，直接结束（不落地、不上传、水位不变）
    // ⚠️ 判据用**等值**而非大小比较：`updatedAt` 由上传方用本机 Date.now() 写入，
    //    跨设备比大小等于比时钟；等值判断只问"变了没有"，天然免疫时钟偏差
    if (cloudRecord !== null && !data.dirty && Number(cloudRecord.updatedAt) === data.lastSyncTime) {
      Logger.info(CloudSyncService.tag,
        'merge: cloud unchanged and local clean, nothing to do. watermark=' + data.lastSyncTime.toString())
      return { outcome: 'ok', uploaded: false, lastSyncTime: Number(cloudRecord.updatedAt), errorMsg: '' }
    }

    // 第二步：合并（settings 本地优先 / profile 云端优先 / 两个数组做条目级并集）
    const rawMergedGoals: string = cloudRecord === null
      ? data.goalsJson
      : this.mergeTopLevelArray(data.goalsJson, cloudRecord.goalsJson, GOALS_ARRAY_KEY)
    const rawMergedTodos: string = cloudRecord === null
      ? data.todosJson
      : this.mergeTopLevelArray(data.todosJson, cloudRecord.todosJson, TODOS_ARRAY_KEY)

    // 第二步半：载荷自洽化（★ 2026-09-17 修复「跨设备进度 / 完成不同步」）
    // `goals` / `taskList` 是两条**独立**合并单元，同一个完成事实存了两份副本
    // （goals[G].tasks[T].status+steps[].isCompleted ↔ taskList[T].isCompleted），
    // 合并时二者各自按条目 updatedAt 裁决 ⇒ 可能各选一端，落地后自相矛盾。
    // 这里把两份副本对齐 + 重算派生 progress，使载荷自洽；
    // 修正结果经第四步指纹对比自动上传，两端随之收敛。
    const reconciled: ReconcileResult = this.reconcileCompletionFacts(rawMergedGoals, rawMergedTodos)
    const mergedGoals: string = reconciled.goalsJson
    const mergedTodos: string = reconciled.todosJson
    const mergedSettings: string = data.settingsJson
    const mergedProfile: string = cloudRecord === null ? data.profileJson : cloudRecord.profileJson

    if (cloudRecord === null) {
      // 云端无记录（首次使用）：合并结果即本地原始数据；本地非空则建立首份记录
      if (data.goalsJson.length === 0 && data.todosJson.length === 0
        && data.settingsJson.length === 0 && data.profileJson.length === 0) {
        Logger.info(CloudSyncService.tag, 'merge: cloud null and local empty, nothing to establish')
        return { outcome: 'ok', uploaded: false, lastSyncTime: 0, errorMsg: '' }
      }
      const written: string = await this.uploadPayload(uid, mergedGoals, mergedTodos, mergedSettings, mergedProfile)
      if (written.length === 0) {
        return {
          outcome: 'upload_failed', uploaded: false, lastSyncTime: 0,
          errorMsg: 'first upload failed: ' + dbService.lastError
        }
      }
      Logger.info(CloudSyncService.tag, 'merge: cloud null, local uploaded as first record')
      return { outcome: 'ok', uploaded: true, lastSyncTime: Number(written), errorMsg: '' }
    }

    const cloudUpdatedAt: number = Number(cloudRecord.updatedAt)

    // 第三步：先落地合并结果（全分支统一，覆盖"无需上传"路径 —— 否则冲突中落败一端永远显示旧内容）
    const mergedRecord: UserSyncRecord = {
      uid: uid,
      goalsJson: mergedGoals,
      todosJson: mergedTodos,
      settingsJson: mergedSettings,
      profileJson: mergedProfile,
      updatedAt: cloudRecord.updatedAt
    }
    const applied: boolean = this.applyCloudData(mergedRecord, callback)
    if (!applied) {
      // 预解析失败：本地未被修改，保留脏标记等下次重试
      Logger.error(CloudSyncService.tag, 'merge parse failed, local kept intact (dirty flag kept)')
      return { outcome: 'parse_failed', uploaded: false, lastSyncTime: 0, errorMsg: 'cloud data parse failed' }
    }

    // 第四步：指纹对比「合并结果 × 云端原始数据包」（canonical，免疫键序）
    const mergedFp: string = this.payloadFingerprint(mergedGoals, mergedTodos, mergedSettings, mergedProfile)
    const cloudFp: string = this.payloadFingerprint(
      cloudRecord.goalsJson, cloudRecord.todosJson, cloudRecord.settingsJson, cloudRecord.profileJson)
    if (mergedFp === cloudFp) {
      // 云端已是最新：不上传，但水位要推进（否则等值判据每次都判"云端变了"→ 反复 merge）
      Logger.info(CloudSyncService.tag,
        'merge: merged equals cloud, no upload needed. watermark advanced to cloud updatedAt')
      return { outcome: 'ok', uploaded: false, lastSyncTime: cloudUpdatedAt, errorMsg: '' }
    }

    // 第五步：上传合并结果
    const written: string = await this.uploadPayload(uid, mergedGoals, mergedTodos, mergedSettings, mergedProfile)
    if (written.length === 0) {
      // 本地已落地合并结果，但上传失败：水位不变 + 保留脏标记，等下次重试
      Logger.warn(CloudSyncService.tag,
        'merge: landed locally but upload failed (dirty flag kept): ' + dbService.lastError)
      return {
        outcome: 'upload_failed', uploaded: false, lastSyncTime: 0,
        errorMsg: 'upload failed: ' + dbService.lastError
      }
    }
    Logger.info(CloudSyncService.tag, 'merge: merged, landed and uploaded. watermark = ' + written)
    return { outcome: 'ok', uploaded: true, lastSyncTime: Number(written), errorMsg: '' }
  }

  /**
   * 写入云端并返回**本次真正落库的 updatedAt**（失败返回空串）
   * ⚠️ 水位必须取自这里的返回值：它是云端实际存储的版本标识，
   *    杜绝"水位由客户端另行生成、与云端实际值不一致"的历史缺陷。
   */
  private async uploadPayload(uid: string, goalsJson: string, todosJson: string,
    settingsJson: string, profileJson: string): Promise<string> {
    const dbService: CloudDBService = CloudDBService.getInstance()
    if (!dbService.isInitialized()) {
      Logger.warn(CloudSyncService.tag, 'uploadPayload: CloudDB not initialized')
      return ''
    }
    const updatedAt: string = Date.now().toString()
    const record: UserSyncRecord = {
      uid: uid,
      goalsJson: goalsJson,
      todosJson: todosJson,
      settingsJson: settingsJson,
      profileJson: profileJson,
      updatedAt: updatedAt
    }
    try {
      const ok: boolean = await dbService.uploadRecord(record)
      if (ok) {
        Logger.info(CloudSyncService.tag, 'uploadPayload success, updatedAt=' + updatedAt)
        return updatedAt
      }
      return ''
    } catch (e) {
      Logger.error(CloudSyncService.tag, 'uploadPayload failed: ' + (e as Error).message)
      return ''
    }
  }

  /**
   * 两阶段原子性应用云端数据：先全量预解析（任一失败则整体放弃），再逐字段应用
   * 杜绝"部分字段被覆盖"的中间态
   * @returns true 表示已成功应用；false 表示预解析失败已整体放弃，本地数据未被修改
   */
  private applyCloudData(record: UserSyncRecord, callback: SyncApplyCallback): boolean {
    // 第一阶段：统一预解析，不触碰本地数据
    const pending: Array<ParsedCloudField> = []

    if (record.goalsJson.length > 0) {
      try {
        const data: Record<string, Object> = JSON.parse(record.goalsJson) as Record<string, Object>
        pending.push({ name: 'goals', data: data, apply: callback.applyGoals })
      } catch (e) {
        Logger.error(CloudSyncService.tag, 'applyCloudData: goals parse failed: ' + (e as Error).message)
        return false
      }
    }
    if (record.todosJson.length > 0) {
      try {
        const data: Record<string, Object> = JSON.parse(record.todosJson) as Record<string, Object>
        pending.push({ name: 'todos', data: data, apply: callback.applyTodos })
      } catch (e) {
        Logger.error(CloudSyncService.tag, 'applyCloudData: todos parse failed: ' + (e as Error).message)
        return false
      }
    }
    if (record.settingsJson.length > 0) {
      try {
        const data: Record<string, Object> = JSON.parse(record.settingsJson) as Record<string, Object>
        pending.push({ name: 'settings', data: data, apply: callback.applySettings })
      } catch (e) {
        Logger.error(CloudSyncService.tag, 'applyCloudData: settings parse failed: ' + (e as Error).message)
        return false
      }
    }
    if (record.profileJson.length > 0) {
      try {
        const data: Record<string, Object> = JSON.parse(record.profileJson) as Record<string, Object>
        pending.push({ name: 'profile', data: data, apply: callback.applyProfile })
      } catch (e) {
        Logger.error(CloudSyncService.tag, 'applyCloudData: profile parse failed: ' + (e as Error).message)
        return false
      }
    }

    // 第二阶段：全部解析成功，原子化逐字段应用（单个字段异常不影响其他字段）
    let failedFields: number = 0
    const failedFieldNames: string[] = []
    for (let i: number = 0; i < pending.length; i++) {
      const field: ParsedCloudField = pending[i]
      try {
        field.apply(field.data)
      } catch (e) {
        failedFields++
        failedFieldNames.push(field.name)
        Logger.warn(CloudSyncService.tag, 'applyCloudData: apply ' + field.name +
          ' failed: ' + (e as Error).message)
      }
    }
    if (failedFields > 0) {
      Logger.warn(CloudSyncService.tag, 'applyCloudData: ' + failedFields.toString() + '/' +
        pending.length.toString() + ' fields apply failed, failedFields=[' + failedFieldNames.join(', ') + ']')
    } else if (pending.length > 0) {
      Logger.info(CloudSyncService.tag, 'applyCloudData: all ' + pending.length.toString() +
        ' fields applied successfully')
    }
    return true
  }

  /* ============================================================
   * 顶层条目并集合并（含墓碑 OR 与条目 updatedAt 裁决）
   * ============================================================ */

  /**
   * 按 id 做顶层数组的条目级并集合并
   * - **以云端数组顺序为基底**（合并结果与云端顺序一致 → 指纹比较可收敛、不反复上传）
   * - 同 id：条目 updatedAt 值大者胜出；缺失用 createTime 兜底；
   *   完全相等或双方都缺失 → **本地优先**（保证本机编辑不被云端旧版本抹掉）
   * - 墓碑 OR：任一方 isDeleted=true，合并结果该条目保持 isDeleted=true
   * - 非数组兄弟字段（version / filterCategory 等）：云端有则取云端，避免两端来回覆盖
   *
   * @param localJson 本地快照 JSON
   * @param cloudJson 云端快照 JSON
   * @param arrayKey 'goals' 或 'taskList'
   * @returns 合并后的 JSON 字符串
   */
  private mergeTopLevelArray(localJson: string, cloudJson: string, arrayKey: string): string {
    if (localJson.length === 0) return cloudJson
    if (cloudJson.length === 0) return localJson

    let localObj: Record<string, Object>
    let cloudObj: Record<string, Object>
    try {
      localObj = JSON.parse(localJson) as Record<string, Object>
      cloudObj = JSON.parse(cloudJson) as Record<string, Object>
    } catch (e) {
      // 任一侧解析失败：不做破坏性合并，保留本地（本地是权威副本）
      Logger.warn(CloudSyncService.tag, 'mergeTopLevelArray: parse failed, keep local side')
      return localJson
    }

    const localArr: Object[] = Array.isArray(localObj[arrayKey]) ? localObj[arrayKey] as Object[] : []
    const cloudArr: Object[] = Array.isArray(cloudObj[arrayKey]) ? cloudObj[arrayKey] as Object[] : []

    const mergedArr: Object[] = []
    const handledIds: Set<string> = new Set<string>()

    // 1. 以云端顺序为基底，逐条与本地同 id 裁决
    for (let i: number = 0; i < cloudArr.length; i++) {
      const cloudItem: Object = cloudArr[i]
      const id: string = this.extractId(cloudItem)
      if (id.length === 0) {
        mergedArr.push(cloudItem)
        continue
      }
      const localItem: Object | null = this.findItemById(localArr, id)
      mergedArr.push(localItem === null ? cloudItem : this.pickWinner(localItem, cloudItem))
      handledIds.add(id)
    }

    // 2. 追加仅本地存在的条目（保持本地顺序）
    for (let j: number = 0; j < localArr.length; j++) {
      const localItem: Object = localArr[j]
      const id: string = this.extractId(localItem)
      if (id.length === 0) {
        mergedArr.push(localItem)
        continue
      }
      if (!handledIds.has(id)) {
        mergedArr.push(localItem)
        handledIds.add(id)
      }
    }

    // 3. 组装：非数组兄弟字段以云端为准（云端缺失时回退本地），数组用合并结果
    const mergedObj: Record<string, Object> = {}
    const localKeys: string[] = Object.keys(localObj)
    for (let k: number = 0; k < localKeys.length; k++) {
      const key: string = localKeys[k]
      if (key === arrayKey) continue
      mergedObj[key] = localObj[key]
    }
    const cloudKeys: string[] = Object.keys(cloudObj)
    for (let m: number = 0; m < cloudKeys.length; m++) {
      const key: string = cloudKeys[m]
      if (key === arrayKey) continue
      mergedObj[key] = cloudObj[key]
    }
    mergedObj[arrayKey] = mergedArr
    return JSON.stringify(mergedObj)
  }

  /**
   * 同 id 条目裁决：墓碑 OR + updatedAt 较大者胜出（相等/缺失 → 本地优先）
   * ⚠️ 这里操作的是刚解析出来的 JSON 裸对象（不是 VM 中的 @Trace 实例），就地改 isDeleted 安全
   */
  private pickWinner(localItem: Object, cloudItem: Object): Object {
    const localDel: boolean = this.readBool(localItem, 'isDeleted')
    const cloudDel: boolean = this.readBool(cloudItem, 'isDeleted')
    const localStamp: number = this.itemStamp(localItem)
    const cloudStamp: number = this.itemStamp(cloudItem)

    // 本地优先：用 >= 而非 >，保证"完全相等或双方都缺失"时取本地
    const winner: Object = localStamp >= cloudStamp ? localItem : cloudItem

    // 墓碑 OR：任一方已删除 → 合并结果必须保持删除
    if ((localDel || cloudDel) && !this.readBool(winner, 'isDeleted')) {
      const rec: Record<string, Object> = winner as Record<string, Object>
      rec['isDeleted'] = true
    }
    return winner
  }

  /**
   * 条目版本时间戳：优先 updatedAt，缺失/非法时退化为 createTime（老数据兼容）
   */
  private itemStamp(item: Object): number {
    const rec: Record<string, Object> = item as Record<string, Object>
    const updated: Object | undefined = rec['updatedAt']
    if (typeof updated === 'number' && !isNaN(updated as number) && (updated as number) > 0) {
      return updated as number
    }
    const created: Object | undefined = rec['createTime']
    if (typeof created === 'number' && !isNaN(created as number)) {
      return created as number
    }
    return 0
  }

  /** 读取布尔字段（缺失 / 类型不符 → false，老数据兼容） */
  private readBool(item: Object, key: string): boolean {
    const v: Object | undefined = (item as Record<string, Object>)[key]
    return v === true
  }

  /** 从数组元素提取 id */
  private extractId(item: Object): string {
    const idVal: Object | undefined = (item as Record<string, Object>)['id']
    if (typeof idVal === 'string') return idVal as string
    if (typeof idVal === 'number') return (idVal as number).toString()
    return ''
  }

  /** 在数组中按 id 查找（未找到返回 null） */
  private findItemById(arr: Object[], id: string): Object | null {
    for (let i: number = 0; i < arr.length; i++) {
      if (this.extractId(arr[i]) === id) {
        return arr[i]
      }
    }
    return null
  }

  /* ============================================================
   * 载荷自洽化（跨设备进度 / 完成一致性）
   * ============================================================ */

  /**
   * 载荷自洽化：消除 `goals` / `taskList` 两条独立合并单元造成的「同一事实两份副本不一致」
   *
   * **背景（2026-09-17 勘察结论）**
   *   - `goalsJson` 与 `todosJson` 是两条独立载荷，合并时**各自**按条目 `updatedAt` 做整块 LWW
   *     （`pickWinner`），字段级无任何规则；L2/L3 不递归，随目标整块走。
   *   - 同一个「任务 T 已完成」存了两份副本：
   *     `goals[G].tasks[T].status` + `steps[].isCompleted`  与  `taskList[T].isCompleted`。
   *   - 两条载荷分别裁决 ⇒ 可以一个取平板版、一个取手机版；落地后**首页说已完成、
   *     路线页 / 目标详情说未完成**。`progress` 又是冗余存储（持久化 + 派生），
   *     整块 LWW 会把旧值一并带回来 ⇒ 进度看起来"没同步"。
   *
   * **本方法做两件事（顺序不可颠倒）**
   *   1. **L2 ⇄ L4 完成事实对齐**：同一逻辑任务的完成态只保留一个结论，写回两侧
   *      （含 L3 步骤，与 `RoutePageViewModel.syncStepFromTodoCompletion` 本地语义一致）。
   *   2. **L1 progress 重算**：从 L2 `tasks[].status` 派生，与
   *      `RoutePageViewModel.updateGoalProgressByTasks` 同公式 —— 让 progress 变成
   *      目标块的**纯函数**，此后不再可能因整块 LWW 带回旧进度而分裂。
   *
   * **裁决规则（2026-09-17 A″：同类对称比较）**
   *   两侧各取**自己的完成态时间轴**（只有完成态真的变化才刷新的字段）比大小，谁更晚谁胜；
   *   时间戳相等或一侧缺失（0 = 从未变更过完成态）→ 完成优先
   *   （完成是单调语义，`true` 被 `false` 覆盖是纯信息丢失；但"取消完成"是合法操作，故不能简单 OR）。
   *   - L2 声明完成 → 比较 `task.completionUpdatedAt` 与 `todo.completionUpdatedAt`
   *   - L4 声明完成 → 同样比较这两条轴（方向相反）
   *   - 老数据无该键 → 退化为"首次完成时刻" `actualCompletionTime`，再退化到条目既有时间戳
   *
   *   ⚠️ 曾用的旧规则是**跨类型比较**（完成时刻 vs 对端"任意改动时刻"，如 `goal.updatedAt`）：
   *     平板只是改个目标名就会抬高它，从而把手机刚声明的完成压掉。已废弃，勿复活。
   *
   * ⚠️ **三条硬约束（违反会造成反复上传 / 死循环）**
   *   1. **必须是纯函数**：相同入参必得相同出参。两端合并输入不同却能各算出一个结果，
   *      若引入 `Date.now()` 之类的本机时钟，两端永远算不出同一个值 ⇒ 指纹恒不相等 ⇒ 上传风暴。
   *      所以本方法**绝不使用 `Date.now()`**，一切时间戳从载荷内已有字段推导（取 `Math.max` 单调收敛）。
   *   2. **禁止改写任何条目的 `updatedAt`**：伪造"本机更新"会污染 LWW 裁决依据。
   *   3. **解析失败原样返回**：不做破坏性修正（本地是权威副本）。
   *
   * ⚠️ 本方法**不解决**"整块 LWW 丢更新"（平板改个名字 `G.updatedAt` 变大即整块覆盖手机勾的完成态）——
   *    那需要把 L2 任务提升为顶层合并条目（option C），属于载荷结构变更，另行评估。
   *    （A″ 已把**完成态本身**的裁决从"任意改动时刻"解耦出来：改名 / 调优先级 / 累计专注
   *      都不再有权改判完成，剩下的只是该整块被覆盖时的连带丢失。）
   *
   * @param goalsJson 合并后的 goals 载荷
   * @param todosJson 合并后的 taskList 载荷
   * @returns 自洽化后的两条载荷 + 修正计数
   */
  private reconcileCompletionFacts(goalsJson: string, todosJson: string): ReconcileResult {
    const unchanged: ReconcileResult = {
      goalsJson: goalsJson,
      todosJson: todosJson,
      fixedPairs: 0,
      fixedProgress: 0
    }
    // 任一侧为空：无法建立 L2 ⇄ L4 对应关系，原样返回
    if (goalsJson.length === 0 || todosJson.length === 0) return unchanged

    let goalsObj: Record<string, Object>
    let todosObj: Record<string, Object>
    try {
      goalsObj = JSON.parse(goalsJson) as Record<string, Object>
      todosObj = JSON.parse(todosJson) as Record<string, Object>
    } catch (e) {
      Logger.warn(CloudSyncService.tag, 'reconcile: parse failed, keep payload as-is')
      return unchanged
    }

    const goalsArr: Object[] = Array.isArray(goalsObj[GOALS_ARRAY_KEY])
      ? goalsObj[GOALS_ARRAY_KEY] as Object[] : []
    const todosArr: Object[] = Array.isArray(todosObj[TODOS_ARRAY_KEY])
      ? todosObj[TODOS_ARRAY_KEY] as Object[] : []
    if (goalsArr.length === 0 || todosArr.length === 0) return unchanged

    // 目标索引：id → 原始 JSON 裸对象（就地修改安全，非 @Trace 实例）
    const goalIndex: Map<string, Record<string, Object>> = new Map<string, Record<string, Object>>()
    for (let i: number = 0; i < goalsArr.length; i++) {
      const goal: Record<string, Object> = goalsArr[i] as Record<string, Object>
      const id: string = this.extractId(goal)
      if (id.length > 0 && !goalIndex.has(id)) {
        goalIndex.set(id, goal)
      }
    }

    let fixedPairs: number = 0

    // ---- 第一步：L2 ⇄ L4 完成事实对齐 ----
    for (let i: number = 0; i < todosArr.length; i++) {
      const todo: Record<string, Object> = todosArr[i] as Record<string, Object>
      if (this.readBool(todo, 'isDeleted')) continue
      const goalId: string = this.readString(todo, 'relatedGoalId')
      const taskId: string = this.readString(todo, 'relatedTaskId')
      // 孤立待办（无关联目标/任务）没有 L2 对照面，保持自身状态
      if (goalId.length === 0 || taskId.length === 0) continue
      const goal: Record<string, Object> | undefined = goalIndex.get(goalId)
      if (goal === undefined || this.readBool(goal, 'isDeleted')) continue
      const tasksRaw: Object | undefined = goal['tasks']
      if (!Array.isArray(tasksRaw)) continue
      const task: Record<string, Object> | null = this.findTaskById(tasksRaw as Object[], taskId)
      if (task === null) continue

      const l2Done: boolean = this.readString(task, 'status') === TASK_STATUS_COMPLETED
      const l4Done: boolean = this.readBool(todo, 'isCompleted')
      // 两份副本本就一致 → 不动（避免无谓的指纹变化触发上传）
      if (l2Done === l4Done) continue

      // 两侧的"首次完成时刻"（actualCompletionTime 语义：取消会归零），仅用于回写一致的完成时刻
      const l2At: number = this.readNumber(task, 'actualCompletionTime')
      const l4At: number = this.readNumber(todo, 'actualCompletionTime')
      // 两侧各自的**完成态时间轴**（只有完成态真的变化才刷新；0 = 从未变更过完成态）
      const c2: number = this.readNumber(task, 'completionUpdatedAt')
      const c4: number = this.readNumber(todo, 'completionUpdatedAt')

      // ---- 完成态裁决（2026-09-17 改进 A″：同类对称比较） ----
      // 旧规则是**跨类型比较**（完成时刻 vs 对端"任意改动时刻"）：
      //   `l4At >= this.itemStamp(goal)` —— 平板只是改个目标名就会抬高 goal.updatedAt，
      //   从而把手机声明的完成压掉（跨设备丢更新）。
      // 新规则：两侧各取**自己的完成态时间轴**比大小，谁的最后一次完成态变更更新，谁胜。
      //   - L2 侧 = `task.completionUpdatedAt`（老数据无此键 → 退化为"首次完成时刻"）
      //   - L4 侧 = `todo.completionUpdatedAt`（老数据 → 退化"首次完成时刻"，再退化条目时间戳）
      //   - 未完成一侧为 0（从未变更过完成态）→ 另一侧的完成声明直接成立
      //     （0 是"没说过"，不是"我反对"）
      let tDone: number
      let tNo: number
      if (l2Done) {
        // L2 声明完成：声明时刻取完成轴（老数据退化为"首次完成时刻"）
        tDone = c2 > 0 ? c2 : l2At
        // 反方（L4）的完成态最后变更时刻
        tNo = c4 > 0 ? c4 : this.itemStamp(todo)
      } else {
        // L4 声明完成：声明时刻取完成轴（老数据退化"首次完成时刻"，再退化条目时间戳）
        tDone = c4 > 0 ? c4 : (l4At > 0 ? l4At : this.itemStamp(todo))
        // 反方（L2）的完成态最后变更时刻（0 = 从未变更过完成态）
        tNo = c2
      }
      // 反方未在完成声明之后变更过完成态 → 完成声明成立（`<=` 保证相等时判完成，幂等）
      const completed: boolean = tNo <= tDone
      // 完成时刻取两侧较大值：单调不减 ⇒ 两端反复合并会收敛到同一个数，不会来回反转
      const completionTime: number = Math.max(l2At, l4At)

      // 写回 L2（含 L3 步骤，全量对齐 —— 与本地 syncStepFromTodoCompletion 的处理一致）
      const stepsRaw: Object | undefined = task['steps']
      if (Array.isArray(stepsRaw)) {
        const steps: Object[] = stepsRaw as Object[]
        for (let s: number = 0; s < steps.length; s++) {
          (steps[s] as Record<string, Object>)['isCompleted'] = completed
        }
      }
      task['status'] = completed ? TASK_STATUS_COMPLETED : TASK_STATUS_PENDING
      task['actualCompletionTime'] = completed ? completionTime : 0

      // 写回 L4
      todo['isCompleted'] = completed
      todo['actualCompletionTime'] = completed ? completionTime : 0

      fixedPairs++
      Logger.warn(CloudSyncService.tag, 'reconcile: fixed completion fact. goalId=' + goalId +
        ', taskId=' + taskId + ', l2Done=' + l2Done.toString() + ', l4Done=' + l4Done.toString() +
        ' -> completed=' + completed.toString())
    }

    // ---- 第二步：L1 progress 重算（必须在完成事实对齐之后，否则用的是旧 status） ----
    let fixedProgress: number = 0
    for (let i: number = 0; i < goalsArr.length; i++) {
      const goal: Record<string, Object> = goalsArr[i] as Record<string, Object>
      if (this.readBool(goal, 'isDeleted')) continue
      const tasksRaw: Object | undefined = goal['tasks']
      if (!Array.isArray(tasksRaw)) continue
      const tasks: Object[] = tasksRaw as Object[]
      // 无 L2 任务的目标：progress 由 milestones 主导（见 updateGoalProgressByTasks 规则 1），不覆盖
      if (tasks.length === 0) continue

      let completedCount: number = 0
      let maxCompletionTime: number = 0
      for (let t: number = 0; t < tasks.length; t++) {
        const task: Record<string, Object> = tasks[t] as Record<string, Object>
        if (this.readString(task, 'status') === TASK_STATUS_COMPLETED) {
          completedCount++
          const at: number = this.readNumber(task, 'actualCompletionTime')
          if (at > maxCompletionTime) {
            maxCompletionTime = at
          }
        }
      }

      // 与 RoutePageViewModel.updateGoalProgressByTasks 同公式（整块 LWW 下 progress 必须是 tasks 的纯函数）
      const newProgress: number = Math.round((completedCount / tasks.length) * 100)
      if (this.readNumber(goal, 'progress') !== newProgress) {
        goal['progress'] = newProgress
        fixedProgress++
      }

      // 目标完成时间戳同样派生（达标取任务完成时刻、回退到 100 以下清零），与 progress 语义保持同步
      const oldGoalAt: number = this.readNumber(goal, 'actualCompletionTime')
      const newGoalAt: number = newProgress >= 100 ? Math.max(oldGoalAt, maxCompletionTime) : 0
      if (oldGoalAt !== newGoalAt) {
        goal['actualCompletionTime'] = newGoalAt
      }
    }

    if (fixedPairs === 0 && fixedProgress === 0) return unchanged

    let outGoals: string = goalsJson
    let outTodos: string = todosJson
    try {
      outGoals = JSON.stringify(goalsObj)
      outTodos = JSON.stringify(todosObj)
    } catch (e) {
      Logger.warn(CloudSyncService.tag, 'reconcile: stringify failed, keep payload as-is')
      return unchanged
    }
    Logger.warn(CloudSyncService.tag, 'reconcile done: fixedPairs=' + fixedPairs.toString() +
      ', fixedProgress=' + fixedProgress.toString())
    return {
      goalsJson: outGoals,
      todosJson: outTodos,
      fixedPairs: fixedPairs,
      fixedProgress: fixedProgress
    }
  }

  /** 读取字符串字段（缺失 / 类型不符 → 空串） */
  private readString(item: Record<string, Object>, key: string): string {
    const v: Object | undefined = item[key]
    return typeof v === 'string' ? v as string : ''
  }

  /** 读取数字字段（缺失 / 类型不符 / NaN → 0） */
  private readNumber(item: Record<string, Object>, key: string): number {
    const v: Object | undefined = item[key]
    if (typeof v === 'number' && !isNaN(v as number)) {
      return v as number
    }
    return 0
  }

  /** 在 L2 任务数组中按 id 查找（未找到返回 null） */
  private findTaskById(tasks: Object[], taskId: string): Record<string, Object> | null {
    for (let i: number = 0; i < tasks.length; i++) {
      const task: Record<string, Object> = tasks[i] as Record<string, Object>
      // 复用 extractId：兼容历史上 id 为数字的老数据
      if (this.extractId(task) === taskId) {
        return task
      }
    }
    return null
  }

  /* ============================================================
   * 指纹（canonical JSON + 双 32 位哈希）
   * ============================================================ */

  /**
   * 数据包指纹：对 4 段载荷做 canonical 归一后哈希
   * - **canonical 化**：对象键递归排序 → 只比内容、不比序列化顺序（免疫键序差异）
   * - profile 段内的 lastSyncTime 先中性化（该字段不参与同步语义，且永不上传）
   * - 解析失败时退化为原始字符串，保证不抛异常
   */
  private payloadFingerprint(goalsJson: string, todosJson: string,
    settingsJson: string, profileJson: string): string {
    const goals: string = this.canonicalOf(goalsJson)
    const todos: string = this.canonicalOf(todosJson)
    const settings: string = this.canonicalOf(settingsJson)
    const profile: string = this.canonicalOf(this.neutralizeLastSyncTime(profileJson))
    return this.hash64(goals) + '|' + this.hash64(todos) + '|' + this.hash64(settings) + '|' + this.hash64(profile)
      + '|' + goals.length.toString() + '|' + todos.length.toString()
      + '|' + settings.length.toString() + '|' + profile.length.toString()
  }

  /**
   * 把 profileJson 中的**本机专属字段**数值中性化（不参与内容比较、永不上传）
   * - `lastSyncTime`：本机水位游标
   * - `lastSyncedAt`：本机"上次同步成功时刻"（2026-10-13 新增，展示用）
   * ⚠️ 两者都必须中性化：否则每次同步成功都会改变载荷指纹 → 白跑一轮上传
   */
  private neutralizeLastSyncTime(profileJson: string): string {
    if (profileJson.length === 0) return ''
    return profileJson.replace(/"lastSyncTime"\s*:\s*-?\d+/g, '"lastSyncTime":0')
      .replace(/"lastSyncedAt"\s*:\s*-?\d+/g, '"lastSyncedAt":0')
  }

  /** 解析并 canonical 化（对象键排序）；任一步失败则退化为原字符串 */
  private canonicalOf(json: string): string {
    if (json.length === 0) return ''
    try {
      return this.canonical(JSON.parse(json) as Object)
    } catch (e) {
      return json
    }
  }

  /**
   * 递归 canonical 序列化：对象键排序、数组保序、原始值走 JSON.stringify
   */
  private canonical(value: Object | null | undefined): string {
    if (value === null || value === undefined) return 'null'
    if (Array.isArray(value)) {
      const arr: Object[] = value as Object[]
      let out: string = '['
      for (let i: number = 0; i < arr.length; i++) {
        if (i > 0) out += ','
        out += this.canonical(arr[i])
      }
      return out + ']'
    }
    const kind: string = typeof value
    if (kind === 'string') return JSON.stringify(value as string)
    if (kind === 'number') {
      const n: number = value as number
      return isNaN(n) ? 'null' : n.toString()
    }
    if (kind === 'boolean') return (value as boolean) ? 'true' : 'false'
    const obj: Record<string, Object> = value as Record<string, Object>
    const keys: string[] = Object.keys(obj).sort()
    let out: string = '{'
    for (let j: number = 0; j < keys.length; j++) {
      if (j > 0) out += ','
      out += JSON.stringify(keys[j]) + ':' + this.canonical(obj[keys[j]])
    }
    return out + '}'
  }

  /**
   * 双 djb2 变体哈希（两次遍历合并为一次，输出 16 位 16 进制 ≈ 64 位）
   * 用 `| 0` 每步强制截断到 32 位，避免浮点精度问题；不依赖 Math.imul。
   */
  private hash64(input: string): string {
    let h1: number = 5381
    let h2: number = 52711
    for (let i: number = 0; i < input.length; i++) {
      const c: number = input.charCodeAt(i)
      h1 = ((h1 << 5) - h1 + c) | 0
      h2 = (((h2 << 5) + h2) ^ c ^ (i << 3)) | 0
    }
    return ((h1 >>> 0).toString(16) + (h2 >>> 0).toString(16))
  }
}
