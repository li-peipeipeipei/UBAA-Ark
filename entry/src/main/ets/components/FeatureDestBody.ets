import { RouteName } from '../common/AppRouter';

import { ExamPage } from '../pages/academic/ExamPage';
import { GradePage } from '../pages/academic/GradePage';
import { ClassroomPage } from '../pages/academic/ClassroomPage';
import { SigninPage } from '../pages/activity/SigninPage';
import { EvaluationPage } from '../pages/evaluation/EvaluationPage';
import { JudgePage } from '../pages/evaluation/JudgePage';
import { JudgeDetailPage } from '../pages/evaluation/JudgeDetailPage';
import { IhomePage } from '../pages/ihome/IhomePage';
import { IhomeDetailPage } from '../pages/ihome/IhomeDetailPage';
import { SpocPage } from '../pages/spoc/SpocPage';
import { YgdkPage } from '../pages/activity/YgdkPage';
import { BykcPage } from '../pages/bykc/BykcPage';
import { BykcCoursesPage } from '../pages/bykc/BykcCoursesPage';
import { BykcChosenPage } from '../pages/bykc/BykcChosenPage';
import { BykcStatisticsPage } from '../pages/bykc/BykcStatisticsPage';
import { BykcDetailPage } from '../pages/bykc/BykcDetailPage';
import { LibBookHomePage } from '../pages/library/LibBookHomePage';
import { LibBookReservePage } from '../pages/library/LibBookReservePage';
import { LibBookBookingsPage } from '../pages/library/LibBookBookingsPage';
import { FinancePage } from '../pages/finance/FinancePage';
import { NetworkPage } from '../pages/campus/NetworkPage';
import { CloudPrintPage } from '../pages/campus/CloudPrintPage';


/**
 * 功能页签「原生导航目的地」的内容分派。
 *
 * 为什么不写在 RouteBuilder 里：`NativeHeroDest` 需要一个**无参** `@Builder`
 * 才能传给 `HeroDetailLayer`，而 `NavPathStack` 又必须逐页传进去 ——
 * 两者冲突。把分派做成一个带 `name` / `stack` 属性的组件就同时满足：
 * 外壳只传名字与栈，具体渲染哪一页由这里决定。
 *
 * 与 `routeBuilder`（HDS 版）一一对应，新增功能入口时两处都要加。
 *
 * 🔴 **漏加一个分支 = 用户点进去一片空白**（2026-11-21 云打印踩过）：
 * 外壳照样画标题栏、下面什么都不渲染，`aboutToAppear` 也不会跑，
 * 所以连网络请求都没有 —— 与「登录失败」「加载失败」的表现完全不同，
 * 很容易误判成后者。末尾因此保留一个显式兜底文案，宁可露字不可静默空白。
 */
@Component
export struct FeatureDestBody {
  name: string = '';
  stack: NavPathStack = new NavPathStack();

  build() {

    if (this.name === RouteName.EXAM) {
      ExamPage()
    } else if (this.name === RouteName.CLASSROOM) {
      ClassroomPage()
    } else if (this.name === RouteName.SIGNIN) {
      SigninPage()
    } else if (this.name === RouteName.EVALUATION) {
      EvaluationPage()
    } else if (this.name === RouteName.SPOC) {
      SpocPage()
    } else if (this.name === RouteName.FINANCE) {
      FinancePage()
    } else if (this.name === RouteName.NETWORK) {
      NetworkPage()
    } else if (this.name === RouteName.YGDK) {
      YgdkPage()
    } else if (this.name === RouteName.IHOME) {
      IhomePage({ stack: this.stack })
    } else if (this.name === RouteName.IHOME_DETAIL) {
      IhomeDetailPage()
    } else if (this.name === RouteName.JUDGE) {
      JudgePage({ stack: this.stack })
    } else if (this.name === RouteName.JUDGE_DETAIL) {
      JudgeDetailPage()
    } else if (this.name === RouteName.BYKC) {
      BykcPage({ stack: this.stack })
    } else if (this.name === RouteName.BYKC_COURSES) {
      BykcCoursesPage({ stack: this.stack })
    } else if (this.name === RouteName.BYKC_CHOSEN) {
      BykcChosenPage()
    } else if (this.name === RouteName.BYKC_STATISTICS) {
      BykcStatisticsPage()
    } else if (this.name === RouteName.BYKC_DETAIL) {
      BykcDetailPage({ stack: this.stack })
    } else if (this.name === RouteName.LIBBOOK_HOME) {
      LibBookHomePage({ stack: this.stack })
    } else if (this.name === RouteName.LIBBOOK_RESERVE) {
      LibBookReservePage()
    } else if (this.name === RouteName.LIBBOOK_BOOKINGS) {
      LibBookBookingsPage()
    } else if (this.name === RouteName.CLOUD_PRINT) {
      CloudPrintPage()
    } else {
      Text('该页面尚未接入功能页路由：' + this.name)
        .fontSize(16)
        .fontColor('#8A8A8E')
        .width('100%')
        .height('100%')
        .textAlign(TextAlign.Center)
    }
  }
}
