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
| 栈深 = 0（停留在一级页） | 整页显示，宫格 / 仪表盘 / 菜单用满宽度 |
| 栈深 > 0（点了某项） | 切 `NavigationMode.Split`：左列表 + 右详情 |
| 返回 / 再点当前页签 | 栈深归零，自动退回整页 |

参与范围：主页 / 功能 / 我的（页签 0 / 2 / 3）。**课表不参与** —— 7 天周网格是固定列宽的
表格，劈成一半没法看。

| 断点 | 列表栏 navBar | 详情栏最小宽 | 说明 |
| --- | --- | --- | --- |
| md（平板竖屏 673vp） | 300vp（范围 264~320） | 300vp | 300 + 300 = 600 < 673，留得下 |
| lg | 360vp（范围 320~400） | 360vp | |
| xxl | 400vp（范围 340~440） | 360vp | |

实现要点：

- 栈深由 `NavPathStack.setInterception().didShow` 维护（push / pop / 手势返回都会经过），
  写进 `@State stackDepth`；`splitFor(tab)` = `navSplitMode && 页签属于 0/2/3 && 栈深 > 0`。
- **过渡动画用 HDS 的模式切换动画**（`enableModeChangeAnimation(true)`，两个布局分支都要开）。
  它的表现是：列表栏从整宽收窄到 300/360，详情栏随之从右往左让出来 —— 正是「详情从右侧
  出现」。⚠️ 曾经为了修「从左侧出现」把它关掉，结果横屏分支变成瞬切（竖屏分支是默认开启，
  所以竖屏还有动画），两端表现不一致；**两个分支必须一致，别只改一边**。
- **push 要等分栏布好再发**（`AppRouter.openAfterLayout`，隔两帧的帧回调）。同一帧里既切
  mode 又 push，内容栏是跟详情一起新建的，push 动画会被吞掉（横屏大窗口下必然瞬显）。
- **点条目要用 replace 而不是 push**：分栏时「左列表 → 右详情」是一对一关系，已经在看
  某个详情时再点另一个条目，应该替换右栏内容。否则栈深变 2，返回一次只退到上一个详情，
  用户会觉得返回键失灵。见 `AppRouter.open(stack, route, splitMode)`。
- 页面要拿到 `splitMode`，必须用 **`@Prop`** 而不是普通成员：普通成员只在创建时赋值，
  父组件重建时不会同步（实测踩过，点第二条时仍走了 push）。
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

### 5. 转场细节：结构切换永远不要靠 animateTo 兜底

- **别用 `if/else` 切 `Row ↔ Column`**：那是结构切换，旧节点被销毁、新节点直接落在终态，
  ArkUI 只对「存续节点」的属性补间，外面包 `animateTo` 也补不出来 → 硬切。
- 正确做法：两块**永远是同一批节点**，只让几何属性变（`width` 100% ↔ 48.5%），
  外面挂隐式 `.animation({ duration: 260, curve: Curve.Friction })`。
- 换行的**位移**仍然无法插值（wrap 一换行，第二块就已经在下方了）。用位移补偿把它变成
  滑行：翻转瞬间 `animateTo({duration: 0})` 把第二块钉回切换前的位置（初值 = 两套布局的
  位置差），下一帧再 `animateTo(260ms)` 归零。见 `HomePage.startBlockShift`。

### 6. 分栏切换时的页面内重排动画（主页 / 功能页）

HDS 的面板收放是**原生动画**，动画期间 ①页面拿不到逐帧宽度 ②子节点不会逐帧重排。
所以「把布局交给百分比 + 自动换行」的方案，中间帧必然是旧布局、结束瞬间跳一档。

两个页面统一改成**自己驱动几何**，并共用 `AppMotion.SPLIT_DURATION`（280ms）：

| 页面 | 做法 |
| --- | --- |
| 主页 | `Stack` + 像素自绘：单块宽 = 并排 ? (lane-16)/2 : lane，第二块用 `translate` 定位；堆叠时缺的高度由 `Blank` 补 |
| 功能页 | 内容列宽度改成像素状态 `paneWidth`，量到面板宽度后用 `animateTo` 补间；宽度逐帧真实变化 → 栅格逐帧重排，磁贴连续挤窄 |

四条硬约束（都是踩出来的）：

1. **必须用显式 `animateTo`**：隐式 `.animation()` 对「布局回调里触发的状态变化」不生效（实测 1200ms 仍瞬切）。
2. **定位用 `translate`，不要 `position`**：`position` 不参与属性动画，左边缘会瞬移。
3. **容器高度不能由状态反推**：否则「高度依赖子节点测量、子节点又依赖高度」死锁成 0 高。
4. **量最终承载内容的那个容器**，别量祖父：容器回调比子节点重排早一帧，会导致列数与宽度错位（磁贴被裁半个）。

调参入口：`AppTheme.ets` 的 `AppMotion.SPLIT_DURATION`（时长），曲线统一 `Curve.Friction`。
验证手法：把该值临时改成 1200ms 抓中间帧，确认几何/列数处于中间态，再改回 280ms。

### 7. 其它页面

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

修法：`narrowTabs()` 的四个一级导航全部显式写
`.mode(this.splitFor(n) ? NavigationMode.Split : NavigationMode.Stack)` —— 既不依赖 Auto，
又保留了「点进去才分栏」的意图。这条只在「平板竖屏（md）」暴露 —— 手机 < 600vp 时 Auto
恰好等于 Stack，所以一直没被发现；凡是「宽度会跨过 600vp」的形态都必须显式声明模式。

> 另一个反向坑：最初为了修上面这条，把 `narrowTabs` 里写死了 `.mode(NavigationMode.Stack)`，
> 结果 md 下永远进不了分栏（`splitFor` 被短路）。显式声明必须带上判断，不能写死。

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
| 平板竖屏 主页 / 功能 / 我的（未点击） | md | 整页显示 | 通过 |
| 平板竖屏 主页点空闲教室 | md | 300vp 主页 + 空闲教室详情 | 通过 |
| 平板竖屏 功能点图书馆座位 | md | 300vp 宫格（2 列）+ 详情 | 通过 |
| 平板竖屏 我的点个人资料 | md | 300vp 菜单 + 个人资料 | 通过 |
| 平板竖屏 分栏内换条目 | md | 右栏替换、栈深仍为 1，返回一次回整页 | 通过 |
| 手机竖屏 主页 / 功能 / 课表 | sm | 与改造前一致 | 上版通过；本版仅改 mode 表达式，未复测（无线调试断开） |

## 五、后续可做

1. 成绩 / 博雅列表在 lg 下改双列卡片，提升信息密度（当前单列，大屏偏空）。
2. 「我的」/ 设置 / 关于等表单页套用 `contentMaxWidthOf()` 居中限宽（lg 下菜单行偏空）。
3. 折叠屏悬停态（`FolderStack` / `display.getCurrentFoldCreaseRegion`）与平行视界
   （`easyGo` 配置）暂未接入。
