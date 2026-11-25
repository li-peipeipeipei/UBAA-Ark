import { image } from '@kit.ImageKit';
import { scanCore, generateBarcode } from '@kit.ScanKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../common/Logger';
import { Toast } from '../common/Toast';
import { ApiError } from '../network/ApiError';
import { LocalSigninService } from '../network/LocalSigninService';
import { AppColor, AppFont, AppSize } from './AppTheme';
import { MaterialCardLayer } from './MaterialCardLayer';

/**
 * 课堂签到二维码浮层。
 *
 * ## 它是干什么的
 *
 * 上游的扫码签到链路里，二维码内容是
 * `stu_scan_sign.action?courseSchedId=X&timestamp=T`。把这张码显示出来，
 * 让对方（i北航 App → 工作台 → 智慧教室 → 扫一扫）扫，等同于「替对方完成扫码这一步」。
 *
 * ## 三个时间常量都不是随便定的
 *
 * - 实时展示 2 秒刷一次：时间戳会过期，停在屏上的旧码扫不开；
 * - 「保存到相册」额外 +2 秒：图片是静态的，留一点余量让对方掏出手机时还在有效期内；
 * - 已签到每 3 秒查一次：面板开着的时候对方可能已经扫完了，不轮询就得让用户自己退出去看。
 *
 * ## 为什么不用 bindSheet
 *
 * `bindSheet` 的 content 是 `@Builder`，而 `@Builder` 的普通参数**按值传递、
 * 不参与刷新** —— 先开 A 课的码、关掉、再开 B 课，builder 不会重跑，
 * 面板还会显示 A 课（项目里 `GradeHeader` / `BykcFilterChip` 都踩过这个坑）。
 * 用 `if` 包裹的自绘浮层，条件切换时子树整体重建，`@Prop` 每次拿到的是新值。
 */
@Component
export struct SigninQrSheet {
  /** 课程排课标识（上游 `courseSchedId`）。 */
  @Prop @Watch('onCourseChanged') courseId: string = '';
  /** 课程名，仅用于标题。 */
  @Prop courseName: string = '';
  /**
   * 内嵌模式：不画遮罩、不显示关闭按钮、宽度吃满父容器。
   *
   * 平板横屏的「左列表 + 右签到区」把这张码常驻在右栏，此时它是页面内容的一部分，
   * 不是浮层（浮层会盖住左侧列表，扫码时看不到别的课）。
   */
  @Prop embedded: boolean = false;
  /**
   * 无壳模式：不画自己的卡片底色 / 内边距 / 圆角 / 投影，由外层弹窗承载。
   * 手机端弹窗复用本组件时打开，避免「玻璃弹窗里再套一张实心卡」。
   */
  @Prop bare: boolean = false;
  /** 外层弹窗是否启用沉浸材质；用于让「保存到相册」与弹窗「关闭」按钮同款。 */
  @Prop materialActive: boolean = false;
  /**
   * 已知的课程签到状态。已签到的课仍显示二维码（用户要求），但用它做初始值，
   * 避免每张卡都从 false 起步、3 秒轮询时对已签到的课反复弹「已签到」Toast。
   */
  @Prop initialSigned: boolean = false;
  /**
   * 未签到时显示的状态提示（由页面按课堂时间窗算好）：
   * 可扫码签到 / 签到未开始，无法扫码签到 / 课堂已结束，无法扫码签到。
   * 已签到时组件内的 `signed` 优先，显示「这门课已签到」，不受本字段影响。
   */
  @Prop statusHint: string = '';
  /** 状态提示是否为「可签到」的正向色（绿），否则用次要灰。 */
  @Prop statusPositive: boolean = false;
  /** 由页面实现：现在这门课是否已经签到了。 */
  onCheckSigned: () => Promise<boolean> = async (): Promise<boolean> => false;
  /** 关闭面板（点遮罩或右上角）。内嵌模式不会触发。 */
  onClose: () => void = () => {
  };

  @State private pixelMap: image.PixelMap | undefined = undefined;
  @State private errorText: string = '';
  @State private saving: boolean = false;
  @State private signed: boolean = false;

  private refreshTimer: number = -1;
  private statusTimer: number = -1;
  /** 组件已销毁：异步回调回来时用它挡住对已释放状态的写入。 */
  private disposed: boolean = false;

  aboutToAppear(): void {
    // 已签到课程由调用方直接告知初值，避免轮询时对已签到的课反复弹 Toast
    this.signed = this.initialSigned;
    this.refresh();
    this.checkSigned();
    this.refreshTimer = setInterval(() => {
      this.refresh();
    }, 2000);
    this.statusTimer = setInterval(() => {
      this.checkSigned();
    }, 3000);
  }

  aboutToDisappear(): void {
    this.disposed = true;
    if (this.refreshTimer >= 0) {
      clearInterval(this.refreshTimer);
      this.refreshTimer = -1;
    }
    if (this.statusTimer >= 0) {
      clearInterval(this.statusTimer);
      this.statusTimer = -1;
    }
    const pending: image.PixelMap | undefined = this.pixelMap;
    this.pixelMap = undefined;
    SigninQrSheet.release(pending);
  }

  /**
   * 内嵌模式下换了课：定时器还在跑，但「已签到」是上一门课的结论，
   * 必须立刻复位并重取，否则会显示「这门课已签到」而其实没签。
   */
  private onCourseChanged(): void {
    if (!this.embedded) {
      return;
    }
    this.signed = false;
    this.errorText = '';
    this.refresh();
    this.checkSigned();
  }

  build() {
    if (this.embedded) {
      // 内嵌：只有面板本体，没有遮罩层
      this.panelBody()
    } else {
      Stack({ alignContent: Alignment.Center }) {
        // 遮罩：点一下关闭。二维码面板是「看一眼就走」的东西，不拦着用户。
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#66000000')
          .onClick(() => {
            this.onClose();
          })

        this.panelBody()
      }
      .width('100%')
      .height('100%')
    }
  }

  @Builder
  panelBody() {
    Column({ space: 14 }) {
      this.header()

      // 二维码区固定 232vp 高：加载中转圈、加载后图片、失败提示都落在同一块占位里，
      // 弹窗从弹出那一刻高度就确定，不会在码生成前后跳一下。
      Stack() {
        if (this.errorText.length > 0) {
          Column({ space: 8 }) {
            Text(this.errorText)
              .fontSize(AppFont.body)
              .fontColor(AppColor.danger)
              .textAlign(TextAlign.Center)
              .width('100%')
            Text('下拉刷新或重开一次面板可重试')
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textSecondary)
          }
        } else if (this.pixelMap === undefined) {
          Column({ space: 12 }) {
            LoadingProgress()
              .width(48)
              .height(48)
              .color(AppColor.brand)
            Text('正在生成签到码…')
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textSecondary)
          }
        } else {
          // 图片底色固定纯白：黑码必须白底才扫得出。此前去掉白底后，
          // 弹窗的品牌蓝玻璃底透过透明容器，码看起来发蓝 —— 这里显式刷回纯白。
          Image(this.pixelMap)
            .width(232)
            .height(232)
            .objectFit(ImageFit.Contain)
            .interpolation(ImageInterpolation.None)
            .backgroundColor(Color.White)
        }
      }
      .width('100%')
      .height(232)

      // 状态文案：已签到优先显示「这门课已签到」；否则显示页面算好的时间窗提示。
      if (this.signed) {
        Text('这门课已签到')
          .fontSize(AppFont.body)
          .fontColor(AppColor.success)
          .textAlign(TextAlign.Center)
          .width('100%')
      } else if (this.statusHint.length > 0) {
        Text(this.statusHint)
          .fontSize(AppFont.body)
          .fontColor(this.statusPositive ? AppColor.success : AppColor.textSecondary)
          .textAlign(TextAlign.Center)
          .width('100%')
      }
      // 扫码路径提示常驻：已签到的课二维码也给别人扫（用户要求），提示不能跟着消失。
      // 两行均居中：第一行用途，第二行扫码路径。
      Column({ space: 2 }) {
        Text('供其他同学扫码签到')
          .fontSize(AppFont.body)
          .fontColor(AppColor.textPrimary)
          .textAlign(TextAlign.Center)
          .width('100%')
        Text('i北航App-工作台-智慧教室-扫一扫')
          .fontSize(AppFont.body)
          .fontColor(AppColor.textPrimary)
          .textAlign(TextAlign.Center)
          .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)

      Text('二维码每 2 秒自动刷新；码在使用前请勿截图外传。')
        .fontSize(AppFont.caption)
        .fontColor(AppColor.textTertiary)
        .textAlign(TextAlign.Center)
        .width('100%')

      // 与外层弹窗「关闭」按钮完全同款：材质画布 + 品牌玻璃底 + 同字号/高度/圆角。
      Stack() {
        if (this.materialActive) {
          MaterialCardLayer({ layerRadius: 22, layerShadow: false })
        }
        Button(this.saving ? '正在保存…' : '保存到相册')
          .fontSize(AppFont.subtitle)
          .fontColor(AppColor.textOnBrand)
          .height(44)
          .width('100%')
          .borderRadius(22)
          .backgroundColor(this.materialActive ? AppColor.brandGlass : AppColor.brand)
          .enabled(!this.saving && this.pixelMap !== undefined)
          .onClick(() => {
            this.save();
          })
      }
      .width('100%')
      .height(44)
    }
    .width(this.embedded ? '100%' : '84%')
    // 内嵌（平板右栏 / 手机弹窗）吃满父容器、不再限宽 —— 与同列其它块等宽；
    // 独立浮层仍限 360，超过就不是「一张卡片」而是「一块板」了。
    .constraintSize({ maxWidth: this.embedded ? 2000 : 360 })
    .padding(this.bare ? 0 : 20)
    // 卡片跟随主题（浅色白 / 深色深灰）；只有二维码图像自身保留白底用于扫码，
    // 卡片与图像容器都不再刷白，深色模式下不会出现一圈突兀的白框。
    // bare（弹窗内）连卡片底都不要，交给同步课程详情弹窗的外壳。
    .backgroundColor(this.bare ? Color.Transparent : AppColor.surface)
    .borderRadius(this.bare ? 0 : (this.embedded ? AppSize.cardRadius : AppSize.sheetRadius))
    // 内嵌 / 弹窗内已贴在页面上，再投影会糊出一圈脏边；独立浮层才需要浮起感。
    .shadow({
      radius: this.embedded ? 0 : 24,
      color: this.embedded ? Color.Transparent : '#33000000',
      offsetY: this.embedded ? 0 : 8
    })
  }

  @Builder
  header() {
    Row() {
      Column({ space: 2 }) {
        Text('课堂签到码')
          .fontSize(AppFont.title)
          .fontColor(AppColor.textPrimary)
          .fontWeight(FontWeight.Medium)
        Text(this.courseName)
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textSecondary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (!this.embedded) {
        Button() {
          Text('✕')
            .fontSize(AppFont.body)
            .fontColor(AppColor.textPrimary)
        }
        .width(32)
        .height(32)
        .borderRadius(16)
        .backgroundColor(AppColor.circleButtonSurface)
        .onClick(() => {
          this.onClose();
        })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  /* ------------------------------ 数据 ------------------------------ */

  private static qrOptions(): generateBarcode.CreateOptions {
    const options: generateBarcode.CreateOptions = {
      scanType: scanCore.ScanType.QR_CODE,
      width: 512,
      height: 512,
      margin: 1,
      level: generateBarcode.ErrorCorrectionLevel.LEVEL_H,
      // 官方 CreateOptions 收的是 6 位 RGB（0xFFFFFF / 0x000000），
      // 传 8 位 ARGB 会被错误解析，生成的码底可能不是纯白。
      backgroundColor: 0xFFFFFF,
      pixelMapColor: 0x000000
    };
    return options;
  }

  private static release(target: image.PixelMap | undefined): void {
    if (target === undefined) {
      return;
    }
    target.release().then(() => {
    }).catch((error: BusinessError) => {
      Logger.warn('二维码 PixelMap 释放失败：' + error.message);
    });
  }

  private async refresh(): Promise<void> {
    if (this.disposed) {
      return;
    }
    try {
      const content: string = await LocalSigninService.buildScanQrContent(this.courseId, 0);
      if (this.disposed) {
        return;
      }
      const next: image.PixelMap =
        await generateBarcode.createBarcode(content, SigninQrSheet.qrOptions());
      if (this.disposed) {
        SigninQrSheet.release(next);
        return;
      }
      const previous: image.PixelMap | undefined = this.pixelMap;
      this.pixelMap = next;
      this.errorText = '';
      SigninQrSheet.release(previous);
    } catch (error) {
      if (!this.disposed) {
        this.errorText = error instanceof ApiError
          ? (error as ApiError).friendlyMessage() : '签到码生成失败';
        Logger.warn('签到二维码生成失败：' + this.errorText);
      }
    }
  }

  private async checkSigned(): Promise<void> {
    if (this.disposed || this.signed) {
      return;
    }
    try {
      const done: boolean = await this.onCheckSigned();
      if (!this.disposed && done) {
        this.signed = true;
        Toast.show('这门课已签到');
      }
    } catch (error) {
      // 轮询失败不打扰用户：面板本身还能扫码，下一次轮询会自己恢复
      Logger.warn('签到状态轮询失败');
    }
  }

  /* ------------------------------ 保存 ------------------------------ */

  private async save(): Promise<void> {
    if (this.saving) {
      return;
    }
    this.saving = true;
    let tempPath: string = '';
    try {
      // 保存用的是「静态图」，比屏上那张多留 2 秒余量
      const content: string = await LocalSigninService.buildScanQrContent(this.courseId, 2000);
      const pixelMap: image.PixelMap =
        await generateBarcode.createBarcode(content, SigninQrSheet.qrOptions());

      const packer: image.ImagePacker = image.createImagePacker();
      const option: image.PackingOption = { format: 'image/png', quality: 100 };
      let buffer: ArrayBuffer;
      try {
        // 用 packToData 而不是已废弃的 packing；注意编码完成前**不能**释放 pixelMap，
        // 否则会拿到 401「参数异常」，官方把它列在 image-common-mistakes 里。
        buffer = await packer.packToData(pixelMap, option);
      } finally {
        await packer.release();
        SigninQrSheet.release(pixelMap);
      }

      const context: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      tempPath = context.cacheDir + '/' + util.generateRandomUUID() + '.png';
      const file: fileIo.File = fileIo.openSync(
        tempPath, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE);
      try {
        if (fileIo.writeSync(file.fd, buffer) !== buffer.byteLength) {
          throw new Error('图片未完整写入');
        }
      } finally {
        fileIo.closeSync(file);
      }

      /**
       * 走「弹窗授权」而不是申请 `ohos.permission.WRITE_IMAGEVIDEO`：
       * 官方对图片保存的推荐路径就是安全控件 / 弹窗授权，两者都**不需要声明权限**，
       * 用户点一次确认即可，应用也不会长期持有相册写权限。
       */
      const helper: photoAccessHelper.PhotoAccessHelper =
        photoAccessHelper.getPhotoAccessHelper(context);
      let targetUri: string = '';
      try {
        const config: photoAccessHelper.PhotoCreationConfig = {
          title: 'UBAA-签到码-' + this.courseId,
          fileNameExtension: 'png',
          photoType: photoAccessHelper.PhotoType.IMAGE
        };
        const uris: Array<string> = await helper.showAssetsCreationDialog(
          [fileUri.getUriFromPath(tempPath)], [config]);
        if (uris.length === 0) {
          // 用户取消了授权：不是错误，不弹提示
          return;
        }
        targetUri = uris[0];
      } finally {
        await helper.release();
      }

      const target: fileIo.File = fileIo.openSync(targetUri, fileIo.OpenMode.WRITE_ONLY);
      try {
        if (fileIo.writeSync(target.fd, buffer) !== buffer.byteLength) {
          throw new Error('图片未完整写入');
        }
      } finally {
        fileIo.closeSync(target);
      }
      Toast.show('签到码已保存到相册');
    } catch (error) {
      Logger.warn('签到码保存失败：' + (error instanceof Error ? error.message : '未知错误'));
      Toast.show('签到码保存失败，请检查存储权限或稍后重试');
    } finally {
      this.saving = false;
      if (tempPath.length > 0) {
        try {
          fileIo.unlinkSync(tempPath);
        } catch (error) {
          Logger.warn('临时签到码文件清理失败');
        }
      }
    }
  }
}
