# Momentum（起势）

HarmonyOS 目标与时间管理应用（ArkTS + Stage 模型，端云一体化）。

以「目标 → 任务 → 步骤」三级结构管理长期目标，以艾森豪威尔四象限管理今日待办，
配合番茄钟专注计时与 AI 目标拆解，形成从规划到执行的完整闭环。

## 功能概览

### 目标与任务
- **目标路线（路线页）**：L1 目标 → L2 任务 → L3 步骤三级结构，支持分类筛选、目标历史（待开始/进行中/已完成/逾期下钻）
- **AI 拆解（AI 页）**：输入目标描述，DeepSeek（经 AGC 云函数中转，客户端零密钥）拆解为带优先级/截止时间/步骤的任务方案；对话式多轮微调，方案确认后一键落库
- **任务编辑**：手动添加/编辑任务均支持优先级（高中低）、截止时间（日期选择器）、预计耗时（分钟/小时/天单位切换 + 快捷档位）
- **L4 待办提取**：目标任务一键提取为首页待办，勾选状态双向同步（首页勾选 ↔ 目标进度 ↔ 里程碑联动）

### 四象限待办（首页）
- **智能分诊**：按「优先级 × 截止时间」自动归入四象限，跨过 24h 紧急线的任务每分钟自动"流动"换象限
- **象限内排序**：优先级降序 + 创建时间降序；任务卡实时显示截止时间（逾期标红/临期标橙）
- **长按移动**：长按任务在四象限间移动，系统自动换算底层字段（优先级/截止时间）并联动提醒重排
- **已完成折叠区**：勾选完成的任务不再凭空消失，可查看、点击撤销（联动回滚目标进度）
- **手动添加待办**：四象限快速添加入口

### 番茄钟
- 可选专注/休息时长（选择持久化）、全屏沉浸倒计时、长休息循环
- **专注-任务联动**：每轮专注完成自动累加任务的聚焦统计（N 轮 · X 分钟），任务详情页实时展示
- **双通道提醒**：前台计时 + 后台 reminderAgent 代理提醒（进程被杀也能到点触发）；放弃专注的部分时长计入统计（有二次确认）
- 实况窗（LiveView）+ 常驻通知栏倒计时，通知/震动受设置开关控制

### 云同步与账号
- 华为账号登录（华为 ID 一键登录，游客模式可用，登录不做强制）
- AGC CloudDB 端云同步（upload / download / merge 三向），冷启动自动合并
- **云库安全**：UserSyncData 仅 Creator/Administrator 可读写删（Authenticated 置空），跨账号数据隔离
- 设置项云同步：通知/提醒提前量/语言/云同步开关跨设备跟随

### 提醒体系
- 任务/目标截止提醒，提前量可自定义（截止当天/1 天/3 天/1 周，任务与目标独立设置）
- 代理提醒（reminderAgentManager）跨重启有效，完成任务/目标自动取消
- 站内通知中心：与系统通知同源记录、未读角标、点击直达详情页

### 桌面卡片
- 今日待办 2×4 卡片（EntryFormAbility），任务增删改实时推送刷新

## 架构

```
entry/src/main/ets/
├── entryability/          # 应用入口（服务初始化、深链/通知/流转路由分发）
├── entryformability/      # 桌面卡片
├── pages/                 # 页面（Navigation + Tabs，@ComponentV2）
├── viewmodel/             # @ObservedV2 单例 ViewModel（@Trace 状态 + @Computed 派生）
├── model/                 # 数据模型（toJSON/fromJSON 防御性序列化，向后兼容）
├── common/
│   ├── services/          # DeepSeek、CloudDB/云同步、账号、番茄钟、代理提醒、实况窗、反馈
│   ├── components/        # StateView、AppActionSheet、AppInfoDialog、AppReportSheet、
│   │                      # 番茄钟卡片/沉浸屏、标题栏（统一返回/菜单按钮）
│   ├── utils/             # SafeUtils（空值兜底/日期/智能耗时）、路由、日志脱敏、WantAgent 工厂
│   ├── constants/         # CommonConstants / DimensConstants（圆角/间距设计令牌）
│   ├── event/             # AppEventBus（跨 ViewModel 事件解耦）
│   └── datasource/        # LazyForEach DataSource（稳定 key）
└── widget/                # 卡片 UI
cloud_objects/             # AGC 云对象（calldeepseek 云函数部署于 AGC 控制台）
```

分层约束：页面 → ViewModel → Service/Storage；`common` 层不反向依赖 `viewmodel`；
跨 ViewModel 通信走 `AppEventBus`（如 L4 勾选 → L2/L1 进度联动、专注完成 → 任务聚焦统计）。

## 关键设计

- **状态管理**：纯 V2（@ComponentV2/@Local/@Param/@Trace/@Computed），列表走 LazyForEach + IDataSource；
  时间敏感的派生状态（四象限/今日统计）依赖每分钟刷新的时钟源，保证"紧急度"实时流动
- **设计系统**：圆角/间距统一走 `DimensConstants` Token（5 档圆角）；颜色统一 `$r('app.color.*')`
  （base/dark 双主题，深色独立色板）；弹窗三件套统一——
  操作菜单 `AppActionSheet`（底部上滑）、长文 `AppInfoDialog`（居中滚动）、AI 报告 `AppReportSheet`
- **路由**：全局 Navigation 单例栈（`RouterManager`），内置跳转防抖；深链/通知直达两条冷启动链路在 `EntryAbility` 统一调度
- **AI 调用**：客户端不持有 Key，经云函数 `calldeepseek` 中转（Key 在云函数环境变量）；
  system prompt 注入当前时间锚点 + 客户端过期 deadline 兜底平移，杜绝"生成的截止时间在过去"
- **通知直达**：WantAgent 携带 `routeName + taskId/goalId`，目标页支持仅有 id 的降级解析
- **合规**：首启隐私弹窗（不同意即退出）、AI 生成内容显式标识 + "举报"入口、登录页"暂不登录"出口、
  日志敏感信息脱敏、无强制登录

## 国际化

简体中文（base）/ English；应用内支持语言切换（重启生效）。
en_US 仍在补齐中，缺失 key 自动回退中文。

## 构建

DevEco Studio 6.1+（API 23 / 6.1.0），`build-profile.json5` 使用本机自动签名调试。

⚠️ **本工程 CLI 不可构建**：仓库内**没有 `hvigorw` 包装脚本**，`hvigorw assembleHap ...` 之类的命令行构建**无法执行**。
编译与真机验证请在 DevEco Studio 内完成（`Build → Build Hap(s)/APP(s)`）。

> 这条务必留意：任何"用命令行跑一次构建"的排查思路在本工程都走不通，
> 代码改动的编译验证只能由人工在 IDE 内完成。

## 上架状态

- [x] 包名 `com.sunshengju.momentum`，AGC 侧配置已对齐（agconnect-services.json / client_id / 云函数）
- [x] 登录合规：无强制登录，登录页提供"暂不登录"出口，返回键放行
- [x] AIGC 合规：AI 内容显式标识 + "举报"入口（走应用内反馈链路上报 CloudDB）
- [x] 云库权限收紧：UserSyncData / UserFeedback 仅 Creator/Administrator 可读写（Authenticated/World 置空），
      附校验脚本护栏（`check_sync_refactor.py`，281/281 通过）
- [x] 混淆白名单：CloudDB 序列化字段已入 `obfuscation-rules.txt` keep 规则
- [ ] 隐私政策公网 URL（应用内已有完整文案，待挂网）、正式 release 签名证书与 Profile
- [ ] AGC 控制台「AI 功能声明」等资质材料

## 安全说明

- 客户端不持有任何 API Key（AI 走云函数中转）
- 云数据库按 Creator 隔离，同账号跨设备仍为 creator，跨账号不可互访
- 日志统一脱敏（token/授权码 masked），AI 对话内容不入 public 日志
- 隐私数据本地存储，云同步默认关闭（隐私优先），开启后经 AGC 加密通道
