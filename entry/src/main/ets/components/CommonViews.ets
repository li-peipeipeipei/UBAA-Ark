import { AppColor, AppFont, AppSize, tilePressCurve } from './AppTheme';
import { KEY_IS_DARK } from '../common/ImmersiveUtil';
import { ScheduleColors } from '../common/ScheduleColors';
import curves from '@ohos.curves';

/**
 * 功能按钮圆角的默认值（vp）：还没量到块宽时的兜底。
 * 实际圆角由 FeaturePage 按「块宽 × 固定比例」算好后传进来，保证块变大圆角也变大。
 */
const FEATURE_TILE_RADIUS_FALLBACK: number = 28;

/**
 * 按下时缩到多小。
 *
 * 反馈要「看得见但不夸张」：0.96 在 175vp 的块上是缩小约 7vp，
 * 抬手时弹簧回到 1 会有一次很轻的过冲 —— 就是那点「弹性」。
 */
const TILE_PRESS_SCALE: number = 0.96;
/** 按下到位的时间（ms）。190：用户指定的「慢压」手感（点击更快时由抬起弹簧接管）。 */
const TILE_PRESS_DOWN_MS: number = 190;
/**
 * 收起落地时原卡片的起始比例 —— **比正常略小**，随后回到 1。
 *
 * 用户要求：落地「缩一点再归位」，不要弹到比正常大。
 * 所以全程只用 0.98 → 1 的单向回弹（不过冲），
 * 不用弹簧 —— springMotion 的欠阻尼一定会冲过 1（用户明确不要）。
 */
const TILE_LAND_SCALE: number = 0.98;
/** 落地回弹时长（ms）。256：收口后回到正常大小的节奏（用户选定）。 */
const TILE_LAND_BACK_MS: number = 256;

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
  /**
   * 断网期间打开过的页面会停在 ERROR 状态。RouteEngine 在检测到「无 → 有」时
   * 写这个键，所有仍在屏幕上的错误页各自重试一次（所有 onRetry 都是读操作）。
   */
  @StorageLink('networkBackTick') @Watch('onNetworkBack') private networkBackTick: number = 0;

  private onNetworkBack(): void {
    if (this.networkBackTick > 0) {
      this.onRetry();
    }
  }

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
  /**
   * 课表色表槽位。底色、图标/文字色全部由它从 `ScheduleColors` 派生，
   * 与课表课程块共用同一套莫奈色板（浅=叠白派生实色、深=暗调预混实色）。
   */
  slot: number = 0;
  /** 深浅色主题（底部图标/文字色随它切换），与课表页同源订阅。 */
  @StorageProp(KEY_IS_DARK) private isDark: boolean = false;
  /** 图标是否自带配色（多色素材），为 true 时不再染色。 */
  colorful: boolean = false;
  /**
   * 图标是位图（PNG）而非矢量（SVG）。
   *
   * `Image.fillColor()` 官方只对 SVG 生效，PNG 必须走 colorFilter；这里用官方
   * 推荐的 `SRC_IN`（保留透明度、只换颜色）。SVG 继续走 fillColor —— 文档明确
   * colorFilter 对 SVG 受限（API21 以下需 supportSvg2），两条分支不能统一。
   */
  bitmapIcon: boolean = false;
  /**
   * 圆角半径（vp），由父级按「块宽 × 固定比例」算好传入。
   *
   * 不能写死：块的宽度随设备 / 横竖屏变化（横屏 5 列、竖屏 3 列），圆角固定的话
   * 大块看着「角很锐」、小块看着「角很圆」。按比例走，视觉一致。
   *
   * ⚠️ **必须是 `@Prop`**：这个值会随列数变化（父级的 `tileRadius` 由实测宽度算出），
   * 而普通成员只在**初始化**时赋值一次、父级后续更新不会同步，也不会触发重绘 ——
   * 卡片的圆角会永远停在兜底值 28，与父级上报给转场的实测值对不上。
   *
   * 这正好解释了「只有平板竖屏看得出圆角突变」：md 断点的兜底列数是 **6**，
   * 实测只有 **4**（块宽 118 → 183），圆角差 **10vp**；手机与横屏的兜底列数
   * 与实测基本一致，差值落在 1~2vp 以内，肉眼看不出来。
   */
  @Prop radius: number = FEATURE_TILE_RADIUS_FALLBACK;
  /** 本卡片在网格中的序号，父级用它决定「回来的那张要回弹」。 */
  @Prop index: number = -1;
  /**
   * 是否隐藏（卡片正在「变成」展开页时）。
   *
   * 不隐藏的话，展开页只是「盖在卡片上的一块」——最接近卡片的那几帧能同时看到
   * 卡片和色块，观感是「浮层压上去」，而不是「这张卡自己展开了」。
   * ⚠️ 收起前必须先置回 false：几何过渡需要一个可见的 out 组件作目标。
   */
  @Prop hidden: boolean = false;
  /**
   * 回弹触发计数：父级在「全屏页缩回这张卡片」之后把它 +1，
   * 这里 `@Watch` 收到就弹一下。用计数而不是布尔，才能连续触发多次。
   */
  @Prop @Watch('onBounce') bounceTick: number = 0;
  onTileClick: () => void = () => {};
  /**
   * 上报本卡片在**屏幕坐标系**里的矩形（转场色块要精确从这里长出来）。
   *
   * 用 `onAreaChange` 的 `globalPosition` 而不是父级按列宽推算 —— 推算会跟真实
   * 布局差几个像素，放大初始帧就看得出来是「错位」的。
   *
   * ⚠️ 圆角必须**由本组件上报它自己正在用的值**，不能让父级另算一份：
   * 父级的 `tileRadius` 是随宽度重算的 @State，而本组件拿到新 `radius` 属性是下一帧 ——
   * 布局回调（本方法）发生在两者之间，父级此时读自己的状态会拿到「卡片还没换上的新圆角」。
   * 平板竖屏首次布局正好踩在这个窗口上（列数从兜底翻到实测），表现为
   * 「收起落地后圆角跳一下」。
   */
  onBounds: (x: number, y: number, w: number, h: number, radius: number) => void = () => {};

  /** 是否处于按下态（0.955）。 */
  @State private pressed: boolean = false;
  /** 收起落地后的归位比例：从 TILE_LAND_SCALE（略小）回到 1。 */
  @State private bounceScale: number = 1;

  onBounce(): void {
    // ⚠️ 只有 tick **递增**才是「该我弹」。
    // 非目标卡片的 tick 会被置回 0 —— 那也是一次 @Watch 变化，不拦截的话，
    // 每次别的卡回弹，之前弹过的卡都会跟着再弹一遍（用户实测：多张卡一起弹）。
    if (this.bounceTick <= 0) {
      return;
    }
    // 落地瞬间先「缩一点」（用户要求：比正常块略小），再回到正常大小 ——
    // 全程不过冲，绝不会比正常大。
    // ⚠️ 起点必须**先落一帧**再启动动画，否则「赋值 + animateTo 到 1」在同一帧
    // 提交会被合并成「直接是 1」，缩的那一下根本看不到。
    this.bounceScale = TILE_LAND_SCALE;
    setTimeout(() => {
      this.getUIContext().animateTo({ duration: TILE_LAND_BACK_MS, curve: Curve.FastOutSlowIn }, () => {
        this.bounceScale = 1;
      });
    }, 16);
  }

  build() {
    // 两层叠放：课表色块（不透明实色） → 图标与文字。
    //
    // 2026-11-24 起磁贴配色与课表课程块统一走 `ScheduleColors`：浅色=文字色叠白派生的
    // 淡实色 + 同色系彩字，深色=暗调预混实色 + 白字。底色既然是**预混实色**，就不能再叠
    // 真 opacity（否则显示色与课表块对不上），材质层也失去透色意义 —— 故去掉材质层，
    // 底色直接铺满。转场遮罩同步改为不透明（见 featureTileAlpha）。
    Stack() {
      // ⚠️ 尺寸一律用 `LayoutPolicy.matchParent`，不能写 '100%'：
      // Stack 子节点的百分比按**父级可用尺寸**解析，而本按钮的高度是由 aspectRatio 算出来的，
      // 可用尺寸就是「网格那一格的剩余空间」—— 写百分比会把按钮自己顶大。
      Column()
        .width(LayoutPolicy.matchParent)
        .height(LayoutPolicy.matchParent)
        .borderRadius(this.radius)
        .backgroundColor(ScheduleColors.forFeatureTile(this.slot, this.isDark))

      Column({ space: 12 }) {
        if (this.colorful) {
          // 多色素材：保留原配色（染色会把内部结构糊掉）
          Image(this.icon)
            .width(40)
            .height(40)
            .draggable(false)
        } else if (this.bitmapIcon) {
          // 位图：fillColor 对 PNG 无效，必须走 colorFilter（官方推荐 SRC_IN 染色）
          Image(this.icon)
            .width(40)
            .height(40)
            .colorFilter(ScheduleColors.iconTintFilter(this.slot, this.isDark))
            .draggable(false)
        } else {
          // 矢量：fillColor 只对 SVG 生效，与位图分支不能统一
          Image(this.icon)
            .width(40)
            .height(40)
            .fillColor(ScheduleColors.textForSlot(this.slot, this.isDark))
            .draggable(false)
        }

        Text(this.title)
          .fontSize(AppFont.subtitle)
          .fontWeight(FontWeight.Medium)
          .fontColor(ScheduleColors.textForSlot(this.slot, this.isDark))
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
    // 按下缩放 + 回来时的一次回弹，都作用在整块上。
    // ⚠️ 不用 `.animation()`：它给所有变化套同一条曲线，而「按下」要快
    // （190ms Friction）、「抬起」要弹（spring）、「回弹」要先涨后落 ——
    // 各自不同，只能用显式 animateTo。
    .scale({
      x: this.pressed ? TILE_PRESS_SCALE : this.bounceScale,
      y: this.pressed ? TILE_PRESS_SCALE : this.bounceScale
    })
    // ⚠️ 不能用 onClick 做按压反馈：onClick 在**抬手**才触发，
    // 按下去的那 100ms 里没有任何视觉回应，手感是「点不动」。
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.getUIContext().animateTo({ duration: TILE_PRESS_DOWN_MS, curve: tilePressCurve() }, () => {
          this.pressed = true;
        });
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.getUIContext().animateTo({ curve: curves.springMotion(0.18, 0.55) }, () => {
          this.pressed = false;
        });
      }
    })
    // 正在展开时自己消失（分层由展开页接管），收起前会被父级还原
    .opacity(this.hidden ? 0 : 1)
    // 平板外接键鼠 / 2in1 触控板上，按钮需要悬停反馈才「像个按钮」（官方多设备交互建议）
    .hoverEffect(HoverEffect.Highlight)
    .onClick(() => {
      this.onTileClick();
    })
    // 卡片展开的转场由 MainPage 的遮罩演（见 MainPage.onMorphTick），
    // 这里不再绑 `geometryTransition` —— 跨 NavDestination 它不生效（实测），
    // 留着反而会触发系统自己的共享元素逻辑、与遮罩抢动画。
    .borderRadius(this.radius)
    .onAreaChange((_old: Area, now: Area) => {
      const x: number = now.globalPosition.x as number;
      const y: number = now.globalPosition.y as number;
      const w: number = now.width as number;
      const h: number = now.height as number;
      this.onBounds(x, y, w, h, this.radius);
    })
  }
}

/**
 * 卡片色块**实际使用的透明度**。
 *
 * 2026-11-24 起磁贴底色改用课表色表的预混实色（不透明），与 `FeatureTile` 的
 * `backgroundColor` 完全同源 —— 转场遮罩必须也是不透明（1），否则起点颜色和卡片对不上。
 */
export function featureTileAlpha(): number {
  return 1;
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
