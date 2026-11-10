# 平板 / 大屏适配

依据华为官方「一次开发，多端部署」（一多）规范落地。核心结论：**按窗口宽度断点适配，
不按设备类型判断**；方向策略（横竖屏锁定）是唯一允许按设备形态分支的地方。

## 一、官方规范要点

| 主题 | 官方结论 | 本项目落地 |
| --- | --- | --- |
| 适配依据 | 用窗口尺寸断点，而非 `deviceType`。折叠屏展开、平板横竖屏、分屏、自由窗口缩放本质都是窗口尺寸变化 | `common/Breakpoint.ets` 纯函数 + `window.on('windowSizeChange')` 发布到 AppStorage |
| 断点档位 | 宽度 sm < 600 / md 600–840 / lg 840–1440 / xl ≥ 1440（vp） | sm / md / lg / xxl（xxl 取 1200vp，覆盖 2in1 与超大平板） |
| 高度断点 | 用于识别「大屏竖屏」：横向 md + 纵向 lg 即 Pad 竖屏 | `heightToBreakpoint()` + `KEY_HEIGHT_BP` / `KEY_IS_LANDSCAPE` |
| 大屏竖屏 | **页签栏放底部**，不要侧栏；利用纵向高度做重复布局 | 底部页签 / 侧边导航的切换点是 `lg`，不是「是否宽屏」 |
| 三分栏 | 有层级关系（目录 → 列表 → 内容）才用分栏：侧栏 + `Navigation` 双栏 | 侧边导航 + `HdsNavigation(NavigationMode.Split)`，仅「我的」页签启用 |
| 栅格 | `GridRow` / `GridCol` 或 `Grid.columnsTemplate` 按断点给列数，`BreakpointsReference.WindowSize` | 磁贴 `1fr × N`，N 由 `tileColumnsOf()` 给出（4 / 6 / 8） |
| 内容限宽 | 图文并茂场景用栅格控制内容宽度，避免大屏单列文字过长 | `contentMaxWidthOf()`（lg 920vp / xxl 1040vp） |
| 多设备交互 | 键鼠 / 触控板需悬停反馈；触控目标不小于 48vp | 磁贴 `hoverEffect(HoverEffect.Highlight)`；磁贴单格不小于 84vp |
| 窗口方向 | 允许按窗口形态自适应；平板的兼容窗口问题源于静态方向声明 | `module.json5` 改 `auto_rotation_restricted`，手机端运行期锁竖屏 |

## 二、本项目实现分层

```text
Breakpoint.ets        断点纯函数（宽/高断点、导航形态、列数、限宽）—— 不 import UI
        ↑                      ↑
ImmersiveUtil         AppTheme(AppSize getter)      MainPage
 发布 AppStorage        页面内边距/底部留白随断点     侧栏 or 底部页签 + 分栏判定
```

### 1. 断点发布（`common/ImmersiveUtil.ets`）

- `window.on('windowSizeChange')` → `px2vp` → 写入 `windowWidthVp` / `windowHeightVp` /
  `breakpoint` / `heightBreakpoint` / `isLandscape` / `isWideScreen` / `navSplitMode`；
- 订阅后主动取一次首值，否则首帧恒为 `sm`；
- 尺寸变化与避让区变化是两个独立回调、顺序不保证，成对刷新安全区。

### 2. 导航形态（`pages/MainPage.ets`）

| 断点 | 形态 | 内容底部留白 |
| --- | --- | --- |
| sm（手机竖屏） | 底部悬浮页签 `HdsTabs` | 104vp |
| md（平板竖屏 / 折叠展开） | 底部悬浮页签 | 104vp |
| lg / xxl（平板横屏 / 2in1） | 侧边导航 + 当前页签 `HdsNavigation` | 24vp |

分栏只在「我的」页签启用（`splitFor`）：主页是仪表盘、课表是周网格、功能页是宫格导航，
塞进 360vp 的列表栏只会更难用（实测功能页 6 列磁贴标题全部变成省略号）。

### 3. 页面级响应式

- 主页：lg / xxl 下「今日课程 | 快捷入口」双列并排；磁贴列数随断点（4 / 6 / 8）。
- 功能页：磁贴列数随断点，且列数不超过条目数（避免 4 个磁贴占 6 列、右侧空两格）。
- 课表 / 空闲教室：本身是网格与表格，铺满可用宽度即可，无需额外分支。

## 三、方向策略（踩坑记录）

历史上 `module.json5` 静态写 `orientation: "portrait"`，平板横屏下系统会把 App 塞进
**竖屏兼容窗口**（左右露出壁纸、窗口宽度恒等于竖屏宽度 387vp），此时运行期调用
`setPreferredOrientation(AUTO_ROTATION)` **无效** —— 静态声明优先级更高。

现状：

```json5
// module.json5
"orientation": "auto_rotation_restricted"   // 跟随传感器、仅正向
```

```ts
// EntryAbility.onWindowStageCreate，必须在 loadContent 之前
ImmersiveUtil.applyOrientationPolicy(windowStage);
// 平板 / 2in1 → AUTO_ROTATION_RESTRICTED；手机 / 窄屏 → PORTRAIT
```

## 四、真机验证（MLR-AL10 / 2560×1600 / 密度 2.375）

| 场景 | 窗口 | 期望 | 实测 |
| --- | --- | --- | --- |
| 平板横屏 主页 | 1077vp → lg | 铺满全屏、侧栏 + 双列仪表盘 | 通过（两侧无壁纸） |
| 平板横屏 功能 | lg | 6 列磁贴、标题完整 | 通过 |
| 平板横屏 我的 | lg | 三分栏：侧栏 + 菜单 + 详情 | 通过（详情栏有标题栏与返回） |
| 平板横屏 课表 | lg | 7 天网格铺满 | 通过 |
| 平板横屏 空闲教室 | lg | 14 节次表格对齐 | 通过 |
| 平板竖屏 | 673vp → md | 底部页签 + 单列内容 | 待复测（需手工把平板立起来） |
| 手机竖屏 | 376vp → sm | 与改造前完全一致 | 待复测（当前无手机在线） |

## 五、后续可做

1. 成绩 / 博雅列表在 lg 下改双列卡片，提升信息密度（当前单列，大屏偏空）。
2. 设置 / 关于等表单页套用 `contentMaxWidthOf()` 居中限宽。
3. 接入 `GridRow` / `GridCol`（`BreakpointsReference.ComponentSize`），让局部栅格按
   **容器宽度**而非窗口宽度取列 —— 分栏后左栏只有 360vp，窗口断点会高估可用宽度。
4. 折叠屏悬停态（`FolderStack` / `display.getCurrentFoldCreaseRegion`）与平行视界
   （`easyGo` 配置）暂未接入。
