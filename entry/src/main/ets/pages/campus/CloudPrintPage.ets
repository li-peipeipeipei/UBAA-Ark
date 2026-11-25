import curves from '@ohos.curves';
import { common } from '@kit.AbilityKit';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { LoadState } from '../../common/AppRouter';
import { BackGuard } from '../../common/BackGuard';
import { Logger } from '../../common/Logger';
import { Toast } from '../../common/Toast';
import { ApiError } from '../../network/ApiError';
import { PRINT_MAX_BYTES } from '../../network/CloudPrintUpload';
import {
  LocalCloudPrintService,
  LocalPrintFile,
  PrintDocument,
  PrintOptionSet,
  PrintRecord,
  PrintRecords,
  PrintStation
} from '../../network/LocalCloudPrintService';
import { AppColor, AppFont, AppMaterial, AppSize } from '../../components/AppTheme';
import { ChipsEdgeFade } from '../../components/ChipsEdgeFade';
import { FilterChip } from '../../components/FilterChip';
import { MaterialCardLayer } from '../../components/MaterialCardLayer';
import { immersiveMaterialActive, selectMenuMaterial } from '../../common/SystemMaterial';
import { topSafeInsetVp } from '../../common/ImmersiveUtil';
import { EmptyView, ErrorView, LoadingView } from '../../components/CommonViews';
import { PageCache } from '../../common/PageCache';
import { OfflineKey } from '../../common/OfflineCache';
import { PullToRefresh } from '../../components/PullToRefresh';

/**
 * 云打印（对齐上游 `packages/ubaa_ui/lib/src/features/cloud_print/view.dart`）。
 *
 * ## 五个分区
 * 待打印（`PrintJob/Get`）、扫描文档（`Scan/Get`）、打印点（`Station/*`）、
 * 使用记录（`Report/DetailPageEx`）、帮助（静态文案）——与上游 `_Section` 枚举一致。
 *
 * ## 能力范围
 * 待打印：上传（图片自动转 PDF）、预览、删除、多选；扫描文档：下载、删除、多选。
 * 上传单份上限 32 MiB；使用记录每页 20 条。帮助页为静态文案，与上述能力保持同步。
 *
 * ## 顶部胶囊行
 * 与 SPOC 页顶部**同一套**处理：`FilterChip`（同款 ✓ / 弹簧动画）+ `ChipsEdgeFade`
 * 左右 15vp 渐隐 + 全出血 `Scroll`（父级无左右 padding，缩进写在滚动内容里）。
 * 差异只有一处语义：这里是**单选**标签页，所以用 `FilterChip` 的 `controlled` 模式 ——
 * 选中态由 `this.section` 单向驱动，点击只回调父级。
 */

/* ------------------------------ 分区 ------------------------------ */

const CP_QUEUE: string = '待打印';
const CP_SCANS: string = '扫描文档';
const CP_STATIONS: string = '打印点';
const CP_RECORDS: string = '使用记录';
const CP_HELP: string = '帮助';

/** 使用记录的类型（位标志，与上游 `PrintRecordKind` 一致：打印 1 / 复印 2 / 扫描 4）。 */
const RECORD_KIND_PRINT: number = 1;
const RECORD_KIND_COPY: number = 2;
const RECORD_KIND_SCAN: number = 4;

/** 帮助页的四段文案（结构对齐上游 `_Help`，内容按本页能力改写）。 */
interface HelpItem {
  title: string;
  body: string;
}

const HELP_ITEMS: HelpItem[] = [
  {
    title: '上传与打印',
    body: '在待打印点右下角上传，选择本机文件后设置彩色 / 黑白、纸张（原稿 / A4 / A3）、单双面、份数与页码范围。单份不超过 32 MiB，JPG / PNG 会自动转成 PDF。上传后在待打印核对文档与页数，再到图书馆自助设备登录取件。'
  },
  {
    title: '文件格式',
    body: 'PDF、JPG、PNG、DOCX、XLSX、PPTX 已实测可提交。官网也列有其他格式，能否转换以服务器结果为准；遇到排版问题建议先转成 PDF。'
  },
  {
    title: '预览与扫描下载',
    body: '待打印里点文档可查看预览并翻页；点行尾「···」可预览、删除或选中。扫描文档里点行尾「···」下载原件，选好保存位置即可；过期的扫描件不能下载，需要在网页端重新扫描。'
  },
  {
    title: '打印点与使用记录',
    body: '打印点可查看各设备的实时状态（空闲 / 忙碌 / 不可用）与纸型；使用记录按日期区间与类型（打印 / 复印 / 扫描）查询，每页 20 条，可翻页。'
  }
];

/* ------------------------------ 小工具 ------------------------------ */

function pad2(value: number): string {
  return value < 10 ? '0' + value.toString() : value.toString();
}

/** 当前日期 `yyyyMMdd`（接口入参格式）。 */
function ymdOf(date: Date): string {
  return date.getFullYear().toString() + pad2(date.getMonth() + 1) + pad2(date.getDate());
}

/** `yyyyMMdd` → `2026-10-23`（日期胶囊上的标签：带年份，跨年查询不会歧义）。 */
function pillDate(ymd: string): string {
  if (ymd.length !== 8) {
    return ymd;
  }
  return ymd.substring(0, 4) + '-' + ymd.substring(4, 6) + '-' + ymd.substring(6, 8);
}

/** `yyyyMMdd` → `Date`；非法值退回今天。 */
function parseYmd(ymd: string): Date {
  if (ymd.length !== 8) {
    return new Date();
  }
  const year: number = Number(ymd.substring(0, 4));
  const month: number = Number(ymd.substring(4, 6));
  const day: number = Number(ymd.substring(6, 8));
  if (!Number.isFinite(year) || !Number.isFinite(month) || !Number.isFinite(day) ||
    year < 1970 || month < 1 || month > 12 || day < 1 || day > 31) {
    return new Date();
  }
  return new Date(year, month - 1, day);
}

/** 时间字段补齐 6 位（上游可能给 `93005`）。 */
function padTime(text: string): string {
  let out: string = text;
  while (out.length < 6) {
    out = '0' + out;
  }
  return out;
}

/**
 * `20261117` + `143005` → `2026-11-17 14:30`；缺字段返回占位符。
 *
 * 时间字段**不一定是 HHMMSS**：部分账号的 `dwTime` 是 Unix 秒（如 `1781929024`）。
 * 上游的做法是 `padLeft(6,'0')` 后按 `^\d{6}$` 匹配，匹配不上就原样拼在后面 ——
 * 这里照搬：只有补齐后正好 6 位才格式化成 `HH:MM`，否则把原值贴上去，
 * 免得把时间戳切成 `17:81` 这种看不懂的东西。
 */
function dateTimeText(dateText: string, timeText: string): string {
  if (dateText.length < 8) {
    return '—';
  }
  const day: string = dateText.substring(0, 4) + '-' + dateText.substring(4, 6) + '-' +
    dateText.substring(6, 8);
  if (timeText.length === 0) {
    return day;
  }
  const time: string = padTime(timeText);
  if (time.length === 10) {
    // 10 位 = Unix 秒（部分账号的 `dwTime` 就是这个）：解析成 HH:MM。
    // 上游此时会原样贴出 `1781929024` 这种数字串，观感很差，这里做一次格式化。
    const stamp: Date = new Date(Number(time) * 1000);
    if (!Number.isNaN(stamp.getTime())) {
      return day + ' ' + pad2(stamp.getHours()) + ':' + pad2(stamp.getMinutes());
    }
  }
  if (time.length !== 6) {
    // 非 HHMMSS、也非时间戳：原样保留，不做无意义的截断
    return day + ' ' + timeText;
  }
  return day + ' ' + time.substring(0, 2) + ':' + time.substring(2, 4);
}

/** 字节数 → `1.2 MiB` / `860 KiB` / `512 B`；取不到返回空串。 */
function sizeText(bytesText: string): string {
  const value: number = Number(bytesText);
  if (!Number.isFinite(value) || value <= 0) {
    return '';
  }
  const mib: number = 1024 * 1024;
  const kib: number = 1024;
  if (value >= mib) {
    return (value / mib).toFixed(1) + ' MiB';
  }
  if (value >= kib) {
    return (value / kib).toFixed(1) + ' KiB';
  }
  return Math.round(value).toString() + ' B';
}

/** 分 → `¥1.00`。 */
function yuan(cents: number): string {
  return '¥' + (cents / 100).toFixed(2);
}

/**
 * 选项胶囊（弹窗内用的单选小胶囊）。
 *
 * 必须是独立 `@Component`：`@Builder` 的普通参数按值传递、不参与刷新，
 * 用它画「选中态跟着状态变」的胶囊会永远停在首帧（本项目踩过）。
 *
 * 沉浸光感：与课表「选择学期」面板里的选项块同一套做法 —— 胶囊下面垫一层
 * `MaterialCardLayer`（小尺寸传 `layerShadow: false`，否则背后顶出一层影子），
 * 选中态的品牌色写在**内容层**（材质绘制在 backgroundColor 之上，写在承载层那侧会被盖掉）。
 */
@Component
struct PrintOptionChip {
  @Prop label: string = '';
  @Prop active: boolean = false;
  onTap: () => void = () => {
  };
  /** 沉浸材质是否可用（见 components/MaterialCardLayer）。 */
  private readonly materialActive: boolean = immersiveMaterialActive();

  build() {
    Stack() {
      if (this.materialActive) {
        MaterialCardLayer({ layerRadius: 14, layerShadow: false })
      }
      Text(this.label)
        .fontSize(AppFont.caption)
        .fontColor(this.active ? AppColor.brand : AppColor.textSecondary)
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        .borderRadius(14)
        // 材质可用时只在选中态叠一层半透明品牌色，未选中完全透明让材质透出来
        .backgroundColor(this.materialActive ?
          (this.active ? AppColor.brandContainerGlass : Color.Transparent) :
          (this.active ? AppColor.brandContainer : AppColor.glassSurface))
        .onClick(() => {
          this.onTap();
        })
    }
    .margin({ right: 8, bottom: 6 })
    .borderRadius(14)
    .backgroundColor(Color.Transparent)
  }
}

/**
 * 上传前的打印参数（对齐上游 `_UploadDialog`）。
 *
 * 默认值与上游一致：黑白、A4、单面、1 份、全部页。
 */
@CustomDialog
struct PrintOptionsDialog {
  controller?: CustomDialogController;
  fileCount: number = 1;
  onConfirm: (options: PrintOptionSet) => void = () => {
  };

  @State private color: boolean = false;
  @State private paper: number = 9;
  @State private duplex: number = 1;
  @State private copies: number = 1;
  @State private fromText: string = '';
  @State private toText: string = '';

  private pageNumber(text: string): number {
    const value: number = Number(text.trim());
    return Number.isFinite(value) && value > 0 ? Math.floor(value) : 0;
  }

  /** 沉浸材质是否可用（API ≥ 26、应用级没被 DISABLE、材质构造成功）。 */
  private readonly materialActive: boolean = immersiveMaterialActive();

  build() {
    if (this.materialActive) {
      this.immersiveCard();
    } else {
      // 取不到系统材质时退回「半透明玻璃底 + 高斯模糊」的手动样式
      this.glassCard();
    }
  }

  /** 设置项本体（两种外观共用，只有底板不同）。 */
  @Builder
  settingsBody() {
    Column() {
      Row() {
        Text('彩色打印')
          .fontSize(AppFont.body)
          .fontColor(AppColor.textPrimary)
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.color })
          .selectedColor(AppColor.brand)
          .onChange((isOn: boolean) => {
            this.color = isOn;
          })
      }
      .width('100%')
      .height(48)
      .alignItems(VerticalAlign.Center)

      Text('纸张')
        .fontSize(AppFont.caption)
        .fontColor(AppColor.textSecondary)
        .width('100%')
        .margin({ bottom: 6 })
      Row() {
        PrintOptionChip({
          label: '原稿',
          active: this.paper === -1,
          onTap: () => {
            this.paper = -1;
          }
        })
        PrintOptionChip({
          label: 'A4',
          active: this.paper === 9,
          onTap: () => {
            this.paper = 9;
          }
        })
        PrintOptionChip({
          label: 'A3',
          active: this.paper === 8,
          onTap: () => {
            this.paper = 8;
          }
        })
      }
      .width('100%')

      Text('单双面')
        .fontSize(AppFont.caption)
        .fontColor(AppColor.textSecondary)
        .width('100%')
        .margin({ top: 8, bottom: 6 })
      Row() {
        PrintOptionChip({
          label: '单面',
          active: this.duplex === 1,
          onTap: () => {
            this.duplex = 1;
          }
        })
        PrintOptionChip({
          label: '双面·长边',
          active: this.duplex === 2,
          onTap: () => {
            this.duplex = 2;
          }
        })
        PrintOptionChip({
          label: '双面·短边',
          active: this.duplex === 3,
          onTap: () => {
            this.duplex = 3;
          }
        })
      }
      .width('100%')

      Row() {
        Text('份数')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textSecondary)
          .layoutWeight(1)
        Text('－')
          .fontSize(AppFont.subtitle)
          .fontColor(this.copies > 1 ? AppColor.brand : AppColor.textTertiary)
          .width(32)
          .height(32)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            if (this.copies > 1) {
              this.copies--;
            }
          })
        Text(this.copies.toString())
          .fontSize(AppFont.body)
          .fontColor(AppColor.textPrimary)
          .width(40)
          .textAlign(TextAlign.Center)
        Text('＋')
          .fontSize(AppFont.subtitle)
          .fontColor(this.copies < 999 ? AppColor.brand : AppColor.textTertiary)
          .width(32)
          .height(32)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            if (this.copies < 999) {
              this.copies++;
            }
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: 6 })

      // 页码范围：**两行**排版。
      //
      // 原来挤在一行（标签 + 两个 72vp 输入 + 提示），86% 宽的卡片里总宽超出可用宽度，
      // 输入框被压扁、提示文字被吃掉（真机反馈「填入框大小有问题」）。
      // 现在标签独占一行、两个输入等分剩余宽度，任何字号下都不会互相挤。
      Row() {
        Text('页码范围')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textSecondary)
          .layoutWeight(1)
        Text('留空打印全部')
          .fontSize(11)
          .fontColor(AppColor.textTertiary)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: 10, bottom: 6 })

      Row({ space: 8 }) {
        TextInput({ text: $$this.fromText, placeholder: '从' })
          .type(InputType.Number)
          .height(36)
          .layoutWeight(1)
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textPrimary)
          .placeholderColor(AppColor.textTertiary)
          .backgroundColor(AppColor.surfaceSubtle)
          .borderRadius(10)
        Text('－')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textTertiary)
        TextInput({ text: $$this.toText, placeholder: '到' })
          .type(InputType.Number)
          .height(36)
          .layoutWeight(1)
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textPrimary)
          .placeholderColor(AppColor.textTertiary)
          .backgroundColor(AppColor.surfaceSubtle)
          .borderRadius(10)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 弹窗头部：标题 + 份数。与课表课程详情弹窗同一套标题排版。 */
  @Builder
  dialogHeader() {
    Row() {
      Text('打印设置')
        .fontSize(AppFont.title)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.textPrimary)
        .layoutWeight(1)
      Text(this.fileCount.toString() + ' 份文件')
        .fontSize(AppFont.caption)
        .fontColor(AppColor.textTertiary)
    }
    .width('100%')
    .margin({ bottom: 8 })

    Divider()
      .color(AppColor.divider)
      .strokeWidth(0.5)
  }

  /** 底部按钮：取消（文字）+ 开始上传（44vp 主按钮，材质之上叠品牌蓝）。 */
  @Builder
  dialogButtons() {
    Row({ space: 12 }) {
      Text('取消')
        .fontSize(AppFont.subtitle)
        .fontColor(AppColor.textSecondary)
        .height(44)
        .layoutWeight(1)
        .textAlign(TextAlign.Center)
        .borderRadius(22)
        .backgroundColor(this.materialActive ? Color.Transparent : AppColor.surfaceSubtle)
        .onClick(() => {
          if (this.controller !== undefined) {
            this.controller.close();
          }
        })

      Stack() {
        if (this.materialActive) {
          MaterialCardLayer({ layerRadius: 22, layerShadow: false })
        }
        Button('开始上传')
          .width('100%')
          .height(44)
          .fontSize(AppFont.subtitle)
          .fontColor(AppColor.textOnBrand)
          .backgroundColor(this.materialActive ? AppColor.brandGlass : AppColor.brand)
          .onClick(() => {
            const from: number = this.pageNumber(this.fromText);
            const to: number = this.pageNumber(this.toText);
            const options: PrintOptionSet = {
              color: this.color,
              paper: this.paper,
              duplex: this.duplex,
              copies: this.copies,
              from: from,
              to: to
            } as PrintOptionSet;
            if (this.controller !== undefined) {
              this.controller.close();
            }
            this.onConfirm(options);
          })
      }
      .height(44)
      .layoutWeight(1)
      .borderRadius(22)
      .backgroundColor(Color.Transparent)
    }
    .width('100%')
    .margin({ top: 16 })
  }

  /**
   * 沉浸材质卡：尺寸/圆角/内边距与**课表课程详情弹窗逐项一致**
   * （86% 宽、maxWidth 400、`cardRadiusLarge`、`cardPadding + 4`）。
   *
   * ⚠️ 普通容器挂 `systemMaterial` 是静默不渲染的，材质必须由
   * `MaterialCardLayer`（不可交互的 Toggle 画布）承载；Stack 自身不能有底色。
   */
  @Builder
  immersiveCard() {
    Stack() {
      MaterialCardLayer({ layerRadius: AppSize.cardRadiusLarge })
      Column() {
        this.dialogHeader()

        Scroll() {
          Column() {
            this.settingsBody()
          }
          .width('100%')
        }
        .width('100%')
        .constraintSize({ maxHeight: 420 })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .margin({ top: 4 })

        this.dialogButtons()
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

  /** 兜底玻璃卡（API 26 以下设备）：与课程详情弹窗同一套兜底样式。 */
  @Builder
  glassCard() {
    Column() {
      this.dialogHeader()

      Scroll() {
        Column() {
          this.settingsBody()
        }
        .width('100%')
      }
      .width('100%')
      .constraintSize({ maxHeight: 420 })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .margin({ top: 4 })

      this.dialogButtons()
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
}

/**
 * 通用提示 / 确认弹窗（删除确认、批量结果）。
 *
 * 替换掉系统 `AlertDialog` —— 那是实底弹窗，没有沉浸光感，尺寸也和课程详情弹窗不一致。
 * 这里与 `CourseDetailDialog` **同一套外壳**：86% 宽 / maxWidth 400 / `cardRadiusLarge` /
 * `cardPadding + 4`，材质走 `MaterialCardLayer`，不可用时回落到玻璃底。
 */
@CustomDialog
struct PrintMessageDialog {
  controller?: CustomDialogController;
  title: string = '';
  message: string = '';
  confirmText: string = '知道了';
  /** 空串 = 只有一个按钮（纯提示）。 */
  cancelText: string = '';
  /** 危险操作（删除）：确认按钮用警示色。 */
  danger: boolean = false;
  onConfirm: () => void = () => {
  };
  private readonly materialActive: boolean = immersiveMaterialActive();

  build() {
    if (this.materialActive) {
      this.immersiveCard();
    } else {
      this.glassCard();
    }
  }

  @Builder
  body() {
    Column() {
      Text(this.title)
        .fontSize(AppFont.title)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.textPrimary)
        .width('100%')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Divider()
        .color(AppColor.divider)
        .strokeWidth(0.5)
        .margin({ top: 8 })

      Scroll() {
        Text(this.message)
          .fontSize(AppFont.body)
          .fontColor(AppColor.textSecondary)
          .width('100%')
          .lineHeight(21)
      }
      .width('100%')
      .constraintSize({ maxHeight: 260 })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .margin({ top: 10 })

      Row({ space: 12 }) {
        if (this.cancelText.length > 0) {
          Text(this.cancelText)
            .fontSize(AppFont.subtitle)
            .fontColor(AppColor.textSecondary)
            .height(44)
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .borderRadius(22)
            .backgroundColor(this.materialActive ? Color.Transparent : AppColor.surfaceSubtle)
            .onClick(() => {
              if (this.controller !== undefined) {
                this.controller.close();
              }
            })
        }

        Stack() {
          if (this.materialActive) {
            MaterialCardLayer({ layerRadius: 22, layerShadow: false })
          }
          Button(this.confirmText)
            .width('100%')
            .height(44)
            .fontSize(AppFont.subtitle)
            .fontColor(AppColor.textOnBrand)
            .backgroundColor(this.danger ? AppColor.danger :
              (this.materialActive ? AppColor.brandGlass : AppColor.brand))
            .onClick(() => {
              if (this.controller !== undefined) {
                this.controller.close();
              }
              this.onConfirm();
            })
        }
        .height(44)
        .layoutWeight(1)
        .borderRadius(22)
        .backgroundColor(Color.Transparent)
      }
      .width('100%')
      .margin({ top: 16 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  immersiveCard() {
    Stack() {
      MaterialCardLayer({ layerRadius: AppSize.cardRadiusLarge })
      Column() {
        this.body()
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

  @Builder
  glassCard() {
    Column() {
      this.body()
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
}

/**
 * 日期选择弹窗（自定义，替代系统 `DatePickerDialog`）。
 *
 * ## 为什么不用系统弹窗
 * 系统的 `showDatePickerDialog` 只能通过 `backgroundColor` / `backgroundBlurStyle` 调外观，
 * 底板是**系统自己画的**，给不了这套 `Toggle` 承载的沉浸材质（材质必须由我们自己叠一层
 * `MaterialCardLayer`）。所以改成「自定义弹窗 + 内置 `DatePicker`」：
 * 滚轮还是系统组件（手感、无障碍一致），底板换成本工程的材质承载层，外壳尺寸与
 * 课程详情弹窗一致（86% / maxWidth 400 / `cardRadiusLarge` / `cardPadding + 4`）。
 *
 * 降级：材质不可用（API < 26 / 全局关闭）时走玻璃底 + 模糊，并保留描边。
 */
@CustomDialog
struct PrintDateDialog {
  controller?: CustomDialogController;
  title: string = '选择日期';
  /** 打开时的选中日期。 */
  selected: Date = new Date();
  start: Date = new Date(2000, 0, 1);
  end: Date = new Date();
  onPick: (value: Date) => void = () => {
  };
  /** 滚轮当前停住的日期（`onDateChange` 持续更新）。 */
  @State private value: Date = new Date();
  private readonly materialActive: boolean = immersiveMaterialActive();

  aboutToAppear(): void {
    this.value = this.selected;
  }

  build() {
    if (this.materialActive) {
      this.immersiveCard();
    } else {
      this.glassCard();
    }
  }

  /** 标题 + 滚轮 + 按钮（两种外观共用）。 */
  @Builder
  cardBody() {
    Column() {
      Text(this.title)
        .fontSize(AppFont.title)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.textPrimary)
        .width('100%')

      Divider()
        .color(AppColor.divider)
        .strokeWidth(0.5)
        .margin({ top: 8 })

      // 滚轮：系统 DatePicker（年 / 月 / 日三列）。高度给足，避免被压扁。
      DatePicker({
        start: this.start,
        end: this.end,
        selected: this.value
      })
        .width('100%')
        .height(220)
        .onDateChange((value: Date) => {
          this.value = value;
        })

      Row({ space: 12 }) {
        Text('取消')
          .fontSize(AppFont.subtitle)
          .fontColor(AppColor.textSecondary)
          .height(44)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .borderRadius(22)
          .backgroundColor(this.materialActive ? Color.Transparent : AppColor.surfaceSubtle)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })

        Stack() {
          if (this.materialActive) {
            MaterialCardLayer({ layerRadius: 22, layerShadow: false })
          }
          Button('确定')
            .width('100%')
            .height(44)
            .fontSize(AppFont.subtitle)
            .fontColor(AppColor.textOnBrand)
            .backgroundColor(this.materialActive ? AppColor.brandGlass : AppColor.brand)
            .onClick(() => {
              if (this.controller !== undefined) {
                this.controller.close();
              }
              this.onPick(this.value);
            })
        }
        .height(44)
        .layoutWeight(1)
        .borderRadius(22)
        .backgroundColor(Color.Transparent)
      }
      .width('100%')
      .margin({ top: 8 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  immersiveCard() {
    Stack() {
      MaterialCardLayer({ layerRadius: AppSize.cardRadiusLarge })
      Column() {
        this.cardBody()
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

  @Builder
  glassCard() {
    Column() {
      this.cardBody()
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
}

@Component
export struct CloudPrintPage {
  /* ------------------------------ 分区与胶囊 ------------------------------ */
  /** 当前分区（单选，默认「待打印」= 上游 `_Section.queue`）。 */
  @State private section: string = CP_QUEUE;
  /** 顶部胶囊行的实测高度（两侧渐隐遮罩据此定高，见 components/ChipsEdgeFade）。 */
  @State private chipsRowH: number = 33;
  /** 使用记录里类型胶囊行的实测高度（第二个渐隐遮罩）。 */
  @State private kindRowH: number = 33;

  /* ------------------------------ 待打印 ------------------------------ */
  @State private queueState: LoadState = LoadState.LOADING;
  @State private queueError: string = '';
  @State private queue: PrintDocument[] = [];

  /* ------------------------------ 扫描文档 ------------------------------ */
  @State private scanState: LoadState = LoadState.LOADING;
  @State private scanError: string = '';
  @State private scans: PrintDocument[] = [];

  /* ------------------------------ 打印点 ------------------------------ */
  @State private stationState: LoadState = LoadState.LOADING;
  @State private stationError: string = '';
  @State private stations: PrintStation[] = [];

  /* ------------------------------ 使用记录 ------------------------------ */
  /** 查询区间（`yyyyMMdd`，含首尾）。默认最近 30 天，与上游一致。 */
  @State private recordBegin: string = ymdOf(new Date());
  @State private recordEnd: string = ymdOf(new Date());
  @State private recordKind: number = RECORD_KIND_PRINT;
  @State private recordState: LoadState = LoadState.LOADING;
  @State private recordError: string = '';
  @State private records: PrintRecord[] = [];
  @State private recordPage: number = 1;
  @State private recordTotalPages: number = 1;

  /** 已发起过请求的分区（切回时不重复打接口；刷新走显式的「刷新」入口）。 */
  private loaded: string[] = [];

  /* ------------------------------ 上传 / 文档操作 ------------------------------ */
  /** 排序：从新到旧（默认，同上游）/ 从旧到新。 */
  @State private sortNewest: boolean = true;
  /** 多选模式。 */
  @State private selecting: boolean = false;
  /** 已选文档 id（扫描件与打印件可能撞 id，键里带 s-/p- 前缀）。 */
  @State private selectedKeys: string[] = [];
  /** 上传进行中（禁用上传入口、显示进度文案）。 */
  @State private uploadBusy: boolean = false;
  @State private uploadNote: string = '';
  /** 预览浮层。 */
  @State private previewVisible: boolean = false;
  @State private previewDoc: PrintDocument | null = null;
  @State private previewPageNo: number = 1;
  /** 预览图的 base64（直接喂给 Image 的 data URI）。 */
  @State private previewSrc: string = '';
  @State private previewBusy: boolean = false;
  private optionsCtrl: CustomDialogController | null = null;
  private messageCtrl: CustomDialogController | null = null;
  private dateCtrl: CustomDialogController | null = null;
  /** 沉浸材质是否可用（弹窗 / 行操作卡片走材质，见 components/MaterialCardLayer）。 */
  private readonly materialActive: boolean = immersiveMaterialActive();

  aboutToAppear(): void {
    // 默认区间：今天往前 29 天 ~ 今天
    const today: Date = new Date();
    const begin: Date = new Date();
    begin.setDate(today.getDate() - 29);
    this.recordEnd = ymdOf(today);
    this.recordBegin = ymdOf(begin);
    this.ensureSection(CP_QUEUE);
  }

  aboutToDisappear(): void {
    if (this.optionsCtrl !== null) {
      this.optionsCtrl.close();
      this.optionsCtrl = null;
    }
    if (this.messageCtrl !== null) {
      this.messageCtrl.close();
      this.messageCtrl = null;
    }
    if (this.dateCtrl !== null) {
      this.dateCtrl.close();
      this.dateCtrl = null;
    }
    // 页面销毁必须清空返回键登记，否则留下指向已卸载组件的闭包
    BackGuard.clear();
  }

  /**
   * 统一提示 / 确认弹窗（沉浸材质，尺寸对齐课程详情弹窗）。
   *
   * `cancelText` 为空 = 单按钮提示；否则是「取消 + 确认」。
   */
  private showMessage(title: string, message: string, confirmText: string, cancelText: string,
    danger: boolean, onConfirm: () => void): void {
    if (this.messageCtrl !== null) {
      this.messageCtrl.close();
    }
    this.messageCtrl = new CustomDialogController({
      builder: PrintMessageDialog({
        title: title,
        message: message,
        confirmText: confirmText,
        cancelText: cancelText,
        danger: danger,
        onConfirm: onConfirm
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      customStyle: true
    });
    this.messageCtrl.open();
  }

  /* ------------------------------ 加载 ------------------------------ */

  /** 首次进入某分区时才拉数据。 */
  private ensureSection(label: string): void {
    if (this.loaded.indexOf(label) >= 0) {
      return;
    }
    this.loaded.push(label);
    if (label === CP_QUEUE) {
      this.loadQueue();
    } else if (label === CP_SCANS) {
      this.loadScans();
    } else if (label === CP_STATIONS) {
      this.loadStations();
    } else if (label === CP_RECORDS) {
      this.loadRecords(1);
    }
  }

  private selectSection(label: string): void {
    if (this.section === label) {
      return;
    }
    this.section = label;
    this.ensureSection(label);
  }

  /** 使用记录缓存 key：按日期区间 + 类型 + 页码隔离（查询条件不同数据不同）。 */
  private recordsCacheKey(page: number): string {
    return OfflineKey.CPRINT_RECORDS + '_' + this.recordBegin + '_' +
      this.recordEnd + '_' + this.recordKind.toString() + '_' + page.toString();
  }

  private async loadQueue(): Promise<void> {
    const cached: PrintDocument[] | null =
      PageCache.load<PrintDocument[]>(OfflineKey.CPRINT_QUEUE, PageCache.TTL_HALF_DAY);
    if (cached !== null) {
      this.queue = cached;
      this.queueState = LoadState.SUCCESS;
    } else if (this.queueState !== LoadState.SUCCESS) {
      this.queueState = LoadState.LOADING;
    }
    try {
      const docs: PrintDocument[] = await LocalCloudPrintService.fetchDocuments(false);
      this.queue = this.sortNewestFirst(docs);
      this.queueState = LoadState.SUCCESS;
      PageCache.save(OfflineKey.CPRINT_QUEUE, this.queue);
      Logger.info('云打印待打印 ' + docs.length + ' 份');
    } catch (error) {
      if (this.queue.length === 0) {
        this.queueError = error instanceof ApiError ?
          (error as ApiError).friendlyMessage() : '待打印列表加载失败，请稍后重试';
        this.queueState = LoadState.ERROR;
      }
      Logger.error('云打印待打印加载失败：' + (error as Error).message);
    }
  }

  private async loadScans(): Promise<void> {
    const cached: PrintDocument[] | null =
      PageCache.load<PrintDocument[]>(OfflineKey.CPRINT_SCANS, PageCache.TTL_HALF_DAY);
    if (cached !== null) {
      this.scans = cached;
      this.scanState = LoadState.SUCCESS;
    } else if (this.scanState !== LoadState.SUCCESS) {
      this.scanState = LoadState.LOADING;
    }
    try {
      const docs: PrintDocument[] = await LocalCloudPrintService.fetchDocuments(true);
      this.scans = this.sortNewestFirst(docs);
      this.scanState = LoadState.SUCCESS;
      PageCache.save(OfflineKey.CPRINT_SCANS, this.scans);
      Logger.info('云打印扫描文档 ' + docs.length + ' 份');
    } catch (error) {
      if (this.scans.length === 0) {
        this.scanError = error instanceof ApiError ?
          (error as ApiError).friendlyMessage() : '扫描文档加载失败，请稍后重试';
        this.scanState = LoadState.ERROR;
      }
      Logger.error('云打印扫描文档加载失败：' + (error as Error).message);
    }
  }

  private async loadStations(): Promise<void> {
    const cached: PrintStation[] | null =
      PageCache.load<PrintStation[]>(OfflineKey.CPRINT_STATIONS, PageCache.TTL_HALF_DAY);
    if (cached !== null) {
      this.stations = cached;
      this.stationState = LoadState.SUCCESS;
    } else if (this.stationState !== LoadState.SUCCESS) {
      this.stationState = LoadState.LOADING;
    }
    try {
      this.stations = await LocalCloudPrintService.fetchStations();
      this.stationState = LoadState.SUCCESS;
      PageCache.save(OfflineKey.CPRINT_STATIONS, this.stations);
      Logger.info('云打印打印点 ' + this.stations.length + ' 台');
    } catch (error) {
      if (this.stations.length === 0) {
        this.stationError = error instanceof ApiError ?
          (error as ApiError).friendlyMessage() : '打印点状态加载失败，请稍后重试';
        this.stationState = LoadState.ERROR;
      }
      Logger.error('云打印打印点加载失败：' + (error as Error).message);
    }
  }

  private async loadRecords(page: number): Promise<void> {
    const key: string = this.recordsCacheKey(page);
    const cached: PrintRecord[] | null = PageCache.load<PrintRecord[]>(key, PageCache.TTL_HALF_DAY);
    if (cached !== null) {
      this.records = cached;
      this.recordPage = page;
      this.recordState = LoadState.SUCCESS;
    } else if (this.recordState !== LoadState.SUCCESS) {
      this.recordState = LoadState.LOADING;
    }
    try {
      const result: PrintRecords = await LocalCloudPrintService.fetchRecords(
        this.recordBegin, this.recordEnd, this.recordKind, page);
      this.records = result.items;
      this.recordTotalPages = Math.max(result.totalPages, 1);
      // 服务端页数变少时把页码夹回范围内，避免停在空白页
      this.recordPage = Math.min(page, this.recordTotalPages);
      this.recordState = LoadState.SUCCESS;
      PageCache.save(key, this.records, true);
      Logger.info('云打印使用记录 ' + result.items.length + ' 条 / 共 ' +
        result.totalPages.toString() + ' 页');
    } catch (error) {
      if (this.records.length === 0) {
        this.recordError = error instanceof ApiError ?
          (error as ApiError).friendlyMessage() : '使用记录加载失败，请稍后重试';
        this.recordState = LoadState.ERROR;
      }
      Logger.error('云打印使用记录加载失败：' + (error as Error).message);
    }
  }

  /** 按提交时间排序（字符串日期 + 补齐的时间即可正确比较）；方向由 `sortNewest` 决定。 */
  private sortNewestFirst(input: PrintDocument[]): PrintDocument[] {
    const out: PrintDocument[] = input.slice();
    const newest: boolean = this.sortNewest;
    out.sort((a: PrintDocument, b: PrintDocument): number => {
      const left: string = a.date + padTime(a.time);
      const right: string = b.date + padTime(b.time);
      if (left === right) {
        return 0;
      }
      const ascending: number = left < right ? -1 : 1;
      return newest ? -ascending : ascending;
    });
    return out;
  }

  /** 切换排序方向（列表已在内存里，直接重排，不再打接口）。 */
  private toggleSort(): void {
    this.sortNewest = !this.sortNewest;
    this.queue = this.sortNewestFirst(this.queue);
    this.scans = this.sortNewestFirst(this.scans);
  }

  /* ------------------------------ 上传 ------------------------------ */

  /**
   * 选文件 → 打印设置 → 逐份上传。
   *
   * 用系统文件选择器（免权限），拿到的 `file://docs/...` URI 通过 `FileUri.path`
   * 转成本地路径再用 `fileIo` 读字节 —— 这是官方推荐的「选择即授权」路径。
   */
  private async pickAndUpload(): Promise<void> {
    if (this.uploadBusy) {
      return;
    }
    const selectOptions = new picker.DocumentSelectOptions();
    selectOptions.maxSelectNumber = 20;
    selectOptions.fileSuffixFilters = [
      'PDF 与文档|.pdf,.docx,.xlsx,.pptx,.txt',
      '图片|.jpg,.jpeg,.png',
      '其它可打印格式|.doc,.xls,.ppt,.wps,.wpt,.rtf,.csv,.odt,.ods'
    ];
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    let uris: string[] = [];
    try {
      uris = await new picker.DocumentViewPicker(context).select(selectOptions);
    } catch (error) {
      Logger.warn('选择打印文件失败：' + (error as Error).message);
      return;
    }
    if (uris.length === 0) {
      return;
    }
    if (uris.length > 20) {
      Toast.show('每批最多上传 20 份，请分批选择');
      return;
    }
    const files: LocalPrintFile[] = [];
    let skipped: number = 0;
    for (let i = 0; i < uris.length; i++) {
      try {
        files.push(this.readPickedFile(uris[i]));
      } catch (error) {
        skipped++;
        Logger.warn('读取打印文件失败：' + (error as Error).message);
      }
    }
    if (files.length === 0) {
      Toast.show('没有可上传的文件（需大于 0 字节且不超过 32 MiB）');
      return;
    }
    if (skipped > 0) {
      Toast.show('已跳过 ' + skipped.toString() + ' 份无法读取的文件');
    }
    this.openPrintOptions(files);
  }

  /** 读一份选中的文件（只读打开 → 整块读入 → 关句柄）。 */
  private readPickedFile(uri: string): LocalPrintFile {
    const path: string = new fileUri.FileUri(uri).path;
    let name: string = path.substring(path.lastIndexOf('/') + 1);
    try {
      name = decodeURIComponent(name);
    } catch (error) {
      // 解码失败就用原串，不影响上传
    }
    const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    try {
      const size: number = fileIo.statSync(file.fd).size;
      if (size <= 0 || size > PRINT_MAX_BYTES) {
        throw new ApiError(400, 'cloudprint_upload', '文件大小超限：' + name);
      }
      const buffer = new ArrayBuffer(size);
      const read: number = fileIo.readSync(file.fd, buffer);
      if (read !== size) {
        throw new ApiError(400, 'cloudprint_upload', '文件未完整读入：' + name);
      }
      return { name: name, bytes: new Uint8Array(buffer) } as LocalPrintFile;
    } finally {
      fileIo.closeSync(file);
    }
  }

  private openPrintOptions(files: LocalPrintFile[]): void {
    if (this.optionsCtrl !== null) {
      this.optionsCtrl.close();
    }
    this.optionsCtrl = new CustomDialogController({
      builder: PrintOptionsDialog({
        fileCount: files.length,
        onConfirm: (options: PrintOptionSet) => {
          this.runUpload(files, options);
        }
      }),
      autoCancel: false,
      alignment: DialogAlignment.Center,
      customStyle: true
    });
    this.optionsCtrl.open();
  }

  /** 顺序上传（上游同样是「一次一份、最多 20 份」），逐份汇报成败。 */
  private async runUpload(files: LocalPrintFile[], options: PrintOptionSet): Promise<void> {
    this.uploadBusy = true;
    let ok: number = 0;
    const problems: string[] = [];
    try {
      for (let i = 0; i < files.length; i++) {
        this.uploadNote = '正在上传 ' + (i + 1).toString() + ' / ' + files.length.toString() +
          '：' + files[i].name;
        try {
          await LocalCloudPrintService.upload(files[i], options);
          ok++;
        } catch (error) {
          const message: string = error instanceof ApiError ?
            (error as ApiError).friendlyMessage() : '上传失败';
          problems.push(files[i].name + '：' + message);
          Logger.warn('云打印上传失败：' + message);
        }
      }
    } finally {
      this.uploadBusy = false;
      this.uploadNote = '';
    }
    await this.loadQueue();
    if (problems.length === 0) {
      Toast.show('已上传 ' + ok.toString() + ' 份');
      return;
    }
    this.reportResult('上传', ok, problems);
  }

  /* ------------------------------ 删除 ------------------------------ */

  private confirmDelete(docs: PrintDocument[], scan: boolean): void {
    if (docs.length === 0) {
      return;
    }
    const names: string[] = [];
    for (let i = 0; i < docs.length && i < 5; i++) {
      names.push(docs[i].name.length > 0 ? docs[i].name : docs[i].id);
    }
    if (docs.length > 5) {
      names.push('…');
    }
    this.showMessage(
      '删除 ' + docs.length.toString() + ' 份' + (scan ? '扫描文档' : '待打印任务') + '？',
      names.join('\n'),
      '删除',
      '取消',
      true,
      () => {
        this.runDelete(docs, scan);
      });
  }
  private async runDelete(docs: PrintDocument[], scan: boolean): Promise<void> {
    let ok: number = 0;
    const problems: string[] = [];
    for (let i = 0; i < docs.length; i++) {
      try {
        await LocalCloudPrintService.deleteDocument(docs[i], scan);
        ok++;
      } catch (error) {
        const message: string = error instanceof ApiError ?
          (error as ApiError).friendlyMessage() : '删除失败';
        problems.push((docs[i].name.length > 0 ? docs[i].name : docs[i].id) + '：' + message);
      }
    }
    this.exitSelecting();
    await this.reloadDocs();
    if (problems.length === 0) {
      Toast.show('已删除 ' + ok.toString() + ' 份');
      return;
    }
    this.reportResult('删除', ok, problems);
  }

  /** 批量操作结果：全成功走 Toast，有失败就列出来（最多 8 条）。 */
  private reportResult(action: string, ok: number, problems: string[]): void {
    const lines: string[] = [];
    lines.push('成功 ' + ok.toString() + ' / ' + (ok + problems.length).toString());
    for (let i = 0; i < problems.length && i < 8; i++) {
      lines.push(problems[i]);
    }
    if (problems.length > 8) {
      lines.push('…共 ' + problems.length.toString() + ' 条失败');
    }
    this.showMessage(action + '结果', lines.join('\n'), '知道了', '', false, () => {
    });
  }

  /* ------------------------------ 预览 / 下载 ------------------------------ */

  /**
   * 行尾菜单的条目（按目标文档决定：打印件可预览，扫描件可下载）。
   *
   * `bindMenu` 直接吃这组数据 —— 每条自带 action，闭包里就是这一行的文档，
   * 页面不必再记「当前操作的是谁」。
   */
  private rowMenu(doc: PrintDocument, scan: boolean): Array<MenuElement> {
    const items: MenuElement[] = [];
    if (!scan && doc.pages.length > 0 && Number(doc.pages) > 0) {
      items.push({
        value: '预览',
        action: () => {
          this.openPreview(doc);
        }
      });
    }
    if (scan && !doc.expired) {
      items.push({
        value: '下载',
        action: () => {
          this.downloadScan(doc);
        }
      });
    }
    if (!doc.expired) {
      items.push({
        value: '删除',
        action: () => {
          const targets: PrintDocument[] = [doc];
          this.confirmDelete(targets, scan);
        }
      });
    }
    items.push({
      value: '选择',
      action: () => {
        this.togglePick(doc, scan);
      }
    });
    return items;
  }

  /** 点一行：多选态下切换选中；能预览就直接预览；其余情况靠行尾菜单。 */
  private tapRow(doc: PrintDocument, scan: boolean): void {
    if (this.selecting) {
      this.togglePick(doc, scan);
      return;
    }
    if (!scan && doc.pages.length > 0 && Number(doc.pages) > 0) {
      this.openPreview(doc);
    }
  }

  /**
   * 打开预览。
   *
   * 预览是页面内的自绘浮层：**必须登记返回键**，否则按系统返回会把整个云打印页
   * 弹掉、回到功能页（用户实测反馈的问题）。`BackGuard` 的关闭动作里只改状态、
   * 不再 `unregister()` —— 出栈由 `consume()` 负责。
   */
  private openPreview(doc: PrintDocument): void {
    this.previewDoc = doc;
    this.previewPageNo = 1;
    this.previewSrc = '';
    this.previewVisible = true;
    BackGuard.register(() => {
      this.hidePreview();
      return true;
    });
    this.loadPreviewPage(1);
  }

  /** 只改状态（返回键路径用）。 */
  private hidePreview(): void {
    this.previewVisible = false;
    this.previewDoc = null;
    this.previewSrc = '';
    this.previewBusy = false;
  }

  /** 关闭预览（按钮路径：状态 + 注销返回键那一层）。 */
  private closePreview(): void {
    if (!this.previewVisible) {
      return;
    }
    this.hidePreview();
    BackGuard.unregister();
  }

  private async loadPreviewPage(pageNo: number): Promise<void> {
    const doc: PrintDocument | null = this.previewDoc;
    if (doc === null || this.previewBusy) {
      return;
    }
    this.previewBusy = true;
    try {
      const bytes: Uint8Array = await LocalCloudPrintService.fetchPreviewPage(doc, pageNo);
      this.previewSrc = 'data:image/png;base64,' + new util.Base64Helper().encodeToStringSync(bytes);
      this.previewPageNo = pageNo;
    } catch (error) {
      const message: string = error instanceof ApiError ?
        (error as ApiError).friendlyMessage() : '预览加载失败';
      Toast.show(message);
      Logger.warn('云打印预览失败：' + message);
    } finally {
      this.previewBusy = false;
    }
  }

  /** 下载扫描原件到用户选的位置（`DocumentViewPicker.save`，免权限）。 */
  private async downloadScan(doc: PrintDocument): Promise<void> {
    try {
      const bytes: Uint8Array = await LocalCloudPrintService.downloadScan(doc);
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const saveOptions = new picker.DocumentSaveOptions();
      saveOptions.newFileNames = [doc.name.length > 0 ? doc.name : 'scan-' + doc.date + '.pdf'];
      const uris: string[] = await new picker.DocumentViewPicker(context).save(saveOptions);
      if (uris.length === 0) {
        return;
      }
      const out: fileIo.File = fileIo.openSync(uris[0],
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      try {
        const copy = new Uint8Array(bytes.length);
        copy.set(bytes);
        if (fileIo.writeSync(out.fd, copy.buffer) !== copy.length) {
          throw new Error('写入不完整');
        }
      } finally {
        fileIo.closeSync(out);
      }
      Toast.show('已保存到所选位置');
    } catch (error) {
      const message: string = error instanceof ApiError ?
        (error as ApiError).friendlyMessage() : '下载失败，请稍后重试';
      Toast.show(message);
      Logger.warn('云打印下载失败：' + message);
    }
  }

  /* ------------------------------ 多选 ------------------------------ */

  private docKey(doc: PrintDocument, scan: boolean): string {
    return (scan ? 's-' : 'p-') + doc.id + doc.date + doc.time;
  }

  private isPicked(doc: PrintDocument, scan: boolean): boolean {
    return this.selectedKeys.indexOf(this.docKey(doc, scan)) >= 0;
  }

  private togglePick(doc: PrintDocument, scan: boolean): void {
    const key: string = this.docKey(doc, scan);
    const next: string[] = [];
    let found: boolean = false;
    for (let i = 0; i < this.selectedKeys.length; i++) {
      if (this.selectedKeys[i] === key) {
        found = true;
      } else {
        next.push(this.selectedKeys[i]);
      }
    }
    if (!found) {
      next.push(key);
    }
    this.selectedKeys = next;
    this.selecting = true;
  }

  private exitSelecting(): void {
    this.selecting = false;
    this.selectedKeys = [];
  }

  private currentDocs(): PrintDocument[] {
    return this.isScanSection() ? this.scans : this.queue;
  }

  private pickedDocs(): PrintDocument[] {
    const scan: boolean = this.isScanSection();
    const out: PrintDocument[] = [];
    const docs: PrintDocument[] = this.currentDocs();
    for (let i = 0; i < docs.length; i++) {
      if (this.isPicked(docs[i], scan)) {
        out.push(docs[i]);
      }
    }
    return out;
  }

  private toggleSelectAll(): void {
    const scan: boolean = this.isScanSection();
    const docs: PrintDocument[] = this.currentDocs();
    if (this.pickedDocs().length === docs.length) {
      this.selectedKeys = [];
      return;
    }
    const keys: string[] = [];
    for (let i = 0; i < docs.length; i++) {
      keys.push(this.docKey(docs[i], scan));
    }
    this.selectedKeys = keys;
  }

  /* ------------------------------ 使用记录交互 ------------------------------ */

  /**
   * 打开日期选择弹窗（自绘，见 `PrintDateDialog`）。
   *
   * 起始/结束互相夹紧，防止出现倒置区间；选完立即按新区间重查第 1 页。
   */
  private pickRecordDate(isBegin: boolean): void {
    const current: string = isBegin ? this.recordBegin : this.recordEnd;
    if (this.dateCtrl !== null) {
      this.dateCtrl.close();
    }
    this.dateCtrl = new CustomDialogController({
      builder: PrintDateDialog({
        title: isBegin ? '选择开始日期' : '选择结束日期',
        selected: parseYmd(current),
        start: new Date(2000, 0, 1),
        end: new Date(),
        onPick: (value: Date) => {
          const picked: string = ymdOf(value);
          if (isBegin) {
            this.recordBegin = picked;
            if (picked > this.recordEnd) {
              this.recordEnd = picked;
            }
          } else {
            this.recordEnd = picked;
            if (picked < this.recordBegin) {
              this.recordBegin = picked;
            }
          }
          this.loadRecords(1);
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      customStyle: true
    });
    this.dateCtrl.open();
  }

  private selectRecordKind(kind: number): void {
    if (this.recordKind === kind) {
      return;
    }
    animateTo({ curve: curves.responsiveSpringMotion(0.25, 0.7) }, () => {
      this.recordKind = kind;
    });
    this.loadRecords(1);
  }

  /** 一条记录的副标题：页数 · 纸型 · 免费额度 · 校园卡 · 其他 · 合计。 */
  private recordMeta(item: PrintRecord): string {
    const parts: string[] = [];
    if (item.pages.length > 0) {
      parts.push(item.pages + ' 页');
    }
    if (item.paper.length > 0) {
      parts.push(item.paper);
    }
    parts.push('免费 ' + yuan(item.freeCents));
    parts.push('校园卡 ' + yuan(item.cardCents));
    parts.push('其他 ' + yuan(item.otherCents));
    parts.push('合计 ' + yuan(item.freeCents + item.cardCents + item.otherCents));
    return parts.join(' · ');
  }

  /* ------------------------------ 打印点分组 ------------------------------ */

  /** 分组名（保持服务端返回顺序；空分组归入「其他打印点」）。 */
  private stationGroups(): string[] {
    const out: string[] = [];
    for (let i = 0; i < this.stations.length; i++) {
      const name: string = this.stations[i].group.length > 0 ?
        this.stations[i].group : '其他打印点';
      if (out.indexOf(name) < 0) {
        out.push(name);
      }
    }
    return out;
  }

  private stationsOf(group: string): PrintStation[] {
    const out: PrintStation[] = [];
    for (let i = 0; i < this.stations.length; i++) {
      const name: string = this.stations[i].group.length > 0 ?
        this.stations[i].group : '其他打印点';
      if (name === group) {
        out.push(this.stations[i]);
      }
    }
    return out;
  }

  /* ------------------------------ 胶囊行 ------------------------------ */

  /**
   * 胶囊行两侧渐隐（高度由该行 `onAreaChange` 实测上报）。
   *
   * ⚠️ `hitTestBehavior` 必须在调用处再设一遍：自定义组件节点自己也是一层参与
   * 触摸测试的节点，只在组件内部给根容器设 None，组件节点仍会吃掉整条胶囊行的点击。
   */
  @Builder
  chipsEdgeFade() {
    ChipsEdgeFade({ fadeHeight: this.chipsRowH })
      .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  kindEdgeFade() {
    ChipsEdgeFade({ fadeHeight: this.kindRowH })
      .hitTestBehavior(HitTestMode.None)
  }

  /**
   * 五个分区胶囊（页面顶部第一行）。
   *
   * 结构、留白、渐隐与 SPOC 页顶部的筛选胶囊**逐项一致**：
   * - 父级 Column 没有左右 padding → 本 `Scroll` 的盒子是 `0 → 屏幕宽`（全出血）；
   * - 默认缩进 16vp 写在**滚动内容** `Row` 的 padding 里（静止时与下方卡片左对齐，滑动时跟着滚走）；
   * - 渐隐走 `overlay`（不参与布局、不吃手势），高度由 `onAreaChange` 实测；
   * - `align(Alignment.Center)`：胶囊整体居中（六处胶囊行统一要求）。
   *
   * ⚠️ 这里**不写 `ForEach`**：`ForEach` 的 itemGenerator 只在键集合变化时重跑，
   * 键不变时子组件的 `@Prop` 不会跟着父级状态刷新（表现为「点了胶囊不变色」）。
   * 五项是固定枚举，直接铺开写，父级 `this.section` 一变就逐个更新。
   */
  @Builder
  sectionBar() {
    Scroll() {
      Row() {
        FilterChip({
          label: CP_QUEUE,
          controlled: true,
          active: this.section === CP_QUEUE,
          initialSelected: this.section === CP_QUEUE,
          onTap: () => {
            animateTo({ curve: curves.responsiveSpringMotion(0.25, 0.7) }, () => {
              this.selectSection(CP_QUEUE);
            });
          }
        })
        FilterChip({
          label: CP_SCANS,
          controlled: true,
          active: this.section === CP_SCANS,
          initialSelected: this.section === CP_SCANS,
          onTap: () => {
            animateTo({ curve: curves.responsiveSpringMotion(0.25, 0.7) }, () => {
              this.selectSection(CP_SCANS);
            });
          }
        })
        FilterChip({
          label: CP_STATIONS,
          controlled: true,
          active: this.section === CP_STATIONS,
          initialSelected: this.section === CP_STATIONS,
          onTap: () => {
            animateTo({ curve: curves.responsiveSpringMotion(0.25, 0.7) }, () => {
              this.selectSection(CP_STATIONS);
            });
          }
        })
        FilterChip({
          label: CP_RECORDS,
          controlled: true,
          active: this.section === CP_RECORDS,
          initialSelected: this.section === CP_RECORDS,
          onTap: () => {
            animateTo({ curve: curves.responsiveSpringMotion(0.25, 0.7) }, () => {
              this.selectSection(CP_RECORDS);
            });
          }
        })
        FilterChip({
          label: CP_HELP,
          controlled: true,
          active: this.section === CP_HELP,
          initialSelected: this.section === CP_HELP,
          onTap: () => {
            animateTo({ curve: curves.responsiveSpringMotion(0.25, 0.7) }, () => {
              this.selectSection(CP_HELP);
            });
          }
        })
      }
      // 默认缩进放在**滚动内容**里（见方法注释）；滑动时这段留白跟着滚走
      .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
    }
    .width('100%')
    .scrollBar(BarState.Off)
    .scrollable(ScrollDirection.Horizontal)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .align(Alignment.Center)
    .clip(false)
    .onAreaChange((_old: Area, now: Area) => {
      const height: number = Number(now.height);
      if (height > 0 && Math.abs(height - this.chipsRowH) > 0.5) {
        this.chipsRowH = height;
      }
    })
    .overlay(this.chipsEdgeFade(), { align: Alignment.Center })
  }

  /* ------------------------------ 列表行 ------------------------------ */

  /** 多选态的圆形勾选位（多选模式下所有行都显示）。 */
  @Builder
  pickMark(item: PrintDocument, scan: boolean) {
    Text(this.isPicked(item, scan) ? '✓' : '')
      .fontSize(12)
      .fontColor(Color.White)
      .width(20)
      .height(20)
      .textAlign(TextAlign.Center)
      .borderRadius(10)
      .margin({ right: 10 })
      .backgroundColor(this.isPicked(item, scan) ? AppColor.brand : Color.Transparent)
      .border({
        width: 1,
        color: this.isPicked(item, scan) ? AppColor.brand : AppColor.divider
      })
  }

  /**
   * 行尾「更多」入口（多选态下收起，避免和勾选打架）。
   *
   * 菜单用 `bindMenu` —— 与空闲教室页「校区 / 日期 / 教学楼」下拉**同一种形态**：
   * 系统贴在触发控件旁的弹出菜单（不是盖住整页的居中卡片），并挂同一份
   * `selectMenuMaterial()` 材质，底色 / 边框 / 阴影都走沉浸光感。
   * 菜单项带各自的关闭语义，因此不需要页面再维护「当前操作的是哪份文档」。
   */
  @Builder
  rowMore(item: PrintDocument, scan: boolean) {
    Text('···')
      .fontSize(16)
      .fontColor(AppColor.textTertiary)
      .width(32)
      .height(32)
      .textAlign(TextAlign.Center)
      .bindMenu(this.rowMenu(item, scan), { systemMaterial: selectMenuMaterial() })
  }

  @Builder
  printRow(item: PrintDocument) {
    Row() {
      if (this.selecting) {
        this.pickMark(item, false)
      }
      Column({ space: 4 }) {
        Text(item.name.length > 0 ? item.name : '未命名文档')
          .fontSize(AppFont.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Row({ space: 12 }) {
          Text(dateTimeText(item.date, item.time))
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textTertiary)
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
        .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (!this.selecting) {
        this.rowMore(item, false)
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 10, bottom: 10 })
    .onClick(() => {
      this.tapRow(item, false);
    })
    .gesture(LongPressGesture().onAction(() => {
      this.togglePick(item, false);
    }))
  }

  @Builder
  scanRow(item: PrintDocument) {
    Row() {
      if (this.selecting) {
        this.pickMark(item, true)
      }
      Column({ space: 4 }) {
        Row({ space: 8 }) {
          Text(dateTimeText(item.date, item.time))
            .fontSize(AppFont.body)
            .fontWeight(FontWeight.Medium)
            .fontColor(AppColor.textPrimary)
            .layoutWeight(1)
            .maxLines(1)
          if (item.expired) {
            Text('已过期')
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textTertiary)
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Row({ space: 12 }) {
          Text(item.name.length > 0 ? item.name : '扫描件')
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textTertiary)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (sizeText(item.bytes).length > 0) {
            Text(sizeText(item.bytes))
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textTertiary)
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (!this.selecting) {
        this.rowMore(item, true)
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 10, bottom: 10 })
    .onClick(() => {
      this.tapRow(item, true);
    })
    .gesture(LongPressGesture().onAction(() => {
      this.togglePick(item, true);
    }))
  }

  @Builder
  stationRow(item: PrintStation) {
    Column({ space: 4 }) {
      Row({ space: 8 }) {
        Text(item.name.length > 0 ? item.name : '打印点')
          .fontSize(AppFont.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(item.state)
          .fontSize(AppFont.caption)
          .fontColor(item.state === '空闲' ? AppColor.accentGreen :
            (item.state === '忙碌' ? AppColor.warning : AppColor.textTertiary))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text((item.papers.length > 0 ? item.papers.join(' / ') : '纸型未知') +
        (item.capabilities.length > 0 ? ' · ' + item.capabilities.join('、') : ''))
        .fontSize(AppFont.caption)
        .fontColor(AppColor.textTertiary)
        .width('100%')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
  }

  @Builder
  recordRow(item: PrintRecord) {
    Column({ space: 4 }) {
      Row({ space: 8 }) {
        Text(dateTimeText(item.date, item.time))
          .fontSize(AppFont.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .layoutWeight(1)
          .maxLines(1)
        if (item.paper.length > 0) {
          Text(item.paper)
            .fontSize(11)
            .fontColor(AppColor.textSecondary)
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .borderRadius(6)
            .backgroundColor(AppColor.surfaceSubtle)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(this.recordMeta(item))
        .fontSize(AppFont.caption)
        .fontColor(AppColor.textTertiary)
        .width('100%')
        .maxLines(2)
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
  }

  /* ------------------------------ 各分区主体 ------------------------------ */

  /** 当前分区是否是「扫描文档」（决定同一条列表走哪套字段与文案）。 */
  private isScanSection(): boolean {
    return this.section === CP_SCANS;
  }

  private docsState(): LoadState {
    return this.isScanSection() ? this.scanState : this.queueState;
  }

  private docsError(): string {
    return this.isScanSection() ? this.scanError : this.queueError;
  }

  private docsOf(): PrintDocument[] {
    return this.isScanSection() ? this.scans : this.queue;
  }

  private reloadDocs(): void {
    if (this.isScanSection()) {
      this.loadScans();
    } else {
      this.loadQueue();
    }
  }

  /**
   * 下拉刷新：只重拉当前分区，保留分区选择、使用记录日期/类型/页码。
   * 帮助页是静态内容，无需网络请求（Promise 立即结束，转圈一闪即收）。
   */
  private async refreshCurrentSection(): Promise<void> {
    if (this.section === CP_STATIONS) {
      await this.loadStations();
    } else if (this.section === CP_RECORDS) {
      await this.loadRecords(this.recordPage);
    } else if (this.section === CP_QUEUE || this.section === CP_SCANS) {
      await (this.isScanSection() ? this.loadScans() : this.loadQueue());
    }
  }

  /**
   * 待打印 / 扫描文档共用的列表外壳。
   *
   * ⚠️ **不接参数**，全部读 `this.*`：`@Builder` 的普通参数是**按值传递、不参与刷新**的，
   * 把 `@State` 的值当参数传进来会让界面永远停在首帧（本项目踩过，见 MEMORY）。
   * 需要「按引用」时只能用单个对象字面量参数 `$$`，这里没必要。
   */
  @Builder
  documentBody() {
    Column() {
      // 上传进度（只在有传输时出现，位置固定在列表上方）
      if (this.uploadBusy) {
        Row({ space: 8 }) {
          LoadingProgress()
            .width(18)
            .height(18)
            .color(AppColor.brand)
          Text(this.uploadNote)
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textSecondary)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .padding(AppSize.cardPadding)
        .borderRadius(AppSize.cardRadius)
        .backgroundColor(AppColor.surface)
        .margin({ bottom: 8 })
      }

      if (this.docsState() === LoadState.LOADING) {
        LoadingView({ message: this.isScanSection() ? '正在读取扫描文档…' : '正在读取待打印文档…' })
      } else if (this.docsState() === LoadState.ERROR) {
        ErrorView({
          message: this.docsError(),
          onRetry: () => {
            this.reloadDocs();
          }
        })
      } else if (this.docsOf().length === 0) {
        EmptyView({ message: this.isScanSection() ? '暂无扫描文档' : '暂无待打印任务' })
      } else {
        Row({ space: 4 }) {
          Text('共 ' + this.docsOf().length.toString() +
            (this.isScanSection() ? ' 份扫描件' : ' 份文档'))
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textTertiary)
            .layoutWeight(1)
          Text(this.sortNewest ? '最新在前' : '最早在前')
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textSecondary)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .onClick(() => {
              this.toggleSort();
            })
          Text('刷新')
            .fontSize(AppFont.caption)
            .fontColor(AppColor.brand)
            .padding({ left: 4, right: 2, top: 6, bottom: 6 })
            .onClick(() => {
              this.reloadDocs();
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ bottom: 8 })

        Column() {
          ForEach(this.docsOf(), (item: PrintDocument, index: number) => {
            if (this.isScanSection()) {
              this.scanRow(item)
            } else {
              this.printRow(item)
            }
            if (index < this.docsOf().length - 1) {
              Divider().color(AppColor.divider).strokeWidth(0.5)
            }
          }, (item: PrintDocument) =>
            (this.isScanSection() ? 's-' : 'q-') + item.id + item.date + item.time)
        }
        .width('100%')
        .padding({ left: AppSize.cardPadding, right: AppSize.cardPadding, top: 4, bottom: 4 })
        .borderRadius(AppSize.cardRadius)
        .backgroundColor(AppColor.surface)
        .margin({ bottom: this.selecting ? 72 : 0 })
      }
    }
    .width('100%')
    .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
  }

  @Builder
  stationBody() {
    Column({ space: 12 }) {
      if (this.stationState === LoadState.LOADING) {
        LoadingView({ message: '正在读取打印点状态…' })
      } else if (this.stationState === LoadState.ERROR) {
        ErrorView({
          message: this.stationError,
          onRetry: () => {
            this.loadStations();
          }
        })
      } else if (this.stations.length === 0) {
        EmptyView({ message: '暂无可显示的打印点' })
      } else {
        Row() {
          Text('设备状态')
            .fontSize(AppFont.subtitle)
            .fontWeight(FontWeight.Medium)
            .fontColor(AppColor.textPrimary)
            .layoutWeight(1)
          Text('刷新')
            .fontSize(AppFont.caption)
            .fontColor(AppColor.brand)
            .padding({ left: 12, right: 2, top: 6, bottom: 6 })
            .onClick(() => {
              this.loadStations();
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        ForEach(this.stationGroups(), (group: string) => {
          Column({ space: 8 }) {
            Text(group)
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textSecondary)
              .width('100%')

            Column() {
              ForEach(this.stationsOf(group), (item: PrintStation, index: number) => {
                this.stationRow(item)
                if (index < this.stationsOf(group).length - 1) {
                  Divider().color(AppColor.divider).strokeWidth(0.5)
                }
              }, (item: PrintStation) => 'st-' + item.name + '-' + item.state)
            }
            .width('100%')
            .padding({ left: AppSize.cardPadding, right: AppSize.cardPadding, top: 2, bottom: 2 })
            .borderRadius(AppSize.cardRadius)
            .backgroundColor(AppColor.surface)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }, (group: string) => 'grp-' + group)
      }
    }
    .width('100%')
    .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
  }

  /**
   * 使用记录。
   *
   * 根 Column **不带左右 padding** —— 类型胶囊行要和顶部胶囊行一样全出血，
   * 留白下放到日期行与列表外壳上（同 docs/tech/chips-edge-fade.md 的规矩）。
   */
  @Builder
  recordBody() {
    Column({ space: 10 }) {
      // 日期区间：`自 [2026-10-23] 至 [2026-11-21]` —— 「自 / 至」是日期选择器**外面**的
      // 文字标签，只有两个日期本身是可点的胶囊（点开系统日期选择器）；日期带年份，跨年不歧义
      Row({ space: 8 }) {
        Text('自')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textTertiary)
        Text(pillDate(this.recordBegin))
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textPrimary)
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .borderRadius(16)
          .backgroundColor(AppColor.surface)
          .onClick(() => {
            this.pickRecordDate(true);
          })
        Text('至')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textTertiary)
        Text(pillDate(this.recordEnd))
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textPrimary)
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .borderRadius(16)
          .backgroundColor(AppColor.surface)
          .onClick(() => {
            this.pickRecordDate(false);
          })
      }
      .width('100%')
      .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
      .alignItems(VerticalAlign.Center)

      // 类型胶囊（打印 / 复印 / 扫描）：与顶部同一套组件 + 渐隐，单选
      Scroll() {
        Row() {
          FilterChip({
            label: '打印',
            controlled: true,
            active: this.recordKind === RECORD_KIND_PRINT,
            initialSelected: this.recordKind === RECORD_KIND_PRINT,
            onTap: () => {
              this.selectRecordKind(RECORD_KIND_PRINT);
            }
          })
          FilterChip({
            label: '复印',
            controlled: true,
            active: this.recordKind === RECORD_KIND_COPY,
            initialSelected: this.recordKind === RECORD_KIND_COPY,
            onTap: () => {
              this.selectRecordKind(RECORD_KIND_COPY);
            }
          })
          FilterChip({
            label: '扫描',
            controlled: true,
            active: this.recordKind === RECORD_KIND_SCAN,
            initialSelected: this.recordKind === RECORD_KIND_SCAN,
            onTap: () => {
              this.selectRecordKind(RECORD_KIND_SCAN);
            }
          })
        }
        .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
      }
      .width('100%')
      .scrollBar(BarState.Off)
      .scrollable(ScrollDirection.Horizontal)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .align(Alignment.Center)
      .clip(false)
      .onAreaChange((_old: Area, now: Area) => {
        const height: number = Number(now.height);
        if (height > 0 && Math.abs(height - this.kindRowH) > 0.5) {
          this.kindRowH = height;
        }
      })
      .overlay(this.kindEdgeFade(), { align: Alignment.Center })

      Column() {
        if (this.recordState === LoadState.LOADING) {
          LoadingView({ message: '正在查询使用记录…' })
        } else if (this.recordState === LoadState.ERROR) {
          ErrorView({
            message: this.recordError,
            onRetry: () => {
              this.loadRecords(this.recordPage);
            }
          })
        } else if (this.records.length === 0) {
          EmptyView({ message: '该日期范围内没有记录' })
        } else {
          Column() {
            ForEach(this.records, (item: PrintRecord, index: number) => {
              this.recordRow(item)
              if (index < this.records.length - 1) {
                Divider().color(AppColor.divider).strokeWidth(0.5)
              }
            }, (item: PrintRecord) => 'rc-' + item.date + item.time + item.pages +
              item.freeCents.toString())
          }
          .width('100%')
          .padding({ left: AppSize.cardPadding, right: AppSize.cardPadding, top: 4, bottom: 4 })
          .borderRadius(AppSize.cardRadius)
          .backgroundColor(AppColor.surface)

          // 翻页（服务端每页固定 5 条）
          Row({ space: 16 }) {
            Text('上一页')
              .fontSize(AppFont.caption)
              .fontColor(this.recordPage > 1 ? AppColor.brand : AppColor.textTertiary)
              .padding({ top: 6, bottom: 6 })
              .onClick(() => {
                if (this.recordPage > 1) {
                  this.loadRecords(this.recordPage - 1);
                }
              })
            Text('第 ' + this.recordPage.toString() + ' / ' +
              Math.max(this.recordTotalPages, 1).toString() + ' 页')
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textSecondary)
            Text('下一页')
              .fontSize(AppFont.caption)
              .fontColor(this.recordPage < this.recordTotalPages ?
                AppColor.brand : AppColor.textTertiary)
              .padding({ top: 6, bottom: 6 })
              .onClick(() => {
                if (this.recordPage < this.recordTotalPages) {
                  this.loadRecords(this.recordPage + 1);
                }
              })
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .margin({ top: 12 })
        }
      }
      .width('100%')
      .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
    }
    .width('100%')
  }

  @Builder
  helpBody() {
    Column({ space: 12 }) {
      Column() {
        ForEach(HELP_ITEMS, (item: HelpItem, index: number) => {
          Column({ space: 4 }) {
            Text(item.title)
              .fontSize(AppFont.body)
              .fontWeight(FontWeight.Medium)
              .fontColor(AppColor.textPrimary)
              .width('100%')
            Text(item.body)
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textSecondary)
              .width('100%')
              .lineHeight(19)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ top: 10, bottom: 10 })
          if (index < HELP_ITEMS.length - 1) {
            Divider().color(AppColor.divider).strokeWidth(0.5)
          }
        }, (item: HelpItem) => 'help-' + item.title)
      }
      .width('100%')
      .padding({ left: AppSize.cardPadding, right: AppSize.cardPadding, top: 4, bottom: 4 })
      .borderRadius(AppSize.cardRadius)
      .backgroundColor(AppColor.surface)

      Text('上传、打印参数设置、预览、下载与删除均可在本页完成；取件与扫描请到图书馆自助设备。')
        .fontSize(AppFont.caption)
        .fontColor(AppColor.textTertiary)
        .width('100%')
    }
    .width('100%')
    .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
  }

  /* ------------------------------ 浮层 ------------------------------ */

  /**
   * 上传入口（待打印分区专用）。
   *
   * 用「整屏透明容器 + 末尾对齐」定位，**不用 `position`/`markAnchor`**：
   * 那两者在这条链上都不可靠（`position` 的百分比会解析成 0、`markAnchor` 无效）。
   * 容器设 `HitTestMode.Transparent`，空白处的触摸仍然落到下面的滚动内容上。
   */
  @Builder
  uploadFabLayer() {
    Column() {
      Row() {
        Blank()
        Row({ space: 6 }) {
          if (this.uploadBusy) {
            LoadingProgress()
              .width(16)
              .height(16)
              .color(Color.White)
          }
          Text(this.uploadBusy ? '上传中' : '上传')
            .fontSize(AppFont.body)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
        }
        .padding({ left: 18, right: 20, top: 11, bottom: 11 })
        .borderRadius(24)
        .backgroundColor(AppColor.brand)
        .opacity(this.uploadBusy ? 0.65 : 1)
        .onClick(() => {
          this.pickAndUpload();
        })
      }
      .width('100%')
    }
    .width('100%')
    // ⚠️ 这里**不能**写成全屏容器（`height('100%')` + 末尾对齐）：
    // 铺满整页的透明兄弟节点会参与触摸测试，抢走落在列表上的拖拽 ——
    // 表现就是「列表滑到尽头后再滑没有回弹」（用户实测）。只占底部一条，
    // 列表的拖拽才能完整落到下面的 `Scroll`。
    .padding({
      left: AppSize.pagePadding,
      right: AppSize.pagePadding,
      bottom: AppSize.contentBottomInset + 12
    })
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /** 多选操作条（底部浮动，沉浸材质）。 */
  @Builder
  selectionBarLayer() {
    Column() {
      Stack() {
        if (this.materialActive) {
          MaterialCardLayer({ layerRadius: AppSize.cardRadius, layerShadow: false })
        }
        Row({ space: 10 }) {
          Text('已选 ' + this.pickedDocs().length.toString())
            .fontSize(AppFont.body)
            .fontColor(AppColor.textPrimary)
            .layoutWeight(1)
          Text(this.pickedDocs().length === this.currentDocs().length ? '取消全选' : '全选')
            .fontSize(AppFont.caption)
            .fontColor(AppColor.brand)
            .padding({ left: 8, right: 8, top: 6, bottom: 6 })
            .onClick(() => {
              this.toggleSelectAll();
            })
          Text('删除')
            .fontSize(AppFont.caption)
            .fontColor(Color.White)
            .padding({ left: 14, right: 14, top: 7, bottom: 7 })
            .borderRadius(16)
            .backgroundColor(this.pickedDocs().length > 0 ? AppColor.danger : AppColor.surfaceSubtle)
            .onClick(() => {
              this.confirmDelete(this.pickedDocs(), this.isScanSection());
            })
          Text('完成')
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textSecondary)
            .padding({ left: 6, right: 2, top: 6, bottom: 6 })
            .onClick(() => {
              this.exitSelecting();
            })
        }
        .width('100%')
        .padding({ left: AppSize.cardPadding, right: AppSize.cardPadding, top: 10, bottom: 10 })
        .borderRadius(AppSize.cardRadius)
      }
      .width('100%')
      .borderRadius(AppSize.cardRadius)
      .backgroundColor(this.materialActive ? Color.Transparent : AppColor.surface)
      .backdropBlur(this.materialActive ? 0 : AppMaterial.blurSmall)
    }
    .width('100%')
    // 同上：只占底部一条，不做全屏透明兄弟节点，避免抢走列表拖拽
    .padding({
      left: AppSize.pagePadding,
      right: AppSize.pagePadding,
      bottom: AppSize.contentBottomInset + 8
    })
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /** 预览浮层（整页覆盖，逐页翻）。 */
  @Builder
  previewLayer() {
    Column() {
      Row({ space: 8 }) {
        Text(this.previewDoc === null ? '预览' : '第 ' + this.previewPageNo.toString() + ' 页')
          .fontSize(AppFont.subtitle)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .layoutWeight(1)
        if (this.previewDoc !== null && this.previewDoc.pages.length > 0) {
          Text('共 ' + this.previewDoc.pages + ' 页')
            .fontSize(AppFont.caption)
            .fontColor('#B3FFFFFF')
        }
        // 「关闭」做成**按钮**（原来只是一行可点文字，没有边界、看不出能点）：
        // 胶囊形，底下垫一层沉浸材质；材质不可用时退回半透明白底。
        Stack() {
          if (this.materialActive) {
            MaterialCardLayer({ layerRadius: 16, layerShadow: false })
          }
          Text('关闭')
            .fontSize(AppFont.caption)
            .fontColor(Color.White)
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .borderRadius(16)
            .backgroundColor(this.materialActive ? Color.Transparent : '#33FFFFFF')
            .onClick(() => {
              this.closePreview();
            })
        }
        .borderRadius(16)
        .backgroundColor(Color.Transparent)
        .accessibilityGroup(true)
        .accessibilityText('关闭预览')
      }
      .width('100%')
      .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
      .alignItems(VerticalAlign.Center)

      Stack({ alignContent: Alignment.Center }) {
        if (this.previewSrc.length > 0) {
          Image(this.previewSrc)
            .objectFit(ImageFit.Contain)
            .width('100%')
            .height('100%')
        }
        if (this.previewBusy || this.previewSrc.length === 0) {
          LoadingProgress()
            .width(40)
            .height(40)
            .color(Color.White)
        }
      }
      .width('100%')
      .layoutWeight(1)

      Row({ space: 24 }) {
        Text('上一页')
          .fontSize(AppFont.caption)
          .fontColor(this.previewPageNo > 1 ? Color.White : '#66FFFFFF')
          .padding({ top: 10, bottom: 10 })
          .onClick(() => {
            if (this.previewPageNo > 1 && !this.previewBusy) {
              this.loadPreviewPage(this.previewPageNo - 1);
            }
          })
        Text('下一页')
          .fontSize(AppFont.caption)
          .fontColor(this.previewDoc !== null && this.previewPageNo < Number(this.previewDoc.pages) ?
            Color.White : '#66FFFFFF')
          .padding({ top: 10, bottom: 10 })
          .onClick(() => {
            if (this.previewDoc !== null && this.previewPageNo < Number(this.previewDoc.pages) &&
              !this.previewBusy) {
              this.loadPreviewPage(this.previewPageNo + 1);
            }
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ bottom: 12 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F2000000')
  }

  /** 原页面内容。下拉刷新由外层 `build()` 的 PullToRefresh 提供。 */
  @Builder
  pageContent() {
    // alignContent 取 Bottom：底部浮条（上传按钮 / 多选条）靠自身高度贴底，
    // 不再需要「全屏 + 末尾对齐」的全屏透明层（那会抢走列表拖拽，见 uploadFabLayer 注释）。
    Stack({ alignContent: Alignment.Bottom }) {
      Scroll() {
        // ⚠️ **这一层不能有左右 padding**：胶囊行要做成「0 → 屏幕宽」的全出血，
        // 全靠它是 Scroll 的直接父级。左右留白下放到各子块（见 ChipsEdgeFade 文档）。
        Column({ space: AppSize.gap }) {
          this.sectionBar()

          if (this.section === CP_QUEUE) {
            this.documentBody()
          } else if (this.section === CP_SCANS) {
            this.documentBody()
          } else if (this.section === CP_STATIONS) {
            this.stationBody()
          } else if (this.section === CP_RECORDS) {
            this.recordBody()
          } else {
            this.helpBody()
          }

          Blank().height(AppSize.contentBottomInset)
        }
        .width('100%')
        .padding({
          // 顶部不用再避让「状态栏 + 标题栏」—— HDS 的组件安全区已整块扣掉
          top: AppSize.destTopInset(topSafeInsetVp()),
          bottom: 0
        })
        .constraintSize({ minHeight: '100%' })
      }
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      // 沉浸光感三件套（配合 HDS 标题栏的 enableComponentSafeArea）
      .clip(false)
      .expandSafeArea()
      .width('100%')
      .height('100%')
      .backgroundColor(AppColor.pageBackground)

      if (this.section === CP_QUEUE && !this.selecting && !this.previewVisible) {
        this.uploadFabLayer()
      }
      if (this.selecting) {
        this.selectionBarLayer()
      }
      if (this.previewVisible) {
        this.previewLayer()
      }
    }
    .width('100%')
    .height('100%')
  }

  build() {
    PullToRefresh({
      onRefresh: () => this.refreshCurrentSection(),
      contentBuilder: () => {
        this.pageContent();
      }
    })
  }
}
