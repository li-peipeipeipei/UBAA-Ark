/**
 * 日课表 · 桌面卡片（4×4 / 2×4 两种尺寸，可拖拽调整）。
 *
 * ## 版式：像素级复刻北航官方课表卡的「日视图」
 *
 * ```
 * ┌───────────────────────────────────────┐
 * │ 10月11日 星期日·  第 5 周              │  ← 日期橙 + 星期白 / 右侧周次
 * │            今日无课程                │  ← 空态居中
 * │ 明天  ③│  ← 分组标题 + 节数
 * │ ┌───────────────────────────────────┐ │
 * │ │ 理论力学A（1）        14:00 │ 15:35 │ │  ← 左课名+地点 / 右时间两行
 * │ │ J3-212 | 吕敬│ │
 * │ └───────────────────────────────────┘ │
 * └───────────────────────────────────────┘
 * ```
 *
 * 实测规格（官方截图 1249×552px）：卡片底色 `#2F3034`、标题橙 `#F76045`；
 * 课程块 2026-11-24 起改用产品给的 16 色色表（原参考色 `#602030` 已弃用）。
 *
 * ## 为什么「今天没课时把明天的课顶上来」
 *
 * 官方就是这么做的 —— 今天是周日没课，它把**明天（周一）的第一节**顶上来，
 * 并在左侧标「明天 ③」（③ = 明天有 3 节课）。空白卡没有任何信息量，
 * 「下一节课」才是用户真正想知道的。
 *
 * 数据由主应用算好推过来（`dayLabel` / `dayCount`），卡片不自己判断时间 ——
 * 卡片渲染进程与主应用的时间可能差几秒，让卡片自己算会显示错。
 *
 * ## ⚠️ 卡片里不能滚动
 *
 * `Scroll` / `List` / `scrollBar` / `edgeEffect` 全部被编译器拦
 *（`'Scroll' can't support form application`，错误码 11706006）——
 * 所以课程一次性全画出来，不做滚动。
 *
 * ## 数据从哪来
 *
 * FRS 进程与主应用内存隔离，靠 `formProvider.updateForm` 推数据，
 * key 注入本页 `LocalStorage`，用 **`@LocalStorageProp`** 接收。
 * 官方明写「接收数据时会被转换成 string 类型」，所以收到的是 JSON 串。
 *
 * ## ⚠️ 本文件为什么这么「空」
 *
 * 1. **不能用 hilog** —— `'hilog' can't support form application`，构建期就拦；
 * 2. **不 import 项目的任何 .ets** —— 官方 FAQ：卡片不支持加载
 *    particleAbility / audio / camera / media / backgroundTaskManager，
 *    「强行加载得到的对象是 undefined，使用时就会产生 JS crash」。
 */

/** LocalStorage key（必须与 UBAAFormAbility 推送的字段名完全一致）。 */
const KEY_DAY_VIEW: string = 'dayViewJson';
const KEY_UPDATED_D: string = 'updatedAt';

/**
 * 深色模式下的课程块色板 —— 与周课表卡同一套莫奈暗色。
 *
 * ⚠️ 卡片模块级常量是**全局作用域**，两张卡的常量必须不同名（故加 _D 后缀）；
 * 卡片也不能 import 项目文件，所以两处各存一份 —— **改色时两边要同步**。
 */
const MONET_DARK_D: string[] = [
  '#944438', '#965B36', '#8E7714', '#54794E',
  '#427071', '#21629A', '#524D8F', '#6C4A8F',
  '#95182F', '#8B4E2A', '#816F26', '#3A6333',
  '#216666', '#3A5985', '#5C4D71', '#4A4E76'
];
/**
 * 深色块上文字的「块色混白」比例：块色占 35%，白占 65%。
 * 与 `ScheduleColors.DARK_TEXT_TINT_RATIO`、周卡 `DARK_TEXT_TINT_W` 三处同步。
 */
const DARK_TEXT_TINT_D: number = 0.35;

/**
 * 浅色课程块底色：2026-11-22 第三轮——按反馈「对齐文字颜色和块颜色」，
 * 每格底色 = 同索引 LIGHT_TEXT_D 文字色叠白派生（14%），
 * 16 槽一一对应、同色系（2026-11-24 换产品线给的 16 色色表）。
 * 必须与 ScheduleColors.LIGHT / ScheduleWeekCard.LIGHT_PALETTE_W 三处同步。
 * 仍是预混实色，不加真 alpha —— 真透明会露出网格横线。
 */
const LIGHT_PALETTE_D: string[] = [
  '#F9E7E4', '#F9ECE3', '#F7F2DB', '#EAF3E8',
  '#E6F0F0', '#DFEDFA', '#EAE8F7', '#F0E8F7',
  '#F9DDE1', '#F7E9E0', '#F4F0E0', '#E4EEE2',
  '#DFEEEE', '#E4EBF5', '#ECE9F0', '#E8E9F2'
];
/**
 * 浅色块上的文字色（与 LIGHT_PALETTE_D 同索引配对）。
 * 2026-11-24：按产品给的 16 色整板替换（前 8 / 后 8 按色相配对）。
 * ⚠️ 卡片不能 import 项目文件，两张卡各存一份；**改配色时三处要同步**。
 */
const LIGHT_TEXT_D: string[] = [
  '#D2513B', '#D57538', '#C8A201', '#6AA65E',
  '#4D9796', '#1981D8', '#675EC7', '#925AC7',
  '#D30A2C', '#C36124', '#B3961E', '#408333',
  '#198784', '#4172B7', '#785F96', '#5B619F'
];



/** 一节课（与主应用 CardCache 的 CardSlot 同形）。 */
interface DayViewSlot {
  day: number;
  begin: number;
  end: number;
  time: string;
  courseName: string;
  place: string;
  color: string;
  /** 主应用算好的相邻避让色槽（0..15）；缺省时回退课程名哈希。 */
  colorSlot?: number;
}

/**
 * 日课表卡数据。
 *
 * 与主应用 `CardCache.CardDayView` 同形，额外两个字段服务于「今天没课」的顶替显示：
 * - `dayLabel`：`今天` / `明天` / `周三` —— 空态时顶上来的那天的名字；
 * - `dayCount`：那一天有几节课（官方在分组标题后跟一个数字）。
 */
interface DayViewData {
  headline: string;
  /** 例如 `第 11 周`（主应用算好传过来，卡片不再写死）。 */
  weekLabel: string;
  day: number;
  slots: DayViewSlot[];
  sections: number;
  times: string[];
  dayLabel: string;
  dayCount: number;
  ready: boolean;
}

let dayCardStorage: LocalStorage = new LocalStorage();

@Entry(dayCardStorage)
@Component
struct ScheduleDayCard {
  @LocalStorageProp(KEY_DAY_VIEW) @Watch('onPayloadChanged') dayViewJson: string = '';
  @LocalStorageProp(KEY_UPDATED_D) updatedAt: string = '';
  /** 主应用推来：`'1'` = 深色模式，课程块换莫奈暗色板 + 浅色文字。 */
  /**
   * ⚠️ 必须挂 `@Watch`：卡片的 `@LocalStorageProp` 单独变化**不会触发重绘**，
   * 只有字段变了 + 有 Watch 才会重新走 parse → build。少了它，切深浅色后
   * 块色和背景都还停在上一种主题。
   */
  @LocalStorageProp('darkMode') @Watch('onPayloadChanged') darkMode: string = '0';

  @State private view: DayViewData | null = null;

  aboutToAppear(): void {
    this.parse();
  }

  /** `@Watch` 回调：卡片数据在组件创建之后才注入，变化时必须重新解析一次。 */
  onPayloadChanged(): void {
    this.parse();
  }

  private parse(): void {
    if (this.dayViewJson.length === 0) {
      this.view = null;
      return;
    }
    try {
      const parsed = JSON.parse(this.dayViewJson) as DayViewData;
      this.view = ScheduleDayCard.normalize(parsed);
    } catch (error) {
      this.view = null;
    }
  }

  /**
   * 逐字段归一化：卡片数据跨进程读自 Preferences，旧缓存或上游缺字段时
   * 渲染期读 `undefined.length` 会让整张卡白屏（@Watch 不会自愈）。
   */
  private static normalize(view: DayViewData): DayViewData {
    const rawSlots = view.slots;
    const slots: DayViewSlot[] = [];
    if (Array.isArray(rawSlots)) {
      for (let i = 0; i < rawSlots.length; i++) {
        const s = rawSlots[i];
        slots.push({
          day: typeof s.day === 'number' ? s.day : 0,
          begin: typeof s.begin === 'number' ? s.begin : 0,
          end: typeof s.end === 'number' ? s.end : 0,
          time: typeof s.time === 'string' ? s.time : '',
          courseName: typeof s.courseName === 'string' ? s.courseName : '',
          place: typeof s.place === 'string' ? s.place : '',
          color: typeof s.color === 'string' ? s.color : ''
        } as DayViewSlot);
      }
    }
    const times: string[] = Array.isArray(view.times) ? view.times : [];
    return {
      headline: typeof view.headline === 'string' ? view.headline : '',
      weekLabel: typeof view.weekLabel === 'string' ? view.weekLabel : '',
      day: typeof view.day === 'number' ? view.day : 0,
      slots: slots,
      sections: typeof view.sections === 'number' ? view.sections : 0,
      times: times,
      dayLabel: typeof view.dayLabel === 'string' ? view.dayLabel : '',
      dayCount: typeof view.dayCount === 'number' ? view.dayCount : 0,
      ready: view.ready === true
    } as DayViewData;
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

  /** 时间拆成起 / 止两行（官方右侧就是两行：`14:00` / `15:35`）。 */
  private timeParts(slot: DayViewSlot): string[] {
    const full: string = slot.time;
    const i: number = full.indexOf('~');
    if (i > 0) {
      return [full.substring(0, i), full.substring(i + 1)];
    }
    return full.length > 0 ? [full, ''] : ['', ''];
  }

  /** 这门课占几节（至少 1）。 */
  private spanOf(slot: DayViewSlot): number {
    const span = slot.end - slot.begin + 1;
    return span > 0 ? span : 1;
  }

  /**
   * 课程色槽：优先用主应用按整学期「相邻避让」算好的 colorSlot，
   * 没有（旧缓存 / 首次下发）时回退课程名哈希。同名课恒定同槽。
   */
  private slotIndexOf(slot: DayViewSlot): number {
    const assigned: number | undefined = slot.colorSlot;
    if (assigned !== undefined && assigned >= 0 && assigned < MONET_DARK_D.length) {
      return assigned;
    }
    return this.monetIndex(slot.courseName);
  }

  /** 课程色槽落到色板取底色；色表本身就是兜底，不再写死某个酒红。 */
  private colorOf(slot: DayViewSlot): string {
    const idx: number = this.slotIndexOf(slot);
    if (this.darkMode === '1') {
      return this.blendOn('#2F3034', MONET_DARK_D[idx], 0.92);
    }
    return LIGHT_PALETTE_D[idx];
  }

  /** 把 color 以 alpha 预混到底色 bg 上，返回不透明实色（防网格线透出）。 */
  private blendOn(bg: string, color: string, alpha: number): string {
    const br: number = this.channelOf(bg, 0);
    const bgc: number = this.channelOf(bg, 1);
    const bb: number = this.channelOf(bg, 2);
    const r: number = Math.round(br + (this.channelOf(color, 0) - br) * alpha);
    const g: number = Math.round(bgc + (this.channelOf(color, 1) - bgc) * alpha);
    const b: number = Math.round(bb + (this.channelOf(color, 2) - bb) * alpha);
    return '#' + this.hex2(r) + this.hex2(g) + this.hex2(b);
  }

  private hex2(v: number): string {
    const clamped: number = v < 0 ? 0 : (v > 255 ? 255 : v);
    return clamped < 16 ? '0' + clamped.toString(16).toUpperCase() : clamped.toString(16).toUpperCase();
  }

  /** 课程名 → 稳定的色板下标（同名课永远同色）。 */
  private monetIndex(name: string): number {
    let h: number = 7;
    for (let i = 0; i < name.length; i++) {
      h = (h * 31 + name.charCodeAt(i)) % 100003;
    }
    return h % MONET_DARK_D.length;
  }
  /**
   * 卡片自己的主题色（**不用 `$r()` 资源**）。
   *
   * 资源解析跟随**卡片进程**的主题，而它跟系统走；主应用可能是深色、卡片却是浅色，
   * 结果就是「深色块贴在白底上」。所以统一按 payload 的 darkMode 给纯色，保证卡片
   * 和应用永远一致。
   */
  private bg(): string {
    return this.darkMode === '1' ? '#2F3034' : '#FFFFFF';
  }

  private tPri(): string {
    return this.darkMode === '1' ? '#E6E6E6' : '#1A1A1A';
  }

  private tSec(): string {
    return this.darkMode === '1' ? '#8C8C8C' : '#6B6B6B';
  }

  private tTer(): string {
    return this.darkMode === '1' ? '#6E6E6E' : '#9A9A9A';
  }

  private line(): string {
    return this.darkMode === '1' ? '#3B3C40' : '#E6E6E6';
  }


  /**
   * 课块上的文字色 —— **按底色亮度自动选黑/白**。
   *
   * 上游给的课块颜色深浅不一，固定白字在浅色块上完全看不清（用户实机反馈）。
   * 卡片里不能调任何系统 API，所以纯字符串解析 + WCAG 相对亮度公式。
   */
  private textColorOn(slot: DayViewSlot): string {
    if (this.darkMode === '1') {
      // 深色：块色混白（与课表页 / 功能页同款），不再是统一暖白
      return this.blendOn('#FFFFFF', this.colorOf(slot), DARK_TEXT_TINT_D);
    }
    return LIGHT_TEXT_D[this.slotIndexOf(slot)];
  }

  private textColorOnLegacy(slot: DayViewSlot): string {
    const hex: string = this.colorOf(slot);
    const lum: number = (0.299 * this.channelOf(hex, 0) + 0.587 * this.channelOf(hex, 1) +
      0.114 * this.channelOf(hex, 2)) / 255;
    return lum > 0.5 ? '#1A1A1A' : '#FFFFFF';
  }

  /** 次要文字（地点）色：浅色下 = 主文字 75%（跟随课程名颜色）。 */
  private subTextColorOn(slot: DayViewSlot): string {
    if (this.darkMode === '1') {
      // 教室行同款混白，但比课程名淡一档（比例取 70%）
      return this.blendOn('#FFFFFF', this.colorOf(slot), DARK_TEXT_TINT_D * 0.7);
    }
    return '#BF' + this.textColorOn(slot).substring(1);
  }

  /** 取 `#RRGGBB` 里第 index 个通道（0=红 1=绿 2=蓝）；解析失败返回 0。 */
  private channelOf(hex: string, index: number): number {
    const start: number = 1 + index * 2;
    if (hex.length < start + 2) {
      return 0;
    }
    const v: number = parseInt(hex.substring(start, start + 2), 16);
    return isNaN(v) ? 0 : v;
  }

  @Builder
  emptyView() {
    Column({ space: 6 }) {
      Text('日课表')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.card_accent'))
      Text('打开 App 获取课表')
        .fontSize(12)
        .fontColor(this.tSec())
      Text(this.updatedAt.length > 0 ? '更新于 ' + this.updatedAt : '')
        .fontSize(9)
        .fontColor(this.tTer())
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 一节课：整条圆角色块，左边课名 + 地点，右边起止时间两行。
   *
   * 高度用 `layoutWeight(span)` 均分 —— 跨节课更高，两张尺寸都自动适配。
   */
  /** 同时段多门课合并出来的块（文案形如 `2节课`）。 */
  private isMergedSlot(slot: DayViewSlot): boolean {
    return slot.courseName.endsWith('节课');
  }

  /**
   * 一天有三节及以上课时是否把教室挪到课程名右侧。
   *
   * 2×4 卡约 150vp 高，顶部两行标题吃掉约一半后，每节课只剩约 20vp。
   * 此时课程名（13fp）在上、地点（10fp）在下会上下压到一起（实机看到重叠）。
   * 三节及以上时改成同行：课程名在左占 layoutWeight，教室贴右，二者不再叠。
   * 两节及以下块更高，维持原来的「课名上 / 教室下」版式（信息更舒展）。
   */
  private placeBesideName(): boolean {
    return (this.view?.slots?.length ?? 0) >= 3;
  }

  @Builder
  courseCard(slot: DayViewSlot, span: number) {
    if (this.isMergedSlot(slot)) {
      // 同时段多节课：块里只放这一行字，**上下左右都居中**（时间也一并省掉，
      // 否则文字被时间挤到左侧，不在正中）
      Column() {
        Text(slot.courseName)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.textColorOn(slot))
          .maxLines(1)
          .width('100%')
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .layoutWeight(span)
      .margin({ top: 2, bottom: 2 })
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .borderRadius(12)
      .backgroundColor(this.colorOf(slot))
      .clip(true)
    } else {
      Row() {
        if (this.placeBesideName()) {
          // 三节及以上（块矮）：课程名在左、教室在同一行右侧，避免上下两行压到一起。
          // 教室此时**不受 span>1 限制** —— 用户明确要三节课时也看到教室。
          Row({ space: 4 }) {
            Text(slot.courseName)
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.textColorOn(slot))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            if (slot.place.length > 0) {
              Text(slot.place)
                .fontSize(10)
                .fontColor(this.subTextColorOn(slot))
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .constraintSize({ maxWidth: 60 })
            }
          }
          .layoutWeight(1)
          .alignItems(VerticalAlign.Center)
        } else {
          Column({ space: 2 }) {
            // 两节及以下（块高）：照抄 App 内课表页，课程名撑满、地点贴底
            Text(slot.courseName)
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.textColorOn(slot))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .layoutWeight(1)
              .align(Alignment.TopStart)
            // 地点只在跨节课上显示：单节行高最小，塞地点会被裁成半行。
            if (slot.place.length > 0 && span > 1) {
              Text(slot.place)
                .fontSize(10)
                .fontColor(this.subTextColorOn(slot))
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .align(Alignment.BottomStart)
            }
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }

        /**
         * 右侧起止时间：**单行**。
         *
         * 原来按官方样式分上下两行，但 2×4 卡片只有约 150vp 高，顶部两行标题吃掉一半后，
         * 每节课只剩 20vp —— 两行 12fp 文字放不下，被 clip 裁成半行，
         * 实机上就是三节课糊成一团。单行 11fp 刚好放得下。
         */
        Text(slot.time)
          .fontSize(11)
          .fontColor(this.textColorOn(slot))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: 78 })
          .textAlign(TextAlign.End)
        .margin({ left: 6 })
    }
    .width('100%')
    .layoutWeight(span)
    // 块间距：上下各 2vp，相邻两块之间留一道细缝
    .margin({ top: 2, bottom: 2 })
    .padding({ left: 8, right: 8, top: 3, bottom: 3 })
    .alignItems(VerticalAlign.Center)
    .borderRadius(12)
    .backgroundColor(this.colorOf(slot))
    // 矮卡片（2×4）上文字会被裁半行 —— 圆角 + 裁切让溢出部分干脆不可见，
    // 而不是像实机截图那样「J3-212 / 14:00 各切掉下半行」。
    .clip(true)
    }
  }

  build() {
    Column() {
      if (this.view === null) {
        this.emptyView()
      } else {
        // 顶部：左日期 + 星期（橙），右「第 N 周」
        // ⚠️ headline **必须给 layoutWeight** —— 不给的话它会按内容宽度
        // 把右边的「第 N 周」挤到贴在一起（实机挤成「周一 · 10/05第 5 周」）。
        Row() {
          Text(this.view?.headline ?? '')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.card_accent'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.view?.weekLabel ?? '')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.tPri())
            .maxLines(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ bottom: 4 })

        if ((this.view?.slots?.length ?? 0) === 0) {
          // 今天真的没课 —— 一句说明，别让上半张卡空着
          Text('今日无课程')
            .fontSize(14)
            .fontColor(this.tSec())
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 10, bottom: 10 })
        }

        // 分组标题：`明天 ③` 这种（官方写法）
        Row({ space: 6 }) {
          Text(this.view?.dayLabel ?? '今天')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.tPri())
          // 2026-11-23：按用户要求数字后补单位「节课」（如「今天 3 节课」）
          Text((this.view?.dayCount ?? 0).toString() + ' 节课')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.card_accent'))
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ bottom: 4 })

        // 课程列表
        Column({ space: 3 }) {
          ForEach(this.view?.slots ?? [], (slot: DayViewSlot) => {
            this.courseCard(slot, this.spanOf(slot))
          }, (slot: DayViewSlot) =>
            // key 带 begin + 全身份：同一天可能有**同名同色**的两门实验班
            'd' + slot.begin + '-' + slot.end + '-' + slot.courseName + '-' + slot.place)
        }
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(this.bg())
    .onClick(() => {
      this.openApp();
    })
  }
}