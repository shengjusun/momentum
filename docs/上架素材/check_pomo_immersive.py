# -*- coding: utf-8 -*-
"""
PomodoroImmersiveScreen.ets 结构自检（无 CLI，用本脚本替代部分编译期检查）

覆盖：
1. 括号 / 字符串平衡（近似代替语法检查）
2. @Builder 与 private 方法的「定义清单」 vs 「this.xxx() 调用清单」是否闭合
3. 常量重复声明 / 前向引用（const 块级作用域不提升，前向引用是硬编译错误）
4. v4 版式关键符号存在性 / 旧符号残留
5. 硬编码线宽（应一律走 this.ringStroke()）
6. 淡出三件套的挂载点审计：只允许挂在「操作控件」上，**绝不能挂在计时显示本体上**

用法：python check_pomo_immersive.py
"""
import io
import re
import sys

P = "entry/src/main/ets/common/components/PomodoroImmersiveScreen.ets"

src = io.open(P, encoding="utf-8").read()
# ⚠️ 正则必须先剔除注释：注释里会引用历史写法（如"不要改回 this.getSelected()"），否则误报
nob = re.sub(r"/\*[\s\S]*?\*/", "", src)
nob = re.sub(r"//[^\n]*", "", nob)

ok = True


def chk(desc, cond):
    global ok
    print(("PASS  " if cond else "FAIL  ") + desc)
    if not cond:
        ok = False


def info(desc, val):
    print("  --  %s: %s" % (desc, val))


# ============ 1. 括号 / 字符串平衡 ============
print("=" * 78)
print("1. 括号 / 字符串平衡（近似语法检查）")
print("=" * 78)
# 先移除字符串字面量（含模板串反引号），再数括号
strip_str = re.sub(r"'(\\.|[^'\\])*'", "''", nob)
strip_str = re.sub(r'"(\\.|[^"\\])*"', '""', strip_str)
strip_str = re.sub(r"`(\\.|[^`\\])*`", "``", strip_str)
for op, cl, name in [("{", "}", "花括号"), ("(", ")", "圆括号"), ("[", "]", "方括号")]:
    a, b = strip_str.count(op), strip_str.count(cl)
    chk("%s 平衡 %d/%d" % (name, a, b), a == b)

# 未闭合的字符串字面量
sq, dq = nob.count("'"), nob.count('"')
chk("单引号成对 %d" % sq, sq % 2 == 0)
chk("双引号成对 %d" % dq, dq % 2 == 0)

# ============ 2. 定义清单 vs 调用清单 ============
print()
print("=" * 78)
print("2. 定义 / 调用闭合")
print("=" * 78)
builders = re.findall(r"@Builder\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(", nob)
privates = re.findall(r"private\s+(?:async\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(", nob)
getters = re.findall(r"private\s+get\s+([A-Za-z_][A-Za-z0-9_]*)\s*[:(]", nob)
# 只读成员字段：private readonly xxx: T = ...
readonlys = re.findall(r"private\s+readonly\s+([A-Za-z_][A-Za-z0-9_]*)\s*:", nob)
defined = set(builders) | set(privates) | set(getters) | set(readonlys)
info("@Builder", len(builders))
info("private 方法", len(privates))
info("private getter", len(getters))
info("private readonly 字段", len(readonlys))

# this.xxx( 调用
calls = set(re.findall(r"this\.([A-Za-z_][A-Za-z0-9_]*)\s*\(", nob))
# this.xxx 属性访问（getter 走这条）
props = set(re.findall(r"this\.([A-Za-z_][A-Za-z0-9_]*)(?![\w(])", nob))

ARROW_LOCAL = set()  # 局部箭头函数名（本项目无此类 this. 调用）
missing_calls = sorted(c for c in calls if c not in defined)
missing_props = sorted(p for p in props if p not in defined
                       and p not in ('viewW', 'viewH', 'state', 'phase', 'remainingMillis',
                                     'progressValue', 'selectedFocusMinutes', 'selectedBreakMinutes',
                                     'selectedLongBreakMinutes', 'selectedCycleLength',
                                     'completedFocusCount', 'breathOpacity', 'isLongBreak',
                                     'todayCount', 'todayMillis', 'pressedBtn', 'showStopSheet',
                                     'stopSheetTitle', 'stopSheetItems', 'chromeVisible',
                                     'taskId', 'taskTitle',
                                     'tickCbId', 'stateCbId', 'completeCbId', 'breathAnimTimer',
                                     'chromeHideTimer', 'keepScreenOnApplied', 'tag'))
chk("this.xxx() 全部有定义", len(missing_calls) == 0)
if missing_calls:
    info("未定义调用", missing_calls)
chk("this.xxx 属性访问全部有定义（未列入 @Local/@Param）", len(missing_props) == 0)
if missing_props:
    info("未定义属性", missing_props)

# ============ 3. 常量重复 / 前向引用 ============
print()
print("=" * 78)
print("3. 顶层常量：重复声明 / 前向引用（const 不提升）")
print("=" * 78)
consts = re.findall(r"^const\s+([A-Za-z_][A-Za-z0-9_]*)\s*:", nob, re.M)
dups = sorted({c for c in consts if consts.count(c) > 1})
chk("常量无重复声明（共 %d 个）" % len(consts), len(dups) == 0)
if dups:
    info("重复", dups)

first_def = {}
for m in re.finditer(r"^const\s+([A-Za-z_][A-Za-z0-9_]*)\s*:", nob, re.M):
    first_def.setdefault(m.group(1), m.start())
fwd = []
for name, pos in first_def.items():
    # 该常量定义行【之前】是否已引用过它
    body_start = nob.find("export struct")
    if body_start != -1 and pos > body_start:
        continue  # 结构体内联常量，不参与此检查
    uses = [m.start() for m in re.finditer(r"\b%s\b" % re.escape(name), nob[:pos])]
    if uses:
        fwd.append(name)
chk("常量无前向引用", len(fwd) == 0)
if fwd:
    info("前向引用", fwd)

# ============ 4. v4 关键符号 & 旧符号残留 ============
print()
print("=" * 78)
print("4. v4 版式符号审计")
print("=" * 78)
for sym in ["landscapeActionButton", "landscapeActionWidth", "landscapeActionHeight",
            "landscapeMinuteCircle", "landscapeSecondCircle", "landscapeDivider",
            "landscapeDual", "minuteCircleText"]:
    chk("v4 必需符号存在: " + sym, re.search(r"\b%s\b" % sym, nob) is not None)

# 横屏分圆必须显示「剩余分钟」，与竖屏同源；禁止再引入"已走"派生量。
# 2026-09-15 事故：v4 用 sessionElapsedMillis 让左圆显示"已走分钟"，
# 刚进专注的 1 分钟内必然显示 00 → 用户报"切横屏分钟变成 0"。
chk("横屏分圆读剩余分钟（minuteCircleText → splitMinuteText(remainingMillis)）",
    re.search(r"private minuteCircleText\(\): string \{[\s\S]*?splitMinuteText\(this\.remainingMillis\)",
              nob) is not None)
for sym in ["sessionElapsedMillis", "elapsedForPhase"]:
    chk("已走派生量已清除: " + sym, re.search(r"\b%s\b" % sym, nob) is None)

# 旧的「点秒圆即暂停」实现必须彻底消失
for sym in ["RING_TIME_RATIO", "ringTimeSideBySide", "landscapeRingSize",
            "LANDSCAPE_RING_RATIO_MAX"]:
    chk("旧符号已清: " + sym, re.search(r"\b%s\b" % sym, nob) is None)

# ============ 5. 硬编码线宽 ============
print()
print("=" * 78)
print("5. 硬编码线宽审计（应一律走 this.ringStroke()）")
print("=" * 78)
hard = re.findall(r"strokeWidth\(\s*(\d+)\s*\)", nob)
hard = [h for h in hard if h not in ("1",)]  # Divider 的 1vp 是刻意的
chk("无硬编码 strokeWidth（除分隔线 1vp）", len(hard) == 0)
if hard:
    info("硬编码值", hard)
chk("细描边走 LANDSCAPE_THIN_STROKE", "strokeWidth(LANDSCAPE_THIN_STROKE)" in nob)

# ============ 6. 淡出三件套挂载点审计（核心！） ============
print()
print("=" * 78)
print("6. 淡出（chromeOpacity）挂载点审计 —— 只能挂操作控件，不能挂计时显示本体")
print("=" * 78)

# 提取每个 @Builder 的函数体（按 @Builder 名字分段，取到下一个 @Builder / 类尾）
segs = {}
marks = [(m.start(), m.group(1)) for m in re.finditer(r"@Builder\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(", nob)]
for i, (pos, name) in enumerate(marks):
    end = marks[i + 1][0] if i + 1 < len(marks) else len(nob)
    segs[name] = nob[pos:end]

# 计时显示本体：绝不允许出现 chromeOpacity
for name in ["landscapeMinuteCircle", "landscapeSecondCircle", "landscapeDual",
             "idleRing", "runningRing", "ringTimeStacked", "landscapeDivider"]:
    body = segs.get(name, "")
    chk("计时显示本体不淡出: %s" % name, "chromeOpacity" not in body)

# 操作控件：必须有 chromeOpacity
for name in ["landscapeActionButton", "primaryActionButton"]:
    body = segs.get(name, "")
    chk("操作控件挂淡出: %s" % name, "chromeOpacity" in body)

# 横屏两个圆都不可点击
for name in ["landscapeMinuteCircle", "landscapeSecondCircle"]:
    body = segs.get(name, "")
    chk("横屏圆不可点击: %s" % name, ".onClick(" not in body and "LongPressGesture" not in body)

# 分圆不得有进度弧
chk("分圆无 Progress（纯细描边）", "Progress(" not in segs.get("landscapeMinuteCircle", ""))
# 秒圆必须是「轨道 + 进度」两层
chk("秒圆有轨道+进度两层", segs.get("landscapeSecondCircle", "").count("Progress(") == 2)

# 横屏胶囊是唯一操作入口：landscapeDual 内 onClick 只出现在胶囊上
dual = segs.get("landscapeDual", "")
chk("横屏主体含胶囊按钮调用", "this.landscapeActionButton()" in dual)
chk("横屏主体内联 onClick 已移除（收敛到胶囊）", ".onClick(" not in dual)

# 按钮位置 = 两圆中点正下方（方案 A，2026-09-15 用户拍板）
btn_anchor = re.search(
    r"Column\(\)\s*\{\s*this\.landscapeActionButton\(\)\s*\}\s*"
    r"\.width\('100%'\)\s*\.alignItems\(HorizontalAlign\.Center\)", dual)
chk("按钮包装显式 width(100%) + alignItems(Center)（锚定中线）", btn_anchor is not None)
chk("两圆整体水平居中（Row justifyContent Center）", "FlexAlign.Center" in dual)
chk("按钮位于两圆下方（带 LANDSCAPE_ACTION_GAP）", "LANDSCAPE_ACTION_GAP" in dual)

print()
print("=" * 78)
print("总行数: %d" % len(src.splitlines()))
print("结论: %s" % ("全部通过" if ok else "存在失败项"))
print("=" * 78)
sys.exit(0 if ok else 1)
