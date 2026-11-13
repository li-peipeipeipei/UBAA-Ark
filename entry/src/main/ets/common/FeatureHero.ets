/**
 * 功能块 → 全屏详情的转场控制器（「卡片放大 / 缩回卡片」）。
 *
 * ## 为什么需要这层
 *
 * ArkUI 跨页面拿不到对方节点（`NavigationTransitionProxy` 只给信息对象），
 * `geometryTransition` 又只在同一组件树内生效 —— 做不到 iOS 那种真正的共享元素。
 *
 * 等效做法：**点击时记住卡片的中心与宽度，让二级页以「卡片大小的缩放态 + 卡片位置」
 * 出现，再放大到 1**。视觉上是「从卡片长出来」。
 *
 * 详见 docs/tech/feature-tile-transition.md。
 *
 * ## 职责
 *
 * 1. 存 / 取一次性的入场原点（`setOrigin` → `takeOrigin`）；
 * 2. 退场协调：页面请求退场时先记下「做完之后再干什么」，等外壳播完缩小动画再执行；
 * 3. 回弹通知：退场完成后告诉功能页「刚回去的是第几张卡片」。
 */

/** 卡片在内容区坐标系里的位置与尺寸（vp）。 */
export interface HeroOrigin {
  /** 卡片中心 X（相对内容区原点；横屏时已扣掉侧栏）。 */
  cx: number;
  /** 卡片中心 Y（相对内容区原点，含状态栏与页内边距）。 */
  cy: number;
  /** 卡片宽度 —— 用来算入场首帧的缩放比例。 */
  w: number;
  /** 这张卡在网格里的序号，退场后据此让原卡片回弹。 */
  index: number;
}

/** 退场动画的兜底超时（ms）：动画没播完也必须放行，不能让用户卡在页面上。 */
export const EXIT_TIMEOUT_MS: number = 320;

/** 请求退场的信号键：外壳 `@StorageProp` 它，收到就播缩小动画。 */
export const HERO_EXIT_TICK: string = 'featureHeroExitTick';

/** 退场完成、卡片该回弹的信号键：功能页收到就让原卡片弹一下。 */
export const HERO_BOUNCE_TICK: string = 'featureHeroBounceTick';

/** 退场请求的等待项。 */
interface ExitRequest {
  callback: () => void;
  /** 已请求退场的页面 index，用来避免重复触发。 */
  stamp: number;
}

export class FeatureHero {
  private static origin: HeroOrigin | null = null;
  private static pending: ExitRequest | null = null;
  private static stampSeed: number = 0;
  private static bounceIndex: number = -1;

  /** 记住最近一次点击的卡片序号（退场回弹用，取 origin 时不清它）。 */
  private static lastIndex: number = -1;

  /** 记录本次点击的卡片位置（在 `push` 之前调用）。 */
  static setOrigin(index: number, cx: number, cy: number, w: number): void {
    FeatureHero.origin = { cx: cx, cy: cy, w: w, index: index };
    FeatureHero.lastIndex = index;
    FeatureHero.lastOrigin = FeatureHero.origin;
  }

  /** 最近一次点击的卡片位置（快照缩回卡片时要用，不随 `takeOrigin` 清空）。 */
  private static lastOrigin: HeroOrigin | null = null;

  static recentOrigin(): HeroOrigin | null {
    return FeatureHero.lastOrigin;
  }

  /** 取走入场原点：**只取一次**，取完即清，保证返回时不会重播入场动画。 */
  static takeOrigin(): HeroOrigin | null {
    const value: HeroOrigin | null = FeatureHero.origin;
    FeatureHero.origin = null;
    return value;
  }

  static hasOrigin(): boolean {
    return FeatureHero.origin !== null;
  }

  /**
   * 请求退场：记下「缩小动画播完之后要做的事」，并通知当前外壳开始播。
   *
   * @param callback 真正的 pop / clear，由外壳在动画结束时回调
   * @returns 是否接管了本次退出（false = 没有可播动画的页面，调用方应立即执行）
   */
  static requestExit(callback: () => void): boolean {
    if (!FeatureHero.origin && FeatureHero.pending === null) {
      // 没有正在进行的 hero 场景也能接管（返回时页面确实在），
      // 由外壳决定是否播动画 —— 这里一律接管，保证「返回 = 缩回卡片」的观感统一。
    }
    if (FeatureHero.pending !== null) {
      // 上一次还没演完：直接放行上一次（用户可能连点返回）
      const stale: () => void = FeatureHero.pending.callback;
      FeatureHero.pending = null;
      stale();
    }
    FeatureHero.stampSeed = FeatureHero.stampSeed + 1;
    FeatureHero.pending = { callback: callback, stamp: FeatureHero.stampSeed };
    return true;
  }

  /** 当前是否有等待中的退场（外壳据此决定播不播缩小动画）。 */
  static isExiting(): boolean {
    return FeatureHero.pending !== null;
  }

  /** 外壳播完缩小动画后调用：执行真正的 pop / clear。 */
  static completeExit(): void {
    const request: ExitRequest | null = FeatureHero.pending;
    FeatureHero.pending = null;
    if (request !== null) {
      request.callback();
    }
  }

  /** 放弃当前退场（例如动画期间用户又点了别的卡片）。 */
  static cancelExit(): void {
    FeatureHero.pending = null;
  }

  /* ---------------- 外壳登记：决定「谁来演退场动画」 ---------------- */

  /**
   * 已挂载的二级页外壳（按挂载顺序）。
   *
   * 退场动画只能由**栈顶那一页**来演：如果所有外壳都响应，下面那些页也会一起缩小，
   * pop 之后它们变成可见页时就是缩小状态，画面会错乱。
   */
  private static shells: number[] = [];
  private static shellSeed: number = 0;

  /** 外壳挂载：返回自己的 id。 */
  static enterShell(): number {
    FeatureHero.shellSeed = FeatureHero.shellSeed + 1;
    FeatureHero.shells.push(FeatureHero.shellSeed);
    return FeatureHero.shellSeed;
  }

  static leaveShell(id: number): void {
    const index: number = FeatureHero.shells.indexOf(id);
    if (index >= 0) {
      FeatureHero.shells.splice(index, 1);
    }
  }

  /** 是否是当前最上层的二级页外壳。 */
  static isTopShell(id: number): boolean {
    if (FeatureHero.shells.length === 0) {
      return false;
    }
    return FeatureHero.shells[FeatureHero.shells.length - 1] === id;
  }

  static hasShell(): boolean {
    return FeatureHero.shells.length > 0;
  }

  /** 广播退场信号：栈顶外壳收到后开始播缩小动画。 */
  static signalExit(): void {
    const current: number = AppStorage.get<number>(HERO_EXIT_TICK) ?? 0;
    AppStorage.setOrCreate<number>(HERO_EXIT_TICK, current + 1);
  }

  /** 记录「刚回去的是第几张卡片」，供功能页播一次回弹。 */
  static markBounce(index: number): void {
    if (index >= 0) {
      FeatureHero.bounceIndex = index;
    }
  }

  /** 最近一次点击的卡片序号（-1 = 没有）。 */
  static recentIndex(): number {
    return FeatureHero.lastIndex;
  }

  /** 取走回弹目标（取完即清）。 */
  static takeBounce(): number {
    const value: number = FeatureHero.bounceIndex;
    FeatureHero.bounceIndex = -1;
    return value;
  }
}
