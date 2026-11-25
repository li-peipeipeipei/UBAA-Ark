import { TokenStore } from '../network/TokenStore';
import { Logger } from './Logger';
import { OfflineCache } from './OfflineCache';

/**
 * 页面首帧缓存（stale-while-revalidate）。
 *
 * ## 解决什么问题
 *
 * 冷启动时各页面首帧是 `LoadState.LOADING` → 转圈/空白，要等网络往返才有内容。
 * 这里统一把「上次成功加载的数据」持久化到磁盘，页面 `aboutToAppear` 同步读出，
 * 首帧即渲染真实内容，同时后台照常拉新数据，回来后无缝覆盖。
 *
 * ## 与 OfflineCache / MemoCache 的分工
 *
 * - `MemoCache`：纯内存、进程内 TTL + 单飞，冷启动失效。解决「同一进程重复请求」。
 * - `OfflineCache`：Preferences 持久化、按账号隔离，**无 TTL**（永不超时）。
 *   供财务/成绩等「离线可用的历史记录」使用，页面自己判断何时写。
 * - 本类：**在 OfflineCache 之上加 TTL 与泛型封装**，供所有页面首帧直读。
 *   短期缓存（今日课程/签到/座位）设短 TTL，长期（学籍信息）设长 TTL。
 *   过期缓存不渲染（返回 null），避免冷启动第一天就显示昨天过期数据。
 *
 * ## 为什么是同步 API
 *
 * `aboutToAppear` 里必须同步拿到数据填 `@State`，首帧才有内容。Preferences 的
 * `getSync` 满足这一点。异步读取会退化成「先空一帧再填」，视觉上仍是闪一下。
 *
 * ## 账号隔离
 *
 * 全部委托 `OfflineCache`（它按 `schoolId` 作废）。写 key 时传当前账号。
 */
export class PageCache {
  /** 默认 TTL：24 小时。适合「学籍信息」这类几乎不变的数据。 */
  static readonly TTL_DAY: number = 24 * 60 * 60 * 1000;
  /** 短 TTL：3 小时。适合「今日课程 / 签到 / 座位」等当天有效的数据。 */
  static readonly TTL_SHORT: number = 3 * 60 * 60 * 1000;
  /** 中 TTL：12 小时。适合作业列表 / 成绩 / 公告等半天内有意义的数据。 */
  static readonly TTL_HALF_DAY: number = 12 * 60 * 60 * 1000;

  /** 当前账号（学号）；未登录返回空串，缓存操作直接跳过。 */
  static account(): string {
    try {
      return TokenStore.getSession().schoolId;
    } catch (error) {
      return '';
    }
  }

  /**
   * 读缓存。返回的数组/对象可直接赋给 `@State`。
   *
   * @param key 缓存键（OfflineKey 中的常量）
   * @param ttlMs 有效期；超时或账号不符返回 null
   */
  static load<T>(key: string, ttlMs: number = PageCache.TTL_DAY): T | null {
    const account: string = PageCache.account();
    if (account.length === 0) {
      return null;
    }
    // TTL 用写入时刻判断，读起来便宜；savedAt 返回 0 表示无缓存
    const savedAt: number = OfflineCacheBridge.savedAt(key, account);
    if (savedAt <= 0 || Date.now() - savedAt > ttlMs) {
      return null;
    }
    const raw: Object | null = OfflineCacheBridge.load(key, account);
    if (raw === null) {
      return null;
    }
    return raw as T;
  }

  /**
   * 写缓存（后台数据成功后调用）。
   *
   * @param key 缓存键
   * @param value 纯数据对象（interface / 数组，不含函数与 class 实例）
   * @param prefixed 是否为带 id 的动态 key（详情页）；是则登记以便换账号清理
   */
  static save(key: string, value: Object, prefixed: boolean = false): void {
    const account: string = PageCache.account();
    if (account.length === 0) {
      return;
    }
    OfflineCacheBridge.save(key, value, account);
    if (prefixed) {
      OfflineCacheBridge.registerPrefixed(key);
    }
  }

  /** 缓存写入时刻（0 = 无缓存），用于界面标注「更新于 HH:mm」。 */
  static savedAt(key: string): number {
    const account: string = PageCache.account();
    if (account.length === 0) {
      return 0;
    }
    return OfflineCacheBridge.savedAt(key, account);
  }

  /** 清掉某个 key（数据被用户主动删除时调用，避免再显示旧内容）。 */
  static remove(key: string): void {
    OfflineCacheBridge.remove(key);
  }
}

/**
 * 对 OfflineCache 的静态转发。
 *
 * 单独抽一层是为了避免 PageCache 直接 import OfflineCache 时，
 * 两个文件的循环引用（OfflineCache 不 import 任何页面模块，这里仅单向依赖）。
 * 同时集中处理「Preferences 不可用时静默降级」——读缓存永远不能影响页面本身。
 */
class OfflineCacheBridge {
  static load(key: string, account: string): Object | null {
    try {
      return OfflineCache.load(key, account);
    } catch (error) {
      Logger.warn('PageCache 读取失败：' + (error as Error).message);
      return null;
    }
  }

  static save(key: string, value: Object, account: string): void {
    try {
      OfflineCache.save(key, value, account);
    } catch (error) {
      Logger.warn('PageCache 写入失败：' + (error as Error).message);
    }
  }

  static savedAt(key: string, account: string): number {
    try {
      return OfflineCache.savedAt(key, account);
    } catch (error) {
      return 0;
    }
  }

  static remove(key: string): void {
    try {
      OfflineCache.remove(key);
    } catch (error) {
      // 忽略
    }
  }

  static registerPrefixed(key: string): void {
    try {
      OfflineCache.registerPrefixed(key);
    } catch (error) {
      // 忽略
    }
  }
}
