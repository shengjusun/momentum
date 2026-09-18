/**
 * @file 关于 起势 页
 * @description 我的 → 帮助与信息 → 关于 起势
 *   版本信息 + 隐私协议 + 版权声明
 *
 * 跳转来源：ProfilePage 帮助与信息分组
 *
 * @module pages
 */


import { DimensConstants } from '../common/constants/DimensConstants'
import { CommonConstants } from '../common/constants/CommonConstants'
import { bundleManager } from '@kit.AbilityKit'
import { globalNavStack } from '../common/RouterManager'
import { CommonTitleBar } from '../common/components/CommonTitleBar'
import { AppInfoDialog } from '../common/components/AppInfoDialog'
import { safeAreaHelper } from '../common/utils/SafeAreaHelper'

@Entry
@ComponentV2
export struct AboutPage {
  @Local appVersion: string = ''
  /** 隐私协议长文弹窗 */
  @Local showPrivacyDialogVisible: boolean = false

  async aboutToAppear(): Promise<void> {
    try {
      const bundleInfo = await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)
      this.appVersion = bundleInfo.versionName
    } catch (e) {
      this.appVersion = '1.0.0'
    }
  }

  private handleBack(): void {
    globalNavStack.pop()
  }
  private showPrivacyDialog(): void {
    // 统一 AppInfoDialog：隐私长文可滚动阅读（替代系统 showDialog）
    this.showPrivacyDialogVisible = true
  }

  build() {
    NavDestination() {
      Stack() {
      Column() {
        CommonTitleBar({
          title: $r('app.string.page_about'),
          showBack: true,
          onBack: (): void => {
            this.handleBack()
          }
        })

        Scroll() {
          Column({ space: 16 }) {
            // Logo + 应用名
            Column({ space: 10 }) {
              Image($r('app.media.app_icon'))
                .width(72)
                .height(72)
                .borderRadius(18)
                .objectFit(ImageFit.Cover)
                .accessibilityText(getContext(this).resourceManager.getStringSync($r('app.string.app_name').id))
              Text($r('app.string.app_name'))
                .fontSize(CommonConstants.FONT_SIZE_HEADLINE)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.text_primary'))
              Text($r('app.string.about_built_with'))
                .fontSize(CommonConstants.FONT_SIZE_SMALL)
                .fontColor($r('app.color.text_tertiary'))
              Text($r('app.string.about_copyright'))
                .fontSize(CommonConstants.FONT_SIZE_XS)
                .fontColor($r('app.color.text_tertiary'))
            }
            .width('100%')
            .padding({ top: 40, bottom: 24 })
            .alignItems(HorizontalAlign.Center)

            // 信息列表
            Column({ space: 0 }) {
              Row({ space: 12 }) {
                Text($r('app.string.settings_version'))
                  .fontSize(CommonConstants.FONT_SIZE_BODY)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1)
                Text(this.appVersion.length > 0 ? this.appVersion : $r('app.string.settings_not_set'))
                  .fontSize(CommonConstants.FONT_SIZE_BODY)
                  .fontColor($r('app.color.text_tertiary'))
              }
              .width('100%')
              .height(52)
              .padding({ left: 16, right: 16 })
              .alignItems(VerticalAlign.Center)

              Divider().color($r('app.color.divider')).padding({ left: 12, right: 12 })

              Row({ space: 12 }) {
                Text($r('app.string.settings_privacy'))
                  .fontSize(CommonConstants.FONT_SIZE_BODY)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1)
                SymbolGlyph($r('sys.symbol.chevron_right'))
                  .fontSize(CommonConstants.FONT_SIZE_SUBTITLE)
                  .fontColor([$r('app.color.text_tertiary')])
              }
              .width('100%')
              .constraintSize({ minHeight: 52 })
              .padding({ left: 16, right: 16 })
              .alignItems(VerticalAlign.Center)
              .stateStyles({
                pressed: { .backgroundColor($r('app.color.bg_tag')) },
                normal: { .backgroundColor(Color.Transparent) }
              })
              .onClick((): void => {
                this.showPrivacyDialog()
              })
            }
            .width('100%')
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(DimensConstants.RADIUS_L)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: safeAreaHelper.getBottomWith(24) })
        }
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
        .width('100%')
        .layoutWeight(1)
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))

      // 隐私协议长文弹窗（统一 AppInfoDialog）
      if (this.showPrivacyDialogVisible) {
        AppInfoDialog({
          title: getContext(this).resourceManager.getStringSync($r('app.string.privacy_agree_title').id),
          message: getContext(this).resourceManager.getStringSync($r('app.string.privacy_content').id),
          closeText: getContext(this).resourceManager.getStringSync($r('app.string.btn_close').id),
          onClose: (): void => {
            this.showPrivacyDialogVisible = false
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
  }
}
