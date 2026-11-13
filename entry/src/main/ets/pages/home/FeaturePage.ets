import { AppRouter } from '../../common/AppRouter';
import { FeatureHero, HERO_BOUNCE_TICK } from '../../common/FeatureHero';
import { HeroMorph, MorphRect } from '../../common/HeroMorph';
import { Toast } from '../../common/Toast';
import { Logger } from '../../common/Logger';
import { AppColor, AppFont, AppSize } from '../../components/AppTheme';
import { topSafeInsetVp } from '../../common/ImmersiveUtil';
import { FeatureTile, tileFillColor } from '../../components/CommonViews';
import { FeatureItem, allFeatures } from '../../components/FeatureRegistry';
import { KEY_BREAKPOINT, templateOfColumns, tileColumnsTemplateFor } from '../../common/Breakpoint';

/**
 * 单个按钮的**目标宽度**（vp）。
 *
 * 列数不是「能塞几列塞几列」，而是按目标宽度反推：
 * `列数 = floor((可用宽 + 间距) / (目标宽 + 间距))`，再用 Grid 把剩余宽度均分。
 *
 * 这样横竖屏下按钮的视觉大小基本一致（横屏 5 列、竖屏 3 列），而不是
 * 「横屏挤 8 个、竖屏只有 2 个」那种忽大忽小。
 * 取 172 是实测值：横屏内容宽 925 → 5 列；竖屏 635 → 3 列。
 */
const TILE_TARGET_WIDTH: number = 172;
/** 列数下限（再少就没法看了）。上限放开：**一排多少个由目标宽度决定**，不设死。 */
const MIN_COLUMNS: number = 2;
const MAX_COLUMNS: number = 10;
/**
 * 圆角半径 ÷ 块宽 的固定比例。
 *
 * 块宽随设备 / 横竖屏变化（横屏 5 列 175vp、竖屏 3 列 194vp、大屏可能 8 列），
 * 圆角固定的话视觉上大块「角锐」、小块「角圆」。按比例走才一致。
 * 取 0.16：175vp 的块算出 28vp 圆角，就是之前定下的那个比例。
 */
const TILE_CORNER_SCALE: number = 0.16;
/** 卡片宽高比：与 FeatureTile 的 `aspectRatio(0.8)` 必须一致，算卡片中心高度要用。 */
const TILE_ASPECT_RATIO: number = 0.8;

/**
 * 功能页：一层平铺的功能按钮网格。
 *
 * ## 2026-11-11 改版
 *
 * - **去掉「普通 / 高级」分组与外面的大卡片**：按钮直接铺在页面上，靠间距分组，
 *   少一层容器、少一层边框，视线更集中在按钮本身。
 * - **按钮改为大圆角矩形**（图标 + 标题 + 说明都在按钮内部），触控面积更大。
 * - **删掉了全部分栏过渡动画**：分栏收放交给 HDS 自己走，页面不再逐帧补间宽度
 *   （那段补间是前面所有"抖 / 跳 / 挤"的来源，本次一并移除）。
 *
 * ## 列数按「自身宽度」算，不按窗口断点
 *
 * 本页可能活在很窄的容器里（窄窗口、折叠屏内屏分栏），此时窗口断点是 md / lg，但可用宽度
 * 只有手机那么多 —— 按窗口断点取列会把按钮挤扁（真机实测）。这里用 `onAreaChange` 拿实测宽度，
 * 按「单个约 172vp」反推列数。
 */
@Component
export struct FeaturePage {
  stack: NavPathStack = new NavPathStack();

  @StorageProp(KEY_BREAKPOINT) private bp: string = 'sm';
  /** 实测可用宽度换算出的列数（0 = 还没量到，按窗口断点兜底）。 */
  @State private columns: number = 0;
  /** 块的圆角（vp）：块宽 × TILE_CORNER_SCALE，与列数同一帧算出，同源。 */
  @State private tileRadius: number = 28;
  /** 自身实测宽度（含内边距），算卡片位置要用。 */
  @State private paneWidth: number = 0;
  /** 刚缩回来的那张卡片（-1 = 没有）。 */
  @State private bounceIndex: number = -1;
  /** 回弹触发计数：只给 `bounceIndex` 那张卡片递增，避免整排一起弹。 */
  @State private bounceTick: number = 0;
  /**
   * 退场动画播完的信号（由 DestShell 递增）。
   * 收到后取 `FeatureHero.takeBounce()` —— 记住的是**哪一张**卡片要弹。
   */
  @StorageProp(HERO_BOUNCE_TICK) @Watch('onBounceSignal') private bounceSignal: number = 0;

  onBounceSignal(): void {
    const index: number = FeatureHero.takeBounce();
    if (index < 0) {
      return;
    }
    this.bounceIndex = index;
    this.bounceTick = this.bounceTick + 1;
  }

  /** 每张卡片在屏幕坐标系里的矩形（由 FeatureTile 的 onAreaChange 上报）。 */
  private tileBounds: Map<number, number[]> = new Map();

  private onTileBounds(index: number, x: number, y: number, w: number, h: number): void {
    this.tileBounds.set(index, [x, y, w, h]);
  }

  /**
   * 卡片的**真实**屏幕矩形。
   *
   * 不再按「页边距 + 列宽」推算：那样和真实布局会差几个像素，放大初始帧就「错位」。
   * 坐标直接用 FeatureTile 上报的 `globalPosition`（已含侧栏 / 状态栏偏移）。
   */
  private cardRect(index: number): MorphRect | null {
    const bounds: number[] | undefined = this.tileBounds.get(index);
    if (bounds === undefined || bounds.length < 4) {
      return null;
    }
    return {
      x: bounds[0],
      y: bounds[1],
      w: bounds[2],
      h: bounds[3],
      radius: this.tileRadius
    };
  }

  private open(item: FeatureItem, index: number): void {
    if (item.route.length === 0) {
      Toast.show(item.title + ' · 敬请期待');
      return;
    }
    // 转场：一块「卡片色」从卡片矩形变形到全屏，页面在它之上交叉淡入。
    // push 仍然是硬切 —— 变形动画由 MainPage 的色块层演，跟路由无关。
    const rect: MorphRect | null = this.cardRect(index);
    if (rect !== null) {
      // 卡片本身是「半透明主色叠材质」，色块要用混合后的实际颜色才不跳
      const dark: boolean = AppStorage.get<boolean>('isDarkMode') ?? false;
      HeroMorph.startExpand(tileFillColor(item.colorValue, dark), rect, index);
    }
    AppRouter.open(this.stack, item.route, undefined, false);
  }

  /**
   * 列数模板：量到宽度就按实测算，否则按窗口断点估。
   *
   * ⚠️ 这里**不走** `fitColumnsToItems`：它会为了「最后一行不留残行」优先选能整除的
   * 列数 —— 10 个功能块按 3 列排是 3+3+3+1，它会退到 2 列（10 % 2 == 0）。
   * 那样一来竖屏的块就比横屏大得多，正是要避免的「视觉大小忽变」。
   * 这里只按目标宽度取列，残行怎么都躲不掉（10 个块不可能被 3 整除）。
   */
  private columnsTemplate(items: FeatureItem[]): string {
    if (this.columns <= 0) {
      return tileColumnsTemplateFor(this.bp, items.length);
    }
    let columns: number = this.columns;
    if (items.length > 0 && items.length < columns) {
      columns = items.length;
    }
    return templateOfColumns(columns);
  }

  build() {
    Scroll() {
      Column({ space: AppSize.gap }) {
        Grid() {
          ForEach(allFeatures(), (item: FeatureItem, index: number) => {
            GridItem() {
              FeatureTile({
                title: item.title,
                icon: item.icon,
                color: item.color,
                radius: this.tileRadius,
                index: index,
                bounceTick: this.bounceIndex === index ? this.bounceTick : 0,
                onBounds: (x: number, y: number, w: number, h: number) => {
                  this.onTileBounds(index, x, y, w, h);
                },
                onTileClick: () => {
                  this.open(item, index);
                }
              })
            }
          }, (item: FeatureItem) => item.title)
        }
        .columnsTemplate(this.columnsTemplate(allFeatures()))
        .columnsGap(AppSize.gap)
        .rowsGap(AppSize.gap)
        .width('100%')

        Blank()
          .height(AppSize.contentBottomInset)
      }
      .width('100%')
      .padding({
        left: AppSize.pagePadding,
        right: AppSize.pagePadding,
        // 顶部让开「状态栏 + 悬浮标题栏（MINI，56vp）」。状态栏那一段的模糊由
        // PageShell 的磨砂层补上，视口必须从屏幕顶开始（见 MainPage.PageShell）；
        // 留白只能写在这里，写到外壳上会把视口压低、内容就滑不进磨砂层了。
        top: AppSize.destTopInset(topSafeInsetVp()),
        bottom: 0
      })
      .constraintSize({ minHeight: '100%' })
      // 一级页内容整体上移一点（纯视觉位移，见 AppSize.contentTopLift）
      .translate({ y: -AppSize.contentTopLift })
      // 量自身宽度换算列数（不做动画；分栏收放期间由 HDS 自己走，页面只跟随最终宽度）
      .onAreaChange((oldArea: Area, newArea: Area) => {
        const raw: Length = newArea.width;
        const total: number = typeof raw === 'number' ? raw : parseFloat(raw.toString());
        if (Math.abs(total - this.paneWidth) > 1) {
          this.paneWidth = total;
        }
        const usable: number = total - AppSize.pagePadding * 2;
        // 按目标宽度反推列数（+ 间距一起算，避免最后一列的缝隙误差）
        let columns: number = Math.floor((usable + AppSize.gap) / (TILE_TARGET_WIDTH + AppSize.gap));
        if (columns < MIN_COLUMNS) {
          columns = MIN_COLUMNS;
        }
        if (columns > MAX_COLUMNS) {
          columns = MAX_COLUMNS;
        }
        // 块宽与圆角同帧算出：圆角 = 块宽 × 固定比例（列数变了块宽就变了）
        const blockWidth: number = (usable - (columns - 1) * AppSize.gap) / columns;
        const radius: number = Math.round(blockWidth * TILE_CORNER_SCALE);
        if (columns !== this.columns) {
          this.columns = columns;
        }
        if (Math.abs(radius - this.tileRadius) > 1) {
          this.tileRadius = radius;
        }
      })
    }
    .scrollBar(BarState.Off)
    // 顶/底拖到边界时回弹（内容不足一屏也生效）
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    // 沉浸光感「三件套」之二 / 之三（配合 titleBar 的 enableComponentSafeArea）：
    //   clip(false)      —— 允许内容画到自身布局矩形之外；
    //   expandSafeArea() —— 绘制区延伸进标题栏声明的组件安全区。
    // 缺了这两个，按钮上滑时不会从标题栏底下钻进去，渐变模糊「没东西可糊」。
    .clip(false)
    .expandSafeArea()
    .width('100%')
    .height('100%')
    // 顶部留白不写在 Scroll 上 —— ArkUI 会把 Scroll 的 padding 当 contentInset，
    // 把滚动内容整体上移（实测反而顶到时钟上）；留白写在滚动内容的内边距里。
    .backgroundColor(AppColor.pageBackground)
  }
}
