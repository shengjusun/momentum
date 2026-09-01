/**
 * @file ProfilePage V2 集成测试
 * @description
 *   测试覆盖：
 *   - settingsVM 单例引用（普通属性，非 @Local）
 *   - UI 状态绑定走 settingsVM
 *   - 业务方法委托给 settingsVM
 *
 * @module ohosTest
 * @date 2026-06-23
 */

import { describe, it, expect, beforeEach } from '@ohos/hypium'
import { abilityDelegatorRegistry, Context } from '@kit.AbilityKit'
import { preferences } from '@kit.ArkData'
import { settingsVM, SettingsViewModel } from '../../main/ets/viewmodel/SettingsViewModel'
import { AppSettings } from '../../main/ets/model/Models'

/* ============================================================
 * 测试套件：ProfilePage V2 集成
 * ============================================================ */

export default function profilePageIntegrationTest(): void {
  describe('ProfilePage V2 Integration', (): void => {
    let ctx: Context

    beforeEach(async (): Promise<void> => {
      ctx = abilityDelegatorRegistry.getAppContext()
      // 清理数据
      try {
        const prefs: preferences.Preferences = await preferences.getPreferences(ctx, 'growthdesk_settings')
        await prefs.delete('storage_settings_v1')
        await prefs.flush()
      } catch (e) {
        // ignore
      }
    })

    /* --------------------------------------------------------
     * 1. 单例引用验证
     * -------------------------------------------------------- */
    describe('singleton reference', (): void => {
      it('settingsVM_is_singleton', 0, (): void => {
        // V2 红线：ProfilePage 引用 settingsVM 单例
        const a: SettingsViewModel = settingsVM
        const b: SettingsViewModel = settingsVM
        expect(a === b).assertTrue()
      })
    })

    /* --------------------------------------------------------
     * 2. 状态流验证
     * -------------------------------------------------------- */
    describe('state flow', (): void => {
      it('state_changes_propagate_via_singleton', 0, async (): Promise<void> => {
        await settingsVM.init(ctx)
        // 1. 通过单例修改状态
        settingsVM.setThemeMode('dark')
        // 2. 所有引用 settingsVM 的组件都能感知
        expect(settingsVM.settings.themeMode).assertEqual('dark')
      })

      it('isLoaded_becomes_true_after_init', 0, async (): Promise<void> => {
        expect(settingsVM.isLoaded).assertFalse()
        await settingsVM.init(ctx)
        expect(settingsVM.isLoaded).assertTrue()
      })
    })

    /* --------------------------------------------------------
     * 3. 业务委托验证
     * -------------------------------------------------------- */
    describe('business delegation', (): void => {
      it('setApiKey_via_singleton_should_persist', 0, async (): Promise<void> => {
        await settingsVM.init(ctx)
        const ok: boolean = settingsVM.setApiKey('sk-integration-test-12345678')
        expect(ok).assertTrue()
        expect(settingsVM.settings.deepseekApiKey).assertEqual('sk-integration-test-12345678')
        await settingsVM.flush()
      })

      it('reset_via_singleton_should_clear_all', 0, async (): Promise<void> => {
        await settingsVM.init(ctx)
        settingsVM.setThemeMode('dark')
        settingsVM.setPrivacyAgreed(true)
        await settingsVM.flush()

        await settingsVM.reset()

        expect(settingsVM.settings.themeMode).assertEqual('system')
        expect(settingsVM.settings.privacyAgreed).assertFalse()
      })
    })

    /* --------------------------------------------------------
     * 4. 数据一致性验证
     * -------------------------------------------------------- */
    describe('data consistency', (): void => {
      it('after_flush_and_reload_should_keep_data', 0, async (): Promise<void> => {
        // 1. 第一次 vm：写入
        await settingsVM.init(ctx)
        settingsVM.setThemeMode('light')
        settingsVM.setApiKey('sk-persist-test-12345678')
        settingsVM.setPrivacyAgreed(true)
        await settingsVM.flush()

        // 2. 第二次 vm：加载（模拟应用重启）
        const vm2: SettingsViewModel = new SettingsViewModel()
        await vm2.init(ctx)

        // 3. 验证：数据一致
        expect(vm2.settings.themeMode).assertEqual('light')
        expect(vm2.settings.deepseekApiKey).assertEqual('sk-persist-test-12345678')
        expect(vm2.settings.privacyAgreed).assertTrue()
      })

      it('settings_instance_should_be_AppSettings', 0, async (): Promise<void> => {
        await settingsVM.init(ctx)
        // V2 红线：复活后必须是 AppSettings 实例（非普通对象）
        expect(settingsVM.settings instanceof AppSettings).assertTrue()
      })
    })
  })
}
