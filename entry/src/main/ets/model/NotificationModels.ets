/**
 * @file 站内通知中心模型
 * @description
 *   App 内通知中心的统一数据模型。
 *   - AppNotificationType：通知类型（任务截止 / 目标截止 / 番茄钟）
 *   - AppNotificationItem：单条通知记录（与系统通知镜像，供 App 内展示/删除/直达）
 *
 * @module model
 * @date 2026-08-12
 */

/** 站内通知类型 */
export type AppNotificationType = 'task_deadline' | 'goal_deadline' | 'pomodoro'

/**
 * 站内通知项（@ObservedV2 驱动 UI 刷新）
 * - 与系统通知镜像：发布系统通知时同步写入一条站内记录
 * - 点击直达：根据 targetRoute + targetId 跳转详情页
 */
@ObservedV2
export class AppNotificationItem {
  /** 唯一 ID（时间戳 + 随机后缀） */
  @Trace id: string = ''
  /** 通知类型 */
  @Trace type: AppNotificationType = 'task_deadline'
  /** 通知标题（已本地化文案） */
  @Trace title: string = ''
  /** 通知正文 */
  @Trace text: string = ''
  /** 关联对象 ID（taskId / goalId，点击直达用） */
  @Trace targetId: string = ''
  /** 点击直达路由名（ROUTE_NAME.GOAL_DETAIL / TASK_DETAIL） */
  @Trace targetRoute: string = ''
  /** 创建时间戳 */
  @Trace createdAt: number = 0
  /** 是否已读 */
  @Trace isRead: boolean = false

  constructor(
    id: string,
    type: AppNotificationType,
    title: string,
    text: string,
    targetId: string,
    targetRoute: string,
    createdAt: number,
    isRead: boolean = false
  ) {
    this.id = id
    this.type = type
    this.title = title
    this.text = text
    this.targetId = targetId
    this.targetRoute = targetRoute
    this.createdAt = createdAt
    this.isRead = isRead
  }
}

/**
 * 站内通知项持久化 JSON（纯字段对象）
 * 关键：@ObservedV2/@Trace 属性不可枚举，直接 JSON.stringify 实例会得到空对象，
 * 必须经由此纯字段接口手工快照/重建（与 AiGeneratedTask.toJSON 同一防坑策略）
 */
export interface AppNotificationItemJSON {
  id: string
  type: AppNotificationType
  title: string
  text: string
  targetId: string
  targetRoute: string
  createdAt: number
  isRead: boolean
}

/**
 * 站内通知持久化快照
 * 用于 StorageManager 序列化/反序列化
 */
export interface AppNotificationSnapshot {
  items: Array<AppNotificationItemJSON>
}