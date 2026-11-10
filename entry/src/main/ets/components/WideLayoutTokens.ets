/**
 * 分栏（Split）专用尺寸令牌。
 *
 * 只保留 MainPage 真正读取的三个值；曾经放在这里的 `sideNavWidth*` / `widePagePadding` /
 * `wideContentBottomInset` 已经下沉到 `common/Breakpoint.ets`（`sideNavWidthOf`）与
 * `AppTheme.AppSize`（随断点取值的 getter），避免同一套数值在两处各写一份。
 */
export class WideLayoutTokens {
  /** 列表栏（navBar）宽度范围。 */
  static readonly navBarMinWidth: number = 320;
  static readonly navBarMaxWidth: number = 400;
  /** 详情栏最小宽度，低于它系统会退回 Stack。 */
  static readonly minContentWidth: number = 360;
}
