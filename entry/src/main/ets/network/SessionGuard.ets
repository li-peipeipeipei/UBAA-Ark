import { ConnectionMode } from '../common/AppConfig';
import { Logger } from '../common/Logger';
import { LoginResponse } from '../model/ApiTypes';
import { CaptchaRequiredError } from './ApiError';
import { LocalAuthService, LocalSessionState, LocalValidation } from './LocalAuthService';
import { RouteScope } from './RouteScope';
import { SavedCredentials, StoredSession, TokenStore } from './TokenStore';

/**
 * 会话门卫：某条路线缺会话时，用已保存的凭据**静默补登**（对齐上游共同恢复服务）。
 *
 * ## 为什么需要它
 *
 * 登录态是按路线隔离的 Cookie 罐。哪怕登录时两条路都灌满了（见
 * `LocalAuthService.loginDual`），仍会有「某条路的会话先过期」的时刻：
 * 网关 Cookie 到期、服务端回收 CAS 会话、临时登录失败……原版在这些时刻不弹登录页，
 * 而是拿**用户已授权保存的凭据**在后台重走一次 CAS —— 用户只看到界面短暂恢复。
 *
 * ## 三条边界（缺一条就会变成「莫名被登出」或「静默疯狂重试」）
 *
 * 1. **必须有授权**：只有勾了「记住密码」且凭据可解才有资格静默提交；
 * 2. **单飞**：同一路线并发调用共享一个 Promise，绝不并行跑两套 CAS；
 * 3. **验证码就停**：自动识别不过就**不重试**，把决定权交回用户 ——
 *    否则会变成每小时一次的无声撞验证码。
 */
export class SessionGuard {
  /** 同一路线的补登单飞表（键是路线）。 */
  private static inflight: Map<ConnectionMode, Promise<boolean>> = new Map();
  /** 上次真正提交凭据的时刻。换网期间每个失败请求都会触发一次补登，必须节流。 */
  private static lastAttempt: Map<ConnectionMode, number> = new Map();
  /** 补登失败后的冷却窗口：5 秒内不再重走一遍 CAS，避免撞验证码 / 锁号。 */
  private static readonly FAILURE_COOLDOWN_MS: number = 5000;

  /** 已保存的凭据是否允许被静默提交（主动退出后一律不允许）。 */
  static canAutoLogin(): boolean {
    if (TokenStore.isSignedOut()) {
      return false;
    }
    const saved: SavedCredentials = TokenStore.getSavedCredentials();
    return saved.remember && saved.username.length > 0 && saved.password.length > 0;
  }

  /**
   * 确保指定路线可用。
   *
   * @returns `true` 表示该路线已有可用会话（原本就有、或刚补登成功）；
   *          `false` 表示需要用户手动登录（无凭据授权 / 验证码 / 凭据被拒）。
   * @param force 跳过失败冷却窗口。仅「上游明确返回 401 后的自检」该传 true。
   */
  static async ensure(mode: ConnectionMode, force: boolean = false): Promise<boolean> {
    // 已处在某条路线的流程里（登录或补登进行中）：不递归，只回答现状
    if (RouteScope.isScoped()) {
      return TokenStore.hasLocalSession(mode);
    }
    // 换网期间的每个失败读请求都会要求补登，5 秒内只提交一次凭据：
    // 既防止撞验证码，也防止上游把短时间重复 CAS 判为异常。
    if (!force && !TokenStore.hasLocalSession(mode)) {
      const last: number = SessionGuard.lastAttempt.get(mode) ?? 0;
      if (Date.now() - last < SessionGuard.FAILURE_COOLDOWN_MS) {
        return false;
      }
    }
    const running: Promise<boolean> | undefined = SessionGuard.inflight.get(mode);
    if (running !== undefined) {
      return await running;
    }
    const task: Promise<boolean> = SessionGuard.run(mode);
    SessionGuard.inflight.set(mode, task);
    try {
      return await task;
    } finally {
      SessionGuard.inflight.delete(mode);
    }
  }

  /** 真正的判定 + 补登。调用方不直接用它，走 `ensure` 才有单飞。 */
  private static async run(mode: ConnectionMode): Promise<boolean> {
    RouteScope.enter(mode);
    try {
      if (TokenStore.hasLocalSession(mode)) {
        const validation: LocalValidation = await LocalAuthService.validate();
        if (validation.state === LocalSessionState.VALID) {
          if (validation.session !== null) {
            TokenStore.saveLocalSession(validation.session, mode);
          }
          return true;
        }
        if (validation.state === LocalSessionState.TRANSIENT) {
          // 上游暂时不可用 ≠ 会话失效：保留槽位，别因为一次抖动把人踢下线
          Logger.warn('会话校验暂时不可用，保留 ' + mode + ' 的本地会话');
          return true;
        }
        TokenStore.clearLocalSession(mode);
      }
      if (!SessionGuard.canAutoLogin()) {
        Logger.info('静默重认证跳过：未授权保存凭据（' + mode + '）');
        return false;
      }
      const saved: SavedCredentials = TokenStore.getSavedCredentials();
      Logger.info('静默重认证：' + mode + ' 会话缺失，用已保存凭据后台补登');
      SessionGuard.lastAttempt.set(mode, Date.now());
      const response: LoginResponse =
        await LocalAuthService.login(saved.username, saved.password, '', '');
      // 界面要用的名字/学号存在 StoredSession 里：会话补回来了，展示信息也得跟上，
      // 否则「我的」页会顶着上一次的空白或旧名字
      const stored: StoredSession = TokenStore.getSession();
      stored.userName = response.user.name;
      stored.schoolId = response.user.schoolid;
      stored.username = saved.username;
      TokenStore.saveSession(stored);
      return TokenStore.hasLocalSession(mode);
    } catch (error) {
      if (error instanceof CaptchaRequiredError) {
        Logger.warn('静默重认证停在验证码（' + mode + '），转人工登录');
      } else {
        Logger.warn('静默重认证失败（' + mode + '）：' + (error as Error).message);
      }
      return TokenStore.hasLocalSession(mode);
    } finally {
      RouteScope.exit();
    }
  }
}
