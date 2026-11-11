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

| 断点 | 形态 | 侧栏宽度 | 内容底部留白 |
| --- | --- | --- | --- |
| sm（手机竖屏） | 底部悬浮页签 `HdsTabs` | — | 104vp |
| md（平板竖屏 / 折叠展开） | 底部悬浮页签 | — | 104vp |
| lg / xxl（平板横屏 / 2in1） | 侧边导航 + 当前页签 `HdsNavigation` | 128 / 144vp | 24vp |

侧栏宽度按内容反推（图标 24 + 间距 12 + 两字标签 32 + 内边距 ≈ 104vp，留一圈呼吸取 128），
早先的 232/256 会让文字右侧空出一大片。

### 3. 分栏：按「栈深」动态开启，而不是一进页面就分

| 状态 | 表现 |
| --- | --- |
| 栈深 = 0（停留在一级页） | 整页显示，宫格/仪表盘用满宽度 |
| 栈深 > 0（点了某项） | 切 `NavigationMode.Split`：左列表 + 右详情 |
| 返回 / 再点当前页签 | 栈深归零，自动退回整页 |

实现要点：

- 栈深由 `NavPathStack.setInterception().didShow` 维护（push / pop / 手势返回都会经过），
  写进 `@State stackDepth`；`splitFor(tab)` = `navSplitMode && 列表型页签 && 栈深 > 0`。
- 过渡动画靠 `enableModeChangeAnimation(true)`，不额外写动画。
- 只有「列表型」页签参与分栏（功能 / 我的）。主页是仪表盘、课表是周网格，压进
  320~400vp 的列表栏只会把内容挤烂。
- **分栏下必须显式接管返回**：HDS 在 Split 里画的返回按钮点了不弹栈（真机实测），
  系统返回键甚至会直接退出应用。所以每个二级页都挂了
  `onBackPressed(() => { stack.pop(); return true })`。

### 4. 页面级响应式：按「自身宽度」而不是窗口断点

官方对应 `BreakpointsReference.ComponentSize`。分栏后左栏只有 320~400vp，窗口断点却仍
报 lg，此时按窗口断点取列就会把标题全挤成省略号（这正是「竖屏左面太挤」的根因）。

- 主页 / 功能页用 `onAreaChange` 量自己的可用宽度，交给
  `columnsTemplateByWidth(width, minTile=84, minCols=3, maxCols=8, itemCount)` 反推列数；
- 主页 `twoColumnLayout()` 的判据也改成「自身宽度 ≥ 720vp」——两栏各 340vp 才会好看；
- 窗口断点只用来决定**外壳形态**（页签 / 侧栏、分栏能力），不再参与页面内部栅格。

### 5. 其它页面

- 课表 / 空闲教室：本身是网格与表格，铺满可用宽度即可，无需额外分支。

## 三、两个「必须显式声明」的坑

### 1. 静态 `orientation: "portrait"` 会让平板只得到竖屏兼容窗口

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

### 2. `NavigationMode.Auto` 会「偷偷分栏」（竖屏左挤的真凶）

平板竖屏 673vp 下主页内容只占左侧 240vp、右侧一块黑 —— `uitest dumpLayout` 显示：

```text
Tabs        [0,105][1600,2560]
  TabContent/Navigation  [0,105][1600,2560]
    NavBar      [0,105][570,2560]     ← 570px = 240vp，右侧没有内容栏
```

原因：底部页签分支里的 `HdsNavigation` **没有显式设置 `mode`**，默认是
`NavigationMode.Auto`；窗口宽度 ≥ 600vp 时 Auto 自动切成 Split，栈空的内容栏就是那片黑。

修法：`narrowTabs()` 的四个一级导航全部显式 `.mode(NavigationMode.Stack)`。
这条只在「平板竖屏（md）」暴露 —— 手机 < 600vp 时 Auto 恰好等于 Stack，所以一直没被
发现；凡是「宽度会跨过 600vp」的形态都必须显式声明模式。

## 四、真机验证

平板 MLR-AL10 `5KLBB25902200979`（2560×1600 / 密度 2.375，横屏 1077vp → lg）；
手机 PLR-AL50（1316×2832 / 3.5 → 376vp → sm，无线调试）。

| 场景 | 窗口 | 期望 | 实测 |
| --- | --- | --- | --- |
| 平板横屏 主页 | lg | 铺满全屏、侧栏 + 双列仪表盘 | 通过（两侧无壁纸） |
| 平板横屏 功能（未点击） | lg | 整页宫格、4 / 7 列按条目数均分 | 通过 |
| 平板横屏 功能（点击某项） | lg | 左列表 3 列 + 右详情，无重叠 | 通过 |
| 平板横屏 返回 | lg | 退回整页宫格，不退出应用 | 通过（补 `onBackPressed` 后） |
| 平板横屏 我的 | lg | 整页；点菜单后分栏 | 通过 |
| 平板横屏 课表 | lg | 7 天网格铺满 | 通过 |
| 平板横屏 空闲教室 | lg | 14 节次表格对齐 | 通过 |
| 手机竖屏 登录页 | sm | 单列铺满、无侧栏 | 通过 |
| 手机竖屏 主页 / 功能 / 课表 | sm | 与改造前一致 | 通过（2026-11-11 复测） |
| 平板竖屏 主页 | 673vp → md | 底部页签 + 整宽单列，快捷入口 4+4 | 通过（修掉 Auto 偷偷分栏后） |
| 平板竖屏 功能 | md | 普通功能 4 列 / 高级功能 7 列，标题完整 | 通过 |
| 平板竖屏 课表 | md | 7 天网格铺满 | 通过 |
| 平板竖屏 点开详情 | md | 整页显示（md 不分栏）+ 返回可退 | 通过 |

## 五、后续可做

1. 成绩 / 博雅列表在 lg 下改双列卡片，提升信息密度（当前单列，大屏偏空）。
2. 「我的」/ 设置 / 关于等表单页套用 `contentMaxWidthOf()` 居中限宽（lg 下菜单行偏空）。
3. 折叠屏悬停态（`FolderStack` / `display.getCurrentFoldCreaseRegion`）与平行视界
   （`easyGo` 配置）暂未接入。
