# -*- coding: utf-8 -*-
"""
HarmonyOS 多语言资源审计脚本（起势 / Momentum 项目）

用途：
  1. 找出「源码引用、但某语言缺失」的 string key（= 会回退中文的隐患）
  2. 找出「定义在 base、但无任何源码引用」的死 key
  3. 找出 en_US 中值仍含中文的条目（判断是否漏翻 / 是否属品牌名等正常保留）

关键点（踩过的坑）：
  - 引用写法不止 $r('app.string.x')，还有 `getString('x')` 封装、
    `getStringByNameSync('x')`、module.json5 里的 `$string:x`，务必全覆盖。
  - 排除资源文件自身时，Windows 路径用反斜杠，不要用正斜杠匹配。

用法：在工程根目录执行
  python docs/上架素材/i18n_audit.py
"""
import json, re, os

BASE = 'entry/src/main/resources/base/element/string.json'
LOCALES = {
    'en_US': 'entry/src/main/resources/en_US/element/string.json',
    'zh_CN': 'entry/src/main/resources/zh_CN/element/string.json',
}
CN = re.compile(r'[\u4e00-\u9fff]')
REF = re.compile(r"(?:app\.string\.|\$string:|getStringByNameSync\('|getString\(')([A-Za-z0-9_]+)")


def load(p):
    with open(p, encoding='utf-8-sig') as f:
        return {x['name']: x['value'] for x in json.load(f)['string']}


def collect_refs(exclude_paths):
    text = []
    for root, dirs, fs in os.walk('.'):
        parts = root.split(os.sep)
        if 'build' in parts or 'oh_modules' in parts or '.git' in parts or 'docs' in parts:
            continue
        for fn in fs:
            if fn.endswith(('.ets', '.ts', '.json', '.json5')):
                p = os.path.join(root, fn)
                if os.path.abspath(p) in exclude_paths:
                    continue
                try:
                    text.append(open(p, encoding='utf-8', errors='ignore').read())
                except Exception:
                    pass
    refs = set()
    for t in text:
        refs.update(REF.findall(t))
    return refs


def main():
    base = load(BASE)
    exclude = {os.path.abspath(BASE)} | {os.path.abspath(v) for v in LOCALES.values()}
    refs = collect_refs(exclude)
    print('源码引用 key 数:', len(refs))

    for loc, path in LOCALES.items():
        d = load(path)
        miss = sorted(k for k in refs if k not in d)
        print('\n=== [%s] 被引用但缺失：%d ===' % (loc, len(miss)))
        for k in miss:
            print('   %-34s base=%s' % (k, base.get(k, '<<base 也无>>')[:44]))

    dead = sorted(k for k in base if k not in refs)
    print('\n=== base 中无源码引用的死 key：%d ===' % len(dead))
    for k in dead:
        print('   %-40s %s' % (k, base[k][:40]))

    for loc, path in LOCALES.items():
        if loc == 'zh_CN':
            continue
        d = load(path)
        cn = [(k, v) for k, v in d.items() if CN.search(v)]
        print('\n=== [%s] 值仍含中文：%d ===' % (loc, len(cn)))
        for k, v in cn:
            print('   %-30s %s' % (k, v[:60].replace('\n', ' ')))


if __name__ == '__main__':
    main()
