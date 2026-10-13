// 设置页 ViewModel：通知/隐私/震动/云同步 5 大设置 + 华为登录态 + 本地与云端持久化

import { AppSettings, UserProfile } from '../model/Models'
import { Logger } from '../common/utils/Logger'
import { StorageManager } from '../common/utils/StorageManager'
import { CommonConstants } from '../common/constants/CommonConstants'
import { profileVM, NotificationToggleResult } from './ProfileViewModel'
import { HuaweiAuthService, HuaweiUserInfo } from '../common/services/HuaweiAuthService'
import { CloudSyncService, SyncDataBundle, SyncApplyCallback, SyncResult } from '../common/services/CloudSyncService'
import { CloudDBSyncProxy } from '../common/services/CloudDBSyncProxy'
import { CloudDBService } from '../common/services/CloudDBService'
import { AgcAuthService } from '../common/services/AgcAuthService'
import { notificationCenterService } from '../common/services/NotificationCenterService'
import { deadlineReminderService } from '../common/services/DeadlineReminderService'
import { pomodoroService } from '../common/services/PomodoroService'
import { hapticFeedback } from '../common/services/HapticFeedback'

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
  reminderAdvanceTaskDays: number
  reminderAdvanceGoalDays: number
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
  /** 上次同步成功时刻（本机展示；与水位 lastSyncTime 语义不同，见 ProfileModels.UserProfile） */
  lastSyncedAt: number
}

/**
 * 云同步脏标记持久化快照（`CommonConstants.STORAGE_KEY_SYNC_DIRTY`）
 * - `dirty === true`：本地存在尚未成功上传到云端的改动，需在下次同步时重试
 * - 独立于 UserProfile 存储：**水位与脏标记都不参与同步载荷**
 */
interface SyncDirtySnapshot {
  dirty: boolean
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
  // Ability onDestroy 防护标志：销毁后阻断一切云同步触发
  private isDestroyed: boolean = false

  /**
   * 持久化脏标记（SYNC_NEEDED）
   * - 语义：本地存在尚未成功上传到云端的改动
   * - **持久化在本地存储**（`CommonConstants.STORAGE_KEY_SYNC_DIRTY`），
   *   App 进程被杀 / 重启后仍保留，用于失败重试
   * - 上传成功 / 无需上传（与云端一致）→ 清除
   * - 上传失败 / 拉取失败 / 解析失败 / 未就绪 → 保留
   * - ⚠️ 清空类操作（登出 / 一键删除所有数据）必须显式清除，
   *   否则下次冷启动会拿空数据上传覆盖云端
   */
  private syncDirty: boolean = false

  /**
   * 就绪 gate 未通过时的待补触发标志
   * - gate 未通过 → 不打网络请求、保留脏标记，并置本标志
   * - SDK / VM / 快照就绪后调用 `notifyCloudReady()` → 自动补跑一次 syncNow
   *   （否则冷启动若用户不操作数据，脏标记会一直滞留到下次触发）
   */
  private pendingReadySync: boolean = false

  /** 就绪补跑的重试定时器与计数（竞态自愈用，见 notifyCloudReady） */
  private readyRetryTimer: number = -1
  private readyRetryCount: number = 0

  /** 快照提供者是否已注册（就绪 gate 的"本地就绪"部分） */
  private snapshotsReady: boolean = false

  /** 云同步回环阻断：同步回调写回本地时置 true，onScheduleFire 检测后跳过云同步 */
  private isApplyingSyncData: boolean = false

  /** 一键删除所有数据后的自动云同步抑制截止时间戳（Date.now() 毫秒） */
  private suppressAutoSyncUntil: number = 0

  // syncNow 防抖定时器，避免静止状态周期 Upsert
  private syncDebounceTimer: number = -1

  /** 前台云端复查定时器（-1 = 未运行）。仅在**前台**运行：进前台启动、退后台立即停 */
  private foregroundProbeTimer: number = -1
  /** 当前复查间隔（指数退避：无变化逐次翻倍到上限，有变化立刻回到最短） */
  private probeIntervalMs: number = CommonConstants.SYNC_PROBE_INTERVAL_MIN_MS

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
      // 本机设置变更（通知/震动/提前量/同步开关等）= 本地有改动
      // → 打持久化脏标记 + 防抖触发 merge（settings 也是同步载荷的一部分）
      this.markSyncNeeded('settings changed')
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

    // 载入持久化脏标记（必须在任何同步判定之前）：App 被杀前未上传成功的改动标志
    await this.loadSyncDirty()

    // 注册事件总线订阅（幂等：重复 init 时先 off 再 on）
    if (this.syncNeededCbId > 0) {
      eventBus.off(EventType.SYNC_NEEDED, this.syncNeededCbId)
    }
    this.syncNeededCbId = eventBus.on(EventType.SYNC_NEEDED, (payload: Object): void => {
      this.markSyncNeeded('data changed')
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
          profileSnapshot.lastSyncTime,
          profileSnapshot.lastSyncedAt
        )
        this.syncLoginStateToAppStorage()
        Logger.info(this.tag, 'userProfile loaded, isLoggedIn=' +
          this.userProfile.isLoggedIn.toString())
      }
    } catch (e) {
      Logger.error(this.tag, 'load userProfile failed, msg=' + (e as Error).message)
    }

    try {
      // 隐私前置检查：未同意隐私协议时禁止任何云端交互（云端 SDK 也尚未初始化）
      if (!this.settings.privacyAgreed) {
        Logger.info(this.tag, 'init: privacy not agreed, skip auto download. ' +
          'Local data loaded: settings.notification=' + this.settings.notificationEnabled.toString() +
          ', settings.syncEnabled=' + this.settings.syncEnabled.toString() +
          ', userProfile.isLoggedIn=' + this.userProfile.isLoggedIn.toString())
        return
      }
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
        // 冷启动统一走 merge；此时 CloudDB 尚未初始化 / 快照尚未注册，
        // gate 会判定未就绪并保留脏标记，等 `notifyCloudReady()` 补触发
        this.syncNowDetached('cold-start')
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
          profileSnapshot.lastSyncTime,
          profileSnapshot.lastSyncedAt
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
    rehydrated.reminderAdvanceTaskDays = AppSettings.sanitizeAdvanceDays(snapshot.reminderAdvanceTaskDays, 1)
    rehydrated.reminderAdvanceGoalDays = AppSettings.sanitizeAdvanceDays(snapshot.reminderAdvanceGoalDays, 3)
    // 整体替换 settings，@Trace 触发 UI 刷新
    this.settings = rehydrated
    // 提前量同步到提醒服务（加载失败走默认值的路径也会经过这里）
    deadlineReminderService.setAdvanceDays(
      rehydrated.reminderAdvanceTaskDays, rehydrated.reminderAdvanceGoalDays)
    // 通知/震动开关同步到番茄钟服务（完成通知与震动受设置控制）
    pomodoroService.setFeedbackEnabled(
      rehydrated.notificationEnabled, rehydrated.vibrationEnabled)
    // 震动开关同步到触觉反馈服务（完成场景三档震动共用同一开关）
    hapticFeedback.setEnabled(rehydrated.vibrationEnabled)
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
      reminderAdvanceTaskDays: 1,
      reminderAdvanceGoalDays: 3,
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

  /**
   * Ability onDestroy 防护（EntryAbility.onDestroy 调用）：
   * 置销毁标志 + 清同步防抖定时器 + 退订事件总线，
   * 阻断销毁后 SYNC_NEEDED 事件/到期的防抖回调再次触发云同步
   */
  destroy(): void {
    this.isDestroyed = true
    if (this.syncDebounceTimer !== -1) {
      clearTimeout(this.syncDebounceTimer)
      this.syncDebounceTimer = -1
    }
    if (this.syncNeededCbId > 0) {
      eventBus.off(EventType.SYNC_NEEDED, this.syncNeededCbId)
      this.syncNeededCbId = -1
    }
    Logger.info(this.tag, 'destroy: debounce timer cleared, event bus unsubscribed')
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
        reminderAdvanceTaskDays: this.settings.reminderAdvanceTaskDays,
        reminderAdvanceGoalDays: this.settings.reminderAdvanceGoalDays,
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
        lastSyncTime: this.userProfile.lastSyncTime,
        lastSyncedAt: this.userProfile.lastSyncedAt
      }
      await StorageManager.saveData(ctx, CommonConstants.STORAGE_KEY_USER_PROFILE,
        profileSnapshot as object)
    } catch (e) {
      Logger.error(this.tag, 'persistNow userProfile failed, msg=' + (e as Error).message)
    }
  }

  /**
   * 构造本地数据包（同步载荷）
   *
   * ⚠️ `lastSyncTime` 是本机专属水位游标：**绝不进入任何一段 JSON 载荷**。
   *    profileJson 里显式剔除该字段（历史实现会随 profile 一起上传，
   *    导致水位被其它设备覆盖 → 等值判据错乱）。
   */
  private buildLocalSyncDataBundle(): SyncDataBundle {
    // 快照提供者为 null 说明对应模块未注入，传空字符串交由就绪 gate 拦截
    const goalsJson: string = this.goalsSnapshotProvider !== null ? this.goalsSnapshotProvider() : ''
    const todosJson: string = this.todosSnapshotProvider !== null ? this.todosSnapshotProvider() : ''
    const profilePayload: Record<string, Object> = {
      'id': this.userProfile.id,
      'nickname': this.userProfile.nickname,
      'signature': this.userProfile.signature,
      'avatarUri': this.userProfile.avatarUri,
      'email': this.userProfile.email,
      'aiCredits': this.userProfile.aiCredits,
      'huaweiUid': this.userProfile.huaweiUid,
      'isLoggedIn': this.userProfile.isLoggedIn
    }
    Logger.info(this.tag, 'buildLocalSyncDataBundle: goalsEmpty=' + (goalsJson.length === 0).toString() +
      ' todosEmpty=' + (todosJson.length === 0).toString())
    return {
      goalsJson: goalsJson,
      todosJson: todosJson,
      settingsJson: JSON.stringify(this.buildSettingsSnapshot()),
      profileJson: JSON.stringify(profilePayload),
      lastSyncTime: this.userProfile.lastSyncTime,
      dirty: this.syncDirty
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
    // ⚠️ 水位（lastSyncTime）是**本机专属游标**：载荷里即使带了这个字段也一律忽略，
    //    永远保留本机当前值（否则会被其它设备的水位覆盖 → 等值判据错乱）
    const keepLocalWatermark: number = this.userProfile.lastSyncTime
    // 同为**本机专属**：合并写回时也一律保留本机值（否则会被云端载荷里的 0 冲掉）
    const keepLocalSyncedAt: number = this.userProfile.lastSyncedAt
    this.userProfile = new UserProfile(
      typeof data['id'] === 'string' ? data['id'] as string : this.userProfile.id,
      cloudNickname.length > 0 ? cloudNickname : this.userProfile.nickname,
      typeof data['signature'] === 'string' ? data['signature'] as string : this.userProfile.signature,
      cloudAvatarUri.length > 0 ? cloudAvatarUri : this.userProfile.avatarUri,
      typeof data['email'] === 'string' ? data['email'] as string : this.userProfile.email,
      typeof data['aiCredits'] === 'string' ? data['aiCredits'] as string : this.userProfile.aiCredits,
      cloudUid.length > 0 ? cloudUid : this.userProfile.huaweiUid,
      typeof loggedIn === 'boolean' ? loggedIn as boolean : this.userProfile.isLoggedIn,
      keepLocalWatermark,
      keepLocalSyncedAt
    )
    this.syncLoginStateToAppStorage()
    // 同步回调写回不得再触发云同步，仅本地持久化
    this.isApplyingSyncData = true
    this.persistHelper.flush().catch((e: Error): void => {
      Logger.warn(this.tag, 'applyProfile flush failed: ' + e.message)
    })
  }

  /**
   * 设置快照（同步载荷的 settingsJson 来源）
   *
   * settings 合并口径：**本地优先**（保护本机偏好；尤其 syncEnabled 若被云端覆盖，
   * 会出现"另一台设备关了同步 → 本机同步被关掉"的意外行为）。
   */
  buildSettingsSnapshot(): SettingsVMSnapshot {
    return {
      notificationEnabled: this.settings.notificationEnabled,
      privacyAgreed: this.settings.privacyAgreed,
      vibrationEnabled: this.settings.vibrationEnabled,
      syncEnabled: this.settings.syncEnabled,
      reminderAdvanceTaskDays: this.settings.reminderAdvanceTaskDays,
      reminderAdvanceGoalDays: this.settings.reminderAdvanceGoalDays,
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
    if (typeof cloudData['reminderAdvanceTaskDays'] === 'number') {
      rehydrated.reminderAdvanceTaskDays =
        AppSettings.sanitizeAdvanceDays(cloudData['reminderAdvanceTaskDays'] as number, 1)
    }
    if (typeof cloudData['reminderAdvanceGoalDays'] === 'number') {
      rehydrated.reminderAdvanceGoalDays =
        AppSettings.sanitizeAdvanceDays(cloudData['reminderAdvanceGoalDays'] as number, 3)
    }
    this.settings = rehydrated
    // 云端写回同样要同步提前量到提醒服务（阻断回环前的本地状态更新）
    deadlineReminderService.setAdvanceDays(
      rehydrated.reminderAdvanceTaskDays, rehydrated.reminderAdvanceGoalDays)
    pomodoroService.setFeedbackEnabled(
      rehydrated.notificationEnabled, rehydrated.vibrationEnabled)
    hapticFeedback.setEnabled(rehydrated.vibrationEnabled)
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
        // 同步到番茄钟服务：完成通知立即受开关控制
        pomodoroService.setFeedbackEnabled(result.finalState, this.settings.vibrationEnabled)
        hapticFeedback.setEnabled(this.settings.vibrationEnabled)
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
    pomodoroService.setFeedbackEnabled(this.settings.notificationEnabled, enabled)
    hapticFeedback.setEnabled(enabled)
    this.scheduleSave()
    Logger.info(this.tag, 'setVibrationEnabled: ' + enabled.toString())
  }

  // 设置截止提醒提前量：L4 任务（0=截止当天/1/3/7 天），立即同步提醒服务
  setReminderAdvanceTaskDays(days: number): void {
    const safeDays: number = AppSettings.sanitizeAdvanceDays(days, 1)
    if (this.settings.reminderAdvanceTaskDays === safeDays) return
    this.settings.reminderAdvanceTaskDays = safeDays
    deadlineReminderService.setAdvanceDays(safeDays, this.settings.reminderAdvanceGoalDays)
    this.scheduleSave()
    Logger.info(this.tag, 'setReminderAdvanceTaskDays: ' + safeDays.toString() + 'd')
  }

  // 设置截止提醒提前量：L1 目标（0=截止当天/1/3/7 天），立即同步提醒服务
  setReminderAdvanceGoalDays(days: number): void {
    const safeDays: number = AppSettings.sanitizeAdvanceDays(days, 3)
    if (this.settings.reminderAdvanceGoalDays === safeDays) return
    this.settings.reminderAdvanceGoalDays = safeDays
    deadlineReminderService.setAdvanceDays(this.settings.reminderAdvanceTaskDays, safeDays)
    this.scheduleSave()
    Logger.info(this.tag, 'setReminderAdvanceGoalDays: ' + safeDays.toString() + 'd')
  }

  /**
   * 云端同步开关切换：更新状态 → 同步代理 → 防抖持久化
   * **开启瞬间立即执行一次 merge**（§4.5）：让用户"打开开关就能看到云端数据"，
   * 否则会以为同步没生效
   */
  toggleSyncEnabled(enabled: boolean): void {
    if (this.settings.syncEnabled === enabled) return
    this.settings.syncEnabled = enabled
    CloudDBSyncProxy.getInstance().setSyncEnabled(enabled)
    this.scheduleSave()
    Logger.info(this.tag, 'toggleSyncEnabled: ' + (enabled ? '开启' : '关闭'))
    if (enabled) {
      // 开启即拉取：本地已登录时立刻 merge 一次（未登录则由 switch 引导登录）
      this.syncNowDetached('sync-enabled')
    }
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

  /* ============================================================
   * 云同步：统一入口 + 持久化脏标记 + 就绪 gate
   * ============================================================ */

  /**
   * 打持久化脏标记（SYNC_NEEDED），可选地防抖触发一次 merge
   *
   * 调用来源：
   *   - HomeVM / RouteVM / SettingsVM 的持久化成功回调（本地数据变更）
   *   - SettingsVM 监听 SYNC_NEEDED 事件
   *   - App 退后台（`trigger = false`：只落标记**不允许发起网络请求**）
   *
   * @param reason - 日志用途的原因
   * @param trigger - 是否顺带触发同步；退后台时必须传 false（禁止后台网络 merge）
   */
  markSyncNeeded(reason: string, trigger: boolean = true): void {
    if (this.isApplyingSyncData) {
      Logger.info(this.tag, 'markSyncNeeded skipped: applying sync data write-back, break loop')
      return
    }
    // 清空类操作（登出 / 一键删除所有数据）窗口内禁止打标记：
    // 这些流程会先清空本地数据，若此时打上脏标记，下次冷启动会尝试上传"空数据"
    if (Date.now() < this.suppressAutoSyncUntil) {
      Logger.info(this.tag, 'markSyncNeeded skipped: suppressed (clear-data window)')
      return
    }
    if (!this.syncDirty) {
      this.syncDirty = true
      this.persistSyncDirty(true)
      Logger.info(this.tag, 'dirty flag SET (' + reason + ')')
    }
    if (trigger) {
      this.triggerSync()
    }
  }

  /** 清除持久化脏标记（同步已达成一致 / 清空类操作） */
  private clearSyncNeeded(reason: string): void {
    if (!this.syncDirty) return
    this.syncDirty = false
    this.persistSyncDirty(false)
    Logger.info(this.tag, 'dirty flag CLEARED (' + reason + ')')
  }

  /** 脏标记读取（冷启动，必须在任何同步判定之前完成） */
  private async loadSyncDirty(): Promise<void> {
    if (this.context === null) return
    try {
      const snapshot: SyncDirtySnapshot | null = await StorageManager.loadData<SyncDirtySnapshot | null>(
        this.context, CommonConstants.STORAGE_KEY_SYNC_DIRTY, null)
      this.syncDirty = snapshot !== null && snapshot.dirty === true
      Logger.info(this.tag, 'loadSyncDirty: dirty=' + this.syncDirty.toString())
    } catch (e) {
      Logger.warn(this.tag, 'loadSyncDirty failed: ' + (e as Error).message)
      this.syncDirty = false
    }
  }

  /** 脏标记写入（立即写，不走防抖：进程随时可能被杀） */
  private persistSyncDirty(dirty: boolean): void {
    if (this.context === null) return
    const ctx: Context = this.context
    const snapshot: SyncDirtySnapshot = { dirty: dirty }
    StorageManager.saveData(ctx, CommonConstants.STORAGE_KEY_SYNC_DIRTY, snapshot as object)
      .catch((e: Error): void => {
        Logger.error(this.tag, 'persistSyncDirty failed: ' + e.message)
      })
  }

  /**
   * 就绪 gate 判定（merge 的前置条件，任一不满足则不发起任何网络请求、保留脏标记）
   *   1. 未同意隐私协议 / 未登录 / 无 UID / 同步开关关闭 → 不允许
   *   2. 本地快照提供者未注册（VM 数据未加载完）→ 未就绪
   *      ⚠️ 此时若合并，会把"空本地"当成真实数据参与并集 → 云端整包覆盖本地独有数据
   *   3. CloudDB 未初始化 → 未就绪
   */
  isReadyToSync(): boolean {
    if (!this.settings.privacyAgreed) return false
    if (!this.userProfile.isLoggedIn || this.userProfile.huaweiUid.length === 0) return false
    if (!CloudDBSyncProxy.getInstance().canSync()) return false
    if (!this.snapshotsReady) return false
    if (!CloudDBService.getInstance().isInitialized()) return false
    return true
  }

  /**
   * 就绪通知：CloudSDK 初始化完成 / 快照提供者注册完成后调用
   * 若此前有因 gate 未通过而滞留的同步请求 → 立刻补跑一次
   */
  notifyCloudReady(): void {
    if (!this.pendingReadySync) return
    if (!this.isReadyToSync()) {
      // ⚠️ 竞态自愈（2026-10-13 真机修复）：就绪 gate 需同时满足「CloudDB 已初始化」与
      //    「快照提供者已注册」，而这两者是**两个独立事件**分别回调本方法 —— 谁先到，
      //    另一个就还没就绪，于是本方法在两边都直接 return，`pendingReadySync` **永久滞留**，
      //    自动同步再也不会发生。用户表现：「同一账号登录后数据不自动下来，必须手动点『立即同步』」
      //    （手动点时两者都已就绪，所以一定成功）。此处改为退避重试，直到就绪或超上限。
      this.scheduleReadyRetry()
      return
    }
    this.readyRetryCount = 0
    this.pendingReadySync = false
    Logger.info(this.tag, 'notifyCloudReady: cloud & local ready, retry pending sync')
    this.syncNowDetached('ready-retry')
  }

  /**
   * 就绪退避重试：每 500ms 复查一次，最多 20 次（≈10s），避免无限轮询。
   * 期间任一就绪事件（notifyCloudReady）到达时会立刻走正常补跑路径。
   */
  private scheduleReadyRetry(): void {
    if (this.readyRetryTimer !== -1) return
    if (this.readyRetryCount >= 20) return
    this.readyRetryCount++
    this.readyRetryTimer = setTimeout((): void => {
      this.readyRetryTimer = -1
      if (this.isDestroyed) return
      this.notifyCloudReady()
    }, 500)
  }

  /**
   * 进入前台：启动云端复查（**多端无感刷新的实现**）
   *
   * 为什么要它：本机在**前台停留**时，若另一台设备改了数据，本机没有任何机制会知道
   * （鸿蒙 `@kit.CloudFoundationKit` 的 cloudDatabase **未提供实时侦听 API**，全工程亦无轮询）
   * ⇒ 表现为"多端不同步，必须手动点立即同步/切后台再回来"。
   * 这里按**指数退避**复查：最短 3 分钟、最长 15 分钟；一旦发现云端变化立刻回到最短间隔。
   * 复查走统一入口 `syncNow('probe')` ⇒ 未就绪不发请求、无变化零写入、有变化正常 merge。
   */
  startForegroundProbe(): void {
    this.stopForegroundProbe()
    this.probeIntervalMs = CommonConstants.SYNC_PROBE_INTERVAL_MIN_MS
    this.scheduleProbe()
  }

  /** 退出前台：立即停止复查（后台不做任何轮询） */
  stopForegroundProbe(): void {
    if (this.foregroundProbeTimer !== -1) {
      clearTimeout(this.foregroundProbeTimer)
      this.foregroundProbeTimer = -1
    }
  }

  private scheduleProbe(): void {
    if (this.foregroundProbeTimer !== -1) return
    this.foregroundProbeTimer = setTimeout((): void => {
      this.foregroundProbeTimer = -1
      if (this.isDestroyed) return
      this.probeOnce()
      this.scheduleProbe()
    }, this.probeIntervalMs)
  }

  /** 复查一次：有变化 → 回到最短间隔；无变化 → 间隔翻倍（上限 SYNC_PROBE_INTERVAL_MAX_MS） */
  private probeOnce(): void {
    if (!this.isReadyToSync()) {
      // 未就绪（未登录 / SDK 未初始化 / 快照未注册）→ 不查，**且照样退避**
      // ⇒ 避免"未登录时每 3 分钟一次无谓心跳"。登录/回前台等事件本就会立即触发一次同步。
      this.probeIntervalMs = Math.min(this.probeIntervalMs * 2,
        CommonConstants.SYNC_PROBE_INTERVAL_MAX_MS)
      return
    }
    const beforeWatermark: number = this.userProfile.lastSyncTime
    this.syncNow('probe').then((r: SyncResult | null): void => {
      if (r === null) {
        return
      }
      if (r.outcome === 'ok' && (r.uploaded || r.lastSyncTime !== beforeWatermark)) {
        // 云端有变化（或本机有改动被上传）→ 立刻回到最短间隔，便于连续追平
        this.probeIntervalMs = CommonConstants.SYNC_PROBE_INTERVAL_MIN_MS
      } else {
        // 无变化 → 退避，避免白耗流量
        this.probeIntervalMs = Math.min(this.probeIntervalMs * 2,
          CommonConstants.SYNC_PROBE_INTERVAL_MAX_MS)
      }
    }).catch((e: Error): void => {
      Logger.warn(this.tag, 'probeOnce failed: ' + e.message)
    })
  }

  /**
   * 【唯一】同步入口（防抖 1s）
   *
   * 所有入口统一走这里：数据变更 / 立即同步 / 冷启动 / 登录完成 / 热启动 onNewWant /
   * 切前台 onForeground / 开启同步开关 / 登出预上传。
   * **禁止任何绕过本入口的裸 upload / download**。
   */
  triggerSync(): void {
    if (this.syncDebounceTimer !== -1) {
      clearTimeout(this.syncDebounceTimer)
    }
    this.syncDebounceTimer = setTimeout((): void => {
      this.syncDebounceTimer = -1
      this.syncNowDetached('debounced')
    }, 1000)
  }

  /**
   * 立即执行一次 merge（triggerSync 防抖到期后调用；需即时生效的入口可直接调用）
   *
   * @returns 同步结果；`null` 表示本次被跳过（已销毁 / 抑制窗口内 / 就绪 gate 未通过）
   */
  async syncNow(reason: string): Promise<SyncResult | null> {
    // Ability 已销毁：阻断云同步
    if (this.isDestroyed) {
      Logger.info(this.tag, 'syncNow skipped: vm destroyed')
      return null
    }
    // 一键删除数据后的抑制窗口：防止清空动作触发的同步把空数据上传
    if (Date.now() < this.suppressAutoSyncUntil) {
      Logger.info(this.tag, 'syncNow skipped: suppressed (deleteAllData window)')
      return null
    }
    // 就绪 gate：未就绪 → 不发网络请求 + **保留脏标记** + 登记就绪后补触发
    if (!this.isReadyToSync()) {
      Logger.info(this.tag, 'syncNow(' + reason + ') deferred: not ready (dirty flag kept)')
      this.pendingReadySync = true
      return null
    }
    const uid: string = this.userProfile.huaweiUid
    // 快照提供者：在**真正执行 merge 的那一刻**取最新本地数据（pending 补跑时也取最新）
    const dataProvider: () => SyncDataBundle = (): SyncDataBundle => this.buildLocalSyncDataBundle()
    const syncCallback: SyncApplyCallback = this.buildLocalSyncApplyCallback()
    try {
      const r: SyncResult = await CloudSyncService.getInstance().requestMerge(uid, dataProvider, syncCallback)
      this.handleSyncResult(r, reason)
      return r
    } catch (e) {
      const msg: string = (e as Error).message
      Logger.error(this.tag, 'syncNow(' + reason + ') failed: ' + msg)
      if (this.context !== null && this.shouldNotifySyncFailure(reason)) {
        this.toastMessage = this.context.resourceManager.getStringByNameSync('toast_sync_upload_pending')
      }
      return { outcome: 'upload_failed', uploaded: false, lastSyncTime: 0, errorMsg: msg }
    }
  }

  /**
   * 防抖调用点（不关心结果）
   */
  private syncNowDetached(reason: string): void {
    this.syncNow(reason).catch((e: Error): void => {
      Logger.error(this.tag, 'syncNowDetached(' + reason + ') failed: ' + e.message)
    })
  }

  /**
   * 同步结果收尾（**水位只在上传成功后推进**）
   * - `ok`
   *   - 上传过 → 水位 = 本次真正写入云端的 updatedAt；清脏标记
   *   - 无需上传 → 水位 = 云端当前 updatedAt（推进以收敛等值判据）；清脏标记
   * - `not_ready` → 静默延后：不打网络请求、保留脏标记，等就绪补触发
   * - `pull_failed` / `upload_failed` / `parse_failed`
   *   → **水位不变 + 保留脏标记**，明确告知用户"改动暂未上传，恢复后自动重试"
   */
  /**
   * 同步失败是否要提示用户。
   *
   * ⚠️ 自动复查（reason='probe'）必须**静默**：它每 3~15 分钟跑一次，弱网/未就绪时失败很常见，
   *    若照样置 `toastMessage`，用户一打开「我的」页就会莫名弹出"改动暂未上传"
   *    （`ProfilePage.checkVmToast` 会消费它）⇒ 属于"自己制造的骚扰"。
   *    手动同步（'manual'）失败由 `SettingPage.handleSync` 自己弹 toast ✔；
   *    其它自动路径（如数据变更后上传失败）**保留**提示 —— 那种情况用户的改动确实没上去，
   *    需要告知。
   */
  private shouldNotifySyncFailure(reason: string): boolean {
    return reason !== 'probe'
  }

  private handleSyncResult(r: SyncResult, reason: string): void {
    Logger.info(this.tag, 'syncNow(' + reason + ') done, outcome=' + r.outcome +
      ', uploaded=' + r.uploaded.toString() + ', lastSyncTime=' + r.lastSyncTime.toString())
    if (r.outcome === 'ok') {
      if (r.lastSyncTime > 0) {
        this.userProfile.lastSyncTime = r.lastSyncTime
      }
      // ★ 修复「同步成功但时间不刷新」：展示用的"上次同步时刻"必须每次成功都推进，
      //   不能再复用 lastSyncTime（水位：云端无新数据时不前进）
      this.userProfile.lastSyncedAt = Date.now()
      this.clearSyncNeeded('sync ok (' + reason + ')')
      this.persistHelper.flush().catch((e: Error): void => {
        Logger.warn(this.tag, 'post-sync flush failed: ' + e.message)
      })
      return
    }
    if (r.outcome === 'idle') {
      return
    }
    if (r.outcome === 'not_ready') {
      // 未就绪属正常中间态（冷启动早于 SDK/VM 就绪），不打扰用户
      this.pendingReadySync = true
      return
    }
    // 真实失败：本地改动未成功上传 → 明确告知用户（水位不变、脏标记保留）
    // 例外：自动复查（probe）失败静默，见 shouldNotifySyncFailure
    if (this.context !== null && this.shouldNotifySyncFailure(reason)) {
      this.toastMessage = this.context.resourceManager.getStringByNameSync('toast_sync_upload_pending')
    }
    Logger.warn(this.tag, 'sync incomplete (dirty flag kept). outcome=' + r.outcome +
      ', err=' + r.errorMsg)
  }

  /**
   * 注册快照提供者（由 MainTab 在所有 VM init 完成后调用）
   * ⚠️ 这是就绪 gate 的关键一环：注册前 `buildLocalSyncDataBundle` 只能拿到空串，
   *    此时合并会把"空本地"当成真实数据 → 必须等注册完成才允许发起 merge。
   */
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
    // 本地侧就绪：允许发起 merge；若此前有滞留请求（冷启动早于注册）→ 立即补跑
    this.snapshotsReady = true
    Logger.info(this.tag, 'registerSnapshotProviders done, snapshots ready')
    this.notifyCloudReady()
  }

  // 华为登录 / 登出

  // 5 秒保护窗口标志位：登录成功后置 true，阻断 applyCloudProfileData 用云端旧数据覆盖刚写入的新 UserProfile
  // 5 秒后 syncNow 应已完成，安全解除保护
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
      // 关键时序：必须在 applyLoginResult 之前建立 AGC 云端会话。
      // applyLoginResult 内部会立即发起 CloudDB 同步；若此时无 AGC 会话，
      // 请求会以匿名(World 角色)被服务端拒绝(2001015)。此时华为账号授权刚完成、authCode 最新鲜，补建会话成功率最高。
      const agcOk: boolean = await AgcAuthService.ensureSignedIn()
      if (!agcOk) {
        Logger.warn(this.tag, 'handleHuaweiLogin: AGC 会话建立失败，云端功能不可用')
      }

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
   * 5. syncNow('after-login') → 统一 merge（并集合并云端数据）
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
      this.userProfile.lastSyncTime,
      this.userProfile.lastSyncedAt
    )
    // 同步到 AppStorage：其他 VM 通过 AppStorage.get('isLoggedIn') 读取，不 import SettingsVM
    this.syncLoginStateToAppStorage()

    // ★ 登录即代表用户要使用云端能力：自动开启云同步。
    // 若沿用默认值 false，会出现"登录了却什么都用不了"：
    //   ① 下面的 canSync() 判定为 false → 登录后**完全不拉取云端数据**（即"没有第一时间拉数据"的根因）；
    //   ② AIPage 以 syncEnabled 作为云功能门控（handleSendMessage / 发送按钮 .enabled）→ AI 被拦截。
    // 这里直接改状态并同步代理层，由紧随其后的 flush() 一并持久化；刻意**不走 toggleSyncEnabled()**，
    // 是为了避开其 scheduleSave() 触发的防抖上传，防止与下面的 merge 同步并发写同一份记录。
    if (!this.settings.syncEnabled) {
      this.settings.syncEnabled = true
      CloudDBSyncProxy.getInstance().setSyncEnabled(true)
      Logger.info(this.tag, 'applyLoginResult: cloud sync auto-enabled on login (login implies cloud intent)')
    }

    // 持久化到 Preferences：冷启动时 settingsVM.init 从此恢复登录态
    await this.flush()

    // 5 秒保护窗口：期间 applyCloudProfileData 被 isJustLoggedIn 拦截
    // 防止合并落地时用云端旧 userProfile 覆盖刚写入的新数据（昵称/头像）
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

    // 登录完成：统一走 merge（并集合并，本地独有数据与云端独有数据都保留）
    // ⚠️ 登录刚完成时 CloudDB 可能尚未初始化 / 快照尚未注册 → gate 会自动延后并补触发
    this.syncNowDetached('after-login')
  }

  /**
   * 一键删除所有数据（设置页高危操作，UI 层二次确认后调用）
   *
   * 删除范围：云端同步记录 + 本地全部业务数据
   *   - 云端：该 uid 的 UserSyncData 记录（未登录/同步关闭时跳过，仅清本地）
   *   - 本地：目标/任务（CLEAR_ALL_REQUESTED，HomeVM 内置取消全部截止提醒）、
   *           AI 拆解任务、番茄钟统计与会话快照、站内通知、四象限排序
   * 保留范围：华为登录态、基础设置开关（通知/隐私/震动/同步）——删数据不应强制登出
   *
   * 关键时序：清空本地会经 HomeVM 持久化防抖触发 SYNC_NEEDED 自动上传空数据，
   * 必须先开启自动同步抑制窗口，否则空 bundle 会把刚删掉的云端记录"复活"。
   *
   * @returns true 表示全部成功（云端记录不存在也视为成功）
   */
  async deleteAllData(context: common.Context): Promise<boolean> {
    Logger.warn(this.tag, 'deleteAllData START')

    // 1. 先开启自动同步抑制窗口（后续清空本地会触发 SYNC_NEEDED）
    this.suppressAutoSyncUntil = Date.now() + CommonConstants.DELETE_ALL_SUPPRESS_SYNC_MS

    // 2. 删除云端同步记录
    let ok: boolean = true
    if (this.userProfile.huaweiUid.length > 0 && CloudDBSyncProxy.getInstance().canSync()) {
      try {
        const cloudOk: boolean =
          await CloudSyncService.getInstance().deleteCloudRecord(this.userProfile.huaweiUid)
        if (!cloudOk) {
          Logger.error(this.tag, 'deleteAllData: delete cloud record failed')
          ok = false
        }
      } catch (e) {
        Logger.error(this.tag, 'deleteAllData: delete cloud record threw: ' + (e as Error).message)
        ok = false
      }
    }

    // 3. 清空目标/任务（内存 + 持久化 + 取消全部截止提醒，HomeVM.clearAll 内置）
    eventBus.emit(EventType.CLEAR_ALL_REQUESTED, null)
    eventBus.emit(EventType.FLUSH_REQUESTED, null)

    // 4. 清空其余本地业务数据
    try {
      await StorageManager.removeData(context, CommonConstants.STORAGE_KEY_AI_TASKS)
      await StorageManager.removeData(context, CommonConstants.STORAGE_KEY_POMODORO_STATS)
      await StorageManager.removeData(context, CommonConstants.STORAGE_KEY_POMODORO_SESSION)
      await StorageManager.removeData(context, CommonConstants.STORAGE_KEY_QUADRANT_ORDER)
      await notificationCenterService.clearAll()
    } catch (e) {
      Logger.error(this.tag, 'deleteAllData: clear local extras failed: ' + (e as Error).message)
      ok = false
    }

    // 5. lastSyncTime 归零 + **清除持久化脏标记** 并持久化
    //    （云端记录已删、本地已清空：脏标记必须一并清掉，
    //      否则下次冷启动 merge 会拿空数据上传，把刚删除的云端记录"复活"）
    this.userProfile.lastSyncTime = 0
    this.pendingReadySync = false
    this.clearSyncNeeded('deleteAllData')
    await this.flush()

    Logger.warn(this.tag, 'deleteAllData END, ok=' + ok.toString())
    return ok
  }

  /**
   * 退出登录
   * 1. 先执行完整 merge（双向合并；失败则中止退出，由 ProfilePage 提示用户）
   * 2. cancelAuthorization 撤销华为 ID 授权
   * 3. 重置 userProfile + settings 为空实例
   * 4. emit CLEAR_ALL_REQUESTED → HomeVM/RouteVM 清空数据
   * 5. **清除持久化脏标记** + flush 持久化空状态 + syncLoginStateToAppStorage
   *
   * 为什么先 merge：退出会清空本地数据，不先同步则用户数据永久丢失；
   * 为什么用 merge 而不是裸 upload：裸 upload 会把云端整包覆盖，
   * 抹掉其它设备在此期间已上传的内容。
   */
  async logout(context: common.Context): Promise<boolean> {
    this.logoutUploadFailed = false
    const oldUid: string = this.userProfile.huaweiUid

    if (oldUid.length > 0) {
      // 云端同步关闭时跳过登出前预合并，但仍继续登出流程
      if (!CloudDBSyncProxy.getInstance().canSync()) {
        Logger.info(this.tag, 'logout: sync disabled, skip pre-logout merge')
      } else {
        // ★ 登出前完成双向合并：本地改动上云、云端他端改动也能一并落地
        const r: SyncResult | null = await this.syncNow('pre-logout')
        const merged: boolean = r !== null && (r.outcome === 'ok' || r.outcome === 'idle')
        if (!merged) {
          // 合并未完成（网络失败 / 未就绪）→ 中止退出，避免数据丢失
          Logger.warn(this.tag, 'pre-logout merge incomplete, abort logout to protect data. outcome=' +
            (r === null ? 'skipped' : r.outcome))
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
    // 开启清空抑制窗口：清空动作会经防抖回调触发 SYNC_NEEDED，
    // 窗口内禁止打脏标记 / 发起同步，防止"空数据上传把云端记录覆盖/复活"
    this.suppressAutoSyncUntil = Date.now() + CommonConstants.DELETE_ALL_SUPPRESS_SYNC_MS
    this.pendingReadySync = false
    this.clearSyncNeeded('logout')
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
    // 与 logout 一致：开启清空抑制窗口 + 清除持久化脏标记，
    // 防止清空动作触发的防抖回调把"空数据"标成待上传
    this.suppressAutoSyncUntil = Date.now() + CommonConstants.DELETE_ALL_SUPPRESS_SYNC_MS
    this.pendingReadySync = false
    this.clearSyncNeeded('force-logout')
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
