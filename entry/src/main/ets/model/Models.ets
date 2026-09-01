/** 统一数据模型导出入口（Barrel File），聚合各业务域文件的 re-export */

// 1. 基础类型与枚举 (BaseTypes)
export {
  Id,
  Timestamp,
  TaskStatus,
  TaskPriority,
  parseTaskPriority, // 顶层函数，ArkTS enum 不支持内部方法
  getPriorityValue, // 优先级数值获取（用于排序）
  TabConfig,
  LoadState
} from './BaseTypes'

// 2. 首页待办 (HomeModels) - L4
export {
  HomeStat,
  HomeTodoItemJSON,
  HomeTodoItem,
  buildHomeTodoItem,
  isValidHomeTodoItem,
  hydrateHomeTodoItem,
  snapshotHomeTodoItem,
  // 艾森豪威尔四象限法则
  EisenhowerQuadrant,
  EisenhowerQuadrantData,
  EisenhowerMatrix
} from './HomeModels'

// 3. 路线与目标 (RouteModels) - L1
export {
  MilestoneNodeJSON,
  MilestoneNode,
  GoalCardItemJSON,
  GoalCardItem,
  GoalDetailRouteNavParam,
  buildGoalCardItem,
  isValidGoalCardItem,
  hydrateGoalCardItem,
  snapshotGoalCardItem
} from './RouteModels'

// 4. 任务详情与AI生成 (TaskModels) - L2/L3
export {
  TaskNode,
  AiGeneratedTaskJSON,
  AiGeneratedTask,
  TaskStepJSON,
  TaskStep,
  TaskDetailItemJSON,
  TaskDetailItem,
  TaskDetailRouteParam,
  RouteParam,
  TaskDetailRouteNavParam,
  getCompletedStepsSafe,
  isStepCompleted,
  hydrateAiGeneratedTask,
  snapshotAiGeneratedTask
} from './TaskModels'

// 5. AI 拆解状态 (AiModels)
export {
  AiBreakdownResult
} from './AiModels'

// 5.1 站内通知中心 (NotificationModels)
export {
  AppNotificationItem,
  AppNotificationSnapshot
} from './NotificationModels'

// 6. 我的页面 (ProfileModels)
export {
  UserProfile,
  AppSettingsJSON,
  AppSettings,
  ProfileSettingItem,
  SelectOptionItem
} from './ProfileModels'

// 7. 网络请求 API 模型 (DeepSeekModels)
export {
  DeepSeekRequest,
  DeepSeekResponseFormat,
  DeepSeekHeader,
  DeepSeekMessage,
  DeepSeekResponse,
  DeepSeekChoice,
  DeepSeekUsage,
  DeepSeekTaskJson,
  DeepSeekPlanJson,
  AIParseResult,
  ExtractPlanResult,
  ChatRole,
  ChatMessage,
  JsonFieldValue,
  TextContentPart,
  ImageContentPart,
  ImageUrlData,
  ContentPart,
  buildTextContentPart,
  buildImageContentPart,
  isStringContent,
  contentToString
} from './DeepSeekModels'

// 8. 全局常量 (AppConstants)
export {

  MAX_INPUT_LENGTH,
  DEEPSEEK_SYSTEM_PROMPT
} from './AppConstants'
