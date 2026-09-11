
import { AbilityConstant, UIAbility, Want, common, wantConstant } from '@kit.AbilityKit'
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
import { globalNavStack, setMigrationPayload, getCurrentTabIndex, navigateToWithId, markPendingDeepLink } from '../common/RouterManager'
import { util } from '@kit.ArkTS';
import { CloudSdkService } from '../common/services/CloudSdkService'

/** 通知直达路由信息（冷启动暂存，待 UI 加载后执行） */
interface PendingNotificationRoute {
  routeName: string
  id: string
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

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    Logger.info(this.tag, 'onCreate, launchReason=' + launchParam.launchReason)
    Logger.info(this.tag, 'want.parameters=' + JSON.stringify(want.parameters))
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
    Logger.info(this.tag, 'onContinue: migrationData=' + migrationData)

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
    Logger.info(this.tag, 'want.parameters=' + JSON.stringify(want.parameters))
    // 优先级：通知直达 > 多端流转
    // 热启动时 UI 已加载，解析后立即跳转
    if (!this.extractNotificationRoute(want)) {
      this.extractMigrationData(want)
    } else {
      this.executeNotificationRoute()
    }
    // 热启动并集合并刷新（方案A）：不无脑用云端覆盖本地，两端独有数据都保留
    // 冷启动已由 settingsVM.init() → smartSync('merge') 自动执行
    settingsVM.triggerSync()

    // 番茄钟运行中检测：热启动时若专注进行中，自动呼出沉浸屏
    this.restorePomodoroImmersiveIfNeeded()
  }

  /**
   * 番茄钟沉浸屏恢复
   * 热启动时若番茄钟运行中，导航到对应任务详情页（页面内番茄钟卡片会显示进行中状态）
   * 注意：不再自动 showImmersive 强制全屏拉起——用户回前台被打断体验差，
   * 且全局可见标志残留曾导致"打开任意任务详情都被番茄钟覆盖"
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

      // 检查当前页面栈顶是否已是 TaskDetailPage，避免重复压栈
      const pathStack: NavPathInfo[] = globalNavStack.getPathStack()
      if (Array.isArray(pathStack) && pathStack.length > 0) {
        const topPath: NavPathInfo = pathStack[pathStack.length - 1]
        if (topPath && typeof topPath.name === 'string' && topPath.name === 'TaskDetailPage') {
          Logger.info(this.tag, 'restorePomodoroImmersiveIfNeeded: already on TaskDetailPage, skip')
          return
        }
      }

      // 导航到 TaskDetailPage（携带 taskId，页面从 homeVM 反查构造数据）
      navigateToWithId('TaskDetailPage', session.taskId)
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
          this.pendingNotificationRoute = { routeName: routeName, id: goalId }
          markPendingDeepLink()
          Logger.info(this.tag, 'extractNotificationRoute: goal detail, goalId=' + goalId)
          return true
        }
      }

      if (routeName === 'TaskDetailPage') {
        const taskId: string = this.decodeParamValue(params.taskId)
        if (taskId.length > 0) {
          this.pendingNotificationRoute = { routeName: routeName, id: taskId }
          markPendingDeepLink()
          Logger.info(this.tag, 'extractNotificationRoute: task detail, taskId=' + taskId)
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
      navigateToWithId(route.routeName, route.id)
      Logger.info(this.tag, 'executeNotificationRoute: navigate to ' + route.routeName +
        ', id=' + route.id)
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
    // 回前台：取消番茄钟 reminderAgent 后台兜底提醒（前台计时器恢复接管）
    pomodoroService.cancelBackgroundReminder()
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
    // 退后台：注册番茄钟 reminderAgent 兜底提醒
    // 即使进程被杀，系统也会在倒计时结束时弹出通知（应用常驻通知无法保证后台存活）
    pomodoroService.registerBackgroundReminder()
  }
}
