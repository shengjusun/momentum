// 路线页 ViewModel：目标/任务/里程碑的增删改查 + 本地持久化 + 云端快照

import {
  GoalCardItem, GoalCardItemJSON, MilestoneNode, Id, Timestamp, AiGeneratedTask,
  HomeTodoItem, TaskStatus, TaskPriority, TaskStep, generateStepId,
  buildGoalCardItem, buildHomeTodoItem,
  isStepCompleted,
  hydrateGoalCardItem, snapshotGoalCardItem
} from '../model/Models'
import { Logger } from '../common/utils/Logger'
import { StorageManager } from '../common/utils/StorageManager'
import { CommonConstants } from '../common/constants/CommonConstants'
import { PersistHelper } from '../common/utils/PersistHelper'
import { formatEstimatedDuration } from '../common/utils/SafeUtils'
import { deadlineReminderService } from '../common/services/DeadlineReminderService'
import { hapticFeedback } from '../common/services/HapticFeedback'
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
  buildTaskRemovedPayload,
  buildGoalCompletedPayload,
  buildGoalProgressChangedPayload
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
  /** “全部”筛选标签的本地化文本（用于判定 filterCategory，避免硬编码中文比较） */
  private categoryAllLabel: string = ''

  /**
   * 对外统一视图：**过滤掉墓碑目标**（isDeleted === true）
   *
   * 数据分层规范（云同步重构）：
   *   - 底层 `goals`：原始完整数据集，**含墓碑条目**，仅用于「同步合并 / 本地持久化」
   *   - 对外 `liveGoals`：UI 页面 / 统计计数 / 提醒服务 / 导出备份统一读取此视图
   * ⚠️ 禁止在 UI、统计、提醒、导出中直接遍历底层 goals
   */
  @Computed
  get liveGoals(): GoalCardItem[] {
    const alive: GoalCardItem[] = []
    for (let i: number = 0; i < this.goals.length; i++) {
      const goal: GoalCardItem = this.goals[i]
      if (goal.isDeleted !== true) {
        alive.push(goal)
      }
    }
    return alive
  }

  /**
   * 同步落地抑制标志：`applyCloudSnapshot` 执行期间为 true
   * - 抑制 onScheduleFire 发出 SYNC_NEEDED：否则「merge → 落地 → 触发同步 → merge」死循环
   * - 不影响本地持久化（落地数据必须落盘）
   */
  private isApplyingCloudSnapshot: boolean = false

  private context: Context | null = null
  /**
   * 防抖持久化：200ms 内多次修改合并为一次写入
   *
   * 云同步重构（2026-09-15）：**本 VM 补上 onScheduleFire**
   *   原设计"云同步由 HomeVM 的 onScheduleFire 统一触发"存在缺口：
   *   只修改目标 / 里程碑 / L2 任务 / L3 步骤时 HomeVM 并未被修改，
   *   不会发出 SYNC_NEEDED → 这些改动仅落本地、迟迟不上传（要等下次冷启动 merge 才补）。
   */
  private persistHelper: PersistHelper = new PersistHelper(
    'RoutePageViewModel',
    async (): Promise<void> => { await this.persistData() },
    200,
    (): void => {
      // 同步落地触发的持久化：只落盘，不打脏标记、不触发云同步（防回环，消费一次后复位）
      if (this.isApplyingCloudSnapshot) {
        this.isApplyingCloudSnapshot = false
        Logger.info(this.tag, 'onScheduleFire skipped: applying cloud snapshot, break sync loop')
        return
      }
      const isLoggedIn: boolean = AppStorage.get<boolean>('isLoggedIn') ?? false
      if (isLoggedIn) {
        eventBus.emit(EventType.SYNC_NEEDED, null)
      }
    }
  )
  private isInitInProgress: boolean = false
  /** 事件总线订阅 ID（用于精确取消订阅） */
  private todoCompletedCbId: number = -1
  private clearAllCbId: number = -1
  private flushCbId: number = -1

  private static readonly CURRENT_VERSION: number = 1

  @Computed
  get activeGoalCount(): number {
    return this.liveGoals.length
  }

  @Computed
  get averageProgress(): number {
    const alive: GoalCardItem[] = this.liveGoals
    if (alive.length === 0) return 0
    let total: number = 0
    for (let i: number = 0; i < alive.length; i++) {
      total += alive[i].progress
    }
    return Math.round(total / alive.length)
  }

  /**
   * 已完成目标数量（@Computed 自动重算）
   * 基于 L1 目标 progress 字段判定：progress === 100 视为已完成
   */
  @Computed
  get completedGoalCount(): number {
    const alive: GoalCardItem[] = this.liveGoals
    let count: number = 0
    for (let i: number = 0; i < alive.length; i++) {
      if (alive[i].progress === 100) {
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
    const alive: GoalCardItem[] = this.liveGoals
    let count: number = 0
    for (let i: number = 0; i < alive.length; i++) {
      const p: number = alive[i].progress
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
    const alive: GoalCardItem[] = this.liveGoals
    let count: number = 0
    for (let i: number = 0; i < alive.length; i++) {
      if (alive[i].progress === 0) {
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
    const alive: GoalCardItem[] = this.liveGoals
    let count: number = 0
    for (let i: number = 0; i < alive.length; i++) {
      const goal: GoalCardItem = alive[i]
      if (goal.deadline > 0 && goal.deadline < now && goal.progress < 100) {
        count++
      }
    }
    return count
  }

  /** 列表展示用（已过滤墓碑 + 分类筛选） */
  @Computed
  get filteredGoals(): GoalCardItem[] {
    const alive: GoalCardItem[] = this.liveGoals
    if (!this.filterCategory || this.filterCategory === '' ||
      (this.categoryAllLabel.length > 0 && this.filterCategory === this.categoryAllLabel)) {
      return alive
    }
    const result: GoalCardItem[] = []
    for (let i: number = 0; i < alive.length; i++) {
      if (alive[i].category === this.filterCategory) {
        result.push(alive[i])
      }
    }
    return result
  }

  constructor() {
  }

  /**
   * 分类筛选（纯本机 UI 视图状态）
   * ⚠️ 只落盘、**不触发云同步**：`filterCategory` 不参与云同步语义
   *    （merge 时统一取云端值，`applyCloudSnapshot` 也不采纳本地该字段），
   *    若走 scheduleSave，每点一次分类都会白跑一轮网络 merge。
   */
  setCategory(category: string): void {
    this.filterCategory = category
    this.scheduleSaveSilent()
  }

  /**
   * 清除分类筛选（回到「全部」）
   * 供路线页「筛选后为空」的空态使用 —— 用户点「查看全部」就是要退出当前筛选。
   */
  clearCategoryFilter(): void {
    if (this.filterCategory === this.categoryAllLabel) return
    this.filterCategory = this.categoryAllLabel
    this.scheduleSaveSilent()
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
      // 提醒只针对存活目标（墓碑不得再排提醒）
      deadlineReminderService.rescheduleAllGoals(this.liveGoals)
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
      this.categoryAllLabel = this.categories[0]
    } catch (e) {
      Logger.error(this.tag, 'loadCategories failed: ' + ((e as Error).message))
      // 资源读取异常的兜底（仅异常路径，正常不会执行）
      this.categories = ['全部', '编程', '语言', '健身', '阅读', 'AI 生成']
      this.categoryAllLabel = this.categories[0]
    }
    this.normalizeFilterCategory()
  }

  /**
   * 归一化筛选分类：把「未选 / 标签已失效」统一落到「全部」
   *
   * 为什么需要：
   *   1. `filterCategory` 的默认值是 `''`，而筛选项选中态的判定是 `filterCategory === cat`
   *      → **空值不命中任何一个 chip（含「全部」）**，表现为"刚进页面所有筛选项都不高亮"；
   *   2. 切换应用语言后，旧语言的分类标签会整体失效，选中态同样会丢。
   *
   * 归一之后，**选中态（UI 直接比较该值）与筛选语义（`filteredGoals` 的"全部"分支）
   * 共用同一个值**，不再各自判断 —— "同一状态被两处各自理解"正是此前番茄钟读数出问题的成因。
   */
  private normalizeFilterCategory(): void {
    if (this.categories.length === 0) return
    if (this.categories.indexOf(this.filterCategory) < 0) {
      this.filterCategory = this.categoryAllLabel
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

  /** 防抖持久化（委托 PersistHelper）—— 会触发云同步（打脏标记 + merge） */
  private scheduleSave(): void {
    if (this.context === null) return
    this.persistHelper.scheduleSave()
  }

  /**
   * 防抖持久化，但**不触发云同步** —— 专用于纯本机视图状态
   * 见 `PersistHelper.scheduleSaveSilent` 的注释
   */
  private scheduleSaveSilent(): void {
    if (this.context === null) return
    this.persistHelper.scheduleSaveSilent()
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

  /**
   * 同步用快照：**包含墓碑目标**（底层原始数据）
   * ⚠️ 仅供云同步的本地快照提供者使用（`MainTab.registerSnapshotProviders`）。
   *    若改用过滤后的视图，删除操作无法上传 → 墓碑传播失效 → 对端删除复活。
   */
  buildSyncSnapshot(): RouteVMSnapshot {
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

  /**
   * 对外快照（导出备份等）：**过滤墓碑目标**
   * ⚠️ 禁止用于云同步（会丢墓碑）
   */
  buildSnapshot(): RouteVMSnapshot {
    const jsonGoals: GoalCardItemJSON[] = []
    const alive: GoalCardItem[] = this.liveGoals
    for (let i: number = 0; i < alive.length; i++) {
      const json: GoalCardItemJSON | null = snapshotGoalCardItem(alive[i])
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

  /**
   * 应用云端合并结果（同步落地）
   *
   * ⚠️ 硬约束（违反会造成反复上传 / 死循环）：
   *   1. **禁止改写条目 updatedAt** —— 这里只做 hydrate（原值保留）；
   *      落地时刷成本机时间会伪造"本机更新"，导致指纹永不相等、反复上传
   *   2. **禁止走 scheduleSave**（防抖 + onScheduleFire 会打脏标记并再次触发 merge）
   *      → 改为直接 `persistData()` 落盘
   *   3. `filterCategory` 是**本机 UI 瞬时状态**：合并不覆盖它，避免两端来回覆盖
   *      （载荷中的兄弟字段以云端为准是为了让指纹收敛，本地视图状态不参与同步语义）
   */
  applyCloudSnapshot(cloudData: Record<string, Object>): void {
    this.isApplyingCloudSnapshot = true
    try {
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

        // ⚠️ 落地前先比 progress：splice 之后旧值即丢失。
        // 为什么必须比（2026-09-17 补）：`filteredGoals`(@Computed) 不依赖单个目标的 progress，
        // 且 RoutePage.goalDataSource 是独立快照、`isGoalDataSourceStale()` 只比「数量 / 首项 id」
        // ⇒ 若合并只改变了进度，路线页既不同步数据源也不重渲染，卡片进度环永远停在旧值。
        let changedGoalId: Id = ''
        let changedProgress: number = 0
        for (let k: number = 0; k < rehydratedGoals.length; k++) {
          const next: GoalCardItem = rehydratedGoals[k]
          const prev: GoalCardItem | null = this.findGoal(next.id)
          if (prev !== null && prev.progress !== next.progress) {
            changedGoalId = next.id
            changedProgress = next.progress
            break
          }
        }

        // 原子化全量覆盖 —— splice 一次完成"清空 + 插入"，只触发 1 次 @Trace
        this.goals.splice(0, this.goals.length, ...rehydratedGoals)

        // 进度变化 → 复用既有广播出口，让路线页强制重同步数据源
        // （RoutePage 的订阅回调只做 forceSyncGoalDataSource，故一次事件足以覆盖全部目标）
        if (changedGoalId.length > 0) {
          this.notifyGoalProgressChanged(changedGoalId, changedProgress)
        }
      }
      // filterCategory 保持本机值（不采纳云端），见方法头注释第 3 条
      this.persistData().catch((e: Error): void => {
        Logger.error(this.tag, 'applyCloudSnapshot persist failed: ' + e.message)
      })
      Logger.info(this.tag, 'applyCloudSnapshot done, goals=' + this.goals.length.toString())
    } finally {
      // 正常情况下不会走 onScheduleFire；此处复位避免标志长期滞留
      this.isApplyingCloudSnapshot = false
    }
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

    // 目标达成检测基线：本函数只在用户动作链被调用（云同步落地直接整体替换 goals，
    // 不经过此处），故"未完成 → 100"的跳变即用户本机达成目标
    const wasGoalCompleted: boolean = goal.progress >= 100

    milestone.isCompleted = isCompleted
    milestone.completedTime = isCompleted ? Date.now() : 0

    let completedCount: number = 0
    for (let i: number = 0; i < goal.milestones.length; i++) {
      if (goal.milestones[i].isCompleted) completedCount++
    }
    goal.completedMilestones = completedCount
    const newProgress: number = goal.totalMilestones > 0 ?
      Math.round((completedCount / goal.totalMilestones) * 100) : 0
    const progressChanged: boolean = goal.progress !== newProgress
    goal.progress = newProgress
    // 里程碑改动会改变目标内容 → 刷新目标条目版本（保证跨设备冲突时本机改动胜出）
    goal.updatedAt = Date.now()

    // 触觉反馈：里程碑完成方向轻点一下（取消完成不震）
    if (isCompleted) {
      hapticFeedback.stepCompleted()
    }

    // 进度变化唯一出口广播：路线页的 goalDataSource 是独立快照，需要显式通知才会重读
    if (progressChanged) {
      this.notifyGoalProgressChanged(goal.id, newProgress)
    }

    this.scheduleSave()
    // 目标截止提醒：progress 达 100 时取消提醒（目标已完成）
    if (goal.progress >= 100) {
      deadlineReminderService.cancelGoalDeadlineReminder(goal.id)
      // 目标达成：庆祝震动 + 广播事件（GoalDetailPage 订阅后播撒花）
      if (!wasGoalCompleted) {
        this.notifyGoalCompleted(goalId)
      }
    }
    return true
  }

  /**
   * 目标达成的统一反馈出口：庆祝震动 + GOAL_COMPLETED 事件广播
   *
   * ⚠️ 调用前提：调用方必须已确认"progress 从 <100 跳到 100"且处于**用户本机动作链**
   * （云同步落地 / 导入恢复直接整体替换 goals，不经过本函数，天然不触发）
   */
  private notifyGoalCompleted(goalId: Id): void {
    hapticFeedback.goalCompleted()
    eventBus.emit(EventType.GOAL_COMPLETED, buildGoalCompletedPayload(goalId))
    Logger.info(this.tag, 'goal completed: goalId=' + goalId)
  }

  /**
   * 进度变化的统一广播出口（唯一）
   *
   * ⚠️ 调用前提：`goal.progress` **已经**被写成新值，且新旧值确实不同。
   *
   * 为什么必须广播：路线页卡片列表走 LazyForEach + `goalDataSource`（filteredGoals 的
   *   **独立快照**），数据源只在收到通知时才重读数据；而触发通知的 `goalCount` 只感知
   *   **数量**变化 ⇒ 纯进度变化不会让路线页重渲染，卡片进度环停在旧值。
   *   本 App 里所有写 `goal.progress` 的地方都收敛在 `updateMilestone` /
   *   `updateGoalProgressByTasks` 两处，各写一次即可覆盖全链路。
   */
  private notifyGoalProgressChanged(goalId: Id, progress: number): void {
    eventBus.emit(EventType.GOAL_PROGRESS_CHANGED,
      buildGoalProgressChangedPayload(goalId, progress) as Object)
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
    if (!Array.isArray(goal.tasks)) return

    // 目标达成检测基线：调用方均为用户本机动作链（勾步骤 / 勾待办联动 / 删任务重算），
    // 云同步落地直接整体替换 goals 不经过此处 ⇒ 跳变即本机达成
    const wasGoalCompleted: boolean = goal.progress >= 100

    // 任务被删空时：无任务可依据，进度归零（否则进度冻结在删除前的旧值）
    if (goal.tasks.length === 0) {
      if (goal.progress !== 0) {
        goal.progress = 0
        goal.actualCompletionTime = 0
        // 目标内容已变（progress 属于目标对象内容）→ 刷新条目版本
        goal.updatedAt = Date.now()
        // 进度变化唯一出口广播（路线页数据源是独立快照，需显式通知）
        this.notifyGoalProgressChanged(goalId, 0)
        this.scheduleSave()
      }
      return
    }

    let completedTaskCount: number = 0
    for (let i: number = 0; i < goal.tasks.length; i++) {
      if (goal.tasks[i].status === TaskStatus.COMPLETED) {
        completedTaskCount++
      }
    }

    const newProgress: number = Math.round((completedTaskCount / goal.tasks.length) * 100)
    if (goal.progress !== newProgress) {
      goal.progress = newProgress
      // 目标完成时间戳：进度达 100 时补全（供统计/复盘使用），回退到 100 以下时重置
      if (newProgress >= 100) {
        if (goal.actualCompletionTime === 0) {
          goal.actualCompletionTime = Date.now()
        }
      } else {
        goal.actualCompletionTime = 0
      }
      // 目标内容已变（派生进度也是目标对象的组成部分）→ 刷新条目版本
      goal.updatedAt = Date.now()
      // 进度变化唯一出口广播（路线页数据源是独立快照，纯进度变化不广播就不会刷新）
      this.notifyGoalProgressChanged(goalId, newProgress)
      this.scheduleSave()
      Logger.info(this.tag, 'updateGoalProgressByTasks: goalId=' + goalId +
        ', completedTasks=' + completedTaskCount.toString() +
        '/total=' + goal.tasks.length.toString() +
        ', newProgress=' + newProgress.toString())
      // 目标截止提醒：progress 达 100 时取消提醒（目标已完成）
      if (newProgress >= 100) {
        deadlineReminderService.cancelGoalDeadlineReminder(goalId)
        // 目标达成：庆祝震动 + 广播事件（GoalDetailPage 订阅后播撒花）
        if (!wasGoalCompleted) {
          this.notifyGoalCompleted(goalId)
        }
      }
    }
  }

  /**
   * 删除目标：**软删除（墓碑）**
   * - 不从底层 goals 移除对象，只置 `isDeleted = true` 并刷新条目 `updatedAt`
   * - 底层保留条目 → 删除状态可随 merge 传播到其他设备，杜绝"删了又复活"
   * - UI 侧读 `liveGoals` / `filteredGoals` 自动隐藏
   */
  deleteGoal(goalId: Id): boolean {
    if (!goalId) return false
    const goal: GoalCardItem | null = this.findGoal(goalId)
    if (!goal) return false
    if (goal.isDeleted === true) return false
    goal.isDeleted = true
    goal.updatedAt = Date.now()
    this.scheduleSave()
    // 解耦：通过事件总线通知 HomeViewModel 级联软删除关联待办
    const goalRemovedPayload: GoalRemovedPayload = buildGoalRemovedPayload(goalId)
    eventBus.emit(EventType.GOAL_REMOVED, goalRemovedPayload as Object)
    // 目标截止提醒：删除目标时取消提醒
    deadlineReminderService.cancelGoalDeadlineReminder(goalId)
    Logger.info(this.tag, 'deleteGoal: tombstoned goal=' + goal.name + ', id=' + goalId)
    return true
  }

  /**
   * 清空所有目标数据（用于登出等场景）
   * 由各 VM 自行管理状态变更 + 持久化，不跨 VM 直接修改
   */
  clearAll(): void {
    this.goals.splice(0, this.goals.length)
    // 复位到「全部」而不是空串：空串在 UI 的 `filterCategory === cat` 判定下不命中任何 chip，
    // 会留下"筛选项全部未选中"的观感（详见 normalizeFilterCategory 的注释）
    this.filterCategory = this.categoryAllLabel
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
    // L2 任务属于目标对象的组成部分（整块随目标走，不做条目级墓碑）→ 刷新目标版本
    goal.updatedAt = Date.now()
    // 删除任务后重算目标进度（含任务删空归零、完成时间戳维护）
    this.updateGoalProgressByTasks(goalId)
    this.scheduleSave()
    // 解耦：通过事件总线通知 HomeViewModel 级联软删除关联待办
    const taskRemovedPayload: TaskRemovedPayload = buildTaskRemovedPayload(taskId)
    eventBus.emit(EventType.TASK_REMOVED, taskRemovedPayload as Object)
    Logger.info(this.tag, 'deleteTask: removed task=' + taskId + ' from goal=' + goalId)
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
  updateGoal(goalId: Id, name: string, description: string, category: string,
    newDeadline?: number): boolean {
    if (!goalId || !name) return false
    const goal: GoalCardItem | null = this.findGoal(goalId)
    if (!goal) return false
    goal.name = name.trim()
    goal.description = description.trim()
    goal.category = category.trim()
    // 截止时间变更（可选参数，缺省不变更）：更新后联动重排目标级截止提醒
    let deadlineChanged: boolean = false
    if (newDeadline !== undefined && newDeadline >= 0 && goal.deadline !== newDeadline) {
      goal.deadline = newDeadline
      deadlineChanged = true
      deadlineReminderService.cancelGoalDeadlineReminder(goalId)
      if (newDeadline > Date.now() && goal.progress < 100 && goal.actualCompletionTime === 0) {
        deadlineReminderService.scheduleGoalDeadlineReminder(goal)
      }
    }
    // 目标内容已变 → 刷新条目版本
    goal.updatedAt = Date.now()
    this.scheduleSave()
    // 解耦：通过事件总线通知 HomeViewModel 更新关联目标名
    const goalRenamedPayload: GoalRenamedPayload = { goalId: goalId, newName: name.trim() }
    eventBus.emit(EventType.GOAL_RENAMED, goalRenamedPayload as Object)
    Logger.info(this.tag, 'updateGoal: updated goal=' + goalId +
      ', newName=' + name + ', deadlineChanged=' + deadlineChanged.toString())
    return true
  }

  /**
   * 直接修改 AiGeneratedTask 的 @Trace 属性
   */
  updateTask(goalId: Id, taskId: Id, taskName: string, estimatedTime: number,
    newPriority?: TaskPriority, newDeadline?: number): boolean {
    if (!goalId || !taskId || !taskName) return false
    const task: AiGeneratedTask | null = this.findTask(goalId, taskId)
    if (!task) return false
    const ownerGoal: GoalCardItem | null = this.findGoal(goalId)
    task.taskName = taskName.trim()
    task.estimatedTime = Math.max(1, Math.floor(estimatedTime))
    // 优先级/截止时间变更（可选参数，缺省不变更）
    if (newPriority !== undefined) {
      task.priority = newPriority
    }
    if (newDeadline !== undefined && newDeadline >= 0) {
      task.deadline = newDeadline
    }
    // L2 任务属于目标内容 → 刷新目标条目版本
    if (ownerGoal !== null) {
      ownerGoal.updatedAt = Date.now()
    }
    this.scheduleSave()
    // 解耦：通过事件总线通知 HomeViewModel 更新关联任务信息（含优先级/截止时间联动）
    const taskInfoPayload: TaskInfoUpdatedPayload = {
      taskId: taskId,
      newTitle: taskName.trim(),
      newEstimatedTime: estimatedTime,
      newPriority: newPriority,
      newDeadline: newDeadline
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
    const stamp: number = Date.now()
    // 只改存活目标（墓碑条目内容不应再变化）
    const alive: GoalCardItem[] = this.liveGoals
    for (let i: number = 0; i < alive.length; i++) {
      const goal: GoalCardItem = alive[i]
      if (goal.category === oldCategory) {
        goal.category = target
        goal.updatedAt = stamp
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
    // 新建目标必须有版本时间戳（冲突裁决依据；缺失时补当前时间）
    if (!(goal.updatedAt > 0)) {
      goal.updatedAt = Date.now()
    }
    goal.isDeleted = false
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
      // 里程碑属于目标内容 → 刷新目标条目版本
      goal.updatedAt = Date.now()
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
      // L2 任务属于目标内容 → 刷新目标条目版本
      goal.updatedAt = Date.now()
      this.scheduleSave()
      Logger.info(this.tag, 'addTaskToGoal: added task=' + task.taskName +
        ' to goal=' + goalId)
    } else {
      Logger.warn(this.tag, 'addTaskToGoal: goal not found, id=' + goalId)
    }
  }

  /**
   * 刷新目标条目版本时间戳（conflict 裁决依据）
   *
   * ⚠️ **任何会让目标内容发生变化的写操作都必须调用**：
   *    目标自身字段、里程碑数组、L2 任务数组、L3 步骤数组、派生进度。
   *    漏调用 = 该改动在与云端冲突时静默输给对方的旧版本。
   * ⚠️ **同步落地（applyCloudSnapshot）禁止调用**（会伪造"本机更新"导致反复上传）。
   */
  private touchGoal(goalId: Id): void {
    const goal: GoalCardItem | null = this.findGoal(goalId)
    if (goal !== null) {
      goal.updatedAt = Date.now()
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
          formatEstimatedDuration(Math.max(0, Math.floor(task.estimatedTime)), this.context !== null ? this.context.resourceManager : null) : '',
        task.priority,
        task.status === TaskStatus.COMPLETED,
        Date.now(),
        task.id,
        goalId,
        task.plannedTime,
        task.actualCompletionTime,
        task.deadline,
        false,
        0,
        // 摘取一个「已完成」的 L2 任务 = L4 侧首次声明完成 ⇒ 带上 L2 的完成态轴，
        // 否则 L4 侧该轴为 0（"从未变更过完成态"），跨设备裁决时会被对端的无关编辑压掉
        task.status === TaskStatus.COMPLETED ? task.completionUpdatedAt : 0
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
   * 直接修改 `AiGeneratedTask.steps[i].isCompleted` @Trace 属性
   * L3 步骤对象化后改单个元素即可精确追踪（原先需整体替换 completedSteps 平行数组）
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
    const steps: TaskStep[] = Array.isArray(task.steps) ? task.steps : []
    if (stepIndex >= steps.length) return false
    // 对象化后：改单个元素的 @Trace isCompleted 即被精确追踪，
    // 不再需要「整体替换平行布尔数组」那套绕行写法。
    // 触觉反馈：仅"未完成 → 完成"的跳变轻点一下（取消完成 / 联动写入不经过本函数）
    const wasStepCompleted: boolean = steps[stepIndex].isCompleted === true
    steps[stepIndex].isCompleted = isCompleted === true
    task.steps = steps
    if (isCompleted === true && !wasStepCompleted) {
      hapticFeedback.stepCompleted()
    }
    let allCompleted: boolean = steps.length > 0
    for (let i: number = 0; i < steps.length; i++) {
      if (steps[i].isCompleted !== true) {
        allCompleted = false
        break
      }
    }
    const wasTaskCompleted: boolean = task.status === TaskStatus.COMPLETED
    task.status = allCompleted ? TaskStatus.COMPLETED : TaskStatus.IN_PROGRESS
    // 完成态时间轴打点（云同步裁决「完成 vs 取消完成」的依据）
    // ⚠️ 必须**仅在完成态真的变化**时打：无条件打点会让每次勾步骤都改变载荷指纹 → 白跑一轮上传
    if (wasTaskCompleted !== allCompleted) {
      task.completionUpdatedAt = Date.now()
    }
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
    // L3 步骤属于目标内容 → 刷新目标条目版本
    this.touchGoal(goalId)
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
   * 一次性**设定** L2 任务的完成态，并连带同步其全部 L3 步骤
   *
   * 语义（统一「底部标记完成」与「逐个勾步骤」两个入口，2026-09-17）：
   *   - completed = true  → 全部 L3 步骤置完成 + L2.status = COMPLETED + 补 actualCompletionTime
   *   - completed = false → 全部 L3 步骤置未完成 + L2.status = PENDING + actualCompletionTime 归零
   *
   * 为什么不复用「写 L2.status + homeVM.toggleTask 翻转 L4 + 靠 TODO_COMPLETED 事件兜回 L3」：
   *   1. 事件兜底要求 L4 待办存在且 relatedTaskId 对得上；从目标详情「断链兜底」进来的任务
   *      没有 L4，`homeVM.toggleTask` 直接 return ⇒ 事件不发 ⇒ 步骤原样不动（"点了完成但步骤没动"）；
   *   2. `homeVM.toggleTask` 是**翻转**语义而非**设定**语义，L4 与本地展示状态一旦不同步就反向错；
   *   3. 直接写 L2.status 会绕过 `updateStep` 建立的 actualCompletionTime 不变式。
   *   本方法只做「设定」，L4 侧由 TASK_COMPLETION_SYNCED 事件**按值**同步（幂等、非翻转）。
   *
   * @param goalId - L1 目标 ID
   * @param taskId - L2 任务 ID
   * @param completed - 目标完成态
   * @returns true 成功；任务不存在或参数非法返回 false
   */
  setTaskCompletion(goalId: Id, taskId: Id, completed: boolean): boolean {
    if (!goalId || !taskId) return false
    const task: AiGeneratedTask | null = this.findTask(goalId, taskId)
    if (!task) return false

    const goalBefore: GoalCardItem | null = this.findGoal(goalId)
    const progressBefore: number = goalBefore !== null ? goalBefore.progress : 0

    // 1) L3：把「用户语义上的完成」落到每一个步骤上（对象化后逐个改 @Trace 即可精确刷新）
    const steps: TaskStep[] = Array.isArray(task.steps) ? task.steps : []
    let stepChanged: boolean = false
    for (let i: number = 0; i < steps.length; i++) {
      if (steps[i].isCompleted !== completed) {
        steps[i].isCompleted = completed
        stepChanged = true
      }
    }
    if (stepChanged) {
      task.steps = steps
    }

    // 2) L2：状态 + 实际完成时间戳（与 updateStep 共用同一套不变式）
    //    完成态时间轴打点：仅当完成态真的变化时打（云同步裁决「完成 vs 取消完成」的依据）
    const wasTaskCompleted: boolean = task.status === TaskStatus.COMPLETED
    task.status = completed ? TaskStatus.COMPLETED : TaskStatus.PENDING
    if (wasTaskCompleted !== completed) {
      task.completionUpdatedAt = Date.now()
    }
    if (completed) {
      // 仅在尚未记录完成时间时补全，避免覆盖历史时刻
      if (task.actualCompletionTime === 0) {
        task.actualCompletionTime = Date.now()
      }
    } else {
      task.actualCompletionTime = 0
    }

    // 3) L2 → L4 按值同步（HomeVM.syncRelatedTaskCompletion 是设定语义，重复调用安全）
    const completionPayload: TaskCompletionSyncedPayload = {
      taskId: task.id,
      completed: completed
    }
    eventBus.emit(EventType.TASK_COMPLETION_SYNCED, completionPayload as Object)

    // 4) L2 status → L1 progress 重算（可能顺带触发「目标达成」：庆祝震动 + 撒花事件）
    this.updateGoalProgressByTasks(goalId)
    this.touchGoal(goalId)

    // 5) 触觉反馈：仅完成方向给一次「任务完成」中震。
    //    ⚠️ 若本次正好把整个目标推到达成，goalCompleted 的节奏震更"重"，应由它独占
    //       （HapticFeedback 有 60ms 限流，后到的会被丢弃）→ 此时不再补任务中震。
    const goalAfter: GoalCardItem | null = this.findGoal(goalId)
    const goalJustCompleted: boolean = completed && progressBefore < 100 &&
      goalAfter !== null && goalAfter.progress >= 100
    if (completed && !goalJustCompleted) {
      hapticFeedback.taskCompleted()
    }

    this.scheduleSave()
    Logger.info(this.tag, 'setTaskCompletion: goalId=' + goalId + ', taskId=' + taskId +
      ', completed=' + completed.toString() + ', steps=' + steps.length.toString() +
      ', stepChanged=' + stepChanged.toString())
    return true
  }

  /**
   * 直接修改 AiGeneratedTask 的 @Trace 属性
   */
  addStep(goalId: Id, taskId: Id, stepText: string): boolean {
    if (!goalId || !taskId) return false
    if (typeof stepText !== 'string' || stepText.trim().length === 0) return false
    const task: AiGeneratedTask | null = this.findTask(goalId, taskId)
    if (!task) return false
    const newSteps: TaskStep[] = []
    if (Array.isArray(task.steps)) {
      for (let i: number = 0; i < task.steps.length; i++) {
        newSteps.push(task.steps[i])
      }
    }
    // 新步骤分配**稳定 id** —— 列表增删动效依赖它作 key（原先只能靠下标，禁用动效）
    newSteps.push(new TaskStep(generateStepId(), stepText.trim(), false))
    task.steps = newSteps
    // L3 步骤属于目标内容 → 刷新目标条目版本
    this.touchGoal(goalId)
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
    const oldSteps: TaskStep[] = Array.isArray(task.steps) ? task.steps : []
    if (oldSteps.length <= 1) {
      Logger.warn(this.tag, 'removeStep: cannot remove last step, goalId=' + goalId + ', taskId=' + taskId)
      return false
    }
    if (stepIndex >= oldSteps.length) return false
    // 完成状态与文本同存于一个对象，删除即整体移除 —— 不再需要额外维护平行数组
    const newSteps: TaskStep[] = oldSteps.filter((_: TaskStep, idx: number): boolean => idx !== stepIndex)
    task.steps = newSteps
    // L3 步骤属于目标内容 → 刷新目标条目版本
    this.touchGoal(goalId)
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
    const oldSteps: TaskStep[] = Array.isArray(task.steps) ? task.steps : []
    if (stepIndex >= oldSteps.length) return false
    const newSteps: TaskStep[] = []
    for (let i: number = 0; i < oldSteps.length; i++) {
      const s: TaskStep = oldSteps[i]
      // ⚠️ 编辑文本必须**保留原 id** —— 步骤身份不因文字变化而改变。
      //    否则 key 变化会被框架判定为"删除 + 新增"，凭空播一次增删动效。
      newSteps.push(i === stepIndex ? new TaskStep(s.id, newText.trim(), s.isCompleted) : s)
    }
    task.steps = newSteps
    // L3 步骤属于目标内容 → 刷新目标条目版本
    this.touchGoal(goalId)
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
    const oldSteps: TaskStep[] = Array.isArray(task.steps) ? task.steps : []
    if (fromIndex >= oldSteps.length || toIndex >= oldSteps.length) return false
    const newSteps: TaskStep[] = []
    for (let i: number = 0; i < oldSteps.length; i++) {
      newSteps.push(oldSteps[i])
    }
    // 完成状态与文本同在一个对象里 → 重排一次即可
    // （原先还要同步重排 completedSteps 平行数组、并补齐/截断长度）
    const removed: TaskStep = newSteps.splice(fromIndex, 1)[0]
    newSteps.splice(toIndex, 0, removed)
    task.steps = newSteps
    // L3 步骤顺序属于目标内容 → 刷新目标条目版本
    this.touchGoal(goalId)
    this.scheduleSave()
    Logger.info(this.tag, 'reorderSteps: success, goalId=' + goalId + ', taskId=' + taskId +
      ', from=' + fromIndex.toString() + ', to=' + toIndex.toString())
    return true
  }

  findGoal(goalId: Id): GoalCardItem | null {
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
    // 对象化后逐个改元素上的 @Trace isCompleted 即可（原先需重建平行数组并整体替换）
    if (Array.isArray(task.steps) && task.steps.length > 0) {
      for (let i: number = 0; i < task.steps.length; i++) {
        task.steps[i].isCompleted = completed === true
      }
    }

    // 完成态时间轴打点：仅当完成态真的变化时打
    // （L4 → L2 联动也算一次完成态变更，跨设备裁决时须能被识别）
    const wasTaskCompleted: boolean = task.status === TaskStatus.COMPLETED
    task.status = completed ? TaskStatus.COMPLETED : TaskStatus.PENDING
    if (wasTaskCompleted !== completed) {
      task.completionUpdatedAt = Date.now()
    }
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
    // L2/L3 状态属于目标内容 → 刷新目标条目版本
    goal.updatedAt = Date.now()

    this.scheduleSave()
    Logger.info(this.tag, 'syncStepFromTodoCompletion: goalId=' + goalId +
      ', taskId=' + taskId + ', completed=' + completed.toString() +
      ', actualCompletionTime=' + task.actualCompletionTime.toString() +
      ', completionUpdatedAt=' + task.completionUpdatedAt.toString())
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
