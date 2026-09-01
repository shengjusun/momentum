/**
 * @file 华为智感握姿感知服务（真实实现版）
 * @description
*   - 使用 @kit.MultimodalAwarenessKit 的 motion 模块监听握姿变化
 *   - 申请 ohos.permission.DETECT_GESTURE 权限
 *   - 500ms 防抖避免传感器瞬间抖动
 *   - 降级策略：API 不可用 / 权限拒绝 → 回调 'unknown'，避免崩溃
 */
import { Logger } from '../utils/Logger'
import { motion } from '@kit.MultimodalAwarenessKit'
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit'

export type GripHand = 'left' | 'right' | 'unknown'
export type GripCallback = (hand: GripHand) => void

export class GripAwarenessService {
  private static readonly tag: string = 'GripAwarenessService'
  private static instance: GripAwarenessService | null = null

  private currentCallback: GripCallback | null = null
  private isSubscribed: boolean = false
  private debounceTimer: number = -1
  /** 缓存 context，避免在 Service 中调用 getContext(this) 失效 */
  private context: common.UIAbilityContext | null = null

  private constructor() {}

  static getInstance(): GripAwarenessService {
    if (GripAwarenessService.instance === null) {
      GripAwarenessService.instance = new GripAwarenessService()
    }
    return GripAwarenessService.instance
  }

  /**
   * 订阅握姿变化
   * - 必须由调用方传入 UIAbilityContext（Service 中 getContext(this) 无效）
   * - 内部自动检测权限，未授予时主动弹窗申请 requestPermissionsFromUser
   * - 申请被拒 / API 不可用 → 回调 'unknown'（UI 默认右下角）
   *
   * @param context - UIAbilityContext，由调用方页面传入
   * @param callback - 握姿变化回调
   */
  async subscribe(context: common.UIAbilityContext, callback: GripCallback): Promise<void> {
    this.currentCallback = callback
    this.context = context
    if (this.isSubscribed) return

    try {
      const atManager = abilityAccessCtrl.createAtManager()
      const permission: Permissions = 'ohos.permission.DETECT_GESTURE'

      // 1. 检查权限
      const grantStatus = await atManager.checkAccessToken(
        context.applicationInfo.accessTokenId, permission)
      if (grantStatus !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        Logger.info(GripAwarenessService.tag, 'subscribe: permission not granted, requesting...')
        // 2. 主动申请权限（弹窗），需在 UIAbilityContext 上调用
        const result = await atManager.requestPermissionsFromUser(context, [permission])
        if (result.authResults.length === 0 ||
            result.authResults[0] !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
          Logger.warn(GripAwarenessService.tag, 'subscribe: permission denied by user, fallback to unknown')
          this.notifyCallback('unknown')
          return
        }
        Logger.info(GripAwarenessService.tag, 'subscribe: permission granted by user')
      }

      this.doSubscribe()
      this.isSubscribed = true
      Logger.info(GripAwarenessService.tag, 'subscribe: success')
    } catch (e) {
      Logger.error(GripAwarenessService.tag, 'subscribe failed: ' + (e as Error).message)
      this.notifyCallback('unknown')
    }
  }

  /**
   * 实际调用 motion API 订阅握姿
   */
  private doSubscribe(): void {
    try {
      motion.on('holdingHandChanged', (data: motion.HoldingHandStatus): void => {
        let targetHand: GripHand = 'unknown'

        if (data === 1) {
          targetHand = 'left'
        } else if (data === 2) {
          targetHand = 'right'
        } else {
          // 0(未握持) 或 3(双手) 视为无效，直接返回不处理
          return
        }

        // 走到这里说明 targetHand 一定是 'left' 或 'right'，直接防抖处理
        if (this.debounceTimer !== -1) {
          clearTimeout(this.debounceTimer)
        }
        this.debounceTimer = setTimeout((): void => {
          this.notifyCallback(targetHand)
          this.debounceTimer = -1
        }, 500) as number
      })
    } catch (e) {
      Logger.warn(GripAwarenessService.tag, 'doSubscribe failed: ' + (e as Error).message)
      this.notifyCallback('unknown')
    }
  }

  /**
   * 注销订阅
   */
  unsubscribe(): void {
    this.currentCallback = null
    this.context = null
    if (this.debounceTimer !== -1) {
      clearTimeout(this.debounceTimer)
      this.debounceTimer = -1
    }
    if (!this.isSubscribed) return

    try {
      motion.off('holdingHandChanged')
      Logger.info(GripAwarenessService.tag, 'unsubscribe: success')
    } catch (e) {
      Logger.warn(GripAwarenessService.tag, 'unsubscribe non-fatal: ' + (e as Error).message)
    }
    this.isSubscribed = false
  }

  private notifyCallback(hand: GripHand): void {
    if (this.currentCallback !== null) {
      this.currentCallback(hand)
    }
  }
}