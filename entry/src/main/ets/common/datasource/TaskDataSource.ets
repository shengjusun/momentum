// 业务 DataSource 实现，配合 LazyForEach 实现按需渲染

import { BaseDataSource } from './BaseDataSource'
import { HomeTodoItem, GoalCardItem, AiGeneratedTask, MilestoneNode } from '../../model/Models'
import { ChatMessage } from '../../model/DeepSeekModels'

// 首页待办列表数据源
export class HomeTodoDataSource extends BaseDataSource<HomeTodoItem> {
  constructor() {
    super('home_todo')
  }
}

/**
 * 四象限待办数据源（艾森豪威尔法则）
 * 每个象限一个独立实例，通过 keyPrefix 区分以避免 LazyForEach key 冲突
 */
export class EisenhowerQuadrantDataSource extends BaseDataSource<HomeTodoItem> {
  // keyPrefix 建议传 'eisenhower_q1' ~ 'eisenhower_q4'
  constructor(keyPrefix: string) {
    super(keyPrefix)
  }
}

// 路线页目标卡片数据源
export class GoalCardDataSource extends BaseDataSource<GoalCardItem> {
  constructor() {
    super('goal_card')
  }
}

// AI 拆解结果数据源
export class AiTaskDataSource extends BaseDataSource<AiGeneratedTask> {
  constructor() {
    super('ai_task')
  }
}

// 里程碑数据源
export class MilestoneDataSource extends BaseDataSource<MilestoneNode> {
  constructor() {
    super('milestone')
  }
}

/**
 * AI 对话消息数据源
 * 仅内存态，不持久化，配合 LazyForEach 实现长列表按需渲染
 */
export class ChatMessageDataSource extends BaseDataSource<ChatMessage> {
  constructor() {
    super('chat_message')
  }
}
