/**
 * @file WantAgent 工厂（通知点击直达路由）
 * @description
 *   从 ProfileViewModel 下沉至 common 层：
 *   PomodoroService / PomodoroNotificationService / DeadlineReminderService 等服务层
 *   需要构造通知 WantAgent，此前反向 import viewmodel 造成层级倒挂。
 *   下沉后服务层只依赖 common，viewmodel 亦可复用。
 *
 * - createNotificationWantAgent: 点击通知仅拉起应用到首页
 * - createGoalDetailWantAgent: 点击通知直达目标详情页（携带 goalId）
 * - createTaskDetailWantAgent: 点击通知直达任务详情页（携带 taskId）
 */
import { wantAgent, WantAgent, common } from '@kit.AbilityKit'

/**
 * 构造目标详情页路由参数（Want.parameters 类型为 Record<string, Object>）
 */
function buildGoalRouteParams(goalId: string): Record<string, Object> {
  const params: Record<string, Object> = {}
  params['routeName'] = 'GoalDetailPage'
  params['goalId'] = goalId
  return params
}

/**
 * 构造任务详情页路由参数（Want.parameters 类型为 Record<string, Object>）
 *
 * @param taskId - 任务 ID
 * @param openImmersive - 是否需要落地即呼出全屏番茄钟（番茄钟通知专用）
 */
function buildTaskRouteParams(taskId: string, openImmersive: boolean): Record<string, Object> {
  const params: Record<string, Object> = {}
  params['routeName'] = 'TaskDetailPage'
  params['taskId'] = taskId
  // 显式标记"从番茄钟通知进来"：EntryAbility 收到后直接 showImmersive()，
  // 不依赖进程内 isImmersiveVisible 标志（进程被回收后该标志为 false，点通知只会落到任务详情）
  if (openImmersive) {
    params['openImmersive'] = '1'
  }
  return params
}

export class WantAgentFactory {
  static async createNotificationWantAgent(context: Context): Promise<WantAgent> {
    const uiaContext: common.UIAbilityContext = context as common.UIAbilityContext
    const wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [
        {
          deviceId: '',
          bundleName: uiaContext.abilityInfo.bundleName,
          abilityName: uiaContext.abilityInfo.name
        }
      ],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    }
    return await wantAgent.getWantAgent(wantAgentInfo)
  }

  /**
   * 创建点击通知后直达目标详情页的 WantAgent
   * 携带 parameters: { routeName: 'GoalDetailPage', goalId: xxx }
   * EntryAbility.onNewWant / onCreate 解析后调用 navigateToWithId 跳转
   *
   * @param context - 应用上下文
   * @param goalId - 目标 ID
   * @returns WantAgent 实例
   */
  static async createGoalDetailWantAgent(context: Context, goalId: string): Promise<WantAgent> {
    const uiaContext: common.UIAbilityContext = context as common.UIAbilityContext
    const routeParams: Record<string, Object> = buildGoalRouteParams(goalId)
    const wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [
        {
          deviceId: '',
          bundleName: uiaContext.abilityInfo.bundleName,
          abilityName: uiaContext.abilityInfo.name,
          parameters: routeParams
        }
      ],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    }
    return await wantAgent.getWantAgent(wantAgentInfo)
  }

  /**
   * 创建点击通知后直达任务详情页的 WantAgent
   * 携带 parameters: { routeName: 'TaskDetailPage', taskId: xxx[, openImmersive: '1'] }
   * EntryAbility.onNewWant / onCreate 解析后调用 navigateToWithIdOnce 跳转
   *
   * @param context - 应用上下文
   * @param taskId - 任务 ID
   * @param openImmersive - true 时落地即呼出全屏番茄钟（仅番茄钟倒计时通知传 true）
   * @returns WantAgent 实例
   */
  static async createTaskDetailWantAgent(context: Context, taskId: string,
    openImmersive: boolean = false): Promise<WantAgent> {
    const uiaContext: common.UIAbilityContext = context as common.UIAbilityContext
    const routeParams: Record<string, Object> = buildTaskRouteParams(taskId, openImmersive)
    const wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [
        {
          deviceId: '',
          bundleName: uiaContext.abilityInfo.bundleName,
          abilityName: uiaContext.abilityInfo.name,
          parameters: routeParams
        }
      ],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    }
    return await wantAgent.getWantAgent(wantAgentInfo)
  }
}
