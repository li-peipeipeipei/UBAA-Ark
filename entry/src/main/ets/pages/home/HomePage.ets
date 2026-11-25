import { AppRouter, LoadState, RouteName, KEY_SCAN_WEB_URL } from '../../common/AppRouter';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { DateUtil } from '../../common/DateUtil';
import { Logger } from '../../common/Logger';
import { Toast } from '../../common/Toast';
import { ApiError } from '../../network/ApiError';
import { ApiService } from '../../network/ApiService';
import { CardDataBuilder } from '../../common/CardDataBuilder';
import { TokenStore } from '../../network/TokenStore';
import { AppColor, AppFont, AppSize } from '../../components/AppTheme';
import { topSafeInsetVp } from '../../common/ImmersiveUtil';
import { KEY_IS_DARK, surfaceArgbHex, transparentOf } from '../../common/ImmersiveUtil';
import {
  EmptyView,
  ErrorView,
  LoadingView,
  SectionCard
} from '../../components/CommonViews';
import { MaterialCardLayer } from '../../components/MaterialCardLayer';
import {
  buildCourseDetail,
  buildSimpleDetail,
  CourseDetail,
  CourseDetailDialog
} from '../../components/CourseDetailDialog';
import { CourseClass, Exam, SigninClass, SpocAssignment, Term, TodayClass, Week, WeeklySchedule } from '../../model/ApiTypes';
import { columnsByMinWidth, isTwoPane, KEY_BREAKPOINT } from '../../common/Breakpoint';
import { RECENT_STORE_LIMIT, RecentFeatures } from '../../common/RecentFeatures';
import { KEY_SIGNIN_VERSION, SigninEvents } from '../../common/SigninEvents';
import { allFeatures, FeatureItem } from '../../components/FeatureRegistry';
import { ScheduleColors } from '../../common/ScheduleColors';
import { PageCache } from '../../common/PageCache';
import { OfflineKey } from '../../common/OfflineCache';

/** 首页首帧缓存内容。纯数据，可 JSON 序列化。 */
interface HomeCache {
  /** 缓存写入时「今日课程」对应的日期（yyyy-MM-dd），跨天作废。 */
  date: string;
  todayClasses: TodayClass[];
  tomorrowClasses: TodayClass[];
  todos: SpocAssignment[];
  exams: Exam[];
}

/**
 * 「最近使用」入口个数按**卡片实际内宽**自适应，不再写死 4 个。
 *
 * 4 是下限（手机一行放 4 个刚好）；8 是上限（再多的使用记录也只展示最近 8 个）。
 * 平板竖屏单列约能放 8 个，横屏两栏的左栏较窄、约 6 个 —— 由 `onAreaChange`
 * 量出来的真实宽度决定，不用断点猜。
 */
const RECENT_MIN_COLUMNS: number = 4;
const RECENT_MAX_COLUMNS: number = 8;

/** 单个入口的最小宽度：图标 44vp + 标题（4 字以内），再窄标题就被压没了。 */
const RECENT_ITEM_MIN_WIDTH: number = 56;

/** 入口之间的间距（均分后仍留一点呼吸感）。 */
const RECENT_ITEM_SPACE: number = 8;

/** 取今日课程时间串 `15:50-17:25` 里的开始时间（取不到返回空串）。 */
function startTimeOf(item: TodayClass): string {
  const time: string = item.time === undefined ? '' : item.time;
  const dash: number = time.indexOf('-');
  return (dash > 0 ? time.substring(0, dash) : time).trim();
}

/** 取今日课程时间串里的结束时间（取不到返回空串）。 */
function endTimeOf(item: TodayClass): string {
  const time: string = item.time === undefined ? '' : item.time;
  const dash: number = time.indexOf('-');
  return dash >= 0 ? time.substring(dash + 1).trim() : '';
}

/** 当前时刻 `HH:mm`（与接口给的时间串同为定长，可直接字符串比较）。 */
function nowHHmm(): string {
  const date = new Date();
  const hour: number = date.getHours();
  const minute: number = date.getMinutes();
  return (hour < 10 ? '0' : '') + hour.toString() + ':' +
    (minute < 10 ? '0' : '') + minute.toString();
}

/**
 * 签到按钮的提前量：教师常在上课前几分钟开窗。
 *
 * 与 `SigninPage` 的 `SIGNIN_EARLY_MS` 保持一致（10 分钟）—— 两处口径不一致会出现
 * 「首页能点、签到页说未开始」这种自相矛盾。
 */
const SIGNIN_EARLY_MINUTES: number = 10;

/** `HH:mm` → 一天中的分钟数；解析不了返回 -1。 */
function minutesOf(hhmm: string): number {
  const parts: string[] = hhmm.split(':');
  if (parts.length < 2) {
    return -1;
  }
  const hour: number = Number.parseInt(parts[0], 10);
  const minute: number = Number.parseInt(parts[1], 10);
  if (Number.isNaN(hour) || Number.isNaN(minute)) {
    return -1;
  }
  return hour * 60 + minute;
}

/**
 * 今日课程按**开始时间升序**排列（接口返回的顺序是随机的，不是按时间排的）。
 * 没有时间的条目排到最后。
 */
function sortTodayClasses(list: TodayClass[]): TodayClass[] {
  const sorted: TodayClass[] = list.slice();
  sorted.sort((a: TodayClass, b: TodayClass): number => {
    const left: string = startTimeOf(a);
    const right: string = startTimeOf(b);
    if (left === right) {
      return 0;
    }
    if (left.length === 0) {
      return 1;
    }
    if (right.length === 0) {
      return -1;
    }
    return left < right ? -1 : 1;
  });
  return sorted;
}

/** 课表项的时间串，格式与「今日课程」接口的 `time` 一致：`HH:mm-HH:mm`。 */
function courseTimeOf(course: CourseClass): string {
  const begin: string = course.beginTime === undefined ? '' : course.beginTime;
  const end: string = course.endTime === undefined ? '' : course.endTime;
  if (begin.length > 0 && end.length > 0) {
    return begin + '-' + end;
  }
  return begin.length > 0 ? begin : end;
}

/**
 * 按「课程名 + 当天 + 时间」在课表里找课，必要时合并同日多节记录。
 *
 * ## 三级匹配 + 一次合并（2026-11-17）
 *
 * 上游对「连上两节」的课有两种写法，同一门课可能同时出现：
 *   - 合并写法：`0102`、`08:00-09:35` 一条记录
 *   - 拆分写法：`0101`、`08:00-08:45` + `0202`、`08:50-09:35` 两条记录
 * 「今日课程」接口会把这些合并成一行（`08:00-09:35`），于是按时间精确匹配
 * 在拆分写法下必然落空，只能退化到「只按名字」—— 那样很容易命中**别的星期**的同名课
 * （例如周一也有 08:00-09:35 的常微分方程），弹出来的时间/节次跟卡片上写的对不上。
 *
 * 所以这里显式按 `dayOfWeek === 今天` 收窄，并且：
 *   1. 先找「同一天 + 名字 + 时间全等」的那条；
 *   2. 找不到就把**同一天同名**的若干条合成一条（起止节次取并集、起止时间取最早最晚），
 *      合成结果的 spans 与卡片一致时直接用；
 *   3. 都不行才退回「同一天 + 名字」，最后才允许跨天。
 *
 * 返回 `null` 表示课表里确实没有（今日课程接口有但本周课表没有的临时课程）。
 */
function findCourseByNameAndTime(list: CourseClass[], name: string, time: string,
  weekday: number, strict: boolean = false): CourseClass | null {
  const hasTime: boolean = time.length > 0;
  const sameDay: CourseClass[] = [];
  const sameName: CourseClass[] = [];
  for (let i = 0; i < list.length; i++) {
    const candidate: string = list[i].courseName;
    if (candidate.length === 0) {
      continue;
    }
    const nameHit: boolean = candidate === name || candidate.indexOf(name) >= 0 || name.indexOf(candidate) >= 0;
    if (!nameHit) {
      continue;
    }
    sameName.push(list[i]);
    if (list[i].dayOfWeek !== undefined && list[i].dayOfWeek === weekday) {
      sameDay.push(list[i]);
    }
  }

  // ① 同一天 + 时间全等
  if (hasTime) {
    for (let i = 0; i < sameDay.length; i++) {
      if (courseTimeOf(sameDay[i]) === time) {
        return sameDay[i];
      }
    }
  }
  // ② 同一天多条记录 → 合成一条（与「今日课程」的合并口径对齐）
  if (hasTime && sameDay.length > 1) {
    const merged: CourseClass | null = mergeSameDay(sameDay, name, time, weekday);
    if (merged !== null) {
      return merged;
    }
  }
  // ③ 同一天 + 名字（时间对不上，但至少是同一天的课）
  if (sameDay.length > 0) {
    return sameDay[0];
  }
  // ④ 跨天 / dayOfWeek 缺失兜底：**时间串完全相等**的同名课是安全匹配 ——
  //    节次与教师由时间唯一确定，不会因为「换了一天」就张冠李戴。
  //    上游课表偶有条目的 dayOfWeek 缺失，此时 sameDay 为空，全靠这一步兜住。
  if (hasTime) {
    for (let i = 0; i < sameName.length; i++) {
      if (courseTimeOf(sameName[i]) === time) {
        return sameName[i];
      }
    }
  }
  // ⑤ 仅凭名字取第一条：严格模式（明日课程）不用 —— 同名课一周上多次、节次不同，
  //    取第一条会显示错的时间 / 节次，宁可退回「时间 + 地点」两行。
  if (!strict && sameName.length > 0) {
    return sameName[0];
  }
  return null;
}

/** 把同一天同一门课的若干条记录合成一条；并集与 `time` 不吻合时返回 null。 */
function mergeSameDay(items: CourseClass[], name: string, time: string,
  weekday: number): CourseClass | null {
  let beginSection: number = Number.MAX_SAFE_INTEGER;
  let endSection: number = 0;
  let beginTime: string = '';
  let endTime: string = '';
  let anchor: CourseClass = items[0];
  let teacherSrc: CourseClass = items[0];
  for (let i = 0; i < items.length; i++) {
    const it: CourseClass = items[i];
    const bs: number = it.beginSection !== undefined && it.beginSection > 0 ? it.beginSection : 0;
    const es: number = it.endSection !== undefined && it.endSection > 0 ? it.endSection : bs;
    if (bs > 0 && bs < beginSection) {
      beginSection = bs;
      anchor = it;
      if (it.beginTime !== undefined && it.beginTime.length > 0) {
        beginTime = it.beginTime;
      }
    }
    if (es > endSection) {
      endSection = es;
      if (it.endTime !== undefined && it.endTime.length > 0) {
        endTime = it.endTime;
      }
    }
    if (it.weeksAndTeachers !== undefined && it.weeksAndTeachers.length > 0) {
      teacherSrc = it;
    }
  }
  if (beginSection === Number.MAX_SAFE_INTEGER || endSection === 0) {
    return null;
  }
  const mergedTime: string = beginTime.length > 0 && endTime.length > 0 ? beginTime + '-' + endTime : '';
  // 并集必须正好等于卡片上写的那一段，否则合并反而制造错误信息
  if (time.length > 0 && mergedTime !== time) {
    return null;
  }
  const merged: CourseClass = {
    courseCode: anchor.courseCode,
    courseName: name,
    courseSerialNo: anchor.courseSerialNo,
    credit: anchor.credit,
    beginTime: beginTime,
    endTime: endTime,
    beginSection: beginSection,
    endSection: endSection,
    placeName: anchor.placeName,
    weeksAndTeachers: teacherSrc.weeksAndTeachers,
    teachingTarget: anchor.teachingTarget,
    color: anchor.color,
    dayOfWeek: weekday,
    titleDetail: anchor.titleDetail
  };
  return merged;
}

/**
 * 主页。
 *
 * 信息层级：问候语 → 下一场考试倒计时 → 今日课程 → 快捷入口。
 * 页面本身不持有标题栏，标题栏由 MainPage 的 HdsNavigation 统一提供（含沉浸光感）。
 */
@Component
export struct HomePage {
  stack: NavPathStack = new NavPathStack();
  /** 当前宽度断点：决定磁贴列数与是否双列并排。 */
  @StorageProp(KEY_BREAKPOINT) private bp: string = 'sm';
  /**
   * 是否深色模式。
   *
   * 必须是 `@StorageProp` 而不是在 builder 里裸读 `AppStorage` ——
   * 教室文字的尾部渐隐条颜色要跟着主题换（深色 `#1A1A1A` / 浅色 `#FFFFFF`），
   * 没有订阅关系时切主题不会重绘，渐变会停在旧配色上。
   */
  @StorageProp(KEY_IS_DARK) private isDark: boolean = false;
  @State private loadState: LoadState = LoadState.LOADING;
  /** 「最近使用」的路由名（按最近优先，最多 `RECENT_STORE_LIMIT` 个）。 */
  @State private recentRoutes: string[] = [];
  /** 当前一行放几个入口，由卡片内宽反推（首帧用下限，避免首屏空白）。 */
  @State private recentColumns: number = RECENT_MIN_COLUMNS;
  /** 待办：未提交且未过期的作业（按截止时间排序，最多 3 条）。 */
  @State private todos: SpocAssignment[] = [];
  @State private errorMessage: string = '';
  @State private todayClasses: TodayClass[] = [];
  /**
   * 明日课程（与今日课程同一上游接口，只换 `rq` 日期）。
   *
   * 只在「今天没课」或「今天全部上完」时才渲染，其余时间保持静默加载 ——
   * 这样最后一节课下课那一刻能立刻显示，不必等用户下拉刷新。加载失败也只记日志。
   */
  @State private tomorrowClasses: TodayClass[] = [];
  /** 今日课程是否已全部上完（结束时间都已过），由 30 秒定时器驱动。 */
  @State private todayFinished: boolean = false;
  /** 今日课程对应的日期；跨天时自动重拉当天与次日课程。 */
  private loadedDate: string = '';
  /**
   * 今日课堂的签到状态（iclass）。
   *
   * 「今日课程」来自教务，签到状态来自 iclass，两边只有**课程名**能对位。
   * 拉不到（签到系统没登录 / 网络不通）时整块退回原图标，绝不让首页因此报错。
   */
  @State private signinClasses: SigninClass[] = [];
  /** 正在提交签到的课程 id；空串表示空闲（防连点导致重复写）。 */
  @State private signinPendingId: string = '';
  /**
   * 「现在」的毫秒数，30 秒刷一次。
   *
   * 首页往往在课间一直开着，13:45 一到（开课前 15 分钟）按钮要自己冒出来，
   * 不能等用户下拉刷新。
   */
  @State private nowMs: number = Date.now();
  private signinTickTimer: number = -1;
  /** 签到页签完之后的通知：计数变了就重读一次状态。 */
  @StorageProp(KEY_SIGNIN_VERSION) @Watch('onSigninVersion') private signinVersion: number = 0;
  /**
   * App 每次回到前台翻转（`EntryAbility.onForeground` 写）。
   *
   * 锁屏 / 切到别的应用期间 30 秒定时器可能被冻结，回来时「现在」还停在离开那一刻；
   * 顺手重取一次，也让「在网页版 iClass 上签过」这种情况能同步过来。
   */
  @StorageLink('appForegroundTick') @Watch('onForegroundTick') private foregroundTick: boolean = false;
  @State private hasNextExam: boolean = false;
  @State private nextExam: Exam = { courseName: '' };
  /** 下拉刷新进行中；Refresh 组件靠它复位转圈动画。 */
  @State private refreshing: boolean = false;
  /** 刷新请求是否在途（非 @State：只做互斥，不参与渲染）。 */
  private refreshInFlight: boolean = false;
  /** 今日课程详情弹窗的内容（@Observed 实例，弹窗用 @ObjectLink 订阅，可原地刷新）。 */
  @State private courseDetail: CourseDetail = new CourseDetail();
  private detailController: CustomDialogController | null = null;
  /**
   * 本周课表缓存（**进页面就预加载**）。
   *
   * 「今日课程」接口只给课程名 / 时间 / 地点，完整详情在课表响应里。预加载之后，
   * 点击课程块时是**同步组装**详情的 —— 与课表页同一个体验：点开即是完整内容，
   * 没有加载态、也没有「先把标签列出来再慢慢填值」的过程。
   */
  private preloadedCourses: CourseClass[] = [];
  private preloadDone: boolean = false;
  /**
   * 在途的预加载任务。
   *
   * 点击课程时如果预加载还没完成（首页是 fire-and-forget 拉取的，用户可能很快就点），
   * 这里 `await` 同一个任务而不是直接用空数组 —— 否则会退化成只有「时间 / 地点」两行，
   * 与课表页点开的完整详情对不上。并发点击共用一次请求，不重复打接口。
   */
  private preloadTask: Promise<void> | null = null;
  /**
   * 已解析的当前学期编码（本页内缓存）。
   *
   * `loadHome` 与 `preloadCourses` 都要用学期编码，缓存一次省掉重复拉学期列表。
   * **只在本页生命周期内有效** —— 换学期要重启应用或重新进首页，可接受；
   * 不写进 TokenStore 当「真相」，那个位置只用于跨启动兜底。
   */
  private termCodeCache: string = '';
  /** 首页缓存对象（首帧恢复 + 后台拉新后合并写回，避免多次加载互相覆盖）。 */
  private homeCache: HomeCache | null = null;
  /** 当前缓存里的考试列表（考试倒计时据此重算，跨天仍然正确）。 */
  private cachedExams: Exam[] = [];

  /**
   * 冷启动首帧：同步读上次缓存填进 @State。
   *
   * 三道校验保证不显示过期数据：
   * 1. TTL（1 天）—— 由 PageCache 判；
   * 2. 日期一致 —— 今日课程是「当天」语义，隔天必须重拉；
   * 3. 考试倒计时按「现在」重算，不缓存倒计时天数本身。
   *
   * 缓存失败/缺失时保持 LOADING，走原来的网络流程，行为与没有缓存时一致。
   */
  private restoreCached(): void {
    const cached: HomeCache | null = PageCache.load<HomeCache>(OfflineKey.HOME, PageCache.TTL_DAY);
    if (cached === null || cached.date !== DateUtil.today()) {
      return;
    }
    this.homeCache = cached;
    this.todayClasses = sortTodayClasses(cached.todayClasses);
    this.tomorrowClasses = sortTodayClasses(cached.tomorrowClasses);
    this.todos = cached.todos;
    this.cachedExams = cached.exams;
    this.loadedDate = cached.date;
    this.todayFinished = this.computeTodayFinished();
    // 考试倒计时按当前日期重选，而不是缓存上次选中的那场
    this.pickNextExam(this.cachedExams);
    // 关键：有内容就直接进 SUCCESS，首帧渲染真实数据而非转圈
    if (this.todayClasses.length > 0 || this.hasNextExam || this.todos.length > 0) {
      this.loadState = LoadState.SUCCESS;
    }
  }

  /** 把当前各路数据合并写回缓存（后台拉新成功后调用）。 */
  private persistCache(): void {
    const cache: HomeCache = {
      date: DateUtil.today(),
      todayClasses: this.todayClasses,
      tomorrowClasses: this.tomorrowClasses,
      todos: this.todos,
      exams: this.cachedExams
    } as HomeCache;
    this.homeCache = cache;
    PageCache.save(OfflineKey.HOME, cache);
  }


  aboutToAppear(): void {
    // 「最近使用」只在**进入应用时**读一次（产品要求：返回首页不要立刻重排，
    // 否则刚点过的入口会在眼前跳位置）。使用轨迹照常记录，顺序在下次启动时生效。
    this.recentRoutes = RecentFeatures.list(RECENT_STORE_LIMIT);
    // 冷启动首帧：先把上次的缓存填进去，避免「转圈→内容」的空白期。
    // 后台 loadHome 照常拉新，成功后无缝覆盖（见 loadHome）。
    this.restoreCached();
    this.loadHome(true);
    // 明日课程后台加载：与今日课程同一接口换日期，失败静默
    this.loadTomorrow();
    // 待办（作业截止）后台加载，失败静默 —— 不影响首页主体
    this.loadTodos();
    // 今日课程的签到状态：只在窗口内的课会用到它，同样后台加载、失败静默
    this.loadSigninState();
    // 后台预加载本周课表（不阻塞首页渲染）—— 点课程时才有完整的详情可用
    this.preloadCourses();
    this.signinTickTimer = setInterval(() => {
      this.nowMs = Date.now();
      this.refreshDayState();
    }, 30000);
  }

  aboutToDisappear(): void {
    if (this.signinTickTimer >= 0) {
      clearInterval(this.signinTickTimer);
      this.signinTickTimer = -1;
    }
  }

  /** 签到页那边签完了：重读一次，别让首页还挂着「签到」按钮。 */
  private onSigninVersion(): void {
    this.loadSigninState();
  }

  /** 回到前台：把「现在」推新，并重读一次签到状态（见字段注释）。 */
  private onForegroundTick(): void {
    this.nowMs = Date.now();
    this.refreshDayState();
    this.loadSigninState();
  }

  /** 明日课程：只取日期，失败静默（附加信息，不拖累主页主体）。 */
  private async loadTomorrow(force: boolean = false): Promise<void> {
    const date: string = DateUtil.format(DateUtil.addDays(new Date(), 1));
    try {
      const list: TodayClass[] = await ApiService.fetchClassesOn(date, force);
      this.tomorrowClasses = sortTodayClasses(list);
      this.persistCache();
    } catch (error) {
      this.tomorrowClasses = [];
      Logger.warn('明日课程加载失败：' + (error as Error).message);
    }
  }

  /**
   * 今日课程是否「全部上完」：每门课都要有结束时间，且都已早于现在。
   *
   * 缺时间的课不算完成 —— 接口偶尔给不出时间串，此时宁可继续显示今日课程，
   * 也不要误判成「已完成」而把今日列表藏掉。
   */
  private computeTodayFinished(): boolean {
    if (this.todayClasses.length === 0) {
      return false;
    }
    const now: number = this.nowMinuteOfDay();
    for (let i = 0; i < this.todayClasses.length; i++) {
      const end: number = minutesOf(endTimeOf(this.todayClasses[i]));
      if (end < 0 || now <= end) {
        return false;
      }
    }
    return true;
  }

  /**
   * 30 秒 tick / 回到前台：推进「今日是否上完」，并处理跨天。
   *
   * 应用可能整夜开着：日期翻过去后，原来的「今日课程」属于昨天，
   * 「明日课程」其实已经是今天 —— 必须重拉，否则显示的是错的课。
   */
  private refreshDayState(): void {
    this.todayFinished = this.computeTodayFinished();
    const today: string = DateUtil.today();
    if (this.loadedDate.length > 0 && today !== this.loadedDate) {
      this.loadedDate = today;
      this.loadHome(false);
      this.loadTomorrow();
    }
  }

  /**
   * 拉今日签到状态。
   *
   * 本地模式之外（旧中转服务）没有签到接口，直接跳过；任何失败都只记日志 ——
   * 这块只是「首页顺手能签到」的增强，坏了不该影响今日课程、考试倒计时。
   */
  private async loadSigninState(): Promise<void> {
    if (!TokenStore.hasLocalSession()) {
      return;
    }
    try {
      this.signinClasses = await ApiService.fetchSigninClasses();
    } catch (error) {
      Logger.warn('首页签到状态加载失败：' + (error as Error).message);
    }
  }

  /**
   * 预加载本周课表（与课表页取的是同一份数据）。
   *
   * 幂等且可并发：已完成直接返回，在途则复用同一个 Promise。
   * 失败不抛错（首页不该因为课表拉不到就报错），下次点击会重试。
   */
  private preloadCourses(): Promise<void> {
    if (this.preloadDone) {
      return Promise.resolve();
    }
    if (this.preloadTask !== null) {
      return this.preloadTask;
    }
    const task: Promise<void> = this.loadCoursesOnce().then(() => {
      this.preloadTask = null;
    }).catch(() => {
      this.preloadTask = null;
    });
    this.preloadTask = task;
    return task;
  }

  private async loadCoursesOnce(): Promise<void> {
    try {
      const termCode: string = await this.resolveTermCode();
      if (termCode.length === 0) {
        return;
      }
      const week: number = await this.resolveCurrentWeek(termCode);
      const schedule: WeeklySchedule = await ApiService.fetchWeeklySchedule(termCode, week);
      this.preloadedCourses = schedule.arrangedList;
      this.preloadDone = true;
      Logger.info('首页预加载本周课表：' + this.preloadedCourses.length + ' 门（第 ' + week + ' 周）');
    } catch (error) {
      // 不置 preloadDone，下次点击会重试
      Logger.warn('首页预加载课表失败：' + (error as Error).message);
    }
  }

  /** 确保课表已就绪再返回（供点击课程时调用，最多阻塞一次网络往返）。 */
  private async ensureCourses(): Promise<CourseClass[]> {
    if (!this.preloadDone) {
      await this.preloadCourses();
    }
    return this.preloadedCourses;
  }

  /**
   * 当前教学周。
   *
   * **必须用「当前教学周」而不是「用户记住的周次」优先**：课表页会把用户翻看的周次记下来
   * （比如翻到第 10 周），若按它取，今天的课自然找不到。
   *
   * ⚠️ 上游没标 `curWeek` 时，**按校历日期实算**，最后才退回「记住的周次」。
   * 早先这里直接用 `TokenStore.getSelectedWeek()` 兜底，用户上次翻到第 5 周，
   * 首页就会一直把「今天」当成第 5 周 —— 看到的今日课程全是错的。
   */
  private async resolveCurrentWeek(termCode: string): Promise<number> {
    const weeks: Week[] = await ApiService.fetchWeeks(termCode);
    for (let i = 0; i < weeks.length; i++) {
      if (weeks[i].curWeek) {
        return weeks[i].serialNumber;
      }
    }
    const byCalendar: number = CardDataBuilder.weekOfToday(weeks);
    if (byCalendar > 0) {
      return byCalendar;
    }
    const remembered: number = TokenStore.getSelectedWeek();
    return remembered > 0 ? remembered : 1;
  }

  /**
   * 拉取主页数据。
   *
   * @param showLoading 首次进入（true）：整页切加载态，失败显示错误页 + 重试；
   *                    下拉刷新（false）：**保持现有内容**后台拉新，失败只轻提示 ——
   *                    刷新的语义是「更新」，把用户正在看的内容清空反而是打扰。
   * @param force 是否绕开内存缓存。**用户显式刷新 / 点重试必须传 true** ——
   *              否则会拿到 TTL 内的旧值，表现为「点了没反应」。
   */
  private async loadHome(showLoading: boolean, force: boolean = false): Promise<void> {
    // 首帧已用缓存渲染时不再切 LOADING：否则用户会看到「内容→转圈→内容」的跳动。
    // 只有完全没有缓存内容时才显示加载态。
    if (showLoading && this.loadState !== LoadState.SUCCESS) {
      this.loadState = LoadState.LOADING;
    }
    try {
      const classes: TodayClass[] = await ApiService.fetchTodayClasses(force);
      // 接口返回的顺序是乱的，按开始时间重排（早的在上）
      this.todayClasses = sortTodayClasses(classes);
      this.loadedDate = DateUtil.today();
      this.todayFinished = this.computeTodayFinished();

      // 首次登录时还没有缓存学期，此时不能直接跳过考试 —— 否则首页会缺掉倒计时卡片
      const termCode: string = await this.resolveTermCode();
      if (termCode.length > 0) {
        const data = await ApiService.fetchExams(termCode, force);
        this.cachedExams = data.arranged;
        this.pickNextExam(this.cachedExams);
      }
      this.loadState = LoadState.SUCCESS;
      // 拉新成功：把最新内容写回缓存，下次冷启动首帧就是它
      this.persistCache();
    } catch (error) {
      const message = error instanceof ApiError ?
        (error as ApiError).friendlyMessage() : '加载失败，请稍后重试';
      if (showLoading) {
        this.errorMessage = message;
        this.loadState = LoadState.ERROR;
      } else {
        Toast.show('刷新失败：' + message);
      }
      Logger.error('主页数据加载失败：' + (error as Error).message);
    }
  }

  /** 下拉刷新入口；结束后把 refreshing 复位，Refresh 的转圈才会收起。 */
  private async refresh(): Promise<void> {
    // 互斥：不干净的手势（快速滑动收尾时）可能连续触发两次 onRefreshing，
    // 第二次直接忽略，否则同一秒内会对上游打两轮完全相同的请求（真机实测出现过）。
    if (this.refreshInFlight) {
      return;
    }
    this.refreshInFlight = true;
    try {
      await this.loadHome(false, true);
      // 下拉刷新是「全部重来」：签到状态同样要重读，否则课上签过的课可能还显示按钮
      await this.loadSigninState();
      await this.loadTomorrow(true);
    } finally {
      this.refreshInFlight = false;
      this.refreshing = false;
    }
  }

  /**
   * 取当前学期编码。
   *
   * 🔴 **必须「上游 selected 优先、记忆兜底」**，与课表页 `SchedulePage` 的选学期规则一致。
   *
   * 原先写的是「TokenStore 里记过就直接返回」—— 一旦记的是**过期学期**就永远不纠正。
   * 实测后果（2026-11-17）：记忆里是 `2025-2026-2`（上一学年），而实际在读 `2026秋季`，
   * 于是首页预加载到上学期的课表（工科数学分析/理科高等代数/数据结构…），
   * 点「今日课程」按名字匹配全部落空 → 详情退化成「时间 / 地点」两行，
   * 与课表页点开的完整卡片对不上。这就是「两个入口弹出的详情不一致」的真正根因。
   *
   * 缓存一次结果，避免 loadHome / preloadCourses 各拉一遍学期列表。
   */
  private async resolveTermCode(): Promise<string> {
    if (this.termCodeCache.length > 0) {
      return this.termCodeCache;
    }
    const remembered = TokenStore.getSelectedTerm();
    try {
      const terms: Term[] = await ApiService.fetchTerms();
      if (terms.length === 0) {
        return remembered[0];
      }
      let picked: Term | null = null;
      // 1) 上游明确标了「当前学期」的最权威
      for (let i = 0; i < terms.length; i++) {
        if (terms[i].selected) {
          picked = terms[i];
          break;
        }
      }
      // 2) 没有标记时，用记忆里的学期（但要能在列表里找到，防止已下架的老学期）
      if (picked === null && remembered[0].length > 0) {
        for (let i = 0; i < terms.length; i++) {
          if (terms[i].itemCode === remembered[0]) {
            picked = terms[i];
            break;
          }
        }
      }
      // 3) 都没有就取第一个
      if (picked === null) {
        picked = terms[0];
      }
      this.termCodeCache = picked.itemCode;
      TokenStore.setSelectedTerm(picked.itemCode, picked.itemName);
      return picked.itemCode;
    } catch (error) {
      // 断网：退回记忆里的学期，首页至少还能显示（考试/课表可能对不上，但不会白屏）
      Logger.warn('取学期列表失败，用记忆学期兜底：' + (error as Error).message);
      return remembered[0];
    }
  }

  /** 取最近一场未结束的考试。 */
  private pickNextExam(list: Exam[]): void {
    let best: Exam | null = null;
    let bestDays: number = Number.MAX_SAFE_INTEGER;
    for (let i = 0; i < list.length; i++) {
      const item = list[i];
      const dateText = item.examDate !== undefined && item.examDate.length > 0 ?
        item.examDate : (item.examTimeDescription !== undefined ? item.examTimeDescription : '');
      const days = DateUtil.daysUntil(dateText);
      if (days === null || days < 0) {
        continue;
      }
      if (days < bestDays) {
        bestDays = days;
        best = item;
      }
    }
    if (best !== null) {
      this.nextExam = best as Exam;
      this.hasNextExam = true;
    } else {
      this.hasNextExam = false;
    }
  }

  private greeting(): string {
    const hour = new Date().getHours();
    if (hour < 6) {
      return '夜深了';
    }
    if (hour < 11) {
      return '早上好';
    }
    if (hour < 14) {
      return '中午好';
    }
    if (hour < 18) {
      return '下午好';
    }
    return '晚上好';
  }

  /** 打开二级页（分栏已取消，直接硬切压栈）。 */
  private openRoute(route: string): void {
    AppRouter.open(this.stack, route);
  }

  /**
   * 扫一扫：调起系统默认扫码界面，**无需申请相机权限**
   * （Scan Kit 对默认界面扫码做了预授权并处于安全访问状态）。
   *
   * 系统扫码界面本身从屏幕右侧滑入，取消/识别完自动退出 —— 这就是官方转场。
   * 识别到二维码后把地址交给网页二级页，由 `AppRouter.open` 走系统默认的
   * pushPath 动画（同样自右向左滑入），返回时 `AppRouter.back` 自右滑出。
   *
   * 启动耗时的三段打点（看 hilog 搜「扫一扫耗时」）：
   *   t0 点击 → t1 拿到 context → t2 startScanForResult 调用返回（Promise 已发出）。
   * t0→t2 若只有几 ms，说明卡顿在**系统扫码 Ability 冷启动**（相机初始化 +
   * 系统界面加载），这段是官方组件的固有开销，应用层无法消除；若 t0→t2 本身
   * 就是几百 ms，才是我们进程主线程被阻塞，需要另查。
   */
  private scanContext: common.UIAbilityContext | null = null;

  private openScanner(): void {
    const t0: number = Date.now();
    // UIAbilityContext 一次拿到后缓存：不必每次点击都走 getHostContext() 查询链。
    if (this.scanContext === null) {
      this.scanContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    }
    const t1: number = Date.now();
    const options: scanBarcode.ScanOptions = {
      scanTypes: [scanCore.ScanType.ALL],
      enableMultiMode: false,
      enableAlbum: true
    };
    try {
      scanBarcode.startScanForResult(this.scanContext, options)
        .then((result: scanBarcode.ScanResult) => {
          AppStorage.setOrCreate<string>(KEY_SCAN_WEB_URL, result.originalValue);
          AppRouter.open(this.stack, RouteName.SCAN_WEB);
        })
        .catch((error: BusinessError) => {
          // 用户主动取消（1000500002）不打扰；其它错误给一条提示。
          if (error.code !== 1000500002) {
            Toast.show('扫码失败，请重试');
          }
        });
      const t2: number = Date.now();
      Logger.info('扫一扫耗时：点击→context ' + (t1 - t0) + 'ms，context→拉起 ' +
        (t2 - t1) + 'ms，合计 ' + (t2 - t0) + 'ms');
    } catch (error) {
      Logger.warn('启动扫一扫失败：' + (error as Error).message);
      Toast.show('无法启动扫一扫');
    }
  }

  private userName(): string {
    const session = TokenStore.getSession();
    return session.userName.length > 0 ? session.userName : '同学';
  }

  /**
   * 点击今日课程：弹出与课表页**完全一致**的详情。
   *
   * 两条路径都走 `buildCourseDetail`（任课教师 / 时间 / 地点 / 上课周次 / 课程编号 /
   * 课序号 / 课程学分 / 上课节次 + 上游附加行），保证同一个课程在两个入口点开是同一张卡。
   *
   * 数据来自 `preloadedCourses`（进页面就预加载的本周课表）。若预加载还没回来，
   * 这里会 `await` 那次在途请求（见 `ensureCourses`）—— 优先保证**内容完整**，
   * 而不是像以前那样直接退化成两行。只有课表本身取不到时才用
   * `buildSimpleDetail` 兜底（今日课程接口自带的时间 / 地点）。
   */
  private async openTodayDetail(item: TodayClass): Promise<void> {
    const name: string = item.bizName;
    const time: string = item.time === undefined ? '' : item.time;
    const place: string = item.place === undefined ? '' : item.place;

    const courses: CourseClass[] = await this.ensureCourses();
    const match: CourseClass | null =
      findCourseByNameAndTime(courses, name, time, DateUtil.currentWeekday());
    const detail: CourseDetail = match === null ?
      buildSimpleDetail(name, time, place) : buildCourseDetail(match);
    this.courseDetail.apply(detail.title, detail.rows);
    this.showDetail();
  }

  /**
   * 明日课程详情要用的课表。
   *
   * 今天是周日时，明天（周一）已经属于**下一教学周**：`preloadedCourses` 拉的是本周，
   * 单双周交替的课程（如理论力学）本周课表里可能根本没有，详情就只剩「时间 + 地点」
   * 两行 —— 必须按下一周重取。其余日子明天仍在本周，直接复用已预加载的课表。
   * `fetchWeeklySchedule` 自带按「学期 + 周次」的 MemoCache，重复点击不会重复打接口。
   */
  private async coursesForTomorrow(): Promise<CourseClass[]> {
    if (DateUtil.currentWeekday() !== 7) {
      return await this.ensureCourses();
    }
    try {
      const termCode: string = await this.resolveTermCode();
      if (termCode.length === 0) {
        return await this.ensureCourses();
      }
      const thisWeek: number = await this.resolveCurrentWeek(termCode);
      const schedule: WeeklySchedule =
        await ApiService.fetchWeeklySchedule(termCode, thisWeek + 1);
      Logger.info('明日详情用下周课表：' + schedule.arrangedList.length + ' 门（第 ' +
        (thisWeek + 1) + ' 周）');
      return schedule.arrangedList;
    } catch (error) {
      Logger.warn('下周课表拉取失败，退回本周：' + (error as Error).message);
      return await this.ensureCourses();
    }
  }

  /**
   * 明日课程详情：与今日课程同一个弹窗，但按**明天的星期 / 下一周课表**匹配。
   *
   * 用今天 weekday 会匹配到另一天的同名课（教师 / 节次全错）；
   * strict 模式禁掉「仅凭名字取第一条」的兜底，匹配不到就退回「时间 + 地点」两行。
   */
  private async openTomorrowDetail(item: TodayClass): Promise<void> {
    const name: string = item.bizName;
    const time: string = item.time === undefined ? '' : item.time;
    const place: string = item.place === undefined ? '' : item.place;
    const next: Date = DateUtil.addDays(new Date(), 1);
    const weekday: number = next.getDay() === 0 ? 7 : next.getDay();
    const courses: CourseClass[] = await this.coursesForTomorrow();
    const match: CourseClass | null =
      findCourseByNameAndTime(courses, name, time, weekday, true);
    const detail: CourseDetail = match === null ?
      buildSimpleDetail(name, time, place) : buildCourseDetail(match);
    this.courseDetail.apply(detail.title, detail.rows);
    this.showDetail();
  }

  /** 弹出详情弹窗（controller 只建一次，重复打开复用）。 */
  private showDetail(): void {
    if (this.detailController === null) {
      this.detailController = new CustomDialogController({
        builder: CourseDetailDialog({ detail: this.courseDetail }),
        autoCancel: true,
        alignment: DialogAlignment.Center,
        customStyle: true
      });
    }
    if (this.detailController !== null) {
      this.detailController.open();
    }
  }

  /**
   * 是否启用平板两栏版式。
   *
   * 只认 lg / xxl：侧栏形态下内容区宽约 965vp，两栏各 470vp 才够放「今日课程」的行。
   * 平板竖屏（md，673vp）按官方「大屏竖屏」规范仍走底部页签 + 单列，不平分。
   */
  private twoPaneMode(): boolean {
    return isTwoPane(this.bp);
  }

  /**
   * 问候语 + 日期。
   *
   * 单列形态在最顶部；两栏形态在左栏顶部（右栏用一份 Visibility.Hidden 的
   * 等高占位对齐）。两处共用，所以抽成无参 @Builder。
   *
   * 上移量按形态区分：单列时沿用 16vp（见原注释）；两栏时归零，
   * 否则右栏首块会比左栏卡片高出 16vp，两栏顶边对不齐。
   *
   * 扫一扫按钮的位置分形态：单列嵌在问候语行右侧；两栏由 `scanButton()`
   * 独立放到右栏顶部最右侧（见两栏布局处），这里不画。
   */
  @Builder
  greetingBlock() {
    Column({ space: 2 }) {
      Row() {
        Text(this.greeting() + '，' + this.userName())
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.textPrimary)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        // 单列：按钮跟问候语同行最右；两栏：按钮挪到右栏顶部最右（那里叠加）
        if (!this.twoPaneMode()) {
          this.scanButton()
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(DateUtil.today() + ' · ' + DateUtil.weekdayNames()[DateUtil.currentWeekday() - 1])
        .fontSize(14)
        .fontColor(AppColor.textTertiary)
        // 日期相对问候语净下移（纯视觉位移）
        .translate({ y: 3 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .translate({ y: this.twoPaneMode() ? 0 : -16 })
  }

  /**
   * 扫一扫圆按钮，单列 / 两栏两处共用。
   *
   * 沉浸光感：与二级页左上角返回按钮同一套规格（见 HeroDetailLayer）——
   * Stack 里先铺一层 MaterialCardLayer（Toggle 画布挂系统材质），再叠透明 Button。
   * ⚠️ 不能只给 Button 填 circleButtonSurface：那只是「淡一圈的圆」，没有玻璃质感。
   * 承载层带投影在小圆钮上会像「按钮背后顶了一层影子」，故 layerShadow:false。
   * 官方扫一扫图标 sys.symbol.line_viewfinder（四角取景框 + 扫描线），
   * 不用 qrcode —— 那是「二维码方块」，含义是「出示码」而非「去扫」。
   *
   * 尺寸：真机反馈 40vp 偏小、48vp 偏大，折中取直径 44vp、图标 26vp、圆角 22vp
   * （Stack / Button / MaterialCardLayer 三处必须同步，否则材质圆与按钮圆错位）。
   */
  @Builder
  scanButton() {
    Stack() {
      MaterialCardLayer({ layerRadius: 22, layerShadow: false })
      Button() {
        SymbolGlyph($r('sys.symbol.line_viewfinder'))
          .fontSize(26)
          .fontColor([AppColor.textPrimary])
      }
      .type(ButtonType.Normal)
      .width(44)
      .height(44)
      .padding(0)
      .borderRadius(22)
      // 材质在 backgroundColor 之下，按钮自身必须透明，否则把材质盖死
      .backgroundColor(Color.Transparent)
      .accessibilityText('扫一扫')
      .onClick(() => {
        this.openScanner();
      })
    }
    .width(44)
    .height(44)
  }

  @Builder
  examBanner() {
    Column({ space: 4 }) {
      Row() {
        Text(this.nextExam.courseName)
          .fontSize(AppFont.subtitle)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(DateUtil.countdownText(this.examDateText()))
          .fontSize(AppFont.caption)
          .fontColor('#E8F1FF')
      }
      .width('100%')

      Row({ space: 12 }) {
        Text(this.examDateText())
          .fontSize(AppFont.caption)
          .fontColor('#D6E6FF')
        if (this.nextExam.examPlace !== undefined && this.nextExam.examPlace.length > 0) {
          Text(this.nextExam.examPlace)
            .fontSize(AppFont.caption)
            .fontColor('#D6E6FF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .width('100%')
    }
    .width('100%')
    .padding(AppSize.cardPadding)
    .borderRadius(AppSize.cardRadius)
    .linearGradient({
      angle: 135,
      colors: [
        [AppColor.brand, 0.0],
        [AppColor.brandDark, 1.0]
      ]
    })
    .onClick(() => {
      this.openRoute(RouteName.EXAM);
    })
  }

  private examDateText(): string {
    const exam = this.nextExam;
    if (exam.examDate !== undefined && exam.examDate.length > 0) {
      return exam.examDate;
    }
    if (exam.examTimeDescription !== undefined) {
      return exam.examTimeDescription;
    }
    return '时间待定';
  }

  /** 这堂课是否已经上完（结束时间早于当前时刻）。 */
  private isPastClass(item: TodayClass): boolean {
    const end: string = endTimeOf(item);
    return end.length > 0 && end < nowHHmm();
  }

  /* ------------------------------ 签到槽位 ------------------------------ */

  /**
   * 今日课程行 → 对应的签到记录。
   *
   * 两个系统的唯一公共字段是**课程名**（教务 `bizName` / iclass `courseName`），
   * 时间串的粒度还不一样（教务给的是「08:00-08:45」这种分节，iclass 给整段），
   * 所以只能按名字对位；同名的多条优先取「已签到」的那条，否则取第一条。
   * 对不上就返回 null —— 那种行不显示按钮，点了也没法提交。
   */
  private signinTarget(item: TodayClass): SigninClass | null {
    const name: string = item.bizName.trim();
    if (name.length === 0) {
      return null;
    }
    let first: SigninClass | null = null;
    for (let i = 0; i < this.signinClasses.length; i++) {
      const candidate: SigninClass = this.signinClasses[i];
      if (candidate.courseName.trim() !== name) {
        continue;
      }
      if (candidate.signStatus === 1) {
        return candidate;
      }
      if (first === null) {
        first = candidate;
      }
    }
    return first;
  }

  /** 现在时刻的「当天第几分钟」（读 `nowMs`，好让定时器驱动重绘）。 */
  private nowMinuteOfDay(): number {
    const date: Date = new Date(this.nowMs);
    return date.getHours() * 60 + date.getMinutes();
  }

  /** 这门课现在是否落在可签到的窗口里：开课前 15 分钟 ～ 下课。 */
  private signinOpen(item: TodayClass): boolean {
    const begin: number = minutesOf(startTimeOf(item));
    const end: number = minutesOf(endTimeOf(item));
    if (begin < 0 || end < 0) {
      return false;
    }
    const now: number = this.nowMinuteOfDay();
    return now >= begin - SIGNIN_EARLY_MINUTES && now <= end;
  }

  /**
   * 课程图标那一格现在该显示什么。
   *
   * - `signed` ：已签到（窗内签完 / 课后补签都算）→ 绿色对勾
   * - `missed` ：已下课但仍未签到 → 灰底红字「未签」
   * - `open`   ：时间窗内且未签 → 「签到」按钮（尺寸与图标完全一致）
   * - `idle`   ：还没开始，或没拿到签到数据 → 原样显示课程图标
   *
   * 判定顺序有讲究：「已签到」优先于时间 —— 下课之后签到成功的课，用户要看的是
   * 「签上了」而不是「已结束」。
   *
   * 这个字符串同时进 ForEach 的 key —— 状态变了行才会重建，否则跨过 13:45 那一刻
   * 按钮不会自己冒出来。
   */
  private signinSlot(item: TodayClass): string {
    const target: SigninClass | null = this.signinTarget(item);
    if (target === null) {
      return 'idle';
    }
    if (target.signStatus === 1) {
      return 'signed';
    }
    const end: number = minutesOf(endTimeOf(item));
    if (end >= 0 && this.nowMinuteOfDay() > end) {
      return 'missed';
    }
    return this.signinOpen(item) ? 'open' : 'idle';
  }

  /** 这一行是不是正在提交签到（用来把按钮换成转圈）。 */
  private isPendingSignin(item: TodayClass): boolean {
    if (this.signinPendingId.length === 0) {
      return false;
    }
    const target: SigninClass | null = this.signinTarget(item);
    return target !== null && target.courseId === this.signinPendingId;
  }

  /**
   * 从首页直接签到。
   *
   * 与签到页同一条链路（`ApiService.performSignin`），同样是**不可撤销的写操作**，
   * 只由用户点击触发：`signinPendingId` 做互斥，提交期间按钮换成转圈。
   */
  private async doSigninFromHome(item: TodayClass): Promise<void> {
    if (this.signinPendingId.length > 0) {
      return;
    }
    const target: SigninClass | null = this.signinTarget(item);
    if (target === null) {
      Toast.show('没取到这门课的签到信息，请到「课堂签到」页操作');
      return;
    }
    this.signinPendingId = target.courseId;
    try {
      const result = await ApiService.performSignin(target.courseId);
      Toast.show(result.message);
      if (result.success || result.message.indexOf('已经签到') >= 0) {
        this.markSigned(target.courseId);
        // 通知签到页：那边再进来时也重读，不要停在旧状态
        SigninEvents.notifyChanged();
      }
    } catch (error) {
      const message = error instanceof ApiError
        ? (error as ApiError).friendlyMessage() : '签到失败，请稍后重试';
      Toast.show(message);
      Logger.error('首页签到失败：' + (error as Error).message);
    } finally {
      this.signinPendingId = '';
    }
  }

  /**
   * 就地改签到状态位。
   *
   * 整体换一个新数组而不是改元素字段：`@State` 只认引用变化，
   * 原地改 `signStatus` 不会触发重绘（对勾不会出现）。
   */
  private markSigned(courseId: string): void {
    const next: SigninClass[] = [];
    for (let i = 0; i < this.signinClasses.length; i++) {
      const item: SigninClass = this.signinClasses[i];
      next.push({
        courseId: item.courseId,
        courseName: item.courseName,
        classBeginTime: item.classBeginTime,
        classEndTime: item.classEndTime,
        signStatus: item.courseId === courseId ? 1 : item.signStatus
      });
    }
    this.signinClasses = next;
  }

  @Builder
  todayClassItem(item: TodayClass) {
    Row({ space: AppSize.gap }) {
      if (this.signinSlot(item) === 'signed') {
        // 已签到（课上签完 / 课后补签都算）：同一格换成对勾，不再给按钮（重复提交没有意义）
        Row() {
          SymbolGlyph($r('sys.symbol.checkmark_circle'))
            .fontSize(24)
            .fontColor([AppColor.success])
        }
        .width(36)
        .height(36)
        .justifyContent(FlexAlign.Center)
      } else if (this.signinSlot(item) === 'missed') {
        // 已下课还没签到：灰底 + 居中红字，字与「课」同字号（AppFont.caption），
        // 槽位尺寸 / 圆角与课程图标一致，行高不变。
        Row() {
          Text('未签')
            .fontSize(AppFont.caption)
            .fontColor(AppColor.signinMissed)
        }
        .width(36)
        .height(36)
        .borderRadius(10)
        // 「课」图标下课后的那种灰（`text_tertiary` 自带 alpha，明暗两套主题都能用）
        .backgroundColor(AppColor.textTertiary)
        .justifyContent(FlexAlign.Center)
      } else if (this.signinSlot(item) === 'open') {
        // 开课前 15 分钟 ～ 下课：原位换成签到按钮，尺寸 / 圆角与课程图标完全一致，
        // 行高不变，列表不会因为按钮出现而跳动。
        Row() {
          if (this.isPendingSignin(item)) {
            LoadingProgress()
              .width(18)
              .height(18)
              .color(Color.White)
          } else {
            Text('签到')
              .fontSize(AppFont.caption)
              .fontColor(Color.White)
          }
        }
        .width(36)
        .height(36)
        .borderRadius(10)
        .backgroundColor(AppColor.brand)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.doSigninFromHome(item);
        })
      } else {
        Column() {
          Text(item.shortName !== undefined && item.shortName.length > 0 ? item.shortName : '课程')
            .fontSize(AppFont.caption)
            .fontColor(Color.White)
        }
        .width(36)
        .height(36)
        .borderRadius(10)
        // 已上完的课用灰底、未上的用品牌色 —— 扫一眼就知道今天上到哪儿了
        .backgroundColor(this.isPastClass(item) ? AppColor.textTertiary : AppColor.brand)
        .justifyContent(FlexAlign.Center)
      }

      Column({ space: 2 }) {
        Text(item.bizName)
          .fontSize(AppFont.body)
          // 已上完的课程名也压暗一档，与待上的拉开一点点层次
          .fontColor(this.isPastClass(item) ? AppColor.textSecondary : AppColor.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 8 }) {
          if (item.time !== undefined && item.time.length > 0) {
            Text(item.time)
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textTertiary)
          }
          if (item.place !== undefined && item.place.length > 0) {
            // 长地点：限制在块内 + 到达右缘**文字自身渐隐**（不是加一层看得见的遮罩）。
            // 实现：文本裁切（Clip，不出省略号）+ 尾部一条 24vp 的渐变，颜色是
            // **与卡片底色同 RGB、只降 alpha** —— 插值不会产生半透明黑/白，
            // 观感就是字形逐个变淡。文本没顶到边缘时渐变叠在底色上（同色叠同色），完全不可见。
            //
            // 🔴 颜色**从 `app.color.surface` 资源里取**（见 `surfaceArgbHex`），不写死字面量。
            // 2026-11-17 修的 bug：这里原先裸读 `AppStorage('isDarkMode')`，
            // 而写入方用的是 `'isDark'` → 键名不一致，深色下恒定走浅色分支、
            // 拿纯白渐变盖在 `#1A1A1A` 卡片上，糊出一块白斑。
            // 现在改为订阅 `this.isDark`（`@StorageProp`），切主题会重绘。
            //
            // ⚠️ 渐变条必须用**固定高度**：写 '100%' 会在自动高度的 Stack 里解析成
            // 整卡高度，把卡片撑爆（踩过）。
            Stack({ alignContent: Alignment.End }) {
              Text(item.place)
                .fontSize(AppFont.caption)
                .fontColor(AppColor.textTertiary)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Clip })
                .width('100%')
              Row()
                .width(24)
                .height(18)
                .linearGradient({
                  angle: 90,
                  colors: [
                    [transparentOf(surfaceArgbHex(this.isDark)), 0],
                    [surfaceArgbHex(this.isDark), 1]
                  ]
                })
                .hitTestBehavior(HitTestMode.None)
            }
            .layoutWeight(1)
          }
        }
        .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 点击提示：能弹出详情
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([AppColor.textTertiary])
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.openTodayDetail(item);
    })
  }

  /** 明日课程标题右侧的日期文案，如「11-23 周一」。 */
  private tomorrowDateText(): string {
    const next: Date = DateUtil.addDays(new Date(), 1);
    const day: number = next.getDay() === 0 ? 7 : next.getDay();
    return (next.getMonth() + 1).toString() + '-' + next.getDate().toString() + ' ' +
      DateUtil.weekdayNames()[day - 1];
  }

  /**
   * 明日课程行：**不复用** `todayClassItem`。
   *
   * 那个 builder 会按课程名去 iclass 找签到记录 —— 明天的同名课会错拿到今天的
   * 「已签到 / 未签」。这里不显示签到槽位；详情点击走 `openTomorrowDetail()`
   * （按明天的 weekday 匹配，并关掉跨天兜底）。
   */
  @Builder
  tomorrowClassItem(item: TodayClass) {
    Row({ space: AppSize.gap }) {
      Column() {
        Text(item.shortName !== undefined && item.shortName.length > 0 ? item.shortName : '课程')
          .fontSize(AppFont.caption)
          .fontColor(Color.White)
      }
      .width(36)
      .height(36)
      .borderRadius(10)
      .backgroundColor(AppColor.brand)
      .justifyContent(FlexAlign.Center)

      Column({ space: 2 }) {
        Text(item.bizName)
          .fontSize(AppFont.body)
          .fontColor(AppColor.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 8 }) {
          if (item.time !== undefined && item.time.length > 0) {
            Text(item.time)
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textTertiary)
          }
          if (item.place !== undefined && item.place.length > 0) {
            Text(item.place)
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textTertiary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
        }
        .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 与今日课程行一致的箭头，提示这行也能点开详情
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([AppColor.textTertiary])
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.openTomorrowDetail(item);
    })
  }

  /** 明日课程子区：只在「今天没课」或「今天全部上完」时出现。 */
  @Builder
  tomorrowBlock() {
    Column({ space: AppSize.gapSmall }) {
      Divider().color(AppColor.divider).strokeWidth(0.5)

      Row() {
        Text('明日课程')
          .fontSize(AppFont.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
        Blank()
        Text(this.tomorrowDateText())
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textTertiary)
      }
      .width('100%')

      if (this.tomorrowClasses.length === 0) {
        Text('明天没有课程安排')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textTertiary)
          .width('100%')
          .padding({ top: 4, bottom: 4 })
      } else {
        Column() {
          ForEach(this.tomorrowClasses, (item: TodayClass, index: number) => {
            this.tomorrowClassItem(item)
            if (index < this.tomorrowClasses.length - 1) {
              Divider().color(AppColor.divider).strokeWidth(0.5)
            }
          }, (item: TodayClass, index: number) =>
            // 与今日课程分开命名，避免同名课在两处撞 key；时间也要进 key（调课会变）
            'tomorrow|' + item.bizName + '|' + (item.time === undefined ? '' : item.time) +
              '|' + index.toString())
        }
        .width('100%')
      }
    }
    .width('100%')
  }

  /**
   * 今日课程块（手机 / 平板共用）。
   *
   * 三态互斥：
   * - 今日无课 → 空态 + 明日课程；
   * - 今日全部上完 → 「今日课程已完成」，今日列表不再显示 + 明日课程；
   * - 其余（有课且未上完）→ 只显示今日课程，**不出现**明日课程。
   */
  @Builder
  todaySection() {
    SectionCard({
      title: '今日课程',
      // 状态提示只在卡内写一次：无课 / 已完成时副标题留空，
      // 否则会出现「今天没有课」+「今天没有课程安排」这类重复（完成态同理）。
      subtitle: (this.todayClasses.length === 0 || this.todayFinished)
        ? '' : this.todayClasses.length.toString() + ' 节课',
      showAction: false
    }) {
      if (this.todayClasses.length === 0) {
        // 轻量空态：今天没课时这张卡下面还要接明日课程，用通用 EmptyView
        // （44vp 图标 + 上下各 60vp）会把明日课程顶到一屏之外。
        Text('今天没有课程安排')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textTertiary)
          .width('100%')
          .padding({ top: 2, bottom: 2 })
        this.tomorrowBlock()
      } else if (this.todayFinished) {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.checkmark_circle'))
            .fontSize(20)
            .fontColor([AppColor.success])
          Text('今日课程已完成')
            .fontSize(AppFont.body)
            .fontColor(AppColor.success)
        }
        .width('100%')
        .padding({ top: 4, bottom: 4 })
        this.tomorrowBlock()
      } else {
        Column() {
          ForEach(this.todayClasses, (item: TodayClass, index: number) => {
            this.todayClassItem(item)
            if (index < this.todayClasses.length - 1) {
              Divider().color(AppColor.divider).strokeWidth(0.5)
            }
          }, (item: TodayClass, index: number) =>
            // key 必须反映数据身份，不能用 index：下拉刷新（不切 LOADING）时数组整体
            // 被替换，若 key 全是 "0"/"1"/"2"，ArkUI 会认为节点没变而**不重跑 itemGenerator**
            // —— 卡片标题写着「3 节课」，下面三行还是刷新前的旧课（调课/换教室后看得到）。
            item.bizName + '|' + (item.time === undefined ? '' : item.time) +
              '|' + (item.place === undefined ? '' : item.place) + '|' + index.toString() +
              // 签到槽位也是身份的一部分：跨过「开课前 15 分钟」或签完之后，
              // key 变了这一行才会重建，图标/按钮/对勾才能自己切换。
              '|' + this.signinSlot(item))
        }
        .width('100%')
      }
    }
  }


  /**
   * 「最近使用」的功能入口（本地记录的真实使用轨迹，最多 4 个）。
   *
   * 容器与「今日课程」「待办」统一走 `SectionCard`（同一套标题排版 / 卡片底色 /
   * 圆角 / 内边距），三块在页面上是同一个视觉层级，不再是「一张卡片 + 两段裸文字」。
   */
  @Builder
  recentSection() {
    SectionCard({
      title: '最近使用',
      showAction: false
    }) {
      if (this.recentItems().length === 0) {
        EmptyView({ message: '用过的功能会出现在这里' })
      } else {
        Row({ space: RECENT_ITEM_SPACE }) {
          ForEach(this.recentItems(), (item: FeatureItem) => {
            Column({ space: 6 }) {
              Stack({ alignContent: Alignment.Center }) {
                // 与功能页磁贴同源：浅=调浓后的同色系淡实色、深=暗调预混实色
                Column()
                  .width(44)
                  .height(44)
                  .borderRadius(14)
                  .backgroundColor(ScheduleColors.forFeatureTile(item.slot, this.isDark))
                if (item.colorful === true) {
                  Image(item.icon)
                    .width(22)
                    .height(22)
                } else if (item.bitmapIcon === true) {
                  // PNG 位图：fillColor 无效，走与功能页磁贴同款的 colorFilter
                  Image(item.icon)
                    .width(22)
                    .height(22)
                    .colorFilter(ScheduleColors.iconTintFilter(item.slot, this.isDark))
                } else {
                  // SVG 矢量：fillColor 染色，浅=同色系彩图标、深=块色混白
                  Image(item.icon)
                    .width(22)
                    .height(22)
                    .fillColor(ScheduleColors.textForSlot(item.slot, this.isDark))
                }
              }
              .width(44)
              .height(44)

              Text(item.title)
                .fontSize(AppFont.caption)
                .fontColor(AppColor.textSecondary)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                // 均分后每格宽度随设备变化：标题必须吃满格宽并居中，否则长名字会溢出
                .width('100%')
                .textAlign(TextAlign.Center)
            }
            // 等宽铺满卡片内宽（Row 里 layoutWeight 有效；Flex 里无效）
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Center)
            .onClick(() => {
              AppRouter.open(this.stack, item.route);
            })
          }, (item: FeatureItem) => 'recent-' + item.route)
        }
        .width('100%')
        .onAreaChange((_old: Area, now: Area) => {
          // 只在个数变化时写状态：滚动 / 高度变化也会回调，每次写会让入口反复重排
          const next: number = columnsByMinWidth(Number(now.width), RECENT_ITEM_MIN_WIDTH,
            RECENT_ITEM_SPACE, RECENT_MIN_COLUMNS, RECENT_MAX_COLUMNS);
          if (next !== this.recentColumns) {
            this.recentColumns = next;
          }
        })
      }
    }
  }

  /**
   * 最近使用的功能项，个数 = `recentColumns`（由卡片内宽自适应）。
   *
   * 1. 真实使用轨迹优先（按 route 反查注册表，查不到的跳过 —— 不留空壳入口）；
   * 2. 前 4 个按原版 `home.dart` 的顺序用常用功能补齐，位置保持稳定；
   * 3. 平板更宽时继续按注册表顺序补足，避免一排只占半幅。
   */
  private recentItems(): FeatureItem[] {
    const all: FeatureItem[] = allFeatures();
    const out: FeatureItem[] = [];
    const used = new Set<string>();
    const limit: number = this.recentColumns;
    for (let i = 0; i < this.recentRoutes.length && out.length < limit; i++) {
      const route: string = this.recentRoutes[i];
      for (let j = 0; j < all.length; j++) {
        if (all[j].route === route && !used.has(route)) {
          used.add(route);
          out.push(all[j]);
          break;
        }
      }
    }
    // 补齐顺序与原版一致：课表在我们这里是一个页签，所以从博雅开始
    const fallback: string[] = [RouteName.BYKC, RouteName.CLASSROOM,
      RouteName.GRADE, RouteName.EXAM];
    for (let i = 0; i < fallback.length && out.length < limit; i++) {
      const route: string = fallback[i];
      if (used.has(route)) {
        continue;
      }
      for (let j = 0; j < all.length; j++) {
        if (all[j].route === route) {
          used.add(route);
          out.push(all[j]);
          break;
        }
      }
    }
    // 宽屏要放 6~8 个：前四个补齐项用完后，按注册表顺序继续填满整行
    for (let j = 0; j < all.length && out.length < limit; j++) {
      if (!used.has(all[j].route)) {
        used.add(all[j].route);
        out.push(all[j]);
      }
    }
    return out;
  }


  /**
   * 待办：未提交且未过期的作业。
   *
   * 只取最近 3 条（再多就成清单了），按截止时间升序。
   * 加载失败静默 —— 待办是增值信息，不该因为拉不到而打扰首页。
   */
  private async loadTodos(): Promise<void> {
    try {
      const data = await ApiService.fetchSpocAssignments();
      const now: string = DateUtil.today();
      const out: SpocAssignment[] = [];
      for (let i = 0; i < data.assignments.length; i++) {
        const item = data.assignments[i];
        if (item.submitted === true) {
          continue;
        }
        const due: string = item.dueTime === undefined ? '' : item.dueTime;
        if (due.length === 0) {
          continue;
        }
        // 已过期的不进待办（过期未交在 SPOC 页里看）
        if (due.substring(0, 10) < now) {
          continue;
        }
        out.push(item);
      }
      out.sort((a: SpocAssignment, b: SpocAssignment): number => {
        const left: string = a.dueTime === undefined ? '' : a.dueTime;
        const right: string = b.dueTime === undefined ? '' : b.dueTime;
        return left < right ? -1 : (left > right ? 1 : 0);
      });
      this.todos = out.slice(0, 3);
      this.persistCache();
    } catch (error) {
      // 待办拉不到不影响首页，静默
    }
  }

  /**
   * 待办区块：作业截止（考试倒计时在上方的 examBanner，不重复）。
   *
   * 与「今日课程」「最近使用」共用 `SectionCard` 容器与「标题 + 副标题 + 列表 +
   * 行间分隔线」的同一套结构，位置在「最近使用」下方。
   */
  @Builder
  todoSection() {
    SectionCard({
      title: '待办',
      subtitle: this.todos.length > 0 ?
        this.todos.length.toString() + ' 项待完成' : '暂无待办',
      showAction: false
    }) {
      if (this.todos.length === 0) {
        EmptyView({ message: '没有临近截止的作业' })
      } else {
        Column({ space: 0 }) {
          ForEach(this.todos, (item: SpocAssignment, index: number) => {
            Row({ space: AppSize.gap }) {
              Column({ space: 2 }) {
                Text(item.title)
                  .fontSize(AppFont.body)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(AppColor.textPrimary)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                Text(item.courseName + ' · 截止 ' + (item.dueTime === undefined ? '' : item.dueTime))
                  .fontSize(AppFont.caption)
                  .fontColor(AppColor.textTertiary)
                  .maxLines(1)
                  .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(14)
                .fontColor([AppColor.textTertiary])
            }
            .width('100%')
            .padding({ top: 10, bottom: 10 })
            .onClick(() => {
              AppRouter.open(this.stack, RouteName.SPOC);
            })
            if (index < this.todos.length - 1) {
              Divider().color(AppColor.divider).strokeWidth(0.5)
            }
          }, (item: SpocAssignment, index: number) =>
            item.assignmentId.length > 0 ? item.assignmentId : 'todo-' + index.toString())
        }
        .width('100%')
      }
    }
  }

  build() {
    // 下拉刷新外壳：Refresh 包 Scroll，内容停在顶部时继续下拉即触发。
    // 注意：顶部模糊依赖「clip(false)+expandSafeArea()」这套扩展，Refresh 作为
    // 新的最外层容器也要开（见下方 .clip(false)/.expandSafeArea()），否则会避让
    // 标题栏组件安全区、把模糊顶没了。
    Refresh({ refreshing: $$this.refreshing }) {
      Scroll() {
        Column({ space: AppSize.gapLarge }) {
          if (this.twoPaneMode()) {
            /**
             * 平板横屏（lg / xxl）：两栏仪表盘。
             *
             * 左栏 = 概览与入口（问候 + 日期 / 最近使用 / 待办）；
             * 右栏 = 时间敏感信息（考试倒计时 / 今日课程 + 明日课程）。
             * 加载 / 错误态收在右栏 —— 那是「今日课程」的位置，
             * 左栏的问候语与最近使用是本地数据，不随网络状态闪动。
             */
            Row({ space: AppSize.gapLarge }) {
              Column({ space: AppSize.gapLarge }) {
                this.greetingBlock()
                if (this.loadState === LoadState.SUCCESS) {
                  if (this.recentItems().length > 0) {
                    this.recentSection()
                  }
                  this.todoSection()
                }
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Column({ space: AppSize.gapLarge }) {
                /**
                 * 与左栏问候语等高的隐藏占位，使右栏第一块与左栏「最近使用」齐顶。
                 *
                 * 用 Visibility.Hidden 复用同一份 greetingBlock()（仍参与布局、只是不画），
                 * 而不是写死一个 paddingTop —— 问候语字号 / 行数 / 系统字体放大后
                 * 两边会一起变，永远对齐。两栏形态下问候语的 translate(y) 为 0，
                 * 所以占位高度与左栏可见的那份完全一致。
                 *
                 * 扫一扫按钮按用户要求挪到右栏：叠在这块占位的右上角（问候语同行、
                 * 右栏最右侧）。Stack 用同一份占位撑高，按钮自身不占布局高度，
                 * 因此右栏第一块仍与左栏齐顶，按钮又正好落在问候语那一行。
                 */
                Stack({ alignContent: Alignment.TopEnd }) {
                  Column() {
                    this.greetingBlock()
                  }
                  .visibility(Visibility.Hidden)
                  .hitTestBehavior(HitTestMode.None)

                  this.scanButton()
                }
                .width('100%')

                if (this.loadState === LoadState.LOADING) {
                  LoadingView({ message: '正在获取校园数据…' })
                } else if (this.loadState === LoadState.ERROR) {
                  ErrorView({
                    message: this.errorMessage,
                    onRetry: () => {
                      this.loadHome(true, true);
                    }
                  })
                } else {
                  if (this.hasNextExam) {
                    this.examBanner()
                  }
                  this.todaySection()
                }
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
          } else {
            // 问候语（单列形态在页面最顶部）
            this.greetingBlock()

            if (this.loadState === LoadState.LOADING) {
              LoadingView({ message: '正在获取校园数据…' })
            } else if (this.loadState === LoadState.ERROR) {
              ErrorView({
                message: this.errorMessage,
                onRetry: () => {
                  this.loadHome(true, true);
                }
              })
            } else {
              if (this.hasNextExam) {
                this.examBanner()
              }

              // 今日课程（快捷入口已移除：功能集中在功能页，主页只留「今天要上什么课」）
              this.todaySection()

              // 「最近使用」快捷入口（本地记录的真实使用轨迹）
              if (this.recentItems().length > 0) {
                this.recentSection()
              }

              // 待办（作业截止）—— 放在「最近使用」下方
              this.todoSection()
            }
          }

          // 为悬浮底栏预留高度（barOverlap 模式下内容会被底栏覆盖）
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
      }
      .scrollBar(BarState.Off)
      // 顶/底拖到边界时回弹（内容不足一屏也生效）
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      // 沉浸光感「三件套」之二 / 之三（配合 titleBar 的 enableComponentSafeArea）：
      //   clip(false)      —— 允许内容画到自身布局矩形之外；
      //   expandSafeArea() —— 绘制区延伸进标题栏声明的组件安全区。
      // 缺了这两个，内容永远停在标题栏下沿（首屏位置是对的，但上滑时内容不会从
      // 标题栏底下钻进去），标题栏的渐变模糊「没东西可糊」。官方文档明确要求。
      .clip(false)
      .expandSafeArea()
      .width('100%')
      .height('100%')
      // 顶部留白不写在 Scroll 上 —— ArkUI 会把 Scroll 的 padding 当 contentInset，
      // 把滚动内容整体上移（实测反而顶到时钟上）；留白写在滚动内容的内边距里。
      .backgroundColor(AppColor.pageBackground)
    }
    // Refresh 也必须补「沉浸光感三件套」：它现在是最外层容器，若不开
    // clip(false)+expandSafeArea()，会默认避开 HDS 标题栏声明的组件安全区，
    // 把主页内容整体往下压、顶部渐变模糊失去可糊的内容（这是加下拉刷新后
    // 模糊丢失的直接原因）。
    .clip(false)
    .expandSafeArea()
    // 刷新态转圈位置：refreshOffset 越大转圈越靠上。按反馈微调。
    .refreshOffset(65)
    .onRefreshing(() => {
      this.refresh();
    })
    .width('100%')
    .height('100%')
  }
}
