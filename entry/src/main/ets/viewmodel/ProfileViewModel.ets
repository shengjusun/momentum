/**
 * @file 通知权限 API 桥接器（纯系统 API 调用，不持有状态）
 * @description
*   架构定位：profileVM = 系统通知 API 桥接器
 *   单一真相源：settingsVM 持有所有 UI 状态 + 持久化
 *   已清理：删除冗余 @Trace 字段 + 独立持久化（与 settingsVM 重叠的 3 字段）
 *   V2 规范：@ObservedV2 + @Trace
 *   ArkTS 严格模式：显式类型标注，无 as 强转
 *
 * 触发链路：
 *   ProfilePage.Toggle.onChange(isOn) →
 *   settingsVM.toggleNotification(isOn) →
 *   profileVM.toggleNotification(isOn) →
 *   notificationManager API →
 *   返回 NotificationToggleResult →
 *   settingsVM 更新状态 + 持久化
 *
 * @module viewmodel
 * @date 2026-07-03
 */

import { notificationManager } from '@kit.NotificationKit'
import { BusinessError } from '../common/utils/BusinessError'
import { Logger } from '../common/utils/Logger'

/**
 * 通知开关结果
 */
export interface NotificationToggleResult {
  success: boolean
  finalState: boolean
  errorMsg: string
}

/**
 * 通知权限 API 桥接器（不持有 UI 状态，不持久化）
 */
@ObservedV2
export class ProfileViewModel {
  private readonly tag: string = 'ProfileViewModel'

  /** 应用上下文（仅用于系统 API 调用） */
  private context: Context | null = null

  /**
   * 注入上下文（由 settingsVM.init() 内部调用）
   */
  init(context: Context): void {
    this.context = context
    Logger.info(this.tag, 'init success')
  }

  /**
   * 首次使用场景的通知授权引导
   * - 已开启系统通知：直接返回 true（零打扰）
   * - 未开启：触发系统授权弹窗，返回弹窗后的最终状态
   * - context 未初始化或 API 异常：返回 false，不阻断调用方主流程
   * 适用调用点：AI 确认方案落库后、番茄钟开始专注前等"即将产生提醒依赖"的时刻
   */
  async ensureNotificationEnabled(): Promise<boolean> {
    if (this.context === null) {
      Logger.warn(this.tag, 'ensureNotificationEnabled: context not initialized')
      return false
    }
    try {
      const isEnabled: boolean = await notificationManager.isNotificationEnabled()
      if (isEnabled) {
        return true
      }
      await notificationManager.requestEnableNotification()
      const finalEnabled: boolean = await notificationManager.isNotificationEnabled()
      Logger.info(this.tag, 'ensureNotificationEnabled: requested, final=' + finalEnabled.toString())
      return finalEnabled
    } catch (e) {
      const err: BusinessError = e as BusinessError
      Logger.warn(this.tag, 'ensureNotificationEnabled failed, code=' + err.code.toString() + ', msg=' + err.message)
      return false
    }
  }

  /**
   * 核心方法：通知开关切换（真实系统 API）
   * @param isChecked - 用户切换的目标状态
   * @returns Promise<NotificationToggleResult>
   */
  async toggleNotification(isChecked: boolean): Promise<NotificationToggleResult> {
    const result: NotificationToggleResult = {
      success: false,
      finalState: false,
      errorMsg: ''
    }
    if (this.context === null) {
      result.errorMsg = 'context not initialized'
      Logger.error(this.tag, 'toggleNotification: ' + result.errorMsg)
      return result
    }
    const ctx: Context = this.context
    try {
      if (isChecked) {
        const isEnabled: boolean = await notificationManager.isNotificationEnabled()
        if (!isEnabled) {
          await notificationManager.requestEnableNotification()
          Logger.info(this.tag, 'requestEnableNotification called')
        }

        // 仅申请权限，不发送测试通知
        result.success = true
        result.finalState = true
      } else {
        try {
          await notificationManager.cancel(1001)
          Logger.info(this.tag, 'notification cancelled, id=1001')
        } catch (e) {
          const err: BusinessError = e as BusinessError
          Logger.warn(this.tag, 'cancel notification warning: ' + err.message)
        }
        result.success = true
        result.finalState = false
      }

      Logger.info(this.tag, 'toggleNotification done, finalState=' +
        result.finalState.toString())
    } catch (e) {
      const err: BusinessError = e as BusinessError
      result.errorMsg = err.message
      result.success = false
      result.finalState = false
      Logger.error(this.tag, 'toggleNotification failed, code=' + err.code.toString() +
        ', msg=' + err.message)
    }
    return result
  }
}

/**
 * 全局单例导出
 * settingsVM.toggleNotification() 内部调用 profileVM.toggleNotification()
 */
export const profileVM: ProfileViewModel = new ProfileViewModel()
