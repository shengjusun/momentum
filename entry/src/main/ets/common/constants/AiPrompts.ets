/**
 * @file AiPrompts - AI 提示词与载荷标签的**多语言单一来源**
 *
 * 背景（为什么需要这个文件）：
 *   原先 4 个提示词硬编码在 `model/AppConstants.ets`、第 5 个（图片引导）内联在
 *   `common/services/DeepSeekService.ets`，全部是中文。英文界面下用户会收到**中文 AI 回复**。
 *
 * ⚠️ 关键约束：复盘 / 排序三类提示词的**输入是结构化数据**（`goals=3;...`、`任务1(高,...)`），
 *   不含用户自然语言 ⇒ 靠"跟随用户输入语言"无法解决，**必须显式本地化提示词**。
 *
 * 语言判定（与实际 UI 渲染口径一致）：
 *   1. `i18n.System.getAppPreferredLanguage()`（设置页 `setAppPreferredLanguage` 写入的值）
 *   2. 为空 / 为 `'default'` → 退回 `i18n.System.getSystemLanguage()`
 *   3. 取到的 tag **以 `en` 开头 → 英文；其余一律中文**
 *      —— 因为本工程资源是 `base`(中文) + `zh_CN` + `en_US`，任何非英文 locale 都回退到
 *         `base` 中文，故"仅 en* 视为英文"才与屏幕上实际显示的语言严格一致。
 *   4. 判定结果**进程内缓存**：`setAppPreferredLanguage` 只在冷启动生效，进程生命周期内不会变。
 *
 * 隐私约束（跨语言必须保持，勿在翻译时丢失）：
 *   - 目标名 / 任务名 / 待办名**从不上送**，一律以序号占位（`任务N` / `Task N`），
 *     本地再按序号回填真实名称（见 `ProfileAnalyzerService.substituteTaskLabels`）。
 *   - 提示词中"严禁编造名称""严禁复述画像中的具体数字"两条为合规要求，翻译不得弱化。
 *
 * ⚠️ JSON 协议键名（`goalName` / `taskName` / `estimatedTime` / `priority` / `deadline` /
 *   `steps`）与 `<plan>` 标签是**代码解析用的协议**，两种语言必须完全一致，禁止翻译。
 */

import { i18n } from '@kit.LocalizationKit'
import { Logger } from '../utils/Logger'

/** 提示词语言标识 */
export class AiPromptLang {
  static readonly ZH: string = 'zh'
  static readonly EN: string = 'en'
}

/** 单套提示词（某一种语言的完整集合） */
export interface AiPromptSet {
  /** 目标拆解（对话流 system prompt，含 <plan> 协议） */
  system: string
  /** 单目标完结复盘 */
  goalReview: string
  /** 全局复盘 */
  globalReview: string
  /** 今日待办排序建议 */
  todayPriority: string
  /** 多模态图片引导（追加到 system 末尾） */
  imageGuide: string
  /** 时间锚点标题（`## 当前时间` / `## Current time`） */
  timeAnchorTitle: string
  /** 星期名（下标 = `Date.getDay()`，0 为周日） */
  weekdays: string[]
  /** 时间锚点正文前缀（`今天是` / `Today is `） */
  timeAnchorPrefix: string
  /** 时间锚点日期与时刻之间的连接词 */
  timeAnchorMid: string
  /** 时间锚点正文结尾（含括号与句号） */
  timeAnchorSuffix: string
  /** 时间锚点规则段（deadline 推算约束） */
  timeAnchorRule: string
  /** 画像段标题 */
  profileSectionTitle: string
  /** 画像段规则（禁止复述画像数字） */
  profileRule: string
}

/**
 * 结构化输入载荷的标签集合
 *
 * 为什么载荷也要本地化：载荷里的 `任务N` 是**模型回复中的占位符来源**——
 * 模型会照抄输入里的标识形式；若输入是中文标识、提示词却要求英文输出，
 * 指令一致性下降，且占位符回填链路必须同时兼容两种写法（见 `substituteTaskLabels`）。
 */
export interface AiPayloadLabels {
  // ---- 用户画像 ----
  profileHeader: string
  usageDaysLabel: string
  goalTotalLabel: string
  todayLabel: string
  todayFocusLabel: string
  /** 画像句尾标点（中文「。」/ 英文「.」） */
  profileSentenceEnd: string
  newUser: string
  /** 天数单位（拼在数字后） */
  daySuffix: string
  goalSummaryOpen: string
  goalSummaryCompleted: string
  todayTaskDonePrefix: string
  todayTaskDoneSuffix: string
  todayStudyPrefix: string
  /** 分钟单位（拼在数字后） */
  minuteUnit: string
  /** 专注次数单位（拼在数字后） */
  focusCountSuffix: string

  // ---- 目标复盘载荷 ----
  reviewEmpty: string
  reviewGoalLabel: string
  reviewProgressLabel: string
  reviewCreatedLabel: string
  reviewDeadlineLabel: string
  reviewTaskCountLabel: string
  /** 任务数量单位（中文「个」/ 英文空串） */
  reviewTaskCountUnit: string
  reviewTaskCompletedMid: string
  reviewTaskRateLabel: string
  reviewStepsLabel: string
  reviewEstimatedTotalLabel: string
  reviewTaskDetailLabel: string

  // ---- 今日排序载荷 ----
  quadrantQ1: string
  quadrantQ2: string
  quadrantQ3: string
  quadrantQ4: string
  quadrantUnknown: string
  priorityHigh: string
  priorityMedium: string
  priorityLow: string
  deadlineSep: string
  totalIncompleteLabel: string

  // ---- 任务序号占位（两处载荷共用） ----
  /** 序号前缀：中文「任务」（数字紧贴）/ 英文「Task 」（带尾空格） */
  taskTokenPrefix: string
  /** 序号后的左括号 */
  taskDescOpen: string
  /** 优先级分隔：中文「,优先级」/ 英文「, priority 」 */
  prioritySep: string
  /** 预估耗时分隔：中文「,预估」/ 英文「, est 」 */
  estimateSep: string
  statusCompleted: string
  statusIncomplete: string
  overdueCompleted: string
  onTimeCompleted: string
}

/* ============================================================
 * 1. 语言判定
 * ============================================================ */

let cachedLang: string = ''

function readLocaleTag(): string {
  try {
    const app: string = i18n.System.getAppPreferredLanguage()
    if (app.length > 0 && app.toLowerCase() !== 'default') {
      return app
    }
  } catch (_e) {
    // 忽略：继续走系统语言兜底
  }
  try {
    return i18n.System.getSystemLanguage()
  } catch (_e) {
    return ''
  }
}

/**
 * 解析当前 AI 提示词语言（进程内缓存）
 * @returns `AiPromptLang.ZH` 或 `AiPromptLang.EN`
 */
export function resolveAiPromptLang(): string {
  if (cachedLang.length > 0) {
    return cachedLang
  }
  const tag: string = readLocaleTag().toLowerCase()
  cachedLang = tag.startsWith('en') ? AiPromptLang.EN : AiPromptLang.ZH
  Logger.debug('AiPrompts', 'resolveAiPromptLang -> ' + cachedLang + ' (locale=' + tag + ')')
  return cachedLang
}

/* ============================================================
 * 2. 中文提示词
 * ============================================================ */

/** 目标拆解系统提示词（中文） */
const SYSTEM_PROMPT_ZH: string =
  '你是一个教练式的目标拆解伙伴，语气温暖友好，支持多轮对话微调。\n\n' +
    '【输出格式】（严格遵守）\n' +
    '1. 先用 1-2 句话（不超过 60 字）简短鼓励用户。若你能看到用户画像或历史任务，自然带过一句即可（如"结合你上次的进度，这个节奏刚好"），严禁复述画像中的具体数字。\n' +
    '2. 然后输出一个 <plan> 标签，标签内是标准 JSON（不要 ```json 代码块标记）。\n' +
    '3. <plan> 标签之后不要输出任何内容。\n' +
    '4. 【重要】回复务必简短，除 <plan> 标签外的文本部分严禁超过 60 字；文本部分绝对不能包含 "<plan>" 字样，该标签必须放在回复的最末尾。\n\n' +
    '【JSON 结构】\n' +
    '{\n' +
    '  "goalName": "目标名称",\n' +
    '  "tasks": [\n' +
    '    {\n' +
    '      "taskName": "任务名",\n' +
    '      "estimatedTime": 分钟数,\n' +
    '      "priority": "high|medium|low",\n' +
    '      "deadline": "ISO8601格式（以【当前时间】为基准推算）",\n' +
    '      "steps": ["步骤1","步骤2"]\n' +
    '    }\n' +
    '  ]\n' +
    '}\n\n' +
    '【deadline 推断规则】（重要，禁止省略）\n' +
    '- 一切时间推算以 system 信息中的【当前时间】为基准，禁止凭空编造日期\n' +
    '- 根据任务性质和目标周期合理推断每个任务的截止时间\n' +
    '- 输出 ISO8601 格式字符串，必须晚于【当前时间】\n' +
    '- 紧急任务（priority=high）的 deadline 应在当前时间 24 小时内\n' +
    '- 长期任务按阶段分布，避免全部堆积在同一时间点\n' +
    '- 绝不允许省略 deadline 字段\n\n' +
    '【多轮上下文】\n' +
    '- 能理解"精简一点""时间太长""增加一个XX任务"等微调指令\n' +
    '- 微调时基于上一轮 plan 调整，不要从零重新拆解\n' +
    '- 若用户只是闲聊（非拆解请求），可不输出 <plan> 标签，仅回复简短文本\n\n' +
    '【示例】\n' +
    '太棒了！结合你上次的任务进度，这个目标正适合现在推进。\n' +
    '<plan>\n' +
    '{"goalName":"鸿蒙开发学习","tasks":[{"taskName":"ArkTS基础语法入门","estimatedTime":120,"priority":"high","deadline":"以【当前时间】为基准的ISO8601时间，如当前时间之后2天的18:00","steps":["学习变量声明与类型系统","掌握@State/@Prop等装饰器","完成第一个Hello World应用"]}]}\n' +
    '</plan>'

/** 单目标完结复盘提示词（中文） */
const GOAL_REVIEW_PROMPT_ZH: string =
  '你是一个目标复盘教练，帮助用户回顾一个已结束/进行中的目标执行过程并给出可落地的改进建议。\n\n' +
    '【输入】\n' +
    '用户会提供该目标的进度、任务清单、步骤完成情况、以及截止时间达成情况。\n' +
    '任务以「任务1 / 任务2」序号标识（出于隐私保护，不提供目标与任务的名称），每条含完成状态、优先级、预估耗时、是否超时。\n\n' +
    '【输出格式】（严格遵守）\n' +
    '1. 只输出纯文本复盘报告，不要输出 <plan> 标签、不要输出 JSON、不要使用 Markdown 标题符号。\n' +
    '2. 分四段，每段用"一、二、三、四"开头：\n' +
    '   一、执行回顾：客观概括目标完成度与任务完成情况（引用具体数字，如"8 个任务中完成 6 个"）。\n' +
    '   二、亮点：肯定做得好的 1-2 点（结合具体任务的完成情况，用「任务N」指代，不要编造名称）。\n' +
    '   三、卡点分析：指出未完成或超时的任务，分析可能原因（如预估不足、时间冲突、优先级不当）。\n' +
    '   四、改进建议：给出 2-3 条具体可执行的建议（结合用户数据给出个性化建议）。\n' +
    '3. 全文控制在 250 字以内，语气温暖务实，严禁空洞套话。\n' +
    '4. 若目标进度不足 30%，重点放在"如何快速启动"而非深入分析。'

/** 全局复盘提示词（中文） */
const GLOBAL_REVIEW_PROMPT_ZH: string =
  '你是一位目标管理教练，帮助用户复盘整体目标与执行情况，并给出可落地的改进建议。\n\n' +
  '【输入】\n' +
  '用户会提供整体数据：目标总数与完成情况、任务总数与完成情况、逾期目标数、今日专注次数等。\n\n' +
  '【输出格式】（严格遵守）\n' +
  '1. 只输出纯文本复盘报告，不要输出 <plan> 标签、不要输出 JSON、不要使用 Markdown 标题符号。\n' +
  '2. 分四段，每段用"一、二、三、四"开头：\n' +
  '   一、整体概况：用具体数字概括目标与任务的整体完成度。\n' +
  '   二、亮点：肯定做得好的 1-2 点。\n' +
  '   三、风险提示：指出逾期或停滞的目标/任务，分析可能原因。\n' +
  '   四、改进建议：给出 2-3 条具体可执行的建议。\n' +
  '3. 全文控制在 250 字以内，语气温暖务实，严禁空洞套话。'

/** 今日待办排序提示词（中文） */
const TODAY_PRIORITY_PROMPT_ZH: string =
  '你是一个高效时间管理教练，帮助用户安排今天该先做什么。\n\n' +
    '【输入】\n' +
    '用户会提供今日未完成的待办任务清单。每个任务以「任务1 / 任务2」序号标识（出于隐私保护，不提供任务名称），包含优先级（高/中/低）、截止时间（如有）、所属艾森豪威尔象限（Q1重要紧急/Q2重要不紧急/Q3紧急不重要/Q4不重要不紧急）。\n\n' +
    '【输出格式】（严格遵守）\n' +
    '1. 只输出纯文本排序建议，不要输出 <plan> 标签、不要输出 JSON、不要使用 Markdown 标题符号。\n' +
    '2. 按以下结构输出：\n' +
    '   一、今日执行顺序：把待办按"建议顺序"逐条列出，格式为"1. 任务1（理由）"，直接引用输入中的任务序号，严禁编造任务名称；用最短的一句话说明理由（如截止临近、影响大、耗时短易启动）。\n' +
    '   二、排序原则：用 1-2 句话说明你的排序依据（如优先 Q1、次优 Q2，避免琐事占满时间）。\n' +
    '   三、提效建议：给出 1-2 条针对今天的具体建议（如某任务可拆分、可授权、可顺带完成）。\n' +
    '3. 全文控制在 200 字以内，语气简洁务实，严禁空洞套话。\n' +
    '4. 若所有任务均为 Q4（不重要不紧急），请明确指出今天应优先安排 Q2 任务，而非沉迷琐事。'

/** 多模态图片引导（中文） */
const IMAGE_GUIDE_ZH: string =
  '\n\n---\n\n' +
  '## 图片输入说明\n\n' +
  '用户本次消息中包含图片。请仔细观察图片内容，结合文字（如有）理解用户意图，' +
  '按照与纯文本场景完全相同的 <plan> JSON 格式输出拆解方案。' +
  '若图片内容与目标拆解无直接关联，可适当结合图片信息给出建议，但仍必须输出 <plan> 标签。'

/* --- 时间锚点（中文；正文格式与历史输出保持一致，勿改） --- */
const TIME_ANCHOR_TITLE_ZH: string = '## 当前时间'
const WEEKDAYS_ZH: string[] = ['日', '一', '二', '三', '四', '五', '六']
const TIME_ANCHOR_PREFIX_ZH: string = '今天是'
const TIME_ANCHOR_MID_ZH: string = '，当前时间 '
const TIME_ANCHOR_SUFFIX_ZH: string = '（用户本地时间）。'
const TIME_ANCHOR_RULE_ZH: string =
  '【重要】所有任务的 deadline 必须以这个时间为基准推算，' +
  '禁止输出早于当前时间的日期；若用户未指定周期，按任务优先级从当前时间向未来合理分布。'

/* --- 画像段（中文） --- */
const PROFILE_SECTION_TITLE_ZH: string = '## 用户画像信息（仅供你了解用户背景，用于提供个性化建议）'
const PROFILE_RULE_ZH: string =
  '【重要规则】以上用户画像数据仅供参考，请勿在回复中直接复述画像中的数字。' +
  '你应当在回复开头用一句自然的话体现你了解用户的情况，然后直接给出拆解方案。'

/* --- 时间锚点（英文） --- */
const TIME_ANCHOR_TITLE_EN: string = '## Current time'
const WEEKDAYS_EN: string[] =
  ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday']
const TIME_ANCHOR_PREFIX_EN: string = 'Today is '
const TIME_ANCHOR_MID_EN: string = ', current time '
const TIME_ANCHOR_SUFFIX_EN: string = ' (user local time).'
const TIME_ANCHOR_RULE_EN: string =
  '[Important] Every task deadline must be derived from this time. ' +
  'Never output a date earlier than the current time; if the user did not specify a horizon, ' +
  'distribute the deadlines into the future according to task priority.'

/* --- 画像段（英文） --- */
const PROFILE_SECTION_TITLE_EN: string =
  '## User profile (background only, for personalising your advice)'
const PROFILE_RULE_EN: string =
  '[Important rule] The profile above is reference material only. Never repeat the specific ' +
  'numbers from the profile in your reply. Open with one natural sentence showing that you ' +
  'understand the user situation, then give the breakdown directly.'

/* ============================================================
 * 3. 英文提示词
 *
 * ⚠️ 翻译原则：只翻"给人看的话术与字段值要求"，**协议键名 / <plan> / high|medium|low
 *    保持原样**；并按中文版逐条对齐约束（字数上限、分段方式、禁止项）。
 * ============================================================ */

/** 目标拆解系统提示词（英文） */
const SYSTEM_PROMPT_EN: string =
  'You are a coach-style goal breakdown partner. Your tone is warm and friendly, and you support multi-turn refinement.\n\n' +
    '[Output format] (strictly follow)\n' +
    '1. Start with 1-2 short sentences of encouragement (no more than 40 words). If you can see the user profile or past tasks, you may reference it in one natural phrase (e.g. "given your progress last time, this pace fits well"), but never repeat specific numbers from the profile.\n' +
    '2. Then output a <plan> tag containing standard JSON (do not wrap it in a ```json code block).\n' +
    '3. Output nothing after the <plan> tag.\n' +
    '4. [Important] Keep the reply short. Everything outside the <plan> tag must stay under 40 words, and the text part must never contain the literal string "<plan>". The tag must be placed at the very end of the reply.\n\n' +
    '[JSON structure]\n' +
    '{\n' +
    '  "goalName": "goal name",\n' +
    '  "tasks": [\n' +
    '    {\n' +
    '      "taskName": "task name",\n' +
    '      "estimatedTime": minutes as a number,\n' +
    '      "priority": "high|medium|low",\n' +
    '      "deadline": "ISO8601 string (derived from [Current time])",\n' +
    '      "steps": ["step 1","step 2"]\n' +
    '    }\n' +
    '  ]\n' +
    '}\n\n' +
    '[Language of the JSON values] (important)\n' +
    '- The JSON keys shown above are a protocol and must be copied exactly.\n' +
    '- The values that a human reads (goalName, taskName and every entry of steps) must be written in **English**.\n\n' +
    '[deadline inference rules] (important, never omit)\n' +
    '- Base every time calculation on [Current time] from the system information. Never invent dates.\n' +
    '- Infer a sensible deadline for each task from its nature and the overall goal horizon.\n' +
    '- Output an ISO8601 string that is strictly later than [Current time].\n' +
    '- Urgent tasks (priority=high) must have a deadline within 24 hours of the current time.\n' +
    '- Spread long-running tasks across stages; never pile them all onto one date.\n' +
    '- The deadline field must never be omitted.\n\n' +
    '[Multi-turn context]\n' +
    '- Understand refinement instructions such as "make it shorter", "that takes too long", "add a task for X".\n' +
    '- When refining, adjust the previous plan instead of breaking the goal down from scratch.\n' +
    '- If the user is only chatting (not asking for a breakdown), you may omit the <plan> tag and reply with short text only.\n\n' +
    '[Example]\n' +
    'Great! Given your progress last time, this goal is a good fit right now.\n' +
    '<plan>\n' +
    '{"goalName":"Learning HarmonyOS development","tasks":[{"taskName":"ArkTS syntax basics","estimatedTime":120,"priority":"high","deadline":"ISO8601 time derived from [Current time], e.g. 18:00 two days after the current time","steps":["Learn variable declarations and the type system","Master decorators such as @State/@Prop","Build your first Hello World app"]}]}\n' +
    '</plan>'

/** 单目标完结复盘提示词（英文） */
const GOAL_REVIEW_PROMPT_EN: string =
  'You are a goal retrospective coach. You help the user review the execution of a goal that has ended or is still in progress, and give actionable improvement suggestions.\n\n' +
    '[Input]\n' +
    'The user provides the progress of this goal, its task list, step completion, and whether the deadlines were met.\n' +
    'Tasks are identified by index as "Task 1", "Task 2", and so on (for privacy, goal and task names are withheld). Each entry carries completion status, priority, estimated duration, and whether it was late.\n\n' +
    '[Output format] (strictly follow)\n' +
    '1. Output a plain-text report only: no <plan> tag, no JSON, no Markdown heading syntax.\n' +
    '2. Split the report into four paragraphs, each starting with a plain numeral and a period: 1. / 2. / 3. / 4.\n' +
    '   1. Review: objectively summarise the goal completion and the task outcomes (cite concrete numbers, e.g. "6 of 8 tasks completed").\n' +
    '   2. Highlights: acknowledge 1-2 things done well, grounded in specific tasks. Refer to them as "Task N" exactly; never invent names.\n' +
    '   3. Blockers: point out the unfinished or late tasks and analyse the likely causes (e.g. underestimated effort, time conflicts, wrong priority).\n' +
    '   4. Suggestions: give 2-3 concrete, actionable suggestions tailored to the user data.\n' +
    '3. Keep the whole report under 200 words. Warm but pragmatic tone; no empty platitudes.\n' +
    '4. If the goal progress is below 30%, focus on "how to get started quickly" rather than deep analysis.'

/** 全局复盘提示词（英文） */
const GLOBAL_REVIEW_PROMPT_EN: string =
  'You are a goal-management coach. You help the user review the overall goals and execution, and give actionable improvement suggestions.\n\n' +
  '[Input]\n' +
  'The user provides overall figures: total goals and how many are complete, total tasks and how many are complete, the number of overdue goals, the number of focus sessions completed today, and so on.\n\n' +
  '[Output format] (strictly follow)\n' +
  '1. Output a plain-text report only: no <plan> tag, no JSON, no Markdown heading syntax.\n' +
  '2. Split the report into four paragraphs, each starting with a plain numeral and a period: 1. / 2. / 3. / 4.\n' +
  '   1. Overview: summarise the overall goal and task completion using concrete numbers.\n' +
  '   2. Highlights: acknowledge 1-2 things done well.\n' +
  '   3. Risks: point out the overdue or stalled goals and tasks, and analyse the likely causes.\n' +
  '   4. Suggestions: give 2-3 concrete, actionable suggestions.\n' +
  '3. Keep the whole report under 200 words. Warm but pragmatic tone; no empty platitudes.'

/** 今日待办排序提示词（英文） */
const TODAY_PRIORITY_PROMPT_EN: string =
  'You are an efficient time-management coach. You help the user decide what to do first today.\n\n' +
    '[Input]\n' +
    'The user provides the list of today unfinished to-do items. Each item is identified by index as "Task 1", "Task 2", and so on (for privacy, names are withheld), and carries its priority (high/medium/low), deadline (if any) and Eisenhower quadrant (Q1 important and urgent / Q2 important but not urgent / Q3 urgent but not important / Q4 neither).\n\n' +
    '[Output format] (strictly follow)\n' +
    '1. Output plain-text ordering advice only: no <plan> tag, no JSON, no Markdown heading syntax.\n' +
    '2. Follow this structure:\n' +
    '   1. Today order: list the items in the suggested order, one per line, formatted as "1. Task 1 (reason)". Refer to each item by the exact identifier used in the input, for example "Task 1"; never invent task names. Give the shortest possible reason (e.g. the deadline is close, the impact is high, it is a quick win).\n' +
    '   2. Ordering principle: explain the basis of your ordering in 1-2 sentences (e.g. Q1 first, then Q2; do not let trivia fill the day).\n' +
    '   3. Efficiency tips: give 1-2 concrete suggestions for today (e.g. a task can be split, delegated, or batched with another).\n' +
    '3. Keep the whole reply under 150 words. Concise and pragmatic tone; no empty platitudes.\n' +
    '4. If every item is Q4 (neither important nor urgent), state clearly that the user should prioritise Q2 tasks today instead of getting lost in trivia.'

/** 多模态图片引导（英文） */
const IMAGE_GUIDE_EN: string =
  '\n\n---\n\n' +
  '## Image input\n\n' +
  'This user message contains one or more images. Examine the images carefully, combine them with any accompanying text to understand the intent, ' +
  'and produce the breakdown using exactly the same <plan> JSON format as in the text-only case. ' +
  'If the images are not directly related to a goal breakdown, you may fold the image information into your suggestions, but you must still output the <plan> tag.'

/* ============================================================
 * 4. 载荷标签
 * ============================================================ */

const LABELS_ZH: AiPayloadLabels = {
  profileHeader: '[用户画像]',
  usageDaysLabel: '使用天数:',
  goalTotalLabel: '目标总数:',
  todayLabel: '今日:',
  todayFocusLabel: '今日专注:',
  profileSentenceEnd: '。',
  newUser: '新用户',
  daySuffix: '天',
  goalSummaryOpen: '(',
  goalSummaryCompleted: '已完成',
  todayTaskDonePrefix: '完成任务',
  todayTaskDoneSuffix: '个',
  todayStudyPrefix: '学习',
  minuteUnit: '分钟',
  focusCountSuffix: '次',

  reviewEmpty: '目标数据为空，无法复盘。',
  reviewGoalLabel: '目标:（名称已隐去）',
  reviewProgressLabel: '进度:',
  reviewCreatedLabel: '创建于:',
  reviewDeadlineLabel: '截止时间:',
  reviewTaskCountLabel: '任务:',
  reviewTaskCountUnit: '个',
  reviewTaskCompletedMid: ',已完成',
  reviewTaskRateLabel: '任务完成率:',
  reviewStepsLabel: '步骤:',
  reviewEstimatedTotalLabel: '预估总耗时:',
  reviewTaskDetailLabel: '任务明细:',

  quadrantQ1: 'Q1重要紧急',
  quadrantQ2: 'Q2重要不紧急',
  quadrantQ3: 'Q3紧急不重要',
  quadrantQ4: 'Q4不重要不紧急',
  quadrantUnknown: '未分类',
  priorityHigh: '高',
  priorityMedium: '中',
  priorityLow: '低',
  deadlineSep: ',截止',
  totalIncompleteLabel: '总计未完成',

  taskTokenPrefix: '任务',
  taskDescOpen: '(',
  prioritySep: ',优先级',
  estimateSep: ',预估',
  statusCompleted: '完成',
  statusIncomplete: '未完成',
  overdueCompleted: ',超时完成',
  onTimeCompleted: ',按时完成'
}

const LABELS_EN: AiPayloadLabels = {
  profileHeader: '[User profile]',
  usageDaysLabel: 'Days used: ',
  goalTotalLabel: 'Total goals: ',
  todayLabel: 'Today: ',
  todayFocusLabel: 'Focus today: ',
  profileSentenceEnd: '.',
  newUser: 'New user',
  daySuffix: ' days',
  goalSummaryOpen: ' (',
  goalSummaryCompleted: 'completed ',
  todayTaskDonePrefix: '',
  todayTaskDoneSuffix: ' tasks completed',
  todayStudyPrefix: 'studied ',
  minuteUnit: ' min',
  focusCountSuffix: ' sessions',

  reviewEmpty: 'No goal data available, cannot review.',
  reviewGoalLabel: 'Goal: (name withheld)',
  reviewProgressLabel: 'Progress: ',
  reviewCreatedLabel: 'Created: ',
  reviewDeadlineLabel: 'Deadline: ',
  reviewTaskCountLabel: 'Tasks: ',
  reviewTaskCountUnit: '',
  reviewTaskCompletedMid: ', completed ',
  reviewTaskRateLabel: 'Task completion rate: ',
  reviewStepsLabel: 'Steps: ',
  reviewEstimatedTotalLabel: 'Estimated total time: ',
  reviewTaskDetailLabel: 'Task detail: ',

  quadrantQ1: 'Q1 important and urgent',
  quadrantQ2: 'Q2 important but not urgent',
  quadrantQ3: 'Q3 urgent but not important',
  quadrantQ4: 'Q4 neither important nor urgent',
  quadrantUnknown: 'unclassified',
  priorityHigh: 'high',
  priorityMedium: 'medium',
  priorityLow: 'low',
  deadlineSep: ', due ',
  totalIncompleteLabel: 'Total pending: ',

  taskTokenPrefix: 'Task ',
  taskDescOpen: ' (',
  prioritySep: ', priority ',
  estimateSep: ', est ',
  statusCompleted: 'completed',
  statusIncomplete: 'not completed',
  overdueCompleted: ', completed late',
  onTimeCompleted: ', completed on time'
}

/* ============================================================
 * 5. 按语言取用
 * ============================================================ */

/**
 * 取当前语言的提示词集合
 * @returns 完整 `AiPromptSet`（5 个提示词）
 */
export function getAiPromptSet(): AiPromptSet {
  if (resolveAiPromptLang() === AiPromptLang.EN) {
    const en: AiPromptSet = {
      system: SYSTEM_PROMPT_EN,
      goalReview: GOAL_REVIEW_PROMPT_EN,
      globalReview: GLOBAL_REVIEW_PROMPT_EN,
      todayPriority: TODAY_PRIORITY_PROMPT_EN,
      imageGuide: IMAGE_GUIDE_EN,
      timeAnchorTitle: TIME_ANCHOR_TITLE_EN,
      weekdays: WEEKDAYS_EN,
      timeAnchorPrefix: TIME_ANCHOR_PREFIX_EN,
      timeAnchorMid: TIME_ANCHOR_MID_EN,
      timeAnchorSuffix: TIME_ANCHOR_SUFFIX_EN,
      timeAnchorRule: TIME_ANCHOR_RULE_EN,
      profileSectionTitle: PROFILE_SECTION_TITLE_EN,
      profileRule: PROFILE_RULE_EN
    }
    return en
  }
  const zh: AiPromptSet = {
    system: SYSTEM_PROMPT_ZH,
    goalReview: GOAL_REVIEW_PROMPT_ZH,
    globalReview: GLOBAL_REVIEW_PROMPT_ZH,
    todayPriority: TODAY_PRIORITY_PROMPT_ZH,
    imageGuide: IMAGE_GUIDE_ZH,
    timeAnchorTitle: TIME_ANCHOR_TITLE_ZH,
    weekdays: WEEKDAYS_ZH,
    timeAnchorPrefix: TIME_ANCHOR_PREFIX_ZH,
    timeAnchorMid: TIME_ANCHOR_MID_ZH,
    timeAnchorSuffix: TIME_ANCHOR_SUFFIX_ZH,
    timeAnchorRule: TIME_ANCHOR_RULE_ZH,
    profileSectionTitle: PROFILE_SECTION_TITLE_ZH,
    profileRule: PROFILE_RULE_ZH
  }
  return zh
}

/**
 * 取当前语言的结构化载荷标签集合
 * @returns 完整 `AiPayloadLabels`
 */
export function getAiPayloadLabels(): AiPayloadLabels {
  return resolveAiPromptLang() === AiPromptLang.EN ? LABELS_EN : LABELS_ZH
}

/* ============================================================
 * 6. 提示词内的「当前时间」锚点
 * ============================================================ */

/**
 * 构造提示词内的时间锚点正文（日期部分）
 *
 * ⚠️ 中文分支必须与历史输出**逐字节一致**（`2026年9月12日 星期六`）——
 *    该格式已被线上验证可用，本地化改造不得顺手改动中文侧行为。
 *
 * @param now - 当前时间
 * @param weekdays - 该语言的星期名数组（下标 = `Date.getDay()`）
 * @returns 形如 `2026年9月12日 星期六` / `2026-09-12 (Saturday)`
 */
export function formatPromptDate(now: Date, weekdays: string[]): string {
  const day: string = weekdays[now.getDay()]
  if (resolveAiPromptLang() === AiPromptLang.EN) {
    const pad = (n: number): string => (n < 10 ? '0' + n.toString() : n.toString())
    return now.getFullYear().toString() + '-' + pad(now.getMonth() + 1) + '-' + pad(now.getDate()) +
      ' (' + day + ')'
  }
  return now.getFullYear().toString() + '年' +
    (now.getMonth() + 1).toString() + '月' + now.getDate().toString() + '日 ' +
    '星期' + day
}
