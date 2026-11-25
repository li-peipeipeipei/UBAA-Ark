import { AppColor, AppFont, AppSize } from './AppTheme';

/**
 * 成绩概览里的一格（数值 + 标签）。
 *
 * 必须做成 @Component（@Prop），不能再写成带参数的 @Builder：
 * @Builder 的普通参数按值传递、不参与状态刷新 —— 首帧算出的「统计中」会一直
 * 留在界面上，即使后台早已汇总完成（真机踩过：全部成绩永远显示「统计中」）。
 */
@Component
export struct SummaryValueCell {
  @Prop label: string = '';
  @Prop value: string = '';

  build() {
    Column({ space: 2 }) {
      Text(this.value)
        .fontSize(AppFont.titleLarge)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.label)
        .fontSize(AppFont.caption)
        .fontColor(AppColor.textSecondary)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }
}
/**
 * 成绩概览卡（全部成绩 / 本学期）。
 *
 * 数值全部以字符串传入（由页面按 GradeStats 的算法算好后格式化），组件只负责排版；
 * loading 为 true 时三个指标显示「统计中」（与原版一致）。
 */
@Component
export struct GradeSummaryCard {
  @Prop title: string = '';
  @Prop showCourseAndCredits: boolean = false;
  @Prop loading: boolean = false;
  @Prop courseCountText: string = '';
  @Prop creditsText: string = '';
  @Prop gpaText: string = '';
  @Prop weightedText: string = '';
  @Prop arithmeticText: string = '';

  @Builder
  emptyTrailing() {
  }

  /**
   * 标题行右侧插槽（成绩页的学期切换器放在这里）。
   *
   * 不传时这一行与改造前完全一样：`Row { 标题; Blank; 插槽 }` 里标题仍在最左，
   * Blank 吃掉剩余宽度，插槽为空就不渲染任何东西 —— 既不动原有排版，
   * 也避免为「本学期」这一张卡单独复制一份组件。
   */
  @BuilderParam trailing: () => void = this.emptyTrailing;

  build() {
    Column({ space: AppSize.gapSmall }) {
      Row() {
        Text(this.title)
          .fontSize(AppFont.subtitle)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.textPrimary)

        Blank()

        this.trailing()
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      /**
       * 标题行固定 24vp 高（= 学期切换按钮的直径）。
       *
       * 「本学期」的插槽里是 24×24 的箭头按钮，「全部成绩」没有插槽 —— 只按文字算，
       * 两张卡并排时标题行差 2vp，整张卡底边就差 2vp（真机看得出来）。
       * 给标题行一个下限，有没有插槽都同高；字体放大时两卡一起增高，仍保持一致。
       */
      .constraintSize({ minHeight: 24 })

      if (this.showCourseAndCredits) {
        Row() {
          SummaryValueCell({ label: '课程数', value: this.courseCountText })
            .layoutWeight(1)
          SummaryValueCell({ label: '总学分', value: this.creditsText })
            .layoutWeight(1)
        }
        .width('100%')
      }

      Row() {
        SummaryValueCell({ label: 'GPA', value: this.loading ? '统计中' : this.gpaText })
          .layoutWeight(1)
        SummaryValueCell({ label: '加权平均分', value: this.loading ? '统计中' : this.weightedText })
          .layoutWeight(1)
        SummaryValueCell({ label: '算数平均分', value: this.loading ? '统计中' : this.arithmeticText })
          .layoutWeight(1)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(AppSize.pagePadding)
    .borderRadius(AppSize.cardRadius)
    .backgroundColor(AppColor.brandContainer)
  }
}
