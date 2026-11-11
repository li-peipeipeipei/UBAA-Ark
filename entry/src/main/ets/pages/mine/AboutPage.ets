import { AppConfig } from '../../common/AppConfig';
import { AppRouter, RouteName } from '../../common/AppRouter';
import { AppColor, AppFont, AppSize } from '../../components/AppTheme';
import { topSafeInsetVp } from '../../common/ImmersiveUtil';
import { InfoRow, SectionCard } from '../../components/CommonViews';

/**
 * 关于页。
 *
 * ## 上架合规要点（改动前请先读）
 *
 * 应用市场上架要求这个页面同时承担三件事，缺一项都可能被审核驳回：
 * 1. **来源与主体声明** —— 明确「基于 UBAA 开发、由个人独立维护、非学校官方应用」。
 *    上游项目方在授权中明确要求在应用介绍中注明这一点，写在这里与商店文案形成互证。
 * 2. **MIT 许可证可达** —— 上游以 MIT 发布，安装包是独立分发形态，必须在应用内可见。
 * 3. **隐私政策可达** —— 商店要求提交政策 URL，审核同时会核对应用内是否有入口。
 *
 * ⚠️ 应用名**不得**使用学校官方应用的名称。当前应用名为 UBAA（上游开源项目名，已获授权）。
 */
@Component
export struct AboutPage {
  stack: NavPathStack = new NavPathStack();

  private openRoute(name: string): void {
    AppRouter.push(this.stack, name);
  }

  /** 菜单行（与「我的」页保持同一视觉规格）。 */
  @Builder
  menuRow(title: string, subtitle: string, icon: Resource, onClick: () => void) {
    Row({ space: AppSize.gap }) {
      SymbolGlyph(icon)
        .fontSize(22)
        .fontColor([AppColor.brand])

      Column({ space: 2 }) {
        Text(title)
          .fontSize(AppFont.body)
          .fontColor(AppColor.textPrimary)
        Text(subtitle)
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textTertiary)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([AppColor.textTertiary])
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .onClick(() => {
      onClick();
    })
  }

  build() {
    Scroll() {
      Column({ space: AppSize.gapLarge }) {
        Column({ space: AppSize.gap }) {
          Image($r('app.media.app_icon'))
            .width(80)
            .height(80)
            .borderRadius(20)
            .draggable(false)
          Text(AppConfig.APP_DISPLAY_NAME)
            .fontSize(AppFont.titleLarge)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColor.textPrimary)
          Text('校园服务聚合客户端 · 鸿蒙原生版')
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textTertiary)
        }
        .width('100%')
        .padding({ top: 24, bottom: 8 })

        SectionCard({ title: '关于本应用', subtitle: '来源与维护主体', showAction: false }) {
          Column() {
            InfoRow({ label: '应用版本', value: AppConfig.APP_VERSION })
            InfoRow({ label: '维护方式', value: '个人开发者独立维护' })
            InfoRow({ label: '项目性质', value: '第三方客户端，非学校官方应用' })
            InfoRow({ label: '上游项目', value: AppConfig.ORIGINAL_PROJECT_NAME, showDivider: false })

            Text('本应用基于开源项目 UBAA 开发，由个人开发者独立维护，' +
              '与学校及相关校内系统的运营方无从属、代理或合作关系，不代表学校提供任何官方服务。' +
              '应用内的全部数据，均由您本人通过统一身份认证登录后自行访问学校系统获得；' +
              '本应用没有自建服务端，不收集、不存储、不转发您的账号与业务数据。')
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textSecondary)
              .lineHeight(20)
              .width('100%')
              .padding({ top: 10 })

            Text('上游项目地址（长按可复制）')
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textTertiary)
              .width('100%')
              .padding({ top: 10 })
            Text(AppConfig.ORIGINAL_PROJECT_URL)
              .fontSize(AppFont.caption)
              .fontColor(AppColor.brand)
              .width('100%')
              .copyOption(CopyOptions.LocalDevice)
          }
          .width('100%')
        }

        SectionCard({ title: '法律与开源', subtitle: '隐私政策与许可证', showAction: false }) {
          Column() {
            this.menuRow('隐私政策', '信息收集范围与使用方式', $r('sys.symbol.doc'), () => {
              this.openRoute(RouteName.PRIVACY);
            })
            Divider().color(AppColor.divider).strokeWidth(0.5)
            this.menuRow('开源许可', 'MIT License · 上游版权声明', $r('sys.symbol.book'), () => {
              this.openRoute(RouteName.LICENSE);
            })
          }
          .width('100%')
        }

        SectionCard({ title: '版本信息', showAction: false }) {
          Column() {
            InfoRow({ label: '应用版本', value: AppConfig.APP_VERSION })
            InfoRow({ label: '目标 API', value: 'HarmonyOS 6.1.0(23)' })
            InfoRow({ label: 'UI 框架', value: 'ArkUI / ArkTS' })
            InfoRow({ label: '设计套件', value: 'UI Design Kit（HDS）', showDivider: false })
          }
          .width('100%')
        }

        SectionCard({ title: '运行模式', showAction: false }) {
          Column() {
            InfoRow({ label: '认证方式', value: '客户端本地统一认证（CAS）' })
            InfoRow({ label: '认证入口', value: AppConfig.UPSTREAM_SSO_HOST })
            InfoRow({ label: '会话校验', value: AppConfig.UPSTREAM_UC_HOST })
            InfoRow({ label: '教务数据源', value: AppConfig.UPSTREAM_BYXT_HOST, showDivider: false })
          }
          .width('100%')
        }

        SectionCard({ title: '已适配的鸿蒙特性', showAction: false }) {
          Column({ space: 6 }) {
            Text('· HdsTabs 悬浮底栏（barFloatingStyle + barOverlap）')
              .fontSize(AppFont.body)
              .fontColor(AppColor.textSecondary)
              .width('100%')
            Text('· 沉浸光感材质（systemMaterialEffect = ADAPTIVE）')
              .fontSize(AppFont.body)
              .fontColor(AppColor.textSecondary)
              .width('100%')
            Text('· HdsNavigation 标题栏渐变模糊（GRADIENT_BLUR）')
              .fontSize(AppFont.body)
              .fontColor(AppColor.textSecondary)
              .width('100%')
            Text('· 全屏布局 + 状态栏 / 导航条安全区避让')
              .fontSize(AppFont.body)
              .fontColor(AppColor.textSecondary)
              .width('100%')
            Text('· 深色模式（resources/dark 色板）')
              .fontSize(AppFont.body)
              .fontColor(AppColor.textSecondary)
              .width('100%')
          }
          .width('100%')
        }

        Blank()
          .height(AppSize.gapLarge)
      }
      .width('100%')
      .padding({
        left: AppSize.pagePadding,
        right: AppSize.pagePadding,
        // 顶部让开「状态栏 + 悬浮标题栏（MINI，56vp）」。留白必须写在滚动内容里、
        // 而不是 DestShell 外壳上：视口仍从屏幕顶开始，内容才能滑进标题栏 + 状态栏
        // 那一段毛玻璃底板（DestShell 用 backdropBlur 补的那层）。
        top: AppSize.destTopInset(topSafeInsetVp()),
        // 底部为悬浮底栏留白。必须留在滚动内容里，不能留给 destination ——
        // 否则底栏背后永远是一块实心底板，毛玻璃透不出内容，看着就是「黑遮罩」。
        bottom: AppSize.contentBottomInset
      })
      .constraintSize({ minHeight: '100%' })
    }
    .scrollBar(BarState.Off)
    // 顶/底拖到边界时回弹（内容不足一屏也生效）
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    // 沉浸光感「三件套」之二 / 之三（配合 titleBar 的 enableComponentSafeArea）：
    //   clip(false)       —— 允许内容画到自身布局矩形之外；
    //   expandSafeArea()  —— 绘制区延伸进标题栏声明的组件安全区。
    // 缺了这两个，内容永远停在标题栏下沿，标题栏的渐变模糊「没东西可糊」。
    .clip(false)
    .expandSafeArea()
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.pageBackground)
  }
}
