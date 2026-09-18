/**
 * @file 番茄钟实况窗服务（Live View Kit · TIMER 场景）
 * @description
 *   把番茄钟的进行中状态外显到状态栏胶囊 / 通知中心 / 锁屏。
 *
 *   【场景规范 · 勿违反，否则正式权限被驳回】
 *   - 只有「计时中 / 暂停」两个节点
 *   - **状态必须写在卡片辅助区**（`primary.extensionData`）：规范原文
 *     "卡片辅助区需明确展示当前处于计时中/暂停状态，不得使用可能导致用户混淆当前状态的内容"
 *     → 只把状态写在标题里不合规
 *   - 用户主动或被动终止计时 → **必须立即 stopLiveView**
 *   - 仅端侧创建与更新（不走 Push）；单窗 ≤ 8h
 *
 *   【倒数机制 · 本项目最关键的一条】
 *   倒数由 **LiveView 顶层 `timer`** 驱动，系统每秒自动刷新，配合
 *   `${placeholder.timer}` 占位符渲染 —— 应用**严禁按秒调 updateLiveView**
 *   （应用级更新流控每秒 20 次会被丢弃，且进程被冻结时调用根本发不出去）。
 *   于是应用只在状态切换点调用：开始 / 暂停 / 恢复 / 阶段切换 / 结束，
 *   单个阶段全程 ≤ 2 次，进程被杀后系统仍会把倒计时走完。
 *
 *   【降级纪律】
 *   任何失败只记日志并复位内部状态，绝不影响计时；`isActive()` 为 false 时
 *   PomodoroService 会回退到既有的常驻通知方案（PomodoroNotificationService）。
 *
 * @module common/services
 */

import { liveViewManager } from '@kit.LiveViewKit'
import { WantAgent } from '@kit.AbilityKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { resourceManager } from '@kit.LocalizationKit'
import { Logger } from '../utils/Logger'
import { WantAgentFactory } from '../utils/WantAgentFactory'
import { logPushTokenOnce } from '../utils/PushTokenProbe'

/** 实况窗展示的阶段（与 PomodoroService 的 phase 对齐；服务层不反向 import viewmodel） */
export type LiveViewPhase = 'focus' | 'break'

/** `${placeholder.timer}`：由系统计时器每秒替换为倒计时读数，应用不刷新 */
const TIMER_PLACEHOLDER: string = '${placeholder.timer}'

/** 卡片标题中任务名的截断长度（字段上限 1024，此处按版式只留 30） */
const TASK_TITLE_MAX: number = 30

/** 胶囊背景色（#AARRGGBB，需 9 位；取沉浸屏主色 #5B8DEF） */
const CAPSULE_BG_COLOR: string = '#FF5B8DEF'

/**
 * 胶囊图标：**必须是 `/resources/rawfile` 下的文件名**
 *
 * ⚠️ 两个踩过的坑（任一都会让 startLiveView 直接失败，且因降级设计而静默、极难排查）：
 *   ① `icon` 传 `image.PixelMap` 时规范要求**图片不大于 30KB** —— 位图是 `w×h×4` 字节，
 *      拿应用图标（1024²）解码出来约 4MB，必然超标 130 倍；
 *   ② `app.media.app_icon` 实际是 **SVG**，`image.createImageSource()` 不能解码 SVG，
 *      第一步就抛异常。
 * 故改为：一张 96×96 透明底 PNG 放进 rawfile，用文件名引用（413 字节）。
 */
const CAPSULE_ICON_FILE: string = 'pomo_capsule_icon.png'

/** liveViewManager 错误码 */
const ERR_ALREADY_EXISTS: number = 1003500006
/** 无实况窗权益（绝大多数情况 = 设备未加入实况窗白名单） */
const ERR_RIGHT_NOT_ENABLED: number = 1003500005

export class PomodoroLiveViewService {
  private static readonly tag: string = 'PomodoroLiveView'
  private static instance: PomodoroLiveViewService | null = null

  /** 实况窗唯一标识（自生成，取值范围内任选，全局固定即可） */
  private static readonly LIVE_VIEW_ID: number = 60001

  /** 本进程内实况窗是否已成功创建（false → 上层走常驻通知降级） */
  private created: boolean = false
  /** 保序版本号：每次创建/更新必须递增，否则 update 会被判为过期而失败 */
  private sequence: number = 0
  /** 实况窗总开关是否已查询过（只查一次，结果落日志便于定位"不显示"） */
  private switchChecked: boolean = false
  /** 点击动作缓存（按 taskId 复用，避免每次状态切换都重建 WantAgent） */
  private clickActionCache: WantAgent | null = null
  private clickActionTaskId: string = ''
  /** 最近一次构造的实况窗对象（end() 需要完整对象才能 stop） */
  private lastPayload: liveViewManager.LiveView | null = null

  private constructor() {}

  static getInstance(): PomodoroLiveViewService {
    if (PomodoroLiveViewService.instance === null) {
      PomodoroLiveViewService.instance = new PomodoroLiveViewService()
    }
    return PomodoroLiveViewService.instance
  }

  /** 实况窗是否已接管展示（false = 由常驻通知兜底） */
  isActive(): boolean {
    return this.created
  }

  /**
   * 确保实况窗处于「计时中 / 已暂停」状态（幂等：已创建则 update，未创建则 start）
   *
   * 唯一的更新入口 —— 开始专注 / 进入休息 / 暂停 / 恢复 / 冷启动恢复全部走这里。
   *
   * @param remainingMillis - **剩余**毫秒（倒计时由该值往下走，不是阶段总时长）
   * @param paused - 是否暂停（同时驱动辅助区文案与 `timer.isPaused`）
   */
  async ensureRunning(context: Context, taskId: string, taskTitle: string,
    phase: LiveViewPhase, remainingMillis: number, paused: boolean): Promise<void> {
    Logger.info(PomodoroLiveViewService.tag, 'ensureRunning: phase=' + phase +
      ', remaining=' + remainingMillis.toString() + 'ms, paused=' + paused.toString() +
      ', created=' + this.created.toString())

    const liveView: liveViewManager.LiveView =
      await this.buildLiveView(context, taskId, taskTitle, phase, remainingMillis, paused)
    this.lastPayload = liveView

    if (this.created) {
      try {
        await liveViewManager.updateLiveView(liveView)
        return
      } catch (e) {
        // 实况窗可能已被系统回收（超时清理）→ 复位后降级为新建
        this.created = false
        Logger.warn(PomodoroLiveViewService.tag,
          'updateLiveView failed, fallback to start: ' + (e as BusinessError).message)
      }
    }

    try {
      // 首次创建前查一次系统总开关（结果落日志，便于区分「开关没开」与「无权益」）
      await this.checkSwitchOnce()
      await liveViewManager.startLiveView(liveView)
      this.created = true
      Logger.info(PomodoroLiveViewService.tag, 'liveView started, phase=' + phase +
        ', remaining=' + remainingMillis.toString() + 'ms, paused=' + paused.toString())
    } catch (e) {
      const err: BusinessError = e as BusinessError
      if (err.code === ERR_ALREADY_EXISTS) {
        // 系统里还留着同一 id 的实况窗（上次进程异常退出）→ 用 update 接管，
        // 否则这个 id 会永远 start 不成功
        try {
          await liveViewManager.updateLiveView(liveView)
          this.created = true
          Logger.info(PomodoroLiveViewService.tag, 'liveView adopted by update (already exists)')
          return
        } catch (e2) {
          Logger.warn(PomodoroLiveViewService.tag,
            'adopt existing liveView failed: ' + (e2 as BusinessError).message)
        }
      }
      this.created = false
      Logger.warn(PomodoroLiveViewService.tag, 'startLiveView failed (fallback to notification): code=' +
        err.code.toString() + ', msg=' + err.message)
      // 1003500005 = 无实况窗权益。实操中绝大多数是「设备未加入实况窗白名单」，
      // 而 AGC「实况窗 → 白名单设备管理」要求**按 Push Token 添加设备** →
      // 顺手把 token 打出来，用户复制粘贴即可，省掉一整轮排查
      if (err.code === ERR_RIGHT_NOT_ENABLED) {
        logPushTokenOnce().catch((e2: Error): void => {
          Logger.warn(PomodoroLiveViewService.tag, 'logPushToken failed: ' + e2.message)
        })
      }
    }
  }

  /**
   * 结束实况窗（用户停止 / 休息完成回待机 / 恢复时发现会话已过期）
   *
   * 规范要求"终止计时立即结束实况窗"，故 `keepTime` 走默认 0（不存档、立即消失）。
   * 幂等：未创建时直接返回。
   */
  async end(): Promise<void> {
    const base: liveViewManager.LiveView | null = this.lastPayload
    this.created = false
    this.lastPayload = null
    if (base === null) {
      return
    }
    this.sequence += 1
    base.sequence = this.sequence
    try {
      await liveViewManager.stopLiveView(base)
      Logger.info(PomodoroLiveViewService.tag, 'liveView stopped')
    } catch (e) {
      Logger.warn(PomodoroLiveViewService.tag,
        'stopLiveView failed: ' + (e as BusinessError).message)
    }
  }

  /**
   * 查询实况窗系统总开关（只查一次）
   * 纯诊断用：不阻断创建，真正失败原因由 startLiveView 的错误码给出
   */
  private async checkSwitchOnce(): Promise<void> {
    if (this.switchChecked) {
      return
    }
    this.switchChecked = true
    try {
      const enabled: boolean = await liveViewManager.isLiveViewEnabled()
      Logger.info(PomodoroLiveViewService.tag, 'system liveView switch enabled=' + enabled.toString())
    } catch (e) {
      Logger.warn(PomodoroLiveViewService.tag,
        'isLiveViewEnabled failed: ' + (e as BusinessError).message)
    }
  }

  /* ============================================================
   * 内部：构造实况窗对象
   * ============================================================ */

  private async buildLiveView(context: Context, taskId: string, taskTitle: string,
    phase: LiveViewPhase, remainingMillis: number, paused: boolean): Promise<liveViewManager.LiveView> {
    const rm: resourceManager.ResourceManager = context.resourceManager

    // 固定区标题 = 阶段（+ 任务名，超长截断）
    const phaseText: string = phase === 'focus'
      ? rm.getStringByNameSync('liveview_title_focus')
      : rm.getStringByNameSync('liveview_title_break')
    const title: string = taskTitle.length > 0
      ? phaseText + ' · ' + this.truncateTitle(taskTitle)
      : phaseText

    // ⚠️ 规范硬约束：状态必须落在**辅助区**，不能只写在标题里
    const stateText: string = rm.getStringByNameSync(
      paused ? 'liveview_state_paused' : 'liveview_state_running')

    const timerText: liveViewManager.RichText = { text: TIMER_PLACEHOLDER }
    const extension: liveViewManager.ExtensionData = {
      type: liveViewManager.ExtensionType.EXTENSION_TYPE_COMMON_TEXT,
      text: stateText
    }
    const layout: liveViewManager.LayoutData = {
      layoutType: liveViewManager.LayoutType.LAYOUT_TYPE_DEFAULT
    }
    const primary: liveViewManager.PrimaryData = {
      title: title,
      content: [timerText],
      clickAction: await this.getClickAction(context, taskId),
      layoutData: layout,
      extensionData: extension
    }

    // 胶囊态：TimerCapsule 自带倒计时字段，同样由系统每秒刷新
    const capsule: liveViewManager.TimerCapsule = {
      type: liveViewManager.CapsuleType.CAPSULE_TYPE_TIMER,
      status: 1,
      icon: CAPSULE_ICON_FILE,
      backgroundColor: CAPSULE_BG_COLOR,
      time: remainingMillis,
      isCountdown: true,
      isPaused: paused
    }

    // 顶层计时器：倒数的唯一驱动源
    const timer: liveViewManager.LiveViewTimer = {
      time: remainingMillis,
      isCountdown: true,
      isPaused: paused
    }

    const data: liveViewManager.LiveViewData = {
      primary: primary,
      capsule: capsule
    }

    this.sequence += 1
    Logger.info(PomodoroLiveViewService.tag, 'payload built: title=' + title +
      ', state=' + stateText + ', seq=' + this.sequence.toString())
    const liveView: liveViewManager.LiveView = {
      id: PomodoroLiveViewService.LIVE_VIEW_ID,
      event: 'TIMER',
      sequence: this.sequence,
      // 状态切换静默：完成提醒已由通知 + 震动承担，实况窗不再重复打扰
      isMute: true,
      timer: timer,
      liveViewData: data
    }
    return liveView
  }

  /** 点击动作：openImmersive=true → 从实况窗点进来直接落地全屏番茄钟 */
  private async getClickAction(context: Context, taskId: string): Promise<WantAgent> {
    if (this.clickActionCache !== null && this.clickActionTaskId === taskId) {
      return this.clickActionCache
    }
    const agent: WantAgent = await WantAgentFactory.createTaskDetailWantAgent(context, taskId, true)
    this.clickActionCache = agent
    this.clickActionTaskId = taskId
    return agent
  }

  private truncateTitle(text: string): string {
    return text.length > TASK_TITLE_MAX ? text.substring(0, TASK_TITLE_MAX) : text
  }
}

/** 全局单例 */
export const pomodoroLiveViewService: PomodoroLiveViewService = PomodoroLiveViewService.getInstance()
