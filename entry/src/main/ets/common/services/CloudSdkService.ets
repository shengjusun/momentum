/**
 * @file 云端 SDK 聚合初始化服务
 * @description 收口所有云端依赖（AGC auth / CloudFoundationKit / CloudDB）的初始化。
 *              隐私合规要求：云端 SDK 必须在用户同意《隐私协议》之后才能初始化，
 *              EntryAbility 冷启动只做本地初始化；同意后由本服务统一拉起云端链路。
 *              幂等 + 并发安全：重复调用共享同一次初始化，失败后允许重试。
 */
import { common } from '@kit.AbilityKit'
import { buffer } from '@kit.ArkTS'
import auth from '@hw-agconnect/auth'
import { cloudCommon } from '@kit.CloudFoundationKit'
import { Logger } from '../utils/Logger'
import { CloudSyncService } from './CloudSyncService'
import { CloudDBService } from './CloudDBService'

export class CloudSdkService {
  private static readonly TAG: string = 'CloudSdkService'
  private static instance: CloudSdkService | null = null
  private initialized: boolean = false
  /** 进行中的初始化 Promise：并发调用共享同一次初始化，避免重复拉起 */
  private initPromise: Promise<boolean> | null = null

  private constructor() {}

  static getInstance(): CloudSdkService {
    if (CloudSdkService.instance === null) {
      CloudSdkService.instance = new CloudSdkService()
    }
    return CloudSdkService.instance
  }

  isInitialized(): boolean {
    return this.initialized
  }

  /**
   * 初始化云端 SDK 链（幂等 + 并发安全）：
   * 1. AGC auth：读取 rawfile/agconnect-services.json（否则 LoginPage 的 auth.signIn 不可用）
   * 2. CloudFoundationKit：注入 authProvider（否则 cloudFunction 调用报 AuthProvider has not value）
   * 3. CloudDB：经 CloudSyncService.init 转发 CloudDBService.init，保持原初始化入口
   *
   * @returns true 表示 CloudDB 就绪，云端链路可用
   */
  async init(context: common.Context): Promise<boolean> {
    if (this.initialized) {
      return true
    }
    if (this.initPromise !== null) {
      return this.initPromise
    }
    this.initPromise = this.doInit(context)
    const ok: boolean = await this.initPromise
    if (!ok) {
      // 失败允许下次重试：清空 in-flight 标记
      this.initPromise = null
    }
    return ok
  }

  private async doInit(context: common.Context): Promise<boolean> {
    Logger.info(CloudSdkService.TAG, 'cloud sdk init START')

    // 1. AGC auth SDK
    try {
      const raw: Uint8Array = context.resourceManager.getRawFileContentSync('agconnect-services.json')
      const jsonStr: string = buffer.from(raw.buffer as ArrayBufferLike).toString('utf8')
      auth.init(context, jsonStr)
      Logger.info(CloudSdkService.TAG, 'AGC auth SDK initialized')
    } catch (e) {
      Logger.error(CloudSdkService.TAG, 'AGC auth SDK init failed: ' + (e as Error).message)
    }

    // 2. CloudFoundationKit
    try {
      cloudCommon.init({
        region: cloudCommon.CloudRegion.CHINA,
        authProvider: auth.getAuthProvider()
      })
      Logger.info(CloudSdkService.TAG, 'CloudFoundationKit initialized')
    } catch (e) {
      Logger.error(CloudSdkService.TAG, 'CloudFoundationKit init failed: ' + (e as Error).message)
    }

    // 3. CloudDB（经 CloudSyncService 转发）
    const dbOk: boolean = await CloudSyncService.getInstance().init(context)
    if (!dbOk) {
      Logger.error(CloudSdkService.TAG,
        'CloudDB init failed, lastError=' + CloudDBService.getInstance().lastError)
      return false
    }

    this.initialized = true
    Logger.info(CloudSdkService.TAG, 'cloud sdk chain initialized successfully')
    return true
  }

  /** 销毁云端资源（EntryAbility.onDestroy 调用） */
  destroy(): void {
    CloudDBService.getInstance().destroy()
    this.initialized = false
    this.initPromise = null
    Logger.info(CloudSdkService.TAG, 'cloud sdk destroyed')
  }
}
