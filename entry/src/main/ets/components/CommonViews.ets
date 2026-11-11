import { AppColor, AppFont, AppSize } from './AppTheme';
import { MaterialCardLayer } from './MaterialCardLayer';
import { immersiveMaterialActive } from '../common/SystemMaterial';

/**
 * 材质层之上那层主色的不透明度。
 *
 * 太低（0.62）时真机上看得出两个问题：色相被材质压暗、按钮像蒙了一层灰；
 * 太高又看不见材质的通透感。0.82 是「色相鲜亮 + 边缘与高光仍透出材质」的折中点。
 */
const FEATURE_TILE_COLOR_ALPHA: number = 0.82;

/**
 * 功能按钮圆角的默认值（vp）：还没量到块宽时的兜底。
 * 实际圆角由 FeaturePage 按「块宽 × 固定比例」算好后传进来，保证块变大圆角也变大。
 */
const FEATURE_TILE_RADIUS_FALLBACK: number = 28;

/**
 * 图标来源类型。
 *
 * - SVG：使用 app.media 下的本地矢量图（沿用 UBAA 的 Material 图标风格，可 fillColor 换色）
 * - SYMBOL：使用 HarmonyOS 系统符号（SymbolGlyph，字号与颜色自适应）
 */
export enum IconKind {
  SVG = 0,
  SYMBOL = 1
}

/** 加载中占位。 */
@Component
export struct LoadingView {
  message: string = '正在加载…';

  build() {
    Column({ space: AppSize.gap }) {
      LoadingProgress()
        .width(40)
        .height(40)
        .color(AppColor.brand)
      Text(this.message)
        .fontSize(AppFont.body)
        .fontColor(AppColor.textSecondary)
    }
    .width('100%')
    .padding({ top: 80, bottom: 80 })
    .justifyContent(FlexAlign.Center)
  }
}

/** 错误占位，带重试入口。 */
@Component
export struct ErrorView {
  message: string = '加载失败';
  onRetry: () => void = () => {};

  build() {
    Column({ space: AppSize.gapLarge }) {
      SymbolGlyph($r('sys.symbol.exclamationmark'))
        .fontSize(44)
        .fontColor([AppColor.warning])
      Text(this.message)
        .fontSize(AppFont.body)
        .fontColor(AppColor.textSecondary)
        .textAlign(TextAlign.Center)
        .padding({ left: 24, right: 24 })
      Button('重新加载')
        .fontSize(AppFont.body)
        .backgroundColor(AppColor.brandContainer)
        .fontColor(AppColor.brand)
        .type(ButtonType.Capsule)
        .height(36)
        .onClick(() => {
          this.onRetry();
        })
    }
    .width('100%')
    .padding({ top: 60, bottom: 60 })
    .justifyContent(FlexAlign.Center)
  }
}

/** 空数据占位。 */
@Component
export struct EmptyView {
  message: string = '暂无数据';

  build() {
    Column({ space: AppSize.gap }) {
      SymbolGlyph($r('sys.symbol.doc'))
        .fontSize(44)
        .fontColor([AppColor.textTertiary])
      Text(this.message)
        .fontSize(AppFont.body)
        .fontColor(AppColor.textSecondary)
    }
    .width('100%')
    .padding({ top: 60, bottom: 60 })
    .justifyContent(FlexAlign.Center)
  }
}

/** 通用卡片容器：统一圆角、留白与背景。 */
@Component
export struct SectionCard {
  title: string = '';
  subtitle: string = '';
  showAction: boolean = false;
  actionText: string = '更多';
  onAction: () => void = () => {};

  @Builder
  emptyContent() {
  }

  @BuilderParam content: () => void = this.emptyContent;

  build() {
    Column({ space: AppSize.gap }) {
      if (this.title.length > 0) {
        Row() {
          Column({ space: 2 }) {
            Text(this.title)
              .fontSize(AppFont.subtitle)
              .fontWeight(FontWeight.Medium)
              .fontColor(AppColor.textPrimary)
            if (this.subtitle.length > 0) {
              Text(this.subtitle)
                .fontSize(AppFont.caption)
                .fontColor(AppColor.textTertiary)
            }
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          if (this.showAction) {
            Row({ space: 2 }) {
              Text(this.actionText)
                .fontSize(AppFont.caption)
                .fontColor(AppColor.textSecondary)
              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(12)
                .fontColor([AppColor.textTertiary])
            }
            .onClick(() => {
              this.onAction();
            })
          }
        }
        .width('100%')
      }

      this.content()
    }
    .width('100%')
    .padding(AppSize.cardPadding)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(AppColor.surface)
    .borderRadius(AppSize.cardRadius)
  }
}

/** 功能入口磁贴（4 列网格中的一格）。 */
/**
 * 功能入口按钮：**大圆角矩形**，图标与文字都在按钮内部。
 *
 * 设计要点（2026-11-11 改版）：
 * - 一整个矩形就是点击热区，不再是「小图标 + 下面一行小字」，触控面积大、误触少；
 * - 左侧 40×40 的彩色圆角块承载重绘的单色图标（白色描边式，跟功能语义对应）；
 * - 右侧两行文字：主标题 + 一句功能说明，扫一眼就知道点进去干什么；
 * - 统一的底色（surface）+ 16 圆角 + 12 内边距，在网格里形成规整的节奏。
 */
/**
 * 功能入口按钮：**竖长矩形**，整块底色填充，只有图标与名称。
 *
 * 设计（2026-11-11 二改）：
 * - 整块用功能主色填充（不再是「小色块 + 卡片底色」），一排按钮像一组彩色卡片；
 * - 竖长（宽高比约 0.8），比横条更容易一眼扫过、也更适合两行以上的网格；
 * - 内部只有居中的图标与名称，去掉说明文字，靠图标表意；
 * - 图标用 UBAA 原版 `app.media.ic_*`（Material 风格），白色着色。
 */
@Component
export struct FeatureTile {
  title: string = '';
  icon: Resource = $r('app.media.ic_apps');
  /** 整块主色（每个功能一种强调色）。 */
  color: Resource = $r('app.color.brand');
  /**
   * 圆角半径（vp），由父级按「块宽 × 固定比例」算好传入。
   *
   * 不能写死：块的宽度随设备 / 横竖屏变化（横屏 5 列、竖屏 3 列），圆角固定的话
   * 大块看着「角很锐」、小块看着「角很圆」。按比例走，视觉一致。
   */
  radius: number = FEATURE_TILE_RADIUS_FALLBACK;
  onTileClick: () => void = () => {};

  /** 沉浸材质是否可用（只查一次；不可用时退化为不透明纯色）。 */
  private readonly materialActive: boolean = immersiveMaterialActive(false);

  build() {
    // 三层叠放：系统材质（底） → 半透明主色层 → 图标与文字。
    //
    // 为什么底色必须分层、不能直接给内容容器上色：沉浸光感的视觉层级在
    // `backgroundColor` **之下**，容器一旦有不透明底色就把材质整块盖死。这里把
    // 「颜色」单独拎成一层、用 opacity 让它半透明，材质才透得出来 —— 观感是彩色玻璃，
    // 而不是「彩色卡纸上贴了一层灰」。
    Stack() {
      if (this.materialActive) {
        MaterialCardLayer({ layerRadius: this.radius, layerShadow: false })
      }

      // ⚠️ 尺寸一律用 `LayoutPolicy.matchParent`，不能写 '100%'：
      // Stack 子节点的百分比按**父级可用尺寸**解析，而本按钮的高度是由 aspectRatio 算出来的，
      // 可用尺寸就是「网格那一格的剩余空间」—— 写百分比会把按钮自己顶大。
      // 同层的 MaterialCardLayer 用的也是 matchParent，兄弟层必须同一种写法。
      Column()
        .width(LayoutPolicy.matchParent)
        .height(LayoutPolicy.matchParent)
        .borderRadius(this.radius)
        .backgroundColor(this.color)
        // 材质可用时留出通透感；不可用（低版本 / 应用级关闭）时退成不透明纯色，
        // 否则会直接漏出页面背景，按钮的色相就没了。
        .opacity(this.materialActive ? FEATURE_TILE_COLOR_ALPHA : 1)

      Column({ space: 12 }) {
        Image(this.icon)
          .width(40)
          .height(40)
          .fillColor(Color.White)
          .opacity(0.9)
          .draggable(false)

        Text(this.title)
          .fontSize(AppFont.subtitle)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .opacity(0.95)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width(LayoutPolicy.matchParent)
      .height(LayoutPolicy.matchParent)
      .justifyContent(FlexAlign.Center)
      // 内容层不参与命中：让点击落到外层 Stack 上（材质层本身 hitTestBehavior 已是 None）
      .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    // 竖长：宽 / 高 = 0.8，高度比宽度大 25%
    .aspectRatio(0.8)
    // 平板外接键鼠 / 2in1 触控板上，按钮需要悬停反馈才「像个按钮」（官方多设备交互建议）
    .hoverEffect(HoverEffect.Highlight)
    .onClick(() => {
      this.onTileClick();
    })
  }
}

/** 键值信息行（「我的」页 / 详情页复用）。 */
@Component
export struct InfoRow {
  @Prop label: string = '';
  @Prop value: string = '';
  @Prop showDivider: boolean = true;

  build() {
    Column() {
      Row() {
        Text(this.label)
          .fontSize(AppFont.body)
          .fontColor(AppColor.textSecondary)
        Text(this.value.length > 0 ? this.value : '—')
          .fontSize(AppFont.body)
          .fontColor(AppColor.textPrimary)
          .layoutWeight(1)
          .textAlign(TextAlign.End)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .padding({ top: 12, bottom: 12 })

      if (this.showDivider) {
        Divider()
          .color(AppColor.divider)
          .strokeWidth(0.5)
      }
    }
    .width('100%')
  }
}

/** 章节标题（列表分组用）。 */
@Component
export struct SectionHeader {
  @Prop title: string = '';

  build() {
    Text(this.title)
      .fontSize(AppFont.caption)
      .fontColor(AppColor.textTertiary)
      .padding({ left: 4, bottom: 8 })
      .width('100%')
  }
}
