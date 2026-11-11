# 页面转场与返回层级

> 2026-11-11 改版。两件事：把删掉的转场动画按新约定加回来；把「返回键」从
> 「无条件弹栈」改成「浮层优先」。

## 1. 转场策略

二级页统一走 `common/AppRouter.ets`：

```ts
AppRouter.open(stack, RouteName.EXAM);            // 默认带动画：自右向左滑入
AppRouter.open(stack, item.route, undefined, false); // 传 false = 硬切
```

| 入口 | 转场 |
| --- | --- |
| 主页考试横幅、我的菜单、课表课程详情… | **带动画**（系统默认） |
| 功能页的大按钮（`FeaturePage.open`） | **硬切**（产品要求，这处之后单独设计） |

返回时沿用「最近一次 push 用的是哪种」，保证对称：硬切进来的页面不会带着滑出动画退回，
否则看起来像从别处冒出来又滑走。

实现上是 `AppRouter.lastPushAnimated` 记一个布尔，`back()` 时取用。只对单层 push/pop
成立 —— 若某个硬切页面内部再 push 一个带动画的页面，`back` 会跟着变成带动画（当前没有
这种组合）。

## 2. 返回层级：浮层 > 页面

### 问题

所有二级页的返回都在 `pages/RouteBuilder.ets` 的 `onBackPressed` 里接管（26 处，
逐字相同）。改造前那里是无条件 `stack.pop()`，于是：

> 博雅课程的筛选面板还开着，按返回键 → 整个课程列表页被关掉，筛选条件一起没了。

自绘遮罩只是 `Stack` 的兄弟节点，框架不会替它消费返回事件；页面内部**没有任何机会拦截**。

### 机制

`common/BackGuard.ets` 是一个「关闭动作栈」：

```ts
// 打开浮层：登记「关掉自己」的动作，返回 true 表示关得掉
BackGuard.register(() => { this.filterPanelOpen = false; return true; });

// 用户点关闭 / 点遮罩关闭：与上面成对注销
this.filterPanelOpen = false;
BackGuard.unregister();

// 关不掉的那种（提交中的阻塞遮罩）：返回 false，这一层留在栈里持续拦截
BackGuard.register(() => false);
```

`AppRouter.back()` 先问它：

```ts
static back(stack: NavPathStack): void {
  if (BackGuard.consume()) {   // 有浮层：吃掉这次返回
    return;
  }
  stack.pop(AppRouter.lastPushAnimated);
}
```

因为 26 处 `onBackPressed` 全部走 `AppRouter.back`，**「浮层优先」只在一处实现**，
页面只负责自己那一层的 register / unregister。

用栈而不是单个槽位，是为了允许嵌套（面板里再弹确认框）：后注册的先关，
关完才轮到下一层，最后才退页面。

### 谁负责登记

**渲染这层浮层的地方登记**，不是「打开它的地方」。

反例（踩过）：SPOC 的全屏网页浮层是 `SpocPage` 打开、`MainPage` 渲染。
一开始把 register 写在 `SpocPage.openSpocWeb` 里，结果按返回时页面照样被退掉 ——
登记没在正确的生命周期上（页面侧的闭包还容易在销毁后悬空）。
改到 `MainPage.onSpocWebOpenChange` 里登记后一次就通了。

### 已接入

| 页面 | 浮层 | 返回行为 |
| --- | --- | --- |
| BykcCoursesPage | 筛选面板（自绘遮罩） | 先关面板，再返回才退页面 |
| EvaluationPage | 提交进度遮罩 | 提交期间**吃掉**返回（`register(() => false)`） |
| MainPage | SPOC 网页提交全屏浮层 | 先关浮层，SPOC 列表页保留 |
| ExamPage | 学期展开面板 | 先收面板 |
| IhomePage | 公告展开 | 先收公告 |

### 由系统处理的（未接入）

`CustomDialog`（作业详情、今日课程详情、学期选择、多课冲突提示）和 `bindSheet`
（登录页的连接模式选择）由系统自己先消费返回 —— 真机验证：弹窗开着按返回，弹窗关闭、
页面保留。这些**不必**再登记，登记了反而会和系统抢。

## 3. 验证记录（MLR-AL10 横屏）

| 场景 | 结果 |
| --- | --- |
| 我的 → 个人资料 | push 抓到滑入中间帧（旧页被挤到左侧）；返回滑出 |
| 功能页大按钮 → 详情 | 连拍两帧像素完全相同（硬切） |
| 博雅筛选 → 返回 | 只关面板、页面保留；再返回才退到博雅首页 |
| SPOC 作业 → 弹窗 → 返回 | 弹窗关闭、页面保留 |
| SPOC 网页浮层 → 返回 | 浮层关闭、SPOC 列表页保留 |
