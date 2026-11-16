import { window } from '@kit.ArkUI';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { Logger } from './Logger';
import { resourceManager } from '@kit.LocalizationKit';
import { GlobalContext } from './GlobalContext';
import {
  KEY_WINDOW_WIDTH_VP,
  KEY_WINDOW_HEIGHT_VP,
  KEY_BREAKPOINT,
  KEY_HEIGHT_BP,
  KEY_IS_LANDSCAPE,
  KEY_IS_WIDE_SCREEN,
  KEY_NAV_SPLIT_MODE,
  widthToBreakpoint,
  heightToBreakpoint,
  isWideBreakpoint,
  isSplitBreakpoint
} from './Breakpoint';

// AppStorage 键：顶部状态栏避让高度（vp）。
export const KEY_TOP_SAFE_HEIGHT: string = 'topSafeAreaHeight';
// AppStorage 键：底部导航条避让高度（vp）。
export const KEY_BOTTOM_SAFE_HEIGHT: string = 'bottomSafeAreaHeight';
/**
 * AppStorage 键：是否处于深色模式。
 *
 * 🔴 **这个值必须是 `'isDark'`，不能是 `'isDarkMode'`**（2026-11-17 修）。
 *
 * 历史坑：这里原先写 `'isDarkMode'`，而 `EntryAbility` 的三个写入点
 * （`onCreate` / `onWindowStageCreate` / `onConfigurationUpdate`）写的是 `'isDark'`。
 * 于是 `AppStorage.get('isDarkMode')` 在**冷启动时恒为 `undefined`**，
 * 所有 `?? false` 的调用点全部落到浅色分支 —— 深色模式下首页教室文字的渐隐遮罩
 * 用了纯白渐变，在 `#1A1A1A` 卡片上糊出一块白斑。
 * （只有运行中切主题才会经 `updateColorMode` 写进 `'isDarkMode'`，所以重启后复发。）
 *
 * 统一到一个键，且**读取一律走 `currentIsDark()`**，不再散落字面量。
 */
export const KEY_IS_DARK: string = 'isDark';

/**
 * 读取当前顶部避让高度（vp）。
 *
 * 供 @Builder / 非组件上下文使用（那里拿不到 @StorageProp）。
 * 避让区在 onWindowStageCreate 阶段写入，早于任何页面构建，因此这里读到的值已就绪。
 */
export function topSafeInsetVp(): number {
  const value: number | undefined = AppStorage.get<number>(KEY_TOP_SAFE_HEIGHT);
  return value !== undefined && value > 0 ? value : 0;
}

/**
 * 生成 HDS 组件用的状态栏内容色样式（`HdsNavigation` / `HdsNavDestination`）。
 *
 * ## 为什么必须给 HDS 显式设置（2026-11-17 定位）
 *
 * `SystemBarStyle.statusBarContentColor` 的**默认值是 `'#E5FFFFFF'`（白色）**
 * （SDK 原文：`@ohos.window.d.ts` → `interface SystemBarStyle`，
 *  "The default value is **'#E5FFFFFF'**"）。
 *
 * HdsNavigation / HdsNavDestination 在**未设置 `systemBarStyle` 属性**时，
 * 会用这个默认值托管状态栏。于是出现这个现象链：
 *   1. 首屏：HDS 应用默认白 → 状态栏白字（错）
 *   2. 锁屏再开屏：`windowVisibilityChange` 回调里调 `setWindowSystemBarProperties` → 变黑（对）
 *   3. 页面下拉/滚动：HDS 动态样式重新生效 → 又按默认值刷回白（错）
 *
 * 官方明确写了 **「不建议混合使用 systemBarStyle 属性和 window 设置状态栏样式的相关接口」**
 * （`ui-design-hdsnavigation` → `systemBarStyle` 说明第 1 条）。
 * 因此正解是：HDS 页面用 `systemBarStyle` 显式给色，window 接口只留给非 HDS 页面（登录页等）兜底。
 *
 * ## 两个参数为什么给同一个值
 *
 * `originalStyle` 是初始样式，`scrollEffectStyle` 是**滚动动态样式生效后**的样式。
 * 两者不同就会在滚动瞬间变色——用户报的「一下拉又变白」正是这一类。
 * 状态栏始终要跟深浅色一致，所以两档给同一个值。
 */
export function systemBarStyleFor(isDark: boolean): window.SystemBarStyle {
  return { statusBarContentColor: isDark ? '#FFFFFFFF' : '#FF000000' };
}

/**
 * 读 AppStorage 的当前深浅色。
 *
 * 供 `@Builder` 等拿不到 `this` 的位置、以及事件回调（点击时取一次快照）使用。
 * **需要跟随主题变化自动重绘的地方不要用它** —— 纯函数读 AppStorage 不产生订阅关系，
 * 要在组件里写 `@StorageProp('isDark')` 再读 `this.xxx`。
 */
export function currentIsDark(): boolean {
  return AppStorage.get<boolean>(KEY_IS_DARK) ?? false;
}

// 数字色值 → #AARRGGBB。不用 padStart，避免个别 ArkTS 运行时差异。
function toArgbHex(argb: number): string {
  const v: number = argb >>> 0;
  let s: string = v.toString(16).toUpperCase();
  while (s.length < 8) {
    s = '0' + s;
  }
  return '#' + s;
}

let surfaceArgbCache: string = '';
let surfaceArgbCacheDark: boolean | null = null;

/**
 * 卡片底色（`app.color.surface`）的 `#AARRGGBB` 值，随深浅色自动取对应资源。
 *
 * ## 为什么需要它
 *
 * 「文字尾部渐隐」的做法是**与卡片底色同 RGB、只把 alpha 从 0 拉到 255** 的渐变，
 * 这样插值过程不会出现半透明黑/白，观感就是字形逐个变淡。
 * 一旦渐变用的 RGB 和卡片真实底色不一致，就会糊出一块可见的色斑 ——
 * 深色模式下曾经的「白斑」就是拿浅色白渐变盖在 `#1A1A1A` 卡片上。
 *
 * 所以这里**从资源里取真值**（项目约定颜色走 resources 下各模式 element/color.json，不写死），
 * 并有内存缓存避免每帧走一次资源管理器。
 */
export function surfaceArgbHex(isDark: boolean): string {
  if (surfaceArgbCacheDark === isDark && surfaceArgbCache.length === 9) {
    return surfaceArgbCache;
  }
  // 兜底值与 color.json 保持一致（深色 #1A1A1A / 浅色 #FFFFFF）
  let hex: string = isDark ? '#FF1A1A1A' : '#FFFFFFFF';
  try {
    hex = toArgbHex(GlobalContext.getContext().resourceManager.getColorSync($r('app.color.surface').id));
  } catch (err) {
    Logger.warn('解析 surface 颜色失败，用兜底值：' + (err as Error).message);
  }
  surfaceArgbCache = hex;
  surfaceArgbCacheDark = isDark;
  return hex;
}

// 同色相的完全透明版本：#AARRGGBB 转成 #00RRGGBB
export function transparentOf(argbHex: string): string {
  return argbHex.length === 9 ? '#00' + argbHex.substring(3) : '#00000000';
}

/**
 * 沉浸式（全屏 + 光感）基础设施。
 *
 * 关键点：
 * 1. setWindowLayoutFullScreen(true) 让内容延伸到状态栏与导航条之下
 * 2. 读取避让区高度写入 AppStorage，页面据此做安全区避让
 * 3. 状态栏 / 导航条内容颜色跟随深浅色模式，避免出现「白底白字」
 * 4. 窗口尺寸（px）换算成 vp 后写入 AppStorage，驱动宽屏 / 分栏断点
 */
export class ImmersiveUtil {
  private static mainWindow: window.Window | null = null;

  /**
   * 方向策略：**必须在 `windowStage.loadContent()` 之前**调用。
   *
   * 历史坑（2026-11-09 ~ 11-10 实测）：module.json5 里静态写 `orientation: portrait`
   * 时，平板横屏下系统会把 App 塞进窄的竖向兼容窗口（左右露出壁纸，窗口宽恒等于
   * 竖屏宽度 387vp），**运行期 `setPreferredOrientation` 改不回来**——静态声明优先级更高。
   * 因此 module.json5 已改为 `auto_rotation_restricted`（允许平板横竖屏），
   * 手机端的竖屏锁定改由这里在运行期下发。
   *
   * 依据：平板 / 折叠屏必须支持握持方向跟随，手机端保持竖屏是产品决策，
   * 属于「方向策略」，与「布局按窗口宽度断点适配」是两条独立规则。
   */
  static applyOrientationPolicy(windowStage: window.WindowStage): void {
    const deviceType: string = deviceInfo.deviceType;
    const isLargeScreen: boolean = deviceType === deviceInfo.DeviceTypes.TYPE_TABLET ||
      deviceType === deviceInfo.DeviceTypes.TYPE_2IN1;
    const win: window.Window = windowStage.getMainWindowSync();
    if (isLargeScreen) {
      // 大屏：跟随传感器，仅正向（不含倒置）
      win.setPreferredOrientation(window.Orientation.AUTO_ROTATION_RESTRICTED)
        .catch((error: Error) => {
          Logger.warn('放开自动旋转失败：' + error.message);
        });
      return;
    }
    // 手机 / 手表等窄屏形态：锁定竖屏，与改造前行为一致
    win.setPreferredOrientation(window.Orientation.PORTRAIT)
      .catch((error: Error) => {
        Logger.warn('锁定竖屏失败：' + error.message);
      });
  }

  // 在 EntryAbility.onWindowStageCreate 中调用。
  static apply(windowStage: window.WindowStage, colorMode: ConfigurationConstant.ColorMode): void {
    try {
      const win = windowStage.getMainWindowSync();
      ImmersiveUtil.mainWindow = win;

      // ⚠️ 状态栏色**必须在 setWindowLayoutFullScreen(true) 之前设置** ——
      // 全屏之后再调 setWindowSystemBarProperties 会被系统忽略（日志显示成功、实际不生效）。
      ImmersiveUtil.applySystemBarStyle(win);

      win.setWindowLayoutFullScreen(true)
        .then(() => {
          ImmersiveUtil.refreshAvoidArea(win);
          // 全屏完成后再设一次，双保险
          ImmersiveUtil.applySystemBarStyle(win);
        })
        .catch((error: Error) => {
          Logger.error('设置全屏布局失败：' + error.message);
        });

      // 避让区变化（折叠屏展开、旋转、手势导航切换等）
      win.on('avoidAreaChange', () => {
        ImmersiveUtil.refreshAvoidArea(win);
      });
      // 深浅色切换
      win.on('windowVisibilityChange', () => {
        ImmersiveUtil.refreshAvoidArea(win);
        // 全屏模式下系统偶尔会重置状态栏文字色，每次可见都重设一次
        ImmersiveUtil.applySystemBarStyle(win);
      });
      // 窗口尺寸变化（分屏 / 自由窗口 / 横竖切换 / 折叠展开）。
      // 与 avoidAreaChange 是两个独立回调、顺序不保证，所以这里成对刷新安全区。
      win.on('windowSizeChange', (size: window.Size) => {
        ImmersiveUtil.refreshAvoidArea(win);
        ImmersiveUtil.publishWindowSize(win, size.width, size.height);
      });
      // 订阅后不一定立刻有事件，必须自己取一次首值，否则首帧永远停在 sm。
      const rect = win.getWindowProperties().windowRect;
      ImmersiveUtil.publishWindowSize(win, rect.width, rect.height);
    } catch (error) {
      Logger.error('沉浸式初始化异常：' + (error as Error).message);
    }
  }

  /**
   * 刷新系统栏样式（供页面 `aboutToAppear` / `onPageShow` 调用）。
   *
   * `setWindowSystemBarProperties` 是**窗口级** API，但官方建议在**页面生命周期**里
   * 调用才稳定生效（见开发者论坛/SegmentFault 的解答）。
   */
  static refreshSystemBar(): void {
    if (ImmersiveUtil.mainWindow !== null) {
      ImmersiveUtil.applySystemBarStyle(ImmersiveUtil.mainWindow);
    }
  }

  // 深浅色模式变化时重新设置状态栏内容色。
  static updateColorMode(colorMode: ConfigurationConstant.ColorMode): void {
    if (ImmersiveUtil.mainWindow !== null) {
      ImmersiveUtil.applySystemBarStyle(ImmersiveUtil.mainWindow);
      AppStorage.setOrCreate(KEY_IS_DARK, colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    }
  }

  // 发布窗口尺寸（vp）与断点，供 MainPage / DestShell / AppSize 消费。
  private static publishWindowSize(win: window.Window, wPx: number, hPx: number): void {
    try {
      const ui = win.getUIContext();
      const wVp: number = ui.px2vp(wPx);
      const hVp: number = ui.px2vp(hPx);
      const bp: string = widthToBreakpoint(wVp);
      const hBp: string = heightToBreakpoint(hVp);
      AppStorage.setOrCreate<number>(KEY_WINDOW_WIDTH_VP, wVp);
      AppStorage.setOrCreate<number>(KEY_WINDOW_HEIGHT_VP, hVp);
      AppStorage.setOrCreate<string>(KEY_BREAKPOINT, bp);
      AppStorage.setOrCreate<string>(KEY_HEIGHT_BP, hBp);
      AppStorage.setOrCreate<boolean>(KEY_IS_LANDSCAPE, wVp > hVp);
      AppStorage.setOrCreate<boolean>(KEY_IS_WIDE_SCREEN, isWideBreakpoint(bp));
      AppStorage.setOrCreate<boolean>(KEY_NAV_SPLIT_MODE, isSplitBreakpoint(bp));
      Logger.info('LAYOUT w=' + wVp + 'vp h=' + hVp + 'vp bp=' + bp + '/' + hBp);
      // 方向策略不在这里做：静态 orientation 已放开（auto_rotation_restricted），
      // 手机端的竖屏锁定由 EntryAbility 按设备形态决定（见 releaseOrientationForWideDevices）。
    } catch (error) {
      Logger.error('窗口尺寸发布失败：' + (error as Error).message);
    }
  }

  private static refreshAvoidArea(win: window.Window): void {
    try {
      const systemArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const indicatorArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      const uiContext = win.getUIContext();
      const top = uiContext.px2vp(systemArea.topRect.height);
      const bottom = uiContext.px2vp(indicatorArea.bottomRect.height);
      AppStorage.setOrCreate(KEY_TOP_SAFE_HEIGHT, top);
      AppStorage.setOrCreate(KEY_BOTTOM_SAFE_HEIGHT, bottom);
      Logger.info('LAYOUT 避让区 top=' + top + 'vp bottom=' + bottom + 'vp');
    } catch (error) {
      Logger.error('获取避让区失败：' + (error as Error).message);
    }
  }

  /**
   * 设置系统栏内容色。
   *
   * **以 `AppStorage('isDark')` 为唯一真相**，不接收 colorMode 参数 ——
   * 之前 `isDark`（页面订阅）和 `isDarkMode`（状态栏用）是两个不同的 key，
   * 切主题后两边不同步，导致「页面浅色、状态栏还白字」。
   */
  /**
   * 设置系统栏内容色。
   *
   * **直接读系统主题**（`resourceManager.getConfigurationSync().colorMode`），
   * 不依赖 `AppStorage('isDark')` —— 后者来自 `context.config.colorMode`，
   * 那是**应用配置**（可能被 `setColorMode` 覆盖），和系统实际主题不一定一致，
   * 结果就是「系统浅色、状态栏还是白字」。
   */
  private static applySystemBarStyle(win: window.Window): void {
    // setWindowSystemBarProperties 不支持 2in1 形态，跳过即可（该形态下系统栏由系统自绘）
    if (deviceInfo.deviceType === deviceInfo.DeviceTypes.TYPE_2IN1) {
      return;
    }
    let isDark: boolean = false;
    try {
      // Window 没有 getContext()，从 GlobalContext 拿应用 context
      const cfg = GlobalContext.getContext().resourceManager.getConfigurationSync();
      isDark = cfg.colorMode === resourceManager.ColorMode.DARK;
    } catch (err) {
      isDark = AppStorage.get<boolean>('isDark') ?? false;
    }
    // 用 ARGB（'#FF000000'），不透明确保生效；默认值是 '#E5FFFFFF'（白色）
    const contentColor = isDark ? '#FFFFFFFF' : '#FF000000';
    Logger.info('设置系统栏内容色: isDark=' + isDark + ' -> ' + contentColor);
    win.setWindowSystemBarProperties({
      // 全屏沉浸必需：状态栏/导航栏背景透明，否则会被一层灰盖住
      statusBarColor: '#00000000',
      navigationBarColor: '#00000000',
      statusBarContentColor: contentColor,
      navigationBarContentColor: contentColor
    }).then(() => {
      Logger.info('系统栏样式设置成功: ' + contentColor);
    }).catch((error: Error) => {
      Logger.warn('设置系统栏样式失败：' + error.message);
    });
  }
}
