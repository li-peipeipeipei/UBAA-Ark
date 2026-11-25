import { LoadState } from '../../common/AppRouter';
import { Logger } from '../../common/Logger';
import { ApiError } from '../../network/ApiError';
import { LocalCampusService } from '../../network/LocalCampusService';
import { AppColor, AppFont, AppSize } from '../../components/AppTheme';
import { topSafeInsetVp } from '../../common/ImmersiveUtil';
import { ErrorView, InfoRow, LoadingView, SectionCard } from '../../components/CommonViews';
import { CampusAmount, NetworkProductUsage } from '../../model/ApiTypes';
import { PageCache } from '../../common/PageCache';
import { OfflineKey } from '../../common/OfflineCache';
import { PullToRefresh } from '../../components/PullToRefresh';

/** 网费流量首帧缓存内容。 */
interface NetworkCache {
  products: NetworkProductUsage[];
}

/**
 * 网费流量（上游 UBAA 2.0「校园服务 · 网费」）。
 *
 * 只读：列出每个网络产品的已用流量 / 免费剩余 / 计费剩余。
 *
 * **免费剩余已做套餐合并**（上游 `packages.rs`）：产品内嵌套餐子表里
 * 「可用流量：xxx」的按钮会累加到页面上的「免费流量剩余(不含套餐)」里，
 * 1024 进制折算到最大单位。**计费剩余保持页面原值**（上游也不合并）。
 * 解析不出套餐子表时退回页面原值 —— 少合并可以，绝不错算。
 */
@Component
export struct NetworkPage {
  @State private loadState: LoadState = LoadState.LOADING;
  @State private errorMessage: string = '';
  @State private products: NetworkProductUsage[] = [];

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    // 冷启动首帧：先同步读上次缓存，命中就直接进 SUCCESS（后台继续拉新覆盖）
    const cached: NetworkCache | null = PageCache.load<NetworkCache>(
      OfflineKey.NETWORK, PageCache.TTL_HALF_DAY);
    if (cached !== null && cached.products.length > 0) {
      this.products = cached.products;
      this.loadState = LoadState.SUCCESS;
    }
    if (this.loadState !== LoadState.SUCCESS) {
      this.loadState = LoadState.LOADING;
    }
    try {
      const usage = await LocalCampusService.fetchNetworkUsage();
      this.products = usage.products;
      this.loadState = LoadState.SUCCESS;
      PageCache.save(OfflineKey.NETWORK, { products: this.products } as NetworkCache);
      Logger.info('网费页面加载完成：' + this.products.length + ' 个产品');
    } catch (error) {
      this.errorMessage = error instanceof ApiError ?
        (error as ApiError).friendlyMessage() : '网费数据加载失败，请稍后重试';
      // 缓存命中过时失败不切 ERROR，保留已渲染的本地内容
      if (this.loadState !== LoadState.SUCCESS) {
        this.loadState = LoadState.ERROR;
      }
      Logger.error('网费数据加载失败：' + (error as Error).message);
    }
  }

  /** `90.001` + `G` → `90.001 G`；byte 显示成 `0 B` 更易读。 */
  private amountText(amount: CampusAmount | undefined): string {
    if (amount === undefined || amount === null) {
      return '—';
    }
    const unit: string = amount.unit === 'byte' ? 'B' : amount.unit;
    return amount.value + ' ' + unit;
  }

  @Builder
  productCard(item: NetworkProductUsage) {
    Column({ space: 8 }) {
      Text(item.productName)
        .fontSize(AppFont.subtitle)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.textPrimary)
        .width('100%')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Row() {
        Column({ space: 4 }) {
          Text('已用')
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textTertiary)
          Text(this.amountText(item.used))
            .fontSize(AppFont.body)
            .fontColor(AppColor.textPrimary)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Column({ space: 4 }) {
          Text('免费剩余')
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textTertiary)
          Text(this.amountText(item.freeRemaining))
            .fontSize(AppFont.body)
            .fontColor(AppColor.accentGreen)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Column({ space: 4 }) {
          Text('计费剩余')
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textTertiary)
          Text(this.amountText(item.billableRemaining))
            .fontSize(AppFont.body)
            .fontColor(AppColor.brand)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
  }

  /** 原页面内容。下拉刷新由外层 `build()` 的 PullToRefresh 提供。 */
  @Builder
  pageContent() {
    Scroll() {
      Column({ space: AppSize.gapLarge }) {
        if (this.loadState === LoadState.LOADING) {
          LoadingView({ message: '正在查询网费流量…' })
        } else if (this.loadState === LoadState.ERROR) {
          ErrorView({
            message: this.errorMessage,
            onRetry: () => {
              this.load();
            }
          })
        } else if (this.products.length === 0) {
          SectionCard({ title: '网费流量', showAction: false }) {
            Column() {
              InfoRow({ label: '暂无数据', value: '自助服务未返回流量记录', showDivider: false })
            }
            .width('100%')
          }
        } else {
          SectionCard({
            title: '网费流量',
            subtitle: this.products.length.toString() + ' 个产品',
            showAction: false
          }) {
            Column() {
              ForEach(this.products, (item: NetworkProductUsage, index: number) => {
                this.productCard(item)
                if (index < this.products.length - 1) {
                  Divider().color(AppColor.divider).strokeWidth(0.5)
                }
              }, (item: NetworkProductUsage) => item.productName)
            }
            .width('100%')
          }

          Text('「免费剩余」已计入套餐可用流量；「计费剩余」为自助服务页面原值。如有出入以自助服务为准。')
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

  build() {
    PullToRefresh({
      onRefresh: () => this.load(),
      contentBuilder: () => {
        this.pageContent();
      }
    })
  }
}
