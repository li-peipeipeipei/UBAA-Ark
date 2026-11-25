/**
 * 课表 · 桌面卡片（次大 1×2）。
 *
 * 与 2×2 大卡**共用同一份数据**（同样的 LocalStorage key），差别只在渲染：
 * 1×2 是横向窄条，塞不下课程列表，所以只放**最有价值的一条 —— 下一节课**。
 * 「下一节」由主应用算好后放进数据里（`next`），卡片不自己判断当前时间，
 * 免得宿主时间与卡片渲染时间不一致。
 *
 * ⚠️ 与大卡同样的两个限制：**不能用 hilog**（编译器报
 * `'hilog' can't support form application`）、**不 import 项目任何 .ets**
 * （卡片导入链的雷区，见官方 FAQ）。
 */

interface SmallCardCourse {
  section: string;
  time: string;
  courseName: string;
  place: string;
}

interface SmallCardToday {
  headline: string;
  summary: string;
  courses: SmallCardCourse[];
  /** 下一节课（没有则为 null）。 */
  next: SmallCardCourse | null;
  ready: boolean;
}

let smallCardStorage: LocalStorage = new LocalStorage();

@Entry(smallCardStorage)
@Component
struct ScheduleSmallCard {
  /**
   * ⚠️ 必须带 `@Watch`。
   *
   * 卡片的 LocalStorage 数据是**在组件创建之后**才注入的：`@LocalStorageProp` 只在初始化时
   * 取一次值，那时 `scheduleJson` 还是空串。若只在 `aboutToAppear` 里 parse，
   * `today` 会永久停在 null —— 表现为「预览/刚添加时一片空白，之后 updateForm 推进来也不变」。
   * 加上 `@Watch` 才能在数据真正到达时重新解析。
   */
  @LocalStorageProp('scheduleJson') @Watch('onPayloadChanged') scheduleJson: string = '';
  @LocalStorageProp('weekLabel') weekLabel: string = '';

  @State private today: SmallCardToday | null = null;

  aboutToAppear(): void {
    this.parse();
  }


  /** `@Watch` 回调：卡片数据在组件创建之后才注入，变化时必须重新解析一次。 */
  onPayloadChanged(): void {
    this.parse();
  }

  private parse(): void {
    if (this.scheduleJson.length === 0) {
      this.today = null;
      return;
    }
    try {
      this.today = JSON.parse(this.scheduleJson) as SmallCardToday;
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

  /**
   * 主体：单列全宽布局（2026-11-23 改）。
   *
   * 原来的「右侧竖列」（大数字 + 节/今天 + 教室）占 76vp、把课程名挤得只剩几个字，
   * 现按用户要求重排为三行、各行都能延伸到卡片最右端：
   *   ① 教学周（左） + 今天 N 节（右上角，样式与大卡完全一致）
   *   ② 时间·节次（左） + 教室（右，同一行）
   *   ③ 课程名（整行全宽）
   *
   * ⚠️ 尺寸预算：`1*2` 卡高约 79vp，扣掉上下 padding（6+12）后可用约 61vp。
   * 三行锁高 15+15+19=49vp，稳妥不被裁。
   */
  build() {
    Column({ space: 0 }) {
      // ① 顶部：教学周 + 今天节数（右上角）
      Row() {
        Text(this.weekLabel.length > 0 ? this.weekLabel : (this.today?.headline ?? 'UBAA 课表'))
          .fontSize(11)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        // 与大卡底部「今天 N 节」同款：fontSize(10) + text_tertiary
        Text('今天 ' + (this.today?.courses?.length ?? 0).toString() + ' 节')
          .fontSize(10)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
      }
      .width('100%')
      .height(15)
      .alignItems(VerticalAlign.Center)
      .justifyContent(FlexAlign.SpaceBetween)

      if (this.today === null) {
        Text('打开 App 查看课表')
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
          .lineHeight(16)
          .maxLines(1)
          .width('100%')
      } else if (this.today?.next !== null && this.today?.next !== undefined) {
        // ② 时间·节次（左） + 教室（右，同行）
        Row() {
          Text(this.today?.next?.time + ' · ' + this.today?.next?.section)
            .fontSize(9)
            .fontColor($r('app.color.brand'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text(this.today?.next?.place ?? '')
            .fontSize(9)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 72 })
        }
        .width('100%')
        .height(15)
        .alignItems(VerticalAlign.Center)
        .justifyContent(FlexAlign.SpaceBetween)

        // ③ 课程名：整行全宽，延伸到卡片最右端
        Text(this.today?.next?.courseName ?? '')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .lineHeight(19)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      } else {
        Text('今天没有课了')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .lineHeight(18)
          .maxLines(1)
          .width('100%')
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    // 2026-11-23：内容整体上移 2vp（top 8→6 / bottom 10→12，内容区高度不变），
    // 下方多留的白抵消文字 lineHeight 的视觉下沉，使上下观感等距。
    .padding({ left: 12, right: 10, top: 6, bottom: 12 })
    .backgroundColor($r('app.color.surface'))
    .onClick(() => {
      this.openApp();
    })
  }
}