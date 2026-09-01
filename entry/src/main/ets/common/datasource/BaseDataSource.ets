/** IDataSource 通用抽象基类 - 消除各业务数据源的重复模板代码，子类传入 keyPrefix 即可获得完整的 LazyForEach 支持 */

import { Logger } from '../utils/Logger'

/**
 * 可标识数据约束 —— 所有数据模型均含 id 字段
 * 用于 keyGenerator 优先使用业务 id 而非序号索引
 */
interface Identifiable {
  id: string
}

/**
 * IDataSource 通用抽象基类
 * 泛型约束 T extends Identifiable 确保数据模型拥有 id 字段
 */
export abstract class BaseDataSource<T extends Identifiable> implements IDataSource {
  /** 数据列表 —— 子类可通过 protected 直接访问 */
  protected dataList: T[] = []
  /** 数据变更监听器列表 */
  private listeners: DataChangeListener[] = []
  /** keyGenerator 前缀 —— 子类通过构造函数传入 */
  private keyPrefix: string = ''

  /**
   * @param keyPrefix - LazyForEach key 前缀，如 'home_todo' / 'goal_card'
   */
  constructor(keyPrefix: string) {
    this.keyPrefix = keyPrefix
  }

  // IDataSource 接口实现

  totalCount(): number {
    return this.dataList.length
  }

  getData(index: number): T {
    if (index < 0 || index >= this.dataList.length) {
      Logger.warn('BaseDataSource', 'getData out of bounds: index=' + index.toString() +
        ', size=' + this.dataList.length.toString())
      throw new Error('BaseDataSource.getData index out of bounds: ' + index.toString())
    }
    return this.dataList[index]
  }

  getItem(index: number): T | undefined {
    if (index < 0 || index >= this.dataList.length) {
      return undefined
    }
    return this.dataList[index]
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener)
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos: number = this.listeners.indexOf(listener)
    if (pos >= 0) {
      this.listeners.splice(pos, 1)
    }
  }

  // 数据操作方法

  /**
   * 全量替换数据并通知刷新
   */
  updateAll(newData: T[]): void {
    this.dataList = [...newData]
    this.notifyDataReload()
  }

  /**
   * 追加单条数据并通知
   */
  addData(item: T): void {
    this.dataList.push(item)
    this.notifyDataAdd(this.dataList.length - 1)
  }

  /**
   * 移除指定位置数据并通知
   */
  removeData(index: number): void {
    if (index >= 0 && index < this.dataList.length) {
      this.dataList.splice(index, 1)
      this.notifyDataDelete(index)
    }
  }

  // 通知方法（protected，供子类按需调用）

  /** 通知全量数据重载 */
  protected notifyDataReload(): void {
    for (let i: number = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataReloaded()
    }
  }

  /** 通知指定位置数据变更 */
  protected notifyDataChange(index: number): void {
    for (let i: number = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataChange(index)
    }
  }

  /** 通知指定位置数据新增 */
  protected notifyDataAdd(index: number): void {
    for (let i: number = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataAdd(index)
    }
  }

  /** 通知指定位置数据删除 */
  protected notifyDataDelete(index: number): void {
    for (let i: number = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataDelete(index)
    }
  }

  // keyGenerator —— 供 LazyForEach 使用

  /**
   * 生成 LazyForEach 唯一 key
   * 优先用业务 id 保证数据增删时 key 稳定，回退到 keyPrefix + index
   */
  keyGenerator(index: number): string {
    if (index >= 0 && index < this.dataList.length) {
      const item: T = this.dataList[index]
      if (item.id && item.id.length > 0) {
        return item.id
      }
    }
    return this.keyPrefix + '_' + index.toString()
  }
}
