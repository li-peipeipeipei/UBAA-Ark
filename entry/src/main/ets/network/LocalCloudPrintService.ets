import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { Logger } from '../common/Logger';
import { ApiError } from './ApiError';
import { CasParser } from './CasParser';
import {
  buildImagePdf,
  buildUploadMultipart,
  isPrintableImage,
  isPrintableName,
  MultipartField,
  PRINT_MAX_BYTES,
  printMimeOf,
  randomBoundary
} from './CloudPrintUpload';
import { LocalWebVpn } from './LocalWebVpn';
import { UpstreamClient, UpstreamResponse } from './UpstreamClient';
import { StoredCookie, TokenStore } from './TokenStore';

/**
 * 图书馆云打印（上游 `features/cloud_print/`）—— **只读**部分。
 *
 * 做的是：文档列表（待打印 / 扫描文档，分开取）、打印站状态、使用记录。
 * PDF 生成、分片上传（`pdf.rs` / `upload.rs`）与预览、下载、删除都**不做** ——
 * 那些需要文件选择器、大文件分片与写操作，风险与工作量都高一档。
 *
 * ## 协议（对齐上游 `cloud_print/mod.rs` + `read.rs`）
 *
 * | 用途 | 地址 | 判据 |
 * |---|---|---|
 * | 会话检查 | `POST /api/client/Auth/Check`（`Content-Length: 0`） | `code===0` 且 `result.szLogonName` 非空 |
 * | 待打印 | `GET /api/client/PrintJob/Get` | `code===0` → `result: [...]` |
 * | 扫描文档 | `GET /api/client/Scan/Get` | 同上 |
 * | 打印站 | `GET /api/client/Station/GetSrvList` + `Station/GetList` | 同上 |
 * | 使用记录 | `POST /api/client/Report/DetailPageEx`（JSON 体 5 字段，每页 20 条） | 同上 |
 *
 * - `code===0` 成功；`code===4` **需认证**；其它 = 服务器拒绝。
 * - API 基址 `https://print.lib.buaa.edu.cn/api/client/<path>`；
 *   页面 `https://print.lib.buaa.edu.cn/client/new/cprintPc/cprint.html`。
 * - `PrintJob/Get`、`Scan/Get`、`Station/GetList`、`Report/DetailPageEx` 都要带随机
 *   `timestamp` 查询参（上游 `timestamped()`）。
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

/**
 * 使用记录每页条数。
 *
 * 上游（`read.rs` 与官网脚本）写死 5 条/页；这里按用户要求改成 20 条/页
 * ——手机上 5 条一页要翻十几次，20 条一屏多一点，翻页成本明显更低。
 * 服务端接受任意 `dwRowCount`，并按它重算 `dwTotalPage`。
 */
const RECORD_PAGE_SIZE: number = 20;

/** 上传的传输超时（毫秒）：默认 30s 传大 PDF 会超时（错误码 1007900028）。 */
const UPLOAD_TIMEOUT_MS: number = 180000;

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

/** 一条使用记录（上游 `PrintRecord`）。 */
export interface PrintRecord {
  /** 形如 `20261117`。 */
  date: string;
  /** 形如 `143005`。 */
  time: string;
  pages: string;
  /** A4 / A3；未知为空串。 */
  paper: string;
  /** 免费额度（分）。 */
  freeCents: number;
  /** 校园卡（分）。 */
  cardCents: number;
  /** 其他（分）。 */
  otherCents: number;
}

/** 使用记录的一页。 */
export interface PrintRecords {
  items: PrintRecord[];
  totalPages: number;
}

/** 上传时的打印参数（对应上游 `PrintOptions`）。 */
export interface PrintOptionSet {
  /** `true` 彩色（`dwColor=2`）；`false` 黑白（`dwColor=1`）。 */
  color: boolean;
  /** `-1` 原稿 / `8` A3 / `9` A4。 */
  paper: number;
  /** `1` 单面 / `2` 长边翻转 / `3` 短边翻转。 */
  duplex: number;
  copies: number;
  /** 页码范围；`0,0` = 全部。 */
  from: number;
  to: number;
}

/** 待上传的一份文件。 */
export interface LocalPrintFile {
  name: string;
  bytes: Uint8Array;
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
   * 文档列表。
   *
   * @param scans `false` = 待打印（`PrintJob/Get`）；`true` = 扫描文档（`Scan/Get`）。
   *              两套接口字段语义不同（`szJobName` vs `szDisplayName`、`dwCreateDate` vs
   *              `dwSubmitDate`），必须分开取，不能合并——否则「待打印」里会混进扫描件。
   */
  static async fetchDocuments(scans: boolean): Promise<PrintDocument[]> {
    const path: string = scans ? 'Scan/Get' : 'PrintJob/Get';
    const rows = arrOf(envelope(await LocalCloudPrintService.json(path)), 'result');
    const out: PrintDocument[] = [];
    for (let i = 0; i < rows.length; i++) {
      out.push(LocalCloudPrintService.jobDocument(rows[i], scans));
    }
    return out;
  }

  /**
   * 使用记录（上游 `read.rs` 的 `records`）。
   *
   * `POST Report/DetailPageEx?timestamp=…`，JSON 体五个字段。
   *
   * ⚠️ 每页条数用 **20**（`RECORD_PAGE_SIZE`），**刻意偏离上游的 5** —— 上游那个值
   * 来自官网脚本，一页 5 条在手机上要翻十几次页，用户要求改成一页 20 条。
   * 服务端认可任意 `dwRowCount`，`dwTotalPage` 会按新页长重算（实测 51 条记录：
   * 5/页 → 11 页，20/页 → 3 页）。
   *
   * @param begin `yyyyMMdd`
   * @param end   `yyyyMMdd`（含当天）
   * @param kind  `1` 打印 / `2` 复印 / `4` 扫描（位标志，不是序号）
   * @param page  从 1 开始
   */
  static async fetchRecords(begin: string, end: string, kind: number, page: number): Promise<PrintRecords> {
    if (!LocalCloudPrintService.isYmd(begin) || !LocalCloudPrintService.isYmd(end) ||
      begin > end || page < 1 || (kind !== 1 && kind !== 2 && kind !== 4)) {
      throw new ApiError(400, 'cloudprint_records', '使用记录查询条件无效');
    }
    const bodyText: string = '{"dwBeginDate":"' + begin + '","dwEndDate":"' + end +
      '","dwType":' + kind.toString() + ',"dwPageNo":' + page.toString() +
      ',"dwRowCount":' + RECORD_PAGE_SIZE.toString() + '}';
    const payload: Object = envelope(await LocalCloudPrintService.postJson('Report/DetailPageEx', bodyText));
    const rows = arrOf(payload, 'result');
    const items: PrintRecord[] = [];
    for (let i = 0; i < rows.length; i++) {
      items.push(LocalCloudPrintService.recordOf(rows[i]));
    }
    // 上游：第一页就没有记录时总页数记 0（服务端此时可能回 null/空）
    const total: number = (items.length === 0 && page === 1) ? 0 : numOf(payload, 'dwTotalPage');
    return {
      items: items,
      totalPages: total
    } as PrintRecords;
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

  /**
   * 上传一份文档（上游 `upload.rs` 的 `send_upload`）。
   *
   * `POST /api/client/CloudPrint/Upload`，multipart 体：文件段 `szPath` 在最前，
   * 随后 `dwColor` / `dwPaperId` / `dwDuplex` / `dwFrom` / `dwTo` / `dwCopies` / `BackURL`。
   *
   * 成功判据是**重定向**：302 到 `printDoc.html?code=0`。`code` 非 0 = 服务端拒绝，
   * HTTP 413 = 超出大小限制。
   *
   * 图片（jpg/png）先在本机转成单页 PDF 再传 —— 与上游一致（服务端只吃 PDF 预览）。
   *
   * ⚠️ 这是**写**请求，失败绝不重发（`postRaw` 的 `isRead` 恒为 false）。
   */
  static async upload(file: LocalPrintFile, options: PrintOptionSet): Promise<void> {
    if (!isPrintableName(file.name)) {
      throw new ApiError(400, 'cloudprint_upload', '文件名无效：不能包含 / \\ " 等字符');
    }
    const mime: string = printMimeOf(file.name);
    if (mime.length === 0) {
      throw new ApiError(400, 'cloudprint_upload',
        '官网未列出此文件格式，请选择 PDF、图片或常见 Office 文件');
    }
    if (file.bytes.length === 0 || file.bytes.length > PRINT_MAX_BYTES) {
      throw new ApiError(400, 'cloudprint_upload', '打印文件需大于 0 字节且不超过 32 MiB');
    }
    let name: string = file.name;
    let mimeType: string = mime;
    let bytes: Uint8Array = file.bytes;
    const converting: boolean = isPrintableImage(name);
    if (converting) {
      bytes = await LocalCloudPrintService.imagePdfBytes(file.bytes, options.paper);
      name = name + '.pdf';
      mimeType = 'application/pdf';
      if (bytes.length > PRINT_MAX_BYTES) {
        throw new ApiError(400, 'cloudprint_upload', '图片转为 PDF 后超过 32 MiB');
      }
    }
    // 图片一律按 A4/A3 出图（原稿尺寸对图片没意义），与上游同一规则
    const paper: number = (converting && options.paper === -1) ? 9 : options.paper;
    const from: number = converting ? 0 : options.from;
    const to: number = converting ? 0 : options.to;
    const queuedUrl: string = 'https://print.lib.buaa.edu.cn/client/new/cprintPc/printDoc.html?t=' +
      Date.now().toString();

    const boundary: string = randomBoundary();
    const fields: MultipartField[] = [
      { key: 'dwColor', value: options.color ? '2' : '1' },
      { key: 'dwPaperId', value: paper.toString() },
      { key: 'dwDuplex', value: options.duplex.toString() },
      { key: 'dwFrom', value: from.toString() },
      { key: 'dwTo', value: to.toString() },
      { key: 'dwCopies', value: options.copies.toString() },
      { key: 'BackURL', value: queuedUrl }
    ];
    const body: ArrayBuffer = buildUploadMultipart(boundary, 'szPath', name, mimeType, bytes, fields);

    await LocalCloudPrintService.ensureSession();
    const headers: Record<string, string> = {};
    headers['origin'] = 'https://print.lib.buaa.edu.cn';
    headers['referer'] = PAGE;
    let response: UpstreamResponse;
    try {
      response = await UpstreamClient.postRaw(
        LocalCloudPrintService.endpoint('CloudPrint/Upload'), body,
        'multipart/form-data; boundary=' + boundary, false, headers,
        // 上传放宽到 3 分钟：默认 30s 传大 PDF 会报 `Timeout was reached`（错误码 1007900028），
        // 服务端还要落盘 + 转码，叠加校内网关后更慢
        UPLOAD_TIMEOUT_MS);
    } catch (error) {
      // 传输层失败（含超时 1007900028）：给一句人话，别把 RCP 的原始英文抛给用户
      if (error instanceof ApiError && (error as ApiError).networkFailure) {
        throw new ApiError(0, 'cloudprint_upload',
          '上传超时或网络中断：大文件请连校内网络重试（单份上限 32 MiB）', true);
      }
      throw error as Error;
    }
    LocalCloudPrintService.checkUploadReply(response);
  }

  /**
   * 删除一份文档（上游 `read.rs` 的 `delete`）。
   *
   * 打印：`PrintJob/Del` + `{dwJobId, dwOldJobId}`；扫描：`Scan/Del` + `{dwJobId}`。
   * 写请求，不重发；上游在「结果未知」时要求先刷新列表核对，这里直接抛错让用户重试。
   */
  static async deleteDocument(item: PrintDocument, scan: boolean): Promise<void> {
    if (item.expired) {
      throw new ApiError(400, 'cloudprint_delete', '扫描文档已过期，无法删除');
    }
    await LocalCloudPrintService.ensureSession();
    const path: string = scan ? 'Scan/Del' : 'PrintJob/Del';
    const bodyText: string = scan ?
      '{"dwJobId":"' + item.id + '"}' :
      '{"dwJobId":"' + item.id + '","dwOldJobId":"' + item.id + '"}';
    const headers: Record<string, string> = {};
    headers['referer'] = PAGE;
    const response: UpstreamResponse = await UpstreamClient.postJson(
      LocalCloudPrintService.endpoint(path), bodyText, false, headers, false);
    const payload: Object = LocalCloudPrintService.readJson(response);
    envelope(payload);
  }

  /**
   * 打印文档某页的预览图（上游 `read.rs` 的 `preview`）。
   *
   * `GET PrintJob/PreviewPage?dwJobId&dwCreateTime&pageNo`，`result` 是 **PNG 的 base64**。
   *
   * @param pageNo 从 1 开始；超过总页数会抛「预览页码不可用」
   */
  static async fetchPreviewPage(job: PrintDocument, pageNo: number): Promise<Uint8Array> {
    if (pageNo < 1 || (job.pages.length > 0 && pageNo > Number(job.pages))) {
      throw new ApiError(400, 'cloudprint_preview', '预览页码不可用');
    }
    await LocalCloudPrintService.ensureSession();
    const url: string = LocalCloudPrintService.endpoint('PrintJob/PreviewPage') +
      '?timestamp=' + Math.random().toString() +
      '&dwJobId=' + encodeURIComponent(job.id) +
      '&dwCreateTime=' + encodeURIComponent(job.time) +
      '&pageNo=' + pageNo.toString();
    const headers: Record<string, string> = {};
    headers['accept'] = 'application/json, text/plain, */*';
    const payload: Object = LocalCloudPrintService.readJson(
      await UpstreamClient.get(url, true, headers));
    envelope(payload);
    const encoded: string = strOf(payload, 'result');
    if (encoded.length === 0) {
      throw new ApiError(502, 'cloudprint_preview', '预览图返回为空，请稍后重试');
    }
    try {
      const bytes: Uint8Array = new util.Base64Helper().decodeSync(encoded);
      // 上游要求严格是 PNG 头，否则判「无法识别」
      if (bytes.length < 8 || bytes[0] !== 0x89 || bytes[1] !== 0x50) {
        throw new ApiError(502, 'cloudprint_preview', '打印站返回的预览图格式异常');
      }
      return bytes;
    } catch (error) {
      if (error instanceof ApiError) {
        throw error;
      }
      throw new ApiError(502, 'cloudprint_preview', '预览图解码失败');
    }
  }

  /** 下载扫描原件（上游 `read.rs` 的 `scan_download`），返回 PDF/图片字节。 */
  static async downloadScan(job: PrintDocument): Promise<Uint8Array> {
    if (job.expired) {
      throw new ApiError(400, 'cloudprint_download', '扫描文档已过期，无法下载');
    }
    await LocalCloudPrintService.ensureSession();
    const url: string = LocalCloudPrintService.endpoint('Scan/Download') +
      '?dwJobId=' + encodeURIComponent(job.id);
    const response: UpstreamResponse = await UpstreamClient.getBinary(url, true);
    if (!response.isOk()) {
      throw new ApiError(response.status, 'cloudprint_download',
        '扫描件下载失败（HTTP ' + response.status + '）');
    }
    const bytes: Uint8Array = response.bytes === null ? new Uint8Array(0) : response.bytes;
    if (bytes.length === 0) {
      throw new ApiError(502, 'cloudprint_download', '打印站没有返回扫描文件，请稍后重试');
    }
    // 上游会拦「返回 HTML/JSON」这种被跳登录页的情况
    if (bytes.length > 1 && bytes[0] === 0x3c) {
      LocalCloudPrintService.activated = false;
      throw new ApiError(401, 'cloudprint_auth', '云打印会话已失效，请重新登录后再试');
    }
    return bytes;
  }

  /* ------------------------------ 上传辅助 ------------------------------ */

  /**
   * 图片 → 单页 PDF。
   *
   * 先让 ImageKit 统一解码并重新编码成 JPEG（PNG 的透明通道也一并合成掉），
   * 再套上 `CloudPrintUpload.buildImagePdf` 的最小 PDF 结构。
   *
   * ⚠️ 编码完成前**不能**释放 pixelMap（会拿到 401 参数异常，官方列为常见错误）。
   */
  private static async imagePdfBytes(source: Uint8Array, paper: number): Promise<Uint8Array> {
    let imageSource: image.ImageSource | null = null;
    let pixelMap: image.PixelMap | null = null;
    const packer: image.ImagePacker = image.createImagePacker();
    try {
      // 复制一份独立的内存：底层共享内存直接交给 createImageSource 会崩（见 CaptchaRecognizer）
      const copy = new Uint8Array(source.length);
      copy.set(source);
      imageSource = image.createImageSource(copy.buffer as ArrayBuffer);
      if (imageSource === null) {
        throw new ApiError(400, 'cloudprint_upload', '无法解析这张图片');
      }
      pixelMap = await imageSource.createPixelMap();
      if (pixelMap === null) {
        throw new ApiError(400, 'cloudprint_upload', '无法解析这张图片');
      }
      const info: image.ImageInfo = await pixelMap.getImageInfo();
      const width: number = info.size.width;
      const height: number = info.size.height;
      if (width <= 0 || height <= 0) {
        throw new ApiError(400, 'cloudprint_upload', '图片尺寸异常');
      }
      if (width * height > 24000000) {
        throw new ApiError(400, 'cloudprint_upload', '图片像素过大（超过 2400 万），请先压缩');
      }
      const option: image.PackingOption = { format: 'image/jpeg', quality: 94 };
      const jpeg: ArrayBuffer = await packer.packToData(pixelMap, option);
      return new Uint8Array(buildImagePdf(jpeg, width, height, paper));
    } catch (error) {
      if (error instanceof ApiError) {
        throw error;
      }
      throw new ApiError(400, 'cloudprint_upload', '无法将该图片转为可打印的 PDF');
    } finally {
      await packer.release();
      if (pixelMap !== null) {
        await pixelMap.release();
      }
      if (imageSource !== null) {
        await imageSource.release();
      }
    }
  }

  /** 上传响应判据：302/303 + `printDoc.html?code=0`。 */
  private static checkUploadReply(response: UpstreamResponse): void {
    if (response.status === 413) {
      throw new ApiError(413, 'cloudprint_upload', '文件超过云打印服务器的大小限制');
    }
    if (response.status !== 302 && response.status !== 303) {
      if (response.status === 401) {
        LocalCloudPrintService.activated = false;
        throw authRequired();
      }
      throw new ApiError(response.status, 'cloudprint_upload',
        '上传未完成（HTTP ' + response.status + '），请稍后重试');
    }
    const location: string = response.location;
    if (location.indexOf('/printDoc.html') < 0) {
      throw new ApiError(502, 'cloudprint_upload', '上传结果无法识别，请刷新待打印列表核对');
    }
    const marker: number = location.indexOf('code=');
    if (marker < 0) {
      throw new ApiError(502, 'cloudprint_upload', '上传结果无法识别，请刷新待打印列表核对');
    }
    const rest: string = location.substring(marker + 5);
    const amp: number = rest.indexOf('&');
    const codeText: string = amp < 0 ? rest : rest.substring(0, amp);
    const code: number = Number(codeText);
    if (!Number.isFinite(code)) {
      throw new ApiError(502, 'cloudprint_upload', '上传结果无法识别，请刷新待打印列表核对');
    }
    if (code !== 0) {
      throw new ApiError(403, 'cloudprint_upload',
        '云打印服务器拒绝了这份文件（code ' + code.toString() + '）');
    }
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

  private static recordOf(row: Object): PrintRecord {
    const paperId: number = numOf(row, 'dwPaperID');
    return {
      date: idLike(row, 'dwDate'),
      time: idLike(row, 'dwTime'),
      pages: idLike(row, 'dwPages'),
      paper: paperId === 9 ? 'A4' : (paperId === 8 ? 'A3' : ''),
      freeCents: numOf(row, 'dwUsedFreeMoney'),
      cardCents: numOf(row, 'dwUsedCardMoney'),
      otherCents: numOf(row, 'dwUsedMoney')
    } as PrintRecord;
  }

  /** `yyyyMMdd` 且逐位是数字（上游 `records` 的入参校验）。 */
  private static isYmd(text: string): boolean {
    if (text.length !== 8) {
      return false;
    }
    for (let i = 0; i < text.length; i++) {
      const code: number = text.charCodeAt(i);
      if (code < 48 || code > 57) {
        return false;
      }
    }
    return true;
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
    // 上游 read.rs：文档列表与 Station/GetList 带随机 timestamp（防缓存）；
    // Station/GetSrvList 用干净的 endpoint。
    const needStamp: boolean = path.indexOf('PrintJob/Get') >= 0 ||
      path.indexOf('Scan/Get') >= 0 || path.indexOf('Station/GetList') >= 0;
    const url: string = needStamp ?
      LocalCloudPrintService.timestamped(path) : LocalCloudPrintService.endpoint(path);
    const response: UpstreamResponse = await UpstreamClient.get(url, true, headers);
    return LocalCloudPrintService.readJson(response);
  }

  /**
   * JSON 体 POST（使用记录）。
   *
   * ⚠️ 这是**只读查询**（`isRead = true`）：允许网络层失败时换路重试一次。
   * 云打印的写入（删除 / 上传）不在这里，它们绝不能重发。
   */
  private static async postJson(path: string, bodyText: string): Promise<Object> {
    await LocalCloudPrintService.ensureSession();
    const headers: Record<string, string> = {};
    headers['accept'] = 'application/json, text/plain, */*';
    const url: string = LocalCloudPrintService.timestamped(path);
    const response: UpstreamResponse =
      await UpstreamClient.postJson(url, bodyText, true, headers, true);
    return LocalCloudPrintService.readJson(response);
  }

  /**
   * 统一解读响应：401 / 非 JSON（被跳登录页）= 会话失效；HTTP 非 2xx = 服务不可用。
   *
   * 两种失效都**必须把 `activated` 置回 false**：否则下次请求仍以为会话有效，
   * 一直拿着过期 cookie 打到底（云打印的登录链只在 `activated === false` 时才会重走）。
   */
  private static readJson(response: UpstreamResponse): Object {
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
    // 0. 清掉本站存量 cookie：旧版把「未声明 Path」的 cookie 钉在目录级，同名
    //    `SESSIONID`/`OSESSIONID` 分裂成多条且值不同，会让 SSO 换取后的会话对不上。
    //    只清 print 域，不动 CAS 登录态。
    LocalCloudPrintService.dropStaleCookies();
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
    // 4. 逐跳跟随到终点（必须自己跟，不能用自动重定向）
    //
    // 🔴 踩过的坑：这里原先用 `get(start, true)` 让 RCP 自动跟随。RCP 跟随之后
    // `response.url` 仍然是**请求时那个地址**，于是终点被读成链路中间的
    // `authcenter/toLoginPage?...`，误报「终点异常」—— 其实票据链早就走完了。
    // `UpstreamClient.follow` 每跳单独发、单独收 Cookie，`url` 就是当跳的真实地址。
    const finalResp: UpstreamResponse = await UpstreamClient.follow(start);
    const logical: string = await LocalWebVpn.fromWebVpnUrl(finalResp.url);

    // 终点落在打印页 = 走通
    if (logical.indexOf(PAGE) === 0) {
      if (await LocalCloudPrintService.checkLogin()) {
        LocalCloudPrintService.activated = true;
        Logger.info('云打印会话就绪（终点 ' + logical + '）');
        return;
      }
      throw authRequired();
    }
    // 停在**带 execution 的**登录页才算会话没了（CAS 中转本身会经过 sso，不能一见 sso 就判死）
    if (logical.indexOf('sso.buaa.edu.cn') >= 0 &&
      CasParser.extractExecution(finalResp.body).length > 0) {
      throw authRequired();
    }
    throw new ApiError(401, 'cloudprint_auth',
      '云打印登录未完成（终点异常：' + logical + '），请重新登录后再试');
  }

  /**
   * `POST Auth/Check`（带 `Content-Length: 0`，上游：空 POST 不带长度会被拒 411）。
   *
   * @returns 是否已登录（`code===0` 且 `result.szLogonName` 与本机账号一致）
   */
  private static async checkLogin(): Promise<boolean> {
    const headers: Record<string, string> = {};
    headers['accept'] = 'application/json, text/plain, */*';
    headers['content-length'] = '0';
    // 只读的登录态检查（空 POST）：允许自动换路重试
    const response: UpstreamResponse = await UpstreamClient.postForm(
      LocalCloudPrintService.endpoint('Auth/Check'), '', true, headers, true);
    return LocalCloudPrintService.interpret(response, TokenStore.getSession().username);
  }

  /** 清掉云打印站的存量 cookie（不含其它站点）。 */
  private static dropStaleCookies(): void {
    const mode = TokenStore.getConnectionMode();
    const jar: StoredCookie[] = TokenStore.loadCookies(mode);
    const kept: StoredCookie[] = [];
    for (let i = 0; i < jar.length; i++) {
      if (jar[i].domain.toLowerCase().indexOf(HOST) < 0) {
        kept.push(jar[i]);
      }
    }
    if (kept.length !== jar.length) {
      TokenStore.saveCookies(kept, mode);
      Logger.info('云打印：清理存量 cookie ' + (jar.length - kept.length) + ' 条');
    }
  }

  /**
   * 把 `Auth/Check` 的响应解读成「是否已登录」。
   *
   * 判据对齐上游 `cloud_print/auth.rs` 的 `check()`：`code===0`、
   * `result.szLogonName` 非空、且与本机登录账号一致。
   */
  private static interpret(response: UpstreamResponse, expected: string): boolean {
    const trimmed: string = response.body.trimStart();
    if (!response.isOk() || trimmed.length === 0 || trimmed.charAt(0) !== '{') {
      // 被重定向到登录页 / 空体：都按未登录处理
      Logger.warn('云打印会话探测未通过：HTTP ' + response.status + ' / ' +
        response.body.length + 'B / 非 JSON');
      return false;
    }
    try {
      const payload = JSON.parse(response.body) as Object;
      const code: number = numOf(payload, 'code');
      const result = objOf(payload, 'result');
      const logonName: string = result === null ? '' : strOf(result, 'szLogonName');
      let ok: boolean = code === 0 && logonName.length > 0;
      // 上游 auth.rs 的 check() 还要求**账号匹配**：登着别人的号不能当"已登录"。
      if (ok && expected.length > 0 && expected !== logonName) {
        Logger.warn('云打印会话属于其它账号（' + Logger.mask(logonName) + '），按未登录处理');
        ok = false;
      }
      if (!ok) {
        Logger.warn('云打印会话无效：code=' + code + ' / ' + strOf(payload, 'message'));
      }
      return ok;
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
