// 隐私协议同意弹层：首次启动（未同意隐私协议）时覆盖在主界面之上，同意前阻断一切交互
// - 同意 → MainTab 注入的 onAgree：持久化同意状态 + 拉起云端 SDK 初始化链
// - 不同意 → MainTab 注入的 onDisagree：退出应用（合规要求：未同意不得使用）
// 显示条件（MainTab 控制）：settingsVM.isLoaded && !settingsVM.settings.privacyAgreed
//   isLoaded 门控避免已同意的老用户在冷启动加载期间看到弹层闪现

import { CommonConstants } from '../constants/CommonConstants'
import { DimensConstants } from '../constants/DimensConstants'

@ComponentV2
export struct PrivacyConsentOverlay {
  /** 点击"同意并继续"回调 */
  @Param onAgree: () => void = (): void => {}
  /** 点击"不同意并退出"回调 */
  @Param onDisagree: () => void = (): void => {}

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 16 }) {
        // 标题
        Text($r('app.string.privacy_agree_title'))
          .fontSize(CommonConstants.FONT_SIZE_XXL)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .textAlign(TextAlign.Center)

        // 协议正文（可滚动，小屏不至于撑爆卡片）
        Scroll() {
          Column() {
            Text($r('app.string.privacy_content'))
              .fontSize(CommonConstants.FONT_SIZE_BODY)
              .fontColor($r('app.color.text_secondary'))
              .lineHeight(22)
              .width('100%')
          }
          .width('100%')
        }
        .constraintSize({ maxHeight: '42%' })
        .scrollable(ScrollDirection.Vertical)
        .edgeEffect(EdgeEffect.Fade)
        .width('100%')

        // 提示行
        Text($r('app.string.privacy_gate_notice'))
          .fontSize(CommonConstants.FONT_SIZE_CAPTION)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')

        // 同意按钮
        Button($r('app.string.privacy_gate_agree'))
          .fontSize(CommonConstants.FONT_SIZE_MID)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_inverse'))
          .backgroundColor($r('app.color.primary_color'))
          .borderRadius(DimensConstants.RADIUS_XL)
          .width('100%')
          .height(48)
          .margin({ top: 8 })
          .onClick((): void => {
            this.onAgree()
          })

        // 不同意（退出应用）
        Text($r('app.string.privacy_gate_disagree'))
          .fontSize(CommonConstants.FONT_SIZE_CAPTION)
          .fontColor($r('app.color.text_secondary'))
          .padding({ top: 4, bottom: 4, left: 16, right: 16 })
          .onClick((): void => {
            this.onDisagree()
          })
      }
      .width('86%')
      .padding(24)
      .borderRadius(DimensConstants.RADIUS_XL)
      .backgroundColor($r('app.color.bg_card'))
      .shadow({
        radius: 32,
        color: $r('app.color.shadow_dialog'),
        offsetX: 0,
        offsetY: 12
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.overlay_mask'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    // 触摸模式说明：不能用 HitTestMode.Block——Block 会阻止子节点参与触摸测试，
    // 导致卡片内按钮全部失灵。用默认模式即可：全屏背景自身消费触摸，
    // Stack 下层的 Tabs/导航栏兄弟节点收不到事件，子节点（卡片）正常响应。
  }
}
