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
/**
 * 最多保留多少条（超出按时间淘汰）。
 *
 * 存得比「首页显示 4 个」多：首页要按功能注册表过滤掉已下线/非一级入口的 route，
 * 只读 4 条会让过滤后凑不满。
 */
export const RECENT_STORE_LIMIT: number = 12;
const MAX_ENTRIES: number = RECENT_STORE_LIMIT;

/** 「近3天」统计窗口（ms）。使用频率＝窗口内的点击次数。 */
const WINDOW_MS: number = 3 * 24 * 60 * 60 * 1000;

interface RecentEntry {
  /** 目标路由名（`AppRouter.RouteName`）。 */
  route: string;
  /** 最近一次点击时刻（epoch ms）。近3天都没用时，用它兜底「上一次的顺序」。 */
  at: number;
  /** 累计点击次数（兼容旧数据；不再作为排序主键）。 */
  count: number;
  /** 近3天内的每次点击时刻（epoch ms），用于统计频率；旧数据可能没有此字段。 */
  times: number[];
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
   * 顺序判定只在这里产生，读取端不再猜：
   * 1. 同一 route 只保留一条，把本次时刻追加进 `times`（近3天窗口内的点击流水）；
   * 2. 追加时顺手裁掉窗口外的旧时间戳，避免流水无限增长；
   * 3. `at` 始终是最近一次点击时刻，用于「近3天没用过」时的兜底排序；
   * 4. 写入前按 `sortByFrequency` 重排一次，超出上限淘汰末尾。
   */
  static record(route: string): void {
    if (route.length === 0) {
      return;
    }
    const account: string = TokenStore.getSession().schoolId;
    if (account.length === 0) {
      return;
    }
    const now: number = Date.now();
    const from: number = now - WINDOW_MS;
    const list: RecentEntry[] = RecentFeatures.readAll(account);

    let found: RecentEntry | undefined = undefined;
    const kept: RecentEntry[] = [];
    for (let i = 0; i < list.length; i++) {
      const entry = list[i];
      if (entry.route === route) {
        found = entry;
      } else if (entry.route !== undefined && entry.route.length > 0) {
        kept.push(entry);
      }
    }

    let times: number[] = [];
    let hits: number = 1;
    if (found !== undefined) {
      const hit: RecentEntry = found;
      const previous: number[] = hit.times === undefined ? [] : hit.times;
      // 只保留窗口内的流水；老数据没有 times 但 at 在窗口内时补一条，平滑过渡。
      for (let i = 0; i < previous.length; i++) {
        if (previous[i] >= from) {
          times.push(previous[i]);
        }
      }
      if (previous.length === 0 && hit.at !== undefined && hit.at >= from) {
        times.push(hit.at);
      }
      hits = (hit.count === undefined ? 1 : hit.count) + 1;
    }
    times.push(now);

    const current: RecentEntry = {
      route: route,
      at: now,
      count: hits,
      times: times
    } as RecentEntry;
    kept.push(current);

    const ordered: RecentEntry[] = RecentFeatures.sortByFrequency(kept, now);
    const trimmed: RecentEntry[] = [];
    for (let i = 0; i < ordered.length && trimmed.length < MAX_ENTRIES; i++) {
      trimmed.push(ordered[i]);
    }
    RecentFeatures.writeAll(account, trimmed);
  }

  /** 某条记录在近3天窗口内的点击次数（使用频率）。 */
  private static hitsInWindow(entry: RecentEntry, now: number): number {
    const times: number[] = entry.times === undefined ? [] : entry.times;
    const from: number = now - WINDOW_MS;
    let n: number = 0;
    for (let i = 0; i < times.length; i++) {
      if (times[i] >= from) {
        n++;
      }
    }
    return n;
  }

  /**
   * 排序：近3天使用频率降序；频率相同（含都为 0，即近3天都没用过）
   * 时按 `at` 降序 —— 也就是「上一次的顺序」；再以次数、route 字典序兜底。
   * 不修改入参。
   */
  private static sortByFrequency(list: RecentEntry[], now: number): RecentEntry[] {
    const sorted: RecentEntry[] = list.slice();
    sorted.sort((a: RecentEntry, b: RecentEntry): number => {
      const fa: number = RecentFeatures.hitsInWindow(a, now);
      const fb: number = RecentFeatures.hitsInWindow(b, now);
      if (fa !== fb) {
        return fb - fa;
      }
      const left: number = a.at === undefined ? 0 : a.at;
      const right: number = b.at === undefined ? 0 : b.at;
      if (left !== right) {
        return right - left;
      }
      const leftCount: number = a.count === undefined ? 0 : a.count;
      const rightCount: number = b.count === undefined ? 0 : b.count;
      if (leftCount !== rightCount) {
        return rightCount - leftCount;
      }
      // 时间戳相同（同一毫秒点了两个）：用 route 定序，保证结果稳定可复现
      return a.route < b.route ? -1 : (a.route > b.route ? 1 : 0);
    });
    return sorted;
  }

  /**
   * 最近使用的 route（按近3天使用频率降序，最多 `limit` 个）。
   *
   * 用「当前时刻」重新统计窗口：超过3天的流水即使还留在盘上也会自然失活，
   * 全部归零后就退化成 at 降序 —— 即「近3天没用时按上一次的顺序显示」。
   *
   * 调用方用它去 `FeatureRegistry` 反查图标与名称；反查不到就跳过
   * （功能可能已被下线，留着一个空壳入口比没有更糟）。
   */
  static list(limit: number): string[] {
    const account: string = TokenStore.getSession().schoolId;
    if (account.length === 0) {
      return [];
    }
    const now: number = Date.now();
    const list: RecentEntry[] = RecentFeatures.sortByFrequency(RecentFeatures.readAll(account), now);
    const out: string[] = [];
    const seen = new Set<string>();
    for (let i = 0; i < list.length && out.length < limit; i++) {
      const route: string = list[i].route;
      if (route === undefined || route.length === 0 || seen.has(route)) {
        continue;
      }
      seen.add(route);
      out.push(route);
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
