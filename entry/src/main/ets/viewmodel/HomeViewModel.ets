/**
 * @file 首页 ViewModel - V2 原地修改版
 * @description 管理首页待办列表数据、持久化与状态更新
 * @module viewmodel
 * @date 2026-06-21
 */

import {
  HomeTodoItem, HomeTodoItemJSON, Id, TaskPriority,
  hydrateHomeTodoItem, isValidHomeTodoItem,
  snapshotHomeTodoItem, getPriorityValue, buildManualTodoItem,
  EisenhowerQuadrant, EisenhowerQuadrantData, EisenhowerMatrix
} from '../model/Models'
import { Logger } from '../common/utils/Logger'
import { StorageManager } from '../common/utils/StorageManager'
import { CommonConstants } from '../common/constants/CommonConstants'
import { PersistHelper } from '../common/utils/PersistHelper'
import { formatEstimatedDuration } from '../common/utils/SafeUtils'
import { formProvider } from '@kit.FormKit'
import { formBindingData } from '@kit.FormKit'
import { preferences } from '@kit.ArkData'
import { fileIo as fs } from '@kit.CoreFileKit'
// 功能8：截止日期系统提醒服务
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
  FocusCompletedPayload,
  GoalRemovedPayload,
  TaskRemovedPayload
} from '../common/event/AppEventBus'

/** 持久化快照结构 */
interface HomeVMSnapshot {
  taskList: Array<HomeTodoItemJSON>
  version: number
}

interface FormBindingData {
  totalCount: number
  completedCount: number
  task1Title: string
  task2Title: string
  hasTasks: boolean
}

// 加到 HomeViewModel 文件顶部（import 下面）
interface WidgetCardData {
  totalCount: number
  completedCount: number
  task1Title: string
  task2Title: string
  hasTasks: boolean
  completionRate: number
  remainingCount: number
  showTask1: boolean
  showTask2: boolean
  showDivider: boolean
  showMore: boolean
  showProgress: boolean
  showHeaderStats: boolean
}

@ObservedV2
export class HomeViewModel {
  private readonly tag: string = 'HomeViewModel'

  @Trace isFirstLoading: boolean = true
  @Trace isLoaded: boolean = false
  @Trace isLoading: boolean = false
  @Trace loadError: boolean = false
  @Trace taskList: Array<HomeTodoItem> = []
  /**
   * 当前分钟时间戳（每分钟自动刷新）
   * 作为象限"紧急度"的响应式时钟源：@Computed 对 Date.now() 不敏感，
   * deadline 跨过 24h 线时若数据无其他变更不会重算——依赖此字段让"流动"实时发生
   */
  @Trace nowMinute: number = Date.now()
  /** 时钟定时器 ID */
  private nowTimerId: number = -1

  @Computed
  get todayStudyMinutes(): number {
    // 口径：仅统计"今天完成"的任务（按 actualCompletionTime 判断），
    // 历史完成的任务不计入今日投入（AI 复盘/统计依赖此口径）
    // 日期基准读 nowMinute：跨天零点后随时钟刷新，无需等数据变更
    const dayStart: Date = new Date(this.nowMinute)
    dayStart.setHours(0, 0, 0, 0)
    const dayStartMillis: number = dayStart.getTime()
    let totalMinutes: number = 0
    const alive: Array<HomeTodoItem> = this.liveTasks
    for (let i: number = 0; i < alive.length; i++) {
      const task: HomeTodoItem = alive[i]
      if (!task.isCompleted) continue
      if (task.actualCompletionTime < dayStartMillis) continue
      const minutes: number = this.parseDurationToMinutes(task.duration)
      totalMinutes += minutes
    }
    return totalMinutes
  }

  /**
   * 对外统一视图：**过滤掉墓碑条目**（isDeleted === true）
   *
   * 数据分层规范（云同步重构）：
   *   - 底层 `taskList`：原始完整数据集，**含墓碑条目**，仅用于「同步合并 / 本地持久化」
   *   - 对外 `liveTasks`：UI 页面 / 统计计数 / 提醒服务 / 导出备份统一读取此视图
   * ⚠️ 禁止在 UI、统计、提醒、导出中直接遍历底层 taskList
   */
  @Computed
  get liveTasks(): Array<HomeTodoItem> {
    const alive: Array<HomeTodoItem> = []
    for (let i: number = 0; i < this.taskList.length; i++) {
      const task: HomeTodoItem = this.taskList[i]
      if (task.isDeleted !== true) {
        alive.push(task)
      }
    }
    return alive
  }

  /**
   * 同步落地抑制标志：`applyCloudSnapshot` 执行期间为 true
   * - 抑制 onScheduleFire 发出 SYNC_NEEDED：否则「merge → 落地 → 触发同步 → merge」死循环
   * - **不影响本地持久化**：落盘照旧（落地数据必须持久化），只是不再触发云同步
   */
  private isApplyingCloudSnapshot: boolean = false

  private context: Context | null = null
  private persistHelper: PersistHelper = new PersistHelper(
    'HomeViewModel',
    async (): Promise<void> => { await this.persistData() },
    200,
    (): void => {
      // 同步落地触发的持久化：只落盘，不打脏标记、不触发云同步（防回环，消费一次后复位）
      if (this.isApplyingCloudSnapshot) {
        this.isApplyingCloudSnapshot = false
        Logger.info(this.tag, 'onScheduleFire skipped: applying cloud snapshot, break sync loop')
        return
      }
      // 防抖写入完成后触发云同步：通过事件总线通知 SettingsVM，解耦循环依赖
      const isLoggedIn: boolean = AppStorage.get<boolean>('isLoggedIn') ?? false
      if (isLoggedIn) {
        eventBus.emit(EventType.SYNC_NEEDED, null)
      }
    }
  )
  /** 事件总线订阅 ID 列表（用于精确取消订阅） */
  private goalRemovedCbId: number = -1
  private taskRemovedCbId: number = -1
  private goalRenamedCbId: number = -1
  private taskInfoUpdatedCbId: number = -1
  private taskCompletionSyncedCbId: number = -1
  private focusCompletedCbId: number = -1
  private clearAllCbId: number = -1
  private flushCbId: number = -1

  private static readonly CURRENT_VERSION: number = 1

  @Computed
  get completionRate(): number {
    const alive: Array<HomeTodoItem> = this.liveTasks
    const total: number = alive.length
    if (total === 0) return 0
    let done: number = 0
    for (let i: number = 0; i < total; i++) {
      if (alive[i].isCompleted) done++
    }
    return Math.round((done / total) * 100)
  }

  @Computed
  get completedTaskCount(): number {
    const alive: Array<HomeTodoItem> = this.liveTasks
    let count: number = 0
    for (let i: number = 0; i < alive.length; i++) {
      if (alive[i].isCompleted) count++
    }
    return count
  }

  /**
   * 已完成的待办（按完成时间倒序）
   * 供首页"已完成"折叠区展示：勾选后不再凭空消失，可查看、可点击反悔
   */
  @Computed
  get completedTasks(): Array<HomeTodoItem> {
    const alive: Array<HomeTodoItem> = this.liveTasks
    const done: Array<HomeTodoItem> = []
    for (let i: number = 0; i < alive.length; i++) {
      if (alive[i].isCompleted) {
        done.push(alive[i])
      }
    }
    done.sort((a: HomeTodoItem, b: HomeTodoItem): number => b.actualCompletionTime - a.actualCompletionTime)
    return done
  }

  @Computed
  get pendingTaskCount(): number {
    return this.liveTasks.length - this.completedTaskCount
  }

  @Computed
  get tasksSortedByPriority(): Array<HomeTodoItem> {
    const sorted: Array<HomeTodoItem> = []
    const alive: Array<HomeTodoItem> = this.liveTasks
    for (let i: number = 0; i < alive.length; i++) {
      sorted.push(alive[i])
    }
    sorted.sort((a: HomeTodoItem, b: HomeTodoItem): number => {
      const priorityA: number = getPriorityValue(a.priority)
      const priorityB: number = getPriorityValue(b.priority)
      if (priorityA !== priorityB) {
        return priorityB - priorityA
      }
      return b.createTime - a.createTime
    })
    return sorted
  }

  // 艾森豪威尔四象限分类：taskList 变化时 @Computed 自动重算，UI 绑定后自动刷新
  // 重要度 = priority === HIGH，紧急度 = deadline 距当前 < 24 小时
  // "now" 读自 nowMinute（@Trace）：每分钟刷新一次时钟源，deadline 跨线任务即时换象限
  @Computed
  get eisenhowerMatrix(): EisenhowerMatrix {
    const URGENT_THRESHOLD_MS: number = 24 * 60 * 60 * 1000
    const now: number = this.nowMinute

    const q1Tasks: Array<HomeTodoItem> = []
    const q2Tasks: Array<HomeTodoItem> = []
    const q3Tasks: Array<HomeTodoItem> = []
    const q4Tasks: Array<HomeTodoItem> = []

    const alive: Array<HomeTodoItem> = this.liveTasks
    for (let i: number = 0; i < alive.length; i++) {
      const task: HomeTodoItem = alive[i]
      if (task.isCompleted) continue

      const isImportant: boolean = task.priority === TaskPriority.HIGH
      const hasDeadline: boolean = typeof task.deadline === 'number' && task.deadline > 0
      const isUrgent: boolean = hasDeadline && (task.deadline - now) < URGENT_THRESHOLD_MS

      if (isImportant && isUrgent) {
        q1Tasks.push(task)
      } else if (isImportant && !isUrgent) {
        q2Tasks.push(task)
      } else if (!isImportant && isUrgent) {
        q3Tasks.push(task)
      } else {
        q4Tasks.push(task)
      }
    }

    // 象限内排序：优先级 高>中>低，同级按创建时间 新>旧（启用 tasksSortedByPriority 的排序规则）
    this.sortTasksByPriority(q1Tasks)
    this.sortTasksByPriority(q2Tasks)
    this.sortTasksByPriority(q3Tasks)
    this.sortTasksByPriority(q4Tasks)

    const q1: EisenhowerQuadrantData = { quadrant: EisenhowerQuadrant.Q1_IMPORTANT_URGENT, tasks: q1Tasks, count: q1Tasks.length }
    const q2: EisenhowerQuadrantData = { quadrant: EisenhowerQuadrant.Q2_IMPORTANT_NOT_URGENT, tasks: q2Tasks, count: q2Tasks.length }
    const q3: EisenhowerQuadrantData = { quadrant: EisenhowerQuadrant.Q3_NOT_IMPORTANT_URGENT, tasks: q3Tasks, count: q3Tasks.length }
    const q4: EisenhowerQuadrantData = { quadrant: EisenhowerQuadrant.Q4_NOT_IMPORTANT_NOT_URGENT, tasks: q4Tasks, count: q4Tasks.length }

    return { q1, q2, q3, q4 }
  }

  /** 原地排序：优先级降序，同级创建时间降序 */
  private sortTasksByPriority(tasks: Array<HomeTodoItem>): void {
    tasks.sort((a: HomeTodoItem, b: HomeTodoItem): number => {
      const priorityA: number = getPriorityValue(a.priority)
      const priorityB: number = getPriorityValue(b.priority)
      if (priorityA !== priorityB) {
        return priorityB - priorityA
      }
      return b.createTime - a.createTime
    })
  }

  getTasksByQuadrant(quadrant: EisenhowerQuadrant): Array<HomeTodoItem> {
    const matrix: EisenhowerMatrix = this.eisenhowerMatrix
    if (quadrant === EisenhowerQuadrant.Q1_IMPORTANT_URGENT) return matrix.q1.tasks
    if (quadrant === EisenhowerQuadrant.Q2_IMPORTANT_NOT_URGENT) return matrix.q2.tasks
    if (quadrant === EisenhowerQuadrant.Q3_NOT_IMPORTANT_URGENT) return matrix.q3.tasks
    return matrix.q4.tasks
  }

  private parseDurationToMinutes(duration: string): number {
    if (!duration || typeof duration !== 'string') return 0
    const trimmed: string = duration.trim()
    if (trimmed.length === 0) return 0
    const match: RegExpMatchArray | null = trimmed.match(/(\d+(\.\d+)?)/)
    if (!match || match.length < 2) return 0
    const value: number = parseFloat(match[1])
    if (isNaN(value) || value < 0) return 0
    if (trimmed.includes('h') || trimmed.includes('H') || trimmed.includes('小时')) {
      return Math.round(value * 60)
    }
    return Math.round(value)
  }

  constructor() {}

  async init(context: Context): Promise<void> {
    if (!context) {
      this.isFirstLoading = false
      this.isLoaded = true
      return
    }
    if (this.isLoading) {
      Logger.info(this.tag, 'init: already loading, skip')
      this.isFirstLoading = false
      return
    }
    if (this.isLoaded) {
      this.isFirstLoading = false
      return
    }
    this.isLoading = true
    this.loadError = false
    this.context = context

    // 注册事件总线订阅（幂等：重复 init 时先 off 再 on）
    this.registerEventBusListeners()

    try {
      const rawSnapshot: HomeVMSnapshot | null = await StorageManager.loadData<HomeVMSnapshot | null>(
        context,
        CommonConstants.STORAGE_KEY_HOME_TODOS,
        null
      )
      const snapshot: HomeVMSnapshot = rawSnapshot ?? this.buildEmptySnapshot()

      this.migrateIfNeeded(snapshot.version)

      if (Array.isArray(snapshot.taskList) && snapshot.taskList.length > 0) {
        this.taskList.splice(0, this.taskList.length)
        for (let i: number = 0; i < snapshot.taskList.length; i++) {
          const raw: HomeTodoItemJSON = snapshot.taskList[i]
          const task: HomeTodoItem | null = this.hydrateTask(raw)
          if (task) {
            this.taskList.push(task)
          }
        }
      }

      this.isLoaded = true
      // 提醒只针对存活条目（墓碑不得再排提醒）
      deadlineReminderService.rescheduleAll(this.liveTasks)

      // 修复：冷启动加载完数据后，主动推送一次卡片
      this.notifyFormUpdate()

      // 象限"流动"时钟：每分钟刷新 nowMinute，驱动 eisenhowerMatrix /
      // todayStudyMinutes 等时间敏感的 @Computed 实时重算
      if (this.nowTimerId === -1) {
        this.nowTimerId = setInterval((): void => {
          this.nowMinute = Date.now()
        }, 60 * 1000)
      }
    } catch (e) {
      Logger.error(this.tag, 'init failed: ' + ((e as Error).message))
      this.loadError = true
    } finally {
      this.isFirstLoading = false
      this.isLoading = false
    }
  }

  /**
   * 重试加载：重置状态后重新调用 init
   * - 供 HomePage 错误态 onRetry 回调使用
   */
  retryLoad(): void {
    if (!this.context) {
      Logger.warn(this.tag, 'retryLoad: context is null, skip')
      return
    }
    this.isLoaded = false
    this.loadError = false
    this.isFirstLoading = true
    this.init(this.context)
  }

  private hydrateTask(raw: HomeTodoItemJSON): HomeTodoItem | null {
    const task: HomeTodoItem | null = hydrateHomeTodoItem(raw)
    if (!task) {
      Logger.warn(this.tag, 'hydrateTask: skip invalid record, id=' + raw.id)
      return null
    }
    return task
  }

  private migrateIfNeeded(savedVersion: number | undefined): void {
    const version: number = savedVersion ?? 0
    if (version < HomeViewModel.CURRENT_VERSION) {
      Logger.info(this.tag, 'migrating from version ' + version.toString() + ' to ' + HomeViewModel.CURRENT_VERSION.toString())
    }
  }

  private buildEmptySnapshot(): HomeVMSnapshot {
    return { taskList: [], version: HomeViewModel.CURRENT_VERSION }
  }

  /**
   * 注册事件总线监听器（解耦 RoutePageViewModel → HomeViewModel 的调用）
   * 幂等：重复调用时先 off 旧订阅再 on 新订阅
   */
  private registerEventBusListeners(): void {
    // 先清理旧订阅
    this.unregisterEventBusListeners()

    // GOAL_REMOVED：RouteVM 删除目标 → HomeVM 删除关联任务
    this.goalRemovedCbId = eventBus.on(EventType.GOAL_REMOVED, (payload: Object): void => {
      const p: GoalRemovedPayload = payload as GoalRemovedPayload
      if (p.goalId && p.goalId.length > 0) {
        this.removeByRelatedGoalId(p.goalId)
      }
    })

    // TASK_REMOVED：RouteVM 删除任务 → HomeVM 删除关联任务
    this.taskRemovedCbId = eventBus.on(EventType.TASK_REMOVED, (payload: Object): void => {
      const p: TaskRemovedPayload = payload as TaskRemovedPayload
      if (p.taskId && p.taskId.length > 0) {
        this.removeByRelatedTaskId(p.taskId)
      }
    })

    // GOAL_RENAMED：RouteVM 修改目标名 → HomeVM 更新关联目标名
    this.goalRenamedCbId = eventBus.on(EventType.GOAL_RENAMED, (payload: Object): void => {
      const p: GoalRenamedPayload = payload as GoalRenamedPayload
      this.updateRelatedGoalName(p.goalId, p.newName)
    })

    // TASK_INFO_UPDATED：RouteVM 修改任务信息 → HomeVM 更新关联任务信息（含优先级/截止时间）
    this.taskInfoUpdatedCbId = eventBus.on(EventType.TASK_INFO_UPDATED, (payload: Object): void => {
      const p: TaskInfoUpdatedPayload = payload as TaskInfoUpdatedPayload
      this.updateRelatedTaskInfo(p.taskId, p.newTitle, p.newEstimatedTime, p.newPriority, p.newDeadline)
    })

    // TASK_COMPLETION_SYNCED：RouteVM 反向同步任务完成状态 → HomeVM 同步
    this.taskCompletionSyncedCbId = eventBus.on(EventType.TASK_COMPLETION_SYNCED, (payload: Object): void => {
      const p: TaskCompletionSyncedPayload = payload as TaskCompletionSyncedPayload
      this.syncRelatedTaskCompletion(p.taskId, p.completed)
    })

    // FOCUS_COMPLETED：番茄钟专注轮完成 → 累加对应任务的聚焦统计
    this.focusCompletedCbId = eventBus.on(EventType.FOCUS_COMPLETED, (payload: Object): void => {
      const p: FocusCompletedPayload = payload as FocusCompletedPayload
      this.addFocusToRelatedTask(p.taskId, p.focusMillis)
    })

    // CLEAR_ALL_REQUESTED：SettingsVM 退出登录 → HomeVM 清空数据
    this.clearAllCbId = eventBus.on(EventType.CLEAR_ALL_REQUESTED, (payload: Object): void => {
      this.clearAll()
    })

    // FLUSH_REQUESTED：SettingsVM 退出登录 → HomeVM 刷盘
    this.flushCbId = eventBus.on(EventType.FLUSH_REQUESTED, (payload: Object): void => {
      this.flush().catch((e: Error): void => {
        Logger.warn(this.tag, 'FLUSH_REQUESTED flush failed: ' + e.message)
      })
    })
  }

  /**
   * 注销事件总线监听器
   */
  private unregisterEventBusListeners(): void {
    if (this.goalRemovedCbId > 0) { eventBus.off(EventType.GOAL_REMOVED, this.goalRemovedCbId); this.goalRemovedCbId = -1 }
    if (this.taskRemovedCbId > 0) { eventBus.off(EventType.TASK_REMOVED, this.taskRemovedCbId); this.taskRemovedCbId = -1 }
    if (this.goalRenamedCbId > 0) { eventBus.off(EventType.GOAL_RENAMED, this.goalRenamedCbId); this.goalRenamedCbId = -1 }
    if (this.taskInfoUpdatedCbId > 0) { eventBus.off(EventType.TASK_INFO_UPDATED, this.taskInfoUpdatedCbId); this.taskInfoUpdatedCbId = -1 }
    if (this.taskCompletionSyncedCbId > 0) { eventBus.off(EventType.TASK_COMPLETION_SYNCED, this.taskCompletionSyncedCbId); this.taskCompletionSyncedCbId = -1 }
    if (this.focusCompletedCbId > 0) { eventBus.off(EventType.FOCUS_COMPLETED, this.focusCompletedCbId); this.focusCompletedCbId = -1 }
    if (this.clearAllCbId > 0) { eventBus.off(EventType.CLEAR_ALL_REQUESTED, this.clearAllCbId); this.clearAllCbId = -1 }
    if (this.flushCbId > 0) { eventBus.off(EventType.FLUSH_REQUESTED, this.flushCbId); this.flushCbId = -1 }
  }

  private scheduleSave(): void {
    if (!this.context) return
    this.persistHelper.scheduleSave()
  }

  private async persistData(): Promise<void> {
    if (!this.context) return

    const jsonList: Array<HomeTodoItemJSON> = []
    for (let i: number = 0; i < this.taskList.length; i++) {
      const task: HomeTodoItem = this.taskList[i]
      const json: HomeTodoItemJSON | null = snapshotHomeTodoItem(task)
      if (json) {
        jsonList.push(json)
      }
    }

    const snapshot: HomeVMSnapshot = {
      taskList: jsonList,
      version: HomeViewModel.CURRENT_VERSION
    }

    try {
      await StorageManager.saveData(this.context, CommonConstants.STORAGE_KEY_HOME_TODOS, snapshot)
      await this.notifyFormUpdate()
    } catch (e) {
      Logger.error(this.tag, 'persistNow failed: ' + ((e as Error).message))
    }
  }

  private async notifyFormUpdate(): Promise<void> {
    if (!this.context) {
      Logger.warn(this.tag, 'notifyFormUpdate: context is null, skipping')
      return
    }
    try {
      const ctx = this.context
      // 桌面卡片属于对外展示：只统计存活条目（墓碑不展示、不计数）
      const alive: Array<HomeTodoItem> = this.liveTasks
      const completedCount: number = alive.filter((t: HomeTodoItem): boolean => t.isCompleted).length
      const unfinishedTasks: Array<HomeTodoItem> = alive.filter((t: HomeTodoItem): boolean => !t.isCompleted)
      const task1Title: string = unfinishedTasks.length > 0 ? unfinishedTasks[0].title : ''
      const task2Title: string = unfinishedTasks.length > 1 ? unfinishedTasks[1].title : ''
      const remainingCount: number = alive.length - completedCount
      const completionRate: number = alive.length > 0
        ? Math.round((completedCount / alive.length) * 100)
        : 0

      const cardData: WidgetCardData = {
        totalCount: alive.length,
        completedCount: completedCount,
        task1Title: task1Title,
        task2Title: task2Title,
        hasTasks: alive.length > 0,
        completionRate: completionRate,
        remainingCount: remainingCount,
        showTask1: task1Title.length > 0,
        showTask2: task2Title.length > 0,
        showDivider: task1Title.length > 0 && task2Title.length > 0,
        showMore: remainingCount > 2,
        showProgress: alive.length > 0,
        showHeaderStats: alive.length > 0
      }

      Logger.info(this.tag, 'notifyFormUpdate: cardData total=' + cardData.totalCount.toString() +
        ', rate=' + cardData.completionRate.toString() +
        ', showTask1=' + cardData.showTask1.toString())

      // 1. 将完整快照写入共享目录（EntryFormAbility 也会读这个文件）
      const appCtx = ctx.getApplicationContext()
      const snapshotPath: string = appCtx.filesDir + '/card_snapshot.json'
      const jsonStr: string = JSON.stringify(cardData)
      const snapshotFile = fs.openSync(snapshotPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC)
      fs.writeSync(snapshotFile.fd, jsonStr)
      fs.closeSync(snapshotFile)
      Logger.info(this.tag, 'notifyFormUpdate: wrote full snapshot to ' + snapshotPath)

      // 2. 从 preferences 读取 formId
      let formIdStr: string = ''
      try {
        const prefs = await preferences.getPreferences(ctx, 'momentum_card_store')
        formIdStr = await prefs.get('form_id', '') as string
        if (formIdStr.length > 0) {
          Logger.info(this.tag, 'notifyFormUpdate: formId found: ' + formIdStr)
        } else {
          Logger.warn(this.tag, 'notifyFormUpdate: formId not found in preferences')
        }
      } catch (e) {
        Logger.warn(this.tag, 'notifyFormUpdate: read formId failed: ' + (e as Error).message)
      }

      // 3. 推送完整数据给卡片（Widget 直接收到所有字段）
      if (formIdStr.length > 0) {
        try {
          await formProvider.updateForm(formIdStr, formBindingData.createFormBindingData(cardData))
          Logger.info(this.tag, 'notifyFormUpdate: updateForm success')
        } catch (e) {
          Logger.error(this.tag, 'notifyFormUpdate: updateForm failed: ' + (e as Error).message)
        }
        return
      }

      Logger.warn(this.tag, 'notifyFormUpdate: no formId, snapshot saved only')
    } catch (e) {
      Logger.error(this.tag, 'notifyFormUpdate: failed: ' + ((e as Error).message))
    }
  }

  async flush(): Promise<void> {
    await this.persistHelper.flush()
  }

  /**
   * 同步用快照：**包含墓碑条目**（底层原始数据）
   * ⚠️ 仅供云同步的本地快照提供者使用（`MainTab.registerSnapshotProviders`）。
   *    若改用过滤后的视图，删除操作无法上传 → 墓碑传播失效 → 对端删除复活。
   */
  buildSyncSnapshot(): HomeVMSnapshot {
    const jsonList: Array<HomeTodoItemJSON> = []
    for (let i: number = 0; i < this.taskList.length; i++) {
      const json: HomeTodoItemJSON | null = snapshotHomeTodoItem(this.taskList[i])
      if (json) {
        jsonList.push(json)
      }
    }
    return {
      taskList: jsonList,
      version: HomeViewModel.CURRENT_VERSION
    }
  }

  /**
   * 对外快照（导出备份等）：**过滤墓碑条目**
   * ⚠️ 禁止用于云同步（会丢墓碑）
   */
  buildSnapshot(): HomeVMSnapshot {
    const jsonList: Array<HomeTodoItemJSON> = []
    const alive: Array<HomeTodoItem> = this.liveTasks
    for (let i: number = 0; i < alive.length; i++) {
      const json: HomeTodoItemJSON | null = snapshotHomeTodoItem(alive[i])
      if (json) {
        jsonList.push(json)
      }
    }
    return {
      taskList: jsonList,
      version: HomeViewModel.CURRENT_VERSION
    }
  }

  /**
   * 应用云端合并结果（同步落地）
   *
   * ⚠️ 两条硬约束（违反会造成反复上传 / 死循环）：
   *   1. **禁止改写条目 updatedAt** —— 这里只做 rehydrate，`hydrateTask` 保留原值；
   *      若在落地时刷成本机时间，会伪造"本机更新"，导致指纹每次都不等、反复上传
   *   2. **禁止走 scheduleSave**（防抖 + onScheduleFire 会打脏标记并再触发 merge）→
   *      改为直接 `persistData()` 落盘，不发 SYNC_NEEDED
   */
  applyCloudSnapshot(cloudData: Record<string, Object>): void {
    // 兜底防线：若期间有其它路径误触发防抖写入，会被 onScheduleFire 消费一次并跳过
    this.isApplyingCloudSnapshot = true
    try {
      const taskListRaw: Object | undefined = cloudData['taskList']
      if (Array.isArray(taskListRaw)) {
        const rehydratedTasks: HomeTodoItem[] = []
        const items: Object[] = taskListRaw as Object[]
        for (let i: number = 0; i < items.length; i++) {
          const raw: HomeTodoItemJSON = items[i] as HomeTodoItemJSON
          const task: HomeTodoItem | null = this.hydrateTask(raw)
          if (task) {
            rehydratedTasks.push(task)
          }
        }
        this.taskList.splice(0, this.taskList.length, ...rehydratedTasks)
      }
      // 直接落盘（不触发云同步）；`persistData` 内部已包含桌面卡片推送
      this.persistData().catch((e: Error): void => {
        Logger.error(this.tag, 'applyCloudSnapshot persist failed: ' + e.message)
      })
    } finally {
      // 正常情况下不会走 onScheduleFire；此处复位避免标志长期滞留
      this.isApplyingCloudSnapshot = false
    }
  }

  toggleTask(taskId: Id): void {
    if (!taskId) return
    try {
      // 墓碑条目不再参与交互：只在存活视图里查找
      const task: HomeTodoItem | undefined = this.liveTasks.find((t: HomeTodoItem): boolean => t.id === taskId)
      if (!task) return
      const wasCompleted: boolean = task.isCompleted
      task.isCompleted = !task.isCompleted
      if (task.isCompleted) {
        if (task.actualCompletionTime === 0) {
          task.actualCompletionTime = Date.now()
        }
        // 触觉反馈：任务完成中震。toggleTask 是两个用户入口（首页勾选 / 任务详情页勾选）
        // 的唯一汇聚点，在此挂一次即可；联动写入（syncRelatedTaskCompletion）不经过此处
        hapticFeedback.taskCompleted()
      } else {
        task.actualCompletionTime = 0
      }
      // 完成态真的翻转 → 推进 L4 完成态轴（与 L2 的 completionUpdatedAt 对称）
      // ⚠️ 只有翻转才打点：非完成类写操作（专注累计 / 改截止 / 改名级联 / 墓碑）**禁止**刷新，
      //    否则对端一次无关编辑就能把本机刚声明的完成压掉
      if (wasCompleted !== task.isCompleted) {
        task.completionUpdatedAt = Date.now()
      }
      // 条目内容已变 → 刷新条目版本，保证跨设备冲突时本机改动胜出
      task.updatedAt = Date.now()
      if (task.relatedGoalId && task.relatedTaskId) {
        // 解耦：通过事件总线通知 RoutePageViewModel
        const payload: TodoCompletedPayload = {
          goalId: task.relatedGoalId,
          taskId: task.relatedTaskId,
          completed: task.isCompleted
        }
        eventBus.emit(EventType.TODO_COMPLETED, payload as Object)
      }
      if (task.isCompleted) {
        deadlineReminderService.cancelTaskDeadlineReminder(task.id)
      } else {
        deadlineReminderService.scheduleTaskDeadlineReminder(task)
      }
      this.scheduleSave()
    } catch (e) {
      Logger.error(this.tag, 'toggleTask failed: ' + ((e as Error).message))
    }
  }

  // 批量添加待办：逐条校验 + id 去重（防止同一任务被重复推入），成功后调度截止提醒
  addTasks(newTasks: Array<HomeTodoItem>): void {
    if (!Array.isArray(newTasks) || newTasks.length === 0) return
    let addedCount: number = 0
    for (let j: number = 0; j < newTasks.length; j++) {
      const task: HomeTodoItem = newTasks[j]
      if (!isValidHomeTodoItem(task)) continue
      const exists: boolean = this.taskList.some((t: HomeTodoItem): boolean => t.id === task.id)
      if (exists) continue
      // 新建条目必须有版本时间戳（冲突裁决依据）
      if (!(task.updatedAt > 0)) {
        task.updatedAt = Date.now()
      }
      task.isDeleted = false
      this.taskList.push(task)
      deadlineReminderService.scheduleTaskDeadlineReminder(task)
      addedCount++
    }
    if (addedCount > 0) {
      this.scheduleSave()
    }
  }

  // 单条添加待办（AI 确认方案主线入口）：AIPage.handleConfirmPlan 构造 HomeTodoItem 后调用
  // id 去重保证重复点击"加入待办"安全，成功后触发 scheduleSave → 防抖落盘 + 云同步
  addExtractedTask(todo: HomeTodoItem | null | undefined): boolean {
    // 摘取路径：4 级架构红线生效（关联字段必须非空）
    if (!todo || !isValidHomeTodoItem(todo)) return false
    return this.insertTodo(todo)
  }

  /**
   * 入库共用内核（摘取 / 手动两条路径只有**入口校验**不同，入库动作完全一致）：
   * 按 id 去重 → 补版本时间戳 → 墓碑复位 → 入列 → 排期截止提醒 → 防抖落盘
   */
  private insertTodo(todo: HomeTodoItem): boolean {
    const exists: boolean = this.taskList.some((t: HomeTodoItem): boolean => t.id === todo.id)
    if (exists) return false
    // 新建条目必须有版本时间戳（冲突裁决依据）
    if (!(todo.updatedAt > 0)) {
      todo.updatedAt = Date.now()
    }
    todo.isDeleted = false
    this.taskList.push(todo)
    deadlineReminderService.scheduleTaskDeadlineReminder(todo)
    this.scheduleSave()
    return true
  }

  /**
   * 手动添加一条待办（首页 FAB →「添加待办」弹层）
   *
   * 与「从目标摘取」的差别：**没有关联目标/任务**（relatedGoalId / relatedTaskId 留空），
   * 因此不参与目标进度联动 —— 它就是用户临时记下的一件事。
   * 入库走共用的 `insertTodo` 内核（去重 / `updatedAt` 兜底 / 提醒排期 / 落盘）；
   * 校验用 `isValidHomeTodoItem(todo, false)`（关联字段仅做类型校验）。
   *
   * @param title 标题
   * @param priority 优先级（由"选象限"反推，见 HomePage.handleAddTodo）
   * @param deadline 截止时间戳（0 = 无；同样由"选象限"反推）
   * @returns 是否添加成功
   */
  addManualTask(title: string, priority: TaskPriority, deadline: number): boolean {
    const trimmed: string = title.trim()
    if (trimmed.length === 0) return false
    try {
      // 必须走专用工厂：手动待办**天生无 L1/L2 关联**，而 buildHomeTodoItem 默认执行
      // 4 级架构红线（relatedTaskId/relatedGoalId 非空），会直接抛
      // `relatedTaskId is required` —— 真机已复现"点添加就失败"。
      const todo: HomeTodoItem = buildManualTodoItem(
        CommonConstants.ITEM_ID_PREFIX + Date.now().toString(),
        trimmed,
        priority,
        deadline > 0 ? deadline : 0
      )
      // 与工厂同口径（requireRelation=false）：只校验类型与其余必填项
      if (!isValidHomeTodoItem(todo, false)) return false
      return this.insertTodo(todo)
    } catch (e) {
      Logger.error(this.tag, 'addManualTask failed: ' + (e as Error).message)
      return false
    }
  }

  /**
   * 删除待办：**软删除（墓碑）**
   * - 不从底层 taskList 移除对象，只置 `isDeleted = true` 并刷新条目 `updatedAt`
   * - 底层保留条目 → 删除状态可随 merge 传播到其他设备，杜绝"删了又复活"
   * - UI 侧读 `liveTasks` 自动隐藏该条目
   */
  deleteTask(taskId: Id): boolean {
    if (!taskId) return false
    try {
      const task: HomeTodoItem | undefined = this.taskList.find((t: HomeTodoItem): boolean => t.id === taskId)
      if (!task) return false
      if (task.isDeleted === true) return false
      task.isDeleted = true
      task.updatedAt = Date.now()
      deadlineReminderService.cancelTaskDeadlineReminder(taskId)
      // 数据一致性回传：删除"从目标提取"的待办时，同步回滚 L2 任务完成态并重算目标进度
      // （否则 L2 仍为 COMPLETED、目标 progress 虚高，且重新提取会生成已完成状态的待办）
      if (task.relatedGoalId && task.relatedTaskId) {
        const payload: TodoCompletedPayload = {
          goalId: task.relatedGoalId,
          taskId: task.relatedTaskId,
          completed: false
        }
        eventBus.emit(EventType.TODO_COMPLETED, payload as Object)
      }
      this.scheduleSave()
      return true
    } catch (e) {
      return false
    }
  }

  clearAll(): void {
    this.taskList.splice(0, this.taskList.length)
    deadlineReminderService.cancelAllReminders()
    this.scheduleSave()
  }

  /**
   * 级联删除：目标被删除时，把关联待办全部软删除（墓碑）
   * - 不改数组长度、不重建数组（避免与 @Trace 实例脱钩），只就地置墓碑
   */
  removeByRelatedGoalId(goalId: Id): void {
    if (!goalId) return
    let changed: boolean = false
    for (let i: number = 0; i < this.taskList.length; i++) {
      const task: HomeTodoItem = this.taskList[i]
      if (task.isDeleted === true) continue
      if (task.relatedGoalId === goalId) {
        task.isDeleted = true
        task.updatedAt = Date.now()
        changed = true
        // A3 生命周期联动：级联删除时同步取消该待办的 deadline 提醒
        deadlineReminderService.cancelTaskDeadlineReminder(task.id)
      }
    }
    if (changed) {
      this.scheduleSave()
    }
  }

  /**
   * 级联删除：L2 任务被删除时，把关联待办软删除（墓碑）
   */
  removeByRelatedTaskId(taskId: Id): void {
    if (!taskId) return
    let changed: boolean = false
    for (let i: number = 0; i < this.taskList.length; i++) {
      const task: HomeTodoItem = this.taskList[i]
      if (task.isDeleted === true) continue
      if (task.relatedTaskId === taskId) {
        task.isDeleted = true
        task.updatedAt = Date.now()
        changed = true
        // A3 生命周期联动：级联删除时同步取消该待办的 deadline 提醒
        deadlineReminderService.cancelTaskDeadlineReminder(task.id)
      }
    }
    if (changed) {
      this.scheduleSave()
    }
  }

  updateRelatedGoalName(goalId: Id, newGoalName: string): void {
    if (!goalId || !newGoalName) return
    let updated: boolean = false
    // 只更新存活条目：墓碑条目的内容不应再变化（避免无意义的云端上传）
    const alive: Array<HomeTodoItem> = this.liveTasks
    for (let i: number = 0; i < alive.length; i++) {
      const task: HomeTodoItem = alive[i]
      if (task.relatedGoalId === goalId) {
        task.goalName = newGoalName
        task.updatedAt = Date.now()
        updated = true
      }
    }
    if (updated) {
      this.scheduleSave()
    }
  }

  updateRelatedTaskInfo(taskId: Id, newTitle: string, newEstimatedTime: number,
    newPriority?: TaskPriority, newDeadline?: number): void {
    if (!taskId || !newTitle) return
    let updated: boolean = false
    // 只更新存活条目（墓碑条目内容不应再变化）
    const alive: Array<HomeTodoItem> = this.liveTasks
    for (let i: number = 0; i < alive.length; i++) {
      const todo: HomeTodoItem = alive[i]
      if (todo.relatedTaskId === taskId) {
        todo.title = newTitle
        todo.duration = formatEstimatedDuration(newEstimatedTime, this.context !== null ? this.context.resourceManager : null)
        // 优先级/截止时间联动（可选参数，缺省不变更）
        if (newPriority !== undefined) {
          todo.priority = newPriority
        }
        const oldDeadline: number = todo.deadline
        if (newDeadline !== undefined && newDeadline >= 0 && oldDeadline !== newDeadline) {
          todo.deadline = newDeadline
          // 截止时间变更 → 重排该待办的截止提醒（0=清除）
          deadlineReminderService.cancelTaskDeadlineReminder(todo.id)
          if (newDeadline > Date.now() && !todo.isCompleted) {
            deadlineReminderService.scheduleTaskDeadlineReminder(todo)
          }
        }
        // 条目内容已变 → 刷新版本
        todo.updatedAt = Date.now()
        updated = true
      }
    }
    if (updated) {
      this.scheduleSave()
    }
  }

  /**
   * 番茄钟专注完成联动：累加关联待办的聚焦统计
   * @param taskId - L2 任务 ID（匹配待办的 relatedTaskId）
   * @param focusMillis - 本次专注时长（毫秒）
   */
  addFocusToRelatedTask(taskId: Id, focusMillis: number): void {
    if (!taskId || !focusMillis || focusMillis <= 0) return
    let updated: boolean = false
    const alive: Array<HomeTodoItem> = this.liveTasks
    for (let i: number = 0; i < alive.length; i++) {
      const task: HomeTodoItem = alive[i]
      if (task.relatedTaskId === taskId) {
        task.focusCount += 1
        task.focusMillis += focusMillis
        // 专注统计属于条目内容 → 刷新版本
        task.updatedAt = Date.now()
        updated = true
      }
    }
    if (updated) {
      this.scheduleSave()
      Logger.info(this.tag, 'addFocusToRelatedTask: taskId=' + taskId +
        ', millis=' + focusMillis.toString())
    }
  }

  syncRelatedTaskCompletion(taskId: Id, completed: boolean): void {
    if (!taskId) return
    let updated: boolean = false
    const alive: Array<HomeTodoItem> = this.liveTasks
    for (let i: number = 0; i < alive.length; i++) {
      const task: HomeTodoItem = alive[i]
      if (task.relatedTaskId === taskId) {
        const wasCompleted: boolean = task.isCompleted
        task.isCompleted = completed
        if (completed) {
          if (task.actualCompletionTime === 0) {
            task.actualCompletionTime = Date.now()
          }
        } else {
          task.actualCompletionTime = 0
        }
        // 完成态真的变化 → 推进 L4 完成态轴；幂等重复同步（值没变）**不打点**，
        // 否则每次云落地/联动都会刷新该轴，裁决依据失真
        if (wasCompleted !== completed) {
          task.completionUpdatedAt = Date.now()
        }
        task.updatedAt = Date.now()
        updated = true
      }
    }
    if (updated) {
      this.scheduleSave()
    }
  }

  /**
   * 该 L2 任务是否已存在对应待办（含墓碑条目：墓碑条目也算"已提取过"，
   * 避免用户删除后重新摘取时生成重复条目）
   */
  isTaskInTodo(taskId: Id): boolean {
    if (!taskId) return false
    return this.taskList.some((t: HomeTodoItem): boolean => t.relatedTaskId === taskId)
  }
}

export const homeVM: HomeViewModel = new HomeViewModel()