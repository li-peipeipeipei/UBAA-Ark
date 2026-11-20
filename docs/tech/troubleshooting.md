# 排障指南

## 编译期

| 报错 / 现象 | 原因 | 修法 |
| --- | --- | --- |
| `00303313 compileSdkVersion is incompatible` | 显式写了低版本 | 删掉 `compileSdkVersion` |
| `import { NavPathStack } from '@kit.ArkUI'` 报错 | `NavPathStack` 是全局声明类，不在 kit 导出表 | 去掉 import 直接用 |
| `ConfigurationConstant.Configuration` 不可用 | 该模块只导出 `ColorMode/Direction/ScreenDensity` | 从 `@kit.AbilityKit` 导入 `Configuration` |
| `@Builder toolbar()` 类型冲突 | `toolbar` 与 `CommonAttribute` 内置属性重名 | 换名（本项目用 `termBar()`） |
| `10903329 Unknown resource name 'sys.symbol.xxx'` | 系统符号表没有这一项（如 `sys.symbol.info`） | 改用存在的（`info_circle`） |
| `promptAction.showToast` 废弃告警 | API 26 起废弃 | 统一走 `common/Toast.ets` |
| `px2vp()` 废弃 | 全局函数废弃 | `window.getUIContext().px2vp()` |
| 改了代码但行为没变 | 增量缓存被上次失败构建污染 | `--no-incremental` 全量重编 |

系统符号的权威清单在 SDK 的
`sdk/default/openharmony/ets/build-tools/ets-loader/sysResource.js` 的 `sys.symbol` 段。

## 运行时

| 现象 | 判据 / 原因 | 处理 |
| --- | --- | --- |
| 白屏但无 JS 日志 | 进程被系统杀掉 | `hdc shell pidof <bundleName>`，无输出即崩溃 |
| `aa start` 报 `10106102` | 设备锁屏 | 物理解锁后再启动，自动化脚本无法绕过 |
| `hdc install` 只报 `Error opening file` | hap 没产出（构建失败但打印了 finished） | 检查 `.hap` 时间戳 |
| 弹窗刚开就闪退 | Builder 直接传方法引用丢了 `this` | 用箭头函数包一层 |
| 页面白屏、编译通过 | `@Builder` 用了泛型 | 改为非泛型或拆组件 |
| 列表少元素 | `ForEach` key 重复 | key 带唯一 id 且反映数据身份 |
| `Select` 显示异常 | 缺少 `.value()` 或 `.selected()` | 两者成对出现 |

## 网络

详见 [登录与连接模式](../features/auth-and-connection.md#排查顺序)，核心一条：
**返回 HTML 时按状态码分流**——`5xx` 是上游挂了，`2xx` 才是被登录页替换，
`404` 是地址错，不能用「响应体是 HTML」一刀切。

其他：

- `405 Method Not Allowed`：先确认没被 `302` 把 POST 改成 GET，再对请求头与表单字段。
- 切换连接模式后仍用旧会话：Cookie 按模式隔离，**必须重新登录**。
- WebVPN 下接口 404：只填了网关根域不行，必须用完整资源地址（由 `LocalWebVpn` 改写）。

### 「刚登录就提示登录失效」——先怀疑 Cookie 路径，不要怀疑密码

真机现象（2026-11-20）：首页反复弹「登录状态已失效，请重新登录」，点重载立刻再弹；
日志里 `currentUser.do -> 200` 紧跟着 `teachingSchedule/detail.do -> 401`，同一秒、同一个
Cookie 罐；重走 CAS 换票后 `currentUser.do?ticket=…` 也是 200，但下一个接口仍然 401。

判据：**能探查会话的接口 200、真正取数的接口 401 = 凭证没被带到后续请求**，
不是会话过期。此时看日志摘要里那句 `上游带 Cookie <host>：…`（只在 4xx/5xx 时打印），
若名单里缺少该站点的会话 cookie（byxt 是 `GS_SESSIONID`），就是路径/域匹配的问题。

两个已修的根因，都在 `UpstreamClient`：

| 缺陷 | 后果 | 修法 |
| --- | --- | --- |
| `Set-Cookie` 只取首个头（`value[0]`） | 上游「先删旧、再发新」成对下发时只剩删除指令，会话 cookie 从未入罐 | `headerValues()` 全量遍历 + 逐条 `splitSetCookie` |
| 未声明 `Path` 时拿**整个请求路径**当 cookie path | cookie 被钉死在 `…/api/home/currentUser.do`，其它接口一律带不上 | `defaultPath()` 按 RFC 6265 §5.1.4 截到目录级 |

存量坏数据由 `normalizeLegacyPaths()` 在下次请求时自愈（path 以 `.do`/`.action` 等资源名
结尾的，截回目录级），用户不必重新登录 —— 日志会出现一行「修正历史 Cookie 路径」。

> 另一条同等重要的教训：**别拿「返回是不是 JSON」当会话判据**。
> byxt 的 `currentUser.do` 对匿名请求也回 200 + JSON 信封（`code` 不是 `'0'`），
> 只看 JSON 就会盖上「会话就绪」，401 后的自动重试被短路，永远不会成功。
> 见 `LocalAcademicService.isByxtLoggedIn`。

## 真机调试速查

```bash
hdc list targets
hdc install -r entry-default-signed.hap
hdc shell pidof cn.edu.ubaa          # 有输出=活着
hdc shell hilog | grep -i ubaa       # 应用日志
hdc file recv /data/log/hilog/x.log  # 落盘时本地路径写相对文件名
```
