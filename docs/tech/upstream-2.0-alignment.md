# 上游 UBAA 2.0 功能对齐：现状与剩余项实现方案

> 上游：<https://github.com/BUAASubnet/UBAA>（分支 `main`，最新合并 PR #127）
> 本地镜像：`D:/0001/.upstream-tmp`（`--depth 1`，用完可删）
> 本文记录 **0.9.0 这一轮做到哪里、剩下的怎么做**，供后续接手。

## 一个必须先说清的事实

**上游 2.0 是 Rust + Flutter 重写版，不能代码级移植到本工程。**

| 上游结构 | 说明 | 对本工程的价值 |
|---|---|---|
| `crates/ubaa_core` | Rust 核心，全部协议实现 | ★★★ **协议契约的唯一权威来源** |
| `crates/ubaa_flutter_bridge` | Rust ↔ Flutter 桥 | 无 |
| `apps/ubaa_flutter` | Flutter UI | 仅参考交互设计 |
| `apps/ubaa_ohos` | **Flutter 的鸿蒙壳**（只有 3 个 `.ets`：EntryAbility / Index / AgendaFilePlugin） | **代码不可复用** |
| `fixtures/readonly/**` | 真实上游响应样本 | ★★★ **离线验证解析器的唯一手段** |

本工程是 ArkTS / ArkUI 原生实现，与上游唯一可靠的对接面是 `crates/ubaa_core` 里的
**请求路径、参数结构、响应字段、判据**，以及 `fixtures/` 里的真实样本。

## 本轮（0.9.0）已完成

| 功能 | 状态 | 依据 |
|---|---|---|
| 自动评教「登录状态已失效」 | ✅ 修复 | `features/evaluation/` |
| 财务收入查询 | ✅ 新增 | `features/finance/` |
| 网费流量查询 | ✅ 新增 | `features/campus/` |
| 版本控制 / 0.9.0 / CHANGELOG | ✅ | — |

已完成的判定标准：**编译 0 error**；网费解析器已用上游真实 fixture 离线验证通过
（`fixtures/readonly/campus/network.html` → 正确跳过干扰表、按 `data-col-seq` 非顺序
对齐、取到 `90.001G` / `512M`）。

## 功能差距总表（对齐上游 README「功能一览」与官方文档站）

> 依据：上游 README 的功能一览、`www.ubaa.top/features/` 的功能导航与各功能详细说明。
> 「✅」= 能力对齐；「部分」= 有但不全；「❌」= 未实现。

| 上游功能 | 上游要求 | 本工程 | 状态 |
|---|---|---|---|
| **首页** | 今日课表、**最近使用的快捷入口**、**待办**（签到/作业截止） | 今日课表 + 考试倒计时 | 部分 |
| **日程与待办** | 时间线、重复规则、教学周对齐、完成标记、导出系统日历、云盘同步 | — | ❌ |
| **课表与考试** | 按周课表、考试时间/考场/座位 | `SchedulePage` / `ExamPage` | ✅ |
| **课堂签到** | 今日课程签到状态、签到 | `SigninPage` | ✅ |
| **SPOC 作业** | 截止时间、提交状态、网页提交 | `SpocPage` | ✅ |
| **希冀作业** | 完成情况、题目明细、得分 | `JudgePage` / `JudgeDetailPage` | ✅ |
| **博雅课程** | 浏览、筛选、选课、退选、签到签退、达标统计 | `Bykc*`（6 个页面） | ✅ |
| **成绩查询** | 按学期、学分、平均分 | `GradePage` | ✅ |
| **教学评教** | 待评课程、批量提交 | `EvaluationPage` | ✅ |
| **iHome** | 诉求、回复、公告 | `IhomePage` / `IhomeDetailPage` | ✅ |
| **北航云盘** | 浏览管理、上传下载、分享、回收站 | — | ❌ |
| **财务查询** | 年份筛选、**合计**、**按月分组+小计**、**搜索**、**点开明细**、下拉刷新 | `FinancePage` | ✅（2026-11-17 补齐 6 项） |
| **空教室查询** | 按日期、校区、教学楼 | `ClassroomPage` | ✅ |
| **图书馆座位** | 预约、查看、取消预约 | `LibBook*`（3 个页面） | ✅ |
| **研讨室预约** | 预约、查看门锁密码 | — | ❌ |
| **阳光打卡** | 进度、提交打卡、记录 | `YgdkPage` | ✅ |
| **网费流量** | 页面流量表 | `NetworkPage` | 部分（**缺套餐合并**） |
| **我的** | 个人资料、**校园卡余额**、**网费余额**、**未读邮件**、**待还图书**、**云盘剩余空间** | 仅个人资料 | 部分 |
| **离线查看** | 打开先显示本机记录 + 「离线记录」标注 | 仅课表有磁盘缓存 | 部分 |
| **桌面命令模式** | 终端查课表/成绩/管理日程 | 无（鸿蒙无终端场景） | ➖ 不适用 |

### 尚未实现的缺口（按「补起来的性价比」排序）

1. **我的页 5 项指标**（校园卡余额 / 网费余额 / 未读邮件 / 待还图书 / 云盘剩余空间）
   —— 上游 `features/campus/portal.rs` 一次接口返回，成本低、页面增量明显
2. **首页「待办 + 最近使用」** —— 待办可由「作业截止 + 签到」派生，无需新接口
3. **网费套餐合并** —— 解析一张套餐表，把可用套餐流量加到 `freeRemaining`
4. **离线缓存铺开**（财务 / 成绩 / 考试 / 空教室）—— 与 `ScheduleCache` 同一套模式
5. **云打印**（建议先只做文档列表与队列查看）
6. **研讨室预约** —— **需要抓包 + 验证码识别**，风险高，无真机数据不要动
7. **北航云盘** —— 分片上传 / 断点续传 / 分享，建议单独立项
8. **日程与待办** —— 上游 4600 行独立子系统，含重复规则与日历导出

### 明确不做

- **桌面命令模式**：鸿蒙手机/平板无终端场景，等价物是本工程已有的**桌面卡片**。


## 剩余项（按「可落地程度」排序）

### 1. 门户账户指标（`features/campus/portal.rs` + `packages.rs`）

**成本：小（约 0.5 人日）** ｜ **风险：低**

- 入口：`https://it.buaa.edu.cn/home/`，业务接口返回 `{e:0, d:{info:{identity,depart}, ...}}`
- 五项指标：网费余额、一卡通余额、未读邮件数、借阅图书数、云盘剩余空间
- 判据：`e===0` 成功；`e===10013` 需业务登录；其它 = 服务不可用
- 认证：`https://it.buaa.edu.cn/manage/common/login/index?redirect=<home>`
- 未做的原因：本轮优先做了同模块里**数据更明确**的网费流量表；
  这一项只需把 `activate(Service.Portal)` + `parser::envelope` 照抄即可

### 2. 网费套餐合并（`features/campus/packages.rs`）

**成本：小（0.2 人日）** ｜ **风险：低**

- 现状：只显示页面原值（三个流量列都标「不含套餐」）
- 待做：解析 `fixtures/readonly/campus/network_packages.html` 那张套餐表，
  把可用套餐流量加到 `freeRemaining`（上游注释：「在线免费剩余包含套餐可用流量」）
- 注意：`billableRemaining` **保持上游原值，不合并**

### 3. 云打印（`features/cloud_print/`）

**成本：中（1.5 人日）** ｜ **风险：中**

- 宿主：`print.lib.buaa.edu.cn`，页面 `/client/new/cprintPc/cprint.html`
- 子模块：`auth.rs`（登录材料）/ `pdf.rs`（PDF 处理）/ `read.rs`（文档列表）/ `upload.rs`
- 难点：PDF 生成与分片上传；鸿蒙侧需 `picker` 选文件 + 文件读写权限
- 建议：先只做**文档列表 + 队列查看**（只读），提交类留到第二步

### 4. 研讨室预约（`features/cgyy/`）

**成本：大（3 人日+）** ｜ **风险：高**

- 入口：`https://cgyy.buaa.edu.cn/venue-zhjs-server/`
  - 登录 `/sso/manageLogin` → `/api/login`
  - 场馆 `/api/sites`、日信息 `/api/.../day`、我的订单 `/api/orders/mine`
  - 下单前要 `/api/orders/lock/code`（锁座验证码）
- **难点：`captcha.rs` 需要解验证码（滑动/点选偏移 `solve_captcha_offset`），
  `crypto.rs` + `sign.rs` 是请求签名。**
- 建议：**没有真机与抓包不要动**。验证码一旦实现不对，会把账号锁死风险引入预约链路。

### 5. 北航云盘（`features/bhpan/`，1316 行）

**成本：大（5 人日+）** ｜ **风险：高**

- 宿主 `bhpan.buaa.edu.cn`，走 anyshare OAuth2：
  `/anyshare/oauth2/login` → `signin` → `callback` → `refreshToken`
- 子模块：`object`（对象读写）/ `multipart`（分片）/ `upload` / `download` /
  `share`（分享链接）/ `read`
- 难点：分片上传与断点续传、分享链接权限、回收站语义；还要处理大文件与后台任务
- 建议：**单独立项**，不要在版本升级里夹带

### 6. 日程与待办（`src/agenda/`，4600 行）

**成本：大（5 人日+）** ｜ **风险：中**

- 上游是独立子系统：`sqlite.rs`（本地库）/ `recurrence.rs`（重复规则）/
  `projection.rs`（投影）/ `split.rs` / `school.rs`（教学周对齐）/ `export/`（导出系统日历）
- 数据来源是**本地 + 课表/作业 / 上游只读**，不新增校园接口
- 鸿蒙侧要替换：SQLite → `relationalStore`；系统日历 → 暂无对等能力（需评估）
- 建议：先做「只读时间线」（课表 + 作业截止合并展示），再做「自建待办 + 重复规则」

### 7. 桌面命令模式（`crates/ubaa_command` + `ubaa-cli`）

**不适用**。这是桌面端（Windows/macOS/Linux）的终端工具，鸿蒙手机/平板无对等场景。
若要「命令行」体验，鸿蒙侧的等价物是**桌面卡片**（本工程已有）与**快捷方式**。

## 明确不做 / 不该做的

- **不要**把上游 `apps/ubaa_ohos` 当成参考实现 —— 它是 Flutter 壳，只有启动与文件插件。
- **不要**从 Flutter UI 反推业务逻辑 —— 逻辑全在 Rust core，UI 只是渲染。
- **不要**在没有 `fixtures/` 真实样本的情况下写新解析器。上游 `fixtures/readonly/`
  里已有 eval / campus / bhpan / libbook 等样本，先补样本再写解析。

## 复现上游镜像

```bash
cd D:/0001
git -c http.sslVerify=false clone --depth 1 https://github.com/BUAASubnet/UBAA.git .upstream-tmp
```

> ⚠️ 本机 HTTPS 有 TLS 中间人，只能临时 `-c http.sslVerify=false`，
> **不要改全局 `sslBackend`**（会污染其它仓库）。

## 与老版本（0.1.0）的兼容性

见 `docs/tech/release-compatibility.md`。结论：**不影响**。
