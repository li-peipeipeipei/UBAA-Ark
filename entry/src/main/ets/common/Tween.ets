import { AnimatorOptions, AnimatorResult, UIContext } from '@kit.ArkUI';

/**
 * 逐帧数值补间。
 *
 * ## 为什么不用 `animateTo` / `.animation()`
 *
 * 它们补间的是**属性**，不会重跑 `build()`。凡是"由状态推导出来的东西"（栅格列数、
 * 排列方式、子组件结构）在动画期间都会**冻住**：宽度在变、列数不变，于是磁贴被挤在
 * 一起甚至重叠，动画结束那一刻才一次性归位 —— 真机上看到的就是"抖一下/跳一下"。
 *
 * 这里的做法相反：用 `UIContext.createAnimator` 拿逐帧回调，**每一帧写一次状态**，
 * 于是 build 每帧都跑，宽度与所有派生值同源、同帧更新。
 *
 * 用法：一个组件持一个实例（复用同一个 animator，避免重复创建）。
 */
export class Tween {
  private result: AnimatorResult | undefined = undefined;

  /**
   * 从 `from` 补间到 `to`，每帧回调一次。
   *
   * @param ui UIContext（组件里用 `this.getUIContext()`）
   * @param from 起始值（一般传当前值，支持中途打断后续上）
   * @param to 目标值
   * @param duration 时长（ms）
   * @param delay 延迟（ms）
   * @param onUpdate 每帧回调，参数为当前插值
   */
  run(ui: UIContext, from: number, to: number, duration: number, delay: number,
    onUpdate: (value: number) => void): void {
    this.cancel();
    if (Math.abs(to - from) < 0.01) {
      onUpdate(to);
      return;
    }
    const options: AnimatorOptions = {
      duration: duration,
      easing: 'friction',
      delay: delay,
      fill: 'forwards',
      direction: 'normal',
      iterations: 1,
      begin: from,
      end: to
    };
    const result: AnimatorResult = ui.createAnimator(options);
    result.onFrame = (value: number) => {
      onUpdate(value);
    };
    this.result = result;
    result.play();
  }

  /** 取消进行中的补间（组件销毁或新补间覆盖时必须调用，否则会写脏状态）。 */
  cancel(): void {
    if (this.result !== undefined) {
      this.result.cancel();
      this.result = undefined;
    }
  }
}
