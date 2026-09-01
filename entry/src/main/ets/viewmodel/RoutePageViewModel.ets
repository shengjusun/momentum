// 路线页 ViewModel：目标/任务/里程碑的增删改查 + 本地持久化 + 云端快照

import {
  GoalCardItem, GoalCardItemJSON, MilestoneNode, Id, Timestamp, AiGeneratedTask,
  HomeTodoItem, TaskStatus, TaskPriority,
  buildGoalCardItem, buildHomeTodoItem,
  getCompletedStepsSafe, isStepCompleted,
  hydrateGoalCardItem, snapshotGoalCardItem
} from '../model/Models'
import { Logger } from '../common/utils/Logger'
import { StorageManager } from '../common/utils/StorageManager'
import { CommonConstants } from '../common/constants/CommonConstants'
import { PersistHelper } from '../common/utils/PersistHelper'
import { deadlineReminderService } from '../common/services/DeadlineReminderService'
// 事件总线（解耦 ViewModel 循环依赖）
import {
  eventBus,
  EventType,
  TodoCompletedPayload,
  GoalRenamedPayload,
  TaskInfoUpdatedPayload,
  TaskCompletionSyncedPayload,
  GoalRemovedPayload,
  TaskRemovedPayload,
  buildGoalRemovedPayload,
  buildTaskRemovedPayload
} from '../common/event/AppEventBus'

interface RouteVMSnapshot {
  goals: GoalCardItemJSON[]
  filterCategory: string
  version: number
}

@ObservedV2
export class RoutePageViewModel {
  private readonly tag: string = 'RoutePageViewModel'

  @Trace isLoading: boolean = true
  @Trace isLoaded: boolean = false
  @Trace loadError: boolean = false
  @Trace goals: GoalCardItem[] = []
  @Trace filterCategory: string = ''
  @Trace categories: string[] = []

  private context: Context | null = null
  // 防抖持久化：200ms 内多次修改合并为一次写入，无 onScheduleFire 回调
  // 云同步由 HomeVM 的 persistHelper onScheduleFire 统一触发 SYNC_NEEDED（同流程中 HomeVM 也会被修改）
  private persistHelper: PersistHelper = new PersistHelper(
    'RoutePageViewModel',
    async (): Promise<void> => { await this.persistData() },
    200
  )
  private isInitInProgress: boolean = false
  /** 事件总线订阅 ID（用于精确取消订阅） */
  private todoCompletedCbId: number = -1
  private clearAllCbId: number = -1
  private flushCbId: number = -1

  private static readonly CURRENT_VERSION: number = 1

  @Computed
  get activeGoalCount(): number {
    return this.goals.length
  }

  @Computed
  get averageProgress(): number {
    if (this.goals.length === 0) return 0
    let total: number = 0
    for (let i: number = 0; i < this.goals.length; i++) {
      total += this.goals[i].progress
    }
    return Math.round(total / this.goals.length)
  }

  /**
   * 已完成目标数量（@Computed 自动重算）
   * 基于 L1 目标 progress 字段判定：progress === 100 视为已完成
   */
  @Computed
  get completedGoalCount(): number {
    let count: number = 0
    for (let i: number = 0; i < this.goals.length; i++) {
      if (this.goals[i].progress === 100) {
        count++
      }
    }
    return count
  }

  /**
   * 进行中目标数量（@Computed 自动重算）
   * 基于 L1 目标 progress 字段判定：progress > 0 && progress < 100 视为进行中
   */
  @Computed
  get inProgressGoalCount(): number {
    let count: number = 0
    for (let i: number = 0; i < this.goals.length; i++) {
      const p: number = this.goals[i].progress
      if (p > 0 && p < 100) {
        count++
      }
    }
    return count
  }

  /**
   * 未开始（待办）目标数量（@Computed 自动重算）
   * 基于 L1 目标 progress 字段判定：progress === 0 视为未开始
   *
   * 与 inProgressGoalCount / completedGoalCount 构成 L1 目标三态：
   *   - pendingGoalCount:    progress === 0（待开始）
   *   - inProgressGoalCount: 0 < progress < 100（进行中）
   *   - completedGoalCount:  progress === 100（已完成）
   */
  @Computed
  get pendingGoalCount(): number {
    let count: number = 0
    for (let i: number = 0; i < this.goals.length; i++) {
      if (this.goals[i].progress === 0) {
        count++
      }
    }
    return count
  }

  /**
   * 已逾期目标数量（@Computed 自动重算）
   * 判定：deadline > 0 且 deadline < 当前时间 且 progress < 100（未完成且已过截止）
   */
  @Computed
  get overdueGoalCount(): number {
    const now: number = Date.now()
    let count: number = 0
    for (let i: number = 0; i < this.goals.length; i++) {
      const goal: GoalCardItem = this.goals[i]
      if (goal.deadline > 0 && goal.deadline < now && goal.progress < 100) {
        count++
      }
    }
    return count
  }

  @Computed
  get filteredGoals(): GoalCardItem[] {
    if (!this.filterCategory || this.filterCategory === '全部' || this.filterCategory === '') {
      return this.goals
    }
    const result: GoalCardItem[] = []
    for (let i: number = 0; i < this.goals.length; i++) {
      if (this.goals[i].category === this.filterCategory) {
        result.push(this.goals[i])
      }
    }
    return result
  }

  constructor() {
  }

  setCategory(category: string): void {
    this.filterCategory = category
    this.scheduleSave()
  }

  async init(context: Context): Promise<void> {
    if (context === null || context === undefined) {
      this.isLoading = false
      this.isLoaded = true
      return
    }
    this.context = context
    if (this.isInitInProgress) {
      Logger.info(this.tag, 'init: already in progress, skip')
      this.isLoading = false
      return
    }
    if (this.isLoaded) {
      this.isLoading = false
      return
    }
    this.isInitInProgress = true
    this.isLoading = true
    this.loadError = false
    // 注册事件总线订阅（幂等：重复 init 时先 off 再 on）
    if (this.todoCompletedCbId > 0) {
      eventBus.off(EventType.TODO_COMPLETED, this.todoCompletedCbId)
    }
    this.todoCompletedCbId = eventBus.on(EventType.TODO_COMPLETED, (payload: Object): void => {
      const p: TodoCompletedPayload = payload as TodoCompletedPayload
      this.syncStepFromTodoCompletion(p.goalId, p.taskId, p.completed)
    })
    if (this.clearAllCbId > 0) {
      eventBus.off(EventType.CLEAR_ALL_REQUESTED, this.clearAllCbId)
    }
    this.clearAllCbId = eventBus.on(EventType.CLEAR_ALL_REQUESTED, (payload: Object): void => {
      this.clearAll()
    })
    if (this.flushCbId > 0) {
      eventBus.off(EventType.FLUSH_REQUESTED, this.flushCbId)
    }
    this.flushCbId = eventBus.on(EventType.FLUSH_REQUESTED, (payload: Object): void => {
      this.flush().catch((e: Error): void => {
        Logger.warn(this.tag, 'FLUSH_REQUESTED flush failed: ' + e.message)
      })
    })
    try {
      // loadData 返回 null 表示数据损坏，使用 buildEmptySnapshot() 恢复
      const raw: RouteVMSnapshot | null = await StorageManager.loadData<RouteVMSnapshot | null>(
        context,
        CommonConstants.STORAGE_KEY_ROUTE_GOALS,
        null
      )
      const snapshot: RouteVMSnapshot = raw ?? this.buildEmptySnapshot()
      this.migrateIfNeeded(snapshot.version)
      this.applySnapshot(snapshot)
      this.isLoaded = true
      Logger.info(this.tag, 'init: loaded from storage, goalCount=' + this.goals.length.toString())
    } catch (e) {
      Logger.error(this.tag, 'init: load failed, msg=' + ((e as Error).message))
      this.loadError = true
    } finally {
      this.loadCategories()
      this.isLoading = false
      this.isInitInProgress = false
      // 目标截止提醒：应用启动数据加载完成后重建所有目标提醒
      deadlineReminderService.rescheduleAllGoals(this.goals)
    }
  }

  /**
   * 重试加载：重置状态后重新调用 init
   * - 供 RoutePage 错误态 onRetry 回调使用
   */
  retryLoad(): void {
    if (!this.context) {
      Logger.warn(this.tag, 'retryLoad: context is null, skip')
      return
    }
    this.isLoaded = false
    this.loadError = false
    this.isLoading = true
    this.init(this.context)
  }

  private loadCategories(): void {
    if (!this.context) return
    try {
      this.categories = [
        this.context.resourceManager.getStringSync($r('app.string.category_all').id),
        this.context.resourceManager.getStringSync($r('app.string.category_programming').id),
        this.context.resourceManager.getStringSync($r('app.string.category_language').id),
        this.context.resourceManager.getStringSync($r('app.string.category_fitness').id),
        this.context.resourceManager.getStringSync($r('app.string.category_reading').id),
        this.context.resourceManager.getStringSync($r('app.string.category_ai').id)
      ]
    } catch (e) {
      Logger.error(this.tag, 'loadCategories failed: ' + ((e as Error).message))
      this.categories = ['全部', '编程', '语言', '健身', '阅读', 'AI 生成']
    }
  }

  private applySnapshot(snapshot: RouteVMSnapshot): void {
    if (Array.isArray(snapshot.goals)) {
      const rehydratedGoals: GoalCardItem[] = []
      for (let i: number = 0; i < snapshot.goals.length; i++) {
        const g: GoalCardItem | null = hydrateGoalCardItem(snapshot.goals[i])
        if (g) {
          rehydratedGoals.push(g)
        } else {
          Logger.warn(this.tag, 'applySnapshot: skip invalid goal at index=' + i.toString())
        }
      }
      this.goals.splice(0, this.goals.length)
      for (let i: number = 0; i < rehydratedGoals.length; i++) {
        this.goals.push(rehydratedGoals[i])
      }
    }
    if (typeof snapshot.filterCategory === 'string') {
      this.filterCategory = snapshot.filterCategory
    }
  }

  /**
   * VM 快照 version 读取迁移：若 version 缺失或低于当前版本，执行迁移逻辑
   * 当前版本为1，迁移逻辑为空壳，预留扩展点
   */
  private migrateIfNeeded(savedVersion: number | undefined): void {
    const version: number = savedVersion ?? 0
    if (version < RoutePageViewModel.CURRENT_VERSION) {
      // 未来版本升级在此添加迁移逻辑
      Logger.info(this.tag, 'migrating from version ' + version.toString() +
        ' to ' + RoutePageViewModel.CURRENT_VERSION.toString())
    }
  }

  private buildEmptySnapshot(): RouteVMSnapshot {
    return { goals: [], filterCategory: '', version: RoutePageViewModel.CURRENT_VERSION }
  }

  /** 防抖持久化（委托 PersistHelper） */
  private scheduleSave(): void {
    if (this.context === null) return
    this.persistHelper.scheduleSave()
  }

  /**
   * 实际持久化逻辑（由 PersistHelper.persistFn 调用）
   */
  private async persistData(): Promise<void> {
    if (this.context === null) return
    const ctx: Context = this.context
    const jsonGoals: GoalCardItemJSON[] = []
    for (let i: number = 0; i < this.goals.length; i++) {
      const json: GoalCardItemJSON | null = snapshotGoalCardItem(this.goals[i])
      if (json) {
        jsonGoals.push(json)
      }
    }
    const snapshot: RouteVMSnapshot = {
      goals: jsonGoals,
      filterCategory: this.filterCategory,
      version: RoutePageViewModel.CURRENT_VERSION
    }
    try {
      await StorageManager.saveData(ctx, CommonConstants.STORAGE_KEY_ROUTE_GOALS, snapshot)
    } catch (e) {
      Logger.error(this.tag, 'persistNow failed, msg=' + ((e as Error).message))
    }
  }

  /** 页面退出时强制刷盘（委托 PersistHelper） */
  async flush(): Promise<void> {
    await this.persistHelper.flush()
  }

  buildSnapshot(): RouteVMSnapshot {
    const jsonGoals: GoalCardItemJSON[] = []
    for (let i: number = 0; i < this.goals.length; i++) {
      const json: GoalCardItemJSON | null = snapshotGoalCardItem(this.goals[i])
      if (json) {
        jsonGoals.push(json)
      }
    }
    return {
      goals: jsonGoals,
      filterCategory: this.filterCategory,
      version: RoutePageViewModel.CURRENT_VERSION
    }
  }

  applyCloudSnapshot(cloudData: Record<string, Object>): void {
    const goalsRaw: Object | undefined = cloudData['goals']
    if (Array.isArray(goalsRaw)) {
      // 临时数组完成全部 hydrate（不触碰 this.goals，不触发 @Trace）
      const rehydratedGoals: GoalCardItem[] = []
      const items: Object[] = goalsRaw as Object[]
      for (let i: number = 0; i < items.length; i++) {
        const rawGoal: GoalCardItemJSON = items[i] as GoalCardItemJSON
        const g: GoalCardItem | null = hydrateGoalCardItem(rawGoal)
        if (g) {
          rehydratedGoals.push(g)
        } else {
          // hydrate 失败打 warn，打印索引与 id，便于排查"3→2"丢数据根因
          Logger.warn(this.tag, 'applyCloudSnapshot: skip invalid goal at index ' + i.toString() +
            ', id=' + (rawGoal.id ?? 'null') + ', name=' + (rawGoal.name ?? 'null'))
        }
      }
      // 原子化全量覆盖 —— splice 一次完成"清空 + 插入"，只触发 1 次 @Trace
      this.goals.splice(0, this.goals.length, ...rehydratedGoals)
    }
    const filter: Object | undefined = cloudData['filterCategory']
    if (typeof filter === 'string') {
      this.filterCategory = filter as string
    }
    this.scheduleSave()
    Logger.info(this.tag, 'applyCloudSnapshot done, goals=' + this.goals.length.toString())
  }

  /**
   * 直接修改 MilestoneNode 的 @Trace 属性
   * 无需整体替换 goals 数组，@Trace 自动追踪变更触发局部刷新
   */
  updateMilestone(goalId: Id, milestoneId: Id, isCompleted: boolean): boolean {
    if (!goalId || !milestoneId) return false
    const goal: GoalCardItem | null = this.findGoal(goalId)
    if (!goal) return false
    const milestone: MilestoneNode | null = this.findMilestoneInGoal(goal, milestoneId)
    if (!milestone) return false

    milestone.isCompleted = isCompleted
    milestone.completedTime = isCompleted ? Date.now() : 0

    let completedCount: number = 0
    for (let i: number = 0; i < goal.milestones.length; i++) {
      if (goal.milestones[i].isCompleted) completedCount++
    }
    goal.completedMilestones = completedCount
    goal.progress = goal.totalMilestones > 0 ?
      Math.round((completedCount / goal.totalMilestones) * 100) : 0

    this.scheduleSave()
    // 目标截止提醒：progress 达 100 时取消提醒（目标已完成）
    if (goal.progress >= 100) {
      deadlineReminderService.cancelGoalDeadlineReminder(goal.id)
    }
    return true
  }

  /**
   * 4 级架构联动核心：基于 L2 任务状态重新计算 L1 目标 progress
   *
   * 计算规则（按优先级降序取值，保证 progress 单调体现完成度）：
   *   1. 若 L1 无 L2 任务 → 保持原 progress（基于 milestones 维护）
   *   2. 若所有 L2 任务均为 COMPLETED → progress = 100
   *   3. 否则 → progress = (COMPLETED L2 任务数 / L2 任务总数) * 100
   *
   * 调用时机（数据联动链路补全）：
   *   - syncStepFromTodoCompletion: L4 勾选 → L2 status 变化 → L1 progress 重算
   *   - updateStep: L3 步骤勾选 → L2 status 变化 → L1 progress 重算
   *
   * 设计权衡：
   *   - 仅在 L2 status 真正变化时重算，避免无谓 @Trace 写入
   *   - 不覆盖 milestones 主导的 progress（无 L2 任务时退回 milestones 逻辑）
   *
   * @param goalId - L1 目标 ID
   */
  private updateGoalProgressByTasks(goalId: Id): void {
    if (!goalId) return
    const goal: GoalCardItem | null = this.findGoal(goalId)
    if (!goal) return
    if (!Array.isArray(goal.tasks) || goal.tasks.length === 0) return

    let completedTaskCount: number = 0
    for (let i: number = 0; i < goal.tasks.length; i++) {
      if (goal.tasks[i].status === TaskStatus.COMPLETED) {
        completedTaskCount++
      }
    }

    const newProgress: number = Math.round((completedTaskCount / goal.tasks.length) * 100)
    if (goal.progress !== newProgress) {
      goal.progress = newProgress
      this.scheduleSave()
      Logger.info(this.tag, 'updateGoalProgressByTasks: goalId=' + goalId +
        ', completedTasks=' + completedTaskCount.toString() +
        '/total=' + goal.tasks.length.toString() +
        ', newProgress=' + newProgress.toString())
      // 目标截止提醒：progress 达 100 时取消提醒（目标已完成）
      if (newProgress >= 100) {
        deadlineReminderService.cancelGoalDeadlineReminder(goalId)
      }
    }
  }

  deleteGoal(goalId: Id): boolean {
    if (!goalId) return false
    const goalIndex: number = this.findGoalIndex(goalId)
    if (goalIndex < 0) return false
    const oldGoal: GoalCardItem = this.goals[goalIndex]
    this.goals.splice(goalIndex, 1)
    this.scheduleSave()
    // 解耦：通过事件总线通知 HomeViewModel 删除关联任务
    const goalRemovedPayload: GoalRemovedPayload = buildGoalRemovedPayload(goalId)
    eventBus.emit(EventType.GOAL_REMOVED, goalRemovedPayload as Object)
    // 目标截止提醒：删除目标时取消提醒
    deadlineReminderService.cancelGoalDeadlineReminder(goalId)
    Logger.info(this.tag, 'deleteGoal: deleted goal=' + oldGoal.name + ', id=' + goalId)
    return true
  }

  /**
   * 清空所有目标数据（用于登出等场景）
   * 由各 VM 自行管理状态变更 + 持久化，不跨 VM 直接修改
   */
  clearAll(): void {
    this.goals.splice(0, this.goals.length)
    this.filterCategory = ''
    this.scheduleSave()
    Logger.info(this.tag, 'clearAll done')
  }

  deleteTask(goalId: Id, taskId: Id): boolean {
    if (!goalId || !taskId) return false
    const goal: GoalCardItem | null = this.findGoal(goalId)
    if (!goal) return false
    if (!Array.isArray(goal.tasks)) return false
    let found: boolean = false
    const newTasks: AiGeneratedTask[] = []
    for (let i: number = 0; i < goal.tasks.length; i++) {
      if (goal.tasks[i].id !== taskId) {
        newTasks.push(goal.tasks[i])
      } else {
        found = true
      }
    }
    if (!found) return false
    goal.tasks = newTasks
    this.scheduleSave()
    // 解耦：通过事件总线通知 HomeViewModel 删除关联任务
    const taskRemovedPayload: TaskRemovedPayload = buildTaskRemovedPayload(taskId)
    eventBus.emit(EventType.TASK_REMOVED, taskRemovedPayload as Object)
    Logger.info(this.tag, 'deleteTask: deleted task=' + taskId + ' from goal=' + goalId)
    return true
  }

  /**
   * 删除 L2 任务（语义化别名，明确层级）
   * 从 L1 目标的 tasks 数组中移除指定任务
   * 并级联删除首页待办中关联的 L4 任务
   *
   * @param goalId - L1 目标 ID
   * @param taskId - L2 任务 ID
   * @returns true 成功，false 失败
   */
  deleteL2Task(goalId: Id, taskId: Id): boolean {
    return this.deleteTask(goalId, taskId)
  }

  /**
   * 直接修改 GoalCardItem 的 @Trace 属性
   */
  updateGoal(goalId: Id, name: string, description: string, category: string): boolean {
    if (!goalId || !name) return false
    const goal: GoalCardItem | null = this.findGoal(goalId)
    if (!goal) return false
    goal.name = name.trim()
    goal.description = description.trim()
    goal.category = category.trim()
    this.scheduleSave()
    // 解耦：通过事件总线通知 HomeViewModel 更新关联目标名
    const goalRenamedPayload: GoalRenamedPayload = { goalId: goalId, newName: name.trim() }
    eventBus.emit(EventType.GOAL_RENAMED, goalRenamedPayload as Object)
    Logger.info(this.tag, 'updateGoal: updated goal=' + goalId + ', newName=' + name)
    return true
  }

  /**
   * 直接修改 AiGeneratedTask 的 @Trace 属性
   */
  updateTask(goalId: Id, taskId: Id, taskName: string, estimatedTime: number): boolean {
    if (!goalId || !taskId || !taskName) return false
    const task: AiGeneratedTask | null = this.findTask(goalId, taskId)
    if (!task) return false
    task.taskName = taskName.trim()
    task.estimatedTime = Math.max(1, Math.floor(estimatedTime))
    this.scheduleSave()
    // 解耦：通过事件总线通知 HomeViewModel 更新关联任务信息
    const taskInfoPayload: TaskInfoUpdatedPayload = {
      taskId: taskId,
      newTitle: taskName.trim(),
      newEstimatedTime: estimatedTime
    }
    eventBus.emit(EventType.TASK_INFO_UPDATED, taskInfoPayload as Object)
    Logger.info(this.tag, 'updateTask: updated task=' + taskId)
    return true
  }

  /**
   * 分类重命名/合并（D2：标签管理 → 目标分类管理）
   * 将 oldCategory 下所有目标的分类批量更新为 newCategory
   * 若 filterCategory 恰好是被修改的分类，筛选同步跟随
   *
   * @param oldCategory - 原分类名（必须与目标上的分类完全一致）
   * @param newCategory - 新分类名（可为已有分类，实现"合并"效果）
   */
  renameCategory(oldCategory: string, newCategory: string): void {
    const target: string = newCategory.trim()
    if (target.length === 0 || oldCategory === target) return
    let changed: number = 0
    for (let i: number = 0; i < this.goals.length; i++) {
      if (this.goals[i].category === oldCategory) {
        this.goals[i].category = target
        changed++
      }
    }
    if (this.filterCategory === oldCategory) {
      this.filterCategory = target
    }
    if (changed > 0) {
      this.scheduleSave()
    }
    Logger.info(this.tag, 'renameCategory: ' + oldCategory + ' -> ' + target +
      ', affected goals=' + changed.toString())
  }

  /**
   * 更新 L2 任务（语义化别名，明确层级）
   * 同步更新 L1 目标的 tasks 数组中对应任务的 taskName 和 estimatedTime
   * 并级联更新首页待办中关联的 L4 任务信息
   *
   * @param goalId - L1 目标 ID
   * @param taskId - L2 任务 ID
   * @param taskName - 新的任务名称
   * @param estimatedTime - 新的预估时间（分钟）
   * @returns true 成功，false 失败
   */
  updateL2Task(goalId: Id, taskId: Id, taskName: string, estimatedTime: number): boolean {
    return this.updateTask(goalId, taskId, taskName, estimatedTime)
  }

  // AI 确认方案落库入口：AIPage.handleConfirmPlan → createGoalFromAi → routeVM.addGoal
  // unshift 插入列表头部（最新目标显示在最前），scheduleSave 触发防抖落盘 + 云同步
  addGoal(goal: GoalCardItem): void {
    if (!goal || !goal.id) {
      Logger.warn(this.tag, 'addGoal: invalid goal')
      return
    }
    for (let i: number = 0; i < this.goals.length; i++) {
      if (this.goals[i].id === goal.id) {
        Logger.warn(this.tag, 'addGoal: duplicate goal id=' + goal.id)
        return
      }
    }
    this.goals.unshift(goal)
    this.scheduleSave()
    // 目标截止提醒：新增目标时调度提醒（deadline <= 0 时 service 内部会自动跳过）
    deadlineReminderService.scheduleGoalDeadlineReminder(goal)
    Logger.info(this.tag, 'addGoal: added goal=' + goal.name + ', tasks=' +
      goal.tasks.length.toString())
  }

  /**
   * 向指定目标追加单个里程碑（手动添加入口）
   * - 找到目标后 push 到 milestones 数组并更新 totalMilestones
   * - 通过 scheduleSave 触发持久化 + 云同步
   * - V2 @Trace 响应式：goal.milestones 是 @Trace，push 可触发刷新
   */
  addMilestoneToGoal(goalId: Id, milestone: MilestoneNode): void {
    if (!goalId || !milestone) {
      Logger.warn(this.tag, 'addMilestoneToGoal: invalid params')
      return
    }
    const goal: GoalCardItem | undefined = this.goals.find((g: GoalCardItem): boolean => g.id === goalId)
    if (goal) {
      goal.milestones.push(milestone)
      goal.totalMilestones = goal.milestones.length
      this.scheduleSave()
      Logger.info(this.tag, 'addMilestoneToGoal: added milestone=' + milestone.title +
        ' to goal=' + goalId)
    } else {
      Logger.warn(this.tag, 'addMilestoneToGoal: goal not found, id=' + goalId)
    }
  }

  /**
   * 向指定目标追加单个任务（手动添加入口）
   * - 找到目标后 push 到 tasks 数组
   * - 通过 scheduleSave 触发持久化 + 云同步
   * - V2 @Trace 响应式：goal.tasks 是 @Trace，push 可触发刷新
   */
  addTaskToGoal(goalId: Id, task: AiGeneratedTask): void {
    if (!goalId || !task) {
      Logger.warn(this.tag, 'addTaskToGoal: invalid params')
      return
    }
    const goal: GoalCardItem | undefined = this.goals.find((g: GoalCardItem): boolean => g.id === goalId)
    if (goal) {
      goal.tasks.push(task)
      this.scheduleSave()
      Logger.info(this.tag, 'addTaskToGoal: added task=' + task.taskName +
        ' to goal=' + goalId)
    } else {
      Logger.warn(this.tag, 'addTaskToGoal: goal not found, id=' + goalId)
    }
  }

  findTask(goalId: Id, taskId: Id): AiGeneratedTask | null {
    if (!goalId || !taskId) return null
    for (let i: number = 0; i < this.goals.length; i++) {
      const g: GoalCardItem = this.goals[i]
      if (g.id !== goalId) continue
      if (!Array.isArray(g.tasks)) return null
      for (let j: number = 0; j < g.tasks.length; j++) {
        if (g.tasks[j].id === taskId) return g.tasks[j]
      }
    }
    return null
  }

  extractToHomeTodo(goalId: Id, taskId: Id): HomeTodoItem | null {
    const task: AiGeneratedTask | null = this.findTask(goalId, taskId)
    if (!task) {
      Logger.warn(this.tag, 'extractToHomeTodo: task not found, goalId=' +
        goalId + ', taskId=' + taskId)
      return null
    }
    let goalName: string = ''
    for (let i: number = 0; i < this.goals.length; i++) {
      if (this.goals[i].id === goalId) {
        goalName = this.goals[i].name
        break
      }
    }
    try {
      // 时间字段透传：L2 任务的 plannedTime / actualCompletionTime / deadline
      //   同步到 L4 待办，保证番茄钟/四象限/截止日期功能在 L4 侧也能直接读取
      //   无需在 L4 重复维护，单一数据源（L2）为准
      const todo: HomeTodoItem = buildHomeTodoItem(
        'todo_ext_' + task.id,
        task.taskName,
        goalName,
        (typeof task.estimatedTime === 'number' && !isNaN(task.estimatedTime)) ?
          Math.max(0, Math.floor(task.estimatedTime)).toString() + ' min' : '',
        task.priority,
        task.status === TaskStatus.COMPLETED,
        Date.now(),
        task.id,
        goalId,
        task.plannedTime,
        task.actualCompletionTime,
        task.deadline
      )
      Logger.info(this.tag, 'extractToHomeTodo: success, taskId=' + task.id +
        ', plannedTime=' + task.plannedTime.toString() +
        ', deadline=' + task.deadline.toString())
      return todo
    } catch (e) {
      const err: Error = e as Error
      Logger.error(this.tag, 'extractToHomeTodo failed, msg=' + err.message)
      return null
    }
  }

  /**
   * 直接修改 AiGeneratedTask.completedSteps @Trace 属性
   * 从 40+ 行"整体替换 goals 数组"缩减到 10 行精确修改
   *
   * 完成时间戳反向链路（L3 → L2 → L4）：
   *   - 当 L3 步骤全部完成 → L2.status = COMPLETED，L2.actualCompletionTime 若为 0 则补 Date.now()
   *   - 当 L3 由全完成变为部分完成 → L2.status = IN_PROGRESS，L2.actualCompletionTime 重置为 0
   *   - L4 侧由 homeVM.syncRelatedTaskCompletion 自动同步 isCompleted + actualCompletionTime
   *     （该方法已增强为携带时间戳不变式，无需在此重复维护 L4）
   *
   * 时间戳优先级说明：
   *   - 若 L2 已有非 0 完成时刻（例如曾被用户经 L4 反向同步过），保留原时刻不被覆盖
   *   - 仅当 L2.actualCompletionTime === 0 时，才用当前时刻补全，保证"首次完成时刻"语义
   */
  updateStep(goalId: Id, taskId: Id, stepIndex: number, isCompleted: boolean): boolean {
    if (!goalId || !taskId) return false
    if (typeof stepIndex !== 'number' || stepIndex < 0) return false
    const task: AiGeneratedTask | null = this.findTask(goalId, taskId)
    if (!task) return false
    const safe: Array<boolean> = getCompletedStepsSafe(task)
    while (safe.length <= stepIndex) {
      safe.push(false)
    }
    safe[stepIndex] = isCompleted === true
    task.completedSteps = safe
    let allCompleted: boolean = safe.length > 0
    for (let i: number = 0; i < safe.length; i++) {
      if (!safe[i]) {
        allCompleted = false
        break
      }
    }
    task.status = allCompleted ? TaskStatus.COMPLETED : TaskStatus.IN_PROGRESS
    // 补全 L2 实际完成时间戳（与 status 语义保持一致）
    if (allCompleted) {
      // 全部完成：仅在尚未记录完成时间时补全，避免覆盖历史时刻
      if (task.actualCompletionTime === 0) {
        task.actualCompletionTime = Date.now()
      }
    } else {
      // 取消全完成：重置为 0，与 status=IN_PROGRESS 语义一致
      task.actualCompletionTime = 0
    }
    // L2 → L4 反向同步：通过事件总线通知 HomeViewModel 同步任务完成状态
    //   HomeVM.syncRelatedTaskCompletion 已增强为
    //   同步 isCompleted + actualCompletionTime，无需在此重复维护 L4 时间戳
    const completionPayload: TaskCompletionSyncedPayload = {
      taskId: task.id,
      completed: allCompleted
    }
    eventBus.emit(EventType.TASK_COMPLETION_SYNCED, completionPayload as Object)
    // 4 级架构联动：L2 status 变化后重算 L1 goal progress
    this.updateGoalProgressByTasks(goalId)
    this.scheduleSave()
    Logger.info(this.tag, 'updateStep: success, goalId=' + goalId + ', taskId=' + taskId +
      ', stepIndex=' + stepIndex.toString() + ', isCompleted=' + isCompleted.toString() +
      ', allCompleted=' + allCompleted.toString() +
      ', L2.actualCompletionTime=' + task.actualCompletionTime.toString())
    return true
  }

  getStepStatus(goalId: Id, taskId: Id, stepIndex: number): boolean {
    const task: AiGeneratedTask | null = this.findTask(goalId, taskId)
    if (!task) return false
    return isStepCompleted(task, stepIndex)
  }

  /**
   * 直接修改 AiGeneratedTask 的 @Trace 属性
   */
  addStep(goalId: Id, taskId: Id, stepText: string): boolean {
    if (!goalId || !taskId) return false
    if (typeof stepText !== 'string' || stepText.trim().length === 0) return false
    const task: AiGeneratedTask | null = this.findTask(goalId, taskId)
    if (!task) return false
    const newSteps: Array<string> = []
    if (Array.isArray(task.steps)) {
      for (let i: number = 0; i < task.steps.length; i++) {
        newSteps.push(task.steps[i])
      }
    }
    newSteps.push(stepText.trim())
    const newCompleted: Array<boolean> = []
    if (Array.isArray(task.completedSteps)) {
      for (let i: number = 0; i < task.completedSteps.length; i++) {
        newCompleted.push(task.completedSteps[i])
      }
    }
    newCompleted.push(false)
    task.steps = newSteps
    task.completedSteps = newCompleted
    this.scheduleSave()
    Logger.info(this.tag, 'addStep: success, goalId=' + goalId + ', taskId=' + taskId +
      ', stepText=' + stepText + ', newStepCount=' + newSteps.length.toString())
    return true
  }

  /**
   * 直接修改 AiGeneratedTask 的 @Trace 属性
   */
  removeStep(goalId: Id, taskId: Id, stepIndex: number): boolean {
    if (!goalId || !taskId) return false
    if (typeof stepIndex !== 'number' || stepIndex < 0) return false
    const task: AiGeneratedTask | null = this.findTask(goalId, taskId)
    if (!task) return false
    const oldSteps: Array<string> = Array.isArray(task.steps) ? task.steps : []
    if (oldSteps.length <= 1) {
      Logger.warn(this.tag, 'removeStep: cannot remove last step, goalId=' + goalId + ', taskId=' + taskId)
      return false
    }
    if (stepIndex >= oldSteps.length) return false
    const newSteps: Array<string> = oldSteps.filter((_: string, idx: number): boolean => idx !== stepIndex)
    const oldCompleted: Array<boolean> = Array.isArray(task.completedSteps) ? task.completedSteps : []
    const newCompleted: Array<boolean> = oldCompleted.filter((_: boolean, idx: number): boolean => idx !== stepIndex)
    task.steps = newSteps
    task.completedSteps = newCompleted
    this.scheduleSave()
    Logger.info(this.tag, 'removeStep: success, goalId=' + goalId + ', taskId=' + taskId +
      ', stepIndex=' + stepIndex.toString() + ', remainingSteps=' + newSteps.length.toString())
    return true
  }

  /**
   * 直接修改 AiGeneratedTask 的 @Trace 属性
   */
  updateStepText(goalId: Id, taskId: Id, stepIndex: number, newText: string): boolean {
    if (!goalId || !taskId) return false
    if (typeof stepIndex !== 'number' || stepIndex < 0) return false
    if (typeof newText !== 'string' || newText.trim().length === 0) return false
    const task: AiGeneratedTask | null = this.findTask(goalId, taskId)
    if (!task) return false
    const oldSteps: Array<string> = Array.isArray(task.steps) ? task.steps : []
    if (stepIndex >= oldSteps.length) return false
    const newSteps: Array<string> = []
    for (let i: number = 0; i < oldSteps.length; i++) {
      newSteps.push(oldSteps[i])
    }
    newSteps[stepIndex] = newText.trim()
    task.steps = newSteps
    this.scheduleSave()
    Logger.info(this.tag, 'updateStepText: success, goalId=' + goalId + ', taskId=' + taskId +
      ', stepIndex=' + stepIndex.toString())
    return true
  }

  /**
   * 直接修改 AiGeneratedTask 的 @Trace 属性
   */
  reorderSteps(goalId: Id, taskId: Id, fromIndex: number, toIndex: number): boolean {
    if (!goalId || !taskId) return false
    if (typeof fromIndex !== 'number' || fromIndex < 0) return false
    if (typeof toIndex !== 'number' || toIndex < 0) return false
    if (fromIndex === toIndex) return false
    const task: AiGeneratedTask | null = this.findTask(goalId, taskId)
    if (!task) return false
    const oldSteps: Array<string> = Array.isArray(task.steps) ? task.steps : []
    if (fromIndex >= oldSteps.length || toIndex >= oldSteps.length) return false
    const newSteps: Array<string> = []
    for (let i: number = 0; i < oldSteps.length; i++) {
      newSteps.push(oldSteps[i])
    }
    const removed: string = newSteps.splice(fromIndex, 1)[0]
    newSteps.splice(toIndex, 0, removed)
    const oldCompleted: Array<boolean> = Array.isArray(task.completedSteps) ? task.completedSteps : []
    const newCompleted: Array<boolean> = []
    for (let i: number = 0; i < oldCompleted.length; i++) {
      newCompleted.push(oldCompleted[i])
    }
    while (newCompleted.length < newSteps.length) {
      newCompleted.push(false) // 新增步骤默认未完成
    }
    if (newCompleted.length > newSteps.length) {
      newCompleted.splice(newSteps.length) // 截断多余
    }
    // 无条件重排 completedSteps
    const completedRemoved: boolean = newCompleted.splice(fromIndex, 1)[0]
    newCompleted.splice(toIndex, 0, completedRemoved)
    task.steps = newSteps
    task.completedSteps = newCompleted
    this.scheduleSave()
    Logger.info(this.tag, 'reorderSteps: success, goalId=' + goalId + ', taskId=' + taskId +
      ', from=' + fromIndex.toString() + ', to=' + toIndex.toString())
    return true
  }

  private findGoal(goalId: Id): GoalCardItem | null {
    for (let i: number = 0; i < this.goals.length; i++) {
      if (this.goals[i].id === goalId) return this.goals[i]
    }
    return null
  }

  /**
   * 从首页待办同步步骤完成状态：当首页勾选/取消待办时，回写 routeVM 中 L2 任务的 status
   *
   * 时间戳同步规则（与 HomeViewModel.toggleTask 建立的不变式保持一致）：
   *   - L4 标记完成 → L2.status = COMPLETED，L2.actualCompletionTime 若为 0 则补 Date.now()
   *     （不覆盖历史非 0 时刻，避免重复勾选时漂移）
   *   - L4 取消完成 → L2.status = PENDING，L2.actualCompletionTime 重置为 0
   *
   * 数据一致性意义：
   *   - L2 与 L4 的 actualCompletionTime 保持语义同步，统计/历史分析任取一侧皆可
   *   - 消除"L4 已完成但 L2 仍无完成时刻"的数据缺口
   *
   * @param goalId - L1 目标 ID
   * @param taskId - L2 任务 ID
   * @param completed - 完成状态
   */
  syncStepFromTodoCompletion(goalId: string, taskId: string, completed: boolean): void {
    if (!goalId || !taskId) return
    const goal: GoalCardItem | null = this.findGoal(goalId)
    if (!goal) return
    if (!Array.isArray(goal.tasks)) return
    const task: AiGeneratedTask | undefined = goal.tasks.find((t: AiGeneratedTask): boolean => t.id === taskId)
    if (!task) return

    // 4 级架构正向联动核心：L4 勾选完成 → L3 步骤全部标记完成
    // 同步 L3 completedSteps 数组（与 L2 status 保持语义一致）
    if (Array.isArray(task.steps) && task.steps.length > 0) {
      const safe: Array<boolean> = getCompletedStepsSafe(task)
      for (let i: number = 0; i < safe.length; i++) {
        safe[i] = completed === true
      }
      task.completedSteps = safe
    }

    task.status = completed ? TaskStatus.COMPLETED : TaskStatus.PENDING
    // 同步回写 L2 实际完成时间戳（与 isCompleted 语义保持一致）
    if (completed) {
      // 标记完成：仅在尚未记录完成时间时补全，避免覆盖历史时刻
      if (task.actualCompletionTime === 0) {
        task.actualCompletionTime = Date.now()
      }
    } else {
      // 取消完成：重置为 0，与 status=PENDING 语义一致
      task.actualCompletionTime = 0
    }

    // 4 级架构联动：L2 status 变化后重算 L1 goal progress
    this.updateGoalProgressByTasks(goalId)

    this.scheduleSave()
    Logger.info(this.tag, 'syncStepFromTodoCompletion: goalId=' + goalId +
      ', taskId=' + taskId + ', completed=' + completed.toString() +
      ', actualCompletionTime=' + task.actualCompletionTime.toString())
  }

  private findGoalIndex(goalId: Id): number {
    for (let i: number = 0; i < this.goals.length; i++) {
      if (this.goals[i].id === goalId) return i
    }
    return -1
  }

  private findMilestoneInGoal(goal: GoalCardItem, milestoneId: Id): MilestoneNode | null {
    if (!Array.isArray(goal.milestones)) return null
    for (let i: number = 0; i < goal.milestones.length; i++) {
      if (goal.milestones[i].id === milestoneId) return goal.milestones[i]
    }
    return null
  }
}

export const routeVM: RoutePageViewModel = new RoutePageViewModel()
