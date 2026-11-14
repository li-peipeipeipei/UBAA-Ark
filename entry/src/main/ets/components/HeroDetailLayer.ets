import { AppColor, AppFont } from './AppTheme';
import { topSafeInsetVp } from '../common/ImmersiveUtil';

/**
 * 功能页「卡片展开」用的自绘详情外壳。
 *
 * ## 为什么不用 HdsNavDestination
 *
 * 共享元素（`geometryTransition`）只在**同一棵组件树**内生效，而 `HdsNavDestination`
 * 把转场完全封装了：实测它在 NavDestination 之间不生效，`customNavContentTransition`
 * 也不会被 HDS 回调出来（两个都验证过）。
 *
 * 所以卡片展开的详情页不走导航，直接在功能页里用浮层渲染 —— 同树内系统才会接管
 * 「这张卡片长成这一页」的几何过渡（含圆角同步）。
 *
 * ## 两层结构（「渐变至功能页本身」的关键）
 *
 * ```
 * Stack（绑定 geometryTransition，随系统几何放大 / 缩小，圆角同步）
 * ├─ 彩色层：卡片本身的颜色，不透明度 0.92 —— 放大时看到的是「这张卡在长大」
 * └─ 页面层：标题栏 + 页面内容，opacity 由父级推动 0→1
 * ```
 *
 * 入场：彩色层先长大，页面层稍后淡入 —— 观感是「彩色卡片展开并变成页面」。
 * 退场：页面层先淡出露出彩色层，再缩回卡片。
 *
 * ## 与 HDS 标题栏的视觉对齐
 *
 * 自绘标题栏刻意复刻 HDS 的排版：84vp 高、返回按钮 40vp 圆、标题 24vp Bold、
 * 左侧 24vp 边距 —— 展开后看不出外壳换过。
 */
@Component
export struct HeroDetailLayer {
  title: string = '';
  /**
   * 共享元素 id —— 与点击的那张卡片一致。
   *
   * ⚠️ 必须写在组件**内部**的根节点上：`@BuilderParam` 尾随闭包之后不能再接属性链
   * （`Component({...}) { }.geometryTransition(...)` 会直接编译报错）。
   */
  heroId: string = '';
  /** 卡片实际显示的颜色（半透明主色叠材质后的结果），展开的起点色。 */
  accent: string = '#1976D2';
  /** 页面层透明度：0 = 只有彩色层；1 = 完全是页面。由父级在转场里推动。 */
  @Prop contentOpacity: number = 0;
  /**
   * 彩色层透明度：展开时很快褪去、收起时很晚才浮现。
   *
   * 和 `contentOpacity` 分开控制，才能做出「颜色先走、内容后到」的错峰感：
   * 展开 → 颜色 0~180ms 褪完、页面 40~280ms 淡入；
   * 收起 → 页面先淡出、收势过半时颜色才回来。
   */
  @Prop accentOpacity: number = 1;
  /**
   * 需要向上抵消的外壳避让（vp）。
   *
   * 本组件挂在功能页内部，而功能页已被 `HdsNavigation` 避让掉「状态栏 + MINI 标题栏」。
   * 展开页要盖到屏幕顶，所以用负 margin 抵回来 —— 用 margin 而不是 offset：
   * offset / translate 只改绘制不改布局，点击会错位。
   */
  topInset: number = 0;
  /** 整窗高度（抵消避让后要补回这段高度，否则底部缺一截）。 */
  fullHeight: number = 0;
  /**
   * 视觉圆角（vp）：展开时由卡片圆角插值到 0，收起时反过来。
   *
   * 系统的共享元素**不会**跨 TabContent 同步圆角（实测两次，过渡中始终是直角），
   * 所以圆角改由父级的 animateTo 驱动，由三层子节点各自裁剪出形状。
   * 注意只能加在**子层**上：加在绑定 geometryTransition 的根节点会连带 clip，
   * 那会让整个几何动画失效（踩过）。
   */
  @Prop corner: number = 0;
  /**
   * 收起时自己缩小的比例与中心（1 = 全屏）。
   *
   * 不依赖系统的 out 过渡：`geometryTransition` 的 out 阶段会强制让离场组件**淡出**，
   * 并按终值渲染圆角 —— 所以收起时既「透」又「直角」，参数改不动。
   * 改为保持浮层在场、用 scale 自己缩回卡片，最后再一次性切走（此刻两者已完全重合）。
   */
  @Prop shrinkScale: number = 1;
  /**
   * 收起时的平移量（vp，相对自身原位）。
   *
   * 不用 `scale` 的 centerX/centerY 做定位：本组件的布局盒被负 margin 上移过，
   * center 的坐标系和屏幕坐标对不上（会缩到屏幕右下角去，实测过）。
   * 改成「默认中心缩放 + 纯平移」：缩放后中心不动，再把它平移到卡片中心，
   * 两个量各自独立、与布局盒无关。
   */
  @Prop shrinkTx: number = 0;
  @Prop shrinkTy: number = 0;

  onBack: () => void = () => {};

  @Builder
  empty() {
  }

  @BuilderParam content: () => void = this.empty;

  build() {
    Stack() {
      // ① 中性底：收起过程中先露出「形状」，颜色稍后才回来
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(AppColor.pageBackground)
        .borderRadius(this.corner)

      // ② 彩色层：展开时快速褪去，收起时较晚浮现（由 accentOpacity 推动）
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.accent)
        .opacity(this.accentOpacity)
        .borderRadius(this.corner)

      // ③ 页面层：内容 + 标题栏，从 0 淡入 =「渐变至功能页本身」
      //
      // ⚠️ 分两层：外层只负责「背景 + 圆角 + 裁剪」，内层承担 padding。
      // 如果把 padding 写在外层，`clip` 裁的是内容区（不含 padding），
      // 背景与内容在四角就会露出直角 —— 用户看到的「圆角不一致」就是这个。
      Column() {
        Column() {
        Row({ space: 16 }) {
          Button() {
            SymbolGlyph($r('sys.symbol.chevron_left'))
              .fontSize(22)
              .fontColor([AppColor.textPrimary])
          }
          .type(ButtonType.Normal)
          .width(40)
          .height(40)
          .borderRadius(20)
          // 与项目里其它圆形返回/关闭按钮同款底色（沉浸光感令牌），
          // 之前误用了 glassSurface（那是卡片玻璃底，偏亮偏透）。
          .backgroundColor(AppColor.circleButtonSurface)
          .onClick(() => {
            this.onBack();
          })

          Text(this.title)
            .fontSize(AppFont.title)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColor.textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Blank()
        }
        .width('100%')
        // 高度与 HDS 的 MINI 标题栏一致（56vp），不是 84（那是展开态标题栏）
        .height(56)
        .padding({ left: 24, right: 24 })
        .alignItems(VerticalAlign.Center)

        Column() {
          this.content()
        }
        .width('100%')
        .layoutWeight(1)
        }
        .width('100%')
        .height('100%')
        .padding({ top: topSafeInsetVp() })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(AppColor.pageBackground)
      .borderRadius(this.corner)
      // 外层无 padding，clip 才能裁到边缘（含四角）
      .clip(true)
      .opacity(this.contentOpacity)
    }
    .width('100%')
    .height(this.fullHeight > 0 ? this.fullHeight : '100%')
    .margin({ top: -this.topInset })
    // 收起：自己缩到卡片位置（不用系统的 out 过渡，见 shrinkScale 注释）
    .scale({ x: this.shrinkScale, y: this.shrinkScale })
    .translate({ x: this.shrinkTx, y: this.shrinkTy })
    // 声明圆角：`geometryTransition` 只同步**绑定处自己的** borderRadius，
    // 不声明就按直角处理（卡片的大圆角会瞬间丢失）。这里取 0，由系统从卡片圆角插值过来。
    // ⚠️ 不要配 clip(true)：实测会让共享元素的几何动画整段失效。
    .borderRadius(0)
    .geometryTransition(this.heroId)
  }
}
