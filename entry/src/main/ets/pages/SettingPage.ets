/**
 * @file 设置页
 * @description 低频配置 + 账号安全（与「我的」主页职责分离）
 *   - 云端数据同步：开关 + 立即同步 + 上次同步时间
 *   - 通知权限：系统通知开关
 *   - 缓存管理：查看占用并清除缓存
 *   - 底部红色退出登录：二次确认（含同步失败强退二级确认）
 *
 * 跳转来源：ProfilePage 右上角齿轮入口
 *
 * @module pages
 */

import { promptAction } from '@kit.ArkUI'
import { CommonConstants } from '../common/constants/CommonConstants'
import { fileIo as fs } from '@kit.CoreFileKit'
import { Logger } from '../common/utils/Logger'
import { settingsVM, SettingsViewModel } from '../viewmodel/SettingsViewModel'
import { NotificationToggleResult } from '../viewmodel/ProfileViewModel'
import { CloudSyncService, SyncDataBundle, SyncApplyCallback } from '../common/services/CloudSyncService'
import { CloudDBSyncProxy } from '../common/services/CloudDBSyncProxy'
import { homeVM } from '../viewmodel/HomeViewModel'
import { routeVM } from '../viewmodel/RoutePageViewModel'
import { deadlineReminderService } from '../common/services/DeadlineReminderService'
import { PomodoroNotificationService } from '../common/services/PomodoroNotificationService'
import { globalNavStack, ROUTE_NAME, navigateTo } from '../common/RouterManager'
import { CommonTitleBar } from '../common/components/CommonTitleBar'
import { safeAreaHelper } from '../common/utils/SafeAreaHelper'
import { StorageManager } from '../common/utils/StorageManager'

@Entry
@ComponentV2
export struct SettingPage {
  settingsVM: SettingsViewModel = settingsVM

  @Local isSyncing: boolean = false
  @Local isLoaded: boolean = true
  @Local cacheSizeText: string = ''
  /** 一键删除所有数据执行中标志（防重复点击） */
  @Local isDeletingAll: boolean = false
  private isAttached: boolean = false

  async aboutToAppear(): Promise<void> {
    this.isAttached = true
    if (!this.settingsVM.isLoaded) {
      this.isLoaded = false
      await this.settingsVM.init(getContext(this)).then((): void => {
        this.isLoaded = true
      }).catch((e: Error): void => {
        this.isLoaded = true
        Logger.error('SettingPage', 'aboutToAppear init failed: ' + e.message)
      })
    }
    if (!this.isAttached) return
    this.refreshCacheSize()
  }

  aboutToDisappear(): void {
    this.isAttached = false
    this.settingsVM.flush()
  }

  private handleBack(): void {
    globalNavStack.pop()
  }

  /* ============================================================
   * 缓存管理
   * ============================================================ */

  private refreshCacheSize(): void {
    try {
      const cacheDir: string = getContext(this).cacheDir
      const files: string[] = fs.listFileSync(cacheDir)
      let totalBytes: number = 0
      for (let i: number = 0; i < files.length; i++) {
        try {
          const stat = fs.statSync(cacheDir + '/' + files[i])
          totalBytes += stat.size
        } catch (e) {
          // 单个文件统计失败跳过
        }
      }
      this.cacheSizeText = this.formatBytes(totalBytes)
    } catch (e) {
      Logger.warn('SettingPage', 'refreshCacheSize failed: ' + (e as Error).message)
      this.cacheSizeText = '0 B'
    }
  }

  private formatBytes(bytes: number): string {
    if (bytes < 1024) {
      return bytes.toString() + ' B'
    }
    const kb: number = bytes / 1024
    if (kb < 1024) {
      return kb.toFixed(1) + ' KB'
    }
    return (kb / 1024).toFixed(1) + ' MB'
  }

  private handleClearCache(): void {
    promptAction.showDialog({
      title: $r('app.string.dialog_clear_cache_title'),
      message: getContext(this).resourceManager.getStringSync($r('app.string.dialog_clear_cache_message').id),
      buttons: [
        { text: $r('app.string.common_cancel'), color: $r('app.color.text_tertiary') },
        { text: $r('app.string.dialog_clear_cache_title'), color: $r('app.color.primary_color') }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse): void => {
      if (!this.isAttached) return
      if (result.index === 1) {
        this.doClearCache()
      }
    }).catch((e: Error): void => {
      Logger.error('SettingPage', 'clear cache dialog failed: ' + e.message)
    })
  }

  private doClearCache(): void {
    try {
      StorageManager.clearCache()
      const cacheDir: string = getContext(this).cacheDir
      const files: string[] = fs.listFileSync(cacheDir)
      for (let i: number = 0; i < files.length; i++) {
        try {
          fs.unlinkSync(cacheDir + '/' + files[i])
        } catch (e) {
          // 单个文件删除失败不阻断流程
        }
      }
      this.refreshCacheSize()
      promptAction.showToast({
        message: getContext(this).resourceManager.getStringSync($r('app.string.toast_cache_cleared').id),
        duration: 1500
      })
    } catch (e) {
      Logger.error('SettingPage', 'clear cache failed: ' + (e as Error).message)
    }
  }

  /* ============================================================
   * 云端同步
   * ============================================================ */

  private handleSync(): void {
    const uid: string = this.settingsVM.userProfile.huaweiUid
    if (uid.length === 0) {
      promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_login_required').id) })
      return
    }

    // 云端同步关闭时阻断手动上传
    if (!CloudDBSyncProxy.getInstance().canSync()) {
      promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_sync_disabled').id) })
      return
    }

    this.isSyncing = true
    const goalsJson: string = JSON.stringify(routeVM.buildSnapshot())
    const todosJson: string = JSON.stringify(homeVM.buildSnapshot())
    // 策略：手动点击"立即同步"按钮，强制上传本地数据覆盖云端
    const syncData: SyncDataBundle = this.settingsVM.buildSyncDataBundle(goalsJson, todosJson, true)
    const syncCallback: SyncApplyCallback = this.settingsVM.buildSyncApplyCallback(
      (data: Record<string, Object>): void => { routeVM.applyCloudSnapshot(data) },
      (data: Record<string, Object>): void => { homeVM.applyCloudSnapshot(data) }
    )
    CloudSyncService.getInstance().smartSync(uid, syncData, syncCallback, 'upload', true).then((result): void => {
      if (!this.isAttached) return
      this.isSyncing = false
      if (result.success) {
        promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_sync_success').id) })
      } else {
        promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_sync_error').id) + ': ' + result.errorMsg })
      }
    }).catch((e: Error): void => {
      if (!this.isAttached) return
      this.isSyncing = false
      promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_sync_error').id) })
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

  private getSyncButtonText(): ResourceStr | string {
    if (!this.settingsVM.settings.syncEnabled) {
      return $r('app.string.profile_sync_off_text')
    }
    return this.isSyncing ? $r('app.string.btn_syncing') : $r('app.string.btn_sync_now')
  }

  private getSyncButtonColor(): ResourceColor {
    if (!this.settingsVM.settings.syncEnabled) {
      return $r('app.color.text_tertiary')
    }
    return $r('app.color.primary_color')
  }

  private handleSyncToggle(isOn: boolean): void {
    this.settingsVM.toggleSyncEnabled(isOn)

    if (isOn) {
      // 从关变为开，二次确认
      promptAction.showDialog({
        title: $r('app.string.profile_sync_enable_title'),
        message: getContext(this).resourceManager.getStringSync($r('app.string.profile_sync_enable_message').id),
        buttons: [
          { text: $r('app.string.common_cancel'), color: $r('app.color.text_tertiary') },
          { text: $r('app.string.profile_sync_enable_confirm'), color: $r('app.color.primary_color') }
        ]
      }).then((result: promptAction.ShowDialogSuccessResponse): void => {
        if (result.index === 1) {
          promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.profile_sync_enabled_toast').id), duration: 1500 })
        } else {
          // 用户取消，回滚
          this.settingsVM.toggleSyncEnabled(false)
          promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.profile_sync_enable_cancelled_toast').id), duration: 1500 })
        }
      }).catch((e: Error): void => {
        Logger.error('SettingPage', 'handleSyncToggle dialog failed: ' + e.message)
        // 异常时也回滚
        this.settingsVM.toggleSyncEnabled(false)
      })
    } else {
      // 从开变为关，直接生效
      promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.profile_sync_disabled_toast').id), duration: 1500 })
    }
  }

  /* ============================================================
   * 删除所有数据（高危操作：本地 + 云端业务数据全删，二次确认）
   * ============================================================ */

  private handleDeleteAllData(): void {
    // 防重复点击：上一次删除还在执行中
    if (this.isDeletingAll) {
      return
    }
    promptAction.showDialog({
      title: $r('app.string.dialog_delete_all_title'),
      message: getContext(this).resourceManager.getStringSync($r('app.string.dialog_delete_all_message').id),
      buttons: [
        { text: $r('app.string.common_cancel'), color: $r('app.color.text_tertiary') },
        { text: $r('app.string.btn_confirm_delete'), color: $r('app.color.error_color') }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse): void => {
      if (!this.isAttached) return
      if (result.index === 1) {
        this.doDeleteAllData()
      }
    }).catch((e: Error): void => {
      Logger.error('SettingPage', 'delete all data dialog failed: ' + e.message)
    })
  }

  private doDeleteAllData(): void {
    this.isDeletingAll = true
    this.settingsVM.deleteAllData(getContext(this)).then((ok: boolean): void => {
      if (!this.isAttached) {
        this.isDeletingAll = false
        return
      }
      this.isDeletingAll = false
      this.refreshCacheSize()
      promptAction.showToast({
        message: ok
          ? getContext(this).resourceManager.getStringSync($r('app.string.toast_delete_all_success').id)
          : getContext(this).resourceManager.getStringSync($r('app.string.toast_delete_all_failed').id),
        duration: 1500
      })
    }).catch((e: Error): void => {
      if (!this.isAttached) {
        this.isDeletingAll = false
        return
      }
      this.isDeletingAll = false
      Logger.error('SettingPage', 'deleteAllData failed: ' + e.message)
      promptAction.showToast({
        message: getContext(this).resourceManager.getStringSync($r('app.string.toast_delete_all_failed').id),
        duration: 1500
      })
    })
  }

  /* ============================================================
   * 通知权限
   * ============================================================ */

  private handleNotificationToggle(isOn: boolean): void {
    this.settingsVM.toggleNotification(isOn).then((result: NotificationToggleResult): void => {
      if (!result.success) {
        promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_notification_failed').id) + '：' + result.errorMsg, duration: 1500 })
        return
      }
      // 开关切换成功后联动已排程提醒：
      //   - 关闭：取消所有截止日期提醒 + 取消番茄钟常驻通知
      //   - 开启：按当前任务/目标数据重建截止日期提醒
      if (!result.finalState) {
        deadlineReminderService.cancelAllReminders()
        PomodoroNotificationService.getInstance().cancelCountdown().catch((e: Error): void => {
          Logger.warn('SettingPage', 'cancelCountdown failed: ' + e.message)
        })
        Logger.info('SettingPage', 'notification disabled, all scheduled reminders canceled')
      } else {
        if (homeVM.isLoaded) {
          deadlineReminderService.rescheduleAll(homeVM.taskList)
          Logger.info('SettingPage', 'notification enabled, tasks reminders rescheduled, count=' + homeVM.taskList.length.toString())
        }
        if (routeVM.isLoaded) {
          deadlineReminderService.rescheduleAllGoals(routeVM.goals)
          Logger.info('SettingPage', 'notification enabled, goals reminders rescheduled, count=' + routeVM.goals.length.toString())
        }
      }
    }).catch((e: Error): void => {
      Logger.error('SettingPage', 'handleNotificationToggle failed, msg=' + e.message)
      promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_notification_error').id), duration: 1500 })
    })
  }

  /* ============================================================
   * 退出登录（高危操作：二次确认）
   * ============================================================ */

  private handleLogout(): void {
    // [安全确认] 云同步关闭时登出会清除本地数据且无法恢复，需明确警告
    const syncDisabled: boolean = !CloudDBSyncProxy.getInstance().canSync()
    const logoutMessage: string = syncDisabled
      ? getContext(this).resourceManager.getStringSync($r('app.string.dialog_logout_no_sync_message').id)
      : getContext(this).resourceManager.getStringSync($r('app.string.dialog_logout_message').id)
    promptAction.showDialog({
      title: $r('app.string.dialog_logout_title'),
      message: logoutMessage,
      buttons: [
        { text: $r('app.string.common_cancel'), color: $r('app.color.text_tertiary') },
        { text: $r('app.string.btn_exit'), color: $r('app.color.error_color') }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse): void => {
      if (!this.isAttached) return
      if (result.index === 1) {
        this.settingsVM.logout(getContext(this)).then((success: boolean): void => {
          if (!this.isAttached) return
          if (success) {
            globalNavStack.clear()
            navigateTo(ROUTE_NAME.LOGIN)
          } else if (this.settingsVM.logoutUploadFailed) {
            promptAction.showDialog({
              title: $r('app.string.dialog_sync_failed_title'),
              message: getContext(this).resourceManager.getStringSync($r('app.string.dialog_sync_failed_message').id),
              buttons: [
                { text: $r('app.string.common_cancel'), color: $r('app.color.text_tertiary') },
                { text: $r('app.string.btn_force_exit'), color: $r('app.color.error_color') }
              ]
            }).then((confirmResult: promptAction.ShowDialogSuccessResponse): void => {
              if (!this.isAttached) return
              if (confirmResult.index === 1) {
                this.settingsVM.forceLogout(getContext(this)).then((forceSuccess: boolean): void => {
                  if (!this.isAttached) return
                  if (forceSuccess) {
                    globalNavStack.clear()
                    navigateTo(ROUTE_NAME.LOGIN)
                  }
                }).catch((e: Error): void => {
                  Logger.error('SettingPage', 'forceLogout failed: ' + e.message)
                })
              }
            }).catch((e: Error): void => {
              Logger.error('SettingPage', 'logoutUploadFailed confirm dialog failed: ' + e.message)
            })
          }
        }).catch((e: Error): void => {
          Logger.error('SettingPage', 'logout failed: ' + e.message)
        })
      }
    }).catch((e: Error): void => {
      Logger.error('SettingPage', 'handleLogout dialog failed: ' + e.message)
    })
  }

  /* ============================================================
   * UI Builder
   * ============================================================ */

  @Builder
  SettingsListBuilder() {
    Column({ space: 0 }) {
      // 云端数据同步开关
      Row({ space: 12 }) {
        Column({ space: 2 }) {
          Text($r('app.string.profile_cloud_sync_title'))
            .fontSize(CommonConstants.FONT_SIZE_BODY)
            .fontColor($r('app.color.text_primary'))
          Text(this.settingsVM.settings.syncEnabled ?
            $r('app.string.profile_sync_local_cloud') : $r('app.string.profile_sync_disabled_hint'))
            .fontSize(CommonConstants.FONT_SIZE_XS)
            .fontColor(this.settingsVM.settings.syncEnabled
              ? $r('app.color.primary_color') : $r('app.color.text_tertiary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Toggle({ type: ToggleType.Switch, isOn: this.settingsVM.settings.syncEnabled })
          .selectedColor($r('app.color.primary_color'))
          .accessibilityText(getContext(this).resourceManager.getStringSync($r('app.string.profile_cloud_sync_toggle_acc').id))
          .onChange((isOn: boolean): void => {
            this.handleSyncToggle(isOn)
          })
      }
      .width('100%')
      .constraintSize({ minHeight: 56 })
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)

      Divider().color($r('app.color.divider')).padding({ left: 12, right: 12 })

      // 立即同步（低频操作：主动上传本地数据到云端）
      Row({ space: 12 }) {
        Column({ space: 2 }) {
          Text(this.getSyncButtonText())
            .fontSize(CommonConstants.FONT_SIZE_BODY)
            .fontColor(this.getSyncButtonColor())
          Text(this.formatSyncTime(this.settingsVM.userProfile.lastSyncTime))
            .fontSize(CommonConstants.FONT_SIZE_XS)
            .fontColor($r('app.color.text_tertiary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(CommonConstants.FONT_SIZE_SUBTITLE)
          .fontColor([$r('app.color.text_tertiary')])
      }
      .width('100%')
      .constraintSize({ minHeight: 56 })
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)
      .opacity(this.settingsVM.settings.syncEnabled ? 1 : 0.45)
      .onClick((): void => {
        this.handleSync()
      })

      Divider().color($r('app.color.divider')).padding({ left: 12, right: 12 })

      // 通知权限
      Row({ space: 12 }) {
        Column({ space: 2 }) {
          Text($r('app.string.settings_notification'))
            .fontSize(CommonConstants.FONT_SIZE_BODY)
            .fontColor($r('app.color.text_primary'))
          Text($r('app.string.settings_notification_desc'))
            .fontSize(CommonConstants.FONT_SIZE_XS)
            .fontColor($r('app.color.text_tertiary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Toggle({ type: ToggleType.Switch, isOn: this.settingsVM.settings.notificationEnabled })
          .selectedColor($r('app.color.primary_color'))
          .accessibilityText(getContext(this).resourceManager.getStringSync($r('app.string.acc_notification_toggle').id))
          .onChange((isOn: boolean): void => {
            this.handleNotificationToggle(isOn)
          })
      }
      .width('100%')
      .constraintSize({ minHeight: 56 })
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)

      Divider().color($r('app.color.divider')).padding({ left: 12, right: 12 })

      // 清除缓存
      Row({ space: 12 }) {
        Column({ space: 2 }) {
          Text($r('app.string.settings_cache_title'))
            .fontSize(CommonConstants.FONT_SIZE_BODY)
            .fontColor($r('app.color.text_primary'))
          Text(this.cacheSizeText)
            .fontSize(CommonConstants.FONT_SIZE_XS)
            .fontColor($r('app.color.text_tertiary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Text($r('app.string.mine_item_clear_cache'))
          .fontSize(CommonConstants.FONT_SIZE_SMALL)
          .fontColor($r('app.color.primary_color'))
          .fontWeight(FontWeight.Medium)
          .padding({ left: 12, right: 12, top: 5, bottom: 5 })
          .borderRadius(14)
          .backgroundColor($r('app.color.primary_color_bg'))
      }
      .width('100%')
      .constraintSize({ minHeight: 56 })
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)
      .onClick((): void => {
        this.handleClearCache()
      })

      Divider().color($r('app.color.divider')).padding({ left: 12, right: 12 })

      // 删除所有数据（高危：本地 + 云端业务数据全删，红色警示 + 二次确认）
      Row({ space: 12 }) {
        Column({ space: 2 }) {
          Text($r('app.string.settings_delete_all_data'))
            .fontSize(CommonConstants.FONT_SIZE_BODY)
            .fontColor($r('app.color.error_color'))
          Text($r('app.string.settings_delete_all_data_desc'))
            .fontSize(CommonConstants.FONT_SIZE_XS)
            .fontColor($r('app.color.text_tertiary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Text($r('app.string.btn_delete'))
          .fontSize(CommonConstants.FONT_SIZE_SMALL)
          .fontColor($r('app.color.error_color'))
          .fontWeight(FontWeight.Medium)
          .padding({ left: 12, right: 12, top: 5, bottom: 5 })
          .borderRadius(14)
          .backgroundColor($r('app.color.error_color_bg'))
      }
      .width('100%')
      .constraintSize({ minHeight: 56 })
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)
      .opacity(this.isDeletingAll ? 0.45 : 1)
      .onClick((): void => {
        this.handleDeleteAllData()
      })
    }
    .width('100%')
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(16)
  }

  @Builder
  LogoutBuilder() {
    Button($r('app.string.mine_logout'))
      .type(ButtonType.Capsule)
      .width('100%')
      .height(48)
      .fontSize(CommonConstants.FONT_SIZE_MID)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.text_inverse'))
      .backgroundColor($r('app.color.error_color'))
      .onClick((): void => {
        this.handleLogout()
      })
  }

  build() {
    NavDestination() {
      Column() {
        CommonTitleBar({
          title: $r('app.string.page_settings'),
          showBack: true,
          onBack: (): void => {
            this.handleBack()
          }
        })

        if (!this.isLoaded) {
          Column() {
            LoadingProgress()
              .width(40)
              .height(40)
              .color($r('app.color.primary_color'))
            Text($r('app.string.loading'))
              .fontSize(CommonConstants.FONT_SIZE_BODY)
              .fontColor($r('app.color.text_tertiary'))
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        } else {
          Scroll() {
            Column({ space: 16 }) {
              this.SettingsListBuilder()

              this.LogoutBuilder()
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 8, bottom: safeAreaHelper.getBottomWith(24) })
          }
          .scrollBar(BarState.Auto)
          .edgeEffect(EdgeEffect.Spring)
          .width('100%')
          .layoutWeight(1)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))
    }
    .hideTitleBar(true)
    .onBackPressed((): boolean => {
      this.handleBack()
      return true
    })
  }
}
