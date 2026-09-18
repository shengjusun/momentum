import { promptAction, window } from '@kit.ArkUI'
import { BusinessError } from '@kit.BasicServicesKit'
import { resourceManager } from '@kit.LocalizationKit'
import { DimensConstants } from '../constants/DimensConstants'
import {
  pomodoroService,
  PomodoroState,
  PomodoroPhase,
  PomodoroSessionSnapshot,
  PomodoroStats
} from '../services/PomodoroService'
import { Logger } from '../utils/Logger'
import { CommonConstants } from '../constants/CommonConstants'
import { safeAreaHelper } from '../utils/SafeAreaHelper'
import { StorageManager } from '../utils/StorageManager'
import { AppActionSheet, AppActionSheetItem } from './AppActionSheet'

interface DurationOption {
  minutes: number
  label: string
}

/** 时长偏好持久化记录（saveData 要求 object，用对象包装 number） */
interface DurationPrefRecord {
  value: number
}

/** 沉浸态：控件无交互后自动淡出的延迟（3s 为视频播放器同款交互值，不做成设置项） */
const CHROME_AUTO_HIDE_MILLIS: number = 3000

/** 控件淡出/淡入动画时长 */
const CHROME_FADE_MILLIS: number = 250

/**
 * 计时环直径 / 视口短边 的比例（2026-09-15 大环沉浸版 · 图片稿 v2）
 * ⚠️ 核心：环尺寸**不写死常量，由视口推导**。
 *    历史问题根因：原 `PORTRAIT_RING_SIZE=220` 写死，360vp 宽机器上只占短边 61%，
 *    主角元素够不到"占短边 85%+"的沉浸阈值，环面积仅占屏幕 5.5% → 怎么调参数都没沉浸感。
 * - 竖屏（图片稿 v2：环 + 按钮上下排，图上环径/屏宽 = 453/608 = 0.745）
 *   运行态 0.78 / 待机态 0.70；**不可吃到 0.90**——按钮与环同在竖排流里会有溢出风险（推演见 MEMORY 尺寸推演记录）
 * - 横屏（v4 图片稿：**双圆** 左分圆(细描边·剩余分钟) | 竖线 | 右秒圆(进度弧·剩余秒数)，
 *   下方一枚「暂停 / 继续」胶囊）：直径由 landscapeDualSize() 按可用宽/高反推，
 *   纵向须扣掉 LANDSCAPE_BUTTON_BAND，见常量说明
 */
const PORTRAIT_RING_RATIO_RUNNING: number = 0.78
const PORTRAIT_RING_RATIO_IDLE: number = 0.70

/**
 * 横屏给"圆 + 底部按钮 + 竖线"预留的额外余量（vp）：避免极端机型上贴边
 * ⚠️ v4 起横屏**又有底部按钮了**（时间倒计下方），故纵向要容「圆 + 间距 + 按钮」，余量不能给太大
 */
const LANDSCAPE_RING_MARGIN: number = 10

/**
 * 主操作按钮直径 / 环直径 的比例（图片稿：116/453 = 0.256，由视口推导而非写死 64vp 常量）
 * - 竖屏：环下方的主操作钮；横屏：双圆下方的「暂停 / 继续」胶囊（见 landscapeDual）
 * ⚠️ 必须定义在 PORTRAIT_BUTTON_BAND **之前**：该常量按按钮最大直径做保守预留，
 *    而 const 是块级作用域**不会提升**，写在后面会触发 "used before its declaration" 编译错误。
 */
const ACTION_BTN_RING_RATIO: number = 0.26
const ACTION_BTN_MIN: number = 46
const ACTION_BTN_MAX: number = 76

/** 单按钮图标 / 按钮直径 的比例 */
const ACTION_ICON_BTN_RATIO: number = 0.42

/**
 * 竖屏按钮带高度（含与环之间的 24vp 间距）：按钮为圆形，直径由环径推导，
 * 故按**最大可能值**保守预留，保证任何机型下"环 + 按钮"都落在可用高度内（宁可有富余，不可溢出）
 * ⚠️ 横屏用 LANDSCAPE_BUTTON_BAND（胶囊钮更高），两者不可混用
 */
const PORTRAIT_BUTTON_BAND: number = 24 + ACTION_BTN_MAX

/**
 * 横屏底部胶囊按钮（「暂停 / 继续」，图片稿：时间倒计下方）尺寸 —— 由短边推导
 * - 宽 = 短边 × 0.34、高 = 短边 × 0.105，各自钳在 [132,210] / [46,66]，保证任何机型都可点、不臃肿
 * - 按钮带总高 = 间距 14 + 按钮最高 66 = 80：landscapeDualSize() 反推圆径时要把它扣掉
 */
const LANDSCAPE_ACTION_W_RATIO: number = 0.34
const LANDSCAPE_ACTION_H_RATIO: number = 0.105
const LANDSCAPE_ACTION_W_MIN: number = 132
const LANDSCAPE_ACTION_W_MAX: number = 210
const LANDSCAPE_ACTION_H_MIN: number = 46
const LANDSCAPE_ACTION_H_MAX: number = 66
const LANDSCAPE_ACTION_GAP: number = 14
const LANDSCAPE_BUTTON_BAND: number = LANDSCAPE_ACTION_GAP + LANDSCAPE_ACTION_H_MAX

/**
 * 计时环线宽 / 环直径 的比例
 * ⚠️ 必须随直径走：原写死 8vp，环从 220 涨到 300 后线只占 2.4%，会细得"发虚"。
 *    取 4.8% —— 对齐图片稿（v2 图上约 22/453 = 4.9%），比业界 4~5% 略重，
 *    因为图片稿的观感本来就偏"厚实有力"；小环（≤170）钳到下限 8vp、大环（≥290）钳到上限 14vp。
 * ⚠️ 轨道与进度必须同宽，否则会出现"两个同心圆错位"的观感（历史问题，勿改回差异线宽）。
 */
const RING_STROKE_RATIO: number = 0.048
const RING_STROKE_MIN: number = 8
const RING_STROKE_MAX: number = 14

/**
 * 环内时间字号 / 圆直径 的比例（v3 放大）
 * - 竖屏·分与秒同号 0.26（上一版 0.23 用户反馈"太小"）
 *   ⚠️ 0.26 是**上限**：再大就压弧线（0.28 → 全机型 −8~−15vp，见
 *      docs/上架素材/check_pomo_v3_sizes.py 的 B 段复核）。0.26 时最差余量 +3.2vp。
 * - 横屏·分左秒右同号 0.44（图片稿「24」高度 ≈ 圆径 50%，是上一版 0.21 的 2.1 倍）
 *   ⚠️ 从 v3 的 0.50 回落到 0.44：v4 圆径要扣掉底部按钮带，圆变小了，字要跟着收一点；
 *      0.44 时字宽 ≈ 圆径 0.75、两字中心距 ≈ 圆径 0.65，仍牢牢在内接正方形（0.707）附近，
 *      视觉上「数字几乎顶到圆」的图片稿观感保持不变。
 */
const LANDSCAPE_TIME_RATIO: number = 0.44
const PORTRAIT_MINUTE_RATIO: number = 0.26
const PORTRAIT_SECOND_RATIO: number = 0.26

/** 竖屏分/秒两行的竖直间距（vp）——固定值，不随环缩放，避免小屏上两行贴在一起 */
const PORTRAIT_TIME_LINE_GAP: number = 2

/** 环内阶段标签字号 / 环直径 的比例（图2 的「专注中」，位置在环内上缘，不占外部空间） */
const RING_PHASE_LABEL_RATIO: number = 0.050

/**
 * 横屏版式（v4，对齐图片稿）：`[分圆（细描边·纯显示）] 竖线 [秒圆（进度弧·纯显示）]` 双圆在上，
 * 「暂停 / 继续」胶囊按钮在**时间倒计下方居中**，随控件一起 3 秒淡出
 * - 圆直径 = min( 按可用宽反推 , 按可用高反推 ) × 0.92
 *   可用宽 = 长边 − 左右安全 32 − 圆间空隙 40；可用高 = 短边 − 状态栏 − 余量 − 底部按钮带
 * - ⚠️ **两个圆都不可点击**：横屏的唯一操作入口是底部胶囊（用户定）。
 *    点圆暂停会造成"淡出后点屏幕唤回"时误暂停，语义也不清晰。
 * - ⚠️ 也不再用竖线夹在两个大圆之间撑满宽度，而是由 Row 自然排布，避免小屏挤压。
 */
const LANDSCAPE_DUAL_RATIO: number = 0.92
const LANDSCAPE_DUAL_GAP_MIN: number = 14
const LANDSCAPE_DUAL_SIDE_PAD: number = 22
const LANDSCAPE_DUAL_INNER_PAD: number = 30
/** 分圆的细描边宽（图片稿左圆只有一根细线，与秒圆的粗进度弧形成对比） */
const LANDSCAPE_THIN_STROKE: number = 1.5
/** 中间竖直分隔线（图片稿细节）：高 = 圆径 × 0.42、1vp 宽、低透明度 */
const LANDSCAPE_DIVIDER_RATIO: number = 0.42

/** setWindowSystemBarEnable 入参：显示 / 隐藏 状态栏与底部导航栏 */
const SYSTEM_BAR_VISIBLE: Array<'status' | 'navigation'> = ['status', 'navigation']
const SYSTEM_BAR_HIDDEN: Array<'status' | 'navigation'> = []

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
  /** 待机态轨道环的呼吸透明度（0.5 ↔ 1.0，用明暗而非缩放，更含蓄） */
  @Local breathOpacity: number = 1.0
  @Local isLongBreak: boolean = false
  @Local todayCount: number = 0
  @Local todayMillis: number = 0
  /** 当前按下的按钮 ID（按压态，统一 onTouch 范式） */
  @Local pressedBtn: string = ''
  /** 停止确认面板状态 */
  @Local showStopSheet: boolean = false
  @Local stopSheetTitle: string = ''
  @Local stopSheetItems: AppActionSheetItem[] = []

  /**
   * 沉浸态控件可见性
   * - `running` 且 3 秒无交互 → false：**操作控件**淡出，只留计时环与时间
   * - 点击屏幕任意位置 → 回到 true 并重新计时
   * - 待机 / 暂停 / 停止确认面板打开时恒为 true（要选时长、要做"继续/停止"的决定）
   * ⚠️ 只挂"操作控件"：右上角 ✕、竖屏主操作圆钮、横屏底部胶囊。
   *    **计时显示本体（计时环 / 横屏双圆及其数字）永不挂** —— 它们不是控件，淡掉会像 Bug
   *    （2026-09-15 用户反馈："秒钟淡化，不对吧"；当时横屏秒圆被错挂成可点击控件，已纠正）
   */
  @Local chromeVisible: boolean = true

  /**
   * 实测视口尺寸（根 Stack 的 onAreaChange 上报）：横竖版式判定的唯一来源
   * - 与 AIPage 的 contentWidth 同款做法：实测是物理事实，不存在"监听没绑上所以永远走竖版"的失效路径
   */
  @Local viewW: number = 0
  @Local viewH: number = 0

  /**
   * 是否走横屏版式：用宽高比判定，而不是"宽 > 高"
   * - 1.15 阈值避开正方形窗口 / 折叠屏开合过程中的反复抖动
   */
  private isLandscape(): boolean {
    return this.viewH > 0 && this.viewW > this.viewH * 1.15
  }

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
  /** 控件自动淡出定时器（-1 = 未在计时） */
  private chromeHideTimer: number = -1
  /** 屏幕常亮是否已生效（幂等标记，避免重复调用窗口接口） */
  private keepScreenOnApplied: boolean = false

  /** 恢复上次选择的时长偏好（无记录时保持默认 25/5；长休与周期数当前无修改 UI，仅透传） */
  private restoreDurationPrefs(): void {
    try {
      const context: Context = getContext(this)
      const fallbackFocus: DurationPrefRecord = { value: 25 }
      const fallbackBreak: DurationPrefRecord = { value: 5 }
      const focusRecord: DurationPrefRecord = StorageManager.loadDataSync<DurationPrefRecord>(
        context, 'pomo_pref_focus_minutes', fallbackFocus)
      const breakRecord: DurationPrefRecord = StorageManager.loadDataSync<DurationPrefRecord>(
        context, 'pomo_pref_break_minutes', fallbackBreak)
      if (this.focusOptions.some((o: DurationOption): boolean => o.minutes === focusRecord.value)) {
        this.selectedFocusMinutes = focusRecord.value
      }
      if (this.breakOptions.some((o: DurationOption): boolean => o.minutes === breakRecord.value)) {
        this.selectedBreakMinutes = breakRecord.value
      }
    } catch (_e) {
      // 恢复失败保持默认值
    }
  }

  /** 保存当前选择的时长偏好（开始专注时调用） */
  private saveDurationPrefs(): void {
    try {
      const context: Context = getContext(this)
      // saveData 仅接受 object，number 需包装为显式接口记录
      const focusRecord: DurationPrefRecord = { value: this.selectedFocusMinutes }
      const breakRecord: DurationPrefRecord = { value: this.selectedBreakMinutes }
      StorageManager.saveData(context, 'pomo_pref_focus_minutes', focusRecord)
        .catch((_e: Error): void => {})
      StorageManager.saveData(context, 'pomo_pref_break_minutes', breakRecord)
        .catch((_e: Error): void => {})
    } catch (_e) {
      // 保存失败不影响开始专注
    }
  }

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

  /* ============================================================
   * 沉浸态（1）：控件自动淡出 / 点击唤回
   * ============================================================ */

  /** 控件透明度（配合各元素上的 .animation() 得到淡入淡出） */
  private get chromeOpacity(): number {
    return this.chromeVisible ? 1 : 0
  }

  /**
   * 控件命中模式
   * ⚠️ 隐藏时必须用 None（自身不响应、且不阻塞任何节点）；
   *    **不可用 Block** —— Block 会连祖先节点一起挡掉触摸测试（项目工程约定）。
   */
  private get chromeHitTest(): HitTestMode {
    return this.chromeVisible ? HitTestMode.Default : HitTestMode.None
  }

  /** 是否处于"控件应隐藏"的场景：只有运行中隐藏；待机 / 暂停 / 停止确认面板打开时必须可见 */
  private shouldChromeHide(): boolean {
    return this.state === 'running' && !this.showStopSheet
  }

  private clearChromeHideTimer(): void {
    if (this.chromeHideTimer !== -1) {
      clearTimeout(this.chromeHideTimer)
      this.chromeHideTimer = -1
    }
  }

  /**
   * 重新计时（任意触摸都会调用，不是只在"唤回"时）
   * - 否则用户正按着按钮的过程中，控件会突然淡出
   */
  private scheduleChromeHide(): void {
    this.clearChromeHideTimer()
    if (!this.shouldChromeHide()) {
      this.chromeVisible = true
      return
    }
    this.chromeHideTimer = setTimeout((): void => {
      this.chromeHideTimer = -1
      // 二次校验：这 3 秒内可能已暂停 / 已弹出停止确认
      if (this.shouldChromeHide()) {
        this.chromeVisible = false
      }
    }, CHROME_AUTO_HIDE_MILLIS)
  }

  /** 点击屏幕唤出控件，并重新开始计时 */
  private revealChrome(): void {
    this.chromeVisible = true
    this.scheduleChromeHide()
  }

  /* ============================================================
   * 沉浸态（2）：系统栏隐藏 + 屏幕常亮
   * ============================================================ */

  /** 取主窗口后执行窗口操作（统一异常出口，避免各处重复样板） */
  private withMainWindow(action: (win: window.Window) => void): void {
    window.getLastWindow(getContext(this)).then((win: window.Window): void => {
      try {
        action(win)
      } catch (e) {
        Logger.warn(this.tag, 'window op threw: ' + (e as BusinessError).message)
      }
    }).catch((e: BusinessError): void => {
      Logger.warn(this.tag, 'getLastWindow failed: ' + e.message)
    })
  }

  /**
   * 隐藏 / 恢复状态栏与底部导航栏
   * ⚠️ 只切换"系统栏可见性"，**绝不调用 setWindowLayoutFullScreen**：
   *    EntryAbility.initWindowInsets() 已在启动时全局置为 true，改动它会破坏全应用的避让逻辑。
   */
  private applySystemBars(hide: boolean): void {
    this.withMainWindow((win: window.Window): void => {
      win.setWindowSystemBarEnable(hide ? SYSTEM_BAR_HIDDEN : SYSTEM_BAR_VISIBLE)
        .catch((e: BusinessError): void => {
          Logger.warn(this.tag, 'setWindowSystemBarEnable failed: ' + e.message)
        })
    })
  }

  /**
   * 沉浸屏内允许随传感器旋转（受控制中心"旋转锁定"开关控制）
   * - `module.json5` 未声明 `orientation`，缺省 = `unspecified`（由系统判断方向）。
   *   官方《多设备窗口形态》明确：可旋转应用应显式配置 `auto_rotation_restricted`，
   *   否则系统可能把应用判为竖屏应用 —— 手机横拿时不旋转，横屏版式永远看不到。
   * - 选 RESTRICTED 变体：用户在控制中心锁了旋转就尊重他，不强行转。
   * - 退出时还原为 `UNSPECIFIED`（即应用原本的默认策略），只在沉浸屏内生效。
   */
  private applyOrientation(followSensor: boolean): void {
    this.withMainWindow((win: window.Window): void => {
      const target: window.Orientation = followSensor
        ? window.Orientation.AUTO_ROTATION_RESTRICTED
        : window.Orientation.UNSPECIFIED
      win.setPreferredOrientation(target).catch((e: BusinessError): void => {
        Logger.warn(this.tag, 'setPreferredOrientation failed: ' + e.message)
      })
    })
  }

  /**
   * 会话进行中保持屏幕常亮（桌面时钟场景）
   * - 官方要求"仅必要场景使用、退出场景后必须重置"，故只在 running / paused 生效，待机态不占用；
   * - 窗口退到后台时系统会自动释放常亮锁，无需额外处理 onBackground。
   */
  private syncKeepScreenOn(): void {
    const keepOn: boolean = this.state === 'running' || this.state === 'paused'
    if (keepOn === this.keepScreenOnApplied) {
      return
    }
    this.keepScreenOnApplied = keepOn
    this.withMainWindow((win: window.Window): void => {
      win.setWindowKeepScreenOn(keepOn)
        .catch((e: BusinessError): void => {
          Logger.warn(this.tag, 'setWindowKeepScreenOn failed: ' + e.message)
        })
    })
  }

  aboutToAppear(): void {
    // 恢复上次选择的时长（选择持久化：重开沉浸屏不再回默认值）
    this.restoreDurationPrefs()
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
      // 沉浸态：状态切换后重算"控件是否该淡出"与"是否保持常亮"
      this.scheduleChromeHide()
      this.syncKeepScreenOn()
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

    // 沉浸态：整屏生命周期内隐藏状态栏与底部导航栏；按当前会话状态决定是否保持屏幕常亮
    this.applySystemBars(true)
    this.syncKeepScreenOn()
    // 允许随传感器旋转（受控制中心旋转锁控制），否则手机横拿时不会切横屏版式
    this.applyOrientation(true)
    // 若进入时已在运行中（例如从通知栏回到会话），立即开始"3 秒后淡出"计时
    this.scheduleChromeHide()
  }

  aboutToDisappear(): void {
    this.stopBreathAnimation()
    if (this.tickCbId > 0) { pomodoroService.offTick(this.tickCbId); this.tickCbId = -1 }
    if (this.stateCbId > 0) { pomodoroService.offStateChange(this.stateCbId); this.stateCbId = -1 }
    if (this.completeCbId > 0) { pomodoroService.offComplete(this.completeCbId); this.completeCbId = -1 }

    // 沉浸态收尾：清定时器 + **无条件**恢复系统栏与屏幕常亮。
    // 这是"双保险"的第一道（第二道在 EntryAbility.initWindowInsets 启动自愈），
    // 覆盖 ✕ / 停止 / 页面退出 / 外层 if 条件变化所有路径，
    // 保证任何情况下都不会留下"应用没有状态栏"或"屏幕永久常亮"的故障。
    this.clearChromeHideTimer()
    this.applySystemBars(false)
    this.applyOrientation(false)
    this.keepScreenOnApplied = false
    this.withMainWindow((win: window.Window): void => {
      win.setWindowKeepScreenOn(false)
        .catch((e: BusinessError): void => {
          Logger.warn(this.tag, 'reset keepScreenOn failed: ' + e.message)
        })
    })
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
      // 明暗变化由轨道环自身的 .animation() 属性承担（隐式动画），此处只改状态值
      this.breathOpacity = this.breathOpacity > 0.75 ? 0.5 : 1.0
      this.breathAnimTimer = setTimeout(() => { runCycle() }, 2100)
    }
    runCycle()
  }

  private stopBreathAnimation(): void {
    if (this.breathAnimTimer !== -1) {
      clearTimeout(this.breathAnimTimer)
      this.breathAnimTimer = -1
    }
    this.breathOpacity = 1.0
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

  /**
   * 横屏·分圆读数（**剩余分钟**，两位）
   * ⚠️ 待机态**不做 00 分钟**：那时左圆显示"所选专注时长"，与秒圆的 00 组成"25 00"，
   *    正好和竖屏待机环的读数同构（图上就是这样）。
   * ⚠️ 2026-09-15 修正：v4 曾把这里改成"**已走**分钟"（另立 `sessionElapsedMillis` 派生量），
   *    后果是① 与竖屏（显示剩余）和图片稿（图上左圆 24 = 剩余）都不一致；
   *    ② 刚进专注的 1 分钟内，左圆必然显示 00 → 用户直接报"切横屏分钟变成 0"。
   *    现统一为**剩余分钟**：左圆剩余分 + 右圆剩余秒，与竖屏完全同源（都读 remainingMillis）。
   */
  private minuteCircleText(): string {
    if (this.state === 'idle') {
      return this.selectedFocusMinutes.toString().padStart(2, '0')
    }
    return this.splitMinuteText(this.remainingMillis)
  }

  private formatTime(millis: number): string {
    const totalSeconds: number = Math.max(0, Math.floor(millis / 1000))
    const minutes: number = Math.floor(totalSeconds / 60)
    const seconds: number = totalSeconds % 60
    return minutes.toString().padStart(2, '0') + ':' + seconds.toString().padStart(2, '0')
  }

  /**
   * 把剩余毫秒拆成"分钟两位 / 秒两位"（图片稿 v2：横屏分左秒右、竖屏分上秒下，两处共用）
   * ⚠️ 分钟**不做 99 封顶**：专注/休息时长产品上不会超过 99 分钟，封顶反而会掩盖异常值。
   *    padStart(2) 保证 9 分钟时显示 "09" 而不是 "9"——不等宽会让整块数字左右跳。
   */
  private splitMinuteText(millis: number): string {
    const totalSeconds: number = Math.max(0, Math.floor(millis / 1000))
    return Math.floor(totalSeconds / 60).toString().padStart(2, '0')
  }

  private splitSecondText(millis: number): string {
    const totalSeconds: number = Math.max(0, Math.floor(millis / 1000))
    return (totalSeconds % 60).toString().padStart(2, '0')
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

  // ── 视觉令牌取值：集中在此，避免 build 里散落长三元表达式 ──

  /**
   * 阶段主色：专注=靛蓝 / 短休息=薄荷绿 / 长休息=紫罗兰（2026-09-14 由红系改版）
   * 注意只按 phase 判断长休息，不直接看 isLongBreak：服务端 isLongBreakRound() 在专注第 1 轮
   * 会误判为 true（0 % cycleLength === 0），会把番茄染成靛蓝。
   */
  private phaseAccent(): Resource {
    if (this.phase === 'focus') {
      return $r('app.color.pomo_immersive_focus')
    }
    return this.isLongBreak
      ? $r('app.color.pomo_immersive_long_break')
      : $r('app.color.pomo_immersive_break')
  }

  /** 阶段药丸底色（与阶段主色同源的低透明度版） */
  private phasePillBg(): Resource {
    if (this.phase === 'focus') {
      return $r('app.color.pomo_immersive_phase_pill')
    }
    return this.isLongBreak
      ? $r('app.color.pomo_immersive_long_break_phase_pill')
      : $r('app.color.pomo_immersive_break_phase_pill')
  }

  /** 阶段标签文案：专注中 / 休息中 / 长休息 */
  private phaseTagLabel(): Resource {
    if (this.phase === 'focus') {
      return $r('app.string.pomo_focusing')
    }
    return this.isLongBreak
      ? $r('app.string.pomo_long_break_tag')
      : $r('app.string.pomo_resting')
  }

  /** 今日专注统计文案（"今日 3 次 · 1h 20m"）；无数据时返回空串，调用处据此决定是否渲染 */
  private todayStatsText(): string {
    if (this.todayCount <= 0 && this.todayMillis <= 0) {
      return ''
    }
    const rm: resourceManager.ResourceManager = getContext(this).resourceManager
    return rm.getStringSync($r('app.string.pomo_today_prefix').id) +
      this.todayCount.toString() +
      rm.getStringSync($r('app.string.pomo_today_count_infix').id) +
      this.formatDuration(this.todayMillis)
  }

  build() {
    Stack() {
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
      // 顶部必须整体让开状态栏高度：沉浸屏虽然让背景铺到状态栏下（expandSafeArea），
      // 但【状态栏那块区域始终归系统所有，落在里面的触摸会被系统截走】。
      // 真机实测：状态栏窗口 rect = [0,0,2800,97]px = 38.8vp，而原来的返回按钮占
      // y 12~47.6vp，约 75% 面积压在状态栏带内 → 点正中心无任何响应，只有点按钮下缘
      // 才生效。这里把 52 的行高与 8 的内边距一并加上 statusBar 高度，保证按钮整体
      // 落在可点区域内。（注意 ArkUI 的 height 含 padding，故两处都要加。）
      .height(52 + safeAreaHelper.statusBar)
      .padding({ left: 20, right: 20, top: 8 + safeAreaHelper.statusBar })
      // 沉浸态：随其他控件一起淡出（用透明度而非摘除节点，避免让位高度变化导致布局跳动）
      .opacity(this.chromeOpacity)
      .hitTestBehavior(this.chromeHitTest)
      // ⚠️ HitTestMode.None 只让"自身"不响应，子节点仍可命中 —— 淡出后 ✕ 会变成隐形热区，
      //    故必须再用 enabled(false) 让整棵子树失效（enabled 不阻断祖先，点击仍能冒到根 Stack 唤回）
      .enabled(this.chromeVisible)
      .animation({ duration: CHROME_FADE_MILLIS, curve: Curve.EaseOut })

      // 横竖分流：横屏走「双圆 + 底部胶囊」版式（v4，两个圆纯显示、按钮在下），竖屏走完整版式
      if (this.state === 'idle') {
        if (this.isLandscape()) {
          this.landscapeDual()
        } else {
          this.idleContent()
        }
      } else {
        if (this.isLandscape()) {
          this.landscapeDual()
        } else {
          this.runningContent()
        }
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

    // 统一操作面板：停止专注二次确认
    if (this.showStopSheet) {
      AppActionSheet({
        title: this.stopSheetTitle,
        items: this.stopSheetItems,
        onDismiss: (): void => {
          this.showStopSheet = false
          // 面板关闭后恢复"3 秒后淡出"的计时（面板打开期间是暂停计时的）
          this.scheduleChromeHide()
        }
      })
    }
    }
    // 沉浸态唤回：点屏幕任意位置 → 控件淡入 + 重新开始 3 秒计时。
    // 子组件命中时父级 onClick 不触发，故点按钮仍是各自功能，点空白才是"唤出"；
    // 触摸与点击都挂上（onTouch 还能覆盖"按着按钮"的情形），两者都是幂等的，不会冲突。
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down) {
        this.revealChrome()
      }
    })
    .onClick((): void => {
      this.revealChrome()
    })
    // 实测视口尺寸：横竖版式判定的唯一来源。
    // 挂在全屏 Stack 上（宽度由窗口决定），不随内部 Flex 方向切换而变化，故无回环风险。
    .onAreaChange((_oldArea: Area, newArea: Area): void => {
      const w: number = Number(newArea.width)
      const h: number = Number(newArea.height)
      if (!Number.isNaN(w) && !Number.isNaN(h)) {
        this.viewW = w
        this.viewH = h
      }
    })
    .width('100%')
    .height('100%')
  }

  /* ============================================================
   * 大环沉浸版（3）：环尺寸 / 线宽 / 字号 —— 全部由视口推导
   * 统一用 Math.round 落整数，避免 Progress 线宽出现半像素导致边缘发毛
   * ============================================================ */

  /**
   * 竖屏运行态环直径
   * - 基准：视口短边 × 0.78（对齐图片稿的 0.745）
   * - 再用"可用高度反推"封一次顶：竖屏是 Column{环, 按钮} 竖排，
   *   扣掉顶部让位的状态栏、按钮带、底部安全区、上下呼吸余量后才是环的真正上限。
   *   短边机型（如 330×720）上 0.78 会算出 257，加上按钮带仍有余量，故保留原比例值。
   * - ⚠️ 不可把按钮改成"底部悬浮不参与竖排"从而把环放到 0.90：
   *   图片稿明确要求按钮在环正下方居中（改做悬浮会与图稿不符）。
   */
  private runningRingSize(): number {
    const short: number = this.viewW > 0 && this.viewH > 0
      ? Math.min(this.viewW, this.viewH)
      : 0
    if (short <= 0) return 280
    const byRatio: number = short * PORTRAIT_RING_RATIO_RUNNING
    const byHeight: number = this.viewH - safeAreaHelper.statusBar
      - PORTRAIT_BUTTON_BAND - 20 - 16 - safeAreaHelper.bottom
    return Math.round(Math.max(180, Math.min(byRatio, byHeight)))
  }

  /** 竖屏待机态环直径：略小于运行态，给时长胶囊与开始按钮留位置 */
  private idleRingSize(): number {
    const short: number = this.viewW > 0 && this.viewH > 0
      ? Math.min(this.viewW, this.viewH)
      : 0
    if (short <= 0) return 250
    return Math.round(short * PORTRAIT_RING_RATIO_IDLE)
  }

  /**
   * 横屏双圆直径（v4，左分圆 / 右秒圆等径）
   * - 横向：`圆 × 2 + 空隙 × 2 + 竖线 1 ≤ 长边 − 左右安全 − 圆间空隙`
   * - 纵向：`圆 ≤ 短边 − 状态栏 − 余量 − 底部按钮带`（**v4 起下方又有胶囊按钮了**）
   * - 取两者较小者再乘 0.92 留白；已按 330/360/381/400/700 复核
   * ⚠️ 圆**不可点击**（唯一操作入口是下方胶囊），故不再是"命中区最小尺寸"的约束方；
   *    但仍是主视觉，横向反推已确保它在任何机型上都吃满可用宽度
   */
  private landscapeDualSize(): number {
    const longSide: number = Math.max(this.viewW, this.viewH)
    const short: number = this.viewW > 0 && this.viewH > 0
      ? Math.min(this.viewW, this.viewH)
      : 0
    if (short <= 0) return 240
    const gap: number = Math.max(LANDSCAPE_DUAL_GAP_MIN, Math.round(short * 0.05))
    const byWidth: number = (longSide - LANDSCAPE_DUAL_SIDE_PAD - LANDSCAPE_DUAL_INNER_PAD - gap * 2 - 1) / 2
    const byHeight: number = short - safeAreaHelper.statusBar - LANDSCAPE_RING_MARGIN - LANDSCAPE_BUTTON_BAND
    const raw: number = Math.min(byWidth, byHeight) * LANDSCAPE_DUAL_RATIO
    return Math.round(Math.max(90, raw))
  }

  /** 横屏双圆之间的水平间距（由短边推导，与 landscapeDualSize 同一公式保证一致） */
  private landscapeDualGap(): number {
    const short: number = this.viewW > 0 && this.viewH > 0
      ? Math.min(this.viewW, this.viewH)
      : 0
    if (short <= 0) return 20
    return Math.max(LANDSCAPE_DUAL_GAP_MIN, Math.round(short * 0.05))
  }

  /** 环线宽：直径 × 4.8%，钳在 [8, 14] —— 小环不变细、大环不变粗 */
  private ringStroke(size: number): number {
    const raw: number = Math.round(size * RING_STROKE_RATIO)
    return Math.max(RING_STROKE_MIN, Math.min(RING_STROKE_MAX, raw))
  }

  /** 主操作按钮直径：由环径推导（图片稿 0.256），钳在 [46, 76] 保证任何机型上手可点 */
  private actionBtnSize(ring: number): number {
    const raw: number = Math.round(ring * ACTION_BTN_RING_RATIO)
    return Math.max(ACTION_BTN_MIN, Math.min(ACTION_BTN_MAX, raw))
  }

  /**
   * 横屏底部胶囊按钮（「暂停 / 继续」）尺寸 —— 由短边推导
   * - 宽 clamp(短边×0.34, 132, 210)：太窄显得小气、太宽会抢两个圆的视觉主体地位
   * - 高 clamp(短边×0.105, 46, 66)：**下限 46 是硬约束**（≥48vp 可点尺寸的近似，实际命中区含内边距更大）
   * ⚠️ 与 landscapeDualSize() 里的 LANDSCAPE_BUTTON_BAND 必须同源：纵向反推用的是**上限** 66，
   *    这里是实际值，故任何机型都只会"余量更多"，不会溢出
   */
  private landscapeActionWidth(): number {
    const short: number = this.viewW > 0 && this.viewH > 0
      ? Math.min(this.viewW, this.viewH)
      : 0
    if (short <= 0) return 150
    return Math.round(Math.max(LANDSCAPE_ACTION_W_MIN, Math.min(LANDSCAPE_ACTION_W_MAX, short * LANDSCAPE_ACTION_W_RATIO)))
  }

  private landscapeActionHeight(): number {
    const short: number = this.viewW > 0 && this.viewH > 0
      ? Math.min(this.viewW, this.viewH)
      : 0
    if (short <= 0) return 48
    return Math.round(Math.max(LANDSCAPE_ACTION_H_MIN, Math.min(LANDSCAPE_ACTION_H_MAX, short * LANDSCAPE_ACTION_H_RATIO)))
  }

  /**
   * 停止二次确认（竖屏 / 横屏共用；停止会丢弃当前轮次，误触代价高）
   */
  private askStopConfirm(): void {
    this.stopSheetTitle = getContext(this).resourceManager.getStringSync($r('app.string.pomo_stop_confirm_message').id)
    this.stopSheetItems = [
      {
        label: getContext(this).resourceManager.getStringSync($r('app.string.pomo_stop').id),
        danger: true,
        action: (): void => {
          pomodoroService.stop()
          // 停止后同步关闭沉浸屏：停留 idle 态会迫使用户按返回退出，
          // 而返回退出曾把可见标志残留在 Service，导致之后打开任意任务详情被全屏番茄钟覆盖
          pomodoroService.hideImmersive()
          promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.pomo_stopped_toast').id), duration: 1500 })
        }
      }
    ]
    this.showStopSheet = true
  }

  /**
   * 环内阶段标签用色（图片稿 v2：标签是**深色文字**，不是阶段主色）
   * - 图上「专注中」写在环内的浅色圆心里，用近黑的深灰，与巨大的深色数字同一套文字色
   * - 取 text_strong（E6FFFFFF，近白）而非 accent：环内背景是深色渐变，浅色字才可读；
   *   accent 留给进度弧——标签也用 accent 会和弧线抢注意力
   */
  private phaseLabelColor(): Resource {
    return $r('app.color.pomo_immersive_text_strong')
  }

  /** 阶段标签（环内上缘，图片稿的「专注中」；不占环外空间） */
  @Builder
  ringPhaseLabel(size: number) {
    Text(this.phaseTagLabel())
      .fontSize(Math.round(size * RING_PHASE_LABEL_RATIO))
      .fontWeight(FontWeight.Medium)
      .fontColor(this.phaseLabelColor())
      .letterSpacing(2)
      .opacity(0.75)
  }

  /**
   * 环内时间·竖屏（分上 / 秒下）
   * - 几何依据：环撑满短边后内接正方形 ≈ 环 × 0.707，横排「24:58」每字仅 50vp 会发扁；
   *   上下排每行只用 2 个字符 → 每字可用宽度翻倍 → 字号可做到环的 0.23（≈67fp，原 46fp 的 1.46 倍）
   * - 分与秒**同号**（对齐图片稿：两行等大，靠上下位置而非字号区分主次）
   * - ⚠️ 水平方向**不是**约束（2 字 × 0.6em ≈ 1.2em，远小于内接方），**竖直方向才是瓶颈**：
   *   标签 + 两行数字必须整体塞进内接正方形，否则左右两侧会压到弧线。
   *   故整块**不做任何额外下移**（历史上这里下移过 size*0.05，正是压线余量的 2 倍量级，
   *   且 Column 已在环内竖直居中，额外偏移只会破坏居中）。改动前请跑
   *   `docs/上架素材/check_pomo_ring_text_fit.py` 复核全机型余量 > 0。
   * - ⚠️ monospace 必须保留：不等宽会让整块数字每秒左右抖动，在 67fp 的大字上极其明显
   */
  @Builder
  ringTimeStacked(size: number) {
    Column({ space: PORTRAIT_TIME_LINE_GAP }) {
      Text(this.splitMinuteText(this.remainingMillis))
        .fontSize(Math.round(size * PORTRAIT_MINUTE_RATIO))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.pomo_immersive_text_strong'))
        .fontFamily('monospace')
        .letterSpacing(1)

      Text(this.splitSecondText(this.remainingMillis))
        .fontSize(Math.round(size * PORTRAIT_SECOND_RATIO))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.pomo_immersive_text_strong'))
        .fontFamily('monospace')
        .letterSpacing(1)
    }
    .opacity(this.state === 'paused' ? 0.55 : 1)
  }

  /**
   * 横屏·分圆（图片稿左圆）：**只有一根细描边，没有进度弧**，圆内是巨大的分钟数字
   * - 细描边是刻意的：与右侧秒圆的粗进度弧形成"一静一动"的对比，是图片稿最关键的视觉语言
   * - 显示**剩余分钟**（`minuteCircleText()`；待机态显示所选时长），与右侧剩余秒数同向递减
   * - **纯显示，不可点击**（唯一操作入口是下方胶囊按钮）
   */
  @Builder
  landscapeMinuteCircle(size: number) {
    Stack({ alignContent: Alignment.Center }) {
      Circle({ width: size, height: size })
        .fill(Color.Transparent)
        .stroke($r('app.color.pomo_immersive_text_faint'))
        .strokeWidth(LANDSCAPE_THIN_STROKE)

      Text(this.minuteCircleText())
        .fontSize(Math.round(size * LANDSCAPE_TIME_RATIO))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.pomo_immersive_text_strong'))
        .fontFamily('monospace')
        .letterSpacing(1)
        .opacity(this.state === 'paused' ? 0.55 : 1)
    }
    .width(size)
    .height(size)
  }

  /**
   * 横屏·秒圆（图片稿右圆）：**带进度弧**，圆内是巨大的秒钟数字
   * - 进度弧 = 整体剩余进度（progressValue），不是"当前这一分钟内的进度"
   * - **纯显示，不可点击**（v4 纠正）：原先把秒圆当"暂停/继续按钮"用，导致
   *   ① 被挂上 chromeOpacity 后运行中 3 秒自动淡出（用户：「秒钟怎么能淡化」）
   *   ② 淡出后还需要 enabled(false) 防误触 —— 现在整个问题不存在了
   * - ⚠️ 禁止给圆加 .shadow()：阴影按组件矩形边界投射，会在圆外投出方框（真机复现过）
   */
  @Builder
  landscapeSecondCircle(size: number) {
    Stack({ alignContent: Alignment.Center }) {
      // 轨道
      Progress({ value: 100, total: 100, type: ProgressType.Ring })
        .width(size).height(size)
        .color($r('app.color.pomo_immersive_track'))
        .backgroundColor(Color.Transparent)
        .style({ strokeWidth: this.ringStroke(size) })
        .opacity(this.state === 'paused' ? 0.55 : 1)

      // 进度弧
      Progress({ value: this.progressValue, total: 100, type: ProgressType.Ring })
        .width(size).height(size)
        .color(this.phaseAccent())
        .backgroundColor(Color.Transparent)
        .style({ strokeWidth: this.ringStroke(size) })
        .opacity(this.state === 'paused' ? 0.55 : 1)

      Text(this.splitSecondText(this.remainingMillis))
        .fontSize(Math.round(size * LANDSCAPE_TIME_RATIO))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.pomo_immersive_text_strong'))
        .fontFamily('monospace')
        .letterSpacing(1)
        .opacity(this.state === 'paused' ? 0.55 : 1)
    }
    .width(size)
    .height(size)
  }

  /** 中间竖直分隔线（图片稿细节）：1vp 宽、高 = 圆径 × 0.42、低透明度，纯装饰 */
  @Builder
  landscapeDivider(circle: number) {
    Divider()
      .vertical(true)
      .height(Math.round(circle * LANDSCAPE_DIVIDER_RATIO))
      .strokeWidth(1)
      .color($r('app.color.pomo_immersive_text_faint'))
  }

  /**
   * 横屏底部胶囊按钮（图片稿：两个大圆**下方**的「暂停 / 继续」）
   * - 这是横屏**唯一可点击**的元素；两个圆都是纯显示
   * - 图标语义与竖屏 primaryActionButton 完全一致：running → ❚❚ 暂停，其余 → ▶ 继续/开始
   * - 淡出：挂在按钮自身的 `chromeOpacity + chromeHitTest + enabled(chromeVisible)` 三件套上
   *   ⚠️ 三件套缺一不可：`hitTestBehavior(None)` 只让自身不参与命中，子节点仍可命中；
   *      必须再 `enabled(false)` 才能让整棵子树失效，且不影响祖先的"点击唤回"。
   * - 长按 800ms = 停止（与竖屏主操作钮一致，保证"停止"始终可触达）
   */
  @Builder
  landscapeActionButton() {
    Row({ space: 8 }) {
      // ❚❚ 暂停图标
      SymbolGlyph($r('sys.symbol.pause_fill'))
        .fontSize(Math.round(this.landscapeActionHeight() * 0.42))
        .fontColor([$r('app.color.pomo_immersive_text_strong')])
        .opacity(this.state === 'running' ? 1 : 0)
        .animation({ duration: 180, curve: Curve.EaseInOut })

      // ▶ 继续 / 开始图标
      SymbolGlyph($r('sys.symbol.play_fill'))
        .fontSize(Math.round(this.landscapeActionHeight() * 0.42))
        .fontColor([$r('app.color.pomo_immersive_text_strong')])
        .opacity(this.state === 'running' ? 0 : 1)
        .animation({ duration: 180, curve: Curve.EaseInOut })

      Text(this.state === 'running'
        ? getContext(this).resourceManager.getStringSync($r('app.string.pomo_pause').id)
        : getContext(this).resourceManager.getStringSync($r('app.string.pomo_resume').id))
        .fontSize(CommonConstants.FONT_SIZE_BODY)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.pomo_immersive_text_strong'))
    }
    .width(this.landscapeActionWidth())
    .height(this.landscapeActionHeight())
    .justifyContent(FlexAlign.Center)
    .borderRadius(this.landscapeActionHeight() / 2)
    .backgroundColor(this.phaseAccent())
    .shadow({ radius: 18, color: $r('app.color.pomo_immersive_focus_shadow'), offsetX: 0, offsetY: 6 })
    .scale({
      x: this.pressedBtn === 'primary' ? 0.96 : 1,
      y: this.pressedBtn === 'primary' ? 0.96 : 1
    })
    .onTouch((event: TouchEvent): void => {
      this.setPressedBtn('primary', event)
    })
    .gesture(
      LongPressGesture({ repeat: false, duration: 800 })
        .onAction((): void => {
          if (this.state === 'running' || this.state === 'paused') {
            this.askStopConfirm()
          }
        })
    )
    .onClick((): void => {
      if (this.state === 'running') {
        pomodoroService.pause()
      } else if (this.state === 'paused') {
        pomodoroService.resume()
      } else {
        pomodoroService.startFocus(this.taskId, this.taskTitle,
          this.selectedFocusMinutes, this.selectedBreakMinutes,
          this.selectedLongBreakMinutes, this.selectedCycleLength)
        this.saveDurationPrefs()
      }
    })
    .opacity(this.chromeOpacity)
    .hitTestBehavior(this.chromeHitTest)
    .enabled(this.chromeVisible)
    .animation({ duration: CHROME_FADE_MILLIS, curve: Curve.EaseOut })
  }

  /**
   * 横屏主体（待机 / 运行共用同构版式）· 方案 A（2026-09-15 用户拍板）
   *   `[分圆（细描边·剩余分钟）] 竖线 [秒圆（进度弧·剩余秒数）]`
   *   `            [ 暂停 / 继续 胶囊 ]  ← 随控件自动淡出`
   * - **按钮位置 = 两圆水平中点的正下方**（不是秒圆下面）：左右两圆整体居中，竖线落在屏幕中线，
   *   按钮也锚在屏幕中线 —— 三者共用同一条竖直轴线，视觉上按钮属于"两个时间中间"而非某一侧。
   * - 待机态：左圆显示所选时长、右圆显示 00 且进度弧为 0；点胶囊 = 开始专注
   * - 运行态：左分（剩余）右秒（剩余）同向递减；点胶囊 = 暂停 / 继续，长按 = 停止
   * - ⚠️ **两个圆都是纯显示**：v3 曾让秒圆整圆可点，结果它被当成"控件"挂上自动淡出，
   *   运行 3 秒后右圆凭空消失（用户：「秒钟怎么能淡化，不对吧」）。v4 把操作入口
   *   收敛回**底部这一枚胶囊**，淡出只作用于它 —— 与竖屏主操作钮完全同构。
   */
  @Builder
  landscapeDual() {
    Column() {
      Blank().layoutWeight(1)

      Row({ space: this.landscapeDualGap() }) {
        this.landscapeMinuteCircle(this.landscapeDualSize())

        this.landscapeDivider(this.landscapeDualSize())

        this.landscapeSecondCircle(this.landscapeDualSize())
      }
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)

      // 操作按钮：**水平锚定在两圆中点（= 屏幕中线 = 中间那根竖线）的正下方**
      // ⚠️ 必须显式 `width('100%') + alignItems(Center)`，**不可**只依赖外层 Column 的 alignItems
      //    —— "按钮在两圆中间"是图片稿硬约束（2026-09-15 用户拍板「放在这俩时间的中间，
      //    不是秒钟下面」）。隐式依赖一旦外层布局被改动，按钮就会悄悄偏到某一侧。
      //    check_pomo_immersive.py 里有对应断言守着这条。
      Column() {
        this.landscapeActionButton()
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .margin({ top: LANDSCAPE_ACTION_GAP })

      Blank().layoutWeight(1)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 待机计时环（轨道 + 阶段标签 + 所选时长）
   * 设计取舍（2026-09-14 定，对齐业界同类）：
   * - **只画一个环**。原先轨道外再套一圈 size+24 的细"呼吸外环" → 两个同心圆错位，
   *   正是"看着别扭"的主因，已删。
   * - 呼吸改用轨道自身的明暗（0.5 ↔ 1.0）承担，含蓄且不产生任何几何位移。
   * - 待机态没有进度可画，就保持一条极淡的完整轨道（与 iOS 计时器待机观感一致）。
   * @param size 环直径（vp）
   */
  @Builder
  idleRing(size: number) {
    Stack({ alignContent: Alignment.Center }) {
      Progress({ value: 100, total: 100, type: ProgressType.Ring })
        .width(size).height(size)
        .color($r('app.color.pomo_immersive_track'))
        .backgroundColor(Color.Transparent)
        .style({ strokeWidth: this.ringStroke(size) })
        .opacity(this.breathOpacity)
        .animation({ duration: 2000, curve: Curve.EaseInOut })

      Column() {
        Text($r('app.string.pomo_ready_to_focus'))
          .fontSize(Math.round(size * RING_PHASE_LABEL_RATIO))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.pomo_immersive_text_strong'))
          .letterSpacing(2)
          .opacity(0.75)

        // 待机态没有"倒计时在走"的语义，显示所选专注时长（分上秒下，秒位固定 00，与图片稿同构）
        Column({ space: PORTRAIT_TIME_LINE_GAP }) {
          Text(this.selectedFocusMinutes.toString().padStart(2, '0'))
            .fontSize(Math.round(size * PORTRAIT_MINUTE_RATIO))
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.pomo_immersive_text_strong'))
            .fontFamily('monospace')
            .letterSpacing(1)
          Text('00')
            .fontSize(Math.round(size * PORTRAIT_SECOND_RATIO))
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.pomo_immersive_text_strong'))
            .fontFamily('monospace')
            .letterSpacing(1)
        }
      }
    }
    .width(size)
    .height(size)
  }

  /**
   * 运行态计时环（**仅竖屏**：轨道 → 进度 → 阶段标签 + 分上秒下）
   * 设计取舍（2026-09-14 定，对齐业界同类）：
   * - 删掉原"柔光层"（strokeWidth 22 的低透明度粗环）——它与细进度弧形成巨大粗细反差，
   *   是环"糊成一团"的根源；业界同类产品均只有"轨道 + 进度"两层。
   * - 轨道与进度同线宽，进度弧精确覆盖轨道，视觉上就是"同一条线在走"。
   * - 暂停时轨道与进度**一起**降透明度：底色不降会让"已暂停"的进度弧看着仍在亮（历史问题）
   * ⚠️ 横屏不走这里：横屏是"双圆"版式（见 landscapeMinuteCircle / landscapeSecondCircle）
   * ⚠️ 禁止给圆环加 .shadow()：阴影按组件矩形边界投射，会在环外投出方框（真机复现过）
   * @param size 环直径（vp）
   */
  @Builder
  runningRing(size: number) {
    Stack({ alignContent: Alignment.Center }) {
      // 轨道层（与进度层同透明度，暂停时一起变暗）
      Progress({ value: 100, total: 100, type: ProgressType.Ring })
        .width(size).height(size)
        .color($r('app.color.pomo_immersive_track'))
        .backgroundColor(Color.Transparent)
        .style({ strokeWidth: this.ringStroke(size) })
        .opacity(this.state === 'paused' ? 0.55 : 1)

      // 进度层
      Progress({ value: this.progressValue, total: 100, type: ProgressType.Ring })
        .width(size).height(size)
        .color(this.phaseAccent())
        .backgroundColor(Color.Transparent)
        .style({ strokeWidth: this.ringStroke(size) })
        .opacity(this.state === 'paused' ? 0.55 : 1)

      // 环内：阶段标签（上）+ 分上秒下
      Column() {
        this.ringPhaseLabel(size)
        this.ringTimeStacked(size)
      }
    }
    .width(size)
    .height(size)
  }

  /**
   * 单个主操作钮（圆形图标钮，**仅竖屏使用**）
   *
   * 图标语义按状态三选一：
   * - `running`   → ❚❚ 暂停
   * - `paused`    → ▶ 继续
   * - 其他（完成一轮后停留的态）→ ▶ 开始下一轮
   *
   * ⚠️ 图标交叉淡入淡出而非"换符号瞬变"：两个 SymbolGlyph 叠在同一个 Stack 里，
   *    用 opacity 切换（都带 .animation）→ 状态切换时是柔和淡入淡出，不是硬跳。
   * ⚠️ 停止**没有**做成第二个按钮（图片稿只有两个圆钮，且"暂停/继续"与"停止"并排
   *    本来就属于互斥逻辑，参照截图里"暂停 + 继续"同时出现是错的）。
   *    停止路径：① 右上角 ✕（退出即结束）② 长按本按钮 800ms → 弹二次确认面板。
   */
  @Builder
  primaryActionButton(ring: number) {
    Stack({ alignContent: Alignment.Center }) {
      // ❚❚ 暂停图标
      SymbolGlyph($r('sys.symbol.pause_fill'))
        .fontSize(Math.round(this.actionBtnSize(ring) * ACTION_ICON_BTN_RATIO))
        .fontColor([$r('app.color.pomo_immersive_text_strong')])
        .opacity(this.state === 'running' ? 1 : 0)
        .animation({ duration: 180, curve: Curve.EaseInOut })

      // ▶ 继续 / 开始下一轮图标
      SymbolGlyph($r('sys.symbol.play_fill'))
        .fontSize(Math.round(this.actionBtnSize(ring) * ACTION_ICON_BTN_RATIO))
        .fontColor([$r('app.color.pomo_immersive_text_strong')])
        .opacity(this.state === 'running' ? 0 : 1)
        .animation({ duration: 180, curve: Curve.EaseInOut })
    }
    .width(this.actionBtnSize(ring))
    .height(this.actionBtnSize(ring))
    .borderRadius(this.actionBtnSize(ring) / 2)
    // 图片稿的主操作钮是**实心主色圆**（不是描边圆），与右侧"继续"的空心描边钮形成主次
    .backgroundColor(this.phaseAccent())
    .shadow({ radius: 18, color: $r('app.color.pomo_immersive_focus_shadow'), offsetX: 0, offsetY: 6 })
    .scale({
      x: this.pressedBtn === 'primary' ? 0.94 : 1,
      y: this.pressedBtn === 'primary' ? 0.94 : 1
    })
    .animation({ duration: 100, curve: Curve.EaseOut })
    .onTouch((event: TouchEvent): void => {
      this.setPressedBtn('primary', event)
    })
    .gesture(
      // 长按 800ms = 停止（保持"停止可触达"同时不牺牲极简版式）
      LongPressGesture({ repeat: false, duration: 800 })
        .onAction((): void => {
          if (this.state === 'running' || this.state === 'paused') {
            this.askStopConfirm()
          }
        })
    )
    .onClick((): void => {
      if (this.state === 'running') {
        pomodoroService.pause()
      } else if (this.state === 'paused') {
        pomodoroService.resume()
      } else {
        pomodoroService.startFocus(this.taskId, this.taskTitle,
          this.selectedFocusMinutes, this.selectedBreakMinutes,
          this.selectedLongBreakMinutes, this.selectedCycleLength)
        this.saveDurationPrefs()
      }
    })
    .opacity(this.chromeOpacity)
    .hitTestBehavior(this.chromeHitTest)
    // ⚠️ 淡出后必须 enabled(false)：否则隐形按钮会抢走"点击唤回"的那一次点击（会真的暂停）
    .enabled(this.chromeVisible)
    .animation({ duration: CHROME_FADE_MILLIS, curve: Curve.EaseOut })
  }

  @Builder
  idleContent() {
    Scroll() {
      Column() {
        Blank().layoutWeight(0.6)

        // 待机计时环（大环版：直径由视口短边推导；横屏走 landscapeDual 的双圆版式）
        this.idleRing(this.idleRingSize())

        // 单个主操作钮：紧贴环下方居中（与运行态同一位置，状态切换时不跳动）
        Column() {
          this.primaryActionButton(this.idleRingSize())
        }
        .margin({ top: 20 })

        // 任务名 / 时长胶囊 / 轮次 / 今日统计（仅竖屏可见，横屏一律回竖屏设置）
        Text(this.taskTitle.length > 0 ? this.taskTitle :
          getContext(this).resourceManager.getStringSync($r('app.string.pomo_focus_now').id))
          .fontSize(CommonConstants.FONT_SIZE_BODY)
          .fontColor($r('app.color.pomo_immersive_text_medium'))
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 16, bottom: 20 })
          .padding({ left: 32, right: 32 })

        Blank().layoutWeight(0.4)

        Column({ space: 20 }) {
          // 注意：不传选中值/颜色，Builder 内直读 this.selected*（见 inlineChips 注释）
          this.inlineChips(true)

          this.inlineChips(false)

          Row({ space: 6 }) {
            ForEach([1, 2, 3, 4], (dotIndex: number): void => {
              Circle({ width: 6, height: 6 })
                .fill(dotIndex <= this.currentRoundInCycle()
                  ? $r('app.color.pomo_immersive_dot_active')
                  : $r('app.color.pomo_immersive_dot_inactive'))
            }, (dotIndex: number): string => dotIndex.toString())
            Text(getContext(this).resourceManager.getStringSync($r('app.string.pomo_cycle_label').id).replace('%d', this.selectedCycleLength.toString()))
              .fontSize(CommonConstants.FONT_SIZE_XXS)
              .fontColor($r('app.color.pomo_immersive_text_faint'))
          }

          // 今日统计（有数据才显示）
          if (this.todayStatsText().length > 0) {
            Text(this.todayStatsText())
              .fontSize(CommonConstants.FONT_SIZE_SMALL)
              .fontColor($r('app.color.pomo_immersive_text_faint'))
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .margin({ bottom: 32 + safeAreaHelper.bottom })
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  /**
   * 时长胶囊行（专注 / 休息共用）
   *
   * ⚠️ 依赖追踪坑位（本次修复的 bug 根因）：
   *   @Builder 的【基本类型形参是按值传递，不建立状态依赖】。原实现把选中值以
   *   `selectedMin: number` 形参传入，于是点击后选中高亮永远停在首帧；
   *   而同屏的计时数字是直读 this.selectedFocusMinutes 的，会出现
   *   “数字变了、高亮不变”的半更新态，看起来像坏了。
   *   修复：不传选中值，在 Builder 内【直接读】this.selectedFocusMinutes /
   *   this.selectedBreakMinutes。注意只有写在属性表达式里的直读才会被登记为依赖，
   *   包在方法里读（例如 this.getSelected()）不会触发刷新，不要再改回去。
   *
   * @param isFocusRow - true = 专注时长行，false = 休息时长行
   */
  @Builder
  inlineChips(isFocusRow: boolean) {
    Row({ space: 6 }) {
      ForEach(isFocusRow ? this.focusOptions : this.breakOptions, (opt: DurationOption): void => {
        Text(opt.label)
          .fontSize(CommonConstants.FONT_SIZE_CAPTION)
          .fontColor((isFocusRow ? this.selectedFocusMinutes : this.selectedBreakMinutes) === opt.minutes
            ? $r('app.color.pomo_immersive_text_strong')
            : $r('app.color.pomo_immersive_text_weak'))
          .fontWeight((isFocusRow ? this.selectedFocusMinutes : this.selectedBreakMinutes) === opt.minutes
            ? FontWeight.Medium : FontWeight.Normal)
          .padding({ left: 16, right: 16, top: 7, bottom: 7 })
          .borderRadius(DimensConstants.RADIUS_L)
          .backgroundColor((isFocusRow ? this.selectedFocusMinutes : this.selectedBreakMinutes) === opt.minutes
            ? (isFocusRow ? $r('app.color.pomo_immersive_chip_active_bg')
              : $r('app.color.pomo_immersive_chip_break_active_bg'))
            : $r('app.color.pomo_immersive_chip_bg'))
          .border({
            width: (isFocusRow ? this.selectedFocusMinutes : this.selectedBreakMinutes) === opt.minutes ? 1 : 0,
            color: (isFocusRow ? this.selectedFocusMinutes : this.selectedBreakMinutes) === opt.minutes
              ? (isFocusRow ? $r('app.color.pomo_immersive_chip_active_border')
                : $r('app.color.pomo_immersive_chip_break_active_border'))
              : Color.Transparent
          })
          .onClick((): void => {
            if (isFocusRow) {
              this.selectedFocusMinutes = opt.minutes
            } else {
              this.selectedBreakMinutes = opt.minutes
            }
          })
      }, (opt: DurationOption) => (isFocusRow ? 'focus_' : 'break_') + opt.label)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
  }

  /**
   * 竖屏运行/暂停态（图片稿 v2 版式）
   * - 结构：`Blank` + **环** + **按钮**（环正下方居中）+ `Blank`
   * - ⚠️ 按钮**不参与底部悬浮**：图片稿要求按钮紧跟圆环下方居中，故放进竖排流里；
   *   代价是环不能吃到 0.90（那会把按钮顶出屏幕），改由 runningRingSize() 双约束取 0.78。
   * - 删掉了阶段药丸 / 轮次点 / 任务名 / 今日统计：图上只留"环 + 按钮"，
   *   且环放大后没有空间容纳；信息可回任务详情查看。
   */
  @Builder
  runningContent() {
    Column() {
      Blank().layoutWeight(1)

      // 计时环：轨道 → 进度 → 环内阶段标签 + 分秒上下排
      // ⚠️ 禁止给圆环加 .shadow()：阴影按组件矩形边界投射，会在环外投出方框（真机复现）
      this.runningRing(this.runningRingSize())

      // 单个主操作钮：与环同一套圆形几何语言（图片稿的实心主色圆）
      Column() {
        this.primaryActionButton(this.runningRingSize())
      }
      .margin({ top: 24 })

      Blank().layoutWeight(1)

      // 底部安全区让位（导航条不与按钮重叠）
      Blank().height(safeAreaHelper.bottom)
    }
    .width('100%')
    .layoutWeight(1)
  }
}
