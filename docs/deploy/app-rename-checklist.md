# 应用改名 · 全量改动清单

> 用途：把当前显示名 `UBAA` 改为新名称时，逐项核对，避免漏改。
> ⚠️ 本清单针对**显示名（label）**。**包名 `com.ubaa.app` 不在改动范围内**——改包名等于换应用，上架后不可改，且需重签 Profile、重做全部上架材料。

---

## 0. 改名前必须先确认的两件事

1. **新名字合规红线**（照旧，别踩）：
   - 不得含「智慧北航」「i北航」「北航官方」等学校官方应用名，不得用校徽；
   - 不得含华为保留词单独成段：`oh` / `ohos` / `harmony` / `harmonyos` / `openharmony` / `system`；
   - 应用名 ≤ 30 字符，一句话简介 ≤ 17 字。
2. **上游授权是否覆盖新名字**：授权书与 MIT 许可要求保留「基于开源项目 UBAA 开发」的署名。改名后**本应用名可以变，但上游 UBAA 的署名不能删**（见第 5 节）。

---

## 1. 代码与资源：决定桌面图标下显示的名字（必改）

| 文件 | 字段 | 现值 | 说明 |
|---|---|---|---|
| `AppScope/resources/base/element/string.json` | `app_name` | `UBAA` | 应用级名称，系统应用管理里显示 |
| `entry/src/main/resources/base/element/string.json` | `EntryAbility_label` | `UBAA` | 桌面图标下方显示名 |
| `entry/src/main/resources/base/element/string.json` | `EntryAbility_desc` | `UBAA · 校园服务聚合客户端` | Ability 描述 |
| `entry/src/main/resources/base/element/string.json` | `module_desc` | `UBAA 鸿蒙原生客户端主模块` | 模块描述 |
| `entry/src/main/resources/base/element/string.json` | `UBAAFormAbility_label` | `UBAA 服务卡片` | 桌面服务卡片名 |
| `entry/src/main/resources/en_US/element/string.json` | `EntryAbility_label` / `module_desc` / `EntryAbility_desc` | 同上英文 | 英文限定名也要同步，否则英文环境显示旧名 |

> `AppScope/app.json5` 的 `label` 和 `entry/src/main/module.json5` 的 `label` 都是引用 `$string:...`，**不用直接改**，改上面资源即可。

### 1.1 代码中硬编码的用户可见文案（视定位决定是否改）

| 文件 | 内容 |
|---|---|
| `entry/src/main/ets/widget/pages/ScheduleSmallCard.ets` | 兜底文案 `'UBAA 课表'` |
| `entry/src/main/ets/network/LocalBykcService.ets` | 错误提示「请重新登录 UBAA 后再试」（3 处） |
| `entry/src/main/ets/network/ApiError.ets`、`ApiService.ets` | 「UBAA 接口」「UBAA 服务端」等提示 |

> ⚠️ **不要全局替换源代码里的 `UBAA`**：绝大多数注释和「基于开源项目 UBAA 开发」字样是**上游项目署名**，属于 MIT 许可要求保留的内容，删了会违反上游授权。

---

## 2. 应用图标（最容易漏，必须重做）

当前图标 `docs/deploy/app-icon-1024.png` 上**直接烧录了白色 "UBAA" 四个大字**。改名后图标必须重画，否则桌面显示新名、图标却是旧字母。

| 产物 | 路径 | 生成方式 |
|---|---|---|
| 满幅基准图 | `docs/deploy/app-icon-1024.png` | 用新名字重画（蓝底 #1976D2 + 白字） |
| AGC 上架图标 | `docs/deploy/app-icon-216.png`、`app-icon-512.png` | 由 1024 等比缩放 |
| 包内单层图 | `AppScope/resources/base/media/app_icon.png`、`entry/src/main/resources/base/media/app_icon.png`、`startIcon.png` | 同步替换 |
| 分层资源 | `AppScope/resources/base/media/foreground.png` + `background.png`、`entry/.../base/media/` 同名两份 | 跑 `.backup/make_layered_icon.py` 从新基准图反解生成 |

> 注意 AGC 图标规范：216/1024 正方形 PNG ≤3MB；分层资源不得自行裁剪圆角 / 加内边距；透明圆角用底色填平。

---

## 3. 商店截图与文案

| 项 | 位置 | 说明 |
|---|---|---|
| 截图品牌小字 | `docs/deploy/shots-config.json`、`shots-config-tablet.json` 的 `brand` 字段（现值 `UBAA 鸿蒙版`，共 12 处） | 改为新品牌字后，**重新合成全部 18 张介绍图**（手机 App Store 6 + 手机 AGC 6 + 平板 6） |
| 应用介绍 | `docs/deploy/store-description.md`、`store-listing.md`、`agc-form-fill.md` | 把作为「本应用名」的 UBAA 换成新名；「基于 UBAA（MIT）开发」那句保留 |
| 一句话简介 | `store-listing.md`、`agc-form-fill.md` | 现值「北航课表成绩图书馆，一站式查询」，检查是否要带新名（≤17 字） |

---

## 4. 协议托管页（两份链接都会受影响）

| 协议 | 文件 / 后台 | 改法 |
|---|---|---|
| 用户协议 | `site/index.html`（标题 + 正文里的 UBAA） | 改完 push 到 `main`，GitHub Actions 自动重新部署，**链接不变** |
| 用户协议正文源 | `docs/deploy/authorization-materials/用户协议-UBAA.md` | 同步改名 |
| 隐私政策（包内源） | `docs/legal/privacy-policy.md`、`entry/src/main/ets/pages/mine/PrivacyPage.ets` | 两处必须一致 |
| 隐私政策（华为托管） | AGC 协议服务里那份（agreementId `2085146074820909824`） | 回协议服务**编辑协议文本**保存，**链接不变**；顺手把之前两处坑（收集范围多勾、存储期限"无的服务器"）一并修了 |

> 两份协议都公开可访问、无需登录。改完务必重新打开链接核对页面显示的是新名字。

---

## 5. 授权与法律材料

| 文件 | 字段 |
|---|---|
| `docs/deploy/authorization-materials/授权书-软件著作权授权发行书.md` | 「被授权软件名称」= `UBAA` → 改新名；包名 `com.ubaa.app` **不动** |
| `docs/deploy/authorization-materials/README-材料说明.md` | 「被授权软件名称为『UBAA』」 |
| 授权材料 zip | `docs/deploy/authorization-materials/授权材料-UBAA.zip` | 改完重新打包 |
| 关于页 / 开源许可页 | `entry/src/main/ets/pages/mine/AboutPage.ets`、`LicensePage.ets` | 把「本应用」的名字换成新名；「基于开源项目 UBAA 开发」保留 |

---

## 6. AGC 后台与外围（需你本人操作）

| 项 | 说明 |
|---|---|
| AGC → 应用信息 → 应用名称 | 改新名；⚠️ 改应用名通常要**重新提交版本审核** |
| 软著名称 | 若已申请，需与新名一致；已下证的软著改名要走变更 |
| ICP 备案 | 备案信息里的应用名称需与新名一致（备案主体不变） |
| 测试账号 / 审核信息 | 若文案里带应用名，同步 |

---

## 7. 明确不改的项

- `bundleName` = `com.ubaa.app`（所有 json5、Profile、文档里的包名）
- 代码注释与文档中**指代上游开源项目**的 `UBAA`（MIT 署名，保留）
- 模块名 `entry`、Ability 类名 `EntryAbility` / `UBAAFormAbility`（改类名无意义且易出错；`UBAAFormAbility` 只是标识符，用户不可见）
- `vendor` = `BUAASubnet`

---

## 8. 建议执行顺序

1. 定新名 → 过一遍第 0 节合规红线
2. 改第 1 节资源文件（显示名）
3. 重做第 2 节图标（基准图 → 分层资源 → 上架图标）
4. 改第 4、5 节协议与授权材料
5. 改第 3 节文案 → 重新合成截图
6. 改第 6 节 AGC 后台 → 重新打包签名 → 重新提交审核
7. 全量构建 + 真机验证（桌面名、卡片名、图标、关于页、协议链接）
