/** 我的页相关数据模型（用户信息、应用设置、设置项） */

import { Id } from './BaseTypes'

// 1. 用户信息

// 用户信息（@ObservedV2 class，支持华为登录 + 云同步）
@ObservedV2
export class UserProfile {
  @Trace id: Id = ''
  @Trace nickname: string = ''
  @Trace signature: string = ''
  @Trace avatarUri: string = ''
  @Trace email: string = ''
  @Trace aiCredits: string = '0'
  @Trace huaweiUid: string = ''
  @Trace isLoggedIn: boolean = false
  @Trace lastSyncTime: number = 0

  constructor(
    id: string = '',
    nickname: string = '',
    signature: string = '',
    avatarUri: string = '',
    email: string = '',
    aiCredits: string = '0',
    huaweiUid: string = '',
    isLoggedIn: boolean = false,
    lastSyncTime: number = 0
  ) {
    this.id = id
    this.nickname = nickname
    this.signature = signature
    this.avatarUri = avatarUri
    this.email = email
    this.aiCredits = aiCredits
    this.huaweiUid = huaweiUid
    this.isLoggedIn = isLoggedIn
    this.lastSyncTime = lastSyncTime
  }

  toJSON(): Record<string, Object> {
    return {
      'id': this.id,
      'nickname': this.nickname,
      'signature': this.signature,
      'avatarUri': this.avatarUri,
      'email': this.email,
      'aiCredits': this.aiCredits,
      'huaweiUid': this.huaweiUid,
      'isLoggedIn': this.isLoggedIn,
      'lastSyncTime': this.lastSyncTime
    } as Record<string, Object>
  }

  static fromJSON(json: Record<string, Object>): UserProfile {
    return new UserProfile(
      typeof json['id'] === 'string' ? json['id'] as string : '',
      typeof json['nickname'] === 'string' ? json['nickname'] as string : '',
      typeof json['signature'] === 'string' ? json['signature'] as string : '',
      typeof json['avatarUri'] === 'string' ? json['avatarUri'] as string : '',
      typeof json['email'] === 'string' ? json['email'] as string : '',
      typeof json['aiCredits'] === 'string' ? json['aiCredits'] as string : '0',
      typeof json['huaweiUid'] === 'string' ? json['huaweiUid'] as string : '',
      typeof json['isLoggedIn'] === 'boolean' ? json['isLoggedIn'] as boolean : false,
      typeof json['lastSyncTime'] === 'number' ? json['lastSyncTime'] as number : 0
    )
  }
}

// 2. 应用设置

// AppSettings 的纯数据快照（用于 JSON 序列化/反序列化，与 @Trace 字段一一对应）
export interface AppSettingsJSON {
  notificationEnabled: boolean
  privacyAgreed: boolean
  vibrationEnabled: boolean
  /** 云端同步总开关，默认关闭（隐私优先） */
  syncEnabled: boolean
}

// 应用设置 Model 类，持久化到 Preferences
@ObservedV2
export class AppSettings {
  /** 是否开启通知 */
  @Trace notificationEnabled: boolean = true
  /** 是否已同意隐私协议 */
  @Trace privacyAgreed: boolean = false
  /** 震动反馈 */
  @Trace vibrationEnabled: boolean = true
  /** 云端同步总开关，默认关闭（隐私优先） */
  @Trace syncEnabled: boolean = false

  constructor() {
  }

  toJSON(): AppSettingsJSON {
    return {
      notificationEnabled: this.notificationEnabled,
      privacyAgreed: this.privacyAgreed,
      vibrationEnabled: this.vibrationEnabled,
      syncEnabled: this.syncEnabled
    }
  }

  static fromJSON(json: AppSettingsJSON | null | undefined): AppSettings {
    if (!json) return new AppSettings()
    const settings: AppSettings = new AppSettings()
    settings.notificationEnabled = typeof json.notificationEnabled === 'boolean'
      ? json.notificationEnabled : true
    settings.privacyAgreed = typeof json.privacyAgreed === 'boolean'
      ? json.privacyAgreed : false
    settings.vibrationEnabled = typeof json.vibrationEnabled === 'boolean'
      ? json.vibrationEnabled : true
    settings.syncEnabled = typeof json.syncEnabled === 'boolean'
      ? json.syncEnabled : false
    return settings
  }
}

// 3. 设置项 / 选项

// 设置分组项（值对象）
export interface ProfileSettingItem {
  id: Id
  /** 显示标题（已 toString） */
  title: string
  /** 副标题/描述（已 toString） */
  subtitle: string
  /** 控件类型 */
  controlType: 'toggle' | 'select' | 'input' | 'navigate'
  /** 控件当前值 */
  value: string | boolean | number | null
  /** 选项列表（controlType=select 时使用） */
  options: SelectOptionItem[]
}

// Select 选项项（值对象）
export interface SelectOptionItem {
  /** 选项值（已 toString） */
  value: string
  /** 显示文本（已 toString） */
  text: string
}
