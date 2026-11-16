import { Logger } from '../common/Logger';
import { ApiError } from './ApiError';
import { UpstreamClient, UpstreamResponse, resolveLocation } from './UpstreamClient';
import { LocalWebVpn } from './LocalWebVpn';
import { TokenStore } from './TokenStore';
import { FinanceIncome, FinanceIncomes } from '../model/ApiTypes';

/**
 * 财务收入查询（客户端直连财务查询系统）。
 *
 * ## 上游从哪来
 *
 * 逐条对齐上游 UBAA 2.0 的 `crates/ubaa_core/src/features/finance/`：
 * 认证走 `auth.rs`，分页与字段解析走 `finance/mod.rs` + `parser.rs`。
 * 上游是 Rust + Flutter 重写版，鸿蒙侧（`apps/ubaa_ohos`）只是 Flutter 壳，
 * 代码不可直接复用，因此这里按 **协议契约** 重写。
 *
 * ## 链路（三段，全部逐跳）
 *
 * 1. `sso.buaa.edu.cn/login?service=...icw.buaa.edu.cn/checkbuaa.aspx`
 *    → 逐跳跟随，直到落在 `icw.buaa.edu.cn/Newindex.aspx`（视为门户已认下）；
 *    若停在 sso 登录页 = 统一认证会话确实没了。
 * 2. `icw.buaa.edu.cn/jump.aspx?sysid=wscx` → 302 到
 *    `chaxun.icw.buaa.edu.cn/gxzhcxzhb/login?Userid=&Cypt=&Stamp=`。
 *    **用户名与「密码」都在这条 URL 的 query 里**（Cypt 是门户算好的口令），
 *    再把三个值作为表单提交给 `/api-zhcx/login` 换 token。
 * 3. 带 `Authorization: Bearer <token>` 调 `/api-zhcx/getStudentSRCX` 分页取数。
 *
 * ## 为什么必须逐跳
 *
 * 与评教同一个坑：跨域链路上「自动跟随重定向」拿不到中间跳的实际地址，
 * Cookie 归属会错位（详见 LocalEvaluationService.ensureActivated 的注释）。
 */

const SSO_ENTRY: string =
  'https://sso.buaa.edu.cn/login?service=http%3A%2F%2Ficw.buaa.edu.cn%2Fcheckbuaa.aspx';
const ICW_JUMP: string = 'https://icw.buaa.edu.cn/jump.aspx?sysid=wscx';
const CHAXUN_LOGIN: string = 'https://chaxun.icw.buaa.edu.cn/api-zhcx/login';
const CHAXUN_LIST: string = 'https://chaxun.icw.buaa.edu.cn/api-zhcx/getStudentSRCX';

/** 门户登录最多跟几跳（上游写 12，这里留同样余量防死循环）。 */
const MAX_PORTAL_HOPS: number = 12;
/** 每页条数（上游写死 100）。 */
const PAGE_SIZE: number = 100;
/** 分页上限，防上游 total 异常时无限翻页。 */
const MAX_PAGES: number = 50;

/** 换来的查询凭据（内存态，进程重启就重走一次三段链路）。 */
interface FinanceCredential {
  user: string;
  token: string;
}

/** 登录页 query 里解析出的三个值。 */
interface FinanceLoginParams {
  user: string;
  cypt: string;
  stamp: string;
  /** 登录页的实际地址，用作换 token 请求的 Referer。 */
  referer: string;
}

/** 分页请求体（ArkTS 里对象字面量不能直接赋给 Record，必须有具名类型）。 */
interface FinanceListRequest {
  userId: string;
  currentPage: number;
  limit: number;
}

/** 上游信封：`code` 为 200 时 `data` 是对象。 */
interface FinanceEnvelope {
  code?: number | string | null;
  data?: FinanceData | null;
  message?: string | null;
  msg?: string | null;
}

/** `data` 里可能是 `{mx:[], total:n}`，也可能是 `{data:[], count:n}`（上游两种都认）。 */
interface FinanceData {
  mx?: FinanceRawRow[];
  total?: number;
  data?: FinanceRawRow[];
  count?: number;
  token?: string;
}

/** 一条原始记录（字段可能缺失，也可能给成数字）。 */
interface FinanceRawRow {
  lsh?: string | number | null;
  ffxmmc?: string | null;
  zy?: string | null;
  je?: string | number | null;
  se?: string | number | null;
  sfje?: string | number | null;
  slbfb?: string | null;
  lrrq?: string | null;
  nian?: string | null;
  yue?: string | null;
}

/** 取字符串（数字也接受），空值折成空串。 */
function str(value: string | number | null | undefined): string {
  if (value === undefined || value === null) {
    return '';
  }
  if (typeof value === 'number') {
    return value.toString();
  }
  return value.trim();
}

/**
 * 金额「元」→「分」。
 *
 * 上游 `parser::cents` 的处理方式：接受整数或最多两位小数，负数保留符号；
 * 超过两位小数视为上游结构变化（宁可报错也不静默截断）。
 * 这里同样实现，解析失败返回 `undefined`（上层当作「没有该字段」）。
 */
function centsOf(value: string | number | null | undefined): number | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }
  const text: string = typeof value === 'number' ? value.toString() : value.trim();
  if (text.length === 0) {
    return undefined;
  }
  const negative: boolean = text.startsWith('-');
  const body: string = negative ? text.substring(1) : text;
  const dot: number = body.indexOf('.');
  const wholeText: string = dot < 0 ? body : body.substring(0, dot);
  const fractionText: string = dot < 0 ? '' : body.substring(dot + 1);
  if (wholeText.length === 0 || fractionText.length > 2) {
    return undefined;
  }
  if (!/^\d+$/.test(wholeText) || (fractionText.length > 0 && !/^\d+$/.test(fractionText))) {
    return undefined;
  }
  const whole: number = parseInt(wholeText, 10);
  if (isNaN(whole)) {
    return undefined;
  }
  let fraction: number = 0;
  if (fractionText.length === 1) {
    fraction = parseInt(fractionText, 10) * 10;
  } else if (fractionText.length === 2) {
    fraction = parseInt(fractionText, 10);
  }
  if (isNaN(fraction)) {
    return undefined;
  }
  const total: number = whole * 100 + fraction;
  return negative ? -total : total;
}

/**
 * 百分号解码；串里有非法转义时原样返回。
 *
 * 学校侧偶尔给出非法的 `%` 转义，`decodeURIComponent` 会抛 URIError ——
 * 那是裸 Error 不是 ApiError，上层只能显示英文原始错误，整条登录链也断在这里。
 */
function percentDecode(text: string): string {
  if (text.indexOf('%') < 0) {
    return text;
  }
  try {
    return decodeURIComponent(text);
  } catch (error) {
    return text;
  }
}

/** 从 URL 的 query 里取值（同名取唯一一个，与上游 `field()` 一致）。 */
function queryValue(url: string, name: string): string {
  const at: number = url.indexOf('?');
  if (at < 0) {
    return '';
  }
  const query: string = url.substring(at + 1);
  const parts: string[] = query.split('&');
  let found: string = '';
  let count: number = 0;
  for (let i = 0; i < parts.length; i++) {
    const part: string = parts[i];
    const eq: number = part.indexOf('=');
    const key: string = eq < 0 ? part : part.substring(0, eq);
    if (percentDecode(key) !== name) {
      continue;
    }
    const raw: string = eq < 0 ? '' : part.substring(eq + 1);
    found = percentDecode(raw.replace(/\+/g, ' '));
    count++;
  }
  return count === 1 ? found : '';
}

/** 逻辑地址是否落在某个 host + path 上。 */
function isAt(logicalUrl: string, host: string, path: string): boolean {
  const marker: string = '://' + host + path;
  const at: number = logicalUrl.indexOf(marker);
  if (at < 0) {
    return false;
  }
  const rest: string = logicalUrl.substring(at + marker.length);
  return rest.length === 0 || rest.startsWith('/') || rest.startsWith('?');
}

function isSso(logicalUrl: string): boolean {
  return logicalUrl.indexOf('sso.buaa.edu.cn') >= 0;
}

export class LocalFinanceService {
  private static credential: FinanceCredential | null = null;
  /** 并发保护：多个页面同时拉时只走一次登录链路。 */
  private static loginTask: Promise<FinanceCredential> | null = null;

  /* ------------------------------ 对外 ------------------------------ */

  /**
   * 全部收入记录（自动翻页取全）。
   *
   * 与上游一致：第一次遇到 `AuthenticationRequired` 会清凭据重试一次，
   * 避免「token 恰好过期」被当成需要用户重新登录。
   */
  static async fetchIncomes(): Promise<FinanceIncomes> {
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        return await LocalFinanceService.readAll();
      } catch (error) {
        const isAuth: boolean = error instanceof ApiError && (error as ApiError).status === 401;
        if (!isAuth) {
          throw error as Error;
        }
        LocalFinanceService.reset();
        if (attempt === 1) {
          throw error as Error;
        }
      }
    }
    throw new ApiError(401, 'invalid_token', '财务登录已失效，请重新登录后再试');
  }

  /** 退出登录时清掉内存凭据。 */
  static reset(): void {
    LocalFinanceService.credential = null;
    LocalFinanceService.loginTask = null;
  }

  /* ------------------------------ 取数 ------------------------------ */

  private static async readAll(): Promise<FinanceIncomes> {
    const credential: FinanceCredential = await LocalFinanceService.ensureCredential();
    const entries: FinanceIncome[] = [];
    const seen: Set<string> = new Set<string>();
    let expectedTotal: number = -1;
    for (let page = 1; page <= MAX_PAGES; page++) {
      const payload: FinanceListRequest = {
        userId: credential.user,
        currentPage: page,
        limit: PAGE_SIZE
      };
      const headers: Record<string, string> = {};
      headers['Authorization'] = 'Bearer ' + credential.token;
      const response: UpstreamResponse = await UpstreamClient.postJson(
        CHAXUN_LIST, JSON.stringify(payload), false, headers);
      if (response.status === 401) {
        throw new ApiError(401, 'invalid_token', '财务登录已失效，请重新登录后再试');
      }
      if (!response.isOk()) {
        throw new ApiError(response.status, 'finance_error',
          '财务数据加载失败（HTTP ' + response.status + '），请稍后重试');
      }
      const data: FinanceData = LocalFinanceService.unwrapData(response);
      const rows: FinanceRawRow[] = LocalFinanceService.rowsOf(data);
      const total: number = LocalFinanceService.totalOf(data, rows.length);
      if (expectedTotal >= 0 && expectedTotal !== total) {
        // total 在翻页途中变了：上游数据正在变，别拼一份自相矛盾的结果
        throw new ApiError(502, 'finance_error', '财务数据在拉取过程中发生变化，请重试');
      }
      expectedTotal = total;
      for (let i = 0; i < rows.length; i++) {
        const entry: FinanceIncome = LocalFinanceService.toIncome(rows[i]);
        if (seen.has(entry.id)) {
          continue;
        }
        seen.add(entry.id);
        entries.push(entry);
      }
      if (entries.length >= total || rows.length === 0) {
        return { entries: entries, total: entries.length };
      }
    }
    return { entries: entries, total: entries.length };
  }

  private static unwrapData(response: UpstreamResponse): FinanceData {
    let envelope: FinanceEnvelope;
    try {
      envelope = JSON.parse(response.body) as FinanceEnvelope;
    } catch (err) {
      throw new ApiError(502, 'finance_error', '财务接口返回的不是合法 JSON，请稍后重试');
    }
    const code: number = parseInt(str(envelope.code), 10);
    if (code === 401) {
      throw new ApiError(401, 'invalid_token', '财务登录已失效，请重新登录后再试');
    }
    if (code !== 200) {
      const message: string = str(envelope.message).length > 0 ? str(envelope.message) : str(envelope.msg);
      throw new ApiError(502, 'finance_error',
        '财务接口返回异常' + (message.length > 0 ? '：' + message : '，请稍后重试'));
    }
    const data: FinanceData | null | undefined = envelope.data;
    if (data === undefined || data === null) {
      throw new ApiError(502, 'finance_error', '财务接口未返回数据，请稍后重试');
    }
    return data;
  }

  private static rowsOf(data: FinanceData): FinanceRawRow[] {
    const mx: FinanceRawRow[] | undefined = data.mx;
    if (mx !== undefined && mx !== null) {
      return mx;
    }
    const list: FinanceRawRow[] | undefined = data.data;
    return list !== undefined && list !== null ? list : [];
  }

  private static totalOf(data: FinanceData, fallback: number): number {
    if (data.total !== undefined && data.total !== null) {
      return data.total;
    }
    if (data.count !== undefined && data.count !== null) {
      return data.count;
    }
    return fallback;
  }

  private static toIncome(row: FinanceRawRow): FinanceIncome {
    const entry: FinanceIncome = {
      id: str(row.lsh),
      project: str(row.ffxmmc),
      description: str(row.zy),
      amountCents: centsOf(row.je),
      taxCents: centsOf(row.se),
      paidCents: centsOf(row.sfje),
      taxRate: str(row.slbfb),
      recordedDate: str(row.lrrq),
      year: str(row.nian),
      month: str(row.yue)
    };
    if (entry.id.length === 0) {
      // 没有流水号无法去重，也不能当稳定 key —— 用日期+项目+金额合成一个
      entry.id = str(row.lrrq) + '|' + str(row.ffxmmc) + '|' + str(row.je);
    }
    return entry;
  }

  /* ------------------------------ 认证 ------------------------------ */

  private static ensureCredential(): Promise<FinanceCredential> {
    const cached: FinanceCredential | null = LocalFinanceService.credential;
    if (cached !== null) {
      return Promise.resolve(cached);
    }
    const running: Promise<FinanceCredential> | null = LocalFinanceService.loginTask;
    if (running !== null) {
      return running;
    }
    const task: Promise<FinanceCredential> = LocalFinanceService.login().then((credential) => {
      LocalFinanceService.credential = credential;
      LocalFinanceService.loginTask = null;
      return credential;
    }).catch((error: Error) => {
      LocalFinanceService.loginTask = null;
      throw error as Error;
    });
    LocalFinanceService.loginTask = task;
    return task;
  }

  private static async login(): Promise<FinanceCredential> {
    await LocalFinanceService.walkPortal();
    const params: FinanceLoginParams = await LocalFinanceService.openJump();
    return await LocalFinanceService.exchangeToken(params);
  }

  /**
   * 第一段：把门户（icw）会话走通。
   *
   * 终点判据与上游 `portal()` 一致：必须落在 `icw.buaa.edu.cn/Newindex.aspx`；
   * 停在 sso 说明统一认证会话已失效。
   */
  private static async walkPortal(): Promise<void> {
    let current: string = SSO_ENTRY;
    for (let hop = 0; hop < MAX_PORTAL_HOPS; hop++) {
      const response: UpstreamResponse = await UpstreamClient.get(current, false);
      const finalLogical: string = await LocalWebVpn.fromWebVpnUrl(response.url);
      if (response.isRedirect()) {
        const next: string = resolveLocation(response.url, response.location);
        const nextLogical: string = await LocalWebVpn.fromWebVpnUrl(next);
        if (isSso(nextLogical) && isSso(finalLogical)) {
          // 又回到 sso 登录页本身：会话确实没了
          throw new ApiError(401, 'invalid_token', '统一身份认证会话已失效，请重新登录后再试');
        }
        current = next;
        continue;
      }
      if (response.status === 401) {
        throw new ApiError(401, 'invalid_token', '财务门户需要重新登录');
      }
      if (response.isOk()) {
        if (isAt(finalLogical, 'icw.buaa.edu.cn', '/Newindex.aspx')) {
          return;
        }
        if (isSso(finalLogical)) {
          throw new ApiError(401, 'invalid_token', '统一身份认证会话已失效，请重新登录后再试');
        }
        // 200 但落在别处：多半是学校改版把登录页返成了 200
        throw new ApiError(401, 'invalid_token',
          '财务门户未就绪（终点异常：' + finalLogical + '），请重新登录后再试');
      }
      throw new ApiError(response.status, 'finance_error',
        '财务门户暂时不可用（HTTP ' + response.status + '），请稍后重试');
    }
    throw new ApiError(401, 'invalid_token', '财务门户登录跳转过多，请重新登录后再试');
  }

  /**
   * 第二段：`jump.aspx?sysid=wscx` 换出查询系统的登录地址。
   *
   * 上游要求这一步**必须**是 302，且 Location 必须指向
   * `chaxun.icw.buaa.edu.cn/gxzhcxzhb/login` 并带 `Userid` / `Cypt` / `Stamp`。
   */
  private static async openJump(): Promise<FinanceLoginParams> {
    const response: UpstreamResponse = await UpstreamClient.get(ICW_JUMP, false);
    if (response.status !== 302) {
      if (response.isOk()) {
        throw new ApiError(401, 'invalid_token',
          '财务跳转未生效（可能未登录），请重新登录后再试');
      }
      throw new ApiError(response.status, 'finance_error',
        '财务跳转失败（HTTP ' + response.status + '），请稍后重试');
    }
    const location: string = resolveLocation(response.url, response.location);
    const logical: string = await LocalWebVpn.fromWebVpnUrl(location);
    if (!isAt(logical, 'chaxun.icw.buaa.edu.cn', '/gxzhcxzhb/login')) {
      throw new ApiError(401, 'invalid_token',
        '财务跳转终点异常（' + logical + '），请重新登录后再试');
    }
    const user: string = queryValue(logical, 'Userid');
    const cypt: string = queryValue(logical, 'Cypt');
    const stamp: string = queryValue(logical, 'Stamp');
    if (user.length === 0 || cypt.length === 0 || stamp.length === 0) {
      throw new ApiError(401, 'invalid_token',
        '财务跳转缺少凭据参数，请重新登录后再试');
    }
    // Referer 用**跳转给出的实际地址**（WebVPN 模式下就是网关地址），与浏览器行为一致
    return { user: user, cypt: cypt, stamp: stamp, referer: location };
  }

  /**
   * 第三段：用跳转带来的三件套换 token。
   *
   * 表单字段与上游一致：`username` / `password` / `yzm` / `stamp`，
   * 其中 `yzm` 固定传字面量 `yzm`（上游注释即如此，不是漏传验证码）。
   */
  private static async exchangeToken(params: FinanceLoginParams): Promise<FinanceCredential> {
    const form: string = 'username=' + encodeURIComponent(params.user) +
      '&password=' + encodeURIComponent(params.cypt) +
      '&yzm=yzm' +
      '&stamp=' + encodeURIComponent(params.stamp);
    const headers: Record<string, string> = {};
    headers['Referer'] = params.referer;
    const response: UpstreamResponse = await UpstreamClient.postForm(
      CHAXUN_LOGIN, form, false, headers);
    if (response.status === 401) {
      throw new ApiError(401, 'invalid_token', '财务登录被拒绝，请重新登录后再试');
    }
    if (!response.isOk()) {
      throw new ApiError(response.status, 'finance_error',
        '财务登录失败（HTTP ' + response.status + '），请稍后重试');
    }
    let envelope: FinanceEnvelope;
    try {
      envelope = JSON.parse(response.body) as FinanceEnvelope;
    } catch (err) {
      throw new ApiError(502, 'finance_error', '财务登录返回的不是合法 JSON，请稍后重试');
    }
    const code: number = parseInt(str(envelope.code), 10);
    if (code !== 200) {
      throw new ApiError(502, 'finance_error', '财务登录失败（上游返回 ' + str(envelope.code) + '）');
    }
    const data: FinanceData | null | undefined = envelope.data;
    const token: string = data === undefined || data === null ? '' : str(data.token);
    if (token.length === 0) {
      throw new ApiError(502, 'finance_error', '财务登录未返回凭据，请稍后重试');
    }
    Logger.info('财务会话就绪（user=' + params.user + '）');
    return { user: params.user, token: token };
  }
}
