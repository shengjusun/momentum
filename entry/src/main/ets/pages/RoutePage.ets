// 路线页：进度概览 + 分类筛选 + 目标卡片列表（含里程碑时间线），点击卡片进入目标详情

import { promptAction } from '@kit.ArkUI'
import { DimensConstants } from '../common/constants/DimensConstants'
import { RoutePageViewModel, routeVM } from '../viewmodel/RoutePageViewModel'
import { GoalCardItem, MilestoneNode, AiGeneratedTask, GoalDetailRouteNavParam,
  TaskPriority, TaskStatus, buildGoalCardItem } from '../model/Models'
import { globalNavStack, ROUTE_NAME, globalTabsController, TAB_INDEX } from '../common/RouterManager'
import { Logger } from '../common/utils/Logger'
import { safeStringUtil, safeNumberUtil, formatDeadlineUtil } from '../common/utils/SafeUtils'
import { homeVM } from '../viewmodel/HomeViewModel'
import { GoalCardDataSource } from '../common/datasource/TaskDataSource'
import { priorityLabelUtil, priorityBgColorUtil, priorityTextColorUtil } from '../common/utils/PriorityUtils'
import { CommonTitleBar } from '../common/components/CommonTitleBar'
import { StateView, StateMode } from '../common/components/StateView'
import { GripAwarenessService, GripHand } from '../common/services/GripAwarenessService'
import { common } from '@kit.AbilityKit'
import { safeAreaHelper } from '../common/utils/SafeAreaHelper'
import { CommonConstants } from '../common/constants/CommonConstants'
import { StorageManager } from '../common/utils/StorageManager'
import { aiPromptBridge } from '../common/utils/AIPromptBridge'
import { MotionConstants } from '../common/constants/MotionConstants'
import { MotionHelper } from '../common/utils/MotionHelper'
import { eventBus, EventType, GoalProgressChangedPayload } from '../common/event/AppEventBus'

/* ============================================================
 * 子组件 1：L2TaskItemComp — 单个 L2 任务项（含"加入待办"按钮）
 * ============================================================ */

@ReusableV2
@ComponentV2
struct L2TaskItemComp {
  @Param goalId: string = ''
  @Param task: AiGeneratedTask = new AiGeneratedTask('', '', 0, TaskPriority.MEDIUM, [], TaskStatus.PENDING)
  @Param taskIndex: number = 0
  @Param pressedAddTaskId: string = ''
  @Param isInTodo: boolean = false
  @Event onExtractToHome: (goalId: string, taskId: string) => void = (_goalId: string, _taskId: string) => {}

  build() {
    Row() {
      // 左侧蓝色竖条
      Column() {}
        .width(3)
        .height('10%')
        .backgroundColor($r('app.color.primary_color'))
        .borderRadius(2)
        .margin({ right: 8 })

      // 右侧内容
      Row({ space: 6 }) {
        // 任务名称 + 元数据
        Column({ space: 2 }) {
          Text(safeStringUtil(this.task.taskName,
            getContext(this).resourceManager.getStringSync($r('app.string.default_unnamed_task').id)))
            .fontSize(13)
            .fontColor($r('app.color.text_primary'))
            .fontWeight(FontWeight.Medium)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          // 元数据：时长 + 步骤数 + 优先级
          Row({ space: 6 }) {
            Text(safeNumberUtil(this.task.estimatedTime, 0).toString() + ' min')
              .fontSize(10)
              .fontColor($r('app.color.text_tertiary'))

            if (Array.isArray(this.task.steps) && this.task.steps.length > 0) {
              Text('·')
                .fontSize(10)
                .fontColor($r('app.color.text_tertiary'))

              Text(this.task.steps.length.toString() +
                getContext(this).resourceManager.getStringSync($r('app.string.route_steps_count_suffix').id))
                .fontSize(10)
                .fontColor($r('app.color.text_tertiary'))
            }

            Text(priorityLabelUtil(this.task.priority))
              .fontSize(9)
              .fontColor(priorityTextColorUtil(this.task.priority))
              .fontWeight(FontWeight.Medium)
              .backgroundColor(priorityBgColorUtil(this.task.priority))
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .borderRadius(6)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // "+ 加入"
        Text(this.isInTodo ? $r('app.string.route_added') : $r('app.string.route_add_plus'))
          .fontSize(11)
          .fontColor(this.isInTodo ? $r('app.color.text_tertiary') : $r('app.color.primary_color'))
          .fontWeight(FontWeight.Medium)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor(this.isInTodo ? $r('app.color.bg_tag') : $r('app.color.primary_color_bg'))
          .borderRadius(DimensConstants.RADIUS_M)
          .enabled(!this.isInTodo)
          .onClick((): void => {
            if (!this.isInTodo) {
              this.onExtractToHome(this.goalId, this.task.id)
            }
          })
      }
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(DimensConstants.RADIUS_M)
    .shadow({ radius: 4, color: $r('app.color.shadow_card'), offsetX: 0, offsetY: 1 })
    .alignItems(VerticalAlign.Center)
  }
}

/* ============================================================
 * 子组件 4：L2TaskListSection — L2 任务列表区
 * ============================================================ */

@ComponentV2
struct L2TaskListSection {
  @Param goalId: string = ''
  @Param tasks: AiGeneratedTask[] = []
  @Param expandedTaskGoalId: string = ''
  @Param pressedAddTaskId: string = ''
  @Event onToggleExpand: (goalId: string) => void = (_goalId: string) => {}
  @Event onExtractToHome: (goalId: string, taskId: string) => void = (_goalId: string, _taskId: string) => {}

  build() {
    if (this.tasks.length > 0) {
      Column({ space: 8 }) {
        // 标题行
        Row() {
          Text(getContext(this).resourceManager.getStringSync($r('app.string.route_recommended_tasks').id) +
            this.tasks.length.toString() + getContext(this).resourceManager.getStringSync($r('app.string.route_recommended_tasks_suffix').id))
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)

          if (this.tasks.length > 3) {
            Text(this.expandedTaskGoalId === this.goalId ?
              $r('app.string.route_collapse_steps') : $r('app.string.route_expand_steps'))
              .fontSize(11)
              .fontColor($r('app.color.primary_color'))
              .accessibilityText(this.expandedTaskGoalId === this.goalId ?
                $r('app.string.route_collapse_tasks') : $r('app.string.route_expand_tasks'))
              .onClick((): void => {
                this.onToggleExpand(this.goalId)
              })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        // 任务列表（最多 3 条，超过根据 expandedTaskGoalId 决定是否展开）
        ForEach(
          this.expandedTaskGoalId === this.goalId ? this.tasks : this.tasks.slice(0, 3),
          (task: AiGeneratedTask, idx: number): void => {
            L2TaskItemComp({
              goalId: this.goalId,
              task: task,
              taskIndex: idx,
              pressedAddTaskId: this.pressedAddTaskId,
              isInTodo: homeVM.isTaskInTodo(task.id),
              onExtractToHome: (goalId: string, taskId: string): void => {
                this.onExtractToHome(goalId, taskId)
              }
            })
          },
          (task: AiGeneratedTask, idx: number): string => safeStringUtil(task.id, 'task_' + idx.toString())
        )
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }
}

/* ============================================================
 * 子组件 5：GoalCardComp — 目标卡片
 *   - 直接接收 goal 对象，消除 30+ 次 viewModel.filteredGoals[index] 重复访问
 *   - 所有 @Local 状态保留在根组件，通过 @Param 只读 + @Event 回调
 *   - AI 确认方案后 routeVM.addGoal() → goals(@Trace) 变更 → filteredGoals(@Computed) 更新 → 此卡片出现在列表
 * ============================================================ */

@ReusableV2
@ComponentV2
struct GoalCardComp {
  @Param goal: GoalCardItem = new GoalCardItem('', '', '', '', 0, '', 0, 0, 0, [], [])
  @Param pressedGoalId: string = ''
  @Param expandedTaskGoalId: string = ''
  @Param pressedAddTaskId: string = ''
  @Event onGoalClick: (goal: GoalCardItem) => void = (_goal: GoalCardItem) => {}
  @Event onGoalPressedIdChange: (id: string) => void = (_id: string) => {}
  @Event onTaskToggle: (goalId: string) => void = (_goalId: string) => {}
  @Event onExtractToHome: (goalId: string, taskId: string) => void = (_goalId: string, _taskId: string) => {}

  build() {
    if (!this.goal || !this.goal.id) {
      // 防空：渲染占位
      Column() {
        Text($r('app.string.route_task_data_error'))
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
      }
      .width('100%')
      .padding(12)
      .backgroundColor($r('app.color.bg_card'))
      .borderRadius(DimensConstants.RADIUS_L)
    } else {
      Column({ space: 10 }) {
        // 顶部行：标签 + 展开提示
        Row() {
          if (this.goal.category && this.goal.category.length > 0 &&
            this.goal.category !== getContext(this).resourceManager.getStringSync($r('app.string.category_all').id)) {
            Text(safeStringUtil(this.goal.category,
              getContext(this).resourceManager.getStringSync($r('app.string.default_other_category').id)))
              .fontSize(10)
              .fontColor($r('app.color.text_secondary'))
              .backgroundColor($r('app.color.bg_tag'))
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(DimensConstants.RADIUS_XS)
          }
          Blank()
        }
        .width('100%')

        // 左文右环布局
        Row({ space: 16 }) {
          // 左侧：目标名称 + 描述 + 里程碑信息
          Column({ space: 6 }) {
            Text(safeStringUtil(this.goal.name,
              getContext(this).resourceManager.getStringSync($r('app.string.default_unnamed_goal').id)))
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')

            if (this.goal.description && this.goal.description.length > 0) {
              Text(safeStringUtil(this.goal.description, ''))
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }

            // 目标摘要：时长 + 截止时间
            Row({ space: 8 }) {
              Text(safeStringUtil(this.goal.duration, ''))
                .fontSize(12)
                .fontColor($r('app.color.text_tertiary'))

              Text('·')
                .fontSize(12)
                .fontColor($r('app.color.text_tertiary'))

              Text(getContext(this).resourceManager.getStringSync($r('app.string.route_deadline_prefix').id) +
                formatDeadlineUtil(this.goal.deadline))
                .fontSize(12)
                .fontColor($r('app.color.text_tertiary'))
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          // 右侧：大号进度环
          Stack({ alignContent: Alignment.Center }) {
            Progress({ value: this.goal.progress, total: 100, type: ProgressType.Ring })
              .width(56)
              .height(56)
              .style({ strokeWidth: 6 })
              .color(this.goal.progress === 100 ?
                $r('app.color.success_color') : $r('app.color.primary_color'))
              .backgroundColor($r('app.color.bg_progress_track'))

            Text(safeNumberUtil(this.goal.progress, 0).toString() + '%')
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
          }
          .width(56)
          .height(56)
          .accessibilityText(getContext(this).resourceManager.getStringSync($r('app.string.acc_progress').id) +
            safeNumberUtil(this.goal.progress, 0).toString() + '%')
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)


        // L2 任务列表 + 摘取流入口
        if (Array.isArray(this.goal.tasks) && this.goal.tasks.length > 0) {
          Divider()
            .color($r('app.color.divider'))
            .strokeWidth(1)
            .width('100%')
            .margin({ top: 4 })

          L2TaskListSection({
            goalId: this.goal.id,
            tasks: this.goal.tasks,
            expandedTaskGoalId: this.expandedTaskGoalId,
            pressedAddTaskId: this.pressedAddTaskId,
            onToggleExpand: (goalId: string): void => {
              this.onTaskToggle(goalId)
            },
            onExtractToHome: (goalId: string, taskId: string): void => {
              this.onExtractToHome(goalId, taskId)
            }
          })
        }
      }
      .width('100%')
      .padding(16)
      .backgroundColor($r('app.color.bg_card'))
      .borderRadius(DimensConstants.RADIUS_L)
      .shadow({ radius: 4, color: $r('app.color.shadow_card'), offsetX: 0, offsetY: 1 })
      .scale({
        x: this.pressedGoalId === this.goal.id ? 0.98 : 1,
        y: this.pressedGoalId === this.goal.id ? 0.98 : 1
      })
      .animation(MotionConstants.pressParam())
      .accessibilityText(getContext(this).resourceManager.getStringSync($r('app.string.route_accessibility_goal_prefix').id) +
        safeStringUtil(this.goal.name,
          getContext(this).resourceManager.getStringSync($r('app.string.default_unnamed_goal').id)) +
        getContext(this).resourceManager.getStringSync($r('app.string.route_accessibility_progress_infix').id) + safeNumberUtil(this.goal.progress, 0).toString() + '%，' +
        safeStringUtil(this.goal.category,
          getContext(this).resourceManager.getStringSync($r('app.string.default_other_category').id)) +
        '，' +
        getContext(this).resourceManager.getStringSync($r('app.string.route_deadline_prefix').id) +
        formatDeadlineUtil(this.goal.deadline))
      .onTouch((event: TouchEvent): void => {
        if (event.type === TouchType.Down) {
          this.onGoalPressedIdChange(this.goal.id)
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.onGoalPressedIdChange('')
        }
      })
      .onClick((): void => {
        this.onGoalClick(this.goal)
      })
    }
  }
}

/* ============================================================
 * 子组件 6：CategoryChipComp — 分类筛选 chip
 * ============================================================ */

@ReusableV2
@ComponentV2
struct CategoryChipComp {
  @Param label: string = ''
  @Param isActive: boolean = false
  @Param pressedCategory: string = ''
  @Event onCategoryPressedIdChange: (id: string) => void = (_id: string) => {}
  @Event onCategoryClick: (label: string) => void = (_label: string) => {}

  build() {
    Text(this.label)
      .fontSize(12)
      .fontColor(this.isActive ?
        $r('app.color.text_inverse') : $r('app.color.text_secondary'))
      .backgroundColor(this.isActive ?
        $r('app.color.primary_color') : Color.Transparent)
      .padding({ left: 14, right: 14, top: 6, bottom: 6 })
      .borderRadius(DimensConstants.RADIUS_XL)
      .border({
        width: 1,
        color: this.isActive ?
          $r('app.color.primary_color') : $r('app.color.bg_progress_track')
      })
      .opacity(this.pressedCategory === this.label ? 0.7 : 1.0)
      .accessibilityText(getContext(this).resourceManager.getStringSync($r('app.string.acc_category_filter_prefix').id) + this.label)
      .onTouch((event: TouchEvent): void => {
        if (event.type === TouchType.Down) {
          this.onCategoryPressedIdChange(this.label)
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.onCategoryPressedIdChange('')
        }
      })
      .onClick((): void => {
        this.onCategoryClick(this.label)
      })
  }
}

/* ============================================================
 * 子组件 7：RouteOverviewSection — 已删除
 * 数据概览已迁移至 ProfilePage.TaskDataOverviewBuilder（含总百分比环 + 三态数字）
 * RoutePage 仅保留 GoalCardComp 内的每目标百分比环
 * ============================================================ */

/* ============================================================
 * 子组件 8：RouteEmptySection — 空态引导区
 * ============================================================ */

@ComponentV2
struct RouteEmptySection {
  /** 去 AI 开始：prompt 非空 = 预填该文本到 AI 输入框；空串 = 只聚焦输入框 */
  @Event onStartAI: (prompt: string) => void = () => {}
  @Event onCreateGoal: () => void = () => {}

  /** 「试试这些」示例目标（与三语言资源一一对应） */
  private exampleKeys: Resource[] = [
    $r('app.string.empty_route_example1'),
    $r('app.string.empty_route_example2'),
    $r('app.string.empty_route_example3')
  ]

  /**
   * 空态（**一个目标都没有**）—— 三段式
   *
   * 迭代记录：第一版"一张引导卡垂直居中"只解决了头重脚轻，解决不了"空"——
   * 内容区约 632vp、卡片仅约 126vp，空白仍占 ~80%，用户反馈"还是太空"。
   * 根因是**信息密度**：空态只回答了"这里没有目标"，没回答"我能做什么 /
   * 这里将来长什么样"。三段各司其职：
   *   ① 引导卡：说明 + **伪输入框**（点击直达 AI 并聚焦）+ 双按钮 ——
   *      用用户最熟悉的"输入框"形态暗示"这里可以开始说话"
   *   ② 起势怎么用：三步说明，建立"路线页会长成什么样"的预期
   *   ③ 试试这些：三个可点示例，降低"不知道说什么"的启动门槛
   */
  build() {
    Column({ space: 12 }) {
      this.GuideCard()
      this.HowtoCard()
      this.ExamplesBlock()
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** ① 引导卡（沿用「路线」Tab 同一枚符号，语义一致） */
  @Builder
  GuideCard() {
    Column() {
      Row({ space: 12 }) {
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.route_plan'))
            .fontSize(22)
            .fontColor([$r('app.color.primary_color')])
        }
        .width(44)
        .height(44)
        .borderRadius(22)
        .backgroundColor($r('app.color.primary_color_bg'))

        Column({ space: 4 }) {
          Text($r('app.string.empty_route_title'))
            .fontSize(CommonConstants.FONT_SIZE_BODY)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
            .textAlign(TextAlign.Start)

          Text($r('app.string.empty_route_subtitle'))
            .fontSize(CommonConstants.FONT_SIZE_XS)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 伪输入框：不是真输入框 —— 点击切到 AI 页并聚焦那边的主输入框，
      // 让用户在那里说目标（AI 才有上下文做拆解），本页不再做第二套输入
      Row({ space: 8 }) {
        Text($r('app.string.empty_route_placeholder'))
          .fontSize(CommonConstants.FONT_SIZE_SMALL)
          .fontColor($r('app.color.text_tertiary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        SymbolGlyph($r('sys.symbol.wand_and_stars'))
          .fontSize(16)
          .fontColor([$r('app.color.primary_color')])
      }
      .width('100%')
      .height(40)
      .padding({ left: 14, right: 12 })
      .backgroundColor($r('app.color.bg_search'))
      .borderRadius(DimensConstants.RADIUS_M)
      .margin({ top: 12 })
      .onClick((): void => {
        this.onStartAI('')
      })

      Row({ space: 10 }) {
        Button($r('app.string.btn_go_ai'))
          .type(ButtonType.Capsule)
          .height(36)
          .padding({ left: 18, right: 18 })
          .backgroundColor($r('app.color.primary_color'))
          .fontColor($r('app.color.text_inverse'))
          .fontSize(CommonConstants.FONT_SIZE_SMALL)
          .fontWeight(FontWeight.Medium)
          .onClick((): void => {
            this.onStartAI('')
          })

        Button($r('app.string.empty_route_manual'))
          .type(ButtonType.Capsule)
          .height(36)
          .padding({ left: 18, right: 18 })
          .backgroundColor($r('app.color.bg_tag'))
          .fontColor($r('app.color.text_secondary'))
          .fontSize(CommonConstants.FONT_SIZE_SMALL)
          .onClick((): void => {
            this.onCreateGoal()
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.Start)
      .margin({ top: 12 })
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(DimensConstants.RADIUS_L)
    .alignItems(HorizontalAlign.Start)
  }

  /** ② 起势怎么用（三步说明：纯说明，不冒充数据） */
  @Builder
  HowtoCard() {
    Column({ space: 10 }) {
      Text($r('app.string.empty_route_howto_title'))
        .fontSize(CommonConstants.FONT_SIZE_XS)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .margin({ bottom: 2 })

      this.StepRow('1', $r('app.string.empty_route_step1'))
      this.StepRow('2', $r('app.string.empty_route_step2'))
      this.StepRow('3', $r('app.string.empty_route_step3'))
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(DimensConstants.RADIUS_L)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  StepRow(no: string, label: Resource) {
    Row({ space: 10 }) {
      Stack({ alignContent: Alignment.Center }) {
        Text(no)
          .fontSize(CommonConstants.FONT_SIZE_XS)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.primary_color'))
      }
      .width(20)
      .height(20)
      .borderRadius(10)
      .backgroundColor($r('app.color.primary_color_bg'))

      Text(label)
        .fontSize(CommonConstants.FONT_SIZE_SMALL)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /** ③ 试试这些：可点示例标签，点了带文本直达 AI */
  @Builder
  ExamplesBlock() {
    Column({ space: 8 }) {
      Text($r('app.string.empty_route_examples_title'))
        .fontSize(CommonConstants.FONT_SIZE_XS)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')

      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.exampleKeys, (key: Resource): void => {
          Text(key)
            .fontSize(CommonConstants.FONT_SIZE_XS)
            .fontColor($r('app.color.text_secondary'))
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .backgroundColor($r('app.color.bg_tag'))
            .borderRadius(DimensConstants.RADIUS_L)
            .margin({ right: 8, bottom: 8 })
            .onClick((): void => {
              this.onStartAI(this.exampleTextOf(key))
            })
        }, (key: Resource): string => key.id.toString())
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 取示例文案的原文（投递给 AI 页预填） */
  private exampleTextOf(key: Resource): string {
    return getContext(this).resourceManager.getStringSync(key.id)
  }
}

/* ============================================================
 * 子组件 8b：RouteFilteredEmptySection — 筛选后为空的提示
 * ============================================================ */

/**
 * 必须与「一个目标都没有」区分开：这里用户**已经有目标**，只是当前分类下没有。
 *
 * 排查发现原实现把两种情况合成了同一句"还没有目标，去 AI 拆解" ——
 * 用户明明有 3 个目标、只是筛到了空分类，页面却告诉他"还没有目标"，
 * 第一反应是"我的数据丢了"。所以这里只说明分类为空，并给回「全部」的出口。
 */
@ComponentV2
struct RouteFilteredEmptySection {
  @Event onClearFilter: () => void = () => {}

  build() {
    Column({ space: 8 }) {
      Text($r('app.string.empty_route_filtered_title'))
        .fontSize(CommonConstants.FONT_SIZE_BODY)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .textAlign(TextAlign.Center)

      Text($r('app.string.empty_route_filtered_subtitle'))
        .fontSize(CommonConstants.FONT_SIZE_XS)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .textAlign(TextAlign.Center)

      Button($r('app.string.empty_route_filtered_action'))
        .type(ButtonType.Capsule)
        .height(34)
        .padding({ left: 18, right: 18 })
        .backgroundColor($r('app.color.bg_tag'))
        .fontColor($r('app.color.text_secondary'))
        .fontSize(CommonConstants.FONT_SIZE_SMALL)
        .margin({ top: 6 })
        .onClick((): void => {
          this.onClearFilter()
        })
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 20, bottom: 20 })
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(DimensConstants.RADIUS_L)
    .alignItems(HorizontalAlign.Center)
  }
}

/* ============================================================
 * 根组件：RoutePage — 路线页
 * ============================================================ */

/**
 * 路线页组件（根组件）
 * AI 确认方案后 routeVM.addGoal() → goals(@Trace) 变更 → filteredGoals(@Computed) 更新 → 本页面列表刷新
 *
 * 刷新链路：
 *   routeVM.goals(@Trace) → filteredGoals(@Computed) → build() 重渲染 → onDidBuild() 更新 goalCount
 *   → @Monitor('goalCount') → isGoalDataSourceStale() → goalDataSource.updateAll() → LazyForEach 刷新
 * viewModel 是普通属性（非 @Local）：依赖 @ObservedV2 单例内部 @Trace 响应式追踪
 */
@ComponentV2
export struct RoutePage {
  private goalDataSource: GoalCardDataSource = new GoalCardDataSource()
  private prevGoalCount: number = -1
  /**
   * viewModel 改为普通属性（不再 @Local）
   *
   * 之前的错误写法：
   *   @Local viewModel: RoutePageViewModel = routeVM
   *
   * 问题分析：
   *   - @Local 是组件私有状态装饰器
   *   - 它无法深度代理外部全局单例内部 @Trace 属性的变化
   *   - 当 routeVM.goals / routeVM.filterCategory 改变时，本组件不会刷新
   *
   * 正确写法：
   *   viewModel: RoutePageViewModel = routeVM
   *
   * 原理：
   *   - routeVM 自身是 @ObservedV2 单例，goals/filterCategory 是 @Trace
   *   - 通过引用（this.viewModel.goals）访问时，ArkUI 会自动追踪 @Trace
   *   - 局部刷新依赖单例内部的响应式系统，不依赖组件本地的 @Local
   */
  viewModel: RoutePageViewModel = routeVM
  /**
   * 按压态 @Local 状态
   * 取代废弃的 .stateStyles
   */
  @Local pressedGoalId: string = ''
  /** 分类 chip 按压态 */
  @Local pressedCategory: string = ''
  /**
   * L2 任务列表展开状态
   * - 记录当前展开的 goalId（同一时间仅一个展开，避免 UI 过载）
   * - '' = 全部收起
   */
  @Local expandedTaskGoalId: string = ''

  /**
   * 单条 L2 任务"加入待办"按钮按压态
   * - 视觉反馈：避免用户连点导致重复添加
   */
  @Local pressedAddTaskId: string = ''
  private pressedTimer: number = -1
  /**
   * 追踪 filteredGoals 数量变化，驱动 DataSource 同步
   * 为什么需要这套机制：goalDataSource 是 filteredGoals 的独立副本，无响应式绑定
   * routeVM.addGoal() 修改 goals(@Trace) → filteredGoals(@Computed) 自动更新
   * 但 goalDataSource 不会自动同步，需要 @Local goalCount + @Monitor 手动触发 updateAll
   */
  @Local goalCount: number = -1
  @Monitor('goalCount')
  onGoalCountChange(): void {
    if (this.goalCount >= 0 && this.isGoalDataSourceStale()) {
      this.goalDataSource.updateAll(this.viewModel.filteredGoals)
      this.prevGoalCount = this.viewModel.filteredGoals.length
    }
  }

  /**
   * GOAL_PROGRESS_CHANGED 订阅 ID（用于精确注销；-1 = 未订阅）
   */
  private goalProgressCbId: number = -1

  /**
   * 目标进度变化 → 重同步目标数据源（2026-09-17 修复"目标详情与路线页进度环不同步"）
   *
   * 为什么必须有它：本页卡片列表走 LazyForEach + `goalDataSource`（`filteredGoals` 的
   *   **独立快照**），数据源只在收到通知时才重读数据。原先唯一的触发是
   *   `@Monitor('goalCount')`，而 `goalCount` 只数**数量**、`filteredGoals`(@Computed)
   *   **也不依赖单个目标的 progress** ⇒ 只改进度时本页既不重渲染、也不同步数据源，
   *   卡片进度环永远停在旧值。进度由 `routeVM` 在写 progress 的两处出口统一广播，
   *   这里订阅后强制重同步即可（数量变化仍走原 goalCount 通道，两条通道互不冲突）。
   */
  onGoalProgressChanged(payload: GoalProgressChangedPayload): void {
    Logger.info('RoutePage', 'GOAL_PROGRESS_CHANGED: goalId=' + payload.goalId +
      ', progress=' + payload.progress.toString() + ' → resync goalDataSource')
    this.forceSyncGoalDataSource()
  }

  /**
   * FAB 悬浮加号按钮位置（受智感握姿驱动）
   * - 'right': 右下（默认）
   * - 'left': 左下（左手握姿）
   */
  @Local fabSide: 'left' | 'right' = 'right'
  /** FAB 容器实测尺寸（onAreaChange 上报）：用 position 驱动换边必须知道容器宽高 */
  @Local fabAreaW: number = 0
  @Local fabAreaH: number = 0
  /** 是否启用「智感握姿」（设置页开关，默认开启） */
  @Local gripEnabled: boolean = true
  /**
   * 悬浮按钮是否显示（**全局偏好**，默认显示）
   * - 页面内**长按** FAB → 置 false（隐藏）
   * - 设置页「悬浮快捷按钮」开关 → 置 true（恢复）
   * 与 `gripEnabled` 相互独立：关掉握姿只是"不跟随换边"，按钮依然在。
   */
  @Local fabVisible: boolean = true
  /** FAB 尺寸与边距：与改造前保持一致（距底部 80vp、距左右各 24vp） */
  private readonly FAB_SIZE: number = 56
  private readonly FAB_EDGE: number = 24
  private readonly FAB_BOTTOM: number = 80

  /**
   * FAB 的 x 坐标
   * 换边必须走 position：它是可动画的渲染属性，配合 .animation() 才有"滑过去"的过渡感；
   * 原实现切换 Stack.alignContent（布局参数），属布局重排，只能瞬变 → 观感生硬。
   */
  private fabX(): number {
    const w: number = this.fabAreaW > 0 ? this.fabAreaW : 360
    if (this.fabSide === 'left') {
      return this.FAB_EDGE
    }
    return Math.max(this.FAB_EDGE, w - this.FAB_SIZE - this.FAB_EDGE)
  }

  /** FAB 的 y 坐标（等价于改造前的 margin.bottom = 80，避开底部悬浮 TabBar） */
  private fabY(): number {
    const h: number = this.fabAreaH > 0 ? this.fabAreaH : 780
    return Math.max(0, h - this.FAB_SIZE - this.FAB_BOTTOM)
  }

  /**
   * 按用户开关同步握姿订阅（设置页「智感握姿」）
   * - 开启：订阅；服务内部做能力探测与降级，不支持设备回退 'unknown' → FAB 保持右下
   * - 关闭：退订并把 FAB 复位右下
   * 幂等：重复调用安全（从设置页返回时也会调用）
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
   * 读取全局 FAB 显隐偏好（幂等：aboutToAppear / onPageShow 都会调）
   *
   * onPageShow 覆盖"从设置页返回"的场景 —— 用户在那里把按钮重新打开后，
   * 切回来必须立刻看到，不能等到重启。
   */
  private async loadFabVisible(): Promise<void> {
    this.fabVisible = await StorageManager.getPreferenceBool(
      CommonConstants.STORAGE_KEY_FAB_VISIBLE, true)
  }

  /**
   * 长按隐藏悬浮按钮
   *
   * 隐藏是**全局**的（首页与路线页共用同一个偏好）：它表达的是"我不需要这个按钮"，
   * 而不是"这一页不需要" —— 否则会出现"路线页藏起来了、首页还露着"的困惑。
   * 恢复入口在设置页「悬浮快捷按钮」，toast 里直接写明路径，避免用户找不到。
   */
  private handleFabLongPress(): void {
    if (!this.fabVisible) return
    this.fabVisible = false
    // 按钮都隐藏了，握姿订阅没有意义，顺手退订省电（设置页重新打开时会再订阅）
    this.gripService.unsubscribe()
    StorageManager.setPreferenceBool(CommonConstants.STORAGE_KEY_FAB_VISIBLE, false)
      .catch((e: Error): void => {
        Logger.warn('RoutePage', 'save fab visible failed: ' + e.message)
      })
    promptAction.showToast({
      message: getContext(this).resourceManager.getStringSync($r('app.string.toast_fab_hidden').id),
      duration: 2500
    })
  }

  /** 控制手动创建目标弹窗显隐 */
  @Local showCreateDialog: boolean = false
  /** 创建弹窗 - 目标名称 */
  @Local createGoalName: string = ''
  /** 创建弹窗 - 目标描述 */
  @Local createGoalDesc: string = ''
  /** 创建弹窗 - 分类 */
  @Local createGoalCategory: string = ''
  /** 创建弹窗 - 截止日期（毫秒时间戳，0 表示未设置） */
  @Local createGoalDeadline: number = 0
  /** 握姿感知服务单例 */
  private gripService: GripAwarenessService = GripAwarenessService.getInstance()

  /**
   * 持久化接入：await init 确保数据加载完成后再同步 DataSource
   * routeVM.init() 是异步方法，未 await 就调用 syncGoalDataSource 会导致 DataSource
   * 在 init 完成前被同步为空数组，LazyForEach 始终渲染空列表
   */
  async aboutToAppear(): Promise<void> {
    // ★ 游客模式：此处**不做**拦页跳转。
    //   路线页内容全部来自本地（routeVM），游客可正常浏览；需要登录的能力
    //   （AI 拆解等）在各触发点就地锁定 + 给引导词，符合《华为帐号登录管理细则》
    //   允许的"用户表现出意向后再提示"。
    //   原实现是 `if (!isLoggedIn) { navigateTo(LOGIN); return }`，三重问题：
    //     ① 与 `docs/上架素材/上架文案.md:93/98` 对市场承诺的
    //        「以游客身份体验全部本地功能」直接矛盾（材料与实现不一致 → 审核风险）；
    //     ② 与 09-11 合规改造（`MainTab` 注释：移除冷启动强登与各页跳转）回退冲突；
    //     ③ TabContent 子组件的 aboutToAppear 只在【首次切到该 Tab 时】执行一次，
    //        游客被弹去登录后返回再点「路线」就不再拦 —— 拦截只生效一次，行为不可预期。
    await routeVM.init(getContext(this))
    this.forceSyncGoalDataSource()

    // 订阅智感握姿，驱动 FAB 左右自适应（受设置页「智感握姿」开关控制）
    this.syncGripSubscription().catch((e: Error): void => {
      Logger.warn('RoutePage', 'syncGripSubscription failed: ' + e.message)
    })
    // 读取悬浮按钮显隐偏好（长按隐藏、设置页恢复，两处写同一个偏好）
    this.loadFabVisible().catch((e: Error): void => {
      Logger.warn('RoutePage', 'loadFabVisible failed: ' + e.message)
    })
    // 目标进度变化 → 重同步目标数据源（修复跨页面改进度后本页进度环不刷新的问题）
    // 幂等：重复 aboutToAppear 时先注销旧订阅，避免回调堆积
    if (this.goalProgressCbId > 0) {
      eventBus.off(EventType.GOAL_PROGRESS_CHANGED, this.goalProgressCbId)
    }
    this.goalProgressCbId = eventBus.on(EventType.GOAL_PROGRESS_CHANGED, (payload: Object): void => {
      this.onGoalProgressChanged(payload as GoalProgressChangedPayload)
    })
  }

  /**
   * build() 完成后检测 filteredGoals 变化并同步 DataSource
   * goalDataSource 是 filteredGoals 的独立副本，build() 中不能放赋值语句。
   * onDidBuild() 在 build() 之后执行，可安全更新 @Local goalCount，
   * 触发 @Monitor('goalCount') → isGoalDataSourceStale() → goalDataSource.updateAll()
   */
  onDidBuild(): void {
    const newCount: number = this.viewModel.filteredGoals.length
    if (this.goalCount !== newCount) {
      this.goalCount = newCount
    }
  }

  /**
   * 从详情页返回时刷新 DataSource
   * 用户在详情页可能修改了里程碑/步骤状态，返回后需重新同步
   */
  onPageShow(): void {
    // 原登录拦截已移除：RoutePage **非 @Entry**（是 TabContent 的子组件），
    // onPageShow 不保证触发（同一结论见 `HomePage.ets:500` 的注释），该拦截一直是死代码。
    // 从设置页返回时「智感握姿」与「悬浮快捷按钮」开关都可能已变化，重新同步
    this.syncGripSubscription().catch((e: Error): void => {
      Logger.warn('RoutePage', 'syncGripSubscription failed: ' + e.message)
    })
    this.loadFabVisible().catch((e: Error): void => {
      Logger.warn('RoutePage', 'loadFabVisible failed: ' + e.message)
    })
    if (routeVM.isLoaded) {
      this.forceSyncGoalDataSource()
    } else {
      routeVM.init(getContext(this)).then((): void => {
        this.forceSyncGoalDataSource()
      })
    }
  }

  /**
   * 页面消失时强制 flush 一次
   */
  aboutToDisappear(): void {
    if (this.pressedTimer !== -1) clearTimeout(this.pressedTimer)
    routeVM.flush()
    // 注销握姿订阅，避免 Tab 切走后资源泄漏
    this.gripService.unsubscribe()
    // 注销进度变化订阅（按 id 精确注销，不能整表清空）
    if (this.goalProgressCbId > 0) {
      eventBus.off(EventType.GOAL_PROGRESS_CHANGED, this.goalProgressCbId)
      this.goalProgressCbId = -1
    }
  }

  /**
   * 摘取流入口
   * - 调用 routeVM.extractToHomeTodo 获取 L4 实例
   * - 调用 homeVM.addExtractedTask 写入首页
   * - 通过 pressedAddTaskId 反馈视觉态
   *
   * @param goalId - L1 目标 ID
   * @param taskId - L2 任务 ID
   */
  private handleExtractToHome(goalId: string, taskId: string): void {
    if (!goalId || !taskId) {
      Logger.warn('RoutePage', 'handleExtractToHome: invalid params')
      return
    }
    Logger.info('RoutePage', 'handleExtractToHome start, goalId=' + goalId + ', taskId=' + taskId)
    try {
      const todo = routeVM.extractToHomeTodo(goalId, taskId)
      if (!todo) {
        promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_task_extract_failed').id) })
        return
      }
      const ok: boolean = homeVM.addExtractedTask(todo)
      if (ok) {
        this.forceSyncGoalDataSource()  // ← 摘取任务后强制同步（属性变更）
        // 视觉反馈：标记该按钮为"已加入"
        this.pressedAddTaskId = taskId
        promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.goal_detail_added_to_todo_prefix').id) + safeStringUtil(todo.title, '') })
        if (this.pressedTimer !== -1) clearTimeout(this.pressedTimer)
        this.pressedTimer = setTimeout((): void => {
          if (this.pressedAddTaskId === taskId) {
            this.pressedAddTaskId = ''
          }
          this.pressedTimer = -1
        }, 1500)
      } else {
        // 重复添加
        promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_task_already_in_todo').id) })
      }
    } catch (e) {
      const err: Error = e as Error
      Logger.error('RoutePage', 'handleExtractToHome failed, msg=' + err.message)
      promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.goal_detail_extract_failed_prefix').id) + err.message })
    }
  }

  /**
   * 点击目标卡片 - 跳转到目标详情
   */
  private onGoalClick(goal: GoalCardItem): void {
    Logger.info('RoutePage', 'onGoalClick, id=' + goal.id)

    // 显式构造对象（字段全部显式赋值）
    const param: GoalDetailRouteNavParam = {
      id: goal.id,
      goal: goal
    }

    const pathInfo: NavPathInfo = new NavPathInfo(ROUTE_NAME.GOAL_DETAIL, param)
    globalNavStack.pushPath(pathInfo)
  }

  /**
   * 空态引导 - 跳转到 AI Tab
   * - 用户在路线页空态点「去 AI 拆解」/ 伪输入框 / 示例标签时触发
   * - 使用 globalTabsController.changeIndex() 直接切换 Tab（无需 NavDestination）
   * - 错误处理：失败时仅打日志，不阻塞 UI
   *
   * @param prompt 待预填到 AI 输入框的目标文本；空串 = 只聚焦输入框、不预填
   *
   * ⚠️ 提示词走 `aiPromptBridge` **信箱式**投递，而不是 eventBus：
   *    HdsTabs 的 TabContent 是**首次切到时才构建** —— 若先 emit 再切 Tab，
   *    AIPage 的订阅者还不存在，事件直接丢失。AIPage 会在「首次构建」与
   *    「每次变为可见」两个时机主动 consume，不依赖订阅时序。
   */
  private switchToAITab(prompt: string = ''): void {
    try {
      aiPromptBridge.post(prompt)
      globalTabsController.changeIndex(TAB_INDEX.AI)
      Logger.info('RoutePage', 'switchToAITab: navigated to AI tab, promptLen=' + prompt.length.toString())
    } catch (e) {
      Logger.error('RoutePage', 'switchToAITab failed, msg=' + (e as Error).message)
    }
  }

  /** 强制刷新 DataSource（属性变更时调用，如里程碑/步骤变更/筛选切换） */
  private forceSyncGoalDataSource(): void {
    this.goalDataSource.updateAll(this.viewModel.filteredGoals)
    this.prevGoalCount = this.viewModel.filteredGoals.length
  }

  /**
   * 检测 goalDataSource 是否与 filteredGoals 不同步
   * routeVM.addGoal() 修改 goals(@Trace)，filteredGoals(@Computed) 自动更新，
   * 但 goalDataSource 是独立副本，需手动同步。onVisibleAreaChange 在 Tab 切换时不可靠。
   * 检测策略：长度不一致 或 首项 id 不一致 → 过期
   */
  private isGoalDataSourceStale(): boolean {
    const filtered: GoalCardItem[] = this.viewModel.filteredGoals
    const dsCount: number = this.goalDataSource.totalCount()
    if (filtered.length !== dsCount) {
      return true
    }
    if (filtered.length > 0 && dsCount > 0) {
      const dsFirst: GoalCardItem = this.goalDataSource.getData(0) as GoalCardItem
      if (filtered[0].id !== dsFirst.id) {
        return true
      }
    }
    return false
  }

  // Opt: H2-2 顶部固定区移入List header释放垂直空间
  // 标题已抽离至 CommonTitleBar（吸顶，不随滚动），数据概览已迁移至 ProfilePage，此处仅保留分类筛选
  @Builder routeListHeaderBuilder() {
    Column() {
      // 分类筛选
      Row({ space: 8 }) {
        ForEach(this.viewModel.categories, (cat: string): void => {
          CategoryChipComp({
            label: cat,
            isActive: this.viewModel.filterCategory === cat,
            pressedCategory: this.pressedCategory,
            onCategoryPressedIdChange: (id: string): void => { this.pressedCategory = id },
            onCategoryClick: (label: string): void => {
              this.viewModel.setCategory(label)
              this.forceSyncGoalDataSource()
            }
          })
        }, (cat: string): string => cat)
      }
      .width('100%')
      .padding({ bottom: 12 })
      .margin({ top: 12 })
    }
    .width('100%')
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      // 第一层：原有 Column 内容（CommonTitleBar + 三态内容区），保持不动
      Column() {
        // 1. 吸顶标题栏（在滚动区外部，不随内容滚动）
        CommonTitleBar({ title: $r('app.string.route_my_route'), showBack: false })

        // 2. 下方内容区：加载态 / 错误态 / 空态 / 列表态
        if (this.viewModel.isLoading) {
          Scroll() {
            Column() {
              this.routeListHeaderBuilder()

              Column({ space: 12 }) {
                // 筛选栏骨架
                Row({ space: 8 }) {
                  Column().width(60).height(28).borderRadius(DimensConstants.RADIUS_L).backgroundColor($r('app.color.bg_card_variant'))
                  Column().width(60).height(28).borderRadius(DimensConstants.RADIUS_L).backgroundColor($r('app.color.bg_card_variant'))
                  Column().width(60).height(28).borderRadius(DimensConstants.RADIUS_L).backgroundColor($r('app.color.bg_card_variant'))
                }

                // 目标卡片骨架 ×2
                ForEach([1, 2], (skeletonIdx: number): void => {
                  Row({ space: 12 }) {
                    Column()
                      .width(60)
                      .height(60)
                      .borderRadius(30)
                      .backgroundColor($r('app.color.bg_card_variant'))
                    Column({ space: 8 }) {
                      Column().width('70%').height(16).borderRadius(DimensConstants.RADIUS_XS).backgroundColor($r('app.color.bg_card_variant'))
                      Column().width('50%').height(12).borderRadius(DimensConstants.RADIUS_XS).backgroundColor($r('app.color.bg_card_variant'))
                      Row({ space: 4 }) {
                        Column().width(40).height(8).borderRadius(DimensConstants.RADIUS_XS).backgroundColor($r('app.color.bg_card_variant'))
                        Column().width(60).height(8).borderRadius(DimensConstants.RADIUS_XS).backgroundColor($r('app.color.bg_card_variant'))
                      }
                    }.layoutWeight(1)
                  }
                  .width('100%')
                  .padding(12)
                  .borderRadius(DimensConstants.RADIUS_L)
                  .backgroundColor($r('app.color.bg_card'))
                  .shadow({ radius: 8, color: $r('app.color.shadow_card'), offsetX: 0, offsetY: 2 })
                }, (item: number): string => item.toString())
              }
              .width('100%')
            }
            .width('100%')
            .padding({ left: 16, right: 16, bottom: safeAreaHelper.getBottomWith(66) })
          }
          .scrollBar(BarState.Auto)
          .edgeEffect(EdgeEffect.Spring)
          .width('100%')
          .layoutWeight(1)
        } else if (this.viewModel.loadError) {
          // 错误态：数据加载失败，提供重试
          Column() {
            this.routeListHeaderBuilder()

            StateView({
              mode: StateMode.ERROR,
              errorMessage: $r('app.string.state_error_desc'),
              onRetry: (): void => {
                this.viewModel.retryLoad()
              }
            })
          }
          .width('100%')
          .layoutWeight(1)
          .padding({ left: 16, right: 16, bottom: safeAreaHelper.getBottomWith(66) })
        } else if (this.viewModel.filteredGoals.length === 0) {
          Column() {
            // 筛选条**仅在"有目标但该分类为空"时显示**：一个目标都没有时整行隐藏
            // —— 那时筛选无意义（点了也是空），还会让空态看起来像"被筛没的"，反而误导
            if (this.viewModel.liveGoals.length > 0) {
              this.routeListHeaderBuilder()
            }

            // 空态分两种，文案与出口都不同（原实现混成一种 —— 用户明明有目标、
            // 只是筛到了空分类，页面却告诉他"还没有目标"，看着像数据丢了）：
            //   ① 一个目标都没有   → 三段式引导（伪输入框 / 三步说明 / 示例标签）
            //   ② 有目标但该分类为空 → 只说明分类为空，并给「查看全部」的出口
            // Scroll：三段式内容在小屏/大字号下可能超过一屏，可滚动；不足一屏时顶部对齐
            Scroll() {
              Column() {
                if (this.viewModel.liveGoals.length === 0) {
                  RouteEmptySection({
                    onStartAI: (prompt: string): void => { this.switchToAITab(prompt) },
                    onCreateGoal: (): void => { this.showCreateDialog = true }
                  })
                } else {
                  // 筛选空态内容少，垫高一点避免完全贴顶
                  Column() {
                    RouteFilteredEmptySection({
                      onClearFilter: (): void => { this.viewModel.clearCategoryFilter() }
                    })
                  }
                  .width('100%')
                  .padding({ top: 56 })
                }
              }
              .width('100%')
              .padding({ top: 4, bottom: 8 })
            }
            .width('100%')
            .layoutWeight(1)
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
          }
          .width('100%')
          .layoutWeight(1)
          .padding({ left: 16, right: 16, bottom: safeAreaHelper.getBottomWith(66) })
        } else {
          // 正常态：目标列表
          // build() 中读取 this.viewModel.filteredGoals 会建立 @Trace 依赖
          // routeVM.goals 变化时组件重渲染 → onDidBuild() 更新 goalCount → @Monitor 同步 goalDataSource
          List({ space: 12 }) {
            // 顶部固定区作为 ListItem 首项，随列表滚动释放垂直空间
            ListItem() {
              this.routeListHeaderBuilder()
            }
            // LazyForEach 只渲染可见 + cachedCount 个缓存项
            // keyGenerator 使用 goal.id 保证 key 稳定，新增目标时框架正确识别为新项而非错位复用
            LazyForEach(this.goalDataSource, (goal: GoalCardItem, index: number): void => {
              ListItem() {
                // GoalCardComp 接收 @Param goal 数据 + @Event 回调，单向数据流
                // onGoalClick → navigateToWithId：跳转 GoalDetailPage
                // onExtractToHome → handleExtractToHome：单个 L2 任务加入首页待办
                GoalCardComp({
                  goal: goal,
                  pressedGoalId: this.pressedGoalId,
                  expandedTaskGoalId: this.expandedTaskGoalId,
                  pressedAddTaskId: this.pressedAddTaskId,
                  onGoalClick: (g: GoalCardItem): void => { this.onGoalClick(g) },
                  onGoalPressedIdChange: (id: string): void => { this.pressedGoalId = id },
                  onTaskToggle: (goalId: string): void => {
                    this.expandedTaskGoalId = this.expandedTaskGoalId === goalId ? '' : goalId
                  },
                  onExtractToHome: (goalId: string, taskId: string): void => {
                    this.handleExtractToHome(goalId, taskId)
                  }
                })
              }
              // L1b：目标卡片增删过渡（keyGenerator 主键 = goal.id，稳定）
              // 注意只给 LazyForEach 内的 ListItem 挂 —— 同 List 里的
              // 顶部 header 与底部占位项是常驻的，不该参与增删动效。
              .transition(MotionHelper.listItem())
            }, (goal: GoalCardItem, index: number): string => safeStringUtil(goal.id, 'goal_' + index.toString()))
            // 底部占位：为底部悬浮 TabBar（HdsTabs 悬浮胶囊）预留避让空间，参与滚动
            ListItem() {
              Column()
                .width('100%')
                .height(safeAreaHelper.getBottomWith(66))
            }
          }
          .width('100%')
          .layoutWeight(1)
          .listDirection(Axis.Vertical)
          .cachedCount(2)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: false })
          .padding({ left: 16, right: 16 })
          .onAppear((): void => {
            this.forceSyncGoalDataSource()
          })
        }
      }
      .width('100%')
      .height('100%')
      // 阈值从[1.0]改为[0.0]：[1.0]要求100%可见才触发，Tab切换时不可靠；
      // [0.0]在组件从隐藏变为可见时即触发，覆盖Tab切换场景
      .onVisibleAreaChange([0.0], (isVisible: boolean, _currentRatio: number): void => {
        if (isVisible && routeVM.isLoaded) {
          this.forceSyncGoalDataSource()
        }
      })

      // 第二层：悬浮加号按钮 (FAB)
      // 位置由 fabSide 驱动，避开底部 TabBar（距底部 80vp、距左右两侧 24vp）
      // 换边用 position（可动画）而非 Stack.alignContent（布局参数，只能瞬变），
      // 具体坐标见 fabX() / fabY()；容器尺寸由下方 onAreaChange 上报。
      // Stack 全屏占位 + hitTestBehavior(Transparent) 让点击穿透到下层 Column
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
            this.openCreateDialog()
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

      // 第三层：手动创建目标弹窗 (Stack 层叠，禁止 bindContentCover)
      if (this.showCreateDialog) {
        this.CreateGoalCoverBuilder()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /**
   * 打开手动创建目标弹窗
   * - 重置表单字段
   * - 设置 showCreateDialog = true
   */
  private openCreateDialog(): void {
    this.createGoalName = ''
    this.createGoalDesc = ''
    this.createGoalCategory = getContext(this).resourceManager.getStringSync($r('app.string.default_other_category').id)
    this.createGoalDeadline = 0
    this.showCreateDialog = true
  }

  /** 创建目标弹窗可选分类（本地化） */
  private get createDialogCategories(): string[] {
    return [
      getContext(this).resourceManager.getStringSync($r('app.string.category_programming').id),
      getContext(this).resourceManager.getStringSync($r('app.string.category_language').id),
      getContext(this).resourceManager.getStringSync($r('app.string.category_fitness').id),
      getContext(this).resourceManager.getStringSync($r('app.string.category_reading').id),
      getContext(this).resourceManager.getStringSync($r('app.string.default_other_category').id)
    ]
  }

  /**
   * 处理手动创建目标入库
   * - 校验名称非空
   * - 复用 buildGoalCardItem 构造（id 前缀 'goal_manual_'）
   * - 复用 routeVM.addGoal 入库
   * - 刷新 DataSource + 关闭弹窗 + Toast 提示
   *
   * @param name 目标名称
   * @param desc 目标描述
   * @param category 分类
   */
  private handleCreateGoal(name: string, desc: string, category: string): void {
    const trimmedName: string = name.trim()
    if (trimmedName.length === 0) {
      promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_input_required').id) })
      return
    }

    try {
      const newGoal: GoalCardItem = buildGoalCardItem(
        'goal_manual_' + Date.now().toString(),  // id
        trimmedName,                              // name
        desc,                                     // description
        category,                                 // category
        0,                                        // progress
        '',                                       // duration
        0,                                        // completedMilestones
        0,                                        // totalMilestones
        Date.now(),                               // createTime
        [] as MilestoneNode[],                    // milestones
        [] as AiGeneratedTask[],                  // tasks
        0,                                        // plannedTime
        0,                                        // actualCompletionTime
        this.createGoalDeadline                   // deadline（用户在 DatePicker 选择的截止时间，0 表示未设置）
      )
      routeVM.addGoal(newGoal)
      this.forceSyncGoalDataSource()
      this.showCreateDialog = false
      promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_save_success').id) })
      Logger.info('RoutePage', 'handleCreateGoal: manual goal created, id=' + newGoal.id)
    } catch (e) {
      Logger.error('RoutePage', 'handleCreateGoal failed: ' + (e as Error).message)
      promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_save_failed').id) })
    }
  }

  /**
   * 手动创建目标弹窗 Builder
   * - 半透明背景遮罩 + 底部 Sheet 表单
   * - 含目标名称、描述、分类输入
   * - 点击遮罩或取消按钮关闭
   * - 红线：用 Stack 层叠，禁止 bindContentCover
   */
  @Builder
  CreateGoalCoverBuilder() {
    Stack() {
      // 半透明遮罩
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.overlay_mask'))
        .transition(MotionHelper.overlayFade())
        .onClick((): void => {
          this.showCreateDialog = false
        })

      // 底部 Sheet 表单
      Column() {
        // 拖拽指示器
        Column()
          .width(40)
          .height(4)
          .borderRadius(2)
          .backgroundColor($r('app.color.text_tertiary'))
          .margin({ top: 12, bottom: 16 })

        // 标题
        Text($r('app.string.btn_create_goal'))
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .margin({ bottom: 16 })

        // 目标名称输入
        TextInput({
          placeholder: $r('app.string.route_create_goal_name_placeholder'),
          text: this.createGoalName
        })
          .width('100%')
          .height(48)
          .fontSize(16)
          .borderRadius(DimensConstants.RADIUS_M)
          .backgroundColor($r('app.color.bg_search'))
          .padding({ left: 16, right: 16 })
          .maxLength(30)
          .onChange((value: string): void => {
            this.createGoalName = value
          })
          .margin({ bottom: 12 })

        // 目标描述输入
        TextArea({
          placeholder: $r('app.string.route_create_goal_desc_placeholder'),
          text: this.createGoalDesc
        })
          .width('100%')
          .height(96)
          .fontSize(14)
          .borderRadius(DimensConstants.RADIUS_M)
          .backgroundColor($r('app.color.bg_search'))
          .padding({ left: 16, right: 16, top: 12, bottom: 12 })
          .maxLength(200)
          .onChange((value: string): void => {
            this.createGoalDesc = value
          })
          .margin({ bottom: 12 })

        // 分类选择
        Row({ space: 8 }) {
          ForEach(this.createDialogCategories, (cat: string): void => {
            Text(cat)
              .fontSize(13)
              .fontColor(this.createGoalCategory === cat ?
                $r('app.color.text_inverse') : $r('app.color.text_primary'))
              .backgroundColor(this.createGoalCategory === cat ?
                $r('app.color.primary_color') : $r('app.color.bg_search'))
              .borderRadius(DimensConstants.RADIUS_L)
              .padding({ left: 14, right: 14, top: 6, bottom: 6 })
              .onClick((): void => {
                this.createGoalCategory = cat
              })
          }, (cat: string): string => cat)
        }
        .width('100%')
        .margin({ bottom: 12 })

        // 截止日期选择（可选，用于目标到期提醒；已选择时可一键清除）
        Column({ space: 6 }) {
          Row({ space: 8 }) {
            Text($r('app.string.route_create_goal_deadline_label'))
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .layoutWeight(1)
            if (this.createGoalDeadline > 0) {
              Text($r('app.string.goal_detail_deadline_clear'))
                .fontSize(13)
                .fontColor($r('app.color.error_color'))
                .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                .onClick((): void => {
                  this.createGoalDeadline = 0
                })
            }
          }
          .width('100%')
          DatePicker({
            start: new Date(),
            end: new Date(Date.now() + 365 * 24 * 60 * 60 * 1000),
            selected: this.createGoalDeadline > 0 ? new Date(this.createGoalDeadline) : new Date()
          })
          .onDateChange((value: Date): void => {
            // 取当天 23:59:59 作为截止时间
            this.createGoalDeadline = new Date(value.getFullYear(), value.getMonth(), value.getDate(),
              23, 59, 59).getTime()
          })
          .height(120)
          .width('100%')
        }
        .width('100%')
        .margin({ bottom: 20 })

        // 按钮区
        Row({ space: 12 }) {
          Button() {
            Text($r('app.string.btn_cancel'))
              .fontSize(15)
              .fontColor($r('app.color.text_primary'))
          }
          .layoutWeight(1)
          .height(44)
          .borderRadius(DimensConstants.RADIUS_XL)
          .backgroundColor($r('app.color.bg_search'))
          .onClick((): void => {
            this.showCreateDialog = false
          })

          Button() {
            Text($r('app.string.btn_create'))
              .fontSize(15)
              .fontColor($r('app.color.text_inverse'))
              .fontWeight(FontWeight.Medium)
          }
          .layoutWeight(1)
          .height(44)
          .borderRadius(DimensConstants.RADIUS_XL)
          .backgroundColor($r('app.color.primary_color'))
          .onClick((): void => {
            this.handleCreateGoal(this.createGoalName, this.createGoalDesc, this.createGoalCategory)
          })
        }
        .width('100%')
      }
      .width('100%')
      .backgroundColor($r('app.color.bg_card'))
      .borderRadius({ topLeft: 20, topRight: 20 })
      .padding({ left: 20, right: 20, bottom: 40 })
      .position({ x: 0, y: '100% - 520' })
      .expandSafeArea([SafeAreaType.KEYBOARD])
      // 面板从屏幕下方来，必须向上滑入；遮罩已单独挂透明度，两者互不拖动
      .transition(MotionHelper.bottomPanel())
    }
    .width('100%')
    .height('100%')
    // Stack 自身不参与转场：遮罩与面板各自负责，避免整体再淡一次
    .transition(MotionHelper.noTransition())
  }
}
