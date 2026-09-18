/**
 * 登录页：冷启动路由守卫未通过时跳转到此页
 * 登录主线：handleLogin → doLogin → settingsVM.handleHuaweiLogin → HuaweiAuthService.login(两步)
 * → applyLoginResult(持久化+云同步) → auth.signIn(AGC云端) → globalNavStack.pop(返回MainTab)
 */

import { globalNavStack } from '../common/RouterManager'
import { AppInfoDialog } from '../common/components/AppInfoDialog'
import { DimensConstants } from '../common/constants/DimensConstants'
import { HuaweiAuthService } from '../common/services/HuaweiAuthService'
import { settingsVM } from '../viewmodel/SettingsViewModel'
import { Logger } from '../common/utils/Logger'
import { promptAction } from '@kit.ArkUI'
import { common } from '@kit.AbilityKit'
import { safeAreaHelper } from '../common/utils/SafeAreaHelper'
import { CommonConstants } from '../common/constants/CommonConstants'
import { MotionHelper } from '../common/utils/MotionHelper'


@ComponentV2
export struct LoginPage {
  @Local isLoggingIn: boolean = false
  @Local isCheckingLogin: boolean = true
  /** 隐私协议长文弹窗 */
  @Local showPrivacyDialogVisible: boolean = false
  /** 用户协议长文弹窗（独立内容源，此前两链接共用隐私文案属合规缺陷） */
  @Local showUserAgreementVisible: boolean = false
  // 隐私协议勾选态：未勾选时登录按钮置灰不可点击
  @Local isPrivacyAgreed: boolean = false

  // 异步 await 后检查 isAttached 状态
  private isAttached: boolean = false

  private loginDebounceTimer: number = -1

  // 异步 await 后检查 isAttached 状态
  aboutToAppear(): void {
    this.isAttached = true
  }

  aboutToDisappear(): void {
    // 异步 await 后检查 isAttached 状态
    this.isAttached = false
    if (this.loginDebounceTimer !== -1) clearTimeout(this.loginDebounceTimer)
  }

  /**
   * NavDestination 就绪回调：检查本地持久化登录态
   * 已登录 → pop() 旁路（用户无感知直接进首页，场景：热启动时路由守卫二次检查）
   * 未登录 → 显示登录 UI
   */
  private onDestinationReady(context: NavDestinationContext): void {
    if (settingsVM.userProfile.isLoggedIn && settingsVM.userProfile.huaweiUid.length > 0) {
      Logger.info('LoginPage', 'already logged in, pop to main')
      this.isCheckingLogin = false
      globalNavStack.pop()
      return
    }
    this.isCheckingLogin = false
    Logger.info('LoginPage', 'not logged in, show login UI')
  }

  /**
   * 华为账号登录（防抖 + 异常处理），未勾选隐私协议时拦截
   */
  private handleLogin(): void {
    if (!this.isPrivacyAgreed) return
    if (this.isLoggingIn) return
    if (this.loginDebounceTimer !== -1) clearTimeout(this.loginDebounceTimer)

    this.loginDebounceTimer = setTimeout((): void => {
      this.loginDebounceTimer = -1
      this.doLogin()
    }, 300)
  }

  /**
   * 登录核心流程（异步）
   * Step 1: settingsVM.handleHuaweiLogin → HuaweiAuthService 两步登录 → applyLoginResult 持久化
   * Step 2: auth.signIn(AGC 云端登录) → 让 cloudFunction/cloudStorage 请求携带用户身份
   * Step 3: globalNavStack.pop() → 返回 MainTab 首页
   * Step 4: 弹出欢迎提示
   * isAttached 检查：await 后组件可能已销毁（用户快速返回），避免更新已销毁组件的 UI
   */
  private async doLogin(): Promise<void> {
    this.isLoggingIn = true

    try {
      // Step 1: 华为 ID 两步登录 + 持久化 UserProfile + 触发云同步
      const success: boolean = await settingsVM.handleHuaweiLogin(getContext(this) as common.Context)

      // isAttached 守卫：await 后组件可能已被销毁（用户快速返回），跳过后续 UI 操作
      if (!this.isAttached) return

      if (success) {
        Logger.info('LoginPage', 'login success, openId=' + settingsVM.userProfile.huaweiUid)

        // AGC 云端会话已在 settingsVM.handleHuaweiLogin 内部（华为账号授权后、落库同步前）建立

        // Step 3: 返回 MainTab 首页（路由栈 pop 揭露底层的 Tabs）
        globalNavStack.pop()

        // Step 4: 弹出欢迎提示
        promptAction.showToast({
          message: getContext(this).resourceManager.getStringSync($r('app.string.login_toast_welcome_prefix').id) + settingsVM.userProfile.nickname
        })
      } else {
        // 登录失败或取消，展示 VM 暴露的提示语
        const errMsg: string = settingsVM.toastMessage.length > 0 ? settingsVM.toastMessage : getContext(this).resourceManager.getStringSync($r('app.string.login_toast_user_cancelled').id)
        promptAction.showToast({
          message: getContext(this).resourceManager.getStringSync($r('app.string.login_toast_login_failed_prefix').id) + errMsg
        })
        // 清空 VM 的提示信息，防止下次重复弹出
        settingsVM.toastMessage = ''
        Logger.warn('LoginPage', 'login failed: ' + errMsg)
      }
    } catch (e) {
      const err: Error = e as Error
      promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.login_toast_login_error_prefix').id) + getContext(this).resourceManager.getStringSync($r('app.string.error_generic_toast').id), duration: 2000 })
      Logger.error('LoginPage', 'login threw: ' + err.message)
    } finally {
      this.isLoggingIn = false
    }
  }

  /**
   * 显示隐私协议弹窗（隐私协议/用户协议共用同一内容）
   */
  private showPrivacyDialog(): void {
    // 统一 AppInfoDialog：隐私长文可滚动阅读（替代系统 showDialog）
    this.showPrivacyDialogVisible = true
  }

  build() {
    NavDestination() {
      Column() {
        // ============ 顶部留白（推动 Logo 至约 1/3 位置）============
        Column() {}
        .layoutWeight(1)

        // ============ Logo 卡片 + 应用名称 区域 ============
        Column({ space: 12 }) {
          // Logo 卡片：app_icon 外裹圆角卡片 + 轻阴影
          Stack() {
            Image($r('app.media.app_icon'))
              .width(72)
              .height(72)
              .borderRadius(18)
              .objectFit(ImageFit.Cover)
          }
          .width(96)
          .height(96)
          .borderRadius(DimensConstants.RADIUS_XL)
          .backgroundColor($r('app.color.login_logo_card_bg'))
          .shadow({
            radius: 24,
            color: $r('app.color.login_logo_card_shadow'),
            offsetX: 0,
            offsetY: 8
          })
          .alignContent(Alignment.Center)

          // 应用名称 起势（大字号粗体）
          Text($r('app.string.app_name'))
            .fontSize(CommonConstants.FONT_SIZE_XXXL)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .textAlign(TextAlign.Center)

          // 英文副标 Momentum（小字号次要色）
          Text($r('app.string.login_brand_name_sub'))
            .fontSize(CommonConstants.FONT_SIZE_BODY)
            .fontColor($r('app.color.text_tertiary'))
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .padding({ left: 32, right: 32 })

        // ============ 中部留白 + 价值主张 ============
        Column() {}
        .layoutWeight(0.8)

        // 价值主张文案
        Text($r('app.string.login_value_prop'))
          .fontSize(CommonConstants.FONT_SIZE_BODY)
          .fontColor($r('app.color.text_secondary'))
          .textAlign(TextAlign.Center)
          .padding({ left: 32, right: 32 })

        Column() {}
        .layoutWeight(1.2)

        // ============ 底部登录按钮 + 隐私勾选 区域 ============
        Column({ space: 16 }) {
          // 登录态检查中：顶部 Loading
          if (this.isCheckingLogin) {
            LoadingProgress()
              .width(32)
              .height(32)
              .color($r('app.color.primary_color'))
              .margin({ bottom: 4 })
          }

          // 登录按钮（胶囊形 + 主题色 + 柔和阴影）
          Button() {
            Row({ space: 10 }) {
              Text($r('app.string.app_name'))
                .fontSize(CommonConstants.FONT_SIZE_XXS)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.primary_color'))
                .backgroundColor($r('app.color.primary_color_bg'))
                .borderRadius(DimensConstants.RADIUS_XS)
                .padding({ left: 6, right: 6, top: 3, bottom: 3 })

              if (this.isLoggingIn) {
                LoadingProgress()
                  .width(18)
                  .height(18)
                  .color($r('app.color.text_inverse'))
              }

              // 按钮文案：登录中... / 华为账号一键登录
              Text(this.isLoggingIn ? $r('app.string.btn_logging_in') : $r('app.string.login_btn_huawei'))
                .fontSize(CommonConstants.FONT_SIZE_SUBTITLE)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_inverse'))
            }
            .justifyContent(FlexAlign.Center)
          }
          .width('100%')
          .height(52)
          .backgroundColor(this.isPrivacyAgreed ? $r('app.color.primary_color') : $r('app.color.primary_color_disabled'))
          .borderRadius(26)
          .shadow({
            radius: 12,
            color: $r('app.color.shadow_dialog'),
            offsetX: 0,
            offsetY: 4
          })
          .enabled(this.isPrivacyAgreed && !this.isLoggingIn && !this.isCheckingLogin)
          .accessibilityText(this.isLoggingIn ? $r('app.string.btn_logging_in') : $r('app.string.acc_login_huawei_button'))
          .onClick((): void => {
            this.handleLogin()
          })

          // 合规改造：「暂不登录」出口（细则要求登录页必须提供可拒绝的选项，不得强制登录）
          Text($r('app.string.login_skip'))
            .fontSize(CommonConstants.FONT_SIZE_CAPTION)
            .fontColor($r('app.color.text_tertiary'))
            .textAlign(TextAlign.Center)
            .width('100%')
            .padding({ top: 12, bottom: 12 })
            .onClick((): void => {
              globalNavStack.pop()
            })

          // 隐私协议勾选行：Checkbox + "我已阅读并同意《隐私协议》和《用户协议》"
          // 勾选区外包 44vp 热区（触控规范；合规关键控件不应难点）
          // 范式对齐首页 CheckboxComponent：Checkbox 纯视觉（select 绑定状态），外层热区点击驱动状态
          Row({ space: 8 }) {
            Row() {
              Checkbox()
                .select(this.isPrivacyAgreed)
                .selectedColor($r('app.color.primary_color'))
                .width(16)
                .height(16)
            }
            .constraintSize({ minWidth: DimensConstants.TOUCH_COMFORT, minHeight: DimensConstants.TOUCH_COMFORT })
            .justifyContent(FlexAlign.Center)
            .alignItems(VerticalAlign.Center)
            .hitTestBehavior(HitTestMode.Block)
            .onClick((): void => {
              this.isPrivacyAgreed = !this.isPrivacyAgreed
            })

            Row() {
              Text($r('app.string.login_privacy_check_prefix'))
                .fontSize(CommonConstants.FONT_SIZE_XS)
                .fontColor($r('app.color.text_tertiary'))
              Text($r('app.string.privacy_link'))
                .fontSize(CommonConstants.FONT_SIZE_XS)
                .fontColor($r('app.color.primary_color'))
                .onClick((): void => {
                  this.showPrivacyDialog()
                })
              Text($r('app.string.login_privacy_check_and'))
                .fontSize(CommonConstants.FONT_SIZE_XS)
                .fontColor($r('app.color.text_tertiary'))
              Text($r('app.string.login_privacy_link_user'))
                .fontSize(CommonConstants.FONT_SIZE_XS)
                .fontColor($r('app.color.primary_color'))
                .onClick((): void => {
                  // 独立《用户协议》（此前与隐私协议共用同一弹窗，内容张冠李戴）
                  this.showUserAgreementVisible = true
                })
            }
            .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .accessibilityText($r('app.string.acc_login_privacy_checkbox'))
        }
        .width('100%')
        .padding({
          left: 36,
          right: 36,
          bottom: safeAreaHelper.getBottomWith(48)
        })
      }
      .width('100%')
      .height('100%')
      // 淡渐变背景：bg_page → primary_color_bg 轻微过渡，增加层次感
      .linearGradient({
        angle: 180,
        colors: [
          [$r('app.color.login_gradient_start'), 0.0],
          [$r('app.color.login_gradient_end'), 1.0]
        ]
      })
      // 页面转场交给系统路由转场独占（原裸 OPACITY 无 animation 参数，实际从未生效）；
      // IDENTITY 同时防止被外层 animateTo 补上默认透明度转场
      .transition(MotionHelper.noTransition())

      // 隐私协议长文弹窗（统一 AppInfoDialog，替代系统 showDialog）
      if (this.showPrivacyDialogVisible) {
        AppInfoDialog({
          title: getContext(this).resourceManager.getStringSync($r('app.string.privacy_agree_title').id),
          message: getContext(this).resourceManager.getStringSync($r('app.string.privacy_content').id),
          closeText: getContext(this).resourceManager.getStringSync($r('app.string.privacy_agree_ack').id),
          onClose: (): void => {
            this.showPrivacyDialogVisible = false
          }
        })
      }

      // 用户协议长文弹窗（独立文案，含 AI 服务专项条款与 DeepSeek 备案号）
      if (this.showUserAgreementVisible) {
        AppInfoDialog({
          title: getContext(this).resourceManager.getStringSync($r('app.string.user_agreement_title').id),
          message: getContext(this).resourceManager.getStringSync($r('app.string.user_agreement_content').id),
          closeText: getContext(this).resourceManager.getStringSync($r('app.string.privacy_agree_ack').id),
          onClose: (): void => {
            this.showUserAgreementVisible = false
          }
        })
      }
    }
    .hideTitleBar(true)
    // 合规改造（2026-09-11）：允许返回。
    // 《华为帐号登录管理细则》要求登录页必须提供清晰的取消/拒绝选项，不得把用户锁在登录流程中；
    // 未登录用户本就以游客身份使用应用，返回应放行。仅登录请求进行中时拦截，避免中途退出导致状态错乱。
    .onBackPressed((): boolean => {
      if (this.isCheckingLogin || this.isLoggingIn) {
        return true
      }
      return false
    })
    .onReady((context: NavDestinationContext): void => {
      this.onDestinationReady(context)
    })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
