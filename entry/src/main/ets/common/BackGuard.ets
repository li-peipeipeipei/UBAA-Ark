/**
 * 返回键优先级：**浮层 > 页面**。
 *
 * ## 解决什么问题
 *
 * 二级页的返回统一在 `RouteBuilder` 的 `onBackPressed` 里接管（26 处，逐字相同）。
 * 如果那里无条件 `stack.pop()`，就会出现「筛选面板还开着、按返回把整个页面关掉」——
 * 用户的预期是先收面板，第二次才退出页面。
 *
 * 页面内部（尤其是自绘遮罩）没有任何机会拦截：遮罩只是 `Stack` 的兄弟节点，
 * 框架不会替它消费返回事件。
 *
 * ## 怎么用
 *
 * 打开浮层时注册「关掉自己」的动作，关闭时注销，**一对一对齐**：
 *
 * ```ts
 * this.filterOpen = true;
 * BackGuard.register(() => { this.filterOpen = false; return true; });
 *
 * this.filterOpen = false;
 * BackGuard.unregister();
 * ```
 *
 * 动作返回 `true` = 「关掉了」，这一层随即出栈；返回 `false` = 「不能关」
 * （例如提交中的阻塞遮罩），这一层留在栈里继续拦截下一次返回。
 *
 * 之后返回键会先走 `AppRouter.back()` → `BackGuard.consume()`：有浮层就关掉并吞掉这次返回，
 * 没有才真正弹栈。
 *
 * ## 为什么用栈而不是单个槽位
 *
 * 允许嵌套（例如某个面板里又弹了一个确认框）：后注册的优先被关，
 * 关掉一层后第二次返回关下一层，最后才退出页面。
 *
 * ⚠️ 页面销毁时必须 `clear()`（`aboutToDisappear`），否则关掉的页面会留下一个
 * 指向已销毁实例的闭包 —— 下次返回时 `consume()` 调用它会访问已卸载的组件状态。
 */
export type LayerCloser = () => boolean;

export class BackGuard {
  private static layers: LayerCloser[] = [];

  /** 注册一层浮层（参数是「关掉它」的动作，返回是否关掉了）。 */
  static register(close: LayerCloser): void {
    BackGuard.layers.push(close);
  }

  /** 注销最上面那一层（关闭浮层时调用，与 register 成对）。 */
  static unregister(): void {
    if (BackGuard.layers.length > 0) {
      BackGuard.layers.pop();
    }
  }

  /** 当前是否有浮层占着返回键。 */
  static hasLayer(): boolean {
    return BackGuard.layers.length > 0;
  }

  /**
   * 消费一次返回：有浮层就吃掉这次返回（返回 true），没有则返回 false 让调用方弹栈。
   *
   * 只有「关闭动作报告已关掉」时才把这层出栈；报告关不掉的（提交中的阻塞遮罩）
   * 保留在栈里，下一次返回仍然由它拦截。
   *
   * ⚠️ 关闭动作里**不要**再调 `unregister()`：本方法已经负责出栈，
   * 再调一次会把下一层误删。
   */
  static consume(): boolean {
    const size: number = BackGuard.layers.length;
    if (size === 0) {
      return false;
    }
    const close: LayerCloser = BackGuard.layers[size - 1];
    if (close()) {
      BackGuard.layers.pop();
    }
    return true;
  }

  /** 页面销毁时清空（防止闭包指向已卸载的组件）。 */
  static clear(): void {
    BackGuard.layers = [];
  }
}
