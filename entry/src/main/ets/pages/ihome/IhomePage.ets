import { BackGuard } from '../../common/BackGuard';
import { AppRouter, LoadState, RouteName } from '../../common/AppRouter';
import { IhomeNav } from '../../common/IhomeNav';
import { Logger } from '../../common/Logger';
import { Toast } from '../../common/Toast';
import { ApiError } from '../../network/ApiError';
import { ApiService } from '../../network/ApiService';
import { AppColor, AppFont, AppSize } from '../../components/AppTheme';
import { ChipsEdgeFade } from '../../components/ChipsEdgeFade';
import { topSafeInsetVp } from '../../common/ImmersiveUtil';
import curves from '@ohos.curves';
import { EmptyView, ErrorView, LoadingView } from '../../components/CommonViews';
import {
  IhomeAppeal,
  IhomeCategory,
  IhomeEntry,
  IhomeFilter,
  IhomeNotice,
  IhomeScope
} from '../../model/ApiTypes';
import { PageCache } from '../../common/PageCache';
import { OfflineKey } from '../../common/OfflineCache';

/** iHome 列表首帧缓存内容。keyword / filter / loadingMore 等交互态不缓存。 */
interface IhomeCache {
  entries: IhomeEntry[];
  notices: IhomeNotice[];
  page: number;
  lastPage: number;
  total: number;
  categories: IhomeCategory[];
}

/**
 * iHome（接诉即办）。
 *
 * 五个视图与上游一致：诉求广场 / 我的发起 / 我的关注 / 我的评价 / 公告。
 * - 广场支持关键词搜索与分类筛选（搜索由上游执行，匹配正文与官方回复）；
 * - 我的发起额外支持按回复状态、回复时间筛选；
 * - 公告点开就地展开正文（纯文本，不执行上游脚本，也不还原表格 / 图片）。
 *
 * ⚠️ 写操作（关注 / 支持）在详情页，按「目标状态」提交，不在这里做。
 */
@Component
export struct IhomePage {
  stack: NavPathStack = new NavPathStack();

  @State private loadState: LoadState = LoadState.LOADING;
  @State private errorMessage: string = '';
  @State private scope: IhomeScope = IhomeScope.PUBLIC;
  @State private entries: IhomeEntry[] = [];
  @State private notices: IhomeNotice[] = [];
  @State private page: number = 1;
  @State private lastPage: number = 1;
  @State private total: number = 0;
  @State private keyword: string = '';
  @State private filter: IhomeFilter = IhomeFilter.ALL;
  @State private categoryId: number = 0;
  @State private categories: IhomeCategory[] = [];
  @State private loadingMore: boolean = false;
  /**
   * 请求序号（单调递增）。每个异步请求发出前叫一次号，回来时比对 —— 序号变了说明
   * 已经有更新的请求在跑（切 scope / 切筛选 / 搜索），本次结果整份丢弃。
   * 否则慢请求后到会把新列表覆盖成旧数据。
   */
  private reqSeq: number = 0;
  @State private expandedNoticeId: number = 0;
  /** 视图胶囊行的实测高度（两侧渐隐遮罩据此定高，见 components/ChipsEdgeFade）。 */
  @State private scopeRowH: number = 33;
  /** 筛选胶囊行的实测高度。 */
  @State private filterRowH: number = 29;

  aboutToAppear(): void {
    this.loadConfig();
    this.load(true);
  }

  private async loadConfig(): Promise<void> {
    try {
      const config = await ApiService.fetchIhomeConfig();
      this.categories = config.categories;
    } catch (error) {
      // 分类字典取不到不影响列表，只是少一个筛选项
      Logger.warn('iHome 配置加载失败：' + (error as Error).message);
    }
  }

  /** key 片段：只保留中英文数字，丢掉特殊字符并限长，避免 key 过长。 */
  private keyPart(value: string, maxLen: number): string {
    let out: string = '';
    const limit: number = value.length < maxLen ? value.length : maxLen;
    for (let i = 0; i < limit; i++) {
      const ch: string = value.charAt(i);
      const code: number = ch.charCodeAt(0);
      if ((code >= 48 && code <= 57) || (code >= 65 && code <= 90) ||
        (code >= 97 && code <= 122) || (code >= 0x4E00 && code <= 0x9FFF)) {
        out += ch;
      }
    }
    return out;
  }

  /** 列表缓存 key：视图 + 关键词 + 筛选 + 分类，多视图互不覆盖。 */
  private listCacheKey(): string {
    return OfflineKey.IHOME_PREFIX + this.keyPart(this.scope.toString(), 16) + '_' +
      this.keyPart(this.keyword, 24) + '_' +
      this.keyPart(this.filter.toString(), 16) + '_' + this.categoryId.toString();
  }

  /** 把当前内容写回本视图缓存（动态 key，登记以便换账号清理）。 */
  private saveListCache(): void {
    PageCache.save(this.listCacheKey(), {
      entries: this.entries,
      notices: this.notices,
      page: this.page,
      lastPage: this.lastPage,
      total: this.total,
      categories: this.categories
    } as IhomeCache, true);
  }

  private async load(reset: boolean): Promise<void> {
    if (this.scope === IhomeScope.NOTICE) {
      await this.loadNotices();
      return;
    }
    if (reset) {
      // 冷启动首帧：必须在下面的 reset 清空之前同步读缓存，命中就直接进 SUCCESS
      const cached: IhomeCache | null =
        PageCache.load<IhomeCache>(this.listCacheKey(), PageCache.TTL_HALF_DAY);
      if (cached !== null && cached.entries.length > 0) {
        this.entries = cached.entries;
        this.notices = cached.notices;
        this.page = cached.page;
        this.lastPage = cached.lastPage;
        this.total = cached.total;
        this.categories = cached.categories;
        this.loadState = LoadState.SUCCESS;
      } else {
        this.entries = [];
        this.page = 1;
      }
      if (this.loadState !== LoadState.SUCCESS) {
        this.loadState = LoadState.LOADING;
      }
    }
    // 请求序号：切换 scope / 筛选 / 关键词都会连发多个请求，慢的那个后到会覆盖新结果
    // （表现为「切到我的关注，列表里却是我的发起的内容」）。回来时序号对不上就整份丢弃。
    const seq: number = ++this.reqSeq;
    const scopeAtSend: IhomeScope = this.scope;
    // 缓存命中时 this.page 是上次读到的页码；后台拉新始终从第 1 页开始
    const requestPage: number = reset ? 1 : this.page;
    try {
      const result = await ApiService.fetchIhomePage(
        scopeAtSend, requestPage, this.keyword, this.filter, this.categoryId);
      if (seq !== this.reqSeq) {
        return;
      }
      this.entries = reset ? result.entries : this.entries.concat(result.entries);
      this.page = result.page > 0 ? result.page : this.page;
      this.lastPage = result.lastPage > 0 ? result.lastPage : 1;
      this.total = result.total;
      this.loadState = LoadState.SUCCESS;
      // 拉新成功：写回缓存，下次冷启动首帧就是它
      this.saveListCache();
    } catch (error) {
      if (seq !== this.reqSeq) {
        return;
      }
      this.errorMessage = error instanceof ApiError
        ? (error as ApiError).friendlyMessage() : 'iHome 加载失败';
      // 缓存命中过时失败不切 ERROR，保留已渲染的本地内容
      if (this.loadState !== LoadState.SUCCESS) {
        this.loadState = LoadState.ERROR;
      }
      Logger.error('iHome 加载失败：' + (error as Error).message);
    }
  }

  private async loadNotices(): Promise<void> {
    // 公告是独立分支：同样先同步读缓存，命中就直接进 SUCCESS
    const cached: IhomeCache | null =
      PageCache.load<IhomeCache>(this.listCacheKey(), PageCache.TTL_HALF_DAY);
    if (cached !== null && cached.notices.length > 0) {
      this.notices = cached.notices;
      this.loadState = LoadState.SUCCESS;
    } else {
      this.loadState = LoadState.LOADING;
    }
    const seq: number = ++this.reqSeq;
    try {
      const list = await ApiService.fetchIhomeNotices();
      if (seq !== this.reqSeq) {
        return;
      }
      this.notices = list;
      this.loadState = LoadState.SUCCESS;
      this.saveListCache();
    } catch (error) {
      if (seq !== this.reqSeq) {
        return;
      }
      this.errorMessage = error instanceof ApiError
        ? (error as ApiError).friendlyMessage() : '公告加载失败';
      // 缓存命中过时失败不切 ERROR，保留已渲染的本地内容
      if (this.loadState !== LoadState.SUCCESS) {
        this.loadState = LoadState.ERROR;
      }
    }
  }

  private async loadMore(): Promise<void> {
    if (this.loadingMore || this.page >= this.lastPage) {
      return;
    }
    this.loadingMore = true;
    // 先叫号：如果这期间用户切了 scope / 筛选，`load()` 会把 reqSeq 顶掉，
    // 这里回来时就不再往新列表里 concat 旧 scope 的下一页（否则会出现跨 scope 混合数据）。
    const seq: number = ++this.reqSeq;
    const scopeAtSend: IhomeScope = this.scope;
    this.page = this.page + 1;
    try {
      const result = await ApiService.fetchIhomePage(
        scopeAtSend, this.page, this.keyword, this.filter, this.categoryId);
      if (seq !== this.reqSeq) {
        return;
      }
      this.entries = this.entries.concat(result.entries);
      this.page = result.page > 0 ? result.page : this.page;
      this.lastPage = result.lastPage > 0 ? result.lastPage : this.page;
      this.total = result.total;
    } catch (error) {
      if (seq !== this.reqSeq) {
        return;
      }
      const message = error instanceof ApiError
        ? (error as ApiError).friendlyMessage() : '加载更多失败';
      Toast.show(message);
      this.page = this.page - 1;
    } finally {
      this.loadingMore = false;
    }
  }

  private switchScope(scope: IhomeScope): void {
    if (this.scope === scope) {
      return;
    }
    this.scope = scope;
    this.keyword = '';
    this.filter = IhomeFilter.ALL;
    this.categoryId = 0;
    // ⚠️ 这里原来是无条件 `BackGuard.unregister()`：用户**没展开过公告**时，
    // 它会把别的页面（别的页签）注册的那一层弹掉 —— 那一层的关闭动作就永远丢了，
    // 表现为「某个面板关不掉 / 返回键只关面板不退页面」。
    // 只有自己真的注册过才注销。
    this.collapseNotice();
    this.load(true);
  }

  private switchFilter(filter: IhomeFilter): void {
    if (this.filter === filter) {
      return;
    }
    this.filter = filter;
    // 列表整批换掉，展开中的公告随之消失 —— 同时撤掉那层返回键登记，
    // 否则会留下一个「关不掉的空面板」把下一次返回吞掉。
    this.collapseNotice();
    this.load(true);
  }

  /**
   * 收起公告并撤掉返回键登记（与 `toggleNotice` 里的 register 成对）。
   *
   * ⚠️ `BackGuard` 是**全局静态栈**：漏掉一层会让此后所有页面的返回键都先被它吃掉，
   * 表现为「返回键失灵」（要按两次、甚至要杀进程）。
   */
  private collapseNotice(): void {
    if (this.expandedNoticeId !== 0) {
      this.expandedNoticeId = 0;
      BackGuard.unregister();
    }
  }

  /**
   * 页面销毁时收掉登记。
   *
   * 不清理的话，`BackGuard` 里会留下一个指向已卸载组件状态的闭包 ——
   * 下次任何页面按返回都会调它（访问已销毁的 `@State`）。
   */
  aboutToDisappear(): void {
    this.collapseNotice();
  }

  private openDetail(entry: IhomeEntry): void {
    IhomeNav.set(entry.appeal.id, this.scope === IhomeScope.MINE || entry.appeal.isMine);
    AppRouter.push(this.stack, RouteName.IHOME_DETAIL);
  }

  private scopeLabel(scope: IhomeScope): string {
    if (scope === IhomeScope.MINE) {
      return '我的发起';
    }
    if (scope === IhomeScope.FOLLOWED) {
      return '我的关注';
    }
    if (scope === IhomeScope.APPRAISED) {
      return '我的评价';
    }
    if (scope === IhomeScope.NOTICE) {
      return '公告';
    }
    return '诉求广场';
  }

  /** 当前列表支持的筛选（与上游参数能力一一对应）。 */
  private filterOptions(): IhomeFilter[] {
    if (this.scope === IhomeScope.PUBLIC) {
      return [
        IhomeFilter.ALL, IhomeFilter.NEWEST, IhomeFilter.OLDEST,
        IhomeFilter.REPLIED, IhomeFilter.UNREPLIED
      ];
    }
    if (this.scope === IhomeScope.MINE) {
      return [
        IhomeFilter.ALL, IhomeFilter.NEWEST, IhomeFilter.REPLIED,
        IhomeFilter.UNREPLIED, IhomeFilter.REPLY_TIME
      ];
    }
    return [];
  }

  private filterLabel(filter: IhomeFilter): string {
    if (filter === IhomeFilter.NEWEST) {
      return '最新';
    }
    if (filter === IhomeFilter.OLDEST) {
      return '最早';
    }
    if (filter === IhomeFilter.REPLIED) {
      return '已回复';
    }
    if (filter === IhomeFilter.UNREPLIED) {
      return '未回复';
    }
    if (filter === IhomeFilter.REPLY_TIME) {
      return '按回复时间';
    }
    return '全部';
  }

  private categoryLabel(): string {
    if (this.categoryId === 0) {
      return '全部分类';
    }
    for (let i = 0; i < this.categories.length; i++) {
      if (this.categories[i].id === this.categoryId) {
        return this.categories[i].name;
      }
    }
    return '全部分类';
  }

  private categoryOptions(): SelectOption[] {
    const options: SelectOption[] = [{ value: '全部分类' }];
    for (let i = 0; i < this.categories.length; i++) {
      options.push({ value: this.categories[i].name });
    }
    return options;
  }

  private onCategorySelect(index: number): void {
    this.categoryId = index <= 0 ? 0 : this.categories[index - 1].id;
    this.load(true);
  }

  /* ------------------------------ 组件 ------------------------------ */

  /**
   * 展开 / 收起公告正文，并同步返回键优先级：展开状态下按返回先收公告，
   * 而不是把整个 iHome 页面退掉。
   */
  private toggleNotice(id: number): void {
    const next: number = this.expandedNoticeId === id ? 0 : id;
    this.expandedNoticeId = next;
    if (next !== 0) {
      BackGuard.register(() => {
        this.expandedNoticeId = 0;
        return true;
      });
    } else {
      BackGuard.unregister();
    }
  }

  /** 视图行的两侧渐隐（高度由该行 onAreaChange 上报）。 */
  @Builder
  scopeEdgeFade() {
    // ⚠️ 必须**在调用处**再设一次 `hitTestBehavior(None)`（与 SPOC / 图书馆座位同款）：
    // 自定义组件节点本身也是一层参与触摸测试的节点，只在组件内部给根容器设 None 时，
    // 组件节点仍会吃掉整条胶囊行的点击（表现为「胶囊点不动、只能滑」）。
    ChipsEdgeFade({ fadeHeight: this.scopeRowH })
      .hitTestBehavior(HitTestMode.None)
  }

  /** 筛选行的两侧渐隐。 */
  @Builder
  filterEdgeFade() {
    ChipsEdgeFade({ fadeHeight: this.filterRowH })
      .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  scopeBar() {
    Scroll() {
      Row({ space: AppSize.gapSmall }) {
        ForEach([
          IhomeScope.PUBLIC, IhomeScope.MINE, IhomeScope.FOLLOWED,
          IhomeScope.APPRAISED, IhomeScope.NOTICE
        ], (item: IhomeScope) => {
          Text(this.scopeLabel(item))
            .fontSize(AppFont.caption)
            .fontColor(this.scope === item ? Color.White : AppColor.textSecondary)
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .backgroundColor(this.scope === item ? AppColor.brand : AppColor.surface)
            .borderRadius(999)
            // 切换视图时底色 / 文字色做弹簧过渡（与博雅课程胶囊同一曲线）
            .animation({ curve: curves.responsiveSpringMotion(0.25, 0.7) })
            .onClick(() => {
              this.switchScope(item);
            })
        }, (item: IhomeScope) => item)
      }
      // 默认缩进放在滚动内容里（对齐 SPOC）：静止时首尾胶囊与下方卡片对齐，
      // 滑动时留白跟着滚走，胶囊能真正贴到屏幕边缘
      .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .width('100%')
    // 胶囊整体居中（六处胶囊行统一要求）
    .align(Alignment.Center)
    .clip(false)
    .onAreaChange((_old: Area, now: Area) => {
      const height: number = Number(now.height);
      if (height > 0 && Math.abs(height - this.scopeRowH) > 0.5) {
        this.scopeRowH = height;
      }
    })
    .overlay(this.scopeEdgeFade(), { align: Alignment.Center })
  }

  @Builder
  searchBar() {
    Column({ space: AppSize.gapSmall }) {
      Search({ value: this.keyword, placeholder: '搜索诉求内容 / 官方回复' })
        .width('100%')
        .height(36)
        .backgroundColor(AppColor.surfaceSubtle)
        .placeholderColor(AppColor.textTertiary)
        .textFont({ size: AppFont.body })
        .onChange((value: string) => {
          this.keyword = value;
        })
        .onSubmit(() => {
          this.load(true);
        })

      Row({ space: AppSize.gapSmall }) {
        Select(this.categoryOptions())
          .selected(this.categoryId === 0 ? 0 : this.indexOfCategory())
          .value(this.categoryLabel())
          .font({ size: AppFont.caption })
          .layoutWeight(1)
          .onSelect((index: number) => {
            this.onCategorySelect(index);
          })
        Text('搜索')
          .fontSize(AppFont.caption)
          .fontColor(Color.White)
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .backgroundColor(AppColor.brand)
          .borderRadius(999)
          .onClick(() => {
            this.load(true);
          })
      }
      .width('100%')
    }
    .width('100%')
    // 父级为胶囊行做了全出血（无左右 padding），本块自行缩进
    .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
  }

  private indexOfCategory(): number {
    for (let i = 0; i < this.categories.length; i++) {
      if (this.categories[i].id === this.categoryId) {
        return i + 1;
      }
    }
    return 0;
  }

  @Builder
  filterBar() {
    Scroll() {
      Row({ space: AppSize.gapSmall }) {
        ForEach(this.filterOptions(), (item: IhomeFilter) => {
          Text(this.filterLabel(item))
            .fontSize(AppFont.caption)
            .fontColor(this.filter === item ? AppColor.brand : AppColor.textSecondary)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor(this.filter === item ? AppColor.brandContainer : AppColor.surfaceSubtle)
            .borderRadius(999)
            .animation({ curve: curves.responsiveSpringMotion(0.25, 0.7) })
            .onClick(() => {
              this.switchFilter(item);
            })
        }, (item: IhomeFilter) => item)
      }
      .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .width('100%')
    .align(Alignment.Center)
    .clip(false)
    .onAreaChange((_old: Area, now: Area) => {
      const height: number = Number(now.height);
      if (height > 0 && Math.abs(height - this.filterRowH) > 0.5) {
        this.filterRowH = height;
      }
    })
    .overlay(this.filterEdgeFade(), { align: Alignment.Center })
  }

  @Builder
  entryCard(entry: IhomeEntry) {
    Column({ space: 8 }) {
      Row({ space: AppSize.gapSmall }) {
        Text(entry.appeal.content)
          .fontSize(AppFont.body)
          .fontColor(AppColor.textPrimary)
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(entry.appeal.status.length > 0 ? entry.appeal.status : '处理中')
          .fontSize(11)
          .fontColor(AppColor.brand)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(6)
          .backgroundColor(AppColor.brandContainer)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Row({ space: AppSize.gapSmall }) {
        if (entry.appeal.category.length > 0) {
          Text(entry.appeal.category)
            .fontSize(11)
            .fontColor(AppColor.textTertiary)
        }
        Text(entry.appeal.publishedAt)
          .fontSize(11)
          .fontColor(AppColor.textTertiary)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (entry.appeal.departments.length > 0) {
          Text(entry.appeal.departments.join('、'))
            .fontSize(11)
            .fontColor(AppColor.textTertiary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 140 })
        }
      }
      .width('100%')

      if (entry.evaluation !== undefined) {
        Row({ space: AppSize.gapSmall }) {
          Text('评价 ' + entry.evaluation.speed + '/' + entry.evaluation.satisfaction + '/' +
            entry.evaluation.degree)
            .fontSize(11)
            .fontColor(AppColor.textSecondary)
          Text('速度 / 满意度 / 解决程度')
            .fontSize(10)
            .fontColor(AppColor.textTertiary)
        }
        .width('100%')
      }

      Row({ space: AppSize.gap }) {
        if (entry.appeal.replies.length > 0) {
          Text('回复 ' + entry.appeal.replies.length)
            .fontSize(11)
            .fontColor(AppColor.textTertiary)
        }
        if (entry.appeal.followCount !== undefined) {
          Text('关注 ' + entry.appeal.followCount)
            .fontSize(11)
            .fontColor(AppColor.textTertiary)
        }
        if (entry.appeal.supportCount !== undefined) {
          Text('支持 ' + entry.appeal.supportCount)
            .fontSize(11)
            .fontColor(AppColor.textTertiary)
        }
      }
      .width('100%')
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.openDetail(entry);
    })
  }

  @Builder
  noticeRow(item: IhomeNotice) {
    Column({ space: 6 }) {
      Row({ space: AppSize.gapSmall }) {
        Text(item.title)
          .fontSize(AppFont.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(item.date)
          .fontSize(11)
          .fontColor(AppColor.textTertiary)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      if (this.expandedNoticeId === item.id) {
        Text(item.content.length > 0 ? item.content : '（无正文）')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textSecondary)
          .width('100%')
          .padding({ top: 4 })
      }
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.toggleNotice(item.id);
    })
  }

  @Builder
  footer() {
    if (this.scope !== IhomeScope.NOTICE && this.page < this.lastPage) {
      Button(this.loadingMore ? '加载中…' : '加载更多')
        .width('100%')
        .height(40)
        .fontSize(AppFont.body)
        .fontColor(AppColor.brand)
        .backgroundColor(AppColor.surfaceSubtle)
        .enabled(!this.loadingMore)
        .onClick(() => {
          this.loadMore();
        })
    }
  }

  build() {
    Scroll() {
      Column({ space: AppSize.gap }) {
        this.scopeBar()

        if (this.scope === IhomeScope.PUBLIC) {
          this.searchBar()
        }

        if (this.loadState === LoadState.LOADING) {
          Column() {
            LoadingView({ message: '正在加载 iHome…' })
          }
          .width('100%')
          .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
        } else if (this.loadState === LoadState.ERROR) {
          Column() {
            ErrorView({
              message: this.errorMessage,
              onRetry: () => {
                this.load(true);
              }
            })
          }
          .width('100%')
          .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
        } else if (this.scope === IhomeScope.NOTICE) {
          if (this.notices.length === 0) {
            Column() {
              EmptyView({ message: '暂无公告' })
            }
            .width('100%')
            .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
          } else {
            Column() {
              Column() {
                ForEach(this.notices, (item: IhomeNotice, index: number) => {
                  this.noticeRow(item)
                  if (index < this.notices.length - 1) {
                    Divider()
                      .color(AppColor.divider)
                      .strokeWidth(0.5)
                  }
                }, (item: IhomeNotice) => item.id.toString())
              }
              .width('100%')
              .padding({ left: AppSize.cardPadding, right: AppSize.cardPadding })
              .borderRadius(AppSize.cardRadius)
              .backgroundColor(AppColor.surface)
            }
            .width('100%')
            .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
          }
        } else {
          if (this.filterOptions().length > 0) {
            this.filterBar()
          }
          if (this.entries.length === 0) {
            Column() {
              EmptyView({ message: '暂无诉求' })
            }
            .width('100%')
            .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
          } else {
            Column() {
              Column() {
                ForEach(this.entries, (item: IhomeEntry, index: number) => {
                  this.entryCard(item)
                  if (index < this.entries.length - 1) {
                    Divider()
                      .color(AppColor.divider)
                      .strokeWidth(0.5)
                  }
                }, (item: IhomeEntry) => item.appeal.id.toString())
              }
              .width('100%')
              .padding({ left: AppSize.cardPadding, right: AppSize.cardPadding })
              .borderRadius(AppSize.cardRadius)
              .backgroundColor(AppColor.surface)
              Column() {
                this.footer()
              }
              .width('100%')
              .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
            }
            .width('100%')
            .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
          }
          Text('共 ' + this.total + ' 条诉求 · 第 ' + this.page + '/' + this.lastPage + ' 页')
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textTertiary)
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
        }

        Blank()
          .height(AppSize.contentBottomInset)
      }
      .width('100%')
      // ⚠️ 不能有左右 padding：两行胶囊要做成「0 → 屏幕宽」的全出血，
      // 渐隐遮罩才会落在真正的屏幕边缘（对齐 SPOC，详见 ChipsEdgeFade 文档）。
      .padding({
        top: AppSize.destTopInset(topSafeInsetVp()),
        bottom: 0
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
