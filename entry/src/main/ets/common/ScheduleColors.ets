/**
 * 课表页的课程块配色（深浅两套）。
 *
 * ## 颜色来源
 * - **深色**：从产品参考图用取色器取的莫奈暗调（低饱和、偏灰），配浅色文字；
 * - **浅色**：同样从参考图取色 —— 它是「深色以约 5% 叠在白底」的效果，
 *   所以看起来像半透明，实际是实色。
 *
 * ## 为什么不用真半透明
 * 用户明确要求「块加一点透明度，但**不要露出底板的横线**」。
 * 真 `backgroundColor` 带 alpha 会让底下的网格线透出来，所以这里统一做**预混**：
 * 把课程色按 alpha 混到底色上，得到一个不透明实色 —— 视觉等效透明，但完全遮线。
 *
 * 卡片（`widget/pages/*.ets`）不能 import 项目文件，那两处各自硬编码了同样的色板，
 * **改色时三处要同步**。
 */
export class ScheduleColors {
  /** 深色模式的课程色（莫奈暗调）。 */
  static readonly DARK: string[] = [
    '#602030', // 酒红
    '#284848', // 墨绿青
    '#583830', // 暗棕
    '#304058', // 靛蓝
    '#304830', // 橄榄绿
    '#504828', // 土黄
    '#383840', // 灰紫
    '#582030'  // 暗玫
  ];

  /** 浅色模式的课程块底色（取色器实采，等价于深色以 5% 叠白底）。 */
  static readonly LIGHT: string[] = [
    '#FCF0F0', // 淡粉
    '#F0F8F8', // 淡青
    '#FCF4F0', // 淡桃
    '#F4F4F8', // 淡蓝紫
    '#F8F4F0', // 淡米
    '#FCF0F4', // 淡玫
    '#F4F8F0', // 淡黄绿
    '#F4F4F4'  // 淡灰
  ];

  /**
   * 浅色块上的**文字色**（与 `LIGHT` 同索引一一配对，取色器实采）。
   *
   * 产品设计里浅色块的文字不是黑/白，而是「块底色的高饱和同色系」——
   * 淡粉块配红橙字、淡青块配深青字，看起来统一又有区分度。
   * **改块色必须同时改这一项**，否则文字和块底不协调。
   */
  static readonly TEXT_LIGHT: string[] = [
    '#BA5A4E', // 红橙（配淡粉）
    '#247E72', // 深青（配淡青）
    '#A8663C', // 橙棕（配淡桃）
    '#486CA8', // 蓝   （配淡蓝紫）
    '#A2963C', // 暗黄（配淡米）
    '#BA7284', // 粉红（配淡玫）
    '#4E7848', // 绿   （配淡黄绿）
    '#5A5A5A'  // 灰   （配淡灰）
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
