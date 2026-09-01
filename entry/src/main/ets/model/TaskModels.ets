/**
 * @file TaskModels - 任务详情与 AI 生成 (模块化拆分 - 任务域)
 * @description
 *   任务详情页与 AI 拆解任务的相关模型：
 *   - TaskNode: AI 拆解后的简单任务节点（值对象）
 *   - AiGeneratedTask: AI 拆解完整任务 @ObservedV2 类（含 L3 steps/completedSteps）
 *   - AiGeneratedTaskJSON: AiGeneratedTask 纯数据快照
 *   - TaskStep: 任务步骤 @ObservedV2 类
 *   - TaskDetailItem: 任务详情完整任务 @ObservedV2 类
 *   - RouteParam: 通用路由参数
 *   - TaskDetailRouteParam: 任务详情页路由参数（早期版本）
 *   - TaskDetailRouteNavParam: 任务详情页路由参数（4 级架构扩展）
 *   - 工具函数：getCompletedStepsSafe / isStepCompleted / hydrateAiGeneratedTask / snapshotAiGeneratedTask
 *
 * 4 级架构定位：
 *   - L2 任务：TaskNode / AiGeneratedTask
 *   - L3 步骤：TaskStep + AiGeneratedTask.steps/completedSteps
 *   - 路由层：3 个 RouteXxx 接口（GoalDetailRouteNavParam 在 RouteModels 中）
 *
 * V2 规范：
 *   - Model 类使用 @ObservedV2 装饰
 *   - 响应式属性使用 @Trace 装饰
 *   - 严禁使用 V1 装饰器
 *
 * @module model
 * @date 2026-07-02
 */

import { Id, Timestamp, TaskStatus, TaskPriority } from './BaseTypes'

/* ============================================================
 * 1. L2 任务接口（简化版，仅 AI 拆解结果预览用）
 * ============================================================ */

export interface TaskNode {
  taskName: string
  estimatedTime: string
  priority: TaskPriority
}

/* ============================================================
 * 2. AiGeneratedTask 纯数据快照
 * ============================================================ */

/**
 * AiGeneratedTask 的纯数据快照（用于 JSON 序列化/反序列化）
 *
 * 关键约束：
 *   - plannedTime / actualCompletionTime / deadline 为可选字段（向后兼容）
 *   - 老版本数据缺少这 3 个字段时，fromJSON 会赋默认值 0，不崩溃
 */
export interface AiGeneratedTaskJSON {
  id: string
  taskName: string
  estimatedTime: number
  priority: string
  steps: string[]
  status: string
  completedSteps: boolean[]
  /** 计划开始时间戳（毫秒），默认 0（用于番茄钟、日程安排） */
  plannedTime?: number
  /** 实际完成时间戳（毫秒），默认 0（用于统计分析） */
  actualCompletionTime?: number
  /** 截止时间戳（毫秒），默认 0（用于截止日期提醒、四象限法则） */
  deadline?: number
}

/* ============================================================
 * 3. AiGeneratedTask @ObservedV2 类（L2 任务）
 * ============================================================ */

/**
 * AI 拆解完整任务 @ObservedV2 类
 *
 * V2 深度修复：
 *   - 从 interface 升级为 @ObservedV2 class
 *   - completedSteps 变更可被 @Trace 精确追踪
 *   - 勾选 Step 时只需修改 task.completedSteps，无需重建整个 goals 数组
 *   - 持久化时通过 toJSON() 脱壳，读取时通过 fromJSON() 复活
 */
@ObservedV2
export class AiGeneratedTask {
  @Trace id: Id = ''
  @Trace taskName: string = ''
  @Trace estimatedTime: number = 0
  @Trace priority: TaskPriority = TaskPriority.MEDIUM
  @Trace steps: Array<string> = []
  @Trace status: TaskStatus = TaskStatus.PENDING
  @Trace completedSteps: Array<boolean> = []
  /**
   * 计划开始时间戳（毫秒）
   * - 用于番茄钟功能：记录计划开始时间
   * - 用于日程安排：展示任务计划时间
   * - 默认值 0，表示未设置
   */
  @Trace plannedTime: Timestamp = 0
  /**
   * 实际完成时间戳（毫秒）
   * - 用于统计分析：计算完成耗时、效率分析
   * - 当 status 为 COMPLETED 且此字段为 0 时，应由业务层补全为当前时间
   * - 默认值 0，表示未完成或未记录
   */
  @Trace actualCompletionTime: Timestamp = 0
  /**
   * 截止时间戳（毫秒）
   * - 用于截止日期提醒：判断任务是否超时
   * - 用于四象限法则：根据截止时间和优先级分类
   * - 默认值 0，表示无截止日期
   */
  @Trace deadline: Timestamp = 0

  /**
   * 完整构造函数（严格 10 个参数，最后 3 个时间字段默认 0 以保证向后兼容）
   *
   * 向后兼容策略：
   *   - 新增的 plannedTime / actualCompletionTime / deadline 均带默认值 0
   *   - 老代码以 7 参数调用（如 RoutePage/AIPage/GoalDetailPage 的空参占位）无需任何修改
   *   - 仅需要透传时间字段的场景（如 fromJSON、extractToHomeTodo）才显式传入
   *
   * @param id - 任务唯一标识
   * @param taskName - 任务名称
   * @param estimatedTime - 预估耗时（分钟）
   * @param priority - 优先级
   * @param steps - L3 步骤文本数组
   * @param status - 任务状态
   * @param completedSteps - L3 步骤完成状态数组（与 steps 同长）
   * @param plannedTime - 计划开始时间戳，默认 0（向后兼容）
   * @param actualCompletionTime - 实际完成时间戳，默认 0（向后兼容）
   * @param deadline - 截止时间戳，默认 0（向后兼容）
   */
  constructor(
    id: Id,
    taskName: string,
    estimatedTime: number,
    priority: TaskPriority,
    steps: Array<string>,
    status: TaskStatus,
    completedSteps: Array<boolean>,
    plannedTime: Timestamp = 0,
    actualCompletionTime: Timestamp = 0,
    deadline: Timestamp = 0
  ) {
    this.id = id
    this.taskName = taskName
    this.estimatedTime = estimatedTime
    this.priority = priority
    this.steps = steps
    this.status = status
    this.completedSteps = completedSteps
    this.plannedTime = plannedTime
    this.actualCompletionTime = actualCompletionTime
    this.deadline = deadline
  }

  static fromJSON(json: AiGeneratedTaskJSON | null | undefined): AiGeneratedTask | null {
    if (!json) return null
    if (typeof json.id !== 'string' || json.id.length === 0) return null
    let priorityEnum: TaskPriority = TaskPriority.MEDIUM
    if (json.priority === 'high') priorityEnum = TaskPriority.HIGH
    else if (json.priority === 'low') priorityEnum = TaskPriority.LOW
    let statusEnum: TaskStatus = TaskStatus.PENDING
    if (json.status === 'in_progress') statusEnum = TaskStatus.IN_PROGRESS
    else if (json.status === 'completed') statusEnum = TaskStatus.COMPLETED
    const safeSteps: Array<string> = Array.isArray(json.steps) ? json.steps : []
    const rawCompleted: Array<boolean> = Array.isArray(json.completedSteps) ? json.completedSteps : []
    const safeCompleted: Array<boolean> = []
    for (let i: number = 0; i < safeSteps.length; i++) {
      safeCompleted.push(i < rawCompleted.length ? rawCompleted[i] === true : false)
    }
    // 时间字段容错：老版本数据可能没有这 3 个字段（undefined），默认 0（向后兼容）
    // 同时防御 NaN / 非数字类型，避免统计/排序逻辑出错
    const safePlannedTime: Timestamp = (typeof json.plannedTime === 'number' && !isNaN(json.plannedTime)) ?
      json.plannedTime : 0
    const safeActualCompletionTime: Timestamp =
      (typeof json.actualCompletionTime === 'number' && !isNaN(json.actualCompletionTime)) ?
        json.actualCompletionTime : 0
    const safeDeadline: Timestamp = (typeof json.deadline === 'number' && !isNaN(json.deadline)) ?
      json.deadline : 0
    return new AiGeneratedTask(
      json.id,
      typeof json.taskName === 'string' ? json.taskName : '',
      (typeof json.estimatedTime === 'number' && !isNaN(json.estimatedTime)) ?
        Math.max(0, Math.floor(json.estimatedTime)) : 0,
      priorityEnum,
      safeSteps,
      statusEnum,
      safeCompleted,
      safePlannedTime,
      safeActualCompletionTime,
      safeDeadline
    )
  }

  toJSON(): AiGeneratedTaskJSON {
    return {
      id: this.id,
      taskName: this.taskName,
      estimatedTime: this.estimatedTime,
      priority: this.priority as string,
      steps: Array.isArray(this.steps) ? this.steps : [],
      status: this.status as string,
      completedSteps: Array.isArray(this.completedSteps) ? this.completedSteps : [],
      // 新增时间字段序列化（与 fromJSON 对称）
      plannedTime: this.plannedTime,
      actualCompletionTime: this.actualCompletionTime,
      deadline: this.deadline
    }
  }
}

/* ============================================================
 * 4. 任务步骤 / 任务详情 @ObservedV2 类
 * ============================================================ */

@ObservedV2
export class TaskStep {
  @Trace id: Id = ''
  @Trace text: string = ''
  @Trace isCompleted: boolean = false

  constructor(id: Id, text: string, isCompleted: boolean = false) {
    this.id = id
    this.text = text
    this.isCompleted = isCompleted
  }

  toJSON(): TaskStepJSON {
    const result: TaskStepJSON = {
      id: this.id,
      text: this.text,
      isCompleted: this.isCompleted
    }
    return result
  }

  static fromJSON(json: TaskStepJSON | null | undefined): TaskStep {
    if (!json) {
      return new TaskStep('', '', false)
    }
    return new TaskStep(
      typeof json.id === 'string' ? json.id : '',
      typeof json.text === 'string' ? json.text : '',
      typeof json.isCompleted === 'boolean' ? json.isCompleted : false
    )
  }
}

export interface TaskStepJSON {
  id: string
  text: string
  isCompleted: boolean
}

export interface TaskDetailItemJSON {
  id: string
  goalId: string | null
  title: string
  description: string
  duration: string
  priority: string
  isCompleted: boolean
  createTime: number
  steps: TaskStepJSON[]
}

@ObservedV2
export class TaskDetailItem {
  @Trace id: Id = ''
  @Trace goalId: Id | null = null
  @Trace title: string = ''
  @Trace description: string = ''
  @Trace duration: string = ''
  @Trace priority: TaskPriority = TaskPriority.MEDIUM
  @Trace isCompleted: boolean = false
  @Trace createTime: Timestamp = 0
  @Trace steps: TaskStep[] = []

  constructor(
    id: Id,
    title: string,
    description: string,
    duration: string,
    priority: TaskPriority,
    isCompleted: boolean,
    createTime: Timestamp
  ) {
    this.id = id
    this.title = title
    this.description = description
    this.duration = duration
    this.priority = priority
    this.isCompleted = isCompleted
    this.createTime = createTime
  }

  toJSON(): TaskDetailItemJSON {
    const stepsJSON: TaskStepJSON[] = this.steps.map((s: TaskStep): TaskStepJSON => {
      return { id: s.id, text: s.text, isCompleted: s.isCompleted }
    })
    return {
      id: this.id,
      goalId: this.goalId,
      title: this.title,
      description: this.description,
      duration: this.duration,
      priority: this.priority as string,
      isCompleted: this.isCompleted,
      createTime: this.createTime,
      steps: stepsJSON
    }
  }

  static fromJSON(json: TaskDetailItemJSON): TaskDetailItem {
    const item: TaskDetailItem = new TaskDetailItem(
      typeof json.id === 'string' ? json.id : '',
      typeof json.title === 'string' ? json.title : '',
      typeof json.description === 'string' ? json.description : '',
      typeof json.duration === 'string' ? json.duration : '',
      (json.priority === 'high' || json.priority === 'medium' || json.priority === 'low')
        ? json.priority as TaskPriority : TaskPriority.MEDIUM,
      typeof json.isCompleted === 'boolean' ? json.isCompleted : false,
      typeof json.createTime === 'number' ? json.createTime : 0
    )
    item.goalId = (typeof json.goalId === 'string') ? json.goalId : null
    if (Array.isArray(json.steps)) {
      item.steps = json.steps.map((s: TaskStepJSON): TaskStep => {
        return TaskStep.fromJSON(s)
      })
    }
    return item
  }
}

/* ============================================================
 * 5. 路由参数接口
 * ============================================================ */

export interface TaskDetailRouteParam {
  task: TaskDetailItem
}

export interface RouteParam {
  id: string
  status?: string
}

export interface TaskDetailRouteNavParam extends RouteParam {
  task: TaskDetailItem
  goalId: string
  relatedTaskId: string
}

/* ============================================================
 * 6. 4 级架构：L3 步骤工具函数
 * ============================================================ */

/**
 * L3 步骤归一化（与 steps 长度对齐）
 */
export function getCompletedStepsSafe(task: AiGeneratedTask | null | undefined): Array<boolean> {
  if (!task) return []
  const stepCount: number = Array.isArray(task.steps) ? task.steps.length : 0
  const result: Array<boolean> = []
  const source: Array<boolean> = Array.isArray(task.completedSteps) ? task.completedSteps : []
  for (let i: number = 0; i < stepCount; i++) {
    result.push(i < source.length ? source[i] === true : false)
  }
  return result
}

/**
 * L3 步骤完成状态查询
 */
export function isStepCompleted(task: AiGeneratedTask | null | undefined, stepIndex: number): boolean {
  if (!task) return false
  if (typeof stepIndex !== 'number' || stepIndex < 0) return false
  const safe: Array<boolean> = getCompletedStepsSafe(task)
  if (stepIndex >= safe.length) return false
  return safe[stepIndex] === true
}

/**
 * 反序列化工厂：从 JSON 还原 AiGeneratedTask @ObservedV2 实例
 */
export function hydrateAiGeneratedTask(json: AiGeneratedTaskJSON | null | undefined): AiGeneratedTask | null {
  return AiGeneratedTask.fromJSON(json)
}

/**
 * 序列化工厂：将 AiGeneratedTask 转为可持久化的 JSON 快照（脱壳）
 */
export function snapshotAiGeneratedTask(task: AiGeneratedTask | null | undefined): AiGeneratedTaskJSON | null {
  if (!task) return null
  return task.toJSON()
}
