import { CommonConstants } from '../../common/constants/CommonConstants'
/**
 * @file 统一三态视图组件（Loading / Error / Empty）
 * @description
 *   - Loading 态：居中加载动画 + 可选文案
 *   - Error 态：错误图标 + 错误文案 + 重试按钮
 *   - Empty 态：空态插画 + 提示文案 + 可选 CTA 按钮
 *
 * API 设计：
 *   StateView({ mode: StateMode.LOADING })
 *   StateView({ mode: StateMode.ERROR, errorMessage: '加载失败', onRetry: () => { ... } })
 *   StateView({ mode: StateMode.EMPTY, emptyMessage: '暂无数据', ctaText: '去创建', onCta: () => { ... } })
 *
 * @module common/components
 * @date 2026-07-25
 */

/**
 * 状态模式枚举
 */
export enum StateMode {
  LOADING = 'loading',
  ERROR = 'error',
  EMPTY = 'empty'
}

@ComponentV2
export struct StateView {
  /** 当前状态模式 */
  @Param mode: StateMode = StateMode.LOADING
  /** 加载态辅助文案 */
  @Param loadingText: ResourceStr = $r('app.string.state_loading')
  /** 错误信息 */
  @Param errorMessage: ResourceStr = $r('app.string.state_error_desc')
  /** 空态提示文案 */
  @Param emptyMessage: ResourceStr = $r('app.string.state_empty_title')
  /** 空态 CTA 按钮文案（为空时不显示按钮） */
  @Param ctaText: ResourceStr = ''
  /** 重试回调（Error 态） */
  @Event onRetry: () => void = (): void => {}
  /** 空态 CTA 回调 */
  @Event onCta: () => void = (): void => {}

  build() {
    Column() {
      if (this.mode === StateMode.LOADING) {
        // ========== Loading 态 ==========
        Column({ space: 12 }) {
          LoadingProgress()
            .width(40)
            .height(40)
            .color($r('app.color.primary_color'))

          Text(this.loadingText)
            .fontSize(CommonConstants.FONT_SIZE_BODY)
            .fontColor($r('app.color.text_secondary'))
        }
      } else if (this.mode === StateMode.ERROR) {
        // ========== Error 态 ==========
        Column({ space: 16 }) {
          // 错误态插画
          Image($r('app.media.error_state_illustration'))
            .width(120)
            .height(120)
            .objectFit(ImageFit.Contain)

          Text(this.errorMessage)
            .fontSize(CommonConstants.FONT_SIZE_BODY)
            .fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)
            .maxLines(3)
            .padding({ left: 32, right: 32 })

          Button($r('app.string.state_retry'))
            .type(ButtonType.Capsule)
            .height(40)
            .padding({ left: 24, right: 24 })
            .backgroundColor($r('app.color.primary_color'))
            .fontColor($r('app.color.text_inverse'))
            .fontSize(CommonConstants.FONT_SIZE_BODY)
            .fontWeight(FontWeight.Medium)
            .accessibilityText($r('app.string.state_retry'))
            .onClick((): void => { this.onRetry() })
        }
      } else {
        // ========== Empty 态 ==========
        Column({ space: 16 }) {
          // 空态插画
          Image($r('app.media.empty_state_illustration'))
            .width(120)
            .height(120)
            .objectFit(ImageFit.Contain)

          Column({ space: 6 }) {
            Text(this.emptyMessage)
              .fontSize(CommonConstants.FONT_SIZE_MID)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .textAlign(TextAlign.Center)
          }
          .padding({ left: 32, right: 32 })

          // CTA 按钮（可选）
          if (this.ctaText.toString().length > 0) {
            Button({ type: ButtonType.Capsule }) {
              Text(this.ctaText)
                .fontColor($r('app.color.text_inverse'))
                .fontSize(CommonConstants.FONT_SIZE_BODY)
                .fontWeight(FontWeight.Medium)
            }
              .height(42)
              .padding({ left: 28, right: 28 })
              .backgroundColor($r('app.color.primary_color'))
              .onClick((): void => { this.onCta() })
              .margin({ top: 4 })
          }
        }
      }
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 16, right: 16 })
  }
}
