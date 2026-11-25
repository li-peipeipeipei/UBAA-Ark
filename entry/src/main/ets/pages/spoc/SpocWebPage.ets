import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../../common/Logger';
import { AppColor, AppSize } from '../../components/AppTheme';
import { PullToRefresh } from '../../components/PullToRefresh';

/**
 * SPOC 网页提交的全屏 Web 二级页。
 *
 * ## 为什么是二级页（而不是浮层）
 * 之前这层是 MainPage 里覆盖全屏的浮层、自绘标题栏 + 组件 transition 假装右滑；
 * 现在是真正的 `HdsNavDestination`，由路由外壳的 `destTitleBar('网页提交')` 画
 * HDS 官方沉浸光感标题栏（含系统返回键），进出走 `AppRouter.push/back` 的
 * **系统导航右滑入 / 右滑出**（与扫一扫网页完全同一种动画，且带返回手势联动）。
 * 平板横屏的左侧导航栏避让由 MainPage 的 HdsTabs padding 统一处理，这里不重复留白。
 *
 * ## 加载流程
 * SPOC 网页提交走独立的 CAS 登录链（`LocalSpocService.webLoginUrl()` 生成带 token
 * 的登录地址），先加载登录页，首帧完成后再 `loadUrl` 到目标作业详情页。
 * 参数沿用 AppStorage 的 `spocWebLogin` / `spocWebDetail` 两个键（与原来浮层一致）。
 *
 * ## 布局：ArkUI 侧控制避让，不注入网页 DOM
 * 扫一扫页是普通网页，`html,body{padding-bottom}` 一条 CSS 就能把正文顶上去；
 * SPOC 是 uni-app hash SPA，正文在内部 div 里滚，且滚动容器由前端异步重建——
 * 三次 `runJavaScript` 注入（全量垫 / 按 overflow 挑 / 贴底锁定）真机均不稳定。
 * 这里改为纯布局：
 * - Web `layoutWeight(1)`，高度 = 外层高度 − 底部延伸块 → 网页视口本身止于底栏上沿，
 *   内容滚到底时最后一行完整可见，且不受网页 DOM 重建影响；
 * - 底下垫一块 `contentBottomInset` 高的空白 Column，与网页底色同色，
 *   底栏背后透出的就是这块延伸（而非 App 的实心底板）。
 * 两层加起来正好铺满外层（已 `expandSafeArea(BOTTOM)` 到屏幕最底）。
 */
@Component
export struct SpocWebPage {
  @StorageProp('spocWebLogin') private loginUrl: string = '';
  @StorageProp('spocWebDetail') private detailUrl: string = '';
  /** 系统深浅色（EntryAbility.onConfigurationUpdate 实时写入），用于网页反色与底部延伸块同步。 */
  @StorageProp('isDark') private isDark: boolean = false;
  /** 页签导航栈（由 RouteBuilder / FeatureDestBody 透传，保留以对齐二级页范本）。 */
  stack: NavPathStack = new NavPathStack();

  private controller: webview.WebviewController = new webview.WebviewController();
  private detailLoaded: boolean = false;

  /** 原页面内容。下拉刷新由外层 `build()` 的 PullToRefresh 提供。 */
  @Builder
  pageContent() {
    Column() {
      if (this.loginUrl.length > 0) {
        Web({ src: this.loginUrl, controller: this.controller })
          .width('100%')
          // 视口高度 = 外层高度 − 底部延伸块；网页自己的滚动区自然止于底栏上沿。
          // 不做 expandSafeArea(BOTTOM)，否则视口又铺到底栏背后，内容仍被盖住。
          .layoutWeight(1)
          // 网页深色模式跟随系统，未适配深色的超星页面由 forceDarkAccess 反色。
          // 背景色显式跟随系统，避免加载瞬间白闪，且与底部延伸块同色。
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
            // 登录页首帧加载完成后，跳到目标作业详情（只跳一次，避免重定向反复触发）。
            // hash 切换由 WebView 自行接管，不需要重新注入任何脚本。
            if (!this.detailLoaded && this.detailUrl.length > 0) {
              this.detailLoaded = true;
              this.controller.loadUrl(this.detailUrl);
            }
            Logger.info('SPOC 网页提交：页面加载完成 ' + (event ? event.url : ''));
          })
          .onErrorReceive((event: OnErrorReceiveEvent) => {
            if (event.error !== undefined) {
              Logger.warn('SPOC 网页提交：资源加载失败 ' + event.error.getErrorInfo());
            }
          })

        // 底栏背后的空白延伸：跟随系统深浅色，与反色后的网页底色一致。
        // ⚠️ 不能用 AppColor.pageBackground：它与网页反色后的底色不同源，会断带。
        // 高度：手机端比 contentBottomInset(104vp) 少 16vp → 上沿下移，可多露一行正文；
        // 侧栏形态（24vp，无悬浮底栏）保持原值，避免减完只剩 8vp。
        Column()
          .width('100%')
          .height(AppSize.contentBottomInset > 50 ? AppSize.contentBottomInset - 16 : AppSize.contentBottomInset)
          .backgroundColor(this.isDark ? Color.Black : Color.White)
      } else {
        Column({ space: 12 }) {
          Text('无法打开网页提交')
            .fontSize(18)
            .fontColor(AppColor.textPrimary)
          Text('请稍后重试')
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
        try {
          // 重刷当前地址：详情页不重新走 CAS 登录链，避免 token 被二次消费。
          this.controller.refresh();
        } catch (error) {
          Logger.warn('SPOC 网页提交：刷新失败 ' + (error as BusinessError).message);
        }
      },
      contentBuilder: () => {
        this.pageContent();
      }
    })
  }
}
