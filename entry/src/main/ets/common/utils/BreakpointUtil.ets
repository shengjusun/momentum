/**
 * @file 断点适配工具
 * @description 基于 mediaquery 的屏幕断点监听封装，禁止写死屏幕宽度判断
 * @module common/utils
 * @date 2026-06-17
 */

import { mediaquery } from '@kit.ArkUI'
import { Logger } from './Logger'
import { CommonConstants } from '../constants/CommonConstants'
import { BreakpointType } from '../types/ApiTypes'

/**
 * 断点变化回调签名
 * @param breakpoint - 当前断点值
 */
export type BreakpointChangeListener = (breakpoint: BreakpointType) => void

/**
 * 断点适配工具类
 *
 * 强制规范：
 * - 禁止写死屏幕宽度判断（如 if (width > 800)）
 * - 必须使用 mediaquery 监听断点变化
 * - 监听器必须在 aboutToDisappear 中 off 解绑
 */
export class BreakpointUtil {
  /** 当前断点值 */
  private static currentBreakpoint: BreakpointType = 'sm'

  /** mediaquery 监听器（小屏↔中屏） */
  private static mdListener: mediaquery.MediaQueryListener | null = null

  /** mediaquery 监听器（中屏↔大屏） */
  private static lgListener: mediaquery.MediaQueryListener | null = null

  /** 已注册的业务回调列表 */
  private static listeners: BreakpointChangeListener[] = []

  /** 引用计数：防止重复注册/提前销毁 */
  private static refCount: number = 0

  /**
   * 注册断点监听
   * 必须在组件 aboutToAppear 中调用，并在 aboutToDisappear 中调用 unregister
   */
  static register(): void {
    const tag: string = 'BreakpointUtil'
    BreakpointUtil.refCount++
    if (BreakpointUtil.refCount > 1) {
      Logger.info(tag, 'register: refCount=' + BreakpointUtil.refCount.toString() + ', already registered, skip')
      return
    }

    try {
      // md 断点：宽度 >= 600vp
      BreakpointUtil.mdListener = mediaquery.matchMediaSync(`(min-width: ${CommonConstants.BREAKPOINT_MD}vp)`)
      BreakpointUtil.mdListener.on('change', (_result: mediaquery.MediaQueryResult): void => {
        BreakpointUtil.updateBreakpoint()
      })

      // lg 断点：宽度 >= 840vp
      BreakpointUtil.lgListener = mediaquery.matchMediaSync(`(min-width: ${CommonConstants.BREAKPOINT_LG}vp)`)
      BreakpointUtil.lgListener.on('change', (_result: mediaquery.MediaQueryResult): void => {
        BreakpointUtil.updateBreakpoint()
      })

      // 初始值：根据当前匹配状态推断
      BreakpointUtil.updateBreakpoint()
      Logger.info(tag, 'register success, initial={0}', BreakpointUtil.currentBreakpoint)
    } catch (error) {
      Logger.error(tag, 'register failed, msg={0}', (error as Error).message)
    }
  }

  /**
   * 联动推导当前断点（唯一写入点）
   * 两个 mediaquery 监听器的 change 事件会独立触发，且宽度 < 600vp 时 lg 监听器
   * 也会以 matches=false 触发——若各自独立写值，lg 的 false 会把正确的 sm 覆盖成 md
   * （表现为手机竖屏页面被渲染成平板双列布局）。必须每次用两个监听器的 matches
   * 状态联合推导：lg 匹配 → lg；否则 md 匹配 → md；否则 sm。
   */
  private static updateBreakpoint(): void {
    const lgMatches: boolean = BreakpointUtil.lgListener !== null && BreakpointUtil.lgListener.matches
    const mdMatches: boolean = BreakpointUtil.mdListener !== null && BreakpointUtil.mdListener.matches
    const next: BreakpointType = lgMatches ? 'lg' : (mdMatches ? 'md' : 'sm')
    if (next === BreakpointUtil.currentBreakpoint) {
      return
    }
    BreakpointUtil.currentBreakpoint = next
    Logger.info('BreakpointUtil', 'breakpoint changed to {0}', next)
    BreakpointUtil.notifyListeners()
  }

  /**
   * 注销断点监听
   * 必须在组件 aboutToDisappear 中调用，避免内存泄漏
   */
  static unregister(): void {
    const tag: string = 'BreakpointUtil'
    BreakpointUtil.refCount--
    if (BreakpointUtil.refCount > 0) {
      Logger.info(tag, 'unregister: refCount=' + BreakpointUtil.refCount.toString() + ', still in use, skip')
      return
    }
    // 防御性保护：refCount 不应为负
    if (BreakpointUtil.refCount < 0) {
      Logger.warn(tag, 'unregister: refCount=' + BreakpointUtil.refCount.toString() + ', reset to 0')
      BreakpointUtil.refCount = 0
      return
    }
    try {
      if (BreakpointUtil.mdListener !== null) {
        BreakpointUtil.mdListener.off('change')
        BreakpointUtil.mdListener = null
      }
      if (BreakpointUtil.lgListener !== null) {
        BreakpointUtil.lgListener.off('change')
        BreakpointUtil.lgListener = null
      }
      BreakpointUtil.listeners = []
      Logger.info(tag, 'unregister success')
    } catch (error) {
      Logger.error(tag, 'unregister failed, msg={0}', (error as Error).message)
    }
  }

  /**
   * 添加断点变化回调
   * @param listener - 回调函数
   */
  static addListener(listener: BreakpointChangeListener): void {
    BreakpointUtil.listeners.push(listener)
  }

  /**
   * 移除断点变化回调
   * @param listener - 回调函数
   */
  static removeListener(listener: BreakpointChangeListener): void {
    const index: number = BreakpointUtil.listeners.indexOf(listener)
    if (index >= 0) {
      BreakpointUtil.listeners.splice(index, 1)
    }
  }

  /**
   * 获取当前断点值
   * @returns 当前断点（sm/md/lg）
   */
  static getCurrentBreakpoint(): BreakpointType {
    return BreakpointUtil.currentBreakpoint
  }

  /**
   * 判断是否为小屏（手机竖屏）
   * @returns 是否小屏
   */
  static isSmallScreen(): boolean {
    return BreakpointUtil.currentBreakpoint === 'sm'
  }

  /**
   * 判断是否为大屏（折叠屏展开/平板）
   * @returns 是否大屏
   */
  static isLargeScreen(): boolean {
    return BreakpointUtil.currentBreakpoint === 'lg'
  }

  /**
   * 通知所有已注册的回调
   */
  private static notifyListeners(): void {
    const current: BreakpointType = BreakpointUtil.currentBreakpoint
    for (let i: number = 0; i < BreakpointUtil.listeners.length; i++) {
      try {
        BreakpointUtil.listeners[i](current)
      } catch (e) {
        // 单个回调异常不影响其他回调
      }
    }
  }

  /** 私有构造：禁止实例化 */
  private constructor() {}
}
