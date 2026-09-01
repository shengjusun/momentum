import { FormExtensionAbility, formBindingData, formProvider } from '@kit.FormKit'
import { Want } from '@kit.AbilityKit'
import { Configuration } from '@kit.AbilityKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { util } from '@kit.ArkTS'
import { preferences } from '@kit.ArkData'
import { Logger } from '../common/utils/Logger'

/** 卡片完整数据结构 */
interface TodoCardBindingData {
  totalCount: number
  completedCount: number
  task1Title: string
  task2Title: string
  hasTasks: boolean
  completionRate: number
  remainingCount: number
  showTask1: boolean
  showTask2: boolean
  showDivider: boolean
  showMore: boolean
  showProgress: boolean
  showHeaderStats: boolean
}

const TAG: string = 'EntryFormAbility'
const PREF_NAME: string = 'momentum_card_store'

export default class EntryFormAbility extends FormExtensionAbility {

  onAddForm(want: Want): formBindingData.FormBindingData {
    const params: Record<string, Object> = want.parameters as Record<string, Object>
    const formId: string = (params['ohos.extra.param.key.form_identity'] as string)
      || (params['formId'] as string)
      || ''

    Logger.info(TAG, 'onAddForm: formId=' + formId)

    if (formId.length > 0) {
      this.persistFormId(formId).catch((e: Error): void => {
        Logger.error(TAG, 'persistFormId failed: ' + e.message)
      })
    }

    const bindingData: TodoCardBindingData = this.loadSnapshot()
    const fbData: formBindingData.FormBindingData =
      formBindingData.createFormBindingData(bindingData)

    if (formId.length > 0) {
      formProvider.updateForm(formId, fbData)
        .then((): void => { Logger.info(TAG, 'onAddForm push success') })
        .catch((e: Error): void => { Logger.error(TAG, 'onAddForm push failed: ' + e.message) })
    }

    return fbData
  }

  onUpdateForm(formId: string): formBindingData.FormBindingData {
    Logger.info(TAG, 'onUpdateForm: formId=' + formId)
    const bindingData: TodoCardBindingData = this.loadSnapshot()
    const fbData: formBindingData.FormBindingData =
      formBindingData.createFormBindingData(bindingData)

    formProvider.updateForm(formId, fbData)
      .then((): void => { Logger.info(TAG, 'onUpdateForm push success') })
      .catch((e: Error): void => { Logger.error(TAG, 'onUpdateForm push failed: ' + e.message) })

    return fbData
  }

  private loadSnapshot(): TodoCardBindingData {
    const emptyData: TodoCardBindingData = {
      totalCount: 0, completedCount: 0, task1Title: '', task2Title: '',
      hasTasks: false, completionRate: 0, remainingCount: 0,
      showTask1: false, showTask2: false, showDivider: false,
      showMore: false, showProgress: false, showHeaderStats: false
    }

    try {
      const appCtx = this.context.getApplicationContext()
      const path: string = appCtx.filesDir + '/card_snapshot.json'

      if (!fs.accessSync(path)) {
        return emptyData
      }

      const stat = fs.statSync(path)
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY)
      const buffer = new ArrayBuffer(stat.size)
      fs.readSync(file.fd, buffer)
      fs.closeSync(file)

      const textDecoder = new util.TextDecoder('utf-8')
      const snapshotJson: string = textDecoder.decodeToString(new Uint8Array(buffer))
      if (snapshotJson.length === 0) {
        return emptyData
      }

      // HomeViewModel 已写入完整快照数据，直接解析返回
      const snapshot: TodoCardBindingData = JSON.parse(snapshotJson) as TodoCardBindingData
      if (snapshot === null || typeof snapshot.totalCount !== 'number') {
        return emptyData
      }

      Logger.info(TAG, 'loadSnapshot: total=' + snapshot.totalCount.toString() +
        ', rate=' + snapshot.completionRate.toString())
      return snapshot
    } catch (e) {
      Logger.error(TAG, 'loadSnapshot failed: ' + (e as Error).message)
      return emptyData
    }
  }

  private async persistFormId(formId: string): Promise<void> {
    const prefs = await preferences.getPreferences(this.context, PREF_NAME)
    await prefs.put('form_id', formId)
    await prefs.flush()
    Logger.info(TAG, 'persistFormId: saved formId=' + formId)
  }

  onFormEvent(formId: string, message: string): void {
    Logger.info(TAG, 'onFormEvent: formId=' + formId)
  }

  onRemoveForm(formId: string): void {
    Logger.info(TAG, 'onRemoveForm: formId=' + formId)
    this.clearPersistedFormId().catch((e: Error): void => {
      Logger.error(TAG, 'clearPersistedFormId failed: ' + e.message)
    })
  }

  onConfigurationUpdate(config: Configuration): void {
    Logger.info(TAG, 'onConfigurationUpdate')
  }

  private async clearPersistedFormId(): Promise<void> {
    const prefs = await preferences.getPreferences(this.context, PREF_NAME)
    await prefs.delete('form_id')
    await prefs.flush()
  }
}