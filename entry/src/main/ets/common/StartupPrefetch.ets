import { ApiService } from '../network/ApiService';
import { LocalPortalService } from '../network/LocalPortalService';
import { TokenStore } from '../network/TokenStore';
import { ExamArrangementData, PortalMetric, PortalMetrics, Term, Week } from '../model/ApiTypes';
import { CardDataBuilder } from './CardDataBuilder';
import { Logger } from './Logger';

/**
 * 启动预取：**首帧之后**按优先级把最常用的几份数据拉进 `MemoCache`。
 *
 * ## 为什么必须是「首帧之后」
 *
 * 冷启动的耗时口径是「点击图标 → 首帧上屏」。在首帧前发请求不会让首帧更早出现，
 * 反而会和首屏渲染抢主线程与网络（还要额外做一次状态写入）。
 * 所以这里刻意延迟到首帧稳定后（{@link DELAY_MS}），且全部步骤都是**异步、可中断**的。
 *
 * ## 与「启动/切后台快照」的关系（关键取舍）
 *
 * 系统在应用启动时显示 startWindow（图标 + 背景色），冷启动动画结束的瞬间会换成应用首帧；
 * 从后台恢复时则先显示**上一帧的快照**。两处都会放大「首帧与真实内容不一致」的问题：
 *
 * 1. **预取不能改首帧的结构**：这里只写缓存，不碰任何 `@State` / `AppStorage`。
 *    首帧长什么样由本地缓存与骨架决定，预取结果由各页面在自己的加载流程里消费。
 * 2. **不能让首帧由「空」变「满」**：如果预取在首帧前完成并直接驱动 UI，动画结束的一帧
 *    就是"有内容"，而下一帧可能因骨架切换又变一次 —— 观感上像闪了两下。
 * 3. **不新增 AppStorage 键**：首帧前没有的键在首帧后 `setOrCreate` 会触发订阅组件重建，
 *    正好落在启动动画末尾。
 *
 * 换句话说：**预取只负责"数据先到"，不负责"界面先变"**。界面变化仍然由页面自己的
 * 加载状态机驱动，与没有预取时走同一条路径（只是更快拿到数据）。
 *
 * ## 预算与并发
 *
 * - 总预算 {@link BUDGET_MS}：超时就放弃剩余步骤（用户可能已经在用别的功能了）；
 * - 串行执行：这几步都要经过同一个 Cookie 罐，并发只会互相覆盖（见 `MemoCache` 的说明）；
 * - 失败静默：任何一步失败都不能影响应用使用，下次进页面会自己重试。
 */
export class StartupPrefetch {
  /** 首帧后等待多久再开始（给首屏布局、字体、卡片刷新让路）。 */
  private static readonly DELAY_MS: number = 900;
  /** 整轮预取的总预算。 */
  private static readonly BUDGET_MS: number = 9000;

  private static started: boolean = false;
  private static cancelled: boolean = false;
  private static finished: boolean = false;
  /** 已经预热好的学期编码（其它模块可读，省一次学期列表）。 */
  private static warmedTermCode: string = '';

  /**
   * 启动预取（幂等，只会真正跑一次）。
   *
   * 由 `MainPage` 在首帧后调用；未登录 / 演示模式下直接跳过。
   */
  static start(): void {
    if (StartupPrefetch.started) {
      return;
    }
    // 未登录 / 演示模式：**不要置 started**，等用户登录后 MainPage 再次挂载时还能启动。
    // （如果在这里置位，冷启动首次未登录的用户整个进程都不会有预取。）
    if (TokenStore.getDemoMode() || !TokenStore.hasLocalSession()) {
      return;
    }
    StartupPrefetch.started = true;
    setTimeout(() => {
      void StartupPrefetch.run();
    }, StartupPrefetch.DELAY_MS);
  }

  /**
   * 中断预取（App 切后台时调用）。
   *
   * 用户已经离开前台，继续跑只会白耗流量与电；已完成的步骤仍留在缓存里。
   */
  static cancel(): void {
    if (!StartupPrefetch.finished) {
      StartupPrefetch.cancelled = true;
    }
  }

  /** 预取是否已经结束（完成 / 中断 / 未开始即跳过）。 */
  static isFinished(): boolean {
    return StartupPrefetch.finished;
  }

  /** 预取拿到的学期编码（空串 = 还没拿到）。 */
  static termCode(): string {
    return StartupPrefetch.warmedTermCode;
  }

  private static async run(): Promise<void> {
    const startAt: number = Date.now();
    const deadline: number = startAt + StartupPrefetch.BUDGET_MS;
    try {
      // 定时器排上之后、真正跑起来之前，App 可能已经切到后台（`cancel()` 只在
      // finished=false 时生效）。这一步必须先判：否则会白跑一次 CAS 换取 + 请求，
      // 才在下面第一步的 shouldStop 里收手。
      if (StartupPrefetch.cancelled) {
        return;
      }
      // ① 学期列表：同时把教务（byxt）会话打通 —— 后面三步都复用这一次换取
      const terms: Term[] = await ApiService.fetchTerms();
      if (StartupPrefetch.shouldStop(deadline)) {
        return;
      }
      const termCode: string = StartupPrefetch.pickTerm(terms);
      if (termCode.length === 0) {
        return;
      }
      StartupPrefetch.warmedTermCode = termCode;

      // ② 周次表：课表页的标题栏与周次胶囊都依赖它
      const weeks: Week[] = await ApiService.fetchWeeks(termCode);
      if (StartupPrefetch.shouldStop(deadline)) {
        return;
      }

      // ③ 当前周的课表：课表页首屏 + 首页「点课程看详情」共用这一份
      const week: number = StartupPrefetch.pickWeek(weeks);
      if (week > 0) {
        await ApiService.fetchWeeklySchedule(termCode, week);
        Logger.info('启动预取：第' + week.toString() + '周课表已就绪（' +
          (Date.now() - startAt).toString() + 'ms）');
      }
      if (StartupPrefetch.shouldStop(deadline)) {
        return;
      }

      // ④ 考试安排：首页倒计时与「考试安排」页共用
      const exams: ExamArrangementData = await ApiService.fetchExams(termCode);
      Logger.info('启动预取：考试 ' + exams.arranged.length.toString() + ' 场（' +
        (Date.now() - startAt).toString() + 'ms）');
      if (StartupPrefetch.shouldStop(deadline)) {
        return;
      }

      // ⑤ 「我的」页的校园账户五项指标：进页面「即有数」的前提就是启动时先跑完。
      //    它要单独打通 it.buaa.edu.cn 的业务登录（另一条 CAS 链，外加 info + items
      //    + 5 次 detail 串行），是这几步里第二重的，所以排在课表/考试之后。
      //    前几步已花掉一半预算（网络偏慢）就跳过：该项在页面上有自己的加载与重试，
      //    缺预取只是慢一次，不会显示成错误。
      if (Date.now() - startAt > StartupPrefetch.BUDGET_MS / 2) {
        Logger.info('启动预取：前几步已用 ' + (Date.now() - startAt).toString() +
          'ms（超过预算一半），跳过校园账户预取');
      } else {
        try {
          const metrics: PortalMetrics = await LocalPortalService.fetchMetrics();
          Logger.info('启动预取：校园账户 ' + StartupPrefetch.metricsSummary(metrics) + '（' +
            (Date.now() - startAt).toString() + 'ms）');
        } catch (error) {
          // 这一步失败**不能**中断后面的成绩预取，故就地吞掉（页面会自己重试）
          Logger.warn('启动预取：校园账户指标失败（忽略）：' + (error as Error).message);
        }
      }
      if (StartupPrefetch.shouldStop(deadline)) {
        return;
      }

      // ⑥ 本学期成绩：最重的一步（要额外换一次 app 门户会话），放最后。
      //    再加一道自适应闸门：前面几步已经花掉一半预算，说明网络/设备偏慢，
      //    这时再插一条 CAS 链只会把启动阶段的 IO 拖长 —— 直接放弃，成绩页自己会加载。
      if (Date.now() - startAt > StartupPrefetch.BUDGET_MS / 2) {
        Logger.info('启动预取：前几步已用 ' + (Date.now() - startAt).toString() +
          'ms（超过预算一半），跳过成绩预取');
        return;
      }
      await ApiService.fetchGrades(termCode);
      Logger.info('启动预取完成，共 ' + (Date.now() - startAt).toString() + 'ms');
    } catch (error) {
      // 预取失败不影响任何功能：各页面自己的加载流程会重试
      Logger.warn('启动预取中断（忽略）：' + (error as Error).message);
    } finally {
      StartupPrefetch.finished = true;
    }
  }

  /** 超预算 / 已切后台 / 已登出 → 停止后续步骤。 */
  private static shouldStop(deadline: number): boolean {
    if (StartupPrefetch.cancelled || Date.now() > deadline) {
      StartupPrefetch.finished = true;
      return true;
    }
    if (!TokenStore.hasLocalSession()) {
      // 预取途中用户登出了：立刻停手，别再往缓存里塞上一个账号的数据
      StartupPrefetch.finished = true;
      return true;
    }
    return false;
  }

  /** 优先用上游标记的当前学期，其次用本地记住的，最后取列表第一个。 */
  private static pickTerm(terms: Term[]): string {
    for (let i = 0; i < terms.length; i++) {
      if (terms[i].selected) {
        return terms[i].itemCode;
      }
    }
    const remembered: string[] = TokenStore.getSelectedTerm();
    if (remembered[0].length > 0) {
      for (let i = 0; i < terms.length; i++) {
        if (terms[i].itemCode === remembered[0]) {
          return remembered[0];
        }
      }
    }
    return terms.length > 0 ? terms[0].itemCode : '';
  }

  /** 当前周：上游 `curWeek` → 按日期算 → 本地记住 → 1。 */
  private static pickWeek(weeks: Week[]): number {
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
    return remembered > 0 ? remembered : (weeks.length > 0 ? weeks[0].serialNumber : 0);
  }

  /** 日志用摘要：「已取到 N/M 项」。只数成功项，不打具体金额（日志会被导出来排查）。 */
  private static metricsSummary(metrics: PortalMetrics): string {
    const list: (PortalMetric | null)[] = [metrics.netFee, metrics.cardBalance,
      metrics.unreadMail, metrics.borrowedBooks, metrics.wangpan];
    let ok: number = 0;
    let total: number = 0;
    for (let i = 0; i < list.length; i++) {
      const metric: PortalMetric | null = list[i];
      if (metric !== null) {
        total++;
        if (metric.ok) {
          ok++;
        }
      }
    }
    return '已取到 ' + ok.toString() + '/' + total.toString() + ' 项';
  }

  /** 供将来排查「预取到底有没有用」时重置（登出后调用）。 */
  static reset(): void {
    StartupPrefetch.started = false;
    StartupPrefetch.cancelled = false;
    StartupPrefetch.finished = false;
    StartupPrefetch.warmedTermCode = '';
  }
}
