/**
 * @file 全局返回键处理工具 (P0 #6.3 修复)
 * @description
 *   - 实现"再按一次退出"防误触机制
 *   - 维护 lastPressTime（上次按下时间戳）
 *   - 首次按：showToast 提示 + 记录时间
 *   - 2 秒内再按：返回 true（应用退出）
 *   - 2 秒后再按：重置 + 重新提示
 *
 *   使用方式：
 *   ```typescript
 *   onBackPress(): boolean {
 *     if (globalNavStack.size() > 0) {
 *       return false  // 有子页面，让系统处理 pop
 *     }
 *     return BackPressHandler.handleExitOnBack(() => { globalNavStack.clear() })
 *   }
 *   ```
 *
 * @module common/utils
 * @date 2026-06-19
 */

import { promptAction } from '@kit.ArkUI'

/**
 * 全局返回键处理类（静态工具）
 */
export class BackPressHandler {
  /** 上次按下时间戳（0 = 未按下） */
  private static lastPressTime: number = 0
  /** 二次确认窗口期（ms） */
  private static readonly CONFIRM_WINDOW_MS: number = 2000
  /** Toast 提示文本（i18n 资源） */
  private static readonly TOAST_MESSAGE: Resource = $r('app.string.back_press_exit_toast')

  /**
   * 处理"再按一次退出"逻辑
   * @param onConfirmExit - 用户在窗口期内再次按下时的回调（用于清理状态/真正退出）
   * @returns true = 已拦截（应退出 App 或已处理），false = 让系统继续
   */
  static handleExitOnBack(onConfirmExit: () => void): boolean {
    const now: number = Date.now()
    if (BackPressHandler.lastPressTime === 0) {
      // 首次按下：显示提示 + 记录时间
      BackPressHandler.lastPressTime = now
      promptAction.showToast({
        message: BackPressHandler.TOAST_MESSAGE,
        duration: 1500,
        bottom: '60vp'
      })
      return true  // 拦截本次返回
    }
    if (now - BackPressHandler.lastPressTime < BackPressHandler.CONFIRM_WINDOW_MS) {
      // 二次按下（在窗口期内）：真正退出
      BackPressHandler.lastPressTime = 0  // 重置
      if (onConfirmExit) {
        onConfirmExit()
      }
      return false  // 让系统处理（退出 App）
    }
    // 超过窗口期：视为新的首次按下
    BackPressHandler.lastPressTime = now
    promptAction.showToast({
      message: BackPressHandler.TOAST_MESSAGE,
      duration: 1500,
      bottom: '60vp'
    })
    return true
  }

  /**
   * 重置状态（在页面切换、Tab 切换时调用）
   * 防止跨页面的"再按一次退出"状态残留
   */
  static reset(): void {
    BackPressHandler.lastPressTime = 0
  }

  /**
   * 获取当前是否在二次确认窗口期内（用于测试/调试）
   * @returns boolean
   */
  static isInConfirmWindow(): boolean {
    if (BackPressHandler.lastPressTime === 0) {
      return false
    }
    return Date.now() - BackPressHandler.lastPressTime < BackPressHandler.CONFIRM_WINDOW_MS
  }
}
