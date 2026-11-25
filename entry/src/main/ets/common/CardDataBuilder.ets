/**
 * 桌面卡片数据的**纯计算层**。
 *
 * ## 为什么要把这些逻辑从 SchedulePage 搬出来
 *
 * 这套计算（周次、日期、冲突簇、节次时间）原来全长在 `SchedulePage` 的私有方法里，
 * 只有「打开课表页 / 切周」才会跑。结果就是：用户不进课表页，桌面卡片就一直挂着
 * 几天前的快照 —— 周次写着上周、日期对不上、「今天」高亮在错误的那一列。
 *
 * 抽成不依赖页面状态的纯函数后：
 * - `SchedulePage` 照旧调用（渲染与写卡片的判定口径完全一致）；
 * - 应用启动时 `CardRefresher` 也能用本地缓存重算一次，卡片不再依赖「先打开课表页」。
 *
 * 所有方法都是静态的、无副作用的，入参显式带 `weeks` / `week`，
 * 避免出现「用页面 currentWeek 去算另一周数据」这类错位。
 */
import { CardCourse, CardDayView, CardSlot, CardToday, CardWeekView } from './CardCache';
import { CourseClass, SectionTime, Week, WeeklySchedule } from '../model/ApiTypes';
import { DateUtil } from './DateUtil';
import { CourseSlotInput, ScheduleColors } from './ScheduleColors';
import { ScheduleCache } from '../network/ScheduleCache';

/**
 * 卡片网格的最少行数。
 *
 * 卡片只画到「本周实际最后一节」，但学期课少时（比如只有 5 节）网格会缩得很矮、
 * 课程块挤成一坨。留 6 行作为下限，行高才够看。
 *
 * 为什么不按尺寸区分（4×4 六行 / 6×4 十行）：卡片运行时**拿不到自身规格** ——
 * `FormDimension` 枚举里只有 1_2 / 2_2 / 2_4 / 4_4，根本没有 6_4，
 * `onAddForm` 的 `DIMENSION_KEY` 对 6×4 也返回 4_4；卡片内又禁用 `onAreaChange`。
 * 所以只能取一个统一下限，选 6（4×4 是默认尺寸，且行高更大更好读）。
 */
const MIN_CARD_SECTIONS = 6;

export class CardDataBuilder {
  /* --------------------------- 课程基础换算 --------------------------- */

  /** 起始节次（1 基，非法值兜底为 1）。 */
  static beginOf(c: CourseClass): number {
    return c.beginSection !== undefined && c.beginSection > 0 ? c.beginSection : 1;
  }

  /** 跨越节数。 */
  static spanOf(c: CourseClass): number {
    const begin: number = CardDataBuilder.beginOf(c);
    const end: number = c.endSection !== undefined && c.endSection >= begin ? c.endSection : begin;
    return end - begin + 1;
  }

  /** 结束节次。 */
  static endOf(c: CourseClass): number {
    return CardDataBuilder.beginOf(c) + CardDataBuilder.spanOf(c) - 1;
  }

  /** `08:00~09:35`；两端都缺就空串。 */
  private static timeText(c: CourseClass): string {
    const begin: string = c.beginTime === undefined ? '' : c.beginTime;
    const end: string = c.endTime === undefined ? '' : c.endTime;
    if (begin.length === 0) {
      return end;
    }
    return end.length > 0 ? begin + '~' + end : begin;
  }

  /** 某一天的全部课程，**按起始节次升序**。 */
  static coursesOfDay(data: WeeklySchedule, day: number): CourseClass[] {
    const out: CourseClass[] = [];
    for (let i = 0; i < data.arrangedList.length; i++) {
      const item: CourseClass = data.arrangedList[i];
      const d: number = item.dayOfWeek === undefined ? 1 : item.dayOfWeek;
      if (d === day) {
        out.push(item);
      }
    }
    // 必须排序：找「下一节课」时是按顺序取第一个未开始的，乱序会取错。
    out.sort((a: CourseClass, b: CourseClass) => CardDataBuilder.beginOf(a) - CardDataBuilder.beginOf(b));
    return out;
  }

  private static overlaps(a: CourseClass, b: CourseClass): boolean {
    return CardDataBuilder.beginOf(a) <= CardDataBuilder.endOf(b) &&
      CardDataBuilder.beginOf(b) <= CardDataBuilder.endOf(a);
  }

  /**
   * 某一天的「冲突簇」：时间上重叠的课归为一簇，簇与簇之间互不重叠。
   *
   * 与课表页 `dayClustersFor` 同一套贪心算法 —— 卡片是静态网格，
   * 同一格塞两个块会直接叠在一起糊成一片，所以卡片侧也必须先合并。
   */
  static clustersOfDay(data: WeeklySchedule, day: number): CourseClass[][] {
    const list: CourseClass[] = CardDataBuilder.coursesOfDay(data, day);
    const out: CourseClass[][] = [];
    let i = 0;
    while (i < list.length) {
      const group: CourseClass[] = [list[i]];
      let j = i + 1;
      while (j < list.length) {
        let hit = false;
        for (let k = 0; k < group.length; k++) {
          if (CardDataBuilder.overlaps(group[k], list[j])) {
            hit = true;
            break;
          }
        }
        if (!hit) {
          break;
        }
        group.push(list[j]);
        j++;
      }
      out.push(group);
      i = j;
    }
    return out;
  }

  /* ----------------------------- 课程色槽（相邻避让） ----------------------------- */

  /**
   * 从本地缓存的**整学期**课程构建避让槽位表，口径与课表页 `rebuildCourseSlots` 完全一致。
   *
   * 卡片进程不能 import 项目文件，也没有整学期数据，所以只能由主应用在写卡片时
   * 把算好的槽位写进 `CardSlot.colorSlot` 随 payload 下发。
   *
   * 取不到缓存 / 没课程时返回空表，调用方回退到课程名哈希（兼容旧数据）。
   */
  static buildCourseSlotMap(): Map<string, number> {
    const inputs: CourseSlotInput[] = [];
    const termCode: string = ScheduleCache.loadTermCode();
    const weeks: Week[] = ScheduleCache.loadWeeks();
    if (termCode.length === 0) {
      return new Map();
    }
    for (let w = 0; w < weeks.length; w++) {
      const n: number = weeks[w].serialNumber;
      const week: WeeklySchedule | null = ScheduleCache.loadWeek(termCode, n);
      if (week === null || week === undefined || week.arrangedList === undefined) {
        continue;
      }
      for (let i = 0; i < week.arrangedList.length; i++) {
        const c: CourseClass = week.arrangedList[i];
        const key: string = c.courseName.length > 0 ? c.courseName : c.courseCode;
        if (key.length === 0) {
          continue;
        }
        const begin: number = CardDataBuilder.beginOf(c);
        const end: number = CardDataBuilder.endOf(c);
        const day: number = c.dayOfWeek === undefined || c.dayOfWeek <= 0 ? 1 : c.dayOfWeek;
        inputs.push({ key: key, day: day, begin: begin, end: end });
      }
    }
    return ScheduleColors.assignCourseSlots(inputs);
  }

  /* ----------------------------- 卡片扁平结构 ----------------------------- */

  /** 一门课 → 今日概览用的扁平结构（不合并冲突，逐门列）。 */
  static toCardCourse(c: CourseClass): CardCourse {
    const begin: number = CardDataBuilder.beginOf(c);
    const end: number = CardDataBuilder.endOf(c);
    const item: CardCourse = {
      section: begin === end ? begin.toString() + '节' : begin.toString() + '-' + end.toString() + '节',
      time: CardDataBuilder.timeText(c),
      courseName: c.courseName,
      place: c.placeName === undefined ? '' : c.placeName
    };
    return item;
  }

  /**
   * 一周全部课程 → 卡片网格块（冲突已合并）。
   *
   * 多门课同处一格时写 `N节课`、教室留空，与课表页 `multiCourseBlock` 的文案一致；
   * 起止时间取簇内最早开始与最晚结束，免得跨节次的块在左列对不上。
   */
  static toSlots(data: WeeklySchedule, assigned?: Map<string, number>): CardSlot[] {
    const slots: Map<string, number> = assigned === undefined ? new Map() : assigned;
    const out: CardSlot[] = [];
    for (let day = 1; day <= 7; day++) {
      const clusters: CourseClass[][] = CardDataBuilder.clustersOfDay(data, day);
      for (let i = 0; i < clusters.length; i++) {
        const group: CourseClass[] = clusters[i];
        const multi: boolean = group.length > 1;
        const first: CourseClass = group[0];
        let minBegin: number = CardDataBuilder.beginOf(first);
        let maxEnd: number = CardDataBuilder.endOf(first);
        let beginTime: string = '';
        let endTime: string = '';
        for (let k = 0; k < group.length; k++) {
          const c: CourseClass = group[k];
          if (CardDataBuilder.beginOf(c) < minBegin) {
            minBegin = CardDataBuilder.beginOf(c);
          }
          if (CardDataBuilder.endOf(c) > maxEnd) {
            maxEnd = CardDataBuilder.endOf(c);
          }
          const bt: string = c.beginTime === undefined ? '' : c.beginTime;
          const et: string = c.endTime === undefined ? '' : c.endTime;
          if (bt.length > 0 && (beginTime.length === 0 || bt.localeCompare(beginTime) < 0)) {
            beginTime = bt;
          }
          if (et.length > 0 && et.localeCompare(endTime) > 0) {
            endTime = et;
          }
        }
        out.push({
          day: day,
          begin: minBegin,
          end: maxEnd,
          time: beginTime + (endTime.length > 0 ? (beginTime.length > 0 ? '~' + endTime : endTime) : ''),
          courseName: multi ? (group.length.toString() + '节课') : first.courseName,
          place: multi ? '' : (first.placeName === undefined ? '' : first.placeName),
          color: first.color === undefined ? '' : first.color,
          // 相邻避让后的色槽（跨端一致）；卡片侧优先用它，缺省回退课程名哈希
          colorSlot: ScheduleColors.slotOf(
            first.courseName.length > 0 ? first.courseName : first.courseCode, slots)
        });
      }
    }
    return out;
  }

  /** 某一天的卡片方块（已合并冲突）。 */
  static slotsOfDay(data: WeeklySchedule, day: number, assigned?: Map<string, number>): CardSlot[] {
    const all: CardSlot[] = CardDataBuilder.toSlots(data, assigned);
    const out: CardSlot[] = [];
    for (let i = 0; i < all.length; i++) {
      if (all[i].day === day) {
        out.push(all[i]);
      }
    }
    return out;
  }

  /* ------------------------------- 节次时间 ------------------------------- */

  /** 节次时间表，索引 = 节次-1；每项形如 `08:00~08:45`。 */
  static sectionTimes(data: WeeklySchedule): string[] {
    const times: string[] = [];
    for (let i = 0; i < data.sectionTimes.length; i++) {
      const t: SectionTime = data.sectionTimes[i];
      const n: number = t.section;
      const begin: string = t.start === undefined ? '' : t.start;
      const end: string = t.end === undefined ? '' : t.end;
      while (times.length < n - 1) {
        times.push('');
      }
      times.push(begin + (end.length > 0 ? '~' + end : ''));
    }
    return times;
  }

  /** 网格行数：取「上游声明的节次」与「实际课程最晚节次」的较大者。 */
  static sectionCount(data: WeeklySchedule, slots: CardSlot[]): number {
    let max = 0;
    for (let i = 0; i < data.sectionTimes.length; i++) {
      if (data.sectionTimes[i].section > max) {
        max = data.sectionTimes[i].section;
      }
    }
    for (let i = 0; i < slots.length; i++) {
      if (slots[i].end > max) {
        max = slots[i].end;
      }
    }
    // 画到「实际最后一节」为止，但不低于 6 行（行高才够放得下课程名）
    return max > MIN_CARD_SECTIONS ? max : MIN_CARD_SECTIONS;
  }

  /* -------------------------------- 日期 -------------------------------- */

  /** 某一周第一天的日期（上游没给就 null）。 */
  static weekStart(weeks: Week[], week: number): Date | null {
    for (let i = 0; i < weeks.length; i++) {
      if (weeks[i].serialNumber === week) {
        return DateUtil.parse(weeks[i].startDate);
      }
    }
    return null;
  }

  /**
   * 今天落在校历的哪一周（按 `startDate`/`endDate` 实算）。
   *
   * **不要用「用户记住的周次」代替当前周**：那是课表页翻页时记录的，
   * 用户上次停在第五周，第二天打开首页就会被当成「今天是第五周」。
   * 校历本身是权威，课程已结束或还没开学返回 0。
   */
  static weekOfToday(weeks: Week[]): number {
    const now: Date = new Date();
    const today: Date = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    const day: number = today.getTime();
    for (let i = 0; i < weeks.length; i++) {
      const start: Date | null = DateUtil.parse(weeks[i].startDate);
      const end: Date | null = DateUtil.parse(weeks[i].endDate);
      if (start === null || end === null) {
        continue;
      }
      // 上游给的日期可能带时分秒，统一归零到当天再比
      const s: number = new Date(start.getFullYear(), start.getMonth(), start.getDate()).getTime();
      const e: number = new Date(end.getFullYear(), end.getMonth(), end.getDate()).getTime();
      if (day >= s && day <= e) {
        return weeks[i].serialNumber;
      }
    }
    return 0;
  }

  /**
   * 系统规则下的「此刻该看哪一周」：按校历算出今天所在教学周，
   * 周日下午 15:00 之后自动滚到下一周（周末新一周课表通常此时已发布）。
   *
   * ⚠️ 桌面卡片（今日概览 / 下一节课）**必须**用这个判定，不能用课表页翻到的
   * `currentWeek` —— 用户在课表页翻到第 12 周，桌面卡片不该跟着变成第 12 周。
   * 课表页切周后写卡片时调用本方法，与 `CardRefresher` 冷启动刷新共用同一口径。
   */
  static systemCurrentWeek(weeks: Week[]): number {
    const curWeek: number = CardDataBuilder.weekOfToday(weeks);
    if (curWeek <= 0) {
      return 0;
    }
    const now: Date = new Date();
    if (now.getDay() !== 0 || now.getHours() < 15) {
      return curWeek;
    }
    // 周日 15:00 后滚到下一周，但不越过本学期最后一周
    let maxWeek: number = 0;
    for (let i = 0; i < weeks.length; i++) {
      if (weeks[i].serialNumber > maxWeek) {
        maxWeek = weeks[i].serialNumber;
      }
    }
    const next: number = curWeek + 1;
    return (maxWeek > 0 && next > maxWeek) ? curWeek : next;
  }

  /** 某周某天的 `MM/DD`。 */
  static dayDate(weeks: Week[], day: number, week: number): string {
    const start: Date | null = CardDataBuilder.weekStart(weeks, week);
    if (start === null) {
      return '';
    }
    const date: Date = DateUtil.addDays(start, day - 1);
    return DateUtil.pad(date.getMonth() + 1) + '/' + DateUtil.pad(date.getDate());
  }

  /** 某周七天的日期文案（表头用）。 */
  static weekDates(weeks: Week[], week: number): string[] {
    const out: string[] = [];
    for (let day = 1; day <= 7; day++) {
      out.push(CardDataBuilder.dayDate(weeks, day, week));
    }
    return out;
  }

  /**
   * 分组标题：`今天` / `明天` / `周三`。
   *
   * **只在卡片显示的正是当前周时才有意义** —— 调用方负责把关，
   * 否则会把下周三说成「今天」。
   */
  static dayLabel(target: number, today: number): string {
    if (target === today) {
      return '今天';
    }
    const nextDay: number = (today % 7) + 1;
    if (target === nextDay) {
      return '明天';
    }
    return DateUtil.weekdayNames()[target - 1];
  }

  /** 当前时刻 `HH:MM`。 */
  static nowClock(): string {
    const d: Date = new Date();
    const h: string = d.getHours() < 10 ? '0' + d.getHours().toString() : d.getHours().toString();
    const m: string = d.getMinutes() < 10 ? '0' + d.getMinutes().toString() : d.getMinutes().toString();
    return h + ':' + m;
  }

  /* ------------------------------ 组装视图 ------------------------------ */

  /**
   * 周课表卡。
   *
   * @param shown 卡片实际展示的周次（不一定等于「当前教学周」）
   * @param today 星期几（1~7）；传 0 表示不高亮任何一列
   */
  static buildWeekView(data: WeeklySchedule, weeks: Week[], shown: number,
    termName: string, today: number, assigned?: Map<string, number>): CardWeekView {
    const slots: CardSlot[] = CardDataBuilder.toSlots(data, assigned);
    const view: CardWeekView = {
      termName: termName.length > 0 ? termName : '课表',
      weekLabel: '第 ' + shown.toString() + ' 周',
      dates: CardDataBuilder.weekDates(weeks, shown),
      slots: slots,
      sections: CardDataBuilder.sectionCount(data, slots),
      times: CardDataBuilder.sectionTimes(data),
      today: today,
      totalWeeks: weeks.length,
      ready: true
    };
    return view;
  }

  /**
   * 日课表卡。
   *
   * 今天没课会自动往后找最近有课的一天（最多 7 天），标题随之变成「明天」/「周三」——
   * 空卡没有信息量，「下一节课」才是用户想知道的。
   */
  static buildDayView(data: WeeklySchedule, weeks: Week[], shown: number,
    weekday: number, today: number, isCurrentWeek: boolean,
    assigned?: Map<string, number>): CardDayView {
    let target: number = weekday;
    let slots: CardSlot[] = [];
    for (let step = 0; step <= 7; step++) {
      const day: number = ((weekday - 1 + step) % 7) + 1;
      const found: CardSlot[] = CardDataBuilder.slotsOfDay(data, day, assigned);
      if (found.length > 0) {
        target = day;
        slots = found;
        break;
      }
    }
    const weekdayName: string = DateUtil.weekdayNames()[target - 1];
    const dateText: string = CardDataBuilder.dayDate(weeks, target, shown);
    const view: CardDayView = {
      // 2026-11-23：按用户要求去掉「今天 · 」前缀 —— 左上角只留「周三 · 10/15」。
      // 非今天本来就没有这个前缀，统一成同一套拼接。
      headline: weekdayName + (dateText.length > 0 ? ' · ' + dateText : ''),
      weekLabel: '第 ' + shown.toString() + ' 周',
      day: target,
      slots: slots,
      sections: CardDataBuilder.sectionCount(data, slots),
      times: CardDataBuilder.sectionTimes(data),
      dayLabel: isCurrentWeek ? CardDataBuilder.dayLabel(target, today) : weekdayName,
      // 课程**门数**，不是合并后的块数（同时段两门课应算 2 节）
      dayCount: CardDataBuilder.coursesOfDay(data, target).length,
      ready: true
    };
    return view;
  }

  /**
   * 今日概览卡（1×2）。
   *
   * 「下一节课」会跨天往后找（今天没有就找明天、再找本周后面的课），
   * 否则周末/无课日卡片是一片空白。
   */
  static buildToday(data: WeeklySchedule, weeks: Week[], shown: number,
    weekday: number, isCurrentWeek: boolean): CardToday {
    const todayList: CourseClass[] = CardDataBuilder.coursesOfDay(data, weekday);
    const nowText: string = CardDataBuilder.nowClock();
    const courses: CardCourse[] = [];
    let next: CardCourse | null = null;
    for (let i = 0; i < todayList.length; i++) {
      const item: CardCourse = CardDataBuilder.toCardCourse(todayList[i]);
      courses.push(item);
      if (next === null && item.time.length > 0 && item.time.localeCompare(nowText) > 0) {
        next = item;
      }
    }
    let nextWhen: string = '';
    if (next !== null) {
      nextWhen = '今天 ' + next.time;
    } else {
      const found: CardCourse | null = CardDataBuilder.findNextLater(data, weekday, nowText);
      if (found !== null) {
        next = found;
        nextWhen = (found.when === undefined ? '' : found.when + ' ') + found.time;
      }
    }
    const dateText: string = CardDataBuilder.dayDate(weeks, weekday, shown);
    const headline: string = '第' + shown.toString() + '周' +
      (dateText.length > 0 ? ' · ' + dateText : '');
    const summary: string = courses.length > 0 ?
      ('今天 ' + courses.length.toString() + ' 节课' +
        (next === null ? ' · 已全部结束' : ' · 下一节 ' + next.time + ' ' + next.courseName)) :
      (next === null ? '今天没有课' : '今天没有课 · 下一节 ' + nextWhen + ' ' + next.courseName);
    // 卡片不显示「今天」但数据来自别的周时，摘要文案要避免误导
    const head: string = isCurrentWeek ? headline : ('第' + shown.toString() + '周' + (dateText.length > 0 ? ' · ' + dateText : ''));
    const view: CardToday = {
      headline: head,
      summary: summary,
      courses: courses,
      next: next,
      nextWhen: nextWhen,
      ready: true
    };
    return view;
  }

  /** 从今天往后找最近一节还没开始的课（只看本周）。 */
  private static findNextLater(data: WeeklySchedule, todayWeekday: number,
    nowText: string): CardCourse | null {
    const names: string[] = DateUtil.weekdayNames();
    for (let step = 0; step <= 7; step++) {
      const day: number = ((todayWeekday - 1 + step) % 7) + 1;
      const list: CourseClass[] = CardDataBuilder.coursesOfDay(data, day);
      if (list.length === 0) {
        continue;
      }
      for (let i = 0; i < list.length; i++) {
        const item: CardCourse = CardDataBuilder.toCardCourse(list[i]);
        if (item.time.length > 0 && (step > 0 || item.time.localeCompare(nowText) > 0)) {
          const withWhen: CardCourse = {
            section: item.section,
            time: item.time,
            courseName: item.courseName,
            place: item.place,
            when: step === 0 ? '今天' : (step === 1 ? '明天' : names[day - 1])
          };
          return withWhen;
        }
      }
    }
    return null;
  }
}
