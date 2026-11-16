import { AppRouter, LoadState, RouteName } from '../../common/AppRouter';
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
import {
  buildCourseDetail,
  buildSimpleDetail,
  CourseDetail,
  CourseDetailDialog
} from '../../components/CourseDetailDialog';
import { CourseClass, Exam, Term, TodayClass, Week, WeeklySchedule } from '../../model/ApiTypes';
import { KEY_BREAKPOINT } from '../../common/Breakpoint';

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
  weekday: number): CourseClass | null {
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
  // ④ 跨天兜底
  if (hasTime) {
    for (let i = 0; i < sameName.length; i++) {
      if (courseTimeOf(sameName[i]) === time) {
        return sameName[i];
      }
    }
  }
  return sameName.length > 0 ? sameName[0] : null;
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
  @State private errorMessage: string = '';
  @State private todayClasses: TodayClass[] = [];
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


  aboutToAppear(): void {
    this.loadHome(true);
    // 后台预加载本周课表（不阻塞首页渲染）—— 点课程时才有完整的详情可用
    this.preloadCourses();
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
   */
  private async loadHome(showLoading: boolean): Promise<void> {
    if (showLoading) {
      this.loadState = LoadState.LOADING;
    }
    try {
      const classes: TodayClass[] = await ApiService.fetchTodayClasses(!showLoading);
      // 接口返回的顺序是乱的，按开始时间重排（早的在上）
      this.todayClasses = sortTodayClasses(classes);

      // 首次登录时还没有缓存学期，此时不能直接跳过考试 —— 否则首页会缺掉倒计时卡片
      const termCode: string = await this.resolveTermCode();
      if (termCode.length > 0) {
        const data = await ApiService.fetchExams(termCode, !showLoading);
        this.pickNextExam(data.arranged);
      }
      this.loadState = LoadState.SUCCESS;
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
      await this.loadHome(false);
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

  @Builder
  todayClassItem(item: TodayClass) {
    Row({ space: AppSize.gap }) {
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

  @Builder
  todaySection() {
    SectionCard({
      title: '今日课程',
      subtitle: this.todayClasses.length > 0 ?
        this.todayClasses.length.toString() + ' 节课' : '今天没有课',
      showAction: false
    }) {
      if (this.todayClasses.length === 0) {
        EmptyView({ message: '今天没有课程安排' })
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
              '|' + (item.place === undefined ? '' : item.place) + '|' + index.toString())
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
          // 问候语
          Column({ space: 2 }) {
            Text(this.greeting() + '，' + this.userName())
              .fontSize(26)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppColor.textPrimary)
            Text(DateUtil.today() + ' · ' + DateUtil.weekdayNames()[DateUtil.currentWeekday() - 1])
              .fontSize(14)
              .fontColor(AppColor.textTertiary)
              // 日期相对问候语净下移（纯视觉位移）
              .translate({ y: 3 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          // 主页只上移「问候语 + 日期」两行（16vp，比其余页的整体上移 8vp 多一倍），
          // 卡片等其余内容保持原位不动。
          .translate({ y: -16 })

          if (this.loadState === LoadState.LOADING) {
            LoadingView({ message: '正在获取校园数据…' })
          } else if (this.loadState === LoadState.ERROR) {
            ErrorView({
              message: this.errorMessage,
              onRetry: () => {
                this.loadHome(true);
              }
            })
          } else {
            if (this.hasNextExam) {
              this.examBanner()
            }

            // 今日课程（快捷入口已移除：功能集中在功能页，主页只留「今天要上什么课」）
            this.todaySection()
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
