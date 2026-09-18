// 主入口页面，4 Tab 容器，Navigation 包裹 HdsTabs 的标准结构
// 页签栏方案（HDS 悬浮页签栏，@kit.UIDesignKit，API 23+）：
//   - HdsTabs + barOverlap(true) + barFloatingStyle：悬浮胶囊底栏 + ADAPTIVE 沉浸光感材质（毛玻璃）
//   - BottomTabBarStyle + SymbolGlyphModifier：系统符号双态图标，选中/未选中配色与官方动效由系统接管
//   - 内容区支持手势滑动换页（vertical(false) 默认行为）；四象限长按拖拽期间经 dragState 临时禁用
//   - 跨页切 Tab 仍走 globalTabsController.changeIndex（HomePage / GoalDetailPage / RoutePage）

import { hdsMaterial, HdsTabs } from '@kit.UIDesignKit'
import { SymbolGlyphModifier } from '@kit.ArkUI'
import { globalNavStack, ROUTE_NAME, globalTabsController, restoreMigrationIfNeeded, setCurrentTabIndex, notifyMigrationRestoreDone, consumePendingDeepLink } from '../common/RouterManager'
import { settingsVM } from '../viewmodel/SettingsViewModel'
import { homeVM } from '../viewmodel/HomeViewModel'
import { routeVM } from '../viewmodel/RoutePageViewModel'
import { HomePage } from './HomePage'
import { RoutePage } from './RoutePage'
import { AIPage } from './AIPage'
import { ProfilePage } from './ProfilePage'
import { GoalDetailPage } from './GoalDetailPage'
import { TaskDetailPage } from './TaskDetailPage'
import { GoalHistoryPage } from './GoalHistoryPage'
import { NotificationPage } from './NotificationPage'
import { SettingPage } from './SettingPage'
import { StatsPage } from './StatsPage'
import { ImportExportPage } from './ImportExportPage'
import { HelpPage } from './HelpPage'
import { FeedbackPage } from './FeedbackPage'
import { AboutPage } from './AboutPage'
import { CategoryManagePage } from './CategoryManagePage'
import { LoginPage } from './LoginPage'
import { bindBreakpointState, unbindBreakpointState, breakpointState } from '../common/utils/BreakpointState'
import { Logger } from '../common/utils/Logger'
import { CommonConstants } from '../common/constants/CommonConstants'

import { BackPressHandler } from '../common/utils/BackPressHandler'
import { PrivacyConsentOverlay } from '../common/components/PrivacyConsentOverlay'
import { CloudSdkService } from '../common/services/CloudSdkService'
import { common } from '@kit.AbilityKit'

// 全局拖拽状态同步对象（@ComponentV2 不支持 @StorageLink，用 @Trace 单例替代）
@ObservedV2
class DragStateHolder {
  @Trace isDragging: boolean = false
}
const dragState = new DragStateHolder()
export { dragState }

// 页签配置：系统符号双态（normal 未选态 / selected 选中态）
// 符号名核对自 HarmonyOS Symbol 全量符号库（4027 个，symbol.termnext.com）：
// - home  house / house_fill（已编译验证）
// - route route_plan / route_plan_fill（已编译验证，语义即"路线规划"）
// - ai    robot / robots_fill（全量库确认的成对变体，AI 助手通用意象；
//         备选：AI_wand_stars_and_cloud / AI_lightbulb_max / wand_and_stars_fill，均无确认的空心态）
// - mine  person / person_fill（已编译验证）
// 注：sparkles 在当前 SDK 不存在（编译 10903329 实测），官方 433 图标页亦未收录
interface TabItem {
  title: Resource
  normal: Resource
  selected: Resource
}

const TAB_ITEMS: TabItem[] = [
  { title: $r('app.string.tab_home'), normal: $r('sys.symbol.house'), selected: $r('sys.symbol.house_fill') },
  { title: $r('app.string.tab_route'), normal: $r('sys.symbol.route_plan'), selected: $r('sys.symbol.route_plan_fill') },
  { title: $r('app.string.tab_ai'), normal: $r('sys.symbol.robot'), selected: $r('sys.symbol.robots_fill') },
  { title: $r('app.string.tab_mine'), normal: $r('sys.symbol.person'), selected: $r('sys.symbol.person_fill') }
]

/** HDS 底部页签样式：系统符号双态 + 文字标签；选中态显式染品牌主色（随深浅色模式自适应） */
function tabBarStyle(item: TabItem): BottomTabBarStyle {
  return new BottomTabBarStyle({
    normal: new SymbolGlyphModifier(item.normal),
    selected: new SymbolGlyphModifier(item.selected)
      .fontColor([$r('app.color.primary_color')])
  }, item.title)
}

@Entry
@ComponentV2
export struct MainTab {
  @Local currentTabIndex: number = 0
  // 断点状态：全局响应式单例（BreakpointState），isTablet 变化自动触发 UI 刷新
  private hasInitStarted: boolean = false

  aboutToAppear(): void {
    Logger.info('MainTab', '========== aboutToAppear START ==========')
    bindBreakpointState(this.getUIContext())
    Logger.info('MainTab', 'aboutToAppear: BreakpointState bound, isTablet=' + breakpointState.isTablet.toString())

    // 耗时操作和流转恢复延后执行，确保 Navigation 已挂载、NavPathStack 已绑定，避免冷启动卡死
    Logger.info('MainTab', 'aboutToAppear: scheduling initAndRestoreMigration in ' +
      CommonConstants.COLD_START_INIT_DELAY_MS.toString() + 'ms')
    setTimeout((): void => {
      if (this.hasInitStarted) {
        Logger.warn('MainTab', 'initAndRestoreMigration already started, skip duplicate')
        return
      }
      this.hasInitStarted = true
      Logger.info('MainTab', 'init delay callback FIRED, calling initAndRestoreMigration')
      this.initAndRestoreMigration()
    }, CommonConstants.COLD_START_INIT_DELAY_MS)
    Logger.info('MainTab', '========== aboutToAppear END ==========')
  }

  /**
   * 初始化 ViewModel 并尝试恢复流转路由
   * 每个 ViewModel.init 独立 try-catch，避免单个失败导致整体卡死
   */
  private async initAndRestoreMigration(): Promise<void> {
    Logger.info('MainTab', '========== initAndRestoreMigration START ==========')

    // 每个 ViewModel.init 独立 try-catch，防止单个失败阻塞整体流程
    try {
      Logger.info('MainTab', 'initAndRestoreMigration: before settingsVM.init')
      await settingsVM.init(getContext(this))
      Logger.info('MainTab', 'initAndRestoreMigration: settingsVM.init DONE, isLoaded=' + settingsVM.isLoaded.toString() + ', isLoggedIn=' + settingsVM.userProfile.isLoggedIn.toString())
    } catch (e) {
      Logger.error('MainTab', 'initAndRestoreMigration: settingsVM.init FAILED: ' + (e as Error).message)
    }

    // 云 SDK 初始化链（不阻塞后续 init）：已同意隐私协议的老用户冷启动也必须拉起云端，
    // 否则 CloudDB 未初始化导致所有云同步静默失败（新用户在 handlePrivacyAgreed 中拉起）
    this.initCloudSdkIfNeeded()

    try {
      Logger.info('MainTab', 'initAndRestoreMigration: before homeVM.init')
      await homeVM.init(getContext(this))
      Logger.info('MainTab', 'initAndRestoreMigration: homeVM.init DONE')
    } catch (e) {
      Logger.error('MainTab', 'initAndRestoreMigration: homeVM.init FAILED: ' + (e as Error).message)
    }

    try {
      Logger.info('MainTab', 'initAndRestoreMigration: before routeVM.init')
      await routeVM.init(getContext(this))
      Logger.info('MainTab', 'initAndRestoreMigration: routeVM.init DONE')
    } catch (e) {
      Logger.error('MainTab', 'initAndRestoreMigration: routeVM.init FAILED: ' + (e as Error).message)
    }

    try {
      settingsVM.registerSnapshotProviders(
        // ⚠️ 必须用 buildSyncSnapshot（**含墓碑**）：用过滤后的视图会丢掉删除标记，
        //    导致删除无法上传 → 对端删除复活
        (): string => JSON.stringify(routeVM.buildSyncSnapshot()),
        (): string => JSON.stringify(homeVM.buildSyncSnapshot()),
        (data: Record<string, Object>): void => { routeVM.applyCloudSnapshot(data) },
        (data: Record<string, Object>): void => { homeVM.applyCloudSnapshot(data) }
      )
      Logger.info('MainTab', 'initAndRestoreMigration: registerSnapshotProviders DONE')
    } catch (e) {
      Logger.error('MainTab', 'initAndRestoreMigration: registerSnapshotProviders FAILED: ' + (e as Error).message)
    }

    // 流转恢复 + 路由守卫放在所有 init 之后并用 setTimeout 包裹
    Logger.info('MainTab', 'initAndRestoreMigration: scheduling restoreMigrationIfNeeded in ' +
      CommonConstants.COLD_START_ROUTE_DELAY_MS.toString() + 'ms')
    setTimeout((): void => {
      Logger.info('MainTab', 'route delay callback FIRED, calling restoreMigrationIfNeeded')
      const restored: boolean = restoreMigrationIfNeeded()
      Logger.info('MainTab', 'restoreMigrationIfNeeded result=' + restored.toString())

      // ★ 合规改造（2026-09-11）：移除冷启动强制登录
      // 依据《华为帐号登录管理细则》——"禁止用户进入应用还未开始了解基础功能，就强制要求注册/登录"，
      // 且应用不得因用户拒绝登录而终止服务。未登录用户以「游客」身份进入，全部本地功能
      // （四象限 / 路线 / 番茄钟 / 统计 / 通知 / 桌面卡片 / 导入导出）可用；
      // AI 拆解、云同步、反馈在点击使用时就地引导登录（细则允许"用户表现出意向后再次提示"）。
      if (!settingsVM.userProfile.isLoggedIn) {
        Logger.info('MainTab', 'guest mode: enter app without login (login gated per-feature)')
      } else {
        Logger.info('MainTab', 'restored=' + restored.toString() + ', logged in, no navigation needed')
      }
      consumePendingDeepLink()
      notifyMigrationRestoreDone()

      Logger.info('MainTab', '========== initAndRestoreMigration END ==========')
    }, CommonConstants.COLD_START_ROUTE_DELAY_MS)
  }

  /**
   * 云 SDK 初始化链：冷启动时若已同意隐私协议，拉起云端 SDK 并通知同步层就绪
   * （settingsVM.init 的同步会因就绪 gate 未通过而滞留，此处就绪后由 notifyCloudReady 补跑）
   * 未同意隐私协议时不做任何云端动作，等弹层同意后走 handlePrivacyAgreed
   */
  private async initCloudSdkIfNeeded(): Promise<void> {
    if (!settingsVM.settings.privacyAgreed) {
      Logger.info('MainTab', 'cloud sdk init skipped: privacy not agreed')
      return
    }
    try {
      const ok: boolean = await CloudSdkService.getInstance().init(getContext(this))
      Logger.info('MainTab', 'cold start cloud sdk init result=' + ok.toString())
    } catch (e) {
      Logger.error('MainTab', 'cold start cloud sdk init failed: ' + (e as Error).message)
      return
    }
    settingsVM.notifyCloudReady()
  }

  /**
   * 同意隐私协议：持久化同意状态 → 拉起云端 SDK 初始化链 → 补跑一次合并同步
   * 云端 SDK（AGC auth / CloudFoundationKit / CloudDB）此前完全未初始化，
   * 此处与 initCloudSdkIfNeeded 是它们在应用生命周期内的仅有的两个初始化入口
   */
  private async handlePrivacyAgreed(): Promise<void> {
    Logger.info('MainTab', 'privacy agreed, initializing cloud sdk chain')
    settingsVM.setPrivacyAgreed(true)
    try {
      const ok: boolean = await CloudSdkService.getInstance().init(getContext(this))
      Logger.info('MainTab', 'cloud sdk init result=' + ok.toString())
    } catch (e) {
      Logger.error('MainTab', 'cloud sdk init failed: ' + (e as Error).message)
    }
    // 云 SDK 就绪后通知同步层：若此前有因 gate 未通过而滞留的请求 → 立即补跑
    settingsVM.notifyCloudReady()
  }

  /** 不同意隐私协议：退出应用（合规要求：未同意不得使用） */
  private handlePrivacyDisagreed(): void {
    Logger.info('MainTab', 'privacy declined, terminate app')
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext
      ctx.terminateSelf()
    } catch (e) {
      Logger.error('MainTab', 'terminateSelf failed: ' + (e as Error).message)
    }
  }

  aboutToDisappear(): void {
    unbindBreakpointState()
  }

  /**
   * 根页面返回拦截："再按一次退出"防误触
   * - 有子页面（NavPathStack 非空）时返回 false，交由 Navigation 系统处理 pop
   * - 根页面时走 BackPressHandler：首次按 toast 提示，2 秒内再按真正退出
   */
  onBackPress(): boolean {
    if (globalNavStack.size() > 0) {
      return false
    }
    return BackPressHandler.handleExitOnBack((): void => {
      globalNavStack.clear()
    })
  }

  // Tab 切换说明：页签点击 / 内容区滑动由 HdsTabs 自行处理（onChange 同步状态）；
  // 跨页切 Tab 走 globalTabsController.changeIndex（RouterManager），不再需要本地 selectTab

  @Builder
  PageMapBuilder(name: string, param: Object): void {
    if (name === ROUTE_NAME.LOGIN) {
      LoginPage()
    } else if (name === ROUTE_NAME.GOAL_DETAIL) {
      GoalDetailPage()
    } else if (name === ROUTE_NAME.TASK_DETAIL) {
      TaskDetailPage()
    } else if (name === ROUTE_NAME.GOAL_HISTORY) {
      GoalHistoryPage()
    } else if (name === ROUTE_NAME.NOTIFICATION) {
      NotificationPage()
    } else if (name === ROUTE_NAME.SETTINGS) {
      SettingPage()
    } else if (name === ROUTE_NAME.STATS) {
      StatsPage()
    } else if (name === ROUTE_NAME.IMPORT_EXPORT) {
      ImportExportPage()
    } else if (name === ROUTE_NAME.HELP) {
      HelpPage()
    } else if (name === ROUTE_NAME.FEEDBACK) {
      FeedbackPage()
    } else if (name === ROUTE_NAME.ABOUT) {
      AboutPage()
    } else if (name === ROUTE_NAME.TAGS) {
      CategoryManagePage()
    }
  }

  build(): void {
    // 标准结构：Navigation 在外，HdsTabs 在内（Navigation + 全局 NavPathStack 不变）
    Navigation(globalNavStack) {
      Stack() {
        // HDS 悬浮页签栏：barOverlap 内容延伸到栏下方，barFloatingStyle 悬浮胶囊 + 沉浸光感材质
        HdsTabs({ controller: globalTabsController }) {
          TabContent() {
            HomePage()
          }
          .tabBar(tabBarStyle(TAB_ITEMS[0]))

          TabContent() {
            RoutePage()
          }
          .tabBar(tabBarStyle(TAB_ITEMS[1]))

          TabContent() {
            AIPage()
          }
          .tabBar(tabBarStyle(TAB_ITEMS[2]))

          TabContent() {
            ProfilePage()
          }
          .tabBar(tabBarStyle(TAB_ITEMS[3]))
        }
        .barPosition(BarPosition.End)
        .vertical(false)
        .barOverlap(true)
        .barFloatingStyle({
          barWidth: { smallWidth: 280, mediumWidth: 420, largeWidth: 560 },
          barBottomMargin: 28,
          systemMaterialEffect: {
            materialType: hdsMaterial.MaterialType.ADAPTIVE,
            materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
          }
        })
        .backgroundColor($r('app.color.bg_page'))
        .width('100%')
        .height('100%')
        // 内容区支持滑动换页（官方默认行为）；四象限长按拖拽期间临时禁用，防止长按拖动时页面晃动
        .scrollable(!dragState.isDragging)
        .animationDuration(300)
        .onChange((index: number): void => {
          setCurrentTabIndex(index)
          this.currentTabIndex = index
        })

        // 隐私门禁：设置加载完成且未同意隐私协议时，全屏弹层阻断一切交互
        // isLoaded 门控：已同意的老用户冷启动加载期间不会看到弹层闪现
        if (settingsVM.isLoaded && !settingsVM.settings.privacyAgreed) {
          PrivacyConsentOverlay({
            onAgree: (): void => {
              this.handlePrivacyAgreed()
            },
            onDisagree: (): void => {
              this.handlePrivacyDisagreed()
            }
          })
        }
      }
      .width('100%')
      .layoutWeight(1)
    }
    .mode(NavigationMode.Stack)
    .navDestination(this.PageMapBuilder)
    .hideTitleBar(true)
    .backgroundColor($r('app.color.bg_page'))
    .width('100%')
    .height('100%')
    .layoutWeight(1)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}