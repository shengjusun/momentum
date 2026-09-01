// 空值/NaN 安全兜底工具函数，统一替代页面间重复实现

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