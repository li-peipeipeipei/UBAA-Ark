import {
  AbilityConstant, bundleManager, Configuration, ConfigurationConstant, UIAbility, Want
} from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { connection } from '@kit.NetworkKit';
import display from '@ohos.display';
import { AppConfig } from '../common/AppConfig';
import { StartupPrefetch } from '../common/StartupPrefetch';
import { GlobalContext } from '../common/GlobalContext';
import { ImmersiveUtil } from '../common/ImmersiveUtil';
import { resourceManager } from '@kit.LocalizationKit';
import { CardCache } from '../common/CardCache';
import { CardRefresher } from '../common/CardRefresher';
import { IconStore, KEY_APP_ICON_SCHEME } from '../common/IconStore';
import { Logger } from '../common/Logger';
import { NETWORK_BACK_TICK_KEY, RouteEngine } from '../network/RouteEngine';
import { TokenStore } from '../network/TokenStore';
import { KEY_MAIN_TAB_INDEX } from '../common/NavStacks';
import { NavHero } from '../common/NavHero';
import { KEY_HERO_PAGE_OPACITY, KEY_MORPH_TICK } from '../common/HeroMorph';
import {
  KEY_WINDOW_WIDTH_VP,
  KEY_WINDOW_HEIGHT_VP,
  KEY_BREAKPOINT,
  KEY_HEIGHT_BP,
  KEY_IS_LANDSCAPE,
  KEY_IS_WIDE_SCREEN,
  KEY_NAV_SPLIT_MODE
} from '../common/Breakpoint';

/**
 * 桌面卡片跳转要落的页签。
 *
 * 卡片侧 `postCardAction({action:'router', abilityName:'EntryAbility', params:{target:'schedule'}})`
 * 会把 `params` 原样塞进启动/跳转的 Want 里。**冷启动走 onCreate、应用已在后台走 onNewWant**
 * —— 两条都要接，否则「点卡片没反应」或「只在被杀时生效」。
 *
 * `target` 是页签标识（home/schedule/feature/mine）；
 * 可选的 `page` 是该页签内的**二级路由名**（exam/grade/classroom…），
 * 「考试卡」这类就靠它落到具体页面而不是只切到功能页。
 *
 * 用 AppStorage 中转而不是直接操作页面：Ability 层拿不到页面实例，
 * 而且首页 Index 要先异步恢复登录态才建出 MainPage，时序上必须解耦。
 */
const KEY_PENDING_ROUTE: string = 'pendingRoute';
const KEY_PENDING_PAGE: string = 'pendingPage';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    Logger.info('EntryAbility onCreate');
    // 全局深浅色标记：课表页等用 @StorageProp('isDark') 订阅，切主题时自动重绘并换色板
    CardCache.darkHint = CardCache.isDarkMode(this.context);
    AppStorage.setOrCreate('isDark', CardCache.darkHint);
    // [探查] 屏幕物理圆角：`getRoundedCorner()` 只对「产品配置了圆角值的物理屏」返回，
    // 虚拟屏/无配置返回空数组。radius 单位 px。用于评估「色块全屏圆角 = 屏幕圆角」是否可行。
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      const cs: display.RoundedCorner[] = d.getRoundedCorner();
      let detail: string = '';
      for (let i = 0; i < cs.length; i++) {
        detail += '|type=' + cs[i].type + ' r=' + cs[i].radius + 'px at(' +
          cs[i].position.x + ',' + cs[i].position.y + ')';
      }
      Logger.info('SCREENROUND density=' + d.densityPixels + ' px=' + d.width + 'x' + d.height +
        ' n=' + cs.length + ' ' + detail);
    } catch (err) {
      Logger.warn('SCREENROUND failed: ' + (err as BusinessError).message +
        ' code=' + (err as BusinessError).code);
    }
    GlobalContext.setContext(this.context);
    // 版本号以**安装包**为准：常量与 app.json5 的 versionName 容易漂移（曾经停在 0.1.0），
    // 关于页 / UA / 检查更新都会跟着报错。读失败就保留常量兜底。
    try {
      const info = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      AppConfig.applyVersionName(info.versionName);
      Logger.info('应用版本：' + AppConfig.APP_VERSION);
    } catch (err) {
      Logger.warn('读取应用版本失败，使用兜底值：' + (err as BusinessError).message);
    }
    // 预热本地存储：clientId 与连接配置需要在首帧前可用
    TokenStore.getOrCreateClientId();
    TokenStore.getApiBaseUrl();
    // 同步用户上次选择的桌面图标（重启后系统图标本身会保持，这里纠正
    // 「清过应用数据/升级」造成的偏好与系统实际图标不一致）。异步，不阻塞首帧。
    AppStorage.setOrCreate(KEY_APP_ICON_SCHEME, IconStore.current());
    IconStore.restore();
    // 冷启动：先建好 key（@StorageLink 才不会读到 undefined），再写入卡片带的目标
    AppStorage.setOrCreate<string>(KEY_PENDING_ROUTE, '');
    AppStorage.setOrCreate<string>(KEY_PENDING_PAGE, '');
    // 响应式断点默认值：必须早于首帧建好；手机端恒为 sm / false（零回归）
    AppStorage.setOrCreate<number>(KEY_WINDOW_WIDTH_VP, 0);
    AppStorage.setOrCreate<number>(KEY_WINDOW_HEIGHT_VP, 0);
    AppStorage.setOrCreate<string>(KEY_BREAKPOINT, 'sm');
    AppStorage.setOrCreate<string>(KEY_HEIGHT_BP, 'sm');
    AppStorage.setOrCreate<boolean>(KEY_IS_LANDSCAPE, false);
    AppStorage.setOrCreate<boolean>(KEY_IS_WIDE_SCREEN, false);
    AppStorage.setOrCreate<boolean>(KEY_NAV_SPLIT_MODE, false);
    // 当前页签序号（横竖屏切换后还要停在原来那一页，见 common/NavStacks.ets）
    AppStorage.setOrCreate<number>(KEY_MAIN_TAB_INDEX, 0);
    AppStorage.setOrCreate<number>(KEY_MORPH_TICK, 0);
    AppStorage.setOrCreate<number>(KEY_HERO_PAGE_OPACITY, 1);
    // 原生导航「卡片展开」转场的三个信号键（见 common/NavHero.ets）
    NavHero.initKeys();
    // 「回到前台」的翻转计数（SchedulePage 订阅它做静默刷新）
    AppStorage.setOrCreate<boolean>('appForegroundTick', false);
    this.foregroundTick = false;
    this.lastWant = want;
    this.consumeRoute(want);
  }

  /**
   * 应用已在后台时点卡片走这里 —— 不接的话点卡片只会把 App 拉到前台停在本页。
   */
  onNewWant(want: Want): void {
    Logger.info('EntryAbility onNewWant');
    this.lastWant = want;
    this.consumeRoute(want);
  }

  /** 从 Want 里取出卡片带的 `target` / `page`，写进 AppStorage 给 MainPage 消费。 */
  private consumeRoute(want: Want): void {
    if (want === undefined || want === null) {
      return;
    }
    // ArkTS 不做属性访问的跨函数空判收窄：必须先取到局部变量再判空，
    // 直接在静态方法里读 `want.parameters[...]` 会被判成 possibly undefined。
    const params: Record<string, Object> | undefined = want.parameters;
    if (params === undefined) {
      return;
    }
    const target: string = EntryAbility.stringParam(params, 'target');
    if (target.length === 0) {
      return;
    }
    const page: string = EntryAbility.stringParam(params, 'page');
    Logger.info('收到卡片跳转请求：' + target + (page.length > 0 ? ' / ' + page : ''));
    AppStorage.set<string>(KEY_PENDING_ROUTE, target);
    AppStorage.set<string>(KEY_PENDING_PAGE, page);
  }

  /**
   * 取一个字符串参数。
   *
   * `want.parameters` 的值类型是 `Object`（postCardAction 传的是字符串，但 Want 里
   * 也可能是数字），所以必须先判 `typeof` 再收窄 —— 直接 `as string` 在数字时会拿到错值。
   */
  private static stringParam(params: Record<string, Object>, key: string): string {
    const raw: Object | undefined = params[key];
    if (raw === undefined || typeof raw !== 'string') {
      return '';
    }
    return raw as string;
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    /**
     * 主题判定用**系统配置**（`resourceManager`），不用 `context.config.colorMode` ——
     * 后者是**应用配置**（可能被 `setColorMode` 覆盖），和系统实际主题不一定一致。
     */
    let isDark: boolean = false;
    try {
      const cfg = this.context.resourceManager.getConfigurationSync();
      isDark = cfg.colorMode === resourceManager.ColorMode.DARK;
    } catch (err) {
      isDark = false;
    }
    const colorMode: ConfigurationConstant.ColorMode = isDark
      ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
      : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    CardCache.darkHint = isDark;
    AppStorage.setOrCreate('isDark', isDark);
    // 网络恢复广播的初值：错误页的 @StorageLink 需要键在组件创建前就存在
    AppStorage.setOrCreate<number>(NETWORK_BACK_TICK_KEY, 0);

    // 方向策略（必须在 loadContent 之前）：
    // - 平板 / 2in1：跟随握持方向，横屏不再被塞进竖屏兼容窗口；
    // - 手机：运行期锁竖屏（静态 orientation 已改为 auto_rotation_restricted）。
    ImmersiveUtil.applyOrientationPolicy(windowStage);

    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code !== 0) {
        Logger.error('加载首页失败：' + JSON.stringify(err));
        return;
      }
      Logger.info('首页加载完成');
    });

    // 沉浸式全屏 + 光感基础：内容延伸到状态栏 / 导航条，并做安全区避让
    ImmersiveUtil.apply(windowStage, colorMode);

    // 自动路线：订阅换网事件（探测缓存随之作废），只注册一次
    this.registerNetworkWatch();
  }

  onWindowStageDestroy(): void {
    Logger.info('EntryAbility onWindowStageDestroy');
    this.unregisterNetworkWatch();
  }

  /**
   * 网络变化监听（自动路线依赖）。
   *
   * 探测结果缓存 3 秒，换网后必须作废 —— 否则新网络上的第一次判断还是旧结论
   * （在校园网探到的 CAMPUS 会一直沿用到校外，路线永远不切）。
   * 上游合同要求「宿主直接订阅平台连接事件……返回前台重新检查网络」。
   */
  private netConnection: connection.NetConnection | null = null;

  private registerNetworkWatch(): void {
    if (this.netConnection !== null) {
      return;
    }
    try {
      const net = connection.createNetConnection();
      // ⚠️ 回调里**不要碰 err**：`AsyncCallback` 成功时 err 是 undefined，
      // 直接 `err.code` 会 TypeError（异步回调抛错 = 未捕获 = 整个进程被杀，启动即闪退）。
      // 注册失败也只是少一个换网通知，不值得为它冒险读 err。
      net.register(() => {
        Logger.info('网络变化监听已注册');
      });
      // 三个事件连着来是常态（netLost → netCapabilitiesChange → netAvailable），
      // RouteEngine.notifyNetworkChanged 内部 1.5s 去抖，不必在这里再挡。
      net.on('netAvailable', () => {
        RouteEngine.notifyNetworkChanged();
      });
      net.on('netCapabilitiesChange', () => {
        RouteEngine.notifyNetworkChanged();
      });
      net.on('netLost', () => {
        RouteEngine.notifyNetworkChanged();
      });
      this.netConnection = net;
    } catch (error) {
      Logger.warn('注册网络变化监听异常：' + (error as Error).message);
    }
  }

  private unregisterNetworkWatch(): void {
    if (this.netConnection === null) {
      return;
    }
    try {
      // 同上：不要在回调里读 err（成功时是 undefined）
      this.netConnection.unregister(() => {
        Logger.info('网络变化监听已注销');
      });
    } catch (error) {
      Logger.warn('注销网络变化监听异常：' + (error as Error).message);
    }
    this.netConnection = null;
  }

  onForeground(): void {
    Logger.info('EntryAbility onForeground');
    // App 回到前台：如果卡带了「跳课表页」的请求，这时才真正切过去。
    // ⚠️ 只消费一次就必须清掉 lastWant —— 否则「临时」每次回前台都会重新写一次
    // pendingRoute，MainPage 的 @Watch 便跟着每次触发 applyRoute（清栈 + 切页签）：
    // 用户在任何页签、任何二级页，切个后台再回来都会被弹回课表页，栈也被清空。
    if (this.lastWant !== null) {
      this.consumeRoute(this.lastWant);
      this.lastWant = null;
    }
    // 回前台重新校一次网络：关 App 期间可能已经换网（宿舍 Wi-Fi → 教室流量）
    RouteEngine.notifyNetworkChanged();
    // 通知 UI 刷新（课表页订阅了这个 AppStorage 事件）
    AppStorage.set<boolean>('appForegroundTick', !this.foregroundTick);
  }

  private lastWant: Want | null = null;
  private foregroundTick: boolean = false;

  onBackground(): void {
    Logger.info('EntryAbility onBackground');
    // 切后台就停掉启动预取：用户已经离开前台，继续跑只是白耗流量与电。
    // 已完成的步骤留在内存缓存里，回前台照常复用。
    StartupPrefetch.cancel();

    /**
     * 回桌面（按 Home / 上滑 / 锁屏）时按系统时间重算一次桌面卡片。
     *
     * 解决「卡片停在旧快照」：上一节课已经上完、或隔了几天没进课表页时，
     * 桌面上的「下一节课」还指向过去的课。此前重算只发生在冷启动和课表页加载，
     * 用户吃完饭回桌面看到的就是过期的。onBackground 是普通应用能拿到的
     * 唯一可靠的「即将看桌面」时机 ——
     * ⚠️ 卡片可见回调 `onChangeFormVisibility` 仅对**系统应用**生效，用不了；
     * 定时刷新 updateDuration 最短 30 分钟，都不够。
     *
     * 只读本地缓存、不联网（CardRefresher 内部口径），几十毫秒完成；
     * 失败只 warn、不影响退后台流程。切后台做这件事不占前台时间。
     */
    try {
      CardRefresher.refresh(this.context);
      Logger.info('onBackground：桌面卡片已按系统时间重算');
    } catch (error) {
      Logger.warn('onBackground 重算桌面卡片失败：' + (error as Error).message);
    }
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    // 诊断：横竖屏切换走这里 = 能力没被重启（只是配置更新）；若这条不出现而 onCreate
    // 重跑，说明能力层重启了，那时 AppStorage 仍保留、模块级单例仍在，页面状态不该丢。
    Logger.info('EntryAbility onConfigurationUpdate');
    // 深浅色 / 语言变化：同步状态栏内容色与全局标记
    const newColorMode: ConfigurationConstant.ColorMode = newConfig.colorMode === undefined
      ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
      : newConfig.colorMode;
    ImmersiveUtil.updateColorMode(newColorMode);

    /**
     * 深浅色切换：页面与桌面卡片要一起换配色。
     *
     * - 页面：写 AppStorage，课表页的 `@StorageProp('isDark')` 收到后自动重绘；
     * - 卡片：它是独立进程，必须由主应用**重新推送** payload（`darkMode` 在
     *   `buildPayload` 里现取配置），所以这里重算一次再 pushAll。
     */
    const dark: boolean = newColorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    // 只有**深浅色真的变了**才重推卡片。`onConfigurationUpdate` 在旋转、折叠屏展开、
    // 分屏调整、语言切换时都会回调 —— 每次都 pushAll 的话，转场动画期间会同步做
    // invalidate + 读 9 个 key + 逐张卡跨进程 IPC，就是「转屏卡一下」的来源。
    const darkChanged: boolean = dark !== CardCache.darkHint;
    CardCache.darkHint = dark;
    AppStorage.setOrCreate('isDark', dark);
    if (!darkChanged) {
      return;
    }
    /**
     * 无条件重推桌面卡片 —— 不走 `CardRefresher.refresh()`，
     * 那个方法在「本地没有课表元信息」时会跳过，导致卡片收不到新的 darkMode。
     * `buildPayload` 里的 darkMode 是现取 `CardCache.darkHint` 的，这里刚设好。
     */
    try {
      CardCache.pushAll(this.context);
      Logger.info('深浅色=' + (dark ? '深色' : '浅色') + '，桌面卡片已重新推送');
    } catch (e) {
      Logger.warn('切换主题后推送卡片失败：' + (e as Error).message);
    }
  }

  onDestroy(): void {
    Logger.info('EntryAbility onDestroy');
  }
}
