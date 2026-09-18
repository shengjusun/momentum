/**
 * @file 番茄钟专注计时入口卡片
 * @description
 *   内嵌于 TaskDetailPage 的任务信息卡下方，作为"开始专注"入口。
 *   - idle / completed：显示开始按钮 + 今日统计
 *   - running / paused：显示专注进行中状态 + 查看/停止按钮
 *   - 点击「开始专注」后，通过 bindContentCover 呼出沉浸式全屏番茄钟
 *   - 完成/停止后自动关闭沉浸屏
 *   - 沉浸屏内点击左上角返回手势，通过 closeImmersiveRequest 回调关闭
 *
 *   修复记录：
 *   - 不在 aboutToDisappear 调用 clearCallbacks（会导致重呼出沉浸屏后 Service 回调失效）
 *   - 改为在 aboutToAppear 中重新注册（覆盖式注册），保证每次呼出都能收到回调
 *
 *   V2 规范：@ComponentV2 + @Local + @Param
 *
 * @module common/components
 * @date 2026-07-24
 */

import { promptAction } from '@kit.ArkUI'
import { DimensConstants } from '../constants/DimensConstants'
import {
  pomodoroService,
  PomodoroState,
  PomodoroPhase,
  PomodoroStats,
  PomodoroSessionSnapshot
} from '../services/PomodoroService'
import { Logger } from '../utils/Logger'
import { CommonConstants } from '../constants/CommonConstants'

/**
 * 番茄钟入口卡片组件
 * 使用方式：<PomodoroTimerCard({ taskId: 'xxx', taskTitle: '任务标题' })} />
 */
@ComponentV2
export struct PomodoroTimerCard {
  /** 关联任务 ID（用于 PomodoroService.startFocus） */
  @Param taskId: string = ''
  /** 任务标题（用于通知文案 + 沉浸屏显示） */
  @Param taskTitle: string = ''

  /** 当前运行状态 */
  @Local state: PomodoroState = 'idle'
  /** 当前阶段 */
  @Local phase: PomodoroPhase = 'focus'
  /** 今日专注次数 */
  @Local todayCount: number = 0
  @Local todayMillis: number = 0
  @Local completedFocusCount: number = 0
  @Local autoContinue: boolean = false
  @Local selectedFocusMinutes: number = 25
  @Local selectedBreakMinutes: number = 5
  @Local selectedLongBreakMinutes: number = 15
  @Local selectedCycleLength: number = 4

  private readonly tag: string = 'PomodoroTimerCard'
  /** 回调 ID（用于 aboutToDisappear 时精确注销） */
  private stateCbId: number = -1
  private completeCbId: number = -1

  /**
   * 组件即将出现：注册回调 + 加载统计 + 恢复状态
   */
  aboutToAppear(): void {
    // 注册状态变化回调（保存 ID 用于精确注销）
    this.stateCbId = pomodoroService.onStateChange((newState: PomodoroState, newPhase: PomodoroPhase): void => {
      this.state = newState
      this.phase = newPhase
      // 同步轮数
      const session: PomodoroSessionSnapshot | null = pomodoroService.getCurrentSession()
      this.completedFocusCount = session !== null ? session.completedFocusCount : 0
    })
    this.completeCbId = pomodoroService.onComplete((completedPhase: PomodoroPhase): void => {
      this.refreshStats()
      if (completedPhase === 'focus') {
        promptAction.showToast({
          message: getContext(this).resourceManager.getStringSync($r('app.string.pomo_focus_complete_toast').id),
          duration: 2000
        })
      } else if (pomodoroService.isAutoContinueEnabled()) {
        promptAction.showToast({
          message: getContext(this).resourceManager.getStringSync($r('app.string.pomo_auto_continue_toast').id),
          duration: 2000
        })
      } else {
        promptAction.showToast({
          message: getContext(this).resourceManager.getStringSync($r('app.string.pomo_break_complete_toast').id),
          duration: 2000
        })
      }
    })

    // 恢复当前状态
    this.restoreState()
    // 读取自动连跑开关
    this.autoContinue = pomodoroService.isAutoContinueEnabled()
    // 加载今日统计
    this.refreshStats()

    Logger.info(this.tag, 'aboutToAppear: taskId=' + this.taskId)
  }

  /**
   * 组件即将消失：精确注销本组件的回调
   */
  aboutToDisappear(): void {
    if (this.stateCbId > 0) {
      pomodoroService.offStateChange(this.stateCbId)
      this.stateCbId = -1
    }
    if (this.completeCbId > 0) {
      pomodoroService.offComplete(this.completeCbId)
      this.completeCbId = -1
    }
    Logger.info(this.tag, 'aboutToDisappear: callbacks unregistered')
  }

  /**
   * 恢复 Service 中的状态
   */
  private restoreState(): void {
    const session: PomodoroSessionSnapshot | null = pomodoroService.getCurrentSession()
    if (session === null) {
      this.state = 'idle'
      this.phase = 'focus'
      this.completedFocusCount = 0
      return
    }
    this.state = session.state
    this.phase = session.phase
    this.completedFocusCount = session.completedFocusCount
    this.selectedFocusMinutes = Math.floor(session.focusDurationMillis / 60000)
    this.selectedBreakMinutes = Math.floor(session.breakDurationMillis / 60000)
    this.selectedLongBreakMinutes = Math.floor(session.longBreakDurationMillis / 60000)
    this.selectedCycleLength = session.cycleLength
  }

  /**
   * 刷新今日统计
   */
  private async refreshStats(): Promise<void> {
    try {
      const stats: PomodoroStats = await pomodoroService.loadStats()
      this.todayCount = stats.todayFocusCount
      this.todayMillis = stats.todayFocusMillis
    } catch (e) {
      Logger.warn(this.tag, 'refreshStats failed: ' + (e as Error).message)
    }
  }

  /**
   * 格式化今日累计时长为 "Xh Ym" 或 "Ym"
   */
  private formatDuration(millis: number): string {
    const totalMinutes: number = Math.floor(millis / 60000)
    const hours: number = Math.floor(totalMinutes / 60)
    const minutes: number = totalMinutes % 60
    if (hours > 0) {
      return hours.toString() + 'h ' + minutes.toString() + 'm'
    }
    return minutes.toString() + 'm'
  }

  /**
   * 点击开始专注：通过 Service 全局状态呼出沉浸屏（TaskDetailPage 监听渲染）
   */
  private onStartClick(): void {
    if (this.taskId.length === 0) {
      promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.pomo_task_info_missing').id), duration: 1500 })
      return
    }
    pomodoroService.showImmersive()
  }

  /**
   * 点击查看：重新呼出沉浸屏查看进行中的倒计时
   */
  private onViewClick(): void {
    pomodoroService.showImmersive()
  }

  /**
   * 点击停止（卡片内的停止按钮）
   */
  private onStopClick(): void {
    pomodoroService.stop()
    pomodoroService.hideImmersive()
    promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.pomo_stopped_toast').id), duration: 1500 })
  }

  build() {
    Column() {
      // 今日统计（右上角；无数据时隐藏，避免无信息量占位）
      if (this.todayCount > 0 || this.todayMillis > 0) {
        Row() {
          Blank()
          Text(getContext(this).resourceManager.getStringSync($r('app.string.pomo_today_prefix').id) +
            this.todayCount.toString() +
            getContext(this).resourceManager.getStringSync($r('app.string.pomo_today_count_infix').id) +
            this.formatDuration(this.todayMillis))
            .fontSize(CommonConstants.FONT_SIZE_XS)
            .fontColor($r('app.color.text_tertiary'))
        }
        .width('100%')
        .margin({ bottom: 8 })
      }

      // 根据状态渲染不同内容
      if (this.state === 'idle') {
        Row({ space: 10 }) {
          // 图标统一为「系统 symbol + 36×36 淡色圆底」，与全站入口图标同语言
          // （原为 30vp 手绘番茄轮廓：小尺寸下萼片与果身糊在一起，观感杂乱）
          Stack({ alignContent: Alignment.Center }) {
            SymbolGlyph($r('sys.symbol.timer'))
              .fontSize(CommonConstants.FONT_SIZE_SUBTITLE)
              .fontColor([$r('app.color.icon_text_orange')])
          }
          .width(36)
          .height(36)
          .borderRadius(18)
          .backgroundColor($r('app.color.icon_bg_orange'))
          Column({ space: 2 }) {
            Text($r('app.string.pomo_start_focus'))
              .fontSize(CommonConstants.FONT_SIZE_MID)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
            Text($r('app.string.pomo_optional_duration_hint'))
              .fontSize(CommonConstants.FONT_SIZE_XS)
              .fontColor($r('app.color.text_secondary'))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Button($r('app.string.pomo_start'))
            .type(ButtonType.Capsule)
            .height(32)
            .padding({ left: 18, right: 18 })
            .backgroundColor($r('app.color.warning_color'))
            .fontColor($r('app.color.text_inverse'))
            .fontSize(CommonConstants.FONT_SIZE_CAPTION)
            .fontWeight(FontWeight.Medium)
            .borderRadius(DimensConstants.RADIUS_L)
            .shadow({ radius: 4, color: $r('app.color.warning_color_bg'), offsetX: 0, offsetY: 2 })
            .accessibilityText($r('app.string.pomo_start'))
            .onClick((): void => this.onStartClick())
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      } else {
        Row({ space: 10 }) {
          // 运行中：同一系统图标，靠圆底/线色区分阶段（专注=橙、休息=绿）
          Stack({ alignContent: Alignment.Center }) {
            SymbolGlyph($r('sys.symbol.timer'))
              .fontSize(CommonConstants.FONT_SIZE_SUBTITLE)
              .fontColor([this.phase === 'focus' ? $r('app.color.icon_text_orange') : $r('app.color.icon_text_green')])
          }
          .width(36)
          .height(36)
          .borderRadius(18)
          .backgroundColor(this.phase === 'focus' ? $r('app.color.icon_bg_orange') : $r('app.color.icon_bg_green'))
          Column({ space: 2 }) {
            Text(this.state === 'paused' ? $r('app.string.pomo_focus_paused') :
              (this.phase === 'focus' ? $r('app.string.pomo_focus_in_progress') : $r('app.string.pomo_resting')))
              .fontSize(CommonConstants.FONT_SIZE_MID)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
            if (this.completedFocusCount > 0) {
              Text(getContext(this).resourceManager.getStringSync($r('app.string.pomo_completed_rounds_prefix').id) +
                this.completedFocusCount.toString() +
                getContext(this).resourceManager.getStringSync($r('app.string.pomo_completed_rounds_suffix').id))
                .fontSize(CommonConstants.FONT_SIZE_XS)
                .fontColor($r('app.color.text_secondary'))
            }
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Button($r('app.string.pomo_view'))
            .type(ButtonType.Capsule)
            .height(32)
            .padding({ left: 16, right: 16 })
            .backgroundColor($r('app.color.warning_color'))
            .fontColor($r('app.color.text_inverse'))
            .fontSize(CommonConstants.FONT_SIZE_CAPTION)
            .fontWeight(FontWeight.Medium)
            .borderRadius(DimensConstants.RADIUS_L)
            .accessibilityText($r('app.string.pomo_view'))
            .onClick((): void => this.onViewClick())

          Button($r('app.string.pomo_stop'))
            .type(ButtonType.Capsule)
            .height(32)
            .padding({ left: 14, right: 14 })
            .backgroundColor(Color.Transparent)
            .fontColor($r('app.color.text_secondary'))
            .fontSize(CommonConstants.FONT_SIZE_CAPTION)
            .border({ width: 1, color: $r('app.color.divider') })
            .borderRadius(DimensConstants.RADIUS_L)
            .accessibilityText($r('app.string.pomo_stop'))
            .onClick((): void => this.onStopClick())
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }

      // 休息后自动连跑开关（设置项弱化：分隔线 + 次要文案，与主操作区分层级）
      Divider()
        .color($r('app.color.divider'))
        .margin({ top: 10, bottom: 8 })
      Row() {
        Text($r('app.string.pomo_auto_continue'))
          .fontSize(CommonConstants.FONT_SIZE_XS)
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.autoContinue })
          .selectedColor($r('app.color.warning_color'))
          .scale({ x: 0.85, y: 0.85 })
          .accessibilityText($r('app.string.pomo_auto_continue'))
          .onChange((isOn: boolean): void => {
            this.autoContinue = isOn
            pomodoroService.setAutoContinueEnabled(isOn)
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 14 })
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(DimensConstants.RADIUS_M)
    .shadow({ radius: 4, color: $r('app.color.shadow_card'), offsetX: 0, offsetY: 1 })
  }
}
