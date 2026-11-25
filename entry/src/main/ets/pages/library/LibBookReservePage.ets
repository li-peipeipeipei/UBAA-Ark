import { LoadState } from '../../common/AppRouter';
import { Logger } from '../../common/Logger';
import { Toast } from '../../common/Toast';
import { AppColor, AppFont, AppSize } from '../../components/AppTheme';
import { ChipsEdgeFade } from '../../components/ChipsEdgeFade';
import { topSafeInsetVp } from '../../common/ImmersiveUtil';
import curves from '@ohos.curves';
import { EmptyView, ErrorView, LoadingView } from '../../components/CommonViews';
import {
  BykcLibBookArea,
  BykcLibBookLibrary,
  BykcLibBookSeat,
  BykcLibBookStorey
} from '../../model/ApiTypes';
import { LibBookSlot, LocalLibBookService } from '../../network/LocalLibBookService';
import { columnsByMinWidth, templateOfColumns } from '../../common/Breakpoint';
import { PageCache } from '../../common/PageCache';
import { OfflineKey } from '../../common/OfflineCache';

/**
 * 楼馆级联首帧缓存内容。
 *
 * 只缓存楼馆列表 + 上次的选择项（楼馆 / 楼层 / 分区 / 座位 / 日期）。
 * areas / seats / slots 强时效，不缓存；交互态（loading / submitting / showAllSeats）也不缓存。
 * 注意 loadLibraries 的自动选楼/层本来就「选择项在列表里仍存在就保留，否则取第一个」，
 * 因此 restore 后已有选择项会被自然保留，无需改动自动选择逻辑。
 */
interface LibReserveCache {
  libraries: BykcLibBookLibrary[];
  selectedLibraryId: string;
  selectedStoreyId: string;
  selectedAreaId: string;
  selectedSeatId: string;
  selectedDay: string;
}

/** 胶囊行高度（vp）：`Scroll` 与两侧渐隐遮罩共用同一个值，避免两处各写一个数。 */
const CHIP_ROW_H: number = 38;

/**
 * 座位块的**最小宽度**（vp）。
 *
 * 取值依据：手机内容宽 344vp 排 4 列时每块 80vp（(344 − 3×8) / 4），块内要放得下
 * 「A-01」这种 4 字符座位号（12fp）—— 取 76 留一点余量。平板据此自动增列
 * （lg 内容宽 917vp → 10 列，到达上限），不再固定 4 列把小块拉成大方块。
 */
const SEAT_MIN_WIDTH: number = 76;
/** 座位网格列间距（vp）。 */
const SEAT_GAP: number = 8;

/**
 * 图书馆座位 · 预约座位（对齐原版 `LibBookReserveScreen.kt`）。
 *
 * 版式：**楼馆 / 楼层 / 分区** 三行横向 chip（各自带「剩余/总数」），
 * 下面是座位网格（每行 4 个），底部是预约信息 + 「确认预约」按钮。
 *
 * ## 加载链（照抄原版，是 5 步不是 4 步）
 *
 * ```
 * loadLibraries          楼馆（楼层嵌在楼馆的 storeys 里，不用单独请求）
 *   → loadAreas          分区（按楼馆 + 楼层 + 日期）
 *     → loadAreaDetail   分区详情（一次性带回可预约日期 + 时段）
 *       → loadSeats      座位（必须带 day + 时段的起止时间）
 * ```
 *
 * **自动选中策略**贯穿全程：优先保留用户已有选择（若在新数据里仍存在），
 * 否则取列表第一个。日期与时段**不给用户选**，自动取上游数组第一个
 * （与原版一致 —— 原版的 `selectSlot` 是死代码，UI 从不调用）。
 */
@Component
export struct LibBookReservePage {
  @State private loadState: LoadState = LoadState.LOADING;
  @State private errorMessage: string = '';
  @State private libraries: BykcLibBookLibrary[] = [];
  @State private areas: BykcLibBookArea[] = [];
  @State private seats: BykcLibBookSeat[] = [];
  @State private slots: LibBookSlot[] = [];
  @State private selectedLibraryId: string = '';
  @State private selectedStoreyId: string = '';
  @State private selectedAreaId: string = '';
  @State private selectedSeatId: string = '';
  @State private selectedDay: string = '';
  @State private areasLoading: boolean = false;
  @State private seatsLoading: boolean = false;
  @State private submitting: boolean = false;
  @State private showAllSeats: boolean = false;
  /**
   * 座位网格列数（按容器实测宽度算）。
   *
   * 手机 4 列是基准（与原版一致），平板按 `SEAT_MIN_WIDTH` 自动增列。
   * 只在列数**变了**才写状态：`onAreaChange` 在滚动/高度变化时会连续回调，
   * 每次都写会让 Grid 反复重排（肉眼可见的抖动）。
   */
  @State private seatColumns: number = 4;
  /**
   * 胶囊行实测高度（vp）：三行胶囊的渐隐遮罩共用。
   *
   * 对齐 SPOC：`overlay` 里的高度不能用固定常量或 `height('100%')`
   * （后者会被解析成整页高，把下方卡片的左右边缘一起压暗）。
   * 由宿主 `Scroll` 的 `onAreaChange` 实测上报，首帧用 CHIP_ROW_H 兜底。
   */
  @State private chipsRowH: number = CHIP_ROW_H;

  aboutToAppear(): void {
    // 冷启动首帧：同步读上次缓存，把楼馆与上次选择项填回去。
    // 只在 aboutToAppear 恢复一次——loadLibraries 会被「刷新 / 重试」反复调用，
    // 若在那里读缓存会把用户当前选择重置成旧值。
    const cached: LibReserveCache | null = PageCache.load<LibReserveCache>(
      OfflineKey.LIB_RESERVE, PageCache.TTL_SHORT);
    if (cached !== null && cached.libraries.length > 0) {
      this.libraries = cached.libraries;
      this.selectedLibraryId = cached.selectedLibraryId;
      this.selectedStoreyId = cached.selectedStoreyId;
      this.selectedAreaId = cached.selectedAreaId;
      this.selectedSeatId = cached.selectedSeatId;
      this.selectedDay = cached.selectedDay;
      this.loadState = LoadState.SUCCESS;
    }
    // 缓存里没有有效日期（首次进入 / 老缓存）时仍按「今天」查询
    if (this.selectedDay.length === 0) {
      this.selectedDay = LocalLibBookService.today();
    }
    this.loadLibraries();
  }

  /* ------------------------------ 数据加载 ------------------------------ */

  private async loadLibraries(): Promise<void> {
    // 缓存命中时 aboutToAppear 已把 loadState 置为 SUCCESS，这里不再切 LOADING，
    // 首帧保留缓存内容；后台拉新回来后无缝覆盖。
    if (this.loadState !== LoadState.SUCCESS) {
      this.loadState = LoadState.LOADING;
    }
    try {
      const list = await LocalLibBookService.fetchLibraries(this.selectedDay);
      this.libraries = list;
      // 自动选楼馆
      let libId: string = this.selectedLibraryId;
      let found: boolean = false;
      for (let i = 0; i < list.length; i++) {
        if (list[i].id === libId) {
          found = true;
          break;
        }
      }
      if (!found) {
        libId = list.length > 0 ? list[0].id : '';
        this.selectedLibraryId = libId;
      }
      // 自动选楼层（楼层嵌在楼馆里）
      let storeyId: string = this.selectedStoreyId;
      let storeyFound: boolean = false;
      for (let i = 0; i < list.length; i++) {
        if (list[i].id !== libId) {
          continue;
        }
        for (let j = 0; j < list[i].storeys.length; j++) {
          if (list[i].storeys[j].id === storeyId) {
            storeyFound = true;
            break;
          }
        }
        if (!storeyFound && list[i].storeys.length > 0) {
          storeyId = list[i].storeys[0].id;
          this.selectedStoreyId = storeyId;
        }
        break;
      }
      this.loadState = LoadState.SUCCESS;
      // 拉新成功写回缓存（在任何会重置选择项的 loadAreas 之前保存当前选择）
      PageCache.save(OfflineKey.LIB_RESERVE, {
        libraries: this.libraries,
        selectedLibraryId: this.selectedLibraryId,
        selectedStoreyId: this.selectedStoreyId,
        selectedAreaId: this.selectedAreaId,
        selectedSeatId: this.selectedSeatId,
        selectedDay: this.selectedDay
      } as LibReserveCache);
      if (libId.length > 0) {
        this.loadAreas();
      }
    } catch (error) {
      this.errorMessage = '加载楼馆失败：' + (error as Error).message;
      // 缓存命中过时失败不切 ERROR，保留已渲染的本地内容
      if (this.loadState !== LoadState.SUCCESS) {
        this.loadState = LoadState.ERROR;
      }
      Logger.error('图书馆楼馆加载失败：' + (error as Error).message);
    }
  }

  private async loadAreas(): Promise<void> {
    // 级联请求必须记住「发起时的选择」：连点两个楼馆时，先发的慢响应后到会覆盖新结果，
    // 变成「选的是 B 楼，列表/座位却是 A 楼的」—— 最后提交预约会把 B 的 id 和 A 的
    // areaId 拼在一起，约到错误的座位。
    const libId: string = this.selectedLibraryId;
    const storeyId: string = this.selectedStoreyId;
    const day: string = this.selectedDay;
    this.areasLoading = true;
    this.areas = [];
    this.seats = [];
    this.selectedAreaId = '';
    this.selectedSeatId = '';
    try {
      const list = await LocalLibBookService.fetchAreas(libId, storeyId, day);
      if (libId !== this.selectedLibraryId || storeyId !== this.selectedStoreyId ||
        day !== this.selectedDay) {
        return; // 已被更新的选择取代，整份丢弃
      }
      this.areas = list;
      if (list.length > 0) {
        this.selectedAreaId = list[0].id;
        this.loadAreaDetailAndSeats();
      }
    } catch (error) {
      Logger.warn('图书馆分区加载失败：' + (error as Error).message);
    } finally {
      if (libId === this.selectedLibraryId && storeyId === this.selectedStoreyId) {
        this.areasLoading = false;
      }
    }
  }

  private async loadAreaDetailAndSeats(): Promise<void> {
    const areaId: string = this.selectedAreaId;
    this.seatsLoading = true;
    this.seats = [];
    this.slots = [];
    this.selectedSeatId = '';
    try {
      const detail = await LocalLibBookService.fetchAreaDetail(areaId);
      if (areaId !== this.selectedAreaId) {
        return; // 分区已切走，这份详情属于别的分区
      }
      // 自动取第一个可预约日期
      if (detail.dates.length > 0) {
        this.selectedDay = detail.dates[0];
      }
      this.slots = detail.slots;
      if (detail.slots.length === 0) {
        this.seatsLoading = false;
        return;
      }
      await this.loadSeats();
    } catch (error) {
      Logger.warn('图书馆分区详情加载失败：' + (error as Error).message);
    } finally {
      if (areaId === this.selectedAreaId) {
        this.seatsLoading = false;
      }
    }
  }

  private async loadSeats(): Promise<void> {
    if (this.slots.length === 0) {
      return;
    }
    const areaId: string = this.selectedAreaId;
    const day: string = this.selectedDay;
    const slot: LibBookSlot = this.slots[0];
    this.seatsLoading = true;
    try {
      const list = await LocalLibBookService.fetchSeats(areaId, day, slot.start, slot.end);
      if (areaId !== this.selectedAreaId || day !== this.selectedDay) {
        return;
      }
      this.seats = list;
    } catch (error) {
      Logger.warn('图书馆座位加载失败：' + (error as Error).message);
    } finally {
      if (areaId === this.selectedAreaId) {
        this.seatsLoading = false;
      }
    }
  }

  /* ------------------------------ 选择动作 ------------------------------ */

  private selectLibrary(id: string): void {
    if (this.selectedLibraryId === id) {
      return;
    }
    this.selectedLibraryId = id;
    // 楼层重置
    for (let i = 0; i < this.libraries.length; i++) {
      if (this.libraries[i].id === id && this.libraries[i].storeys.length > 0) {
        this.selectedStoreyId = this.libraries[i].storeys[0].id;
        break;
      }
    }
    this.loadAreas();
  }

  private selectStorey(id: string): void {
    if (this.selectedStoreyId === id) {
      return;
    }
    this.selectedStoreyId = id;
    this.loadAreas();
  }

  private selectArea(id: string): void {
    if (this.selectedAreaId === id) {
      return;
    }
    this.selectedAreaId = id;
    this.loadAreaDetailAndSeats();
  }

  private selectSeat(seat: BykcLibBookSeat): void {
    if (!seat.isAvailable) {
      Toast.show('该座位当前不可预约');
      return;
    }
    // 再点一次同一个座位 = 取消选择
    this.selectedSeatId = this.selectedSeatId === seat.id ? '' : seat.id;
  }

  /* ------------------------------ 写操作 ------------------------------ */

  private async submitReservation(): Promise<void> {
    if (this.submitting) {
      return;
    }
    if (this.selectedAreaId.length === 0) {
      Toast.show('请先选择分区');
      return;
    }
    if (this.selectedSeatId.length === 0) {
      Toast.show('请先选择可预约座位');
      return;
    }
    if (this.slots.length === 0) {
      Toast.show('请先选择预约时段');
      return;
    }
    this.submitting = true;
    try {
      const message: string = await LocalLibBookService.reserve(
        this.selectedAreaId, this.selectedSeatId, this.selectedDay, this.slots[0]);
      Toast.show(message);
      this.selectedSeatId = '';
      // 预约成功后刷新座位与记录
      await this.loadSeats();
    } catch (error) {
      Toast.show('预约失败：' + (error as Error).message);
      Logger.warn('图书馆预约失败：' + (error as Error).message);
    } finally {
      this.submitting = false;
    }
  }

  /* ------------------------------ 派生数据 ------------------------------ */

  private currentLibrary(): BykcLibBookLibrary | null {
    for (let i = 0; i < this.libraries.length; i++) {
      if (this.libraries[i].id === this.selectedLibraryId) {
        return this.libraries[i];
      }
    }
    return null;
  }

  private currentStoreys(): BykcLibBookStorey[] {
    const lib = this.currentLibrary();
    return lib === null ? [] : lib.storeys;
  }

  private currentArea(): BykcLibBookArea | null {
    for (let i = 0; i < this.areas.length; i++) {
      if (this.areas[i].id === this.selectedAreaId) {
        return this.areas[i];
      }
    }
    return null;
  }

  private currentSeat(): BykcLibBookSeat | null {
    for (let i = 0; i < this.seats.length; i++) {
      if (this.seats[i].id === this.selectedSeatId) {
        return this.seats[i];
      }
    }
    return null;
  }

  /** 可预约的座位（网格只显示这些 —— 与原版 `visibleLibBookSeats` 一致）。 */
  private visibleSeats(): BykcLibBookSeat[] {
    if (this.showAllSeats) {
      return this.seats;
    }
    const out: BykcLibBookSeat[] = [];
    for (let i = 0; i < this.seats.length; i++) {
      if (this.seats[i].isAvailable) {
        out.push(this.seats[i]);
      }
    }
    return out;
  }

  /* ------------------------------ 界面 ------------------------------ */

  /**
   * 一行横向 chip（楼馆 / 楼层 / 分区三处用同一套外观）。
   *
   * ⚠️ **拆成三个专用 Builder 而不用泛型** —— ArkUI 的 `@Builder` **不支持泛型参数**
   * （`<T>` 会在运行期炸掉，表现为进页面直接白屏/闪退）。
   * 三处 chip 的元素类型不同（楼馆 / 楼层 / 分区），只能各写一份。
   *
   * ⚠️ **横滑能生效，关键是内容 Row 不能设 `.width('100%')`**。
   * 先后踩过：
   *   - `Row.width('100%')` → 内容被压成容器宽，**没有溢出量就没得滑**（滑不动）；
   *   - `List` + `listDirection(Axis.Horizontal)` → `List` 嵌在 `Scroll` 里
   *     **直接白屏崩溃**（进程消失，且没有 JS 日志）。
   * 正解参照 `ScheduleWeekChips`（课表页周次条）：`Scroll` +
   * `.scrollable(ScrollDirection.Horizontal)`，内容 `Row` **只设 padding 不设宽度**。
   */
  /**
   * 胶囊行两侧的渐隐遮罩（与 SPOC 页同一套 `ChipsEdgeFade` + 实测行高）。
   */
  @Builder
  chipsEdgeFade() {
    // ⚠️ `hitTestBehavior` 必须**同时**在调用处再设一遍（与 SPOC 页同一套）：
    // 自定义组件节点自己也是一层参与触摸测试的节点，只在组件内部给根容器设 None 时，
    // 组件节点仍会吃掉整条胶囊行的点击（表现为「胶囊点不动、只能滑」）。
    ChipsEdgeFade({ fadeHeight: this.chipsRowH })
      .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  libraryChips() {
    Scroll() {
      Row({ space: 6 }) {
        ForEach(this.libraries, (item: BykcLibBookLibrary) => {
          Text(item.name + ' ' + item.freeNum.toString() + '/' + item.totalNum.toString())
            .fontSize(AppFont.caption)
            .fontColor(item.id === this.selectedLibraryId ? AppColor.brand : AppColor.textSecondary)
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .borderRadius(16)
            .backgroundColor(item.id === this.selectedLibraryId ?
              AppColor.brandContainer : AppColor.surfaceSubtle)
            // 选中 / 取消的底色与文字色做弹簧过渡（底部两个胶囊行同款）
            .animation({ curve: curves.responsiveSpringMotion(0.25, 0.7) })
            .maxLines(1)
            .onClick(() => {
              this.selectLibrary(item.id);
            })
        }, (item: BykcLibBookLibrary) => item.id)
      }
      // ⚠️ **内容 Row 绝不能设 `.width('100%')`** —— 那会把内容压成容器宽，
      // 没有溢出量就没有可滚区域。参照 `ScheduleWeekChips`（课表周次条）的写法。
      // 默认缩进放在滚动内容里（对齐 SPOC）：静止时首尾胶囊与下方标题对齐，
      // 滑动时留白跟着滚走，胶囊能真正贴到屏幕边缘
      .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
    }
    .scrollBar(BarState.Off)
    .scrollable(ScrollDirection.Horizontal)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .width('100%')
    .height(CHIP_ROW_H)
    // 胶囊整体居中（六处胶囊行统一要求）
    .align(Alignment.Center)
    .clip(false)
    // 遮罩高度由行高实测上报（对齐 SPOC，不用固定常量）
    .onAreaChange((_old: Area, now: Area) => {
      const height: number = Number(now.height);
      if (height > 0 && Math.abs(height - this.chipsRowH) > 0.5) {
        this.chipsRowH = height;
      }
    })
    .overlay(this.chipsEdgeFade(), { align: Alignment.Center })
  }

  @Builder
  storeyChips() {
    Scroll() {
      Row({ space: 6 }) {
        ForEach(this.currentStoreys(), (item: BykcLibBookStorey) => {
          Text(item.name + ' ' + item.freeNum.toString() + '/' + item.totalNum.toString())
            .fontSize(AppFont.caption)
            .fontColor(item.id === this.selectedStoreyId ? AppColor.brand : AppColor.textSecondary)
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .borderRadius(16)
            .backgroundColor(item.id === this.selectedStoreyId ?
              AppColor.brandContainer : AppColor.surfaceSubtle)
            .animation({ curve: curves.responsiveSpringMotion(0.25, 0.7) })
            .maxLines(1)
            .onClick(() => {
              this.selectStorey(item.id);
            })
        }, (item: BykcLibBookStorey) => item.id)
      }
      // 内容 Row 不设 width('100%')（否则压成容器宽，没得滑）—— 见 libraryChips 注释
      .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
    }
    .scrollBar(BarState.Off)
    .scrollable(ScrollDirection.Horizontal)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .width('100%')
    .height(CHIP_ROW_H)
    // 胶囊整体居中（六处胶囊行统一要求）
    .align(Alignment.Center)
    .clip(false)
    // 遮罩高度由行高实测上报（对齐 SPOC，不用固定常量）
    .onAreaChange((_old: Area, now: Area) => {
      const height: number = Number(now.height);
      if (height > 0 && Math.abs(height - this.chipsRowH) > 0.5) {
        this.chipsRowH = height;
      }
    })
    .overlay(this.chipsEdgeFade(), { align: Alignment.Center })
  }

  @Builder
  areaChips() {
    Scroll() {
      Row({ space: 6 }) {
        ForEach(this.areas, (item: BykcLibBookArea) => {
          Text(item.name + ' ' + item.freeNum.toString() + '/' + item.totalNum.toString())
            .fontSize(AppFont.caption)
            .fontColor(item.id === this.selectedAreaId ? AppColor.brand : AppColor.textSecondary)
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .borderRadius(16)
            .backgroundColor(item.id === this.selectedAreaId ?
              AppColor.brandContainer : AppColor.surfaceSubtle)
            .animation({ curve: curves.responsiveSpringMotion(0.25, 0.7) })
            .maxLines(1)
            .onClick(() => {
              this.selectArea(item.id);
            })
        }, (item: BykcLibBookArea) => item.id)
      }
      // 内容 Row 不设 width('100%')（否则压成容器宽，没得滑）—— 见 libraryChips 注释
      .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
    }
    .scrollBar(BarState.Off)
    .scrollable(ScrollDirection.Horizontal)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .width('100%')
    .height(CHIP_ROW_H)
    // 胶囊整体居中（六处胶囊行统一要求）
    .align(Alignment.Center)
    .clip(false)
    // 遮罩高度由行高实测上报（对齐 SPOC，不用固定常量）
    .onAreaChange((_old: Area, now: Area) => {
      const height: number = Number(now.height);
      if (height > 0 && Math.abs(height - this.chipsRowH) > 0.5) {
        this.chipsRowH = height;
      }
    })
    .overlay(this.chipsEdgeFade(), { align: Alignment.Center })
  }

  @Builder
  sectionTitle(title: string, trailing?: string) {
    Row() {
      Text(title)
        .fontSize(AppFont.body)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.textPrimary)
        .layoutWeight(1)
      if (trailing !== undefined) {
        Text(trailing)
          .fontSize(AppFont.caption)
          .fontColor(AppColor.brand)
          .onClick(() => {
            this.loadLibraries();
          })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    // 父级为胶囊行做了全出血（无左右 padding），标题自行缩进
    .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
  }

  @Builder
  seatCard(seat: BykcLibBookSeat) {
    Column({ space: 4 }) {
      Text(seat.no.length > 0 ? seat.no : (seat.name.length > 0 ? seat.name : seat.id))
        .fontSize(AppFont.caption)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Center)
      Text(this.selectedSeatId === seat.id ? '已选' : (seat.isAvailable ? '可预约' : '不可预约'))
        .fontSize(10)
        .fontColor(this.selectedSeatId === seat.id ? AppColor.brand : AppColor.textTertiary)
        .maxLines(1)
    }
    .width('100%')
    .height(64)
    .padding(8)
    .borderRadius(8)
    .backgroundColor(this.selectedSeatId === seat.id ? AppColor.brandContainer : AppColor.surfaceSubtle)
    .onClick(() => {
      this.selectSeat(seat);
    })
  }

  build() {
    Scroll() {
      Column({ space: AppSize.gapSmall }) {
        if (this.loadState === LoadState.LOADING) {
          Column() {
            LoadingView({ message: '正在加载图书馆楼馆…' })
          }
          .width('100%')
          .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
        } else if (this.loadState === LoadState.ERROR) {
          Column() {
            ErrorView({
              message: this.errorMessage,
              onRetry: () => {
                this.loadLibraries();
              }
            })
          }
          .width('100%')
          .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
        } else {
          // 楼馆
          this.sectionTitle('楼馆', '刷新')
          this.libraryChips()

          // 楼层（仅当选中的楼馆有楼层时才显示）
          if (this.currentStoreys().length > 0) {
            this.sectionTitle('楼层')
            this.storeyChips()
          }

          // 分区
          this.sectionTitle('分区')
          if (this.areasLoading) {
            Text('正在加载分区…')
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textTertiary)
              .width('100%')
              .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
          } else if (this.areas.length === 0) {
            Text('当前楼层暂无可预约分区')
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textTertiary)
              .width('100%')
              .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
          } else {
            this.areaChips()
          }

          // 座位
          Row() {
            Text('座位')
              .fontSize(AppFont.body)
              .fontWeight(FontWeight.Medium)
              .fontColor(AppColor.textPrimary)
              .layoutWeight(1)
            Text(this.showAllSeats ? '只看可预约' : '看全部座位')
              .fontSize(AppFont.caption)
              .fontColor(AppColor.brand)
              .onClick(() => {
                this.showAllSeats = !this.showAllSeats;
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })

          if (this.seatsLoading) {
            Text('正在加载座位…')
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textTertiary)
              .width('100%')
              .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
          } else if (this.seats.length === 0) {
            Text('当前分区暂无座位数据')
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textTertiary)
              .width('100%')
              .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
          } else if (this.visibleSeats().length === 0) {
            Text('当前分区暂无可预约座位')
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textTertiary)
              .width('100%')
              .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
          } else {
            // 父级为胶囊行做了全出血（无左右 padding），这里自行缩进。
            // ⚠️ 缩进包在 Grid 外的 Column 上，不能加在 Grid 自身 ——
            // Grid 的 onAreaChange 量的是自身宽度，用来反推列数，必须保持「内容宽」。
            Column() {
              // 座位网格：手机 4 列，平板按最小块宽自适应增列（见 SEAT_MIN_WIDTH）
              //
              // ⚠️ **必须用 `Grid` 而不是 `Flex` + `layoutWeight`** ——
              // `layoutWeight` 只在 `Row`/`Column` 里生效，`Flex` 里设了也没用
              // （实测每行只排下一个座位，卡片被拉成整行宽）。
              Grid() {
                ForEach(this.visibleSeats(), (seat: BykcLibBookSeat) => {
                  GridItem() {
                    this.seatCard(seat)
                  }
                }, (seat: BykcLibBookSeat) => seat.id)
              }
              .columnsTemplate(templateOfColumns(this.seatColumns))
              .columnsGap(SEAT_GAP)
              .rowsGap(SEAT_GAP)
              .width('100%')
              // 量自身宽度反推列数：不按窗口断点 —— 座位网格的父容器可能带内边距、
              // 将来也可能被放进两栏，只有自身宽度是准的。
              .onAreaChange((_old: Area, now: Area) => {
                const width: number = Number(now.width);
                const next: number = columnsByMinWidth(width, SEAT_MIN_WIDTH, SEAT_GAP, 4, 10);
                if (next !== this.seatColumns) {
                  this.seatColumns = next;
                }
              })
            }
            .width('100%')
            .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
          }

          // 预约信息（父级全出血，本块自行缩进）
          Column() {
            Column({ space: 6 }) {
              Text('预约信息')
                .fontSize(AppFont.body)
                .fontWeight(FontWeight.Medium)
                .fontColor(AppColor.textPrimary)
              Text('日期：' + (this.selectedDay.length > 0 ? this.selectedDay : '-'))
                .fontSize(AppFont.caption)
                .fontColor(AppColor.textSecondary)
                .width('100%')
              Text('分区：' + (this.currentArea() === null ? '-' : this.currentArea()?.name ?? '-'))
                .fontSize(AppFont.caption)
                .fontColor(AppColor.textSecondary)
                .width('100%')
              Text('座位：' + this.seatText())
                .fontSize(AppFont.caption)
                .fontColor(AppColor.textSecondary)
                .width('100%')
              if (this.slots.length > 0) {
                Text('时段：' + this.slots[0].start + ' - ' + this.slots[0].end)
                  .fontSize(AppFont.caption)
                  .fontColor(AppColor.textSecondary)
                  .width('100%')
              }
            }
            .width('100%')
            .padding(AppSize.cardPadding)
            .borderRadius(AppSize.cardRadius)
            .backgroundColor(AppColor.surface)
            .alignItems(HorizontalAlign.Start)

            Button(this.submitting ? '提交中…' : '确认预约')
              .width('100%')
              .height(44)
              .fontSize(AppFont.body)
              .fontColor(AppColor.textOnBrand)
              .backgroundColor(AppColor.brand)
              .enabled(!this.submitting && this.selectedSeatId.length > 0)
              .onClick(() => {
                this.submitReservation();
              })
          }
          .width('100%')
          .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
        }

        Blank()
          .height(AppSize.gapLarge)
      }
      .width('100%')
      // ⚠️ 不能有左右 padding：三行胶囊要做成「0 → 屏幕宽」的全出血，
      // 渐隐遮罩才会落在真正的屏幕边缘（对齐 SPOC，详见 ChipsEdgeFade 文档）。
      // 左右留白已下放到每个子块。
      .padding({
        top: AppSize.destTopInset(topSafeInsetVp()),
        bottom: AppSize.contentBottomInset
      })
      .constraintSize({ minHeight: '100%' })
    }
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .clip(false)
    .expandSafeArea()
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.pageBackground)
  }

  private seatText(): string {
    const seat = this.currentSeat();
    if (seat === null) {
      return '-';
    }
    return seat.no.length > 0 ? seat.no : seat.name;
  }
}
