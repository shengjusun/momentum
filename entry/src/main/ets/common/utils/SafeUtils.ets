// 空值/NaN 安全兜底工具函数，统一替代页面间重复实现

import { resourceManager } from '@kit.LocalizationKit'

/** 空值/空字符串安全兜底，非有效字符串时返回 fallback */
export function safeStringUtil(value: string | null | undefined, fallback: string): string {
  if (typeof value === 'string' && value.length > 0) return value
  return fallback
}

/** NaN/非数字安全兜底，有效数字返回非负整数取整值，否则返回 fallback */
export function safeNumberUtil(value: number | null | undefined, fallback: number = 0): number {
  if (typeof value === 'number' && !isNaN(value)) return Math.max(0, Math.floor(value))
  return fallback
}

/** 两位补零 */
function pad2Util(v: number): string {
  return v < 10 ? '0' + v.toString() : v.toString()
}

/**
 * 截止时间毫秒时间戳 → "YYYY-MM-DD" 文本
 * 无效/0/NaN 返回 "--"（表示未设置截止时间）
 */
export function formatDeadlineUtil(timestamp: number | null | undefined): string {
  if (typeof timestamp !== 'number' || isNaN(timestamp) || timestamp <= 0) return '--'
  const d: Date = new Date(timestamp)
  return d.getFullYear().toString() + '-' + pad2Util(d.getMonth() + 1) + '-' + pad2Util(d.getDate())
}

/**
 * 分钟数 → 智能耗时文案：≥1 天按"X 天"、≥1 小时按"X 小时"、否则"X 分钟"
 * （资源单位随系统语言；resourceManager 不可用时回退英文，与历史 ' min' 行为兼容）
 * @param minutes - 预估耗时（分钟），无效/0 返回空串
 * @param rm - 资源管理器，可空
 */
export function formatEstimatedDuration(minutes: number | null | undefined,
  rm: resourceManager.ResourceManager | null | undefined): string {
  const safeMinutes: number = (typeof minutes === 'number' && !isNaN(minutes) && minutes > 0)
    ? Math.floor(minutes) : 0
  if (safeMinutes === 0) return ''
  let unitText: string
  let value: number
  if (safeMinutes >= 1440) {
    value = Math.round(safeMinutes / 1440)
    unitText = rm ? rm.getStringByNameSync('duration_unit_day') : ' days'
  } else if (safeMinutes >= 60) {
    value = Math.round(safeMinutes / 60)
    unitText = rm ? rm.getStringByNameSync('duration_unit_hour') : ' hrs'
  } else {
    value = safeMinutes
    unitText = rm ? rm.getStringByNameSync('duration_unit_min') : ' min'
  }
  return value.toString() + unitText
}