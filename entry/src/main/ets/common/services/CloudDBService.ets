/**
 * @file CloudDB 极简同步服务
 * @description 直接使用 CloudDB 的 Text 类型存储大 JSON，无需云存储。
 */
import { cloudDatabase } from '@kit.CloudFoundationKit'
import { common } from '@kit.AbilityKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { Logger } from '../utils/Logger'

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
      Logger.info(TAG, 'CloudDBService 初始化成功')
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
    try {
      const obj = new UserSyncData()
      obj.uid = record.uid
      obj.goalsJson = record.goalsJson
      obj.todosJson = record.todosJson
      obj.settingsJson = record.settingsJson
      obj.profileJson = record.profileJson
      obj.updatedAt = record.updatedAt

      const result: number = await this.dbZone.upsert([obj])
      this._lastError = ''
      Logger.info(TAG, `uploadRecord 成功，影响行数: ${result}`)
      return result > 0
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
    try {
      const query = new cloudDatabase.DatabaseQuery<UserSyncData>(UserSyncData)
      query.equalTo('uid', uid)
      const objects: UserSyncData[] = await this.dbZone.query(query)
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
}
