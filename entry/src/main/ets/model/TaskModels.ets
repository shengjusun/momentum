/**
 * @file TaskModels - 任务详情与 AI 生成 (模块化拆分 - 任务域)
 * @description
 *   任务详情页与 AI 拆解任务的相关模型：
 *   - TaskNode: AI 拆解后的简单任务节点（值对象）
 *   - AiGeneratedTask: AI 拆解完整任务 @ObservedV2 类（含 L3 steps: TaskStep[]）
 *   - AiGeneratedTaskJSON: AiGeneratedTask 纯数据快照
 *   - TaskStep: 任务步骤 @ObservedV2 类
 *   - TaskDetailItem: 任务详情完整任务 @ObservedV2 类
 *   - RouteParam: 通用路由参数
 *   - TaskDetailRouteParam: 任务详情页路由参数（早期版本）
 *   - TaskDetailRouteNavParam: 任务详情页路由参数（4 级架构扩展）
 *   - 工具函数：isStepCompleted / hydrateAiGeneratedTask / snapshotAiGeneratedTask
 *
 * 4 级架构定位：
 *   - L2 任务：TaskNode / AiGeneratedTask
 *   - L3 步骤：TaskStep + AiGeneratedTask.steps（对象数组，完成态内联在元素上）
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

let __stepIdCounter: number = 0

/**
 * 生成 L3 步骤的稳定 id
 *
 * 用途：① 老数据迁移时给没有身份的步骤补 id（`AiGeneratedTask.fromJSON`）；
 *      ② 新增步骤时生成（`RoutePageViewModel.addStep`）。
 * 形式与 `DeepSeekService.generateTaskId` 对齐（时间戳 + 自增计数），同毫秒内不冲突。
 *
 * 为什么 id 必须稳定：步骤列表的 keyGenerator 要用它 —— key 含数组下标时，
 * 删除中间项会让后续所有 key 变化，框架判定为"新增 + 删除"，整段列表重播进场。
 */
export function generateStepId(): string {
  __stepIdCounter += 1
  return 'step_' + Date.now().toString() + '_' + __stepIdCounter.toString()
}

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
  /**
   * L3 步骤（**对象数组**，每项含稳定 `id`）
   *
   * ⚠️ 历史格式是 `string[]`（步骤文本）+ `boolean[]`（完成状态）两个平行数组，
   *    由 `AiGeneratedTask.fromJSON` 做格式嗅探后迁移，读取一律归一化为 `TaskStep`。
   */
  steps: TaskStepJSON[]
  status: string
  /**
   * @deprecated 历史「平行布尔数组」写法的残留字段
   *
   * 仅为**读取老数据**保留：迁移完成度状态由 `steps[i].isCompleted` 承载，
   * `toJSON` 不再写出本字段（新数据中恒为 `undefined`）。
   */
  completedSteps?: boolean[]
  /** 计划开始时间戳（毫秒），默认 0（用于番茄钟、日程安排） */
  plannedTime?: number
  /** 实际完成时间戳（毫秒），默认 0（用于统计分析） */
  actualCompletionTime?: number
  /** 截止时间戳（毫秒），默认 0（用于截止日期提醒、四象限法则） */
  deadline?: number
  /**
   * 完成态最后变更时刻（毫秒）—— 云同步裁决「完成 vs 取消完成」的唯一依据
   *
   * ⚠️ 为什么必须与 `actualCompletionTime` 分开（2026-09-17 新增）：
   *   1. `actualCompletionTime` 的语义是「**首次**完成时刻」，取消完成会归零、
   *      再次完成才重新补 —— 它**无法表达"取消"这个动作发生在什么时候**；
   *   2. L2 任务**没有自己的 `updatedAt`**（它作为 `goals[G].tasks[]` 的元素，
   *      随整个目标块参与合并），裁决时若退化用目标块的 `updatedAt`，
   *      那么"平板改了个目标名"就会把"手机勾的完成"压掉（= 跨设备丢更新）；
   *   3. 本字段只在**完成态发生变化**时刷新（完成与取消都刷），
   *      是一条**只反映完成态**的时间轴，与改名/改描述/改预估耗时等无关编辑彻底分家。
   *
   * 老数据缺失此字段 → 反序列化视为 0（= 从未变更过完成态，向后兼容）
   */
  completionUpdatedAt?: number
}

/* ============================================================
 * 3. AiGeneratedTask @ObservedV2 类（L2 任务）
 * ============================================================ */

/**
 * AI 拆解完整任务 @ObservedV2 类
 *
 * V2 深度修复：
 *   - 从 interface 升级为 @ObservedV2 class
 *   - steps 变更可被 @Trace 精确追踪（TaskStep.isCompleted 亦为 @Trace）
 *   - 勾选 Step 时只需修改 task.steps[i].isCompleted，无需重建整个 goals 数组
 *   - 持久化时通过 toJSON() 脱壳，读取时通过 fromJSON() 复活
 */
@ObservedV2
export class AiGeneratedTask {
  @Trace id: Id = ''
  @Trace taskName: string = ''
  @Trace estimatedTime: number = 0
  @Trace priority: TaskPriority = TaskPriority.MEDIUM
  /**
   * L3 步骤（**对象数组**，每项含稳定 id）
   *
   * ⚠️ 由 `Array<string>` + `Array<boolean>` 两个平行数组**合并**而来：
   *   - 对象化后 keyGenerator 可用 `step.id`，列表增删动效才有稳定身份
   *     （原先只能靠「下标 + stepVersion」，导致删中间项时整段列表重播进场）；
   *   - 顺带消除「两条数组靠下标对齐」的隐患 —— 任何一处漏同步就错位，
   *     原先的 `getCompletedStepsSafe` 正是为兜底这种错位而生；
   *   - `TaskStep` 自身是 `@ObservedV2` + `@Trace isCompleted`，
   *     改勾选只动单个元素即可被精确追踪。
   */
  @Trace steps: TaskStep[] = []
  @Trace status: TaskStatus = TaskStatus.PENDING
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
   * 完成态最后变更时刻（毫秒）
   * - **完成与取消完成都会刷新**（与 `actualCompletionTime` 的"首次完成时刻"语义不同）
   * - 云同步裁决「完成 vs 取消完成」时，两侧各取自己的本字段比较，避免跨类型比较误判
   * - 默认 0 表示从未变更过完成态（老数据）→ 裁决时退化为旧规则
   * - 详见 `AiGeneratedTaskJSON.completionUpdatedAt` 的完整说明
   */
  @Trace completionUpdatedAt: Timestamp = 0

  /**
   * 完整构造函数（10 个参数，后 4 个时间字段默认 0 以保证向后兼容）
   *
   * 向后兼容策略：
   *   - 新增的 plannedTime / actualCompletionTime / deadline / completionUpdatedAt 均带默认值 0
   *   - 老代码以 7 参数调用（如 RoutePage/AIPage/GoalDetailPage 的空参占位）无需任何修改
   *   - 仅需要透传时间字段的场景（如 fromJSON、extractToHomeTodo）才显式传入
   *
   * ⚠️ 2026-09-16 **破坏性变更**：`steps` 由 `Array<string>` 改为 `TaskStep[]`，
   *    并**移除** `completedSteps` 参数（参数个数 10 → 9）。
   *    调用点须同步改造：
   *      - 原 `(..., [], TaskStatus.PENDING, [])` → `(..., [], TaskStatus.PENDING)`
   *      - 原 `(..., steps, status, completedSteps, ...)` → `(..., stepObjs, status, ...)`
   *
   * ⚠️ 2026-09-17 追加 `completionUpdatedAt`（第 10 个参数，带默认值）：
   *    **非破坏性** —— 现有 7/9 参数调用点一律无需改动，仅 `fromJSON` 显式透传。
   *
   * @param id - 任务唯一标识
   * @param taskName - 任务名称
   * @param estimatedTime - 预估耗时（分钟）
   * @param priority - 优先级
   * @param steps - L3 步骤对象数组（`TaskStep`：id / text / isCompleted）
   * @param status - 任务状态
   * @param plannedTime - 计划开始时间戳，默认 0（向后兼容）
   * @param actualCompletionTime - 实际完成时间戳，默认 0（向后兼容）
   * @param deadline - 截止时间戳，默认 0（向后兼容）
   * @param completionUpdatedAt - 完成态最后变更时刻，默认 0（云同步裁决依据）
   */
  constructor(
    id: Id,
    taskName: string,
    estimatedTime: number,
    priority: TaskPriority,
    steps: TaskStep[],
    status: TaskStatus,
    plannedTime: Timestamp = 0,
    actualCompletionTime: Timestamp = 0,
    deadline: Timestamp = 0,
    completionUpdatedAt: Timestamp = 0
  ) {
    this.id = id
    this.taskName = taskName
    this.estimatedTime = estimatedTime
    this.priority = priority
    this.steps = steps
    this.status = status
    this.plannedTime = plannedTime
    this.actualCompletionTime = actualCompletionTime
    this.deadline = deadline
    this.completionUpdatedAt = completionUpdatedAt
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
    // L3 步骤迁移：兼容两种历史格式（**格式嗅探，按元素类型判定**）
    //   ① 新格式：steps = [{ id, text, isCompleted }]
    //   ② 老格式：steps = ["步骤文本", ...] + completedSteps = [true/false, ...]（两个平行数组）
    // 老格式的步骤没有身份，就地补 id —— 补一次即稳定，之后增删动效才有 key 可用。
    const safeSteps: TaskStep[] = []
    const rawSteps: Object[] = Array.isArray(json.steps) ? json.steps as Object[] : []
    const rawCompleted: Array<boolean> = Array.isArray(json.completedSteps) ? json.completedSteps : []
    for (let i: number = 0; i < rawSteps.length; i++) {
      const raw: Object = rawSteps[i]
      if (typeof raw === 'string') {
        const done: boolean = i < rawCompleted.length && rawCompleted[i] === true
        safeSteps.push(new TaskStep(generateStepId(), raw as string, done))
      } else {
        safeSteps.push(TaskStep.fromJSON(raw as TaskStepJSON))
      }
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
    // 完成态时间轴容错：老数据没有此字段（undefined）→ 0（= 从未变更过完成态）
    const safeCompletionUpdatedAt: Timestamp =
      (typeof json.completionUpdatedAt === 'number' && !isNaN(json.completionUpdatedAt)) ?
        json.completionUpdatedAt : 0
    return new AiGeneratedTask(
      json.id,
      typeof json.taskName === 'string' ? json.taskName : '',
      (typeof json.estimatedTime === 'number' && !isNaN(json.estimatedTime)) ?
        Math.max(0, Math.floor(json.estimatedTime)) : 0,
      priorityEnum,
      safeSteps,
      statusEnum,
      safePlannedTime,
      safeActualCompletionTime,
      safeDeadline,
      safeCompletionUpdatedAt
    )
  }

  toJSON(): AiGeneratedTaskJSON {
    return {
      id: this.id,
      taskName: this.taskName,
      estimatedTime: this.estimatedTime,
      priority: this.priority as string,
      // L3 步骤对象化脱壳。
      // ⚠️ 不再写出 completedSteps —— 完成状态已并入 steps[i].isCompleted，
      //    这也是「两条数组靠下标对齐」隐患的根治点。
      steps: Array.isArray(this.steps)
        ? this.steps.map((s: TaskStep): TaskStepJSON => s.toJSON())
        : [],
      status: this.status as string,
      // 新增时间字段序列化（与 fromJSON 对称）
      plannedTime: this.plannedTime,
      actualCompletionTime: this.actualCompletionTime,
      deadline: this.deadline,
      // 完成态时间轴：云同步裁决「完成 vs 取消完成」的依据，必须随快照持久化
      completionUpdatedAt: this.completionUpdatedAt
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
 * L3 步骤完成状态查询
 *
 * ⚠️ 签名与语义**刻意保持不变**（仍按下标查询）—— 对象化改造保留了这层兼容，
 *    使全部"只读"调用点无需改动（这是把 103 处引用压到可控范围的关键）。
 */
export function isStepCompleted(task: AiGeneratedTask | null | undefined, stepIndex: number): boolean {
  if (!task) return false
  if (typeof stepIndex !== 'number' || stepIndex < 0) return false
  const steps: TaskStep[] = Array.isArray(task.steps) ? task.steps : []
  if (stepIndex >= steps.length) return false
  return steps[stepIndex].isCompleted === true
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
