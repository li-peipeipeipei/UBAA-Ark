import { AppColor, AppFont, AppMaterial } from './AppTheme';
import { topSafeInsetVp } from '../common/ImmersiveUtil';
import { MaterialCardLayer } from './MaterialCardLayer';

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
  /**
   * 收起时的几何：**相对全屏原位**的平移量 + 非等比缩放。
   *
   * 三个量（踩了三轮才齐）：
   * 1. 位置用 `translate` —— 相对自身原位，**与父容器偏移无关**。
   *    用 `position` 会踩坑：它相对父容器，而父容器被侧栏/标题栏推过，
   *    传屏幕坐标会整体偏移（实测偏移 112vp = 侧栏宽）。
   * 2. 缩放用 `scale` 且 `centerX/centerY = 0`（从左上角缩），位置才不漂。
   * 3. X/Y 分别缩放 —— 浮层全屏横向（≈1.6:1）、卡片竖长（≈0.77:1），
   *    等比会缩成一个横向块。
   *
   * 收起终点：左上角 = (translate)，尺寸 = 全屏 × (scaleX, scaleY)，
   * 所以 translate 直接取卡片左上角的**屏幕坐标**即可。
   */
  @Prop transX: number = 0;
  @Prop transY: number = 0;
  @Prop scaleX: number = 1;
  @Prop scaleY: number = 1;

  onBack: () => void = () => {};

  @Builder
  empty() {
  }

  /**
   * 标题栏右侧插槽（可空）。
   *
   * 成绩查询页的「2026秋季」切换器在 HDS 里是挂在标题栏上的，换成自绘标题栏后
   * 需要一个位置放它 —— 用命名参数传 @Builder 即可（不能再加尾随闭包，
   * 尾随闭包已经被 `content` 占用）。
   */
  @BuilderParam trailing: () => void = this.empty;
  /**
   * 是否画本组件自己的标题文字。
   *
   * 成绩查询的标题栏整条都由 `GradeTermTitle` 画（标题 + 学期 + 上下学期箭头），
   * 这里再画一次就重复了 —— 那一页传 false，把整条标题栏交给 `trailing`。
   */
  titleVisible: boolean = true;

  @BuilderParam content: () => void = this.empty;

  /**
   * 返回键箭头的路径字符串（**px 坐标**）。
   *
   * 目标可视尺寸 8.57 × 16.57vp、线宽 1.43vp —— 路径本身要缩掉半个线宽：
   * x 从 0.715 到 7.855、y 从 0.715 到 15.855，尖在左中 (0.715, 8.285)。
   * `Path.commands` 按 px 解析，所以统一乘当前密度。
   */
  private arrowPath(): string {
    const k: number = this.getUIContext().vp2px(1);
    const x0: string = (0.715 * k).toFixed(1);
    const x1: string = (7.855 * k).toFixed(1);
    const y0: string = (0.715 * k).toFixed(1);
    const ym: string = (8.285 * k).toFixed(1);
    const y1: string = (15.855 * k).toFixed(1);
    // 右上 → 左中 → 右下（尖朝左）
    return 'M ' + x1 + ' ' + y0 + ' L ' + x0 + ' ' + ym + ' L ' + x1 + ' ' + y1;
  }

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
        Stack({ alignContent: Alignment.Top }) {
          // 内容：**布局从屏幕顶开始**（Scroll 视口到顶），再用 offset 把绘制下移
          // 「状态栏 + 标题栏」的高度。
          //
          // 为什么不能用「标题栏占位 + 内容在下面」的老布局：那样滚动内容永远在标题栏
          // 下沿停住，标题栏的材质下面是一块纯色底 —— 模糊没东西可糊，观感就是一堵
          // 深色板（HDS 时期的沉浸光感就是这么丢的）。
          // 现在视口到顶、内容可以穿到标题栏下面，材质才是真的在糊内容。
          // 底部同量补 padding：offset 只改绘制不改布局，不补的话最下面一截会被裁。
          Column() {
            this.content()
          }
          .width('100%')
          .height('100%')
          .padding({ bottom: topSafeInsetVp() + 56 })
          .offset({ y: topSafeInsetVp() + 56 })

          // 顶栏底衬：**不透明页面底色**，垫在遮罩 + 模糊之下。
          //
          // 只靠 `navScrim`（80% 不透明）+ `backdropBlur` 的话，下层页面的亮色会透上来：
          // 「我的」页顶部那张蓝色用户卡，就在三个入口页（关于 / 隐私 / 开源许可）的
          // 标题栏下沿透出一条蓝边（真机截图）。有这层底衬，模糊采到的就是自己的底色。
          Column()
            .width('100%')
            .height(topSafeInsetVp() + 56)
            .backgroundColor(AppColor.pageBackground)
            .hitTestBehavior(HitTestMode.None)

          // 顶栏底板：半透明遮罩 + 高斯模糊，**范围严格等于「状态栏 + 56vp 标题栏」**。
          //
          // 不再向下延伸渐变带 —— 用户实测：延伸带（60→32vp）都嫌「模糊范围太往下」，
          // 遮罩只要盖住标题栏本身即可，下面就是正常内容。
          // 单层也顺带避免了「模糊硬边」：模糊与遮罩同高同边，底边处两者一起结束，
          // 不存在「模糊还在、遮罩已没了」的错位。
          Column()
            .width('100%')
            .height(topSafeInsetVp() + 56)
            .backgroundColor(AppColor.navScrim)
            .backdropBlur(AppMaterial.blurLarge)
            // 这层盖在最上面，绝不能吃触摸：否则返回钮点不动
            .hitTestBehavior(HitTestMode.None)

          // 标题栏（不占布局，内容从其下穿过）
          // 左右内边距 16 / 图标与标题间距 8 —— 按 HDS 默认返回键的实拍像素位置量出的
          // （状态栏下：按钮左边缘 16.0vp、直径 40、标题左边缘 64.9 ≈ 16+40+8.9）。
          // 之前写 24 / 16，整体比「我的」页那套偏右 16vp。
          Row({ space: 8 }) {
              // 返回钮：**沉浸光感**（材质由 Toggle 画布承载，按钮自身保持透明）。
              // 之前用的是 circleButtonSurface（8%/12% 叠加色）—— 那只是「淡一圈的圆」，
              // 没有玻璃质感，和 HDS 版一对比就看出差别。
              Stack() {
                MaterialCardLayer({ layerRadius: 20, layerShadow: false })
                Button() {
                  // 箭头自绘（`Path`），不再用 `SymbolGlyph`。
                  //
                  // 三个实测值（1316×2832 / 3.5，均为 40vp 圆钮内的箭头）：
                  //   系统 HDS：8.57 × 16.57、笔画 **1.43vp**
                  //   符号 32 号 Regular：8.86 × 16.86、笔画 2.00vp（偏粗）
                  //   符号 32 号 Lighter：8.29 × 16.00、笔画 0.86vp（偏细）
                  // 符号字重只有「粗/细」两档，没有中间值；自绘才能把线宽定在 1.43。
                  //
                  // ⚠️ `Path.commands` 的单位是 **px**（SDK 原文 "The unit is px"），
                  // 直接写 7.85 会被当成 7.85px（≈2.2vp），箭头小到几乎看不见。
                  // 所以坐标一律走 `arrowPath()` 按当前密度换算。
                  Path()
                    .commands(this.arrowPath())
                    // ⚠️ 必须显式给尺寸：Path 省略 width/height 时不同 API 版本的
                    // 「按内容自动算尺寸」行为不一致，实测在本机按钮里会算成 0×0 而完全不显示。
                    // 路径包围盒 = 0.715..7.855 × 0.715..15.855（vp），加两侧半个线宽 0.715
                    // → 8.57 × 16.57vp。注意 commands 是 px、这里 width/height 是 vp。
                    .width(8.57)
                    .height(16.57)
                    .stroke(AppColor.textPrimary)
                    .strokeWidth(1.43)
                    .strokeLineCap(LineCapStyle.Round)
                    .strokeLineJoin(LineJoinStyle.Round)
                    .fill(Color.Transparent)
                    // 系统那个箭头在圆内偏左偏上（实测相对钮心 dx=-1.14 / dy=+0.57）；
                    // 自绘版居中时是 (-0.86/+0.86)，所以再补 -0.28 / -0.29 对齐。
                    .translate({ x: -1.42, y: -0.29 })
                }
                .type(ButtonType.Normal)
                .width(40)
                .height(40)
                .padding(0)
                .borderRadius(20)
                // 材质的层级在 backgroundColor 之上，按钮自身必须透明，否则把材质盖死
                .backgroundColor(Color.Transparent)
                .onClick(() => {
                  this.onBack();
                })
              }
              .width(40)
              .height(40)

              if (this.titleVisible) {
                Text(this.title)
                  .fontSize(AppFont.title)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(AppColor.textPrimary)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }

              // 右侧区域吃掉剩余宽度：成绩页把整条标题栏（标题 + 学期 + 箭头）塞进来，
              // 用 Blank 会把它挤到屏幕外（实测右边被裁）
              Row() {
                this.trailing()
              }
              .layoutWeight(1)
              .justifyContent(FlexAlign.End)
            }
            .width('100%')
            // 高度与 HDS 的 MINI 标题栏一致（56vp），不是 84（那是展开态标题栏）
            .height(56)
            .padding({ left: 16, right: 16 })
            .alignItems(VerticalAlign.Center)
            // 悬浮在状态栏之下：不垫这一条的话标题会顶进状态栏时钟里
            .margin({ top: topSafeInsetVp() })
        }
        .width('100%')
        .height('100%')
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
    // 从左上角缩放 + 相对原位平移（见 transX / scaleX 注释）
    .scale({ x: this.scaleX, y: this.scaleY, centerX: 0, centerY: 0 })
    .translate({ x: this.transX, y: this.transY })
    // 声明圆角：`geometryTransition` 只同步**绑定处自己的** borderRadius，
    // 不声明就按直角处理（卡片的大圆角会瞬间丢失）。这里取 0，由系统从卡片圆角插值过来。
    // ⚠️ 不要配 clip(true)：实测会让共享元素的几何动画整段失效。
    .borderRadius(0)
    .geometryTransition(this.heroId)
  }
}
