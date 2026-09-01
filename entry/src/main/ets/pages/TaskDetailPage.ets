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
import { safeStringUtil } from '../common/utils/SafeUtils'
import { priorityLabelUtil, priorityStatusColorUtil, priorityBgColorUtil, priorityTextColorUtil } from '../common/utils/PriorityUtils'
import { routeVM } from '../viewmodel/RoutePageViewModel'
import { homeVM } from '../viewmodel/HomeViewModel'
import { globalNavStack, ROUTE_NAME } from '../common/RouterManager'
import { settingsVM } from '../viewmodel/SettingsViewModel'
import { CommonTitleBar } from '../common/components/CommonTitleBar'
import { StateView, StateMode } from '../common/components/StateView'
import { PomodoroTimerCard } from '../common/components/PomodoroTimerCard'
import { PomodoroImmersiveScreen } from '../common/components/PomodoroImmersiveScreen'
import { pomodoroService } from '../common/services/PomodoroService'
import { safeAreaHelper } from '../common/utils/SafeAreaHelper'

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
  /**
   * 步骤状态版本号（用于触发 UI 重新渲染）
   * - 当 L2 任务的 completedSteps 变更时，routeVM 整体替换 task
   * - 此处用 stepVersion 自增触发 @Local 重新计算
   * - 这是绕过 ArkUI 嵌套数组代理限制的常用技巧
   */
  @Local stepVersion: number = 0
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

  aboutToAppear(): void {
    this.isAttached = true
    // 注册沉浸屏可见性变化回调（Stack 层叠方案，替代 bindContentCover）
    pomodoroService.onImmersiveVisibleChange((visible: boolean): void => {
      this.isPomodoroImmersiveVisible = visible
    })
    // 注意：不在此处恢复沉浸屏可见性。此时 task 尚未从路由参数加载，
    // 无条件继承 Service 全局可见标志会导致"打开任意任务详情都被残留的全屏番茄钟覆盖"。
    // 恢复逻辑移至 onDestinationReady，并校验进行中的会话属于本任务。
  }

  aboutToDisappear(): void {
    this.isAttached = false
    // 页面退出时同步关闭沉浸屏：否则 Service 的可见标志残留，
    // 下次打开任意任务详情会在第一帧被全屏番茄钟覆盖（bug："点任务跳到番茄钟"根因）
    if (pomodoroService.isImmersiveVisible()) {
      pomodoroService.hideImmersive()
    }
    // 清除沉浸屏回调（避免调用已销毁组件）
    pomodoroService.clearImmersiveCallback()
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
      this.stepVersion += 1
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
   * - 数据源：l2Task.steps（字符串数组）
   * - 完成态：isStepCompleted(l2Task, index)（读自 l2Task.completedSteps）
   * - 勾选：toggleStep(index) → 走 routeVM.updateStep() 回写流
   *
   * @param stepText - 步骤文本（来自 l2Task.steps[index]）
   * @param index - 步骤下标
   * @param isCompleted - 当前完成状态（由调用方预算后传入，避免 @Builder 内调方法）
   */
  @Builder
  StepItemBuilder(stepText: string, index: number, isCompleted: boolean): void {
    Row({ space: 10 }) {
      // Checkbox 视觉 18，外包 44 热区容器（触控规范）
      Row() {
        Checkbox()
          .select(isCompleted)
          .selectedColor($r('app.color.success_color'))
          .width(18).height(18)
          .accessibilityText(getContext(this).resourceManager.getStringSync($r('app.string.task_detail_complete_prefix_acc').id) + safeStringUtil(stepText, getContext(this).resourceManager.getStringSync($r('app.string.task_detail_unnamed_step').id)))
          .onChange((): void => { this.toggleStep(index) })
      }
      .constraintSize({ minWidth: DimensConstants.TOUCH_COMFORT, minHeight: DimensConstants.TOUCH_COMFORT })
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)

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
           .borderRadius(22)
           .backgroundColor(this.pressedStepIndex === index && this.pressedStepAction === 'confirm' ? $r('app.color.bg_tag') : Color.Transparent)
           .scale({ x: this.pressedStepIndex === index && this.pressedStepAction === 'confirm' ? 0.9 : 1, y: this.pressedStepIndex === index && this.pressedStepAction === 'confirm' ? 0.9 : 1 })
           .animation({ duration: 100, curve: Curve.EaseOut })
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
           .borderRadius(22)
           .backgroundColor(this.pressedStepIndex === index && this.pressedStepAction === 'cancel' ? $r('app.color.bg_tag') : Color.Transparent)
           .scale({ x: this.pressedStepIndex === index && this.pressedStepAction === 'cancel' ? 0.9 : 1, y: this.pressedStepIndex === index && this.pressedStepAction === 'cancel' ? 0.9 : 1 })
           .animation({ duration: 100, curve: Curve.EaseOut })
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
        // 显示模式：显示文本
        Text((index + 1).toString() + '. ' + safeStringUtil(stepText, getContext(this).resourceManager.getStringSync($r('app.string.task_unnamed_step').id)))
          .fontSize(CommonConstants.FONT_SIZE_BODY)
          .fontFamily('HarmonyOS Sans')
          .fontColor(isCompleted ? $r('app.color.text_tertiary') : $r('app.color.text_primary'))
          .decoration(isCompleted ? { type: TextDecorationType.LineThrough } : { type: TextDecorationType.None })
          .layoutWeight(1)

        Row() {
          SymbolGlyph($r('sys.symbol.pencil_tip'))
            .fontSize(CommonConstants.FONT_SIZE_SUBTITLE)
            .fontColor([$r('app.color.primary_color')])
        }
        .constraintSize({ minWidth: 44, minHeight: 44 })
        .borderRadius(22)
        .backgroundColor(this.pressedStepIndex === index && this.pressedStepAction === 'edit' ? $r('app.color.bg_tag') : Color.Transparent)
        .scale({ x: this.pressedStepIndex === index && this.pressedStepAction === 'edit' ? 0.9 : 1, y: this.pressedStepIndex === index && this.pressedStepAction === 'edit' ? 0.9 : 1 })
        .animation({ duration: 100, curve: Curve.EaseOut })
        .margin({ right: 4 })
        .accessibilityText(getContext(this).resourceManager.getStringSync($r('app.string.task_detail_edit_step_acc').id))
        .onClick(() => { this.startEditStep(index, stepText) })
        .onTouch((event: TouchEvent): void => {
          if (event.type === TouchType.Down) {
            this.pressedStepIndex = index
            this.pressedStepAction = 'edit'
          } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
            this.pressedStepIndex = -1
            this.pressedStepAction = ''
          }
        })
      }

      Row() {
        SymbolGlyph($r('sys.symbol.trash'))
          .fontSize(CommonConstants.FONT_SIZE_SUBTITLE)
          .fontColor([$r('app.color.text_tertiary')])
      }
      .constraintSize({ minWidth: 44, minHeight: 44 })
      .borderRadius(22)
      .backgroundColor(this.pressedStepIndex === index && this.pressedStepAction === 'delete' ? $r('app.color.bg_tag') : Color.Transparent)
      .scale({ x: this.pressedStepIndex === index && this.pressedStepAction === 'delete' ? 0.9 : 1, y: this.pressedStepIndex === index && this.pressedStepAction === 'delete' ? 0.9 : 1 })
      .animation({ duration: 100, curve: Curve.EaseOut })
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
    .width('100%').padding(10).backgroundColor($r('app.color.bg_card')).borderRadius(12)
    .alignItems(VerticalAlign.Center)
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
          // - stepVersion 自增触发 @Local 重新计算
          // - l2Task 引用更新触发 ForEach 重新渲染
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

  private toggleTaskComplete(): void {
    const newCompleted: boolean = !this.task.isCompleted
    this.task.isCompleted = newCompleted
    Logger.info('TaskDetailPage', 'toggleTaskComplete, new=' + newCompleted.toString())

    // 4 级架构回写：更新 L2 任务状态
    if (this.goalId && this.relatedTaskId) {
      const task: AiGeneratedTask | null = routeVM.findTask(this.goalId, this.relatedTaskId)
      if (task) {
        task.status = newCompleted ? TaskStatus.COMPLETED : TaskStatus.PENDING
        Logger.info('TaskDetailPage', 'toggleTaskComplete: updated L2 task status via routeVM')
      }
    }

    // 回写 L4 待办完成状态
    homeVM.toggleTask(this.task.id)

    promptAction.showToast({ message: newCompleted ? getContext(this).resourceManager.getStringSync($r('app.string.toast_task_completed').id) : getContext(this).resourceManager.getStringSync($r('app.string.toast_task_uncompleted').id) })
  }

  private onDestinationReady(context: NavDestinationContext): void {
    if (!settingsVM.userProfile.isLoggedIn) {
      Logger.warn('TaskDetailPage', 'onDestinationReady: not logged in, redirect to LoginPage')
      globalNavStack.replacePath(new NavPathInfo(ROUTE_NAME.LOGIN, null))
      return
    }

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
    const found = homeVM.taskList.find((t: HomeTodoItem): boolean => t.id === taskId)
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
          .fontFamily('HarmonyOS Sans')
          .fontColor($r('app.color.text_primary'))

        // 任务名称输入
        TextInput({ text: this.editTaskName, placeholder: $r('app.string.edit_task_name_hint') })
          .type(InputType.Normal)
          .width('100%')
          .height(44)
          .fontSize(CommonConstants.FONT_SIZE_SUBTITLE)
          .backgroundColor($r('app.color.bg_page'))
          .borderRadius(10)
          .padding({ left: 12, right: 12 })
          .onChange((value: string): void => { this.editTaskName = value })

        // 预估时长输入（数字键盘）
        TextInput({ text: this.editTaskDuration, placeholder: $r('app.string.edit_task_duration_hint') })
          .type(InputType.Number)
          .width('100%')
          .height(44)
          .fontSize(CommonConstants.FONT_SIZE_SUBTITLE)
          .backgroundColor($r('app.color.bg_page'))
          .borderRadius(10)
          .padding({ left: 12, right: 12 })
          .onChange((value: string): void => { this.editTaskDuration = value })

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
      .animation({ duration: 250, curve: Curve.EaseOut })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.overlay_mask'))
    .animation({ duration: 200, curve: Curve.EaseOut })
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
    promptAction.showActionMenu({
      title: $r('app.string.dialog_task_action_title'),
      buttons: [
        { text: $r('app.string.dialog_edit_task'), color: $r('app.color.text_primary') },
        { text: $r('app.string.dialog_delete_task'), color: $r('app.color.error_color') }
      ]
    }).then((result: promptAction.ActionMenuSuccessResponse): void => {
      if (!this.isAttached) return
      if (result.index === 0) {
        this.handleEditTask()
      } else if (result.index === 1) {
        this.handleDeleteTask()
      }
    }).catch((e: Error): void => {
      Logger.error('TaskDetailPage', 'showTaskActionMenu failed: ' + e.message)
    })
  }

  private handleEditTask(): void {
    // 预填当前任务名称和时长
    this.editTaskName = this.task.title
    // 从 L2 任务或当前任务中读取时长，转为分钟数
    if (this.l2Task && this.l2Task.estimatedTime > 0) {
      this.editTaskDuration = this.l2Task.estimatedTime.toString()
    } else {
      // 从 duration 字符串中提取数字
      const match = this.task.duration.match(/\d+/)
      this.editTaskDuration = match ? match[0] : '30'
    }
    this.showEditPanel = true
  }

  private saveEditTask(): void {
    const newName: string = this.editTaskName.trim()
    if (newName.length === 0) {
      promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_step_empty').id) })
      return
    }
    const newDuration: number = parseInt(this.editTaskDuration, 10)
    const safeDuration: number = (isNaN(newDuration) || newDuration <= 0) ? 30 : newDuration

    // 持久化到 routeVM + 同步 L4 待办
    if (this.goalId && this.relatedTaskId) {
      const success: boolean = routeVM.updateTask(this.goalId, this.relatedTaskId, newName, safeDuration)
      if (success) {
        Logger.info('TaskDetailPage', 'saveEditTask: routeVM.updateTask success')
      } else {
        Logger.warn('TaskDetailPage', 'saveEditTask: routeVM.updateTask returned false')
      }
    }

    // 本地 UI 立即刷新
    this.task.title = newName
    this.task.duration = safeDuration.toString() + ' min'
    if (this.l2Task) {
      this.l2Task.taskName = newName
      this.l2Task.estimatedTime = safeDuration
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

  /** 内容列限宽：平板（lg）双栏铺满，手机/折叠屏保持 640 居中 */
  private getContentConstraint(): ConstraintSizeOptions {
    if (breakpointState.isTablet) {
      const full: ConstraintSizeOptions = { maxWidth: '100%' }
      return full
    }
    const capped: ConstraintSizeOptions = { maxWidth: DimensConstants.CONTENT_MAX_WIDTH }
    return capped
  }

  /** 任务信息区：菜单按钮 + 任务信息卡（平板双栏时为左栏上部） */
  @Builder
  TaskInfoBuilder() {
    // 菜单按钮（独立 Row，靠右对齐）
    Row() {
      Column() {
        SymbolGlyph($r('sys.symbol.ellipsis_circle'))
          .fontSize(CommonConstants.FONT_SIZE_LARGE)
          .fontColor([$r('app.color.text_secondary')])
      }
      .width(DimensConstants.TOUCH_COMFORT)
      .height(DimensConstants.TOUCH_COMFORT)
      .borderRadius(22)
      .backgroundColor(Color.Transparent)
      .alignItems(HorizontalAlign.Center)
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.showTaskActionMenu()
      })
    }
    .width('100%')
    .justifyContent(FlexAlign.End)

    // 顶部：任务信息卡
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(safeStringUtil(this.task.title, getContext(this).resourceManager.getStringSync($r('app.string.default_unnamed_task').id)))
          .fontSize(CommonConstants.FONT_SIZE_LARGE)
          .fontWeight(FontWeight.Bold)
          .fontFamily('HarmonyOS Sans')
          .fontColor(this.task.isCompleted ? $r('app.color.text_tertiary') : $r('app.color.text_primary'))
          .layoutWeight(1).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(priorityLabelUtil(this.task.priority))
          .fontSize(CommonConstants.FONT_SIZE_XS)
          .fontColor(priorityTextColorUtil(this.task.priority))
          .fontWeight(FontWeight.Regular)
          .fontFamily('HarmonyOS Sans')
          .backgroundColor(priorityBgColorUtil(this.task.priority))
          .padding({ left: 8, right: 8, top: 2, bottom: 2 }).borderRadius(4)
      }
      .width('100%').alignItems(VerticalAlign.Center)

      // 修复：ArkUI 的条件渲染 if 必须直接判断，不能先声明 const 变量
      if (safeStringUtil(this.task.description, '').length > 0) {
        Text(safeStringUtil(this.task.description, ''))
          .fontSize(CommonConstants.FONT_SIZE_SMALL)
          .fontColor($r('app.color.text_secondary'))
          .fontFamily('HarmonyOS Sans')
          .width('100%').maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      Row({ space: 16 }) {
        Row({ space: 4 }) {
          Text($r('app.string.task_detail_estimated_time')).fontSize(CommonConstants.FONT_SIZE_XS)
          .fontColor($r('app.color.text_tertiary')).fontFamily('HarmonyOS Sans')
          Text((this.l2Task ? this.l2Task.estimatedTime : 0).toString() + ' min')
            .fontSize(CommonConstants.FONT_SIZE_SMALL)
            .fontColor($r('app.color.text_primary'))
            .fontFamily('HarmonyOS Sans')
        }
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.calendar'))
            .fontSize(CommonConstants.FONT_SIZE_SMALL)
            .fontColor([$r('app.color.text_tertiary')])
          Text(this.formatCreateTime(this.task.createTime)).fontSize(CommonConstants.FONT_SIZE_SMALL)
          .fontColor($r('app.color.text_primary')).fontFamily('HarmonyOS Sans')
        }
      }
      .width('100%')
    }
    .width('100%').padding(12).backgroundColor($r('app.color.bg_card')).borderRadius(16).margin({ bottom: 12 })
  }

  /** 番茄钟专注计时卡片（平板双栏时为左栏下部） */
  @Builder
  PomodoroBuilder() {
    PomodoroTimerCard({ taskId: this.task.id, taskTitle: this.task.title })
      .margin({ bottom: 12 })
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
          .fontFamily('HarmonyOS Sans')
          .fontColor($r('app.color.text_primary')).layoutWeight(1)
        // 修复：直接调用防空逻辑，不声明 const safeSteps
        Text(getContext(this).resourceManager.getStringSync($r('app.string.task_detail_steps_count_prefix').id) + (this.l2Task && Array.isArray(this.l2Task.steps) ?
          this.l2Task.steps.length : 0).toString() + getContext(this).resourceManager.getStringSync($r('app.string.task_detail_steps_count_suffix').id))
.fontSize(CommonConstants.FONT_SIZE_XS)
          .fontColor($r('app.color.text_tertiary')).fontFamily('HarmonyOS Sans')
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
        .backgroundColor($r('app.color.bg_card')).borderRadius(8)
      } else {
        // 4 级架构：从 l2Task.steps 渲染（字符串数组）
        //   - 预算 isCompleted（避免在 @Builder 内调方法）
        //   - keyGenerator 用 index 拼接（保证 ArkUI 不重复渲染）
        ForEach(this.l2Task.steps, (step: string, index: number): void => {
          this.StepItemBuilder(
            step,
            index,
            // 读 l2Task.completedSteps[index]，触发 @Trace 自动追踪
            isStepCompleted(this.l2Task, index)
          )
        }, (step: string, index: number): string => 'l3step_' + index.toString() + '_v' + this.stepVersion.toString())
      }
    }
    // 平板双栏：步骤区自然高度（避免 layoutWeight 把右栏撑满视口、操作按钮被顶到底部）
    .width('100%').layoutWeight(breakpointState.isTablet ? 0 : 1)
  }

  /** 底部操作区：添加步骤输入 + 完成按钮（平板双栏时为右栏下部） */
  @Builder
  StepActionsBuilder() {
    // 底部：添加步骤输入 + 完成按钮
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        TextInput({ placeholder: $r('app.string.task_detail_add_step_hint') })
          .type(InputType.Normal).layoutWeight(1).height(40).fontSize(CommonConstants.FONT_SIZE_BODY)
          .backgroundColor($r('app.color.bg_card')).borderRadius(8).padding({ left: 12, right: 12 })
          .accessibilityText(getContext(this).resourceManager.getStringSync($r('app.string.task_detail_add_step_input').id))
          .onChange((value: string): void => { this.newStepText = value })
          .onSubmit((keyCode: EnterKeyType): void => {
            Logger.info('TaskDetailPage', 'onSubmit, keyCode=' + keyCode.toString())
            this.addStep()
          })

        Button($r('app.string.btn_add_step'))
          .type(ButtonType.Capsule).height(40).padding({ left: 14, right: 14 })
          .backgroundColor($r('app.color.primary_color')).fontColor($r('app.color.text_inverse')).fontSize(CommonConstants.FONT_SIZE_BODY)
          .enabled(this.newStepText.trim().length > 0).accessibilityText(getContext(this).resourceManager.getStringSync($r('app.string.task_detail_add_step_button').id))
          .onClick((): void => { this.addStep() })
      }
      .width('100%')

      Button(this.task.isCompleted ? $r('app.string.btn_completed') : $r('app.string.btn_mark_complete'))
        .type(ButtonType.Capsule).height(44).width('100%')
        .backgroundColor(this.task.isCompleted ? $r('app.color.success_color') : $r('app.color.primary_color'))
        .fontColor($r('app.color.text_inverse')).fontSize(CommonConstants.FONT_SIZE_BODY)
        .fontWeight(FontWeight.Medium)
        .borderRadius(22)
        .shadow({ radius: 4, color: $r('app.color.primary_color_bg'), offsetX: 0, offsetY: 2 })
        .scale({ x: this.pressedCompleteBtn ? 0.97 : 1, y: this.pressedCompleteBtn ? 0.97 : 1 })
        .animation({ duration: 100, curve: Curve.EaseOut })
        .accessibilityText(getContext(this).resourceManager.getStringSync($r('app.string.task_detail_mark_complete_button').id))
        .onTouch((event: TouchEvent): void => {
          if (event.type === TouchType.Down) {
            this.pressedCompleteBtn = true
          } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
            this.pressedCompleteBtn = false
          }
        })
        .onClick((): void => { this.toggleTaskComplete() })
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
            onBack: (): void => { this.handleBackPress() }
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
            this.TaskInfoBuilder()

            this.PomodoroBuilder()

            this.StepsBuilder()

            this.StepActionsBuilder()
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .backgroundColor($r('app.color.bg_page'))
        .transition(TransitionEffect.OPACITY)
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
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))
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
      Logger.info('TaskDetailPage', 'onShown: refreshing task data')
      this.loadL2Task()
    })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .height('100%')
    // .hideTitleBar()
  }
}
