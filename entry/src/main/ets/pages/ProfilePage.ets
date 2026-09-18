// 我的页：统一状态源 SettingsViewModel，华为登录态展示 + 设置项

import { promptAction } from '@kit.ArkUI'
import { Logger } from '../common/utils/Logger'
import { breakpointState } from '../common/utils/BreakpointState'
import { safeStringUtil } from '../common/utils/SafeUtils'
import { settingsVM, SettingsViewModel } from '../viewmodel/SettingsViewModel'
import { homeVM } from '../viewmodel/HomeViewModel'
import { routeVM } from '../viewmodel/RoutePageViewModel'
import { notificationCenterService, NotificationCenterService } from '../common/services/NotificationCenterService'
import { globalNavStack, ROUTE_NAME, navigateTo, pushNavPath } from '../common/RouterManager'
import { CommonTitleBar } from '../common/components/CommonTitleBar'
import { StateView, StateMode } from '../common/components/StateView'
import { RouteParam } from '../model/Models'
import { common } from '@kit.AbilityKit'
import { safeAreaHelper } from '../common/utils/SafeAreaHelper'
import { CommonConstants } from '../common/constants/CommonConstants'
import { DimensConstants } from '../common/constants/DimensConstants'
import { MotionConstants } from '../common/constants/MotionConstants'

@ComponentV2
export struct ProfilePage {
  settingsVM: SettingsViewModel = settingsVM

  @Local isLoading: boolean = false
  @Local isError: boolean = false
  /** 当前按下的菜单行 ID（按压反馈） */
  @Local pressedMenuId: string = ''
  private isAttached: boolean = false

  async aboutToAppear(): Promise<void> {
    this.isAttached = true
    if (!this.settingsVM.isLoaded) {
      this.isLoading = true
      this.isError = false
      await this.settingsVM.init(getContext(this)).then((): void => {
        this.isLoading = false
      }).catch((e: Error): void => {
        this.isLoading = false
        this.isError = true
        Logger.error('ProfilePage', 'aboutToAppear init failed: ' + e.message)
      })
      if (!this.isAttached) return
    }
  }

  aboutToDisappear(): void {
    this.isAttached = false
    this.settingsVM.flush()
  }

  onPageShow(): void {
    if (!this.isAttached) return
    if (!this.settingsVM.isLoaded) {
      if (!this.isLoading) {
        this.retryLoad()
      }
      return
    }
    // refreshUserProfile 已停用（登录信息在 applyLoginResult 时已同步，无需每次展示刷新）
    // 合规改造：游客可进入「我的」，页面内已有「未登录 / 去登录」卡片，不再强制跳登录
    // routeVM.init 已在 EntryAbility.onWindowStageCreate 中调用，此处为安全保障
    // 若用户在 routeVM 尚未完成 init 时切到本页，补充触发加载
    if (!routeVM.isLoaded) {
      routeVM.init(getContext(this)).then((): void => {
        Logger.info('ProfilePage', 'onPageShow: routeVM.init completed')
      }).catch((e: Error): void => {
        Logger.error('ProfilePage', 'onPageShow: routeVM.init failed: ' + e.message)
      })
    }
    if (!homeVM.isLoaded) {
      homeVM.init(getContext(this)).then((): void => {
        Logger.info('ProfilePage', 'onPageShow: homeVM.init completed')
      }).catch((e: Error): void => {
        Logger.error('ProfilePage', 'onPageShow: homeVM.init failed: ' + e.message)
      })
    }
  }

  private checkVmToast(): void {
    if (this.settingsVM.toastMessage.length > 0) {
      promptAction.showToast({ message: this.settingsVM.toastMessage, duration: 1500 })
      this.settingsVM.toastMessage = ''
    }
  }

  @Builder
  UserCardBuilder() {
    Column({ space: 12 }) {
      if (this.settingsVM.userProfile.isLoggedIn) {
        Row({ space: 14 }) {
          this.UserAvatarBuilder()

          this.UserInfoBuilder()
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      } else {
        Row({ space: 14 }) {
          Stack({ alignContent: Alignment.Center }) {
            Image($r('app.media.app_icon'))
              .width(52)
              .height(52)
              .borderRadius(26)
              .objectFit(ImageFit.Cover)
          }
          .width(56)
          .height(56)
          .borderRadius(28)
          .backgroundColor($r('app.color.icon_bg_gray'))
          .alignContent(Alignment.Center)

          Column({ space: 4 }) {
            Text($r('app.string.login_not_logged_in'))
              .fontSize(CommonConstants.FONT_SIZE_SUBTITLE)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))

            Text($r('app.string.login_please_login'))
              .fontSize(CommonConstants.FONT_SIZE_SMALL)
              .fontColor($r('app.color.text_tertiary'))
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Text($r('app.string.btn_go_login'))
            .fontSize(CommonConstants.FONT_SIZE_CAPTION)
            .fontColor($r('app.color.primary_color'))
            .fontWeight(FontWeight.Medium)
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .borderRadius(20)
            .backgroundColor($r('app.color.primary_color_bg'))
            .onClick(async (): Promise<void> => {
              const success = await this.settingsVM.handleHuaweiLogin(getContext(this) as common.Context)
              if (!success) {
                this.checkVmToast()
              }
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 18, bottom: 18 })
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(DimensConstants.RADIUS_L)
  }

  @Builder
  UserAvatarBuilder() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.settingsVM.userProfile.avatarUri.length > 0) {
        Image(this.settingsVM.userProfile.avatarUri)
          .width(52)
          .height(52)
          .borderRadius(26)
          .objectFit(ImageFit.Cover)
          .alt($r('app.media.app_icon'))
          .accessibilityText(getContext(this).resourceManager.getStringSync($r('app.string.avatar').id))
      } else {
        Image($r('app.media.app_icon'))
          .width(52)
          .height(52)
          .borderRadius(26)
          .objectFit(ImageFit.Cover)
          .accessibilityText(getContext(this).resourceManager.getStringSync($r('app.string.avatar').id))
      }
    }
    .width(56)
    .height(56)
    .borderRadius(28)
    .backgroundColor($r('app.color.icon_bg_gray'))
    .alignContent(Alignment.Center)
    .shadow({ radius: 6, color: $r('app.color.shadow_card'), offsetX: 0, offsetY: 2 })
  }

  @Builder
  UserInfoBuilder() {
    Column({ space: 6 }) {
      Text(safeStringUtil(this.settingsVM.userProfile.nickname, getContext(this).resourceManager.getStringSync($r('app.string.default_nickname').id)))
        .fontSize(CommonConstants.FONT_SIZE_TITLE)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      if (this.settingsVM.userProfile.email.length > 0) {
        Text(this.settingsVM.userProfile.email)
          .fontSize(CommonConstants.FONT_SIZE_XS)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      Text(safeStringUtil(this.settingsVM.userProfile.signature, getContext(this).resourceManager.getStringSync($r('app.string.default_signature').id)))
        .fontSize(CommonConstants.FONT_SIZE_SMALL)
        .fontColor($r('app.color.text_tertiary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Row({ space: 6 }) {
        Text($r('app.string.login_already_logged_in'))
          .fontSize(CommonConstants.FONT_SIZE_XXS)
          .fontColor($r('app.color.success_color'))
          .fontWeight(FontWeight.Medium)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor($r('app.color.success_color_bg'))
          .borderRadius(DimensConstants.RADIUS_M)

        Text(this.settingsVM.settings.syncEnabled ?
          $r('app.string.profile_sync_local_cloud') : $r('app.string.profile_sync_local_only'))
          .fontSize(CommonConstants.FONT_SIZE_XXS)
          .fontColor(this.settingsVM.settings.syncEnabled
            ? $r('app.color.success_color') : $r('app.color.text_tertiary'))
          .fontWeight(FontWeight.Medium)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(DimensConstants.RADIUS_M)
          .backgroundColor(this.settingsVM.settings.syncEnabled
            ? $r('app.color.success_color_bg') : $r('app.color.bg_tag'))
      }

      Text(this.formatSyncTime(this.settingsVM.userProfile.lastSyncTime))
        .fontSize(CommonConstants.FONT_SIZE_XXS)
        .fontColor($r('app.color.text_tertiary'))
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  SettingsGearBuilder() {
    Stack({ alignContent: Alignment.Center }) {
      SymbolGlyph($r('sys.symbol.gearshape'))
        .fontSize(CommonConstants.FONT_SIZE_TITLE)
        .fontColor([$r('app.color.icon_text_gray')])
    }
    .width(36)
    .height(36)
    .borderRadius(18)
    .backgroundColor($r('app.color.icon_bg_gray'))
    .alignContent(Alignment.Center)
    .onClick((): void => {
      navigateTo(ROUTE_NAME.SETTINGS)
    })
    .accessibilityText(getContext(this).resourceManager.getStringSync($r('app.string.acc_go_settings').id))
  }

  @Builder
  HeaderActionsBuilder() {
    Row({ space: 8 }) {
      // 设置齿轮：登录后才显示（设置页含账号/同步等登录相关项）
      if (this.settingsVM.userProfile.isLoggedIn) {
        this.SettingsGearBuilder()
      }
      // 通知入口：**始终显示**。通知中心的内容（专注完成 / 任务到期提醒）都来自本地事件，
      // 与登录状态无关；而「我的」页面下方那条指向同一路由的列表菜单项已删除，
      // 所以这里是全状态下**唯一**的通知入口，不能再挂在 isLoggedIn 条件里。
      this.NotificationBellBuilder()
    }
  }

  @Builder
  NotificationBellBuilder() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph($r('sys.symbol.bell'))
          .fontSize(CommonConstants.FONT_SIZE_SUBTITLE)
          .fontColor([$r('app.color.icon_text_orange')])
      }
      .width(36)
      .height(36)
      .borderRadius(18)
      .backgroundColor($r('app.color.icon_bg_orange'))
      .alignContent(Alignment.Center)
      .onClick((): void => {
        navigateTo(ROUTE_NAME.NOTIFICATION)
      })
      .accessibilityText(getContext(this).resourceManager.getStringSync($r('app.string.acc_notification_entry').id))

      if (notificationCenterService.unreadCount > 0) {
        Text(notificationCenterService.unreadCount > 99 ? '99+' : notificationCenterService.unreadCount.toString())
          .fontSize(CommonConstants.FONT_SIZE_MINI)
          .fontColor($r('app.color.text_inverse'))
          .backgroundColor($r('app.color.error_color'))
          .borderRadius(DimensConstants.RADIUS_S)
          .padding({ left: 5, right: 5, top: 1, bottom: 1 })
          .margin({ top: -4, right: -4 })
      }
    }
    .width(36)
    .height(36)
  }

  /**
   * 任务数据纵览卡片（L1 目标维度）
   * - 横向平铺三列：待开始 / 进行中 / 已完成
   * - 数据源（基于 L2 任务状态判定 L1 目标归属）：
   *   待开始   → routeVM.pendingGoalCount    （所有 L2 任务均为 PENDING 的目标数）
   *   进行中   → routeVM.inProgressGoalCount （至少一个 L2 任务为 IN_PROGRESS/COMPLETED，但非全部完成的目标数）
   *   已完成   → routeVM.completedGoalCount  （所有 L2 任务均为 COMPLETED 的目标数）
   *
   * 交互：
   *   - 三列分别绑定 onClick，携带 status 参数跳转 GoalHistoryPage
   *
   * 布局规范：
   *   - 数字 fontSize: 24, FontWeight.Bold，醒目展示
   *   - 标签 fontSize: 12, text_tertiary
   *   - 三列等宽 layoutWeight(1)，居中对齐
   *   - 列间用竖向 Divider 分隔
   */
  @Builder
  TaskDataOverviewBuilder() {
    Column({ space: 6 }) {
      Text($r('app.string.profile_data_overview_title'))
        .fontSize(CommonConstants.FONT_SIZE_BODY)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_secondary'))
        .padding({ left: 4 })

      Row() {
        // 进度环口径 = 所有目标的平均进度（非任务完成率），加标签避免与右侧状态计数混淆
        Column({ space: 2 }) {
          Stack({ alignContent: Alignment.Center }) {
            Progress({ value: routeVM.averageProgress, total: 100, type: ProgressType.Ring })
              .width(64)
              .height(64)
              .style({ strokeWidth: 8 })
              .color(routeVM.averageProgress >= 100 ?
                $r('app.color.success_color') : $r('app.color.primary_color'))
              .backgroundColor($r('app.color.bg_progress_track'))
            Text(routeVM.averageProgress.toString() + '%')
              .fontSize(CommonConstants.FONT_SIZE_MID)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
          }
          .width(64)
          .height(64)

          Text($r('app.string.profile_overview_ring_label'))
            .fontSize(CommonConstants.FONT_SIZE_XXS)
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(1)
        }
        .margin({ left: 8, right: 12 })

        Column({ space: 4 }) {
          Text(routeVM.pendingGoalCount.toString())
            .fontSize(CommonConstants.FONT_SIZE_XL)
            .fontWeight(FontWeight.Bold)
            .fontColor(routeVM.pendingGoalCount === 0 ?
              $r('app.color.text_tertiary') : $r('app.color.text_primary'))
          Text($r('app.string.profile_stat_todo'))
            .fontSize(CommonConstants.FONT_SIZE_XS)
            .fontColor($r('app.color.text_tertiary'))
        }
        .layoutWeight(1)
        .padding({ top: 12, bottom: 12 })
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .borderRadius(DimensConstants.RADIUS_M)
        .backgroundColor($r('app.color.status_pending_bg'))
        .onClick((): void => {
          const param: RouteParam = { id: '', status: 'pending' }
          pushNavPath(ROUTE_NAME.GOAL_HISTORY, param)
        })

        Column({ space: 4 }) {
          Text(routeVM.inProgressGoalCount.toString())
            .fontSize(CommonConstants.FONT_SIZE_XL)
            .fontWeight(FontWeight.Bold)
            .fontColor(routeVM.inProgressGoalCount === 0 ?
              $r('app.color.text_tertiary') : $r('app.color.primary_color'))
          Text($r('app.string.profile_stat_in_progress'))
            .fontSize(CommonConstants.FONT_SIZE_XS)
            .fontColor($r('app.color.text_tertiary'))
        }
        .layoutWeight(1)
        .padding({ top: 12, bottom: 12 })
        .margin({ left: 6 })
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .borderRadius(DimensConstants.RADIUS_M)
        .backgroundColor($r('app.color.status_in_progress_bg'))
        .onClick((): void => {
          const param: RouteParam = { id: '', status: 'inProgress' }
          pushNavPath(ROUTE_NAME.GOAL_HISTORY, param)
        })

        Column({ space: 4 }) {
          Text(routeVM.completedGoalCount.toString())
            .fontSize(CommonConstants.FONT_SIZE_XL)
            .fontWeight(FontWeight.Bold)
            .fontColor(routeVM.completedGoalCount === 0 ?
              $r('app.color.text_tertiary') : $r('app.color.success_color'))
          Text($r('app.string.profile_stat_completed'))
            .fontSize(CommonConstants.FONT_SIZE_XS)
            .fontColor($r('app.color.text_tertiary'))
        }
        .layoutWeight(1)
        .padding({ top: 12, bottom: 12 })
        .margin({ left: 6 })
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .borderRadius(DimensConstants.RADIUS_M)
        .backgroundColor($r('app.color.status_completed_bg'))
        .onClick((): void => {
          const param: RouteParam = { id: '', status: 'completed' }
          pushNavPath(ROUTE_NAME.GOAL_HISTORY, param)
        })

        Column({ space: 4 }) {
          Text(routeVM.overdueGoalCount.toString())
            .fontSize(CommonConstants.FONT_SIZE_XL)
            .fontWeight(FontWeight.Bold)
            .fontColor(routeVM.overdueGoalCount === 0 ?
              $r('app.color.text_tertiary') : $r('app.color.error_color'))
          Text($r('app.string.profile_stat_overdue'))
            .fontSize(CommonConstants.FONT_SIZE_XS)
            .fontColor($r('app.color.text_tertiary'))
        }
        .layoutWeight(1)
        .padding({ top: 12, bottom: 12 })
        .margin({ left: 6 })
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .borderRadius(DimensConstants.RADIUS_M)
        .backgroundColor($r('app.color.error_color_bg'))
        .onClick((): void => {
          const param: RouteParam = { id: '', status: 'overdue' }
          pushNavPath(ROUTE_NAME.GOAL_HISTORY, param)
        })
      }
      .width('100%')
      .backgroundColor($r('app.color.bg_card'))
      .borderRadius(DimensConstants.RADIUS_L)
      .padding({ left: 4, right: 8, top: 4, bottom: 4 })

      if (routeVM.pendingGoalCount === 0 &&
          routeVM.inProgressGoalCount === 0 &&
          routeVM.completedGoalCount === 0 &&
          routeVM.overdueGoalCount === 0) {
        Row({ space: 4 }) {
          Text($r('app.string.profile_empty_overview_hint'))
            .fontSize(CommonConstants.FONT_SIZE_XS)
            .fontColor($r('app.color.text_tertiary'))
        }
        .width('100%')
        .padding({ top: 8, bottom: 4 })
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .margin({ top: 16 })
  }

  @Builder
  ToolsGroupBuilder() {
    Column({ space: 6 }) {
      Text($r('app.string.profile_group_tools'))
        .fontSize(CommonConstants.FONT_SIZE_BODY)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_secondary'))
        .padding({ left: 4 })

      Column({ space: 0 }) {
        this.MenuItemBuilder('stats', $r('app.color.icon_bg_blue'), $r('app.color.icon_text_blue'),
          $r('sys.symbol.wand_and_stars'), $r('app.string.profile_item_ai_review'), (): void => {
            navigateTo(ROUTE_NAME.STATS)
          })
        Divider().color($r('app.color.divider')).padding({ left: 52, right: 16 })
        this.MenuItemBuilder('import_export', $r('app.color.icon_bg_green'), $r('app.color.icon_text_green'),
          $r('sys.symbol.doc_text'), $r('app.string.profile_item_import_export'), (): void => {
            navigateTo(ROUTE_NAME.IMPORT_EXPORT)
          })
        Divider().color($r('app.color.divider')).padding({ left: 52, right: 16 })
        this.MenuItemBuilder('tags', $r('app.color.icon_bg_purple'), $r('app.color.icon_text_purple'),
          $r('sys.symbol.label'), $r('app.string.profile_item_tag_manage'), (): void => {
            navigateTo(ROUTE_NAME.TAGS)
          })
      }
      .width('100%')
      .backgroundColor($r('app.color.bg_card'))
      .borderRadius(DimensConstants.RADIUS_L)
    }
    .width('100%')
    .margin({ top: 16 })
  }

  @Builder
  HelpGroupBuilder() {
    Column({ space: 6 }) {
      Text($r('app.string.profile_group_help'))
        .fontSize(CommonConstants.FONT_SIZE_BODY)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_secondary'))
        .padding({ left: 4 })

      Column({ space: 0 }) {
        this.MenuItemBuilder('help', $r('app.color.icon_bg_teal'), $r('app.color.icon_text_teal'),
          $r('sys.symbol.questionmark_circle'), $r('app.string.profile_item_help'), (): void => {
            navigateTo(ROUTE_NAME.HELP)
          })
        Divider().color($r('app.color.divider')).padding({ left: 52, right: 16 })
        this.MenuItemBuilder('feedback', $r('app.color.icon_bg_blue'), $r('app.color.icon_text_blue'),
          $r('sys.symbol.envelope'), $r('app.string.profile_item_feedback'), (): void => {
            navigateTo(ROUTE_NAME.FEEDBACK)
          })
        Divider().color($r('app.color.divider')).padding({ left: 52, right: 16 })
        this.MenuItemBuilder('about', $r('app.color.icon_bg_gray'), $r('app.color.icon_text_gray'),
          $r('sys.symbol.info_circle'), $r('app.string.profile_item_about'), (): void => {
            navigateTo(ROUTE_NAME.ABOUT)
          })
      }
      .width('100%')
      .backgroundColor($r('app.color.bg_card'))
      .borderRadius(DimensConstants.RADIUS_L)
    }
    .width('100%')
    .margin({ top: 16 })
  }

  @Builder
  MenuItemBuilder(menuId: string, iconBg: ResourceColor, iconColor: ResourceColor, icon: Resource,
    label: ResourceStr, onTap: () => void) {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph(icon)
          .fontSize(CommonConstants.FONT_SIZE_SUBTITLE)
          .fontColor([iconColor])
      }
      .width(32)
      .height(32)
      .borderRadius(DimensConstants.RADIUS_S)
      .backgroundColor(iconBg)
      .alignContent(Alignment.Center)

      Text(label)
        .fontSize(CommonConstants.FONT_SIZE_MID)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(CommonConstants.FONT_SIZE_SUBTITLE)
        .fontColor([$r('app.color.text_tertiary')])
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
    .opacity(this.pressedMenuId === menuId ? 0.55 : 1.0)
    .animation(MotionConstants.pressParam())
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down) {
        this.pressedMenuId = menuId
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressedMenuId = ''
      }
    })
    .onClick((): void => {
      onTap()
    })
  }

  private formatSyncTime(timestamp: number): string {
    // 修复：防御 NaN / 非数字 / 非正数，避免显示"NaN天同步"
    if (typeof timestamp !== 'number' || isNaN(timestamp) || timestamp <= 0) {
      return getContext(this).resourceManager.getStringSync($r('app.string.sync_not_synced').id)
    }
    const now: number = Date.now()
    const diff: number = now - timestamp
    if (diff < 60000) return getContext(this).resourceManager.getStringSync($r('app.string.sync_just_now').id)
    if (diff < 3600000) return Math.floor(diff / 60000).toString() + getContext(this).resourceManager.getStringSync($r('app.string.sync_minutes_ago_suffix').id)
    if (diff < 86400000) return Math.floor(diff / 3600000).toString() + getContext(this).resourceManager.getStringSync($r('app.string.sync_hours_ago_suffix').id)
    return Math.floor(diff / 86400000).toString() + getContext(this).resourceManager.getStringSync($r('app.string.sync_days_ago_suffix').id)
  }

  private retryLoad(): void {
    this.isError = false
    this.isLoading = true
    this.settingsVM.init(getContext(this)).then((): void => {
      this.isLoading = false
    }).catch((e: Error): void => {
      this.isLoading = false
      this.isError = true
      Logger.error('ProfilePage', 'retryLoad failed: ' + e.message)
    })
  }

  build() {
    Column() {
      // 吸顶标题栏（CommonTitleBar 统一处理标题 + 安全区），右侧注入设置齿轮 + 通知入口
      CommonTitleBar({
        title: $r('app.string.page_profile'),
        showBack: false,
        rightActions: (): void => {
          this.HeaderActionsBuilder()
        }
      })

      // 三态条件渲染：加载态 / 错误态 / 内容态（统一 StateView 组件）
      if (this.isLoading) {
        StateView({ mode: StateMode.LOADING })
      } else if (this.isError) {
        StateView({
          mode: StateMode.ERROR,
          errorMessage: $r('app.string.load_failed'),
          onRetry: (): void => {
            this.retryLoad()
          }
        })
      } else {
        Scroll() {
          Column() {
            Column() {
              // 1. 用户信息卡片（头像/昵称/签名 + 只读同步状态）
              this.UserCardBuilder()

              // 2. 任务数据纵览（待开始 / 进行中 / 已完成 / 已逾期 四列）
              this.TaskDataOverviewBuilder()

              // 3. 工具与管理（仅放 Tab 栏没有的功能）
              this.ToolsGroupBuilder()

              // 4. 帮助与信息
              this.HelpGroupBuilder()
            }
            // 宽屏适配：内容列限宽（平板 lg 放宽到 860，避免横屏两侧大片留白；手机保持 640）
            .constraintSize({
              maxWidth: breakpointState.isTablet
                ? DimensConstants.CONTENT_MAX_WIDTH_TABLET
                : DimensConstants.CONTENT_MAX_WIDTH
            })
            .width('100%')
            .padding({ left: 16, right: 16, top: 8, bottom: safeAreaHelper.getBottomWith(DimensConstants.TAB_CLEARANCE) })
            .backgroundColor($r('app.color.bg_page'))
          }
          // 宽屏居中：全宽包裹层 + alignItems Center，替代 Scroll.align（宽视口下不可靠）
          .width('100%')
          .alignItems(HorizontalAlign.Center)
        }
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
        .width('100%')
        .layoutWeight(1)

        .expandSafeArea([SafeAreaType.KEYBOARD])
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
