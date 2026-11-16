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

### 新增（启动预加载，含可行性研究）

研究文档：`docs/tech/startup-prefetch-feasibility.md`。

结论是**不做「五个功能一起预取」**：按「参数确定 / 可复用 / 不写界面」三条门槛筛选后，
前五功能里只有**课表、考试、成绩**可预取；空闲教室与博雅依赖用户选择参数、阳光打卡要额外走
≤10 跳 oauth 链，预取收益为负，明确不做。

- `common/MemoCache.ets`：TTL + **单飞**。单飞不只是省流量 —— 首页与课表页同时启动时，
  两个请求会各自「整罐读 → 改 → 整罐写」Cookie，后写的覆盖前者。
- `network/LocalAcademicService.ets`：`terms / weeks / weekly / today / exams / grades`
  六个接口改为「缓存包装 + `doFetchXxx`」，新增 `force` 逃逸口；`reset()` 里清缓存。
- `common/StartupPrefetch.ets`：首帧后 900ms 启动、总预算 9s、串行执行
  （会话唤醒 → 学期 → 周次 → 当前周课表 → 考试 → 本学期成绩），
  每步独立 try/catch，超预算 / 切后台（`onBackground`）/ 已登出立即停手。
- 刷新路径必须 `force = true`：课表逐周比对（2 处）、重试按钮、首页下拉刷新
  —— 否则「拿自己刚缓存的那份去比」，永远比不出差异。

**与启动动画快照的关系**（研究文档第四节）：
预取只写缓存、不碰 `@State`/`AppStorage`，界面变化仍由页面自己的状态机驱动；
`start_window_background` 由 `#FFFFFF` 改为 `#F1F3F5`，与 `page_background` 完全一致，
消除「启动窗口 → 首帧」的颜色突变（深色本来就是 `#000000`）。

### 修复（第二轮巡检：桌面卡片 / 启动流程 / 登录）

**登录**

- **密码打错一次后「怎么输都登不上」**：CAS 的 `execution` 是一次性令牌，提交过一次即作废，
  但 `LoginPage` 只在「验证码」和「切连接模式」两处清空它 —— 普通凭据错误后一直复用死令牌，
  服务端永远判「凭据无效」，只能杀进程重进。现在任何失败都清空，下次现取。
  （例外：`CaptchaRequiredError` 带下来的新令牌必须保留，它与屏幕上的验证码图是一对。）
- **验证码错一次后永远对不上**：图片与令牌都是一次性的，失败后旧图仍留在屏幕上，
  用户反复对着它输。现在失败即清空输入并重新预热（换图 + 换令牌）。
- **同一帧双击连发两次登录**：补入口防重入（只靠按钮 `enabled` 挡不住）。

**桌面卡片**

- **成绩卡 / 空闲教室卡未注册**：`GradeCard.ets`、`ClassroomCard.ets` 与对应字符串资源、
  缓存写入、推送链路全都在，但 `form_config.json` 里没有这两项 —— 用户在「添加卡片」
  里根本看不到，主应用却每次都在为它们读盘+推送。已补 `ubaa_grade_small` /
  `ubaa_classroom_small`（均 1×2）。
- **卡片白屏不可自愈**：周/日课表卡把 Preferences 里读到的 JSON 直接 `as` 用，
  缺字段时渲染期读 `undefined.length` 直接抛异常，且 `@Watch` 不会自愈（只能删卡重加）。
  现在 parse 后逐字段归一化。
- **卡片刷新失败会永久空白**：`onAddForm` / `onUpdateForm` 里组数据没有 try/catch，
  抛异常时系统认为本次刷新失败并不再重试。现在失败返回空 payload 走空态。
- **formId 可能存进 null**：`onAddForm` 先校验 `IDENTITY_KEY` 再登记（否则每次 pushAll
  都对 null 调 updateForm 报错且清不掉）。

**启动与生命周期**

- **每次回前台都被弹回课表页**：`onForeground` 用 `lastWant` 反复消费卡片路由，
  `lastWant` 永不清空 → 点过一次卡片后，任何页签/二级页切后台再回来都会 `clearStack` +
  跳课表。现在消费一次即置空。
- **转屏/折叠屏展开时全量推卡片**：`onConfigurationUpdate` 无条件 `pushAll`（invalidate +
  读 9 个 key + 逐卡 IPC），正好压在转场动画上。现在只在深浅色真的变化时才推。
- **后台自检会踢掉刚登录的用户**：冷启动的会话自检是网络往返，用户期间登录成功后
  旧结果照旧落地会把 `loggedIn` 置 false。加代次令牌，登录/登出即作废在途结果。
- 删除 `Index` 里已失效的 `restoreSession`（52 行死代码，与「先亮界面 + 后台自检」并存的旧实现）。

**其它**

- **版本号漂移**：`AppConfig.APP_VERSION` 停在 `0.1.0`，而安装包已经是 `0.9.0` ——
  关于页、User-Agent、检查更新都在报错版本。现在启动时用 `bundleManager` 读安装包的
  真实 `versionName` 覆盖，字面量只作兜底。
- **「检查更新」永远提示「已是最新版本」**：不看返回体，服务端说「有新版本 x.y.z」时
  也弹这句。现在解析 `hasUpdate/latestVersion/forceUpdate` 后再提示。
- **SPOC 连点作业叠出多个弹窗**：`openDetail` 无防重入，每次新建一个
  `CustomDialogController`（旧的既不 close 也不释放）。现在加互斥 + 先关后开；
  并在 `aboutToDisappear` 里关掉，避免对话框持有已卸载页面。
- **`MaterialCardLayer` 每次重建都重挂材质**：`attributeModifier` 用对象字面量写在 build 里，
  每次都是新实例。改为按「是否带投影」预建两个常量，build 只挑引用。
- **我的页面隐蓝卡定时器未清理**：连点会叠定时器，页面销毁后仍写 `@State`。
  现在保存 id、重复调用先清、`aboutToDisappear` 再清一次。


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
