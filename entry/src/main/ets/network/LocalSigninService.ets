import { AppConfig } from '../common/AppConfig';
import { DateUtil } from '../common/DateUtil';
import { Logger } from '../common/Logger';
import { ApiError } from './ApiError';
import { resolveLocation, UpstreamClient, UpstreamResponse } from './UpstreamClient';
import { SigninActionResult, SigninClass } from '../model/ApiTypes';

/**
 * 本地模式下的课堂签到（iclass「一体化课堂」，客户端直接对接校内上游）。
 *
 * ## 上游契约从哪来
 *
 * 全部照抄原 UBAA 服务端的 `signin/` 三个文件（每个方法都标注了出处）：
 *
 * | 本文件 | 原实现 |
 * | --- | --- |
 * | `walkForLoginName` / `extractLoginName` | `SigninLoginNameSupport.kt` |
 * | `performLogin` / `fetchTodayClasses` / `signIn` | `SigninClient.kt` |
 * | `friendlyMessage` | `SigninClient.sanitizeSignInMessage` |
 *
 * 因此返回给 UI 的对象与原 `/api/v1/signin/*` 完全同构，页面不需要知道
 * 服务端已经不在了。
 *
 * ## 为什么 iclass 要单独一套会话
 *
 * iclass 不属于 CAS 体系：它有自己的 `userId` + `sessionId`，登录后由服务端下发，
 * 之后所有请求靠请求头 `sessionId` 认人。所以即便 SSO 会话正常，也必须先
 * 「换成 iclass 的会话」才能查课、签到。
 *
 * ## 换取凭据是 loginName，不是学号
 *
 * iclass 的登录接口不吃学号，吃的是**登录名** `loginName`。它不在任何接口的
 * 返回值里，只能从门户跳转链上捡：
 *
 *   1. GET `https://iclass.buaa.edu.cn:8346/?type=jumpMyCenter`；
 *   2. 未登录时这条链会 302 到统一身份认证，认证过再 302 回来，而**回跳目标
 *      URL 的查询串里就带着 `loginName`**；
 *   3. 于是逐跳跟随，每跳都检查「实际请求地址」与「Location 头」里的
 *      `loginName`，取到即可。
 *
 * 拿到 loginName 之后 `password` 传空串就能登录 —— iclass 把「持有有效 SSO
 * 会话」直接当成了身份凭证，这也是原实现能免密登录的原因。换句话说：
 * **本功能的安全性完全依赖门外那道 CAS，iclass 侧没有任何额外凭据。**
 */

/* ============================== 上游地址 ============================== */

/**
 * iclass 门户（跳转链上会带回 loginName）。
 *
 * **端口是 8346**，与登录接口的 8347 不是一个 —— 这是上游自己的划分，
 * 别顺手「统一」掉（原 `SIGNIN_MY_CENTER_URL`）。
 */
const ICLASS_PORTAL_URL: string = 'https://iclass.buaa.edu.cn:8346/?type=jumpMyCenter';

/** iclass 登录入口（原 `SigninClient.login`）。 */
const ICLASS_LOGIN_URL: string = 'https://iclass.buaa.edu.cn:8347/app/user/login.action';

/** 课程排课 + 签到状态（原 `SigninClient.getClasses`）。 */
const ICLASS_COURSE_URL: string =
  'https://iclass.buaa.edu.cn:8347/app/course/get_stu_course_sched.action';

/**
 * 签到类接口的基址（原 `SigninClient.signinCheckinUrl` 的落点）。
 *
 * 实测 iclass 的 8347 端口在**直连与 WebVPN 两种模式下都能走 https**，且
 * `stu_scan_sign.action` / `get_timestamp.action` 在 8347 上均存在、路径统一
 * **不带 `eschool` 前缀**（带 eschool 前缀的路径在 8347 上是 404）。
 *
 * 原实现里「直连走 `http://8081/eschool/...`」是历史入口；要迁就它就得给整个
 * 应用开明文 HTTP 许可（HarmonyOS 默认拦截 http://），得不偿失 —— 这里统一
 * 走 8347 的 https，两种连接模式共用同一条入口。
 */
const ICLASS_API_BASE: string = 'https://iclass.buaa.edu.cn:8347/';

/**
 * 课堂签到**提交**入口（上游 2.0.3 `build_auto_signin_url` 裁决）。
 *
 * ⚠️ 这是 2026-11-19 抓包裁决后的唯一提交入口，三个要点不能「统一」掉：
 * - 端口是 **8181**，既不是列表的 8347、也不是二维码的 8081；
 * - **POST 不带查询串**，所有参数都在表单体里；
 * - 表单恰好六个字段，`routerInfo` / `longitude` / `latitude` / `machineInfo`
 *   是官方客户端的固定值，服务端只校验形状、不校验真实性。
 *
 * 旧的 `stu_scan_sign.action` 是**扫码签到**，它要的是「扫到的那张码」里的
 * 参数；拿它当自动签到的提交入口，上游必然回 `ERRMSG=!appMsg.qxktSign!`
 * （服务端 i18n 键「请先扫码」）。这正是 11-19 那次「签到永远失败」的根因 ——
 * 参数载体没有错，**接口选错了**。`stu_scan_sign` 现在只用于生成二维码内容
 * （见 `qrContent`），不再用于提交。
 */
const ICLASS_AUTO_SIGN_URL: string = 'https://iclass.buaa.edu.cn:8181/app/course/stu_auto_sign.action';

/**
 * 签到二维码的**内容前缀**（给 iClass App / 微信扫的那张码）。
 *
 * ⚠️ 这里用 `http` + 8081 + `eschool` 前缀，与上面两条都不一样，是上游按用途
 * 分开的入口，不是笔误：
 * - 8021/8081 的 `eschool/...` 是**学生端 H5** 的路径，二维码扫出来要落到那边；
 * - 这串只是**字符串内容**，本机不会去请求它，因此不受「HarmonyOS 默认拦截明文
 *   HTTP」的限制（见官方错误码 `2300997`）。真要本机请求才需要 network_config.json。
 *
 * 反过来说：**别因为「要开明文许可」就把二维码改到 8347** —— 扫出来对方打不开。
 */
const ICLASS_QR_SCAN_URL: string =
  'http://iclass.buaa.edu.cn:8081/eschool/app/course/stu_scan_sign.action';

/** 二维码时间戳允许的前后偏移上限（与上游 `get_qr` 校验一致）。 */
const QR_OFFSET_LIMIT_MS: number = 60000;

/** 统一身份认证入口（门户没带回 loginName 时显式换取一次）。 */
const CAS_LOGIN_URL: string = 'https://' + AppConfig.UPSTREAM_SSO_HOST + '/login';

/** 跳转链最大跳数（原 `SIGNIN_LOGIN_REDIRECT_LIMIT`）。 */
const SIGNIN_LOGIN_REDIRECT_LIMIT: number = 8;

/* ============================== 工具 ============================== */

function enc(value: string): string {
  return encodeURIComponent(value);
}

/** 把可能是字符串也可能是数字的上游字段统一成去空白的字符串。 */
function textOf(value: string | number | undefined): string {
  if (value === undefined || value === null) {
    return '';
  }
  if (typeof value === 'number') {
    return value.toString();
  }
  return (value as string).trim();
}

/** 百分号解码；串里有非法转义时原样返回（不为一个参数把整条跳转链打断）。 */
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

/* ============================== 响应契约 ============================== */

/** iclass 的通用信封：`STATUS` 为 "0" / "200" / "success" 表示成功。 */
interface IclassEnvelope<T> {
  STATUS?: string | number;
  /** 业务错误码（失败时和 `ERRMSG` 成对出现，只用于日志定位）。 */
  ERRCODE?: string | number;
  ERRMSG?: string;
  result?: T;
}

/** 登录返回的会话标识（原 `SigninClient.login` 取 `result.id` / `result.sessionId`）。 */
interface IclassLoginResult {
  id?: string | number;
  sessionId?: string;
}

/** 一堂课的排课与签到状态（原 `SigninClassDto`）。 */
interface IclassCourseRaw {
  id?: string | number;
  courseName?: string;
  classBeginTime?: string;
  classEndTime?: string;
  signStatus?: string | number;
}

/** 签到返回体（原实现只认 `result.stuSignStatus == "1"`）。 */
interface IclassSignResult {
  stuSignStatus?: string | number;
}

/**
 * 服务器时间戳。
 *
 * 注意它在响应**顶层**，不是 `result.timestamp` —— 原实现是
 * `client.get(...).body<JsonObject>().get("timestamp")`，直接取的顶层字段。
 */
interface IclassTimestamp {
  timestamp?: string | number;
}

/** 只用来偷看 STATUS / ERRMSG 的轻量结构（会话探活时用）。 */
interface IclassStatusProbe {
  STATUS?: string | number;
  ERRMSG?: string;
}

/* ============================== 服务 ============================== */

export class LocalSigninService {
  /** 本进程内是否已换到 iclass 会话。 */
  private static ready: boolean = false;
  private static userId: string = '';
  private static sessionId: string = '';

  /** 登出时清空进程内会话（见 LocalSpocService.reset 的说明）。 */
  static reset(): void {
    LocalSigninService.ready = false;
    LocalSigninService.userId = '';
    LocalSigninService.sessionId = '';
  }

  /* ------------------------------ 对外 ------------------------------ */

  /**
   * 今日可签到的课堂（含已签 / 未签状态）。
   *
   * @throws ApiError 会话换不到、上游故障或返回无法解析时抛出
   */
  static async fetchTodayClasses(): Promise<SigninClass[]> {
    await LocalSigninService.ensureLogin();
    const url = ICLASS_COURSE_URL +
      '?id=' + enc(LocalSigninService.userId) +
      '&dateStr=' + LocalSigninService.todayCompact();

    let response = await UpstreamClient.get(url, true, LocalSigninService.sessionHeaders());
    if (LocalSigninService.needsRelogin(response)) {
      Logger.warn('课堂签到会话已失效，重新换取后重试');
      await LocalSigninService.relogin();
      response = await UpstreamClient.get(url, true, LocalSigninService.sessionHeaders());
      if (LocalSigninService.needsRelogin(response)) {
        // 重登之后仍然失败：以前这里回退空列表，结果是「明明有课、界面说没有」，
        // 把会话故障伪装成「今天没课」，和签到失败撞在同一个坑里。
        // 现在明确报错，交给页面 ErrorView 给重试入口。
        Logger.warn('课堂列表仍未取到（HTTP ' + response.status + '）');
        throw new ApiError(502, 'signin_error',
          '签到课堂加载失败：课堂系统会话未建立，请返回设置页重新登录后重试');
      }
    }

    const envelope =
      LocalSigninService.parse<IclassCourseRaw[]>(response, '获取签到课堂失败');
    const list = envelope.result;
    if (list === undefined || list === null) {
      return [];
    }
    const classes = LocalSigninService.toClasses(list);
    Logger.info('今日签到课堂（' + LocalSigninService.todayCompact() + '）：' +
      classes.length + ' 堂');
    return classes;
  }

  /**
   * 对指定课程提交一次签到。
   *
   * 这是**不可撤销**的真实业务动作，只应由用户点击触发。
   *
   * @throws ApiError 会话换不到或上游故障时抛出
   */
  static async signIn(courseId: string): Promise<SigninActionResult> {
    await LocalSigninService.ensureLogin();

    /**
     * 提交走 `stu_auto_sign`，**不取时间戳**：这个接口按排课 id + 会话认课时段，
     * 时间戳是扫码签发那条链路的东西（`stu_scan_sign`），混进来只会多一跳请求
     * 和一个「取不到就签不了」的假依赖。
     */
    const body = LocalSigninService.autoSignForm(courseId);

    // ⚠️ 写请求**不跟随重定向**（与云打印那次修的同一类坑）：自动跟随会把 3xx 吞掉，
    // 最终落到登录页 HTML 上，调用方再也看不到「会话失效」这个事实。
    let response = await UpstreamClient.postForm(
      ICLASS_AUTO_SIGN_URL, body, false, LocalSigninService.sessionHeaders());
    if (LocalSigninService.signRetryWorthy(response)) {
      Logger.warn('课堂签到会话已失效，重新换取后重试');
      await LocalSigninService.relogin();
      response = await UpstreamClient.postForm(
        ICLASS_AUTO_SIGN_URL, body, false, LocalSigninService.sessionHeaders());
    }

    const envelope = LocalSigninService.parse<IclassSignResult>(response, '签到失败');
    const result = envelope.result;
    const signStatus = result === undefined ? '' : textOf(result.stuSignStatus);
    const statusOk = LocalSigninService.isStatusOk(envelope.STATUS);
    const success = statusOk && signStatus === '1';

    const raw = textOf(envelope.ERRMSG);
    const errCode = textOf(envelope.ERRCODE);
    if (!success) {
      Logger.warn('签到未成功：STATUS=' + textOf(envelope.STATUS) +
        ' ERRCODE=' + (errCode.length > 0 ? errCode : '-') +
        ' ERRMSG=' + (raw.length > 0 ? raw : '-') +
        ' stuSignStatus=' + (signStatus.length > 0 ? signStatus : '-'));
    }
    return {
      success: success,
      message: LocalSigninService.friendlyMessage(success, raw, errCode, statusOk, signStatus)
    };
  }

  /**
   * 生成课堂签到二维码的**内容字符串**（不提交任何请求）。
   *
   * 内容形如
   * `http://iclass.buaa.edu.cn:8081/eschool/app/course/stu_scan_sign.action?courseSchedId=X&timestamp=T`，
   * 由对方（iClass App / 微信）扫码后自己去访问 —— 所以本机**只需要真实的服务端
   * 时间戳**，不需要能连通 8081。
   *
   * 时间戳必须是上游的：用 `Date.now()` 拼出来的码会被对方判为过期/无效。
   *
   * @param offsetMs 在校验通过后额外加的毫秒偏移（0 ~ 60000）。
   *        实时展示用 0；「保存到相册」用 2000 —— 图片是静态的，留一点余量让对方
   *        扫码时还落在有效期内。
   */
  static async buildScanQrContent(courseId: string, offsetMs: number): Promise<string> {
    if (courseId.length === 0) {
      throw new ApiError(400, 'invalid_request', '缺少课程安排标识');
    }
    if (offsetMs < 0 || offsetMs > QR_OFFSET_LIMIT_MS) {
      throw new ApiError(400, 'invalid_request', '二维码时间偏移超出允许范围');
    }
    let timestamp = await LocalSigninService.fetchTimestamp();
    if (timestamp.length === 0) {
      // 与签到提交同款自愈：面板开着的几分钟里会话可能已被回收
      Logger.warn('取服务器时间失败，重新换取会话后重试');
      await LocalSigninService.relogin();
      timestamp = await LocalSigninService.fetchTimestamp();
    }
    if (timestamp.length === 0) {
      throw new ApiError(502, 'signin_error', '获取服务器时间失败，请稍后重试');
    }
    const base: number = Number.parseInt(timestamp, 10);
    if (Number.isNaN(base) || base <= 0) {
      throw new ApiError(502, 'signin_error', '服务器返回的时间戳格式异常');
    }
    return ICLASS_QR_SCAN_URL + '?courseSchedId=' + enc(courseId) +
      '&timestamp=' + (base + offsetMs).toString();
  }

  /* ---------------------------- 会话准备 ---------------------------- */

  /** 确保 iclass 会话可用：先解析登录名，再用登录名换会话。 */
  private static async ensureLogin(): Promise<void> {
    if (LocalSigninService.ready) {
      return;
    }
    let loginName = await LocalSigninService.walkForLoginName(ICLASS_PORTAL_URL);
    if (loginName.length === 0) {
      // 兜底：CAS 过滤器没返回 302 而是直接吐了登录页时，显式带 service 再换一次
      Logger.warn('门户跳转链未带回 loginName，显式走一次统一认证换取');
      loginName = await LocalSigninService.walkForLoginName(
        CAS_LOGIN_URL + '?service=' + enc(ICLASS_PORTAL_URL));
    }
    if (loginName.length === 0) {
      throw new ApiError(401, 'upstream_session_expired',
        '课堂签到会话未建立：未能取到课堂系统登录名，请返回设置页重新登录后重试');
    }
    await LocalSigninService.performLogin(loginName);
    LocalSigninService.ready = true;
  }

  private static async relogin(): Promise<void> {
    LocalSigninService.ready = false;
    LocalSigninService.userId = '';
    LocalSigninService.sessionId = '';
    await LocalSigninService.ensureLogin();
  }

  /** 用 loginName 换 iclass 会话（原 `SigninClient.login`，`password` 传空串）。 */
  private static async performLogin(loginName: string): Promise<void> {
    const url = ICLASS_LOGIN_URL +
      '?password=&phone=' + enc(loginName) +
      '&userLevel=1&verificationType=2&verificationUrl=';
    const response = await UpstreamClient.get(url, true);
    const envelope =
      LocalSigninService.parse<IclassLoginResult>(response, '课堂系统登录失败');

    if (!LocalSigninService.isStatusOk(envelope.STATUS)) {
      const message = textOf(envelope.ERRMSG);
      throw new ApiError(401, 'upstream_session_expired',
        '课堂系统登录失败：' + (message.length > 0 ? message : '上游未返回会话'));
    }
    const result = envelope.result;
    const userId = result === undefined ? '' : textOf(result.id);
    const sessionId = result === undefined ? '' : textOf(result.sessionId);
    if (userId.length === 0 || sessionId.length === 0) {
      throw new ApiError(502, 'signin_error', '课堂系统登录失败：上游未返回会话标识');
    }
    LocalSigninService.userId = userId;
    LocalSigninService.sessionId = sessionId;
    Logger.info('课堂签到会话就绪（userId=' + userId + '）');
  }

  /**
   * 逐跳跟随跳转链，从每一跳的「实际请求地址」与「Location 头」里找 loginName。
   *
   * 为什么不直接用 `UpstreamClient.follow`：它只返回最后一跳，而 loginName
   * 恰恰可能落在**中间某一跳**上（回跳那一刻带上，之后又被重定向掉）。
   *
   * WebVPN 模式下每一跳的实际地址是网关地址（`d.buaa.edu.cn/https-8346/...`），
   * 但查询串是原样透传的，所以照样能取到。
   */
  private static async walkForLoginName(startUrl: string): Promise<string> {
    let current = startUrl;
    for (let hop = 0; hop < SIGNIN_LOGIN_REDIRECT_LIMIT; hop++) {
      const fromCurrent = LocalSigninService.extractLoginName(current);
      if (fromCurrent.length > 0) {
        return fromCurrent;
      }
      const response = await UpstreamClient.get(current, false);
      const fromUrl = LocalSigninService.extractLoginName(response.url);
      if (fromUrl.length > 0) {
        return fromUrl;
      }
      if (response.location.length > 0) {
        const fromLocation = LocalSigninService.extractLoginName(response.location);
        if (fromLocation.length > 0) {
          return fromLocation;
        }
      }
      if (!response.isRedirect()) {
        return '';
      }
      current = resolveLocation(response.url, response.location);
    }
    return '';
  }

  /**
   * 从 URL 的查询串里取 `loginName`（原 `extractSigninLoginNameFromUrl`）。
   *
   * 先截到 `#` 之前，避免把前端的哈希路由当成查询参数。
   */
  private static extractLoginName(url: string): string {
    const queryIndex = url.indexOf('?');
    if (queryIndex < 0) {
      return '';
    }
    let query = url.substring(queryIndex + 1);
    const hashIndex = query.indexOf('#');
    if (hashIndex >= 0) {
      query = query.substring(0, hashIndex);
    }
    const parts = query.split('&');
    for (let i = 0; i < parts.length; i++) {
      const part = parts[i];
      const eq = part.indexOf('=');
      const key = eq >= 0 ? part.substring(0, eq) : part;
      if (key.toLowerCase() !== 'loginname') {
        continue;
      }
      const value = eq >= 0 ? part.substring(eq + 1) : '';
      if (value.length === 0) {
        continue;
      }
      return percentDecode(value);
    }
    return '';
  }

  /**
   * 取服务器时间戳（毫秒 epoch）。
   *
   * **提交签到已经不需要它了**（`stu_auto_sign` 按排课 id 认时段）。这个入口保留给
   * 签到二维码：二维码内容 = `stu_scan_sign` 地址 + `courseSchedId` + 服务器时间戳，
   * 时间戳必须是**服务端**的，用本机时间拼出来的码对方扫不开 —— 这也是它不能用
   * `Date.now()` 兜底的原因。
   *
   * 拿不到时返回空串而**不抛错** —— 调用方要用它区分「换个会话还能救」与
   * 「真的取不到」，把判据留在调用处更好读。
   */
  private static async fetchTimestamp(): Promise<string> {
    const url = LocalSigninService.checkinUrl('app/common/get_timestamp.action');
    // 原实现对这一个接口没有加 sessionId 头，照抄
    const response = await UpstreamClient.get(url, true);
    if (!response.isOk()) {
      return '';
    }
    const trimmed = response.body.trimStart();
    if (!trimmed.startsWith('{')) {
      return '';
    }
    try {
      const parsed = JSON.parse(trimmed) as IclassTimestamp;
      const value = parsed.timestamp;
      if (value === undefined || value === null) {
        return '';
      }
      return textOf(value);
    } catch (error) {
      return '';
    }
  }

  /* ------------------------------ 内部 ------------------------------ */

  /**
   * `stu_auto_sign` 的表单体，**恰好六个字段**。
   *
   * `routerInfo`（MAC 样式串）、`longitude` / `latitude`（经纬度）、`machineInfo`
   * 都是官方客户端上报的固定占位值：上游只校验「字段在、形状对」，不校验真实性
   * —— 学校没有接入基站/WiFi 定位核验，签到是否成立由教师开窗决定。2.0.3 的契约
   * 测试把这六个字段钉死成契约（`stu_auto_sign表单包含六个固定字段`），少一个
   * 或多一个都会让上游进入不同的失败分支。
   */
  private static autoSignForm(courseId: string): string {
    return 'id=' + enc(LocalSigninService.userId) +
      '&courseSchedId=' + enc(courseId) +
      '&routerInfo=' + enc('02:00:00:00:00:00') +
      '&longitude=0' +
      '&latitude=0' +
      '&machineInfo=Android';
  }

  /**
   * 组装 iclass **读接口**的实际地址（课程列表、时间戳）。
   *
   * 两种连接模式统一走 8347 的 https、路径不带 `eschool` 前缀（见 ICLASS_API_BASE
   * 注释），故这里只收一个路径参数。
   *
   * ⚠️ **提交不走这里** —— 提交是 8181 的 `stu_auto_sign`，见 `ICLASS_AUTO_SIGN_URL`。
   * 别把两者合并成「统一基址」，端口是上游按接口划分的，不是笔误。
   */
  private static checkinUrl(path: string): string {
    return ICLASS_API_BASE + path;
  }

  /** iclass 用请求头 `sessionId` 认人（原实现唯一必带的业务头）。 */
  private static sessionHeaders(): Record<string, string> {
    const headers: Record<string, string> = {};
    headers['sessionid'] = LocalSigninService.sessionId;
    return headers;
  }

  /**
   * HTTP / HTML 层的会话失效：3xx、非 2xx、或停在门户登录页。
   *
   * iclass 对失效的会话**不跳转、也不回 401**，通常照常 200 返回 JSON、只把
   * `STATUS` 置成失败 —— 所以 STATUS 层的判断单独放在调用方（不同接口的
   * 宽严尺度不一样，见 `needsRelogin` 与 `signRetryWorthy`）。
   */
  private static transportDead(response: UpstreamResponse): boolean {
    if (response.isRedirect() || !response.isOk()) {
      return true;
    }
    return !response.body.trimStart().startsWith('{');
  }

  /**
   * 课程列表的会话判定：STATUS 失败也重换一次（与原 `getClasses` 一致）。
   *
   * 极少数接口（`get_timestamp`）不带 STATUS 字段，那种视为正常；
   * **`STATUS` 为 `2` 是「今天没有课」的合法空结果**（2.x `empty_result`），
   * 不能当成会话失效 —— 否则没课的那天每次进页面都白跑一轮 SSO 跳转链。
   */
  private static needsRelogin(response: UpstreamResponse): boolean {
    if (LocalSigninService.transportDead(response)) {
      return true;
    }
    try {
      const probe = JSON.parse(response.body.trimStart()) as IclassStatusProbe;
      const status = probe.STATUS;
      if (status === undefined) {
        return false;
      }
      if (LocalSigninService.isEmptyStatus(status)) {
        return false;
      }
      return !LocalSigninService.isStatusOk(status);
    } catch (error) {
      return true;
    }
  }

  /**
   * 签到响应是否值得「重换会话再试一次」。
   *
   * 与课程列表不同：签到的 STATUS 失败绝大多数是**业务原因**（不是上课时间、
   * 签到未开始、不在范围），重换会话救不了，反而白跑一遍 SSO 跳转链（真机
   * 实测 `当前时间不是上课时间！` 触发过一整轮重试，多花约 1.5 秒）。原实现
   * 对签到也只信 `ERRMSG` 里的「登录」字样 —— 只有它才说明会话真没了。
   */
  private static signRetryWorthy(response: UpstreamResponse): boolean {
    if (LocalSigninService.transportDead(response)) {
      return true;
    }
    try {
      const probe = JSON.parse(response.body.trimStart()) as IclassStatusProbe;
      if (LocalSigninService.isStatusOk(probe.STATUS)) {
        return false;
      }
      const message = probe.ERRMSG === undefined ? '' : textOf(probe.ERRMSG);
      return message.indexOf('登录') >= 0;
    } catch (error) {
      return true;
    }
  }

  /** `STATUS` 是否表示成功（原 `isStatusSuccess`）。 */
  private static isStatusOk(status: string | number | undefined): boolean {
    const value = textOf(status);
    return value === '0' || value === '200' || value === 'success';
  }

  /**
   * `STATUS` 是否表示「今天没有课」（2.x `empty_result` 的口径：字符串或数字 2）。
   *
   * 这是**合法空结果**，不是会话失效 —— 混为一谈会在没课的日子每进一次页面
   * 就白跑一轮 SSO 跳转链。
   */
  private static isEmptyStatus(status: string | number | undefined): boolean {
    return textOf(status) === '2';
  }

  /**
   * 剥出上游未本地化的 i18n 占位（形如 `!appMsg.qxktSign!`）里的键名。
   *
   * 真机实测：参数不全时上游直接吐这个键，中文资源没打包进去。不剥掉的话
   * 它会原样飘到用户眼前，也没法参与下面的关键字映射。
   */
  private static i18nKey(raw: string): string {
    if (raw.length < 3 || !raw.startsWith('!') || !raw.endsWith('!')) {
      return '';
    }
    return raw.substring(1, raw.length - 1);
  }

  /** 解析 iclass 信封；HTTP 层或 JSON 层出问题时抛出可读错误。 */
  private static parse<T>(response: UpstreamResponse, what: string): IclassEnvelope<T> {
    if (response.isRedirect()) {
      throw new ApiError(401, 'upstream_session_expired',
        what + '：课堂系统会话已失效，请重新登录');
    }
    if (!response.isOk()) {
      if (response.body.indexOf('<html') >= 0 || response.body.indexOf('<!DOCTYPE') >= 0) {
        throw ApiError.fromHtmlResponse(response.status, response.body,
          AppConfig.hostOf(response.url));
      }
      throw new ApiError(response.status, 'upstream_down',
        what + '：上游返回 HTTP ' + response.status);
    }
    const trimmed = response.body.trimStart();
    if (!trimmed.startsWith('{')) {
      throw new ApiError(502, 'upstream_down', what + '：上游返回的是网页而不是数据');
    }
    try {
      return JSON.parse(trimmed) as IclassEnvelope<T>;
    } catch (error) {
      throw new ApiError(502, 'upstream_down', what + '：上游返回的数据无法解析');
    }
  }

  /** 上游数组 → UI 契约（与 `SigninClassDto` 逐字段对应）。 */
  private static toClasses(list: IclassCourseRaw[]): SigninClass[] {
    const out: SigninClass[] = [];
    for (let i = 0; i < list.length; i++) {
      const item = list[i];
      if (item === undefined || item === null) {
        continue;
      }
      const courseId = textOf(item.id);
      const courseName = textOf(item.courseName);
      // 没有课程 id 就无法发起签到，直接丢掉比留一个点了没反应的按钮好
      if (courseId.length === 0 || courseName.length === 0) {
        continue;
      }
      const status = parseInt(textOf(item.signStatus), 10);
      out.push({
        courseId: courseId,
        courseName: courseName,
        classBeginTime: textOf(item.classBeginTime),
        classEndTime: textOf(item.classEndTime),
        signStatus: isNaN(status) ? 0 : status
      });
    }
    return out;
  }

  /** 上游要的日期格式是 `yyyyMMdd`（原 `DateTimeFormatter.ofPattern("yyyyMMdd")`）。 */
  private static todayCompact(): string {
    return DateUtil.today().split('-').join('');
  }

  /**
   * 把上游的原始报错翻成人话（原 `sanitizeSignInMessage`，本轮按真机实测扩充）。
   *
   * 上游的 ERRMSG 是写给运维看的（「用户不存在」「不在范围」），直接甩到界面上
   * 既含糊又吓人，这里逐条映射。判断顺序与原实现保持一致。
   *
   * 🔴 最后**不再无条件吞成「签到失败，请稍后重试」**：以前任何未命中关键字的
   * 原因都会塌成这一句，用户和开发者都拿不到线索（课堂签到长期「签到失败」的
   * 直接观感就是这么来的）。现在未命中的原始文案原样带出，至少能看出是哪一步。
   */
  private static friendlyMessage(
    success: boolean,
    rawMessage: string,
    errCode: string,
    statusOk: boolean,
    signStatus: string
  ): string {
    if (success) {
      return rawMessage.length > 0 && LocalSigninService.i18nKey(rawMessage).length === 0
        ? rawMessage : '签到成功';
    }
    // STATUS 成功、但没拿到 `stuSignStatus`：上游没给出结论，属于「请求已到、
    // 结果不明」的中间态。不能让用户以为没签上而反复点（写操作无法撤销）。
    if (statusOk && signStatus.length === 0) {
      return '签到结果未知，请刷新确认状态后再决定是否重试';
    }
    // `ERRCODE=101` + 「签到失败！」：真机实测（2026-11-19 13:05 点 14:00 的课）——
    // 参数与用户都已被上游接受，是**业务层拒绝**：教师还没开窗，或本课走扫码签到。
    // 上游不给细节，这里只能把已知的两种可能都说出来，别再让用户对着「签到失败」猜。
    if (errCode === '101') {
      return '课堂系统拒绝了本次签到：教师可能还没开启签到窗口，或本课需要扫码签到';
    }
    if (rawMessage.indexOf('已签到') >= 0) {
      return '您今天已经签到过了';
    }
    if (rawMessage.indexOf('未开始') >= 0) {
      return '当前还未到签到时间';
    }
    if (rawMessage.indexOf('不是上课时间') >= 0) {
      return '当前不是上课时间，无法签到';
    }
    if (rawMessage.indexOf('已结束') >= 0) {
      return '本次签到已结束';
    }
    if (rawMessage.indexOf('范围') >= 0) {
      return '当前不在可签到范围内';
    }
    if (rawMessage.indexOf('用户不存在') >= 0) {
      return '签到账号不存在，请联系管理员';
    }
    if (rawMessage.indexOf('课程') >= 0 && rawMessage.indexOf('不存在') >= 0) {
      return '未找到对应课程，请刷新后重试';
    }
    // 会话过期在上游是「未登录」/「登录已失效」这类字样，原实现完全没映射，
    // 于是被吞成通用文案 —— 用户不知道重登就能解决。
    if (rawMessage.indexOf('登录') >= 0) {
      return '课堂系统登录状态已失效，请返回设置页重新登录后重试';
    }
    const key = LocalSigninService.i18nKey(rawMessage);
    if (key.length > 0) {
      // `qxktSign`：实测「缺 courseSchedId」时返回，即上游找不到这堂课的签到任务
      if (key.indexOf('qxktSign') >= 0) {
        return '课堂系统没有该课程的签到任务（教师可能未开启签到，或本课不支持一键签到）';
      }
      return '签到未成功（课堂系统错误码 ' + key + '）';
    }
    if (rawMessage.length > 0) {
      return '签到未成功：' + rawMessage;
    }
    return '签到失败，请稍后重试';
  }
}
