/**
 * @file 首页 ViewModel - V2 原地修改版
 * @description 管理首页待办列表数据、持久化与状态更新
 * @module viewmodel
 * @date 2026-06-21
 */

import {
  HomeTodoItem, HomeTodoItemJSON, Id, TaskPriority,
  hydrateHomeTodoItem, isValidHomeTodoItem,
  snapshotHomeTodoItem, getPriorityValue,
  EisenhowerQuadrant, EisenhowerQuadrantData, EisenhowerMatrix
} from '../model/Models'
import { Logger } from '../common/utils/Logger'
import { StorageManager } from '../common/utils/StorageManager'
import { CommonConstants } from '../common/constants/CommonConstants'
import { PersistHelper } from '../common/utils/PersistHelper'
import { formProvider } from '@kit.FormKit'
import { formBindingData } from '@kit.FormKit'
import { preferences } from '@kit.ArkData'
import { fileIo as fs } from '@kit.CoreFileKit'
// 功能8：截止日期系统提醒服务
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

  @Computed
  get todayStudyMinutes(): number {
    let totalMinutes: number = 0
    for (let i: number = 0; i < this.taskList.length; i++) {
      const task: HomeTodoItem = this.taskList[i]
      if (!task.isCompleted) continue
      const minutes: number = this.parseDurationToMinutes(task.duration)
      totalMinutes += minutes
    }
    return totalMinutes
  }

  private context: Context | null = null
  private persistHelper: PersistHelper = new PersistHelper(
    'HomeViewModel',
    async (): Promise<void> => { await this.persistData() },
    200,
    (): void => {
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
  private clearAllCbId: number = -1
  private flushCbId: number = -1

  private static readonly CURRENT_VERSION: number = 1

  @Computed
  get completionRate(): number {
    const total: number = this.taskList.length
    if (total === 0) return 0
    let done: number = 0
    for (let i: number = 0; i < total; i++) {
      if (this.taskList[i].isCompleted) done++
    }
    return Math.round((done / total) * 100)
  }

  @Computed
  get completedTaskCount(): number {
    let count: number = 0
    for (let i: number = 0; i < this.taskList.length; i++) {
      if (this.taskList[i].isCompleted) count++
    }
    return count
  }

  @Computed
  get pendingTaskCount(): number {
    return this.taskList.length - this.completedTaskCount
  }

  @Computed
  get tasksSortedByPriority(): Array<HomeTodoItem> {
    const sorted: Array<HomeTodoItem> = []
    for (let i: number = 0; i < this.taskList.length; i++) {
      sorted.push(this.taskList[i])
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
  @Computed
  get eisenhowerMatrix(): EisenhowerMatrix {
    const URGENT_THRESHOLD_MS: number = 24 * 60 * 60 * 1000
    const now: number = Date.now()

    const q1Tasks: Array<HomeTodoItem> = []
    const q2Tasks: Array<HomeTodoItem> = []
    const q3Tasks: Array<HomeTodoItem> = []
    const q4Tasks: Array<HomeTodoItem> = []

    for (let i: number = 0; i < this.taskList.length; i++) {
      const task: HomeTodoItem = this.taskList[i]
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

    const q1: EisenhowerQuadrantData = { quadrant: EisenhowerQuadrant.Q1_IMPORTANT_URGENT, tasks: q1Tasks, count: q1Tasks.length }
    const q2: EisenhowerQuadrantData = { quadrant: EisenhowerQuadrant.Q2_IMPORTANT_NOT_URGENT, tasks: q2Tasks, count: q2Tasks.length }
    const q3: EisenhowerQuadrantData = { quadrant: EisenhowerQuadrant.Q3_NOT_IMPORTANT_URGENT, tasks: q3Tasks, count: q3Tasks.length }
    const q4: EisenhowerQuadrantData = { quadrant: EisenhowerQuadrant.Q4_NOT_IMPORTANT_NOT_URGENT, tasks: q4Tasks, count: q4Tasks.length }

    return { q1, q2, q3, q4 }
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
      deadlineReminderService.rescheduleAll(this.taskList)

      // 修复：冷启动加载完数据后，主动推送一次卡片
      this.notifyFormUpdate()
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

    // TASK_INFO_UPDATED：RouteVM 修改任务信息 → HomeVM 更新关联任务信息
    this.taskInfoUpdatedCbId = eventBus.on(EventType.TASK_INFO_UPDATED, (payload: Object): void => {
      const p: TaskInfoUpdatedPayload = payload as TaskInfoUpdatedPayload
      this.updateRelatedTaskInfo(p.taskId, p.newTitle, p.newEstimatedTime)
    })

    // TASK_COMPLETION_SYNCED：RouteVM 反向同步任务完成状态 → HomeVM 同步
    this.taskCompletionSyncedCbId = eventBus.on(EventType.TASK_COMPLETION_SYNCED, (payload: Object): void => {
      const p: TaskCompletionSyncedPayload = payload as TaskCompletionSyncedPayload
      this.syncRelatedTaskCompletion(p.taskId, p.completed)
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
      const completedCount: number = this.taskList.filter((t: HomeTodoItem): boolean => t.isCompleted).length
      const unfinishedTasks: Array<HomeTodoItem> = this.taskList.filter((t: HomeTodoItem): boolean => !t.isCompleted)
      const task1Title: string = unfinishedTasks.length > 0 ? unfinishedTasks[0].title : ''
      const task2Title: string = unfinishedTasks.length > 1 ? unfinishedTasks[1].title : ''
      const remainingCount: number = this.taskList.length - completedCount
      const completionRate: number = this.taskList.length > 0
        ? Math.round((completedCount / this.taskList.length) * 100)
        : 0

      const cardData: WidgetCardData = {
        totalCount: this.taskList.length,
        completedCount: completedCount,
        task1Title: task1Title,
        task2Title: task2Title,
        hasTasks: this.taskList.length > 0,
        completionRate: completionRate,
        remainingCount: remainingCount,
        showTask1: task1Title.length > 0,
        showTask2: task2Title.length > 0,
        showDivider: task1Title.length > 0 && task2Title.length > 0,
        showMore: remainingCount > 2,
        showProgress: this.taskList.length > 0,
        showHeaderStats: this.taskList.length > 0
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

  buildSnapshot(): HomeVMSnapshot {
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

  applyCloudSnapshot(cloudData: Record<string, Object>): void {
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
    this.scheduleSave()
  }

  toggleTask(taskId: Id): void {
    if (!taskId) return
    try {
      const task: HomeTodoItem | undefined = this.taskList.find((t: HomeTodoItem): boolean => t.id === taskId)
      if (!task) return
      task.isCompleted = !task.isCompleted
      if (task.isCompleted) {
        if (task.actualCompletionTime === 0) {
          task.actualCompletionTime = Date.now()
        }
      } else {
        task.actualCompletionTime = 0
      }
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
    if (!todo || !isValidHomeTodoItem(todo)) return false
    const exists: boolean = this.taskList.some((t: HomeTodoItem): boolean => t.id === todo.id)
    if (exists) return false
    this.taskList.push(todo)
    deadlineReminderService.scheduleTaskDeadlineReminder(todo)
    this.scheduleSave()
    return true
  }

  deleteTask(taskId: Id): boolean {
    if (!taskId) return false
    try {
      const index: number = this.taskList.findIndex((t: HomeTodoItem): boolean => t.id === taskId)
      if (index < 0) return false
      this.taskList.splice(index, 1)
      deadlineReminderService.cancelTaskDeadlineReminder(taskId)
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

  removeByRelatedGoalId(goalId: Id): void {
    if (!goalId) return
    const initialLength: number = this.taskList.length
    const newList: HomeTodoItem[] = []
    for (let i: number = 0; i < this.taskList.length; i++) {
      if (this.taskList[i].relatedGoalId !== goalId) {
        newList.push(this.taskList[i])
      } else {
        // A3 生命周期联动：级联移除时同步取消该待办的 deadline 提醒
        deadlineReminderService.cancelTaskDeadlineReminder(this.taskList[i].id)
      }
    }
    if (newList.length !== initialLength) {
      this.taskList = newList
      this.scheduleSave()
    }
  }

  removeByRelatedTaskId(taskId: Id): void {
    if (!taskId) return
    const initialLength: number = this.taskList.length
    const newList: HomeTodoItem[] = []
    for (let i: number = 0; i < this.taskList.length; i++) {
      if (this.taskList[i].relatedTaskId !== taskId) {
        newList.push(this.taskList[i])
      } else {
        // A3 生命周期联动：级联移除时同步取消该待办的 deadline 提醒
        deadlineReminderService.cancelTaskDeadlineReminder(this.taskList[i].id)
      }
    }
    if (newList.length !== initialLength) {
      this.taskList = newList
      this.scheduleSave()
    }
  }

  updateRelatedGoalName(goalId: Id, newGoalName: string): void {
    if (!goalId || !newGoalName) return
    let updated: boolean = false
    for (let i: number = 0; i < this.taskList.length; i++) {
      if (this.taskList[i].relatedGoalId === goalId) {
        this.taskList[i].goalName = newGoalName
        updated = true
      }
    }
    if (updated) {
      this.scheduleSave()
    }
  }

  updateRelatedTaskInfo(taskId: Id, newTitle: string, newEstimatedTime: number): void {
    if (!taskId || !newTitle) return
    let updated: boolean = false
    for (let i: number = 0; i < this.taskList.length; i++) {
      if (this.taskList[i].relatedTaskId === taskId) {
        this.taskList[i].title = newTitle
        this.taskList[i].duration = newEstimatedTime.toString() + ' min'
        updated = true
      }
    }
    if (updated) {
      this.scheduleSave()
    }
  }

  syncRelatedTaskCompletion(taskId: Id, completed: boolean): void {
    if (!taskId) return
    let updated: boolean = false
    for (let i: number = 0; i < this.taskList.length; i++) {
      if (this.taskList[i].relatedTaskId === taskId) {
        this.taskList[i].isCompleted = completed
        if (completed) {
          if (this.taskList[i].actualCompletionTime === 0) {
            this.taskList[i].actualCompletionTime = Date.now()
          }
        } else {
          this.taskList[i].actualCompletionTime = 0
        }
        updated = true
      }
    }
    if (updated) {
      this.scheduleSave()
    }
  }

  isTaskInTodo(taskId: Id): boolean {
    if (!taskId) return false
    return this.taskList.some((t: HomeTodoItem): boolean => t.relatedTaskId === taskId)
  }
}

export const homeVM: HomeViewModel = new HomeViewModel()