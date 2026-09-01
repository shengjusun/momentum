/**
 * @file 通知中心页
 * @description
 *   站内通知中心：展示系统通知的镜像记录（任务截止 / 目标截止 / 番茄钟完成）
 *   - 列表展示：标题 / 正文 / 时间 / 未读红点
 *   - 点击直达：任务 → TaskDetailPage，目标 → GoalDetailPage
 *   - 长按 / 右键菜单删除单条，顶部按钮清空全部
 *   - 进入页面时标记全部已读
 *
 * 跳转来源：ProfilePage 铃铛入口
 *
 * @module pages
 * @date 2026-08-12
 */

import { promptAction } from '@kit.ArkUI'
import { CommonConstants } from '../common/constants/CommonConstants'
import { notificationCenterService } from '../common/services/NotificationCenterService'
import { AppNotificationItem } from '../model/NotificationModels'
import { routeVM } from '../viewmodel/RoutePageViewModel'
import { homeVM } from '../viewmodel/HomeViewModel'
import { GoalCardItem, GoalDetailRouteNavParam, HomeTodoItem, TaskDetailItem, TaskDetailRouteNavParam } from '../model/Models'
import { globalNavStack, ROUTE_NAME, pushNavPath } from '../common/RouterManager'
import { Logger } from '../common/utils/Logger'
import { safeStringUtil } from '../common/utils/SafeUtils'
import { CommonTitleBar } from '../common/components/CommonTitleBar'

/** 通知列表懒加载数据源 */
class NotificationDataSource implements IDataSource {
  private items: Array<AppNotificationItem> = []
  private listeners: DataChangeListener[] = []

  totalCount(): number {
    return this.items.length
  }

  getData(index: number): AppNotificationItem {
    return this.items[index]
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener)
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos: number = this.listeners.indexOf(listener)
    if (pos >= 0) {
      this.listeners.splice(pos, 1)
    }
  }

  notifyDataReload(): void {
    this.listeners.forEach((listener: DataChangeListener): void => {
      listener.onDataReloaded()
    })
  }

  setItems(items: Array<AppNotificationItem>): void {
    this.items = items
    this.notifyDataReload()
  }
}

/**
 * 通知中心页
 */
@ComponentV2
export struct NotificationPage {
  @Local dataSource: NotificationDataSource = new NotificationDataSource()
  @Local pressedId: string = ''
  @Local isLoading: boolean = false

  private readonly tag: string = 'NotificationPage'

  aboutToAppear(): void {
    this.refreshList()
  }

  /**
   * 刷新列表：从服务读取最新通知并同步数据源
   */
  private refreshList(): void {
    this.dataSource.setItems(notificationCenterService.notificationList)
  }

  /**
   * 返回上一页
   */
  private handleBack(): void {
    globalNavStack.pop()
  }

  /**
   * 点击通知：标记已读 + 直达详情页
   * - task_deadline / pomodoro → TaskDetailPage（从 homeVM 反查任务构造路由参数）
   * - goal_deadline → GoalDetailPage（从 routeVM 反查目标构造路由参数）
   * - 关联对象已删除时 toast 提示
   */
  private handleClick(item: AppNotificationItem): void {
    if (!item || !item.id) return
    notificationCenterService.markRead(item.id).then((): void => {
      this.refreshList()
    }).catch((e: Error): void => {
      Logger.warn(this.tag, 'markRead failed: ' + e.message)
    })

    if (item.targetRoute === ROUTE_NAME.GOAL_DETAIL) {
      this.navigateToGoalDetail(item.targetId)
    } else if (item.targetRoute === ROUTE_NAME.TASK_DETAIL) {
      this.navigateToTaskDetail(item.targetId)
    }
  }

  /**
   * 直达目标详情（反查 routeVM.goals，目标已删除则提示）
   * @param goalId - 目标 ID
   */
  private navigateToGoalDetail(goalId: string): void {
    if (!goalId || goalId.length === 0) return
    let target: GoalCardItem | null = null
    for (let i: number = 0; i < routeVM.goals.length; i++) {
      if (routeVM.goals[i].id === goalId) {
        target = routeVM.goals[i]
        break
      }
    }
    if (target === null) {
      promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.notif_target_deleted').id) })
      return
    }
    const param: GoalDetailRouteNavParam = {
      id: target.id,
      goal: target
    }
    pushNavPath(ROUTE_NAME.GOAL_DETAIL, param)
  }

  /**
   * 直达任务详情（反查 homeVM.taskList，任务已删除则提示）
   * @param taskId - 任务 ID
   */
  private navigateToTaskDetail(taskId: string): void {
    if (!taskId || taskId.length === 0) return
    let target: HomeTodoItem | null = null
    for (let i: number = 0; i < homeVM.taskList.length; i++) {
      if (homeVM.taskList[i].id === taskId) {
        target = homeVM.taskList[i]
        break
      }
    }
    if (target === null) {
      promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.notif_target_deleted').id) })
      return
    }
    const detailItem: TaskDetailItem = new TaskDetailItem(
      target.id,
      target.title,
      '',
      target.duration,
      target.priority,
      target.isCompleted,
      target.createTime
    )
    const param: TaskDetailRouteNavParam = {
      id: target.id,
      task: detailItem,
      goalId: target.relatedGoalId,
      relatedTaskId: target.relatedTaskId
    }
    pushNavPath(ROUTE_NAME.TASK_DETAIL, param)
  }

  /**
   * 删除单条通知
   * @param item - 通知项
   */
  private handleDelete(item: AppNotificationItem): void {
    if (!item || !item.id) return
    notificationCenterService.deleteItem(item.id).then((): void => {
      this.refreshList()
    }).catch((e: Error): void => {
      Logger.warn(this.tag, 'deleteItem failed: ' + e.message)
    })
  }

  /**
   * 清空全部通知（二次确认）
   */
  private handleClearAll(): void {
    if (notificationCenterService.notificationList.length === 0) return
    promptAction.showDialog({
      title: $r('app.string.notif_clear_title'),
      message: $r('app.string.notif_clear_message'),
      buttons: [
        { text: $r('app.string.common_cancel'), color: $r('app.color.text_tertiary') },
        { text: $r('app.string.notif_clear_confirm'), color: $r('app.color.error_color') }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse): void => {
      if (result.index === 1) {
        notificationCenterService.clearAll().then((): void => {
          this.refreshList()
        }).catch((e: Error): void => {
          Logger.warn(this.tag, 'clearAll failed: ' + e.message)
        })
      }
    }).catch((e: Error): void => {
      Logger.warn(this.tag, 'clear dialog failed: ' + e.message)
    })
  }

  /**
   * 标记全部已读（进入页面 / 顶部按钮）
   */
  private handleMarkAllRead(): void {
    notificationCenterService.markAllRead().then((): void => {
      this.refreshList()
    }).catch((e: Error): void => {
      Logger.warn(this.tag, 'markAllRead failed: ' + e.message)
    })
  }

  /**
   * 格式化通知时间（相对时间：刚刚 / N 分钟前 / N 小时前 / N 天前）
   * @param ts - 时间戳
   */
  private formatTime(ts: number): string {
    if (typeof ts !== 'number' || isNaN(ts) || ts <= 0) {
      return getContext(this).resourceManager.getStringSync($r('app.string.default_unknown').id)
    }
    const diff: number = Date.now() - ts
    if (diff < 60000) return getContext(this).resourceManager.getStringSync($r('app.string.sync_just_now').id)
    if (diff < 3600000) return Math.floor(diff / 60000).toString() + getContext(this).resourceManager.getStringSync($r('app.string.sync_minutes_ago_suffix').id)
    if (diff < 86400000) return Math.floor(diff / 3600000).toString() + getContext(this).resourceManager.getStringSync($r('app.string.sync_hours_ago_suffix').id)
    return Math.floor(diff / 86400000).toString() + getContext(this).resourceManager.getStringSync($r('app.string.sync_days_ago_suffix').id)
  }

  @Builder
  NotificationItemBuilder(item: AppNotificationItem): void {
    Row({ space: 12 }) {
      // 未读红点
      Column()
        .width(8)
        .height(8)
        .borderRadius(4)
        .backgroundColor(item.isRead ? Color.Transparent : $r('app.color.error_color'))
        .margin({ left: 2 })

      // 通知内容
      Column({ space: 4 }) {
        Text(safeStringUtil(item.title, ''))
          .fontSize(CommonConstants.FONT_SIZE_MID)
          .fontWeight(item.isRead ? FontWeight.Regular : FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Text(safeStringUtil(item.text, ''))
          .fontSize(CommonConstants.FONT_SIZE_CAPTION)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Text(this.formatTime(item.createdAt))
          .fontSize(CommonConstants.FONT_SIZE_XS)
          .fontColor($r('app.color.text_tertiary'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.pressedId === item.id ?
      $r('app.color.bg_tag') : $r('app.color.bg_card'))
    .borderRadius(16)
    .alignItems(VerticalAlign.Center)
    .scale({
      x: this.pressedId === item.id ? 0.98 : 1,
      y: this.pressedId === item.id ? 0.98 : 1
    })
    .animation({ duration: 100, curve: Curve.EaseOut })
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down) {
        this.pressedId = item.id
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressedId = ''
      }
    })
    .onClick((): void => {
      this.handleClick(item)
    })
    .gesture(
      LongPressGesture()
        .onAction((): void => {
          this.showItemActions(item)
        })
    )
  }

  /**
   * 单条通知操作菜单（删除）
   * @param item - 通知项
   */
  private showItemActions(item: AppNotificationItem): void {
    promptAction.showActionMenu({
      title: safeStringUtil(item.title, ''),
      buttons: [
        {
          text: $r('app.string.notif_delete'),
          color: $r('app.color.error_color')
        },
        {
          text: $r('app.string.common_cancel'),
          color: $r('app.color.text_tertiary')
        }
      ]
    }).then((result: promptAction.ActionMenuSuccessResponse): void => {
      if (result.index === 0) {
        this.handleDelete(item)
      }
    }).catch((e: Error): void => {
      Logger.warn(this.tag, 'action menu failed: ' + e.message)
    })
  }

  @Builder
  EmptyStateBuilder(): void {
    Column({ space: 12 }) {
      Column()
        .width(64)
        .height(64)
        .borderRadius(32)
        .backgroundColor($r('app.color.bg_tag'))
        .border({ width: 1.5, color: $r('app.color.divider') })
      Text($r('app.string.notif_empty'))
        .fontSize(CommonConstants.FONT_SIZE_BODY)
        .fontColor($r('app.color.text_tertiary'))
    }
    .width('100%')
    .padding({ top: 80, bottom: 80 })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  HeaderActionsBuilder(): void {
    Row() {
      Text($r('app.string.notif_clear_all'))
        .fontSize(CommonConstants.FONT_SIZE_BODY)
        .fontColor(notificationCenterService.notificationList.length > 0
          ? $r('app.color.primary_color') : $r('app.color.text_tertiary'))
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        .onClick((): void => {
          this.handleClearAll()
        })

      Text($r('app.string.notif_read_all'))
        .fontSize(CommonConstants.FONT_SIZE_BODY)
        .fontColor(notificationCenterService.unreadCount > 0
          ? $r('app.color.primary_color') : $r('app.color.text_tertiary'))
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        .onClick((): void => {
          this.handleMarkAllRead()
        })
    }
    .width('100%')
    .padding({ left: 8, right: 16, top: 4, bottom: 4 })
    .justifyContent(FlexAlign.End)
  }

  @Builder
  NotificationListBuilder(): void {
    Column() {
      this.HeaderActionsBuilder()

      List({ space: 10 }) {
        LazyForEach(this.dataSource, (item: AppNotificationItem): void => {
          ListItem() {
            this.NotificationItemBuilder(item)
          }
        }, (item: AppNotificationItem): string => item.id)
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 16, right: 16, top: 4, bottom: 12 })
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
  }

  build() {
    NavDestination() {
      Column() {
        CommonTitleBar({
          title: $r('app.string.page_notifications'),
          showBack: true,
          onBack: (): void => {
            this.handleBack()
          }
        })

        if (this.isLoading) {
          Column() {
            LoadingProgress()
              .width(40)
              .height(40)
              .color($r('app.color.primary_color'))
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        } else if (notificationCenterService.notificationList.length === 0) {
          this.EmptyStateBuilder()
        } else {
          this.NotificationListBuilder()
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
    .onShown((): void => {
      this.refreshList()
      // 进入页面时自动标记全部已读（角标清零）
      if (notificationCenterService.unreadCount > 0) {
        notificationCenterService.markAllRead().then((): void => {
          this.refreshList()
        }).catch((e: Error): void => {
          Logger.warn(this.tag, 'onShown markAllRead failed: ' + e.message)
        })
      }
    })
  }
}