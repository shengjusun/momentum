import { CommonConstants } from '../common/constants/CommonConstants'
@Entry
@Component
struct TodoCardWidget {
  /** 卡片完成率大数字字号（卡片独立上下文，避免跨模块依赖） */
  private static readonly RATE_FONT_SIZE: number = 26
  @LocalStorageProp('totalCount') totalCount: number = 0
  @LocalStorageProp('completedCount') completedCount: number = 0
  @LocalStorageProp('task1Title') task1Title: string = ''
  @LocalStorageProp('task2Title') task2Title: string = ''
  @LocalStorageProp('hasTasks') hasTasks: boolean = false
  @LocalStorageProp('completionRate') completionRate: number = 0
  @LocalStorageProp('remainingCount') remainingCount: number = 0
  @LocalStorageProp('showTask1') showTask1: boolean = false
  @LocalStorageProp('showTask2') showTask2: boolean = false
  @LocalStorageProp('showDivider') showDivider: boolean = false
  @LocalStorageProp('showMore') showMore: boolean = false
  @LocalStorageProp('showProgress') showProgress: boolean = false
  @LocalStorageProp('showHeaderStats') showHeaderStats: boolean = false

  build() {
    Column() {
      // 顶部标题 + 完成率大数字
      Row() {
        Column() {
          Text($r('app.string.widget_today_todo')).fontSize(CommonConstants.FONT_SIZE_MID).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
          Row() {
            Text(this.completedCount + ' / ' + this.totalCount)
              .fontSize(CommonConstants.FONT_SIZE_XS).fontColor($r('app.color.text_secondary'))
            Text($r('app.string.widget_completed_count_suffix'))
              .fontSize(CommonConstants.FONT_SIZE_XS).fontColor($r('app.color.text_secondary'))
          }
          .margin({ top: 2 })
          .visibility(this.showHeaderStats ? Visibility.Visible : Visibility.Hidden)
        }
        .alignItems(HorizontalAlign.Start).layoutWeight(1)

        Text(this.completionRate + '%')
          .fontSize(TodoCardWidget.RATE_FONT_SIZE).fontWeight(FontWeight.Bold).fontColor($r('app.color.primary_color'))
          .visibility(this.showHeaderStats ? Visibility.Visible : Visibility.Hidden)
      }
      .width('100%').alignItems(VerticalAlign.Center)

      // 细横条进度条
      Stack({ alignContent: Alignment.Start }) {
        Row().width('100%').height(3).backgroundColor($r('app.color.bg_progress_track')).borderRadius(1.5)
        Row().width(this.completionRate + '%').height(3).backgroundColor($r('app.color.primary_color')).borderRadius(1.5)
      }
      .width('100%').margin({ top: 10, bottom: 12 })
      .visibility(this.showProgress ? Visibility.Visible : Visibility.Hidden)

      // 有任务：列表
      Column() {
        Row() {
          Row().width(14).height(14).borderRadius(7).border({ width: 1.5, color: $r('app.color.text_tertiary') }).margin({ right: 10 })
          Text(this.task1Title).fontSize(CommonConstants.FONT_SIZE_BODY).fontColor($r('app.color.text_primary')).maxLines(2).lineHeight(20).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        }
        .width('100%').padding({ top: 8, bottom: 8 })
        .visibility(this.showTask1 ? Visibility.Visible : Visibility.Hidden)

        Divider().width('100%').height(0.5).color($r('app.color.divider'))
          .visibility(this.showDivider ? Visibility.Visible : Visibility.Hidden)

        Row() {
          Row().width(14).height(14).borderRadius(7).border({ width: 1.5, color: $r('app.color.text_tertiary') }).margin({ right: 10 })
          Text(this.task2Title).fontSize(CommonConstants.FONT_SIZE_BODY).fontColor($r('app.color.text_primary')).maxLines(2).lineHeight(20).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        }
        .width('100%').padding({ top: 8, bottom: 8 })
        .visibility(this.showTask2 ? Visibility.Visible : Visibility.Hidden)

        Row() {
          Row() {
            Text('+' + this.remainingCount)
              .fontSize(CommonConstants.FONT_SIZE_SMALL).fontColor($r('app.color.text_tertiary'))
            Text($r('app.string.widget_more_items_suffix'))
              .fontSize(CommonConstants.FONT_SIZE_SMALL).fontColor($r('app.color.text_tertiary'))
          }
          Blank()
          Text($r('app.string.widget_view_all')).fontSize(CommonConstants.FONT_SIZE_XS).fontColor($r('app.color.primary_color'))
        }
        .width('100%').margin({ top: 8 })
        .visibility(this.showMore ? Visibility.Visible : Visibility.Hidden)
      }
      .width('100%').layoutWeight(1).alignItems(HorizontalAlign.Start)
      .visibility(this.hasTasks ? Visibility.Visible : Visibility.Hidden)

      // 空状态
      Column() {
        Text($r('app.string.widget_empty_title')).fontSize(CommonConstants.FONT_SIZE_BODY).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_secondary'))
        Text($r('app.string.widget_empty_cta')).fontSize(CommonConstants.FONT_SIZE_SMALL).fontColor($r('app.color.primary_color')).margin({ top: 4 })
      }
      .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
      .visibility(this.hasTasks ? Visibility.Hidden : Visibility.Visible)
    }
    .width('100%').height('100%').padding(16)
    .backgroundColor($r('app.color.bg_card')).borderRadius(16)
    .shadow({ radius: 8, color: $r('app.color.shadow_card'), offsetX: 0, offsetY: 2 })
    .onClick((): void => {
      postCardAction(this, { action: 'router', abilityName: 'EntryAbility', params: { targetPage: 'pages/MainTab' } })
    })
  }
}