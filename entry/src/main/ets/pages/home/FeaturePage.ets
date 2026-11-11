import { AppRouter } from '../../common/AppRouter';
import { Toast } from '../../common/Toast';
import { AppColor, AppFont, AppMotion, AppSize } from '../../components/AppTheme';
import { topSafeInsetVp } from '../../common/ImmersiveUtil';
import { FeatureTile, SectionCard } from '../../components/CommonViews';
import { FeatureItem, advancedFeatures, basicFeatures } from '../../components/FeatureRegistry';
import { KEY_BREAKPOINT, fitColumnsToItems, templateOfColumns, tileColumnsTemplateFor } from '../../common/Breakpoint';

/** 单个磁贴的最小宽度（vp）：低于它 4 字标题就会被省略号吃掉。 */
const MIN_TILE_WIDTH: number = 84;
/** 磁贴列数上下限。 */
const MIN_COLUMNS: number = 2;
const MAX_COLUMNS: number = 8;

/**
 * 功能聚合页。
 *
 * 沿用 UBAA 的「普通功能 / 高级功能」两级分组，
 * 每个入口以网格磁贴呈现，图标与配色与 UBAA 保持一致。
 *
 * ## 列数按「自身宽度」算，不按窗口断点
 *
 * 分栏后本页会活在 300~400vp 的列表栏里，此时窗口断点是 md / lg（6 列），但可用
 * 宽度只有手机那么多 —— 按窗口断点取列会把标题全挤成省略号（真机实测）。
 * 官方做法是 `BreakpointsReference.ComponentSize`，这里用 `onAreaChange` 拿实测宽度，
 * 按「单格不小于 84vp」反推列数。
 */
@Component
export struct FeaturePage {
  stack: NavPathStack = new NavPathStack();
  /** 当前是否分栏（由 MainPage 传入）：分栏时点条目是替换右栏而不是压栈。 */
  @Prop splitMode: boolean = false;
  /**
   * 点条目前的回调。返回 true = 外层会立刻切成双列，此时要**延后一帧**再 push：
   * 分栏先就位，详情才以 push 动画从右侧滑入；否则先 push 后切模式，看到的是
   * 模式切换动画（内容区自左向右展开，像从左边挤出来）。
   */
  onWillOpen: () => boolean = () => false;

  @StorageProp(KEY_BREAKPOINT) private bp: string = 'sm';
  /**
   * 缓存的「按单格 84vp 能放几列」：只在**跨列边界**时写状态。
   *
   * 分栏切换时宽度是动画过渡的，onAreaChange 会连续回调几十次；若每次都用宽度驱动
   * 重建，网格会在动画里反复重排（肉眼可见的抖动）。缓存列数后动画期间只有跨边界
   * 的那一次重建，观感才顺。条目数的适配（整除 / 不超条目）在渲染时再算。
   */
  /**
   * 内容容器的**像素宽度**（我们自己驱动，0 表示还没量到、用 100%）。
   *
   * 为什么要这一层：分栏收放是 HDS 的原生动画，动画期间子节点不会逐帧重排，
   * 栅格列数只能"动画结束瞬间"跳一档。把内容宽度做成自己的状态、用 animateTo 补间，
   * 宽度就会逐帧真实变化 → 栅格每帧重排 → 磁贴是"连续挤窄"而不是"跳一下"。
   */
  @State private paneWidth: number = 0;

  private open(item: FeatureItem): void {
    if (item.route.length === 0) {
      Toast.show(item.title + ' · 敬请期待');
      return;
    }
    if (this.splitMode || !this.onWillOpen()) {
      AppRouter.open(this.stack, item.route, this.splitMode);
      return;
    }
    // 外层即将切分栏：等这一帧布局落定再 push，详情才会从右侧滑入
    AppRouter.openAfterLayout(this.stack, item.route, this.splitMode);
  }

  /** 列数由 paneWidth 现算；还没量到（paneWidth=0）时按窗口断点估。 */
  private columnsTemplate(items: FeatureItem[]): string {
    if (this.paneWidth <= 0) {
      return tileColumnsTemplateFor(this.bp, items.length);
    }
    // 列数**直接由 paneWidth 推导**，与内容列宽度同一个状态：
    // 若改从"实测宽度"读，动画期间会慢一拍（面板已经 675，栅格还按 7 列排窄格子，
    // 收尾时再一次性归位 —— 就是看到的那下"向左跳"）。
    const usable: number = this.paneWidth - AppSize.pagePadding * 2;
    let columns: number = Math.floor(usable / MIN_TILE_WIDTH);
    if (columns < MIN_COLUMNS) {
      columns = MIN_COLUMNS;
    }
    if (columns > MAX_COLUMNS) {
      columns = MAX_COLUMNS;
    }
    return templateOfColumns(fitColumnsToItems(columns, items.length, MIN_COLUMNS));
  }

  @Builder
  featureGrid(items: FeatureItem[]) {
    Grid() {
      ForEach(items, (item: FeatureItem) => {
        GridItem() {
          FeatureTile({
            title: item.title,
            icon: item.icon,
            color: item.color,
            onTileClick: () => {
              this.open(item);
            }
          })
        }
      }, (item: FeatureItem) => item.title)
    }
    .columnsTemplate(this.columnsTemplate(items))
    .columnsGap(AppSize.gapSmall)
    .rowsGap(AppSize.gap)
    .width('100%')
  }

  build() {
    Scroll() {
      // 外面包一层满宽 Row：内容列在动画期间会比面板窄，直接放进 Scroll 会被**居中**，
      // 于是收尾那一刻内容整体跳一下（实测左内边距从 20 变 55 再弹回 20）。
      // Row 撑满宽度 + Start 对齐，内容列就永远贴左边。
      Row() {
        Column({ space: AppSize.gapLarge }) {
        SectionCard({ title: '普通功能', subtitle: '课业相关的高频服务' }) {
          this.featureGrid(basicFeatures())
        }

        SectionCard({ title: '高级功能', subtitle: '按需开放' }) {
          this.featureGrid(advancedFeatures())
        }

        Blank()
          .height(AppSize.contentBottomInset)
      }
      // 宽度用像素、由我们自己补间（见下方 Scroll 的 onAreaChange）。
      // 未量到（paneWidth=0）时先退回 100%，首帧不会塌成 0。
      .width(this.paneWidth > 0 ? this.paneWidth : '100%')
      .padding({
        left: AppSize.pagePadding,
        right: AppSize.pagePadding,
        // 顶部让开「状态栏 + 悬浮标题栏（MINI，56vp）」。状态栏那一段的模糊由
        // PageShell 的磨砂层补上，视口必须从屏幕顶开始（见 MainPage.PageShell）；
        // 留白只能写在这里，写到外壳上会把视口压低、内容就滑不进磨砂层了。
        top: AppSize.destTopInset(topSafeInsetVp()),
        bottom: 0
      })
      // maxWidth 兜底：动画期间内容列**不许宽过面板**。
      .constraintSize({ minHeight: '100%', maxWidth: '100%' })
      // 一级页内容整体上移一点（纯视觉位移，见 AppSize.contentTopLift）
      .translate({ y: -AppSize.contentTopLift })
      }
      .width('100%')
      .justifyContent(FlexAlign.Start)
      .alignItems(VerticalAlign.Top)
      .constraintSize({ minHeight: '100%' })
    }
    .scrollBar(BarState.Off)
    // 量**面板**宽度（Scroll 是 100% 宽），并用 animateTo 把内容列宽补间过去：
    // HDS 的分栏收放是原生动画、子节点不逐帧重排，只有让内容宽度自己动起来，
    // 栅格才会逐帧重排、磁贴"连续挤窄"而不是"跳一档"。
    .onAreaChange((oldArea: Area, newArea: Area) => {
      const raw: Length = newArea.width;
      const total: number = typeof raw === 'number' ? raw : parseFloat(raw.toString());
      if (Math.abs(total - this.paneWidth) > 0.5) {
        // 与主页同一套时序：变宽 = 关闭分栏，等一小段再补间，让栅格归位和详情消失同时收尾。
        const closing: boolean = total > this.paneWidth;
        const run = (): void => {
          this.getUIContext().animateTo({
            duration: closing ? AppMotion.SPLIT_CLOSE_DURATION : AppMotion.SPLIT_DURATION,
            curve: Curve.Friction
          }, () => {
            this.paneWidth = total;
          });
        };
        if (closing) {
          setTimeout(run, AppMotion.SPLIT_CLOSE_DELAY);
        } else {
          run();
        }
      }
    })
    // 顶/底拖到边界时回弹（内容不足一屏也生效）
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    // 沉浸光感「三件套」之二 / 之三（配合 titleBar 的 enableComponentSafeArea）：
    //   clip(false)      —— 允许内容画到自身布局矩形之外；
    //   expandSafeArea() —— 绘制区延伸进标题栏声明的组件安全区。
    // 缺了这两个，磁贴上滑时不会从标题栏底下钻进去，渐变模糊「没东西可糊」。
    .clip(false)
    .expandSafeArea()
    .width('100%')
    .height('100%')
    // 顶部留白不写在 Scroll 上 —— ArkUI 会把 Scroll 的 padding 当 contentInset，
    // 把滚动内容整体上移（实测反而顶到时钟上）；留白写在滚动内容的内边距里。
    .backgroundColor(AppColor.pageBackground)
  }
}
