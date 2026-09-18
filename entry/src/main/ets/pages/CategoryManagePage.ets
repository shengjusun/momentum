/**
 * @file 标签管理页（目标分类管理）
 * @description 我的 → 工具与管理 → 标签管理
 *   目标分类管理：列出所有在用分类及目标数量，支持：
 *   - 重命名：批量更新该分类下所有目标的分类名
 *   - 合并：将当前分类下的目标全部移入另一个分类
 *
 * 跳转来源：ProfilePage 工具与管理分组
 *
 * @module pages
 */

import { promptAction } from '@kit.ArkUI'
import { DimensConstants } from '../common/constants/DimensConstants'
import { CommonConstants } from '../common/constants/CommonConstants'
import { Logger } from '../common/utils/Logger'
import { routeVM } from '../viewmodel/RoutePageViewModel'
import { globalNavStack } from '../common/RouterManager'
import { CommonTitleBar } from '../common/components/CommonTitleBar'
import { safeAreaHelper } from '../common/utils/SafeAreaHelper'
import { MotionHelper } from '../common/utils/MotionHelper'

/** 分类统计项 */
class CategoryCount {
  name: string = ''
  count: number = 0

  constructor(name: string, count: number) {
    this.name = name
    this.count = count
  }
}

/** 对话框模式 */
type TagDialogMode = 'none' | 'rename' | 'merge'

@Entry
@ComponentV2
export struct CategoryManagePage {
  @Local dialogMode: TagDialogMode = 'none'
  @Local currentCategory: string = ''
  @Local inputText: string = ''

  private handleBack(): void {
    globalNavStack.pop()
  }

  /**
   * 聚合当前所有在用分类（去重 + 计数，按数量降序）
   */
  private buildCategoryList(): CategoryCount[] {
    const list: CategoryCount[] = []
    for (let i: number = 0; i < routeVM.liveGoals.length; i++) {
      const cat: string = routeVM.liveGoals[i].category.trim()
      if (cat.length === 0) continue
      let found: boolean = false
      for (let j: number = 0; j < list.length; j++) {
        if (list[j].name === cat) {
          list[j].count++
          found = true
          break
        }
      }
      if (!found) {
        list.push(new CategoryCount(cat, 1))
      }
    }
    list.sort((a: CategoryCount, b: CategoryCount): number => b.count - a.count)
    return list
  }

  private openRename(category: string): void {
    this.dialogMode = 'rename'
    this.currentCategory = category
    this.inputText = category
  }

  private openMerge(category: string): void {
    this.dialogMode = 'merge'
    this.currentCategory = category
    this.inputText = ''
  }

  private closeDialog(): void {
    this.dialogMode = 'none'
    this.inputText = ''
  }

  private confirmDialog(): void {
    const newName: string = this.inputText.trim()
    if (newName.length === 0) {
      promptAction.showToast({
        message: getContext(this).resourceManager.getStringSync($r('app.string.tag_name_empty').id),
        duration: 1500
      })
      return
    }
    if (newName === this.currentCategory) {
      promptAction.showToast({
        message: getContext(this).resourceManager.getStringSync($r('app.string.tag_same_name').id),
        duration: 1500
      })
      return
    }
    const mode: TagDialogMode = this.dialogMode
    routeVM.renameCategory(this.currentCategory, newName)
    this.closeDialog()
    promptAction.showToast({
      message: getContext(this).resourceManager.getStringSync(
        mode === 'rename' ? $r('app.string.tag_rename_success').id : $r('app.string.tag_merge_success').id),
      duration: 1500
    })
    Logger.info('CategoryManagePage', 'confirmDialog mode=' + mode + ' ' +
      this.currentCategory + ' -> ' + newName)
  }

  /* ============================================================
   * UI Builder
   * ============================================================ */

  @Builder
  CategoryListBuilder() {
    Column({ space: 6 }) {
      Text($r('app.string.profile_item_tag_manage'))
        .fontSize(CommonConstants.FONT_SIZE_BODY)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_secondary'))
        .padding({ left: 4 })

      if (this.buildCategoryList().length === 0) {
        Column({ space: 12 }) {
          SymbolGlyph($r('sys.symbol.label'))
            .fontSize(CommonConstants.FONT_SIZE_HUGE)
            .fontColor([$r('app.color.text_tertiary')])
          Text($r('app.string.tag_empty'))
            .fontSize(CommonConstants.FONT_SIZE_SMALL)
            .fontColor($r('app.color.text_tertiary'))
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .padding({ top: 40, bottom: 40 })
        .alignItems(HorizontalAlign.Center)
        .backgroundColor($r('app.color.bg_card'))
        .borderRadius(DimensConstants.RADIUS_L)
      } else {
        Column({ space: 0 }) {
          ForEach(this.buildCategoryList(), (item: CategoryCount): void => {
            Row({ space: 12 }) {
              SymbolGlyph($r('sys.symbol.label'))
                .fontSize(CommonConstants.FONT_SIZE_TITLE)
                .fontColor([$r('app.color.primary_color')])
                .width(28)
                .height(28)
              Column({ space: 2 }) {
                Text(item.name)
                  .fontSize(CommonConstants.FONT_SIZE_MID)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(item.count.toString() + getContext(this).resourceManager.getStringSync($r('app.string.chat_tasks_count_suffix').id))
                  .fontSize(CommonConstants.FONT_SIZE_XS)
                  .fontColor($r('app.color.text_tertiary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Text($r('app.string.tag_rename'))
                .fontSize(CommonConstants.FONT_SIZE_SMALL)
                .fontColor($r('app.color.primary_color'))
                .textAlign(TextAlign.Center)
                .constraintSize({ minWidth: 44, minHeight: 44 })
                .padding({ left: 10, right: 10 })
                .borderRadius(DimensConstants.RADIUS_M)
                .backgroundColor($r('app.color.primary_color_bg'))
                .onClick((): void => {
                  this.openRename(item.name)
                })

              Text($r('app.string.tag_merge'))
                .fontSize(CommonConstants.FONT_SIZE_SMALL)
                .fontColor($r('app.color.text_secondary'))
                .textAlign(TextAlign.Center)
                .constraintSize({ minWidth: 44, minHeight: 44 })
                .padding({ left: 10, right: 10 })
                .borderRadius(DimensConstants.RADIUS_M)
                .backgroundColor($r('app.color.bg_tag'))
                .onClick((): void => {
                  this.openMerge(item.name)
                })
            }
            .width('100%')
            .constraintSize({ minHeight: 60 })
            .padding({ left: 16, right: 16 })
            .alignItems(VerticalAlign.Center)
          }, (item: CategoryCount): string => 'cat_' + item.name)

          Text($r('app.string.help_data_desc'))
            .fontSize(CommonConstants.FONT_SIZE_XS)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .padding(16)
        }
        .width('100%')
        .backgroundColor($r('app.color.bg_card'))
        .borderRadius(DimensConstants.RADIUS_L)
      }
    }
    .width('100%')
    .margin({ top: 16 })
  }

  @Builder
  TagDialogBuilder() {
    Column() {
      Column() {
        Row() {
          Text(this.dialogMode === 'rename' ?
            $r('app.string.tag_rename_title') : $r('app.string.tag_merge_title'))
            .fontSize(CommonConstants.FONT_SIZE_SUBTITLE)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(CommonConstants.FONT_SIZE_BODY)
            .fontColor([$r('app.color.text_secondary')])
            .width(32)
            .height(32)
            .borderRadius(DimensConstants.RADIUS_L)
            .backgroundColor($r('app.color.bg_tag'))
            .onClick((): void => {
              this.closeDialog()
            })
        }
        .width('100%')

        Text(this.dialogMode === 'rename' ?
          $r('app.string.tag_rename_message') : $r('app.string.tag_merge_message'))
          .fontSize(CommonConstants.FONT_SIZE_SMALL)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .margin({ top: 8 })

        TextInput({
          placeholder: getContext(this).resourceManager.getStringSync(
            this.dialogMode === 'rename' ?
              $r('app.string.tag_new_name_placeholder').id : $r('app.string.tag_merge_target_placeholder').id),
          text: this.inputText
        })
          .fontSize(CommonConstants.FONT_SIZE_BODY)
          .height(44)
          .borderRadius(DimensConstants.RADIUS_M)
          .backgroundColor($r('app.color.bg_tag'))
          .margin({ top: 16 })
          .onChange((value: string): void => {
            this.inputText = value
          })

        Row({ space: 12 }) {
          Button($r('app.string.common_cancel'))
            .type(ButtonType.Capsule)
            .layoutWeight(1)
            .height(40)
            .fontSize(CommonConstants.FONT_SIZE_BODY)
            .fontColor($r('app.color.text_secondary'))
            .backgroundColor($r('app.color.bg_tag'))
            .onClick((): void => {
              this.closeDialog()
            })
          Button($r('app.string.common_confirm'))
            .type(ButtonType.Capsule)
            .layoutWeight(1)
            .height(40)
            .fontSize(CommonConstants.FONT_SIZE_BODY)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_inverse'))
            .backgroundColor($r('app.color.primary_color'))
            .onClick((): void => {
              this.confirmDialog()
            })
        }
        .width('100%')
        .margin({ top: 20 })
      }
      .width('85%')
      .padding(20)
      .backgroundColor($r('app.color.bg_card'))
      .borderRadius(DimensConstants.RADIUS_L)
      // 位移/缩放只能挂内层卡片：遮罩是同一棵树的背景层，跟着移动会带出错误的空间暗示
      .transition(MotionHelper.dialogCard())
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('app.color.overlay_mask'))
    .transition(MotionHelper.overlayFade())
  }

  build() {
    NavDestination() {
      Column() {
        CommonTitleBar({
          title: $r('app.string.page_tag_manage'),
          showBack: true,
          onBack: (): void => {
            this.handleBack()
          }
        })

        Scroll() {
          Column() {
            this.CategoryListBuilder()
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: safeAreaHelper.getBottomWith(24) })
        }
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
        .width('100%')
        .layoutWeight(1)

        if (this.dialogMode !== 'none') {
          this.TagDialogBuilder()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))
    }
    .hideTitleBar(true)
    .onBackPressed((): boolean => {
      if (this.dialogMode !== 'none') {
        this.closeDialog()
        return true
      }
      this.handleBack()
      return true
    })
  }
}
