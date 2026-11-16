import { AppColor } from '../components/AppTheme';
import { Logger } from '../common/Logger';
import { ApiError } from '../network/ApiError';
import { ApiService } from '../network/ApiService';
import { TokenStore } from '../network/TokenStore';
import { LoginPage } from './auth/LoginPage';
import { MainPage } from './MainPage';
import { UserData } from '../model/ApiTypes';

/**
 * 应用入口页。
 *
 * 职责只有一件：决定首帧展示「登录」还是「主页」。
 * 已登录但会话在上游失效时，静默回退到登录页，不做弹窗打扰。
 *
 * 两套登录态都要认：
 * - `StoredSession`（JWT）—— 中转模式的历史遗留；
 * - `LocalAuthSession`（上游 Cookie）—— 本地模式，登录态是 Cookie 而非令牌，
 *   因此不能用 `session.isValid()`（它只看 refreshToken）来判定登录与否。
 *
 * ⚠️ 这里**没有** loading 态：会话判定是同步的（读本地存储），首帧就能定下来。
 * 早先那版「先探测、探测完再进主页」已经被「先亮界面 + 后台自检」取代
 * （探测要往返上游，横竖屏重建时会闪一段「正在恢复登录状态…」）。
 */
/**
 * 上次成功自检的时刻（模块级）。
 *
 * 横竖屏切换会重建 `Index`，而 `aboutToAppear` 每次都会发一次 `status()` ——
 * 平板来回转几次屏就是好几次多余往返。成功过一次就 5 分钟内不再重复；
 * 失败不记录，下次重建还会重试（网络抖动时自我修复）。
 */
let lastVerifiedAt: number = 0;
/** 复检间隔。 */
const VERIFY_INTERVAL_MS: number = 5 * 60 * 1000;

@Entry
@Component
struct Index {
  @State private loggedIn: boolean = false;
  /**
   * 后台自检的代次。
   *
   * 自检是一次网络往返，期间用户可能已经在登录页登录成功（或刚从 401 退回登录页又登进来）。
   * 迟到的旧结果如果照旧落地，会把刚登录的用户直接弹回登录页。
   * 每次自检发起时叫一次号，落地前比对；登录成功 / 登出时也递增，作废在途结果。
   */
  private verifySeq: number = 0;

  aboutToAppear(): void {
    // 诊断横竖屏切换后的「重载」发生在哪一层：这条打印说明 Index 组件被重建了
    Logger.info('Index aboutToAppear');

    const hasLocal: boolean = TokenStore.hasLocalSession();
    const session = TokenStore.getSession();
    if (!session.isValid() && !hasLocal) {
      return;
    }
    // **有会话就直接进主页**，探测放到后台。
    //
    // 原来是「先探测、探测完才进主页」，探测要往返上游（最坏重试 + 600ms 等待），
    // 于是横竖屏切换重建 Index 时会闪一段「正在恢复登录状态…」——那也是「APP 重载了」
    // 的一部分。改成先亮界面、后台自检：401 才回登录页，其余情况不打扰用户。
    this.loggedIn = true;
    // 5 分钟内成功自检过就不再重复（转屏会重建本组件）
    if (Date.now() - lastVerifiedAt < VERIFY_INTERVAL_MS) {
      return;
    }
    const seq: number = ++this.verifySeq;
    void this.verifyInBackground(seq);
  }

  /** 后台自检会话：只有上游明确说 401 才把用户请回登录页。 */
  private async verifyInBackground(seq: number): Promise<void> {
    try {
      const status = await ApiService.status();
      if (seq !== this.verifySeq) {
        return; // 已被更新的状态取代（例如用户刚刚登录成功）
      }
      ApiService.persistUser(status.user);
      // 只有成功才记时间：失败不记，下次重建还会重试
      lastVerifiedAt = Date.now();
    } catch (error) {
      if (seq !== this.verifySeq) {
        return;
      }
      const apiError = error as ApiError;
      if (apiError instanceof ApiError && apiError.status === 401) {
        TokenStore.clear();
        TokenStore.clearAllLocalSessions();
        // 已确认失效：清掉时间戳，下次进主页（重新登录后）立刻再校验一次
        lastVerifiedAt = 0;
        Logger.warn('会话已失效，需要重新登录');
        this.loggedIn = false;
      } else {
        // 网络抖动：不打扰用户，数据页自己会重试
        Logger.warn('会话自检失败（忽略，页面会自行重试）：' + (error as Error).message);
      }
    }
  }

  build() {
    Column() {
      if (this.loggedIn) {
        MainPage({
          onLogout: () => {
            this.verifySeq++;
            // 换账号后要重新校验：清掉时间戳
            lastVerifiedAt = 0;
            this.loggedIn = false;
          }
        })
      } else {
        LoginPage({
          onLoginSuccess: (user: UserData) => {
            // 登录成功：作废可能还在飞的自检（它带的是旧会话的结论）
            this.verifySeq++;
            // 刚登录成功本身就是最强的会话证明，不必立刻再自检一次
            lastVerifiedAt = Date.now();
            this.loggedIn = true;
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.pageBackground)
  }
}
