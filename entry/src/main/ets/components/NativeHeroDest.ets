import { HeroCard, NavHero } from '../common/NavHero';
import { FeatureDestBody } from './FeatureDestBody';
import { KEY_HERO_PAGE_OPACITY } from '../common/HeroMorph';
import { HeroDetailLayer } from './HeroDetailLayer';

/**
 * 「卡片展开页」的原生导航外壳。
 *
 * ## 这里**不做**任何几何动画
 *
 * 试过在 NavDestination 的内容上做 `scale` / `translate` 从卡片放大：日志显示动画正常
 * 播完、`@State` 也确实到了终值，但**画面停在初始大小** —— 系统在自定义转场期间冻结了
 * 目的地的渲染。所以几何动画交给 MainPage 里那层普通遮罩（导航外面、不受转场约束），
 * 本组件只负责一件事：按 `heroPageOpacity` 淡入淡出，实现「色块融进页面」的交叉过渡。
 *
 * ## 为什么要等遮罩铺满再淡入
 *
 * 打开时遮罩还小，画面周围是系统保留的**功能页快照**（所以其他卡片可见）；
 * 遮罩长到全屏并开始淡出时，这一页正好淡入到不透明 —— 两者在视觉上接力。
 */
@Component
export struct NativeHeroDest {
  title: string = '';
  /**
   * 是否是「卡片展开页」。
   *
   * 只有功能页的 10 个大按钮是 —— 它们参与「缩回卡片」的转场；
   * 页内二级页（博雅 → 选择课程 等）传 false，返回时走系统默认滑出。
   */
  hero: boolean = false;
  onBack: () => void = () => {};

  /** 标题栏右侧插槽（成绩页的学期切换器）。 */
  @Builder
  emptyTrailing() {
  }

  @BuilderParam trailing: () => void = this.emptyTrailing;

  @Builder
  empty() {
  }

  /**
   * 要渲染哪个路由（`RouteName`）。
   *
   * 内容分派放在 `FeatureDestBody` 里 —— 有些页面需要 `NavPathStack`（博雅、iHome、
   * 图书馆…），而 `@BuilderParam` 是无参的，只能在组件内部把栈传下去。
   */
  routeName: string = '';
  /** 功能页签的导航栈（页内二级页要继续 push）。 */
  stack: NavPathStack = new NavPathStack();

  @BuilderParam content: () => void = this.empty;

  /** 整页透明度：由 MainPage 的遮罩编排推动（0 → 1 打开，1 → 0 收起）。 */
  @StorageProp(KEY_HERO_PAGE_OPACITY) private pageOpacity: number = 1;

  private shellId: number = -1;

  aboutToAppear(): void {
    this.shellId = NavHero.enter(this.hero);
  }

  aboutToDisappear(): void {
    NavHero.leave(this.shellId);
  }

  /** 外部显式给了内容（成绩查询要共享 header 模型，用它自己的 builder）。 */
  contentProvided: boolean = false;
  /** 是否显示本组件自己的标题文字（成绩页整条标题栏交给 trailing）。 */
  titleVisible: boolean = true;

  /**
   * 内容分派：默认按 `routeName` 渲染，特殊页（成绩查询）用外部传入的 builder。
   *
   * ⚠️ 必须有它：`HeroDetailLayer` 有两个 `@BuilderParam`，调用时只能用命名参数，
   * 不能写尾随闭包。
   */
  @Builder
  bodyBuilder() {
    if (this.contentProvided) {
      this.content()
    } else {
      FeatureDestBody({ name: this.routeName, stack: this.stack })
    }
  }

  /** 当前这次点击的卡片（取它的颜色给彩色层；可能为空）。 */
  private cardColor(): string {
    const card: HeroCard | null = NavHero.peekCard();
    return card === null ? '#1976D2' : card.color;
  }

  build() {
    Column() {
      Column() {
      HeroDetailLayer({
        title: this.title,
        titleVisible: this.titleVisible,
        // 原生导航不需要共享元素配对（几何由遮罩演），给一个不会有对手的 id
        heroId: 'navHeroDest_' + this.shellId,
        accent: this.cardColor(),
        // 页面内容始终是「完整页面」：交叉过渡靠整页透明度 + 遮罩
        contentOpacity: 1,
        accentOpacity: 0,
        corner: 0,
        topInset: 0,
        fullHeight: 0,
        transX: 0,
        transY: 0,
        scaleX: 1,
        scaleY: 1,
        // ⚠️ 传 @Builder 必须用箭头函数包一层（见下），否则 this 丢失、内容空白
        trailing: (): void => { this.trailing(); },
        // ⚠️ 组件有两个 @BuilderParam 时**不能**用尾随闭包（编译报
        // 「must have one and only one property decorated with @BuilderParam」），
        // 必须用命名参数传一个 @Builder。
        content: (): void => { this.bodyBuilder(); },
        onBack: () => {
          this.onBack();
        }
      })
      }
      .width('100%')
      .height('100%')
      // 「页面快照」取景点（MainPage 在 PUSH/POP 时 componentSnapshot.get）。
      // ⚠️ 必须挂在 pageOpacity **之内**：打开时外层是 0（页面不可见），
      // 连外层一起拍只会拍到一张全透明图；内层永远正常渲染，拍它才拿得到
      // 「加载中/已加载」的真实画面。
      .id('heroPageShot')
    }
    .width('100%')
    .height('100%')
    // 非展开页恒为 1：否则上一次展开留下的 0 会让它整页透明
    .opacity(this.hero ? this.pageOpacity : 1)
  }
}
