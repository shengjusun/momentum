import { promptAction } from '@kit.ArkUI'
import {
  pomodoroService,
  PomodoroState,
  PomodoroPhase,
  PomodoroSessionSnapshot,
  PomodoroStats
} from '../services/PomodoroService'
import { Logger } from '../utils/Logger'
import { CommonConstants } from '../constants/CommonConstants'

interface DurationOption {
  minutes: number
  label: string
}

@ComponentV2
export struct PomodoroImmersiveScreen {
  @Param taskId: string = ''
  @Param taskTitle: string = ''

  @Local remainingMillis: number = 25 * 60 * 1000
  @Local state: PomodoroState = 'idle'
  @Local phase: PomodoroPhase = 'focus'
  @Local selectedFocusMinutes: number = 25
  @Local selectedBreakMinutes: number = 5
  @Local selectedLongBreakMinutes: number = 15
  @Local selectedCycleLength: number = 4
  @Local completedFocusCount: number = 0
  @Local progressValue: number = 0
  @Local breathScale: number = 1.0
  @Local isLongBreak: boolean = false
  @Local todayCount: number = 0
  @Local todayMillis: number = 0
  /** 当前按下的按钮 ID（按压态，统一 onTouch 范式） */
  @Local pressedBtn: string = ''

  private setPressedBtn(id: string, event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      this.pressedBtn = id
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.pressedBtn = ''
    }
  }

  private readonly tag: string = 'PomodoroImmersiveScreen'
  private tickCbId: number = -1
  private stateCbId: number = -1
  private completeCbId: number = -1
  private breathAnimTimer: number = -1

  private readonly focusOptions: DurationOption[] = [
    { minutes: 15, label: '15' },
    { minutes: 25, label: '25' },
    { minutes: 35, label: '35' },
    { minutes: 45, label: '45' }
  ]
  private readonly breakOptions: DurationOption[] = [
    { minutes: 3, label: '3' },
    { minutes: 5, label: '5' },
    { minutes: 10, label: '10' },
    { minutes: 15, label: '15' }
  ]

  aboutToAppear(): void {
    this.tickCbId = pomodoroService.onTick((remaining: number, currentPhase: PomodoroPhase): void => {
      this.remainingMillis = remaining
      this.phase = currentPhase
      this.isLongBreak = pomodoroService.isLongBreakRound()
      this.progressValue = this.computeProgressFromRemaining(remaining, currentPhase)
    })
    this.stateCbId = pomodoroService.onStateChange((newState: PomodoroState, newPhase: PomodoroPhase): void => {
      this.state = newState
      this.phase = newPhase
      this.isLongBreak = pomodoroService.isLongBreakRound()
      const remaining: number = pomodoroService.getCurrentRemainingMillis()
      this.remainingMillis = remaining
      this.progressValue = this.computeProgressFromRemaining(remaining, newPhase)
      if (newState === 'idle') {
        this.startBreathAnimation()
      } else {
        this.stopBreathAnimation()
      }
    })
    this.completeCbId = pomodoroService.onComplete((completedPhase: PomodoroPhase): void => {
      if (completedPhase === 'focus') {
        this.completedFocusCount += 1
        this.refreshStats()
        promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.pomo_focus_complete_toast').id), duration: 2000 })
      } else if (pomodoroService.isAutoContinueEnabled()) {
        promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.pomo_auto_continue_toast').id), duration: 2000 })
      } else {
        promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.pomo_break_complete_toast').id), duration: 2000 })
      }
    })

    this.restoreSession()
    this.refreshStats()
    if (this.state === 'idle') {
      this.startBreathAnimation()
    }
  }

  aboutToDisappear(): void {
    this.stopBreathAnimation()
    if (this.tickCbId > 0) { pomodoroService.offTick(this.tickCbId); this.tickCbId = -1 }
    if (this.stateCbId > 0) { pomodoroService.offStateChange(this.stateCbId); this.stateCbId = -1 }
    if (this.completeCbId > 0) { pomodoroService.offComplete(this.completeCbId); this.completeCbId = -1 }
  }

  private async refreshStats(): Promise<void> {
    try {
      const stats: PomodoroStats = await pomodoroService.loadStats()
      this.todayCount = stats.todayFocusCount
      this.todayMillis = stats.todayFocusMillis
    } catch (e) {
      Logger.warn(this.tag, 'refreshStats failed: ' + (e as Error).message)
    }
  }

  private formatDuration(millis: number): string {
    const totalMinutes: number = Math.floor(millis / 60000)
    const hours: number = Math.floor(totalMinutes / 60)
    const minutes: number = totalMinutes % 60
    if (hours > 0) {
      return hours.toString() + 'h ' + minutes.toString() + 'm'
    }
    return minutes.toString() + 'm'
  }

  private startBreathAnimation(): void {
    if (this.breathAnimTimer !== -1) return
    const runCycle = (): void => {
      this.breathScale = this.breathScale > 1.07 ? 1.0 : 1.15
      animateTo({ duration: 2000, curve: Curve.EaseInOut }, () => {})
      this.breathAnimTimer = setTimeout(() => { runCycle() }, 2100)
    }
    runCycle()
  }

  private stopBreathAnimation(): void {
    if (this.breathAnimTimer !== -1) {
      clearTimeout(this.breathAnimTimer)
      this.breathAnimTimer = -1
    }
    this.breathScale = 1.0
  }

  private restoreSession(): void {
    const session: PomodoroSessionSnapshot | null = pomodoroService.getCurrentSession()
    if (session === null) {
      this.state = 'idle'; this.phase = 'focus'
      this.remainingMillis = this.selectedFocusMinutes * 60 * 1000
      this.progressValue = 0; this.completedFocusCount = 0
      this.isLongBreak = false
      return
    }
    this.state = session.state; this.phase = session.phase
    this.selectedFocusMinutes = Math.floor(session.focusDurationMillis / 60000)
    this.selectedBreakMinutes = Math.floor(session.breakDurationMillis / 60000)
    this.selectedLongBreakMinutes = Math.floor(session.longBreakDurationMillis / 60000)
    this.selectedCycleLength = session.cycleLength
    this.completedFocusCount = session.completedFocusCount
    this.isLongBreak = pomodoroService.isLongBreakRound()
    const remaining: number = pomodoroService.getCurrentRemainingMillis()
    this.remainingMillis = remaining
    this.progressValue = this.computeProgressFromRemaining(remaining, session.phase)
  }

  private formatTime(millis: number): string {
    const totalSeconds: number = Math.max(0, Math.floor(millis / 1000))
    const minutes: number = Math.floor(totalSeconds / 60)
    const seconds: number = totalSeconds % 60
    return minutes.toString().padStart(2, '0') + ':' + seconds.toString().padStart(2, '0')
  }

  private computeProgressFromRemaining(remaining: number, currentPhase: PomodoroPhase): number {
    const session: PomodoroSessionSnapshot | null = pomodoroService.getCurrentSession()
    const total: number = currentPhase === 'focus'
      ? (session !== null ? session.focusDurationMillis : this.selectedFocusMinutes * 60 * 1000)
      : (session !== null ? pomodoroService.getActualBreakDuration() : this.selectedBreakMinutes * 60 * 1000)
    if (total <= 0) return 0
    const elapsed: number = total - remaining
    const percent: number = Math.floor((elapsed / total) * 100)
    return Math.max(0, Math.min(100, percent))
  }

  private currentRoundInCycle(): number {
    if (this.selectedCycleLength <= 0) return 1
    return (this.completedFocusCount % this.selectedCycleLength) + 1
  }

  build() {
    Column() {
      Row() {
        Row() {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(CommonConstants.FONT_SIZE_BODY)
            .fontColor([$r('app.color.pomo_immersive_text_weak')])
            .fontWeight(FontWeight.Medium)
        }
        .width(36)
        .height(36)
        .borderRadius(18)
        .alignItems(VerticalAlign.Center)
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.pomo_immersive_surface'))
        .border({ width: 0.5, color: $r('app.color.pomo_immersive_border') })
        .onClick((): void => { pomodoroService.hideImmersive() })

        Blank()
      }
      .width('100%')
      .height(52)
      .padding({ left: 20, right: 20, top: 8 })

      if (this.state === 'idle') {
        this.idleContent()
      } else {
        this.runningContent()
      }
    }
    .width('100%')
    .height('100%')
    .radialGradient({
      center: [50, 60],
      radius: '120%',
      colors: [
        [$r('app.color.pomo_immersive_bg_start'), 0.0],
        [$r('app.color.pomo_immersive_bg_mid'), 0.5],
        [$r('app.color.pomo_immersive_bg_end'), 1.0]
      ]
    })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  idleContent() {
    Scroll() {
      Column() {
        Blank().layoutWeight(1)

        Stack({ alignContent: Alignment.Center }) {
          Circle({ width: 220, height: 220 })
            .fill(Color.Transparent)
            .stroke($r('app.color.pomo_immersive_outer_ring'))
            .strokeWidth(1)
            .scale({ x: this.breathScale, y: this.breathScale })
            .animation({ duration: 2000, curve: Curve.EaseInOut })

          Circle({ width: 180, height: 180 })
            .fill(Color.Transparent)
            .stroke($r('app.color.pomo_immersive_ring_stroke'))
            .strokeWidth(1.5)

          Column({ space: 4 }) {
            Text(this.formatTime(this.selectedFocusMinutes * 60 * 1000))
              .fontSize(CommonConstants.FONT_SIZE_TIMER_MD)
              .fontColor($r('app.color.pomo_immersive_text_strong'))
              .fontWeight(FontWeight.Bold)
              .fontFamily('monospace')
              .letterSpacing(4)
            Text($r('app.string.pomo_ready_to_focus'))
              .fontSize(CommonConstants.FONT_SIZE_SMALL)
              .fontColor($r('app.color.pomo_immersive_text_weak'))
              .letterSpacing(2)
          }
        }
        .width(220)
        .height(220)

        Text(this.taskTitle.length > 0 ? this.taskTitle :
          getContext(this).resourceManager.getStringSync($r('app.string.pomo_focus_now').id))
          .fontSize(CommonConstants.FONT_SIZE_BODY)
          .fontColor($r('app.color.pomo_immersive_text_medium'))
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 20, bottom: 32 })
          .padding({ left: 32, right: 32 })

        Blank().layoutWeight(0.4)

        Column({ space: 20 }) {
          this.inlineChips(
            this.focusOptions,
            this.selectedFocusMinutes,
            $r('app.color.pomo_immersive_chip_active_bg'),
            $r('app.color.pomo_immersive_chip_active_border'),
            (m: number): void => { this.selectedFocusMinutes = m }
          )

          this.inlineChips(
            this.breakOptions,
            this.selectedBreakMinutes,
            $r('app.color.pomo_immersive_chip_break_active_bg'),
            $r('app.color.pomo_immersive_chip_break_active_border'),
            (m: number): void => { this.selectedBreakMinutes = m }
          )

          Row({ space: 6 }) {
            ForEach([1, 2, 3, 4], (dotIndex: number) => {
              Circle({ width: 6, height: 6 })
                .fill(dotIndex <= this.currentRoundInCycle()
                  ? $r('app.color.pomo_immersive_dot_active')
                  : $r('app.color.pomo_immersive_dot_inactive'))
            }, (dotIndex: number) => dotIndex.toString())
            Text(getContext(this).resourceManager.getStringSync($r('app.string.pomo_cycle_label').id).replace('%d', this.selectedCycleLength.toString()))
              .fontSize(CommonConstants.FONT_SIZE_XXS)
              .fontColor($r('app.color.pomo_immersive_text_faint'))
          }

          Button() {
            Text($r('app.string.pomo_start_focus'))
              .fontSize(CommonConstants.FONT_SIZE_SUBTITLE)
              .fontColor($r('app.color.pomo_immersive_text_strong'))
              .fontWeight(FontWeight.Medium)
          }
          .type(ButtonType.Capsule)
          .width('60%')
          // 宽屏适配：按钮不至于拉满整屏
          .constraintSize({ maxWidth: 360 })
          .height(50)
          .borderRadius(25)
          .linearGradient({
            angle: 135,
            colors: [[$r('app.color.pomo_immersive_gradient_start'), 0.0], [$r('app.color.pomo_immersive_gradient_end'), 1.0]]
          })
          .shadow({ radius: 20, color: $r('app.color.pomo_immersive_focus_shadow'), offsetX: 0, offsetY: 6 })
          .scale({ x: this.pressedBtn === 'start' ? 0.96 : 1, y: this.pressedBtn === 'start' ? 0.96 : 1 })
          .animation({ duration: 100, curve: Curve.EaseOut })
          .margin({ bottom: 32 })
          .onTouch((event: TouchEvent): void => {
            this.setPressedBtn('start', event)
          })
          .onClick((): void => {
            pomodoroService.startFocus(this.taskId, this.taskTitle,
              this.selectedFocusMinutes, this.selectedBreakMinutes,
              this.selectedLongBreakMinutes, this.selectedCycleLength)
          })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  inlineChips(
    options: DurationOption[],
    selectedMin: number,
    activeBg: ResourceStr,
    activeBorder: ResourceStr,
    onSelect: (m: number) => void
  ) {
    Row({ space: 6 }) {
      ForEach(options, (opt: DurationOption) => {
        Text(opt.label)
          .fontSize(CommonConstants.FONT_SIZE_CAPTION)
          .fontColor(selectedMin === opt.minutes ? $r('app.color.pomo_immersive_text_strong') : $r('app.color.pomo_immersive_text_weak'))
          .fontWeight(selectedMin === opt.minutes ? FontWeight.Medium : FontWeight.Normal)
          .padding({ left: 16, right: 16, top: 7, bottom: 7 })
          .borderRadius(16)
          .backgroundColor(selectedMin === opt.minutes ? activeBg : $r('app.color.pomo_immersive_chip_bg'))
          .border({ width: selectedMin === opt.minutes ? 1 : 0, color: selectedMin === opt.minutes ? activeBorder : Color.Transparent })
          .onClick((): void => { onSelect(opt.minutes) })
      }, (opt: DurationOption) => opt.label)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  runningContent() {
    Column() {
      Blank().layoutWeight(1)

      Row() {
        if (this.isLongBreak) {
          Text($r('app.string.pomo_long_break_tag'))
            .fontSize(CommonConstants.FONT_SIZE_XXS)
            .fontColor($r('app.color.pomo_immersive_long_break'))
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .borderRadius(8)
            .backgroundColor($r('app.color.pomo_immersive_long_break_phase_pill'))
        }
        Text(this.phase === 'focus' ? $r('app.string.pomo_focusing') : $r('app.string.pomo_resting'))
          .fontSize(CommonConstants.FONT_SIZE_SMALL)
          .fontColor(this.isLongBreak ? $r('app.color.pomo_immersive_long_break') :
            (this.phase === 'focus' ? $r('app.color.pomo_immersive_focus') : $r('app.color.pomo_immersive_break')))
          .letterSpacing(4)
      }
      .margin({ bottom: 20 })

      Row({ space: 5 }) {
        ForEach([1, 2, 3, 4], (dotIndex: number) => {
          Circle({ width: 6, height: 6 })
            .fill(dotIndex <= this.currentRoundInCycle()
              ? $r('app.color.pomo_immersive_dot_active')
              : $r('app.color.pomo_immersive_dot_inactive'))
        }, (dotIndex: number) => dotIndex.toString())
      }
      .margin({ bottom: 24 })

      Stack({ alignContent: Alignment.Center }) {
        Progress({ value: 100, total: 100, type: ProgressType.Ring })
          .width(220).height(220)
          .color($r('app.color.pomo_immersive_surface'))
          .style({ strokeWidth: 6 })

        Progress({ value: this.progressValue, total: 100, type: ProgressType.Ring })
          .width(220).height(220)
          .color(this.isLongBreak ? $r('app.color.pomo_immersive_long_break') :
            (this.phase === 'focus' ? $r('app.color.pomo_immersive_focus') : $r('app.color.pomo_immersive_break')))
          .backgroundColor(Color.Transparent)
          .style({ strokeWidth: 6 })
          .shadow(this.phase === 'focus'
            ? { radius: 24, color: $r('app.color.pomo_immersive_progress_glow'), offsetX: 0, offsetY: 0 }
            : { radius: 24, color: $r('app.color.pomo_immersive_break_progress_glow'), offsetX: 0, offsetY: 0 })

        Column({ space: 6 }) {
          Text(this.formatTime(this.remainingMillis))
            .fontSize(CommonConstants.FONT_SIZE_TIMER_XL)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.pomo_immersive_text_strong'))
            .letterSpacing(3)
            .fontFamily('monospace')
          Text(this.phase === 'focus' ? '🍅' : '☕')
            .fontSize(CommonConstants.FONT_SIZE_XL)
            .margin({ top: 4 })
        }
      }
      .width(220).height(220)

      Column({ space: 4 }) {
        Text(this.taskTitle.length > 0 ? this.taskTitle :
          getContext(this).resourceManager.getStringSync($r('app.string.pomo_focus_now').id))
          .fontSize(CommonConstants.FONT_SIZE_BODY)
          .fontColor($r('app.color.pomo_immersive_text_medium'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ left: 40, right: 40 })
          .margin({ top: 32 })

        if (this.state === 'paused') {
          Text($r('app.string.pomo_paused'))
            .fontSize(CommonConstants.FONT_SIZE_SMALL)
            .fontColor($r('app.color.pomo_immersive_text_weak'))
        } else if (this.phase === 'break' && this.isLongBreak) {
          Text($r('app.string.pomo_long_break_hint'))
            .fontSize(CommonConstants.FONT_SIZE_SMALL)
            .fontColor($r('app.color.pomo_immersive_text_weak'))
        } else if (this.phase === 'break') {
          Text($r('app.string.pomo_break_hint'))
            .fontSize(CommonConstants.FONT_SIZE_SMALL)
            .fontColor($r('app.color.pomo_immersive_text_weak'))
        } else {
          Text($r('app.string.pomo_keep_focus_hint'))
            .fontSize(CommonConstants.FONT_SIZE_SMALL)
            .fontColor($r('app.color.pomo_immersive_text_weak'))
        }
      }

      Blank().layoutWeight(1)

      Row({ space: 16 }) {
        if (this.state === 'running') {
          Button($r('app.string.pomo_pause'))
            .type(ButtonType.Capsule)
            .width(140).height(48)
            .backgroundColor($r('app.color.pomo_immersive_btn_surface'))
            .border({ width: 0.5, color: $r('app.color.pomo_immersive_btn_border') })
            .fontColor($r('app.color.pomo_immersive_text_strong')).fontSize(CommonConstants.FONT_SIZE_MID)
            .borderRadius(24)
            .scale({ x: this.pressedBtn === 'pause' ? 0.96 : 1, y: this.pressedBtn === 'pause' ? 0.96 : 1 })
            .animation({ duration: 100, curve: Curve.EaseOut })
            .onTouch((event: TouchEvent): void => {
              this.setPressedBtn('pause', event)
            })
            .onClick((): void => { pomodoroService.pause() })
        } else if (this.state === 'paused') {
          Button($r('app.string.pomo_resume'))
            .type(ButtonType.Capsule)
            .width(140).height(48)
            .linearGradient({
              angle: 135,
              colors: [[$r('app.color.pomo_immersive_gradient_start'), 0.0], [$r('app.color.pomo_immersive_gradient_end'), 1.0]]
            })
            .fontColor($r('app.color.pomo_immersive_text_strong')).fontSize(CommonConstants.FONT_SIZE_MID)
            .borderRadius(24)
            .shadow({ radius: 12, color: $r('app.color.pomo_immersive_focus_shadow'), offsetX: 0, offsetY: 4 })
            .scale({ x: this.pressedBtn === 'resume' ? 0.96 : 1, y: this.pressedBtn === 'resume' ? 0.96 : 1 })
            .animation({ duration: 100, curve: Curve.EaseOut })
            .onTouch((event: TouchEvent): void => {
              this.setPressedBtn('resume', event)
            })
            .onClick((): void => { pomodoroService.resume() })
        } else {
          Button($r('app.string.pomo_start_next_round'))
            .type(ButtonType.Capsule)
            .width(160).height(48)
            .linearGradient({
              angle: 135,
              colors: [[$r('app.color.pomo_immersive_gradient_start'), 0.0], [$r('app.color.pomo_immersive_gradient_end'), 1.0]]
            })
            .fontColor($r('app.color.pomo_immersive_text_strong')).fontSize(CommonConstants.FONT_SIZE_MID)
            .borderRadius(24)
            .shadow({ radius: 12, color: $r('app.color.pomo_immersive_focus_shadow'), offsetX: 0, offsetY: 4 })
            .scale({ x: this.pressedBtn === 'next' ? 0.96 : 1, y: this.pressedBtn === 'next' ? 0.96 : 1 })
            .animation({ duration: 100, curve: Curve.EaseOut })
            .onTouch((event: TouchEvent): void => {
              this.setPressedBtn('next', event)
            })
            .onClick((): void => {
              pomodoroService.startFocus(this.taskId, this.taskTitle,
                this.selectedFocusMinutes, this.selectedBreakMinutes,
                this.selectedLongBreakMinutes, this.selectedCycleLength)
            })
        }

        if (this.state === 'running' || this.state === 'paused') {
          Button($r('app.string.pomo_stop'))
            .type(ButtonType.Capsule)
            .width(140).height(48)
            .backgroundColor($r('app.color.pomo_immersive_btn_surface'))
            .fontColor($r('app.color.pomo_immersive_text_medium')).fontSize(CommonConstants.FONT_SIZE_MID)
            .borderRadius(24)
            .scale({ x: this.pressedBtn === 'stop' ? 0.96 : 1, y: this.pressedBtn === 'stop' ? 0.96 : 1 })
            .animation({ duration: 100, curve: Curve.EaseOut })
            .onTouch((event: TouchEvent): void => {
              this.setPressedBtn('stop', event)
            })
            .onClick((): void => {
              pomodoroService.stop()
              // 停止后同步关闭沉浸屏：停留 idle 态会迫使用户按返回退出，
              // 而返回退出曾把可见标志残留在 Service，导致之后打开任意任务详情被全屏番茄钟覆盖
              pomodoroService.hideImmersive()
              promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.pomo_stopped_toast').id), duration: 1500 })
            })
        }
      }
      .margin({ bottom: 80 })
    }
    .width('100%')
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }
}
