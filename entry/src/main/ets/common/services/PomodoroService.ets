/**
 * 番茄钟专注计时服务（单例）
 * 前台 setInterval 计时 + 后台 reminderAgent 兜底（进程被杀也能到点弹通知）+ 完成通知震动
 * 单例保证同一时刻只有一个会话，session 持久化支持冷启动恢复
 */

import { notificationManager } from '@kit.NotificationKit'
import { reminderAgentManager } from '@kit.BackgroundTasksKit'
import { vibrator } from '@kit.SensorServiceKit'
import { WantAgent } from '@kit.AbilityKit'
import { Logger } from '../utils/Logger'
import { StorageManager } from '../utils/StorageManager'
import { CommonConstants } from '../constants/CommonConstants'
import { WantAgentFactory } from '../utils/WantAgentFactory'
import { PomodoroNotificationService } from './PomodoroNotificationService'
import { notificationCenterService } from './NotificationCenterService'

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
  /** 沉浸屏可见性变化回调（由 TaskDetailPage 注册） */
  private immersiveVisibleCallback: PomodoroImmersiveVisibleCallback | null = null
  /** 沉浸屏当前可见状态 */
  private immersiveVisible: boolean = false
  /** 回调 ID 自增计数器 */
  private nextCallbackId: number = 1

  /** 通知栏倒计时服务引用（替代实况窗方案，所有调用均 fire-and-forget 不阻塞计时） */
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

        // 重新发布通知栏倒计时（替代实况窗方案）
        this.publishCountdownSafe(this.context!, session.taskId, session.taskTitle, remaining)
      } else {
        // 会话已过期，清除
        Logger.info(PomodoroService.tag, 'restoreSessionIfNeeded: session expired, discard')
        await this.clearSession()
      }
    } else if (session.state === 'paused') {
      const remaining: number = totalDuration - session.elapsedBeforePause
      if (remaining > 0) {
        this.session = session
        this.notifyStateChange()
        Logger.info(PomodoroService.tag, 'restoreSessionIfNeeded: paused restored, remaining=' +
          remaining.toString() + 'ms')

        // 重新发布通知栏倒计时（显示"已暂停"）
        this.publishCountdownSafe(this.context!, session.taskId, session.taskTitle, remaining)
        this.updateCountdownSafe(remaining, '已暂停')
      } else {
        Logger.info(PomodoroService.tag, 'restoreSessionIfNeeded: paused session expired, discard')
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
   * 显示沉浸屏（由 TimerCard 调用）
   */
  showImmersive(): void {
    this.immersiveVisible = true
    if (this.immersiveVisibleCallback !== null) {
      this.immersiveVisibleCallback(true)
    }
  }

  /**
   * 隐藏沉浸屏（由 ImmersiveScreen 返回手势 / TimerCard 停止时调用）
   */
  hideImmersive(): void {
    this.immersiveVisible = false
    if (this.immersiveVisibleCallback !== null) {
      this.immersiveVisibleCallback(false)
    }
  }

  /**
   * 获取沉浸屏当前可见状态
   */
  isImmersiveVisible(): boolean {
    return this.immersiveVisible
  }

  /**
   * 注册沉浸屏可见性变化回调（由 TaskDetailPage 注册）
   */
  onImmersiveVisibleChange(cb: PomodoroImmersiveVisibleCallback): void {
    this.immersiveVisibleCallback = cb
  }

  /**
   * 清除沉浸屏可见性变化回调（TaskDetailPage aboutToDisappear 时调用）
   */
  clearImmersiveCallback(): void {
    this.immersiveVisibleCallback = null
  }

  /**
   * 清除所有回调（应用销毁时调用）
   */
  clearCallbacks(): void {
    this.tickCallbacks.clear()
    this.stateCallbacks.clear()
    this.completeCallbacks.clear()
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

    this.publishCountdownSafe(this.context!, taskId, taskTitle, focusMillis)
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

    this.publishCountdownSafe(this.context!, taskId, taskTitle, actualBreakMillis)
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

    // 更新通知栏倒计时状态为"已暂停"
    const remaining: number = this.getCurrentRemainingMillis()
    this.updateCountdownSafe(remaining, '已暂停')
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

    // 更新通知栏倒计时状态恢复为"专注中/休息中"
    const remaining: number = this.getCurrentRemainingMillis()
    const status: string = this.session.phase === 'focus'
      ? '专注中 ' + this.formatTime(remaining)
      : '休息中 ' + this.formatTime(remaining)
    this.updateCountdownSafe(remaining, status)
    //持久化 session（running 状态）
    this.saveSession()
  }

  /**
   * 停止并清除当前会话（不触发完成回调）
   */
  stop(): void {
    this.stopInternal(true)
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

    // 同步更新通知栏倒计时（每秒一次，fire-and-forget 不阻塞 setInterval）
    const status: string = currentPhase === 'focus'
      ? '专注中 ' + this.formatTime(remaining)
      : '休息中 ' + this.formatTime(remaining)
    this.updateCountdownSafe(remaining, status)
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
      }
    }
  }

  // 后台兜底：reminderAgent

  /**
   * 注册后台提醒（应用退后台时调用）
   * 即使进程被杀，系统也会在到点时弹出通知
   */
  registerBackgroundReminder(): void {
    if (this.session === null || this.session.state !== 'running') {
      Logger.info(PomodoroService.tag, 'registerBackgroundReminder: no running session, skip')
      return
    }
    if (!this.checkInit()) return

    const totalElapsed: number = this.session.elapsedBeforePause + (Date.now() - this.roundStartTime)
    const totalDuration: number = this.session.phase === 'focus'
      ? this.session.focusDurationMillis
      : this.getActualBreakDuration()
    const remaining: number = totalDuration - totalElapsed
    if (remaining <= 0) {
      return
    }

    const triggerTime: number = new Date(Date.now() + remaining).getTime()
    const title: string = this.session.phase === 'focus'
      ? '专注完成'
      : '休息结束'
    const text: string = this.session.phase === 'focus'
      ? '任务『' + this.session.taskTitle + '』专注完成，休息一下吧'
      : '休息结束，可以开始下一轮专注了'

    try {
      const reminder: reminderAgentManager.ReminderRequestCalendar = {
        reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR,
        dateTime: {
          year: new Date(triggerTime).getFullYear(),
          month: new Date(triggerTime).getMonth() + 1,
          day: new Date(triggerTime).getDate(),
          hour: new Date(triggerTime).getHours(),
          minute: new Date(triggerTime).getMinutes(),
          second: new Date(triggerTime).getSeconds()
        },
        title: title,
        content: text,
        notificationId: this.notificationIdBase + (this.session.phase === 'focus' ? 0 : 1),
        slotType: notificationManager.SlotType.SERVICE_INFORMATION
      }
      reminderAgentManager.publishReminder(reminder).then((id: number): void => {
        this.reminderId = id
        Logger.info(PomodoroService.tag, 'registerBackgroundReminder: id=' + id.toString() +
          ', triggerAt=' + triggerTime.toString())
      }).catch((e: Error): void => {
        Logger.warn(PomodoroService.tag, 'registerBackgroundReminder failed: ' + e.message)
      })
    } catch (e) {
      Logger.warn(PomodoroService.tag, 'registerBackgroundReminder error: ' + (e as Error).message)
    }
  }

  /**
   * 取消后台提醒（对外公开，供 EntryAbility.onForeground 回前台时调用）
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

    try {
      const title: string = isFocus ? '专注完成' : '休息结束'
      const text: string = isFocus
        ? '任务『' + this.session.taskTitle + '』已完成一轮专注，休息一下吧'
        : '休息结束，可以开始下一轮专注了'

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

  /**
   * 震动反馈（短震 200ms）
   */
  private vibrate(): void {
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
   */
  private async incrementFocusStats(): Promise<void> {
    if (!this.checkInit()) return
    try {
      const stats: PomodoroStats = await this.loadStats()
      stats.todayFocusCount += 1
      // 使用本次会话的实际专注时长（支持自定义时长）
      const focusMillis: number = this.session !== null
        ? this.session.focusDurationMillis
        : this.focusDurationMillis
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

  // 通知栏倒计时辅助方法（fire-and-forget，异常不阻断计时）

  /**
   * 发布通知栏倒计时（安全包装）
   * Promise 链挂 .catch 兜底，异常不会冒泡到调用方
   *
   * @param context - 应用上下文
   * @param taskId - 任务 ID
   * @param taskTitle - 任务标题
   * @param remainingMillis - 剩余毫秒
   */
  private publishCountdownSafe(context: Context, taskId: string, taskTitle: string, remainingMillis: number): void {
    this.notificationService.publishCountdown(context, taskId, taskTitle, remainingMillis)
      .catch((e: Error): void => {
        Logger.warn(PomodoroService.tag, 'publishCountdown failed: ' + e.message)
      })
  }

  /**
   * 更新通知栏倒计时（安全包装）
   * - Promise 链挂 .catch 兜底，异常不会冒泡到 onTickInternal
   *
   * @param remainingMillis - 剩余毫秒
   * @param status - 状态文案
   */
  private updateCountdownSafe(remainingMillis: number, status: string): void {
    this.notificationService.updateCountdown(remainingMillis, status)
      .catch((e: Error): void => {
        Logger.warn(PomodoroService.tag, 'updateCountdown failed: ' + e.message)
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

  /**
   * 格式化剩余毫秒为 MM:SS（用于通知栏/UI 倒计时显示）
   *
   * @param millis - 剩余毫秒
   */
  private formatTime(millis: number): string {
    const totalSeconds: number = Math.max(0, Math.floor(millis / 1000))
    const minutes: number = Math.floor(totalSeconds / 60)
    const seconds: number = totalSeconds % 60
    const minStr: string = minutes.toString().padStart(2, '0')
    const secStr: string = seconds.toString().padStart(2, '0')
    return minStr + ':' + secStr
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
