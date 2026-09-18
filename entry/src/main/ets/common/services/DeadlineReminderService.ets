// 任务/目标截止日期提醒服务
// 定时提醒：reminderAgentManager 代理提醒（到点由系统弹出，进程被杀也能触发）
// 立即提醒（提前窗口已过的兜底）：notificationManager 即时通知
// 注意：notificationManager.publish 没有定时能力（deliveryTime 仅是展示时间戳，发布即显示），
//       这是"生成目标后立刻弹出截止提醒"历史 bug 的根因，禁止改回用 publish 调度未来提醒。

import { notificationManager } from '@kit.NotificationKit'
import { reminderAgentManager } from '@kit.BackgroundTasksKit'
import { Logger } from '../utils/Logger'
import { CommonConstants } from '../constants/CommonConstants'
import { HomeTodoItem, GoalCardItem } from '../../model/Models'
import { WantAgent, common } from '@kit.AbilityKit'
import { WantAgentFactory } from '../utils/WantAgentFactory'
import { StorageManager } from '../utils/StorageManager'
import { notificationCenterService } from './NotificationCenterService'

/** 提前提醒"已触发"标记的持久化结构（saveData 要求 object 类型，用对象包装 number） */
interface AdvanceMarkRecord {
  value: number
}

/** 代理提醒 ID 的持久化结构：itemKey（taskId/goalId）→ 系统返回的 reminderId */
interface ReminderIdSnapshot {
  taskIds: Record<string, number>
  goalIds: Record<string, number>
}

/** 代理提醒 ID 持久化存储键 */
const REMINDER_IDS_STORAGE_KEY: string = 'deadline_reminder_ids_v1'

/**
 * 截止日期提醒服务单例
 * - 定时路径走 reminderAgentManager（系统代理，跨重启有效）；
 *   reminderId 由系统分配，持久化保存以支持取消/重排（含进程重启后）
 * - 触发时弹出的通知 ID 基于 taskId/goalId 哈希生成固定值
 *   （任务 20000~29999，目标 30000~39999），同一 item 稳定复用
 */
class DeadlineReminderService {
  private readonly tag: string = 'DeadlineReminderService'
  private context: Context | null = null
  private isInitialized: boolean = false
  /** itemKey → 系统代理提醒 ID（持久化，跨重启有效） */
  private reminderIdMap: Map<string, number> = new Map()
  private goalReminderIdMap: Map<string, number> = new Map()
  /** 通知操作串行队列，确保同 ID 的取消严格先于发布，避免 reschedule 异步竞态 */
  private operationChain: Promise<void> = Promise.resolve()

  /** 将通知操作加入串行队列（前一个完成后才执行下一个） */
  private enqueue(op: () => Promise<void>): void {
    this.operationChain = this.operationChain.then(op).catch((e: Error): void => {
      Logger.error(this.tag, 'queued notification op failed: ' + e.message)
    })
  }
  /** 提前提醒时间窗口：L4 任务默认提前 1 天，L1 目标默认提前 3 天，可由设置页修改 */
  private advanceTaskMillis: number = 1 * CommonConstants.DAY_MILLIS
  private advanceGoalMillis: number = 3 * CommonConstants.DAY_MILLIS
  /** "刚创建"判定窗口：创建后 10 分钟内不做兜底立即提醒（用户刚建完不可能忘） */
  private static readonly JUST_CREATED_WINDOW_MILLIS: number = 10 * 60 * 1000
  /**
   * 单次重排可注册的代理提醒上限（任务 / 目标分开计）
   *
   * 系统对代理提醒有总量限制（API 25 及之前 30 条，API 26+ 64 条），且**到点后用户没点"关闭"
   * 的提醒仍算有效、继续占名额**。任务 + 目标 + 番茄钟后台兜底共享这个额度，
   * 因此按"截止时间最近"截断：排不进额度的不注册（只打日志），
   * 避免整体 publish 失败、或挤掉时间更紧迫的提醒。
   */
  private static readonly TASK_REMINDER_LIMIT: number = 20
  private static readonly GOAL_REMINDER_LIMIT: number = 8
  /** 提醒 ID 映射的持久化节流窗口（见 persistReminderIds 注释） */
  private static readonly PERSIST_DEBOUNCE_MILLIS: number = 300
  /** 本次进程生命周期是否已排过健康自检（rescheduleAll / rescheduleAllGoals 会连续调用两次） */
  private verifyScheduled: boolean = false
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
    // 恢复持久化的代理提醒 ID 映射（进程重启后取消/重排依赖它）
    this.restoreReminderIds()
    Logger.info(this.tag, 'init success')
  }

  private checkInit(): boolean {
    if (!this.isInitialized || this.context === null) {
      Logger.warn(this.tag, 'not initialized')
      return false
    }
    return true
  }

  /**
   * 更新截止提醒提前量（由 SettingsViewModel 在加载与用户修改时调用）
   * 仅更新窗口值；重排由调用方负责（rescheduleAll / rescheduleAllGoals）
   */
  setAdvanceDays(taskDays: number, goalDays: number): void {
    this.advanceTaskMillis = taskDays * CommonConstants.DAY_MILLIS
    this.advanceGoalMillis = goalDays * CommonConstants.DAY_MILLIS
    Logger.info(this.tag, 'setAdvanceDays: task=' + taskDays.toString() +
      'd, goal=' + goalDays.toString() + 'd')
  }

  // ===================== 代理提醒 ID 持久化 =====================

  /** 从存储恢复 itemKey → reminderId 映射（init 时调用） */
  private restoreReminderIds(): void {
    if (this.context === null) return
    const fallback: ReminderIdSnapshot = { taskIds: {}, goalIds: {} }
    const snap: ReminderIdSnapshot = StorageManager.loadDataSync<ReminderIdSnapshot>(
      this.context, REMINDER_IDS_STORAGE_KEY, fallback)
    this.reminderIdMap.clear()
    this.goalReminderIdMap.clear()
    const taskKeys: string[] = Object.keys(snap.taskIds)
    for (let i: number = 0; i < taskKeys.length; i++) {
      this.reminderIdMap.set(taskKeys[i], snap.taskIds[taskKeys[i]])
    }
    const goalKeys: string[] = Object.keys(snap.goalIds)
    for (let i: number = 0; i < goalKeys.length; i++) {
      this.goalReminderIdMap.set(goalKeys[i], snap.goalIds[goalKeys[i]])
    }
    Logger.info(this.tag, 'restoreReminderIds: task=' + taskKeys.length.toString() +
      ', goal=' + goalKeys.length.toString())
  }

  /**
   * 当前映射写入持久化存储（fire-and-forget，300ms 节流合并）
   *
   * 写盘风暴修复：rescheduleAll 会对每个任务触发"取消 1 次 + 注册成功 1 次"共 2 次本方法，
   * 50 任务 ≈ 100 次全量 Map 序列化 + saveData，冷启动时挤占 IO。
   * 改为 300ms 节流：批量期间只落窗口末尾的最终状态（每次全量序列化 → 每窗口 1 次）。
   * 代价：窗口内进程被杀会丢最后一次映射更新 → 下次启动恢复出旧 id，cancel 可能失败（仅日志），
   * 提醒本身会在 rescheduleAll 重排，无实际影响。
   */
  private persistTimer: number = -1

  private persistReminderIds(): void {
    if (this.context === null) return
    if (this.persistTimer !== -1) return
    this.persistTimer = setTimeout((): void => {
      this.persistTimer = -1
      this.doPersistReminderIds()
    }, DeadlineReminderService.PERSIST_DEBOUNCE_MILLIS)
  }

  private doPersistReminderIds(): void {
    if (this.context === null) return
    const snap: ReminderIdSnapshot = { taskIds: {}, goalIds: {} }
    this.reminderIdMap.forEach((id: number, key: string): void => {
      snap.taskIds[key] = id
    })
    this.goalReminderIdMap.forEach((id: number, key: string): void => {
      snap.goalIds[key] = id
    })
    StorageManager.saveData(this.context, REMINDER_IDS_STORAGE_KEY, snap as object)
      .catch((e: Error): void => {
        Logger.warn(this.tag, 'persistReminderIds failed: ' + e.message)
      })
  }

  /** 取消 itemKey 对应的代理提醒（存在才取消），并从映射移除 + 持久化 */
  private cancelAgentReminder(itemKey: string, isGoal: boolean): void {
    const map: Map<string, number> = isGoal ? this.goalReminderIdMap : this.reminderIdMap
    const reminderId: number | undefined = map.get(itemKey)
    if (reminderId === undefined) {
      return
    }
    map.delete(itemKey)
    this.persistReminderIds()
    this.enqueue((): Promise<void> => {
      return reminderAgentManager.cancelReminder(reminderId).then((): void => {
        Logger.info(this.tag, 'agent reminder canceled, key=' + itemKey +
          ', reminderId=' + reminderId.toString())
      }).catch((e: Error): void => {
        // 已过期的提醒系统可能自动移除，取消失败仅记录，不影响后续流程
        Logger.info(this.tag, 'cancel agent reminder (may be gone), key=' + itemKey +
          ', msg=' + e.message)
      })
    })
  }

  /**
   * 构造代理提醒的跳转意图
   * 注意：reminderAgentManager.ReminderRequest.wantAgent 是模块内自定义的简化结构
   * （pkgName/abilityName/parameters），不是 @kit.AbilityKit 的 WantAgent 实例；
   * parameters 与 WantAgentFactory 保持同键（routeName/goalId/taskId），EntryAbility 解析后路由直达
   */
  private buildReminderWantAgent(routeName: string, itemId: string): reminderAgentManager.WantAgent {
    const uiaContext: common.UIAbilityContext = this.context as common.UIAbilityContext
    const isGoal: boolean = routeName === 'GoalDetailPage'
    const params: Record<string, Object> = {}
    params['routeName'] = routeName
    params[isGoal ? 'goalId' : 'taskId'] = itemId
    const want: reminderAgentManager.WantAgent = {
      pkgName: uiaContext.abilityInfo.bundleName,
      abilityName: uiaContext.abilityInfo.name,
      parameters: params
    }
    return want
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
   * 提前 1 天（可设置）由系统代理提醒触发；若"提前窗口"已过但截止未到：
   *   - 刚创建（10 分钟内）的跳过并记标记，避免"建完即被催"
   *   - 其余立即触发（含离线期间跨过窗口的启动补触发）
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

    const notificationId: number = this.hashTaskIdToNotificationId(task.id)
    // 同 item 重排：先取消旧代理提醒（持久化 ID，跨重启幂等），再注册新的
    this.cancelAgentReminder(task.id, false)

    // 提前 N 天触发：若"提前窗口"已过但截止未到，进入兜底逻辑
    const advanceDelivery: number = task.deadline - this.advanceTaskMillis
    let deliveryTime: number
    // 站内通知记录只在"真触发"时写入：未来调度的路径不写，等触发日的启动扫描补写
    let isImmediateFire: boolean = false
    if (advanceDelivery > now) {
      // 正常情况：在截止前 N 天由系统代理提醒触发
      deliveryTime = advanceDelivery
      Logger.info(this.tag, 'agent reminder scheduled at advance, taskId=' + task.id +
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
      // 刚创建（10 分钟内）且截止临近的，跳过立即提醒并记标记
      if (task.createTime > 0 && now - task.createTime < DeadlineReminderService.JUST_CREATED_WINDOW_MILLIS) {
        Logger.info(this.tag, 'task just created, skip immediate reminder: ' + task.id)
        this.saveAdvanceMark(markKey, task.deadline)
        return
      }
      // 兜底：窗口已过（含离线期间跨过窗口的，启动扫描在此补触发），立即触发并记录标记
      deliveryTime = now
      isImmediateFire = true
      Logger.info(this.tag, 'reminder fallback to immediate, taskId=' + task.id +
        ', advanceDelivery=' + advanceDelivery.toString() + ' already passed')
    }

    try {
      const title: string =
        this.context!.resourceManager.getStringByNameSync('notif_task_deadline_title')
      const text: string = task.title +
        this.context!.resourceManager.getStringByNameSync('notif_task_deadline_text_suffix')

      if (isImmediateFire) {
        // 立即触发：notificationManager 即时通知（发布即显示，正是所需语义）
        // 创建点击通知直达任务详情页的 WantAgent（携带 taskId）
        const taskWantAgent: WantAgent =
          await WantAgentFactory.createTaskDetailWantAgent(this.context!, task.id)
        const content: notificationManager.NotificationContent = {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: title,
            text: text,
            additionalText: ''
          }
        }
        const request: notificationManager.NotificationRequest = {
          id: notificationId,
          content: content,
          // 横幅通知：SERVICE_INFORMATION 渠道触发系统顶部横幅展示，横幅消失后留在通知栏
          notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
          // 点击通知直达任务详情页（EntryAbility 解析 taskId 后跳转）
          wantAgent: taskWantAgent
        }
        this.enqueue((): Promise<void> => {
          return notificationManager.publish(request).then((): void => {
            Logger.info(this.tag, 'immediate reminder published, taskId=' + task.id)
            this.saveAdvanceMark(this.advanceMarkPrefix + task.id, task.deadline)
            // 站内通知中心：真触发才写入记录（点击直达任务详情）
            notificationCenterService.add(
              'task_deadline', title, text, task.id, 'TaskDetailPage'
            ).catch((e: Error): void => {
              Logger.warn(this.tag, 'notificationCenter add failed, taskId=' + task.id +
                ', msg=' + e.message)
            })
          }).catch((e: Error): void => {
            Logger.error(this.tag, 'publish immediate reminder failed, taskId=' + task.id +
              ', msg=' + e.message)
          })
        })
      } else {
        // 定时触发：系统代理提醒（进程被杀也到点弹出）
        const d: Date = new Date(deliveryTime)
        const reminder: reminderAgentManager.ReminderRequestCalendar = {
          reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR,
          dateTime: {
            year: d.getFullYear(),
            month: d.getMonth() + 1,
            day: d.getDate(),
            hour: d.getHours(),
            minute: d.getMinutes(),
            second: d.getSeconds()
          },
          title: title,
          content: text,
          notificationId: notificationId,
          slotType: notificationManager.SlotType.SERVICE_INFORMATION,
          wantAgent: this.buildReminderWantAgent('TaskDetailPage', task.id)
        }
        reminderAgentManager.publishReminder(reminder).then((reminderId: number): void => {
          this.reminderIdMap.set(task.id, reminderId)
          this.persistReminderIds()
          Logger.info(this.tag, 'agent reminder scheduled, taskId=' + task.id +
            ', reminderId=' + reminderId.toString() +
            ', deliveryTime=' + deliveryTime.toString())
        }).catch((e: Error): void => {
          Logger.error(this.tag, 'publish agent reminder failed, taskId=' + task.id +
            ', msg=' + e.message)
        })
      }
    } catch (e) {
      const err: Error = e as Error
      Logger.error(this.tag, 'scheduleTaskDeadlineReminder error: ' + err.message)
    }
  }

  /** 取消单个任务的截止日期提醒 */
  cancelTaskDeadlineReminder(taskId: string): void {
    if (!this.checkInit()) return
    if (!taskId) return
    this.cancelAgentReminder(taskId, false)
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

    // 收集有效任务后按截止时间升序排序：额度有限，优先保证最紧急的那些
    const candidates: Array<HomeTodoItem> = []
    for (let i: number = 0; i < taskList.length; i++) {
      const task: HomeTodoItem = taskList[i]
      if (task && task.id && !task.isCompleted && task.deadline && task.deadline > Date.now()) {
        candidates.push(task)
      }
    }
    candidates.sort((a: HomeTodoItem, b: HomeTodoItem): number => a.deadline - b.deadline)

    const limited: Array<HomeTodoItem> = candidates.slice(0, DeadlineReminderService.TASK_REMINDER_LIMIT)
    if (candidates.length > limited.length) {
      Logger.warn(this.tag, 'rescheduleAll: 待办提醒超出额度，按截止时间取最近 ' +
        limited.length.toString() + '/' + candidates.length.toString() + ' 条')
    }

    // 为截断后的任务设置提醒
    for (let i: number = 0; i < limited.length; i++) {
      this.scheduleTaskDeadlineReminder(limited[i])
    }

    Logger.info(this.tag, 'rescheduleAll done, scheduled=' + limited.length.toString())
    this.scheduleVerify()
  }

  /** 取消所有任务提醒（仅 L4 待办，不影响目标提醒） */
  cancelAllTaskReminders(): void {
    if (!this.checkInit()) return

    const taskIds: string[] = Array.from(this.reminderIdMap.keys())
    Logger.info(this.tag, 'cancelAllTaskReminders, count=' + taskIds.length.toString())
    for (let i: number = 0; i < taskIds.length; i++) {
      this.cancelAgentReminder(taskIds[i], false)
    }
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
   * 提醒规则与 L4 任务一致：已完成的跳过，提前 3 天（可设置）代理提醒，
   * "提前窗口"已过则兜底立即触发（刚创建的跳过）
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

    const notificationId: number = this.hashGoalIdToNotificationId(goal.id)
    // 同 item 重排：先取消旧代理提醒（持久化 ID，跨重启幂等），再注册新的
    this.cancelAgentReminder(goal.id, true)

    // 提前 N 天触发 + 兜底立即触发
    const advanceDelivery: number = goal.deadline - this.advanceGoalMillis
    let deliveryTime: number
    // 站内通知记录只在"真触发"时写入：未来调度的路径不写，等触发日的启动扫描补写
    let isImmediateFire: boolean = false
    if (advanceDelivery > now) {
      deliveryTime = advanceDelivery
      Logger.info(this.tag, 'goal agent reminder scheduled at advance, goalId=' + goal.id +
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
      // 刚创建（10 分钟内）且截止临近的，跳过立即提醒并记标记
      if (goal.createTime > 0 && now - goal.createTime < DeadlineReminderService.JUST_CREATED_WINDOW_MILLIS) {
        Logger.info(this.tag, 'goal just created, skip immediate reminder: ' + goal.id)
        this.saveAdvanceMark(markKey, goal.deadline)
        return
      }
      deliveryTime = now
      isImmediateFire = true
      Logger.info(this.tag, 'goal reminder fallback to immediate, goalId=' + goal.id +
        ', advanceDelivery=' + advanceDelivery.toString() + ' already passed')
    }

    try {
      const title: string =
        this.context!.resourceManager.getStringByNameSync('notif_goal_deadline_title')
      const text: string =
        this.context!.resourceManager.getStringByNameSync('notif_goal_deadline_text_prefix') +
        goal.name +
        this.context!.resourceManager.getStringByNameSync('notif_goal_deadline_text_suffix')

      if (isImmediateFire) {
        // 立即触发：notificationManager 即时通知
        // 创建点击通知直达目标详情页的 WantAgent（携带 goalId）
        const goalWantAgent: WantAgent =
          await WantAgentFactory.createGoalDetailWantAgent(this.context!, goal.id)
        const content: notificationManager.NotificationContent = {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: title,
            text: text,
            additionalText: ''
          }
        }
        const request: notificationManager.NotificationRequest = {
          id: notificationId,
          content: content,
          notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
          wantAgent: goalWantAgent
        }
        this.enqueue((): Promise<void> => {
          return notificationManager.publish(request).then((): void => {
            Logger.info(this.tag, 'goal immediate reminder published, goalId=' + goal.id)
            this.saveAdvanceMark(this.advanceMarkPrefix + goal.id, goal.deadline)
            // 站内通知中心：真触发才写入记录（点击直达目标详情）
            notificationCenterService.add(
              'goal_deadline', title, text, goal.id, 'GoalDetailPage'
            ).catch((e: Error): void => {
              Logger.warn(this.tag, 'notificationCenter add failed, goalId=' + goal.id +
                ', msg=' + e.message)
            })
          }).catch((e: Error): void => {
            Logger.error(this.tag, 'publish goal immediate reminder failed, goalId=' + goal.id +
              ', msg=' + e.message)
          })
        })
      } else {
        // 定时触发：系统代理提醒（进程被杀也到点弹出）
        const d: Date = new Date(deliveryTime)
        const reminder: reminderAgentManager.ReminderRequestCalendar = {
          reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR,
          dateTime: {
            year: d.getFullYear(),
            month: d.getMonth() + 1,
            day: d.getDate(),
            hour: d.getHours(),
            minute: d.getMinutes(),
            second: d.getSeconds()
          },
          title: title,
          content: text,
          notificationId: notificationId,
          slotType: notificationManager.SlotType.SERVICE_INFORMATION,
          wantAgent: this.buildReminderWantAgent('GoalDetailPage', goal.id)
        }
        reminderAgentManager.publishReminder(reminder).then((reminderId: number): void => {
          this.goalReminderIdMap.set(goal.id, reminderId)
          this.persistReminderIds()
          Logger.info(this.tag, 'goal agent reminder scheduled, goalId=' + goal.id +
            ', reminderId=' + reminderId.toString() +
            ', deliveryTime=' + deliveryTime.toString())
        }).catch((e: Error): void => {
          Logger.error(this.tag, 'publish goal agent reminder failed, goalId=' + goal.id +
            ', msg=' + e.message)
        })
      }
    } catch (e) {
      const err: Error = e as Error
      Logger.error(this.tag, 'scheduleGoalDeadlineReminder error: ' + err.message)
    }
  }

  /** 取消单个目标的截止日期提醒 */
  cancelGoalDeadlineReminder(goalId: string): void {
    if (!this.checkInit()) return
    if (!goalId) return
    this.cancelAgentReminder(goalId, true)
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

    // 与任务侧同策略：按截止时间升序，额度内取最近的若干条
    const candidates: Array<GoalCardItem> = []
    for (let i: number = 0; i < goals.length; i++) {
      const goal: GoalCardItem = goals[i]
      if (goal && goal.id && goal.progress < 100 &&
          goal.actualCompletionTime === 0 &&
          goal.deadline && goal.deadline > Date.now()) {
        candidates.push(goal)
      }
    }
    candidates.sort((a: GoalCardItem, b: GoalCardItem): number => a.deadline - b.deadline)

    const limited: Array<GoalCardItem> = candidates.slice(0, DeadlineReminderService.GOAL_REMINDER_LIMIT)
    if (candidates.length > limited.length) {
      Logger.warn(this.tag, 'rescheduleAllGoals: 目标提醒超出额度，按截止时间取最近 ' +
        limited.length.toString() + '/' + candidates.length.toString() + ' 条')
    }

    for (let i: number = 0; i < limited.length; i++) {
      this.scheduleGoalDeadlineReminder(limited[i])
    }

    Logger.info(this.tag, 'rescheduleAllGoals done, scheduled=' + limited.length.toString())
    this.scheduleVerify()
  }

  /** 取消所有目标提醒（仅 L1 目标，不影响任务提醒） */
  cancelAllGoalReminders(): void {
    if (!this.checkInit()) return

    const goalIds: string[] = Array.from(this.goalReminderIdMap.keys())
    Logger.info(this.tag, 'cancelAllGoalReminders, count=' + goalIds.length.toString())
    for (let i: number = 0; i < goalIds.length; i++) {
      this.cancelAgentReminder(goalIds[i], true)
    }
  }

  // ===================== 提醒健康自检 =====================

  /**
   * 排一次延迟自检
   * 启动时 rescheduleAll 与 rescheduleAllGoals 会被连续调用（两者内部都会调本方法），
   * 这里做一次性门控 + 延迟 3s，等两轮发布都落定后再去问系统，避免统计到中间态。
   */
  private scheduleVerify(): void {
    if (this.verifyScheduled) return
    this.verifyScheduled = true
    setTimeout((): void => {
      this.verifyReminders()
    }, 3000)
  }

  /**
   * 提醒健康自检：把"本地以为已排期"与"系统侧实际有效"对一次账
   *
   * 存在的意义（代理提醒受管控时它是唯一的可观测手段）：
   *   未在 AGC 申请到「代理提醒」权益的应用，可用提醒数为 0，publishReminder 必然失败
   *   （错误码 1700002 Too Many Reminders）。失败只落在 .catch 日志里，用户侧完全无感知——
   *   表现为"离开应用后不提醒"。这条日志给出事后确认。
   *
   * 另外：到点后用户没点"关闭"的提醒会继续占名额，已过期的会被系统回收，
   *   所以本地映射与系统数量长期会漂移；这里只做日志比对，不擅自改动映射。
   */
  private async verifyReminders(): Promise<void> {
    if (!this.checkInit()) return
    const expectedTask: number = this.reminderIdMap.size
    const expectedGoal: number = this.goalReminderIdMap.size
    const expected: number = expectedTask + expectedGoal
    try {
      const valid: Array<reminderAgentManager.ReminderRequest> =
        await reminderAgentManager.getValidReminders()
      const validCount: number = Array.isArray(valid) ? valid.length : 0
      Logger.info(this.tag, 'verifyReminders: local(task=' + expectedTask.toString() +
        ', goal=' + expectedGoal.toString() + '), systemValid=' + validCount.toString())
      if (expected > 0 && validCount === 0) {
        Logger.warn(this.tag,
          'verifyReminders: 系统侧没有任何有效代理提醒，但本地认为已排期 ' + expected.toString() +
          ' 条 → 代理提醒很可能受管控（未申请"代理提醒"权益），离开应用后不会提醒')
      } else if (validCount < expected) {
        Logger.warn(this.tag, 'verifyReminders: 系统有效提醒少于本地记录，可能有提醒被拒（额度/管控）')
      }
    } catch (e) {
      Logger.warn(this.tag, 'verifyReminders failed: ' + (e as Error).message)
    }
  }

}

/**
 * 全局单例导出
 */
export const deadlineReminderService: DeadlineReminderService = new DeadlineReminderService()
