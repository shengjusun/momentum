# -*- coding: utf-8 -*-
"""
v4 版式尺寸推演（对齐图片稿「番茄钟UI设计咨询 (2).png」+ 用户 2026-09-15 的口径）

用户口径（v4 与 v3 的差别）：
- 横屏**恢复底部按钮**（时间倒计下方一枚「暂停 / 继续」胶囊），它才是自动淡出的对象
- 两个圆**都是纯显示**（不可点击）→ 圆不再承担命中区职责

图片稿要点：
- 横屏 = 左右两个大圆：左=分（细描边**无进度弧**），右=秒（**有进度弧**）
- 数字极大：图上「24」字高 ≈ 圆径 0.50，两字宽 ≈ 圆径 0.85
- 中间一根竖线；底部按钮

本脚本复核：
A. 横屏「双圆 + 底部胶囊」在参考机型上横向/纵向是否放得下，按钮是否 ≥ 可点尺寸
B. 竖屏字号放大后，环内文字是否仍落在内接正方形内（不压弧线）
"""

# ---- 参考机型（短边 = min(宽, 高)） ----
DEVICES = [
    ('小屏 330x720', 330, 720),
    ('Pura70 360x800', 360, 800),
    ('折叠展开 381x900', 381, 900),
    ('Mate 400x920', 400, 920),
    ('平板 700x1200', 700, 1200),
]

# ---- 代码中的常量（必须与 PomodoroImmersiveScreen.ets 一致） ----
LANDSCAPE_DUAL_RATIO = 0.92
LANDSCAPE_DUAL_GAP_MIN = 14
LANDSCAPE_DUAL_SIDE_PAD = 22
LANDSCAPE_DUAL_INNER_PAD = 30
LANDSCAPE_RING_MARGIN = 10

LSA_W_RATIO, LSA_W_MIN, LSA_W_MAX = 0.34, 132, 210
LSA_H_RATIO, LSA_H_MIN, LSA_H_MAX = 0.105, 46, 66
LSA_GAP = 14
LANDSCAPE_BUTTON_BAND = LSA_GAP + LSA_H_MAX  # = 80

LANDSCAPE_TIME_RATIO = 0.44
LANDSCAPE_THIN_STROKE = 1.5
RING_STROKE_RATIO, RING_STROKE_MIN, RING_STROKE_MAX = 0.048, 8, 14
LANDSCAPE_DIVIDER_RATIO = 0.42
MIN_TOUCH = 48          # 可点尺寸下限（vp）
STATUS_BAR = 36         # 推演用状态栏高度（真机由 safeAreaHelper.statusBar 提供）

INSCRIBED = 0.7071
SAFE = 0.98

# 内接正方形：字符排版 / 字宽经验值（与 v3 脚本同源）
LINE_BOX = 1.18         # 行盒高 / 字号
CHAR_RATIO = 0.6        # monospace 字宽 / 字号（0.5em~0.6em 取保守值）


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


def portrait_ring(short, status=STATUS_BAR, bottom=24):
    by_ratio = short * 0.78
    by_height = (short * 2.1) - status - (24 + 76) - 20 - 16 - bottom
    return round(max(180, min(by_ratio, by_height)))


def text_block_height(ring, label, num, gap, line_ratio=LINE_BOX):
    return ring * label * line_ratio + ring * num * line_ratio * 2 + gap


def report_text_fit(tag, label, num, gap):
    print('=' * 78)
    print('[%s]  标签=%.3f 数字=%.3f 行距=%d' % (tag, label, num, gap))
    print('%-20s %7s %10s %10s %9s %s' % ('机型', '环直', '内容高', '内接方', '余量', '结论'))
    worst = 999
    for name, w, h in DEVICES:
        short = min(w, h)
        ring = portrait_ring(short)
        content = text_block_height(ring, label, num, gap)
        limit = ring * INSCRIBED * SAFE
        margin = limit - content
        worst = min(worst, margin)
        print('%-20s %7d %10.1f %10.1f %9.1f %s'
              % (name, ring, content, limit, margin, 'OK' if margin > 0 else '压弧线!'))
    print('最差余量: %.1f vp  ->  %s' % (worst, 'PASS' if worst > 0 else 'FAIL'))
    return worst


# ============ A. 横屏「双圆 + 底部胶囊」 ============
print('#' * 78)
print('# A. 横屏 v4：双圆（纯显示）在上，暂停/继续胶囊在下')
print('#' * 78)
print('%-18s %7s %7s %7s %8s %8s %8s %8s %s'
      % ('机型(横屏视口)', '长边', '短边', '圆径', '纵向余', '横两圆', '按钮W', '按钮H', '结论'))
all_ok = True
for name, w, h in DEVICES:
    lw, lh = max(w, h), min(w, h)          # 横屏视口：宽 = 长边，高 = 短边
    short = lh
    gap = max(LANDSCAPE_DUAL_GAP_MIN, round(short * 0.05))
    by_w = (lw - LANDSCAPE_DUAL_SIDE_PAD - LANDSCAPE_DUAL_INNER_PAD - gap * 2 - 1) / 2
    by_h = short - STATUS_BAR - LANDSCAPE_RING_MARGIN - LANDSCAPE_BUTTON_BAND
    d = round(max(90, min(by_w, by_h) * LANDSCAPE_DUAL_RATIO))

    # 纵向实测余量：视口高 − 状态栏 − (圆 + 按钮间距 + 按钮实际高) − 余量
    btn_h = round(clamp(short * LSA_H_RATIO, LSA_H_MIN, LSA_H_MAX))
    btn_w = round(clamp(short * LSA_W_RATIO, LSA_W_MIN, LSA_W_MAX))
    used_h = d + LSA_GAP + btn_h
    avail_h = short - STATUS_BAR - LANDSCAPE_RING_MARGIN
    free_h = avail_h - used_h

    # 横向实测：两圆 + 两 gap + 竖线
    row_w = d * 2 + gap * 2 + 1
    free_w = lw - row_w

    # 数字是否落在圆内（字高 + 两字宽）
    num_h = d * LANDSCAPE_TIME_RATIO * LINE_BOX
    num_w = d * LANDSCAPE_TIME_RATIO * CHAR_RATIO * 2
    num_ok = (num_h <= d * 0.85) and (num_w <= d * 0.95)
    btn_ok = btn_h >= MIN_TOUCH - 2 and btn_w >= MIN_TOUCH
    ok = (free_h >= 0) and (free_w >= 0) and num_ok and btn_ok
    all_ok = all_ok and ok
    print('%-18s %7d %7d %7d %8.1f %8.1f %8d %8d %s'
          % (name, lw, lh, d, free_h, free_w, btn_w, btn_h,
             'OK' if ok else ('溢出/过小!' if not (free_h >= 0 and free_w >= 0 and btn_ok)
                              else '数字溢出圆!')))

print()
print('%-18s %8s %8s %9s %9s %s'
      % ('机型', '话质高', '字面宽', '占径(高)', '占径(宽)', '数字在内?'))
for name, w, h in DEVICES:
    lw, lh = max(w, h), min(w, h)
    short = lh
    gap = max(LANDSCAPE_DUAL_GAP_MIN, round(short * 0.05))
    by_w = (lw - LANDSCAPE_DUAL_SIDE_PAD - LANDSCAPE_DUAL_INNER_PAD - gap * 2 - 1) / 2
    by_h = short - STATUS_BAR - LANDSCAPE_RING_MARGIN - LANDSCAPE_BUTTON_BAND
    d = round(max(90, min(by_w, by_h) * LANDSCAPE_DUAL_RATIO))
    num_h = d * LANDSCAPE_TIME_RATIO * LINE_BOX
    num_w = d * LANDSCAPE_TIME_RATIO * CHAR_RATIO * 2
    print('%-18s %8.1f %8.1f %8.0f%% %8.0f%% %s'
          % (name, num_h, num_w, num_h / d * 100, num_w / d * 100,
             'YES' if (num_h <= d * 0.85 and num_w <= d * 0.95) else 'NO(溢出圆)'))
print()
print('A 段总结论: %s' % ('PASS' if all_ok else 'FAIL'))

# ============ B. 竖屏字号放大复核 ============
print()
print('#' * 78)
print('# B. 竖屏环内文字（放大后必须仍不压弧线）')
print('#' * 78)
report_text_fit('v3 现行 0.26（已交付）', 0.050, 0.26, 2)
print()
report_text_fit('候选 0.28（+8%）', 0.048, 0.28, 2)
print()
report_text_fit('候选 0.30（+15%）', 0.046, 0.30, 0)

print()
print('#' * 78)
print('# v4 尺寸推演完成')
print('#' * 78)
