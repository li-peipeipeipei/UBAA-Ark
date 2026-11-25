import { AppRouter, RouteName } from '../../common/AppRouter';
import { AppConfig, ConnectionMode, RoutePolicy, connectionModeName } from '../../common/AppConfig';
import { Logger } from '../../common/Logger';
import { StartupPrefetch } from '../../common/StartupPrefetch';
import { Toast } from '../../common/Toast';
import { ApiService } from '../../network/ApiService';
import { LocalPortalService } from '../../network/LocalPortalService';
import { TokenStore } from '../../network/TokenStore';
import { IconScheme, IconStore, KEY_APP_ICON_SCHEME } from '../../common/IconStore';
import { PortalMetric, PortalMetrics } from '../../model/ApiTypes';
import { AppColor, AppFont, AppSize } from '../../components/AppTheme';
import { topSafeInsetVp } from '../../common/ImmersiveUtil';
import { SectionCard } from '../../components/CommonViews';
import { isTwoPane, KEY_BREAKPOINT } from '../../common/Breakpoint';
import { PageCache } from '../../common/PageCache';
import { OfflineKey } from '../../common/OfflineCache';
import { PullToRefresh } from '../../components/PullToRefresh';

/**
 * 「我的」页。
 *
 * 上半部分为身份卡片（品牌渐变 + 沉浸底色），下半部分为功能列表。
 */
@Component
export struct MinePage {
  stack: NavPathStack = new NavPathStack();

  @State private userName: string = '';
  @State private schoolId: string = '';
  @State private loggingOut: boolean = false;
  /**
   * 二级页转场窗口内为 true：把顶部蓝卡隐去，避免缩放淡入时露出「蓝色一条」。
   * 由 `openRoute` 置位，约一屏转场时长后自动复位。
   */
  @State private pushVeil: boolean = false;
  /** 隐蓝卡的定时器（重复调用先清旧的，销毁时清掉，见 openRoute）。 */
  private pushVeilTimer: number = -1;
  /** 校园账户五项指标（单项失败不影响其它项，见 `LocalPortalService.fetchMetrics`）。 */
  @State private metrics: PortalMetrics | null = null;
  @State private metricsLoading: boolean = false;
  @State private metricsError: string = '';
  /**
   * 当前宽度断点：决定「我的」页是否走两栏（lg / xxl）。
   *
   * 手机（sm）与平板竖屏（md）保持单列 —— 平板竖屏按官方「大屏竖屏」规范
   * 仍用底部页签，673vp 平分两栏后每栏只有 316vp，菜单副标题会被切掉。
   */
  @StorageProp(KEY_BREAKPOINT) private bp: string = 'sm';
  /**
   * 当前图标方案：入口副标题与前置图标由它决定。
   *
   * 必须 @StorageProp(@Watch) + @State 两段式，不能只用 @StorageLink：
   * 「我的」页是 Navigation 的 home 内容，二级页覆盖期间 AppStorage 的值虽然变了，
   * 但恢复可见时 home 页不会因 @StorageLink 自身变化而重绘（实测：切换返回仍是旧
   * 图标，冷启动重建组件才更新）。@Watch 回调里把值转赋给 @State 才会真正标脏重绘。
   * 与签到刷新（SigninEvents / KEY_SIGNIN_VERSION）用的是同一套跨页模式。
   */
  @StorageProp(KEY_APP_ICON_SCHEME) @Watch('onIconSchemeChanged')
  private iconSchemeProp: string = IconScheme.DEFAULT;
  @State private currentIcon: string = IconScheme.DEFAULT;

  private onIconSchemeChanged(): void {
    this.currentIcon = this.iconSchemeProp;
  }

  onLogout: () => void = () => {};

  aboutToAppear(): void {
    // 兜底：组件创建时 @StorageProp 已经带上了最新值，@Watch 不会为初始值触发回调，
    // 所以首帧这里显式同步一次，保证前置图标/副标题从创建起就是当前方案。
    this.currentIcon = this.iconSchemeProp;
    const session = TokenStore.getSession();
    this.userName = session.userName.length > 0 ? session.userName : '未设置姓名';
    this.schoolId = session.schoolId.length > 0 ? session.schoolId : session.username;
    // 冷启动首帧：优先读磁盘缓存（跨进程保留上次结果），再读内存预取缓存。
    // 两者都取不到才保持 null 走网络。这样冷启动进来就是上次真实的余额，
    // 而非先闪「正在读取…」再跳数字。
    const diskCached: PortalMetrics | null =
      PageCache.load<PortalMetrics>(OfflineKey.MINE_METRICS, PageCache.TTL_HALF_DAY);
    const cached: PortalMetrics | null = diskCached !== null ?
      diskCached : LocalPortalService.cachedMetrics();
    if (cached !== null) {
      this.metrics = cached;
    }
    // 五项指标是异步拉的：不阻塞本页首帧，失败也不影响其它内容
    this.loadMetrics();
  }

  private async loadMetrics(force: boolean = false): Promise<void> {
    if (this.metricsLoading) {
      return;
    }
    this.metricsLoading = true;
    this.metricsError = '';
    try {
      const data: PortalMetrics = await LocalPortalService.fetchMetrics(force);
      this.metrics = data;
      PageCache.save(OfflineKey.MINE_METRICS, data);
      Logger.info('门户指标已加载');
    } catch (error) {
      const apiError = error as Error;
      this.metricsError = apiError.message;
      Logger.warn('门户指标加载失败：' + apiError.message);
    } finally {
      this.metricsLoading = false;
    }
  }

  /** 当前已取到的指标（按固定展示顺序）。 */
  private metricList(): PortalMetric[] {
    const m = this.metrics;
    if (m === null) {
      return [];
    }
    const out: PortalMetric[] = [];
    if (m.netFee !== null) {
      out.push(m.netFee);
    }
    if (m.cardBalance !== null) {
      out.push(m.cardBalance);
    }
    if (m.unreadMail !== null) {
      out.push(m.unreadMail);
    }
    if (m.borrowedBooks !== null) {
      out.push(m.borrowedBooks);
    }
    if (m.wangpan !== null) {
      out.push(m.wangpan);
    }
    return out;
  }

  /** 取失败（ok=false）的项数。单项失败本身不算整卡错误，但要让用户能重试。 */
  private failedCount(): number {
    const list: PortalMetric[] = this.metricList();
    let count: number = 0;
    for (let i = 0; i < list.length; i++) {
      if (!list[i].ok) {
        count++;
      }
    }
    return count;
  }

  /** 单项指标格子。`ok=false` 时显示占位符，不打断整卡。 */
  @Builder
  metricCell(m: PortalMetric) {
    Column({ space: 3 }) {
      Text(m.label)
        .fontSize(AppFont.caption)
        .fontColor(AppColor.textSecondary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Text(m.ok ? (m.value + (m.unit.length > 0 ? ' ' + m.unit : '')) : '—')
        .fontSize(AppFont.subtitle)
        .fontWeight(FontWeight.Medium)
        .fontColor(m.ok ? AppColor.textPrimary : AppColor.textTertiary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
    .width('100%')
    .padding({ top: 10, bottom: 10, left: 12, right: 12 })
    .borderRadius(12)
    .backgroundColor(AppColor.surfaceSubtle)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  metricsCard() {
    SectionCard({
      title: '校园账户',
      subtitle: this.metrics === null ?
        (this.metricsLoading ? '正在读取…' : '余额与待办概览') :
        '更新于 ' + new Date(this.metrics.fetchedAt).toTimeString().substring(0, 5),
      showAction: false
    }) {
      Column({ space: 10 }) {
        if (this.metrics === null && this.metricsError.length > 0) {
          Text(this.metricsError)
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textTertiary)
            .width('100%')
          Text('点此重试')
            .fontSize(AppFont.caption)
            .fontColor(AppColor.brand)
            .width('100%')
            .onClick(() => {
              // force：绕过 2 分钟的指标缓存，用户点「重试」必须真的重取
              this.loadMetrics(true);
            })
        } else if (this.metricList().length === 0) {
          Text(this.metricsLoading ? '正在读取…' : '暂无可展示的指标')
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textTertiary)
            .width('100%')
        } else {
          Grid() {
            ForEach(this.metricList(), (m: PortalMetric) => {
              GridItem() {
                this.metricCell(m)
              }
            }, (m: PortalMetric) => 'metric-' + m.label)
          }
          .columnsTemplate('1fr 1fr')
          .columnsGap(10)
          .rowsGap(10)
          .width('100%')

          if (this.metricsError.length > 0 || this.failedCount() > 0) {
            // 部分项失败时在底部提示，不打断已成功的项
            Row({ space: 4 }) {
              Text(this.failedCount() > 0 ? this.failedCount().toString() + ' 项暂时不可用' :
                '部分指标暂时不可用')
                .fontSize(AppFont.caption)
                .fontColor(AppColor.textTertiary)
              Text('点此重试')
                .fontSize(AppFont.caption)
                .fontColor(AppColor.brand)
                .onClick(() => {
                  this.loadMetrics(true);
                })
            }
            .width('100%')
          }
        }
      }
      .width('100%')
    }
  }

  @Builder
  profileCard() {
    Row({ space: AppSize.gapLarge }) {
      Column() {
        Text(this.userName.substring(0, 1))
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
      }
      .width(56)
      .height(56)
      .borderRadius(28)
      .backgroundColor('#33000000')
      .justifyContent(FlexAlign.Center)

      Column({ space: 4 }) {
        Text(this.userName)
          .fontSize(AppFont.title)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('学号 ' + this.schoolId)
          .fontSize(AppFont.caption)
          .fontColor('#D9ECFF')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(AppSize.cardPadding)
    .borderRadius(AppSize.cardRadiusLarge)
    .linearGradient({
      angle: 135,
      colors: [
        [AppColor.brand, 0.0],
        [AppColor.brandDark, 1.0]
      ]
    })
    // 二级页转场期间隐去（见 `openRoute`）：HDS 的页面转场是「新页面缩放淡入、
    // 下层不动」，缩放时四周会露出约 7.5vp 的下层内容 —— 这张蓝卡的顶部就是
    // 用户看到的「蓝色一条」，藏掉后露出的是本页底色，与新页面同色看不出来。
    .opacity(this.pushVeil ? 0 : 1)
  }

  /**
   * 连接设置一行的摘要。
   *
   * 自动策略下写「自动 · 当前 <实际路线>」—— 只写「自动」用户不知道现在走的哪条，
   * 真出了问题无从判断。
   */
  private connectionSummary(): string {
    const policy: RoutePolicy = TokenStore.getRoutePolicy();
    if (policy !== RoutePolicy.AUTO) {
      return '当前：' + connectionModeName(TokenStore.getConnectionMode());
    }
    return '自动 · 当前' + connectionModeName(TokenStore.getConnectionMode());
  }

  @Builder
  menuRow(title: string, subtitle: string, symbol: Resource, onClick: () => void) {
    Row({ space: AppSize.gap }) {
      Column() {
        SymbolGlyph(symbol)
          .fontSize(20)
          .fontColor([Color.White])
      }
      .width(34)
      .height(34)
      .borderRadius(10)
      .backgroundColor(AppColor.brand)
      .justifyContent(FlexAlign.Center)

      Column({ space: 2 }) {
        Text(title)
          .fontSize(AppFont.body)
          .fontColor(AppColor.textPrimary)
        Text(subtitle)
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textTertiary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([AppColor.textTertiary])
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .onClick(() => {
      onClick();
    })
  }

  /**
   * 菜单行（图标来自 `app.media` 的自绘 SVG 版本）。
   *
   * 和 `menuRow` 的差别只在图标节点：`SymbolGlyph` 只能吃系统符号，
   * 自绘图标必须用 `Image` + `fillColor` 才能染成白色。
   */
  @Builder
  menuRowImage(title: string, subtitle: string, icon: Resource, onClick: () => void) {
    Row({ space: AppSize.gap }) {
      Column() {
        Image(icon)
          .width(20)
          .height(20)
          .objectFit(ImageFit.Contain)
          .fillColor(Color.White)
      }
      .width(34)
      .height(34)
      .borderRadius(10)
      .backgroundColor(AppColor.brand)
      .justifyContent(FlexAlign.Center)

      Column({ space: 2 }) {
        Text(title)
          .fontSize(AppFont.body)
          .fontColor(AppColor.textPrimary)
        Text(subtitle)
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textTertiary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([AppColor.textTertiary])
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .onClick(() => {
      onClick();
    })
  }

  /**
   * 菜单行（前置图标是当前生效的应用图标，与桌面图标一一对应）。
   * 用于「切换图标」入口 —— 让用户一眼看到现在用的是哪套图标。
   */
  @Builder
  menuRowIconPreview(title: string, subtitle: string, icon: Resource, onClick: () => void) {
    Row({ space: AppSize.gap }) {
      Column() {
        Image(icon)
          .width(34)
          .height(34)
          .borderRadius(9)
          .objectFit(ImageFit.Cover)
          .draggable(false)
      }
      .width(34)
      .height(34)

      Column({ space: 2 }) {
        Text(title)
          .fontSize(AppFont.body)
          .fontColor(AppColor.textPrimary)
        Text(subtitle)
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textTertiary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([AppColor.textTertiary])
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .onClick(() => {
      onClick();
    })
  }

  private async doLogout(): Promise<void> {
    if (this.loggingOut) {
      return;
    }
    this.loggingOut = true;
    try {
      await ApiService.logout();
      // 登出后允许下次登录重新预热（预取状态是进程级的，不清就会一直不跑）
      StartupPrefetch.reset();
      Toast.show('已退出登录');
      this.clearLocalData();
      this.onLogout();
    } catch (error) {
      Logger.warn('注销异常：' + (error as Error).message);
      StartupPrefetch.reset();
      this.clearLocalData();
      this.onLogout();
    } finally {
      this.loggingOut = false;
    }
  }

  /**
   * 退出登录时**不再清课表缓存**。
   *
   * 缓存里已经记了它属于哪个账号（学号 + 登录名）。同一个账号重新登录时直接复用，
   * 打开课表零等待；换成别的账号登录，SchedulePage.restoreFromCache 会发现账号
   * 对不上并整体清空，隐私同样有保障 —— 不需要在退出时“宁可错杀”。
   */
  private clearLocalData(): void {
  }

  /**
   * 打开二级页。未分栏且外层能分栏时，先切 Split、下一帧再 push，
   * 让详情以 push 动画从右侧滑入（而不是模式切换动画里的自左向右展开）。
   */
  private openRoute(route: string): void {
    // 转场窗口内隐去顶部蓝卡：HDS 的二级页转场是「新页面缩放淡入、下层保持不动」，
    // 缩放那 200~300ms 里四周会露出约 7.5vp 的下层画面；本页顶部是 brand 渐变的
    // 用户卡，露出来就是一条刺眼的蓝色。隐去后露出的是本页底色（pageBackground），
    // 与新页面底色相同，视觉上无缝。420ms 覆盖整段转场，之后自动复原。
    this.pushVeil = true;
    // 连点菜单会叠加多个定时器；页面销毁后定时器仍会回调并向已卸载组件写 @State。
    // 保存 id、重复调用先清旧的，销毁时再清一次。
    if (this.pushVeilTimer >= 0) {
      clearTimeout(this.pushVeilTimer);
    }
    this.pushVeilTimer = setTimeout(() => {
      this.pushVeil = false;
      this.pushVeilTimer = -1;
    }, 420);
    AppRouter.open(this.stack, route);
  }

  aboutToDisappear(): void {
    if (this.pushVeilTimer >= 0) {
      clearTimeout(this.pushVeilTimer);
      this.pushVeilTimer = -1;
    }
  }

  private twoPaneMode(): boolean {
    return isTwoPane(this.bp);
  }

  /** 「账户」分组（个人资料 / 连接设置）。单列与两栏共用。 */
  @Builder
  accountSection() {
    SectionCard({ title: '账户', subtitle: '学籍与连接配置' }) {
      Column() {
        this.menuRow('个人资料', '查看学籍信息与联系方式', $r('sys.symbol.person'), () => {
          this.openRoute(RouteName.USER_INFO);
        })
        Divider().color(AppColor.divider).strokeWidth(0.5)
        this.menuRowImage('连接设置', this.connectionSummary(),
          $r('app.media.ic_connection'), () => {
            this.openRoute(RouteName.SETTINGS);
          })
      }
      .width('100%')
    }
  }

  /** 「关于」分组（切换图标 / 关于 UBAA）。单列与两栏共用。 */
  @Builder
  aboutSection() {
    SectionCard({ title: '关于', subtitle: '版本与开源信息' }) {
      Column() {
        // 前置图标 = 当前正在使用的图标方案（严格跟随，与系统深浅色无关）。
        this.menuRowIconPreview(
          '切换图标',
          '当前：' + IconStore.displayName(this.currentIcon),
          IconStore.displayIcon(this.currentIcon),
          () => {
            this.openRoute(RouteName.ICON_SWITCH);
          })
        Divider().color(AppColor.divider).strokeWidth(0.5)
        this.menuRow('关于 UBAA', '版本 ' + AppConfig.APP_VERSION, $r('sys.symbol.info_circle'), () => {
          this.openRoute(RouteName.ABOUT);
        })
      }
      .width('100%')
    }
  }

  @Builder
  logoutButton() {
    Button('退出登录')
      .width('100%')
      .height(48)
      .fontSize(AppFont.subtitle)
      .fontColor(AppColor.danger)
      .backgroundColor(AppColor.surface)
      .onClick(() => {
        this.doLogout();
      })
  }

  /** 原页面内容。下拉刷新由外层 `build()` 的 PullToRefresh 提供。 */
  @Builder
  pageContent() {
    Scroll() {
      Column({ space: AppSize.gapLarge }) {
        if (this.twoPaneMode()) {
          /**
           * 平板横屏（lg / xxl）：两栏。
           *
           * 左栏是「我是谁 + 我的账户余额」，右栏是「能去哪里」——
           * 身份信息与操作入口分列，宽屏下不再是一路向下滑的长表单。
           */
          Row({ space: AppSize.gapLarge }) {
            Column({ space: AppSize.gapLarge }) {
              this.profileCard()
              this.metricsCard()
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Column({ space: AppSize.gapLarge }) {
              this.accountSection()
              this.aboutSection()
              this.logoutButton()
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        } else {
          this.profileCard()
          this.metricsCard()
          this.accountSection()
          this.aboutSection()
          this.logoutButton()
        }

        Blank()
          .height(AppSize.contentBottomInset)
      }
      .width('100%')
      .padding({
        left: AppSize.pagePadding,
        right: AppSize.pagePadding,
        // 顶部让开「状态栏 + 悬浮标题栏（MINI，56vp）」。状态栏那一段的模糊由
        // PageShell 的磨砂层补上，视口必须从屏幕顶开始（见 MainPage.PageShell）；
        // 留白只能写在这里，写到外壳上会把视口压低、内容就滑不进磨砂层了。
        top: AppSize.destTopInset(topSafeInsetVp()),
        bottom: 0
      })
      .constraintSize({ minHeight: '100%' })
      // 一级页内容整体上移一点（纯视觉位移，见 AppSize.contentTopLift）
      .translate({ y: -AppSize.contentTopLift })
    }
    .scrollBar(BarState.Off)
    // 顶/底拖到边界时回弹（内容不足一屏也生效）
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    // 沉浸光感「三件套」之二 / 之三（配合 titleBar 的 enableComponentSafeArea）：
    //   clip(false)      —— 允许内容画到自身布局矩形之外；
    //   expandSafeArea() —— 绘制区延伸进标题栏声明的组件安全区。
    // 缺了这两个，内容上滑时不会从标题栏底下钻进去，渐变模糊「没东西可糊」。
    .clip(false)
    .expandSafeArea()
    .width('100%')
    .height('100%')
    // 顶部留白不写在 Scroll 上 —— ArkUI 会把 Scroll 的 padding 当 contentInset，
    // 把滚动内容整体上移（实测反而顶到时钟上）；留白写在滚动内容的内边距里。
    .backgroundColor(AppColor.pageBackground)
  }

  build() {
    PullToRefresh({
      onRefresh: () => this.loadMetrics(true),
      contentBuilder: () => {
        this.pageContent();
      }
    })
  }
}
