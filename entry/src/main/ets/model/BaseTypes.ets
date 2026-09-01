/** 全局共享的基础类型与枚举（最底层，不依赖任何业务模块，避免循环依赖） */

// 通用基础类型

// 唯一标识符类型
export type Id = string

// 时间戳（毫秒）
export type Timestamp = number

// 任务状态枚举（ArkTS 严格模式不支持 const enum）
export enum TaskStatus {
  PENDING = 'pending',
  IN_PROGRESS = 'in_progress',
  COMPLETED = 'completed'
}

// 优先级枚举（ArkTS 严格模式不支持 const enum）
export enum TaskPriority {
  HIGH = 'high',
  MEDIUM = 'medium',
  LOW = 'low'
}

// 优先级数值（高=3, 中=2, 低=1），用于排序
export function getPriorityValue(priority: TaskPriority): number {
  if (priority === TaskPriority.HIGH) return 3
  if (priority === TaskPriority.MEDIUM) return 2
  return 1
}

// 从序列化值解析枚举，ArkTS enum 不支持内部方法故用顶层函数；JSON 反序列化后 enum 变字符串需兼容
export function parseTaskPriority(raw: number | string | null | undefined): TaskPriority {
  if (typeof raw === 'string') {
    const lower: string = raw.toLowerCase()
    if (lower === 'high') {
      return TaskPriority.HIGH
    }
    if (lower === 'low') {
      return TaskPriority.LOW
    }
    return TaskPriority.MEDIUM
  }
  if (typeof raw === 'number') {
    if (raw === 0) {
      return TaskPriority.HIGH
    }
    if (raw === 1) {
      return TaskPriority.MEDIUM
    }
    if (raw === 2) {
      return TaskPriority.LOW
    }
  }
  return TaskPriority.MEDIUM
}

// 统一加载状态枚举（IDLE 空闲 / LOADING 加载中 / SUCCESS 成功 / ERROR 失败 / EMPTY 空数据）
export enum LoadState {
  IDLE = 'idle',
  LOADING = 'loading',
  SUCCESS = 'success',
  ERROR = 'error',
  EMPTY = 'empty'
}

// Tab 配置项
export class TabConfig {
  index: number = 0
  title: Resource = $r('app.string.tab_home')
  icon: Resource = $r('app.media.tab_home')
  iconSelected: Resource = $r('app.media.tab_home_active')
}
