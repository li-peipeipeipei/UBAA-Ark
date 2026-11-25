import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { GlobalContext } from './GlobalContext';

/**
 * 通用离线缓存（离线优先）。
 *
 * ## 解决什么问题
 *
 * 课表之外的四个查询页（财务收入 / 成绩 / 考试安排 / 空闲教室）原来是「纯在线」的：
 * 打开就发请求，失败就一张错误页 —— **明明上次的结果还在本地，却什么都看不到**。
 *
 * 这里提供统一的「先渲染本地、后台静默刷新」三件套：
 * 1. `load()` 同步读本地，**立刻**把内容填上并标注「离线记录」；
 * 2. 网络成功后 `save()` 覆盖写回，去掉标注；
 * 3. 网络失败时**保留本地内容不动**（只轻提示），不清空。
 *
 * 与 `ScheduleCache` 同一套模式：Preferences 同步读写、按 key 存 JSON、
 * 记录账号（换账号整体作废）。差别是这里做成了**通用**的 key-value，
 * 各页面自己决定存什么形状。
 *
 * ## 为什么用 Preferences 而不是 RDB
 *
 * 数据量小（几十 KB）、只要「一次写入、整体读取」，同步读写毫秒级，
 * 不用引入关系库与迁移。详见 `ScheduleCache` 的文件头说明。
 */

const STORE_NAME: string = 'ubaa_offline_cache';

/** 账号不匹配时整体作废（换账号不能看到别人的记录）。 */
const KEY_ACCOUNT: string = 'account';

/**
 * 动态 key 登记表的持久化键（值是 JSON 字符串数组）。
 *
 * Preferences 无法枚举 key，带 id 的详情页 key 只能靠登记。登记表若只在内存里，
 * 进程重启后就清空 —— 换账号时会漏掉上次进程写过的详情缓存。落到磁盘后，
 * 冷启动也能恢复完整表，换账号清理才彻底。
 */
const KEY_PREFIXED_REGISTRY: string = 'off_pref_registry';

interface CacheBox {
  /** 值（JSON 字符串）。 */
  v: string;
  /** 写入时刻（epoch ms）。 */
  t: number;
}

export class OfflineCache {
  private static pref: preferences.Preferences | null = null;
  /** 打开失败过就别再试（每次读写都抛异常会拖慢页面）。 */
  private static failed: boolean = false;

  private static store(): preferences.Preferences | null {
    if (OfflineCache.failed) {
      return null;
    }
    if (OfflineCache.pref === null) {
      try {
        const ctx: common.UIAbilityContext = GlobalContext.getContext();
        OfflineCache.pref = preferences.getPreferencesSync(ctx, {
          name: STORE_NAME
        } as preferences.Options);
      } catch (error) {
        // 读不到缓存只是退化成「纯在线」，不能影响页面本身
        OfflineCache.failed = true;
        return null;
      }
    }
    return OfflineCache.pref;
  }

  /** 当前账号（用于换账号作废）。空串表示未知，任何账号都不匹配。 */
  private static account(): string {
    try {
      const store = OfflineCache.store();
      if (store === null) {
        return '';
      }
      return store.getSync(KEY_ACCOUNT, '') as string;
    } catch (error) {
      return '';
    }
  }

  /**
   * 写入一份缓存。
   *
   * @param account 缓存所属账号（学号）；与当前记录不一致时会先清掉旧的。
   */
  static save(key: string, value: Object, account: string): void {
    const store = OfflineCache.store();
    if (store === null) {
      return;
    }
    try {
      const previous: string = OfflineCache.account();
      if (previous.length > 0 && previous !== account) {
        // 换账号：全部作废，别让新账号读到别人的记录
        OfflineCache.clearAll(account);
      }
      const box = { v: JSON.stringify(value), t: Date.now() } as CacheBox;
      store.putSync(key, JSON.stringify(box));
      store.putSync(KEY_ACCOUNT, account);
      store.flush();
    } catch (error) {
      // 写不进缓存不影响本次显示
    }
  }

  /**
   * 读一份缓存。
   *
   * @param account 当前账号；与缓存所属账号不一致时返回 null（当作没缓存）。
   * @returns 缓存值，没有/账号不符/解析失败都返回 null。
   */
  static load(key: string, account: string): Object | null {
    const store = OfflineCache.store();
    if (store === null) {
      return null;
    }
    try {
      const owner: string = OfflineCache.account();
      if (owner.length === 0 || owner !== account) {
        return null;
      }
      const raw = store.getSync(key, '') as string;
      if (raw.length === 0) {
        return null;
      }
      const box = JSON.parse(raw) as CacheBox;
      if (box === null || box === undefined || typeof box.v !== 'string') {
        return null;
      }
      return JSON.parse(box.v) as Object;
    } catch (error) {
      return null;
    }
  }

  /**
   * 读缓存的写入时刻（epoch ms）；没有则返回 0。
   *
   * 用来在界面上标注「更新于 xx:xx」或「离线记录」。
   */
  static savedAt(key: string, account: string): number {
    const store = OfflineCache.store();
    if (store === null) {
      return 0;
    }
    try {
      const owner: string = OfflineCache.account();
      if (owner.length === 0 || owner !== account) {
        return 0;
      }
      const raw = store.getSync(key, '') as string;
      if (raw.length === 0) {
        return 0;
      }
      const box = JSON.parse(raw) as CacheBox;
      return (box !== null && box !== undefined && typeof box.t === 'number') ? box.t : 0;
    } catch (error) {
      return 0;
    }
  }

  /** 清掉某个 key。 */
  static remove(key: string): void {
    const store = OfflineCache.store();
    if (store === null) {
      return;
    }
    try {
      store.deleteSync(key);
      store.flush();
    } catch (error) {
      // 忽略
    }
  }

  /** 全部清掉（换账号 / 退出登录时用）。 */
  static clearAll(account: string): void {
    const store = OfflineCache.store();
    if (store === null) {
      return;
    }
    try {
      const keys: Array<string> = store.getSync(KEY_ACCOUNT, '') as string !== '' ?
        OfflineCache.allKeys(store) : [];
      for (let i = 0; i < keys.length; i++) {
        store.deleteSync(keys[i]);
      }
      // 这批动态 key 已经删掉，登记表也一并清空；否则下次 clearAll 会白删一遍。
      store.deleteSync(KEY_PREFIXED_REGISTRY);
      OfflineCache.prefixedKeys = [];
      store.putSync(KEY_ACCOUNT, account);
      store.flush();
    } catch (error) {
      // 忽略
    }
  }

  /** 列出全部 key（用于换账号时整体作废）。 */
  private static allKeys(store: preferences.Preferences): string[] {
    // Preferences 没有「列所有 key」的同步 API，这里只清已知 key。
    // 固定 key 全列；带 id 的详情页 key 在写入时顺手登记到 REGISTRY（见 registerPrefixed）。
    const result: string[] = OfflineKey.ALL_FIXED.slice();
    const registered: string[] = OfflineCache.registry();
    for (let i = 0; i < registered.length; i++) {
      result.push(registered[i]);
    }
    return result;
  }

  /**
   * 带 id 的详情页 key 登记表（持久化到 Preferences）。
   *
   * Preferences 无法枚举 key，详情页又按 `前缀 + id` 动态生成 key，换账号时若不登记
   * 就会残留上一个账号的详情缓存。写入这类 key 时调 {@link registerPrefixed} 登记一次，
   * `clearAll` 即可一并清掉（重复登记由 indexOf 去重）。
   *
   * `null` 表示尚未从磁盘恢复 —— 首次使用时懒加载，避免每次读写都反序列化整张表。
   */
  private static prefixedKeys: string[] | null = null;

  /** 取登记表：内存没有就从磁盘恢复（冷启动后的第一次登记/清理会走到这里）。 */
  private static registry(): string[] {
    let list: string[] | null = OfflineCache.prefixedKeys;
    if (list === null) {
      let restored: string[] = [];
      const store = OfflineCache.store();
      if (store !== null) {
        try {
          const raw = store.getSync(KEY_PREFIXED_REGISTRY, '') as string;
          if (raw.length > 0) {
            const parsed = JSON.parse(raw) as string[];
            restored = Array.isArray(parsed) ? parsed : [];
          }
        } catch (error) {
          restored = [];
        }
      }
      list = restored;
      OfflineCache.prefixedKeys = list;
    }
    return list ?? [];
  }

  /** 登记一个动态 key（带 id 的详情页写入时调用），并立即落盘。 */
  static registerPrefixed(key: string): void {
    const list: string[] = OfflineCache.registry();
    if (list.indexOf(key) >= 0) {
      return;
    }
    list.push(key);
    const store = OfflineCache.store();
    if (store === null) {
      return;
    }
    try {
      store.putSync(KEY_PREFIXED_REGISTRY, JSON.stringify(list));
      store.flush();
    } catch (error) {
      // 落盘失败不影响本次读取；下次登记会重试写入整张表
    }
  }
}

/** 各功能的缓存 key（统一前缀，便于整体作废）。 */
export class OfflineKey {
  static readonly FINANCE: string = 'off_finance';
  static readonly GRADE: string = 'off_grade';
  static readonly EXAM: string = 'off_exam';
  static readonly CLASSROOM: string = 'off_classroom';

  // ---- 冷启动首帧缓存（PageCache 使用，统一 off_ 前缀） ----
  static readonly HOME: string = 'off_home';
  static readonly MINE_METRICS: string = 'off_mine_metrics';
  static readonly SPOC: string = 'off_spoc';
  static readonly BYKC_COURSES: string = 'off_bykc_courses';
  static readonly BYKC_CHOSEN: string = 'off_bykc_chosen';
  static readonly BYKC_STATISTICS: string = 'off_bykc_statistics';
  static readonly BYKC_DETAIL_PREFIX: string = 'off_bykc_detail_';
  static readonly IHOME_PREFIX: string = 'off_ihome_';
  static readonly IHOME_DETAIL_PREFIX: string = 'off_ihome_detail_';
  static readonly LIB_BOOKINGS: string = 'off_lib_bookings';
  static readonly LIB_RESERVE: string = 'off_lib_reserve';
  static readonly SIGNIN: string = 'off_signin';
  static readonly YGDK: string = 'off_ygdk';
  static readonly EVALUATION: string = 'off_evaluation';
  static readonly JUDGE_PREFIX: string = 'off_judge_';
  static readonly JUDGE_DETAIL_PREFIX: string = 'off_judge_detail_';
  static readonly NETWORK: string = 'off_network';
  static readonly CPRINT_QUEUE: string = 'off_cprint_queue';
  static readonly CPRINT_SCANS: string = 'off_cprint_scans';
  static readonly CPRINT_STATIONS: string = 'off_cprint_stations';
  static readonly CPRINT_RECORDS: string = 'off_cprint_records';
  static readonly USERINFO: string = 'off_userinfo';

  /** 固定 key 的汇总（换账号时整体作废；带 id 的详情页 key 用前缀，见 allKeys）。 */
  static readonly ALL_FIXED: string[] = [
    OfflineKey.FINANCE,
    OfflineKey.GRADE,
    OfflineKey.EXAM,
    OfflineKey.CLASSROOM,
    OfflineKey.HOME,
    OfflineKey.MINE_METRICS,
    OfflineKey.SPOC,
    OfflineKey.BYKC_COURSES,
    OfflineKey.BYKC_CHOSEN,
    OfflineKey.BYKC_STATISTICS,
    OfflineKey.LIB_BOOKINGS,
    OfflineKey.LIB_RESERVE,
    OfflineKey.SIGNIN,
    OfflineKey.YGDK,
    OfflineKey.EVALUATION,
    OfflineKey.NETWORK,
    OfflineKey.CPRINT_QUEUE,
    OfflineKey.CPRINT_SCANS,
    OfflineKey.CPRINT_STATIONS,
    OfflineKey.CPRINT_RECORDS,
    OfflineKey.USERINFO
  ];

  /** 带 id 的详情页 key 前缀（换账号时按前缀清，避免残留别人的详情）。 */
  static readonly PREFIXED: string[] = [
    OfflineKey.BYKC_DETAIL_PREFIX,
    OfflineKey.IHOME_PREFIX,
    OfflineKey.IHOME_DETAIL_PREFIX,
    OfflineKey.JUDGE_PREFIX,
    OfflineKey.JUDGE_DETAIL_PREFIX
  ];
}

/**
 * 把写入时刻格式化成「离线记录 · 更新于 HH:mm」。
 *
 * 没有缓存时返回空串，界面据此不显示标注。
 */
export function offlineNote(savedAtMs: number): string {
  if (savedAtMs <= 0) {
    return '';
  }
  const d = new Date(savedAtMs);
  const hh: string = d.getHours() < 10 ? '0' + d.getHours().toString() : d.getHours().toString();
  const mm: string = d.getMinutes() < 10 ? '0' + d.getMinutes().toString() : d.getMinutes().toString();
  return '离线记录 · 更新于 ' + hh + ':' + mm;
}
