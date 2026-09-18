/**
 * @file Push Token 探针（**仅用于实况窗白名单设备配置**）
 * @description
 *   AGC「实况窗 → 白名单设备管理」要求**按 Push Token 添加白名单设备**（不是 UDID）。
 *   没有 token 就无法把调试设备加进实况窗白名单，而未加白名单的设备调用
 *   `startLiveView` 必然返回 `1003500005`（The right of liveView is not enabled）。
 *
 *   接入时机：仅在实况窗创建失败于 1003500005 时调用一次 —— 复现一次即可在
 *   hilog 里拿到 token，无需额外入口/按钮。
 *
 *   前置：AGC 必须已开通「推送服务」（增长 → 推送服务），否则 getToken 会报
 *   `80600003`（未开通）或 `1000900010`（身份验证失败）。
 *
 * @module common/utils
 */

import { pushService } from '@kit.PushKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { Logger } from './Logger'

/** 单次会话内是否已打印过 token（避免每次失败都刷日志） */
let logged: boolean = false

/**
 * 获取并打印 Push Token（失败时给出可直接执行的排查提示）
 */
export async function logPushTokenOnce(): Promise<void> {
  if (logged) {
    return
  }
  logged = true
  try {
    const token: string = await pushService.getToken()
    Logger.info('PushToken', '==== 复制下面这行到 AGC「实况窗 → 白名单设备管理」====')
    Logger.info('PushToken', token)
  } catch (e) {
    const err: BusinessError = e as BusinessError
    // 官方 pushService.getToken 错误码（@kit.PushKit）
    if (err.code === 1000900012) {
      Logger.error('PushToken', '取 Token 失败：推送权益未激活（1000900012）→ AGC「增长 → 推送服务」点「开通」')
    } else if (err.code === 1000900010) {
      Logger.error('PushToken', '取 Token 失败：非法的应用身份（1000900010）→ 换用 AGC 最新 agconnect-services.json')
    } else if (err.code === 1000900013) {
      Logger.error('PushToken', '取 Token 失败：跨地域应用不允许获取 Token（1000900013）→ 数据处理位置需设为「中国」')
    } else if (err.code === 1000900011) {
      Logger.error('PushToken', '取 Token 失败：网络不可用（1000900011）')
    } else {
      Logger.error('PushToken', '取 Token 失败：code=' + err.code.toString() + ', msg=' + err.message)
    }
  }
}
