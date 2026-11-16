import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CardCache, CardClassroom, CardDayView, CardToday, CardWeekView } from './CardCache';
import { CardDataBuilder } from './CardDataBuilder';
import { DateUtil } from './DateUtil';
import { ScheduleCache } from '../network/ScheduleCache';
import { TokenStore } from '../network/TokenStore';
import { Week, WeeklySchedule } from '../model/ApiTypes';

const SUNDAY_ROLL_OVER_HOUR: number = 15;
const DOMAIN: number = 0x0100;
const TAG: string = 'CardRefresher';

/**
 * 应用启动时用**本地缓存**重算一遍桌面卡片。
 *
 * ## 要解决什么
 *
 * 卡片数据的写入原本只发生在「课表页加载 / 切周」时。用户只要不打开课表页，
 * 桌面就一直挂着几天前的快照 —— 周次是上周的、日期对不上、日卡还写着「明天」。
 * 这一步让卡片在每次冷启动后都能对上「今天」。
 *
 * ## 边界
 *
 * - **不联网**：只读 `ScheduleCache` 里已经落盘的周课表，几百毫秒完成；
 * - 取不到缓存就整体跳过，绝不用残缺数据覆盖现有卡片；
 * - 内容计算全部交给 `CardDataBuilder`，与课表页同一套口径。
 */
export class CardRefresher {
  static refresh(context: common.Context): void {
    try {
      const termCode: string = ScheduleCache.loadTermCode();
      const weeks: Week[] = ScheduleCache.loadWeeks();

      // 空闲教室的过期判定与课表缓存无关，先单独处理 —— 哪怕本地没有课表元信息也要做。
      CardRefresher.dropStaleClassroom(context);

      if (termCode.length === 0 || weeks.length === 0) {
        // 没有课表元信息时不能整个跳过：深浅色切换也会走这里，
        // 至少要按现有缓存重推一次，payload 里的 darkMode 是现取的。
        hilog.info(DOMAIN, TAG, '本地无课表元信息，仅按现有缓存重推');
        CardCache.pushAll(context);
        return;
      }
      // ⚠️ 不能直接用 ScheduleCache.loadCurWeek()：那是**上次保存时**的周次，
      // 隔天/隔周再启动就已经过期，卡片会照着旧周去取数据。
      // 校历（weeks[].startDate/endDate）本身就是权威，按"今天落在哪一周"现算。
      let curWeek: number = CardDataBuilder.weekOfToday(weeks);
      if (curWeek <= 0) {
        curWeek = ScheduleCache.loadCurWeek();
      }
      if (curWeek <= 0) {
        hilog.info(DOMAIN, TAG, '推算不出当前教学周，跳过卡片刷新');
        return;
      }

      // **卡片一律以「今天所在周」为准**，不再叠加“用户上次翻到的周”——
      // 否则翻过一次第 12 周，桌面就长期停在第 12 周（今天明明在第 11 周）。
      const shown: number = CardRefresher.systemWeek(curWeek, weeks);

      let used: number = shown;
      let data: WeeklySchedule | null = ScheduleCache.loadWeek(termCode, shown);
      if (data === null) {
        // 该周没缓存 → 退到一个确实有数据的周，并让「周标签/日期/今天高亮」都跟着它走，
        // 否则会出现「标题第 10 周、表头第 8 周」的错位。
        const alt: number = ScheduleCache.pickCachedWeek(termCode, shown, weeks);
        if (alt !== shown) {
          const other: WeeklySchedule | null = ScheduleCache.loadWeek(termCode, alt);
          if (other !== null) {
            used = alt;
            data = other;
          }
        }
      }
      if (data === null) {
        hilog.info(DOMAIN, TAG, '无可用周课表缓存，仅按现有缓存重推');
        CardCache.pushAll(context);
        return;
      }

      const today: number = DateUtil.currentWeekday();
      const isCurrentWeek: boolean = used === curWeek;
      const termName: string = ScheduleCache.loadTermName();

      const weekView: CardWeekView =
        CardDataBuilder.buildWeekView(data, weeks, used, termName, isCurrentWeek ? today : 0);
      CardCache.saveWeekView(context, weekView);

      const dayView: CardDayView =
        CardDataBuilder.buildDayView(data, weeks, used, today, today, isCurrentWeek);
      CardCache.saveDayView(context, dayView);

      const todayCard: CardToday =
        CardDataBuilder.buildToday(data, weeks, used, today, isCurrentWeek);
      CardCache.saveToday(context, todayCard, todayCard.headline);

      hilog.info(DOMAIN, TAG, '卡片已按本地缓存重算：第 %{public}d 周（当前周=%{public}s）',
        used, isCurrentWeek ? '是' : '否');
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '刷新卡片失败：%{public}s', (error as Error).message);
    }
  }

  /**
   * 空闲教室快照跨天即失效。
   *
   * 它的文案形如 `今天 · 11月15日` —— 隔天再看，「今天」两个字直接是错的。
   * 与其改文案粉饰，不如清掉让卡片回到空态（提示用户去 App 里查当天的）。
   */
  private static dropStaleClassroom(context: common.Context): void {
    const room: CardClassroom | null = CardCache.loadClassroom(context);
    if (room === null) {
      return;
    }
    const m: RegExpMatchArray | null = room.dateText.match(/(\d+)月(\d+)日/);
    if (m === null) {
      return;
    }
    const now: Date = new Date();
    const sameDay: boolean =
      parseInt(m[1], 10) === now.getMonth() + 1 && parseInt(m[2], 10) === now.getDate();
    if (!sameDay) {
      hilog.info(DOMAIN, TAG, '空闲教室快照已过期（%{public}s），清除', room.dateText);
      CardCache.clearClassroom(context);
    }
  }

  /** 系统规则下的「此刻该看哪一周」：周日下午 15:00 之后自动看下一周。 */
  private static systemWeek(curWeek: number, weeks: Week[]): number {
    const now: Date = new Date();
    if (now.getDay() !== 0) {
      return curWeek;
    }
    if (now.getHours() < SUNDAY_ROLL_OVER_HOUR) {
      return curWeek;
    }
    let maxWeek = 0;
    for (let i = 0; i < weeks.length; i++) {
      if (weeks[i].serialNumber > maxWeek) {
        maxWeek = weeks[i].serialNumber;
      }
    }
    const next: number = curWeek + 1;
    if (maxWeek > 0 && next > maxWeek) {
      return curWeek;
    }
    return next;
  }
}
