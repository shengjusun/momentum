/**
 * @file ProfileAnalyzerService - AI 学习画像分析引擎
 * @description
 *   纯函数式单例，只读读取 RoutePageViewModel / HomeViewModel / PomodoroService
 *   中的聚合统计数据，生成一段 200 字以内的纯文本用户画像摘要。
 *
 *   架构定位：
 *   - 输入：routeVM + homeVM + pomodoroService（只读引用，不修改任何数据）
 *   - 输出：纯文本字符串，由 DeepSeekService 注入到 system prompt 中
 *   - 当 VM 未初始化或数据为空时，返回空字符串 ''
 *
 *   画像维度（基于真实存在的数据字段）：
 *   - 使用天数：routeVM.liveGoals[].createTime 中最早的距今天数
 *   - 目标概况：goals.length / completedGoalCount / averageProgress
 *   - 今日投入：completedTaskCount / todayStudyMinutes
 *   - 今日专注：todayFocusCount / todayFocusMillis
 *   （原「领域分布」维度已移除：分类名可能含用户自定义文本，为收窄隐私面不再发送）
 *
 *   隐私约定：本服务产出的文本会随请求发送给第三方大模型（DeepSeek），
 *   因此仅包含统计口径（数量/进度/状态/耗时），**不包含目标名、任务名等用户文本内容**。
 *
 *   约束：
 *   - ArkTS 严格模式：无 any、无 as 强转（异常 as Error 除外）、显式类型
 *   - 所有 VM 访问做 null/undefined 防御
 *   - 画像文本 ≤ 200 字，不包含原始数据
 *
 * @module common/services
 * @date 2026-07-25
 */

import { RoutePageViewModel } from '../../viewmodel/RoutePageViewModel'
import { HomeViewModel } from '../../viewmodel/HomeViewModel'
import { GoalCardItem } from '../../model/RouteModels'
import { AiGeneratedTask, TaskStep } from '../../model/TaskModels'
import { HomeTodoItem, EisenhowerQuadrant } from '../../model/HomeModels'
import { TaskPriority, TaskStatus } from '../../model/BaseTypes'
import { PomodoroService, PomodoroStats } from './PomodoroService'
import { getAiPayloadLabels, AiPayloadLabels } from '../constants/AiPrompts'
import { Logger } from '../utils/Logger'

/**
 * 今日待办 AI 输入数据
 * - data：发送给第三方模型的文本（仅序号 + 象限/优先级/截止时间，**不含待办名称**）
 * - titles：与文本中「任务N」序号一一对应的待办名称，**仅本地持有用于回填展示，不发送**
 */
export interface TodayTodoInput {
  data: string
  titles: string[]
}

export class ProfileAnalyzerService {
  private static readonly tag: string = 'ProfileAnalyzerService'

  /**
   * 构建用户画像纯文本摘要
   *
   * 调用方：
   * - DeepSeekService.generateTasks() 在构建 system prompt 前调用
   * - 异步方法（因 pomodoroService.loadStats 为 Promise）
   *
   * 容错策略：
   * - 任一 VM 未初始化或数据为空 → 不抛异常，该维度返回空值或跳过
   * - 全空时返回空字符串 ''，调用方应检测并跳过画像注入
   *
   * @param routeVM - 路线页 ViewModel（获取目标数据）
   * @param homeVM - 首页 ViewModel（获取任务和时长数据）
   * @param pomodoroService - 番茄钟服务（获取专注统计）
   * @returns 用户画像纯文本摘要，或空字符串（数据不足时）
   */
  static async buildProfilePrompt(
    routeVM: RoutePageViewModel | null,
    homeVM: HomeViewModel | null,
    pomodoroService: PomodoroService | null
  ): Promise<string> {
    // 防御：任一核心 VM 为 null 或未加载 → 返回空字符串
    if (routeVM === null || routeVM.isLoaded === false) {
      Logger.info(ProfileAnalyzerService.tag,
        'buildProfilePrompt skipped: routeVM not ready')
      return ''
    }
    if (homeVM === null || homeVM.isLoaded === false) {
      Logger.info(ProfileAnalyzerService.tag,
        'buildProfilePrompt skipped: homeVM not ready')
      return ''
    }
    if (pomodoroService === null) {
      Logger.info(ProfileAnalyzerService.tag,
        'buildProfilePrompt skipped: pomodoroService is null')
      return ''
    }

    try {
      // === 维度 1：使用天数 ===
      const usageDays: string = ProfileAnalyzerService.computeUsageDays(routeVM)

      // === 维度 2：目标概况 ===
      const goalSummary: string = ProfileAnalyzerService.computeGoalSummary(routeVM)

      // === 维度 3：今日投入 ===
      const todayInput: string = ProfileAnalyzerService.computeTodayInput(homeVM)

      // === 维度 4：今日专注（异步读取持久化统计） ===
      let todayFocus: string = ''
      try {
        const stats: PomodoroStats = await pomodoroService.loadStats()
        todayFocus = ProfileAnalyzerService.computeTodayFocus(stats)
      } catch (e) {
        Logger.warn(ProfileAnalyzerService.tag,
          'loadStats failed, skip todayFocus: ' + (e as Error).message)
      }

      // 维度 5「领域分布」已移除：分类名可能含用户自定义文本，为收窄隐私面不再发送给第三方模型

      // === 组装画像文本 ===
      // 标签随提示词语言本地化（标签是 AI prompt 协议的一部分：
      // 英文提示词下若仍是中文标签，指令一致性下降）
      const L: AiPayloadLabels = getAiPayloadLabels()
      const parts: string[] = [
        L.profileHeader,
        L.usageDaysLabel + usageDays,
        L.goalTotalLabel + goalSummary
      ]
      if (todayInput.length > 0) {
        parts.push(L.todayLabel + todayInput)
      }
      if (todayFocus.length > 0) {
        parts.push(L.todayFocusLabel + todayFocus)
      }
      const profile: string = parts.join(' ') + L.profileSentenceEnd

      // 如果所有维度都为空（除固定头部外无有效数据），返回空字符串
      // 判据用**语言中立的原始条件**（无目标）而非拼 `goalSummary` 字符串——
      // 后者的格式随语言变化，靠字符串比较会随本地化失效
      if (usageDays === L.newUser && routeVM.liveGoals.length === 0 &&
        todayInput.length === 0 && todayFocus.length === 0) {
        Logger.info(ProfileAnalyzerService.tag,
          'buildProfilePrompt: all dimensions empty, user is new')
        return ''
      }

      Logger.info(ProfileAnalyzerService.tag,
        'buildProfilePrompt success, length=' + profile.length.toString())
      return profile
    } catch (e) {
      Logger.warn(ProfileAnalyzerService.tag,
        'buildProfilePrompt failed: ' + (e as Error).message)
      return ''
    }
  }

  /**
   * 计算使用天数
   * - 遍历 routeVM.liveGoals，找到最早的 createTime（GoalCardItem.createTime 字段）
   * - 距今天数 = floor((Date.now() - minCreateTime) / 86400000) + 1
   * - 无目标时返回 '新用户'
   */
  private static computeUsageDays(routeVM: RoutePageViewModel): string {
    const L: AiPayloadLabels = getAiPayloadLabels()
    const goals: GoalCardItem[] = routeVM.liveGoals
    if (goals.length === 0) {
      return L.newUser
    }
    let minTime: number = Date.now()
    for (let i: number = 0; i < goals.length; i++) {
      const goal: GoalCardItem = goals[i]
      const ct: number = goal.createTime
      if (ct > 0 && ct < minTime) {
        minTime = ct
      }
    }
    if (minTime === Date.now()) {
      return L.newUser
    }
    const days: number = Math.floor((Date.now() - minTime) / 86400000) + 1
    return days.toString() + L.daySuffix
  }

  /**
   * 计算目标概况
   * - 格式：总目标数(已完成数)
   */
  private static computeGoalSummary(routeVM: RoutePageViewModel): string {
    const L: AiPayloadLabels = getAiPayloadLabels()
    const total: number = routeVM.liveGoals.length
    const completed: number = routeVM.completedGoalCount
    return total.toString() + L.goalSummaryOpen + L.goalSummaryCompleted +
      completed.toString() + ')'
  }

  /**
   * 计算今日投入
   * - 今日完成任务数 (homeVM.completedTaskCount)
   * - 今日学习时长 (homeVM.todayStudyMinutes)
   * - 两个指标任一 > 0 才输出
   */
  private static computeTodayInput(homeVM: HomeViewModel): string {
    const L: AiPayloadLabels = getAiPayloadLabels()
    const partStrings: string[] = []
    const completedCount: number = homeVM.completedTaskCount
    if (completedCount > 0) {
      partStrings.push(L.todayTaskDonePrefix + completedCount.toString() + L.todayTaskDoneSuffix)
    }
    const studyMinutes: number = homeVM.todayStudyMinutes
    if (studyMinutes > 0) {
      partStrings.push(L.todayStudyPrefix + studyMinutes.toString() + L.minuteUnit)
    }
    return partStrings.join(', ')
  }

  /**
   * 计算今日专注
   * - todayFocusCount + todayFocusMillis（换算分钟，取整）
   * - 两个指标任一 > 0 才输出
   */
  private static computeTodayFocus(stats: PomodoroStats): string {
    const L: AiPayloadLabels = getAiPayloadLabels()
    const partStrings: string[] = []
    if (stats.todayFocusCount > 0) {
      partStrings.push(stats.todayFocusCount.toString() + L.focusCountSuffix)
    }
    const focusMinutes: number = Math.round(stats.todayFocusMillis / 60000)
    if (focusMinutes > 0) {
      partStrings.push(focusMinutes.toString() + L.minuteUnit)
    }
    return partStrings.join('/')
  }

  /* ============================================================
   * B1 目标完结复盘数据采集
   * ============================================================ */

  /**
   * 构建单个目标的复盘数据文本（供 DeepSeekService.generateGoalReview 使用）
   *
   * 采集维度（隐私：**不含目标名称与任务名称**，任务以序号标识）：
   *   - 目标：进度 / 创建与截止时间
   *   - 任务总数 / 完成数 / 完成率
   *   - 步骤总数 / 完成数
   *   - 预估总耗时（分钟）与实际总耗时（分钟，基于任务 actualCompletionTime 差值估算）
   *   - deadline 达成情况：是否有任务超时（completed 且完成时间 > deadline）
   *   - 各任务的完成状态 / 优先级 / 预估耗时 / 是否超时
   *
   * 容错：
   *   - 目标无任务 / 数据缺失时返回最小可读文本
   *   - 不抛异常，所有字段显式防御
   *
   * @param goal - L1 目标（只读）
   * @returns 复盘数据纯文本（标签随提示词语言本地化，供 AI 分析）
   */
  static buildGoalReviewData(goal: GoalCardItem | null | undefined): string {
    const L: AiPayloadLabels = getAiPayloadLabels()
    if (!goal) {
      return L.reviewEmpty
    }

    const lines: string[] = []
    // 目标基本信息
    // 隐私：目标/任务名称等文本内容不发送给第三方模型，仅提供统计口径（进度/状态/优先级/耗时）
    lines.push(L.reviewGoalLabel)
    lines.push(L.reviewProgressLabel + Math.max(0, Math.min(100, goal.progress)).toString() + '%')
    if (goal.createTime > 0) {
      lines.push(L.reviewCreatedLabel + new Date(goal.createTime).toLocaleDateString())
    }
    if (goal.deadline > 0) {
      lines.push(L.reviewDeadlineLabel + new Date(goal.deadline).toLocaleDateString())
    }

    // 任务统计
    const tasks: AiGeneratedTask[] = Array.isArray(goal.tasks) ? goal.tasks : []
    let completedCount: number = 0
    let totalSteps: number = 0
    let completedSteps: number = 0
    let totalEstimate: number = 0
    for (let i: number = 0; i < tasks.length; i++) {
      const t: AiGeneratedTask = tasks[i]
      if (t.status === TaskStatus.COMPLETED) {
        completedCount++
      }
      totalEstimate += Math.max(0, t.estimatedTime)
      // L3 步骤已对象化：完成状态读自 steps[j].isCompleted（原先读平行布尔数组）
      const steps: TaskStep[] = Array.isArray(t.steps) ? t.steps : []
      totalSteps += steps.length
      for (let j: number = 0; j < steps.length; j++) {
        if (steps[j].isCompleted === true) {
          completedSteps++
        }
      }
    }

    lines.push(L.reviewTaskCountLabel + tasks.length.toString() + L.reviewTaskCountUnit +
      L.reviewTaskCompletedMid + completedCount.toString() + L.reviewTaskCountUnit)
    if (tasks.length > 0) {
      const rate: number = Math.round(completedCount * 100 / tasks.length)
      lines.push(L.reviewTaskRateLabel + rate.toString() + '%')
    }
    if (totalSteps > 0) {
      lines.push(L.reviewStepsLabel + completedSteps.toString() + '/' + totalSteps.toString())
    }
    if (totalEstimate > 0) {
      lines.push(L.reviewEstimatedTotalLabel + totalEstimate.toString() + L.minuteUnit)
    }

    // 各任务明细（含超时判断）
    if (tasks.length > 0) {
      const detailParts: string[] = []
      for (let i: number = 0; i < tasks.length; i++) {
        const t: AiGeneratedTask = tasks[i]
        const statusText: string = t.status === TaskStatus.COMPLETED ? L.statusCompleted : L.statusIncomplete
        const priText: string = t.priority === TaskPriority.HIGH ? L.priorityHigh :
          (t.priority === TaskPriority.MEDIUM ? L.priorityMedium : L.priorityLow)
        let taskDesc: string = L.taskTokenPrefix + (i + 1).toString() + L.taskDescOpen +
          statusText + L.prioritySep + priText +
          L.estimateSep + t.estimatedTime.toString() + L.minuteUnit + ')'
        // 超时判断：已完成但实际完成时间晚于 deadline
        if (t.status === TaskStatus.COMPLETED && t.actualCompletionTime > 0 && t.deadline > 0 &&
          t.actualCompletionTime > t.deadline) {
          taskDesc += L.overdueCompleted
        } else if (t.status === TaskStatus.COMPLETED && t.deadline > 0 &&
          t.actualCompletionTime <= t.deadline) {
          taskDesc += L.onTimeCompleted
        }
        detailParts.push(taskDesc)
      }
      lines.push(L.reviewTaskDetailLabel + detailParts.join('; '))
    }

    return lines.join('\n')
  }

  /* ============================================================
   * C2 今日待办排序建议数据采集
   * ============================================================ */

  /**
   * 构建今日未完成待办的数据文本（供 DeepSeekService.generateTodaySuggestion 使用）
   *
   * 采集维度：
   *   - 遍历 homeVM.eisenhowerMatrix 四个象限的未完成任务
   *   - 每项以**序号**标识（隐私：不含待办名称），标注象限、优先级（高/中/低）、截止时间（如有）
   *
   * 容错：
   *   - homeVM 未初始化 / 无待办时 data 为空串（调用方应检测并跳过）
   *   - 不抛异常
   *
   * @param homeVM - 首页 ViewModel（读取四象限分类数据）
   * @returns TodayTodoInput（data = 发送给模型的文本；titles = 本地回填用的名称；数据不足时 data 为空串）
   */
  static buildTodayTodoData(homeVM: HomeViewModel | null): TodayTodoInput {
    if (homeVM === null || homeVM.isLoaded === false) {
      Logger.info(ProfileAnalyzerService.tag,
        'buildTodayTodoData skipped: homeVM not ready')
      const notReady: TodayTodoInput = { data: '', titles: [] }
      return notReady
    }

    const lines: string[] = []
    const L: AiPayloadLabels = getAiPayloadLabels()
    // 与「任务N」序号一一对应的名称，仅本地回填展示用，不随请求发送
    const titles: string[] = []
    const quadrants: Array<EisenhowerQuadrant> = [
      EisenhowerQuadrant.Q1_IMPORTANT_URGENT,
      EisenhowerQuadrant.Q2_IMPORTANT_NOT_URGENT,
      EisenhowerQuadrant.Q3_NOT_IMPORTANT_URGENT,
      EisenhowerQuadrant.Q4_NOT_IMPORTANT_NOT_URGENT
    ]
    const quadrantLabels: Map<EisenhowerQuadrant, string> = new Map<EisenhowerQuadrant, string>()
    quadrantLabels.set(EisenhowerQuadrant.Q1_IMPORTANT_URGENT, L.quadrantQ1)
    quadrantLabels.set(EisenhowerQuadrant.Q2_IMPORTANT_NOT_URGENT, L.quadrantQ2)
    quadrantLabels.set(EisenhowerQuadrant.Q3_NOT_IMPORTANT_URGENT, L.quadrantQ3)
    quadrantLabels.set(EisenhowerQuadrant.Q4_NOT_IMPORTANT_NOT_URGENT, L.quadrantQ4)

    let totalCount: number = 0
    for (let i: number = 0; i < quadrants.length; i++) {
      const q: EisenhowerQuadrant = quadrants[i]
      let tasks: Array<HomeTodoItem> = []
      if (q === EisenhowerQuadrant.Q1_IMPORTANT_URGENT) {
        tasks = homeVM.eisenhowerMatrix.q1.tasks
      } else if (q === EisenhowerQuadrant.Q2_IMPORTANT_NOT_URGENT) {
        tasks = homeVM.eisenhowerMatrix.q2.tasks
      } else if (q === EisenhowerQuadrant.Q3_NOT_IMPORTANT_URGENT) {
        tasks = homeVM.eisenhowerMatrix.q3.tasks
      } else {
        tasks = homeVM.eisenhowerMatrix.q4.tasks
      }

      const label: string | undefined = quadrantLabels.get(q)
      const safeLabel: string = (label !== undefined) ? label : L.quadrantUnknown
      for (let j: number = 0; j < tasks.length; j++) {
        const todo: HomeTodoItem = tasks[j]
        const priText: string = todo.priority === TaskPriority.HIGH ? L.priorityHigh :
          (todo.priority === TaskPriority.MEDIUM ? L.priorityMedium : L.priorityLow)
        // 隐私：不发送待办名称，仅以序号 + 象限/优先级/截止时间等统计口径描述；
        // 名称按同一序号在本地留存（titles），用于把模型回复里的「任务N」回填为真实名称
        let desc: string = L.taskTokenPrefix + (totalCount + 1).toString() + L.taskDescOpen +
          safeLabel + L.prioritySep + priText
        if (todo.deadline > 0) {
          desc += L.deadlineSep + new Date(todo.deadline).toLocaleDateString()
        }
        desc += ')'
        lines.push(desc)
        titles.push(todo.title)
        totalCount++
      }
    }

    if (totalCount === 0) {
      Logger.info(ProfileAnalyzerService.tag,
        'buildTodayTodoData: no pending todo tasks')
      const noTasks: TodayTodoInput = { data: '', titles: [] }
      return noTasks
    }

    lines.push(L.totalIncompleteLabel + totalCount.toString() + L.reviewTaskCountUnit)
    Logger.info(ProfileAnalyzerService.tag,
      'buildTodayTodoData success, count=' + totalCount.toString())
    const result: TodayTodoInput = { data: lines.join('\n'), titles: titles }
    return result
  }

  /**
   * 将模型回复中的「任务N」占位回填为真实名称（仅本地展示；名称从未发送给模型）
   *
   * 兼容的占位写法（中英两套提示词各自对应一种）：
   *   - 中文：`任务1` / `任务 1`
   *   - 英文：`Task 1` / `Task1`（大小写不敏感，故 `task 1` 亦可）
   *
   * ⚠️ 实现为**单次扫描**而非多轮 `split/join`：
   *   多轮替换时，前一轮写入的真实名称若恰好含后一轮的模式（如某任务名叫 "task 2 review"），
   *   会被二次替换。占位模式从 2 种扩到 6 种后该级联风险成倍放大，故改为一次扫描定序输出。
   *
   * - 越界序号（<1 或 > titles.length）与空名称**原样保留**，不改写
   * - 未匹配到的位置原样输出
   */
  static substituteTaskLabels(text: string, titles: string[]): string {
    if (text.length === 0 || titles.length === 0) {
      return text
    }
    // `(?:任务|Task|task)` + 可选空白 + 数字；用 `\s?` 而非 `\s*` 以避免吞掉正文空格
    const tokenRegex: RegExp = /(?:任务|Task|task)\s?(\d+)/g
    let out: string = ''
    let cursor: number = 0
    let m: RegExpExecArray | null = tokenRegex.exec(text)
    while (m !== null) {
      const idx: number = parseInt(m[1], 10)
      let replacement: string = m[0]
      if (idx >= 1 && idx <= titles.length) {
        const name: string = titles[idx - 1]
        if (name.length > 0) {
          replacement = name
        }
      }
      out += text.substring(cursor, m.index) + replacement
      cursor = m.index + m[0].length
      m = tokenRegex.exec(text)
    }
    out += text.substring(cursor)
    return out
  }
}
