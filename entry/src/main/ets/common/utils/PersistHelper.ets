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
   */
  scheduleSave(): void {
    if (this.saveTimer !== -1) {
      clearTimeout(this.saveTimer)
    }
    this.saveTimer = setTimeout(async (): Promise<void> => {
      // 先确保本地落盘完成再触发云同步，避免云端读到旧数据
      await this.persistNow().catch((e: Error): void => {
        Logger.error(this.tag, 'scheduleSave persistNow failed: ' + e.message)
      })
      if (this.onScheduleFire !== null) {
        this.onScheduleFire()
      }
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
   * 执行实际写入，失败时记录告警日志
   * Preferences API 无事务，此处仅记录不抛出，避免防抖回调中断
   */
  private async persistNow(): Promise<void> {
    try {
      await this.persistFn()
    } catch (e) {
      Logger.error(this.tag, 'persistNow failed: ' + (e as Error).message)
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