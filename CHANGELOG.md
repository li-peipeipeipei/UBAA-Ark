# CHANGELOG

本项目遵循语义化版本。**versionCode 必须严格递增**（见 `AppScope/app.json5` 注释），
否则 AGC 拒收、真机也无法覆盖安装。

## [0.9.0] — 进行中

> 目标：对齐上游 UBAA 2.0 的功能面。分支 `release/0.9.0`。

### 调整（今日详表卡：三节课不重叠 + 文案）

- **三节及以上课不重叠**：2×4 日卡块矮（每节约 20vp），课程名（13fp）在上、教室（10fp）
  在下会挤到一起。加 `placeBesideName()` 判定（slots≥3）→ 课程名在左占 layoutWeight、
  教室同行贴右（此时不受 `span>1` 限制，三节也显示教室）；两节及以下维持原上下版式。
- 日卡左上角 headline 去掉「今天 · 」前缀（`CardDataBuilder.buildDayView`），只留「周三 · 10/15」。
- 日卡第二行分组标题数字补单位：「今天 3」→「今天 3 节课」。

### 调整（卡片按课表节次自动刷新 + 回桌面重算）

- **按节次链式定时刷新**：`CardCache.scheduleNextRefresh()` 读 `next` 的开始时刻，
  用 `formProvider.setFormNextRefreshTime` 把所有卡的下次刷新精确设到"下一节课开始时"；
  到点 `onUpdateForm` → 卡片进程按系统时间重算 → pushAll → 再设下一次，形成链。
  官方最短 5 分钟、每天 50 次配额（十几节课够用）；无下一节不设点，靠定点刷新兜底。
- 卡片进程 `GlobalContext` 未初始化 → 新增 `ScheduleCache.setFormContext()` 注入 context，
  否则重算读不到课表缓存、退化成旧快照。`CardRefresher` 去掉未用的 TokenStore import。
- **回桌面重算**：`EntryAbility.onBackground()` 调 `CardRefresher.refresh()`，
  用户按 Home / 上滑 / 锁屏回桌面时卡片按系统时间刷新，不再停在旧快照。
  （卡片可见回调 `onChangeFormVisibility` 仅系统应用可用，故走 onBackground。）

### 调整（1×2 小卡：右上角节数 + 教室移时间行 + 名称全宽）

- 删掉原右侧竖列（大数字 + `节/今天` + 教室，占 76vp 挤窄课程名），改为单列全宽三行布局：
  ① 教学周（左）+ **今天 N 节**（右上角，`fontSize(10)` + `text_tertiary`，与大卡同款）；
  ② 时间·节次（左）+ **教室**（右，同一行）；③ **课程名整行全宽**延伸到卡片最右端。
- 三行锁高 15+15+19=49vp，落在 1×2 卡的 61vp 可用高度内。

### 调整（下一节课卡：手机端布局收紧）

- **1×2 小卡**：右侧 `maxWidth` 96→76（原太宽把课程名挤到只剩几个字就省略），右侧字号
  22→20 / 教室 10→9，左侧课程名 15→14、时间行 10→9，padding `{left12,right10,top8,bottom10}`
  （底部留白加大）。一行多显示约两个字再省略，整体不再挤、离底边有留白。
  随后按反馈把内容整体上移 2vp（padding top 8→6 / bottom 10→12，内容区高度不变），
  抵消文字 lineHeight 的视觉下沉，使上下间距观感一致。
- **2×2 大卡**：课程名 19→16（手机宽度小，19 号一行只显示几个字），删除右下角更新时间
  （底部只留「今天 N 节」，SpaceBetween→Start）。
- 同一份卡片代码在手机/平板共用；这些改动在平板上同样是「信息更全」，不改结构。

### 调整（下一节课卡：教室移位 / 系统时间判定 / 加粗）

- **1×2 右下角时间 → 教室**：`ScheduleSmallCard` 删掉右侧「更新时间」行，改成下一节课教室
  （右对齐、可省略）；左侧原教室行删除避免重复。右侧 `constraintSize({maxWidth:96})` 防挤压课程名。
- **两张卡按系统时间判定周次**：`buildToday` 的周次原先取课表页 `this.currentWeek`（用户翻到哪周
  桌面就停在哪周）。`SchedulePage.pushToCards` 改按 `CardDataBuilder.systemCurrentWeek`（校历算今天
  在哪周 + 周日 15:00 滚动），从 `ScheduleCache` 读系统周数据；星期仍用 `DateUtil.currentWeekday()`。
  与 `CardRefresher` 冷启动刷新同口径。
- **加粗**：大卡（2×2）课程名原已 Bold、教室加 Bold；小卡课程名 Medium→Bold、教室 Bold。

### 调整（下一节课桌面卡：1×2 修溢出 + 新增 2×2）

- **1×2 修溢出**：`ScheduleSmallCard` 左侧 4 行文字原行高约 69vp + padding 20vp ≈ 89vp，
  超出 `1*2` 卡约 79vp 的高度 → 最后一行「地点」被裁掉看不见。收 `space 3→0`、
  逐行锁 `lineHeight`（16/15/20/15）、padding 上下 10→6、右侧数字 26→22，
  合计约 60vp 落在可用高度内，4 行全部可见。
- **新增 2×2「下一节课」卡**：`widget/pages/ScheduleNextCard.ets`（`ubaa_schedule_next`），
  复用同一份 `scheduleJson`（含 `next`/`nextWhen`）+ `weekLabel`/`updatedAt`，无需新增数据字段。
  158vp 见方内展示卡片名、教学周、跨天标签、时间·节次、课程名（可两行）、地点、
  今天节数 + 更新时间。空态/无课态各有引导。已注册 `form_config.json`（`2*2` 单规格）
  + `string.json` 两串。卡片红线照旧：不 import 项目文件、不用 hilog、`@LocalStorageProp`+`@Watch`。

### 调整（课表色板扩到 11 槽 + 底字同色系对齐）

- **文字色整板替换**：浅色块文字色按用户取色器实采的 11 色更换
  （`#B09627 / #408333 / #1D8682 / #C5102F / #4272B4 / #D0523B / #CD533E / #C06225 / #CD533C / #D0523C / #CC523D`），
  色板由 8 槽扩到 **11 槽**。`indexOf` 的取模基数是 `DARK.length`，故深色板/浅底/文字三套数组
  必须同步扩到 11，否则第 9-11 槽取不到、文字色越界 Undefined。三处（`ScheduleColors` /
  周卡 / 日卡）× 四套数组全部同步。扩容后所有课程按 `% 11` 重新洗牌取色。
- **底字对齐**：浅底整板按「同索引文字色叠白」重新派生（如 `#B09627 → #F1ECD8`），
  底色与文字永远同色系；描边从块底派生，自动跟随。
  叠白比例 30% → 24% → 18% → **14%**（反馈逐档调淡）。
- **教室行跟随课程名颜色**：浅色下副文字（地点）由中性黑 `#B3000000` 改为
  **课程名文字色的 75% 不透明度**（`#BF` + RGB，新增 `ScheduleColors.subTextForCourse`）；
  桌面两卡同步。深色模式维持原暖白逻辑。

### 修复（个人资料始终获取失败 + 横屏转场缝）

- **个人资料**：`LocalAuthService.fetchUserInfo()` 实测未登录返回 200 +
  `{"code":10600,"data":null}`（非 302）。原代码只在登录时建一次 UC 会话，换网/切路线/冷启动后
  UC cookie 掉了、SSO 仍有效 → 一直报「获取失败」。现识别 10600 时用现有 SSO 会话重建
  UC 会话（`activateUcLogin`）再重试一次；非 2xx/非 JSON 仍走原 `unauthorized` 语义。
- **横屏二级页转场缝**：29 个二级页共用的 `DestShell` 外壳原本不铺底色、只靠
  `HdsNavDestination.backgroundColor`。转场时系统渲染的是 destination 内容树，底色不在参与
  平移的内容上 → 新页面未落位时左缘透明，露出旧页面一条，落位后消失（竖屏无侧栏参照故看不见）。
  现给 `DestShell` 内容外壳铺不透明 `pageBackground`，随页面一起平移，任何一帧都不透。

### 调整（浅色课程块加深 + 多节课块不透底 + 去灰）

- 浅色课程块按反馈再"去灰"：饱和度由 4~5% 提到 15%（明度不变、色相显现），
  三处色板同步；文字色不动（提饱和保持明度时对比度实测几乎不变）。

- 浅色模式所有课程块底色整体加深约 10%（每通道 ×0.9，色相不变）—— 三处色板同步：
  `ScheduleColors.LIGHT`、周卡 `LIGHT_PALETTE_W`、日卡 `LIGHT_PALETTE_D`。
  仍是预混实色、不加真 alpha（真透明会露出网格横线）。
- 多节课块底色由半透明 `sideNavSelected` 改为观感一致但**完全不透明**的预混实色
  `multiCourseBlock`（浅 #A7CCED / 深 #223750 = 侧栏沾色按栏底预混的结果），避免网格横线透出。

### 修复（课表「同时段多节课」蓝块过显眼）

- `SchedulePage.multiCourseBlock` 底色由实色 `brand`（浅 #1976D2 / 深 #5AA9F0，白字）
  改为与侧栏选中块同一个半透明沾色 `sideNavSelected`，文字同步换成品牌色（半透明底上白字看不清）；
  去掉白描边。桌面卡片的合并块走 Monet 课程配色、不随主题变，不在本次范围。

### 修复（浅色模式横屏侧栏选中底色）

- 宽屏侧栏选中项底色由通用 `brandContainerGlass`（浅色约 60% 的 #E3F0FC，与近白栏几乎融在一起）
  改为专用 `sideNavSelected`（浅色 #85B9E8 系，加深但保留半透明以透出材质）；深色模式沿用原值。
  单独建资源色，避免把共用 `brandContainerGlass` 的筛选胶囊 / 学期选择一起改深。

### 新增（平板横屏页面级两栏）

手机与平板竖屏（sm / md）保持原单列，仅 lg / xxl 换形态；判据统一走
`common/Breakpoint.ets::isTwoPane()`（等价 `useSideNav`）：

- **主页**：左「问候 + 日期 / 最近使用 / 待办」、右「考试倒计时 + 今日课程」；
  问候语抽成 `greetingBlock()`，两栏时上移量归零以对齐左右顶边；
- **我的**：左「头像卡 + 校园账户」、右「账户 / 关于 / 退出登录」；
- **成绩查询**：「全部成绩」与「本学期」并排，课程卡按 12 栅格排（lg 2 列 / xxl 3 列）；
- **博雅课程**（选择 / 我的课程）：卡片 md 2 列、lg 3 列；
- **课堂签到**（iclass，`SigninPage`）：左课程列表 + 右签到区（信息 + 签到按钮 + **常驻**签到码），
  `SigninQrSheet` 新增 `embedded` 模式；两栏下左栏点卡片只做选择，写操作全部收到右栏；
- **阳光打卡**（`YgdkPage`）：左打卡操作卡（一键打卡 / 项目 / 地点 / 分享 / 按选项提交），
  右统计卡（学期 / 周 / 月）+ 打卡记录列表，左右 1 : 1.4。

### 新增（主页明日课程 + 今日课程三态）

- 主页「今日课程」在同一张卡内按状态切换：今天没课 → 空态 + 明日课程；
  今天全部上完 → 「今日课程已完成」且今日列表不再显示 + 明日课程；
  其余情况只显示今日课程，**不出现明日课程**。
- 「全部上完」按课程结束时间判定（每门课都要有时间串且已过），不依赖 iclass 签到；
  由 30 秒 tick / 回到前台 / 数据加载后推进，最后一节课下课即自动切换。
- 明日课程复用教务 `detail.do?rq=日期`，新增 `LocalAcademicService.fetchClassesOn(date)`
  与 `ApiService.fetchClassesOn(date)`；缓存键按日期隔离，跨天自动重拉。
- 明日课程行独立实现，不接签到与详情点击 —— 避免同名课错拿今天的签到状态。
- 今日无课空态改成一行轻文字、去掉图标：原通用 `EmptyView`（44vp 图标 + 上下各 60vp）
  会把紧接着的明日课程顶出一屏。
- 「最近使用」入口按卡片**实际内宽**自适应个数（4~8 个，手机 4 / 平板竖屏 8 /
  两栏左栏约 6），每项 `layoutWeight(1)` 等宽铺满，标题居中并可截断；
  不再固定 4 个 62vp。
- 平板两栏右栏首块与左栏「最近使用」齐顶：右栏顶部放一份隐藏的 `greetingBlock()`
  占位（跟随问候语实际高度，不用写死 padding）。
- 今日课程卡副标题只在有课时显示「N 节课」；无课 / 已完成时留空，状态提示只在卡内出现一次。
- 明日课程行可点开与今日课程同一个详情弹窗：新增 `openTomorrowDetail()` 按明天的 weekday
  匹配课表，`findCourseByNameAndTime` 增加 `strict` 参数并在明日场景关闭「仅凭名字取第一条」。
- 修复明日课程详情只有「时间 / 地点」两项（理论力学实例）：周日时明天属下一教学周，
  本周课表不含单双周交替的课程；`coursesForTomorrow()` 在周日按 `thisWeek + 1` 重取课表。
  同时让「时间串完全相等的同名课」兜住 `dayOfWeek` 缺失的课表条目。

### 修复（「展开页 → 页内二级页 → 返回」后功能块消失）

功能页点「博雅课程」→ 博雅首页 →「我的课程」→ 返回功能页时，「博雅课程」块视觉消失、
位置上仍可点击，再进出一次才恢复。真因是原卡片只在 `finishShrink()` 里被放回来，
这条路径上走的是系统默认转场（或收缩信号因页面被回收而丢失），SHOW 从未发出：

- POP 且栈顶不是展开页时：延时确认「已回到功能栈根」即 `notifyTileShow()`（判据用栈深，
  不用 `NavContentInfo.name`）；
- POP 接管转场时增加 1200ms 兜底：收缩始终没开始就强制 `finishShrink()`
  （放开卡片 + 释放转场 proxy），轮次号防串。详见 `docs/tech/feature-tile-transition.md`。

### 改进（图书馆座位块自适应列数）

预约座位页的座位网格从固定 4 列改为按最小块宽（76vp）反推列数：手机仍 4 列，
平板横屏到 10 列，块宽不再被拉成 230vp 的方块。用新增的
`Breakpoint.columnsByMinWidth()`（不做整除优化，避免块大小随数据跳档）。

### 修复（并排卡片因标题行数不同而高低错落）

平板横屏多列卡片里，标题占 2 行的卡比占 1 行的高出约 20vp，同一行高低不齐
（博雅「选择课程」「我的课程」、成绩查询三页实机可见）：

- 新增 `AppSize.cardTitleTwoLines(fontSize)`：标题固定占两行高度，1 行标题在标题区留白，
  2 行正好铺满；超过 2 行仍由 `maxLines(2)` 截断，不会继续撑高卡片；
- 应用于成绩课程卡（`AppFont.subtitle`）、博雅两张课程卡（`AppFont.body`）；
- 成绩页两张概览卡并排时，「全部成绩」补显示课程数 / 总学分（数据本就在 `allSummary`），
  与「本学期」行数一致、底边对齐；手机端仍为原版三行指标；
- 其余并排容器（功能磁贴 `aspectRatio`、图标卡、我的页指标格、空闲教室座位表）已核过不受影响，
  清单见 `docs/tech/tablet-adaptation.md` §3.5 第 4 条。

实现约束与踩坑记录见 `docs/tech/tablet-adaptation.md` §3.5。

### 新增（双路线会话：换网后不再要求重新登录）

原来登录只认证**当前那一条**路线，校内只登 Direct、校外只登 WebVPN，另一条路的
Cookie 罐永远是空的 —— 换网（宿舍 Wi-Fi ↔ 流量、校内 ↔ 校外）就必然掉回登录页。
原版从不要求重登，靠的是「一次登录灌满两条路 + 缺会话时用已授权凭据静默补登」，
本轮按此补齐：

- `LocalAuthService.loginDual()`：按 `RouteEngine.loginRoutes()` 顺序认证两条路线
  （校园网仅 Direct，校外主+备）；主路线失败照旧抛错，副路线失败只登记（`partial`）；
- `RouteScope`：新增路线作用域，让一条登录流程能在**另一条路线**上完整跑完
  （地址改写、Cookie 读写、会话落槽全部按作用域走）；作用域内禁止网络层自动换路；
- `PreparedLogin.mode`：一次性令牌只在所属路线上有效，杜绝跨路线复用；
- `SessionGuard`：目标路线缺会话时用保存凭据静默补登（按路线单飞、`TRANSIENT` 保留会话、
  验证码即停）；接入 `adaptToNetwork` / `onNetworkChanged` / 启动自检 / 登录页；
- 主动退出标记 `signed_out_flag`：退出只清会话不清密码，但禁止静默重认证把人登回来；
- 401 只清**当前路线**的槽位（原来 `clearAllLocalSessions` 会把另一条活会话一起清掉）；
- `logout()` 对两条有会话的路线各注销一次（对齐上游 `remote_logout` 各调一次）。

详见 `docs/tech/session-dual-route.md`，路线判定表更新见 `docs/tech/auto-route-switch.md`。

### 修复（过夜后第一次点「登录」报 `Error decoding flow execution`）

真因是一次性令牌的有效期属于**服务端 webflow 会话**：应用被冻结在后台过夜后
`aboutToAppear` 不会重跑，手里那份 `execution` 仍是隔夜的，而服务端会话早已超时回收。
二次放大：`loginOnce()` 原先「调用方传的令牌优先于刚取到的新页面」，方向正好反了；
且该错误页没有表单与 `tip-text`，只会被泛化成「账号或密码验证未通过」，把人引去改密码。

- `CasParser.isFlowExecutionExpired()`：认 Spring Webflow 的固定英文标记，
  在 `followAndCheck` / `activateUcLogin` 里**排在凭据错误之前**判定；
- `LocalAuthService.login()`：识别到 `cas_flow_expired` → 清准备页、整轮重试一次
  （含自动验证码），用户无感；
- `PreparedLogin.preparedAt` + 5 min TTL：`loginOnce()` / `submitCaptcha()` 提交前判旧，
  过期先换新页面；`loginOnce()` 改为**只信准备页里的令牌**，不再采信调用方缓存；
- `LoginPage` 侧同口径兜底：`warmedAt` 空置超期先 `warmUp()` 再提交；
- 验证码路径：准备页过期时 `submitCaptcha()` 重取挑战，新页面若不再要验证码则直接普通登录；
- `friendlyMessage()` 新增 `cas_flow_expired` → 「登录页面已过期，请再点一次「登录」」。

详见 `docs/tech/login-2.0.2-parity.md` §5.2。

### 修复（首页反复「登录状态已失效，请重新登录」）

真因不在登录链路，也不在会话过期，而在 **Cookie 罐**：真正的会话凭证
（byxt 的 `GS_SESSIONID`）从来没被存进去，于是每个取数接口都 401，
页面把 401 一律翻译成「请重新登录」，用户点多少次重载都不会好。

- **`Set-Cookie` 只取首个头**：`headerValue(…,'set-cookie')` 在响应头是
  `string[]` 时只返回 `[0]`。上游「先删旧、再发新」成对下发时，罐子里只剩删除指令
  （真机可见 `_WEU … Max-Age=0`，且没有 `GS_SESSIONID`）。改用新增的
  `headerValues()` 全量遍历，每个头再过 `splitSetCookie`。
- **未声明 `Path` 时拿整个请求路径当 cookie path**：cookie 被钉死在
  `…/api/home/currentUser.do` 上，`getTermWeeks.do` / `schoolCalendars.do` 全都带不上。
  改为 `defaultPath()`（RFC 6265 §5.1.4，截到目录级）；存量坏数据由
  `normalizeLegacyPaths()` 自愈，**不需要重新登录**。
- **会话判据误报**：`doEnsureByxt` 原本「是 JSON 就算就绪」，而 `currentUser.do`
  对匿名请求也回 200 + JSON 信封。改为 `isByxtLoggedIn()` 校验 `code === '0'`；
  数据接口已明确 401 时走新增的 `forceReauthByxt()` 无条件重签，不再被探测短路。
- 401 时日志补 `上游带 Cookie <host>：<cookie 名列表>`（只打名字，值不落盘），
  用于区分「没带凭证」与「带了被拒」。

真机验证（PLR-AL50 / API26）：连续 4 次冷启动 + 1 次下拉刷新，
`byxt` 全部接口 200，`401 / 登录状态已失效` 计数 0；今日课程 1 条、
周课表 16 门 / 13 节、成绩与 SPOC 预取全部正常。
详见 `docs/tech/troubleshooting.md`「刚登录就提示登录失效」一节。

### 修复（功能块展开转场：云打印跳色 + 平板竖屏圆角跳变）

两个都是「卡片」与「转场遮罩」数据不同源，与动画参数无关。

- **云打印跳色**：`FeatureItem` 的 `color`（卡片渲染）写的是 `AppColor.brand`（蓝），
  而 `colorValue`（遮罩基础色）是青色 `#00897B` —— 11 个功能块里唯一不匹配的一个。
  新增 `accent_teal`（浅 `#00897B` / 深 `#26A69A`）+ `AppColor.accentTeal`，
  云打印改用青色。
- **平板竖屏圆角跳变**：`FeatureTile.radius` 缺 `@Prop`。普通成员只在初始化时赋值，
  父级按实测块宽重算的 `tileRadius` 既不写入也不触发重绘 —— 卡片圆角永远停在兜底 28，
  而遮罩用的是实测值。断点兜底列数与实测列数差得越远越明显：
  平板横屏 6→5（圆角都是 28，无差）、手机 4→2~3（差 1~3vp）、
  平板竖屏 **6→4**（差 5vp 以上）—— 这就是「只有平板竖屏看得出来」的原因。
- 顺带加固：`onBounds` 增加 `radius` 参数，由卡片上报**自己正在渲染的**圆角，
  遮罩优先用它。以后即使再出现父子不同步，转场也不会跳到另一个圆角上。

详见 `docs/tech/feature-tile-transition.md` 末节。

### 修复（课堂签到「永远失败」，同步上游 2.0.3）

11-19 那轮把失败归因于参数载体，按冻结旧版 v1.7.2 实现 —— **归因错了**。
上游 2.0.3（2026-11-19 抓包裁决）确认：`stu_scan_sign` 是**扫码签到**接口，
拿它当自动签到提交，上游第一步就回 `ERRMSG=!appMsg.qxktSign!`。

- 提交改用 `stu_auto_sign.action`：端口 **8181**（既非列表的 8347、也非二维码的 8081），
  `POST` **无查询串**，表单恰好六字段 `id` / `courseSchedId` / `routerInfo` /
  `longitude` / `latitude` / `machineInfo`，**不带时间戳**。
- 提交不再先取时间戳：那条链路是扫码用的，混进来只会多一跳请求和一个假依赖。
- `checkinUrl()` 降级为读接口基址，注释禁止与提交入口合并。

详见 `docs/tech/upstream-2.0.3-sync.md`。

### 新增（课堂签到二维码）

对齐上游 2.0.3 的扫码签到：把 `stu_scan_sign` 的码显示出来供 iClass App / 微信扫。

- `LocalSigninService.buildScanQrContent(courseId, offsetMs)`：服务端时间戳 + 偏移拼 URL。
  时间戳必须是上游的，`Date.now()` 拼的码对方判为无效。
- `components/SigninQrSheet.ets`：`@kit.ScanKit` 的 `generateBarcode` 渲染，
  **无需三方库、无需权限**；每 2 秒刷新、每 3 秒轮询已签到。
- 「保存到相册」走 `photoAccessHelper.showAssetsCreationDialog`（弹窗授权），
  **不声明 `WRITE_IMAGEVIDEO`**；编码用 `packToData`（`packing` 已废弃）。
- 入口是卡片底部的弱文字「出示签到码 ›」，不做成第二个主按钮 —— 点错的那个是
  不可撤销的写请求。
- 浮层用 `.overlay()` + `if (courseId)` 条件挂载，绕开 `@Builder` 普通参数
  不参与刷新的坑。

### 新增（登录自动切换直连 / WebVPN，含可行性研究）

对齐上游 `RoutePolicy::Auto`（`connection.rs` + `facade/routing.rs`，契约见
`docs/contracts/route-policy.md`）。可行性研究见 `docs/tech/auto-route-switch.md`。

- **路线策略** `AUTO / DIRECT / WEBVPN`（默认 **AUTO**）：策略与「实际路线」分成两个键，
  程序只维护后者，用户意图永不被覆盖。登录页与设置页三选一。
- **校园网探测** `CampusProbe`：对 `gw.buaa.edu.cn:80` 做纯 TCP 探测（不发 HTTP/TLS、
  不带凭据），500ms 总预算、只认 `10.0.0.0/8`（排除代理 fake-ip）、3 秒缓存 + 单飞。
  用 `connection.getAddressesByName` + `socket.TCPSocket.connect`，**无需新增权限**。
- **登录自动切换**：登录前探测 → 校内直连 / 校外 WebVPN；网络层失败自动换另一条路再试
  一次（凭据错误/验证码不换路）。预热令牌跨路线会作废并自动重新预热。
- **读请求自动回退**：网络层失败时重新探测，切到另一条**已有会话**的路重试一次
  （`get`/`getBinary` 与只读 `post*`；**写入永不自动重发**）。
- **换网自愈**：订阅 `netAvailable/netCapabilitiesChange/netLost`（1.5s 去抖）+ 回前台复查；
  启动时把「活会话所在的那条路」找回来，避免平白弹登录页。

🔴 **与上游的刻意差异**：不做「校外并发双路登录」。同账号两次并发 CAS 登录会翻倍认证
请求、可能触发风控/锁号（本项目把账号锁死风险列为红线），且双会话要求登录 UI 表达
两条路各自的状态。单会话下校外统一走 WebVPN，功能完全可用，只是都经网关转发。

### 新增（功能补全，2026-11-17 下午）

按 `docs/tech/upstream-2.0-alignment.md` 的差距表补 5 项（研讨室/云盘/日程按约定不做）：

| 项 | 实现 |
|---|---|
| 我的页 5 项指标 | `LocalPortalService`（对齐 `campus/portal.rs`）：网费余额、一卡通余额、未读邮件、待还图书、云盘剩余。**单项失败不影响其它项** |
| 网费套餐合并 | `campus/packages.rs`：产品行嵌套套餐子表的「可用流量」累加到免费剩余，1024 进制折算；计费剩余保持原值 |
| 离线缓存铺开 | `common/OfflineCache.ets` + 财务/成绩/考试/空教室四页：打开先显示本机记录并标「离线记录」，失败保留旧数据 |
| 首页待办 + 最近使用 | 待办=未提交且未过期的 SPOC 作业（前 3）；最近使用=本地记录的真实使用轨迹（`RecentFeatures`，4 个入口） |
| 云打印（只读） | `LocalCloudPrintService` + `CloudPrintPage`：文档列表（打印+扫描）与打印站状态。上传/预览/下载/删除**不做** |

### 修复（真机反馈，2026-11-17 下午）

- **网费流量 / 自动评教打开即报「登录状态已失效」**
  根因是 CAS 判据写错：这两处把「重定向目标出现 `sso.buaa.edu.cn`」直接判成会话失效。
  而统一认证**有**会话时的正常签发路径必然经过 sso：
  `业务站/sso/cas/index` → 302 `sso.buaa.edu.cn/login?service=…` → 302 回业务站带 `ticket=ST-…`。
  看到中间那跳就抛错 = **只要需要签发就报登录失效**，于是登录后第一次打开这两个页面必失败。
  修法是补上另一半判据：**当前页与下一跳都停在 sso**（回不到业务站）才算真失效，
  与 `LocalFinanceService.walkPortal` 的写法一致（财务页一直正常，正是因为它用了双重判据）。
  两处的 `isOk()` 分支原本就有终点校验，无需改动。

### 新增（财务页补齐，对齐上游「财务查询」）

原版有 6 项能力，此前只做了列表展示。本次补齐：

| 能力 | 说明 |
|---|---|
| 年份筛选 | 「全部」+ 各年份胶囊，点击切换 |
| 合计统计 | **实发合计**（大字）+ 笔数 + 应发 + 扣税，随搜索/筛选联动 |
| 按月分组 | 每月一卡，标题显示当月**实发小计**；最新月份在上 |
| 搜索 | 「项目或摘要」模糊匹配 |
| 点开明细 | 应发、扣税、实发、税率、所属年月、录入日期、**流水号**（与 SPOC 详情同版式弹窗） |
| 下拉刷新 | 刷新失败保留旧数据（与上游「刷新失败时保留上次的记录」一致） |

并补充了 `docs/tech/upstream-2.0-alignment.md` 的**功能差距总表**（20 项逐条对照上游
README 与官方文档站，标注「✅ / 部分 / ❌」与补全优先级）。

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
官方《应用启动页简介》明确：**启动页到应用内容有 200ms 透明渐隐** —— 这 200ms 里
两种底色同屏，色差会被直接看到，所以这条不是"锦上添花"。

**上线后复查修复**（自查本轮改动）

- `IhomePage.switchScope` 原来**无条件** `BackGuard.unregister()`：用户没展开过公告时，
  它会把**别的页签**注册的那一层弹掉（那层的关闭动作从此丢失）。改为只注销自己那层。
- `StartupPrefetch` 在 900ms 等待窗口内被 `cancel()`（切后台）后，`run()` 仍会先跑一次
  学期请求（一次 CAS 换取）才收手。入口处补 `cancelled` 判断。
- `ImmersiveUtil` 用布尔标记记录「监听已注册」：`onWindowStageDestroy → onWindowStageCreate`
  会拿到**新的** Window 实例，此时新窗口再也挂不上监听（安全区/断点从此不更新）。
  改为按窗口实例比对。
- `MemoCache` 只写不清：周课表单条就有几十 KB，翻遍整个学期会持续涨。
  超过 32 条时按「先清过期、再丢最旧」回收。
- `HomePage` 的**重试按钮**走了缓存（`loadHome(true)` 推出 force=false）：网络恢复后
  点重试仍拿旧值。`loadHome` 增加独立 `force` 参数，重试与下拉刷新都显式传 true。
- `Index` 每次横竖屏重建都发一次 `status()`：改为成功自检后 5 分钟内不重复
  （失败不记时间，下次重建仍会重试）。
- 成绩预取加自适应闸门：前几步已用掉一半预算就跳过，避免慢网络下再插一条 CAS 链。
- 研究文档补入官方 200ms 渐隐的原文依据。

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
