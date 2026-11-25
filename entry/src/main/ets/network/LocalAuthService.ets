import { util } from '@kit.ArkTS';
import { ConnectionMode } from '../common/AppConfig';
import { Logger } from '../common/Logger';
import { ApiError, CaptchaRequiredError } from './ApiError';
import { CaptchaRecognizer } from './CaptchaRecognizer';
import { CasParser } from './CasParser';
import { resolveLocation, stripQuery, UpstreamClient, UpstreamResponse } from './UpstreamClient';
import { RouteScope } from './RouteScope';
import { LocalAuthSession, TokenStore } from './TokenStore';
import { LocalWebVpn } from './LocalWebVpn';
import { RouteEngine } from './RouteEngine';
import {
  CaptchaInfo,
  LoginPreloadResponse,
  LoginResponse,
  SessionStatusResponse,
  UserData,
  UserInfo
} from '../model/ApiTypes';

/**
 * 本地模式登录（客户端自己完成校内统一身份认证）。
 *
 * ## 与 UBAA 2.0.2 的对齐关系
 *
 * 本文件按原版 `crates/ubaa_core/src/auth/{mod,interactive,automatic,gateway}.rs`
 * 的**流程顺序**实现，关键差异见各处注释：
 *
 * ```
 *  GET  sso/login                              → 准备页（execution + 验证码 id，二者成对）
 *  ├─ 无验证码 → POST sso/login（普通表单）
 *  └─ 有验证码 → GET sso/captcha?captchaId=…   → 取图 → POST sso/login（八字段表单）
 *  → 逐跳跟随重定向（每跳解包 WebVPN 地址 + HSTS 升级）
 *  → WebVPN：激活 d.buaa.edu.cn 网关自身的 CAS 会话
 *  → 会话身份核验：教务取票 + serviceValidate 验票
 * ```
 *
 * 🔴 **准备页只能用一次，且不能重新 GET**：原版 2.0.2 明确记录「真实 WebVPN 每次
 * GET 登录页都会轮换 captchaId 与 execution」，答案必须配取图时那份准备页提交。
 * 旧实现（照 1.7.2）在提交前又 GET 了一遍登录页，于是服务端的验证码已被换掉、
 * 而用户填的是上一张图的答案 —— 表现为「验证码怎么输都错」。
 *
 * ## 登录态是什么
 *
 * **上游 Cookie**，不是 JWT。`LoginResponse` 的访问令牌字段按契约留空，
 * 会话有效性靠 `validate()`（SSO 验票）实时判定。
 */

const CAS_LOGIN_URL: string = 'https://sso.buaa.edu.cn/login';
const CAS_LOGOUT_URL: string = 'https://sso.buaa.edu.cn/logout';
const CAS_CAPTCHA_URL: string = 'https://sso.buaa.edu.cn/captcha';
const SSO_VALIDATE_URL: string = 'https://sso.buaa.edu.cn/serviceValidate';
const UC_USERINFO_URL: string = 'https://uc.buaa.edu.cn/api/uc/userinfo';
/** UC `api/uc/userinfo` 的「会话未激活/已失效」码（实测未登录态返回 200 + code=10600）。 */
const UC_NOT_ACTIVATED: number = 10600;
const UC_ACTIVATE_URL: string =
  'https://uc.buaa.edu.cn/api/login?target=https%3A%2F%2Fuc.buaa.edu.cn%2F%23%2Fuser%2Flogin';

/** 教务落地页（CAS 的 service），取票后用它验票。 */
const AAS_VERIFY_URL: string =
  'https://byxt.buaa.edu.cn/jwapp/sys/homeapp/index.do?contextPath=/jwapp';

/** 教务取票入口：带 service 的 SSO 登录地址，已有 SSO 会话时直接 302 回带 ticket 的地址。 */
const AAS_LOGIN_URL: string =
  'https://sso.buaa.edu.cn/login?service=https%3A%2F%2Fbyxt.buaa.edu.cn%2Fjwapp%2Fsys%2Fhomeapp%2Findex.do%3FcontextPath%3D%2Fjwapp';

/** WebVPN 网关自身的 CAS 认证入口（service 指回网关）。 */
const GATEWAY_LOGIN_URL: string =
  'https://sso.buaa.edu.cn/login?service=https%3A%2F%2Fd.buaa.edu.cn%2Flogin%3Fcas_login%3Dtrue';

/** 网关根地址：用它确认网关会话已建立（不依赖任何业务站点）。 */
const GATEWAY_ROOT: string = 'https://d.buaa.edu.cn/';

const GATEWAY_HOST: string = 'd.buaa.edu.cn';
const SSO_HOST: string = 'sso.buaa.edu.cn';

/** 单条重定向链最大跳数（正常登录不超过 5 跳，超过说明打转了）。 */
const MAX_REDIRECT_HOPS: number = 10;

/**
 * 验证码自动识别的尝试次数（对齐原版 2.0.2 的「3 次预算」）。
 *
 * 每次失败都必须换服务端新下发的挑战再试 —— 同一个 captchaId 的答案用第二次
 * 一定是错的。用完仍不成功就交回人工输入。
 */
const AUTO_CAPTCHA_ATTEMPTS: number = 3;

/**
 * 准备页（`execution`）在客户端侧的最大可用时长。
 *
 * 服务端 webflow 会话超时后令牌即作废，但具体时长由服务端配置决定、客户端看不到。
 * 这里取一个保守值：超过它就**在提交前**重新取一次登录页（一次 GET，几百毫秒），
 * 避免用死令牌换回一张 `Error decoding flow execution` 错误页。
 *
 * 典型触发场景：应用被冻结在后台过夜，第二天直接点「登录」。
 */
const PREPARED_TTL_MS: number = 5 * 60 * 1000;

/** 供 UI 复用同一口径：登录页据此判断「手里的令牌是不是该换了」。 */
export const LOGIN_PREPARED_TTL_MS: number = PREPARED_TTL_MS;

/** 「webflow 执行上下文失效」的错误码（内部信号，由 login() 消化并自动重试）。 */
const CAS_FLOW_EXPIRED: string = 'cas_flow_expired';

/** UC 的响应信封：{ code, msg, data }。 */
interface UcEnvelope {
  code?: number;
  msg?: string;
  data?: UserInfo;
}

/** serviceValidate 的失败节点。 */
interface CasValidationFailure {
  code?: string;
}

/** serviceValidate 的外层 `serviceResponse`。 */
interface CasServiceResponse {
  authenticationFailure?: CasValidationFailure;
}

/** serviceValidate 的属性集（北航实测为顶层平铺，不是 Apereo 的标准嵌套）。 */
interface CasValidationAttributes {
  employeeNumber?: string[];
  name?: string[];
  type?: string[];
}

/** serviceValidate 响应体。 */
interface CasValidationPayload {
  serviceResponse?: CasServiceResponse;
  user?: string;
  attributes?: CasValidationAttributes;
}

/** 会话校验结果。 */
export enum LocalSessionState {
  /** 上游会话有效。 */
  VALID = 'VALID',
  /** 上游明确表示未登录（应清除本地会话）。 */
  INVALID = 'INVALID',
  /** 上游暂时不可用（5xx / 网络失败），不能据此清除会话。 */
  TRANSIENT = 'TRANSIENT'
}

export class LocalValidation {
  state: LocalSessionState = LocalSessionState.INVALID;
  session: LocalAuthSession | null = null;
}

/**
 * 单条路线的登录结果（双路线登录逐条登记，对齐上游 `RouteLoginState`）。
 */
export enum RouteLoginState {
  /** 该路线会话已建立。 */
  READY = 'READY',
  /** 该路线要用验证码，且本地自动识别未通过（不阻塞其它路线）。 */
  NEEDS_CAPTCHA = 'NEEDS_CAPTCHA',
  /** 该路线明确失败（凭据被拒 / 上游异常）。 */
  FAILED = 'FAILED',
  /** 本次未尝试（例如校园网只认证 Direct）。 */
  SKIPPED = 'SKIPPED'
}

export class RouteLoginResult {
  mode: ConnectionMode = ConnectionMode.DIRECT;
  state: RouteLoginState = RouteLoginState.SKIPPED;
  message: string = '';
}

/**
 * 已准备的登录页。
 *
 * `execution` 与 `captchaId` 是**一对**：服务端在每次渲染登录页时同时下发，
 * 提交时必须用同一份，不能拿 A 页的令牌配 B 页的验证码。
 */
class PreparedLogin {
  /** 页面 HTML（构造普通登录表单要按页面里的真实字段复制隐藏域）。 */
  html: string = '';
  /** 一次性令牌。 */
  execution: string = '';
  /** 验证码标识（`''` 表示这一页不需要验证码）。 */
  captchaId: string = '';
  /**
   * 这一页属于哪条路线。
   *
   * 登录页的一次性令牌只对**下发它的那条路线**有效（Direct 与 WebVPN 是两套
   * Cookie 罐、两条 webflow 会话）。双路线登录会先后跑两条流程，不校验来源就会
   * 拿 A 路的令牌去 B 路提交 —— 必然被判无效。
   */
  mode: ConnectionMode = ConnectionMode.DIRECT;
  /**
   * 取到这一页的时刻（毫秒时间戳）。
   *
   * `execution` 的寿命由**服务端的 webflow 会话**决定，不由客户端决定：
   * 应用被冻结在后台过夜后，手里的令牌早已随会话超时作废，再拿去提交只会换回
   * 一张 `Error decoding flow execution` 错误页。记时间戳是为了在提交前判掉它。
   */
  preparedAt: number = 0;
}

function nowIso(): string {
  return new Date().toISOString();
}

function toUserData(session: LocalAuthSession): UserData {
  return { name: session.userName, schoolid: session.schoolId };
}

/** 取 URL 的主机名（小写；解析不出返回空串）。 */
function hostOfUrl(raw: string): string {
  const schemeIndex = raw.indexOf('://');
  if (schemeIndex < 0) {
    return '';
  }
  let rest = raw.substring(schemeIndex + 3);
  const slashIndex = rest.indexOf('/');
  if (slashIndex >= 0) {
    rest = rest.substring(0, slashIndex);
  }
  const at = rest.lastIndexOf('@');
  if (at >= 0) {
    rest = rest.substring(at + 1);
  }
  const colonIndex = rest.lastIndexOf(':');
  const host = colonIndex > 0 ? rest.substring(0, colonIndex) : rest;
  return host.toLowerCase();
}

/** 取 URL 的路径（不含查询串）。 */
function pathOfUrl(raw: string): string {
  const schemeIndex = raw.indexOf('://');
  if (schemeIndex < 0) {
    return '';
  }
  const rest = raw.substring(schemeIndex + 3);
  const slashIndex = rest.indexOf('/');
  if (slashIndex < 0) {
    return '/';
  }
  const pathAndQuery = rest.substring(slashIndex);
  const queryIndex = pathAndQuery.indexOf('?');
  const hashIndex = pathAndQuery.indexOf('#');
  let end: number = pathAndQuery.length;
  if (queryIndex >= 0 && queryIndex < end) {
    end = queryIndex;
  }
  if (hashIndex >= 0 && hashIndex < end) {
    end = hashIndex;
  }
  return pathAndQuery.substring(0, end);
}

/** 从回调地址里取 `ticket`（先解包 WebVPN 包装）。 */
async function ticketOf(location: string): Promise<string> {
  if (location.length === 0) {
    return '';
  }
  const direct: string = await LocalWebVpn.fromWebVpnUrl(location);
  const queryIndex: number = direct.indexOf('?');
  if (queryIndex < 0) {
    return '';
  }
  let query: string = direct.substring(queryIndex + 1);
  const hashIndex: number = query.indexOf('#');
  if (hashIndex >= 0) {
    query = query.substring(0, hashIndex);
  }
  const pairs: string[] = query.split('&');
  for (let i = 0; i < pairs.length; i++) {
    const eq: number = pairs[i].indexOf('=');
    if (eq <= 0 || pairs[i].substring(0, eq) !== 'ticket') {
      continue;
    }
    const value: string = pairs[i].substring(eq + 1).trim();
    return value;
  }
  return '';
}

export class LocalAuthService {
  /**
   * 最近一次准备出来的登录页。
   *
   * 进程内单例：验证码答案必须配这份状态提交（见类注释）。任何「重新准备」都会
   * 覆盖它，旧答案随之作废 —— 这正是服务端的语义。
   */
  private static prepared: PreparedLogin | null = null;

  /**
   * 取当前路线可用的准备页。
   *
   * 落在别的路线上的准备页等同「没有」—— 令牌与那份 Cookie 罐绑定，
   * 拿它去另一条路提交只会换回「凭据无效」。
   */
  private static preparedFor(mode: ConnectionMode): PreparedLogin | null {
    const current: PreparedLogin | null = LocalAuthService.prepared;
    if (current === null || current.mode !== mode) {
      return null;
    }
    return current;
  }

  /* ============================ 登录前置 ============================ */

  /**
   * 拉取登录页，取出一次性令牌并探测验证码。
   *
   * 与 2.0.2 `prepare_interactive` 一致：302 说明已有 SSO 会话，此时直接核验身份
   * 并把用户信息带回去（不再走一次凭据提交）。
   */
  static async preload(): Promise<LoginPreloadResponse> {
    // 登录页已经用 prepareForLogin() 选好路线；请求入口的「借回活会话」不能把
    // 这次预热拉回另一条路（否则令牌与实际提交时的路线不匹配，必判凭据无效）。
    RouteScope.enter(TokenStore.getConnectionMode());
    try {
      return await LocalAuthService.preloadScoped();
    } finally {
      RouteScope.exit();
    }
  }

  /** 已锁定路线作用域内的预热实现。 */
  private static async preloadScoped(): Promise<LoginPreloadResponse> {
    const result: LoginPreloadResponse = { captchaRequired: false };
    // 后台预热验证码识别模型（首次要把 52 MB 模型释放到沙箱，不阻塞登录页）
    if (!CaptchaRecognizer.isReady()) {
      CaptchaRecognizer.ensureReady();
    }
    const page = await UpstreamClient.get(CAS_LOGIN_URL, false);
    if (page.isRedirect()) {
      LocalAuthService.prepared = null;
      const validation = await LocalAuthService.validate();
      if (validation.state === LocalSessionState.VALID && validation.session !== null) {
        TokenStore.saveLocalSession(validation.session, RouteScope.mode());
        result.userData = toUserData(validation.session);
      }
      return result;
    }
    if (!page.isOk()) {
      return result;
    }
    const prepared: PreparedLogin = LocalAuthService.parsePage(page.body);
    result.execution = prepared.execution;
    if (prepared.captchaId.length > 0) {
      result.captchaRequired = true;
      // 取一次图片：既内联给 UI 显示，也顺手本地识别出答案（预填，省得手输）
      const bytes: Uint8Array | null = await LocalAuthService.fetchCaptchaBytes(prepared.captchaId);
      if (bytes !== null) {
        const helper = new util.Base64Helper();
        const info: CaptchaInfo = {
          id: prepared.captchaId,
          type: 'image',
          imageUrl: CAS_CAPTCHA_URL + '?captchaId=' + prepared.captchaId,
          base64Image: 'data:image/jpeg;base64,' + helper.encodeToStringSync(bytes)
        };
        result.captcha = info;
        const started: number = Date.now();
        const answer: string = await CaptchaRecognizer.recognizeImage(bytes);
        if (answer.length === 6) {
          result.captchaAnswer = answer;
          Logger.info('验证码预识别：' + answer + '（' + (Date.now() - started) + 'ms）');
        } else {
          Logger.warn('验证码预识别未收敛，需人工输入（' + (Date.now() - started) + 'ms）');
        }
      }
    }
    return result;
  }

  /* ============================== 登录 ============================== */

  /**
   * 执行一次完整登录。
   *
   * 两条互斥路径：
   * - **带验证码**：直接提交准备页（不重新 GET，见类注释），失败按「验证未完成」处理；
   * - **不带验证码**：普通表单提交；页面过期换新页重来一次，WebVPN 模式下整链失败
   *   再追加一次重试（2.0.2 口径）。
   *
   * @throws CaptchaRequiredError 需要验证码 / 验证码被拒（携带新图与配套 execution）
   * @throws ApiError 凭据错误（`cas_login_failed`）/ 上游不可用（`auth_upstream_timeout`）
   */
  static async login(
    username: string,
    password: string,
    captcha: string,
    execution: string
  ): Promise<LoginResponse> {
    if (captcha.length > 0) {
      return await LocalAuthService.submitCaptcha(username, password, captcha, execution);
    }
    const mode: ConnectionMode = RouteScope.mode();
    /**
     * 最多两轮：第一轮撞上「流程上下文失效」（`execution` 已随服务端会话超时作废，
     * 典型场景是应用被冻结在后台过夜、第二天直接点登录）时，丢掉准备页、取一张新
     * 登录页**整轮**重来一次。只重试一次 —— 再失败说明上游确有异常，不该空转。
     */
    for (let round = 0; round < 2; round++) {
      try {
        return await LocalAuthService.loginAttempt(username, password);
      } catch (error) {
        if (round === 0 && LocalAuthService.isFlowExpired(error)) {
          Logger.warn('CAS 登录流程上下文已失效（execution 过期 / 被回收），换新登录页重试');
          LocalAuthService.prepared = null;
          continue;
        }
        // 需要验证码：`loginAttempt` 已试过本地自动识别，这里直接把挑战交给 UI
        if (error instanceof CaptchaRequiredError) {
          throw error as Error;
        }
        if (!LocalAuthService.shouldRetryLogin(mode, error)) {
          LocalAuthService.prepared = null;
          throw error as Error;
        }
        // 2.0.2：WebVPN 下「明确凭据拒绝 / 网络 / 超时 / 上游不可用」整链重试一次。
        // 重试前必须丢掉旧准备页 —— 复用已提交的 execution 一定被判无效。
        Logger.warn('WebVPN 登录失败，整链重试一次：' + (error as Error).message);
        LocalAuthService.prepared = null;
        return await LocalAuthService.loginOnce(username, password);
      }
    }
    throw new ApiError(400, CAS_FLOW_EXPIRED, '登录页面已失效，请重新点击登录');
  }

  /**
   * 双路线登录（对齐上游 `facade/auth.rs::login`）。
   *
   * 为什么必须两条都登：登录态是**按路线隔离的 Cookie 罐**，另一条路线上没有会话，
   * 一旦换网（校内↔校外）就要重新输密码。原版之所以「换网、冷启动都不用重登」，
   * 一半靠这个（另一半靠静默重认证，见 `SessionGuard`）。
   *
   * 失败语义：
   * - **主路线**失败照旧抛出（含 `CaptchaRequiredError`），由登录页展示；
   * - **副路线**失败只登记不抛出 —— 另一条通道的验证码不该阻塞已经可用的主通道
   *   （上游同样是 `partial`，只要求「至少一条就绪」）。
   */
  static async loginDual(
    username: string,
    password: string,
    captcha: string,
    execution: string
  ): Promise<LoginResponse> {
    const routes: ConnectionMode[] = await RouteEngine.loginRoutes();
    // 主路线必须是 App 接下来实际走的那条，否则登录完还是一条空罐
    if (routes.length > 0 && TokenStore.getConnectionMode() !== routes[0]) {
      RouteEngine.pinMode(routes[0]);
    }
    let primary: LoginResponse | null = null;
    const results: RouteLoginResult[] = [];
    for (let i = 0; i < routes.length; i++) {
      const route: ConnectionMode = routes[i];
      const isPrimary: boolean = i === 0;
      const result: RouteLoginResult = new RouteLoginResult();
      result.mode = route;
      RouteScope.enter(route);
      try {
        const response: LoginResponse = await LocalAuthService.login(
          username, password, isPrimary ? captcha : '', isPrimary ? execution : '');
        result.state = RouteLoginState.READY;
        if (primary === null) {
          primary = response;
        }
        Logger.info('双路线登录：' + route + ' 已就绪' + (isPrimary ? '（主）' : '（备）'));
      } catch (error) {
        if (isPrimary) {
          throw error as Error;
        }
        if (error instanceof CaptchaRequiredError) {
          result.state = RouteLoginState.NEEDS_CAPTCHA;
          result.message = '备用通道待验证码';
        } else {
          result.state = RouteLoginState.FAILED;
          result.message = (error as Error).message;
        }
        Logger.warn('双路线登录：备用通道 ' + route + ' 未就绪（' + result.message + '）');
      } finally {
        RouteScope.exit();
        results.push(result);
      }
    }
    const ready: LoginResponse | null = primary;
    if (ready === null) {
      throw new ApiError(401, 'cas_login_failed', '登录未能完成，请重试');
    }
    return ready;
  }

  /**
   * 一轮完整登录（不含 WebVPN 整链重试与「页面过期」重来）。
   *
   * 页面要求验证码时先本地自动识别（不上传图片，最多 `AUTO_CAPTCHA_ATTEMPTS` 次），
   * 全部失败才把挑战交回 UI 让人工输入。
   */
  private static async loginAttempt(
    username: string,
    password: string
  ): Promise<LoginResponse> {
    try {
      return await LocalAuthService.loginOnce(username, password);
    } catch (error) {
      if (!(error instanceof CaptchaRequiredError)) {
        throw error as Error;
      }
      const auto: LoginResponse | null =
        await LocalAuthService.loginWithAutoCaptcha(username, password);
      if (auto !== null) {
        return auto;
      }
      throw error as Error;
    }
  }

  /** 是否为「webflow 执行上下文失效」类错误（据此自动换新页面重试）。 */
  private static isFlowExpired(error: Object): boolean {
    return error instanceof ApiError && (error as ApiError).code === CAS_FLOW_EXPIRED;
  }

  /** 准备页是否超过客户端可用期（服务端大概率也已回收该 `execution`）。 */
  private static isStale(prepared: PreparedLogin): boolean {
    if (prepared.preparedAt <= 0) {
      return true;
    }
    return Date.now() - prepared.preparedAt > PREPARED_TTL_MS;
  }

  /** 是否要按 2.0.2 的 WebVPN 口径整链重试一次（交互验证不自动重放）。 */
  private static shouldRetryLogin(mode: ConnectionMode, error: Object): boolean {
    if (mode !== ConnectionMode.WEBVPN) {
      return false;
    }
    if (error instanceof CaptchaRequiredError) {
      return false;
    }
    if (!(error instanceof ApiError)) {
      return false;
    }
    const apiError = error as ApiError;
    if (apiError.networkFailure) {
      return true;
    }
    return apiError.code === 'cas_login_failed' || apiError.code === 'upstream_down';
  }

  /**
   * 普通（无验证码）登录。
   *
   * 🔴 **准备页存在且未过期时不再 GET**：重新取页会轮换 execution，等于把手中令牌作废。
   * 反之，准备页一旦过期就必须先换页 —— 死令牌提交上去只会换回
   * 「Error decoding flow execution」，而这正是「过夜后第一次点登录必失败」的成因。
   */
  private static async loginOnce(
    username: string,
    password: string
  ): Promise<LoginResponse> {
    let prepared: PreparedLogin | null = LocalAuthService.preparedFor(RouteScope.mode());
    if (prepared !== null && LocalAuthService.isStale(prepared)) {
      Logger.info('登录准备页已过期（持有 ' +
        Math.round((Date.now() - prepared.preparedAt) / 1000) + 's），重新取登录页');
      prepared = null;
      LocalAuthService.prepared = null;
    }
    if (prepared === null) {
      const page = await UpstreamClient.get(CAS_LOGIN_URL, false);
      if (page.isRedirect()) {
        // 已有 SSO 会话：不必再提交凭据，直接去 UC 换会话
        Logger.info('SSO 已存在会话，跳过凭据提交');
        await LocalAuthService.activateGateway();
        return await LocalAuthService.finishLogin();
      }
      if (!page.isOk()) {
        throw new ApiError(page.status, 'cas_page_failed',
          '统一身份认证页面加载失败（HTTP ' + page.status + '），请确认网络；连接方式建议用「自动」');
      }
      const tip: string = CasParser.extractTipText(page.body);
      if (tip.length > 0) {
        throw new ApiError(400, 'cas_login_failed', tip);
      }
      prepared = LocalAuthService.parsePage(page.body);
    }

    if (prepared.captchaId.length > 0) {
      // 这一页要求验证码：把挑战交给 UI，让用户看图后再提交
      throw new CaptchaRequiredError(
        await LocalAuthService.hydrateCaptcha(prepared.captchaId),
        prepared.execution,
        '本次登录需要验证码'
      );
    }

    // 页面里的令牌是唯一权威来源：它来自刚刚登记的准备页（比调用方手里任何
    // 缓存值都新）。旧实现优先用调用方传进来的 execution，过夜后传的是隔夜死令牌。
    const form: string = CasParser.buildLoginBody(prepared.html, username, password,
      prepared.execution, '');
    Logger.info('提交 CAS 凭据：账号 ' + username + '，模式 ' +
      RouteScope.mode() + '，目标 ' + CAS_LOGIN_URL);
    const submit = await UpstreamClient.postForm(CAS_LOGIN_URL, form, false);
    Logger.info('CAS 提交响应：状态 ' + submit.status.toString() +
      '，Location ' + submit.location + '，最终地址 ' + submit.url);
    await LocalAuthService.followAndCheck(submit);
    await LocalAuthService.activateGateway();
    return await LocalAuthService.finishLogin();
  }

  /**
   * 带验证码提交。
   *
   * 必须使用取图时那份准备页的 `execution`，**不能在提交前重新 GET 登录页** ——
   * 服务端每次渲染都会同时换掉 captchaId 与 execution，重新取页会让用户手里的
   * 答案与令牌错位，表现就是「验证码怎么输都错」。
   */
  private static async submitCaptcha(
    username: string,
    password: string,
    captcha: string,
    execution: string
  ): Promise<LoginResponse> {
    const prepared: PreparedLogin | null = LocalAuthService.preparedFor(RouteScope.mode());
    // 调用方没带 execution 时用准备页自己的（UI 失败后可能已清空变量）
    const expected: string = execution.length > 0 ? execution :
      (prepared === null ? '' : prepared.execution);
    if (prepared === null || LocalAuthService.isStale(prepared) ||
      prepared.captchaId.length === 0 || prepared.execution !== expected) {
      // 状态已被换掉（重新预热 / 换路线 / 进程重启 / 令牌过夜过期）：
      // 重新取一份挑战交给 UI —— 旧图与旧令牌是一对，已一起作废。
      const fresh: PreparedLogin = await LocalAuthService.reprepare();
      if (fresh.captchaId.length === 0) {
        // 新页面不再要验证码：用户手上那张图连同旧令牌一起作废，直接按普通登录走
        Logger.info('新准备的登录页不再要求验证码，改走普通登录');
        return await LocalAuthService.loginOnce(username, password);
      }
      throw new CaptchaRequiredError(
        await LocalAuthService.hydrateCaptcha(fresh.captchaId),
        fresh.execution,
        '验证状态已变化，请重新输入验证码'
      );
    }

    const form: string = CasParser.buildCaptchaLoginBody(username, password, captcha,
      prepared.execution);
    const submit = await UpstreamClient.postForm(CAS_LOGIN_URL, form, false);
    const body: string = submit.body;
    Logger.info('CAS 验证码提交响应：状态 ' + submit.status.toString() +
      '，Location ' + submit.location);

    // 真实 SSO 对「验证码错」与「密码错」使用同一句文案，并同时下发下一次图像挑战。
    // 判据必须带上「页面仍要求 image 验证码」，否则会把真的密码错误吃成验证码错误。
    if (submit.status === 401 && CasParser.findLoginError(body).length > 0 &&
      CasParser.captchaType(body) === 'image') {
      const next: PreparedLogin = LocalAuthService.parsePage(body);
      throw new CaptchaRequiredError(
        await LocalAuthService.hydrateCaptcha(next.captchaId),
        next.execution,
        '验证未通过，请重新输入验证码'
      );
    }

    await LocalAuthService.followAndCheck(submit);
    await LocalAuthService.activateGateway();
    return await LocalAuthService.finishLogin();
  }

  /**
   * 自动识别验证码并登录（最多 `AUTO_CAPTCHA_ATTEMPTS` 次）。
   *
   * 每次都用**当前准备页**的 captchaId 取图、本地识别、按八字段表单提交；
   * 被拒时服务端会同时下发新的 captchaId 与 execution（页面里就带着），
   * 解析出来接着试下一张。
   *
   * @returns 成功返回登录结果；识别不出 / 次数用尽返回 `null`（调用方转人工）
   */
  private static async loginWithAutoCaptcha(
    username: string,
    password: string
  ): Promise<LoginResponse | null> {
    for (let attempt = 0; attempt < AUTO_CAPTCHA_ATTEMPTS; attempt++) {
      const prepared: PreparedLogin | null = LocalAuthService.preparedFor(RouteScope.mode());
      if (prepared === null || prepared.captchaId.length === 0) {
        return null;
      }
      const bytes: Uint8Array | null = await LocalAuthService.fetchCaptchaBytes(prepared.captchaId);
      if (bytes === null) {
        return null;
      }
      const answer: string = await CaptchaRecognizer.recognizeImage(bytes);
      if (answer.length !== 6) {
        Logger.warn('验证码自动识别未收敛（第 ' + (attempt + 1) + ' 次），转人工输入');
        return null;
      }
      Logger.info('验证码自动识别：' + answer + '（第 ' + (attempt + 1) + ' 次）');

      const form: string = CasParser.buildCaptchaLoginBody(username, password, answer,
        prepared.execution);
      const submit = await UpstreamClient.postForm(CAS_LOGIN_URL, form, false);
      const body: string = submit.body;
      // 验证码被拒：服务端在同一响应里给了新的挑战，解析出来再试一次
      if (submit.status === 401 && CasParser.findLoginError(body).length > 0 &&
        CasParser.captchaType(body) === 'image') {
        LocalAuthService.parsePage(body);
        continue;
      }
      await LocalAuthService.followAndCheck(submit);
      await LocalAuthService.activateGateway();
      return await LocalAuthService.finishLogin();
    }
    Logger.warn('验证码自动识别已用尽 ' + AUTO_CAPTCHA_ATTEMPTS + ' 次，转人工输入');
    return null;
  }

  /** 重新取一次登录页并登记为当前准备页。 */
  private static async reprepare(): Promise<PreparedLogin> {
    LocalAuthService.prepared = null;
    const page = await UpstreamClient.get(CAS_LOGIN_URL, false);
    if (!page.isOk()) {
      throw new ApiError(page.status, 'cas_page_failed',
        '统一身份认证页面加载失败（HTTP ' + page.status + '），请稍后重试');
    }
    return LocalAuthService.parsePage(page.body);
  }

  /** 解析登录页并**登记**为当前准备页（令牌与验证码成对保存）。 */
  private static parsePage(html: string): PreparedLogin {
    const reason: string = CasParser.unsupportedInteraction(html);
    if (reason.length > 0) {
      throw new ApiError(500, 'cas_page_failed',
        '统一认证页面要求了本应用尚未支持的验证步骤（' + reason + '），请稍后重试或联系学校信息中心');
    }
    const captchaType: string = CasParser.captchaType(html);
    if (captchaType.length > 0 && captchaType !== 'image') {
      throw new ApiError(500, 'cas_page_failed',
        '统一认证页面要求了尚未支持的验证方式（' + captchaType + '），请稍后重试');
    }
    const execution: string = CasParser.extractExecution(html);
    if (execution.length === 0) {
      // 拿空令牌去提交只会被服务端判成「凭据无效」，报错会指向错误的方向
      throw new ApiError(500, 'cas_page_failed',
        '未能从统一认证页面解析到登录令牌，页面可能已改版或网络被劫持，请稍后重试');
    }
    const prepared = new PreparedLogin();
    prepared.html = html;
    prepared.execution = execution;
    const captcha: CaptchaInfo | null = CasParser.detectCaptcha(html, CAS_CAPTCHA_URL);
    prepared.captchaId = captcha === null ? '' : captcha.id;
    prepared.mode = RouteScope.mode();
    // 记下取页时刻：`execution` 的寿命跟服务端 webflow 会话走，客户端只能按时间判旧
    prepared.preparedAt = Date.now();
    LocalAuthService.prepared = prepared;
    return prepared;
  }

  /** 提交成功后收尾：激活 UC、核验身份、落盘会话。 */
  private static async finishLogin(): Promise<LoginResponse> {
    // 保留 UC 会话激活：本应用的「个人信息」等页面直接读 uc/userinfo，
    // 2.0.2 已用 SSO 验票替代它，但客户端仍需要这条会话（有意保留的差异）。
    await LocalAuthService.activateUcLogin();
    const validation = await LocalAuthService.validate();
    if (validation.state === LocalSessionState.VALID && validation.session !== null) {
      const session = validation.session;
      TokenStore.saveLocalSession(session, RouteScope.mode());
      LocalAuthService.prepared = null;
      Logger.info('本地模式登录成功：' + session.userName + ' / ' + session.schoolId);
      return {
        user: toUserData(session),
        // 本地模式没有 JWT，令牌字段按契约留空（参考实现同样如此）
        accessToken: '',
        refreshToken: '',
        accessTokenExpiresAt: '',
        refreshTokenExpiresAt: ''
      };
    }
    if (validation.state === LocalSessionState.TRANSIENT) {
      throw new ApiError(503, 'auth_upstream_timeout', '统一认证服务响应超时，请稍后重试');
    }
    throw new ApiError(401, 'cas_login_failed', '登录未能完成身份核验，请重试');
  }

  /* ============================ 会话校验 ============================ */

  /**
   * 实时校验上游会话（2.0.2 口径：教务取票 + `serviceValidate` 验票）。
   *
   * 为什么不用 `uc/status`：那是 1.7.2 的判据，UC 侧会话与 CAS 会话是两套东西，
   * UC 掉线并不等于 CAS 失效（反之亦然）。原版 2.0.x 改为直接问 CAS 要票据。
   *
   * 必须区分「未登录」与「上游挂了」：前者要清本地会话并回登录页，后者清掉会
   * 让用户在网络抖动时被莫名登出。
   */
  static async validate(): Promise<LocalValidation> {
    const result = new LocalValidation();
    let ticket: string = '';
    try {
      const login = await UpstreamClient.get(AAS_LOGIN_URL, false);
      // 401，或 200 却回到带 execution 的登录页 → 会话已失效
      if (login.status === 401 ||
        (login.status === 200 && CasParser.extractExecution(login.body).length > 0)) {
        result.state = LocalSessionState.INVALID;
        return result;
      }
      if (login.status >= 500) {
        result.state = LocalSessionState.TRANSIENT;
        return result;
      }
      if (login.status !== 302) {
        result.state = LocalSessionState.INVALID;
        return result;
      }
      ticket = await ticketOf(login.location);
      if (ticket.length === 0) {
        result.state = LocalSessionState.INVALID;
        return result;
      }
    } catch (error) {
      Logger.warn('取票失败：' + (error as Error).message);
      result.state = LocalSessionState.TRANSIENT;
      return result;
    }

    const validateUrl: string = SSO_VALIDATE_URL +
      '?service=' + encodeURIComponent(AAS_VERIFY_URL) +
      '&ticket=' + encodeURIComponent(ticket) + '&format=JSON';
    let response: UpstreamResponse;
    try {
      response = await UpstreamClient.get(validateUrl, false);
    } catch (error) {
      Logger.warn('验票网络失败：' + (error as Error).message);
      result.state = LocalSessionState.TRANSIENT;
      return result;
    }
    if (response.status >= 500) {
      result.state = LocalSessionState.TRANSIENT;
      return result;
    }
    if (!response.isOk()) {
      result.state = LocalSessionState.INVALID;
      return result;
    }
    if (!response.body.trimStart().startsWith('{')) {
      result.state = LocalSessionState.INVALID;
      return result;
    }

    let payload: CasValidationPayload;
    try {
      payload = JSON.parse(response.body) as CasValidationPayload;
    } catch (error) {
      Logger.warn('验票响应解析失败');
      result.state = LocalSessionState.INVALID;
      return result;
    }
    const failure = payload.serviceResponse === undefined ? undefined :
      payload.serviceResponse.authenticationFailure;
    if (failure !== undefined && failure.code === 'INVALID_TICKET') {
      result.state = LocalSessionState.INVALID;
      return result;
    }
    const rawUser: string = payload.user === undefined ? '' : payload.user.trim();
    const attributes = payload.attributes;
    const ids: string[] = attributes === undefined || attributes.employeeNumber === undefined ?
      [] : attributes.employeeNumber;
    if (rawUser.length === 0 || ids.length !== 1) {
      result.state = LocalSessionState.INVALID;
      return result;
    }
    const schoolId: string = ids[0].trim();
    if (schoolId.length === 0) {
      result.state = LocalSessionState.INVALID;
      return result;
    }
    const names: string[] = attributes === undefined || attributes.name === undefined ?
      [] : attributes.name;
    const userName: string = names.length === 1 ? names[0].trim() : '';

    const previous = TokenStore.getLocalSession(RouteScope.mode());
    const session: LocalAuthSession = {
      username: rawUser,
      userName: userName,
      schoolId: schoolId,
      authenticatedAt: previous !== null && previous.authenticatedAt.length > 0
        ? previous.authenticatedAt
        : nowIso(),
      lastActivity: nowIso()
    };

    result.state = LocalSessionState.VALID;
    result.session = session;
    return result;
  }

  /** 查询登录状态（Index 恢复会话 / 设置页展示用）。 */
  static async status(): Promise<SessionStatusResponse> {
    const stored = TokenStore.getLocalSession(RouteScope.mode());
    if (stored === null) {
      throw ApiError.unauthorized();
    }
    const validation = await LocalAuthService.validate();
    if (validation.state === LocalSessionState.VALID && validation.session !== null) {
      const session = validation.session;
      TokenStore.saveLocalSession(session, RouteScope.mode());
      return {
        user: toUserData(session),
        lastActivity: session.lastActivity,
        authenticatedAt: session.authenticatedAt
      };
    }
    if (validation.state === LocalSessionState.TRANSIENT) {
      throw new ApiError(503, 'auth_upstream_timeout', '统一认证服务响应超时，请稍后重试');
    }
    TokenStore.clearLocalSession(RouteScope.mode());
    throw ApiError.unauthorized();
  }

  /**
   * 注销：尽力通知上游退出，随后无条件清空本地登录态。
   *
   * 两条路线各有一套 CAS 会话（Cookie 罐隔离），只销一条会留下另一个仍然有效的
   * 上游会话 —— 对齐上游 `logout` 对两个 runtime 各调一次 `remote_logout`。
   * 只对**确实有会话**的路线发请求，不必多打一次。
   */
  static async logout(): Promise<void> {
    const routes: ConnectionMode[] = [ConnectionMode.DIRECT, ConnectionMode.WEBVPN];
    for (let i = 0; i < routes.length; i++) {
      const route: ConnectionMode = routes[i];
      if (!TokenStore.hasLocalSession(route)) {
        continue;
      }
      RouteScope.enter(route);
      try {
        await LocalAuthService.followTo(CAS_LOGOUT_URL);
      } catch (error) {
        Logger.warn('上游注销失败（' + route + '），本地登录态仍会清除：' +
          (error as Error).message);
      } finally {
        RouteScope.exit();
      }
    }
    LocalAuthService.prepared = null;
    TokenStore.clearAllLocalSessions();
  }

  /* ============================ 用户信息 ============================ */

  /**
   * 从校内用户中心读取个人信息（本地模式下这是唯一可用的用户信息源）。
   *
   * 2026-11-22 修复「个人资料始终获取失败」：UC 会话与 SSO 会话是**两套**，
   * `activateUcLogin()` 原本只在 `finishLogin()` 里调一次；换网 / 自动切路线 /
   * 冷启动后 UC 那枚 cookie 掉了，而 SSO 仍有效 —— 此时 userinfo 返回 200 +
   * `{"code":10600,"data":null}`（实测未登录态就是这个结构），不是 302，
   * 于是旧代码直接抛 `user_info_failed`，页面永远显示「获取失败」。
   *
   * 修法：识别 10600 时用**现有 SSO 会话**重建一次 UC 会话（`activateUcLogin`
   * 会带 ticket 跳回 UC，幂等），再重试一次读取。SSO 也失效时重建会抛 CAS 错误，
   * 交给上层的 SessionGuard / 重新登录处理，不在本方法里死循环。
   */
  static async fetchUserInfo(): Promise<UserInfo> {
    const response = await UpstreamClient.get(UC_USERINFO_URL, false, {
      'X-Requested-With': 'XMLHttpRequest'
    });
    // 非 2xx / 非 JSON：会话级失败（大概率 302 到 SSO），沿用原来的 unauthorized 语义
    if (!response.isOk() || !response.body.trimStart().startsWith('{')) {
      throw ApiError.unauthorized();
    }
    let envelope = JSON.parse(response.body) as UcEnvelope;
    let code: number = envelope.code === undefined ? -1 : envelope.code;
    // 10600 = UC 会话未激活/已失效，但 SSO 多半还有效 —— 重建一次再读
    if (code === UC_NOT_ACTIVATED) {
      Logger.info('UC 会话未激活（code=10600），用现有 SSO 会话重建后重试');
      await LocalAuthService.activateUcLogin();
      const retry = await UpstreamClient.get(UC_USERINFO_URL, false, {
        'X-Requested-With': 'XMLHttpRequest'
      });
      if (retry.isOk() && retry.body.trimStart().startsWith('{')) {
        envelope = JSON.parse(retry.body) as UcEnvelope;
        code = envelope.code === undefined ? -1 : envelope.code;
      }
    }
    if (code !== 0 || envelope.data === undefined || envelope.data === null) {
      throw new ApiError(500, 'user_info_failed', '个人信息获取失败，请稍后重试');
    }
    return envelope.data;
  }

  /** 验证码图片地址（本地模式下直接指向统一认证的验证码接口）。 */
  static captchaUrl(captchaId: string): string {
    return CAS_CAPTCHA_URL + '?captchaId=' + captchaId;
  }

  /* ============================== 内部 ============================== */

  /**
   * 拉取验证码图片并内联成 data URI。
   *
   * 图片必须与登录页走**同一条路线**（WebVPN 模式下经网关取）—— 验证码是按
   * 会话下发的，换个域名去取会拿到一张与当前会话无关的图。
   */
  private static async hydrateCaptcha(captchaId: string): Promise<CaptchaInfo> {
    const salt: number = Date.now();
    const captcha: CaptchaInfo = {
      id: captchaId,
      type: 'image',
      // 随机参数只用于绕过上游/网关的图片缓存，不参与业务语义
      imageUrl: CAS_CAPTCHA_URL + '?captchaId=' + captchaId + '&r=' + salt.toString()
    };
    const bytes: Uint8Array | null = await LocalAuthService.fetchCaptchaBytes(captchaId);
    if (bytes !== null) {
      const helper = new util.Base64Helper();
      captcha.base64Image = 'data:image/jpeg;base64,' + helper.encodeToStringSync(bytes);
    }
    return captcha;
  }

  /**
   * 取验证码图片的原始字节（自动识别与内联展示共用这一次请求）。
   *
   * 必须与登录页走同一条路线（WebVPN 下经网关）：验证码是按会话下发的，
   * 换个域名去取会拿到与当前会话无关的图。
   */
  private static async fetchCaptchaBytes(captchaId: string): Promise<Uint8Array | null> {
    if (captchaId.length === 0) {
      return null;
    }
    const url: string = CAS_CAPTCHA_URL + '?captchaId=' + captchaId +
      '&r=' + Date.now().toString();
    try {
      const response = await UpstreamClient.getBinary(url);
      if (response.isOk() && response.bytes !== null && response.bytes.length > 0) {
        return response.bytes;
      }
    } catch (error) {
      Logger.warn('验证码图片获取失败：' + (error as Error).message);
    }
    return null;
  }

  /**
   * 用已有的 SSO 会话换取 UC 会话。
   *
   * UC 侧没有会话时会 302 到统一认证，再拿 ticket 跳回来 —— 这条链上的每一跳
   * 都必须带上各自域名的 Cookie，所以只能逐跳手动跟随（见 followTo 的注释）。
   */
  private static async activateUcLogin(): Promise<void> {
    // ⚠️ **必须带错误检查**（对齐原版 `activateUcLogin` 用的是
    // `followRedirectsAndCheckError`）—— 只跟随不检查的话，
    // UC 侧失败会被静默吞掉，最后只能报「账号或密码验证未通过」这种
    // **指向错误方向**的提示（密码其实是对的，是会话没建起来）。
    const response = await LocalAuthService.followTo(UC_ACTIVATE_URL);
    const body: string = response.body;
    const markerIndex: number = response.url.indexOf('exception.message=');
    if (markerIndex >= 0) {
      throw new ApiError(401, 'cas_login_failed', LocalAuthService.decodeMessage(
        response.url.substring(markerIndex + 'exception.message='.length)
      ));
    }
    // 令牌随服务端 webflow 会话超时而作废：交由 login() 换新页面整轮重试
    if (CasParser.isFlowExecutionExpired(body)) {
      throw new ApiError(400, CAS_FLOW_EXPIRED, 'CAS 登录流程上下文已失效（execution 已过期）');
    }
    const loginError: string = CasParser.findLoginError(body);
    if (response.status === 401 || loginError.length > 0) {
      throw new ApiError(401, 'cas_login_failed',
        loginError.length > 0 ? loginError : '账号或密码错误，请重试');
    }
    Logger.info('UC 会话激活完成，最终状态 ' + response.status);
  }

  /**
   * 激活 WebVPN 网关**自身**的 CAS 会话（对齐 2.0.2 `auth/gateway.rs`）。
   *
   * 为什么需要：网关是独立的一层 CAS 客户端。只把业务请求包装成网关地址，
   * 网关自身仍是未登录状态，一部分站点会被它拦在自己的登录页上。原版在
   * 登录成功后立刻用同一个 SSO 会话把网关也登一次，且只认网关根地址的
   * 落地结果（不依赖任何业务站点）。
   *
   * 非 WebVPN 模式直接返回。
   */
  private static async activateGateway(): Promise<void> {
    if (RouteScope.mode() !== ConnectionMode.WEBVPN) {
      return;
    }
    try {
      await LocalAuthService.runGatewayActivation();
    } catch (error) {
      // 网关激活只是「加分项」：这一步失败**不能**把已经建立的 CAS 会话判成登录失败。
      // 实测踩过：握手链末尾停在被代理的业务页（200），被当成失败 →
      // 用户「第一次点登录报错、再点一次才成功」。
      Logger.warn('WebVPN 网关激活未完成（不影响登录）：' + (error as Error).message);
    }
  }

  /** 真正的网关握手（成功/失败由调用方决定如何处置）。 */
  private static async runGatewayActivation(): Promise<void> {
    let current: string = GATEWAY_LOGIN_URL;
    for (let hop = 0; hop < MAX_REDIRECT_HOPS; hop++) {
      const response = await UpstreamClient.get(current, false);
      const direct: string = await LocalWebVpn.fromWebVpnUrl(current);
      if (response.isRedirect()) {
        // token 回调已建立网关 Cookie，后续只验证网关本身，不请求此前保存的业务地址
        if (hostOfUrl(direct) === GATEWAY_HOST && pathOfUrl(direct) === '/token-login') {
          current = GATEWAY_ROOT;
          continue;
        }
        const resolved: string = resolveLocation(response.url, response.location);
        const target: string = await LocalWebVpn.fromWebVpnUrl(resolved);
        const targetHost: string = hostOfUrl(target);
        if (targetHost !== SSO_HOST && targetHost !== GATEWAY_HOST) {
          // 已经跳到业务站点 → 网关放行了（票据被接受）
          Logger.info('WebVPN 网关已放行到业务站点：' + target);
          return;
        }
        // 网关自指回调必须保留**包装地址**参与票据交换；其余用解包后的逻辑地址
        current = targetHost === GATEWAY_HOST ? resolved : target;
        continue;
      }
      if (response.status === 200) {
        // 只要不是「仍要求统一认证的登录页」，就说明网关已经带着票据走完了流程。
        // ⚠️ 不能要求落地地址等于网关根：实测会直接落到被代理的业务页。
        if (CasParser.extractExecution(response.body).length > 0) {
          throw new ApiError(500, 'cas_page_failed', '网关仍要求统一认证');
        }
        Logger.info('WebVPN 网关会话已激活：' + direct);
        return;
      }
      throw new ApiError(500, 'cas_page_failed',
        'WebVPN 网关认证未完成（HTTP ' + response.status + '）');
    }
    throw new ApiError(500, 'cas_page_failed', 'WebVPN 网关认证跳转次数超过上限');
  }

  /**
   * 逐跳跟随重定向（实现见 `UpstreamClient.follow`）。
   *
   * 为什么不用 `maxRedirects` 自动跟随：`@ohos.net.http` 的自动重定向只认第一次
   * 请求上挂的 Cookie，中间跳转不会重新按目标域名组装 Cookie 头。而这条链恰好
   * 在 sso / uc 两个域之间来回跳，缺一跳 Cookie 就断。
   */
  private static async followTo(
    url: string,
    extraHeaders?: Record<string, string>
  ): Promise<UpstreamResponse> {
    return await UpstreamClient.follow(url, extraHeaders);
  }

  /**
   * 跟随登录提交后的跳转链，并在每一跳上判定成败。
   *
   * CAS 的失败信息散落在三个地方，缺一个就会把失败当成功：
   * 1. 跳转目标 URL 里的 `exception.message=`（凭据类的软失败）
   * 2. 页面里的 tip-text / errors 容器（文案面向用户，直接透出）
   * 3. 又回到了带 username+password 的登录表单（被退回）
   */
  private static async followAndCheck(initial: UpstreamResponse): Promise<void> {
    let current = initial;
    let passwordExpiryIgnored = false;
    let hops = 0;

    while (true) {
      while (current.isRedirect() && hops < MAX_REDIRECT_HOPS) {
        hops++;
        const resolved: string = resolveLocation(current.url, current.location);
        // ⚠️ **WebVPN 模式下必须「解包 → HSTS 升级 → 重包」**（对齐原版
        // `LocalConnectionAuth.followRedirectsAndCheckError`）：
        //   1. 网关返回的 Location 是**网关地址**（主机名加密的），
        //      直接当校内地址再包装一次 =双重包装 → 地址错乱 →
        //      凭据根本没提交到 SSO → 表现为「账号或密码验证未通过」（密码其实是对的）；
        //   2. SSO 开了 HSTS，浏览器会自动把 http 升成 https，
        //      **原生客户端没这层机制**，不升级就是明文请求，SSO 会拒。
        const unwrapped: string = await LocalWebVpn.fromWebVpnUrl(resolved);
        const secured: string = LocalWebVpn.secureCasTransportUrl(unwrapped);
        current = await UpstreamClient.get(secured, false);
      }

      const body = current.body;

      /**
       * webflow 执行上下文失效（`execution` 过期 / 被服务端回收）。
       *
       * 必须排在「凭据错误」之前判：这张错误页既不含登录表单，也不含 tip-text，
       * 落到后面的分支只会被泛化成「账号或密码验证未通过」，把用户引去改密码。
       */
      if (CasParser.isFlowExecutionExpired(body)) {
        throw new ApiError(400, CAS_FLOW_EXPIRED, 'CAS 登录流程上下文已失效（execution 已过期）');
      }

      // 「密码过期 / 账号风险」不是失败，是要求确认一次「继续」
      if (CasParser.isIgnorablePasswordExpiryPage(body)) {
        if (passwordExpiryIgnored) {
          throw new ApiError(400, 'cas_login_failed', '登录失败，请稍后重试');
        }
        const execution = CasParser.extractExecution(body);
        if (execution.length === 0) {
          throw new ApiError(400, 'cas_login_failed', '登录失败，请稍后重试');
        }
        passwordExpiryIgnored = true;
        current = await UpstreamClient.postForm(
          stripQuery(current.url),
          CasParser.buildIgnorePasswordExpiryBody(execution),
          false
        );
        continue;
      }

      const marker = 'exception.message=';
      const markerIndex = current.url.indexOf(marker);
      if (markerIndex >= 0) {
        throw new ApiError(401, 'cas_login_failed', LocalAuthService.decodeMessage(
          current.url.substring(markerIndex + marker.length)
        ));
      }

      const loginError = CasParser.findLoginError(body);
      if (current.status === 401 || loginError.length > 0) {
        throw new ApiError(401, 'cas_login_failed',
          loginError.length > 0 ? loginError : '账号或密码错误，请重试');
      }
      if (CasParser.hasLoginForm(body)) {
        throw new ApiError(401, 'cas_login_failed', '账号或密码错误，请重试');
      }
      return;
    }
  }

  /** 从查询串里取出到 `&` 为止的一段并解码成可读文案。 */
  private static decodeMessage(raw: string): string {
    let text = raw;
    const amp = text.indexOf('&');
    if (amp >= 0) {
      text = text.substring(0, amp);
    }
    try {
      text = decodeURIComponent(text.replace(/\+/g, ' '));
    } catch (error) {
      // 编码不合法时保留原文，总比抛异常好
    }
    return text.length > 0 ? text : '账号或密码错误，请重试';
  }
}
