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
import { routeBuilder } from './RouteBuilder';
import { HomePage } from './home/HomePage';
import { SchedulePage } from './academic/SchedulePage';
import { FeaturePage } from './home/FeaturePage';
import { MinePage } from './mine/MinePage';
import {
  KEY_BREAKPOINT,
  KEY_NAV_SPLIT_MODE,
  navBarWidthOf,
  navBarMinWidthOf,
  navBarMaxWidthOf,
  minContentWidthOf,
  useSideNav
} from '../common/Breakpoint';
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
  @State private currentIndex: number = 0;
  /** 宽度断点（AppStorage 由 ImmersiveUtil 的 windowSizeChange 写入）。 */
  @StorageProp(KEY_BREAKPOINT) private bp: string = 'sm';
  @StorageProp(KEY_NAV_SPLIT_MODE) @Watch('onNavSplitModeChange') private navSplitMode: boolean = false;

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

  /* 站内网页提交浮层（覆盖底栏，全屏） */
  @StorageProp('spocWebOpen') @Watch('onSpocWebOpenChange') private spocWebOpen: boolean = false;
  @StorageProp('spocWebLogin') private spocWebLogin: string = '';
  @StorageProp('spocWebDetail') private spocWebDetail: string = '';
  private mainWebCtrl: webview.WebviewController = new webview.WebviewController();
  private mainWebLoaded: boolean = false;

  onSpocWebOpenChange(): void {
    if (this.spocWebOpen) {
      this.mainWebLoaded = false;
    }
  }
  private homeStack: NavPathStack = new NavPathStack();
  private scheduleStack: NavPathStack = new NavPathStack();
  private featureStack: NavPathStack = new NavPathStack();
  private mineStack: NavPathStack = new NavPathStack();

  /**
   * 四个页签的导航栈深度（0 = 停留在一级页）。
   *
   * 分栏模式由它驱动：>0 才切 Split，因此「没点进去」时是一整页，
   * 「点进去」才出现左列表 + 右详情，配合「先切分栏、下一帧 push」的顺序让详情从右侧滑入。
   * 由 `bindStackDepth()` 里的 `setInterception().didShow` 维护。
   */
  @State private stackDepth: number[] = [0, 0, 0, 0];

  /**
   * 四个页签的「即将分栏」标记。
   *
   * 点条目时先把它置真，让 `mode` 在这一帧就切到 Split（模式切换动画已关闭，瞬切），
   * **下一帧**才 push 详情 —— 这样详情是作为「分栏里的内容」进来的，播放的是 push 的
   * 默认右滑入动画。否则先 push 再切模式，看到的是 HDS 的模式切换动画：
   * 左侧列表收窄、内容区从**左**展开，和「点开一项、详情从右边推进来」的直觉相反。
   *
   * 栈深一旦 > 0 就会被清掉（`updateStackDepth`），不留残余。
   */
  @State private awaitSplit: boolean[] = [false, false, false, false];

  aboutToAppear(): void {
    // 冷启动路径：AppStorage 里已有值时，这里把它吃掉
    this.applyRoute(this.pendingRoute);
    // 订阅四个栈的进出，维护「当前页签是否已进入二级页」
    this.bindStackDepth();
  }

  /**
   * 让四个页签的导航栈在 push / pop 时把栈深写进状态。
   *
   * 分栏模式由**栈深**决定（见 `splitFor`）：没点进去时整页显示，点进去才切成
   * 「左列表 + 右详情」。`NavPathStack` 本身不是可观察对象，只能靠
   * `setInterception().didShow` 这个「页面已切换完成」回调来同步深度，
   * 返回键、手势返回、代码 pop 都会经过它。
   */
  private bindStackDepth(): void {
    const stacks: NavPathStack[] = [this.homeStack, this.scheduleStack, this.featureStack, this.mineStack];
    for (let i = 0; i < stacks.length; i++) {
      const index: number = i;
      // 只挂 didShow：push / pop / 手势返回都会经过它，能覆盖所有进出栈路径。
      stacks[i].setInterception({
        didShow: () => {
          this.updateStackDepth(index, stacks[index].size());
        }
      });
    }
  }

  /** 只在深度真的变化时整体替换数组 —— @State 才会通知重建（进而触发 mode 切换动画）。 */
  private updateStackDepth(index: number, depth: number): void {
    if (depth > 0 && this.awaitSplit[index]) {
      const cleared: boolean[] = this.awaitSplit.slice();
      cleared[index] = false;
      this.awaitSplit = cleared;
    }
    if (this.stackDepth[index] === depth) {
      return;
    }
    const next: number[] = this.stackDepth.slice();
    next[index] = depth;
    this.stackDepth = next;
    Logger.info('LAYOUT 页签' + index + ' 栈深=' + depth);
  }

  /** 该页签是否参与分栏（课表不参与：周网格劈一半没法看）。 */
  private isSplitTab(tabIndex: number): boolean {
    return tabIndex === 0 || tabIndex === 2 || tabIndex === 3;
  }

  /**
   * 一级页点条目时的回调：若当前能分栏且还没分，先切到 Split 再返回 true，
   * 由调用方在下一帧 push —— 详情才会以「从右侧滑入」的方式出现。
   * 不能分栏（手机 / 课表）时返回 false，调用方直接 push，零延迟。
   */
  private beginSplit(tabIndex: number): boolean {
    if (!this.navSplitMode || !this.isSplitTab(tabIndex)) {
      return false;
    }
    if (this.stackDepth[tabIndex] > 0 || this.awaitSplit[tabIndex]) {
      return true;
    }
    const next: boolean[] = this.awaitSplit.slice();
    next[tabIndex] = true;
    this.awaitSplit = next;
    return true;
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
    this.stackOf(index).clear();
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
  private onWideSelect(index: number): void {
    if (index === this.currentIndex) {
      // 「再点当前项回主页」：清栈后自动退回单栏（栈深归零）
      this.stackOf(index).clear();
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
   * 该页签当前是否分栏。
   *
   * 两个条件：① 窗口具备分栏能力（md / lg / xxl）；② 该页签已经点进二级页（栈深 > 0）。
   * 所以「没点进去」时是一整页，「点进去」才变成左右双列 —— 过渡由
   * 详情自身的 push 动画（自右向左滑入）负责。
   *
   * 课表（页签 1）不参与：7 天周网格是固定列宽的表格，劈成一半没法看。
   */
  private splitFor(tabIndex: number): boolean {
    if (!this.navSplitMode || !this.isSplitTab(tabIndex)) {
      return false;
    }
    return this.stackDepth[tabIndex] > 0 || this.awaitSplit[tabIndex];
  }

  /**
   * 断点退回窄屏（md/sm）时清理导航栈：
   * 分栏消失后，栈里若只剩「二级页」会让用户离开时停在详情页而不是一级页，
   * 这里不做额外处理 —— 单栏下停在详情页正是用户点进去的位置，符合预期。
   */
  private onNavSplitModeChange(): void {
    // 状态由 stackDepth 驱动，断点切换本身不需要改栈；保留回调以便将来埋点。
    Logger.info('LAYOUT 分栏能力=' + this.navSplitMode);
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
              splitMode: this.splitFor(0),
              onWillOpen: () => this.beginSplit(0)
            })
          }
        }
        .navDestination(this.routeMap)
        .titleBar(this.titleBar())
        .titleMode(HdsNavigationTitleMode.MINI)
        .hideBackButton(true)
        .mode(this.splitFor(0) ? NavigationMode.Split : NavigationMode.Stack)
        .navBarWidth(navBarWidthOf(this.bp))
        .navBarWidthRange({
          minWidth: navBarMinWidthOf(this.bp),
          maxWidth: navBarMaxWidthOf(this.bp)
        })
        .minContentWidth(minContentWidthOf(this.bp))
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
        .mode(this.splitFor(1) ? NavigationMode.Split : NavigationMode.Stack)
        .navBarWidth(navBarWidthOf(this.bp))
        .navBarWidthRange({
          minWidth: navBarMinWidthOf(this.bp),
          maxWidth: navBarMaxWidthOf(this.bp)
        })
        .minContentWidth(minContentWidthOf(this.bp))
      }
      .tabBar(new BottomTabBarStyle($r('app.media.ic_schedule'), $r('app.string.tab_schedule')))

      TabContent() {
        HdsNavigation(this.featureStack) {
          PageShell() {
            FeaturePage({
              stack: this.featureStack,
              splitMode: this.splitFor(2),
              onWillOpen: () => this.beginSplit(2)
            })
          }
        }
        .navDestination(this.routeMap)
        .titleBar(this.titleBar())
        .titleMode(HdsNavigationTitleMode.MINI)
        .hideBackButton(true)
        .mode(this.splitFor(2) ? NavigationMode.Split : NavigationMode.Stack)
        .navBarWidth(navBarWidthOf(this.bp))
        .navBarWidthRange({
          minWidth: navBarMinWidthOf(this.bp),
          maxWidth: navBarMaxWidthOf(this.bp)
        })
        .minContentWidth(minContentWidthOf(this.bp))
      }
      .tabBar(new BottomTabBarStyle($r('app.media.ic_apps'), $r('app.string.tab_feature')))

      TabContent() {
        HdsNavigation(this.mineStack) {
          PageShell() {
            MinePage({
              stack: this.mineStack,
              splitMode: this.splitFor(3),
              onWillOpen: () => this.beginSplit(3),
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
        .mode(this.splitFor(3) ? NavigationMode.Split : NavigationMode.Stack)
        .navBarWidth(navBarWidthOf(this.bp))
        .navBarWidthRange({
          minWidth: navBarMinWidthOf(this.bp),
          maxWidth: navBarMaxWidthOf(this.bp)
        })
        .minContentWidth(minContentWidthOf(this.bp))
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
    .onChange((index: number) => {
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
      if (index === this.currentIndex) {
        this.stackOf(index).clear();
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
              splitMode: this.splitFor(0),
              onWillOpen: () => this.beginSplit(0)
            })
          }
        }
        .navDestination(this.routeMap)
        .titleBar(this.titleBar())
        .titleMode(HdsNavigationTitleMode.MINI)
        .hideBackButton(true)
        .mode(this.splitFor(0) ? NavigationMode.Split : NavigationMode.Stack)
        .navBarWidth(navBarWidthOf(this.bp))
        .navBarWidthRange({
          minWidth: navBarMinWidthOf(this.bp),
          maxWidth: navBarMaxWidthOf(this.bp)
        })
        .minContentWidth(minContentWidthOf(this.bp))
        .navBarPosition(NavBarPosition.Start)
        // 保留 HDS 的模式切换动画（与底部页签分支一致）：两端表现必须一样，
        // 否则横屏是瞬切、竖屏有动画（实测就是这个差异）。
        .enableModeChangeAnimation(true)
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
        .mode(this.splitFor(1) ? NavigationMode.Split : NavigationMode.Stack)
        .navBarWidth(navBarWidthOf(this.bp))
        .navBarWidthRange({
          minWidth: navBarMinWidthOf(this.bp),
          maxWidth: navBarMaxWidthOf(this.bp)
        })
        .minContentWidth(minContentWidthOf(this.bp))
        .navBarPosition(NavBarPosition.Start)
        // 保留 HDS 的模式切换动画（与底部页签分支一致）：两端表现必须一样，
        // 否则横屏是瞬切、竖屏有动画（实测就是这个差异）。
        .enableModeChangeAnimation(true)
        .layoutWeight(1)
      } else if (this.currentIndex === 2) {
        HdsNavigation(this.featureStack) {
          PageShell() {
            FeaturePage({
              stack: this.featureStack,
              splitMode: this.splitFor(2),
              onWillOpen: () => this.beginSplit(2)
            })
          }
        }
        .navDestination(this.routeMap)
        .titleBar(this.titleBar())
        .titleMode(HdsNavigationTitleMode.MINI)
        .hideBackButton(true)
        .mode(this.splitFor(2) ? NavigationMode.Split : NavigationMode.Stack)
        .navBarWidth(navBarWidthOf(this.bp))
        .navBarWidthRange({
          minWidth: navBarMinWidthOf(this.bp),
          maxWidth: navBarMaxWidthOf(this.bp)
        })
        .minContentWidth(minContentWidthOf(this.bp))
        .navBarPosition(NavBarPosition.Start)
        // 保留 HDS 的模式切换动画（与底部页签分支一致）：两端表现必须一样，
        // 否则横屏是瞬切、竖屏有动画（实测就是这个差异）。
        .enableModeChangeAnimation(true)
        .layoutWeight(1)
      } else {
        HdsNavigation(this.mineStack) {
          PageShell() {
            MinePage({
              stack: this.mineStack,
              splitMode: this.splitFor(3),
              onWillOpen: () => this.beginSplit(3),
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
        .mode(this.splitFor(3) ? NavigationMode.Split : NavigationMode.Stack)
        .navBarWidth(navBarWidthOf(this.bp))
        .navBarWidthRange({
          minWidth: navBarMinWidthOf(this.bp),
          maxWidth: navBarMaxWidthOf(this.bp)
        })
        .minContentWidth(minContentWidthOf(this.bp))
        .navBarPosition(NavBarPosition.Start)
        // 保留 HDS 的模式切换动画（与底部页签分支一致）：两端表现必须一样，
        // 否则横屏是瞬切、竖屏有动画（实测就是这个差异）。
        .enableModeChangeAnimation(true)
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Stack() {
      if (this.sideNavLayout()) {
        this.wideLayout()
      } else {
        this.narrowTabs()
      }

      if (this.spocWebOpen) {
        this.spocWebOverlay()
      }
    }
    .width('100%')
    .height('100%')
  }
}
