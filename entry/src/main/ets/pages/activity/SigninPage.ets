import { LoadState } from '../../common/AppRouter';
import { DateUtil } from '../../common/DateUtil';
import { Logger } from '../../common/Logger';
import { SigninEvents } from '../../common/SigninEvents';
import { Toast } from '../../common/Toast';
import { ApiError } from '../../network/ApiError';
import { ApiService } from '../../network/ApiService';
import { AppColor, AppFont, AppMaterial, AppSize } from '../../components/AppTheme';
import { MaterialCardLayer } from '../../components/MaterialCardLayer';
import { immersiveMaterialActive } from '../../common/SystemMaterial';
import { topSafeInsetVp } from '../../common/ImmersiveUtil';
import { EmptyView, ErrorView, LoadingView } from '../../components/CommonViews';
import { SigninQrSheet } from '../../components/SigninQrSheet';
import { isTwoPane, KEY_BREAKPOINT } from '../../common/Breakpoint';
import { SigninClass } from '../../model/ApiTypes';
import { PageCache } from '../../common/PageCache';
import { OfflineKey } from '../../common/OfflineCache';
import { PullToRefresh } from '../../components/PullToRefresh';

/** 签到课堂首帧缓存内容。pendingCourseId / 二维码浮层等交互态不缓存。 */
interface SigninCache {
  classes: SigninClass[];
}

/**
 * 课堂签到（iclass 一体化课堂）。
 *
 * 数据来自校内上游：登录后用 SSO 跳转链换一次 iclass 会话，再取「今日课堂 +
 * 签到状态」。签到提交是不可撤销的真实动作，只由用户点击触发，不自动补签。
 *
 * 交互刻意做得「一屏一件事」：列表本身就是操作面板，未签到的课右侧直接给按钮，
 * 已签到的显示状态，不额外套一层详情页 —— 上课前那几十秒不该用来点三次。
 */

/**
 * 允许提前多久点签到。
 *
 * 签到窗口由**教师**开启，不是课表说了算，所以不能只按上课时间卡死；但完全放开
 * 就变成「点了必失败」。真机实测（2026-11-19 13:05 点 14:00 的课）上游回的是
 * `ERRCODE=101 / 签到失败！` —— 客户端的代价是一次白跑的写请求 + 一句看不懂的报错。
 * 留 10 分钟余量（产品口径）：盖住教师提前开窗的常见情况，又不至于提前太久空点。
 */
const SIGNIN_EARLY_MS: number = 10 * 60 * 1000;

/** 一门课「现在能不能点」的结论（只用于展示，不改变上游语义）。 */
enum SigninPhase {
  /** 时间窗内（含提前量）：给按钮。 */
  OPEN,
  /** 还没到上课时间：灰态「未开始」。 */
  UPCOMING,
  /** 已经下课：灰态「已结束」。 */
  ENDED
}

@Component
export struct SigninPage {
  @State private loadState: LoadState = LoadState.LOADING;
  @State private errorMessage: string = '';
  @State private classes: SigninClass[] = [];
  /** 正在提交签到的课程 id；空串表示当前没有进行中的签到。 */
  @State private pendingCourseId: string = '';
  /**
   * 「现在」的毫秒值，每 30 秒刷一次。
   *
   * 页面常在课间一直开着，跨过 14:00 那一刻按钮得自己从「未开始」变成「签到」，
   * 否则用户点刷新之前都以为没到时间。定时器在 `aboutToDisappear` 里清掉。
   */
  @State private nowMs: number = Date.now();
  private tickTimer: number = -1;

  /** 顶部「刷新」按钮：静止只显示「刷新」二字，刷新中只显示系统 LoadingProgress 转圈，并互斥重复点击。 */
  @State private refreshing: boolean = false;

  /**
   * 两栏（lg / xxl）下右侧签到区当前盯着的课。
   *
   * 空串 = 还没选。左列表点击只改这个值，不弹浮层 —— 扫码时要能同时看到
   * 其它课的时间和签到状态，浮层会把它们盖住。
   */
  @State private activeCourseId: string = '';
  /** 手机单列「查看签到码」弹窗的控制器（弹窗不在渲染树里，必须持有引用）。 */
  private qrController: CustomDialogController | null = null;
  @StorageProp(KEY_BREAKPOINT) private bp: string = 'sm';

  aboutToAppear(): void {
    this.load();
    this.tickTimer = setInterval(() => {
      this.nowMs = Date.now();
    }, 30000);
  }

  aboutToDisappear(): void {
    if (this.tickTimer >= 0) {
      clearInterval(this.tickTimer);
      this.tickTimer = -1;
    }
  }

  private async load(): Promise<void> {
    // 冷启动首帧：先同步读上次缓存，命中就直接进 SUCCESS（后台继续拉新覆盖）。
    // 签到状态强时效，TTL 取短，避免显示过期的「已签到 / 未签到」。
    const cached: SigninCache | null = PageCache.load<SigninCache>(
      OfflineKey.SIGNIN, PageCache.TTL_SHORT);
    if (cached !== null && cached.classes.length > 0) {
      this.classes = cached.classes;
      this.loadState = LoadState.SUCCESS;
      // 恢复内容后右栏照常选中一门课（两栏模式下首帧就有目标）
      this.pickActiveCourse();
    }
    if (this.loadState !== LoadState.SUCCESS) {
      this.loadState = LoadState.LOADING;
    }
    try {
      this.classes = await ApiService.fetchSigninClasses();
      this.loadState = LoadState.SUCCESS;
      this.pickActiveCourse();
      PageCache.save(OfflineKey.SIGNIN, { classes: this.classes } as SigninCache);
    } catch (error) {
      this.errorMessage = error instanceof ApiError
        ? (error as ApiError).friendlyMessage() : '签到课堂加载失败';
      // 缓存命中过时失败不切 ERROR，保留已渲染的本地内容
      if (this.loadState !== LoadState.SUCCESS) {
        this.loadState = LoadState.ERROR;
      }
      Logger.error('签到课堂加载失败：' + (error as Error).message);
    }
  }

  /**
   * 顶部「刷新」按钮：静止只显示「刷新」二字；刷新中只显示系统转圈（LoadingProgress），完成后立即恢复文字。
   *
   * 用 `refreshing` 互斥：转圈期间重复点击不生效，避免叠加多次 load。
   * `load()` 内部已 catch 全部异常，finally 保证转圈一定停下。
   */
  private async refresh(): Promise<void> {
    if (this.refreshing) {
      return;
    }
    this.refreshing = true;
    try {
      await this.load();
    } finally {
      this.refreshing = false;
    }
  }

  /**
   * 提交一次签到。
   *
   * 用 `pendingCourseId` 做互斥：签到本身有网络往返，期间再次点击会重复提交，
   * 而上游对重复提交只会回「已签到」，界面看着像成功、实际白跑一趟。
   */
  private async doSignin(item: SigninClass): Promise<void> {
    if (this.pendingCourseId.length > 0) {
      return;
    }
    this.pendingCourseId = item.courseId;
    try {
      const result = await ApiService.performSignin(item.courseId);
      Toast.show(result.message);
      // 成功要回读状态；「已经签到」「结果未知」这两种失败也可能意味着上游状态已经变了
      // （同学代签、上次其实写进去了），刷新一次才能画出真实状态。
      if (result.success || result.message.indexOf('已经签到') >= 0 ||
        result.message.indexOf('结果未知') >= 0) {
        await this.load();
      }
      if (result.success) {
        // 告诉首页：那边「今日课程」里的签到按钮该换成对勾了
        SigninEvents.notifyChanged();
      }
    } catch (error) {
      const message = error instanceof ApiError
        ? (error as ApiError).friendlyMessage() : '签到失败，请稍后重试';
      Toast.show(message);
      Logger.error('签到失败：' + (error as Error).message);
    } finally {
      this.pendingCourseId = '';
    }
  }

  /* ---------------------------- 签到二维码 ---------------------------- */

  /**
   * 二维码面板的「已签到」探测。
   *
   * 面板开着的时候对面可能已经扫完了，不轮询就只能让用户自己退出去看。
   * 这里直接复用今日课堂的在线查询（与 `load()` 同一个接口），按排课 id 匹配。
   */
  private async isSigned(courseId: string): Promise<boolean> {
    const classes: SigninClass[] = await ApiService.fetchSigninClasses();
    for (let i = 0; i < classes.length; i++) {
      if (classes[i].courseId === courseId) {
        return classes[i].signStatus === 1;
      }
    }
    return false;
  }

  private timeRange(item: SigninClass): string {
    if (item.classBeginTime.length === 0 && item.classEndTime.length === 0) {
      return '上课时间待定';
    }
    if (item.classEndTime.length === 0) {
      return item.classBeginTime;
    }
    return item.classBeginTime + ' - ' + item.classEndTime;
  }

  /** `2026-11-19 14:00:00` → `14:00`（提示语里只用到时分）。 */
  private shortTime(text: string): string {
    const blank: number = text.indexOf(' ');
    const clock: string = blank >= 0 ? text.substring(blank + 1) : text;
    return clock.length >= 5 ? clock.substring(0, 5) : clock;
  }

  /**
   * 这门课现在处于什么阶段。
   *
   * 上游只回 `STATUS=1 / ERRCODE=101 / 签到失败！`，看不出是「没开窗」还是「下课了」，
   * 所以把课表时间当**展示**依据：时间外不给按钮，避免一次注定失败的写入。
   * 时间解析不出来（上游没给时间）时一律放开 —— 宁可让用户点一次，也别凭空拦死。
   */
  private phase(item: SigninClass): SigninPhase {
    const begin: Date | null = DateUtil.parseDateTime(item.classBeginTime);
    const end: Date | null = DateUtil.parseDateTime(item.classEndTime);
    if (begin !== null && this.nowMs < begin.getTime() - SIGNIN_EARLY_MS) {
      return SigninPhase.UPCOMING;
    }
    if (end !== null && this.nowMs > end.getTime()) {
      return SigninPhase.ENDED;
    }
    return SigninPhase.OPEN;
  }

  private signedCount(): number {
    let count = 0;
    for (let i = 0; i < this.classes.length; i++) {
      if (this.classes[i].signStatus === 1) {
        count++;
      }
    }
    return count;
  }

  /* ---------------------------- 两栏（lg / xxl） ---------------------------- */

  private twoPaneMode(): boolean {
    return isTwoPane(this.bp);
  }

  /**
   * 选一门课作为右栏的目标。
   *
   * 优先「还没签到的第一门」（这正是用户打开这个页面的原因）；全都签完了
   * 就退回第一门，右栏显示它的已签到状态。已经选中的课仍在列表里就保持不动 ——
   * 刷新（`load`）不应把用户正在看的课换掉。
   */
  private pickActiveCourse(): void {
    for (let i = 0; i < this.classes.length; i++) {
      if (this.classes[i].courseId === this.activeCourseId) {
        return;
      }
    }
    let first: string = '';
    let firstUnsigned: string = '';
    for (let i = 0; i < this.classes.length; i++) {
      const id: string = this.classes[i].courseId;
      if (first.length === 0) {
        first = id;
      }
      if (firstUnsigned.length === 0 && this.classes[i].signStatus !== 1) {
        firstUnsigned = id;
      }
    }
    this.activeCourseId = firstUnsigned.length > 0 ? firstUnsigned : first;
  }

  /**
   * 右栏当前目标课的字段。
   *
   * 全部做成「返回基础类型的方法」而不是先取对象再读属性：`@Builder` 里不能声明
   * 局部变量，多次 `this.activeXxx()` 是这套限制下最干净的写法（数据量只有几门课）。
   */
  private activeFound(): boolean {
    for (let i = 0; i < this.classes.length; i++) {
      if (this.classes[i].courseId === this.activeCourseId) {
        return true;
      }
    }
    return false;
  }

  private activeName(): string {
    for (let i = 0; i < this.classes.length; i++) {
      if (this.classes[i].courseId === this.activeCourseId) {
        return this.classes[i].courseName;
      }
    }
    return '';
  }

  private activeTimeText(): string {
    for (let i = 0; i < this.classes.length; i++) {
      if (this.classes[i].courseId === this.activeCourseId) {
        return this.timeRange(this.classes[i]);
      }
    }
    return '';
  }

  private activeSigned(): boolean {
    for (let i = 0; i < this.classes.length; i++) {
      if (this.classes[i].courseId === this.activeCourseId) {
        return this.classes[i].signStatus === 1;
      }
    }
    return false;
  }

  private activePhase(): SigninPhase {
    for (let i = 0; i < this.classes.length; i++) {
      if (this.classes[i].courseId === this.activeCourseId) {
        return this.phase(this.classes[i]);
      }
    }
    return SigninPhase.ENDED;
  }

  /** 签到码弹窗的状态提示：与 `phase()` 同一套时间窗判据，避免按钮和文案打架。 */
  private qrStatusHint(now: SigninPhase): string {
    if (now === SigninPhase.UPCOMING) {
      return '签到未开始，无法扫码签到';
    }
    if (now === SigninPhase.ENDED) {
      return '课堂已结束，无法扫码签到';
    }
    return '可扫码签到';
  }

  /** 只有时间窗内（OPEN）的提示用绿色，未开始 / 已结束用次要灰。 */
  private qrStatusPositive(now: SigninPhase): boolean {
    return now === SigninPhase.OPEN;
  }

  @Builder
  summaryBar() {
    Row() {
      Column({ space: 2 }) {
        Text('今天 · ' + DateUtil.today())
          .fontSize(AppFont.subtitle)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
        Text(this.classes.length === 0
          ? '暂无可签到的课堂'
          : '共 ' + this.classes.length + ' 堂 · 已签 ' + this.signedCount() + ' 堂')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textSecondary)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 单一内容槽 + 固定宽高：静止态只显示「刷新」两字，加载态只显示系统转圈。
      // 两态共用同一个居中的 Stack，容器尺寸恒定 —— 点击前后按钮形状不变。
      Row() {
        Stack() {
          if (this.refreshing) {
            LoadingProgress()
              .width(16)
              .height(16)
              .color(AppColor.brand)
          } else {
            Text('刷新')
              .fontSize(AppFont.caption)
              .fontColor(AppColor.brand)
          }
        }
        .width(32)
        .height(16)
      }
      .padding({ left: 14, right: 14, top: 6, bottom: 6 })
      .backgroundColor(AppColor.brandContainer)
      .borderRadius(999)
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.refresh();
      })
    }
    .width('100%')
    .padding(AppSize.cardPadding)
    .borderRadius(AppSize.cardRadius)
    .backgroundColor(AppColor.surface)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  classCard(item: SigninClass) {
    Column({ space: 10 }) {
      Row({ space: AppSize.gap }) {
        Column({ space: 4 }) {
          Text(item.courseName)
            .fontSize(AppFont.body)
            .fontWeight(FontWeight.Medium)
            .fontColor(AppColor.textPrimary)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(this.timeRange(item))
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textTertiary)
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (item.signStatus === 1) {
          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.checkmark_circle'))
              .fontSize(14)
              .fontColor([AppColor.success])
            Text('已签到')
              .fontSize(AppFont.caption)
              .fontColor(AppColor.success)
          }
        } else if (this.pendingCourseId === item.courseId) {
          // 提交中：占位尺寸与按钮接近，避免列表在结果回来时跳一下
          Row() {
            LoadingProgress()
              .width(18)
              .height(18)
              .color(AppColor.brand)
          }
          .width(64)
          .height(32)
          .justifyContent(FlexAlign.Center)
        } else if (this.twoPaneMode()) {
          // 两栏：卡片只做「选了哪门」的入口，写操作全部收到右栏，
          // 避免左列表和右栏各有一个签到按钮（点错的那个是不可撤销的写请求）。
          this.phaseLabelChip(item)
        } else if (this.phase(item) === SigninPhase.UPCOMING) {
          this.phaseChip(item, '未开始')
        } else if (this.phase(item) === SigninPhase.ENDED) {
          this.phaseChip(item, '已结束')
        } else {
          Text('签到')
            .fontSize(AppFont.caption)
            .fontColor(Color.White)
            .textAlign(TextAlign.Center)
            .width(64)
            .padding({ top: 8, bottom: 8 })
            .backgroundColor(AppColor.brand)
            .borderRadius(999)
            .onClick(() => {
              this.doSignin(item);
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 手机单列：点按钮弹窗看码（弹窗样式与课表课程详情一致），不再每卡常驻。
      // 两栏下左栏不放：右栏 signinPane 已常驻当前选中课的码，避免重复。
      if (!this.twoPaneMode()) {
        Row() {
          Text('查看签到码')
            .fontSize(AppFont.body)
            .fontColor(AppColor.brand)
        }
        .width('100%')
        .height(40)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(AppColor.brandContainer)
        .borderRadius(20)
        .onClick(() => {
          this.openQrDialog(item);
        })
      }
    }
    .width('100%')
    .padding(AppSize.cardPadding)
    .borderRadius(AppSize.cardRadius)
    .backgroundColor(AppColor.surface)
    .alignItems(HorizontalAlign.Start)
    // 两栏下点卡片 = 把右栏切到这门课；选中态用一圈品牌色描边标出来。
    // 单列下不拦截点击，行为与改造前完全一致。
    // ⚠️ border 宽度参与布局：0 ↔ 1.5 切换会把卡片内容挤进 1.5vp，肉眼可见位移。
    // 宽度恒定 1.5vp、只切颜色（未选中透明），两态几何完全一致、内容不跳动。
    .border({
      width: 1.5,
      color: this.twoPaneMode() && this.activeCourseId === item.courseId
        ? AppColor.brand : Color.Transparent
    })
    .onClick(() => {
      if (this.twoPaneMode()) {
        this.activeCourseId = item.courseId;
      }
    })
  }

  /** 两栏左列表里的只读阶段标签（未开始 / 已结束 / 待签到）。 */
  @Builder
  phaseLabelChip(item: SigninClass) {
    Text(this.phaseLabel(item))
      .fontSize(AppFont.caption)
      .fontColor(this.phase(item) === SigninPhase.OPEN ? AppColor.brand : AppColor.textTertiary)
      .textAlign(TextAlign.Center)
      .width(64)
      .padding({ top: 8, bottom: 8 })
      .backgroundColor(this.phase(item) === SigninPhase.OPEN ?
        AppColor.brandContainer : AppColor.surfaceSubtle)
      .borderRadius(999)
  }

  private phaseLabel(item: SigninClass): string {
    const now: SigninPhase = this.phase(item);
    if (now === SigninPhase.UPCOMING) {
      return '未开始';
    }
    if (now === SigninPhase.ENDED) {
      return '已结束';
    }
    return '待签到';
  }

  /**
   * 时间窗外的只读标签。
   *
   * 不做成禁用按钮（灰按钮看着像「能用但坏了」），也不直接隐藏（课还在列表里，
   * 得能看出为什么不能签）。点了先重判一次时间，窗口内就直接签，否则给一句解释。
   */
  @Builder
  phaseChip(item: SigninClass, label: string) {
    Text(label)
      .fontSize(AppFont.caption)
      .fontColor(AppColor.textTertiary)
      .textAlign(TextAlign.Center)
      .width(64)
      .padding({ top: 8, bottom: 8 })
      .backgroundColor(AppColor.surfaceSubtle)
      .borderRadius(999)
      .onClick(() => {
        this.onPhaseChipTap(item);
      })
  }

  /**
   * 点「未开始 / 已结束」时的兜底判定。
   *
   * 关键在**先重新取一次当前时间**：定时器 30 秒一刷，ForEach 的 key 也依赖它，
   * 真到 14:00 那一刻界面未必已经跟上。这里再判一次，用户就不会因为「还显示未开始」
   * 而卡住；判到窗口内就直接走正常签到。
   */
  private onPhaseChipTap(item: SigninClass): void {
    this.nowMs = Date.now();
    const now: SigninPhase = this.phase(item);
    if (now === SigninPhase.OPEN) {
      this.doSignin(item);
      return;
    }
    Toast.show(now === SigninPhase.UPCOMING
      ? '这门课 ' + this.shortTime(item.classBeginTime) + ' 开始，教师开启签到后再点'
      : '这门课已经下课，本次签到不再受理');
  }

  /** 左栏 / 单列共用的课程列表（汇总条 + 状态 + 卡片 + 免责说明）。 */
  @Builder
  classList() {
    this.summaryBar()

    if (this.loadState === LoadState.LOADING) {
      LoadingView({ message: '正在获取今日课堂…' })
    } else if (this.loadState === LoadState.ERROR) {
      ErrorView({
        message: this.errorMessage,
        onRetry: () => {
          this.load();
        }
      })
    } else if (this.classes.length === 0) {
      EmptyView({ message: '今天没有需要签到的课堂' })
    } else {
      // key 里带 `phase`：定时器把「现在」推过上下课边界时，键变了才会重建卡片。
      // 只用 courseId + signStatus 的话，跨过 14:00 按钮会一直停在「未开始」。
      // 两栏下还要带**选中态**：`ForEach` 的 itemGenerator 只在键集合变化时重跑，
      // 键不变时列表项里读 `activeCourseId` 的描边不会跟着换（老坑）。
      ForEach(this.classes, (item: SigninClass) => {
        this.classCard(item);
      }, (item: SigninClass) => item.courseId + '-' + item.signStatus + '-' + this.phase(item) +
        '-' + (this.activeCourseId === item.courseId ? 'on' : 'off'))
    }

    Text('签到由任课教师开启窗口后有效；点击「签到」即向课堂系统提交，无法撤销。' +
      '课表时间之外（未开始 / 已结束）不再给按钮，避免一次注定被拒的提交；' +
      '若时间窗内仍提示被拒，请确认已连接校园网或已切到 WebVPN 模式。')
      .fontSize(AppFont.caption)
      .fontColor(AppColor.textTertiary)
      .width('100%')
      .padding({ left: 4, right: 4 })
  }

  /** 右栏：当前选中课堂的签到区（信息 + 签到动作 + 常驻二维码）。 */
  @Builder
  signinPane() {
    if (!this.activeFound()) {
      Column({ space: 6 }) {
        Text('选择左侧的课堂')
          .fontSize(AppFont.body)
          .fontColor(AppColor.textSecondary)
        Text('右侧会显示这堂课的签到按钮与签到码')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textTertiary)
      }
      .width('100%')
      .padding(AppSize.cardPadding + 8)
      .borderRadius(AppSize.cardRadius)
      .backgroundColor(AppColor.surface)
      .alignItems(HorizontalAlign.Start)
    } else {
      // 课程信息 + 状态
      Column({ space: 6 }) {
        Row({ space: 8 }) {
          Text(this.activeName())
            .fontSize(AppFont.subtitle)
            .fontWeight(FontWeight.Medium)
            .fontColor(AppColor.textPrimary)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)

          if (this.activeSigned()) {
            Row({ space: 4 }) {
              SymbolGlyph($r('sys.symbol.checkmark_circle'))
                .fontSize(14)
                .fontColor([AppColor.success])
              Text('已签到')
                .fontSize(AppFont.caption)
                .fontColor(AppColor.success)
            }
          } else {
            Text(this.activePhaseLabel())
              .fontSize(AppFont.caption)
              .fontColor(this.activePhase() === SigninPhase.OPEN ?
                Color.White : AppColor.textTertiary)
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .borderRadius(999)
              .backgroundColor(this.activePhase() === SigninPhase.OPEN ?
                AppColor.brand : AppColor.surfaceSubtle)
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)

        Text(this.activeTimeText())
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textTertiary)
          .width('100%')
      }
      .width('100%')
      .padding(AppSize.cardPadding)
      .borderRadius(AppSize.cardRadius)
      .backgroundColor(AppColor.surface)
      .alignItems(HorizontalAlign.Start)

      // 签到动作：不可撤销的写请求，只在「未签到 + 时间窗内」出现
      if (!this.activeSigned() && this.activePhase() === SigninPhase.OPEN) {
        Button() {
          if (this.pendingCourseId === this.activeCourseId) {
            LoadingProgress()
              .width(20)
              .height(20)
              .color(Color.White)
          } else {
            Text('签到')
              .fontSize(AppFont.subtitle)
              .fontColor(Color.White)
          }
        }
        .width('100%')
        .height(48)
        .borderRadius(24)
        .backgroundColor(AppColor.brand)
        .enabled(this.pendingCourseId.length === 0)
        .onClick(() => {
          this.doSigninActive();
        })
      }

      // 常驻签到码：无论是否已签到都显示（用户要「一直显示」）。
      // 换课时由 @Watch 复位并重取（见 SigninQrSheet.onCourseChanged）。
      SigninQrSheet({
        courseId: this.activeCourseId,
        courseName: this.activeName(),
        embedded: true,
        initialSigned: this.activeSigned(),
        statusHint: this.qrStatusHint(this.activePhase()),
        statusPositive: this.qrStatusPositive(this.activePhase()),
        onCheckSigned: (): Promise<boolean> => this.isSigned(this.activeCourseId)
      })
    }
  }

  private activePhaseLabel(): string {
    const now: SigninPhase = this.activePhase();
    if (now === SigninPhase.UPCOMING) {
      return '未开始';
    }
    if (now === SigninPhase.ENDED) {
      return '已结束';
    }
    return '待签到';
  }

  /** 对右栏当前选中的课提交签到（与卡片上的按钮同一条链路）。 */
  private async doSigninActive(): Promise<void> {
    for (let i = 0; i < this.classes.length; i++) {
      if (this.classes[i].courseId === this.activeCourseId) {
        await this.doSignin(this.classes[i]);
        return;
      }
    }
  }

  /** 手机单列：点「查看签到码」弹出与课程详情同款的弹窗。 */
  private openQrDialog(item: SigninClass): void {
    const now: SigninPhase = this.phase(item);
    this.qrController = new CustomDialogController({
      builder: SigninQrDialog({
        courseId: item.courseId,
        courseName: item.courseName,
        initialSigned: item.signStatus === 1,
        statusHint: this.qrStatusHint(now),
        statusPositive: this.qrStatusPositive(now),
        onCheckSigned: (): Promise<boolean> => this.isSigned(item.courseId)
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      customStyle: true
    });
    if (this.qrController !== null) {
      this.qrController.open();
    }
  }

  /** 原页面内容。下拉刷新由外层 `build()` 的 PullToRefresh 提供。 */
  @Builder
  pageContent() {
    Scroll() {
      Column({ space: AppSize.gap }) {
        if (this.twoPaneMode()) {
          /**
           * 平板横屏（lg / xxl）：左课程列表 + 右签到区。
           *
           * 右栏常驻签到码，扫码时左栏的其它课（时间和状态）仍然看得见 ——
           * 这正是浮层方案做不到的：浮层一开，整页只剩一张码。
           */
          Row({ space: AppSize.gapLarge }) {
            Column({ space: AppSize.gap }) {
              this.classList()
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Column({ space: AppSize.gap }) {
              this.signinPane()
            }
            .layoutWeight(1)
            // 三块（信息卡 / 签到按钮 / 签到码）都吃满右栏，等宽且左对齐。
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        } else {
          // 单列：与改造前逐字一致
          this.classList()
        }

        Blank()
          .height(AppSize.gapLarge)
      }
      .width('100%')
      .padding({
        left: AppSize.pagePadding,
        right: AppSize.pagePadding,
        // 顶部让开「状态栏 + 悬浮标题栏（MINI，56vp）」。留白必须写在滚动内容里、
        // 而不是外壳上：视口仍从屏幕顶开始，内容才能滑进标题栏那一段毛玻璃底板。
        top: AppSize.destTopInset(topSafeInsetVp()),
        // 底部为悬浮底栏留白，同样留在滚动内容里（见 RouteBuilder 的说明）。
        bottom: AppSize.contentBottomInset
      })
      .constraintSize({ minHeight: '100%' })
    }
    .scrollBar(BarState.Off)
    // 顶/底拖到边界时回弹（内容不足一屏也生效）
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    // 沉浸光感「三件套」之二 / 之三（配合 titleBar 的 enableComponentSafeArea）：
    // clip(false) 允许内容画到布局矩形之外，expandSafeArea() 让绘制区延伸进
    // 标题栏声明的组件安全区 —— 缺了它们标题栏的渐变模糊就没东西可糊。
    .clip(false)
    .expandSafeArea()
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.pageBackground)
  }

  build() {
    PullToRefresh({
      // 复用页面已有的 refresh()：它自己带防重入，不会划一次触发两遍请求。
      onRefresh: () => this.refresh(),
      contentBuilder: () => {
        this.pageContent();
      }
    })
  }
}

/**
 * 手机单列「查看签到码」弹窗。
 *
 * 外壳与课表页 `CourseDetailDialog` 完全同款：86% 宽 / maxWidth 400 /
 * cardRadiusLarge / cardPadding+4 / MaterialCardLayer（不可用时玻璃兜底），
 * 内部直接放 SigninQrSheet（bare 模式，不重复画卡片底）。
 */
@CustomDialog
struct SigninQrDialog {
  controller?: CustomDialogController;
  courseId: string = '';
  courseName: string = '';
  initialSigned: boolean = false;
  statusHint: string = '';
  statusPositive: boolean = false;
  onCheckSigned: () => Promise<boolean> = async (): Promise<boolean> => false;

  private readonly materialActive: boolean = immersiveMaterialActive();

  build() {
    if (this.materialActive) {
      this.immersiveCard();
    } else {
      this.glassCard();
    }
  }

  @Builder
  cardContent() {
    Column() {
      SigninQrSheet({
        courseId: this.courseId,
        courseName: this.courseName,
        embedded: true,
        bare: true,
        materialActive: this.materialActive,
        initialSigned: this.initialSigned,
        statusHint: this.statusHint,
        statusPositive: this.statusPositive,
        onCheckSigned: this.onCheckSigned
      })

      Stack() {
        if (this.materialActive) {
          MaterialCardLayer({ layerRadius: 22, layerShadow: false })
        }
        Button('关闭')
          .width('100%')
          .height(44)
          .borderRadius(22)
          .fontSize(AppFont.subtitle)
          .fontColor(AppColor.textOnBrand)
          .backgroundColor(this.materialActive ? AppColor.brandGlass : AppColor.brand)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
      }
      .width('100%')
      .height(44)
      .margin({ top: 16 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  immersiveCard() {
    Stack() {
      MaterialCardLayer({ layerRadius: AppSize.cardRadiusLarge })
      Column() {
        this.cardContent()
      }
      .width('100%')
      .padding(AppSize.cardPadding + 4)
      .alignItems(HorizontalAlign.Start)
    }
    .width('86%')
    .constraintSize({ maxWidth: 400 })
    .borderRadius(AppSize.cardRadiusLarge)
    .backgroundColor(Color.Transparent)
  }

  @Builder
  glassCard() {
    Column() {
      this.cardContent()
    }
    .width('86%')
    .constraintSize({ maxWidth: 400 })
    .padding(AppSize.cardPadding + 4)
    .backdropBlur(AppMaterial.blurLarge)
    .backgroundColor(AppColor.glassSurface)
    .border({ width: 0.5, color: AppColor.divider })
    .borderRadius(AppSize.cardRadiusLarge)
    .alignItems(HorizontalAlign.Start)
  }
}
