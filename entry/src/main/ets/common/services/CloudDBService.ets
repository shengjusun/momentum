/**
 * @file CloudDB 极简同步服务
 * @description 直接使用 CloudDB 的 Text 类型存储大 JSON，无需云存储。
 */
import { cloudDatabase } from '@kit.CloudFoundationKit'
import { common } from '@kit.AbilityKit'
import { BusinessError } from '@kit.BasicServicesKit'
import auth from '@hw-agconnect/auth';
import { Logger } from '../utils/Logger'
import { AgcAuthService } from './AgcAuthService'

const ZONE_NAME: string = 'GrowthDeskZone'
const TAG: string = 'CloudDBService'

export interface UserSyncRecord {
  uid: string
  goalsJson: string
  todosJson: string
  settingsJson: string
  profileJson: string
  updatedAt: string
}

export class UserSyncData extends cloudDatabase.DatabaseObject {
  public uid: string = ''
  public goalsJson: string = ''
  public todosJson: string = ''
  public settingsJson: string = ''
  public profileJson: string = ''
  public updatedAt: string = ''

  constructor() { super() }
  public naturalbase_ClassName(): string { return 'UserSyncData' }
}

/**
 * 用户反馈记录（对应 AGC 云数据库对象类型 UserFeedback）
 * 注意：content / diagJson / imageUrls 在云端必须是 Text 类型（String 上限仅 200 字符）；
 *      主键 feedbackId 必须是 String（Text 不能作主键）。
 */
export interface UserFeedbackRecord {
  feedbackId: string
  userId: string
  content: string
  category: string
  appVersion: string
  deviceModel: string
  osVersion: string
  diagJson: string
  contact: string
  status: number
  createTime: number
  imageUrls: string
}

/** 对象类型名必须与控制台部署的 'UserFeedback' 完全一致，否则 upsert 报 1006001 */
export class UserFeedback extends cloudDatabase.DatabaseObject {
  public feedbackId: string = ''
  public userId: string = ''
  public content: string = ''
  public category: string = ''
  public appVersion: string = ''
  public deviceModel: string = ''
  public osVersion: string = ''
  public diagJson: string = ''
  public contact: string = ''
  public status: number = 0
  public createTime: number = 0
  public imageUrls: string = ''

  constructor() { super() }
  public naturalbase_ClassName(): string { return 'UserFeedback' }
}

export class CloudDBService {
  private static instance: CloudDBService | null = null
  private dbZone: cloudDatabase.DatabaseZone | null = null
  private initialized: boolean = false
  /** 最近一次操作失败的真实异常信息（供上层只读访问，避免外部覆盖） */
  private _lastError: string = ''

  get lastError(): string { return this._lastError }

  private constructor() {}

  /** 打印当前 AGC 认证身份，用于排查 CloudDB 请求是否携带有效已认证用户 */
  private async logAuthState(who: string): Promise<void> {
    try {
      const user = await auth.getCurrentUser()
      if (user === null || user === undefined) {
        Logger.warn(TAG, `[${who}] AGC 当前无登录用户（getCurrentUser=null）——请求将按匿名处理，CloudDB 会判"所有人"权限(2001015)`);
        return
      }
      // user.getUid() 不一定全部实现，统一 try 包住，拿不到也不阻塞
      Logger.info(TAG, `[${who}] AGC 当前用户已登录, uid=${user.getUid() ?? 'N/A'}`)
    } catch (e) {
      Logger.warn(TAG, `[${who}] 读取 AGC 当前用户异常: ` + (e as Error).message)
    }
  }

  /**
   * 判据：AGC 会话被**服务端拒绝**（需重建会话后重试）
   *
   * 典型报文：`code=1008231001, msg=401:205524994:third access token auth failed`
   * 与"本地无会话"必须区分：无会话时 ensureSignedIn() 已提前中止并给出
   * `CloudDB auth unavailable`，不会走到服务端，因此不会命中本判据。
   *
   * 为什么单靠本地判断不够：ensureSignedIn() 只判 getCurrentUser() 是否非空，
   * **不校验 token 有效性** —— 会话存在但已被服务端作废时，只有真正发出请求才会暴露。
   */
  private isAgcSessionRejected(e: Error): boolean {
    const be: BusinessError = e as BusinessError
    const msg: string = be.message !== undefined && be.message !== null ? be.message : ''
    return be.code === 1008231001 &&
      (msg.indexOf('auth failed') >= 0 || msg.indexOf('401') >= 0)
  }

  /**
   * 鉴权自愈：清掉本地僵尸会话 → 用华为账号重建会话 → 供调用方重试一次
   *
   * 修复的真实故障：手机上 AGC 会话 token 被服务端拒绝后，因项目从不调用
   * `auth.signOut()`，缓存 user 永远非空 → signIn 分支永不执行 → 云端永久 401，
   * 且 App 内"退出登录再登录"也无效，只能卸载重装。现在由代码自行重建。
   *
   * @returns true 表示新会话已建立，可重试原请求
   */
  private async healAgcSession(who: string): Promise<boolean> {
    Logger.warn(TAG, who + ' 命中 AGC 会话被拒(1008231001)，重建会话后重试一次')
    await AgcAuthService.resetSession()
    const ok: boolean = await AgcAuthService.ensureSignedIn()
    if (!ok) {
      Logger.error(TAG, who + ' AGC 会话重建失败，放弃重试（请检查华为账号登录态与网络）')
    }
    return ok
  }

  static getInstance(): CloudDBService {
    if (CloudDBService.instance === null) {
      CloudDBService.instance = new CloudDBService()
    }
    return CloudDBService.instance
  }

  async init(context: common.Context): Promise<boolean> {
    if (this.initialized) return true
    try {
      this.dbZone = cloudDatabase.zone(ZONE_NAME)
      this.initialized = true
      Logger.info(TAG, 'CloudDBService 初始化成功, zone=' + ZONE_NAME)
      await this.logAuthState('init')
    } catch (e) {
      // ============================================================
      // CloudDB 初始化异常解析
      // - BusinessError.code    : 核心错误码（如 1006001/1006003）
      // - BusinessError.message : 英文错误描述
      // - JSON.stringify(err)   : 完整错误对象（含 details/data 等附加字段）
      // ============================================================
      const err: BusinessError = e as BusinessError
      this.initialized = false
      this._lastError = 'code=' + err.code.toString() + ', msg=' + err.message
      Logger.error(TAG, 'CloudDBService 初始化失败 code=' + err.code.toString() + ', msg=' + err.message)
      Logger.error(TAG, 'CloudDBService 初始化完整错误对象: ' + JSON.stringify(err))
    }
    return this.initialized
  }

  isInitialized(): boolean { return this.initialized }

  destroy(): void {
    this.dbZone = null
    this.initialized = false
  }

  /** @param retried - 内部重试标记（鉴权自愈后只重试一次，调用方无需传） */
  async uploadRecord(record: UserSyncRecord, retried: boolean = false): Promise<boolean> {
    if (!this.initialized || this.dbZone === null) return false
    Logger.info(TAG, `uploadRecord 开始: uid='${record.uid}', updatedAt='${record.updatedAt}', json大小 goals=${record.goalsJson.length}, todos=${record.todosJson.length}, settings=${record.settingsJson.length}, profile=${record.profileJson.length}`)
    await this.logAuthState('uploadRecord')
    // 关键：无 AGC 登录会话时请求会按 World 角色被判无权限(2001015)，先补建会话再上传
    if (!await AgcAuthService.ensureSignedIn()) {
      this._lastError = 'AGC not signed in (CloudDB will reject as World role, rescode 2001015)'
      Logger.error(TAG, 'uploadRecord 中止：AGC 未登录，云端会按匿名身份拒绝')
      return false
    }
    try {
      const obj = new UserSyncData()
      obj.uid = record.uid
      obj.goalsJson = record.goalsJson
      obj.todosJson = record.todosJson
      obj.settingsJson = record.settingsJson
      obj.profileJson = record.profileJson
      obj.updatedAt = record.updatedAt

      // 返回值语义（以 SDK 声明为准，勿凭猜测改）：
      //   upsert(objectList: T[] | T): Promise<number>
      //   "returns the number of records that are successfully upsert"
      // 即【成功写入的记录条数】，不是错误码。
      // 失败一律以 BusinessError 抛出（1008230001 网络 / 1008230002 schema /
      // 1008230003 对象类型 / 1008231001 服务端），由下方 catch 兜底，
      // 不会以数字形式出现在返回值里 —— 因此不存在"200xxx 返回值被 >0 误判成功"的情况。
      // 本方法固定写入 1 条：written > 0 即成功；written === 0 表示未抛异常但一条都没写进去。
      const written: number = await this.dbZone.upsert([obj])
      const ok: boolean = written > 0
      if (ok) {
        this._lastError = ''
      } else {
        // 失败路径必须留下原因，否则上层拿到的 _lastError 为空、无法定位
        this._lastError = 'upsert wrote 0 records without throwing (CloudDB returned 0)'
      }
      Logger.info(TAG, `uploadRecord 写入条数 written=${written} => ${ok ? '成功' : '失败'}`)
      return ok
    } catch (e) {
      // ============================================================
      // CloudDB upsert 异常解析（同步失败的唯一可靠排查入口）
      // ------------------------------------------------------------
      // BusinessError.code    : 核心错误码，形如 1006001 / 1006003
      // BusinessError.message : 英文错误描述
      // JSON.stringify(err)   : 完整错误对象，可能含 details/data 等附加字段
      //
      // 已知错误码：
      //   1006001 : 对象类型（Object Type）不存在 / 未部署
      //             → 检查 AGC 控制台是否已创建并"部署" UserSyncData，
      //               名称须与 naturalbase_ClassName() 返回的 'UserSyncData' 完全一致
      //   1006003 : 对象类型字段不匹配（字段名/类型与云端 schema 不一致）
      //             → 逐字段比对 App 端 UserSyncData 与控制台字段类型
      // ============================================================
      const err: BusinessError = e as BusinessError
      // 鉴权被服务端拒绝（僵尸会话）→ 重建会话后重试一次
      if (!retried && this.isAgcSessionRejected(e as Error) &&
        await this.healAgcSession('uploadRecord')) {
        return await this.uploadRecord(record, true)
      }
      this._lastError = 'code=' + err.code.toString() + ', msg=' + err.message
      Logger.error(TAG, 'uploadRecord 抛出异常 code=' + err.code.toString() + ', msg=' + err.message)
      Logger.error(TAG, 'uploadRecord 完整错误对象: ' + JSON.stringify(err))
      return false
    }
  }

  /**
   * 下载云端同步记录（返回语义已严格区分，调用方必须遵守）：
   * - 返回 null : 查询成功但云端无记录（真正的"首次使用"）
   * - 抛出异常  : 查询本身失败（未初始化/网络/服务异常/对象类型未部署）
   *               调用方必须按"同步失败"处理，严禁把失败当作"云端无数据"
   *               （否则弱网下会误触发首传，用本地旧数据覆盖云端）
   */
  /** @param retried - 内部重试标记（鉴权自愈后只重试一次，调用方无需传） */
  async downloadRecord(uid: string, retried: boolean = false): Promise<UserSyncRecord | null> {
    if (!this.initialized || this.dbZone === null) {
      throw new Error('CloudDB not initialized')
    }
    Logger.info(TAG, `downloadRecord 开始: uid='${uid}'`)
    await this.logAuthState('downloadRecord')
    // 关键：无 AGC 登录会话时请求会按 World 角色被判无权限(2001015)，先补建会话再查询
    if (!await AgcAuthService.ensureSignedIn()) {
      this._lastError = 'AGC not signed in (CloudDB will reject as World role, rescode 2001015)'
      Logger.error(TAG, 'downloadRecord 中止：AGC 未登录，云端会按匿名身份拒绝')
      throw new Error('CloudDB auth unavailable: ' + this._lastError)
    }
    try {
      const query = new cloudDatabase.DatabaseQuery<UserSyncData>(UserSyncData)
      query.equalTo('uid', uid)
      const objects: UserSyncData[] = await this.dbZone.query(query)
      Logger.info(TAG, `downloadRecord 查询返回 ${objects.length} 条 (uid='${uid}')`)
      if (objects.length === 0) return null

      const obj = objects[0]
      return {
        uid: obj.uid,
        goalsJson: obj.goalsJson,
        todosJson: obj.todosJson,
        settingsJson: obj.settingsJson,
        profileJson: obj.profileJson,
        updatedAt: obj.updatedAt
      }
    } catch (e) {
      // ============================================================
      // CloudDB query 异常解析（与 uploadRecord 相同规则）
      // - code=1006001 : 对象类型不存在/未部署
      // - code=1006003 : 字段不匹配
      // 失败必须向上抛出，禁止返回 null 与"云端无数据"混淆
      // ============================================================
      const err: BusinessError = e as BusinessError
      // 鉴权被服务端拒绝（僵尸会话）→ 重建会话后重试一次
      if (!retried && this.isAgcSessionRejected(e as Error) &&
        await this.healAgcSession('downloadRecord')) {
        return await this.downloadRecord(uid, true)
      }
      this._lastError = 'code=' + err.code.toString() + ', msg=' + err.message
      Logger.error(TAG, 'downloadRecord 抛出异常 code=' + err.code.toString() + ', msg=' + err.message)
      Logger.error(TAG, 'downloadRecord 完整错误对象: ' + JSON.stringify(err))
      // ArkTS 限制 throw 只能抛 Error 及其子类：把 BusinessError 信息包装成 Error 向上传递
      const wrapped: Error = new Error('CloudDB query failed: ' + this._lastError)
      throw wrapped
    }
  }

  /**
   * 删除云端同步记录（设置页"一键删除所有数据"专用）
   * - 云端本无记录：直接返回 true（"云端无该记录"的目标状态已达成）
   * - 查询/删除异常：返回 false，调用方按失败处理并提示用户
   */
  /** @param retried - 内部重试标记（鉴权自愈后只重试一次，调用方无需传） */
  async deleteRecord(uid: string, retried: boolean = false): Promise<boolean> {
    if (!this.initialized || this.dbZone === null) {
      Logger.warn(TAG, 'deleteRecord: CloudDB not initialized')
      return false
    }
    Logger.info(TAG, `deleteRecord 开始: uid='${uid}'`)
    await this.logAuthState('deleteRecord')
    // 关键：无 AGC 登录会话时请求会按 World 角色被判无权限(2001015)，先补建会话再删除
    if (!await AgcAuthService.ensureSignedIn()) {
      this._lastError = 'AGC not signed in (CloudDB will reject as World role, rescode 2001015)'
      Logger.error(TAG, 'deleteRecord 中止：AGC 未登录，云端会按匿名身份拒绝')
      return false
    }
    try {
      const query = new cloudDatabase.DatabaseQuery<UserSyncData>(UserSyncData)
      query.equalTo('uid', uid)
      const objects: UserSyncData[] = await this.dbZone.query(query)
      if (objects.length === 0) {
        Logger.info(TAG, `deleteRecord: cloud has no record (uid='${uid}'), treat as success`)
        return true
      }
      const result: number = await this.dbZone.delete(objects)
      Logger.info(TAG, `deleteRecord 删除返回 raw=${result}`)
      this._lastError = ''
      // 无异常即视为达成"云端无该记录"目标
      //（raw=0 仅出现在并发删除竞态，此时目标状态同样已达成）
      return true
    } catch (e) {
      const err: BusinessError = e as BusinessError
      // 鉴权被服务端拒绝（僵尸会话）→ 重建会话后重试一次
      if (!retried && this.isAgcSessionRejected(e as Error) &&
        await this.healAgcSession('deleteRecord')) {
        return await this.deleteRecord(uid, true)
      }
      this._lastError = 'code=' + err.code.toString() + ', msg=' + err.message
      Logger.error(TAG, 'deleteRecord 抛出异常 code=' + err.code.toString() + ', msg=' + err.message)
      Logger.error(TAG, 'deleteRecord 完整错误对象: ' + JSON.stringify(err))
      return false
    }
  }

  /**
   * 提交用户反馈（写入 UserFeedback 对象类型）
   * 前置：AGC 控制台已创建并部署 UserFeedback，且 Authenticated 角色具备 Upsert 权限
   * 失败不抛异常，统一返回 false，由调用方决定是否本地暂存重试
   * @param record - 反馈记录
   * @returns true 表示已成功写入云端
   */
  /** @param retried - 内部重试标记（鉴权自愈后只重试一次，调用方无需传） */
  async addFeedback(record: UserFeedbackRecord, retried: boolean = false): Promise<boolean> {
    if (!this.initialized || this.dbZone === null) {
      this._lastError = 'CloudDB not initialized'
      Logger.warn(TAG, 'addFeedback: CloudDB not initialized')
      return false
    }
    await this.logAuthState('addFeedback')
    // 与同步链路一致：无 AGC 会话时请求会按 World 角色被拒(2001015)，先补建会话再写入
    if (!await AgcAuthService.ensureSignedIn()) {
      this._lastError = 'AGC not signed in (CloudDB will reject as World role, rescode 2001015)'
      Logger.error(TAG, 'addFeedback 中止：AGC 未登录，云端会按匿名身份拒绝')
      return false
    }
    try {
      const obj = new UserFeedback()
      obj.feedbackId = record.feedbackId
      obj.userId = record.userId
      obj.content = record.content
      obj.category = record.category
      obj.appVersion = record.appVersion
      obj.deviceModel = record.deviceModel
      obj.osVersion = record.osVersion
      obj.diagJson = record.diagJson
      obj.contact = record.contact
      obj.status = record.status
      obj.createTime = record.createTime
      obj.imageUrls = record.imageUrls

      const written: number = await this.dbZone.upsert([obj])
      const ok: boolean = written > 0
      if (ok) {
        this._lastError = ''
      } else {
        this._lastError = 'upsert wrote 0 records without throwing (CloudDB returned 0)'
      }
      Logger.info(TAG, `addFeedback 写入条数 written=${written} => ${ok ? '成功' : '失败'}`)
      return ok
    } catch (e) {
      // 常见错误码：1006001 对象类型不存在/未部署；1006003 字段名或类型与云端不一致
      const err: BusinessError = e as BusinessError
      // 鉴权被服务端拒绝（僵尸会话）→ 重建会话后重试一次
      if (!retried && this.isAgcSessionRejected(e as Error) &&
        await this.healAgcSession('addFeedback')) {
        return await this.addFeedback(record, true)
      }
      this._lastError = 'code=' + err.code.toString() + ', msg=' + err.message
      Logger.error(TAG, 'addFeedback 抛出异常 code=' + err.code.toString() + ', msg=' + err.message)
      return false
    }
  }
}
