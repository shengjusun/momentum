// 任务详情页：任务标题/耗时/优先级 + L3 执行步骤列表 + 添加步骤与标记完成

import { breakpointState } from '../common/utils/BreakpointState'
import {
  TaskDetailItem,
  TaskStep,
  TaskPriority,
  TaskStatus,
  AiGeneratedTask,
  HomeTodoItem,
  isStepCompleted
} from '../model/Models'
import { CommonConstants } from '../common/constants/CommonConstants'
import { DimensConstants } from '../common/constants/DimensConstants'
import { promptAction } from '@kit.ArkUI'
import { Logger } from '../common/utils/Logger'
import { safeStringUtil, formatDeadlineUtil, formatEstimatedDuration } from '../common/utils/SafeUtils'
import { priorityLabelUtil, priorityBgColorUtil, priorityTextColorUtil, classifyEisenhowerQuadrant, quadrantLabelUtil, quadrantTextColorUtil, quadrantBgColorUtil } from '../common/utils/PriorityUtils'
import { routeVM } from '../viewmodel/RoutePageViewModel'
import { GoalCardItem } from '../model/RouteModels'
import { homeVM } from '../viewmodel/HomeViewModel'
import { globalNavStack } from '../common/RouterManager'
import { settingsVM } from '../viewmodel/SettingsViewModel'
import { CommonTitleBar } from '../common/components/CommonTitleBar'
import { AppActionSheet, AppActionSheetItem } from '../common/components/AppActionSheet'
import { StateView, StateMode } from '../common/components/StateView'
import { PomodoroTimerCard } from '../common/components/PomodoroTimerCard'
import { PomodoroImmersiveScreen } from '../common/components/PomodoroImmersiveScreen'
import { pomodoroService, PomodoroPhase } from '../common/services/PomodoroService'
import { safeAreaHelper } from '../common/utils/SafeAreaHelper'
import { MotionConstants } from '../common/constants/MotionConstants'
import { MotionHelper } from '../common/utils/MotionHelper'

/**
 * 任务详情页
 */
@ComponentV2
export struct TaskDetailPage {
  /** 任务数据（V2: @Local） */
  @Local task: TaskDetailItem = new TaskDetailItem(
    '', '', '', '', TaskPriority.MEDIUM, false, 0
  )
  /** 新步骤输入文本 */
  @Local newStepText: string = ''
  /**
   * 关联的 L1 目标 ID
   * - 从路由参数读取（来自 GoalDetailPage.onTaskClick）
   * - 用于回写流：routeVM.updateStep(goalId, relatedTaskId, stepIndex, isCompleted)
   */
  @Local goalId: string = ''
  /**
   * 关联的 L2 任务 ID
   * - 从路由参数读取
   * - 用于反查 L2 任务：routeVM.findTask(goalId, relatedTaskId)
   */
  @Local relatedTaskId: string = ''
  /**
   * 当前加载的 L2 任务（@Trace 代理对象）
   * - null 时表示未找到 L2 任务（孤立 L4 任务）
   * - 不可变：routeVM 内部维护 @Trace 代理，本地仅持有引用
   */
  @Local l2Task: AiGeneratedTask | null = null
  @Local editingStepIndex: number = -1
  @Local editingStepText: string = ''
  /** 开始编辑时的原始文本（用于判断内容是否实际变更） */
  private editingStepOriginalText: string = ''
  @Local hasUnsavedChanges: boolean = false
  @Local pressedStepIndex: number = -1
  @Local pressedStepAction: string = ''
  /** 标记完成按钮按压态（统一 onTouch 范式，替代废弃的 stateStyles） */
  @Local pressedCompleteBtn: boolean = false
  /** 加载态 */
  @Local isLoading: boolean = true
  /** 错误态：路由参数缺失或解析失败 */
  @Local loadError: boolean = false

  private isAttached: boolean = false

  /** 番茄钟沉浸屏可见状态（由 pomodoroService 全局驱动） */
  @Local isPomodoroImmersiveVisible: boolean = false

  /** 任务编辑面板状态 */
  @Local showEditPanel: boolean = false
  @Local editTaskName: string = ''
  @Local editTaskDuration: string = ''
  /** 耗时单位倍率：1=分钟 60=小时 1440=天 */
  @Local editTaskDurationUnit: number = 1
  /** 编辑面板：优先级（默认中，打开时预填任务当前值） */
  @Local editTaskPriority: TaskPriority = TaskPriority.MEDIUM
  /** 编辑面板：截止时间戳（毫秒），0=未设置 */
  @Local editTaskDeadline: number = 0
  /** 聚焦统计摘要（空串=该任务暂无专注记录） */
  @Local focusSummary: string = ''
  /** 所属目标名（空串=无关联目标，概览卡不展示该行） */
  @Local goalNameText: string = ''
  /** 统一操作面板状态 */
  @Local showActionSheet: boolean = false
  @Local actionSheetTitle: string = ''
  @Local actionSheetItems: AppActionSheetItem[] = []
  /** 番茄钟完成回调 ID（注销用） */
  private focusCompleteCbId: number = -1
  /** 沉浸屏可见性回调 ID（注销用；多订阅模式下必须按 id 注销，不能整表清空） */
  private immersiveVisibleCbId: number = -1

  /* ============================================================
   * 派生状态：统一「步骤 ↔ 任务」完成口径（2026-09-17）
   * ============================================================
   * 本页"任务是否完成"的**唯一判据**（取代此前散落各处的 this.task.isCompleted 直读）：
   *   - 有 L2 任务：以 L2.status 为准 —— 该字段由两个入口共同维护且语义一致：
   *       · routeVM.updateStep（逐个勾步骤）
   *       · routeVM.setTaskCompletion（底部主按钮：批量设定全部步骤）
   *     两者都遵守「全部步骤完成 ⇔ COMPLETED」⇒ 用户逐个勾完最后一个步骤时，
   *     底部按钮 / 进度条 / 标题徽标会**自动**切到完成态，无需任何额外通知。
   *   - 无 L2 任务（孤立 L4 待办）：退化为本地快照 this.task.isCompleted。
   *
   * 注：@Computed 内部直读 @Trace 属性（this.l2Task.status、steps[i].isCompleted）即可
   *     建立响应式绑定，无需再靠 stepVersion 之类的"版本号兜底"（该字段已删除）。
   */
  @Computed
  get isTaskCompleted(): boolean {
    const l2: AiGeneratedTask | null = this.l2Task
    if (l2 !== null) {
      return l2.status === TaskStatus.COMPLETED
    }
    return this.task.isCompleted
  }

  /** 步骤总数（无 L2 / 无步骤时为 0） */
  @Computed
  get stepTotal(): number {
    const l2: AiGeneratedTask | null = this.l2Task
    if (l2 === null || !Array.isArray(l2.steps)) return 0
    return l2.steps.length
  }

  /** 已完成步骤数 */
  @Computed
  get stepCompletedCount(): number {
    const l2: AiGeneratedTask | null = this.l2Task
    if (l2 === null || !Array.isArray(l2.steps)) return 0
    let done: number = 0
    for (let i: number = 0; i < l2.steps.length; i++) {
      if (l2.steps[i].isCompleted) done++
    }
    return done
  }

  /** 步骤进度百分比（0~100，四舍五入）；无步骤时按整体完成态取 0 或 100 */
  @Computed
  get stepProgressPercent(): number {
    const total: number = this.stepTotal
    if (total === 0) return this.isTaskCompleted ? 100 : 0
    return Math.round((this.stepCompletedCount / total) * 100)
  }

  /** 刷新聚焦统计摘要（页面加载与每轮专注完成时调用） */
  private refreshFocusSummary(): void {
    if (!this.relatedTaskId || this.relatedTaskId.length === 0) {
      this.focusSummary = ''
      return
    }
    const todo: HomeTodoItem | undefined = homeVM.liveTasks.find(
      (t: HomeTodoItem): boolean => t.relatedTaskId === this.relatedTaskId)
    if (!todo || todo.focusCount === 0) {
      this.focusSummary = ''
      return
    }
    const rm = getContext(this).resourceManager
    this.focusSummary = rm.getStringByNameSync('task_focus_summary') +
      todo.focusCount.toString() + rm.getStringByNameSync('task_focus_count_unit') +
      ' · ' + formatEstimatedDuration(Math.round(todo.focusMillis / 60000), rm)
  }

  /** 刷新所属目标名（概览卡元信息行展示） */
  private refreshGoalName(): void {
    if (!this.goalId || this.goalId.length === 0) {
      this.goalNameText = ''
      return
    }
    const goal: GoalCardItem | null = routeVM.findGoal(this.goalId)
    this.goalNameText = goal !== null ? goal.name : ''
  }

  private readonly durationUnitOptions: number[] = [1, 60, 1440]
  /** 快捷档位（分钟值）：15 分钟 / 30 分钟 / 1 小时 / 2 小时 / 半天 / 1 天 */
  private readonly durationPresets: number[] = [15, 30, 60, 120, 720, 1440]

  private durationUnitLabel(unit: number): Resource {
    if (unit === 1440) return $r('app.string.duration_unit_day')
    if (unit === 60) return $r('app.string.duration_unit_hour')
    return $r('app.string.duration_unit_min')
  }

  /** 快捷档位完整文案（分钟值 → "15 分钟"/"半天"等） */
  private presetLabel(minutes: number): string {
    const rm = getContext(this).resourceManager
    if (minutes === 720) return rm.getStringByNameSync('duration_preset_half_day')
    if (minutes >= 1440) return (minutes / 1440).toString() + rm.getStringByNameSync('duration_unit_day')
    if (minutes >= 60) return (minutes / 60).toString() + rm.getStringByNameSync('duration_unit_hour')
    return minutes.toString() + rm.getStringByNameSync('duration_unit_min')
  }

  private applyPreset(minutes: number): void {
    if (minutes === 720) {
      this.editTaskDurationUnit = 60
      this.editTaskDuration = '12'
      return
    }
    if (minutes >= 1440) {
      this.editTaskDurationUnit = 1440
      this.editTaskDuration = (minutes / 1440).toString()
      return
    }
    if (minutes >= 60) {
      this.editTaskDurationUnit = 60
      this.editTaskDuration = (minutes / 60).toString()
      return
    }
    this.editTaskDurationUnit = 1
    this.editTaskDuration = minutes.toString()
  }

  /** 优先级档位文案 */
  private editPriorityLabel(p: TaskPriority): Resource {
    return priorityLabelUtil(p)
  }

  /** 弹出截止日期选择器 */
  private showEditDeadlinePicker(): void {
    DatePickerDialog.show({
      start: new Date(),
      end: new Date(Date.now() + 365 * 24 * 60 * 60 * 1000),
      selected: this.editTaskDeadline > 0 ? new Date(this.editTaskDeadline) : new Date(),
      onAccept: (value: DatePickerResult): void => {
        // 取当天 23:59:59 作为截止时间
        this.editTaskDeadline = new Date(value.year, value.month, value.day, 23, 59, 59).getTime()
      }
    })
  }

  aboutToAppear(): void {
    this.isAttached = true
    // 注册沉浸屏可见性变化回调（Stack 层叠方案，替代 bindContentCover）
    // 保存返回的回调 ID：Service 侧已改为多订阅，注销必须按 id，不能整表清空
    // （否则会把其他页面实例的回调一起清掉，导致状态不再同步）
    this.immersiveVisibleCbId = pomodoroService.onImmersiveVisibleChange((visible: boolean): void => {
      this.isPomodoroImmersiveVisible = visible
    })
    // 注册专注完成回调：每轮专注结束后刷新聚焦统计摘要
    this.focusCompleteCbId = pomodoroService.onComplete((_phase: PomodoroPhase): void => {
      if (this.isAttached) {
        this.refreshFocusSummary()
      }
    })
    // 注意：不在此处恢复沉浸屏可见性。此时 task 尚未从路由参数加载，
    // 无条件继承 Service 全局可见标志会导致"打开任意任务详情都被残留的全屏番茄钟覆盖"。
    // 恢复逻辑移至 onDestinationReady，并校验进行中的会话属于本任务。
  }

  aboutToDisappear(): void {
    this.isAttached = false
    // 注销专注完成回调
    if (this.focusCompleteCbId >= 0) {
      pomodoroService.offComplete(this.focusCompleteCbId)
      this.focusCompleteCbId = -1
    }
    // 页面退出时同步关闭沉浸屏：否则 Service 的可见标志残留，
    // 下次打开任意任务详情会在第一帧被全屏番茄钟覆盖（bug："点任务跳到番茄钟"根因）
    // 正常路径下（返回键先关全屏）这里已是 false，仅作兜底
    if (pomodoroService.isImmersiveVisible()) {
      pomodoroService.hideImmersive()
    }
    // 按 id 注销自己的沉浸屏回调（多订阅模式，不能整表清空）
    if (this.immersiveVisibleCbId >= 0) {
      pomodoroService.offImmersiveVisibleChange(this.immersiveVisibleCbId)
      this.immersiveVisibleCbId = -1
    }
  }

  /**
   * 加载 L2 任务
   * - 优先从 routeVM 反查
   * - 失败时给出提示（孤立 L4 任务，无法展示步骤）
   */
  private loadL2Task(): void {
    if (!this.goalId || !this.relatedTaskId) {
      Logger.warn('TaskDetailPage', 'loadL2Task: missing goalId/relatedTaskId')
      this.l2Task = null
      return
    }
    const found: AiGeneratedTask | null = routeVM.findTask(this.goalId, this.relatedTaskId)
    if (found) {
      this.l2Task = found
      Logger.info('TaskDetailPage', 'loadL2Task: found, taskId=' + found.id +
        ', steps=' + (Array.isArray(found.steps) ? found.steps.length : 0).toString())
    } else {
      Logger.warn('TaskDetailPage', 'loadL2Task: not found in routeVM, goalId=' +
        this.goalId + ', taskId=' + this.relatedTaskId)
      this.l2Task = null
    }
  }


  /**
   * L3 步骤渲染
   * - 数据源：l2Task.steps（TaskStep 对象数组 —— 2026-09-16 步骤对象化）
   * - 完成态：**直读 step.isCompleted（@Trace）** —— 修复（2026-09-17）：此前由调用方在
   *   ForEach itemGenerator 里预算 `isStepCompleted(l2Task, index)` 后**传值**，而步骤
   *   keyGenerator 已改为稳定 step.id（L1b 动效前提）→ 勾选后 key 不变、item 不重建、
   *   预算参数不更新 ⇒ 圆圈不刷新（stepVersion 自增也不再被任何 UI 消费，兜底失效）。
   *   改为传 step 对象、在 Builder 内直读 @Trace 属性 → 勾选后精确刷新对应节点。
   * - 勾选：toggleStep(index) → 走 routeVM.updateStep() 回写流
   *
   * @param step - 步骤对象（@ObservedV2，直读其 @Trace 字段建立精确绑定）
   * @param index - 步骤下标
   */
  /** 步骤左滑删除按钮（swipeAction end 区，替代常驻垃圾桶图标） */
  @Builder
  StepDeleteBuilder(index: number) {
    Row() {
      SymbolGlyph($r('sys.symbol.trash'))
        .fontSize(CommonConstants.FONT_SIZE_SUBTITLE)
        .fontColor([$r('app.color.text_inverse')])
    }
    .width(40)
    .height(40)
    .borderRadius(20)
    .backgroundColor($r('app.color.error_color'))
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .margin({ left: 8, top: 4, bottom: 4 })
    .onClick(() => { this.removeStep(index) })
  }

  @Builder
  StepItemBuilder(step: TaskStep, index: number): void {
    Row({ space: 10 }) {
      // 勾选圈：Checkbox 仅作纯视觉（18），外包 44×44 热区容器（触控规范）。
      // ⚠️ 事件不能挂在 Checkbox 上：HitTestMode.Block 会「阻塞子节点 + 祖先节点」的触摸测试
      //    （官方枚举原文），Checkbox 收不到触摸 → onChange 永不触发。
      //    故由容器自己 onClick 接管勾选，并借 Block 阻断父级整行 onClick（点勾不进入编辑态）。
      //    同款写法见 HomePage.CheckboxComponent。
      Row() {
        Checkbox()
          .select(step.isCompleted)
          .selectedColor($r('app.color.success_color'))
          .width(18).height(18)
          .hitTestBehavior(HitTestMode.None)
      }
      .constraintSize({ minWidth: DimensConstants.TOUCH_COMFORT, minHeight: DimensConstants.TOUCH_COMFORT })
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .hitTestBehavior(HitTestMode.Block)
      .onClick((): void => { this.toggleStep(index) })
      .accessibilityGroup(true)
      .accessibilityText(getContext(this).resourceManager.getStringSync($r('app.string.task_detail_complete_prefix_acc').id) + safeStringUtil(step.text, getContext(this).resourceManager.getStringSync($r('app.string.task_detail_unnamed_step').id)))

      if (this.editingStepIndex === index) {
        // 编辑模式：显示输入框
        TextInput({ placeholder: getContext(this).resourceManager.getStringSync($r('app.string.task_detail_edit_step_placeholder').id), text: this.editingStepText })
          .type(InputType.Normal)
          .layoutWeight(1)
          .height(36)
          .fontSize(CommonConstants.FONT_SIZE_BODY)
          .backgroundColor($r('app.color.bg_page'))
          .borderRadius(6)
          .padding({ left: 8, right: 8 })
          .onSubmit(() => { this.finishEditStep(index) })
          .onChange((value: string) => {
            this.editingStepText = value
            // 仅内容实际变更时标记未保存，进入编辑态本身不算修改（避免误弹"未保存"确认框）
            this.hasUnsavedChanges = value.trim() !== this.editingStepOriginalText.trim()
          })

        Row({ space: 6 }) {
           Row() {
             SymbolGlyph($r('sys.symbol.checkmark'))
               .fontSize(CommonConstants.FONT_SIZE_SUBTITLE)
               .fontColor([$r('app.color.success_color')])
           }
           .constraintSize({ minWidth: 44, minHeight: 44 })
           .borderRadius(DimensConstants.RADIUS_XL)
           .backgroundColor(this.pressedStepIndex === index && this.pressedStepAction === 'confirm' ? $r('app.color.bg_tag') : Color.Transparent)
           .scale({ x: this.pressedStepIndex === index && this.pressedStepAction === 'confirm' ? 0.9 : 1, y: this.pressedStepIndex === index && this.pressedStepAction === 'confirm' ? 0.9 : 1 })
           .animation(MotionConstants.pressParam())
           .accessibilityText(getContext(this).resourceManager.getStringSync($r('app.string.task_detail_confirm_edit_acc').id))
           .onClick(() => { this.finishEditStep(index) })
           .onTouch((event: TouchEvent): void => {
             if (event.type === TouchType.Down) {
               this.pressedStepIndex = index
               this.pressedStepAction = 'confirm'
             } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
               this.pressedStepIndex = -1
               this.pressedStepAction = ''
             }
           })

           Row() {
             SymbolGlyph($r('sys.symbol.xmark'))
               .fontSize(CommonConstants.FONT_SIZE_SUBTITLE)
               .fontColor([$r('app.color.text_tertiary')])
           }
           .constraintSize({ minWidth: 44, minHeight: 44 })
           .borderRadius(DimensConstants.RADIUS_XL)
           .backgroundColor(this.pressedStepIndex === index && this.pressedStepAction === 'cancel' ? $r('app.color.bg_tag') : Color.Transparent)
           .scale({ x: this.pressedStepIndex === index && this.pressedStepAction === 'cancel' ? 0.9 : 1, y: this.pressedStepIndex === index && this.pressedStepAction === 'cancel' ? 0.9 : 1 })
           .animation(MotionConstants.pressParam())
           .accessibilityText(getContext(this).resourceManager.getStringSync($r('app.string.task_detail_cancel_edit_acc').id))
           .onClick(() => { this.cancelEditStep() })
           .onTouch((event: TouchEvent): void => {
             if (event.type === TouchType.Down) {
               this.pressedStepIndex = index
               this.pressedStepAction = 'cancel'
             } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
               this.pressedStepIndex = -1
               this.pressedStepAction = ''
             }
           })
        }
      } else {
        // 显示模式：文本行（点击整行进入编辑；删除改由左滑触发，去除常驻图标）
        Text((index + 1).toString() + '. ' + safeStringUtil(step.text, getContext(this).resourceManager.getStringSync($r('app.string.task_unnamed_step').id)))
          .fontSize(CommonConstants.FONT_SIZE_BODY)

          .fontColor(step.isCompleted ? $r('app.color.text_tertiary') : $r('app.color.text_primary'))
          .decoration(step.isCompleted ? { type: TextDecorationType.LineThrough } : { type: TextDecorationType.None })
          .layoutWeight(1)
      }

      if (this.editingStepIndex === index) {
        Row() {
          SymbolGlyph($r('sys.symbol.trash'))
            .fontSize(CommonConstants.FONT_SIZE_SUBTITLE)
            .fontColor([$r('app.color.text_tertiary')])
        }
        .constraintSize({ minWidth: 44, minHeight: 44 })
        .borderRadius(DimensConstants.RADIUS_XL)
        .backgroundColor(this.pressedStepIndex === index && this.pressedStepAction === 'delete' ? $r('app.color.bg_tag') : Color.Transparent)
        .scale({ x: this.pressedStepIndex === index && this.pressedStepAction === 'delete' ? 0.9 : 1, y: this.pressedStepIndex === index && this.pressedStepAction === 'delete' ? 0.9 : 1 })
        .animation(MotionConstants.pressParam())
        .accessibilityText(getContext(this).resourceManager.getStringSync($r('app.string.task_detail_delete_step_acc').id))
        .onClick(() => { this.removeStep(index) })
        .onTouch((event: TouchEvent): void => {
          if (event.type === TouchType.Down) {
            this.pressedStepIndex = index
            this.pressedStepAction = 'delete'
          } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
            this.pressedStepIndex = -1
            this.pressedStepAction = ''
          }
        })
      }
    }
    .width('100%')
    .padding({ left: 4, right: 12, top: 4, bottom: 4 })
    .constraintSize({ minHeight: 48 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      // 点击整行进入编辑（非编辑态才响应，避免与编辑框/按钮冲突）
      // 注：左侧勾选圈因自身 HitTestMode.Block 不参与本回调，点圈只切换完成态
      if (this.editingStepIndex !== index) {
        // ⚠️ 取 step.text（不是旧签名里的 stepText）—— steps 对象化（2026-09-16）把
        //    StepItemBuilder 的入参从「文本值」换成了「TaskStep 对象」，本调用点当时漏改，
        //    残留的 stepText 已无声明 → `Cannot find name 'stepText'` 编译错。
        this.startEditStep(index, step.text)
      }
    })
  }

  /**
   * 步骤编辑：开始编辑
   * @param index - 步骤下标
   * @param text - 当前步骤文本
   */
  private startEditStep(index: number, text: string): void {
    this.editingStepIndex = index
    this.editingStepText = text
    this.editingStepOriginalText = text
    // 不在此处置 hasUnsavedChanges：仅进入编辑不算修改，实际改动在 onChange 中判定
    Logger.info('TaskDetailPage', 'startEditStep, index=' + index.toString())
  }

  /**
   * 步骤编辑：完成编辑（持久化版）
   * - 优先使用 routeVM.updateStepText() 回写 L2 任务
   * - 失败时回滚 + Toast 提示
   * @param index - 步骤下标
   */
  private finishEditStep(index: number): void {
    const newText: string = this.editingStepText.trim()
    if (newText.length === 0) {
      promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_step_empty').id) })
      return
    }

    // 优先路径：4 级架构编辑流
    if (this.l2Task && this.goalId && this.relatedTaskId) {
      try {
        const success: boolean = routeVM.updateStepText(this.goalId, this.relatedTaskId, index, newText)
        if (success) {
          this.editingStepIndex = -1
          this.editingStepText = ''
          this.hasUnsavedChanges = false
          this.loadL2Task()
          Logger.info('TaskDetailPage', 'finishEditStep success via routeVM, index=' + index.toString())
          promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_step_updated').id) })
          return
        } else {
          Logger.warn('TaskDetailPage', 'finishEditStep: routeVM.updateStepText returned false')
        }
      } catch (e) {
        const err: Error = e as Error
        Logger.error('TaskDetailPage', 'finishEditStep: routeVM.updateStepText threw, msg=' + err.message)
      }
      promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_update_failed_retry').id), duration: 1500 })
      return
    }

    // 降级路径：孤立任务
    this.editingStepIndex = -1
    this.editingStepText = ''
    promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.task_detail_toast_step_updated').id), duration: 1500 })
  }

  /**
   * 步骤编辑：取消编辑
   */
  private cancelEditStep(): void {
    this.editingStepIndex = -1
    this.editingStepText = ''
    this.hasUnsavedChanges = false
  }

  /**
   * 添加 L3 步骤（持久化版）
   * - 优先使用 routeVM.addStep() 回写 L2 任务
   * - 失败时回滚 + Toast 提示
   * - 若 l2Task 为 null（孤立任务），降级使用本地 task.steps（仅 UI 展示）
   */
  private addStep(): void {
    const text: string = this.newStepText.trim()
    if (text.length === 0) {
      promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_step_empty').id) })
      return
    }

    // 优先路径：4 级架构编辑流
    if (this.l2Task && this.goalId && this.relatedTaskId) {
      try {
        const success: boolean = routeVM.addStep(this.goalId, this.relatedTaskId, text)
        if (success) {
          // 刷新 L2 任务引用
          this.loadL2Task()
          this.newStepText = ''
          Logger.info('TaskDetailPage', 'addStep success via routeVM, text=' + text)
          promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_step_added').id) })
          return
        } else {
          Logger.warn('TaskDetailPage', 'addStep: routeVM.addStep returned false')
        }
      } catch (e) {
        const err: Error = e as Error
        Logger.error('TaskDetailPage', 'addStep: routeVM.addStep threw, msg=' + err.message)
      }
      promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.task_detail_add_failed_retry').id), duration: 1500 })
      return
    }

    // 降级路径：孤立任务（旧版本无关联字段）
    const newStep: TaskStep = new TaskStep('step_' + Date.now().toString(), text, false)
    const currentSteps: TaskStep[] = Array.isArray(this.task.steps) ? this.task.steps : []
    currentSteps.push(newStep)
    this.task.steps = currentSteps
    this.newStepText = ''
    Logger.info('TaskDetailPage', 'addStep, text=' + text + ' (UI only, not persisted)')
    promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.task_detail_toast_step_added').id), duration: 1500 })
  }

  /**
   * 切换 L3 步骤完成状态（回写流）
   * - 优先使用 routeVM.updateStep() 回写 L2 任务
   * - 失败时回滚 + Toast 提示
   * - 若 l2Task 为 null（孤立任务），降级使用本地 task.steps
   *
   * @param index - 步骤下标
   */
  private toggleStep(index: number): void {
    // 优先路径：4 级架构回写流
    if (this.l2Task && this.goalId && this.relatedTaskId) {
      const currentStatus: boolean = isStepCompleted(this.l2Task, index)
      const newStatus: boolean = !currentStatus
      try {
        const success: boolean = routeVM.updateStep(
          this.goalId, this.relatedTaskId, index, newStatus
        )
        if (success) {
          // 重新加载 l2Task 引用（routeVM 内部已整体替换）
          // - l2Task 是 @Local，重新赋值即刷新本页所有派生状态
          //   （isTaskCompleted / stepCompletedCount / stepProgressPercent 均为 @Computed）
          // - ForEach key 用稳定 step.id，步骤圆圈则由 StepItemBuilder 直读 @Trace 刷新
          this.loadL2Task()
          Logger.info('TaskDetailPage', 'toggleStep success via routeVM, index=' +
            index.toString() + ', newStatus=' + newStatus.toString())
          return
        } else {
          Logger.warn('TaskDetailPage', 'toggleStep: updateStep returned false, index=' + index.toString())
          promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.task_detail_step_update_failed_retry').id), duration: 1500 })
        }
      } catch (e) {
        const err: Error = e as Error
        Logger.error('TaskDetailPage', 'toggleStep: updateStep threw, msg=' + err.message)
        promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.task_detail_update_failed_prefix').id) + err.message, duration: 1500 })
      }
      return
    }

    // 降级路径：孤立任务（旧版本无关联字段）
    const currentSteps: TaskStep[] = Array.isArray(this.task.steps) ? this.task.steps : []
    if (index < 0 || index >= currentSteps.length) return

    const newSteps: TaskStep[] = []
    for (let i: number = 0; i < currentSteps.length; i++) {
      const old: TaskStep = currentSteps[i]
      if (i === index) {
        newSteps.push(new TaskStep(old.id, old.text, !old.isCompleted))
      } else {
        newSteps.push(old)
      }
    }
    this.task.steps = newSteps
  }

  /**
   * 删除 L3 步骤（持久化版 + 二次确认）
   * - 优先使用 routeVM.removeStep() 回写 L2 任务
   * - 至少保留 1 个步骤（由 routeVM 保护）
   * - 失败时回滚 + Toast 提示
   * - 若 l2Task 为 null（孤立任务），降级使用本地 task.steps（仅 UI 展示）
   * - 删除步骤前二次确认
   *
   * @param index - 要删除的步骤下标
   */
  private removeStep(index: number): void {
    // Opt: F3-4+删除提示文案标准化
    promptAction.showDialog({
      title: $r('app.string.dialog_delete_title'),
      message: getContext(this).resourceManager.getStringSync($r('app.string.dialog_delete_message').id),
      buttons: [
        { text: $r('app.string.common_cancel'), color: $r('app.color.text_secondary') },
        { text: $r('app.string.btn_delete'), color: $r('app.color.error_color') }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse): void => {
      if (!this.isAttached) return
      if (result.index !== 1) return // 用户取消
      this.doRemoveStep(index)
    }).catch((e: Error): void => {
      Logger.error('TaskDetailPage', 'removeStep dialog failed: ' + e.message)
    })
  }

  /**
   * 实际执行步骤删除（由 removeStep 确认后调用）
   * @param index - 要删除的步骤下标
   */
  private doRemoveStep(index: number): void {
    // 优先路径：4 级架构编辑流
    if (this.l2Task && this.goalId && this.relatedTaskId) {
      try {
        const success: boolean = routeVM.removeStep(this.goalId, this.relatedTaskId, index)
        if (success) {
          // 刷新 L2 任务引用
          this.loadL2Task()
          Logger.info('TaskDetailPage', 'removeStep success via routeVM, index=' + index.toString())
          promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_step_deleted').id) })
          return
        } else {
          Logger.warn('TaskDetailPage', 'removeStep: routeVM.removeStep returned false')
          promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.task_detail_min_step_warning').id), duration: 1500 })
        }
      } catch (e) {
        const err: Error = e as Error
        Logger.error('TaskDetailPage', 'removeStep: routeVM.removeStep threw, msg=' + err.message)
        promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.task_detail_delete_failed_prefix').id) + err.message, duration: 1500 })
      }
      return
    }

    // 降级路径：孤立任务（旧版本无关联字段）
    const currentSteps: TaskStep[] = Array.isArray(this.task.steps) ? this.task.steps : []
    if (index < 0 || index >= currentSteps.length) return

    // 至少保留1个步骤
    if (currentSteps.length <= 1) {
      promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.task_detail_min_step_warning').id) })
      return
    }

    const newSteps: TaskStep[] = []
    for (let i: number = 0; i < currentSteps.length; i++) {
      if (i !== index) newSteps.push(currentSteps[i])
    }
    this.task.steps = newSteps
    Logger.info('TaskDetailPage', 'removeStep, index=' + index.toString() + ' (UI only)')
    promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.task_detail_toast_step_deleted').id), duration: 1500 })
  }

  /**
   * 底部主按钮：切换任务完成态（**统一完成链路**，2026-09-17）
   *
   * 语义（用户确认）：点"完成全部步骤" = 把上面所有 L3 步骤一并置完成；
   *                 点"已完成 · 取消" = 把全部 L3 步骤一并置未完成。
   * 因此本按钮与"逐个勾步骤"落到**同一处真相源**（L2.status + 各 step.isCompleted），
   * 区别只是"批量设定"还是"逐个设定"——两个入口不再各走一条链路。
   *
   * 为什么改走 routeVM.setTaskCompletion（而非原来的
   * "写 this.task.isCompleted + 直改 L2.status + homeVM.toggleTask 翻转 L4"）：
   *   1. 原链路**完全不碰 L3 步骤** ⇒ 点完成时上面步骤圆圈纹丝不动（用户报的问题①）；
   *   2. 原链路绕过 actualCompletionTime 不变式，且 L4 走"翻转"语义——L4 与本地展示
   *      一旦不同步就会反向错；孤立任务（无对应 L4）时 toggleTask 直接 return，链路静默失效；
   *   3. setTaskCompletion 是**设定**语义且幂等，L4 侧由 TASK_COMPLETION_SYNCED 事件按值同步。
   *
   * 目标值取自 isTaskCompleted（L2 派生）：逐个勾完最后一个步骤后，按钮已自动显示为
   * "已完成 · 取消"，此时点击即整任务回退（含全部步骤）。
   */
  private toggleTaskComplete(): void {
    const newCompleted: boolean = !this.isTaskCompleted
    Logger.info('TaskDetailPage', 'toggleTaskComplete, new=' + newCompleted.toString())

    const toastMsg: Resource = newCompleted
      ? $r('app.string.toast_task_completed')
      : $r('app.string.toast_task_uncompleted')

    // 优先路径：4 级架构（L1/L2/L3 一次设定，L4 由事件按值同步）
    if (this.l2Task !== null && this.goalId.length > 0 && this.relatedTaskId.length > 0) {
      try {
        const success: boolean = routeVM.setTaskCompletion(this.goalId, this.relatedTaskId, newCompleted)
        if (success) {
          // 刷新 L2 引用（routeVM 内部可能整体替换代理）+ 同步本地快照完成态
          this.loadL2Task()
          this.task.isCompleted = newCompleted
          Logger.info('TaskDetailPage', 'toggleTaskComplete: success via routeVM.setTaskCompletion')
          promptAction.showToast({ message: toastMsg })
          return
        }
        Logger.warn('TaskDetailPage', 'toggleTaskComplete: setTaskCompletion returned false')
      } catch (e) {
        const err: Error = e as Error
        Logger.error('TaskDetailPage', 'toggleTaskComplete: setTaskCompletion threw, msg=' + err.message)
      }
    }

    // 降级路径：孤立 L4 待办（本页展示的任务无 L2 关联，没有步骤可言）
    // ⚠️ homeVM.toggleTask 是**翻转**语义，必须先比对当前值再调用，否则会反向错
    this.task.isCompleted = newCompleted
    const todo: HomeTodoItem | undefined =
      homeVM.liveTasks.find((t: HomeTodoItem): boolean => t.id === this.task.id)
    if (todo !== undefined && todo.isCompleted !== newCompleted) {
      homeVM.toggleTask(this.task.id)
    }
    Logger.info('TaskDetailPage', 'toggleTaskComplete: degraded path, hasTodo=' +
      (todo !== undefined).toString())

    promptAction.showToast({ message: toastMsg })
  }

  private onDestinationReady(context: NavDestinationContext): void {
    // 合规改造：游客可查看任务详情（本地数据），不再强制跳登录
    Logger.info('TaskDetailPage', 'onDestinationReady: isLoggedIn=' + settingsVM.userProfile.isLoggedIn.toString())

    const rawParam: Object = context.pathInfo.param as Object
    if (rawParam === null || rawParam === undefined) {
      Logger.error('TaskDetailPage', 'navParam is null')
      this.loadError = true
      this.isLoading = false
      return
    }
    const paramObj: Record<string, Object> = rawParam as Record<string, Object>
    const taskRaw: Object | undefined = paramObj['task']
    let parsedTask: TaskDetailItem
    if (taskRaw !== undefined) {
      // 常规路径：完整路由参数（含 task 快照 + goalId/relatedTaskId）
      const taskObj: Record<string, Object> = taskRaw as Record<string, Object>
      parsedTask = new TaskDetailItem(
        String(taskObj['id'] ?? ''),
        String(taskObj['title'] ?? ''),
        String(taskObj['description'] ?? ''),
        String(taskObj['duration'] ?? ''),
        this.parsePriority(String(taskObj['priority'] ?? 'medium')),
        Boolean(taskObj['isCompleted'] ?? false),
        Number(taskObj['createTime'] ?? 0)
      )
      this.goalId = String(paramObj['goalId'] ?? '')
      this.relatedTaskId = String(paramObj['relatedTaskId'] ?? '')
    } else {
      // 兼容路径：系统通知直达/热启动恢复只携带 id（WantAgent 参数限制），
      // 从首页待办列表反查构造，避免直接落错误态
      const fallbackId: string = String(paramObj['id'] ?? '')
      Logger.info('TaskDetailPage', 'onDestinationReady: task param missing, resolve by id=' + fallbackId)
      const resolved: HomeTodoItem | null = this.resolveTaskFromHomeById(fallbackId)
      if (resolved === null) {
        Logger.error('TaskDetailPage', 'onDestinationReady: cannot resolve task by id=' + fallbackId)
        this.loadError = true
        this.isLoading = false
        return
      }
      parsedTask = new TaskDetailItem(
        resolved.id,
        resolved.title,
        '',
        resolved.duration,
        resolved.priority,
        resolved.isCompleted,
        resolved.createTime
      )
      this.goalId = resolved.relatedGoalId
      this.relatedTaskId = resolved.relatedTaskId
    }

    // 修复：确保 steps 一定是数组，防止 UI 层 ForEach 报错
    if (!Array.isArray(parsedTask.steps)) {
      parsedTask.steps = []
    }
    this.task = parsedTask

    // 恢复沉浸屏可见性：仅当 Service 中进行中的会话属于本任务时才恢复显示
    const activeSession = pomodoroService.getCurrentSession()
    this.isPomodoroImmersiveVisible = pomodoroService.isImmersiveVisible() &&
      activeSession !== null && activeSession.taskId === this.task.id

    Logger.info('TaskDetailPage', 'onDestinationReady, id=' + this.task.id +
      ', goalId=' + this.goalId + ', relatedTaskId=' + this.relatedTaskId)

    // 4 级架构：加载 L2 任务（用于反查步骤）
    this.loadL2Task()

    // 聚焦统计摘要（relatedTaskId 就绪后计算）
    this.refreshFocusSummary()
    this.refreshGoalName()

    this.isLoading = false
  }

  /**
   * 通知直达/热启动恢复场景：仅有任务 id（L4 待办 id），从首页待办列表反查
   * @returns 找不到返回 null（数据未加载或任务已删除）
   */
  private resolveTaskFromHomeById(taskId: string): HomeTodoItem | null {
    if (taskId.length === 0) {
      return null
    }
    const found = homeVM.liveTasks.find((t: HomeTodoItem): boolean => t.id === taskId)
    return found !== undefined ? found : null
  }

  private parsePriority(raw: string): TaskPriority {
    if (raw === 'high' || raw === '高') return TaskPriority.HIGH
    if (raw === 'low' || raw === '低') return TaskPriority.LOW
    return TaskPriority.MEDIUM
  }

  private formatCreateTime(ts: number): string {
    if (ts === 0) return getContext(this).resourceManager.getStringSync($r('app.string.default_unknown').id)
    const date: Date = new Date(ts)
    return (date.getMonth() + 1).toString() +
      getContext(this).resourceManager.getStringSync($r('app.string.task_detail_date_month_suffix').id) +
      date.getDate().toString() +
      getContext(this).resourceManager.getStringSync($r('app.string.task_detail_date_day_suffix').id)
  }

  /**
   * 任务编辑面板（Stack 层叠，替换原 toast_edit_task 占位）
   * 支持编辑任务名称和预估时长
   */
  @Builder
  EditPanelBuilder() {
    Column() {
      // 透明遮罩，点击关闭
      Column() {}
        .width('100%')
        .layoutWeight(1)
        .onClick((): void => { this.cancelEditTask() })

      // 编辑面板
      Column({ space: 14 }) {
        Text($r('app.string.edit_task_panel_title'))
          .fontSize(CommonConstants.FONT_SIZE_TITLE)
          .fontWeight(FontWeight.Bold)
          
          .fontColor($r('app.color.text_primary'))

        // 任务名称输入
        TextInput({ text: this.editTaskName, placeholder: $r('app.string.edit_task_name_hint') })
          .type(InputType.Normal)
          .width('100%')
          .height(44)
          .fontSize(CommonConstants.FONT_SIZE_SUBTITLE)
          .backgroundColor($r('app.color.bg_page'))
          .borderRadius(DimensConstants.RADIUS_M)
          .padding({ left: 12, right: 12 })
          .onChange((value: string): void => { this.editTaskName = value })

        // 预估时长输入（数值 + 分钟/小时/天单位）
        Row({ space: 8 }) {
          TextInput({ text: this.editTaskDuration, placeholder: $r('app.string.edit_task_duration_hint') })
            .type(InputType.Number)
            .layoutWeight(1)
            .height(44)
            .fontSize(CommonConstants.FONT_SIZE_SUBTITLE)
            .backgroundColor($r('app.color.bg_page'))
            .borderRadius(DimensConstants.RADIUS_M)
            .padding({ left: 12, right: 12 })
            .onChange((value: string): void => { this.editTaskDuration = value })
          ForEach(this.durationUnitOptions, (unit: number) => {
            Text(this.durationUnitLabel(unit))
              .fontSize(CommonConstants.FONT_SIZE_XS)
              .fontColor(this.editTaskDurationUnit === unit ?
                $r('app.color.text_inverse') : $r('app.color.text_secondary'))
              .backgroundColor(this.editTaskDurationUnit === unit ?
                $r('app.color.primary_color') : $r('app.color.bg_tag'))
              .borderRadius(DimensConstants.RADIUS_M)
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .onClick((): void => { this.editTaskDurationUnit = unit })
          }, (unit: number): string => 'edit_unit_' + unit.toString())
        }
        .width('100%')

        // 快捷档位
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.durationPresets, (minutes: number) => {
            Text(this.presetLabel(minutes))
              .fontSize(CommonConstants.FONT_SIZE_XS)
              .fontColor($r('app.color.text_secondary'))
              .backgroundColor($r('app.color.bg_tag'))
              .borderRadius(DimensConstants.RADIUS_M)
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .margin({ right: 6, bottom: 6 })
              .onClick((): void => { this.applyPreset(minutes) })
          }, (minutes: number): string => 'edit_preset_' + minutes.toString())
        }
        .width('100%')

        // 优先级选择（高/中/低）
        Row({ space: 8 }) {
          Text($r('app.string.goal_detail_priority_label'))
            .fontSize(CommonConstants.FONT_SIZE_XS)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)
          ForEach([TaskPriority.HIGH, TaskPriority.MEDIUM, TaskPriority.LOW], (p: TaskPriority) => {
            Text(this.editPriorityLabel(p))
              .fontSize(CommonConstants.FONT_SIZE_XS)
              .fontColor(this.editTaskPriority === p ?
                $r('app.color.text_inverse') : $r('app.color.text_secondary'))
              .backgroundColor(this.editTaskPriority === p ?
                $r('app.color.primary_color') : $r('app.color.bg_tag'))
              .borderRadius(DimensConstants.RADIUS_M)
              .padding({ left: 12, right: 12, top: 5, bottom: 5 })
              .onClick((): void => { this.editTaskPriority = p })
          }, (p: TaskPriority): string => 'edit_prio_' + p.toString())
        }
        .width('100%')

        // 截止时间（可选，点击弹日期选择器，可清除）
        Row({ space: 8 }) {
          Text($r('app.string.route_create_goal_deadline_label'))
            .fontSize(CommonConstants.FONT_SIZE_XS)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)
          if (this.editTaskDeadline > 0) {
            Text(formatDeadlineUtil(this.editTaskDeadline))
              .fontSize(CommonConstants.FONT_SIZE_XS)
              .fontColor($r('app.color.text_primary'))
            Text($r('app.string.goal_detail_deadline_clear'))
              .fontSize(CommonConstants.FONT_SIZE_XS)
              .fontColor($r('app.color.error_color'))
              .onClick((): void => { this.editTaskDeadline = 0 })
          } else {
            Text($r('app.string.goal_detail_no_deadline'))
              .fontSize(CommonConstants.FONT_SIZE_XS)
              .fontColor($r('app.color.text_tertiary'))
          }
        }
        .width('100%')
        .height(44)
        .padding({ left: 12, right: 12 })
        .backgroundColor($r('app.color.bg_page'))
        .borderRadius(DimensConstants.RADIUS_M)
        .onClick((): void => { this.showEditDeadlinePicker() })

        // 象限实时预览：把"优先级 × 截止时间 → 四象限"的换算关系显性化
        Row({ space: 8 }) {
          Text($r('app.string.task_edit_quadrant_preview'))
            .fontSize(CommonConstants.FONT_SIZE_XS)
            .fontColor($r('app.color.text_secondary'))
          Text(quadrantLabelUtil(classifyEisenhowerQuadrant(this.editTaskPriority, this.editTaskDeadline)))
            .fontSize(CommonConstants.FONT_SIZE_XS)
            .fontWeight(FontWeight.Medium)
            .fontColor(quadrantTextColorUtil(classifyEisenhowerQuadrant(this.editTaskPriority, this.editTaskDeadline)))
            .backgroundColor(quadrantBgColorUtil(classifyEisenhowerQuadrant(this.editTaskPriority, this.editTaskDeadline)))
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .borderRadius(6)
        }
        .width('100%')

        // 按钮行
        Row({ space: 12 }) {
          Button($r('app.string.edit_task_cancel'))
            .type(ButtonType.Capsule)
            .height(44)
            .layoutWeight(1)
            .backgroundColor($r('app.color.bg_tag'))
            .fontColor($r('app.color.text_secondary'))
            .fontSize(CommonConstants.FONT_SIZE_MID)
            .onClick((): void => { this.cancelEditTask() })

          Button($r('app.string.edit_task_save'))
            .type(ButtonType.Capsule)
            .height(44)
            .layoutWeight(1)
            .backgroundColor($r('app.color.primary_color'))
            .fontColor($r('app.color.text_inverse'))
            .fontSize(CommonConstants.FONT_SIZE_MID)
            .enabled(this.editTaskName.trim().length > 0)
            .onClick((): void => { this.saveEditTask() })
        }
        .width('100%')
      }
      .width('100%')
      .padding(20)
      .backgroundColor($r('app.color.bg_card'))
      .borderRadius({ topLeft: 20, topRight: 20 })
      .shadow({ radius: 16, color: $r('app.color.shadow_dialog_overlay'), offsetX: 0, offsetY: -4 })
      // 面板由父级 if 插入/删除：属性动画对"插入那一刻"无效（无属性变化可补间），
      // 必须用 transition 才会真的滑上来
      .transition(MotionHelper.bottomPanel())
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.overlay_mask'))
    .transition(MotionHelper.overlayFade())
  }

  private handleBackPress(): void {
    if (this.hasUnsavedChanges) {
    promptAction.showDialog({
      title: $r('app.string.dialog_unsaved_title'),
      message: getContext(this).resourceManager.getStringSync($r('app.string.dialog_unsaved_message').id),
        buttons: [
        { text: $r('app.string.dialog_leave_edit'), color: $r('app.color.primary_color') },
        { text: $r('app.string.dialog_leave_page'), color: $r('app.color.error_color') }
        ]
      }).then((result: promptAction.ShowDialogSuccessResponse): void => {
        if (!this.isAttached) return
        if (result.index === 1) {
          this.hasUnsavedChanges = false
          globalNavStack.pop()
        }
      }).catch((e: Error): void => {
        Logger.error('TaskDetailPage', 'handleBackPress dialog failed: ' + e.message)
      })
    } else {
      globalNavStack.pop()
    }
  }

  private showTaskActionMenu(): void {
    // 统一 ActionSheet：替代系统 showActionMenu 兜底样式
    this.actionSheetTitle = getContext(this).resourceManager.getStringSync($r('app.string.dialog_task_action_title').id)
    this.actionSheetItems = [
      {
        label: getContext(this).resourceManager.getStringSync($r('app.string.dialog_edit_task').id),
        action: (): void => { this.handleEditTask() }
      },
      {
        label: getContext(this).resourceManager.getStringSync($r('app.string.dialog_delete_task').id),
        danger: true,
        action: (): void => { this.handleDeleteTask() }
      }
    ]
    this.showActionSheet = true
  }

  private handleEditTask(): void {
    // 预填当前任务名称和时长
    this.editTaskName = this.task.title
    // 从 L2 任务或当前任务中读取时长（分钟），自动选择能整除的最大单位
    let minutes: number = 30
    if (this.l2Task && this.l2Task.estimatedTime > 0) {
      minutes = this.l2Task.estimatedTime
    } else {
      const match = this.task.duration.match(/\d+/)
      minutes = match ? parseInt(match[0], 10) : 30
    }
    if (minutes > 0 && minutes % 1440 === 0) {
      this.editTaskDurationUnit = 1440
      this.editTaskDuration = (minutes / 1440).toString()
    } else if (minutes > 0 && minutes % 60 === 0) {
      this.editTaskDurationUnit = 60
      this.editTaskDuration = (minutes / 60).toString()
    } else {
      this.editTaskDurationUnit = 1
      this.editTaskDuration = minutes.toString()
    }
    // 预填优先级与截止时间（L2 缺失时回退当前展示值/未设置）
    this.editTaskPriority = this.l2Task ? this.l2Task.priority : this.task.priority
    this.editTaskDeadline = this.l2Task && this.l2Task.deadline > 0 ? this.l2Task.deadline : 0
    this.showEditPanel = true
  }

  private saveEditTask(): void {
    const newName: string = this.editTaskName.trim()
    if (newName.length === 0) {
      promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_step_empty').id) })
      return
    }
    const parsedValue: number = parseInt(this.editTaskDuration, 10)
    // 输入值 × 单位倍率 → 分钟；未填时回退 30 分钟（保持历史默认）
    const safeDuration: number = (isNaN(parsedValue) || parsedValue <= 0)
      ? 30 : Math.max(1, Math.floor(parsedValue * this.editTaskDurationUnit))

    // 持久化到 routeVM + 同步 L4 待办（含优先级/截止时间联动与截止提醒重排）
    if (this.goalId && this.relatedTaskId) {
      const success: boolean = routeVM.updateTask(this.goalId, this.relatedTaskId, newName, safeDuration,
        this.editTaskPriority, this.editTaskDeadline)
      if (success) {
        Logger.info('TaskDetailPage', 'saveEditTask: routeVM.updateTask success')
      } else {
        Logger.warn('TaskDetailPage', 'saveEditTask: routeVM.updateTask returned false')
      }
    }

    // 本地 UI 立即刷新
    this.task.title = newName
    this.task.duration = formatEstimatedDuration(safeDuration, getContext(this).resourceManager)
    if (this.l2Task) {
      this.l2Task.taskName = newName
      this.l2Task.estimatedTime = safeDuration
      this.l2Task.priority = this.editTaskPriority
      this.l2Task.deadline = this.editTaskDeadline
    }

    this.showEditPanel = false
    promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_task_updated').id) })
  }

  private cancelEditTask(): void {
    this.showEditPanel = false
    this.editTaskName = ''
    this.editTaskDuration = ''
  }

  private handleDeleteTask(): void {
    promptAction.showDialog({
      title: $r('app.string.dialog_delete_task_title'),
      message: getContext(this).resourceManager.getStringSync($r('app.string.dialog_delete_task_message').id),
      buttons: [
        { text: $r('app.string.dialog_cancel'), color: $r('app.color.text_secondary') },
        { text: $r('app.string.dialog_confirm'), color: $r('app.color.error_color') }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse): void => {
      if (!this.isAttached) return
      if (result.index === 1) {
        // 番茄钟正在为本任务计时时，先停止会话并关闭沉浸屏，
        // 避免已删除的任务继续倒计时/发完成通知
        const activeSession = pomodoroService.getCurrentSession()
        if (activeSession !== null && activeSession.taskId === this.task.id) {
          pomodoroService.stop()
          pomodoroService.hideImmersive()
        }
        if (this.goalId && this.relatedTaskId) {
          const success: boolean = routeVM.deleteTask(this.goalId, this.relatedTaskId)
          if (success) {
            promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_task_deleted').id), duration: 1500 })
            globalNavStack.pop()
          } else {
            promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_delete_failed').id), duration: 1500 })
          }
        } else {
          const success: boolean = homeVM.deleteTask(this.task.id)
          if (success) {
            promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_task_deleted').id), duration: 1500 })
            globalNavStack.pop()
          } else {
            promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_delete_failed').id), duration: 1500 })
          }
        }
      }
    }).catch((e: Error): void => {
      Logger.error('TaskDetailPage', 'handleDeleteTask dialog failed: ' + e.message)
    })
  }

  /** 内容列限宽：平板（lg）双栏上限 DUAL_MAX_WIDTH，手机/折叠屏保持 640 居中 */
  private getContentConstraint(): ConstraintSizeOptions {
    if (breakpointState.isTablet) {
      const dual: ConstraintSizeOptions = { maxWidth: DimensConstants.DUAL_MAX_WIDTH }
      return dual
    }
    const capped: ConstraintSizeOptions = { maxWidth: DimensConstants.CONTENT_MAX_WIDTH }
    return capped
  }

  /** 任务信息区：概览卡（菜单已收进标题栏右侧） */
  @Builder
  TaskInfoBuilder() {
    // 顶部：任务信息卡
    Column({ space: 10 }) {
      // 优先级徽标（小标签，置于标题上方建立层级）
      Row({ space: 6 }) {
        Text(priorityLabelUtil(this.task.priority))
          .fontSize(CommonConstants.FONT_SIZE_XS)
          .fontColor(priorityTextColorUtil(this.task.priority))
          .fontWeight(FontWeight.Medium)
          .backgroundColor(priorityBgColorUtil(this.task.priority))
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .borderRadius(6)
        if (this.isTaskCompleted) {
          Text($r('app.string.btn_completed'))
            .fontSize(CommonConstants.FONT_SIZE_XS)
            .fontColor($r('app.color.success_color'))
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .backgroundColor($r('app.color.status_completed_bg'))
            .borderRadius(6)
        }
      }
      .width('100%')
      .justifyContent(FlexAlign.Start)

      Text(safeStringUtil(this.task.title, getContext(this).resourceManager.getStringSync($r('app.string.default_unnamed_task').id)))
        .fontSize(CommonConstants.FONT_SIZE_TITLE)
        .fontWeight(FontWeight.Bold)
        
        .fontColor(this.isTaskCompleted ? $r('app.color.text_tertiary') : $r('app.color.text_primary'))
        .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })

      // 修复：ArkUI 的条件渲染 if 必须直接判断，不能先声明 const 变量
      if (safeStringUtil(this.task.description, '').length > 0) {
        Text(safeStringUtil(this.task.description, ''))
          .fontSize(CommonConstants.FONT_SIZE_SMALL)
          .fontColor($r('app.color.text_secondary'))
          
          .width('100%').maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      // 元信息行 1：预计耗时 + 截止时间（有截止显示截止并标逾期，否则显示创建日期）
      Row({ space: 16 }) {
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.timer'))
            .fontSize(CommonConstants.FONT_SIZE_SMALL)
            .fontColor([$r('app.color.text_tertiary')])
          Text(formatEstimatedDuration(this.l2Task ? this.l2Task.estimatedTime : 0, getContext(this).resourceManager))
            .fontSize(CommonConstants.FONT_SIZE_SMALL)
            .fontColor($r('app.color.text_primary'))
            
        }
        if (this.l2Task !== null && this.l2Task.deadline > 0) {
          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.calendar'))
              .fontSize(CommonConstants.FONT_SIZE_SMALL)
              .fontColor([this.l2Task.deadline <= Date.now()
                ? $r('app.color.error_color') : $r('app.color.text_tertiary')])
            Text(formatDeadlineUtil(this.l2Task.deadline) +
              (this.l2Task.deadline <= Date.now()
                ? getContext(this).resourceManager.getStringSync($r('app.string.home_deadline_overdue').id)
                : ''))
              .fontSize(CommonConstants.FONT_SIZE_SMALL)
              .fontColor(this.l2Task.deadline <= Date.now()
                ? $r('app.color.error_color') : $r('app.color.text_primary'))
              
          }
        } else {
          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.calendar'))
              .fontSize(CommonConstants.FONT_SIZE_SMALL)
              .fontColor([$r('app.color.text_tertiary')])
            Text(this.formatCreateTime(this.task.createTime)).fontSize(CommonConstants.FONT_SIZE_SMALL)
            .fontColor($r('app.color.text_primary'))
          }
        }
      }
      .width('100%')

      // 元信息行 2：所属目标（存在关联目标时展示）
      if (this.goalNameText.length > 0) {
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.flag'))
            .fontSize(CommonConstants.FONT_SIZE_SMALL)
            .fontColor([$r('app.color.text_tertiary')])
          Text(this.goalNameText)
            .fontSize(CommonConstants.FONT_SIZE_SMALL)
            .fontColor($r('app.color.text_secondary'))
            
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
      }
    }
    .width('100%').padding(16).backgroundColor($r('app.color.bg_card')).borderRadius(DimensConstants.RADIUS_L)
    .margin({ bottom: 12 })
  }

  /** 标题栏右侧任务菜单按钮（原"..."悬浮按钮收编，建立归属关系） */
  @Builder
  TitleMenuButtonBuilder() {
    Row() {
      SymbolGlyph($r('sys.symbol.ellipsis_circle'))
        .fontSize(CommonConstants.FONT_SIZE_LARGE)
        .fontColor([$r('app.color.text_secondary')])
    }
    .width(DimensConstants.TOUCH_COMFORT)
    .height(DimensConstants.TOUCH_COMFORT)
    .borderRadius(DimensConstants.RADIUS_XL)
    .backgroundColor(Color.Transparent)
    .alignItems(VerticalAlign.Center)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.showTaskActionMenu()
    })
  }

  /** 番茄钟专注计时卡片（平板双栏时为左栏下部）+ 聚焦统计摘要 */
  @Builder
  PomodoroBuilder() {
    PomodoroTimerCard({ taskId: this.task.id, taskTitle: this.task.title })
      .margin({ bottom: 12 })

    // 聚焦统计：该任务累计专注 N 轮 · X 分钟（专注完成时实时刷新）
    if (this.focusSummary.length > 0) {
      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.timer'))
          .fontSize(14)
          .fontColor([$r('app.color.primary_color')])
        Text(this.focusSummary)
          .fontSize(CommonConstants.FONT_SIZE_SMALL)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .padding({ left: 4, right: 4, bottom: 12 })
    }
  }

  /** 执行步骤区（平板双栏时为右栏上部） */
  @Builder
  StepsBuilder() {
    // 中部：执行步骤
    // 4 级架构：步骤数据从 l2Task.steps 读取（不是 this.task.steps）
    Column({ space: 8 }) {
      Row() {
        Text($r('app.string.task_detail_execution_steps')).fontSize(CommonConstants.FONT_SIZE_BODY)
          .fontWeight(FontWeight.Medium)
          
          .fontColor($r('app.color.text_secondary')).layoutWeight(1)
        // 修复：直接调用防空逻辑，不声明 const safeSteps
        Text(getContext(this).resourceManager.getStringSync($r('app.string.task_detail_steps_count_prefix').id) + (this.l2Task && Array.isArray(this.l2Task.steps) ?
          this.l2Task.steps.length : 0).toString() + getContext(this).resourceManager.getStringSync($r('app.string.task_detail_steps_count_suffix').id))
.fontSize(CommonConstants.FONT_SIZE_XS)
          .fontColor($r('app.color.text_tertiary'))
      }
      .width('100%').padding({ left: 4 })

      if (!this.l2Task || !Array.isArray(this.l2Task.steps) || this.l2Task.steps.length === 0) {
        Column({ space: 6 }) {
          // 4 级架构空态：孤立 L4 任务（无关联 L2）
          if (this.l2Task === null && (this.goalId.length === 0 || this.relatedTaskId.length === 0)) {
            Text($r('app.string.task_detail_unlinked_task')).fontSize(CommonConstants.FONT_SIZE_SMALL)
            .fontColor($r('app.color.text_tertiary'))
            Text($r('app.string.task_detail_unlinked_hint')).fontSize(CommonConstants.FONT_SIZE_XS)
            .fontColor($r('app.color.text_tertiary'))
          } else if (this.l2Task === null) {
            Text($r('app.string.task_detail_expired_link')).fontSize(CommonConstants.FONT_SIZE_SMALL)
            .fontColor($r('app.color.text_tertiary'))
            Text($r('app.string.task_detail_expired_hint')).fontSize(CommonConstants.FONT_SIZE_XS)
            .fontColor($r('app.color.text_tertiary'))
          } else {
            Text($r('app.string.empty_steps')).fontSize(CommonConstants.FONT_SIZE_SMALL)
            .fontColor($r('app.color.text_tertiary'))
            Text($r('app.string.empty_no_step_hint')).fontSize(CommonConstants.FONT_SIZE_XS)
            .fontColor($r('app.color.text_tertiary'))
          }
        }
        .width('100%').padding(20).alignItems(HorizontalAlign.Center)
        .backgroundColor($r('app.color.bg_card')).borderRadius(DimensConstants.RADIUS_S)
      } else {
        // 4 级架构：从 l2Task.steps 渲染（TaskStep 对象数组）
        // 单卡分组样式（对齐系统备忘录）：一张卡片承载全部步骤，行间细分隔线，
        // 删除改左滑触发（对齐首页待办交互），点行编辑，去除常驻图标
        Column() {
          List({ space: 0 }) {
            ForEach(this.l2Task.steps, (step: TaskStep, index: number): void => {
              ListItem() {
                Column() {
                  if (index > 0) {
                    Divider()
                      .color($r('app.color.divider'))
                      .strokeWidth(0.5)
                      .margin({ left: 48, right: 12 })
                  }
                  this.StepItemBuilder(step, index)
                }
                .width('100%')
              }
              .swipeAction({ end: this.StepDeleteBuilder(index), edgeEffect: SwipeEdgeEffect.None })
              // L1b：步骤增删过渡。**前提是 key 稳定** —— 见下方 keyGenerator 改动
              .transition(MotionHelper.listItem())
            }, (step: TaskStep, index: number): string =>
              // ⚠️ key 由 `'l3step_' + index + '_v' + stepVersion` 改为 **step.id**
              //   - 含 index ⇒ 删中间项会让后续所有 key 变化 ⇒ 整段重播进场
              //   - 含 stepVersion ⇒ 任何变更都让全部 key 变化 ⇒ 同理
              //   - 改用稳定 id 后，框架能精确识别"哪一项新增/删除"，动效才成立
              step.id.length > 0 ? step.id : ('l3step_' + index.toString()))
          }
          .width('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.None)
          // 嵌套滚动让位外层 Scroll：步骤数少不单独滚动，手势优先滚页面
          .nestedScroll({
            scrollForward: NestedScrollMode.PARENT_FIRST,
            scrollBackward: NestedScrollMode.PARENT_FIRST
          })

          // 添加步骤行：固定在卡片内部底部（修复悬浮遮挡）
          Row({ space: 8 }) {
            TextInput({ placeholder: $r('app.string.task_detail_add_step_hint') })
              .type(InputType.Normal).layoutWeight(1).height(40).fontSize(CommonConstants.FONT_SIZE_BODY)
              .backgroundColor($r('app.color.bg_page')).borderRadius(DimensConstants.RADIUS_M).padding({ left: 12, right: 12 })
              .accessibilityText(getContext(this).resourceManager.getStringSync($r('app.string.task_detail_add_step_input').id))
              .onChange((value: string): void => { this.newStepText = value })
              .onSubmit((keyCode: EnterKeyType): void => {
                Logger.info('TaskDetailPage', 'onSubmit, keyCode=' + keyCode.toString())
                this.addStep()
              })

            Button($r('app.string.btn_add_step'))
              .type(ButtonType.Capsule).height(36).padding({ left: 14, right: 14 })
              .backgroundColor($r('app.color.primary_color')).fontColor($r('app.color.text_inverse')).fontSize(CommonConstants.FONT_SIZE_SMALL)
              .enabled(this.newStepText.trim().length > 0).accessibilityText(getContext(this).resourceManager.getStringSync($r('app.string.task_detail_add_step_button').id))
              .onClick((): void => { this.addStep() })
          }
          .width('100%')
          .padding({ left: 4, right: 4, top: 8 })
        }
        .width('100%')
        .padding({ top: 4, bottom: 10 })
        .backgroundColor($r('app.color.bg_card'))
        .borderRadius(DimensConstants.RADIUS_L)
      }
    }
    // 平板双栏：步骤区自然高度（避免 layoutWeight 把右栏撑满视口、操作按钮被顶到底部）
    .width('100%').layoutWeight(breakpointState.isTablet ? 0 : 1)
  }

  /**
   * 底部操作区：步骤进度 + 完成主按钮（平板双栏时为右栏下部）
   *
   * 改造（2026-09-17，用户反馈"底部标记完成太死板"）：
   *   - 新增步骤进度条 + "已完成 N/M 步"，让"点下去会发生什么"变得可预期；
   *   - 按钮文案**随状态变化**（三态，不再是死板的"标记完成"/"已完成"）：
   *       · 有未完成步骤 → 完成全部步骤（语义即：一键把上面全部勾上）
   *       · 无步骤       → 标记完成    （退化为整任务完成）
   *       · 已完成       → 已完成 · 取消（明确"还能反悔"，避免误以为不可逆）
   *   - 未完成且有步骤时补一行提示"会一并完成上面所有步骤"，
   *     消除"会不会覆盖我手动勾的进度"的疑虑。
   */
  @Builder
  StepActionsBuilder() {
    Column({ space: 10 }) {
      // 步骤进度（仅在有 L3 步骤时展示；孤立 L4 任务不适用）
      if (this.stepTotal > 0) {
        Column({ space: 6 }) {
          Row() {
            Text(getContext(this).resourceManager.getStringSync($r('app.string.task_detail_steps_progress_prefix').id) +
              this.stepCompletedCount.toString() + '/' + this.stepTotal.toString() +
              getContext(this).resourceManager.getStringSync($r('app.string.task_detail_steps_progress_suffix').id))
              .fontSize(CommonConstants.FONT_SIZE_XS)
              .fontColor($r('app.color.text_secondary'))
              .layoutWeight(1)
            Text(this.stepProgressPercent.toString() + '%')
              .fontSize(CommonConstants.FONT_SIZE_XS)
              .fontColor(this.isTaskCompleted ? $r('app.color.success_color') : $r('app.color.text_tertiary'))
          }
          .width('100%')

          Progress({ value: this.stepProgressPercent, total: 100, type: ProgressType.Linear })
            .width('100%')
            .height(6)
            .style({ strokeWidth: 6 })
            .color(this.isTaskCompleted ? $r('app.color.success_color') : $r('app.color.primary_color'))
            .backgroundColor($r('app.color.bg_progress_track'))
        }
        .width('100%')
      }

      // 完成主按钮（三态文案，见方法注释）
      Button(this.isTaskCompleted
        ? $r('app.string.btn_completed_undo')
        : (this.stepTotal > 0 ? $r('app.string.btn_complete_all_steps') : $r('app.string.btn_mark_complete')))
        .type(ButtonType.Capsule).height(44).width('100%')
        .backgroundColor(this.isTaskCompleted ? $r('app.color.status_completed_bg') : $r('app.color.primary_color'))
        .fontColor(this.isTaskCompleted ? $r('app.color.success_color') : $r('app.color.text_inverse'))
        .fontSize(CommonConstants.FONT_SIZE_BODY)
        .fontWeight(FontWeight.Medium)
        .borderRadius(DimensConstants.RADIUS_XL)
        // 完成态弱化视觉（去阴影），未完成保持轻阴影引导主操作
        .shadow(this.isTaskCompleted
          ? { radius: 0, color: Color.Transparent, offsetX: 0, offsetY: 0 }
          : { radius: 4, color: $r('app.color.primary_color_bg'), offsetX: 0, offsetY: 2 })
        .scale({ x: this.pressedCompleteBtn ? 0.97 : 1, y: this.pressedCompleteBtn ? 0.97 : 1 })
        .animation(MotionConstants.pressParam())
        .accessibilityText(getContext(this).resourceManager.getStringSync($r('app.string.task_detail_mark_complete_button').id))
        .onTouch((event: TouchEvent): void => {
          if (event.type === TouchType.Down) {
            this.pressedCompleteBtn = true
          } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
            this.pressedCompleteBtn = false
          }
        })
        .onClick((): void => { this.toggleTaskComplete() })

      // 提示：尚有未完成步骤时说明按钮会连带完成它们
      if (!this.isTaskCompleted && this.stepTotal > 0 && this.stepCompletedCount < this.stepTotal) {
        Text($r('app.string.task_detail_complete_all_hint'))
          .fontSize(CommonConstants.FONT_SIZE_XS)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .textAlign(TextAlign.Center)
      }
    }
    .width('100%').padding({ top: 12 })
  }

  build() {
    NavDestination() {
      Stack() {
        Column() {
          CommonTitleBar({
            title: $r('app.string.page_task_detail'),
            showBack: true,
            onBack: (): void => { this.handleBackPress() },
            rightActions: (): void => {
              // 任务菜单收进标题栏（原"..."悬浮在标题与内容之间无归属）
              this.TitleMenuButtonBuilder()
            }
          })

        if (this.isLoading) {
          StateView({ mode: StateMode.LOADING, loadingText: $r('app.string.state_loading') })
        } else if (this.loadError) {
          StateView({
            mode: StateMode.ERROR,
            errorMessage: $r('app.string.state_error_desc'),
            onRetry: (): void => { this.handleBackPress() }
          })
        } else {
        Scroll() {
        Column() {
          if (breakpointState.isTablet) {
            // 平板（lg）：双栏铺满——左任务信息+番茄钟，右执行步骤+操作
            Row({ space: 16 }) {
              Column() {
                this.TaskInfoBuilder()
                this.PomodoroBuilder()
              }
              .width('38%')

              Column() {
                this.StepsBuilder()
                this.StepActionsBuilder()
              }
              .layoutWeight(1)
            }
            .alignItems(VerticalAlign.Top)
            .constraintSize({ maxWidth: DimensConstants.DUAL_MAX_WIDTH })
            .width('100%')
            .padding({
              left: 16,
              right: 16,
              top: 12,
              bottom: safeAreaHelper.getBottomWith(16)
            })
          } else {
            // 手机/折叠屏单栏：补齐左右内边距 + 底部安全区避让。
            // 此前该分支没有任何 padding —— 平板上看到的"留白"其实是 640 限宽居中
            // 撑出来的假留白，窄屏（手机竖屏）上卡片会直接贴屏幕边；且缺底部安全区，
            // 滚到底"标记完成"会压住手势条。此处与平板分支的 padding 口径对齐。
            Column() {
              this.TaskInfoBuilder()

              this.PomodoroBuilder()

              this.StepsBuilder()

              this.StepActionsBuilder()
            }
            .width('100%')
            .padding({
              left: 16,
              right: 16,
              top: 12,
              bottom: safeAreaHelper.getBottomWith(16)
            })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .backgroundColor($r('app.color.bg_page'))
        // 断点分支容器（平板双栏 / 手机单栏）：旋屏切换不该整块淡入
        .transition(MotionHelper.noTransition())
      }
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
      .width('100%')
      .layoutWeight(1)
      .expandSafeArea([SafeAreaType.KEYBOARD])
      }
      }
      // 宽屏适配：内容列限宽（钳到 640 后由外层 Stack 居中，弹层不限宽）；平板双栏铺满
      .constraintSize(this.getContentConstraint())
      .width('100%')
      .height('100%')

      // 番茄钟沉浸屏（Stack 层叠方案，由 Service 全局状态驱动显示）
      // 点击 PomodoroTimerCard 的"开始"按钮 → Service.showImmersive()
      // → 回调更新 isPomodoroImmersiveVisible = true → 渲染沉浸屏
      if (this.isPomodoroImmersiveVisible) {
        PomodoroImmersiveScreen({
          taskId: this.task.id,
          taskTitle: this.task.title
        })
      }

      // 任务编辑面板（Stack 层叠方案，替换原 toast_edit_task 占位提示）
      if (this.showEditPanel) {
        this.EditPanelBuilder()
      }

      // 统一操作面板（替代系统 showActionMenu）
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
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))
    }
    .hideTitleBar(true)
    .onBackPressed((): boolean => {
      // 全屏番茄钟正在本页显示时：返回键先关闭全屏（与左上角 X 一致），不弹出整个页面。
      // 用页面本地的可见标志判断，而非 Service 标志——会话属于其他任务时本页并无全屏层，
      // 那种情况下吞掉返回键会变成"返回无反应"。
      if (this.isPomodoroImmersiveVisible) {
        pomodoroService.hideImmersive()
        return true
      }
      this.handleBackPress()
      return true
    })
    .onReady((context: NavDestinationContext): void => {
      this.onDestinationReady(context)
    })
    .onShown((): void => {
      Logger.info('TaskDetailPage', 'onShown: refreshing task data')
      this.loadL2Task()
    })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .height('100%')
    // .hideTitleBar()
  }
}
