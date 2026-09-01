/**
 * @file DeepSeek AI 网络请求服务 (M2 云函数中转 - CloudFoundationKit)
 * @description
 *   - 通过 @kit.CloudFoundationKit.cloudFunction.call 调用 AGC 云函数 calldeepseek
 *   - 系统 SDK 自动处理 apigw-client + HDA-SYSTEM 鉴权，无需客户端持有密钥
 *   - 核心方法：async generateTasks(history, currentUserInput, profilePrompt, images): Promise<AIParseResult>
 *   - 强制 AI 返回 <plan> 标签包裹的 JSON
 *   - Markdown 代码块标记清洗、JSON.parse 显式断言
 *   - 取消机制：isCancelled 标志位（cloudFunction.call 无法真正中断，仅丢弃结果）
 *
 * 功能保底红线（已严格遵守）：
 *   1. Prompt 完整保留（DEEPSEEK_SYSTEM_PROMPT）
 *   2. Markdown 清洗完整（4 条正则）
 *   3. JSON 解析完整（field-by-field 显式映射）
 *   4. steps 字段完整保留
 *   5. estimatedTime 完整保留
 *   6. priority 完整保留
 *
 * 防呆规范：
 *   1. async 函数返回 Promise<T>，严禁赋值给 void
 *   2. JSON.parse 后必须显式类型断言
 *   3. 严禁使用 any / unknown / object 作为 JSON 解析的目标类型
 *
 * V1 封杀：严禁使用 @State / @Observed（旧）/ router
 *
 * @module common
 * @date 2026-06-19
 */

import { cloudFunction } from '@kit.CloudFoundationKit'
import { BusinessError } from '../utils/BusinessError'
import { common } from '@kit.AbilityKit'
import {
  AiGeneratedTask,
  TaskPriority,
  TaskStatus,
  DeepSeekResponse,
  DeepSeekMessage,
  DeepSeekTaskJson,
  DeepSeekPlanJson,
  AIParseResult,
  ExtractPlanResult,
  ContentPart,
  buildTextContentPart,
  buildImageContentPart,
  isStringContent,
  contentToString
} from '../../model/Models'
import { DEEPSEEK_SYSTEM_PROMPT } from '../../model/Models'
import { GOAL_REVIEW_SYSTEM_PROMPT, GLOBAL_REVIEW_SYSTEM_PROMPT, TODAY_PRIORITY_SYSTEM_PROMPT } from '../../model/AppConstants'
import { GoalCardItem } from '../../model/RouteModels'
import { Logger } from '../utils/Logger'

/**
 * 多模态图片引导（追加到 system prompt 末尾）
 * 当用户消息携带图片时，告诉 AI 要分析图片内容并按相同 <plan> JSON 格式输出
 */
const IMAGE_GUIDE_PROMPT: string =
  '\n\n---\n\n' +
  '## 图片输入说明\n\n' +
  '用户本次消息中包含图片。请仔细观察图片内容，结合文字（如有）理解用户意图，' +
  '按照与纯文本场景完全相同的 <plan> JSON 格式输出拆解方案。' +
  '若图片内容与目标拆解无直接关联，可适当结合图片信息给出建议，但仍必须输出 <plan> 标签。'

/**
 * AGC 云函数调用参数
 *
 * 来源：AGC 控制台 → 云函数 → calldeepseek → 触发器
 *   触发 URL: /functions/5azwyc0o/calldeepseek-$latest
 *   鉴权方式: apigw-client + HDA-SYSTEM（由 @kit.CloudFoundationKit 自动处理）
 */
const CLOUD_FUNCTION_NAME: string = 'calldeepseek'
const CLOUD_FUNCTION_VERSION: string = '$latest'

/**
 * 统一的错误提示文案（云函数调用失败 / DeepSeek 返回错误均使用此文案）
 */
const ERROR_MESSAGE_UNAVAILABLE: string = 'AI 服务暂时不可用，请稍后重试'


let __idCounter: number = 0

function generateTaskId(): string {
  __idCounter += 1
  return 'ai_task_' + Date.now().toString() + '_' + __idCounter.toString()
}

/**
 * DeepSeek 服务（懒汉式单例 - 双检锁）
 *
 * ArkTS 单线程环境下双检锁退化为带 null 检查的延迟初始化，
 * 保留双检锁结构以便未来多线程场景无缝升级。
 *
 * 优势（相对饿汉式）：
 *   - 首次 getInstance() 调用前不占用内存
 *   - 启动阶段无 DeepSeekService 实例化开销
 *   - 与其他 Service（CloudSyncService / HuaweiAuthService）单例风格统一
 */
export class DeepSeekService {
  /** 日志标签 */
  private readonly tag: string = 'DeepSeekService'
  /** 单例实例（懒加载，初始为 null） */
  private static instance: DeepSeekService | null = null
  /** 请求是否已被用户主动取消 */
  private isCancelled: boolean = false
  /** 应用上下文（用于 i18n 资源读取） */
  private context: common.UIAbilityContext | null = null

  /**
   * 获取单例实例（双检锁懒加载）
   *
   * 实现：
   *   - 第一次检查：已初始化则直接返回，避免每次进入同步块
   *   - 第二次检查：防止并发场景下重复构造（ArkTS 单线程，此处保留语义）
   */
  static getInstance(): DeepSeekService {
    if (DeepSeekService.instance === null) {
      // ArkTS 单线程无真正并发，此处保留双检锁结构以维持代码风格一致
      if (DeepSeekService.instance === null) {
        DeepSeekService.instance = new DeepSeekService()
      }
    }
    return DeepSeekService.instance
  }

  /**
   * 私有构造（单例模式）
   */
  private constructor() {
  }

  /**
   * 初始化上下文（用于 i18n 资源读取）
   * 在 EntryAbility.initializeAppServices 中调用
   */
  init(context: common.UIAbilityContext): void {
    this.context = context
    Logger.info(this.tag, 'init: context set')
  }

  /**
   * 获取本地化字符串
   * @param name - 资源名称（不含 app.string. 前缀）
   * @returns 本地化字符串，context 为空时返回空字符串
   */
  private getString(name: string): string {
    if (this.context === null) {
      Logger.warn(this.tag, 'getString: context is null, name=' + name)
      return ''
    }
    return this.context.resourceManager.getStringByNameSync(name)
  }

  /**
   * 取消当前进行中的云函数调用
   * cloudFunction.call() 返回 Promise，无法真正中断网络请求，
   * 仅通过 isCancelled 标志位在 await 返回后丢弃结果。
   */
  cancelRequest(): void {
    this.isCancelled = true
    Logger.info(this.tag, 'cancelRequest: marked as cancelled')
  }

  /**
   * 清洗 history 数组：剔除错误消息，确保 role 交替合法
   *
   * 防御策略：
   *   - 移除 assistant 角色中带错误关键词的消息（如"AI 生成失败"）
   *   - 移除空内容消息
   *   - 确保不会出现连续相同 role（取后者，覆盖前一条）
   *   - 历史消息中的图片必须剥离，用文字占位（如"[用户发送了2张图片]"），
   *     仅保留当前消息的真实 base64，避免请求体爆炸
   *
   * @param history - 原始多轮对话历史
   * @returns 清洗后的安全 history（content 全部规范化为 string）
   */
  private sanitizeHistory(history: Array<DeepSeekMessage>): Array<DeepSeekMessage> {
    const ERROR_KEYWORDS: string[] = ['失败', '错误', '重试', '稍后', '异常', 'HTTP 4', 'HTTP 5']
    const cleaned: Array<DeepSeekMessage> = []

    for (let i: number = 0; i < history.length; i++) {
      const msg: DeepSeekMessage = history[i]
      // 历史消息图片剥离：统一转 string，避免历史 base64 进入请求体
      // 坑1：多轮 history 中图片必须剥离，否则请求体会爆炸
      const contentStr: string = contentToString(msg.content)
      // 跳过空内容
      if (contentStr.length === 0) {
        Logger.info(this.tag, 'sanitizeHistory: skip empty content, role=' + msg.role)
        continue
      }
      // 跳过 assistant 错误消息
      if (msg.role === 'assistant') {
        let isError: boolean = false
        for (let k: number = 0; k < ERROR_KEYWORDS.length; k++) {
          if (contentStr.indexOf(ERROR_KEYWORDS[k]) >= 0) {
            isError = true
            break
          }
        }
        if (isError) {
          Logger.warn(this.tag, 'sanitizeHistory: skip error assistant msg: ' +
            contentStr.substring(0, 80))
          // 同时移除其前一条 user 消息（避免出现连续两个 user）
          if (cleaned.length > 0 && cleaned[cleaned.length - 1].role === 'user') {
            Logger.info(this.tag, 'sanitizeHistory: also removing preceding user msg')
            cleaned.pop()
          }
          continue
        }
      }
      // 重建消息：content 强制为 string（图片已剥离为占位文本）
      const safeMsg: DeepSeekMessage = {
        role: msg.role,
        content: contentStr
      }
      cleaned.push(safeMsg)
    }

    // 最终校验：消除连续相同 role（保留后一条）
    if (cleaned.length > 1) {
      const final: Array<DeepSeekMessage> = []
      final.push(cleaned[0])
      for (let i: number = 1; i < cleaned.length; i++) {
        if (cleaned[i].role === final[final.length - 1].role) {
          Logger.warn(this.tag, 'sanitizeHistory: consecutive same role (' + cleaned[i].role +
            '), merging by keeping later msg')
          final[final.length - 1] = cleaned[i]
        } else {
          final.push(cleaned[i])
        }
      }
      if (final.length < cleaned.length) {
        Logger.info(this.tag, 'sanitizeHistory: ' + cleaned.length.toString() +
          ' → ' + final.length.toString() + ' msgs after dedup')
      }
      return final
    }

    return cleaned
  }

  /**
   * 构造发送给云函数的 messages 数组
   *
   * 多模态支持（坑2/坑3）：
   *   - 当前用户消息携带图片时，content 改为 Array<ContentPart>（text + image_url 片段）
   *   - 历史消息中的图片已在 sanitizeHistory 中剥离为占位文本，绝不进入请求体
   *   - 当用户消息携带图片时，system prompt 末尾追加 IMAGE_GUIDE_PROMPT 引导 AI 输出 <plan>
   *
   * 注意：云函数 calldeepseek 仅接收 messages 数组，model / temperature / max_tokens 由云函数内部固定，
   *      客户端不再传 DeepSeekRequest 完整请求体。
   *
   * @param history - 多轮对话历史（不含 system，按时间顺序）
   * @param currentUserInput - 当前用户输入文本（纯文本，不含图片）
   * @param profilePrompt - 用户画像摘要（由 ProfileAnalyzerService 生成），空字符串时不注入
   * @param images - 当前用户消息携带的图片 base64 data URL 数组（空数组表示纯文本）
   * @returns messages 数组（system + history + 当前 user）
   */
  private buildMessages(history: Array<DeepSeekMessage>, currentUserInput: string,
    profilePrompt: string, images: Array<string>): Array<DeepSeekMessage> {
    // 0. 清洗 history：剔除错误消息、空内容，确保 role 交替合法
    //    注意：sanitizeHistory 内部已将历史消息的 content 全部规范化为 string（图片剥离）
    const safeHistory: Array<DeepSeekMessage> = this.sanitizeHistory(history)
    const hasImages: boolean = images.length > 0

    // 历史窗口裁剪：只保留最近 10 条（偶数，保持 user/assistant 成对）。
    // 画像已注入 system，更早的历史价值有限；窗口越小请求 token 越少、响应越快、费用越低
    const maxHistoryMessages: number = 10
    let windowedHistory: Array<DeepSeekMessage> = safeHistory
    if (safeHistory.length > maxHistoryMessages) {
      let cut: number = safeHistory.length - maxHistoryMessages
      if (cut % 2 !== 0) {
        cut += 1
      }
      windowedHistory = safeHistory.slice(cut)
      Logger.info(this.tag, 'buildMessages: history windowed ' +
        safeHistory.length.toString() + ' -> ' + windowedHistory.length.toString())
    }

    // 拼接 system prompt：基础 prompt + 用户画像 + 画像约束指令 + 图片引导
    let systemContent: string = DEEPSEEK_SYSTEM_PROMPT
    // 强制空值保护：profilePrompt 为 undefined/null 时转为空字符串
    const safeProfile: string = (profilePrompt !== null && profilePrompt !== undefined) ? profilePrompt : ''
    if (safeProfile.length > 0) {
      // 彻底清洗画像文本：防止任何特殊字符破坏 JSON 结构
      // - 双引号 → 单引号（避免 JSON.stringify 后产生畸形转义）
      // - 换行符 → 空格（避免 ArkTS JSON.stringify 大段换行符处理缺陷）
      const sanitizedProfile: string = safeProfile
        .replace(/"/g, '\'')
        .replace(/\r\n/g, ' ')
        .replace(/\n/g, ' ')
        .replace(/\r/g, ' ')
      systemContent += '\n\n---\n\n' +
        '## 用户画像信息（仅供你了解用户背景，用于提供个性化建议）\n\n' +
        sanitizedProfile +
        '\n\n' +
        '【重要规则】以上用户画像数据仅供参考，请勿在回复中直接复述画像中的数字。' +
        '你应当在回复开头用一句自然的话体现你了解用户的情况，然后直接给出拆解方案。'
    }
    // 坑2：用户消息携带图片时，system prompt 末尾追加图片引导
    if (hasImages) {
      systemContent += IMAGE_GUIDE_PROMPT
    }

    // ArkTS 严格模式：使用已定义的 interface 显式标注，禁用 as 强转
    const systemMsg: DeepSeekMessage = {
      role: 'system',
      content: systemContent
    }

    // 构造当前用户消息：
    //   - 纯文本：content 为 string（向后兼容，不影响现有逻辑）
    //   - 多模态：content 为 Array<ContentPart>（text 片段 + N 个 image_url 片段）
    //     注：文本为空时仅发图片片段（用户只发图不打字），避免空 text 片段干扰 API
    let userMsg: DeepSeekMessage
    if (hasImages) {
      const parts: Array<ContentPart> = []
      // 文本片段（仅有文字时才加入，避免空 text 片段）
      if (currentUserInput.length > 0) {
        parts.push(buildTextContentPart(currentUserInput))
      }
      // 图片片段（已为 base64 data URL 格式）
      for (let i: number = 0; i < images.length; i++) {
        parts.push(buildImageContentPart(images[i]))
      }
      userMsg = {
        role: 'user',
        content: parts
      }
    } else {
      userMsg = {
        role: 'user',
        content: currentUserInput
      }
    }

    // 拼接完整 messages：system + history + 当前 user
    const messages: DeepSeekMessage[] = [systemMsg]
    for (let i: number = 0; i < windowedHistory.length; i++) {
      messages.push(windowedHistory[i])
    }
    messages.push(userMsg)

    // 最终安全校验：确保 messages 中无连续相同 role（system→user 合法，user→user 违规）
    // 注意：sanitizeHistory 已将 history 的 content 规范化为 string，此处合并操作安全
    const validatedMessages: DeepSeekMessage[] = [messages[0]]
    for (let i: number = 1; i < messages.length; i++) {
      const prev: DeepSeekMessage = validatedMessages[validatedMessages.length - 1]
      if (messages[i].role === prev.role && messages[i].role !== 'system') {
        // 连续相同非 system role → 合并 content（保留后一条的语义）
        // 坑3：合并时必须做类型判断，避免 string + Array 拼接崩溃
        const prevText: string = isStringContent(prev.content) ?
          (prev.content as string) : contentToString(prev.content)
        const currText: string = isStringContent(messages[i].content) ?
          (messages[i].content as string) : contentToString(messages[i].content)
        Logger.warn(this.tag,
          'buildMessages: merging consecutive same role: ' + messages[i].role +
          ', prevContent=' + prevText.substring(0, 30) +
          ', currContent=' + currText.substring(0, 30))
        // 合并后统一降级为 string（图片在合并场景下必然是历史消息，已被剥离）
        prev.content = prevText + '\n' + currText
      } else {
        validatedMessages.push(messages[i])
      }
    }
    if (validatedMessages.length !== messages.length) {
      Logger.info(this.tag, 'buildMessages: validated messages count ' +
        messages.length.toString() + ' → ' + validatedMessages.length.toString())
    }
    return validatedMessages
  }

  /**
   * 清洗 Markdown 代码块标记
   * 使用正则去掉 ```json / ``` 包裹
   * @param raw - 原始 AI 返回字符串
   * @returns 清洗后的 JSON 字符串
   */
  private stripMarkdown(raw: string): string {
    let cleaned: string = raw.trim()
    // 去掉开头 ```json 或 ```，可选换行
    cleaned = cleaned.replace(/^```json\s*/i, '')
    cleaned = cleaned.replace(/^```\s*/i, '')
    // 去掉结尾 ```
    cleaned = cleaned.replace(/\s*```$/i, '')
    return cleaned.trim()
  }

  /**
   * 显式提取 number（处理 string/number/null/undefined）
   */
  private safeExtractNumber(value: string | number | Array<string> | null | undefined): number {
    if (typeof value === 'number') {
      return Math.max(0, Math.floor(value))
    }
    if (typeof value === 'string') {
      const parsed: number = parseInt(value, 10)
      return isNaN(parsed) ? 0 : Math.max(0, parsed)
    }
    return 0
  }

  /**
   * 显式提取 string
   */
  private safeExtractString(value: string | number | Array<string> | null | undefined,
    fallback: string): string {
    if (typeof value === 'string') {
      return value
    }
    if (typeof value === 'number') {
      return value.toString()
    }
    if (Array.isArray(value)) {
      return value.join(' / ')
    }
    return fallback
  }

  /**
   * 显式提取 string[]（用于 steps）
   * 保底功能：所有执行步骤完整保留，绝不丢失
   */
  private safeExtractStringArray(value: string | number | Array<string> | null | undefined): Array<string> {
    const result: Array<string> = []
    if (Array.isArray(value)) {
      for (let i: number = 0; i < value.length; i++) {
        // 终极修复：用 String() 而非 .toString()，避免 never 类型错误
        const item: string | number | Array<string> | null | undefined =
          value[i] as string | number | Array<string> | null | undefined
        const str: string = String(item)
        result.push(str)
      }
      return result
    }
    return result
  }

  /**
   * 归一化 priority 字段
   * @param raw - 原始字符串
   * @returns TaskPriority
   */
  private normalizePriority(raw: string): TaskPriority {
    const lower: string = raw.toLowerCase()
    if (lower === 'high' || lower === '高' || raw.indexOf('重要') >= 0) {
      return TaskPriority.HIGH
    }
    if (lower === 'low' || lower === '低') {
      return TaskPriority.LOW
    }
    return TaskPriority.MEDIUM
  }

  /**
   * 将单个 DeepSeekTaskJson 显式映射为 AiGeneratedTask
   * 保底功能：所有字段（taskName / estimatedTime / priority / steps / deadline）完整保留
   *
   * Step 1 重构：新增 deadline 字段映射
   * - AI 返回 ISO8601 字符串或毫秒时间戳，经 parseDeadline 统一转为毫秒
   * - 解析失败回退 0（不紧急，向后兼容老数据）
   *
   * @param json - 解析后的 JSON
   * @param index - 索引（用于生成 fallback taskName）
   * @returns AiGeneratedTask
   */
  private mapToTask(json: DeepSeekTaskJson, index: number): AiGeneratedTask {
    // 防呆：使用 safeExtractXxx 显式转换，避免 any/unknown/object
    const taskName: string = this.safeExtractString(json.taskName, this.getString('ai_default_task_prefix') + (index + 1).toString())
    const estimatedTime: number = this.safeExtractNumber(json.estimatedTime)
    const priority: TaskPriority = this.normalizePriority(this.safeExtractString(json.priority, 'medium'))
    const steps: Array<string> = this.safeExtractStringArray(json.steps)
    // Step 1 重构：解析 deadline，ISO8601 字符串或毫秒时间戳统一转为毫秒
    const deadline: number = this.parseDeadline(json.deadline)

    const completedSteps: Array<boolean> = steps.map((): boolean => false)
    const task: AiGeneratedTask = new AiGeneratedTask(
      generateTaskId(),
      taskName,
      estimatedTime,
      priority,
      steps,
      TaskStatus.PENDING,
      completedSteps,
      0,              // plannedTime，AI 不生成，默认 0
      0,              // actualCompletionTime，AI 不生成，默认 0
      deadline        // deadline，四象限联动关键字段
    )
    return task
  }

  /**
   * 解析 deadline 字段为毫秒时间戳（Step 1 重构）
   *
   * 支持格式：
   *   - ISO8601 字符串（如 "2026-08-15T18:00:00"）→ Date.parse
   *   - 毫秒时间戳（number）→ 直接返回（防御 NaN/负数）
   *   - 缺失/无效 → 回退 0（不紧急，向后兼容）
   *
   * @param raw - 原始 deadline 值（string | number | undefined）
   * @returns 毫秒时间戳，0 表示未设置
   */
  private parseDeadline(raw: string | number | undefined): number {
    if (raw === undefined || raw === null) return 0
    if (typeof raw === 'number') {
      if (isNaN(raw) || raw <= 0) return 0
      return Math.floor(raw)
    }
    if (typeof raw === 'string') {
      const trimmed: string = raw.trim()
      if (trimmed.length === 0) return 0
      // 优先尝试 ISO8601 解析
      const parsed: number = Date.parse(trimmed)
      if (!isNaN(parsed) && parsed > 0) return parsed
      // 兜底：纯数字字符串视为毫秒时间戳
      const asNum: number = parseInt(trimmed, 10)
      if (!isNaN(asNum) && asNum > 0) return asNum
    }
    return 0
  }

  /**
   * 从 AI 回复中提取说明文本和 JSON 字符串（兼容性增强版）
   *
   * 支持三种 AI 返回格式（防御 DeepSeek 不严格遵守 Prompt）：
   *   1. <plan>{json}</plan> 标签包裹（Prompt 期望的标准格式）
   *   2. ```json {json} ``` Markdown 代码块包裹（AI 常见违规格式）
   *   3. 纯 JSON 字符串（以 { 或 [ 开头，无任何包裹）
   *
   * 无以上任一特征时，视为纯闲聊文本，planJson 返回 null。
   *
   * @param content - AI 原始回复
   * @returns ExtractPlanResult（text 说明文本 + planJson JSON 字符串或 null）
   */
  private extractPlanContent(content: string): ExtractPlanResult {
    // 1. 优先匹配 <plan> 标签（标准协议格式）
    const planRegex: RegExp = /<plan>([\s\S]*?)<\/plan>/i
    const planMatch: RegExpExecArray | null = planRegex.exec(content)
    if (planMatch !== null && planMatch[1]) {
      const planJson: string = planMatch[1].trim()
      const text: string = content.substring(0, planMatch.index).trim()
      const planResult: ExtractPlanResult = {
        text: text,
        planJson: planJson
      }
      return planResult
    }

    // 2. 兜底匹配 ```json ... ``` 代码块（AI 违规使用 Markdown 包裹）
    const codeBlockRegex: RegExp = /```json\s*([\s\S]*?)\s*```/
    const codeBlockMatch: RegExpExecArray | null = codeBlockRegex.exec(content)
    if (codeBlockMatch !== null && codeBlockMatch[1]) {
      const planJson: string = codeBlockMatch[1].trim()
      const text: string = content.substring(0, codeBlockMatch.index).trim()
      const codeResult: ExtractPlanResult = {
        text: text,
        planJson: planJson
      }
      return codeResult
    }

    // 3. 兜底匹配纯 JSON（以 { 或 [ 开头，无任何包裹）
    const trimmedContent: string = content.trim()
    if (trimmedContent.startsWith('{') || trimmedContent.startsWith('[')) {
      // 尝试找到最后一个 } 或 ] 作为 JSON 结束位置
      const lastBrace: number = trimmedContent.lastIndexOf('}')
      const lastBracket: number = trimmedContent.lastIndexOf(']')
      const endIndex: number = Math.max(lastBrace, lastBracket)
      if (endIndex > 0) {
        const planJson: string = trimmedContent.substring(0, endIndex + 1)
        const pureJsonResult: ExtractPlanResult = {
          text: '',
          planJson: planJson
        }
        return pureJsonResult
      }
    }

    // 4. 都不匹配，视为纯闲聊文本
    const chatOnly: ExtractPlanResult = {
      text: content.trim(),
      planJson: null
    }
    return chatOnly
  }

  /**
   * 解析 AI 原始回复为 AIParseResult（Step 1 重构，对外主入口）
   *
   * 协议流程：
   *   1. extractPlanContent 提取 <plan> 标签，分离 text 与 planJson
   *   2. planJson 非空 → stripMarkdown 清洗 → JSON.parse 取 DeepSeekPlanJson
   *      - 提取 goalName（缺失时回退空串）
   *      - 提取 tasks 数组，复用 mapToTask 完成字段映射（含 deadline）
   *   3. planJson 为 null（闲聊场景）→ 返回 { text, goalName: '', tasks: [] }
   *   4. planJson 解析失败 → 尝试 repairTruncatedJson 兜底恢复任务名
   *
   * 微调场景判断（Step 2 重构）：
   *   - 当 history 非空（说明用户在已有任务基础上要求调整）但 planJson 为 null 时，
   *     视为 AI 失忆或未遵循协议，抛错让 UI 提示用户重试或换种说法
   *   - 首次拆解场景（history 为空）允许 planJson 为 null，视为闲聊或说明文本
   *
   * @param content - AI 原始回复（DeepSeekResponse.choices[0].message.content）
   * @param history - 多轮对话历史（用于判断是否为微调场景）
   * @returns AIParseResult（text + goalName + tasks 三段式）
   */
  private parseToResult(content: string, history: Array<DeepSeekMessage>): AIParseResult {
    const extracted: ExtractPlanResult = this.extractPlanContent(content)
    const text: string = extracted.text
    const planJson: string | null = extracted.planJson
    // 闲聊场景：无 <plan> 标签
    if (planJson === null || planJson.length === 0) {
      // 微调场景判断：history 非空说明用户在要求调整，但 AI 没返回 plan = 协议违例
      // 抛错让 UI 明确提示，避免 UI 静默落入"无任务可确认"状态
      if (history.length > 0) {
        throw new Error(this.getString('ai_error_continue'))
      }
      Logger.info(this.tag, 'parseToResult: no <plan> tag, treat as chat text')
      const chatResult: AIParseResult = {
        text: text,
        goalName: '',
        tasks: [] as Array<AiGeneratedTask>
      }
      return chatResult
    }

    // 清洗 Markdown 并解析为 DeepSeekPlanJson
    const cleaned: string = this.stripMarkdown(planJson)
    let goalName: string = ''
    let rawJsonTasks: Array<DeepSeekTaskJson> = []

    try {
      const parsed: object = JSON.parse(cleaned) as object
      const plan: Record<string, Object> = parsed as Record<string, Object>
      // 提取 goalName
      const goalNameRaw: Object | undefined = plan['goalName']
      if (typeof goalNameRaw === 'string') {
        goalName = goalNameRaw as string
      }
      // 提取 tasks 数组
      const tasksRaw: Object | undefined = plan['tasks']
      if (tasksRaw && Array.isArray(tasksRaw)) {
        rawJsonTasks = tasksRaw as Array<DeepSeekTaskJson>
      }

    } catch (e) {
      Logger.warn(this.tag, 'parseToResult: plan JSON parse failed, attempting repair: ' + (e as Error).message)
      rawJsonTasks = this.repairTruncatedJson(cleaned)
    }

    // 映射为 AiGeneratedTask[]
    const tasks: Array<AiGeneratedTask> = []
    for (let i: number = 0; i < rawJsonTasks.length; i++) {
      const task: AiGeneratedTask = this.mapToTask(rawJsonTasks[i], i)
      tasks.push(task)
    }

    // 有 <plan> 标签但解析后 tasks 为空 → 格式异常，抛错触发 UI 错误提示
    // （与闲聊场景区分：闲聊无 <plan> 标签，已在上方提前 return）
    if (tasks.length === 0) {
      throw new Error(this.getString('ai_error_unparseable'))
    }

    Logger.info(this.tag, 'parseToResult: textLen=' + text.length.toString() +
      ', goalName=' + goalName +
      ', tasks=' + tasks.length.toString())
    const finalResult: AIParseResult = {
      text: text,
      goalName: goalName,
      tasks: tasks
    }
    return finalResult
  }

  /**
   * 残缺 JSON 修复/补全机制
   * 当 max_tokens 不够导致 DeepSeek 返回截断 JSON 时，尝试恢复已完成的任务数据
   */
  private repairTruncatedJson(raw: string): Array<DeepSeekTaskJson> {
    const result: Array<DeepSeekTaskJson> = []

    let repairable: string = raw.trim()
    if (repairable.startsWith('{"tasks":')) {
      const tasksStart: number = repairable.indexOf('[')
      if (tasksStart >= 0) {
        repairable = repairable.substring(tasksStart)
      }
    }

    let lastBrace: number = repairable.lastIndexOf('}')
    while (lastBrace > 0) {
      const candidate: string = repairable.substring(0, lastBrace + 1) + ']'
      try {
        const parsed: object = JSON.parse(candidate) as object
        if (Array.isArray(parsed)) {
          const arr: Array<DeepSeekTaskJson> = parsed as Array<DeepSeekTaskJson>
          if (arr.length > 0) {
            Logger.info(this.tag, 'repairTruncatedJson: recovered ' +
              arr.length.toString() + ' tasks from truncated JSON')
            return arr
          }
        }
      } catch (_e) {
        // continue
      }
      lastBrace = repairable.lastIndexOf('}', lastBrace - 1)
    }

    const taskNameRegex: RegExp = /"taskName"\s*:\s*"([^"]+)"/g
    let match: RegExpExecArray | null = taskNameRegex.exec(repairable)
    while (match !== null) {
      result.push({
        taskName: match[1],
        estimatedTime: 30,
        priority: 'medium',
        steps: [this.getString('ai_default_step')]
      })
      match = taskNameRegex.exec(repairable)
    }

    if (result.length > 0) {
      Logger.info(this.tag, 'repairTruncatedJson: regex recovered ' +
        result.length.toString() + ' task names')
    }

    return result
  }



  /**
   * 核心方法：通过 @kit.CloudFoundationKit 调用 AGC 云函数 calldeepseek
   *
   * 架构（M2 云函数中转）：
   *   - 使用 cloudFunction.call() 系统 API，自动处理 apigw-client + HDA-SYSTEM 鉴权
   *   - API Key 安全存放于云函数环境变量，客户端不持有任何密钥
   *   - 云函数返回值即 DeepSeek 原始响应 JSON，<plan> 标签解析逻辑保持不变
   *
   * 多模态支持：
   *   - images 参数非空时，构造 OpenAI 兼容的多模态 content 数组
   *   - 历史消息中的图片已在 sanitizeHistory 中剥离，绝不进入请求体
   *   - 当 images 非空时，system prompt 末尾追加图片引导
   *
   * 取消机制：
   *   - cloudFunction.call() 返回 Promise，无法真正中断网络请求
   *   - 仅通过 isCancelled 标志位在 await 返回后丢弃结果
   *
   * @param history - 多轮对话历史（不含 system，按时间顺序，role: 'user'|'assistant'）
   * @param currentUserInput - 当前用户输入文本（纯文本，不含图片）
   * @param profilePrompt - 用户画像摘要（由 ProfileAnalyzerService 生成），默认为空，向后兼容
   * @param images - 当前用户消息携带的图片 base64 data URL 数组，默认为空数组（纯文本场景）
   * @returns AIParseResult 三段式结果（text + goalName + tasks）
   */
  // Step 1 重构：返回类型 AiGeneratedTask[] → AIParseResult，分离说明文本与结构化数据
  // Step 2 重构：新增 history 参数支持多轮对话微调
  // Step 3 重构：新增 profilePrompt 参数支持用户画像注入（向后兼容，不传仍正常工作）
  // M1 重构：新增 images 参数支持多模态图片输入（向后兼容，不传仍按纯文本处理）
  // M2 重构：移除 apiKey 参数，改用 AGC 云函数中转调用 DeepSeek
  async generateTasks(history: Array<DeepSeekMessage>, currentUserInput: string,
    profilePrompt: string = '', images: Array<string> = []): Promise<AIParseResult> {
    // 1. 入参校验
    const hasImages: boolean = images.length > 0
    if (!hasImages && (!currentUserInput || currentUserInput.trim().length === 0)) {
      throw new Error(this.getString('ai_error_empty_desc'))
    }
    const safeInput: string = (currentUserInput !== null && currentUserInput !== undefined) ?
      currentUserInput : ''

    // 2. 重置取消标记
    this.isCancelled = false

    // 3. 构造 messages 数组
    const messages: Array<DeepSeekMessage> = this.buildMessages(history, safeInput, profilePrompt, images)

    Logger.info(this.tag, 'generateTasks start, input length=' + safeInput.length.toString() +
      ', history=' + history.length.toString() +
      ', hasProfile=' + (profilePrompt.length > 0).toString() +
      ', imageCount=' + images.length.toString() +
      ', messages count=' + messages.length.toString())

    // 4. 通过 cloudFunction.call() 调用云函数（自动处理 HDA-SYSTEM 鉴权）
    //    云函数内部持有 DeepSeek API Key，客户端不传 Key
    try {
      const firstMsgRole: string = messages.length > 0 ? messages[0].role : 'none'
      const firstMsgType: string = (messages.length > 0 && isStringContent(messages[0].content))
        ? 'string' : 'array'
      Logger.info(this.tag, '[DIAG] cloudFunction.call: name=' + CLOUD_FUNCTION_NAME +
        ', version=' + CLOUD_FUNCTION_VERSION +
        ', messagesCount=' + messages.length.toString() +
        ', firstRole=' + firstMsgRole + ', firstContentType=' + firstMsgType)

      // cloudFunction.call() 参数类型
      const callData: Record<string, Object> = {
        'messages': messages
      }
      const fnResult: cloudFunction.FunctionResult = await cloudFunction.call({
        name: CLOUD_FUNCTION_NAME,
        version: CLOUD_FUNCTION_VERSION,
        data: callData
      })

      // 5. 取消检查
      if (this.isCancelled) {
        Logger.info(this.tag, 'generateTasks cancelled by user, discard result')
        const cancelledResult: AIParseResult = {
          text: '',
          goalName: '',
          tasks: [] as Array<AiGeneratedTask>
        }
        return cancelledResult
      }

      // 6. 解析云函数返回值（即 DeepSeek 原始响应 JSON）
      //    FunctionResult.result 可能是 string（JSON）或 object
      let responseStr: string
      if (typeof fnResult.result === 'string') {
        responseStr = fnResult.result as string
      } else {
        responseStr = JSON.stringify(fnResult.result)
      }
      Logger.info(this.tag, '[DIAG] cloudFunction response: bodyLen=' +
        responseStr.length.toString() + ', body=' + responseStr.substring(0, 500))

      const deepSeekResp: DeepSeekResponse = JSON.parse(responseStr) as DeepSeekResponse

      if (!deepSeekResp.choices || deepSeekResp.choices.length === 0) {
        Logger.error(this.tag, '[DIAG] no choices in response. keys: ' +
          Object.keys(deepSeekResp as object).join(','))
        throw new Error(ERROR_MESSAGE_UNAVAILABLE)
      }

      const choice = deepSeekResp.choices[0]
      if (choice.finish_reason === 'length') {
        Logger.warn(this.tag, 'AI response truncated by max_tokens, attempting repair')
      }
      const rawContent: string | Array<ContentPart> = choice.message.content
      const content: string = isStringContent(rawContent) ?
        (rawContent as string) : contentToString(rawContent)
      Logger.info(this.tag, 'AI content length=' + content.length.toString())

      // 7. 解析 <plan> 标签
      const result: AIParseResult = this.parseToResult(content, history)
      Logger.info(this.tag, 'parseToResult success, textLen=' + result.text.length.toString() +
        ', goalName=' + result.goalName +
        ', tasks=' + result.tasks.length.toString())
      return result
    } catch (err) {
      if (this.isCancelled) {
        Logger.info(this.tag, 'generateTasks cancelled by user (in catch), return empty result')
        const cancelledResult: AIParseResult = {
          text: '',
          goalName: '',
          tasks: [] as Array<AiGeneratedTask>
        }
        return cancelledResult
      }
      // 诊断日志
      const error: BusinessError = err as BusinessError
      const errMsg: string = error.message || ''
      const errCode: number = error.code || 0
      Logger.error(this.tag, '[DIAG] cloudFunction.call FAILED: code=' + errCode.toString() +
        ', message=' + errMsg + ', typeof=' + typeof err)
      try {
        Logger.error(this.tag, '[DIAG] full error JSON: ' + JSON.stringify(err))
      } catch (_strErr) {
        Logger.error(this.tag, '[DIAG] error not JSON-serializable')
      }
      // 业务错误保留原始 message
      if (errMsg.indexOf('未能继续拆解') >= 0 || errMsg.indexOf('换种说法') >= 0 ||
        errMsg.indexOf('无法解析') >= 0 || errMsg.indexOf(this.getString('ai_error_continue')) >= 0 ||
        errMsg.indexOf(this.getString('ai_error_unparseable')) >= 0 ||
        errMsg.indexOf(this.getString('ai_error_empty_desc')) >= 0) {
        throw new Error(errMsg)
      }
      throw new Error(ERROR_MESSAGE_UNAVAILABLE)
    }
  }

  /**
   * 通用纯文本 AI 调用（复盘/建议类场景：无 <plan> 结构，直接返回文本）
   * 复用 generateTasks 的云函数调用通道与 isCancelled 取消机制
   * @param systemPrompt - 场景系统提示词（复盘/排序建议）
   * @param userContent - 用户数据摘要文本
   * @returns AI 报告文本；被取消时返回空串；网络/服务异常时抛出统一错误
   */
  private async generatePlainText(systemPrompt: string, userContent: string): Promise<string> {
    if (!userContent || userContent.trim().length === 0) {
      return ''
    }
    this.isCancelled = false
    const messages: Array<DeepSeekMessage> = [
      { role: 'system', content: systemPrompt },
      { role: 'user', content: userContent }
    ]
    try {
      const callData: Record<string, Object> = { 'messages': messages }
      const fnResult: cloudFunction.FunctionResult = await cloudFunction.call({
        name: CLOUD_FUNCTION_NAME,
        version: CLOUD_FUNCTION_VERSION,
        data: callData
      })
      if (this.isCancelled) {
        Logger.info(this.tag, 'generatePlainText cancelled by user, discard result')
        return ''
      }
      let responseStr: string
      if (typeof fnResult.result === 'string') {
        responseStr = fnResult.result as string
      } else {
        responseStr = JSON.stringify(fnResult.result)
      }
      const deepSeekResp: DeepSeekResponse = JSON.parse(responseStr) as DeepSeekResponse
      if (!deepSeekResp.choices || deepSeekResp.choices.length === 0) {
        throw new Error(ERROR_MESSAGE_UNAVAILABLE)
      }
      const rawContent: string | Array<ContentPart> = deepSeekResp.choices[0].message.content
      const content: string = isStringContent(rawContent) ?
        (rawContent as string) : contentToString(rawContent)
      Logger.info(this.tag, 'generatePlainText success, contentLen=' + content.length.toString())
      return content.trim()
    } catch (err) {
      if (this.isCancelled) {
        return ''
      }
      const error: BusinessError = err as BusinessError
      Logger.error(this.tag, 'generatePlainText FAILED: code=' + (error.code || 0).toString() +
        ', msg=' + (error.message || ''))
      throw new Error(ERROR_MESSAGE_UNAVAILABLE)
    }
  }

  /**
   * 目标完结复盘：传入 L1 目标（含任务与步骤），返回复盘报告文本
   * 调用方：GoalDetailPage.handleGoalReview
   */
  async generateGoalReview(goal: GoalCardItem): Promise<string> {
    const userData: string = '目标名称：' + goal.name +
      '\n总进度：' + goal.progress.toString() + '%' +
      '\n任务总数：' + goal.tasks.length.toString() +
      '\n任务明细（名称/优先级/状态/步骤完成情况）：' + JSON.stringify(goal.tasks)
    return await this.generatePlainText(GOAL_REVIEW_SYSTEM_PROMPT, userData)
  }

  /**
   * 全局学习复盘：传入统计数据摘要文本，返回复盘报告文本
   * 调用方：StatsPage
   */
  async generateGlobalReview(summary: string): Promise<string> {
    return await this.generatePlainText(GLOBAL_REVIEW_SYSTEM_PROMPT, summary)
  }

  /**
   * 今日排序建议：传入今日待办摘要文本，返回建议文本
   * 调用方：HomePage.handleTodaySuggestion
   */
  async generateTodaySuggestion(todoData: string): Promise<string> {
    return await this.generatePlainText(TODAY_PRIORITY_SYSTEM_PROMPT, todoData)
  }
}
