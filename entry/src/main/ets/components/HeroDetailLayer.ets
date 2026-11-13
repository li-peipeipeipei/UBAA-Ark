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

  onBack: () => void = () => {};

  @Builder
  empty() {
  }

  @BuilderParam content: () => void = this.empty;

  build() {
    Stack() {
      // 彩色层：整块随共享元素几何一起长大 / 缩小
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.accent)
        // 略透：放大过程中底下的其他卡片还隐约透得出来
        .opacity(0.92)

      // 页面层：内容 + 标题栏，从 0 淡入 =「渐变至功能页本身」
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
          .backgroundColor(AppColor.glassSurface)
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
        .height(84)
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
      .backgroundColor(AppColor.pageBackground)
      .padding({ top: topSafeInsetVp() })
      .opacity(this.contentOpacity)
    }
    .width('100%')
    .height('100%')
    // 裁掉圆角外的溢出
    .clip(true)
    // ⚠️ 必须显式声明圆角，共享元素才会做圆角插值：
    // `geometryTransition` 只同步「绑定处自己的 borderRadius」，没设就按无圆角处理，
    // 于是展开瞬间卡片的大圆角会直接变成直角（用户看到的就是「没有圆角过渡」）。
    // 这里取 0（展开后是整页），系统会从卡片的 28 平滑插值到 0。
    .borderRadius(0)
    .geometryTransition(this.heroId)
  }
}
