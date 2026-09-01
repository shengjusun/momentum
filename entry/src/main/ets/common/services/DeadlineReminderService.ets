// 基于 notificationManager 的任务/目标截止日期提醒服务（横幅通知 + 通知栏保留）

import { notificationManager } from '@kit.NotificationKit'
import { Logger } from '../utils/Logger'
import { CommonConstants } from '../constants/CommonConstants'
import { HomeTodoItem, GoalCardItem } from '../../model/Models'
import { WantAgent } from '@kit.AbilityKit'
import { WantAgentFactory } from '../utils/WantAgentFactory'
import { StorageManager } from '../utils/StorageManager'
import { notificationCenterService } from './NotificationCenterService'

/** 提前提醒"已触发"标记的持久化结构（saveData 要求 object 类型，用对象包装 number） */
interface AdvanceMarkRecord {
  value: number
}

/**
 * 截止日期提醒服务单例
 * 通知 ID 基于 taskId/goalId 哈希生成固定值（任务 20000~29999，目标 30000~39999），
 * 同一 ID 多次调度复用同一 notificationId，避免自增溢出；Map 仅用于反向查找日志诊断
 */
class DeadlineReminderService {
  private readonly tag: string = 'DeadlineReminderService'
  private context: Context | null = null
  private isInitialized: boolean = false
  private reminderIdMap: Map<string, number> = new Map()
  private goalReminderIdMap: Map<string, number> = new Map()
  private reverseIdMap: Map<number, string> = new Map()
  private reverseGoalIdMap: Map<number, string> = new Map()
  /** 通知操作串行队列，确保同 ID 的取消严格先于发布，避免 reschedule 异步竞态 */
  private operationChain: Promise<void> = Promise.resolve()

  /** 将通知操作加入串行队列（前一个完成后才执行下一个） */
  private enqueue(op: () => Promise<void>): void {
    this.operationChain = this.operationChain.then(op).catch((e: Error): void => {
      Logger.error(this.tag, 'queued notification op failed: ' + e.message)
    })
  }
  /** 提前提醒时间窗口（5 天），deliveryTime = deadline - 5天 */
  private readonly advanceReminderMillis: number = CommonConstants.REMINDER_ADVANCE_DAYS * CommonConstants.DAY_MILLIS
  /** 提前提醒"已触发"标记前缀，防止兜底立即提醒每日重复打扰 */
  private readonly advanceMarkPrefix: string = 'deadline_advance_reminded_'

  /**
   * 基于 taskId 哈希生成稳定的 notificationId（区间 20000~29999）
   * 同一 taskId 多次调用返回同一 ID，避免自增溢出
   */
  private hashTaskIdToNotificationId(taskId: string): number {
    let hash: number = 0
    for (let i: number = 0; i < taskId.length; i++) {
      // 简单 DJB2 变种哈希，分布均匀且稳定
      hash = (hash * 31 + taskId.charCodeAt(i)) & 0x7FFFFFFF
    }
    return CommonConstants.NOTIFICATION_ID_TASK_BASE + (hash % CommonConstants.NOTIFICATION_ID_TASK_RANGE)
  }

  /**
   * 基于 goalId 哈希生成稳定的 notificationId（区间 30000~39999）
   */
  private hashGoalIdToNotificationId(goalId: string): number {
    let hash: number = 0
    for (let i: number = 0; i < goalId.length; i++) {
      hash = (hash * 31 + goalId.charCodeAt(i)) & 0x7FFFFFFF
    }
    return CommonConstants.NOTIFICATION_ID_GOAL_BASE + (hash % CommonConstants.NOTIFICATION_ID_GOAL_RANGE)
  }

  /**
   * 初始化服务
   * @param context - 应用上下文
   */
  init(context: Context): void {
    if (this.isInitialized) {
      Logger.warn(this.tag, 'already initialized')
      return
    }
    this.context = context
    this.isInitialized = true
    Logger.info(this.tag, 'init success')
  }

  private checkInit(): boolean {
    if (!this.isInitialized || this.context === null) {
      Logger.warn(this.tag, 'not initialized')
      return false
    }
    return true
  }

  /** 读取"提前提醒已触发"标记，返回已触发时的 deadline，未触发返回 0 */
  private loadAdvanceMark(key: string): number {
    if (this.context === null) return 0
    // 满足 ArkTS 强类型约束：对象字面量先赋值给显式接口类型变量
    const fallback: AdvanceMarkRecord = { value: 0 }
    const record: AdvanceMarkRecord = StorageManager.loadDataSync<AdvanceMarkRecord>(
      this.context, key, fallback)
    return record.value
  }

  /** 写入"提前提醒已触发"标记（fire-and-forget，不阻塞提醒调度） */
  private saveAdvanceMark(key: string, deadline: number): void {
    if (this.context === null) return
    // 满足 ArkTS 强类型约束：对象字面量先赋值给显式接口类型变量再传入 object 参数
    const record: AdvanceMarkRecord = { value: deadline }
    StorageManager.saveData(this.context, key, record).catch((e: Error): void => {
      Logger.warn(this.tag, 'saveAdvanceMark failed, key=' + key + ', msg=' + e.message)
    })
  }

  /**
   * 为单个任务设置截止日期提醒
   * 提前 5 天触发：deliveryTime = deadline - 5天；若"提前5天"已过但截止未到则立即触发；
   * 若截止时间已过则不设置提醒
   */
  async scheduleTaskDeadlineReminder(task: HomeTodoItem): Promise<void> {
    if (!this.checkInit()) return
    if (!task || !task.id) {
      Logger.warn(this.tag, 'scheduleTaskDeadlineReminder: invalid task')
      return
    }

    // 已完成的任务不设置提醒
    if (task.isCompleted) {
      Logger.info(this.tag, 'task already completed, skip reminder: ' + task.id)
      return
    }

    // 没有截止日期则不设置提醒
    if (!task.deadline || task.deadline <= 0) {
      Logger.info(this.tag, 'task has no deadline, skip reminder: ' + task.id)
      return
    }

    const now: number = Date.now()
    // 截止日期已过，不设置提醒
    if (task.deadline <= now) {
      Logger.info(this.tag, 'task deadline already passed, skip reminder: ' + task.id)
      return
    }

    // 基于 taskId 哈希生成固定 notificationId（跨进程稳定）
    const notificationId: number = this.hashTaskIdToNotificationId(task.id)

    // 关键修复：无条件按稳定 ID 先取消旧调度再入队发布
    // 旧逻辑依赖内存 reminderIdMap 取消，进程重启后 Map 为空 → 取消落空，
    // 每次启动重新 publish 叠加定时通知（重复通知根因）；取消不存在的 ID 仅记录日志，幂等安全
    this.enqueue((): Promise<void> => {
      return notificationManager.cancel(notificationId).catch((e: Error): void => {
        Logger.info(this.tag, 'pre-publish cancel (may not exist), id=' + notificationId.toString() +
          ', msg=' + e.message)
      })
    })
    this.reminderIdMap.set(task.id, notificationId)
    this.reverseIdMap.set(notificationId, task.id)

    // 提前 5 天触发：若"提前5天"已过但截止未到，立即触发
    const advanceDelivery: number = task.deadline - this.advanceReminderMillis
    let deliveryTime: number
    if (advanceDelivery > now) {
      // 正常情况：在截止前 5 天触发
      deliveryTime = advanceDelivery
      Logger.info(this.tag, 'reminder scheduled at advance-5d, taskId=' + task.id +
        ', advanceDelivery=' + advanceDelivery.toString())
    } else {
      // 防重复打扰：兜底立即触发只对同一 deadline 执行一次
      // （Number() 归一化：防御历史数据 deadline 类型漂移导致严格相等失配、重复立即提醒）
      const markKey: string = this.advanceMarkPrefix + task.id
      const firedDeadline: number = this.loadAdvanceMark(markKey)
      if (Number(firedDeadline) === Number(task.deadline) && firedDeadline > 0) {
        Logger.info(this.tag, 'advance reminder already fired for taskId=' + task.id +
          ', deadline=' + task.deadline.toString() + ', skip')
        return
      }
      // 兜底："提前5天"已过但截止未到，立即触发，并记录已触发标记
      deliveryTime = now
      Logger.info(this.tag, 'reminder fallback to immediate, taskId=' + task.id +
        ', advanceDelivery=' + advanceDelivery.toString() + ' already passed')
    }

    try {
      const content: notificationManager.NotificationContent = {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: this.context!.resourceManager.getStringByNameSync('notif_task_deadline_title'),
          text: task.title + this.context!.resourceManager.getStringByNameSync('notif_task_deadline_text_suffix'),
          additionalText: ''
        }
      }
      // 创建点击通知直达任务详情页的 WantAgent（携带 taskId）
      const taskWantAgent: WantAgent =
        await WantAgentFactory.createTaskDetailWantAgent(this.context!, task.id)
      const request: notificationManager.NotificationRequest = {
        id: notificationId,
        content: content,
        deliveryTime: deliveryTime,
        autoDeletedTime: task.deadline + 24 * 60 * 60 * 1000,
        // 横幅通知：SERVICE_INFORMATION 渠道触发系统顶部横幅展示，横幅消失后留在通知栏
        // 使用 notificationSlotType（API 11+ 推荐字段），类型为 notificationManager.SlotType
        notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
        // 点击通知直达任务详情页（EntryAbility 解析 taskId 后跳转）
        wantAgent: taskWantAgent
      }

      // 发布操作入队，与同 ID 的取消严格串行，消除"先取消再发布"竞态
      this.enqueue((): Promise<void> => {
        return notificationManager.publish(request).then((): void => {
          Logger.info(this.tag, 'reminder scheduled, taskId=' + task.id +
            ', notificationId=' + notificationId.toString() +
            ', deliveryTime=' + deliveryTime.toString() +
            ', deadline=' + task.deadline.toString())
          // 兜底立即触发场景下，发布成功后写入"已提醒"标记，防止每日重复
          if (advanceDelivery <= now) {
            this.saveAdvanceMark(this.advanceMarkPrefix + task.id, task.deadline)
          }
          // 站内通知中心：同步写入任务截止提醒记录（点击直达任务详情）
          notificationCenterService.add(
            'task_deadline',
            this.context!.resourceManager.getStringByNameSync('notif_task_deadline_title'),
            task.title + this.context!.resourceManager.getStringByNameSync('notif_task_deadline_text_suffix'),
            task.id,
            'TaskDetailPage'
          ).catch((e: Error): void => {
            Logger.warn(this.tag, 'notificationCenter add failed, taskId=' + task.id +
              ', msg=' + e.message)
          })
        }).catch((e: Error): void => {
          Logger.error(this.tag, 'publish reminder failed, taskId=' + task.id +
            ', msg=' + e.message)
          this.reminderIdMap.delete(task.id)
          this.reverseIdMap.delete(notificationId)
        })
      })
    } catch (e) {
      const err: Error = e as Error
      Logger.error(this.tag, 'scheduleTaskDeadlineReminder error: ' + err.message)
      this.reminderIdMap.delete(task.id)
      this.reverseIdMap.delete(notificationId)
    }
  }

  /** 取消单个任务的截止日期提醒 */
  cancelTaskDeadlineReminder(taskId: string): void {
    if (!this.checkInit()) return
    if (!taskId) return

    const notificationId: number | undefined = this.reminderIdMap.get(taskId)
    if (notificationId === undefined) {
      Logger.info(this.tag, 'no reminder to cancel for task: ' + taskId)
      return
    }

    // 取消操作入队，与同 ID 的发布严格串行，消除竞态
    const taskIdForLog: string = taskId
    this.enqueue((): Promise<void> => {
      return notificationManager.cancel(notificationId).then((): void => {
        Logger.info(this.tag, 'reminder canceled, taskId=' + taskIdForLog +
          ', notificationId=' + notificationId.toString())
      }).catch((e: Error): void => {
        Logger.error(this.tag, 'cancel reminder failed, taskId=' + taskIdForLog +
          ', msg=' + e.message)
      })
    })

    this.reminderIdMap.delete(taskId)
    this.reverseIdMap.delete(notificationId)
  }

  /** 重新设置所有任务的截止日期提醒（先全部取消再为有效任务重新设置） */
  rescheduleAll(taskList: Array<HomeTodoItem>): void {
    if (!this.checkInit()) return
    if (!Array.isArray(taskList)) {
      Logger.warn(this.tag, 'rescheduleAll: invalid taskList')
      return
    }

    Logger.info(this.tag, 'rescheduleAll start, taskCount=' + taskList.length.toString())

    // 先取消所有现有任务提醒
    this.cancelAllTaskReminders()

    // 为每个有效任务设置提醒
    for (let i: number = 0; i < taskList.length; i++) {
      const task: HomeTodoItem = taskList[i]
      if (task && task.id && !task.isCompleted && task.deadline && task.deadline > Date.now()) {
        this.scheduleTaskDeadlineReminder(task)
      }
    }

    Logger.info(this.tag, 'rescheduleAll done')
  }

  /** 取消所有任务提醒（仅 L4 待办，不影响目标提醒） */
  cancelAllTaskReminders(): void {
    if (!this.checkInit()) return

    const taskIds: string[] = Array.from(this.reminderIdMap.keys())
    Logger.info(this.tag, 'cancelAllTaskReminders, count=' + taskIds.length.toString())

    for (let i: number = 0; i < taskIds.length; i++) {
      const taskId: string = taskIds[i]
      const notificationId: number | undefined = this.reminderIdMap.get(taskId)
      if (notificationId !== undefined) {
        // 取消操作入队，保证与后续发布严格串行
        const taskIdForLog: string = taskId
        this.enqueue((): Promise<void> => {
          return notificationManager.cancel(notificationId).then((): void => {
            Logger.info(this.tag, 'cancelAll task canceled, taskId=' + taskIdForLog +
              ', notificationId=' + notificationId.toString())
          }).catch((e: Error): void => {
            Logger.error(this.tag, 'cancelTask cancel failed, id=' +
              notificationId.toString() + ', msg=' + e.message)
          })
        })
      }
    }

    this.reminderIdMap.clear()
    this.reverseIdMap.clear()
    Logger.info(this.tag, 'cancelAllTaskReminders done')
  }

  /** 取消所有提醒（任务 + 目标） */
  cancelAllReminders(): void {
    if (!this.checkInit()) return
    this.cancelAllTaskReminders()
    this.cancelAllGoalReminders()
  }

  // ===================== L1 目标截止提醒 =====================

  /**
   * 为单个 L1 目标设置截止日期提醒
   * 提醒规则与 L4 任务一致：已完成的跳过，提前 5 天触发，"提前5天"已过则兜底立即触发
   */
  async scheduleGoalDeadlineReminder(goal: GoalCardItem): Promise<void> {
    if (!this.checkInit()) return
    if (!goal || !goal.id) {
      Logger.warn(this.tag, 'scheduleGoalDeadlineReminder: invalid goal')
      return
    }

    // 已完成的目标不设置提醒（progress >= 100 或 actualCompletionTime > 0）
    if (goal.progress >= 100 || goal.actualCompletionTime > 0) {
      Logger.info(this.tag, 'goal already completed, skip reminder: ' + goal.id)
      return
    }

    // 没有截止日期则不设置提醒
    if (!goal.deadline || goal.deadline <= 0) {
      Logger.info(this.tag, 'goal has no deadline, skip reminder: ' + goal.id)
      return
    }

    const now: number = Date.now()
    // 截止日期已过，不设置提醒
    if (goal.deadline <= now) {
      Logger.info(this.tag, 'goal deadline already passed, skip reminder: ' + goal.id)
      return
    }

    // 基于 goalId 哈希生成固定 notificationId（跨进程稳定）
    const notificationId: number = this.hashGoalIdToNotificationId(goal.id)

    // 关键修复：无条件按稳定 ID 先取消旧调度再入队发布（与任务侧一致，跨进程幂等）
    this.enqueue((): Promise<void> => {
      return notificationManager.cancel(notificationId).catch((e: Error): void => {
        Logger.info(this.tag, 'pre-publish goal cancel (may not exist), id=' + notificationId.toString() +
          ', msg=' + e.message)
      })
    })
    this.goalReminderIdMap.set(goal.id, notificationId)
    this.reverseGoalIdMap.set(notificationId, goal.id)

    // 提前 5 天触发 + 兜底立即触发（与 L4 逻辑一致）
    const advanceDelivery: number = goal.deadline - this.advanceReminderMillis
    let deliveryTime: number
    if (advanceDelivery > now) {
      deliveryTime = advanceDelivery
      Logger.info(this.tag, 'goal reminder scheduled at advance-5d, goalId=' + goal.id +
        ', advanceDelivery=' + advanceDelivery.toString())
    } else {
      // 防重复打扰：同一 deadline 的兜底立即触发只执行一次（Number() 归一化防类型漂移）
      const markKey: string = this.advanceMarkPrefix + goal.id
      const firedDeadline: number = this.loadAdvanceMark(markKey)
      if (Number(firedDeadline) === Number(goal.deadline) && firedDeadline > 0) {
        Logger.info(this.tag, 'goal advance reminder already fired, goalId=' + goal.id +
          ', deadline=' + goal.deadline.toString() + ', skip')
        return
      }
      deliveryTime = now
      Logger.info(this.tag, 'goal reminder fallback to immediate, goalId=' + goal.id +
        ', advanceDelivery=' + advanceDelivery.toString() + ' already passed')
    }

    try {
      const content: notificationManager.NotificationContent = {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: this.context!.resourceManager.getStringByNameSync('notif_goal_deadline_title'),
          text: this.context!.resourceManager.getStringByNameSync('notif_goal_deadline_text_prefix') + goal.name + this.context!.resourceManager.getStringByNameSync('notif_goal_deadline_text_suffix'),
          additionalText: ''
        }
      }
      // 创建点击通知直达目标详情页的 WantAgent（携带 goalId）
      const goalWantAgent: WantAgent =
        await WantAgentFactory.createGoalDetailWantAgent(this.context!, goal.id)
      const request: notificationManager.NotificationRequest = {
        id: notificationId,
        content: content,
        deliveryTime: deliveryTime,
        autoDeletedTime: goal.deadline + 24 * 60 * 60 * 1000,
        // 横幅通知：SERVICE_INFORMATION 渠道触发系统顶部横幅展示，横幅消失后留在通知栏
        // 使用 notificationSlotType（API 11+ 推荐字段），类型为 notificationManager.SlotType
        notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
        // 点击通知直达目标详情页（EntryAbility 解析 goalId 后跳转）
        wantAgent: goalWantAgent
      }

      // 发布操作入队，与同 ID 的取消严格串行，消除竞态
      this.enqueue((): Promise<void> => {
        return notificationManager.publish(request).then((): void => {
          Logger.info(this.tag, 'goal reminder scheduled, goalId=' + goal.id +
            ', notificationId=' + notificationId.toString() +
            ', deliveryTime=' + deliveryTime.toString() +
            ', deadline=' + goal.deadline.toString())
          // 兜底立即触发场景下，发布成功后写入"已提醒"标记，防止每日重复
          if (advanceDelivery <= now) {
            this.saveAdvanceMark(this.advanceMarkPrefix + goal.id, goal.deadline)
          }
          // 站内通知中心：同步写入目标截止提醒记录（点击直达目标详情）
          notificationCenterService.add(
            'goal_deadline',
            this.context!.resourceManager.getStringByNameSync('notif_goal_deadline_title'),
            this.context!.resourceManager.getStringByNameSync('notif_goal_deadline_text_prefix') + goal.name + this.context!.resourceManager.getStringByNameSync('notif_goal_deadline_text_suffix'),
            goal.id,
            'GoalDetailPage'
          ).catch((e: Error): void => {
            Logger.warn(this.tag, 'notificationCenter add failed, goalId=' + goal.id +
              ', msg=' + e.message)
          })
        }).catch((e: Error): void => {
          Logger.error(this.tag, 'publish goal reminder failed, goalId=' + goal.id +
            ', msg=' + e.message)
          this.goalReminderIdMap.delete(goal.id)
          this.reverseGoalIdMap.delete(notificationId)
        })
      })
    } catch (e) {
      const err: Error = e as Error
      Logger.error(this.tag, 'scheduleGoalDeadlineReminder error: ' + err.message)
      this.goalReminderIdMap.delete(goal.id)
      this.reverseGoalIdMap.delete(notificationId)
    }
  }

  /** 取消单个目标的截止日期提醒 */
  cancelGoalDeadlineReminder(goalId: string): void {
    if (!this.checkInit()) return
    if (!goalId) return

    const notificationId: number | undefined = this.goalReminderIdMap.get(goalId)
    if (notificationId === undefined) {
      Logger.info(this.tag, 'no goal reminder to cancel for: ' + goalId)
      return
    }

    // 取消操作入队，与同 ID 的发布严格串行，消除竞态
    const goalIdForLog: string = goalId
    this.enqueue((): Promise<void> => {
      return notificationManager.cancel(notificationId).then((): void => {
        Logger.info(this.tag, 'goal reminder canceled, goalId=' + goalIdForLog +
          ', notificationId=' + notificationId.toString())
      }).catch((e: Error): void => {
        Logger.error(this.tag, 'cancel goal reminder failed, goalId=' + goalIdForLog +
          ', msg=' + e.message)
      })
    })

    this.goalReminderIdMap.delete(goalId)
    this.reverseGoalIdMap.delete(notificationId)
  }

  /** 重新设置所有目标的截止日期提醒（先全部取消再为有效目标重新设置） */
  rescheduleAllGoals(goals: Array<GoalCardItem>): void {
    if (!this.checkInit()) return
    if (!Array.isArray(goals)) {
      Logger.warn(this.tag, 'rescheduleAllGoals: invalid goals')
      return
    }

    Logger.info(this.tag, 'rescheduleAllGoals start, goalCount=' + goals.length.toString())

    // 先取消所有现有目标提醒
    this.cancelAllGoalReminders()

    // 为每个有效目标设置提醒
    for (let i: number = 0; i < goals.length; i++) {
      const goal: GoalCardItem = goals[i]
      if (goal && goal.id && goal.progress < 100 &&
          goal.actualCompletionTime === 0 &&
          goal.deadline && goal.deadline > Date.now()) {
        this.scheduleGoalDeadlineReminder(goal)
      }
    }

    Logger.info(this.tag, 'rescheduleAllGoals done')
  }

  /** 取消所有目标提醒（仅 L1 目标，不影响任务提醒） */
  cancelAllGoalReminders(): void {
    if (!this.checkInit()) return

    const goalIds: string[] = Array.from(this.goalReminderIdMap.keys())
    Logger.info(this.tag, 'cancelAllGoalReminders, count=' + goalIds.length.toString())

    for (let i: number = 0; i < goalIds.length; i++) {
      const goalId: string = goalIds[i]
      const notificationId: number | undefined = this.goalReminderIdMap.get(goalId)
      if (notificationId !== undefined) {
        // 取消操作入队，保证与后续发布严格串行
        const goalIdForLog: string = goalId
        this.enqueue((): Promise<void> => {
          return notificationManager.cancel(notificationId).then((): void => {
            Logger.info(this.tag, 'cancelAll goal canceled, goalId=' + goalIdForLog +
              ', notificationId=' + notificationId.toString())
          }).catch((e: Error): void => {
            Logger.error(this.tag, 'cancelGoal cancel failed, id=' +
              notificationId.toString() + ', msg=' + e.message)
          })
        })
      }
    }

    this.goalReminderIdMap.clear()
    this.reverseGoalIdMap.clear()
    Logger.info(this.tag, 'cancelAllGoalReminders done')
  }
}

/**
 * 全局单例导出
 */
export const deadlineReminderService: DeadlineReminderService = new DeadlineReminderService()
