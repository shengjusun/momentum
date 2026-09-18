
import { AbilityConstant, UIAbility, Want, wantConstant } from '@kit.AbilityKit'
import { window } from '@kit.ArkUI'
import { BusinessError } from '@kit.BasicServicesKit'
import { CommonConstants } from '../common/constants/CommonConstants'
import { StorageManager } from '../common/utils/StorageManager'
import { settingsVM } from '../viewmodel/SettingsViewModel'
import { homeVM } from '../viewmodel/HomeViewModel'
import { routeVM } from '../viewmodel/RoutePageViewModel'
import { Logger } from '../common/utils/Logger'
import { safeAreaHelper } from '../common/utils/SafeAreaHelper'
import { deadlineReminderService } from '../common/services/DeadlineReminderService'
import { pomodoroService } from '../common/services/PomodoroService'
import { notificationCenterService } from '../common/services/NotificationCenterService'
import { DeepSeekService } from '../common/services/DeepSeekService'
import { globalNavStack, setMigrationPayload, getCurrentTabIndex, navigateToWithIdOnce, markPendingDeepLink } from '../common/RouterManager'
import { util } from '@kit.ArkTS';
import { CloudSdkService } from '../common/services/CloudSdkService'
import { FeedbackService } from '../common/services/FeedbackService'

/** 通知直达路由信息（冷启动暂存，待 UI 加载后执行） */
interface PendingNotificationRoute {
  routeName: string
  id: string
  /** true 表示落地即呼出全屏番茄钟（番茄钟倒计时通知专用） */
  openImmersive: boolean
}

/** 多端协同迁移负载 */
interface MigrationPayload {
  routeName: string
  param: string
  tabIndex: number
}

export default class EntryAbility extends UIAbility {
  private readonly tag: string = 'EntryAbility'
  /** 待执行的通知直达路由 */
  private pendingNotificationRoute: PendingNotificationRoute | null = null
  /** 热启动同步节流：上次 onNewWant 触发 triggerSync 的时刻（0 = 从未触发） */
  private lastHotStartSyncAt: number = 0

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    Logger.info(this.tag, 'onCreate, launchReason=' + launchParam.launchReason)
    // 隐私合规：want.parameters 在多端流转场景携带完整用户数据（migrationData），
    // 禁止走 Logger.info（%{public}s 公开可读）。debug 档为 %{private}s，release 掩码。
    Logger.debug(this.tag, 'want.parameters=' + JSON.stringify(want.parameters))
    // 优先级：通知直达 > 多端流转
    if (!this.extractNotificationRoute(want)) {
      this.extractMigrationData(want)
    }

    // 初始化所有服务，确保应用启动时就准备就绪
    this.initializeAppServices();
  }

  /**
   * 本地服务初始化（隐私合规拆分后仅保留本地链路）
   * 云端 SDK（AGC auth / CloudFoundationKit / CloudDB）不在冷启动初始化——
   * 必须等用户在 MainTab 同意《隐私协议》后，由 CloudSdkService 统一拉起。
   */
  private async initializeAppServices(): Promise<void> {
    try {
      // 1. 初始化本地存储
      await StorageManager.init(this.context);

      // 2. 初始化其他服务（如截止日期提醒）
      deadlineReminderService.init(this.context);

      // 3. 初始化番茄钟服务（前台计时 + 后台 reminderAgent + 通知）
      pomodoroService.init(this.context);

      // 3.1 初始化站内通知中心（展示/删除/直达）
      notificationCenterService.init(this.context);

      // 4. 初始化 DeepSeek 服务（注入 context 用于 i18n 资源读取；实际云端调用依赖隐私同意后的 CloudSdkService）
      DeepSeekService.getInstance().init(this.context);

      Logger.info(this.tag, 'Local application services initialized successfully');
    } catch (e) {
      Logger.error(this.tag, 'Error initializing application services: ' + (e as Error).message);
    }
  }


  onContinue(wantParam: Record<string, Object>): AbilityConstant.OnContinueResult {
    Logger.info(this.tag, 'onContinue')

    wantParam[wantConstant.Params.SUPPORT_CONTINUE_PAGE_STACK_KEY] = false

    let routeName: string = 'MainTab'
    let paramStr: string = '{}'
    let tabIndex: number = 0

    try {
      const pathStack: NavPathInfo[] = globalNavStack.getPathStack()
      if (Array.isArray(pathStack) && pathStack.length > 0) {
        const topPath: NavPathInfo = pathStack[pathStack.length - 1]
        if (topPath && typeof topPath.name === 'string' && topPath.name.length > 0) {
          routeName = topPath.name
        }
        if (topPath.param !== undefined && topPath.param !== null) {
          try {
            paramStr = JSON.stringify(topPath.param) ?? '{}'
          } catch (_e) {
            paramStr = '{}'
          }
        }
      } else {
        try {
          tabIndex = getCurrentTabIndex()
        } catch (_e) {
          tabIndex = 0
        }
      }
    } catch (_e) {
      Logger.warn(this.tag, 'onContinue: getPathStack failed')
    }

    const payload: MigrationPayload = {
      routeName: routeName,
      param: paramStr,
      tabIndex: tabIndex
    }

    const migrationData: string = JSON.stringify(payload)
    // 隐私合规：migrationData 是多端流转的完整载荷（路由 + 页面参数），
    // 与 onCreate/onNewWant 的 want.parameters 同级敏感 → 一律 debug（%{private}s），release 掩码
    Logger.debug(this.tag, 'onContinue: migrationData=' + migrationData)

    wantParam.routeName = routeName
    wantParam.param = paramStr
    wantParam.tabIndex = tabIndex

    const encoder: util.TextEncoder = new util.TextEncoder()
    const encoded: Uint8Array = encoder.encodeInto(migrationData)
    wantParam.migrationData = encoded.buffer as ArrayBuffer

    Logger.info(this.tag, 'onContinue: routeName=' + routeName + ', tabIndex=' + tabIndex)
    return AbilityConstant.OnContinueResult.AGREE
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    Logger.info(this.tag, 'onNewWant, launchReason=' + launchParam.launchReason)
    // 隐私合规：同 onCreate —— parameters 可能含完整流转数据，降 debug（%{private}s）
    Logger.debug(this.tag, 'want.parameters=' + JSON.stringify(want.parameters))
    // 优先级：通知直达 > 多端流转
    // 热启动时 UI 已加载，解析后立即跳转
    if (!this.extractNotificationRoute(want)) {
      this.extractMigrationData(want)
    } else {
      this.executeNotificationRoute()
    }
    // 热启动并集合并刷新（方案A）：不无脑用云端覆盖本地，两端独有数据都保留
    // 冷启动已由 settingsVM.init() → syncNow('cold-start') 触发，就绪后由 notifyCloudReady 补跑
    // 节流：triggerSync 自身只有 1s 防抖，点 N 次通知（间隔 >1s）= N 次全量云往返 →
    // 30s 窗口内只触发一次；窗口内的本地变更由 SYNC_NEEDED 脏标记 + 2s 防抖兜底，不会丢
    const nowMs: number = Date.now()
    if (nowMs - this.lastHotStartSyncAt >= CommonConstants.HOT_START_SYNC_THROTTLE_MS) {
      this.lastHotStartSyncAt = nowMs
      settingsVM.triggerSync()
    } else {
      Logger.info(this.tag, 'onNewWant: triggerSync throttled (<' +
        CommonConstants.HOT_START_SYNC_THROTTLE_MS.toString() + 'ms since last)')
    }

    // 番茄钟运行中检测：热启动时若专注进行中，自动呼出沉浸屏
    this.restorePomodoroImmersiveIfNeeded()
  }

  /**
   * 番茄钟沉浸屏恢复
   * 热启动时若番茄钟运行中，导航到对应任务详情页（页面内番茄钟卡片会显示进行中状态）
   *
   * ⚠️ 这里【不】自动 showImmersive：用户自己回前台被打断体验差，
   *    且全局可见标志残留曾导致"打开任意任务详情都被番茄钟覆盖"。
   *    需要"落地即全屏"的只有一种情况——用户主动点番茄钟通知，
   *    那条路径由 executeNotificationRoute 依据 openImmersive 标记显式呼出。
   */
  private restorePomodoroImmersiveIfNeeded(): void {
    try {
      if (!pomodoroService.isRunning()) {
        return
      }
      const session = pomodoroService.getCurrentSession()
      if (session === null) {
        return
      }
      Logger.info(this.tag, 'restorePomodoroImmersiveIfNeeded: pomodoro running, taskId=' + session.taskId)

      // 检查页面栈顶是否已是 TaskDetailPage，避免重复压栈
      // 注意这里【只比路由名、不比 id】是刻意的：栈顶已是"某个任务的详情页"时就不打扰用户，
      // 若改成 name+id 比较，会在"番茄钟跑 B、用户正在看 A 的详情"时把页面替用户换掉。
      const pathStack: NavPathInfo[] = globalNavStack.getPathStack()
      if (Array.isArray(pathStack) && pathStack.length > 0) {
        const topPath: NavPathInfo = pathStack[pathStack.length - 1]
        if (topPath && typeof topPath.name === 'string' && topPath.name === 'TaskDetailPage') {
          Logger.info(this.tag, 'restorePomodoroImmersiveIfNeeded: already on TaskDetailPage, skip')
          return
        }
      }

      // 导航到 TaskDetailPage（携带 taskId，页面从 homeVM 反查构造数据）；幂等跳转避免重复压栈
      navigateToWithIdOnce('TaskDetailPage', session.taskId)
      Logger.info(this.tag, 'restorePomodoroImmersiveIfNeeded: navigate to TaskDetailPage')
    } catch (e) {
      Logger.warn(this.tag, 'restorePomodoroImmersiveIfNeeded failed: ' + (e as Error).message)
    }
  }

  private extractMigrationData(want: Want): void {
    if (!want.parameters) {
      Logger.info(this.tag, 'extractMigrationData: no parameters')
      return
    }
    try {
      const params: Record<string, Object> = want.parameters
      Logger.info(this.tag, 'extractMigrationData: keys=' + Object.keys(params).join(','))

      const migrationDataRaw: Object | undefined = params.migrationData
      if (migrationDataRaw !== undefined && migrationDataRaw !== null) {
        try {
          let jsonStr: string = ''
          if (migrationDataRaw instanceof ArrayBuffer) {
            const bytes: Uint8Array = new Uint8Array(migrationDataRaw)
            const decoder: util.TextDecoder = util.TextDecoder.create('utf-8')
            jsonStr = decoder.decodeToString(bytes)
          } else if (typeof migrationDataRaw === 'string') {
            jsonStr = migrationDataRaw
          }
          if (jsonStr.length > 0) {
            const parsed: Record<string, Object> = JSON.parse(jsonStr) as Record<string, Object>
            const routeName: string = (parsed.routeName as string) ?? 'MainTab'
            const paramStr: string = (parsed.param as string) ?? '{}'
            const tabIndex: number = (parsed.tabIndex as number) ?? 0
            setMigrationPayload({ routeName, param: paramStr, tabIndex })
            markPendingDeepLink()
            Logger.info(this.tag, 'extractMigrationData from migrationData SUCCESS: routeName=' + routeName)
            return
          }
        } catch (e) {
          Logger.warn(this.tag, 'extractMigrationData: migrationData parse failed: ' + (e as Error).message)
        }
      }

      const routeName: string = this.decodeParamValue(params.routeName)
      if (routeName.length === 0) {
        Logger.info(this.tag, 'extractMigrationData: routeName is empty, skip')
        return
      }
      const paramStr: string = this.decodeParamValue(params.param)
      let tabIndex: number = 0
      const tabIndexVal: Object | undefined = params.tabIndex
      if (typeof tabIndexVal === 'number') {
        tabIndex = tabIndexVal
      } else if (typeof tabIndexVal === 'string') {
        tabIndex = parseInt(tabIndexVal, 10) || 0
      }
      setMigrationPayload({ routeName, param: paramStr, tabIndex })
      markPendingDeepLink()
      Logger.info(this.tag, 'extractMigrationData from keys SUCCESS: routeName=' + routeName)
    } catch (_e) {
      Logger.warn(this.tag, 'extractMigrationData failed')
    }
  }

  private decodeParamValue(value: Object | undefined): string {
    if (value === undefined || value === null) {
      return ''
    }
    if (typeof value === 'string') {
      return value
    }
    if (value instanceof ArrayBuffer) {
      try {
        const bytes: Uint8Array = new Uint8Array(value)
        let result: string = ''
        for (let i: number = 0; i < bytes.length; i++) {
          result += String.fromCharCode(bytes[i])
        }
        return result
      } catch (_e) {
        return ''
      }
    }
    if (typeof value === 'object') {
      try {
        return JSON.stringify(value)
      } catch (_e) {
        return ''
      }
    }
    return ''
  }

  /**
   * 解析通知直达路由
   * 通知 Want 携带 parameters: { routeName: 'GoalDetailPage'|'TaskDetailPage', goalId|taskId: xxx }
   * 区别于多端协同迁移（携带 migrationData / param / tabIndex）
   *
   * @param want - 启动 Want
   * @returns true 表示为通知直达场景，已暂存路由；false 表示非通知场景
   */
  private extractNotificationRoute(want: Want): boolean {
    if (!want.parameters) {
      return false
    }
    try {
      const params: Record<string, Object> = want.parameters
      const routeName: string = this.decodeParamValue(params.routeName)

      if (routeName === 'GoalDetailPage') {
        const goalId: string = this.decodeParamValue(params.goalId)
        if (goalId.length > 0) {
          this.pendingNotificationRoute = { routeName: routeName, id: goalId, openImmersive: false }
          markPendingDeepLink()
          Logger.info(this.tag, 'extractNotificationRoute: goal detail, goalId=' + goalId)
          return true
        }
      }

      if (routeName === 'TaskDetailPage') {
        const taskId: string = this.decodeParamValue(params.taskId)
        if (taskId.length > 0) {
          const openImmersive: boolean = this.decodeParamValue(params.openImmersive) === '1'
          this.pendingNotificationRoute = {
            routeName: routeName, id: taskId, openImmersive: openImmersive
          }
          markPendingDeepLink()
          Logger.info(this.tag, 'extractNotificationRoute: task detail, taskId=' + taskId +
            ', openImmersive=' + openImmersive.toString())
          return true
        }
      }

      return false
    } catch (_e) {
      Logger.warn(this.tag, 'extractNotificationRoute failed: ' + (_e as Error).message)
      return false
    }
  }

  /**
   * 执行暂存的通知直达路由跳转
   * 冷启动：在 loadContent 回调中延迟调用（等待 MainTab 渲染）
   * 热启动：在 onNewWant 中直接调用
   */
  private executeNotificationRoute(): void {
    if (this.pendingNotificationRoute === null) {
      return
    }
    const route: PendingNotificationRoute = this.pendingNotificationRoute
    this.pendingNotificationRoute = null
    try {
      // 幂等跳转：栈顶已是同一 (route, id) 时不再压栈。
      // 否则每点一次通知压一层新详情页，用户"返回一次"会退回到上一个同类页面而非来源页。
      const navigated: boolean = navigateToWithIdOnce(route.routeName, route.id)
      Logger.info(this.tag, 'executeNotificationRoute: navigate to ' + route.routeName +
        ', id=' + route.id + ', effective=' + navigated.toString())

      // 番茄钟通知直达：确认目标页已在位后再置位"全屏可见"，
      // 新页面 onDestinationReady 会据此直接渲染全屏番茄钟，不再依赖进程内标志是否残留
      // （进程被回收后该标志为 false，点通知只会落到任务详情页）。
      // 顺序要求：必须在导航生效【之后】——若跳转被 600ms 防抖拦下，
      // 提前置位会让标志悬挂（没有宿主页面承载全屏层），之后用户手动打开该任务详情会被"意外全屏"。
      if (navigated && route.openImmersive && route.routeName === 'TaskDetailPage') {
        const session = pomodoroService.getCurrentSession()
        if (session !== null && session.state !== 'idle' && session.taskId === route.id) {
          pomodoroService.showImmersive()
          Logger.info(this.tag, 'executeNotificationRoute: session active, show immersive screen')
        }
      }
    } catch (e) {
      Logger.error(this.tag, 'executeNotificationRoute failed: ' + (e as Error).message)
    }
  }

  // 加载页面内容
  private setupWindowStage(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/MainTab', (err: BusinessError): void => {
      if (err.code) {
        Logger.error(this.tag, 'loadContent FAILED, code=' + err.code + ', msg=' + err.message)
        return
      }
      Logger.info(this.tag, 'loadContent SUCCESS')
      // 冷启动通知直达：待 MainTab 渲染后执行暂存的通知路由
      if (this.pendingNotificationRoute !== null) {
        setTimeout((): void => {
          this.executeNotificationRoute()
        }, CommonConstants.COLD_START_ROUTE_DELAY_MS)
      }
    })
  }

  /**
   * 初始化窗口安全区与沉浸式布局
   * - 开启窗口全屏布局，使应用内容可延伸到状态栏/底部手势区
   * - 存储 statusBarHeight / bottomSafeAreaHeight 到 AppStorage，供全页面统一避让
   */
  private initWindowInsets(windowStage: window.WindowStage): void {
    const mainWindow = windowStage.getMainWindowSync()
    // 关键：开启全屏布局，否则 expandSafeArea 无法突破系统默认 inset
    mainWindow.setWindowLayoutFullScreen(true)

    // 自愈：每次启动都无条件恢复"状态栏 + 导航栏"可见。
    // 番茄钟沉浸屏会在整屏生命周期内隐藏系统栏；若进程在隐藏态被杀/崩溃，
    // 这里保证下次启动一定回到可见状态，不会留下"应用没有状态栏"这类诡异故障。
    const barNames: Array<'status' | 'navigation'> = ['status', 'navigation']
    mainWindow.setWindowSystemBarEnable(barNames).catch((e: BusinessError): void => {
      Logger.warn(this.tag, 'restore system bars failed: ' + e.message)
    })

    const systemAvoidArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM)
    const statusBarHeight = px2vp(systemAvoidArea.topRect.height)

    const navAvoidArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR)
    const bottomSafeAreaHeight = px2vp(navAvoidArea.bottomRect.height)

    // 写入响应式安全区单例，全页面 build 内读取自动刷新
    safeAreaHelper.refresh(statusBarHeight, bottomSafeAreaHeight)

    // 监听避让区变化：旋转/折叠/悬浮态后 statusBarHeight/bottomSafeAreaHeight 失效，
    // 不监听会导致页面顶部/底部避让错位
    mainWindow.on('avoidAreaChange', (data: window.AvoidAreaOptions): void => {
      if (data.type === window.AvoidAreaType.TYPE_SYSTEM) {
        const top: number = px2vp(data.area.topRect.height)
        safeAreaHelper.refresh(top, safeAreaHelper.getBottom())
        Logger.info(this.tag, 'avoidAreaChange: statusBarHeight=' + top.toString())
      } else if (data.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
        const bottom: number = px2vp(data.area.bottomRect.height)
        safeAreaHelper.refresh(safeAreaHelper.getStatusBar(), bottom)
        Logger.info(this.tag, 'avoidAreaChange: bottomSafeAreaHeight=' + bottom.toString())
      }
    })

    Logger.info(this.tag, 'statusBarHeight=' + statusBarHeight.toString() +
      ', bottomSafeAreaHeight=' + bottomSafeAreaHeight.toString())
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    Logger.info(this.tag, 'onWindowStageCreate')
    this.initWindowInsets(windowStage)
    this.setupWindowStage(windowStage)
  }

  // 接续场景（多端流转恢复）系统调用此方法，非 onWindowStageCreate
  onWindowStageRestore(windowStage: window.WindowStage): void {
    Logger.info(this.tag, 'onWindowStageRestore')
    this.initWindowInsets(windowStage)
    this.setupWindowStage(windowStage)
  }


  onWindowStageDestroy(): void {
    Logger.info(this.tag, 'onWindowStageDestroy')
  }

  onDestroy(): void {
    Logger.info(this.tag, 'onDestroy')
    settingsVM.flush().catch((e: Error): void => {
      Logger.error(this.tag, 'settingsVM.flush failed: ' + e.message)
    })
    homeVM.flush().catch((e: Error): void => {
      Logger.error(this.tag, 'homeVM.flush failed: ' + e.message)
    })
    routeVM.flush().catch((e: Error): void => {
      Logger.error(this.tag, 'routeVM.flush failed: ' + e.message)
    })
    // SettingsViewModel 防护：清定时器/退订事件总线，阻断 destroy 后的云同步触发
    settingsVM.destroy()
    CloudSdkService.getInstance().destroy()
  }

  onForeground(): void {
    Logger.info(this.tag, 'onForeground')
    // 回前台：不再取消后台兜底提醒，而是【重新注册】（幂等，内部会先取消旧的）。
    // 原因：取消会留下"前台运行期间进程被系统回收 / 崩溃"的提醒空洞——那条路径不会触发
    // onBackground，兜底就此丢失。重复通知的风险由两处共同消除：
    //   ① 兜底提醒的触发时间带 5s 延迟（PomodoroService.BG_REMINDER_LEAD_MILLIS）；
    //   ② 前台计时器到点时 onPhaseComplete() 会先 cancelReminder() 再发完成通知。
    pomodoroService.registerBackgroundReminder()
    // 回前台：补传上次因未登录/网络异常而暂存的用户反馈（内部有云 SDK 就绪判断，不满足则静默跳过）
    FeedbackService.getInstance().flushQueue().catch((e: Error): void => {
      Logger.warn(this.tag, 'flush feedback queue failed: ' + e.message)
    })
    // 回前台：通知同步层就绪（补跑滞留请求）+ 主动触发一次 merge 拉取云端更新
    // （多设备场景：另一台设备改完数据后，本机切回前台即可看到）
    settingsVM.notifyCloudReady()
    settingsVM.triggerSync()
  }

  onBackground(): void {
    Logger.info(this.tag, 'onBackground')
    settingsVM.flush().catch((e: Error): void => {
      Logger.error(this.tag, 'onBackground settingsVM.flush failed: ' + e.message)
    })
    homeVM.flush().catch((e: Error): void => {
      Logger.error(this.tag, 'onBackground homeVM.flush failed: ' + e.message)
    })
    routeVM.flush().catch((e: Error): void => {
      Logger.error(this.tag, 'onBackground routeVM.flush failed: ' + e.message)
    })
    // ⚠️ 退后台**只做本地持久化 + 写持久化脏标记，绝不发起网络 merge**：
    //    鸿蒙后台进程随时可能被冻结/回收，异步网络请求不保证完成。
    //    未上传的改动由脏标记兜住，等回前台 / 下次启动自动重试。
    settingsVM.markSyncNeeded('background', false)
    // 退后台：注册番茄钟 reminderAgent 兜底提醒
    // 即使进程被杀，系统也会在倒计时结束时弹出通知（应用常驻通知无法保证后台存活）
    pomodoroService.registerBackgroundReminder()
  }
}
