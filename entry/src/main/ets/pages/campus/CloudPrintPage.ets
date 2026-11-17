import { LoadState } from '../../common/AppRouter';
import { Logger } from '../../common/Logger';
import { ApiError } from '../../network/ApiError';
import { LocalCloudPrintService, PrintDocument, PrintStation } from '../../network/LocalCloudPrintService';
import { AppColor, AppFont, AppSize } from '../../components/AppTheme';
import { topSafeInsetVp } from '../../common/ImmersiveUtil';
import { ErrorView, LoadingView, SectionCard } from '../../components/CommonViews';

/**
 * 云打印（**只读**：文档列表 + 打印站状态）。
 *
 * 对齐上游 `features/cloud_print/read.rs` 的 `documents()` / `stations()`。
 * 上传、预览、下载、删除**都不做** —— 那些需要文件选择器、大文件分片与写操作。
 *
 * 页面骨架与其它二级页一致：外层 Scroll + 顶部让开标题栏 + 底部让开悬浮页签栏。
 */
@Component
export struct CloudPrintPage {
  @State private loadState: LoadState = LoadState.LOADING;
  @State private errorMessage: string = '';
  @State private docs: PrintDocument[] = [];
  @State private stations: PrintStation[] = [];

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.loadState = LoadState.LOADING;
    try {
      // 文档列表是主体；打印站是加分项，失败不影响文档显示
      const docs: PrintDocument[] = await LocalCloudPrintService.fetchDocuments();
      this.docs = docs;
      try {
        this.stations = await LocalCloudPrintService.fetchStations();
      } catch (stationError) {
        Logger.warn('打印站状态获取失败（忽略）：' + (stationError as Error).message);
      }
      this.loadState = LoadState.SUCCESS;
      Logger.info('云打印文档 ' + docs.length + ' 份、打印站 ' + this.stations.length + ' 台');
    } catch (error) {
      this.errorMessage = error instanceof ApiError ?
        (error as ApiError).friendlyMessage() : '云打印数据加载失败，请稍后重试';
      this.loadState = LoadState.ERROR;
      Logger.error('云打印加载失败：' + (error as Error).message);
    }
  }

  /** `20261117` + `143005` → `2026-11-17 14:30`；缺字段返回占位符。 */
  private timeText(item: PrintDocument): string {
    const d: string = item.date;
    const t: string = item.time;
    if (d.length < 8) {
      return '—';
    }
    const dateText: string = d.substring(0, 4) + '-' + d.substring(4, 6) + '-' + d.substring(6, 8);
    if (t.length < 4) {
      return dateText;
    }
    return dateText + ' ' + t.substring(0, 2) + ':' + t.substring(2, 4);
  }

  @Builder
  docRow(item: PrintDocument) {
    Column({ space: 4 }) {
      Row() {
        Text(item.name)
          .fontSize(AppFont.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (item.expired) {
          Text('已过期')
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textTertiary)
            .margin({ left: 8 })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Row({ space: 12 }) {
        Text(this.timeText(item))
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textTertiary)
        if (item.scan) {
          if (item.bytes.length > 0) {
            Text(item.bytes + ' B')
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textTertiary)
          }
          Text('扫描件')
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textTertiary)
        } else {
          if (item.pages.length > 0) {
            Text(item.pages + ' 页')
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textTertiary)
          }
          if (item.copies.length > 0) {
            Text(item.copies + ' 份')
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textTertiary)
          }
        }
      }
      .width('100%')
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
  }

  @Builder
  stationRow(item: PrintStation) {
    Column({ space: 4 }) {
      Row() {
        Text(item.name)
          .fontSize(AppFont.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(item.state)
          .fontSize(AppFont.caption)
          .fontColor(item.state === '空闲' ? AppColor.accentGreen : AppColor.textTertiary)
          .margin({ left: 8 })
      }
      .width('100%')

      Text((item.group.length > 0 ? item.group + ' · ' : '') +
        (item.papers.length > 0 ? item.papers.join('/') : '纸型未知') +
        (item.capabilities.length > 0 ? ' · ' + item.capabilities.join('/') : ''))
        .fontSize(AppFont.caption)
        .fontColor(AppColor.textTertiary)
        .maxLines(1)
        .width('100%')
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
  }

  build() {
    Scroll() {
      Column({ space: AppSize.gapLarge }) {
        if (this.loadState === LoadState.LOADING) {
          LoadingView({ message: '正在读取云打印文档…' })
        } else if (this.loadState === LoadState.ERROR) {
          ErrorView({
            message: this.errorMessage,
            onRetry: () => {
              this.load();
            }
          })
        } else {
          SectionCard({
            title: '我的文档',
            subtitle: this.docs.length.toString() + ' 份',
            showAction: false
          }) {
            Column() {
              if (this.docs.length === 0) {
                Text('还没有上传过文档')
                  .fontSize(AppFont.caption)
                  .fontColor(AppColor.textTertiary)
                  .width('100%')
                  .padding({ top: 4, bottom: 4 })
              } else {
                ForEach(this.docs, (item: PrintDocument, index: number) => {
                  this.docRow(item)
                  if (index < this.docs.length - 1) {
                    Divider().color(AppColor.divider).strokeWidth(0.5)
                  }
                }, (item: PrintDocument, index: number) =>
                  item.id.length > 0 ? (item.scan ? 's-' : 'p-') + item.id : 'doc-' + index.toString())
              }
            }
            .width('100%')
          }

          if (this.stations.length > 0) {
            SectionCard({
              title: '打印站',
              subtitle: this.stations.length.toString() + ' 台',
              showAction: false
            }) {
              Column() {
                ForEach(this.stations, (item: PrintStation, index: number) => {
                  this.stationRow(item)
                  if (index < this.stations.length - 1) {
                    Divider().color(AppColor.divider).strokeWidth(0.5)
                  }
                }, (item: PrintStation, index: number) => 'st-' + index.toString())
              }
              .width('100%')
            }
          }

          Text('本页只读：上传、预览与删除请到图书馆云打印网页操作。')
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
