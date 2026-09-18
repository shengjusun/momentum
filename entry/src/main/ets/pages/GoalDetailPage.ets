// 目标详情页：目标信息卡 + L2 任务卡片列表 + 关联任务 + 编辑面板

import {
  GoalCardItem, TaskPriority, TaskDetailItem, Id,
  GoalDetailRouteNavParam, TaskDetailRouteNavParam, HomeTodoItem,
  AiGeneratedTask, TaskStatus, isStepCompleted, TaskStep
} from '../model/Models'
import { DimensConstants } from '../common/constants/DimensConstants'
import { CommonConstants } from '../common/constants/CommonConstants'
import { globalNavStack, ROUTE_NAME, globalTabsController, TAB_INDEX } from '../common/RouterManager'
import { Logger } from '../common/utils/Logger'
import { safeAreaHelper } from '../common/utils/SafeAreaHelper'
import { safeStringUtil, safeNumberUtil, formatDeadlineUtil, formatEstimatedDuration } from '../common/utils/SafeUtils'
import { classifyEisenhowerQuadrant, quadrantLabelUtil, quadrantTextColorUtil, quadrantBgColorUtil, priorityLabelUtil } from '../common/utils/PriorityUtils'
import { MotionConstants } from '../common/constants/MotionConstants'
import { MotionHelper } from '../common/utils/MotionHelper'
import { routeVM } from '../viewmodel/RoutePageViewModel'
import { homeVM } from '../viewmodel/HomeViewModel'
import { DeepSeekService } from '../common/services/DeepSeekService'
import { ProfileAnalyzerService } from '../common/services/ProfileAnalyzerService'
import { promptAction } from '@kit.ArkUI'
import { AiTaskDataSource } from '../common/datasource/TaskDataSource'
import { CommonTitleBar } from '../common/components/CommonTitleBar'
import { StateView, StateMode } from '../common/components/StateView'
import { AppReportSheet } from '../common/components/AppReportSheet'
import { AppActionSheet, AppActionSheetItem } from '../common/components/AppActionSheet'
import { ConfettiOverlay } from '../common/components/ConfettiOverlay'
import {
  eventBus,
  EventType,
  GoalCompletedPayload,
  GoalProgressChangedPayload
} from '../common/event/AppEventBus'

/* ============================================================
 * 工厂函数（为 @Param 提供类型安全的默认值）
 * ============================================================ */

/**
 * 空 GoalCardItem 工厂（杜绝 {...} as GoalCardItem）
 * 用于 @Local goal 初始值 + onDestinationReady 兜底赋值
 * 4 级架构必填 tasks 字段（允许空数组）
 */
function buildEmptyGoalCard(): GoalCardItem {
  return new GoalCardItem('', '', '', '', 0, '', 0, 0, 0, [], [])
}

/** 空 AiGeneratedTask 工厂（@Param 默认值） */
function buildEmptyAiGeneratedTask(): AiGeneratedTask {
  // L3 步骤已对象化（TaskStep[]），构造参数由 10 个减为 9 个
  return new AiGeneratedTask('', '', 0, TaskPriority.MEDIUM, [], TaskStatus.PENDING)
}


/* ============================================================
 * 2. L2TaskCardItem — L2任务卡片条目 (@ReusableV2)
 *    原始：L2TaskCardBuilder (L418-537)
 * ============================================================ */

@ReusableV2
@ComponentV2
struct L2TaskCardItem {
  @Param goalId: string = ''
  @Param task: AiGeneratedTask = buildEmptyAiGeneratedTask()
  @Param taskIndex: number = 0
  @Param isExpanded: boolean = false
  @Param isInTodo: boolean = false
  @Event onToggleExpand: (taskId: string) => void = () => {}
  @Event onAddToHome: (goalId: string, taskId: string) => void = () => {}
  @Event onStepToggle: (goalId: string, taskId: string, stepIndex: number) => void =
    (_goalId: string, _taskId: string, _stepIndex: number): void => {}
  @Event onViewDetail: (taskId: string) => void = (_taskId: string): void => {}
  @Local isPressed: boolean = false
  @Local addBtnPressed: boolean = false

  build() {
    Column({ space: 0 }) {
      Row({ space: 8 }) {
        if (this.isInTodo) {
          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize(11)
            .fontColor([$r('app.color.text_secondary')])
            .fontWeight(FontWeight.Regular)
            
        }

        Text(safeStringUtil(this.task.taskName, '').length > 0 ? safeStringUtil(this.task.taskName, '') : $r('app.string.default_unnamed_task'))
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .fontWeight(FontWeight.Medium)
          
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 6 })
      .alignItems(VerticalAlign.Center)
      .onClick((): void => {
        this.onToggleExpand(this.task.id)
      })

      Row({ space: 6 }) {
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.clock'))
            .fontSize(11)
            .fontColor([$r('app.color.text_tertiary')])
          Text(safeNumberUtil(this.task.estimatedTime, 0).toString() + getContext(this).resourceManager.getStringSync($r('app.string.route_estimated_suffix').id))
            .fontSize(13)
            .fontColor($r('app.color.text_tertiary'))
            
        }

        if (Array.isArray(this.task.steps) && this.task.steps.length > 0) {
          Row({ space: 3 }) {
            Text('·')
              .fontSize(10)
              .fontColor($r('app.color.text_tertiary'))
            Text(this.task.steps.length.toString() + getContext(this).resourceManager.getStringSync($r('app.string.route_steps_count_suffix').id))
              .fontSize(13)
              .fontColor($r('app.color.text_tertiary'))
              
          }
        }

        Blank()

        Text(quadrantLabelUtil(classifyEisenhowerQuadrant(this.task.priority, this.task.deadline)))
          .fontSize(11)
          .fontColor(quadrantTextColorUtil(classifyEisenhowerQuadrant(this.task.priority, this.task.deadline)))
          .fontWeight(FontWeight.Regular)
          
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .backgroundColor(quadrantBgColorUtil(classifyEisenhowerQuadrant(this.task.priority, this.task.deadline)))
          .borderRadius(DimensConstants.RADIUS_XS)

        // 断链修复（2026-09-13）：详情入口此前藏在「已展开 && 有步骤 && 已加入待办」三重条件里
        // （原 L193-211），手动任务没有步骤时入口根本不渲染 → 点不进详情，无法修改/加步骤。
        // 现常显在信息行：详情页对无 L4 的任务已有 L2 兜底，全部操作可用。
        Text($r('app.string.goal_detail_view_task_detail'))
          .fontSize(11)
          .fontColor($r('app.color.primary_color'))
          .fontWeight(FontWeight.Medium)
          .padding({ left: 6, right: 6, top: 3, bottom: 3 })
          .onClick((): void => {
            this.onViewDetail(this.task.id)
          })

        if (!this.isInTodo) {
          Text($r('app.string.route_add_plus'))
            .fontSize(12)
            .fontColor($r('app.color.primary_color'))
            .fontWeight(FontWeight.Medium)
            
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .backgroundColor($r('app.color.primary_color_bg'))
            .borderRadius(DimensConstants.RADIUS_M)
            .scale({ x: this.addBtnPressed ? 0.95 : 1, y: this.addBtnPressed ? 0.95 : 1 })
            .animation(MotionConstants.pressParam())
            .onClick((): void => {
              this.onAddToHome(this.goalId, this.task.id)
            })
            .onTouch((event: TouchEvent): void => {
              if (event.type === TouchType.Down) {
                this.addBtnPressed = true
              } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                this.addBtnPressed = false
              }
            })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 12 })
      .alignItems(VerticalAlign.Center)

      if (this.isExpanded && Array.isArray(this.task.steps) && this.task.steps.length > 0) {
        Column({ space: 8 }) {
          ForEach(this.task.steps, (step: TaskStep, stepIdx: number): void => {
            Row({ space: 8 }) {
              // 完成态直读 step.isCompleted（@Trace）：勾选后精确刷新本行。
              // ⚠️ 勿改回 isStepCompleted(this.task, stepIdx) 预算传值 —— ForEach
              //    itemGenerator 非响应式作用域，key 已是稳定 step.id，勾选后不会重执行，
              //    预算值永远停留在旧状态（2026-09-17 TaskDetailPage 同款修复）。
              if (step.isCompleted) {
                 SymbolGlyph($r('sys.symbol.checkmark'))
                   .fontSize(11)
                   .fontColor([$r('app.color.success_color')])
                   .fontWeight(FontWeight.Bold)

                   .width(16)
              } else {
                 Text((stepIdx + 1).toString())
                   .fontSize(11)
                   .fontColor($r('app.color.text_tertiary'))
                   .fontWeight(FontWeight.Medium)

                   .width(16)
                  .textAlign(TextAlign.Center)
              }

              Text(step.text)
                .fontSize(13)
                .fontColor(step.isCompleted ?
                  $r('app.color.text_tertiary') : $r('app.color.text_secondary'))

                .decoration(step.isCompleted ?
                  { type: TextDecorationType.LineThrough } : { type: TextDecorationType.None })
                .layoutWeight(1)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .padding({ top: 6, bottom: 6 })
            .onClick((): void => {
              this.onStepToggle(this.goalId, this.task.id, stepIdx)
            })
          }, (step: TaskStep, stepIdx: number): string =>
            // key 改用稳定 id（原为 `index + stepVersion`，任何变更都会让全部 key 失效）
            step.id.length > 0 ? step.id : ('l3step_' + stepIdx.toString()))
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 10 })
        .backgroundColor($r('app.color.bg_page'))
        .borderRadius(DimensConstants.RADIUS_M)
        .margin({ left: 16, right: 16, bottom: 4 })
        // 展开/收起过渡：该容器由 `if (this.isExpanded ...)` 创建/销毁，属"组件插入/删除"，
        // 只有 `transition` 能触发（`.animation()` 对 if 换树无效 —— 没有属性在补间）。
        // ↓ 原注释标记的 L1b 待办，此处落地。
        .transition(MotionHelper.expandSection())
      }
    }
    .width('100%')
    .backgroundColor(Color.Transparent)
    .accessibilityText(getContext(this).resourceManager.getStringSync($r('app.string.acc_l2_task_card').id) +
      safeStringUtil(this.task.taskName, '') + '，' +
      quadrantLabelUtil(classifyEisenhowerQuadrant(this.task.priority, this.task.deadline)))
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down) {
        this.isPressed = true
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.isPressed = false
      }
    })
  }
}

/* ============================================================
 * 4. GoalHeaderSection — 目标信息卡 (@ComponentV2)
 *    原始：build() L1000-1099（目标信息卡部分）
 *    注：顶部返回栏因在 Scroll 外部，保留在根页面 build 内联
 * ============================================================ */

@ComponentV2
struct GoalHeaderSection {
  @Param goal: GoalCardItem = buildEmptyGoalCard()
  @Param taskCount: number = 0
  /**
   * 目标进度（0-100）——**数值型 @Param**，进度环唯一数据源
   *
   * ⚠️ 为什么不直接读 `this.goal.progress`（2026-09-17 修复进度不同步）：
   *   `goal` 是对象引用型 @Param，其属性级刷新依赖 V2 的观察链能一路传进本子组件；
   *   而"进度"是本页最高频、最需要即时反馈的读数，一旦这条链被 `@ReusableV2`/缓存
   *   任一层打断，环就会静默停在旧值（症状：勾完步骤目标详情的环不动）。
   *   改成**原始类型** @Param 后，父组件 post 一次新值就必然触发本组件刷新，
   *   不依赖任何对象观察语义 —— 把不确定性直接消掉。
   */
  @Param progress: number = 0

  /**
   * 实测卡片宽度（由根容器 onAreaChange 上报，挂在定宽容器上故无回环风险）
   * - 指标区断点判定的唯一来源：手机窄卡走三行列表，平板宽卡横排铺开
   */
  @Local cardWidth: number = 0

  /** 指标区是否宽屏铺开：卡片实测宽度 ≥ 中屏阈值（600vp） */
  private isWideCard(): boolean {
    return this.cardWidth >= CommonConstants.BREAKPOINT_MD
  }

  /** 指标（宽屏）：数值在上、标签在下，三列横排共用 */
  @Builder
  StatColumnBuilder(value: string, label: Resource, valueSize: number) {
    Column({ space: 4 }) {
      Text(value)
        .fontSize(valueSize)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Text(label)
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .maxLines(1)
    }
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 指标（窄屏）：标签左、数值右 的单行
   * - 窄卡上三列横排会因英文标签（Estimated Time）与长日期（2026-10-13）
   *   撑破行宽被裁切，改单行后标签可省略号、数值右对齐，永不溢出
   */
  @Builder
  StatLineBuilder(label: Resource, value: string) {
    Row() {
      Text(label)
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Text(value)
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  build() {
    Column({ space: 16 }) {
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          Text(safeStringUtil(this.goal.name, '').length > 0 ? safeStringUtil(this.goal.name, '') : $r('app.string.default_unnamed_goal'))
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))

            .layoutWeight(1)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')

        Row({ space: 8 }) {
          if (safeNumberUtil(this.progress, 0) >= 100) {
            Text($r('app.string.goal_detail_completed'))
              .fontSize(11)
              .fontColor($r('app.color.success_color'))
              .fontWeight(FontWeight.Medium)
              
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .backgroundColor($r('app.color.success_color_bg'))
              .borderRadius(DimensConstants.RADIUS_M)
          } else {
            Text($r('app.string.goal_detail_in_progress'))
              .fontSize(11)
              .fontColor($r('app.color.primary_color'))
              .fontWeight(FontWeight.Medium)
              
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .backgroundColor($r('app.color.primary_color_bg'))
              .borderRadius(DimensConstants.RADIUS_M)
          }

          Text(safeStringUtil(this.goal.category, '').length > 0 ? safeStringUtil(this.goal.category, '') : $r('app.string.default_other_category'))
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
            
            .backgroundColor($r('app.color.bg_tag'))
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .borderRadius(DimensConstants.RADIUS_M)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (safeStringUtil(this.goal.description, '').length > 0) {
          Text(safeStringUtil(this.goal.description, ''))
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
      }
      .width('100%')

      Row({ space: 20 }) {
        // 进度环：两种断点下位置一致
        Stack({ alignContent: Alignment.Center }) {
          Progress({ value: safeNumberUtil(this.progress, 0), total: 100, type: ProgressType.Ring })
            .width(84)
            .height(84)
            .style({ strokeWidth: 8 })
            .color(safeNumberUtil(this.progress, 0) >= 100 ?
              $r('app.color.success_color') : $r('app.color.primary_color'))
            .backgroundColor($r('app.color.bg_progress_track'))
          Text(safeNumberUtil(this.progress, 0).toString() + '%')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor(safeNumberUtil(this.progress, 0) > 0 ? $r('app.color.text_primary') : $r('app.color.text_tertiary'))
        }
        .width(84)
        .height(84)

        // 断点判定见 isWideCard()：卡片实测宽度 >= 600vp 视为宽卡
        if (this.isWideCard()) {
          // 宽屏（平板横屏）：三列横排 + SpaceAround 均分剩余宽度，内容铺开而非挤在左侧留白
          Row({ space: 16 }) {
            this.StatColumnBuilder(safeStringUtil(this.goal.duration, '--'),
              $r('app.string.goal_detail_estimated_time'), 22)
            this.StatColumnBuilder(formatDeadlineUtil(this.goal.deadline),
              $r('app.string.goal_detail_deadline_label'), 15)
            this.StatColumnBuilder(this.taskCount.toString(),
              $r('app.string.goal_detail_task_label'), 22)
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.SpaceAround)
        } else {
          // 窄屏（手机）：改为「标签左 / 数值右」三行列表。
          // 原三列横排在窄卡上会被英文标签（Estimated Time）与长日期（2026-10-13）
          // 撑破行宽导致末尾指标被裁切；改单行后标签可省略号、数值右对齐，永不溢出
          Column({ space: 8 }) {
            this.StatLineBuilder($r('app.string.goal_detail_estimated_time'),
              safeStringUtil(this.goal.duration, '--'))
            this.StatLineBuilder($r('app.string.goal_detail_deadline_label'),
              formatDeadlineUtil(this.goal.deadline))
            this.StatLineBuilder($r('app.string.goal_detail_task_label'),
              this.taskCount.toString())
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Start)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(20)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(DimensConstants.RADIUS_L)
    .shadow({ radius: 16, color: $r('app.color.shadow_card'), offsetX: 0, offsetY: 6 })
    // 实测卡片宽度上报：指标区断点判定的唯一来源。
    // 容器宽度由父级（页面左右 16 padding）决定，不随内部指标区布局切换而变化，故无回环风险。
    .onAreaChange((_oldArea: Area, newArea: Area): void => {
      const w: number = Number(newArea.width)
      if (!Number.isNaN(w)) {
        this.cardWidth = w
      }
    })
  }
}

/* ============================================================
 * 6. L2TaskListSection — L2任务拆解卡片列表区 (@ComponentV2)
 *    原始：build() L1185-1206
 * ============================================================ */

@ComponentV2
struct L2TaskListSection {
  @Param l2TaskDataSource: AiTaskDataSource = new AiTaskDataSource()
  // 刷新修复（2026-09-13）：任务计数/空态判断此前用 l2TaskDataSource.totalCount()——
  // 普通方法调用非响应式，从 0 添加第一个任务后 if 分支不重新求值，空态永远不切换。
  // 改由父组件传入 @Local 数组长度（@Local → @Param 响应式联动）。
  @Param taskCount: number = 0
  @Param goalId: string = ''
  @Param expandedL2TaskId: string = ''
  @Param isTaskInTodo: (taskId: string) => boolean = (_taskId: string): boolean => false
  @Event onToggleExpand: (taskId: string) => void = () => {}
  @Event onAddToHome: (goalId: string, taskId: string) => void = () => {}
  // 【修复 1】：补充 onStepToggle 的 @Event 声明
  @Event onStepToggle: (goalId: string, taskId: string, stepIndex: number) => void = (_g: string, _t: string, _s: number) => {}
  @Event onViewDetail: (taskId: string) => void = (_taskId: string): void => {}
  @Event onAddTask: () => void = () => {}

  build() {
    Column({ space: 14 }) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.folder'))
          .fontSize(16)
          .fontColor([$r('app.color.primary_color')])

        Text(getContext(this).resourceManager.getStringSync($r('app.string.goal_detail_task_label').id) + '（' + this.taskCount.toString() + '）')
          .fontSize(16).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
          .layoutWeight(1)

        Text($r('app.string.goal_detail_add_task_btn'))
          .fontSize(13)
          .fontColor($r('app.color.primary_color'))
          .fontWeight(FontWeight.Regular)
          
          .onClick((): void => { this.onAddTask() })
      }
      .width('100%')
      .padding({ left: 4, bottom: 4 })

      if (this.taskCount === 0) {
        Column({ space: 12 }) {
          Text($r('app.string.goal_detail_no_l2_task'))
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            .textAlign(TextAlign.Center)

          Button($r('app.string.goal_detail_add_task_btn'))
            .type(ButtonType.Capsule)
            .height(36)
            .padding({ left: 18, right: 18 })
            .backgroundColor($r('app.color.primary_color'))
            .fontColor($r('app.color.text_inverse'))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .shadow({ radius: 6, color: $r('app.color.shadow_card'), offsetX: 0, offsetY: 2 })
            .onClick((): void => { this.onAddTask() })
        }
        .width('100%')
        .padding(24)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor($r('app.color.bg_card'))
        .borderRadius(DimensConstants.RADIUS_L)
        .shadow({ radius: 4, color: $r('app.color.shadow_card'), offsetX: 0, offsetY: 1 })
      } else {
        Column() {
          LazyForEach(this.l2TaskDataSource, (task: AiGeneratedTask, idx: number): void => {
            L2TaskCardItem({
              goalId: this.goalId,
              task: task,
              taskIndex: idx,
              isExpanded: this.expandedL2TaskId === task.id,
              isInTodo: this.isTaskInTodo(task.id),
              onToggleExpand: this.onToggleExpand,
              onAddToHome: this.onAddToHome,
              onStepToggle: this.onStepToggle,
              onViewDetail: this.onViewDetail
            })
            if (idx < this.l2TaskDataSource.totalCount() - 1) {
              Divider()
                .width('100%')
                .color($r('app.color.divider'))
                .strokeWidth(0.5)
                .margin({ left: 16, right: 16 })
            }
          }, (task: AiGeneratedTask, idx: number): string => {
            return this.l2TaskDataSource.keyGenerator(idx)
          })
        }
        .width('100%')
        .backgroundColor($r('app.color.bg_card'))
        .borderRadius(DimensConstants.RADIUS_L)
        .shadow({ radius: 4, color: $r('app.color.shadow_card'), offsetX: 0, offsetY: 1 })
        .clip(true)
      }
    }
    .width('100%')
  }
}

/* ============================================================
 * 8. GoalEditPanel — 编辑目标弹窗面板 (@ComponentV2)
 *    原始：L46-159（已是独立@ComponentV2，移到文件底部）
 * ============================================================ */

@ComponentV2
struct GoalEditPanel {
  @Param goal: GoalCardItem = buildEmptyGoalCard()
  @Event onConfirm: (name: string, description: string, category: string, deadline: number) => void = () => {}
  @Event onCancel: () => void = () => {}

  @Local editName: string = ''
  @Local editDescription: string = ''
  @Local editCategory: string = ''
  /** 截止时间戳（毫秒），0=未设置 */
  @Local editDeadline: number = 0

  aboutToAppear(): void {
    this.editName = safeStringUtil(this.goal.name, '')
    this.editDescription = safeStringUtil(this.goal.description, '')
    this.editCategory = safeStringUtil(this.goal.category, '')
    this.editDeadline = this.goal.deadline > 0 ? this.goal.deadline : 0
  }

  private showDeadlinePicker(): void {
    DatePickerDialog.show({
      start: new Date(),
      end: new Date(Date.now() + 365 * 24 * 60 * 60 * 1000),
      selected: this.editDeadline > 0 ? new Date(this.editDeadline) : new Date(),
      onAccept: (value: DatePickerResult): void => {
        // 取当天 23:59:59 作为截止时间
        this.editDeadline = new Date(value.year, value.month, value.day, 23, 59, 59).getTime()
      }
    })
  }

  private handleConfirm(): void {
    const trimmedName: string = this.editName.trim()
    if (trimmedName.length === 0) {
      promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.goal_detail_goal_name_empty').id), duration: 1500 })
      return
    }
    this.onConfirm(trimmedName, this.editDescription.trim(), this.editCategory.trim(), this.editDeadline)
  }

  build() {
    Column() {
      Column({ space: 16 }) {
        Text($r('app.string.goal_detail_edit_goal'))
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          

        Column({ space: 8 }) {
          Text($r('app.string.goal_detail_goal_name'))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            
            .width('100%')
          TextInput({ text: this.editName, placeholder: $r('app.string.goal_detail_goal_name_hint') })
            .fontSize(14)
            .height(40)
            .backgroundColor($r('app.color.bg_tag'))
            .borderRadius(DimensConstants.RADIUS_S)
            .padding({ left: 12, right: 12 })
            .onChange((value: string): void => { this.editName = value })
        }
        .width('100%')

        Column({ space: 8 }) {
          Text($r('app.string.goal_detail_description'))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            
            .width('100%')
          TextArea({ text: this.editDescription, placeholder: $r('app.string.goal_detail_description_hint') })
            .fontSize(14)
            .height(80)
            .backgroundColor($r('app.color.bg_tag'))
            .borderRadius(DimensConstants.RADIUS_S)
            .padding(12)
            .onChange((value: string): void => { this.editDescription = value })
        }
        .width('100%')

        Column({ space: 8 }) {
          Text($r('app.string.goal_detail_category'))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            
            .width('100%')
          TextInput({ text: this.editCategory, placeholder: $r('app.string.goal_detail_category_hint') })
            .fontSize(14)
            .height(40)
            .backgroundColor($r('app.color.bg_tag'))
            .borderRadius(DimensConstants.RADIUS_S)
            .padding({ left: 12, right: 12 })
            .onChange((value: string): void => { this.editCategory = value })
        }
        .width('100%')

        // 截止时间（可选，点击弹日期选择器，可清除）
        Row({ space: 8 }) {
          Text($r('app.string.route_create_goal_deadline_label'))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)
          if (this.editDeadline > 0) {
            Text(formatDeadlineUtil(this.editDeadline))
              .fontSize(12)
              .fontColor($r('app.color.text_primary'))
            Text($r('app.string.goal_detail_deadline_clear'))
              .fontSize(12)
              .fontColor($r('app.color.error_color'))
              .onClick((): void => { this.editDeadline = 0 })
          } else {
            Text($r('app.string.goal_detail_no_deadline'))
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'))
          }
        }
        .width('100%')
        .height(40)
        .padding({ left: 12, right: 12 })
        .backgroundColor($r('app.color.bg_tag'))
        .borderRadius(DimensConstants.RADIUS_S)
        .onClick((): void => { this.showDeadlinePicker() })

        Row({ space: 12 }) {
          Button($r('app.string.common_cancel'))
            .type(ButtonType.Capsule)
            .height(40)
            .layoutWeight(1)
            .backgroundColor($r('app.color.bg_tag'))
            .fontColor($r('app.color.text_secondary'))
            .fontSize(14)
            .onClick((): void => { this.onCancel() })

          Button($r('app.string.btn_save'))
            .type(ButtonType.Capsule)
            .height(40)
            .layoutWeight(1)
            .backgroundColor($r('app.color.primary_color'))
            .fontColor($r('app.color.text_inverse'))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .onClick((): void => { this.handleConfirm() })
        }
        .width('100%')
      }
      .width('85%')
      .padding(20)
      .backgroundColor($r('app.color.bg_card'))
      .borderRadius(DimensConstants.RADIUS_L)
      .shadow({ radius: 20, color: $r('app.color.shadow_dialog_overlay'), offsetX: 0, offsetY: 4 }) // Opt: H3-3 硬编码颜色替换为资源引用
      // 位移/缩放只能挂内层卡片：遮罩是同一棵树的背景层，跟着移动会带出错误的空间暗示
      .transition(MotionHelper.dialogCard())
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('app.color.overlay_mask')) // Opt: H3-3 硬编码颜色替换为资源引用
    .transition(MotionHelper.overlayFade())
    .onClick((): void => { this.onCancel() })
  }
}

/* ============================================================
 * 8.3 AddTaskPanel — 手动添加任务弹窗 (@ComponentV2)
 * ============================================================ */

@ComponentV2
struct AddTaskPanel {
  @Event onConfirm: (taskName: string, priority: TaskPriority, deadline: number, estimatedTime: number) => void = () => {}
  @Event onCancel: () => void = () => {}

  @Local editName: string = ''
  /** 优先级，默认中 */
  @Local editPriority: TaskPriority = TaskPriority.MEDIUM
  /** 截止时间戳（毫秒），0=未设置 */
  @Local editDeadline: number = 0
  /** 预估耗时输入值（配合单位换算为分钟），空=未设置 */
  @Local editDurationValue: string = ''
  /** 耗时单位倍率：1=分钟 60=小时 1440=天 */
  @Local editDurationUnit: number = 1

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
      this.editDurationUnit = 60
      this.editDurationValue = '12'
      return
    }
    if (minutes >= 1440) {
      this.editDurationUnit = 1440
      this.editDurationValue = (minutes / 1440).toString()
      return
    }
    if (minutes >= 60) {
      this.editDurationUnit = 60
      this.editDurationValue = (minutes / 60).toString()
      return
    }
    this.editDurationUnit = 1
    this.editDurationValue = minutes.toString()
  }

  private showDeadlinePicker(): void {
    DatePickerDialog.show({
      start: new Date(),
      end: new Date(Date.now() + 365 * 24 * 60 * 60 * 1000),
      selected: this.editDeadline > 0 ? new Date(this.editDeadline) : new Date(),
      onAccept: (value: DatePickerResult): void => {
        // 取当天 23:59:59 作为截止时间
        this.editDeadline = new Date(value.year, value.month, value.day, 23, 59, 59).getTime()
      }
    })
  }

  private handleConfirm(): void {
    const trimmedName: string = this.editName.trim()
    if (trimmedName.length === 0) {
      promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_input_empty').id), duration: 1500 })
      return
    }
    const parsedValue: number = parseInt(this.editDurationValue, 10)
    const safeTime: number = (isNaN(parsedValue) || parsedValue <= 0)
      ? 0 : Math.floor(parsedValue * this.editDurationUnit)
    this.onConfirm(trimmedName, this.editPriority, this.editDeadline, safeTime)
  }

  build() {
    Column() {
      Column({ space: 16 }) {
        Text($r('app.string.goal_detail_add_task_title'))
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          

        Column({ space: 8 }) {
          Text($r('app.string.goal_detail_add_task_name_label'))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            
            .width('100%')
          TextInput({ text: this.editName, placeholder: $r('app.string.goal_detail_add_task_name_hint') })
            .fontSize(14)
            .height(40)
            .backgroundColor($r('app.color.bg_tag'))
            .borderRadius(DimensConstants.RADIUS_S)
            .padding({ left: 12, right: 12 })
            .onChange((value: string): void => { this.editName = value })
        }
        .width('100%')

        // 优先级选择（高/中/低）
        Column({ space: 8 }) {
          Text($r('app.string.goal_detail_priority_label'))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            
            .width('100%')
          Row({ space: 8 }) {
            ForEach([TaskPriority.HIGH, TaskPriority.MEDIUM, TaskPriority.LOW], (p: TaskPriority): void => {
              Text(priorityLabelUtil(p))
                .fontSize(12)
                .fontColor(this.editPriority === p ?
                  $r('app.color.text_inverse') : $r('app.color.text_secondary'))
                .backgroundColor(this.editPriority === p ?
                  $r('app.color.primary_color') : $r('app.color.bg_tag'))
                .borderRadius(DimensConstants.RADIUS_M)
                .padding({ left: 14, right: 14, top: 5, bottom: 5 })
                .onClick((): void => { this.editPriority = p })
            }, (p: TaskPriority): string => 'prio_' + p.toString())
          }
          .width('100%')
        }
        .width('100%')

        // 截止时间（可选，点击弹日期选择器，可清除）
        Row({ space: 8 }) {
          Text($r('app.string.route_create_goal_deadline_label'))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)
          if (this.editDeadline > 0) {
            Text(formatDeadlineUtil(this.editDeadline))
              .fontSize(12)
              .fontColor($r('app.color.text_primary'))
            Text($r('app.string.goal_detail_deadline_clear'))
              .fontSize(12)
              .fontColor($r('app.color.error_color'))
              .onClick((): void => { this.editDeadline = 0 })
          } else {
            Text($r('app.string.goal_detail_no_deadline'))
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'))
          }
        }
        .width('100%')
        .height(40)
        .padding({ left: 12, right: 12 })
        .backgroundColor($r('app.color.bg_tag'))
        .borderRadius(DimensConstants.RADIUS_S)
        .onClick((): void => { this.showDeadlinePicker() })

        // 预估耗时（可选：分钟/小时/天 + 快捷档位）
        Column({ space: 8 }) {
          Row({ space: 8 }) {
            Text($r('app.string.goal_detail_estimated_time_label'))
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              
              .layoutWeight(1)
            ForEach(this.durationUnitOptions, (unit: number): void => {
              Text(this.durationUnitLabel(unit))
                .fontSize(12)
                .fontColor(this.editDurationUnit === unit ?
                  $r('app.color.text_inverse') : $r('app.color.text_secondary'))
                .backgroundColor(this.editDurationUnit === unit ?
                  $r('app.color.primary_color') : $r('app.color.bg_tag'))
                .borderRadius(DimensConstants.RADIUS_M)
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .onClick((): void => { this.editDurationUnit = unit })
            }, (unit: number): string => 'unit_' + unit.toString())
          }
          .width('100%')

          TextInput({ text: this.editDurationValue, placeholder: $r('app.string.goal_detail_estimated_time_hint') })
            .type(InputType.Number)
            .fontSize(14)
            .height(40)
            .backgroundColor($r('app.color.bg_tag'))
            .borderRadius(DimensConstants.RADIUS_S)
            .padding({ left: 12, right: 12 })
            .onChange((value: string): void => { this.editDurationValue = value })

          // 快捷档位
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.durationPresets, (minutes: number): void => {
              Text(this.presetLabel(minutes))
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .backgroundColor($r('app.color.bg_tag'))
                .borderRadius(DimensConstants.RADIUS_M)
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .margin({ right: 6, bottom: 6 })
                .onClick((): void => { this.applyPreset(minutes) })
            }, (minutes: number): string => 'preset_' + minutes.toString())
          }
          .width('100%')
        }
        .width('100%')

        Row({ space: 12 }) {
          Button($r('app.string.common_cancel'))
            .type(ButtonType.Capsule)
            .height(40)
            .layoutWeight(1)
            .backgroundColor($r('app.color.bg_tag'))
            .fontColor($r('app.color.text_secondary'))
            .fontSize(14)
            .onClick((): void => { this.onCancel() })

          Button($r('app.string.btn_save'))
            .type(ButtonType.Capsule)
            .height(40)
            .layoutWeight(1)
            .backgroundColor($r('app.color.primary_color'))
            .fontColor($r('app.color.text_inverse'))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .onClick((): void => { this.handleConfirm() })
        }
        .width('100%')
      }
      .width('85%')
      .padding(20)
      .backgroundColor($r('app.color.bg_card'))
      .borderRadius(DimensConstants.RADIUS_L)
      .shadow({ radius: 20, color: $r('app.color.shadow_dialog_overlay'), offsetX: 0, offsetY: 4 })
      // 位移/缩放只能挂内层卡片：遮罩是同一棵树的背景层，跟着移动会带出错误的空间暗示
      .transition(MotionHelper.dialogCard())
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('app.color.overlay_mask'))
    .transition(MotionHelper.overlayFade())
    .onClick((): void => { this.onCancel() })
  }
}

/* ============================================================
 * 9. GoalDetailPage — 根页面 (@ComponentV2)
 *    保留：所有@Local状态 + 生命周期 + 业务事件方法 + 子组件组装
 * ============================================================ */

@ComponentV2
export struct GoalDetailPage {
  @Local goal: GoalCardItem = buildEmptyGoalCard()

  @Local l2Tasks: AiGeneratedTask[] = []
  private l2TaskDataSource: AiTaskDataSource = new AiTaskDataSource()
  @Local showEditDialog: boolean = false
  @Local showAddTaskDialog: boolean = false
  @Local expandedL2TaskId: string = ''
  // 原 `@Local stepVersion`（勾选步骤时自增，靠 @Param 变更强制整卡重渲染）已于 2026-09-17 删除：
  // 步骤行直读 `step.isCompleted`，而 `TaskStep` 是 @ObservedV2 + @Trace（`task.steps` 亦 @Trace）
  // ⇒ 精确响应式已覆盖，版本号兜底只剩下「每次勾选白刷整段任务列表」的副作用。
  @Local pressedL2AddTaskId: string = ''
  private pressedL2Timer: number = -1
  @Local isLoading: boolean = true
  /** 错误态：路由参数缺失或目标不存在 */
  @Local loadError: boolean = false
  /** 错误态重试用：缓存进入页面时的路由上下文 */
  private lastNavContext: NavDestinationContext | null = null
  @Local skeletonOpacity: number = 0.5
  private isAttached: boolean = false
  /** B1 复盘：弹层显示/加载中/报告文本 */
  @Local showReviewSheet: boolean = false
  @Local reviewLoading: boolean = false
  @Local reviewText: string = ''
  /** 统一操作面板状态 */
  @Local showActionSheet: boolean = false
  @Local actionSheetTitle: string = ''
  @Local actionSheetItems: AppActionSheetItem[] = []
  /** 目标达成撒花（GOAL_COMPLETED 事件驱动，仅当前页目标达成时播放） */
  @Local showConfetti: boolean = false
  private goalCompletedCallbackId: number = -1
  /**
   * 目标进度变化订阅 ID（本地操作 / **云同步落地**都会广播；-1 = 未订阅）
   * ⚠️ 本页持有 `@Local goal` 与 `@Local l2Tasks` **独立副本**（不像首页/统计页直接读
   *    `liveGoals` / `liveTasks` 派生视图）⇒ 云同步落地时本页**不会自动感知**，
   *    必须在事件里重取活引用，否则进度环 / 里程碑 / 任务列表停在旧值。
   */
  private goalProgressCallbackId: number = -1

  aboutToAppear(): void {
    this.isAttached = true
    this.startSkeletonShimmer()
    // 目标达成事件：只对本页目标响应（其他目标完成与本页无关）
    this.goalCompletedCallbackId = eventBus.on(EventType.GOAL_COMPLETED,
      (payload: Object): void => {
        const data: GoalCompletedPayload = payload as GoalCompletedPayload
        if (data.goalId === this.goal.id && !this.showConfetti) {
          this.showConfetti = true
        }
      })
    // 进度变化事件：只对本页目标响应（其他目标的进度与本页无关）。
    // 幂等：重复 aboutToAppear 时先注销旧订阅，避免回调堆积。
    if (this.goalProgressCallbackId !== -1) {
      eventBus.off(EventType.GOAL_PROGRESS_CHANGED, this.goalProgressCallbackId)
    }
    this.goalProgressCallbackId = eventBus.on(EventType.GOAL_PROGRESS_CHANGED,
      (payload: Object): void => {
        const data: GoalProgressChangedPayload = payload as GoalProgressChangedPayload
        if (data.goalId === this.goal.id) {
          this.refreshOnShown()
        }
      })
  }

  aboutToDisappear(): void {
    this.isAttached = false
    if (this.pressedL2Timer !== -1) clearTimeout(this.pressedL2Timer)
    if (this.goalCompletedCallbackId !== -1) {
      eventBus.off(EventType.GOAL_COMPLETED, this.goalCompletedCallbackId)
      this.goalCompletedCallbackId = -1
    }
    if (this.goalProgressCallbackId !== -1) {
      eventBus.off(EventType.GOAL_PROGRESS_CHANGED, this.goalProgressCallbackId)
      this.goalProgressCallbackId = -1
    }
  }

  @Local shimmerOffset: number = -100

  private startSkeletonShimmer(): void {
    this.shimmerOffset = -100
    animateTo({
      duration: 1200,
      iterations: -1,
      curve: Curve.Linear,
      onFinish: () => {}
    }, () => {
      this.shimmerOffset = 100
    })
  }

  /**
   * onShown状态刷新
   * 应用从后台切回或从子页面返回时，刷新目标数据（里程碑/任务可能已变更）
   */
  private refreshOnShown(): void {
    if (!this.goal.id || this.goal.id.length === 0) return
    const latestGoal: GoalCardItem = this.findLatestGoal(this.goal.id, this.goal)
    this.goal = latestGoal
    this.l2Tasks = this.findLatestL2Tasks(latestGoal.id)
    this.l2TaskDataSource.updateAll(this.l2Tasks)
  }

  /**
   * 返回按钮处理（含异常处理 + 兜底）
   */
  private isTaskInTodo(taskId: string): boolean {
    return homeVM.isTaskInTodo(taskId)
  }

  /**
   * L2 任务展开/收起切换（由 L2TaskCardItem @Event 回调触发）
   */
  private handleToggleL2Expand(taskId: string): void {
    this.expandedL2TaskId = this.expandedL2TaskId === taskId ? '' : taskId
    this.l2TaskDataSource.updateAll(this.l2Tasks)
  }

  /**
   * L2 任务摘取流入口
   * - 调用 routeVM.extractToHomeTodo 获取 L4 实例
   * - 调用 homeVM.addExtractedTask 写入首页
   *
   * @param goalId - L1 目标 ID
   * @param taskId - L2 任务 ID
   */
  private handleL2ExtractToHome(goalId: string, taskId: string): void {
    if (!goalId || !taskId) {
      Logger.warn('GoalDetailPage', 'handleL2ExtractToHome: invalid params')
      return
    }
    Logger.info('GoalDetailPage', 'handleL2ExtractToHome start, goalId=' + goalId + ', taskId=' + taskId)
    try {
      const todo = routeVM.extractToHomeTodo(goalId, taskId)
      if (!todo) {
        promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_task_extract_failed').id) })
        return
      }
      const ok: boolean = homeVM.addExtractedTask(todo)
      if (ok) {
        this.pressedL2AddTaskId = taskId
        this.l2TaskDataSource.updateAll(this.l2Tasks)
        promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.goal_detail_added_to_todo_prefix').id) + safeStringUtil(todo.title, '') })
        if (this.pressedL2Timer !== -1) clearTimeout(this.pressedL2Timer)
        this.pressedL2Timer = setTimeout((): void => {
          if (this.pressedL2AddTaskId === taskId) {
            this.pressedL2AddTaskId = ''
          }
          this.pressedL2Timer = -1
          this.l2TaskDataSource.updateAll(this.l2Tasks)
        }, 1500)
      } else {
        promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_task_already_in_todo').id) })
      }
    } catch (e) {
      const err: Error = e as Error
      Logger.error('GoalDetailPage', 'handleL2ExtractToHome failed, msg=' + err.message)
      promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_update_failed_retry').id) })
    }
  }

  /**
   * L3 步骤勾选切换（4 级架构反向联动核心入口）
   *
   * 联动链路：
   *   routeVM.updateStep(goalId, taskId, stepIndex, !isCompleted)
   *     → 更新 L3 步骤完成态（steps[i].isCompleted）
   *     → 自动维护 L2.status (COMPLETED/IN_PROGRESS)
   *     → 调用 homeVM.syncRelatedTaskCompletion 同步 L4.isCompleted
   *     → 调用 updateGoalProgressByTasks 重算 L1.progress
   *
   * 同步刷新本页 UI：
   *   - l2Tasks / l2TaskDataSource: L2 任务状态变化
   *   - 步骤勾选态由 `TaskStep.isCompleted`（@ObservedV2 + @Trace）精确通知，
   *     无需版本号兜底（原 `stepVersion += 1` 已删除）
   *
   * @param goalId - L1 目标 ID
   * @param taskId - L2 任务 ID
   * @param stepIndex - L3 步骤索引
   */
  private handleStepToggle(goalId: string, taskId: string, stepIndex: number): void {
    if (!goalId || !taskId || stepIndex < 0) {
      Logger.warn('GoalDetailPage', 'handleStepToggle: invalid params')
      return
    }
    try {
      const currentCompleted: boolean = routeVM.getStepStatus(goalId, taskId, stepIndex)
      const success: boolean = routeVM.updateStep(goalId, taskId, stepIndex, !currentCompleted)
      if (!success) {
        Logger.warn('GoalDetailPage', 'handleStepToggle: updateStep failed')
        return
      }
      // 刷新本页数据源
      this.l2Tasks = this.findLatestL2Tasks(goalId)
      this.l2TaskDataSource.updateAll(this.l2Tasks)
      // 同步刷新目标引用：routeVM 内部若发生整体替换（云同步落地 splice / 重载），
      // 本地 this.goal 会变成脱离数组的旧对象 ⇒ 进度环读的是死值。
      // 每次勾选都重新取一次活引用，把这条路径的陈旧引用也一并消掉。
      this.goal = this.findLatestGoal(goalId, this.goal)
      Logger.info('GoalDetailPage', 'handleStepToggle success, goalId=' + goalId +
        ', taskId=' + taskId + ', stepIndex=' + stepIndex.toString())
    } catch (e) {
      const err: Error = e as Error
      Logger.error('GoalDetailPage', 'handleStepToggle failed, msg=' + err.message)
      promptAction.showToast({
        message: getContext(this).resourceManager.getStringSync($r('app.string.toast_update_failed_retry').id),
        duration: 1500
      })
    }
  }

  /**
   * 显示目标操作菜单（编辑/AI 复盘/删除）
   */
  private showGoalActionMenu(): void {
    // 统一 ActionSheet：替代系统 showActionMenu 兜底样式
    this.actionSheetTitle = getContext(this).resourceManager.getStringSync($r('app.string.dialog_goal_action_title').id)
    this.actionSheetItems = [
      {
        label: getContext(this).resourceManager.getStringSync($r('app.string.dialog_edit_goal').id),
        action: (): void => { this.handleEditGoal() }
      },
      {
        label: getContext(this).resourceManager.getStringSync($r('app.string.dialog_goal_review').id),
        action: (): void => { this.handleGoalReview() }
      },
      {
        label: getContext(this).resourceManager.getStringSync($r('app.string.dialog_delete_goal').id),
        danger: true,
        action: (): void => { this.handleDeleteGoal() }
      }
    ]
    this.showActionSheet = true
  }

  /**
   * B1 目标完结复盘：调用 DeepSeekService 生成复盘报告并在全屏弹层展示
   * - 打开弹层即进入加载态
   * - 成功后展示纯文本报告；失败 toast 并关闭弹层
   */
  private handleGoalReview(): void {
    if (!this.goal.id || this.goal.id.length === 0) {
      Logger.warn('GoalDetailPage', 'handleGoalReview: goalId empty')
      return
    }
    this.showReviewSheet = true
    this.reviewLoading = true
    this.reviewText = ''
    DeepSeekService.getInstance().generateGoalReview(this.goal).then((report: string): void => {
      if (!this.isAttached) return
      this.reviewLoading = false
      if (report.length === 0) {
        this.reviewText = ''
        this.showReviewSheet = false
        promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_review_failed').id), duration: 1500 })
        return
      }
      // 本地回填：报告里的「任务N」还原为真实任务名（任务名未发送给模型）
      const taskTitles: string[] = []
      for (let i: number = 0; i < this.goal.tasks.length; i++) {
        taskTitles.push(this.goal.tasks[i].taskName)
      }
      this.reviewText = ProfileAnalyzerService.substituteTaskLabels(report, taskTitles)
      Logger.info('GoalDetailPage', 'handleGoalReview success, reportLen=' + report.length.toString())
    }).catch((e: Error): void => {
      Logger.error('GoalDetailPage', 'handleGoalReview failed: ' + e.message)
      if (!this.isAttached) return
      this.reviewLoading = false
      this.showReviewSheet = false
      promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_review_failed').id), duration: 1500 })
    })
  }

  /**
   * 编辑目标
   */
  private handleEditGoal(): void {
    this.showEditGoalDialog()
  }

  /**
   * 自定义编辑目标对话框
   */
  private showEditGoalDialog(): void {
    this.showEditDialog = true
  }

  private confirmEditGoal(editName: string, editDescription: string, editCategory: string, editDeadline: number): void {
    const success: boolean = routeVM.updateGoal(this.goal.id, editName,
      editDescription, editCategory, editDeadline)
    if (success) {
      this.goal = this.findLatestGoal(this.goal.id, this.goal)
      this.showEditDialog = false
        promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_goal_updated').id), duration: 1500 })
    } else {
        promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_update_failed_retry').id), duration: 1500 })
    }
  }

  /**
   * 确认手动添加任务（L2 AiGeneratedTask）
   * - 构造新 AiGeneratedTask 调 routeVM.addTaskToGoal 追加
   * - 刷新本地 l2Tasks + dataSource 触发 @Trace 响应式刷新
   */
  private confirmAddTask(taskName: string, priority: TaskPriority, deadline: number, estimatedTime: number): void {
    if (!this.goal.id || this.goal.id.length === 0) {
      Logger.warn('GoalDetailPage', 'confirmAddTask: goalId empty')
      return
    }
    const newId: string = 'task_manual_' + Date.now().toString()
    const task: AiGeneratedTask = new AiGeneratedTask(newId, taskName, estimatedTime, priority, [],
      TaskStatus.PENDING, 0, 0, deadline)
    routeVM.addTaskToGoal(this.goal.id, task)
    // 断链修复（2026-09-13）：此前手动添加只建 L2、不建 L4 待办，导致
    //   ① 点击任务弹「任务未找到」进不了详情（改不了、加不了步骤）
    //   ② 任务不出现在四象限/番茄钟，与 AI 任务行为不一致
    // 复用既有摘取机制（extractToHomeTodo + addExtractedTask）同步创建 L4，
    // 使手动任务与 AI 任务链路完全一致。addExtractedTask 自带去重与截止提醒调度。
    const todo: HomeTodoItem | null = routeVM.extractToHomeTodo(this.goal.id, newId)
    if (todo !== null) {
      const added: boolean = homeVM.addExtractedTask(todo)
      if (!added) {
        Logger.warn('GoalDetailPage', 'confirmAddTask: L4 already exists for l2TaskId=' + newId)
      }
    } else {
      Logger.warn('GoalDetailPage', 'confirmAddTask: extractToHomeTodo returned null, L4 not created')
    }
    // 刷新本地状态 + dataSource 触发响应式刷新
    this.l2Tasks = this.findLatestL2Tasks(this.goal.id)
    this.l2TaskDataSource.updateAll(this.l2Tasks)
    this.goal = this.findLatestGoal(this.goal.id, this.goal)
    this.showAddTaskDialog = false
    promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_task_added').id), duration: 1500 })
    Logger.info('GoalDetailPage', 'confirmAddTask: added id=' + newId + ' name=' + taskName +
      ', priority=' + priority.toString() + ', deadline=' + deadline.toString())
  }

  /**
   * 删除目标（带二次确认）
   */
  private handleDeleteGoal(): void {
    const goalName: string = safeStringUtil(this.goal.name, '').length > 0 ?
      safeStringUtil(this.goal.name, '') :
      getContext(this).resourceManager.getStringSync($r('app.string.default_unnamed_goal').id)
    const deleteMsg: string = getContext(this).resourceManager.getStringSync($r('app.string.goal_detail_dialog_delete_confirm_prefix').id) + goalName + getContext(this).resourceManager.getStringSync($r('app.string.goal_detail_dialog_delete_confirm_suffix').id) +
      getContext(this).resourceManager.getStringSync($r('app.string.dialog_delete_message').id)
    promptAction.showDialog({
      title: $r('app.string.dialog_delete_title'),
      message: deleteMsg,
      buttons: [
        { text: $r('app.string.common_cancel'), color: $r('app.color.text_secondary') },
        { text: $r('app.string.btn_delete'), color: $r('app.color.error_color') }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse): void => {
      if (!this.isAttached) return
      if (result.index === 1) {
        const success: boolean = routeVM.deleteGoal(this.goal.id)
        if (success) {
           promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_goal_deleted').id) })
          this.handleBack()
        } else {
           promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_delete_failed_retry').id) })
         }
       }
     }).catch((e: Error): void => {
       Logger.error('GoalDetailPage', 'handleDeleteGoal failed: ' + e.message)
    })
  }

  /**
   * 删除任务（带确认）
   */
  private handleDeleteTask(goalId: string, taskId: string): void {
    promptAction.showDialog({
      title: $r('app.string.dialog_delete_title'),
      message: $r('app.string.goal_detail_delete_task_message'),
      buttons: [
        { text: $r('app.string.common_cancel'), color: $r('app.color.text_secondary') },
        { text: $r('app.string.btn_delete'), color: $r('app.color.error_color') }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse): void => {
      if (!this.isAttached) return
      if (result.index === 1) {
        const success: boolean = routeVM.deleteTask(goalId, taskId)
        if (success) {
           promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_task_deleted').id) })
          this.l2Tasks = this.findLatestL2Tasks(this.goal.id)
          this.l2TaskDataSource.updateAll(this.l2Tasks)
        } else {
           promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_delete_failed_retry').id) })
         }
       }
     }).catch((e: Error): void => {
       Logger.error('GoalDetailPage', 'handleDeleteTask failed: ' + e.message)
    })
  }

  /** 详情页来源行文案：「来自目标「xxx」」 */
  private buildGoalSourceText(): string {
    return getContext(this).resourceManager.getStringSync($r('app.string.goal_detail_from_goal_prefix').id) +
      (safeStringUtil(this.goal.name, '').length > 0
        ? safeStringUtil(this.goal.name, '')
        : getContext(this).resourceManager.getStringSync($r('app.string.default_unnamed_goal').id)) +
      getContext(this).resourceManager.getStringSync($r('app.string.goal_detail_from_goal_suffix').id)
  }

  /** 统一的详情页导航（构造参数 + 压栈 + 异常兜底） */
  private pushTaskDetail(detailItem: TaskDetailItem, goalId: string, relatedTaskId: string): void {
    try {
      const param: TaskDetailRouteNavParam = {
        id: detailItem.id,
        task: detailItem,
        goalId: safeStringUtil(goalId, ''),
        relatedTaskId: safeStringUtil(relatedTaskId, '')
      }
      globalNavStack.pushPath({ name: ROUTE_NAME.TASK_DETAIL, param: param })
      Logger.info('GoalDetailPage', 'pushTaskDetail: navigated, taskId=' + detailItem.id +
        ', relatedTaskId=' + param.relatedTaskId)
    } catch (e) {
      const err: Error = e as Error
      Logger.error('GoalDetailPage', 'pushTaskDetail failed, msg=' + err.message)
      promptAction.showToast({
        message: getContext(this).resourceManager.getStringSync($r('app.string.toast_update_failed_retry').id),
        duration: 1500
      })
    }
  }

  private handleViewTaskDetail(l2TaskId: string): void {
    if (!l2TaskId || l2TaskId.length === 0) {
      Logger.warn('GoalDetailPage', 'handleViewTaskDetail: l2TaskId is empty')
      return
    }
    const freshTask: HomeTodoItem | undefined = homeVM.liveTasks.find(
      (t: HomeTodoItem): boolean => t.relatedTaskId === l2TaskId
    )
    if (freshTask) {
      // 常规路径：L2 ↔ L4 关联完整，用 L4 待办数据
      const detailItem: TaskDetailItem = new TaskDetailItem(
        freshTask.id,
        freshTask.title,
        this.buildGoalSourceText(),
        freshTask.duration,
        freshTask.priority,
        freshTask.isCompleted,
        freshTask.createTime
      )
      this.pushTaskDetail(detailItem, freshTask.relatedGoalId, freshTask.relatedTaskId)
      return
    }
    // 断链兜底（2026-09-13）：手动添加的历史任务只有 L2、没有 L4 待办
    // （老版 confirmAddTask 不创建 L4），此前在此弹「任务未找到」拦死 → 无法修改/加步骤。
    // 降级用 L2 数据直接进详情：详情页的编辑/删除/步骤均走 routeVM（L2 存在，全部可用）；
    // 仅番茄钟聚焦统计依赖 L4 反查，无 L4 时为空，属可接受降级。
    const l2: AiGeneratedTask | null = routeVM.findTask(this.goal.id, l2TaskId)
    if (l2 === null) {
      // 数据异常（L2 也不存在）：维持原有拦截
      Logger.warn('GoalDetailPage', 'handleViewTaskDetail: L4 missing and L2 not found, l2TaskId=' + l2TaskId)
      promptAction.showToast({
        message: getContext(this).resourceManager.getStringSync($r('app.string.goal_detail_task_not_found').id),
        duration: 1500
      })
      return
    }
    Logger.info('GoalDetailPage', 'handleViewTaskDetail: L4 missing, fallback to L2 snapshot, l2TaskId=' + l2TaskId)
    const detailItem: TaskDetailItem = new TaskDetailItem(
      l2TaskId,
      l2.taskName,
      this.buildGoalSourceText(),
      formatEstimatedDuration(l2.estimatedTime, getContext(this).resourceManager),
      l2.priority,
      l2.status === TaskStatus.COMPLETED,
      Date.now()
    )
    this.pushTaskDetail(detailItem, this.goal.id, l2TaskId)
  }

  private onDestinationReady(context: NavDestinationContext): void {
    // ★ 游客模式：目标详情的数据源是**本地** routeVM，游客可正常查看，此处不再拦页跳转。
    //   原实现 `replacePath(LOGIN)` 会把游客从目标详情直接替换到登录页 ——
    //   结果是"游客能进路线页、却点不开任何目标"，与 `docs/上架素材/上架文案.md:93/98`
    //   对市场承诺的「以游客身份体验全部本地功能」矛盾。
    //   需要登录的动作（AI 复盘等）在各触发点就地锁定 + 给引导词即可。
    // 缓存路由上下文，供错误态"重试"重新加载
    this.lastNavContext = context
    this.loadGoalFromNav(context)
  }

  /** 从路由参数加载目标数据（onDestinationReady 与错误态重试共用） */
  private loadGoalFromNav(context: NavDestinationContext): void {
    this.isLoading = true
    this.loadError = false

    const rawParam: Object = context.pathInfo.param as Object
    if (rawParam === null || rawParam === undefined) {
      Logger.error('GoalDetailPage', 'navParam is null')
      this.loadError = true
      this.isLoading = false
      return
    }
    const navParam: GoalDetailRouteNavParam = rawParam as GoalDetailRouteNavParam
    if (!navParam.goal || !navParam.goal.id) {
      Logger.error('GoalDetailPage', 'navParam.goal is null or missing id')
      this.loadError = true
      this.isLoading = false
      return
    }
    const srcGoal: GoalCardItem = navParam.goal
    const latestGoal: GoalCardItem = this.findLatestGoal(srcGoal.id, srcGoal)
    this.goal = latestGoal
    this.l2Tasks = this.findLatestL2Tasks(latestGoal.id)
    this.l2TaskDataSource.updateAll(this.l2Tasks)

    // 数据同步读取，无需假延迟（原 setTimeout 300ms 强行演骨架屏已移除）
    this.isLoading = false
  }

  /** 错误态"重试"：基于缓存的路由上下文重新加载（原实现直接返回页面，重试名不副实） */
  private retryLoadGoal(): void {
    if (this.lastNavContext !== null) {
      this.loadGoalFromNav(this.lastNavContext)
    } else {
      this.handleBackPress()
    }
  }

  private findLatestGoal(goalId: string, fallback: GoalCardItem): GoalCardItem {
    for (let i: number = 0; i < routeVM.liveGoals.length; i++) {
      const g: GoalCardItem = routeVM.liveGoals[i]
      if (g.id === goalId) return g
    }
    return fallback
  }

  /**
   * 从 routeVM 取 L2 任务
   * - 数据源：goal.tasks（routeVM 持久化字段）
   * - 与 relatedTasks 区分：relatedTasks 是 L4（homeVM 中已加入待办的任务），l2Tasks 是原始拆解
   * - 返回引用（不是副本）→ 支持 @Trace 响应式联动
   *
   * @param goalId - L1 目标 ID
   * @returns L2 任务数组（找不到或空时返回 []）
   */
  private findLatestL2Tasks(goalId: string): AiGeneratedTask[] {
    for (let i: number = 0; i < routeVM.liveGoals.length; i++) {
      const g: GoalCardItem = routeVM.liveGoals[i]
      if (g.id === goalId && Array.isArray(g.tasks) && g.tasks.length > 0) {
        return g.tasks
      }
    }
    return []
  }

  /**
   * Tab 跳转辅助方法
   * 用于空态引导：跳到 AI Tab 生成新项目
   */
  private switchToAITab(): void {
    try {
      globalTabsController.changeIndex(TAB_INDEX.AI)
      Logger.info('GoalDetailPage', 'switchToAITab: navigated to AI tab')
    } catch (e) {
      Logger.error('GoalDetailPage', 'switchToAITab failed, msg=' + (e as Error).message)
    }
  }

  /**
   * 返回按钮处理（含异常处理 + 兜底）
   */
  private handleBack(): void {
    try {
      globalNavStack.pop()
      Logger.info('GoalDetailPage', 'handleBack: pop success')
    } catch (e) {
      Logger.error('GoalDetailPage', 'handleBack failed, msg=' + (e as Error).message)
    }
  }

  /**
   * 物理返回键拦截，补全 onBackPressed 避免物理返回键绕过未保存编辑检测
   * - 编辑弹窗打开时，关闭弹窗而非退出页面
   * - 否则正常返回
   */
  private handleBackPress(): void {
    if (this.showEditDialog) {
      this.showEditDialog = false
      return
    }
    if (this.showAddTaskDialog) {
      this.showAddTaskDialog = false
      return
    }
    this.handleBack()
  }

  // Opt: H2-8 移除假难度星级模块 - 已删除 getDifficultyStars()

  build() {
    NavDestination() {
      // 红线修复：用 Stack 层叠替代 bindContentCover，全屏弹窗禁止使用 bindContentCover
      Stack() {
        Column() {
          // 吸顶标题栏（CommonTitleBar 统一处理返回按钮 + 标题 + 安全区）
          // 返回逻辑使用 handleBackPress（含编辑弹窗拦截）
          CommonTitleBar({
            title: $r('app.string.page_goal_detail'),
            showBack: true,
            onBack: (): void => { this.handleBackPress() },
            // ⚠️ @BuilderParam 的箭头函数内只能「调用 @Builder」，不可内联写 UI 组件
            // （内联 Row/SymbolGlyph 会触发 Rollup 00305015 解析错误，并引发上百条次生报错）
            rightActions: (): void => {
              this.GoalMenuActionBuilder()
            }
          })

          if (this.isLoading) {
          Column({ space: 16 }) {
            this.SkeletonCardBuilder(140, 22)

            this.SkeletonCardBuilder(80, 16)

            this.SkeletonCardBuilder(120, 18)

            this.SkeletonCardBuilder(60, 16)
          }
          .padding({ left: 16, right: 16, top: 16 })
          .layoutWeight(1)
          .animation(MotionConstants.panelParam())
        } else if (this.loadError) {
          StateView({
            mode: StateMode.ERROR,
            errorMessage: $r('app.string.state_error_desc'),
            onRetry: (): void => { this.retryLoadGoal() }
          })
        } else {
          Scroll() {
            Column({ space: 16 }) {
              GoalHeaderSection({
                goal: this.goal,
                taskCount: this.l2Tasks.length,
                // 进度以数值 @Param 显式下发（不依赖对象属性观察链）
                progress: this.goal.progress
              })

              L2TaskListSection({
                l2TaskDataSource: this.l2TaskDataSource,
                taskCount: this.l2Tasks.length,
                goalId: this.goal.id,
                expandedL2TaskId: this.expandedL2TaskId,
                isTaskInTodo: (taskId: string): boolean => {
                  return this.isTaskInTodo(taskId)
                },
                onToggleExpand: (taskId: string): void => {
                  this.handleToggleL2Expand(taskId)
                },
                onAddToHome: (goalId: string, taskId: string): void => {
                  this.handleL2ExtractToHome(goalId, taskId)
                },
                onStepToggle: (goalId: string, taskId: string, stepIndex: number): void => {
                  this.handleStepToggle(goalId, taskId, stepIndex)
                },
                onViewDetail: (taskId: string): void => {
                  this.handleViewTaskDetail(taskId)
                },
                onAddTask: (): void => {
                  this.showAddTaskDialog = true
                }
              })

              Column()
                .height(24)
            }
            .padding({
              left: 16,
              right: 16,
              top: 16,
              bottom: safeAreaHelper.getBottomWith(24)
            })
          }
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
        }
        }
        // 红线修复：Stack 层叠弹窗（替代 bindContentCover）
        if (this.showEditDialog) {
          this.EditGoalCoverBuilder()
        }
        if (this.showAddTaskDialog) {
          this.AddTaskCoverBuilder()
        }
        if (this.showReviewSheet) {
          this.GoalReviewCoverBuilder()
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

        // 目标达成撒花：纯观赏覆盖层（hitTest 透传，不拦截交互），播完 onFinished 自收起。
        // 仅响应 GOAL_COMPLETED（用户本机动作链），云同步落地不触发。
        if (this.showConfetti) {
          ConfettiOverlay({
            show: true,
            onFinished: (): void => {
              this.showConfetti = false
            }
          })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .expandSafeArea([SafeAreaType.KEYBOARD])
      // 页面转场交给系统路由转场独占（本工程保留 Navigation 系统默认转场）；
      // 此处显式 IDENTITY，既清掉原失效的裸 OPACITY，也防止被外层 animateTo 补上默认转场
      .transition(MotionHelper.noTransition())
    }
    .hideTitleBar(true)
    .onBackPressed((): boolean => {
      this.handleBackPress()
      return true
    })
    .onReady((context: NavDestinationContext): void => {
      this.onDestinationReady(context)
    })
    .onShown((): void => {
      this.refreshOnShown()
      Logger.info('GoalDetailPage', 'onShown: data refreshed, goalId=' + this.goal.id)
    })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }


  /**
   * 标题栏右侧「目标菜单」按钮（原浮动在概览卡右上角，与标题错位 → 收进标题栏）
   * 说明：作为 @BuilderParam rightActions 的注入目标，供 CommonTitleBar 调用
   */
  @Builder
  GoalMenuActionBuilder() {
    Row() {
      SymbolGlyph($r('sys.symbol.ellipsis_circle'))
        .fontSize(CommonConstants.FONT_SIZE_SUBTITLE)
        .fontColor([$r('app.color.text_secondary')])
    }
    .width(DimensConstants.TOUCH_COMFORT)
    .height(DimensConstants.TOUCH_COMFORT)
    .borderRadius(22)
    .backgroundColor(Color.Transparent)
    .alignItems(VerticalAlign.Center)
    .justifyContent(FlexAlign.Center)
    .onClick((): void => {
      this.showGoalActionMenu()
    })
  }

  @Builder
  SkeletonCardBuilder(height: number, borderRadius: number): void {
    Column() {
      if (height >= 120) {
        Column({ space: 8 }) {
          Row({ space: 8 }) {
            Column()
              .width(40)
              .height(40)
              .borderRadius(20)
              .backgroundColor($r('app.color.skeleton_base'))
              .opacity(0.5)
              .margin({ left: 12 })
            Column() {
              Column()
                .width('40%')
                .height(14)
                .borderRadius(DimensConstants.RADIUS_XS)
                .backgroundColor($r('app.color.skeleton_base'))
                .opacity(0.5)
              Column()
                .width('30%')
                .height(12)
                .borderRadius(DimensConstants.RADIUS_XS)
                .backgroundColor($r('app.color.skeleton_base'))
                .opacity(0.5)
                .margin({ top: 4 })
            }
            .margin({ left: 12 })
          }
          .width('100%')
          .padding({ top: 12 })

          Column()
            .width('90%')
            .height(12)
            .borderRadius(DimensConstants.RADIUS_XS)
            .backgroundColor($r('app.color.skeleton_base'))
            .opacity(0.5)
            .margin({ left: 12 })

          Column()
            .width('70%')
            .height(12)
            .borderRadius(DimensConstants.RADIUS_XS)
            .backgroundColor($r('app.color.skeleton_base'))
            .opacity(0.5)
            .margin({ left: 12, top: 4 })
        }
        .width('100%')
        .height(height)
      } else if (height >= 80) {
        Column({ space: 6 }) {
          Row({ space: 8 }) {
            Column()
              .width(32)
              .height(32)
              .borderRadius(DimensConstants.RADIUS_L)
              .backgroundColor($r('app.color.skeleton_base'))
              .opacity(0.5)
              .margin({ left: 12 })
            Column() {
              Column()
                .width('50%')
                .height(14)
                .borderRadius(DimensConstants.RADIUS_XS)
                .backgroundColor($r('app.color.skeleton_base'))
                .opacity(0.5)
            }
            .margin({ left: 12 })
          }
          .width('100%')
          .padding({ top: 12 })

          Column()
            .width('80%')
            .height(12)
            .borderRadius(DimensConstants.RADIUS_XS)
            .backgroundColor($r('app.color.skeleton_base'))
            .opacity(0.5)
            .margin({ left: 12, top: 4 })
        }
        .width('100%')
        .height(height)
      } else {
        Row({ space: 8 }) {
          Column()
            .width(28)
            .height(28)
            .borderRadius(DimensConstants.RADIUS_L)
            .backgroundColor($r('app.color.skeleton_base'))
            .opacity(0.5)
            .margin({ left: 12 })
          Column() {
            Column()
              .width('60%')
              .height(12)
              .borderRadius(DimensConstants.RADIUS_XS)
              .backgroundColor($r('app.color.skeleton_base'))
              .opacity(0.5)
          }
          .margin({ left: 12 })
        }
        .width('100%')
        .height(height)
        .alignItems(VerticalAlign.Center)
      }

      Column()
        .width('150%')
        .height('100%')
        .backgroundColor($r('app.color.shimmer_highlight'))
        .translate({ x: this.shimmerOffset })
        .position({ left: 0, top: 0 })
    }
    .width('100%')
    .height(height)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(borderRadius)
    .shadow({ radius: 8, color: $r('app.color.shadow_card'), offsetX: 0, offsetY: 2 })
    .animation({ duration: 800, curve: Curve.EaseInOut })
  }

  @Builder
  EditGoalCoverBuilder() {
    GoalEditPanel({
      goal: this.goal,
      onConfirm: (name: string, description: string, category: string, deadline: number): void => {
        this.confirmEditGoal(name, description, category, deadline)
      },
      onCancel: (): void => {
        this.showEditDialog = false
      }
    })
  }

  @Builder
  AddTaskCoverBuilder() {
    AddTaskPanel({
      onConfirm: (taskName: string, priority: TaskPriority, deadline: number, estimatedTime: number): void => {
        this.confirmAddTask(taskName, priority, deadline, estimatedTime)
      },
      onCancel: (): void => {
        this.showAddTaskDialog = false
      }
    })
  }

  /**
   * B1 复盘报告全屏弹层（Stack 层叠，替代 bindContentCover）
   * - 加载态：Loading + 提示文案
   * - 完成态：可滚动报告文本 + 关闭按钮
   */
  @Builder
  GoalReviewCoverBuilder() {
    AppReportSheet({
    title: getContext(this).resourceManager.getStringSync($r('app.string.dialog_goal_review_title').id),
    loading: this.reviewLoading,
    text: this.reviewText,
    loadingText: getContext(this).resourceManager.getStringSync($r('app.string.review_loading').id),
    onClose: (): void => {
      this.showReviewSheet = false
    }
    })
  }
}
