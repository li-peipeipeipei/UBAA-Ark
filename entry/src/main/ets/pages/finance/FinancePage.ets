import { LoadState } from '../../common/AppRouter';
import { Logger } from '../../common/Logger';
import { ApiError } from '../../network/ApiError';
import { LocalFinanceService } from '../../network/LocalFinanceService';
import { AppColor, AppFont, AppMaterial, AppSize } from '../../components/AppTheme';
import { topSafeInsetVp } from '../../common/ImmersiveUtil';
import {
  ErrorView, InfoRow, LoadingView, SectionCard
} from '../../components/CommonViews';
import { MaterialCardLayer } from '../../components/MaterialCardLayer';
import { immersiveMaterialActive } from '../../common/SystemMaterial';
import { FinanceIncome, FinanceIncomes } from '../../model/ApiTypes';
import { OfflineCache, OfflineKey, offlineNote } from '../../common/OfflineCache';
import { TokenStore } from '../../network/TokenStore';

/**
 * 财务收入查询（对齐上游 UBAA 2.0 的「财务查询」）。
 *
 * 参考上游使用指南 `www.ubaa.top/features/finance`，能力对齐：
 * - 年份筛选（某一年 / 全部）
 * - 顶部合计：**实发合计 + 笔数 + 应发 + 扣税**（随搜索与筛选联动）
 * - 记录按**所属月份分组**，每组标题显示当月实发小计
 * - 搜索「项目 / 摘要」
 * - 点一条记录看明细：应发、扣税、实发、税率、所属年月、录入日期、**流水号**
 * - 下拉刷新
 *
 * 金额一律以「分」存储、按人民币两位小数显示，避免浮点误差。
 */

/** 离线缓存里的财务记录（不能用 Record 承载对象字面量，见 ArkTS 红线）。 */
interface FinanceOffline {
  entries: FinanceIncome[];
}

/** 某一个月的记录分组。 */
interface MonthGroup {
  /** `YYYY-MM`，同时用作 ForEach 的稳定键。 */
  key: string;
  /** 展示用标题，如 `2026年11月`。 */
  label: string;
  /** 当月实发小计（分）。 */
  paidSubtotal: number;
  items: FinanceIncome[];
}

/** 当前筛选范围的合计。 */
interface FinanceSummary {
  count: number;
  /** 应发合计（分）。 */
  amountTotal: number;
  /** 扣税合计（分）。 */
  taxTotal: number;
  /** 实发合计（分）。 */
  paidTotal: number;
}

function emptySummary(): FinanceSummary {
  return { count: 0, amountTotal: 0, taxTotal: 0, paidTotal: 0 } as FinanceSummary;
}

/** 某条记录所属的 `YYYY-MM`；缺字段时退化为 `录入日期` 的前 7 位，再退化为「未标注」。 */
function monthKeyOf(item: FinanceIncome): string {
  const year: string = item.year ?? '';
  const month: string = item.month ?? '';
  if (year.length > 0 && month.length > 0) {
    return year + '-' + (month.length === 1 ? '0' + month : month);
  }
  const recorded: string = item.recordedDate ?? '';
  if (recorded.length >= 7) {
    return recorded.substring(0, 7);
  }
  return '未标注';
}

/** 分 → 「¥1,234.56」；缺值显示占位符。 */
function moneyOf(cents: number | undefined): string {
  if (cents === undefined || cents === null) {
    return '—';
  }
  const negative: boolean = cents < 0;
  const abs: number = Math.abs(cents);
  const whole: number = Math.floor(abs / 100);
  const fraction: number = abs % 100;
  const wholeText: string = whole.toString();
  let grouped: string = '';
  for (let i = 0; i < wholeText.length; i++) {
    const fromEnd: number = wholeText.length - i;
    grouped += wholeText.charAt(i);
    if (fromEnd > 1 && fromEnd % 3 === 1) {
      grouped += ',';
    }
  }
  const fractionText: string = fraction < 10 ? '0' + fraction.toString() : fraction.toString();
  return (negative ? '-¥' : '¥') + grouped + '.' + fractionText;
}

/** 记录明细弹窗（与 SPOC 作业详情同一套版式：自绘标题栏 + 右上角 × 关闭）。 */
@CustomDialog
struct FinanceDetailDialog {
  controller?: CustomDialogController;
  project: string = '';
  description: string = '';
  amountText: string = '';
  taxText: string = '';
  paidText: string = '';
  taxRateText: string = '';
  periodText: string = '';
  recordedText: string = '';
  serialText: string = '';

  /**
   * 沉浸材质是否可用（API ≥ 26、应用级没被 DISABLE、材质构造成功）。
   * 不可用时走兜底玻璃样式 —— 与 `CourseDetailDialog` / `SpocDetailDialog` 同一套。
   */
  private readonly materialActive: boolean = immersiveMaterialActive();

  build() {
    if (this.materialActive) {
      this.immersiveCard();
    } else {
      // API 26 以下的设备取不到系统材质，退回「半透明玻璃底 + 高斯模糊」的手动样式
      this.glassCard();
    }
  }

  /** 沉浸材质卡（API ≥ 26）。 */
  @Builder
  immersiveCard() {
    Stack() {
      MaterialCardLayer({ layerRadius: AppSize.cardRadiusLarge })
      Column() {
        this.cardContent()
      }
      .width('100%')
      .padding(AppSize.cardPadding + 4)
      .alignItems(HorizontalAlign.Start)
    }
    .width('86%')
    .constraintSize({ maxWidth: 400 })
    .borderRadius(AppSize.cardRadiusLarge)
    .backgroundColor(Color.Transparent)
  }

  /** 兜底玻璃卡（API 26 以下设备）：半透明底 + 大半径高斯模糊 + 细描边。 */
  @Builder
  glassCard() {
    Column() {
      this.cardContent()
    }
    .width('86%')
    .constraintSize({ maxWidth: 400 })
    .padding(AppSize.cardPadding + 4)
    .backdropBlur(AppMaterial.blurLarge)
    .backgroundColor(AppColor.glassSurface)
    .border({ width: 0.5, color: AppColor.divider })
    .borderRadius(AppSize.cardRadiusLarge)
    .alignItems(HorizontalAlign.Start)
  }

  /** 标题栏 + 明细行（与课程详情弹窗同一套版式）。 */
  @Builder
  cardContent() {
    Row() {
      Text('收入明细')
        .fontSize(AppFont.title)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.textPrimary)
        .maxLines(1)

      Stack() {
        if (this.materialActive) {
          MaterialCardLayer({ layerRadius: 20, layerShadow: false })
        } else {
          Column()
            .width('100%')
            .height('100%')
            .borderRadius(20)
            .backgroundColor(AppColor.circleButtonSurface)
        }
        Button({ type: ButtonType.Normal, stateEffect: false }) {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(24)
            .fontColor([AppColor.textPrimary])
        }
        .width(40)
        .height(40)
        .borderRadius(20)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          if (this.controller !== undefined) {
            this.controller.close();
          }
        })
      }
      .width(40)
      .height(40)
    }
    .width('100%')
    .justifyContent(FlexAlign.SpaceBetween)
    .alignItems(VerticalAlign.Center)
    .margin({ bottom: 8 })

    Divider()
      .color(AppColor.divider)
      .strokeWidth(0.5)

    Scroll() {
      Column() {
        if (this.project.length > 0) {
          Text(this.project)
            .fontSize(AppFont.subtitle)
            .fontWeight(FontWeight.Medium)
            .fontColor(AppColor.textPrimary)
            .width('100%')
        }
        if (this.description.length > 0) {
          Text(this.description)
            .fontSize(AppFont.body)
            .fontColor(AppColor.textSecondary)
            .width('100%')
            .margin({ top: 6 })
        }
        ForEach(this.rows(), (row: FinanceDetailRow) => {
          Row() {
            Text(row.label)
              .fontSize(AppFont.body)
              .fontColor(AppColor.textSecondary)
              .width(72)
            Text(row.value.length > 0 ? row.value : '—')
              .fontSize(AppFont.body)
              .fontColor(AppColor.textPrimary)
              .layoutWeight(1)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          .padding({ top: 7, bottom: 7 })
        }, (row: FinanceDetailRow) => row.label)
      }
      .width('100%')
    }
    .scrollBar(BarState.Off)
    // 滑动到上限有回弹，内容不满也响应手势（见 CourseDetailDialog 同处注释）
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .constraintSize({ maxHeight: 380 })
    .margin({ top: 4 })
  }

  /** 明细行（与课程详情弹窗的 rows 同构）。 */
  private rows(): FinanceDetailRow[] {
    const out: FinanceDetailRow[] = [];
    out.push({ label: '应发金额', value: this.amountText } as FinanceDetailRow);
    out.push({ label: '扣税', value: this.taxText } as FinanceDetailRow);
    out.push({ label: '实发金额', value: this.paidText } as FinanceDetailRow);
    out.push({ label: '税率', value: this.taxRateText } as FinanceDetailRow);
    out.push({ label: '所属年月', value: this.periodText } as FinanceDetailRow);
    out.push({ label: '录入日期', value: this.recordedText } as FinanceDetailRow);
    out.push({ label: '流水号', value: this.serialText } as FinanceDetailRow);
    return out;
  }
}

/** 明细行（与 `CourseDetailRow` 同构，键用 label）。 */
interface FinanceDetailRow {
  label: string;
  value: string;
}

/** 年份筛选胶囊（独立组件，见 JudgeFilterChip 的说明：带状态的不能用 @Builder 传参）。 */
@Component
struct FinanceYearChip {
  @Prop label: string = '';
  @Prop active: boolean = false;
  onTap: () => void = () => {
  };

  build() {
    Text(this.label)
      .fontSize(AppFont.caption)
      .fontColor(this.active ? Color.White : AppColor.textSecondary)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .backgroundColor(this.active ? AppColor.brand : AppColor.surfaceSubtle)
      .borderRadius(999)
      .onClick(() => {
        this.onTap();
      })
  }
}

@Component
export struct FinancePage {
  @State private loadState: LoadState = LoadState.LOADING;
  @State private errorMessage: string = '';
  /** 上游返回的全量记录（不参与筛选，刷新后整体替换）。 */
  @State private entries: FinanceIncome[] = [];
  /** 搜索关键词（项目 / 摘要）。 */
  @State private query: string = '';
  /** 选中的年份；空串 = 全部。 */
  @State private yearFilter: string = '';
  @State private refreshing: boolean = false;
  /** 离线标注（有值=当前显示的是本机记录）。 */
  @State private offlineNote: string = '';
  /** 详情弹窗（每次点击新建一个，关闭后置空）。 */
  @State private dialogCtrl: CustomDialogController | null = null;

  aboutToAppear(): void {
    // 先渲染本地记录（离线优先），再后台刷新
    this.restoreOffline();
    this.load();
  }

  /** 读本机缓存；有就立刻显示并标注「离线记录」。 */
  private restoreOffline(): void {
    const account: string = TokenStore.getSession().schoolId;
    const cached = OfflineCache.load(OfflineKey.FINANCE, account);
    if (cached === null) {
      return;
    }
    const data = cached as FinanceOffline;
    if (data.entries === undefined || data.entries.length === 0) {
      return;
    }
    this.entries = data.entries;
    this.loadState = LoadState.SUCCESS;
    this.offlineNote = offlineNote(OfflineCache.savedAt(OfflineKey.FINANCE, account));
  }

  private async load(): Promise<void> {
    // 已经有本地内容时不再整页切 loading —— 那会让用户看到「内容→转圈→内容」的跳动
    if (this.loadState !== LoadState.SUCCESS) {
      this.loadState = LoadState.LOADING;
    }
    try {
      const result = await LocalFinanceService.fetchIncomes();
      this.entries = result.entries;
      this.loadState = LoadState.SUCCESS;
      this.offlineNote = '';
      OfflineCache.save(OfflineKey.FINANCE, result, TokenStore.getSession().schoolId);
      Logger.info('财务收入加载完成：' + this.entries.length + ' 条');
    } catch (error) {
      // 有本地记录就保留，只提示；没有才整页报错
      if (this.entries.length > 0) {
        Logger.warn('财务刷新失败，保留本地记录：' + (error as Error).message);
        return;
      }
      this.errorMessage = error instanceof ApiError ?
        (error as ApiError).friendlyMessage() : '财务数据加载失败，请稍后重试';
      this.loadState = LoadState.ERROR;
      Logger.error('财务收入加载失败：' + (error as Error).message);
    }
  }

  /** 下拉刷新：成功保留新数据，失败保留旧数据（与上游「刷新失败时保留上次的记录」一致）。 */
  private async refresh(): Promise<void> {
    try {
      const result = await LocalFinanceService.fetchIncomes();
      this.entries = result.entries;
      Logger.info('财务收入刷新完成：' + this.entries.length + ' 条');
    } catch (error) {
      const message = error instanceof ApiError ?
        (error as ApiError).friendlyMessage() : '刷新失败，请稍后重试';
      Logger.warn('财务收入刷新失败：' + message);
    } finally {
      this.refreshing = false;
    }
  }

  /* ------------------------------ 派生数据 ------------------------------ */

  /**
   * 某条记录所属年份：优先 `year` 字段，缺失时从 `recordedDate` 的前 4 位推。
   *
   * 只按 `year` 判会漏掉那些「有录入日期但没填年份」的记录 —— 选了某一年后它们
   * 会整批消失，用户以为数据丢了。
   */
  private yearOf(item: FinanceIncome): string {
    const year: string = item.year ?? '';
    if (year.length > 0) {
      return year;
    }
    const recorded: string = item.recordedDate ?? '';
    return recorded.length >= 4 ? recorded.substring(0, 4) : '';
  }

  /** 可选年份（倒序，最新在前，用于筛选胶囊）。 */
  private years(): string[] {
    const seen: Map<string, boolean> = new Map<string, boolean>();
    const list: string[] = [];
    for (let i = 0; i < this.entries.length; i++) {
      const year: string = this.yearOf(this.entries[i]);
      if (year.length === 0 || seen.has(year)) {
        continue;
      }
      seen.set(year, true);
      list.push(year);
    }
    // 倒序：最新年份在前（用户最常查最近的）
    list.sort((a: string, b: string): number => {
      return a < b ? 1 : (a > b ? -1 : 0);
    });
    return list;
  }

  /** 当前搜索 + 年份筛选后的记录。 */
  private visible(): FinanceIncome[] {
    const keyword: string = this.query.trim().toLowerCase();
    const list: FinanceIncome[] = [];
    for (let i = 0; i < this.entries.length; i++) {
      const item = this.entries[i];
      if (this.yearFilter.length > 0) {
        const year: string = this.yearOf(item);
        if (year !== this.yearFilter) {
          continue;
        }
      }
      if (keyword.length > 0) {
        const project: string = item.project ?? '';
        const description: string = item.description ?? '';
        const haystack: string = (project + ' ' + description).toLowerCase();
        if (haystack.indexOf(keyword) < 0) {
          continue;
        }
      }
      list.push(item);
    }
    return list;
  }

  private summarize(list: FinanceIncome[]): FinanceSummary {
    const summary = emptySummary();
    summary.count = list.length;
    for (let i = 0; i < list.length; i++) {
      // ⚠️ 必须先落到显式 `number` 局部变量：ArkTS 的三元不收窄 `number | undefined`，
      // 直接 `a += (x === undefined ? 0 : x)` 会报「Type 'string | undefined'…」/「possibly undefined」。
      const amount: number = list[i].amountCents ?? 0;
      const tax: number = list[i].taxCents ?? 0;
      const paid: number = list[i].paidCents ?? 0;
      summary.amountTotal += amount;
      summary.taxTotal += tax;
      summary.paidTotal += paid;
    }
    return summary;
  }

  /** 按所属月份分组，**最新的月份在上**；组内按录入日期倒序。 */
  private groupByMonth(list: FinanceIncome[]): MonthGroup[] {
    const map: Map<string, FinanceIncome[]> = new Map<string, FinanceIncome[]>();
    for (let i = 0; i < list.length; i++) {
      const key: string = monthKeyOf(list[i]);
      const bucket: FinanceIncome[] | undefined = map.get(key);
      if (bucket === undefined) {
        map.set(key, [list[i]] as FinanceIncome[]);
      } else {
        bucket.push(list[i]);
      }
    }
    const keys: string[] = [];
    map.forEach((value: FinanceIncome[], key: string) => {
      keys.push(key);
    });
    // 倒序：`未标注` 排最后（它不是合法年月，用特殊值保证比较稳定）
    keys.sort((a: string, b: string): number => {
      if (a === b) {
        return 0;
      }
      if (a === '未标注') {
        return 1;
      }
      if (b === '未标注') {
        return -1;
      }
      return a < b ? 1 : -1;
    });
    const groups: MonthGroup[] = [];
    for (let i = 0; i < keys.length; i++) {
      const items: FinanceIncome[] | undefined = map.get(keys[i]);
      if (items === undefined) {
        continue;
      }
      items.sort((x: FinanceIncome, y: FinanceIncome): number => {
        const left: string = x.recordedDate ?? '';
        const right: string = y.recordedDate ?? '';
        return left < right ? 1 : (left > right ? -1 : 0);
      });
      let subtotal: number = 0;
      for (let j = 0; j < items.length; j++) {
        const paid: number = items[j].paidCents ?? 0;
        subtotal += paid;
      }
      groups.push({
        key: keys[i],
        label: keys[i] === '未标注' ? '未标注月份' : keys[i].replace('-', '年') + '月',
        paidSubtotal: subtotal,
        items: items
      } as MonthGroup);
    }
    return groups;
  }

  /* ------------------------------ 交互 ------------------------------ */

  private openDetail(item: FinanceIncome): void {
    if (this.dialogCtrl !== null) {
      this.dialogCtrl.close();
      this.dialogCtrl = null;
    }
    const project: string = item.project ?? '';
    const description: string = item.description ?? '';
    const year: string = item.year ?? '';
    const month: string = item.month ?? '';
    const period: string = year.length > 0 && month.length > 0 ?
      year + ' 年 ' + month + ' 月' : (year.length > 0 ? year + ' 年' : '—');
    const rate: string = item.taxRate ?? '';
    const ctrl = new CustomDialogController({
      builder: FinanceDetailDialog({
        project: project,
        description: description,
        amountText: moneyOf(item.amountCents),
        taxText: moneyOf(item.taxCents),
        paidText: moneyOf(item.paidCents),
        taxRateText: rate.length > 0 ? rate + '%' : '—',
        periodText: period,
        recordedText: item.recordedDate === undefined || item.recordedDate.length === 0 ?
          '—' : item.recordedDate,
        serialText: item.id.length > 0 ? item.id : '—'
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      customStyle: true
    });
    this.dialogCtrl = ctrl;
    ctrl.open();
  }

  /** 年月 + 录入日期的合称。 */
  private dateText(item: FinanceIncome): string {
    const key: string = monthKeyOf(item);
    const recorded: string = item.recordedDate ?? '';
    const head: string = key === '未标注' ? '' : key;
    if (recorded.length > 0 && head.length > 0 && head !== recorded) {
      return head + ' · ' + recorded;
    }
    return head.length > 0 ? head : (recorded.length > 0 ? recorded : '—');
  }

  /** 金额优先用实发，缺失时退回总额。 */
  private primaryAmount(item: FinanceIncome): string {
    if (item.paidCents !== undefined && item.paidCents !== null) {
      return moneyOf(item.paidCents);
    }
    return moneyOf(item.amountCents);
  }

  /* ------------------------------ 视图 ------------------------------ */

  @Builder
  summaryCard(summary: FinanceSummary) {
    Column({ space: 8 }) {
      Text('实发合计')
        .fontSize(AppFont.caption)
        .fontColor(AppColor.textSecondary)
        .width('100%')
      Text(moneyOf(summary.paidTotal))
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.accentGreen)
        .width('100%')
      Row() {
        Text(summary.count.toString() + ' 笔')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textSecondary)
        Text('应发 ' + moneyOf(summary.amountTotal))
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textSecondary)
        Text('扣税 ' + moneyOf(summary.taxTotal))
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textSecondary)
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween)
    }
    .width('100%')
    .padding(AppSize.cardPadding)
    .borderRadius(AppSize.cardRadius)
    .backgroundColor(AppColor.surface)
    .alignItems(HorizontalAlign.Start)
  }

  /** 搜索框 + 年份筛选。 */
  @Builder
  filterBar() {
    Column({ space: 10 }) {
      // 双向绑定：单向绑定在每次 onChange 后重绘会让输入光标跳到行首
      TextInput({ text: $$this.query, placeholder: '搜索项目或摘要' })
        .height(40)
        .fontSize(AppFont.body)
        .fontColor(AppColor.textPrimary)
        .backgroundColor(AppColor.surface)
        .borderRadius(12)
        .placeholderColor(AppColor.textTertiary)
        .enterKeyType(EnterKeyType.Search)
        .onChange((value: string) => {
          this.query = value;
        })

      Scroll() {
        Row({ space: 8 }) {
          FinanceYearChip({
            label: '全部',
            active: this.yearFilter.length === 0,
            onTap: () => {
              this.yearFilter = '';
            }
          })
          ForEach(this.years(), (year: string) => {
            FinanceYearChip({
              label: year,
              active: this.yearFilter === year,
              onTap: () => {
                this.yearFilter = this.yearFilter === year ? '' : year;
              }
            })
          }, (year: string) => 'year-' + year)
        }
      }
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .width('100%')
    }
    .width('100%')
  }

  @Builder
  incomeCard(item: FinanceIncome) {
    Column({ space: 5 }) {
      Row() {
        Text(item.project !== undefined && item.project.length > 0 ? item.project : '收入')
          .fontSize(AppFont.subtitle)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.primaryAmount(item))
          .fontSize(AppFont.subtitle)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.accentGreen)
          .margin({ left: 8 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      if (item.description !== undefined && item.description.length > 0) {
        Text(item.description)
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textSecondary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }

      Text(this.dateText(item))
        .fontSize(AppFont.caption)
        .fontColor(AppColor.textTertiary)
        .width('100%')

      // 金额 / 税额 / 税率：有值才显示，避免整行「—」
      if (item.amountCents !== undefined || item.taxCents !== undefined) {
        Row({ space: 12 }) {
          if (item.amountCents !== undefined) {
            Text('金额 ' + moneyOf(item.amountCents))
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textTertiary)
          }
          if (item.taxCents !== undefined) {
            Text('税额 ' + moneyOf(item.taxCents))
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textTertiary)
          }
          if (item.taxRate !== undefined && item.taxRate.length > 0) {
            Text('税率 ' + item.taxRate + '%')
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textTertiary)
          }
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .onClick(() => {
      this.openDetail(item);
    })
  }

  /** 一个月的分组卡片。 */
  @Builder
  monthGroupCard(group: MonthGroup) {
    Column({ space: 0 }) {
      Row() {
        Text(group.label)
          .fontSize(AppFont.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .layoutWeight(1)
        Text('小计 ' + moneyOf(group.paidSubtotal))
          .fontSize(AppFont.caption)
          .fontColor(AppColor.accentGreen)
      }
      .width('100%')
      .padding({ top: 10, bottom: 4 })

      ForEach(group.items, (item: FinanceIncome, index: number) => {
        this.incomeCard(item)
        if (index < group.items.length - 1) {
          Divider().color(AppColor.divider).strokeWidth(0.5)
        }
      }, (item: FinanceIncome, index: number) =>
        // 流水号缺失时 `id` 可能是合成值，仍然唯一；加下标兜底保证键不撞
        item.id.length > 0 ? item.id : 'row-' + index.toString())
    }
    .width('100%')
  }

  build() {
    // 单向绑定：`refreshing` 由本页自己维护（onRefreshing 置 true、refresh 完成复位）。
    // `$$this.x` 双向绑定在本文件里不被编译器接受（同一页签其它文件可用），故用单向。
    Refresh({ refreshing: this.refreshing }) {
      Scroll() {
        Column({ space: AppSize.gapLarge }) {
          if (this.loadState === LoadState.LOADING) {
            LoadingView({ message: '正在查询收入记录…' })
          } else if (this.loadState === LoadState.ERROR) {
            ErrorView({
              message: this.errorMessage,
              onRetry: () => {
                this.load();
              }
            })
          } else {
        if (this.offlineNote.length > 0) {
          Text(this.offlineNote)
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textTertiary)
            .width('100%')
        }
            this.filterBar()

            if (this.visible().length === 0) {
              SectionCard({ title: '收入记录', showAction: false }) {
                Column() {
                  InfoRow({
                    label: '暂无记录',
                    value: this.query.trim().length > 0 || this.yearFilter.length > 0 ?
                      '没有符合当前筛选条件的记录' : '本学期没有可展示的收入',
                    showDivider: false
                  })
                }
                .width('100%')
              }
            } else {
              this.summaryCard(this.summarize(this.visible()))

              ForEach(this.groupByMonth(this.visible()), (group: MonthGroup) => {
                this.monthGroupCard(group)
              }, (group: MonthGroup) => 'group-' + group.key)

              Text('数据来源于学校财务查询系统，仅供本人查阅；如与财务系统不一致，以财务系统为准。到账以银行记录为准。')
                .fontSize(AppFont.caption)
                .fontColor(AppColor.textTertiary)
                .width('100%')
                .padding({ left: 4, right: 4 })
            }
          }

          Blank().height(AppSize.gapLarge)
        }
        .width('100%')
        .padding({
          left: AppSize.pagePadding,
          right: AppSize.pagePadding,
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
    }
    .onRefreshing(() => {
      this.refreshing = true;
      this.refresh();
    })
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.pageBackground)
  }
}
