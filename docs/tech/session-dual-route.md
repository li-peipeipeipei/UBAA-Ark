# 会话双槽与静默重认证（2026-11-22）

对齐上游 UBAA 2.0.3 的会话模型。出发点是真机反馈的两个现象：

- **应用外换网后冷启动**：原来在校内登录（只登了 Direct），回家打开就要重新输密码；
- **应用内换网**：WebVPN ↔ 直连切换同样掉回登录页。

上游在同一台手机上从不需要重登。本文记录「为什么」与「我们怎么补齐」。

## 一、上游为什么不需要重登

| # | 机制 | 证据 |
|---|---|---|
| 1 | 一次登录认证两条路线 | `crates/ubaa_core/src/facade/auth.rs::login`：`for route in [Direct, WebVpn]` 顺序 await，返回 `LoginReadiness::{AllReady, Partial, NoneReady}` |
| 2 | 双槽持久化，Cookie 不跨槽 | `session/coordinator.rs::DualSessionCoordinator`；`session.json` schema v2 有 `direct` / `webvpn` 两个独立槽位与独立 revision |
| 3 | 冷启动只校验当前所需路线 | `docs/contracts/route-policy.md`「Auto 登录与会话恢复」：其他槽位继续保留 |
| 4 | 缺会话时用**已授权凭据**静默补登 | `packages/ubaa_app/lib/src/services/session_recovery.dart::_SharedLogin`：门槛 `saved.isUsable && saved.autoLogin && saved.username == scope.expectedUsername`，按「账号+路线」单飞；验证码/凭据拒绝才转人工 |

补充两点容易被忽略的设计：

- **主动退出需要一个独立标记**。退出只清会话、保留「记住密码」，若不区分，
  静默重认证会在退出后立刻把人登回来（上游用 `SessionRecoveryStatus.signedOut` 表达）。
- **换网不急着改路线**。Auto 下优先 Direct，只有读请求真的网络失败才回退 WebVPN；
  校内↔校外多数时候连路线都没变，会话自然不失效。

## 二、我们的实现

| 文件 | 职责 |
|---|---|
| `network/RouteScope.ets` | 请求/取 Cookie/落槽的路线作用域覆盖（`TokenStore` 的会话与 Cookie 本来就是 `modeScopedKey` 分槽存的，只缺「在另一条路线上跑流程」的能力） |
| `network/LocalAuthService.ets` | `loginDual()` 顺序登录两路；`PreparedLogin.mode` 保证一次性令牌不跨路线复用；`logout()` 对两条有会话的路线各注销一次 |
| `network/SessionGuard.ets` | 目标路线缺会话时静默补登：先 `validate()`，`TRANSIENT` 保留会话；无授权（含主动退出）直接返回 false；按路线单飞；验证码即停 |
| `network/RouteEngine.ets` | `loginRoutes()` 决定认证哪几条（校园网只 Direct，校外两路）；`adaptToNetwork()` / `onNetworkChanged()` 在目标路线无会话时先补登再决定是否要求人工登录 |
| `pages/Index.ets` | 401 时先 `ApiService.ensureSession()`，失败才回登录页，且只清当前路线的槽位 |
| `pages/auth/LoginPage.ets` | 无本地会话但凭据可用时替用户提交一次（主动退出除外） |

### 路线集合规则（`RouteEngine.loginRoutes`）

| 策略 / 网络 | 认证路线 | 主路线 |
|---|---|---|
| 显式 Direct / WebVPN | 仅该条 | 该条 |
| Auto + 校园网 | `[DIRECT]` | DIRECT |
| Auto + 校外 / 未知 | `[主, 备]` | 当前钉住的那条 |

校外把 Direct 也灌满不是浪费：上游 Auto 优先 Direct，只有 Direct 网络失败才回退，
直连槽有会话时回退是**零登录等待**的。

### 失败语义

- 主路线失败：照旧抛出（`CaptchaRequiredError` / `ApiError`），登录页展示；
- 副路线失败：只登记 `RouteLoginState.{NEEDS_CAPTCHA, FAILED}`，**不阻塞**已就绪的主通道
  （对应上游 `partial`，合同只要求「至少一条就绪」）；
- 串行、不并发：与上游一致。真正要避免的是并发提交同一账号凭据。

## 三、踩过的坑

1. **一次性令牌不能跨路线**：`prepared` 是进程级单例，双路线登录必须校验它属于哪条路线
   （`PreparedLogin.mode`），否则会拿 WebVPN 的 `execution` 去 Direct 提交。
2. **作用域内禁止自动换路**：`UpstreamClient.send` 失败时的 `adaptToNetwork` 会与正在
   进行的 CAS 流程抢路线，`RouteScope.isScoped()` 为真时一律保留原错误。
3. **静默重认证的重入**：它本身会产生请求，`ensure()` 在作用域内直接返回现状，不再递归；
   跨调用靠按路线的单飞表合并。
4. **上游暂时不可用 ≠ 会话失效**：`validate()` 返回 `TRANSIENT` 时保留会话，
   否则一次网络抖动就会清掉本地会话、逼出登录页。
