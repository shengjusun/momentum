/**
 * @file 尺寸常量表
 * @description 全工程布局尺寸的单一来源：内容列限宽、分栏宽、弹窗钳制、
 *   底部避让、触控热区等。调整任何尺寸只改本文件。
 *
 * @module common/constants
 */

export class DimensConstants {
  /** 内容列最大宽（阅读舒适行宽上限，限宽居中范式） */
  static readonly CONTENT_MAX_WIDTH: number = 640

  /** 内容列最大宽——平板（lg 断点）分档：列表型页面（我的/统计）放宽，避免横屏两侧大片留白 */
  static readonly CONTENT_MAX_WIDTH_TABLET: number = 860

  /** 分栏双栏布局整体上限（TaskDetail/GoalDetail lg 双栏） */
  static readonly DUAL_MAX_WIDTH: number = 1280

  /** 侧栏/分栏固定列宽（AI 侧栏等） */
  static readonly SIDE_COLUMN_WIDTH: number = 360

  /** 半模态/对话框最大宽（大屏弹窗钳制） */
  static readonly SHEET_MAX_WIDTH: number = 480

  /** 底部 TabBar 高度避让（HDS 悬浮胶囊：barBottomMargin 28 + 栏高约 72） */
  static readonly TAB_CLEARANCE: number = 100

  /** FAB 悬浮按钮底部避让 */
  static readonly FAB_CLEARANCE: number = 80

  /** 最小触控热区（HarmonyOS 交互规范下限） */
  static readonly TOUCH_MIN: number = 40

  /** 推荐触控热区 */
  static readonly TOUCH_COMFORT: number = 44

  /** 页面基础水平边距 */
  static readonly PAGE_PADDING_H: number = 16

  /** 卡片圆角 */
  static readonly RADIUS_CARD: number = 16

  /** 卡片列表间距 */
  static readonly SPACE_CARD: number = 12

  /* ============================================================
   * 圆角 Token（收敛历史 8 种取值为 5 档，全 App 统一圆角语言）
   * ============================================================ */
  /** 极小圆角：徽标/小标签 */
  static readonly RADIUS_XS: number = 6
  /** 小圆角：内嵌输入框/小按钮 */
  static readonly RADIUS_S: number = 8
  /** 中圆角：行内元素/chip/列表行 */
  static readonly RADIUS_M: number = 12
  /** 大圆角：卡片（默认卡片圆角） */
  static readonly RADIUS_L: number = 16
  /** 特大圆角：底部面板/全屏弹层顶部 */
  static readonly RADIUS_XL: number = 24

  /* ============================================================
   * 间距 Token（卡片间/卡内/元素间统一节奏）
   * ============================================================ */
  /** 间距-紧凑：元素内 */
  static readonly SPACE_S: number = 8
  /** 间距-标准：卡片内区块 */
  static readonly SPACE_M: number = 16
}
