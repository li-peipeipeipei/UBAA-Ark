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
 * - **图标全部重绘**（`app.media.icf_*`，24×24 单色可着色）：按功能语义各画一个，
 *   替代原先复用的 Material 图标。
 */
export interface FeatureItem {
  title: string;
  desc: string;
  icon: Resource;
  color: Resource;
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
      desc: '考试时间与考场座位',
      icon: $r('app.media.icf_exam'),
      color: AppColor.accentPurple,
      route: RouteName.EXAM
    },
    {
      title: '成绩查询',
      desc: '按学期看成绩与学分',
      icon: $r('app.media.icf_grade'),
      color: AppColor.accentGreen,
      route: RouteName.GRADE
    },
    {
      title: '空闲教室',
      desc: '按日期查空闲教室',
      icon: $r('app.media.icf_classroom'),
      color: AppColor.accentYellow,
      route: RouteName.CLASSROOM
    },
    {
      title: '课堂签到',
      desc: '今日课堂一键签到',
      icon: $r('app.media.icf_signin'),
      color: AppColor.brand,
      route: RouteName.SIGNIN
    },
    {
      title: '博雅课程',
      desc: '博雅课程查询与选课',
      icon: $r('app.media.icf_bykc'),
      color: AppColor.accentPink,
      route: RouteName.BYKC
    },
    {
      title: '图书馆座位',
      desc: '预约座位与我的预约',
      icon: $r('app.media.icf_library'),
      color: AppColor.accentPurple,
      route: RouteName.LIBBOOK_HOME
    },
    {
      title: 'SPOC',
      desc: '在线课程作业与提交',
      icon: $r('app.media.icf_spoc'),
      color: AppColor.brandLight,
      route: RouteName.SPOC
    },
    {
      title: '自动评教',
      desc: '一键完成待评课程',
      icon: $r('app.media.icf_evaluation'),
      color: AppColor.accentGreen,
      route: RouteName.EVALUATION
    },
    {
      title: 'iHome',
      desc: '校园诉求与处理进度',
      icon: $r('app.media.icf_ihome'),
      color: AppColor.accentYellow,
      route: RouteName.IHOME
    },
    {
      title: '阳光打卡',
      desc: '学期打卡次数与记录',
      icon: $r('app.media.icf_sun'),
      color: AppColor.accentPink,
      route: RouteName.YGDK
    }
  ];
}
