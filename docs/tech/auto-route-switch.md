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
| 校外 | DIRECT | 有 WEBVPN 会话 → SWITCHED（重试一次）；没有 → 切换并提示重新登录 |

**换网事件 / 回前台**（`onNetworkChanged`）：只作废缓存；**仅当目标路线已有会话**才切换
（换网伴随抖动，把人踢到一条没登录的路只会制造「莫名掉线」）。

**启动**（`ensureSessionRoute`）：锁定路线没有会话而另一条有 → 直接切回有会话的那条
（同步、无请求，堵住「故障切换钉到未登录路线后用户关掉了 App」的角落）。

### 🔴 与上游的最大差异：单会话，不做并发双登录

上游校外 Auto 登录时**并发**认证 Direct 与 WebVPN 两条路线，之后每次请求各自用各自
的会话（`read_with_fallback` 能直接切到已就绪的那条）。我们**不做**，理由：

1. **账号安全**：同账号两次并发 CAS 登录会翻倍认证请求，可能触发验证码/风控/锁号。
   本项目把「账号锁死风险」列为红线（研讨室预约因此整项不做），不值得为速度冒险。
2. **架构代价**：双会话要求登录 UI 也能表达「两条路各自的登录状态/验证码」
   （上游为此有 `DualLoginInput`、`InteractiveRouteState` 一整套状态机），鸿蒙登录页是
   单表单，改造面大。
3. **收益有限**：单会话下校外统一走 WebVPN，**功能全都能用**，只是都经过网关转发，
   比「部分域名直连」略慢。可靠性优先于速度。

因此本实现的语义是：**登录时选一条对的路；网络变了自动切到另一条有会话的路；
两条都通向「重新登录」时给出准确提示**，而不是「两路并行谁快用谁」。

### 未实现（有意留待后续）

| 项 | 上游 | 原因 |
|---|---|---|
| 校外域名名单（6 个域名强制 WebVPN） | `OFF_CAMPUS_WEBVPN_DOMAINS` | 只在双会话下有意义；单会话下校外统一走 WebVPN，名单无处生效 |
| 域名级 24h WebVPN 偏好记忆 | `domain_routes.json` | 同上 |
| 读取中途换网取消在途请求 | `connection/control.rs` | 需要 per-request 取消令牌；现有超时（连接 10s / 读 30s）已能兜底 |
| 静默凭据重登 | 共同恢复服务 | 只做「记住密码回填」，不自动提交凭据（上游也要求显式许可） |

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
4. 校内登录成功后切到流量，刷新课表：应自动切到 WebVPN（若之前登过 WebVPN 就直接成功；
   没登过则提示「请重新登录」，重新登录后即通）。
5. 锁定「校内直连」时在流量下登录：应报错并提示「请切到『自动』或 WebVPN 模式」。
6. 写操作（作业提交/评教/签到）在任何情况下都**不应**被自动重发（日志里不出现两次同请求）。
