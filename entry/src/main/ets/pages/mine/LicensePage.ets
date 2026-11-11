import { AppConfig } from '../../common/AppConfig';
import { AppColor, AppFont, AppSize } from '../../components/AppTheme';
import { topSafeInsetVp } from '../../common/ImmersiveUtil';

/** MIT 许可证原文（逐行保存，便于按行渲染并保持换行语义）。 */
const MIT_LICENSE_LINES: string[] = [
  'MIT License',
  '',
  'Copyright (c) 2026 BUAASubnet',
  '',
  'Permission is hereby granted, free of charge, to any person obtaining a copy',
  'of this software and associated documentation files (the "Software"), to deal',
  'in the Software without restriction, including without limitation the rights',
  'to use, copy, modify, merge, publish, distribute, sublicense, and/or sell',
  'copies of the Software, and to permit persons to whom the Software is',
  'furnished to do so, subject to the following conditions:',
  '',
  'The above copyright notice and this permission notice shall be included in all',
  'copies or substantial portions of the Software.',
  '',
  'THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR',
  'IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,',
  'FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE',
  'AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER',
  'LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,',
  'OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE',
  'SOFTWARE.'
];

/**
 * 开源许可页。
 *
 * ## 为什么必须有这一页
 *
 * 上游 UBAA 以 MIT 许可证发布，其条款要求「在所有副本或实质性部分中保留上述版权
 * 声明与本许可声明」。把 LICENSE 文件放在代码仓库里只满足「随源码分发」，
 * 应用安装包是独立分发形态，必须在**应用内**可见，否则不满足 MIT 的随附义务。
 *
 * 同时这一页也是向用户和审核方说明「本应用来源与维护主体」的正式位置。
 */
@Component
export struct LicensePage {
  build() {
    Scroll() {
      Column({ space: AppSize.gapLarge }) {
        // 来源与维护主体
        Column({ space: 8 }) {
          Text('本应用基于开源项目 UBAA 开发')
            .fontSize(AppFont.subtitle)
            .fontWeight(FontWeight.Medium)
            .fontColor(AppColor.textPrimary)
            .width('100%')
          Text('上游项目：' + AppConfig.ORIGINAL_PROJECT_NAME)
            .fontSize(AppFont.body)
            .fontColor(AppColor.textSecondary)
            .width('100%')
          Text(AppConfig.ORIGINAL_PROJECT_URL)
            .fontSize(AppFont.caption)
            .fontColor(AppColor.brand)
            .width('100%')
          Text('本鸿蒙版本由个人开发者独立开发与维护，非学校官方应用。' +
            '按照上游要求，在应用介绍与「关于」页注明本版本基于 UBAA 开发、与本项目独立维护。')
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textTertiary)
            .lineHeight(20)
            .width('100%')
          Text(AppConfig.THIS_PROJECT_URL)
            .fontSize(AppFont.caption)
            .fontColor(AppColor.brand)
            .width('100%')
        }
        .width('100%')
        .padding(AppSize.cardPadding)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor(AppColor.surface)
        .borderRadius(AppSize.cardRadius)

        // 许可证原文
        Column({ space: 8 }) {
          Text('MIT License 全文')
            .fontSize(AppFont.subtitle)
            .fontWeight(FontWeight.Medium)
            .fontColor(AppColor.textPrimary)
            .width('100%')
          Text('上游以 MIT 许可证发布，本应用作为其衍生作品，同样以 MIT 许可证分发。')
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textTertiary)
            .lineHeight(20)
            .width('100%')
          Column({ space: 2 }) {
            ForEach(MIT_LICENSE_LINES, (line: string, index: number) => {
              Text(line.length > 0 ? line : ' ')
                .fontSize(12)
                .fontColor(AppColor.textSecondary)
                .lineHeight(18)
                .width('100%')
            }, (line: string, index: number) => 'mit-' + index)
          }
          .width('100%')
          .padding(12)
          .alignItems(HorizontalAlign.Start)
          .backgroundColor(AppColor.surfaceSubtle)
          .borderRadius(8)
        }
        .width('100%')
        .padding(AppSize.cardPadding)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor(AppColor.surface)
        .borderRadius(AppSize.cardRadius)

        Blank()
          .height(AppSize.gapLarge)
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
