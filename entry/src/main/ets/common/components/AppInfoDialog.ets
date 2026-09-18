/**
 * AppInfoDialog - 统一的居中长文本信息弹窗（隐私协议/用户协议等长内容展示）
 *
 * 设计规范：
 *   - 遮罩淡入 + 卡片缩放入场；标题 + 分隔线 + 可滚动正文 + 主色关闭按钮
 *   - 正文最大高度钳制，超长内容内部滚动
 *   - 深浅色全部走资源引用
 */
import { CommonConstants } from '../constants/CommonConstants'
import { DimensConstants } from '../constants/DimensConstants'
import { safeAreaHelper } from '../utils/SafeAreaHelper'
import { MotionConstants } from '../constants/MotionConstants'

@ComponentV2
export struct AppInfoDialog {
  @Param title: string = ''
  /** 正文（纯文本，内部滚动） */
  @Param message: string = ''
  /** 关闭按钮文案（空串时使用"关闭"） */
  @Param closeText: string = ''
  @Event onClose: () => void = () => {}

  @Local entered: boolean = false

  aboutToAppear(): void {
    setTimeout((): void => {
      this.entered = true
    }, 16)
  }

  build() {
    Column() {
      // 遮罩层：点击关闭
      Column() {}
        .width('100%')
        .layoutWeight(1)
        .backgroundColor($r('app.color.overlay_mask'))
        .opacity(this.entered ? 1 : 0)
        .animation(MotionConstants.enterParam())
        .onClick((): void => {
          this.onClose()
        })

      // 内容卡片
      Column({ space: 12 }) {
        Text(this.title)
          .fontSize(CommonConstants.FONT_SIZE_SUBTITLE)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .textAlign(TextAlign.Center)

        Divider()
          .color($r('app.color.divider'))

        Scroll() {
          Text(this.message)
            .fontSize(CommonConstants.FONT_SIZE_SMALL)
            .fontColor($r('app.color.text_secondary'))
            .lineHeight(22)
            .width('100%')
        }
        .scrollBar(BarState.Auto)
        .constraintSize({ maxHeight: 420 })
        .width('100%')
        .layoutWeight(1)

        Button(this.closeText.length > 0 ? this.closeText : $r('app.string.btn_close'))
          .type(ButtonType.Capsule)
          .height(44)
          .width('100%')
          .backgroundColor($r('app.color.primary_color'))
          .fontColor($r('app.color.text_inverse'))
          .fontSize(CommonConstants.FONT_SIZE_BODY)
          .fontWeight(FontWeight.Medium)
          .onClick((): void => {
            this.onClose()
          })

        Row().height(safeAreaHelper.getBottomWith(0))
      }
      .width('85%')
      .padding(20)
      .backgroundColor($r('app.color.bg_card'))
      .borderRadius(DimensConstants.RADIUS_L)
      .constraintSize({ maxHeight: '80%' })
      .scale({ x: this.entered ? 1 : 0.92, y: this.entered ? 1 : 0.92 })
      .opacity(this.entered ? 1 : 0)
      .animation(MotionConstants.enterParam())
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}
