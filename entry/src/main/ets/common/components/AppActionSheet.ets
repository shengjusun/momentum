/**
 * AppActionSheet - 全 App 统一的底部操作面板（替代系统 showActionMenu/AlertDialog 兜底样式）
 *
 * 设计规范：
 *   - 底部上滑入场 + 遮罩淡入；顶部圆角 24 + 圆点拖拽条
 *   - 菜单项行高 52、圆角胶囊按压态；危险项红色；底部独立取消区
 *   - 深浅色全部走资源引用
 *
 * 用法（页面 Stack 内条件渲染）：
 *   if (this.showSheet) {
 *     AppActionSheet({
 *       title: '任务操作',
 *       items: [
 *         { label: '编辑', action: (): void => this.doEdit() },
 *         { label: '删除', danger: true, action: (): void => this.doDelete() }
 *       ],
 *       onDismiss: (): void => { this.showSheet = false }
 *     })
 *   }
 */
import { CommonConstants } from '../constants/CommonConstants'
import { DimensConstants } from '../constants/DimensConstants'
import { safeAreaHelper } from '../utils/SafeAreaHelper'
import { MotionConstants } from '../constants/MotionConstants'

/** 面板菜单项（label 由调用方完成资源解析） */
export interface AppActionSheetItem {
  label: string
  /** 危险操作（红色文案） */
  danger?: boolean
  action: () => void
}

@ComponentV2
export struct AppActionSheet {
  @Param title: string = ''
  @Param items: AppActionSheetItem[] = []
  @Event onDismiss: () => void = () => {}

  /** 入场动画状态 */
  @Local entered: boolean = false
  /** 按压态菜单项索引 */
  @Local pressedIndex: number = -1

  aboutToAppear(): void {
    // 下一帧再置位，触发上滑入场动画
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
          this.onDismiss()
        })

      // 底部面板
      Column() {
        // 拖拽条
        Row()
          .width(36)
          .height(4)
          .borderRadius(2)
          .backgroundColor($r('app.color.divider'))
          .margin({ top: 10, bottom: 4 })

        // 标题
        if (this.title.length > 0) {
          Text(this.title)
            .fontSize(CommonConstants.FONT_SIZE_SMALL)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 6, bottom: 6 })
        }

        // 菜单项
        ForEach(this.items, (item: AppActionSheetItem, index: number): void => {
          Row() {
            Text(item.label)
              .fontSize(CommonConstants.FONT_SIZE_SUBTITLE)
              .fontWeight(FontWeight.Medium)
              .fontColor(item.danger === true ? $r('app.color.error_color') : $r('app.color.text_primary'))
          }
          .width('100%')
          .height(52)
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .borderRadius(DimensConstants.RADIUS_L)
          .margin({ left: 8, right: 8 })
          .backgroundColor(this.pressedIndex === index ? $r('app.color.bg_tag') : Color.Transparent)
          .animation(MotionConstants.pressParam())
          .onClick((): void => {
            // 先收面板再执行动作，动作内部可能再次弹层
            this.onDismiss()
            item.action()
          })
          .onTouch((event: TouchEvent): void => {
            if (event.type === TouchType.Down) {
              this.pressedIndex = index
            } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              this.pressedIndex = -1
            }
          })
        }, (item: AppActionSheetItem): string => item.label + (item.danger === true ? '_d' : ''))

        // 取消区（独立分隔）
        Divider()
          .color($r('app.color.divider'))
          .margin({ top: 8, bottom: 2 })
        Row() {
          Text($r('app.string.common_cancel'))
            .fontSize(CommonConstants.FONT_SIZE_SUBTITLE)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .height(52)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .borderRadius(DimensConstants.RADIUS_L)
        .margin({ left: 8, right: 8 })
        .backgroundColor(this.pressedIndex === -2 ? $r('app.color.bg_tag') : Color.Transparent)
        .animation(MotionConstants.pressParam())
        .onClick((): void => {
          this.onDismiss()
        })
        .onTouch((event: TouchEvent): void => {
          if (event.type === TouchType.Down) {
            this.pressedIndex = -2
          } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
            this.pressedIndex = -1
          }
        })

        // 底部安全区避让
        Row().height(safeAreaHelper.getBottomWith(8))
      }
      .width('100%')
      .padding({ left: 8, right: 8 })
      .backgroundColor($r('app.color.bg_card'))
      .borderRadius({ topLeft: 24, topRight: 24 })
      .translate({ y: this.entered ? 0 : 320 })
      .animation(MotionConstants.panelParam())
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
  }
}
