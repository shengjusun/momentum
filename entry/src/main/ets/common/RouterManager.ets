/** 全局路由管理器 - 管理导航栈、Tab切换、深链竞态协调 */

import { HdsTabsController } from '@kit.UIDesignKit'
import { RouteParam } from '../model/Models'
import { Logger } from './utils/Logger'

// NavPathStack 是 ArkUI 全局类型，无需 import
// HdsTabsController 来自 @kit.UIDesignKit（HDS 页签栏，API 23+），接口与 TabsController 兼容（changeIndex 等）

// 路由跳转参数结构，对应 pushPath 的 NavPathInfo
interface NavPath {
  name: string;
  param: RouteParam;
}

// 使用具体 interface 而非 Record，满足 ArkTS 强类型约束
interface RouteNameConfig {
  readonly HOME: string;
  readonly ROUTE: string;
  readonly AI: string;
  readonly MINE: string;
  readonly LOGIN: string;
  readonly GOAL_DETAIL: string;
  readonly TASK_DETAIL: string;
  readonly GOAL_HISTORY: string;
  readonly NOTIFICATION: string;
  readonly SETTINGS: string;
  readonly STATS: string;
  readonly IMPORT_EXPORT: string;
  readonly HELP: string;
  readonly FEEDBACK: string;
  readonly ABOUT: string;
  readonly TAGS: string;
}

interface TabIndexConfig {
  readonly HOME: number;
  readonly ROUTE: number;
  readonly AI: number;
  readonly MINE: number;
}

/**
 * 全局路由栈单例
 */
export const globalNavStack: NavPathStack = new NavPathStack()

/**
 * 全局 Tabs 控制器单例（HDS 页签栏控制器）
 * 供 MainTab 挂载 + 跨页 changeIndex 切 Tab（HomePage / GoalDetailPage / RoutePage）
 */
export const globalTabsController: HdsTabsController = new HdsTabsController()

let currentTabIndex: number = 0

export function getCurrentTabIndex(): number {
  return currentTabIndex
}

export function setCurrentTabIndex(index: number): void {
  currentTabIndex = index
}

/**
 * 路由名称常量（集中管理，避免魔法字符串散落各处）
 * 用工厂函数构造，满足 ArkTS 禁止 as 类型断言的约束
 */
function buildRouteNameConfig(
  home: string, route: string, ai: string, mine: string,
  login: string, goalDetail: string, taskDetail: string, goalHistory: string,
  notification: string, settings: string, stats: string, importExport: string,
  help: string, feedback: string, about: string, tags: string
): RouteNameConfig {
  const config: RouteNameConfig = {
    HOME: home,
    ROUTE: route,
    AI: ai,
    MINE: mine,
    LOGIN: login,
    GOAL_DETAIL: goalDetail,
    TASK_DETAIL: taskDetail,
    GOAL_HISTORY: goalHistory,
    NOTIFICATION: notification,
    SETTINGS: settings,
    STATS: stats,
    IMPORT_EXPORT: importExport,
    HELP: help,
    FEEDBACK: feedback,
    ABOUT: about,
    TAGS: tags
  }
  return config
}

export const ROUTE_NAME: RouteNameConfig = buildRouteNameConfig(
  'HomePage', 'RoutePage', 'AIPage', 'ProfilePage',
  'LoginPage', 'GoalDetailPage', 'TaskDetailPage', 'GoalHistoryPage',
  'NotificationPage', 'SettingPage', 'StatsPage', 'ImportExportPage',
  'HelpPage', 'FeedbackPage', 'AboutPage', 'CategoryManagePage'
)

/**
 * Tab 索引常量（集中管理）
 */
function buildTabIndexConfig(home: number, route: number, ai: number, mine: number): TabIndexConfig {
  const config: TabIndexConfig = {
    HOME: home,
    ROUTE: route,
    AI: ai,
    MINE: mine
  }
  return config
}

export const TAB_INDEX: TabIndexConfig = buildTabIndexConfig(0, 1, 2, 3)

let shouldAutoExpandAdvancedSettings: boolean = false

/**
 * 多端流转数据接口
 * routeName: 当前路由名称
 * param: 路由参数（已序列化为字符串）
 */
interface MigrationData {
  routeName: string
  param: string
  tabIndex: number
}

let migrationPayload: MigrationData | null = null

/**
 * 深链待执行标志
 * 协调冷启动竞态：MainTab 自动跳登录页 vs EntryAbility 深链路由
 * 存在深链时跳过自动登录跳转，交给深链路由先执行，避免页面栈混乱
 */
let pendingDeepLinkFlag: boolean = false

export function markPendingDeepLink(): void {
  pendingDeepLinkFlag = true
  Logger.info('RouterManager', 'markPendingDeepLink: deep link marked')
}

/**
 * 查询是否存在待执行的深链（不消费）
 * @returns true 表示本次启动存在通知直达/意图/流转路由
 */
export function hasPendingDeepLink(): boolean {
  return pendingDeepLinkFlag
}

/**
 * 读取并消费深链标志（MainTab 判断登录跳转后调用）
 * @returns true 表示本次启动存在深链
 */
export function consumePendingDeepLink(): boolean {
  const existed: boolean = pendingDeepLinkFlag
  pendingDeepLinkFlag = false
  return existed
}

// 流转恢复完成回调函数
let onRestoreDoneCallback: (() => void) | null = null

export function setOnRestoreDoneCallback(callback: (() => void) | null): void {
  onRestoreDoneCallback = callback
  Logger.info('RouterManager', 'setOnRestoreDoneCallback: callback registered')
}

export function notifyMigrationRestoreDone(): void {
  Logger.info('RouterManager', 'notifyMigrationRestoreDone: called')
  if (onRestoreDoneCallback !== null) {
    Logger.info('RouterManager', 'notifyMigrationRestoreDone: triggering callback')
    onRestoreDoneCallback()
    onRestoreDoneCallback = null // 只触发一次
  } else {
    Logger.warn('RouterManager', 'notifyMigrationRestoreDone: no callback registered')
  }
}

export function setMigrationPayload(data: MigrationData): void {
  migrationPayload = data
  Logger.info('RouterManager',
    'setMigrationPayload: data stored, routeName=' + data.routeName + ', tabIndex=' + data.tabIndex + ', paramLen=' +
      data.param.length.toString())
}

export function restoreMigrationIfNeeded(): boolean {
  Logger.info('RouterManager',
    'restoreMigrationIfNeeded: enter, migrationPayload is null=' + (migrationPayload === null).toString())
  if (migrationPayload === null) {
    Logger.warn('RouterManager', 'restoreMigrationIfNeeded: migrationPayload is NULL, return false')
    return false
  }
  const data: MigrationData = migrationPayload
  migrationPayload = null
  Logger.info('RouterManager',
    'restoreMigrationIfNeeded: processing, routeName=' + data.routeName + ', tabIndex=' + data.tabIndex)

  try {
    if (typeof data.tabIndex === 'number') {
      try {
        Logger.info('RouterManager', 'restoreMigrationIfNeeded: before changeIndex=' + data.tabIndex)
        globalTabsController.changeIndex(data.tabIndex)
        Logger.info('RouterManager', 'restoreMigrationIfNeeded: after changeIndex SUCCESS')
      } catch (_e) {
        Logger.warn('RouterManager', 'restoreMigrationIfNeeded: change tab index failed: ' + (_e as Error).message)
      }
    }

    if (data.routeName === 'MainTab') {
      Logger.info('RouterManager', 'restoreMigrationIfNeeded: MainTab route, return true, tabIndex=' + data.tabIndex)
      return true
    }

    const param: RouteParam = parseMigrationParam(data.param)
    const pathInfo: NavPathInfo = new NavPathInfo(data.routeName, param)
    Logger.info('RouterManager',
      'restoreMigrationIfNeeded: before pushPath, routeName=' + data.routeName + ', paramId=' + param.id)
    globalNavStack.pushPath(pathInfo)
    Logger.info('RouterManager', 'restoreMigrationIfNeeded: after pushPath SUCCESS, routeName=' + data.routeName)
    return true
  } catch (_e) {
    Logger.error('RouterManager',
      'restoreMigrationIfNeeded: FAILED for route=' + data.routeName + ', error=' + (_e as Error).message)
    return false
  }
}

/**
 * 解析流转参数 JSON 字符串
 * - 解析失败：返回默认空 param
 * - 解析成功但字段缺失：用空字符串填充
 * @param raw - 原始 JSON 字符串
 * @returns 解析后的参数（RouteParam 类型）
 */
function parseMigrationParam(raw: string): RouteParam {
  const result: RouteParam = { id: '' }
  if (raw.length === 0) {
    return result
  }
  try {
    const obj: Record<string, Object> = JSON.parse(raw) as Record<string, Object>
    if (obj && typeof obj === 'object') {
      const idVal: Object | undefined = obj['id']
      if (typeof idVal === 'string') {
        result.id = idVal
      }
      const statusVal: Object | undefined = obj['status']
      if (typeof statusVal === 'string') {
        result.status = statusVal
      }
    }
  } catch (_e) {
    Logger.warn('RouterManager', 'parseMigrationParam: JSON parse failed, use default empty param')
  }
  return result
}

export function getShouldAutoExpandAdvancedSettings(): boolean {
  return shouldAutoExpandAdvancedSettings
}

export function setAutoExpandAdvancedSettings(value: boolean): void {
  shouldAutoExpandAdvancedSettings = value
}

/**
 * 构造 RouteParam（带 id 的显式对象）
 * @param id - 目标 ID
 * @returns RouteParam
 */
export function buildRouteParam(id: string): RouteParam {
  const param: RouteParam = { id: id }
  return param
}

/* ============================================================
 * 跳转防抖（防止快速连点重复压栈详情页）
 * ============================================================ */
const PUSH_DEBOUNCE_MS: number = 600
let lastPushTime: number = 0

/**
 * 获取跳转锁：PUSH_DEBOUNCE_MS 内的连续跳转只放行第一次
 * @returns true=放行；false=防抖窗口内，调用方应忽略本次点击
 */
export function tryAcquireNavLock(): boolean {
  const now: number = Date.now()
  if (now - lastPushTime < PUSH_DEBOUNCE_MS) {
    Logger.info('RouterManager', 'tryAcquireNavLock: debounced push within ' + PUSH_DEBOUNCE_MS.toString() + 'ms')
    return false
  }
  lastPushTime = now
  return true
}

/**
 * 通用压栈（带防抖）：供携带自定义参数对象的页面使用
 * @param name - 路由名
 * @param param - 路由参数（任意对象/null）
 */
export function pushNavPath(name: string, param: Object | null): void {
  if (!tryAcquireNavLock()) {
    return
  }
  globalNavStack.pushPath({ name: name, param: param })
}

/**
 * 通用路由跳转（不取 id 的纯跳转）
 * @param routeName - 路由名
 */
export function navigateTo(routeName: string): void {
  if (!tryAcquireNavLock()) {
    return
  }
  const emptyParam: RouteParam = { id: '' }
  const pathInfo: NavPathInfo = new NavPathInfo(routeName, emptyParam)
  globalNavStack.pushPath(pathInfo)
}

/**
 * 带 id 的路由跳转
 * @param routeName - 路由名
 * @param id - 目标 ID（不可为空/undefined/null）
 */
export function navigateToWithId(routeName: string, id: string | undefined | null): void {
  // 空ID会导致目标页取参崩溃，提前拦截
  if (!id || id.length === 0) {
    Logger.warn('RouterManager', 'navigateToWithId: invalid id, route=' + routeName)
    return
  }
  if (!tryAcquireNavLock()) {
    return
  }
  const param: RouteParam = { id: id }
  const pathInfo: NavPathInfo = new NavPathInfo(routeName, param)
  globalNavStack.pushPath(pathInfo)
}

/**
 * 栈顶是否已是指定的 (routeName, id) 页面
 *
 * 用于通知直达 / 热启动恢复的幂等跳转判断：
 * 只比路由名不够（不同 id 的同一路由是两个不同页面），必须连 id 一起比。
 *
 * @param routeName - 路由名
 * @param id - 路由参数中的 id
 * @returns true 表示栈顶就是该页面
 */
export function isTopRoute(routeName: string, id: string): boolean {
  try {
    const pathStack: NavPathInfo[] = globalNavStack.getPathStack()
    if (!Array.isArray(pathStack) || pathStack.length === 0) {
      return false
    }
    const top: NavPathInfo = pathStack[pathStack.length - 1]
    if (top === undefined || top === null || top.name !== routeName) {
      return false
    }
    // 两段式转换：与 TaskDetailPage 读取路由参数保持同一写法（ArkTS 不允许直接断言 unknown）
    const rawParam: Object = top.param as Object
    if (rawParam === undefined || rawParam === null) {
      return false
    }
    const paramObj: Record<string, Object> = rawParam as Record<string, Object>
    return String(paramObj['id'] ?? '') === id
  } catch (e) {
    Logger.warn('RouterManager', 'isTopRoute failed: ' + (e as Error).message)
    return false
  }
}

/**
 * 带 id 的幂等跳转（通知直达 / 热启动恢复专用）
 *
 * 栈顶已是同一 (routeName, id) 页面时直接返回，不重复压栈。
 * 否则每点一次通知都会压一层新的详情页，用户"返回一次"退回到的是上一个同类页面
 * 而不是点通知之前的那一页（真机复现：番茄钟通知点两次，返回后又看到番茄钟）。
 *
 * ⚠️ 命中幂等时【不消费防抖锁】：本次什么都没做，不该影响紧随其后的正常跳转。
 * ⚠️ 不委托给 navigateToWithId：调用方需要"本次是否真的把页面放到了栈顶"这个确定答案
 *    （跳转可能被 600ms 防抖拦下），委托会导致返回值不可靠。
 *
 * @returns true = 调用结束后目标页确实在栈顶（本次压栈成功，或本来就在栈顶）；false = 未生效
 */
export function navigateToWithIdOnce(routeName: string, id: string | undefined | null): boolean {
  if (!id || id.length === 0) {
    Logger.warn('RouterManager', 'navigateToWithIdOnce: invalid id, route=' + routeName)
    return false
  }
  if (isTopRoute(routeName, id)) {
    Logger.info('RouterManager',
      'navigateToWithIdOnce: top is already ' + routeName + ', skip push, id=' + id)
    return true
  }
  if (!tryAcquireNavLock()) {
    Logger.warn('RouterManager',
      'navigateToWithIdOnce: debounced, push skipped, route=' + routeName)
    return false
  }
  const param: RouteParam = { id: id }
  const pathInfo: NavPathInfo = new NavPathInfo(routeName, param)
  globalNavStack.pushPath(pathInfo)
  return true
}
