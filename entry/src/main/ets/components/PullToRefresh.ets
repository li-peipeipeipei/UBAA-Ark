import { Logger } from '../common/Logger';

/**
 * 全站统一的「下拉刷新 + 官方加载动画」外壳。
 *
 * ## 为什么封装成组件
 * 十个页面各自写一遍 `Refresh({ refreshing, builder })` 会引入两类问题：
 * 1. `refreshing` 与页面自己的 loading 状态混用后，回调里立刻被防重入挡住，
 *    旋转动画永远收不回来；
 * 2. `@Builder` 的普通参数按值传递、不参与刷新，内容必须经由 `@BuilderParam`
 *    的箭头函数传进来，才能跟随页面 `@State` 重新渲染。
 *
 * 这里把 `refreshing` 收在组件内部：`onRefresh` 的 Promise 结束（成功或失败）
 * 才置回 false，Refresh 自动回弹到顶部，页面内容原地不动。
 *
 * ## 官方参数（harmonyos-references/ts-container-refresh、ts-basic-components-loadingprogress）
 * - `refreshOffset(64)`：未设置 promptText 时的官方默认触发距离 64vp；
 * - `pullToRefresh(true)`：官方默认值，下拉超过偏移即触发；
 * - `pullDownRatio` 不显式设置：使用官方动态跟手系数（下拉越深系数越小）；
 * - 指示器用示例里的 `LoadingProgress`，官方要求设置合理宽高，示例取 32vp；
 * - `constraintSize({ minHeight: 32 })`：官方示例要求的最小高度约束，
 *   避免刷新区域收缩时把加载动画压扁。
 *
 * ## 用法
 * ```ts
 * build() {
 *   PullToRefresh({
 *     onRefresh: () => this.load(),
 *     contentBuilder: () => { this.pageContent(); }
 *   })
 * }
 * ```
 * `contentBuilder` **必须**是箭头函数包一层，直接传 `this.pageContent` 会把
 * `this` 绑到本组件，页面状态全部读成空白（见 arkts-localbuilder）。
 */
@Component
export struct PullToRefresh {
  /** 页面提供的刷新回调；Promise resolve/reject 后动画自动收起。 */
  onRefresh: () => Promise<void> = async (): Promise<void> => {
  };
  @BuilderParam contentBuilder: () => void;
  /** 仅组件内部使用，避免与业务页 loading / refreshing 标志互相干扰。 */
  @State private refreshing: boolean = false;
  /**
   * LoadingProgress **一挂载就开始转**，所以不能常驻在 builder 里：
   * Refresh 即使处于 Inactive / Done，builder 节点仍然活着，动画会一直跑。
   * 只有真正进入刷新时才挂载它，结束即卸载。
   */
  @State private showSpinner: boolean = false;

  /**
   * 官方示例的加载指示器：LoadingProgress 32vp + 最小高度约束。
   *
   * ⚠️ Stack 外壳**必须常驻**：Refresh 的 builder 若在某些时刻返回空（没有任何
   * 组件），刷新区高度会抖动，进而干扰它对垂直手势的判定。只让内部的
   * LoadingProgress 按 showSpinner 条件挂载 —— 既保持刷新区结构稳定，又不会在
   * 非刷新态常驻转圈。
   */
  @Builder
  officialIndicator() {
    Stack() {
      if (this.showSpinner) {
        LoadingProgress()
          .width(32)
          .height(32)
      }
    }
    .align(Alignment.Center)
    .clip(true)
    .constraintSize({ minHeight: 32 })
    .width('100%')
  }

  private async runRefresh(): Promise<void> {
    // ⚠️ 不要在这里加 `if (this.refreshing) return`：
    // Refresh 触发 onRefreshing 时已通过 $$ 把 refreshing 置为 true，
    // 这层 guard 会把真正的刷新回调挡掉，动画就永远停不下来。
    this.showSpinner = true;
    try {
      await this.onRefresh();
    } catch (error) {
      Logger.error('下拉刷新失败：' + (error as Error).message);
    } finally {
      this.showSpinner = false;
      // Refresh 收到 false 后自动进入 Done 回弹到顶部 —— 页面归位。
      this.refreshing = false;
    }
  }

  build() {
    Refresh({ refreshing: $$this.refreshing, builder: this.officialIndicator() }) {
      this.contentBuilder()
    }
    .width('100%')
    .height('100%')
    // 官方《开发应用沉浸式效果》：子节点单独设 expandSafeArea 时，
    // 「需要确保父组件未设置 clip 等裁剪属性」。各页 Scroll 已设 clip(false)
    // + expandSafeArea，这里必须一并关掉 Refresh 自身的裁剪，否则 Scroll
    // 往标题栏下方的绘制延伸会被裁掉，玻璃材质后面只剩目的地纯色背景（黑遮罩）。
    // ⚠️ 但不能给 Refresh 加 expandSafeArea()：它自带垂直 PanGesture，扩展安全区
    // 会把手势区撑进状态栏/导航栏，与内层 Scroll 抢手势 —— 页面上下滑都不动。
    .clip(false)
    // ⚠️ 背景也不能铺 AppColor.pageBackground：ResourceColor 默认铺满所有安全区，
    // 深色主题下会把标题栏玻璃背后刷成纯黑。页面底色由内层 Scroll 提供，这里透明。
    .backgroundColor(Color.Transparent)
    .refreshOffset(64)
    .pullToRefresh(true)
    .onStateChange((state: RefreshStatus) => {
      // 兜底同步：被上滑取消 / Refresh 自行回到初始态时也立刻停掉动画。
      if (state === RefreshStatus.Inactive || state === RefreshStatus.Done) {
        this.showSpinner = false;
      }
    })
    .onRefreshing(() => {
      this.runRefresh();
    })
  }
}
