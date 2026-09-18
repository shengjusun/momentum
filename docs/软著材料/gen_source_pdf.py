# -*- coding: utf-8 -*-
"""
软著申请 · 源程序鉴别材料生成器

规格依据：中国版权保护中心《软件著作权登记申请所需文件》
  https://www.ccopyright.com.cn/index.php?optionid=1368
  - 源程序前、后各连续 30 页，共 60 页；整个程序不到 60 页的，提交整个源程序
  - 除特定情况外，每页不少于 50 行（结束页可少于 50 行）
  - 在每页的右上角标注连续页号 1-60
  - 申请文件应纵向排版，文字从左向右排列；不要装订

实现要点：
  - 字体用 SimSun（宋体）：中英混排不缺字，且其 ASCII 字形为半角等宽，代码列对齐不破
  - 超长行按"em 宽度"折行（半角 1、全角 2），保证任何一行都不溢出纸面
  - 折行后再按每页 50 行分页 —— "不少于 50 行"是下限，折行只会让物理行更多，永远合规

用法：python gen_source_pdf.py
改软件名/版本：只改下面 SOFT_NAME / SOFT_VERSION 两个常量后重跑。
"""
import os
import glob

from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfgen import canvas
from reportlab.lib.pagesizes import A4

# ── 申请信息（与申请表保持一致）────────────────────────────
SOFT_NAME = '起势任务管理软件'
SOFT_VERSION = 'V1.0'

# ── 排版常量 ──────────────────────────────────────────────
FONT_PATH = 'C:/Windows/Fonts/simsun.ttc'   # TTC 字体集合，index 0 = SimSun
FONT_NAME = 'SimSun'
FONT_SIZE = 9.0                             # 正文字号（pt）
HEADER_SIZE = 9.0
LINES_PER_PAGE = 50                         # 每页物理行数（官方下限）
MARGIN_X = 45.0
HEADER_Y = 40.0                             # 页眉距顶
BODY_TOP = 66.0                             # 正文起始距顶
BODY_BOTTOM = 50.0                          # 正文下边界
WRAP_LIMIT = 108                            # 单行最大宽度（em 单位；A4 可用宽 505pt ÷ 9pt ≈ 112）

# 是否剔除空行（必须为 True）
# 官方口径"每页不少于 50 行"审查看的是**有效代码行**：若保留空行，一页 50 个物理行里
# 可能只有 40 多行是代码，会被要求补正。剔除空行后每页恰好 50 行代码，永远合规。
DROP_BLANK = True

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
SRC_DIR = os.path.join(ROOT, 'entry', 'src', 'main', 'ets')
OUT_PDF = os.path.join(HERE, '%s%s-源程序.pdf' % (SOFT_NAME, SOFT_VERSION))

# 源码拼接顺序：入口 → 页面 → 视图模型 → 模型 → 组件/服务/工具
PRIORITY = ['entryability', 'pages', 'viewmodel', 'model', 'widget', 'common', 'entrybackupability']


def sort_key(path):
    rel = os.path.relpath(path, SRC_DIR).replace('\\', '/')
    top = rel.split('/')[0]
    idx = PRIORITY.index(top) if top in PRIORITY else len(PRIORITY)
    return (idx, rel)


def disp_width(s):
    """显示宽度，单位 em：半角 1，全角 2"""
    return sum(1 if ord(ch) < 128 else 2 for ch in s)


def wrap_line(line, limit=WRAP_LIMIT):
    """按 em 宽度折行；尽量在空格处断开，避免把标识符切得太难看"""
    if disp_width(line) <= limit:
        return [line]
    out = []
    rest = line
    while disp_width(rest) > limit:
        acc = 0
        cut = 0
        for i, ch in enumerate(rest):
            acc += 1 if ord(ch) < 128 else 2
            if acc > limit:
                break
            cut = i + 1
        if cut == 0:
            cut = 1
        sp = rest.rfind(' ', max(0, cut - 24), cut)
        if sp > 0:
            cut = sp
        out.append(rest[:cut])
        rest = rest[cut:].lstrip(' ')
    out.append(rest)
    return out


def collect_lines():
    files = sorted(glob.glob(os.path.join(SRC_DIR, '**', '*.ets'), recursive=True), key=sort_key)
    lines = []
    for f in files:
        try:
            txt = open(f, encoding='utf-8-sig').read()
        except UnicodeDecodeError:
            txt = open(f, encoding='utf-8', errors='ignore').read()
        for ln in txt.split('\n'):
            s = ln.replace('\t', '    ').rstrip('\r')
            if DROP_BLANK and s.strip() == '':
                continue
            lines.append(s)
    return files, lines


def main():
    if not os.path.exists(FONT_PATH):
        raise SystemExit('缺少中文字体：%s' % FONT_PATH)
    pdfmetrics.registerFont(TTFont(FONT_NAME, FONT_PATH, subfontIndex=0))

    files, raw = collect_lines()
    print('源文件数 = %d，原始行数 = %d' % (len(files), len(raw)))

    # 折行 → 物理行
    phys = []
    for ln in raw:
        if ln.strip() == '':
            phys.append('')
        else:
            phys.extend(wrap_line(ln))
    print('折行后物理行数 = %d' % len(phys))

    # 每页 50 物理行
    pages = [phys[i:i + LINES_PER_PAGE] for i in range(0, len(phys), LINES_PER_PAGE)]
    print('排版总页数 = %d' % len(pages))

    # 前 30 页 + 后 30 页（不足 60 页则全部提交）
    if len(pages) <= 60:
        selected = pages
        mode = '全部提交（不足 60 页）'
    else:
        selected = pages[:30] + pages[-30:]
        mode = '前 30 页 + 后 30 页'
    print('提交策略：%s，最终 %d 页' % (mode, len(selected)))

    c = canvas.Canvas(OUT_PDF, pagesize=A4)
    page_w, page_h = A4
    usable_h = page_h - BODY_TOP - BODY_BOTTOM
    line_h = usable_h / LINES_PER_PAGE
    print('行距 = %.2fpt，每页正文可用高 = %.1fpt' % (line_h, usable_h))

    total = len(selected)
    for idx, page_lines in enumerate(selected):
        # 页眉：左软件名+版本，右连续页码
        c.setFont(FONT_NAME, HEADER_SIZE)
        c.drawString(MARGIN_X, page_h - HEADER_Y, '%s %s' % (SOFT_NAME, SOFT_VERSION))
        c.drawRightString(page_w - MARGIN_X, page_h - HEADER_Y, '第 %d 页' % (idx + 1))
        c.setLineWidth(0.4)
        c.line(MARGIN_X, page_h - HEADER_Y - 8, page_w - MARGIN_X, page_h - HEADER_Y - 8)

        # 正文
        c.setFont(FONT_NAME, FONT_SIZE)
        y = page_h - BODY_TOP
        for ln in page_lines:
            if ln:
                c.drawString(MARGIN_X, y, ln)
            y -= line_h

        c.showPage()

    c.save()
    size_kb = os.path.getsize(OUT_PDF) / 1024.0
    print('已生成：%s  (%.0f KB, %d 页)' % (OUT_PDF, size_kb, total))
    print('每页行数 = %d（官方要求不少于 50）' % LINES_PER_PAGE)


if __name__ == '__main__':
    main()
