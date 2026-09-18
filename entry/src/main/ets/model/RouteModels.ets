/**
 * @file RouteModels - 路线与目标 (模块化拆分 - 路线域)
 * @description
*   路线页（RoutePage）与目标详情（GoalDetailPage）相关数据模型：
 *   - MilestoneNode: 里程碑节点 @ObservedV2 类（L1 嵌套）
 *   - MilestoneNodeJSON: 里程碑纯数据快照
 *   - GoalCardItem: 路线页目标卡片 @ObservedV2 类（L1 目标）
 *   - GoalCardItemJSON: 目标纯数据快照
 *   - GoalDetailRouteNavParam: 目标详情页路由参数
 *   - buildGoalCardItem: 顶层工厂函数（4 级架构强校验）
 *   - isValidGoalCardItem: 类型守卫
 *   - hydrateGoalCardItem: 反序列化工厂
 *   - snapshotGoalCardItem: 序列化工厂
 *
 * 4 级架构定位：
 *   - L1 目标：GoalCardItem
 *   - L2 任务：通过 GoalCardItem.tasks 字段关联（依赖 TaskModels）
 *
 * V2 规范：
 *   - Model 类使用 @ObservedV2 装饰
 *   - 响应式属性使用 @Trace 装饰
 *   - 严禁使用 V1 装饰器
 *
 * @module model
 * @date 2026-07-02
 */

import { Id, Timestamp } from './BaseTypes'
import { AiGeneratedTask, AiGeneratedTaskJSON, RouteParam,
  hydrateAiGeneratedTask, snapshotAiGeneratedTask } from './TaskModels'

/* ============================================================
 * 1. 里程碑节点 @ObservedV2 类
 * ============================================================ */

/**
 * 里程碑纯数据快照（用于 JSON 序列化/反序列化）
 */
export interface MilestoneNodeJSON {
  id: string
  week: number
  title: string
  description: string
  dueText: string
  isCompleted: boolean
  completedTime: number
}

/**
 * 里程碑节点 @ObservedV2 类
 * 用于 RoutePage / GoalDetailPage 时间线渲染
 * isCompleted / completedTime 变更可被 @Trace 精确追踪，无需整体替换数组
 */
@ObservedV2
export class MilestoneNode {
  @Trace id: Id = ''
  @Trace week: number = 1
  @Trace title: string = ''
  @Trace description: string = ''
  @Trace dueText: string = ''
  @Trace isCompleted: boolean = false
  @Trace completedTime: Timestamp = 0

  constructor(
    id: Id,
    week: number,
    title: string,
    description: string,
    dueText: string,
    isCompleted: boolean,
    completedTime: Timestamp
  ) {
    this.id = id
    this.week = week
    this.title = title
    this.description = description
    this.dueText = dueText
    this.isCompleted = isCompleted
    this.completedTime = completedTime
  }

  static fromJSON(json: MilestoneNodeJSON | null | undefined): MilestoneNode | null {
    if (!json) return null
    if (typeof json.id !== 'string' || json.id.length === 0) return null
    return new MilestoneNode(
      json.id,
      (typeof json.week === 'number' && !isNaN(json.week) && json.week >= 1)
        ? Math.floor(json.week) : 1,
      typeof json.title === 'string' ? json.title : '',
      typeof json.description === 'string' ? json.description : '',
      typeof json.dueText === 'string' ? json.dueText : '',
      typeof json.isCompleted === 'boolean' ? json.isCompleted : false,
      (typeof json.completedTime === 'number' && !isNaN(json.completedTime))
        ? json.completedTime : 0
    )
  }

  toJSON(): MilestoneNodeJSON {
    return {
      id: this.id,
      week: this.week,
      title: this.title,
      description: this.description,
      dueText: this.dueText,
      isCompleted: this.isCompleted,
      completedTime: this.completedTime
    }
  }
}

/* ============================================================
 * 2. 路线页目标卡片 @ObservedV2 类（L1 目标）
 * ============================================================ */

/**
 * 目标纯数据快照（用于 JSON 序列化/反序列化）
 * 向后兼容：新字段（plannedTime/actualCompletionTime/deadline）为可选，默认为 0
 */
export interface GoalCardItemJSON {
  id: string
  name: string
  description: string
  category: string
  progress: number
  duration: string
  completedMilestones: number
  totalMilestones: number
  createTime: number
  milestones: MilestoneNodeJSON[]
  tasks: AiGeneratedTaskJSON[]
  /** 计划开始时间戳（毫秒），默认 0（用于番茄钟、日程安排） */
  plannedTime?: number
  /** 实际完成时间戳（毫秒），默认 0（用于统计分析） */
  actualCompletionTime?: number
  /** 截止时间戳（毫秒），默认 0（用于截止日期提醒） */
  deadline?: number
  /**
   * 墓碑标记（云同步软删除），默认 false
   * - true 表示该目标已被删除，条目仍留在底层 goals 数组里用于跨设备传播删除
   * - 老数据缺失此字段 → 反序列化时视为 false（向后兼容）
   * - ⚠️ UI / 统计 / 提醒 / 导出一律读取 liveGoals 视图，禁止直接遍历底层 goals
   */
  isDeleted?: boolean
  /**
   * 条目最后修改时间戳（毫秒）—— 云同步冲突裁决唯一依据
   * - 新建时写入当前时间；任何会让目标内容变化的写操作都要刷新
   * - 老数据缺失此字段 → 0，冲突裁决退化为 createTime 兜底
   * - ⚠️ 同步落地（applyCloudSnapshot）**禁止**改写本字段
   */
  updatedAt?: number
}

/**
 * 路线页目标卡片 @ObservedV2 类（L1 目标）
 *
 * 4 级架构：
 *   - L1 目标：自身
 *   - L2 任务：通过 tasks 字段关联
 *   - L3 步骤：嵌套在每个 L2 任务的 steps 字段中
 *   - L4 待办：摘取流时由 L2 任务转化，存于 homeVM
 *
 * V2 深度修复：
 *   - 从 interface 升级为 @ObservedV2 class
 *   - tasks/milestones/progress 等属性变更可被 @Trace 精确追踪
 *   - 勾选 Step 时只需修改 task.steps[i].isCompleted，无需重建整个 goals 数组
 *
 * 时间字段扩展（阶段1：数据底座扩展）：
 *   - plannedTime: 计划开始时间，用于番茄钟、日程安排
 *   - actualCompletionTime: 实际完成时间，用于统计分析
 *   - deadline: 截止时间，用于截止日期提醒、四象限法则
 */
@ObservedV2
export class GoalCardItem {
  @Trace id: Id = ''
  @Trace name: string = ''
  @Trace description: string = ''
  @Trace category: string = ''
  @Trace progress: number = 0
  @Trace duration: string = ''
  @Trace completedMilestones: number = 0
  @Trace totalMilestones: number = 0
  @Trace createTime: Timestamp = 0
  @Trace milestones: MilestoneNode[] = []
  @Trace tasks: AiGeneratedTask[] = []
  /**
   * 计划开始时间戳（毫秒）
   * - 用于番茄钟功能：记录目标计划开始时间
   * - 用于日程安排：展示目标计划时间
   * - 默认值 0，表示未设置
   */
  @Trace plannedTime: Timestamp = 0
  /**
   * 实际完成时间戳（毫秒）
   * - 用于统计分析：计算完成耗时、效率分析
   * - 当 progress 为 100 且此字段为 0 时，应补全为当前时间
   * - 默认值 0，表示未完成或未记录
   */
  @Trace actualCompletionTime: Timestamp = 0
  /**
   * 截止时间戳（毫秒）
   * - 用于截止日期提醒：判断目标是否超时
   * - 用于四象限法则：根据截止时间和优先级分类
   * - 默认值 0，表示无截止日期
   */
  @Trace deadline: Timestamp = 0
  /**
   * 墓碑标记（云同步软删除）
   * - 删除目标时只置 true，不从 goals 数组移除 → 保证删除能跨设备传播、不复活
   * - 老数据默认为 false
   */
  @Trace isDeleted: boolean = false
  /**
   * 目标最后修改时间戳（毫秒）—— 跨设备冲突裁决依据（谁的值大谁胜出）
   * - 同步落地时禁止改写（见 GoalCardItemJSON.updatedAt 说明）
   */
  @Trace updatedAt: Timestamp = 0

  constructor(
    id: Id,
    name: string,
    description: string,
    category: string,
    progress: number,
    duration: string,
    completedMilestones: number,
    totalMilestones: number,
    createTime: Timestamp,
    milestones: MilestoneNode[],
    tasks: AiGeneratedTask[],
    plannedTime: Timestamp = 0,
    actualCompletionTime: Timestamp = 0,
    deadline: Timestamp = 0,
    isDeleted: boolean = false,
    updatedAt: Timestamp = 0
  ) {
    this.id = id
    this.name = name
    this.description = description
    this.category = category
    this.progress = progress
    this.duration = duration
    this.completedMilestones = completedMilestones
    this.totalMilestones = totalMilestones
    this.createTime = createTime
    this.milestones = milestones
    this.tasks = tasks
    this.plannedTime = plannedTime
    this.actualCompletionTime = actualCompletionTime
    this.deadline = deadline
    this.isDeleted = isDeleted
    this.updatedAt = updatedAt
  }

  static fromJSON(json: GoalCardItemJSON | null | undefined): GoalCardItem | null {
    if (!json) return null
    if (typeof json.id !== 'string' || json.id.length === 0) return null
    if (typeof json.name !== 'string' || json.name.length === 0) return null
    const safeMilestones: MilestoneNode[] = []
    if (Array.isArray(json.milestones)) {
      for (let i: number = 0; i < json.milestones.length; i++) {
        const m: MilestoneNode | null = MilestoneNode.fromJSON(json.milestones[i])
        if (m) safeMilestones.push(m)
      }
    }
    const safeTasks: AiGeneratedTask[] = []
    if (Array.isArray(json.tasks)) {
      for (let j: number = 0; j < json.tasks.length; j++) {
        const t: AiGeneratedTask | null = hydrateAiGeneratedTask(json.tasks[j])
        if (t) safeTasks.push(t)
      }
    }
    // 时间字段容错：老版本数据可能没有这些字段，默认 0（向后兼容）
    const safePlannedTime: Timestamp = (typeof json.plannedTime === 'number' && !isNaN(json.plannedTime)) ?
      json.plannedTime : 0
    const safeActualCompletionTime: Timestamp = (typeof json.actualCompletionTime === 'number' && !isNaN(json.actualCompletionTime)) ?
      json.actualCompletionTime : 0
    const safeDeadline: Timestamp = (typeof json.deadline === 'number' && !isNaN(json.deadline)) ?
      json.deadline : 0
    // 云同步扩展字段容错：老数据缺失 → isDeleted=false、updatedAt=0（后续由 createTime 兜底裁决）
    const safeIsDeleted: boolean = typeof json.isDeleted === 'boolean' ? json.isDeleted : false
    const safeUpdatedAt: number = (typeof json.updatedAt === 'number' && !isNaN(json.updatedAt) && json.updatedAt > 0) ?
      json.updatedAt : 0
    return new GoalCardItem(
      json.id,
      json.name,
      typeof json.description === 'string' ? json.description : '',
      typeof json.category === 'string' ? json.category : '',
      (typeof json.progress === 'number' && !isNaN(json.progress)) ?
        Math.max(0, Math.min(100, Math.floor(json.progress))) : 0,
      typeof json.duration === 'string' ? json.duration : '',
      (typeof json.completedMilestones === 'number' && !isNaN(json.completedMilestones)) ?
        Math.max(0, Math.floor(json.completedMilestones)) : 0,
      (typeof json.totalMilestones === 'number' && !isNaN(json.totalMilestones)) ?
        Math.max(0, Math.floor(json.totalMilestones)) : 0,
      (typeof json.createTime === 'number' && !isNaN(json.createTime)) ?
        json.createTime : Date.now(),
      safeMilestones,
      safeTasks,
      safePlannedTime,
      safeActualCompletionTime,
      safeDeadline,
      safeIsDeleted,
      safeUpdatedAt
    )
  }

  /**
   * 修复：snapshotAiGeneratedTask 可能返回 null，增加空值过滤
   * 新增：序列化时间字段（plannedTime/actualCompletionTime/deadline）
   */
  toJSON(): GoalCardItemJSON {
    const jsonMilestones: MilestoneNodeJSON[] = []
    for (let i: number = 0; i < this.milestones.length; i++) {
      jsonMilestones.push(this.milestones[i].toJSON())
    }
    const jsonTasks: AiGeneratedTaskJSON[] = []
    for (let j: number = 0; j < this.tasks.length; j++) {
      const snap: AiGeneratedTaskJSON | null = snapshotAiGeneratedTask(this.tasks[j])
      if (snap) {
        jsonTasks.push(snap)
      }
    }
    return {
      id: this.id,
      name: this.name,
      description: this.description,
      category: this.category,
      progress: this.progress,
      duration: this.duration,
      completedMilestones: this.completedMilestones,
      totalMilestones: this.totalMilestones,
      createTime: this.createTime,
      milestones: jsonMilestones,
      tasks: jsonTasks,
      plannedTime: this.plannedTime,
      actualCompletionTime: this.actualCompletionTime,
      deadline: this.deadline,
      isDeleted: this.isDeleted === true,
      updatedAt: typeof this.updatedAt === 'number' && !isNaN(this.updatedAt) ? this.updatedAt : 0
    }
  }
}

/* ============================================================
 * 3. 路由参数
 * ============================================================ */

export interface GoalDetailRouteNavParam extends RouteParam {
  goal: GoalCardItem
}

/**
 * 反馈/举报页路由参数
 * mode = 'feedback' 普通问题反馈（默认） | 'report' AI 生成内容举报
 */
export interface FeedbackRouteNavParam {
  mode: string
}

/* ============================================================
 * 4. 4 级架构：L1 目标工厂函数与守卫
 * ============================================================ */

/**
 * V2 规范：GoalCardItem 顶层工厂函数
 * 返回 @ObservedV2 代理实例，@Trace 属性变更可被 UI 精确追踪
 * 时间字段（plannedTime/actualCompletionTime/deadline）可选，默认 0（向后兼容）
 */
export function buildGoalCardItem(
  id: Id,
  name: string,
  description: string,
  category: string,
  progress: number,
  duration: string,
  completedMilestones: number,
  totalMilestones: number,
  createTime: Timestamp,
  milestones: MilestoneNode[],
  tasks: AiGeneratedTask[],
  plannedTime: Timestamp = 0,
  actualCompletionTime: Timestamp = 0,
  deadline: Timestamp = 0,
  isDeleted: boolean = false,
  updatedAt: Timestamp = 0
): GoalCardItem {
  if (typeof id !== 'string' || id.length === 0) {
    throw new Error('buildGoalCardItem: id is required and must be non-empty string')
  }
  if (typeof name !== 'string' || name.length === 0) {
    throw new Error('buildGoalCardItem: name is required and must be non-empty string')
  }
  const safeProgress: number = (typeof progress === 'number' && !isNaN(progress)) ?
    Math.max(0, Math.min(100, Math.floor(progress))) : 0
  const safeCompleted: number = (typeof completedMilestones === 'number' && !isNaN(completedMilestones)) ?
    Math.max(0, Math.floor(completedMilestones)) : 0
  const safeTotal: number = (typeof totalMilestones === 'number' && !isNaN(totalMilestones)) ?
    Math.max(0, Math.floor(totalMilestones)) : 0
  const safeCreateTime: Timestamp = (typeof createTime === 'number' && !isNaN(createTime)) ?
    createTime : Date.now()
  const safeMilestones: MilestoneNode[] = Array.isArray(milestones) ? milestones : []
  const safeTasks: AiGeneratedTask[] = Array.isArray(tasks) ? tasks : []
  const safePlannedTime: Timestamp = (typeof plannedTime === 'number' && !isNaN(plannedTime)) ?
    plannedTime : 0
  const safeActualCompletionTime: Timestamp = (typeof actualCompletionTime === 'number' && !isNaN(actualCompletionTime)) ?
    actualCompletionTime : 0
  const safeDeadline: Timestamp = (typeof deadline === 'number' && !isNaN(deadline)) ?
    deadline : 0
  // 云同步扩展：墓碑默认 false；updatedAt 缺省时按"新建"语义写入当前时间
  const safeIsDeleted: boolean = typeof isDeleted === 'boolean' ? isDeleted : false
  const safeUpdatedAt: Timestamp = (typeof updatedAt === 'number' && !isNaN(updatedAt) && updatedAt > 0) ?
    updatedAt : Date.now()
  return new GoalCardItem(
    id,
    name,
    typeof description === 'string' ? description : '',
    typeof category === 'string' ? category : '',
    safeProgress,
    typeof duration === 'string' ? duration : '',
    safeCompleted,
    safeTotal,
    safeCreateTime,
    safeMilestones,
    safeTasks,
    safePlannedTime,
    safeActualCompletionTime,
    safeDeadline,
    safeIsDeleted,
    safeUpdatedAt
  )
}

/**
 * 类型守卫：校验 GoalCardItem 关联完整性（增强版）
 * 修复：补充 category/duration/completedMilestones/totalMilestones/createTime 类型校验
 * 修复：补充 milestones 数组元素级校验
 */
export function isValidGoalCardItem(goal: GoalCardItem | null | undefined): boolean {
  if (!goal) return false
  if (typeof goal.id !== 'string' || goal.id.length === 0) return false
  if (typeof goal.name !== 'string' || goal.name.length === 0) return false
  if (typeof goal.category !== 'string') return false
  if (typeof goal.duration !== 'string') return false
  if (typeof goal.progress !== 'number' || isNaN(goal.progress)) return false
  if (typeof goal.completedMilestones !== 'number' || isNaN(goal.completedMilestones)) return false
  if (typeof goal.totalMilestones !== 'number' || isNaN(goal.totalMilestones)) return false
  if (typeof goal.createTime !== 'number' || isNaN(goal.createTime)) return false
  if (!Array.isArray(goal.milestones)) return false
  if (!Array.isArray(goal.tasks)) return false
  // 里程碑元素级校验
  for (let i: number = 0; i < goal.milestones.length; i++) {
    const m: MilestoneNode = goal.milestones[i]
    if (typeof m.id !== 'string' || m.id.length === 0) return false
    if (typeof m.week !== 'number' || isNaN(m.week)) return false
    if (typeof m.isCompleted !== 'boolean') return false
  }
  // 任务元素级校验
  for (let j: number = 0; j < goal.tasks.length; j++) {
    const t: AiGeneratedTask = goal.tasks[j]
    if (typeof t.id !== 'string' || t.id.length === 0) return false
    if (typeof t.taskName !== 'string') return false
    if (!Array.isArray(t.steps)) return false
  }
  return true
}

/**
 * 反序列化工厂：从 JSON 还原 GoalCardItem @ObservedV2 实例
 */
export function hydrateGoalCardItem(json: GoalCardItemJSON | null | undefined): GoalCardItem | null {
  return GoalCardItem.fromJSON(json)
}

/**
 * 序列化工厂：将 GoalCardItem 转为可持久化的 JSON 快照（脱壳）
 */
export function snapshotGoalCardItem(goal: GoalCardItem | null | undefined): GoalCardItemJSON | null {
  if (!goal) return null
  if (!isValidGoalCardItem(goal)) return null
  return goal.toJSON()
}
