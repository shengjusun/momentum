/** AI 目标工厂 - 将 AI 拆解结果转换为 L1 目标，从 AIPage 抽离实现关注点分离 */

import {
  AiGeneratedTask,
  GoalCardItem,
  MilestoneNode,
  Id,
  Timestamp,
  buildGoalCardItem,
  getCompletedStepsSafe
} from '../../model/Models'
import { Context } from '@kit.AbilityKit'

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

  const defaultTaskPrefix: string = context ?
    context.resourceManager.getStringSync($r('app.string.ai_default_task').id) : '任务'

  const aiDescription: string = context ?
    context.resourceManager.getStringSync($r('app.string.ai_description').id) : '由 AI 智能拆解生成'

  const aiCategory: string = context ?
    context.resourceManager.getStringSync($r('app.string.ai_category').id) : 'AI 生成'

  // 1. 按任务总数均分 3 阶段构建里程碑（基础入门 / 核心实战 / 冲刺完善）
  //    让用户在 GoalDetailPage 看到阶段化推进路径，而非一堆扁平任务
  const goalId: string = 'goal_ai_' + Date.now().toString()
  const phaseSize: number = Math.ceil(totalTasks / 3)

  const milestones: MilestoneNode[] = []
  let completedCount: number = 0

  for (let p: number = 0; p < 3; p++) {
    const startIdx: number = p * phaseSize
    const endIdx: number = Math.min((p + 1) * phaseSize, totalTasks)

    let desc: string = ''
    for (let t: number = startIdx; t < endIdx; t++) {
      if (t > startIdx) desc += '、'
      desc += aiTasks[t].taskName
    }
    if (desc.length === 0) desc = phaseEmpty

    const phaseTasksCount: number = endIdx - startIdx
    const isCompleted: boolean = false

    const node: MilestoneNode = buildMilestoneNode(
      goalId + '_m' + (p + 1).toString(),
      p + 1,
      phaseNames[p],
      desc,
      weekPrefix + (p + 1).toString() + weekSuffix,
      isCompleted,
      isCompleted ? Date.now() : 0
    )
    milestones.push(node)
  }

  // 2. 构建 L2 任务数组：逐字段防御性拷贝（NaN/非数字容错），保留 deadline 供四象限分类
  const tasksForGoal: Array<AiGeneratedTask> = []
  for (let i: number = 0; i < aiTasks.length; i++) {
    const src: AiGeneratedTask = aiTasks[i]
    const safeTime: number = (typeof src.estimatedTime === 'number' && !isNaN(src.estimatedTime)) ?
      Math.max(0, Math.floor(src.estimatedTime)) : 0
    const safeSteps: Array<string> = Array.isArray(src.steps) ? src.steps : []
    const safeCompleted: Array<boolean> = getCompletedStepsSafe(src)
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
      safeCompleted,
      safePlannedTime,
      safeActualCompletionTime,
      safeDeadline
    )
    tasksForGoal.push(t)
  }

  // 3. 推导 L1 目标 deadline：取所有 L2 任务中最早的 deadline
  //    让目标截止提醒基于整体最紧迫的任务截止时间触发
  let earliestDeadline: number = 0
  for (let i: number = 0; i < tasksForGoal.length; i++) {
    const taskDeadline: number = tasksForGoal[i].deadline
    if (taskDeadline > 0) {
      if (earliestDeadline === 0 || taskDeadline < earliestDeadline) {
        earliestDeadline = taskDeadline
      }
    }
  }

  // 4. 创建 L1 目标：组装 milestones + tasksForGoal + earliestDeadline → 返回 GoalCardItem
  //    返回后由 AIPage 传入 routeVM.addGoal 落库
  const newGoal: GoalCardItem = buildGoalCardItem(
    goalId,
    goalName,
    aiDescription,
    aiCategory,
    0,
    Math.ceil(totalTasks / 2) + ' 周',
    completedCount,
    3,
    Date.now(),
    milestones,
    tasksForGoal,
    0,                  // plannedTime，目标级计划开始时间，暂不设置
    0,                  // actualCompletionTime，新建目标未完成
    earliestDeadline    // deadline，取最早 L2 任务 deadline
  )

  return newGoal
}