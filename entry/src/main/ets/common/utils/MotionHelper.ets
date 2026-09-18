/**
 * @file 动效构建助手
 * @description 组合过渡（TransitionEffect）的单一来源，供页面/组件直接取用。
 *
 * ⚠️ 存在的理由（本次升级的核心发现）：
 *   官方《组件内转场》对象说明第 3 点 —— 「如果未使用 animateTo 触发转场动画
 *   且 TransitionEffect 中也无 animation 参数，则该组件**直接出现或者消失**。」
 *   本工程原有 9 处 `.transition()` 中有 8 处是裸 `TransitionEffect.OPACITY`，
 *   既无 `.animation()`、外层也无 `animateTo` 包装 → **它们从来没在动**。
 *   把参数收口到此处，避免各处再写出"看起来有、其实没有"的转场。
 *
 * ⚠️ 另一个必须遵守的官方约束（对象说明第 6 点）：
 *   一旦用 `animateTo` 包装状态变更，动画范围内所有**未配 transition** 的上下树组件
 *   会被自动补一个默认透明度转场 → 不需要动效的必须显式配 `TransitionEffect.IDENTITY`
 *   抑制。`pageRoot()` 就是为此提供的。
 *
 * ⚠️ 遮罩与卡片必须**分离挂载**：遮罩层（overlay_mask）只做透明度，
 *   位移/缩放只能挂在内层卡片上，否则遮罩会跟着卡片一起平移。
 *
 * @module common/utils
 */

import { MotionConstants } from '../constants/MotionConstants'

export class MotionHelper {
  private constructor() {}

  /**
   * 弹层遮罩：纯淡入（挂**最外层**全屏容器）
   * 刻意不叠加位移 —— 遮罩是背景，移动它会带出错误的空间暗示
   */
  static overlayFade(): TransitionEffect {
    return TransitionEffect.OPACITY.animation(MotionConstants.enterParam())
  }

  /**
   * 居中对话框卡片：缩放进场 + 轻微下落 + 淡入（挂**内层卡片**）
   * 出现与消失互为逆过程：出现时 0.94→1、y+8→0，消失时反向
   */
  static dialogCard(): TransitionEffect {
    return TransitionEffect.scale({
      x: MotionConstants.DIALOG_SCALE_FROM,
      y: MotionConstants.DIALOG_SCALE_FROM
    })
      .animation(MotionConstants.enterParam())
      .combine(TransitionEffect.translate({ y: MotionConstants.DIALOG_TRANSLATE_Y }))
      .combine(TransitionEffect.OPACITY)
  }

  /**
   * 底部面板：从下方向上滑入 + 淡入（挂**内层面板**）
   * 方向必须向上 —— 面板从屏幕下方来，往上滑才符合空间因果
   */
  static bottomPanel(): TransitionEffect {
    return TransitionEffect.translate({ y: MotionConstants.PANEL_TRANSLATE_Y })
      .animation(MotionConstants.panelParam())
      .combine(TransitionEffect.OPACITY)
  }

  /**
   * 列表项：进场轻推入 + 淡入，离场收缩 + 淡出（挂 **ListItem / ForEach 的列表项根组件**）
   *
   * ⚠️ 进场与离场**刻意不对称**：
   *   - 进场用位移：新内容"从下方来"符合空间因果（聊天消息、新增步骤都在尾部出现）；
   *   - 离场只用收缩 + 淡出、**不加位移**：位移会让"被删项消失"和"后续项上移重排"
   *     两个过程互相干扰，观感混乱；收缩则把视觉焦点收在消失点上。
   *
   * ⚠️ 本构建器**自带 animation 参数**，因此不要求外层用 animateTo 包裹数据变更
   *   —— 这对本工程至关重要：列表数据是在 ViewModel 里改的（`splice`/`push`），
   *   逻辑层不适合、也无法调用 UI 侧的 animateTo。见文件头说明第 3 点。
   *
   * ⚠️ 生效前提是 **keyGenerator 稳定唯一**（业务 id，不能含数组下标）。
   *   若 key 含 index，删除中间项会导致后续所有项 key 变化 → 框架判定为
   *   "新增 + 删除" → 整段列表重播进场动效，反而更乱。
   */
  static listItem(): TransitionEffect {
    return TransitionEffect.asymmetric(
      TransitionEffect.translate({ y: MotionConstants.LIST_ITEM_TRANSLATE_Y })
        .combine(TransitionEffect.OPACITY)
        .animation(MotionConstants.enterParam()),
      TransitionEffect.scale({
        x: MotionConstants.LIST_ITEM_SCALE_TO,
        y: MotionConstants.LIST_ITEM_SCALE_TO
      })
        .combine(TransitionEffect.OPACITY)
        .animation(MotionConstants.exitParam())
    )
  }

  /**
   * 展开区块：贴着锚点"向下长出"，收起时反向收回
   * （挂 **由 `if` 条件创建/销毁的展开容器**，如目标详情页 L2 任务卡片的步骤区）
   *
   * ⚠️ 为什么这里必须是 `transition` 而不是 `.animation()`：
   *   `if` 换树是"组件插入/删除"，**属性动画对它无效**（没有属性在补间）。
   *   本工程原先在此处配的是 `.animation(MotionConstants.enterParam())`，
   *   对"展开/收起"本身不起作用 —— 官方口径：插入/删除要靠 `transition` 触发。
   *
   * 方向：进场从上方推入（-8vp），因为展开内容长在锚点**下方**，
   *   起点在锚点上方才符合"从标题底下展开"的空间因果；
   *   与 `listItem()`（从下方来）方向相反，是刻意的。
   */
  static expandSection(): TransitionEffect {
    return TransitionEffect.asymmetric(
      TransitionEffect.translate({ y: MotionConstants.EXPAND_TRANSLATE_Y })
        .combine(TransitionEffect.OPACITY)
        .animation(MotionConstants.enterParam()),
      TransitionEffect.translate({ y: MotionConstants.EXPAND_TRANSLATE_Y })
        .combine(TransitionEffect.OPACITY)
        .animation(MotionConstants.exitParam())
    )
  }

  /**
   * **显式声明不参与组件内转场**
   *
   * 两类使用场景：
   *   1. **页面级容器**（`NavDestination` 内容根）：本工程路由转场保留系统默认
   *      （`NavigationMode.Stack` 系统推入/弹出）。若再给页面根叠一层透明度转场，
   *      页面在系统滑动过程中会半透明、透出下层页面 → 观感反而更脏。交给系统独占。
   *   2. **断点分支容器**（`if (breakpointState.isTablet) 双栏 else 单栏`）：
   *      旋屏/断点切换时整块淡入会显得卡顿拖沓，不是流畅。
   *
   * 同时它也是防止「默认转场外溢」（见文件头说明第 6 点）的显式保护：
   * 一旦外层用 `animateTo` 包了状态变更，未配 `transition` 的上下树组件会被
   * 自动补一个默认透明度转场，配 `IDENTITY` 才能关掉。
   */
  static noTransition(): TransitionEffect {
    return TransitionEffect.IDENTITY
  }
}
