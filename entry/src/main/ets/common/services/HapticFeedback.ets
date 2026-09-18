/**
 * @file HapticFeedback - 完成场景的触觉反馈（三档：轻点 / 中震 / 庆祝节奏）
 * @description
 *   面向"完成"链路的轻量触觉反馈：
 *   - 步骤 / 里程碑完成 → 10ms 轻点（stepCompleted）
 *   - 任务完成 → 40ms 中震（taskCompleted）
 *   - 目标达成 → 短-停-长两段庆祝节奏（goalCompleted）
 *
 *   设计约束：
 *   - 开关复用设置页既有的「震动反馈」（vibrationEnabled），由 SettingsViewModel 推送
 *     （与 pomodoroService.setFeedbackEnabled 同一来源，不新增设置项）
 *   - 内置最小触发间隔：连续快速勾选（如批量勾步骤）时按限频合并，避免马达叠震发闷
 *   - 使用方只应在**用户动作写点**调用（勾选翻转处），禁止在数据恢复 /
 *     云同步落地路径调用——同步回来的完成状态不发声不震动
 *   - vibrator 属系统能力（非 UI API），在 service / viewmodel 层调用合法
 *     （先例：pomodoroService.vibrate）
 *
 *   权限：ohos.permission.VIBRATE（module.json5 已声明，system_grant）
 *
 * @module common/services
 * @date 2026-09-17
 */

import { vibrator } from '@kit.SensorServiceKit'
import { Logger } from '../utils/Logger'

export class HapticFeedback {
  private static readonly tag: string = 'HapticFeedback'
  private static instance: HapticFeedback | null = null

  /** 连续触发的最小间隔（毫秒）：窗口内的重复请求直接忽略 */
  private static readonly MIN_FIRE_INTERVAL_MS: number = 60

  /** 震动开关（设置页「震动反馈」，SettingsViewModel 推送；默认开启与设置默认值一致） */
  private enabled: boolean = true
  /** 上次实际触发时刻（限频用） */
  private lastFireAt: number = 0

  private constructor() {}

  static getInstance(): HapticFeedback {
    if (HapticFeedback.instance === null) {
      HapticFeedback.instance = new HapticFeedback()
    }
    return HapticFeedback.instance
  }

  /**
   * 更新开关（由 SettingsViewModel 推送）
   * @param enabled 设置页「震动反馈」开关值
   */
  setEnabled(enabled: boolean): void {
    this.enabled = enabled
    Logger.info(HapticFeedback.tag, 'setEnabled: ' + enabled.toString())
  }

  /** 步骤 / 里程碑完成：10ms 轻点 */
  stepCompleted(): void {
    this.fire(10)
  }

  /** 任务完成：40ms 中震 */
  taskCompleted(): void {
    this.fire(40)
  }

  /**
   * 目标达成：短-停-长两段庆祝节奏（60ms → 停 90ms → 160ms）
   * 单次 startVibration 只能表达一个时长，两段用定时器衔接；
   * 第二段距第一段 150ms > 限频窗口 60ms，可正常触发。
   */
  goalCompleted(): void {
    this.fire(60)
    setTimeout((): void => {
      this.fire(160)
    }, 150)
  }

  /**
   * 实际触发（时长模式；预设触感 preset 因机型支持参差需 isSupportEffect 探测，暂不使用）
   */
  private fire(durationMs: number): void {
    if (!this.enabled) return
    const now: number = Date.now()
    if (now - this.lastFireAt < HapticFeedback.MIN_FIRE_INTERVAL_MS) {
      Logger.info(HapticFeedback.tag,
        'fire skipped: within throttle window (' + durationMs.toString() + 'ms)')
      return
    }
    this.lastFireAt = now
    try {
      vibrator.startVibration(
        { type: 'time', duration: durationMs },
        { id: 0, usage: 'notification' }
      ).catch((e: Error): void => {
        Logger.warn(HapticFeedback.tag, 'startVibration failed: ' + e.message)
      })
    } catch (e) {
      Logger.warn(HapticFeedback.tag, 'vibrate error: ' + (e as Error).message)
    }
  }
}

/** 全局单例 */
export const hapticFeedback: HapticFeedback = HapticFeedback.getInstance()
