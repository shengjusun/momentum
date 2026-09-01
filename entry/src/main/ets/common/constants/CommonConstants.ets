// 应用全局公共常量定义：日志标识、网络超时、断点阈值、存储键名等

export class CommonConstants {
  /** 日志 DOMAIN（hilog 域） */
  static readonly LOG_DOMAIN: number = 0xD0001

  /** 日志 TAG（hilog 标签） */
  static readonly LOG_TAG: string = 'Momentum'

  /** 网络请求默认连接超时（毫秒） */
  static readonly HTTP_CONNECT_TIMEOUT: number = 15000

  /** 网络请求默认读取超时（毫秒） */
  static readonly HTTP_READ_TIMEOUT: number = 15000

  /** 冷启动延迟：等待 MainTab 渲染后再执行 ViewModel 初始化（毫秒） */
  static readonly COLD_START_INIT_DELAY_MS: number = 100

  /** 冷启动延迟：等待 Navigation 挂载后再执行暂存路由（毫秒） */
  static readonly COLD_START_ROUTE_DELAY_MS: number = 500

  /** 登录保护窗口：登录成功后禁止云端旧数据覆盖本地配置（毫秒） */
  static readonly LOGIN_GUARD_WINDOW_MS: number = 5000

  /** 一天的毫秒数 */
  static readonly DAY_MILLIS: number = 24 * 60 * 60 * 1000

  /** 截止提醒提前天数（系统通知在截止前 N 天发出） */
  static readonly REMINDER_ADVANCE_DAYS: number = 5

  /** 截止提醒通知 ID 区间：任务 [20000, 30000) */
  static readonly NOTIFICATION_ID_TASK_BASE: number = 20000
  static readonly NOTIFICATION_ID_TASK_RANGE: number = 10000
  /** 截止提醒通知 ID 区间：目标 [30000, 40000) */
  static readonly NOTIFICATION_ID_GOAL_BASE: number = 30000
  static readonly NOTIFICATION_ID_GOAL_RANGE: number = 10000


  /** 断点阈值：小屏（vp） */
  static readonly BREAKPOINT_SM: number = 320

  /** 断点阈值：中屏（vp） */
  static readonly BREAKPOINT_MD: number = 600

  /** 断点阈值：大屏（vp） */
  static readonly BREAKPOINT_LG: number = 840

  /** 断点名称：小屏 */
  static readonly BREAKPOINT_NAME_SM: string = 'sm'

  /** 断点名称：中屏 */
  static readonly BREAKPOINT_NAME_MD: string = 'md'

  /** 断点名称：大屏 */
  static readonly BREAKPOINT_NAME_LG: string = 'lg'

  // ===================== 持久化存储键（StorageManager 使用） =====================

  /** 存储键：首页今日待办任务列表（JSON） */
  static readonly STORAGE_KEY_HOME_TODOS: string = 'storage_home_todos_v1'

  /** 存储键：路线页目标列表（JSON） */
  static readonly STORAGE_KEY_ROUTE_GOALS: string = 'storage_route_goals_v1'

  /** 存储键：首页四象限自定义排序（JSON 字符串数组） */
  static readonly STORAGE_KEY_QUADRANT_ORDER: string = 'storage_quadrant_order_v1'



  /** 存储键：应用设置（通知/主题/API Key/隐私/震动） */
  static readonly STORAGE_KEY_APP_SETTINGS: string = 'storage_app_settings_v1'

  /** 存储键：AI 拆解结果 */
  static readonly STORAGE_KEY_AI_TASKS: string = 'storage_ai_tasks_v1'

  /** 存储键：用户身份（华为登录 uid/nickname/avatarUri） */
  static readonly STORAGE_KEY_USER_PROFILE: string = 'storage_user_profile_v1'

  /** 存储键：番茄钟专注统计（todayFocusCount/todayFocusMillis/lastFocusDate） */
  static readonly STORAGE_KEY_POMODORO_STATS: string = 'storage_pomodoro_stats_v1'
  /** 存储键：番茄钟会话快照（冷启动恢复实况窗用） */
  static readonly STORAGE_KEY_POMODORO_SESSION: string = 'storage_pomodoro_session_v1'
  /** 存储键：番茄钟休息结束自动连跑开关（boolean） */
  static readonly STORAGE_KEY_POMO_AUTO_CONTINUE: string = 'storage_pomo_auto_continue_v1'

  /** 存储键：站内通知中心列表（JSON） */
  static readonly STORAGE_KEY_APP_NOTIFICATIONS: string = 'storage_app_notifications_v1'

  /** 存储键：是否已看过 AI 引导（boolean） */
  static readonly STORAGE_KEY_HAS_SEEN_AI_GUIDE: string = 'has_seen_ai_guide'

  /** 列表项唯一 ID 前缀 */
  static readonly ITEM_ID_PREFIX: string = 'home_item_'

  /** 信息流每页数量 */
  static readonly PAGE_SIZE: number = 15

  // ===================== 字体大小规范（fp 数值，基于设计系统） =====================

  /** 极小字（最低可读下限） */
  static readonly FONT_SIZE_MINI: number = 9

  /** 超大标题 */
  static readonly FONT_SIZE_XL: number = 24

  /** 特大标题（导航栏返回箭头/卡片标题） */
  static readonly FONT_SIZE_XXL: number = 26

  /** 特大标题（品牌 Logo 应用名） */
  static readonly FONT_SIZE_XXXL: number = 28

  /** 巨型标题（FAB 图标） */
  static readonly FONT_SIZE_HUGE: number = 32

  /** 超巨型（番茄钟 emoji/状态图标） */
  static readonly FONT_SIZE_MEGA: number = 36

  /** 倒计时主数字 */
  static readonly FONT_SIZE_TIMER: number = 40

  /** 沉浸屏次级倒计时 */
  static readonly FONT_SIZE_TIMER_MD: number = 52

  /** 沉浸屏超大倒计时 */
  static readonly FONT_SIZE_TIMER_XL: number = 56

  /** 大标题 */
  static readonly FONT_SIZE_LARGE: number = 20

  /** 标题 */
  static readonly FONT_SIZE_TITLE: number = 18

  /** 副标题 */
  static readonly FONT_SIZE_SUBTITLE: number = 16

  /** 正文 */
  static readonly FONT_SIZE_BODY: number = 14

  /** 中间字号（菜单项/强调正文，介于 CAPTION 与 SUBTITLE 之间） */
  static readonly FONT_SIZE_MID: number = 15

  /** 标题级字号（卡片主标题，介于 TITLE 与 XL 之间） */
  static readonly FONT_SIZE_HEADLINE: number = 22

  /** 辅助文字 */
  static readonly FONT_SIZE_CAPTION: number = 13

  /** 小字 */
  static readonly FONT_SIZE_SMALL: number = 12

  /** 微小字 */
  static readonly FONT_SIZE_XS: number = 11

  /** 极微小字 */
  static readonly FONT_SIZE_XXS: number = 10

  private constructor() {}
}
