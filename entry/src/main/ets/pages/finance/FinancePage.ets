import { LoadState } from '../../common/AppRouter';
import { Logger } from '../../common/Logger';
import { ApiError } from '../../network/ApiError';
import { LocalFinanceService } from '../../network/LocalFinanceService';
import { AppColor, AppFont, AppSize } from '../../components/AppTheme';
import { topSafeInsetVp } from '../../common/ImmersiveUtil';
import { ErrorView, InfoRow, LoadingView, SectionCard } from '../../components/CommonViews';
import { FinanceIncome } from '../../model/ApiTypes';

/**
 * 财务收入查询（上游 UBAA 2.0 的「财务收入」功能）。
 *
 * 只读展示：项目名称 / 摘要 / 金额 / 实发 / 税额 / 税率 / 日期 / 年月。
 * 金额存的是「分」，这里统一按人民币两位小数显示。
 *
 * 页面骨架与其它二级页一致：外层 Scroll + 顶部让开 MINI 标题栏 + 底部让开悬浮页签栏，
 * `clip(false)` + `expandSafeArea()` 让内容能滑进标题栏的沉浸光感底板。
 */
@Component
export struct FinancePage {
  @State private loadState: LoadState = LoadState.LOADING;
  @State private errorMessage: string = '';
  @State private entries: FinanceIncome[] = [];

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.loadState = LoadState.LOADING;
    try {
      const result = await LocalFinanceService.fetchIncomes();
      this.entries = result.entries;
      this.loadState = LoadState.SUCCESS;
      Logger.info('财务收入加载完成：' + this.entries.length + ' 条');
    } catch (error) {
      this.errorMessage = error instanceof ApiError ?
        (error as ApiError).friendlyMessage() : '财务数据加载失败，请稍后重试';
      this.loadState = LoadState.ERROR;
      Logger.error('财务收入加载失败：' + (error as Error).message);
    }
  }

  /** 分 → 「¥1,234.56」；缺值显示占位符。 */
  private money(cents: number | undefined): string {
    if (cents === undefined || cents === null) {
      return '—';
    }
    const negative: boolean = cents < 0;
    const abs: number = Math.abs(cents);
    const whole: number = Math.floor(abs / 100);
    const fraction: number = abs % 100;
    let wholeText: string = whole.toString();
    // 千分位
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

  /** 金额优先用实发，缺失时退回总额。 */
  private primaryAmount(item: FinanceIncome): string {
    if (item.paidCents !== undefined && item.paidCents !== null) {
      return this.money(item.paidCents);
    }
    return this.money(item.amountCents);
  }

  /** 年月 + 录入日期的合称。 */
  private dateText(item: FinanceIncome): string {
    const year: string = item.year === undefined ? '' : item.year;
    const month: string = item.month === undefined ? '' : item.month;
    const recorded: string = item.recordedDate === undefined ? '' : item.recordedDate;
    let head: string = '';
    if (year.length > 0 && month.length > 0) {
      head = year + '-' + (month.length === 1 ? '0' + month : month);
    } else if (recorded.length > 0) {
      head = recorded;
    }
    if (recorded.length > 0 && head !== recorded) {
      return head + ' · ' + recorded;
    }
    return head.length > 0 ? head : '—';
  }

  @Builder
  incomeCard(item: FinanceIncome) {
    Column({ space: 6 }) {
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
            Text('金额 ' + this.money(item.amountCents))
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textTertiary)
          }
          if (item.taxCents !== undefined) {
            Text('税额 ' + this.money(item.taxCents))
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
  }

  build() {
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
        } else if (this.entries.length === 0) {
          SectionCard({ title: '收入记录', showAction: false }) {
            Column() {
              InfoRow({ label: '暂无记录', value: '本学期没有可展示的收入', showDivider: false })
            }
            .width('100%')
          }
        } else {
          SectionCard({
            title: '收入记录',
            subtitle: this.entries.length.toString() + ' 条',
            showAction: false
          }) {
            Column() {
              ForEach(this.entries, (item: FinanceIncome, index: number) => {
                this.incomeCard(item)
                if (index < this.entries.length - 1) {
                  Divider().color(AppColor.divider).strokeWidth(0.5)
                }
              }, (item: FinanceIncome, index: number) =>
                // 流水号缺失时 `id` 是空串，多条同时为空就会撞键（ArkUI 对相同键值的
                // 行为是未定义的，表现为静默丢行）。空 id 用下标兜底保证唯一。
                item.id.length > 0 ? item.id : 'row-' + index.toString())
            }
            .width('100%')
          }

          Text('数据来源于学校财务查询系统，仅供本人查阅；如与财务系统不一致，以财务系统为准。')
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textTertiary)
            .width('100%')
            .padding({ left: 4, right: 4 })
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
    .backgroundColor(AppColor.pageBackground)
  }
}
