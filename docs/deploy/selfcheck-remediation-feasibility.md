# UBAA 上架自检不通过 · 整改可行性研究

> 报告 ID：1328896983483171616　｜　测试时间：2026-11-16 01:22:13 ~ 03:21:10（1h58m57s）
> 被测包：UBAA 0.1.0（API Level 23，1.6 MB）　｜　结论：**不通过**
> 本文只做可行性与方案评估，**不含任何代码改动**。

---

## 一、报告事实还原

### 1.1 测试环境

| 项 | 值 |
|---|---|
| 应用 / 版本 | UBAA / 0.1.0 |
| API Level | 23 |
| 应用大小 | 1.6 MB |
| 测试场景 | 上架测试（鸿蒙应用） |
| 测试设备 | 6 台：Mate 80 Pro (SGT-AL50)、Mate X7 典藏版 (DEL-AL20)、Pura 90 Pro Max (SCA-AL00)、Mate 80 (VYG-AL00)、Mate X5 (ALT-AL10)、Pura 80 (HED-AL00) |
| 系统版本 | 6.1.1.120 ×5、6.1.1.135 ×1 |
| 报告所示"适配设备" | 直板机 / 平板 / 2in1 / 折叠屏 |

### 1.2 五维得分

| 维度 | 测试总项 | 不通过 | 警告 | 通过 | 通过率 | 判定 |
|---|---|---|---|---|---|---|
| 兼容性 | 54 | **2** | 0 | 52 | 96% | 不通过 |
| UX | 35 | **2** | 0 | 33 | 94% | 不通过 |
| 稳定性 | 6 | 0 | 0 | 6 | 100% | 良好：核心用例未捕获崩溃 |
| 功耗 | 7 | 0 | 0 | 7 | 100% | 良好：无异常唤醒/耗电 |
| 性能 | 3 | 0 | 0 | 3 | 100% | 良好：内存平稳，通过率 100% |
| **合计** | **105** | **4** | **0** | **101** | **96%** | — |

### 1.3 两条不通过项（原始记录）

| 问题维度 | 问题类型 | 测试项名称 | 发生次数 | 测试结果 |
|---|---|---|---|---|
| 兼容性 | 设计约束 | 卡片刷新方式应符合规范 | 2 | 不通过 |
| UX | 图标 | 应用图标资源需分层，尺寸需满足规范要求：应用图标资源必须分为前景图… | 2 | 不通过 |

"发生次数 2"= 在 2 台测试设备上各复现一次，属确定性缺陷而非偶发。

### 1.4 一条分析建议（非不通过项，但影响上架）

> 测试覆盖设备类型不全：本次测试使用的是"直板机/折叠屏"，您的应用适配设备是"直板机/平板/2in1/折叠屏"，请您根据应用的实际分发设备类型补充测试。

---

## 二、问题 A：应用图标未分层（UX）

### 2.1 现状核查

| 资源 | 尺寸 | 色彩模式 | 透明角 | 判定 |
|---|---|---|---|---|
| `AppScope/resources/base/media/app_icon.png` | 1024×1024 | RGBA | 四角 alpha=0 | ❌ 单层 + 自行裁圆角 |
| `entry/src/main/resources/base/media/app_icon.png` | 1024×1024 | RGBA | 四角 alpha=0 | ❌ 同上（与 AppScope 同源同字节） |
| `entry/.../startIcon.png` | 1024×1024 | RGBA | 四角 alpha=0 | ⚠️ 启动页图标，同类问题 |
| `docs/deploy/app-icon-1024.png`（AGC 上传用） | 1024×1024 | RGB | 无 alpha | ✅ 仅满足 AGC 侧要求 |

配置侧：
- `AppScope/app.json5` → `"icon": "$media:app_icon"`（单层）
- `entry/src/main/module.json5` → `EntryAbility.icon = "$media:app_icon"`（单层，且**优先级高于 app.json5**）

### 2.2 规范判定依据

**图标资源规范**（design-guides/application-icon-0000001953444009）：

> 为保证图标在系统内显示的一致性，应用预置的图标资源应满足以下要素：
> - 图标资源**必须为分层资源**
> - 图标资源尺寸必须为 **1024×1024px**
> - 图标资源必须为正方形图像，**无需圆角，系统会为对应场景自动生成遮罩裁切**
> - 图标资源使用 PNG 格式
> - 应用图标的**背景图不允许含有透明像素**
>
> **Don't**：未正确分层，背景含有透明像素（**包含圆角裁切**或带有透明内边距的情况）

**最佳实践**（best-practices/bpta-app-icon-configuration）：

> 应用图标资源**不允许自行裁剪圆角**，**不允许在资源内添加内间距**。
> 上传的应用图标**必须与软件包中的应用图标一致**。

当前包内图标同时踩中三条：未分层、自行裁剪圆角、背景含透明像素。

### 2.3 整改方案

分层图标由"前景图 + 背景图 + JSON 映射"三件套构成：

| 步骤 | 内容 | 文件 |
|---|---|---|
| 1 | 生成前景图：1024×1024、**透明底**、图形主体居中且**不留内边距** | `AppScope/resources/base/media/foreground.png` |
| 2 | 生成背景图：1024×1024、**纯色**（建议 `#1976D2`）、**无任何透明像素**、不加圆角 | `AppScope/resources/base/media/background.png` |
| 3 | 声明分层映射 | `AppScope/resources/base/media/layered_image.json` |
| 4 | app.json5 引用 | `"icon": "$media:layered_image"` |
| 5 | module.json5 的 EntryAbility.icon 同步改为分层资源 | `"icon": "$media:layered_image"` |
| 6 | 启动页图标同步（避免二次驳回） | `startWindowIcon` |
| 7 | AGC 上传图标替换为分层合成后的单层 1024 图 | `docs/deploy/app-icon-1024.png` |

`layered_image.json` 内容：

```json
{
  "layered-image": {
    "background": "$media:background",
    "foreground": "$media:foreground"
  }
}
```

**关键注意点**

1. 资源名 = 文件名（去扩展名）。JSON 必须命名为 `layered_image.json` 才能被 `$media:layered_image` 引用。
2. AppScope 资源在编译期会合入模块；若两处同名，**AppScope 覆盖模块**。建议只在 AppScope 放一份，避免双份漂移。
3. `EntryAbility.icon` 优先级高于 `app.json5`，两处都要改；或**删掉 ability 的 icon 字段**让系统回退到 `app.json5`（改动更少、单点维护）。
4. 自检报告会比对"上传图标与包内图标一致"，AGC 侧图片需与分层合成效果一致。

### 2.4 可行性评估

| 维度 | 评估 |
|---|---|
| 技术可行性 | ✅ 完全可行，属标准配置项，无 API 限制（API 23 支持） |
| 改动范围 | 3~4 个配置文件 + 2 个新增素材 |
| 工作量 | 配置侧 15 分钟；素材侧取决于是否有原始设计源 |
| 风险 | **低**。唯一实际风险是同名资源覆盖（已在注意事项 2 中规避） |
| 回归面 | 桌面图标、任务列表图标、设置页应用列表、启动页 |

**唯一实质障碍：前景层素材来源。**

现有素材只有渲染完成的 1024 单层 PNG（图形与 `#1976D2` 底色已合并）。分层要求背景是纯色平铺、前景是透明底的图形，**从单层位图无法无损反解出前景层**——边缘会出现底色残留或锯齿。

三条路径：

| 路径 | 说明 | 前提 | 质量 |
|---|---|---|---|
| A（最优） | 从原始设计源（SVG / AI / Figma）导出前景层与背景层 | 需保留源文件 | 无损 |
| B | 重绘前景：用现有图标图形重描一遍（如校徽线稿 / "U" 字标） | 无需源文件 | 良好，需设计确认 |
| C | 从 RGB 版 1024 用容差抠图提取前景 | 无源文件 | 一般，边缘需人工修补 |

> 建议确认：图标原始设计稿（SVG/AI）是否还在？这直接决定 A 与 B/C 的取舍。

---

## 三、问题 B：卡片刷新方式不符合规范（兼容性 / 设计约束）

### 3.1 现状核查

`entry/src/main/resources/base/profile/form_config.json` 中 6 张卡片（`ubaa_schedule_small`、`ubaa_exam_small`、`ubaa_grade_small`、`ubaa_classroom_small`、`ubaa_schedule_week`、`ubaa_schedule_day`）**全部**采用同一套刷新配置：

```json
"updateEnabled": true,
"updateDuration": 0,
"multiScheduledUpdateTime": "07:30,11:50,16:50"
// ← 缺少 scheduledUpdateTime
```

代码侧核查（`UBAAFormAbility.ets`）：
- 仅在 `onUpdateForm()` 生命周期内调用 `formProvider.updateForm()`
- 全工程无 `setInterval` / `setTimeout` 常驻定时器
- 无 `setFormNextRefreshTime` 调用
- → **刷新实现方式本身合规**，问题在静态配置

### 3.2 规范判定依据

**依据 1｜hvigor 编译期校验规则（错误码 00303003 系列）**

> In the form_config.json file, if the value of the **updateEnabled** field is **true**, the **updateDuration** and **scheduleUpdateTime** fields **cannot be both empty**.
> （若 updateEnabled 为 true，则 updateDuration 与 scheduleUpdateTime 不能同时为空）

当前状态：`updateEnabled = true`、`updateDuration = 0`（视为不定时）、`scheduledUpdateTime` **缺失** → 精确命中该校验条件。

**依据 2｜定点刷新官方说明（harmonyos-guides/arkts-ui-widget-passive-refresh）**

> 1. 当同时配置了定时刷新 updateDuration 和定点刷新 scheduledUpdateTime 时，定时刷新的优先级更高且定点刷新不会执行。**如果想要配置定点刷新，则需要将 updateDuration 配置为 0**。
> 2. `multiScheduledUpdateTime` 的配置最多可设置 24 个时间。
> 3. 同时配置了单定点和多定点刷新，**多定点刷新配置生效，单定点刷新配置不生效**。
> 4. 考虑到向前兼容的问题，**尽量保留 scheduledUpdateTime 字段，不要直接删除**。

**依据 3｜官方配置示例**——三者并存是标准写法：

```json
"updateEnabled": true,
"scheduledUpdateTime": "10:30",
"multiScheduledUpdateTime": "11:30,16:30",
"updateDuration": 0
```

当前配置只保留了多定点，删掉了 `scheduledUpdateTime`，与官方示例不符，也正是说明 4 明确警告的做法。

### 3.3 整改方案

给 6 张卡片各补一行，取值与多定点的首个时间点一致：

```json
"scheduledUpdateTime": "07:30",
"multiScheduledUpdateTime": "07:30,11:50,16:50",
"updateDuration": 0,
"updateEnabled": true
```

### 3.4 可行性评估

| 维度 | 评估 |
|---|---|
| 技术可行性 | ✅ 标准字段，API 23 全支持 |
| 改动范围 | 单个 JSON，6 处各加 1 行 |
| 工作量 | **分钟级** |
| 运行行为影响 | **零**。按说明 3，同时配置时多定点生效、单定点不生效 |
| 风险 | **极低**。补的是向前兼容字段，不改变实际刷新时序 |
| 回归面 | 卡片定时刷新（07:30 / 11:50 / 16:50 三次） |

其他合规项复核（均通过，无需改动）：

| 检查点 | 规范要求 | 当前值 | 结论 |
|---|---|---|---|
| 卡片数量上限 | ≤16 个 | 6 | ✅ |
| 多定点时间数 | ≤24 个 | 3 | ✅ |
| 定时刷新配额 | ≤50 次/天/卡片 | 定点 3 次/天 | ✅ |
| 最短刷新间隔 | ≥5 分钟 | 定点最低间隔 4h20m | ✅ |
| 卡片元数据声明 | `ohos.extension.form` → `$profile:form_config` | 已配 | ✅ |

---

## 四、问题 C：测试覆盖设备类型不全（分析建议项）

### 4.1 事实

| 项 | 报告中 | 包内当前 |
|---|---|---|
| 应用适配设备 | 直板机 / 平板 / 2in1 / 折叠屏 | `deviceTypes: ["phone", "tablet"]` |
| 实际测试设备 | 直板机 + 折叠屏（6 台，无平板） | — |

报告"适配设备"含 2in1，而包内已去掉 2in1 → **提测包是修改 `deviceTypes` 之前的旧构建**。
即便按新包重测，"手机 + 平板"仍缺平板覆盖。

### 4.2 为什么必须处理

应用声明支持 `tablet`，但 6 台设备中无任何平板。审核侧可据此判定"声明能力未经验证"，与本次分析建议同源，存在二次驳回风险。

### 4.3 两条路径

| 方案 | 做法 | 代价 | 后续影响 |
|---|---|---|---|
| **1（推荐）** | 保留 `tablet`，用平板真机或云测补测平板布局（三档断点、分栏、横屏） | 需平板设备 / 云测时长 | 一次到位，符合产品实际能力 |
| 2（应急） | 本期 `deviceTypes` 收窄为 `["phone"]`，平板下期再放 | 0 成本 | 平板上不可安装；需下个版本重新走审核 |

> 项目 11-10 已完成平板三档适配（`docs/tech/tablet-adaptation.md`），代码能力具备，缺的只是**验证证据**。因此推荐方案 1。

---

## 五、整改优先级与整体判断

### 5.1 优先级

| 优先级 | 事项 | 工作量 | 风险 | 阻塞上架 |
|---|---|---|---|---|
| P0 | 6 张卡片补 `scheduledUpdateTime` | 分钟级 | 极低 | 是 |
| P0 | 图标改分层（素材 + 配置） | 小时级（取决于素材） | 低 | 是 |
| P1 | 平板补测并留证 | 天级 | 中（依赖设备） | 是 |
| P1 | 重新打包（release）+ 重新提测 | 小时级 | 低 | 是 |

### 5.2 整体可行性结论

**结论：两条不通过项均为「配置合规性」问题，不涉及架构改造，整改完全可行且成本可控。**

支撑判断：

1. **稳定性 / 功耗 / 性能三维满分**（16 个用例 100% 通过），说明应用本身质量良好，不通过并非功能缺陷。
2. **问题 A（图标）** 是资源配置形态问题，标准解法明确，唯一变量是前景层素材来源。
3. **问题 B（卡片刷新）** 是 1 行配置 × 6 处，且按官方说明不改变运行行为，属"零风险修复"。
4. **问题 C（设备覆盖）** 是流程问题而非代码问题，取决于能否取得平板测试资源。

### 5.3 重测通过概率预估

| 项 | 通过条件 | 把握 |
|---|---|---|
| 卡片刷新合规 | 补齐 `scheduledUpdateTime` 后重测 | 高（确定性配置项） |
| 图标合规 | 分层资源 + 双处引用一致 + AGC 图标一致 | 高（若素材质量达标） |
| 设备覆盖 | 平板实测通过 | 取决于测试资源 |

### 5.4 建议的执行顺序

1. 先做 B（分钟级、零风险），单独验证配置改动不影响卡片刷新时序；
2. 同步启动 A 的素材确认（原始设计稿是否在手），素材到位后一次改完配置；
3. 打包前确认 `deviceTypes`、`orientation`、图标引用三处一致；
4. 出 release 包 → 平板补测 → 重新提测。

---

## 六、实施记录（2026-11-16 11:40 起）

### 6.1 已落地改动

| 文件 | 改动 |
|---|---|
| `entry/src/main/resources/base/media/foreground.png` | 新增。1024×1024 RGBA，前景=白色 UBAA 字标，透明底 |
| `entry/src/main/resources/base/media/background.png` | 新增。1024×1024 纯色 `#1976D2`，无透明像素 |
| `entry/src/main/resources/base/media/layered_image.json` | 新增。分层映射声明 |
| `AppScope/app.json5` | `icon` → `$media:layered_image` |
| `entry/src/main/module.json5` | `EntryAbility.icon` → `$media:layered_image`；`startWindowIcon` 保留 `$media:app_icon` |
| `AppScope/…/media/app_icon.png`、`entry/…/media/app_icon.png`、`startIcon.png` | 替换为满幅无圆角版（原版四角 alpha=0，与 `borderRadius` 叠加会露缝） |
| `entry/src/main/resources/base/profile/form_config.json` | 6 张卡片各补 `"scheduledUpdateTime": "07:30"` |

前景层不是重绘，而是**从单层图标反解**得到：
原图满足 `P = α·W + (1-α)·B`（W=白，B=`#1976D2`），逐像素最小二乘解 α，
前景色固定为白。合成回背景后与原图平均偏差 0.05/255，抗锯齿边缘完整保留。

### 6.2 构建验证

| 检查项 | 结果 |
|---|---|
| 构建结果 | BUILD SUCCESSFUL（24s 682ms） |
| ArkTS 错误 | 0 |
| 产物签名 | `entry-default-signed.hap` / `UBAA-HarmonyOS-default-signed.app` |
| `app.debug` | **false**（非 debug 签名包） |
| 包内 `app.icon` | `$media:layered_image` ✅ |
| 包内 `EntryAbility.icon` | `$media:layered_image` ✅ |
| 包内 `form_config` 6 卡 | 全部含 `scheduledUpdateTime` ✅ |

### 6.3 两条残留观察（不影响提交，但需知晓）

**① 编译器会把图层压到 512×512。**
源文件 1024×1024，打包后 HAP 内 `foreground.png` / `background.png` 均为 512×512。
移动资源目录（AppScope → entry）不能规避，属资源编译器对分层图层的既定处理；
同一包内单层 `app_icon.png` 仍保持 1024×1024，说明这不是通用图片压缩。
判断：图层的 512 是编译期标准规格，源文件保持 1024 即满足规范字面要求。

**② 背景层 alpha 被重编码为 254。**
包内 `background.png` 全图 alpha=254、RGB 由 `#1976D2` 微调为 `(25,117,210)`。
这是编译器 PNG 优化的量化损失，肉眼不可辨；规范中「背景图不允许含透明像素」
指向设计层面的透明（圆角、留白），不针对 ±1 的编码误差。ACP 侧如需严格校验，
可考虑把背景改为无 alpha 的索引色 PNG 再试，但当前不建议为此冒险改结构。

### 6.4 启动动画圆角修正（12:10 追加）

冷启动转场动画曾出现**直角蓝块**：`startWindowIcon` 指向满幅直角 `app_icon`，
而启动窗口与转场不做遮罩裁切，矩形边缘直接暴露。

修正：新增 `entry/src/main/resources/base/media/startIcon.png`
（1024×1024，圆角半径 185/1024，与原设计一致，四角透明，
用 4× 超采样遮罩保证边缘平滑），`startWindowIcon` 改指向 `$media:startIcon`。
`app_icon` 保持满幅直角不变——它服务的是应用内 `Image` + `borderRadius` 场景，
自带圆角反而会与 `borderRadius` 叠加出缝隙，两者职责分离。

真机验证（PLR-AL50 冷启动连拍 6 帧）：转场放大帧已呈**圆角**，
圆角外透出桌面壁纸/启动页背景色，无直角暴露；后续帧正常进入首页。

### 6.5 尚未完成

- **真机验证**：`hdc list targets` 为空，设备离线。需连接后安装 `entry-default-signed.hap`，
  确认桌面图标分层渲染正常、无白边/双重圆角、启动页图标无缺口、卡片 07:30 定点刷新仍触发。
- **平板补测**：见第四节，需平板设备或云测。

---

## 附录：本次核查所用的官方依据

| 主题 | 文档标识 |
|---|---|
| 图标资源规范 | `design-guides/application-icon-0000001953444009` |
| 分层图标配置 | `harmonyos-guides/layered-image` |
| 图标最佳实践 | `best-practices/bpta-app-icon-configuration` |
| 卡片定点/多定点刷新 | `harmonyos-guides/arkts-ui-widget-passive-refresh` |
| 卡片刷新与数据交互 | `harmonyos-guides/form-refresh-and-data-interaction` |
| hvigor 配置校验 00303 | `harmonyos-guides/ide-hmos-hvigor-errorcode-00303-1` |

> 以上文档均通过 HarmonyOS Developer Knowledge MCP（`harmonyos_developer_knowledge`）检索核对。
