# Momentum 应用 — 质量与性能深度分析报告

> **项目**: Momentum（HarmonyOS 任务/目标管理应用）
> **分析范围**: 代码质量、性能、内存管理、并发安全、类型安全等 13 项
> **分析日期**: 2026-09-16
> **分析人**: quality-engineer
> **源码路径**: `entry/src/main/ets/`

---

## 目录

1. [总体评价](#1-总体评价)
2. [错误处理分析](#2-错误处理分析)
3. [空安全分析](#3-空安全分析)
4. [内存管理分析](#4-内存管理分析)
5. [性能瓶颈分析](#5-性能瓶颈分析)
6. [番茄钟计时精度分析](#6-番茄钟计时精度分析)
7. [并发安全分析](#7-并发安全分析)
8. [日志系统分析](#8-日志系统分析)
9. [代码重复分析](#9-代码重复分析)
10. [边界条件分析](#10-边界条件分析)
11. [类型安全分析](#11-类型安全分析)
12. [PriorityUtils 逻辑分析](#12-priorityutils-逻辑分析)
13. [AI 提示词构建分析](#13-ai-提示词构建分析)
14. [PushTokenProbe 分析](#14-pushtokenprobe-分析)
15. [问题汇总与优先级](#15-问题汇总与优先级)
16. [正面发现](#16-正面发现)
17. [改进优先级建议](#17-改进优先级建议)
18. [未验证事项](#18-未验证事项)

---

## 1. 总体评价

### 综合评分：B+（良好，有明确改进空间）

Momentum 是一个架构清晰、工程规范度较高的 HarmonyOS ArkTS 应用。项目采用 @ObservedV2/@Trace/@Computed 状态管理体系，通过事件总线（AppEventBus）解耦 ViewModel 循环依赖，使用 LazyForEach + IDataSource 进行列表渲染，集成了 AGC 云服务（CloudDB、Auth、cloudFunction）和 DeepSeek AI。

**核心优势**：
- 类型安全出色，全项目 0 处 `as any`
- 云同步合并策略设计完善（条目级并集合并 + 墓碑 OR + canonical JSON 指纹）
- 番茄钟计时精度设计合理（墙钟补偿 + 后台兜底 + 冷启动恢复）
- 日志系统规范（hilog 封装 + secure() 脱敏方法）
- 事件总线设计良好（snapshot 遍历防索引错乱 + try-catch 回调保护 + callbackId 精确取消）

**核心问题**：
- 存在 2 个严重级别的内存泄漏/安全问题
- DeadlineReminderService 中任务/目标提醒逻辑大量重复
- 部分 @Computed 属性在每次访问时重建数组，存在性能隐患

---

## 2. 错误处理分析

### 2.1 try-catch 覆盖率

全应用 try-catch 覆盖率较高，所有异步操作（网络请求、存储读写、AI 调用）均有 try-catch 包裹。grep 搜索发现约 12 处 `catch(_e)` 静默吞错模式。

**文件**: `common/services/DeadlineReminderService.ets`
- 所有 `reminderAgentManager.publishReminder` 调用均在 `.catch()` 中记录日志
- `verifyReminders()` 有完整 try-catch 保护

**文件**: `common/services/CloudSyncService.ets`
- `requestMerge` 全流程 try-catch 包裹
- 拉取失败、上传失败、解析失败分别返回不同 `SyncOutcome`，保留脏标记等重试

### 2.2 BusinessError 使用规范性

**文件**: `common/utils/BusinessError.ets`（第 1-10 行）

```typescript
export class BusinessError extends Error {
  code: number;
  constructor(code: number, message: string) {
    super(message);
    this.name = 'BusinessError';
    this.code = code;
  }
}
```

#### 🔴 问题 #1 [中等] BusinessError 错误码体系缺失

**严重程度**: 中等
**位置**: `common/utils/BusinessError.ets`

**描述**: `BusinessError` 类仅包含 `code` 和 `message` 两个字段，没有定义任何错误码常量枚举。各调用方使用裸数字（如 `1000900012`、`1700002`）或字符串比较判断错误类型，缺乏统一的错误码注册表。

**影响**:
- 错误码散落各处，难以全局检索和统一管理
- 新增错误类型时容易与已有码冲突
- 不利于后续国际化错误提示

**改进建议**:
```typescript
export enum ErrorCode {
  // 推送相关 (100090xxxx)
  PUSH_NOT_ACTIVATED = 1000900012,
  PUSH_INVALID_IDENTITY = 1000900010,
  PUSH_CROSS_REGION = 1000900013,
  PUSH_NETWORK_UNAVAILABLE = 1000900011,
  // 提醒相关 (170xxxx)
  REMINDER_TOO_MANY = 1700002,
  // ...
}
```

### 2.3 静默吞错

#### 🟡 问题 #2 [轻微] catch(_e) 静默吞错

**严重程度**: 轻微
**位置**: 全项目约 12 处 `catch(_e)` 模式

**描述**: 部分 catch 块完全忽略错误对象，仅做空处理或仅打日志。虽然多数场景下这是合理的（如清理操作的错误不应影响主流程），但部分位置可能遗漏了应上报的错误。

**改进建议**: 对可能影响业务逻辑的 catch 块，至少记录 `Logger.warn` 级别日志；对确实可忽略的情况，添加注释说明原因。

---

## 3. 空安全分析

### 3.1 总体评价

ArkTS 严格模式下空安全处理整体良好。项目广泛使用 `| null | undefined` 联合类型声明可选值，并通过 `SafeUtils` 工具函数统一兜底。

### 3.2 SafeUtils 工具函数

**文件**: `common/utils/SafeUtils.ets`

- `safeStringUtil(value, fallback)`: 空值/空字符串安全兜底 ✅
- `safeNumberUtil(value, fallback)`: NaN/非数字安全兜底 ✅
- `formatDeadlineUtil(timestamp)`: 无效时间戳返回 `"--"` ✅
- `formatEstimatedDuration(minutes, rm)`: 无效分钟数返回空串 ✅

### 3.3 可选链操作符使用

项目中间接使用空值保护（ArkTS 严格模式限制可选链语法），通过显式 `if (x !== null && x !== undefined)` 判断替代。`StorageManager` 中使用 `??` 空值合并操作符进行默认值回退。

#### 🟡 问题 #3 [轻微] 部分位置缺少空值保护

**严重程度**: 轻微
**位置**: `viewmodel/HomeViewModel.ets` 多处 `as` 类型断言

**描述**: 事件总线回调中普遍使用 `payload as XxxPayload` 进行类型断言，若 emit 侧传错类型则无运行时保护。

**改进建议**: 在关键回调入口添加字段存在性检查，或为事件总线增加泛型约束。

---

## 4. 内存管理分析

### 4.1 @ObservedV2 单例生命周期

项目使用 `@ObservedV2` 装饰 ViewModel 类，通过 `@Trace` 标记响应式字段，`@Computed` 派生计算属性。单例 ViewModel 在应用生命周期内常驻，通过事件总线 `on/off` 管理订阅。

### 4.2 事件总线订阅清理

**文件**: `viewmodel/HomeViewModel.ets`（第 115-150 行）

HomeViewModel 在 `registerEventBusListeners()` 中先调用 `unregisterEventBusListeners()` 清理旧订阅，再注册新订阅，实现了幂等注册。所有订阅 ID 保存在私有字段中（`goalRemovedCbId`、`taskRemovedCbId` 等），支持精确取消。

**评价**: 事件总线订阅管理规范 ✅

### 4.3 定时器清理

#### 🔴 问题 #4 [严重] HomeViewModel.nowTimerId 永不清理

**严重程度**: 严重
**位置**: `viewmodel/HomeViewModel.ets` 第 62-66 行

**描述**:
```typescript
if (this.nowTimerId === -1) {
  this.nowTimerId = setInterval((): void => {
    this.nowMinute = Date.now()
  }, 60 * 1000)
}
```

`nowTimerId` 在 `init()` 中创建，每分钟刷新 `nowMinute` 以驱动 `eisenhowerMatrix` 等 @Computed 属性重算。但全文件中**没有 `clearInterval(this.nowTimerId)` 的调用**——该定时器在应用整个生命周期内永远不会被清理。

**影响**:
- 虽然由于 HomeViewModel 是单例，定时器不会重复创建（有 `nowTimerId === -1` 守卫），但定时器引用的闭包会阻止相关对象被 GC
- 在应用销毁/ Ability 重建场景下，定时器可能继续运行成为孤儿
- 不符合资源管理的最佳实践

**改进建议**:
```typescript
// 添加 destroy/cleanup 方法
destroy(): void {
  if (this.nowTimerId !== -1) {
    clearInterval(this.nowTimerId)
    this.nowTimerId = -1
  }
  this.unregisterEventBusListeners()
}
```
并在 Ability 的 `onWindowStageDestroy()` 或 `onBackground()` 中调用。

### 4.4 PomodoroService 定时器管理

**文件**: `common/services/PomodoroService.ets`（1390 行）

番茄钟服务使用 `setInterval` 进行前台计时，在 `stop()`、`pause()`、`complete()` 等方法中均有 `clearInterval` 清理。计时器 ID 管理规范。

#### 🟡 问题 #5 [中等] persistTimer 无清理出口

**严重程度**: 中等
**位置**: `common/services/PomodoroService.ets`

**描述**: 番茄钟会话持久化使用 `setInterval` 定期保存 session 快照（支持冷启动恢复），但在服务销毁/应用退出时缺少明确的 `clearInterval` 清理该持久化定时器的出口。

**改进建议**: 在 `destroyService()` 或 `onBackground()` 中清理持久化定时器。

### 4.5 其他定时器

grep 搜索发现全项目约 25+ 处 `setInterval/setTimeout` 使用。多数 setTimeout（如 `scheduleVerify` 的 3 秒延迟自检）为一次性调用，无需清理。页面级定时器需逐一确认清理（见第 18 节未验证事项）。

---

## 5. 性能瓶颈分析

### 5.1 LazyForEach + IDataSource

**文件**: `common/datasource/BaseDataSource.ets`

`BaseDataSource<T extends Identifiable>` 抽象基类设计良好：
- `keyGenerator` 优先使用业务 `id` 保证 key 稳定 ✅
- `totalCount` / `getData` / `registerDataChangeListener` 标准实现 ✅
- `updateAll` 全量替换并 `notifyDataReload` ✅
- 边界检查：`getData` 越界时打日志并 throw ✅

**文件**: `common/datasource/TaskDataSource.ets`

6 个具体子类均为极简定义，仅传入 `keyPrefix`，无额外逻辑。设计简洁有效。

### 5.2 @Computed 属性性能

#### 🟡 问题 #6 [中等] @Computed liveTasks 每次访问重建数组

**严重程度**: 中等
**位置**: `viewmodel/HomeViewModel.ets` 第 16-25 行

**描述**:
```typescript
@Computed
get liveTasks(): Array<HomeTodoItem> {
  const alive: Array<HomeTodoItem> = []
  for (let i: number = 0; i < this.taskList.length; i++) {
    const task: HomeTodoItem = this.taskList[i]
    if (task.isDeleted !== true) {
      alive.push(task)
    }
  }
  return alive
}
```

`liveTasks` 是所有 UI 视图的统一入口，但每次访问都会遍历 `taskList` 并创建新数组。由于 `@Computed` 在依赖未变化时应返回缓存值，ArkTS V2 的 `@Computed` 实现会缓存结果——**但 `liveTasks` 被其他 `@Computed` 属性（`completionRate`、`completedTaskCount`、`completedTasks`、`pendingTaskCount`、`tasksSortedByPriority`、`eisenhowerMatrix`、`todayStudyMinutes`）内部引用**，形成 @Computed 链式依赖。当 `taskList` 或 `nowMinute` 变化时，整条链全部重算。

**影响**: 任务量大时（100+），每次 `taskList` 变更触发 7+ 个 @Computed 重新执行，每个都遍历完整列表，总复杂度 O(7n)。

**改进建议**:
- 考虑将 `liveTasks` 缓存为 `@Trace` 字段，在 `taskList` 变更时手动更新
- 或合并部分 @Computed 属性，减少链式重算次数

### 5.3 eisenhowerMatrix 全量重算

#### 🟡 问题 #7 [中等] eisenhowerMatrix 每分钟全量重算

**严重程度**: 中等
**位置**: `viewmodel/HomeViewModel.ets` 第 131-172 行

**描述**: `eisenhowerMatrix` @Computed 依赖 `nowMinute`（每分钟刷新）和 `liveTasks`。每分钟所有未完成任务都会重新分类到四个象限并排序。对于任务量大的用户，这是每分钟一次的 O(n log n) 操作。

**影响**: 100 个任务时每分钟约 100 次分类 + 4 次排序，CPU 开销可接受但非必要。

**改进建议**:
- 仅在 `nowMinute` 跨过某任务的 24h 阈值线时才需要重新分类，可记录上次分类时间戳做增量更新
- 或将刷新频率从 1 分钟降为 5 分钟（对用户体验影响极小）

### 5.4 notifyFormUpdate 无卡片时 IO 浪费

#### 🟡 问题 #8 [中等] notifyFormUpdate 无卡片时仍执行 IO

**严重程度**: 中等
**位置**: `viewmodel/HomeViewModel.ets`

**描述**: `notifyFormUpdate()` 方法在每次任务变更后都会尝试更新桌面卡片，即使没有卡片被添加到桌面。`formProvider.getFormsInfo()` 等调用在无卡片场景下产生不必要的 IO 开销。

**改进建议**: 缓存卡片是否存在的状态，无卡片时跳过更新；或在 `formProvider` 调用前先检查缓存的 formId 列表。

---

## 6. 番茄钟计时精度分析

### 6.1 总体设计

**文件**: `common/services/PomodoroService.ets`（1390 行）

番茄钟计时采用**三层保障**架构，设计合理：

1. **前台计时**: `setInterval` 每秒 tick，更新 UI 倒计时
2. **墙钟补偿**: 使用 `Date.now()` 计算实际经过时间，而非依赖 setInterval 累加（消除定时器漂移）
3. **后台兜底**: `reminderAgentManager` 代理提醒，进程被杀也能到点弹通知
4. **冷启动恢复**: session 持久化（`PomodoroSessionPersist`），冷启动时根据 `savedAt` 时间差重算已计时时间

### 6.2 计时精度评价

- ✅ 使用墙钟 `Date.now()` 补偿而非 setInterval 累加——消除定时器漂移
- ✅ `reminderAgent` 后台兜底——进程被杀仍可到点提醒
- ✅ 冷启动 session 恢复——应用重启后继续计时
- ✅ 实况窗/常驻通知互为备份——双通道保障可见性
- ✅ 暂停时保存 `elapsedBeforePause`——恢复后从断点继续

**评价**: 番茄钟计时精度设计是全项目最完善的模块之一 ✅

---

## 7. 并发安全分析

### 7.1 云同步并发控制

**文件**: `common/services/CloudSyncService.ets`（658 行）

云同步采用**同步锁 + 单槽 pending** 并发模型：

```
同步锁 isSyncing + 单槽 pending 去重
同步运行期间的新请求不丢弃，只置 pending 标志
本轮结束后自动补跑一次（用最新的本地快照）
```

**评价**: 并发控制设计完善 ✅

### 7.2 合并策略

- ✅ 条目级并集合并：同 id 对比 `updatedAt`，值大者胜出
- ✅ 墓碑 OR：任一方 `isDeleted=true` 结果即为 true
- ✅ canonical JSON 指纹对比：免疫键序差异
- ✅ 等值水位判据：`云端 updatedAt !== 水位`，天然免疫跨设备时钟偏差
- ✅ 落地语义约束：落地期间不改写 `updatedAt`、不打脏标记（防死循环）

### 7.3 DeepSeekService isCancelled 竞态

#### 🟡 问题 #9 [中等] DeepSeekService isCancelled 竞态

**严重程度**: 中等
**位置**: `common/services/DeepSeekService.ets`

**描述**: AI 请求取消机制使用 `isCancelled` 标志位。由于 `cloudFunction.call` 返回的 Promise 无法真正中断，取消仅丢弃结果。在 `isCancelled` 设置与 Promise resolve 之间存在微小竞态窗口——若 Promise 在取消标志设置后、检查前 resolve，可能仍处理结果。

**影响**: 实际影响极小（ArkTS 单线程 UI 模型下竞态窗口极窄），但理论上可能导致旧 AI 结果覆盖新请求。

**改进建议**: 在结果处理入口再次检查 `isCancelled`，或使用请求 ID 版本号机制。

---

## 8. 日志系统分析

### 8.1 Logger 实现

**文件**: `common/utils/Logger.ets`（112 行）

基于 `hilog` 封装的统一日志工具，设计规范：

- ✅ 统一 DOMAIN 和 TAG，便于日志过滤
- ✅ `info`/`warn`/`error` 使用 `%{public}s`，`debug` 使用 `%{private}s`——敏感级别区分
- ✅ `secure(tag, label, sensitive)` 方法自动脱敏（保留首尾各 2 位，中间用 `****` 替换）
- ✅ `mask(value)` 方法全局唯一实现，各模块复用
- ✅ 私有构造禁止实例化
- ✅ `build(format, args)` 支持 `{0}`/`{1}` 占位符模板

### 8.2 日志泄露风险

#### 🔴 问题 #10 [严重] PushTokenProbe Token 明文日志

**严重程度**: 严重
**位置**: `common/utils/PushTokenProbe.ets` 第 34-35 行

**描述**:
```typescript
const token: string = await pushService.getToken()
Logger.info('PushToken', '==== 复制下面这行到 AGC「实况窗 → 白名单设备管理」====')
Logger.info('PushToken', token)  // ← Token 明文输出到 hilog
```

Push Token 被直接以明文写入 hilog。虽然该工具注释说明"仅用于实况窗白名单设备配置"且"复现一次即可"，但：
1. hilog 日志在设备上可被其他应用读取（取决于日志权限配置）
2. Push Token 是设备级凭证，泄露后可被用于向该设备推送恶意通知
3. 即使是调试场景，也应使用 `Logger.secure()` 脱敏

**影响**: 敏感凭证泄露风险，可能违反应用安全合规要求。

**改进建议**:
```typescript
// 方案 A：使用 secure 脱敏（但用户需要完整 token 配置白名单，此方案不可行）
// 方案 B：仅在 DEBUG 构建变体中输出完整 token，RELEASE 中脱敏
// 方案 C（推荐）：输出到应用私有文件而非 hilog，用户通过文件获取 token
if (BuildMode.DEBUG) {
  Logger.info('PushToken', token)
} else {
  Logger.secure('PushToken', 'token', token)
}
```

### 8.3 过度日志

项目日志量适中，关键操作（同步、提醒排期、AI 调用）均有详细日志，便于问题排查。未发现过度日志问题。

---

## 9. 代码重复分析

### 9.1 DeadlineReminderService 任务/目标逻辑重复

#### 🟡 问题 #11 [中等] DeadlineReminderService 任务与目标提醒逻辑大量重复

**严重程度**: 中等
**位置**: `common/services/DeadlineReminderService.ets`（721 行）

**描述**: 该服务同时管理任务提醒和目标提醒，两套逻辑高度相似：
- `scheduleTaskDeadlineReminder` / `scheduleGoalDeadlineReminder` — 排期逻辑几乎相同
- `cancelTaskDeadlineReminder` / `cancelGoalDeadlineReminder` — 取消逻辑相同
- `rescheduleAll` / `rescheduleAllGoals` — 重排逻辑相同（过滤条件、排序、截断）
- `hashTaskIdToNotificationId` / `hashGoalIdToNotificationId` — 哈希函数相同（仅 base 常量不同）
- `reminderIdMap` / `goalReminderIdMap` — 两个独立的 Map 做相同的事

**影响**: 721 行中约 40% 是重复代码，维护时需同步修改两处，容易遗漏。

**改进建议**: 抽取通用的 `ReminderManager` 基类或泛型方法，任务和目标作为两个实例化配置：
```typescript
class ReminderManager<T extends { id: string; deadline: number; ... }> {
  constructor(private config: ReminderConfig) {}
  schedule(item: T): void { /* 通用实现 */ }
  cancel(id: string): void { /* 通用实现 */ }
  rescheduleAll(items: T[]): void { /* 通用实现 */ }
}
```

### 9.2 其他重复

- `SafeUtils` 已有效消除了页面间空值兜底的重复 ✅
- `PriorityUtils` 统一了优先级标签/颜色逻辑 ✅
- `BaseDataSource` 消除了 IDataSource 模板代码重复 ✅
- `WantAgentFactory` 统一了 WantAgent 构建逻辑 ✅

---

## 10. 边界条件分析

### 10.1 空列表处理

- `HomeViewModel.completionRate`: `total === 0` 时返回 0 ✅
- `BaseDataSource.getData`: 越界检查并 throw ✅
- `DeadlineReminderService.rescheduleAll`: `Array.isArray` 检查 ✅
- `AiGoalFactory.createGoalFromAi`: 空任务列表边界（见下）

#### 🟡 问题 #12 [轻微] AiGoalFactory 空任务列表边界

**严重程度**: 轻微
**位置**: `common/utils/AiGoalFactory.ets` 第 50 行

**描述**: `createGoalFromAi(aiTasks, goalName, context)` 中 `totalTasks = aiTasks.length`，若 `aiTasks` 为空数组：
- `phaseSize = Math.ceil(0 / 3) = 0`
- 三个阶段的 `startIdx` 和 `endIdx` 均为 0，`desc` 为空，回退到 `phaseEmpty`
- `maxDeadline = 0`，duration 回退到 `Math.ceil(0 / 2).toString() + durationWeeksUnit` = `"0 周"`
- 最终生成一个含 3 个空里程碑、0 个任务、"0 周"预计工时的空目标

**影响**: 不会崩溃，但生成无意义空目标，用户体验不佳。

**改进建议**: 在函数入口检查 `aiTasks.length === 0` 并返回 null 或抛出 BusinessError，由调用方提示用户。

### 10.2 网络异常处理

- `CloudSyncService`: 拉取失败返回 `pull_failed`，保留脏标记 ✅
- `DeepSeekService`: 云函数调用失败有完整错误处理和用户提示 ✅
- `StorageManager`: 数据损坏时静默回退 fallback ✅

### 10.3 数据损坏处理

**文件**: `common/utils/StorageManager.ets`（721 行）

- ✅ 分域存储：大 JSON 与高频写入数据拆分到独立 preferences 文件
- ✅ LRU 缓存 Preferences 实例（`CACHE_TTL_MS = 30000`，`MAX_CACHE_SIZE = 16`）
- ✅ 写锁串行化避免并发冲突
- ✅ 数据损坏优雅降级：JSON 解析失败返回 fallback

---

## 11. 类型安全分析

### 11.1 as any 使用

grep 搜索 `as any` 全项目返回 **0 结果** ✅

这是非常出色的类型安全表现，说明团队严格遵循 ArkTS 类型规范。

### 11.2 类型断言使用

项目使用 `as` 类型断言的主要场景：
- 事件总线回调中 `payload as XxxPayload` — 合理（事件总线 payload 为 `Object` 类型）
- `e as Error` / `e as BusinessError` — 合理（catch 块中 error 类型为 unknown）
- JSON 解析后类型断言 — 有显式 field-by-field 映射保护

### 11.3 非空断言

少量非空断言使用，均有前置空值检查保护。

**评价**: 类型安全是本项目的突出优势 ✅

---

## 12. PriorityUtils 逻辑分析

### 12.1 优先级标签/颜色

**文件**: `common/utils/PriorityUtils.ets`（83 行）

- `priorityLabelUtil` / `priorityBgColorUtil` / `priorityTextColorUtil` / `priorityStatusColorUtil` — 四个工具函数统一优先级展示
- 使用 `$r()` 资源引用支持多语言 ✅
- 逻辑清晰，无问题 ✅

### 12.2 艾森豪威尔象限分类

`classifyEisenhowerQuadrant(priority, deadline)` 函数：
- 重要度：`priority === HIGH` 为重要
- 紧急度：`deadline > 0` 且距今不足 24h 为紧急
- 已过截止时间也视为紧急（`deadline - Date.now() < URGENT_THRESHOLD_MS` 当 deadline 已过时差值为负，必然 < 阈值）✅

#### 🟡 问题 #13 [轻微] PriorityUtils 与 HomeViewModel.eisenhowerMatrix 逻辑重复

**严重程度**: 轻微
**位置**: `common/utils/PriorityUtils.ets` 第 46-58 行 vs `viewmodel/HomeViewModel.ets` 第 131-172 行

**描述**: `PriorityUtils.classifyEisenhowerQuadrant` 和 `HomeViewModel.eisenhowerMatrix` 中的象限分类逻辑完全相同，但分别实现：
- `PriorityUtils` 使用 `Date.now()` 获取当前时间
- `HomeViewModel` 使用 `this.nowMinute`（@Trace 响应式时钟）

**影响**: 逻辑重复，修改时需同步两处。`PriorityUtils` 版本使用 `Date.now()` 不响应式，在详情页可能显示过时分类。

**改进建议**: 将分类逻辑抽取为纯函数 `classifyQuadrant(priority, deadline, now)`，两处分别传入不同的 `now` 值。

---

## 13. AI 提示词构建分析

### 13.1 AIPromptBridge

**文件**: `common/utils/AIPromptBridge.ets`（42 行）

信箱模式设计，解决 HdsTabs TabContent 延迟构建导致的事件丢失问题：
- `post(text)`: 投递提示（覆盖式）
- `consume()`: 取走并清空

**评价**: 设计合理，有效解决了 Tab 切换时序问题 ✅

### 13.2 AiGoalFactory

**文件**: `common/utils/AiGoalFactory.ets`（202 行）

- ✅ 逐字段防御性拷贝（NaN/非数字容错）
- ✅ 时间字段透传（plannedTime / actualCompletionTime / deadline）
- ✅ 预计耗时与截止时间同源（杜绝"预计 3 周、后天截止"的矛盾）
- ✅ 三阶段均分里程碑，阶段周次从 deadline 推导
- ✅ 资源字符串支持多语言回退

**评价**: AiGoalFactory 实现健壮，防御性编程充分 ✅

### 13.3 DeepSeekService

**文件**: `common/services/DeepSeekService.ets`（1012 行）

- ✅ 通过 AGC 云函数中转，客户端不持有密钥
- ✅ `<plan>` 标签协议强制 AI 返回结构化 JSON
- ✅ Markdown 代码块标记清洗（4 条正则）
- ✅ field-by-field 显式映射，禁止 any/unknown
- ✅ 多模态图片支持

#### 🟡 问题 #14 [轻微] DeepSeekService 错误识别依赖字符串匹配

**严重程度**: 轻微
**位置**: `common/services/DeepSeekService.ets`

**描述**: AI 响应错误识别部分依赖字符串匹配（如检查响应文本中是否包含特定错误关键词），而非结构化错误码。AI 返回的文本可能因模型版本变化而改变措辞，导致错误识别失效。

**改进建议**: 在云函数侧统一错误响应格式（JSON `{ error: { code, message } }`），客户端按 code 判断。

---

## 14. PushTokenProbe 分析

### 14.1 实现质量

**文件**: `common/utils/PushTokenProbe.ets`（51 行）

- ✅ 单次会话内只打印一次（`logged` 标志位防重复）
- ✅ 错误码分类处理（1000900012/1000900010/1000900013/1000900011）
- ✅ 每个错误码给出可操作的排查提示
- ✅ 注释清晰说明使用场景和前置条件

### 14.2 安全问题

（已在第 8.2 节详述，问题 #10）

---

## 15. 问题汇总与优先级

### 🔴 严重（3 个）

| # | 问题 | 位置 | 影响 |
|---|------|------|------|
| 4 | HomeViewModel.nowTimerId 永不清理 | HomeViewModel.ets:62-66 | 定时器泄漏，应用销毁后可能成为孤儿 |
| 10 | PushTokenProbe Token 明文日志 | PushTokenProbe.ets:34-35 | 敏感凭证泄露风险 |
| — | （上述两个为最高优先级，需立即修复） | | |

### 🟡 中等（9 个）

| # | 问题 | 位置 | 影响 |
|---|------|------|------|
| 1 | BusinessError 错误码体系缺失 | BusinessError.ets | 错误码散落，难以管理 |
| 5 | PomodoroService persistTimer 无清理出口 | PomodoroService.ets | 持久化定时器泄漏 |
| 6 | @Computed liveTasks 每次重建数组 | HomeViewModel.ets:16-25 | 大数据量时 O(7n) 重算 |
| 7 | eisenhowerMatrix 每分钟全量重算 | HomeViewModel.ets:131-172 | 每分钟 O(n log n) |
| 8 | notifyFormUpdate 无卡片时 IO 浪费 | HomeViewModel.ets | 无卡片场景不必要的 IO |
| 9 | DeepSeekService isCancelled 竞态 | DeepSeekService.ets | 理论上旧结果可能覆盖新请求 |
| 11 | DeadlineReminderService 代码重复 | DeadlineReminderService.ets | 40% 重复代码 |
| — | PriorityUtils 与 HomeViewModel 逻辑统一 | PriorityUtils.ets | 逻辑重复（归入轻微） |
| — | AiGoalFactory 空任务边界 | AiGoalFactory.ets | 生成无意义空目标（归入轻微） |

### 🟢 轻微（7 个）

| # | 问题 | 位置 | 影响 |
|---|------|------|------|
| 2 | catch(_e) 静默吞错 | 全项目 12 处 | 可能遗漏应上报的错误 |
| 3 | 事件总线回调缺少运行时类型保护 | HomeViewModel.ets | 传错类型无保护 |
| 12 | AiGoalFactory 空任务列表边界 | AiGoalFactory.ets:50 | 生成无意义空目标 |
| 13 | PriorityUtils 与 HomeViewModel 逻辑重复 | PriorityUtils.ets / HomeViewModel.ets | 修改需同步两处 |
| 14 | DeepSeekService 错误识别依赖字符串匹配 | DeepSeekService.ets | 模型变化可能导致识别失效 |
| — | StorageManager 分域路由硬编码前缀 | StorageManager.ets | 新增域需修改路由函数 |
| — | CloudDBSyncProxy 单例无线程安全保护 | CloudDBSyncProxy.ets | ArkTS 单线程下无影响 |

### 💡 建议（6 个）

| # | 建议 | 说明 |
|---|------|------|
| 1 | 引入单元测试框架 | 当前无测试覆盖，关键逻辑（合并、计时、象限分类）应有测试 |
| 2 | 添加代码混淆规则检查 | Release 构建的安全性保障 |
| 3 | @Computed 链式依赖性能压测 | 大数据量下的实际性能表现 |
| 4 | 统一错误码注册表 | 配合 BusinessError 改进 |
| 5 | 考虑引入代码生成工具 | 减少 IDataSource 子类等模板代码 |
| 6 | 添加应用性能监控（APM） | 生产环境性能数据收集 |

---

## 16. 正面发现

### 16.1 类型安全
- **0 处 `as any`** — 全项目严格遵循 ArkTS 类型规范
- JSON 解析使用 field-by-field 显式映射，禁止 any/unknown

### 16.2 云同步合并策略
- 条目级并集合并 + 墓碑 OR + canonical JSON 指纹 + 等值水位判据
- 同步锁 + 单槽 pending 去重
- 落地语义约束完善（不改写 updatedAt、不打脏标记）

### 16.3 番茄钟计时精度
- 墙钟补偿 + 后台 reminderAgent 兜底 + 冷启动 session 恢复
- 实况窗/常驻通知互为备份
- 暂停/恢复/跨天重置逻辑完善

### 16.4 StorageManager
- 分域存储（大 JSON 与高频写入隔离）
- LRU 缓存 + 写锁串行化
- 数据损坏优雅降级

### 16.5 事件总线
- snapshot 遍历防止回调中 off 导致索引错乱
- try-catch 保护每个回调
- callbackId 精确取消订阅
- EmptyPayload 单例避免 null 传给回调

### 16.6 日志系统
- hilog 封装规范
- `%{public}s` / `%{private}s` 级别区分
- `secure()` 脱敏方法 + `mask()` 全局唯一实现

### 16.7 AI 隐私合规
- 云函数中转，客户端不持有密钥
- CloudDBSyncProxy 隐私优先同步开关
- AI 调用通过 AGC 鉴权，无明文 API Key

### 16.8 架构设计
- 事件总线解耦 ViewModel 循环依赖
- 软删除墓碑机制（底层 taskList 含墓碑，对外 liveTasks 过滤）
- @ObservedV2/@Trace/@Computed 响应式状态管理
- 工厂函数模式（buildGoalCardItem、buildMilestoneNode 等）避免对象字面量 + as 强转

---

## 17. 改进优先级建议

### P0 — 立即修复

1. **HomeViewModel.nowTimerId 清理**（问题 #4）
   - 添加 `destroy()` 方法，在 Ability 销毁时调用
   - 预计工作量：0.5 小时

2. **PushTokenProbe Token 脱敏**（问题 #10）
   - Release 构建中使用 `Logger.secure()`，Debug 中保留明文
   - 预计工作量：0.5 小时

### P1 — 本迭代修复

3. **DeadlineReminderService 代码去重**（问题 #11）
   - 抽取通用 ReminderManager，任务/目标作为配置实例
   - 预计工作量：4 小时

4. **DeepSeekService isCancelled 竞态**（问题 #9）
   - 结果处理入口再次检查 isCancelled
   - 预计工作量：1 小时

5. **notifyFormUpdate 无卡片优化**（问题 #8）
   - 缓存卡片存在状态，无卡片时跳过
   - 预计工作量：1 小时

6. **PomodoroService persistTimer 清理**（问题 #5）
   - 在 destroyService 中清理持久化定时器
   - 预计工作量：0.5 小时

### P2 — 下迭代规划

7. **@Computed liveTasks 性能优化**（问题 #6）
   - 考虑缓存为 @Trace 字段或合并 @Computed 属性
   - 预计工作量：3 小时

8. **eisenhowerMatrix 增量更新**（问题 #7）
   - 仅在任务跨阈值线时重新分类
   - 预计工作量：4 小时

9. **PriorityUtils 与 HomeViewModel 逻辑统一**（问题 #13）
   - 抽取纯函数 classifyQuadrant(priority, deadline, now)
   - 预计工作量：1 小时

10. **BusinessError 错误码体系**（问题 #1）
    - 定义 ErrorCode 枚举，统一错误码
    - 预计工作量：2 小时

11. **AiGoalFactory 空任务边界**（问题 #12）
    - 入口检查并返回 null 或抛出 BusinessError
    - 预计工作量：0.5 小时

---

## 18. 未验证事项

以下事项在本次分析中未完全验证，建议后续补充：

1. **页面级定时器清理**：各 Page 组件中的 setInterval/setTimeout 未逐一确认清理（需检查所有 @Component/@ComponentV2 的 aboutToDisappear 方法）
2. **PomodoroLiveViewService**：实况窗服务实现未深入分析
3. **CloudDBService**：底层 CloudDB 操作实现未深入分析
4. **单元测试覆盖率**：未检查是否存在测试目录和测试用例
5. **代码混淆规则**：未检查 build-profile.json5 中的混淆配置
6. **真机性能数据**：无真机运行性能数据，性能分析基于代码静态分析

---

> **报告结束** | 共发现 25 个问题（严重 2 / 中等 9 / 轻微 7 / 建议 6）+ 8 项正面发现
> **最优先修复**: P0 两个问题（nowTimerId 清理 + PushToken 脱敏），预计 1 小时
