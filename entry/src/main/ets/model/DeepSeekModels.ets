/**
 * @file DeepSeekModels - 网络请求 API 模型 (模块化拆分 - 网络域)
 * @description
 *   DeepSeek API 网络请求相关模型：
 *   - DeepSeekRequest: Chat Completions 请求体
 *   - DeepSeekResponseFormat: 响应格式
 *   - DeepSeekHeader: HTTP 请求头
 *   - DeepSeekMessage: 消息体
 *   - DeepSeekResponse: 响应体
 *   - DeepSeekChoice: 响应选择项
 *   - DeepSeekUsage: 用量统计
 *   - DeepSeekTaskJson: AI 返回的原始任务 JSON 结构
 *   - JsonFieldValue: JSON 字段值包装类型
 *
 * 设计原则：
 *   - 纯网络模型（值对象），不含任何业务逻辑
 *   - DeepSeekTaskJson 是 AI 返回的原始结构，需经 DeepSeekService 转换为 AiGeneratedTask
 *
 * @module model
 * @date 2026-06-23
 */

import { AiGeneratedTask } from './TaskModels'

/* ============================================================
 * 1. DeepSeek Chat Completions 请求
 * ============================================================ */

/**
 * DeepSeek Chat Completions 请求体（值对象）
 */
export interface DeepSeekRequest {
  model: string
  messages: DeepSeekMessage[]
  temperature?: number
  max_tokens?: number
}

/**
 * DeepSeek response_format（值对象，替代匿名字面量）
 */
export interface DeepSeekResponseFormat {
  type: 'json_object' | 'text'
}

/**
 * DeepSeek HTTP 请求头
 */
export interface DeepSeekHeader {
  'Content-Type': string
  'Authorization': string
}

/**
 * DeepSeek 消息体（值对象）
 * 多模态：content 支持纯文本字符串或 OpenAI 兼容的数组格式
 *   - 纯文本：content 为 string（保持向后兼容）
 *   - 多模态：content 为 Array<ContentPart>（文本片段 + 图片片段）
 */
export interface DeepSeekMessage {
  role: 'system' | 'user' | 'assistant'
  content: string | Array<ContentPart>
}

/**
 * 多模态内容片段（OpenAI 兼容格式）
 * Refactor: M1+多模态支持，v4-flash 原生识图，content 改为联合类型
 */

/** 文本片段 */
export interface TextContentPart {
  type: 'text'
  text: string
}

/** 图片片段（image_url.url 为 base64 data URL 或公网 URL） */
export interface ImageContentPart {
  type: 'image_url'
  image_url: ImageUrlData
}

/** 图片 URL 载荷 */
export interface ImageUrlData {
  url: string
}

/** 联合类型：文本片段 | 图片片段 */
export type ContentPart = TextContentPart | ImageContentPart

/**
 * 工厂函数：构造 TextContentPart（满足 arkts-no-untyped-obj-literals）
 */
export function buildTextContentPart(text: string): TextContentPart {
  const part: TextContentPart = { type: 'text', text: text }
  return part
}

/**
 * 工厂函数：构造 ImageContentPart（满足 arkts-no-untyped-obj-literals）
 */
export function buildImageContentPart(url: string): ImageContentPart {
  const urlData: ImageUrlData = { url: url }
  const part: ImageContentPart = { type: 'image_url', image_url: urlData }
  return part
}

/**
 * 类型守卫：content 是否为字符串
 */
export function isStringContent(content: string | Array<ContentPart>): boolean {
  return typeof content === 'string'
}

/**
 * 安全读取 content 为字符串：若为数组则拼接所有文本片段，图片片段替换为占位符
 * 用于日志、history 序列化等场景
 */
export function contentToString(content: string | Array<ContentPart>,
  imageLabelPrefix: string = '', imageLabelSuffix: string = ''): string {
  if (typeof content === 'string') {
    return content
  }
  let result: string = ''
  let imageCount: number = 0
  for (const part of content) {
    if (part.type === 'text') {
      result += part.text
    } else {
      imageCount += 1
    }
  }
  if (imageCount > 0) {
    result += imageLabelPrefix + imageCount.toString() + imageLabelSuffix
  }
  return result
}

/* ============================================================
 * 2. DeepSeek 响应
 * ============================================================ */

/**
 * DeepSeek Chat Completions 响应体（值对象）
 * Refactor: P2-8+DeepSeekModels usage可选类型
 */
export interface DeepSeekResponse {
  id: string
  choices: DeepSeekChoice[]
  usage?: DeepSeekUsage
}

/**
 * DeepSeek 响应中的选择项（值对象）
 */
export interface DeepSeekChoice {
  index: number
  message: DeepSeekMessage
  finish_reason: string
}

/**
 * DeepSeek 用量统计（值对象）
 */
export interface DeepSeekUsage {
  prompt_tokens: number
  completion_tokens: number
  total_tokens: number
}

/* ============================================================
 * 3. AI 返回的原始任务 JSON
 * ============================================================ */

/**
 * AI 返回的原始任务 JSON 结构（DeepSeek 实际返回）
 * 用于 DeepSeekService JSON 解析中显式映射，避免使用 object/unknown
 * 与 AiGeneratedTask 的区别：estimatedTime 是 number 或 string 都可以；steps 可空
 *
 * Step 1 重构：新增 deadline 字段（ISO8601 字符串或毫秒时间戳）
 * - 用于四象限联动：AI 必须推断并生成 deadline，经 parseDeadline 转为毫秒时间戳
 * - 兼容老格式：deadline 缺失或解析失败时回退为 0（不紧急）
 */
export interface DeepSeekTaskJson {
  taskName: string
  estimatedTime: number | string
  priority: string
  steps: Array<string>
  /** 截止时间，ISO8601 字符串或毫秒时间戳；缺失/无效时回退 0 */
  deadline?: string | number
}

/**
 * <plan> 标签内的完整 JSON 结构（Step 1 重构）
 * - goalName: AI 推断的目标名称（替代从 inputText 截取）
 * - tasks: 任务数组
 */
export interface DeepSeekPlanJson {
  goalName: string
  tasks: Array<DeepSeekTaskJson>
}

/**
 * AI 解析结果（Step 1 重构，generateTasks 的新返回类型）
 * - text: <plan> 标签前的说明文本（无标签时为整段文本，闲聊场景）
 * - goalName: 从 plan JSON 提取的目标名（无则空串）
 * - tasks: 解析出的任务数组（无则空，闲聊场景）
 *
 * 设计意图：实现"说明文本"与"结构化数据"分离，
 * 为 Step 2 对话流 UI 提供文本气泡 + 卡片双区域渲染能力。
 */
export interface AIParseResult {
  text: string
  goalName: string
  tasks: Array<AiGeneratedTask>
}

/**
 * extractPlanContent 的返回值（Step 1 重构）
 * - text: <plan> 标签前的说明文本（无标签时为整段文本）
 * - planJson: <plan> 标签内的 JSON 字符串（无标签时为 null）
 *
 * ArkTS 规范：禁止用匿名字面量 { text: string, planJson: string | null } 作为类型声明，
 * 必须显式声明 interface。
 */
export interface ExtractPlanResult {
  text: string
  planJson: string | null
}

/**
 * 对话流消息角色（Step 2 重构）
 * - user: 用户发送的消息
 * - assistant: AI 回复的消息（可携带拆解任务）
 */
export type ChatRole = 'user' | 'assistant'

/**
 * 对话流消息模型（Step 2 重构）
 *
 * 红线：仅存在于内存（AIPage.@Local chatMessages）
 *   - 绝不写入 routeVM.goals
 *   - 绝不进入 CloudSyncService.SyncDataBundle
 *   - 仅当用户点"确认使用此方案"时，通过 createGoalFromAi + routeVM.addGoal 正式入库
 *
 * V2 响应式修复：从 interface 改为 @ObservedV2 class + @Trace
 *   - 根因：interface 类型对象在 ForEach 同 key 复用时，@Param 无法监听属性变化
 *   - 改为 @ObservedV2 后，@Trace 属性变更可被 @Param 自动监听，无需重建组件
 *
 * @param id - 消息唯一 ID（msg_ + 时间戳）
 * @param role - 'user' | 'assistant'
 * @param text - 展示的文本内容（用户原文 / AI 说明文本）
 * @param tasks - AI 回复携带的拆解任务（user 为空数组）
 * @param goalName - AI 回复携带的目标名（user 为空串）
 * @param isStreaming - AI 回复等待态标志（控制 loading 动画与 UI 分支）
 * @param isConfirmed - 该计划是否已被加入路线（防重复入库）
 */
@ObservedV2
export class ChatMessage {
  id: string = ''
  @Trace role: ChatRole = 'user'
  @Trace text: string = ''
  @Trace tasks: Array<AiGeneratedTask> = []
  @Trace goalName: string = ''
  @Trace isStreaming: boolean = false
  @Trace isConfirmed: boolean = false
  /** 打字机逐字显示的完整目标文本（text 从空逐段追加至等于 fullText） */
  fullText: string = ''

  constructor(id: string, role: ChatRole, text: string, tasks: Array<AiGeneratedTask>,
              goalName: string, isStreaming: boolean, isConfirmed: boolean) {
    this.id = id
    this.role = role
    this.text = text
    this.tasks = tasks
    this.goalName = goalName
    this.isStreaming = isStreaming
    this.isConfirmed = isConfirmed
  }
}

/**
 * JSON 解析中的字段值包装（值对象）
 * 用于 safeExtractString / safeExtractNumber 等显式转换函数
 */
export type JsonFieldValue = string | number | Array<string> | null | undefined
