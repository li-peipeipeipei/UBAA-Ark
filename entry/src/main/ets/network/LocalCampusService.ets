import { Logger } from '../common/Logger';
import { ApiError } from './ApiError';
import { UpstreamClient, UpstreamResponse, resolveLocation } from './UpstreamClient';
import { LocalWebVpn } from './LocalWebVpn';
import { TokenStore } from './TokenStore';
import { CampusAmount, NetworkProductUsage, NetworkUsage } from '../model/ApiTypes';

/**
 * 网费流量查询（自助服务 `zfw.buaa.edu.cn` 的只读流量表）。
 *
 * ## 上游从哪来
 *
 * 对齐上游 UBAA 2.0 的 `crates/ubaa_core/src/features/campus/`（`network.rs` + `parser.rs`）。
 * 上游是 Rust + Flutter，鸿蒙侧只是 Flutter 壳，代码不可复用，这里按协议契约重写。
 *
 * ## 链路
 *
 * 1. 逐跳走 `https://zfw.buaa.edu.cn/sso/cas/index`，直到落在 `/pay/card`
 *    （与评教/财务同一套逐跳做法：跨域自动跟随会把 Cookie 归错域）。
 * 2. GET `https://zfw.buaa.edu.cn/home`，Referer 用 `/pay/card`。
 * 3. 从返回 HTML 里解析流量表。
 *
 * ## 解析为什么手写而不用 DOM 库
 *
 * ArkTS 没有 HTML 解析库。上游用 `scraper`（CSS 选择器）并处理了嵌套表格，
 * 而真实页面（见上游 `fixtures/readonly/campus/network.html`）结构是：
 * 先一个干扰用的单列表格，再一个 `class="kv-grid-table table"` 的目标表；
 * 表头与单元格都带 `data-col-seq`，靠它对齐列而不是靠列序。
 * 这里照这个结构做**带校验的字符串解析**：任何一处对不上就报「页面结构异常」，
 */

const NETWORK_LOGIN: string = 'https://zfw.buaa.edu.cn/sso/cas/index';
const NETWORK_HOME: string = 'https://zfw.buaa.edu.cn/home';
const NETWORK_PAGE: string = 'https://zfw.buaa.edu.cn/pay/card';

/** CAS 激活最多跟几跳（上游写 10）。 */
const MAX_HOPS: number = 10;

/** 流量表的四个列名（与上游 `LABELS` 完全一致，顺序不重要，靠 data-col-seq 对齐）。 */
const LABEL_PRODUCT: string = '产品名称';
const LABEL_USED: string = '已用流量';
const LABEL_FREE: string = '免费流量剩余(不含套餐)';
const LABEL_BILLABLE: string = '计费流量剩余(不含套餐)';

/** `90.001G` / `0byte` / `512M`。 */
const TRAFFIC_PATTERN: RegExp = new RegExp('^([0-9]+(?:\\.[0-9]+)?)(byte|[KMGT])$');

/** 去标签、去所有空白、全角括号转半角 —— 与上游 `text()` 对齐。 */
function cellText(html: string): string {
  const noTags: string = html.replace(/<[^>]*>/g, '');
  const compact: string = noTags.replace(/\s+/g, '');
  return compact.replace(/（/g, '(').replace(/）/g, ')');
}

/** `data-col-seq="7"` 的取值正则（模块级常量，避免逐格 new RegExp）。 */
const COL_SEQ_PATTERN: RegExp = /data-col-seq\s*=\s*"([^"]*)"/;

/** 从属性串里取 `data-col-seq` 的值（表头与每个单元格都会调，高频路径）。 */
function colSeqOf(attrs: string): string {
  const found: RegExpMatchArray | null = attrs.match(COL_SEQ_PATTERN);
  return found === null || found.length < 2 ? '' : found[1];
}

/** 逻辑地址是否落在 host + path 上。 */
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

/** 流量串 → `CampusAmount`；格式不符返回 null（上层据此判定「页面结构异常」）。 */
function amountOf(raw: string): CampusAmount | null {
  const found: RegExpMatchArray | null = raw.match(TRAFFIC_PATTERN);
  if (found === null || found.length < 3) {
    return null;
  }
  return { value: found[1], unit: found[2] };
}

function invalid(): ApiError {
  return new ApiError(502, 'campus_error', '网费页面结构异常，请稍后重试');
}

export class LocalCampusService {
  private static activated: boolean = false;

  /** 退出登录时清状态。 */
  static reset(): void {
    LocalCampusService.activated = false;
  }

  /* ------------------------------ 对外 ------------------------------ */

  static async fetchNetworkUsage(): Promise<NetworkUsage> {
    await LocalCampusService.ensureActivated();
    const headers: Record<string, string> = {};
    headers['Referer'] = await LocalWebVpn.rewrite(NETWORK_PAGE, TokenStore.getConnectionMode());
    const response: UpstreamResponse = await UpstreamClient.get(NETWORK_HOME, false, headers);
    if (response.status === 401 || response.status === 403) {
      // 会话在激活后立刻又失效：清标记，让下次重新走一遍
      LocalCampusService.activated = false;
      throw new ApiError(401, 'invalid_token', '网费服务会话已失效，请重新登录后再试');
    }
    if (!response.isOk()) {
      // ⚠️ 任何非 2xx 都要清标记：会话过期时上游回的是 **302 跳登录页**（不是 401/403），
      // 只清 401/403 的话 `activated` 会一直留着 true，`ensureActivated` 此后永久短路，
      // 用户每次进网费页都报「HTTP 302」且再也不会重试 —— 只能杀进程。
      LocalCampusService.activated = false;
      throw new ApiError(response.status, 'campus_error',
        '网费页面加载失败（HTTP ' + response.status + '），请稍后重试');
    }
    const products: NetworkProductUsage[] = LocalCampusService.parseTraffic(response.body);
    Logger.info('网费流量解析完成：' + products.length + ' 个产品');
    return { products: products, fetchedAt: Date.now() };
  }

  /* ------------------------------ 解析 ------------------------------ */

  /**
   * 解析流量表。
   *
   * 步骤与上游 `traffic()` 一一对应：
   *   1. 逐个 `<table>` 找表头含「已用流量」的那张（干扰表要被跳过）；
   *   2. 表头的 `data-col-seq` 必须齐四个列名且互不重复，否则结构异常；
   *   3. `tbody > tr` 的每个 `td[data-col-seq]` 按 seq 归列；
   *   4. 产品名非空、流量值必须匹配 `数字+单位`，否则整体判结构异常。
   *
   * **任何一步对不上都抛错，绝不「跳过坏行继续显示」** —— 网费是账单类数据，
   * 显示一个猜出来的数比报错更糟。
   */
  private static parseTraffic(html: string): NetworkProductUsage[] {
    const tables: RegExpMatchArray | null = html.match(/<table[^>]*>[\s\S]*?<\/table>/g);
    if (tables === null) {
      throw invalid();
    }
    for (let t = 0; t < tables.length; t++) {
      const table: string = tables[t];
      const columns: Map<string, string> | null = LocalCampusService.headerColumns(table);
      if (columns === null) {
        continue;
      }
      const rows: string[] = LocalCampusService.rowBodies(table);
      const products: NetworkProductUsage[] = [];
      for (let r = 0; r < rows.length; r++) {
        const cells: Map<string, string> = LocalCampusService.rowCells(rows[r]);
        if (cells.size === 0) {
          continue;
        }
        const name: string = cells.get(columns.get(LABEL_PRODUCT) as string) ?? '';
        if (name.length === 0 || name.length > 512) {
          throw invalid();
        }
        const used: CampusAmount | null = amountOf(cells.get(columns.get(LABEL_USED) as string) ?? '');
        const free: CampusAmount | null = amountOf(cells.get(columns.get(LABEL_FREE) as string) ?? '');
        const billable: CampusAmount | null =
          amountOf(cells.get(columns.get(LABEL_BILLABLE) as string) ?? '');
        if (used === null || free === null || billable === null) {
          throw invalid();
        }
        products.push({
          productName: name,
          used: used,
          freeRemaining: free,
          billableRemaining: billable
        });
      }
      // 找到目标表就返回（同页可能还有套餐子表，上游也只在流量表上取行）
      return products;
    }
    throw invalid();
  }

  /** 读表头；不是目标表返回 null。 */
  private static headerColumns(table: string): Map<string, string> | null {
    const thead: RegExpMatchArray | null = table.match(/<thead[^>]*>([\s\S]*?)<\/thead>/);
    if (thead === null) {
      return null;
    }
    const ths: RegExpMatchArray | null = thead[1].match(/<th([^>]*)>([\s\S]*?)<\/th>/g);
    if (ths === null) {
      return null;
    }
    const columns: Map<string, string> = new Map<string, string>();
    const usedSeq: Set<string> = new Set<string>();
    let isTarget: boolean = false;
    for (let i = 0; i < ths.length; i++) {
      const raw: string = ths[i];
      const open: RegExpMatchArray | null = raw.match(/^<th([^>]*)>/);
      if (open === null) {
        continue;
      }
      const seq: string = colSeqOf(open[1]);
      const label: string = cellText(raw);
      if (label === LABEL_USED) {
        isTarget = true;
      }
      if (label !== LABEL_PRODUCT && label !== LABEL_USED &&
        label !== LABEL_FREE && label !== LABEL_BILLABLE) {
        continue;
      }
      if (seq.length === 0 || usedSeq.has(seq) || columns.has(label)) {
        return null;
      }
      usedSeq.add(seq);
      columns.set(label, seq);
    }
    if (!isTarget || columns.size !== 4) {
      return null;
    }
    return columns;
  }

  /** 取 `tbody` 里的每个 `<tr>` 片段。 */
  private static rowBodies(table: string): string[] {
    const tbody: RegExpMatchArray | null = table.match(/<tbody[^>]*>([\s\S]*?)<\/tbody>/);
    if (tbody === null) {
      return [];
    }
    const trs: RegExpMatchArray | null = tbody[1].match(/<tr[^>]*>[\s\S]*?<\/tr>/g);
    return trs === null ? [] : trs;
  }

  /** 一行里 `td[data-col-seq]` → seq 到文本的映射。 */
  private static rowCells(row: string): Map<string, string> {
    const cells: Map<string, string> = new Map<string, string>();
    const tds: RegExpMatchArray | null = row.match(/<td([^>]*)>([\s\S]*?)<\/td>/g);
    if (tds === null) {
      return cells;
    }
    for (let i = 0; i < tds.length; i++) {
      const raw: string = tds[i];
      const open: RegExpMatchArray | null = raw.match(/^<td([^>]*)>/);
      if (open === null) {
        continue;
      }
      const seq: string = colSeqOf(open[1]);
      if (seq.length === 0) {
        continue;
      }
      cells.set(seq, cellText(raw));
    }
    return cells;
  }

  /* ------------------------------ 认证 ------------------------------ */

  private static async ensureActivated(): Promise<void> {
    if (LocalCampusService.activated) {
      return;
    }
    let current: string = NETWORK_LOGIN;
    let currentLogical: string = NETWORK_LOGIN;
    for (let hop = 0; hop < MAX_HOPS; hop++) {
      const response: UpstreamResponse = await UpstreamClient.get(current, false);
      if (response.isRedirect()) {
        const next: string = resolveLocation(response.url, response.location);
        const nextLogical: string = await LocalWebVpn.fromWebVpnUrl(next);
        /**
         * ⚠️ **不能「下一跳出现 sso 就判失效」**。
         *
         * 统一认证**有**会话时的正常签发路径就是：
         * `zfw…/sso/cas/index` → 302 `sso.buaa.edu.cn/login?service=…` →
         * 302 回 `zfw…/callback?ticket=ST-…` → 302 `zfw…/pay/card`。
         * 中间那跳**必然**落在 sso 域名上，看到它就抛错等于「只要需要签发就报登录失效」——
         * 表现为登录后第一次打开网费必失败（财务页不受影响，因为它用的是双重判据）。
         *
         * 真正的判据：**当前页和下一跳都停在 sso**（回不到业务站）才算会话没了。
         * 与 `LocalFinanceService.walkPortal` 保持一致。
         */
        if (isSso(nextLogical) && isSso(currentLogical)) {
          throw new ApiError(401, 'invalid_token',
            '统一身份认证会话已失效，请重新登录后再试');
        }
        current = next;
        currentLogical = nextLogical;
        continue;
      }
      if (response.status === 401 || response.status === 403) {
        throw new ApiError(401, 'invalid_token', '网费服务会话未建立，请重新登录后再试');
      }
      if (response.isOk()) {
        const finalLogical: string = await LocalWebVpn.fromWebVpnUrl(response.url);
        if (isAt(finalLogical, 'zfw.buaa.edu.cn', '/pay/card')) {
          LocalCampusService.activated = true;
          return;
        }
        if (isSso(finalLogical)) {
          throw new ApiError(401, 'invalid_token',
            '统一身份认证会话已失效，请重新登录后再试');
        }
        throw new ApiError(401, 'invalid_token',
          '网费服务未就绪（终点异常：' + finalLogical + '），请重新登录后再试');
      }
      throw new ApiError(response.status, 'campus_error',
        '网费服务暂时不可用（HTTP ' + response.status + '），请稍后重试');
    }
    throw new ApiError(401, 'invalid_token', '网费服务登录跳转过多，请重新登录后再试');
  }
}
