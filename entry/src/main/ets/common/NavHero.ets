import { Logger } from './Logger';

/**
 * 功能块 → 全屏页的转场状态中枢（原生 Navigation 版）。
 *
 * ## 为什么需要它
 *
 * 原生 `Navigation` 的 `customNavContentTransition` 只给我们一个 `proxy`：
 * 它能「结束」转场，但**拿不到任何节点引用**。所以要动画面，只能由目的地页面
 * 自己驱动自己的 `@State`，而「点的是哪张卡、卡片在哪、什么颜色」这些信息
 * 必须在两个组件之间传 —— 本文件就是这个信箱。
 *
 * ## 一次完整的往返
 *
 * ```
 * 点卡片（FeaturePage）
 *   NavHero.setCard(rect)  →  pushPath(animated = true)
 *     ↓ 系统回调 customNavContentTransition(PUSH) → NavHero.holdProxy(proxy)
 * 目的地（NativeHeroDest）量到自己的盒子 → 从卡片矩形放大 → NavHero.finishTransition()
 *     ↓
 * 返回：pop(true)
 *     ↓ 系统回调 customNavContentTransition(POP) → NavHero.beginClose()
 * 目的地收到 close 信号 → 缩回卡片矩形 → NavHero.finishTransition() + 广播回弹
 * ```
 *
 * ⚠️ 顺序上有两个「必须先记下来」的点：
 * 1. `proxy` 必须存住 —— 目的地动画播完才知道什么时候结束；
 * 2. 卡片矩形必须在 push 之前写入 —— 目的地在 `aboutToAppear` 里就要读它做首帧。
 */

/** 被点的卡片：屏幕坐标矩形 + 实际显示色 + 序号。 */
/** 目的地登记项（用于判断栈顶是不是「卡片展开页」）。 */
export interface ShellEntry {
  id: number;
  hero: boolean;
}

export interface HeroCard {
  x: number;
  y: number;
  w: number;
  h: number;
  /** 卡片圆角（vp）。展开时由它插值到 0。 */
  radius: number;
  /** 卡片**实际显示**的颜色（半透明主色叠材质后的结果），不是主色本身。 */
  color: string;
  /** 在网格里的序号，收起后据此让原卡片回弹。 */
  index: number;
}

/** 请求目的地收起（返回 / 点页签都走这条）。 */
export const KEY_HERO_CLOSE: string = 'navHeroCloseTick';
/** 目的地数据已变更、请原卡片先显示出来（收缩开始时）。 */
export const KEY_HERO_TILE_SHOW: string = 'navHeroTileShowTick';
/** 收缩落地：原卡片回弹一次。 */
export const KEY_HERO_TILE_BOUNCE: string = 'navHeroTileBounceTick';

export class NavHero {
  /**
   * 支持「卡片展开」的路由名。
   *
   * 只有这些路由的 PUSH/POP 才由我们接管转场，其余（博雅子页、设置…）走系统默认 ——
   * 否则一旦点过一次卡片，后面任何 push 都会被误判成「从卡片展开」。
   * 铺开到全部入口时，这里逐个加名字即可。
   */
  private static heroRoutes: string[] = [
    'exam', 'grade', 'classroom', 'signin', 'evaluation',
    'spoc', 'ygdk', 'ihome', 'bykc', 'libbookHome', 'finance', 'network'
  ];

  static isHeroRoute(name: string): boolean {
    return NavHero.heroRoutes.indexOf(name) >= 0;
  }

  /** 本次点击的卡片（push 之前写入，收起时还要再用一次）。 */
  private static card: HeroCard | null = null;

  /** 系统给的转场代理，等目的地动画结束后由它收尾。 */
  private static proxy: NavigationTransitionProxy | null = null;

  /**
   * 已挂载的目的地表（按挂载顺序，最后一个才是栈顶）。
   *
   * 必须登记**所有**目的地，而不只是「卡片展开页」：博雅 → 选择课程 这种页内二级页
   * 也在同一个栈里，pop 它时栈顶就不是展开页了。只看「有没有展开页」会把二级页的
   * 返回也误判成卡片收起（会自动缩放到某张卡，明显错误）。
   */
  private static shells: ShellEntry[] = [];
  private static seed: number = 0;

  /* ---------------- 卡片 ---------------- */

  static setCard(card: HeroCard): void {
    NavHero.card = card;
  }

  /** 读卡片矩形（不清空 —— 收起时还要用）。 */
  static peekCard(): HeroCard | null {
    return NavHero.card;
  }

  static hasCard(): boolean {
    return NavHero.card !== null;
  }

  /* ---------------- 展开页挂载登记 ---------------- */

  /** 目的地挂载：返回自己的 id（hero 标记它是不是「卡片展开页」）。 */
  static enter(hero: boolean): number {
    NavHero.seed = NavHero.seed + 1;
    const entry: ShellEntry = { id: NavHero.seed, hero: hero };
    NavHero.shells.push(entry);
    return NavHero.seed;
  }

  static leave(id: number): void {
    for (let i: number = NavHero.shells.length - 1; i >= 0; i--) {
      if (NavHero.shells[i].id === id) {
        NavHero.shells.splice(i, 1);
        return;
      }
    }
  }

  /** 是否是当前栈顶的展开页。 */
  static isTop(id: number): boolean {
    if (NavHero.shells.length === 0) {
      return false;
    }
    return NavHero.shells[NavHero.shells.length - 1].id === id;
  }

  /** 栈顶是不是「卡片展开页」—— 决定 POP 要不要演「缩回卡片」。 */
  static isTopHero(): boolean {
    if (NavHero.shells.length === 0) {
      return false;
    }
    return NavHero.shells[NavHero.shells.length - 1].hero;
  }

  /* ---------------- 转场代理 ---------------- */

  /**
   * 存住系统的转场代理。
   *
   * 上一个如果还没收尾（极端情况：连续 push/pop），先把它结束掉 ——
   * 否则系统会一直等，界面卡在「转场中」不可交互。
   */
  static holdProxy(proxy: NavigationTransitionProxy): void {
    if (NavHero.proxy !== null) {
      NavHero.proxy.finishTransition();
    }
    NavHero.proxy = proxy;
    Logger.info('HERO proxy held');
  }

  /** 动画播完：告诉系统这次转场结束。 */
  static finishTransition(): void {
    const had: boolean = NavHero.proxy !== null;
    if (NavHero.proxy !== null) {
      NavHero.proxy.finishTransition();
      NavHero.proxy = null;
    }
    Logger.info('HERO finishTransition hadProxy=' + had);
  }

  /* ---------------- 信号 ---------------- */

  /** 请求收起：目的地收到后开始缩回卡片。 */
  static beginClose(): void {
    NavHero.bump(KEY_HERO_CLOSE);
    // 收缩一开始就把原卡片放出来：此时画面还是全屏不透明的页面，看不到变化；
    // 等收缩到卡片位置时它已经在那里了，落点才不会「先空一块再冒出来」。
    NavHero.bump(KEY_HERO_TILE_SHOW);
  }

  /** 收缩开始：让原卡片先显示出来（遮罩盖着，看不到变化）。 */
  static notifyTileShow(): void {
    NavHero.bump(KEY_HERO_TILE_SHOW);
  }

  /** 收缩落地：让原卡片弹一下。 */
  static notifyBounce(): void {
    NavHero.bump(KEY_HERO_TILE_BOUNCE);
  }

  private static bump(key: string): void {
    const current: number = AppStorage.get<number>(key) ?? 0;
    AppStorage.setOrCreate<number>(key, current + 1);
  }

  /** 初始化三个信号键（EntryAbility 启动时调用一次）。 */
  static initKeys(): void {
    AppStorage.setOrCreate<number>(KEY_HERO_CLOSE, 0);
    AppStorage.setOrCreate<number>(KEY_HERO_TILE_SHOW, 0);
    AppStorage.setOrCreate<number>(KEY_HERO_TILE_BOUNCE, 0);
  }
}
