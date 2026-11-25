/**
 * 日期工具。
 *
 * 服务端返回的日期均为本地日期字符串（yyyy-MM-dd），
 * 这里只做「按天」计算，避免时区带来的偏差。
 */
export class DateUtil {
  private static readonly DAY_MILLIS: number = 86400000;
  /**
   * 日期前缀匹配（模块级常量，避免每次 `parse` 都重新编译正则）。
   *
   * 月份/日期允许 1~2 位：上游的日期串**不保证补零**。
   */
  private static readonly DATE_PREFIX: RegExp = /^(\d{4})-(\d{1,2})-(\d{1,2})/;

  static pad(value: number): string {
    return value < 10 ? '0' + value.toString() : value.toString();
  }

  static format(date: Date): string {
    return date.getFullYear().toString() + '-' +
      DateUtil.pad(date.getMonth() + 1) + '-' +
      DateUtil.pad(date.getDate());
  }

  static today(): string {
    return DateUtil.format(new Date());
  }

  static addDays(date: Date, days: number): Date {
    const next = new Date(date.getTime());
    next.setDate(next.getDate() + days);
    return next;
  }

  /** 解析 yyyy-MM-dd；也兼容 "2026-06-15 08:00" 这类带时间的前缀。 */
  static parse(text: string): Date | null {
    // ⚠️ 不能按固定下标切：上游偶尔返回 "2026-1-5"（月/日不补零），
    // 固定下标会切出 month="1-" → 1、day=" 0" → 0，`new Date(2026, 0, 0)`
    // 落到 2025-12-31 —— 卡片「本周」与考试倒计时会整体错一天。
    const matched: RegExpMatchArray | null = text.match(DateUtil.DATE_PREFIX);
    if (matched === null) {
      return null;
    }
    const year: number = Number.parseInt(matched[1], 10);
    const month: number = Number.parseInt(matched[2], 10);
    const day: number = Number.parseInt(matched[3], 10);
    if (Number.isNaN(year) || Number.isNaN(month) || Number.isNaN(day) ||
      month < 1 || month > 12 || day < 1 || day > 31) {
      return null;
    }
    return new Date(year, month - 1, day);
  }

  /**
   * 解析 `yyyy-MM-dd HH:mm[:ss]`（课表上下课时间就是这种格式）。
   *
   * 只有日期没有时间时按当天 00:00 返回 —— 调用方是拿它和「现在」比大小，
   * 日期部分必须真实，时间部分缺了就该落到当天零点而不是丢掉整个解析结果。
   */
  static parseDateTime(text: string): Date | null {
    const day: Date | null = DateUtil.parse(text);
    if (day === null) {
      return null;
    }
    const timeMatched: RegExpMatchArray | null = text.match(/(\d{1,2}):(\d{2})(?::(\d{2}))?/);
    if (timeMatched === null) {
      return day;
    }
    const hour: number = Number.parseInt(timeMatched[1], 10);
    const minute: number = Number.parseInt(timeMatched[2], 10);
    const second: number = Number.parseInt(timeMatched[3] ?? '0', 10);
    if (Number.isNaN(hour) || hour > 23 || Number.isNaN(minute) || minute > 59 ||
      Number.isNaN(second) || second > 59) {
      return day;
    }
    day.setHours(hour, minute, second, 0);
    return day;
  }

  /** 距离目标日期还有几天（负数表示已过去）。 */
  static daysUntil(text: string): number | null {
    const target = DateUtil.parse(text);
    if (target === null) {
      return null;
    }
    const now = new Date();
    const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    return Math.round((target.getTime() - today.getTime()) / DateUtil.DAY_MILLIS);
  }

  /** 倒计时文案。 */
  static countdownText(text: string): string {
    const days = DateUtil.daysUntil(text);
    if (days === null) {
      return '待定';
    }
    if (days < 0) {
      return '已结束';
    }
    if (days === 0) {
      return '今天';
    }
    return days.toString() + ' 天后';
  }

  static weekdayNames(): string[] {
    return ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  }

  /** 当前是周几（1 = 周一，7 = 周日）。 */
  static currentWeekday(): number {
    const day = new Date().getDay();
    return day === 0 ? 7 : day;
  }

  /** 节次区间文案，如「3-4 节」。 */
  static sectionRange(begin: number, end: number): string {
    if (begin <= 0) {
      return '';
    }
    if (end > begin) {
      return begin.toString() + '-' + end.toString() + ' 节';
    }
    return begin.toString() + ' 节';
  }
}
