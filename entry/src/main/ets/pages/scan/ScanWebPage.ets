import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../../common/Logger';
import { TokenStore, StoredCookie } from '../../network/TokenStore';
import { ConnectionMode } from '../../common/AppConfig';
import { LocalWebVpn } from '../../network/LocalWebVpn';
import { KEY_SCAN_WEB_URL } from '../../common/AppRouter';
import { AppColor, AppSize } from '../../components/AppTheme';
import { PullToRefresh } from '../../components/PullToRefresh';

/**
 * 扫一扫打开的全屏网页。
 *
 * ## 自动登录
 * 学校二维码指向的是校内站点（教务、iHome、图书馆…），这些站点与 App 共用
 * 统一认证的会话 Cookie。App 自己的请求走 RCP，Cookie 存在 `TokenStore` 的
 * 按路线分槽的罐里；ArkWeb 有独立的 Cookie 存储，两者不互通。所以进页时把
 * 当前路线的 Cookie 逐条 `configCookieSync` 注入 ArkWeb —— 以 Cookie 自己的
 * domain 为归属，而不是扫码地址，这样跳转到同域的其它校内页面也能带上。
 *
 * ## 路线
 * 扫码地址是「逻辑地址」，WEBVPN 模式下必须先过 `LocalWebVpn.rewrite` 换成
 * 网关地址，否则校外直接打校内域名必然超时。Cookie 也取同一路线的罐。
 *
 * ## 布局（与 SPOC 网页提交页同一套，纯 ArkUI 侧控制）
 * 原先靠网页内 `html,body{padding-bottom}` 把正文顶上去 —— 普通网页有效，但
 * 与 SPOC 的写法不统一，且不同站点的 padding 解析不一致。现改为：
 * - Web `layoutWeight(1)`，视口高度 = 外层高度 − 底部延伸块，网页自身滚动区
 *   止于底栏上沿，内容滚到底时最后一行完整可见，不依赖任何网页 DOM / CSS 注入；
 * - 底下垫一块 `contentBottomInset − 16`（手机 88vp / 侧栏 24vp）的固定白色
 *   Column，底栏背后透出的是这块延伸，与网页白底连成一片；
 * - 外层 `expandSafeArea(BOTTOM)` 铺到屏幕最底，两层高度相加正好满屏。
 * 平板横屏的左侧导航栏避让由 MainPage 的 HdsTabs padding 统一处理，这里不重复留白。
 */
@Component
export struct ScanWebPage {
  @StorageProp(KEY_SCAN_WEB_URL) private rawUrl: string = '';
  /** 系统深浅色（EntryAbility.onConfigurationUpdate 实时写入），用于网页反色与底部延伸块同步。 */
  @StorageProp('isDark') private isDark: boolean = false;
  @State private loadUrl: string = '';
  @State private failed: boolean = false;

  private controller: webview.WebviewController = new webview.WebviewController();

  aboutToAppear(): void {
    this.prepare();
  }

  private async prepare(): Promise<void> {
    const target = this.rawUrl.trim();
    if (target.length === 0) {
      Logger.warn('扫一扫：没有拿到网页地址');
      this.failed = true;
      return;
    }
    const mode: ConnectionMode = TokenStore.getConnectionMode();
    // WEBVPN 模式下扫码拿到的是校内逻辑地址，必须换成网关地址；DIRECT 原样返回。
    let realUrl: string = target;
    try {
      realUrl = await LocalWebVpn.rewrite(target, mode);
    } catch (error) {
      Logger.warn('扫一扫：地址改写失败，使用原地址 ' + (error as Error).message);
    }
    this.injectCookies(mode);
    // Cookie 注入必须在 Web 组件首次加载页面之前完成 —— 先算好地址再挂载 Web。
    this.loadUrl = realUrl;
  }

  /**
   * 把当前路线的会话 Cookie 注入 ArkWeb。
   *
   * 关键两点（官方文档）：
   * 1. `configCookieSync` 每次只能设一条，value 必须是 Set-Cookie 格式；
   * 2. 归属用 Cookie 自己的 domain 构造的 URL，而不是扫码地址 —— 校内站点
   *    之间会互相 302（如 CAS 中转），按 domain 注入才能让整条链路都带上。
   */
  private injectCookies(mode: ConnectionMode): void {
    let jar: StoredCookie[] = [];
    try {
      jar = TokenStore.loadCookies(mode);
    } catch (error) {
      Logger.warn('扫一扫：读取会话 Cookie 失败 ' + (error as Error).message);
      return;
    }
    const now: number = Date.now();
    let injected: number = 0;
    for (let i = 0; i < jar.length; i++) {
      const cookie: StoredCookie = jar[i];
      if (cookie.name.length === 0) {
        continue;
      }
      // 已过期（expiresAt>0 且已过时刻）的条目不注入；会话 Cookie（0）放行。
      if (cookie.expiresAt > 0 && cookie.expiresAt <= now) {
        continue;
      }
      const domain: string = cookie.domain.replace(/^\./, '').toLowerCase();
      if (domain.length === 0) {
        continue;
      }
      const path: string = cookie.path.length > 0 && cookie.path.charAt(0) === '/' ? cookie.path : '/';
      const scheme: string = cookie.secure ? 'https://' : 'http://';
      let value: string = cookie.name + '=' + cookie.value + '; Path=' + path;
      // 显式 Domain（去掉前导点）：让同一主域下的跳转也带上；不带 domain 的
      // host-only Cookie 才只认注入 URL 的主机。
      if (cookie.domain.replace(/^\./, '').indexOf('.') > 0) {
        value += '; Domain=' + domain;
      }
      if (cookie.secure) {
        value += '; Secure';
      }
      if (cookie.expiresAt > 0) {
        value += '; Max-Age=' + Math.max(0, Math.floor((cookie.expiresAt - now) / 1000));
      }
      try {
        // 第 4 个参数 true：允许覆盖 HttpOnly 的会话 Cookie（统一认证的
        // JSESSIONID / CASTGC 常带 HttpOnly，不置 true 会被静默忽略）。
        webview.WebCookieManager.configCookieSync(scheme + domain + path, value, false, true);
        injected += 1;
      } catch (error) {
        // 单条失败不影响其它 Cookie（比如 domain 含非法字符）。
        Logger.warn('扫一扫：Cookie ' + cookie.name + ' 注入失败 ' + (error as BusinessError).message);
      }
    }
    Logger.info('扫一扫：已注入 ' + injected + ' 条会话 Cookie（路线 ' + mode + '）');
  }

  /** 原页面内容。下拉刷新由外层 `build()` 的 PullToRefresh 提供。 */
  @Builder
  pageContent() {
    Column() {
      if (this.loadUrl.length > 0 && !this.failed) {
        Web({
          src: this.loadUrl,
          controller: this.controller
        })
          .width('100%')
          // 视口高度 = 外层高度 − 底部延伸块；网页自身的滚动区自然止于底栏上沿。
          // 不做 expandSafeArea(BOTTOM)，否则视口又铺到底栏背后，内容仍被盖住。
          .layoutWeight(1)
          // 网页深色模式跟随系统；校内站点大多没适配深色，forceDarkAccess 用系统
          // 反色算法把高亮色转成低光色（官方 API9+，跟随 On/Auto 生效）。
          // 背景色也跟随系统：强制深色下 Web 默认背景会变黑，这里显式指定避免
          // 页面加载瞬间白底闪一下，且与底部延伸块同色。
          .darkMode(WebDarkMode.Auto)
          .forceDarkAccess(true)
          .backgroundColor(this.isDark ? Color.Black : Color.White)
          .domStorageAccess(true)
          .javaScriptAccess(true)
          .mixedMode(MixedMode.All)
          .metaViewport(true)
          .zoomAccess(false)
          // Web 嵌在 Refresh 里必须声明嵌套滚动（官方「Web组件嵌套滚动」）：
          // 网页内容优先滚，滚到顶部后再把下拉交给 Refresh。
          .nestedScroll({
            scrollUp: NestedScrollMode.PARENT_FIRST,
            scrollDown: NestedScrollMode.SELF_FIRST
          })
          .onPageEnd((event) => {
            Logger.info('扫一扫：网页加载完成 ' + (event ? event.url : ''));
          })
          .onErrorReceive((event: OnErrorReceiveEvent) => {
            if (event.error !== undefined) {
              Logger.warn('扫一扫：网页资源加载失败 ' + event.error.getErrorInfo());
            }
          })

        // 底栏背后的空白延伸：与网页底色同色，替代原来的网页内 CSS padding。
        // 跟随系统深浅色：深色时网页反色成黑底，这里同步变黑，底栏背后才不会
        // 露出一块白板（官方也建议深色下 Web 背景置黑，与网页保持一致）。
        // ⚠️ 不能用 AppColor.pageBackground：它与网页反色后的底色不同源，会断带。
        // 高度：手机端 contentBottomInset(104) − 16 = 88vp，与 SPOC 页一致；
        // 侧栏形态（24vp，无悬浮底栏）保持原值。
        Column()
          .width('100%')
          .height(AppSize.contentBottomInset > 50 ? AppSize.contentBottomInset - 16 : AppSize.contentBottomInset)
          .backgroundColor(this.isDark ? Color.Black : Color.White)
      } else if (this.failed) {
        Column({ space: 12 }) {
          Text('无法打开这个二维码')
            .fontSize(18)
            .fontColor(AppColor.textPrimary)
          Text('请确认扫描的是学校网站链接')
            .fontSize(14)
            .fontColor(AppColor.textSecondary)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    // 外层铺到屏幕最底（含悬浮底栏背后），给上面的「Web + 延伸块」提供总高度。
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    .clip(false)
    .backgroundColor(AppColor.pageBackground)
  }

  build() {
    PullToRefresh({
      onRefresh: async () => {
        if (this.loadUrl.length === 0 || this.failed) {
          // 首次地址改写失败时，下拉给一次重新注入 Cookie / 重算地址的机会。
          await this.prepare();
          return;
        }
        try {
          this.controller.refresh();
        } catch (error) {
          Logger.warn('扫一扫网页：刷新失败 ' + (error as BusinessError).message);
        }
      },
      contentBuilder: () => {
        this.pageContent();
      }
    })
  }
}
