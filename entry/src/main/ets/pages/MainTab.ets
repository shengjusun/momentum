// 主入口页面，4 Tab 容器，Navigation 包裹 Tabs 的标准结构
// 交互方案（对齐华为音乐）：
//   - 内容区禁止滑动切换（scrollable(false)），页面滑动无反应
//   - 导航栏左右拖拽，松手那一刻触发切换，页面以滑动动画过渡到目标 Tab（animationDuration 300）
//   - 导航栏点击切换保留，同样带动画
//   - 不做跟手平移（页面不跟随手指移动）

import { TabConfig } from '../model/Models'
import { globalNavStack, ROUTE_NAME, globalTabsController, navigateTo, restoreMigrationIfNeeded, setCurrentTabIndex, notifyMigrationRestoreDone, hasPendingDeepLink, consumePendingDeepLink } from '../common/RouterManager'
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
import { safeAreaHelper } from '../common/utils/SafeAreaHelper'
import { BackPressHandler } from '../common/utils/BackPressHandler'
import { DuneTabBar } from '../common/components/DuneTabBar'

// 全局拖拽状态同步对象（@ComponentV2 不支持 @StorageLink，用 @Trace 单例替代）
@ObservedV2
class DragStateHolder {
  @Trace isDragging: boolean = false
}
const dragState = new DragStateHolder()
export { dragState }

function buildTabConfig(index: number, title: Resource, icon: Resource, iconSelected: Resource): TabConfig {
  const config: TabConfig = new TabConfig()
  config.index = index
  config.title = title
  config.icon = icon
  config.iconSelected = iconSelected
  return config
}

const TAB_CONFIGS: TabConfig[] = [
  buildTabConfig(0, $r('app.string.tab_home'), $r('app.media.tab_home'), $r('app.media.tab_home_active')),
  buildTabConfig(1, $r('app.string.tab_route'), $r('app.media.tab_route'), $r('app.media.tab_route_active')),
  buildTabConfig(2, $r('app.string.tab_ai'), $r('app.media.tab_ai'), $r('app.media.tab_ai_active')),
  buildTabConfig(3, $r('app.string.tab_mine'), $r('app.media.tab_mine'), $r('app.media.tab_mine_active'))
]

@Entry
@ComponentV2
export struct MainTab {
  @Local currentTabIndex: number = 0
  // 断点状态：全局响应式单例（BreakpointState），isTablet 变化自动触发 UI 刷新
  // 四象限拖拽态：为 true 时禁止切换
  dragState: DragStateHolder = dragState
  private hasInitStarted: boolean = false

  aboutToAppear(): void {
    Logger.info('MainTab', '========== aboutToAppear START ==========')
    bindBreakpointState()
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
        (): string => JSON.stringify(routeVM.buildSnapshot()),
        (): string => JSON.stringify(homeVM.buildSnapshot()),
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

      // ★ 路由守卫：三条件决定是否跳转 LoginPage
      if (!restored && settingsVM.userProfile.isLoggedIn === false && !hasPendingDeepLink()) {
        Logger.info('MainTab', 'not restored and not logged in and no deep link, navigateTo LoginPage')
        navigateTo(ROUTE_NAME.LOGIN)
      } else if (!restored && settingsVM.userProfile.isLoggedIn === false) {
        Logger.info('MainTab', 'deep link pending, skip auto-login navigation')
      } else {
        Logger.info('MainTab', 'restored=' + restored.toString() + ', isLoggedIn=' + settingsVM.userProfile.isLoggedIn.toString() + ', no navigation needed')
      }
      consumePendingDeepLink()
      notifyMigrationRestoreDone()

      Logger.info('MainTab', '========== initAndRestoreMigration END ==========')
    }, CommonConstants.COLD_START_ROUTE_DELAY_MS)
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

  // 统一的 Tab 切换入口（导航栏点击 / 导航栏拖拽共用）
  // 切换由 currentTabIndex 驱动（$$ 双向绑定），页面以 animationDuration 的动画滑动到目标页
  private selectTab(index: number): void {
    // 边界钳制：越界或重复切换直接忽略（首个 Tab 右拖、末个 Tab 左拖不会切换）
    if (index < 0 || index >= TAB_CONFIGS.length || index === this.currentTabIndex) {
      return
    }
    animateTo({ duration: 300, curve: Curve.EaseOut }, (): void => {
      this.currentTabIndex = index
      setCurrentTabIndex(index)
    })
  }

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
    // 标准结构：Navigation 在外，Tabs 在内
    // 导航栏始终底部悬浮；平板（lg）加宽胶囊，手机（sm/md）72% 宽
    Navigation(globalNavStack) {
      Stack() {
        // Tabs 撑满整个区域（包括底部安全区），内容可滚到底部
        Tabs({
          barPosition: BarPosition.End,
          index: $$this.currentTabIndex,
          controller: globalTabsController
        }) {
          TabContent() {
            HomePage()
          }
          .tabBar('')

          TabContent() {
            RoutePage()
          }
          .tabBar('')

          TabContent() {
            AIPage()
          }
          .tabBar('')

          TabContent() {
            ProfilePage()
          }
          .tabBar('')
        }
        .barWidth('100%')
        .barHeight(0) // 隐藏系统 TabBar，使用自定义沙丘导航栏
        .barMode(BarMode.Fixed)
        .backgroundColor($r('app.color.bg_page'))
        .width('100%')
        .height('100%')
        // 内容区禁止滑动切换：页面滑动无反应，切换只能由导航栏触发
        .scrollable(false)
        // 松手/点击切换时，页面以 300ms 的滑动动画过渡到目标 Tab（华为音乐式动效）
        // 手感调节：觉得慢改 250，觉得快改 350~400
        .animationDuration(300)
        .onChange((index: number): void => {
          setCurrentTabIndex(index)
        })

        // 悬浮导航栏层：Column 满铺 + Blank 顶到底部，透传点击给 Tabs
        Column() {
          Blank()
          DuneTabBar({
            currentIndex: this.currentTabIndex,
            tabConfigs: TAB_CONFIGS,
            onTabSelected: (index: number): void => {
              this.selectTab(index)
            }
          })
            .width(breakpointState.isTablet ? '480vp' : '72%')
            // 导航栏横向拖拽 → 松手那一刻切换到相邻 Tab，页面带动画滑过去
            // PanGesture 而非 SwipeGesture：Swipe 有速度阈值，慢速拖动不触发；
            // Pan 只看位移，拖过 20vp 松手即切，轻扫和慢拖都能响应
            .gesture(
              PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 20 })
                .onActionEnd((event: GestureEvent): void => {
                  // 四象限拖拽期间禁止切换
                  if (this.dragState.isDragging) {
                    return
                  }
                  // 向左拖（offsetX < 0）→ 下一个；向右拖（offsetX > 0）→ 上一个
                  // 单次拖拽只切一个 Tab，selectTab 内部已做边界钳制
                  if (event.offsetX < 0) {
                    this.selectTab(this.currentTabIndex + 1)
                  } else if (event.offsetX > 0) {
                    this.selectTab(this.currentTabIndex - 1)
                  }
                })
            )
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
      }
      .width('100%')
      .layoutWeight(1)
    }
    .mode(NavigationMode.Stack)
    .navDestination(this.PageMapBuilder)
    .hideTitleBar(true)
    .backgroundColor($r('app.color.bg_page'))
    .width('100%')
    .layoutWeight(1)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}