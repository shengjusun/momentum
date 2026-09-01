// 设置页 ViewModel：通知/隐私/震动/云同步 5 大设置 + 华为登录态 + 本地与云端持久化

import { AppSettings, UserProfile } from '../model/Models'
import { Logger } from '../common/utils/Logger'
import { StorageManager } from '../common/utils/StorageManager'
import { CommonConstants } from '../common/constants/CommonConstants'
import { profileVM, NotificationToggleResult } from './ProfileViewModel'
import { HuaweiAuthService, HuaweiUserInfo } from '../common/services/HuaweiAuthService'
import { CloudSyncService, SyncDataBundle, SyncApplyCallback, SyncDirection } from '../common/services/CloudSyncService'
import { CloudDBSyncProxy } from '../common/services/CloudDBSyncProxy'

import { PersistHelper } from '../common/utils/PersistHelper'
// 事件总线，解耦 ViewModel 循环依赖
import { eventBus, EventType } from '../common/event/AppEventBus'

import { common } from '@kit.AbilityKit'

// 持久化快照：与 @Trace 字段一一对应，用于 Preferences 序列化
interface SettingsVMSnapshot {
  notificationEnabled: boolean
  privacyAgreed: boolean
  vibrationEnabled: boolean
  syncEnabled: boolean
  version: number
}

interface UserProfileVMSnapshot {
  id: string
  nickname: string
  signature: string
  avatarUri: string
  email: string
  aiCredits: string
  huaweiUid: string
  isLoggedIn: boolean
  lastSyncTime: number
}

@ObservedV2
export class SettingsViewModel {
  private readonly tag: string = 'SettingsViewModel'

  // V2 核心状态容器，必须 new AppSettings() 避免代理失效
  @Trace settings: AppSettings = new AppSettings()

  @Trace isLoaded: boolean = false
  @Trace isProcessing: boolean = false
  @Trace isLoading: boolean = false

  @Trace userProfile: UserProfile = new UserProfile()

  // 统一提示文本，页面绑定后统一弹窗
  @Trace toastMessage: string = ''

  @Trace logoutUploadFailed: boolean = false

  private context: Context | null = null
  // 事件总线订阅 ID
  private syncNeededCbId: number = -1

  // 本地有未上传修改标志，triggerCloudSync 时置 true，buildLocalSyncDataBundle 取出后重置
  // 保护本地新数据不被云端旧数据覆盖
  private forceUploadFlag: boolean = false

  // 云同步回环阻断：同步回调写回本地时置 true，onScheduleFire 检测后跳过云同步
  private isApplyingSyncData: boolean = false

  // triggerCloudSync 防抖定时器，避免静止状态周期 Upsert
  private syncDebounceTimer: number = -1

  private persistHelper: PersistHelper = new PersistHelper(
    'SettingsViewModel',
    async (): Promise<void> => { await this.persistData() },
    200,
    (): void => {
      // 同步回调写回触发的保存直接吞掉，不再触发云同步，阻断回环
      if (this.isApplyingSyncData) {
        Logger.info(this.tag, 'onScheduleFire skipped: applying sync data write-back, break loop')
        this.isApplyingSyncData = false
        return
      }
      this.triggerCloudSync()
    }
  )

  // 快照提供者（由 MainTab 注入，避免循环依赖）
  private goalsSnapshotProvider: (() => string) | null = null
  private todosSnapshotProvider: (() => string) | null = null
  private goalsApplyCallback: ((data: Record<string, Object>) => void) | null = null
  private todosApplyCallback: ((data: Record<string, Object>) => void) | null = null

  private static readonly STORAGE_KEY: string = CommonConstants.STORAGE_KEY_APP_SETTINGS
  private static readonly CURRENT_VERSION: number = 1

  // 初始化与持久化

  // 初始化入口：加载快照 → 逐字段赋值复活 → 标记 isLoaded
  async init(context: Context): Promise<void> {
    if (context === null || context === undefined) {
      Logger.error(this.tag, 'init: context is null, skip')
      this.isLoaded = true
      return
    }
    if (this.isLoading) {
      Logger.info(this.tag, 'init: already loading, skip')
      return
    }
    if (this.isLoaded) {
      return
    }
    this.isLoading = true
    this.context = context
    profileVM.init(context)

    // 注册事件总线订阅（幂等：重复 init 时先 off 再 on）
    if (this.syncNeededCbId > 0) {
      eventBus.off(EventType.SYNC_NEEDED, this.syncNeededCbId)
    }
    this.syncNeededCbId = eventBus.on(EventType.SYNC_NEEDED, (payload: Object): void => {
      this.triggerCloudSync()
    })

    try {
      const raw: SettingsVMSnapshot | null = await StorageManager.loadData<SettingsVMSnapshot | null>(
        this.context,
        SettingsViewModel.STORAGE_KEY,
        null
      )
      const snapshot: SettingsVMSnapshot = raw ?? this.buildEmptySnapshot()
      this.migrateIfNeeded(snapshot.version)
      this.applySnapshot(snapshot)
      Logger.info(this.tag,
        'init success, notification=' + this.settings.notificationEnabled.toString() +
        ', privacy=' + this.settings.privacyAgreed.toString())

      // 将 syncEnabled 状态同步到代理层
      CloudDBSyncProxy.getInstance().setSyncEnabled(this.settings.syncEnabled)
    } catch (e) {
      Logger.error(this.tag, 'init failed, use defaults, msg=' + (e as Error).message)
      this.applySnapshot(this.buildEmptySnapshot())
      // 加载失败时也用默认值（false）同步代理
      CloudDBSyncProxy.getInstance().setSyncEnabled(false)
    }

    try {
      const profileSnapshot: UserProfileVMSnapshot | null =
        await StorageManager.loadData<UserProfileVMSnapshot | null>(
          this.context,
          CommonConstants.STORAGE_KEY_USER_PROFILE,
          null
        )
      if (profileSnapshot !== null) {
        this.userProfile = new UserProfile(
          profileSnapshot.id,
          profileSnapshot.nickname,
          profileSnapshot.signature,
          profileSnapshot.avatarUri,
          profileSnapshot.email,
          profileSnapshot.aiCredits,
          profileSnapshot.huaweiUid,
          profileSnapshot.isLoggedIn,
          profileSnapshot.lastSyncTime
        )
        this.syncLoginStateToAppStorage()
        Logger.info(this.tag, 'userProfile loaded, isLoggedIn=' +
          this.userProfile.isLoggedIn.toString())
      }
    } catch (e) {
      Logger.error(this.tag, 'load userProfile failed, msg=' + (e as Error).message)
    }

    try {
      // 云端同步关闭时跳过所有自动下载
      if (!CloudDBSyncProxy.getInstance().canSync()) {
        Logger.info(this.tag, 'init: sync disabled, skip auto download. ' +
          'Local data loaded: settings.notification=' + this.settings.notificationEnabled.toString() +
          ', settings.syncEnabled=' + this.settings.syncEnabled.toString() +
          ', userProfile.isLoggedIn=' + this.userProfile.isLoggedIn.toString() +
          ', userProfile.huaweiUid.length=' + this.userProfile.huaweiUid.length.toString() +
          ', userProfile.lastSyncTime=' + this.userProfile.lastSyncTime.toString())
        return
      }
      if (this.userProfile.isLoggedIn && this.userProfile.huaweiUid.length > 0) {
        const syncData: SyncDataBundle = this.buildLocalSyncDataBundle()
        const syncCallback: SyncApplyCallback = this.buildLocalSyncApplyCallback()
        // 冷启动自动合并云端数据，并集合并不覆盖本地独有数据
        CloudSyncService.getInstance().smartSync(this.userProfile.huaweiUid, syncData, syncCallback, 'merge')
          .then((r): void => {
            Logger.info(this.tag, 'auto smartSync on init, direction=' + r.direction)
            if (r.direction === 'error') {
              this.toastMessage = this.context !== null
                ? this.context.resourceManager.getStringByNameSync('toast_sync_error')
                : r.errorMsg
            }
          }).catch((e: Error): void => {
            Logger.error(this.tag, 'auto smartSync failed: ' + e.message)
            this.toastMessage = this.context !== null
              ? this.context.resourceManager.getStringByNameSync('toast_sync_error')
              : e.message
          })
      }
    } finally {
      this.isLoaded = true
      this.isLoading = false
    }
  }

  // 从 Preferences 重新读取 userProfile，确保从后台切回时状态最新
  async refreshUserProfile(): Promise<void> {
    if (this.context === null) return
    try {
      const profileSnapshot: UserProfileVMSnapshot | null =
        await StorageManager.loadData<UserProfileVMSnapshot | null>(
          this.context,
          CommonConstants.STORAGE_KEY_USER_PROFILE,
          null
        )
      if (profileSnapshot !== null) {
        this.userProfile = new UserProfile(
          profileSnapshot.id,
          profileSnapshot.nickname,
          profileSnapshot.signature,
          profileSnapshot.avatarUri,
          profileSnapshot.email,
          profileSnapshot.aiCredits,
          profileSnapshot.huaweiUid,
          profileSnapshot.isLoggedIn,
          profileSnapshot.lastSyncTime
        )
        this.syncLoginStateToAppStorage()
        Logger.info(this.tag, 'refreshUserProfile done, isLoggedIn=' +
          this.userProfile.isLoggedIn.toString())
      }
    } catch (e) {
      Logger.error(this.tag, 'refreshUserProfile failed, msg=' + (e as Error).message)
    }
  }

  // 应用快照：new AppSettings() + 逐字段赋值（禁止 as 强转，保证 @Trace 生效）
  private applySnapshot(snapshot: SettingsVMSnapshot): void {
    const rehydrated: AppSettings = new AppSettings()
    rehydrated.notificationEnabled = typeof snapshot.notificationEnabled === 'boolean'
      ? snapshot.notificationEnabled : true
    rehydrated.privacyAgreed = typeof snapshot.privacyAgreed === 'boolean'
      ? snapshot.privacyAgreed : false
    rehydrated.vibrationEnabled = typeof snapshot.vibrationEnabled === 'boolean'
      ? snapshot.vibrationEnabled : true
    rehydrated.syncEnabled = typeof snapshot.syncEnabled === 'boolean'
      ? snapshot.syncEnabled : false
    // 整体替换 settings，@Trace 触发 UI 刷新
    this.settings = rehydrated
  }

  // 快照版本迁移：version 缺失或低于当前版本时执行，预留扩展点
  private migrateIfNeeded(savedVersion: number | undefined): void {
    const version: number = savedVersion ?? 0
    if (version < SettingsViewModel.CURRENT_VERSION) {
      // 未来版本升级在此添加迁移逻辑
      Logger.info(this.tag, 'migrating from version ' + version.toString() +
        ' to ' + SettingsViewModel.CURRENT_VERSION.toString())
    }
  }

  /** 构造空快照（默认配置） */
  private buildEmptySnapshot(): SettingsVMSnapshot {
    return {
      notificationEnabled: true,
      privacyAgreed: false,
      vibrationEnabled: true,
      syncEnabled: false,
      version: SettingsViewModel.CURRENT_VERSION
    }
  }

  // 防抖持久化，委托 PersistHelper 合并多次连续修改
  private scheduleSave(): void {
    if (this.context === null) {
      return
    }
    this.persistHelper.scheduleSave()
  }

  // 立即持久化（测试/外部调用）
  async persistNow(): Promise<void> {
    await this.persistHelper.flush()
  }

  // 页面退出时强制刷盘
  async flush(): Promise<void> {
    await this.persistHelper.flush()
  }

  // 实际持久化逻辑：settings + userProfile 两部分写入
  private async persistData(): Promise<void> {
    if (this.context === null) {
      return
    }
    const ctx: Context = this.context
    try {
      const snapshot: SettingsVMSnapshot = {
        notificationEnabled: this.settings.notificationEnabled,
        privacyAgreed: this.settings.privacyAgreed,
        vibrationEnabled: this.settings.vibrationEnabled,
        syncEnabled: this.settings.syncEnabled,
        version: SettingsViewModel.CURRENT_VERSION
      }
      await StorageManager.saveData(ctx, SettingsViewModel.STORAGE_KEY, snapshot as object)
      Logger.info(this.tag,
        'persistNow success, key=' + SettingsViewModel.STORAGE_KEY)
    } catch (e) {
      Logger.error(this.tag,
        'persistNow failed, msg=' + (e as Error).message)
    }

    try {
      const profileSnapshot: UserProfileVMSnapshot = {
        id: this.userProfile.id,
        nickname: this.userProfile.nickname,
        signature: this.userProfile.signature,
        avatarUri: this.userProfile.avatarUri,
        email: this.userProfile.email,
        aiCredits: this.userProfile.aiCredits,
        huaweiUid: this.userProfile.huaweiUid,
        isLoggedIn: this.userProfile.isLoggedIn,
        lastSyncTime: this.userProfile.lastSyncTime
      }
      await StorageManager.saveData(ctx, CommonConstants.STORAGE_KEY_USER_PROFILE,
        profileSnapshot as object)
    } catch (e) {
      Logger.error(this.tag, 'persistNow userProfile failed, msg=' + (e as Error).message)
    }
  }

  private buildLocalSyncDataBundle(): SyncDataBundle {
    // 快照提供者为 null 说明对应模块未注入，传空字符串让 smartSync 做 null protection 合并
    const goalsJson: string = this.goalsSnapshotProvider !== null ? this.goalsSnapshotProvider() : ''
    const todosJson: string = this.todosSnapshotProvider !== null ? this.todosSnapshotProvider() : ''
    // 取出强制上传标志并重置，防止下次没修改也强制上传
    const forceUpload: boolean = this.forceUploadFlag
    this.forceUploadFlag = false
    Logger.info(this.tag, 'buildLocalSyncDataBundle: goalsEmpty=' + (goalsJson.length === 0).toString() +
      ' todosEmpty=' + (todosJson.length === 0).toString() + ' forceUpload=' + forceUpload.toString())
    const profileSnapshot: UserProfileVMSnapshot = {
      id: this.userProfile.id,
      nickname: this.userProfile.nickname,
      signature: this.userProfile.signature,
      avatarUri: this.userProfile.avatarUri,
      email: this.userProfile.email,
      aiCredits: this.userProfile.aiCredits,
      huaweiUid: this.userProfile.huaweiUid,
      isLoggedIn: this.userProfile.isLoggedIn,
      lastSyncTime: this.userProfile.lastSyncTime
    }
    return {
      goalsJson: goalsJson,
      todosJson: todosJson,
      settingsJson: JSON.stringify(this.buildSettingsSnapshot()),
      profileJson: JSON.stringify(profileSnapshot),
      lastSyncTime: this.userProfile.lastSyncTime,
      forceUpload: forceUpload
    }
  }

  private buildLocalSyncApplyCallback(): SyncApplyCallback {
    return {
      applyGoals: (data: Record<string, Object>): void => {
        if (this.goalsApplyCallback !== null) {
          this.goalsApplyCallback(data)
        }
      },
      applyTodos: (data: Record<string, Object>): void => {
        if (this.todosApplyCallback !== null) {
          this.todosApplyCallback(data)
        }
      },
      applySettings: (data: Record<string, Object>): void => {
        this.applyCloudSettingsSnapshot(data)
      },
      applyProfile: (data: Record<string, Object>): void => {
        this.applyCloudProfileData(data)
      },
      updateLastSyncTime: (time: number): void => {
        this.userProfile.lastSyncTime = time
        // 同步回调写回不得触发云同步，仅本地持久化
        this.persistHelper.flush().catch((e: Error): void => {
          Logger.warn(this.tag, 'updateLastSyncTime flush failed: ' + e.message)
        })
      }
    }
  }

  // 云端 profile 数据统一应用入口（三层防御）
  private applyCloudProfileData(data: Record<string, Object>): void {
    // 防御 1：刚登录成功（5 秒窗口内），拒绝任何云端数据覆盖
    if (this.isJustLoggedIn) {
      Logger.warn(this.tag, 'applyProfile skipped: just logged in, ignore cloud data.')
      return
    }

    // 防御 2：UID 一致性校验
    const cloudUid: string = typeof data['huaweiUid'] === 'string' ?
      data['huaweiUid'] as string : ''
    if (this.userProfile.isLoggedIn && this.userProfile.huaweiUid.length > 0) {
      if (cloudUid.length === 0 || cloudUid !== this.userProfile.huaweiUid) {
        Logger.warn(this.tag, 'applyProfile skipped: cloud data is stale or empty, ' +
          'cloudUid=' + this.maskPii(cloudUid) + ', localUid=' + this.maskPii(this.userProfile.huaweiUid))
        return
      }
    }

    // 防御 3：字段级空值防御，云端字段为空时保留本地值
    const cloudNickname: string = typeof data['nickname'] === 'string' ?
      data['nickname'] as string : ''
    const cloudAvatarUri: string = typeof data['avatarUri'] === 'string' ?
      data['avatarUri'] as string : ''
    const loggedIn: Object | undefined = data['isLoggedIn']
    const syncTime: Object | undefined = data['lastSyncTime']
    this.userProfile = new UserProfile(
      typeof data['id'] === 'string' ? data['id'] as string : this.userProfile.id,
      cloudNickname.length > 0 ? cloudNickname : this.userProfile.nickname,
      typeof data['signature'] === 'string' ? data['signature'] as string : this.userProfile.signature,
      cloudAvatarUri.length > 0 ? cloudAvatarUri : this.userProfile.avatarUri,
      typeof data['email'] === 'string' ? data['email'] as string : this.userProfile.email,
      typeof data['aiCredits'] === 'string' ? data['aiCredits'] as string : this.userProfile.aiCredits,
      cloudUid.length > 0 ? cloudUid : this.userProfile.huaweiUid,
      typeof loggedIn === 'boolean' ? loggedIn as boolean : this.userProfile.isLoggedIn,
      typeof syncTime === 'number' ? syncTime as number : this.userProfile.lastSyncTime
    )
    this.syncLoginStateToAppStorage()
    // 同步回调写回不得再触发云同步，仅本地持久化
    this.isApplyingSyncData = true
    this.persistHelper.flush().catch((e: Error): void => {
      Logger.warn(this.tag, 'applyProfile flush failed: ' + e.message)
    })
  }

  // 手动同步场景构造数据包，forceUpload 由调用方决定
  buildSyncDataBundle(goalsJson: string, todosJson: string, forceUpload: boolean): SyncDataBundle {
    const profileSnapshot: UserProfileVMSnapshot = {
      id: this.userProfile.id,
      nickname: this.userProfile.nickname,
      signature: this.userProfile.signature,
      avatarUri: this.userProfile.avatarUri,
      email: this.userProfile.email,
      aiCredits: this.userProfile.aiCredits,
      huaweiUid: this.userProfile.huaweiUid,
      isLoggedIn: this.userProfile.isLoggedIn,
      lastSyncTime: this.userProfile.lastSyncTime
    }
    return {
      goalsJson: goalsJson,
      todosJson: todosJson,
      settingsJson: JSON.stringify(this.buildSettingsSnapshot()),
      profileJson: JSON.stringify(profileSnapshot),
      lastSyncTime: this.userProfile.lastSyncTime,
      forceUpload: forceUpload
    }
  }

  buildSyncApplyCallback(applyGoals: (data: Record<string, Object>) => void,
    applyTodos: (data: Record<string, Object>) => void): SyncApplyCallback {
    return {
      applyGoals: applyGoals,
      applyTodos: applyTodos,
      applySettings: (data: Record<string, Object>): void => {
        this.applyCloudSettingsSnapshot(data)
      },
      applyProfile: (data: Record<string, Object>): void => {
        this.applyCloudProfileData(data)
      },
      updateLastSyncTime: (time: number): void => {
        this.userProfile.lastSyncTime = time
        // 同步回调写回不得触发云同步，仅本地持久化
        this.persistHelper.flush().catch((e: Error): void => {
          Logger.warn(this.tag, 'updateLastSyncTime flush failed: ' + e.message)
        })
      }
    }
  }

  buildSettingsSnapshot(): SettingsVMSnapshot {
    return {
      notificationEnabled: this.settings.notificationEnabled,
      privacyAgreed: this.settings.privacyAgreed,
      vibrationEnabled: this.settings.vibrationEnabled,
      syncEnabled: this.settings.syncEnabled,
      version: SettingsViewModel.CURRENT_VERSION
    }
  }

  applyCloudSettingsSnapshot(cloudData: Record<string, Object>): void {
    const rehydrated: AppSettings = new AppSettings()
    rehydrated.notificationEnabled = this.settings.notificationEnabled
    rehydrated.privacyAgreed = this.settings.privacyAgreed
    rehydrated.vibrationEnabled = this.settings.vibrationEnabled
    rehydrated.syncEnabled = this.settings.syncEnabled
    // 仅在云端存在对应字段时覆盖
    if (typeof cloudData['notificationEnabled'] === 'boolean') {
      rehydrated.notificationEnabled = cloudData['notificationEnabled'] as boolean
    }
    if (typeof cloudData['privacyAgreed'] === 'boolean') {
      rehydrated.privacyAgreed = cloudData['privacyAgreed'] as boolean
    }
    if (typeof cloudData['vibrationEnabled'] === 'boolean') {
      rehydrated.vibrationEnabled = cloudData['vibrationEnabled'] as boolean
    }
    if (typeof cloudData['syncEnabled'] === 'boolean') {
      rehydrated.syncEnabled = cloudData['syncEnabled'] as boolean
    }
    this.settings = rehydrated
    // 同步回调写回不得再触发云同步，仅本地持久化
    this.isApplyingSyncData = true
    this.persistHelper.flush().catch((e: Error): void => {
      Logger.warn(this.tag, 'applyCloudSettingsSnapshot flush failed: ' + e.message)
    })
    Logger.info(this.tag, 'applyCloudSettingsSnapshot done')
  }

  // 业务方法：5 大设置 + 重置

  // 通知开关切换：乐观更新 → 系统 API → 失败回滚
  async toggleNotification(isOn: boolean): Promise<NotificationToggleResult> {
    const prev: boolean = this.settings.notificationEnabled

    // 乐观更新
    this.settings.notificationEnabled = isOn
    this.scheduleSave()

    try {
      // 调用 profileVM 系统 API（仅做系统桥，不持有状态）
      const result: NotificationToggleResult = await profileVM.toggleNotification(isOn)
      if (result.success) {
        // 成功：用系统返回的最终状态
        this.settings.notificationEnabled = result.finalState
        this.scheduleSave()
        Logger.info(this.tag,
          'toggleNotification success, finalState=' + result.finalState.toString())
      } else {
        // 失败：回滚
        this.settings.notificationEnabled = prev
        this.scheduleSave()
        this.toastMessage = this.context!.resourceManager.getStringByNameSync('settings_notification_failed_prefix') + result.errorMsg
        Logger.warn(this.tag, 'toggleNotification failed, msg=' + result.errorMsg)
      }
      return result
    } catch (e) {
      // 异常：回滚
      this.settings.notificationEnabled = prev
      this.scheduleSave()
      const err: Error = e as Error
      this.toastMessage = this.context!.resourceManager.getStringByNameSync('settings_notification_error_prefix') + err.message
      Logger.error(this.tag, 'toggleNotification threw, msg=' + err.message)
      throw new Error((e as Error).message)
    }
  }


  // 设置隐私协议
  setPrivacyAgreed(agreed: boolean): void {
    if (this.settings.privacyAgreed === agreed) return
    this.settings.privacyAgreed = agreed
    this.scheduleSave()
    Logger.info(this.tag, 'setPrivacyAgreed: ' + agreed.toString())
  }

  // 设置震动反馈
  setVibrationEnabled(enabled: boolean): void {
    if (this.settings.vibrationEnabled === enabled) return
    this.settings.vibrationEnabled = enabled
    this.scheduleSave()
    Logger.info(this.tag, 'setVibrationEnabled: ' + enabled.toString())
  }

  // 云端同步开关切换：更新状态 → 同步代理 → 防抖持久化
  toggleSyncEnabled(enabled: boolean): void {
    if (this.settings.syncEnabled === enabled) return
    this.settings.syncEnabled = enabled
    CloudDBSyncProxy.getInstance().setSyncEnabled(enabled)
    this.scheduleSave()
    Logger.info(this.tag, 'toggleSyncEnabled: ' + (enabled ? '开启' : '关闭'))
  }

  // PII 信息日志脱敏：委托 Logger.mask 统一实现（空值差异由空串判断补齐）
  private maskPii(value: string): string {
    if (value.length === 0) return '***'
    return Logger.mask(value)
  }

  // 重置所有设置为默认值
  async reset(): Promise<void> {
    this.isProcessing = true
    try {
      const defaults: SettingsVMSnapshot = this.buildEmptySnapshot()
      this.applySnapshot(defaults)
      await this.persistHelper.flush()
      Logger.warn(this.tag, 'reset success')
    } catch (e) {
      Logger.error(this.tag, 'reset failed, msg=' + (e as Error).message)
    } finally {
      this.isProcessing = false
    }
  }

  // 计算属性

  // 设置摘要，UI 显示当前配置状态
  @Computed
  get summary(): string {
    if (!this.context) {
      return ''
    }
    const parts: string[] = []
    const notifLabel: string = this.context.resourceManager.getStringSync($r('app.string.settings_notification').id)
    const notifOn: string = this.context.resourceManager.getStringSync($r('app.string.settings_notification_on').id)
    const notifOff: string = this.context.resourceManager.getStringSync($r('app.string.settings_notification_off').id)
    parts.push(notifLabel + '：' + (this.settings.notificationEnabled ? notifOn : notifOff))
    const privacyLabel: string = this.context.resourceManager.getStringSync($r('app.string.settings_privacy').id)
    const privacyAgreed: string = this.context.resourceManager.getStringSync($r('app.string.settings_privacy_agreed').id)
    const privacyNotAgreed: string = this.context.resourceManager.getStringSync($r('app.string.settings_privacy_not_agreed').id)
    parts.push(privacyLabel + '：' + (this.settings.privacyAgreed ? privacyAgreed : privacyNotAgreed))
    return parts.join(' | ')
  }

  // 触发云端上传同步（防抖 1s）
  // 解耦链路：HomeVM/RouteVM 数据变更 → emit SYNC_NEEDED → 此处监听 → triggerCloudSync
  triggerCloudSync(): void {
    // 防抖：同一对象短时间内只触发一次云同步
    if (this.syncDebounceTimer !== -1) {
      clearTimeout(this.syncDebounceTimer)
    }
    this.syncDebounceTimer = setTimeout((): void => {
      this.syncDebounceTimer = -1
      this.doTriggerCloudSync()
    }, 1000)
  }

  // 实际执行云端上传同步（防抖到期后调用）
  private doTriggerCloudSync(): void {
    // 未登录或无 UID 跳过
    if (!this.userProfile.isLoggedIn || this.userProfile.huaweiUid.length === 0) {
      Logger.info(this.tag, 'triggerCloudSync skipped: not logged in')
      return
    }
    // 云端同步关闭时跳过
    if (!CloudDBSyncProxy.getInstance().canSync()) {
      Logger.info(this.tag, 'triggerCloudSync skipped: sync disabled')
      return
    }
    // 标记强制上传，buildLocalSyncDataBundle 取出后自动重置
    this.forceUploadFlag = true
    const syncData: SyncDataBundle = this.buildLocalSyncDataBundle()
    const syncCallback: SyncApplyCallback = this.buildLocalSyncApplyCallback()
    CloudSyncService.getInstance().smartSync(this.userProfile.huaweiUid, syncData, syncCallback, 'upload')
      .then((r): void => {
        Logger.info(this.tag, 'triggerCloudSync done, direction=' + r.direction)
        if (r.direction === 'error') {
          this.toastMessage = this.context !== null
            ? this.context.resourceManager.getStringByNameSync('toast_sync_error')
            : r.errorMsg
        }
      }).catch((e: Error): void => {
        Logger.error(this.tag, 'triggerCloudSync failed: ' + e.message)
        this.toastMessage = this.context !== null
          ? this.context.resourceManager.getStringByNameSync('toast_sync_error')
          : e.message
      })
  }

  // 强制下载同步：以云端为准覆盖本地（慎用，多端协同请用 triggerSync）
  triggerDownloadSync(): void {
    if (!this.userProfile.isLoggedIn || this.userProfile.huaweiUid.length === 0) {
      Logger.info(this.tag, 'triggerDownloadSync skipped: not logged in')
      return
    }
    // 云端同步关闭时跳过下载
    if (!CloudDBSyncProxy.getInstance().canSync()) {
      Logger.info(this.tag, 'triggerDownloadSync skipped: sync disabled')
      return
    }
    const syncData: SyncDataBundle = this.buildLocalSyncDataBundle()
    const syncCallback: SyncApplyCallback = this.buildLocalSyncApplyCallback()
    CloudSyncService.getInstance().smartSync(this.userProfile.huaweiUid, syncData, syncCallback, 'download')
      .then((r): void => {
        Logger.info(this.tag, 'triggerDownloadSync done, direction=' + r.direction)
        if (r.direction === 'error') {
          this.toastMessage = this.context !== null
            ? this.context.resourceManager.getStringByNameSync('toast_sync_error')
            : r.errorMsg
        }
      }).catch((e: Error): void => {
        Logger.error(this.tag, 'triggerDownloadSync failed: ' + e.message)
        this.toastMessage = this.context !== null
          ? this.context.resourceManager.getStringByNameSync('toast_sync_error')
          : e.message
      })
  }

  // 并集合并同步（多端协同推荐）：按 id 合并，两端独有数据都保留
  triggerSync(): void {
    if (!this.userProfile.isLoggedIn || this.userProfile.huaweiUid.length === 0) {
      Logger.info(this.tag, 'triggerSync skipped: not logged in')
      return
    }
    // 云端同步关闭时跳过合并
    if (!CloudDBSyncProxy.getInstance().canSync()) {
      Logger.info(this.tag, 'triggerSync skipped: sync disabled')
      return
    }
    const syncData: SyncDataBundle = this.buildLocalSyncDataBundle()
    const syncCallback: SyncApplyCallback = this.buildLocalSyncApplyCallback()
    CloudSyncService.getInstance().smartSync(this.userProfile.huaweiUid, syncData, syncCallback, 'merge')
      .then((r): void => {
        Logger.info(this.tag, 'triggerSync done, direction=' + r.direction)
        if (r.direction === 'error') {
          this.toastMessage = this.context !== null
            ? this.context.resourceManager.getStringByNameSync('toast_sync_error')
            : r.errorMsg
        }
      }).catch((e: Error): void => {
        Logger.error(this.tag, 'triggerSync failed: ' + e.message)
        this.toastMessage = this.context !== null
          ? this.context.resourceManager.getStringByNameSync('toast_sync_error')
          : e.message
      })
  }

  registerSnapshotProviders(
    goalsProvider: () => string,
    todosProvider: () => string,
    goalsApply: (data: Record<string, Object>) => void,
    todosApply: (data: Record<string, Object>) => void
  ): void {
    this.goalsSnapshotProvider = goalsProvider
    this.todosSnapshotProvider = todosProvider
    this.goalsApplyCallback = goalsApply
    this.todosApplyCallback = todosApply
  }

  // 华为登录 / 登出

  // 5 秒保护窗口标志位：登录成功后置 true，阻断 applyCloudProfileData 用云端旧数据覆盖刚写入的新 UserProfile
  // 5 秒后 smartSync 应已完成，安全解除保护
  private isJustLoggedIn: boolean = false

  /**
   * 华为 ID 登录入口（由 LoginPage.doLogin 调用）
   * 调用 HuaweiAuthService.login(两步法) → 成功则 applyLoginResult 持久化 + 触发云同步
   * 失败/取消则清除本地缓存并暴露提示语
   */
  async handleHuaweiLogin(context: common.Context): Promise<boolean> {
    const authService: HuaweiAuthService = HuaweiAuthService.getInstance()
    const result = await authService.login(context)

    if (result.success && result.user) {
      // 登录成功：立即标记防止云同步覆盖，然后应用登录数据
      this.isJustLoggedIn = true

      await this.applyLoginResult(result.user)
      return true
    } else {
      // 登录失败/取消：清除本地半登录态缓存（HuaweiAuthService 内部已调用，此处兜底）
      authService.clearLocalCache(context)
      this.toastMessage = result.errorMsg.length > 0 ? result.errorMsg : (this.context ? this.context.resourceManager.getStringByNameSync('settings_login_failed') : '')
      return false
    }
  }

  /**
   * 应用登录结果（核心持久化方法）
   * 1. 构造新 UserProfile（id='huawei_'+openId, isLoggedIn=true）
   * 2. syncLoginStateToAppStorage → 同步到 AppStorage 供其他 VM 读取
   * 3. flush() → 持久化到 Preferences（冷启动恢复依赖）
   * 4. 5 秒后解除 isJustLoggedIn 保护
   * 5. smartSync('merge') → 并集合并云端数据
   * nickname 兜底：华为 ID 未返回昵称时用 openId 后 4 位生成默认昵称
   */
  async applyLoginResult(user: HuaweiUserInfo): Promise<void> {
    // nickname 兜底策略
    let finalNickname: string = user.nickname
    if (finalNickname.length === 0) {
      const openIdTail: string = user.openId.length >= 4 ?
        user.openId.substring(user.openId.length - 4) : user.openId
      finalNickname = (this.context ? this.context.resourceManager.getStringByNameSync('settings_default_nickname_prefix') : '') + openIdTail
    }
    // 构造新 UserProfile：id 全局唯一（huawei_ + openId），isLoggedIn=true
    // 保留旧的 signature/aiCredits/lastSyncTime（登录不应丢失本地设置）
    this.userProfile = new UserProfile(
      'huawei_' + user.openId,
      finalNickname,
      this.userProfile.signature,
      user.avatarUri,
      user.email.length > 0 ? user.email : this.userProfile.email,
      this.userProfile.aiCredits,
      user.openId,
      true,
      this.userProfile.lastSyncTime
    )
    // 同步到 AppStorage：其他 VM 通过 AppStorage.get('isLoggedIn') 读取，不 import SettingsVM
    this.syncLoginStateToAppStorage()

    // 持久化到 Preferences：冷启动时 settingsVM.init 从此恢复登录态
    await this.flush()

    // 5 秒保护窗口：期间 applyCloudProfileData 被 isJustLoggedIn 拦截
    // 防止 smartSync 回调用云端旧 userProfile 覆盖刚写入的新数据（昵称/头像）
    setTimeout((): void => {
      this.isJustLoggedIn = false
      Logger.info(this.tag, 'isJustLoggedIn reset to false after ' +
        CommonConstants.LOGIN_GUARD_WINDOW_MS.toString() + 'ms')
    }, CommonConstants.LOGIN_GUARD_WINDOW_MS)

    Logger.info(this.tag, 'applyLoginResult success, openId=' + this.maskPii(user.openId))

    // 云端同步关闭时跳过登录后自动下载
    if (!CloudDBSyncProxy.getInstance().canSync()) {
      Logger.info(this.tag, 'applyLoginResult: sync disabled, skip download')
      return
    }

    // 直接执行并集合并同步，保护本地独有数据不被云端旧数据覆盖
    const syncService: CloudSyncService = CloudSyncService.getInstance()
    const syncData: SyncDataBundle = this.buildLocalSyncDataBundle()
    const syncCallback: SyncApplyCallback = this.buildLocalSyncApplyCallback()

    syncService.smartSync(user.openId, syncData, syncCallback, 'merge').then((syncResult): void => {
      Logger.info(this.tag, 'smartSync done, direction=' + syncResult.direction)
      if (syncResult.direction === 'error') {
        this.toastMessage = this.context !== null
          ? this.context.resourceManager.getStringByNameSync('toast_sync_error')
          : syncResult.errorMsg
      }
    }).catch((e: Error): void => {
      Logger.error(this.tag, 'smartSync failed: ' + e.message)
      this.toastMessage = this.context !== null
        ? this.context.resourceManager.getStringByNameSync('toast_sync_error')
        : e.message
    })
  }

  /**
   * 退出登录
   * 1. 先上传本地数据到云端（logoutUploadFailed 则中止退出，由 ProfilePage 提示用户）
   * 2. cancelAuthorization 撤销华为 ID 授权
   * 3. 重置 userProfile + settings 为空实例
   * 4. emit CLEAR_ALL_REQUESTED → HomeVM/RouteVM 清空数据
   * 5. flush() 持久化空状态 + syncLoginStateToAppStorage
   * 为什么先上传：退出会清空本地数据，不先上传则用户数据永久丢失
   */
  async logout(context: common.Context): Promise<boolean> {
    this.logoutUploadFailed = false
    const oldUid: string = this.userProfile.huaweiUid

    if (oldUid.length > 0) {
      // 云端同步关闭时跳过登出前预上传，但仍继续登出流程
      if (!CloudDBSyncProxy.getInstance().canSync()) {
        Logger.info(this.tag, 'logout: sync disabled, skip pre-logout upload')
      } else {
        // ★ 先上传本地数据到云端：退出后本地数据会被清空，不先上传则用户数据永久丢失
        try {
          const syncData: SyncDataBundle = this.buildLocalSyncDataBundle()
          await CloudSyncService.getInstance().upload(oldUid, syncData)
        } catch (e) {
          // 上传失败则中止退出：返回 false 让 ProfilePage 提示用户，避免数据丢失
          Logger.warn(this.tag, 'pre-logout upload failed: ' + (e as Error).message)
          this.logoutUploadFailed = true
          return false
        }
      }
    }

    // 撤销华为 ID 授权：下次登录需重新授权
    try {
      const authService: HuaweiAuthService = HuaweiAuthService.getInstance()
      await authService.cancelAuthorization(context)
    } catch (e) {
      Logger.warn(this.tag, 'cancelAuthorization failed: ' + (e as Error).message)
    }

    // 重置为空实例：isLoggedIn=false, huaweiUid=''，保留默认值
    this.userProfile = new UserProfile()
    this.settings = new AppSettings()
    // 事件总线通知 HomeVM/RouteVM 清空 taskList/goals（解耦：不直接 import 其他 VM）
    eventBus.emit(EventType.CLEAR_ALL_REQUESTED, null)
    await this.flush()
    // 通知 HomeVM/RouteVM 立即刷盘（防抖定时器可能未到期，强制落盘）
    eventBus.emit(EventType.FLUSH_REQUESTED, null)
    // 同步到 AppStorage：isLoggedIn=false，其他 VM 读取后跳过云同步
    this.syncLoginStateToAppStorage()
    Logger.info(this.tag, 'logout success')

    return true
  }

  async forceLogout(context: common.Context): Promise<boolean> {
    try {
      const authService: HuaweiAuthService = HuaweiAuthService.getInstance()
      await authService.cancelAuthorization(context)
    } catch (e) {
      Logger.warn(this.tag, 'forceLogout cancelAuthorization failed: ' + (e as Error).message)
    }

    this.userProfile = new UserProfile()
    this.settings = new AppSettings()
    this.logoutUploadFailed = false
    // 通过事件总线通知 HomeVM/RouteVM 清空数据
    eventBus.emit(EventType.CLEAR_ALL_REQUESTED, null)
    await this.flush()
    // 通知 HomeVM/RouteVM 刷盘
    eventBus.emit(EventType.FLUSH_REQUESTED, null)
    this.syncLoginStateToAppStorage()
    Logger.info(this.tag, 'forceLogout success')

    return true
  }

  /**
   * 同步登录态到 AppStorage（全局内存级存储）
   * 每次 userProfile 变更后调用（登录/登出/init 加载）
   * 其他 VM 通过 AppStorage.get('isLoggedIn') 读取，不需要 import SettingsVM，解耦循环依赖
   */
  private syncLoginStateToAppStorage(): void {
    AppStorage.setOrCreate<boolean>('isLoggedIn', this.userProfile.isLoggedIn)
    AppStorage.setOrCreate<string>('huaweiUid', this.userProfile.huaweiUid)
  }
}

// 全局单例，ProfilePage 引用此普通属性
export const settingsVM: SettingsViewModel = new SettingsViewModel()
