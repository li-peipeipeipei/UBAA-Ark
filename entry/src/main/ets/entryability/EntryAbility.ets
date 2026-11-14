import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { GlobalContext } from '../common/GlobalContext';
import { ImmersiveUtil } from '../common/ImmersiveUtil';
import { Logger } from '../common/Logger';
import { TokenStore } from '../network/TokenStore';
import { KEY_MAIN_TAB_INDEX } from '../common/NavStacks';
import { NavHero } from '../common/NavHero';
import { HERO_BOUNCE_TICK, HERO_EXIT_TICK } from '../common/FeatureHero';
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
    GlobalContext.setContext(this.context);
    // 预热本地存储：clientId 与连接配置需要在首帧前可用
    TokenStore.getOrCreateClientId();
    TokenStore.getApiBaseUrl();
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
    // 功能块放大/缩回转场的两个信号（见 common/FeatureHero.ets）
    AppStorage.setOrCreate<number>(HERO_EXIT_TICK, 0);
    AppStorage.setOrCreate<number>(HERO_BOUNCE_TICK, 0);
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
    // config.colorMode 可能为 undefined（未指定），这里回退到浅色
    const rawColorMode: ConfigurationConstant.ColorMode | undefined = this.context.config.colorMode;
    const colorMode: ConfigurationConstant.ColorMode = rawColorMode === undefined
      ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
      : rawColorMode;
    AppStorage.setOrCreate('isDarkMode', colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK);

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
  }

  onWindowStageDestroy(): void {
    Logger.info('EntryAbility onWindowStageDestroy');
  }

  onForeground(): void {
    Logger.info('EntryAbility onForeground');
    // App 回到前台：如果卡带了「跳课表页」的请求，这时才真正切过去
    if (this.lastWant !== null) {
      this.consumeRoute(this.lastWant);
    }
    // 通知 UI 刷新（课表页订阅了这个 AppStorage 事件）
    AppStorage.set<boolean>('appForegroundTick', !this.foregroundTick);
  }

  private lastWant: Want | null = null;
  private foregroundTick: boolean = false;

  onBackground(): void {
    Logger.info('EntryAbility onBackground');
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
  }

  onDestroy(): void {
    Logger.info('EntryAbility onDestroy');
  }
}
