import { image } from '@kit.ImageKit';
import { FeatureHero, HERO_BOUNCE_TICK } from './FeatureHero';

/** 快照层变化信号键（MainPage 用它 `@StorageProp` + `@Watch`）。 */
export const KEY_HERO_SNAPSHOT_TICK: string = 'heroSnapshotTick';

/**
 * 「全屏 → 卡片」退场用的**窗口快照**。
 *
 * ## 为什么需要快照
 *
 * 直接缩放 `DestShell` 有两个死结：
 * 1. `HdsNavigation` 在 Stack 模式下只渲染栈顶页，缩放时背后是容器底色（黑），
 *    看不到功能页网格 —— 观感是「内容塌进黑洞」，不是「缩回卡片」；
 * 2. 标题栏是 `HdsNavDestination` 自绘的，在外壳之外，不会跟着缩。
 *
 * 换成**先给整窗截一张图、让这张图缩回卡片**就没这两个问题：
 * 图里本来就含标题栏，而图缩小后露出的是**已经 pop 完的真实功能页**。
 *
 * ## 时序（退场）
 *
 * ```
 * 点返回
 *   → window.snapshot() 截整窗（异步，约 30~60ms）
 *   → show(pm)：快照层盖在内容区之上（侧栏之上不盖，侧栏要一直可见）
 *   → 下一帧 pop 真实页面（快照顶着，用户看不到切换）
 *   → shrink()：快照缩到卡片位置并淡出
 *   → done：移除快照层，通知功能页让原卡片回弹
 * ```
 *
 * 入场**不用快照**：页面背景本身就是纯黑，从卡片放大时露出的那圈「底」与页面
 * 背景同色，看不出来。
 */

/** 快照层当前阶段。 */
export enum SnapshotPhase {
  /** 不显示。 */
  NONE = 0,
  /** 全屏覆盖（pop 期间顶着画面）。 */
  COVER = 1,
  /** 正在缩回卡片。 */
  SHRINK = 2
}

/** 快照层状态（供 MainPage 渲染）。 */
export interface SnapshotState {
  phase: SnapshotPhase;
  /** 缩放中心与目标比例由 FeatureHero 里的最近一次卡片位置算出。 */
  scale: number;
  cx: number;
  cy: number;
}

export class HeroSnapshot {
  private static pixmap: image.PixelMap | null = null;
  private static phase: SnapshotPhase = SnapshotPhase.NONE;
  private static seed: number = 0;

  /**
   * 挂上快照并进入 COVER 阶段。
   *
   * @param pm 整窗快照
   */
  static show(pm: image.PixelMap): void {
    HeroSnapshot.pixmap = pm;
    HeroSnapshot.phase = SnapshotPhase.COVER;
    HeroSnapshot.bump();
  }

  /** 进入 SHRINK 阶段：快照开始缩回卡片。 */
  static startShrink(): void {
    if (HeroSnapshot.phase === SnapshotPhase.NONE) {
      return;
    }
    HeroSnapshot.phase = SnapshotPhase.SHRINK;
    HeroSnapshot.bump();
  }

  /**
   * 结束并释放位图（务必调用，一块全屏 PixelMap 很占内存）。
   *
   * 顺便广播「卡片回弹」：快照缩完 = 用户已经看到自己回到功能页，
   * 此时原卡片弹一下正好接上。
   */
  static clear(): void {
    HeroSnapshot.pixmap = null;
    HeroSnapshot.phase = SnapshotPhase.NONE;
    HeroSnapshot.bump();
    FeatureHero.markBounce(FeatureHero.recentIndex());
    const current: number = AppStorage.get<number>(HERO_BOUNCE_TICK) ?? 0;
    AppStorage.setOrCreate<number>(HERO_BOUNCE_TICK, current + 1);
  }

  static get(): image.PixelMap | null {
    return HeroSnapshot.pixmap;
  }

  static currentPhase(): SnapshotPhase {
    return HeroSnapshot.phase;
  }

  /** 变化计数：MainPage 用它 `@StorageProp` + `@Watch` 感知（PixelMap 不适合直接进 AppStorage）。 */
  static tick(): number {
    return HeroSnapshot.seed;
  }

  private static bump(): void {
    HeroSnapshot.seed = HeroSnapshot.seed + 1;
    AppStorage.setOrCreate<number>(KEY_HERO_SNAPSHOT_TICK, HeroSnapshot.seed);
  }

  static isReady(): boolean {
    return HeroSnapshot.pixmap !== null;
  }
}
