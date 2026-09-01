/**
 * @file 问题反馈页
 * @description 我的 → 帮助与信息 → 问题反馈
 *   - 文本反馈：本地保存 + 成功提示（当前无后端，先落地本地记录）
 *   - 复制诊断信息：应用版本 / 设备信息 / 数据规模 复制到剪贴板，供用户粘贴提交
 *
 * 跳转来源：ProfilePage 帮助与信息分组
 *
 * @module pages
 */

import { promptAction } from '@kit.ArkUI'
import { CommonConstants } from '../common/constants/CommonConstants'
import { pasteboard } from '@kit.BasicServicesKit'
import { bundleManager } from '@kit.AbilityKit'
import { Logger } from '../common/utils/Logger'
import { settingsVM } from '../viewmodel/SettingsViewModel'
import { routeVM } from '../viewmodel/RoutePageViewModel'
import { homeVM } from '../viewmodel/HomeViewModel'
import { globalNavStack } from '../common/RouterManager'
import { CommonTitleBar } from '../common/components/CommonTitleBar'
import { safeAreaHelper } from '../common/utils/SafeAreaHelper'
import { StorageManager } from '../common/utils/StorageManager'

/** 本地反馈记录（Preferences 存储） */
interface FeedbackRecord {
  content: string
  createdAt: number
}

@Entry
@ComponentV2
export struct FeedbackPage {
  @Local content: string = ''
  @Local isSubmitting: boolean = false

  private static readonly STORAGE_KEY: string = 'feedback_records'

  private handleBack(): void {
    globalNavStack.pop()
  }

  private handleSubmit(): void {
    const text: string = this.content.trim()
    if (text.length === 0) {
      promptAction.showToast({
        message: getContext(this).resourceManager.getStringSync($r('app.string.feedback_empty').id),
        duration: 1500
      })
      return
    }
    if (this.isSubmitting) return
    this.isSubmitting = true
    try {
      const record: FeedbackRecord = {
        content: text,
        createdAt: Date.now()
      }
      this.appendRecord(record).then((): void => {
        this.content = ''
        this.isSubmitting = false
        promptAction.showToast({
          message: getContext(this).resourceManager.getStringSync($r('app.string.feedback_submit_success').id),
          duration: 1500
        })
      }).catch((e: Error): void => {
        Logger.error('FeedbackPage', 'submit failed: ' + e.message)
        this.isSubmitting = false
        promptAction.showToast({
          message: getContext(this).resourceManager.getStringSync($r('app.string.toast_save_failed').id),
          duration: 1500
        })
      })
    } catch (e) {
      Logger.error('FeedbackPage', 'submit error: ' + (e as Error).message)
      this.isSubmitting = false
    }
  }

  private async appendRecord(record: FeedbackRecord): Promise<void> {
    const ctx = getContext(this)
    const existing: FeedbackRecord[] = await StorageManager.loadData<FeedbackRecord[]>(ctx, FeedbackPage.STORAGE_KEY, []) ?? []
    existing.push(record)
    await StorageManager.saveData(ctx, FeedbackPage.STORAGE_KEY, existing as object)
  }

  private async handleCopyDiagnostics(): Promise<void> {
    try {
      const bundleInfo = await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)
      const info: string =
        '【Momentum 诊断信息】\n' +
        '版本：' + bundleInfo.versionName + '\n' +
        '目标数：' + routeVM.goals.length.toString() + '\n' +
        '待办数：' + homeVM.taskList.length.toString() + '\n' +
        '登录态：' + (settingsVM.userProfile.isLoggedIn ? '已登录' : '未登录') + '\n' +
        '云同步：' + (settingsVM.settings.syncEnabled ? '开' : '关')
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, info)
      await pasteboard.getSystemPasteboard().setData(data)
      promptAction.showToast({
        message: getContext(this).resourceManager.getStringSync($r('app.string.feedback_copied').id),
        duration: 1500
      })
    } catch (e) {
      Logger.error('FeedbackPage', 'copy diagnostics error: ' + (e as Error).message)
    }
  }

  build() {
    NavDestination() {
      Column() {
        CommonTitleBar({
          title: $r('app.string.page_feedback'),
          showBack: true,
          onBack: (): void => {
            this.handleBack()
          }
        })

        Scroll() {
          Column({ space: 16 }) {
            // 反馈输入卡片
            Column({ space: 12 }) {
              TextArea({ placeholder: getContext(this).resourceManager.getStringSync($r('app.string.feedback_input_placeholder').id) })
                .fontSize(CommonConstants.FONT_SIZE_BODY)
                .fontColor($r('app.color.text_primary'))
                .placeholderColor($r('app.color.text_tertiary'))
                .height(160)
                .borderRadius(12)
                .backgroundColor($r('app.color.bg_tag'))
                .padding(12)
                .onChange((value: string): void => {
                  this.content = value
                })

              Button(this.isSubmitting ?
                getContext(this).resourceManager.getStringSync($r('app.string.btn_syncing').id) :
                $r('app.string.feedback_submit'))
                .type(ButtonType.Capsule)
                .width('100%')
                .height(44)
                .fontSize(CommonConstants.FONT_SIZE_MID)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_inverse'))
                .backgroundColor($r('app.color.primary_color'))
                .onClick((): void => {
                  this.handleSubmit()
                })
            }
            .width('100%')
            .padding(16)
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(16)
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
                .borderRadius(12)
                .backgroundColor($r('app.color.primary_color_bg'))
                .onClick((): void => {
                  this.handleCopyDiagnostics()
                })
            }
            .width('100%')
            .padding(16)
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(16)
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
    .onBackPressed((): boolean => {
      this.handleBack()
      return true
    })
  }
}
