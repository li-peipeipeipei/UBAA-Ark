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
 * ## 与 HDS 标题栏的视觉对齐
 *
 * 自绘标题栏刻意复刻 HDS 的排版：84vp 高、返回按钮 40vp 圆、标题 24vp Bold、
 * 左侧 24vp 边距 —— 展开后看不出外壳换过。
 */
@Component
export struct HeroDetailLayer {
  title: string = '';
  onBack: () => void = () => {};
  /**
   * 共享元素 id —— 与点击的那张卡片一致。
   *
   * ⚠️ 必须写在组件**内部**的根节点上：`@BuilderParam` 尾随闭包之后不能再接属性链
   * （`Component({...}) { }.geometryTransition(...)` 会直接编译报错）。
   */
  heroId: string = '';

  @Builder
  empty() {
  }

  @BuilderParam content: () => void = this.empty;

  build() {
    Column() {
      // 自绘标题栏（对齐 HdsNavDestination 的 MINI 模式）
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

      // 页面内容
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
    .geometryTransition(this.heroId)
  }
}
