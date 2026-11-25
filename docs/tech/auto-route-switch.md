# 登录自动切换「校园网直连 / WebVPN」——可行性研究与实现

> 2026-11-17 · 对应上游 `BUAASubnet/UBAA` 的 `RoutePolicy::Auto` 体系
> 实现文件：`network/CampusProbe.ets`、`network/RouteEngine.ets`、`UpstreamClient`、
> `TokenStore`、`pages/auth/LoginPage`、`pages/mine/SettingsPage`、`EntryAbility`

## 一、上游源码定位

功能在上游叫**路线策略（Route Policy）**，不叫「登录切换」。相关文件：

| 文件 | 职责 |
|---|---|
| `crates/ubaa_core/src/connection.rs` | 网关探测 `SystemGatewayProbe`、三态 `NetworkState`、`resolve_route()`、3 秒缓存 `CachingGatewayProbe` |
| `crates/ubaa_core/src/connection/control.rs` | 换网时撤销在途读取（读取取消，不影响已发送的写入） |
| `crates/ubaa_core/src/facade/routing.rs` | `read_with_fallback!`（读失败回退）、`resolve_operation()`（每次操作前选路） |
| `crates/ubaa_core/src/facade/routing/domains.rs` | 校外域名名单 + 24 小时 WebVPN 偏好记忆 |
| `crates/ubaa_core/src/domain/route.rs` | `ConnectionMode{Direct,WebVpn}`、`RoutePolicy{Auto,Direct,WebVpn}` |
| `crates/ubaa_core/src/facade/interactive_auth/quiet.rs` | 登录选路：「校园网只准备 Direct，校外 Auto 准备两条独立路线」 |
| `docs/contracts/route-policy.md` | 官方契约（探测参数、回退判据、域名名单依据） |

### 上游的关键判定（原文语义）

1. **网关探测**：对 `gw.buaa.edu.cn:80` 做 **TCP 连通性**测试（不发 HTTP/TLS、不带凭据），
   单次总预算 **500ms**，结果缓存 **3 秒**；只有解析到 **`10.0.0.0/8`** 的 IPv4 才算校园网证据
   —— 代理的 fake-ip（`198.18.0.0/15`）会让任意 TCP 连接成功，必须排除。
2. **三态结论**：`Campus` / `OffCampus` / `Unknown`。解析失败、无地址、连接失败/超时均为
   `OffCampus`；只有探测自身内部失败才是 `Unknown`。
3. **Auto 初选**：校园网 → Direct；校外 → 视域名名单（部分域名校外必须走 WebVPN）。
4. **读回退**：只有**读**遇到网络不可达/超时才在另一条路重试一次；认证失败、业务拒绝、
   解析错误、5xx **一律不回退**；**写入永不自动重发**。
5. **就绪预检**：初选 Direct 但 Direct 还没登录、而 WebVPN 已登录时，直接换 WebVPN。
6. **域名记忆**：某域名 Direct 网络失败而 WebVPN 成功后，记 24 小时偏好；回校园网即清空。
7. **登录**：校外 Auto **并发**认证 Direct 与 WebVPN 两条独立路线（`DualLoginInput`），
   至少一条就绪即可进入应用；校园网只认证 Direct。

## 二、HarmonyOS 可行性结论

| 上游能力 | 鸿蒙对应 | 结论 |
|---|---|---|
| TCP 连接探测（带超时） | `socket.constructTCPSocketInstance()` + `connect({address, timeout})`（`@kit.NetworkKit`，`Promise<void>`） | ✅ 已核对 SDK d.ts：`TCPConnectOptions.timeout` 单位 ms，默认 5000 |
| 只认 10.x 私网地址 | 先 `connection.getAddressesByName(host)` 拿全部 IP，再过滤首字节 `10` | ✅ 需 `ohos.permission.INTERNET`（已有） |
| DNS 无超时参数 | 外层 `Promise.race` 加截止时间 | ✅ |
| 3 秒缓存 + 单飞 + 换网作废 | 进程内静态缓存 + `inflight` Promise + revision 计数 | ✅ |
| 换网事件 | `connection.createNetConnection()` + `register()` + `on('netAvailable'/'netCapabilitiesChange'/'netLost')` | ✅ 需 `ohos.permission.GET_NETWORK_INFO`（已有） |
| 读回退 | `UpstreamClient.send` 包一层：网络层失败且是读 → 切路重试一次 | ✅ |
| 双会话并行登录 | 两次 CAS 登录（同账号） | ⚠️ **不做**，见下 |

**无需新增权限、无需新增依赖。**

## 三、采用的方案与刻意差异

### 核心设计：策略与「实际路线」分层

- `RoutePolicy`（用户意图，**程序不许改**）：`AUTO` / `DIRECT` / `WEBVPN`，默认 `AUTO`。
- `ConnectionMode`（本次实际走哪条）：AUTO 下由 `RouteEngine` 维护一个**锁定值**
  （`PREF_AUTO_PINNED_MODE`，与策略分开存）。
- 其余 30 多处调用点继续只读 `TokenStore.getConnectionMode()`，**零改动、无感知**。

这是本次实现最关键的取舍：把「策略」与「结论」分成两个键，避免出现
「程序偷偷改了用户设置」；同时把改动半径压到最小。

### 判定表（`RouteEngine`）

**登录前**（`prepareForLogin`）：探测 → 校内 Direct / 校外 WebVPN，无条件跟随
（马上要建会话，没有旧会话要保护）。若预热令牌属于旧路线 → 丢弃重新预热。

**读请求网络层失败后**（`adaptToNetwork`）：先作废缓存**重新探测**（不能用旧观察否决回退）：

| 探测 | 当前 | 处置 |
|---|---|---|
| 校内 | DIRECT | KEEP（只是抖动） |
| 校内 | WEBVPN | 有 DIRECT 会话则升级直连，否则 KEEP |
| 校外 | WEBVPN | KEEP（WebVPN 校外本来就通，是真断网） |
| 校外 | DIRECT | 有 WEBVPN 会话 → SWITCHED（重试一次）；没有 → 保持 DIRECT，后台补登失败则保留原错误（11-25 起不再钉空通道） |

**换网事件 / 回前台**（`onNetworkChanged`）：只作废缓存；**仅当目标路线已有会话**才切换
（换网伴随抖动，把人踢到一条没登录的路只会制造「莫名掉线」）。

**启动 / 每个业务请求入口**（`ensureSessionRoute`）：锁定路线没有会话而另一条有 →
直接切回有会话的那条（同步、无请求）。除 Index 启动判定外，`ApiService.localMode()`、
`UpstreamClient.sendOnce()`、图书馆座位会话检查都会调用，堵住「换网后全线加载失败」。

### 与上游的关系：双槽会话 + 静默重认证（2026-11-22 补齐）

> 本节替换了 2026-11-20 之前的「单会话、不做双路线登录」结论。旧结论的两条理由
> 经核对上游 2.0.3 源码后需要修正，详见 `docs/tech/session-dual-route.md`。

上游校外 Auto 登录时**顺序**（不是并发：`facade/auth.rs::login` 是 for + await）
认证 Direct 与 WebVPN，两套会话分别落在 `session.json` 的两个槽位；之后任何一条路
缺会话，都用**已授权保存的凭据**在后台静默补登。这就是「换网、冷启动都不用重登」的
全部原因（另一半是冷启动先进首页、后台再校验）。

本实现现在同构：

- `LocalAuthService.loginDual()`：按 `RouteEngine.loginRoutes()` 决定的路线集合顺序登录，
  主路线失败照旧抛错，副路线失败只登记（`partial`），不阻塞；
- `RouteScope`：请求/取 Cookie/落槽都按「当前作用域路线」走，使一条流程能在另一条
  路线上完整跑完；
- `SessionGuard`：目标路线缺会话时用保存凭据静默补登（按路线单飞、验证码即停、
  主动退出后禁止）；
- 冷启动仍是「先进主页 + 后台自检」，401 时先 `SessionGuard` 再决定是否回登录页。

顺序双登录 = 两次 CAS。这与官方客户端完全一致，不再视为「锁号风险」；真正需要避免的是
**并发**提交同一账号的凭据（上游也没有这样做）。

### 11-25 修复：校内登录 → 切流量后「所有服务加载不出来」

现象：校园网进 App 后切到蜂窝，除空闲教室外全部服务偶发加载失败，
报「博雅课程仅支持本地（校内直连 / WebVPN）模式」「加载楼馆失败：请先登录后再使用…」。
根因不在单个页面，而是一条同步判据链：

1. 校园网登录时 `loginRoutes()` 只认证 Direct，WebVPN 槽为空；
2. 切流量后的首个读请求失败，`adaptToNetwork()` 探测到校外并把路线**钉到无会话的 WebVPN**
   （`NEED_RELOGIN` 分支）。此时另一条路上的 Direct 会话其实还活着；
3. 之后每个页面都在发请求前用 `ApiService.localMode()` / `ensureLogin()` 判「当前路有没有会话」，
   得到 false 就直接抛「仅支持本地 / 请先登录」。因为**没有发请求**，
   `UpstreamClient` 的自动换路重试永远不会触发，用户反复点「重新加载」也没有自愈机会。

修复三层：

- **不钉空通道**：`adaptToNetwork()` 静默补登失败后保持当前路线（当前有会话返回 `KEEP`），
  只有两条路都没会话才返回 `NEED_RELOGIN`；
- **同步借回活会话**：`ensureSessionRoute()` 提升为全请求入口兜底
  （`ApiService.localMode()`、`UpstreamClient.sendOnce()`、图书馆座位 `ensureLogin()`），
  换网后的下一个请求就能用回有会话的那条路；
- **补登节流 + 作用域保护**：`SessionGuard` 失败冷却 5 秒（同一路线单飞照旧），
  显式 401 自检可 `force` 跳过；登录页预热纳入 `RouteScope`，
  避免全局兜底把预热令牌拉回另一条路线导致「凭据无效」。
  `RouteScope` 同时由单值改为栈，预热重入时先结束的那次不会提前解除另一次的作用域。

### 11-25 第二例：断网启动，之后才接入网络

断网时启动，所有读请求失败 → `adaptToNetwork()` 在无网状态下尝试 CAS 补登并记下失败冷却；
用户随后联网时，网络变化事件里的补登可能被 5 秒冷却挡掉，而断网期间已经停在 ERROR
状态的页面也不会自己重试，于是表现为「联网了依然全部加载不出来」。

修复：

- `RouteEngine` 用官方 `connection.getDefaultNetSync().netId !== 0` 区分「校外但联网」
  与「完全断网」（`CampusProbe` 两者都回 OFF_CAMPUS，不能代替）；断网事件里只作废缓存，
  不探测、不补登，避免留下无谓的失败冷却。
- 检测到「无 → 有」时：跳过补登冷却强制恢复一次；同时写 `networkBackTick` 到 AppStorage。
- `ErrorView` 订阅该键，所有仍挂载的错误页自动调用各自的 `onRetry()`。
  已逐一核对 23 处 `ErrorView` 的重试回调都是读操作，不会重发写请求（签到、预约、提交等）。

### 未实现（有意留待后续）

| 项 | 上游 | 原因 |
|---|---|---|
| 校外域名名单（6 个域名强制 WebVPN） | `OFF_CAMPUS_WEBVPN_DOMAINS` | 我们用探测结论决定整条路线，不按域名分流；校外统一走 WebVPN 仍能覆盖 |
| 域名级 24h WebVPN 偏好记忆 | `domain_routes.json` | 同上 |
| 读取中途换网取消在途请求 | `connection/control.rs` | 需要 per-request 取消令牌；现有超时（连接 10s / 读 30s）已能兜底 |
| 分路线验证码交互（第二条路线弹独立验证码） | `InteractiveRouteState` | 副路线验证码不阻塞主流程；需要时由门卫转人工，一次只弹一个 |

## 四、性能

- 探测成本：1 次 DNS + 最多 N 次 TCP 握手，**总预算 500ms**；缓存 3 秒 + 单飞，
  登录、启动、换网、故障切换同时触发也只探一次。
- 触发点仅三处：登录前、读请求网络失败后、换网事件（去抖 1.5s）。
  成功路径**零开销**（只在 catch 分支里做）。
- `getConnectionMode()` = 2 次 preferences 内存读（`getSync` 不落盘），无感知。
- 探测**不发 HTTP/TLS、不带任何凭据**，不会被登录墙/重定向/证书干扰，也不泄露会话。

## 五、真机验收清单

1. **设置 → 连接方式 → 自动**，登录页显示「自动（当前：校内直连 / WebVPN）」。
2. 校内（连校园网/校园 VPN）登录：应走直连；`hilog | grep 登录选路` 能看到「探测校园网 → DIRECT」。
3. 关掉校园网（用流量）登录：应自动走 WebVPN 并登录成功。
4. 校内登录成功后切到流量，刷新课表 / 博雅 / 图书馆座位：若之前登过 WebVPN 就直接成功；
   没登过时应保持 Direct 会话可用（不再出现「仅支持本地 / 请先登录」），
   同时后台尝试静默补登 WebVPN；补登不了才在真正需要时提示重新登录。
5. 锁定「校内直连」时在流量下登录：应报错并提示「请切到『自动』或 WebVPN 模式」。
6. 写操作（作业提交/评教/签到）在任何情况下都**不应**被自动重发（日志里不出现两次同请求）。
