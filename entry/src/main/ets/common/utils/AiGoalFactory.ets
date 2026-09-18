/** AI 目标工厂 - 将 AI 拆解结果转换为 L1 目标，从 AIPage 抽离实现关注点分离 */

import {
  AiGeneratedTask,
  GoalCardItem,
  MilestoneNode,
  TaskStep,
  Id,
  Timestamp,
  buildGoalCardItem,
  generateStepId
} from '../../model/Models'
import { Context } from '@kit.AbilityKit'

/** 一周的毫秒数（预计耗时/阶段周次推导用） */
const WEEK_MILLIS: number = 7 * 24 * 60 * 60 * 1000
/** 一天的毫秒数 */
const DAY_MILLIS: number = 24 * 60 * 60 * 1000

/**
 * MilestoneNode 工厂函数 - 显式构造，避免对象字面量 + as 强转
 */
function buildMilestoneNode(
  id: Id,
  week: number,
  title: string,
  description: string,
  dueText: string,
  isCompleted: boolean,
  completedTime: Timestamp
): MilestoneNode {
  return new MilestoneNode(id, week, title, description, dueText, isCompleted, completedTime)
}

/**
 * 主线桥梁：将 AI 拆解的扁平任务列表组装为 L1 目标（含 3 里程碑 + L2 任务数组 + deadline 推导）
 * 调用方：AIPage.handleConfirmPlan → createGoalFromAi → routeVM.addGoal
 *
 * 时间语义（修复：预计耗时与截止时间脱节的问题）：
 *   - 目标 deadline = 所有 L2 任务中【最晚】的 deadline（目标完成时刻）
 *   - 预计耗时 duration = 当前时间到目标 deadline 的实际跨度（<1 周按天显示）
 *   - 二者同源于 AI 排的任务时间表，展示永远一致
 *   - 紧迫性提醒由任务级 deadline 提醒覆盖（DeadlineReminderService 对每个任务单独调度），
 *     目标级提醒在真实完成时间点触发
 */
export function createGoalFromAi(
  aiTasks: Array<AiGeneratedTask>,
  goalName: string,
  context?: Context
): GoalCardItem {
  const totalTasks: number = aiTasks.length

  const phaseNames: string[] = context ? [
    context.resourceManager.getStringSync($r('app.string.ai_phase_basic').id),
    context.resourceManager.getStringSync($r('app.string.ai_phase_core').id),
    context.resourceManager.getStringSync($r('app.string.ai_phase_sprint').id)
  ] : ['基础入门', '核心实战', '冲刺完善']

  const phaseEmpty: string = context ?
    context.resourceManager.getStringSync($r('app.string.ai_phase_empty').id) : '本阶段暂无具体任务'

  const weekPrefix: string = context ?
    context.resourceManager.getStringSync($r('app.string.ai_week_prefix').id) : '第 '

  const weekSuffix: string = context ?
    context.resourceManager.getStringSync($r('app.string.ai_week_suffix').id) : ' 周'

  const durationWeeksUnit: string = context ?
    context.resourceManager.getStringSync($r('app.string.ai_duration_weeks').id) : ' 周'

  const durationDaysUnit: string = context ?
    context.resourceManager.getStringSync($r('app.string.ai_duration_days').id) : ' 天'

  const defaultTaskPrefix: string = context ?
    context.resourceManager.getStringSync($r('app.string.ai_default_task').id) : '任务'

  const aiDescription: string = context ?
    context.resourceManager.getStringSync($r('app.string.ai_description').id) : '由 AI 智能拆解生成'

  const aiCategory: string = context ?
    context.resourceManager.getStringSync($r('app.string.ai_category').id) : 'AI 生成'

  const goalId: string = 'goal_ai_' + Date.now().toString()
  const phaseSize: number = Math.ceil(totalTasks / 3)

  // 1. 构建 L2 任务数组：逐字段防御性拷贝（NaN/非数字容错），保留 deadline 供四象限分类
  const tasksForGoal: Array<AiGeneratedTask> = []
  for (let i: number = 0; i < aiTasks.length; i++) {
    const src: AiGeneratedTask = aiTasks[i]
    const safeTime: number = (typeof src.estimatedTime === 'number' && !isNaN(src.estimatedTime)) ?
      Math.max(0, Math.floor(src.estimatedTime)) : 0
    // L3 步骤：源已是 `TaskStep[]`，逐项防御性重建（保留 id 与完成状态）
    //   - id 缺失时补发（防御历史/异常数据），保证 keyGenerator 始终可用
    const safeSteps: TaskStep[] = []
    if (Array.isArray(src.steps)) {
      for (let k: number = 0; k < src.steps.length; k++) {
        const s: TaskStep = src.steps[k]
        safeSteps.push(new TaskStep(
          (s && typeof s.id === 'string' && s.id.length > 0) ? s.id : generateStepId(),
          (s && typeof s.text === 'string') ? s.text : '',
          !!(s && s.isCompleted === true)
        ))
      }
    }
    // 时间字段容错：从源任务透传 plannedTime / actualCompletionTime / deadline
    //   - 防御 NaN / 非数字类型（派生场景下源任务可能字段缺失或异常）
    //   - 保证 L2→L2 拷贝不丢失时间数据（例如"基于已有任务派生新任务"场景）
    const safePlannedTime: number =
      (typeof src.plannedTime === 'number' && !isNaN(src.plannedTime)) ? src.plannedTime : 0
    const safeActualCompletionTime: number =
      (typeof src.actualCompletionTime === 'number' && !isNaN(src.actualCompletionTime)) ?
        src.actualCompletionTime : 0
    const safeDeadline: number =
      (typeof src.deadline === 'number' && !isNaN(src.deadline)) ? src.deadline : 0
    const t: AiGeneratedTask = new AiGeneratedTask(
      typeof src.id === 'string' ? src.id : '',
      (src.taskName && src.taskName.length > 0) ? src.taskName : (defaultTaskPrefix + (i + 1).toString()),
      safeTime,
      src.priority,
      safeSteps,
      src.status,
      safePlannedTime,
      safeActualCompletionTime,
      safeDeadline
    )
    tasksForGoal.push(t)
  }

  // 2. 时间统计：最晚 deadline = 目标完成时刻，同时用于预计耗时与里程碑周次推导
  const now: number = Date.now()
  let maxDeadline: number = 0
  for (let i: number = 0; i < tasksForGoal.length; i++) {
    const taskDeadline: number = tasksForGoal[i].deadline
    if (taskDeadline > maxDeadline) {
      maxDeadline = taskDeadline
    }
  }

  // 3. 预计耗时：从实际时间跨度推导（与目标 deadline 同源，杜绝"预计 3 周、后天截止"的矛盾）
  //    跨度 ≥ 1 周按周显示，不足 1 周按天显示；任务均无 deadline 时回退任务数估算公式
  let duration: string
  if (maxDeadline > 0) {
    const span: number = Math.max(DAY_MILLIS, maxDeadline - now)
    if (span >= WEEK_MILLIS) {
      duration = Math.ceil(span / WEEK_MILLIS).toString() + durationWeeksUnit
    } else {
      duration = Math.ceil(span / DAY_MILLIS).toString() + durationDaysUnit
    }
  } else {
    duration = Math.ceil(totalTasks / 2).toString() + durationWeeksUnit
  }

  // 4. 按任务总数均分 3 阶段构建里程碑（基础入门 / 核心实战 / 冲刺完善）
  //    阶段周次取该阶段内最晚任务 deadline 所在的周（相对当前时间），无 deadline 时回退阶段序号
  const milestones: MilestoneNode[] = []
  let completedCount: number = 0

  for (let p: number = 0; p < 3; p++) {
    const startIdx: number = p * phaseSize
    const endIdx: number = Math.min((p + 1) * phaseSize, totalTasks)

    let desc: string = ''
    let phaseDeadline: number = 0
    for (let t: number = startIdx; t < endIdx; t++) {
      if (t > startIdx) desc += '、'
      desc += aiTasks[t].taskName
      if (tasksForGoal[t].deadline > phaseDeadline) {
        phaseDeadline = tasksForGoal[t].deadline
      }
    }
    if (desc.length === 0) desc = phaseEmpty

    const phaseTasksCount: number = endIdx - startIdx
    const isCompleted: boolean = false

    let dueWeek: number = p + 1
    if (maxDeadline > 0 && phaseDeadline > 0) {
      dueWeek = Math.max(1, Math.ceil((phaseDeadline - now) / WEEK_MILLIS))
    }

    const node: MilestoneNode = buildMilestoneNode(
      goalId + '_m' + (p + 1).toString(),
      p + 1,
      phaseNames[p],
      desc,
      weekPrefix + dueWeek.toString() + weekSuffix,
      isCompleted,
      isCompleted ? Date.now() : 0
    )
    milestones.push(node)
  }

  // 5. 创建 L1 目标：组装 milestones + tasksForGoal + maxDeadline → 返回 GoalCardItem
  //    返回后由 AIPage 传入 routeVM.addGoal 落库
  const newGoal: GoalCardItem = buildGoalCardItem(
    goalId,
    goalName,
    aiDescription,
    aiCategory,
    0,
    duration,
    completedCount,
    3,
    Date.now(),
    milestones,
    tasksForGoal,
    0,                  // plannedTime，目标级计划开始时间，暂不设置
    0,                  // actualCompletionTime，新建目标未完成
    maxDeadline         // deadline，取最晚 L2 任务 deadline（目标完成时刻）
  )

  return newGoal
}
