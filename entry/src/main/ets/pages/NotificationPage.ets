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
import { safeAreaHelper } from '../common/utils/SafeAreaHelper'
import { DimensConstants } from '../common/constants/DimensConstants'
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
import { AppActionSheet, AppActionSheetItem } from '../common/components/AppActionSheet'
import { MotionConstants } from '../common/constants/MotionConstants'
import { MotionHelper } from '../common/utils/MotionHelper'

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
  /** 统一操作面板状态 */
  @Local showActionSheet: boolean = false
  @Local actionSheetTitle: string = ''
  @Local actionSheetItems: AppActionSheetItem[] = []

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
   * 直达目标详情（反查 routeVM.liveGoals，目标已删除则提示）
   * @param goalId - 目标 ID
   */
  private navigateToGoalDetail(goalId: string): void {
    if (!goalId || goalId.length === 0) return
    let target: GoalCardItem | null = null
    for (let i: number = 0; i < routeVM.liveGoals.length; i++) {
      if (routeVM.liveGoals[i].id === goalId) {
        target = routeVM.liveGoals[i]
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
   * 直达任务详情（反查 homeVM.liveTasks，任务已删除则提示）
   * @param taskId - 任务 ID
   */
  private navigateToTaskDetail(taskId: string): void {
    if (!taskId || taskId.length === 0) return
    let target: HomeTodoItem | null = null
    for (let i: number = 0; i < homeVM.liveTasks.length; i++) {
      if (homeVM.liveTasks[i].id === taskId) {
        target = homeVM.liveTasks[i]
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
    // 统一 ActionSheet：替代系统 showDialog 兜底样式
    this.actionSheetTitle = getContext(this).resourceManager.getStringSync($r('app.string.notif_clear_message').id)
    this.actionSheetItems = [
      {
        label: getContext(this).resourceManager.getStringSync($r('app.string.notif_clear_confirm').id),
        danger: true,
        action: (): void => {
          notificationCenterService.clearAll().then((): void => {
            this.refreshList()
          }).catch((e: Error): void => {
            Logger.warn(this.tag, 'clearAll failed: ' + e.message)
          })
        }
      }
    ]
    this.showActionSheet = true
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
        .borderRadius(DimensConstants.RADIUS_XS)
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
    .borderRadius(DimensConstants.RADIUS_L)
    .alignItems(VerticalAlign.Center)
    .scale({
      x: this.pressedId === item.id ? 0.98 : 1,
      y: this.pressedId === item.id ? 0.98 : 1
    })
    .animation(MotionConstants.pressParam())
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
    // 统一 ActionSheet：替代系统 showActionMenu 兜底样式
    this.actionSheetTitle = safeStringUtil(item.title, '')
    this.actionSheetItems = [
      {
        label: getContext(this).resourceManager.getStringSync($r('app.string.notif_delete').id),
        danger: true,
        action: (): void => { this.handleDelete(item) }
      }
    ]
    this.showActionSheet = true
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
        .stateStyles({
          pressed: { .backgroundColor($r('app.color.bg_tag')) },
          normal: { .backgroundColor(Color.Transparent) }
        })
        .fontColor(notificationCenterService.unreadCount > 0
          ? $r('app.color.primary_color') : $r('app.color.text_tertiary'))
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        .onClick((): void => {
          this.handleMarkAllRead()
        })
    }
    .width('100%')
    .padding({ left: 8, right: 16, top: 4, bottom: 4 })
        .stateStyles({
          pressed: { .backgroundColor($r('app.color.bg_tag')) },
          normal: { .backgroundColor(Color.Transparent) }
        })
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
          // L1b：通知增删过渡（keyGenerator = item.id，稳定唯一）
          .transition(MotionHelper.listItem())
        }, (item: AppNotificationItem): string => item.id)
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 16, right: 16, top: 4, bottom: safeAreaHelper.getBottomWith(12) })
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
  }

  build() {
    NavDestination() {
      Stack() {
      Column() {
        CommonTitleBar({
          title: $r('app.string.page_notifications'),
          showBack: true,
          onBack: (): void => {
            this.handleBack()
          }
        })

        // isLoading 恒为 false（refreshList 为同步刷新），移除死分支
        if (notificationCenterService.notificationList.length === 0) {
          this.EmptyStateBuilder()
        } else {
          this.NotificationListBuilder()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))

      // 统一操作面板（替代系统 showActionMenu/showDialog）
      if (this.showActionSheet) {
        AppActionSheet({
          title: this.actionSheetTitle,
          items: this.actionSheetItems,
          onDismiss: (): void => {
            this.showActionSheet = false
          }
        })
      }
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .onBackPressed((): boolean => {
      this.handleBack()
      return true
    })
    .onShown((): void => {
      this.refreshList()
      // 修复：不再进页即自动全部已读——原行为让"全部已读"按钮和单条已读标记形同虚设，
      // 未读红点进页瞬间消失。改为由用户点击单条或"全部已读"按钮显式标记。
    })
  }
}
