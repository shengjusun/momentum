/**
 * @file AiModels - AI 拆解状态 (模块化拆分 - AI 域)
 * @description
 *   AI 拆解（AIPage）相关状态模型：
 *   - AiBreakdownResult: AI 拆解结果（值对象，用于 ViewModel 维护状态）
 *
 * 4 级架构定位：
 *   - 用于 AIPage 的 L1 目标生成流程前置状态
 *   - 拆解得到的 tasks 列表（TaskNode[]）将进一步构造为 L2 AiGeneratedTask
 *
 * @module model
 * @date 2026-06-23
 */

import { TaskNode } from './TaskModels'
import { LoadState } from './BaseTypes'

/**
 * AI 拆解结果（值对象）
 * 用于 AIPage ViewModel 维护的状态
 */
export interface AiBreakdownResult {
  state: LoadState
  /** 用户输入的原始目标 */
  inputText: string
  /** 拆解得到的任务列表 */
  tasks: TaskNode[]
  /** 错误信息（state=ERROR 时有值） */
  errorMessage: string
}
