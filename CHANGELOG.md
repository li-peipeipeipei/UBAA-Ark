# CHANGELOG

本项目遵循语义化版本。**versionCode 必须严格递增**（见 `AppScope/app.json5` 注释），
否则 AGC 拒收、真机也无法覆盖安装。

## [0.9.0] — 进行中

> 目标：对齐上游 UBAA 2.0 的功能面。分支 `release/0.9.0`。

### 修复

- **自动评教一直提示「登录状态已失效」**
  `/pjxt/cas` 的 CAS 握手改为**逐跳**（`followRedirects=false`）而非自动跟随。
  跨域链路（spoc → sso → spoc）下自动跟随时，`absorbCookies()` 只能按「首发地址」归属 Cookie，
  统一认证会话拿不回来；且原先靠 HTML 里的 `name="execution"` 判断登录页，
  学校一改版就误判。现按上游 `ensure_activation_terminal` 的判据校验终点：
  还原 WebVPN 网关地址后，host 必须是 `spoc.buaa.edu.cn` 且 path 在 `/pjxt` 下。
- **深色模式状态栏白字**：HDS 的 `systemBarStyle` 默认值是 `#E5FFFFFF`，
  未显式设置时由 HDS 托管状态栏，页面一滚动就覆盖 `setWindowSystemBarProperties` 设的黑。
- **深色模式「今日课程」教室尾部渐隐变白斑**：AppStorage 键名不一致
  （读 `isDarkMode`、写 `isDark`），冷启动恒取不到值。
- **首页课程详情只有「时间 / 地点」两行**：`resolveTermCode()` 读到过期学期，
  预加载到上学期课表导致按名字匹配全部落空。

### 修复（全量巡检，2026-11-17）

对全部 104 个 `.ets`（3 万行）做了两轮针对性巡检（页面/组件一轮、网络/公共模块一轮），
以下按「会造成什么」排序。

**会锁死或报错**

- **评教提交异常会永久锁死返回键**：`BackGuard.register(() => false)` 后没有
  `try/finally`，任一门课抛异常就跳过 `unregister()` 与 `submitting=false` ——
  遮罩不消失，且此后**所有页面**按返回都没反应，只能杀进程。现改为 finally 收尾，
  并给每门课单独 try/catch（一门失败不再中断后面的课）。
- **网费会话失效后永久报错**：`activated` 只在 401/403 时复位，而会话过期时上游回的是
  **302 跳登录页** → 标记一直为 true、`ensureActivated` 永久短路。现任何非 2xx 都复位。
- **图书馆重试绕过业务校验**：token 失效重试的那一次直接 `return`，不再判 `code` ——
  「座位已被占用」会被当成功，界面提示预约成功但实际没约上。现重试结果走同一套校验。
- **课表页可能白屏**：`Swiper.onChange` 里 `this.weeks[index]` 无边界检查，
  换学期后数组变短、旧下标仍在 → `undefined.serialNumber`。已加边界判断。
- **损坏的课表缓存会让课表页白屏**：`ScheduleCache.loadWeek` 只 `JSON.parse` 不校验形状，
  缺 `arrangedList` 的旧缓存会在 build 期抛 TypeError。现读出来先校验，不合格当无缓存。
- **希冀作业刷新永远拿到旧状态**：详情缓存无 TTL、无失效入口，提交代码后下拉刷新还是
  「未提交 / 上次得分」。列表刷新改为绕过缓存（详情页仍复用）。

**会显示错数据**

- **筛选胶囊点了没反应**（希冀作业页）：三个参数的 `@Builder`，`active` 按值传递不参与刷新，
  选中态永远停在首帧。改为独立 `@Component` + `@Prop`（与 `BykcFilterChip` 同一套写法）。
- **iHome 切 scope 后列表串数据**：没有请求序号，慢请求后到会覆盖新列表。
  加单调递增 `reqSeq`，回来时序号对不上就整份丢弃（`load` / `loadMore` / 公告都覆盖）。
- **图书馆预约可能约到错座位**：四级级联请求无互斥，连点两个楼馆时「B 楼的 id + A 楼的分区」
  会被一起提交。现在每次请求都记住发起时的选择，回来比对不一致就丢弃。
- **博雅写操作后多弹一层**：成功后无条件 `back()`，用户若在等待的 1~2 秒里自己返回过，
  会把列表页也弹掉。改为比对发起时的栈深。
- **换账号后仍用旧账号的会话与缓存**：`TokenStore.clear()` 只清磁盘，各 `Local*Service`
  的静态 token / 已激活标志 / **希冀作业详情缓存**都还在（会读到别人的作业结果）。
  新增 10 个 `reset()`，在 `logout()` 里统一清。
- **首页今日课程下拉刷新不更新**：`ForEach` 用 index 当 key，数组整体替换时 ArkUI
  认为节点没变、不重跑 itemGenerator（标题写着「3 节课」，三行还是旧内容）。改用身份键。
- **非补零日期解析错一天**：`DateUtil.parse` 按固定下标切 `"2026-1-5"` → day=0 →
  落到 2025-12-31（卡片「本周」与考试倒计时跟着错）。改为正则 + 范围校验。
- **财务列表可能丢行**：流水号缺失时 id 为空串，多条撞键 → ArkUI 未定义行为。空 id 用下标兜底。

**性能**

- **成绩页 build 里做 8 次全量统计**（两个卡片 × 4 项 + 课程数），「全部成绩」是上百门课，
  任何状态变化都重跑一整轮。改为数据变更时算一次（`refreshSummaries`），build 只读字符串。
- **教室表格 840 次 split+parseInt**（60 间 × 14 格，全在同一帧）。按 `kxsds` 字符串缓存解析结果。
- **首屏重复跑 CAS 链**：教务（学期/周次/今日课程）与评教、博雅、阳光打卡的 `ensure*` 只有
  布尔标志、没有 in-flight 复用 —— 并发请求各跑一遍 3~10 跳的跳转链，还互相覆盖 Cookie。
  统一改为共享同一个 Promise。
- **一次卡片刷新连推三次**：`CardRefresher` 连写周/日/今日三份数据，每次都 `pushAll`
  （重读 formIds + 重新 buildPayload + 每张卡一次跨进程 IPC）。改为只在最后一份推。
- **窗口尺寸回调每帧写日志**：`windowSizeChange` 在拖拽分屏/旋转动画时逐帧触发，
  每次都格式化并落盘 hiLog。改为只在断点/避让区真的变化时打。
- **课表后台预取抖动**：原先每 3 周 `slice()` 一次 @State 数组，数组换引用会让已挂载的
  3 页（约 900 节点）全部重建。改为按时间节流（≥400ms）。
- **功能页每次 build 构造两遍功能清单**（24 个对象 + 24 次 `$r()`）：清单提为模块级常量。
- **重复注册窗口监听**：`ImmersiveUtil.apply()` 被重复调用时会在同一窗口上再挂一套监听，
  回调按倍数增长且无法解绑。加 `listenersBound` 守卫。

**健壮性（防御性）**

- `HttpEngine` 刷新令牌失败时不再一律清登录态：只有 401/403 才清，网络异常与 5xx 保留令牌
  （一次校园网抖动不该把人踢回登录页）。
- `TokenStore.loadCookies` 加 `Array.isArray` 校验（脏数据会让后续 `jar.push` 抛 TypeError）。
- `CasParser.hasLoginForm` 容忍单/双引号（模板改成单引号后不再误判）。
- `LocalCampusService` 解析表格不再逐格 `new RegExp`；URL query 解码包 try（非法 `%` 不再抛 URIError）。

### 新增

- **财务收入查询**（对齐上游 UBAA 2.0 `features/finance/`）：三段认证（SSO →
  icw 门户 → chaxun 换 token）全部逐跳，分页取全、流水号去重、金额以「分」存储。
- **网费流量查询**（对齐 `features/campus/`）：逐跳激活 `zfw.buaa.edu.cn`，
  解析自助服务流量表。解析器已用上游真实 fixture 离线验证通过。
- `CHANGELOG.md`（本文件）。
- 版本号升级到 `0.9.0`（versionCode `1090000`）。
- `docs/tech/upstream-2.0-alignment.md`：上游 2.0 差距与剩余项实现方案。
- `docs/tech/release-compatibility.md`：0.9.0 对 0.1.0 的兼容性结论。

### 安全

- `.gitignore` 补 `/keys/` 与 `*.csr`：签名材料目录（含 DevEco material 凭据缓存）
  一律不入库。

### 兼容性

已发布的 `0.1.0` **不受影响**（独立安装包 + 无自建服务端）。覆盖升级保留全部本地数据
（Preferences 键名未变）。唯一硬约束是**签名必须与设备上已装版本一致**——
当前工程用 DevEco 调试证书，若设备上是 release 签名版则无法覆盖安装，需卸载重装。
详见 `docs/tech/release-compatibility.md`。

### 未完成（本轮）

上游 2.0 还有四项未移植，原因见 `docs/tech/upstream-2.0-alignment.md`：
门户账户指标（小，0.5 人日）、网费套餐合并（小）、云打印（中）、
研讨室预约（大，含验证码与请求签名）、北航云盘（大）、日程与待办（大）。
桌面命令模式不适用于鸿蒙，等价能力是桌面卡片。

## [0.1.0] — 2026-11-11

首个可提交版本：鸿蒙原生重构基线。
