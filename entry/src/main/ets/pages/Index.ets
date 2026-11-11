import { LoadingView } from '../components/CommonViews';
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
 */
@Entry
@Component
struct Index {
  /**
   * 初值必须是 false。
   *
   * `@State` 在组件重建时回到初值 —— 若这里初值是 true，重建的第一帧必然显示
   * 「正在恢复登录状态…」，然后 aboutToAppear 才把它改掉。横竖屏切换时正是这一帧
   * 闪出来，看起来就是「APP 重载了」。
   */
  @State private checking: boolean = false;
  @State private loggedIn: boolean = false;

  aboutToAppear(): void {
    // 诊断横竖屏切换后的「重载」发生在哪一层：这条打印说明 Index 组件被重建了
    Logger.info('Index aboutToAppear');

    const hasLocal: boolean = TokenStore.hasLocalSession();
    const session = TokenStore.getSession();
    if (!session.isValid() && !hasLocal) {
      this.checking = false;
      return;
    }
    // **有会话就直接进主页**，探测放到后台。
    //
    // 原来是「先探测、探测完才进主页」，探测要往返上游（最坏重试 + 600ms 等待），
    // 于是横竖屏切换重建 Index 时会闪一段「正在恢复登录状态…」——那也是「APP 重载了」
    // 的一部分。改成先亮界面、后台自检：401 才回登录页，其余情况不打扰用户。
    this.loggedIn = true;
    this.checking = false;
    void this.verifyInBackground();
  }

  /** 后台自检会话：只有上游明确说 401 才把用户请回登录页。 */
  private async verifyInBackground(): Promise<void> {
    try {
      const status = await ApiService.status();
      ApiService.persistUser(status.user);
    } catch (error) {
      const apiError = error as ApiError;
      if (apiError instanceof ApiError && apiError.status === 401) {
        TokenStore.clear();
        TokenStore.clearAllLocalSessions();
        Logger.warn('会话已失效，需要重新登录');
        this.loggedIn = false;
      } else {
        // 网络抖动：不打扰用户，数据页自己会重试
        Logger.warn('会话自检失败（忽略，页面会自行重试）：' + (error as Error).message);
      }
    }
  }

  private async restoreSession(): Promise<void> {
    const hasLocal: boolean = TokenStore.hasLocalSession();
    const session = TokenStore.getSession();
    if (!session.isValid() && !hasLocal) {
      this.checking = false;
      return;
    }

    // 探测失败重试一次：上游偶发抖动（DNS 慢、首包超时）时，一次探测失败就把
    // 用户扔回登录页、要求重新输密码，是「偶尔打开 app 没能自动登录」的直接原因。
    let lastError: Error | null = null;
    for (let attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0) {
        await new Promise<void>((resolve: () => void) => {
          setTimeout(() => {
            resolve();
          }, 600);
        });
      }
      try {
        const status = await ApiService.status();
        ApiService.persistUser(status.user);
        this.loggedIn = true;
        this.checking = false;
        return;
      } catch (error) {
        lastError = error as Error;
        const apiError = error as ApiError;
        // 上游**明确**表示未登录（401）：清掉两套登录态，避免带着死 Cookie 反复重试
        if (apiError instanceof ApiError && apiError.status === 401) {
          TokenStore.clear();
          TokenStore.clearAllLocalSessions();
          // 课表缓存**保留**：里面记了所属账号，重新登录同一账号可直接复用；
          // 换账号时由 SchedulePage 比对后清空。
          Logger.warn('会话已失效，需要重新登录：' + lastError.message);
          this.checking = false;
          return;
        }
      }
    }

    // 两次都没探测成功，且都不是明确的 401 —— 多为网络抖动或上游暂时不可用。
    // 只要本地还留着 Cookie 会话，就乐观放行进主页：各数据页本来就有重试 + 会话
    // 自愈（见 LocalAcademicService.byxtCall），而把用户推回登录页才是最差的结果。
    if (hasLocal) {
      Logger.warn('会话校验两次未成功，带着本地会话进入主页（页面会自行重试）');
      this.loggedIn = true;
    } else {
      Logger.warn('恢复会话失败：' + (lastError === null ? '未知错误' : lastError.message));
    }
    this.checking = false;
  }

  build() {
    Column() {
      if (this.checking) {
        LoadingView({ message: '正在恢复登录状态…' })
      } else if (this.loggedIn) {
        MainPage({
          onLogout: () => {
            this.loggedIn = false;
          }
        })
      } else {
        LoginPage({
          onLoginSuccess: (user: UserData) => {
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
