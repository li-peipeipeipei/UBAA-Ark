import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { GlobalContext } from './GlobalContext';
import { TokenStore } from '../network/TokenStore';

/**
 * 「最近使用」的功能入口（本地记录）。
 *
 * 上游首页有「最近使用的功能快捷入口」——不是固定的常用清单，
 * 而是**用户真的点过什么就显示什么**。这里用 Preferences 记录 route 与时刻，
 * 取最近几个展示；换账号整体作废。
 *
 * 只记 route 字符串（功能清单在 `FeatureRegistry` 里，由展示方按 route 反查），
 * 避免把整个 FeatureItem（含 Resource）序列化进 Preferences。
 */

const STORE_NAME: string = 'ubaa_recent_features';
const KEY_LIST: string = 'list';
const KEY_ACCOUNT: string = 'account';
/** 最多保留多少条（超出按时间淘汰）。 */
const MAX_ENTRIES: number = 12;

interface RecentEntry {
  /** 目标路由名（`AppRouter.RouteName`）。 */
  route: string;
  /** 点击时刻（epoch ms）。 */
  at: number;
}

export class RecentFeatures {
  private static pref: preferences.Preferences | null = null;
  private static failed: boolean = false;

  private static store(): preferences.Preferences | null {
    if (RecentFeatures.failed) {
      return null;
    }
    if (RecentFeatures.pref === null) {
      try {
        const ctx: common.UIAbilityContext = GlobalContext.getContext();
        RecentFeatures.pref = preferences.getPreferencesSync(ctx, {
          name: STORE_NAME
        } as preferences.Options);
      } catch (error) {
        RecentFeatures.failed = true;
        return null;
      }
    }
    return RecentFeatures.pref;
  }

  private static readAll(account: string): RecentEntry[] {
    const store = RecentFeatures.store();
    if (store === null) {
      return [];
    }
    try {
      const owner = store.getSync(KEY_ACCOUNT, '') as string;
      if (owner.length === 0 || owner !== account) {
        return [];
      }
      const raw = store.getSync(KEY_LIST, '') as string;
      if (raw.length === 0) {
        return [];
      }
      const list = JSON.parse(raw) as RecentEntry[];
      return Array.isArray(list) ? list : [];
    } catch (error) {
      return [];
    }
  }

  private static writeAll(account: string, list: RecentEntry[]): void {
    const store = RecentFeatures.store();
    if (store === null) {
      return;
    }
    try {
      store.putSync(KEY_ACCOUNT, account);
      store.putSync(KEY_LIST, JSON.stringify(list));
      store.flush();
    } catch (error) {
      // 写不进不影响本次展示
    }
  }

  /**
   * 记一次使用。
   *
   * 同一 route 已存在就提到最前（按最近时间排序），避免重复条目挤占位置。
   */
  static record(route: string): void {
    if (route.length === 0) {
      return;
    }
    const account: string = TokenStore.getSession().schoolId;
    if (account.length === 0) {
      return;
    }
    const list: RecentEntry[] = RecentFeatures.readAll(account);
    const out: RecentEntry[] = [];
    out.push({ route: route, at: Date.now() } as RecentEntry);
    for (let i = 0; i < list.length; i++) {
      if (list[i].route !== route) {
        out.push(list[i]);
      }
      if (out.length >= MAX_ENTRIES) {
        break;
      }
    }
    RecentFeatures.writeAll(account, out);
  }

  /**
   * 最近使用的 route（按最近优先，最多 `limit` 个）。
   *
   * 调用方用它去 `FeatureRegistry` 反查图标与名称；反查不到就跳过
   * （功能可能已被下线，留着一个空壳入口比没有更糟）。
   */
  static list(limit: number): string[] {
    const account: string = TokenStore.getSession().schoolId;
    if (account.length === 0) {
      return [];
    }
    const list: RecentEntry[] = RecentFeatures.readAll(account);
    const out: string[] = [];
    for (let i = 0; i < list.length && out.length < limit; i++) {
      out.push(list[i].route);
    }
    return out;
  }

  /** 换账号 / 退出登录时清空。 */
  static clear(): void {
    const store = RecentFeatures.store();
    if (store === null) {
      return;
    }
    try {
      store.deleteSync(KEY_LIST);
      store.deleteSync(KEY_ACCOUNT);
      store.flush();
    } catch (error) {
      // 忽略
    }
  }
}
