import {
  HdsNavDestination,
  HdsNavigationTitleBarOptions,
  ScrollEffectType,
  hdsMaterial
} from '@kit.UIDesignKit';
import { AppRouter, RouteName } from '../common/AppRouter';
import { systemBarStyleFor, currentIsDark } from '../common/ImmersiveUtil';
import { NativeHeroDest } from '../components/NativeHeroDest';
import { AppColor } from '../components/AppTheme';
import { FeatureHero } from '../common/FeatureHero';
import { KEY_HERO_PAGE_OPACITY } from '../common/HeroMorph';
import curves from '@ohos.curves';
import { Logger } from '../common/Logger';
import { GradeHeaderModel, GradeTermTitle } from '../components/GradeHeader';
import { ExamPage } from './academic/ExamPage';
import { GradePage } from './academic/GradePage';
import { ClassroomPage } from './academic/ClassroomPage';
import { SigninPage } from './activity/SigninPage';
import { EvaluationPage } from './evaluation/EvaluationPage';
import { JudgePage } from './evaluation/JudgePage';
import { JudgeDetailPage } from './evaluation/JudgeDetailPage';
import { IhomePage } from './ihome/IhomePage';
import { IhomeDetailPage } from './ihome/IhomeDetailPage';
import { SpocPage } from './spoc/SpocPage';
import { FinancePage } from './finance/FinancePage';
import { NetworkPage } from './campus/NetworkPage';
import { CloudPrintPage } from './campus/CloudPrintPage';
import { YgdkPage } from './activity/YgdkPage';
import { BykcPage } from './bykc/BykcPage';
import { BykcCoursesPage } from './bykc/BykcCoursesPage';
import { BykcChosenPage } from './bykc/BykcChosenPage';
import { BykcStatisticsPage } from './bykc/BykcStatisticsPage';
import { BykcDetailPage } from './bykc/BykcDetailPage';
import { LibBookHomePage } from './library/LibBookHomePage';
import { LibBookReservePage } from './library/LibBookReservePage';
import { LibBookBookingsPage } from './library/LibBookBookingsPage';
import { UserInfoPage } from './mine/UserInfoPage';
import { SettingsPage } from './mine/SettingsPage';
import { AboutPage } from './mine/AboutPage';
import { PrivacyPage } from './mine/PrivacyPage';
import { LicensePage } from './mine/LicensePage';
import { WidePlaceholder } from '../components/WidePlaceholder';
import { WIDE_PLACEHOLDER_ROUTE } from '../common/AppRouter';

/**
 * 成绩页的 NavDestination 外壳（**必须**做成组件）。
 *
 * ## 为什么不能像其它二级页那样在 routeBuilder 里直接写
 *
 * 成绩页的标题栏要放「学期名 + ← →」，而 HDS 的 `content.stackBuilder` 是由
 * 原生侧（hdsBaseComponent.js）回调执行的。回调里的 @Builder 依赖
 * `this.observeComponentCreation2`：
 *
 * - 在**普通函数**里写箭头函数 → `this` 是 undefined → 闪退；
 * - 在 routeBuilder（全局 @Builder）里包一层全局 @Builder → 同样没有组件实例 →
 *   `Cannot read property observeComponentCreation2 of undefined`。
 *
 * 真机实测两种写法都会在点「成绩查询」时必现。把整个 destination 收进一个
 * @Component，让箭头函数捕获组件实例（与 MainPage.scheduleTitleBar 同一套写法），
 * 标题栏里的 @Builder 才能正常创建组件。
 */
@Component
struct GradeDestination {
  stack: NavPathStack = new NavPathStack();

  /** 标题栏与页面共用同一个 @Observed 实例（换学期时两边一起刷新）。 */
  @State private header: GradeHeaderModel = new GradeHeaderModel();

  @Builder
  termTitle() {
    GradeTermTitle({ model: this.header });
  }

  private titleBarOptions(): HdsNavigationTitleBarOptions {
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
          scrollEffectType: ScrollEffectType.GRADIENT_BLUR
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      },
      content: {
        // 箭头函数捕获本组件实例，HDS 原生回调时 @Builder 仍在实例上执行
        stackBuilder: (): void => {
          this.termTitle();
        }
      }
    };
  }

  build() {
    HdsNavDestination() {
      DestShell({ stack: this.stack }) {
        GradePage({ header: this.header })
      }
    }
    .titleBar(this.titleBarOptions())
    // 同上：状态栏内容色显式托管给 HDS（否则下拉滚动时被默认白覆盖）
    .systemBarStyle(systemBarStyleFor(currentIsDark()), systemBarStyleFor(currentIsDark()))
    // 显式接管返回：分栏下 HDS 自己画的返回按钮不一定能弹栈（实测无效），
    // 由目的地主动 pop 才可靠；返回 true 表示事件已消费、不再冒泡到系统。
    .onBackPressed(() => {
      AppRouter.back(this.stack);
      return true;
    })
    // 背景交给页面自己的根容器（每个二级页都铺了 pageBackground）——
    // 目的地容器保持透明，「卡片放大 / 缩回」时下层功能页网格才透得出来。
    .backgroundColor(Color.Transparent)
  }
}

/**
 * 全局路由表（供四个页签的 HdsNavigation 共用）。
 *
 * 二级页面用 **HdsNavDestination**（而不是原生 NavDestination），原因有三：
 *   1. 底板半透明：二级页面的标题栏也能拿到与主页同款的「沉浸光感」材质，
 *      滚动时内容从毛玻璃下透出，而不是一条死黑/死白的实心条；
 *   2. 顶部避让：HdsNavDestination 的标题栏自行避让状态栏，不必再手写 padding
 *      （原生 NavDestination 会直接把标题压在状态栏时钟上）；
 *   3. 返回按钮沿用 HDS 规范样式，与系统应用一致。
 */
function destTitleBar(title: string): HdsNavigationTitleBarOptions {
  return {
    avoidLayoutSafeArea: true,
    // 组件级安全区：标题栏的材质底板连状态栏一起覆盖，标题文字仍从状态栏下沿开始。
    // 这是「顶部模糊没有横向接缝」的关键 —— 不再需要外壳另外叠一层 backdropBlur
    // 去兜状态栏那一条（那层与标题栏材质强度不一致，接缝正是它造成的）。
    enableComponentSafeArea: true,
    style: {
      // 初始底色显式透明：避免首帧先铺一层实心底色再换挡成材质。
      originalStyle: {
        backgroundStyle: {
          backgroundColor: Color.Transparent
        }
      },
      scrollEffectOpts: {
        enableScrollEffect: true,
        scrollEffectType: ScrollEffectType.GRADIENT_BLUR
      },
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.ADAPTIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      }
    },
    content: {
      title: {
        mainTitle: title
      }
    }
  };
}

/**
 * 二级页面内容外壳。
 *
 * 2026-09-20 起只是一层「撑满 + 承载 @BuilderParam」的容器，**不再自己补模糊层**。
 * 顶部模糊全部交给 HDS：destTitleBar 里置了 `enableComponentSafeArea: true`，
 * 标题栏被声明成组件级安全区，材质底板一直铺到屏幕顶端（状态栏区域也盖上）。
 *
 * 此前是叠一层 `Column().height(topSafeInsetVp()).backdropBlur(20)` 去盖状态栏，
 * 那一条的模糊强度与标题栏自带材质对不上，交界处有一条明显横向断层（状态栏那段更
 * 「糊」、下面那段更「透」）。现在唯一模糊源是标题栏自己的材质，接缝消失。
 *
 * 外壳本身**不加内边距**：加在外壳上的 padding 会被当成 contentInset 把整块内容
 * 连同滚动视口一起压低，内容就再也滑不进底板。顶部留白由页面自己的滚动内容承担
 * （见各二级页 `.padding({ top: AppSize.destTopInset(topSafeInsetVp()) })`）；
 * 底部同理，留给滚动内容（AppSize.contentBottomInset），否则悬浮底栏背后永远是
 * 一块实心底板，毛玻璃透不出内容。
 *
 * 另外：HdsNavDestination 自身的 padding 作用在整个组件上，会把沉浸式标题栏
 * 一起推下去（实测标题栏从 63vp 掉到 163vp，正好压在第一张卡片上），所以顶部
 * 避让也不能拿它来做。
 */
@Component
struct DestShell {
  @Builder
  empty() {
  }

  @BuilderParam content: () => void = this.empty;
  /**
   * 当前页签的导航栈。
   *
   * 二级页里有的还要**再跳一级**（博雅课程列表 → 课程详情），
   * 而 `navDestination` 的回调拿不到栈 —— 所以从 `MainPage` 一路传下来。
   */
  stack: NavPathStack = new NavPathStack();

  /**
   * 页面整体透明度。
   *
   * 由 `MainPage` 的转场编排推：入场 0→1（与彩色块交叉淡入），退场 1→0。
   * 只作用在内容上 —— 标题栏是 `HdsNavDestination` 自绘的、在外壳之外，
   * 但它位于转场色块的**下层**，色块铺满时本来就看不见，不必单独控制。
   */
  @StorageProp(KEY_HERO_PAGE_OPACITY) private pageOpacity: number = 1;

  /** 在「二级页外壳」栈里的 id（转场要判断谁是栈顶）。 */
  private shellId: number = -1;

  aboutToAppear(): void {
    this.shellId = FeatureHero.enterShell();
  }

  aboutToDisappear(): void {
    FeatureHero.leaveShell(this.shellId);
  }

  build() {
    Column() {
      this.content()
    }
    .width('100%')
    .height('100%')
    .opacity(this.pageOpacity)
  }
}

@Builder
export function routeBuilder(name: string, param: object, stack: NavPathStack) {
  if (name === RouteName.EXAM) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        ExamPage()
      }
    }
    .titleBar(destTitleBar('考试安排'))
    // HDS 不设 systemBarStyle 时按 SystemBarStyle 默认值 #E5FFFFFF（白）托管状态栏，
    // 页面一下拉/滚动就会被刷回白。官方不建议与 window 接口混用 → 显式托管。
    .systemBarStyle(systemBarStyleFor(currentIsDark()), systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    // 背景交给页面自己的根容器（每个二级页都铺了 pageBackground）——
    // 目的地容器保持透明，「卡片放大 / 缩回」时下层功能页网格才透得出来。
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.GRADE) {
    GradeDestination({ stack: stack })
  } else if (name === RouteName.CLASSROOM) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        ClassroomPage()
      }
    }
    .titleBar(destTitleBar('空闲教室'))
    // HDS 不设 systemBarStyle 时按 SystemBarStyle 默认值 #E5FFFFFF（白）托管状态栏，
    // 页面一下拉/滚动就会被刷回白。官方不建议与 window 接口混用 → 显式托管。
    .systemBarStyle(systemBarStyleFor(currentIsDark()), systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    // 背景交给页面自己的根容器（每个二级页都铺了 pageBackground）——
    // 目的地容器保持透明，「卡片放大 / 缩回」时下层功能页网格才透得出来。
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.IHOME) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        IhomePage({ stack: stack })
      }
    }
    .titleBar(destTitleBar('iHome'))
    // HDS 不设 systemBarStyle 时按 SystemBarStyle 默认值 #E5FFFFFF（白）托管状态栏，
    // 页面一下拉/滚动就会被刷回白。官方不建议与 window 接口混用 → 显式托管。
    .systemBarStyle(systemBarStyleFor(currentIsDark()), systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    // 背景交给页面自己的根容器（每个二级页都铺了 pageBackground）——
    // 目的地容器保持透明，「卡片放大 / 缩回」时下层功能页网格才透得出来。
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.IHOME_DETAIL) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        IhomeDetailPage()
      }
    }
    .titleBar(destTitleBar('诉求详情'))
    // HDS 不设 systemBarStyle 时按 SystemBarStyle 默认值 #E5FFFFFF（白）托管状态栏，
    // 页面一下拉/滚动就会被刷回白。官方不建议与 window 接口混用 → 显式托管。
    .systemBarStyle(systemBarStyleFor(currentIsDark()), systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    // 背景交给页面自己的根容器（每个二级页都铺了 pageBackground）——
    // 目的地容器保持透明，「卡片放大 / 缩回」时下层功能页网格才透得出来。
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.JUDGE) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        JudgePage({ stack: stack })
      }
    }
    .titleBar(destTitleBar('希冀作业'))
    // HDS 不设 systemBarStyle 时按 SystemBarStyle 默认值 #E5FFFFFF（白）托管状态栏，
    // 页面一下拉/滚动就会被刷回白。官方不建议与 window 接口混用 → 显式托管。
    .systemBarStyle(systemBarStyleFor(currentIsDark()), systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    // 背景交给页面自己的根容器（每个二级页都铺了 pageBackground）——
    // 目的地容器保持透明，「卡片放大 / 缩回」时下层功能页网格才透得出来。
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.JUDGE_DETAIL) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        JudgeDetailPage()
      }
    }
    .titleBar(destTitleBar('作业详情'))
    // HDS 不设 systemBarStyle 时按 SystemBarStyle 默认值 #E5FFFFFF（白）托管状态栏，
    // 页面一下拉/滚动就会被刷回白。官方不建议与 window 接口混用 → 显式托管。
    .systemBarStyle(systemBarStyleFor(currentIsDark()), systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    // 背景交给页面自己的根容器（每个二级页都铺了 pageBackground）——
    // 目的地容器保持透明，「卡片放大 / 缩回」时下层功能页网格才透得出来。
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.EVALUATION) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        EvaluationPage()
      }
    }
    .titleBar(destTitleBar('自动评教'))
    // HDS 不设 systemBarStyle 时按 SystemBarStyle 默认值 #E5FFFFFF（白）托管状态栏，
    // 页面一下拉/滚动就会被刷回白。官方不建议与 window 接口混用 → 显式托管。
    .systemBarStyle(systemBarStyleFor(currentIsDark()), systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    // 背景交给页面自己的根容器（每个二级页都铺了 pageBackground）——
    // 目的地容器保持透明，「卡片放大 / 缩回」时下层功能页网格才透得出来。
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.SIGNIN) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        SigninPage()
      }
    }
    .titleBar(destTitleBar('课堂签到'))
    // HDS 不设 systemBarStyle 时按 SystemBarStyle 默认值 #E5FFFFFF（白）托管状态栏，
    // 页面一下拉/滚动就会被刷回白。官方不建议与 window 接口混用 → 显式托管。
    .systemBarStyle(systemBarStyleFor(currentIsDark()), systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    // 背景交给页面自己的根容器（每个二级页都铺了 pageBackground）——
    // 目的地容器保持透明，「卡片放大 / 缩回」时下层功能页网格才透得出来。
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.SPOC) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        SpocPage()
      }
    }
    .titleBar(destTitleBar('SPOC 作业'))
    // HDS 不设 systemBarStyle 时按 SystemBarStyle 默认值 #E5FFFFFF（白）托管状态栏，
    // 页面一下拉/滚动就会被刷回白。官方不建议与 window 接口混用 → 显式托管。
    .systemBarStyle(systemBarStyleFor(currentIsDark()), systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    // 背景交给页面自己的根容器（每个二级页都铺了 pageBackground）——
    // 目的地容器保持透明，「卡片放大 / 缩回」时下层功能页网格才透得出来。
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.FINANCE) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        FinancePage()
      }
    }
    .titleBar(destTitleBar('财务收入'))
    .systemBarStyle(systemBarStyleFor(currentIsDark()), systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.CLOUD_PRINT) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        CloudPrintPage()
      }
    }
    .titleBar(destTitleBar('云打印'))
    .systemBarStyle(systemBarStyleFor(currentIsDark()), systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.NETWORK) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        NetworkPage()
      }
    }
    .titleBar(destTitleBar('网费流量'))
    .systemBarStyle(systemBarStyleFor(currentIsDark()), systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.YGDK) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        YgdkPage()
      }
    }
    .titleBar(destTitleBar('阳光打卡'))
    // HDS 不设 systemBarStyle 时按 SystemBarStyle 默认值 #E5FFFFFF（白）托管状态栏，
    // 页面一下拉/滚动就会被刷回白。官方不建议与 window 接口混用 → 显式托管。
    .systemBarStyle(systemBarStyleFor(currentIsDark()), systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    // 背景交给页面自己的根容器（每个二级页都铺了 pageBackground）——
    // 目的地容器保持透明，「卡片放大 / 缩回」时下层功能页网格才透得出来。
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.BYKC) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        BykcPage({ stack: stack })
      }
    }
    .titleBar(destTitleBar('博雅课程'))
    // HDS 不设 systemBarStyle 时按 SystemBarStyle 默认值 #E5FFFFFF（白）托管状态栏，
    // 页面一下拉/滚动就会被刷回白。官方不建议与 window 接口混用 → 显式托管。
    .systemBarStyle(systemBarStyleFor(currentIsDark()), systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    // 背景交给页面自己的根容器（每个二级页都铺了 pageBackground）——
    // 目的地容器保持透明，「卡片放大 / 缩回」时下层功能页网格才透得出来。
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.BYKC_COURSES) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        BykcCoursesPage({ stack: stack })
      }
    }
    .titleBar(destTitleBar('选择课程'))
    // HDS 不设 systemBarStyle 时按 SystemBarStyle 默认值 #E5FFFFFF（白）托管状态栏，
    // 页面一下拉/滚动就会被刷回白。官方不建议与 window 接口混用 → 显式托管。
    .systemBarStyle(systemBarStyleFor(currentIsDark()), systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    // 背景交给页面自己的根容器（每个二级页都铺了 pageBackground）——
    // 目的地容器保持透明，「卡片放大 / 缩回」时下层功能页网格才透得出来。
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.BYKC_CHOSEN) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        BykcChosenPage()
      }
    }
    .titleBar(destTitleBar('我的课程'))
    // HDS 不设 systemBarStyle 时按 SystemBarStyle 默认值 #E5FFFFFF（白）托管状态栏，
    // 页面一下拉/滚动就会被刷回白。官方不建议与 window 接口混用 → 显式托管。
    .systemBarStyle(systemBarStyleFor(currentIsDark()), systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    // 背景交给页面自己的根容器（每个二级页都铺了 pageBackground）——
    // 目的地容器保持透明，「卡片放大 / 缩回」时下层功能页网格才透得出来。
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.BYKC_STATISTICS) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        BykcStatisticsPage()
      }
    }
    .titleBar(destTitleBar('课程统计'))
    // HDS 不设 systemBarStyle 时按 SystemBarStyle 默认值 #E5FFFFFF（白）托管状态栏，
    // 页面一下拉/滚动就会被刷回白。官方不建议与 window 接口混用 → 显式托管。
    .systemBarStyle(systemBarStyleFor(currentIsDark()), systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    // 背景交给页面自己的根容器（每个二级页都铺了 pageBackground）——
    // 目的地容器保持透明，「卡片放大 / 缩回」时下层功能页网格才透得出来。
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.BYKC_DETAIL) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        BykcDetailPage({ stack: stack })
      }
    }
    .titleBar(destTitleBar('课程详情'))
    // HDS 不设 systemBarStyle 时按 SystemBarStyle 默认值 #E5FFFFFF（白）托管状态栏，
    // 页面一下拉/滚动就会被刷回白。官方不建议与 window 接口混用 → 显式托管。
    .systemBarStyle(systemBarStyleFor(currentIsDark()), systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    // 背景交给页面自己的根容器（每个二级页都铺了 pageBackground）——
    // 目的地容器保持透明，「卡片放大 / 缩回」时下层功能页网格才透得出来。
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.LIBBOOK_HOME) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        LibBookHomePage({ stack: stack })
      }
    }
    .titleBar(destTitleBar('图书馆座位'))
    // HDS 不设 systemBarStyle 时按 SystemBarStyle 默认值 #E5FFFFFF（白）托管状态栏，
    // 页面一下拉/滚动就会被刷回白。官方不建议与 window 接口混用 → 显式托管。
    .systemBarStyle(systemBarStyleFor(currentIsDark()), systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    // 背景交给页面自己的根容器（每个二级页都铺了 pageBackground）——
    // 目的地容器保持透明，「卡片放大 / 缩回」时下层功能页网格才透得出来。
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.LIBBOOK_RESERVE) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        LibBookReservePage()
      }
    }
    .titleBar(destTitleBar('预约座位'))
    // HDS 不设 systemBarStyle 时按 SystemBarStyle 默认值 #E5FFFFFF（白）托管状态栏，
    // 页面一下拉/滚动就会被刷回白。官方不建议与 window 接口混用 → 显式托管。
    .systemBarStyle(systemBarStyleFor(currentIsDark()), systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    // 背景交给页面自己的根容器（每个二级页都铺了 pageBackground）——
    // 目的地容器保持透明，「卡片放大 / 缩回」时下层功能页网格才透得出来。
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.LIBBOOK_BOOKINGS) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        LibBookBookingsPage()
      }
    }
    .titleBar(destTitleBar('我的座位预约'))
    // HDS 不设 systemBarStyle 时按 SystemBarStyle 默认值 #E5FFFFFF（白）托管状态栏，
    // 页面一下拉/滚动就会被刷回白。官方不建议与 window 接口混用 → 显式托管。
    .systemBarStyle(systemBarStyleFor(currentIsDark()), systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    // 背景交给页面自己的根容器（每个二级页都铺了 pageBackground）——
    // 目的地容器保持透明，「卡片放大 / 缩回」时下层功能页网格才透得出来。
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.USER_INFO) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        UserInfoPage()
      }
    }
    .titleBar(destTitleBar('个人资料'))
    // HDS 不设 systemBarStyle 时按 SystemBarStyle 默认值 #E5FFFFFF（白）托管状态栏，
    // 页面一下拉/滚动就会被刷回白。官方不建议与 window 接口混用 → 显式托管。
    .systemBarStyle(systemBarStyleFor(currentIsDark()), systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    // 背景交给页面自己的根容器（每个二级页都铺了 pageBackground）——
    // 目的地容器保持透明，「卡片放大 / 缩回」时下层功能页网格才透得出来。
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.SETTINGS) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        SettingsPage()
      }
    }
    .titleBar(destTitleBar('设置'))
    // HDS 不设 systemBarStyle 时按 SystemBarStyle 默认值 #E5FFFFFF（白）托管状态栏，
    // 页面一下拉/滚动就会被刷回白。官方不建议与 window 接口混用 → 显式托管。
    .systemBarStyle(systemBarStyleFor(currentIsDark()), systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    // 背景交给页面自己的根容器（每个二级页都铺了 pageBackground）——
    // 目的地容器保持透明，「卡片放大 / 缩回」时下层功能页网格才透得出来。
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.ABOUT) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        AboutPage({ stack: stack })
      }
    }
    .titleBar(destTitleBar('关于'))
    // HDS 不设 systemBarStyle 时按 SystemBarStyle 默认值 #E5FFFFFF（白）托管状态栏，
    // 页面一下拉/滚动就会被刷回白。官方不建议与 window 接口混用 → 显式托管。
    .systemBarStyle(systemBarStyleFor(currentIsDark()), systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    // 背景交给页面自己的根容器（每个二级页都铺了 pageBackground）——
    // 目的地容器保持透明，「卡片放大 / 缩回」时下层功能页网格才透得出来。
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.PRIVACY) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        PrivacyPage()
      }
    }
    .titleBar(destTitleBar('隐私政策'))
    // HDS 不设 systemBarStyle 时按 SystemBarStyle 默认值 #E5FFFFFF（白）托管状态栏，
    // 页面一下拉/滚动就会被刷回白。官方不建议与 window 接口混用 → 显式托管。
    .systemBarStyle(systemBarStyleFor(currentIsDark()), systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    // 背景交给页面自己的根容器（每个二级页都铺了 pageBackground）——
    // 目的地容器保持透明，「卡片放大 / 缩回」时下层功能页网格才透得出来。
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.LICENSE) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        LicensePage()
      }
    }
    .titleBar(destTitleBar('开源许可'))
    // HDS 不设 systemBarStyle 时按 SystemBarStyle 默认值 #E5FFFFFF（白）托管状态栏，
    // 页面一下拉/滚动就会被刷回白。官方不建议与 window 接口混用 → 显式托管。
    .systemBarStyle(systemBarStyleFor(currentIsDark()), systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    // 背景交给页面自己的根容器（每个二级页都铺了 pageBackground）——
    // 目的地容器保持透明，「卡片放大 / 缩回」时下层功能页网格才透得出来。
    .backgroundColor(Color.Transparent)
  } else if (name === WIDE_PLACEHOLDER_ROUTE) {
    // Split 右栏栈空时的占位页；非分栏形态从不 push 这个名字。
    // hideBackButton：占位页不是真实页面，给它一个「返回」按钮没有语义，
    // 而且在分栏下会浮在右栏左上角，看着像误入了一个死页面。
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        WidePlaceholder()
      }
    }
    .titleBar(destTitleBar(''))
    // HDS 不设 systemBarStyle 时按 SystemBarStyle 默认值 #E5FFFFFF（白）托管状态栏，
    // 页面一下拉/滚动就会被刷回白。官方不建议与 window 接口混用 → 显式托管。
    .systemBarStyle(systemBarStyleFor(currentIsDark()), systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    .hideBackButton(true)
    // 背景交给页面自己的根容器（每个二级页都铺了 pageBackground）——
    // 目的地容器保持透明，「卡片放大 / 缩回」时下层功能页网格才透得出来。
    .backgroundColor(Color.Transparent)
  } else {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        Column() {
          Text('页面不存在：' + name)
            .fontSize(16)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      }
    }
    .titleBar(destTitleBar('出错了'))
    // HDS 不设 systemBarStyle 时按 SystemBarStyle 默认值 #E5FFFFFF（白）托管状态栏，
    // 页面一下拉/滚动就会被刷回白。官方不建议与 window 接口混用 → 显式托管。
    .systemBarStyle(systemBarStyleFor(currentIsDark()), systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    // 背景交给页面自己的根容器（每个二级页都铺了 pageBackground）——
    // 目的地容器保持透明，「卡片放大 / 缩回」时下层功能页网格才透得出来。
    .backgroundColor(Color.Transparent)
  }
}

/**
 * 原生 `Navigation` 用的路由 builder（功能页签专用）。
 *
 * ## 为什么单独一套
 *
 * 功能页签要的是「完全可控的共享元素转场」，而 HDS 把转场控制权收走了：
 * `HdsNavigation.customNavContentTransition` 不回调、跨 `HdsNavDestination` 的
 * `geometryTransition` 不生效。原生 `Navigation` 两者都支持。
 *
 * ## 外壳
 *
 * 用 `NativeHeroDest`（内部包 `HeroDetailLayer` 的自绘标题栏）：
 * 它自己算「从卡片矩形放大到全屏」的几何，动画播完才通知系统转场结束。
 *
 * ## 当前阶段
 *
 * 只接 `EXAM`。`customNavContentTransition` 已验证会回调（PUSH op=1 / POP op=2，
 * 前提是 push/pop 必须 `animated = true`）。其余路由先给占位页，
 * 逐个补全时只需换内容组件与标题（注意还有博雅/iHome/图书馆/评教的二级页）。
 */
/**
 * 原生 `Navigation` 用的路由表（功能页签专用）。
 *
 * ## 为什么功能页签单独一套
 *
 * 它要「完全可控的卡片展开转场」，而 HDS 把转场控制权收走了：
 * `HdsNavigation.customNavContentTransition` 不回调、跨 `HdsNavDestination` 的
 * `geometryTransition` 不生效。原生 `Navigation` 两者都支持
 * （实测回调正常：PUSH op=1 / POP op=2，前提是 push/pop 必须 `animated = true`）。
 *
 * ## 两种外壳
 *
 * - 功能页 10 个大按钮 → `hero: true`：参与「从卡片放大 / 缩回卡片」的转场；
 * - 页内二级页（博雅 → 选择课程 …）→ `hero: false`：返回走系统默认滑出，
 *   否则二级页的返回会被误判成「缩回某张卡片」。
 *
 * 两者都是自绘标题栏（样式对齐 HDS MINI：56vp 高、40vp 圆按钮、24vp Bold 标题）。
 */
/**
 * 原生 `Navigation` 用的路由表（功能页签专用）。
 *
 * ## 为什么功能页签单独一套
 *
 * 它要「完全可控的卡片展开转场」，而 HDS 把转场控制权收走了：
 * `HdsNavigation.customNavContentTransition` 不回调、跨 `HdsNavDestination` 的
 * `geometryTransition` 不生效。原生 `Navigation` 两者都支持
 * （实测回调正常：PUSH op=1 / POP op=2，前提是 push/pop 必须 `animated = true`）。
 *
 * ## 两种外壳
 *
 * - 功能页 10 个大按钮 → `hero: true`：参与「从卡片放大 / 缩回卡片」的转场；
 * - 页内二级页（博雅 → 选择课程 …）→ `hero: false`：返回走系统默认滑出，
 *   否则二级页的返回会被误判成「缩回某张卡片」。
 *
 * 两者都是自绘标题栏（对齐 HDS MINI：56vp 高、40vp 圆按钮、24vp Bold 标题）。
 *
 * ⚠️ `NativeHeroDest` / `HeroDetailLayer` 都有两个 `@BuilderParam`
 * （`trailing` + `content`），**不能**用尾随闭包调用，所以下面每个页面都写了一个
 * 具名 `@Builder`，用 `content: xxxBody` 传入。
 */


/**
 * 原生 `Navigation` 用的路由表（功能页签专用）。
 *
 * ## 为什么功能页签单独一套
 *
 * 它要「完全可控的卡片展开转场」，而 HDS 把转场控制权收走了：
 * `HdsNavigation.customNavContentTransition` 不回调、跨 `HdsNavDestination` 的
 * `geometryTransition` 不生效。原生 `Navigation` 两者都支持
 * （实测回调正常：PUSH op=1 / POP op=2，**前提是 push/pop 必须 `animated = true`**，
 * 否则系统根本不播转场、回调也不会来）。
 *
 * ## 两种目的地
 *
 * - 功能页 10 个大按钮 → `hero: true`：参与「从卡片放大 / 缩回卡片」的转场；
 * - 页内二级页（博雅 → 选择课程 …）→ `hero: false`：返回走系统默认滑出，
 *   否则二级页的返回会被误判成「缩回某张卡片」。
 *
 * 两者共用 `NativeHeroDest` 外壳（自绘标题栏，对齐 HDS MINI：56vp 高、40vp 圆按钮、
 * 24vp Bold 标题），页面内容由 `FeatureDestBody` 按 `routeName` 分派。
 */
@Builder
export function nativeFeatureRoute(name: string, param: object, stack: NavPathStack) {
  if (name === RouteName.EXAM) {
    NavDestination() {
      NativeHeroDest({
        title: '考试安排',
        hero: true,
        routeName: RouteName.EXAM,
        stack: stack,
        onBack: () => {
          AppRouter.back(stack);
        }
      })
    }
    .hideTitleBar(true)
    // 原生 Navigation/NavDestination 的 systemBarStyle 只收一个参数
    .systemBarStyle(systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.CLASSROOM) {
    NavDestination() {
      NativeHeroDest({
        title: '空闲教室',
        hero: true,
        routeName: RouteName.CLASSROOM,
        stack: stack,
        onBack: () => {
          AppRouter.back(stack);
        }
      })
    }
    .hideTitleBar(true)
    // 原生 Navigation/NavDestination 的 systemBarStyle 只收一个参数
    .systemBarStyle(systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.SIGNIN) {
    NavDestination() {
      NativeHeroDest({
        title: '课堂签到',
        hero: true,
        routeName: RouteName.SIGNIN,
        stack: stack,
        onBack: () => {
          AppRouter.back(stack);
        }
      })
    }
    .hideTitleBar(true)
    // 原生 Navigation/NavDestination 的 systemBarStyle 只收一个参数
    .systemBarStyle(systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.EVALUATION) {
    NavDestination() {
      NativeHeroDest({
        title: '自动评教',
        hero: true,
        routeName: RouteName.EVALUATION,
        stack: stack,
        onBack: () => {
          AppRouter.back(stack);
        }
      })
    }
    .hideTitleBar(true)
    // 原生 Navigation/NavDestination 的 systemBarStyle 只收一个参数
    .systemBarStyle(systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.SPOC) {
    NavDestination() {
      NativeHeroDest({
        title: 'SPOC 作业',
        hero: true,
        routeName: RouteName.SPOC,
        stack: stack,
        onBack: () => {
          AppRouter.back(stack);
        }
      })
    }
    .hideTitleBar(true)
    // 原生 Navigation/NavDestination 的 systemBarStyle 只收一个参数
    .systemBarStyle(systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.FINANCE) {
    NavDestination() {
      NativeHeroDest({
        title: '财务收入',
        hero: true,
        routeName: RouteName.FINANCE,
        stack: stack,
        onBack: () => {
          AppRouter.back(stack);
        }
      })
    }
    .hideTitleBar(true)
    // 原生 Navigation/NavDestination 的 systemBarStyle 只收一个参数
    .systemBarStyle(systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.CLOUD_PRINT) {
    NavDestination() {
      NativeHeroDest({
        title: '云打印',
        hero: true,
        routeName: RouteName.CLOUD_PRINT,
        stack: stack,
        onBack: () => {
          AppRouter.back(stack);
        }
      })
    }
    .hideTitleBar(true)
    .systemBarStyle(systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.NETWORK) {
    NavDestination() {
      NativeHeroDest({
        title: '网费流量',
        hero: true,
        routeName: RouteName.NETWORK,
        stack: stack,
        onBack: () => {
          AppRouter.back(stack);
        }
      })
    }
    .hideTitleBar(true)
    .systemBarStyle(systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.YGDK) {
    NavDestination() {
      NativeHeroDest({
        title: '阳光打卡',
        hero: true,
        routeName: RouteName.YGDK,
        stack: stack,
        onBack: () => {
          AppRouter.back(stack);
        }
      })
    }
    .hideTitleBar(true)
    // 原生 Navigation/NavDestination 的 systemBarStyle 只收一个参数
    .systemBarStyle(systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.IHOME) {
    NavDestination() {
      NativeHeroDest({
        title: 'iHome',
        hero: true,
        routeName: RouteName.IHOME,
        stack: stack,
        onBack: () => {
          AppRouter.back(stack);
        }
      })
    }
    .hideTitleBar(true)
    // 原生 Navigation/NavDestination 的 systemBarStyle 只收一个参数
    .systemBarStyle(systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.IHOME_DETAIL) {
    NavDestination() {
      NativeHeroDest({
        title: '诉求详情',
        hero: false,
        routeName: RouteName.IHOME_DETAIL,
        stack: stack,
        onBack: () => {
          AppRouter.back(stack);
        }
      })
    }
    .hideTitleBar(true)
    // 原生 Navigation/NavDestination 的 systemBarStyle 只收一个参数
    .systemBarStyle(systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.JUDGE) {
    NavDestination() {
      NativeHeroDest({
        title: '希冀作业',
        hero: false,
        routeName: RouteName.JUDGE,
        stack: stack,
        onBack: () => {
          AppRouter.back(stack);
        }
      })
    }
    .hideTitleBar(true)
    // 原生 Navigation/NavDestination 的 systemBarStyle 只收一个参数
    .systemBarStyle(systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.JUDGE_DETAIL) {
    NavDestination() {
      NativeHeroDest({
        title: '作业详情',
        hero: false,
        routeName: RouteName.JUDGE_DETAIL,
        stack: stack,
        onBack: () => {
          AppRouter.back(stack);
        }
      })
    }
    .hideTitleBar(true)
    // 原生 Navigation/NavDestination 的 systemBarStyle 只收一个参数
    .systemBarStyle(systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.BYKC) {
    NavDestination() {
      NativeHeroDest({
        title: '博雅课程',
        hero: true,
        routeName: RouteName.BYKC,
        stack: stack,
        onBack: () => {
          AppRouter.back(stack);
        }
      })
    }
    .hideTitleBar(true)
    // 原生 Navigation/NavDestination 的 systemBarStyle 只收一个参数
    .systemBarStyle(systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.BYKC_COURSES) {
    NavDestination() {
      NativeHeroDest({
        title: '选择课程',
        hero: false,
        routeName: RouteName.BYKC_COURSES,
        stack: stack,
        onBack: () => {
          AppRouter.back(stack);
        }
      })
    }
    .hideTitleBar(true)
    // 原生 Navigation/NavDestination 的 systemBarStyle 只收一个参数
    .systemBarStyle(systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.BYKC_CHOSEN) {
    NavDestination() {
      NativeHeroDest({
        title: '我的课程',
        hero: false,
        routeName: RouteName.BYKC_CHOSEN,
        stack: stack,
        onBack: () => {
          AppRouter.back(stack);
        }
      })
    }
    .hideTitleBar(true)
    // 原生 Navigation/NavDestination 的 systemBarStyle 只收一个参数
    .systemBarStyle(systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.BYKC_STATISTICS) {
    NavDestination() {
      NativeHeroDest({
        title: '课程统计',
        hero: false,
        routeName: RouteName.BYKC_STATISTICS,
        stack: stack,
        onBack: () => {
          AppRouter.back(stack);
        }
      })
    }
    .hideTitleBar(true)
    // 原生 Navigation/NavDestination 的 systemBarStyle 只收一个参数
    .systemBarStyle(systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.BYKC_DETAIL) {
    NavDestination() {
      NativeHeroDest({
        title: '课程详情',
        hero: false,
        routeName: RouteName.BYKC_DETAIL,
        stack: stack,
        onBack: () => {
          AppRouter.back(stack);
        }
      })
    }
    .hideTitleBar(true)
    // 原生 Navigation/NavDestination 的 systemBarStyle 只收一个参数
    .systemBarStyle(systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.LIBBOOK_HOME) {
    NavDestination() {
      NativeHeroDest({
        title: '图书馆座位',
        hero: true,
        routeName: RouteName.LIBBOOK_HOME,
        stack: stack,
        onBack: () => {
          AppRouter.back(stack);
        }
      })
    }
    .hideTitleBar(true)
    // 原生 Navigation/NavDestination 的 systemBarStyle 只收一个参数
    .systemBarStyle(systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.LIBBOOK_RESERVE) {
    NavDestination() {
      NativeHeroDest({
        title: '预约座位',
        hero: false,
        routeName: RouteName.LIBBOOK_RESERVE,
        stack: stack,
        onBack: () => {
          AppRouter.back(stack);
        }
      })
    }
    .hideTitleBar(true)
    // 原生 Navigation/NavDestination 的 systemBarStyle 只收一个参数
    .systemBarStyle(systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.LIBBOOK_BOOKINGS) {
    NavDestination() {
      NativeHeroDest({
        title: '我的座位预约',
        hero: false,
        routeName: RouteName.LIBBOOK_BOOKINGS,
        stack: stack,
        onBack: () => {
          AppRouter.back(stack);
        }
      })
    }
    .hideTitleBar(true)
    // 原生 Navigation/NavDestination 的 systemBarStyle 只收一个参数
    .systemBarStyle(systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
    .backgroundColor(Color.Transparent)
  } else if (name === RouteName.GRADE) {
    GradeNativeDestination({ stack: stack })
  } else {
    NavDestination() {
      Column() {
        Text('该页面尚未接入原生路由：' + name)
          .fontSize(15)
          .fontColor(AppColor.textSecondary)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .backgroundColor(AppColor.pageBackground)
    }
    .hideTitleBar(true)
    // 原生 Navigation/NavDestination 的 systemBarStyle 只收一个参数
    .systemBarStyle(systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(stack);
      return true;
    })
  }
}

/**
 * 成绩查询的原生目的地。
 *
 * 与其它页的区别：标题栏右侧要挂「2026秋季」学期切换器，它和页面共用同一个
 * `GradeHeaderModel`（换学期时两边一起刷新）—— 必须在同一个组件里持有它，
 * 所以这里显式传 `content`（`contentProvided: true`）。
 */
@Component
struct GradeNativeDestination {
  stack: NavPathStack = new NavPathStack();
  @State private header: GradeHeaderModel = new GradeHeaderModel();

  @Builder
  gradeBody() {
    GradePage({ header: this.header })
  }

  build() {
    NavDestination() {
      NativeHeroDest({
        title: '成绩查询',
        hero: true,
        routeName: RouteName.GRADE,
        stack: this.stack,
        content: (): void => { this.gradeBody(); },
        contentProvided: true,
        // 标题用外壳的标准标题栏（与考试安排等页同一位置：返回钮右侧、56vp 栏内）。
        // 学期切换已经从标题栏移进「本学期」卡片，titleVisible 不再需要关掉。
        titleVisible: true,
        onBack: () => {
          AppRouter.back(this.stack);
        }
      })
    }
    .hideTitleBar(true)
    // 原生 Navigation/NavDestination 的 systemBarStyle 只收一个参数
    .systemBarStyle(systemBarStyleFor(currentIsDark()))
    .onBackPressed(() => {
      AppRouter.back(this.stack);
      return true;
    })
    .backgroundColor(Color.Transparent)
  }
}
