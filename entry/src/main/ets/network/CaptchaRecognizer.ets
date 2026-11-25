import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { GlobalContext } from '../common/GlobalContext';
import { Logger } from '../common/Logger';
import { init as mnnInit, debug as mnnDebug, recognize as mnnRecognize } from 'libmnncaptcha.so';

/**
 * 验证码自动识别（MNN 本地推理，不上传图片）。
 *
 * 模型与字符集都来自 ddddocr 通用模型（8210 类 CTC），随包放在 `rawfile`：
 * - `ocr.mnn`：MNN 格式的 CRNN 模型（约 52 MB）
 * - `captcha_charset.txt`：8192 + 18 个字符，**每行一个**，首行是 CTC 的 blank
 *
 * ⚠️ **字符集必须与模型配套**：同名的 `charset.json`（UBAA 仓库里那份）顺序与此
 * 不同，混用会解出一串毫不相干的中文。
 *
 * 首次识别时把模型从 `rawfile` 复制到沙箱再加载（`createFromFile` 需要真实路径），
 * 之后直接复用；失败不抛错，一律返回空串，由调用方退回人工输入。
 */

const MODEL_ASSET: string = 'ocr.mnn';
const CHARSET_ASSET: string = 'captcha_charset.txt';
const MODEL_FILE: string = 'captcha-model.mnn';
/** 模型预期下限：小于这个大小说明没复制完整。 */
const MODEL_MIN_BYTES: number = 40 * 1024 * 1024;

export class CaptchaRecognizer {
  private static ready: boolean = false;
  private static broken: boolean = false;
  /** 在途的初始化任务（并发调用只跑一次）。 */
  private static task: Promise<boolean> | null = null;

  /** 模型是否可用（未初始化时返回 false，不触发加载）。 */
  static isReady(): boolean {
    return CaptchaRecognizer.ready;
  }

  /**
   * 懒加载：复制模型 → 读字符集 → 建会话。
   *
   * 幂等且并发安全：已完成直接返回，在途则复用同一个 Promise。
   */
  static ensureReady(): Promise<boolean> {
    if (CaptchaRecognizer.ready) {
      return Promise.resolve(true);
    }
    if (CaptchaRecognizer.broken) {
      return Promise.resolve(false);
    }
    if (CaptchaRecognizer.task !== null) {
      return CaptchaRecognizer.task;
    }
    const task: Promise<boolean> = CaptchaRecognizer.load().then((ok: boolean) => {
      CaptchaRecognizer.ready = ok;
      CaptchaRecognizer.broken = !ok;
      CaptchaRecognizer.task = null;
      return ok;
    }).catch((error: Error) => {
      Logger.warn('验证码模型初始化失败：' + error.message);
      CaptchaRecognizer.broken = true;
      CaptchaRecognizer.task = null;
      return false;
    });
    CaptchaRecognizer.task = task;
    return task;
  }

  private static async load(): Promise<boolean> {
    const context = GlobalContext.getContext();
    const modelPath: string = context.filesDir + '/' + MODEL_FILE;

    // 1. 模型落地到沙箱（只在缺失或明显不完整时复制）
    let needCopy: boolean = true;
    try {
      const stat = fileIo.statSync(modelPath);
      needCopy = stat.size < MODEL_MIN_BYTES;
    } catch (error) {
      needCopy = true;
    }
    if (needCopy) {
      const started: number = Date.now();
      const raw = await context.resourceManager.getRawFileContent(MODEL_ASSET);
      const file = fileIo.openSync(modelPath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, raw.buffer as ArrayBuffer);
      } finally {
        fileIo.closeSync(file);
      }
      Logger.info('验证码模型已释放到沙箱：' + raw.byteLength + ' 字节，' +
        (Date.now() - started) + 'ms');
    }

    // 2. 字符集（每行一个，首行是 blank）
    const charsetBytes = await context.resourceManager.getRawFileContent(CHARSET_ASSET);
    const decoder = util.TextDecoder.create('utf-8');
    const charset: string = decoder.decodeToString(charsetBytes);
    Logger.info('验证码字符集读取完成：' + charsetBytes.byteLength + ' 字节');

    // 3. 建会话
    const started: number = Date.now();
    Logger.info('开始加载验证码模型：' + modelPath + '（' + (needCopy ? '刚复制' : '已存在') + '）');
    const ok: boolean = mnnInit(modelPath, charset);
    Logger.info('验证码模型加载' + (ok ? '成功' : '失败') + '：' + (Date.now() - started) + 'ms');
    return ok;
  }

  /**
   * 识别一张验证码。
   *
   * @param bytes 图片原始字节（JPEG/PNG，直接用上游响应体）
   * @returns 6 位小写字母数字；识别不出来返回空串
   */
  static async recognizeImage(bytes: Uint8Array): Promise<string> {
    if (bytes.length === 0) {
      return '';
    }
    const ok: boolean = await CaptchaRecognizer.ensureReady();
    if (!ok) {
      return '';
    }
    let source: image.ImageSource | null = null;
    let pixelMap: image.PixelMap | null = null;
    try {
      // ⚠️ 必须复制成独立的 ArrayBuffer 再交给 ImageKit：
      // 上游响应体是 RCP 持有的缓冲区，直接把 `bytes.buffer` 传进去属于跨模块
      // 共享同一块native内存，实测会在 createImageSource 里 SIGSEGV。
      const copy = new Uint8Array(bytes.length);
      copy.set(bytes);
      Logger.info('验证码识别：图片 ' + bytes.length + ' 字节，开始解码');
      source = image.createImageSource(copy.buffer as ArrayBuffer);
      pixelMap = await source.createPixelMap({
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      });
      const info: image.ImageInfo = await pixelMap.getImageInfo();
      const width: number = info.size.width;
      const height: number = info.size.height;
      if (width <= 0 || height <= 0) {
        return '';
      }
      const buffer = new ArrayBuffer(width * height * 4);
      await pixelMap.readPixelsToBuffer(buffer);
      Logger.info('验证码识别：像素 ' + width + '×' + height + '，开始推理');
      const text: string = mnnRecognize(buffer, width, height);
      Logger.info('验证码识别：原始输出 ' + text + '｜' + mnnDebug());
      const cleaned: string = text.trim().toLowerCase();
      // 只接受 6 位字母数字：其它长度/字符说明这次识别没收敛，交给人工
      if (cleaned.length !== 6) {
        Logger.warn('验证码识别结果长度异常：' + cleaned.length + '（' + cleaned + '）');
        return '';
      }
      for (let i = 0; i < cleaned.length; i++) {
        const code: number = cleaned.charCodeAt(i);
        const isDigit: boolean = code >= 48 && code <= 57;
        const isLower: boolean = code >= 97 && code <= 122;
        if (!isDigit && !isLower) {
          Logger.warn('验证码识别结果含非法字符：' + cleaned);
          return '';
        }
      }
      return cleaned;
    } catch (error) {
      Logger.warn('验证码识别失败：' + (error as Error).message);
      return '';
    } finally {
      if (pixelMap !== null) {
        await pixelMap.release();
      }
      if (source !== null) {
        await source.release();
      }
    }
  }

  /** 识别 base64（`CaptchaInfo.base64Image` 去掉前缀后的部分）。 */
  static async recognizeBase64(base64: string): Promise<string> {
    if (base64.length === 0) {
      return '';
    }
    try {
      const helper = new util.Base64Helper();
      const bytes: Uint8Array = helper.decodeSync(base64);
      return await CaptchaRecognizer.recognizeImage(bytes);
    } catch (error) {
      Logger.warn('验证码 base64 解码失败：' + (error as Error).message);
      return '';
    }
  }
}
