# Momentum 应用全面深度诊断综合分析报告

> 汇总人：产品与架构师  
> 日期：2026-09-16  
> 项目路径：D:\harmony\Project\s\Application  
> 应用包名：com.sunshengju.momentum  
> 版本：1.0.0 (versionCode: 1000000)  
> 基于 5 份独立分析报告综合而成

---

## 一、报告来源

| # | 报告 | 分析人 | 文件路径 | 问题统计 |
|---|------|--------|----------|----------|
| 1 | 架构与代码质量深度分析 | 产品与架构师 | `.team/analysis-architecture.md` | 10 维度, 12 项建议 |
| 2 | UI/UX 与前端体验深度分析 | 客户端工程师 | `.team/analysis-uiux.md` | 3 严重 / 8 中等 / 7 轻微 / 6 建议 |
| 3 | 云服务与数据层深度分析 | 服务端工程师 | `.team/analysis-backend.md` | 1 严重 / 15 中等 / 7 轻微 |
| 4 | 质量与性能深度分析 | 质量工程师 | `.team/analysis-quality.md` | 3 严重 / 9 中等 / 7 轻微 / 6 建议 |
| 5 | 构建配置与发布就绪深度分析 | 发布工程师 | `.team/analysis-release.md` | 3 严重 / 7 中等 / 5 轻微 / 5 建议 |

---

## 二、总体评价

Momentum 是一款基于 HarmonyOS（ArkTS + Stage 模型, API 23）任务/目标管理应用，采用纯 V2 状态管理体系（@ComponentV2/@Local/@Param/@Trace/@Computed），具备 4 级目标-任务架构、AI 智能拆解、云同步、番茄钟、桌面卡片等丰富功能。

### 核心亮点

1. **架构分层清晰**：L1 目标 → L2 任务 → L3 步骤 → L4 待办，通过 relatedTaskId/relatedGoalId 关联，工厂/水合/快照三件套模式统一
2. **状态管理规范**：@ObservedV2 + @Trace + @Computed V2 装饰器体系，DTO + 代理分离，全面的类型容错和向后兼容
3. **安全性优秀**：API Key 通过云函数中转隔离，PII 日志脱敏，隐私协议后延迟初始化云端 SDK，同步开关默认关闭
4. **可靠性完善**：AGC 会话自愈机制、冷启动恢复、离线暂存+自动补传、番茄钟三层计时保障
5. **同步设计成熟**：canonical JSON 指纹免疫键序差异，墓碑模式软删除，两阶段原子性应用云端数据
6. **UI/UX 水准较高**：设计令牌体系完善，三态覆盖规范，响应式布局，可访问性支持，交互细节丰富
7. **文档非常完善**：上架全流程文档、技术方案、合规文档、软著材料齐全

### 核心问题

1. **发布就绪度不足**：无 Release 签名证书、受限权限未解决、代码混淆未启用，综合发布就绪评分仅 5.3/10
2. **数据同步风险**：非顶层字段不递归合并，多设备同步时里程碑/子任务修改可能丢失
3. **代码质量隐患**：ViewModel God Object、定时器泄漏、代码大量重复、@Computed 性能开销
4. **UI/UX 矛盾**：RoutePage 强制登录与游客模式矛盾、i18n 破坏、多指触摸竞态

### 综合评分

| 维度 | 评分 | 说明 |
|------|------|------|
| 架构设计 | ⭐⭐⭐⭐ (4/5) | 分层清晰，状态管理规范，但 ViewModel 过大 |
| UI/UX 体验 | ⭐⭐⭐⭐ (4/5) | 设计令牌完善，交互丰富，但存在策略矛盾 |
| 云服务与数据层 | ⭐⭐⭐⭐ (4/5) | 安全性可靠性优秀，但同步合并策略有数据丢失风险 |
| 代码质量 | ⭐⭐⭐½ (3.5/5) | 整体中上，但定时器管理/代码重复/性能有改进空间 |
| 发布就绪度 | ⭐⭐½ (2.7/10) | 签名/权限/混淆/主题多项阻塞，未达发布标准 |
| **综合** | **⭐⭐⭐½ (3.5/5)** | **功能丰富架构成熟，但发布前需解决多项阻塞问题** |

---

## 三、严重问题汇总（10 项）

### S1. build-profile.json5 硬编码签名路径且仅有调试证书

- **来源**：架构分析 (P0) + 发布分析 (S1/M4)
- **文件**：`build-profile.json5` 第 8-14 行
- **问题描述**：签名配置使用机器特定的绝对路径（`D:/HuaweiMoveData/...`），profile 文件名含 `Debug` 明确是调试证书，且未创建 Release 签名证书
- **影响**：换机器构建必然失败；无法构建可上架的 release 包；构建配置不在版本控制中
- **改进建议**：
  1. 在 AGC 控制台创建正式签名证书和 Profile
  2. 将签名文件路径改为相对路径
  3. 提供 `build-profile.template.json5` 模板纳入版本控制

### S2. RoutePage 未登录时强制跳转登录页，与游客模式矛盾

- **来源**：UI/UX 分析 (S1)
- **文件**：`pages/RoutePage.ets` 第 848-852 行 / 第 883-886 行
- **问题描述**：MainTab 已移除冷启动强制登录，未登录用户以游客身份进入。但 RoutePage 仍保留 `if (!isLoggedIn) { navigateTo(LOGIN); return }` 强制跳转逻辑
- **影响**：游客模式下首页可用、路线页不可用，体验严重割裂；违反华为帐号登录管理细则
- **改进建议**：移除 RoutePage 强制登录跳转，改为需要云功能时就地引导登录

### S3. StatsPage 硬编码中文字符串，破坏 i18n

- **来源**：UI/UX 分析 (S2)
- **文件**：`pages/StatsPage.ets` 第 57-68 行
- **问题描述**：`buildGlobalSummary()` 直接硬编码中文（`'目标总数：' + ...`），未走 `$r('app.string.*')` 资源引用
- **影响**：英文环境下 AI 复盘数据仍以中文发送，AI 回复语言与界面语言不一致
- **改进建议**：替换为资源引用，或改为纯数据结构传给 AI

### S4. HomePage 四象限拖拽多指触摸竞态

- **来源**：UI/UX 分析 (S3)
- **文件**：`pages/HomePage.ets` 第 797-854 行
- **问题描述**：`longPressTimerId` 和 `touchStartScreenX/Y` 是单一变量，多指触摸时会被覆盖，导致拖拽指向错误象限
- **影响**：多指触摸时四象限可能错误交换，数据持久化后用户排序被意外打乱
- **改进建议**：改为单指锁定模式，`onTouch` Down 时若 `draggingIndex !== -1` 则忽略新触摸

### S5. 同步合并非顶层字段不递归，里程碑/子任务修改可能丢失

- **来源**：云服务分析 (S1)
- **文件**：`common/services/CloudSyncService.ets` 第 449-533 行
- **问题描述**：`mergeTopLevelArray` 只对顶层 `goals` 和 `taskList` 做条目级并集合并，里程碑/L2任务/L3步骤不递归合并，整块跟随所属目标
- **影响**：设备 A 修改目标 X 的里程碑 M1，设备 B 修改同一目标的里程碑 M2，updatedAt 不同时另一端修改完全丢失
- **改进建议**：对里程碑和子任务实现 id 级并集合并（至少一层递归）

### S6. HomeViewModel.nowTimerId 定时器永不清理

- **来源**：质量分析 (#1)
- **文件**：`viewmodel/HomeViewModel.ets` 第 362-366 行
- **问题描述**：`nowTimerId` 在 `init()` 中创建后从未被 `clearInterval` 清理，HomeViewModel 是全局单例
- **影响**：当前因单例生命周期等同进程而无实际泄漏，但架构变更后将成为泄漏源
- **改进建议**：添加 `destroy()` 方法清理，在 `EntryAbility.onDestroy` 中调用

### S7. DeadlineReminderService 任务/目标提醒逻辑大量重复（~140 行）

- **来源**：质量分析 (#2)
- **文件**：`common/services/DeadlineReminderService.ets` 第 259-608 行
- **问题描述**：`scheduleTaskDeadlineReminder` 与 `scheduleGoalDeadlineReminder` 约 140 行代码几乎完全一致，`rescheduleAll` 与 `rescheduleAllGoals` 也是复制粘贴
- **影响**：维护成本高，修改一处需同步修改另一处，易出错
- **改进建议**：抽取 `scheduleDeadlineReminderInternal(item, config)` 通用方法，可减少约 150 行重复代码

### S8. notifyFormUpdate 每次持久化都写文件

- **来源**：质量分析 (#3)
- **文件**：`viewmodel/HomeViewModel.ets` 第 516-592 行
- **问题描述**：`notifyFormUpdate` 在每次 `persistData` 后同步写文件 + 异步读 preferences + 异步 updateForm，防抖 200ms
- **影响**：无桌面卡片的用户产生完全浪费的文件 IO
- **改进建议**：检测是否有已添加的 formId（缓存结果），无卡片时跳过文件写入

### S9. DETECT_GESTURE 受限权限未解决

- **来源**：发布分析 (S2)
- **文件**：`entry/src/main/module.json5` 第 91-98 行
- **问题描述**：`DETECT_GESTURE` 是 system_basic 级别受限权限，普通应用无法直接获取，README 确认未解决
- **影响**：上架审核时可能被拒绝，或权限运行时始终被拒绝导致功能异常
- **改进建议**：向华为申请 AGC 白名单，或移除权限声明和握姿检测功能

### S10. agconnect-services.json 在 rawfile 中存在副本

- **来源**：发布分析 (S3)
- **文件**：`entry/src/main/resources/rawfile/agconnect-services.json`
- **问题描述**：AGC 配置文件被打包进 HAP，包含加密的 client_secret 和 api_key，可从 HAP 中提取
- **影响**：敏感信息暴露面增大，可能与 entry/agconnect-services.json 不同步
- **改进建议**：确认 rawfile 副本是否必要，不必要则删除；必要则确保两份同步

---

## 四、中等问题汇总（40 项）

### 4.1 架构与代码组织（2 项）

| # | 问题 | 文件 | 位置 |
|---|------|------|------|
| A-M1 | ViewModel God Object：HomeViewModel/SettingsViewModel/ProfileViewModel 均 > 900 行 | viewmodel/*.ets | — |
| A-M2 | AppEventBus 无自动清理机制、无类型约束 | common/event/AppEventBus.ets | — |

### 4.2 UI/UX 与前端体验（8 项）

| # | 问题 | 文件 | 位置 |
|---|------|------|------|
| U-M1 | 首页四象限卡片嵌套重复的 EisenhowerQuadrantCardBuilder 定义 | pages/HomePage.ets | L695-869 |
| U-M2 | AI 页打字机效果页面销毁时可能遗漏定时器清理 | pages/AIPage.ets | L570-583 |
| U-M3 | 隐私弹层协议正文单一 string 资源，长文本可读性差 | common/components/PrivacyConsentOverlay.ets | L29-38 |
| U-M4 | RoutePage 目标卡片展开/收起缺少过渡动画 | pages/RoutePage.ets | L159-174 |
| U-M5 | CommonTitleBar 标题居中时返回按钮占位导致视觉偏移 | common/components/CommonTitleBar.ets | L46-53 |
| U-M6 | 设置页缓存清理缺少加载态反馈和防重入 | pages/SettingPage.ets | L152-172 |
| U-M7 | 首页 FAB 悬浮按钮初始渲染时位置可能跳跃 | pages/HomePage.ets | L300-312, L1481-1488 |
| U-M8 | AI 页历史消息通过字符串匹配过滤错误消息，逻辑脆弱 | pages/AIPage.ets | L565-568 |

### 4.3 云服务与数据层（15 项）

| # | 问题 | 文件 | 位置 |
|---|------|------|------|
| B-M1 | CloudDBSyncProxy 拦截未强制执行，依赖调用方自觉检查 | CloudDBSyncProxy.ets | L62-79 |
| B-M2 | settings/profile 合并策略过于简单（本地优先/云端优先） | CloudSyncService.ets | L263-264 |
| B-M3 | CloudDBService init 非并发安全 | CloudDBService.ets | L144-165 |
| B-M4 | 取消机制仅丢弃结果不中断网络请求 | DeepSeekService.ets | L154-157 |
| B-M5 | 错误分类硬编码中文关键词匹配 | DeepSeekService.ets | L922-928 |
| B-M6 | isCancelled 标志多请求共享导致竞态 | DeepSeekService.ets | L943 |
| B-M7 | parseTaskPriority 数字映射不一致（序列化/反序列化方向相反） | BaseTypes.ets | L26-30 vs L44-54 |
| B-M8 | 本地存储无加密，敏感数据明文存于 Preferences | StorageManager.ets | 全文件 |
| B-M9 | hashTaskIdToNotificationId 可能碰撞 | DeadlineReminderService.ets | L79-86 |
| B-M10 | cacheAvatar 无文件大小限制 | HuaweiAuthService.ets | L225-263 |
| B-M11 | loadSession state 类型断言宽松 | PomodoroService.ets | L1330 |
| B-M12 | GripAwarenessService 单回调不支持多订阅 | GripAwarenessService.ets | L20 |
| B-M13 | 握姿权限弹窗自动触发 | GripAwarenessService.ets | L57-65 |
| B-M14 | ensureSignedIn 不校验 token 有效性 | AgcAuthService.ets | L37-38 |
| B-M15 | saveData 无 JSON 大小限制 | StorageManager.ets | L227 |

### 4.4 质量与性能（9 项）

| # | 问题 | 文件 | 位置 |
|---|------|------|------|
| Q-M1 | BusinessError 错误类过于简陋，无错误码常量 | BusinessError.ets | L1-10 |
| Q-M2 | DeadlineReminderService.persistTimer 未提供清理出口 | DeadlineReminderService.ets | L165-174 |
| Q-M3 | @Computed liveTasks 每次调用重建数组，多 @Computed 级联重算 | HomeViewModel.ets | L115-125 |
| Q-M4 | eisenhowerMatrix 每分钟全量重算 | HomeViewModel.ets | L230-272 |
| Q-M5 | CloudSyncService.requestMerge inFlight 竞态窗口 | CloudSyncService.ets | L160-174 |
| Q-M6 | PushTokenProbe Token 明文日志 | PushTokenProbe.ets | L33-35 |
| Q-M7 | JSON.parse as T 泛型断言无运行时校验 | StorageManager.ets | L291 |
| Q-M8 | AiGoalFactory 空任务列表生成"0 周"无意义展示 | AiGoalFactory.ets | L45-201 |
| Q-M9 | PriorityUtils 与 HomeViewModel 艾森豪威尔逻辑重复 | PriorityUtils.ets:46 vs HomeViewModel.ets:230 | — |

### 4.5 构建配置与发布（6 项）

| # | 问题 | 文件 | 位置 |
|---|------|------|------|
| R-M1 | Release 模式代码混淆未启用 | entry/build-profile.json5 | L24 |
| R-M2 | 浅色主题颜色配置极不完整（仅 1 项 vs 深色 145 行） | resources/light/element/color.json | — |
| R-M3 | 英文字符串不完整（缺 23 行），英文用户会看到中文 | resources/en_US/element/string.json | — |
| R-M4 | build-profile.json5 不在版本控制中，构建配置不可追溯 | .gitignore | L14 |
| R-M5 | 根级与 entry 级 AGC 依赖包不一致 | oh-package.json5 vs entry/oh-package.json5 | — |
| R-M6 | AGC 控制台配置一致性未确认 | README.md | L53 |

---

## 五、轻微问题与建议汇总

### 5.1 轻微问题（30 项）

| 类别 | 数量 | 典型问题 |
|------|------|----------|
| 云服务与数据层 | 7 | runLoop 无次数上限、hash64 碰撞风险、历史窗口固定 10 条、通知 ID 碰撞、反馈队列无上限、默认时长硬编码、IdGenerator 桩代码 |
| 质量与性能 | 11 | catch(_e) 静默吞错 12 处、context! 非空断言 15 处、context 空值检查不充分、setTimeout 无清理、全量替换触发 onDataReloaded、已过期任务永远占紧急象限、正则匹配不够健壮、JSON 多层 as 断言、isCancelled 不中断请求、goalId 碰撞、高频日志量 |
| 构建与发布 | 5 | 桌面卡片仅 2*4、无深链配置、zh_CN 与 base 重复、设备资源目录为空、依赖 ^ 范围声明 |
| UI/UX | 7 | 已完成任务固定高度、分类 Chip 用 ForEach、ActionSheet key 碰撞、StateView Image 无 alt、问候语不更新、横竖屏阈值缺文档、登录按钮无 Loading |

### 5.2 建议项（17 项）

| 类别 | 数量 | 典型建议 |
|------|------|----------|
| 质量与性能 | 6 | StorageManager 错误处理标杆、PomodoroService 回调管理规范、AppEventBus 防泄漏设计、番茄钟墙钟补偿、实况窗互为备份、墓碑机制分层 |
| 构建与发布 | 5 | 添加 CI/CD、补全浅色主题、多尺寸卡片、CHANGELOG、升级安全 lint |
| UI/UX | 6 | 统一按压态封装、触觉反馈、消息长按复制、深色对比度修复、键盘快捷键、页面切换动画 |

---

## 六、按类别分类分析

### 6.1 安全与隐私

**做得好的方面：**
- API Key 通过云函数中转隔离，客户端不持有任何密钥
- PII 日志脱敏（openId/unionId/token 均 Logger.secure/mask）
- 云端 SDK 延迟初始化（隐私协议同意后）
- 同步开关默认关闭（隐私优先）
- 华为账号两步法合规登录 + CSRF 防护

**需改进：**
- 🔴 S9：DETECT_GESTURE 受限权限未解决
- 🔴 S10：AGC 配置在 rawfile 中存在副本
- ⚠️ B-M8：本地存储无加密
- ⚠️ B-M13：握姿权限弹窗自动触发
- ⚠️ Q-M6：PushTokenProbe Token 明文日志
- ⚠️ B-M10：cacheAvatar 无大小限制

### 6.2 数据同步与一致性

**做得好的方面：**
- canonical JSON 指纹免疫键序差异
- 墓碑模式软删除 + updatedAt 冲突裁决
- 两阶段原子性应用云端数据
- 水位等值判断免疫时钟偏差
- 先落地后上传的顺序保证

**需改进：**
- 🔴 S5：非顶层字段不递归合并，数据丢失风险
- ⚠️ B-M1：同步代理拦截未强制执行
- ⚠️ B-M2：settings/profile 合并策略过于简单
- ⚠️ B-M3：CloudDBService init 非并发安全
- ⚠️ B-M14：ensureSignedIn 不校验 token 有效性

### 6.3 性能与资源管理

**做得好的方面：**
- 番茄钟墙钟补偿避免计时漂移
- StorageManager 写锁串行化 + LRU 缓存
- DeadlineReminderService 串行操作队列
- BaseDataSource LazyForEach key 策略正确

**需改进：**
- 🔴 S6：HomeViewModel.nowTimerId 永不清理
- 🔴 S8：notifyFormUpdate 每次持久化都写文件
- ⚠️ Q-M3：@Computed liveTasks 每次重建数组
- ⚠️ Q-M4：eisenhowerMatrix 每分钟全量重算
- ⚠️ Q-M2：persistTimer 未提供清理出口

### 6.4 代码质量与可维护性

**做得好的方面：**
- 0 处 as any，类型安全良好
- SafeUtils 统一兜底函数
- BaseDataSource 模板代码消除良好
- AIPromptBridge 信箱模式设计合理

**需改进：**
- 🔴 S7：DeadlineReminderService ~140 行重复代码
- ⚠️ A-M1：ViewModel God Object（3 个 VM > 900 行）
- ⚠️ A-M2：AppEventBus 无自动清理/无类型约束
- ⚠️ Q-M1：BusinessError 错误类过于简陋
- ⚠️ Q-M9：PriorityUtils 与 HomeViewModel 逻辑重复
- ⚠️ B-M7：parseTaskPriority 数字映射不一致

### 6.5 UI/UX 与国际化

**做得好的方面：**
- 设计令牌体系完善（字体/圆角/间距/颜色统一管理）
- 三态覆盖规范（Loading/Error/Empty）
- 响应式布局（手机/平板双布局）
- 可访问性（accessibilityText + 触控热区）

**需改进：**
- 🔴 S2：RoutePage 强制登录与游客模式矛盾
- 🔴 S3：StatsPage 硬编码中文破坏 i18n
- 🔴 S4：四象限拖拽多指触摸竞态
- ⚠️ R-M2：浅色主题颜色配置极不完整
- ⚠️ R-M3：英文字符串不完整
- ⚠️ U-M1~U-M8：8 项 UI 交互问题

### 6.6 构建与发布

**做得好的方面：**
- Lint 安全规则完善（11 项 error）
- 混淆规则文件已完善（5 类白名单）
- .gitignore 安全配置正确
- 文档非常完善

**需改进：**
- 🔴 S1：无 Release 签名证书 + 路径硬编码
- ⚠️ R-M1：代码混淆未启用
- ⚠️ R-M4：构建配置不在版本控制中
- ⚠️ R-M5：AGC 依赖包不一致
- ⚠️ R-M6：AGC 控制台配置一致性未确认

---

## 七、优先级排序改进路线图

### 阶段一：发布前必须完成（阻塞项）

| 优先级 | 编号 | 问题 | 预估工作量 |
|--------|------|------|-----------|
| P0 | S1 | 创建 Release 签名证书，修复路径硬编码 | 2h |
| P0 | S9 | 解决 DETECT_GESTURE 受限权限（申请白名单或移除） | 1h |
| P0 | S10 | 清理 rawfile 中 AGC 配置副本 | 0.5h |
| P0 | S2 | 移除 RoutePage 强制登录跳转 | 1h |
| P0 | S4 | 修复四象限拖拽多指触摸竞态 | 1h |
| P0 | S5 | 实现里程碑/子任务 id 级递归合并 | 4h |

### 阶段二：发布前强烈建议完成

| 优先级 | 编号 | 问题 | 预估工作量 |
|--------|------|------|-----------|
| P1 | S3 | StatsPage 硬编码中文替换为资源引用 | 1h |
| P1 | S6 | HomeViewModel.nowTimerId 添加 destroy 清理 | 0.5h |
| P1 | S8 | notifyFormUpdate 无卡片时跳过文件 IO | 1h |
| P1 | R-M1 | 启用 Release 代码混淆并验证 | 2h |
| P1 | R-M2 | 补全浅色主题或声明仅支持深色 | 3h |
| P1 | R-M3 | 补全英文字符串 | 2h |
| P1 | Q-M6 | PushTokenProbe Token 脱敏打印 | 0.5h |
| P1 | B-M8 | 敏感数据加密存储 | 4h |
| P1 | B-M1 | 同步代理强制拦截内嵌到 requestMerge | 1h |
| P1 | B-M7 | 统一 parseTaskPriority 数字映射 | 1h |

### 阶段三：近期迭代修复

| 优先级 | 编号 | 问题 | 预估工作量 |
|--------|------|------|-----------|
| P2 | S7 | DeadlineReminderService 代码去重 | 3h |
| P2 | B-M2 | settings/profile 字段级合并 | 3h |
| P2 | B-M4~M6 | AI 服务健壮性（取消机制/错误分类/独立标志） | 4h |
| P2 | B-M9 | 哈希碰撞防护 | 1h |
| P2 | Q-M3~M4 | @Computed 性能优化（缓存/增量） | 3h |
| P2 | Q-M9 | PriorityUtils 与 HomeViewModel 逻辑统一 | 1h |
| P2 | Q-M1 | BusinessError 错误码体系 | 2h |
| P2 | Q-M8 | AiGoalFactory 空任务列表边界 | 0.5h |
| P2 | A-M1 | ViewModel 拆分重构 | 8h |
| P2 | A-M2 | AppEventBus 类型约束增强 | 2h |

### 阶段四：长期改善

| 优先级 | 编号 | 问题 | 预估工作量 |
|--------|------|------|-----------|
| P3 | U-M1~M8 | UI/UX 8 项中等问题 | 8h |
| P3 | R-M4~M6 | 构建配置模板/依赖一致性/AGC 确认 | 3h |
| P3 | Q-M2 | persistTimer 清理出口 | 0.5h |
| P3 | Q-M7 | JSON.parse 运行时校验 | 2h |
| P3 | — | 30 项轻微问题 | 按需 |
| P3 | — | 17 项建议项 | 按需 |

### 路线图时间线

```
Week 1: 阶段一（6 项阻塞, 9.5h）+ 阶段二开始
Week 2: 阶段二完成（10 项, 15h）
Week 3-4: 阶段三（10 项, 27.5h）
Week 5+: 阶段四按需排期
```

**总预估工时**：约 71 小时（阶段一 9.5h + 阶段二 15h + 阶段三 27.5h + 阶段四 19h+）

---

## 八、问题统计总览

| 严重程度 | 架构 | UI/UX | 云服务 | 质量 | 发布 | 去重合计 |
|----------|------|-------|--------|------|------|----------|
| 🔴 严重 | 1 | 3 | 1 | 3 | 3 | **10** |
| ⚠️ 中等 | 2 | 8 | 15 | 9 | 6 | **40** |
| 🔵 轻微 | — | 7 | 7 | 11 | 5 | **30** |
| 💡 建议 | 12 | 6 | — | 6 | 5 | **17** |
| **合计** | | | | | | **97** |

---

## 九、关键文件问题热力图

| 文件 | 严重 | 中等 | 轻微 | 总计 |
|------|------|------|------|------|
| `build-profile.json5` | 1 | 1 | — | 2 |
| `CloudSyncService.ets` | 1 | 3 | 2 | 6 |
| `HomeViewModel.ets` | 2 | 2 | 2 | 6 |
| `DeepSeekService.ets` | — | 3 | 2 | 5 |
| `DeadlineReminderService.ets` | 1 | 2 | 1 | 4 |
| `pages/HomePage.ets` | 1 | 2 | — | 3 |
| `pages/RoutePage.ets` | 1 | 1 | — | 2 |
| `StorageManager.ets` | — | 2 | — | 2 |
| `module.json5` | 1 | — | — | 1 |
| `pages/StatsPage.ets` | 1 | — | — | 1 |
| `PomodoroService.ets` | — | 1 | 2 | 3 |
| `GripAwarenessService.ets` | — | 2 | 1 | 3 |

> 以上仅列出问题数 ≥ 2 的文件，按总计降序排列

---

## 十、总体结论

Momentum 是一款**功能丰富、架构成熟**的 HarmonyOS 任务/目标管理应用，在架构分层、状态管理、安全隐私、同步设计、UI/UX 等方面体现了较高的工程素养和大量实战经验沉淀。代码整体质量**中上**，0 处 `as any`、完善的日志脱敏、规范的错误兜底都值得肯定。

然而，要达到**可上架发布**的标准，仍有 **10 项严重问题**需要优先解决，其中 3 项为发布阻塞项（签名证书、受限权限、AGC 配置副本），2 项为用户体验矛盾（强制登录、i18n 破坏），1 项为数据安全风险（同步合并不递归），4 项为代码质量隐患（定时器泄漏、代码重复、不必要 IO、触摸竞态）。

**建议按四阶段路线图推进**：阶段一解决 6 项发布阻塞（预估 9.5h），阶段二完成 10 项发布前建议（预估 15h），阶段三进行 10 项近期迭代修复（预估 27.5h），阶段四处理长期改善项。完成阶段一和阶段二后，应用可达到基本发布就绪状态。

---

*综合报告结束 — 基于全部 5 份独立分析报告汇总而成*
