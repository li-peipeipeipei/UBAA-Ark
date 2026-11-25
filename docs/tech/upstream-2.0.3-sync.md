# 上游 UBAA 2.0.3 增量同步排查

排查日期：2026-11-20
对照源：`UBAA-2.0.2`（2026-11-17 快照）→ `UBAA-2.0.3`（2026-11-19 快照）
变更规模：213 个文件差异，其中 `crates/ubaa_core` 48 个（协议核心），Flutter/Dart 侧 100+。

## 结论摘要

2.0.3 只有一个产品级新功能，其余是会话缓存架构落地。

| 优先级 | 项 | 对鸿蒙版的影响 | 状态 |
|---|---|---|---|
| P0 | 签到提交改用 `stu_auto_sign` | 直接修复「签到永远失败」 | **已落地** |
| P1 | 签到二维码（扫码签到） | 新增功能 | **已落地**（编译通过，待真机） |
| — | 签到时间窗拆分 | 上游把直接签到收窄到上课后 30 分钟 | **已同步**（2026-11-25） |
| P2 | 业务凭据失效判定（`is_pre_send_credential_error`） | 原则适用 | **已排查，无需改动** |
| — | 业务会话旁车缓存（`business_session.json`） | 不适用（多进程架构） | 不适用 |
| — | Flutter/Dart/服务端/CI 变更 | 不适用 | 不适用 |

## P0：签到提交接口选错（已修复）

### 根因

11-19 那轮把「签到永远失败」归因于**参数载体放错**（`courseSchedId`/`timestamp`
从查询串挪进表单），并按冻结旧版 v1.7.2 的 `LocalSigninApi.performSignin` 实现。
真因是**接口选错**：

- `stu_scan_sign.action` 是**扫码签到**接口，它要的是「扫到的那张码」里的参数组合。
  拿它当自动签到的提交入口，上游第一步就回 `ERRMSG=!appMsg.qxktSign!`。
- 自动签到是 `stu_auto_sign.action`，端口 **8181**，参数全在表单里。

2.0.3 的裁决原文（`docs/protocol/parity/signin.md`）：

> 旧 `stu_scan_sign` 提交因用户确认不可用而停用；二维码读取仍保留旧时间戳接口。

该裁决依据是 2026-11-19 的真实抓包摘要，不是冻结旧版代码 —— 冻结旧版和
`examples/buaa-api` 都没有 `stu_auto_sign` 这个操作。

### 契约差异

| | 修复前（v1.7.2 / 2.0.2 契约） | 修复后（2.0.3 裁决） |
|---|---|---|
| 端点 | `stu_scan_sign.action` | `stu_auto_sign.action` |
| 端口 | 8347 | **8181** |
| 查询串 | `?courseSchedId=&timestamp=` | **无** |
| 表单 | `id`（1 字段） | `id` `courseSchedId` `routerInfo` `longitude` `latitude` `machineInfo`（**6 字段**） |
| 时间戳 | 必带 | **不带** |

固定值：`routerInfo=02:00:00:00:00:00`、`longitude=0`、`latitude=0`、`machineInfo=Android`。
上游只校验字段形状，不校验定位真实性。

### 落地位置

`entry/src/main/ets/network/LocalSigninService.ets`

- 新增常量 `ICLASS_AUTO_SIGN_URL`（8181）
- 新增 `autoSignForm()`，六字段表单
- `signIn()` 不再取时间戳，直接提交
- `checkinUrl()` 降级为「读接口基址」，注释明确禁止与提交入口合并
- `fetchTimestamp()` 保留，注明为二维码预留

### 保留项（与 2.0.3 一致，无需改）

- `STATUS=2` = 今日无课的合法空结果
- 成功判定：`STATUS ∈ {0, 200, success}` 且 `result.stuSignStatus = 1`
- 写请求不跟随重定向
- 写后结果无法解析 → `outcome_unknown`，先回读再决定是否重试

## P1：签到二维码（已实施）

2.0.3 新增 `signin_qr` 只读接口 + UI 面板。产品形态：

| 参数 | 值 |
|---|---|
| 二维码内容 | `http://iclass.buaa.edu.cn:8081/eschool/app/course/stu_scan_sign.action?courseSchedId=X&timestamp=T` |
| 时间戳来源 | `get_timestamp.action`（服务端时间，不可用本机时间兜底） |
| 实时面板偏移 | 0 ms，每 2 秒刷新 |
| 保存到相册偏移 | 2000 ms |
| 已签到轮询 | 每 3 秒，回到前台立即查一次 |
| 时间窗（上游） | 课前 10 分钟 → 下课 |

### 落地位置

- `entry/src/main/ets/network/LocalSigninService.ets`
  - `ICLASS_QR_SCAN_URL` 常量（8081 + `eschool` 前缀，仅作字符串内容）
  - `buildScanQrContent(courseId, offsetMs)`：取服务端时间戳 → 加偏移 → 拼 URL
- `entry/src/main/ets/components/SigninQrSheet.ets`（新增）
  - 二维码渲染：`@kit.ScanKit` 的 `generateBarcode.createBarcode`，**无需三方库、无需权限**
  - 保存相册：`@kit.MediaLibraryKit` 的 `photoAccessHelper.showAssetsCreationDialog`
    （弹窗授权，**不声明 `WRITE_IMAGEVIDEO`**）
  - 编码用 `packToData`（`packing` 已废弃）；编码完成前不释放 PixelMap
- `entry/src/main/ets/pages/activity/SigninPage.ets`
  - 卡片底部「出示签到码 ›」弱入口（刻意不做成第二个主按钮）
  - `.overlay()` 挂浮层 + `if (courseId)` 条件，绕开 `@Builder` 参数不刷新的坑

### 两个技术前提的核实

1. **二维码内容用 `http://...:8081` 不违反明文 HTTP 限制** —— 它只是给 iClass App /
   微信扫的字符串，本机不发这个请求。本机取时间戳仍走 8347 https。
   官方错误码 `2300997 Cleartext traffic not permitted` 只约束本机请求。
2. **保存到相册免权限** —— 官方 `photoaccesshelper-savebutton` 指南：安全控件或
   `showAssetsCreationDialog` 二者都不需要 `ohos.permission.WRITE_IMAGEVIDEO`。

## 时间窗：已同步（2026-11-25 修复）

2.0.3 把单一窗口拆成两个：

| 动作 | 上游窗口 | 鸿蒙版（本次同步后） |
|---|---|---|
| 扫二维码 | 课前 10 分钟 → 下课 | `SigninPage.qrPhase()` / `QR_EARLY_MS` |
| 页内直接签到 | 课前 5 分钟 → 上课后 30 分钟 | `SigninPage.phase()` / `SIGNIN_EARLY_MS` + `SIGNIN_LATE_MS` |

原先鸿蒙版维持单一窗口「课前 10 分钟 → 下课」，理由是「产品口径、一个窗口更简单」。
2026-11-25 18:54 真机四次点击均被上游拒绝：`STATUS=1 / ERRCODE=121 / ERRMSG=签到时间有误`
（`hilog` 中 `stu_auto_sign.action` 均 HTTP 200，非网络/会话问题）。那门课 **19:00 开始**，
18:54 点击是**课前 6 分钟**——落在旧窗口（课前 10 分钟）内、新窗口（课前 5 分钟）外，
所以旧版给了按钮、上游以「时间有误」拒绝。收窄为与上游一致的两套窗口后，这类过早点击
会在客户端就被挡下；二维码仍覆盖到下课，不影响扫码路径。`doSignin()` 写前再判一次窗口，
`LocalSigninService.friendlyMessage()` 对 121 给出明确提示。

### 🔴 写后必须回读真实状态，不能只信回包（同日追加）

同一门 19:00 的课，18:54 四次回包全是 121「失败」，但 **19:04 刷新后 App 显示「已签到」**。
回包与最终落库状态不一致 —— 无论中间是教师端放行、另一次提交补上，还是上游先拒后写，
客户端唯一可信的判据只有课程列表的在线 `signStatus`。这正是 2.0.3 `parse_action_response`
把无法解析的写后结果归为 `outcome_unknown`、要求「先回读今日状态再决定是否重试」的原因。

`SigninPage.doSignin()` 已改为：任何回包返回后都在线回读该课程的 `signStatus`；
回读为已签则以成功覆盖失败文案（`签到成功（已按课堂系统实际状态确认）`），
并通知首页刷新；回读失败（网络问题）才退回信回包。教训：**写请求的结果以服务端最终状态
为准，回包只是提示** —— 只信回包会出现「界面说失败、实际签上了」的误导。

## P2：业务凭据失效判定（已排查，无需改动）

2.0.3 在 SPOC、阳光打卡、门户、课表四处统一加了 `!is_pre_send_credential_error(&error)`：
**发送前就失败**（网络、路线、超时）不得作废业务凭据。

逐项核对结论：

| 服务 | 当前实现 | 结论 |
|---|---|---|
| `LocalSpocService.withAuth` | `await request()` 抛异常直接冒泡，不重试不清 token | ✅ 已符合 |
| `LocalYgdkService.postForm` | 仅 `probe.authExpired`（上游 `code === -98`）才清 `auth` | ✅ 已符合 |
| `LocalSigninService` | 仅 `signRetryWorthy`（3xx/非 2xx/非 JSON）才重登 | ✅ 已符合 |
| `LocalPortalService` | 只认 `e === 10013` | ⚠️ 比上游窄，**故意不改** |

门户那一条：上游额外放宽到「已有 Cookie 且 `UpstreamUnavailable` + `kind == Authentication`」。
鸿蒙版的 `ApiError` 没有 `kind` 维度，按这个口径放宽会把**网络断开**也判成「需要业务登录」，
触发一次必然失败的重新激活。收益（门户偶发失效时少点一次刷新）远小于风险，保留窄判据。

另：「会话冲突分级清理」（`clear_runtime_memory` vs `clear_all_memory`）是 Rust 多进程
场景的产物，鸿蒙单进程不存在「另一个进程抢走会话」的情形，不适用。

## 不适用项

| 变更 | 不适用原因 |
|---|---|
| `session/business_cache*`（旁车缓存、撤销令牌、墓碑） | 服务 CLI + GUI 双进程共享凭据；鸿蒙单进程，无跨进程回填窗口 |
| `internal/runtime/main_session.rs`、`shared_account` | 多进程主会话 CAS 与账号代次 |
| `packages/*`、`apps/ubaa_flutter`（100+ 文件） | Dart / Flutter UI，鸿蒙是 ArkTS 原生 |
| `crates/ubaa_flutter_bridge` | flutter_rust_bridge 绑定层 |
| `services/app_service`、`scripts/` | 更新分发与匿名统计服务端 |
| 首页考试独立交付（`home.md`） | Flutter 首页并行等待策略，鸿蒙首页已是独立任务 |
| 希冀批量激活撤回（`decision-log`） | 性能取舍，实测差异在波动范围内 |
| SPOC 详情跨路线离线票据竞争 | 上游自己标注为「基线已有的残留问题」，未修 |

## 验证记录

- 官方文档核实：`showAssetsCreationDialog` 免权限（弹窗授权）、明文 HTTP 需
  `network_config.json` 否则报 `2300997`、`packToData` 取代已废弃的 `packing`。
- 编译验证（两次，均 `assembleHap` module 模式 BUILD SUCCESSFUL）：
  - 仅签到提交改动：`entry-default-signed.hap` 2026-11-20 19:28:53
  - 含二维码面板：`entry-default-signed.hap` 2026-11-20 20:58:49，`SigninQrSheet` 零告警
  - 两次均无 `ArkTS:ERROR`
- 真机验证：**未执行**（`hdc list targets` 为空，设备未连接）。待验证项：
  1. `stu_auto_sign` 的 **8181 端口**在鸿蒙真机是否可达（是否被网络安全策略拦截）；
  2. 实际提交结果（需教师开窗时段，写操作，需确认）；
  3. 二维码能否被 iClass App / 微信正确识别；
  4. 「保存到相册」的 `showAssetsCreationDialog` + `fileIo` 写 media uri 是否成功。
