/** 云端同步编排服务 - 上传/下载/并集合并，不直接 import ViewModel 避免循环依赖 */

import { CloudDBService, UserSyncRecord } from './CloudDBService'
import { Logger } from '../utils/Logger'
import { common } from '@kit.AbilityKit'

export interface SyncResult {
  success: boolean
  direction: 'upload' | 'download' | 'merge' | 'none' | 'error'
  errorMsg: string
}

export interface SyncDataBundle {
  goalsJson: string
  todosJson: string
  settingsJson: string
  profileJson: string
  lastSyncTime: number
  forceUpload: boolean // 保留向后兼容，新策略下不再使用，同步方向由 direction 参数决定
}

/**
 * 同步方向（手动上传 + 自动下拉覆盖 + 并集合并策略）
 * - 'upload'：强制上传本地数据覆盖云端（手动点击"立即同步"按钮）
 * - 'download'：强制下载云端数据覆盖本地（App启动/多端协同/登录后自动触发）
 * - 'merge'：下载云端数据与本地按 id 做并集合并，两端独有数据都保留，
 *            同 id 冲突项取整包 updatedAt 较新一端；合并结果写回本地并回传云端
 */
export type SyncDirection = 'upload' | 'download' | 'merge'

export interface SyncApplyCallback {
  applyGoals: (data: Record<string, Object>) => void
  applyTodos: (data: Record<string, Object>) => void
  applySettings: (data: Record<string, Object>) => void
  applyProfile: (data: Record<string, Object>) => void
  updateLastSyncTime: (time: number) => void
}

/**
 * 云端字段应用单元（先解析后应用，保证原子性）
 */
interface ParsedCloudField {
  name: string
  data: Record<string, Object>
  apply: (data: Record<string, Object>) => void
}

export class CloudSyncService {
  private static readonly tag: string = 'CloudSyncService'
  private static instance: CloudSyncService | null = null
  private syncTimer: number = -1
  private isSyncing: boolean = false
  /** 上次成功上传的数据指纹，用于脏检查避免重复上传 */
  private lastUploadedFingerprint: string = ''

  private constructor() {}

  static getInstance(): CloudSyncService {
    if (CloudSyncService.instance === null) {
      CloudSyncService.instance = new CloudSyncService()
    }
    return CloudSyncService.instance
  }

  /**
   * 计算数据指纹用于脏检查
   * 排除 lastSyncTime 字段：该字段每次同步后都会变，纳入会导致脏检查永远判定有变化→死循环
   */
  private buildFingerprint(uid: string, data: SyncDataBundle): string {
    const normalizedProfile: string = data.profileJson.replace(/"lastSyncTime":\d+/g, '"lastSyncTime":0')
    return uid + '|' +
      data.goalsJson + '|' +
      data.todosJson + '|' +
      data.settingsJson + '|' +
      normalizedProfile
  }

  /**
   * 脏检查：内容未变化则跳过 Upsert，返回 false（不触发任何写回）
   * @returns true 表示内容有变化需要上传；false 表示内容未变应跳过
   */
  private shouldUpload(uid: string, data: SyncDataBundle): boolean {
    const fp: string = this.buildFingerprint(uid, data)
    if (fp === this.lastUploadedFingerprint) {
      Logger.info(CloudSyncService.tag, 'shouldUpload: content unchanged, skip upload (dirty check)')
      return false
    }
    this.lastUploadedFingerprint = fp
    return true
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

  async upload(uid: string, data: SyncDataBundle): Promise<boolean> {
    if (uid.length === 0) return false
    const dbService: CloudDBService = CloudDBService.getInstance()
    if (!dbService.isInitialized()) {
      Logger.warn(CloudSyncService.tag, 'upload: CloudDB not initialized')
      return false
    }

    try {
      const record: UserSyncRecord = {
        uid: uid,
        goalsJson: data.goalsJson,
        todosJson: data.todosJson,
        settingsJson: data.settingsJson,
        profileJson: data.profileJson,
        updatedAt: Date.now().toString()
      }
      const ok: boolean = await dbService.uploadRecord(record)
      if (ok) {
        data.lastSyncTime = Number(record.updatedAt)
        Logger.info(CloudSyncService.tag, 'upload success, uid=' + uid)
      }
      return ok
    } catch (e) {
      Logger.error(CloudSyncService.tag, 'upload failed: ' + (e as Error).message)
      return false
    }
  }

  /**
   * 脏检查 + 防抖上传
   * 内容指纹相同则跳过上传，切断"上传→写回lastSyncTime→触发回调→再上传"的死循环
   */
  async uploadIfChanged(uid: string, data: SyncDataBundle): Promise<boolean> {
    // 脏检查：内容未变直接返回 true（视为已同步），避免周期 Upsert
    if (!this.shouldUpload(uid, data)) {
      return true
    }
    return await this.upload(uid, data)
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

    // 第二阶段：全部解析成功，原子化逐字段应用（此时 applyXxx 内部异常仅记录，不影响其他字段）
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

    // 日志汇总
    if (failedFields > 0) {
      Logger.warn(CloudSyncService.tag, 'applyCloudData: ' + failedFields.toString() + '/' +
        pending.length.toString() + ' fields apply failed, failedFields=[' + failedFieldNames.join(', ') + ']')
    } else if (pending.length > 0) {
      Logger.info(CloudSyncService.tag, 'applyCloudData: all ' + pending.length.toString() +
        ' fields applied successfully')
    }

    // 解析阶段任一失败已在上方提前返回 false（原子性保护，本地未被修改）
    return true
  }

  /**
   * 按 id 并集合并两个 JSON 数组快照（方案A：多端协同冲突保护）
   * - 数组字段（arrayKey）按元素 id 取并集：云端独有加入、本地独有保留、
   *   同 id 冲突取较新一端的元素
   * - 非数组字段（如 filterCategory/version）取较新一端的值
   *
   * @param localJson 本地快照 JSON（goals 或 todos）
   * @param cloudJson 云端快照 JSON
   * @param arrayKey 数组字段名（goals 对应 'goals'，todos 对应 'taskList'）
   * @param cloudNewer 云端整包是否较新（按 updatedAt 比较）
   * @returns 合并后的 JSON 字符串；任一侧为空 JSON 时返回非空侧
   */
  private mergeIdArrays(localJson: string, cloudJson: string, arrayKey: string, cloudNewer: boolean): string {
    if (localJson.length === 0 && cloudJson.length === 0) return ''
    if (localJson.length === 0) return cloudJson
    if (cloudJson.length === 0) return localJson

    let localObj: Record<string, Object>
    let cloudObj: Record<string, Object>
    try {
      localObj = JSON.parse(localJson) as Record<string, Object>
      cloudObj = JSON.parse(cloudJson) as Record<string, Object>
    } catch (e) {
      Logger.warn(CloudSyncService.tag, 'mergeIdArrays: parse failed, keep newer side')
      return cloudNewer ? cloudJson : localJson
    }

    const localArr: Object[] = Array.isArray(localObj[arrayKey]) ? localObj[arrayKey] as Object[] : []
    const cloudArr: Object[] = Array.isArray(cloudObj[arrayKey]) ? cloudObj[arrayKey] as Object[] : []

    const mergedArr: Object[] = []
    const idMap: Map<string, Object> = new Map()

    // 先用较新一侧初始化（保证同 id 冲突项取较新一端）
    const baseArr: Object[] = cloudNewer ? cloudArr : localArr
    const otherArr: Object[] = cloudNewer ? localArr : cloudArr
    for (let i: number = 0; i < baseArr.length; i++) {
      const item: Object = baseArr[i]
      const id: string = this.extractId(item)
      if (id.length > 0) {
        idMap.set(id, item)
      }
    }
    for (let i: number = 0; i < otherArr.length; i++) {
      const item: Object = otherArr[i]
      const id: string = this.extractId(item)
      if (id.length > 0 && !idMap.has(id)) {
        idMap.set(id, item)
      }
    }
    idMap.forEach((v: Object): void => {
      mergedArr.push(v)
    })

    const mergedObj: Record<string, Object> = {}
    const srcObj: Record<string, Object> = cloudNewer ? cloudObj : localObj
    Object.keys(srcObj).forEach((key: string): void => {
      if (key !== arrayKey) {
        mergedObj[key] = srcObj[key]
      }
    })
    mergedObj[arrayKey] = mergedArr

    return JSON.stringify(mergedObj)
  }

  /**
   * 从快照数组元素中提取 id（用于并集合并去重）
   */
  private extractId(item: Object): string {
    const idVal: Object | undefined = (item as Record<string, Object>)['id']
    if (typeof idVal === 'string') return idVal as string
    if (typeof idVal === 'number') return (idVal as number).toString()
    return ''
  }

  /**
   * 智能同步（手动上传 + 强制下载 + 并集合并策略）
   *
   * 策略说明：
   *   - direction='upload'：强制上传本地数据覆盖云端（手动点击"立即同步"按钮触发）
   *     不下载云端，不比较时间戳，直接 upload
   *   - direction='download'：强制下载云端数据覆盖本地（App启动/多端协同/登录后触发）
   *     不上传本地，云端为 null 时跳过（首次使用无云端数据）
   *   - direction='merge'：并集合并（多端协同默认方向，方案A）
   *     下载云端 + 按 id 并集合并 goals/todos，两端独有数据都保留，
   *     同 id 冲突取整包 updatedAt 较新一端；settings/profile 以较新整包为准；
   *     合并结果写回本地并回传云端，保证两端最终一致
   *
   * @param uid - 用户唯一标识
   * @param data - 本地数据快照
   * @param callback - 应用云端数据的回调
   * @param direction - 同步方向：'upload' 强制上传 | 'download' 强制下载 | 'merge' 并集合并
   * @param force - 手动同步传 true 跳过脏检查，自动防抖传 false
   * @returns SyncResult
   */
  async smartSync(uid: string, data: SyncDataBundle, callback: SyncApplyCallback,
    direction: SyncDirection, force: boolean = false): Promise<SyncResult> {
    const result: SyncResult = { success: false, direction: 'none', errorMsg: '' }
    if (uid.length === 0) { result.errorMsg = 'uid is empty'; return result }
    if (this.isSyncing) { result.errorMsg = 'sync already in progress'; return result }

    this.isSyncing = true

    const dbService: CloudDBService = CloudDBService.getInstance()
    if (!dbService.isInitialized()) {
      result.errorMsg = 'CloudDB not initialized'
      this.isSyncing = false
      return result
    }

    try {
      if (direction === 'upload') {
        // 手动上传：强制上传覆盖云端，自动同步时脏检查跳过未变内容
        let needUpload: boolean = true
        if (!force) {
          needUpload = this.shouldUpload(uid, data)
        }
        if (!needUpload) {
          result.success = true
          result.direction = 'upload'
          Logger.info(CloudSyncService.tag, 'smartSync: content unchanged, dirty check skip upload.')
        } else {
          const ok: boolean = await this.upload(uid, data)
          if (ok) {
            result.success = true
            result.direction = 'upload'
            // 上传成功后更新指纹，保证后续自动同步能正确走脏检查
            this.lastUploadedFingerprint = this.buildFingerprint(uid, data)
            callback.updateLastSyncTime(data.lastSyncTime)
            Logger.info(CloudSyncService.tag, 'smartSync: forced upload, local overwrites cloud.')
          } else {
            // 异常透出：CloudDBService.lastError 携带 upsert 真实失败原因，供 UI 直接显示
            const realError: string = dbService.lastError
            result.errorMsg = realError.length > 0 ? ('upload failed: ' + realError) : 'upload failed'
            result.direction = 'error'
          }
        }
      } else if (direction === 'merge') {
        // 多端协同并集合并：下载云端 + 按 id 并集合并，两端独有数据都保留
        // 冲突保护：不无条件用云端覆盖本地，本地独有目标/待办不会被云端旧数据冲掉
        let cloudRecord: UserSyncRecord | null = null
        let downloadError: string = ''
        try {
          cloudRecord = await dbService.downloadRecord(uid)
        } catch (e) {
          downloadError = (e as Error).message
        }

        if (downloadError.length > 0) {
          // 查询失败 ≠ 云端无数据：禁止触发"首传覆盖"，否则弱网/服务异常会拿本地数据覆盖云端旧记录
          result.success = false
          result.direction = 'error'
          const realError: string = dbService.lastError
          result.errorMsg = realError.length > 0
            ? ('merge download failed: ' + realError)
            : ('merge download failed: ' + downloadError)
          Logger.error(CloudSyncService.tag, 'smartSync merge: download failed, abort merge. ' + result.errorMsg)
          return result
        }

        if (cloudRecord === null) {
          // 云端无数据（首次使用）：本地数据作为权威上传，形成首份云端记录
          const ok: boolean = await this.upload(uid, data)
          if (ok) {
            result.success = true
            result.direction = 'merge'
            this.lastUploadedFingerprint = this.buildFingerprint(uid, data)
            callback.updateLastSyncTime(data.lastSyncTime)
            Logger.info(CloudSyncService.tag, 'smartSync merge: cloud null, upload local as first record.')
          } else {
            const realError: string = dbService.lastError
            result.errorMsg = realError.length > 0 ? ('merge first upload failed: ' + realError) : 'merge first upload failed'
            result.direction = 'error'
          }
        } else {
          const cloudNewer: boolean = Number(cloudRecord.updatedAt) > data.lastSyncTime
          // 按 id 并集合并 goals / todos（两端独有都保留，同 id 冲突取较新一端）
          const mergedGoals: string = this.mergeIdArrays(data.goalsJson, cloudRecord.goalsJson, 'goals', cloudNewer)
          const mergedTodos: string = this.mergeIdArrays(data.todosJson, cloudRecord.todosJson, 'taskList', cloudNewer)
          // settings / profile 以较新整包为准
          const mergedSettings: string = cloudNewer ? cloudRecord.settingsJson : data.settingsJson
          const mergedProfile: string = cloudNewer ? cloudRecord.profileJson : data.profileJson
          const mergedUpdatedAt: string = cloudNewer ? cloudRecord.updatedAt : Date.now().toString()

          const mergedRecord: UserSyncRecord = {
            uid: uid,
            goalsJson: mergedGoals,
            todosJson: mergedTodos,
            settingsJson: mergedSettings,
            profileJson: mergedProfile,
            updatedAt: mergedUpdatedAt
          }
          // applyCloudData 返回 false 表示预解析失败（原子性保护，本地未被修改）
          const applied: boolean = this.applyCloudData(mergedRecord, callback)
          if (!applied) {
            result.success = false
            result.direction = 'error'
            result.errorMsg = 'cloud data parse failed, local data kept intact'
            Logger.error(CloudSyncService.tag, 'smartSync merge: cloud data parse failed, local kept intact.')
          } else {
            // 回传合并结果到云端（保证两端一致，防止下次被旧云端数据覆盖）
            callback.updateLastSyncTime(Number(mergedUpdatedAt))
            const mergedBundle: SyncDataBundle = {
              goalsJson: mergedGoals,
              todosJson: mergedTodos,
              settingsJson: mergedSettings,
              profileJson: mergedProfile,
              lastSyncTime: Number(mergedUpdatedAt),
              forceUpload: false
            }
            const uploadOk: boolean = await this.upload(uid, mergedBundle)
            if (uploadOk) {
              this.lastUploadedFingerprint = this.buildFingerprint(uid, mergedBundle)
              result.success = true
              result.direction = 'merge'
              Logger.info(CloudSyncService.tag, 'smartSync merge: union merged, applied locally and pushed back.')
            } else {
              // 本地已合并成功，回传云端失败不视为致命错误（下次自动同步会补）
              result.success = true
              result.direction = 'merge'
              Logger.warn(CloudSyncService.tag, 'smartSync merge: applied locally but push-back failed: ' + dbService.lastError)
            }
          }
        }
      } else {
        // 自动下载：强制下载云端数据覆盖本地，不上传本地
        let cloudRecord: UserSyncRecord | null = null
        let downloadError: string = ''
        try {
          cloudRecord = await dbService.downloadRecord(uid)
        } catch (e) {
          downloadError = (e as Error).message
        }

        if (downloadError.length > 0) {
          // 查询失败 ≠ 云端无数据：失败时保留本地数据并按错误上报，等待下次重试
          result.success = false
          result.direction = 'error'
          const realError: string = dbService.lastError
          result.errorMsg = realError.length > 0
            ? ('download failed: ' + realError)
            : ('download failed: ' + downloadError)
          Logger.error(CloudSyncService.tag, 'smartSync: download failed, local kept intact. ' + result.errorMsg)
        } else if (cloudRecord === null) {
          // 云端无数据（首次使用），跳过下载，保留本地数据
          result.success = true
          result.direction = 'download'
          Logger.info(CloudSyncService.tag, 'smartSync: cloud is null, skip download (first use).')
        } else {
          // applyCloudData 返回 false 表示预解析失败（原子性保护，本地未被修改）
          const applied: boolean = this.applyCloudData(cloudRecord, callback)
          if (!applied) {
            result.success = false
            result.direction = 'error'
            result.errorMsg = 'cloud data parse failed, local data kept intact'
            Logger.error(CloudSyncService.tag, 'smartSync: cloud data parse failed, local kept intact.')
          } else {
            callback.updateLastSyncTime(Number(cloudRecord.updatedAt))
            result.success = true
            result.direction = 'download'
            Logger.info(CloudSyncService.tag, 'smartSync: forced download, cloud overwrites local.')
          }
        }
      }

      return result
    } catch (e) {
      result.errorMsg = (e as Error).message
      result.direction = 'error'
      return result
    } finally {
      this.isSyncing = false
    }
  }

  scheduleSync(uid: string, data: SyncDataBundle, direction: SyncDirection,
    callback?: SyncApplyCallback): void {
    if (uid.length === 0 || this.isSyncing) return
    if (this.syncTimer !== -1) clearTimeout(this.syncTimer)
    const snapshot: SyncDataBundle = {
      goalsJson: data.goalsJson,
      todosJson: data.todosJson,
      settingsJson: data.settingsJson,
      profileJson: data.profileJson,
      lastSyncTime: data.lastSyncTime,
      forceUpload: data.forceUpload
    }
    this.syncTimer = setTimeout((): void => {
      if (callback) {
        this.smartSync(uid, snapshot, callback, direction).catch((e: Error): void => {
          Logger.error(CloudSyncService.tag, 'scheduled smartSync failed: ' + e.message)
        })
      } else {
        this.upload(uid, snapshot).catch((e: Error): void => {
          Logger.error(CloudSyncService.tag, 'scheduled sync failed: ' + e.message)
        })
      }
    }, 2000)
  }

  async flush(uid: string, data: SyncDataBundle): Promise<void> {
    if (this.syncTimer !== -1) { clearTimeout(this.syncTimer); this.syncTimer = -1 }
    if (uid.length > 0) await this.upload(uid, data)
  }

  destroy(): void {
    if (this.syncTimer !== -1) {
      clearTimeout(this.syncTimer)
      this.syncTimer = -1
    }
    Logger.info(CloudSyncService.tag, 'destroy: syncTimer cleared')
  }
}