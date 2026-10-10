import { safeAreaHelper } from '../utils/SafeAreaHelper'
import { CommonConstants } from '../constants/CommonConstants'

/** 栏体高度（vp）——滚动联动时内容顶部避让也用它，改这里即可（TaskDetailPage 会 import） */
export const TITLE_BAR_HEIGHT: number = 56
/** 栏下方渐隐遮罩高度（vp）：内容滚到栏前在这段距离内渐隐，而不是被硬切一刀 */
const TITLE_BAR_MASK_HEIGHT: number = 16

/**
 * 通用标题栏
 *
 * 滚动联动（**可选**）：调用方传入 `scrollProgress`（0~1）即启用；默认 `-1` = 不启用，
 * 保持历史静态栏行为 ⇒ **其余 8 个页面零影响**。
 *
 * 启用后由滚动进度连续驱动三件事（**刻意不做时间动画**，滚动本来就连续，叠 `.animation()`
 * 会让手感变黏、产生拖尾）：
 *   1. 栏体底色「页面色 → 卡片白」淡入（叠加层透明度）；
 *   2. 栏底 0.5px 分割线淡入（滚动前无边界，滚动后出现实边）；
 *   3. 栏下方 16vp 渐隐遮罩淡入（内容滚上来在这段内渐隐）。
 *
 * ⚠️ 标题与返回键**始终不透明**：滚动中必须保留导航锚点，否则用户不知道在哪一页、
 *    也点不到返回键；状态栏文字也必须有底色托住（故栏底色层覆盖状态栏区）。
 *
 * ⚠️ 渐变遮罩的末端色用 `scroll_fade_end`（与 `bg_card` **同色、零透明**）而不是通用的
 *    `color_transparent`（#00000000）：白 → 透明黑 会在中段插出灰带。暗色模式另有取值。
 */
@ComponentV2
@ReusableV2
export struct CommonTitleBar {
  @Param title: ResourceStr = ''
  @Param showBack: boolean = false
  @Event onBack: () => void = () => {}
  /**
   * 滚动联动进度：`-1` = 不启用（默认，静态栏）；`0~1` = 启用（0 = 未滚动 / 1 = 已滚过联动距离）
   */
  @Param scrollProgress: number = -1

  @BuilderParam
  rightActions: () => void = this.defaultRightActions

  @Builder
  defaultRightActions() {
    if (this.showBack) {
      Column().width(40)
    }
  }

  /** 是否启用滚动联动（>= 0 即启用） */
  private isScrollLinked(): boolean {
    return this.scrollProgress >= 0
  }

  /** 联动不透明度（0~1；未启用恒 0 ⇒ 白层/分割线/遮罩全部不可见） */
  private linkedOpacity(): number {
    if (!this.isScrollLinked()) return 0
    return Math.max(0, Math.min(1, this.scrollProgress))
  }

  build() {
    Column() {
      // 栏体（含状态栏区）：底色 = 页面色；其上叠加卡片白，透明度由滚动进度驱动
      Stack({ alignContent: Alignment.TopStart }) {
        // 底色叠加层：滚动后淡入，把「页面色」过渡成「卡片白」
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.bg_card'))
          .opacity(this.linkedOpacity())

        Column() {
          // 状态栏占位：让栏底色层覆盖状态栏区，状态栏文字始终有底
          Column()
            .width('100%')
            .height(safeAreaHelper.getStatusBar())

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
          .height(TITLE_BAR_HEIGHT)
          .padding({ left: 16, right: 16 })
          .alignItems(VerticalAlign.Center)

          // 栏底分割线：滚动前无边界，滚动后淡入「实边」
          if (this.isScrollLinked()) {
            Column()
              .width('100%')
              .height(0.5)
              .backgroundColor($r('app.color.divider'))
              .opacity(this.linkedOpacity())
          }
        }
        .width('100%')
      }
      .width('100%')
      .height(safeAreaHelper.getStatusBar() + TITLE_BAR_HEIGHT + (this.isScrollLinked() ? 0.5 : 0))
      .backgroundColor($r('app.color.bg_page'))

      // 栏下方渐隐遮罩：内容滚到栏前在这段距离内渐隐（仅启用时存在）
      if (this.isScrollLinked()) {
        Column()
          .width('100%')
          .height(TITLE_BAR_MASK_HEIGHT)
          .linearGradient({
            angle: 180,
            colors: [[$r('app.color.bg_card'), 0], [$r('app.color.scroll_fade_end'), 1]]
          })
          .opacity(this.linkedOpacity())
      }
    }
    .width('100%')
    // 根容器透明：遮罩区不能被底色挡住，必须透出下层滚动内容
    .backgroundColor(Color.Transparent)
  }
}
