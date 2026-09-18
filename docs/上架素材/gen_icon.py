# -*- coding: utf-8 -*-
"""
生成应用市场图标（AGC 版本信息用）——与分层图标前景层 v2 保持同形。

- 底：蓝色对角渐变 (#4DA3FF -> #007DFF -> #004FC7)
- 辅助层：2×2 四象限十字（半透白 30%，正交，无外框），线宽 ≈ 势线 1/10
- 主层：三段式上扬势线「起手 → 首峰 → 微蓄 → 长段上扬」，纯白、圆头圆角
  末段最长且收于最高点；终点内收，右上留呼吸
- 输出：正方形、满幅（无内边距、无自带圆角），216x216 与 1024x1024
- 另出一版自带圆角（供应用内/桌面预览或平台要求圆角时使用）

用法：python gen_icon.py
"""
import os
from PIL import Image, ImageDraw

OUT_DIR = os.path.dirname(os.path.abspath(__file__))

VB = 120.0                                              # SVG viewBox 边长
STOPS = [(0.00, (0x4D, 0xA3, 0xFF)),
         (0.55, (0x00, 0x7D, 0xFF)),
         (1.00, (0x00, 0x4F, 0xC7))]                    # 对角渐变三站
# 三段式上扬线：起手 (27.5,85.8) -> 首峰 (45.4,60) -> 微蓄 (60,75.8) -> 长段 (88.3,37.5)
# 判据：① 峰谷间距 > 线宽 + 视觉余量，避免多峰在小尺寸下糊成一团；
#       ② 末段为最长且收于最高点，读作"势"而不是字母；
#       ③ 终点内收，右上留出呼吸，避免撞 66% 安全区右沿。
PT = [(27.5, 85.8), (45.4, 60.0), (60.0, 75.8), (88.3, 37.5)]
STROKE = 15.0                                           # 势线线宽
GRID_ARM = (21.0, 99.0)                                 # 十字臂端点（66% 安全区内）
GRID_MID = 60.0                                         # 十字中线（画布中心）
GRID_WIDTH = 1.46                                       # 十字线宽 ≈ 势线 1/10
GRID_OPACITY = 0.30                                     # 十字：半透白 30%
RADIUS = 28.0                                           # 圆角半径（圆角版）
PAD = 2.0                                               # 圆角版内边距
SS = 4                                                  # 超采样倍数（画线抗锯齿）


def _lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def _grad_color(t: float):
    t = 0.0 if t < 0.0 else (1.0 if t > 1.0 else t)
    for i in range(len(STOPS) - 1):
        t0, c0 = STOPS[i]
        t1, c1 = STOPS[i + 1]
        if t <= t1:
            k = 0.0 if t1 == t0 else (t - t0) / (t1 - t0)
            return (int(round(_lerp(c0[0], c1[0], k))),
                    int(round(_lerp(c0[1], c1[1], k))),
                    int(round(_lerp(c0[2], c1[2], k))))
    return STOPS[-1][1]


def build_gradient(size: int) -> Image.Image:
    """SVG 渐变 x1,y1=(0,0) -> x2,y2=(1,1)（objectBoundingBox）=> t=(x+y)/(2*size)"""
    lut = [_grad_color(i / (2.0 * size)) for i in range(2 * size)]
    buf = bytearray(size * size * 3)
    idx = 0
    for y in range(size):
        base = y
        row = lut[base:base + size]
        for c in row:
            buf[idx] = c[0]
            buf[idx + 1] = c[1]
            buf[idx + 2] = c[2]
            idx += 3
    return Image.frombytes('RGB', (size, size), bytes(buf))


def build_sheen(size: int) -> Image.Image:
    """右上角高光：M96 34V6h24v28z，白色 0.45->0 的竖向渐变，整体 opacity 0.7。

    满幅正方形下对左边缘做羽化，读起来像角落的柔光。
    """
    k = size / VB
    lay = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    px = lay.load()
    x0, x1 = int(round(96 * k)), min(size, int(round(120 * k)))
    y0, y1 = int(round(6 * k)), min(size, int(round(34 * k)))
    span_y = max(1, y1 - y0 - 1)
    span_x = max(1, int(round(26 * k)))          # 左侧羽化宽度（SVG 单位 26）
    for y in range(y0, y1):
        fy = 1.0 - (y - y0) / span_y
        for x in range(x0, x1):
            fx = min(1.0, (x - x0) / span_x)
            a = int(round(fy * fx * 0.45 * 0.7 * 255.0))
            px[x, y] = (255, 255, 255, a)
    return lay


def draw_grid(size: int) -> Image.Image:
    """半透白四象限十字（无外框）：水平 + 垂直中线。"""
    k = size / VB
    lay = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(lay)
    a0, a1 = GRID_ARM[0] * k, GRID_ARM[1] * k
    mid = GRID_MID * k
    w = max(1, int(round(GRID_WIDTH * k)))
    a = int(round(GRID_OPACITY * 255))
    col = (255, 255, 255, a)
    d.line([a0, mid, a1, mid], fill=col, width=w)
    d.line([mid, a0, mid, a1], fill=col, width=w)
    return lay


def draw_m(size: int) -> Image.Image:
    """白色上扬势线：圆头圆角，超采样后由上层缩回"""
    k = size / VB
    w = max(1, int(round(STROKE * k)))
    lay = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(lay)
    pts = [(x * k, y * k) for (x, y) in PT]
    d.line(pts, fill=(255, 255, 255, 255), width=w, joint='curve')
    r = w / 2.0
    for (x, y) in pts:                       # 圆头端点
        d.ellipse([x - r, y - r, x + r, y + r], fill=(255, 255, 255, 255))
    return lay


def rounded_mask(size: int) -> Image.Image:
    k = size / VB
    m = Image.new('L', (size, size), 0)
    d = ImageDraw.Draw(m)
    p = PAD * k
    d.rounded_rectangle([p, p, size - p, size - p], radius=RADIUS * k, fill=255)
    return m


def main() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)

    # 1) 满幅正方形：渐变铺满 + 高光 + 四象限十字 + 势线（4x 超采样后缩回）
    base = build_gradient(1024)
    big = base.resize((1024 * SS, 1024 * SS), Image.LANCZOS).convert('RGBA')
    sheen = build_sheen(1024).resize((1024 * SS, 1024 * SS), Image.LANCZOS)
    big = Image.alpha_composite(big, sheen)
    big = Image.alpha_composite(big, draw_grid(1024 * SS))
    big = Image.alpha_composite(big, draw_m(1024 * SS))
    square = big.resize((1024, 1024), Image.LANCZOS)

    square.convert('RGB').save(os.path.join(OUT_DIR, 'app_icon_1024.png'), 'PNG', optimize=True)
    square.convert('RGB').resize((216, 216), Image.LANCZOS)\
        .save(os.path.join(OUT_DIR, 'app_icon_216.png'), 'PNG', optimize=True)

    # 2) WEBP 版（规范上限 100KB）
    for q in (95, 90, 85, 80, 75, 70, 60):
        p = os.path.join(OUT_DIR, 'app_icon_216.webp')
        square.convert('RGB').resize((216, 216), Image.LANCZOS).save(p, 'WEBP', quality=q)
        if os.path.getsize(p) <= 100 * 1024:
            print('webp quality =', q)
            break

    # 3) 自带圆角版（保留 2/120 内边距 + 28/120 圆角）
    rg = square.copy()
    rg.putalpha(rounded_mask(1024))
    rg.resize((216, 216), Image.LANCZOS)\
        .save(os.path.join(OUT_DIR, 'app_icon_216_rounded.png'), 'PNG', optimize=True)

    for f in sorted(os.listdir(OUT_DIR)):
        if f.endswith(('.png', '.webp')):
            print(f, round(os.path.getsize(os.path.join(OUT_DIR, f)) / 1024.0, 1), 'KB')


if __name__ == '__main__':
    main()
