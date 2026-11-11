/**
 * 四个页签的导航栈 —— **模块级单例**。
 *
 * ## 为什么要放在组件外面
 *
 * 横竖屏切换会重建 `MainPage`（`sideNavLayout()` 从 lg/xxl 档切到 md，两个档位用的是
 * 两棵完全不同的组件树；叠加能力层的重建，页面实例整个换掉）。栈作为 `MainPage` 的成员，
 * 一重建就整棵丢掉 —— 表现为「转一下屏幕，回到主页、刚打开的页面全没了」。
 *
 * 放在模块里之后，组件重建只是换了一批 UI 实例，栈本身（里面压着哪个页面、参数是什么）
 * 都还在。`NavPathStack` 是数据模型，允许被新的 `HdsNavigation` 直接复用。
 *
 * ⚠️ 这四个常量在应用生命周期里只创建一次，**不要**在任何地方 `new NavPathStack()`
 * 去替换它们；要清空栈用 `clear()`。
 */
export const HOME_STACK: NavPathStack = new NavPathStack();
export const SCHEDULE_STACK: NavPathStack = new NavPathStack();
export const FEATURE_STACK: NavPathStack = new NavPathStack();
export const MINE_STACK: NavPathStack = new NavPathStack();

/**
 * 当前页签序号的 AppStorage 键。
 *
 * 同样为了「横竖屏切换后还停在原来那一页」：`@State` 挂在组件上，重建即回到默认值 0。
 */
export const KEY_MAIN_TAB_INDEX: string = 'mainTabIndex';
