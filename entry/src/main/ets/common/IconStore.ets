import { bundleManager, common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppConfig } from './AppConfig';
import { GlobalContext } from './GlobalContext';
import { Logger } from './Logger';
import { isApi26OrAbove } from './SystemMaterial';

/**
 * 应用图标方案（对应 AppScope/app.json5 的 alternateIcons）。
 *
 * 切换原理（API 26.0.0+）：
 * - 默认图标是 app.json5 的 `$media:layered_image`（A 标识浅色分层图标）；
 * - `bundleManager.setAlternateIcon(name)` 启用 alternateIcons 里的一个备用图标；
 * - 传空字符串恢复默认图标。
 *
 * 约束（官方文档）：
 * - 仅 bundleType=app 生效；应用最多同时启用一个备用图标；
 * - 分身应用不支持设置/查询备用图标；
 * - API < 26 的设备忽略 alternateIcons 标签，此工具类全部走降级（仅记录偏好、不调用系统接口）。
 */
export class IconScheme {
  static readonly DEFAULT: string = 'default';       // 系统默认：A 标识浅色分层图标
  static readonly ARK_LIGHT: string = 'ark_light';   // A 标识 · 浅色
  static readonly ARK_DARK: string = 'ark_dark';     // A 标识 · 深色
  static readonly CLASSIC_LIGHT: string = 'classic_light'; // 原版 UBAA · 浅色
  static readonly CLASSIC_DARK: string = 'classic_dark';   // 原版 UBAA · 深色
}

/** 一个可展示的图标选项。 */
export interface IconOption {
  /** alternateIcons 的 name；default 表示恢复默认分层图标。 */
  key: string;
  /** 列表里的标题。 */
  title: string;
  /** 列表里的副标题。 */
  subtitle: string;
  /** 该方案对应的桌面图标预览（固定展示这一张，让用户区分四个选项）。 */
  previewIcon: Resource;
}

/** 供「切换图标」页使用的四套选项，顺序与用户约定一致。 */
export const ICON_OPTIONS: IconOption[] = [
  {
    // 默认项：传空字符串恢复 app.json5 的 layered_image（A 标识浅色分层图标），
    // 即用户当前正在用的图标，保留桌面景深视差效果。
    key: IconScheme.DEFAULT,
    title: 'UBAA Ark · 浅色',
    subtitle: '蓝底白字 + Ark 角标 · 默认',
    previewIcon: $r('app.media.icon_ark_light')
  },
  {
    key: IconScheme.ARK_DARK,
    title: 'UBAA Ark · 深色',
    subtitle: '深底蓝字 + Ark 角标',
    previewIcon: $r('app.media.icon_ark_dark')
  },
  {
    key: IconScheme.CLASSIC_LIGHT,
    title: '原版 UBAA · 浅色',
    subtitle: '蓝底白字，无角标',
    previewIcon: $r('app.media.icon_ubaa_light')
  },
  {
    key: IconScheme.CLASSIC_DARK,
    title: '原版 UBAA · 深色',
    subtitle: '深底蓝字，无角标',
    previewIcon: $r('app.media.icon_ubaa_dark')
  }
];

/** 当前图标偏好在系统里的落盘 key。 */
const PREF_KEY_ICON: string = 'app_icon_scheme';
/** AppStorage 广播 key：切页返回后「我的」页据此即时刷新图标与副标题。 */
export const KEY_APP_ICON_SCHEME: string = 'appIconScheme';

export class IconStore {
  private static pref: preferences.Preferences | null = null;

  private static store(): preferences.Preferences | null {
    if (IconStore.pref === null) {
      try {
        const context: common.UIAbilityContext = GlobalContext.getContext();
        IconStore.pref = preferences.getPreferencesSync(context, { name: AppConfig.PREF_STORE_NAME });
      } catch (error) {
        Logger.error('图标偏好存储打开失败：' + (error as Error).message);
        return null;
      }
    }
    return IconStore.pref;
  }

  /** 读取当前图标方案 key；无记录返回 default。 */
  static current(): string {
    const store = IconStore.store();
    if (store === null) {
      return IconScheme.DEFAULT;
    }
    try {
      const value = store.getSync(PREF_KEY_ICON, IconScheme.DEFAULT);
      if (typeof value === 'string' && IconStore.isValid(value as string)) {
        return value as string;
      }
    } catch (error) {
      Logger.error('读取图标偏好失败：' + (error as Error).message);
    }
    return IconScheme.DEFAULT;
  }

  private static isValid(key: string): boolean {
    return key === IconScheme.DEFAULT
      || key === IconScheme.ARK_LIGHT
      || key === IconScheme.ARK_DARK
      || key === IconScheme.CLASSIC_LIGHT
      || key === IconScheme.CLASSIC_DARK;
  }

  /**
   * 应用图标方案：先落盘偏好，再调用系统切换。
   *
   * @returns 成功返回 true；API < 26 返回 false（偏好已记，等系统支持后生效），
   *   系统接口报错也返回 false（偏好仍保留，便于下次重试）。
   */
  static async apply(key: string): Promise<boolean> {
    if (!IconStore.isValid(key)) {
      return false;
    }
    const store = IconStore.store();
    if (store !== null) {
      try {
        store.putSync(PREF_KEY_ICON, key);
        store.flushSync();
      } catch (error) {
        Logger.error('写入图标偏好失败：' + (error as Error).message);
      }
    }
    // 即时广播，返回「我的」页时图标入口无需重新 appear 就能刷新
    AppStorage.setOrCreate(KEY_APP_ICON_SCHEME, key);

    if (!isApi26OrAbove()) {
      Logger.warn('当前系统 API < 26，备用图标仅记录偏好，未调用系统切换');
      return false;
    }

    // default 传空字符串恢复默认分层图标；其余传 alternateIcons 的 name
    const name: string = key === IconScheme.DEFAULT ? '' : key;
    try {
      await bundleManager.setAlternateIcon(name);
      Logger.info('切换应用图标成功：' + (name.length === 0 ? 'default' : name));
      return true;
    } catch (error) {
      const err = error as BusinessError;
      Logger.error('切换应用图标失败：code=' + err.code + ', ' + err.message);
      return false;
    }
  }

  /**
   * 启动时把已保存的偏好同步到系统图标。
   *
   * 说明：桌面图标由系统持久化，重装/恢复出厂才会丢；应用侧偏好可能在升级、
   * 清缓存等场景与系统实际图标不一致，冷启动时补一次切换可纠正。
   */
  static async restore(): Promise<void> {
    if (!isApi26OrAbove()) {
      return;
    }
    const key = IconStore.current();
    const name: string = key === IconScheme.DEFAULT ? '' : key;
    try {
      await bundleManager.setAlternateIcon(name);
      Logger.info('恢复应用图标：' + (name.length === 0 ? 'default' : name));
    } catch (error) {
      const err = error as BusinessError;
      Logger.warn('恢复应用图标失败：code=' + err.code + ', ' + err.message);
    }
  }

  /**
   * 当前生效方案的应用内展示图标。
   *
   * 严格跟随「正在使用的那套图标」——选深色方案就显示深色图，选原版就显示原版图，
   * 与系统深浅色无关。桌面图标本身是切换时固定的那张，入口图标必须和它一一对应，
   * 否则用户切完返回会看到前置图标和桌面不一致，误以为没生效。
   */
  static displayIcon(key: string): Resource {
    switch (key) {
      case IconScheme.ARK_DARK:
        return $r('app.media.icon_ark_dark');
      case IconScheme.CLASSIC_LIGHT:
        return $r('app.media.icon_ubaa_light');
      case IconScheme.CLASSIC_DARK:
        return $r('app.media.icon_ubaa_dark');
      case IconScheme.ARK_LIGHT:
      case IconScheme.DEFAULT:
      default:
        return $r('app.media.icon_ark_light');
    }
  }

  /** 当前方案的展示文案。 */
  static displayName(key: string): string {
    for (const option of ICON_OPTIONS) {
      if (option.key === key) {
        return option.title;
      }
    }
    return 'UBAA Ark · 浅色';
  }
}
