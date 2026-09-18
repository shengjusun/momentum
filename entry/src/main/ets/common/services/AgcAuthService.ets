/**
 * @file AGC 认证会话保障服务
 * @description 云数据库/云函数以「认证用户」身份鉴权：若没有 AGC 登录会话，请求会被判为
 *              World（所有人）角色，而 schema 中 World 无任何权限，服务端返回 2001015，
 *              表现为「云数据库无法使用」。本服务在执行云端操作前确保 AGC 已建立登录会话。
 */
import auth from '@hw-agconnect/auth'
import { Logger } from '../utils/Logger'

export class AgcAuthService {
  private static readonly TAG: string = 'AgcAuthService'

  private constructor() {}

  /**
   * 是否已存在 AGC 登录用户（只读检查，不触发任何授权 UI）
   */
  static async hasUser(): Promise<boolean> {
    try {
      const user = await auth.getCurrentUser()
      return user !== null && user !== undefined
    } catch (e) {
      Logger.warn(AgcAuthService.TAG, 'getCurrentUser failed: ' + (e as Error).message)
      return false
    }
  }

  /**
   * 确保 AGC 已建立登录会话：
   * - 已有用户：直接返回 true（复用 SDK 缓存的会话，通常静默）
   * - 无用户：用华为账号(hwid)补登一次
   * 必须在任何云数据库/云函数操作之前调用，否则请求会以匿名身份被拒绝(2001015)。
   *
   * @returns true 表示已具备「认证用户」身份，可安全访问云端
   */
  static async ensureSignedIn(): Promise<boolean> {
    if (await AgcAuthService.hasUser()) {
      return true
    }
    try {
      await auth.signIn({
        autoCreateUser: true,
        credentialInfo: {
          kind: 'hwid'
        }
      })
      Logger.info(AgcAuthService.TAG, 'AGC signIn success')
      return true
    } catch (e) {
      Logger.error(AgcAuthService.TAG,
        'AGC signIn failed (cloud unavailable): ' + (e as Error).message)
      return false
    }
  }

  /**
   * 清除本地 AGC 会话（**鉴权失败自愈专用**）
   *
   * 为什么必须有它：`ensureSignedIn()` 只要 `getCurrentUser()` 非空就直接返回 true，
   * 而缓存的会话 token 可能**已被服务端拒绝**（CloudDB 报 `1008231001 /
   * 401 third access token auth failed`）。此时若不清掉这个"僵尸会话"，
   * signIn 分支永远不会执行，客户端会一直以为自己已登录 ——
   * 表现为「云端永远 401，连退出登录再登录都无救，只能卸载重装」。
   *
   * 调用时机：仅在云端调用**确认**因鉴权被拒之后（见 CloudDBService.healAgcSession）。
   */
  static async resetSession(): Promise<void> {
    try {
      await auth.signOut()
      Logger.warn(AgcAuthService.TAG, 'AGC session cleared (signOut), ready to re-sign-in')
    } catch (e) {
      // signOut 失败不影响后续 signIn：下一次 ensureSignedIn 仍会尝试重建
      Logger.warn(AgcAuthService.TAG, 'signOut failed (ignored): ' + (e as Error).message)
    }
  }
}
