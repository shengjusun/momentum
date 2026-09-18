/**
 * 番茄钟专注计时服务（单例）
 * 前台 setInterval 计时 + 后台 reminderAgent 兜底（进程被杀也能到点弹通知）+ 完成通知震动
 * 单例保证同一时刻只有一个会话，session 持久化支持冷启动恢复
 */

import { notificationManager } from '@kit.NotificationKit'
import { reminderAgentManager } from '@kit.BackgroundTasksKit'
import { vibrator } from '@kit.SensorServiceKit'
import { WantAgent, common } from '@kit.AbilityKit'
import { resourceManager } from '@kit.LocalizationKit'
import { Logger } from '../utils/Logger'
import { StorageManager } from '../utils/StorageManager'
import { CommonConstants } from '../constants/CommonConstants'
import { WantAgentFactory } from '../utils/WantAgentFactory'
import { PomodoroNotificationService, PomoNotifPhase, PomoNotifStatus } from './PomodoroNotificationService'
import { PomodoroLiveViewService, pomodoroLiveViewService } from './PomodoroLiveViewService'
import { notificationCenterService } from './NotificationCenterService'
import { eventBus, EventType, FocusCompletedPayload } from '../event/AppEventBus'

/** 番茄钟阶段 */
export type PomodoroPhase = 'focus' | 'break'

/** 番茄钟运行状态 */
export type PomodoroState = 'idle' | 'running' | 'paused' | 'completed'

/** 计时回调：剩余毫秒 + 当前阶段 */
export type PomodoroTickCallback = (remainingMillis: number, phase: PomodoroPhase) => void

/** 状态变化回调 */
export type PomodoroStateCallback = (state: PomodoroState, phase: PomodoroPhase) => void

/** 完成回调：本次完成的阶段 */
export type PomodoroCompleteCallback = (phase: PomodoroPhase) => void

/** 沉浸屏可见性变化回调（由 TaskDetailPage 注册，Service 触发） */
export type PomodoroImmersiveVisibleCallback = (visible: boolean) => void

/** 番茄钟统计数据 */
export interface PomodoroStats {
  /** 今日专注次数 */
  todayFocusCount: number
  /** 今日累计专注毫秒 */
  todayFocusMillis: number
  /** 上次专注日期（YYYY-MM-DD，用于跨天重置） */
  lastFocusDate: string
}

/** 番茄钟会话快照（用于 UI 恢复，对外公开） */
export interface PomodoroSessionSnapshot {
  taskId: string
  taskTitle: string
  phase: PomodoroPhase
  state: PomodoroState
  startTime: number
  /** 暂停时累计已计时毫秒（用于恢复） */
  elapsedBeforePause: number
  /** 本轮专注时长（毫秒，用户可自定义） */
  focusDurationMillis: number
  /** 本轮休息时长（毫秒，用户可自定义） */
  breakDurationMillis: number
  /** 长休息时长（毫秒，第 N 轮后使用） */
  longBreakDurationMillis: number
  /** 多少轮专注后进入长休息 */
  cycleLength: number
  /** 已完成的专注轮数（用于 UI 显示"第 N 轮"） */
  completedFocusCount: number
}

/**
 * 番茄钟会话持久化结构
 * 在 PomodoroSessionSnapshot 基础上新增 savedAt，恢复时根据时间差重算已计时时间
 */
export interface PomodoroSessionPersist {
  taskId: string
  taskTitle: string
  phase: PomodoroPhase
  state: PomodoroState
  startTime: number
  elapsedBeforePause: number
  focusDurationMillis: number
  breakDurationMillis: number
  longBreakDurationMillis: number
  cycleLength: number
  completedFocusCount: number
  /** 持久化时刻的墙钟时间戳（用于恢复时计算经过时间） */
  savedAt: number
}

export class PomodoroService {
  private static readonly tag: string = 'PomodoroService'
  private static instance: PomodoroService | null = null

  /** 工作阶段时长（25 分钟） */
  private readonly focusDurationMillis: number = 25 * 60 * 1000
  /** 休息阶段时长（5 分钟） */
  private readonly breakDurationMillis: number = 5 * 60 * 1000
  /** 长休息时长（15 分钟） */
  private readonly longBreakDurationMillis: number = 15 * 60 * 1000
  /** 多少轮专注后进入长休息 */
  private readonly cycleLength: number = 4
  /** 通知 ID 区间起点（与任务提醒 20000+、目标提醒 30000+ 隔离） */
  private readonly notificationIdBase: number = 40000

  private context: Context | null = null
  private isInitialized: boolean = false

  /** 休息结束后是否自动开始下一轮专注（持久化到本地） */
  private autoContinueEnabled: boolean = false

  /** 当前会话快照 */
  private session: PomodoroSessionSnapshot | null = null
  /** 前台计时器 */
  private tickTimer: number = -1
  /** reminderAgent 提醒 ID（退后台兜底） */
  private reminderId: number = -1
  /** 本轮开始时的墙钟时间戳（用于回前台补偿） */
  private roundStartTime: number = 0

  /** 回调注册表（带 ID，支持精确注销单个组件的回调） */
  private tickCallbacks: Map<number, PomodoroTickCallback> = new Map()
  private stateCallbacks: Map<number, PomodoroStateCallback> = new Map()
  private completeCallbacks: Map<number, PomodoroCompleteCallback> = new Map()
  /**
   * 沉浸屏可见性变化回调（多订阅：与 tick/state/complete 同一模式）
   * ⚠️ 曾为「单槽」实现，被后注册的页面覆盖 → 前一份页面状态永远不同步，
   *    表现为"从通知重复进入后，返回一次又看到全屏番茄钟"。不要再改回单槽。
   */
  private immersiveVisibleCallbacks: Map<number, PomodoroImmersiveVisibleCallback> = new Map()
  /** 沉浸屏当前可见状态 */
  private immersiveVisible: boolean = false
  /** 回调 ID 自增计数器 */
  private nextCallbackId: number = 1

  /**
   * 实况窗服务引用（TIMER 场景）—— 与常驻通知**互为备份**：
   * 实况窗创建成功后接管展示，`publishCountdownSafe` 会跳过常驻通知（避免通知中心重复）；
   * 实况窗不可用（未开权益 / 用户关闭 / 内部错误）时自动回退到常驻通知。
   */
  private liveViewService: PomodoroLiveViewService = pomodoroLiveViewService

  /** 通知栏倒计时服务引用（实况窗不可用时的降级方案，所有调用均 fire-and-forget 不阻塞计时） */
  private notificationService: PomodoroNotificationService = PomodoroNotificationService.getInstance()

  private constructor() {}

  static getInstance(): PomodoroService {
    if (PomodoroService.instance === null) {
      PomodoroService.instance = new PomodoroService()
    }
    return PomodoroService.instance
  }

  /**
   * 初始化服务（由 EntryAbility 调用）
   * 异步恢复 session，若运行中则重启计时器 + 发布通知栏倒计时
   */
  init(context: Context): void {
    if (this.isInitialized) {
      Logger.warn(PomodoroService.tag, 'already initialized')
      return
    }
    this.context = context
    this.isInitialized = true
    Logger.info(PomodoroService.tag, 'init success')
    // 异步恢复 session（fire-and-forget，不阻塞 init）
    this.restoreSessionIfNeeded().catch((e: Error): void => {
      Logger.warn(PomodoroService.tag, 'restoreSessionIfNeeded failed: ' + e.message)
    })
    // 异步读取"休息后自动连跑"开关（fire-and-forget）
    StorageManager.getPreferenceBool(CommonConstants.STORAGE_KEY_POMO_AUTO_CONTINUE, false)
      .then((enabled: boolean): void => {
        this.autoContinueEnabled = enabled
        Logger.info(PomodoroService.tag, 'autoContinue loaded: ' + enabled.toString())
      })
      .catch((e: Error): void => {
        Logger.warn(PomodoroService.tag, 'load autoContinue failed: ' + e.message)
      })
  }

  /**
   * 从本地恢复 session
   * running 状态：根据保存时刻与当前时刻差值重算已计时时间，剩余 > 0 恢复计时，否则清除
   * paused 状态：直接恢复，不调整时间
   */
  private async restoreSessionIfNeeded(): Promise<void> {
    if (!this.checkInit()) return
    const persist: PomodoroSessionPersist | null = await this.loadSession()
    if (persist === null) {
      Logger.info(PomodoroService.tag, 'restoreSessionIfNeeded: no persisted session')
      return
    }

    // 构造恢复后的 session（基于持久化数据）
    const session: PomodoroSessionSnapshot = {
      taskId: persist.taskId,
      taskTitle: persist.taskTitle,
      phase: persist.phase,
      state: persist.state,
      startTime: persist.startTime,
      elapsedBeforePause: persist.elapsedBeforePause,
      focusDurationMillis: persist.focusDurationMillis,
      breakDurationMillis: persist.breakDurationMillis,
      longBreakDurationMillis: persist.longBreakDurationMillis,
      cycleLength: persist.cycleLength,
      completedFocusCount: persist.completedFocusCount
    }

    const totalDuration: number = session.phase === 'focus'
      ? session.focusDurationMillis
      : (session.cycleLength > 0 && session.completedFocusCount % session.cycleLength === 0
        ? session.longBreakDurationMillis : session.breakDurationMillis)

    if (session.state === 'running') {
      // 计算保存时刻的 elapsed，再加上保存到现在的差值
      const elapsedAtSave: number = session.elapsedBeforePause + (persist.savedAt - session.startTime)
      const elapsedNow: number = elapsedAtSave + (Date.now() - persist.savedAt)
      const remaining: number = totalDuration - elapsedNow

      if (remaining > 0) {
        // 恢复 running：更新 elapsedBeforePause 为当前实际已计时，重置 roundStartTime
        session.elapsedBeforePause = elapsedNow
        this.session = session
        this.roundStartTime = Date.now()
        this.startTickTimer()
        this.notifyStateChange()
        Logger.info(PomodoroService.tag, 'restoreSessionIfNeeded: running restored, remaining=' +
          remaining.toString() + 'ms')

        // 重新发布通知栏状态通知（实况窗不可用时的兜底；仅状态切换点发布，不按秒刷新）
        this.publishCountdownSafe(this.context!, session.taskId, session.taskTitle,
          session.phase, 'running', totalDuration)
        // 实况窗：进程重启后系统会持久化恢复展示，这里用**真实剩余**接管并校正读数
        this.syncLiveViewSafe(this.context!, session.taskId, session.taskTitle,
          session.phase, remaining, false)
        // 冷启动恢复出来的运行中会话也要有兜底提醒（此后若进程被杀，系统仍能到点提醒）
        this.registerBackgroundReminder()
      } else {
        // 会话已过期：
        // - focus 轮在后台/进程被杀期间到点完成 → 补记统计并触发完成回调，
        //   否则这轮专注彻底蒸发（用户只看到系统通知，应用内统计/轮数全无记录）
        // - break 到点完成 → 无需记录
        if (session.phase === 'focus') {
          Logger.info(PomodoroService.tag,
            'restoreSessionIfNeeded: focus round completed in background, crediting stats')
          await this.incrementFocusStats(session.focusDurationMillis)
          // 专注-任务联动：后台完成的轮次同样累加任务聚焦统计
          const focusPayload: FocusCompletedPayload = {
            taskId: session.taskId,
            focusMillis: session.focusDurationMillis
          }
          eventBus.emit(EventType.FOCUS_COMPLETED, focusPayload as Object)
          this.completeCallbacks.forEach((cb: PomodoroCompleteCallback): void => {
            cb(session.phase)
          })
        }
        // 会话在后台已结束：系统恢复出来的实况窗必须立即清掉，否则会一直显示旧倒计时
        this.endLiveViewSafe()
        await this.clearSession()
      }
    } else if (session.state === 'paused') {
      const remaining: number = totalDuration - session.elapsedBeforePause
      if (remaining > 0) {
        this.session = session
        this.notifyStateChange()
        Logger.info(PomodoroService.tag, 'restoreSessionIfNeeded: paused restored, remaining=' +
          remaining.toString() + 'ms')

        // 重新发布通知栏状态通知（显示"已暂停 + 剩余时长"）
        this.publishCountdownSafe(this.context!, session.taskId, session.taskTitle,
          session.phase, 'paused', remaining)
        // 实况窗：恢复为暂停态
        this.syncLiveViewSafe(this.context!, session.taskId, session.taskTitle,
          session.phase, remaining, true)
      } else {
        Logger.info(PomodoroService.tag, 'restoreSessionIfNeeded: paused session expired, discard')
        this.endLiveViewSafe()
        await this.clearSession()
      }
    }
  }

  private checkInit(): boolean {
    if (!this.isInitialized || this.context === null) {
      Logger.warn(PomodoroService.tag, 'not initialized')
      return false
    }
    return true
  }

  // 回调注册

  /**
   * 注册计时回调（每秒触发，仅前台有效）
   * 支持多组件同时订阅
   * @returns 回调 ID，用于注销时调用 offTick
   */
  onTick(cb: PomodoroTickCallback): number {
    const id: number = this.nextCallbackId++
    this.tickCallbacks.set(id, cb)
    return id
  }

  /**
   * 注销计时回调
   */
  offTick(id: number): void {
    this.tickCallbacks.delete(id)
  }

  /**
   * 注册状态变化回调（支持多组件同时订阅）
   * @returns 回调 ID
   */
  onStateChange(cb: PomodoroStateCallback): number {
    const id: number = this.nextCallbackId++
    this.stateCallbacks.set(id, cb)
    return id
  }

  /**
   * 注销状态变化回调
   */
  offStateChange(id: number): void {
    this.stateCallbacks.delete(id)
  }

  /**
   * 注册完成回调（支持多组件同时订阅）
   * @returns 回调 ID
   */
  onComplete(cb: PomodoroCompleteCallback): number {
    const id: number = this.nextCallbackId++
    this.completeCallbacks.set(id, cb)
    return id
  }

  /**
   * 注销完成回调
   */
  offComplete(id: number): void {
    this.completeCallbacks.delete(id)
  }

  /**
   * 显示沉浸屏（由 TimerCard / 通知直达调用）
   */
  showImmersive(): void {
    this.immersiveVisible = true
    this.immersiveVisibleCallbacks.forEach((cb: PomodoroImmersiveVisibleCallback): void => {
      cb(true)
    })
  }

  /**
   * 隐藏沉浸屏（由 ImmersiveScreen 的 X / 返回手势、TimerCard 停止时调用）
   */
  hideImmersive(): void {
    this.immersiveVisible = false
    this.immersiveVisibleCallbacks.forEach((cb: PomodoroImmersiveVisibleCallback): void => {
      cb(false)
    })
  }

  /**
   * 获取沉浸屏当前可见状态
   */
  isImmersiveVisible(): boolean {
    return this.immersiveVisible
  }

  /**
   * 注册沉浸屏可见性变化回调（支持多组件同时订阅）
   * @returns 回调 ID，注销时传给 offImmersiveVisibleChange
   */
  onImmersiveVisibleChange(cb: PomodoroImmersiveVisibleCallback): number {
    const id: number = this.nextCallbackId++
    this.immersiveVisibleCallbacks.set(id, cb)
    return id
  }

  /**
   * 注销沉浸屏可见性变化回调（页面 aboutToDisappear 时调用）
   */
  offImmersiveVisibleChange(id: number): void {
    this.immersiveVisibleCallbacks.delete(id)
  }

  /**
   * 清除所有回调（应用销毁时调用）
   */
  clearCallbacks(): void {
    this.tickCallbacks.clear()
    this.stateCallbacks.clear()
    this.completeCallbacks.clear()
    this.immersiveVisibleCallbacks.clear()
  }

  // 核心控制

  /**
   * 开始一轮专注（工作阶段）
   * - 若当前已有运行中的会话，先停止
   * - 单例保证同一时刻只有一个会话
   *
   * @param taskId - 关联任务 ID（用于完成通知点击直达）
   * @param taskTitle - 任务标题（用于通知文案）
   * @param focusMinutes - 专注时长（分钟），默认 25
   * @param breakMinutes - 休息时长（分钟），默认 5
   */
  startFocus(taskId: string, taskTitle: string,
             focusMinutes: number = 25, breakMinutes: number = 5,
             longBreakMinutes: number = 15, cycleLen: number = 4): void {
    if (!this.checkInit()) return
    if (!taskId || taskId.length === 0) {
      Logger.warn(PomodoroService.tag, 'startFocus: invalid taskId')
      return
    }

    // 首次专注场景补一次系统通知授权引导：未授权时完成通知/后台提醒会静默失败
    // fire-and-forget，内部已兜底 catch，不阻断计时主流程
    this.ensureNotificationEnabled()

    let completedFocusCount: number = 0
    if (this.session !== null) {
      completedFocusCount = this.session.completedFocusCount
      this.stopInternal(false)
    }

    const focusMillis: number = Math.max(1, focusMinutes) * 60 * 1000
    const breakMillis: number = Math.max(1, breakMinutes) * 60 * 1000
    const longBreakMillis: number = Math.max(1, longBreakMinutes) * 60 * 1000
    const cl: number = Math.max(1, cycleLen)

    this.session = {
      taskId: taskId,
      taskTitle: taskTitle,
      phase: 'focus',
      state: 'running',
      startTime: Date.now(),
      elapsedBeforePause: 0,
      focusDurationMillis: focusMillis,
      breakDurationMillis: breakMillis,
      longBreakDurationMillis: longBreakMillis,
      cycleLength: cl,
      completedFocusCount: completedFocusCount
    }
    this.roundStartTime = this.session.startTime

    this.startTickTimer()
    this.notifyStateChange()
    Logger.info(PomodoroService.tag, 'startFocus: taskId=' + taskId +
      ', focusMin=' + focusMinutes.toString() +
      ', breakMin=' + breakMinutes.toString() +
      ', longBreakMin=' + longBreakMinutes.toString() +
      ', cycle=' + cl.toString())

    this.publishCountdownSafe(this.context!, taskId, taskTitle, 'focus', 'running', focusMillis)
    // 实况窗：开始专注 → 倒计时由**系统计时器**驱动（应用不按秒刷新）
    this.syncLiveViewSafe(this.context!, taskId, taskTitle, 'focus', focusMillis, false)
    // 阶段一开始就注册后台兜底：进程在前台被回收 / 崩溃时不会触发 onBackground，
    // 只靠 onBackground 注册会完全没有提醒（详见 registerBackgroundReminder 注释）
    this.registerBackgroundReminder()
    this.saveSession()
  }

  /**
   * 系统通知授权引导（首次专注时触发）
   * 已授权则静默返回；未授权触发系统弹窗；API 异常仅记日志，不影响专注计时
   */
  private async ensureNotificationEnabled(): Promise<void> {
    try {
      const enabled: boolean = await notificationManager.isNotificationEnabled()
      if (enabled) {
        return
      }
      await notificationManager.requestEnableNotification()
      Logger.info(PomodoroService.tag, 'ensureNotificationEnabled: request dialog shown')
    } catch (e) {
      Logger.warn(PomodoroService.tag, 'ensureNotificationEnabled failed: ' + (e as Error).message)
    }
  }

  /**
   * 开始休息阶段（专注完成后自动调用，或用户手动跳过专注后调用）
   */
  startBreak(): void {
    if (!this.checkInit()) return
    if (this.session === null) {
      Logger.warn(PomodoroService.tag, 'startBreak: no session')
      return
    }

    const taskId: string = this.session.taskId
    const taskTitle: string = this.session.taskTitle
    const focusMillis: number = this.session.focusDurationMillis
    const breakMillis: number = this.session.breakDurationMillis
    const longBreakMillis: number = this.session.longBreakDurationMillis
    const cycleLen: number = this.session.cycleLength
    const completedCount: number = this.session.completedFocusCount

    this.stopInternal(false)

    const isLongBreak: boolean = cycleLen > 0 && completedCount % cycleLen === 0
    const actualBreakMillis: number = isLongBreak ? longBreakMillis : breakMillis

    this.session = {
      taskId: taskId,
      taskTitle: taskTitle,
      phase: 'break',
      state: 'running',
      startTime: Date.now(),
      elapsedBeforePause: 0,
      focusDurationMillis: focusMillis,
      breakDurationMillis: breakMillis,
      longBreakDurationMillis: longBreakMillis,
      cycleLength: cycleLen,
      completedFocusCount: completedCount
    }
    this.roundStartTime = this.session.startTime

    this.startTickTimer()
    this.notifyStateChange()
    Logger.info(PomodoroService.tag, 'startBreak: breakMillis=' + actualBreakMillis.toString() +
      ', isLongBreak=' + isLongBreak.toString() +
      ', round=' + completedCount.toString() + '/' + cycleLen.toString())

    this.publishCountdownSafe(this.context!, taskId, taskTitle, 'break', 'running', actualBreakMillis)
    // 实况窗：同一实况窗内换阶段（只 update —— 规范只在"终止计时"时才结束，
    // 且 stop 后立刻以同 id 重建会撞留存期）
    this.syncLiveViewSafe(this.context!, taskId, taskTitle, 'break', actualBreakMillis, false)
    // 休息阶段同样注册兜底（stopInternal 已取消上一轮的提醒，此处补新的）
    this.registerBackgroundReminder()
    this.saveSession()
  }

  /**
   * 查询"休息后自动开始下一轮"开关状态（UI 同步读取用）
   */
  isAutoContinueEnabled(): boolean {
    return this.autoContinueEnabled
  }

  /**
   * 设置"休息后自动开始下一轮"开关
   * - 立即生效（影响后续 break 完成时的流转）
   * - 异步持久化，失败仅记录日志，不影响本次会话
   */
  setAutoContinueEnabled(enabled: boolean): void {
    if (this.autoContinueEnabled === enabled) return
    this.autoContinueEnabled = enabled
    Logger.info(PomodoroService.tag, 'setAutoContinueEnabled: ' + enabled.toString())
    if (!this.checkInit()) return
    StorageManager.setPreferenceBool(CommonConstants.STORAGE_KEY_POMO_AUTO_CONTINUE, enabled)
      .catch((e: Error): void => {
        Logger.warn(PomodoroService.tag, 'persist autoContinue failed: ' + e.message)
      })
  }

  /**
   * 暂停计时
   */
  pause(): void {
    if (this.session === null || this.session.state !== 'running') {
      Logger.warn(PomodoroService.tag, 'pause: no running session')
      return
    }
    const elapsed: number = Date.now() - this.roundStartTime
    this.session.elapsedBeforePause += elapsed
    this.session.state = 'paused'
    this.stopTickTimer()
    this.cancelReminder()
    this.notifyStateChange()
    Logger.info(PomodoroService.tag, 'pause: elapsed=' + this.session.elapsedBeforePause.toString())

    // 更新通知栏为"已暂停 + 剩余时长"
    const remaining: number = this.getCurrentRemainingMillis()
    this.publishCountdownSafe(this.context!, this.session.taskId, this.session.taskTitle,
      this.session.phase, 'paused', remaining)
    // 实况窗：置暂停（辅助区显示「已暂停」，系统计时器停在当前秒）
    this.syncLiveViewSafe(this.context!, this.session.taskId, this.session.taskTitle,
      this.session.phase, remaining, true)
    //持久化 session（paused 状态）
    this.saveSession()
  }

  /**
   * 恢复计时
   */
  resume(): void {
    if (this.session === null || this.session.state !== 'paused') {
      Logger.warn(PomodoroService.tag, 'resume: no paused session')
      return
    }
    this.session.state = 'running'
    this.roundStartTime = Date.now()
    this.startTickTimer()
    this.notifyStateChange()
    Logger.info(PomodoroService.tag, 'resume')

    // 恢复通知栏：回到"专注中/休息中 + 本次时长"（用总时长而非剩余，避免通知里的数字看起来卡住）
    const total: number = this.session.phase === 'focus'
      ? this.session.focusDurationMillis
      : this.getActualBreakDuration()
    this.publishCountdownSafe(this.context!, this.session.taskId, this.session.taskTitle,
      this.session.phase, 'running', total)
    // 实况窗恢复：传**剩余量**（不是 total）—— 倒计时必须从真实剩余继续，否则会跳回满值
    this.syncLiveViewSafe(this.context!, this.session.taskId, this.session.taskTitle,
      this.session.phase, this.getCurrentRemainingMillis(), false)
    // pause 会取消后台提醒，恢复计时必须补回来，否则再次退后台就没有兜底了
    this.registerBackgroundReminder()
    //持久化 session（running 状态）
    this.saveSession()
  }

  /**
   * 停止并清除当前会话（不触发完成回调）
   * 放弃专注时：已专注满 1 分钟的部分时长计入今日专注时长（不计轮次，不触发任务联动）
   */
  stop(): void {
    if (this.session !== null && this.session.phase === 'focus') {
      const elapsed: number = this.session.elapsedBeforePause + (Date.now() - this.roundStartTime)
      const partialMinutes: number = Math.floor(elapsed / 60000)
      if (partialMinutes >= 1) {
        this.addPartialFocusMillis(partialMinutes * 60000)
      }
    }
    this.stopInternal(true)
    // 用户主动终止 → 规范要求"立即结束实况窗"（不留存占位）
    this.endLiveViewSafe()
  }

  /** 仅累加专注时长（不记轮次）：放弃专注时的部分时长记录 */
  private async addPartialFocusMillis(millis: number): Promise<void> {
    if (!this.checkInit()) return
    try {
      const stats: PomodoroStats = await this.loadStats()
      stats.todayFocusMillis += millis
      stats.lastFocusDate = this.formatDate(Date.now())
      await StorageManager.saveData(
        this.context!, CommonConstants.STORAGE_KEY_POMODORO_STATS, stats)
      Logger.info(PomodoroService.tag, 'addPartialFocusMillis: +' + millis.toString() + 'ms')
    } catch (e) {
      Logger.error(PomodoroService.tag, 'addPartialFocusMillis failed: ' + (e as Error).message)
    }
  }

  /**
   * 停止内部实现
   * @param notifyState - 是否通知状态变化（停止时通知 idle，完成时不通知）
   */
  private stopInternal(notifyState: boolean): void {
    this.stopTickTimer()
    this.cancelReminder()
    if (this.session !== null) {
      Logger.info(PomodoroService.tag, 'stopInternal: taskId=' + this.session.taskId +
        ', phase=' + this.session.phase)
    }
    this.session = null
    // 停止通知栏倒计时（无论 notifyState 值，停止和阶段切换都需要取消）
    this.cancelCountdownSafe()
    //清除持久化的 session
    this.clearSession().catch((e: Error): void => {
      Logger.warn(PomodoroService.tag, 'clearSession failed: ' + e.message)
    })
    if (notifyState) {
      this.notifyStateChange()
    }
  }

  // 计时驱动

  /**
   * 启动前台 setInterval 计时器
   */
  private startTickTimer(): void {
    if (this.tickTimer !== -1) {
      clearInterval(this.tickTimer)
    }
    this.tickTimer = setInterval((): void => {
      this.onTickInternal()
    }, 1000) as number
  }

  /**
   * 停止前台计时器
   */
  private stopTickTimer(): void {
    if (this.tickTimer !== -1) {
      clearInterval(this.tickTimer)
      this.tickTimer = -1
    }
  }

  /**
   * 每秒触发：计算剩余时间，触发回调，检测完成
   */
  private onTickInternal(): void {
    if (this.session === null || this.session.state !== 'running') {
      return
    }
    const totalElapsed: number = this.session.elapsedBeforePause + (Date.now() - this.roundStartTime)
    const totalDuration: number = this.session.phase === 'focus'
      ? this.session.focusDurationMillis
      : this.getActualBreakDuration()
    const remaining: number = totalDuration - totalElapsed

    if (remaining <= 0) {
      this.onPhaseComplete()
      return
    }

    // 缓存 phase 到局部变量（避免闭包内访问 this.session 的 null 检查）
    const currentPhase: PomodoroPhase = this.session.phase
    // 遍历所有 tick 回调（支持 TimerCard + ImmersiveScreen 同时更新）
    this.tickCallbacks.forEach((cb: PomodoroTickCallback): void => {
      cb(remaining, currentPhase)
    })

    // ⚠️ 此处【禁止】刷新通知栏：BASIC_TEXT 通知每次 publish 都会重新弹横幅，
    //    曾经在这里每秒调一次 updateCountdown，导致一次 25 分钟专注弹约 1500 条横幅。
    //    通知只在状态切换点更新（见 pause/resume/startFocus/startBreak），倒计时以应用内界面为准。
  }

  /**
   * 当前阶段完成处理
   * - focus 完成 → 累加统计 + 通知 + 震动 + 自动启动 break
   * - break 完成 → 通知 + 震动 + 清除会话回到 idle
   */
  private onPhaseComplete(): void {
    if (this.session === null) return
    const completedPhase: PomodoroPhase = this.session.phase
    Logger.info(PomodoroService.tag, 'onPhaseComplete: phase=' + completedPhase)

    this.stopTickTimer()
    this.cancelReminder()

    if (completedPhase === 'focus') {
      // 专注完成：累加轮数 + 统计 + 通知 + 震动
      this.session.completedFocusCount += 1
      this.incrementFocusStats()
      // 专注-任务联动：通知 HomeViewModel 累加该任务的聚焦统计（focusCount/focusMillis）
      const focusPayload: FocusCompletedPayload = {
        taskId: this.session.taskId,
        focusMillis: this.session.focusDurationMillis
      }
      eventBus.emit(EventType.FOCUS_COMPLETED, focusPayload as Object)
      this.publishCompleteNotification(true)
      this.vibrate()

      // 遍历所有完成回调
      this.completeCallbacks.forEach((cb: PomodoroCompleteCallback): void => {
        cb(completedPhase)
      })

      // 自动流转到休息阶段
      this.startBreak()
    } else {
      // 休息完成：通知 + 震动
      this.publishCompleteNotification(false)
      this.vibrate()

      this.completeCallbacks.forEach((cb: PomodoroCompleteCallback): void => {
        cb(completedPhase)
      })

      if (this.autoContinueEnabled) {
        const taskId: string = this.session.taskId
        const taskTitle: string = this.session.taskTitle
        const focusMinutes: number = this.session.focusDurationMillis / 60000
        const breakMinutes: number = this.session.breakDurationMillis / 60000
        const longBreakMinutes: number = this.session.longBreakDurationMillis / 60000
        const cl: number = this.session.cycleLength
        Logger.info(PomodoroService.tag, 'onPhaseComplete: auto continue next focus, taskId=' + taskId)
        this.startFocus(taskId, taskTitle, focusMinutes, breakMinutes, longBreakMinutes, cl)
      } else {
        // 休息结束 → 清除会话，回到 idle（用户需手动开始下一轮）
        this.session = null
        this.notifyStateChange()
        // 会话终结 → 立即结束实况窗（规范：终止计时须立即结束）
        this.endLiveViewSafe()
      }
    }
  }

  // 后台兜底：reminderAgent

  /**
   * 后台兜底提醒的触发延迟（毫秒）
   *
   * 为什么不"到点即触发"：
   *   本方法现在会在【阶段开始 / 恢复 / 退后台】三处注册，而应用在前台时前台计时器到点
   *   会自己发完成通知并 cancelReminder()。留 5s 余量，让前台的取消稳稳落在系统触发
   *   之前，避免"前台 + 代理"同一时刻双通知。
   *   而应用被冻结/被杀时前台计时器根本不会跑（那正是需要兜底的场景），
   *   晚 5s 弹出对用户无感知。
   */
  private static readonly BG_REMINDER_LEAD_MILLIS: number = 5000

  /**
   * 注册后台兜底提醒
   *
   * 调用时机（三处，缺一不可）：
   *   ① startFocus / startBreak —— 阶段一开始就注册。
   *      这是"进程在前台被系统回收 / 应用崩溃"场景的唯一兜底：那两条路径不会触发
   *      onBackground，只靠 onBackground 注册会静默地没有任何提醒。
   *   ② resume —— pause 会 cancel，恢复必须补回来。
   *   ③ EntryAbility.onBackground —— 常规退后台。
   *
   * 幂等：注册前先取消旧提醒，避免重复注册在系统侧堆出多条。
   *
   * ⚠️ 代理提醒在手机/平板上是【受管控能力】：未在 AGC 申请到"代理提醒"权益时，
   *    可用提醒数为 0，publishReminder 必然失败（错误码 1700002 Too Many Reminders）。
   *    这里失败只打日志、不抛异常，用户侧表现为"离开应用后不提醒"。
   */
  registerBackgroundReminder(): void {
    if (this.session === null || this.session.state !== 'running') {
      Logger.info(PomodoroService.tag, 'registerBackgroundReminder: no running session, skip')
      return
    }
    if (!this.checkInit()) return
    // 与 publishCompleteNotification 的开关语义保持一致：通知关掉就不做后台兜底
    if (!this.notificationFeedbackEnabled) {
      Logger.info(PomodoroService.tag, 'registerBackgroundReminder skipped: notification disabled')
      return
    }

    const totalElapsed: number = this.session.elapsedBeforePause + (Date.now() - this.roundStartTime)
    const totalDuration: number = this.session.phase === 'focus'
      ? this.session.focusDurationMillis
      : this.getActualBreakDuration()
    const remaining: number = totalDuration - totalElapsed
    if (remaining <= 0) {
      return
    }

    const isFocus: boolean = this.session.phase === 'focus'
    // 幂等：先取消旧提醒再注册（cancelReminder 内部会把 reminderId 置回 -1）
    this.cancelReminder()

    const triggerTime: number = Date.now() + remaining + PomodoroService.BG_REMINDER_LEAD_MILLIS
    // 文案走资源 key：原来这里硬编码中文，英文设备上会整条看到中文
    const rm: resourceManager.ResourceManager = this.context!.resourceManager
    const title: string = rm.getStringSync(isFocus
      ? $r('app.string.pomo_notif_complete_focus_title').id
      : $r('app.string.pomo_notif_complete_break_title').id)
    const text: string = isFocus
      ? rm.getStringSync($r('app.string.pomo_notif_complete_focus_text').id)
        .replace('%s', this.session.taskTitle)
      : rm.getStringSync($r('app.string.pomo_notif_complete_break_text').id)

    try {
      const d: Date = new Date(triggerTime)
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
        // 刻意复用倒计时通知的 ID（专注 base+0 / 休息 base+1）而不是完成通知的 base+2/+3：
        // 到点后由代理提醒【覆盖】通知栏里那条已经过时的「🍅 专注中」，
        // 用户只看到一条「专注完成」，而不是「专注中」+「专注完成」叠成两条。
        notificationId: this.notificationIdBase + (isFocus ? 0 : 1),
        slotType: notificationManager.SlotType.SERVICE_INFORMATION,
        // 点击提醒直达对应任务详情（原来没带 wantAgent，点了只会拉起首页）并恢复全屏番茄钟
        wantAgent: this.buildReminderWantAgent(this.session.taskId)
      }
      reminderAgentManager.publishReminder(reminder).then((id: number): void => {
        this.reminderId = id
        Logger.info(PomodoroService.tag, 'registerBackgroundReminder: id=' + id.toString() +
          ', triggerAt=' + triggerTime.toString() +
          ', phase=' + (isFocus ? 'focus' : 'break'))
      }).catch((e: Error): void => {
        // 受管控（1700002）也会走到这里；配合 DeadlineReminderService.verifyReminders 定位
        Logger.warn(PomodoroService.tag, 'registerBackgroundReminder failed: ' + e.message)
      })
    } catch (e) {
      Logger.warn(PomodoroService.tag, 'registerBackgroundReminder error: ' + (e as Error).message)
    }
  }

  /**
   * 构造代理提醒的跳转意图
   *
   * 注意：reminderAgentManager.WantAgent 是本模块内自定义的简化结构
   * （pkgName / abilityName / parameters），不是 @kit.AbilityKit 的 WantAgent 实例。
   * parameters 与 WantAgentFactory 保持同键（routeName / taskId），
   * 并带 openImmersive='1' —— EntryAbility 解析后除跳转外还会恢复全屏番茄钟，
   * 与倒计时通知的点击行为完全一致。
   */
  private buildReminderWantAgent(taskId: string): reminderAgentManager.WantAgent {
    const uiaContext: common.UIAbilityContext = this.context as common.UIAbilityContext
    const params: Record<string, Object> = {}
    params['routeName'] = 'TaskDetailPage'
    params['taskId'] = taskId
    params['openImmersive'] = '1'
    const want: reminderAgentManager.WantAgent = {
      pkgName: uiaContext.abilityInfo.bundleName,
      abilityName: uiaContext.abilityInfo.name,
      parameters: params
    }
    return want
  }

  /**
   * 显式取消后台兜底提醒（对外公开）
   *
   * ⚠️ 不要再接回 EntryAbility.onForeground：回前台必须保留兜底提醒，
   *    否则"前台运行期间进程被回收/崩溃"就完全没有提醒了（见 onForeground 注释）。
   *    目前无调用方，保留作为需要主动拆除兜底时的出口。
   */
  cancelBackgroundReminder(): void {
    this.cancelReminder()
  }

  /**
   * 取消后台提醒（回前台或停止时调用）
   */
  private cancelReminder(): void {
    if (this.reminderId === -1) return
    try {
      reminderAgentManager.cancelReminder(this.reminderId).then((): void => {
        Logger.info(PomodoroService.tag, 'cancelReminder: id=' + this.reminderId.toString())
      }).catch((e: Error): void => {
        Logger.warn(PomodoroService.tag, 'cancelReminder failed: ' + e.message)
      })
    } catch (e) {
      Logger.warn(PomodoroService.tag, 'cancelReminder error: ' + (e as Error).message)
    }
    this.reminderId = -1
  }

  // 完成通知 + 震动

  /**
   * 发布完成通知（横幅 + 通知栏）
   * @param isFocus - true=专注完成，false=休息结束
   */
  private async publishCompleteNotification(isFocus: boolean): Promise<void> {
    if (!this.checkInit()) return
    if (this.session === null) return
    // 受设置"通知权限"开关控制：关闭后不弹系统横幅也不写站内记录
    if (!this.notificationFeedbackEnabled) {
      Logger.info(PomodoroService.tag, 'publishCompleteNotification skipped: disabled by settings')
      return
    }

    try {
      const rm: resourceManager.ResourceManager = this.context!.resourceManager
      const titleRes: Resource = isFocus
        ? $r('app.string.pomo_notif_complete_focus_title')
        : $r('app.string.pomo_notif_complete_break_title')
      const title: string = rm.getStringSync(titleRes.id)
      const text: string = isFocus
        ? rm.getStringSync($r('app.string.pomo_notif_complete_focus_text').id)
          .replace('%s', this.session.taskTitle)
        : rm.getStringSync($r('app.string.pomo_notif_complete_break_text').id)

      const content: notificationManager.NotificationContent = {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: title,
          text: text,
          additionalText: ''
        }
      }

      // 点击通知直达任务详情页
      const wantAgentObj: WantAgent =
        await WantAgentFactory.createTaskDetailWantAgent(this.context!, this.session.taskId)

      const request: notificationManager.NotificationRequest = {
        id: this.notificationIdBase + (isFocus ? 2 : 3),
        content: content,
        notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
        wantAgent: wantAgentObj
      }

      await notificationManager.publish(request)
      Logger.info(PomodoroService.tag, 'publishCompleteNotification: isFocus=' + isFocus.toString())
      // 站内通知中心：同步写入番茄钟完成记录（点击直达任务详情）
      notificationCenterService.add(
        'pomodoro',
        title,
        text,
        this.session.taskId,
        'TaskDetailPage'
      ).catch((e: Error): void => {
        Logger.warn(PomodoroService.tag, 'notificationCenter add failed: ' + e.message)
      })
    } catch (e) {
      Logger.error(PomodoroService.tag, 'publishCompleteNotification failed: ' + (e as Error).message)
    }
  }

  /** 反馈开关（由 SettingsViewModel 推送）：完成通知/站内记录受通知开关控制，震动受震动开关控制 */
  private notificationFeedbackEnabled: boolean = true
  private vibrationFeedbackEnabled: boolean = true

  /**
   * 更新番茄钟反馈开关（由 SettingsViewModel 在加载与用户修改时调用）
   */
  setFeedbackEnabled(notificationEnabled: boolean, vibrationEnabled: boolean): void {
    this.notificationFeedbackEnabled = notificationEnabled
    this.vibrationFeedbackEnabled = vibrationEnabled
    Logger.info(PomodoroService.tag, 'setFeedbackEnabled: notif=' + notificationEnabled.toString() +
      ', vibrate=' + vibrationEnabled.toString())
  }

  /**
   * 震动反馈（短震 200ms，受设置"震动反馈"开关控制）
   */
  private vibrate(): void {
    if (!this.vibrationFeedbackEnabled) {
      Logger.info(PomodoroService.tag, 'vibrate skipped: disabled by settings')
      return
    }
    try {
      vibrator.startVibration({
        type: 'time',
        duration: 200
      }, {
        id: 0,
        usage: 'notification'
      }).then((): void => {
        Logger.info(PomodoroService.tag, 'vibrate done')
      }).catch((e: Error): void => {
        Logger.warn(PomodoroService.tag, 'vibrate failed: ' + e.message)
      })
    } catch (e) {
      Logger.warn(PomodoroService.tag, 'vibrate error: ' + (e as Error).message)
    }
  }

  // 统计持久化

  /**
   * 加载番茄钟统计（跨天自动重置）
   */
  async loadStats(): Promise<PomodoroStats> {
    if (!this.checkInit()) {
      return this.getDefaultStats()
    }
    const fallback: PomodoroStats = this.getDefaultStats()
    const stats: PomodoroStats =
      await StorageManager.loadData<PomodoroStats>(
        this.context!, CommonConstants.STORAGE_KEY_POMODORO_STATS, fallback)

    // 跨天重置
    const today: string = this.formatDate(Date.now())
    if (stats.lastFocusDate !== today) {
      stats.todayFocusCount = 0
      stats.todayFocusMillis = 0
      stats.lastFocusDate = today
      Logger.info(PomodoroService.tag, 'loadStats: cross-day reset')
    }
    return stats
  }

  /**
   * 专注完成时累加统计
   * @param explicitFocusMillis - 显式指定本次专注时长；缺省时取当前会话配置时长
   *   （冷启动补记场景会话已不可用，必须显式传入）
   */
  private async incrementFocusStats(explicitFocusMillis?: number): Promise<void> {
    if (!this.checkInit()) return
    try {
      const stats: PomodoroStats = await this.loadStats()
      stats.todayFocusCount += 1
      // 使用本次会话的实际专注时长（支持自定义时长）
      const focusMillis: number = explicitFocusMillis !== undefined
        ? explicitFocusMillis
        : (this.session !== null ? this.session.focusDurationMillis : this.focusDurationMillis)
      stats.todayFocusMillis += focusMillis
      stats.lastFocusDate = this.formatDate(Date.now())
      await StorageManager.saveData(
        this.context!, CommonConstants.STORAGE_KEY_POMODORO_STATS, stats)
      Logger.info(PomodoroService.tag, 'incrementFocusStats: count=' +
        stats.todayFocusCount.toString() + ', millis=' + stats.todayFocusMillis.toString())
    } catch (e) {
      Logger.error(PomodoroService.tag, 'incrementFocusStats failed: ' + (e as Error).message)
    }
  }

  /**
   * 获取默认统计（首次使用或数据损坏）
   */
  private getDefaultStats(): PomodoroStats {
    const stats: PomodoroStats = {
      todayFocusCount: 0,
      todayFocusMillis: 0,
      lastFocusDate: this.formatDate(Date.now())
    }
    return stats
  }

  /**
   * 格式化日期为 YYYY-MM-DD
   */
  private formatDate(timestamp: number): string {
    const d: Date = new Date(timestamp)
    const year: number = d.getFullYear()
    const month: string = (d.getMonth() + 1).toString().padStart(2, '0')
    const day: string = d.getDate().toString().padStart(2, '0')
    return year + '-' + month + '-' + day
  }

  // 状态查询与通知

  /**
   * 获取当前会话快照（UI 用于恢复状态）
   */
  getCurrentSession(): PomodoroSessionSnapshot | null {
    return this.session
  }

  /**
   * 计算当前剩余毫秒（UI 重新打开时调用，避免显示旧值）
   * - 无会话或已停止：返回 0
   * - running：totalDuration - (elapsedBeforePause + now - roundStartTime)
   * - paused：totalDuration - elapsedBeforePause
   */
  getCurrentRemainingMillis(): number {
    if (this.session === null) return 0
    const totalDuration: number = this.session.phase === 'focus'
      ? this.session.focusDurationMillis
      : this.getActualBreakDuration()
    if (this.session.state === 'paused') {
      return Math.max(0, totalDuration - this.session.elapsedBeforePause)
    }
    if (this.session.state === 'running') {
      const elapsed: number = this.session.elapsedBeforePause + (Date.now() - this.roundStartTime)
      return Math.max(0, totalDuration - elapsed)
    }
    return 0
  }

  getActualBreakDuration(): number {
    if (this.session === null) return this.breakDurationMillis
    const isLongBreak: boolean = this.session.cycleLength > 0 &&
      this.session.completedFocusCount % this.session.cycleLength === 0
    return isLongBreak ? this.session.longBreakDurationMillis : this.session.breakDurationMillis
  }

  isLongBreakRound(): boolean {
    if (this.session === null) return false
    // completedFocusCount=0 时 0%N===0 会误判为长休（恢复场景首轮休息错用长休时长/配色）
    if (this.session.completedFocusCount <= 0) return false
    return this.session.cycleLength > 0 &&
      this.session.completedFocusCount % this.session.cycleLength === 0
  }

  /**
   * 获取工作阶段时长（UI 用于渲染进度环总长）
   * 优先返回当前会话的自定义时长，无会话时返回默认值
   */
  getFocusDurationMillis(): number {
    if (this.session !== null) {
      return this.session.focusDurationMillis
    }
    return this.focusDurationMillis
  }

  /**
   * 获取休息阶段时长
   * 优先返回当前会话的自定义时长，无会话时返回默认值
   */
  getBreakDurationMillis(): number {
    if (this.session !== null) {
      return this.session.breakDurationMillis
    }
    return this.breakDurationMillis
  }

  getLongBreakDurationMillis(): number {
    if (this.session !== null) {
      return this.session.longBreakDurationMillis
    }
    return this.longBreakDurationMillis
  }

  getCycleLength(): number {
    if (this.session !== null) {
      return this.session.cycleLength
    }
    return this.cycleLength
  }

  /**
   * 通知状态变化
   */
  private notifyStateChange(): void {
    const state: PomodoroState = this.session === null ? 'idle' : this.session.state
    const phase: PomodoroPhase = this.session === null ? 'focus' : this.session.phase
    // 遍历所有状态回调（支持 TimerCard + ImmersiveScreen 同时更新）
    this.stateCallbacks.forEach((cb: PomodoroStateCallback): void => {
      cb(state, phase)
    })
  }

  // 通知栏辅助方法（fire-and-forget，异常不阻断计时）
  //
  // ⚠️ 只在【状态切换点】调用（开始专注 / 进入休息 / 暂停 / 恢复 / 冷启动恢复会话）。
  //    严禁在 onTickInternal 里按秒刷新：BASIC_TEXT 通知每次 publish 都会重新弹横幅，
  //    按秒刷新会让一次 25 分钟专注弹出约 1500 条系统横幅。

  /**
   * 发布/刷新通知栏常驻通知（安全包装）
   * Promise 链挂 .catch 兜底，异常不会冒泡到调用方
   *
   * @param context - 应用上下文
   * @param taskId - 任务 ID
   * @param taskTitle - 任务标题
   * @param phase - 阶段：专注 / 休息
   * @param status - 状态：进行中 / 已暂停
   * @param spanMillis - 进行中传本次总时长；已暂停传暂停那一刻的剩余时长
   */
  private publishCountdownSafe(context: Context, taskId: string, taskTitle: string,
    phase: PomoNotifPhase, status: PomoNotifStatus, spanMillis: number): void {
    // 实况窗已接管展示时跳过常驻通知：否则通知中心会同时出现「实况窗卡片 + 常驻通知」
    // 两个入口。实况窗创建失败时 isActive() 恒为 false，通知照发（完整降级）。
    if (this.liveViewService.isActive()) {
      // 顺手清掉接管前可能已发布的那条常驻通知
      this.cancelCountdownSafe()
      return
    }
    this.notificationService.publishCountdown(context, taskId, taskTitle, phase, status, spanMillis)
      .catch((e: Error): void => {
        Logger.warn(PomodoroService.tag, 'publishCountdown failed: ' + e.message)
      })
  }

  /**
   * 同步实况窗（fire-and-forget 安全包装，任何失败只记日志）
   *
   * @param remainingMillis - **剩余**毫秒：实况窗倒计时由该值往下走，
   *   与常驻通知传"阶段总时长"的语义不同（通知不会自己走，实况窗会）
   * @param paused - 是否暂停（驱动辅助区文案与 timer.isPaused）
   */
  private syncLiveViewSafe(context: Context, taskId: string, taskTitle: string,
    phase: PomodoroPhase, remainingMillis: number, paused: boolean): void {
    this.liveViewService.ensureRunning(context, taskId, taskTitle, phase, remainingMillis, paused)
      .catch((e: Error): void => {
        Logger.warn(PomodoroService.tag, 'liveView ensureRunning failed: ' + e.message)
      })
  }

  /** 结束实况窗（fire-and-forget 安全包装） */
  private endLiveViewSafe(): void {
    this.liveViewService.end().catch((e: Error): void => {
      Logger.warn(PomodoroService.tag, 'liveView end failed: ' + e.message)
    })
  }

  /**
   * 取消通知栏倒计时（安全包装）
   * - Promise 链挂 .catch 兜底
   */
  private cancelCountdownSafe(): void {
    this.notificationService.cancelCountdown().catch((e: Error): void => {
      Logger.warn(PomodoroService.tag, 'cancelCountdown failed: ' + e.message)
    })
  }

  // Session 持久化（冷启动恢复用）

  /**
   * 持久化当前 session（带 savedAt 时间戳）
   * 调用时机：startFocus / startBreak / pause / resume
   */
  private saveSession(): void {
    if (!this.checkInit()) return
    if (this.session === null) return
    const snapshot: PomodoroSessionSnapshot = this.session
    const persist: PomodoroSessionPersist = {
      taskId: snapshot.taskId,
      taskTitle: snapshot.taskTitle,
      phase: snapshot.phase,
      state: snapshot.state,
      startTime: snapshot.startTime,
      elapsedBeforePause: snapshot.elapsedBeforePause,
      focusDurationMillis: snapshot.focusDurationMillis,
      breakDurationMillis: snapshot.breakDurationMillis,
      longBreakDurationMillis: snapshot.longBreakDurationMillis,
      cycleLength: snapshot.cycleLength,
      completedFocusCount: snapshot.completedFocusCount,
      savedAt: Date.now()
    }
    StorageManager.saveData(this.context!, CommonConstants.STORAGE_KEY_POMODORO_SESSION, persist)
      .then((): void => {
        Logger.info(PomodoroService.tag, 'saveSession success, state=' + snapshot.state)
      })
      .catch((e: Error): void => {
        Logger.warn(PomodoroService.tag, 'saveSession failed: ' + e.message)
      })
  }

  /**
   * 从本地加载持久化的 session
   * - 调用时机：init → restoreSessionIfNeeded
   * - 失败返回 null，不影响番茄钟启动
   * - 检测 __cleared__ 标记（stopInternal 时写入），返回 null 表示无有效会话
   *
   * @returns PomodoroSessionPersist 或 null（无数据/已清除/加载失败）
   */
  private async loadSession(): Promise<PomodoroSessionPersist | null> {
    if (!this.checkInit()) return null
    try {
      const raw: Record<string, Object> | null =
        await StorageManager.loadData<Record<string, Object> | null>(
          this.context!, CommonConstants.STORAGE_KEY_POMODORO_SESSION, null)
      if (raw === null) return null
      // 检测清除标记
      if (raw['__cleared__'] !== undefined) {
        Logger.info(PomodoroService.tag, 'loadSession: session cleared marker found')
        return null
      }
      // 转换为 PomodoroSessionPersist
      const persist: PomodoroSessionPersist = {
        taskId: typeof raw['taskId'] === 'string' ? raw['taskId'] as string : '',
        taskTitle: typeof raw['taskTitle'] === 'string' ? raw['taskTitle'] as string : '',
        phase: (raw['phase'] === 'focus' || raw['phase'] === 'break')
          ? raw['phase'] as PomodoroPhase : 'focus',
        state: typeof raw['state'] === 'string' ? raw['state'] as PomodoroState : 'idle',
        startTime: typeof raw['startTime'] === 'number' ? raw['startTime'] as number : 0,
        elapsedBeforePause: typeof raw['elapsedBeforePause'] === 'number'
          ? raw['elapsedBeforePause'] as number : 0,
        focusDurationMillis: typeof raw['focusDurationMillis'] === 'number'
          ? raw['focusDurationMillis'] as number : 25 * 60 * 1000,
        breakDurationMillis: typeof raw['breakDurationMillis'] === 'number'
          ? raw['breakDurationMillis'] as number : 5 * 60 * 1000,
        longBreakDurationMillis: typeof raw['longBreakDurationMillis'] === 'number'
          ? raw['longBreakDurationMillis'] as number : 15 * 60 * 1000,
        cycleLength: typeof raw['cycleLength'] === 'number'
          ? raw['cycleLength'] as number : 4,
        completedFocusCount: typeof raw['completedFocusCount'] === 'number'
          ? raw['completedFocusCount'] as number : 0,
        savedAt: typeof raw['savedAt'] === 'number' ? raw['savedAt'] as number : 0
      }
      // 校验 savedAt 有效性
      if (persist.savedAt === 0) return null
      return persist
    } catch (e) {
      Logger.warn(PomodoroService.tag, 'loadSession failed: ' + (e as Error).message)
      return null
    }
  }

  /**
   * 清除持久化的 session
   * - 调用时机：stopInternal / restoreSessionIfNeeded 发现会话过期
   * - 失败仅记录日志，不阻断后续流程
   * - 注意：StorageManager.saveData 第二个参数要求 object 类型，不接受 null
   *   此处用空字符串标记「无会话」，loadSession 时检测空字符串并返回 null
   */
  private async clearSession(): Promise<void> {
    if (!this.checkInit()) return
    try {
      // 用空对象标记清除（避免 null 类型不匹配）
      const emptyMarker: Record<string, string> = { '__cleared__': '' }
      await StorageManager.saveData(
        this.context!, CommonConstants.STORAGE_KEY_POMODORO_SESSION, emptyMarker)
      Logger.info(PomodoroService.tag, 'clearSession success')
    } catch (e) {
      Logger.warn(PomodoroService.tag, 'clearSession failed: ' + (e as Error).message)
    }
  }

  /**
   * 查询番茄钟是否正在运行
   * 供 EntryAbility 在 onNewWant 中检测，触发沉浸屏呼出
   * state === 'running' 才返回 true（paused 不自动呼出，避免打扰）
   *
   * @returns true=运行中，false=空闲或暂停
   */
  isRunning(): boolean {
    return this.session !== null && this.session.state === 'running'
  }
}

/**
 * 全局单例导出
 */
export const pomodoroService: PomodoroService = PomodoroService.getInstance()
