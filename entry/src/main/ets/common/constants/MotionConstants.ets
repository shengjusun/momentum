/**
 * @file 动效常量表
 * @description 全工程动效参数的单一来源：时长、曲线、位移与缩放量。调整任何动效只改本文件。
 *
 * 基调 = **分层克制**：
 *   - 基础交互（按压/出现/消失）走短促、系统一致的曲线，幅度保守；
 *   - 只在情绪节点（完成打卡/里程碑达成，L3）才放开存在感。
 *
 * ⚠️ 为什么必须收口：全工程原有 28 处 `.animation()` 的 duration 各写各的
 *   （80/100/120/150/180/200/250/300 共 8 种取值），曲线清一色 `Curve.EaseOut`，
 *   导致跨页面手感不一致。此处收敛为三档。
 *
 * ⚠️ 不动清单（勿用本文件覆盖）：
 *   - `PomodoroImmersiveScreen.ets` 全部动画（v4 版式契约，`check_pomo_immersive.py` 有断言）
 *   - `GoalDetailPage.ets` 骨架 shimmer（1200ms Linear 无限循环）
 *   - `MainTab.ets` 的 `.animationDuration(300)`（HdsTabs 系统动效）
 *
 * @module common/constants
 */

import { curves } from '@kit.ArkUI'

export class MotionConstants {
  /* ============================================================
   * 时长三档（收敛原 8 种取值）
   * ============================================================ */

  /** 快档：按压反馈 / 状态切换 / 图标换形（吸收原 80 / 100 / 120 / 150） */
  static readonly DURATION_FAST: number = 120

  /** 标准档：元素出现与消失（吸收原 180 / 200 / 250） */
  static readonly DURATION_BASE: number = 200

  /** 慢档：底部面板与大区块（吸收原 300） */
  static readonly DURATION_SLOW: number = 300

  /* ============================================================
   * 曲线
   * ============================================================ */

  /** 按压/状态切换：快而钝，不弹 —— 克制基调下按压不该有回弹 */
  static readonly CURVE_PRESS: Curve = Curve.Friction

  /** 出现（减速进入）：起步快、落位稳 */
  static readonly CURVE_ENTER: Curve = Curve.FastOutSlowIn

  /** 消失（加速离开）：去得干脆 */
  static readonly CURVE_EXIT: Curve = Curve.Friction

  /** 面板与大区块：与出现同族，保证层次一致 */
  static readonly CURVE_PANEL: Curve = Curve.FastOutSlowIn

  /* ============================================================
   * 位移 / 缩放量（分层克制的幅度上限：位移 ≤20vp、缩放偏移 ≤0.06）
   * ============================================================ */

  /** 页面/区块从下方进入的起始位移（vp） */
  static readonly ENTER_TRANSLATE_Y: number = 16

  /** 底部面板上滑距离（vp）—— 面板例外，需要更明显的方向感 */
  static readonly PANEL_TRANSLATE_Y: number = 40

  /** 居中对话框起始缩放比 */
  static readonly DIALOG_SCALE_FROM: number = 0.94

  /** 居中对话框起始纵向偏移（vp） */
  static readonly DIALOG_TRANSLATE_Y: number = 8

  /** 列表项进入的起始纵向位移（vp）—— 比区块更短：长列表里幅度大会显得"飘" */
  static readonly LIST_ITEM_TRANSLATE_Y: number = 12

  /**
   * 列表项离场的收缩比（0.96）
   * ⚠️ 离场刻意用「收缩 + 淡出」而**不用位移**：位移会让被删项周围的项
   *    重排过程与消失过程互相干扰，观感混乱。收缩则把视觉焦点收在消失点上。
   * ⚠️ 必须 ≠ 1：官方约束「属性值如与默认值相同则不产生转场动画」
   *    （`scale` 默认 1、`opacity` 默认 1），填 1 等于没有动效。
   */
  static readonly LIST_ITEM_SCALE_TO: number = 0.96

  /**
   * 展开区块的起始纵向位移（vp，**负值 = 从上方进入**）
   * 语义：展开的内容贴着锚点"向下长出来"，故起点在锚点上方；收起时反向收回。
   * 与 `LIST_ITEM_TRANSLATE_Y`（正值）方向刻意相反 —— 列表尾部的新内容该从下方来，
   * 而展开区块该从锚点下方长出，两者空间因果不同。
   */
  static readonly EXPAND_TRANSLATE_Y: number = -8

  private constructor() {}

  /* ============================================================
   * AnimateParam 工厂
   * ============================================================ */

  /**
   * 按压反馈 / 状态切换 / 图标换形
   * 适用于：onTouch 按压态、图标选中态切换、列表行按压
   */
  static pressParam(): AnimateParam {
    const param: AnimateParam = {
      duration: MotionConstants.DURATION_FAST,
      curve: MotionConstants.CURVE_PRESS
    }
    return param
  }

  /**
   * 元素出现（淡入 + 落位）
   * 适用于：弹层遮罩、居中对话框、条件渲染区块的插入
   */
  static enterParam(): AnimateParam {
    const param: AnimateParam = {
      duration: MotionConstants.DURATION_BASE,
      curve: MotionConstants.CURVE_ENTER
    }
    return param
  }

  /**
   * 元素消失（加速离开）
   * 刻意比出现更短 —— 离开不该让用户等
   */
  static exitParam(): AnimateParam {
    const param: AnimateParam = {
      duration: MotionConstants.DURATION_FAST,
      curve: MotionConstants.CURVE_EXIT
    }
    return param
  }

  /**
   * 底部面板 / 大区块
   * 适用于：从底部升起的操作面板、大块内容区的展开
   */
  static panelParam(): AnimateParam {
    const param: AnimateParam = {
      duration: MotionConstants.DURATION_SLOW,
      curve: MotionConstants.CURVE_PANEL
    }
    return param
  }

  /**
   * 响应式弹簧（物理感，跟随手势/位移变化）
   * 适用于：悬浮按钮换边、位置迁移等"滑过去"的连续位移。
   *
   * ⚠️ 刻意不设 duration：弹簧由 response/dampingFraction 决定节奏，
   *    填 duration 会与弹簧物理冲突。
   * ⚠️ `curves` 已在 SDK 侧确认由 `@kit.ArkUI` 再导出（497 个导出名之一），
   *    且 `AnimateParam.curve` 接受 `Curve | string | ICurve`。
   *
   * @param response - 响应时长（秒），默认 0.35，越小越跟手
   * @param dampingFraction - 阻尼比，0~1 越小回弹越明显，默认 0.86
   */
  static springParam(response: number = 0.35, dampingFraction: number = 0.86): AnimateParam {
    const param: AnimateParam = {
      curve: curves.responsiveSpringMotion(response, dampingFraction)
    }
    return param
  }
}
