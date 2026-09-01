/**
 * @file 安全区域辅助工具（响应式单例）
 * @description
 *   基于 @ObservedV2 + @Trace 的安全区状态单例，由 EntryAbility 在
 *   initWindowInsets 中初始化并在 avoidAreaChange 回调里 refresh()。
 *   所有 @ComponentV2 组件在 build 中读取本单例即可自动响应
 *   旋转/折叠/分屏后的避让区变化，无需手动订阅。
 *
 * @module common/utils
 */

/**
 * 安全区响应式单例
 *
 * - statusBar: 状态栏高度（vp）
 * - bottom: 底部安全区高度（vp）
 */
@ObservedV2
class SafeAreaHelper {
  /** 状态栏高度（vp） */
  @Trace statusBar: number = 0

  /** 底部安全区高度（vp） */
  @Trace bottom: number = 0

  /**
   * 获取状态栏高度
   * @returns 状态栏高度（vp），未初始化时返回 0
   */
  getStatusBar(): number {
    return this.statusBar
  }

  /**
   * 获取底部安全区高度
   * @returns 底部安全区高度（vp），未初始化时返回 0
   */
  getBottom(): number {
    return this.bottom
  }

  /**
   * 获取底部安全区高度 + 额外偏移量
   * @param extra 额外偏移量（如导航栏高度 66）
   * @returns 底部安全区高度 + extra
   */
  getBottomWith(extra: number): number {
    return extra + this.bottom
  }

  /**
   * 刷新安全区数值（EntryAbility 初始化与 avoidAreaChange 回调调用）
   * @param status 状态栏高度（vp）
   * @param bottom 底部安全区高度（vp）
   */
  refresh(status: number, bottom: number): void {
    this.statusBar = status
    this.bottom = bottom
  }
}

/** 全局单例 */
export const safeAreaHelper: SafeAreaHelper = new SafeAreaHelper()
