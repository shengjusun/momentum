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
import { breakpointState } from '../common/utils/BreakpointState'
import { CommonConstants } from '../common/constants/CommonConstants'
import { DimensConstants } from '../common/constants/DimensConstants'
import { Logger } from '../common/utils/Logger'
import { AppReportSheet } from '../common/components/AppReportSheet'
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
  /** 页面存活标记：防止页面 pop 后 AI 回调仍写入 @Local 状态 */
  private isAttached: boolean = false

  async aboutToAppear(): Promise<void> {
    this.isAttached = true
    try {
      const stats = await pomodoroService.loadStats()
      this.todayFocusCount = stats.todayFocusCount
    } catch (e) {
      Logger.warn('StatsPage', 'loadStats failed: ' + (e as Error).message)
    }
  }

  aboutToDisappear(): void {
    this.isAttached = false
  }

  private handleBack(): void {
    globalNavStack.pop()
  }

  /**
   * 构造全局复盘数据载荷（目标/任务/专注汇总）。
   *
   * ⚠️ 刻意用**语言中立的 `key=value`** 而不是拼中文句子：
   *   原实现硬编码「目标总数：%d；已完成目标：%d…」，属 i18n 违规
   *   （工程约定"文案一律走 `$r('app.string.*')`"），且英文界面下会把中文串
   *   塞进全局复盘提示词（当时硬编码在 `model/AppConstants.ets`）。
   *   改中立载荷后，本文件不再出现面向用户的中文文案。
   *
   * ✅ 已解决（2026-09-17）：提示词已迁至 `common/constants/AiPrompts.ets`，
   *   中英两套 + 按语言取用（含"分四段""字数上限"等格式指令的本地化），
   *   本载荷保持语言中立，两侧配合即为完整的英文体验。
   */
  private buildGlobalSummary(): string {
    const goalTotal: number = routeVM.liveGoals.length
    const taskTotal: number = homeVM.liveTasks.length
    const completedGoals: number = routeVM.completedGoalCount
    const overdueGoals: number = routeVM.overdueGoalCount
    const focusCount: number = this.todayFocusCount
    return 'goals=' + goalTotal.toString() +
      ';goals_completed=' + completedGoals.toString() +
      ';goals_overdue=' + overdueGoals.toString() +
      ';tasks=' + taskTotal.toString() +
      ';focus_today=' + focusCount.toString()
  }

  /** 是否存在任何可复盘的数据（三项全零即视为无数据） */
  private hasReviewableData(): boolean {
    return routeVM.liveGoals.length > 0 || homeVM.liveTasks.length > 0 || this.todayFocusCount > 0
  }

  private handleGlobalReview(): void {
    // ⚠️ 修复死分支：原实现用 `summary.length === 0` 判空，但 summary 恒定非空
    //   （总是带 label/键名）→ 该分支永远不会命中，`stats_no_data` 提示成了死代码。
    if (!this.hasReviewableData()) {
      promptAction.showToast({
        message: getContext(this).resourceManager.getStringSync($r('app.string.stats_no_data').id),
        duration: 1500
      })
      return
    }
    const summary: string = this.buildGlobalSummary()
    this.showReviewSheet = true
    this.reviewLoading = true
    this.reviewText = ''
    DeepSeekService.getInstance().generateGlobalReview(summary).then((report: string): void => {
      if (!this.isAttached) return
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
          this.StatItemBuilder(routeVM.liveGoals.length, $r('app.string.stats_goal_total'))
          Divider().vertical(true).height(32).color($r('app.color.divider'))
          this.StatItemBuilder(routeVM.completedGoalCount, $r('app.string.stats_completed_goals'))
          Divider().vertical(true).height(32).color($r('app.color.divider'))
          this.StatItemBuilder(routeVM.overdueGoalCount, $r('app.string.stats_overdue_goals'))
        }
        .width('100%')
        .padding({ top: 16, bottom: 16 })

        Divider().color($r('app.color.divider')).padding({ left: 12, right: 12 })

        Row() {
          this.StatItemBuilder(homeVM.liveTasks.length, $r('app.string.stats_task_total'))
          Divider().vertical(true).height(32).color($r('app.color.divider'))
          this.StatItemBuilder(this.todayFocusCount, $r('app.string.stats_today_focus'))
          Divider().vertical(true).height(32).color($r('app.color.divider'))
          // 已完成任务数（原为"-- 未设置"死占位格，改真实指标）
          this.StatItemBuilder(homeVM.completedTaskCount, $r('app.string.stats_completed_tasks'))
        }
        .width('100%')
        .padding({ top: 16, bottom: 16 })
      }
      .width('100%')
      .backgroundColor($r('app.color.bg_card'))
      .borderRadius(DimensConstants.RADIUS_L)
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
      .borderRadius(DimensConstants.RADIUS_L)
    }
    .width('100%')
    .margin({ top: 16 })
  }

  /**
   * AI 复盘报告全屏弹层（Stack 层叠，替代 bindContentCover）
   */
  @Builder
  ReviewCoverBuilder() {
    AppReportSheet({
    title: getContext(this).resourceManager.getStringSync($r('app.string.stats_ai_review_title').id),
    loading: this.reviewLoading,
    text: this.reviewText,
    loadingText: getContext(this).resourceManager.getStringSync($r('app.string.stats_ai_review_loading').id),
    onClose: (): void => {
      this.showReviewSheet = false
    }
    })
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
            // 宽屏适配：内容列限宽居中（平板 lg 放宽到 860，与"我的"页同一分档）
            .constraintSize({
              maxWidth: breakpointState.isTablet
                ? DimensConstants.CONTENT_MAX_WIDTH_TABLET
                : DimensConstants.CONTENT_MAX_WIDTH
            })
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
