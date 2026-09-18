/**
 * @file AI 提示词接力（跨 Tab 单向传递）
 * @description
 *   路线页空态要把用户"说出口的目标"带到 AI 页：点示例标签 → 切到 AI 并**预填**这句话；
 *   点伪输入框 → 切到 AI 并**聚焦**输入框。
 *
 *   ⚠️ 为什么不用 eventBus：HdsTabs 的 TabContent 是**首次切到时才构建**，
 *   RoutePage 先 emit 再切 Tab 时，AIPage 的订阅者还不存在 → 事件直接丢失。
 *   改成本「信箱」语义：RoutePage 投递，AIPage 在**首次构建**与**每次变为可见**
 *   两个时机主动取走（consume 后立即清空），完全不依赖订阅时序。
 *
 * @module common/utils
 */

/** 一条待处理的 AI 提示 */
export interface AIPendingPrompt {
  /** 待预填文本；为空串表示"只聚焦输入框、不预填" */
  text: string
}

class AIPromptBridge {
  /** 待取走的提示（未被取走时会被下一次投递覆盖） */
  private pending: AIPendingPrompt | null = null

  /**
   * 投递一条提示
   * @param text 待预填文本；空串表示只聚焦输入框
   */
  post(text: string): void {
    this.pending = { text: text }
  }

  /** 取走并清空（无待处理时返回 null） */
  consume(): AIPendingPrompt | null {
    const p: AIPendingPrompt | null = this.pending
    this.pending = null
    return p
  }
}

/** 全局单例 */
export const aiPromptBridge: AIPromptBridge = new AIPromptBridge()
