import { Logger } from '../common/Logger';
import { ApiError } from './ApiError';
import { LocalWebVpn } from './LocalWebVpn';
import { resolveLocation, UpstreamClient, UpstreamResponse } from './UpstreamClient';
import { TokenStore } from './TokenStore';

/**
 * 图书馆云打印（上游 `features/cloud_print/`）—— **只读**部分。
 *
 * 本轮只做**文档列表 + 打印站状态**（上游 `read.rs` 的 `documents` / `stations`）。
 * PDF 生成、分片上传（`pdf.rs` / `upload.rs`）与预览、下载、删除都**不做** ——
 * 那些需要文件选择器、大文件分片与写操作，风险与工作量都高一档。
 *
 * ## 协议（对齐上游 `cloud_print/mod.rs` + `read.rs`）
 *
 * | 用途 | 地址 | 判据 |
 * |---|---|---|
 * | 会话检查 | `POST /api/client/Auth/Check`（`Content-Length: 0`） | `code===0` 且 `result.szLogonName` 非空 |
 * | 文档列表 | `GET /api/client/PrintJob/Get`（打印）/ `Scan/Get`（扫描） | `code===0` → `result: [...]` |
 * | 打印站 | `GET /api/client/Station/GetSrvList` + `Station/GetList` | 同上 |
 *
 * - `code===0` 成功；`code===4` **需认证**；其它 = 服务器拒绝。
 * - API 基址 `https://print.lib.buaa.edu.cn/api/client/<path>`；
 *   页面 `https://print.lib.buaa.edu.cn/client/new/cprintPc/cprint.html`。
 * - `PrintJob/Get` 要带一个随机 `timestamp` 查询参（上游 `timestamped()`）。
 *
 * ## 认证（上游 `auth.rs`）
 *
 * 链路：`Auth/SSoPage?backurl=<PAGE>` → 拿到起始 URL → 逐跳跟到 CAS → 回 `Auth/SSOLogin`
 * → `Auth/UniEntry` → 落回 PAGE。上游对每一跳的 origin/path/query 都做了严格校验。
 *
 * ⚠️ 这里**放宽了逐跳校验**（只判终点落在 PAGE、跳数不超限）：上游那套严格校验
 * 需要真实抓包保证字段稳定，我们没有 fixture。放宽后若学校改版，行为是「走不通并
 * 报错」而不是「误判通过」，方向是安全的。
 */

const HOST: string = 'print.lib.buaa.edu.cn';
const PAGE: string = 'https://print.lib.buaa.edu.cn/client/new/cprintPc/cprint.html';
const API_BASE: string = 'https://print.lib.buaa.edu.cn/api/client/';

/** 认证跳转最多跟几跳（上游写 8）。 */
const MAX_HOPS: number = 8;

/* ------------------------------ 数据结构 ------------------------------ */

/** 一份打印/扫描文档。 */
export interface PrintDocument {
  id: string;
  name: string;
  /** 提交日期（形如 `20261117`）。 */
  date: string;
  /** 提交时间（形如 `143005`）。 */
  time: string;
  /** 文件大小（字节，扫描文档才有）。 */
  bytes: string;
  /** 页数（打印文档才有，`bw + color`）。 */
  pages: string;
  /** 份数（打印文档才有）。 */
  copies: string;
  /** 是否已过期（扫描文档用 `dwStatus & 256`）。 */
  expired: boolean;
  /** 是否扫描件（决定用哪套字段）。 */
  scan: boolean;
}

/** 一台打印站。 */
export interface PrintStation {
  name: string;
  /** 所属分组（可能为空）。 */
  group: string;
  /** 空闲 / 忙碌 / 不可用 / 未开放。 */
  state: string;
  /** 纸盒里有什么纸（A4 / A3）。 */
  papers: string[];
  /** 能力（打印 / 复印 / 扫描 / 彩色）。 */
  capabilities: string[];
}

function invalid(): ApiError {
  return new ApiError(502, 'cloudprint_error',
    '云打印返回了无法识别的结果（可能学校改版了），请稍后重试');
}

function authRequired(): ApiError {
  return new ApiError(401, 'cloudprint_auth',
    '云打印需要有效的学校登录，请重新登录后再试');
}

/* ------------------------------ JSON 取值 ------------------------------ */

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
  return typeof value === 'number' ? (value as number) : 0;
}

/**
 * 上游 `field()`：数字或数字串，统一转成字符串。
 *
 * 数字字段（`dwJobId` 之类）在 JSON 里可能是 number 也可能是 string，
 * 上游 `field()` 两种都收。这里同样兼容。
 */
function idLike(source: Object, key: string): string {
  const value = (source as Record<string, Object>)[key];
  if (typeof value === 'string') {
    return (value as string).length > 0 ? (value as string) : '';
  }
  if (typeof value === 'number') {
    return (value as number).toString();
  }
  return '';
}

/** 上游 `envelope`：判 `code`。0 成功、4 需认证、其它拒绝。 */
function envelope(payload: Object): Object {
  const code: number = numOf(payload, 'code');
  if (code === 0) {
    return payload;
  }
  if (code === 4) {
    throw authRequired();
  }
  throw new ApiError(403, 'cloudprint_rejected', '云打印服务器拒绝了该操作');
}

export class LocalCloudPrintService {
  /** 本次进程是否已打通云打印会话。 */
  private static activated: boolean = false;
  /** 正在进行的激活（并发共享同一次）。 */
  private static activateTask: Promise<void> | null = null;

  /* ------------------------------ 对外 ------------------------------ */

  /**
   * 文档列表（打印 + 扫描，合并返回）。
   *
   * 两个接口都打一次，扫描件标 `scan: true`（字段语义不同）。
   */
  static async fetchDocuments(): Promise<PrintDocument[]> {
    const out: PrintDocument[] = [];
    const jobs = arrOf(envelope(await LocalCloudPrintService.json('PrintJob/Get')), 'result');
    for (let i = 0; i < jobs.length; i++) {
      out.push(LocalCloudPrintService.jobDocument(jobs[i], false));
    }
    const scans = arrOf(envelope(await LocalCloudPrintService.json('Scan/Get')), 'result');
    for (let i = 0; i < scans.length; i++) {
      out.push(LocalCloudPrintService.jobDocument(scans[i], true));
    }
    return out;
  }

  /** 打印站状态（设备列表 + 分组）。 */
  static async fetchStations(): Promise<PrintStation[]> {
    const groupsPayload = envelope(await LocalCloudPrintService.json('Station/GetSrvList'));
    const devicesPayload = envelope(await LocalCloudPrintService.json('Station/GetList'));
    const groups = arrOf(groupsPayload, 'result');
    const devices = arrOf(devicesPayload, 'result');
    const out: PrintStation[] = [];
    for (let i = 0; i < devices.length; i++) {
      out.push(LocalCloudPrintService.stationOf(devices[i], groups));
    }
    return out;
  }

  /** 登出时清空。 */
  static reset(): void {
    LocalCloudPrintService.activated = false;
    LocalCloudPrintService.activateTask = null;
  }

  /* ------------------------------ 解析 ------------------------------ */

  private static jobDocument(row: Object, scan: boolean): PrintDocument {
    const id = idLike(row, 'dwJobId');
    const name = scan ? strOf(row, 'szDisplayName') : strOf(row, 'szJobName');
    const date = scan ? idLike(row, 'dwSubmitDate') : idLike(row, 'dwCreateDate');
    const time = scan ? idLike(row, 'dwSubmitTime') : idLike(row, 'dwCreateTime');
    let pages: string = '';
    let copies: string = '';
    let bytes: string = '';
    let expired: boolean = false;
    if (scan) {
      bytes = idLike(row, 'dwFileSize');
      expired = (numOf(row, 'dwStatus') & 256) !== 0;
    } else {
      copies = idLike(row, 'dwCopies');
      // `szPaperDetail` 是 JSON 字符串：[{dwBWPages, dwColorPages}]
      const detailText = strOf(row, 'szPaperDetail');
      if (detailText.length > 0) {
        try {
          const detail = JSON.parse(detailText) as Object[];
          if (Array.isArray(detail) && detail.length > 0) {
            const paper = detail[0];
            const bw = numOf(paper, 'dwBWPages');
            const color = numOf(paper, 'dwColorPages');
            pages = (bw + color).toString();
          }
        } catch (error) {
          // 解析不出页数就留空，不影响列表
        }
      }
    }
    return {
      id: id,
      name: name,
      date: date,
      time: time,
      bytes: bytes,
      pages: pages,
      copies: copies,
      expired: expired,
      scan: scan
    } as PrintDocument;
  }

  private static stationOf(row: Object, groups: Object[]): PrintStation {
    const devSn: number = numOf(row, 'dwDevSN');
    const groupId: number = Math.floor(devSn / 1000);
    let group: string = '';
    for (let i = 0; i < groups.length; i++) {
      if (numOf(groups[i], 'dwSN') === groupId) {
        group = strOf(groups[i], 'szName');
        break;
      }
    }
    const status: number = numOf(row, 'dwStatus');
    // 上游：20/200/400/800/1000/2000/10000 任一位置 1 即「不可用」
    const UNAVAILABLE: number = 0x0014 | 0x00c8 | 0x0190 | 0x0320 | 0x03e8 | 0x07d0 | 0x2710;
    let state: string = '不可用';
    if ((status & UNAVAILABLE) === 0) {
      if ((status & 2) !== 0) {
        state = '忙碌';
      } else if ((status & 1) !== 0) {
        state = '空闲';
      } else if (status === 0) {
        state = '未开放';
      }
    }
    const papers: string[] = [];
    const trayKeys: string[] = ['dwTrayPaper1', 'dwTrayPaper2', 'dwTrayPaper3', 'dwTrayPaper4'];
    for (let i = 0; i < trayKeys.length; i++) {
      const code: number = numOf(row, trayKeys[i]);
      const paper: string = code === 9 ? 'A4' : (code === 8 ? 'A3' : '');
      if (paper.length > 0 && papers.indexOf(paper) < 0) {
        papers.push(paper);
      }
    }
    const property: number = numOf(row, 'dwProperty');
    const capabilities: string[] = [];
    const CAPS: string[][] = [['1', '打印'], ['2', '复印'], ['4', '扫描'], ['8', '彩色']];
    for (let i = 0; i < CAPS.length; i++) {
      const flag: number = parseInt(CAPS[i][0], 10);
      if ((property & flag) !== 0) {
        capabilities.push(CAPS[i][1]);
      }
    }
    return {
      name: strOf(row, 'szName'),
      group: group,
      state: state,
      papers: papers,
      capabilities: capabilities
    } as PrintStation;
  }

  /* ------------------------------ 请求层 ------------------------------ */

  private static endpoint(path: string): string {
    return API_BASE + path;
  }

  /** 上游 `timestamped()`：给列表接口加一个随机 `timestamp` 查询参（防缓存）。 */
  private static timestamped(path: string): string {
    return LocalCloudPrintService.endpoint(path) +
      '?timestamp=' + Math.random().toString();
  }

  private static async json(path: string): Promise<Object> {
    await LocalCloudPrintService.ensureSession();
    const headers: Record<string, string> = {};
    headers['accept'] = 'application/json, text/plain, */*';
    const url: string = (path.indexOf('PrintJob/Get') >= 0 || path.indexOf('Scan/Get') >= 0) ?
      LocalCloudPrintService.timestamped(path) : LocalCloudPrintService.endpoint(path);
    const response: UpstreamResponse = await UpstreamClient.get(url, true, headers);
    if (response.status === 401) {
      LocalCloudPrintService.activated = false;
      throw authRequired();
    }
    if (!response.isOk()) {
      throw new ApiError(response.status, 'cloudprint_error',
        '云打印服务暂时不可用（HTTP ' + response.status + '）');
    }
    const trimmed: string = response.body.trimStart();
    if (trimmed.length === 0 || trimmed.charAt(0) !== '{') {
      // 被重定向到登录页时拿到 HTML
      LocalCloudPrintService.activated = false;
      throw authRequired();
    }
    try {
      return JSON.parse(response.body) as Object;
    } catch (error) {
      throw invalid();
    }
  }

  /* ------------------------------ 认证 ------------------------------ */

  private static async ensureSession(): Promise<void> {
    if (LocalCloudPrintService.activated) {
      return;
    }
    if (LocalCloudPrintService.activateTask !== null) {
      return LocalCloudPrintService.activateTask;
    }
    const task: Promise<void> = LocalCloudPrintService.doLogin();
    LocalCloudPrintService.activateTask = task;
    try {
      await task;
    } finally {
      LocalCloudPrintService.activateTask = null;
    }
  }

  /**
   * 走一遍云打印登录链。
   *
   * 简化版：不逐跳校验 origin/path（上游那套需要真实抓包），只跟到**落在 PAGE** 为止。
   * 走不通就报错，不会误判成功。
   */
  private static async doLogin(): Promise<void> {
    // 1. 先打开页面，建立站点会话
    const page: UpstreamResponse = await UpstreamClient.get(PAGE, true);
    if (!page.isOk()) {
      throw new ApiError(page.status, 'cloudprint_error',
        '云打印页面加载失败（HTTP ' + page.status + '）');
    }
    // 2. 检查是否已登录（已登录直接返回）
    if (await LocalCloudPrintService.checkLogin()) {
      LocalCloudPrintService.activated = true;
      Logger.info('云打印会话已就绪');
      return;
    }
    // 3. 走 SSO 链：Auth/SSoPage 给出起始 URL
    const bootUrl: string = LocalCloudPrintService.endpoint('Auth/SSoPage') +
      '?backurl=' + encodeURIComponent(PAGE);
    const boot: UpstreamResponse = await UpstreamClient.get(bootUrl, true);
    const bootPayload = LocalCloudPrintService.parseJson(boot);
    const start: string = strOf(bootPayload, 'result');
    if (start.length === 0) {
      throw authRequired();
    }
    // 4. 逐跳跟随，终点必须落回 PAGE
    let current: string = start;
    for (let hop = 0; hop < MAX_HOPS; hop++) {
      const response: UpstreamResponse = await UpstreamClient.get(current, true);
      if (response.isRedirect()) {
        current = resolveLocation(response.url, response.location);
        continue;
      }
      // 200：看是不是落在 PAGE
      const logical: string = await LocalWebVpn.fromWebVpnUrl(response.url);
      if (logical.indexOf(PAGE) === 0) {
        if (await LocalCloudPrintService.checkLogin()) {
          LocalCloudPrintService.activated = true;
          Logger.info('云打印会话就绪（' + hop + ' 跳）');
          return;
        }
        throw authRequired();
      }
      // 落在 sso 登录页 = 会话没了
      if (logical.indexOf('sso.buaa.edu.cn') >= 0) {
        throw authRequired();
      }
      throw new ApiError(401, 'cloudprint_auth',
        '云打印登录未完成（终点异常：' + logical + '），请重新登录后再试');
    }
    throw new ApiError(401, 'cloudprint_auth', '云打印登录跳转过多，请重新登录后再试');
  }

  /**
   * `POST Auth/Check`（带 `Content-Length: 0`，上游：空 POST 不带长度会被拒 411）。
   *
   * @returns 是否已登录（`result.szLogonName` 非空）
   */
  private static async checkLogin(): Promise<boolean> {
    const headers: Record<string, string> = {};
    headers['accept'] = 'application/json, text/plain, */*';
    headers['content-length'] = '0';
    const response: UpstreamResponse = await UpstreamClient.postForm(
      LocalCloudPrintService.endpoint('Auth/Check'), '', true, headers);
    if (!response.isOk()) {
      return false;
    }
    try {
      const payload = JSON.parse(response.body) as Object;
      const code: number = numOf(payload, 'code');
      if (code !== 0) {
        return false;
      }
      const result = objOf(payload, 'result');
      if (result === null) {
        return false;
      }
      return strOf(result, 'szLogonName').length > 0;
    } catch (error) {
      return false;
    }
  }

  private static parseJson(response: UpstreamResponse): Object {
    if (!response.isOk()) {
      throw authRequired();
    }
    const trimmed: string = response.body.trimStart();
    if (trimmed.length === 0 || trimmed.charAt(0) !== '{') {
      throw authRequired();
    }
    try {
      return JSON.parse(response.body) as Object;
    } catch (error) {
      throw invalid();
    }
  }
}
