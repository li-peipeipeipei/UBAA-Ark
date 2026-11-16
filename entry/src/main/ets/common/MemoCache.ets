/**
 * 轻量内存缓存：**TTL + 单飞（single-flight）**。
 *
 * ## 解决什么问题
 *
 * 冷启动时首页与课表页会各自去拉「学期 / 周次 / 本周课表」—— 同一份数据在一个进程里
 * 被请求两三遍。除了多花流量，更要紧的是它们**共用同一个 Cookie 罐**：
 * 并发请求各自「整罐读 → 改 → 整罐写」，后写的会盖掉前者新增的 Cookie。
 *
 * 这里把「同一个 key 的并发请求」合并成一次（单飞），再给结果一个短 TTL，
 * 让后来的调用方直接复用。
 *
 * ## 为什么不在页面各自缓存
 *
 * 页面的生命周期与数据归属不一致（首页常驻、课表页按周切换、二级页反复进出）。
 * 缓存放在服务层，谁调用都命中同一份，且失效点只有一个。
 *
 * ## 什么时候必须 `force`
 *
 * 用户**显式**要求刷新时（下拉刷新、点重试、切周比对）必须传 `force = true`，
 * 否则会拿到 TTL 内的旧值，表现为「下拉了但没变化」。
 */
interface MemoEntry {
  value: Object;
  /** 到期时刻（epoch ms）。 */
  expireAt: number;
}

export class MemoCache {
  /**
   * 条目上限。超过就顺手清掉已过期的。
   *
   * 正常的 key 数量是有界的（学期数 × 周数 + 若干当日 key），但「周课表」一类条目
   * 单个就有几十 KB —— 用户滑遍整个学期、再翻几个学期，内存会明显涨。
   * 这里不追求精确 LRU，只在超过上限时回收过期项，足够。
   */
  private static readonly MAX_ENTRIES: number = 32;

  private static entries: Map<string, MemoEntry> = new Map<string, MemoEntry>();
  private static inflight: Map<string, Promise<Object>> = new Map<string, Promise<Object>>();

  /**
   * 读缓存；没有/过期/强制刷新时调 `loader`，并把结果写回。
   *
   * 同一 key 并发调用只会真正执行一次 `loader`，其余调用方 await 同一个 Promise。
   */
  static async through<T>(key: string, ttlMs: number, loader: () => Promise<Object>,
    force: boolean = false): Promise<T> {
    if (!force) {
      const hit: MemoEntry | undefined = MemoCache.entries.get(key);
      if (hit !== undefined && hit.expireAt > Date.now()) {
        return hit.value as T;
      }
      const running: Promise<Object> | undefined = MemoCache.inflight.get(key);
      if (running !== undefined) {
        return await running as T;
      }
    }
    const task: Promise<Object> = loader();
    MemoCache.inflight.set(key, task);
    try {
      const value: Object = await task;
      MemoCache.entries.set(key, { value: value, expireAt: Date.now() + ttlMs } as MemoEntry);
      MemoCache.prune();
      return value as T;
    } finally {
      // 失败也要摘掉，否则一次网络错误会让这个 key 永远「在途」。
      // ⚠️ 只在「还是自己这一发」时才摘：`force` 会让同一 key 起第二个请求，
      // 先完成的旧请求若无条件删除，会把新请求的在途标记也抹掉。
      if (MemoCache.inflight.get(key) === task) {
        MemoCache.inflight.delete(key);
      }
    }
  }

  /** 预热：直接写入一份结果（预取器用它把数据塞进缓存）。 */
  static put(key: string, value: Object, ttlMs: number): void {
    MemoCache.entries.set(key, { value: value, expireAt: Date.now() + ttlMs } as MemoEntry);
    MemoCache.prune();
  }

  /** 超过上限时回收：先清过期项，还不够就按插入顺序丢最旧的（Map 保证插入顺序）。 */
  private static prune(): void {
    if (MemoCache.entries.size <= MemoCache.MAX_ENTRIES) {
      return;
    }
    const now: number = Date.now();
    const keys: string[] = [];
    MemoCache.entries.forEach((entry: MemoEntry, key: string) => {
      keys.push(key);
    });
    // 第一轮：过期项
    for (let i = 0; i < keys.length; i++) {
      const entry: MemoEntry | undefined = MemoCache.entries.get(keys[i]);
      if (entry !== undefined && entry.expireAt <= now) {
        MemoCache.entries.delete(keys[i]);
      }
    }
    // 第二轮：仍超上限就丢最旧的
    let index: number = 0;
    while (MemoCache.entries.size > MemoCache.MAX_ENTRIES && index < keys.length) {
      MemoCache.entries.delete(keys[index]);
      index++;
    }
  }

  /** 是否有仍然新鲜的缓存（不触发加载）。 */
  static fresh(key: string): boolean {
    const hit: MemoEntry | undefined = MemoCache.entries.get(key);
    return hit !== undefined && hit.expireAt > Date.now();
  }

  /**
   * 全部清空。
   *
   * **登出 / 切换连接模式必须调用**：两种模式的 Cookie 完全不同，
   * 缓存里存的是上一个账号（甚至另一个网络环境）的数据。
   */
  static clear(): void {
    MemoCache.entries.clear();
    MemoCache.inflight.clear();
  }
}
