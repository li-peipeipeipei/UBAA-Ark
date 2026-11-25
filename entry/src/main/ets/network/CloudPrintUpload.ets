import { util } from '@kit.ArkTS';

/**
 * 云打印上传用到的两个「手工活」：图片转 PDF、拼 multipart 请求体。
 *
 * 上游（Rust 侧）分别用 `pdf.rs` 的 `image_pdf` 和 `reqwest` 的 multipart 完成；
 * HarmonyOS 这边没有现成的等价物：
 * - `rcp.MultipartForm` 不能带自定义 boundary 与 `Origin`/`Referer`（云打印会挑），
 *   所以沿用 `LocalYgdkService` 里那套「手工拼字节」的做法（那边是同一个坑）；
 * - 图片转 PDF 只能自己写一个最小 PDF：把图片统一编码成 JPEG，作为单个
 *   `DCTDecode` 图像 XObject 放进一页。
 */

/** 单份文件上限（与上游 `MAX_UPLOAD_BYTES` 一致）。 */
export const PRINT_MAX_BYTES: number = 32 * 1024 * 1024;

/** 按扩展名给 MIME；不支持的格式返回空串。表与上游 `file_type()` 一致。 */
export function printMimeOf(name: string): string {
  const dot: number = name.lastIndexOf('.');
  if (dot < 0) {
    return '';
  }
  const ext: string = name.substring(dot + 1).toLowerCase();
  if (ext === 'jpg' || ext === 'jpeg') {
    return 'image/jpeg';
  }
  if (ext === 'png') {
    return 'image/png';
  }
  if (ext === 'pdf') {
    return 'application/pdf';
  }
  if (ext === 'docx') {
    return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
  }
  if (ext === 'xlsx') {
    return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
  }
  if (ext === 'pptx') {
    return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
  }
  if (ext === 'txt') {
    return 'text/plain';
  }
  // 官网列了但只能按二进制传的格式（服务端自己转换）
  const binary: string[] = ['heic', 'doc', 'xls', 'xslx', 'ppt', 'wps', 'wpt', 'dot', 'rtf',
    'dotx', 'docm', 'dotm', 'xml', 'mht', 'mhtml', 'html', 'htm', 'xps', 'odt', 'xlsm', 'xlsb',
    'csv', 'xltx', 'xltm', 'xlt', 'prn', 'dif', 'slk', 'xla', 'xlam', 'ods', 'dps', 'dpt', 'pot',
    'pps', 'pptm', 'potm', 'ppsm'];
  for (let i = 0; i < binary.length; i++) {
    if (ext === binary[i]) {
      return 'application/octet-stream';
    }
  }
  return '';
}

/** 需要先转成 PDF 再传的图片（上游同样只认 jpg/png，其余图片格式由服务端按 octet-stream 处理）。 */
export function isPrintableImage(name: string): boolean {
  const mime: string = printMimeOf(name);
  return mime === 'image/jpeg' || mime === 'image/png';
}

/** 文件名合法性（上游 `file_type()` 的校验：非空、≤240、无控制字符与路径分隔符）。 */
export function isPrintableName(name: string): boolean {
  if (name.length === 0 || name.length > 240 || name !== name.trim()) {
    return false;
  }
  for (let i = 0; i < name.length; i++) {
    const code: number = name.charCodeAt(i);
    if (code < 0x20 || code === 0x7f) {
      return false;
    }
    const ch: string = name.charAt(i);
    if (ch === '/' || ch === '\\' || ch === '"') {
      return false;
    }
  }
  return true;
}

function padNum(value: number, width: number): string {
  let out: string = Math.round(value).toString();
  while (out.length < width) {
    out = '0' + out;
  }
  return out;
}

function fixed2(value: number): string {
  return value.toFixed(2);
}

function joinChunks(chunks: Uint8Array[]): ArrayBuffer {
  let total: number = 0;
  for (let i = 0; i < chunks.length; i++) {
    total += chunks[i].length;
  }
  const merged = new Uint8Array(total);
  let offset: number = 0;
  for (let i = 0; i < chunks.length; i++) {
    merged.set(chunks[i], offset);
    offset += chunks[i].length;
  }
  return merged.buffer;
}

/**
 * 单页 PDF：把一张 JPEG 铺在一页上。
 *
 * 页面尺寸与上游 `image_pdf` 完全一致：`dwPaperId == 8` → A3，否则 A4；横图先把纸转成横向；
 * 图片等比缩放后居中（`cm` 矩阵 + `Do`）。
 *
 * PDF 结构只有五个对象：Catalog / Pages / Page / Contents / Image(XObject, DCTDecode)。
 * 手写是为了**不引三方库**：这张 PDF 只让服务端解码一次，不需要完整实现。
 */
export function buildImagePdf(jpeg: ArrayBuffer, imageWidth: number, imageHeight: number,
  paper: number): ArrayBuffer {
  const encoder = new util.TextEncoder();
  const chunks: Uint8Array[] = [];
  const offsets: number[] = [];
  let offset: number = 0;

  const pushText = (text: string): void => {
    const bytes: Uint8Array = encoder.encodeInto(text);
    chunks.push(bytes);
    offset += bytes.length;
  };

  let width: number = paper === 8 ? 841.89 : 595.28;
  let height: number = paper === 8 ? 1190.55 : 841.89;
  if (imageWidth > imageHeight) {
    const swap: number = width;
    width = height;
    height = swap;
  }
  const scale: number = Math.min(width / imageWidth, height / imageHeight);
  const drawWidth: number = imageWidth * scale;
  const drawHeight: number = imageHeight * scale;
  const drawX: number = (width - drawWidth) / 2;
  const drawY: number = (height - drawHeight) / 2;

  pushText('%PDF-1.5\n');

  offsets.push(offset);
  pushText('1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n');

  offsets.push(offset);
  pushText('2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n');

  offsets.push(offset);
  pushText('3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ' + fixed2(width) + ' ' +
    fixed2(height) + '] /Resources << /XObject << /Image 5 0 R >> >> /Contents 4 0 R >>\nendobj\n');

  const content: string = 'q\n' + fixed2(drawWidth) + ' 0 0 ' + fixed2(drawHeight) + ' ' +
    fixed2(drawX) + ' ' + fixed2(drawY) + ' cm\n/Image Do\nQ\n';
  const contentBytes: Uint8Array = encoder.encodeInto(content);
  offsets.push(offset);
  pushText('4 0 obj\n<< /Length ' + contentBytes.length.toString() + ' >>\nstream\n');
  chunks.push(contentBytes);
  offset += contentBytes.length;
  pushText('\nendstream\nendobj\n');

  const imageBytes = new Uint8Array(jpeg);
  offsets.push(offset);
  pushText('5 0 obj\n<< /Type /XObject /Subtype /Image /Width ' + imageWidth.toString() +
    ' /Height ' + imageHeight.toString() +
    ' /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length ' +
    imageBytes.length.toString() + ' >>\nstream\n');
  chunks.push(imageBytes);
  offset += imageBytes.length;
  pushText('\nendstream\nendobj\n');

  // 交叉引用表：每条形如「10 位字节偏移 + 5 位代号 + ' n' + 空格 + 换行」共 20 字节
  const xrefStart: number = offset;
  let xref: string = 'xref\n0 6\n0000000000 65535 f \n';
  for (let i = 0; i < offsets.length; i++) {
    xref += padNum(offsets[i], 10) + ' 00000 n \n';
  }
  xref += 'trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n' + xrefStart.toString() + '\n%%EOF\n';
  pushText(xref);

  return joinChunks(chunks);
}

/** multipart 的一个文本字段（顺序即发送顺序）。 */
export interface MultipartField {
  key: string;
  value: string;
}

/**
 * 拼 multipart/form-data 请求体。
 *
 * 顺序与上游一致：**文件段在最前**（`szPath`），随后才是 `dwColor` 等字段。
 * 与 `LocalYgdkService` 里那份是同一种写法（那边字段在前，顺序按服务端要求不同）。
 */
export function buildUploadMultipart(boundary: string, fileField: string, fileName: string,
  mimeType: string, fileBytes: Uint8Array, fields: MultipartField[]): ArrayBuffer {
  const encoder = new util.TextEncoder();
  const crlf: string = '\r\n';
  const chunks: Uint8Array[] = [];
  chunks.push(encoder.encodeInto('--' + boundary + crlf +
    'Content-Disposition: form-data; name="' + fileField + '"; filename="' + fileName + '"' + crlf +
    'Content-Type: ' + mimeType + crlf + crlf));
  chunks.push(fileBytes);
  chunks.push(encoder.encodeInto(crlf));
  for (let i = 0; i < fields.length; i++) {
    chunks.push(encoder.encodeInto('--' + boundary + crlf +
      'Content-Disposition: form-data; name="' + fields[i].key + '"' + crlf + crlf +
      fields[i].value + crlf));
  }
  chunks.push(encoder.encodeInto('--' + boundary + '--' + crlf));
  return joinChunks(chunks);
}

/** 随机 boundary（48 位字母数字，与上游同量级，避免与文件内容撞车）。 */
export function randomBoundary(): string {
  const alphabet: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  let out: string = '----UBAAPrint';
  for (let i = 0; i < 32; i++) {
    out += alphabet.charAt(Math.floor(Math.random() * alphabet.length));
  }
  return out;
}
