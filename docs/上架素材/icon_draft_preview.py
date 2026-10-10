# -*- coding: utf-8 -*-
"""
icon.svg 前景层草图 · 多尺寸预览（仅用于尺寸验证，不产出上架资产）。

合成顺序：蓝色对角渐变底（= background.svg）→ 半透白四象限十字（30%）→ 纯白势线（100%）。
输出：216 / 120 / 72 / 48 四档并排，重点看 48px 下十字是否糊成灰雾、势线是否仍可辨。

用法：python icon_draft_preview.py
"""
import os
from PIL import Image, ImageDraw

OUT_DIR = os.path.dirname(os.path.abspath(__file__))

VB = 288.0                                              # 与 icon.svg 同一坐标体系
STOPS = [(0.00, (0x4D, 0xA3, 0xFF)),
         (0.55, (0x00, 0x7D, 0xFF)),
         (1.00, (0x00, 0x4F, 0xC7))]                    # 对角渐变，同 background.svg

GRID_OPACITY = 0.30                                     # 网格：半透白 30%
GRID_WIDTH = 3.5                                        # 网格线宽（≈势线 1/10）
GRID_ARM = (50.5, 237.5)                                # 十字臂端点（落在 66% 安全区内）
GRID_MID = 144.0                                        # 十字中线（交汇于画布中心）

LINE_WIDTH = 36.0                                       # 势线线宽
PT = [(66, 206), (109, 144), (144, 182), (212, 90)]     # 三段式上扬：起手→首峰→微蓄→长段（终点内收）

SS = 4                                                  # 超采样倍数


def _lerp(a, b, t):
    return a + (b - a) * t


def _grad_color(t):
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


def build_gradient(size):
    """对角渐变 t=(x+y)/(2*size)，对齐 background.svg 的 x1y1(0,0)->x2y2(1,1)。"""
    lut = [_grad_color(i / (2.0 * size)) for i in range(2 * size)]
    buf = bytearray(size * size * 3)
    idx = 0
    for y in range(size):
        for c in lut[y:y + size]:
            buf[idx], buf[idx + 1], buf[idx + 2] = c
            idx += 3
    return Image.frombytes('RGB', (size, size), bytes(buf))


def overlay_grid(size):
    """半透白四象限十字（无外框）。"""
    k = size / VB
    lay = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(lay)
    a0, a1 = [v * k for v in GRID_ARM]
    mid = GRID_MID * k
    w = max(1, int(round(GRID_WIDTH * k)))
    a = int(round(GRID_OPACITY * 255))
    col = (255, 255, 255, a)
    d.line([a0, mid, a1, mid], fill=col, width=w)
    d.line([mid, a0, mid, a1], fill=col, width=w)
    return lay


def overlay_line(size):
    """纯白势线：圆头圆角，端点补圆。"""
    k = size / VB
    lay = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(lay)
    pts = [(x * k, y * k) for (x, y) in PT]
    w = max(1, int(round(LINE_WIDTH * k)))
    d.line(pts, fill=(255, 255, 255, 255), width=w, joint='curve')
    r = w / 2.0
    for (x, y) in pts:
        d.ellipse([x - r, y - r, x + r, y + r], fill=(255, 255, 255, 255))
    return lay


def render(size):
    big = size * SS
    base = build_gradient(big).convert('RGBA')
    base = Image.alpha_composite(base, overlay_grid(big))
    base = Image.alpha_composite(base, overlay_line(big))
    return base.resize((size, size), Image.LANCZOS)


def main():
    sizes = [216, 120, 72, 48]
    gap, pad, top = 24, 24, 24
    label_h = 22
    total_w = pad + sum(sizes) + gap * (len(sizes) - 1) + pad
    total_h = top + max(sizes) + label_h + pad
    canvas = Image.new('RGB', (total_w, total_h), (238, 241, 245))
    d = ImageDraw.Draw(canvas)
    x = pad
    for s in sizes:
        canvas.paste(render(s).convert('RGB'), (x, top))
        d.text((x, top + s + 6), f'{s}px', fill=(70, 80, 95))
        x += s + gap
    p = os.path.join(OUT_DIR, 'icon_draft_preview.png')
    canvas.save(p, 'PNG', optimize=True)
    print(p, round(os.path.getsize(p) / 1024.0, 1), 'KB')


if __name__ == '__main__':
    main()
