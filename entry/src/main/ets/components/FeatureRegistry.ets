import { AppColor } from './AppTheme';
import { RouteName } from '../common/AppRouter';

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
  color: Resource;
  /**
   * 同一个颜色的**十六进制色值**。
   *
   * 卡片 → 全屏的转场要拿一个纯色块做变形载体，而 `backgroundColor(Resource)`
   * 在动画里无法插值（不同 Resource 之间没有过渡）。这里把主色的字面值一并存下来，
   * 转场色块才能从「卡片色」平滑过渡到「页面底色」。
   */
  colorValue: string;
  /** 目标路由名；为空表示暂未实现。 */
  route: string;
}

/**
 * 功能页的全部入口（单一列表，顺序即展示顺序）。
 *
 * 按「一学期里用得最多的先后」排：查考试 / 成绩、找空教室、签到、选博雅、
 * 约图书馆、看作业、评教、提诉求、打卡。
 */
export function allFeatures(): FeatureItem[] {
  return [
    {
      title: '考试安排',
      icon: $r('app.media.ic_event'),
      color: AppColor.accentPurple,
      colorValue: '#7B61FF',
      route: RouteName.EXAM
    },
    {
      title: '成绩查询',
      icon: $r('app.media.ic_grade'),
      color: AppColor.accentGreen,
      colorValue: '#30A46C',
      route: RouteName.GRADE
    },
    {
      title: '空闲教室',
      icon: $r('app.media.ic_meeting_room'),
      color: AppColor.accentYellow,
      colorValue: '#FFB300',
      route: RouteName.CLASSROOM
    },
    {
      title: '课堂签到',
      icon: $r('app.media.ic_schedule'),
      color: AppColor.brand,
      colorValue: '#1976D2',
      route: RouteName.SIGNIN
    },
    {
      title: '博雅课程',
      icon: $r('app.media.ic_menu_book'),
      color: AppColor.accentPink,
      colorValue: '#E64A7B',
      route: RouteName.BYKC
    },
    {
      title: '图书馆座位',
      icon: $r('app.media.ic_schedule'),
      color: AppColor.accentPurple,
      colorValue: '#7B61FF',
      route: RouteName.LIBBOOK_HOME
    },
    {
      title: 'SPOC',
      icon: $r('app.media.ic_school'),
      color: AppColor.brandLight,
      colorValue: '#1E88E5',
      route: RouteName.SPOC
    },
    {
      title: '自动评教',
      icon: $r('app.media.ic_assignment'),
      color: AppColor.accentGreen,
      colorValue: '#30A46C',
      route: RouteName.EVALUATION
    },
    {
      title: 'iHome',
      icon: $r('app.media.ic_person'),
      color: AppColor.accentYellow,
      colorValue: '#FFB300',
      route: RouteName.IHOME
    },
    {
      title: '阳光打卡',
      icon: $r('app.media.ic_home'),
      color: AppColor.accentPink,
      colorValue: '#E64A7B',
      route: RouteName.YGDK
    }
  ];
}
