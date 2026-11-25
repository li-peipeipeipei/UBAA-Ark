/**
 * 课表 · 桌面卡片（2×2「下一节课」）。
 *
 * 与 1×2 的 ScheduleSmallCard **共用同一份数据**（同样的 LocalStorage key），
 * 差别只在渲染：2×2 有约 158vp 见方的空间，除了「下一节课」还能多放
 * 今天节数、教学周，信息更完整（2026-11-23 按用户要求删掉右下角更新时间）。
 * 「下一节」由主应用算好后放进数据里（`next`），卡片不自己判断当前时间。
 *
 * ⚠️ 与大卡同样的两个限制：**不能用 hilog**（编译器报
 * `'hilog' can't support form application`）、**不 import 项目任何 .ets**
 * （卡片导入链的雷区，见官方 FAQ）。只用 ArkUI 内置组件 + `$r('app.color.*')`
 * 资源（颜色随系统深浅色自动切换）。
 */

interface NextCardCourse {
  section: string;
  time: string;
  courseName: string;
  place: string;
  /** 跨天时如 `明天` / `周三`，今天则没有此字段。 */
  when?: string;
}

interface NextCardToday {
  headline: string;
  summary: string;
  courses: NextCardCourse[];
  /** 下一节课（没有则为 null）。 */
  next: NextCardCourse | null;
  /** 下一节课是哪天，如 `明天 08:00` / `今天 08:00`。 */
  nextWhen: string;
  ready: boolean;
}

let nextCardStorage: LocalStorage = new LocalStorage();

@Entry(nextCardStorage)
@Component
struct ScheduleNextCard {
  /**
   * ⚠️ 必须带 `@Watch`：卡片数据在组件创建之后才注入，`@LocalStorageProp`
   * 只在初始化时取一次值（那时 scheduleJson 还是空串）。加 `@Watch` 才能在
   * 数据真正到达/updateForm 推进来时重新解析。
   */
  @LocalStorageProp('scheduleJson') @Watch('onPayloadChanged') scheduleJson: string = '';
  @LocalStorageProp('weekLabel') weekLabel: string = '';
  @LocalStorageProp('updatedAt') updatedAt: string = '';

  @State private today: NextCardToday | null = null;

  aboutToAppear(): void {
    this.parse();
  }

  onPayloadChanged(): void {
    this.parse();
  }

  private parse(): void {
    if (this.scheduleJson.length === 0) {
      this.today = null;
      return;
    }
    try {
      this.today = JSON.parse(this.scheduleJson) as NextCardToday;
    } catch (error) {
      this.today = null;
    }
  }

  private openApp(): void {
    postCardAction(this, {
      action: 'router',
      abilityName: 'EntryAbility',
      params: {
        target: 'schedule'
      }
    });
  }

  /** 跨天标签文案（下一节不是今天时才有）；用方法收窄类型，避免 Builder 里做可选链断言。 */
  private whenLabel(): string {
    const next: NextCardCourse | null | undefined = this.today?.next;
    if (next !== undefined && next !== null && next.when !== undefined && next.when !== null) {
      return next.when;
    }
    return '';
  }

  /** 没有缓存 / 没数据时居中显示引导。 */
  @Builder
  emptyView() {
    Column({ space: 8 }) {
      Text('下一节课')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      Text('打开 App 查看课表')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /** 今天没课、且本周后面也没有课。 */
  @Builder
  noClassView() {
    Column({ space: 8 }) {
      Text('下一节课')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      Text('今天没有课了')
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
      Text('好好休息 · 打开 App 查看完整课表')
        .fontSize(10)
        .fontColor($r('app.color.text_tertiary'))
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 有下一节课时的主体。
   *
   * 158vp 见方，扣掉 padding 约 134vp 可用高度：卡片名 + 时间/节次 + 课程名 +
   * 地点 + 跨天标签 + 底部统计，按行锁高合计约 118vp，留有余量不被裁。
   */
  @Builder
  nextView() {
    Column({ space: 0 }) {
      // 顶部：卡片名 + 教学周
      Row() {
        Text('下一节课')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Text(this.weekLabel.length > 0 ? this.weekLabel : (this.today?.headline ?? ''))
          .fontSize(10)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
      }
      .width('100%')
      .height(20)
      .alignItems(VerticalAlign.Center)
      .justifyContent(FlexAlign.SpaceBetween)

      // 跨天标签（下一节不是今天时才有）：如「明天」
      if (this.whenLabel().length > 0) {
        Text(this.whenLabel())
          .fontSize(10)
          .fontColor($r('app.color.brand'))
          .height(16)
          .width('100%')
      }

      Column({ space: 2 }) {
        // 时间与节次
        Text((this.today?.next?.time ?? '') + ' · ' + (this.today?.next?.section ?? ''))
          .fontSize(12)
          .fontColor($r('app.color.brand'))
          .lineHeight(18)
          .maxLines(1)
        // 课程名（主视觉，允许折到第二行）
        // 2026-11-23：19→16 —— 手机上卡片宽度比平板小，19 号字一行只显示几个字就
        // 折行/省略。降到 16 让一行多显示几个字；仍是 Bold 主视觉。
        Text(this.today?.next?.courseName ?? '')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .lineHeight(21)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        // 地点（用户要求：课程名与教室都加粗）
        Text(this.today?.next?.place ?? '')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_secondary'))
          .lineHeight(18)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Center)
      .layoutWeight(1)

      // 底部：今天节数（2026-11-23 按用户要求删掉右下角的更新时间）
      Row() {
        Text('今天 ' + (this.today?.courses?.length ?? 0).toString() + ' 节')
          .fontSize(10)
          .fontColor($r('app.color.text_tertiary'))
      }
      .width('100%')
      .height(16)
      .alignItems(VerticalAlign.Center)
      .justifyContent(FlexAlign.Start)
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Column() {
      if (this.today === null) {
        this.emptyView()
      } else if (this.today?.next !== null && this.today?.next !== undefined) {
        this.nextView()
      } else {
        this.noClassView()
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor($r('app.color.surface'))
    .onClick(() => {
      this.openApp();
    })
  }
}
