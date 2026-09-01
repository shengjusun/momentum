/**
 * @file 数据统计 & AI 全局复盘页
 * @description 我的 → 工具与管理 → AI复盘 & 数据统计
 *   - 数据概览：目标总数 / 已完成 / 已逾期 / 任务总数 / 今日专注
 *   - AI 全局复盘：基于整体数据调用 DeepSeek 生成复盘报告（全屏弹层展示）
 *
 * 跳转来源：ProfilePage 工具与管理分组
 *
 * @module pages
 */

import { promptAction } from '@kit.ArkUI'
import { CommonConstants } from '../common/constants/CommonConstants'
import { DimensConstants } from '../common/constants/DimensConstants'
import { Logger } from '../common/utils/Logger'
import { routeVM } from '../viewmodel/RoutePageViewModel'
import { homeVM } from '../viewmodel/HomeViewModel'
import { pomodoroService } from '../common/services/PomodoroService'
import { DeepSeekService } from '../common/services/DeepSeekService'
import { globalNavStack } from '../common/RouterManager'
import { CommonTitleBar } from '../common/components/CommonTitleBar'
import { safeAreaHelper } from '../common/utils/SafeAreaHelper'

@Entry
@ComponentV2
export struct StatsPage {
  @Local showReviewSheet: boolean = false
  @Local reviewLoading: boolean = false
  @Local reviewText: string = ''
  @Local todayFocusCount: number = 0

  async aboutToAppear(): Promise<void> {
    try {
      const stats = await pomodoroService.loadStats()
      this.todayFocusCount = stats.todayFocusCount
    } catch (e) {
      Logger.warn('StatsPage', 'loadStats failed: ' + (e as Error).message)
    }
  }

  private handleBack(): void {
    globalNavStack.pop()
  }

  /**
   * 构造全局复盘数据文本（目标/任务/专注汇总）
   */
  private buildGlobalSummary(): string {
    const goalTotal: number = routeVM.goals.length
    const taskTotal: number = homeVM.taskList.length
    const completedGoals: number = routeVM.completedGoalCount
    const overdueGoals: number = routeVM.overdueGoalCount
    const focusCount: number = this.todayFocusCount
    return '目标总数：' + goalTotal.toString() +
      '；已完成目标：' + completedGoals.toString() +
      '；逾期目标：' + overdueGoals.toString() +
      '；任务总数：' + taskTotal.toString() +
      '；今日专注次数：' + focusCount.toString()
  }

  private handleGlobalReview(): void {
    const summary: string = this.buildGlobalSummary()
    if (summary.length === 0) {
      promptAction.showToast({
        message: getContext(this).resourceManager.getStringSync($r('app.string.stats_no_data').id),
        duration: 1500
      })
      return
    }
    this.showReviewSheet = true
    this.reviewLoading = true
    this.reviewText = ''
    DeepSeekService.getInstance().generateGlobalReview(summary).then((report: string): void => {
      this.reviewLoading = false
      if (report.length === 0) {
        this.reviewText = ''
        this.showReviewSheet = false
        promptAction.showToast({
          message: getContext(this).resourceManager.getStringSync($r('app.string.toast_review_failed').id),
          duration: 1500
        })
        return
      }
      this.reviewText = report
    }).catch((e: Error): void => {
      Logger.error('StatsPage', 'generateGlobalReview failed: ' + e.message)
      this.reviewLoading = false
      this.showReviewSheet = false
      promptAction.showToast({
        message: getContext(this).resourceManager.getStringSync($r('app.string.toast_review_failed').id),
        duration: 1500
      })
    })
  }

  /* ============================================================
   * UI Builder
   * ============================================================ */

  @Builder
  StatsGridBuilder() {
    Column({ space: 6 }) {
      Text($r('app.string.profile_data_overview_title'))
        .fontSize(CommonConstants.FONT_SIZE_BODY)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_secondary'))
        .padding({ left: 4 })

      Column({ space: 0 }) {
        Row() {
          this.StatItemBuilder(routeVM.goals.length, $r('app.string.stats_goal_total'))
          Divider().vertical(true).height(32).color($r('app.color.divider'))
          this.StatItemBuilder(routeVM.completedGoalCount, $r('app.string.stats_completed_goals'))
          Divider().vertical(true).height(32).color($r('app.color.divider'))
          this.StatItemBuilder(routeVM.overdueGoalCount, $r('app.string.stats_overdue_goals'))
        }
        .width('100%')
        .padding({ top: 16, bottom: 16 })

        Divider().color($r('app.color.divider')).padding({ left: 12, right: 12 })

        Row() {
          this.StatItemBuilder(homeVM.taskList.length, $r('app.string.stats_task_total'))
          Divider().vertical(true).height(32).color($r('app.color.divider'))
          this.StatItemBuilder(this.todayFocusCount, $r('app.string.stats_today_focus'))
          Divider().vertical(true).height(32).color($r('app.color.divider'))
          // 占位保持三列等分
          this.StatItemBuilder(-1, $r('app.string.settings_not_set'))
        }
        .width('100%')
        .padding({ top: 16, bottom: 16 })
      }
      .width('100%')
      .backgroundColor($r('app.color.bg_card'))
      .borderRadius(16)
    }
    .width('100%')
    .margin({ top: 16 })
  }

  @Builder
  StatItemBuilder(value: number, label: ResourceStr) {
    Column({ space: 4 }) {
      Text(value < 0 ? '--' : value.toString())
        .fontSize(CommonConstants.FONT_SIZE_XL)
        .fontWeight(FontWeight.Bold)
        .fontColor(value <= 0 && value !== -1 ? $r('app.color.text_tertiary') : $r('app.color.text_primary'))
      Text(label)
        .fontSize(CommonConstants.FONT_SIZE_SMALL)
        .fontColor($r('app.color.text_tertiary'))
    }
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  AiReviewCardBuilder() {
    Column({ space: 6 }) {
      Text($r('app.string.profile_item_ai_review'))
        .fontSize(CommonConstants.FONT_SIZE_BODY)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_secondary'))
        .padding({ left: 4 })

      Column({ space: 12 }) {
        Text($r('app.string.stats_ai_review_desc'))
          .fontSize(CommonConstants.FONT_SIZE_SMALL)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')

        Button($r('app.string.stats_ai_review_btn'))
          .type(ButtonType.Capsule)
          .width('100%')
          .height(44)
          .fontSize(CommonConstants.FONT_SIZE_MID)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_inverse'))
          .backgroundColor($r('app.color.primary_color'))
          .onClick((): void => {
            this.handleGlobalReview()
          })
      }
      .width('100%')
      .padding(16)
      .backgroundColor($r('app.color.bg_card'))
      .borderRadius(16)
    }
    .width('100%')
    .margin({ top: 16 })
  }

  /**
   * AI 复盘报告全屏弹层（Stack 层叠，替代 bindContentCover）
   */
  @Builder
  ReviewCoverBuilder() {
    Column() {
      Column() {
        Row() {
          Text($r('app.string.stats_ai_review_title'))
            .fontSize(CommonConstants.FONT_SIZE_SUBTITLE)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
          Button($r('app.string.common_close'))
            .type(ButtonType.Capsule)
            .height(32)
            .padding({ left: 16, right: 16 })
            .backgroundColor($r('app.color.bg_tag'))
            .fontColor($r('app.color.text_secondary'))
            .fontSize(CommonConstants.FONT_SIZE_CAPTION)
            .onClick((): void => { this.showReviewSheet = false })
        }
        .width('100%')

        if (this.reviewLoading) {
          Column({ space: 12 }) {
            LoadingProgress()
              .width(40)
              .height(40)
              .color($r('app.color.primary_color'))
            Text($r('app.string.stats_ai_review_loading'))
              .fontSize(CommonConstants.FONT_SIZE_CAPTION)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .margin({ top: 80 })
          .layoutWeight(1)
        } else {
          Scroll() {
            Text(this.reviewText)
              .fontSize(CommonConstants.FONT_SIZE_BODY)
              .fontColor($r('app.color.text_primary'))
              .lineHeight(22)
              .width('100%')
              .copyOption(CopyOptions.LocalDevice)
          }
          .scrollBar(BarState.Off)
          .layoutWeight(1)
          .margin({ top: 12 })
        }
      }
      .width('100%')
      .height('78%')
      .constraintSize({ maxWidth: DimensConstants.CONTENT_MAX_WIDTH })
      .padding(20)
      .backgroundColor($r('app.color.bg_card'))
      .borderRadius({ topLeft: 20, topRight: 20 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.End)
    .backgroundColor($r('app.color.overlay_mask'))
  }

  build() {
    NavDestination() {
      Column() {
        CommonTitleBar({
          title: $r('app.string.page_stats'),
          showBack: true,
          onBack: (): void => {
            this.handleBack()
          }
        })

        Scroll() {
          Column() {
            Column({ space: 16 }) {
              this.StatsGridBuilder()

              this.AiReviewCardBuilder()
            }
            // 宽屏适配：内容列限宽居中
            .constraintSize({ maxWidth: DimensConstants.CONTENT_MAX_WIDTH })
            .width('100%')
            .padding({ left: 16, right: 16, top: 8, bottom: safeAreaHelper.getBottomWith(24) })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
        }
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
        .width('100%')
        .layoutWeight(1)

        if (this.showReviewSheet) {
          this.ReviewCoverBuilder()
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
