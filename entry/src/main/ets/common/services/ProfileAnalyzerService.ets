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
 *   - 使用天数：routeVM.goals[].createTime 中最早的距今天数
 *   - 目标概况：goals.length / completedGoalCount / averageProgress
 *   - 今日投入：completedTaskCount / todayStudyMinutes
 *   - 今日专注：todayFocusCount / todayFocusMillis
 *   - 领域分布：goals[].category 分组计数
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
import { AiGeneratedTask } from '../../model/TaskModels'
import { HomeTodoItem, EisenhowerQuadrant } from '../../model/HomeModels'
import { TaskPriority, TaskStatus } from '../../model/BaseTypes'
import { PomodoroService, PomodoroStats } from './PomodoroService'
import { Logger } from '../utils/Logger'

/** 领域分布项（降序排序用） */
interface CategoryCount {
  category: string
  count: number
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

      // === 维度 5：领域分布 ===
      const domainDist: string = ProfileAnalyzerService.computeDomainDistribution(routeVM)

      // === 组装画像文本 ===
      // TODO: i18n - 以下画像标签为 AI prompt 协议字符串，如需多语言支持需同步调整 prompt 模板
      const parts: string[] = [
        '[用户画像]',
        '使用天数:' + usageDays,
        '目标总数:' + goalSummary
      ]
      if (todayInput.length > 0) {
        parts.push('今日:' + todayInput)
      }
      if (todayFocus.length > 0) {
        parts.push('今日专注:' + todayFocus)
      }
      if (domainDist.length > 0) {
        parts.push('领域:' + domainDist)
      }

      const profile: string = parts.join(' ') + '。'

      // 如果所有维度都为空（除固定头部外无有效数据），返回空字符串
      if (usageDays === '新用户' && goalSummary === '0(已完成0)' &&
        todayInput.length === 0 && todayFocus.length === 0 && domainDist.length === 0) {
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
   * - 遍历 routeVM.goals，找到最早的 createTime（GoalCardItem.createTime 字段）
   * - 距今天数 = floor((Date.now() - minCreateTime) / 86400000) + 1
   * - 无目标时返回 '新用户'
   */
  private static computeUsageDays(routeVM: RoutePageViewModel): string {
    const goals: GoalCardItem[] = routeVM.goals
    if (goals.length === 0) {
      return '新用户' // TODO: i18n
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
      return '新用户'
    }
    const days: number = Math.floor((Date.now() - minTime) / 86400000) + 1
    return days.toString() + '天'
  }

  /**
   * 计算目标概况
   * - 格式：总目标数(已完成数)
   */
  private static computeGoalSummary(routeVM: RoutePageViewModel): string {
    const total: number = routeVM.goals.length
    const completed: number = routeVM.completedGoalCount
    return total.toString() + '(已完成' + completed.toString() + ')'
  }

  /**
   * 计算今日投入
   * - 今日完成任务数 (homeVM.completedTaskCount)
   * - 今日学习时长 (homeVM.todayStudyMinutes)
   * - 两个指标任一 > 0 才输出
   */
  private static computeTodayInput(homeVM: HomeViewModel): string {
    const partStrings: string[] = []
    const completedCount: number = homeVM.completedTaskCount
    if (completedCount > 0) {
      partStrings.push('完成任务' + completedCount.toString() + '个')
    }
    const studyMinutes: number = homeVM.todayStudyMinutes
    if (studyMinutes > 0) {
      partStrings.push('学习' + studyMinutes.toString() + '分钟')
    }
    return partStrings.join(', ')
  }

  /**
   * 计算今日专注
   * - todayFocusCount + todayFocusMillis（换算分钟，取整）
   * - 两个指标任一 > 0 才输出
   */
  private static computeTodayFocus(stats: PomodoroStats): string {
    const partStrings: string[] = []
    if (stats.todayFocusCount > 0) {
      partStrings.push(stats.todayFocusCount.toString() + '次')
    }
    const focusMinutes: number = Math.round(stats.todayFocusMillis / 60000)
    if (focusMinutes > 0) {
      partStrings.push(focusMinutes.toString() + '分钟')
    }
    return partStrings.join('/')
  }

  /**
   * 计算领域分布
   * - 遍历 routeVM.goals，按 GoalCardItem.category 分组计数
   * - 剔除空分类
   * - 按计数降序排列，取前 4 个
   * - 格式：学习(2), 健身(1), 工作(1)
   * - 无数据时返回空字符串
   */
  private static computeDomainDistribution(routeVM: RoutePageViewModel): string {
    const goals: GoalCardItem[] = routeVM.goals
    if (goals.length === 0) {
      return ''
    }

    const categoryMap: Map<string, number> = new Map<string, number>()
    for (let i: number = 0; i < goals.length; i++) {
      const cat: string = goals[i].category
      if (cat.length === 0) continue

      let current: number = 0
      if (categoryMap.has(cat)) {
        const val: number | undefined = categoryMap.get(cat)
        if (val !== undefined) {
          current = val
        }
      }
      categoryMap.set(cat, current + 1)
    }

    if (categoryMap.size === 0) {
      return ''
    }

    // 转换为数组并按计数降序排列
    const sorted: CategoryCount[] = []
    const keysIter: IterableIterator<string> = categoryMap.keys()
    let entry: IteratorResult<string> = keysIter.next()
    while (!entry.done) {
      const cat: string = entry.value
      let count: number = 0
      if (categoryMap.has(cat)) {
        const val: number | undefined = categoryMap.get(cat)
        if (val !== undefined) {
          count = val
        }
      }
      sorted.push({ category: cat, count: count })
      entry = keysIter.next()
    }
    sorted.sort((a: CategoryCount, b: CategoryCount): number => b.count - a.count)

    // 取前 4 个，格式化为 "学习(2), 健身(1)"
    const limitCount: number = Math.min(4, sorted.length)
    const partStrings: string[] = []
    for (let i: number = 0; i < limitCount; i++) {
      partStrings.push(sorted[i].category + '(' + sorted[i].count.toString() + ')')
    }
    return partStrings.join(', ')
  }

  /* ============================================================
   * B1 目标完结复盘数据采集
   * ============================================================ */

  /**
   * 构建单个目标的复盘数据文本（供 DeepSeekService.generateGoalReview 使用）
   *
   * 采集维度：
   *   - 目标名称 / 进度 / 创建与截止时间
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
   * @returns 复盘数据纯文本（中文，供 AI 分析）
   */
  static buildGoalReviewData(goal: GoalCardItem | null | undefined): string {
    if (!goal) {
      return '目标数据为空，无法复盘。'
    }

    const lines: string[] = []
    // 目标基本信息
    const goalName: string = goal.name.length > 0 ? goal.name : '未命名目标'
    lines.push('目标:' + goalName)
    lines.push('进度:' + Math.max(0, Math.min(100, goal.progress)).toString() + '%')
    if (goal.createTime > 0) {
      lines.push('创建于:' + new Date(goal.createTime).toLocaleDateString())
    }
    if (goal.deadline > 0) {
      lines.push('截止时间:' + new Date(goal.deadline).toLocaleDateString())
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
      const steps: Array<boolean> = Array.isArray(t.completedSteps) ? t.completedSteps : []
      totalSteps += steps.length
      for (let j: number = 0; j < steps.length; j++) {
        if (steps[j]) {
          completedSteps++
        }
      }
    }

    lines.push('任务:' + tasks.length.toString() + '个,已完成' + completedCount.toString() + '个')
    if (tasks.length > 0) {
      const rate: number = Math.round(completedCount * 100 / tasks.length)
      lines.push('任务完成率:' + rate.toString() + '%')
    }
    if (totalSteps > 0) {
      lines.push('步骤:' + completedSteps.toString() + '/' + totalSteps.toString())
    }
    if (totalEstimate > 0) {
      lines.push('预估总耗时:' + totalEstimate.toString() + '分钟')
    }

    // 各任务明细（含超时判断）
    if (tasks.length > 0) {
      const detailParts: string[] = []
      for (let i: number = 0; i < tasks.length; i++) {
        const t: AiGeneratedTask = tasks[i]
        const statusText: string = t.status === TaskStatus.COMPLETED ? '完成' : '未完成'
        const priText: string = t.priority === TaskPriority.HIGH ? '高' :
          (t.priority === TaskPriority.MEDIUM ? '中' : '低')
        let taskDesc: string = '「' + t.taskName + '」(' + statusText + ',优先级' + priText +
          ',预估' + t.estimatedTime.toString() + '分钟)'
        // 超时判断：已完成但实际完成时间晚于 deadline
        if (t.status === TaskStatus.COMPLETED && t.actualCompletionTime > 0 && t.deadline > 0 &&
          t.actualCompletionTime > t.deadline) {
          taskDesc += ',超时完成'
        } else if (t.status === TaskStatus.COMPLETED && t.deadline > 0 &&
          t.actualCompletionTime <= t.deadline) {
          taskDesc += ',按时完成'
        }
        detailParts.push(taskDesc)
      }
      lines.push('任务明细:' + detailParts.join('; '))
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
   *   - 每项标注：任务名、优先级（高/中/低）、截止时间（如有）、所属象限
   *
   * 容错：
   *   - homeVM 未初始化 / 无待办时返回空字符串（调用方应检测并跳过）
   *   - 不抛异常
   *
   * @param homeVM - 首页 ViewModel（读取四象限分类数据）
   * @returns 今日待办纯文本（中文），或空字符串（数据不足时）
   */
  static buildTodayTodoData(homeVM: HomeViewModel | null): string {
    if (homeVM === null || homeVM.isLoaded === false) {
      Logger.info(ProfileAnalyzerService.tag,
        'buildTodayTodoData skipped: homeVM not ready')
      return ''
    }

    const lines: string[] = []
    const quadrants: Array<EisenhowerQuadrant> = [
      EisenhowerQuadrant.Q1_IMPORTANT_URGENT,
      EisenhowerQuadrant.Q2_IMPORTANT_NOT_URGENT,
      EisenhowerQuadrant.Q3_NOT_IMPORTANT_URGENT,
      EisenhowerQuadrant.Q4_NOT_IMPORTANT_NOT_URGENT
    ]
    const quadrantLabels: Map<EisenhowerQuadrant, string> = new Map<EisenhowerQuadrant, string>()
    quadrantLabels.set(EisenhowerQuadrant.Q1_IMPORTANT_URGENT, 'Q1重要紧急')
    quadrantLabels.set(EisenhowerQuadrant.Q2_IMPORTANT_NOT_URGENT, 'Q2重要不紧急')
    quadrantLabels.set(EisenhowerQuadrant.Q3_NOT_IMPORTANT_URGENT, 'Q3紧急不重要')
    quadrantLabels.set(EisenhowerQuadrant.Q4_NOT_IMPORTANT_NOT_URGENT, 'Q4不重要不紧急')

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
      const safeLabel: string = (label !== undefined) ? label : '未分类'
      for (let j: number = 0; j < tasks.length; j++) {
        const todo: HomeTodoItem = tasks[j]
        const priText: string = todo.priority === TaskPriority.HIGH ? '高' :
          (todo.priority === TaskPriority.MEDIUM ? '中' : '低')
        let desc: string = '「' + todo.title + '」(' + safeLabel + ',优先级' + priText
        if (todo.deadline > 0) {
          desc += ',截止' + new Date(todo.deadline).toLocaleDateString()
        }
        desc += ')'
        lines.push(desc)
        totalCount++
      }
    }

    if (totalCount === 0) {
      Logger.info(ProfileAnalyzerService.tag,
        'buildTodayTodoData: no pending todo tasks')
      return ''
    }

    lines.push('总计未完成' + totalCount.toString() + '个')
    Logger.info(ProfileAnalyzerService.tag,
      'buildTodayTodoData success, count=' + totalCount.toString())
    return lines.join('\n')
  }
}
