/**
 * @file 站内通知中心服务（单例）
 * @description
 *   管理 App 内通知记录：系统通知发布时同步写入站内记录，
 *   供通知中心页面展示（列表 / 点击直达 / 删除 / 清空）。
 *
 *   能力范围：
 *   - add(type, title, text, targetId, targetRoute)：写入一条站内通知
 *   - markRead(id) / markAllRead()：标记已读
 *   - deleteItem(id) / clearAll()：删除单条 / 清空全部
 *   - getUnreadCount()：未读数（供入口角标展示）
 *
 *   设计原则：
 *   - 单例 + @ObservedV2/@Trace：通知页与入口角标可响应式联动
 *   - 持久化走 StorageManager（与项目其他 VM 一致），上限 50 条，超出丢弃最旧
 *   - 所有写操作 fire-and-forget + .catch 兜底，不阻断业务主流程
 *   - ArkTS 严格模式：无 any、无 as 强转、显式类型
 *
 * @module common/services
 * @date 2026-08-12
 */

import { Logger } from '../utils/Logger'
import { StorageManager } from '../utils/StorageManager'
import { CommonConstants } from '../constants/CommonConstants'
import { AppNotificationItem, AppNotificationType, AppNotificationItemJSON, AppNotificationSnapshot } from '../../model/NotificationModels'

/** 通知记录上限（超出丢弃最旧） */
const MAX_NOTIFICATION_COUNT: number = 50

/** 合法通知类型白名单（JSON 反序列化校验用） */
const NOTIFICATION_TYPES: Array<AppNotificationType> = ['task_deadline', 'goal_deadline', 'pomodoro']

/** 工厂函数：构造空快照（ArkTS 严格模式：对象字面量须显式类型） */
function buildEmptySnapshot(): AppNotificationSnapshot {
  const snapshot: AppNotificationSnapshot = { items: [] }
  return snapshot
}

/**
 * 持久化 JSON → 实例重建（逐字段校验，损坏记录跳过）
 * @param raw - 反序列化得到的纯字段对象
 * @returns 合法实例；非法返回 null
 */
function parseNotificationItem(raw: AppNotificationItemJSON): AppNotificationItem | null {
  if (raw === null || raw === undefined) {
    return null
  }
  if (typeof raw.id !== 'string' || raw.id.length === 0) {
    return null
  }
  let type: AppNotificationType = 'task_deadline'
  let typeValid: boolean = false
  for (let i: number = 0; i < NOTIFICATION_TYPES.length; i++) {
    if (raw.type === NOTIFICATION_TYPES[i]) {
      type = raw.type
      typeValid = true
      break
    }
  }
  if (!typeValid) {
    return null
  }
  return new AppNotificationItem(
    raw.id,
    type,
    typeof raw.title === 'string' ? raw.title : '',
    typeof raw.text === 'string' ? raw.text : '',
    typeof raw.targetId === 'string' ? raw.targetId : '',
    typeof raw.targetRoute === 'string' ? raw.targetRoute : '',
    typeof raw.createdAt === 'number' ? raw.createdAt : Date.now(),
    raw.isRead === true
  )
}

/**
 * 站内通知中心服务（单例）
 * - @ObservedV2 + @Trace：notificationList / unreadCount 变化可驱动 UI
 * - 供 ProfilePage 铃铛角标 + NotificationPage 列表共享
 */
@ObservedV2
export class NotificationCenterService {
  private static readonly tag: string = 'NotificationCenterService'
  private static instance: NotificationCenterService | null = null

  private context: Context | null = null
  private isInitialized: boolean = false

  /** 通知记录列表（最新在前） */
  @Trace notificationList: Array<AppNotificationItem> = []
  /** 未读数 */
  @Trace unreadCount: number = 0

  private constructor() {}

  static getInstance(): NotificationCenterService {
    if (NotificationCenterService.instance === null) {
      NotificationCenterService.instance = new NotificationCenterService()
    }
    return NotificationCenterService.instance
  }

  /**
   * 初始化服务（由 EntryAbility 调用）
   * 异步加载持久化通知记录，失败仅记录日志
   * @param context - 应用上下文
   */
  init(context: Context): void {
    if (this.isInitialized) {
      Logger.warn(NotificationCenterService.tag, 'already initialized')
      return
    }
    this.context = context
    this.isInitialized = true
    Logger.info(NotificationCenterService.tag, 'init success')
    this.loadFromStorage().catch((e: Error): void => {
      Logger.warn(NotificationCenterService.tag, 'loadFromStorage failed: ' + e.message)
    })
  }

  /**
   * 检查是否已初始化
   */
  private checkInit(): boolean {
    if (!this.isInitialized || this.context === null) {
      Logger.warn(NotificationCenterService.tag, 'not initialized')
      return false
    }
    return true
  }

  /**
   * 从持久化加载通知记录（init 时调用）
   * - 数据损坏时回退空列表，不阻塞服务
   * - 同时更新 unreadCount
   */
  private async loadFromStorage(): Promise<void> {
    if (!this.checkInit()) return
    try {
      const fallback: AppNotificationSnapshot = buildEmptySnapshot()
      // 关键：持久化走纯字段快照（@Trace 属性不可枚举，直接序列化实例会丢全部字段）
      const loaded: AppNotificationSnapshot = await StorageManager.loadData<AppNotificationSnapshot>(
        this.context!, CommonConstants.STORAGE_KEY_APP_NOTIFICATIONS, fallback)
      const items: Array<AppNotificationItem> = []
      const rawItems: Array<AppNotificationItemJSON> =
        Array.isArray(loaded.items) ? loaded.items : []
      for (let i: number = 0; i < rawItems.length; i++) {
        const item: AppNotificationItem | null = parseNotificationItem(rawItems[i])
        if (item !== null) {
          items.push(item)
        }
      }
      this.notificationList = items
      this.recountUnread()
      Logger.info(NotificationCenterService.tag, 'loadFromStorage success, count=' +
        this.notificationList.length.toString() + ', unread=' + this.unreadCount.toString())
    } catch (e) {
      Logger.warn(NotificationCenterService.tag, 'loadFromStorage failed: ' + (e as Error).message)
    }
  }

  /**
   * 新增一条站内通知
   * - 同 targetId + type 的通知视为重复，覆盖旧记录（避免 reschedule 产生垃圾）
   * - 上限 MAX_NOTIFICATION_COUNT，超出丢弃最旧
   * - 新通知标记未读，写入成功才增加 unreadCount
   *
   * @param type - 通知类型
   * @param title - 通知标题（调用方传入已本地化文案）
   * @param text - 通知正文
   * @param targetId - 关联对象 ID（taskId / goalId）
   * @param targetRoute - 点击直达路由名
   */
  async add(
    type: AppNotificationType,
    title: string,
    text: string,
    targetId: string,
    targetRoute: string
  ): Promise<void> {
    if (!this.checkInit()) return
    try {
      // 同 targetId + type 去重：先移除旧记录（保持时间倒序最新在前）
      const filtered: Array<AppNotificationItem> = []
      for (let i: number = 0; i < this.notificationList.length; i++) {
        const item: AppNotificationItem = this.notificationList[i]
        if (!(item.targetId === targetId && item.type === type)) {
          filtered.push(item)
        }
      }

      const item: AppNotificationItem = new AppNotificationItem(
        Date.now().toString() + '_' + Math.floor(Math.random() * 100000).toString(),
        type,
        title,
        text,
        targetId,
        targetRoute,
        Date.now(),
        false
      )
      filtered.unshift(item)

      // 截断超上限记录
      if (filtered.length > MAX_NOTIFICATION_COUNT) {
        filtered.splice(MAX_NOTIFICATION_COUNT)
      }

      this.notificationList = filtered
      this.unreadCount += 1

      await this.persist()
      Logger.info(NotificationCenterService.tag, 'add success, type=' + type +
        ', targetId=' + targetId + ', unread=' + this.unreadCount.toString())
    } catch (e) {
      Logger.warn(NotificationCenterService.tag, 'add failed: ' + (e as Error).message)
    }
  }

  /**
   * 标记单条通知为已读
   * @param id - 通知 ID
   */
  async markRead(id: string): Promise<void> {
    if (!this.checkInit()) return
    let changed: boolean = false
    for (let i: number = 0; i < this.notificationList.length; i++) {
      const item: AppNotificationItem = this.notificationList[i]
      if (item.id === id && !item.isRead) {
        item.isRead = true
        changed = true
        break
      }
    }
    if (!changed) return
    this.recountUnread()
    await this.persist()
    Logger.info(NotificationCenterService.tag, 'markRead success, id=' + id)
  }

  /**
   * 标记全部为已读
   */
  async markAllRead(): Promise<void> {
    if (!this.checkInit()) return
    let changed: boolean = false
    for (let i: number = 0; i < this.notificationList.length; i++) {
      if (!this.notificationList[i].isRead) {
        this.notificationList[i].isRead = true
        changed = true
      }
    }
    if (!changed) return
    this.recountUnread()
    await this.persist()
    Logger.info(NotificationCenterService.tag, 'markAllRead success')
  }

  /**
   * 删除单条通知
   * @param id - 通知 ID
   */
  async deleteItem(id: string): Promise<void> {
    if (!this.checkInit()) return
    const filtered: Array<AppNotificationItem> = []
    let removed: boolean = false
    for (let i: number = 0; i < this.notificationList.length; i++) {
      const item: AppNotificationItem = this.notificationList[i]
      if (item.id === id) {
        removed = true
      } else {
        filtered.push(item)
      }
    }
    if (!removed) return
    this.notificationList = filtered
    this.recountUnread()
    await this.persist()
    Logger.info(NotificationCenterService.tag, 'deleteItem success, id=' + id)
  }

  /**
   * 清空全部通知
   */
  async clearAll(): Promise<void> {
    if (!this.checkInit()) return
    if (this.notificationList.length === 0) return
    this.notificationList = []
    this.unreadCount = 0
    await this.persist()
    Logger.info(NotificationCenterService.tag, 'clearAll success')
  }

  /**
   * 获取未读数（入口角标展示）
   * @returns 未读数量
   */
  getUnreadCount(): number {
    return this.unreadCount
  }

  /**
   * 重新统计未读数
   */
  private recountUnread(): void {
    let count: number = 0
    for (let i: number = 0; i < this.notificationList.length; i++) {
      if (!this.notificationList[i].isRead) {
        count++
      }
    }
    this.unreadCount = count
  }

  /**
   * 持久化通知列表（fire-and-forget 由调用方 await）
   */
  private async persist(): Promise<void> {
    if (!this.checkInit()) return
    try {
      // 关键：手工构建纯字段快照（@Trace 属性不可枚举，直接序列化实例会得到空对象）
      const snapshot: AppNotificationSnapshot = { items: [] }
      for (let i: number = 0; i < this.notificationList.length; i++) {
        const item: AppNotificationItem = this.notificationList[i]
        const record: AppNotificationItemJSON = {
          id: item.id,
          type: item.type,
          title: item.title,
          text: item.text,
          targetId: item.targetId,
          targetRoute: item.targetRoute,
          createdAt: item.createdAt,
          isRead: item.isRead
        }
        snapshot.items.push(record)
      }
      await StorageManager.saveData(
        this.context!, CommonConstants.STORAGE_KEY_APP_NOTIFICATIONS, snapshot)
      Logger.info(NotificationCenterService.tag, 'persist success, count=' +
        this.notificationList.length.toString())
    } catch (e) {
      Logger.warn(NotificationCenterService.tag, 'persist failed: ' + (e as Error).message)
    }
  }
}

/**
 * 全局单例导出
 */
export const notificationCenterService: NotificationCenterService = NotificationCenterService.getInstance()