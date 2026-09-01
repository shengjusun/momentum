/**
 * 应用事件总线
 * 解除 ViewModel 之间的循环依赖：跨 VM 通信改为 emit/on 模式，避免互相 import 单例
 * ArkTS 单线程 UI，所有回调在 emit 调用栈中同步执行
 */

import { Logger } from '../utils/Logger'

/**
 * 事件类型枚举
 */
export enum EventType {
  /** 请求触发云同步（payload: void） */
  SYNC_NEEDED = 'SYNC_NEEDED',
  /** 任务勾选状态变更（payload: TodoCompletedPayload） */
  TODO_COMPLETED = 'TODO_COMPLETED',
  /** 目标被删除（payload: { goalId: string }） */
  GOAL_REMOVED = 'GOAL_REMOVED',
  /** 任务被删除（payload: { taskId: string }） */
  TASK_REMOVED = 'TASK_REMOVED',
  /** 目标被重命名（payload: GoalRenamedPayload） */
  GOAL_RENAMED = 'GOAL_RENAMED',
  /** 任务信息被更新（payload: TaskInfoUpdatedPayload） */
  TASK_INFO_UPDATED = 'TASK_INFO_UPDATED',
  /** 任务完成状态被反向同步（payload: TaskCompletionSyncedPayload） */
  TASK_COMPLETION_SYNCED = 'TASK_COMPLETION_SYNCED',
  /** 请求所有 VM 清空内存数据（payload: void） */
  CLEAR_ALL_REQUESTED = 'CLEAR_ALL_REQUESTED',
  /** 请求所有 VM 刷盘（payload: void） */
  FLUSH_REQUESTED = 'FLUSH_REQUESTED'
}

/** TODO_COMPLETED 事件载荷 */
export interface TodoCompletedPayload {
  goalId: string
  taskId: string
  completed: boolean
}

/** GOAL_RENAMED 事件载荷 */
export interface GoalRenamedPayload {
  goalId: string
  newName: string
}

/** TASK_INFO_UPDATED 事件载荷 */
export interface TaskInfoUpdatedPayload {
  taskId: string
  newTitle: string
  newEstimatedTime: number
}

/** TASK_COMPLETION_SYNCED 事件载荷 */
export interface TaskCompletionSyncedPayload {
  taskId: string
  completed: boolean
}

/** GOAL_REMOVED 事件载荷 */
export interface GoalRemovedPayload {
  goalId: string
}

/** TASK_REMOVED 事件载荷 */
export interface TaskRemovedPayload {
  taskId: string
}

/** 工厂函数：构造 GoalRemovedPayload */
export function buildGoalRemovedPayload(goalId: string): GoalRemovedPayload {
  const payload: GoalRemovedPayload = { goalId: goalId }
  return payload
}

/** 工厂函数：构造 TaskRemovedPayload */
export function buildTaskRemovedPayload(taskId: string): TaskRemovedPayload {
  const payload: TaskRemovedPayload = { taskId: taskId }
  return payload
}

/**
 * 事件回调类型（payload 为 Object，接收方按需 as 具体类型）
 */
type EventCallback = (payload: Object) => void

/**
 * 事件监听器条目
 */
interface EventListenerEntry {
  id: number
  fn: EventCallback
}

/**
 * 工厂函数：构造 EventListenerEntry，满足 ArkTS 强类型约束
 */
function buildListenerEntry(id: number, fn: EventCallback): EventListenerEntry {
  const entry: EventListenerEntry = { id: id, fn: fn }
  return entry
}

/**
 * 空载荷单例（无 payload 事件使用，避免 null 和对象字面量）
 */
class EmptyPayload {
  private static instance: EmptyPayload | null = null

  static getInstance(): EmptyPayload {
    if (EmptyPayload.instance === null) {
      EmptyPayload.instance = new EmptyPayload()
    }
    return EmptyPayload.instance
  }
}

/**
 * 事件总线单例
 * emit 触发事件、on 订阅（返回 callbackId 用于 off 精确取消）、off 取消订阅
 */
class AppEventBus {
  private readonly tag: string = 'AppEventBus'
  private static instance: AppEventBus | null = null
  /** 事件类型 → 回调列表 */
  private listeners: Map<EventType, Array<EventListenerEntry>> = new Map()
  /** 回调 ID 自增（用于精确 off） */
  private nextCallbackId: number = 1

  private constructor() {}

  static getInstance(): AppEventBus {
    if (AppEventBus.instance === null) {
      AppEventBus.instance = new AppEventBus()
    }
    return AppEventBus.instance
  }

  /**
   * 订阅事件
   * @returns 回调 ID，用于 off 精确取消订阅
   */
  on(type: EventType, callback: EventCallback): number {
    if (!this.listeners.has(type)) {
      this.listeners.set(type, [])
    }
    const id: number = this.nextCallbackId++
    const arr = this.listeners.get(type)
    if (arr !== undefined) {
      arr.push(buildListenerEntry(id, callback))
    }
    return id
  }

  /**
   * 取消订阅
   */
  off(type: EventType, callbackId: number): void {
    const arr = this.listeners.get(type)
    if (arr === undefined) return
    const idx: number = arr.findIndex((item: EventListenerEntry): boolean => item.id === callbackId)
    if (idx >= 0) {
      arr.splice(idx, 1)
    }
  }

  /**
   * 触发事件（同步执行所有回调）
   * @param type 事件类型
   * @param payload 载荷，无载荷时传 null
   */
  emit(type: EventType, payload: Object | null): void {
    const arr = this.listeners.get(type)
    if (arr === undefined || arr.length === 0) return
    // 复制一份遍历，防止回调中 off 导致索引错乱
    const snapshot: Array<EventListenerEntry> = arr.slice()
    // 无载荷时使用空对象单例，避免 null 传给回调
    const safePayload: Object = payload === null ? EmptyPayload.getInstance() : payload
    for (let i: number = 0; i < snapshot.length; i++) {
      try {
        snapshot[i].fn(safePayload)
      } catch (e) {
        Logger.error(this.tag, 'emit ' + type + ' callback id=' + snapshot[i].id.toString() +
          ' failed: ' + (e as Error).message)
      }
    }
  }
}

/** 事件总线全局单例 */
export const eventBus: AppEventBus = AppEventBus.getInstance()
