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
      store.putSync(KEY_ACCOUNT, account);
      store.flush();
    } catch (error) {
      // 忽略
    }
  }

  /** 列出全部 key（用于换账号时整体作废）。 */
  private static allKeys(store: preferences.Preferences): string[] {
    // Preferences 没有「列所有 key」的同步 API，这里只清已知前缀。
    // 各页面的 key 都以 `off_` 开头（见下面的常量），换账号时按前缀扫掉。
    const known: string[] = [
      OfflineKey.FINANCE,
      OfflineKey.GRADE,
      OfflineKey.EXAM,
      OfflineKey.CLASSROOM
    ];
    return known;
  }
}

/** 各功能的缓存 key（统一前缀，便于整体作废）。 */
export class OfflineKey {
  static readonly FINANCE: string = 'off_finance';
  static readonly GRADE: string = 'off_grade';
  static readonly EXAM: string = 'off_exam';
  static readonly CLASSROOM: string = 'off_classroom';
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
