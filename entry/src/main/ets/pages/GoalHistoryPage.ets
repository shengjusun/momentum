/**
 * @file 目标历史页
 * @description
 *   根据 status 参数过滤并展示 L1 目标列表
 *   - pending: 所有 L2 任务均为 PENDING 的目标（待开始）
 *   - inProgress: 至少一个 L2 任务为 IN_PROGRESS/COMPLETED，但非全部完成（进行中）
 *   - completed: 所有 L2 任务均为 COMPLETED 的目标（已完结）
 *
 * 跳转来源：ProfilePage 数据纵览卡片的三列点击
 *
 * @module pages
 * @date 2026-07-03
 */

import { routeVM } from '../viewmodel/RoutePageViewModel'
import { safeAreaHelper } from '../common/utils/SafeAreaHelper'
import { DimensConstants } from '../common/constants/DimensConstants'
import { GoalCardItem, RouteParam, GoalDetailRouteNavParam } from '../model/Models'
import { globalNavStack, ROUTE_NAME } from '../common/RouterManager'
import { Logger } from '../common/utils/Logger'
import { safeStringUtil, safeNumberUtil, formatDeadlineUtil } from '../common/utils/SafeUtils'
import { CommonTitleBar } from '../common/components/CommonTitleBar'
import { MotionConstants } from '../common/constants/MotionConstants'

/**
 * 目标历史页懒加载数据源
 */
class GoalHistoryDataSource implements IDataSource {
  private goals: GoalCardItem[] = []
  private listeners: DataChangeListener[] = []

  totalCount(): number {
    return this.goals.length
  }

  getData(index: number): GoalCardItem {
    return this.goals[index]
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

  setGoals(goals: GoalCardItem[]): void {
    this.goals = goals
    this.notifyDataReload()
  }
}

/**
 * 目标历史页
 */
@ComponentV2
export struct GoalHistoryPage {
  @Local statusFilter: string = 'all'
  @Local pageTitle: ResourceStr = $r('app.string.page_goal_history')
  @Local pressedGoalId: string = ''
  @Local dataSource: GoalHistoryDataSource = new GoalHistoryDataSource()

  private readonly tag: string = 'GoalHistoryPage'

  /**
   * NavDestination onReady 回调，获取路由参数
   */
  private onDestinationReady(context: NavDestinationContext): void {
    try {
      const rawParam: Object = context.pathInfo.param as Object
      if (rawParam === null || rawParam === undefined) {
        Logger.info(this.tag, 'onDestinationReady: no param, show all')
        this.statusFilter = 'all'
        this.updateTitle('all')
        return
      }
      const navParam: RouteParam = rawParam as RouteParam
      if (navParam.status && navParam.status.length > 0) {
        const status: string = navParam.status
        if (status === 'pending' || status === 'inProgress' || status === 'completed' || status === 'overdue') {
          this.statusFilter = status
          this.updateTitle(status)
          Logger.info(this.tag, 'onDestinationReady: status=' + status)
          return
        }
      }
      this.statusFilter = 'all'
      this.updateTitle('all')
    } catch (e) {
      const err: Error = e as Error
      Logger.error(this.tag, 'onDestinationReady failed: ' + err.message)
      this.statusFilter = 'all'
      this.updateTitle('all')
    }
  }

  /**
   * 根据状态更新页面标题
   */
  private updateTitle(status: string): void {
    if (status === 'pending') {
      this.pageTitle = $r('app.string.profile_stat_todo')
    } else if (status === 'inProgress') {
      this.pageTitle = $r('app.string.profile_stat_in_progress')
    } else if (status === 'completed') {
      this.pageTitle = $r('app.string.profile_stat_completed')
    } else if (status === 'overdue') {
      this.pageTitle = $r('app.string.profile_stat_overdue')
    } else {
      this.pageTitle = $r('app.string.page_goal_history')
    }
  }

  /**
   * 判断目标是否匹配当前过滤状态
   * 基于 L1 目标 progress 字段判定，与 RoutePageViewModel 三态统计逻辑一致：
   *   - pending:    progress === 0
   *   - inProgress: 0 < progress < 100
   *   - completed:  progress === 100
   */
  private matchStatus(goal: GoalCardItem): boolean {
    if (this.statusFilter === 'all') return true
    const p: number = goal.progress
    if (this.statusFilter === 'pending') {
      return p === 0
    } else if (this.statusFilter === 'inProgress') {
      return p > 0 && p < 100
    } else if (this.statusFilter === 'completed') {
      return p === 100
    } else if (this.statusFilter === 'overdue') {
      const deadline: number = goal.deadline
      return p < 100 && deadline > 0 && deadline < Date.now()
    }
    return true
  }

  /**
   * 跳转到目标详情页
   * 传入完整 GoalCardItem，避免详情页拿不到 goal 字段导致兜底空数据
   */
  private navigateToGoalDetail(goal: GoalCardItem): void {
    if (!goal || !goal.id) return
    const param: GoalDetailRouteNavParam = {
      id: goal.id,
      goal: goal
    }
    const pathInfo: NavPathInfo = new NavPathInfo(ROUTE_NAME.GOAL_DETAIL, param)
    globalNavStack.pushPath(pathInfo)
  }

  /**
   * 返回上一页
   */
  private handleBack(): void {
    globalNavStack.pop()
  }

  /**
   * 更新数据源：根据当前过滤状态过滤目标列表并设置到 dataSource
   */
  private updateDataSource(): void {
    const filtered: GoalCardItem[] = []
    // 历史列表只展示存活目标（墓碑不参与展示）
    const goals: GoalCardItem[] = routeVM.liveGoals
    for (let i: number = 0; i < goals.length; i++) {
      const goal: GoalCardItem = goals[i]
      if (goal && goal.id && Array.isArray(goal.tasks) && goal.tasks.length > 0 && this.matchStatus(goal)) {
        filtered.push(goal)
      }
    }
    this.dataSource.setGoals(filtered)
  }

  @Builder
  GoalCardBuilder(goal: GoalCardItem): void {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Stack({ alignContent: Alignment.Center }) {
          Progress({ value: goal.progress, total: 100, type: ProgressType.Ring })
            .width(60)
            .height(60)
            .style({ strokeWidth: 8 })
            .color($r('app.color.primary_color'))
            .backgroundColor($r('app.color.bg_progress_track'))

          Text(safeNumberUtil(goal.progress, 0).toString() + '%')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
        }
        .width(60)
        .height(60)

        Column({ space: 6 }) {
          Row({ space: 6 }) {
            Text(safeStringUtil(goal.name,
              getContext(this).resourceManager.getStringSync($r('app.string.default_unnamed_goal').id)))
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)

            Text(safeStringUtil(goal.category,
              getContext(this).resourceManager.getStringSync($r('app.string.default_other_category').id)))
              .fontSize(10)
              .fontColor($r('app.color.primary_color'))
              .backgroundColor($r('app.color.bg_tag'))
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(DimensConstants.RADIUS_XS)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Text(safeStringUtil(goal.description, ''))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          Row({ space: 8 }) {
            Text(safeStringUtil(goal.duration, ''))
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))

            Text('·')
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))

            Text(getContext(this).resourceManager.getStringSync($r('app.string.route_deadline_prefix').id) +
              formatDeadlineUtil(goal.deadline))
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(12)
    .backgroundColor(this.pressedGoalId === goal.id ?
      $r('app.color.bg_tag') : $r('app.color.bg_card'))
    .borderRadius(DimensConstants.RADIUS_L)
    .shadow({
      radius: this.pressedGoalId === goal.id ? 4 : 8,
      color: $r('app.color.shadow_card'),
      offsetX: 0,
      offsetY: this.pressedGoalId === goal.id ? 1 : 2
    })
    .scale({
      x: this.pressedGoalId === goal.id ? 0.98 : 1,
      y: this.pressedGoalId === goal.id ? 0.98 : 1
    })
    .animation(MotionConstants.pressParam())
    .accessibilityText(
      getContext(this).resourceManager.getStringSync($r('app.string.acc_goal_history_card').id) + ' ' +
      safeStringUtil(goal.name, getContext(this).resourceManager.getStringSync($r('app.string.default_unnamed_goal').id)) +
      ' ' + safeNumberUtil(goal.progress, 0).toString() + '%')
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down) {
        this.pressedGoalId = goal.id
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressedGoalId = ''
      }
    })
    .onClick((): void => {
      this.navigateToGoalDetail(goal)
    })
  }

  @Builder
  EmptyStateBuilder(): void {
    Column({ space: 12 }) {
      // 空态插图：纯几何装饰，避免系统符号资源依赖
      Column()
        .width(64)
        .height(64)
        .borderRadius(32)
        .backgroundColor($r('app.color.bg_tag'))
        .border({ width: 1.5, color: $r('app.color.divider') })
      // 根据过滤状态显示不同文案
      if (this.statusFilter === 'completed') {
        Text($r('app.string.goal_history_empty_completed'))
          .fontSize(14)
          .fontColor($r('app.color.text_tertiary'))
      } else if (this.statusFilter === 'inProgress') {
        Text($r('app.string.goal_history_empty_in_progress'))
          .fontSize(14)
          .fontColor($r('app.color.text_tertiary'))
      } else if (this.statusFilter === 'overdue') {
        Text($r('app.string.goal_history_empty_overdue'))
          .fontSize(14)
          .fontColor($r('app.color.text_tertiary'))
      } else {
        Text($r('app.string.goal_history_empty'))
          .fontSize(14)
          .fontColor($r('app.color.text_tertiary'))
      }
    }
    .width('100%')
    .padding({ top: 80, bottom: 80 })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  GoalListBuilder(): void {
    List({ space: 12 }) {
      LazyForEach(this.dataSource, (goal: GoalCardItem): void => {
        ListItem() {
          this.GoalCardBuilder(goal)
        }
      }, (goal: GoalCardItem): string => goal.id)
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 16, right: 16, top: 12, bottom: safeAreaHelper.getBottomWith(12) })
  }

  build() {
    NavDestination() {
      Column() {
        CommonTitleBar({
          title: this.pageTitle,
          showBack: true,
          onBack: (): void => {
            this.handleBack()
          }
        })

        if (this.dataSource.totalCount() === 0) {
          this.EmptyStateBuilder()
        } else {
          this.GoalListBuilder()
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
    .onReady((context: NavDestinationContext): void => {
      this.onDestinationReady(context)
      this.updateDataSource()
    })
    .onShown((): void => {
      this.updateDataSource()
    })
  }
}
