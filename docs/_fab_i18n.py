# -*- coding: utf-8 -*-
"""悬浮按钮 / 添加待办 / 筛选空态：三语言新增文案 key。

追加到 string.json 的 string 数组末尾（按行文本插入 + JSON 合法性校验），
注意把"原最后一项补逗号、新最后一项去逗号"，否则数组尾部会出尾逗号。
"""
import io
import json
import os

ROOT = r'D:\harmony\Project\s\Application'
RES = os.path.join(ROOT, 'entry', 'src', 'main', 'resources')
LOG = os.path.join(ROOT, '.workbuddy', '_fab_i18n_log.txt')

NEW = {
    'settings_fab_title': {
        'base': '悬浮快捷按钮',
        'zh_CN': '悬浮快捷按钮',
        'en_US': 'Floating action button',
    },
    'settings_fab_desc': {
        'base': '首页与路线页右下角的添加按钮；长按可隐藏，在此重新开启',
        'zh_CN': '首页与路线页右下角的添加按钮；长按可隐藏，在此重新开启',
        'en_US': 'The add button on Home and Route. Long-press to hide; re-enable here',
    },
    'toast_fab_hidden': {
        'base': '已隐藏，可在「设置 → 悬浮快捷按钮」中重新开启',
        'zh_CN': '已隐藏，可在「设置 → 悬浮快捷按钮」中重新开启',
        'en_US': 'Hidden. Re-enable it in Settings, Floating action button',
    },
    'home_add_todo_title': {
        'base': '添加待办',
        'zh_CN': '添加待办',
        'en_US': 'Add a task',
    },
    'home_add_todo_placeholder': {
        'base': '要做什么？',
        'zh_CN': '要做什么？',
        'en_US': 'What needs doing?',
    },
    'home_add_todo_quadrant_label': {
        'base': '放在哪一格',
        'zh_CN': '放在哪一格',
        'en_US': 'Which quadrant?',
    },
    'empty_route_filtered_title': {
        'base': '该分类下还没有目标',
        'zh_CN': '该分类下还没有目标',
        'en_US': 'No goals in this category',
    },
    'empty_route_filtered_subtitle': {
        'base': '换个分类看看，或把目标归到这一类',
        'zh_CN': '换个分类看看，或把目标归到这一类',
        'en_US': 'Try another category, or move a goal into this one',
    },
    'empty_route_filtered_action': {
        'base': '查看全部',
        'zh_CN': '查看全部',
        'en_US': 'View all',
    },
}

out = []
for lang in ['base', 'zh_CN', 'en_US']:
    p = os.path.join(RES, lang, 'element', 'string.json')
    if not os.path.exists(p):
        out.append('SKIP (no file) ' + lang)
        continue
    src = io.open(p, encoding='utf-8').read()
    lines = src.split('\n')

    idx = -1
    for i in range(len(lines) - 1, -1, -1):
        if lines[i].strip().startswith(']'):
            idx = i
            break
    if idx < 0:
        out.append('SKIP %s : array end not found' % lang)
        continue

    j = idx - 1
    while j >= 0 and not lines[j].strip():
        j -= 1
    if j >= 0 and not lines[j].rstrip().endswith(','):
        lines[j] = lines[j].rstrip() + ','

    block = []
    for k in NEW:
        v = NEW[k].get(lang)
        if v is None:
            continue
        block.append('    { "name": "%s", "value": "%s" },' % (k, v))
    if not block:
        out.append('SKIP %s : no values' % lang)
        continue
    block[-1] = block[-1][:-1]

    lines[idx:idx] = block
    after = '\n'.join(lines)
    try:
        json.loads(after)
    except Exception as e:
        out.append('SKIP WRITE %s : invalid JSON -> %s' % (lang, e))
        continue
    io.open(p, 'w', encoding='utf-8').write(after)
    out.append('%-6s added=%d' % (lang, len(block)))

io.open(LOG, 'w', encoding='utf-8').write('\n'.join(out))
print('fab i18n done')
