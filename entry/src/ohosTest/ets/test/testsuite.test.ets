/**
 * @file 测试套件入口
 * @description 聚合所有单元测试
 * @module ohosTest
 * @date 2026-06-23
 */

import settingsViewModelTest from './SettingsViewModelTest.test.ets'
import profilePageIntegrationTest from './ProfilePageIntegrationTest.test.ets'

export default function testsuite(): void {
  settingsViewModelTest()
  profilePageIntegrationTest()
}
