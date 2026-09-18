# -*- coding: utf-8 -*-
"""
云同步重构静态自查（本工程无 hvigorw，CLI 无法编译 → 用脚本替代编译期检查）

用法：
    python check_sync_refactor.py            # 打印结果并写 .workbuddy/_check_sync_report.txt

覆盖：
  1. 括号 / 引号平衡（先剔注释与字符串，避免注释里的示例括号误报）
  2. 旧符号残留（本次重构禁止复活的历史 API）
  3. 新符号必需（重构后的关键定义必须存在）
  4. 关键不变式（落地不得改 updatedAt / 不得打脏标记、水位只在成功后更新等）
  5. 模型层老数据兼容（isDeleted / updatedAt 缺失兜底）
"""
import io
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ETS = os.path.join(ROOT, 'entry', 'src', 'main', 'ets')

FILES = {
    'sync': 'common/services/CloudSyncService.ets',
    'db': 'common/services/CloudDBService.ets',
    'settings_vm': 'viewmodel/SettingsViewModel.ets',
    'route_vm': 'viewmodel/RoutePageViewModel.ets',
    'home_vm': 'viewmodel/HomeViewModel.ets',
    'route_models': 'model/RouteModels.ets',
    'home_models': 'model/HomeModels.ets',
    'persist': 'common/utils/PersistHelper.ets',
    'constants': 'common/constants/CommonConstants.ets',
    'main_tab': 'pages/MainTab.ets',
    'entry_ability': 'entryability/EntryAbility.ets',
    'setting_page': 'pages/SettingPage.ets',
    'import_export': 'pages/ImportExportPage.ets',
}

results = []


def chk(desc, ok, detail=''):
    results.append((bool(ok), desc, detail))


def read(key):
    p = os.path.join(ETS, FILES[key].replace('/', os.sep))
    if not os.path.exists(p):
        return None
    return io.open(p, encoding='utf-8').read()


def strip_comments_and_strings(src):
    """剔除块注释 / 行注释 / 字符串字面量 / **正则字面量**，返回纯代码文本（保留换行以维持行号）

    正则字面量必须识别：否则 `/\\"/g` 这类"正则里带引号"会把扫描器带偏，
    造成后续括号统计错位（本工程 DeepSeekService.ets 就有多处）。
    判定：`/` 出现在"期待值"的位置（前一有效字符是 ( , = : [ ! & | ? { } ; 或行首）时按正则处理。
    """
    out = []
    i = 0
    n = len(src)
    prev_sig = ''  # 上一个有效（非空白）字符
    while i < n:
        c = src[i]
        if c == '/' and i + 1 < n and src[i + 1] == '*':
            j = src.find('*/', i + 2)
            j = n if j < 0 else j + 2
            out.append('\n' * src.count('\n', i, j))
            i = j
        elif c == '/' and i + 1 < n and src[i + 1] == '/':
            j = src.find('\n', i)
            j = n if j < 0 else j
            out.append('\n')
            i = j
        elif c == '/' and (prev_sig in ('', '(', ',', '=', ':', '[', '!', '&', '|', '?', '{', '}', ';', '+', '-', '*', '%', '<', '>')):
            # 正则字面量：扫到未转义的 / （跳过字符类 [...]）
            j = i + 1
            in_class = False
            while j < n:
                ch = src[j]
                if ch == '\\':
                    j += 2
                    continue
                if ch == '[':
                    in_class = True
                elif ch == ']':
                    in_class = False
                elif ch == '/' and not in_class:
                    break
                elif ch == '\n':
                    break
                j += 1
            j = min(j + 1, n)
            while j < n and src[j].isalpha():
                j += 1  # 跳过 flags
            out.append('RE')
            prev_sig = 'E'
            i = j
        elif c in ('"', "'", '`'):
            quote = c
            j = i + 1
            while j < n:
                if src[j] == '\\':
                    j += 2
                    continue
                if src[j] == quote:
                    break
                j += 1
            j = min(j + 1, n)
            out.append('""')
            prev_sig = '"'
            i = j
        else:
            out.append(c)
            if not c.isspace():
                prev_sig = c
            i += 1
    return ''.join(out)


def balance(path, src):
    code = strip_comments_and_strings(src)
    issues = []
    for op, cl in (('{', '}'), ('(', ')'), ('[', ']')):
        a = code.count(op)
        b = code.count(cl)
        if a != b:
            issues.append('%s%s=%d/%d' % (op, cl, a, b))
    chk('括号平衡 %s' % path, not issues, ' '.join(issues))
    return code


# ---------------------------------------------------------------- 1. 文件与平衡
codes = {}   # 剔除注释与字符串后的纯代码（用于结构/负向断言）
raws = {}    # 原始源码（用于含字符串字面量的正向断言，正则须足够精确以免命中注释）
for key, rel in FILES.items():
    src = read(key)
    if src is None:
        chk('文件存在 %s' % rel, False, 'missing')
        continue
    chk('文件存在 %s' % rel, True)
    raws[key] = src
    codes[key] = balance(rel, src)

# ---------------------------------------------------------------- 2. 旧符号残留
sync = codes.get('sync', '')
settings_vm = codes.get('settings_vm', '')

for sym in ['SyncDirection', 'forceUpload', 'scheduleSync(', 'uploadIfChanged',
            "'upload'", "'download'", 'triggerDownloadSync', 'mergedUpdatedAt', 'cloudNewer']:
    chk('同步服务已清除旧符号 %s' % sym, sym not in sync, 'still present in CloudSyncService')

chk('同步服务不再出现方向参数调用',
    "smartSync(" not in sync, 'smartSync should be replaced by requestMerge')

# ---------------------------------------------------------------- 3. 新符号必需
required_sync = ['requestMerge', 'SyncOutcome', 'runLoop', 'runMergeOnce', 'mergeTopLevelArray',
                 'pickWinner', 'itemStamp', 'readBool', 'payloadFingerprint', 'neutralizeLastSyncTime',
                 'canonical', 'canonicalOf', 'hash64', 'uploadPayload', 'applyCloudData',
                 'isBusy', 'deleteCloudRecord']
for sym in required_sync:
    chk('同步服务包含 %s' % sym, sym in sync, 'missing in CloudSyncService')

for sym in ['STORAGE_KEY_SYNC_DIRTY']:
    chk('常量包含 %s' % sym, sym in codes.get('constants', ''), 'missing in CommonConstants')

chk('PersistHelper.persistNow 返回 boolean',
    'persistNow(): Promise<boolean>' in codes.get('persist', ''),
    'must return boolean for success gate')
chk('PersistHelper 仅在写入成功时触发 onScheduleFire',
    re.search(r'const persisted: boolean = await this\.persistNow\(\)', codes.get('persist', '')) is not None and
    re.search(r'if \(!persisted\)', codes.get('persist', '')) is not None,
    'scheduleSave must skip onScheduleFire on failure')

# ---------------------------------------------------------------- 4. 关键不变式
# 4.1 同步服务：水位只取自 uploadPayload 的返回值，且无"先更新水位"路径
chk('同步服务水位取自上传返回值',
    'lastSyncTime: Number(written)' in sync, 'watermark must come from upload return value')
chk('同步服务不再从回调更新水位',
    'updateLastSyncTime' not in sync, 'watermark write must move to caller after success')
chk('同步服务已移除 updateLastSyncTime 回调字段',
    'updateLastSyncTime' not in sync, '')
chk('同步服务首传分支存在', 'cloud null, local uploaded as first record' in sync.replace('\n', ' ')
    or 'cloudRecord === null' in sync, '')

# 4.2 模型层：isDeleted / updatedAt 双向序列化 + 老数据兜底
rm = codes.get('route_models', '')
hm = codes.get('home_models', '')
chk('GoalCardItem 含 isDeleted / updatedAt 字段',
    'isDeleted' in rm and 'updatedAt' in rm, '')
chk('HomeTodoItem 含 isDeleted / updatedAt 字段',
    'isDeleted' in hm and 'updatedAt' in hm, '')
chk('GoalCardItemJSON 含两个新字段',
    re.search(r'interface GoalCardItemJSON[\s\S]*?isDeleted\?: boolean', rm) is not None and
    re.search(r'interface GoalCardItemJSON[\s\S]*?updatedAt\?: number', rm) is not None, '')
chk('HomeTodoItemJSON 含两个新字段',
    re.search(r'interface HomeTodoItemJSON[\s\S]*?isDeleted\?: boolean', hm) is not None and
    re.search(r'interface HomeTodoItemJSON[\s\S]*?updatedAt\?: number', hm) is not None, '')
chk('老数据 isDeleted 兜底为 false',
    re.search(r"json\.isDeleted\s*===\s*'boolean'\s*\?\s*json\.isDeleted\s*:\s*false", raws.get('route_models', '')) is not None and
    re.search(r"json\.isDeleted\s*===\s*'boolean'\s*\?\s*json\.isDeleted\s*:\s*false", raws.get('home_models', '')) is not None,
    'isDeleted must default to false for legacy data')
chk('老数据 updatedAt 兜底为 0',
    re.search(r"json\.updatedAt\s*===\s*'number'\s*&&\s*!isNaN\(json\.updatedAt\)", raws.get('route_models', '')) is not None and
    re.search(r"json\.updatedAt\s*===\s*'number'\s*&&\s*!isNaN\(json\.updatedAt\)", raws.get('home_models', '')) is not None,
    'updatedAt must default to 0 for legacy data')
chk('snapshot 写出 isDeleted',
    'isDeleted: this.isDeleted === true' in rm and 'isDeleted: todo.isDeleted === true' in hm, '')

# ---------------------------------------------------------------- 5. 同步载荷水位隔离
sm = codes.get('settings_vm', '')
sm_raw = raws.get('settings_vm', '')
chk('上传载荷 profileJson 不含 lastSyncTime',
    re.search(r"const profilePayload: Record<string, Object> = \{[\s\S]*?\}", sm_raw) is not None and
    "lastSyncTime" not in re.search(r"const profilePayload: Record<string, Object> = \{[\s\S]*?\}", sm_raw).group(0),
    'profilePayload must not carry the local watermark')
chk('应用云端 profile 时忽略其 lastSyncTime',
    'keepLocalWatermark' in sm, 'cloud watermark must never overwrite the local one')

# ---------------------------------------------------------------- 6. 持久化脏标记 + 就绪 gate
for sym in ['markSyncNeeded', 'clearSyncNeeded', 'loadSyncDirty', 'persistSyncDirty',
            'notifyCloudReady', 'isReadyToSync', 'handleSyncResult', 'syncNowDetached',
            'snapshotsReady', 'pendingReadySync', 'syncDirty']:
    chk('SettingsVM 含 %s' % sym, sym in sm, 'missing in SettingsViewModel')

chk('StorageManager 读写脏标记',
    'STORAGE_KEY_SYNC_DIRTY' in sm_raw, 'dirty flag must be persisted')

for sym in ['triggerCloudSync', 'doTriggerCloudSync', 'forceUploadFlag',
            'triggerDownloadSync', 'buildSyncDataBundle', 'buildSyncApplyCallback']:
    chk('SettingsVM 已清除 %s' % sym, sym not in sm, 'still present in SettingsViewModel')
chk('SettingsVM 不再直接调用 smartSync',
    'smartSync' not in sm, 'must go through requestMerge')

# 清空类操作必须清脏标记（登出 / 强登出 / 一键删除）
chk('登出流程清除脏标记', sm.count('clearSyncNeeded(') >= 2,
    'logout / forceLogout / deleteAllData must clear the dirty flag')
chk('清空类操作开启抑制窗口', 'suppressAutoSyncUntil = Date.now()' in sm,
    'clear-data window must block dirty marking')

# ---------------------------------------------------------------- 7. 入口收敛
mt = codes.get('main_tab', '')
ea = codes.get('entry_ability', '')
sp = codes.get('setting_page', '')
chk('MainTab 快照提供者用 buildSyncSnapshot（含墓碑）',
    'buildSyncSnapshot()' in mt and 'registerSnapshotProviders' in mt, '')
chk('MainTab 注册后通知就绪', 'notifyCloudReady()' in mt, '')
chk('EntryAbility onForeground 触发 merge',
    re.search(r'onForeground\(\)[\s\S]*?triggerSync\(\)', ea) is not None, '')
chk('EntryAbility onBackground 只落标记不联网',
    re.search(r'onBackground\(\)[\s\S]*?markSyncNeeded\([^)]*false\s*\)', ea) is not None and
    re.search(r'onBackground\(\)[\s\S]*?triggerSync', ea) is None,
    'background must never issue a network merge')
chk('SettingPage 立即同步走 syncNow',
    "syncNow('manual')" in raws.get('setting_page', ''), '')
chk('SettingPage 已移除强制覆盖调用',
    "smartSync(" not in sp and 'buildSyncDataBundle' not in sp, '')
chk('SettingPage 开关确认后才开启', re.search(r'result\.index === 1[\s\S]{0,120}toggleSyncEnabled\(true\)', sp) is not None,
    'enable must happen after confirmation')

# ---------------------------------------------------------------- 8. VM：墓碑写入 + live 视图
rv = codes.get('route_vm', '')
hv = codes.get('home_vm', '')
chk('RouteVM 存在 liveGoals 视图', 'get liveGoals()' in rv, '')
chk('HomeVM 存在 liveTasks 视图', 'get liveTasks()' in hv, '')
chk('RouteVM 删除目标改墓碑',
    re.search(r'deleteGoal\(goalId: Id\): boolean \{[\s\S]*?isDeleted = true', rv) is not None, '')
chk('HomeVM 删除待办改墓碑',
    re.search(r'deleteTask\(taskId: Id\): boolean \{[\s\S]*?isDeleted = true', hv) is not None, '')
chk('HomeVM 级联删除改墓碑',
    'task.isDeleted = true' in hv, '')
chk('RouteVM 有 touchGoal 打点助手', 'private touchGoal(goalId: Id)' in rv, '')
chk('HomeVM 落地直接落盘（不走 scheduleSave）',
    re.search(r'applyCloudSnapshot\(cloudData: Record<string, Object>\): void \{[\s\S]*?persistData\(\)',
              hv) is not None, '')
chk('RouteVM 落地直接落盘（不走 scheduleSave）',
    re.search(r'applyCloudSnapshot\(cloudData: Record<string, Object>\): void \{[\s\S]*?persistData\(\)',
              rv) is not None, '')
chk('RouteVM 落地禁止改写 updatedAt',
    'updatedAt' not in re.search(r'applyCloudSnapshot\(cloudData: Record<string, Object>\): void \{[\s\S]*?\n  \}',
                                 rv).group(0), '')
chk('HomeVM 落地禁止改写 updatedAt',
    'updatedAt' not in re.search(r'applyCloudSnapshot\(cloudData: Record<string, Object>\): void \{[\s\S]*?\n  \}',
                                 hv).group(0), '')
chk('RouteVM 补上 onScheduleFire', 'SYNC_NEEDED' in rv, '')
chk('updatedAt 打点数量足够（RouteVM）', rv.count('updatedAt = Date.now()') + rv.count('touchGoal(') >= 12,
    'every mutator must refresh the item version')
chk('updatedAt 打点数量足够（HomeVM）', hv.count('updatedAt = Date.now()') >= 7,
    'every mutator must refresh the item version')
chk('VM 落地抑制云同步回环', 'isApplyingCloudSnapshot' in rv and 'isApplyingCloudSnapshot' in hv, '')

# ---------------------------------------------------------------- 9. 消费方改用 live 视图
live_consumers = {
    'pages/StatsPage.ets': 'stats',
    'pages/NotificationPage.ets': 'notification',
    'pages/GoalDetailPage.ets': 'goal detail',
    'pages/TaskDetailPage.ets': 'task detail',
    'pages/FeedbackPage.ets': 'feedback',
    'pages/CategoryManagePage.ets': 'category',
    'pages/GoalHistoryPage.ets': 'history',
}
for rel, label in live_consumers.items():
    p = os.path.join(ETS, rel.replace('/', os.sep))
    if not os.path.exists(p):
        continue
    src = io.open(p, encoding='utf-8').read()
    code = strip_comments_and_strings(src)
    chk('消费方 %s 不再直读底层 goals' % label,
        'routeVM.goals' not in code, 'must read routeVM.liveGoals')
    chk('消费方 %s 不再直读底层 taskList' % label,
        'homeVM.taskList' not in code, 'must read homeVM.liveTasks')

# ---------------------------------------------------------------- 10. 空态保留页面骨架
# 2026-09-15：两页空态曾用"整页居中插画"（首页 StateView(EMPTY) / 路线页居中 RouteEmptySection），
# 把页面骨架整个替换掉 —— 首页看不到四象限、路线页看不到卡片列表，用户反馈"很怪、没有框架"。
# 这里守住「空态保留骨架 + 引导不占满屏」，防止回退。
home_code = strip_comments_and_strings(
    io.open(os.path.join(ETS, 'pages', 'HomePage.ets'), encoding='utf-8').read())
chk('首页空态保留四象限骨架（引导压成一行）',
    'EmptyGuideRowBuilder' in home_code and 'QuadrantMatrixBuilder' in home_code, '')
chk('首页空态不得再用整页插画空态',
    'StateMode.EMPTY' not in home_code, 'StateView EMPTY 会把四象限矩阵整个换掉')

route_src = io.open(os.path.join(ETS, 'pages', 'RoutePage.ets'), encoding='utf-8').read()
chk('路线页空态为引导卡且双入口（AI / 手动）',
    'empty_route_manual' in route_src and 'onCreateGoal' in route_src, '')

# ---------------------------------------------------------------- 10a-2. AI 场景芯片：横向滚动单行 + 6 场景
ai_comp = io.open(os.path.join(ETS, 'common', 'components', 'ai', 'AIChatComponents.ets'),
                  encoding='utf-8').read()
chk('AI 场景芯片为横向滚动单行（手机不得再折成 2×2）',
    'ScrollDirection.Horizontal' in ai_comp and 'FlexWrap.Wrap' not in ai_comp, '')
chk('AI 场景芯片扩容到 6 个（开发/学习/求职/健康/生活/习惯）',
    'scenario_5' in ai_comp and 'scenario_6' in ai_comp, '')

# ---------------------------------------------------------------- 10b. 悬浮按钮：长按隐藏 + 全局显隐
setting_code = strip_comments_and_strings(
    io.open(os.path.join(ETS, 'pages', 'SettingPage.ets'), encoding='utf-8').read())
chk('设置页有「悬浮快捷按钮」开关',
    'handleFabToggle' in setting_code and 'STORAGE_KEY_FAB_VISIBLE' in setting_code, '')
chk('两页 FAB 都受 fabVisible 控制',
    'this.fabVisible' in home_code and 'this.fabVisible' in route_src, '')
chk('两页 FAB 都支持长按隐藏',
    'handleFabLongPress' in home_code and 'handleFabLongPress' in route_src, '')
chk('长按隐藏写的是全局偏好（两页同一存储键）',
    'STORAGE_KEY_FAB_VISIBLE' in home_code and 'STORAGE_KEY_FAB_VISIBLE' in route_src, '')

# ---------------------------------------------------------------- 10c. 首页手动添加待办
chk('首页有「添加待办」弹层与提交逻辑',
    'AddTodoSheetBuilder' in home_code and 'handleAddTodo' in home_code, '')
# 必须走 bindSheet：页面内自绘 Stack 层位于 HdsTabs 内容区之内，
# 会被悬浮胶囊 TabBar 压住底部「确认 / 取消」（真机已复现），遮罩也盖不住 TabBar
chk('「添加待办」弹层走 bindSheet（禁自绘 Stack 层，防 TabBar 遮挡回归）',
    '$$this.showAddTodoSheet' in home_code and 'this.AddTodoSheetBuilder()' in home_code, '')
vm_home = strip_comments_and_strings(
    io.open(os.path.join(ETS, 'viewmodel', 'HomeViewModel.ets'), encoding='utf-8').read())
chk('HomeViewModel 提供 addManualTask（象限反推后入库）',
    'addManualTask' in vm_home, '')
# 手动待办天生无关联（relatedGoalId/relatedTaskId 为空串）：
# ① 入库校验必须传 requireRelation=false（曾因复用 addExtractedTask 的非空强校验而 100% 添加失败）
# ② hydrate（冷启动复活）只做类型校验 —— 强校验非空会导致手动待办重启后被静默丢弃
chk('addManualTask 不复用摘取校验（requireRelation=false + insertTodo 内核）',
    'isValidHomeTodoItem(todo, false)' in vm_home and 'this.insertTodo(todo)' in vm_home, '')
model_home = strip_comments_and_strings(
    io.open(os.path.join(ETS, 'model', 'HomeModels.ets'), encoding='utf-8').read())
chk('isValidHomeTodoItem 支持 requireRelation（放行手动待办）',
    'requireRelation: boolean = true' in model_home, '')
# ⚠️ 该断言必须用原始源码（不剥离）判定：'string' 是字符串字面量，会被剥离器吃掉
model_raw = io.open(os.path.join(ETS, 'model', 'HomeModels.ets'), encoding='utf-8').read()
chk('hydrateHomeTodoItem 关联字段仅类型校验（防冷启动丢手动待办）',
    "typeof json.relatedTaskId !== 'string') return null" in model_raw and
    "json.relatedTaskId.length === 0" not in model_raw, '')

# ---------------------------------------------------------------- 10d. 路线页两种空态必须分离
chk('路线页区分「无目标」与「筛选后为空」',
    'RouteFilteredEmptySection' in route_src and 'liveGoals.length === 0' in route_src, '')

# ---------------------------------------------------------------- 10e. 实况窗（TIMER 场景，规范硬约束）
lv_path = os.path.join(ETS, 'common', 'services', 'PomodoroLiveViewService.ets')
lv_raw = io.open(lv_path, encoding='utf-8').read()
lv_code = strip_comments_and_strings(lv_raw)
# 'TIMER' 是字符串字面量 → 必须用原始源码判定（剥离器会吃掉）
chk('实况窗服务声明 TIMER 场景', "event: 'TIMER'" in lv_raw, '')
# 规范原文："卡片辅助区需明确展示当前处于计时中/暂停状态" → 状态必须在辅助区，不能只写在标题
chk('状态写在卡片辅助区（extensionData + COMMON_TEXT）',
    'extensionData' in lv_code and 'EXTENSION_TYPE_COMMON_TEXT' in lv_code, '')
# 倒数由系统计时器驱动：占位符 + 顶层 timer，应用不按秒刷新
chk('倒数用 ${placeholder.timer} 占位符（原始源码判定）',
    'placeholder.timer' in lv_raw, '')
chk('配置了顶层计时器（LiveViewTimer：time/isCountdown/isPaused）',
    'LiveViewTimer' in lv_code and 'isCountdown' in lv_code and 'isPaused' in lv_code, '')
chk('胶囊用 TimerCapsule', 'CAPSULE_TYPE_TIMER' in lv_code, '')
# 图标必须用 rawfile 文件名：PixelMap 有 30KB 上限（应用图标 1024² ≈ 4MB 必超标），
# 且 app.media.app_icon 是 SVG，image.createImageSource 解不了 → startLiveView 直接失败
chk('胶囊图标用 rawfile 文件名（禁 PixelMap 解码）',
    'CAPSULE_ICON_FILE' in lv_code and 'getMediaContent' not in lv_code and
    'createImageSource' not in lv_code, '')
chk('rawfile 存在胶囊图标文件 pomo_capsule_icon.png',
    os.path.isfile(os.path.join(ROOT, 'entry', 'src', 'main', 'resources',
                                'rawfile', 'pomo_capsule_icon.png')), '')
pomo_path = os.path.join(ETS, 'common', 'services', 'PomodoroService.ets')
pomo_code = strip_comments_and_strings(io.open(pomo_path, encoding='utf-8').read())
# ⚠️ 防回归红线：应用**禁止**按秒刷新实况窗（应用级更新流控每秒 20 次会丢，
# 且进程被冻结时调用发不出去）—— PomodoroService 里不应出现任何 updateLiveView
chk('番茄钟不按秒刷新实况窗（无 updateLiveView 调用）',
    'updateLiveView' not in pomo_code, '')
chk('状态切换点接入实况窗（≥6 处 ensureRunning）',
    pomo_code.count('this.syncLiveViewSafe(') >= 6, '')
chk('终止点结束实况窗（≥4 处 end）',
    pomo_code.count('this.endLiveViewSafe(') >= 4, '')
chk('实况窗接管后跳过常驻通知（避免通知中心重复）',
    'this.liveViewService.isActive()' in pomo_code, '')

# ---------------------------------------------------------------- 10f. AGC 鉴权自愈（僵尸会话不可恢复缺陷）
agc_src = io.open(os.path.join(ETS, 'common', 'services', 'AgcAuthService.ets'),
                  encoding='utf-8').read()
db_src = io.open(os.path.join(ETS, 'common', 'services', 'CloudDBService.ets'),
                 encoding='utf-8').read()
chk('AgcAuthService 提供 resetSession() 且调用 auth.signOut()',
    'static async resetSession' in agc_src and 'auth.signOut()' in agc_src,
    '无 signOut 则缓存的僵尸会话无法清除 → 云端永久 401')
chk('CloudDBService 具备「鉴权被拒」判据与自愈助手',
    'isAgcSessionRejected' in db_src and 'healAgcSession' in db_src, '')
chk('四个云操作均挂鉴权自愈重试（download/upload/delete/addFeedback 各 1 处）',
    db_src.count('await this.healAgcSession(') == 4, '')
chk('自愈重试带 retried 守卫（只重试一次，防死循环）',
    db_src.count('retried: boolean = false') == 4, '')

# ---------------------------------------------------------------- 10g. 手动待办：4 级架构红线豁免链必须闭合
# 真机故障复盘：buildHomeTodoItem 默认强制 relatedTaskId/relatedGoalId 非空，
# 手动待办传空串 → 工厂直接抛 `relatedTaskId is required` → 点「添加」必失败。
chk('buildHomeTodoItem 提供 requireRelation 豁免开关（默认仍强制关联）',
    'requireRelation: boolean = true' in model_home, '')
chk('模型层提供 buildManualTodoItem 专用工厂（豁免收口一处）',
    'function buildManualTodoItem' in model_home, '')
chk('手动待办走 buildManualTodoItem（不得直接用 buildHomeTodoItem）',
    'buildManualTodoItem(' in vm_home and 'buildHomeTodoItem(' not in vm_home, '')
chk('入库校验与工厂同口径（requireRelation=false 成对出现）',
    'isValidHomeTodoItem(todo, false)' in vm_home, '')
chk('Models 桶文件已导出 buildManualTodoItem',
    'buildManualTodoItem' in io.open(os.path.join(ETS, 'model', 'Models.ets'),
                                     encoding='utf-8').read(), '')

# ---------------------------------------------------------------- 11. 资源完整性
res_dir = os.path.join(ROOT, 'entry', 'src', 'main', 'resources')
for lang in ['base', 'zh_CN', 'en_US']:
    p = os.path.join(res_dir, lang, 'element', 'string.json')
    try:
        doc = json.load(io.open(p, encoding='utf-8'))
        kv = {}
        for it in doc.get('string', []):
            kv[it.get('name')] = it.get('value')
        chk('%s 含 toast_sync_upload_pending' % lang, 'toast_sync_upload_pending' in kv, '')
        chk('%s 含场景芯片 5/6（生活/习惯场景）' % lang,
            all(k in kv for k in ('scenario_5_text', 'scenario_5_prompt',
                                  'scenario_6_text', 'scenario_6_prompt')), '')
        lv_keyword = 'Live View' if lang == 'en_US' else '实况窗'
        chk('%s 隐私长文含实况窗与 OpenID 披露（对齐托管 V1.1）' % lang,
            'privacy_content' in kv
            and lv_keyword in (kv.get('privacy_content') or '')
            and 'OpenID' in (kv.get('privacy_content') or ''), '')
        chk('%s 含实况窗文案' % lang,
            'liveview_title_focus' in kv and 'liveview_title_break' in kv and
            'liveview_state_running' in kv and 'liveview_state_paused' in kv, '')
        # 品牌名回归守卫：base / zh_CN 必须是中文主名「起势」（历史出现过被外部进程整文件回退）；
        # en_US 使用英文名 Momentum，属预期双语品牌，不做中文强校验
        if lang == 'en_US':
            chk('en_US app_name 非空（英文名）', len(kv.get('app_name') or '') > 0,
                'app_name=%s' % kv.get('app_name'))
        else:
            chk('%s app_name 为起势' % lang, kv.get('app_name') == '起势', 'app_name=%s' % kv.get('app_name'))
    except Exception as e:
        chk('%s string.json 可解析' % lang, False, str(e))

# ---------------------------------------------------------------- 11. 全工程语法粗检
# 本工程无 hvigorw（CLI 不能编译），对 entry/src/main/ets 下**全部 .ets** 做
# 括号 / 引号平衡检查，作为编译期语法检查的替代（先剔注释与字符串，避免误报）
all_ets = []
for dirpath, _dirnames, filenames in os.walk(ETS):
    for fn in filenames:
        if fn.endswith('.ets'):
            all_ets.append(os.path.join(dirpath, fn))
bad_files = []
for p in all_ets:
    try:
        src = io.open(p, encoding='utf-8').read()
    except Exception as e:
        bad_files.append('%s (read: %s)' % (os.path.relpath(p, ETS), e))
        continue
    code = strip_comments_and_strings(src)
    for op, cl in (('{', '}'), ('(', ')'), ('[', ']')):
        if code.count(op) != code.count(cl):
            bad_files.append('%s (%s%s %d/%d)' % (os.path.relpath(p, ETS), op, cl,
                                                  code.count(op), code.count(cl)))
chk('全工程 %d 个 .ets 括号/引号平衡' % len(all_ets), not bad_files, ' | '.join(bad_files[:6]))

# ---------------------------------------------------------------- 12. 动效升级不变式（L0 Token + L1a 转场）
# 背景：升级前全工程 9 处 .transition() 中有 8 处是裸 TransitionEffect.OPACITY，
#   官方《组件内转场》对象说明第 3 点：未使用 animateTo 触发且 TransitionEffect 中
#   无 animation 参数 → 组件直接出现或消失。即它们**从来没在动**。
#   本段守卫的是"修好之后不许退化"。
MOTION_CONST = 'common/constants/MotionConstants.ets'
MOTION_HELPER = 'common/utils/MotionHelper.ets'
# 本次 L1a 的转场骨架计数（新增/删除转场时必须同步更新，属有意为之的护栏）
EXPECT_TRANSITIONS = {'dialogCard': 4, 'overlayFade': 6, 'bottomPanel': 2, 'noTransition': 4}
# 不动清单：允许保留原硬编码动效的文件（None = 整文件豁免）
LEGACY_ANIM_ALLOW = {
    'common/components/PomodoroImmersiveScreen.ets': None,
    'pages/GoalDetailPage.ets': ('duration: 800',),
}


def call_arg(code, open_idx):
    """取 '(' 起配对到 ')' 的完整实参文本（无参时返回 '(x)' 兜底片段）"""
    depth = 0
    i = open_idx
    while i < len(code):
        if code[i] == '(':
            depth += 1
        elif code[i] == ')':
            depth -= 1
            if depth == 0:
                return code[open_idx:i + 1]
        i += 1
    return code[open_idx:open_idx + 200]


motion_files = {}
for p in all_ets:
    rel = os.path.relpath(p, ETS).replace(os.sep, '/')
    try:
        src = io.open(p, encoding='utf-8').read()
    except Exception:
        continue
    motion_files[rel] = strip_comments_and_strings(src)

chk('动效：MotionConstants.ets 存在', MOTION_CONST in motion_files, 'missing')
chk('动效：MotionHelper.ets 存在', MOTION_HELPER in motion_files, 'missing')

mc = motion_files.get(MOTION_CONST, '')
mh = motion_files.get(MOTION_HELPER, '')

need_mc = ('DURATION_FAST', 'DURATION_BASE', 'DURATION_SLOW',
           'CURVE_PRESS', 'CURVE_ENTER', 'CURVE_EXIT', 'CURVE_PANEL',
           'ENTER_TRANSLATE_Y', 'PANEL_TRANSLATE_Y', 'DIALOG_SCALE_FROM', 'DIALOG_TRANSLATE_Y',
           'LIST_ITEM_TRANSLATE_Y', 'LIST_ITEM_SCALE_TO', 'EXPAND_TRANSLATE_Y',
           'pressParam', 'enterParam', 'exitParam', 'panelParam', 'springParam')
miss_mc = [s for s in need_mc if s not in mc]
chk('动效：MotionConstants 三档时长 / 四曲线 / 幅度量 / 参数工厂齐备',
    not miss_mc, 'missing=%s' % ','.join(miss_mc))

BUILDERS = ('overlayFade', 'dialogCard', 'bottomPanel', 'listItem', 'expandSection', 'noTransition')
miss_mh = [s for s in BUILDERS if s not in mh]
chk('动效：MotionHelper 六个转场构建器齐备', not miss_mh, 'missing=%s' % ','.join(miss_mh))


def helper_body(code, name):
    """取 MotionHelper 中某构建器的函数体（含花括号），用于检查内部是否带 animation 参数"""
    m = re.search(r'static %s\(\)[^{]*\{' % name, code)
    if not m:
        return ''
    i = m.end() - 1
    depth = 0
    while i < len(code):
        if code[i] == '{':
            depth += 1
        elif code[i] == '}':
            depth -= 1
            if depth == 0:
                return code[m.end() - 1:i + 1]
        i += 1
    return ''


# 12.0b 「会动的」构建器必须自带 animation 参数
#   官方口径：TransitionEffect 无 animation 参数、外层又无 animateTo → 组件直接出现或消失。
#   本断言防止日后有人往 MotionHelper 里塞一个"看起来有、其实不动"的裸构建器
#   （`noTransition` 是有意禁用，不在检查范围）。
ANIMATED_BUILDERS = ('overlayFade', 'dialogCard', 'bottomPanel', 'listItem', 'expandSection')
bad_anim = [b for b in ANIMATED_BUILDERS if 'animation(' not in helper_body(mh, b)]
chk('动效：MotionHelper 内「会动的」构建器均自带 animation 参数',
    not bad_anim, 'missing=%s' % ','.join(bad_anim))

# 12.1 替换范围内不得残留硬编码 .animation({...})
legacy_hits = []
for rel, code in motion_files.items():
    if rel in LEGACY_ANIM_ALLOW and LEGACY_ANIM_ALLOW[rel] is None:
        continue
    allow = LEGACY_ANIM_ALLOW.get(rel, ())
    for m in re.finditer(r'\.animation\(\{', code):
        ln = code.count('\n', 0, m.start()) + 1
        snippet = code.split('\n')[ln - 1].strip()
        if not any(tok in snippet for tok in allow):
            legacy_hits.append('%s:%d %s' % (rel, ln, snippet))
chk('动效：替换范围内无硬编码 .animation({...}) 残留', not legacy_hits, ' | '.join(legacy_hits[:6]))

# 12.2 禁止"裸 TransitionEffect 转场"（无 animation 参数 = 等于没有动效）
bare_tr = []
for rel, code in motion_files.items():
    for m in re.finditer(r'\.transition\(', code):
        arg = call_arg(code, m.end() - 1).strip()
        if 'animation(' in arg or 'combine(' in arg:
            continue
        if 'MotionHelper.' in arg:      # 构建器内部已带 animation 参数
            continue
        if arg == '(TransitionEffect.IDENTITY)':   # 显式禁用，属有意为之
            continue
        bare_tr.append('%s:%d %s' % (rel, code.count('\n', 0, m.start()) + 1, arg[:60]))
chk('动效：无"裸 TransitionEffect 转场"（等于没有动效）', not bare_tr, ' | '.join(bare_tr[:6]))

# 12.3 引用 token 的文件必须已 import；已 import 的必须真的在用（本工程介意未使用导入告警）
no_import = []
for rel, code in motion_files.items():
    for sym in ('MotionConstants', 'MotionHelper'):
        if rel == MOTION_CONST and sym == 'MotionConstants':
            continue  # 自身定义处，内部自引用无需 import
        imported = ('import { %s }' % sym) in code
        used = (sym + '.') in code
        if used and not imported:
            no_import.append('MISSING %s %s' % (rel, sym))
        elif imported and not used:
            no_import.append('UNUSED %s %s' % (rel, sym))
chk('动效：token 导入无缺失、无未使用', not no_import, ' | '.join(no_import[:6]))

# 12.4 用到的构建器必须都有定义
defined = set(re.findall(r'static (\w+)\(', mh))
used = set()
for code in motion_files.values():
    used |= set(re.findall(r'MotionHelper\.(\w+)\(', code))
undef = sorted(used - defined)
chk('动效：所有被调用的 MotionHelper 构建器均已定义', not undef, 'undefined=%s' % ','.join(undef))

# 12.5 本次 L1a 的转场骨架计数（遮罩/卡片分离 + 面板 + 显式禁用）
for build_name, expect in sorted(EXPECT_TRANSITIONS.items()):
    actual = sum(len(re.findall(r'MotionHelper\.%s\(\)' % build_name, c)) for c in motion_files.values())
    chk('动效：%s 使用处数 = %d' % (build_name, expect), actual == expect, 'actual=%d' % actual)

# 12.6 遮罩必须与"载体"成对：每个居中对话框配 1 遮罩、每个底部面板也配 1 遮罩。
#      分离挂载的理由：位移/缩放只能挂内层载体，遮罩是同一棵树的背景层，
#      跟着移动会带出错误的空间暗示（整体平移而非内容入场）。
pair_bad = []
for rel, code in motion_files.items():
    d = len(re.findall(r'MotionHelper\.dialogCard\(\)', code))
    p = len(re.findall(r'MotionHelper\.bottomPanel\(\)', code))
    o = len(re.findall(r'MotionHelper\.overlayFade\(\)', code))
    if o != d + p:
        pair_bad.append('%s dialogCard=%d bottomPanel=%d overlayFade=%d' % (rel, d, p, o))
    if (d > 0 or p > 0) and 'DIALOG_SCALE_FROM' in code:
        pair_bad.append('%s 直接引用 DIALOG_SCALE_FROM（应经 MotionHelper 收口）' % rel)
    if (d > 0 or p > 0) and 'PANEL_TRANSLATE_Y' in code:
        pair_bad.append('%s 直接引用 PANEL_TRANSLATE_Y（应经 MotionHelper 收口）' % rel)
chk('动效：遮罩与载体成对且幅度量已收口', not pair_bad, ' | '.join(pair_bad[:6]))

# 12.7 弹簧曲线只在 MotionConstants 内定义（禁止各处乱引）
spring_owners = sorted(rel for rel, code in motion_files.items() if 'responsiveSpringMotion' in code)
chk('动效：弹簧曲线只在 MotionConstants 内定义',
    spring_owners == [MOTION_CONST], 'owners=%s' % ','.join(spring_owners))

# 12.8 FAB 换边用响应式弹簧；四象限拖拽不得用弹簧（必须跟手）
chk('动效：FAB 换边走响应式弹簧（HomePage / RoutePage）',
    'MotionConstants.springParam()' in motion_files.get('pages/HomePage.ets', '')
    and 'MotionConstants.springParam()' in motion_files.get('pages/RoutePage.ets', ''), '')

# 12.9 不动清单守卫：番茄钟 v4 版式与实况窗链路零改动
pomo = motion_files.get('common/components/PomodoroImmersiveScreen.ets', '')
chk('动效：番茄钟未接入 token（v4 版式契约保持零改动）',
    'MotionConstants' not in pomo and 'MotionHelper' not in pomo
    and 'CHROME_FADE_MILLIS' in pomo, '')
chk('动效：番茄钟 .animation 数量未减少（应为 9）',
    pomo.count('.animation({') == 9, 'count=%d' % pomo.count('.animation({'))

# 12.10 不动清单守卫：骨架屏 shimmer 与 HdsTabs 系统动效
gd = motion_files.get('pages/GoalDetailPage.ets', '')
chk('动效：骨架屏 shimmer 未改动（1200ms 无限循环 + 800ms 卡片）',
    'duration: 1200' in gd and 'iterations: -1' in gd and 'duration: 800' in gd, '')
chk('动效：MainTab HdsTabs animationDuration(300) 未改动',
    'animationDuration(300)' in motion_files.get('pages/MainTab.ets', ''), '')

# 12.11 L1b：列表项增删过渡 / 展开区块过渡的落地计数
#   与 L1a 的 EXPECT_TRANSITIONS 同理 —— 这是个**有意为之的护栏**：
#   新增或删除 L1b 过渡点时必须同步改这里，避免"悄悄退化"或"悄悄扩张"。
# listItem 当前 4 处：AIPage（聊天气泡，实验点）/ NotificationPage（通知增删）/ RoutePage（目标卡片增删）
#                  / TaskDetailPage（L3 步骤增删 —— 2026-09-16 steps 对象化把 key 换成 step.id 后才接上，
#                    对象化前 key 含 index/stepVersion，任何变更都会整段重播进场，转场不成立）
EXPECT_L1B = {'listItem': 4, 'expandSection': 1}
l1b_bad = []
for build_name, expected in EXPECT_L1B.items():
    actual = sum(len(re.findall(r'MotionHelper\.%s\(\)' % build_name, c))
                 for c in motion_files.values())
    if actual != expected:
        l1b_bad.append('%s actual=%d expected=%d' % (build_name, actual, expected))
chk('动效：L1b 列表项 / 展开区块过渡落地且计数正确', not l1b_bad, ' | '.join(l1b_bad))

# 12.12 L1b 最小实验点必须仍在（聊天气泡是"LazyForEach 是否支持组件转场"的判据）
#   判据：真机若生效 → 其余 5 处 LazyForEach 照做、BaseDataSource 无需增量改造；
#         不生效 → 需为 BaseDataSource 补 onDataAdd/onDataDelete。
ai_page = motion_files.get('pages/AIPage.ets', '')
chk('动效：聊天气泡保留 listItem 过渡（LazyForEach 转场实验点）',
    'LazyForEach(' in ai_page and 'MotionHelper.listItem()' in ai_page,
    'experiment point missing')

# 12.13 列表项/展开过渡不得依赖 animateTo 包裹数据变更
#   本工程列表数据在 ViewModel 侧改动（splice/push），逻辑层无法调 UI 侧 animateTo，
#   因此这些构建器必须自带 animation 参数（12.0b 已单独守卫）。
#   此处守卫"数据层未被误引入 animateTo"——ViewModel/DataSource 属纯逻辑层。
logic_anim = [rel for rel in motion_files
              if ('viewmodel/' in rel or 'datasource/' in rel) and 'animateTo' in motion_files[rel]]
chk('动效：逻辑层（viewmodel / datasource）未被引入 animateTo', not logic_anim,
    ' | '.join(logic_anim[:6]))

# ---------------------------------------------------------------- 13. AI 提示词多语言（单一来源 AiPrompts）
# 背景：4 个提示词原硬编码在 model/AppConstants.ets、第 5 个（图片引导）内联在
#   common/services/DeepSeekService.ets，**全部中文** → 英文界面下 AI 也只能返回中文。
#   2026-09-17 起统一迁至 common/constants/AiPrompts.ets：中英两套 + 按语言取用。
# 本段守卫四件事：
#   a) 单一来源不被搬回去（AppConstants 不得再出现提示词、DeepSeekService 不得再内联引导语）
#   b) 两套提示词的**协议**（JSON 键名 / <plan> / high|medium|low / ISO8601）逐字一致，禁止翻译
#   c) 隐私约束不因翻译而弱化（"禁止编造名称""禁止复述画像数字"两语言都必须保留）
#   d) 结构化载荷的标签也必须随语言切换，且载荷层不得残留硬编码中文


def strip_comments_keep_literals(src):
    """只剔块注释 / 行注释，**保留字符串与正则字面量**（保留换行以维持行号）

    ⚠️ 为什么不复用 `strip_comments_and_strings`：它把字符串整段换成 `""`，
    于是"某中文字面量是否还在"这类断言会**恒为真**（历史多次误报）。
    凡断言对象是字符串字面量，必须用本函数。
    """
    out = []
    i = 0
    n = len(src)
    prev_sig = ''
    while i < n:
        c = src[i]
        if c == '/' and i + 1 < n and src[i + 1] == '*':
            j = src.find('*/', i + 2)
            j = n if j < 0 else j + 2
            out.append('\n' * src.count('\n', i, j))
            i = j
        elif c == '/' and i + 1 < n and src[i + 1] == '/':
            j = src.find('\n', i)
            j = n if j < 0 else j
            out.append('\n')
            i = j
        elif c == '/' and prev_sig in ('', '(', ',', '=', ':', '[', '!', '&', '|', '?',
                                       '{', '}', ';', '+', '-', '*', '%', '<', '>'):
            j = i + 1
            in_class = False
            while j < n:
                ch = src[j]
                if ch == '\\':
                    j += 2
                    continue
                if ch == '[':
                    in_class = True
                elif ch == ']':
                    in_class = False
                elif ch == '/' and not in_class:
                    break
                elif ch == '\n':
                    break
                j += 1
            j = min(j + 1, n)
            while j < n and src[j].isalpha():
                j += 1
            out.append(src[i:j])
            prev_sig = 'E'
            i = j
        elif c in ('"', "'", '`'):
            quote = c
            j = i + 1
            while j < n:
                if src[j] == '\\':
                    j += 2
                    continue
                if src[j] == quote:
                    break
                j += 1
            j = min(j + 1, n)
            out.append(src[i:j])
            prev_sig = '"'
            i = j
        else:
            out.append(c)
            if not c.isspace():
                prev_sig = c
            i += 1
    return ''.join(out)


AI_PROMPTS_REL = 'common/constants/AiPrompts.ets'
raw_files = {}
for p in all_ets:
    _rel = os.path.relpath(p, ETS).replace(os.sep, '/')
    try:
        raw_files[_rel] = strip_comments_keep_literals(io.open(p, encoding='utf-8').read())
    except Exception:
        pass

ai = raw_files.get(AI_PROMPTS_REL, '')
_ai_path = os.path.join(ETS, AI_PROMPTS_REL.replace('/', os.sep))
ai_src = io.open(_ai_path, encoding='utf-8').read() if os.path.exists(_ai_path) else ''
chk('i18n：%s 存在（提示词与载荷标签的多语言单一来源）' % AI_PROMPTS_REL,
    AI_PROMPTS_REL in raw_files, 'missing')

# 13.1 切出「中文提示词段」与「英文提示词段」，两侧**分别**校验（只改一侧不得整体通过）
_zh_start = ai_src.find('const SYSTEM_PROMPT_ZH')
_zh_end = ai_src.find('/* --- 时间锚点（中文')
_en_start = ai_src.find('const SYSTEM_PROMPT_EN')
_en_end = ai_src.find('* 4. 载荷标签')
sliced_ok = min(_zh_start, _zh_end, _en_start, _en_end) >= 0 and _zh_start < _zh_end < _en_start < _en_end
chk('i18n：中英两套提示词段可完整切分', sliced_ok,
    'zh=[%d,%d) en=[%d,%d)' % (_zh_start, _zh_end, _en_start, _en_end))
zh_block = ai_src[_zh_start:_zh_end] if sliced_ok else ''
en_block = ai_src[_en_start:_en_end] if sliced_ok else ''

# 13.2 协议必须逐字一致：键名 / <plan> / 优先级取值都是**代码解析用的协议**，翻译即崩
PROTOCOL = ['<plan>', '"goalName"', '"taskName"', '"estimatedTime"', '"priority"', '"deadline"',
            '"steps"', '"high|medium|low"', 'ISO8601']
proto_bad = [k for k in PROTOCOL if k not in zh_block or k not in en_block]
chk('i18n：两套提示词的 JSON 协议键名 / <plan> / 优先级取值完全一致（禁止翻译）',
    not proto_bad, ' | '.join(proto_bad))

# 13.3 格式指令逐条对齐（分段方式 / 字数上限）——翻译时最容易整条丢失
FORMAT_PAIRS = [
    ('一、执行回顾：', '1. Review:'),
    ('二、亮点：', '2. Highlights:'),
    ('三、卡点分析：', '3. Blockers:'),
    ('四、改进建议：', '4. Suggestions:'),
    ('一、整体概况：', '1. Overview:'),
    ('三、风险提示：', '3. Risks:'),
    ('一、今日执行顺序：', '1. Today order:'),
    ('二、排序原则：', '2. Ordering principle:'),
    ('三、提效建议：', '3. Efficiency tips:'),
    ('250 字以内', 'under 200 words'),
    ('200 字以内', 'under 150 words'),
    ('不超过 60 字', 'under 40 words'),
]
fmt_bad = ['%s / %s' % (z, e) for z, e in FORMAT_PAIRS if z not in zh_block or e not in en_block]
chk('i18n：格式指令（分段方式 / 字数上限）两侧逐条对齐', not fmt_bad, ' | '.join(fmt_bad))

# 13.4 隐私约束不得因翻译而弱化（上架合规项，AI 发送范围只给序号不给名称）
PRIVACY_PAIRS = [
    ('严禁复述画像中的具体数字', 'never repeat specific numbers from the profile'),
    ('不要编造名称', 'never invent names'),
    ('严禁编造任务名称', 'never invent task names'),
]
priv_bad = ['%s / %s' % (z, e) for z, e in PRIVACY_PAIRS if z not in zh_block or e not in en_block]
chk('i18n：隐私约束（禁止编造名称 / 禁止复述画像数字）两侧均保留', not priv_bad,
    ' | '.join(priv_bad))

# 13.5 单一来源守卫
BANNED_SYMBOLS = ['DEEPSEEK_SYSTEM_PROMPT', 'GOAL_REVIEW_SYSTEM_PROMPT',
                  'GLOBAL_REVIEW_SYSTEM_PROMPT', 'TODAY_PRIORITY_SYSTEM_PROMPT']
resurrected = sorted(rel for rel, txt in raw_files.items()
                     if any(b in txt for b in BANNED_SYMBOLS))
chk('i18n：已删除的提示词常量在全工程无残留引用', not resurrected,
    ' | '.join(resurrected[:6]))

app_const = raw_files.get('model/AppConstants.ets', '')
chk('i18n：AppConstants 不再持有提示词（单一来源 = AiPrompts）',
    '你是' not in app_const and 'MAX_INPUT_LENGTH' in app_const, 'prompt moved back?')

ds_raw = raw_files.get('common/services/DeepSeekService.ets', '')
chk('i18n：DeepSeekService 不再内联图片引导语（改取 AiPrompts.imageGuide）',
    'const IMAGE_GUIDE_PROMPT' not in ds_raw and 'prompts.imageGuide' in ds_raw,
    'inline guide revived?')


def obj_keys(decl):
    """取 `const <decl> ... = {` 起、按花括号配对切出的字段名集合

    不用正则直接跨块匹配：AiPromptSet 的两个字面量都以缩进的 `}` 结尾，
    `\\n\\}` 会一路吃到外层函数，把两套字段合并（曾因此误判为"字段翻倍"）。

    又：键名判定必须锚在**行首**（`\\n\\s*(\\w+)\\s*:`）——载荷标签的值本身含冒号
    （如 `'使用天数:'`），否则会把值里的 `使用天数` 当成字段名（曾因此误报 13 个"多余字段"）。
    """
    i = ai.find(decl)
    if i < 0:
        return set()
    i = ai.find('{', i)
    depth = 0
    j = i
    while j < len(ai):
        if ai[j] == '{':
            depth += 1
        elif ai[j] == '}':
            depth -= 1
            if depth == 0:
                break
        j += 1
    return set(re.findall(r'\n\s*(\w+)\s*:', ai[i:j]))


def iface_keys(name):
    m = re.search(r'export interface %s\s*\{(.*?)\n\}' % name, ai, re.S)
    return set(re.findall(r'^\s*(\w+)\s*:', m.group(1), re.M)) if m else set()


PROMPT_KEYS = iface_keys('AiPromptSet')
LABEL_KEYS = iface_keys('AiPayloadLabels')

# 13.6 两套字面量必须与接口字段**完全相等**（漏一个 = ArkTS 编译失败，本工程无法 CLI 编译，只能靠这里守）
prompt_lit_bad = []
for _lit in ('const en: AiPromptSet', 'const zh: AiPromptSet'):
    _got = obj_keys(_lit)
    if _got != PROMPT_KEYS:
        prompt_lit_bad.append('%s missing=%s extra=%s'
                              % (_lit, sorted(PROMPT_KEYS - _got), sorted(_got - PROMPT_KEYS)))
chk('i18n：AiPromptSet 两套字面量字段齐全（%d 项）' % len(PROMPT_KEYS),
    not prompt_lit_bad, ' | '.join(prompt_lit_bad))

label_lit_bad = []
for _lit in ('const LABELS_ZH: AiPayloadLabels', 'const LABELS_EN: AiPayloadLabels'):
    _got = obj_keys(_lit)
    if _got != LABEL_KEYS:
        label_lit_bad.append('%s missing=%s extra=%s'
                             % (_lit, sorted(LABEL_KEYS - _got), sorted(_got - LABEL_KEYS)))
chk('i18n：AiPayloadLabels 中英两套标签字段齐全（%d 项）' % len(LABEL_KEYS),
    not label_lit_bad, ' | '.join(label_lit_bad))

# 13.7 使用侧引用必须全部落在接口字段内（拼错字段名 = 编译失败）
pa_raw = raw_files.get('common/services/ProfileAnalyzerService.ets', '')
used_labels = set(re.findall(r'\bL\.(\w+)', pa_raw))
used_prompts = (set(re.findall(r'\bprompts\.(\w+)', ds_raw)) |
                set(re.findall(r'getAiPromptSet\(\)\.(\w+)', ds_raw)))
label_ref_bad = sorted(used_labels - LABEL_KEYS)
prompt_ref_bad = sorted(used_prompts - PROMPT_KEYS)
chk('i18n：载荷标签引用无未定义字段', not label_ref_bad, ' | '.join(label_ref_bad))
chk('i18n：提示词字段全部被真实取用（防"加了字段忘了接"）',
    not prompt_ref_bad and PROMPT_KEYS <= used_prompts,
    'invalid=%s unused=%s' % (prompt_ref_bad, sorted(PROMPT_KEYS - used_prompts)))

# 13.8 语言判定口径（必须与屏幕上实际渲染的语言一致）
chk('i18n：语言判定优先读应用偏好、退回系统语言',
    'getAppPreferredLanguage()' in ai and 'getSystemLanguage()' in ai, '')
chk('i18n：语言判定结果进程内缓存（与 setAppPreferredLanguage 冷启动生效的口径一致）',
    'let cachedLang' in ai and 'if (cachedLang.length > 0)' in ai, '')
chk('i18n：仅 en* 判为英文（与 base=中文 的资源回退口径严格一致）',
    "startsWith('en')" in ai, '')

# 13.9 载荷层不得残留硬编码中文标签（否则英文下会把中文串塞进英文提示词）
ZH_LABEL_LITERALS = ["'[用户画像]'", "'使用天数:'", "'目标总数:'", "'今日:'", "'今日专注:'",
                     "'新用户'", "'完成任务'", "'分钟'", "'次'", "'任务:'", "',已完成'",
                     "'任务完成率:'", "'步骤:'", "'预估总耗时:'", "'任务明细:'", "'Q1重要紧急'",
                     "'未分类'", "',截止'", "'总计未完成'", "',超时完成'", "',按时完成'"]
leaked = [lit for lit in ZH_LABEL_LITERALS if lit in pa_raw]
chk('i18n：载荷层（ProfileAnalyzerService）无硬编码中文标签残留', not leaked, ' | '.join(leaked))
lost_labels = [lit for lit in ZH_LABEL_LITERALS if lit not in ai]
chk('i18n：中文载荷标签集中于 AiPrompts', not lost_labels, ' | '.join(lost_labels))

# 13.10 占位符回填必须同时认「任务N」与「Task N」（否则英文回复里的 Task 1 回填不了真实名称）
chk('i18n：占位符回填同时支持「任务N」与「Task N」（单次扫描，无级联替换）',
    '任务|Task|task' in pa_raw and 'RegExpExecArray' in pa_raw, 'tokenRegex missing')

# 13.11 中文时间锚点正文形态不得被顺手改动（该格式已被线上验证可用）
chk('i18n：中文时间锚点正文形态未变（年月日 + 星期）',
    all(k in ai for k in ("'## 当前时间'", "'年'", "'月'", "'日 '", "'星期'")),
    'anchor format changed')

# ---------------------------------------------------------------- 14. 跨文件符号：出现即必须 import
# 背景（2026-09-17 真实编译错）：steps 对象化把 TaskStep 用进了 GoalDetailPage，
#   但 import 漏了 → `Cannot find name 'TaskStep'`。本工程无 hvigorw、CLI 不能编译，
#   这类"漏 import"编译错此前**没有任何 AI 侧手段**能拦住，只能靠用户在 DevEco 撞上。
# 做法：维护一张**显式符号表**（跨文件消费的类型/函数），任何文件正文出现即必须出现在
#   该文件 import 区。显式表而非自动推导：自动推导要枚举 ArkUI 内置组件 + SDK 全局类型，
#   误报量不可控；显式表零误报，代价是新符号要登记一行（与 EXPECT_* 计数护栏同一风格）。
TRACKED_SYMBOLS = {
    # steps 对象化（2026-09-16，TaskModels）
    'TaskStep': 'model/TaskModels.ets',
    'TaskStepJSON': 'model/TaskModels.ets',
    'generateStepId': 'model/TaskModels.ets',
    'isStepCompleted': 'model/TaskModels.ets',
    'hydrateAiGeneratedTask': 'model/TaskModels.ets',
    'snapshotAiGeneratedTask': 'model/TaskModels.ets',
    # AI 提示词多语言（2026-09-17，AiPrompts）
    'AiPromptSet': 'common/constants/AiPrompts.ets',
    'AiPayloadLabels': 'common/constants/AiPrompts.ets',
    'AiPromptLang': 'common/constants/AiPrompts.ets',
    'getAiPromptSet': 'common/constants/AiPrompts.ets',
    'getAiPayloadLabels': 'common/constants/AiPrompts.ets',
    'formatPromptDate': 'common/constants/AiPrompts.ets',
    'resolveAiPromptLang': 'common/constants/AiPrompts.ets',
    # 完成反馈（2026-09-17，触觉 + 撒花）
    'hapticFeedback': 'common/services/HapticFeedback.ets',
    'ConfettiOverlay': 'common/components/ConfettiOverlay.ets',
}

sym_code = {}   # rel -> 剔注释（保留代码与字符串）后的全文
sym_files = []
for p in all_ets:
    rel = os.path.relpath(p, ETS).replace(os.sep, '/')
    try:
        sym_code[rel] = strip_comments_keep_literals(io.open(p, encoding='utf-8').read())
        sym_files.append(rel)
    except Exception:
        pass

missing_import = []
for rel in sym_files:
    code = sym_code[rel]
    # ⚠️ 本工程源码无分号（ArkTS 风格），**不能用 `;` 当语句边界**——
    #   `[^;]*;` 会一路吃到后文的分号，把 head 区撑大造成漏报。
    # import 语句统一以 `from '<path>'` 结尾 → 取最后一个 from 匹配作为 head 边界。
    last_from = None
    for m in re.finditer(r"from\s*['\"][^'\"]*['\"]", code):
        last_from = m
    head_end = last_from.end() if last_from else 0
    head, body = code[:head_end], code[head_end:]
    # re-export 不算"使用"：`export { TaskStep, ... } from './TaskModels'` 只是转发，
    # 不要求本文件 import（否则 Models barrel 会被误报——曾把全部 barrel 项判为缺失）
    body = re.sub(r"export\s*\{[^}]*\}\s*from\s*['\"][^'\"]*['\"]", ' ', body)
    for sym, def_file in TRACKED_SYMBOLS.items():
        if rel == def_file:
            continue  # 定义文件本身
        if not re.search(r'\b%s\b' % sym, body):
            continue  # 未使用
        if re.search(r'\b%s\b' % sym, head):
            continue  # 已 import（经 Models barrel 或直连均可）
        missing_import.append('%s: %s (def in %s)' % (rel, sym, def_file))
chk('符号：跨文件符号"出现即 import"（%d 个受追踪符号）' % len(TRACKED_SYMBOLS),
    not missing_import, ' | '.join(missing_import[:6]))

# ---------------------------------------------------------------- 15. 统一完成链路（步骤 ⟷ 任务 ⇔ 目标进度）
# 背景（2026-09-17 用户反馈的三个缺陷，同一个根上长出的三张脸）：
#   a) 任务详情页底部「标记完成」与上面"逐个勾步骤"是**两条独立链路**——前者只写 L2.status
#      + 翻转 L4，**完全不碰 L3 步骤** ⇒ 点了完成，上面的步骤圆圈纹丝不动；
#   b) 路线页目标卡片进度环读的是 filteredGoals 的**独立快照**（goalDataSource），
#      而同步信号 goalCount 只统计**数量** ⇒ 纯进度变化不发 notifyDataReload ⇒ 与目标
#      详情页显示不同步；
#   c) 目标详情页进度环读 `@Param goal`（**对象引用**），观察链可能被 @ReusableV2 / 缓存
#      打断而静默失效。
# 修法：
#   完成语义**收口到 L2** —— updateStep（逐个勾）与 setTaskCompletion（底部按钮批量设定）
#     遵守同一条不变式「全部步骤完成 ⇔ status = COMPLETED」，两个入口不再各走各的；
#   进度变化用 GOAL_PROGRESS_CHANGED 事件广播，路线页订阅后精确 reload 快照；
#   进度环改吃**原始类型** @Param progress（原始类型必然刷新，对象引用不一定）。
# 本段是护栏：日后新增 / 删除上述任一环节，都必须显式改这里，避免"悄悄退化"。
def rel_stripped(rel):
    p = os.path.join(ETS, rel.replace('/', os.sep))
    if not os.path.exists(p):
        return ''
    return strip_comments_keep_literals(io.open(p, encoding='utf-8').read())


def method_body(code, name):
    """按名字取方法体（含花括号）。用括号配平找结尾，避免贪婪正则吃过头。

    与 12.0b 的 helper_body 的区别：后者只认 `static xxx()`（专给 MotionHelper 用），
    本函数认实例方法（含 private/public 修饰符与返回类型标注）。
    """
    m = re.search(r'\n\s*(?:private\s+|public\s+|protected\s+)?%s\s*\([^)]*\)\s*:\s*[^{\n]*\{' % name, code)
    if not m:
        return ''
    i = m.end() - 1
    depth = 0
    while i < len(code):
        if code[i] == '{':
            depth += 1
        elif code[i] == '}':
            depth -= 1
            if depth == 0:
                return code[m.end() - 1:i + 1]
        i += 1
    return ''


_tdp = rel_stripped('pages/TaskDetailPage.ets')
_gdp = rel_stripped('pages/GoalDetailPage.ets')
_rtp = rel_stripped('pages/RoutePage.ets')
_bus = rel_stripped('common/event/AppEventBus.ets')
_rvm = rel_stripped('viewmodel/RoutePageViewModel.ets')

# 15.1 原子设定方法：签名 + 四个动作齐全（L3 批量 → L2 状态 → L4 按值 → L1 重算）
_setc = method_body(_rvm, 'setTaskCompletion')
chk('完成链路：RouteVM.setTaskCompletion(goalId, taskId, completed) 签名不变',
    'setTaskCompletion(goalId: Id, taskId: Id, completed: boolean): boolean' in _rvm, '')
chk('完成链路：setTaskCompletion 批量写 L3（steps[i].isCompleted = completed）',
    'steps[i].isCompleted = completed' in _setc, 'body_len=%d' % len(_setc))
chk('完成链路：setTaskCompletion 维护 actualCompletionTime 不变式',
    'actualCompletionTime = Date.now()' in _setc and 'actualCompletionTime = 0' in _setc, '')
chk('完成链路：setTaskCompletion 按值同步 L4 并重算 L1 进度',
    'TASK_COMPLETION_SYNCED' in _setc and 'updateGoalProgressByTasks(goalId)' in _setc, '')

# 15.2 任务详情页：底部按钮必须走原子方法、完成态必须派生、死字段必须清零
chk('完成链路：TaskDetailPage 底部按钮走 routeVM.setTaskCompletion',
    'routeVM.setTaskCompletion(' in _tdp, '')
chk('完成链路：TaskDetailPage 完成态派生自 L2（@Computed isTaskCompleted）',
    'get isTaskCompleted(): boolean' in _tdp and 'l2.status === TaskStatus.COMPLETED' in _tdp, '')
# this.task.isCompleted 只允许 3 处：getter 兜底返回 1 + 两条分支各赋值 1。
# 任何 UI 属性链直读（`this.task.isCompleted ?` / `Button(this.task.isCompleted`）
# 都会让计数上涨 —— 那正是"又长出第二套完成口径"的信号。
_tdp_direct = len(re.findall(r'this\.task\.isCompleted', _tdp))
chk('完成链路：TaskDetailPage 完成态不再由 UI 直读 this.task.isCompleted（应恰为 3 处）',
    _tdp_direct == 3, 'actual=%d' % _tdp_direct)
chk('完成链路：TaskDetailPage 死字段 stepVersion 已清除',
    'stepVersion' not in _tdp, '')
chk('完成链路：底部按钮为三态动态文案（完成全部步骤 / 标记完成 / 已完成·取消）',
    'btn_complete_all_steps' in _tdp and 'btn_mark_complete' in _tdp
    and 'btn_completed_undo' in _tdp, '')
chk('完成链路：任务详情页底部有步骤进度条（已完成 N/M 步）',
    'task_detail_steps_progress_prefix' in _tdp and 'task_detail_steps_progress_suffix' in _tdp
    and 'ProgressType.Linear' in _tdp, '')

# 15.3 进度同步：事件定义 / 发送 / 订阅三端必须闭合
chk('进度同步：AppEventBus 定义 GOAL_PROGRESS_CHANGED + 载荷 + 工厂',
    'GOAL_PROGRESS_CHANGED' in _bus and 'GoalProgressChangedPayload' in _bus
    and 'buildGoalProgressChangedPayload' in _bus, '')
chk('进度同步：RouteVM 在 4 处进度出口广播（updateMilestone / 空任务 / 逐任务重算 / 云落地）',
    len(re.findall(r'this\.notifyGoalProgressChanged\(', _rvm)) == 4,
    'actual=%d' % len(re.findall(r'this\.notifyGoalProgressChanged\(', _rvm)))
# 为什么云落地也要广播（2026-09-17 补）：`isGoalDataSourceStale()` 只比「数量 / 首项 id」，
#   `filteredGoals`(@Computed) 也不依赖单个目标的 progress ⇒ 合并只改变进度时路线页
#   既不同步数据源也不重渲染，卡片进度环停在旧值（= 用户报的"跨设备进度不同步"）。
#   这条断言单独锚定 applyCloudSnapshot 内必须有广播，防止后续被误删。
chk('进度同步：RouteVM.applyCloudSnapshot 落地后广播进度变化（否则卡片进度环停在旧值）',
    re.search(r'applyCloudSnapshot\([\s\S]*?notifyGoalProgressChanged\(', _rvm) is not None, '')
chk('进度同步：RoutePage 订阅后在回调里 reload 快照（forceSyncGoalDataSource）',
    'GOAL_PROGRESS_CHANGED' in _rtp
    and re.search(r'onGoalProgressChanged[\s\S]{0,400}?forceSyncGoalDataSource', _rtp) is not None, '')
chk('进度同步：RoutePage 退出时按 id 注销订阅（防多实例串台）',
    'eventBus.off(EventType.GOAL_PROGRESS_CHANGED' in _rtp, '')

# 15.4 进度环吃原始类型（对象引用观察链不可靠）
chk('进度同步：GoalHeaderSection 用 @Param progress（原始类型，必然刷新）',
    '@Param progress: number' in _gdp, '')
chk('进度同步：GoalHeaderSection 的进度展示均读 this.progress，且调用处传 this.goal.progress',
    len(re.findall(r'this\.progress', _gdp)) >= 4
    and re.search(r'GoalHeaderSection\(\{[\s\S]{0,200}?progress:\s*this\.goal\.progress', _gdp) is not None, '')

# 15.5 三语言资源齐备（缺 key 会静默回退 base：中文用户看不出来，英文用户会看到中文）
_new_keys = ('btn_complete_all_steps', 'btn_completed_undo',
             'task_detail_steps_progress_prefix', 'task_detail_steps_progress_suffix',
             'task_detail_complete_all_hint')
_missing_keys = []
for _lang in ['base', 'zh_CN', 'en_US']:
    _p = os.path.join(res_dir, _lang, 'element', 'string.json')
    try:
        _doc = json.load(io.open(_p, encoding='utf-8'))
        _kv = {}
        for _it in _doc.get('string', []):
            _kv[_it.get('name')] = _it.get('value')
        _miss = [k for k in _new_keys if not _kv.get(k)]
        if _miss:
            _missing_keys.append('%s: %s' % (_lang, ','.join(_miss)))
    except Exception as e:
        _missing_keys.append('%s: %s' % (_lang, e))
chk('完成链路：三语言均含 5 个新文案 key（缺 key 会静默回退 base）',
    not _missing_keys, ' | '.join(_missing_keys))

# ---------------------------------------------------------------- 16. 改造遗留标识符（"签名改了、调用点没改"）
# 背景（2026-09-17 真实编译错）：`Cannot find name 'stepText'` @ TaskDetailPage:462。
#   steps 对象化（2026-09-16）把 `StepItemBuilder(stepText, isCompleted, index)` 的入参
#   换成了 `(step: TaskStep, index)`，**但有一个 onClick 调用点漏改**，残留的 `stepText`
#   已无任何声明。本工程无 hvigorw、CLI 不能编译 ⇒ 这类错此前只能靠用户在 DevEco 撞上。
# 做法：登记"已被重构淘汰的标识符"黑名单；凡在**代码区**（注释不算）出现即失败。
#   与第 14 节 TRACKED_SYMBOLS（出现即必须 import）互补：那条管"该引的没引"，
#   本条管"不该在的还在"。
# ⚠️ 加新条目时务必确认该名字在**全工程**已无合法用途（同名局部变量/参数会误报）——
#    例：`stepText` 仍是 RouteVM.addStep 的合法形参，故只对 TaskDetailPage 生效。
RETIRED_IDENTIFIERS = {
    # 标识符 -> 仍允许出现的文件集合（除这些文件外，出现在代码区即失败）
    # stepVersion：**2026-09-17 已全工程清零**（TaskDetailPage 早先删除；GoalDetailPage 的
    #   @Local / 两处 @Param / 两处传参 / 自增共 6 处同批删除）。当时保留它的理由是
    #   "@Param 变更触发整卡重渲染，可能掩盖别的非响应式绑定"；核实后确认步骤行直读
    #   `step.isCompleted`，而 TaskStep 是 @ObservedV2 + @Trace（`task.steps` 亦 @Trace）
    #   ⇒ 精确响应式已覆盖，版本号兜底只剩"每次勾选白刷整段任务列表"的副作用。
    #   故白名单一并撤销：全工程代码区再出现即失败（注释里说明历史可以）。
    'stepVersion': {'allow': set()},
    'stepText': {'allow': {'viewmodel/RoutePageViewModel.ets'}},  # addStep 形参合法
}

_retired_hits = []
for _p in all_ets:
    _rel = os.path.relpath(_p, ETS).replace(os.sep, '/')
    try:
        _code = strip_comments_keep_literals(io.open(_p, encoding='utf-8').read())
    except Exception:
        continue
    for _name, _cfg in RETIRED_IDENTIFIERS.items():
        if _rel in _cfg['allow']:
            continue
        for _m in re.finditer(r'\b%s\b' % _name, _code):
            _ln = _code.count('\n', 0, _m.start()) + 1
            _retired_hits.append('%s:%d %s' % (_rel, _ln, _name))
chk('遗留：已被重构淘汰的标识符（%d 个）未在代码区残留' % len(RETIRED_IDENTIFIERS),
    not _retired_hits, ' | '.join(_retired_hits[:6]))

# 16.1 StepItemBuilder 签名与调用点一致（对象化后入参是 TaskStep 对象，不是文本）
_tdp_steps_builder = re.search(r'StepItemBuilder\(([^)]*)\)\s*:\s*void', _tdp)
chk('遗留：StepItemBuilder 入参为 (step: TaskStep, index: number)',
    _tdp_steps_builder is not None
    and 'step: TaskStep' in _tdp_steps_builder.group(1)
    and 'index: number' in _tdp_steps_builder.group(1),
    _tdp_steps_builder.group(1) if _tdp_steps_builder else 'signature not found')

# 16.2 @Builder 调用点参数个数必须与签名相容
# 这是"签名改了、调用点没改"的**通用**拦网（16 节那条黑名单只能拦住**已知**的旧名字，
# 新重构产生的新旧名字拦不住）。做法：解析全工程 @Builder 声明 → 逐个调用点比对实参个数。
# 容差：带默认值的形参可省略 ⇒ 允许 [必填数, 形参总数] 区间。
# 只查 @Builder（本项目唯一大量使用位置传参的构造），@ComponentV2 结构体走 `{...}` 对象式，
# 属性名绑定由框架校验，不在本检查范围（也避免了误报）。


def _split_top(s):
    """按顶层逗号切分（忽略 () [] {} <> 内与字符串/模板串内的逗号）"""
    parts = []
    depth = 0
    cur = []
    i = 0
    n = len(s)
    q = None
    while i < n:
        c = s[i]
        if q is not None:
            cur.append(c)
            if c == '\\':
                if i + 1 < n:
                    cur.append(s[i + 1])
                    i += 2
                    continue
            elif c == q:
                q = None
            i += 1
            continue
        if c in ('"', "'", '`'):
            q = c
            cur.append(c)
            i += 1
            continue
        if c in '([{<':
            depth += 1
        elif c in ')]}>':
            depth -= 1
        elif c == ',' and depth == 0:
            parts.append(''.join(cur))
            cur = []
            i += 1
            continue
        cur.append(c)
        i += 1
    if ''.join(cur).strip():
        parts.append(''.join(cur))
    return parts


_builder_sig = {}   # name -> (required, total, def_rel, def_line)
for _p in all_ets:
    _rel = os.path.relpath(_p, ETS).replace(os.sep, '/')
    try:
        _code = strip_comments_keep_literals(io.open(_p, encoding='utf-8').read())
    except Exception:
        continue
    for _m in re.finditer(r'@Builder\s*\n\s*(?:private\s+|public\s+)?(\w+)\s*\(([^)]*)\)', _code):
        _params = _m.group(2).strip()
        _ps = [] if not _params else _split_top(_params)
        _req = len([x for x in _ps if '=' not in x])
        _builder_sig[_m.group(1)] = (_req, len(_ps), _rel, _code.count('\n', 0, _m.start()) + 1)

_builder_bad = []
for _p in all_ets:
    _rel = os.path.relpath(_p, ETS).replace(os.sep, '/')
    try:
        _code = strip_comments_keep_literals(io.open(_p, encoding='utf-8').read())
    except Exception:
        continue
    for _name, (_req, _tot, _df, _dl) in _builder_sig.items():
        for _m in re.finditer(r'(?:this\.)?%s\s*\(' % re.escape(_name), _code):
            _ln = _code.count('\n', 0, _m.start()) + 1
            if _rel == _df and abs(_ln - _dl) <= 1:
                continue  # 定义处自身
            _i = _code.find('(', _m.start())
            _depth = 0
            _j = _i
            while _j < len(_code):
                if _code[_j] == '(':
                    _depth += 1
                elif _code[_j] == ')':
                    _depth -= 1
                    if _depth == 0:
                        break
                _j += 1
            _args = _code[_i + 1:_j]
            if _args.strip().startswith('{'):
                continue  # @ComponentV2 结构体的对象式调用
            _n = 0 if not _args.strip() else len(_split_top(_args))
            if not (_req <= _n <= _tot):
                _builder_bad.append('%s:%d %s() 实参 %d 个，签名需 %d~%d 个（定义 %s:%d）'
                                    % (_rel, _ln, _name, _n, _req, _tot, _df, _dl))
chk('遗留：@Builder 调用点实参个数与签名相容（%d 个 @Builder）' % len(_builder_sig),
    not _builder_bad, ' | '.join(_builder_bad[:6]))

# ---------------------------------------------------------------- 17. 载荷自洽化（跨设备进度 / 完成一致性）
# 背景（2026-09-17 用户报障："跨设备进度与完成状态不同步"）：
#   `goalsJson` / `todosJson` 是两条**独立**合并单元，同一个完成事实存了两份副本
#   （goals[G].tasks[T].status + steps[].isCompleted  ↔  taskList[T].isCompleted）；
#   合并时二者各自按条目 updatedAt 做整块 LWW（L2/L3 不递归），可各选一端 ⇒ 落地后自相矛盾：
#   首页说已完成、路线页/目标详情说未完成。`progress` 又是"持久化 + 派生"的冗余字段，
#   整块 LWW 会把旧值一并带回来 ⇒ 表现成"进度没同步"。
# 修复：在「合并之后 / 指纹对比之前 / 首传分支之前」插入 `reconcileCompletionFacts`：
#   ① 对齐 L2 ⇄ L4 完成事实（含 L3 步骤，与本地 syncStepFromTodoCompletion 同语义）
#   ② 从 L2 tasks 重算 L1 progress，使 progress 成为该目标块的**纯函数**、不再可能分裂。
# ⚠️ reconcile **必须是纯函数**（禁 Date.now / Math.random）：两端合并输入不同却要各自算出
#   同一个结果，一旦引入本机时钟就永远算不出同值 ⇒ 指纹恒不相等 ⇒ 上传风暴。
# 2026-09-17 追加 A″（同类对称裁决，见 17b）：完成事实的裁决轴从「对端任意改动时刻」换成
#   「对端完成态最后变更时刻」，修掉"改个名字就把对端完成压掉"的丢更新。
_rsc = rel_stripped('common/services/CloudSyncService.ets')
_rec = method_body(_rsc, 'reconcileCompletionFacts')

chk('自洽化：CloudSyncService 提供 reconcileCompletionFacts',
    'reconcileCompletionFacts' in _rsc and len(_rec) > 0, 'body_len=%d' % len(_rec))

_i_merge = _rsc.find('this.mergeTopLevelArray(data.todosJson')
_i_rec = _rsc.find('reconcileCompletionFacts(rawMergedGoals, rawMergedTodos)')
_i_fp = _rsc.find('payloadFingerprint(mergedGoals')
_i_first = _rsc.find('if (cloudRecord === null)')
chk('自洽化：调用点在「合并之后 / 指纹对比之前」（含首传分支之前）',
    _i_merge >= 0 and _i_rec > _i_merge and _i_fp > _i_rec and _i_first > _i_rec,
    'merge=%d rec=%d fp=%d firstNull=%d' % (_i_merge, _i_rec, _i_fp, _i_first))

chk('自洽化：自洽结果被用作 mergedGoals / mergedTodos 载荷',
    'const mergedGoals: string = reconciled.goalsJson' in _rsc
    and 'const mergedTodos: string = reconciled.todosJson' in _rsc, '')

chk('自洽化：reconcile 内禁用 Date.now / Math.random（纯函数硬约束）',
    'Date.now()' not in _rec and 'Math.random(' not in _rec,
    'non-deterministic call found in reconcile body')

chk('自洽化：reconcile 不改写任何 updatedAt（禁止伪造"本机更新"）',
    re.search(r"\.updatedAt\s*=[^=]|\[['\"]updatedAt['\"]\]\s*=[^=]", _rec) is None,
    'updatedAt written in reconcile body')

chk('自洽化：reconcile 不改写 completionUpdatedAt（时间轴只能由本机交互推进）',
    re.search(r"task\.completionUpdatedAt\s*=|completionUpdatedAt['\"]\]\s*=[^=]", _rec) is None, '')

# A″（2026-09-17）：裁决由"跨类型比较"改为"同类对称比较"
#   旧规则 `l4At >= this.itemStamp(goal)` 拿"完成时刻"比"目标块任意改动时刻"→ 平板改个目标名
#   就能把手机声明的完成压掉。新规则两侧各取**自己的完成态时间轴**：L2 = task.completionUpdatedAt，
#   L4 = todo 自身 itemStamp（勾选/取消/改标题都算，但远窄于 goal.updatedAt）。
chk('自洽化：裁决规则为「完成态时间轴对比」（同类型、相等时完成优先）',
    re.search(r'const completed: boolean = tNo <= tDone', _rec) is not None
    and "const c2: number = this.readNumber(task, 'completionUpdatedAt')" in _rec
    and "const c4: number = this.readNumber(todo, 'completionUpdatedAt')" in _rec, '')

chk('自洽化：旧跨类型规则已彻底移除（不得拿 l2At/l4At 或 goal 级时间戳做完成裁决）',
    # ⚠️ 不要写成 `\b(?:l2At|l4At)\s*>` 这种宽泛形式：A″ 的回退链里合法存在
    #    `l4At > 0 ? l4At : itemStamp(todo)`（这是"缺失判定"，不是比较轴）。
    #    只禁"把完成时刻与某个 itemStamp 相互比较"这一形态。
    'itemStamp(goal)' not in _rec
    and re.search(r'\b(?:l2At|l4At)\s*[<>]=?\s*this\.itemStamp', _rec) is None
    and re.search(r'this\.itemStamp\(\w+\)\s*[<>]=?\s*\w*l[24]At', _rec) is None,
    'cross-type comparison resurfaced in reconcile')

chk('自洽化：L4 侧比较轴取待办自己的完成态轴（非完成类编辑不再有权改判完成）',
    _rec.count("this.readNumber(todo, 'completionUpdatedAt')") == 1
    and _rec.count('this.itemStamp(todo)') >= 2, 'itemStamp(todo)=%d' % _rec.count('this.itemStamp(todo)'))

chk('自洽化：两侧均保留「老数据缺轴 → 退化既有时间戳」的回退链',
    'c2 > 0 ? c2 : l2At' in _rec
    and 'c4 > 0 ? c4 : this.itemStamp(todo)' in _rec
    and 'c4 > 0 ? c4 : (l4At > 0 ? l4At : this.itemStamp(todo))' in _rec
    and 'tNo = c2' in _rec, '')

chk('自洽化：完成事实两侧都写回（L2 status + L3 steps + L4 isCompleted）',
    "task['status']" in _rec and "todo['isCompleted']" in _rec
    and re.search(r"isCompleted'\]\s*=\s*completed", _rec) is not None, '')

chk('自洽化：progress 重算与 RouteVM.updateGoalProgressByTasks 同公式',
    'Math.round((completedCount / tasks.length) * 100)' in _rec
    and "goal['progress'] = newProgress" in _rec, '')

chk('自洽化：无 L2 任务的目标不覆盖 progress（保留 milestones 主导口径）',
    re.search(r'if \(tasks\.length === 0\) continue', _rec) is not None, '')

chk('自洽化：完成时刻取两侧较大值（单调不减，保证两端收敛不反转）',
    'Math.max(l2At, l4At)' in _rec, '')

# 17b ---------------------------------------------------------------- A″ 字段落地（完成态时间轴）
# 为什么要这条轴：`actualCompletionTime` 语义是"首次完成时刻"（取消即归零），它承担不了
#   "谁最后改过完成态"的裁决——取消完成这个动作在它上面不留痕迹。旧规则只能退而拿"完成时刻"
#   去比"对端任意改动时刻"，于是被改名/调优先级这类无关改动误伤（跨设备丢更新）。
# `completionUpdatedAt` 与它解耦：**完成与取消都刷新**，只反映完成态本身。
# 落地三要件缺一不可：① 模型声明 + 落盘（否则跨设备恒为 0，裁决退化回旧行为）
#                    ② 写入点打点（updateStep / setTaskCompletion / L4→L2 三步链路全覆盖）
#                    ③ reconcile 读取（见 17 节的裁决断言）
_taskm = rel_stripped('model/TaskModels.ets')
chk('完成态时间轴：AiGeneratedTaskJSON 声明 completionUpdatedAt（可选键，老数据无此键）',
    re.search(r'completionUpdatedAt\?\s*:\s*number', _taskm) is not None, '')
chk('完成态时间轴：AiGeneratedTask 持有 @Trace completionUpdatedAt 且默认 0',
    re.search(r'@Trace\s+completionUpdatedAt\s*:\s*Timestamp\s*=\s*0', _taskm) is not None, '')
chk('完成态时间轴：fromJSON 读取（缺失 / NaN 兜底 0）',
    "typeof json.completionUpdatedAt === 'number'" in _taskm
    and 'json.completionUpdatedAt : 0' in _taskm, '')
chk('完成态时间轴：toJSON 落盘（不落盘则跨设备恒为 0，裁决退化）',
    'completionUpdatedAt: this.completionUpdatedAt' in _taskm, '')
_stamp_sites = len(re.findall(r'task\.completionUpdatedAt\s*=\s*Date\.now\(\)', _rvm))
chk('完成态时间轴：3 处 L2 完成态写入点均打点（updateStep / setTaskCompletion / L4→L2 同步）',
    _stamp_sites == 3, 'sites=%d' % _stamp_sites)
chk('完成态时间轴：3 处打点都有完成态变化守卫（无条件打点＝每次勾选都白跑一轮上传）',
    len(re.findall(r'const wasTaskCompleted: boolean = task\.status === TaskStatus\.COMPLETED',
                   _rvm)) == 3
    and _rvm.count('if (wasTaskCompleted !== ') == 3, '')

# L4 侧同款（2026-09-17 补齐）：L4 原本拿条目 `updatedAt` 当完成轴，而它会被**非完成类操作**
#   刷新（专注累计 / 改截止 / 目标改名级联 / 墓碑）⇒ 对端在更晚时刻的一次无关编辑，
#   仍能把本机刚声明的完成判成未完成。补上独立轴后，两侧彻底同类、对称。
_hom = rel_stripped('model/HomeModels.ets')
chk('完成态时间轴：HomeTodoItemJSON 声明 completionUpdatedAt（可选键，老数据无此键）',
    re.search(r'completionUpdatedAt\?\s*:\s*number', _hom) is not None, '')
chk('完成态时间轴：HomeTodoItem 持有 @Trace completionUpdatedAt 且默认 0',
    re.search(r'@Trace\s+completionUpdatedAt\s*:\s*Timestamp\s*=\s*0', _hom) is not None, '')
chk('完成态时间轴：hydrate / snapshot 两端对称（缺失 / NaN 兜底 0）',
    'json.completionUpdatedAt > 0' in _hom
    and 'completionUpdatedAt: typeof todo.completionUpdatedAt' in _hom, '')
_hvm = rel_stripped('viewmodel/HomeViewModel.ets')
chk('完成态时间轴：L4 侧恰 2 处打点（toggleTask / syncRelatedTaskCompletion）',
    len(re.findall(r'task\.completionUpdatedAt\s*=\s*Date\.now\(\)', _hvm)) == 2,
    'sites=%d' % len(re.findall(r'task\.completionUpdatedAt\s*=\s*Date\.now\(\)', _hvm)))
chk('完成态时间轴：2 处打点都有 wasCompleted 守卫（幂等同步不得刷新该轴）',
    len(re.findall(r'const wasCompleted: boolean = task\.isCompleted', _hvm)) == 2
    and _hvm.count('if (wasCompleted !== ') == 2, '')
chk('完成态时间轴：非完成类写操作严禁刷新该轴（专注累计 / 目标改名级联）',
    'completionUpdatedAt' not in method_body(_hvm, 'addFocusToRelatedTask')
    and 'completionUpdatedAt' not in method_body(_hvm, 'updateGoalName'), '')

# ---------------------------------------------------------------- 18. 混淆白名单覆盖（防"名称即数据"静默失效）
# 背景（2026-09-18 全面体检发现）：`entry/obfuscation-rules.txt` 的 `-keep-property-name`
#   白名单漏登 3 个"名称即数据"字段 —— `isDeleted`（云同步墓碑，**已在用**）、
#   `completionUpdatedAt`（完成态裁决轴，2026-09-17 新增）、`dueText`（目标卡片 JSON）。
#
# **失效机理**（本项目特有的"半边混淆"，最难排查）：
#   · 写入端 = 对象字面量 key（`snapshotXxx` / `toJSON` 里的 `isDeleted: ...`）→ **会被混淆成短名**
#   · 读取端 = 字符串字面量（`readBool(x, 'isDeleted')`、`x['isDeleted']`）→
#     `-enable-string-property-obfuscation` **未开启** ⇒ 字符串侧恒为**原名**
#   ⇒ 两侧不再同名 ⇒ **墓碑 OR 失效**（已删除的条目在另一设备复活）、完成态轴恒读 0，
#     且**全程不报错**。开混淆（`enable: true`）之前必须让本段全绿。
#
# ⚠️ 本项目刻意**未开** `-enable-string-property-obfuscation`（注释里称之为"双保险"），
#    所以字符串侧永远安全、属性名侧必须登记 —— 这正是本段断言的方向。
_obf_path = os.path.join(ROOT, 'entry', 'obfuscation-rules.txt')
_obf_src = io.open(_obf_path, encoding='utf-8').read() if os.path.exists(_obf_path) else ''
_keep_names = set()
for _m in re.finditer(r'^-keep-property-name\s+(.+)$', _obf_src, re.M):
    _keep_names.update(_m.group(1).split())

chk('混淆白名单：obfuscation-rules.txt 可解析（≥100 个 keep 属性名，防解析失效恒真）',
    len(_keep_names) >= 100, 'parsed=%d' % len(_keep_names))

_bp = io.open(os.path.join(ROOT, 'entry', 'build-profile.json5'), encoding='utf-8').read()
chk('混淆白名单：规则文件已挂到 build-profile.json5 的 obfuscation.ruleOptions.files',
    './obfuscation-rules.txt' in _bp, '')
chk('混淆白名单：release 构建已实际启用混淆（obfuscation.enable = true，2026-09-18 开启）',
    re.search(r'"obfuscation"\s*:\s*\{[\s\S]*?"enable"\s*:\s*true', _bp) is not None,
    'obfuscation.enable is not true')
chk('混淆白名单：四个 enable-* 开关齐备（property / toplevel / filename / export）',
    all(('-%s' % _k) in _obf_src for _k in
        ['enable-property-obfuscation', 'enable-toplevel-obfuscation',
         'enable-filename-obfuscation', 'enable-export-obfuscation']), '')

# 危险集 A：同步服务里以**字符串**访问的属性名（读取端恒为原名）
_cs_src = _rsc
_str_fields = set()
for _m in re.finditer(r"read(?:Bool|Number|String|Obj|Any)\(\s*\w+\s*,\s*'([A-Za-z_][A-Za-z0-9_]*)'\s*\)", _cs_src):
    _str_fields.add(_m.group(1))
for _m in re.finditer(r"\w+\[\s*'([A-Za-z_][A-Za-z0-9_]*)'\s*\]", _cs_src):
    _str_fields.add(_m.group(1))
_miss_a = sorted(_f for _f in _str_fields if _f not in _keep_names)
chk('混淆白名单：云同步字符串访问字段（%d 个）全部被 keep' % len(_str_fields),
    len(_str_fields) >= 8 and not _miss_a, 'missing: %s' % ' '.join(_miss_a))

# 危险集 B：模型层**序列化输出**里以属性名字面量写出的 key（写入端会被改名）
#   只扫 `snapshotXxx` 与 `toJSON` 的函数体 —— 它们才真正决定落盘键名。
#   （第一版扫"文件里全部 4 空格缩进字面量"，把 interface 字段声明与函数参数默认值也算了进来
#     —— `trend:` / `requireRelation:` / `q1:` 全是误报 ⇒ 改为按函数体提取。）
def _fn_body(code, name):
    """取函数体（含花括号）。兼容模块级 `function name(...)` 与类方法 `name(): T {`。"""
    for _p in (r'function\s+%s\s*\([^)]*\)\s*(?::\s*[^{\n]+)?\{' % name,
               r'^\s*(?:static\s+)?(?:private\s+|public\s+|protected\s+)?%s\s*\(\s*\)\s*:\s*[^{\n]+\{'
               % name):
        _m = re.search(_p, code, re.M)
        if not _m:
            continue
        _i = _m.end() - 1
        _d = 0
        while _i < len(code):
            if code[_i] == '{':
                _d += 1
            elif code[_i] == '}':
                _d -= 1
                if _d == 0:
                    return code[_m.end() - 1:_i + 1]
            _i += 1
    return ''


_SER_FNS = {
    'model/HomeModels.ets': ['snapshotHomeTodoItem'],
    'model/TaskModels.ets': ['snapshotAiGeneratedTask', 'toJSON'],
    'model/RouteModels.ets': ['snapshotGoalCardItem', 'toJSON'],
}
_lit_fields = set()
_ser_found = []
for _rel, _fns in _SER_FNS.items():
    _src = rel_stripped(_rel)
    for _fn in _fns:
        _b = _fn_body(_src, _fn)
        if len(_b) > 0:
            _ser_found.append('%s:%s' % (_rel.split('/')[-1], _fn))
        _lit_fields.update(re.findall(r'\n\s+([A-Za-z_][A-Za-z0-9_]*)\s*:', _b))

chk('混淆白名单：5 个序列化函数体全部解析成功（防"取不到体 ⇒ 断言恒真"）',
    len(_ser_found) == 5, 'found=%s' % ','.join(_ser_found))

_miss_b = sorted(_f for _f in _lit_fields if _f not in _keep_names)
chk('混淆白名单：序列化字面量 key（%d 个）全部被 keep' % len(_lit_fields),
    len(_lit_fields) >= 20 and not _miss_b, 'missing: %s' % ' '.join(_miss_b))

# ---------------------------------------------------------------- 输出
lines = []
ok_all = True
for ok, desc, detail in results:
    tag = 'PASS  ' if ok else 'FAIL  '
    if not ok:
        ok_all = False
    lines.append('%s%s%s' % (tag, desc, ('  << ' + detail) if detail and not ok else ''))

total = len(results)
passed = sum(1 for ok, _, _ in results if ok)
lines.append('')
lines.append('总计 %d 项，通过 %d 项' % (total, passed))
lines.append('全部通过' if ok_all else '存在失败项')

text = '\n'.join(lines)
# 报告写到 .workbuddy/（项目数据目录），避免每次跑完都在 docs/上架素材 里冒出一个文件
report_dir = os.path.join(ROOT, '.workbuddy')
if not os.path.isdir(report_dir):
    os.makedirs(report_dir)
report = os.path.join(report_dir, '_check_sync_report.txt')
io.open(report, 'w', encoding='utf-8').write(text)
print(text)
sys.exit(0 if ok_all else 1)
