/**
 * 小艺技能调用执行器 - @InsightIntentEntry 装饰器声明意图，框架自动注入槽位参数
 * onExecute 暂存目标文本到技能路由，由 EntryAbility 消费切到 AI Tab 并自动拆解
 */

import { InsightIntentEntry, InsightIntentEntryExecutor, insightIntent } from '@kit.AbilityKit'
import { window } from '@kit.ArkUI'
import { Logger } from '../common/utils/Logger'
import { setSkillRoute } from '../common/RouterManager'

/**
 * 意图执行结果结构
 */
interface CreateGoalResult {
  /** 成功状态 */
  success: boolean
  /** 提示信息 */
  message: string
}

/**
 * 执行结果工厂，满足 ArkTS 强类型约束
 */
function buildCreateGoalResult(success: boolean, message: string): CreateGoalResult {
  const result: CreateGoalResult = {
    success: success,
    message: message
  }
  return result
}

@InsightIntentEntry({
  intentName: 'CreateGoal',
  domain: 'com.example.momentum',
  intentVersion: '1.0.0',
  displayName: '创建目标',
  llmDescription: '当用户希望创建或制定一个新的目标计划时调用此意图，例如：我要一个月减掉10斤肉、帮我制定一个学习计划。请从用户话语中提取目标内容，抽取到 goalText 参数。goalText 必须是用户希望达成的具体目标描述，包含时间周期、量化指标等，不能为空。如果用户只是询问建议或与创建目标无关，如打招呼、问时间、查询天气，请不要调用此意图。',
  parameters: {
    'type': 'object',
    'properties': {
      'goalText': {
        'type': 'string',
        'description': '用户希望实现的目标内容，如：一个月减掉10斤肉'
      }
    },
    'required': ['goalText']
  },
  abilityName: 'EntryAbility',
  executeMode: [insightIntent.ExecuteMode.UI_ABILITY_FOREGROUND]
})
export default class CreateGoalIntentImpl extends InsightIntentEntryExecutor<CreateGoalResult> {
  private readonly tag: string = 'CreateGoalIntentImpl'

  /** 与 parameters 同名的公共属性，框架自动注入小艺抽取的目标内容 */
  goalText: string = ''

  /**
   * 技能执行入口（装饰器方式，UI_ABILITY_FOREGROUND 前台模式）
   *
   * @returns Promise<insightIntent.IntentResult<CreateGoalResult>>（code=0 成功）
   */
  async onExecute(): Promise<insightIntent.IntentResult<CreateGoalResult>> {
    Logger.info(this.tag, 'onExecute: goalTextLen=' + this.goalText.length.toString())

    // 1. 暂存技能路由（冷启动 MainTab 渲染后执行切换 Tab，AIPage 消费目标文本）
    setSkillRoute(this.goalText)

    // 2. 加载主界面（前台模式下系统已拉起 EntryAbility；此处确保页面加载）
    try {
      const stage: window.WindowStage | undefined = this.windowStage
      if (stage !== undefined) {
        stage.loadContent('pages/MainTab', (err: BusinessError): void => {
          if (err.code) {
            Logger.warn(this.tag, 'loadContent FAILED, code=' + err.code + ', msg=' + err.message)
            return
          }
          Logger.info(this.tag, 'loadContent SUCCESS')
        })
      }
    } catch (e) {
      Logger.warn(this.tag, 'loadContent failed: ' + (e as Error).message)
    }

    // 3. 返回执行成功
    const result: CreateGoalResult = buildCreateGoalResult(true, '目标已创建')
    const intentResult: insightIntent.IntentResult<CreateGoalResult> = {
      code: 0,
      result: result
    }
    return intentResult
  }
}