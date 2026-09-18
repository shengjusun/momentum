# Momentum 应用 UI/UX 与前端体验深度分析报告

> 分析人：客户端工程师  
> 日期：2026-09-16  
> 项目路径：D:\harmony\Project\s\Application  
> 分析范围：17 个页面、10+ 公共组件、资源文件与主题适配

---

## 一、总体评价

Momentum 是一款基于 HarmonyOS（ArkTS + Stage 模型）的任务/目标管理应用，采用纯 V2 状态管理体系（@ComponentV2/@Local/@Param/@Trace/@Computed），整体 UI/UX 设计水准**较高**。应用在以下方面表现优秀：

- **设计令牌体系完善**：字体大小（CommonConstants.FONT_SIZE_*）、圆角（DimensConstants.RADIUS_*）、间距（SPACE_*）统一管理，颜色走 `$r('app.color.*')` 资源引用并支持深浅色双主题
- **三态覆盖规范**：Loading / Error / Empty 三态通过 StateView 组件统一处理，首页空态保留四象限骨架而非整页替换
- **响应式布局**：支持手机/平板双布局，首页平板走左矩阵+右常驻面板，AI 页支持宽屏双栏
- **可访问性**：关键元素标注 accessibilityText，触控热区遵循 DimensConstants.TouchMin(40vp)/TouchComfort(44vp)
- **交互细节丰富**：长按拖拽排序、滑动删除、半模态面板、FAB 悬浮按钮 + 智感握姿、打字机逐字显示

但深入源码审查后，发现以下层面存在可改进之处：

---

## 二、严重问题（3 项）

### S1. RoutePage 未登录时强制跳转登录页，与游客模式策略矛盾

- **文件**：`pages/RoutePage.ets` 第 848-852 行 / 第 883-886 行
- **问题描述**：MainTab 中已明确注释"合规改造（2026-09-11）：移除冷启动强制登录"，未登录用户以游客身份进入，全部本地功能可用。但 RoutePage 的 `aboutToAppear` 和 `onPageShow` 中仍保留 `if (settingsVM.isLoaded && !settingsVM.userProfile.isLoggedIn) { navigateTo(ROUTE_NAME.LOGIN); return }` 的强制跳转逻辑。这导致游客模式切到路线 Tab 时被强制跳转到登录页，与首页/我的页的游客策略直接矛盾。
- **影响**：用户体验严重割裂——首页可用、路线页不可用；且违反《华为帐号登录管理细则》"不得因用户拒绝登录而终止服务"
- **改进建议**：移除 RoutePage 中的强制登录跳转，改为在需要云功能时（如 AI 拆解、云同步）就地引导登录，与 AIPage 的做法保持一致

### S2. StatsPage 中 buildGlobalSummary 硬编码中文字符串，破坏 i18n

- **文件**：`pages/StatsPage.ets` 第 57-68 行
- **问题描述**：`buildGlobalSummary()` 方法中直接硬编码中文：`'目标总数：' + goalTotal.toString() + '；已完成目标：' + ...`。这些文本作为 AI 复盘的输入数据发送给 DeepSeek，未走 `$r('app.string.*')` 资源引用。应用已配置 zh_CN 和 en_US 双语言资源，切换到英文环境后，AI 复盘数据仍以中文描述发送，导致 AI 回复语言与界面语言不一致。
- **影响**：多语言环境下 AI 复盘功能体验异常，输出语言与用户预期不匹配
- **改进建议**：将硬编码中文替换为 `getContext(this).resourceManager.getStringByNameSync('stats_summary_goal_total')` 等资源引用，或改为纯数据结构（JSON）传给 AI，由 system prompt 指定输出语言

### S3. HomePage 四象限拖拽实现存在触摸事件竞态风险

- **文件**：`pages/HomePage.ets` 第 797-854 行
- **问题描述**：四象限拖拽排序通过 `onTouch` 手动实现，使用 `setTimeout` 启动 500ms 长按定时器进入拖拽态。但 `longPressTimerId` 是单一变量，若用户快速连续长按两个不同象限（手指 A 按下象限 1 → 手指 B 按下象限 2），手指 A 的定时器会被手指 B 覆盖，导致手指 A 抬起时 `draggingIndex` 指向错误象限。此外 `touchStartScreenX/Y` 也是单一变量，多指触摸时位移计算会错乱。
- **影响**：多指触摸时四象限可能错误交换，数据持久化后用户排序被意外打乱
- **改进建议**：改为单指锁定模式——`onTouch` Down 时若 `draggingIndex !== -1` 则忽略新触摸；或使用 Map<pointerId, state> 管理多指状态。考虑到四象限拖拽本身只需单指，建议加 `if (event.touches.length > 1) return` 前置拦截

---

## 三、中等问题（8 项）

### M1. 首页四象限卡片内嵌套了重复的 EisenhowerQuadrantCardBuilder 定义

- **文件**：`pages/HomePage.ets` 第 695-869 行
- **问题描述**：HomePage 中存在两个四象限卡片 Builder：`EisenhowerQuadrantCardBuilder`（第 695 行，带 onTouch 拖拽逻辑）和 `EisenhowerQuadrantCardBuilder`（第 770 行附近，无拖拽逻辑但包含 ForEach 任务预览）。代码结构显示存在重复的卡片构建逻辑，增加了维护成本和出错风险。
- **改进建议**：合并为单一 Builder，通过 @Param 控制是否启用拖拽

### M2. AI 页打字机效果使用 setInterval，页面销毁时可能遗漏定时器清理

- **文件**：`pages/AIPage.ets` 第 570-583 行（startTypewriterReveal）
- **问题描述**：打字机逐字显示通过 `setInterval` 实现，`revealTimerId` 记时器在 `aboutToDisappear` 中通过 `stopTypewriterReveal` 清理。但 `stopTypewriterReveal` 仅清除定时器不补全文本，若页面在打字过程中销毁，消息文本会停留在不完整状态。虽然 chatMessages 仅内存态不持久化，但如果用户快速切 Tab 回来，AIPage 可能被重建看到残缺文本。
- **改进建议**：`aboutToDisappear` 中改用 `finishTypewriterReveal()` 补全文本后再清理，确保任何时刻消息文本完整

### M3. 隐私弹层协议正文使用单一 string 资源，长文本可读性差

- **文件**：`common/components/PrivacyConsentOverlay.ets` 第 29-38 行
- **问题描述**：隐私协议正文通过 `$r('app.string.privacy_content')` 单一资源加载，放在 `Scroll` 中展示，`constraintSize({ maxHeight: '42%' })`。协议正文通常很长，42% 最大高度在小屏设备上约 300vp，用户需要大量滚动才能读完。缺少"展开全文"折叠、关键条款加粗、分段标题等可读性优化。
- **改进建议**：将协议正文拆分为多段（概述、数据收集、数据使用、用户权利等），每段加标题和折叠展开；或提供"查看完整协议"跳转 WebView/独立页面

### M4. RoutePage 目标卡片 L2 任务列表展开/收起缺少过渡动画

- **文件**：`pages/RoutePage.ets` 第 159-174 行（L2TaskListSection）
- **问题描述**：L2 任务列表通过 `expandedTaskGoalId === this.goalId` 切换显示 `this.tasks` 或 `this.tasks.slice(0, 3)`，展开/收起时列表项瞬间出现/消失，无过渡动画。同时同一时间仅允许一个目标展开（`expandedTaskGoalId` 单值），展开新目标时旧目标直接折叠也无动画。
- **改进建议**：添加 `.animation({ duration: 200, curve: Curve.EaseOut })` 过渡；考虑使用 `transition` 属性实现列表项的入场/退场动画

### M5. CommonTitleBar 标题在 showBack 时居中对齐，但返回按钮占位导致视觉偏移

- **文件**：`common/components/CommonTitleBar.ets` 第 46-53 行
- **问题描述**：当 `showBack=true` 时，标题 `textAlign(TextAlign.Center)` 居中显示，返回按钮占 40vp 宽度。但右侧 `rightActions` 默认仅占位 40vp（`defaultRightActions`），当调用方注入更宽的右侧操作（如通知图标+文字）时，标题实际视觉中心会左偏。标题居中是基于 `layoutWeight(1)` 的可用空间居中，而非整个 TitleBar 宽度居中。
- **改进建议**：若需严格居中，改用 Stack 布局叠加标题（绝对居中）+ 返回按钮（左对齐）+ 右侧操作（右对齐）；或在文档中明确"标题居中基于剩余空间"的设计约定

### M6. 设置页缓存清理直接操作文件系统，缺少加载态反馈

- **文件**：`pages/SettingPage.ets` 第 152-172 行（doClearCache）
- **问题描述**：`doClearCache()` 同步遍历 cacheDir 删除文件，无加载态指示。若缓存文件较多，删除操作可能耗时，期间用户可重复点击。`handleClearCache` 使用 `promptAction.showDialog` 确认后直接调用 `doClearCache`，缺少 `isClearing` 状态防重入。
- **改进建议**：添加 `@Local isClearing: boolean` 状态，清理期间禁用按钮并显示 LoadingProgress；考虑异步执行文件删除

### M7. 首页 FAB 悬浮按钮位置依赖 onAreaChange 上报的容器尺寸，初始渲染时位置可能跳跃

- **文件**：`pages/HomePage.ets` 第 300-312 行（fabX/fabY）+ 第 1481-1488 行（onAreaChange）
- **问题描述**：FAB 的 x/y 坐标通过 `fabX()`/`fabY()` 计算，依赖 `fabAreaW`/`fabAreaH`（由 `onAreaChange` 上报）。初始值均为 0，`fabX()` 回退到 `w = 360`，`fabY()` 回退到 `h = 780`。首次渲染时 FAB 出现在回退位置，`onAreaChange` 回调后跳到真实位置，产生可见的位置跳跃。RoutePage 有相同问题。
- **改进建议**：初始 `fabAreaW`/`fabAreaH` 设为 -1，渲染时若未拿到真实尺寸则隐藏 FAB（`if (this.fabAreaW > 0)`），避免回退位置的闪烁

### M8. AI 页历史消息构造中通过字符串匹配过滤错误消息，逻辑脆弱

- **文件**：`pages/AIPage.ets` 第 565-568 行
- **问题描述**：构造 DeepSeek 对话历史时，通过 `msg.text.indexOf('失败') >= 0 || msg.text.indexOf('错误') >= 0 || ...` 字符串匹配判断是否为错误消息并跳过。这种基于关键词的判断方式非常脆弱——若 AI 正常回复中包含"失败"一词（如"如果失败了怎么办"），会被误判为错误消息而跳过，破坏对话上下文连贯性。
- **改进建议**：在 ChatMessage 模型中增加 `isError: boolean` 标记字段，错误消息生成时显式标记，历史构造时按标记过滤而非字符串匹配

---

## 四、轻微问题（7 项）

### L1. 首页已完成任务折叠区固定高度 160vp，大量已完成任务时无法完整查看

- **文件**：`pages/HomePage.ets` 第 1287 行
- **问题描述**：`CompletedSectionBuilder` 中已完成任务列表 `.height(160)`，固定 160vp 高度。当已完成任务超过 4-5 个时，用户需要在小窗口内滚动查看，体验不佳。
- **改进建议**：改为 `layoutWeight(1)` 或动态高度（如 `Math.min(320, count * 48)`），允许更多内容展示

### L2. RoutePage 分类筛选 Chip 使用 ForEach 而非 LazyForEach

- **文件**：`pages/RoutePage.ets` 第 231-242 行
- **问题描述**：分类筛选 Chip 通过 `ForEach` 渲染。虽然分类数量通常较少（5-8 个），ForEach 性能可接受，但与应用其他列表统一使用 LazyForEach 的策略不一致。
- **改进建议**：分类数量少时 ForEach 可接受，但建议在代码注释中说明"分类数量少，ForEach 性能无忧"以避免后续开发者误改

### L3. AppActionSheet 菜单项 key 使用 label 文本，多语言切换时可能 key 碰撞

- **文件**：`common/components/AppActionSheet.ets` 第 112 行
- **问题描述**：`keyGenerator` 使用 `item.label + (item.danger ? '_d' : '')`。若两个菜单项文本相同（如"删除"出现两次），key 会碰撞导致渲染异常。虽然实际场景中不太可能出现重复菜单项，但 key 设计不够健壮。
- **改进建议**：使用 `item.label + index.toString() + (item.danger ? '_d' : '')` 纳化 key

### L4. StateView 错误态使用 Image 插画，但未提供 alt/placeholder

- **文件**：`common/components/StateView.ets` 第 62-65 行
- **问题描述**：错误态和空态使用 `Image($r('app.media.error_state_illustration'))` 和 `Image($r('app.media.empty_state_illustration'))`，未设置 `.alt()` 占位图。若图片资源加载失败，用户看到空白区域而非错误提示。
- **改进建议**：添加 `.alt($r('app.media.app_icon'))` 或使用 SymbolGlyph 作为兜底

### L5. 首页问候语在 onPageShow 时更新，但 HomePage 非 @Entry 页面不保证触发

- **文件**：`pages/HomePage.ets` 第 455-460 行
- **问题描述**：`onPageShow()` 中更新 `this.greeting = getGreeting(...)`，但注释自己也提到"HomePage 不是 @Entry 页面，onPageShow 不保证触发"。虽然 `onVisibleAreaChange` 补充了数据同步，但未补充问候语更新。用户长时间停留在首页跨过时段边界（如 12:00 从上午到中午）后，问候语不会自动更新。
- **改进建议**：在 `onVisibleAreaChange` 回调中同时更新 greeting；或使用定时器在整点刷新

### L6. 番茄钟沉浸屏横竖屏判定阈值 1.15 缺少文档化依据

- **文件**：`common/components/PomodoroImmersiveScreen.ets` 第 189-191 行
- **问题描述**：`isLandscape()` 使用 `this.viewW > this.viewH * 1.15` 判定横屏，注释提到"1.15 阈值避开正方形窗口/折叠屏开合过程中的反复抖动"。但 1.15 这个具体数值缺少推演依据——为何不是 1.1 或 1.2？不同折叠屏开合过程中宽高比变化曲线是否测试过？
- **改进建议**：在注释中补充测试数据（如"Mate X5 开合过程中宽高比从 1.0 到 1.38，1.15 为中位值"），或改为监听系统方向变化事件

### L7. ProfilePage 未登录态"去登录"按钮直接调用 handleHuaweiLogin，缺少 Loading 态

- **文件**：`pages/ProfilePage.ets` 第 132-137 行
- **问题描述**：未登录态下"去登录"按钮的 onClick 直接 `await this.settingsVM.handleHuaweiLogin(...)`，但按钮未显示 Loading 态。华为账号登录弹窗弹出前可能有短暂延迟，用户可能重复点击。
- **改进建议**：添加 `@Local isLoggingIn: boolean` 状态，登录期间禁用按钮并显示"正在登录..."

---

## 五、建议优化（6 项）

### A1. 统一按压态实现模式

当前应用中按压态（pressed）实现方式不统一：
- HomePage/RoutePage 使用 `@Local pressedXxxId: string` + `onTouch` 手动管理
- AppActionSheet 使用 `@Local pressedIndex: number` + `onTouch`
- GoalCardComp 使用 `scale({ x: 0.98, y: 0.98 })` 按压反馈
- 建议封装统一的 `PressableMixin` 或 `@Builder PressableWrapper`，统一按压视觉反馈（scale/opacity）和状态管理

### A2. 首页四象限拖拽可增加触觉反馈

- **文件**：`pages/HomePage.ets` 第 807-812 行
- 长按进入拖拽态时仅 `promptAction.showToast` 提示，建议增加 `vibrator.startVibration()` 短震动反馈，提升拖拽启动的感知。应用已声明 `ohos.permission.VIBRATE` 权限但未在拖拽场景使用。

### A3. AI 页对话流可增加消息长按复制功能

- **文件**：`pages/AIPage.ets` + `common/components/ai/AIChatComponents.ets`
- 当前 AI 回复消息仅支持查看，不支持长按复制文本。用户可能需要复制 AI 生成的任务名称或建议内容。

### A4. 深色模式下番茄钟沉浸屏色彩对比度可进一步优化

- **文件**：`resources/dark/element/color.json` 第 89-126 行
- 番茄钟沉浸屏深色模式使用深色渐变背景 + 白色半透明文字。`pomo_immersive_text_weak`（#59FFFFFF，36% 透明度）在 `pomo_immersive_bg_end`（#0A0E1A）上的对比度约 2.8:1，低于 WCAG AA 标准 4.5:1。建议提升至 #80FFFFFF（50% 透明度）以上。

### A5. 考虑为平板模式增加键盘快捷键支持

- 应用已支持平板（deviceTypes 包含 tablet），但未实现键盘快捷键。在平板外接键盘场景下，建议支持：
  - `Ctrl+1/2/3/4` 切换 Tab
  - `Esc` 关闭半模态/弹层
  - `Enter` 确认操作

### A6. 考虑增加页面切换过渡动画

- **文件**：`pages/MainTab.ets` 第 320 行
- HdsTabs 的 `animationDuration(300)` 控制 Tab 切换动画，但 Navigation push/pop 页面切换使用系统默认动画。建议为 NavDestination 统一配置转场动画（如共享元素过渡），提升导航的连续感。

---

## 六、设计令牌与主题适配分析

### 6.1 字体令牌（CommonConstants.FONT_SIZE_*）

| 令牌 | 值 (fp) | 用途 | 评价 |
|------|---------|------|------|
| FONT_SIZE_MINI | 9 | 极小字 | ⚠️ 低于推荐最小可读字号 10fp，仅用于极特殊场景 |
| FONT_SIZE_XXS | 10 | 微小字 | 临界值，小屏/老花用户可能困难 |
| FONT_SIZE_XS | 11 | 小字 | 元数据/辅助信息，可接受 |
| FONT_SIZE_SMALL | 12 | 小字 | 常用辅助文字 |
| FONT_SIZE_CAPTION | 13 | 辅助文字 | 常用 |
| FONT_SIZE_BODY | 14 | 正文 | 标准 |
| FONT_SIZE_MID | 15 | 强调正文 | 标准 |
| FONT_SIZE_SUBTITLE | 16 | 副标题 | 标准 |
| FONT_SIZE_TITLE | 18 | 标题 | 标准 |
| FONT_SIZE_LARGE | 20 | 大标题 | 标准 |
| FONT_SIZE_HEADLINE | 22 | 卡片主标题 | 标准 |
| FONT_SIZE_XL | 24 | 超大标题 | 标准 |
| FONT_SIZE_XXL | 26 | 导航栏返回 | 标准 |
| FONT_SIZE_XXXL | 28 | 品牌 Logo | 标准 |
| FONT_SIZE_HUGE | 32 | FAB 图标 | 标准 |
| FONT_SIZE_MEGA | 36 | 番茄钟 emoji | 标准 |
| FONT_SIZE_TIMER | 40 | 倒计时主数字 | 标准 |
| FONT_SIZE_TIMER_MD | 52 | 沉浸屏次级 | 标准 |
| FONT_SIZE_TIMER_XL | 56 | 沉浸屏超大 | 标准 |

**问题**：`FONT_SIZE_MINI = 9` 低于 HarmonyOS 推荐最小可读字号。`FONT_SIZE_XXS = 10` 为临界值。建议审查所有使用 MINI/XXS 的场景，确认是否可提升至 SMALL(12)。

### 6.2 圆角令牌（DimensConstants.RADIUS_*）

圆角收敛为 5 档（XS=6, S=8, M=12, L=16, XL=24），设计语言统一，**评价优秀**。

### 6.3 颜色主题

- **浅色模式**：base/color.json 定义完整，包含 primary/status/priority/quadrant/pomodoro 等语义化颜色分组
- **深色模式**：dark/color.json 完整覆盖所有浅色颜色，色值适配合理（如 primary 从 #007DFF 调亮为 #4D9FFF）
- **light/element/color.json**：仅覆盖 `start_window_background`，其余由 base 提供——这是正确的覆盖策略
- **问题**：深色模式下 `pomo_immersive_text_weak`（#59FFFFFF）对比度不足（见 A4）

### 6.4 多语言资源

- zh_CN 和 en_US 均有 string.json，覆盖主要界面文本
- **问题**：StatsPage.buildGlobalSummary 中硬编码中文（见 S2），未走资源引用
- **问题**：部分页面中仍有少量 `getStringSync($r('app.string.*').id)` 模式，虽然功能正确但写法冗长，建议封装工具函数

---

## 七、交互模式分析

### 7.1 手势与交互

| 交互模式 | 实现位置 | 评价 |
|---------|---------|------|
| 长按拖拽排序 | HomePage 四象限 | ⚠️ 多指竞态风险（S3） |
| 滑动删除 | HomePage 任务列表 | ✅ swipeAction 实现，有确认弹层 |
| 长按弹出菜单 | HomePage 任务项→移动象限 | ✅ bindPopup 锚定行，空间关系清晰 |
| 半模态面板 | HomePage 象限详情/添加待办 | ✅ bindSheet 使用规范，避开 TabBar 遮挡 |
| FAB 悬浮按钮 | HomePage/RoutePage | ⚠️ 初始位置跳跃（M7） |
| 智感握姿 | FAB 左右换边 | ✅ GripAwarenessService 降级处理完善 |
| 打字机显示 | AIPage AI 回复 | ⚠️ 定时器清理边界（M2） |
| 按压反馈 | 全局 | ⚠️ 实现不统一（A1） |
| 控件自动淡出 | 番茄钟沉浸屏 | ✅ 3s 无交互淡出，计时本体不淡出 |

### 7.2 状态管理

| 状态模式 | 评价 |
|---------|------|
| Loading 态 | ✅ StateView + 骨架屏（RoutePage） |
| Error 态 | ✅ StateView + 重试按钮 |
| Empty 态 | ✅ 首页保留骨架、路线页三段式引导、筛选空态区分 |
| 防重入 | ✅ AI 建议/同步/删除等操作有 isLoading/isSyncing 防护 |
| 组件存活 | ✅ isAttached 标记 + 异步回调校验 |
| 请求序列号 | ✅ AIPage requestSeq 防旧回调污染 |

### 7.3 响应式布局

| 断点 | 阈值 (vp) | 适配策略 | 评价 |
|------|----------|---------|------|
| SM | 320 | 手机竖屏 | ✅ |
| MD | 600 | 折叠屏/手机横屏 | ✅ |
| LG | 840 | 平板 | ✅ 首页左矩阵+右面板，AI 页双栏 |

- **首页**：平板走左象限矩阵 + 右常驻任务面板（替代半模态），✅
- **AI 页**：宽屏双栏（对话流 + 方案侧栏），通过 onAreaChange 实测宽度判定，✅
- **RoutePage**：内容列限宽 640vp 居中，平板放宽至 860vp，✅
- **问题**：TaskDetailPage/GoalDetailPage 在平板上应支持双栏（列表+详情），但未确认是否实现

---

## 八、性能分析

### 8.1 列表渲染

- **HomePage 四象限**：使用 LazyForEach + EisenhowerQuadrantDataSource，✅
- **RoutePage 目标列表**：使用 LazyForEach + GoalCardDataSource，cachedCount(2)，✅
- **AIPage 对话流**：使用 LazyForEach + ChatMessageDataSource，✅
- **HomePage 已完成任务**：使用 ForEach（数量少可接受）
- **RoutePage L2 任务**：使用 ForEach（每卡片≤3+展开，可接受）

### 8.2 不必要的重绘

- **HomePage**：`onDidBuild` 中更新 `quadrantTaskTotal` 触发 @Monitor 同步 DataSource，每次 build 都执行——虽然有 `if (this.quadrantTaskTotal !== total)` 守卫，但 build 频繁时仍有开销
- **RoutePage**：`onDidBuild` + `onVisibleAreaChange` + `onAppear` 三处调用 `forceSyncGoalDataSource`，可能重复同步。虽有 `isGoalDataSourceStale` 检测，但检测本身有遍历开销
- **建议**：考虑引入脏标记 + 微任务去抖，合并多次同步请求

### 8.3 动画性能

- 四象限拖拽：`.animation({ duration: 150, curve: Curve.EaseOut })`，✅ 轻量
- FAB 换边：`.animation({ duration: 300, curve: Curve.EaseInOut })`，✅
- AppActionSheet：遮罩淡入 200ms + 面板上滑 250ms，✅
- 番茄钟沉浸屏：呼吸动画 + 控件淡出，使用 opacity 而非 scale，✅ 性能友好

---

## 九、问题汇总统计

| 严重程度 | 数量 | 编号 |
|---------|------|------|
| 严重 | 3 | S1, S2, S3 |
| 中等 | 8 | M1-M8 |
| 轻微 | 7 | L1-L7 |
| 建议 | 6 | A1-A6 |
| **合计** | **24** | |

---

## 十、优先修复建议

1. **立即修复**（S1）：移除 RoutePage 强制登录跳转，统一游客模式策略
2. **立即修复**（S2）：StatsPage 硬编码中文改为资源引用或纯数据结构
3. **尽快修复**（S3）：HomePage 四象限拖拽增加多指触摸防护
4. **短期修复**（M2/M7/M8）：定时器清理、FAB 位置跳跃、AI 历史消息过滤
5. **中期优化**（M3/M4/M6）：隐私弹层可读性、展开动画、缓存清理反馈
6. **长期优化**（A1/A4/A5/A6）：统一按压态、深色对比度、键盘快捷键、转场动画

---

*报告结束*
