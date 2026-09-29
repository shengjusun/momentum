// 目标详情页：目标信息卡 + L2 任务卡片列表 + 关联任务 + 编辑面板

import {
  GoalCardItem, TaskPriority, TaskDetailItem, Id,
  GoalDetailRouteNavParam, TaskDetailRouteNavParam, HomeTodoItem,
  AiGeneratedTask, TaskStatus, isStepCompleted
} from '../model/Models'
import { globalNavStack, ROUTE_NAME, globalTabsController, TAB_INDEX } from '../common/RouterManager'
import { Logger } from '../common/utils/Logger'
import { safeAreaHelper } from '../common/utils/SafeAreaHelper'
import { safeStringUtil, safeNumberUtil, formatDeadlineUtil } from '../common/utils/SafeUtils'
import { classifyEisenhowerQuadrant, quadrantLabelUtil, quadrantTextColorUtil, quadrantBgColorUtil } from '../common/utils/PriorityUtils'
import { routeVM } from '../viewmodel/RoutePageViewModel'
import { homeVM } from '../viewmodel/HomeViewModel'
import { DeepSeekService } from '../common/services/DeepSeekService'
import { settingsVM } from '../viewmodel/SettingsViewModel'
import { promptAction } from '@kit.ArkUI'
import { AiTaskDataSource } from '../common/datasource/TaskDataSource'
import { CommonTitleBar } from '../common/components/CommonTitleBar'
import { StateView, StateMode } from '../common/components/StateView'

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
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
            .fontWeight(FontWeight.Regular)
            .fontFamily('HarmonyOS Sans')
        }

        Text(safeStringUtil(this.task.taskName, '').length > 0 ? safeStringUtil(this.task.taskName, '') : $r('app.string.default_unnamed_task'))
          .fontSize(16)
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
            .fontSize(11)
            .fontColor([$r('app.color.text_tertiary')])
          Text(safeNumberUtil(this.task.estimatedTime, 0).toString() + getContext(this).resourceManager.getStringSync($r('app.string.route_estimated_suffix').id))
            .fontSize(13)
            .fontColor($r('app.color.text_tertiary'))
            .fontFamily('HarmonyOS Sans')
        }

        if (Array.isArray(this.task.steps) && this.task.steps.length > 0) {
          Row({ space: 3 }) {
            Text('·')
              .fontSize(10)
              .fontColor($r('app.color.text_tertiary'))
            Text(this.task.steps.length.toString() + '个步骤')
              .fontSize(13)
              .fontColor($r('app.color.text_tertiary'))
              .fontFamily('HarmonyOS Sans')
          }
        }

        Blank()

        Text(quadrantLabelUtil(classifyEisenhowerQuadrant(this.task.priority, this.task.deadline)))
          .fontSize(11)
          .fontColor(quadrantTextColorUtil(classifyEisenhowerQuadrant(this.task.priority, this.task.deadline)))
          .fontWeight(FontWeight.Regular)
          .fontFamily('HarmonyOS Sans')
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .backgroundColor(quadrantBgColorUtil(classifyEisenhowerQuadrant(this.task.priority, this.task.deadline)))
          .borderRadius(4)

        if (!this.isInTodo) {
          Text($r('app.string.route_add_plus'))
            .fontSize(12)
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
                   .fontSize(11)
                   .fontColor($r('app.color.success_color'))
                   .fontWeight(FontWeight.Bold)
                   .fontFamily('HarmonyOS Sans')
                   .width(16)
                  .textAlign(TextAlign.Center)
              } else {
                 Text((stepIdx + 1).toString())
                   .fontSize(11)
                   .fontColor($r('app.color.text_tertiary'))
                   .fontWeight(FontWeight.Medium)
                   .fontFamily('HarmonyOS Sans')
                   .width(16)
                  .textAlign(TextAlign.Center)
              }

              Text(step)
                .fontSize(13)
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
                .fontSize(12)
                .fontColor($r('app.color.primary_color'))
                .fontWeight(FontWeight.Medium)
                .fontFamily('HarmonyOS Sans')
              Text('›')
                .fontSize(12)
                .fontColor($r('app.color.primary_color'))
                .fontWeight(FontWeight.Medium)
                .fontFamily('HarmonyOS Sans')
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
struct GoalHeaderSection {
  @Param goal: GoalCardItem = buildEmptyGoalCard()
  @Param taskCount: number = 0
  @Event onMenuClick: () => void = () => {}

  build() {
    Column({ space: 16 }) {
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          Text(safeStringUtil(this.goal.name, '').length > 0 ? safeStringUtil(this.goal.name, '') : $r('app.string.default_unnamed_goal'))
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .fontFamily('HarmonyOS Sans')
            .layoutWeight(1)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Text('⋮')
            .fontSize(20)
            .fontColor($r('app.color.text_secondary'))
            .fontWeight(FontWeight.Medium)
            .fontFamily('HarmonyOS Sans')
            .width(32)
            .height(32)
            .borderRadius(16)
            .backgroundColor($r('app.color.bg_tag'))
            .textAlign(TextAlign.Center)
            .accessibilityText($r('app.string.dialog_goal_action_title'))
            .onClick((): void => {
              this.onMenuClick()
            })
        }
        .width('100%')

        Row({ space: 8 }) {
          if (safeNumberUtil(this.goal.progress, 0) >= 100) {
            Text($r('app.string.goal_detail_completed'))
              .fontSize(11)
              .fontColor($r('app.color.success_color'))
              .fontWeight(FontWeight.Medium)
              .fontFamily('HarmonyOS Sans')
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .backgroundColor($r('app.color.success_color_bg'))
              .borderRadius(10)
          } else {
            Text($r('app.string.goal_detail_in_progress'))
              .fontSize(11)
              .fontColor($r('app.color.primary_color'))
              .fontWeight(FontWeight.Medium)
              .fontFamily('HarmonyOS Sans')
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .backgroundColor($r('app.color.primary_color_bg'))
              .borderRadius(10)
          }

          Text(safeStringUtil(this.goal.category, '').length > 0 ? safeStringUtil(this.goal.category, '') : $r('app.string.default_other_category'))
            .fontSize(11)
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
            .fontSize(12)
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
              $r('app.color.success_color') : Color.Blue)
            .backgroundColor($r('app.color.bg_progress_track'))
          Text(safeNumberUtil(this.goal.progress, 0).toString() + '%')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontFamily('HarmonyOS Sans')
            .fontColor(safeNumberUtil(this.goal.progress, 0) > 0 ? $r('app.color.text_primary') : $r('app.color.text_tertiary'))
        }
        .width(84)
        .height(84)

        Row({ space: 16 }) {
          Column({ space: 4 }) {
            Text(safeStringUtil(this.goal.duration, '--'))
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .fontFamily('HarmonyOS Sans')
            Text($r('app.string.goal_detail_estimated_time'))
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'))
              .fontFamily('HarmonyOS Sans')
          }
          .alignItems(HorizontalAlign.Center)

          Column({ space: 4 }) {
            Text(formatDeadlineUtil(this.goal.deadline))
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .fontFamily('HarmonyOS Sans')
            Text($r('app.string.goal_detail_deadline_label'))
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'))
              .fontFamily('HarmonyOS Sans')
          }
          .alignItems(HorizontalAlign.Center)

          Column({ space: 4 }) {
            Text(this.taskCount.toString())
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .fontFamily('HarmonyOS Sans')
            Text($r('app.string.goal_detail_task_label'))
              .fontSize(12)
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
struct L2TaskListSection {
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
          .fontSize(16)
          .fontColor([$r('app.color.primary_color')])

        Text(getContext(this).resourceManager.getStringSync($r('app.string.goal_detail_task_label').id) + '（' + this.l2TaskDataSource.totalCount().toString() + '）')
          .fontSize(16).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).fontFamily('HarmonyOS Sans')
          .layoutWeight(1)

        Text($r('app.string.goal_detail_add_task_btn'))
          .fontSize(13)
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
struct GoalEditPanel {
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
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .fontFamily('HarmonyOS Sans')

        Column({ space: 8 }) {
          Text($r('app.string.goal_detail_goal_name'))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .fontFamily('HarmonyOS Sans')
            .width('100%')
          TextInput({ text: this.editName, placeholder: $r('app.string.goal_detail_goal_name_hint') })
            .fontSize(14)
            .height(40)
            .backgroundColor($r('app.color.bg_tag'))
            .borderRadius(8)
            .padding({ left: 12, right: 12 })
            .onChange((value: string): void => { this.editName = value })
        }
        .width('100%')

        Column({ space: 8 }) {
          Text($r('app.string.goal_detail_description'))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .fontFamily('HarmonyOS Sans')
            .width('100%')
          TextArea({ text: this.editDescription, placeholder: $r('app.string.goal_detail_description_hint') })
            .fontSize(14)
            .height(80)
            .backgroundColor($r('app.color.bg_tag'))
            .borderRadius(8)
            .padding(12)
            .onChange((value: string): void => { this.editDescription = value })
        }
        .width('100%')

        Column({ space: 8 }) {
          Text($r('app.string.goal_detail_category'))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .fontFamily('HarmonyOS Sans')
            .width('100%')
          TextInput({ text: this.editCategory, placeholder: $r('app.string.goal_detail_category_hint') })
            .fontSize(14)
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
struct AddTaskPanel {
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
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .fontFamily('HarmonyOS Sans')

        Column({ space: 8 }) {
          Text($r('app.string.goal_detail_add_task_name_label'))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .fontFamily('HarmonyOS Sans')
            .width('100%')
          TextInput({ text: this.editName, placeholder: $r('app.string.goal_detail_add_task_name_hint') })
            .fontSize(14)
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
  @Local stepVersion: number = 0
  @Local pressedL2AddTaskId: string = ''
  private pressedL2Timer: number = -1
  @Local isLoading: boolean = true
  /** 错误态：路由参数缺失或目标不存在 */
  @Local loadError: boolean = false
  @Local skeletonOpacity: number = 0.5
  private isAttached: boolean = false
  /** B1 复盘：弹层显示/加载中/报告文本 */
  @Local showReviewSheet: boolean = false
  @Local reviewLoading: boolean = false
  @Local reviewText: string = ''

  aboutToAppear(): void {
    this.isAttached = true
    this.startSkeletonShimmer()
  }

  aboutToDisappear(): void {
    this.isAttached = false
    if (this.pressedL2Timer !== -1) clearTimeout(this.pressedL2Timer)
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
   *     → 更新 L3 completedSteps
   *     → 自动维护 L2.status (COMPLETED/IN_PROGRESS)
   *     → 调用 homeVM.syncRelatedTaskCompletion 同步 L4.isCompleted
   *     → 调用 updateGoalProgressByTasks 重算 L1.progress
   *
   * 同步刷新本页 UI：
   *   - l2Tasks / l2TaskDataSource: L2 任务状态变化
   *   - stepVersion: 触发 ForEach 重渲染步骤勾选状态
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
      this.stepVersion += 1
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
    promptAction.showActionMenu({
      title: $r('app.string.dialog_goal_action_title'),
      buttons: [
        { text: $r('app.string.dialog_edit_goal'), color: $r('app.color.text_primary') },
        { text: $r('app.string.dialog_goal_review'), color: $r('app.color.text_primary') },
        { text: $r('app.string.dialog_delete_goal'), color: $r('app.color.error_color') }
      ]
    }).then((result: promptAction.ActionMenuSuccessResponse): void => {
      if (!this.isAttached) return
      if (result.index === 0) {
        this.handleEditGoal()
      } else if (result.index === 1) {
        this.handleGoalReview()
      } else if (result.index === 2) {
        this.handleDeleteGoal()
      }
    }).catch((e: Error): void => {
      Logger.error('GoalDetailPage', 'showGoalActionMenu failed: ' + e.message)
    })
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
      this.reviewText = report
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

  private confirmEditGoal(editName: string, editDescription: string, editCategory: string): void {
    const success: boolean = routeVM.updateGoal(this.goal.id, editName,
      editDescription, editCategory)
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
  private confirmAddTask(taskName: string): void {
    if (!this.goal.id || this.goal.id.length === 0) {
      Logger.warn('GoalDetailPage', 'confirmAddTask: goalId empty')
      return
    }
    const newId: string = 'task_manual_' + Date.now().toString()
    const task: AiGeneratedTask = new AiGeneratedTask(newId, taskName, 0, TaskPriority.MEDIUM, [], TaskStatus.PENDING)
    routeVM.addTaskToGoal(this.goal.id, task)
    // 刷新本地状态 + dataSource 触发响应式刷新
    this.l2Tasks = this.findLatestL2Tasks(this.goal.id)
    this.l2TaskDataSource.updateAll(this.l2Tasks)
    this.goal = this.findLatestGoal(this.goal.id, this.goal)
    this.showAddTaskDialog = false
    promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_task_added').id), duration: 1500 })
    Logger.info('GoalDetailPage', 'confirmAddTask: added id=' + newId + ' name=' + taskName)
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

  private handleViewTaskDetail(l2TaskId: string): void {
    if (!l2TaskId || l2TaskId.length === 0) {
      Logger.warn('GoalDetailPage', 'handleViewTaskDetail: l2TaskId is empty')
      return
    }
    const freshTask: HomeTodoItem | undefined = homeVM.taskList.find(
      (t: HomeTodoItem): boolean => t.relatedTaskId === l2TaskId
    )
    if (!freshTask) {
      Logger.warn('GoalDetailPage', 'handleViewTaskDetail: L4 task not found for l2TaskId=' + l2TaskId)
      promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.goal_detail_task_not_found').id), duration: 1500 })
      return
    }
    const detailItem: TaskDetailItem = new TaskDetailItem(
      freshTask.id,
      freshTask.title,
      getContext(this).resourceManager.getStringSync($r('app.string.goal_detail_from_goal_prefix').id) + (safeStringUtil(this.goal.name, '').length > 0 ? safeStringUtil(this.goal.name, '') : getContext(this).resourceManager.getStringSync($r('app.string.default_unnamed_goal').id)) + getContext(this).resourceManager.getStringSync($r('app.string.goal_detail_from_goal_suffix').id),
      freshTask.duration,
      freshTask.priority,
      freshTask.isCompleted,
      freshTask.createTime
    )
    try {
      const param: TaskDetailRouteNavParam = {
        id: detailItem.id,
        task: detailItem,
        goalId: safeStringUtil(freshTask.relatedGoalId, ''),
        relatedTaskId: safeStringUtil(freshTask.relatedTaskId, '')
      }
      globalNavStack.pushPath({ name: ROUTE_NAME.TASK_DETAIL, param: param })
      Logger.info('GoalDetailPage', 'handleViewTaskDetail: navigated, l2TaskId=' + l2TaskId +
        ', relatedTaskId=' + param.relatedTaskId)
    } catch (e) {
      const err: Error = e as Error
      Logger.error('GoalDetailPage', 'handleViewTaskDetail failed, msg=' + err.message)
      promptAction.showToast({
        message: getContext(this).resourceManager.getStringSync($r('app.string.toast_update_failed_retry').id),
        duration: 1500
      })
    }
  }

  private onDestinationReady(context: NavDestinationContext): void {
    if (!settingsVM.userProfile.isLoggedIn) {
      Logger.warn('GoalDetailPage', 'onDestinationReady: not logged in, redirect to LoginPage')
      globalNavStack.replacePath(new NavPathInfo(ROUTE_NAME.LOGIN, null))
      return
    }

    this.isLoading = true

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

    setTimeout((): void => {
      this.isLoading = false
    }, 300)
  }

  private findLatestGoal(goalId: string, fallback: GoalCardItem): GoalCardItem {
    for (let i: number = 0; i < routeVM.goals.length; i++) {
      const g: GoalCardItem = routeVM.goals[i]
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
    for (let i: number = 0; i < routeVM.goals.length; i++) {
      const g: GoalCardItem = routeVM.goals[i]
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
            onBack: (): void => { this.handleBackPress() }
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
          .animation({ duration: 300, curve: Curve.EaseOut })
        } else if (this.loadError) {
          StateView({
            mode: StateMode.ERROR,
            errorMessage: $r('app.string.state_error_desc'),
            onRetry: (): void => { this.handleBackPress() }
          })
        } else {
          Scroll() {
            Column({ space: 16 }) {
              GoalHeaderSection({
                goal: this.goal,
                taskCount: this.l2Tasks.length,
                onMenuClick: (): void => { this.showGoalActionMenu() }
              })

              L2TaskListSection({
                l2TaskDataSource: this.l2TaskDataSource,
                goalId: this.goal.id,
                expandedL2TaskId: this.expandedL2TaskId,
                stepVersion: this.stepVersion,
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
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .expandSafeArea([SafeAreaType.KEYBOARD])
      .transition(TransitionEffect.OPACITY)
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
                .borderRadius(4)
                .backgroundColor($r('app.color.skeleton_base'))
                .opacity(0.5)
              Column()
                .width('30%')
                .height(12)
                .borderRadius(4)
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
            .borderRadius(4)
            .backgroundColor($r('app.color.skeleton_base'))
            .opacity(0.5)
            .margin({ left: 12 })

          Column()
            .width('70%')
            .height(12)
            .borderRadius(4)
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
              .borderRadius(16)
              .backgroundColor($r('app.color.skeleton_base'))
              .opacity(0.5)
              .margin({ left: 12 })
            Column() {
              Column()
                .width('50%')
                .height(14)
                .borderRadius(4)
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
            .borderRadius(4)
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
            .borderRadius(14)
            .backgroundColor($r('app.color.skeleton_base'))
            .opacity(0.5)
            .margin({ left: 12 })
          Column() {
            Column()
              .width('60%')
              .height(12)
              .borderRadius(4)
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
      onConfirm: (name: string, description: string, category: string): void => {
        this.confirmEditGoal(name, description, category)
      },
      onCancel: (): void => {
        this.showEditDialog = false
      }
    })
  }

  @Builder
  AddTaskCoverBuilder() {
    AddTaskPanel({
      onConfirm: (taskName: string): void => {
        this.confirmAddTask(taskName)
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
    Column() {
      Column() {
        Row() {
          Text($r('app.string.dialog_goal_review_title'))
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .fontFamily('HarmonyOS Sans')
            .layoutWeight(1)
          Button($r('app.string.common_close'))
            .type(ButtonType.Capsule)
            .height(32)
            .padding({ left: 16, right: 16 })
            .backgroundColor($r('app.color.bg_tag'))
            .fontColor($r('app.color.text_secondary'))
            .fontSize(13)
            .onClick((): void => { this.showReviewSheet = false })
        }
        .width('100%')

        if (this.reviewLoading) {
          Column({ space: 12 }) {
            LoadingProgress()
              .width(40)
              .height(40)
              .color($r('app.color.primary_color'))
            Text($r('app.string.review_loading'))
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .fontFamily('HarmonyOS Sans')
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .margin({ top: 80 })
          .layoutWeight(1)
        } else {
          Scroll() {
            Text(this.reviewText)
              .fontSize(14)
              .fontColor($r('app.color.text_primary'))
              .fontFamily('HarmonyOS Sans')
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
