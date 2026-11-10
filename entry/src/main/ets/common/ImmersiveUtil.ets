import { window } from '@kit.ArkUI';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { Logger } from './Logger';
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

/** AppStorage 键：顶部状态栏避让高度（vp）。 */
export const KEY_TOP_SAFE_HEIGHT: string = 'topSafeAreaHeight';
/** AppStorage 键：底部导航条避让高度（vp）。 */
export const KEY_BOTTOM_SAFE_HEIGHT: string = 'bottomSafeAreaHeight';
/** AppStorage 键：是否处于深色模式。 */
export const KEY_IS_DARK: string = 'isDarkMode';

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

  /** 在 EntryAbility.onWindowStageCreate 中调用。 */
  static apply(windowStage: window.WindowStage, colorMode: ConfigurationConstant.ColorMode): void {
    try {
      const win = windowStage.getMainWindowSync();
      ImmersiveUtil.mainWindow = win;

      win.setWindowLayoutFullScreen(true)
        .then(() => {
          ImmersiveUtil.refreshAvoidArea(win);
          ImmersiveUtil.applySystemBarStyle(win, colorMode);
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

  /** 深浅色模式变化时重新设置状态栏内容色。 */
  static updateColorMode(colorMode: ConfigurationConstant.ColorMode): void {
    if (ImmersiveUtil.mainWindow !== null) {
      ImmersiveUtil.applySystemBarStyle(ImmersiveUtil.mainWindow, colorMode);
      AppStorage.setOrCreate(KEY_IS_DARK, colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    }
  }

  /** 发布窗口尺寸（vp）与断点，供 MainPage / DestShell / AppSize 消费。 */
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

  private static applySystemBarStyle(win: window.Window, colorMode: ConfigurationConstant.ColorMode): void {
    // setWindowSystemBarProperties 不支持 2in1 形态，跳过即可（该形态下系统栏由系统自绘）
    if (deviceInfo.deviceType === deviceInfo.DeviceTypes.TYPE_2IN1) {
      return;
    }
    const isDark = colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    const contentColor = isDark ? '#FFFFFF' : '#000000';
    win.setWindowSystemBarProperties({
      statusBarContentColor: contentColor,
      navigationBarContentColor: contentColor
    }).catch((error: Error) => {
      Logger.warn('设置系统栏样式失败：' + error.message);
    });
  }
}
