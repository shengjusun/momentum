/**
 * @file HomeModels - 首页待办 (模块化拆分 - 首页域)
 * @description
 *   首页（HomePage）相关数据模型：
 *   - HomeStat: 首页统计卡片项（值对象）
 *   - HomeTodoItem: 首页待办任务 @ObservedV2 类（L4 待办）
 *   - HomeTodoItemJSON: HomeTodoItem 的纯数据快照（用于 JSON 序列化）
 *   - buildHomeTodoItem: 顶层工厂函数（4 级架构强校验）
 *   - isValidHomeTodoItem: 类型守卫
 *   - hydrateHomeTodoItem: 反序列化工厂
 *   - snapshotHomeTodoItem: 序列化工厂
 *
 * 4 级架构定位：
 *   - L4 待办：HomeTodoItem（含 relatedTaskId / relatedGoalId 关联字段）
 *
 * V2 规范：
 *   - Model 类使用 @ObservedV2 装饰
 *   - 响应式属性使用 @Trace 装饰
 *   - 严禁使用 V1 装饰器
 *
 * 废弃代码（已清理，不在本文件）：
 *   - class Models（旧的 @ObservedV2 混乱类，与 HomeTodoItem 重名）
 *   - type HomeTodoItemLegacy（占位类型别名）
 *
 * @module model
 * @date 2026-06-23
 */

import { Id, Timestamp, TaskPriority } from './BaseTypes'

/* ============================================================
 * 1. 首页统计卡片项
 * ============================================================ */

/**
 * 首页统计卡片项（值对象，不可变 - 使用 interface）
 * 用于：完成率、学习时长等数据概览
 */
export interface HomeStat {
  /** 唯一标识 */
  id: Id
  /** 指标标题（如"今日完成率"） */
  label: string
  /** 指标数值（字符串，便于展示"85%"或"2.5h"） */
  value: string
  /** 单位（如"%"、"h"、"min"） */
  unit: string
  /** 趋势方向 */
  trend: 'up' | 'down' | 'flat'
  /** 较昨日变化值（已格式化） */
  delta: string
  /** 图标资源（已 toString） */
  icon: string
}

/* ============================================================
 * 2. HomeTodoItem 的纯数据快照
 * ============================================================ */

/**
 * HomeTodoItem 的纯数据快照（用于 JSON 序列化/反序列化）
 * 必须与 HomeTodoItem 类的字段一一对应
 *
 * 关键约束：
 *   - 反序列化后必须用 new HomeTodoItem() 重新构造代理
 *   - createTime 字段必传（首次构造时由 hydrateTask 注入 Date.now()）
 *   - relatedTaskId / relatedGoalId 必传（4 级架构关联必填项）
 *   - plannedTime/actualCompletionTime/deadline 为可选字段（向后兼容），默认为 0
 */
export interface HomeTodoItemJSON {
  id: string
  title: string
  goalName: string
  duration: string
  /** 序列化后是字符串（'high' / 'medium' / 'low'），由 parsePriority 还原为 enum */
  priority: string
  isCompleted: boolean
  /** 创建时间戳（数字，毫秒） */
  createTime: number
  /** 4 级架构：指向原 L2 任务的唯一标识符（不可为空） */
  relatedTaskId: string
  /** 4 级架构：指向所属 L1 目标的唯一标识符（不可为空） */
  relatedGoalId: string
  /** 计划开始时间戳（毫秒），默认 0（用于番茄钟、日程安排） */
  plannedTime?: number
  /** 实际完成时间戳（毫秒），默认 0（用于统计分析） */
  actualCompletionTime?: number
  /** 截止时间戳（毫秒），默认 0（用于截止日期提醒） */
  deadline?: number
  /** 累计专注轮数，默认 0（番茄钟完成联动，向后兼容） */
  focusCount?: number
  /** 累计专注时长（毫秒），默认 0（番茄钟完成联动，向后兼容） */
  focusMillis?: number
  /**
   * 墓碑标记（云同步软删除），默认 false
   * - true 表示该待办已被删除，条目仍留在底层数组里用于跨设备传播删除
   * - 老数据缺失此字段 → 反序列化时视为 false（向后兼容）
   * - ⚠️ UI / 统计 / 提醒 / 导出一律读取 liveTasks 视图，禁止直接遍历底层 taskList
   */
  isDeleted?: boolean
  /**
   * 条目最后修改时间戳（毫秒）—— 云同步冲突裁决唯一依据
   * - 新建时写入当前时间；任何会让条目内容变化的写操作都要刷新
   * - 老数据缺失此字段 → 0，冲突裁决退化为 createTime 兜底
   * - ⚠️ 同步落地（applyCloudSnapshot）**禁止**改写本字段，否则伪造"本机更新"导致反复上传
   */
  updatedAt?: number
  /**
   * 完成态最后变更时刻（毫秒）—— 跨设备「完成 / 取消完成」裁决唯一依据
   * - **只有 isCompleted 真的翻转时才刷新**（勾选、取消勾选；L2→L4 联动同步同理）
   * - 与 `actualCompletionTime` 解耦：后者语义是"首次完成时刻、取消即归零"，
   *   承载不了"谁最后改过完成态"（取消这个动作在它上面不留痕迹）
   * - ⚠️ 专注累计 / 改截止 / 目标改名级联 / 墓碑等**非完成类写操作禁止刷新**本字段，
   *   否则对端一次无关编辑就能把本机刚声明的完成压掉（跨设备丢更新）
   * - 老数据缺失此字段 → 0，云同步裁决退化为按条目既有时间戳兜底
   * - ⚠️ 同步落地（applyCloudSnapshot）**禁止**改写本字段
   */
  completionUpdatedAt?: number
}

/* ============================================================
 * 3. 首页待办任务 @ObservedV2 类（L4 待办）
 * ============================================================ */

/**
 * ============================================================
 * V2 响应式 HomeTodoItem 类（用于今日待办 L4）
 *
 * 关键约束：
 *   1. 必须用 @ObservedV2 装饰整个类
 *   2. 每个需要响应式更新的字段必须用 @Trace
 *   3. 反序列化（JSON.parse）后必须用 new HomeTodoItem() 重建代理
 *      否则 @Trace 失效，UI 永远不会刷新
 *   4. V2 修正：toggleTask 翻转状态时直接修改 task.isCompleted 即可触发 @Trace 响应
 *      （V1 的"必须构造新实例"限制在 V2 已解除）
 *   5. 构造函数严格 12 个参数（含 createTime + relatedTaskId + relatedGoalId + 时间字段）
 *   6. 4 级架构必填：relatedTaskId/relatedGoalId 不可为空字符串
 *   7. 时间字段（plannedTime/actualCompletionTime/deadline）默认为 0，向后兼容
 * ============================================================
 */
@ObservedV2
export class HomeTodoItem {
  /** 唯一标识 */
  @Trace id: Id = ''
  /** 任务标题 */
  @Trace title: string = ''
  /** 所属目标/项目名（冗余展示字段，反查以 relatedGoalId 为准） */
  @Trace goalName: string = ''
  /** 预计耗时（如"30 min"） */
  @Trace duration: string = ''
  /** 优先级 */
  @Trace priority: TaskPriority = TaskPriority.LOW
  /** 关键：必须 @Trace，否则删除线、勾选态、置灰效果不会刷新 */
  @Trace isCompleted: boolean = false
  /** 创建时间戳（用于排序/统计） */
  @Trace createTime: Timestamp = 0
  /**
   * 4 级架构：指向原 L2 任务的唯一标识符
   * - 用于执行流（首页点击 → 任务详情页）反查 L3 步骤数据
   * - 不可为空字符串（创建时由 buildHomeTodoItem 强校验）
   */
  @Trace relatedTaskId: Id = ''
  /**
   * 4 级架构：指向所属 L1 目标的唯一标识符
   * - 用于回写流（步骤勾选）定位原目标
   * - 不可为空字符串（创建时由 buildHomeTodoItem 强校验）
   */
  @Trace relatedGoalId: Id = ''
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
   * - 当 isCompleted 为 true 且此字段为 0 时，应补全为当前时间
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
   * 累计专注轮数（番茄钟完成联动）
   * - 由 HomeViewModel 监听 FOCUS_COMPLETED 事件累加
   * - 默认值 0，向后兼容（老数据无此字段）
   */
  @Trace focusCount: number = 0
  /**
   * 累计专注时长（毫秒，番茄钟完成联动）
   * - 与 focusCount 同步累加，供任务详情展示"已专注 N 轮 · X 分钟"
   */
  @Trace focusMillis: number = 0
  /**
   * 墓碑标记（云同步软删除）
   * - 删除待办时只置 true，不从 taskList 数组移除 → 保证删除能跨设备传播、不复活
   * - 老数据默认为 false
   */
  @Trace isDeleted: boolean = false
  /**
   * 条目最后修改时间戳（毫秒）—— 跨设备冲突裁决依据（谁的值大谁胜出）
   * - 同步落地时禁止改写（见 HomeTodoItemJSON.updatedAt 说明）
   */
  @Trace updatedAt: Timestamp = 0
  /**
   * 完成态最后变更时刻（毫秒）—— 跨设备「完成 / 取消」裁决依据
   * - 仅当 isCompleted 真的翻转时刷新；**非完成类写操作禁止刷新**（见 HomeTodoItemJSON 说明）
   * - 与 L2 的 AiGeneratedTask.completionUpdatedAt 构成**同类对称**的两条轴
   */
  @Trace completionUpdatedAt: Timestamp = 0

  /**
   * 完整构造函数（12 个必填/默认参数 + 3 个云同步扩展字段）
   * @param createTime - 必传创建时间戳
   * @param relatedTaskId - 必传关联的 L2 任务 ID
   * @param relatedGoalId - 必传关联的 L1 目标 ID
   * @param plannedTime - 计划开始时间，默认 0（向后兼容）
   * @param actualCompletionTime - 实际完成时间，默认 0（向后兼容）
   * @param deadline - 截止时间，默认 0（向后兼容）
   * @param isDeleted - 墓碑标记，默认 false（向后兼容，云同步软删除用）
   * @param updatedAt - 条目最后修改时间戳，默认 0（向后兼容，冲突裁决用）
   * @param completionUpdatedAt - 完成态最后变更时刻，默认 0（向后兼容，完成态裁决用）
   */
  constructor(
    id: Id,
    title: string,
    goalName: string,
    duration: string,
    priority: TaskPriority,
    isCompleted: boolean,
    createTime: Timestamp,
    relatedTaskId: Id,
    relatedGoalId: Id,
    plannedTime: Timestamp = 0,
    actualCompletionTime: Timestamp = 0,
    deadline: Timestamp = 0,
    isDeleted: boolean = false,
    updatedAt: Timestamp = 0,
    completionUpdatedAt: Timestamp = 0
  ) {
    this.id = id
    this.title = title
    this.goalName = goalName
    this.duration = duration
    this.priority = priority
    this.isCompleted = isCompleted
    this.createTime = createTime
    this.relatedTaskId = relatedTaskId
    this.relatedGoalId = relatedGoalId
    this.plannedTime = plannedTime
    this.actualCompletionTime = actualCompletionTime
    this.deadline = deadline
    this.isDeleted = isDeleted
    this.updatedAt = updatedAt
    this.completionUpdatedAt = completionUpdatedAt
  }

  /**
   * 简化构造（用于 toggleTask 翻转状态）
   * - V2 修正：@ObservedV2 + @Trace 下直接修改 isCompleted 即可触发 UI 刷新
   * - 此方法保留用于需要构造新实例的特殊场景
   * - 保留所有原始字段（goalName/duration/priority/createTime/时间字段）
   *
   * @param source - 原始 HomeTodoItem 实例（透传所有字段）
   * @param isCompleted - 新的完成状态
   */
  static quick(source: HomeTodoItem, isCompleted: boolean): HomeTodoItem {
    if (!source) {
      return new HomeTodoItem('', '', '', '', TaskPriority.MEDIUM, isCompleted, Date.now(), '', '', 0, 0, 0)
    }
    return new HomeTodoItem(
      source.id,
      source.title,
      source.goalName,
      source.duration,
      source.priority,
      isCompleted,
      source.createTime,
      source.relatedTaskId,
      source.relatedGoalId,
      source.plannedTime,
      source.actualCompletionTime,
      source.deadline,
      source.isDeleted,
      source.updatedAt,
      source.completionUpdatedAt
    )
  }
}

/* ============================================================
 * 4. 4 级架构：L4 待办工厂函数与守卫
 * ============================================================ */

/**
 * V2 规范：HomeTodoItem 顶层工厂函数
 *
 * 4 级架构定位：L4 待办构造入口
 *  - 调用方：routeVM.addGoal 时的"摘取流"、homeVM 复活场景
 *  - 必填校验：id、title、relatedTaskId、relatedGoalId 不可为空
 *  - 强校验：relatedTaskId/relatedGoalId 缺失则抛错（避免空关联数据）
 *
 * 关键约束：
 *  - 必须 new HomeTodoItem() 构造 @ObservedV2 代理实例
 *  - 工厂返回的是 @Trace 代理对象，UI 响应式可立即生效
 *  - 时间字段（plannedTime/actualCompletionTime/deadline）可选，默认 0（向后兼容）
 *
 * @returns HomeTodoItem @ObservedV2 实例
 */
export function buildHomeTodoItem(
  id: Id,
  title: string,
  goalName: string,
  duration: string,
  priority: TaskPriority,
  isCompleted: boolean,
  createTime: Timestamp,
  relatedTaskId: Id,
  relatedGoalId: Id,
  plannedTime: Timestamp = 0,
  actualCompletionTime: Timestamp = 0,
  deadline: Timestamp = 0,
  isDeleted: boolean = false,
  updatedAt: Timestamp = 0,
  /**
   * 完成态最后变更时刻（毫秒），默认 0（向后兼容）
   * - 仅当本次构造是"完成态真的翻转"（如摘取一个已完成的 L2 任务）时才传值，
   *   一般新建待办传 0（= 从未变更过完成态）
   */
  completionUpdatedAt: Timestamp = 0,
  /**
   * 是否强制要求 L1/L2 关联（4 级架构红线）
   * - true（默认）：从目标摘取 / AI 拆解生成 —— 必须同时有 relatedTaskId 与 relatedGoalId
   * - false：**首页手动添加的待办** —— 天生没有关联目标/任务，跳过红线
   * ⚠️ 与 isValidHomeTodoItem 的第二参同义，两者必须成对传，
   *    否则会出现"工厂放行了、入库校验又拦下"（或反之）的自相矛盾。
   */
  requireRelation: boolean = true
): HomeTodoItem {
  // 1. 必填校验
  if (typeof id !== 'string' || id.length === 0) {
    throw new Error('buildHomeTodoItem: id is required and must be non-empty string')
  }
  if (typeof title !== 'string' || title.length === 0) {
    throw new Error('buildHomeTodoItem: title is required and must be non-empty string')
  }
  // 2. 4 级架构强校验：relatedTaskId / relatedGoalId 不可为空（手动待办路径可豁免）
  if (requireRelation) {
    if (typeof relatedTaskId !== 'string' || relatedTaskId.length === 0) {
      throw new Error('buildHomeTodoItem: relatedTaskId is required (4 级架构必填，关联 L2 任务)')
    }
    if (typeof relatedGoalId !== 'string' || relatedGoalId.length === 0) {
      throw new Error('buildHomeTodoItem: relatedGoalId is required (4 级架构必填，关联 L1 目标)')
    }
  } else {
    // 豁免路径仍做类型兜底：空串可接受，undefined/null 仍拒绝（否则会污染数据模型）
    if (typeof relatedTaskId !== 'string') {
      throw new Error('buildHomeTodoItem: relatedTaskId must be string (relation optional path)')
    }
    if (typeof relatedGoalId !== 'string') {
      throw new Error('buildHomeTodoItem: relatedGoalId must be string (relation optional path)')
    }
  }
  // 3. 时间戳容错
  const safeCreateTime: Timestamp = (typeof createTime === 'number' && !isNaN(createTime)) ?
    createTime : Date.now()
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
  // 完成态轴**不做"新建即当前时间"兜底**：0 的语义是"从未变更过完成态"，
  // 伪造成本机时刻会让对端一次无关编辑就把这里的完成态压掉（见 HomeTodoItemJSON 说明）
  const safeCompletionUpdatedAt: Timestamp =
    (typeof completionUpdatedAt === 'number' && !isNaN(completionUpdatedAt) && completionUpdatedAt > 0) ?
      completionUpdatedAt : 0
  // 4. 显式 new 构造 @ObservedV2 代理实例
  return new HomeTodoItem(
    id,
    title,
    typeof goalName === 'string' ? goalName : '',
    typeof duration === 'string' ? duration : '',
    priority,
    typeof isCompleted === 'boolean' ? isCompleted : false,
    safeCreateTime,
    relatedTaskId,
    relatedGoalId,
    safePlannedTime,
    safeActualCompletionTime,
    safeDeadline,
    safeIsDeleted,
    safeUpdatedAt,
    safeCompletionUpdatedAt
  )
}

/**
 * 手动待办工厂（首页 FAB →「添加待办」专用）
 *
 * 存在的意义：手动待办**天生没有 L1 目标 / L2 任务关联**，若直接用
 * `buildHomeTodoItem` 走 4 级架构红线，会在工厂内直接抛
 * `relatedTaskId is required` → 用户点「添加」必失败。
 * 这里把豁免显式收口成一处，调用方不必自己拼一长串位置参数。
 *
 * ⚠️ 手动待办不参与目标进度联动（目标侧所有联动方法都以 relatedXxxId 判空跳过）
 *
 * @param id - 待办 ID
 * @param title - 标题（已 trim，非空）
 * @param priority - 优先级（由"选象限"反推）
 * @param deadline - 截止时间戳（0 = 无；同样由"选象限"反推）
 */
export function buildManualTodoItem(id: Id, title: string, priority: TaskPriority,
  deadline: Timestamp): HomeTodoItem {
  // 末三位依次为：isDeleted=false、updatedAt=0（工厂按"新建"语义写入当前时间）、
  // completionUpdatedAt=0（新建待办从未变更过完成态）、
  // requireRelation=false（无 L1/L2 关联，豁免 4 级架构红线）
  return buildHomeTodoItem(
    id, title, '', '', priority, false, Date.now(), '', '', 0, 0,
    deadline > 0 ? deadline : 0, false, 0, 0, false
  )
}

/**
 * 类型守卫：校验 HomeTodoItem 关联完整性（4 级架构核心）
 *  - id / title 不可为空
 *  - relatedTaskId / relatedGoalId 默认不可为空（4 级架构红线，摘取路径）
 *  - priority 必须是合法枚举值
 *  - createTime 必须是有效数字
 *
 * @param todo - 待校验的待办项
 * @param requireRelation - 是否强制校验关联字段（默认 true）。
 *   ⚠️ 手动创建的待办（首页「添加待办」）**天生没有关联目标/任务**，
 *   是合法的一等公民，调用方须传 false 放行 —— 只做类型校验（string），不要求非空。
 * @returns 是否通过校验
 */
export function isValidHomeTodoItem(todo: HomeTodoItem | null | undefined,
  requireRelation: boolean = true): boolean {
  if (!todo) return false
  if (typeof todo.id !== 'string' || todo.id.length === 0) return false
  if (typeof todo.title !== 'string' || todo.title.length === 0) return false
  if (typeof todo.isCompleted !== 'boolean') return false
  if (typeof todo.createTime !== 'number' || isNaN(todo.createTime)) return false
  // 4 级架构红线：摘取的待办 relatedTaskId / relatedGoalId 不可为空；
  // 手动待办无关联，退化为仅类型校验（联动逻辑全部以 `relatedXxxId &&` 判空，天然兼容）
  if (typeof todo.relatedTaskId !== 'string' ||
    (requireRelation && todo.relatedTaskId.length === 0)) return false
  if (typeof todo.relatedGoalId !== 'string' ||
    (requireRelation && todo.relatedGoalId.length === 0)) return false
  // priority 枚举值校验
  if (todo.priority !== TaskPriority.HIGH &&
      todo.priority !== TaskPriority.MEDIUM &&
      todo.priority !== TaskPriority.LOW) {
    return false
  }
  return true
}

/**
 * 反序列化守卫：从 JSON 还原 HomeTodoItem 时校验字段类型
 *  - 用于持久化"复活"流程
 *  - 校验失败时返回 null，由调用方决定兜底策略（默认空对象 / 跳过 / 告警）
 *  - 向后兼容：新字段（plannedTime/actualCompletionTime/deadline）缺失时默认为 0
 *
 * ⚠️ 关联字段（relatedTaskId / relatedGoalId）**仅做类型校验，允许空串**：
 *    手动创建的待办（首页「添加待办」）天生没有关联目标/任务。
 *    若在此强校验非空，手动待办落盘后冷启动复活会被拒（return null）→ 静默丢数据。
 *    摘取路径的"必须非空"校验由 `isValidHomeTodoItem(todo, true)` 在入库时把守。
 *
 * @param json - 序列化快照
 * @returns 校验通过返回 HomeTodoItem @ObservedV2 实例；否则 null
 */
export function hydrateHomeTodoItem(json: HomeTodoItemJSON | null | undefined): HomeTodoItem | null {
  if (!json) return null
  if (typeof json.id !== 'string' || json.id.length === 0) return null
  if (typeof json.relatedTaskId !== 'string') return null
  if (typeof json.relatedGoalId !== 'string') return null
  // priority 字符串 → enum
  let priorityEnum: TaskPriority = TaskPriority.MEDIUM
  if (json.priority === 'high') priorityEnum = TaskPriority.HIGH
  else if (json.priority === 'low') priorityEnum = TaskPriority.LOW
  // 时间字段容错：老版本数据可能没有这些字段，默认 0（向后兼容）
  const safePlannedTime: Timestamp = (typeof json.plannedTime === 'number' && !isNaN(json.plannedTime)) ?
    json.plannedTime : 0
  const safeActualCompletionTime: Timestamp = (typeof json.actualCompletionTime === 'number' && !isNaN(json.actualCompletionTime)) ?
    json.actualCompletionTime : 0
  const safeDeadline: Timestamp = (typeof json.deadline === 'number' && !isNaN(json.deadline)) ?
    json.deadline : 0
  const safeFocusCount: number = (typeof json.focusCount === 'number' && !isNaN(json.focusCount)) ?
    json.focusCount : 0
  const safeFocusMillis: number = (typeof json.focusMillis === 'number' && !isNaN(json.focusMillis)) ?
    json.focusMillis : 0
  // 云同步扩展字段容错：老数据缺失 → isDeleted=false、updatedAt=0（后续由 createTime 兜底裁决）
  const safeIsDeleted: boolean = typeof json.isDeleted === 'boolean' ? json.isDeleted : false
  const safeUpdatedAt: number = (typeof json.updatedAt === 'number' && !isNaN(json.updatedAt) && json.updatedAt > 0) ?
    json.updatedAt : 0
  // 完成态轴：老数据 / 未声明过完成 → 0（裁决侧退化为按条目既有时间戳兜底）
  const safeCompletionUpdatedAt: number =
    (typeof json.completionUpdatedAt === 'number' && !isNaN(json.completionUpdatedAt) && json.completionUpdatedAt > 0) ?
      json.completionUpdatedAt : 0
  // 显式 new 构造 @ObservedV2 代理
  const item: HomeTodoItem = new HomeTodoItem(
    json.id,
    typeof json.title === 'string' ? json.title : '',
    typeof json.goalName === 'string' ? json.goalName : '',
    typeof json.duration === 'string' ? json.duration : '',
    priorityEnum,
    typeof json.isCompleted === 'boolean' ? json.isCompleted : false,
    typeof json.createTime === 'number' ? json.createTime : 0,
    json.relatedTaskId,
    json.relatedGoalId,
    safePlannedTime,
    safeActualCompletionTime,
    safeDeadline,
    safeIsDeleted,
    safeUpdatedAt,
    safeCompletionUpdatedAt
  )
  // 专注统计字段（构造函数不含，直接赋值，向后兼容老数据）
  item.focusCount = safeFocusCount
  item.focusMillis = safeFocusMillis
  return item
}

/**
 * 序列化守卫：将 HomeTodoItem 转为可持久化的 JSON 快照
 *  - 显式字段提取（"脱壳"），排除 @Trace 代理痕迹
 *  - 必含 4 级架构关联字段（relatedTaskId / relatedGoalId）
 *  - 新增时间字段（plannedTime/actualCompletionTime/deadline），用于后续番茄钟、四象限等功能
 *
 * @param todo - 待序列化的 HomeTodoItem 实例
 * @returns JSON 快照（不含代理）
 */
export function snapshotHomeTodoItem(todo: HomeTodoItem | null | undefined): HomeTodoItemJSON | null {
  if (!todo) return null
  if (!isValidHomeTodoItem(todo)) return null
  return {
    id: todo.id,
    title: todo.title,
    goalName: todo.goalName,
    duration: todo.duration,
    priority: todo.priority as string,
    isCompleted: todo.isCompleted,
    createTime: todo.createTime,
    relatedTaskId: todo.relatedTaskId,
    relatedGoalId: todo.relatedGoalId,
    plannedTime: todo.plannedTime,
    actualCompletionTime: todo.actualCompletionTime,
    deadline: todo.deadline,
    focusCount: todo.focusCount,
    focusMillis: todo.focusMillis,
    isDeleted: todo.isDeleted === true,
    updatedAt: typeof todo.updatedAt === 'number' && !isNaN(todo.updatedAt) ? todo.updatedAt : 0,
    completionUpdatedAt: typeof todo.completionUpdatedAt === 'number' && !isNaN(todo.completionUpdatedAt) ?
      todo.completionUpdatedAt : 0
  }
}

/* ============================================================
 * 5. 艾森豪威尔四象限法则（功能5）
 * ============================================================ */

/**
 * 艾森豪威尔四象限枚举
 *
 * 划分规则（基于 priority 重要度 + deadline 紧急度）：
 *   - 重要度：HIGH 视为"重要"，MEDIUM/LOW 视为"不重要"
 *   - 紧急度：deadline 非零且距截止时间 < 24 小时视为"紧急"，否则视为"不紧急"
 *     （deadline === 0 表示未设置截止时间，默认归入"不紧急"象限）
 *
 * 四个象限（按艾森豪威尔原典命名）：
 *   - Q1_IMPORTANT_URGENT:   重要且紧急（立即做）
 *   - Q2_IMPORTANT_NOT_URGENT: 重要不紧急（计划做）
 *   - Q3_NOT_IMPORTANT_URGENT: 紧急不重要（委托/快速做）
 *   - Q4_NOT_IMPORTANT_NOT_URGENT: 不紧急不重要（尽量减少）
 */
export enum EisenhowerQuadrant {
  /** 第一象限：重要且紧急（立即做） */
  Q1_IMPORTANT_URGENT = 'q1_important_urgent',
  /** 第二象限：重要不紧急（计划做） */
  Q2_IMPORTANT_NOT_URGENT = 'q2_important_not_urgent',
  /** 第三象限：紧急不重要（委托/快速做） */
  Q3_NOT_IMPORTANT_URGENT = 'q3_not_important_urgent',
  /** 第四象限：不紧急不重要（尽量减少） */
  Q4_NOT_IMPORTANT_NOT_URGENT = 'q4_not_important_not_urgent'
}

/**
 * 单个象限的展示数据
 *
 * 设计说明：
 *   - tasks 为 HomeTodoItem 数组，UI 侧通过 LazyForEach + DataSource 渲染
 *   - 颜色与标题由 UI 层根据 quadrant 枚举映射，保持 Model 层纯净
 *   - count 为冗余字段，便于 UI 标题栏直接显示数量而无需访问 tasks.length
 */
export interface EisenhowerQuadrantData {
  /** 象限枚举（用于 UI 颜色/标题映射） */
  quadrant: EisenhowerQuadrant
  /** 该象限的任务列表（仅包含未完成任务，已完成任务不参与四象限展示） */
  tasks: Array<HomeTodoItem>
  /** 任务数量（冗余字段，等于 tasks.length，便于 UI 直接读取） */
  count: number
}

/**
 * 完整的四象限矩阵数据
 *
 * 由 HomeViewModel.eisenhowerMatrix @Computed 属性产出
 * UI 层根据此结构渲染 2x2 Grid 矩阵
 */
export interface EisenhowerMatrix {
  /** 第一象限：重要且紧急 */
  q1: EisenhowerQuadrantData
  /** 第二象限：重要不紧急 */
  q2: EisenhowerQuadrantData
  /** 第三象限：紧急不重要 */
  q3: EisenhowerQuadrantData
  /** 第四象限：不紧急不重要 */
  q4: EisenhowerQuadrantData
}
