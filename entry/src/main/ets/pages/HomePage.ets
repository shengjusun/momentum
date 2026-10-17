// 首页工作台：艾森豪威尔四象限矩阵 + 任务勾选/导航/滑动删除

import { HomeTodoItem, Id, TaskPriority, TaskDetailRouteNavParam, TaskDetailItem,
  EisenhowerQuadrant } from '../model/Models'
import { homeVM, HomeViewModel } from '../viewmodel/HomeViewModel'
import { routeVM } from '../viewmodel/RoutePageViewModel'
import { globalTabsController, TAB_INDEX, ROUTE_NAME, pushNavPath } from '../common/RouterManager'

import { Logger } from '../common/utils/Logger'
import { safeStringUtil, safeNumberUtil, formatDeadlineUtil } from '../common/utils/SafeUtils'
import { priorityLabelUtil, priorityBgColorUtil, priorityTextColorUtil, classifyEisenhowerQuadrant, quadrantLabelUtil } from '../common/utils/PriorityUtils'
import { promptAction, window } from '@kit.ArkUI'
import { Context, common } from '@kit.AbilityKit'
import { EisenhowerQuadrantDataSource } from '../common/datasource/TaskDataSource'
import { CommonTitleBar } from '../common/components/CommonTitleBar'
import { StateView, StateMode } from '../common/components/StateView'
import { AppReportSheet } from '../common/components/AppReportSheet'
import { AppActionSheet, AppActionSheetItem } from '../common/components/AppActionSheet'
import { StorageManager } from '../common/utils/StorageManager'
import { CommonConstants } from '../common/constants/CommonConstants'
import { DimensConstants } from '../common/constants/DimensConstants'
import { MotionConstants } from '../common/constants/MotionConstants'
import { dragState } from './MainTab'
import { safeAreaHelper } from '../common/utils/SafeAreaHelper'
import { DeepSeekService } from '../common/services/DeepSeekService'
import { ProfileAnalyzerService, TodayTodoInput } from '../common/services/ProfileAnalyzerService'
import { breakpointState } from '../common/utils/BreakpointState'
import { GripAwarenessService, GripHand } from '../common/services/GripAwarenessService'

/* ============================================================
 * 顶层工具函数
 * ============================================================ */

/**
 * bindPopup 的显示状态回调参数
 * 自定义同构接口（形状与 SDK 声明一致），避免依赖 SDK 内部类型名
 */
interface PopupVisibilityEvent {
  isVisible: boolean
}

/** 默认四象限顺序（Q1→Q2→Q3→Q4） */
const DEFAULT_QUADRANT_ORDER: EisenhowerQuadrant[] = [
  EisenhowerQuadrant.Q1_IMPORTANT_URGENT,
  EisenhowerQuadrant.Q2_IMPORTANT_NOT_URGENT,
  EisenhowerQuadrant.Q3_NOT_IMPORTANT_URGENT,
  EisenhowerQuadrant.Q4_NOT_IMPORTANT_NOT_URGENT
]

/** 将象限枚举数组转为字符串数组用于持久化 */
function quadrantOrderToStrings(order: EisenhowerQuadrant[]): string[] {
  const result: string[] = []
  for (let i = 0; i < order.length; i++) {
    result.push(order[i])
  }
  return result
}

/** 将字符串数组还原为象限枚举数组，过滤非法值 */
function stringsToQuadrantOrder(strs: string[]): EisenhowerQuadrant[] {
  const result: EisenhowerQuadrant[] = []
  for (let i = 0; i < strs.length; i++) {
    const s = strs[i]
    if (s === EisenhowerQuadrant.Q1_IMPORTANT_URGENT) {
      result.push(EisenhowerQuadrant.Q1_IMPORTANT_URGENT)
    } else if (s === EisenhowerQuadrant.Q2_IMPORTANT_NOT_URGENT) {
      result.push(EisenhowerQuadrant.Q2_IMPORTANT_NOT_URGENT)
    } else if (s === EisenhowerQuadrant.Q3_NOT_IMPORTANT_URGENT) {
      result.push(EisenhowerQuadrant.Q3_NOT_IMPORTANT_URGENT)
    } else if (s === EisenhowerQuadrant.Q4_NOT_IMPORTANT_NOT_URGENT) {
      result.push(EisenhowerQuadrant.Q4_NOT_IMPORTANT_NOT_URGENT)
    }
  }
  // 保证四格齐全，缺失则补默认
  if (result.length !== 4) {
    return DEFAULT_QUADRANT_ORDER.slice()
  }
  return result
}

// 将 context 作为参数传入，避免依赖 AppStorage 导致的空指针
function getGreeting(context: Context): string {
  const hour: number = new Date().getHours()
  if (hour < 6) { return context.resourceManager.getStringSync($r('app.string.greeting_dawn').id) }
  if (hour < 12) { return context.resourceManager.getStringSync($r('app.string.greeting_morning').id) }
  if (hour < 14) { return context.resourceManager.getStringSync($r('app.string.greeting_noon').id) }
  if (hour < 18) { return context.resourceManager.getStringSync($r('app.string.greeting_afternoon').id) }
  return context.resourceManager.getStringSync($r('app.string.greeting_night').id)
}

/* ============================================================
 * 子组件 1：CheckboxComponent - 复选框组件
 * ============================================================ */

@ComponentV2
@ReusableV2
export struct CheckboxComponent {
  @Param isCompleted: boolean = false
  @Event onToggle: () => void = (): void => {}

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.isCompleted) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(CommonConstants.FONT_SIZE_BODY)
          .fontWeight(FontWeight.Bold)
          .fontColor([$r('app.color.text_inverse')])
          .width(22)
          .height(22)
          .borderRadius(11)
          .backgroundColor($r('app.color.success_color'))
      } else {
        Column()
          .width(22)
          .height(22)
          .borderRadius(11)
          .border({ width: 1.5, color: $r('app.color.text_tertiary') })
          .backgroundColor($r('app.color.bg_card'))
      }
    }
    .width(36)
    .height(36)
    .hitTestBehavior(HitTestMode.Block) // 勾选仅响应 Checkbox，卡片点击跳转详情
    .onClick((): void => {
      this.onToggle()
    })
  }
}

/* ============================================================
 * 子组件 2：TaskListItemComponent - 任务卡片子组件
 * ============================================================ */

@ComponentV2
@ReusableV2
export struct TaskListItemComponent {
  // 4 级架构：HomeTodoItem 构造函数需 9 个参数（含 createTime + relatedTaskId + relatedGoalId）
  //  占位默认值：relatedTaskId/relatedGoalId 为空字符串（实际渲染时由 homeVM.taskList 覆盖）
  @Param task: HomeTodoItem = new HomeTodoItem('', '', '', '', TaskPriority.LOW, false, 0, '', '')
  @Event onToggle: (id: Id) => void = (id: Id): void => {}
  @Event onNavigate: (task: HomeTodoItem) => void = (task: HomeTodoItem): void => {}
  /** 长按：弹出四象限移动菜单（象限反向操作入口） */
  @Event onLongPress: (task: HomeTodoItem) => void = (task: HomeTodoItem): void => {}

  build() {
    Row({ space: 12 }) {
      CheckboxComponent({ isCompleted: this.task.isCompleted, onToggle: (): void => {
        this.onToggle(this.task.id)
      } })

      Column({ space: 4 }) {
        Text(safeStringUtil(this.task.title, getContext(this).resourceManager.getStringSync($r('app.string.default_unnamed_task').id)))
          .fontSize(CommonConstants.FONT_SIZE_SUBTITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.task.isCompleted ? $r('app.color.text_tertiary') : $r('app.color.text_primary'))
          .decoration({ type: this.task.isCompleted ? TextDecorationType.LineThrough : TextDecorationType.None })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Row({ space: 8 }) {
          Text(priorityLabelUtil(this.task.priority))
            .fontSize(CommonConstants.FONT_SIZE_XXS)
            .fontColor(priorityTextColorUtil(this.task.priority))
            .backgroundColor(priorityBgColorUtil(this.task.priority))
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(DimensConstants.RADIUS_XS)

          if (safeNumberUtil(parseInt(this.task.duration), 0) > 0) {
            Text(this.task.duration)
              .fontSize(CommonConstants.FONT_SIZE_XS)
              .fontColor($r('app.color.text_tertiary'))
          }

          // 截止时间：已逾期标红，24 小时内标警示色，其余常规展示
          if (this.task.deadline > 0) {
            Text(formatDeadlineUtil(this.task.deadline) +
              (this.task.deadline <= Date.now()
                ? getContext(this).resourceManager.getStringSync($r('app.string.home_deadline_overdue').id)
                : ''))
              .fontSize(CommonConstants.FONT_SIZE_XS)
              .fontColor(this.task.deadline <= Date.now()
                ? $r('app.color.error_color')
                : (this.task.deadline - Date.now() < 24 * 60 * 60 * 1000
                  ? $r('app.color.warning_color')
                  : $r('app.color.text_tertiary')))
          }
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .constraintSize({ minHeight: 64 })
    .padding({ left: 16, right: 16 })
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(DimensConstants.RADIUS_M)
    .shadow({ radius: 4, color: $r('app.color.shadow_card'), offsetX: 0, offsetY: 1 })
    .onClick((): void => {
      this.onNavigate(this.task)
    })
    .gesture(LongPressGesture({ repeat: false })
      .onAction((): void => {
        this.onLongPress(this.task)
      }))
  }
}

/* ============================================================
 * 根组件 3：HomePage - 首页根组件
 * ============================================================ */

/**
 * 首页工作台（根组件）
 * AI 确认方案后 Q1 任务自动添加到 homeVM.taskList → @Computed eisenhowerMatrix 自动重算 → 本页面四象限刷新
 *
 * 数据流：
 *   homeVM.taskList(@Trace) → eisenhowerMatrix(@Computed) → syncEisenhowerDataSources → q1~q4DataSource → LazyForEach
 *   viewModel 是普通属性（非 @Local），依赖 @ObservedV2 单例内部 @Trace 响应式追踪
 */
@Entry
@ComponentV2
export struct HomePage {
  // viewModel 是普通属性而非 @Local：homeVM 是 @ObservedV2 单例，@Trace 属性变更时 ArkUI 自动追踪
  private viewModel: HomeViewModel = homeVM

  @Local greeting: string = getGreeting(getContext(this))

  // 艾森豪威尔四象限半模态状态：showEisenhowerSheet 控制半模态显示/隐藏
  @Local showEisenhowerSheet: boolean = false

  /** 行内删除确认：仅该行显示「取消 / 删除」，同时只允许一行（成熟做法：不弹系统框，避免与半模态叠两层） */
  @Local pendingDeleteTaskId: string = '' 
  /** 已完成任务折叠区展开状态 */
  @Local showCompletedSection: boolean = false
  /** C2 今日排序建议：弹层显示/加载中/报告文本 */
  @Local showSuggestionSheet: boolean = false
  /** 统一操作面板状态（页面级操作：删除确认等） */
  @Local showActionSheet: boolean = false
  @Local actionSheetTitle: string = ''
  @Local actionSheetItems: AppActionSheetItem[] = []

  // ---------------- 悬浮快捷按钮（FAB）+「添加待办」弹层 ----------------
  /**
   * FAB 显隐（**全局偏好**，默认显示）
   * 与 RoutePage 共用 `CommonConstants.STORAGE_KEY_FAB_VISIBLE`：
   * 长按隐藏、设置页「悬浮快捷按钮」恢复，两边行为完全一致。
   */
  @Local fabVisible: boolean = true
  /** FAB 所在侧（智感握姿驱动；'unknown' 一律回落右下） */
  @Local fabSide: 'left' | 'right' = 'right'
  /** FAB 容器实测尺寸（onAreaChange 上报）：用 position 换边必须知道容器宽高 */
  @Local fabAreaW: number = 0
  @Local fabAreaH: number = 0
  /** 是否启用「智感握姿」（设置页开关，默认开启） */
  @Local gripEnabled: boolean = true
  /** 「添加待办」弹层：显隐 / 标题输入 / 目标象限 */
  @Local showAddTodoSheet: boolean = false
  @Local addTodoTitle: string = ''
  /** 默认放"重要不紧急"：这是大多数人真正该先做的事（Q1 往往是别人压给你的） */
  @Local addTodoQuadrant: EisenhowerQuadrant = EisenhowerQuadrant.Q2_IMPORTANT_NOT_URGENT
  /** FAB 尺寸与边距：与 RoutePage 保持一致（距底部 80vp、距左右各 24vp） */
  private readonly FAB_SIZE: number = 56
  private readonly FAB_EDGE: number = 24
  private readonly FAB_BOTTOM: number = 80
  /** 握姿感知服务单例（与 RoutePage 共用同一个单例） */
  private gripService: GripAwarenessService = GripAwarenessService.getInstance()

  // 长按待办 → "移动象限"菜单：锚定在被长按那一行上的弹层（bindPopup）
  // 为什么不用 AppActionSheet：它是"页面级底部面板"，渲染在页面 Stack 内、位于四象限半模态
  // （bindSheet，独立浮层）之下且贴着屏幕底部，与被长按的那一项毫无空间关系 —— 用户会觉得"弹在外面"。
  /** 菜单是否显示 */
  @Local showMoveMenu: boolean = false
  /** 菜单操作的目标任务（null = 未选中；也用于判断弹层挂在哪一行） */
  @Local moveMenuTask: HomeTodoItem | null = null
  /** 目标任务当前所在象限（用于在菜单里标出"（当前）"） */
  @Local moveMenuCurrent: EisenhowerQuadrant = EisenhowerQuadrant.Q1_IMPORTANT_URGENT
  @Local suggestionLoading: boolean = false
  @Local suggestionText: string = ''
  // 四个象限独立 DataSource，配合 LazyForEach 按需渲染
  // keyPrefix 不同避免 LazyForEach key 碰撞
  @Local q1DataSource: EisenhowerQuadrantDataSource = new EisenhowerQuadrantDataSource('eisenhower_q1')
  @Local q2DataSource: EisenhowerQuadrantDataSource = new EisenhowerQuadrantDataSource('eisenhower_q2')
  @Local q3DataSource: EisenhowerQuadrantDataSource = new EisenhowerQuadrantDataSource('eisenhower_q3')
  @Local q4DataSource: EisenhowerQuadrantDataSource = new EisenhowerQuadrantDataSource('eisenhower_q4')
  /**
   * 当前点击的象限（控制半模态展示哪个象限的任务列表）
   * - 点击首页象限卡片时设置
   * - 半模态标题与数据源根据此值动态切换
   */
  @Local activeQuadrant: EisenhowerQuadrant = EisenhowerQuadrant.Q1_IMPORTANT_URGENT
  /**
   * 四象限信号（驱动四象限 DataSource 同步）
   * 为什么需要：q1~q4DataSource 是 eisenhowerMatrix 的独立副本，无响应式绑定。
   * 之前只在"打开半模态 / 数据变更后可见性回调"时同步，平板右栏（常驻面板）
   * 冷启动首次渲染时数据源还是空的 → 面板空白。用 @Local + @Monitor 在
   * build 之后统一补一次同步（模式与 RoutePage.goalCount 一致）。
   *
   * ⚠️ 为什么是"四象限计数组合"而不是"任务总数"（2026-09-17 修复）：
   *   旧信号 `liveTasks.length` 感知不到**任务换象限**——deadline 跨过 24h 线时
   *   （nowMinute 每分钟驱动 eisenhowerMatrix 重算），任务从 q4 挪到 q3，总数不变
   *   → 信号不变 → DataSource 不同步 → 右栏"计数是新的、列表是旧的"（计数直读
   *   @Computed 会刷新，列表走 DataSource 不会）。四个计数拼串后，任何象限迁移都会改变信号。
   */
  @Local quadrantSignal: string = ''

  /**
   * FAB 的 x 坐标
   * 换边必须走 position：它是可动画的渲染属性，配合 .animation() 才有"滑过去"的过渡感
   */
  private fabX(): number {
    const w: number = this.fabAreaW > 0 ? this.fabAreaW : 360
    if (this.fabSide === 'left') {
      return this.FAB_EDGE
    }
    return Math.max(this.FAB_EDGE, w - this.FAB_SIZE - this.FAB_EDGE)
  }

  /** FAB 的 y 坐标（距底 80vp，避开底部悬浮 TabBar） */
  private fabY(): number {
    const h: number = this.fabAreaH > 0 ? this.fabAreaH : 780
    return Math.max(0, h - this.FAB_SIZE - this.FAB_BOTTOM)
  }

  /**
   * 读取全局 FAB 显隐偏好（幂等：aboutToAppear / onVisibleAreaChange 都会调）
   * 后者覆盖"从设置页返回"的场景 —— 用户在设置里重新打开后切回首页要立刻生效。
   */
  private async loadFabVisible(): Promise<void> {
    this.fabVisible = await StorageManager.getPreferenceBool(
      CommonConstants.STORAGE_KEY_FAB_VISIBLE, true)
  }

  /**
   * 按用户开关同步握姿订阅（设置页「智感握姿」）
   * - 开启：订阅；服务内部做能力探测与降级，不支持设备回退 'unknown' → FAB 保持右下
   * - 关闭：退订并把 FAB 复位右下
   */
  private async syncGripSubscription(): Promise<void> {
    this.gripEnabled = await StorageManager.getPreferenceBool(
      CommonConstants.STORAGE_KEY_GRIP_AWARENESS, true)
    if (!this.gripEnabled) {
      this.gripService.unsubscribe()
      this.fabSide = 'right'
      return
    }
    const uiContext: common.UIAbilityContext = getContext(this) as common.UIAbilityContext
    this.gripService.subscribe(uiContext, (hand: GripHand): void => {
      // 'right' 与 'unknown' 一律右下（默认）
      this.fabSide = hand === 'left' ? 'left' : 'right'
    })
  }

  /**
   * 长按隐藏 FAB
   * 隐藏是**全局偏好**（首页与路线页一起隐藏）：表达"我不需要这个按钮"，
   * 而非"这一页不需要" —— 否则会出现"首页藏了、路线页还露着"的困惑。
   * 恢复入口在设置页「悬浮快捷按钮」，toast 里直接写明路径。
   */
  private handleFabLongPress(): void {
    if (!this.fabVisible) return
    this.fabVisible = false
    this.gripService.unsubscribe()
    StorageManager.setPreferenceBool(CommonConstants.STORAGE_KEY_FAB_VISIBLE, false)
      .catch((e: Error): void => {
        Logger.warn('HomePage', 'save fab visible failed: ' + e.message)
      })
    promptAction.showToast({
      message: getContext(this).resourceManager.getStringSync($r('app.string.toast_fab_hidden').id),
      duration: 2500
    })
  }

  /** 打开「添加待办」弹层（重置表单） */
  private openAddTodoSheet(): void {
    this.addTodoTitle = ''
    this.addTodoQuadrant = EisenhowerQuadrant.Q2_IMPORTANT_NOT_URGENT
    this.showAddTodoSheet = true
  }

  /**
   * 把用户选的「象限」反推成数据字段并入库
   *
   * 四象限在本 App 里是**派生**的（重要 = `priority === HIGH`；紧急 = `deadline` 距今 < 24h），
   * 所以选了"放哪一格"后，这里要反向写出对应的 `priority` + `deadline`：
   *   Q1 重要且紧急   → HIGH   + 今天 23:59 截止
   *   Q2 重要不紧急   → HIGH   + 无截止
   *   Q3 紧急不重要   → MEDIUM + 今天 23:59 截止
   *   Q4 不重要不紧急 → LOW    + 无截止
   */
  private handleAddTodo(): void {
    const title: string = this.addTodoTitle.trim()
    if (title.length === 0) {
      promptAction.showToast({
        message: getContext(this).resourceManager.getStringSync($r('app.string.toast_input_empty').id)
      })
      return
    }
    const q: EisenhowerQuadrant = this.addTodoQuadrant
    const isImportant: boolean = q === EisenhowerQuadrant.Q1_IMPORTANT_URGENT ||
      q === EisenhowerQuadrant.Q2_IMPORTANT_NOT_URGENT
    const isUrgent: boolean = q === EisenhowerQuadrant.Q1_IMPORTANT_URGENT ||
      q === EisenhowerQuadrant.Q3_NOT_IMPORTANT_URGENT

    const priority: TaskPriority = isImportant
      ? TaskPriority.HIGH
      : (q === EisenhowerQuadrant.Q3_NOT_IMPORTANT_URGENT ? TaskPriority.MEDIUM : TaskPriority.LOW)
    let deadline: number = 0
    if (isUrgent) {
      const now: Date = new Date()
      deadline = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 23, 59, 59).getTime()
    }

    const added: boolean = homeVM.addManualTask(title, priority, deadline)
    if (!added) {
      promptAction.showToast({
        message: getContext(this).resourceManager.getStringSync($r('app.string.home_toast_operation_failed_prefix').id)
      })
      return
    }
    this.showAddTodoSheet = false
    promptAction.showToast({
      message: getContext(this).resourceManager.getStringSync($r('app.string.toast_task_added').id)
    })
  }

  @Monitor('quadrantSignal')
  onQuadrantSignalChange(): void {
    if (this.quadrantSignal.length > 0) {
      this.syncEisenhowerDataSources()
    }
  }
  /** 象限卡拖拽松手后吞掉紧随的一次 onClick（防拖拽换位后误开半模态） */
  private suppressQuadrantCardClick: boolean = false

  /**
   * 四象限自定义排序（可长按拖拽调整）
   * - 初始为默认顺序 Q1→Q2→Q3→Q4
   * - aboutToAppear 从 StorageManager 加载持久化顺序
   * - 拖拽完成后调用 saveQuadrantOrder 持久化
   */
  @Local quadrantOrder: EisenhowerQuadrant[] = DEFAULT_QUADRANT_ORDER.slice()

  /** 当前正在拖拽的象限索引（-1 表示未拖拽） */
  @Local draggingIndex: number = -1

  /**
   * 拖拽会话锁：记录本次手势起始的象限索引，-1 = 无会话。
   *
   * ⚠️ 为什么必须加锁：`onTouch` 挂在**每张象限卡**上，而 `longPressTimerId` /
   * `touchStartScreenX/Y` / `draggingIndex` 都是**页面级共享字段**。双指同时按两张卡时：
   *   ① 第二指的 Down 覆盖起始坐标，并用新句柄覆盖 `longPressTimerId`
   *      —— 旧句柄丢失但**旧定时器仍会触发**，两个定时器各自把 `draggingIndex` 置成自己那张卡；
   *   ② 之后任一手指的 Move 都用被覆盖后的起始坐标算位移 → 目标象限算错；
   *   ③ 松手时按错误的 targetIndex 交换并 `saveQuadrantOrder()` **持久化**
   *      → 用户排序被莫名打乱，且重启后依然是错的。
   * 加锁后只认**第一个按下**的那张卡，其余手指的事件直接丢弃。
   */
  private dragSessionIndex: number = -1

  /** 拖拽偏移量 X（vp） */
  @Local dragOffsetX: number = 0

  /** 拖拽偏移量 Y（vp） */
  @Local dragOffsetY: number = 0

  /** 触摸起始全局坐标（用于计算位移） */
  private touchStartScreenX: number = 0
  private touchStartScreenY: number = 0

  /** 长按定时器 ID */
  private longPressTimerId: number = -1

  /** 组件是否已挂载（异步回调防御） */
  private isAttached: boolean = false

  /** 窗口宽度缓存（vp），用于拖拽跨格阈值计算 */
  private windowWidthVp: number = 360

  onPageShow(): void {
    this.greeting = getGreeting(getContext(this))
    Logger.info('HomePage', 'onPageShow: greeting=' + this.greeting)
    this.forceSyncDataSource()
    this.refreshWindowWidth()
  }

  /**
   * build 之后更新四象限信号，触发 @Monitor 同步四象限 DataSource
   * （数据加载完成时 build 重渲染 → 此处补同步，避免平板右栏常驻面板空白）
   *
   * 信号 = q1,q2,q3,q4 四个计数拼串：任务增删、勾选完成、**跨象限迁移**（deadline
   * 跨过 24h 线 / 优先级调整）任一发生都会改变信号 → 精确触发一次 DataSource 同步；
   * 平时每分钟的 nowMinute 刷新若未引起任何象限计数变化，信号不变，不产生多余同步。
   */
  onDidBuild(): void {
    const signal: string = this.viewModel.eisenhowerMatrix.q1.count.toString() + ',' +
      this.viewModel.eisenhowerMatrix.q2.count.toString() + ',' +
      this.viewModel.eisenhowerMatrix.q3.count.toString() + ',' +
      this.viewModel.eisenhowerMatrix.q4.count.toString()
    if (this.quadrantSignal !== signal) {
      this.quadrantSignal = signal
    }
  }

  /**
   * 异步获取窗口宽度并缓存到 windowWidthVp
   * - 折叠屏/平板宽度不同，拖拽跨格阈值需依赖真实窗口宽度
   * - 通过 window.getLastWindow 获取（UIContext 无 getWindowInfo，DisplayKit 未引入）
   */
  private refreshWindowWidth(): void {
    try {
      window.getLastWindow(getContext(this)).then((win: window.Window): void => {
        const props: window.WindowProperties = win.getWindowProperties()
        // windowRect 单位是 px（真机实测：平板横屏 2800px / density 2.5 = 1120vp），需 px2vp 换算
        const widthVp: number = px2vp(props.windowRect.width)
        if (widthVp > 0) {
          this.windowWidthVp = widthVp
          Logger.info('HomePage', 'refreshWindowWidth success, vp=' + this.windowWidthVp.toString())
        }
      }).catch((e: Error): void => {
        Logger.warn('HomePage', 'refreshWindowWidth failed: ' + e.message)
      })
    } catch (e) {
      Logger.warn('HomePage', 'refreshWindowWidth exception: ' + (e as Error).message)
    }
  }

  aboutToAppear(): void {
    this.isAttached = true
    this.loadQuadrantOrder()
    // HomePage 不是 @Entry 页面，onPageShow 不保证触发；窗口宽度改在这里取，
    // 保证四象限拖拽跨格阈值用的是真实窗口宽度（默认 360 在平板上会偏大）
    this.refreshWindowWidth()
    // 悬浮按钮：读显隐偏好 + 订阅智感握姿（与 RoutePage 共用同一个偏好与同一个服务单例）
    this.loadFabVisible().catch((e: Error): void => {
      Logger.warn('HomePage', 'loadFabVisible failed: ' + e.message)
    })
    this.syncGripSubscription().catch((e: Error): void => {
      Logger.warn('HomePage', 'syncGripSubscription failed: ' + e.message)
    })
  }

  /**
   * 释放拖拽会话（幂等）：清长按定时器 + 复位拖拽态 + 释放会话锁 + 恢复 Tabs 滑动。
   * Up / Cancel / 手指全抬起 / 页面消失 四条路径统一走这里，避免任何一条漏清理导致
   * "会话锁残留 → 象限卡再也拖不动"。
   */
  private releaseDragSession(): void {
    if (this.longPressTimerId !== -1) {
      clearTimeout(this.longPressTimerId)
      this.longPressTimerId = -1
    }
    this.draggingIndex = -1
    this.dragOffsetX = 0
    this.dragOffsetY = 0
    this.dragSessionIndex = -1
    dragState.isDragging = false
  }

  aboutToDisappear(): void {
    this.isAttached = false
    this.releaseDragSession()
  }

  /** 从 StorageManager 加载四象限排序 */
  private async loadQuadrantOrder(): Promise<void> {
    try {
      const saved: string[] = await StorageManager.loadData<string[]>(
        getContext(this),
        CommonConstants.STORAGE_KEY_QUADRANT_ORDER,
        []
      )
      if (saved.length === 4) {
        this.quadrantOrder = stringsToQuadrantOrder(saved)
        Logger.info('HomePage', 'loadQuadrantOrder: ' + this.quadrantOrder.join(','))
      }
    } catch (e) {
      Logger.error('HomePage', 'loadQuadrantOrder failed: ' + (e as Error).message)
    }
  }

  /** 保存四象限排序到 StorageManager */
  private saveQuadrantOrder(): void {
    const strs: string[] = quadrantOrderToStrings(this.quadrantOrder)
    StorageManager.saveData(
      getContext(this),
      CommonConstants.STORAGE_KEY_QUADRANT_ORDER,
      strs
    ).then((): void => {
      Logger.info('HomePage', 'saveQuadrantOrder success: ' + strs.join(','))
    }).catch((e: Error): void => {
      Logger.error('HomePage', 'saveQuadrantOrder failed: ' + e.message)
    })
  }

  // 首页主体为四象限矩阵，需同步四象限 DataSource
  // 注：搜索栏已移除（原 todoDataSource 无 UI 绑定，属断路遗留物），仅同步四象限
  private forceSyncDataSource(): void {
    this.syncEisenhowerDataSources()
  }

  /**
   * 同步四象限数据源：从 @Computed eisenhowerMatrix 读取分类后任务 → 更新四个 DataSource
   * 为什么需要手动同步：@Computed 自动重算 eisenhowerMatrix，但 DataSource 是独立副本无响应式绑定
   * 调用时机：半模态打开时 / 半模态内勾选任务后 / forceSyncDataSource（首页数据变更后）
   */
  private syncEisenhowerDataSources(): void {
    this.q1DataSource.updateAll(this.viewModel.getTasksByQuadrant(EisenhowerQuadrant.Q1_IMPORTANT_URGENT))
    this.q2DataSource.updateAll(this.viewModel.getTasksByQuadrant(EisenhowerQuadrant.Q2_IMPORTANT_NOT_URGENT))
    this.q3DataSource.updateAll(this.viewModel.getTasksByQuadrant(EisenhowerQuadrant.Q3_NOT_IMPORTANT_URGENT))
    this.q4DataSource.updateAll(this.viewModel.getTasksByQuadrant(EisenhowerQuadrant.Q4_NOT_IMPORTANT_NOT_URGENT))
  }

  /**
   * 打开指定象限的半模态
   * - 设置 activeQuadrant 控制半模态标题与数据源
   * - 同步四象限数据源（确保最新数据）
   * - 触发 bindSheet 显示
   *
   * @param quadrant - 点击的象限枚举
   */
  private onOpenQuadrantSheet(quadrant: EisenhowerQuadrant): void {
    this.activeQuadrant = quadrant
    this.syncEisenhowerDataSources()
    this.showEisenhowerSheet = true
  }

  /**
   * 获取当前激活象限的数据源
   * - 半模态内 List+LazyForEach 绑定此数据源
   * - 根据 activeQuadrant 返回对应的 DataSource
   */
  private getActiveDataSource(): EisenhowerQuadrantDataSource {
    if (this.activeQuadrant === EisenhowerQuadrant.Q1_IMPORTANT_URGENT) return this.q1DataSource
    if (this.activeQuadrant === EisenhowerQuadrant.Q2_IMPORTANT_NOT_URGENT) return this.q2DataSource
    if (this.activeQuadrant === EisenhowerQuadrant.Q3_NOT_IMPORTANT_URGENT) return this.q3DataSource
    return this.q4DataSource
  }

  /**
   * 获取指定象限的任务总数，用于首页象限卡片右上角徽标展示
   */
  private getQuadrantCount(quadrant: EisenhowerQuadrant): number {
    if (quadrant === EisenhowerQuadrant.Q1_IMPORTANT_URGENT) {
      return this.viewModel.eisenhowerMatrix.q1.count
    }
    if (quadrant === EisenhowerQuadrant.Q2_IMPORTANT_NOT_URGENT) {
      return this.viewModel.eisenhowerMatrix.q2.count
    }
    if (quadrant === EisenhowerQuadrant.Q3_NOT_IMPORTANT_URGENT) {
      return this.viewModel.eisenhowerMatrix.q3.count
    }
    return this.viewModel.eisenhowerMatrix.q4.count
  }

  /**
   * 获取指定象限的任务列表，用于首页象限卡片预览前 2 个任务标题
   */
  private getQuadrantTasks(quadrant: EisenhowerQuadrant): Array<HomeTodoItem> {
    return this.viewModel.getTasksByQuadrant(quadrant)
  }

  // ===== 象限视觉映射方法 =====

  /** 象限标题资源 */
  private getQuadrantTitleRes(quadrant: EisenhowerQuadrant): Resource {
    if (quadrant === EisenhowerQuadrant.Q1_IMPORTANT_URGENT) {
      return $r('app.string.eisenhower_q1_title')
    }
    if (quadrant === EisenhowerQuadrant.Q2_IMPORTANT_NOT_URGENT) {
      return $r('app.string.eisenhower_q2_title')
    }
    if (quadrant === EisenhowerQuadrant.Q3_NOT_IMPORTANT_URGENT) {
      return $r('app.string.eisenhower_q3_title')
    }
    return $r('app.string.eisenhower_q4_title')
  }

  /** 象限副标题（行动指引） */
  private getQuadrantDescRes(quadrant: EisenhowerQuadrant): Resource {
    if (quadrant === EisenhowerQuadrant.Q1_IMPORTANT_URGENT) {
      return $r('app.string.eisenhower_q1_desc')
    }
    if (quadrant === EisenhowerQuadrant.Q2_IMPORTANT_NOT_URGENT) {
      return $r('app.string.eisenhower_q2_desc')
    }
    if (quadrant === EisenhowerQuadrant.Q3_NOT_IMPORTANT_URGENT) {
      return $r('app.string.eisenhower_q3_desc')
    }
    return $r('app.string.eisenhower_q4_desc')
  }

  /** 象限主题色（竖条/角标文字） */
  private getQuadrantThemeColor(quadrant: EisenhowerQuadrant): ResourceColor {
    if (quadrant === EisenhowerQuadrant.Q1_IMPORTANT_URGENT) {
      return $r('app.color.quadrant_urgent_text')
    }
    if (quadrant === EisenhowerQuadrant.Q2_IMPORTANT_NOT_URGENT) {
      return $r('app.color.quadrant_important_text')
    }
    if (quadrant === EisenhowerQuadrant.Q3_NOT_IMPORTANT_URGENT) {
      return $r('app.color.quadrant_effective_text')
    }
    return $r('app.color.quadrant_marginal_text')
  }

  /** 象限淡色角标背景（10% 透明度） */
  private getQuadrantBadgeBg(quadrant: EisenhowerQuadrant): ResourceColor {
    if (quadrant === EisenhowerQuadrant.Q1_IMPORTANT_URGENT) {
      return $r('app.color.quadrant_urgent_bg')
    }
    if (quadrant === EisenhowerQuadrant.Q2_IMPORTANT_NOT_URGENT) {
      return $r('app.color.quadrant_important_bg')
    }
    if (quadrant === EisenhowerQuadrant.Q3_NOT_IMPORTANT_URGENT) {
      return $r('app.color.quadrant_effective_bg')
    }
    return $r('app.color.quadrant_marginal_bg')
  }

  /**
   * 象限内任务勾选
   * 透传到 ViewModel.toggleTask（已含 actualCompletionTime 自动维护）
   * 勾选后立即 syncEisenhowerDataSources：已完成的任务会被 @Computed eisenhowerMatrix 过滤掉，从象限中消失
   */
  private toggleEisenhowerTask(taskId: Id): void {
    this.viewModel.toggleTask(taskId)
    this.syncEisenhowerDataSources()
  }

  /**
   * 四象限看板卡片 Builder
   * 首页主体区 2x2 矩阵的每个格子，展示：象限标题 + 任务总数徽标 + 前 2 个任务标题预览
   * 点击拉起半模态展示该象限完整任务列表
   * AI 添加的 Q1 任务会在此卡片中实时显示（通过 getQuadrantCount/getQuadrantTasks 读取 @Computed）
   */
  @Builder
  EisenhowerQuadrantCardBuilder(quadrant: EisenhowerQuadrant, quadIndex: number) {
    Row() {
      // 左侧彩色竖条（4vp 宽，区分象限）
      Column() {}
        .width(4)
        .height('100%')
        .backgroundColor(this.getQuadrantThemeColor(quadrant))
        .borderRadius(2)

      // 右侧内容区
      Column({ space: 6 }) {
        // 标题行：象限标题 + 右上角数量徽标
        Row() {
          Text(this.getQuadrantTitleRes(quadrant))
            .fontSize(CommonConstants.FONT_SIZE_BODY)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)

          // 数量角标（右上角，半透明背景）
          if (this.getQuadrantCount(quadrant) > 0) {
            Text(this.getQuadrantCount(quadrant).toString())
              .fontSize(CommonConstants.FONT_SIZE_XS)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.getQuadrantThemeColor(quadrant))
              .backgroundColor(this.getQuadrantBadgeBg(quadrant))
              .borderRadius(DimensConstants.RADIUS_M)
              .padding({ left: 7, right: 7, top: 2, bottom: 2 })
          } else {
            Text('0')
              .fontSize(CommonConstants.FONT_SIZE_XS)
              .fontColor($r('app.color.text_tertiary'))
              .backgroundColor($r('app.color.bg_tag'))
              .borderRadius(DimensConstants.RADIUS_M)
              .padding({ left: 7, right: 7, top: 2, bottom: 2 })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        // 行动指引副标题
        Text(this.getQuadrantDescRes(quadrant))
          .fontSize(CommonConstants.FONT_SIZE_XXS)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)

        // 任务预览区：仅展示前 2 条，避免多任务时无谓渲染全部标题
        if (this.getQuadrantCount(quadrant) === 0) {
          Column() {}
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
        } else {
          Column({ space: 6 }) {
            ForEach(this.getQuadrantTasks(quadrant).slice(0, breakpointState.isTablet ? 3 : 2), (task: HomeTodoItem, taskIdx: number): void => {
              Text(safeStringUtil(task.title,
                getContext(this).resourceManager.getStringSync($r('app.string.default_unnamed_task').id)))
                .fontSize(CommonConstants.FONT_SIZE_CAPTION)
                .fontColor(taskIdx === 0 ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }, (task: HomeTodoItem, taskIdx: number): string => task.id + '_' + taskIdx.toString())
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
      }
      .layoutWeight(1)
      .height('100%')
      .padding(12)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    // 高度由 Grid 行高（rowsTemplate 1fr 1fr）决定，从而铺满屏幕；不再写死 150/200vp
    .height('100%')
    .constraintSize({ minHeight: 120 })
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(DimensConstants.RADIUS_L)
    .border({
      width: breakpointState.isTablet && this.activeQuadrant === quadrant ? 2 : 0,
      color: breakpointState.isTablet && this.activeQuadrant === quadrant
        ? this.getQuadrantThemeColor(quadrant)
        : Color.Transparent
    })
    .shadow({ radius: 4, color: $r('app.color.shadow_card'), offsetX: 0, offsetY: 1 })
    .clip(true)
    .accessibilityText(
      getContext(this).resourceManager.getStringSync(this.getQuadrantTitleRes(quadrant).id) + '，' +
      getContext(this).resourceManager.getStringSync($r('app.string.acc_quadrant_card').id)
        .replace('%d', this.getQuadrantCount(quadrant).toString()))
    .opacity(this.draggingIndex === quadIndex ? 0.5 : 1.0)
    .scale(this.draggingIndex === quadIndex
      ? { x: 1.05, y: 1.05 }
      : { x: 1.0, y: 1.0 })
    .offset(this.draggingIndex === quadIndex
      ? { x: this.dragOffsetX, y: this.dragOffsetY }
      : { x: 0, y: 0 })
    .zIndex(this.draggingIndex === quadIndex ? 100 : 0)
    // 长按拖拽跟手：刻意用短促非弹性曲线 —— 弹簧会让位移落后于手指、拖出"糊"的观感
    .animation(MotionConstants.pressParam())
    .onTouch((event: TouchEvent): void => {
      // 兜底：所有手指都已抬起 → 无条件释放会话（防会话锁残留导致象限卡再也拖不动）
      if (event.touches.length === 0) {
        this.releaseDragSession()
        return
      }
      // ⚠️ 多指竞态防护：onTouch 挂在每张卡上，而会话字段（longPressTimerId /
      //   touchStartScreenX/Y / draggingIndex）是页面级共享的。只认第一个按下的那张卡，
      //   其余手指的事件一律丢弃，否则会算出错误的 targetIndex 并持久化坏排序。
      if (this.dragSessionIndex !== -1 && this.dragSessionIndex !== quadIndex) {
        return
      }
      const touch: TouchObject = event.touches[0]

      if (event.type === TouchType.Down) {
        // 同一张卡上多指重复 Down：会话已建立，忽略后续手指
        if (this.dragSessionIndex === quadIndex) {
          return
        }
        // 认领本次手势会话
        this.dragSessionIndex = quadIndex
        // 记录起始全局坐标，启动长按定时器
        this.touchStartScreenX = touch.screenX
        this.touchStartScreenY = touch.screenY
        // 立即通知 MainTab 禁用 Tabs 滑动，防止长按期间页面晃动
        dragState.isDragging = true
        this.longPressTimerId = setTimeout((): void => {
          this.draggingIndex = quadIndex
          this.dragOffsetX = 0
          this.dragOffsetY = 0
          promptAction.showToast({ message: $r('app.string.home_drag_release_hint'), duration: 1500 })
        }, 500)
      } else if (event.type === TouchType.Move) {
        if (this.draggingIndex === quadIndex) {
          // 拖拽中：用全局坐标计算位移，跟手
          this.dragOffsetX = touch.screenX - this.touchStartScreenX
          this.dragOffsetY = touch.screenY - this.touchStartScreenY
        } else if (this.longPressTimerId !== -1) {
          // 长按等待中：移动超过 10vp 则取消长按
          const moveDist: number = Math.abs(touch.screenX - this.touchStartScreenX) +
            Math.abs(touch.screenY - this.touchStartScreenY)
          if (moveDist > 10) {
            clearTimeout(this.longPressTimerId)
            this.longPressTimerId = -1
            // 取消长按，恢复 Tabs 滑动（会话锁保留到抬起，避免期间被别的卡接管）
            dragState.isDragging = false
          }
        }
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        // 只有在拖拽态且是正常抬起时，才执行象限交换
        if (this.draggingIndex === quadIndex && event.type === TouchType.Up) {
          const targetIndex: number = this.calcTargetIndex(this.dragOffsetX, this.dragOffsetY)
          if (targetIndex >= 0 && targetIndex < this.quadrantOrder.length && targetIndex !== quadIndex) {
            const tmp: EisenhowerQuadrant = this.quadrantOrder[quadIndex]
            this.quadrantOrder[quadIndex] = this.quadrantOrder[targetIndex]
            this.quadrantOrder[targetIndex] = tmp
            this.saveQuadrantOrder()
          }
          // 拖拽松手后会触发一次 onClick：置标志吞掉，防止拖完误开半模态
          // （onClick 在 onTouch.Up 之后触发，此时 draggingIndex 已复位，原防护失效）
          this.suppressQuadrantCardClick = true
        }
        this.releaseDragSession()
      }
    })
    .onClick((): void => {
      if (this.draggingIndex >= 0) return
      if (this.suppressQuadrantCardClick) {
        this.suppressQuadrantCardClick = false
        return
      }
      if (breakpointState.isTablet) {
        // 平板：点击象限切换右侧常驻面板，不拉半模态
        this.activeQuadrant = quadrant
        this.syncEisenhowerDataSources()
      } else {
        this.onOpenQuadrantSheet(quadrant)
      }
    })
  }

  /**
   * 根据拖拽位移计算目标格子索引
   * - 四象限 2x2 布局：左上=0, 右上=1, 左下=2, 右下=3
   * - 水平位移 > 阈值视为跨列
   * - 垂直位移 > 阈值视为跨行
   */
  private calcTargetIndex(offsetX: number, offsetY: number): number {
    // 卡片宽度动态计算：窗口宽度 - 左右 padding 32 - 列间距 8 后均分两列
    // 兼容折叠屏/平板等不同宽度，避免硬编码 160vp 在小屏/大屏上误判跨格
    // UIContext 无 getWindowInfo()，DisplayKit 未引入，改用 onPageShow 缓存宽度
    const cardWidth: number = Math.max(80, (this.windowWidthVp - 32 - 8) / 2)
    const threshold: number = cardWidth * 0.4
    const isHorizontalCross: boolean = Math.abs(offsetX) > threshold
    const isVerticalCross: boolean = Math.abs(offsetY) > threshold
    const currentRow: number = Math.floor(this.draggingIndex / 2)
    const currentCol: number = this.draggingIndex % 2

    let targetRow: number = currentRow
    let targetCol: number = currentCol

    if (isHorizontalCross) {
      targetCol = offsetX > 0
        ? Math.min(currentCol + 1, 1)
        : Math.max(currentCol - 1, 0)
    }
    if (isVerticalCross) {
      targetRow = offsetY > 0
        ? Math.min(currentRow + 1, 1)
        : Math.max(currentRow - 1, 0)
    }
    return targetRow * 2 + targetCol
  }

  /**
   * 主页空态引导行（只占一行，不与页面骨架抢空间）
   *
   * ⚠️ 这里刻意**只给一个去向明确**的入口：首页没有"手动添加待办"的能力
   *   （待办只能来自「AI 拆解目标 → 确认方案」或「从路线页摘取任务」），
   *   若在此放"手动添加"，用户点了无处可去。
   */
  @Builder
  EmptyGuideRowBuilder() {
    Row({ space: 8 }) {
      Text($r('app.string.home_empty_message'))
        .fontSize(CommonConstants.FONT_SIZE_SMALL)
        .fontColor($r('app.color.text_secondary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Text($r('app.string.home_empty_cta'))
        .fontSize(CommonConstants.FONT_SIZE_SMALL)
        .fontColor($r('app.color.primary_color'))
        .fontWeight(FontWeight.Medium)
        .padding({ left: 12, right: 12, top: 5, bottom: 5 })
        .borderRadius(DimensConstants.RADIUS_L)
        .backgroundColor($r('app.color.primary_color_bg'))
        .onClick((): void => {
          globalTabsController.changeIndex(TAB_INDEX.AI)
        })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(DimensConstants.RADIUS_L)
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 四象限矩阵（手机与平板共用），由调用方决定外层容器与内边距
   */
  @Builder
  QuadrantMatrixBuilder() {
    Grid() {
      ForEach(this.quadrantOrder, (q: EisenhowerQuadrant, idx: number): void => {
        GridItem() {
          this.EisenhowerQuadrantCardBuilder(q, idx)
        }
      }, (q: EisenhowerQuadrant): string => q)
    }
    .columnsTemplate('1fr 1fr')
    // 两行等分：让 2x2 矩阵吃满外层可用高度（此前只给 columnsTemplate，Grid 按内容自适应 → 底部留白）
    .rowsTemplate('1fr 1fr')
    .columnsGap(8)
    .rowsGap(8)
    .width('100%')
    .height('100%')
  }

  /** 象限空态占位（半模态与平板右侧面板共用） */
  @Builder
  QuadrantEmptyBuilder() {
    Column({ space: 8 }) {
      Column()
        .width(56)
        .height(56)
        .borderRadius(28)
        .backgroundColor($r('app.color.bg_tag'))
        .border({ width: 1.5, color: $r('app.color.divider') })
      Text($r('app.string.eisenhower_empty_quadrant'))
        .fontSize(CommonConstants.FONT_SIZE_BODY)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 象限任务单行（半模态与平板右栏共用）
   * @param task - 任务项
   */
  @Builder
  QuadrantTaskItemBuilder(task: HomeTodoItem) {
    ListItem() {
      if (this.pendingDeleteTaskId === task.id) {
        // 行内二次确认（成熟做法）：不新增浮层 ⇒ 不会再和半模态叠两层；
        // 「删除」用**实心危险色**（系统弹窗只能文字色，做不到）
        Row({ space: 8 }) {
          Text(getContext(this).resourceManager.getStringSync($r('app.string.home_delete_task_title').id) +
            '"' + safeStringUtil(task.title,
              getContext(this).resourceManager.getStringSync($r('app.string.default_unnamed_task').id)) + '"？')
            .fontSize(CommonConstants.FONT_SIZE_SMALL)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)

          Button($r('app.string.dialog_cancel'))
            .type(ButtonType.Capsule)
            .height(30)
            .padding({ left: 14, right: 14 })
            .backgroundColor(Color.Transparent)
            .fontColor($r('app.color.text_secondary'))
            .fontSize(CommonConstants.FONT_SIZE_SMALL)
            .onClick((): void => {
              this.pendingDeleteTaskId = ''
            })

          Button($r('app.string.btn_delete'))
            .type(ButtonType.Capsule)
            .height(30)
            .padding({ left: 16, right: 16 })
            .backgroundColor($r('app.color.error_color'))
            .fontColor($r('app.color.text_inverse'))
            .fontSize(CommonConstants.FONT_SIZE_SMALL)
            .onClick((): void => {
              this.doDeleteTask(task)
            })
        }
        .width('100%')
        .padding({ left: 16, right: 12, top: 12, bottom: 12 })
        .alignItems(VerticalAlign.Center)
        .backgroundColor($r('app.color.bg_card'))
      } else {
      TaskListItemComponent({
        task: task,
        onToggle: (id: Id): void => {
          this.toggleEisenhowerTask(id)
        },
        onLongPress: (t: HomeTodoItem): void => {
          this.openMoveQuadrantMenu(t)
        },
        onNavigate: (todo: HomeTodoItem): void => {
          this.navigateToTaskDetail(todo)
        }
      })
      }
    }
    .backgroundColor(Color.Transparent)
    .swipeAction({ end: this.deleteBuilder(task), edgeEffect: SwipeEdgeEffect.None })
    // "移动象限"菜单：锚定在被长按的那一行上（只有目标任务所在的那一行会显示）
    // 挂在 ListItem 上（ListItem 继承 CommonMethod，支持 bindPopup），不往 @ReusableV2 的
    // TaskListItemComponent 内部挂浮层 —— 复用组件里挂弹层容易串状态。
    .bindPopup(this.showMoveMenu && this.moveMenuTask !== null && this.moveMenuTask.id === task.id,
      {
        builder: this.MoveQuadrantMenuBuilder,
        placement: Placement.Bottom,
        popupColor: $r('app.color.bg_card'),
        enableArrow: true,
        autoCancel: true,
        // 点外部/返回键收起时回写状态：否则 showMoveMenu 停在 true，
        // 再次长按同一行时 show 值没变化，弹层不会再打开
        onStateChange: (event: PopupVisibilityEvent): void => {
          if (!event.isVisible) {
            this.showMoveMenu = false
          }
        }
      })
  }

  /**
   * "移动象限"菜单内容（锚定弹层，读组件状态）
   *
   * ⚠️ 不接收形参：@Builder 的形参是按值传递、不建立状态依赖，菜单必须在打开那一刻
   *    读到最新的 this.moveMenuTask / this.moveMenuCurrent，所以这里直读组件状态。
   */
  @Builder
  MoveQuadrantMenuBuilder() {
    Column({ space: 2 }) {
      // 顶部任务名：让用户确认"操作的是这一项"
      Text(safeStringUtil(this.moveMenuTask === null ? '' : this.moveMenuTask.title,
        getContext(this).resourceManager.getStringSync($r('app.string.default_unnamed_task').id)))
        .fontSize(CommonConstants.FONT_SIZE_XS)
        .fontColor($r('app.color.text_tertiary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .padding({ left: 14, right: 14, top: 10, bottom: 6 })

      ForEach(DEFAULT_QUADRANT_ORDER, (q: EisenhowerQuadrant): void => {
        Row({ space: 8 }) {
          // 当前象限用圆点标记（不用 SymbolGlyph：符号名需逐个核实，圆点零依赖且清晰）
          Circle({ width: 6, height: 6 })
            .fill(this.moveMenuCurrent === q ? $r('app.color.primary_color') : Color.Transparent)

          Text(getContext(this).resourceManager.getStringSync(quadrantLabelUtil(q).id) +
            (this.moveMenuCurrent === q
              ? getContext(this).resourceManager.getStringSync($r('app.string.home_quadrant_current_suffix').id)
              : ''))
            .fontSize(CommonConstants.FONT_SIZE_BODY)
            .fontWeight(this.moveMenuCurrent === q ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.moveMenuCurrent === q ? $r('app.color.primary_color') : $r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
        .height(44)
        .padding({ left: 14, right: 14 })
        .alignItems(VerticalAlign.Center)
        .onClick((): void => {
          const target: HomeTodoItem | null = this.moveMenuTask
          const isCurrent: boolean = this.moveMenuCurrent === q
          // 先收起菜单再执行动作（动作内部会弹 toast/可能再弹层）
          this.closeMoveQuadrantMenu()
          if (target !== null && !isCurrent) {
            this.applyQuadrantMove(target, q)
          }
        })
      }, (q: EisenhowerQuadrant): string => q)
    }
    .width(228)
    .padding({ top: 4, bottom: 6 })
  }

  /**
   * 平板右栏任务列表：直接读 @Computed 象限数据（响应式，无需手动同步 DataSource）
   * 为什么不复用 QuadrantTaskListBuilder：右栏是常驻面板，冷启动即渲染，
   * 而 q1~q4DataSource 是独立副本、只在半模态/数据变更回调时同步 → 曾出现右栏空白。
   * 直接绑定 getTasksByQuadrant 结果可随 taskList(@Trace) 自动刷新。
   * @param hPadding - 列表左右内边距
   */
  @Builder
  QuadrantPaneTaskListBuilder(hPadding: number) {
    List({ space: 12 }) {
      ForEach(this.viewModel.getTasksByQuadrant(this.activeQuadrant), (task: HomeTodoItem): void => {
        this.QuadrantTaskItemBuilder(task)
      }, (task: HomeTodoItem): string => task.id)
    }
    .width('100%')
    .layoutWeight(1)
    .cachedCount(3)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: false })
    .padding({ left: hPadding, right: hPadding, bottom: 16 })
  }

  /**
   * 象限任务列表（半模态使用；LazyForEach 适配长列表）
   * @param hPadding - 列表左右内边距
   */
  @Builder
  QuadrantTaskListBuilder(hPadding: number) {
    List({ space: 12 }) {
      LazyForEach(this.getActiveDataSource(), (task: HomeTodoItem, index: number): void => {
        this.QuadrantTaskItemBuilder(task)
      }, (task: HomeTodoItem, index: number): string => {
        return task.id
      })
    }
    .width('100%')
    .layoutWeight(1)
    .cachedCount(3)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: false })
    .padding({ left: hPadding, right: hPadding, bottom: 16 })
  }

  /** 平板右侧常驻任务面板：点击左侧象限格切换，替代半模态 */
  @Builder
  QuadrantPaneBuilder() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(this.getQuadrantTitleRes(this.activeQuadrant))
          .fontSize(CommonConstants.FONT_SIZE_SUBTITLE)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.getQuadrantThemeColor(this.activeQuadrant))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        Text(getContext(this).resourceManager.getStringSync($r('app.string.home_quadrant_count_prefix').id) +
          this.getQuadrantCount(this.activeQuadrant).toString() +
          getContext(this).resourceManager.getStringSync($r('app.string.home_quadrant_count_suffix').id))
          .fontSize(CommonConstants.FONT_SIZE_SMALL)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .padding({ left: 4, right: 4, top: 4 })
      .alignItems(VerticalAlign.Center)

      if (this.getQuadrantCount(this.activeQuadrant) === 0) {
        this.QuadrantEmptyBuilder()
      } else {
        this.QuadrantPaneTaskListBuilder(4)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_card_variant'))
    .borderRadius(DimensConstants.RADIUS_L)
    .padding(8)
  }

  /**
   * 四象限矩阵半模态内容
   * - 点击首页某象限卡片后拉起，展示该象限完整任务列表
   * - 顶部标题根据 activeQuadrant 动态变化
   * - 单象限 List + LazyForEach 渲染任务详情，复用 TaskListItemComponent
   */
  @Builder
  EisenhowerSheetBuilder() {
    Column({ space: 12 }) {
      // 顶部标题区：根据 activeQuadrant 动态显示
      Column({ space: 4 }) {
        Text(this.getQuadrantTitleRes(this.activeQuadrant))
          .fontSize(CommonConstants.FONT_SIZE_SUBTITLE)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.getQuadrantThemeColor(this.activeQuadrant))
        Row({ space: 8 }) {
          Text(this.getQuadrantDescRes(this.activeQuadrant))
            .fontSize(CommonConstants.FONT_SIZE_SMALL)
            .fontColor($r('app.color.text_tertiary'))
          Text(getContext(this).resourceManager.getStringSync($r('app.string.home_quadrant_count_prefix').id) +
            this.getQuadrantCount(this.activeQuadrant).toString() +
            getContext(this).resourceManager.getStringSync($r('app.string.home_quadrant_count_suffix').id))
            .fontSize(CommonConstants.FONT_SIZE_SMALL)
            .fontColor($r('app.color.text_secondary'))
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 8 })
      .alignItems(HorizontalAlign.Start)

      // 任务列表区：空态 / 完整任务列表（共用 Builder）
      if (this.getQuadrantCount(this.activeQuadrant) === 0) {
        this.QuadrantEmptyBuilder()
      } else {
        this.QuadrantTaskListBuilder(16)
      }

      // 已完成任务折叠区：勾选后不再"凭空消失"，可查看、点击可反悔
      if (this.viewModel.completedTasks.length > 0) {
        this.CompletedSectionBuilder()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }

  /** 已完成任务折叠区（半模态内）：默认收起，展开后点击条目可撤销完成 */
  @Builder
  CompletedSectionBuilder() {
    Column({ space: 8 }) {
      // 折叠头：标题 + 数量 + 展开/收起箭头
      Row({ space: 6 }) {
        Text($r('app.string.home_completed_section_title'))
          .fontSize(CommonConstants.FONT_SIZE_BODY)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_secondary'))
        Text(this.viewModel.completedTasks.length.toString())
          .fontSize(CommonConstants.FONT_SIZE_SMALL)
          .fontColor($r('app.color.text_tertiary'))
        Blank()
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(14)
          .fontColor([$r('app.color.text_tertiary')])
          .rotate({ angle: this.showCompletedSection ? 180 : 0 })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 4 })
      .onClick((): void => {
        this.showCompletedSection = !this.showCompletedSection
      })

      if (this.showCompletedSection) {
        List({ space: 8 }) {
          ForEach(this.viewModel.completedTasks, (task: HomeTodoItem): void => {
            ListItem() {
              Row({ space: 8 }) {
                SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
                  .fontSize(16)
                  .fontColor([$r('app.color.success_color')])
                Text(task.title)
                  .fontSize(CommonConstants.FONT_SIZE_BODY)
                  .fontColor($r('app.color.text_tertiary'))
                  .decoration({ type: TextDecorationType.LineThrough, color: $r('app.color.text_tertiary') })
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                Text($r('app.string.home_completed_undo_hint'))
                  .fontSize(CommonConstants.FONT_SIZE_XS)
                  .fontColor($r('app.color.primary_color'))
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
              .onClick((): void => {
                // 反悔：恢复为未完成（toggleTask 会联动 routeVM 回滚 L2/进度并重排提醒）
                this.toggleEisenhowerTask(task.id)
              })
            }
          }, (task: HomeTodoItem): string => task.id + '_' + task.isCompleted.toString())
        }
        .width('100%')
        .height(160)
        .scrollBar(BarState.Off)
        .padding({ left: 0, right: 0 })
      }
    }
    .width('100%')
  }

  /** 内容列限宽：平板（lg）双栏上限 DUAL_MAX_WIDTH，手机/折叠屏保持 640 居中 */
  private getPageConstraint(): ConstraintSizeOptions {
    if (breakpointState.isTablet) {
      const dual: ConstraintSizeOptions = { maxWidth: DimensConstants.DUAL_MAX_WIDTH }
      return dual
    }
    const capped: ConstraintSizeOptions = { maxWidth: DimensConstants.CONTENT_MAX_WIDTH }
    return capped
  }

  // 首页构建：三态切换（Loading → Error → Empty → 正常态四象限矩阵）
  // 正常态使用 Grid 2x2 布局，ForEach 遍历 quadrantOrder（支持长按拖拽自定义顺序）
  // 每个格子由 EisenhowerQuadrantCardBuilder 渲染，点击拉起半模态展示完整任务列表
  build() {
    Stack() {
      Column() {
      // 1. 吸顶标题栏：显示时段问候语（如"早上好同学"）替代原"首页"
      CommonTitleBar({
        title: this.greeting + getContext(this).resourceManager.getStringSync($r('app.string.home_greeting_suffix').id),
        showBack: false
      })

      // 2. 副标题：鼓励语
      Row() {
        Text($r('app.string.home_encourage_text')).fontSize(CommonConstants.FONT_SIZE_SMALL).fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 0, bottom: 4 })
      .alignItems(VerticalAlign.Center)

      // 3. 四象限矩阵标题行（搜索栏已移除：原实现 onChange 写入 todoDataSource，但 todoDataSource 无任何 UI 绑定，属断路遗留物）
      Row() {
        Text($r('app.string.eisenhower_sheet_title'))
          .fontSize(CommonConstants.FONT_SIZE_SUBTITLE)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        // C2：AI 今日排序建议入口按钮
        Button($r('app.string.home_suggestion_button'))
          .type(ButtonType.Capsule)
          .height(28)
          .padding({ left: 12, right: 12 })
          .backgroundColor($r('app.color.bg_tag'))
          .fontColor($r('app.color.primary_color'))
          .fontSize(CommonConstants.FONT_SIZE_SMALL)
          .onClick((): void => { this.handleTodaySuggestion() })
        Text(getContext(this).resourceManager.getStringSync($r('app.string.eisenhower_total_prefix').id) +
          (this.viewModel.eisenhowerMatrix.q1.count +
            this.viewModel.eisenhowerMatrix.q2.count +
            this.viewModel.eisenhowerMatrix.q3.count +
            this.viewModel.eisenhowerMatrix.q4.count).toString() +
          getContext(this).resourceManager.getStringSync($r('app.string.eisenhower_total_suffix').id))
          .fontSize(CommonConstants.FONT_SIZE_SMALL)
          .fontColor($r('app.color.text_tertiary'))
          .margin({ left: 8 })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 12 })
      .alignItems(VerticalAlign.Center)

      // 5. 主体区：统一三态（Loading / Empty / 四象限矩阵）
      if (this.viewModel.isFirstLoading) {
        // 加载态
        StateView({ mode: StateMode.LOADING, loadingText: $r('app.string.state_loading') })
      } else if (this.viewModel.loadError) {
        // 错误态：数据加载失败，提供重试
        StateView({
          mode: StateMode.ERROR,
          errorMessage: $r('app.string.state_error_desc'),
          onRetry: (): void => {
            this.viewModel.retryLoad()
          }
        })
      } else if (this.viewModel.liveTasks.length === 0) {
        // 空态：**保留四象限骨架**，引导压成一行
        // 设计取舍：原实现用 StateView(EMPTY) 的整页居中插画，会把四象限矩阵整个换掉 ——
        //   用户看不到"这个 App 是怎么组织的"，页面也显得空荡。
        //   现改为矩阵照常渲染（四象限卡片本就支持 0 条：角标显示 0、任务区留空），
        //   引导只占一行高度，页面骨架与正常态完全一致。
        Column() {
          this.EmptyGuideRowBuilder()

          Column() {
            this.QuadrantMatrixBuilder()
          }
          .width('100%')
          .layoutWeight(1)
          .margin({ top: 10 })
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 16, right: 16, bottom: safeAreaHelper.getBottomWith(DimensConstants.TAB_CLEARANCE) })
      } else if (breakpointState.isTablet) {
        // 正常态-平板：左象限矩阵 + 右常驻任务面板（点击左格右栏直接切换，替代半模态）
        Row({ space: 16 }) {
          Column() {
            this.QuadrantMatrixBuilder()
          }
          .layoutWeight(5)
          .height('100%')

          Column() {
            this.QuadrantPaneBuilder()
          }
          .layoutWeight(4)
          .height('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 16, right: 16, bottom: safeAreaHelper.getBottomWith(DimensConstants.TAB_CLEARANCE) })
      } else {
        // 正常态-手机：2x2 四象限矩阵铺满剩余高度（layoutWeight(1) + Grid 行等分）
        Column() {
          this.QuadrantMatrixBuilder()
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 16, right: 16, bottom: safeAreaHelper.getBottomWith(DimensConstants.TAB_CLEARANCE) })
      }
      }
      // 宽屏适配：内容列限宽居中（背景/弹层仍在 Stack 层铺满全屏）；平板铺满全宽
      .constraintSize(this.getPageConstraint())
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      // 阈值与 RoutePage 对齐用 [0.0]：[1.0] 在 Tab 切换时不可靠，会导致列表不刷新
      .onVisibleAreaChange([0.0], (isVisible: boolean, _currentRatio: number): void => {
        if (isVisible && this.viewModel.isLoaded) {
          this.forceSyncDataSource()
          // 切回首页时，「智感握姿 / 悬浮快捷按钮」可能刚在设置页被改过，重新同步
          // （HomePage 非 @Entry 页面，onPageShow 不保证触发，故挂在这里）
          this.loadFabVisible().catch((e: Error): void => {
            Logger.warn('HomePage', 'loadFabVisible failed: ' + e.message)
          })
          this.syncGripSubscription().catch((e: Error): void => {
            Logger.warn('HomePage', 'syncGripSubscription failed: ' + e.message)
          })
        }
      })
      // 四象限半模态（bindSheet）
      .bindSheet($$this.showEisenhowerSheet, this.EisenhowerSheetBuilder(), {
        height: SheetSize.LARGE,
        detents: [SheetSize.MEDIUM, SheetSize.LARGE],
        blurStyle: BlurStyle.BACKGROUND_THICK,
        showClose: true,
        dragBar: true,
        backgroundColor: $r('app.color.bg_page'),
        maskColor: $r('app.color.overlay_mask'),
        enableOutsideInteractive: false,
        onDisappear: (): void => {
          this.showEisenhowerSheet = false
          Logger.info('HomePage', 'Eisenhower sheet dismissed')
        }
      })
      // 悬浮快捷按钮（FAB）：与 RoutePage 同一套几何 + 智感握姿 + 长按隐藏
      // 全屏容器 + hitTestBehavior(Transparent)：空白处点击穿透到下层内容
      if (this.viewModel.isLoaded && this.fabVisible) {
        Stack() {
          Button({ type: ButtonType.Circle }) {
            Text('+')
              .fontSize(CommonConstants.FONT_SIZE_HUGE)
              .fontColor($r('app.color.text_inverse'))
              .fontWeight(FontWeight.Bold)
          }
          .width(this.FAB_SIZE)
          .height(this.FAB_SIZE)
          .backgroundColor($r('app.color.primary_color'))
          .shadow({ radius: 12, color: $r('app.color.shadow_card'), offsetX: 0, offsetY: 4 })
          .position({ x: this.fabX(), y: this.fabY() })
          // 换边过渡：position 可动画 + 响应式弹簧，让按钮"带惯性滑"过去而不是匀速平移
          .animation(MotionConstants.springParam())
          .onClick((): void => {
            this.openAddTodoSheet()
          })
          // 长按 600ms = 隐藏按钮（恢复入口在设置页「悬浮快捷按钮」）
          .gesture(
            LongPressGesture({ repeat: false, duration: 600 })
              .onAction((): void => {
                this.handleFabLongPress()
              })
          )
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
        .onAreaChange((_oldArea: Area, newArea: Area): void => {
          const w: number = Number(newArea.width)
          const h: number = Number(newArea.height)
          if (!Number.isNaN(w) && !Number.isNaN(h) && w > 0 && h > 0) {
            this.fabAreaW = w
            this.fabAreaH = h
          }
        })
      }

      // C2 今日排序建议全屏弹层（Stack 层叠；置于 Stack 层不受内容限宽影响）
      if (this.showSuggestionSheet) {
        this.SuggestionCoverBuilder()
      }

      // 统一操作面板（替代系统 showActionMenu/showDialog）
      if (this.showActionSheet) {
        AppActionSheet({
          title: this.actionSheetTitle,
          items: this.actionSheetItems,
          onDismiss: (): void => {
            this.showActionSheet = false
          }
        })
      }
    }
    // 「添加待办」半模态（bindSheet）
    // ⚠️ 必须用 bindSheet，不能用页面内自绘 Stack 层：自绘层位于 HdsTabs 的**内容区之内**，
    //    会被悬浮胶囊 TabBar 压住底部按钮（真机已复现），详见 AddTodoSheetBuilder 注释。
    // 挂在根 Stack 上（而非内容 Column）：内容 Column 已被「四象限半模态」占用，
    // 避免在同一个组件上重复调用 bindSheet。
    .bindSheet($$this.showAddTodoSheet, this.AddTodoSheetBuilder(), {
      // FIT_CONTENT：面板高度随表单内容自适应，不写死高度
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: false,
      backgroundColor: $r('app.color.bg_card'),
      maskColor: $r('app.color.overlay_mask'),
      enableOutsideInteractive: false,
      onDisappear: (): void => {
        this.showAddTodoSheet = false
        Logger.info('HomePage', 'add-todo sheet dismissed')
      }
    })
  }

  /**
   * 打开任务详情页（行点击 / 右滑「编辑」共用）
   * - 只有关联了目标的待办才有步骤可看；孤立待办给出明确提示（原来静默无反馈，用户以为"点了没反应"）
   */
  private navigateToTaskDetail(todo: HomeTodoItem): void {
    if (!todo.relatedTaskId || !todo.relatedGoalId || !todo.id || todo.id.length === 0) {
      promptAction.showToast({
        message: getContext(this).resourceManager.getStringSync($r('app.string.home_toast_task_detail_unavailable').id)
      })
      return
    }
    this.showEisenhowerSheet = false
    const detailItem: TaskDetailItem = new TaskDetailItem(
      todo.id, todo.title, '', todo.duration, todo.priority, todo.isCompleted, todo.createTime)
    const param: TaskDetailRouteNavParam = {
      id: todo.id,
      task: detailItem,
      goalId: todo.relatedGoalId,
      relatedTaskId: todo.relatedTaskId
    }
    pushNavPath(ROUTE_NAME.TASK_DETAIL, param)
  }

  /** 执行删除（行内确认后调用）：删数据 + 刷新数据源 + 清确认态 + 提示 */
  private doDeleteTask(task: HomeTodoItem): void {
    const taskTitle: string = safeStringUtil(task.title,
      getContext(this).resourceManager.getStringSync($r('app.string.default_unnamed_task').id))
    this.pendingDeleteTaskId = ''
    if (!this.viewModel.isLoaded) return
    this.viewModel.deleteTask(task.id)
    this.forceSyncDataSource()
    promptAction.showToast({
      message: getContext(this).resourceManager.getStringSync($r('app.string.toast_deleted_prefix').id) + taskTitle + '"',
      duration: 1500
    })
    Logger.info('HomePage', 'inline delete confirmed, id=' + task.id + ', title=' + taskTitle)
  }

  @Builder
  deleteBuilder(task: HomeTodoItem) {
    Row() {
      // 「编辑」：打开任务详情（成熟做法：右滑同时给"改"与"删"，不用先关列表）
      // 孤立待办没有详情，隐藏该按钮而不是点了报错
      if (task.relatedTaskId && task.relatedGoalId) {
        Row() {
          Text($r('app.string.dialog_edit_task'))
            .fontSize(CommonConstants.FONT_SIZE_SMALL)
            .fontColor($r('app.color.text_primary'))
            .fontWeight(FontWeight.Medium)
            .textAlign(TextAlign.Center)
        }
        .width(76)
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .backgroundColor($r('app.color.bg_tag'))
        .onClick((): void => {
          this.navigateToTaskDetail(task)
        })
      }

       Column({ space: 4 }) {
         SymbolGlyph($r('sys.symbol.trash'))
           .fontSize(CommonConstants.FONT_SIZE_LARGE)
           .fontColor([$r('app.color.text_inverse')])
            .accessibilityText(getContext(this).resourceManager.getStringSync($r('app.string.acc_delete').id))
          Text($r('app.string.home_swipe_delete'))
          .fontSize(CommonConstants.FONT_SIZE_BODY)
          .fontColor($r('app.color.text_inverse'))
          .fontWeight(FontWeight.Medium)
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .width(88)
    .height('100%')
    .backgroundColor($r('app.color.error_color'))
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .onClick((): void => {
      this.confirmDeleteTask(task)
    })
  }

  /**
   * 进入行内确认态（替代原 ActionSheet）
   * 原因：ActionSheet/系统弹窗与"四象限半模态"叠成两层 —— 关掉确认框还要再关列表；
   * 且系统弹窗只能放文字按钮，做不到"确认键实心深色"。行内确认两个问题一起解决。
   */
  private confirmDeleteTask(task: HomeTodoItem): void {
    this.pendingDeleteTaskId = task.id
  }

  /**
   * C2 今日排序建议：调用 AI 分析今日待办并展示排序建议弹层
   * - 打开弹层即进入加载态
   * - 成功后展示纯文本建议；失败 toast 并关闭弹层
   */
  /**
   * 长按任务 → 打开"移动象限"菜单（象限反向操作入口）
   *
   * 象限本身是"优先级 × 截止时间"的派生结果，移动 = 反推底层字段并联动全链路。
   * 菜单是锚定在被长按那一行上的 bindPopup（见 QuadrantTaskItemBuilder），
   * 不再走页面级底部面板 —— 面板会被四象限半模态（bindSheet）压住且贴在屏幕底部，
   * 与被长按的那一项毫无空间关系。
   *
   * 顺序要求：先把目标任务与当前象限写进状态、再置位显示。
   * bindPopup 的 builder 在显示那一刻读取这两个状态，因此不依赖任何生命周期回调，无竞态。
   */
  private openMoveQuadrantMenu(task: HomeTodoItem): void {
    this.moveMenuTask = task
    this.moveMenuCurrent = classifyEisenhowerQuadrant(task.priority, task.deadline)
    this.showMoveMenu = true
    Logger.info('HomePage', 'openMoveQuadrantMenu: id=' + task.id +
      ', current=' + this.moveMenuCurrent)
  }

  /** 收起"移动象限"菜单（选中项 / 点外部 / 返回键都会回到这里） */
  private closeMoveQuadrantMenu(): void {
    this.showMoveMenu = false
    this.moveMenuTask = null
  }

  /**
   * 象限移动换算：目标象限 → 优先级 + 截止时间（保持"双输入"机制，联动既有链路）
   * 换算后经 routeVM.updateTask → TASK_INFO_UPDATED → L4 同步 + 截止提醒重排 + 象限重算
   */
  private applyQuadrantMove(task: HomeTodoItem, target: EisenhowerQuadrant): void {
    const DAY_MS: number = 24 * 60 * 60 * 1000
    const now: number = Date.now()
    // 未来某天 23:59:59（days 天后）
    const endOfDaysLater: (days: number) => number = (days: number): number => {
      const d: Date = new Date(now)
      d.setDate(d.getDate() + days)
      d.setHours(23, 59, 59, 0)
      return d.getTime()
    }
    // 确保"紧急"：无截止或截止超 24h → 明天 23:59
    const ensureUrgent: (deadline: number) => number = (deadline: number): number => {
      return (deadline > 0 && deadline <= now + DAY_MS) ? deadline : endOfDaysLater(1)
    }
    // 确保"不紧急"：已逾期或 24h 内 → 顺延 7 天；否则保持
    const ensureNotUrgent: (deadline: number) => number = (deadline: number): number => {
      return (deadline > 0 && deadline > now + DAY_MS) ? deadline : endOfDaysLater(7)
    }

    let newPriority: TaskPriority = task.priority
    let newDeadline: number = task.deadline
    if (target === EisenhowerQuadrant.Q1_IMPORTANT_URGENT) {
      newPriority = TaskPriority.HIGH
      newDeadline = ensureUrgent(task.deadline)
    } else if (target === EisenhowerQuadrant.Q2_IMPORTANT_NOT_URGENT) {
      newPriority = TaskPriority.HIGH
      newDeadline = ensureNotUrgent(task.deadline)
    } else if (target === EisenhowerQuadrant.Q3_NOT_IMPORTANT_URGENT) {
      newPriority = task.priority === TaskPriority.HIGH ? TaskPriority.MEDIUM : task.priority
      newDeadline = ensureUrgent(task.deadline)
    } else {
      newPriority = TaskPriority.LOW
      newDeadline = task.deadline > 0 ? ensureNotUrgent(task.deadline) : 0
    }

    // 字段无变化（选了当前象限）则跳过
    if (newPriority === task.priority && newDeadline === task.deadline) {
      return
    }

    // 反查 L2 任务（updateTask 需要名称与时长）
    const l2 = routeVM.findTask(task.relatedGoalId, task.relatedTaskId)
    if (l2 === null) {
      promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.home_toast_task_detail_unavailable').id), duration: 1500 })
      return
    }
    const success: boolean = routeVM.updateTask(task.relatedGoalId, task.relatedTaskId,
      l2.taskName, l2.estimatedTime > 0 ? l2.estimatedTime : 30, newPriority, newDeadline)
    if (success) {
      // 联动链路：updateTask → TASK_INFO_UPDATED → L4 同步/提醒重排 → 象限重算，此处仅提示结果
      promptAction.showToast({
        message: getContext(this).resourceManager.getStringSync($r('app.string.home_moved_to_prefix').id) +
          getContext(this).resourceManager.getStringSync(quadrantLabelUtil(target).id),
        duration: 1500
      })
    }
  }

  private handleTodaySuggestion(): void {
    // 防重入：加载中重复点击会重复发起 AI 请求
    if (this.suggestionLoading) {
      return
    }
    const todoInput: TodayTodoInput = ProfileAnalyzerService.buildTodayTodoData(this.viewModel)
    const todoData: string = todoInput.data
    if (todoData.length === 0) {
      promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_suggestion_empty').id), duration: 1500 })
      return
    }
    this.showSuggestionSheet = true
    this.suggestionLoading = true
    this.suggestionText = ''
    DeepSeekService.getInstance().generateTodaySuggestion(todoData).then((report: string): void => {
      if (!this.isAttached) return
      this.suggestionLoading = false
      if (report.length === 0) {
        this.suggestionText = ''
        this.showSuggestionSheet = false
        promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_suggestion_failed').id), duration: 1500 })
        return
      }
      // 本地回填：把模型回复里的「任务N」还原为真实待办名称（名称从未发送给模型）
      this.suggestionText = ProfileAnalyzerService.substituteTaskLabels(report, todoInput.titles)
      Logger.info('HomePage', 'handleTodaySuggestion success, reportLen=' + report.length.toString())
    }).catch((e: Error): void => {
      Logger.error('HomePage', 'handleTodaySuggestion failed: ' + e.message)
      if (!this.isAttached) return
      this.suggestionLoading = false
      this.showSuggestionSheet = false
      promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_suggestion_failed').id), duration: 1500 })
    })
  }

  /**
   * 「添加待办」表单（作为 bindSheet 的内容，由 build 中的 bindSheet 挂载）
   *
   * ⚠️ **必须是 bindSheet，不能是页面内自绘 Stack 层**（真机已复现遮挡）：
   *    自绘层位于 HdsTabs 的**内容区之内**，而悬浮胶囊 TabBar 由 HdsTabs 组件自身
   *    绘制在内容区之上 —— 于是自绘层无论怎么调 padding / zIndex，底部的
   *    「确认 / 取消」都会被 TabBar 压掉一截；遮罩同样盖不住 TabBar，
   *    模态态下还能点它切页（不合规范）。
   *    bindSheet 是页面级独立浮层，能正常盖住 TabBar，并自带遮罩、圆角、拖拽条
   *    与键盘避让；与首页「四象限半模态」同款，交互风格一致。
   *
   * 交互差异：这里选的是**象限**而不是分类。四象限是首页的主视觉，
   * "这件事放哪一格"比让用户填"优先级 + 截止时间"直观得多
   * （四象限本就是这两个字段派生出来的，反推关系见 handleAddTodo）。
   */
  @Builder
  AddTodoSheetBuilder() {
    Column() {
      Text($r('app.string.home_add_todo_title'))
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .margin({ bottom: 16 })

      TextInput({
        placeholder: $r('app.string.home_add_todo_placeholder'),
        text: this.addTodoTitle
      })
        .width('100%')
        .height(48)
        .fontSize(16)
        .borderRadius(DimensConstants.RADIUS_M)
        .backgroundColor($r('app.color.bg_search'))
        .padding({ left: 16, right: 16 })
        .maxLength(30)
        .onChange((value: string): void => {
          this.addTodoTitle = value
        })
        .margin({ bottom: 16 })

      Text($r('app.string.home_add_todo_quadrant_label'))
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ bottom: 8 })

      Grid() {
        ForEach(this.quadrantOrder, (q: EisenhowerQuadrant): void => {
          GridItem() {
            Text(quadrantLabelUtil(q))
              .fontSize(13)
              .fontColor(this.addTodoQuadrant === q ?
                $r('app.color.text_inverse') : $r('app.color.text_primary'))
              .backgroundColor(this.addTodoQuadrant === q ?
                $r('app.color.primary_color') : $r('app.color.bg_search'))
              .borderRadius(DimensConstants.RADIUS_M)
              .textAlign(TextAlign.Center)
              .width('100%')
              .height(40)
              .onClick((): void => {
                this.addTodoQuadrant = q
              })
          }
        }, (q: EisenhowerQuadrant): string => q)
      }
      .columnsTemplate('1fr 1fr')
      .columnsGap(8)
      .rowsGap(8)
      .width('100%')
      .height(88)
      .margin({ bottom: 20 })

      Row({ space: 12 }) {
        Button() {
          Text($r('app.string.btn_cancel'))
            .fontSize(15)
            .fontColor($r('app.color.text_secondary'))
        }
        .layoutWeight(1)
        .height(44)
        .borderRadius(DimensConstants.RADIUS_XL)
        .backgroundColor($r('app.color.bg_search'))
        .onClick((): void => {
          this.showAddTodoSheet = false
        })

        Button() {
          Text($r('app.string.btn_add_to_today'))
            .fontSize(15)
            .fontColor($r('app.color.text_inverse'))
            .fontWeight(FontWeight.Medium)
        }
        .layoutWeight(1)
        .height(44)
        .borderRadius(DimensConstants.RADIUS_XL)
        .backgroundColor($r('app.color.primary_color'))
        .onClick((): void => {
          this.handleAddTodo()
        })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 8, bottom: 24 })
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * C2 今日排序建议全屏弹层（Stack 层叠，替代 bindContentCover）
   * - 加载态：Loading + 提示文案
   * - 完成态：可滚动建议文本 + 关闭按钮
   */
  @Builder
  SuggestionCoverBuilder() {
    AppReportSheet({
      title: getContext(this).resourceManager.getStringSync($r('app.string.suggestion_sheet_title').id),
      loading: this.suggestionLoading,
      text: this.suggestionText,
      loadingText: getContext(this).resourceManager.getStringSync($r('app.string.suggestion_loading').id),
      onClose: (): void => {
        this.showSuggestionSheet = false
      }
    })
  }
}
