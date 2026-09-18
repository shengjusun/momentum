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
import { common, Want } from '@kit.AbilityKit'
import { i18n } from '@kit.LocalizationKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { DimensConstants } from '../common/constants/DimensConstants'
import { CommonConstants } from '../common/constants/CommonConstants'
import { fileIo as fs } from '@kit.CoreFileKit'
import { Logger } from '../common/utils/Logger'
import { settingsVM, SettingsViewModel } from '../viewmodel/SettingsViewModel'
import { NotificationToggleResult } from '../viewmodel/ProfileViewModel'
import { SyncResult } from '../common/services/CloudSyncService'
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
  /** 当前语言偏好：'default' 跟随系统 / 'zh' 简体中文 / 'en' English */
  @Local selectedLanguage: string = 'default'
  /** 是否启用「智感握姿」（悬浮按钮跟随左右手握持自动换边，默认开启） */
  @Local gripEnabled: boolean = true
  /**
   * 悬浮快捷按钮是否显示（全局偏好，与首页 / 路线页共用同一个存储键）
   * 页面内**长按** FAB 会把它置 false；本开关负责**恢复**。
   */
  @Local fabVisible: boolean = true
  private isAttached: boolean = false
  /** 语言可选项（id 同时作为 setAppPreferredLanguage 的参数） */
  private languageIds: string[] = ['default', 'zh', 'en']

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
    try {
      this.selectedLanguage = await StorageManager.getPreference(CommonConstants.STORAGE_KEY_LANGUAGE_PREF, 'default')
    } catch (e) {
      Logger.warn('SettingPage', 'load language pref failed: ' + (e as Error).message)
    }
    try {
      this.gripEnabled = await StorageManager.getPreferenceBool(
        CommonConstants.STORAGE_KEY_GRIP_AWARENESS, true)
    } catch (e) {
      Logger.warn('SettingPage', 'load grip pref failed: ' + (e as Error).message)
    }
    try {
      this.fabVisible = await StorageManager.getPreferenceBool(
        CommonConstants.STORAGE_KEY_FAB_VISIBLE, true)
    } catch (e) {
      Logger.warn('SettingPage', 'load fab visible pref failed: ' + (e as Error).message)
    }
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

  /**
   * 【立即同步】：文案不变，底层统一走 **merge**（双向并集合并）
   * - 已移除 force 强制上传覆盖：普通入口不再提供"用本地整包覆盖云端"的能力
   * - 结果提示：成功 / 未就绪 / 改动未上传（保留脏标记，恢复后自动重试）
   */
  private handleSync(): void {
    const uid: string = this.settingsVM.userProfile.huaweiUid
    if (uid.length === 0) {
      promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_login_required').id) })
      return
    }

    // 云端同步关闭时阻断手动同步
    if (!CloudDBSyncProxy.getInstance().canSync()) {
      promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_sync_disabled').id) })
      return
    }

    this.isSyncing = true
    this.settingsVM.syncNow('manual').then((result: SyncResult | null): void => {
      if (!this.isAttached) return
      this.isSyncing = false
      if (result === null) {
        // 被跳过（未就绪 / 抑制窗口）：提示稍后自动重试
        promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_sync_upload_pending').id) })
        return
      }
      if (result.outcome === 'ok') {
        promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_sync_success').id) })
      } else if (result.outcome === 'not_ready') {
        promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_sync_upload_pending').id) })
      } else {
        promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_sync_error').id) + ': ' + result.errorMsg })
      }
    }).catch((e: Error): void => {
      if (!this.isAttached) return
      this.isSyncing = false
      Logger.error('SettingPage', 'handleSync failed: ' + e.message)
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
    if (isOn) {
      // 从关变为开：**先二次确认、确认后才真正开启**
      // （开启动作内部会立即触发一次 merge；不能在校验前就发生网络请求）
      promptAction.showDialog({
        title: $r('app.string.profile_sync_enable_title'),
        message: getContext(this).resourceManager.getStringSync($r('app.string.profile_sync_enable_message').id),
        buttons: [
          { text: $r('app.string.common_cancel'), color: $r('app.color.text_tertiary') },
          { text: $r('app.string.profile_sync_enable_confirm'), color: $r('app.color.primary_color') }
        ]
      }).then((result: promptAction.ShowDialogSuccessResponse): void => {
        if (result.index === 1) {
          this.settingsVM.toggleSyncEnabled(true)
          promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.profile_sync_enabled_toast').id), duration: 1500 })
        } else {
          promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.profile_sync_enable_cancelled_toast').id), duration: 1500 })
        }
      }).catch((e: Error): void => {
        Logger.error('SettingPage', 'handleSyncToggle dialog failed: ' + e.message)
      })
    } else {
      // 从开变为关，直接生效
      this.settingsVM.toggleSyncEnabled(false)
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
          deadlineReminderService.rescheduleAll(homeVM.liveTasks)
          Logger.info('SettingPage', 'notification enabled, tasks reminders rescheduled, count=' + homeVM.liveTasks.length.toString())
        }
        if (routeVM.isLoaded) {
          deadlineReminderService.rescheduleAllGoals(routeVM.liveGoals)
          Logger.info('SettingPage', 'notification enabled, goals reminders rescheduled, count=' + routeVM.liveGoals.length.toString())
        }
      }
    }).catch((e: Error): void => {
      Logger.error('SettingPage', 'handleNotificationToggle failed, msg=' + e.message)
      promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_notification_error').id), duration: 1500 })
    })
  }

  /**
   * 提前量档位文案（0=截止当天 / 1 / 3 / 7 天）
   */
  private advanceLabel(days: number): Resource {
    if (days === 0) return $r('app.string.advance_option_same_day')
    if (days === 1) return $r('app.string.advance_option_1d')
    if (days === 3) return $r('app.string.advance_option_3d')
    return $r('app.string.advance_option_1w')
  }

  /**
   * 任务提前量变更：保存设置 + 立即重排任务提醒（通知关闭时仅保存，不重排）
   */
  private handleAdvanceTaskChange(days: number): void {
    this.settingsVM.setReminderAdvanceTaskDays(days)
    if (this.settingsVM.settings.notificationEnabled && homeVM.isLoaded) {
      deadlineReminderService.rescheduleAll(homeVM.liveTasks)
    }
  }

  /**
   * 目标提前量变更：保存设置 + 立即重排目标提醒（通知关闭时仅保存，不重排）
   */
  private handleAdvanceGoalChange(days: number): void {
    this.settingsVM.setReminderAdvanceGoalDays(days)
    if (this.settingsVM.settings.notificationEnabled && routeVM.isLoaded) {
      deadlineReminderService.rescheduleAllGoals(routeVM.liveGoals)
    }
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

  /** 语言选项的显示文案（已解析为字符串） */
  private languageLabel(id: string): string {
    if (id === 'zh') {
      return getContext(this).resourceManager.getStringSync($r('app.string.settings_language_zh').id)
    }
    if (id === 'en') {
      return getContext(this).resourceManager.getStringSync($r('app.string.settings_language_en').id)
    }
    return getContext(this).resourceManager.getStringSync($r('app.string.settings_language_default').id)
  }

  /**
   * 切换应用语言
   * - i18n.System.setAppPreferredLanguage 为系统级应用偏好，冷启动生效
   * - 本地持久化用户选择，用于设置页高亮当前项
   * - 因需冷启动生效，切换后弹窗询问是否立即重启（避免打断进行中的操作）
   */
  private handleLanguageChange(lang: string): void {
    if (this.selectedLanguage === lang) return
    this.selectedLanguage = lang
    StorageManager.setPreference(CommonConstants.STORAGE_KEY_LANGUAGE_PREF, lang).catch((e: Error): void => {
      Logger.warn('SettingPage', 'save language pref failed: ' + e.message)
    })
    try {
      i18n.System.setAppPreferredLanguage(lang)
      Logger.info('SettingPage', 'setAppPreferredLanguage -> ' + lang)
    } catch (e) {
      const err = e as BusinessError
      Logger.error('SettingPage', 'setAppPreferredLanguage failed: code=' + err.code.toString() +
        ', msg=' + err.message)
    }
    promptAction.showDialog({
      title: $r('app.string.settings_language_restart_title'),
      message: getContext(this).resourceManager.getStringSync($r('app.string.settings_language_restart_message').id),
      buttons: [
        { text: $r('app.string.settings_language_restart_later'), color: $r('app.color.text_tertiary') },
        { text: $r('app.string.settings_language_restart_now'), color: $r('app.color.primary_color') }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse): void => {
      if (result.index === 1) {
        this.restartApp()
      } else {
        promptAction.showToast({
          message: getContext(this).resourceManager.getStringSync($r('app.string.settings_language_restart_toast').id),
          duration: 2000
        })
      }
    }).catch((e: Error): void => {
      Logger.error('SettingPage', 'language restart dialog failed: ' + e.message)
    })
  }

  /**
   * 重启应用（使语言偏好立即生效）
   * - ApplicationContext.restartApp：不触发 onDestroy；需应用处于前台焦点态
   * - 失败时兜底提示用户手动重启
   */
  private restartApp(): void {
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext
      const want: Want = {
        bundleName: ctx.abilityInfo.bundleName,
        abilityName: ctx.abilityInfo.name
      }
      ctx.getApplicationContext().restartApp(want)
      Logger.info('SettingPage', 'restartApp invoked')
    } catch (e) {
      const err = e as BusinessError
      Logger.error('SettingPage', 'restartApp failed: code=' + err.code.toString() + ', msg=' + err.message)
      promptAction.showToast({
        message: getContext(this).resourceManager.getStringSync($r('app.string.settings_language_restart_toast').id),
        duration: 2000
      })
    }
  }

  /**
   * 切换「智感握姿」
   * - 此处只负责写偏好；RoutePage 在 onPageShow 时重新读取并同步订阅状态（切回该 Tab 即生效）
   * - 关闭后悬浮按钮复位右下角，不再跟随握持手
   */
  private handleGripToggle(isOn: boolean): void {
    this.gripEnabled = isOn
    StorageManager.setPreferenceBool(CommonConstants.STORAGE_KEY_GRIP_AWARENESS, isOn).catch((e: Error): void => {
      Logger.warn('SettingPage', 'save grip pref failed: ' + e.message)
    })
  }

  /**
   * 悬浮快捷按钮开关（恢复被长按隐藏的 FAB）
   *
   * 与"页面内长按隐藏"**写同一个偏好** `STORAGE_KEY_FAB_VISIBLE`，
   * 所以这个开关的状态天然反映"当前按钮是否被隐藏过"，不需要额外同步；
   * 用户切回首页 / 路线页时，那边会重读偏好并即时生效。
   */
  private handleFabToggle(isOn: boolean): void {
    this.fabVisible = isOn
    StorageManager.setPreferenceBool(CommonConstants.STORAGE_KEY_FAB_VISIBLE, isOn).catch((e: Error): void => {
      Logger.warn('SettingPage', 'save fab visible pref failed: ' + e.message)
    })
  }

  /* ============================================================
   * UI Builder
   * ============================================================ */

  /** 分组标题（设置页按功能分区：通用 / 云同步 / 通知与提醒 / 数据） */
  @Builder
  SectionTitleBuilder(title: Resource) {
    Text(title)
      .fontSize(CommonConstants.FONT_SIZE_SMALL)
      .fontColor($r('app.color.text_tertiary'))
      .width('100%')
      .padding({ left: 4, top: 16 })
      .textAlign(TextAlign.Start)
  }

  @Builder
  SettingsListBuilder() {
    // 分组一：通用（语言 / 智感握姿 / 悬浮快捷按钮）
    this.SectionTitleBuilder($r('app.string.settings_section_general'))
    Column({ space: 0 }) {
      // 语言 / Language
      Row({ space: 12 }) {
        Text($r('app.string.settings_language'))
          .fontSize(CommonConstants.FONT_SIZE_BODY)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Row({ space: 6 }) {
          ForEach(this.languageIds, (langId: string) => {
            Text(this.languageLabel(langId))
              .fontSize(CommonConstants.FONT_SIZE_XS)
              .fontColor(this.selectedLanguage === langId ?
                $r('app.color.text_inverse') : $r('app.color.text_secondary'))
              .backgroundColor(this.selectedLanguage === langId ?
                $r('app.color.primary_color') : $r('app.color.bg_tag'))
              .borderRadius(DimensConstants.RADIUS_M)
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .onClick((): void => {
                this.handleLanguageChange(langId)
              })
          }, (langId: string): string => langId)
        }
      }
      .width('100%')
      .constraintSize({ minHeight: 56 })
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)

      Divider().color($r('app.color.divider')).padding({ left: 12, right: 12 })

      // 智感握姿（悬浮按钮跟随左右手握持自动换边；官方接入原则建议提供用户开关）
      Row({ space: 12 }) {
        Column({ space: 2 }) {
          Text($r('app.string.settings_grip_awareness'))
            .fontSize(CommonConstants.FONT_SIZE_BODY)
            .fontColor($r('app.color.text_primary'))
          Text($r('app.string.settings_grip_awareness_desc'))
            .fontSize(CommonConstants.FONT_SIZE_XS)
            .fontColor($r('app.color.text_tertiary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Toggle({ type: ToggleType.Switch, isOn: this.gripEnabled })
          .selectedColor($r('app.color.primary_color'))
          .accessibilityText(getContext(this).resourceManager.getStringSync($r('app.string.settings_grip_awareness').id))
          .onChange((isOn: boolean): void => {
            this.handleGripToggle(isOn)
          })
      }
      .width('100%')
      .constraintSize({ minHeight: 56 })
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)

      Divider().color($r('app.color.divider')).padding({ left: 12, right: 12 })

      // 悬浮快捷按钮（首页 / 路线页右下角的 +；页面内长按可隐藏，此处恢复）
      Row({ space: 12 }) {
        Column({ space: 2 }) {
          Text($r('app.string.settings_fab_title'))
            .fontSize(CommonConstants.FONT_SIZE_BODY)
            .fontColor($r('app.color.text_primary'))
          Text($r('app.string.settings_fab_desc'))
            .fontSize(CommonConstants.FONT_SIZE_XS)
            .fontColor($r('app.color.text_tertiary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Toggle({ type: ToggleType.Switch, isOn: this.fabVisible })
          .selectedColor($r('app.color.primary_color'))
          .accessibilityText(getContext(this).resourceManager.getStringSync($r('app.string.settings_fab_title').id))
          .onChange((isOn: boolean): void => {
            this.handleFabToggle(isOn)
          })
      }
      .width('100%')
      .constraintSize({ minHeight: 56 })
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(DimensConstants.RADIUS_L)

    // 分组二：云同步（同步开关 / 立即同步）
    this.SectionTitleBuilder($r('app.string.settings_section_sync'))
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
      .stateStyles({
        pressed: { .backgroundColor($r('app.color.bg_tag')) },
        normal: { .backgroundColor(Color.Transparent) }
      })
      .onClick((): void => {
        this.handleSync()
      })
    }
    .width('100%')
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(DimensConstants.RADIUS_L)

    // 分组三：通知与提醒（通知权限 / 震动反馈 / 截止提醒提前量）
    this.SectionTitleBuilder($r('app.string.settings_section_notification'))
    Column({ space: 0 }) {
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

      // 震动反馈：完成场景三档触觉（步骤/任务/目标）与番茄钟结束共用此开关
      Row({ space: 12 }) {
        Column({ space: 2 }) {
          Text($r('app.string.settings_vibration'))
            .fontSize(CommonConstants.FONT_SIZE_BODY)
            .fontColor($r('app.color.text_primary'))
          Text($r('app.string.settings_vibration_desc'))
            .fontSize(CommonConstants.FONT_SIZE_XS)
            .fontColor($r('app.color.text_tertiary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Toggle({ type: ToggleType.Switch, isOn: this.settingsVM.settings.vibrationEnabled })
          .selectedColor($r('app.color.primary_color'))
          .accessibilityText(getContext(this).resourceManager.getStringSync($r('app.string.settings_vibration').id))
          .onChange((isOn: boolean): void => {
            this.settingsVM.setVibrationEnabled(isOn)
          })
      }
      .width('100%')
      .constraintSize({ minHeight: 56 })
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)

      Divider().color($r('app.color.divider')).padding({ left: 12, right: 12 })

      // 截止提醒提前量：任务
      Row({ space: 12 }) {
        Text($r('app.string.settings_advance_task_label'))
          .fontSize(CommonConstants.FONT_SIZE_BODY)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Row({ space: 6 }) {
          ForEach(CommonConstants.REMINDER_ADVANCE_OPTIONS, (days: number) => {
            Text(this.advanceLabel(days))
              .fontSize(CommonConstants.FONT_SIZE_XS)
              .fontColor(this.settingsVM.settings.reminderAdvanceTaskDays === days ?
                $r('app.color.text_inverse') : $r('app.color.text_secondary'))
              .backgroundColor(this.settingsVM.settings.reminderAdvanceTaskDays === days ?
                $r('app.color.primary_color') : $r('app.color.bg_tag'))
              .borderRadius(DimensConstants.RADIUS_M)
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .onClick((): void => {
                this.handleAdvanceTaskChange(days)
              })
          }, (days: number): string => 'task_advance_' + days.toString())
        }
      }
      .width('100%')
      .constraintSize({ minHeight: 56 })
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)
      .opacity(this.settingsVM.settings.notificationEnabled ? 1 : 0.45)

      Divider().color($r('app.color.divider')).padding({ left: 12, right: 12 })

      // 截止提醒提前量：目标
      Row({ space: 12 }) {
        Text($r('app.string.settings_advance_goal_label'))
          .fontSize(CommonConstants.FONT_SIZE_BODY)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Row({ space: 6 }) {
          ForEach(CommonConstants.REMINDER_ADVANCE_OPTIONS, (days: number) => {
            Text(this.advanceLabel(days))
              .fontSize(CommonConstants.FONT_SIZE_XS)
              .fontColor(this.settingsVM.settings.reminderAdvanceGoalDays === days ?
                $r('app.color.text_inverse') : $r('app.color.text_secondary'))
              .backgroundColor(this.settingsVM.settings.reminderAdvanceGoalDays === days ?
                $r('app.color.primary_color') : $r('app.color.bg_tag'))
              .borderRadius(DimensConstants.RADIUS_M)
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .onClick((): void => {
                this.handleAdvanceGoalChange(days)
              })
          }, (days: number): string => 'goal_advance_' + days.toString())
        }
      }
      .width('100%')
      .constraintSize({ minHeight: 56 })
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)
      .opacity(this.settingsVM.settings.notificationEnabled ? 1 : 0.45)
    }
    .width('100%')
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(DimensConstants.RADIUS_L)

    // 分组四：数据（清除缓存 / 删除所有数据）
    this.SectionTitleBuilder($r('app.string.settings_section_data'))
    Column({ space: 0 }) {
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
          .borderRadius(DimensConstants.RADIUS_L)
          .backgroundColor($r('app.color.primary_color_bg'))
      }
      .width('100%')
      .stateStyles({
        pressed: { .backgroundColor($r('app.color.bg_tag')) },
        normal: { .backgroundColor(Color.Transparent) }
      })
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
          .borderRadius(DimensConstants.RADIUS_L)
          .backgroundColor($r('app.color.error_color_bg'))
      }
      .width('100%')
      .stateStyles({
        pressed: { .backgroundColor($r('app.color.bg_tag')) },
        normal: { .backgroundColor(Color.Transparent) }
      })
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
    .borderRadius(DimensConstants.RADIUS_L)
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
