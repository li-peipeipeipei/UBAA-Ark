import { connection } from '@kit.NetworkKit';
import { ConnectionMode, RoutePolicy } from '../common/AppConfig';
import { Logger } from '../common/Logger';
import { CampusProbe, NetworkState } from './CampusProbe';
import { SessionGuard } from './SessionGuard';
import { TokenStore } from './TokenStore';

/**
 * 自动路线引擎（对齐上游 `facade/routing.rs` + `connection.rs::resolve_route`）。
 *
 * 职责：在 **AUTO 策略**下维护「本次实际走哪条路」（`ConnectionMode`），
 * 让其余 30 多处调用点继续只读 `TokenStore.getConnectionMode()`，不必感知策略。
 *
 * 与上游的对应关系：
 * | 上游 | 本实现 |
 * |---|---|
 * | `resolve_route(policy, row, probe)` | `targetFor()`（探测 → 选路） |
 * | `route_is_ready(route)` | `TokenStore.hasLocalSession(mode)` |
 * | `read_with_fallback!` 的回退分支 | `adaptToNetwork()` + `UpstreamClient` 重试 |
 * | `CachingGatewayProbe.invalidate()` | `CampusProbe.invalidate()` |
 *
 * **一个刻意的差异**（详见 docs/tech/auto-route-switch.md）：
 * 上游是「双会话并行」（Direct / WebVPN 各自持有独立登录态，校外并发登录两条），
 * 我们是**单会话**（登录态按模式隔离，但同一时刻只有一条真正登着）。
 * 原因：并发两次 CAS 登录会翻倍认证请求，有触发风控/锁号的风险，
 * 而本项目把「账号锁死风险」列为红线。因此：
 * - 只在**登录**时选路（探测 → 走目标路登录一次）；
 * - 只在**网络层失败**时切路（切到另一条有会话的路）；
 * - 目标路没会话时不静默复制凭据，而是明确提示重新登录。
 */

/** 一次故障切换的结论，供调用方决定「重试 / 报错 / 提示重登」。 */
export enum RouteAdapt {
  /** 无需切换（瞬时抖动或本来就该走这条），调用方保留原错误。 */
  KEEP = 'KEEP',
  /** 已切到另一条**有会话**的路线，调用方应重试一次。 */
  SWITCHED = 'SWITCHED',
  /** 已切到另一条路线但**没有会话**，调用方应提示重新登录。 */
  NEED_RELOGIN = 'NEED_RELOGIN'
}

/** 网络从「无」恢复为「有」时广播的 AppStorage 键；错误页订阅后自动重试。 */
export const NETWORK_BACK_TICK_KEY: string = 'networkBackTick';

export class RouteEngine {
  /** 上一次观察到的网络可用性。初值取真实状态，断网启动也能识别「恢复」。 */
  private static lastOnline: boolean = RouteEngine.isOnline();
  /**
   * 登录前选路：探测一次，把 AUTO 的目标路线定下来。
   *
   * 这里**无条件**跟随探测结果（不像 `onNetworkChanged` 只在有会话时切）——
   * 因为紧接着就要在目标路线上建立会话，本来就没有旧会话要保护。
   *
   * @returns 本次登录应该走的模式（显式策略下直接返回该模式，不探测）。
   */
  static async prepareForLogin(): Promise<ConnectionMode> {
    const policy: RoutePolicy = TokenStore.getRoutePolicy();
    if (policy !== RoutePolicy.AUTO) {
      return policy === RoutePolicy.WEBVPN ? ConnectionMode.WEBVPN : ConnectionMode.DIRECT;
    }
    const state: NetworkState = await CampusProbe.probe();
    const target: ConnectionMode = RouteEngine.targetFor(state);
    RouteEngine.pin(target);
    Logger.info('登录选路：探测' + RouteEngine.stateName(state) + ' → ' + target);
    return target;
  }

  /**
   * 登录该认证哪几条路线（对齐上游路由合同「Auto 登录与会话恢复」）。
   *
   * - 显式策略：只认证那一条；
   * - Auto + 校园网：只认证 Direct（WebVPN 在校内没有意义，少一次 CAS）；
   * - Auto + 校外/未知：**主路线在前**，再补另一条。
   *
   * 补另一条不是「多此一举」：登录态是按路线隔离的 Cookie 罐，只登一条的话，
   * 下次换网（宿舍 Wi-Fi ↔ 流量）就必须重新输密码 —— 原版能无感换网，
   * 靠的正是登录时把两条路都灌上。
   */
  static async loginRoutes(): Promise<ConnectionMode[]> {
    const policy: RoutePolicy = TokenStore.getRoutePolicy();
    if (policy === RoutePolicy.DIRECT) {
      return [ConnectionMode.DIRECT];
    }
    if (policy === RoutePolicy.WEBVPN) {
      return [ConnectionMode.WEBVPN];
    }
    const state: NetworkState = await CampusProbe.probe();
    if (state === NetworkState.CAMPUS) {
      return [ConnectionMode.DIRECT];
    }
    const primary: ConnectionMode = TokenStore.getConnectionMode();
    const routes: ConnectionMode[] = [primary];
    routes.push(primary === ConnectionMode.DIRECT ?
      ConnectionMode.WEBVPN : ConnectionMode.DIRECT);
    return routes;
  }

  /**
   * 读请求发生网络层失败后的自适应（对齐上游 `prepare_read_fallback` 的判定）。
   *
   * 判定表（仅 AUTO 策略，其它策略一律 KEEP）：
   * | 探测 | 当前 | 处置 |
   * |---|---|---|
   * | CAMPUS | DIRECT | KEEP —— 刚才只是抖动，别急着切 |
   * | CAMPUS | WEBVPN | 有 DIRECT 会话则升级直连（更快），否则 KEEP |
   * | 校外 | WEBVPN | KEEP —— WebVPN 校外本来就通，是真断网 |
   * | 校外 | DIRECT | 有 WEBVPN 会话 → SWITCHED；没有 → 切并 NEED_RELOGIN |
   *
   * 「校外」= `OFF_CAMPUS` 或 `UNKNOWN`（上游只在重新探测仍是 CAMPUS 时否决回退）。
   */
  static async adaptToNetwork(): Promise<RouteAdapt> {
    const policy: RoutePolicy = TokenStore.getRoutePolicy();
    if (policy !== RoutePolicy.AUTO) {
      return RouteAdapt.KEEP;
    }
    const current: ConnectionMode = TokenStore.getConnectionMode();
    // 先作废缓存再探：必须拿到「此刻」的网络，不能用 3 秒前的旧观察否决回退
    CampusProbe.invalidate();
    const state: NetworkState = await CampusProbe.probe();
    const target: ConnectionMode = RouteEngine.targetFor(state);
    if (target === current) {
      return RouteAdapt.KEEP;
    }
    if (TokenStore.hasLocalSession(target)) {
      RouteEngine.pin(target);
      Logger.warn('网络层失败，已自动切换路线 ' + current + ' → ' + target + '（会话已就绪）');
      return RouteAdapt.SWITCHED;
    }
    if (state === NetworkState.CAMPUS) {
      // 回到校园网但直连没会话（用户一直是 WebVPN）：保持现状，不打断
      return RouteAdapt.KEEP;
    }
    // 目标路线没有会话：先试着用已保存凭据静默补一次（对齐上游换路恢复），
    // 补上了就和「会话已就绪」等价。
    const recovered: boolean = await SessionGuard.ensure(target);
    if (recovered) {
      RouteEngine.pin(target);
      Logger.warn('网络层失败，已切到 ' + target + ' 并静默补登成功');
      return RouteAdapt.SWITCHED;
    }
    // 🔴 补登失败时**不能**把路线钉到空通道：
    // 页面侧的 localMode()/ensureLogin() 是同步判据，看到「当前路没会话」会立刻报
    // 「仅支持本地模式 / 请先登录」，即便另一条路上的会话还活着（校内登录→切流量
    // 时 WebVPN 槽为空，正是这个场景）。保持原路线，让同步判据还能借回活会话。
    Logger.warn('网络层失败，目标路线 ' + target + ' 无会话且补登未成功，保持 ' + current);
    return TokenStore.hasLocalSession(current) ? RouteAdapt.KEEP : RouteAdapt.NEED_RELOGIN;
  }

  /**
   * 网络变化事件（换 Wi-Fi / 开关数据）后的收尾。
   *
   * 只做两件**无副作用**的事：作废探测缓存；若另一条路更合适且**已有会话**则切换。
   * 不会在没有会话的情况下改路线 —— 换网事件常常伴随抖动，
   * 这时候把人踢到一条没登录的路上只会制造「莫名掉线」。
   */
  static async onNetworkChanged(): Promise<void> {
    CampusProbe.invalidate();
    // 断网启动时 onNetworkChanged 也会被 netLost 触发：那时不探测、不补登，
    // 更不能在无网的 CAS 上留下失败冷却，拖慢真正联网后的恢复。
    const online: boolean = RouteEngine.isOnline();
    const justBack: boolean = online && !RouteEngine.lastOnline;
    RouteEngine.lastOnline = online;
    if (!online) {
      return;
    }
    if (justBack) {
      // 断网期间打开过的页面已经停在 ERROR 状态；发一次全局信号让它们各自重试，
      // 否则用户只能手动逐页点「重新加载」。
      AppStorage.setOrCreate<number>(NETWORK_BACK_TICK_KEY, Date.now());
      Logger.info('网络已恢复，通知错误页自动重试');
    }
    if (TokenStore.getRoutePolicy() !== RoutePolicy.AUTO) {
      // 显式路线下没有自动选路可做，但断网启动时被打断的静默补登仍要补一次
      if (justBack) {
        void SessionGuard.ensure(TokenStore.getConnectionMode(), true);
      }
      return;
    }
    const state: NetworkState = await CampusProbe.probe();
    const target: ConnectionMode = RouteEngine.targetFor(state);
    const current: ConnectionMode = TokenStore.getConnectionMode();
    if (target === current) {
      return;
    }
    if (TokenStore.hasLocalSession(target)) {
      RouteEngine.pin(target);
      Logger.info('网络变化后自动切换路线 ' + current + ' → ' + target);
      return;
    }
    // 两条路都没会话 = 还没登录过（登录页会自己处理），这里不抢跑，
    // 否则用户的输入与静默补登会各自跑一遍 CAS。
    if (!TokenStore.hasLocalSession(current)) {
      return;
    }
    // 目标路线没有会话：后台静默补一次，成功才切。
    // 换网/联网恢复是「条件真的变了」，跳过补登冷却（断网启动时的那次失败
    // 不该拖住联网后的第一次恢复）；节流仍由读请求失败路径保留。
    const recovered: boolean = await SessionGuard.ensure(target, true);
    if (recovered) {
      RouteEngine.pin(target);
      Logger.info('网络变化后已切到 ' + target + '（静默补登成功）');
    }
  }

  /**
   * 网络变化事件的**去抖**入口。
   *
   * 换网通常是一串事件（netLost + netCapabilitiesChange + netAvailable 连着来），
   * 不去抖就是连着探好几次网关。1.5 秒内合并成最后一次。
   */
  static notifyNetworkChanged(): void {
    if (RouteEngine.changeTimer >= 0) {
      clearTimeout(RouteEngine.changeTimer);
    }
    RouteEngine.changeTimer = setTimeout(() => {
      RouteEngine.changeTimer = -1;
      void RouteEngine.onNetworkChanged();
    }, 1500);
  }

  private static changeTimer: number = -1;

  /**
   * 启动时的一次性对账（与 `onNetworkChanged` 同规则）。
   *
   * 存在的意义：AUTO 的目标路线可能在上次关掉 App 后就变了
   * （晚上在宿舍连校园 Wi-Fi、白天在教室用流量），启动时校正一次，
   * 首页预取就不会白走一条错路。
   */
  static async reconcile(): Promise<void> {
    await RouteEngine.onNetworkChanged();
  }

  /**
   * 会话优先：锁定路线没有会话而另一条有，就先回到有会话的那条。
   *
   * 一个必须堵住的角落：故障切换会把路线钉到「目标路」（哪怕那条还没登录，
   * 见 `adaptToNetwork` 的 NEED_RELOGIN），用户没重登就关了 App。
   * 再打开时若网络已经回来，钉的却还是那条没会话的路 —— 登录页会平白出现，
   * 而**另一条路上的会话其实还活着**。
   *
   * 这里不探测网络、不发请求，纯粹是「别把活会话当没有」，同步完成。
   * 除启动判定外，**所有本地业务请求的入口**（`ApiService.localMode()`、
   * `UpstreamClient.sendOnce()`、图书馆座位会话检查）都会调用它，
   * 这样换网后即使路线暂时钉错，也不会出现「全服务加载不出来」。
   */
  static ensureSessionRoute(): void {
    if (TokenStore.getRoutePolicy() !== RoutePolicy.AUTO) {
      return;
    }
    const current: ConnectionMode = TokenStore.getConnectionMode();
    if (TokenStore.hasLocalSession(current)) {
      return;
    }
    const other: ConnectionMode =
      current === ConnectionMode.DIRECT ? ConnectionMode.WEBVPN : ConnectionMode.DIRECT;
    if (TokenStore.hasLocalSession(other)) {
      RouteEngine.pin(other);
      Logger.info('锁定路线无会话而 ' + other + ' 有，自动切回 ' + other);
    }
  }

  /** 探测结论 → 目标路线（上游 `resolve_route` 的 Auto 分支：校外优先 WebVPN）。 */
  private static targetFor(state: NetworkState): ConnectionMode {
    return state === NetworkState.CAMPUS ? ConnectionMode.DIRECT : ConnectionMode.WEBVPN;
  }

  /** 落盘当前实际模式（重启沿用，避免冷启动必探一次）。 */
  private static pin(mode: ConnectionMode): void {
    TokenStore.setAutoPinnedMode(mode);
  }

  /**
   * 系统层面是否有可用默认网络。官方约定：无网络时 `getDefaultNetSync()` 的 netId 为 0。
   * 这里必须是**系统网络可用性**，不能拿 `CampusProbe` 的结果代替 —— 后者在
   * 「校外但联网」和「完全断网」两种情况下都返回 OFF_CAMPUS。
   */
  private static isOnline(): boolean {
    try {
      return connection.getDefaultNetSync().netId !== 0;
    } catch (error) {
      // 权限/系统异常时按在线处理，避免把真实的网络恢复误判掉
      return true;
    }
  }

  private static stateName(state: NetworkState): string {
    if (state === NetworkState.CAMPUS) {
      return '校园网';
    }
    if (state === NetworkState.OFF_CAMPUS) {
      return '校外';
    }
    return '未知';
  }

  /** 供界面展示的当前网络描述（自动策略下才有意义）。 */
  static describeCurrent(): string {
    const policy: RoutePolicy = TokenStore.getRoutePolicy();
    if (policy !== RoutePolicy.AUTO) {
      return '';
    }
    const mode: ConnectionMode = TokenStore.getConnectionMode();
    return mode === ConnectionMode.DIRECT ? '当前走校内直连' : '当前走 WebVPN';
  }

  /** 显式切换策略（手动模式 / 自动）。显式模式同时把实际路线锁死。 */
  static setPolicy(policy: RoutePolicy): void {
    TokenStore.setRoutePolicy(policy);
    CampusProbe.invalidate();
    if (policy === RoutePolicy.DIRECT) {
      TokenStore.setAutoPinnedMode(ConnectionMode.DIRECT);
    } else if (policy === RoutePolicy.WEBVPN) {
      TokenStore.setAutoPinnedMode(ConnectionMode.WEBVPN);
    }
  }

  /**
   * 切换策略并**返回**随之生效的实际路线（登录页选完立刻要显示）。
   */
  static resolvePolicy(policy: RoutePolicy): ConnectionMode {
    RouteEngine.setPolicy(policy);
    return TokenStore.getConnectionMode();
  }

  /**
   * 直接锁定实际路线（不动用户策略）。
   *
   * 只有「登录时网络层失败后的换路重试」该用它 —— 那是在**建立会话的路上**换路，
   * 用户策略仍然是自动，下次进来还会重新探测。
   */
  static pinMode(mode: ConnectionMode): void {
    TokenStore.setAutoPinnedMode(mode);
    CampusProbe.invalidate();
  }
}
