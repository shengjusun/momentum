# Momentum

HarmonyOS 任务/目标管理应用（ArkTS + Stage 模型，端云一体化）。

## 功能概览

- **四象限待办（首页）**：基于艾森豪威尔法则自动分类今日任务，支持长按拖拽排序、半模态管理、AI 今日排序建议
- **目标路线（路线页）**：L1 目标 → L2 任务 → L3 步骤 三级结构，AI 一键拆解生成，支持分类筛选与目标历史
- **AI 拆解（AI 页）**：输入目标，DeepSeek（经 AGC 云函数中转）拆解为可执行任务并加入路线；对话式多轮微调
- **番茄钟**：可选时长、全屏沉浸倒计时、多轮循环、后台 reminderAgent 兜底、常驻通知栏倒计时
- **云同步**：华为账号登录 + AGC CloudDB（GrowthDeskZone），upload / download / merge 三向同步，按 id 并集合并防冲突
- **桌面卡片**：今日待办卡片（EntryFormAbility），同步本地数据
- **小艺接入**：注册 `ohos.want.action.createGoal` / `viewTodos` 意图与技能调用

## 架构

```
entry/src/main/ets/
├── entryability/          # 应用入口（服务初始化、深链/通知/流转路由分发）
├── entryformability/      # 桌面卡片
├── pages/                 # 页面（Navigation + Tabs，@ComponentV2）
├── viewmodel/             # @ObservedV2 单例 ViewModel（@Trace 状态）
├── model/                 # 数据模型（toJSON/fromJSON 防御性序列化）
├── common/
│   ├── services/          # DeepSeek、CloudDB/云同步、账号、番茄钟、提醒等服务
│   ├── components/        # StateView、DuneTabBar、番茄钟卡片/沉浸屏
│   ├── utils/             # 存储续排、路由、日志、WantAgent 工厂等
│   ├── constants/         # CommonConstants（设计令牌/存储键/常量）
│   └── datasource/        # LazyForEach DataSource
└── widget/                # 卡片 UI
cloud_objects/             # AGC 云对象（calldeepseek 云函数部署于 AGC 控制台）
```

分层约束：页面 → ViewModel → Service/Storage；`common` 层不反向依赖 `viewmodel`。

## 关键设计

- **状态管理**：纯 V2（@ComponentV2/@Local/@Param/@Trace/@Computed），列表走 LazyForEach + IDataSource 手动同步
- **设计令牌**：字体大小统一走 `CommonConstants.FONT_SIZE_*`；颜色统一 `$r('app.color.*')`（base/dark 双主题）
- **路由**：全局 Navigation 单例栈（`RouterManager`），内置 600ms 跳转防抖；深链/通知直达/小艺意图四条冷启动链路在 `EntryAbility` 统一调度
- **AI 调用**：客户端不持有 Key，经云函数 `calldeepseek` 中转（Key 在云函数环境变量）
- **通知直达**：WantAgent 携带 `routeName + taskId/goalId`，目标页支持仅有 id 的降级解析

## 构建

DevEco Studio 6.1+（API 23 / 6.1.0），`build-profile.json5` 使用本机自动签名调试。

```
hvigorw assembleHap --mode module -p module=entry@default
```

## 上架前待办

- [ ] 更换正式包名（当前 `com.example.Momentum` 不可上架，需同步重建 AGC 项目/云函数/CloudDB/签名）
- [ ] 创建 release 签名证书与 Profile（调试密码勿入库）
- [ ] `DETECT_GESTURE` 为受限权限：申请 AGC 白名单，否则下线 RoutePage 握姿功能并移除权限声明
