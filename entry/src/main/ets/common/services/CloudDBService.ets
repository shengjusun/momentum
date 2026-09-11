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

  async uploadRecord(record: UserSyncRecord): Promise<boolean> {
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

      // 关键：upsert 的返回值是"同步结果码"，不是行数。
      // 拿到后【原样记录】，便于和 SDK 层日志(如 2001015)对号入座
      const result: number = await this.dbZone.upsert([obj])
      this._lastError = ''
      Logger.info(TAG, `uploadRecord 原始返回值 raw=${result} (0->失败/无操作, >0->成功或状态码, 若出现 200xxx 多为云端同步异常码)`);
      // FIXME 临时诊断日志：明确暴露 raw 值，避免被 >0 误判掩盖
      const ok: boolean = result > 0
      Logger.info(TAG, `uploadRecord 判定: result>0 => ${ok}，当前 raw=${result}`);
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
  async downloadRecord(uid: string): Promise<UserSyncRecord | null> {
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
  async deleteRecord(uid: string): Promise<boolean> {
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
      this._lastError = 'code=' + err.code.toString() + ', msg=' + err.message
      Logger.error(TAG, 'deleteRecord 抛出异常 code=' + err.code.toString() + ', msg=' + err.message)
      Logger.error(TAG, 'deleteRecord 完整错误对象: ' + JSON.stringify(err))
      return false
    }
  }
}
