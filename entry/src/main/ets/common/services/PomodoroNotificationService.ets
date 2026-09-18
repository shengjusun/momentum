// 番茄钟常驻通知栏服务，使用 notificationManager 展示专注状态并支持点击直达任务详情页

import { notificationManager } from '@kit.NotificationKit'
import { WantAgent } from '@kit.AbilityKit'
import { resourceManager } from '@kit.LocalizationKit'
import { Logger } from '../utils/Logger'
import { WantAgentFactory } from '../utils/WantAgentFactory'

/** 通知栏展示的阶段 */
export type PomoNotifPhase = 'focus' | 'break'

/** 通知栏展示的运行状态 */
export type PomoNotifStatus = 'running' | 'paused'

/**
 * 番茄钟常驻通知服务（单例）
 *
 * ⚠️ 设计红线（勿改）：HarmonyOS 的 BASIC_TEXT 通知**每次 publish 都会重新弹横幅**，
 *   即便通知 ID 不变、只是内容被覆盖。因此本服务**只在状态切换点发布**
 *   （开始专注 / 进入休息 / 暂停 / 恢复 / 冷启动恢复会话），**绝不按秒刷新**。
 *   历史上 onTickInternal 曾每秒调用一次更新，导致一次 25 分钟专注弹出约 1500 条横幅。
 *
 * 通知文案只承载「当前处于什么状态 + 本次时长（或暂停时剩余）」：
 *   - 专注/休息中：标题=阶段，附加行=本次 X 分钟
 *   - 已暂停：标题=已暂停，附加行=剩余 MM:SS
 *   实时倒计时以应用内沉浸屏为准（系统不为基础文本通知提供静默更新，能做到的只有实况窗 ACL）。
 */
export class PomodoroNotificationService {
  private static readonly tag: string = 'PomodoroNotificationService'
  private static instance: PomodoroNotificationService | null = null

  /** 通知 ID（固定值 50000，独立区间避免与任务 20000+/目标 30000+ 提醒冲突） */
  private static readonly NOTIFICATION_ID: number = 50000

  private isPublished: boolean = false
  private currentLabel: string = ''
  private currentTaskId: string = ''
  private currentPhase: PomoNotifPhase = 'focus'
  private currentStatus: PomoNotifStatus = 'running'
  private context: Context | null = null

  private constructor() {}

  static getInstance(): PomodoroNotificationService {
    if (PomodoroNotificationService.instance === null) {
      PomodoroNotificationService.instance = new PomodoroNotificationService()
    }
    return PomodoroNotificationService.instance
  }

  /**
   * 发布（或刷新）番茄钟常驻通知——仅在状态切换点调用
   *
   * isOngoing 保证常驻不可滑动清除，SERVICE_INFORMATION 触发顶部横幅，wantAgent 点击直达任务详情
   *
   * @param taskId - 任务 ID（点击通知的跳转目标）
   * @param taskTitle - 任务标题（作为通知正文）
   * @param phase - 当前阶段：专注 / 休息
   * @param status - 运行状态：进行中 / 已暂停
   * @param spanMillis - 进行中传「本次阶段总时长」；已暂停传「暂停那一刻的剩余时长」
   */
  async publishCountdown(
    context: Context, taskId: string, taskTitle: string,
    phase: PomoNotifPhase, status: PomoNotifStatus, spanMillis: number
  ): Promise<void> {
    // 幂等：同一任务 + 同一阶段 + 同一状态重复调用时通知内容完全相同，直接跳过，
    // 避免冷启动恢复等路径多弹一条无信息量的横幅
    if (this.isPublished && this.currentTaskId === taskId &&
      this.currentPhase === phase && this.currentStatus === status) {
      return
    }

    // 容错：若上一轮未正常关闭，先清理（cancel 不弹横幅，不会打扰用户）
    if (this.isPublished) {
      await this.cancelCountdown()
    }

    this.context = context

    try {
      // openImmersive=true：从番茄钟通知进来时直接落地全屏番茄钟
      const wantAgent: WantAgent =
        await WantAgentFactory.createTaskDetailWantAgent(context, taskId, true)
      const rm: resourceManager.ResourceManager = context.resourceManager

      // 标题：阶段标签；附加行：时长。均为静态文案，不随秒变化
      const label: string = status === 'paused'
        ? rm.getStringByNameSync('pomo_notif_paused_prefix')
        : (phase === 'focus'
          ? rm.getStringByNameSync('pomo_notif_focus_prefix')
          : rm.getStringByNameSync('pomo_notif_rest_prefix'))
      const detail: string = status === 'paused'
        ? rm.getStringByNameSync('pomo_notif_remain_time').replace('%s', this.formatTime(spanMillis))
        : rm.getStringByNameSync('pomo_notif_span_minutes')
          .replace('%d', Math.max(1, Math.round(spanMillis / 60000)).toString())

      const body: string = taskTitle.length > 0
        ? taskTitle
        : rm.getStringByNameSync('pomo_notif_fallback_title')

      const request: notificationManager.NotificationRequest = {
        id: PomodoroNotificationService.NOTIFICATION_ID,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: label,
            text: body,
            additionalText: detail
          }
        } as notificationManager.NotificationContent,
        notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
        wantAgent: wantAgent,
        isOngoing: true
      }

      await notificationManager.publish(request)

      this.isPublished = true
      this.currentLabel = label
      this.currentTaskId = taskId
      this.currentPhase = phase
      this.currentStatus = status
      Logger.info(PomodoroNotificationService.tag,
        'publishCountdown success, label=' + label + ', status=' + status +
        ', taskId=' + taskId + ', span=' + spanMillis.toString() + 'ms')
    } catch (e) {
      Logger.warn(PomodoroNotificationService.tag,
        'publishCountdown failed: ' + (e as Error).message +
        '（番茄钟主流程不受影响，降级到无通知模式）')
    }
  }

  /** 取消番茄钟常驻通知（未发布时幂等返回，先重置状态避免 cancel 失败误判重复发布） */
  async cancelCountdown(): Promise<void> {
    if (!this.isPublished) {
      return
    }

    // 先重置内部状态，避免 cancel 失败导致后续 publish 被误判为重复发布
    this.isPublished = false
    const previousLabel: string = this.currentLabel

    try {
      await notificationManager.cancel(PomodoroNotificationService.NOTIFICATION_ID)
      Logger.info(PomodoroNotificationService.tag,
        'cancelCountdown success, label=' + previousLabel)
    } catch (e) {
      Logger.warn(PomodoroNotificationService.tag,
        'cancelCountdown failed: ' + (e as Error).message +
        '（内部状态已重置，不影响后续 publish）')
    }

    this.currentLabel = ''
    this.currentTaskId = ''
  }

  /** 格式化毫秒为 MM:SS（暂停时展示剩余时长用） */
  private formatTime(millis: number): string {
    const totalSeconds: number = Math.max(0, Math.floor(millis / 1000))
    const minutes: number = Math.floor(totalSeconds / 60)
    const seconds: number = totalSeconds % 60
    const minStr: string = minutes.toString().padStart(2, '0')
    const secStr: string = seconds.toString().padStart(2, '0')
    return minStr + ':' + secStr
  }
}
