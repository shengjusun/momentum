// 首页工作台：艾森豪威尔四象限矩阵 + 任务勾选/导航/滑动删除

import { HomeTodoItem, Id, TaskPriority, TaskDetailRouteNavParam, TaskDetailItem,
  EisenhowerQuadrant } from '../model/Models'
import { homeVM, HomeViewModel } from '../viewmodel/HomeViewModel'
import { globalNavStack, globalTabsController, TAB_INDEX, ROUTE_NAME, navigateTo, pushNavPath } from '../common/RouterManager'
import { settingsVM } from '../viewmodel/SettingsViewModel'
import { Logger } from '../common/utils/Logger'
import { safeStringUtil, safeNumberUtil } from '../common/utils/SafeUtils'
import { priorityLabelUtil, priorityBgColorUtil, priorityTextColorUtil } from '../common/utils/PriorityUtils'
import { promptAction, window } from '@kit.ArkUI'
import { Context } from '@kit.AbilityKit'
import { EisenhowerQuadrantDataSource } from '../common/datasource/TaskDataSource'
import { CommonTitleBar } from '../common/components/CommonTitleBar'
import { StateView, StateMode } from '../common/components/StateView'
import { StorageManager } from '../common/utils/StorageManager'
import { CommonConstants } from '../common/constants/CommonConstants'
import { DimensConstants } from '../common/constants/DimensConstants'
import { dragState } from './MainTab'
import { safeAreaHelper } from '../common/utils/SafeAreaHelper'
import { DeepSeekService } from '../common/services/DeepSeekService'
import { ProfileAnalyzerService } from '../common/services/ProfileAnalyzerService'
import { breakpointState } from '../common/utils/BreakpointState'

/* ============================================================
 * 顶层工具函数
 * ============================================================ */

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
        Text('✓')
          .fontSize(CommonConstants.FONT_SIZE_BODY)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_inverse'))
          .width(22)
          .height(22)
          .borderRadius(11)
          .backgroundColor($r('app.color.success_color'))
          .textAlign(TextAlign.Center)
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
            .borderRadius(4)

          if (safeNumberUtil(parseInt(this.task.duration), 0) > 0) {
            Text(this.task.duration + 'min')
              .fontSize(CommonConstants.FONT_SIZE_XS)
              .fontColor($r('app.color.text_tertiary'))
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
    .borderRadius(12)
    .shadow({ radius: 4, color: $r('app.color.shadow_card'), offsetX: 0, offsetY: 1 })
    .onClick((): void => {
      this.onNavigate(this.task)
    })
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
  /** C2 今日排序建议：弹层显示/加载中/报告文本 */
  @Local showSuggestionSheet: boolean = false
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
   * 任务总数追踪（驱动四象限 DataSource 同步）
   * 为什么需要：q1~q4DataSource 是 eisenhowerMatrix 的独立副本，无响应式绑定。
   * 之前只在"打开半模态 / 数据变更后可见性回调"时同步，平板右栏（常驻面板）
   * 冷启动首次渲染时数据源还是空的 → 面板空白。用 @Local + @Monitor 在
   * build 之后统一补一次同步（模式与 RoutePage.goalCount 一致）。
   */
  @Local quadrantTaskTotal: number = -1
  @Monitor('quadrantTaskTotal')
  onQuadrantTaskTotalChange(): void {
    if (this.quadrantTaskTotal >= 0) {
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
   * build 之后更新任务总数，触发 @Monitor 同步四象限 DataSource
   * （数据加载完成时 build 重渲染 → 此处补同步，避免平板右栏常驻面板空白）
   */
  onDidBuild(): void {
    const total: number = this.viewModel.taskList.length
    if (this.quadrantTaskTotal !== total) {
      this.quadrantTaskTotal = total
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
  }

  aboutToDisappear(): void {
    this.isAttached = false
    if (this.longPressTimerId !== -1) {
      clearTimeout(this.longPressTimerId)
      this.longPressTimerId = -1
    }
    if (this.draggingIndex >= 0) {
      this.draggingIndex = -1
    }
    dragState.isDragging = false
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
              .borderRadius(10)
              .padding({ left: 7, right: 7, top: 2, bottom: 2 })
          } else {
            Text('0')
              .fontSize(CommonConstants.FONT_SIZE_XS)
              .fontColor($r('app.color.text_tertiary'))
              .backgroundColor($r('app.color.bg_tag'))
              .borderRadius(10)
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
    .borderRadius(16)
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
    .animation({ duration: 150, curve: Curve.EaseOut })
    .onTouch((event: TouchEvent): void => {
      if (event.touches.length === 0) return
      const touch: TouchObject = event.touches[0]

      if (event.type === TouchType.Down) {
        // 记录起始全局坐标，启动长按定时器
        this.touchStartScreenX = touch.screenX
        this.touchStartScreenY = touch.screenY
        // 立即通知 MainTab 禁用 Tabs 滑动，防止长按期间页面晃动
        dragState.isDragging = true
        this.longPressTimerId = setTimeout((): void => {
          this.draggingIndex = quadIndex
          this.dragOffsetX = 0
          this.dragOffsetY = 0
          promptAction.showToast({ message: $r('app.string.home_drag_release_hint'), duration: 1000 })
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
            // 取消长按，恢复 Tabs 滑动
            dragState.isDragging = false
          }
        }
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        // 清除长按定时器
        if (this.longPressTimerId !== -1) {
          clearTimeout(this.longPressTimerId)
          this.longPressTimerId = -1
        }
        // 如果在拖拽态且是正常抬起，执行交换
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
        this.draggingIndex = -1
        this.dragOffsetX = 0
        this.dragOffsetY = 0
        // 恢复 Tabs 滑动
        dragState.isDragging = false
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
      TaskListItemComponent({
        task: task,
        onToggle: (id: Id): void => {
          this.toggleEisenhowerTask(id)
        },
        onNavigate: (todo: HomeTodoItem): void => {
          if (todo.relatedTaskId && todo.relatedGoalId) {
            if (!todo.id || todo.id.length === 0) {
              promptAction.showToast({
                message: getContext(this).resourceManager.getStringSync(
                  $r('app.string.home_toast_task_detail_unavailable').id)
              })
              return
            }
            this.showEisenhowerSheet = false
            const detailItem: TaskDetailItem = new TaskDetailItem(
              todo.id,
              todo.title,
              '',
              todo.duration,
              todo.priority,
              todo.isCompleted,
              todo.createTime
            )
            const param: TaskDetailRouteNavParam = {
              id: todo.id,
              task: detailItem,
              goalId: todo.relatedGoalId,
              relatedTaskId: todo.relatedTaskId
            }
            pushNavPath(ROUTE_NAME.TASK_DETAIL, param)
          } else {
            promptAction.showToast({
              message: getContext(this).resourceManager.getStringSync(
                $r('app.string.home_toast_task_detail_unavailable').id)
            })
          }
        }
      })
    }
    .backgroundColor(Color.Transparent)
    .swipeAction({ end: this.deleteBuilder(task), edgeEffect: SwipeEdgeEffect.None })
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
    .borderRadius(16)
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
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
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
      } else if (this.viewModel.taskList.length === 0) {
        // 空态：无待办任务时引导用户去 AI 拆解
        StateView({
          mode: StateMode.EMPTY,
          emptyMessage: $r('app.string.home_empty_message'),
          ctaText: $r('app.string.home_empty_cta'),
          onCta: (): void => {
            globalTabsController.changeIndex(TAB_INDEX.AI)
          }
        })
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
      // C2 今日排序建议全屏弹层（Stack 层叠；置于 Stack 层不受内容限宽影响）
      if (this.showSuggestionSheet) {
        this.SuggestionCoverBuilder()
      }
    }
  }

  @Builder
  deleteBuilder(task: HomeTodoItem) {
    Row() {
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

  private confirmDeleteTask(task: HomeTodoItem): void {
    const taskTitle: string = safeStringUtil(task.title, getContext(this).resourceManager.getStringSync($r('app.string.default_unnamed_task').id))
    promptAction.showDialog({
      title: $r('app.string.home_delete_task_title'),
      message: getContext(this).resourceManager.getStringSync($r('app.string.home_delete_task_title').id) + '"' + taskTitle + '"？\n' + getContext(this).resourceManager.getStringSync($r('app.string.dialog_delete_message').id),
      buttons: [
        { text: $r('app.string.common_cancel'), color: $r('app.color.text_tertiary') },
        { text: $r('app.string.btn_delete'), color: $r('app.color.error_color') }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse): void => {
      if (!this.viewModel.isLoaded) return
      if (result.index === 1) {
        this.viewModel.deleteTask(task.id)
        this.forceSyncDataSource()
        Logger.info('HomePage', 'swipe delete confirmed, id=' + task.id + ', title=' + taskTitle)
        promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_deleted_prefix').id) + taskTitle + '"', duration: 1500 })
      }
    }).catch((e: Error): void => {
      Logger.error('HomePage', 'confirmDeleteTask showDialog failed: ' + e.message)
    })
  }

  /**
   * C2 今日排序建议：调用 AI 分析今日待办并展示排序建议弹层
   * - 打开弹层即进入加载态
   * - 成功后展示纯文本建议；失败 toast 并关闭弹层
   */
  private handleTodaySuggestion(): void {
    // 防重入：加载中重复点击会重复发起 AI 请求
    if (this.suggestionLoading) {
      return
    }
    const todoData: string = ProfileAnalyzerService.buildTodayTodoData(this.viewModel)
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
      this.suggestionText = report
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
   * C2 今日排序建议全屏弹层（Stack 层叠，替代 bindContentCover）
   * - 加载态：Loading + 提示文案
   * - 完成态：可滚动建议文本 + 关闭按钮
   */
  @Builder
  SuggestionCoverBuilder() {
    Column() {
      Column() {
        Row() {
          Text($r('app.string.suggestion_sheet_title'))
            .fontSize(CommonConstants.FONT_SIZE_SUBTITLE)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
          Button($r('app.string.common_close'))
            .type(ButtonType.Capsule)
            .height(32)
            .padding({ left: 16, right: 16 })
            .backgroundColor($r('app.color.bg_tag'))
            .fontColor($r('app.color.text_secondary'))
            .fontSize(CommonConstants.FONT_SIZE_CAPTION)
            .onClick((): void => { this.showSuggestionSheet = false })
        }
        .width('100%')

        if (this.suggestionLoading) {
          Column({ space: 12 }) {
            LoadingProgress()
              .width(40)
              .height(40)
              .color($r('app.color.primary_color'))
            Text($r('app.string.suggestion_loading'))
              .fontSize(CommonConstants.FONT_SIZE_CAPTION)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .margin({ top: 80 })
          .layoutWeight(1)
        } else {
          Scroll() {
            Text(this.suggestionText)
              .fontSize(CommonConstants.FONT_SIZE_BODY)
              .fontColor($r('app.color.text_primary'))
              .lineHeight(22)
              .width('100%')
              .copyOption(CopyOptions.LocalDevice)
          }
          .scrollBar(BarState.Off)
          .layoutWeight(1)
          .margin({ top: 12 })
        }
      }
      .width('100%')
      .height('78%')
      .padding(20)
      .backgroundColor($r('app.color.bg_card'))
      .borderRadius({ topLeft: 20, topRight: 20 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.End)
    .backgroundColor($r('app.color.overlay_mask'))
  }
}
