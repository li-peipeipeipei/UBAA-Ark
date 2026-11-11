import { AppConfig } from '../../common/AppConfig';
import { AppColor, AppFont, AppSize } from '../../components/AppTheme';
import { topSafeInsetVp } from '../../common/ImmersiveUtil';

/**
 * 隐私政策正文的一节。
 *
 * ⚠️ 不用 `interface` + 匿名对象字面量之外的写法：ArkTS 要求对象字面量必须有
 * 明确的类型上下文，`PolicySection[]` 提供了这个上下文，因此可以直接初始化。
 */
interface PolicySection {
  title: string;
  paragraphs: string[];
}

/** 隐私政策与用户协议。
 *
 * ## 为什么应用内也要有一份全文
 *
 * 华为应用市场要求提交「隐私政策 URL」，同时审核会**在应用内**核对隐私声明是否
 * 可达、内容与申报一致。只给网页不给应用内入口，是常见的驳回原因之一。
 *
 * 本节内容与 `docs/legal/privacy-policy.md` 保持同步 —— 改一份必须改另一份。
 */
@Component
export struct PrivacyPage {
  private sections: PolicySection[] = [
    {
      title: '一、引言',
      paragraphs: [
        'UBAA（以下称「本应用」）是由个人开发者基于开源项目 UBAA 独立开发并维护的第三方校园服务客户端，' +
          '不是任何学校的官方应用，也不代表任何学校提供官方服务。',
        '本应用尊重并保护所有使用者的个人信息。本政策说明本应用会处理哪些信息、为何处理、' +
          '如何处理、是否对外提供，以及您如何管理这些信息。请您在使用前完整阅读。',
        '本应用的运行前提是：您本人已持有学校统一身份认证账号，并自愿用该账号登录、' +
          '查看属于您本人的校园数据。本应用不提供任何他人数据的查询能力。'
      ]
    },
    {
      title: '二、我们处理的信息',
      paragraphs: [
        '1. 统一身份认证凭据：您在登录页填写的学号（或统一认证账号）与密码。该凭据仅用于向学校统一认证' +
          '服务（sso.buaa.edu.cn，校外模式下经 d.buaa.edu.cn 加密转发）发起登录请求，用于换取学校系统' +
          '签发的会话凭据。本应用不会将该账号密码上传至任何自有服务器或第三方服务器。',
        '2. 会话凭据（Cookie）：登录成功后由学校系统签发，用于后续请求的身份校验。按「校内直连」与' +
          '「WebVPN」两种连接模式分别隔离保存在本机应用私有目录，切换模式不会互相覆盖。',
        '3. 校园业务数据：您主动访问时从学校系统读取的课表、成绩、考试安排、空闲教室、作业、' +
          '图书馆座位、博雅课程、签到与打卡记录、诉求工单等。这些数据来源于学校系统，本应用仅做展示。',
        '4. 本地缓存：为减少重复请求、支持离线查看，部分业务数据会以缓存形式保存在本机应用私有目录。',
        '5. 运行日志：仅记录在您设备本地的简要运行日志（如请求失败原因），用于排查问题。'
      ]
    },
    {
      title: '三、我们不收集的信息',
      paragraphs: [
        '本应用不收集、不申请、不读取以下信息：通讯录、通话记录、短信、相册与文件、精确或粗略地理位置、' +
          '麦克风、摄像头、设备唯一标识（IMEI / OAID / SN 等）、已安装应用列表。',
        '本应用不接入任何广告、统计、崩溃上报类第三方 SDK，不含任何数据变现逻辑。',
        '本应用没有自建服务端，不存在「把您的数据汇总到开发者服务器」这一环节。'
      ]
    },
    {
      title: '四、信息的使用目的',
      paragraphs: [
        '上述信息仅用于实现以下功能：完成统一身份认证登录、展示您本人的校园业务数据、' +
          '在您授权下执行预约与提交类操作（如座位预约、作业提交、课堂签到）、保持登录状态以免重复输入。',
        '本应用不会将您的信息用于用户画像、精准推送、广告投放、信用评估或任何与上述目的无关的用途。'
      ]
    },
    {
      title: '五、信息的存储与保护',
      paragraphs: [
        '存储位置：全部保存在您设备的应用私有目录内，不上传至开发者或任何第三方。卸载本应用即随应用数据' +
          '一并删除；您也可以在「我的 → 退出登录」或系统设置中清除应用数据，立即失效并删除本地凭据与缓存。',
        '传输安全：与学校系统之间使用 HTTPS 加密传输；登录凭据不写入日志、不落盘为明文。',
        '保存期限：会话凭据与业务缓存随登录状态与缓存策略存在，退出登录或卸载即清除。'
      ]
    },
    {
      title: '六、信息的对外提供',
      paragraphs: [
        '本应用只会与您所就读学校的相关系统通信，包括统一身份认证、教务、图书馆预约、教学平台等，' +
          '通信目的是完成您本人发起的请求。除此之外，不向任何第三方共享、转让、公开披露您的信息。',
        '本应用不包含第三方登录、第三方支付或社会化分享功能。',
        '如未来因功能变更确需引入第三方服务，我们会在更新本政策并取得您的同意后再行提供。'
      ]
    },
    {
      title: '七、系统权限说明',
      paragraphs: [
        '网络访问（ohos.permission.INTERNET）：与学校系统通信的必需权限，是应用核心功能的前提。',
        '获取网络状态（ohos.permission.GET_NETWORK_INFO）：用于判断当前网络是否可用，在离线时给出提示' +
          '并引导切换连接模式，避免无效重试。',
        '除以上两项外，本应用不申请任何其他权限。'
      ]
    },
    {
      title: '八、您的权利',
      paragraphs: [
        '您可以在应用内随时查看、刷新属于自己的数据；可以退出登录以失效本地会话凭据；' +
          '可以清除缓存或卸载应用以删除全部本地数据。',
        '您有权拒绝提供学号与密码 —— 但这会使登录功能无法使用，因为本应用的唯一身份来源就是学校统一认证。',
        '如需就个人信息处理提出疑问、投诉或行使删除权，可通过本政策末尾的联系方式与我们联系。'
      ]
    },
    {
      title: '九、未成年人保护',
      paragraphs: [
        '本应用面向具备完全民事行为能力的在校师生。若您未满 14 周岁，请在监护人陪同下阅读本政策，' +
          '并在监护人同意后使用本应用。'
      ]
    },
    {
      title: '十、政策更新与联系方式',
      paragraphs: [
        '本政策可能因功能调整或法规要求而更新，更新后会在应用内本页面同步展示，并更新生效日期。' +
          '若涉及处理范围或方式的重大变更，会在应用内显著位置提示。',
        '本政策自 ' + AppConfig.POLICY_EFFECTIVE_DATE + ' 起生效。',
        '联系邮箱：' + AppConfig.CONTACT_EMAIL,
        '开源项目地址：' + AppConfig.THIS_PROJECT_URL
      ]
    }
  ];

  build() {
    Scroll() {
      Column({ space: AppSize.gapLarge }) {
        Column({ space: 6 }) {
          Text('隐私政策')
            .fontSize(AppFont.title)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColor.textPrimary)
          Text('生效日期：' + AppConfig.POLICY_EFFECTIVE_DATE)
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textTertiary)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ top: 12, bottom: 4 })

        Column({ space: AppSize.gapLarge }) {
          ForEach(this.sections, (section: PolicySection, index: number) => {
            Column({ space: 8 }) {
              Text(section.title)
                .fontSize(AppFont.subtitle)
                .fontWeight(FontWeight.Medium)
                .fontColor(AppColor.textPrimary)
                .width('100%')
              ForEach(section.paragraphs, (paragraph: string, pIndex: number) => {
                Text(paragraph)
                  .fontSize(AppFont.body)
                  .fontColor(AppColor.textSecondary)
                  .lineHeight(22)
                  .width('100%')
              }, (paragraph: string, pIndex: number) => index + '-' + pIndex)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }, (section: PolicySection, index: number) => 'sec-' + index)
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
