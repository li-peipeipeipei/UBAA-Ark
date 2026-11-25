import { KEY_IS_DARK, pageBackgroundArgbHex } from '../common/ImmersiveUtil';

/**
 * 横向胶囊行两侧渐隐遮罩的宽度（vp）：自行的两端向内延伸这么多。
 *
 * 取值与博雅课程页的筛选胶囊行一致 —— 四处（博雅 / 图书馆座位 / iHome / 财务收入 / SPOC）
 * 共用同一个常量，避免各处手感不同。
 */
export const CHIP_FADE_WIDTH: number = 15;

/**
 * 横向滚动胶囊行两侧的渐隐遮罩（恒定显示，不随滚动位置变化）。
 *
 * ## 用法
 * 挂在胶囊 `Scroll` 的 `overlay` 上，高度必须由宿主的 `onAreaChange` 实测上报：
 * `overlay` 里 `height('100%')` 会撑到整页高，把下方内容一起压暗。
 *
 * ```ts
 * Scroll() { ... }
 *   .clip(false)
 *   .onAreaChange((_old: Area, now: Area) => { this.chipsRowH = Number(now.height); })
 *   .overlay(this.chipsEdgeFade(), { align: Alignment.Center })
 * ```
 *
 * ## 为什么是 overlay 而不是外层包一个 Stack
 * `Stack` 会抢走横向 Pan（实测滑不动）；`overlay` 不参与布局、也不吃手势。
 *
 * ## 颜色
 * 渐变两端必须是**页面底色的同 RGB、只降 alpha**（不透明端 75%，透明端 0）。
 * 不能写 `Color.Transparent`（rgba(0,0,0,0)）—— 浅色底上与遮罩色插值会渗出灰黑，
 * 形成一条脏带。真值从 `app.color.page_background` 取，深浅色自动跟随。
 */
@Component
export struct ChipsEdgeFade {
  /** 遮罩高度（vp）：由宿主胶囊行实测上报。 */
  @Prop fadeHeight: number = 34;
  /** 深色主题（渐隐色跟随主题，浅色底上才不会发灰）。 */
  @StorageProp(KEY_IS_DARK) private isDarkTheme: boolean = false;

  /** 渐隐的不透明端：页面底色 + 75% alpha（0xBF）。 */
  private headColor(): string {
    return '#BF' + pageBackgroundArgbHex(this.isDarkTheme).substring(3);
  }

  /** 渐隐的透明端：同色 alpha=0。 */
  private tailColor(): string {
    return '#00' + pageBackgroundArgbHex(this.isDarkTheme).substring(3);
  }

  build() {
    Row() {
      // 左：自左边缘向内，75% → 0
      Column()
        .width(CHIP_FADE_WIDTH)
        .height('100%')
        .linearGradient({
          angle: 90,
          colors: [[this.headColor(), 0], [this.tailColor(), 1]]
        })
      Blank()
      // 右：自右边缘向内，75% → 0（渐变方向反过来）
      Column()
        .width(CHIP_FADE_WIDTH)
        .height('100%')
        .linearGradient({
          angle: 90,
          colors: [[this.tailColor(), 0], [this.headColor(), 1]]
        })
    }
    .width('100%')
    // 高度必须显式给：`height('100%')` 在 overlay 里会撑到整页高，
    // 渐隐条就会把下方卡片的左右边缘一起压暗。
    .height(this.fadeHeight)
    .hitTestBehavior(HitTestMode.None)
  }
}
