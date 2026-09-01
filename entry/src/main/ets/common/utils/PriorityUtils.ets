// 优先级与艾森豪威尔象限的标签/颜色工具函数，统一替代页面间重复实现

import { TaskPriority } from '../../model/BaseTypes'
import { EisenhowerQuadrant } from '../../model/HomeModels'

/** 优先级中文标签（返回 Resource 以支持多语言） */
export function priorityLabelUtil(priority: TaskPriority): Resource {
  if (priority === TaskPriority.HIGH) return $r('app.string.priority_high')
  if (priority === TaskPriority.MEDIUM) return $r('app.string.priority_medium')
  return $r('app.string.priority_low')
}

/** 优先级标签背景色（用于卡片式标签） */
export function priorityBgColorUtil(priority: TaskPriority): Resource {
  if (priority === TaskPriority.HIGH) return $r('app.color.priority_high_bg')
  if (priority === TaskPriority.MEDIUM) return $r('app.color.priority_medium_bg')
  return $r('app.color.priority_low_bg')
}

/** 优先级标签文字色（用于卡片式标签） */
export function priorityTextColorUtil(priority: TaskPriority): Resource {
  if (priority === TaskPriority.HIGH) return $r('app.color.priority_high_text')
  if (priority === TaskPriority.MEDIUM) return $r('app.color.priority_medium_text')
  return $r('app.color.priority_low_text')
}

/** 优先级状态指示色（用于色条/状态标记） */
export function priorityStatusColorUtil(priority: TaskPriority): Resource {
  if (priority === TaskPriority.HIGH) return $r('app.color.error_color')
  if (priority === TaskPriority.MEDIUM) return $r('app.color.warning_color')
  return $r('app.color.text_tertiary')
}

// ===================== 艾森豪威尔四象限工具函数 =====================
// 用于详情页等场景，根据 priority + deadline 动态计算象限并展示标签
// 分类规则须与 HomeViewModel.eisenhowerMatrix 保持一致

/** 紧急度阈值：24 小时（毫秒） */
const URGENT_THRESHOLD_MS: number = 24 * 60 * 60 * 1000

/**
 * 根据 priority（重要度）+ deadline（紧急度）计算艾森豪威尔象限
 * 重要度：HIGH 为重要；紧急度：deadline > 0 且距今不足 24h 为紧急
 * deadline 为 0 视为未设置归入不紧急，已过截止时间也视为紧急
 */
export function classifyEisenhowerQuadrant(priority: TaskPriority, deadline: number): EisenhowerQuadrant {
  const isImportant: boolean = priority === TaskPriority.HIGH
  const hasDeadline: boolean = typeof deadline === 'number' && deadline > 0
  const isUrgent: boolean = hasDeadline && (deadline - Date.now()) < URGENT_THRESHOLD_MS

  if (isImportant && isUrgent) {
    return EisenhowerQuadrant.Q1_IMPORTANT_URGENT
  } else if (isImportant && !isUrgent) {
    return EisenhowerQuadrant.Q2_IMPORTANT_NOT_URGENT
  } else if (!isImportant && isUrgent) {
    return EisenhowerQuadrant.Q3_NOT_IMPORTANT_URGENT
  }
  return EisenhowerQuadrant.Q4_NOT_IMPORTANT_NOT_URGENT
}

/** 象限中文标签（如"重要且紧急"、"不紧急不重要"等） */
export function quadrantLabelUtil(quadrant: EisenhowerQuadrant): Resource {
  if (quadrant === EisenhowerQuadrant.Q1_IMPORTANT_URGENT) return $r('app.string.eisenhower_q1_title')
  if (quadrant === EisenhowerQuadrant.Q2_IMPORTANT_NOT_URGENT) return $r('app.string.eisenhower_q2_title')
  if (quadrant === EisenhowerQuadrant.Q3_NOT_IMPORTANT_URGENT) return $r('app.string.eisenhower_q3_title')
  return $r('app.string.eisenhower_q4_title')
}

/** 象限标签文字色（Q1红/Q2橙/Q3蓝/Q4灰） */
export function quadrantTextColorUtil(quadrant: EisenhowerQuadrant): Resource {
  if (quadrant === EisenhowerQuadrant.Q1_IMPORTANT_URGENT) return $r('app.color.error_color')
  if (quadrant === EisenhowerQuadrant.Q2_IMPORTANT_NOT_URGENT) return $r('app.color.warning_color')
  if (quadrant === EisenhowerQuadrant.Q3_NOT_IMPORTANT_URGENT) return $r('app.color.info_color')
  return $r('app.color.text_tertiary')
}

/** 象限标签背景色（淡色底：Q1淡红/Q2淡橙/Q3淡蓝/Q4淡灰） */
export function quadrantBgColorUtil(quadrant: EisenhowerQuadrant): Resource {
  if (quadrant === EisenhowerQuadrant.Q1_IMPORTANT_URGENT) return $r('app.color.priority_high_bg')
  if (quadrant === EisenhowerQuadrant.Q2_IMPORTANT_NOT_URGENT) return $r('app.color.priority_medium_bg')
  if (quadrant === EisenhowerQuadrant.Q3_NOT_IMPORTANT_URGENT) return $r('app.color.primary_color_bg')
  return $r('app.color.bg_tag')
}