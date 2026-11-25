import { AppColor, AppFont } from './AppTheme';
import curves from '@ohos.curves';

/**
 * 多选筛选胶囊（博雅课程筛选面板的基准样式，四处共用）。
 *
 * ## 交互
 * - 点一次选中：前置 ✓ 用「宽度 / 间距 / 透明度」三个动画属性同时展开，
 *   胶囊自身的宽度变化因此是连续的（不跳变）；
 * - 再点一次取消：✓ 收回、底色与描边回落到未选中态；
 * - 弹簧曲线 `responsiveSpringMotion(0.25, 0.7)`，与博雅课程页完全一致。
 *
 * ## 为什么必须有本地 `@State selected`
 * 选中态由**组件自己**重绘，不依赖父级重建：
 * - 父级若是半模态面板 / 弹窗，会被缓存，参数更新后子组件不一定重跑 build；
 * - `@Builder` 的普通参数是「值传递 + 不参与刷新」，用它渲染胶囊会出现
 *   「点了没反馈、再点也取消不掉」。
 *
 * 父子双写：点击后先动画改本地 `selected`，再通过 `onTap` 通知父级改筛选条件。
 */
@Component
export struct FilterChip {
  label: string = '';
  /** 首次挂载时的初始选中态。 */
  initialSelected: boolean = false;
  /**
   * 受控模式：选中态**完全由父级 `active` 决定**（单选标签页 / 单选筛选）。
   *
   * 默认 `false`，即博雅 / SPOC / 评价等既有页面用的「自管状态」模式 —— 那些页面
   * 点一下自己翻转 `selected` 并回调父级，行为一字不变。
   *
   * 受控模式用于**同一时刻只能选中一个**的胶囊行（云打印的五个分区）：
   * 点击只回调父级，父级在 `animateTo` 作用域里改自身状态 → 本组件的 `@Prop active`
   * 随之更新 → 选中的胶囊展开 ✓、其余收回，两个方向的过渡都在同一条弹簧曲线上。
   * ⚠️ 不要在受控模式下再翻转本地 `selected`：两套状态会打架，表现为「点了两个都亮」。
   */
  controlled: boolean = false;
  /** 受控模式下的选中态（由父级传入）。 */
  @Prop active: boolean = false;
  /** 组件内部状态：点击后自己重绘（仅非受控模式使用，见类注释）。 */
  @State selected: boolean = false;
  onTap: () => void = () => {
  };

  aboutToAppear(): void {
    this.selected = this.initialSelected;
  }

  /** 当前是否处于选中态（受控走 `active`，自管走 `selected`）。 */
  private isOn(): boolean {
    return this.controlled ? this.active : this.selected;
  }

  build() {
    Row() {
      // ✓ 常驻，只动画宽度 / 间距 / 透明度 —— 这样胶囊自身的宽度变化是连续的
      SymbolGlyph($r('sys.symbol.checkmark'))
        .fontSize(12)
        .fontColor([AppColor.brand])
        .width(this.isOn() ? 12 : 0)
        .height(12)
        .margin({ right: this.isOn() ? 4 : 0 })
        .opacity(this.isOn() ? 1 : 0)
      Text(this.label)
        .fontSize(AppFont.caption)
        .fontColor(this.isOn() ? AppColor.brand : AppColor.textSecondary)
    }
    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
    .margin({ right: 8, bottom: 4 })
    .borderRadius(16)
    .backgroundColor(this.isOn() ? AppColor.brandContainerGlass : Color.Transparent)
    .border({
      width: 1,
      color: this.isOn() ? Color.Transparent : AppColor.divider
    })
    .onClick(() => {
      if (this.controlled) {
        // 选中态由父级决定；动画也由父级的 animateTo 统一驱动（见 controlled 注释）
        this.onTap();
        return;
      }
      animateTo({ curve: curves.responsiveSpringMotion(0.25, 0.7) }, () => {
        this.selected = !this.selected;
      });
      this.onTap();
    })
  }
}
