/** 持久化辅助类 - 统一封装防抖写入 + 异常处理，消除各 VM 重复的防抖模板代码 */

import { Logger } from './Logger'

/**
 * 持久化辅助类
 * scheduleSave 防抖写入、flush 页面退出强写、persistNow 异常兜底
 */
export class PersistHelper {
  /** 防抖定时器句柄 */
  private saveTimer: number = -1
  /** 防抖延迟（毫秒） */
  private readonly delay: number
  /** 实际持久化函数（由各VM提供） */
  private readonly persistFn: () => Promise<void>
  /** 日志标签 */
  private readonly tag: string
  /** 防抖触发时的附加回调（如云同步），flush时不触发 */
  private onScheduleFire: (() => void) | null

  /**
   * @param tag - 日志标签（通常为VM类名）
   * @param persistFn - 实际持久化函数（由各VM提供，包含序列化 + 写入）
   * @param delay - 防抖延迟毫秒数，默认200
   * @param onScheduleFire - 防抖触发时的附加回调（如云同步），flush不触发
   */
  constructor(tag: string, persistFn: () => Promise<void>, delay: number = 200,
    onScheduleFire?: (() => void)) {
    this.tag = tag
    this.persistFn = persistFn
    this.delay = delay
    this.onScheduleFire = onScheduleFire !== undefined ? onScheduleFire : null
  }

  /**
   * 防抖持久化：合并多次连续修改，延迟单次落盘
   * 每次调用重置定时器，到期后执行一次写入并触发 onScheduleFire
   *
   * ⚠️ 云同步改造（2026-09-15）：**写入成功才触发 onScheduleFire**
   *   onScheduleFire 现在负责"打持久化 SYNC_NEEDED 脏标记 + 触发 merge"，
   *   若落盘失败仍触发，会把未落盘的内存态当成"本地有改动"上传，破坏一致性。
   */
  scheduleSave(): void {
    if (this.saveTimer !== -1) {
      clearTimeout(this.saveTimer)
    }
    this.saveTimer = setTimeout(async (): Promise<void> => {
      const persisted: boolean = await this.persistNow()
      if (!persisted) {
        Logger.error(this.tag, 'scheduleSave: persist failed, skip onScheduleFire (SYNC_NEEDED not marked)')
        return
      }
      if (this.onScheduleFire !== null) {
        this.onScheduleFire()
      }
    }, this.delay)
  }

  /**
   * 防抖持久化，但**不触发** onScheduleFire
   *
   * 用途：只影响本机视图状态、不参与云同步语义的字段变更。
   * 典型场景 `RoutePageViewModel.filterCategory`（分类筛选）——它是纯本机 UI 瞬时状态，
   * `applyCloudSnapshot` 明确不采纳该字段，走 scheduleSave 只会"打脏标记 → 白跑一轮网络 merge"
   * （merge 后内容无变化，不会上传，纯粹浪费一次请求）。
   *
   * 与 scheduleSave 的唯一区别：**不回调 onScheduleFire**；防抖与单次落盘行为完全一致。
   */
  scheduleSaveSilent(): void {
    if (this.saveTimer !== -1) {
      clearTimeout(this.saveTimer)
    }
    this.saveTimer = setTimeout(async (): Promise<void> => {
      await this.persistNow()
    }, this.delay)
  }

  /**
   * 立即持久化（页面退出时调用）
   * 清除防抖定时器后立即写入，不触发 onScheduleFire
   */
  async flush(): Promise<void> {
    if (this.saveTimer !== -1) {
      clearTimeout(this.saveTimer)
      this.saveTimer = -1
    }
    await this.persistNow()
  }

  /**
   * 执行实际写入
   * @returns true 表示写入成功；false 表示写入抛异常（已记录日志，不向上抛）
   */
  private async persistNow(): Promise<boolean> {
    try {
      await this.persistFn()
      return true
    } catch (e) {
      Logger.error(this.tag, 'persistNow failed: ' + (e as Error).message)
      return false
    }
  }

  // 清理定时器，防止页面销毁后定时器仍然触发
  destroy(): void {
    if (this.saveTimer !== -1) {
      clearTimeout(this.saveTimer)
      this.saveTimer = -1
    }
    Logger.info(this.tag, 'destroy: saveTimer cleared')
  }
}