/**
 * @file CloudDBSyncProxy - 云端同步代理拦截层（P0-privacy）
 * @description
 *   单例代理，封装对所有 CloudDB 网络请求的权限守卫。
 *   所有云端操作（upload / download / smartSync）必须通过此代理检查 canSync()，
 *   开关关闭时静默阻断，不产生任何出站流量。
 *
 *   使用方式：
 *   ```typescript
 *   // SettingsViewModel 在 init 和 toggle 时同步状态
 *   CloudDBSyncProxy.getInstance().setSyncEnabled(enabled)
 *
 *   // 所有云端调用前检查
 *   if (!CloudDBSyncProxy.getInstance().canSync()) {
 *     Logger.info(...', sync disabled, skip')
 *     return
 *   }
 *   ```
 *
 *   V2 规范：@ComponentV2 独立单例，无 @State / @Observed
 *   硬性约束：不直接 import ViewModel（避免循环依赖），由外部注入状态
 *
 * @module common/services
 * @date 2026-07-24
 */

import { Logger } from '../utils/Logger'

/**
 * 云端同步代理拦截层（单例）
 * - syncEnabled = false：阻断所有 CloudDB 网络请求
 * - syncEnabled = true：放行，同步行为完全由调用方原有逻辑控制
 */
export class CloudDBSyncProxy {
  private static readonly tag: string = 'CloudDBSyncProxy'
  private static instance: CloudDBSyncProxy | null = null

  /**
   * 云端同步总开关
   * - false（默认）：隐私优先，阻断所有上传/下载
   * - true：正常同步
   */
  private syncEnabled: boolean = false

  private constructor() {}

  static getInstance(): CloudDBSyncProxy {
    if (CloudDBSyncProxy.instance === null) {
      CloudDBSyncProxy.instance = new CloudDBSyncProxy()
    }
    return CloudDBSyncProxy.instance
  }

  /**
   * 更新云端同步开关状态
   * 由 SettingsViewModel 在以下时机调用：
   * - init() 中从 Preferences 恢复后
   * - toggleSyncEnabled() 用户切换开关时
   *
   * @param enabled - 新的开关状态
   */
  setSyncEnabled(enabled: boolean): void {
    const changed: boolean = this.syncEnabled !== enabled
    this.syncEnabled = enabled
    if (changed) {
      Logger.info(CloudDBSyncProxy.tag,
        'syncEnabled 已变更为: ' + (enabled ? '开启' : '关闭'))
    }
  }

  /**
   * 查询当前是否允许云端同步
   * 所有 CloudDB 网络操作（upload / download / smartSync）调用前必须先检查此方法
   *
   * @returns true=允许同步，false=已关闭云端同步
   */
  canSync(): boolean {
    return this.syncEnabled
  }

}
