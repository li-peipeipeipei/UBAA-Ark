import { Logger } from '../common/Logger';
import { ApiError } from './ApiError';
import { LocalWebVpn } from './LocalWebVpn';
import {
  CampusAmount, PortalMetric, PortalMetrics, PortalProfile
} from '../model/ApiTypes';
import { resolveLocation, UpstreamClient, UpstreamResponse } from './UpstreamClient';

/**
 * 门户账户指标（上游 `features/campus/portal.rs`）。
 *
 * 一次拿身份资料 + 五项指标：网费余额、一卡通余额、未读邮件数、借阅图书数、云盘剩余空间。
 * 「我的」页顶部那一排指标用的就是它。
 *
 * ## 协议（逐字对齐上游 `portal.rs` + `parser.rs` + `campus/mod.rs`）
 *
 * | 用途 | 地址 | 判据 |
 * |---|---|---|
 * | 身份资料 | `GET /personal/frontend/data/info` | `e===0` → `d.info.{identity,depart}` |
 * | 指标列表 | `GET /personal/frontend/data/items?type=personal_data` | `e===0` → `d[]: {key, id}` |
 * | 指标明细 | `GET /personal/frontend/data/detail?id=<id>` | `e===0` → `d.{value, unit}` 或 `{value}` |
 * | 一卡通余额 | `GET /buaa/frontend/card/balance` | 优先走它，失败回退 `detail` |
 *
 * - `e===0` 成功；`e===10013` **需业务登录**（激活后重试一次）；其它 = 服务不可用。
 * - 请求必须带 `X-Requested-With: XMLHttpRequest` 与 `Referer: <portal home>`（上游 `get(api=true)`）。
 *
 * ## 判据与其它服务一致
 *
 * `Service::Portal` 与 `Service::Network` 是**同一 CAS 域下两个不同的业务登录入口**，
 * 会话不能互相复用（所以 `activated` 各记各的）。失效判据沿用
 * `LocalCampusService` / `LocalFinanceService.walkPortal` 的**双重判定**：
 * 只有当前页与下一跳都停在 sso（回不到业务站）才算统一认证会话失效。
 */

const PORTAL_BASE: string = 'https://it.buaa.edu.cn';
/** 业务站首页，同时是激活的**终点判据**。 */
const PORTAL_HOME: string = PORTAL_BASE + '/home/';
/** 业务登录入口（上游 `activate(Service::Portal)` 的起点）。 */
const PORTAL_LOGIN: string =
  PORTAL_BASE + '/manage/common/login/index?redirect=' + encodeURIComponent(PORTAL_HOME);
const INFO_URL: string = PORTAL_BASE + '/personal/frontend/data/info';
const ITEMS_URL: string = PORTAL_BASE + '/personal/frontend/data/items?type=personal_data';
const DETAIL_URL: string = PORTAL_BASE + '/personal/frontend/data/detail?id=';
const CARD_BALANCE_URL: string = PORTAL_BASE + '/buaa/frontend/card/balance';

/** CAS 激活最多跟几跳（上游写 10）。 */
const MAX_HOPS: number = 10;

/** 上游 `parser::DECIMAL`：`0`、`12`、`12.5`，不允许前导零与负号。 */
const DECIMAL: RegExp = /^(?:0|[1-9][0-9]*)(?:\.[0-9]+)?$/;

/** 上游 KEYS：五项指标在 items 列表里的 key。 */
const KEY_NET: string = 'net.netFee';
const KEY_CARD: string = 'card.balance';
const KEY_MAIL: string = 'mail.unread';
const KEY_BOOK: string = 'book.bookNum';
const KEY_PAN: string = 'wangPan.wangPan';

function invalid(): ApiError {
  return new ApiError(502, 'portal_error',
    '校园账户响应不符合已验证的格式（可能学校改版了），请稍后重试');
}

function isSso(logicalUrl: string): boolean {
  return logicalUrl.indexOf('sso.buaa.edu.cn') >= 0;
}

/* ------------------------- JSON 字段取值（与 LocalLibBookService 同一套） ------------------------- */

function objOf(source: Object, key: string): Object | null {
  const value = (source as Record<string, Object>)[key];
  return (value !== null && value !== undefined && typeof value === 'object')
    ? (value as Object) : null;
}

function arrOf(source: Object, key: string): Object[] {
  const value = (source as Record<string, Object>)[key];
  return Array.isArray(value) ? (value as Object[]) : [];
}

function strOf(source: Object, key: string): string {
  const value = (source as Record<string, Object>)[key];
  return typeof value === 'string' ? (value as string) : '';
}

function numOf(source: Object, key: string): number {
  const value = (source as Record<string, Object>)[key];
  if (typeof value === 'number') {
    return value as number;
  }
  return 0;
}

/**
 * 取出 `e` 字段并判定（上游 `parser::envelope`）。
 *
 * - `e===0` → 返回 `d`
 * - `e===10013` → **业务登录需重试**
 * - 其它 → 服务不可用
 */
function envelope(payload: Object): Object {
  const code: number = numOf(payload, 'e');
  if (code === 0) {
    const data = objOf(payload, 'd');
    if (data === null) {
      throw invalid();
    }
    return data;
  }
  if (code === 10013) {
    throw new ApiError(401, 'portal_business_login', '校园账户需要业务登录，请稍后重试');
  }
  throw new ApiError(503, 'portal_error', '校园账户服务暂时不可用');
}

/** 上游 `parser::nonblank`：非空、≤512、无控制字符。 */
function nonblank(value: string): string {
  const text = value.trim();
  if (text.length === 0 || text.length > 512) {
    throw invalid();
  }
  for (let i = 0; i < text.length; i++) {
    if (text.charCodeAt(i) < 0x20) {
      throw invalid();
    }
  }
  return text;
}

/** 上游 `parser::decimal`：数字或数字串，≤64 字符。 */
function decimal(value: string): string {
  const text = value.trim();
  if (text.length === 0 || text.length > 64 || !DECIMAL.test(text)) {
    throw invalid();
  }
  return text;
}

/** 上游 `parser::amount`：`{value, unit}`（金额与容量共用，云盘剩余空间也是它）。 */
function amountOf(data: Object): CampusAmount {
  const rawValue: string = strOf(data, 'value');
  const valueText: string = rawValue.length > 0 ? rawValue : numOf(data, 'value').toString();
  const unit: string = strOf(data, 'unit');
  return {
    value: decimal(valueText),
    unit: nonblank(unit)
  } as CampusAmount;
}

/** 上游 `parser::count`：整数，不允许小数点。 */
function countOf(data: Object): string {
  const rawValue: string = strOf(data, 'value');
  const valueText: string = rawValue.length > 0 ? rawValue : numOf(data, 'value').toString();
  const value = decimal(valueText);
  if (value.indexOf('.') >= 0) {
    throw invalid();
  }
  return value;
}

function metricOk(label: string, value: string, unit: string): PortalMetric {
  return { label: label, value: value, unit: unit, ok: true } as PortalMetric;
}

function metricFail(label: string, message: string): PortalMetric {
  return { label: label, value: message, unit: '', ok: false } as PortalMetric;
}

export class LocalPortalService {
  /** 本次进程是否已打通 it.buaa.edu.cn 的业务登录。 */
  private static activated: boolean = false;
  /** 正在进行的激活（并发共享同一次，避免各跑一遍 CAS 跳转链）。 */
  private static activateTask: Promise<void> | null = null;

  /* ------------------------------ 对外 ------------------------------ */

  /** 身份资料（身份 + 院系）。 */
  static async fetchProfile(): Promise<PortalProfile> {
    const data = envelope(await LocalPortalService.json(INFO_URL));
    const info = objOf(data, 'info');
    if (info === null) {
      throw invalid();
    }
    return {
      identity: nonblank(strOf(info, 'identity')),
      department: nonblank(strOf(info, 'depart')),
      fetchedAt: Date.now()
    } as PortalProfile;
  }

  /**
   * 五项指标。**单项失败不影响其它项**（上游 `record()` 就是这么做的）——
   * 一项挂了其余四项照常显示，界面不用为一个字段整卡报错。
   */
  static async fetchMetrics(): Promise<PortalMetrics> {
    const data = envelope(await LocalPortalService.json(ITEMS_URL));
    const list = arrOf(data, 'data');
    const ids: Map<string, string> = new Map<string, string>();
    for (let i = 0; i < list.length; i++) {
      const row = list[i];
      const key = strOf(row, 'key');
      const id = strOf(row, 'id');
      if (key.length > 0 && id.trim().length > 0 && !ids.has(key)) {
        ids.set(key, id.trim());
      }
    }

    const metrics = {
      netFee: null,
      cardBalance: null,
      unreadMail: null,
      borrowedBooks: null,
      wangpan: null,
      fetchedAt: Date.now()
    } as PortalMetrics;

    metrics.netFee = await LocalPortalService.metricAmount(ids, KEY_NET, '网费余额');
    metrics.cardBalance = await LocalPortalService.cardBalance(ids);
    metrics.unreadMail = await LocalPortalService.metricCount(ids, KEY_MAIL, '未读邮件');
    metrics.borrowedBooks = await LocalPortalService.metricCount(ids, KEY_BOOK, '待还图书');
    metrics.wangpan = await LocalPortalService.metricAmount(ids, KEY_PAN, '云盘剩余');
    return metrics;
  }

  /** 登出时清空（与其它 Local*Service 的 reset 语义一致）。 */
  static reset(): void {
    LocalPortalService.activated = false;
    LocalPortalService.activateTask = null;
  }

  /* ------------------------------ 指标取数 ------------------------------ */

  private static async metricAmount(ids: Map<string, string>, key: string,
    label: string): Promise<PortalMetric | null> {
    const id = ids.get(key);
    if (id === undefined) {
      return null;
    }
    try {
      const data = envelope(await LocalPortalService.json(DETAIL_URL + encodeURIComponent(id)));
      const amount = amountOf(data);
      return metricOk(label, amount.value, amount.unit);
    } catch (error) {
      return metricFail(label, (error as Error).message);
    }
  }

  private static async metricCount(ids: Map<string, string>, key: string,
    label: string): Promise<PortalMetric | null> {
    const id = ids.get(key);
    if (id === undefined) {
      return null;
    }
    try {
      const data = envelope(await LocalPortalService.json(DETAIL_URL + encodeURIComponent(id)));
      return metricOk(label, countOf(data), '');
    } catch (error) {
      return metricFail(label, (error as Error).message);
    }
  }

  /**
   * 一卡通余额：优先走 `/buaa/frontend/card/balance`，失败回退到 `card.balance` 的 detail。
   *
   * 上游 `card()` 的语义：独立接口走不通（网络/上游/解析/认证类错误）才回退，
   * 会话冲突与「需要重新登录」不回退 —— 那种情况该重登而不是换条路。
   */
  private static async cardBalance(ids: Map<string, string>): Promise<PortalMetric | null> {
    const id = ids.get(KEY_CARD);
    try {
      const data = envelope(await LocalPortalService.json(CARD_BALANCE_URL));
      const amount = amountOf(data);
      return metricOk('一卡通余额', amount.value, amount.unit);
    } catch (primary) {
      const message: string = (primary as Error).message;
      // 会话类错误不回退，让上层知道该重新登录
      if (primary instanceof ApiError && primary.status === 401) {
        return metricFail('一卡通余额', message);
      }
      if (id === undefined) {
        return metricFail('一卡通余额', message);
      }
      try {
        const data = envelope(await LocalPortalService.json(DETAIL_URL + encodeURIComponent(id)));
        const amount = amountOf(data);
        return metricOk('一卡通余额', amount.value, amount.unit);
      } catch (fallback) {
        return metricFail('一卡通余额', (fallback as Error).message);
      }
    }
  }

  /* ------------------------------ 请求层 ------------------------------ */

  // 打一个 JSON 接口。
  // 请求头按上游 get(api=true)：Accept 取 JSON 类、X-Requested-With: XMLHttpRequest、
  // Referer 为 portal home。缺 X-Requested-With 时有些网关会把 JSON 请求当浏览器导航返回 HTML。
  private static async json(url: string): Promise<Object> {
    await LocalPortalService.ensurePortal();
    const headers: Record<string, string> = {};
    headers['accept'] = 'application/json, text/plain, */*';
    headers['x-requested-with'] = 'XMLHttpRequest';
    headers['referer'] = PORTAL_HOME;
    const response: UpstreamResponse = await UpstreamClient.get(url, true, headers);
    if (response.status === 401 || response.status === 403) {
      // 业务登录过期：清标记，下次重新激活
      LocalPortalService.activated = false;
      throw new ApiError(401, 'portal_business_login', '校园账户需要业务登录，请稍后重试');
    }
    if (!response.isOk()) {
      throw new ApiError(response.status, 'portal_error',
        '校园账户服务暂时不可用（HTTP ' + response.status + '）');
    }
    const trimmed: string = response.body.trimStart();
    if (trimmed.length === 0 || trimmed.charAt(0) !== '{') {
      // 被重定向到登录页时拿到的是 HTML —— 判成业务登录未就绪，别让 JSON 解析抛裸错
      LocalPortalService.activated = false;
      throw new ApiError(401, 'portal_business_login', '校园账户需要业务登录，请稍后重试');
    }
    try {
      return JSON.parse(response.body) as Object;
    } catch (error) {
      throw invalid();
    }
  }

  /* ------------------------------ 认证 ------------------------------ */

  private static async ensurePortal(): Promise<void> {
    if (LocalPortalService.activated) {
      return;
    }
    if (LocalPortalService.activateTask !== null) {
      return LocalPortalService.activateTask;
    }
    const task: Promise<void> = LocalPortalService.doActivate();
    LocalPortalService.activateTask = task;
    try {
      await task;
    } finally {
      LocalPortalService.activateTask = null;
    }
  }

  private static async doActivate(): Promise<void> {
    let current: string = PORTAL_LOGIN;
    let currentLogical: string = PORTAL_LOGIN;
    for (let hop = 0; hop < MAX_HOPS; hop++) {
      const response: UpstreamResponse = await UpstreamClient.get(current, false);
      if (response.isRedirect()) {
        const next: string = resolveLocation(response.url, response.location);
        const nextLogical: string = await LocalWebVpn.fromWebVpnUrl(next);
        // 与网费/财务一致的双重判据：当前页与下一跳都在 sso 才算失效。
        // 只看下一跳会把 CAS 的正常签发中转（sso/login?service=）误判成会话没了。
        if (isSso(nextLogical) && isSso(currentLogical)) {
          throw new ApiError(401, 'invalid_token',
            '统一身份认证会话已失效，请重新登录后再试');
        }
        current = next;
        currentLogical = nextLogical;
        continue;
      }
      if (response.status === 401 || response.status === 403) {
        throw new ApiError(401, 'invalid_token',
          '校园账户服务会话未建立，请重新登录后再试');
      }
      if (response.isOk()) {
        const finalLogical: string = await LocalWebVpn.fromWebVpnUrl(response.url);
        // 终点必须落在门户首页（上游 `activate(Service::Portal)` 的判据）
        if (finalLogical.indexOf(PORTAL_HOME) === 0 || finalLogical === PORTAL_HOME) {
          LocalPortalService.activated = true;
          Logger.info('门户账户会话就绪（' + hop + ' 跳，终点 ' + finalLogical + '）');
          return;
        }
        if (isSso(finalLogical)) {
          throw new ApiError(401, 'invalid_token',
            '统一身份认证会话已失效，请重新登录后再试');
        }
        throw new ApiError(401, 'invalid_token',
          '校园账户服务未就绪（终点异常：' + finalLogical + '），请重新登录后再试');
      }
      throw new ApiError(response.status, 'portal_error',
        '校园账户服务暂时不可用（HTTP ' + response.status + '）');
    }
    throw new ApiError(401, 'invalid_token',
      '校园账户服务登录跳转过多，请重新登录后再试');
  }
}
