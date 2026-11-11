
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
  /** 隐私政策与用户协议（应用内全文，上架合规要求）。 */
  static readonly PRIVACY: string = 'privacy';
  /** 开源许可（MIT 全文 + 上游项目署名，MIT 许可证要求的随附声明）。 */
  static readonly LICENSE: string = 'license';
}

/** 宽屏 Split 右栏栈空时压入的占位路由（只由 MainPage 在 lg / xxl 档使用）。 */
export const WIDE_PLACEHOLDER_ROUTE: string = 'widePlaceholder';

export class AppRouter {
  static push(stack: NavPathStack, name: string, param?: object): void {
    if (param === undefined) {
      stack.pushPath({ name: name });
    } else {
      stack.pushPath({ name: name, param: param });
    }
  }

  /**
   * 打开二级页（区分单栏 / 分栏）。
   *
   * 分栏时「左列表 → 右详情」是一对一关系：已经在看某个详情时再点另一个条目，
   * 应该是**替换**右栏内容，而不是继续压栈（否则返回一次只退到上一个详情，
   * 语义上说不通，用户会觉得返回键失灵）。单栏时仍然正常压栈。
   */
  static open(stack: NavPathStack, name: string, splitMode: boolean, param?: object): void {
    if (splitMode && stack.size() > 0) {
      if (param === undefined) {
        stack.replacePath({ name: name });
      } else {
        stack.replacePath({ name: name, param: param });
      }
      return;
    }
    AppRouter.push(stack, name, param);
  }

  /**
   * 延后一帧多一点再打开二级页（分栏切换专用）。
   *
   * 为什么要延后：分栏是父组件切 `mode` 得来的，同一帧既切 mode 又 push，内容栏会和详情
   * 一起新建，push 动画被吞掉（横屏大窗口下必然瞬显）。
   *
   * ⚠️ 用定时器而**不是** `postFrameCallback`：帧回调只在"真的排了新帧"时才触发，
   * 平板竖屏下点一下未必有下一帧在排队，于是回调永不触发、页面表现成"点了没反应"
   * （真机踩过）。定时器是确定性的，32ms 约等于两帧，足够让分栏那次布局与渲染落地。
   */
  static openAfterLayout(stack: NavPathStack, name: string, splitMode: boolean): void {
    setTimeout(() => {
      AppRouter.open(stack, name, splitMode);
    }, 32);
  }

  /** 二级页返回前通知外层：立刻收起分栏（让左栏在 pop 的同时向右展开，而不是等 pop 结束）。 */
  static requestSplitCollapse(): void {
    AppStorage.setOrCreate('ubaaSplitCollapse', Date.now());
  }

  static back(stack: NavPathStack): void {
    stack.pop();
  }
}

/** 加载状态机，页面统一用它驱动 加载中 / 内容 / 错误 / 空 四态。 */
export enum LoadState {
  LOADING = 0,
  SUCCESS = 1,
  ERROR = 2
}
