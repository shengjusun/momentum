
import { AbilityConstant, UIAbility, Want, common, wantConstant, abilityAccessCtrl, Permissions } from '@kit.AbilityKit'
import { window } from '@kit.ArkUI'
import { BusinessError } from '@kit.BasicServicesKit'
import { CommonConstants } from '../common/constants/CommonConstants'
import { StorageManager } from '../common/utils/StorageManager'
import { settingsVM } from '../viewmodel/SettingsViewModel'
import { homeVM } from '../viewmodel/HomeViewModel'
import { routeVM } from '../viewmodel/RoutePageViewModel'
import { Logger } from '../common/utils/Logger'
import { CloudSyncService } from '../common/services/CloudSyncService'
import { safeAreaHelper } from '../common/utils/SafeAreaHelper'
import { CloudDBService } from '../common/services/CloudDBService'
import { deadlineReminderService } from '../common/services/DeadlineReminderService'
import { pomodoroService } from '../common/services/PomodoroService'
import { notificationCenterService } from '../common/services/NotificationCenterService'
import { DeepSeekService } from '../common/services/DeepSeekService'
import { globalNavStack, setMigrationPayload, getCurrentTabIndex, navigateToWithId, resolveIntentRoute, executeIntentRoute, IntentRoute, executeSkillRoute, hasPendingSkillRoute, markPendingDeepLink, setSkillRoute } from '../common/RouterManager'
import { util } from '@kit.ArkTS';
import { buffer } from '@kit.ArkTS';
import auth from '@hw-agconnect/auth';
import { cloudCommon } from '@kit.CloudFoundationKit'

/** 通知直达路由信息（冷启动暂存，待 UI 加载后执行） */
interface PendingNotificationRoute {
  routeName: string
  id: string
}

/** 番茄钟迁移状态 */
interface PomodoroMigrationState {
  taskId: string
  taskTitle: string
  phase: string
  remainingMillis: number
  totalMillis: number
}

/** 多端协同迁移负载 */
interface MigrationPayload {
  routeName: string
  param: string
  tabIndex: number
  pomodoro?: PomodoroMigrationState
}

export default class EntryAbility extends UIAbility {
  private readonly tag: string = 'EntryAbility'
  /** 待执行的通知直达路由 */
  private pendingNotificationRoute: PendingNotificationRoute | null = null
  /** 待执行的小艺意图路由（冷启动暂存，待 UI 加载后执行） */
  private pendingIntentRoute: IntentRoute | null = null

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    Logger.info(this.tag, 'onCreate, launchReason=' + launchParam.launchReason)
    Logger.info(this.tag, 'want.parameters=' + JSON.stringify(want.parameters))
    // 优先级：通知直达 > 小艺技能文本 > 小艺意图 > 多端流转
    if (!this.extractNotificationRoute(want)) {
      if (!this.extractSkillCallText(want)) {
        if (!this.extractIntentRoute(want)) {
          this.extractMigrationData(want)
        }
      }
    }

    // 初始化所有服务，确保应用启动时就准备就绪
    this.initializeAppServices();
  }

  private async initializeAppServices(): Promise<void> {
    try {
      // 0. 初始化 AGC SDK（@hw-agconnect/hmcore + auth）
      //    必须读取 rawfile 中的 agconnect-services.json 完成初始化，
      //    否则 LoginPage 的 auth.signIn 与 AGC 鉴权链路不可用
      try {
        const raw: Uint8Array = this.context.resourceManager.getRawFileContentSync('agconnect-services.json')
        const jsonStr: string = buffer.from(raw.buffer as ArrayBufferLike).toString('utf8')
        auth.init(this.context, jsonStr)
        Logger.info(this.tag, 'AGC auth SDK initialized')
      } catch (agcErr) {
        Logger.error(this.tag, 'AGC auth SDK init failed: ' + (agcErr as Error).message)
      }

      // 0.5 初始化 CloudFoundationKit（必须注入 authProvider，否则 cloudFunction 调用报 AuthProvider has not value）
      try {
        cloudCommon.init({
          region: cloudCommon.CloudRegion.CHINA,
          authProvider: auth.getAuthProvider()
        })
        Logger.info(this.tag, 'CloudFoundationKit initialized')
      } catch (cfErr) {
        Logger.error(this.tag, 'CloudFoundationKit init failed: ' + (cfErr as Error).message)
      }

      // 1. 初始化本地存储
      await StorageManager.init(this.context);

      // 2. 初始化云同步服务（CloudSyncService.init 转发 CloudDBService.init，统一在此入口）
      await CloudSyncService.getInstance().init(this.context);

      // 3. 初始化云数据库服务
      const cloudDBSuccess = await CloudDBService.getInstance().init(this.context);
      if (!cloudDBSuccess) {
        Logger.error(this.tag, 'CloudDBService initialization failed');
      } else {
        Logger.info(this.tag, 'CloudDBService initialized successfully');
      }

      // 4. 初始化其他服务（如截止日期提醒）
      deadlineReminderService.init(this.context);

      // 5. 初始化番茄钟服务（前台计时 + 后台 reminderAgent + 通知）
      pomodoroService.init(this.context);

      // 5.1 初始化站内通知中心（展示/删除/直达）
      notificationCenterService.init(this.context);

      // 6. 初始化 DeepSeek 服务（注入 context 用于 i18n 资源读取）
      DeepSeekService.getInstance().init(this.context);

      Logger.info(this.tag, 'All application services initialized successfully');
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

    // 如果番茄钟正在运行，把当前会话状态打包进迁移数据，供手表端恢复
    if (pomodoroService.isRunning()) {
      const session = pomodoroService.getCurrentSession()
      if (session !== null) {
        const remainingMillis: number = pomodoroService.getCurrentRemainingMillis()
        const totalMillis: number = session.phase === 'focus'
          ? session.focusDurationMillis
          : session.breakDurationMillis
        payload.pomodoro = {
          taskId: session.taskId,
          taskTitle: session.taskTitle,
          phase: session.phase,
          remainingMillis: remainingMillis,
          totalMillis: totalMillis
        }
        Logger.info(this.tag, 'onContinue: pomodoro running, remaining=' + remainingMillis.toString())
      }
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
    // 优先级：通知直达 > 小艺技能文本 > 小艺意图 > 多端流转
    // 热启动时 UI 已加载，解析后立即跳转
    if (!this.extractNotificationRoute(want)) {
      if (!this.extractSkillCallText(want)) {
        if (!this.extractIntentRoute(want)) {
          this.extractMigrationData(want)
        } else {
          this.executePendingIntentRoute()
        }
      }
    } else {
      this.executeNotificationRoute()
    }
    // 热启动小艺技能调用：UI 已加载，立即切到 AI Tab 并触发自动拆解
    if (hasPendingSkillRoute()) {
      executeSkillRoute()
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
   * 解析小艺技能调用文本（Skill calling 拉起 App 场景）
   * - 与静态意图（extractIntentRoute）不同：Skill calling 以参数形式传递目标文本
   * - 兼容多种参数键名（goalText / goal / text / query / inputText / content），
   *   避免受官方 Skill 传参命名影响
   * - 找到目标文本后调用 setSkillRoute 暂存，由冷/热启动消费切到 AI Tab 并自动拆解
   *
   * @param want - 启动 Want
   * @returns true 表示已提取技能文本；false 表示未命中
   */
  private extractSkillCallText(want: Want): boolean {
    if (!want.parameters) {
      return false
    }
    try {
      const params: Record<string, Object> = want.parameters
      Logger.info(this.tag, 'extractSkillCallText: parameters keys=' + Object.keys(params).join(','))
      const textKeys: string[] = ['goalText', 'goal', 'text', 'query', 'inputText', 'content']
      for (let i: number = 0; i < textKeys.length; i++) {
        const val: string = this.decodeParamValue(params[textKeys[i]])
        if (val.length > 0) {
          setSkillRoute(val)
          markPendingDeepLink()
          Logger.info(this.tag, 'extractSkillCallText SUCCESS: key=' + textKeys[i] +
            ', textLen=' + val.length.toString())
          return true
        }
      }
      Logger.info(this.tag, 'extractSkillCallText: no target text param found')
      return false
    } catch (e) {
      Logger.warn(this.tag, 'extractSkillCallText failed: ' + (e as Error).message)
      return false
    }
  }

  /**
   * 解析小艺意图路由
   * 小艺语音匹配后，系统以 Want.action 拉起 Ability
   * action 取值见 module.json5 skills 注册
   *
   * @param want - 启动 Want
   * @returns true 表示为意图场景，已暂存路由；false 表示非意图场景
   */
  private extractIntentRoute(want: Want): boolean {
    const action: string | undefined = want.action
    if (action === undefined || action === null || action.length === 0) {
      return false
    }
    const route: IntentRoute | null = resolveIntentRoute(action)
    if (route === null) {
      return false
    }
    this.pendingIntentRoute = route
    markPendingDeepLink()
    Logger.info(this.tag, 'extractIntentRoute: action=' + action +
      ', tabIndex=' + route.tabIndex.toString() + ', focusInput=' + route.focusInput.toString())
    return true
  }

  /**
   * 执行暂存的小艺意图路由跳转
   * 冷启动：在 loadContent 回调中延迟调用（等待 MainTab 渲染）
   * 热启动：在 onNewWant 中直接调用
   */
  private executePendingIntentRoute(): void {
    if (this.pendingIntentRoute === null) {
      return
    }
    const route: IntentRoute = this.pendingIntentRoute
    this.pendingIntentRoute = null
    try {
      executeIntentRoute(route)
      Logger.info(this.tag, 'executePendingIntentRoute: tabIndex=' + route.tabIndex.toString())
    } catch (e) {
      Logger.error(this.tag, 'executePendingIntentRoute failed: ' + (e as Error).message)
    }
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
      // 冷启动小艺意图：待 MainTab 渲染后执行暂存的意图路由
      if (this.pendingIntentRoute !== null) {
        setTimeout((): void => {
          this.executePendingIntentRoute()
        }, CommonConstants.COLD_START_ROUTE_DELAY_MS)
      }
      // 冷启动小艺技能调用：待 MainTab 渲染后切到 AI Tab
      if (hasPendingSkillRoute()) {
        setTimeout((): void => {
          executeSkillRoute()
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

  /**
   * 动态申请 DISTRIBUTED_DATASYNC（user_grant 权限：仅在 module.json5 声明不生效）
   * 已授予则静默返回；未授予时在窗口就绪后弹窗申请，用户拒绝不影响其他功能（仅流转不可用）
   */
  private async requestDistributedSyncPermission(): Promise<void> {
    try {
      const atManager = abilityAccessCtrl.createAtManager()
      const permission: Permissions = 'ohos.permission.DISTRIBUTED_DATASYNC'
      const status = await atManager.checkAccessToken(
        this.context.applicationInfo.accessTokenId, permission)
      if (status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        Logger.info(this.tag, 'DISTRIBUTED_DATASYNC already granted')
        return
      }
      const result = await atManager.requestPermissionsFromUser(this.context, [permission])
      Logger.info(this.tag, 'DISTRIBUTED_DATASYNC request result: ' + JSON.stringify(result.authResults))
    } catch (e) {
      Logger.warn(this.tag, 'requestDistributedSyncPermission failed: ' + (e as Error).message)
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    Logger.info(this.tag, 'onWindowStageCreate')
    this.initWindowInsets(windowStage)
    this.setupWindowStage(windowStage)
    this.requestDistributedSyncPermission()
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
    CloudDBService.getInstance().destroy()
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
