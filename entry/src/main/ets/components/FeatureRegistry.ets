import { AppColor } from './AppTheme';
import { RouteName } from '../common/AppRouter';
import { ScheduleColors } from '../common/ScheduleColors';

/**
 * 校园功能入口清单。
 *
 * `route` 为空串表示尚未打通（点击只会给「敬请期待」提示）。**没实现的入口不挂出来**：
 * 希冀平台 / 研讨室预约在原版 UBAA 里也只是占位，先在注册表里移除，
 * 等真有实现再连同 `route` 一起加回来 —— 半成品入口比没有入口更伤体验。
 *
 * ## 2026-11-11 改版
 *
 * - **不再分「普通功能 / 高级功能」**：功能页只做一层平铺，靠图标与色彩区分，
 *   分组反而多出一层视觉噪音。
 * - **移除「个人资料」入口**：它属于「我的」页的账户信息，放在功能页是重复入口。
 * - **图标沿用 UBAA 原版**（`app.media.ic_*`，Material 风格，白色着色）。
 * - **去掉 `desc` 字段**：按钮内只放图标与名称，说明文字不再展示。
 */
export interface FeatureItem {
  title: string;
  icon: Resource;
  /**
   * 旧版强调色（Resource）。
   *
   * 2026-11-24 起功能页磁贴、主页「最近使用」、转场遮罩已全部改走课表色表
   * （`slot` + `ScheduleColors.forFeatureTile`）；此字段仅作兼容保留，不再参与渲染。
   */
  color: Resource;
  /**
   * 功能块底色在**浅色模式**下的字面值 = `ScheduleColors.forFeatureTile(slot, false)`。
   *
   * 卡片 → 全屏的转场要拿一个纯色块做变形载体，而 `backgroundColor` 在动画里
   * 无法插值（不同颜色之间没有过渡）。这里存下与磁贴完全相同的字面值，转场色块
   * 才能从「卡片色」平滑过渡到「页面底色」——**必须与磁贴显示色同源，否则跳色**。
   */
  colorValue: string;
  /**
   * 功能块底色在**深色模式**下的字面值 = `ScheduleColors.forFeatureTile(slot, true)`。
   *
   * 转场遮罩要拿真实色值做插值，不能只存浅色那份 —— 否则深色下遮罩明显比卡片暗一档。
   */
  colorDark: string;
  /**
   * 课表色表槽位（0..15，`ScheduleColors.slotIndex` 自动取模）。
   *
   * 功能页按「0,8,1,9,2,10…」交错分配，让色表中相近的一对（i 与 i+8）
   * 在网格里挨着；磁贴底色、图标/文字色、转场色全由它派生。
   */
  slot: number;
  /** 目标路由名；为空表示暂未实现。 */
  route: string;
  /**
   * 图标是否**自带配色**（多色插画）。
   *
   * 磁贴默认按课表色表给图标染色（浅=同色系彩图标、深=块色混白）；少数素材本身由多色路径组成（例如课堂签到的
   * 「日历底 + 白色对勾」），强行染白会让中间的空与对勾糊成一片。这类图标
   * 置 true，磁贴不再覆盖它的 fill。
   */
  colorful?: boolean;
  /**
   * 图标是**位图（PNG）**而非矢量（SVG）。
   *
   * `Image.fillColor()` 官方明确只对 SVG 图源生效；本项目 7 个 PNG 都是纯白像素 + alpha
   * 抗锯齿，`fillColor` 完全无效（浅色下仍显示白色）。这类图标置 true，磁贴改用
   * `colorFilter` + `BlendMode.SRC_IN` 染色（官方推荐的图标染色方式，保留透明度）。
   */
  bitmapIcon?: boolean;
}

/**
 * 功能页的全部入口（单一列表，顺序即展示顺序）。
 *
 * 按「一学期里用得最多的先后」排：查考试 / 成绩、找空教室、签到、选博雅、
 * 约图书馆、看作业、评教、提诉求、打卡。
 */
/*
 * ⚠️ 清单只构建**一次**（模块级常量）。
 *
 * 原来每次调用 `allFeatures()` 都新建 12 个对象，每个还带一个 `$r()` 资源对象；
 * 而 FeaturePage 的 build 里调了两次（ForEach + columnsTemplate），
 * 意味着每次重渲染（切主题、onAreaChange 改列数、磁贴回弹）都要造 24 个对象、
 * 24 次 `$r()`，并让 ForEach 拿到新数组多跑一轮 key 计算。
 * 清单是静态的，构建一次就够；调用方**不要修改返回值**。
 */
/**
 * ⚠️ 磁贴的 colorValue / colorDark **不是字面写死的色值**，而是按 `slot`
 * 从课表色表派生（`ScheduleColors.forFeatureTile`）—— 与课程块共用同一套莫奈色板：
 * 浅色 = 文字色叠白派生的淡实色，深色 = 暗调预混实色。
 *
 * `color: Resource` 只留给出色的小图标底色用（主页最近使用），
 * 不再参与功能页磁贴与转场。
 *
 * 2026-11-24 色表扩到 16 槽（前 8 / 后 8 按色相配对），slot 按
 * 「0,8,1,9,2,10,3,11,4,12,5,13,6」交错分配：每对相近色在网格里相邻，
 * 13 个入口全部落在实际槽位上，不再有取模回绕的撞色。
 */
const FEATURE_LIST: FeatureItem[] = [
  {
    title: '考试安排', icon: $r('app.media.ic_assignment'), slot: 0, bitmapIcon: true,
    color: AppColor.accentPurple,
    colorValue: ScheduleColors.forFeatureTile(0, false), colorDark: ScheduleColors.forFeatureTile(0, true),
    route: RouteName.EXAM
  },
  {
    // 与上一项「考试安排」(槽 0) 是色表配对色（砖红 / 正红），网格里挨着放
    title: '成绩查询', icon: $r('app.media.ic_grade'), slot: 8, bitmapIcon: true,
    color: AppColor.accentGreen,
    colorValue: ScheduleColors.forFeatureTile(8, false), colorDark: ScheduleColors.forFeatureTile(8, true),
    route: RouteName.GRADE
  },
  {
    title: '空闲教室', icon: $r('app.media.ic_meeting_room'), slot: 1, bitmapIcon: true,
    color: AppColor.accentYellow,
    colorValue: ScheduleColors.forFeatureTile(1, false), colorDark: ScheduleColors.forFeatureTile(1, true),
    route: RouteName.CLASSROOM
  },
  {
    // 配对「空闲教室」(槽 1)：橙 / 赭橙
    title: '课堂签到', icon: $r('app.media.ic_how_to_reg'), slot: 9, bitmapIcon: true,
    color: AppColor.brand,
    colorValue: ScheduleColors.forFeatureTile(9, false), colorDark: ScheduleColors.forFeatureTile(9, true),
    route: RouteName.SIGNIN
  },
  {
    title: '博雅课程', icon: $r('app.media.ic_school'), slot: 2,
    color: AppColor.accentPink,
    colorValue: ScheduleColors.forFeatureTile(2, false), colorDark: ScheduleColors.forFeatureTile(2, true),
    route: RouteName.BYKC
  },
  {
    // 配对「博雅课程」(槽 2)：芥末黄 / 暗金
    title: '图书馆座位', icon: $r('app.media.ic_event_seat'), slot: 10,
    color: AppColor.accentPurple,
    colorValue: ScheduleColors.forFeatureTile(10, false), colorDark: ScheduleColors.forFeatureTile(10, true),
    route: RouteName.LIBBOOK_HOME
  },
  {
    title: 'SPOC', icon: $r('app.media.ic_assignment_turned_in'), slot: 3,
    color: AppColor.brandLight,
    colorValue: ScheduleColors.forFeatureTile(3, false), colorDark: ScheduleColors.forFeatureTile(3, true),
    route: RouteName.SPOC
  },
  {
    // 配对「SPOC」(槽 3)：绿 / 深绿
    title: '自动评教', icon: $r('app.media.ic_rate_review'), slot: 11, bitmapIcon: true,
    color: AppColor.accentGreen,
    colorValue: ScheduleColors.forFeatureTile(11, false), colorDark: ScheduleColors.forFeatureTile(11, true),
    route: RouteName.EVALUATION
  },
  {
    title: 'iHome', icon: $r('app.media.ic_forum'), slot: 4, bitmapIcon: true,
    color: AppColor.accentYellow,
    colorValue: ScheduleColors.forFeatureTile(4, false), colorDark: ScheduleColors.forFeatureTile(4, true),
    route: RouteName.IHOME
  },
  {
    // 配对「iHome」(槽 4)：青绿 / 深青
    title: '阳光打卡', icon: $r('app.media.ic_wb_sunny'), slot: 12,
    color: AppColor.accentPink,
    colorValue: ScheduleColors.forFeatureTile(12, false), colorDark: ScheduleColors.forFeatureTile(12, true),
    route: RouteName.YGDK
  },
  {
    // 上游 UBAA 2.0 的「财务收入」：只读查询，走 chaxun.icw.buaa.edu.cn。
    title: '财务收入', icon: $r('app.media.ic_receipt_long'), slot: 5, bitmapIcon: true,
    color: AppColor.brand,
    colorValue: ScheduleColors.forFeatureTile(5, false), colorDark: ScheduleColors.forFeatureTile(5, true),
    route: RouteName.FINANCE
  },
  {
    // 配对「财务收入」(槽 5)：蓝 / 灰蓝
    title: '云打印', icon: $r('app.media.ic_print'), slot: 13,
    color: AppColor.accentTeal,
    colorValue: ScheduleColors.forFeatureTile(13, false), colorDark: ScheduleColors.forFeatureTile(13, true),
    route: RouteName.CLOUD_PRINT
  },
  {
    // 上游 UBAA 2.0「校园服务」里的网费流量：只读，走 zfw.buaa.edu.cn。
    title: '网费流量', icon: $r('app.media.ic_wifi'), slot: 6,
    color: AppColor.accentPurple,
    colorValue: ScheduleColors.forFeatureTile(6, false), colorDark: ScheduleColors.forFeatureTile(6, true),
    route: RouteName.NETWORK
  }
];

/** 取功能清单（返回同一个数组实例，只读使用）。 */
export function allFeatures(): FeatureItem[] {
  return FEATURE_LIST;
}
