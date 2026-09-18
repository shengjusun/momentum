/**
 * @file ConfettiOverlay - 目标达成全屏撒花（Canvas 粒子，零第三方依赖）
 * @description
 *   目标 progress 首次达 100 时的全屏庆祝层：
 *   - 粒子从画布顶部错落落下，重力加速 + 水平摆动 + 自旋转，三种形状（矩形/圆/竖条）
 *   - 总时长 1800ms，末 400ms 整层淡出，播完回调 onFinished（调用方收起覆盖层）
 *   - **不拦截任何交互**：外层 hitTestBehavior(None)，撒花期间用户可继续操作
 *   - 动画由 setInterval 驱动 Canvas 重绘，不依赖 .transition / .animation
 *     （规避"transition 对 if 插入无效 / 裸 TransitionEffect 无动效"两条铁律）
 *   - 调用方经 bindContentCover 承载（系统全屏模态 API），isShow 用 $$ 双向绑定
 *
 *   纪律：只由 GOAL_COMPLETED 事件驱动（用户本机动作链），云同步落地不触发。
 *
 * @module common/components
 * @date 2026-09-17
 */

import { Logger } from '../utils/Logger'

const TAG: string = 'ConfettiOverlay'

/** 粒子总时长（毫秒） */
const CONFETTI_DURATION_MS: number = 1800
/** 末段淡出时长（毫秒） */
const CONFETTI_FADE_MS: number = 400
/** 帧间隔（毫秒） */
const CONFETTI_FRAME_MS: number = 16
/** 粒子数量 */
const CONFETTI_COUNT: number = 80

/** 明亮调色板（撒花要亮眼，深浅色主题下都用同一组高饱和色） */
const CONFETTI_COLORS: string[] =
  ['#F5564E', '#F7BA1E', '#41CC45', '#3D93FD', '#B37FEB', '#FF7EB3']

/** 单个粒子状态 */
interface ConfettiParticle {
  x: number
  y: number
  /** 水平速度 */
  vx: number
  /** 垂直速度（重力持续加速，封顶见 tick） */
  vy: number
  /** 边长/直径（px） */
  size: number
  /** 填充色 */
  color: string
  /** 旋转角（弧度） */
  rot: number
  /** 每帧旋转增量（弧度） */
  rotSpeed: number
  /** 水平摆动相位 */
  swayPhase: number
  /** 水平摆动速度 */
  swaySpeed: number
  /** 形状：0 矩形 / 1 圆 / 2 竖条 */
  shape: number
}

/** 工厂：构造粒子（满足 ArkTS 对象字面量显式类型约束） */
function buildParticle(x: number, y: number, vx: number, vy: number, size: number,
  color: string, rot: number, rotSpeed: number,
  swayPhase: number, swaySpeed: number, shape: number): ConfettiParticle {
  const p: ConfettiParticle = {
    x: x, y: y, vx: vx, vy: vy, size: size, color: color,
    rot: rot, rotSpeed: rotSpeed, swayPhase: swayPhase,
    swaySpeed: swaySpeed, shape: shape
  }
  return p
}

@ComponentV2
export struct ConfettiOverlay {
  /** 显示开关：true 启动播撒，false 静默停止（不回调 onFinished） */
  @Param @Require show: boolean = false
  /** 播完回调（自然结束时触发；调用方应收起覆盖层） */
  @Event onFinished: () => void = (): void => {}

  private settings: RenderingContextSettings = new RenderingContextSettings(true)
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings)
  /** 画布尺寸（onReady 时记录，px） */
  private canvasW: number = 0
  private canvasH: number = 0
  private particles: ConfettiParticle[] = []
  private timerId: number = -1
  private elapsedMs: number = 0

  aboutToDisappear(): void {
    // 页面销毁时静默清理，不触发 onFinished
    this.stopAnimation()
  }

  /** show 变化：true → 启动；false → 静默停止（外部提前收起） */
  @Monitor('show')
  onShowChange(): void {
    if (this.show) {
      this.startAnimation()
    } else {
      this.stopAnimation()
    }
  }

  /** Canvas 就绪：若挂载时 show 已为 true（首帧即播场景），在此补启动 */
  private handleCanvasReady(w: number, h: number): void {
    this.canvasW = w
    this.canvasH = h
    if (this.show && this.timerId === -1) {
      this.startAnimation()
    }
  }

  /** 启动播撒（防重入：已运行则忽略） */
  private startAnimation(): void {
    if (this.timerId !== -1) return
    if (this.canvasW <= 0 || this.canvasH <= 0) return
    this.elapsedMs = 0
    this.spawnParticles()
    this.timerId = setInterval((): void => {
      this.tick()
    }, CONFETTI_FRAME_MS)
    Logger.info(TAG, 'startAnimation: particles=' + this.particles.length.toString())
  }

  /** 静默停止：清定时器与画布，不回调 onFinished */
  private stopAnimation(): void {
    if (this.timerId !== -1) {
      clearInterval(this.timerId)
      this.timerId = -1
    }
    this.particles = []
    if (this.canvasW > 0) {
      this.context.clearRect(0, 0, this.canvasW, this.canvasH)
    }
  }

  /** 生成粒子：顶部落下，x 全宽错落，y 略负制造先后感 */
  private spawnParticles(): void {
    this.particles = []
    for (let i: number = 0; i < CONFETTI_COUNT; i++) {
      const color: string = CONFETTI_COLORS[i % CONFETTI_COLORS.length]
      const p: ConfettiParticle = buildParticle(
        Math.random() * this.canvasW,
        -20 - Math.random() * 120,
        -1.2 + Math.random() * 2.4,
        2 + Math.random() * 3,
        5 + Math.random() * 6,
        color,
        Math.random() * Math.PI * 2,
        (Math.random() - 0.5) * 0.4,
        Math.random() * Math.PI * 2,
        0.05 + Math.random() * 0.1,
        i % 3
      )
      this.particles.push(p)
    }
  }

  /** 单帧：推进物理 + 重绘；到时淡出收尾 */
  private tick(): void {
    this.elapsedMs += CONFETTI_FRAME_MS
    if (this.elapsedMs >= CONFETTI_DURATION_MS) {
      this.stopAnimation()
      Logger.info(TAG, 'finished')
      this.onFinished()
      return
    }
    const ctx: CanvasRenderingContext2D = this.context
    ctx.clearRect(0, 0, this.canvasW, this.canvasH)
    // 末段整层淡出
    const remain: number = CONFETTI_DURATION_MS - this.elapsedMs
    ctx.globalAlpha = remain < CONFETTI_FADE_MS ? remain / CONFETTI_FADE_MS : 1
    for (let i: number = 0; i < this.particles.length; i++) {
      const p: ConfettiParticle = this.particles[i]
      // 重力加速（封顶防穿屏过快）+ 水平摆动
      p.vy = Math.min(p.vy + 0.12, 7)
      p.swayPhase += p.swaySpeed
      p.x += p.vx + Math.sin(p.swayPhase) * 1.2
      p.y += p.vy
      p.rot += p.rotSpeed
      if (p.y > this.canvasH + 24) {
        continue
      }
      ctx.save()
      ctx.translate(p.x, p.y)
      ctx.rotate(p.rot)
      ctx.fillStyle = p.color
      if (p.shape === 0) {
        // 矩形纸片
        ctx.fillRect(-p.size / 2, -p.size / 3, p.size, p.size / 1.5)
      } else if (p.shape === 1) {
        // 圆点
        ctx.beginPath()
        ctx.arc(0, 0, p.size / 2, 0, Math.PI * 2)
        ctx.fill()
      } else {
        // 竖条（旋转后近似纸屑翻滚）
        ctx.fillRect(-p.size / 6, -p.size / 2, p.size / 3, p.size)
      }
      ctx.restore()
    }
    ctx.globalAlpha = 1
  }

  build(): void {
    Stack() {
      Canvas(this.context)
        .width('100%')
        .height('100%')
        .onReady((): void => {
          // onReady 拿到的是组件布局尺寸（vp 单位由画布体系内部换算），直接使用
          this.handleCanvasReady(this.context.width, this.context.height)
        })
    }
    .width('100%')
    .height('100%')
    // 撒花层纯观赏：不拦截点击/滑动，用户可继续操作页面
    .hitTestBehavior(HitTestMode.None)
  }
}
