/**
 * @file 使用帮助页
 * @description 我的 → 帮助与信息 → 使用帮助
 *   静态图文，说明核心功能的使用方法
 *
 * 跳转来源：ProfilePage 帮助与信息分组
 *
 * @module pages
 */

import { globalNavStack } from '../common/RouterManager'
import { CommonConstants } from '../common/constants/CommonConstants'
import { CommonTitleBar } from '../common/components/CommonTitleBar'
import { safeAreaHelper } from '../common/utils/SafeAreaHelper'

@Entry
@ComponentV2
export struct HelpPage {
  private handleBack(): void {
    globalNavStack.pop()
  }

  @Builder
  HelpItemBuilder(icon: string, title: ResourceStr, desc: ResourceStr) {
    Column({ space: 4 }) {
      Text(icon)
        .fontSize(CommonConstants.FONT_SIZE_XXL)
        .width('100%')
        .textAlign(TextAlign.Start)
      Text(title)
        .fontSize(CommonConstants.FONT_SIZE_MID)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      Text(desc)
        .fontSize(CommonConstants.FONT_SIZE_SMALL)
        .fontColor($r('app.color.text_tertiary'))
        .lineHeight(18)
        .width('100%')
    }
    .width('100%')
    .padding(16)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(16)
  }

  build() {
    NavDestination() {
      Column() {
        CommonTitleBar({
          title: $r('app.string.page_help'),
          showBack: true,
          onBack: (): void => {
            this.handleBack()
          }
        })

        Scroll() {
          Column({ space: 12 }) {
            this.HelpItemBuilder('🤖', $r('app.string.help_ai_title'), $r('app.string.help_ai_desc'))
            this.HelpItemBuilder('🗂', $r('app.string.help_quadrant_title'), $r('app.string.help_quadrant_desc'))
            this.HelpItemBuilder('🍅', $r('app.string.help_pomodoro_title'), $r('app.string.help_pomodoro_desc'))
            this.HelpItemBuilder('☁️', $r('app.string.help_sync_title'), $r('app.string.help_sync_desc'))
            this.HelpItemBuilder('🔒', $r('app.string.help_data_title'), $r('app.string.help_data_desc'))
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
    }
    .hideTitleBar(true)
    .onBackPressed((): boolean => {
      this.handleBack()
      return true
    })
  }
}
