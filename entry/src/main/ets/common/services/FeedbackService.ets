/**
 * @file 用户反馈服务
 * @description
 *   组装运行诊断信息 → 写入 AGC 云数据库对象类型 UserFeedback。
 *   - 前置：① 已同意《隐私协议》（CloudSdkService 已初始化）② 已登录华为账号
 *   - 提交失败（无网 / 服务异常 / AGC 会话缺失）自动落入本地暂存队列，
 *     下次进入反馈页或应用回前台时自动补传，避免用户输入丢失
 *   - 分层约束：本服务不反向依赖 viewmodel，用户身份与数据统计由调用方（页面）注入
 */

import { bundleManager } from '@kit.AbilityKit'
import { deviceInfo } from '@kit.BasicServicesKit'
import { util } from '@kit.ArkTS'
import { CloudDBService, UserFeedbackRecord } from './CloudDBService'
import { CloudSdkService } from './CloudSdkService'
import { StorageManager } from '../utils/StorageManager'
import { CommonConstants } from '../constants/CommonConstants'
import { Logger } from '../utils/Logger'

const TAG: string = 'FeedbackService'

/** 提交结果 */
export interface FeedbackSubmitResult {
  /** 已成功写入云端 */
  success: boolean
  /** 已本地暂存，待联网后补传 */
  queued: boolean
  /** 需要用户先登录 */
  needLogin: boolean
  /** 失败原因（供日志排查，不直接展示给用户） */
  errorMsg: string
}

/** 运行诊断信息（由页面注入，避免 common 层依赖 viewmodel） */
export interface FeedbackDiagnostics {
  goalsCount: number
  todosCount: number
  syncEnabled: boolean
}

/** 提交入参 */
export interface FeedbackSubmitInput {
  content: string
  category: string
  contact: string
  /** 当前登录用户 uid；未登录传空字符串 */
  userId: string
  isLoggedIn: boolean
  diagnostics: FeedbackDiagnostics
}

/** 诊断信息落库结构（强类型，避免 ArkTS 对 Record 宽松类型的限制） */
interface FeedbackDiagnosticsJson {
  appVersion: string
  deviceModel: string
  osVersion: string
  goalsCount: number
  todosCount: number
  syncEnabled: boolean
  ts: number
}

export class FeedbackService {
  private static instance: FeedbackService | null = null
  /** 补传进行中标志：避免并发重复补传 */
  private flushing: boolean = false

  private constructor() {}

  static getInstance(): FeedbackService {
    if (FeedbackService.instance === null) {
      FeedbackService.instance = new FeedbackService()
    }
    return FeedbackService.instance
  }

  /** 由页面注入的入参组装成云端记录（版本/机型/系统只读取一次，复用到独立列与诊断 JSON） */
  private async buildRecord(input: FeedbackSubmitInput): Promise<UserFeedbackRecord> {
    let versionName: string = ''
    try {
      const info = await bundleManager.getBundleInfoForSelf(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)
      versionName = info.versionName
    } catch (e) {
      Logger.warn(TAG, 'buildRecord: read version failed')
    }

    let model: string = ''
    let os: string = ''
    try {
      model = deviceInfo.productModel
      os = deviceInfo.osFullName
    } catch (e) {
      Logger.warn(TAG, 'buildRecord: read device info failed')
    }

    const diag: FeedbackDiagnosticsJson = {
      appVersion: versionName,
      deviceModel: model,
      osVersion: os,
      goalsCount: input.diagnostics.goalsCount,
      todosCount: input.diagnostics.todosCount,
      syncEnabled: input.diagnostics.syncEnabled,
      ts: Date.now()
    }

    const record: UserFeedbackRecord = {
      feedbackId: util.generateRandomUUID(),
      userId: input.userId,
      content: input.content,
      category: input.category,
      appVersion: versionName,
      deviceModel: model,
      osVersion: os,
      diagJson: JSON.stringify(diag),
      contact: input.contact,
      status: 0,
      createTime: Date.now(),
      imageUrls: ''
    }
    return record
  }

  /**
   * 提交反馈
   * - 未登录：不入云端也不入队，返回 needLogin 由页面提示登录（输入内容由页面保留）
   * - 云 SDK 未就绪（隐私未同意）/ 写入失败（网络异常）：落本地队列，联网后自动补传
   */
  async submit(input: FeedbackSubmitInput): Promise<FeedbackSubmitResult> {
    const result: FeedbackSubmitResult = {
      success: false, queued: false, needLogin: false, errorMsg: ''
    }

    if (input.content.length === 0) {
      result.errorMsg = 'content is empty'
      return result
    }

    // 未登录：按产品策略既不写云端也不入队——页面会保留输入内容，
    // 用户登录后可再次点击提交，避免"入队 + 手点"导致同一条反馈重复入库
    if (!input.isLoggedIn || input.userId.length === 0) {
      result.needLogin = true
      result.errorMsg = 'not logged in'
      return result
    }

    const record: UserFeedbackRecord = await this.buildRecord(input)

    // 云 SDK 未初始化（隐私协议未同意）：暂存
    if (!CloudSdkService.getInstance().isInitialized()) {
      const queued: boolean = await this.enqueue(record)
      result.queued = queued
      result.errorMsg = 'cloud sdk not initialized'
      return result
    }

    const ok: boolean = await CloudDBService.getInstance().addFeedback(record)
    if (ok) {
      result.success = true
      return result
    }

    // 写入失败（网络/服务异常）：暂存待补传
    const queued: boolean = await this.enqueue(record)
    result.queued = queued
    result.errorMsg = CloudDBService.getInstance().lastError
    return result
  }

  /** 读取本地暂存队列 */
  private async loadQueue(): Promise<Array<UserFeedbackRecord>> {
    if (!StorageManager.isInitialized()) {
      return []
    }
    const raw: Array<UserFeedbackRecord> | null =
      await StorageManager.getPreferenceObject<Array<UserFeedbackRecord>>(
        CommonConstants.STORAGE_KEY_FEEDBACK_QUEUE)
    if (raw === null || !Array.isArray(raw)) {
      return []
    }
    return raw
  }

  /** 写入本地暂存队列 */
  private async saveQueue(queue: Array<UserFeedbackRecord>): Promise<void> {
    if (!StorageManager.isInitialized()) {
      return
    }
    await StorageManager.setPreferenceObject(
      CommonConstants.STORAGE_KEY_FEEDBACK_QUEUE, queue as object)
  }

  /** 入队（同一 feedbackId 去重） */
  private async enqueue(record: UserFeedbackRecord): Promise<boolean> {
    try {
      const queue: Array<UserFeedbackRecord> = await this.loadQueue()
      for (let i: number = 0; i < queue.length; i++) {
        if (queue[i].feedbackId === record.feedbackId) {
          return true
        }
      }
      queue.push(record)
      await this.saveQueue(queue)
      Logger.info(TAG, 'enqueue success, queueSize=' + queue.length.toString())
      return true
    } catch (e) {
      Logger.error(TAG, 'enqueue failed: ' + (e as Error).message)
      return false
    }
  }

  /**
   * 补传暂存队列（串行，遇失败即停，保留剩余项待下次）
   * 触发点：进入反馈页 / 应用回前台 / 登录成功后
   */
  async flushQueue(): Promise<void> {
    if (this.flushing) {
      return
    }
    if (!CloudSdkService.getInstance().isInitialized()) {
      return
    }
    this.flushing = true
    try {
      const queue: Array<UserFeedbackRecord> = await this.loadQueue()
      if (queue.length === 0) {
        return
      }
      Logger.info(TAG, 'flushQueue start, size=' + queue.length.toString())
      const remain: Array<UserFeedbackRecord> = []
      let stopped: boolean = false
      for (let i: number = 0; i < queue.length; i++) {
        const item: UserFeedbackRecord = queue[i]
        if (stopped) {
          remain.push(item)
          continue
        }
        const ok: boolean = await CloudDBService.getInstance().addFeedback(item)
        if (!ok) {
          // 首个失败即停：多为网络整体不可用，继续尝试只会拖慢并刷错误日志
          stopped = true
          remain.push(item)
        }
      }
      if (remain.length !== queue.length) {
        await this.saveQueue(remain)
        Logger.info(TAG, 'flushQueue done, flushed=' +
          (queue.length - remain.length).toString() + ', remain=' + remain.length.toString())
      }
    } catch (e) {
      Logger.error(TAG, 'flushQueue failed: ' + (e as Error).message)
    } finally {
      this.flushing = false
    }
  }

  /** 当前暂存条数（供页面提示"有 N 条待上传"） */
  async getPendingCount(): Promise<number> {
    const queue: Array<UserFeedbackRecord> = await this.loadQueue()
    return queue.length
  }
}
