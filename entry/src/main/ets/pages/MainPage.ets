import { BackGuard } from '../common/BackGuard';
import { Toast } from '../common/Toast';
import { FeatureHero, HERO_BOUNCE_TICK, KEY_FEATURE_HERO_CLOSE } from '../common/FeatureHero';
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
import { KEY_BOTTOM_SAFE_HEIGHT, topSafeInsetVp } from '../common/ImmersiveUtil';
import { webview } from '@kit.ArkWeb';
import { Logger } from '../common/Logger';
import { AppColor, AppFont, AppSize } from '../components/AppTheme';
import { ScheduleDayHeader, ScheduleHeaderModel, ScheduleTermChip, ScheduleWeekChips } from '../components/ScheduleHeader';
import { nativeFeatureRoute, routeBuilder } from './RouteBuilder';
import { HomePage } from './home/HomePage';
import { SchedulePage } from './academic/SchedulePage';
import { FeaturePage } from './home/FeaturePage';
import { MinePage } from './mine/MinePage';
import { KEY_BREAKPOINT, KEY_WINDOW_HEIGHT_VP, KEY_WINDOW_WIDTH_VP, sideNavWidthOf, useSideNav } from '../common/Breakpoint';
import { WideSideNav } from '../components/WideSideNav';

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
  /** 卡片上的图标 + 文字：随色块一起拉伸，才有「这张卡本身展开」的一体感。 */
  @State private morphContentScale: number = 1;
  @State private morphContentOpacity: number = 1;
  @State private morphTitle: string = '';
  private morphIcon: Resource | null = null;
  private morphAlpha: number = 1;
  @State private morphOpacity: number = 1;
  @StorageProp(KEY_MORPH_TICK) @Watch('onMorphTick') private morphTick: number = 0;

  /** 页面底色：色块放大到位后要「融进」它，浅色 / 深色主题不同。 */
  private pageBg(): string {
    const dark: boolean = AppStorage.get<boolean>('isDarkMode') ?? false;
    return dark ? '#000000' : '#F1F3F5';
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
   * 时序（打开）：几何 340ms；180ms 起遮罩整体淡出 260ms；440ms 收尾放行。
   * 时序（收起）：几何 320ms 固定时长（弹簧的 onFinish 比视觉停稳晚很多，会显得回弹滞后）。
   */
  onMorphTick(): void {
    const phase: MorphPhase = HeroMorph.getPhase();
    if (phase === MorphPhase.IDLE) {
      this.morphVisible = false;
      return;
    }
    const navW: number = this.sideNavLayout() ? sideNavWidthOf(this.bp) : 0;
    const winW: number = AppStorage.get<number>(KEY_WINDOW_WIDTH_VP) ?? 375;
    const winH: number = AppStorage.get<number>(KEY_WINDOW_HEIGHT_VP) ?? 800;
    // card.x / card.y 是卡片的**屏幕坐标**（FeatureTile 上报），所以直接用
    const card: MorphRect = HeroMorph.getCard();
    const fullW: number = winW - navW;
    // 图标 / 文字按宽度比例放大：色块长到全屏时它们也长到对应倍数，始终「长在一块上」
    const endScale: number = card.w > 0 ? fullW / card.w : 1;

    if (phase === MorphPhase.EXPAND) {
      this.shrinkDone = false;
      this.expandDone = false;
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
      this.morphOpacity = 1;
      this.morphVisible = true;
      // 目的地一开始不可见：等遮罩铺满并开始淡出时它才登场
      AppStorage.setOrCreate<number>(KEY_HERO_PAGE_OPACITY, 0);
      // ⚠️ 必须等一帧：初值与 animateTo 在同一帧内提交会被合并成「直接到终值」
      setTimeout(() => {
        this.getUIContext().animateTo(
          { curve: curves.springMotion(0.32, 0.82) },
          () => {
            this.morphX = navW;
            this.morphY = 0;
            this.morphW = fullW;
            this.morphH = winH;
            this.morphRadius = 0;
            // 颜色与图标/文字**同一条曲线**一起淡出：两层始终同进同退
            this.morphAccentOpacity = 0;
            this.morphContentOpacity = 0;
            // 图标 / 文字跟着色块一起长大
            this.morphContentScale = endScale;
          }
        );
        // 交叉过渡：遮罩整体淡出 + 页面淡入放在同一个 animateTo 里 ——
        // 两者的曲线、时长、起止完全一致，不会出现「一层没了另一层还没来」的黑场。
        // ⚠️ 页面透明度必须显式拉回 1：它在前一帧被设成 0（避免转场瞬间闪页面），
        // 忘了拉回来的话，遮罩淡完就是**一片黑**（真机踩过）。
        setTimeout(() => {
          // 用户可能在放大还没结束时就按了返回：阶段已经变了就别再推打开的那套值
          if (HeroMorph.getPhase() !== MorphPhase.EXPAND) {
            return;
          }
          this.getUIContext().animateTo({ duration: 260, curve: Curve.EaseOut }, () => {
            this.morphOpacity = 0;
            AppStorage.setOrCreate<number>(KEY_HERO_PAGE_OPACITY, 1);
          });
        }, 230);
        // 收尾：不再依赖弹簧的 onFinish（它比视觉停稳晚很多，页面会显得「出来得慢」）
        setTimeout(() => {
          this.finishExpand();
        }, 520);
      }, 32);
      return;
    }

    // SHRINK：遮罩先铺满并把页面隐去 —— 收缩时露出的应是功能页，而不是这一页。
    this.shrinkDone = false;
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
    this.morphOpacity = 1;
    this.morphVisible = true;
    AppStorage.setOrCreate<number>(KEY_HERO_PAGE_OPACITY, 0);
    setTimeout(() => {
      this.getUIContext().animateTo(
        // 固定时长：弹簧的 onFinish 明显滞后于视觉停稳，回弹会晚半拍（用户实测反馈）
        { duration: 320, curve: Curve.FastOutSlowIn },
        () => {
          this.morphX = card.x;
          this.morphY = card.y;
          this.morphW = card.w;
          this.morphH = card.h;
          this.morphRadius = card.radius;
          // 与打开对称：颜色与图标/文字同一条曲线一起回来
          this.morphAccentOpacity = this.morphAlpha;
          this.morphContentOpacity = 1;
          this.morphContentScale = 1;
        }
      );
      // 与几何同一时长收尾：落地即回弹，中间不留空档
      setTimeout(() => {
        this.finishShrink();
      }, 320);
    }, 32);
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
    AppStorage.setOrCreate<number>(KEY_HERO_PAGE_OPACITY, 1);
    HeroMorph.finish();
    NavHero.finishTransition();
    // 回弹放在下一帧：先让 grid 真正露出来，弹动才看得见（同帧弹会被上面那层盖掉）
    setTimeout(() => {
      NavHero.notifyBounce();
    }, 16);
  }

  /**
   * 断点变化 = 布局分支切换（侧边栏 ↔ 底部页签），两棵不同的组件树，
   * 竖屏那棵里的 `HdsTabs` 是**新创建**的，会再报一次 `onChange(0)`。
   * 把初始化标记归零，好让下一次回调被当成「初始化」而不是「用户切换」。
   */
  onBreakpointChange(): void {
    this.tabsReady = false;
  }

  /* 站内网页提交浮层（覆盖底栏，全屏） */
  @StorageProp('spocWebOpen') @Watch('onSpocWebOpenChange') private spocWebOpen: boolean = false;
  @StorageProp('spocWebLogin') private spocWebLogin: string = '';
  @StorageProp('spocWebDetail') private spocWebDetail: string = '';
  private mainWebCtrl: webview.WebviewController = new webview.WebviewController();
  private mainWebLoaded: boolean = false;

  /**
   * 网页提交浮层（盖在整个应用上，含底部页签）的开关。
   *
   * **返回键优先级由这里登记，不由 SpocPage 登记**：浮层是 MainPage 渲染的，
   * 渲染方登记才不会在页面销毁时留下指向死实例的闭包。只要 `spocWebOpen` 变 true，
   * 不论从哪个入口打开，返回键都能先关掉这一层。
   */
  onSpocWebOpenChange(): void {
    // 全屏模态一定是最上面一层，先清掉可能残留的旧登记
    BackGuard.clear();
    if (this.spocWebOpen) {
      this.mainWebLoaded = false;
      BackGuard.register(() => {
        AppStorage.setOrCreate('spocWebOpen', false);
        return true;
      });
    }
  }
  // 四个栈是模块级单例（common/NavStacks）：横竖屏切换重建组件时栈与栈里的页面都还在。
  private homeStack: NavPathStack = HOME_STACK;
  private scheduleStack: NavPathStack = SCHEDULE_STACK;
  private featureStack: NavPathStack = FEATURE_STACK;
  private mineStack: NavPathStack = MINE_STACK;

  aboutToAppear(): void {
    // 诊断：横竖屏切换后重建 MainPage 时这条会出现，栈与页签仍应保留（见 common/NavStacks）
    Logger.info('MainPage aboutToAppear，currentIndex=' + this.currentIndex);
    // 冷启动路径：AppStorage 里已有值时，这里把它吃掉
    this.applyRoute(this.pendingRoute);
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
      this.featureStack.pushPath({ name: page });
    }
  }

  /**
   * 课表页顶部「学期 / 周次」选择器的共享状态（见 ScheduleHeader.ScheduleHeaderModel）。
   *
   * MainPage 持有它、并把它渲染进课表页的标题栏；SchedulePage 拿到**同一个实例**
   * 负责写数据和挂回调 —— 两边不是父子关系，靠这个 @Observed 实例当桥。
   */
  @State private scheduleHeader: ScheduleHeaderModel = new ScheduleHeaderModel();

  /** 四个页签共用同一张路由表，各自跳转互不干扰。 */
  /**
   * 当前生效的导航栈 —— 由 `routeMap` 在被调用时按**当前页签**决定。
   *
   * ## 为什么需要这个间接层
   *
   * `navDestination` 要的是 **@Builder**（组件装饰器），不能传普通函数 ——
   * 传了普通函数（第一版我写成 `routeMapOf(stack)` 返回闭包），
   * 路由表**根本挂不上**，所有二级页全黑（真机实测）。
   *
   * 而 `navDestination` 的回调签名只有 `(name, param)`，**拿不到栈**。
   * 于是用一个 `@State` 记住「当前是哪个页签」，在 `@Builder routeMap` 里
   * 按它取对应的栈：
   *
   * ```
   * MainPage.routeMap（@Builder）
   *   → 按 currentIndex 取 stackOf(index)
   *   → routeBuilder(name, param, stack)
   *   → DestShell({ stack })
   *   → 子页组件
   * ```
   */
  @Builder
  routeMap(name: string, param: object) {
    // `currentIndex` 由 HdsTabs 的 onChange 维护 —— 就是当前页签序号，
    // 用它取对应的栈（栈的内容与页签一一对应，见 stackOf）。
    routeBuilder(name, param, this.stackOf(this.currentIndex));
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
  /**
   * 通知功能页收起「展开的卡片」。
   *
   * 那是功能页内部的一个浮层（为了共享元素转场），**不在导航栈里** ——
   * `clearStack()` 清的是栈，碰不到它。点「功能」页签时必须单独发这个信号，
   * 否则用户会觉得「点了功能按钮回不到功能主页」。
   */
  private notifyCloseFeatureHero(): void {
    const current: number = AppStorage.get<number>(KEY_FEATURE_HERO_CLOSE) ?? 0;
    AppStorage.setOrCreate<number>(KEY_FEATURE_HERO_CLOSE, current + 1);
  }

  private clearStack(index: number): void {
    if (index === 2) {
      const stack: NavPathStack = this.stackOf(index);
      // 栈里可能停着一张「卡片展开页」。清栈前必须把原卡片放出来：
      // `clear(false)` 不播转场，也就没有 POP 回调去通知功能页 —— 卡片会一直保持隐藏
      // （实测：点「功能」回到网格后，考试安排那张卡是空的）。
      NavHero.notifyTileShow();
      if (NavHero.isTopHero() && stack.size() === 1) {
        // 只有一层时带动画清栈，正好走上「缩回卡片」的转场
        stack.clear(true);
      } else {
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
          NavHero.holdProxy(proxy);
        }
      };
      return push;
    }
    if (operation === NavigationOperation.POP) {
      if (!NavHero.isTopHero()) {
        return undefined;
      }
      // ⚠️ 这个回调是在**渲染管线里同步调用**的，此处直接改 AppStorage / @State 会抛
      // JS Error（实测：点返回直接崩进程，exit 254，栈顶就落在这一行）。
      // 所以状态改动统统延后一帧。
      this.expandDone = false;
      setTimeout(() => {
        // 遮罩开始收缩（MainPage 自己演），系统保留功能页快照作为露出内容
        HeroMorph.startShrink();
        // 真实卡片先放出来：此刻遮罩全屏不透明，看不到变化
        NavHero.notifyTileShow();
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
    this.currentIndex = index;
    // 切到课表页时通知它刷新当前周（页签内容是常驻的，onPageShow 不触发）
    if (index === 1) {
      this.scheduleHeader.onRefresh();
    }
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

  /** 站内网页提交：覆盖整个屏幕（含底部页签），先登录再跳作业详情。 */
  @Builder
  spocWebOverlay() {
    Column() {
      Row() {
        Text('网页提交')
          .fontSize(AppFont.title)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.textPrimary)
        Blank()
        Button('关闭')
          .height(32)
          .fontSize(AppFont.body)
          .fontColor(AppColor.brand)
          .backgroundColor(AppColor.brandContainer)
          .onClick(() => {
            AppStorage.setOrCreate('spocWebOpen', false);
          })
      }
      .width('100%')
      .height(56)
      .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
      .alignItems(VerticalAlign.Center)
      .backgroundColor(AppColor.pageBackground)

      Web({ src: this.spocWebLogin, controller: this.mainWebCtrl })
        .width('100%')
        .layoutWeight(1)
        .domStorageAccess(true)
        .javaScriptAccess(true)
        .mixedMode(MixedMode.All)
        .metaViewport(true)
        .zoomAccess(false)
        .onPageEnd(() => {
          if (!this.mainWebLoaded) {
            this.mainWebLoaded = true;
            if (this.spocWebDetail.length > 0) {
              this.mainWebCtrl.loadUrl(this.spocWebDetail);
            }
          }
        })
    }
    .width('100%')
    .height('100%')
    // 顶部让开「状态栏 + MINI 标题栏」，保留 SPOC 作业那一行；底部一直铺到屏幕底，盖住页签栏
    .padding({ top: topSafeInsetVp() + AppSize.navTitleBarMiniHeight })
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
        .navDestination(this.routeMap)
        .titleBar(this.titleBar())
        .titleMode(HdsNavigationTitleMode.MINI)
        .hideBackButton(true)
        .mode(NavigationMode.Stack)
      }
      .tabBar(new BottomTabBarStyle($r('app.media.ic_home'), $r('app.string.tab_home')))

      TabContent() {
        HdsNavigation(this.scheduleStack) {
          PageShell() {
            SchedulePage({ stack: this.scheduleStack, header: this.scheduleHeader })
          }
        }
        .navDestination(this.routeMap)
        .titleBar(this.scheduleTitleBar())
        .titleMode(HdsNavigationTitleMode.MINI)
        .hideBackButton(true)
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
        .navDestination(this.routeMap)
        .titleBar(this.titleBar())
        .titleMode(HdsNavigationTitleMode.MINI)
        .hideBackButton(true)
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
      // 首次回调是 HdsTabs 的初始化（必然是 0），不是用户点的 ——
      // 不要据此改 currentIndex，而是让新建的 Tabs 跟随保存的页签。
      if (!this.tabsReady) {
        this.tabsReady = true;
        if (index !== this.currentIndex) {
          // changeIndex 会再回调一次 onChange（此时 tabsReady 已 true），
          // 于是 currentIndex 被同步到正确值。
          this.controller.changeIndex(this.currentIndex);
        }
        return;
      }
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
        this.notifyCloseFeatureHero();
      }
      if (index === this.currentIndex) {
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
        .navDestination(this.routeMap)
        .titleBar(this.titleBar())
        .titleMode(HdsNavigationTitleMode.MINI)
        .hideBackButton(true)
        .mode(NavigationMode.Stack)
        .navBarPosition(NavBarPosition.Start)
        .layoutWeight(1)
      } else if (this.currentIndex === 1) {
        HdsNavigation(this.scheduleStack) {
          PageShell() {
            SchedulePage({ stack: this.scheduleStack, header: this.scheduleHeader })
          }
        }
        .navDestination(this.routeMap)
        .titleBar(this.scheduleTitleBar())
        .titleMode(HdsNavigationTitleMode.MINI)
        .hideBackButton(true)
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
        .navDestination(this.routeMap)
        .titleBar(this.titleBar())
        .titleMode(HdsNavigationTitleMode.MINI)
        .hideBackButton(true)
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
        .navDestination(this.routeMap)
        .titleBar(this.titleBar())
        .titleMode(HdsNavigationTitleMode.MINI)
        .hideBackButton(true)
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
        // 三层：页面底色 → 彩色层（与卡片同透明度）→ 图标文字（随块一起拉伸）
        Stack() {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(this.pageBg())

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

      if (this.spocWebOpen) {
        this.spocWebOverlay()
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
          this.notifyCloseFeatureHero();
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
