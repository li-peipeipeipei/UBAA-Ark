/**
 * 课堂签到的跨页信号。
 *
 * 首页「今日课程」与「课堂签到」页读的是同一份 iclass 状态，两边都能发起签到。
 * 一边签完之后，另一边必须知道自己该重读 —— 否则首页还挂着「签到」按钮，
 * 用户会白点一次（签到是写操作，重复提交虽然上游会回「已签到」，但体验很差）。
 *
 * 用**自增计数**而不是布尔：连续签两门课要能连续触发两次 `@Watch`。
 */
export const KEY_SIGNIN_VERSION: string = 'signinVersion';

export class SigninEvents {
  /** 播一次「签到状态可能变了」。订阅方（首页）收到后自行重读。 */
  static notifyChanged(): void {
    const current: number = AppStorage.get<number>(KEY_SIGNIN_VERSION) ?? 0;
    AppStorage.setOrCreate(KEY_SIGNIN_VERSION, current + 1);
  }
}
