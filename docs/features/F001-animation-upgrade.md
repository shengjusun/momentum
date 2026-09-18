---
feature_ids: [F001]
related_features: []
topics: [ui, animation, arkui]
doc_kind: spec
created: 2026-09-16
---

# F001: 动效全面升级（L0 Token 基建 + L1 出现/消失过渡）

> Status: **in-progress**（L0 + L1a + L1b 已实施，待真机复核；两处 steps 列表因身份问题另立任务）| Owner: mr孙

## 实施记录（2026-09-16）

### 新增文件
| 文件 | 作用 |
|---|---|
| `entry/src/main/ets/common/constants/MotionConstants.ets` | 动效 token 单一来源：时长三档 + 四曲线 + 幅度量 + 4 个 `AnimateParam` 工厂 + `springParam()` |
| `entry/src/main/ets/common/utils/MotionHelper.ets` | 转场构建器：`overlayFade()` / `dialogCard()` / `bottomPanel()` / `listItem()` / `expandSection()` / `noTransition()` |

> ⚠️ 另有一个 `common/components/LoginRequiredSection.ets`（共享门控组件）曾于游客模式改造时新建，但**始终未被任何页面落地使用**（AIPage 实际用的是内联横幅）→ 已于 2026-09-16 作为死代码**删除**。

### 已改动文件（13 个）
`GoalDetailPage` `TaskDetailPage` `RoutePage` `HomePage` `AIPage` `LoginPage` `CategoryManagePage` `GoalHistoryPage` `NotificationPage` `ProfilePage` `AppActionSheet` `AppReportSheet` `AppInfoDialog`

### L0 落地口径
- 原 8 种 duration（80/100/120/150/180/200/250/300）收敛为三档：**FAST 120 / BASE 200 / SLOW 300**；曲线由清一色 `Curve.EaseOut` 改为按语义分族（按压 `Friction`、出现 `FastOutSlowIn`、消失 `Friction`、面板 `FastOutSlowIn`）。
- 原 28 处中 **21 处**改为 token（番茄钟 9 处 + `GoalDetailPage` 骨架屏 2 处按不动清单保留）。

### L1a 落地口径（9 处转场 → 四类形态）
| 类别 | 位置 | 落地写法 |
|---|---|---|
| 居中对话框 | `GoalDetailPage:688/932`、`CategoryManagePage:294`、`AIPage`（builder 内卡片 + 外层遮罩） | 外层 `overlayFade()` + 内层 `dialogCard()` |
| 底部面板 | `RoutePage:1512`（遮罩 + 面板 + Stack 三层）、`TaskDetailPage:947` | 遮罩 `overlayFade()` + 面板 `bottomPanel()` + 容器 `noTransition()` |
| 页面级 | `GoalDetailPage` 页面根、`LoginPage:321` | `noTransition()`（系统路由转场独占） |
| 断点分支 | `TaskDetailPage:1464`（平板双栏 / 手机单栏） | `noTransition()`（旋屏不整块淡入） |

### L1b 落地口径（2026-09-16 追加）

| 过渡点 | 位置 | 落地写法 |
|---|---|---|
| 列表项增删（**LazyForEach 实验点**） | `AIPage:1227` 聊天气泡（key = `msg.id`） | `.transition(MotionHelper.listItem())` |
| 列表项增删 | `NotificationPage:387` 通知列表（key = `item.id`） | 同上 |
| 列表项增删 | `RoutePage:1199` 目标卡片（key 主键 = `goal.id`）。同 `List` 内的 header 与底部占位项**刻意不挂** —— 它们是常驻项，不参与增删动效 | 同上 |
| 展开 / 收起区块 | `GoalDetailPage:215`（L2 任务卡片的步骤区，由 `if (isExpanded)` 创建/销毁） | `.transition(MotionHelper.expandSection())` |

**⚠️ 另有 3 处 `LazyForEach` 刻意未接**（原因各异，勿盲接）：

| 位置 | 未接原因 |
|---|---|
| `HomePage:1169` | `getActiveDataSource()` 在 q1~q4 是**四个独立 DataSource 实例**，切象限 = 换数据源 = 全量重建 ⇒ 接了会**整屏重刷**，须先显式抑制 |
| `GoalHistoryPage:328` | 筛选切换整列表换内容，同属"换源"类，须先评估 |
| `GoalDetailPage:495` | ⚠️ 结构是 **`Column` + `LazyForEach`**（非 `List` + `ListItem`），与官方「LazyForEach 只能在 List / ListItemGroup / Grid / Swiper / WaterFlow 内使用」的限制不符，需单独评估 |

**两个构建器的设计依据**

- `listItem()`：进场用**位移**（+12vp，新内容从下方来）；离场用**收缩 + 淡出、刻意不加位移** —— 位移会让"被删项消失"与"后续项上移重排"两个过程互相干扰。用 `asymmetric(appear, disappear)` 分别配 `enterParam` / `exitParam`。
- `expandSection()`：进场从**上方**推入（-8vp）。展开内容长在锚点**下方**，起点在上方才符合"从标题底下展开"的空间因果；与 `listItem()` 方向相反是刻意的。
- 两者均**自带 `animation()` 参数** ⇒ **不要求外层 `animateTo` 包裹数据变更**。这对本工程是硬要求：列表数据在 ViewModel 侧 `splice`/`push`，**逻辑层无法调用 UI 侧的 `animateTo`**（新增断言 12.13 专门守卫"逻辑层未引入 animateTo"）。

**⚠️ 未做：两处 steps 列表的增删过渡**（原因必须留档）

`TaskDetailPage:1300`、`GoalDetailPage:171` 的 keyGenerator 均为 `'l3step_' + index + '_v' + stepVersion`：

- `index` 作 key ⇒ 删除中间项后，后续所有项 key 全部变化；
- `stepVersion` **必须保留** —— `TaskDetailPage:63-68` 注释写明它是为绕过「ArkUI 嵌套数组代理限制」（`completedSteps: boolean[]` 内部变化不触发 `@Trace` 追踪）；
- 二者叠加 ⇒ **任何步骤变更（连勾选都算）都会让全部 key 变化** ⇒ 此时加 `transition` 会变成"整段列表闪一下"，**比不加更差**。
⇒ 解法须先给步骤稳定身份（数据模型改动），已另立任务跟踪，本轮不做。

### 实施中修正的两个原判断
1. **`RoutePage` 的转场原为 1 处，实为 3 个挂载点**：遮罩与面板是 `Stack` 的两个兄弟节点，只改外层会让整体一起淡、丢方向感 → 拆成遮罩/面板/容器三处分别处理。
2. **`AppActionSheet` / `AppReportSheet` / `AppInfoDialog` 的入场动画本来就是好的**：三者都用 `@Local entered` + `aboutToRender` 后 16ms 置位 + `.opacity/.translate/.scale` + `.animation()` 的模式实现，属性变化确实发生了 → 能正常入场。**修正了审计阶段"公共弹层也无动效"的推断**：它们只做 token 替换，未改结构。残留缺口：**退场无动效**（`onDismiss` 直接移除组件），见 L1b。

### 验证结果
- `docs/上架素材/check_sync_refactor.py` → **200/200 PASS**（原 177 → L0/L1a 后 196 → L1b 再增 **4 条**：① 构建器自带 `animation` 参数 ② L1b 落地计数 ③ 聊天气泡实验点保留 ④ 逻辑层未引入 `animateTo`）。
- `check_pomo_immersive.py` / `check_pomo_ring_text_fit.py` → 全部通过（`check_pomo_v4_sizes.py` 内 FAIL 为候选 0.28/0.30 的推演结论，现行 0.26 本就刻意避开，非回归）。
- 全工程 `.ets`：80 → 82（L0 新增 2）→ 83（游客模式新增 `LoginRequiredSection`）→ **82**（该类始终未落地，已按死代码删除）。
  ⚠️ 括号/引号平衡须按「**剥离注释与字符串后**」的口径判定：用裸文本统计时 `PomodoroTimerCard.ets` 会误报（注释里有不成对花括号），校验脚本内部已做剥离。
- ⚠️ 本工程无 `hvigorw`，**编译验证仍需用户在 DevEco 完成**。

## Open Questions

- ~~Q2: `curves` 是否从 `@kit.ArkUI` 正常导出~~ → **已解决（2026-09-16）**：SDK 实测 `@kit.ArkUI.d.ts` 的 `export {...}` 共 497 个导出名，**含 `curves`**；`focusControl` 确认不在（印证历史结论）。四个弹簧函数签名已核对：`springCurve` / `springMotion` / `responsiveSpringMotion`（均为 `(response?, dampingFraction?, overlapDuration?) => ICurve`）/ `interpolatingSpring(velocity, mass, stiffness, damping)`；`AnimateParam.curve` 接受 `Curve | string | ICurve`。已据此实现 `springParam()`。
- ~~Q3: `GoalDetailPage.ets:1770` 那处 800ms 的用途~~ → **已确认**：属骨架屏体系（与 `animateTo({duration:1200, iterations:-1, curve:Linear})` 的 shimmer 耦合），已列入不动清单，**不纳入 token**。
- **Q1（仍开放）**：HarmonyOS 6.1 是否暴露「减少动态效果 / 移除动画」的可读 API？若无，本方案只靠幅度克制兜底（位移 ≤20vp、缩放偏移 ≤0.06）。
- **Q4（仍开放）**：`AIPage` 自绘 `Stack` 叠加弹窗（注释写"替代 bindContentCover"）已违反工程「弹层一律 `bindSheet`」约定——建议单开议题，本轮未夹带。
- **Q5（新增，L1b 必答）**：`AppActionSheet` / `AppReportSheet` / `AppInfoDialog` 的**退场动效**需要先 `entered = false` 再延迟调用 `onDismiss`，但这会顺延调用方的 `item.action()`（现有注释明确"先收面板再执行动作，动作内部可能再次弹层"）。是接受"动作顺延动效时长"，还是改为"动作立即执行 + 仅延迟组件移除"（两个弹层会短暂并存）？影响 8+ 调用点，需先定口径。

## Why

2026-09-16 对全工程 80 个 `.ets` 逐文件扫描动效 API 用量，现状基线：

| 能力 | 用量 | 说明 |
|---|---|---|
| `.animation()` 属性动画 | ~28 处 | 几乎全是按压反馈；时长 80/100/120/150/180/200/250/300ms **八种混用**，曲线清一色 `Curve.EaseOut` |
| `animateTo` 显式动画 | **1 处** | 仅 `GoalDetailPage.ets:984` 骨架屏 shimmer（1200ms Linear 无限） |
| `.transition()` | 9 处 | 8 处裸 `TransitionEffect.OPACITY`，1 处带 `.animation()` |
| `curves.*`（弹簧/插值弹簧/响应弹簧） | **0** | 全 App 无弹簧物理 |
| `geometryTransition` / `keyframeAnimateTo` / `animateToImmediately` / `@AnimatableExtend` / `motionPath` / `sharedTransition` | **均 0** | 高级动效能力未使用 |
| 列表项增删过渡 | **0** | 13 处 `List`/`Grid`/`LazyForEach` 均无 transition |
| 动效 token | **无** | `CommonConstants` 管字号、`DimensConstants` 管尺寸/圆角/间距，**没有 `MOTION_*`** |

### 关键发现：8 处转场其实"根本没在动"

官方《组件内转场 (transition)》对象说明第 3 点原文：

> 「如果未使用 animateTo 触发转场动画且 TransitionEffect 中也无 animation 参数，则该组件**直接出现或者消失**。」

据此逐条核对 9 处：

| 位置 | 形态 | 现状 |
|---|---|---|
| `AIPage.ets:1465` | 自绘叠加弹窗（overlay_mask + 居中卡片） | ❌ 无动效 |
| `CategoryManagePage.ets:294` | 自绘居中对话框 | ❌ 无动效 |
| `GoalDetailPage.ets:688` | 自绘居中对话框（卡片 + shadow） | ❌ 无动效 |
| `GoalDetailPage.ets:932` | 自绘居中对话框 | ❌ 无动效 |
| `GoalDetailPage.ets:1610` | 全屏层（bg_page + expandSafeArea，ActionSheet 所在） | ❌ 无动效 |
| `LoginPage.ets:321` | 页面级（linearGradient 背景） | ❌ 无动效 |
| `RoutePage.ets:1512` | 底部面板（`position y:'100% - 520'`、顶部圆角 20） | ✅ 生效（带 `{duration:200}`） |
| `TaskDetailPage.ets:947` | 底部面板（顶部圆角 20 + 向上阴影） | ❌ 无动效 |
| `TaskDetailPage.ets:1464` | 全屏层（bg_page） | ❌ 无动效 |

**结论：L1 的性质是「修复 8 处失效转场 + 升级为方向正确的组合过渡」，而非单纯加戏。** 这也解释了为何用户侧观感一直是"瞬现瞬隐"。

## 已确认决策（2026-09-16 与 mr孙对齐）

1. **基调**：分层克制 —— 基础交互走系统一致的短弹簧；只在「完成打卡 / 里程碑达成 / 番茄阶段切换」这类情绪节点放开存在感（情绪节点属 L3，本轮不做）。
2. **本轮范围**：**L0 + L1**。L2（空间连续性/一镜到底）与 L3（情绪节点）另轮推进。
3. **路由转场**：**保留系统默认**，不使用 `customNavContentTransition`。返回手势、深链直达、流转恢复等既有链路零风险。

## What

### L0 — 动效 Token 基建

新增 `entry/src/main/ets/common/constants/MotionConstants.ets`，沿用工程既有的 `class + static readonly` 风格（与 `CommonConstants`/`DimensConstants` 一致）。

**时长三档**（收敛现有八种取值）：

| Token | 值 | 语义 | 吸收的原取值 |
|---|---|---|---|
| `MOTION_FAST` | 120 | 按压/状态切换/图标换形 | 80 / 100 / 120 / 150 |
| `MOTION_BASE` | 200 | 元素出现与消失 | 180 / 200 / 250 |
| `MOTION_SLOW` | 300 | 面板与大区块 | 300 |

**曲线**：

| Token | 值 | 用途 |
|---|---|---|
| `MOTION_CURVE_PRESS` | `Curve.Friction` | 按压反馈（快而钝，不弹） |
| `MOTION_CURVE_ENTER` | `Curve.FastOutSlowIn` | 出现（减速） |
| `MOTION_CURVE_EXIT` | `Curve.Friction` | 消失（加速） |
| `MOTION_CURVE_PANEL` | `Curve.FastOutSlowIn` | 底部面板 |

**位移/缩放量**（分层克制的幅度上限）：

| Token | 值 | 用途 |
|---|---|---|
| `MOTION_ENTER_TRANSLATE_Y` | 16 | 页面/区块从下方进入 |
| `MOTION_PANEL_TRANSLATE_Y` | 40 | 底部面板上滑距离 |
| `MOTION_DIALOG_SCALE_FROM` | 0.94 | 居中对话框起始缩放 |
| `MOTION_LIST_ITEM_TRANSLATE_Y` | -12 | 列表新增项落下起点 |

**参数装配**：同文件内提供 `AnimateParam` 工厂（`pressParam()` / `enterParam()` / `exitParam()` / `panelParam()`），供 28 处调用点替换硬编码字面量。

**替换范围与不动清单**：
- ✅ 替换：全工程 28 处 `.animation({...})` 中的 duration/curve 字面量。
- ⛔ **不动**：`PomodoroImmersiveScreen.ets` 全部动画（v4 定稿契约 + `check_pomo_immersive.py` 断言）、`GoalDetailPage.ets:984` 骨架 shimmer（1200ms）、`GoalDetailPage.ets:1770`（800ms，用途待确认）、`CHROME_FADE_MILLIS`（已具名）。
- ⛔ **不动**：`MainTab.ets:320` 的 `.animationDuration(300)`（HdsTabs 系统动效）。

### L1 — 出现/消失过渡

按元素的空间位置分四类，**位移方向必须与元素位置一致**：

| 类别 | 位置 | 过渡写法 |
|---|---|---|
| 居中对话框 | `GoalDetailPage:688/932`、`CategoryManagePage:294`、`AIPage:1465` | 外层容器纯淡入；**内层卡片**加 `scale(0.94→1)` + `translate(y:8→0)` + 淡入 |
| 底部面板 | `RoutePage:1512`、`TaskDetailPage:947` | 面板 `translate(y:MOTION_PANEL_TRANSLATE_Y→0)` + 淡入；遮罩纯淡入（遮罩不能跟着位移） |
| 页面/全屏层 | `LoginPage:321`、`TaskDetailPage:1464`、`GoalDetailPage:1610` | `translate(y:MOTION_ENTER_TRANSLATE_Y→0)` + 淡入 |
| 列表项增删 | 见下 | `TransitionEffect.asymmetric(enter, exit)`，新增从上方落下、删除向下方淡出 |

> 实现要点：遮罩与卡片是父子关系时，**透明度挂最外层、位移/缩放挂内层**，否则遮罩会一起平移。

**列表项增删过渡接入清单**（7 处首选）：

| 位置 | 容器 | 循环 |
|---|---|---|
| `HomePage.ets:1135` | `List({space:12})` | `LazyForEach(getActiveDataSource())` |
| `HomePage.ets:1116` | `List({space:12})` | `ForEach(getTasksByQuadrant(activeQuadrant))` |
| `HomePage.ets:1259` | `List({space:8})` | `ForEach(completedTasks)` |
| `RoutePage.ets:1167` | `List({space:12})` | `LazyForEach(goalDataSource)` |
| `NotificationPage.ets:382` | `List({space:10})` | `LazyForEach(dataSource)` |
| `GoalHistoryPage.ets:326` | `List({space:12})` | `LazyForEach(dataSource)` |
| `AIPage.ets:1179` | `List({space:4})` | `LazyForEach(chatDataSource)`（聊天气泡，观感收益最高） |

次选：`TaskDetailPage.ets:1296`（步骤增删）、`GoalDetailPage.ets:491`（L2 任务）。

## ⚠️ UI/数据层配合度评估（决定"能不能做出来"）

2026-09-16 追加勘察。**L1 必须拆成 L1a / L1b 两段**——L1b 在现有数据推送方式下做了也不生效。

### 档 A：不用动结构（L1a）
9 处转场补 `.animation()` + 组合过渡、28 处按压反馈换 token、面板上滑、对话框缩放——全部是在**现有节点上挂属性**。

### 档 B：需要微调层级，但不改布局语义
9 处弹层的 `.transition()` 目前挂在**外层全屏容器**上（同一节点还承载 `overlay_mask` 背景）。要让"卡片缩放进场、遮罩只淡入"，必须把 transition **拆成两处**：外层挂透明度、内层卡片挂位移+缩放。否则遮罩会跟着卡片一起平移。

官方另有一条必须配合的约束（对象说明第 7 点）：删除整棵子树时，**被删子树的根组件需有充足的消失转场时间**；且根组件属性值若等于默认值（如 `opacity(1)`）会导致转场**不触发**，需用 `opacity(0.99)` 之类规避。

### 档 C：必须改数据层，否则写了也是死的（L1b — 阻塞项）

**全工程列表数据推送没有一处走增量通知。** 逐条核查：

| 位置 | 推送方式 | 结果 |
|---|---|---|
| `HomePage.ets:566-569` | `q1~q4DataSource.updateAll(...)` | → `notifyDataReload()` |
| `RoutePage.ets:729` / `:1000` | `goalDataSource.updateAll(filteredGoals)` | → `notifyDataReload()` |
| `GoalDetailPage.ets`（**9 处**） | `l2TaskDataSource.updateAll(l2Tasks)` | → `notifyDataReload()` |
| `AIPage.ets:156` | `chatDataSource.updateAll(chatMessages)` | → `notifyDataReload()`（聊天气泡因此无进入动效） |
| `NotificationPage.ets:63-66` | `setItems()` 内部调 `notifyDataReload()` | → `notifyDataReload()` |

而 `BaseDataSource.ets` 里真正的**增量**通知 `addData()`（→`notifyDataAdd`）、`removeData()`（→`notifyDataDelete`）、`notifyDataChange()` —— **全工程零调用，只有定义**。

→ `onDataReloaded` 的语义是"全部数据都变了"，框架无法 diff → **列表项进入/退出动效物理上不可能生效**。这是为什么聊天气泡、通知列表从来就没有出现/删除动效。

→ L1b 的改动 = 把变更改为增量推送（`notifyDataAdd` / `onDataDelete` / `notifyDataChange`），涉及 `BaseDataSource` 与上述 6 处调用点。**属数据层改造，非纯 UI。**

### 另一处结构问题：HomePage 切象限

`q1~q4DataSource` 是**四个独立实例**，`getActiveDataSource()`（`HomePage.ets:591-596`）按 `activeQuadrant` 返回**不同实例** → 切象限 = 换数据源 = 全量重建，做不到"只动变化项"。要干净必须改为「单一稳定 id 数据源 + 过滤视图」，属结构改造。

### 已记录的同类规则
**`if/else` 切换无法补间**（工程既有结论）。`NotificationPage.ets:412` 即 `if (list.length===0) EmptyStateBuilder() else NotificationListBuilder()` 的典型——要让"空态 ↔ 列表"连续过渡，必须改成**属性驱动**而非 if/else 换树。

## L2 前置结论（一镜到底，本轮不做但需先决策）

官方《组件内隐式共享元素转场 (geometryTransition)》（2026-09-14 更新）硬约束：

- **必须配合 `animateTo`** 才有动效，**不支持 `.animation()`**（与 `transition` 恰好相反）。
- 同一个 `id` **只能绑两个组件**，且必须分别充当 in（新视图）/ out（旧视图），不能多绑。
- in/out 组件**必须配 `transition`**，否则 out 组件离场时被**立即析构**，共享元素转场可能无法正常呈现。
- 圆角同步**仅限 `geometryTransition` 绑定处**，不作用于容器内部子组件的 `borderRadius`。
- 文档定位是「**组件内**隐式共享元素转场」；官方两个示例分别走 **if/else 范式** 与 **`bindContentCover` + `modalTransition: ModalTransition.NONE`**。

→ 而当前首页象限卡片 → `GoalDetailPage` 走的是 `globalNavStack.pushPath` **路由跳转**。要做一镜到底，很可能需把详情页从 `NavDestination` 改为 `bindContentCover` 模态页——那会撞上工程「弹层一律 `bindSheet`、HdsTabs 内容区永远在 TabBar 之下」的既有约定。

**⇒ L2 不是"补动画"，是架构级决策，须单独立项。**

## Acceptance Criteria

- [x] AC-1: 全工程不再存在「裸 `TransitionEffect`（无 `.animation()`）且非 `IDENTITY`」的失效转场。**已达成**（脚本断言「无裸 TransitionEffect 转场」PASS）。
- [x] AC-2: `MotionConstants.ets` 建立，替换范围内**无**硬编码 duration/curve 残留（不动清单外）。**已达成**：原 28 处中 21 处改 token，保留 7 处（番茄钟 9 处中 6 处数值型 + `GoalDetailPage` 800ms + 骨架 shimmer 1200ms；番茄钟另 3 处用 `CHROME_FADE_MILLIS` 本就具名）。
- [x] AC-3: 9 处转场全部按四类定义生效，位移方向与元素位置一致；**遮罩与载体动效分离**。**已达成**（构建器计数断言：`dialogCard` 4 / `overlayFade` 6 / `bottomPanel` 2 / `noTransition` 4）。
- [x] **AC-4a（L1a）**：弹层/面板/页面转场与按压反馈完成升级，零结构改动。**已达成**。
- [ ] **AC-4b（L1b）**：列表项进入/退出过渡生效。**部分达成**：
  - ✅ 已接 `listItem()` **3 处**：`AIPage:1227`（聊天气泡，**最小实验点**）、`NotificationPage:387`（通知增删）、`RoutePage:1199`（目标卡片增删）。三处 keyGenerator 均稳定、且都**不存在"换源"场景**，因此是安全子集。
  - ✅ `GoalDetailPage:215` 展开/收起区块已接入 `expandSection()`。
  - ⏸ 另 3 处 `LazyForEach`（`HomePage:1169` / `GoalHistoryPage:328` / `GoalDetailPage:495`）**刻意未接**，各有结构性原因（见上表）。
  - ❌ 两处 steps 列表（`TaskDetailPage:1300` / `GoalDetailPage:171`）**受阻于 key 稳定性**（`index + stepVersion`，其中 `stepVersion` 不可去），需先给步骤稳定身份，已另立任务。
  - ⚠️ 三处 `listItem()` 的**生效性待真机确认**：官方触发条件只点名 `ForEach`、未列 `LazyForEach`（详见 R4）。真机若无效，需改走 `BaseDataSource` 增量推送；此时这三处 transition 属"无害但无效"，可保留待数据层就位。
- [x] AC-5: `check_sync_refactor.py` 全 PASS，并新增断言覆盖 AC-1~AC-4。**已达成**：**200/200**（L0/L1a 后 196，L1b 再增 4 条）。
- [x] AC-6: 番茄钟 v4 版式与实况窗链路零改动。**已达成**：`check_pomo_immersive.py` / `check_pomo_ring_text_fit.py` 通过；脚本断言番茄钟文件未接入 token 且 `.animation` 数量保持 9。
- [ ] AC-7: 真机观感复核通过（**待用户在 DevEco build 后确认**）。

## Dependencies

- 无外部依赖；纯 UI 层改动，不触碰云同步 / 数据模型 / 存储键。
- 需用户在 DevEco 完成编译验证（本工程无 `hvigorw`，CLI 不可构建）。

## Risk

- **R1 默认转场外溢**（官方对象说明第 6 点）：一旦用 `animateTo` 包装状态变更，动画范围内所有**未配 `transition`** 的上下树组件会被自动补一个默认透明度转场。→ 不需要动效的显式配 `TransitionEffect.IDENTITY` 抑制。
- **R2 子树消失时间**（说明第 7 点）：删除整棵子树时，被删子树的**根组件**需有充足的消失转场时间；且根组件属性值若等于默认值（如 `opacity(1)`）会导致转场**不触发**，需用 `opacity(0.99)` 之类规避。
- **R3 HomePage 四象限长按拖拽重排**：`dragState.isDragging` 期间已临时禁用滑动换页，过渡不得破坏拖拽命中与四象限 `position` 换位动效。
- **R4 LazyForEach 增删过渡结论待实验裁决**：官方给出的 `transition` 触发条件**只点名 `ForEach`、未列 `LazyForEach`**；而 `onDataReloaded` 的官方语义是「键值比对，相同用缓存、不同才重建」⇒ 框架**确实在做 diff**，与原判断"无从 diff、必须改数据层"冲突。⇒ 以 `AIPage` 实验点为准。另注意 `HomePage.getActiveDataSource()` 是**按象限切换数据源**（q1~q4 四个独立实例），切象限会整列表换源 → 若接入动效必须显式抑制，否则观感"整屏重刷"。
- **R5 无障碍/低端机**：分层克制下幅度上限设为缩放 ≤0.06、位移 ≤20vp（面板例外 40vp），避免低端机掉帧与眩晕。
- **R6 `curves` 导入位置待验证**：历史上 `focusControl` 就不在 `@kit.ArkUI` 导出（报 10311006），`curves` 需在写码时先确认导入路径。

## Open Questions

见文首「实施记录」末尾——Q2（`curves` 导出）与 Q3（800ms 用途）**已解决**并附证据；Q1（减少动态效果 API）、Q4（AIPage 自绘弹窗改 `bindSheet`）、Q5（L1b 退场动效口径）仍开放。
