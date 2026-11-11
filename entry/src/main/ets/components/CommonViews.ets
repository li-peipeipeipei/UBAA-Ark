import { AppColor, AppFont, AppSize } from './AppTheme';

/**
 * 图标来源类型。
 *
 * - SVG：使用 app.media 下的本地矢量图（沿用 UBAA 的 Material 图标风格，可 fillColor 换色）
 * - SYMBOL：使用 HarmonyOS 系统符号（SymbolGlyph，字号与颜色自适应）
 */
export enum IconKind {
  SVG = 0,
  SYMBOL = 1
}

/** 加载中占位。 */
@Component
export struct LoadingView {
  message: string = '正在加载…';

  build() {
    Column({ space: AppSize.gap }) {
      LoadingProgress()
        .width(40)
        .height(40)
        .color(AppColor.brand)
      Text(this.message)
        .fontSize(AppFont.body)
        .fontColor(AppColor.textSecondary)
    }
    .width('100%')
    .padding({ top: 80, bottom: 80 })
    .justifyContent(FlexAlign.Center)
  }
}

/** 错误占位，带重试入口。 */
@Component
export struct ErrorView {
  message: string = '加载失败';
  onRetry: () => void = () => {};

  build() {
    Column({ space: AppSize.gapLarge }) {
      SymbolGlyph($r('sys.symbol.exclamationmark'))
        .fontSize(44)
        .fontColor([AppColor.warning])
      Text(this.message)
        .fontSize(AppFont.body)
        .fontColor(AppColor.textSecondary)
        .textAlign(TextAlign.Center)
        .padding({ left: 24, right: 24 })
      Button('重新加载')
        .fontSize(AppFont.body)
        .backgroundColor(AppColor.brandContainer)
        .fontColor(AppColor.brand)
        .type(ButtonType.Capsule)
        .height(36)
        .onClick(() => {
          this.onRetry();
        })
    }
    .width('100%')
    .padding({ top: 60, bottom: 60 })
    .justifyContent(FlexAlign.Center)
  }
}

/** 空数据占位。 */
@Component
export struct EmptyView {
  message: string = '暂无数据';

  build() {
    Column({ space: AppSize.gap }) {
      SymbolGlyph($r('sys.symbol.doc'))
        .fontSize(44)
        .fontColor([AppColor.textTertiary])
      Text(this.message)
        .fontSize(AppFont.body)
        .fontColor(AppColor.textSecondary)
    }
    .width('100%')
    .padding({ top: 60, bottom: 60 })
    .justifyContent(FlexAlign.Center)
  }
}

/** 通用卡片容器：统一圆角、留白与背景。 */
@Component
export struct SectionCard {
  title: string = '';
  subtitle: string = '';
  showAction: boolean = false;
  actionText: string = '更多';
  onAction: () => void = () => {};

  @Builder
  emptyContent() {
  }

  @BuilderParam content: () => void = this.emptyContent;

  build() {
    Column({ space: AppSize.gap }) {
      if (this.title.length > 0) {
        Row() {
          Column({ space: 2 }) {
            Text(this.title)
              .fontSize(AppFont.subtitle)
              .fontWeight(FontWeight.Medium)
              .fontColor(AppColor.textPrimary)
            if (this.subtitle.length > 0) {
              Text(this.subtitle)
                .fontSize(AppFont.caption)
                .fontColor(AppColor.textTertiary)
            }
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          if (this.showAction) {
            Row({ space: 2 }) {
              Text(this.actionText)
                .fontSize(AppFont.caption)
                .fontColor(AppColor.textSecondary)
              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(12)
                .fontColor([AppColor.textTertiary])
            }
            .onClick(() => {
              this.onAction();
            })
          }
        }
        .width('100%')
      }

      this.content()
    }
    .width('100%')
    .padding(AppSize.cardPadding)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(AppColor.surface)
    .borderRadius(AppSize.cardRadius)
  }
}

/** 功能入口磁贴（4 列网格中的一格）。 */
/**
 * 功能入口按钮：**大圆角矩形**，图标与文字都在按钮内部。
 *
 * 设计要点（2026-11-11 改版）：
 * - 一整个矩形就是点击热区，不再是「小图标 + 下面一行小字」，触控面积大、误触少；
 * - 左侧 40×40 的彩色圆角块承载重绘的单色图标（白色描边式，跟功能语义对应）；
 * - 右侧两行文字：主标题 + 一句功能说明，扫一眼就知道点进去干什么；
 * - 统一的底色（surface）+ 16 圆角 + 12 内边距，在网格里形成规整的节奏。
 */
@Component
export struct FeatureTile {
  title: string = '';
  desc: string = '';
  icon: Resource = $r('app.media.icf_spoc');
  /** 图标块底色（每个功能一种强调色）。 */
  color: Resource = $r('app.color.brand');
  onTileClick: () => void = () => {};

  build() {
    Row({ space: 12 }) {
      Column() {
        Image(this.icon)
          .width(22)
          .height(22)
          .fillColor(Color.White)
          .draggable(false)
      }
      .width(40)
      .height(40)
      .borderRadius(12)
      .backgroundColor(this.color)
      .justifyContent(FlexAlign.Center)

      Column({ space: 3 }) {
        Text(this.title)
          .fontSize(AppFont.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.desc.length > 0) {
          Text(this.desc)
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textTertiary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .constraintSize({ minHeight: 64 })
    .padding({ left: 12, right: 12, top: 12, bottom: 12 })
    .borderRadius(16)
    .backgroundColor(AppColor.surface)
    .alignItems(VerticalAlign.Center)
    // 平板外接键鼠 / 2in1 触控板上，按钮需要悬停反馈才「像个按钮」（官方多设备交互建议）
    .hoverEffect(HoverEffect.Highlight)
    .onClick(() => {
      this.onTileClick();
    })
  }
}

/** 键值信息行（「我的」页 / 详情页复用）。 */
@Component
export struct InfoRow {
  @Prop label: string = '';
  @Prop value: string = '';
  @Prop showDivider: boolean = true;

  build() {
    Column() {
      Row() {
        Text(this.label)
          .fontSize(AppFont.body)
          .fontColor(AppColor.textSecondary)
        Text(this.value.length > 0 ? this.value : '—')
          .fontSize(AppFont.body)
          .fontColor(AppColor.textPrimary)
          .layoutWeight(1)
          .textAlign(TextAlign.End)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .padding({ top: 12, bottom: 12 })

      if (this.showDivider) {
        Divider()
          .color(AppColor.divider)
          .strokeWidth(0.5)
      }
    }
    .width('100%')
  }
}

/** 章节标题（列表分组用）。 */
@Component
export struct SectionHeader {
  @Prop title: string = '';

  build() {
    Text(this.title)
      .fontSize(AppFont.caption)
      .fontColor(AppColor.textTertiary)
      .padding({ left: 4, bottom: 8 })
      .width('100%')
  }
}
