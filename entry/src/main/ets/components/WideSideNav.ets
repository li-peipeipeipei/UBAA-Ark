import { AppColor, AppFont, AppMaterial, AppSize } from './AppTheme';
import { MaterialCardLayer } from './MaterialCardLayer';
import { immersiveMaterialActive } from '../common/SystemMaterial';
import { sideNavWidthOf } from '../common/Breakpoint';
import curves from '@ohos.curves';

/** 侧栏两侧内边距（按钮宽度 = 栏宽 − 2 × 它）。 */
const SIDE_NAV_PADDING: number = 8;
/** 单个菜单项高度。 */
const SIDE_NAV_ITEM_HEIGHT: number = 48;
/**
 * 选中背景滑动用的弹簧参数（秒 / 阻尼比）。
 *
 * 不用 `Curve.Friction + duration` 的原因是那种写法是「固定时长的匀减速」，
 * 到位那一下是「咔」地停住。弹簧有自然的加速—减速—轻微收尾，是 iOS 上分段控件
 * 指示器的手感：
 * 这两个数由沛轩在真机上一档一档试出来
 * （0.36 → 0.28 → 0.15 → 0.2 → 0.22 → 0.2/0.76 收敛）：
 * - response 0.2：一次振荡的时长。0.36 / 0.28 偏拖，0.15 略「急」，0.2 最合手；
 * - dampingFraction 0.76：略低于临界阻尼（1.0），到位时留一点点回弹。
 *
 * ⚠️ 弹簧曲线**不吃 `duration`**，时长由这两个参数决定。
 */
const SIDE_NAV_SLIDE_RESPONSE: number = 0.2;
const SIDE_NAV_SLIDE_DAMPING: number = 0.76;

/**
 * 宽屏侧边导航栏（平板 / 折叠展开 / 2in1 / 宽自由窗口）。
 *
 * ## 沉浸光感的分层
 *
 * 普通 `Column` 在内容区挂 `systemMaterial` 静默不渲染，底板只能交给
 * `MaterialCardLayer`（不可交互 `ToggleType.Button` 画布），内容作为 Stack 兄弟叠上去。
 *
 * **材质只给「选中项」那一个背景块，而且这块背景是全栏共用的一个**：
 * 整条侧栏挂材质时，材质自带的边缘高光会沿栏的右边画出一条竖直亮线（贴边特别扎眼）；
 * 而每个按钮各挂一块，四个玻璃块并排又会显得很满。
 *
 * 共用一块还有个好处 —— 切换页签时这块背景会**从旧位置滑到新位置**（`translate` +
 * 隐式动画），而不是这边熄、那边亮。
 */
@Component
export struct WideSideNav {
  @Prop currentIndex: number = 0;
  @Prop bp: string = 'sm';
  onSelect: (index: number) => void = () => {};

  private readonly materialActive: boolean = immersiveMaterialActive(false);

  /** 按钮宽度：栏宽减去两侧内边距。四个按钮等宽，图标与文字居中 → 两边的留白自然相等。 */
  private itemWidth(): number {
    return sideNavWidthOf(this.bp) - SIDE_NAV_PADDING * 2;
  }

  /** 相邻两个菜单项的纵向步长。 */
  private itemStride(): number {
    return SIDE_NAV_ITEM_HEIGHT + AppSize.gapSmall;
  }

  /**
   * 选中背景块：材质 + 品牌沾色。
   *
   * 它不属于任何单个按钮，而是浮在按钮组下方、按 `currentIndex` 平移 ——
   * 切换时的「移动」就是这一块在动。
   */
  @Builder
  selectionBlock() {
    Stack() {
      if (this.materialActive) {
        MaterialCardLayer({ layerRadius: AppSize.cardRadius, layerShadow: false })
      } else {
        // 材质不可用：退成一层半透明底色（形状一致，只是没有光感）
        Column()
          .width(LayoutPolicy.matchParent)
          .height(LayoutPolicy.matchParent)
          .borderRadius(AppSize.cardRadius)
          .backgroundColor(AppColor.glassSurface)
      }

      // 沾色层：半透明品牌色**叠在材质之上**（不透明底会把材质盖死）
      Column()
        .width(LayoutPolicy.matchParent)
        .height(LayoutPolicy.matchParent)
        .borderRadius(AppSize.cardRadius)
        .backgroundColor(AppColor.brandContainerGlass)
    }
    .width(this.itemWidth())
    .height(SIDE_NAV_ITEM_HEIGHT)
    // translate 参与属性动画（position 不参与，左边缘会瞬移）
    .translate({ y: this.currentIndex * this.itemStride() })
    .animation({ curve: curves.springMotion(SIDE_NAV_SLIDE_RESPONSE, SIDE_NAV_SLIDE_DAMPING) })
  }

  @Builder
  navItem(index: number, icon: Resource, label: string) {
    Row({ space: 12 }) {
      Image(icon)
        .width(24)
        .height(24)
        .fillColor(this.currentIndex === index ? AppColor.brand : AppColor.textSecondary)
        // 换色跟背景块一起淡变，避免「块在滑、颜色已经跳完」
        .animation({ duration: 220, curve: Curve.EaseOut })
      Text(label)
        .fontSize(AppFont.subtitle)
        .fontColor(this.currentIndex === index ? AppColor.brand : AppColor.textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        // animation 放在链末：把它前面所有可动画属性都纳入（这里实际只有颜色）
        .animation({ duration: 220, curve: Curve.EaseOut })
    }
    .width(this.itemWidth())
    .height(SIDE_NAV_ITEM_HEIGHT)
    // 内容居中：图标左侧留白与文字右侧留白由「等宽按钮 + 居中」自动相等
    .justifyContent(FlexAlign.Center)
    .hoverEffect(HoverEffect.Highlight)
    .onClick(() => {
      this.onSelect(index);
    })
  }

  build() {
    // 默认 Center：按钮组是固定高度的块，交给 Stack 垂直居中
    Stack() {
      // 整条栏只垫一层淡毛玻璃：给导航区一个边界，但不画任何描边
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(AppColor.glassSurface)
        .backdropBlur(AppMaterial.blurLarge)

      // 按钮组垂直居中；选中背景块与按钮同处一个 Stack，靠 translate 对齐
      Stack({ alignContent: Alignment.TopStart }) {
        this.selectionBlock()

        Column({ space: AppSize.gapSmall }) {
          this.navItem(0, $r('app.media.ic_home'), '主页')
          this.navItem(1, $r('app.media.ic_schedule'), '课表')
          this.navItem(2, $r('app.media.ic_apps'), '功能')
          this.navItem(3, $r('app.media.ic_person'), '我的')
        }
        .width(this.itemWidth())
      }
      .width(this.itemWidth())
      .height(this.itemStride() * 4 - AppSize.gapSmall)
    }
    .width(sideNavWidthOf(this.bp))
    .height('100%')
    .backgroundColor(Color.Transparent)
  }
}
