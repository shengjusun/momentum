/**
 * @file MetaInfoRow —— 元信息行（图标底块 + 彩色图标 + 单行文字）
 *
 * @description
 *   任务详情页与目标详情页的"元信息"统一视觉：左侧 28×28 圆角图标底块（复用
 *   `icon_bg_*` 浅底 + `icon_text_*` 彩色图标），右侧单行文字（超出省略）。
 *
 *   2026-10-10 从 TaskDetailPage 内部抽出：目标详情页要改成同一视觉，若各写一份
 *   必然漂移（本项目"双份副本 → 单边覆盖"事故的老毛病）⇒ 收敛为单一来源。
 *
 * 用法：
 *   MetaInfoRow({
 *     icon: $r('sys.symbol.timer'),
 *     iconBg: $r('app.color.icon_bg_blue'),
 *     iconColor: $r('app.color.icon_text_blue'),
 *     text: '预计 45 分钟'
 *   })
 *
 * ⚠️ 调用实参里**不要出现 `<=` / `>=`**：护栏 check_sync_refactor.py 的 `_split_top()`
 *    把 `<` `>` 当括号计数，会把该实参与其后的实参误并成一个，报"实参 N 个，签名需 N+1 个"。
 *
 * @module common/components/ui
 */

import { DimensConstants } from '../../constants/DimensConstants'
import { CommonConstants } from '../../constants/CommonConstants'

@ComponentV2
export struct MetaInfoRow {
  /** 图标（建议用 `sys.symbol.*`） */
  @Param icon: Resource = $r('sys.symbol.info_circle')
  /** 图标底块背景色（建议 `icon_bg_*`） */
  @Param iconBg: ResourceColor = $r('app.color.icon_bg_blue')
  /** 图标颜色（建议 `icon_text_*`） */
  @Param iconColor: ResourceColor = $r('app.color.icon_text_blue')
  /** 单行文字 */
  @Param text: string = ''
  /** 文字颜色（如逾期用 `error_color`） */
  @Param textColor: ResourceColor = $r('app.color.text_primary')
  /** 图标底块边长（vp），默认 28 */
  @Param iconSize: number = 28

  /** 图标字号：跟随底块尺寸（28 → 14） */
  private iconFontSize(): number {
    return Math.round(this.iconSize / 2)
  }

  build() {
    Row({ space: 10 }) {
      Row() {
        SymbolGlyph(this.icon)
          .fontSize(this.iconFontSize())
          .fontColor([this.iconColor])
      }
      .width(this.iconSize)
      .height(this.iconSize)
      .borderRadius(DimensConstants.RADIUS_S)
      .backgroundColor(this.iconBg)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)

      Text(this.text)
        .fontSize(CommonConstants.FONT_SIZE_SMALL)
        .fontColor(this.textColor)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }
}
