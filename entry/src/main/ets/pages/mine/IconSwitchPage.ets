import { AppColor, AppFont, AppSize } from '../../components/AppTheme';
import { topSafeInsetVp } from '../../common/ImmersiveUtil';
import { Toast } from '../../common/Toast';
import { isApi26OrAbove } from '../../common/SystemMaterial';
import { ICON_OPTIONS, IconOption, IconScheme, IconStore, KEY_APP_ICON_SCHEME } from '../../common/IconStore';

/**
 * 切换应用图标页。
 *
 * 四个方案对应 AppScope/app.json5 的 alternateIcons（API 26.0.0+）：
 * A 标识浅/深 + 原版 UBAA 浅/深。点选后调用 bundleManager.setAlternateIcon 生效，
 * 偏好由 IconStore 落盘，重启由 EntryAbility.restore 同步。
 */
@Component
export struct IconSwitchPage {
  stack: NavPathStack = new NavPathStack();

  @StorageLink(KEY_APP_ICON_SCHEME) private current: string = IconScheme.DEFAULT;
  @State private applying: boolean = false;

  private async choose(key: string): Promise<void> {
    if (this.applying || key === this.current) {
      return;
    }
    this.applying = true;
    const supported: boolean = isApi26OrAbove();
    const ok: boolean = await IconStore.apply(key);
    this.current = key;
    this.applying = false;
    if (!supported) {
      Toast.show('当前系统不支持动态图标，需 HarmonyOS API 26 及以上', 2500);
    } else if (ok) {
      Toast.show('图标已切换，请返回桌面查看', 2500);
    } else {
      Toast.show('切换失败，请重试', 2000);
    }
  }

  /** 单个图标方案卡片。 */
  @Builder
  optionCard(option: IconOption) {
    Column({ space: 10 }) {
      Stack() {
        Image(option.previewIcon)
          .width(88)
          .height(88)
          .borderRadius(20)
          .draggable(false)
        if (option.key === this.current) {
          Column() {
            SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
              .fontSize(22)
              .fontColor([Color.White])
          }
          .width(26)
          .height(26)
          .borderRadius(13)
          .backgroundColor(AppColor.brand)
          .justifyContent(FlexAlign.Center)
          .position({ x: 66, y: -6 }) // 右上角（88-26+4）
        }
      }
      .width(88)
      .height(88)

      Text(option.title)
        .fontSize(AppFont.body)
        .fontWeight(FontWeight.Medium)
        .fontColor(option.key === this.current ? AppColor.brand : AppColor.textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(option.subtitle)
        .fontSize(AppFont.caption)
        .fontColor(AppColor.textTertiary)
        .maxLines(2)
        .textAlign(TextAlign.Center)
        .height(32)
    }
    .width('100%')
    .padding({ top: 16, bottom: 14 })
    .borderRadius(16)
    .backgroundColor(AppColor.surface)
    .border({
      width: option.key === this.current ? 2 : 1,
      color: option.key === this.current ? AppColor.brand : AppColor.divider
    })
    .onClick(() => {
      this.choose(option.key);
    })
  }

  build() {
    Scroll() {
      Column({ space: AppSize.gapLarge }) {
        // 说明卡
        Column({ space: 8 }) {
          Text('选择桌面图标')
            .fontSize(AppFont.subtitle)
            .fontWeight(FontWeight.Medium)
            .fontColor(AppColor.textPrimary)
            .width('100%')
          Text('选好后返回桌面即可看到新图标。想用深色图标请直接选深色版本。')
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textSecondary)
            .lineHeight(19)
            .width('100%')
          if (!isApi26OrAbove()) {
            Row({ space: 6 }) {
              SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
                .fontSize(16)
                .fontColor([AppColor.danger])
              Text('当前系统版本不支持动态切换图标（需 API 26 及以上）')
                .fontSize(AppFont.caption)
                .fontColor(AppColor.danger)
            }
            .width('100%')
            .padding({ top: 6 })
          }
        }
        .width('100%')
        .padding(16)
        .borderRadius(16)
        .backgroundColor(AppColor.surface)

        // 2×2 图标卡片网格
        Grid() {
          ForEach(ICON_OPTIONS, (option: IconOption) => {
            GridItem() {
              this.optionCard(option)
            }
          }, (option: IconOption) => option.key)
        }
        .columnsTemplate('1fr 1fr')
        .rowsGap(12)
        .columnsGap(12)
        .width('100%')

        Text('注：应用分身不支持切换图标；切换只影响本应用在桌面的显示，不会改动应用数据。')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textTertiary)
          .lineHeight(18)
          .width('100%')
          .padding({ top: 4 })

        Blank().height(AppSize.contentBottomInset)
      }
      .width('100%')
      .padding({
        left: AppSize.pagePadding,
        right: AppSize.pagePadding,
        top: AppSize.destTopInset(topSafeInsetVp()),
        bottom: 0
      })
      .constraintSize({ minHeight: '100%' })
      .translate({ y: -AppSize.contentTopLift })
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
