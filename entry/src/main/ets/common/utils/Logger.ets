/**
 * @file 日志工具
 * @description 基于 hilog 封装的统一日志工具，禁止 console.log
 * @module common/utils
 * @date 2026-06-17
 */

import { hilog } from '@kit.PerformanceAnalysisKit'
import { CommonConstants } from '../constants/CommonConstants'

/**
 * 日志工具类
 *
 * 强制规范：
 * - 禁止 console.log/error/warn，必须使用 hilog
 * - 敏感信息必须脱敏（secure 方法）
 * - 统一 TAG 与 DOMAIN，便于日志过滤
 */
export class Logger {
  /** 日志域 */
  private static readonly DOMAIN: number = CommonConstants.LOG_DOMAIN
  /** 日志标签 */
  private static readonly TAG: string = CommonConstants.LOG_TAG

  /**
   * 输出 INFO 级别日志
   * @param tag - 模块标签（与全局 TAG 拼接）
   * @param format - 格式字符串
   * @param args - 格式参数（均为 public 占位，避免敏感泄露）
   */
  static info(tag: string, format: string, ...args: string[]): void {
    hilog.info(Logger.DOMAIN, `${Logger.TAG}.${tag}`, '%{public}s', Logger.build(format, args))
  }

  /**
   * 输出 DEBUG 级别日志
   * @param tag - 模块标签
   * @param format - 格式字符串
   * @param args - 格式参数
   */
  static debug(tag: string, format: string, ...args: string[]): void {
    hilog.debug(Logger.DOMAIN, `${Logger.TAG}.${tag}`, '%{private}s', Logger.build(format, args))
  }

  /**
   * 输出 WARN 级别日志
   * @param tag - 模块标签
   * @param format - 格式字符串
   * @param args - 格式参数
   */
  static warn(tag: string, format: string, ...args: string[]): void {
    hilog.warn(Logger.DOMAIN, `${Logger.TAG}.${tag}`, '%{public}s', Logger.build(format, args))
  }

  /**
   * 输出 ERROR 级别日志
   * @param tag - 模块标签
   * @param format - 格式字符串
   * @param args - 格式参数
   */
  static error(tag: string, format: string, ...args: string[]): void {
    hilog.error(Logger.DOMAIN, `${Logger.TAG}.${tag}`, '%{public}s', Logger.build(format, args))
  }

  /**
   * 输出脱敏后的敏感信息日志
   * 自动对参数进行掩码处理（保留首尾各 2 位，中间用 * 填充）
   * @param tag - 模块标签
   * @param label - 字段标签（如 "token"）
   * @param sensitive - 敏感值原文
   */
  static secure(tag: string, label: string, sensitive: string): void {
    const masked: string = Logger.mask(sensitive)
    hilog.info(Logger.DOMAIN, `${Logger.TAG}.${tag}`, '%{public}s', `${label}=${masked}`)
  }

  /**
   * 拼接格式字符串与参数
   * @param format - 格式模板
   * @param args - 参数列表
   * @returns 拼接后的字符串
   */
  private static build(format: string, args: string[]): string {
    if (args.length === 0) {
      return format
    }
    let result: string = format
    for (let i = 0; i < args.length; i++) {
      const placeholder: string = `{${i}}`
      result = result.replace(placeholder, args[i])
    }
    return result
  }

  /**
   * 对敏感字符串进行掩码处理（全局唯一实现，各模块复用）
   * 规则：长度 ≤4 全部掩码；长度 >4 保留首尾各 2 位，中间用 **** 替换
   * @param value - 原始敏感值
   * @returns 脱敏后的字符串
   */
  static mask(value: string): string {
    if (value.length <= 4) {
      return '****'
    }
    const head: string = value.substring(0, 2)
    const tail: string = value.substring(value.length - 2)
    return `${head}****${tail}`
  }

  /** 私有构造：禁止实例化 */
  private constructor() {}
}
