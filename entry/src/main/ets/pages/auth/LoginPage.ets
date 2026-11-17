import { AppColor, AppFont, AppSize } from '../../components/AppTheme';
import {
  AppConfig,
  ConnectionMode,
  DEFAULT_ROUTE_POLICY,
  RoutePolicy,
  RoutePolicyMeta,
  allRoutePolicies,
  connectionModeName,
  routePolicyName
} from '../../common/AppConfig';
import { KEY_TOP_SAFE_HEIGHT } from '../../common/ImmersiveUtil';
import { Logger } from '../../common/Logger';
import { Toast } from '../../common/Toast';
import { ApiError, CaptchaRequiredError } from '../../network/ApiError';
import { ApiService } from '../../network/ApiService';
import { RouteEngine } from '../../network/RouteEngine';
import { SavedCredentials, TokenStore } from '../../network/TokenStore';
import { CaptchaInfo, UserData } from '../../model/ApiTypes';

/**
 * 登录页。
 *
 * 沉浸式设计：
 * - 品牌色渐变背景延伸到状态栏（配合 EntryAbility 的全屏布局）
 * - 表单以「浮起卡片」形式呈现，配合半透明与柔和阴影形成层次
 * - 顶部留白跟随状态栏避让区高度自适应
 */
@Component
export struct LoginPage {
  onLoginSuccess: (user: UserData) => void = () => {};

  @StorageProp(KEY_TOP_SAFE_HEIGHT) topSafeHeight: number = 0;
  @State username: string = '';
  @State password: string = '';
  @State captchaCode: string = '';
  @State loading: boolean = false;
  @State errorMessage: string = '';
  @State showCaptcha: boolean = false;
  @State captchaImageUri: string = '';
  @State mode: ConnectionMode = ConnectionMode.DIRECT;
  /** 用户选的路线策略：AUTO 自动 / 锁直连 / 锁 WebVPN。 */
  @State policy: RoutePolicy = DEFAULT_ROUTE_POLICY;
  @State showModeSheet: boolean = false;
  @State demoMode: boolean = false;
  /** 登录失败是否源于服务端故障（据此给出「开启演示模式」的出路）。 */
  @State serverDown: boolean = false;
  /** 是否记住密码（默认开：登录成功即落盘，下次进页面自动回填）。 */
  @State rememberPassword: boolean = true;

  private execution: string = '';
  /**
   * `warmUp()` 取令牌时所在的路线。
   *
   * CAS 的 `execution` 是**某一个登录页**的一次性令牌，换了路线（换了上游域名）
   * 就作废。自动选路可能在预热之后才把路线定下来 —— 不记录就会拿 A 路的令牌
   * 去 B 路提交，服务端一律判「凭据无效」，而用户明明没输错。
   */
  private warmedMode: ConnectionMode = ConnectionMode.DIRECT;

  aboutToAppear(): void {
    this.policy = TokenStore.getRoutePolicy();
    this.mode = TokenStore.getConnectionMode();
    this.demoMode = TokenStore.getDemoMode();
    this.restoreCredentials();
    // 自动策略下后台探一次校园网，把「当前走哪条」显示出来（不阻塞表单）
    if (this.policy === RoutePolicy.AUTO && !this.demoMode) {
      void RouteEngine.prepareForLogin().then((mode: ConnectionMode) => {
        this.mode = mode;
      });
    }
    this.warmUp();
  }

  /**
   * 回填上次记住的凭据。
   *
   * 只回填「勾选过记住密码」的那一份；没勾选过就什么都不动，
   * 免得把一台共用设备上别人残留的学号带出来。
   */
  private restoreCredentials(): void {
    const saved: SavedCredentials = TokenStore.getSavedCredentials();
    if (saved.username.length === 0) {
      return;
    }
    this.username = saved.username;
    this.rememberPassword = saved.remember;
    if (saved.remember && saved.password.length > 0) {
      this.password = saved.password;
    }
  }

  /**
   * 把「记住密码」的勾选落到存储上。
   *
   * 只存学号密码本身，不碰其它登录态 —— 退出登录时密码仍在，
   * 这符合用户勾选「记住密码」的预期；要清就在登录页取消勾选。
   */
  private syncSavedCredentials(): void {
    if (this.rememberPassword) {
      TokenStore.saveCredentials(this.username.trim(), this.password);
    } else {
      TokenStore.clearSavedCredentials();
    }
  }

  /**
   * 预热：先拉一次统一认证登录页。
   *
   * 两个作用 ——
   * 1. 取回本次登录的一次性令牌 `execution`，用户点登录时直接带上，少一次往返；
   * 2. 若本次需要验证码，提前把图片显示出来，而不是等用户填完账号密码被退回。
   *
   * 失败一律静默：预加载不是登录的必经步骤，真正提交时还会再取一次。
   */
  private async warmUp(): Promise<void> {
    if (this.demoMode) {
      return;
    }
    try {
      const preload = await ApiService.preload(TokenStore.getOrCreateClientId());
      // 记下令牌是在哪条路上取的（预热期间自动选路可能刚把路线定下来）
      this.warmedMode = TokenStore.getConnectionMode();
      if (preload.execution !== undefined && preload.execution.length > 0) {
        this.execution = preload.execution;
      }
      // 两个方向都要写：这次不需要验证码时得把输入框收起来
      // （失败后重新预热时，旧的那张图已经作废了）。
      const needCaptcha: boolean =
        preload.captchaRequired === true && preload.captcha !== undefined;
      this.showCaptcha = needCaptcha;
      if (needCaptcha && preload.captcha !== undefined) {
        this.captchaImageUri = this.buildCaptchaUri(preload.captcha);
      }
    } catch (error) {
      Logger.warn('登录页预热失败（不影响继续登录）：' + (error as Error).message);
    }
  }

  /** 根据登录响应构造验证码图片地址（优先内联 base64）。 */
  private buildCaptchaUri(captcha: CaptchaInfo): string {
    const base64 = captcha.base64Image;
    if (base64 !== undefined && base64.length > 0) {
      if (base64.startsWith('data:')) {
        return base64;
      }
      return 'data:image/jpeg;base64,' + base64;
    }
    return ApiService.captchaImageUrl(captcha.id);
  }

  private validate(): string {
    if (this.username.length === 0) {
      return '请输入学号';
    }
    if (this.password.length === 0) {
      return '请输入密码';
    }
    if (this.showCaptcha && this.captchaCode.length === 0) {
      return '请输入验证码';
    }
    return '';
  }

  private async doLogin(): Promise<void> {
    // 按钮虽然会置灰，但同一帧内的快速双击会在 loading 重新渲染前进来两次 ——
    // 第二次带的是同一个 execution（已被第一次消费），必然失败并盖掉成功提示。
    if (this.loading) {
      return;
    }
    const invalid = this.validate();
    if (invalid.length > 0) {
      this.errorMessage = invalid;
      return;
    }

    this.loading = true;
    this.errorMessage = '';
    this.serverDown = false;
    let succeeded: boolean = false;
    // 「要求输入验证码」不是失败：服务端同时下发了**新的** execution 与验证码图片，
    // 两者必须配对使用。这种情形不能清 execution，否则用户看着旧图输入的验证码
    // 会和新的令牌对不上，怎么输都错。
    let keepExecution: boolean = false;

    // 自动策略：先探测校园网，把这次登录走哪条路定下来（校内→直连 / 校外→WebVPN）。
    // 这是「登录自动切换」的第一步 —— 用户不再需要判断自己在不在校园网。
    const autoMode: boolean = this.policy === RoutePolicy.AUTO;
    if (autoMode) {
      this.mode = await RouteEngine.prepareForLogin();
    }
    // 路线可能刚被自动选路改掉：预热拿的令牌属于旧路线，直接提交必被判「凭据无效」。
    // 丢掉旧令牌、按新路线重新预热一次（比让用户白输一次密码便宜得多）。
    if (this.execution.length > 0 && this.mode !== this.warmedMode) {
      Logger.info('预热令牌所属路线已变（' + this.warmedMode + '→' + this.mode + '），重新预热');
      this.execution = '';
      this.showCaptcha = false;
      this.captchaCode = '';
      await this.warmUp();
    }

    // 最多两次：第二次只在「自动策略 + 网络层失败」时发生（换另一条路重试）。
    // 凭据错误、验证码、业务拒绝都不换路 —— 那与走哪条路无关。
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        const user: UserData = await ApiService.login(
          this.username.trim(),
          this.password,
          TokenStore.getOrCreateClientId(),
          this.captchaCode,
          this.execution
        ).then((response) => {
          ApiService.persistLogin(response, this.username.trim());
          return response.user;
        });

        Toast.show('欢迎回来，' + user.name);
        succeeded = true;
        // 登录成功后按勾选状态落盘 / 清理凭据
        this.syncSavedCredentials();
        this.onLoginSuccess(user);
        break;
      } catch (error) {
        const apiError = error as ApiError;
        const networkFailure: boolean =
          apiError instanceof ApiError && apiError.networkFailure;

        // —— 自动切换：网络层失败就换另一条路再试一次 ——
        if (autoMode && networkFailure && attempt === 0) {
          const other: ConnectionMode = this.mode === ConnectionMode.DIRECT ?
            ConnectionMode.WEBVPN : ConnectionMode.DIRECT;
          Logger.warn('登录网络层失败（' + this.mode + '），自动切换到 ' + other + ' 重试');
          this.mode = other;
          RouteEngine.pinMode(other);
          // 换路 = 换上游域名：旧的一次性令牌与验证码全部作废
          this.execution = '';
          this.showCaptcha = false;
          this.captchaCode = '';
          this.errorMessage = '';
          await this.warmUp();
          continue;
        }

        if (error instanceof CaptchaRequiredError) {
          const challenge = error as CaptchaRequiredError;
          this.execution = challenge.execution;
          keepExecution = true;
          this.captchaImageUri = this.buildCaptchaUri(challenge.captcha);
          this.showCaptcha = true;
          this.captchaCode = '';
          this.errorMessage = challenge.message;
        } else if (error instanceof ApiError) {
          this.errorMessage = apiError.friendlyMessage();
          // 网络层失败时补上目标地址，避免「不知道连的是哪个地址」这种无从下手的报错
          if (apiError.target.length > 0) {
            this.errorMessage += '（' + apiError.target + '）';
          }
          if (apiError.networkFailure) {
            if (autoMode) {
              // 两条路都试过了 —— 说明真的是网络不通，而不是选错了路
              this.errorMessage += '；已自动尝试直连与 WebVPN 两条路线均不通，请检查网络';
            } else if (this.mode === ConnectionMode.DIRECT) {
              // 锁定直连时最常见的失败原因就是不在校园网内 —— 给出可执行的下一步
              this.errorMessage += '；若当前不在校园网，请切到「自动」或 WebVPN 模式';
            }
          }
          this.serverDown = apiError.code === 'upstream_down';
          /**
           * 带验证码失败后必须**换一张图 + 换一个 execution**。
           *
           * 验证码是一次性的：错一次之后，屏幕上这张图和手里的 execution 都已作废。
           * 不主动刷新的话，用户对着同一张旧图反复输入，永远对不上 ——
           * 这也是「验证码怎么输都错」的成因之一。
           */
          if (this.showCaptcha) {
            this.captchaCode = '';
            void this.warmUp();
          }
        } else {
          this.errorMessage = '登录失败，请稍后重试';
          Logger.error('登录异常：' + (error as Error).message);
        }
        break;
      }
    }

    /**
     * CAS 的 `execution` 是**一次性令牌**：提交过一次就作废。
     *
     * 这里不清的话，用户密码打错一次之后，之后每次点登录都带着同一个死令牌 ——
     * 服务端一律判「凭据无效」，变成**怎么输都登不上**，只能杀进程重进重新预热。
     * 清空后 `LocalAuthService` 会重新拉登录页现取一个新令牌。
     *
     * 例外：`CaptchaRequiredError` 分支（见 `keepExecution`）—— 那里的令牌是新下发的，
     * 与屏幕上的验证码图片是**一对**，必须留着。
     */
    if (!succeeded && !keepExecution) {
      this.execution = '';
    }
    this.loading = false;
  }

  @Builder
  modeSheet() {
    Column({ space: AppSize.gap }) {
      Text('连接方式')
        .fontSize(AppFont.subtitle)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.textPrimary)
        .width('100%')

      ForEach(allRoutePolicies(), (item: RoutePolicyMeta) => {
        Row() {
          Column({ space: 2 }) {
            Text(item.displayName)
              .fontSize(AppFont.body)
              .fontColor(AppColor.textPrimary)
            Text(item.description)
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textTertiary)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          if (item.policy === this.policy) {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(18)
              .fontColor([AppColor.brand])
          }
        }
        .width('100%')
        .padding(AppSize.cardPadding)
        .borderRadius(AppSize.cardRadius)
        .backgroundColor(item.policy === this.policy ? AppColor.brandContainer : AppColor.surfaceSubtle)
        .onClick(() => {
          const changed: boolean = item.policy !== this.policy;
          this.policy = item.policy;
          this.mode = RouteEngine.resolvePolicy(item.policy);
          this.showModeSheet = false;
          if (changed) {
            // 换方式可能换上游域名：之前取到的一次性令牌与验证码全部作废，
            // 必须重新预热，否则拿旧 execution 提交一定被判为凭据无效
            this.execution = '';
            this.showCaptcha = false;
            this.captchaCode = '';
            this.errorMessage = '';
            this.warmUp();
          }
        })
      }, (item: RoutePolicyMeta) => item.policy)
    }
    .width('100%')
    .padding(AppSize.pagePadding)
    .backgroundColor(AppColor.pageBackground)
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      // 背景层：品牌渐变延伸到状态栏，构成沉浸式底色
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [
            [AppColor.brand, 0.0],
            [AppColor.brandLight, 0.28],
            [AppColor.pageBackground, 0.62]
          ]
        })

      Scroll() {
        Column({ space: AppSize.gapLarge }) {
          // 品牌区
          Column({ space: AppSize.gap }) {
            Image($r('app.media.app_icon'))
              .width(84)
              .height(84)
              .borderRadius(22)
              .draggable(false)
            Text('UBAA')
              .fontSize(AppFont.titleLarge)
              .fontWeight(FontWeight.Bold)
              .fontColor(Color.White)
            Text('校园服务聚合客户端 · 鸿蒙原生版')
              .fontSize(AppFont.caption)
              .fontColor('#CCFFFFFF')
          }
          .width('100%')
          .padding({ top: 24, bottom: 8 })

          if (this.demoMode) {
            Row({ space: 8 }) {
              SymbolGlyph($r('sys.symbol.info_circle'))
                .fontSize(16)
                .fontColor([AppColor.warning])
              Text(AppConfig.DEMO_BANNER + '，任意学号与密码均可进入。')
                .fontSize(AppFont.caption)
                .fontColor(AppColor.textSecondary)
                .layoutWeight(1)
            }
            .width('100%')
            .padding(12)
            .borderRadius(12)
            .backgroundColor('#FFF4E5')
          }

          // 表单卡片
          Column({ space: AppSize.gapLarge }) {
            Text('登录统一身份认证')
              .fontSize(AppFont.subtitle)
              .fontWeight(FontWeight.Medium)
              .fontColor(AppColor.textPrimary)
              .width('100%')

            Column({ space: AppSize.gap }) {
              TextInput({ placeholder: '请输入学号', text: this.username })
                .type(InputType.Number)
                .height(48)
                .backgroundColor(AppColor.surfaceSubtle)
                .borderRadius(12)
                .placeholderColor(AppColor.textTertiary)
                .fontSize(AppFont.body)
                .maxLength(20)
                .onChange((value: string) => {
                  this.username = value;
                  this.errorMessage = '';
                })

              TextInput({ placeholder: '请输入密码', text: this.password })
                .type(InputType.Password)
                .showPasswordIcon(true)
                .height(48)
                .backgroundColor(AppColor.surfaceSubtle)
                .borderRadius(12)
                .placeholderColor(AppColor.textTertiary)
                .fontSize(AppFont.body)
                .onChange((value: string) => {
                  this.password = value;
                  this.errorMessage = '';
                })

              if (this.showCaptcha) {
                Row({ space: AppSize.gap }) {
                  TextInput({ placeholder: '请输入验证码', text: this.captchaCode })
                    .height(48)
                    .layoutWeight(1)
                    .backgroundColor(AppColor.surfaceSubtle)
                    .borderRadius(12)
                    .placeholderColor(AppColor.textTertiary)
                    .fontSize(AppFont.body)
                    .maxLength(8)
                    .onChange((value: string) => {
                      this.captchaCode = value;
                    })

                  Image(this.captchaImageUri)
                    .width(108)
                    .height(48)
                    .borderRadius(12)
                    .backgroundColor(AppColor.surfaceSubtle)
                    .objectFit(ImageFit.Contain)
                    .draggable(false)
                }
                .width('100%')
              }
            }
            .width('100%')

            if (this.errorMessage.length > 0) {
              Row({ space: 6 }) {
                SymbolGlyph($r('sys.symbol.exclamationmark'))
                  .fontSize(14)
                  .fontColor([AppColor.danger])
                Text(this.errorMessage)
                  .fontSize(AppFont.caption)
                  .fontColor(AppColor.danger)
                  .layoutWeight(1)
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
            }

            // 服务端故障时给一条可执行的出路，而不是让用户对着报错干瞪眼
            //
            // ⚠️ 上架版刻意**不提供**「开启演示模式」的入口：
            // 审核员在登录失败时点进去会看到本地示例数据，可能误判为真实数据，
            // 也可能被认为应用支持任意账号登录，与商店申报口径不符。
            // 这里只保留重试与说明，出路必须是「等网络恢复后重试」。
            if (this.serverDown) {
              Column({ space: 6 }) {
                Text('学校统一身份认证服务当前不可用，请检查网络连接后重试。若持续失败，可稍后再试或联系学校信息中心。')
                  .fontSize(AppFont.caption)
                  .fontColor(AppColor.textSecondary)
                  .width('100%')

                Button('重新加载登录页')
                  .fontSize(AppFont.caption)
                  .height(32)
                  .backgroundColor(AppColor.surfaceSubtle)
                  .fontColor(AppColor.brand)
                  .type(ButtonType.Capsule)
                  .onClick(() => {
                    this.errorMessage = '';
                    this.serverDown = false;
                    this.warmUp();
                  })
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            }

            Button(this.loading ? '登录中…' : '登 录')
              .width('100%')
              .height(48)
              .fontSize(AppFont.subtitle)
              .fontColor(AppColor.textOnBrand)
              .backgroundColor(AppColor.brand)
              .enabled(!this.loading)
              .onClick(() => {
                this.doLogin();
              })

            // 记住密码 + 连接模式
            Row() {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(14)
                .fontColor([this.rememberPassword ? AppColor.brand : AppColor.textTertiary])
              Text('记住密码')
                .fontSize(AppFont.caption)
                .fontColor(AppColor.textSecondary)
                .layoutWeight(1)
                .margin({ left: 6 })
              // 只让 Toggle 自己响应点击：Row 再挂一个 onClick 会跟 Toggle 的
              // onChange 撞车（点一下状态翻转两次，肉眼是「点了没反应」）。
              Toggle({ type: ToggleType.Switch, isOn: this.rememberPassword })
                .onChange((isOn: boolean) => {
                  this.rememberPassword = isOn;
                  // 取消勾选立即抹掉已存凭据，不给「以为忘了其实还留着」的机会
                  this.syncSavedCredentials();
                })
            }
            .width('100%')

            Row() {
              SymbolGlyph($r('sys.symbol.arrow_clockwise'))
                .fontSize(14)
                .fontColor([AppColor.textTertiary])
              Text('连接：' + this.currentModeName())
                .fontSize(AppFont.caption)
                .fontColor(AppColor.textSecondary)
                .layoutWeight(1)
                .margin({ left: 6 })
              Text('切换')
                .fontSize(AppFont.caption)
                .fontColor(AppColor.brand)
            }
            .width('100%')
            .onClick(() => {
              this.showModeSheet = true;
            })
          }
          .width('100%')
          .padding(20)
          .backgroundColor(AppColor.surface)
          .borderRadius(AppSize.cardRadiusLarge)
          .shadow({ radius: 24, color: '#1A000000', offsetX: 0, offsetY: 8 })

          Column({ space: 4 }) {
            Text('登录即表示同意使用校园统一身份认证')
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textTertiary)
            Text('版本 ' + AppConfig.APP_VERSION)
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textTertiary)
          }
          .width('100%')
          .padding({ bottom: 24 })
        }
        .width('100%')
        .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding, top: this.topSafeHeight + 16 })
      }
      .scrollBar(BarState.Off)
      // 顶/底拖到边界时回弹（内容不足一屏也生效）
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.pageBackground)
    .bindSheet($$this.showModeSheet, this.modeSheet(), {
      height: 320,
      dragBar: true,
      backgroundColor: AppColor.pageBackground
    })
  }

  /**
   * 连接方式的展示文案。
   *
   * 自动策略下要让用户看得到「现在到底走哪条」——只写「自动」等于没写，
   * 出问题时无从下手。所以补上当前实际路线。
   */
  private currentModeName(): string {
    const name: string = routePolicyName(this.policy);
    if (this.policy !== RoutePolicy.AUTO) {
      return name;
    }
    return name + '（当前：' + connectionModeName(this.mode) + '）';
  }
}
