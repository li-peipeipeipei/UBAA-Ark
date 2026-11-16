import { formBindingData, FormExtensionAbility, formInfo, formProvider } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CardCache } from '../common/CardCache';

const DOMAIN_NUMBER: number = 0x0100;
const TAG: string = 'UBAAForm';

/**
 * 桌面服务卡片的提供方（FormExtensionAbility）。
 *
 * ## 职责边界（很重要）
 *
 * 这个进程**只做三件事**：记住有哪些卡片、读取主应用写好的缓存、把缓存推给卡片 UI。
 * **它不联网、不解密、不碰登录链路** ——
 * 官方明写 FormExtensionAbility 回调后只存活 5~10 秒，
 * 而取课表要走 CAS 登录 + Cookie 跳转 + 解密，必然超时。
 *
 * ## 为什么 import 链这么短
 *
 * 官方 FAQ 原文：「ArkTS 卡片的 FormExtensionAbility **不支持加载**
 * particleAbility、audio、camera、media、backgroundTaskManager 等模块。
 * 强行加载得到的对象是 undefined，使用时就会产生 JS crash。」
 * 所以这里只引 FormKit / AbilityKit / hilog 和一个纯 Preferences 的 CardCache，
 * 绝不间接引到项目里那些会带上网络栈、加密栈的文件。
 */
export default class UBAAFormAbility extends FormExtensionAbility {
  /**
   * 用户把卡片拖到桌面时触发。
   *
   * 这里必须**同步返回**数据（签名不是 Promise，没法 await），
   * 所以直接同步读 Preferences —— 主应用把课表写进去，这里才读得到。
   */
  onAddForm(want: Want): formBindingData.FormBindingData {
    const params = want.parameters;
    if (params === undefined) {
      hilog.warn(DOMAIN_NUMBER, TAG, 'onAddForm: want.parameters 为空');
      return this.payload();
    }
    const formId = params[formInfo.FormParam.IDENTITY_KEY] as string;
    const name = params[formInfo.FormParam.NAME_KEY] as string;
    hilog.info(DOMAIN_NUMBER, TAG, 'onAddForm: name=%{public}s formId=%{public}s', name, formId);
    // 记下这张卡片，主应用之后才知道该往哪些 formId 推数据
    CardCache.addFormId(this.context, formId);
    return this.payload();
  }

  /**
   * 定时 / 定点 / 主动刷新时触发。
   *
   * 只读缓存、只推数据，**不做任何网络请求**。
   */
  onUpdateForm(formId: string): void {
    hilog.info(DOMAIN_NUMBER, TAG, 'onUpdateForm: %{public}s', formId);
    this.push(formId);
  }

  /** 用户移除卡片时触发 —— 必须清掉持久化的 formId，否则会越攒越多。 */
  onRemoveForm(formId: string): void {
    hilog.info(DOMAIN_NUMBER, TAG, 'onRemoveForm: %{public}s', formId);
    CardCache.removeFormId(this.context, formId);
  }

  /** 卡片内 `postCardAction({action:'message'})` 时触发。 */
  onFormEvent(formId: string, message: string): void {
    hilog.info(DOMAIN_NUMBER, TAG, 'onFormEvent: %{public}s', message);
    this.push(formId);
  }

  /** 卡片状态查询：直接报就绪。 */
  onAcquireFormState(want: Want): formInfo.FormState {
    return formInfo.FormState.READY;
  }

  /**
   * 组一份扁平数据（**只放 string**）。
   *
   * 实际实现在 `CardCache` —— 主应用推送时用的是同一份。
   * 早先这里和主应用各拼一遍，字段一旦增删就会悄悄漂移，故收敛到单一实现。
   */
  private payload(): formBindingData.FormBindingData {
    return formBindingData.createFormBindingData(CardCache.buildPayload(this.context));
  }

  /** 把缓存推给指定卡片。 */
  private push(formId: string): void {
    const data = this.payload();
    formProvider.updateForm(formId, data).catch((error: BusinessError) => {
      hilog.error(DOMAIN_NUMBER, TAG, 'updateForm 失败：code=%{public}d', error.code);
    });
  }
}