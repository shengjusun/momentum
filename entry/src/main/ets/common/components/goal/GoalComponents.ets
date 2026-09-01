/**
 * @file 目标详情页拆分出的子组件
 * @description
 *   从 GoalDetailPage.ets 拆分而来。包含：L2 任务卡片、目标头部卡、L2 任务列表区、
 *   编辑目标面板、添加任务面板，以及 @Param 默认值所需的空工厂函数。
 *   全部为展示组件：@Param 只读入参 + @Event 向上回调，业务逻辑仍由根页面持有。
 */
import { AiGeneratedTask, GoalCardItem, TaskPriority, TaskStatus, isStepCompleted } from '../../../model/Models'
import { CommonConstants } from '../../constants/CommonConstants'
import { DimensConstants } from '../../constants/DimensConstants'
import { priorityLabelUtil, priorityBgColorUtil, priorityTextColorUtil, priorityStatusColorUtil, quadrantLabelUtil, quadrantTextColorUtil, quadrantBgColorUtil, classifyEisenhowerQuadrant } from '../../utils/PriorityUtils'
import { safeStringUtil, safeNumberUtil, formatDeadlineUtil } from '../../utils/SafeUtils'
import { Logger } from '../../utils/Logger'
import { AiTaskDataSource } from '../../datasource/TaskDataSource'
import { promptAction } from '@kit.ArkUI'

/**
 * 空 GoalCardItem 工厂（杜绝 {...} as GoalCardItem）
 * 用于 @Local goal 初始值 + onDestinationReady 兜底赋值
 * 4 级架构必填 tasks 字段（允许空数组）
 */
export function buildEmptyGoalCard(): GoalCardItem {
  return new GoalCardItem('', '', '', '', 0, '', 0, 0, 0, [], [])
}

/** 空 AiGeneratedTask 工厂（@Param 默认值） */
export function buildEmptyAiGeneratedTask(): AiGeneratedTask {
  return new AiGeneratedTask('', '', 0, TaskPriority.MEDIUM, [], TaskStatus.PENDING, [])
}


/* ============================================================
 * 2. L2TaskCardItem — L2任务卡片条目 (@ReusableV2)
 *    原始：L2TaskCardBuilder (L418-537)
 * ============================================================ */

@ReusableV2
@ComponentV2
export struct L2TaskCardItem {
  @Param goalId: string = ''
  @Param task: AiGeneratedTask = buildEmptyAiGeneratedTask()
  @Param taskIndex: number = 0
  @Param isExpanded: boolean = false
  @Param stepVersion: number = 0
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
          Text('✓')
            .fontSize(CommonConstants.FONT_SIZE_XS)
            .fontColor($r('app.color.text_secondary'))
            .fontWeight(FontWeight.Regular)
            .fontFamily('HarmonyOS Sans')
        }

        Text(safeStringUtil(this.task.taskName, '').length > 0 ? safeStringUtil(this.task.taskName, '') : $r('app.string.default_unnamed_task'))
          .fontSize(CommonConstants.FONT_SIZE_SUBTITLE)
          .fontColor($r('app.color.text_primary'))
          .fontWeight(FontWeight.Medium)
          .fontFamily('HarmonyOS Sans')
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
            .fontSize(CommonConstants.FONT_SIZE_XS)
            .fontColor([$r('app.color.text_tertiary')])
          Text(safeNumberUtil(this.task.estimatedTime, 0).toString() + getContext(this).resourceManager.getStringSync($r('app.string.route_estimated_suffix').id))
            .fontSize(CommonConstants.FONT_SIZE_CAPTION)
            .fontColor($r('app.color.text_tertiary'))
            .fontFamily('HarmonyOS Sans')
        }

        if (Array.isArray(this.task.steps) && this.task.steps.length > 0) {
          Row({ space: 3 }) {
            Text('·')
              .fontSize(CommonConstants.FONT_SIZE_XXS)
              .fontColor($r('app.color.text_tertiary'))
            Text(this.task.steps.length.toString() + '个步骤')
              .fontSize(CommonConstants.FONT_SIZE_CAPTION)
              .fontColor($r('app.color.text_tertiary'))
              .fontFamily('HarmonyOS Sans')
          }
        }

        Blank()

        Text(quadrantLabelUtil(classifyEisenhowerQuadrant(this.task.priority, this.task.deadline)))
          .fontSize(CommonConstants.FONT_SIZE_XS)
          .fontColor(quadrantTextColorUtil(classifyEisenhowerQuadrant(this.task.priority, this.task.deadline)))
          .fontWeight(FontWeight.Regular)
          .fontFamily('HarmonyOS Sans')
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .backgroundColor(quadrantBgColorUtil(classifyEisenhowerQuadrant(this.task.priority, this.task.deadline)))
          .borderRadius(4)

        if (!this.isInTodo) {
          Text($r('app.string.route_add_plus'))
            .fontSize(CommonConstants.FONT_SIZE_SMALL)
            .fontColor($r('app.color.primary_color'))
            .fontWeight(FontWeight.Medium)
            .fontFamily('HarmonyOS Sans')
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .backgroundColor($r('app.color.primary_color_bg'))
            .borderRadius(10)
            .scale({ x: this.addBtnPressed ? 0.95 : 1, y: this.addBtnPressed ? 0.95 : 1 })
            .animation({ duration: 100, curve: Curve.EaseOut })
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
          ForEach(this.task.steps, (step: string, stepIdx: number): void => {
            Row({ space: 8 }) {
              if (isStepCompleted(this.task, stepIdx)) {
                 Text('✓')
                   .fontSize(CommonConstants.FONT_SIZE_XS)
                   .fontColor($r('app.color.success_color'))
                   .fontWeight(FontWeight.Bold)
                   .fontFamily('HarmonyOS Sans')
                   .width(16)
                  .textAlign(TextAlign.Center)
              } else {
                 Text((stepIdx + 1).toString())
                   .fontSize(CommonConstants.FONT_SIZE_XS)
                   .fontColor($r('app.color.text_tertiary'))
                   .fontWeight(FontWeight.Medium)
                   .fontFamily('HarmonyOS Sans')
                   .width(16)
                  .textAlign(TextAlign.Center)
              }

              Text(step)
                .fontSize(CommonConstants.FONT_SIZE_CAPTION)
                .fontColor(isStepCompleted(this.task, stepIdx) ?
                  $r('app.color.text_tertiary') : $r('app.color.text_secondary'))
                .fontFamily('HarmonyOS Sans')
                .decoration(isStepCompleted(this.task, stepIdx) ?
                  { type: TextDecorationType.LineThrough } : { type: TextDecorationType.None })
                .layoutWeight(1)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .padding({ top: 6, bottom: 6 })
            .onClick((): void => {
              this.onStepToggle(this.goalId, this.task.id, stepIdx)
            })
          }, (step: string, stepIdx: number): string => 'l3step_' + stepIdx.toString() + '_v' + this.stepVersion.toString())

          if (this.isInTodo) {
            Row() {
              Text($r('app.string.goal_detail_view_task_detail'))
                .fontSize(CommonConstants.FONT_SIZE_SMALL)
                .fontColor($r('app.color.primary_color'))
                .fontWeight(FontWeight.Medium)
                .fontFamily('HarmonyOS Sans')
              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(CommonConstants.FONT_SIZE_SMALL)
                .fontColor([$r('app.color.primary_color')])
                .margin({ left: 2 })
            }
            .padding({ top: 8, bottom: 2 })
            .onClick((): void => {
              this.onViewDetail(this.task.id)
            })
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 10 })
        .backgroundColor($r('app.color.bg_page'))
        .borderRadius(10)
        .margin({ left: 16, right: 16, bottom: 4 })
        .animation({ duration: 250, curve: Curve.EaseOut })
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
export struct GoalHeaderSection {
  @Param goal: GoalCardItem = buildEmptyGoalCard()
  @Param taskCount: number = 0
  @Event onMenuClick: () => void = () => {}

  build() {
    Column({ space: 16 }) {
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          Text(safeStringUtil(this.goal.name, '').length > 0 ? safeStringUtil(this.goal.name, '') : $r('app.string.default_unnamed_goal'))
            .fontSize(CommonConstants.FONT_SIZE_HEADLINE)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .fontFamily('HarmonyOS Sans')
            .layoutWeight(1)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          SymbolGlyph($r('sys.symbol.ellipsis_circle'))
            .fontSize(CommonConstants.FONT_SIZE_LARGE)
            .fontColor([$r('app.color.text_secondary')])
            .width(32)
            .height(32)
            .borderRadius(16)
            .backgroundColor($r('app.color.bg_tag'))
            .accessibilityText($r('app.string.dialog_goal_action_title'))
            .onClick((): void => {
              this.onMenuClick()
            })
        }
        .width('100%')

        Row({ space: 8 }) {
          if (safeNumberUtil(this.goal.progress, 0) >= 100) {
            Text($r('app.string.goal_detail_completed'))
              .fontSize(CommonConstants.FONT_SIZE_XS)
              .fontColor($r('app.color.success_color'))
              .fontWeight(FontWeight.Medium)
              .fontFamily('HarmonyOS Sans')
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .backgroundColor($r('app.color.success_color_bg'))
              .borderRadius(10)
          } else {
            Text($r('app.string.goal_detail_in_progress'))
              .fontSize(CommonConstants.FONT_SIZE_XS)
              .fontColor($r('app.color.primary_color'))
              .fontWeight(FontWeight.Medium)
              .fontFamily('HarmonyOS Sans')
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .backgroundColor($r('app.color.primary_color_bg'))
              .borderRadius(10)
          }

          Text(safeStringUtil(this.goal.category, '').length > 0 ? safeStringUtil(this.goal.category, '') : $r('app.string.default_other_category'))
            .fontSize(CommonConstants.FONT_SIZE_XS)
            .fontColor($r('app.color.text_secondary'))
            .fontFamily('HarmonyOS Sans')
            .backgroundColor($r('app.color.bg_tag'))
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .borderRadius(10)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (safeStringUtil(this.goal.description, '').length > 0) {
          Text(safeStringUtil(this.goal.description, ''))
            .fontSize(CommonConstants.FONT_SIZE_SMALL)
            .fontColor($r('app.color.text_tertiary'))
            .fontFamily('HarmonyOS Sans')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
      }
      .width('100%')

      Row({ space: 20 }) {
        Stack({ alignContent: Alignment.Center }) {
          Progress({ value: safeNumberUtil(this.goal.progress, 0), total: 100, type: ProgressType.Ring })
            .width(84)
            .height(84)
            .style({ strokeWidth: 8 })
            .color(safeNumberUtil(this.goal.progress, 0) >= 100 ?
              $r('app.color.success_color') : $r('app.color.primary_color'))
            .backgroundColor($r('app.color.bg_progress_track'))
          Text(safeNumberUtil(this.goal.progress, 0).toString() + '%')
            .fontSize(CommonConstants.FONT_SIZE_XL)
            .fontWeight(FontWeight.Bold)
            .fontFamily('HarmonyOS Sans')
            .fontColor(safeNumberUtil(this.goal.progress, 0) > 0 ? $r('app.color.text_primary') : $r('app.color.text_tertiary'))
        }
        .width(84)
        .height(84)

        Row({ space: 16 }) {
          Column({ space: 4 }) {
            Text(safeStringUtil(this.goal.duration, '--'))
              .fontSize(CommonConstants.FONT_SIZE_HEADLINE)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .fontFamily('HarmonyOS Sans')
            Text($r('app.string.goal_detail_estimated_time'))
              .fontSize(CommonConstants.FONT_SIZE_SMALL)
              .fontColor($r('app.color.text_tertiary'))
              .fontFamily('HarmonyOS Sans')
          }
          .alignItems(HorizontalAlign.Center)

          Column({ space: 4 }) {
            Text(formatDeadlineUtil(this.goal.deadline))
              .fontSize(CommonConstants.FONT_SIZE_MID)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .fontFamily('HarmonyOS Sans')
            Text($r('app.string.goal_detail_deadline_label'))
              .fontSize(CommonConstants.FONT_SIZE_SMALL)
              .fontColor($r('app.color.text_tertiary'))
              .fontFamily('HarmonyOS Sans')
          }
          .alignItems(HorizontalAlign.Center)

          Column({ space: 4 }) {
            Text(this.taskCount.toString())
              .fontSize(CommonConstants.FONT_SIZE_HEADLINE)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .fontFamily('HarmonyOS Sans')
            Text($r('app.string.goal_detail_task_label'))
              .fontSize(CommonConstants.FONT_SIZE_SMALL)
              .fontColor($r('app.color.text_tertiary'))
              .fontFamily('HarmonyOS Sans')
          }
          .alignItems(HorizontalAlign.Center)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(20)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(16)
    .shadow({ radius: 16, color: $r('app.color.shadow_card'), offsetX: 0, offsetY: 6 })
  }
}

/* ============================================================
 * 6. L2TaskListSection — L2任务拆解卡片列表区 (@ComponentV2)
 *    原始：build() L1185-1206
 * ============================================================ */

@ComponentV2
export struct L2TaskListSection {
  @Param l2TaskDataSource: AiTaskDataSource = new AiTaskDataSource()
  @Param goalId: string = ''
  @Param expandedL2TaskId: string = ''
  @Param stepVersion: number = 0
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
          .fontSize(CommonConstants.FONT_SIZE_SUBTITLE)
          .fontColor([$r('app.color.primary_color')])

        Text(getContext(this).resourceManager.getStringSync($r('app.string.goal_detail_task_label').id) + '（' + this.l2TaskDataSource.totalCount().toString() + '）')
          .fontSize(CommonConstants.FONT_SIZE_SUBTITLE).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).fontFamily('HarmonyOS Sans')
          .layoutWeight(1)

        Text($r('app.string.goal_detail_add_task_btn'))
          .fontSize(CommonConstants.FONT_SIZE_CAPTION)
          .fontColor($r('app.color.primary_color'))
          .fontWeight(FontWeight.Regular)
          .fontFamily('HarmonyOS Sans')
          .onClick((): void => { this.onAddTask() })
      }
      .width('100%')
      .padding({ left: 4, bottom: 4 })

      if (this.l2TaskDataSource.totalCount() === 0) {
        Column({ space: 12 }) {
          Text($r('app.string.goal_detail_no_l2_task'))
            .fontSize(CommonConstants.FONT_SIZE_SMALL)
            .fontColor($r('app.color.text_tertiary'))
            .textAlign(TextAlign.Center)

          Button($r('app.string.goal_detail_add_task_btn'))
            .type(ButtonType.Capsule)
            .height(36)
            .padding({ left: 18, right: 18 })
            .backgroundColor($r('app.color.primary_color'))
            .fontColor($r('app.color.text_inverse'))
            .fontSize(CommonConstants.FONT_SIZE_BODY)
            .fontWeight(FontWeight.Medium)
            .shadow({ radius: 6, color: $r('app.color.shadow_card'), offsetX: 0, offsetY: 2 })
            .onClick((): void => { this.onAddTask() })
        }
        .width('100%')
        .padding(24)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor($r('app.color.bg_card'))
        .borderRadius(16)
        .shadow({ radius: 4, color: $r('app.color.shadow_card'), offsetX: 0, offsetY: 1 })
      } else {
        Column() {
          LazyForEach(this.l2TaskDataSource, (task: AiGeneratedTask, idx: number): void => {
            L2TaskCardItem({
              goalId: this.goalId,
              task: task,
              taskIndex: idx,
              isExpanded: this.expandedL2TaskId === task.id,
              stepVersion: this.stepVersion,
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
        .borderRadius(16)
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
export struct GoalEditPanel {
  @Param goal: GoalCardItem = buildEmptyGoalCard()
  @Event onConfirm: (name: string, description: string, category: string) => void = () => {}
  @Event onCancel: () => void = () => {}

  @Local editName: string = ''
  @Local editDescription: string = ''
  @Local editCategory: string = ''

  aboutToAppear(): void {
    this.editName = safeStringUtil(this.goal.name, '')
    this.editDescription = safeStringUtil(this.goal.description, '')
    this.editCategory = safeStringUtil(this.goal.category, '')
  }

  private handleConfirm(): void {
    const trimmedName: string = this.editName.trim()
    if (trimmedName.length === 0) {
      promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.goal_detail_goal_name_empty').id), duration: 1500 })
      return
    }
    this.onConfirm(trimmedName, this.editDescription.trim(), this.editCategory.trim())
  }

  build() {
    Column() {
      Column({ space: 16 }) {
        Text($r('app.string.goal_detail_edit_goal'))
          .fontSize(CommonConstants.FONT_SIZE_SUBTITLE)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .fontFamily('HarmonyOS Sans')

        Column({ space: 8 }) {
          Text($r('app.string.goal_detail_goal_name'))
            .fontSize(CommonConstants.FONT_SIZE_SMALL)
            .fontColor($r('app.color.text_secondary'))
            .fontFamily('HarmonyOS Sans')
            .width('100%')
          TextInput({ text: this.editName, placeholder: $r('app.string.goal_detail_goal_name_hint') })
            .fontSize(CommonConstants.FONT_SIZE_BODY)
            .height(40)
            .backgroundColor($r('app.color.bg_tag'))
            .borderRadius(8)
            .padding({ left: 12, right: 12 })
            .onChange((value: string): void => { this.editName = value })
        }
        .width('100%')

        Column({ space: 8 }) {
          Text($r('app.string.goal_detail_description'))
            .fontSize(CommonConstants.FONT_SIZE_SMALL)
            .fontColor($r('app.color.text_secondary'))
            .fontFamily('HarmonyOS Sans')
            .width('100%')
          TextArea({ text: this.editDescription, placeholder: $r('app.string.goal_detail_description_hint') })
            .fontSize(CommonConstants.FONT_SIZE_BODY)
            .height(80)
            .backgroundColor($r('app.color.bg_tag'))
            .borderRadius(8)
            .padding(12)
            .onChange((value: string): void => { this.editDescription = value })
        }
        .width('100%')

        Column({ space: 8 }) {
          Text($r('app.string.goal_detail_category'))
            .fontSize(CommonConstants.FONT_SIZE_SMALL)
            .fontColor($r('app.color.text_secondary'))
            .fontFamily('HarmonyOS Sans')
            .width('100%')
          TextInput({ text: this.editCategory, placeholder: $r('app.string.goal_detail_category_hint') })
            .fontSize(CommonConstants.FONT_SIZE_BODY)
            .height(40)
            .backgroundColor($r('app.color.bg_tag'))
            .borderRadius(8)
            .padding({ left: 12, right: 12 })
            .onChange((value: string): void => { this.editCategory = value })
        }
        .width('100%')

        Row({ space: 12 }) {
          Button($r('app.string.common_cancel'))
            .type(ButtonType.Capsule)
            .height(40)
            .layoutWeight(1)
            .backgroundColor($r('app.color.bg_tag'))
            .fontColor($r('app.color.text_secondary'))
            .fontSize(CommonConstants.FONT_SIZE_BODY)
            .onClick((): void => { this.onCancel() })

          Button($r('app.string.btn_save'))
            .type(ButtonType.Capsule)
            .height(40)
            .layoutWeight(1)
            .backgroundColor($r('app.color.primary_color'))
            .fontColor($r('app.color.text_inverse'))
            .fontSize(CommonConstants.FONT_SIZE_BODY)
            .fontWeight(FontWeight.Medium)
            .onClick((): void => { this.handleConfirm() })
        }
        .width('100%')
      }
      .width('85%')
      .constraintSize({ maxWidth: DimensConstants.SHEET_MAX_WIDTH })
      .padding(20)
      .backgroundColor($r('app.color.bg_card'))
      .borderRadius(16)
      .shadow({ radius: 20, color: $r('app.color.shadow_dialog_overlay'), offsetX: 0, offsetY: 4 }) // Opt: H3-3 硬编码颜色替换为资源引用
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('app.color.overlay_mask')) // Opt: H3-3 硬编码颜色替换为资源引用
    .onClick((): void => { this.onCancel() })
  }
}

/* ============================================================
 * 8.3 AddTaskPanel — 手动添加任务弹窗 (@ComponentV2)
 * ============================================================ */

@ComponentV2
export struct AddTaskPanel {
  @Event onConfirm: (taskName: string) => void = () => {}
  @Event onCancel: () => void = () => {}

  @Local editName: string = ''

  private handleConfirm(): void {
    const trimmedName: string = this.editName.trim()
    if (trimmedName.length === 0) {
      promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_input_empty').id), duration: 1500 })
      return
    }
    this.onConfirm(trimmedName)
  }

  build() {
    Column() {
      Column({ space: 16 }) {
        Text($r('app.string.goal_detail_add_task_title'))
          .fontSize(CommonConstants.FONT_SIZE_SUBTITLE)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .fontFamily('HarmonyOS Sans')

        Column({ space: 8 }) {
          Text($r('app.string.goal_detail_add_task_name_label'))
            .fontSize(CommonConstants.FONT_SIZE_SMALL)
            .fontColor($r('app.color.text_secondary'))
            .fontFamily('HarmonyOS Sans')
            .width('100%')
          TextInput({ text: this.editName, placeholder: $r('app.string.goal_detail_add_task_name_hint') })
            .fontSize(CommonConstants.FONT_SIZE_BODY)
            .height(40)
            .backgroundColor($r('app.color.bg_tag'))
            .borderRadius(8)
            .padding({ left: 12, right: 12 })
            .onChange((value: string): void => { this.editName = value })
        }
        .width('100%')

        Row({ space: 12 }) {
          Button($r('app.string.common_cancel'))
            .type(ButtonType.Capsule)
            .height(40)
            .layoutWeight(1)
            .backgroundColor($r('app.color.bg_tag'))
            .fontColor($r('app.color.text_secondary'))
            .fontSize(CommonConstants.FONT_SIZE_BODY)
            .onClick((): void => { this.onCancel() })

          Button($r('app.string.btn_save'))
            .type(ButtonType.Capsule)
            .height(40)
            .layoutWeight(1)
            .backgroundColor($r('app.color.primary_color'))
            .fontColor($r('app.color.text_inverse'))
            .fontSize(CommonConstants.FONT_SIZE_BODY)
            .fontWeight(FontWeight.Medium)
            .onClick((): void => { this.handleConfirm() })
        }
        .width('100%')
      }
      .width('85%')
      .constraintSize({ maxWidth: DimensConstants.SHEET_MAX_WIDTH })
      .padding(20)
      .backgroundColor($r('app.color.bg_card'))
      .borderRadius(16)
      .shadow({ radius: 20, color: $r('app.color.shadow_dialog_overlay'), offsetX: 0, offsetY: 4 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('app.color.overlay_mask'))
    .onClick((): void => { this.onCancel() })
  }
}

