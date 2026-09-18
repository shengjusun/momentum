/**
 * @file 导入 / 导出页
 * @description 我的 → 工具与管理 → 导入/导出任务数据
 *   - 导出：目标 + 待办 + 设置序列化为 JSON，经 DocumentViewPicker 保存到用户目录
 *   - 导入：DocumentViewPicker 选择 JSON 备份 → 解析校验 → 合并模式导入
 *     （按 ID 去重：本地已有 ID 保留本地，备份独有 ID 追加，双端数据都保留）
 *
 * 跳转来源：ProfilePage 工具与管理分组
 *
 * @module pages
 */

import { promptAction } from '@kit.ArkUI'
import { DimensConstants } from '../common/constants/DimensConstants'
import { CommonConstants } from '../common/constants/CommonConstants'
import { picker } from '@kit.CoreFileKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { util } from '@kit.ArkTS'
import { Logger } from '../common/utils/Logger'
import { routeVM } from '../viewmodel/RoutePageViewModel'
import { homeVM } from '../viewmodel/HomeViewModel'
import { settingsVM } from '../viewmodel/SettingsViewModel'
import { globalNavStack } from '../common/RouterManager'
import { CommonTitleBar } from '../common/components/CommonTitleBar'
import { AppActionSheet, AppActionSheetItem } from '../common/components/AppActionSheet'
import { safeAreaHelper } from '../common/utils/SafeAreaHelper'
import {
  GoalCardItem, GoalCardItemJSON, snapshotGoalCardItem, hydrateGoalCardItem
} from '../model/RouteModels'
import {
  HomeTodoItem, HomeTodoItemJSON, snapshotHomeTodoItem, hydrateHomeTodoItem
} from '../model/HomeModels'

/** 备份文件包结构 */
interface BackupPackage {
  app: string
  version: number
  exportedAt: number
  data: Record<string, Object>
}

/** 合并结果 */
interface MergeResult {
  goalsJson: GoalCardItemJSON[]
  tasksJson: HomeTodoItemJSON[]
}

@Entry
@ComponentV2
export struct ImportExportPage {
  @Local isExporting: boolean = false
  @Local isImporting: boolean = false
  /** 统一操作面板状态 */
  @Local showActionSheet: boolean = false
  @Local actionSheetTitle: string = ''
  @Local actionSheetItems: AppActionSheetItem[] = []

  private handleBack(): void {
    globalNavStack.pop()
  }

  /* ============================================================
   * 导出
   * ============================================================ */

  private async handleExport(): Promise<void> {
    if (this.isExporting) return
    this.isExporting = true
    try {
      const goalsSnapshot: Record<string, Object> = routeVM.buildSnapshot() as Object as Record<string, Object>
      const todosSnapshot: Record<string, Object> = homeVM.buildSnapshot() as Object as Record<string, Object>
      const settingsSnapshot: Record<string, Object> = settingsVM.buildSettingsSnapshot() as Object as Record<string, Object>
      const data: Record<string, Object> = {}
      data['goals'] = goalsSnapshot
      data['todos'] = todosSnapshot
      data['settings'] = settingsSnapshot
      const pkg: BackupPackage = {
        // ⚠️ 备份文件格式标识：与下方导入校验（parsed.app !== 'Momentum'）成对出现，
        // 属导出文件的兼容契约。应用改名（Momentum → 起势）时**此处不得同步修改**，
        // 否则用户此前导出的备份将全部无法导入。如需换标识，必须同时兼容新旧两个值。
        app: 'Momentum',
        version: 1,
        exportedAt: Date.now(),
        data: data
      }
      const jsonStr: string = JSON.stringify(pkg)

      const options = new picker.DocumentSaveOptions()
      options.newFileNames = ['Momentum_backup_' + this.formatDate() + '.json']
      const documentPicker = new picker.DocumentViewPicker(getContext(this))
      const uris: Array<string> = await documentPicker.save(options)
      if (uris.length === 0) {
        this.isExporting = false
        return
      }
      const targetUri: string = uris[0]
      const file = fs.openSync(targetUri, fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC)
      const encoder = new util.TextEncoder()
      const buffer: Uint8Array = encoder.encodeInto(jsonStr)
      fs.writeSync(file.fd, buffer.buffer as ArrayBuffer)
      fs.closeSync(file)
      this.isExporting = false
      promptAction.showToast({
        message: getContext(this).resourceManager.getStringSync($r('app.string.export_success').id),
        duration: 1500
      })
    } catch (e) {
      Logger.error('ImportExportPage', 'export failed: ' + (e as Error).message)
      this.isExporting = false
      promptAction.showToast({
        message: getContext(this).resourceManager.getStringSync($r('app.string.export_failed').id),
        duration: 1500
      })
    }
  }

  private formatDate(): string {
    const now: Date = new Date()
    const month: string = (now.getMonth() + 1).toString().padStart(2, '0')
    const day: string = now.getDate().toString().padStart(2, '0')
    return now.getFullYear().toString() + month + day
  }

  /* ============================================================
   * 导入（合并模式）
   * ============================================================ */

  private async handleImport(): Promise<void> {
    if (this.isImporting) return
    try {
      const options = new picker.DocumentSelectOptions()
      options.fileSuffixFilters = [getContext(this).resourceManager.getStringSync($r('app.string.import_file_filter_label').id) + '|.json']
      const documentPicker = new picker.DocumentViewPicker(getContext(this))
      const uris: Array<string> = await documentPicker.select(options)
      if (uris.length === 0) return

      const file = fs.openSync(uris[0], fs.OpenMode.READ_ONLY)
      const fileSize: number = fs.statSync(uris[0]).size
      const buffer = new ArrayBuffer(fileSize)
      fs.readSync(file.fd, buffer)
      fs.closeSync(file)
      const textDecoder = new util.TextDecoder('utf-8')
      const jsonStr: string = textDecoder.decodeToString(new Uint8Array(buffer))

      const parsed: BackupPackage = JSON.parse(jsonStr) as BackupPackage
      if (parsed.app !== 'Momentum' || parsed.data === undefined) {
        promptAction.showToast({
          message: getContext(this).resourceManager.getStringSync($r('app.string.import_invalid').id),
          duration: 2000
        })
        return
      }

      // 二次确认：合并模式导入（统一 ActionSheet）
      this.actionSheetTitle = getContext(this).resourceManager.getStringSync($r('app.string.import_confirm_message').id)
      this.actionSheetItems = [
        {
          label: getContext(this).resourceManager.getStringSync($r('app.string.common_confirm').id),
          action: (): void => {
            this.doMergeImport(parsed.data)
          }
        }
      ]
      this.showActionSheet = true
    } catch (e) {
      Logger.error('ImportExportPage', 'import failed: ' + (e as Error).message)
      promptAction.showToast({
        message: getContext(this).resourceManager.getStringSync($r('app.string.import_invalid').id),
        duration: 2000
      })
    }
  }

  /**
   * 合并模式导入：按 ID 去重，本地已有 ID 保留本地，备份独有 ID 追加
   */
  private doMergeImport(data: Record<string, Object>): void {
    this.isImporting = true
    try {
      const goalsData: Record<string, Object> = data['goals'] as Record<string, Object>
      const todosData: Record<string, Object> = data['todos'] as Record<string, Object>
      const mergedGoals: GoalCardItemJSON[] = []
      const mergedTasks: HomeTodoItemJSON[] = []

      // ---- 目标合并 ----
      // ⚠️ 这里刻意遍历**底层 routeVM.goals（含墓碑）**，属于 §1.4 数据分层规范的**唯一例外**：
      //    导入是"按 id 去重的数据合并"操作，必须看到墓碑 id 才能避免在数组里产生重复 id；
      //    若只看 liveGoals，已删除目标的 id 会被当作"本地不存在"而重复插入。
      const localGoalIds: Set<string> = new Set<string>()
      for (let i: number = 0; i < routeVM.goals.length; i++) {
        localGoalIds.add(routeVM.goals[i].id)
        const json: GoalCardItemJSON | null = snapshotGoalCardItem(routeVM.goals[i])
        if (json) mergedGoals.push(json)
      }
      const importedGoalsRaw: Object | undefined = goalsData['goals']
      if (Array.isArray(importedGoalsRaw)) {
        const items: Object[] = importedGoalsRaw as Object[]
        for (let i: number = 0; i < items.length; i++) {
          const raw: GoalCardItemJSON = items[i] as GoalCardItemJSON
          const g: GoalCardItem | null = hydrateGoalCardItem(raw)
          if (g === null) continue
          if (localGoalIds.has(g.id)) continue
          const json: GoalCardItemJSON | null = snapshotGoalCardItem(g)
          if (json) mergedGoals.push(json)
        }
      }

      // ---- 待办合并 ----
      // 同目标合并：刻意遍历底层 homeVM.taskList（含墓碑），理由见上
      const localTaskIds: Set<string> = new Set<string>()
      for (let i: number = 0; i < homeVM.taskList.length; i++) {
        localTaskIds.add(homeVM.taskList[i].id)
        const json: HomeTodoItemJSON | null = snapshotHomeTodoItem(homeVM.taskList[i])
        if (json) mergedTasks.push(json)
      }
      const importedTasksRaw: Object | undefined = todosData['taskList']
      if (Array.isArray(importedTasksRaw)) {
        const items: Object[] = importedTasksRaw as Object[]
        for (let i: number = 0; i < items.length; i++) {
          const raw: HomeTodoItemJSON = items[i] as HomeTodoItemJSON
          const t: HomeTodoItem | null = hydrateHomeTodoItem(raw)
          if (t === null) continue
          if (localTaskIds.has(t.id)) continue
          const json: HomeTodoItemJSON | null = snapshotHomeTodoItem(t)
          if (json) mergedTasks.push(json)
        }
      }

      // 应用合并结果
      const goalsSnapshot: Record<string, Object> = {}
      goalsSnapshot['goals'] = mergedGoals
      goalsSnapshot['filterCategory'] = routeVM.filterCategory
      goalsSnapshot['version'] = 1
      const todosSnapshot: Record<string, Object> = {}
      todosSnapshot['taskList'] = mergedTasks
      todosSnapshot['version'] = 1
      routeVM.applyCloudSnapshot(goalsSnapshot)
      homeVM.applyCloudSnapshot(todosSnapshot)

      // ⚠️ applyCloudSnapshot 是"同步落地"语义：只落盘、**不打脏标记、不触发云同步**（防回环）。
      //    导入是本地用户操作，必须显式打脏标记，让导入结果能同步到云端。
      settingsVM.markSyncNeeded('import')

      this.isImporting = false
      promptAction.showToast({
        message: getContext(this).resourceManager.getStringSync($r('app.string.import_success').id),
        duration: 1500
      })
    } catch (e) {
      Logger.error('ImportExportPage', 'doMergeImport failed: ' + (e as Error).message)
      this.isImporting = false
      promptAction.showToast({
        message: getContext(this).resourceManager.getStringSync($r('app.string.import_failed').id),
        duration: 1500
      })
    }
  }

  /* ============================================================
   * UI Builder
   * ============================================================ */

  @Builder
  SectionCardBuilder(icon: Resource, title: ResourceStr, desc: ResourceStr,
    btnText: ResourceStr, onBtn: () => void) {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        SymbolGlyph(icon)
          .fontSize(CommonConstants.FONT_SIZE_HEADLINE)
          .fontColor([$r('app.color.primary_color')])
          .width(40)
          .height(40)
        Column({ space: 3 }) {
          Text(title)
            .fontSize(CommonConstants.FONT_SIZE_MID)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(desc)
            .fontSize(CommonConstants.FONT_SIZE_XS)
            .fontColor($r('app.color.text_tertiary'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')

      Button(btnText)
        .type(ButtonType.Capsule)
        .width('100%')
        .height(42)
        .fontSize(CommonConstants.FONT_SIZE_BODY)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_inverse'))
        .backgroundColor($r('app.color.primary_color'))
        .onClick((): void => {
          onBtn()
        })
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(DimensConstants.RADIUS_L)
    .margin({ top: 16 })
  }

  build() {
    NavDestination() {
      Stack() {
      Column() {
        CommonTitleBar({
          title: $r('app.string.page_import_export'),
          showBack: true,
          onBack: (): void => {
            this.handleBack()
          }
        })

        Scroll() {
          Column() {
            this.SectionCardBuilder(
              $r('sys.symbol.arrow_up_circle'),
              $r('app.string.export_section_title'),
              $r('app.string.export_section_desc'),
              $r('app.string.export_btn'),
              (): void => {
                this.handleExport()
              }
            )

            this.SectionCardBuilder(
              $r('sys.symbol.square_and_arrow_down'),
              $r('app.string.import_section_title'),
              $r('app.string.import_section_desc'),
              $r('app.string.import_btn'),
              (): void => {
                this.handleImport()
              }
            )
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: safeAreaHelper.getBottomWith(24) })
        }
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
        .width('100%')
        .layoutWeight(1)
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))

      // 统一操作面板（替代系统 showDialog）
      if (this.showActionSheet) {
        AppActionSheet({
          title: this.actionSheetTitle,
          items: this.actionSheetItems,
          onDismiss: (): void => {
            this.showActionSheet = false
          }
        })
      }
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .onBackPressed((): boolean => {
      this.handleBack()
      return true
    })
  }
}
