import { common2D, drawing } from '@kit.ArkGraphics2D';

/**
 * 课程在课表网格里的位置（相邻判定的输入）。
 *
 * 卡片进程不能 import 项目文件，所以这里只放**纯数据**；分配算法在主应用侧跑完后，
 * 把算好的 slot 写进卡片 payload（`CardSlot.colorSlot`），卡片只按 slot 查色板。
 */
export interface CourseSlotInput {
  /** 稳定身份：课程名（为空时用课程码）—— 同名课跨周必须同色。 */
  key: string;
  /** 星期 1..7。 */
  day: number;
  /** 起始节次 1..N。 */
  begin: number;
  /** 结束节次（含）。 */
  end: number;
}

/**
 * 课表页的课程块配色（深浅两套）。
 *
 * ## 颜色来源
 * - **深色**：从产品参考图用取色器取的莫奈暗调（低饱和、偏灰），配浅色文字；
 * - **浅色**：2026-11-22 起为「同索引文字色 14% 叠白」的派生实色（底与字同色系）。
 *
 * ## 为什么不用真半透明
 * 用户明确要求「块加一点透明度，但**不要露出底板的横线**」。
 * 真 `backgroundColor` 带 alpha 会让底下的网格线透出来，所以这里统一做**预混**：
 * 把课程色按 alpha 混到底色上，得到一个不透明实色 —— 视觉等效透明，但完全遮线。
 *
 * 卡片（`widget/pages/*.ets`）不能 import 项目文件，那两处各自硬编码了同样的色板，
 * **改色时三处要同步**：本文件 `LIGHT`、周卡 `LIGHT_PALETTE_W`、日卡 `LIGHT_PALETTE_D`。
 */
export class ScheduleColors {
  /**
   * 深色模式的课程块底色（暗调预混前的源色）。
   *
   * 2026-11-24 起为产品给的 **16 色色表**：前 8 与后 8 一一配对（0↔8、1↔9 … 7↔15），
   * 同对色相相近、深浅略不同。此数组由 `TEXT_LIGHT` 各色以 62% 混到 `DARK_BG` 派生，
   * 目标是得到与旧莫奈暗调相近的明度（例如 0 槽 #944438 ≈ 旧 #914639）。
   *
   * **此数组长度即全课表的取模基数**（`indexOf` 用它），扩到 16 槽后所有课程的
   * 取色按 `% 16` 重新洗牌。浅/深/文字三套数组必须同为 16 项，否则文字色越界。
   */
  static readonly DARK: string[] = [
    '#944438', '#965B36', '#8E7714', '#54794E',
    '#427071', '#21629A', '#524D8F', '#6C4A8F',
    '#95182F', '#8B4E2A', '#816F26', '#3A6333',
    '#216666', '#3A5985', '#5C4D71', '#4A4E76'
  ];

  /**
   * 浅色模式的课程块底色 = 同索引 `TEXT_LIGHT` 彩字**叠白 14%** 派生（16 槽一一对应）。
   *
   * 2026-11-24 色表换成产品给的 16 色，仍沿用「底与字同色系」规则；仍是预混实色，
   * 不加真 alpha —— 真透明会让网格横线透出来。
   */
  static readonly LIGHT: string[] = [
    '#F9E7E4', '#F9ECE3', '#F7F2DB', '#EAF3E8',
    '#E6F0F0', '#DFEDFA', '#EAE8F7', '#F0E8F7',
    '#F9DDE1', '#F7E9E0', '#F4F0E0', '#E4EEE2',
    '#DFEEEE', '#E4EBF5', '#ECE9F0', '#E8E9F2'
  ];

  /**
   * 浅色块上的**文字色**（与 `LIGHT` 同索引一一配对）—— 产品给的 16 色色表。
   *
   * 前 8 与后 8 按色相配对：0↔8 砖红/正红、1↔9 橙/赭、2↔10 芥末/暗金、
   * 3↔11 绿、4↔12 青绿、5↔13 蓝、6↔14 蓝紫、7↔15 紫。
   * 功能页 slot 按「0,8,1,9…」顺序铺，让每对在网格里相邻。
   *
   * **必须三处同步**（本数组 + 周卡 `LIGHT_TEXT_W` + 日卡 `LIGHT_TEXT_D`），
   * 且三处长度都要 = `DARK.length`（16），否则取色越界 Undefined。
   */
  static readonly TEXT_LIGHT: string[] = [
    '#D2513B', '#D57538', '#C8A201', '#6AA65E',
    '#4D9796', '#1981D8', '#675EC7', '#925AC7',
    '#D30A2C', '#C36124', '#B3961E', '#408333',
    '#198784', '#4172B7', '#785F96', '#5B619F'
  ];

  /** 深色卡片/页面底色（预混用）。 */
  static readonly DARK_BG: string = '#2F3034';
  /** 浅色卡片/页面底色（预混用）。 */
  static readonly LIGHT_BG: string = '#FFFFFF';

  /** 同一门课稳定取一色（换周不会变色）。 */
  static indexOf(key: string): number {
    let h: number = 7;
    for (let i = 0; i < key.length; i++) {
      h = (h * 31 + key.charCodeAt(i)) % 100003;
    }
    return h % ScheduleColors.DARK.length;
  }

  /* ---------------- 课程色：相邻避让分配 ---------------- */

  /**
   * 相近色判据：**槽位除以 8 同余**（0↔8、1↔9 … 7↔15 是产品定义的相近色对）。
   *
   * 只是「同组」才算相近 —— 同组内深浅两版本来就是同一色相；不同组即使色相
   * 挨着（如 0 砖红 / 1 橙）也视为可区分，避免约束过强导致 8 组不够分。
   */
  static similarGroup(slot: number): number {
    const idx: number = ScheduleColors.slotIndex(slot);
    return idx % 8;
  }

  /** 两块课在网格里是否「挨着」：同天节次相接/重叠，或相邻天时段重叠。 */
  private static adjacent(a: CourseSlotInput, b: CourseSlotInput): boolean {
    const beginA: number = a.begin <= 0 ? 1 : a.begin;
    const beginB: number = b.begin <= 0 ? 1 : b.begin;
    const endA: number = a.end < beginA ? beginA : a.end;
    const endB: number = b.end < beginB ? beginB : b.end;
    if (a.day === b.day) {
      // 同一列上下相邻：前一节结束的下一节 == 后一节开始，或节次区间重叠
      return endA + 1 >= beginB && endB + 1 >= beginA;
    }
    if (Math.abs(a.day - b.day) === 1) {
      // 相邻列横向挨着：时段有重叠（节次区间相交）才算，错开的不算
      return beginA <= endB && beginB <= endA;
    }
    return false;
  }

  /**
   * 给整学期课程分配色槽：**同名课同色、相邻课不同相近色组**。
   *
   * 算法（确定性贪心，与输入顺序无关）：
   * 1. 按 `key` 字典序排序，逐门课处理，保证跨周 / 跨端（主应用 vs 卡片）结果一致；
   * 2. 每门课的深浅变体由 `indexOf(key) >= 8` 决定（保留 16 色的丰富度）；
   * 3. 组先从 `indexOf(key) % 8` 试起；若与任一**已分配且相邻**的课同组，
   *    就按 0..7 顺序找第一个不冲突的组；8 组全占满时退回首组（极罕见）。
   *
   * ⚠️ 必须传**整学期**的课程集合：只传当前周会让同一门课换周后邻居变化、颜色跳变。
   * 返回值按课程名索引；查不到时调用方回退 `indexOf(key)`（旧缓存 / 首次加载）。
   */
  static assignCourseSlots(courses: CourseSlotInput[]): Map<string, number> {
    const result: Map<string, number> = new Map();

    // 按课程名分组，**保留同名课的所有时段**。
    // ⚠️ 早期版本在这里去重只留第一条记录，导致一周上多次的课（如理论力学周一 + 周三）
    // 只用第一条记录判相邻 —— 周一实际挨着的复变函数没被检测到，两门课落进同一相近色组
    // （槽 9 赭 / 槽 1 橙，%8 同为 1）。现在任意一对时段相邻就算两门课相邻。
    const groups: Map<string, CourseSlotInput[]> = new Map();
    const order: string[] = [];
    for (let i = 0; i < courses.length; i++) {
      const item: CourseSlotInput = courses[i];
      if (item.key.length === 0) {
        continue;
      }
      const times: CourseSlotInput[] | undefined = groups.get(item.key);
      if (times === undefined) {
        const created: CourseSlotInput[] = [];
        created.push(item);
        groups.set(item.key, created);
        order.push(item.key);
      } else {
        times.push(item);
      }
    }
    order.sort((a: string, b: string) => a.localeCompare(b));

    for (let i = 0; i < order.length; i++) {
      const key: string = order[i];
      const curSlots: CourseSlotInput[] = groups.get(key) ?? [];
      const base: number = ScheduleColors.indexOf(key);
      const variant: number = base >= 8 ? 8 : 0;
      const preferred: number = base % 8;

      // 已分配邻居占用的组：两门课的任意一对时段相邻即视为相邻
      const used: boolean[] = [false, false, false, false, false, false, false, false];
      for (let j = 0; j < i; j++) {
        const otherKey: string = order[j];
        const otherSlots: CourseSlotInput[] = groups.get(otherKey) ?? [];
        let isAdjacent: boolean = false;
        for (let a = 0; a < curSlots.length && !isAdjacent; a++) {
          for (let b = 0; b < otherSlots.length; b++) {
            if (ScheduleColors.adjacent(curSlots[a], otherSlots[b])) {
              isAdjacent = true;
              break;
            }
          }
        }
        if (!isAdjacent) {
          continue;
        }
        const slot: number | undefined = result.get(otherKey);
        if (slot !== undefined) {
          used[slot % 8] = true;
        }
      }

      let group: number = preferred;
      if (used[group]) {
        for (let g = 0; g < 8; g++) {
          if (!used[g]) {
            group = g;
            break;
          }
        }
      }
      result.set(key, group + variant);
    }
    return result;
  }

  /** 从分配表取课程色槽；查不到时回退课程名哈希（旧缓存 / 数据未就绪）。 */
  static slotOf(key: string, assigned: Map<string, number>): number {
    const value: number | undefined = assigned.get(key);
    return value === undefined ? ScheduleColors.indexOf(key) : value;
  }

  /* ---------------- 功能页磁贴复用同一套色板 ---------------- */

  /**
   * 把外部给的槽位号收敛到色表范围内。
   *
   * 色表 2026-11-24 扩到 16 槽，功能页 13 个入口全部落在 0..12，不再回绕；
   * 保留取模是为了以后入口超过 16 个时仍能安全取色。
   */
  static slotIndex(slot: number): number {
    const n: number = ScheduleColors.DARK.length;
    return ((slot % n) + n) % n;
  }

  /** 按槽位取块底色：浅 = 叠白派生实色，深 = 0.92 预混实色（与课程块同一套规则）。 */
  static forSlot(slot: number, dark: boolean): string {
    const idx: number = ScheduleColors.slotIndex(slot);
    if (!dark) {
      return ScheduleColors.LIGHT[idx];
    }
    return ScheduleColors.blend(ScheduleColors.DARK_BG, ScheduleColors.DARK[idx], 0.92);
  }

  /**
   * 功能页磁贴**浅色底色**里文字色的占比（课表 `LIGHT` 用 14%）。
   *
   * 2026-11-24 反馈「功能页浅色块本体有点淡」——只调功能页，不动课表色板
   * （`LIGHT`）与桌面卡片里那两份硬编码色板。数值越大颜色越浓。
   */
  static readonly FEATURE_TILE_LIGHT_TINT_RATIO: number = 0.20;

  /**
   * 功能页磁贴底色：浅色单独调浓（上面的比例），深色与课程块完全一致。
   *
   * ⚠️ 转场遮罩的 `colorValue` / `colorDark` 也必须走这个方法，
   * 否则浅色下卡片与展开动画起点颜色对不上（跳色）。
   */
  static forFeatureTile(slot: number, dark: boolean): string {
    const idx: number = ScheduleColors.slotIndex(slot);
    if (!dark) {
      return ScheduleColors.blend('#FFFFFF', ScheduleColors.TEXT_LIGHT[idx],
        ScheduleColors.FEATURE_TILE_LIGHT_TINT_RATIO);
    }
    return ScheduleColors.forSlot(slot, true);
  }

  /**
   * 深色块上图标 / 名称的「块色混白」比例：块色占 35%，白占 65%。
   *
   * 2026-11-24 两轮反馈定稿：先 25%（「偏白」），再按「往白色的反方向调一点」
   * 提到 35%。功能页、课表页、桌面卡片**共用这个值**，保证三处深色文字一致。
   */
  static readonly DARK_TEXT_TINT_RATIO: number = 0.35;

  /**
   * 按槽位取块上文字 / 图标色。
   *
   * - 浅色：同色系高饱和彩字（`TEXT_LIGHT`，与底一一配对）；
   * - 深色：**块底色与白色混合、偏向白**（`DARK_TEXT_TINT_RATIO`，当前 35% 块色）。
   *
   * ⚠️ 这是功能页专用方法（位于「功能页磁贴复用同一套色板」段内）——改它不会影响
   * 课表页与桌面卡片；观感确认后再把同款规则同步过去（课表页 + 周/日卡片）。
   */
  static textForSlot(slot: number, dark: boolean): string {
    const idx: number = ScheduleColors.slotIndex(slot);
    if (!dark) {
      return ScheduleColors.TEXT_LIGHT[idx];
    }
    return ScheduleColors.darkTextOnBlock(ScheduleColors.forFeatureTile(slot, true));
  }

  /**
   * 深色块上的通用文字色 = 块色与白色混合、偏白。
   *
   * 课表页的课程名 / 教室行、功能页图标 / 名称都走这里，避免三处各写一套白。
   */
  static darkTextOnBlock(color: string): string {
    return ScheduleColors.blend('#FFFFFF', color, ScheduleColors.DARK_TEXT_TINT_RATIO);
  }

  /** 深色块上的副文字（教室行）色：比名称淡一档，比例取名称的 70%。 */
  static darkSubTextOnBlock(color: string): string {
    return ScheduleColors.blend('#FFFFFF', color, ScheduleColors.DARK_TEXT_TINT_RATIO * 0.7);
  }

  /**
   * 功能图标的染色滤镜（含 PNG 位图）。
   *
   * `Image.fillColor()` 官方只对 SVG 生效，PNG 必须走 colorFilter；
   * `BlendMode.SRC_IN` 是官方推荐的「改图标颜色、保留透明度」方式。
   * 功能页磁贴与主页「最近使用」共用这一处，避免两处逻辑漂移。
   */
  static iconTintFilter(slot: number, dark: boolean): ColorFilter {
    const hex: string = ScheduleColors.textForSlot(slot, dark);
    const tint: common2D.Color = {
      alpha: 255,
      red: ScheduleColors.channel(hex, 0),
      green: ScheduleColors.channel(hex, 1),
      blue: ScheduleColors.channel(hex, 2)
    };
    return drawing.ColorFilter.createBlendModeColorFilter(tint, drawing.BlendMode.SRC_IN);
  }

  /** 相对亮度判断是否浅色（> 140），与课表页 `isLightColor` 同口径。 */
  static isLight(color: string): boolean {
    const hex: string = color.charAt(0) === '#' ? color.substring(1) : color;
    if (hex.length !== 6) {
      return false;
    }
    const r: number = parseInt(hex.substring(0, 2), 16);
    const g: number = parseInt(hex.substring(2, 4), 16);
    const b: number = parseInt(hex.substring(4, 6), 16);
    if (isNaN(r) || isNaN(g) || isNaN(b)) {
      return false;
    }
    return (0.299 * r + 0.587 * g + 0.114 * b) > 140;
  }

  /**
   * 一门课的块色。
   *
   * @param key 课程名或课程码（决定取哪个色）
   * @param dark 是否深色模式
   */
  static forCourse(key: string, dark: boolean): string {
    const idx: number = ScheduleColors.indexOf(key);
    if (!dark) {
      // 浅色板本身就是叠白后的观察色，直接可用
      return ScheduleColors.LIGHT[idx];
    }
    // 深色：0.92 预混到底色 → 略显通透但仍不透明（横线不会透出）
    return ScheduleColors.blend(ScheduleColors.DARK_BG, ScheduleColors.DARK[idx], 0.92);
  }

  /**
   * 浅色模式下该课程块上的文字色。
   *
   * 只在**浅色模式**下用 —— 深色模式的块底很深，统一用暖白 `#EDE8E0` 更清楚。
   */
  static textForCourse(key: string): string {
    return ScheduleColors.TEXT_LIGHT[ScheduleColors.indexOf(key)];
  }

  /**
   * 课程块副文字（教室行）色 = **主文字色的 75% 不透明度**（`#BF` + RGB）。
   *
   * 2026-11-22 反馈：教室行不再用中性黑，跟随课程名颜色、只淡一档。
   * 只在浅色模式用（深色模式副文字仍是暖白 70%）。
   */
  static subTextForCourse(key: string): string {
    return '#BF' + ScheduleColors.textForCourse(key).substring(1);
  }

  /* -------- 按避让后的 slot 取课程色（课表页 / 卡片同源规则） -------- */

  /**
   * 课表页课程块**浅色底色**里彩字的占比（LIGHT 用 14%）。
   *
   * 2026-11-24 反馈「课表页块底色太淡，稍微加深」——只调课表页：
   * 提到 20%（与功能页 `FEATURE_TILE_LIGHT_TINT_RATIO` 同档）。
   * 不动 `LIGHT`（卡片硬编码板、课程块以外复用处）与桌面卡片。
   */
  static readonly COURSE_TILE_LIGHT_TINT: number = 0.20;

  /**
   * 课表页课程块**深色底色**里块色预混占比（原 0.92）。
   *
   * 2026-11-24 反馈「深色块底色不透明度减少一点」→ 降到 0.88，
   * 让深色页底透出更多、块更沉。仅课表页课程块使用。
   */
  static readonly COURSE_TILE_DARK_ALPHA: number = 0.88;

  /** 课表页课程块底色：仅此处用上面两个课表专用参数，不影响功能页 / 卡片。 */
  static courseColorOf(slot: number, dark: boolean): string {
    const idx: number = ScheduleColors.slotIndex(slot);
    if (!dark) {
      return ScheduleColors.blend('#FFFFFF', ScheduleColors.TEXT_LIGHT[idx],
        ScheduleColors.COURSE_TILE_LIGHT_TINT);
    }
    return ScheduleColors.blend(ScheduleColors.DARK_BG, ScheduleColors.DARK[idx],
      ScheduleColors.COURSE_TILE_DARK_ALPHA);
  }

  /** 课程名文字色：浅色用同组彩字，深色走块色混白。 */
  static courseTextOf(slot: number, dark: boolean): string {
    if (!dark) {
      return ScheduleColors.TEXT_LIGHT[ScheduleColors.slotIndex(slot)];
    }
    return ScheduleColors.darkTextOnBlock(ScheduleColors.courseColorOf(slot, true));
  }

  /** 教室行文字色：浅色是彩字的 75% 透明，深色比名称淡一档。 */
  static courseSubTextOf(slot: number, dark: boolean): string {
    if (!dark) {
      return '#BF' + ScheduleColors.TEXT_LIGHT[ScheduleColors.slotIndex(slot)].substring(1);
    }
    return ScheduleColors.darkSubTextOnBlock(ScheduleColors.courseColorOf(slot, true));
  }

  /** 课程块描边色：与 `borderFor` 同规则。 */
  static courseBorderOf(slot: number, dark: boolean): string {
    const base: string = ScheduleColors.courseColorOf(slot, dark);
    return ScheduleColors.blend('#000000', base, dark ? 0.82 : 0.88);
  }

  /**
   * 边框色。
   *
   * - **深色模式**：在块色上叠黑，边界更清楚；
   * - **浅色模式**：**块底色略深的同色系**（仍是浅色，不是黑描边）——
   *   淡块配黑边太硬，配同色系浅边更柔和，又不至于看不见。
   */
  static borderFor(key: string, dark: boolean): string {
    const base: string = ScheduleColors.forCourse(key, dark);
    return ScheduleColors.blend('#000000', base, dark ? 0.82 : 0.88);
  }

  /** 把 color 以 alpha 预混到底色 bg 上，返回不透明实色。 */
  static blend(bg: string, color: string, alpha: number): string {
    const br: number = ScheduleColors.channel(bg, 0);
    const bgc: number = ScheduleColors.channel(bg, 1);
    const bb: number = ScheduleColors.channel(bg, 2);
    const r: number = Math.round(br + (ScheduleColors.channel(color, 0) - br) * alpha);
    const g: number = Math.round(bgc + (ScheduleColors.channel(color, 1) - bgc) * alpha);
    const b: number = Math.round(bb + (ScheduleColors.channel(color, 2) - bb) * alpha);
    return '#' + ScheduleColors.hex2(r) + ScheduleColors.hex2(g) + ScheduleColors.hex2(b);
  }

  /** 取 `#RRGGBB` 的第 index 个通道；解析失败返回 0。 */
  static channel(hex: string, index: number): number {
    const start: number = 1 + index * 2;
    if (hex.length < start + 2) {
      return 0;
    }
    const v: number = parseInt(hex.substring(start, start + 2), 16);
    return isNaN(v) ? 0 : v;
  }

  private static hex2(v: number): string {
    const c: number = v < 0 ? 0 : (v > 255 ? 255 : v);
    return c < 16 ? '0' + c.toString(16).toUpperCase() : c.toString(16).toUpperCase();
  }
}
