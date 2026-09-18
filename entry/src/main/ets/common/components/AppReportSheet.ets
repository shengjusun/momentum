/**
 * AppReportSheet - 统一的 AI 报告底部弹层（复盘报告/排序建议共用）
 *
 * 设计规范：
 *   - 底部上滑入场（250ms）+ 遮罩淡入；顶部圆角 RADIUS_XL + 拖拽条
 *   - 三态：加载中（LoadingProgress + 文案）/ 报告文本（可滚动）/ 空文本不显示
 *   - 深浅色全部走资源引用
 *
 * 用法（页面 Stack 内条件渲染）：
 *   if (this.showReviewSheet) {
 *     AppReportSheet({
 *       title: ..., loading: this.reviewLoading, text: this.reviewText,
 *       loadingText: ..., onClose: (): void => { this.showReviewSheet = false }
 *     })
 *   }
 */
import { CommonConstants } from '../constants/CommonConstants'
import { DimensConstants } from '../constants/DimensConstants'
import { safeAreaHelper } from '../utils/SafeAreaHelper'
import { MotionConstants } from '../constants/MotionConstants'

@ComponentV2
export struct AppReportSheet {
  @Param title: string = ''
  @Param loading: boolean = false
  @Param text: string = ''
  @Param loadingText: string = ''
  @Event onClose: () => void = () => {}

  @Local entered: boolean = false

  aboutToAppear(): void {
    setTimeout((): void => {
      this.entered = true
    }, 16)
  }

  build() {
    Column() {
      // 遮罩层：加载中不允许点击关闭（防误触丢报告），完成后可点
      Column() {}
        .width('100%')
        .layoutWeight(1)
        .backgroundColor($r('app.color.overlay_mask'))
        .opacity(this.entered ? 1 : 0)
        .animation(MotionConstants.enterParam())
        .onClick((): void => {
          if (!this.loading) {
            this.onClose()
          }
        })

      // 底部面板
      Column() {
        Row()
          .width(36)
          .height(4)
          .borderRadius(2)
          .backgroundColor($r('app.color.divider'))
          .margin({ top: 10, bottom: 6 })

        Text(this.title)
          .fontSize(CommonConstants.FONT_SIZE_SUBTITLE)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 4, bottom: 10 })

        if (this.loading) {
          Column({ space: 12 }) {
            LoadingProgress()
              .width(32)
              .height(32)
              .color($r('app.color.primary_color'))
            Text(this.loadingText.length > 0 ? this.loadingText : $r('app.string.state_loading'))
              .fontSize(CommonConstants.FONT_SIZE_SMALL)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .height(200)
          .justifyContent(FlexAlign.Center)
        } else {
          Scroll() {
            Text(this.text)
              .fontSize(CommonConstants.FONT_SIZE_BODY)
              .fontColor($r('app.color.text_primary'))
              .lineHeight(24)
              .copyOption(CopyOptions.LocalDevice)
              .width('100%')
          }
          .scrollBar(BarState.Auto)
          .edgeEffect(EdgeEffect.Spring)
          .width('100%')
          .layoutWeight(1)
          .padding({ left: 4, right: 4 })
        }

        Button($r('app.string.common_cancel'))
          .type(ButtonType.Capsule)
          .height(44)
          .width('100%')
          .margin({ top: 12 })
          .backgroundColor($r('app.color.bg_tag'))
          .fontColor($r('app.color.text_secondary'))
          .fontSize(CommonConstants.FONT_SIZE_BODY)
          .enabled(!this.loading)
          .onClick((): void => {
            this.onClose()
          })

        Row().height(safeAreaHelper.getBottomWith(8))
      }
      .width('100%')
      .height('78%')
      .padding({ left: 20, right: 20, top: 4, bottom: 12 })
      .backgroundColor($r('app.color.bg_card'))
      .borderRadius({ topLeft: DimensConstants.RADIUS_XL, topRight: DimensConstants.RADIUS_XL })
      .translate({ y: this.entered ? 0 : 500 })
      .animation(MotionConstants.panelParam())
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
  }
}
