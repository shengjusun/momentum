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

  /** 分栏双栏布局整体上限（TaskDetail/GoalDetail lg 双栏） */
  static readonly DUAL_MAX_WIDTH: number = 1080

  /** 侧栏/分栏固定列宽（AI 侧栏等） */
  static readonly SIDE_COLUMN_WIDTH: number = 360

  /** 半模态/对话框最大宽（大屏弹窗钳制） */
  static readonly SHEET_MAX_WIDTH: number = 480

  /** 底部 TabBar 高度避让（悬浮胶囊 56 + 间距 10） */
  static readonly TAB_CLEARANCE: number = 66

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
}
