import { AppRouter, LoadState, RouteName } from '../../common/AppRouter';
import { DateUtil } from '../../common/DateUtil';
import { Logger } from '../../common/Logger';
import { Toast } from '../../common/Toast';
import { ApiError } from '../../network/ApiError';
import { ApiService } from '../../network/ApiService';
import { TokenStore } from '../../network/TokenStore';
import { AppColor, AppFont, AppMotion, AppSize } from '../../components/AppTheme';
import { topSafeInsetVp } from '../../common/ImmersiveUtil';
import {
  EmptyView,
  ErrorView,
  FeatureTile,
  LoadingView,
  SectionCard
} from '../../components/CommonViews';
import { FeatureItem, quickFeatures } from '../../components/FeatureRegistry';
import {
  buildCourseDetail,
  buildSimpleDetail,
  CourseDetail,
  CourseDetailDialog
} from '../../components/CourseDetailDialog';
import { CourseClass, Exam, Term, TodayClass, Week, WeeklySchedule } from '../../model/ApiTypes';
import {
  KEY_BREAKPOINT,
  fitColumnsToItems,
  templateOfColumns,
  tileColumnsTemplate
} from '../../common/Breakpoint';

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

/**
 * 在课表里按课程名找课。
 *
 * 先精确匹配；不一致时退化为「包含」匹配 —— 今日课程接口有时用简称，
 * 与课表里的全称不完全一致。
 */
function findCourseByName(list: CourseClass[], name: string): CourseClass | null {
  for (let i = 0; i < list.length; i++) {
    if (list[i].courseName === name) {
      return list[i];
    }
  }
  for (let i = 0; i < list.length; i++) {
    const candidate: string = list[i].courseName;
    if (candidate.length > 0 && (candidate.indexOf(name) >= 0 || name.indexOf(candidate) >= 0)) {
      return list[i];
    }
  }
  return null;
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
  /** 当前是否分栏（由 MainPage 传入）：分栏时点条目是替换右栏而不是压栈。 */
  @Prop splitMode: boolean = false;
  /** 点条目前的回调。返回 true = 外层会立刻切双列，此时延后一帧再 push，详情才从右侧滑入。 */
  onWillOpen: () => boolean = () => false;

  /** 当前宽度断点：决定磁贴列数与是否双列并排。 */
  @StorageProp(KEY_BREAKPOINT) private bp: string = 'sm';
  /**
   * 按自身宽度量出来的布局参数（只在**变化**时写状态）。
   *
   * 分栏切换时宽度是动画过渡的，onAreaChange 会连续回调几十次；若用宽度驱动重建，
   * 卡片会在动画里持续重排。这里只缓存「够不够双列」和「单格 84vp 能放几列」，
   * 动画期间只有跨边界时重建一次。
   */
  @State private wideEnough: boolean = false;
  /**
   * 内容区当前可用宽度（vp），**每帧都更新**。
   *
   * 之前缓存的是"列数"（只在跨列边界时才写），结果分栏动画的中间帧里：
   * 卡片宽度已经跟着面板变了，列数还停在上一档 → 磁贴被挤到重叠（录屏里那几帧）。
   * 现在列数由宽度现场算，宽度和列数永远同源，不会再对不上。
   */
  @State private laneWidth: number = 0;
  /**
   * 「快捷入口」卡片**自身**的实测宽度（vp）。
   *
   * 必须量卡片自己、不能借用外层面板的宽度：分栏收放是原生动画，容器的宽度回调会比
   * 子节点的百分比重排早一帧，用外层宽度算列数就会出现"卡片还窄、列数已经按宽卡片算"
   * 的错位 —— 表现为磁贴被裁成半个（关闭分栏时最明显）。
   */
  @State private quickCardWidth: number = 0;
  /** 两块区域的像素布局（都挂在同一个 .animation() 上补间）。 */
  @State private blockLane: number = 0;
  @State private todayHeightVp: number = 0;
  @State private quickHeightVp: number = 0;
  /** 是否已经量过自身宽度（false 时按窗口断点兜底）。非 @State：只做分支判断。 */
  private measured: boolean = false;

  /** 两块实测高度与内容区可用宽度（vp）：算位移初值用，非 @State（不参与渲染）。 */

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

  /** 各功能入口的使用次数；快捷入口按它排序（见 quickFeatures）。 */
  @State private featureUsage: Record<string, number> = {};

  aboutToAppear(): void {
    this.featureUsage = TokenStore.getFeatureUsage();
    this.loadHome(true);
    // 后台预加载本周课表（不阻塞首页渲染）—— 点课程时才有完整的详情可用
    this.preloadCourses();
  }

  /**
   * 预加载本周课表（与课表页取的是同一份数据）。
   *
   * 失败不影响首页（只是点开课程时退化成「时间 / 地点」两行），所以这里只记日志。
   */
  private async preloadCourses(): Promise<void> {
    if (this.preloadDone) {
      return;
    }
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
      Logger.warn('首页预加载课表失败：' + (error as Error).message);
    }
  }

  /**
   * 当前教学周。
   *
   * **必须用「当前教学周」而不是「用户记住的周次」优先**：课表页会把用户翻看的周次记下来
   * （比如翻到第 10 周），若按它取，今天的课自然找不到。
   */
  private async resolveCurrentWeek(termCode: string): Promise<number> {
    const weeks: Week[] = await ApiService.fetchWeeks(termCode);
    for (let i = 0; i < weeks.length; i++) {
      if (weeks[i].curWeek) {
        return weeks[i].serialNumber;
      }
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
      const classes: TodayClass[] = await ApiService.fetchTodayClasses();
      // 接口返回的顺序是乱的，按开始时间重排（早的在上）
      this.todayClasses = sortTodayClasses(classes);

      // 首次登录时还没有缓存学期，此时不能直接跳过考试 —— 否则首页会缺掉倒计时卡片
      const termCode: string = await this.resolveTermCode();
      if (termCode.length > 0) {
        const data = await ApiService.fetchExams(termCode);
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

  /** 取当前学期编码：优先用已缓存的，没有就拉一次学期列表并记住。 */
  private async resolveTermCode(): Promise<string> {
    const remembered = TokenStore.getSelectedTerm();
    if (remembered[0].length > 0) {
      return remembered[0];
    }
    const terms: Term[] = await ApiService.fetchTerms();
    if (terms.length === 0) {
      return '';
    }
    let picked: Term = terms[0];
    for (let i = 0; i < terms.length; i++) {
      if (terms[i].selected) {
        picked = terms[i];
        break;
      }
    }
    TokenStore.setSelectedTerm(picked.itemCode, picked.itemName);
    return picked.itemCode;
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

  private userName(): string {
    const session = TokenStore.getSession();
    return session.userName.length > 0 ? session.userName : '同学';
  }

  private openFeature(item: FeatureItem): void {
    if (item.route.length === 0) {
      Toast.show(item.title + ' · 敬请期待');
      return;
    }
    // 记一次使用：快捷入口按使用次数排序，回来时顺序已经是新的
    TokenStore.recordFeatureUse(item.title);
    this.featureUsage = TokenStore.getFeatureUsage();
    this.openRoute(item.route);
  }

  /**
   * 打开二级页。
   *
   * 未分栏且外层能分栏时，先让外层切到 Split、**下一帧**再 push ——
   * 详情才是「分栏里的内容从右侧滑入」，而不是模式切换动画里的「自左向右展开」。
   */
  private openRoute(route: string): void {
    if (this.splitMode || !this.onWillOpen()) {
      AppRouter.open(this.stack, route, this.splitMode);
      return;
    }
    AppRouter.openAfterLayout(this.stack, route, this.splitMode);
  }

  /**
   * 点击今日课程：**同步组装、直接弹出完整详情**。
   *
   * 完整详情来自 `preloadedCourses`（进页面就预加载好的本周课表），所以这里没有任何
   * 异步等待 —— 与课表页点课程块的行为完全一致。只有预加载还没回来（或失败）时，
   * 才退化成「时间 / 地点」两行，不会出现加载态。
   */
  private openTodayDetail(item: TodayClass): void {
    const name: string = item.bizName;
    const time: string = item.time === undefined ? '' : item.time;
    const place: string = item.place === undefined ? '' : item.place;

    const match: CourseClass | null = findCourseByName(this.preloadedCourses, name);
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
            Text(item.place)
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textTertiary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
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

  /**
   * 是否双列并排。
   *
   * 判据是本页**实测宽度**而不是窗口断点：分栏时本页会活在 320~400vp 的列表栏里，
   * 窗口断点仍报 lg，按断点走双列会把两栏各压到 160vp（真机上文字全成省略号、
   * 右侧还空一片）。720vp 以下一律单列，正好是「两栏各 340vp」的下限。
   */
  private twoColumnLayout(): boolean {
    if (!this.measured) {
      return this.bp === 'lg' || this.bp === 'xxl';
    }
    return this.wideEnough;
  }

  /** 快捷入口的列数：单格不小于 84vp；并排时按半栏算。列数由当前宽度现场推导。 */
  private quickColumnsTemplate(): string {
    const items: number = quickFeatures(this.featureUsage).length;
    if (!this.measured || this.laneWidth <= 0) {
      return this.twoColumnLayout() ? '1fr 1fr 1fr 1fr' : tileColumnsTemplate(this.bp);
    }
    // 卡片自身宽度已含 SectionCard 的 16vp 内边距 ×2，直接扣掉
    const cardWidth: number = this.quickCardWidth - 32;
    let columns: number = Math.floor(cardWidth / 84);
    if (columns < 2) {
      columns = 2;
    }
    if (columns > 8) {
      columns = 8;
    }
    return templateOfColumns(fitColumnsToItems(columns, items, 2));
  }

  /** 单块宽度：并排各占一半（扣 16vp 间距），堆叠整宽。 */
  private blockWidth(): number {
    const gap: number = AppSize.gapLarge;
    return this.wideEnough ? (this.blockLane - gap) / 2 : this.blockLane;
  }

  /** 「快捷入口」左边缘：并排接在「今日课程」右侧 + 间距，堆叠为 0。 */
  private quickBlockX(): number {
    return this.wideEnough ? (this.blockLane + AppSize.gapLarge) / 2 : 0;
  }

  /** 「快捷入口」上边缘：并排与「今日课程」齐平，堆叠落到其下方 + 间距。 */
  private quickBlockY(): number {
    return this.wideEnough ? 0 : this.todayHeightVp + AppSize.gapLarge;
  }

  /**
   * 堆叠形态下，Stack 自适应高度（= 较高者）与真实需要（h1 + gap + h2）的差额。
   *
   * Stack 里第二块是绝对定位，不撑高父容器，所以差额用外层一个 Blank 补上；
   * 并排时不需要补（两块等高对齐）。
   */
  private blocksExtraHeight(): number {
    if (this.wideEnough || this.blockLane <= 0) {
      return 0;
    }
    return Math.min(this.todayHeightVp, this.quickHeightVp) + AppSize.gapLarge;
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
          }, (item: TodayClass, index: number) => index.toString())
        }
        .width('100%')
      }
    }
  }

  @Builder
  quickSection() {
    SectionCard({ title: '快捷入口', subtitle: '按最近使用排序' }) {
      Grid() {
        ForEach(quickFeatures(this.featureUsage), (item: FeatureItem) => {
          GridItem() {
            FeatureTile({
              title: item.title,
              icon: item.icon,
              color: item.color,
              onTileClick: () => {
                this.openFeature(item);
              }
            })
          }
        }, (item: FeatureItem) => item.title)
      }
      .columnsTemplate(this.quickColumnsTemplate())
      .columnsGap(AppSize.gapSmall)
      .rowsGap(AppSize.gap)
      .width('100%')
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

            // 「今日课程 | 快捷入口」：用**绝对定位 + 像素尺寸**自己排两块。
            //
            // 为什么不用 Flex/Row 收放：分栏收放是 HDS 的原生动画，动画期间页面拿不到
            // 逐帧宽度、子节点也不会逐帧重排 —— 交给换行布局，底板就会"先出现在中间、
            // 再跳到目标位"（关闭分栏时最明显）。
            // 这里把宽度/位置/容器高全部算成像素，挂在同一个 `.animation()` 上：
            // 数值属性可以插值，底板与内容就会连续地"从左边展开成并排"，不依赖面板重排。
            Stack({ alignContent: Alignment.TopStart }) {
              Column() {
                this.todaySection()
              }
              .width(this.blockWidth())
              .alignItems(HorizontalAlign.Start)
              .onAreaChange((oldArea: Area, newArea: Area) => {
                const raw: Length = newArea.height;
                const measured: number = typeof raw === 'number' ? raw : parseFloat(raw.toString());
                if (Math.abs(measured - this.todayHeightVp) > 0.5) {
                  this.todayHeightVp = measured;
                }
              })

              Column() {
                this.quickSection()
              }
              .width(this.blockWidth())
              .alignItems(HorizontalAlign.Start)
              // 用 margin 而不是 translate：translate 只改绘制位置、**布局盒留在原处**，
              // 命中区域跟着布局盒走 → 磁贴画在下面却点不到（真机踩过，竖屏完全点不动）。
              // margin 是布局属性：命中区域、滚动范围、动画补间三者都对得上。
              .margin({ left: this.quickBlockX(), top: this.quickBlockY() })
              .onAreaChange((oldArea: Area, newArea: Area) => {
                const rawW: Length = newArea.width;
                const w: number = typeof rawW === 'number' ? rawW : parseFloat(rawW.toString());
                if (Math.abs(w - this.quickCardWidth) > 0.5) {
                  this.quickCardWidth = w;
                }
                const rawH: Length = newArea.height;
                const h: number = typeof rawH === 'number' ? rawH : parseFloat(rawH.toString());
                if (Math.abs(h - this.quickHeightVp) > 0.5) {
                  this.quickHeightVp = h;
                }
              })
            }
            .width('100%')
            // 高度必须自适应（取较高那块），不能由状态反推 —— 否则"高度依赖子节点测量、
            // 子节点又依赖高度"会死锁成 0 高（实测整页只剩一个图标）。
            // 堆叠时第二块在下方，超出的那部分尺寸由下面的 Blank 补。

            // 堆叠时补足"两块高度之和 + 间距"与 Stack 自适应高度之间的差额
            Blank()
              .width('100%')
              .height(this.blocksExtraHeight())
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
        // 量自身可用宽度，换算成两个量化值：够不够双列、快捷入口放几列。
        // 只在量化值变化时写状态，避免分栏动画期间反复重排。
        .onAreaChange((oldArea: Area, newArea: Area) => {
          const raw: Length = newArea.width;
          const total: number = typeof raw === 'number' ? raw : parseFloat(raw.toString());
          const usable: number = total - AppSize.pagePadding * 2;
          this.measured = true;
          const wide: boolean = usable >= 720;
          // 必须用**显式 animateTo**：这段状态变化发生在布局回调（onAreaChange）里，
          // 隐式 `.animation()` 对"布局过程中触发的属性变更"不生效（实测 1200ms 也是瞬切）。
          if (wide !== this.wideEnough) {
            this.getUIContext().animateTo({ duration: AppMotion.SPLIT_DURATION, curve: Curve.Friction }, () => {
              this.wideEnough = wide;
              this.blockLane = usable;
            });
            return;
          }
          // 列数不再缓存，交给 quickColumnsTemplate() 用它现算，保证与宽度同源
          if (Math.abs(usable - this.laneWidth) > 0.5) {
            this.laneWidth = usable;
          }
          // 像素布局的基准宽度：两块几何全部由它算，配合 .animation() 连续补间
          if (Math.abs(usable - this.blockLane) > 0.5) {
            this.blockLane = usable;
          }
        })
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
