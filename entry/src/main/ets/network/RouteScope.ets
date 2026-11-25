import { ConnectionMode } from '../common/AppConfig';
import { TokenStore } from './TokenStore';

/**
 * 请求路线的作用域覆盖（对齐上游「每个 runtime 私有 Cookie 罐」的最小实现）。
 *
 * 全应用取路线只有一个口：`TokenStore.getConnectionMode()` —— 它返回**全局钉住**
 * 的那一条。这对「同时只登一条路线」是够用的，但双路线登录需要在**另一条路线上**
 * 跑完整套 CAS 流程（取页 → 提交 → 逐跳跟随 → 吸收 Cookie → 落槽），
 * 而全局钉住的仍是主路线。
 *
 * 所以登录（以及路由层的静默重认证）在进入某条路线的流程前 `enter(mode)`，
 * 期间所有请求地址改写、Cookie 读写、会话落盘都按这条路线走，退出即还原。
 *
 * 🔴 **只能在「没有并发业务请求」的窗口里用**：它是进程级单值，不是协程上下文。
 * 目前的两个使用点都满足 —— 登录页（尚未进入主页）与静默重认证（本身就是
 * 恢复动作，`SessionGuard` 会挡住重入）。
 */
export class RouteScope {
  /**
   * 作用域栈。登录预热可能重入（aboutToAppear 的 warmUp 还没回来，用户在 doLogin 里
   * 又触发一次），单值实现会被先结束的那次 `exit()` 提前清掉，后一次剩下的请求
   * 失去保护、被全请求入口的兜底拉回另一条路线，拿到不匹配的令牌/Cookie。
   */
  private static modes: ConnectionMode[] = [];

  /** 本次请求/读写实际该走的路线：栈顶优先，否则取全局钉住值。 */
  static mode(): ConnectionMode {
    return RouteScope.modes.length === 0 ?
      TokenStore.getConnectionMode() : RouteScope.modes[RouteScope.modes.length - 1];
  }

  /** 是否处于覆盖窗口内（此时禁止网络层自动换路，否则会与登录流程抢路线）。 */
  static isScoped(): boolean {
    return RouteScope.modes.length > 0;
  }

  /** 进入某条路线的流程。调用方必须用 `try/finally` 配对 `exit()`。 */
  static enter(mode: ConnectionMode): void {
    RouteScope.modes.push(mode);
  }

  /** 退出最内层覆盖窗口，恢复到外层作用域或全局钉住的路线。 */
  static exit(): void {
    if (RouteScope.modes.length > 0) {
      RouteScope.modes.pop();
    }
  }
}
