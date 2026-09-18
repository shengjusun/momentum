/**
 * @file AI 页面拆分出的聊天 UI 子组件（多模态版）
 * @description
 *   从 AIPage.ets 拆分而来。包含：任务卡片、对话消息气泡（含图片预览回调）、
 *   场景芯片区、未登录拦截态、初始引导态。
 *   全部为无业务状态的展示组件：@Param 只读入参 + @Event 向上回调。
 */
import { AiGeneratedTask, TaskStep, TaskPriority, TaskStatus, ChatMessage } from '../../../model/Models'
import { DimensConstants } from '../../constants/DimensConstants'
import { MotionConstants } from '../../constants/MotionConstants'

import { priorityLabelUtil, priorityTextColorUtil } from '../../utils/PriorityUtils'
import { safeStringUtil } from '../../utils/SafeUtils'
import { formatEstimatedDuration } from '../../utils/SafeUtils'
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

 * 场景芯片配置（6 个预设：开发 / 学习 / 求职 / 健康 / 生活 / 习惯，覆盖目标管理的主场景）
 * - 标签用「带结果的短句」（如「12 周减脂 10 斤」）而非领域名词：更能传达 AI 的产出价值
 * - 展示为横向滚动单行：原 Flex wrap 在 360vp 手机宽下折成 2×2，观感差；平板一行全见，视觉不变
 * - prompt 保持带时限、带量化目标的完整句式（点击后直接进输入框）
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
  ),
  buildScenarioChip(
    'scenario_5',
    $r('app.string.scenario_5_text'),
    $r('app.string.scenario_5_prompt')
  ),
  buildScenarioChip(
    'scenario_6',
    $r('app.string.scenario_6_text'),
    $r('app.string.scenario_6_prompt')
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
  @Param task: AiGeneratedTask = new AiGeneratedTask('', '', 0, TaskPriority.MEDIUM, [], TaskStatus.PENDING)
  /** 任务索引 */
  @Param index: number = 0
  /** 是否展开步骤 */
  @Param isExpanded: boolean = false
  /** 当前按压态的任务卡片 ID */
  @Param pressedTaskCardId: string = ''
  /** 方案是否已确认落库：确认后隐藏微调/删除按钮（改动不会同步到已落库目标，避免误导） */
  @Param isConfirmed: boolean = false
  /** 切换展开/收起步骤 */
  @Event onToggleExpand: (index: number) => void = () => {}
  /** 按压态 ID 变更回调 */
  @Event onTaskCardPressedIdChange: (id: string) => void = () => {}
  /** 更多操作（点击卡片右上角 ⋯，由页面弹出操作面板：微调 / 删除） */
  @Event onMoreActions: (task: AiGeneratedTask) => void = () => {}

  build() {
    Column({ space: 8 }) {
      // 标题行：序号 + 任务名 + 更多操作(⋯)
      Row({ space: 8 }) {
        Text(this.indexLabel)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.primary_color'))
          .backgroundColor($r('app.color.primary_color_bg'))
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(DimensConstants.RADIUS_XS)

        Text(this.safeTaskName)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        if (!this.isConfirmed) {
          Text('⋯')
            .fontSize(16)
            .fontColor($r('app.color.text_tertiary'))
            .padding({ left: 8, right: 2, top: 2, bottom: 2 })
            .onClick((): void => {
              this.onMoreActions(this.task)
            })
            .accessibilityText(getContext(this).resourceManager.getStringSync($r('app.string.ai_task_more_actions').id))
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 元信息行：时长 / 步骤数（点击展开）/ 优先级
      Row({ space: 6 }) {
        Text(formatEstimatedDuration(safeEstimatedTimeUtil(this.task.estimatedTime), getContext(this).resourceManager))
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
          .backgroundColor($r('app.color.bg_tag'))
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(DimensConstants.RADIUS_M)

        if (this.safeSteps.length > 0) {
          Row({ space: 2 }) {
            Text(this.safeSteps.length.toString() +
              getContext(this).resourceManager.getStringSync($r('app.string.route_steps_count_suffix').id))
              .fontSize(11)
              .fontColor($r('app.color.primary_color'))

            SymbolGlyph(this.isExpanded ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
              .fontSize(11)
              .fontColor([$r('app.color.primary_color')])
          }
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor($r('app.color.primary_color_bg'))
          .borderRadius(DimensConstants.RADIUS_M)
          .onClick((): void => {
            this.onToggleExpand(this.index)
          })
          .accessibilityText(this.isExpanded ?
            getContext(this).resourceManager.getStringSync($r('app.string.ai_collapse_steps').id) :
            getContext(this).resourceManager.getStringSync($r('app.string.ai_expand_steps').id) +
              this.safeSteps.length.toString() +
              getContext(this).resourceManager.getStringSync($r('app.string.route_steps_count_suffix').id))
        }

        Blank()

        Text(priorityLabelUtil(this.task.priority))
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(priorityTextColorUtil(this.task.priority))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 展开的步骤（左侧时间轴，紧凑行高）
      if (this.isExpanded && this.safeSteps.length > 0) {
        Column({ space: 6 }) {
          ForEach(this.safeSteps, (step: TaskStep, stepIndex: number): void => {
            Row({ space: 8 }) {
              Text((stepIndex + 1).toString())
                .fontSize(11)
                .fontColor($r('app.color.primary_color'))
                .fontWeight(FontWeight.Medium)
                .width(16)
                .textAlign(TextAlign.Center)
              Text(step.text)
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .layoutWeight(1)
                .lineHeight(18)
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
          }, (step: TaskStep, stepIndex: number): string =>
            // key 改用稳定 id（原为「下标 + 任务 id」拼接，删中间项会让后续全部换 key）
            step.id.length > 0 ? step.id : ('ai_step_' + stepIndex.toString() + '_' + this.task.id))
        }
        .width('100%')
        .padding({ left: 10, top: 4, bottom: 2 })
        .border({ width: { left: 2 }, color: $r('app.color.primary_color_bg') })
        .margin({ top: 2 })
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 12, bottom: 12 })
    .backgroundColor(this.pressedTaskCardId === this.task.id ?
      $r('app.color.bg_tag') : $r('app.color.bg_card'))
    .borderRadius(DimensConstants.RADIUS_L)
    .border({ width: { left: 3 }, color: priorityTextColorUtil(this.task.priority) })
    .shadow({ radius: 8, color: $r('app.color.shadow_card'), offsetX: 0, offsetY: 2 })
    .alignItems(HorizontalAlign.Start)
    .animation(MotionConstants.pressParam())
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down) {
        this.onTaskCardPressedIdChange(this.task.id)
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.onTaskCardPressedIdChange('')
      }
    })
  }

  /** 序号标签（01 / 02 …） */
  private get indexLabel(): string {
    const n: number = this.index + 1
    return n < 10 ? '0' + n.toString() : n.toString()
  }

  /** 防空任务名 */
  private get safeTaskName(): string {
    return (this.task.taskName && this.task.taskName.length > 0) ?
      this.task.taskName : (getContext(this).resourceManager.getStringSync($r('app.string.ai_task_fallback_prefix').id) + (this.index + 1).toString())
  }

  /** 防空步骤数组 */
  private get safeSteps(): TaskStep[] {
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
  /** 宽屏双栏：任务卡片 / 确认按钮改由右侧方案栏呈现，对话流内只保留文字 */
  @Param hidePlanCards: boolean = false

  /** 切换任务步骤展开/收起 */
  @Event onToggleExpand: (messageId: string, taskIndex: number) => void = (_m: string, _i: number) => {}
  /** 任务卡片按压态 ID 变更回调 */
  @Event onTaskCardPressedIdChange: (id: string) => void = (_id: string) => {}
  /** 更多操作（⋯ → 由页面弹出微调/删除操作面板） */
  @Event onMoreActions: (messageId: string, task: AiGeneratedTask) => void = (_m: string, _t: AiGeneratedTask) => {}
  /** 确认使用此方案（加入路线） */
  @Event onConfirmPlan: (messageId: string) => void = (_m: string) => {}
  /** 举报本条 AI 生成内容 */
  @Event onReportContent: (messageId: string) => void = (_m: string) => {}

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
            } else if (!this.message.isStreaming && this.hidePlanCards && this.message.tasks.length > 0) {
              // 宽屏双栏：方案消息仅有结构化任务、无说明文字时给一句引导，避免对话流空白
              Text($r('app.string.ai_plan_generated_hint'))
                .fontSize(15)
                .fontColor($r('app.color.text_secondary'))
                .lineHeight(22)
                .textAlign(TextAlign.Start)
                .padding({ left: 16, right: 16, top: 11, bottom: 11 })
                .backgroundColor($r('app.color.bg_card'))
                .borderRadius({ topLeft: 6, topRight: 18, bottomLeft: 18, bottomRight: 18 })
                .constraintSize({ maxWidth: '82%' })
                .shadow({ radius: 6, color: $r('app.color.shadow_card'), offsetX: 0, offsetY: 1 })
            }

            // 任务卡片列表（仅当有任务、且非宽屏双栏时显示）
            if (this.message.tasks.length > 0 && !this.hidePlanCards) {
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
                    .borderRadius(DimensConstants.RADIUS_M)
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
                    isConfirmed: this.message.isConfirmed,
                    onToggleExpand: (idx: number): void => { this.onToggleExpand(this.message.id, idx) },
                    onTaskCardPressedIdChange: (id: string): void => { this.onTaskCardPressedIdChange(id) },
                    onMoreActions: (t: AiGeneratedTask): void => { this.onMoreActions(this.message.id, t) }
                  })
                }, (task: AiGeneratedTask): string => this.message.id + '_' + task.id)
              }
              .width('100%')
              .padding(14)
              .backgroundColor($r('app.color.bg_card'))
              .borderRadius(DimensConstants.RADIUS_L)
              .constraintSize({ maxWidth: '88%' })
              .shadow({ radius: 6, color: $r('app.color.shadow_card'), offsetX: 0, offsetY: 1 })
            }
          }

          // 确认使用此方案按钮（仅当 AI 回复携带任务且未确认、且非宽屏双栏时显示）
          if (!this.message.isStreaming && this.message.tasks.length > 0 && !this.hidePlanCards) {
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
                .borderRadius(DimensConstants.RADIUS_XL)
                .shadow({ radius: 4, color: $r('app.color.primary_color_bg'), offsetX: 0, offsetY: 2 })
                .onClick((): void => {
                  this.onConfirmPlan(this.message.id)
                })
            }
          }

          // AI 生成内容显式标识 + 举报入口（合规要求：显式标识 + 便捷举报）
          if (!this.message.isStreaming &&
            (this.message.text.length > 0 || this.message.tasks.length > 0)) {
            Row({ space: 8 }) {
              Text($r('app.string.ai_content_label'))
                .fontSize(11)
                .fontColor($r('app.color.text_tertiary'))
              Text('·')
                .fontSize(11)
                .fontColor($r('app.color.text_tertiary'))
              Text($r('app.string.ai_content_report'))
                .fontSize(11)
                .fontColor($r('app.color.primary_color'))
                .padding({ top: 10, bottom: 10, left: 4, right: 4 })
                .onClick((): void => {
                  this.onReportContent(this.message.id)
                })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
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
    // ⚠️ 必须是「横向滚动单行」，不能用 Flex wrap：
    //    手机 360vp 宽下一行只放得下 2 个芯片，wrap 会折成 2×2（用户反馈"两行太丑"）；
    //    横滑行露出约 2.5 个芯片，半截芯片天然暗示可滑动；平板一行全见，视觉与原版一致。
    //    横滑与页面竖滑方向正交，ArkUI 按手势主方向分发，无冲突。
    Scroll() {
      Row({ space: 8 }) {
        ForEach(SCENARIO_CHIPS, (chip: ScenarioChip): void => {
          Text(chip.text)
            .fontSize(13)
            .fontColor(this.pressedChipId === chip.id ?
              $r('app.color.text_inverse') : $r('app.color.primary_color'))
            .backgroundColor(this.pressedChipId === chip.id ?
              $r('app.color.primary_color') : $r('app.color.primary_color_bg'))
            .padding({ left: 14, right: 14, top: 7, bottom: 7 })
            .borderRadius(DimensConstants.RADIUS_L)
            .border({ width: 0.5, color: $r('app.color.divider') })
            .scale(this.pressedChipId === chip.id ?
              { x: 0.96, y: 0.96 } : { x: 1, y: 1 })
            .animation(MotionConstants.pressParam())
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
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .width('100%')
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
      .borderRadius(DimensConstants.RADIUS_L)
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
  /** 是否存在历史方案（≥2 条）：为真时右栏标题标「最新」，与左侧历史方案区分 */
  @Param hasPlanHistory: boolean = false
  /** 侧栏独立展开状态 Map<messageId_taskIndex, true> */
  @Param expandedIndices: Map<string, boolean> = new Map()
  /** 任务卡按压态 ID */
  @Param pressedTaskCardId: string = ''
  /** 展开/收起回调 */
  @Event onToggleExpand: (messageId: string, taskIndex: number) => void = (_m: string, _i: number) => {}
  /** 按压态变更回调 */
  @Event onTaskCardPressedIdChange: (id: string) => void = (_id: string) => {}
  /** 更多操作（⋯ → 由页面弹出微调/删除操作面板） */
  @Event onMoreActions: (messageId: string, task: AiGeneratedTask) => void = (_m: string, _t: AiGeneratedTask) => {}
  /** 一键展开/收起全部任务步骤 */
  @Event onToggleAllExpand: (messageId: string, expand: boolean) => void = (_m: string, _e: boolean) => {}
  /** 确认方案回调 */
  @Event onConfirmPlan: (messageId: string) => void = (_m: string) => {}
  /** 举报本方案内容 */
  @Event onReportContent: (messageId: string) => void = (_m: string) => {}

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

  /** 摘要文案：N 个任务 · 共 X（时长由 formatEstimatedDuration 本地化） */
  private get summaryText(): string {
    const tasks: Array<AiGeneratedTask> = this.getPlanTasks()
    if (tasks.length === 0) {
      return ''
    }
    let totalMinutes: number = 0
    for (let i: number = 0; i < tasks.length; i++) {
      totalMinutes += safeEstimatedTimeUtil(tasks[i].estimatedTime)
    }
    const rm = getContext(this).resourceManager
    return tasks.length.toString() + rm.getStringSync($r('app.string.ai_plan_summary_tasks_suffix').id) +
      rm.getStringSync($r('app.string.ai_plan_summary_total_infix').id) +
      formatEstimatedDuration(totalMinutes, rm)
  }

  /** 是否全部任务的步骤都已展开（用于「全部展开/收起」按钮文案） */
  private get isAllExpanded(): boolean {
    const tasks: Array<AiGeneratedTask> = this.getPlanTasks()
    if (tasks.length === 0) {
      return false
    }
    const messageId: string = this.getPlanMessageId()
    for (let i: number = 0; i < tasks.length; i++) {
      if (this.expandedIndices.get(messageId + '_' + i.toString()) !== true) {
        return false
      }
    }
    return true
  }

  build() {
    Column() {
      // 标题行：标题 + 摘要（N 个任务 · 共 X）+ 全部展开/收起
      Row({ space: 8 }) {
        Text($r('app.string.ai_plan_side_title'))
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))

        // 有历史方案时才标「最新」：右栏恒为当前版，历史方案卡片在左侧对话流
        if (this.planMessage !== null && this.hasPlanHistory) {
          Text($r('app.string.ai_plan_latest_badge'))
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.primary_color'))
            .backgroundColor($r('app.color.primary_color_bg'))
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(DimensConstants.RADIUS_XS)
        }

        if (this.planMessage !== null) {
          Text(this.summaryText)
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          if (this.getPlanTasks().length > 0) {
            Text(this.isAllExpanded ? $r('app.string.ai_plan_collapse_all') : $r('app.string.ai_plan_expand_all'))
              .fontSize(12)
              .fontColor($r('app.color.primary_color'))
              .onClick((): void => {
                this.onToggleAllExpand(this.getPlanMessageId(), !this.isAllExpanded)
              })
          }
        } else {
          Blank()
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 16, right: 16, top: 16, bottom: 8 })

      if (this.planMessage !== null) {
        Scroll() {
          Column({ space: 8 }) {
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
                onMoreActions: (t: AiGeneratedTask): void => { this.onMoreActions(this.getPlanMessageId(), t) }
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

        // AI 生成内容显式标识 + 举报入口（合规要求：显式标识 + 便捷举报）
        Row({ space: 8 }) {
          Text($r('app.string.ai_content_label'))
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
          Text('·')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
          Text($r('app.string.ai_content_report'))
            .fontSize(11)
            .fontColor($r('app.color.primary_color'))
            .padding({ top: 4, bottom: 4, left: 4, right: 4 })
            .onClick((): void => {
              this.onReportContent(this.getPlanMessageId())
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ left: 16, right: 16, top: 8, bottom: 12 })
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

