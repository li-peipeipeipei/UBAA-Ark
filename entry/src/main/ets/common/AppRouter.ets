
import { BackGuard } from './BackGuard';
import { RecentFeatures } from './RecentFeatures';

/**
 * 路由表。
 *
 * 说明：4 个一级页签各自持有一个 NavPathStack（见 MainPage），
 * 二级页面在当前页签栈内跳转，底部悬浮页签栏保持可见（与主流原生 App 一致）。
 */
export class RouteName {
  static readonly EXAM: string = 'exam';
  static readonly GRADE: string = 'grade';
  static readonly CLASSROOM: string = 'classroom';
  static readonly SIGNIN: string = 'signin';
  /** iHome（接诉即办）。 */
  static readonly IHOME: string = 'ihome';
  /** iHome 诉求详情。 */
  static readonly IHOME_DETAIL: string = 'ihomeDetail';
  /** 希冀作业（列表）。 */
  static readonly JUDGE: string = 'judge';
  /** 希冀作业详情。 */
  static readonly JUDGE_DETAIL: string = 'judgeDetail';
  /** 自动评教（一键评教）。 */
  static readonly EVALUATION: string = 'evaluation';
  static readonly SPOC: string = 'spoc';
  /** 财务收入查询（上游 UBAA 2.0 对齐）。 */
  static readonly FINANCE: string = 'finance';
  /** 网费流量查询（上游 UBAA 2.0「校园服务」对齐）。 */
  static readonly NETWORK: string = 'network';
  static readonly CLOUD_PRINT: string = 'cloudPrint';
  static readonly YGDK: string = 'ygdk';
  static readonly BYKC: string = 'bykc';
  /** 图书馆座位首页。 */
  static readonly LIBBOOK_HOME: string = 'libbookHome';
  /** 图书馆座位：预约座位。 */
  static readonly LIBBOOK_RESERVE: string = 'libbookReserve';
  /** 图书馆座位：我的座位预约。 */
  static readonly LIBBOOK_BOOKINGS: string = 'libbookBookings';
  /** 博雅子页：选择课程（列表 + 筛选）。 */
  static readonly BYKC_COURSES: string = 'bykcCourses';
  /** 博雅子页：我的课程。 */
  static readonly BYKC_CHOSEN: string = 'bykcChosen';
  /** 博雅子页：课程统计。 */
  static readonly BYKC_STATISTICS: string = 'bykcStatistics';
  /** 博雅子页：课程详情。 */
  static readonly BYKC_DETAIL: string = 'bykcDetail';
  static readonly USER_INFO: string = 'userInfo';
  static readonly SETTINGS: string = 'settings';
  static readonly ABOUT: string = 'about';
  /** 切换应用图标（Ark/原版 × 浅/深，API 26 备用图标）。 */
  static readonly ICON_SWITCH: string = 'iconSwitch';
  /** 隐私政策与用户协议（应用内全文，上架合规要求）。 */
  static readonly PRIVACY: string = 'privacy';
  /** 开源许可（MIT 全文 + 上游项目署名，MIT 许可证要求的随附声明）。 */
  static readonly LICENSE: string = 'license';
  /** 扫一扫识别出的网页（带统一认证 Cookie 的全屏 Web 二级页）。 */
  static readonly SCAN_WEB: string = 'scanWeb';
  /** SPOC 网页提交（先登录再跳作业详情的全屏 Web 二级页，走系统导航转场）。 */
  static readonly SPOC_WEB: string = 'spocWeb';
}

/**
 * 扫码得到的网页地址。
 *
 * 系统扫码界面在 HomePage 里回调，网页页在 RouteBuilder 里创建 —— 两者之间
 * 用 AppStorage 传参（与 SPOC 网页浮层同款做法），避免全局 @Builder 解析
 * NavPathStack param 时的 ArkTS 类型限制。
 */
export const KEY_SCAN_WEB_URL: string = 'scanWebUrl';

/** 宽屏 Split 右栏栈空时压入的占位路由（只由 MainPage 在 lg / xxl 档使用）。 */
export const WIDE_PLACEHOLDER_ROUTE: string = 'widePlaceholder';

export class AppRouter {
  /**
   * 最近一次进入二级页是否带动画。
   *
   * 返回时沿用同一个值，转场才对称：硬切进来的一页如果带着滑出动画退回，
   * 看起来像是从别处冒出来又滑走。功能页的大按钮目前是**硬切**（产品要求，
   * 那处的转场单独设计），其余入口都带动画。
   */
  private static lastPushAnimated: boolean = true;

  /**
   * 压栈打开二级页。
   *
   * @param animated 是否播放系统转场（默认 true：自右向左滑入）。
   *   传 false 只用于「功能页大按钮」那一处，其余入口一律带动画。
   */
  static push(stack: NavPathStack, name: string, param?: object, animated: boolean = true): void {
    // 进入新二级页前清掉「页面内浮层」遗留的返回拦截层。
    //
    // 页签内容是常驻的（HdsTabs 不销毁，aboutToDisappear 不触发），某个页面里
    // 打开的浮层（筛选面板 / 公告正文 / 学期选择 / 打印预览 / 提交遮罩）注册的
    // BackGuard 层，如果用户没关就离开了，会一直留在全局栈里 —— 之后进入的
    // 任何二级页按返回（左上角 + 系统返回都走 AppRouter.back → BackGuard.consume）
    // 都会被这层「关掉一个看不见的面板」吞掉，表现为**返回键失灵**，只有点
    // 导航栏触发 dropStaleBackGuards() 才恢复。
    //
    // 打开新页面意味着已经离开旧页，旧页浮层的返回优先级必须先作废。
    // 新页自己的浮层是 push 之后才 register 的，不受影响。
    BackGuard.clear();
    AppRouter.lastPushAnimated = animated;
    if (param === undefined) {
      stack.pushPath({ name: name }, animated);
    } else {
      stack.pushPath({ name: name, param: param }, animated);
    }
  }

  /** 打开二级页：统一走压栈（分栏已取消）。 */
  static open(stack: NavPathStack, name: string, param?: object, animated: boolean = true): void {
    // 记一次「最近使用」：首页的快捷入口按真实使用轨迹显示（上游「最近使用的功能」）
    RecentFeatures.record(name);
    AppRouter.push(stack, name, param, animated);
  }

  /**
   * 返回。**先给页面内部的浮层一次机会**（筛选面板、作业详情弹窗、全屏网页…），
   * 浮层都关完了才真正弹栈 —— 见 `BackGuard`。
   *
   * 26 个二级页的 `onBackPressed` 全部走这里，所以「浮层优先」只在这一处实现。
   */
  static back(stack: NavPathStack): void {
    if (BackGuard.consume()) {
      return;
    }
    stack.pop(AppRouter.lastPushAnimated);
  }
}

/** 加载状态机，页面统一用它驱动 加载中 / 内容 / 错误 / 空 四态。 */
export enum LoadState {
  LOADING = 0,
  SUCCESS = 1,
  ERROR = 2
}
