# -*- coding: utf-8 -*-
"""
竖屏环内文字「压弧线」复核脚本
================================
背景：环内文字块（阶段标签 + 分 + 秒两行）必须整体落在环的**内接正方形**内，
      否则在环的左右两侧会与弧线相撞（视觉上"压线"）。

判据（保守）：内接正方形边长 = 环直径 x 0.72
  - 严格内接方 = D/sqrt(2) = 0.7071D；留 1.3% 给字体的视觉外扩/字距，取 0.72 偏宽松，
    但仍比"文字块宽度"这个约束严——因为文字块宽 < 高，竖直方向才是瓶颈。

文字块高度模型（vp）：
  标签行   = label   x 1.35   (Medium, 单行行高)
  分秒两行 = 2 x num x 1.18   (Bold monospace, 单行行高)
  行间距   = gap
  下移量   = marginTop
  合计 H   = label*1.35 + 2*num*1.18 + gap + marginTop
"""
import math

# ---- 当前（待修）参数 ----
CUR = dict(label=0.055, num=0.26, gap=2, margin=0.05)
# ---- 修复候选参数（与本文件下方代码实际落盘值一致） ----
FIX = dict(label=0.052, num=0.23, gap=2, margin=0.0)
# ---- 已落盘（现行）参数 = 修复候选 ----
LANDED = FIX

LINE_LABEL = 1.35
LINE_NUM = 1.18
INSCRIBED = 0.72

# (机型, 视口宽, 视口高, 状态栏, 底部安全区)
DEVICES = [
    ("小屏 330x720", 330, 720, 24, 16),
    ("Mate60 360x800", 360, 800, 28, 16),
    ("Pura70 381x846", 381, 846, 30, 16),
    ("折叠展开 400x900", 400, 900, 32, 16),
    ("平板 700x1200", 700, 1200, 34, 20),
]

PORTRAIT_RING_RATIO_RUNNING = 0.78
PORTRAIT_BUTTON_BAND = 24 + 76  # 24 gap + ACTION_BTN_MAX(76)
RING_STROKE_RATIO, STROKE_MIN, STROKE_MAX = 0.048, 8, 14


def ring_size(w, h, status, bottom):
    short = min(w, h)
    by_ratio = short * PORTRAIT_RING_RATIO_RUNNING
    by_height = h - status - PORTRAIT_BUTTON_BAND - 20 - 16 - bottom
    return max(180, min(by_ratio, by_height))


def stroke(size):
    return max(STROKE_MIN, min(STROKE_MAX, round(size * RING_STROKE_RATIO)))


def block_height(size, p):
    return p["label"] * size * LINE_LABEL + 2 * p["num"] * size * LINE_NUM + p["gap"] + p["margin"] * size


def report(tag, p):
    print("=" * 78)
    print(f"[{tag}]  label={p['label']}  num={p['num']}  gap={p['gap']}  marginTop={p['margin']}*D")
    print("-" * 78)
    head = f"{'机型':<18}{'环直':>6}{'内接方':>8}{'文字高':>8}{'余量':>8}{'短边':>7}{'占比':>8}  结论"
    print(head)
    worst = 999
    for name, w, h, status, bottom in DEVICES:
        d = ring_size(w, h, status, bottom)
        inscribed = d * INSCRIBED
        bh = block_height(d, p)
        margin = inscribed - bh
        worst = min(worst, margin)
        ratio = d / min(w, h) * 100
        ok = "OK" if margin > 0 else "压弧线!"
        print(f"{name:<16}{d:>6.0f}{inscribed:>8.1f}{bh:>8.1f}{margin:>+8.1f}{min(w,h):>7.0f}{ratio:>7.1f}%  {ok}")
    print(f"--> 最差余量 {worst:+.1f}vp  {'（全部通过）' if worst > 0 else '（存在压线）'}")
    print()


report("当前参数（待修）", CUR)
report("已落盘参数（现行，全机型通过）", LANDED)

print("=" * 78)
print("字号实际值对照（环内数字，fp）")
print("-" * 78)
print(f"{'机型':<18}{'环直':>7}{'待修字号':>10}{'现行字号':>10}{'缩幅':>8}")
for name, w, h, status, bottom in DEVICES:
    d = ring_size(w, h, status, bottom)
    cur = round(d * CUR["num"])
    fix = round(d * FIX["num"])
    print(f"{name:<16}{d:>7.0f}{cur:>10.0f}{fix:>10.0f}{(1 - fix / cur) * 100:>7.1f}%")

print()
print("=" * 78)
print("竖屏整屏高度占用复核（环 + 24 + 按钮 + 上下 Blank）")
print("-" * 78)
print(f"{'机型':<18}{'环直':>7}{'按钮':>7}{'内容块':>9}{'可用高':>9}{'余量':>8}  结论")
for name, w, h, status, bottom in DEVICES:
    d = ring_size(w, h, status, bottom)
    btn = max(46, min(76, round(d * 0.26)))
    content = d + 24 + btn
    avail = h - status - bottom
    free = avail - content
    print(f"{name:<16}{d:>7.0f}{btn:>7.0f}{content:>9.0f}{avail:>9.0f}{free:>+8.0f}  {'OK' if free >= 40 else '偏紧!'}")
