/**
 * @file 华为官方沉浸光感 TabBar（纯净悬浮版）
 * @description
 *   - 胶囊悬浮底部，无凸起按钮，符合 HDS 规范
 *   - 使用 BACKGROUND_THICK 官方沉浸光感材质（强磨砂质感）
 *   - 配合 AdaptiveColor.AVERAGE 自适应底色，磨玻璃随内容变化，沉浸感真实
 *   - 不叠加额外背景色/白边框，靠 BlurStyle 自带质感
 *   - 阴影轻量，选中态为图标+文字变色
 */

import { TabConfig } from '../../model/BaseTypes'
import { CommonConstants } from '../../common/constants/CommonConstants'
import { safeAreaHelper } from '../utils/SafeAreaHelper'

/** TabBar 胶囊高度 */
const TAB_BAR_HEIGHT: number = 56
/** 胶囊圆角（=高度/2，形成完整胶囊） */
const CAPSULE_RADIUS: number = 28

@ComponentV2
export struct DuneTabBar {
  /** 当前选中索引 */
  @Param currentIndex: number = 0
  /** Tab 配置数组 */
  @Param tabConfigs: TabConfig[] = []
  /** 选中回调 */
  @Event onTabSelected: (index: number) => void = () => {}

  /**
   * 胶囊外边距：底部安全区 + 悬浮间距
   * build 内直读响应式安全区单例，旋转/折叠后自动刷新
   */
  private getBarMargin(): Margin {
    const margin: Margin = { bottom: safeAreaHelper.getBottom() + 10 }
    return margin
  }

  build() {
    Row() {
      ForEach(this.tabConfigs,
        (config: TabConfig, idx: number): void => {
          this.TabItem(config, idx)
        },
        (config: TabConfig): string => config.index.toString())
    }
    .width('100%')
    .height(TAB_BAR_HEIGHT)
    .padding({ left: 12, right: 12 })
    // 华为官方沉浸光感：BACKGROUND_THICK 强磨砂质感，导航表面最显著档位
    // AdaptiveColor.AVERAGE 让材质取背景平均色自适应调色，沉浸光感随底色变化
    .backgroundBlurStyle(BlurStyle.BACKGROUND_THICK, {
      adaptiveColor: AdaptiveColor.AVERAGE
    })
    // 深色模式对比度修复：磨砂在纯黑背景上趋近黑色，胶囊与页面融为一体；
    // 叠加微透提亮色调 + 发丝描边（浅色模式两值近中性，观感不变）
    .backgroundColor($r('app.color.tab_bar_tint'))
    .border({ width: 0.5, color: $r('app.color.tab_bar_border') })
    .borderRadius(CAPSULE_RADIUS)
    .shadow({
      radius: 12,
      color: $r('app.color.shadow_card'),
      offsetX: 0,
      offsetY: 4
    })
    .margin(this.getBarMargin())
  }

  @Builder
  TabItem(config: TabConfig, idx: number): void {
    Column({ space: 2 }) {
      Image(idx === this.currentIndex ? config.iconSelected : config.icon)
        .width(22)
        .height(22)
        .fillColor(idx === this.currentIndex
          ? $r('app.color.primary_color')
          : $r('app.color.tab_inactive'))

      Text(config.title)
        .fontSize(CommonConstants.FONT_SIZE_XXS)
        .fontWeight(idx === this.currentIndex ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(idx === this.currentIndex
          ? $r('app.color.primary_color')
          : $r('app.color.tab_inactive'))
    }
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .onClick((): void => {
      this.onTabSelected(config.index)
    })
    .animation({
      duration: 150,
      curve: Curve.EaseInOut
    })
  }
}
