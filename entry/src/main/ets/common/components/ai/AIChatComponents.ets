/**
 * @file AI 页面拆分出的聊天 UI 子组件（多模态版）
 * @description
 *   从 AIPage.ets 拆分而来。包含：任务卡片、对话消息气泡（含图片预览回调）、
 *   场景芯片区、未登录拦截态、初始引导态。
 *   全部为无业务状态的展示组件：@Param 只读入参 + @Event 向上回调。
 */
import { AiGeneratedTask, TaskPriority, TaskStatus, ChatMessage } from '../../../model/Models'
import { CommonConstants } from '../../constants/CommonConstants'
import { priorityLabelUtil, priorityBgColorUtil, priorityTextColorUtil } from '../../utils/PriorityUtils'
import { safeStringUtil } from '../../utils/SafeUtils'
import { Logger } from '../../utils/Logger'

interface ScenarioChip {
  id: string
  text: ResourceStr
  prompt: ResourceStr
}

/**
 * AI 对话历史中的 plan 快照（用于构造 history 时序列化）
 * - goalName: AI 推断的目标名
 * - tasks: 直接复用 AiGeneratedTask 数组，避免与 DeepSeekTaskJson 字段类型不兼容
 *   （AiGeneratedTask.priority 是 enum，DeepSeekTaskJson.priority 是 string）
 */
interface AIHistoryPlanSnapshot {
  goalName: string
  tasks: Array<AiGeneratedTask>
}

/**

 * 场景芯片配置（3 个预设）
 * ArkTS 严格模式：使用 buildScenarioChip 工厂函数构造，杜绝对象字面量
 */
const SCENARIO_CHIPS: Array<ScenarioChip> = [
  buildScenarioChip(
    'scenario_1',
    $r('app.string.scenario_1_text'),
    $r('app.string.scenario_1_prompt')
  ),
  buildScenarioChip(
    'scenario_2',
    $r('app.string.scenario_2_text'),
    $r('app.string.scenario_2_prompt')
  ),
  buildScenarioChip(
    'scenario_3',
    $r('app.string.scenario_3_text'),
    $r('app.string.scenario_3_prompt')
  ),
  buildScenarioChip(
    'scenario_4',
    $r('app.string.scenario_4_text'),
    $r('app.string.scenario_4_prompt')
  )
]

/**
 * 顶层 ScenarioChip 工厂函数（ArkTS 严格模式）
 * 显式构造（不使用对象字面量 + as 强转）
 */
function buildScenarioChip(id: string, text: ResourceStr, prompt: ResourceStr): ScenarioChip {
  const chip: ScenarioChip = {
    id: id,
    text: text,
    prompt: prompt
  }
  return chip
}


/**
 * P0 #8.1 修复：estimatedTime 防空（NaN/null/undefined → 0）
 * 从根组件私有方法提升为顶层工具函数，供 AiTaskCardItem 子组件使用
 * 防止后端缺失字段时渲染 "NaN min" 或崩溃
 * @param value - 原始值
 * @returns 安全数字
 */
function safeEstimatedTimeUtil(value: number | null | undefined): number {
  if (typeof value === 'number' && !isNaN(value)) {
    return Math.max(0, Math.floor(value))
  }
  return 0
}

/* ============================================================
 * 子组件 1/9：AiTaskCardItem — 列表条目（@ReusableV2 复用优化）
 * 原 TaskCardBuilder @Builder → @ReusableV2 @ComponentV2
 * ============================================================ */

/**
 * AI 任务卡片条目（@ReusableV2）
 * LazyForEach 列表项，通过 @Param 接收 task 数据，@Event 回调操作
 */
@ReusableV2
@ComponentV2
export struct AiTaskCardItem {
  /** 任务数据（只读） */
  @Param task: AiGeneratedTask = new AiGeneratedTask('', '', 0, TaskPriority.MEDIUM, [], TaskStatus.PENDING, [])
  /** 任务索引 */
  @Param index: number = 0
  /** 是否展开步骤 */
  @Param isExpanded: boolean = false
  /** 当前按压态的任务卡片 ID */
  @Param pressedTaskCardId: string = ''
  /** 切换展开/收起步骤 */
  @Event onToggleExpand: (index: number) => void = () => {}
  /** 按压态 ID 变更回调 */
  @Event onTaskCardPressedIdChange: (id: string) => void = () => {}
  /** 编辑任务回调（点击"微调"按钮） */
  @Event onEditTask: (task: AiGeneratedTask) => void = () => {}
  /** 删除任务回调（点击"删除"按钮） */
  @Event onDeleteTask: (task: AiGeneratedTask) => void = () => {}

  build() {
    Column({ space: 10 }) {
      // 标题行：任务名称 + 优先级标签
      Row({ space: 8 }) {
        Text(this.safeTaskName)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(priorityLabelUtil(this.task.priority))
          .fontSize(11)
          .fontColor(priorityTextColorUtil(this.task.priority))
          .backgroundColor(priorityBgColorUtil(this.task.priority))
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(12)
          .fontWeight(FontWeight.Medium)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 元数据行：耗时 + 步骤数
      Row({ space: 4 }) {
        Text(safeEstimatedTimeUtil(this.task.estimatedTime).toString() +
          ' min')
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))

        if (this.safeSteps.length > 0) {
          Text('·')
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))

          Text(this.safeSteps.length.toString() + ' steps')
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 展开/收起按钮（全宽 + 淡色背景）
      if (this.safeSteps.length > 0) {
        Row() {
          Text(this.isExpanded ? $r('app.string.route_collapse_steps') : $r('app.string.route_expand_steps'))
            .fontSize(12)
            .fontColor($r('app.color.primary_color'))
            .layoutWeight(1)

          Text(this.isExpanded ? '▲' : '▼')
            .fontSize(10)
            .fontColor($r('app.color.primary_color'))
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .backgroundColor($r('app.color.primary_color_bg'))
        .borderRadius(12)
        .onClick((): void => {
          this.onToggleExpand(this.index)
        })
        .accessibilityText(this.isExpanded ?
          getContext(this).resourceManager.getStringSync($r('app.string.ai_collapse_steps').id) :
          getContext(this).resourceManager.getStringSync($r('app.string.ai_expand_steps').id) + this.safeSteps.length.toString() + getContext(this).resourceManager.getStringSync($r('app.string.route_steps_count_suffix').id))

        // 展开的步骤列表
        if (this.isExpanded) {
          Column({ space: 8 }) {
            ForEach(this.safeSteps, (step: string, stepIndex: number): void => {
              Row({ space: 8 }) {
                Text((stepIndex + 1).toString() + '.')
                  .fontSize(12)
                  .fontColor($r('app.color.primary_color'))
                  .fontWeight(FontWeight.Medium)
                Text(step)
                  .fontSize(13)
                  .fontColor($r('app.color.text_secondary'))
                  .layoutWeight(1)
                  .lineHeight(18)
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
            }, (step: string, stepIndex: number): string => 'ai_step_' + stepIndex.toString() + '_' + this.task.id)
          }
          .width('100%')
          .padding(10)
          .backgroundColor($r('app.color.bg_tag'))
          .borderRadius(8)
          .margin({ top: 6 })
        }

        // 操作按钮行：微调 / 删除（纯文字 + 淡色背景）
        Row({ space: 8 }) {
          Text($r('app.string.ai_edit_task'))
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .backgroundColor($r('app.color.bg_tag'))
            .borderRadius(12)
            .onClick((): void => {
              this.onEditTask(this.task)
            })

          Text($r('app.string.ai_delete_task'))
            .fontSize(11)
            .fontColor($r('app.color.error_color'))
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .backgroundColor($r('app.color.priority_high_bg'))
            .borderRadius(12)
            .onClick((): void => {
              this.onDeleteTask(this.task)
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
        .margin({ top: 4 })
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.pressedTaskCardId === this.task.id ?
      $r('app.color.bg_tag') : $r('app.color.bg_card'))
    .borderRadius(16)
    .shadow({ radius: 8, color: $r('app.color.shadow_card'), offsetX: 0, offsetY: 2 })
    .alignItems(HorizontalAlign.Start)
    .animation({ duration: 120, curve: Curve.EaseInOut })
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down) {
        this.onTaskCardPressedIdChange(this.task.id)
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.onTaskCardPressedIdChange('')
      }
    })
  }

  /** 防空任务名 */
  private get safeTaskName(): string {
    return (this.task.taskName && this.task.taskName.length > 0) ?
      this.task.taskName : (getContext(this).resourceManager.getStringSync($r('app.string.ai_task_fallback_prefix').id) + (this.index + 1).toString())
  }

  /** 防空步骤数组 */
  private get safeSteps(): Array<string> {
    return Array.isArray(this.task.steps) ? this.task.steps : []
  }
}

/* ============================================================
 * 子组件 2：ChatMessageItem — 对话流消息气泡（Step 2 重构）
 *   - 用户消息：右对齐蓝色气泡
 *   - AI 消息：左对齐灰色气泡 + 内嵌任务卡片 + 确认按钮
 *   - 复用 AiTaskCardItem 渲染任务（保持展开/收起一致性）
 * ============================================================ */

@ReusableV2
@ComponentV2
export struct ChatMessageItem {
  /** 消息数据 */
  @Param message: ChatMessage = buildEmptyChatMessage()
  /** 任务索引 → 是否展开步骤（共享 Map，由根页面持有） */
  @Param expandedIndices: Map<string, boolean> = new Map()
  /** 当前按压态的任务卡片 ID */
  @Param pressedTaskCardId: string = ''

  /** 切换任务步骤展开/收起 */
  @Event onToggleExpand: (messageId: string, taskIndex: number) => void = (_m: string, _i: number) => {}
  /** 任务卡片按压态 ID 变更回调 */
  @Event onTaskCardPressedIdChange: (id: string) => void = (_id: string) => {}
  /** 编辑任务回调 */
  @Event onEditTask: (messageId: string, task: AiGeneratedTask) => void = (_m: string, _t: AiGeneratedTask) => {}
  /** 删除任务回调 */
  @Event onDeleteTask: (messageId: string, task: AiGeneratedTask) => void = (_m: string, _t: AiGeneratedTask) => {}
  /** 确认使用此方案（加入路线） */
  @Event onConfirmPlan: (messageId: string) => void = (_m: string) => {}

  build() {
    if (this.message.role === 'user') {
      // 用户消息：右对齐主色气泡（非对称圆角，右下角小圆角模拟气泡尖角方向）
      Row() {
        Blank()

        Column() {
          // 文字
          if (this.message.text.length > 0) {
            Text(this.message.text)
              .fontSize(15)
              .fontColor($r('app.color.text_inverse'))
              .fontWeight(FontWeight.Regular)
              .lineHeight(22)
              .textAlign(TextAlign.Start)
          }
        }
        .padding({ left: 16, right: 16, top: 11, bottom: 11 })
        .backgroundColor($r('app.color.primary_color'))
        .borderRadius({ topLeft: 18, topRight: 18, bottomLeft: 18, bottomRight: 6 })
        .constraintSize({ maxWidth: '72%' })
        .alignItems(HorizontalAlign.Start)
        .shadow({ radius: 6, color: $r('app.color.shadow_card'), offsetX: 0, offsetY: 2 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .padding({ top: 10, bottom: 10 })
    } else {
      // AI 消息：左对齐气泡 + 可选任务卡片 + 确认按钮
      Row() {
        Column({ space: 12 }) {
          if (this.message.isStreaming && this.message.text.length === 0) {
            // Loading 态：AI 正在思考（带呼吸感的圆点动画），收到回复前显示
            Row({ space: 10 }) {
              LoadingProgress()
                .width(16)
                .height(16)
                .color($r('app.color.primary_color'))
              Text($r('app.string.chat_loading_hint'))
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
            }
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius({ topLeft: 6, topRight: 18, bottomLeft: 18, bottomRight: 18 })
            .constraintSize({ maxWidth: '82%' })
            .shadow({ radius: 6, color: $r('app.color.shadow_card'), offsetX: 0, offsetY: 1 })
          } else {
            // 文本气泡（仅当有文本时显示；逐字显示中追加光标符模拟打字机）
            if (this.message.text.length > 0) {
              Text(this.message.text + (this.message.isStreaming ? '▍' : ''))
                .fontSize(15)
                .fontColor($r('app.color.text_primary'))
                .lineHeight(22)
                .textAlign(TextAlign.Start)
                .padding({ left: 16, right: 16, top: 11, bottom: 11 })
                .backgroundColor($r('app.color.bg_card'))
                .borderRadius({ topLeft: 6, topRight: 18, bottomLeft: 18, bottomRight: 18 })
                .constraintSize({ maxWidth: '82%' })
                .shadow({ radius: 6, color: $r('app.color.shadow_card'), offsetX: 0, offsetY: 1 })
            }

            // 任务卡片列表（仅当有任务时显示）
            if (this.message.tasks.length > 0) {
              Column({ space: 10 }) {
                // 任务统计（精致胶囊标签）
                Row({ space: 8 }) {
                  Text(getContext(this).resourceManager.getStringSync($r('app.string.ai_result_summary').id))
                    .fontSize(12)
                    .fontColor($r('app.color.text_tertiary'))
                  Text(getContext(this).resourceManager.getStringSync($r('app.string.chat_tasks_count_prefix').id) +
                    this.message.tasks.length.toString() +
                    getContext(this).resourceManager.getStringSync($r('app.string.chat_tasks_count_suffix').id))
                    .fontSize(12)
                    .fontColor($r('app.color.primary_color'))
                    .fontWeight(FontWeight.Medium)
                    .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                    .backgroundColor($r('app.color.primary_color_bg'))
                    .borderRadius(10)
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)

                // 任务卡片（ForEach，复用 AiTaskCardItem）
                ForEach(this.message.tasks, (task: AiGeneratedTask, index: number): void => {
                  AiTaskCardItem({
                    task: task,
                    index: index,
                    isExpanded: this.isTaskExpanded(this.message.id, index),
                    pressedTaskCardId: this.pressedTaskCardId,
                    onToggleExpand: (idx: number): void => { this.onToggleExpand(this.message.id, idx) },
                    onTaskCardPressedIdChange: (id: string): void => { this.onTaskCardPressedIdChange(id) },
                    onEditTask: (t: AiGeneratedTask): void => { this.onEditTask(this.message.id, t) },
                    onDeleteTask: (t: AiGeneratedTask): void => { this.onDeleteTask(this.message.id, t) }
                  })
                }, (task: AiGeneratedTask): string => this.message.id + '_' + task.id)
              }
              .width('100%')
              .padding(14)
              .backgroundColor($r('app.color.bg_card'))
              .borderRadius(16)
              .constraintSize({ maxWidth: '88%' })
              .shadow({ radius: 6, color: $r('app.color.shadow_card'), offsetX: 0, offsetY: 1 })
            }
          }

          // 确认使用此方案按钮（仅当 AI 回复携带任务且未确认时显示）
          if (!this.message.isStreaming && this.message.tasks.length > 0) {
            if (this.message.isConfirmed) {
              Text($r('app.string.chat_plan_confirmed'))
                .fontSize(13)
                .fontColor($r('app.color.primary_color'))
                .fontWeight(FontWeight.Medium)
                .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                .backgroundColor($r('app.color.primary_color_bg'))
                .borderRadius(20)
            } else {
              Button($r('app.string.btn_confirm_plan'))
                .type(ButtonType.Capsule)
                .height(38)
                .padding({ left: 22, right: 22 })
                .backgroundColor($r('app.color.primary_color'))
                .fontColor($r('app.color.text_inverse'))
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .borderRadius(24)
                .shadow({ radius: 4, color: $r('app.color.primary_color_bg'), offsetX: 0, offsetY: 2 })
                .onClick((): void => {
                  this.onConfirmPlan(this.message.id)
                })
            }
          }
        }
        .alignItems(HorizontalAlign.Start)

        Blank()
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .padding({ top: 10, bottom: 10 })
    }
  }

  /** 判断指定消息内的任务是否展开 */
  private isTaskExpanded(messageId: string, taskIndex: number): boolean {
    const key: string = messageId + '_' + taskIndex.toString()
    const val: boolean | undefined = this.expandedIndices.get(key)
    return val === true
  }
}

/**
 * 空 ChatMessage 工厂（@Param 默认值，ArkTS 严格模式禁止对象字面量）
 */
function buildEmptyChatMessage(): ChatMessage {
  const msg: ChatMessage = new ChatMessage('', 'user', '', [], '', false, false)
  return msg
}

/* ============================================================
 * 子组件 3：AiScenarioChipSection — 场景芯片区
 * ============================================================ */

/**
 * 场景芯片区（3 个预设芯片，含按压态）
 * 按压态通过 @Event 回调给根页面修改 pressedChipId
 */
@ComponentV2
export struct AiScenarioChipSection {
  /** 当前按压态的芯片 ID */
  @Param pressedChipId: string = ''
  /** 按压态 ID 变更回调 */
  @Event onChipPressedIdChange: (id: string) => void = () => {}
  /** 芯片点击回调（传入 prompt 文本） */
  @Event onChipClick: (prompt: string) => void = () => {}

  /** 解析 ResourceStr 为 string（ArkTS 严格模式：用 typeof 类型守卫代替 as 强转） */
  private resolveResourceStr(res: ResourceStr): string {
    if (typeof res === 'string') {
      return res
    }
    return getContext(this).resourceManager.getStringSync(res.id)
  }

  build() {
    // 场景芯片：淡填充 + 细边框，简约风格
    Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start, alignItems: ItemAlign.Center }) {
      ForEach(SCENARIO_CHIPS, (chip: ScenarioChip): void => {
        Text(chip.text)
          .fontSize(13)
          .fontColor(this.pressedChipId === chip.id ?
            $r('app.color.text_inverse') : $r('app.color.primary_color'))
          .backgroundColor(this.pressedChipId === chip.id ?
            $r('app.color.primary_color') : $r('app.color.primary_color_bg'))
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .borderRadius(16)
          .border({ width: 0.5, color: $r('app.color.divider') })
          .margin({ right: 8, bottom: 8 })
          .scale(this.pressedChipId === chip.id ?
            { x: 0.96, y: 0.96 } : { x: 1, y: 1 })
          .animation({ duration: 120, curve: Curve.EaseInOut })
          .accessibilityText(getContext(this).resourceManager.getStringSync($r('app.string.scenario_accessibility_prefix').id) + this.resolveResourceStr(chip.text))
          .onTouch((event: TouchEvent): void => {
            if (event.type === TouchType.Down) {
              this.onChipPressedIdChange(chip.id)
            } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              this.onChipPressedIdChange('')
            }
          })
          .onClick((): void => {
            const promptStr: string = this.resolveResourceStr(chip.prompt)
            this.onChipClick(safeStringUtil(promptStr, ''))
            Logger.info('AIPage', 'chip click, id=' + chip.id)
          })
      }, (chip: ScenarioChip): string => chip.id)
    }
    .width('100%')
  }
}

/* ============================================================
 * 子组件 3/9：AiLoginRequiredSection — 未登录拦截态
 * ============================================================ */

/**
 * 未登录拦截态
 * 显示提示图标 + 文案 + "去登录"按钮
 */
@ComponentV2
export struct AiLoginRequiredSection {
  /** 点击"去登录"回调 */
  @Event onNavigateLogin: () => void = () => {}

  build() {
    Column({ space: 16 }) {
      Image($r('app.media.tab_ai_active'))
        .width(64)
        .height(64)
        .objectFit(ImageFit.Contain)
        .opacity(0.4)
        .accessibilityText($r('app.string.ai_icon'))

      Text($r('app.string.ai_login_required_title'))
        .fontSize(16) // Fix: P1-1+字号单位统一为纯数字
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))

      Text($r('app.string.ai_login_required_desc'))
        .fontSize(14) // Fix: P1-1+字号单位统一为纯数字
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
        .padding({ left: 24, right: 24 })

      Button($r('app.string.btn_go_login'))
        .type(ButtonType.Capsule)
        .width('60%')
        .height(44)
        .backgroundColor($r('app.color.primary_color'))
        .fontColor($r('app.color.text_inverse'))
        .fontSize(14) // Fix: P1-1+字号单位统一为纯数字
        .borderRadius(22)
        .margin({ top: 8 })
        .accessibilityText(getContext(this).resourceManager.getStringSync($r('app.string.acc_go_login').id))
        .onClick((): void => {
          this.onNavigateLogin()
        })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}

/* ============================================================
 * Step 2 重构：AiLoadingSection / AiErrorSection 已移除
 *   - Loading 态改由 ChatMessageItem 内部 isStreaming 分支渲染
 *   - 错误态改由 AI 消息气泡内显示错误文本
 * ============================================================ */

/* ============================================================
 * 子组件：AiGuideSection — 初始引导态
 * ============================================================ */

/**
 * 初始引导态
 * 3 步骤引导：输入目标 → AI 拆解 → 一键加入路线
 */
@ComponentV2
export struct AiGuideSection {
  build() {
    Column({ space: 24 }) {
      // 顶部图标区（柔和光晕效果）
      Column() {
        Image($r('app.media.tab_ai_active'))
          .width(72)
          .height(72)
          .objectFit(ImageFit.Contain)
          .opacity(0.85)
          .accessibilityText($r('app.string.ai_icon'))
      }
      .padding(20)
      .backgroundColor($r('app.color.primary_color_bg'))
      .borderRadius(36)

      Text($r('app.string.ai_guide_title'))
        .fontSize(15)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
        .lineHeight(22)
        .padding({ left: 32, right: 32 })

      // 步骤引导卡片
      Column({ space: 14 }) {
        Row({ space: 12 }) {
          Text('1')
            .fontSize(13)
            .fontColor($r('app.color.text_inverse'))
            .fontWeight(FontWeight.Medium)
            .width(26)
            .height(26)
            .textAlign(TextAlign.Center)
            .borderRadius(13)
            .backgroundColor($r('app.color.primary_color'))
          Text($r('app.string.ai_guide_step1'))
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Row({ space: 12 }) {
          Text('2')
            .fontSize(13)
            .fontColor($r('app.color.text_inverse'))
            .fontWeight(FontWeight.Medium)
            .width(26)
            .height(26)
            .textAlign(TextAlign.Center)
            .borderRadius(13)
            .backgroundColor($r('app.color.primary_color'))
          Text($r('app.string.ai_guide_step2'))
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Row({ space: 12 }) {
          Text('3')
            .fontSize(13)
            .fontColor($r('app.color.text_inverse'))
            .fontWeight(FontWeight.Medium)
            .width(26)
            .height(26)
            .textAlign(TextAlign.Center)
            .borderRadius(13)
            .backgroundColor($r('app.color.primary_color'))
          Text($r('app.string.ai_guide_step3'))
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .padding(20)
      .backgroundColor($r('app.color.bg_card'))
      .borderRadius(16)
      .margin({ left: 24, right: 24 })
      .shadow({ radius: 8, color: $r('app.color.shadow_card'), offsetX: 0, offsetY: 2 })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .margin({ top: 0, bottom: 40 })
  }
}

/* ============================================================
 * Step 2 重构：AiActionBarSection / AiInputSection / AiResultSection 已移除
 *   - 操作栏改由 ChatMessageItem 内部的"确认使用此方案"按钮替代
 *   - 输入区改由根页面 build 中的底部 TextInput + 发送按钮替代
 *   - 结果列表改由 ChatMessageItem 内嵌 AiTaskCardItem 替代
 * ============================================================ */

/* ============================================================
 * 子组件 6：AiPlanSideSection — lg 侧栏"最新拆解方案"
 *   展示最新一条带任务的 AI 消息，支持展开步骤 / 编辑 / 删除 / 确认
 *   展开状态 Map 由页面独立注入，与消息流互不影响
 * ============================================================ */

@ComponentV2
export struct AiPlanSideSection {
  /** 最新一条拆解方案消息（null 时显示空态引导） */
  @Param planMessage: ChatMessage | null = null
  /** 侧栏独立展开状态 Map<messageId_taskIndex, true> */
  @Param expandedIndices: Map<string, boolean> = new Map()
  /** 任务卡按压态 ID */
  @Param pressedTaskCardId: string = ''
  /** 展开/收起回调 */
  @Event onToggleExpand: (messageId: string, taskIndex: number) => void = (_m: string, _i: number) => {}
  /** 按压态变更回调 */
  @Event onTaskCardPressedIdChange: (id: string) => void = (_id: string) => {}
  /** 编辑任务回调 */
  @Event onEditTask: (messageId: string, task: AiGeneratedTask) => void = (_m: string, _t: AiGeneratedTask) => {}
  /** 删除任务回调 */
  @Event onDeleteTask: (messageId: string, task: AiGeneratedTask) => void = (_m: string, _t: AiGeneratedTask) => {}
  /** 确认方案回调 */
  @Event onConfirmPlan: (messageId: string) => void = (_m: string) => {}

  private getPlanTasks(): Array<AiGeneratedTask> {
    return this.planMessage !== null ? this.planMessage.tasks : []
  }

  private getPlanMessageId(): string {
    return this.planMessage !== null ? this.planMessage.id : ''
  }

  private isTaskExpanded(messageId: string, taskIndex: number): boolean {
    const key: string = messageId + '_' + taskIndex.toString()
    return this.expandedIndices.get(key) === true
  }

  build() {
    Column() {
      Text($r('app.string.ai_plan_side_title'))
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .padding({ left: 16, right: 16, top: 16, bottom: 8 })

      if (this.planMessage !== null) {
        Scroll() {
          Column({ space: 10 }) {
            Text(this.planMessage.goalName)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')

            ForEach(this.getPlanTasks(), (task: AiGeneratedTask, index: number): void => {
              AiTaskCardItem({
                task: task,
                index: index,
                isExpanded: this.isTaskExpanded(this.getPlanMessageId(), index),
                pressedTaskCardId: this.pressedTaskCardId,
                onToggleExpand: (idx: number): void => { this.onToggleExpand(this.getPlanMessageId(), idx) },
                onTaskCardPressedIdChange: (id: string): void => { this.onTaskCardPressedIdChange(id) },
                onEditTask: (t: AiGeneratedTask): void => { this.onEditTask(this.getPlanMessageId(), t) },
                onDeleteTask: (t: AiGeneratedTask): void => { this.onDeleteTask(this.getPlanMessageId(), t) }
              })
            }, (task: AiGeneratedTask): string => task.id)
          }
          .width('100%')
          .padding({ left: 12, right: 12 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .align(Alignment.Top)

        if (this.planMessage.isConfirmed) {
          Text($r('app.string.chat_plan_confirmed'))
            .fontSize(13)
            .fontColor($r('app.color.primary_color'))
            .fontWeight(FontWeight.Medium)
            .padding({ left: 14, right: 14, top: 7, bottom: 7 })
            .backgroundColor($r('app.color.primary_color_bg'))
            .borderRadius(20)
            .margin({ top: 10 })
        } else {
          Button($r('app.string.btn_confirm_plan'))
            .type(ButtonType.Capsule)
            .width('100%')
            .height(40)
            .margin({ left: 12, right: 12, top: 10 })
            .backgroundColor($r('app.color.primary_color'))
            .fontColor($r('app.color.text_inverse'))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .borderRadius(20)
            .onClick((): void => {
              this.onConfirmPlan(this.getPlanMessageId())
            })
        }
      } else {
        Column({ space: 8 }) {
          Text('✨')
            .fontSize(32)
          Text($r('app.string.ai_plan_side_empty'))
            .fontSize(13)
            .fontColor($r('app.color.text_tertiary'))
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .padding({ left: 20, right: 20 })
      }
    }
    .width('100%')
    .height('100%')
  }
}

