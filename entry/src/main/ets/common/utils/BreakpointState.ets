/**
 * @file 全局响应式断点状态
 * @description
 *   基于 @ObservedV2 + @Trace 的断点单例，配合 BreakpointUtil（mediaquery）使用。
 *   所有 @ComponentV2 页面直接读取 breakpointState.isTablet 即可自动响应断点变化，
 *   无需各自注册/解绑 mediaquery 监听。
 *
 *   生命周期约定：
 *   - 根页面（MainTab）在 aboutToAppear 调用 bindBreakpointState()
 *   - 在 aboutToDisappear 调用 unbindBreakpointState()
 *   - 子页面只读不绑定
 *
 * @module common/utils
 */

import { BreakpointUtil, BreakpointChangeListener } from './BreakpointUtil'
import { BreakpointType } from '../types/ApiTypes'

/**
 * 全局断点状态（响应式单例）
 *
 * - breakpoint: 当前断点值（sm/md/lg）
 * - isTablet: 是否大屏（lg，平板/折叠屏展开态），用于双布局切换
 */
@ObservedV2
export class BreakpointState {
  /** 当前断点值 */
  @Trace breakpoint: BreakpointType = 'sm'

  /** 是否大屏（平板/折叠屏展开） */
  @Trace isTablet: boolean = false
}

/** 全局唯一实例，页面直接引用读取即可获得响应式更新 */
export const breakpointState: BreakpointState = new BreakpointState()

/** 已绑定的监听器引用（用于解绑） */
let boundListener: BreakpointChangeListener | null = null

/** 绑定计数：支持多层嵌套绑定/解绑 */
let bindCount: number = 0

/**
 * 绑定全局断点状态（幂等，可重入）
 * 内部持有 BreakpointUtil 的注册/监听，把 mediaquery 结果同步到 breakpointState
 */
export function bindBreakpointState(): void {
  bindCount++
  if (bindCount > 1) {
    return
  }
  boundListener = (bp: BreakpointType): void => {
    breakpointState.breakpoint = bp
    breakpointState.isTablet = bp === 'lg'
  }
  BreakpointUtil.register()
  // 关键顺序：先挂监听再读初始值——若窗口在 register 与 addListener 之间发生变化，
  // change 事件能正常写入 breakpointState，不丢事件
  BreakpointUtil.addListener(boundListener)
  breakpointState.breakpoint = BreakpointUtil.getCurrentBreakpoint()
  breakpointState.isTablet = BreakpointUtil.isLargeScreen()
}

/**
 * 解绑全局断点状态
 * 与 bindBreakpointState 配对调用，计数归零时才真正注销 mediaquery 监听
 */
export function unbindBreakpointState(): void {
  if (bindCount === 0) {
    return
  }
  bindCount--
  if (bindCount > 0) {
    return
  }
  if (boundListener !== null) {
    BreakpointUtil.removeListener(boundListener)
    boundListener = null
  }
  BreakpointUtil.unregister()
}
