/**
 * @file AI 智能拆解页 (Phase 2 - V2 纯净版 + 套娃结构 + 同文件组件化)
 * @description 像素级实现：
 *   - 顶部输入区：标题 + TextArea 多行输入 (maxLength 200) + 字数统计
 *   - 场景芯片区：3-4 个预设目标，点击填入输入框
 *   - 操作按钮区：主按钮"开始 AI 拆解"，Loading 态显示 LoadingProgress
 *   - 结果展示区：统计 + List 卡片（可展开 steps）+ 底部悬浮"一键加入路线"
 *
 * 套娃结构（4 级架构）：
 *   - AI 拆解后生成 1 个 L1 目标（含 3 个 L2 任务，每个 L2 任务含 2-3 个 L3 步骤）
 *   - 一键加入路线：仅入库 L1 目标到 routeVM（**不再自动创建 L4 待办**）
 *   - L4 待办由用户在目标详情页通过"加入待办"按钮触发摘取流
 *
 * V2 规范：
 *   - @ComponentV2 + @Local
 *   - 严禁 @State / @Prop / @Link
 *   - async/await + try/catch 处理异步
 *   - 严禁 Stack 配 justifyContent
 *   - 严禁将 Promise 赋值给 void
 *
 * 同文件组件化（方案A）：
 *   - 9 个 @ComponentV2 子组件 + 1 个根页面
 *   - 所有 @Local 状态保留在根页面，子组件仅通过 @Param 接收只读数据
 *   - 所有数据操作/状态修改/路由/弹窗通过 @Event 向上回调给根页面
 *   - 列表条目组件使用 @ReusableV2 复用优化
 *
 * 功能保底：
 *   - 多行输入：使用 TextArea（原生支持多行 + maxLength + placeholder）
 *   - 密码框：使用 InputType.Password
 *   - 回车提交：onSubmit((keyCode: EnterKeyType) => {...})
 *
 * @module pages
 * @date 2026-06-19
 */

import { promptAction } from '@kit.ArkUI'
import {
  AiGeneratedTask,
  AIParseResult,
  buildHomeTodoItem,
  ChatMessage,
  ChatRole,
  DeepSeekMessage,
  DeepSeekPlanJson,
  FeedbackRouteNavParam,
  GoalCardItem,
  HomeTodoItem,
  TaskPriority,
  TaskStatus
} from '../model/Models'
import { createGoalFromAi } from '../common/utils/AiGoalFactory'
import { DeepSeekService } from '../common/services/DeepSeekService'
import { PomodoroService } from '../common/services/PomodoroService'
import { ProfileAnalyzerService } from '../common/services/ProfileAnalyzerService'
import { StorageManager } from '../common/utils/StorageManager'
import { Logger } from '../common/utils/Logger'
import { safeAreaHelper } from '../common/utils/SafeAreaHelper'
import { DimensConstants } from '../common/constants/DimensConstants'
import { CommonConstants } from '../common/constants/CommonConstants'
import { MAX_INPUT_LENGTH } from '../model/AppConstants'
import { formatEstimatedDuration } from '../common/utils/SafeUtils'
import { aiPromptBridge, AIPendingPrompt } from '../common/utils/AIPromptBridge'

import { routeVM } from '../viewmodel/RoutePageViewModel'
import { settingsVM } from '../viewmodel/SettingsViewModel'
import { homeVM } from '../viewmodel/HomeViewModel'
import { profileVM } from '../viewmodel/ProfileViewModel'
import { ROUTE_NAME, navigateTo, pushNavPath } from '../common/RouterManager'
import { ChatMessageDataSource } from '../common/datasource/TaskDataSource'
import { backgroundTaskManager } from '@kit.BackgroundTasksKit'
import { CommonTitleBar } from '../common/components/CommonTitleBar'
import { AppActionSheet, AppActionSheetItem } from '../common/components/AppActionSheet'
import { ChatMessageItem, AiScenarioChipSection, AiGuideSection, AiPlanSideSection } from '../common/components/ai/AIChatComponents'
import { MotionHelper } from '../common/utils/MotionHelper'


// 用命名空间方式引用 DelaySuspendInfo
type DelaySuspendInfo = backgroundTaskManager.DelaySuspendInfo

// 平板横屏双栏阈值（与全局 lg 断点一致）。
// 注意：AI 页双栏以页面实测宽度（onAreaChange）判定，不依赖全局断点监听——
// 实测是物理事实，不存在"监听没绑上所以平板永远走手机布局"的失效路径。
const WIDE_PANE_MIN_WIDTH: number = CommonConstants.BREAKPOINT_LG

/** 底部主输入框的组件 ID（供 UIContext.getFocusController().requestFocus 定位；路线页空态跳转过来时自动聚焦） */
const AI_PROMPT_INPUT_ID: string = 'ai_prompt_input'

/**
 * AI 对话历史中的 plan 快照（用于构造 history 时序列化）
 * 刻意只保留任务名/优先级/截止日：完整任务对象（含 steps）会让多轮对话的
 * history 膨胀到数千 token，显著拖慢响应；AI 上下文只需要"之前提过哪些任务"
 */
interface AIHistoryPlanTask {
  taskName: string
  priority: string
  deadline: number
}

interface AIHistoryPlanSnapshot {
  goalName: string
  tasks: Array<AIHistoryPlanTask>
}

/** 从完整任务对象提取历史快照所需的精简字段 */
function buildHistoryPlanTask(t: AiGeneratedTask): AIHistoryPlanTask {
  const item: AIHistoryPlanTask = {
    taskName: t.taskName,
    priority: String(t.priority),
    deadline: t.deadline
  }
  return item
}

/* ============================================================
 * 根组件：AIPage — AI 智能拆解页
 * ============================================================ */

/**
 * AI 智能拆解页
 *
 * 职责：
 *   - 持有全部 @Local 页面级状态
 *   - 执行全部业务方法（网络请求、数据持久化、路由跳转、弹窗）
 *   - 组装子组件（build 方法仅含条件判断 + 子组件标签）
 */
@ComponentV2
export struct AIPage {
  /** 用户输入文本（底部输入框） */
  @Local inputText: string = ''
  /** 是否正在等待 AI 回复（用于禁用发送按钮） */
  @Local isLoading: boolean = false
  /**
   * Step 2 重构：对话流消息列表（仅内存，绝不入库）
   * 红线：chatMessages 仅存在于 @Local，绝不写入 routeVM.goals 或 CloudSyncService.SyncDataBundle
   *       落库动作仅通过 handleConfirmPlan → createGoalFromAi + routeVM.addGoal
   */
  @Local chatMessages: Array<ChatMessage> = []
  /**
   * LazyForEach 数据源：与 chatMessages 同步
   * - chatMessages 数组引用变更时通过 @Monitor 同步
   * - chatMessages[i] 属性变更由 @Trace 直接驱动子组件 @Param 刷新
   */
  @Local chatDataSource: ChatMessageDataSource = new ChatMessageDataSource()
  /** 已展开的任务步骤索引 Map<messageId_taskIndex, true>（替代旧 Set，支持多消息隔离） */
  @Local expandedTaskIndices: Map<string, boolean> = new Map()
  /** lg 侧栏任务卡独立展开状态（不与消息流共享，避免互相影响） */
  @Local sideExpandedTaskIndices: Map<string, boolean> = new Map()
  @Local requestSeq: number = 0

  /**
   * 监听 chatMessages 引用变更，同步至 LazyForEach 数据源
   * - 仅数组引用变更触发（如 push 后重新赋值）
   * - 数组元素属性变更（如 isConfirmed）由 @Trace 直接驱动，无需此处同步
   */
  @Monitor('chatMessages')
  onChatMessagesChange(): void {
    this.chatDataSource.updateAll(this.chatMessages)
  }

  private bgRequestInfo: DelaySuspendInfo | null = null
  /**
   * 深度修复：组件存活标记
   * 防止页面已销毁/未挂载时仍被回调污染状态。
   */
  private isAttached: boolean = false

  /** ArkTS 重构：场景芯片按压态（替代废弃的 .stateStyles） */
  @Local pressedChipId: string = ''
  /** ArkTS 重构：任务卡按压态（替代废弃的 .stateStyles） */
  @Local pressedTaskCardId: string = ''

  /**
   * 登录态拦截：改为**在 build() 中直接派生**（不再用 @Local 快照）。
   *
   * 原实现只在 aboutToAppear / onPageShow 里赋值。游客是在应用内点"去登录"拉起 LoginPage，
   * 而 LoginPage 是压在 Navigation 栈上的 NavDestination，MainTab 及其 Tabs 并未真正 onPageHide，
   * 返回时 onPageShow 不保证触发 → 快照不更新 → 出现"已经登录了，AI 页却还显示去登录"。
   *
   * 现统一读 `settingsVM.userProfile.isLoggedIn`（SettingsViewModel @ObservedV2 → userProfile @Trace
   * → isLoggedIn @Trace 的完整响应链），登录成功即自动重渲染当前所有读取该值的界面。
   * 消费点：`isAiCloudUsable()`（= 已登录 ∧ 云同步开启）——门控横幅、输入框 `.enabled()`、
   * 发送按钮、场景芯片填入，共 10 处统一走它。
   */

  /** 编辑任务弹窗状态 */
  @Local showEditTaskDialog: boolean = false
  /** 统一操作面板状态 */
  @Local showActionSheet: boolean = false
  @Local actionSheetTitle: string = ''
  @Local actionSheetItems: AppActionSheetItem[] = []
  /** 当前编辑的任务所属消息 ID */
  @Local editingMessageId: string = ''
  /** 当前编辑的任务 ID */
  @Local editingTaskId: string = ''
  /** 编辑中的任务名称 */
  @Local editTaskName: string = ''
  /** 编辑中的预估时间（分钟） */
  @Local editTaskTime: string = ''

  /** 对话列表 Scroller 控制器（用于自动滚动到底部 + 悬浮按钮） */
  private scroller: Scroller = new Scroller()
  /** 是否显示"滚动到底部"悬浮按钮（仅当列表偏离底部时显示） */
  @Local showScrollToBottom: boolean = false

  /** DeepSeek 服务单例 */
  private service: DeepSeekService = DeepSeekService.getInstance()
  /** 打字机逐字显示定时器（-1 = 未在进行） */
  private revealTimerId: number = -1
  /** 正在逐字显示的消息 ID（空串 = 未在进行） */
  private revealMsgId: string = ''


  /**
   * Step 2 重构：切换指定消息内任务的步骤展开状态
   * @param messageId - 消息 ID
   * @param taskIndex - 任务在该消息内的索引
   */
  private toggleExpand(messageId: string, taskIndex: number): void {
    const key: string = messageId + '_' + taskIndex.toString()
    const newMap: Map<string, boolean> = new Map(this.expandedTaskIndices)
    if (newMap.has(key)) {
      newMap.delete(key)
    } else {
      newMap.set(key, true)
    }
    this.expandedTaskIndices = newMap
  }

  /** lg 侧栏：切换侧栏任务卡的步骤展开状态（独立 Map，不影响消息流） */
  private toggleSideExpand(messageId: string, taskIndex: number): void {
    const key: string = messageId + '_' + taskIndex.toString()
    const newMap: Map<string, boolean> = new Map(this.sideExpandedTaskIndices)
    if (newMap.has(key)) {
      newMap.delete(key)
    } else {
      newMap.set(key, true)
    }
    this.sideExpandedTaskIndices = newMap
  }

  /** lg 侧栏：最新一条已生成的拆解方案消息（assistant 且携带任务且非流式） */
  @Computed
  get latestPlanMessage(): ChatMessage | null {
    let latest: ChatMessage | null = null
    for (let i = 0; i < this.chatMessages.length; i++) {
      const msg: ChatMessage = this.chatMessages[i]
      if (this.isPlanMessage(msg)) {
        latest = msg
      }
    }
    return latest
  }

  /**
   * 是否存在多条方案（≥2 条）。
   * 右栏恒为最新一份、左栏保留历史方案卡片；仅当确有历史时才在右栏标「最新」，
   * 避免只有一条方案时出现无意义的标识。
   */
  @Computed
  get hasPlanHistory(): boolean {
    let count: number = 0
    for (let i: number = 0; i < this.chatMessages.length; i++) {
      if (this.isPlanMessage(this.chatMessages[i])) {
        count++
      }
    }
    return count > 1
  }

  /** 实测内容区宽度（onAreaChange 上报），平板双栏的唯一判定来源 */
  @Local contentWidth: number = 0

  /** 是否宽屏双栏布局：页面实测宽度 ≥ lg 阈值（840vp） */
  private isWidePane(): boolean {
    return this.contentWidth >= WIDE_PANE_MIN_WIDTH
  }

  /**
   * 云端 AI 能力是否可用（**唯一判据**，10 处门控统一走它）。
   *
   * 为什么必须同时要求登录态：
   *   原实现只判 `settings.syncEnabled`。而 `syncEnabled` 的语义是"云同步开关"，
   *   **登出流程不保证把它复位为 false** → 存在"游客会话里 syncEnabled 仍为 true，
   *   于是输入框可编辑、可发起 AI 请求"的口子。
   *   加上 `isLoggedIn` 后，未登录一律锁死，与"游客模式下数据只留本地"的口径一致。
   *
   * 产品语义（已知耦合，待决策）：已登录但**手动关闭云同步**时 AI 也会被锁，
   *   因为 AI 拆解需把文本上传云端。若将来要解耦（AI 走后端云函数，不依赖 CloudDB
   *   同步），只需改这一处。
   */
  private isAiCloudUsable(): boolean {
    return settingsVM.userProfile.isLoggedIn && settingsVM.settings.syncEnabled
  }

  /** 方案消息判定：assistant 且携带任务且非流式（聊天流隐藏与右栏展示共用同一谓词） */
  private isPlanMessage(msg: ChatMessage): boolean {
    return msg.role === 'assistant' && msg.tasks.length > 0 && !msg.isStreaming
  }

  /**
   * 宽屏双栏：仅「最新一条」方案的任务卡片移到右侧方案栏；
   * 历史方案的卡片仍留在对话流中（文字 + 卡片 + 确认按钮都在），
   * 便于用户回看、对比，或觉得新方案不合适时改用旧方案。
   */
  private shouldHidePlanCards(msg: ChatMessage): boolean {
    if (!this.isWidePane() || msg.role !== 'assistant' || msg.tasks.length === 0) {
      return false
    }
    const latest: ChatMessage | null = this.latestPlanMessage
    return latest !== null && latest.id === msg.id
  }

  /** 内容列限宽：宽屏双栏铺满（聊天 layoutWeight + 右侧方案栏），手机保持限宽居中 */
  private getContentConstraint(): ConstraintSizeOptions {
    if (this.isWidePane()) {
      const full: ConstraintSizeOptions = { maxWidth: '100%' }
      return full
    }
    const capped: ConstraintSizeOptions = { maxWidth: DimensConstants.CONTENT_MAX_WIDTH }
    return capped
  }

  /**
   * Step 2 重构：打开编辑任务弹窗（微调）
   * 用当前任务数据填充编辑表单
   *
   * @param messageId - 任务所属消息 ID
   * @param task - 要编辑的 AI 生成任务
   */
  private handleEditTask(messageId: string, task: AiGeneratedTask): void {
    if (!task || !task.id) return
    this.editingMessageId = messageId
    this.editingTaskId = task.id
    this.editTaskName = task.taskName
    this.editTaskTime = task.estimatedTime > 0 ? task.estimatedTime.toString() : ''
    this.showEditTaskDialog = true
    Logger.info('AIPage', 'handleEditTask: msg=' + messageId + ', taskId=' + task.id)
  }

  /**
   * 保存编辑结果
   * Step 2 重构：在 chatMessages 中查找并更新对应任务
   */
  private saveEditTask(): void {
    if (!this.editingTaskId || this.editingTaskId.length === 0) return
    const trimmedName: string = this.editTaskName.trim()
    if (trimmedName.length === 0) {
      promptAction.showToast({
        message: getContext(this).resourceManager.getStringSync($r('app.string.toast_task_name_required').id),
        duration: 1500
      })
      return
    }
    const timeNum: number = parseInt(this.editTaskTime, 10)
    const safeTime: number = isNaN(timeNum) || timeNum < 1 ? 1 : Math.floor(timeNum)

    // Step 2 重构：在 chatMessages 中查找任务并更新（@Trace 触发响应式刷新）
    const task: AiGeneratedTask | null = this.findTaskInMessages(this.editingMessageId, this.editingTaskId)
    if (task === null) {
      this.showEditTaskDialog = false
      return
    }
    task.taskName = trimmedName
    task.estimatedTime = safeTime

    // 触发 chatMessages 响应式刷新（重新赋值数组）
    this.chatMessages = [...this.chatMessages]

    this.showEditTaskDialog = false
    Logger.info('AIPage', 'saveEditTask: msg=' + this.editingMessageId +
      ', taskId=' + this.editingTaskId +
      ', name=' + trimmedName + ', time=' + safeTime.toString())
  }

  /**
   * Step 2 重构：删除 AI 生成任务（带确认弹窗）
   *
   * @param messageId - 任务所属消息 ID
   * @param task - 要删除的任务
   */
  private handleDeleteTask(messageId: string, task: AiGeneratedTask): void {
    if (!task || !task.id) return
    // 统一 ActionSheet：替代系统 showDialog 兜底样式
    this.actionSheetTitle = getContext(this).resourceManager.getStringSync($r('app.string.ai_delete_confirm_message').id)
    this.actionSheetItems = [
      {
        label: getContext(this).resourceManager.getStringSync($r('app.string.btn_confirm_delete').id),
        danger: true,
        action: (): void => {
          if (!this.isAttached) return
          this.doDeleteTask(messageId, task.id)
        }
      }
    ]
    this.showActionSheet = true
  }

  /**
   * 任务卡片「⋯」更多操作：弹出操作面板（微调 / 删除）
   * 复用 handleEditTask / handleDeleteTask（后者自身会再弹一次确认面板）
   */
  private handleTaskMoreActions(messageId: string, task: AiGeneratedTask): void {
    if (!task || !task.id) return
    const rm = getContext(this).resourceManager
    this.actionSheetTitle = task.taskName
    this.actionSheetItems = [
      {
        label: rm.getStringSync($r('app.string.ai_edit_task').id),
        action: (): void => {
          if (!this.isAttached) return
          this.handleEditTask(messageId, task)
        }
      },
      {
        label: rm.getStringSync($r('app.string.ai_delete_task').id),
        danger: true,
        action: (): void => {
          if (!this.isAttached) return
          this.handleDeleteTask(messageId, task)
        }
      }
    ]
    this.showActionSheet = true
  }

  /** lg 侧栏：一键展开 / 收起该方案下全部任务的步骤 */
  private setSideExpandAll(messageId: string, expand: boolean): void {
    let taskCount: number = 0
    for (let i: number = 0; i < this.chatMessages.length; i++) {
      if (this.chatMessages[i].id === messageId) {
        taskCount = this.chatMessages[i].tasks.length
        break
      }
    }
    const newMap: Map<string, boolean> = new Map(this.sideExpandedTaskIndices)
    for (let i: number = 0; i < taskCount; i++) {
      const key: string = messageId + '_' + i.toString()
      if (expand) {
        newMap.set(key, true)
      } else {
        newMap.delete(key)
      }
    }
    this.sideExpandedTaskIndices = newMap
  }

  /**
   * Step 2 重构：实际执行删除操作
   * 从指定消息的 tasks 数组中移除任务
   *
   * @param messageId - 消息 ID
   * @param taskId - 要删除的任务 ID
   */
  private doDeleteTask(messageId: string, taskId: string): void {
    if (!messageId || !taskId) return
    const msgIndex: number = this.findMessageIndexById(messageId)
    if (msgIndex < 0) return
    const msg: ChatMessage = this.chatMessages[msgIndex]
    const initialLen: number = msg.tasks.length
    const newList: AiGeneratedTask[] = []
    for (let i: number = 0; i < msg.tasks.length; i++) {
      if (msg.tasks[i].id !== taskId) {
        newList.push(msg.tasks[i])
      }
    }
    if (newList.length === initialLen) return
    // V2 响应式：ChatMessage 已是 @ObservedV2 class，直接修改 @Trace tasks 即可触发刷新
    msg.tasks = newList
    Logger.info('AIPage', 'doDeleteTask: msg=' + messageId + ', taskId=' + taskId +
      ', remaining=' + newList.length.toString())
  }

  /**
   * Step 2 重构：根据消息 ID 查找 chatMessages 中的索引
   */
  private findMessageIndexById(messageId: string): number {
    for (let i: number = 0; i < this.chatMessages.length; i++) {
      if (this.chatMessages[i].id === messageId) return i
    }
    return -1
  }

  /**
   * Step 2 重构：在指定消息内根据任务 ID 查找任务（返回引用，可直接修改 @Trace 属性）
   */
  private findTaskInMessages(messageId: string, taskId: string): AiGeneratedTask | null {
    const msgIndex: number = this.findMessageIndexById(messageId)
    if (msgIndex < 0) return null
    const msg: ChatMessage = this.chatMessages[msgIndex]
    for (let i: number = 0; i < msg.tasks.length; i++) {
      if (msg.tasks[i].id === taskId) return msg.tasks[i]
    }
    return null
  }

  /**
   * Step 2 重构：发送消息（对话流主入口）
   *
   * 流程：
   *   1. 用户输入构造为 ChatMessage(role=user) 推入 chatMessages
   *   2. 构造空的 AI ChatMessage(isStreaming=true) 推入 chatMessages
   *   3. 将历史 chatMessages（排除 isStreaming 空消息）映射为 history 传给 service
   *   4. 收到 AIParseResult 后，更新刚才那个 AI ChatMessage 的 text/tasks/goalName
   *
   * 红线：chatMessages 仅内存，绝不入库；落库仅通过 handleConfirmPlan
   */

  /**
   * 发送消息：构造用户消息 + AI 占位消息，调用 DeepSeek 生成拆解方案
   */
  private async handleSendMessage(): Promise<void> {
    // [P0-privacy] 云端同步关闭时拦截 AI 网络请求
    if (!this.isAiCloudUsable()) {
      promptAction.showToast({
        message: $r('app.string.ai_cloud_sync_required_toast'),
        duration: 2000
      })
      Logger.info('AIPage', 'handleSendMessage blocked: cloud sync disabled')
      return
    }
    const text: string = this.inputText.trim()
    if (text.length === 0) {
      promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_input_required').id) })
      return
    }
    if (this.isLoading) {
      return
    }

    // 深度修复：请求序列号（防止旧回调污染新状态）
    this.requestSeq += 1
    const localSeq: number = this.requestSeq

    // 1. 构造用户消息并推入 chatMessages
    const userMsgId: string = 'msg_user_' + Date.now().toString()
    const userMsg: ChatMessage = new ChatMessage(userMsgId, 'user', text, [], '', false, false)
    this.chatMessages = [...this.chatMessages, userMsg]

    // 2. 构造空的 AI 消息（isStreaming=true，UI 显示 loading）
    const aiMsgId: string = 'msg_ai_' + Date.now().toString()
    const aiMsg: ChatMessage = new ChatMessage(aiMsgId, 'assistant', '', [], '', true, false)
    this.chatMessages = [...this.chatMessages, aiMsg]

    // 自动滚动到底部（展示最新的 loading 气泡）
    this.scrollToBottom()

    // 3. 清空输入框，置 loading
    this.inputText = ''
    this.isLoading = true

    // 4. 申请后台长时任务
    try {
      this.bgRequestInfo = backgroundTaskManager.requestSuspendDelay(
        'AIGenerate',
        (): void => {
          Logger.warn('AIPage', 'background suspend delay expired, request may be killed')
        }
      )
    } catch (e) {
      Logger.warn('AIPage', 'requestSuspendDelay failed: ' + (e as Error).message)
    }

    Logger.info('AIPage', 'handleSendMessage: seq=' + localSeq.toString() +
      ', userMsgId=' + userMsgId + ', aiMsgId=' + aiMsgId)

    try {
      // 5. 构造多轮对话 history（过滤掉当前 isStreaming 的空 AI 消息，只取 role + text）
      // 注：chatMessages 中已包含本次刚推入的 user 消息 + isStreaming=true 的 AI 空消息
      //      history 应只包含"本次之前的"完整对话，故排除最后两条（user + streaming AI）
      // 修复：AI 消息需补上 <plan> 标签，让 AI 能看到自己之前拆解的任务结构（避免失忆）
      // 限制：最多保留最近 16 条（8 轮对话），防止极端情况下 token 超限
      const history: Array<DeepSeekMessage> = []
      const excludeTail: number = 2 // 排除刚推入的 user + streaming AI
      const maxHistory: number = 16 // 8 轮对话 = 16 条消息
      const historyEnd: number = Math.max(0, this.chatMessages.length - excludeTail)
      const startIdx: number = Math.max(0, historyEnd - maxHistory)
      // 上次被跳过的 user 消息（用于补位：当 error assistant 被移除时，其前的 user 也应跳过）
      let lastSkippedUser: boolean = false
      for (let i: number = startIdx; i < historyEnd; i++) {
        const msg: ChatMessage = this.chatMessages[i]
        // 跳过空消息或 streaming 中的消息
        if (msg.text.length === 0 || msg.isStreaming) continue
        // 跳过 assistant 错误消息（防止"AI 生成失败"等文本污染 DeepSeek 上下文导致 400）
        if (msg.role === 'assistant' && msg.tasks.length === 0 && !msg.isConfirmed) {
          if (msg.text.indexOf('失败') >= 0 || msg.text.indexOf('错误') >= 0 ||
            msg.text.indexOf('重试') >= 0 || msg.text.indexOf('稍后') >= 0 ||
            msg.text.indexOf('异常') >= 0 || msg.text.indexOf('HTTP') >= 0) {
            // 标记：上一次推入的 user 消息需要被移除（避免 user → (error) → user 连续 user 违规）
            lastSkippedUser = true
            Logger.info('AIPage', 'history: skip error assistant msg at index ' + i.toString() +
              ', text=' + msg.text.substring(0, 50))
            continue
          }
        }
        // 如果上一个 error assistant 被跳过，其前面的 user 消息也应跳过
        if (lastSkippedUser && msg.role === 'user') {
          lastSkippedUser = false
          Logger.info('AIPage', 'history: skip user msg after error assistant, id=' + msg.id)
          continue
        }
        lastSkippedUser = false
        let content: string = msg.text
        // AI 消息且携带任务：补上精简版 <plan> 标签，让 AI 能看到自己之前拆解过什么（不传完整结构，控制 token）
        if (msg.role === 'assistant' && msg.tasks.length > 0) {
          const planTasks: Array<AIHistoryPlanTask> = []
          for (let i: number = 0; i < msg.tasks.length; i++) {
            planTasks.push(buildHistoryPlanTask(msg.tasks[i]))
          }
          const planObj: AIHistoryPlanSnapshot = {
            goalName: msg.goalName,
            tasks: planTasks
          }
          content = msg.text + '\n<plan>\n' + JSON.stringify(planObj) + '\n</plan>'
        }
        const historyMsg: DeepSeekMessage = {
          role: msg.role,
          content: content
        }
        history.push(historyMsg)
      }
      // 边界修复：如果 error assistant 是 history 窗口最后一条，其前的 user 仍在 history 末尾，
      // 后续 buildRequest 会追加 currentUserInput，导致连续两个 user 违规
      if (lastSkippedUser && history.length > 0 &&
        history[history.length - 1].role === 'user') {
        Logger.info('AIPage', 'history: pop trailing user after error assistant at boundary')
        history.pop()
      }
      Logger.info('AIPage', 'handleSendMessage: history 构造完成, count=' + history.length.toString() +
        ', startIdx=' + startIdx.toString() + ', historyEnd=' + historyEnd.toString())

      // 6. 获取用户画像摘要（fire-and-forget 风格，失败不阻断 AI 调用）
      let profilePrompt: string = ''
      try {
        profilePrompt = await ProfileAnalyzerService.buildProfilePrompt(
          routeVM, homeVM, PomodoroService.getInstance())
        if (profilePrompt.length > 0) {
          Logger.info('AIPage', 'profilePrompt: ' + profilePrompt)
        }
      } catch (e) {
        Logger.warn('AIPage', 'buildProfilePrompt failed, skip: ' + (e as Error).message)
      }

      // 7. 调用 DeepSeekService（传入 history + 当前用户输入 + 画像，service 内部拼 system+profile+history+user）
      //    M2 云函数中转：移除 apiKey 参数，由云函数环境变量持有密钥
      const result: AIParseResult = await this.service.generateTasks(
        history, text, profilePrompt, [])

      // 深度修复：校验 seq + 组件存活
      if (localSeq !== this.requestSeq) {
        Logger.info('AIPage', 'stale response, seq=' + localSeq.toString() + ', discarded')
        return
      }
      if (!this.isAttached) {
        Logger.info('AIPage', 'component detached, discarded')
        return
      }

      // 6. 更新刚才那个 AI 消息
      const msgIndex: number = this.findMessageIndexById(aiMsgId)
      if (msgIndex < 0) {
        Logger.warn('AIPage', 'ai message not found after await: ' + aiMsgId)
        return
      }
      // V2 响应式：ChatMessage 已是 @ObservedV2 class，直接修改 @Trace 属性即可触发 @Param 刷新
      // 无需构造新对象替换数组元素，@Trace 会自动通知 @Param 监听器
      const aiMsg2: ChatMessage = this.chatMessages[msgIndex]
      aiMsg2.tasks = result.tasks
      aiMsg2.goalName = result.goalName
      // 打字机逐字显示（伪流式）：文本从空逐段追加，任务卡与确认按钮在显示完成后出现
      this.startTypewriterReveal(aiMsgId, result.text)
      Logger.info('AIPage', 'handleSendMessage success, aiMsgId=' + aiMsgId +
        ', textLen=' + result.text.length.toString() +
        ', goalName=' + result.goalName +
        ', tasks=' + result.tasks.length.toString())
    } catch (e) {
      if (localSeq !== this.requestSeq) {
        Logger.info('AIPage', 'stale error, seq=' + localSeq.toString() + ', discarded')
        return
      }
      if (!this.isAttached) return

      const err: Error = e as Error
      Logger.error('AIPage', 'handleSendMessage failed: ' + err.message)
      // 更新 AI 消息为错误态（在气泡内显示错误文本）
      const msgIndex: number = this.findMessageIndexById(aiMsgId)
      if (msgIndex >= 0) {
        // V2 响应式：ChatMessage 已是 @ObservedV2 class，直接改 @Trace 属性
        const errMsgObj: ChatMessage = this.chatMessages[msgIndex]
        errMsgObj.text = getContext(this).resourceManager.getStringSync($r('app.string.error_generic_toast').id)
        errMsgObj.isStreaming = false
      }

      // M2 云函数中转：错误提示统一化，不再区分 API Key 失效
      const errMsg: string = err.message
      promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.error_generic_toast').id), duration: 2000 })
      Logger.error('AIPage', 'handleSendMessage AI failed: ' + errMsg)
    } finally {
      // 修复：finally 必须无条件重置 isLoading，否则任何边界情况都会导致永久卡死
      // （原条件 localSeq === this.requestSeq 在 requestSeq 被改时会跳过重置，导致下次发送被拦截）
      this.isLoading = false
      this.releaseBackgroundTask()
    }
  }

  /**
   * 举报 AI 生成内容（合规要求：AIGC 应用需提供便捷举报入口）
   * 复用反馈页，以 report 模式打开（标题/分类/文案切换为举报语义）
   *
   * @param messageId - 被举报的 AI 消息 ID（仅用于日志溯源，内容由用户在举报页描述）
   */
  private handleReportAiContent(messageId: string): void {
    Logger.info('AIPage', 'handleReportAiContent: open report page for message=' + messageId)
    const param: FeedbackRouteNavParam = { mode: 'report' }
    pushNavPath(ROUTE_NAME.FEEDBACK, param)
  }

  /**
   * Step 2 重构：确认使用此方案（加入路线）
   *
   * 红线（绝对不可破坏）：
   *   - 仅通过 createGoalFromAi + routeVM.addGoal 落库
   *   - 不直接操作 routeVM.goals 或 CloudSyncService
   *   - chatMessages 仅更新 isConfirmed 标记（内存态）
   *
   * @param messageId - AI 消息 ID
   */
  private async handleConfirmPlan(messageId: string): Promise<void> {
    const msgIndex: number = this.findMessageIndexById(messageId)
    if (msgIndex < 0) {
      Logger.warn('AIPage', 'handleConfirmPlan: message not found: ' + messageId)
      return
    }
    const msg: ChatMessage = this.chatMessages[msgIndex]
    if (msg.isConfirmed) {
      Logger.info('AIPage', 'handleConfirmPlan: already confirmed: ' + messageId)
      return
    }
    if (msg.tasks.length === 0) {
      promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_no_tasks_to_add').id) })
      return
    }

    // goalName 转义（去除换行/截断），优先用 AI 返回的 goalName，缺失时从用户最近一条消息截取
    let rawGoalName: string = msg.goalName.trim()
    if (rawGoalName.length === 0) {
      rawGoalName = this.findLatestUserTextBefore(messageId)
    }
    const goalName: string = rawGoalName.length > 0 ?
      rawGoalName.replace(/[\r\n]+/g, ' ').substring(0, 50) :
      getContext(this).resourceManager.getStringSync($r('app.string.ai_default_goal_name').id)

    // 红线：通过 AiGoalFactory + routeVM.addGoal 单一入库路径
    const newGoal: GoalCardItem = createGoalFromAi(msg.tasks, goalName, getContext(this))

    try {
      routeVM.addGoal(newGoal)
      Logger.info('AIPage', 'handleConfirmPlan: routeVM.addGoal success, goalId=' + newGoal.id +
        ', name=' + newGoal.name + ', tasks=' + newGoal.tasks.length.toString())
    } catch (e) {
      const err: Error = e as Error
      Logger.error('AIPage', 'handleConfirmPlan: routeVM.addGoal FAILED: ' + err.message)
      promptAction.showToast({
        message: getContext(this).resourceManager.getStringSync($r('app.string.toast_goal_add_failed_prefix').id) +
          getContext(this).resourceManager.getStringSync($r('app.string.error_generic_toast').id),
        duration: 2000
      })
      return
    }

    // 标记该消息为已确认（仅内存态，刷新 UI 为"已加入路线 ✓"）
    // V2 响应式：ChatMessage 已是 @ObservedV2 class，直接改 @Trace isConfirmed
    this.chatMessages[msgIndex].isConfirmed = true

    // 首次使用场景引导开启系统通知：确认方案意味着产生了带 deadline 的任务，
    // 不开通知则截止提醒会静默失败。fire-and-forget，不阻断主流程
    profileVM.ensureNotificationEnabled().catch((e: Error): void => {
      Logger.warn('AIPage', 'ensureNotificationEnabled failed: ' + e.message)
    })

    promptAction.showToast({
      message: getContext(this).resourceManager.getStringSync($r('app.string.toast_goal_added_prefix').id) +
        newGoal.name +
        getContext(this).resourceManager.getStringSync($r('app.string.toast_goal_added_task_infix').id) +
        newGoal.tasks.length.toString() +
        getContext(this).resourceManager.getStringSync($r('app.string.toast_goal_added_task_suffix').id),
      duration: 2000
    })

    // 自动将高优先级任务同步到首页待办清单（失败不阻断目标创建流程）
    try {
      const allTasks: AiGeneratedTask[] = newGoal.tasks
      const highPriorityTasks: AiGeneratedTask[] = []
      for (let i: number = 0; i < allTasks.length; i++) {
        if (allTasks[i].priority === TaskPriority.HIGH) {
          highPriorityTasks.push(allTasks[i])
        }
      }
      // 筛选策略：优先高优先级，不足 2 个则从原数组取前 2 个补足
      const MAX_SYNC_COUNT: number = 2
      let selectedTasks: AiGeneratedTask[] = []
      if (highPriorityTasks.length >= MAX_SYNC_COUNT) {
        selectedTasks = highPriorityTasks.slice(0, MAX_SYNC_COUNT)
      } else {
        selectedTasks = highPriorityTasks.slice()
        for (let i: number = 0; i < allTasks.length && selectedTasks.length < MAX_SYNC_COUNT; i++) {
          const t: AiGeneratedTask = allTasks[i]
          if (t.priority !== TaskPriority.HIGH) {
            selectedTasks.push(t)
          }
        }
      }
      // 逐个构造 HomeTodoItem 并加入首页待办
      let addedCount: number = 0
      for (let i: number = 0; i < selectedTasks.length; i++) {
        const aiTask: AiGeneratedTask = selectedTasks[i]
        const todoId: string = 'home_ai_' + newGoal.id + '_' + aiTask.id
        const durationStr: string = formatEstimatedDuration(aiTask.estimatedTime > 0 ? aiTask.estimatedTime : 30, getContext(this).resourceManager)
        const todo: HomeTodoItem = buildHomeTodoItem(
          todoId,
          aiTask.taskName,
          newGoal.name,
          durationStr,
          aiTask.priority,
          false,
          Date.now(),
          aiTask.id,
          newGoal.id,
          0,
          0,
          aiTask.deadline
        )
        const ok: boolean = homeVM.addExtractedTask(todo)
        if (ok) {
          addedCount++
        }
      }
      if (addedCount > 0) {
        promptAction.showToast({
          message: getContext(this).resourceManager.getStringSync($r('app.string.ai_added_tasks_to_todo_prefix').id) +
            addedCount.toString() +
            getContext(this).resourceManager.getStringSync($r('app.string.ai_added_tasks_to_todo_suffix').id),
          duration: 2000
        })
        Logger.info('AIPage', 'handleConfirmPlan: synced ' + addedCount.toString() +
          ' tasks to home todo, goalId=' + newGoal.id)
      }
    } catch (e) {
      Logger.warn('AIPage', 'handleConfirmPlan: sync tasks to home todo failed: ' +
        (e as Error).message + ', goalId=' + newGoal.id)
    }
  }

  /**
   * Step 2 重构：查找指定 AI 消息之前最近一条用户消息文本（用于 goalName fallback）
   */
  private findLatestUserTextBefore(messageId: string): string {
    const msgIndex: number = this.findMessageIndexById(messageId)
    if (msgIndex < 0) return ''
    // 从 msgIndex-1 倒序查找 role=user 的消息
    for (let i: number = msgIndex - 1; i >= 0; i--) {
      if (this.chatMessages[i].role === 'user') {
        return this.chatMessages[i].text
      }
    }
    return ''
  }

  /**
   * 打字机逐字显示（伪流式）：拿到完整回复后按节奏追加到 text
   * - 观感为"AI 正在打字"，替代一次性全文出现
   * - 期间 isStreaming 保持 true，任务卡与确认按钮延后出现
   * - 若上一条消息还在逐字显示中，先补全上一条再开始新的
   */
  private startTypewriterReveal(msgId: string, fullText: string): void {
    // 上一轮逐字显示未结束时：立即补全，保证同一时刻只有一条消息在逐字显示
    this.finishTypewriterReveal()
    const msgIndex: number = this.findMessageIndexById(msgId)
    if (msgIndex < 0) {
      return
    }
    const msg: ChatMessage = this.chatMessages[msgIndex]
    msg.fullText = fullText
    msg.text = ''
    msg.isStreaming = true
    // 总时长约 1.2 秒：按文本长度分片，每 40ms 追加一片。
    // 之前 24ms×60 tick：每 tick 改 @Trace text + scrollToBottom = 60 次重渲染 + 60 次滚动排队，
    // 观感与 40ms×30 无差别 → 降频减负（2026-09-17）
    const totalTicks: number = 30
    const typewriterIntervalMs: number = 40
    const chunkSize: number = Math.max(1, Math.ceil(fullText.length / totalTicks))
    this.revealMsgId = msgId
    this.revealTimerId = setInterval((): void => {
      const idx: number = this.findMessageIndexById(this.revealMsgId)
      if (idx < 0) {
        this.stopTypewriterReveal()
        return
      }
      const m: ChatMessage = this.chatMessages[idx]
      if (m.text.length >= m.fullText.length) {
        this.finishTypewriterReveal()
        return
      }
      m.text = m.fullText.substring(0, Math.min(m.fullText.length, m.text.length + chunkSize))
      this.scrollToBottom()
    }, typewriterIntervalMs) as number
  }

  /** 补全逐字显示：立即把 text 置为完整文本并结束 isStreaming 态 */
  private finishTypewriterReveal(): void {
    if (this.revealTimerId !== -1) {
      clearInterval(this.revealTimerId)
      this.revealTimerId = -1
    }
    const idx: number = this.findMessageIndexById(this.revealMsgId)
    this.revealMsgId = ''
    if (idx >= 0) {
      const m: ChatMessage = this.chatMessages[idx]
      m.text = m.fullText
      m.isStreaming = false
    }
  }

  /** 仅停止定时器（不补全文本），用于页面销毁等场景 */
  private stopTypewriterReveal(): void {
    if (this.revealTimerId !== -1) {
      clearInterval(this.revealTimerId)
      this.revealTimerId = -1
    }
    this.revealMsgId = ''
  }

  /**
   * 取消 AI 拆解请求
   */
  private handleCancel(): void {
    // 打字机逐字显示进行中：请求已返回，无网络可取消，直接补全显示
    if (this.revealTimerId !== -1) {
      this.finishTypewriterReveal()
      return
    }
    this.requestSeq += 1
    this.service.cancelRequest()
    this.isLoading = false
    this.releaseBackgroundTask()
    // Step 2 重构：将最后一条 isStreaming 的 AI 消息移除（避免气泡卡在 loading）
    if (this.chatMessages.length > 0) {
      const last: ChatMessage = this.chatMessages[this.chatMessages.length - 1]
      if (last.isStreaming) {
        this.chatMessages = this.chatMessages.slice(0, this.chatMessages.length - 1)
      }
    }
    Logger.info('AIPage', 'handleCancel: cancelled by user, seq bumped to ' + this.requestSeq.toString())
    promptAction.showToast({ message: getContext(this).resourceManager.getStringSync($r('app.string.toast_cancelled').id) })
  }

  /**
   * 对话列表滚动到底部（并隐藏悬浮按钮）
   */
  private scrollToBottom(): void {
    const total: number = this.chatMessages.length
    if (total > 0) {
      this.scroller.scrollToIndex(total - 1)
    }
    this.showScrollToBottom = false
  }

  /**
   * [Fix]: 释放后台长时任务（cancelSuspendDelay）
   */
  private releaseBackgroundTask(): void {
    if (this.bgRequestInfo !== null) {
      try {
        backgroundTaskManager.cancelSuspendDelay(this.bgRequestInfo.requestId)
        Logger.info('AIPage', 'cancelSuspendDelay done')
      } catch (e) {
        Logger.warn('AIPage', 'cancelSuspendDelay failed: ' + (e as Error).message)
      }
      this.bgRequestInfo = null
    }
  }

  /**
   * Step 2 重构：页面初始化
   * - 标记组件存活
   * - 恢复输入草稿（对话流历史不持久化，仅内存）
   */
  async aboutToAppear(): Promise<void> {
    this.isAttached = true
    await this.restoreDraft()
    // 路线页空态跳转过来的提示词：**在草稿之后处理** —— 用户明确点了示例/输入框，
    // 意图强于自动恢复的草稿，有文本时覆盖草稿
    this.consumePendingPrompt()
  }

  /**
   * 深度修复：页面销毁/隐藏前
   * - 标记组件已销毁
   * - 取消进行中的请求
   * - 保存草稿（解决"无后悔药"）
   * Step 2 重构：chatMessages 不持久化（仅内存），销毁即清空
   */
  aboutToDisappear(): void {
    this.isAttached = false
    // 停止打字机逐字显示定时器（避免销毁后定时器仍操作消息）
    this.stopTypewriterReveal()
    // 卸载时如果有未完成的请求，bump seq 避免迟到回调污染
    this.requestSeq += 1
    if (this.isLoading) {
      this.service.cancelRequest()
      this.isLoading = false
    }
    // [Fix]: 页面销毁时释放后台长时任务
    this.releaseBackgroundTask()
    this.saveDraft()
  }

  /**
   * Fix: B2-5+AIPage onPageShow状态刷新
   * M2 云函数中转：移除 API Key 状态检查（Key 已存放于云函数环境变量）
   * Fix: B2-8+AIPage登录态拦截
   * 检查登录态，未登录则禁用 AI 功能
   */
  onPageShow(): void {
    // 登录态不在此处刷新：未登录拦截已改为在 build() 中直接派生自 settingsVM.userProfile.isLoggedIn，
    // 登录成功（@Trace 变更）即触发重渲染，不依赖 onPageShow 是否触发。此处仅保留日志。
    Logger.info('AIPage', 'onPageShow, isLoggedIn=' + settingsVM.userProfile.isLoggedIn.toString())
  }

  /**
   * 深度修复：恢复草稿（解决切走/返回输入丢失）
   * // Refactor: P3-6+AppStorage草稿迁移至StorageManager
   * // Refactor: P2-4+草稿操作迁移至StorageManager
   */
  private async restoreDraft(): Promise<void> {
    try {
      const draft: string = await StorageManager.loadDraft('ai_draft_text')
      if (draft.length > 0 && this.inputText.length === 0) {
        this.inputText = draft
        Logger.info('AIPage', 'restored draft, length=' + draft.length.toString())
      }
    } catch (e) {
      Logger.warn('AIPage', 'restoreDraft failed: ' + (e as Error).message)
    }
  }

  /**
   * 深度修复：保存草稿
   * 用户输入 200 字后切走，输入不丢
   * // Refactor: P2-4+草稿操作迁移至StorageManager
   */
  private saveDraft(): void {
    StorageManager.saveDraft('ai_draft_text', this.inputText)
  }

  /**
   * 取走路线页空态投递的提示词（信箱语义，见 AIPromptBridge）
   *
   * 两个调用时机（缺一不可）：
   *   - aboutToAppear：TabContent **首次构建**（用户从没来过 AI 页）
   *   - onVisibleAreaChange：AIPage 已存在、只是被切走过（再次切回）
   * 有文本 → 预填输入框；无论有无文本 → 聚焦输入框（点击方的意图就是"开始说"）。
   */
  private consumePendingPrompt(): void {
    const pending: AIPendingPrompt | null = aiPromptBridge.consume()
    if (pending === null) {
      return
    }
    if (pending.text.length > 0) {
      this.inputText = pending.text
      Logger.info('AIPage', 'prefill prompt from route page, length=' + pending.text.length.toString())
    }
    // 延到下一轮事件循环再聚焦：aboutToAppear 阶段输入框可能尚未完成构建，
    // 立即 requestFocus 会拿不到焦点（onVisibleAreaChange 时已就绪，延迟无害）
    setTimeout((): void => {
      this.focusPromptInput()
    }, 0)
  }

  /** 聚焦底部主输入框（失败仅记日志，不影响页面） */
  private focusPromptInput(): void {
    try {
      this.getUIContext().getFocusController().requestFocus(AI_PROMPT_INPUT_ID)
    } catch (e) {
      Logger.warn('AIPage', 'requestFocus failed: ' + (e as Error).message)
    }
  }

  @Builder
  EditTaskDialogBuilder(): void {
    if (this.showEditTaskDialog) {
      Column({ space: 20 }) {
        Text($r('app.string.ai_edit_task_title'))
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .textAlign(TextAlign.Center)

        Column({ space: 12 }) {
          Text($r('app.string.ai_edit_task_name_hint'))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')

          TextInput({
            placeholder: $r('app.string.ai_edit_task_name_hint'),
            text: this.editTaskName
          })
            .height(44)
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
            .backgroundColor($r('app.color.bg_tag'))
            .borderRadius(DimensConstants.RADIUS_M)
            .padding({ left: 12, right: 12 })
            .maxLength(100)
            .onChange((value: string): void => {
              this.editTaskName = value
            })

          Text($r('app.string.ai_edit_task_time_hint'))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .margin({ top: 8 })

          TextInput({
            placeholder: $r('app.string.ai_edit_task_time_hint'),
            text: this.editTaskTime
          })
            .height(44)
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
            .backgroundColor($r('app.color.bg_tag'))
            .borderRadius(DimensConstants.RADIUS_M)
            .padding({ left: 12, right: 12 })
            .type(InputType.Number)
            .maxLength(5)
            .onChange((value: string): void => {
              this.editTaskTime = value
            })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        Row({ space: 12 }) {
          Button($r('app.string.common_cancel'))
            .type(ButtonType.Capsule)
            .layoutWeight(1)
            .height(44)
            .backgroundColor($r('app.color.bg_tag'))
            .fontColor($r('app.color.text_secondary'))
            .fontSize(14)
            .onClick((): void => {
              this.showEditTaskDialog = false
            })

          Button($r('app.string.btn_save'))
            .type(ButtonType.Capsule)
            .layoutWeight(1)
            .height(44)
            .backgroundColor($r('app.color.primary_color'))
            .fontColor($r('app.color.text_inverse'))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .onClick((): void => {
              this.saveEditTask()
            })
        }
        .width('100%')
        .margin({ top: 8 })
      }
      .width('85%')
      .constraintSize({ maxWidth: DimensConstants.SHEET_MAX_WIDTH })
      .padding(24)
      .backgroundColor($r('app.color.bg_card'))
      .borderRadius(DimensConstants.RADIUS_L)
      // 位移/缩放只能挂内层卡片：外层容器承载 overlay_mask，跟着移动会带出错误的空间暗示
      .transition(MotionHelper.dialogCard())
    }
  }

  build() {
    // Step 2 重构：对话流布局
    // 编辑弹窗 - 统一用 Stack 包裹实现层级叠加
    Stack() {
      Row() {
      Column() {
        CommonTitleBar({ title: $r('app.string.page_ai'), showBack: false })

        // ★ 游客模式（方案 2）：不再整页替换为引导卡 —— 界面照常渲染，
        //   只把「云端 AI 能力」就地锁住 + 给引导词。未登录时 settings.syncEnabled
        //   恒为 false，下方输入区的 .enabled() 与 🔒 横幅会自动生效，
        //   游客看到的是"界面可见 + 输入框灰着 + 引导词"。
        // ============ 中部：对话消息列表 ============
        if (this.chatMessages.length === 0) {
          // 空态：引导组件
          AiGuideSection()
        } else {
          // ============ 中部：对话消息列表（Stack 包裹，叠加悬浮滚动按钮） ============
          Stack({ alignContent: Alignment.BottomEnd }) {
            List({ space: 4, scroller: this.scroller }) {
              LazyForEach(this.chatDataSource, (msg: ChatMessage): void => {
                ListItem() {
                  // 平板双栏：方案消息的「文字」留在对话流，「任务卡片」由右侧方案栏呈现（避免双份）
                  // 平板双栏：对话流保留「文字」，任务卡片由右侧方案栏呈现（避免双份）
                  ChatMessageItem({
                    message: msg,
                    hidePlanCards: this.shouldHidePlanCards(msg),
                    expandedIndices: this.expandedTaskIndices,
                    pressedTaskCardId: this.pressedTaskCardId,
                    onToggleExpand: (messageId: string, taskIndex: number): void => {
                      this.toggleExpand(messageId, taskIndex)
                    },
                    onTaskCardPressedIdChange: (id: string): void => { this.pressedTaskCardId = id },
                    onMoreActions: (messageId: string, task: AiGeneratedTask): void => {
                      this.handleTaskMoreActions(messageId, task)
                    },
                    onConfirmPlan: (messageId: string): void => {
                      this.handleConfirmPlan(messageId)
                    },
                    onReportContent: (messageId: string): void => {
                      this.handleReportAiContent(messageId)
                    }
                  })
                }
                // ★ L1b-2 最小实验：验证 `LazyForEach` + `onDataReloaded` 下组件转场是否生效。
                //   本处 keyGenerator 用 `msg.id`（稳定唯一），是理想试验场。
                //   判据：生效 ⇒ 其余 5 处 LazyForEach 照做、`BaseDataSource` 无需增量改造；
                //         不生效 ⇒ 需为 BaseDataSource 增加 onDataAdd/onDataDelete 增量推送。
                .transition(MotionHelper.listItem())
              }, (msg: ChatMessage): string => msg.id)
            }
            .width('100%')
            .height('100%')
            .listDirection(Axis.Vertical)
            .cachedCount(3)
            .padding({ left: 16, right: 16, top: 16, bottom: 8 })
            .backgroundColor($r('app.color.bg_page'))
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
            .expandSafeArea([SafeAreaType.KEYBOARD])
            .onScrollIndex((first: number, last: number): void => {
              const total: number = this.chatMessages.length
              if (total > 0) {
                this.showScrollToBottom = last < total - 1
              }
            })

            // 滚动到底部悬浮按钮（仅当列表偏离底部时显示）
            if (this.showScrollToBottom) {
              Button() {
                Text('↓')
                  .fontSize(18)
                  .fontColor($r('app.color.text_secondary'))
                  .fontWeight(FontWeight.Bold)
              }
              .width(36)
              .height(36)
              .borderRadius(18)
              .backgroundColor($r('app.color.bg_card'))
              .shadow({ radius: 8, color: $r('app.color.shadow_card'), offsetX: 0, offsetY: 2 })
              .margin({ right: 16, bottom: 16 })
              .onClick((): void => {
                this.scrollToBottom()
              })
            }
          }
          .width('100%')
          .layoutWeight(1)
        }

        // ============ 底部：场景芯片 + 输入栏 ============
        Column({ space: 10 }) {
          // [P0-privacy] 云端 AI 能力不可用时的引导横幅（游客模式：锁住 + 给引导词）
          // 文案按原因分流：未登录 → 引导登录；已登录但关了云同步 → 引导去开启。
          if (!this.isAiCloudUsable()) {
            Row({ space: 6 }) {
              Text('🔒')
                .fontSize(12)
              Text(settingsVM.userProfile.isLoggedIn
                ? $r('app.string.ai_cloud_sync_required_toast')
                : $r('app.string.ai_login_required_desc'))
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .layoutWeight(1)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              // 游客态额外给一个"去登录"入口：引导词只是说明，还得给可达的动作
              if (!settingsVM.userProfile.isLoggedIn) {
                Text($r('app.string.btn_go_login'))
                  .fontSize(12)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.primary_color'))
                  .padding({ left: 6, right: 2, top: 2, bottom: 2 })
                  .onClick((): void => { navigateTo(ROUTE_NAME.LOGIN) })
              }
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .backgroundColor($r('app.color.bg_tag'))
            .borderRadius(DimensConstants.RADIUS_M)
            .alignItems(VerticalAlign.Center)
          }

          // 场景芯片（平板双栏时移至右侧方案栏空态，避免与右栏重复）
          if (!this.isWidePane()) {
            AiScenarioChipSection({
              pressedChipId: this.pressedChipId,
              onChipPressedIdChange: (id: string): void => { this.pressedChipId = id },
              onChipClick: (prompt: string): void => {
                // [P0-privacy] 同步关闭时禁用芯片填入
                if (!this.isAiCloudUsable()) return
                this.inputText = prompt
              }
            })
          }

          // 字数提示：接近上限时显示（原实现静默截断无任何提示）
          if (this.inputText.length > MAX_INPUT_LENGTH * 0.8) {
            Text(getContext(this).resourceManager.getStringSync($r('app.string.chat_input_count').id)
              .replace('%d', this.inputText.length.toString())
              .replace('%max', MAX_INPUT_LENGTH.toString()))
              .fontSize(11)
              .fontColor(this.inputText.length >= MAX_INPUT_LENGTH
                ? $r('app.color.error_color') : $r('app.color.text_tertiary'))
              .width('100%')
              .textAlign(TextAlign.End)
              .padding({ right: 20, bottom: 2 })
          }

          // 输入框 + 发送按钮
          Row({ space: 10 }) {
            TextInput({
              placeholder: $r('app.string.chat_input_placeholder'),
              text: this.inputText
            })
              // 组件 ID：路线页空态跳转过来后 requestFocus 靠它定位
              .id(AI_PROMPT_INPUT_ID)
              .layoutWeight(1)
              .height(DimensConstants.TOUCH_COMFORT)
              .fontSize(14)
              .fontColor($r('app.color.text_primary'))
              .backgroundColor($r('app.color.bg_page'))
              .borderRadius(21)
              .padding({ left: 18, right: 18 })
              .maxLength(MAX_INPUT_LENGTH)
              .enabled(!this.isLoading && this.isAiCloudUsable())
              // 关键修复：显式允许点击获取焦点
              .focusOnTouch(true)
              .onChange((value: string): void => {
                this.inputText = value
              })
              .onSubmit((_keyCode: EnterKeyType): void => {
                if (!this.isLoading && this.isAiCloudUsable()) {
                  this.handleSendMessage()
                }
              })

            if (this.isLoading) {
              // Loading 时显示取消按钮（柔和红色边框）
              Button($r('app.string.btn_cancel_generate'))
                .type(ButtonType.Capsule)
                .height(DimensConstants.TOUCH_COMFORT)
                .padding({ left: 18, right: 18 })
                .backgroundColor($r('app.color.bg_page'))
                .fontColor($r('app.color.error_color'))
                .fontSize(13)
                .border({ width: 1, color: $r('app.color.error_color') })
                .borderRadius(21)
                .onClick((): void => {
                  this.handleCancel()
                })
            } else {
              // 发送按钮（syncEnabled=false 时置灰禁用）
              // M1 多模态：syncEnabled 且 (有文本 或 有图片) 时可发送
              Button($r('app.string.chat_send'))
                .type(ButtonType.Capsule)
                .height(DimensConstants.TOUCH_COMFORT)
                .padding({ left: 22, right: 22 })
                .backgroundColor(this.isAiCloudUsable()
                  ? $r('app.color.primary_color') : $r('app.color.bg_tag'))
                .fontColor(this.isAiCloudUsable()
                  ? $r('app.color.text_inverse') : $r('app.color.text_tertiary'))
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .borderRadius(21)
                .enabled(this.isAiCloudUsable() &&
                  this.inputText.trim().length > 0)
                .shadow(this.isAiCloudUsable()
                  ? { radius: 4, color: $r('app.color.primary_color_bg'), offsetX: 0, offsetY: 2 }
                  : { radius: 0, color: $r('app.color.color_transparent'), offsetX: 0, offsetY: 0 })
                .onClick((): void => {
                  this.handleSendMessage()
                })
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .padding({
          left: 16,
          right: 16,
          top: 12,
          bottom: safeAreaHelper.getBottomWith(DimensConstants.TAB_CLEARANCE)
        })
        .backgroundColor($r('app.color.bg_card'))
        .border({ width: { top: 0.5 }, color: $r('app.color.divider') })
      }
      .constraintSize(this.getContentConstraint())
      .height('100%')
      .layoutWeight(1)

      // 宽屏侧栏：AI 拆解方案与对话同屏（对话 + 产出双栏）
      // 判定用页面实测宽度（onAreaChange），不用全局断点——见 WIDE_PANE_MIN_WIDTH 注释
      if (this.isWidePane()) {
        Divider()
          .vertical(true)
          .height('100%')
          .color($r('app.color.divider'))
          .margin({ left: 8, right: 8 })

        Column() {
          if (this.latestPlanMessage !== null) {
            AiPlanSideSection({
              planMessage: this.latestPlanMessage,
              hasPlanHistory: this.hasPlanHistory,
              expandedIndices: this.sideExpandedTaskIndices,
              pressedTaskCardId: this.pressedTaskCardId,
              onToggleExpand: (messageId: string, taskIndex: number): void => {
                this.toggleSideExpand(messageId, taskIndex)
              },
              onTaskCardPressedIdChange: (id: string): void => { this.pressedTaskCardId = id },
              onMoreActions: (messageId: string, task: AiGeneratedTask): void => {
                this.handleTaskMoreActions(messageId, task)
              },
              onToggleAllExpand: (messageId: string, expand: boolean): void => {
                this.setSideExpandAll(messageId, expand)
              },
              onConfirmPlan: (messageId: string): void => {
                this.handleConfirmPlan(messageId)
              },
              onReportContent: (messageId: string): void => {
                this.handleReportAiContent(messageId)
              }
            })
          } else {
            // 空态：尚无方案时，右栏承载提示词推荐（双栏下从输入框上方移到这里）
            Scroll() {
              Column({ space: 16 }) {
                Text($r('app.string.ai_plan_side_title'))
                  .fontSize(16)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.text_primary'))
                  .width('100%')
                Text($r('app.string.ai_plan_side_empty'))
                  .fontSize(13)
                  .fontColor($r('app.color.text_tertiary'))
                  .width('100%')
                AiScenarioChipSection({
                  pressedChipId: this.pressedChipId,
                  onChipPressedIdChange: (id: string): void => { this.pressedChipId = id },
                  onChipClick: (prompt: string): void => {
                    // [P0-privacy] 同步关闭时禁用芯片填入
                    if (!this.isAiCloudUsable()) return
                    this.inputText = prompt
                  }
                })
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 4 })
            }
            .width('100%')
            .layoutWeight(1)
            .align(Alignment.Top)
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
          }
        }
        .width(DimensConstants.SIDE_COLUMN_WIDTH)
        .height('100%')
        .backgroundColor($r('app.color.bg_card'))
        // 与左栏输入区一致：底部留出悬浮标签栏(TAB_CLEARANCE) + 系统安全区的余地，
        // 否则横屏双栏时，方案栏底部的「AI 生成标识 + 举报」会被 MainTab 的悬浮标签栏遮住
        .padding({ top: 12, bottom: safeAreaHelper.getBottomWith(DimensConstants.TAB_CLEARANCE) })
      }
      }
      // 关键：Row 默认起点对齐，手机/折叠屏分支的限宽列会被顶到左侧；
      // 居中由 justifyContent 保证（平板分支子项占满整行，居中无副作用）
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)

      // 替代 bindContentCover：使用 Stack 叠加编辑弹窗
      if (this.showEditTaskDialog) {
        Column() {
          this.EditTaskDialogBuilder()
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.overlay_mask'))
        .justifyContent(FlexAlign.Center)
        .transition(MotionHelper.overlayFade())
        .alignItems(HorizontalAlign.Center)
        .zIndex(999)
      }

      // 统一操作面板（替代系统 showDialog）
      if (this.showActionSheet) {
        AppActionSheet({
          title: this.actionSheetTitle,
          items: this.actionSheetItems,
          onDismiss: (): void => {
            this.showActionSheet = false
          }
        })
      }

    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    // 实测宽度上报：双栏判定的唯一来源（挂在全宽 Stack 上，与内容列限宽解耦，避免死循环）
    .onAreaChange((_oldArea: Area, newArea: Area): void => {
      this.contentWidth = Number(newArea.width)
      Logger.info('AIPage', 'paneWidth=' + this.contentWidth.toString() +
        ', wide=' + this.isWidePane().toString())
    })
    // 切回 AI Tab 时取走路线页投递的提示词（AIPage 是 TabContent 内容，
    // 非页面级组件，onPageShow 在切 Tab 时不会触发，只能靠可见性回调）
    .onVisibleAreaChange([0.0], (isVisible: boolean, _ratio: number): void => {
      if (isVisible) {
        this.consumePendingPrompt()
      }
    })
  }
}
