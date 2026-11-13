/**
 * 「彩色功能块 → 全屏」的变形转场。
 *
 * ## 效果
 *
 * 点击卡片时，**卡片本身**（同一个颜色、同一个圆角）从它在网格里的位置放大到全屏，
 * 圆角一路收到 0；放大的同时，真实页面从 0 逐渐淡入压在色块上，两者交叉过渡 ——
 * 观感就是「这张彩色卡片展开成了这一页」。
 *
 * 返回时反向：页面淡出露出彩色层，彩色层缩回卡片位置、圆角复原。
 *
 * ## 为什么用纯色块而不是页面缩放
 *
 * `HdsNavigation` 在栈模式下只渲染栈顶页，缩放页面时背后是黑的；标题栏又是
 * `HdsNavDestination` 自绘的，不跟外壳一起缩。用一块**不透明纯色**做载体就没这些问题：
 * 它天然盖住一切，能精确对准卡片矩形，也不需要截图（截图有 30~60ms 延迟）。
 *
 * ## 时序
 *
 * ```
 * 入场（约 420ms）
 *   t=0    色块出现在卡片矩形（卡片色 / 卡片圆角）、页面 opacity=0
 *   t=0→320  色块放大到全屏、圆角→0、颜色→页面底色
 *   t=180→400  页面 opacity 0→1（交叉）
 *   t=400  移除色块
 *
 * 退场（约 470ms）
 *   t=0    色块出现在全屏（页面底色）、页面 opacity 1
 *   t=0→150  页面淡出到 0
 *   t=150  pop 真实页面（色块顶着）
 *   t=150→470  色块缩回卡片矩形、圆角复原、颜色→卡片色
 *   t=470  移除色块 + 原卡片回弹
 * ```
 */

/** 一个矩形（含圆角），单位 vp。 */
export interface MorphRect {
  x: number;
  y: number;
  w: number;
  h: number;
  radius: number;
}

export enum MorphPhase {
  IDLE = 0,
  EXPAND = 1,
  SHRINK = 2
}

/** 转场色块状态变化信号。 */
export const KEY_MORPH_TICK: string = 'heroMorphTick';

/** 页面整体透明度的共享键：DestShell 绑它，MainPage 在转场里推它。 */
export const KEY_HERO_PAGE_OPACITY: string = 'heroPageOpacity';

export class HeroMorph {
  private static phase: MorphPhase = MorphPhase.IDLE;
  private static color: string = '#1976D2';
  private static card: MorphRect = { x: 0, y: 0, w: 0, h: 0, radius: 0 };
  /** 卡片在网格里的序号（退场后回弹用）。 */
  private static cardIndex: number = -1;
  private static seed: number = 0;

  /** 入场：记下卡片颜色与矩形，并广播。调用方紧接着 push（硬切）。 */
  static startExpand(color: string, card: MorphRect, index: number): void {
    HeroMorph.color = color;
    HeroMorph.card = card;
    HeroMorph.cardIndex = index;
    HeroMorph.phase = MorphPhase.EXPAND;
    HeroMorph.bump();
  }

  /** 退场：用上次记下的卡片矩形反向缩回。 */
  static startShrink(): void {
    if (HeroMorph.card.w <= 0) {
      return;
    }
    HeroMorph.phase = MorphPhase.SHRINK;
    HeroMorph.bump();
  }

  /** 转场结束（色块消失）。 */
  static finish(): void {
    HeroMorph.phase = MorphPhase.IDLE;
    HeroMorph.bump();
  }

  static getPhase(): MorphPhase {
    return HeroMorph.phase;
  }

  static getColor(): string {
    return HeroMorph.color;
  }

  static getCard(): MorphRect {
    return HeroMorph.card;
  }

  static getCardIndex(): number {
    return HeroMorph.cardIndex;
  }

  static tick(): number {
    return HeroMorph.seed;
  }

  private static bump(): void {
    HeroMorph.seed = HeroMorph.seed + 1;
    AppStorage.setOrCreate<number>(KEY_MORPH_TICK, HeroMorph.seed);
  }
}
