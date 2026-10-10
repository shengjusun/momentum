/**
 * @file ScrollLinkHelper —— 滚动联动标题栏的进度换算（唯一来源）
 *
 * @description
 *   配合 `CommonTitleBar.scrollProgress` 使用：把 `Scroll` 的绝对滚动偏移换算成 0~1 的
 *   联动进度，驱动「栏底色淡入 / 底部分割线淡入 / 栏下 16vp 渐隐遮罩淡入」。
 *
 *   ⚠️ 偏移必须取 `Scroller.currentOffset().yOffset`（**绝对位置**）：
 *      `Scroll.onDidScroll(handler)` 的回调参数是**每帧增量**，直接拿它做进度会越滚越飘。
 *   ⚠️ 回弹（overscroll）时 `yOffset` 为**正数**，故此处 clamp 到 [0, 1]
 *      —— 否则"下拉到顶"时栏会反向越拉越透明。
 *
 *   2026-10-10 抽出：任务详情页与目标详情页共用同一套手感，避免各写一份后漂移。
 *
 * 用法（页内）：
 *   private scroller: Scroller = new Scroller()
 *   @Local barProgress: number = 0
 *   // Scroll(this.scroller).onDidScroll(() => { this.syncBarProgress() })
 *   private syncBarProgress(): void {
 *     const p: number = ScrollLinkHelper.progressFromOffset(this.scroller.currentOffset().yOffset)
 *     if (Math.abs(p - this.barProgress) > ScrollLinkHelper.MIN_DELTA) { this.barProgress = p }
 *   }
 *
 * @module common/utils
 */

export class ScrollLinkHelper {
  /**
   * 联动距离（vp）：滚过这段距离后，栏底色 / 分割线 / 渐隐遮罩**全部到位**。
   * 48 ≈ 2/3 个栏高 —— 太小会"一闪就满"，太大显得迟钝（参考 iOS 44pt / 主流 ~48vp）。
   */
  static readonly FADE_DISTANCE: number = 48

  /**
   * 写入阈值：进度变化小于该值时不回写状态。
   * 滚动是每帧回调，静止/微抖时会产生大量无意义的重渲染。
   */
  static readonly MIN_DELTA: number = 0.004

  /** 由滚动绝对偏移算联动进度（0~1）；回弹的正偏移被 clamp 到 0 */
  static progressFromOffset(yOffset: number): number {
    return Math.max(0, Math.min(1, -yOffset / ScrollLinkHelper.FADE_DISTANCE))
  }

  private constructor() {}
}
