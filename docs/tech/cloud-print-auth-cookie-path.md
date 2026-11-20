# 云打印「登录不上」根因：Cookie Path 分裂（2026-11-20）

## 现象

进入「云打印」直接停在 `ErrorView`：

> 云打印需要有效的学校登录，请重新登录后再试

按钮「重新加载」无效，重进无效。

## 排查路径

### 1. 先看 CAS 链路是否走通

真机 hilog（`hilog -x` 过滤 `UBAA`）显示票据链**完全正常**：

```
GET  /client/new/cprintPc/cprint.html                      -> 200
POST /api/client/Auth/Check                                -> 200  code=4
GET  /api/client/Auth/SSoPage?backurl=…                    -> 200  （返回起始 URL）
GET  /authcenter/toLoginPage?redirectUrl=…                 -> 302  → sso/login
GET  sso.buaa.edu.cn/login?service=…doAuth/<id>            -> 302  → doAuth?ticket=ST-…
GET  /authcenter/doAuth/<id>?ticket=ST-…                   -> 302  → SSOLogin
GET  /api/client/Auth/SSOLogin?…&uniToken=…                -> 302  → UniEntry
GET  /api/client/Auth/UniEntry?SessionId=…&Func=…          -> 302  → cprint.html
GET  /client/new/cprintPc/cprint.html                      -> 200
POST /api/client/Auth/Check                                -> 200  code=4  ← 仍判未登录
```

所以**不是**重定向、不是票据、不是 WebVPN 改写的问题（本机为校内直连）。

### 2. 拿到 `Auth/Check` 的真实响应体

加临时诊断日志后拿到：响应本身是正常 JSON，不是空体、不是 HTML：

```json
{"code":4,"message":"无效会话，未登录","result":null}
```

即请求形态没问题，是服务端**不认这个会话**。

### 3. 关键：CAS 每一跳都没有下发 `Set-Cookie`，而罐里已有同名旧值

逐跳打印 `Set-Cookie` 条数与「本次实际发出的 cookie 名」：

```
Set-Cookie[/api/client/Auth/SSoPage]  ：无 / OSESSIONID,SESSIONID,SESSIONID,OSESSIONID
Set-Cookie[/api/client/Auth/SSOLogin] ：无 / OSESSIONID,SESSIONID,OSESSIONID
Set-Cookie[/api/client/Auth/UniEntry] ：无 / SESSIONID,SESSIONID,OSESSIONID,OSESSIONID
Set-Cookie[/api/client/Auth/Check]    ：无 / _zte_cid_,OSESSIONID,SESSIONID,SESSIONID,OSESSIONID
```

一次请求带上**两个 `SESSIONID`、两个 `OSESSIONID`**。再看罐内明细：

```
SESSIONID@/api/client/Auth, OSESSIONID@/api/client/Auth,
OSESSIONID@/, SESSIONID@/client/new/cprintPc, SESSIONID@/
```

同名 cookie 被拆成 3 份（`/`、`/api/client/Auth`、`/client/new/cprintPc`），值互不相同。
服务端解析 `SESSIONID=a; SESSIONID=b` 时取到的是**旧的那个**，于是「无效会话」；
而 CAS 侧看到请求已带 `SESSIONID`，就不再下发新的 → 死循环。

## 根因

`UpstreamClient` 在 `Set-Cookie` **未声明 `Path`** 时，按 RFC 6265 §5.1.4 的
default-path 把 cookie 钉在**请求路径的目录级**：

| 请求 | default-path |
|---|---|
| `/api/client/Auth/Check` | `/api/client/Auth` |
| `/client/new/cprintPc/cprint.html` | `/client/new/cprintPc` |

于是同名 cookie 在三个路径下各存一份，后续请求全部命中。

上游 2.0.3 不是这么做的。`crates/ubaa_core/src/session/cookies.rs`：

```rust
let cookie = Cookie::parse(raw, url)?;     // cookie crate
path: String::from(&cookie.path),          // 未声明 Path 时为 "/"
```

`cookie` crate 的 `CookiePath` 默认值就是 `/`，**不会**做 default-path 推导。
`cloud_print_contract_tests.rs` 里的 fixture 也印证这一点（统一 `Path=/`）。

## 修复

两处改动：

### 1. `UpstreamClient`：未声明 `Path` 一律存 `/`（对齐上游）

- `putResponseCookie()`：`cookie.path` 为空 → `/`（原 `defaultPath(requestPath)`）
- `upsertCookie()`：`path` 初值 → `/`（原 `defaultPath(requestPath)`）

`defaultPath()` 仅保留给 `normalizeLegacyPaths()` 的历史自愈使用。

### 2. `LocalCloudPrintService`：登录前清本站存量 cookie

旧规则产生的目录级 cookie 已经落盘，不改存量的话新规则依然被污染。
`doLogin()` 首步 `dropStaleCookies()`，只清 `print.lib.buaa.edu.cn` 域，**不动 CAS 登录态**。

## 验证（真机 PLR-AL50）

```
云打印会话检查：罐内 cookie=OSESSIONID@/, SESSIONID@/      ← 不再分裂
Auth/Check[0] HTTP 200 / 528B
  {"SessionId":"aece0d7f…","code":0,"message":"password",
   "result":{"dwAccNo":101872518,"szLogonName":"25051020",…}}   ← 已登录
云打印会话就绪（终点 …/cprint.html）
云打印文档 0 份、打印站 5 台
```

页面渲染：我的文档 0 份（「还没有上传过文档」）+ 打印站 5 台（一层大厅西侧 01/02、
沙河校区特色阅览室、沙河校区新馆、科研楼阅览室），均显示「未开放」（深夜时段，正常）。

**回归**（Cookie 路径是全局规则，必须查）：冷启动后依次打开云打印、SPOC 作业、
我的页，`hilog` 中**无任何 4xx/5xx**：

- SPOC 作业：共 21 次作业，已提交/未提交状态正确
- 我的 · 校园账户：网费 1.56 元、一卡通 261.57 元、未读邮件 74、待还图书 0、云盘 200.00 G

## 附带修掉的第二个 bug：从「功能」页进入是一片空白

登录修好后用户又指出：**从主页「最近使用」进云打印正常，从「功能」页进是纯白页**。

两者走的是**两套不同的路由表**（`MainPage.ets`）：

| 入口 | 路由 builder | 内容来源 |
|---|---|---|
| 主页 / 课表 / 我的 | `routeBuilder`（HDS `HdsNavDestination`） | 分支里直接写 `CloudPrintPage()` |
| **功能页签** | `nativeFeatureRoute`（原生 `NavDestination` + `NativeHeroDest`） | `FeatureDestBody({ name, stack })` 按 `RouteName` 分派 |

而 `components/FeatureDestBody.ets` 的分派表**没有 `CLOUD_PRINT` 分支**（`nativeFeatureRoute`
明明有这一支，只是它把内容交给分派组件）。于是 `if/else` 链全部落空 → 标题栏照画、
内容区零渲染，`aboutToAppear` 也不执行，**连网络请求都没有**。

这个表现很容易误判：没有报错、没有加载圈、没有 4xx —— 看起来像「渲染 bug 或闪烁」，
实际是「路由表漏项」。

修法：

1. `FeatureDestBody` 补 `RouteName.CLOUD_PRINT → CloudPrintPage()`；
2. 末尾补显式兜底分支，渲染「该页面尚未接入功能页路由：<name>」。
   宁可在页面上露一行字，也不要静默空白 —— 否则下次再加功能入口还是同样的哑谜。

⚠️ **以后新增功能入口必须三处齐全**：`FeatureRegistry`（图标/颜色/route）、
`routeBuilder`（HDS 版）、`nativeFeatureRoute` + `FeatureDestBody`（功能页原生版）。

## 遗留

- `Auth/Check` 响应里带 `SessionId` / `dwAccNo` / `szLogonName` 等字段，目前只用了
  `szLogonName` 做账号比对。若后续要做「云打印账户概览」（余额、已打印页数），这几个
  字段可以直接复用，不必再加接口。
- 云打印仍是**只读**：上传（PDF 生成 + 分片）、预览、下载、删除都未实现。

