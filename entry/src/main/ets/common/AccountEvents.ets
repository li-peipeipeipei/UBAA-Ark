/**
 * 账号切换的跨页信号。
 *
 * 课表是 MainPage 里的**常驻页签**：HdsTabs 不销毁它，`aboutToAppear` 只在首次创建时跑一次。
 * 课表缓存（ScheduleCache）的账号校验原本只在 `aboutToAppear → restoreFromCache` 里做，
 * 于是「退出登录 A → 登录 B」后 MainPage 若被复用，常驻的 SchedulePage 不会重跑校验，
 * 内存里的旧课表与磁盘上的旧缓存就一起留在了界面上。
 *
 * 和签到刷新（SigninEvents / KEY_SIGNIN_VERSION）用同一套模式：
 * - **自增计数**而非布尔：连续换两次账号也能连续触发（布尔置 true 再置 true 不触发 Watch）。
 * - 账号身份真正确立的时刻（登录成功写会话 / 登出）播一次，订阅方据此作废自己的数据。
 *
 * 订阅方：SchedulePage（清课表缓存 + 重拉）。其他页面用的是按 schoolId 严格隔离的
 * OfflineCache / PageCache，读缓存时天然按新账号过滤，不需要订阅本信号。
 */
export const KEY_ACCOUNT_VERSION: string = 'accountVersion';

export class AccountEvents {
  /** 播一次「登录账号可能变了」。订阅方收到后自行丢弃旧账号数据。 */
  static notifyChanged(): void {
    const current: number = AppStorage.get<number>(KEY_ACCOUNT_VERSION) ?? 0;
    AppStorage.setOrCreate(KEY_ACCOUNT_VERSION, current + 1);
  }

  /**
   * 缓存里记的账号（学号或 `学号|登录名`）是否与当前账号一致。
   *
   * 供登录作废课表缓存与课表页首帧校验共用一套判据，避免两处规则不一致又串号。
   * 老缓存只存了单一标识（无 `|`）时，学号 / 登录名任一对上即算同一人。
   *
   * ⚠️ 不再像旧版那样「信息不全就 return true」—— 那是账号切换仍显示旧课表的
   * 元凶之一：读不到当前账号时宁可判为不同账号、重拉一次，也不能放行别人的数据。
   */
  static accountMatches(cached: string, schoolId: string, username: string): boolean {
    if (cached.length === 0) {
      return false;
    }
    if (cached.indexOf('|') < 0) {
      return cached === schoolId || cached === username;
    }
    const parts: string[] = cached.split('|');
    const cachedSid: string = parts.length > 0 ? parts[0] : '';
    const cachedUser: string = parts.length > 1 ? parts[1] : '';
    if (schoolId.length > 0 && cachedSid.length > 0) {
      return schoolId === cachedSid;
    }
    if (username.length > 0 && cachedUser.length > 0) {
      return username === cachedUser;
    }
    return false;
  }
}
