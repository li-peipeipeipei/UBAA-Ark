import { BackGuard } from '../common/BackGuard';
import { StartupPrefetch } from '../common/StartupPrefetch';
import { Toast } from '../common/Toast';
import { NavHero } from '../common/NavHero';
import { HeroMorph, KEY_HERO_PAGE_OPACITY, KEY_MORPH_TICK, MorphPhase, MorphRect } from '../common/HeroMorph';
import curves from '@ohos.curves';
import { FEATURE_STACK, HOME_STACK, KEY_MAIN_TAB_INDEX, MINE_STACK, SCHEDULE_STACK } from '../common/NavStacks';
import {
  HdsNavigation,
  HdsNavigationTitleBarOptions,
  HdsNavigationTitleMode,
  HdsTabs,
  HdsTabsController,
  ScrollEffectType,
  hdsMaterial
} from '@kit.UIDesignKit';
import { KEY_BOTTOM_SAFE_HEIGHT, topSafeInsetVp, systemBarStyleFor } from '../common/ImmersiveUtil';
import { Logger } from '../common/Logger';
import { ImmersiveUtil } from '../common/ImmersiveUtil';
import { AppColor, AppFont, AppSize, HERO_EXPAND_MS, HERO_LAND_BOUNCE, heroExpandCurve, heroShrinkCurve } from '../components/AppTheme';
import { ScheduleDayHeader, ScheduleHeaderModel, ScheduleTermChip, ScheduleWeekChips } from '../components/ScheduleHeader';
import { nativeFeatureRoute, routeBuilder } from './RouteBuilder';
import { HomePage } from './home/HomePage';
import { AppRouter } from '../common/AppRouter';
import { SchedulePage } from './academic/SchedulePage';
import { FeaturePage } from './home/FeaturePage';
import { MinePage } from './mine/MinePage';
import { KEY_BREAKPOINT, KEY_WINDOW_HEIGHT_VP, KEY_WINDOW_WIDTH_VP, sideNavWidthOf, useSideNav } from '../common/Breakpoint';
import { WideSideNav } from '../components/WideSideNav';
import { componentSnapshot } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { CardRefresher } from '../common/CardRefresher';
import { GlobalContext } from '../common/GlobalContext';

/**
 * 桌面卡片跳转用的 AppStorage key（写入方在 `EntryAbility`）。
 * - `pendingRoute`：页签标识 home / schedule / feature / mine
 * - `pendingPage`：可选，该页签内的二级路由名（exam / grade / classroom …）
 */
const KEY_PENDING_ROUTE: string = 'pendingRoute';
const KEY_PENDING_PAGE: string = 'pendingPage';

/**
 * 一级页面内容外壳。
 *
 * 只是一层「撑满 + 承载 @BuilderParam」的容器，**不再自己补模糊层**。
 *
 * 2026-09-20 起顶部模糊全部交给 HDS 自己：标题栏置了
 * `enableComponentSafeArea: true`（见 titleBar / scheduleTitleBar），HDS 把标题栏
 * 声明成组件级安全区，材质底板会一直铺到屏幕顶端（状态栏区域也盖上）。
 *
 * 之前是在这里叠一层 `Column().height(topSafeInsetVp()).backdropBlur(20)` 去盖状态栏，
 * 结果那一条的模糊强度与标题栏自带的系统材质对不上，两者交界处出现一条明显的横向
 * 断层（状态栏那一段更「糊」、下面那一段更「透」，像两块板拼接）—— 现在唯一模糊源
 * 就是标题栏自己的材质，接缝自然消失。
 *
 * 外壳本身**不加内边距**：加在外壳上的 padding 会被当成 contentInset 把滚动视口
 * 一并压低，内容就再也滑不进底板（二级页面踩过）。顶部留白改由各一级页自己的滚动
 * 内容承担（见各页 `.padding({ top: AppSize.destTopInset(topSafeInsetVp()) })`）。
 */
@Component
struct PageShell {
  @Builder
  empty() {
  }

  @BuilderParam content: () => void = this.empty;

  build() {
    Column() {
      this.content()
    }
    .width('100%')
    .height('100%')
  }
}

/**
 * 主容器：HDS 悬浮底栏 + 沉浸光感。
 *
 * 三条硬性约束（官方「页签栏悬浮样式」指南）：
 *   1. barPosition = BarPosition.End —— 页签位于容器底部
 *   2. vertical = false              —— 横向排布
 *   3. barOverlap = true             —— TabBar 叠加在 TabContent 之上
 * 满足后才允许通过 barFloatingStyle 配置悬浮样式与沉浸光感。
 *
 * 沉浸光感要点：
 *   - systemMaterialEffect.materialType = ADAPTIVE：由系统按设备算力自适应材质
 *   - systemMaterialEffect.materialLevel = ADAPTIVE：旗舰机完整效果，低端机自动降级
 *   - 标题栏走 HdsNavigation.titleBar.style 的同名参数
 * 两项能力均自 6.1.0(23) 起提供，本工程 compatibleSdkVersion 已对齐。
 */
@Component
export struct MainPage {
  @StorageProp(KEY_BOTTOM_SAFE_HEIGHT) bottomSafeHeight: number = 0;
  /**
   * 当前页签序号。**存进 AppStorage 而不是 @State** ——
   * 横竖屏切换会重建 MainPage（两个档位是两棵完全不同的组件树），
   * @State 会跟着归零，用户转个屏就回到主页。
   */
  @StorageLink(KEY_MAIN_TAB_INDEX) private currentIndex: number = 0;
  /** 宽度断点（AppStorage 由 ImmersiveUtil 的 windowSizeChange 写入）。 */
  @StorageProp(KEY_BREAKPOINT) @Watch('onBreakpointChange') private bp: string = 'sm';
  /**
   * 当前是否深色模式。
   *
   * 订阅它是为了让下方 HdsNavigation 的 `systemBarStyle` 在**切主题时重新求值** ——
   * 不订阅的话属性只在首次构建时算一次，切到深色后状态栏文字会保持黑字、贴在深色底上看不见。
   */
  @StorageProp('isDark') private isDark: boolean = false;

  /**
   * 桌面卡片带过来的页签请求（`EntryAbility.onCreate` / `onNewWant` 写入 AppStorage）。
   *
   * - `@StorageLink` 而不是 `AppStorage.get`：卡片在后台点进来时 MainPage **已经存在**，
   *   需要跟着 AppStorage 的变化一起更新（@Watch 触发切页签）；
   * - 冷启动时 MainPage 是在首页恢复登录态之后才建的，AppStorage 里已经有值，
   *   所以 `aboutToAppear` 也要消费一次。
   *
   * 消费完立刻清空：否则下次任意一次 AppStorage 写回都会把用户「弹」回课表页。
   */
  @StorageLink(KEY_PENDING_ROUTE) @Watch('onPendingRoute') pendingRoute: string = '';

  /** 卡片指定的二级页面（考试/成绩/空闲教室卡会带，课表卡不带）。 */
  @StorageLink(KEY_PENDING_PAGE) pendingPage: string = '';


  onLogout: () => void = () => {};

  private controller: HdsTabsController = new HdsTabsController();
  /**
   * HdsTabs 是否已经初始化过。
   *
   * **HdsTabs 被创建时会立刻回调一次 `onChange(0)`**（报「当前选中项是第 0 个」），
   * 这不是用户点的。横竖屏切换正好踩在这一点上：竖屏新建 HdsTabs → onChange(0)
   * 把 `currentIndex` 打回主页 —— 看起来就是「转个屏，APP 回到主页了」。
   * 所以首次 onChange 不当作用户切换，而是让 Tabs 去跟随已保存的页签。
   */
  private tabsReady: boolean = false;
  /**
   * 上一帧的布局分支（底部页签 false ↔ 侧边栏 true）。
   * 只有它翻转才说明 HdsTabs 被重建、需要重新吞一次初始化 onChange(0)。
   */
  private lastSideNav: boolean = false;

  /* ---------------- 卡片 → 全屏 的转场色块 ---------------- */

  /** 一块纯色：从卡片矩形变形到全屏（或反向）。 */
  @State private morphVisible: boolean = false;
  @State private morphX: number = 0;
  @State private morphY: number = 0;
  @State private morphW: number = 0;
  @State private morphH: number = 0;
  @State private morphRadius: number = 0;
  @State private morphColor: string = '#1976D2';
  /** 彩色层的透明度（与卡片同源：材质可用 0.86，否则 1）。展开时溶到 0 = 融进页面。 */
  @State private morphAccentOpacity: number = 0;
  /**
   * 底色层（页面底色）的透明度。
   *
   * 打开时要 1：色块褪色后剩下的是它，等于「融进页面本身」。
   * 收起时要 0：底色是纯黑（深色主题），若遮罩带着它淡入，页面溶解的目标就是**黑屏** ——
   * 逐帧实测有 2 帧纯黑。收起改让溶解直接露出背后的功能页网格，色块再凝结出来。
   */
  @State private morphBgOpacity: number = 1;
  /** 卡片上的图标 + 文字：随色块一起拉伸，才有「这张卡本身展开」的一体感。 */
  @State private morphContentScale: number = 1;
  @State private morphContentOpacity: number = 1;
  /**
   * 页面外壳标题条（返回钮占位 + 标题）的不透明度。
   *
   * 与彩色层互补：彩色层满（0.86）时必须是 0 —— 半透明彩色层会把它透出来，
   * 在卡片上留一枚幽灵标题（真机踩过）。彩色层褪去时它浮现 = 「主界面更早出现」，
   * 收起凝结时反向隐去。
   */
  @State private morphShellTitleOpacity: number = 0;
  /**
   * 收起转场用的「页面快照」：POP 时对目的地整页 componentSnapshot 拍下，
   * 放进遮罩里随块缩放 —— 收起缩的必须是**页面本身**（有内容），
   * 缩「空壳」会先变黑再缩、看不出缩小效果（用户实测）。拍不到时为 null，走空壳兜底。
   */
  @State private morphPageShot: image.PixelMap | null = null;
  /**
   * 整页尺寸（vp）：页面骨架按这个尺寸排布，再等比缩到块宽（宽随块、上下裁）。
   * 转场开始时从 AppStorage 的窗口尺寸写入。
   */
  @State private morphPageW: number = 0;
  @State private morphPageH: number = 0;
  @State private morphTitle: string = '';
  private morphIcon: Resource | null = null;
  private morphAlpha: number = 1;
  @State private morphOpacity: number = 1;
  @StorageProp(KEY_MORPH_TICK) @Watch('onMorphTick') private morphTick: number = 0;

  /** 页面底色：色块放大到位后要「融进」它，浅色 / 深色主题不同。 */
  private pageBg(): string {
    // 键名曾误写 'isDarkMode'（写入方是 'isDark'）→ 深色下取不到值，
    // 转场时色块会「融进」浅灰底而不是黑底。用已订阅的 this.isDark。
    return this.isDark ? '#000000' : '#F1F3F5';
  }

  /**
   * 转场编排（全在这里，DestShell 只跟着 `heroPageOpacity` 淡入淡出）。
   *
   * 入场：色块从卡片矩形放大到全屏、圆角→0、颜色→页面底色；放到一半时页面 0→1 淡入。
   * 退场：色块铺满 → 页面淡出 → pop → 色块缩回卡片、圆角复原、颜色变回卡片色。
   */
  /** 放大收尾只做一次（onFinish 与兜底定时器都会调）。 */
  private expandDone: boolean = false;
  /** 收起收尾只做一次（onFinish 与兜底定时器都会调）。 */
  private shrinkDone: boolean = false;
  /**
   * POP 兜底的轮次号：每次 POP 接管转场时 +1，延时回调带着自己的号回来。
   *
   * 防止「上一次 POP 的兜底定时器」在用户已经重新点开一张卡之后才触发 ——
   * 那一发会把新一轮的转场 proxy 提前放掉。
   */
  private popGuardToken: number = 0;
  /**
   * 转场序号：每开一轮（EXPAND / SHRINK）+1。
   *
   * 定时器必须带着自己那一轮的序号回来 —— 否则「展开还没播完就按了返回」时，
   * 展开那批定时器还会继续执行：520ms 的收尾会把收起中的遮罩直接藏掉、
   * 并提前 `finishTransition()`，画面会突然断掉（真机会这样）。
   */
  private morphSeq: number = 0;

  /**
   * 「卡片 → 全屏」的遮罩动画（打开 / 收起共用一套矩形动画）。
   *
   * ## 为什么用导航**外面**的一层遮罩
   *
   * 直接在 `NavDestination` 的内容上做 scale/translate 实测无效：日志显示动画正常播完、
   * 状态也确实是终值，但画面停在初始大小（系统在转场期间冻结了目的地的渲染）。
   * 而这一层是 MainPage 的普通子节点，`animateTo` 改 width/height/position 稳定可靠。
   *
   * ## 结构（三层，缺一不可）
   *
   * ```
   * ① 页面底色        —— 颜色淡去后剩下的是它，等于「融进页面本身」
   * ② 彩色层          —— 基础色 + 与卡片相同的透明度（0.86），起点颜色才能和卡片一模一样
   * ③ 图标 + 文字     —— 跟着色块一起放大 / 缩小，做出一体感
   * ```
   *
   * 时序（打开）：几何 450ms（M3 DurationLong1；曲线由 `AppTheme.heroExpandCurve()` 决定，
   *   `USE_APPLE_CURVES` 可一键切回 springMotion(0.3,0.82)）；色块 48~112ms 褪完（相对点按）；
   *   270ms 页面就位、350ms 遮罩淡出 110ms、530ms 收尾放行。
   * 时序（收起）：几何 450ms 固定时长（弹簧的 onFinish 比视觉停稳晚很多，会显得回弹滞后）；
   *   颜色 100ms 起 160ms（260ms 盖满）；几何 onFinish 收尾（兜底 530ms）。
   */
  /**
   * 骨架里返回箭头的路径（px 坐标），与 HeroDetailLayer.arrowPath() 完全一致。
   *
   * 展开动画期间屏幕上显示的是本页自绘的「页面骨架」，不是真实目的页；
   * 所以骨架里的返回钮也必须画出同一支箭头，否则放大过程中只有一个空圆圈，
   * 等骨架淡出、真实页接管时才突然冒出箭头（用户看到的「快照没有返回箭头」）。
   */
  private morphArrowPath(): string {
    const k: number = this.getUIContext().vp2px(1);
    const x0: string = (0.715 * k).toFixed(1);
    const x1: string = (7.855 * k).toFixed(1);
    const y0: string = (0.715 * k).toFixed(1);
    const ym: string = (8.285 * k).toFixed(1);
    const y1: string = (15.855 * k).toFixed(1);
    return 'M ' + x1 + ' ' + y0 + ' L ' + x0 + ' ' + ym + ' L ' + x1 + ' ' + y1;
  }

  onMorphTick(): void {
    const phase: MorphPhase = HeroMorph.getPhase();
    if (phase === MorphPhase.IDLE) {
      this.morphVisible = false;
      return;
    }
    const navW: number = this.sideNavLayout() ? sideNavWidthOf(this.bp) : 0;
    const winW: number = AppStorage.get<number>(KEY_WINDOW_WIDTH_VP) ?? 375;
    const winH: number = AppStorage.get<number>(KEY_WINDOW_HEIGHT_VP) ?? 800;
    // 内容区宽度 = 整窗宽 - 侧栏宽，横屏分栏下这才是二页的真实宽度。
    const fullW: number = winW - navW;
    /**
     * 页面骨架必须按**内容区**尺寸（fullW × winH）排布，而不是整窗宽 winW。
     *
     * 骨架末尾会统一乘 `scale = morphW / morphPageW`（见下方 build 里的页面骨架），
     * 这个 scale 默认以**中心**为原点。此前 morphPageW 写的是 winW：
     *   - 竖屏 navW=0 → fullW=winW、scale=1，看不出问题；
     *   - 横屏分栏 navW>0 → 终态 scale=fullW/winW<1，骨架虽然被缩回 fullW 宽，
     *     但高度 winH 也一起被缩，且中心缩放把顶边往下推了 winH*(1-scale)/2。
     *     真机表现：动画里的标题（含加载圈）比最终页面低几十 vp，溶接时跳一下。
     *
     * 改成 fullW 后终态 scale=1，骨架与真实页面逐像素重合；
     * 中途帧仍按「宽随块、上下裁」等比缩放，观感不变。
     */
    this.morphPageW = fullW;
    this.morphPageH = winH;
    // card.x / card.y 是卡片的**屏幕坐标**（FeatureTile 上报），所以直接用
    const card: MorphRect = HeroMorph.getCard();
    // 图标 / 文字按宽度比例放大：色块长到全屏时它们也长到对应倍数，始终「长在一块上」
    const endScale: number = card.w > 0 ? fullW / card.w : 1;

    if (phase === MorphPhase.EXPAND) {
      this.shrinkDone = false;
      this.expandDone = false;
      this.morphSeq = this.morphSeq + 1;
      const seq: number = this.morphSeq;
      this.morphAlpha = HeroMorph.getAlpha();
      this.morphTitle = HeroMorph.getTitle();
      this.morphIcon = HeroMorph.getIcon();
      // ① 首帧就是「这张卡」：实心卡片色（同透明度）、卡片圆角、卡片矩形、图标文字原位
      this.morphX = card.x;
      this.morphY = card.y;
      this.morphW = card.w;
      this.morphH = card.h;
      this.morphRadius = card.radius;
      this.morphColor = HeroMorph.getColor();
      this.morphAccentOpacity = this.morphAlpha;
      this.morphContentScale = 1;
      this.morphContentOpacity = 1;
      this.morphShellTitleOpacity = 0;
      // 上一轮收起若被打断，快照可能还在 —— 打开绝不能顶着旧快照
      this.morphPageShot = null;
      this.morphOpacity = 1;
      this.morphBgOpacity = 1;
      this.morphVisible = true;
      // 目的地一开始不可见：遮罩的「页面骨架」负责放大中的画面，真实页面到溶接时才登场
      AppStorage.setOrCreate<number>(KEY_HERO_PAGE_OPACITY, 0);
      // ⚠️ 必须等一帧：初值与 animateTo 在同一帧内提交会被合并成「直接到终值」
      setTimeout(() => {
        // ① 几何：色块从卡片矩形长到全屏（图标/文字同步拉伸）。
        //    时长见 `HERO_EXPAND_MS`（M3 DurationLong1 = 450ms，英雄转场档位）。
        this.getUIContext().animateTo(
          { duration: HERO_EXPAND_MS, curve: heroExpandCurve() },
          () => {
            this.morphX = navW;
            this.morphY = 0;
            this.morphW = fullW;
            this.morphH = winH;
            this.morphRadius = 0;
            this.morphContentScale = endScale;
          }
        );
        // ② 颜色更早淡出 + 图标文字同窗淡出 + 外壳标题条浮现。
        //    相对**点按**：48ms 开始褪、112ms 完全消失（64ms 时长；外层还有 32ms 首帧错开，
        //    所以这里的延时是 16ms）。
        //    分窗是安全的：外壳层全程在场，任何时刻都有一层撑着，不会出黑场。
        setTimeout(() => {
          if (seq !== this.morphSeq) {
            return;
          }
          this.getUIContext().animateTo({ duration: 64, curve: Curve.EaseOut }, () => {
            this.morphAccentOpacity = 0;
            this.morphContentOpacity = 0;
            this.morphShellTitleOpacity = 1;
          });
        }, 16);
        // ③ 真实内容接管，分两步 —— 先让页面就位，再撤遮罩。
        //
        // 为什么不能「页面淡入 + 遮罩淡出同窗」：真机连拍 6 帧显示，遮罩先变半透明、
        // 而页面透明度还没上来，中间那几帧透出的是**背后的功能网格**（整屏发暗），
        // 随后页面再渐显时又和骨架的转圈/字叠成两层 —— 观感是「先暗下去再渐显」。
        //
        // 正确做法：此时遮罩是**整块不透明**的（颜色层已褪、只剩底色 + 标题栏 + 圈），
        // 把页面透明度直接拉回 1 用户完全看不见；随后遮罩淡出时，下面已经是画好的
        // 真实页面 —— 交叉的只是「骨架内容淡出 ↔ 真实内容透出」，永远不会露出网格。
        setTimeout(() => {
          if (seq !== this.morphSeq) {
            return;
          }
          AppStorage.setOrCreate<number>(KEY_HERO_PAGE_OPACITY, 1);
        }, 270);
        //    ④ 解冻目的地：**必须早于遮罩淡出**。
        //
        //    自定义转场期间系统会冻结目的地的渲染（见 `NativeHeroDest` 头注释：
        //    transform/状态都正常但「画面停在初始大小」）。所以上一步 270ms 设的
        //    `pageOpacity = 1` 只是一次状态赋值，**画面不会更新** —— 目的地仍然
        //    停在挂载首帧（那时 opacity 是 0，即全透明）。
        //    若此时直接淡出遮罩，下面什么都没有：标题只能跟着遮罩一起变暗，
        //    到 530ms `finishExpand` 解冻时页面突然出现 → 「放大到全屏后闪一下」。
        //    300ms 时几何已走完 99.4%（差 2.3vp 满屏，缺口落在页面右侧 padding
        //    之外，与遮罩同色看不出），放行后页面在遮罩后面正常绘制，淡出才安全。
        setTimeout(() => {
          if (seq !== this.morphSeq) {
            return;
          }
          NavHero.finishTransition();
        }, 300);
        //    ⑤ 遮罩淡出：骨架与真实页此刻内容同构（同底色、同位置标题栏、同位置同尺寸
        //    的加载圈），110ms 的重合过渡几乎是「内容原地浮现」；再短就成硬切了。
        setTimeout(() => {
          if (seq !== this.morphSeq) {
            return;
          }
          Logger.info('HERO dissolve-in');
          this.getUIContext().animateTo({ duration: 110, curve: Curve.EaseInOut }, () => {
            this.morphOpacity = 0;
          });
        }, 350);
        // 收尾：淡出在 460ms 结束，留一档余量再放行
        setTimeout(() => {
          if (seq !== this.morphSeq) {
            return;
          }
          this.finishExpand();
        }, 530);
      }, 32);
      return;
    }

    // SHRINK：完全反向的打开 —— 页面溶进外壳，外壳块收缩，颜色最后凝结。
    //
    // ① 的交叉是「全屏 ↔ 全屏」：页面与外壳此时**天然重合、圆角都是 0**，
    // 满足「界面要和块重合、圆角符合」。之后壳块带着标题条收缩（界面始终在块内）。
    this.shrinkDone = false;
    this.morphSeq = this.morphSeq + 1;
    const seq: number = this.morphSeq;
    // 落点用**实测矩形**（FeaturePage 每次 onAreaChange 刷新），不用点开时的快照：
    // 展开期间网格若因内容加载位移几 vp，旧坐标会让遮罩停在偏一点的位置，最后跳到真卡片
    // （真机实测：最后一帧尺寸正确但整体下移 19px）。
    const land: MorphRect = HeroMorph.getLandingCard();
    this.morphX = navW;
    this.morphY = 0;
    this.morphW = fullW;
    this.morphH = winH;
    this.morphRadius = 0;
    this.morphColor = HeroMorph.getColor();
    this.morphAlpha = HeroMorph.getAlpha();
    this.morphAccentOpacity = 0;
    this.morphContentScale = endScale;
    this.morphContentOpacity = 0;
    // 外壳在场：有页面快照时遮罩内容 = 整页快照（与真实页面像素一致）；
    // 拍不到时退回「底色 + 标题条」空壳兜底。
    this.morphShellTitleOpacity = 1;
    this.morphBgOpacity = 1;
    this.morphVisible = true;
    if (this.morphPageShot !== null) {
      // 快照与页面像素一致：直接接管 —— 不经过任何「页面溶进外壳=变黑」的中间态
      this.morphOpacity = 1;
      AppStorage.setOrCreate<number>(KEY_HERO_PAGE_OPACITY, 0);
    } else {
      // 空壳兜底：**页面不参与淡出**，只把遮罩淡入。
      //
      // ⚠️ 不能让页面 1→0 与遮罩 0→1 同时跑：两层各半透明时，白字的等效不透明度
      // = a + (1−a)·b，中间帧只有 0.75 —— 标题栏会明显暗一档又亮回来（真机可见闪烁）。
      // 页面保持不透明，遮罩淡入时合成恒为 1；等遮罩满值（110ms，此时切换不可见）
      // 再把页面撤到 0，相当于一次不可见的硬切。
      //
      // 顺带修掉另一个隐患：页面淡到 0 时半透明遮罩会透出背后的功能网格
      // （整屏发暗、隐约见卡片），页面常驻后永远不会露底。
      this.morphOpacity = 0;
      this.getUIContext().animateTo({ duration: 110, curve: Curve.EaseIn }, () => {
        this.morphOpacity = 1;
      });
      setTimeout(() => {
        if (seq !== this.morphSeq) {
          return;
        }
        AppStorage.setOrCreate<number>(KEY_HERO_PAGE_OPACITY, 0);
      }, 110);
    }
    // ① 几何立刻开始：**页面快照随块缩放** = 「页面在缩小」，全程可见
    //    （此前缩的是空壳：先变黑再缩，看不出缩小效果 —— 用户实测）。
    setTimeout(() => {
      if (seq !== this.morphSeq) {
        return;
      }
      this.getUIContext().animateTo(
        // 固定时长：弹簧的 onFinish 明显滞后于视觉停稳，回弹会晚半拍（用户实测反馈）。
        // 收尾挂 onFinish（而不是定时器）：animateTo 的实际首帧比调用晚一帧，
        // 固定时长定时器会比动画早到约 16ms —— FastOutSlowIn 尾部极慢，
        // 那 16ms 还差 3~6% 路程，遮罩会在「高出一截、整体偏下」的状态被隐藏，
        // 然后跳到真卡片（真机连拍：高度多 20px、底边多 26px 的那一帧）。
        {
          // 450 = M3 DurationLong1（与放大同一档，往返对称）
          duration: 450,
          curve: heroShrinkCurve(),
          onFinish: () => {
            if (seq !== this.morphSeq) {
              return;
            }
            this.finishShrink();
          }
        },
        () => {
          this.morphX = land.x;
          this.morphY = land.y;
          this.morphW = land.w;
          this.morphH = land.h;
          this.morphRadius = land.radius;
          this.morphContentScale = 1;
        }
      );
      // ② 颜色更晚出现（100ms 起 **160ms**，260ms 盖满 —— 比 450ms 几何早 190ms）；
      //    页面快照同窗溶进颜色。标题条同步隐去（互补时序，杜绝幽灵标题）。
      setTimeout(() => {
        if (seq !== this.morphSeq) {
          return;
        }
        this.getUIContext().animateTo({ duration: 160, curve: Curve.EaseOut }, () => {
          this.morphAccentOpacity = this.morphAlpha;
          this.morphContentOpacity = 1;
          this.morphShellTitleOpacity = 0;
          this.morphBgOpacity = 0;
        });
      }, 100);
      // 兜底：onFinish 万一不回调（动画被系统打断等），也必须把卡片放出来 ——
      // 否则卡片会一直保持隐藏（`finishShrink` 自带幂等，正常路径不会重复执行）
      setTimeout(() => {
        if (seq !== this.morphSeq) {
          return;
        }
        this.finishShrink();
      }, 530);
    }, 16);
  }

  /** 放大到位：遮罩已经淡到 0，移除目的地（此刻画面早已是页面本身）。 */
  private finishExpand(): void {
    if (this.expandDone) {
      return;
    }
    this.expandDone = true;
    this.morphVisible = false;
    HeroMorph.finish();
    NavHero.finishTransition();
  }

  /** 收缩落地：移除目的地 → 真实卡片露出，立刻回弹。 */
  private finishShrink(): void {
    if (this.shrinkDone) {
      return;
    }
    this.shrinkDone = true;
    // 遮罩此刻与真实卡片像素级重合，直接隐藏看不出切换
    this.morphVisible = false;
    // 快照用完即清（PixelMap 占显存，也防止下一轮误用旧图）
    this.morphPageShot = null;
    // 真卡片此刻才登场：收起全程保持隐藏 —— 半透明的 0.86 彩色层下不会再透出
    // 「同名卡片」，落地也没有双层边缘（此前的「收回最后稍有错位」就是它）
    NavHero.notifyTileShow();
    AppStorage.setOrCreate<number>(KEY_HERO_PAGE_OPACITY, 1);
    HeroMorph.finish();
    NavHero.finishTransition();
    // 回弹由 `AppTheme.HERO_LAND_BOUNCE` 控制（当前关闭 → 卡片落位即静止）。
    //
    // 历史：早先延 16ms 触发（怕遮罩还盖着看不见），后来改成同帧 —— 遮罩在上一行
    // 已经隐藏、真卡片同帧显示，弹动一定看得见；延后一帧反而多出一帧「停在原位」。
    // ⚠️ 重新打开时注意：`FeatureTile.onBounce` 里的 16ms 不能动 —— 那里的用途是让
    // 「缩到 0.98」先落一帧，否则「赋值 + 启动回弹」同帧合并，缩的动作会整个消失。
    if (HERO_LAND_BOUNCE) {
      NavHero.notifyBounce();
    }
  }

  /**
   * 断点变化 = 布局分支切换（侧边栏 ↔ 底部页签），两棵不同的组件树，
   * 竖屏那棵里的 `HdsTabs` 是**新创建**的，会再报一次 `onChange(0)`。
   * 把初始化标记归零，好让下一次回调被当成「初始化」而不是「用户切换」。
   *
   * ⚠️ 但**只有分支真的翻转**（useSideNav 前后不一致）才归零：
   * 冷启动时窗口尺寸回调会让断点在 sm/md 之间抖动，两者都走底部页签、
   * HdsTabs 根本没有重建 —— 这时归零会把用户紧随其后的一次点按
   * 误当成初始化吞掉（冷启动「底栏第一时间点不动」的真因，真机复现过）。
   */
  onBreakpointChange(): void {
    const side: boolean = this.sideNavLayout();
    if (side !== this.lastSideNav) {
      this.lastSideNav = side;
      this.tabsReady = false;
    }
  }

  // 四个栈是模块级单例（common/NavStacks）：横竖屏切换重建组件时栈与栈里的页面都还在。
  private homeStack: NavPathStack = HOME_STACK;
  private scheduleStack: NavPathStack = SCHEDULE_STACK;
  private featureStack: NavPathStack = FEATURE_STACK;
  private mineStack: NavPathStack = MINE_STACK;

  aboutToAppear(): void {
    // 官方建议：状态栏样式要在页面生命周期里调用才稳定生效
    // （窗口级 API 单独调用容易被后续页面/系统重置）
    ImmersiveUtil.refreshSystemBar();
    // 诊断：横竖屏切换后重建 MainPage 时这条会出现，栈与页签仍应保留（见 common/NavStacks）
    Logger.info('MainPage aboutToAppear，currentIndex=' + this.currentIndex);
    // 冷启动路径：AppStorage 里已有值时，这里把它吃掉
    this.applyRoute(this.pendingRoute);
    // 把桌面卡片对齐到「今天」。卡片数据原先只在课表页加载/切周时写，
    // 不进课表页就会一直挂着几天前的快照（周次、日期、日卡的「明天」全错）。
    // 这里只读本地缓存重算，不联网；延迟一拍让首屏先渲染完，别抢布局时间。
    setTimeout(() => {
      CardRefresher.refresh(GlobalContext.getContext());
    }, 600);
    // 首帧之后预热最常用的几份数据（课表/考试/成绩），详见 common/StartupPrefetch。
    // 它内部还会再等 900ms、只写内存缓存不碰界面 —— 不参与首帧，也不改首帧结构。
    StartupPrefetch.start();
  }

  private onPendingRoute(): void {
    this.applyRoute(this.pendingRoute);
  }

  /**
   * 按 `target` 切到对应页签（认不出就不动），再按 `page` 压入二级页面。
   *
   * `page` 只在 feature 页签有意义 —— 卡片要落的二级页面（考试/成绩/空闲教室）
   * 全都挂在功能页的 NavPathStack 下。压栈前必须先 `clear()`，
   * 否则会叠在用户之前停留的那个二级页上。
   */
  private applyRoute(target: string): void {
    if (target.length === 0) {
      return;
    }
    // 冷启动时 MainPage 可能先于 `pendingPage` 的写入？两个 key 同一次 want 里写出，
    // 这里都同步读一次即可。
    const page: string = this.pendingPage;
    AppStorage.set<string>(KEY_PENDING_ROUTE, '');
    AppStorage.set<string>(KEY_PENDING_PAGE, '');
    let index: number = -1;
    if (target === 'home') {
      index = 0;
    } else if (target === 'schedule') {
      index = 1;
    } else if (target === 'feature') {
      index = 2;
    } else if (target === 'mine') {
      index = 3;
    }
    if (index < 0) {
      Logger.warn('未知的卡片跳转目标：' + target);
      return;
    }
    // 目标页签若有二级页面在栈里，先清干净 —— 卡片进来的应该是该页签的根页面
    this.clearStack(index);
    // 宽屏没有 HdsTabsController，切页签靠 currentIndex 驱动 if/else 分支
    this.currentIndex = index;
    this.controller.changeIndex(index);
    if (index === 2 && page.length > 0) {
      // 卡片深链也算一次「使用」（走 open 才会记进最近使用）
      AppRouter.open(this.featureStack, page);
    }
  }

  /**
   * 课表页顶部「学期 / 周次」选择器的共享状态（见 ScheduleHeader.ScheduleHeaderModel）。
   *
   * MainPage 持有它、并把它渲染进课表页的标题栏；SchedulePage 拿到**同一个实例**
   * 负责写数据和挂回调 —— 两边不是父子关系，靠这个 @Observed 实例当桥。
   */
  @State private scheduleHeader: ScheduleHeaderModel = new ScheduleHeaderModel();

  /**
   * 四个页签**各自一张固定栈的路由表**，互不干扰。
   *
   * ## 为什么不用一张 routeMap 按 currentIndex 猜栈（重要）
   *
   * `navDestination` 的回调签名只有 `(name, param)`，拿不到栈 —— 曾经用一张
   * `routeMap` 按 `currentIndex` 间接取栈（`stackOf(this.currentIndex)`）。
   * 但 `currentIndex` 是「界面当前显示的页签」，**不一定等于本次 push 用的栈**：
   * 桌面卡片深链（下一节课）会在冷启动时改 `currentIndex` / 界面停在别处，
   * 此时从主页「最近使用」push 到 homeStack，目的地却按错位的 currentIndex
   * 绑到空栈（scheduleStack）—— 页面正常显示、能滑动，但 `onBackPressed`
   * 弹的是空栈，返回直接卡死（真机复现，日志 push size=1 / back size=0）。
   *
   * 治本：让每个 Navigation 的 `navDestination` 用**固定绑定自己栈**的 @Builder，
   * 目的地里的 `stack` 与 push 时用的栈恒为同一实例，与 `currentIndex` 彻底解耦。
   * 各 Navigation 本就显式绑定了各自的栈（`HdsNavigation(this.homeStack)` 等），
   * 路由表跟着固定下来只是让这条约束显式化。
   */
  @Builder
  homeRouteMap(name: string, param: object) {
    routeBuilder(name, param, this.homeStack);
  }

  @Builder
  scheduleRouteMap(name: string, param: object) {
    routeBuilder(name, param, this.scheduleStack);
  }

  @Builder
  featureRouteMap(name: string, param: object) {
    routeBuilder(name, param, this.featureStack);
  }

  @Builder
  mineRouteMap(name: string, param: object) {
    routeBuilder(name, param, this.mineStack);
  }

  /** 功能页签的原生路由表（`Navigation` 专用，见 RouteBuilder.nativeFeatureRoute）。 */
  @Builder
  nativeRouteMap(name: string, param: object) {
    nativeFeatureRoute(name, param, this.featureStack);
  }

  /** 按页签序号取对应的导航栈（「再点一次回主页」时清空它）。 */
  private stackOf(index: number): NavPathStack {
    if (index === 0) {
      return this.homeStack;
    }
    if (index === 1) {
      return this.scheduleStack;
    }
    if (index === 2) {
      return this.featureStack;
    }
    return this.mineStack;
  }

  /** 宽屏侧栏点选：等价 HdsTabs 的 onChange + onTabBarClick 两个回调。 */
  /**
   * 清栈回到该页签的根页面。
   *
   * **功能页签（index 2）必须硬切**：功能页的大按钮进二级页就是硬切（产品要求），
   * 返回按钮也是硬切；如果点底部页签「功能」时的清栈带着滑出动画，就会看到
   * 「二级页滑走 + 列表页滑入」——与同一场景的其它返回方式不一致。
   * 其余页签保持默认（带动画），与它们的 push / pop 对称。
   */
  private clearStack(index: number): void {
    if (index === 2) {
      const stack: NavPathStack = this.stackOf(index);
      if (NavHero.isTopHero() && stack.size() === 1) {
        // 只有一层时带动画清栈，正好走上「缩回卡片」的转场；
        // 真卡片由 finishShrink 放出（收起全程隐藏，防 0.86 彩色层透出同名卡片）
        stack.clear(true);
      } else {
        // `clear(false)` 不播转场，没有 POP 回调 / finishShrink 去放卡片 ——
        // 这里必须把原卡片放出来（实测：点「功能」回到网格后，考试安排那张卡是空的）。
        NavHero.notifyTileShow();
        stack.clear(false);
      }
    } else {
      this.stackOf(index).clear();
    }
  }

  /**
   * 功能页签的自定义转场。
   *
   * 只接管两种情况，其余一律 `undefined`（走系统默认滑入/滑出）：
   * - **PUSH**：本次点击记录了卡片矩形（`NavHero.hasCard()`）→ 目的地从卡片位置放大；
   * - **POP**：当前栈顶是「卡片展开页」（`NavHero.hasActive()`）→ 让它缩回卡片。
   *
   * 两个关键点：
   * 1. 我们只负责**存住 proxy**，动画由目的地 `NativeHeroDest` 自己演，
   *    演完它调 `NavHero.finishTransition()`。系统在那之前不会移除页面。
   * 2. `timeout` 是兜底：万一动画回调没来，系统也会在超时后强制结束，
   *    不会把用户卡在「转场中」的不可交互状态。
   */
  private heroTransition(from: NavContentInfo, to: NavContentInfo,
    operation: NavigationOperation): NavigationAnimatedTransition | undefined {
    Logger.info('HERO op=' + operation + ' from=' + (from.name ?? '-') + ' to=' + (to.name ?? '-') +
      ' heroRoute=' + NavHero.isHeroRoute(to.name ?? '') + ' card=' + NavHero.hasCard() +
      ' active=' + NavHero.isTopHero());
    if (operation === NavigationOperation.PUSH) {
      // 只有「支持卡片展开的路由」+ 刚记过卡片矩形才接管
      if (!NavHero.isHeroRoute(to.name ?? '') || !NavHero.hasCard()) {
        return undefined;
      }
      const push: NavigationAnimatedTransition = {
        timeout: 900,
        transition: (proxy: NavigationTransitionProxy) => {
          // 作废上一轮 POP 的兜底定时器：那一发会把本轮 proxy 提前放掉（画面无动画直接切）
          this.popGuardToken = this.popGuardToken + 1;
          NavHero.holdProxy(proxy);
          // ⚠️ 这里**绝对不能**调 componentSnapshot（或其它强制定格的手段）：
          // 实测在 PUSH 的 hold 期间拍一次图，系统会把自己的默认「右侧滑入」放出来，
          // 页面在遮罩外面从右侧滑进屏幕（19:32 版没有这段代码就完全不滑，加了才滑）。
          // 遮罩的放大载体是「页面骨架」，本来也不需要打开时拍快照。
        }
      };
      return push;
    }
    if (operation === NavigationOperation.POP) {
      if (!NavHero.isTopHero()) {
        /**
         * 不接管转场（博雅 → 我的课程、成绩 → 详情 这类页内二级页都走系统默认）。
         *
         * 但**必须兜底放开原卡片**：正常路径下原卡片是 `finishShrink()` 放回来的，
         * 这条分支没有收缩动画、`finishShrink` 不会执行。于是「卡片展开页 → 页内二级页
         * → 一路返回功能页」时，如果「展开页 → 功能页」那一次 POP 也被判成非 hero
         * （二级页的 shell 还没出栈、或展开页内容被系统回收导致 close 收不到），
         * 就再没有任何地方发 `KEY_HERO_TILE_SHOW`，功能页那张卡**永远保持隐藏**。
         * 真机表现：功能块消失，但位置上仍能点进去，再进出一次才恢复
         * （2026-11-22 博雅 → 我的课程 → 返回，复现）。
         *
         * 判据用「pop 之后栈是否回到根」而不是 `to.name`：`NavContentInfo.name` 在
         * 根页面上填什么没有文档保证，栈深是确定的。延时是因为回调里栈还没 pop 完。
         */
        setTimeout(() => {
          if (this.featureStack.size() === 0) {
            NavHero.notifyTileShow();
            Logger.info('HERO 回到功能页但未走收缩转场，兜底放开原卡片');
          }
        }, 60);
        return undefined;
      }
      // ⚠️ 这个回调是在**渲染管线里同步调用**的，此处直接改 AppStorage / @State 会抛
      // JS Error（实测：点返回直接崩进程，exit 254，栈顶就落在这一行）。
      // 所以状态改动统统延后一帧。
      this.expandDone = false;
      // 本轮收缩标记先归零：下面那个兜底要判断「这一轮到底有没有演过收缩」
      this.shrinkDone = false;
      const guard: number = this.popGuardToken + 1;
      this.popGuardToken = guard;
      /**
       * 收缩信号兜底（1200ms）。
       *
       * 接管了转场，但目的地可能在这个期间被系统回收/重建，`KEY_HERO_CLOSE` 的
       * @Watch 收不到 → `startShrink()` 从不执行 → 900ms 转场超时后 proxy 被释放，
       * 而 `finishShrink()` 没跑过 → 原卡片一直隐藏（与上面那条同样的症状）。
       * 超时后强制收尾：放开卡片 + 结束转场，避免卡在「转场中」。
       */
      setTimeout(() => {
        if (guard !== this.popGuardToken || this.shrinkDone) {
          return;
        }
        Logger.warn('HERO 收缩未开始（1200ms），强制收尾并放开原卡片');
        this.finishShrink();
      }, 1200);
      setTimeout(() => {
        // 收起前先给目的页拍一张**整页快照**：遮罩里缩的是页面本身（含内容），
        // 才有「页面在缩小」的观感（只缩空壳 = 先变黑再缩，看不出缩小 —— 用户实测）。
        // 快照就绪才开演；80ms 还没回来就先开演（此时走空壳兜底），不让点击等拍。
        // ⚠️ 真卡片这里**不能**放出来：遮罩彩色层是 0.86 半透明，收起全程会透出
        // 下面的同名卡片（用户实测）。真卡片到 finishShrink（落地帧）才登场。
        let started: boolean = false;
        const go: () => void = (): void => {
          if (started) {
            return;
          }
          started = true;
          HeroMorph.startShrink();
        };
        componentSnapshot.get('heroPageShot').then((shot: image.PixelMap): void => {
          if (!started) {
            this.morphPageShot = shot;
          }
          go();
        }).catch(() => {
          go();
        });
        setTimeout(go, 80);
      }, 0);
      const pop: NavigationAnimatedTransition = {
        timeout: 900,
        transition: (proxy: NavigationTransitionProxy) => {
          NavHero.holdProxy(proxy);
        }
      };
      return pop;
    }
    return undefined;
  }

  private onWideSelect(index: number): void {
    if (index === this.currentIndex) {
      // 「再点当前项回主页」：清栈后自动退回单栏（栈深归零）
      this.clearStack(index);
      return;
    }
    this.dropStaleBackGuards();
    this.currentIndex = index;
    // 切到课表页时通知它刷新当前周（页签内容是常驻的，onPageShow 不触发）
    if (index === 1) {
      this.scheduleHeader.onRefresh();
    }
  }

  /**
   * 切页签时清掉上一页留下的返回键登记。
   *
   * 页签内容是**常驻**的（HdsTabs 不销毁、`aboutToDisappear` 不触发），页面里打开的
   * 浮层（公告正文、筛选面板、学期选择…）注册的 `BackGuard` 层会一直留在全局栈里。
   * 用户切到别的页签再按返回时，那层「关掉一个看不见的面板」的动作先吃掉这次返回，
   * 表现就是**返回键失灵**（要按第二次）。
   *
   * 代价：原页签里仍然开着的面板，回来后按返回不再先关它（还能点面板自己的关闭按钮 /
   * 点遮罩关掉）。相比「全局返回键失灵」，这个代价可接受。
   */
  private dropStaleBackGuards(): void {
    BackGuard.clear();
  }

  /** 是否用侧边导航形态（平板横屏 / 2in1 / 宽自由窗口）。平板竖屏仍走底部页签。 */
  private sideNavLayout(): boolean {
    return useSideNav(this.bp);
  }

  /**
   * 四个一级页面共用的标题栏配置 —— **只留底板，不留文字**。
   *
   * 为什么去掉大标题：四个页面的第一屏内容本身就说明了所处位置（「晚上好，沛轩」
   * 的问候卡、课表的周次选择、功能的九宫格、我的头像卡），再挂一个「主页 / 课表」
   * 大标题既重复，又把内容硬生生压下 112vp。现在不配置 `content.title`，标题栏
   * 不再绘制任何文字，内容直接从状态栏下方开始。
   *
   * 为什么不丢渐变模糊：滚动效果与光感材质挂在 `style` 上，只要标题栏还在，内容
   * 上滑经过它下方时照样会浮出渐变模糊底板 —— 这正是要保留的效果。状态栏那一段
   * 由 PageShell 的磨砂层补齐（视口从屏幕顶开始），标题栏（MINI，56vp）之下才是
   * 内容的首行，见各页 `.padding({ top: AppSize.destTopInset(topSafeInsetVp()) })`。
   *
   * avoidLayoutSafeArea = true 是关键：置 false 会让 HdsNavigation 的整块内容
   * 上移约一个状态栏的高度（实测内容从 50vp 提到 10vp），静止状态就压在状态栏
   * 时钟上、还会一直被底板模糊 —— 试过，不可用。置 true 后标题栏被约束在安全区
   * 内，内容从状态栏下方开始，静止态干净。
   *
   * 另外 4 个 HdsNavigation 都显式置 `titleMode(HdsNavigationTitleMode.MINI)`（56vp）
   * 并 `hideBackButton(true)`。
   *
   * MINI 的原因：悬浮标题栏虽然不画文字，但**它的布局盒仍然吃触摸**。FREE 模式默认
   * 112vp，状态栏下沿到 112vp 这一整条带上的内容点不动 —— 「功能」页第一排磁贴正好
   * 落在带里（实测点瓦片中心无响应、点它的文字标签才进得去）。MINI 后死区收窄到
   * 56vp，只压住卡片的标题文字（不可点），磁贴全部可点，视觉与光感均无变化。
   *
   * hideBackButton 的原因：MINI 模式的标题栏按 HDS 规范会渲染一个返回按钮，而一级
   * 页面是根页面、没有上一级可退（实测 MINI 后左上角冒出一个孤零零的返回箭头）。
   * 隐藏后标题栏只剩那块透明底板，正好是想要的。
   *
   * enableComponentSafeArea 的原因（6.0.0(20) 起，顶部模糊无缝的关键）：
   * 置 true 后 HDS 把标题栏声明成「组件级安全区」，标题栏的材质底板会连**状态栏**
   * 一起覆盖，同时标题栏内文字/胶囊仍从状态栏下沿开始排。此前 statusBar 那一条靠
   * 外壳自叠一层 backdropBlur 兜底，与标题栏自带材质强度不一致 —— 两者交界处有一条
   * 明显横线（用户反馈的「状态栏部分的模糊和下面的不一样」）。现在只有一个模糊源。
   */
  private titleBar(): HdsNavigationTitleBarOptions {
    return {
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true,
      style: {
        // 初始态底色显式置透明：不设的话首帧会先铺一层实心底色，
        // 与后面浮出的材质换挡，快速滚动时能看到闪一下。
        originalStyle: {
          backgroundStyle: {
            backgroundColor: Color.Transparent
          }
        },
        scrollEffectOpts: {
          enableScrollEffect: true,
          // IMMERSIVE_GRADIENT_BLUR 自 6.1.0(23) 起提供，抹得更「沉浸」：
          // 渐变过渡更长（默认 56vp），内容从底板下淡出而不是被硬切一刀。
          scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      }
    };
  }

  /**
   * 课表页标题栏主区：学期胶囊 + 「第 N 周」。
   *
   * 左右留白写在这里、不写 `HdsNavigationTitleBarOptions.padding` ——
   * 实测那个 padding 只作用于标题栏自带的标题区，对自定义 stackBuilder / bottomBuilder
   * 内容不生效（胶囊依旧贴着屏幕左边）。（此前试过，已回退。）
   */
  @Builder
  scheduleTermTitle() {
    Row() {
      ScheduleTermChip({ model: this.scheduleHeader })
    }
    .width('100%')
    .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
  }

  /** 课表页标题栏下沿：周次胶囊 + 「周几 / 日期」行（第一版：直接放在标题栏里，靠系统材质模糊）。 */
  @Builder
  scheduleWeekTitle() {
    Column() {
      ScheduleWeekChips({ model: this.scheduleHeader })
      ScheduleDayHeader({ model: this.scheduleHeader })
    }
    .width('100%')
  }

  /**
   * 课表页专用标题栏 —— 与其它三个页签同款底板与光感，但**带内容**。
   *
   * 主区（stackBuilder）挂学期选择器，下沿（bottomBuilder）挂周次选择器。这样
   * 「学期 + 周次」常驻悬浮标题栏、永远贴在状态栏下方，课表网格不再被它们往下压；
   * 而且它们属于标题栏自己的布局盒，不受「标题栏吃触摸」影响，照常可点。
   */
  private scheduleTitleBar(): HdsNavigationTitleBarOptions {
    return {
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true,
      style: {
        originalStyle: {
          backgroundStyle: {
            backgroundColor: Color.Transparent
          }
        },
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      },
      content: {
        // 注意：这里必须用箭头函数包一层，**不能**直接写 `stackBuilder: this.scheduleTermTitle`。
        // HDS 收到的是普通 options 对象，直接传方法引用时调用方是那个对象，
        // `this` 丢失 → @Builder 内生成的 `this.observeComponentCreation2` 取到 undefined，
        // 运行时抛 "Cannot read property observeComponentCreation2 of undefined" 并闪退。
        // 箭头函数捕获外层 this，@Builder 仍在 MainPage 实例上执行。
        stackBuilder: (): void => {
          this.scheduleTermTitle();
        },
        bottomBuilder: {
          builder: (): void => {
            this.scheduleWeekTitle();
          },
          // 周次胶囊 44 + 日期行 44
          height: AppSize.scheduleWeekBarHeight + 44
        }
      }
    };
  }

  /** 手机端原布局：整段逐字保留，零回归。 */
  @Builder
  narrowTabs() {
    HdsTabs({ controller: this.controller }) {
      TabContent() {
        HdsNavigation(this.homeStack) {
          PageShell() {
            HomePage({
              stack: this.homeStack,
            })
          }
        }
        .navDestination(this.homeRouteMap)
        .titleBar(this.titleBar())
        .titleMode(HdsNavigationTitleMode.MINI)
        .hideBackButton(true)
        // HDS 未设 systemBarStyle 时按 SystemBarStyle 默认值 '#E5FFFFFF'（白）托管状态栏；
        // 页面一下拉/滚动，HDS 动态样式重新生效，会把 window 接口设的黑色刷回白。
        // 官方明确「不建议混合使用 systemBarStyle 和 window 接口」→ 这里显式托管。
        .systemBarStyle(systemBarStyleFor(this.isDark), systemBarStyleFor(this.isDark))
        .mode(NavigationMode.Stack)
      }
      .tabBar(new BottomTabBarStyle($r('app.media.ic_home'), $r('app.string.tab_home')))

      TabContent() {
        HdsNavigation(this.scheduleStack) {
          PageShell() {
            SchedulePage({ stack: this.scheduleStack, header: this.scheduleHeader })
          }
        }
        .navDestination(this.scheduleRouteMap)
        .titleBar(this.scheduleTitleBar())
        .titleMode(HdsNavigationTitleMode.MINI)
        .hideBackButton(true)
        // 同上：状态栏内容色显式托管给 HDS，避免下拉滚动时被默认白覆盖
        .systemBarStyle(systemBarStyleFor(this.isDark), systemBarStyleFor(this.isDark))
        .mode(NavigationMode.Stack)
      }
      .tabBar(new BottomTabBarStyle($r('app.media.ic_schedule'), $r('app.string.tab_schedule')))

      TabContent() {
        // 功能页签用**原生 Navigation**：只有它能给到 `customNavContentTransition`
        // （完全接管 push/pop）与跨页共享元素。其余三个页签仍是 HdsNavigation，
        // 保留 HDS 的标题栏与沉浸光感。
        Navigation(this.featureStack) {
          PageShell() {
            FeaturePage({
              stack: this.featureStack,
            })
          }
        }
        .navDestination(this.nativeRouteMap)
        .mode(NavigationMode.Stack)
        // 原生 Navigation 的 systemBarStyle 只收**一个**参数（不像 HdsNavigation 有两档）。
        // 一级页没有标题栏、内容铺满屏幕，状态栏必须显式给色，否则同样被默认白接管。
        .systemBarStyle(systemBarStyleFor(this.isDark))
        // 功能页一级页没有标题栏（只有卡片网格），内容从屏幕顶开始，
        // 网格位置由页面内的 destTopInset 自己补
        .hideTitleBar(true)
        // 转场完全由我们接管（HDS 的 HdsNavigation 不会回调这个，原生 Navigation 会）。
        // ⚠️ 必须用箭头函数包一层：直接把方法引用传进去时 `this` 不会绑定，
        // 回调里访问 `this.xxx` 会抛 `TypeError: Obj is not a Valid object` 并崩进程（踩过）。
        .customNavContentTransition((from: NavContentInfo, to: NavContentInfo,
          operation: NavigationOperation) => this.heroTransition(from, to, operation))
      }
      .tabBar(new BottomTabBarStyle($r('app.media.ic_apps'), $r('app.string.tab_feature')))

      TabContent() {
        HdsNavigation(this.mineStack) {
          PageShell() {
            MinePage({
              stack: this.mineStack,
              onLogout: () => {
                this.onLogout();
              }
            })
          }
        }
        .navDestination(this.mineRouteMap)
        .titleBar(this.titleBar())
        .titleMode(HdsNavigationTitleMode.MINI)
        .hideBackButton(true)
        // HDS 未设 systemBarStyle 时按 SystemBarStyle 默认值 '#E5FFFFFF'（白）托管状态栏；
        // 页面一下拉/滚动，HDS 动态样式重新生效，会把 window 接口设的黑色刷回白。
        // 官方明确「不建议混合使用 systemBarStyle 和 window 接口」→ 这里显式托管。
        .systemBarStyle(systemBarStyleFor(this.isDark), systemBarStyleFor(this.isDark))
        .mode(NavigationMode.Stack)
      }
      .tabBar(new BottomTabBarStyle($r('app.media.ic_person'), $r('app.string.tab_mine')))
    }
    // ---- 悬浮三件套 ----
    .barOverlap(true)
    .barPosition(BarPosition.End)
    .vertical(false)
    // ⚠️ **关闭「左右滑动切换页签」**：用户要求 4 个底部栏不再能通过左右滑切换，
    // 把这一手势让给各页自己用（例如课表页用左右滑切教学周）。
    // 注意：这只关掉「内容区横滑切页签」，底部 TabBar 的点击切换不受影响。
    .scrollable(false)
    // ---- 悬浮样式 + 沉浸光感 ----
    .barFloatingStyle({
      // 底部间距跟随手势导航条高度，避免与系统导航条重叠
      barBottomMargin: this.bottomSafeHeight + AppSize.tabBarBottomMargin,
      gradientMask: {
        // 走资源引用，深色模式下不再出现白色渐变遮罩
        maskColor: AppColor.tabBarMask,
        maskHeight: 92
      },
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.ADAPTIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      }
    })
    // 横屏：底部页签栏高度收成 0（不显示，由左侧导航替代），内容让开侧栏宽度；
    // 竖屏：恢复原样。**这正是「转屏不重建」的关键** —— HdsTabs 一直在树上。
    .barHeight(this.sideNavLayout() ? 0 : AppSize.tabBarHeight)
    .padding({ left: this.sideNavLayout() ? sideNavWidthOf(this.bp) : 0 })
    .onChange((index: number) => {
      // 首次回调是 HdsTabs 的初始化（**必然是 0**），不是用户点的 ——
      // 不要据此改 currentIndex，而是让新建的 Tabs 跟随保存的页签。
      // ⚠️ 只有 index === 0 才允许走「初始化」分支：用户在冷启动窗口里的
      // 第一次点按（index≠0）若是第一发回调，绝不能被当成初始化吞掉再拉回原页签。
      if (!this.tabsReady && index === 0) {
        this.tabsReady = true;
        if (index !== this.currentIndex) {
          // changeIndex 会再回调一次 onChange（此时 tabsReady 已 true），
          // 于是 currentIndex 被同步到正确值。
          this.controller.changeIndex(this.currentIndex);
        }
        return;
      }
      this.tabsReady = true;
      this.dropStaleBackGuards();
      this.currentIndex = index;
      // 切到课表页时通知它刷新当前周。
      //
      // 为什么不用 SchedulePage.onPageShow：实测在 HdsTabs 的页签切换下**不触发**
      // （切走再切回，上游请求 0 次）—— 页签内容是常驻的，页面可见性回调不跟着页签走。
      // 页签切换的权威信号是这个 onChange。
      if (index === 1) {
        this.scheduleHeader.onRefresh();
      }
    })
    // 「再点一次当前页签 → 回到该页主页」：
    // onTabBarClick 在**每次点击页签**时都会触发（含点当前页签）。如果点的是当前页签，
    // 说明用户想「回顶部/回主页」，就把这个页签的导航栈清空（栈空了会退回根页面）。
    .onTabBarClick((index: number) => {
      // 点「功能」：无论当前在不在功能页，都先收起卡片浮层（它不在导航栈里）
      if (index === 2) {
      }
      // ⚠️ 先把 currentIndex 落地再判分支：onChange 的「初始化回调必然是 0」
      // 与「用户点了主页」在数据上无法区分 —— 冷启动时用户第一下点「主页」
      // 会被初始化分支拉回原页签（真机复现：第一时间点不动）。onTabBarClick
      // 只在真实点按时触发，这里先写入目标页签，初始化分支比对相等就不会拉回。
      // 点按本身已经完成切换，**不需要** changeIndex（再调会让 onChange 双发、
      // 课表的 onRefresh 跟着跑两遍）。
      const was: number = this.currentIndex;
      this.currentIndex = index;
      // 「再点一次当前页签 → 回到该页主页」：
      // 点的是当前页签，说明用户想「回顶部/回主页」，就把这个页签的导航栈清空
      // （栈空了会退回根页面）。
      if (index === was) {
        this.clearStack(index);
      }
    })
    .backgroundColor(AppColor.pageBackground)
    .width('100%')
    .height('100%')
  }

  /** 宽屏布局：侧边导航 + 当前页签的 HdsNavigation（lg / xxl 走 Split 三栏）。 */
  @Builder
  wideLayout() {
    Row() {
      WideSideNav({
        currentIndex: this.currentIndex,
        bp: this.bp,
        onSelect: (index: number) => {
          this.onWideSelect(index);
        }
      })

      if (this.currentIndex === 0) {
        HdsNavigation(this.homeStack) {
          PageShell() {
            HomePage({
              stack: this.homeStack,
            })
          }
        }
        .navDestination(this.homeRouteMap)
        .titleBar(this.titleBar())
        .titleMode(HdsNavigationTitleMode.MINI)
        .hideBackButton(true)
        // HDS 未设 systemBarStyle 时按 SystemBarStyle 默认值 '#E5FFFFFF'（白）托管状态栏；
        // 页面一下拉/滚动，HDS 动态样式重新生效，会把 window 接口设的黑色刷回白。
        // 官方明确「不建议混合使用 systemBarStyle 和 window 接口」→ 这里显式托管。
        .systemBarStyle(systemBarStyleFor(this.isDark), systemBarStyleFor(this.isDark))
        .mode(NavigationMode.Stack)
        .navBarPosition(NavBarPosition.Start)
        .layoutWeight(1)
      } else if (this.currentIndex === 1) {
        HdsNavigation(this.scheduleStack) {
          PageShell() {
            SchedulePage({ stack: this.scheduleStack, header: this.scheduleHeader })
          }
        }
        .navDestination(this.scheduleRouteMap)
        .titleBar(this.scheduleTitleBar())
        .titleMode(HdsNavigationTitleMode.MINI)
        .hideBackButton(true)
        // 同上：状态栏内容色显式托管给 HDS，避免下拉滚动时被默认白覆盖
        .systemBarStyle(systemBarStyleFor(this.isDark), systemBarStyleFor(this.isDark))
        .mode(NavigationMode.Stack)
        .navBarPosition(NavBarPosition.Start)
        .layoutWeight(1)
      } else if (this.currentIndex === 2) {
        HdsNavigation(this.featureStack) {
          PageShell() {
            FeaturePage({
              stack: this.featureStack,
            })
          }
        }
        .navDestination(this.featureRouteMap)
        .titleBar(this.titleBar())
        .titleMode(HdsNavigationTitleMode.MINI)
        .hideBackButton(true)
        // HDS 未设 systemBarStyle 时按 SystemBarStyle 默认值 '#E5FFFFFF'（白）托管状态栏；
        // 页面一下拉/滚动，HDS 动态样式重新生效，会把 window 接口设的黑色刷回白。
        // 官方明确「不建议混合使用 systemBarStyle 和 window 接口」→ 这里显式托管。
        .systemBarStyle(systemBarStyleFor(this.isDark), systemBarStyleFor(this.isDark))
        .mode(NavigationMode.Stack)
        .navBarPosition(NavBarPosition.Start)
        .layoutWeight(1)
      } else {
        HdsNavigation(this.mineStack) {
          PageShell() {
            MinePage({
              stack: this.mineStack,
              onLogout: () => {
                this.onLogout();
              }
            })
          }
        }
        .navDestination(this.mineRouteMap)
        .titleBar(this.titleBar())
        .titleMode(HdsNavigationTitleMode.MINI)
        .hideBackButton(true)
        // HDS 未设 systemBarStyle 时按 SystemBarStyle 默认值 '#E5FFFFFF'（白）托管状态栏；
        // 页面一下拉/滚动，HDS 动态样式重新生效，会把 window 接口设的黑色刷回白。
        // 官方明确「不建议混合使用 systemBarStyle 和 window 接口」→ 这里显式托管。
        .systemBarStyle(systemBarStyleFor(this.isDark), systemBarStyleFor(this.isDark))
        .mode(NavigationMode.Stack)
        .navBarPosition(NavBarPosition.Start)
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
  }

  build() {
    // **HdsTabs 是唯一的内容容器，横竖屏切换时它不重建。**
    //
    // 之前横屏走 wideLayout（Row + 侧栏 + 另一套 HdsNavigation）、竖屏走 narrowTabs
    // （HdsTabs + TabContent），两棵完全不同的组件树 —— 转屏时整棵换掉，于是：
    // 页面组件全部重建（数据重新加载）、Index 闪「正在恢复登录状态」、
    // HdsTabs 新建时报 onChange(0) 把页签打回主页。
    //
    // 现在只有一套 HdsTabs：横屏时把底部页签栏高度收成 0、内容让开左侧侧栏，
    // 侧栏叠在上面；竖屏时反过来。转屏只是切换外壳的可见性，页面实例一直在树上。
    //
    // alignContent: Start —— 侧栏是 Stack 里唯一「不占满」的子节点，默认居中会跑到
    // 屏幕中间（踩过：`.align()` 在 @Component 上不生效）。
    Stack({ alignContent: Alignment.Start }) {
      this.narrowTabs()

      // 转场遮罩：盖在内容区之上、侧栏之下（侧栏始终可见）。
      // 它是 MainPage 的普通子节点 —— 不在 Navigation 的转场里，animateTo 改
      // width/height/position 一定生效（目的页内容上的 transform 会被系统冻结）。
      if (this.morphVisible) {
        // 三层：页面外壳（底色 + 标题条）→ 彩色层（与卡片同透明度）→ 图标文字（随块一起拉伸）
        Stack() {
          // ① 页面外壳：页面底色 + 与 HeroDetailLayer 同构的标题条。
          //    它被彩色层盖住时就是「这张卡」；彩色层褪去后它是「主界面」的壳 ——
          //    天生就是块的矩形 + 块的圆角（外层 Stack 的 clip/borderRadius），
          //    满足「界面要和块重合、圆角符合」。真实内容在块长满时无缝接管。
          //    ⚠️ 底色必须满铺**不参与缩放**：跟内容一起缩放会只盖住左上一小块，
          //    彩色层是 0.86 半透明，其余部分直接漏出网格（真机踩过：整块变半透明）。
          Stack({ alignContent: Alignment.Center }) {
            // 页面骨架：**按整页尺寸（morphPageW×morphPageH）排布**，再等比缩放到
            // 「块宽 / 页宽」、居中 —— 宽度永远贴合块宽，块装不下的上下部分被外层裁掉，
            // 与快照的 Cover 规则完全一致（用户要求：宽随块、裁上下、不许拉伸）。
            // 为什么不直接用快照：展开期页面必须隐身（opacity≈0），componentSnapshot
            // 会把祖先透明度一起算进图里 —— 拍出来是全透明图（真机两轮实测）。
            // 收起方向页面 opacity=1，快照照常能拍，仍然叠在骨架上（能拍到就盖住它）。
            Column() {
              Row({ space: 8 }) {
                // 返回钮：与 HeroDetailLayer 同构（40vp 圆钮 + 自绘箭头）。
                // 之前这里只有纯色圆圈占位、没有箭头 —— 放大过程中显示的就是这套骨架，
                // 所以看起来「快照里没有返回箭头」，等真页接管才突然出现。现补齐同款箭头。
                Stack() {
                  Column()
                    .width(40)
                    .height(40)
                    .borderRadius(20)
                    .backgroundColor(AppColor.circleButtonSurface)
                  Path()
                    .commands(this.morphArrowPath())
                    // commands 是 px、width/height 是 vp（靠 morphArrowPath 内 vp2px 换算）。
                    // 显式给尺寸，否则本机按内容算成 0×0 箭头不显示（同 HeroDetailLayer 踩坑）。
                    .width(8.57)
                    .height(16.57)
                    .stroke(AppColor.textPrimary)
                    .strokeWidth(1.43)
                    .strokeLineCap(LineCapStyle.Round)
                    .strokeLineJoin(LineJoinStyle.Round)
                    .fill(Color.Transparent)
                    .translate({ x: -1.42, y: -0.29 })
                }
                .width(40)
                .height(40)

                Text(this.morphTitle)
                  .fontSize(AppFont.title)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(AppColor.textPrimary)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })

                Blank()
              }
              .width('100%')
              // 与真实标题栏同高（56vp）、同内边距（16/16）、同间距（8）——
              // 全屏时与真实标题栏逐像素重合（数值按 HDS 返回键的实拍位置量出）
              .height(56)
              .padding({ left: 16, right: 16 })
              .alignItems(VerticalAlign.Center)

              // 加载圈：位置必须与真实页的 LoadingView **完全一致**（内容顶下来 80vp、
              // 水平居中、40×40、brand 色）—— 交叉过渡时两个圈完全重合，观感是
              // 「一个圈」，不是上下错位的两个转圈。
              // 不画「正在获取…」文字：各页文案不同（「正在获取考试安排…」等），
              // 两条不同长度的灰字叠在一起是交叉期最刺眼的重影（真机连拍可见）。
              Column() {
                LoadingProgress()
                  .width(40)
                  .height(40)
                  .color(AppColor.brand)
              }
              .width('100%')
              .layoutWeight(1)
              .padding({ top: 80 })
              .alignItems(HorizontalAlign.Center)
            }
            .width(this.morphPageW)
            .height(this.morphPageH)
            .backgroundColor(this.pageBg())
            .padding({ top: topSafeInsetVp() })
            // 宽度贴块：缩放比 = 块宽 / 页宽（morphW 在动画中，这个比例随之变化）
            .scale({
              x: this.morphPageW > 0 ? this.morphW / this.morphPageW : 1,
              y: this.morphPageW > 0 ? this.morphW / this.morphPageW : 1
            })
            // 受控浮现：彩色层满时为 0（防透过 0.86 彩色层留痕），彩色褪去后为 1
            .opacity(this.morphShellTitleOpacity)

            if (this.morphPageShot !== null) {
              // 真快照（收起方向能拍到）：同样 Cover —— 宽随块、上下裁
              Image(this.morphPageShot)
                .width('100%')
                .height('100%')
                .objectFit(ImageFit.Cover)
                .interpolation(ImageInterpolation.Medium)
                .draggable(false)
            }
          }
          .width('100%')
          .height('100%')
          .backgroundColor(this.pageBg())
          .opacity(this.morphBgOpacity)

          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(this.morphColor)
            .opacity(this.morphAccentOpacity)

          Column({ space: 12 }) {
            if (this.morphIcon !== null) {
              Image(this.morphIcon)
                .width(40)
                .height(40)
                .fillColor(Color.White)
                .opacity(0.9)
                .draggable(false)
            }
            Text(this.morphTitle)
              .fontSize(AppFont.subtitle)
              .fontWeight(FontWeight.Medium)
              .fontColor(Color.White)
              .opacity(0.95)
              .maxLines(1)
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          // 以中心缩放：块在长大时，图标与文字同步长大，看上去是同一张卡在展开
          .scale({ x: this.morphContentScale, y: this.morphContentScale })
          .opacity(this.morphContentOpacity)
        }
        .width(this.morphW)
        .height(this.morphH)
        .borderRadius(this.morphRadius)
        // 裁掉放大后溢出的图标文字
        .clip(true)
        .opacity(this.morphOpacity)
        .position({ x: this.morphX, y: this.morphY })
        .hitTestBehavior(HitTestMode.None)
      }

      if (this.sideNavLayout()) {
        this.sideNavOverlay()
      }
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 横屏左侧导航：叠在 HdsTabs 之上。
   *
   * 点击走 `controller.changeIndex` —— 与底部页签是**同一套内容**，
   * 只是换了外壳，所以切页签 / 转屏都不会重建页面。
   */
  @Builder
  sideNavOverlay() {
    WideSideNav({
      currentIndex: this.currentIndex,
      bp: this.bp,
      onSelect: (index: number) => {
        // 点「功能」：先收起卡片浮层（与底部页签一致）
        if (index === 2) {
          }
        if (index === this.currentIndex) {
          // 「再点当前项」清栈回主页
          this.clearStack(index);
          return;
        }
        this.controller.changeIndex(index);
      }
    })
    .width(sideNavWidthOf(this.bp))
    .height('100%')
  }
}
