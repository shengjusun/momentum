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
    // v3 稿：大卡 → **紧凑条**（图标 + 主副文案 + 右侧开关/停止；整条可点进入专注）
    // 原「今日统计」独立行、分隔线、「可选时长」提示行、橙色"开始"按钮全部收进这一条，
    // 把纵向空间还给步骤区（用户反馈：番茄钟占了整张卡只放一个开关，视觉重量失衡）。
    Row({ space: 10 }) {
      // 图标圆底：专注=橙 / 休息=绿（运行中按阶段换色）
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph($r('sys.symbol.timer'))
          .fontSize(CommonConstants.FONT_SIZE_SUBTITLE)
          .fontColor([this.state !== 'idle' && this.phase !== 'focus'
            ? $r('app.color.icon_text_green') : $r('app.color.icon_text_orange')])
      }
      .width(30)
      .height(30)
      .borderRadius(15)
      .backgroundColor(this.state !== 'idle' && this.phase !== 'focus'
        ? $r('app.color.icon_bg_green') : $r('app.color.icon_bg_orange'))

      // 主 + 副文案
      Column({ space: 2 }) {
        Text(this.state === 'idle' ? $r('app.string.pomo_start_focus') :
          (this.state === 'paused' ? $r('app.string.pomo_focus_paused') :
            (this.phase === 'focus' ? $r('app.string.pomo_focus_in_progress') : $r('app.string.pomo_resting'))))
          .fontSize(CommonConstants.FONT_SIZE_BODY)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(this.state === 'idle'
          ? (this.todayCount > 0 || this.todayMillis > 0
            ? (getContext(this).resourceManager.getStringSync($r('app.string.pomo_today_prefix').id) +
              this.todayCount.toString() +
              getContext(this).resourceManager.getStringSync($r('app.string.pomo_today_count_infix').id) +
              this.formatDuration(this.todayMillis))
            : getContext(this).resourceManager.getStringSync($r('app.string.pomo_optional_duration_hint').id))
          : (this.completedFocusCount > 0
            ? (getContext(this).resourceManager.getStringSync($r('app.string.pomo_completed_rounds_prefix').id) +
              this.completedFocusCount.toString() +
              getContext(this).resourceManager.getStringSync($r('app.string.pomo_completed_rounds_suffix').id))
            : getContext(this).resourceManager.getStringSync($r('app.string.pomo_optional_duration_hint').id)))
          .fontSize(CommonConstants.FONT_SIZE_XS)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 右侧：未开始=自动连跑开关（去掉长文案，只留开关 + 无障碍标签）；运行中=停止
      if (this.state === 'idle') {
        Toggle({ type: ToggleType.Switch, isOn: this.autoContinue })
          .selectedColor($r('app.color.warning_color'))
          .scale({ x: 0.8, y: 0.8 })
          .accessibilityText($r('app.string.pomo_auto_continue'))
          .onChange((isOn: boolean): void => {
            this.autoContinue = isOn
            pomodoroService.setAutoContinueEnabled(isOn)
          })
      } else {
        Text($r('app.string.pomo_stop'))
          .fontSize(CommonConstants.FONT_SIZE_XS)
          .fontColor($r('app.color.text_secondary'))
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(DimensConstants.RADIUS_L)
          .border({ width: 0.5, color: $r('app.color.divider') })
          .accessibilityText($r('app.string.pomo_stop'))
          .onClick((): void => this.onStopClick())
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 11, bottom: 11 })
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(DimensConstants.RADIUS_M)
    .shadow({ radius: 4, color: $r('app.color.shadow_card'), offsetX: 0, offsetY: 1 })
    .alignItems(VerticalAlign.Center)
    // 整条可点：未开始 → 开始专注；运行中 → 打开沉浸屏
    .onClick((): void => {
      if (this.state === 'idle') {
        this.onStartClick()
      } else {
        this.onViewClick()
      }
    })
  }
}
