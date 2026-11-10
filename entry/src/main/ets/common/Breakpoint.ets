/**
 * 响应式断点（单位 vp）。
 *
 * 只做纯计算与键名定义：**不 import 任何 UI / Ability 模块**，
 * 以便 AppTheme（被 30+ 页面引用）与 ImmersiveUtil 都能安全依赖它。
 *
 * ## 断点划分（对齐华为「一次开发，多端部署」官方断点）
 *
 * 宽度断点（决定主布局形态）：
 * | 名称 | 宽度 vp | 典型设备 |
 * | --- | --- | --- |
 * | sm | [0, 600) | 手机竖屏、窄分屏窗口 |
 * | md | [600, 840) | 平板竖屏、折叠屏展开、手机横屏 |
 * | lg | [840, 1200) | 平板横屏、2in1 小窗 |
 * | xxl | [1200, +∞) | 2in1 全屏、超大平板横屏 |
 *
 * 高度断点（用于识别官方所说的「大屏竖屏」：横向 md + 纵向 lg）：
 * | 名称 | 高度 vp |
 * | --- | --- |
 * | sm | [0, 600) |
 * | md | [600, 840) |
 * | lg | [840, +∞) |
 *
 * ## 两条硬规则（官方要求）
 *
 * 1. **按窗口宽度断点适配，不按设备类型判断**。折叠屏展开折叠、平板横竖屏、
 *    分屏 / 自由窗口缩放，本质都是窗口尺寸变化，同一套断点覆盖全部形态。
 * 2. **大屏竖屏把页签栏放底部**。所以「底部页签 / 侧边导航」的切换点是 lg，
 *    而不是「是不是宽屏」—— Pad 竖屏（673vp）虽然算宽屏，仍然用底部页签。
 *
 * 实测设备（2026-11-10）：
 * - 手机 PLR-AL50：1316×2832 / 3.5 → 376vp → sm
 * - 平板 MLR-AL10（MatePad Mini）：1600×2560 / 2.375 → 竖 673vp(md) / 横 1077vp(lg)
 */

/** AppStorage 键：窗口宽度（vp）。 */
export const KEY_WINDOW_WIDTH_VP: string = 'windowWidthVp';
/** AppStorage 键：窗口高度（vp）。 */
export const KEY_WINDOW_HEIGHT_VP: string = 'windowHeightVp';
/** AppStorage 键：宽度断点 sm / md / lg / xxl。 */
export const KEY_BREAKPOINT: string = 'breakpoint';
/** AppStorage 键：高度断点 sm / md / lg。 */
export const KEY_HEIGHT_BP: string = 'heightBreakpoint';
/** AppStorage 键：是否横屏（窗口宽 > 高）。 */
export const KEY_IS_LANDSCAPE: string = 'isLandscape';
/** AppStorage 键：是否走宽屏分支（bp !== 'sm'）。 */
export const KEY_IS_WIDE_SCREEN: string = 'isWideScreen';
/** AppStorage 键：窗口是否具备分栏能力（lg / xxl）。 */
export const KEY_NAV_SPLIT_MODE: string = 'navSplitMode';

export const BP_SM_MAX: number = 600;
export const BP_MD_MAX: number = 840;
export const BP_LG_MAX: number = 1200;

/** 宽度（vp）→ 断点名。纯函数，便于日志核对。 */
export function widthToBreakpoint(wVp: number): string {
  if (wVp < BP_SM_MAX) {
    return 'sm';
  }
  if (wVp < BP_MD_MAX) {
    return 'md';
  }
  if (wVp < BP_LG_MAX) {
    return 'lg';
  }
  return 'xxl';
}

/** 高度（vp）→ 高度断点名。 */
export function heightToBreakpoint(hVp: number): string {
  if (hVp < BP_SM_MAX) {
    return 'sm';
  }
  if (hVp < BP_MD_MAX) {
    return 'md';
  }
  return 'lg';
}

export function isWideBreakpoint(bp: string): boolean {
  return bp !== 'sm';
}

/** 是否使用「侧边导航」形态：只有 lg / xxl 才用，其余一律底部页签。 */
export function useSideNav(bp: string): boolean {
  return bp === 'lg' || bp === 'xxl';
}

/** 是否使用底部页签：手机（sm）/ 平板竖屏（md）。 */
export function useBottomTabBar(bp: string): boolean {
  return !useSideNav(bp);
}

/** 是否具备「列表 + 详情」分栏能力（还要结合页面语义，见 MainPage.splitFor）。 */
export function isSplitBreakpoint(bp: string): boolean {
  return bp === 'lg' || bp === 'xxl';
}

/** 侧边导航宽度（vp）。 */
export function sideNavWidthOf(bp: string): number {
  return bp === 'xxl' ? 256 : 232;
}

/** 列表栏（navBar）宽度（vp）。 */
export function navBarWidthOf(bp: string): number {
  return bp === 'xxl' ? 400 : 360;
}

/**
 * 磁贴 / 卡片网格的列数。
 *
 * 以「单格不小于 84vp」为约束反推，避免大屏下 4 列被拉成巨型方块：
 * 376vp 手机 4 列 → 平板竖屏 6 列 → 平板横屏 6 列 → 2in1 8 列。
 */
export function tileColumnsOf(bp: string): number {
  if (bp === 'md') {
    return 6;
  }
  if (bp === 'xxl') {
    return 8;
  }
  if (bp === 'lg') {
    return 6;
  }
  return 4;
}

/**
 * 磁贴网格的 columnsTemplate 字符串（如 '1fr 1fr 1fr 1fr'）。
 *
 * 单独抽出来是因为 ArkTS 里 `'1fr '.repeat(n)` 这类写法可用性不稳，
 * 而 `Grid.columnsTemplate` 只吃现成字符串。
 */
export function tileColumnsTemplate(bp: string): string {
  const count: number = tileColumnsOf(bp);
  const cells: string[] = [];
  for (let i = 0; i < count; i++) {
    cells.push('1fr');
  }
  return cells.join(' ');
}

/**
 * 按「断点列数」与「实际条目数」取列：条目比列数少时按条目数均分。
 *
 * 否则大屏下 4 个磁贴占 6 列，右侧会空出两格，视觉上像少渲染了东西。
 */
export function tileColumnsTemplateFor(bp: string, itemCount: number): string {
  const byBp: number = tileColumnsOf(bp);
  const count: number = itemCount > 0 && itemCount < byBp ? itemCount : byBp;
  const cells: string[] = [];
  for (let i = 0; i < count; i++) {
    cells.push('1fr');
  }
  return cells.join(' ');
}

/**
 * 阅读 / 表单类内容的限宽（vp）。返回 0 表示不限宽。
 *
 * 大屏上单列文本行宽超过约 900vp 后阅读效率明显下降（官方「插图与文字组合」
 * 场景建议用栅格控制内容宽度），因此设置、关于、个人资料这类页面在宽屏下居中限宽。
 */
export function contentMaxWidthOf(bp: string): number {
  if (bp === 'xxl') {
    return 1040;
  }
  if (bp === 'lg') {
    return 920;
  }
  return 0;
}
