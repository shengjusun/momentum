/**
 * @file API 类型定义
 * @description 网络请求与响应的统一类型，以及页面状态枚举
 * @module common/types
 * @date 2026-06-17
 */

import { http } from '@kit.NetworkKit'

/**
 * 统一 API 响应结构
 */
export interface ApiResponse<T> {
  /** 业务状态码（0 或 200 表示成功） */
  code: number
  /** 业务消息 */
  message: string
  /** 业务数据 */
  data: T
}

/**
 * HTTP 请求配置
 */
export interface HttpRequestOptions {
  /** 请求地址（完整 URL） */
  url: string
  /** 请求方法 */
  method: http.RequestMethod
  /** 请求头 */
  header?: Record<string, string>
  /** 请求体（字符串化后的数据） */
  data?: string
  /** 连接超时（毫秒），默认 15000 */
  connectTimeout?: number
  /** 读取超时（毫秒），默认 15000 */
  readTimeout?: number
  /** 是否期望返回 JSON 字符串 */
  expectJson?: boolean
}

/**
 * HTTP 错误信息
 */
export interface HttpError {
  /** 错误码（系统码或 HTTP 状态码） */
  code: number
  /** 错误消息 */
  message: string
}

/**
 * 断点类型
 */
export type BreakpointType = 'sm' | 'md' | 'lg'

/**
 * 列表项基础接口
 */
export interface BaseItem {
  /** 唯一标识 */
  id: string
  /** 标题 */
  title: string
  /** 描述 */
  desc: string
}
