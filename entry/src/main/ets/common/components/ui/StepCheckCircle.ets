/**
 * @file StepCheckCircle —— 步骤勾选圆（自绘，替代系统 Checkbox）
 *
 * @description
 *   - 未完成：描边圆（`text_tertiary`，1.5vp）
 *   - 完成：实心主色圆 + 白对勾，对勾以 `scale 0→1` + 弹簧**"打进去"**（轻反馈）
 *
 *   2026-10-10 从 TaskDetailPage 内部抽出：目标详情页展开后的步骤行要改成同一控件，
 *   若各写一份必然漂移 ⇒ 收敛为单一来源。
 *
 * ⚠️ 本组件**只负责视觉**，不接管点击：
 *    热区（44×44）、`HitTestMode.Block`、`accessibilityText` 一律由调用方在外面套一层处理。
 *    原因见 TaskDetailPage 原注释：系统 Checkbox 自身收不到触摸（`HitTestMode.Block`
 *    会「阻塞子节点 + 祖先节点」的触摸测试），故本工程统一自绘 + 外层容器接 onClick。
 *
 * ⚠️ 对勾**常驻渲染**、用 `scale` 补间：`if (completed)` 插入的组件属"更换树"，
 *    属性动画对它无效（没有属性在补间）。
 *
 * ⚠️ **@Param 取名绝不能与 ArkUI 通用属性方法同名**（如 `size` / `width` / `height` /
 *    `id` / `key` …）：V2 组件的基类是 `CustomComponent`（含全部通用属性方法），
 *    撞名会直接编译报错 `10505001 Property 'X' is not assignable to the same property
 *    in base type 'CustomComponent'`。本字段原名 `size` 正是踩了这个坑（已改 `diameter`）。
 *
 * @module common/components/ui
 */

import { MotionConstants } from '../../constants/MotionConstants'

@ComponentV2
export struct StepCheckCircle {
  /** 是否已完成 */
  @Param completed: boolean = false
  /** 圆直径（vp），默认 24。⚠️ 勿改名为 `size`（与通用属性方法撞名，编译报错） */
  @Param diameter: number = 24

  /** 对勾字号：跟随圆尺寸（24 → 14） */
  private checkFontSize(): number {
    return Math.round(this.diameter * 0.58)
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Circle({ width: this.diameter, height: this.diameter })
        .fill(this.completed ? $r('app.color.primary_color') : Color.Transparent)
        .stroke(this.completed ? $r('app.color.primary_color') : $r('app.color.text_tertiary'))
        .strokeWidth(1.5)
        .animation(MotionConstants.pressParam())

      SymbolGlyph($r('sys.symbol.checkmark'))
        .fontSize(this.checkFontSize())
        .fontWeight(FontWeight.Bold)
        .fontColor([$r('app.color.text_inverse')])
        .scale({ x: this.completed ? 1 : 0, y: this.completed ? 1 : 0 })
        .animation(this.completed ? MotionConstants.springParam(0.26, 0.62) : MotionConstants.pressParam())
    }
    .width(this.diameter)
    .height(this.diameter)
  }
}
