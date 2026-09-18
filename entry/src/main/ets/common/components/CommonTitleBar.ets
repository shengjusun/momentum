import { safeAreaHelper } from '../utils/SafeAreaHelper'
import { CommonConstants } from '../constants/CommonConstants'

@ComponentV2
@ReusableV2
export struct CommonTitleBar {
  @Param title: ResourceStr = ''
  @Param showBack: boolean = false
  @Event onBack: () => void = () => {}

  @BuilderParam
  rightActions: () => void = this.defaultRightActions

  @Builder
  defaultRightActions() {
    if (this.showBack) {
      Column().width(40)
    }
  }

  build() {
    // 最外层用 Column 包裹，用于撑开状态栏高度
    Column() {
      // 原有的 Row 逻辑保持不变
      Row() {
        // 返回按钮区域：华为风格圆形浅灰底 + 细左箭头，左对齐
        if (this.showBack) {
          Row() {
            SymbolGlyph($r('sys.symbol.chevron_left'))
              .fontSize(22)
              .fontColor([$r('app.color.text_primary')])
              .fontWeight(FontWeight.Medium)
          }
          .width(40)
          .height(40)
          .justifyContent(FlexAlign.Center)
          .borderRadius(20)
          .backgroundColor($r('app.color.bg_search'))
          .accessibilityText($r('app.string.acc_back_button'))
          .onClick((): void => {
            this.onBack()
          })
        }

        // 标题文字
        Text(this.title)
          .fontSize(CommonConstants.FONT_SIZE_TITLE)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .textAlign(this.showBack ? TextAlign.Center : TextAlign.Start)

        // 右侧操作区：默认返回占位，可由调用方通过 rightActions 注入（如通知入口）
        this.rightActions()
      }
      .width('100%')
      .height(56)
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ top: safeAreaHelper.getStatusBar() })
    .backgroundColor($r('app.color.bg_page'))
  }
}