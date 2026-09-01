/**
 * 统一存储管理器 - 封装 ArkData preferences，提供类型安全的 JSON 序列化/反序列化
 * 关键设计：LRU 缓存 Preferences 实例、写锁串行化避免并发冲突、数据损坏时静默回退 fallback
 */

import { preferences } from '@kit.ArkData'
import { common } from '@kit.AbilityKit'
import { BusinessError } from './BusinessError'
import { Logger } from './Logger'
import { TaskPriority } from '../../model/Models'
import { parseTaskPriority } from '../../model/BaseTypes'
import { AiGeneratedTask, AiGeneratedTaskJSON } from '../../model/Models'
import { CommonConstants } from '../constants/CommonConstants'

// 顶层类型声明

/**
 * 存储操作结果（统一返回类型，避免 throw）
 */
export interface StorageResult {
  success: boolean
  errorMsg: string
}

/**
 * 缓存条目
 */
interface CacheEntry {
  prefs: preferences.Preferences
  lastAccessTime: number
}

interface StringWrapper {
  v: string
}

interface BooleanWrapper {
  v: boolean
}

// 常量定义

const TAG: string = 'StorageManager'
const STORE_NAME: string = 'app_data_store'
/** 分域 store：大 JSON 与高频写入的数据拆分到独立 preferences 文件，
 *  避免任何一次小写入都触发整包大值重写（历史上所有键共用单一 store 文件） */
const STORE_NAME_GOALS: string = 'goals_store'
const STORE_NAME_TODOS: string = 'todos_store'
const STORE_NAME_NOTIFY: string = 'notify_store'
const STORE_NAME_POMO: string = 'pomo_store'

/**
 * 按存储键前缀路由到目标 store（StorageManager 内部使用，调用方无感）
 * - 目标/通知/番茄钟：写入频繁，与目标大 JSON 物理隔离
 * - 目标列表：全项目最大 JSON，单独成库
 */
function resolveStoreName(key: string): string {
  if (key.indexOf('storage_route_goals') === 0) {
    return STORE_NAME_GOALS
  }
  if (key.indexOf('storage_home_todos') === 0) {
    return STORE_NAME_TODOS
  }
  if (key.indexOf('storage_app_notifications') === 0) {
    return STORE_NAME_NOTIFY
  }
  if (key.indexOf('storage_pomodoro') === 0 || key.indexOf('storage_pomo_') === 0) {
    return STORE_NAME_POMO
  }
  return STORE_NAME
}
/** 缓存过期时间（毫秒） */
const CACHE_TTL_MS: number = 30000
/** 缓存最大条目数 */
const MAX_CACHE_SIZE: number = 16

// StorageManager 主体

/**
 * 统一存储管理器（静态工具类）
 */
export class StorageManager {
  /**
   * Preferences 实例缓存（key = context 标识）
   * 用 Map 维护，按 context 哈希 + 最后访问时间排序
   */
  private static cache: Map<string, CacheEntry> = new Map()
  /**
   * 写锁队列：保证同一 key 的写操作串行化
   * key = 存储键名
   */
  private static writeLocks: Map<string, Promise<void>> = new Map()

  /** 私有构造：禁止实例化 */
  private constructor() {}

  /**
   * 获取（或复用）Preferences 实例
   * @param context - 应用上下文（getContext(this) 获取）
   * @returns Promise<preferences.Preferences>
   */
  private static async getPreferences(context: Context,
    storeName: string = STORE_NAME): Promise<preferences.Preferences> {
    const cacheKey: string = StorageManager.buildCacheKey(context) + '|' + storeName
    const now: number = Date.now()
    // 1. 检查缓存（命中且未过期）
    const cached: CacheEntry | undefined = StorageManager.cache.get(cacheKey)
    if (cached !== undefined && (now - cached.lastAccessTime) < CACHE_TTL_MS) {
      // 更新访问时间
      const refreshed: CacheEntry = {
        prefs: cached.prefs,
        lastAccessTime: now
      }
      StorageManager.cache.set(cacheKey, refreshed)
      return cached.prefs
    }
    // 2. 缓存未命中或已过期，重新获取
    try {
      const prefs: preferences.Preferences =
        await preferences.getPreferences(context, storeName)
      // 3. 写入缓存
      StorageManager.cache.set(cacheKey, {
        prefs: prefs,
        lastAccessTime: now
      })
      // 4. 缓存超过上限，清理最旧条目
      if (StorageManager.cache.size > MAX_CACHE_SIZE) {
        StorageManager.evictOldest()
      }
      Logger.info(TAG, 'getPreferences success, cacheKey=' + cacheKey)
      return prefs
    } catch (e) {
      const err: BusinessError = e as BusinessError
      Logger.error(TAG, 'getPreferences failed, code=' + err.code.toString() +
        ', msg=' + err.message)
      throw new Error('StorageManager.getPreferences failed: ' + err.message)
    }
  }

  /**
   * 构建缓存键（避免长生命周期 context 引用）
   * 优先使用 context 中可序列化的标识
   */
  private static buildCacheKey(context: Context): string {
    // UIAbilityContext 有 cacheDir 等稳定标识
    if (context !== null && context !== undefined) {
      const ctx: Context = context
      return typeof ctx.cacheDir === 'string' ?
        ctx.cacheDir : 'ctx_' + StorageManager.hashCode(JSON.stringify({
          stage: (ctx as common.UIAbilityContext).stageMode,
          process: (ctx as common.UIAbilityContext).processName
        })).toString()
    }
    return 'ctx_null'
  }

  /**
   * 字符串哈希（简单实现，避免引用完整 hash 库）
   */
  private static hashCode(str: string): number {
    let hash: number = 0
    for (let i: number = 0; i < str.length; i++) {
      hash = ((hash << 5) - hash) + str.charCodeAt(i)
      hash = hash & hash // 转为 32 位整数
    }
    return Math.abs(hash)
  }

  /**
   * 清理最旧的缓存条目
   */
  private static evictOldest(): void {
    let oldestKey: string = ''
    let oldestTime: number = Number.MAX_SAFE_INTEGER
    StorageManager.cache.forEach((entry: CacheEntry, key: string): void => {
      if (entry.lastAccessTime < oldestTime) {
        oldestTime = entry.lastAccessTime
        oldestKey = key
      }
    })
    if (oldestKey.length > 0) {
      StorageManager.cache.delete(oldestKey)
    }
  }

  /**
   * 核心方法：保存数据到 Preferences
   *
   * @param context - 应用上下文（getContext(this)）
   * @param key - 存储键名
   * @param value - 要存储的对象（必须可 JSON 序列化）
   * @returns Promise<void> 存储完成的 Promise
   *
   * @example
   * ```typescript
   * await StorageManager.saveData(
   *   getContext(this),
   *   CommonConstants.STORAGE_KEY_HOME_TODOS,
   *   this.taskList
   * )
   * ```
   */
  static async saveData(context: Context, key: string, value: object): Promise<void> {
    if (context === null || context === undefined) {
      Logger.error(TAG, 'saveData: context is null')
      return
    }
    if (typeof key !== 'string' || key.length === 0) {
      Logger.error(TAG, 'saveData: key is empty')
      return
    }
    if (value === null || value === undefined) {
      Logger.error(TAG, 'saveData: value is null, key=' + key)
      return
    }
    // 写锁串行化：同一 key 的写操作排队执行，锁的获取与注册在同一微任务内完成避免 TOCTOU 竞态
    const existingLock: Promise<void> | undefined = StorageManager.writeLocks.get(key)
    const writePromise: Promise<void> = (async (): Promise<void> => {
      // 先等待之前的写操作完成（在 writePromise 内部 await，不阻塞锁注册）
      if (existingLock !== undefined) {
        await existingLock
      }
      try {
        const prefs: preferences.Preferences =
          await StorageManager.getPreferences(context, resolveStoreName(key))
        const jsonStr: string = JSON.stringify(value)
        await prefs.put(key, jsonStr)
        await prefs.flush()
        Logger.info(TAG, 'saveData success, key=' + key +
          ', size=' + jsonStr.length.toString())
      } catch (e) {
        const err: BusinessError = e as BusinessError
        Logger.error(TAG, 'saveData failed, key=' + key +
          ', code=' + err.code.toString() + ', msg=' + err.message)
      }
    })()
    // 立即注册锁（在任何 await 之前，确保并发调用能看到新锁）
    StorageManager.writeLocks.set(key, writePromise)
    try {
      await writePromise
    } finally {
      // 释放写锁
      if (StorageManager.writeLocks.get(key) === writePromise) {
        StorageManager.writeLocks.delete(key)
      }
    }
  }

  /**
   * 核心方法：从 Preferences 加载数据
   *
   * @typeParam T - 期望返回的数据类型
   * @param context - 应用上下文
   * @param key - 存储键名
   * @param fallback - 默认值（加载失败或数据不存在时返回）
   * @returns Promise<T> 包含加载数据的 Promise
   *
   * @example
   * ```typescript
   * const todos: Array<HomeTodoItem> = await StorageManager.loadData<Array<HomeTodoItem>>(
   *   getContext(this),
   *   CommonConstants.STORAGE_KEY_HOME_TODOS,
   *   []
   * )
   * ```
   */
  static async loadData<T>(context: Context, key: string, fallback: T): Promise<T> {
    if (context === null || context === undefined) {
      Logger.error(TAG, 'loadData: context is null')
      return fallback
    }
    if (typeof key !== 'string' || key.length === 0) {
      Logger.error(TAG, 'loadData: key is empty')
      return fallback
    }
    try {
      const prefs: preferences.Preferences =
        await StorageManager.getPreferences(context, resolveStoreName(key))
      const hasKey: boolean = await prefs.has(key)
      if (!hasKey) {
        Logger.info(TAG, 'loadData: key not found, key=' + key + ', use fallback')
        return fallback
      }
      const jsonStr: string = await prefs.get(key, '') as string
      if (typeof jsonStr !== 'string' || jsonStr.length === 0) {
        Logger.warn(TAG, 'loadData: empty value, key=' + key)
        return fallback
      }
      // JSON.parse 单独 try-catch：数据损坏时返回 fallback，不抛异常保证 UI 不崩
      try {
        const parsed: T = JSON.parse(jsonStr) as T
        Logger.info(TAG, 'loadData success, key=' + key)
        return parsed
      } catch (parseError) {
        Logger.error(TAG, 'loadData: JSON.parse failed (data corruption), key=' + key +
          ', rawLen=' + jsonStr.length.toString() +
          ', msg=' + (parseError as Error).message +
          ' (已返回 fallback 默认值)')
        return fallback
      }
    } catch (e) {
      const err: BusinessError = e as BusinessError
      Logger.error(TAG, 'loadData failed, key=' + key +
        ', code=' + err.code.toString() + ', msg=' + err.message)
      return fallback
    }
  }

  /**
   * 同步读取指定键的数据（卡片场景专用）
   * @param context - 应用上下文
   * @param key - 存储键名
   * @param fallback - 默认值（加载失败或数据不存在时返回）
   * @returns T 包含加载数据的对象
   *
   * 说明：卡片 FormExtensionAbility 的 onAddForm 是同步回调，无法使用 async/await，
   * 因此提供同步版本。底层使用 preferences.getPreferencesSync + getSync。
   */
  static loadDataSync<T>(context: Context, key: string, fallback: T): T {
    if (context === null || context === undefined) {
      Logger.error(TAG, 'loadDataSync: context is null')
      return fallback
    }
    if (typeof key !== 'string' || key.length === 0) {
      Logger.error(TAG, 'loadDataSync: key is empty')
      return fallback
    }
    try {
      // API 23 同步获取 Preferences 实例：options 是对象 { name: string }
      // 桌面卡片读取的 todos 键在分域后位于 todos_store，必须同步路由
      const options: preferences.Options = { name: resolveStoreName(key) }
      const prefs: preferences.Preferences = preferences.getPreferencesSync(context, options)
      const hasKey: boolean = prefs.hasSync(key)
      if (!hasKey) {
        Logger.info(TAG, 'loadDataSync: key not found, key=' + key + ', use fallback')
        return fallback
      }
      const jsonStr: string = prefs.getSync(key, '') as string
      if (typeof jsonStr !== 'string' || jsonStr.length === 0) {
        Logger.warn(TAG, 'loadDataSync: empty value, key=' + key)
        return fallback
      }
      try {
        const parsed: T = JSON.parse(jsonStr) as T
        Logger.info(TAG, 'loadDataSync success, key=' + key)
        return parsed
      } catch (parseError) {
        Logger.error(TAG, 'loadDataSync: JSON.parse failed (data corruption), key=' + key +
          ', msg=' + (parseError as Error).message)
        return fallback
      }
    } catch (e) {
      const err: BusinessError = e as BusinessError
      Logger.error(TAG, 'loadDataSync failed, key=' + key +
        ', code=' + err.code.toString() + ', msg=' + err.message)
      return fallback
    }
  }

  /**
   * 删除指定键
   * @param context - 应用上下文
   * @param key - 存储键名
   * @returns Promise<StorageResult> 操作结果
   */
  static async removeData(context: Context, key: string): Promise<StorageResult> {
    const result: StorageResult = { success: false, errorMsg: '' }
    if (context === null || context === undefined) {
      result.errorMsg = 'context is null'
      Logger.error(TAG, 'removeData: ' + result.errorMsg)
      return result
    }
    if (typeof key !== 'string' || key.length === 0) {
      result.errorMsg = 'key is empty'
      Logger.error(TAG, 'removeData: ' + result.errorMsg)
      return result
    }
    try {
      const prefs: preferences.Preferences =
        await StorageManager.getPreferences(context, resolveStoreName(key))
      await prefs.delete(key)
      await prefs.flush()
      result.success = true
      Logger.info(TAG, 'removeData success, key=' + key)
    } catch (e) {
      const err: BusinessError = e as BusinessError
      result.errorMsg = err.message
      Logger.error(TAG, 'removeData failed, key=' + key +
        ', code=' + err.code.toString() + ', msg=' + err.message)
    }
    return result
  }

  /**
   * 检查键是否存在
   * @param context - 应用上下文
   * @param key - 存储键名
   * @returns Promise<boolean> 是否存在
   */
  static async hasData(context: Context, key: string): Promise<boolean> {
    if (context === null || context === undefined || typeof key !== 'string' || key.length === 0) {
      return false
    }
    try {
      const prefs: preferences.Preferences =
        await StorageManager.getPreferences(context, resolveStoreName(key))
      return await prefs.has(key)
    } catch (e) {
      const err: BusinessError = e as BusinessError
      Logger.error(TAG, 'hasData failed, key=' + key + ', msg=' + err.message)
      return false
    }
  }

  /**
   * 清除所有缓存（应用退出前调用，避免 context 泄漏）
   */
  static clearCache(): void {
    StorageManager.cache.clear()
    Logger.info(TAG, 'clearCache done')
  }

  // 兼容层：统一 PreferencesUtil / PreferenceManager 调用入口

  /** 应用上下文缓存 */
  private static appContext: Context | null = null

  /** 分域迁移是否已完成（每进程一次） */
  private static storeMigrationDone: boolean = false

  /**
   * 兼容层：初始化 Preferences（替代 PreferencesUtil.init + PreferenceManager.init）
   * 统一入口：EntryAbility.onCreate 只需调用 StorageManager.init(context)
   *
   * @param context - UIAbilityContext
   */
  static async init(context: common.UIAbilityContext): Promise<void> {
    StorageManager.appContext = context;
    // 分域存储迁移：每进程最多执行一次（幂等）
    if (!StorageManager.storeMigrationDone) {
      await StorageManager.migrateToSplitStores(context)
      StorageManager.storeMigrationDone = true
    }
    Logger.info(TAG, 'init success');
  }

  /**
   * 一次性迁移：把历史版本存放在默认 store 中的分域键搬到目标 store，并从默认 store 删除
   * 安全性：逐键先 put 后 delete——任一步失败都不会丢数据（最坏情况双份，读路径以新 store 为准）
   */
  private static async migrateToSplitStores(context: Context): Promise<void> {
    try {
      const defaultPrefs: preferences.Preferences =
        await StorageManager.getPreferences(context, STORE_NAME)
      const allObj: Object = await defaultPrefs.getAll()
      const keys: Array<string> = Object.keys(allObj as Record<string, Object>)
      let moved: number = 0
      for (let i: number = 0; i < keys.length; i++) {
        const key: string = keys[i]
        const target: string = resolveStoreName(key)
        if (target === STORE_NAME) {
          continue
        }
        const value: Object = (allObj as Record<string, Object>)[key]
        const targetPrefs: preferences.Preferences =
          await StorageManager.getPreferences(context, target)
        const hasInTarget: boolean = await targetPrefs.has(key)
        if (!hasInTarget) {
          await targetPrefs.put(key, value)
          await targetPrefs.flush()
        }
        await defaultPrefs.delete(key)
        moved++
      }
      if (moved > 0) {
        await defaultPrefs.flush()
      }
      Logger.info(TAG, 'migrateToSplitStores done, moved=' + moved.toString())
    } catch (e) {
      // 迁移失败不阻塞启动：数据仍留在默认 store，下次启动重试
      Logger.error(TAG, 'migrateToSplitStores failed: ' + (e as Error).message)
    }
  }

  static async setPreference(key: string, value: string): Promise<void> {
    if (StorageManager.appContext === null) {
      Logger.error(TAG, 'setPreference: appContext not initialized')
      return
    }
    const wrapper: StringWrapper = { v: value }
    await StorageManager.saveData(StorageManager.appContext, key, wrapper)
  }

  static async getPreference(key: string, defaultValue: string): Promise<string> {
    if (StorageManager.appContext === null) {
      Logger.error(TAG, 'getPreference: appContext not initialized')
      return defaultValue
    }
    const fallback: StringWrapper = { v: defaultValue }
    const wrapper: StringWrapper = await StorageManager.loadData<StringWrapper>(
      StorageManager.appContext, key, fallback)
    return wrapper.v
  }

  static async setPreferenceBool(key: string, value: boolean): Promise<void> {
    if (StorageManager.appContext === null) {
      Logger.error(TAG, 'setPreferenceBool: appContext not initialized')
      return
    }
    const wrapper: BooleanWrapper = { v: value }
    await StorageManager.saveData(StorageManager.appContext, key, wrapper)
  }

  static async getPreferenceBool(key: string, defaultValue: boolean): Promise<boolean> {
    if (StorageManager.appContext === null) {
      Logger.error(TAG, 'getPreferenceBool: appContext not initialized')
      return defaultValue
    }
    const fallback: BooleanWrapper = { v: defaultValue }
    const wrapper: BooleanWrapper = await StorageManager.loadData<BooleanWrapper>(
      StorageManager.appContext, key, fallback)
    return wrapper.v
  }

  static async setPreferenceObject(key: string, obj: Object): Promise<void> {
    if (StorageManager.appContext === null) {
      Logger.error(TAG, 'setPreferenceObject: appContext not initialized')
      return
    }
    await StorageManager.saveData(StorageManager.appContext, key, obj)
  }

  static async getPreferenceObject<T>(key: string): Promise<T | null> {
    if (StorageManager.appContext === null) {
      Logger.error(TAG, 'getPreferenceObject: appContext not initialized')
      return null
    }
    return await StorageManager.loadData<T | null>(StorageManager.appContext, key, null)
  }

  static async hasPreference(key: string): Promise<boolean> {
    if (StorageManager.appContext === null) {
      return false
    }
    return await StorageManager.hasData(StorageManager.appContext, key)
  }

  static async deletePreference(key: string): Promise<void> {
    if (StorageManager.appContext === null) {
      Logger.error(TAG, 'deletePreference: appContext not initialized')
      return
    }
    await StorageManager.removeData(StorageManager.appContext, key)
  }

  /**
   * 兼容层：保存 AI 拆解任务（替代 PreferenceManager.saveAITasks）
   * 内部仍委托 StorageManager.saveData，统一入口
   *
   * @param tasks - AI 拆解任务数组
   */
  static async saveAITasks(tasks: Array<AiGeneratedTask>): Promise<void> {
    if (StorageManager.appContext === null) {
      Logger.error(TAG, 'saveAITasks: context not initialized')
      return
    }
    try {
      const snapshot: Array<object> = []
      for (let i: number = 0; i < tasks.length; i++) {
        snapshot.push(tasks[i].toJSON() as object)
      }
      await StorageManager.saveData(
        StorageManager.appContext,
        CommonConstants.STORAGE_KEY_AI_TASKS,
        snapshot as object
      )
      Logger.info(TAG, 'saveAITasks success, count=' + tasks.length.toString())
    } catch (e) {
      Logger.error(TAG, 'saveAITasks failed: ' + (e as Error).message)
    }
  }

  /**
   * 兼容层：加载 AI 拆解任务（替代 PreferenceManager.loadAITasks）
   * 内部仍委托 StorageManager.loadData，统一入口
   *
   * @returns AI 拆解任务数组
   */
  static async loadAITasks(): Promise<Array<AiGeneratedTask>> {
    if (StorageManager.appContext === null) {
      Logger.error(TAG, 'loadAITasks: context not initialized')
      return []
    }
    try {
      const raw: Array<AiGeneratedTaskJSON> = await StorageManager.loadData<Array<AiGeneratedTaskJSON>>(
        StorageManager.appContext,
        CommonConstants.STORAGE_KEY_AI_TASKS,
        []
      )
      if (!Array.isArray(raw) || raw.length === 0) {
        return []
      }
      const tasks: Array<AiGeneratedTask> = []
      for (let i: number = 0; i < raw.length; i++) {
        const task: AiGeneratedTask | null = AiGeneratedTask.fromJSON(raw[i])
        if (task !== null) {
          tasks.push(task)
        } else {
          Logger.warn(TAG, 'loadAITasks: skip invalid record at index=' + i.toString())
        }
      }
      Logger.info(TAG, 'loadAITasks success, count=' + tasks.length.toString())
      return tasks
    } catch (e) {
      Logger.error(TAG, 'loadAITasks failed: ' + (e as Error).message)
      return []
    }
  }

  /**
   * 兼容层：清除 AI 拆解任务（替代 PreferenceManager.clearAITasks）
   * 内部仍委托 StorageManager.removeData，统一入口
   */
  static async clearAITasks(): Promise<void> {
    if (StorageManager.appContext === null) {
      Logger.error(TAG, 'clearAITasks: context not initialized')
      return
    }
    try {
      await StorageManager.removeData(
        StorageManager.appContext,
        CommonConstants.STORAGE_KEY_AI_TASKS
      )
      Logger.info(TAG, 'clearAITasks success')
    } catch (e) {
      Logger.error(TAG, 'clearAITasks failed: ' + (e as Error).message)
    }
  }

  /**
   * 兼容层：保存草稿（替代 AIPage 中 AppStorage 草稿操作）
   * 底层已从 AppStorage 迁移至 PreferencesUtil 持久化
   *
   * @param draftKey - 草稿存储键名
   * @param text - 草稿文本
   */
  static saveDraft(draftKey: string, text: string): void {
    if (StorageManager.appContext === null) {
      Logger.warn(TAG, 'saveDraft: appContext not initialized')
      return
    }
    try {
      if (text.length > 0) {
        const wrapper: StringWrapper = { v: text }
        StorageManager.saveData(StorageManager.appContext, draftKey, wrapper)
      } else {
        StorageManager.removeData(StorageManager.appContext, draftKey)
      }
    } catch (e) {
      Logger.warn(TAG, 'saveDraft failed: ' + (e as Error).message)
    }
  }

  /**
   * 兼容层：加载草稿（替代 AIPage 中 AppStorage 草稿操作）
   * 底层已从 AppStorage 迁移至 PreferencesUtil 持久化
   *
   * @param draftKey - 草稿存储键名
   * @returns 草稿文本
   */
  static async loadDraft(draftKey: string): Promise<string> {
    if (StorageManager.appContext === null) {
      Logger.warn(TAG, 'loadDraft: appContext not initialized')
      return ''
    }
    try {
      const fallback: StringWrapper = { v: '' }
      const wrapper: StringWrapper = await StorageManager.loadData<StringWrapper>(
        StorageManager.appContext, draftKey, fallback)
      return wrapper.v
    } catch (e) {
      Logger.warn(TAG, 'loadDraft failed: ' + (e as Error).message)
      return ''
    }
  }

  /**
   * 兼容层：清除草稿（替代 AIPage 中 AppStorage.delete 草稿操作）
   * 底层已从 AppStorage 迁移至 PreferencesUtil 持久化
   *
   * @param draftKey - 草稿存储键名
   */
  static clearDraft(draftKey: string): void {
    if (StorageManager.appContext === null) {
      Logger.warn(TAG, 'clearDraft: appContext not initialized')
      return
    }
    StorageManager.removeData(StorageManager.appContext, draftKey)
  }

  /**
   * 兼容层：检查是否已初始化（替代 PreferenceManager.isInitialized）
   *
   * @returns 是否已初始化
   */
  static isInitialized(): boolean {
    return StorageManager.appContext !== null
  }

  /**
   * 工具方法：解析 TaskPriority 枚举值（兼容 number/string）
   * JSON 序列化后 enum 会变成字符串，必须做兼容
   * @param raw - 序列化后的原始值
   * @returns TaskPriority 枚举值
   *
   * 注意：此方法保留为兼容代理，实际逻辑已迁移至 Model 层 parseTaskPriority
   */
  static parseTaskPriority(raw: number | string | null | undefined): TaskPriority {
    return parseTaskPriority(raw)
  }
}
