# 登录链路与 2.0.2 对齐审计（2026-11-18）

> 上游基准：`BUAASubnet/UBAA` **v2.0.0** 与 **v2.0.2**（本地 `C:/Users/Lipeipeipeipei/Downloads/UBAA-2.0.2.zip`）
> 对照版本：v1.7.2（本工程最初移植的 Kotlin 版本，`LocalConnectionAuth.kt`）
> 结论先给：**验证码处理此前与 2.0.x 不一致，已按 2.0.2 重写**；其余差异见下表。

## 0. 两个基准版本的关系

对 `crates/ubaa_core/src/auth/*` 与 `upstream/*` 逐文件 diff，**v2.0.0 → v2.0.2 只多了
`#[track_caller]` 属性**，没有任何行为差异。因此下文「2.0.2 的行为」等同于「2.0.0 的行为」。

## 1. 原版 2.0.2 的登录链路

```
GET  sso/login                          → 准备页：execution + 可选 captchaId（成对）
├─ 无验证码  → POST sso/login            （页面隐藏域 + username/password/submit/execution/_eventId/type）
└─ 有验证码  → GET  sso/captcha?captchaId=…
             → POST sso/login            （八字段：username/password/captcha/captchaResponse/execution/_eventId/submit/type）
→ 逐跳跟随 3xx（每跳解包 WebVPN 地址、按需 HSTS 升级）
→ WebVPN：GET sso/login?service=d.buaa.edu.cn/login?cas_login=true
          → 处理网关 /token-login 自指回调 → GET d.buaa.edu.cn/ 确认网关会话
→ 身份核验：GET sso/login?service=byxt… → 302 取 ticket
          → GET sso/serviceValidate?service=…&ticket=…&format=JSON
```

关键实现位置：

| 环节 | 文件 |
|---|---|
| 准备 / 提交 / 跳转判定 | `crates/ubaa_core/src/auth/mod.rs` |
| 验证码准备与一次性提交 | `crates/ubaa_core/src/auth/interactive.rs` |
| 验证码页面形态校验 | `crates/ubaa_core/src/upstream/interactive_auth.rs` |
| 验证码自动识别（3 次预算） | `crates/ubaa_core/src/auth/automatic.rs`、`captcha.rs` |
| 取图与图片校验 | `crates/ubaa_core/src/auth/captcha_image.rs` |
| WebVPN 网关激活 | `crates/ubaa_core/src/auth/gateway.rs` |
| 身份核验（验票） | `crates/ubaa_core/src/auth/sso_identity.rs` |

## 2. 原版在 WebVPN 下**有**验证码

事实依据（上游 `docs/protocol/parity/auth-session.md`，第 87–92 行）：

- 「准备图像验证码：沿用 HTTPS SSO `/login`，**Direct 和 WebVPN 各自使用原路线 Cookie**」
- 「获取或刷新图片：**同路线** `/captcha`，业务参数 `captchaId`」
- 「提交验证码：**同一路线** SSO `/login`，成功后执行本页的网关激活与 SSO 身份校验」
- 「**真实 WebVPN 每次 GET 都轮换 captchaId 和 execution**，浏览器直接提交取图时的
  execution。**按来源裁决取消提交前 GET**」

也就是说：验证码不是 Direct 专属，WebVPN 下同样会出现；取图、提交全部经网关
（`runtime.url()` 统一改写），Cookie 用该路线自己的罐。2.0.x 额外做了**本地 ONNX 离线识别**，
静默最多试 3 次，耗尽才转人工输入。

## 3. 本轮发现的不一致（修复前）

| # | 问题 | 后果 |
|---|---|---|
| 1 | `login()` 一进来就重新 GET 登录页，再用预热拿到的 `execution` 提交验证码 | 服务端已换掉 captchaId/execution，**答案与令牌错位，验证码怎么输都错** |
| 2 | 验证码被拒（401 + 同一句「用户名或密码错误。」+ 新挑战）被归类为密码错误 | 引导用户反复改密码，方向完全错 |
| 3 | 没有「未知交互步骤」判定 | 页面出现 slider/OTP/MFA 时仍按 image 提交，必然失败且报错指向凭据 |
| 4 | 未激活 WebVPN 网关自身会话 | 网关是独立 CAS 客户端，部分站点会被网关自己的登录页拦住 |
| 5 | WebVPN 登录失败不重试 | 2.0.2 对「明确凭据拒绝 / 网络 / 超时 / 上游不可用」追加一次整链重试 |
| 6 | 会话校验用 `uc/status` | 2.0.x 改用「教务取票 + serviceValidate」，UC 与 CAS 是两套会话 |
| 7 | 验证码图片无格式/尺寸/大小校验 | 网关错误页会被当成图片塞进 `Image` |

## 4. 本轮改动

| 文件 | 改动 |
|---|---|
| `network/LocalAuthService.ets` | 重写：准备页状态（`PreparedLogin`）缓存；**提交验证码不再重新 GET**；验证码被拒单独归类并下发新挑战；新增网关激活；WebVPN 整链重试一次；会话校验改 `serviceValidate`；图片带随机参数绕缓存 |
| `network/CasParser.ets` | 新增 `captchaType()`（只认 `image`）与 `unsupportedInteraction()`（封闭世界边界，见下） |
| `pages/home/HomePage.ets` | 见第 6 节（主页版式） |

`unsupportedInteraction()` 的边界（对齐 2.0.2 `has_unsupported_login_controls`）：
拒绝 `config.mfa/otp/verification/verify/challenge`、`select`/`textarea`/`button`、
未命名可见输入、以及除 `captcha`/`captchaResponse` 之外的非隐藏/非提交类输入。

## 5. 仍存在的差异（有意保留）

| 差异 | 原因 |
|---|---|
| 无 ONNX 验证码自动识别（2.0.2 有，3 次预算） | 需要打包 ~ 数 MB 模型与 ArkTS 侧推理；本工程仍为**人工输入**，与原 1.7.2 一致 |
| 保留 UC 会话激活（2.0.2 已移除） | 「个人信息」页直接读 `uc/api/uc/userinfo`，去掉会让资料页 401 |
| 登录成功后不缓存登录页，也不做「自动登录静默重试」编排 | 属于 App 层（Flutter bridge）职责，本工程登录页已是单入口 |
| 会话校验没有「身份代次」编号 | 单账号客户端，无并发路线编排需求 |

## 6. 主页版式（同一轮）

- 顺序改为：问候语 → 考试倒计时 → **今日课程 → 最近使用 → 待办**（待办移到最近使用下方）。
- 三块统一走 `SectionCard`（同一套标题排版 / 卡片底色 / 圆角 / 内边距 / 行间分隔线 /
  `EmptyView` 空态），不再是「一张卡片 + 两段裸文字」。

## 7. 待真机验收

| 项 | 方法 | 状态 |
|---|---|---|
| 主页三块版式一致 | 真机截图比对 | ⏳ 设备锁屏（皮套模式），`aa start` 返回 10106102 |
| 无验证码登录（直连 / WebVPN） | 真机登录 | ⏳ 需手动输入密码 |
| 需要验证码时的登录 | 连续输错密码触发 `config.captcha` | ⏳ 同上 |
| 会话恢复（重启应用） | 杀进程重进 | ⏳ 同上 |
