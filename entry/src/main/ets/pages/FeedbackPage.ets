/**
 * @file 问题反馈页
 * @description 我的 → 帮助与信息 → 问题反馈
 *   - 文本反馈：组装运行诊断信息后写入 AGC 云数据库对象类型 UserFeedback（需已登录）
 *   - 提交失败（无网/服务异常）自动落入本地暂存队列，联网后自动补传，不丢用户输入
 *   - 复制诊断信息：便于用户在其他渠道（邮件/社群）提交问题
 *
 * 跳转来源：ProfilePage 帮助与信息分组
 *
 * @module pages
 */

import { promptAction } from '@kit.ArkUI'
import { DimensConstants } from '../common/constants/DimensConstants'
import { pasteboard } from '@kit.BasicServicesKit'
import { bundleManager } from '@kit.AbilityKit'
import { CommonConstants } from '../common/constants/CommonConstants'
import { Logger } from '../common/utils/Logger'
import { settingsVM } from '../viewmodel/SettingsViewModel'
import { routeVM } from '../viewmodel/RoutePageViewModel'
import { homeVM } from '../viewmodel/HomeViewModel'
import { globalNavStack } from '../common/RouterManager'
import { CommonTitleBar } from '../common/components/CommonTitleBar'
import { safeAreaHelper } from '../common/utils/SafeAreaHelper'
import {
  FeedbackService,
  FeedbackSubmitInput,
  FeedbackSubmitResult,
  FeedbackDiagnostics
} from '../common/services/FeedbackService'
import { FeedbackRouteNavParam } from '../model/Models'

/** 反馈分类选项（value 落库，label 展示） */
class FeedbackCategoryItem {
  value: string
  label: Resource

  constructor(value: string, label: Resource) {
    this.value = value
    this.label = label
  }
}

const CATEGORY_ITEMS: FeedbackCategoryItem[] = [
  new FeedbackCategoryItem('bug', $r('app.string.feedback_category_bug')),
  new FeedbackCategoryItem('suggestion', $r('app.string.feedback_category_suggestion')),
  new FeedbackCategoryItem('other', $r('app.string.feedback_category_other'))
]

/** 举报模式的类型选项（合规要求：AIGC 应用需提供便捷举报入口） */
const REPORT_CATEGORY_ITEMS: FeedbackCategoryItem[] = [
  new FeedbackCategoryItem('inappropriate', $r('app.string.report_category_inappropriate')),
  new FeedbackCategoryItem('infringement', $r('app.string.report_category_infringement')),
  new FeedbackCategoryItem('misinformation', $r('app.string.report_category_misinformation')),
  new FeedbackCategoryItem('other', $r('app.string.feedback_category_other'))
]

/** 反馈正文输入上限（云端 Text 类型本身支持超长，此处仅做交互约束） */
const CONTENT_MAX_LENGTH: number = 1000

@Entry
@ComponentV2
export struct FeedbackPage {
  @Local content: string = ''
  @Local category: string = 'bug'
  @Local contact: string = ''
  @Local isSubmitting: boolean = false
  /** 'feedback' 普通问题反馈 | 'report' AI 生成内容举报 */
  @Local mode: string = 'feedback'

  /** 是否举报模式 */
  private isReport(): boolean {
    return this.mode === 'report'
  }

  /** 当前模式下的类型选项 */
  private getCategoryItems(): FeedbackCategoryItem[] {
    return this.isReport() ? REPORT_CATEGORY_ITEMS : CATEGORY_ITEMS
  }

  aboutToAppear(): void {
    // 进入页面尝试补传历史暂存反馈（后台行为，不打扰用户）
    FeedbackService.getInstance().flushQueue().catch((e: Error): void => {
      Logger.warn('FeedbackPage', 'flush feedback queue failed: ' + e.message)
    })
  }

  /** 解析路由参数：mode='report' 时切换为举报模式（默认普通反馈） */
  private onDestinationReady(context: NavDestinationContext): void {
    const rawParam: Object = context.pathInfo.param as Object
    if (rawParam === null || rawParam === undefined) {
      return
    }
    const navParam: FeedbackRouteNavParam = rawParam as FeedbackRouteNavParam
    if (navParam.mode === 'report') {
      this.mode = 'report'
      this.category = 'inappropriate'
    }
  }

  private handleBack(): void {
    globalNavStack.pop()
  }

  private handleSubmit(): void {
    const text: string = this.content.trim()
    if (text.length === 0) {
      promptAction.showToast({ message: $r('app.string.feedback_empty'), duration: 1500 })
      return
    }
    if (this.isSubmitting) {
      return
    }
    this.isSubmitting = true

    const diagnostics: FeedbackDiagnostics = {
      goalsCount: routeVM.liveGoals.length,
      todosCount: homeVM.liveTasks.length,
      syncEnabled: settingsVM.settings.syncEnabled
    }
    const input: FeedbackSubmitInput = {
      content: text,
      // 举报模式加前缀，便于在云端按类型区分筛选：report_xxx
      category: this.isReport() ? 'report_' + this.category : this.category,
      contact: this.contact.trim(),
      userId: settingsVM.userProfile.huaweiUid,
      isLoggedIn: settingsVM.userProfile.isLoggedIn,
      diagnostics: diagnostics
    }

    FeedbackService.getInstance().submit(input)
      .then((result: FeedbackSubmitResult): void => {
        this.isSubmitting = false
        if (result.success) {
          this.content = ''
          this.contact = ''
          promptAction.showToast({
            message: this.isReport()
              ? $r('app.string.report_submit_success')
              : $r('app.string.feedback_submit_success'),
            duration: 1500
          })
        } else if (result.needLogin) {
          promptAction.showToast({
            message: $r('app.string.feedback_login_required'), duration: 2000
          })
        } else if (result.queued) {
          promptAction.showToast({
            message: $r('app.string.feedback_queued_offline'), duration: 2000
          })
        } else {
          promptAction.showToast({
            message: $r('app.string.feedback_submit_failed'), duration: 2000
          })
        }
      })
      .catch((e: Error): void => {
        this.isSubmitting = false
        Logger.error('FeedbackPage', 'submit failed: ' + e.message)
        promptAction.showToast({
          message: $r('app.string.feedback_submit_failed'), duration: 2000
        })
      })
  }

  private async handleCopyDiagnostics(): Promise<void> {
    try {
      const bundleInfo = await bundleManager.getBundleInfoForSelf(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)
      const info: string =
        '【跬步 诊断信息】\n' +
        '版本：' + bundleInfo.versionName + '\n' +
        '目标数：' + routeVM.liveGoals.length.toString() + '\n' +
        '待办数：' + homeVM.liveTasks.length.toString() + '\n' +
        '登录态：' + (settingsVM.userProfile.isLoggedIn ? '已登录' : '未登录') + '\n' +
        '云同步：' + (settingsVM.settings.syncEnabled ? '开' : '关')
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, info)
      await pasteboard.getSystemPasteboard().setData(data)
      promptAction.showToast({
        message: $r('app.string.feedback_copied'), duration: 1500
      })
    } catch (e) {
      Logger.error('FeedbackPage', 'copy diagnostics error: ' + (e as Error).message)
    }
  }

  @Builder
  CategoryChips() {
    Row({ space: 8 }) {
      ForEach(this.getCategoryItems(), (item: FeedbackCategoryItem): void => {
        Text(item.label)
          .fontSize(CommonConstants.FONT_SIZE_CAPTION)
          .fontColor(this.category === item.value
            ? $r('app.color.text_brand')
            : $r('app.color.text_secondary'))
          .backgroundColor(this.category === item.value
            ? $r('app.color.primary_color_bg')
            : $r('app.color.bg_tag'))
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .borderRadius(DimensConstants.RADIUS_M)
          .onClick((): void => {
            this.category = item.value
          })
      }, (item: FeedbackCategoryItem): string => item.value)
    }
    .width('100%')
  }

  build() {
    NavDestination() {
      Column() {
        CommonTitleBar({
          title: this.isReport() ? $r('app.string.page_report') : $r('app.string.page_feedback'),
          showBack: true,
          onBack: (): void => {
            this.handleBack()
          }
        })

        Scroll() {
          Column({ space: 16 }) {
            // 反馈输入卡片
            Column({ space: 12 }) {
              Text(this.isReport()
                ? $r('app.string.report_category_label')
                : $r('app.string.feedback_category_label'))
                .fontSize(CommonConstants.FONT_SIZE_CAPTION)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')

              this.CategoryChips()

              TextArea({
                placeholder: getContext(this).resourceManager.getStringSync(
                  this.isReport()
                    ? $r('app.string.report_input_placeholder').id
                    : $r('app.string.feedback_input_placeholder').id),
                text: this.content
              })
                .fontSize(CommonConstants.FONT_SIZE_BODY)
                .fontColor($r('app.color.text_primary'))
                .placeholderColor($r('app.color.text_tertiary'))
                .height(160)
                .maxLength(CONTENT_MAX_LENGTH)
                .borderRadius(DimensConstants.RADIUS_M)
                .backgroundColor($r('app.color.bg_tag'))
                .padding(12)
                .onChange((value: string): void => {
                  this.content = value
                })

              TextInput({
                placeholder: getContext(this).resourceManager
                  .getStringSync($r('app.string.feedback_contact_placeholder').id),
                text: this.contact
              })
                .fontSize(CommonConstants.FONT_SIZE_BODY)
                .fontColor($r('app.color.text_primary'))
                .placeholderColor($r('app.color.text_tertiary'))
                .maxLength(100)
                .height(44)
                .borderRadius(DimensConstants.RADIUS_M)
                .backgroundColor($r('app.color.bg_tag'))
                .padding({ left: 12, right: 12 })
                .onChange((value: string): void => {
                  this.contact = value
                })

              Button(this.isSubmitting
                ? $r('app.string.loading')
                : (this.isReport() ? $r('app.string.report_submit') : $r('app.string.feedback_submit')))
                .type(ButtonType.Capsule)
                .width('100%')
                .height(44)
                .fontSize(CommonConstants.FONT_SIZE_MID)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_inverse'))
                .backgroundColor($r('app.color.primary_color'))
                .enabled(!this.isSubmitting)
                .onClick((): void => {
                  this.handleSubmit()
                })
            }
            .width('100%')
            .padding(16)
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(DimensConstants.RADIUS_M)
            .margin({ top: 16 })

            // 复制诊断信息
            Column({ space: 8 }) {
              Text($r('app.string.feedback_copy_diag'))
                .fontSize(CommonConstants.FONT_SIZE_BODY)
                .fontColor($r('app.color.primary_color'))
                .fontWeight(FontWeight.Medium)
                .textAlign(TextAlign.Center)
                .width('100%')
                .padding({ top: 12, bottom: 12 })
                .borderRadius(DimensConstants.RADIUS_M)
                .backgroundColor($r('app.color.primary_color_bg'))
                .onClick((): void => {
                  this.handleCopyDiagnostics()
                })
            }
            .width('100%')
            .padding(16)
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(DimensConstants.RADIUS_L)
          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: safeAreaHelper.getBottomWith(24) })
        }
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
        .width('100%')
        .layoutWeight(1)
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))
    }
    .hideTitleBar(true)
    .onReady((context: NavDestinationContext): void => {
      this.onDestinationReady(context)
    })
    .onBackPressed((): boolean => {
      this.handleBack()
      return true
    })
  }
}
