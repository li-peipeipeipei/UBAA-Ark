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
