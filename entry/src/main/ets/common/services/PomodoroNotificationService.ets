// 番茄钟常驻通知栏倒计时服务，使用 notificationManager 展示专注状态并支持点击直达任务详情页

import { notificationManager } from '@kit.NotificationKit'
import { WantAgent } from '@kit.AbilityKit'
import { Logger } from '../utils/Logger'
import { WantAgentFactory } from '../utils/WantAgentFactory'

/**
 * 番茄钟常驻通知服务（单例）
 * 封装 notificationManager 的 publish/cancel 生命周期，失败时仅记录日志不抛异常，确保不阻断番茄钟主流程
 * 每秒更新走 publish 同 ID 覆盖，无需 cancel 再 publish
 */
export class PomodoroNotificationService {
  private static readonly tag: string = 'PomodoroNotificationService'
  private static instance: PomodoroNotificationService | null = null

  /** 通知 ID（固定值 50000，独立区间避免与任务 20000+/目标 30000+ 提醒冲突） */
  private static readonly NOTIFICATION_ID: number = 50000

  /** 更新间隔下限（毫秒），避免每秒 publish 触发系统频控 */
  private static readonly MIN_UPDATE_INTERVAL_MS: number = 900

  private isPublished: boolean = false
  private currentTitle: string = ''
  private currentTaskId: string = ''
  private lastUpdateTime: number = 0
  private context: Context | null = null

  private constructor() {}

  static getInstance(): PomodoroNotificationService {
    if (PomodoroNotificationService.instance === null) {
      PomodoroNotificationService.instance = new PomodoroNotificationService()
    }
    return PomodoroNotificationService.instance
  }

  /**
   * 发布番茄钟常驻通知倒计时
   * isOngoing 保证常驻不可滑动清除，SERVICE_INFORMATION 触发顶部横幅，wantAgent 点击直达任务详情
   */
  async publishCountdown(
    context: Context, taskId: string, taskTitle: string, remainingMillis: number
  ): Promise<void> {
    const title: string = taskTitle.length > 0 ? taskTitle : context.resourceManager.getStringByNameSync('pomo_notif_fallback_title')

    // 容错：若上一轮未正常关闭，先清理
    if (this.isPublished) {
      Logger.info(PomodoroNotificationService.tag,
        'publishCountdown: previous notification still active, cancel first')
      await this.cancelCountdown()
    }

    this.context = context

    try {
      const wantAgent: WantAgent =
        await WantAgentFactory.createTaskDetailWantAgent(context, taskId)
      const formattedTime: string = this.formatTime(remainingMillis)

      const request: notificationManager.NotificationRequest = {
        id: PomodoroNotificationService.NOTIFICATION_ID,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: context.resourceManager.getStringByNameSync('pomo_notif_focus_prefix') + formattedTime,
            text: title,
            additionalText: ''
          }
        } as notificationManager.NotificationContent,
        notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
        wantAgent: wantAgent,
        isOngoing: true
      }

      await notificationManager.publish(request)

      this.isPublished = true
      this.currentTitle = title
      this.currentTaskId = taskId
      this.lastUpdateTime = Date.now()
      Logger.info(PomodoroNotificationService.tag,
        'publishCountdown success, title=' + title +
        ', taskId=' + taskId +
        ', remaining=' + remainingMillis.toString() + 'ms')
    } catch (e) {
      Logger.warn(PomodoroNotificationService.tag,
        'publishCountdown failed: ' + (e as Error).message +
        '（番茄钟主流程不受影响，降级到无通知模式）')
    }
  }

  /**
   * 更新通知栏倒计时文案（每秒触发，频控避免系统限流，状态切换时强制更新）
   * 文案区分专注中/休息中/已暂停三种状态
   */
  async updateCountdown(remainingMillis: number, status: string): Promise<void> {
    if (!this.isPublished || this.context === null) {
      return
    }

    // 频控：距上次更新不足最小间隔且非状态切换时跳过
    const isStatusChange: boolean =
      status === '已暂停' ||
      status.startsWith('休息中') ||
      // 从暂停恢复（上次是暂停，本次不是）
      (this.lastUpdateTime === 0) // 首次更新允许
    const now: number = Date.now()
    if (!isStatusChange && now - this.lastUpdateTime < PomodoroNotificationService.MIN_UPDATE_INTERVAL_MS) {
      return
    }

    try {
      const wantAgent: WantAgent =
        await WantAgentFactory.createTaskDetailWantAgent(this.context, this.currentTaskId)
      const formattedTime: string = this.formatTime(remainingMillis)

      let title: string
      if (status === '已暂停') {
        title = this.context!.resourceManager.getStringByNameSync('pomo_notif_paused_prefix') + formattedTime
      } else if (status.startsWith('休息中')) {
        title = this.context!.resourceManager.getStringByNameSync('pomo_notif_rest_prefix') + formattedTime
      } else {
        title = this.context!.resourceManager.getStringByNameSync('pomo_notif_focus_prefix') + formattedTime
      }

      const request: notificationManager.NotificationRequest = {
        id: PomodoroNotificationService.NOTIFICATION_ID,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: title,
            text: this.currentTitle,
            additionalText: ''
          }
        } as notificationManager.NotificationContent,
        notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
        wantAgent: wantAgent,
        isOngoing: true
      }

      await notificationManager.publish(request)
      this.lastUpdateTime = Date.now()
    } catch (e) {
      Logger.warn(PomodoroNotificationService.tag,
        'updateCountdown failed: ' + (e as Error).message +
        ', remaining=' + remainingMillis.toString() +
        ', status=' + status)
    }
  }

  /** 取消番茄钟常驻通知（未发布时幂等返回，先重置状态避免 cancel 失败误判重复发布） */
  async cancelCountdown(): Promise<void> {
    if (!this.isPublished) {
      return
    }

    // 先重置内部状态，避免 cancel 失败导致后续 publish 被误判为重复发布
    const wasPublished: boolean = this.isPublished
    this.isPublished = false
    const previousTitle: string = this.currentTitle

    try {
      await notificationManager.cancel(PomodoroNotificationService.NOTIFICATION_ID)
      Logger.info(PomodoroNotificationService.tag,
        'cancelCountdown success, title=' + previousTitle)
    } catch (e) {
      Logger.warn(PomodoroNotificationService.tag,
        'cancelCountdown failed: ' + (e as Error).message +
        '（内部状态已重置，不影响后续 publish）')
    }

    this.currentTitle = ''
    this.currentTaskId = ''
  }

  /** 格式化毫秒为 MM:SS（与 PomodoroService.formatTime 保持一致） */
  private formatTime(millis: number): string {
    const totalSeconds: number = Math.max(0, Math.floor(millis / 1000))
    const minutes: number = Math.floor(totalSeconds / 60)
    const seconds: number = totalSeconds % 60
    const minStr: string = minutes.toString().padStart(2, '0')
    const secStr: string = seconds.toString().padStart(2, '0')
    return minStr + ':' + secStr
  }
}
