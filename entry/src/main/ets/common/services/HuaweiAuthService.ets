// 华为账号登录服务，封装 @kit.AccountKit 的两步法合规登录（静默获取 openId + 显式授权获取 profile）

import { authentication } from '@kit.AccountKit'
import { common } from '@kit.AbilityKit'
import { Logger } from '../utils/Logger'
import { util } from '@kit.ArkTS'
import { http } from '@kit.NetworkKit'
import { fileIo as fs } from '@kit.CoreFileKit'
import { BusinessError } from '@kit.BasicServicesKit'

export interface HuaweiUserInfo {
  openId: string
  unionId: string
  nickname: string
  avatarUri: string
  email: string
  authorizationCode: string
  idToken: string
}

export interface HuaweiLoginResult {
  success: boolean
  user: HuaweiUserInfo | null
  errorMsg: string
}

export class HuaweiAuthService {
  private static readonly tag: string = 'HuaweiAuthService'
  private static instance: HuaweiAuthService | null = null

  private constructor() {}

  static getInstance(): HuaweiAuthService {
    if (HuaweiAuthService.instance === null) {
      HuaweiAuthService.instance = new HuaweiAuthService()
    }
    return HuaweiAuthService.instance
  }

  /** 清除本地登录缓存（登录失败/取消时调用，清理 cacheDir 下 avatar_*.jpg 头像缓存） */
  clearLocalCache(context: common.Context | null = null): void {
    if (context !== null) {
      try {
        const cacheDir: string = context.cacheDir
        const files: string[] = fs.listFileSync(cacheDir)
        let cleanedCount: number = 0
        for (let i: number = 0; i < files.length; i++) {
          const fileName: string = files[i]
          if (fileName.startsWith('avatar_') && fileName.endsWith('.jpg')) {
            try {
              fs.unlinkSync(`${cacheDir}/${fileName}`)
              cleanedCount++
            } catch (unlinkErr) {
              // 单个文件删除失败不阻断流程
              Logger.warn(HuaweiAuthService.tag, 'clearLocalCache: failed to delete ' + fileName +
                ': ' + (unlinkErr as Error).message)
            }
          }
        }
        Logger.info(HuaweiAuthService.tag, 'clearLocalCache: cleaned ' + cleanedCount.toString() +
          ' avatar cache files')
      } catch (e) {
        Logger.warn(HuaweiAuthService.tag, 'clearLocalCache: listFileSync failed: ' + (e as Error).message)
      }
    } else {
      Logger.info(HuaweiAuthService.tag, 'clearLocalCache: no context, skipped avatar cleanup')
    }
  }

  /**
   * 华为账号登录授权（两步法）
   * Step 1：静默登录获取 openId/unionId（不拉授权页，失败不阻断）
   *   - forceLogin=false：已授权过的用户无感知通过，新用户静默失败继续 Step 2
   *   - 目的：减少授权页弹出次数，已登录用户直接拿到 openId
   * Step 2：显式授权获取昵称、头像、authorizationCode、idToken
   *   - forceAuthorization=true：强制拉起华为 ID 授权页
   *   - scopes=['openid','profile']：合规要求，声明需要的用户信息范围
   *   - permissions=['serviceauthcode']：获取授权码供服务端换取 access_token
   *   - state=generateRandomUUID()：CSRF 防护，响应必须校验 state 一致
   */
  async login(context: common.Context): Promise<HuaweiLoginResult> {
    const result: HuaweiLoginResult = { success: false, user: null, errorMsg: '' }

    try {
      const provider: authentication.HuaweiIDProvider = new authentication.HuaweiIDProvider()
      const controller: authentication.AuthenticationController =
        new authentication.AuthenticationController(context)

      // Step 1：静默获取 openId（forceLogin=false，失败不阻断，由 Step 2 拉起授权页）
      let openId: string = ''
      let unionId: string = ''
      try {
        const loginRequest: authentication.LoginWithHuaweiIDRequest =
          provider.createLoginWithHuaweiIDRequest()
        loginRequest.forceLogin = false
        const loginResp = await controller.executeRequest(loginRequest) as authentication.LoginWithHuaweiIDResponse
        const loginCred = loginResp.data
        if (loginCred && loginCred.openID) {
          openId = loginCred.openID
          unionId = loginCred.unionID ?? ''
          Logger.info(HuaweiAuthService.tag, 'Step 1 silent login success, openId=' + this.maskPii(openId))
        } else {
          Logger.info(HuaweiAuthService.tag, 'Step 1 silent login returned empty openId, continue to Step 2')
        }
      } catch (e1) {
        // 未登录/未授权属预期失败，继续 Step 2
        const err1 = e1 as BusinessError
        Logger.info(HuaweiAuthService.tag, 'Step 1 silent login failed (expected if not logged in), code=' +
          err1.code.toString() + ', msg=' + err1.message + ', continue to Step 2')
      }

      // Step 2：显式授权获取 profile（scopes 含 openid+profile，forceAuthorization 拉起授权页）
      const authRequest: authentication.AuthorizationWithHuaweiIDRequest =
        provider.createAuthorizationWithHuaweiIDRequest()
      // 合规要求：scopes 包含 openid 和 profile
      authRequest.scopes = ['openid', 'profile']
      // serviceauthcode 用于服务端换取 access_token
      authRequest.permissions = ['serviceauthcode']
      authRequest.forceAuthorization = true
      // state 防 CSRF
      authRequest.state = util.generateRandomUUID()

      const resp = await controller.executeRequest(authRequest) as authentication.AuthorizationWithHuaweiIDResponse

      // CSRF 校验：state 不匹配说明响应可能被篡改，拒绝登录
      if (resp.state !== undefined && resp.state !== authRequest.state) {
        result.errorMsg = context.resourceManager.getStringByNameSync('login_error_state_csrf')
        Logger.error(HuaweiAuthService.tag, result.errorMsg)
        this.clearLocalCache(context)
        return result
      }

      const cred = resp.data
      if (!cred || !cred.openID) {
        result.errorMsg = context.resourceManager.getStringByNameSync('login_error_empty_openid')
        Logger.error(HuaweiAuthService.tag, result.errorMsg)
        this.clearLocalCache(context)
        return result
      }

      // 优先使用 Step 2 返回的 openId（更可靠），Step 1 作为兜底
      const finalOpenId: string = cred.openID ?? openId
      const finalUnionId: string = cred.unionID ?? unionId

      const credMap: Record<string, Object> = cred as Record<string, Object>
      const allKeys: string[] = Object.keys(credMap)
      Logger.info(HuaweiAuthService.tag, 'Step 2 cred keys count=' + allKeys.length.toString() +
        ', keys=[' + allKeys.join(', ') + ']')
      // 敏感凭证（authorizationCode/idToken）仅输出脱敏日志
      Logger.secure(HuaweiAuthService.tag, 'authorizationCode',
        (cred.authorizationCode ?? ''))
      Logger.secure(HuaweiAuthService.tag, 'idToken', (cred.idToken ?? ''))
      Logger.secure(HuaweiAuthService.tag, 'openId', finalOpenId)
      Logger.secure(HuaweiAuthService.tag, 'unionId', finalUnionId)

      // 兼容多版本 SDK 字段名差异：不同 HarmonyOS 版本返回的 nickname/avatarUri 键名可能不同
      // 遍历候选键名直到找到非空值，确保跨版本兼容
      const nicknameCandidates: string[] = ['nickname', 'nickName', 'Nickname', 'NICKNAME']
      const avatarCandidates: string[] = ['avatarUri', 'avatarUriString', 'avataruri', 'AvatarUri', 'photoUrl']
      let nickname: string = ''
      let avatarUri: string = ''
      let usedNickKey: string = ''
      let usedAvatarKey: string = ''
      for (let i: number = 0; i < nicknameCandidates.length; i++) {
        const key: string = nicknameCandidates[i]
        const val: Object | undefined = credMap[key]
        if (typeof val === 'string' && (val as string).length > 0) {
          nickname = val as string
          usedNickKey = key
          break
        }
      }
      for (let i: number = 0; i < avatarCandidates.length; i++) {
        const key: string = avatarCandidates[i]
        const val: Object | undefined = credMap[key]
        if (typeof val === 'string' && (val as string).length > 0) {
          avatarUri = val as string
          usedAvatarKey = key
          break
        }
      }
      Logger.info(HuaweiAuthService.tag, 'nickname resolved: key=' + usedNickKey +
        ', value=' + this.maskPii(nickname))
      Logger.info(HuaweiAuthService.tag, 'avatarUri resolved: key=' + usedAvatarKey +
        ', value=' + this.maskPii(avatarUri))

      result.success = true
      result.user = {
        openId: finalOpenId,
        unionId: finalUnionId,
        nickname,
        avatarUri,
        email: '',
        authorizationCode: cred.authorizationCode ?? '',
        idToken: cred.idToken ?? ''
      }

      Logger.info(HuaweiAuthService.tag,
        'login success (two-step), openId=' + this.maskPii(finalOpenId) +
          ', nickname=' + this.maskPii(nickname))
    } catch (e) {
      const err = e as BusinessError
      // 官方错误码：1001502012 为用户取消
      if (err.code === 1001502012) {
        result.errorMsg = context.resourceManager.getStringByNameSync('login_toast_user_cancelled')
        Logger.info(HuaweiAuthService.tag, 'login cancelled by user (code=1001502012)')
      } else if (err.code === 1001500001) {
        result.errorMsg = context.resourceManager.getStringByNameSync('login_error_cert_invalid')
        Logger.error(HuaweiAuthService.tag, result.errorMsg)
      } else {
        result.errorMsg = err.message ?? 'unknown error'
        Logger.error(HuaweiAuthService.tag, `login failed: code=${err.code}, msg=${err.message}`)
      }
      // 登录失败时清除本地缓存状态
      this.clearLocalCache(context)
    }
    return result
  }

  /**
   * 下载网络头像到本地缓存目录
   * 为什么需要缓存：华为 ID 返回的 avatarUri 是临时链接，会过期失效
   * 下载到 cacheDir/avatar_*.jpg 后，UI 用本地路径加载，避免链接过期后头像空白
   */
  async cacheAvatar(context: common.Context, avatarUri: string): Promise<string> {
    if (!avatarUri) return ''
    const cacheDir = context.cacheDir
    const fileName = `avatar_${util.generateRandomUUID()}.jpg`
    const localPath = `${cacheDir}/${fileName}`

    try {
      const httpReq = http.createHttp()
      const data = await httpReq.request(avatarUri, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 15000,
        readTimeout: 15000
      })
      httpReq.destroy()

      // 满足 ArkTS 强类型约束：instanceOf ArrayBuffer 可能失效，改为类型判断 + byteLength 校验
      if (data.responseCode === 200 && typeof data.result !== 'string' &&
        data.result !== null && data.result !== undefined) {
        const buffer: ArrayBuffer = data.result as ArrayBuffer
        if (buffer.byteLength > 0) {
          const file = fs.openSync(localPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE)
          fs.writeSync(file.fd, buffer)
          fs.closeSync(file)
          Logger.info(HuaweiAuthService.tag, 'cacheAvatar success: ' + localPath +
            ', bytes=' + buffer.byteLength.toString())
          return localPath
        } else {
          Logger.warn(HuaweiAuthService.tag, 'cacheAvatar: buffer byteLength is 0')
        }
      } else {
        Logger.warn(HuaweiAuthService.tag, 'cacheAvatar: responseCode=' + data.responseCode.toString() +
          ', result type invalid')
      }
    } catch (e) {
      Logger.error(HuaweiAuthService.tag, 'cacheAvatar failed: ' + (e as Error).message)
    }
    return ''
  }

  /** PII 信息日志脱敏：委托 Logger.mask 统一实现（空值差异由空串判断补齐） */
  private maskPii(value: string): string {
    if (value.length === 0) return '***'
    return Logger.mask(value)
  }

  /**
   * 撤销华为 ID 授权（退出登录时调用）
   * 撤销后下次登录需重新拉起授权页，用户头像/昵称需重新授权获取
   */
  async cancelAuthorization(context: common.Context): Promise<void> {
    try {
      const provider: authentication.HuaweiIDProvider = new authentication.HuaweiIDProvider()
      const controller: authentication.AuthenticationController =
        new authentication.AuthenticationController(context)

      const cancelRequest: authentication.CancelAuthorizationRequest =
        provider.createCancelAuthorizationRequest()
      await controller.executeRequest(cancelRequest)

      Logger.info(HuaweiAuthService.tag, 'cancelAuthorization success')
    } catch (e) {
      Logger.error(HuaweiAuthService.tag,
        'cancelAuthorization failed: ' + (e as Error).message)
    }
  }
}