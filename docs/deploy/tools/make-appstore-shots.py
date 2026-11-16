#!/usr/bin/env python3
"""把真机截图合成成商店介绍图（营销图），风格对齐原版 UBAA 的 App Store 介绍图。

原版风格拆解（参考 apps.apple.com/cn/app/ubaa/id6768861821 的介绍图）：
    浅蓝渐变背景 → 品牌小字（蓝）→ 双行主标题（第一行深灰、第二行蓝）→
    一行副标题（灰）→ 黑色圆角机身内嵌真实截图

本脚本生成两套尺寸，同一批源截图复用：
    appstore : 1290x2796 竖版（App Store 提交，iPhone 6.7"）
    agc      : 1920x1080 横版（华为应用市场商店截图，16:9）

用法：
    python make-appstore-shots.py --shots <截图目录> --config <配置.json> \
                                  --out <输出目录> [--target appstore|agc|both]

配置格式（config.json，数组，顺序即输出顺序）：
    [
      {
        "file": "01_home.png",
        "brand": "UBAA 鸿蒙版",
        "title": "今天上什么课",
        "title2": "首页一眼看清",
        "subtitle": "今日课程、待办和常用入口集中呈现"
      }
    ]
"""

import argparse
import json
import os
import re
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont


NO_LINE_START = '，。、；：！？）》」』'          # 避头尾：不能出现在行首


def wrap_text(draw, text, f, max_w):
    """按像素宽度折行（中文按字、英文按词）；标点不落行首。"""
    lines, cur = [], ''
    tokens = re.findall(r'[A-Za-z0-9@._:/+-]+|\s+|.', text)
    # 把标点与前一个 token 绑定，避免行首出现标点
    bound = []
    for t in tokens:
        if bound and t and t[0] in NO_LINE_START and not t.isspace():
            bound[-1] += t
        else:
            bound.append(t)
    for t in bound:
        trial = cur + t
        if draw.textlength(trial, font=f) <= max_w:
            cur = trial
        else:
            if cur.strip():
                lines.append(cur.rstrip())
            cur = '' if t.isspace() else t
    if cur.strip():
        lines.append(cur.rstrip())
    return lines or ['']

# ---------- 主题（对齐原版介绍图取色） ----------
BG_TOP = (223, 235, 250)
BG_BOTTOM = (247, 250, 253)
BRAND_BLUE = (26, 115, 232)
TITLE_DARK = (60, 64, 67)
SUB_GRAY = (95, 99, 104)
FRAME_COLOR = (24, 26, 30)

FONT_BOLD = r'C:\Windows\Fonts\msyhbd.ttc'
FONT_REG = r'C:\Windows\Fonts\msyh.ttc'


def font(path: str, size: int):
    try:
        return ImageFont.truetype(path, size)
    except Exception:                       # noqa: BLE001
        return ImageFont.load_default()


def vertical_gradient(size, top, bottom):
    """竖向线性渐变背景。"""
    w, h = size
    img = Image.new('RGB', (w, h))
    d = ImageDraw.Draw(img)
    for y in range(h):
        t = y / max(1, h - 1)
        d.line([(0, y), (w, y)],
               fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return img


def horizontal_gradient(size, left, right):
    w, h = size
    img = Image.new('RGB', (w, h))
    d = ImageDraw.Draw(img)
    for x in range(w):
        t = x / max(1, w - 1)
        d.line([(x, 0), (x, h)],
               fill=tuple(int(left[i] + (right[i] - left[i]) * t) for i in range(3)))
    return img


def rounded_mask(size, radius):
    m = Image.new('L', size, 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size[0] - 1, size[1] - 1], radius, fill=255)
    return m


def detect_screen_box(img, screen_ratio=None):
    """探测带壳截图里的屏幕区域，返回 (left, top, right, bottom)。

    带壳模板结构（实测华为带壳截图）：
        外圈黑色描边 → 彩色高光带 → 纯黑壳边 → 屏幕内容
    左右两侧都能找到长度 >= 8px 的**连续纯黑带**（壳边），屏幕边界就在黑带内侧。
    上下边界同样用黑带法探测（横屏平板也适用）；探不到时回退到按屏幕比例推算
    （手机 1316:2832，screen_ratio 可覆盖）。
    检测失败返回 None（调用方回退到整图）。
    """
    w, h = img.size
    px = img.load()

    def is_black(x, y):
        """纯黑且**不透明**才算壳边 —— 透明像素转 RGB 后也是黑，必须排除，
        否则会把透明描边误判成壳边。"""
        r, g, b, a = px[x, y]
        return a > 250 and max(r, g, b) < 14

    def scan_line(vals, edge=15):
        """在一行/一列里找连续纯黑带（长度 >= 8px），排除距两端 edge 内的段。"""
        segs, start = [], None
        for i, dark in enumerate(vals):
            if dark:
                if start is None:
                    start = i
            else:
                if start is not None and i - start >= 8 and start >= edge and i - 1 <= len(vals) - 1 - edge:
                    segs.append((start, i - 1))
                start = None
        return segs

    def row_blacks(y):
        return scan_line([is_black(x, y) for x in range(w)])

    # 多行采样，取每行「最左黑带右端」与「最右黑带左端」的中位数，抗内容干扰
    lefts, rights = [], []
    for y in range(int(h * 0.2), int(h * 0.8), max(1, h // 40)):
        segs = row_blacks(y)
        if len(segs) >= 2:
            lefts.append(segs[0][1] + 1)
            rights.append(segs[-1][0] - 1)
    if not lefts:
        return None
    lefts.sort()
    rights.sort()
    left = lefts[len(lefts) // 2]
    right = rights[len(rights) // 2]
    if right - left < w * 0.5:
        return None

    # 上下边界：按屏幕比例推算并垂直居中（壳上下对称，比例已知且稳定）。
    # 不用黑带法：壳边缘是半透明渐变，黑带检测在 alpha 条件下会失效。
    if screen_ratio is None:
        screen_ratio = 2832 / 1316          # 手机：高/宽 = 2832/1316
    screen_w = right - left + 1
    screen_h = int(round(screen_w * screen_ratio))
    top = max(0, (h - screen_h) // 2)
    bottom = min(h - 1, top + screen_h - 1)
    return left, top, right, bottom


def uncase(img, screen_ratio=None):
    """裁掉壳，只留屏幕内容。检测失败时返回原图。"""
    box = detect_screen_box(img, screen_ratio)
    if not box:
        print('    [提示] 未识别到壳结构，保留原图')
        return img
    l, t, r, b = box
    print(f'    [裁壳] 屏幕区域 = ({l},{t})-({r},{b})，尺寸 {r-l+1}x{b-t+1}')
    return img.crop((l, t, r + 1, b + 1))


def render_agc_phone(item, shot_path, size=(1080, 1920), use_frame=True, do_uncase=False,
                     fill_notches=False):
    """AGC 手机页签专用：**9:16 竖版 1080×1920**。

    AGC 对手机截图的要求是宽高比 9:16、最低 1080×1920（不是 16:9 横版）。
    版式：标题在上、设备图在下居中 —— 竖版画布配竖屏手机，左右自然留白。
    """
    W, H = size
    canvas = vertical_gradient(size, BG_TOP, BG_BOTTOM)
    d = ImageDraw.Draw(canvas)

    blue_first = item.get('tone', 'gray-first') == 'blue-first'
    c_first, c_second = (BRAND_BLUE, TITLE_DARK) if blue_first else (TITLE_DARK, BRAND_BLUE)

    y = int(H * 0.048)
    text(d, (W // 2, y), item.get('brand', 'UBAA'), font(FONT_BOLD, 40), BRAND_BLUE)

    y += int(H * 0.042)
    text(d, (W // 2, y), item['title'], font(FONT_BOLD, 82), c_first)

    y += int(H * 0.050)
    text(d, (W // 2, y), item['title2'], font(FONT_BOLD, 82), c_second)

    y += int(H * 0.036)
    text(d, (W // 2, y), item['subtitle'], font(FONT_REG, 34), SUB_GRAY)

    shot = load_screen(shot_path, do_uncase, item.get('crop_bottom', 0.0), fill_notches,
                       item.get('screen_ratio'))
    avail_h = int(H * 0.63)
    scale = avail_h / shot.height
    ph = int(shot.height * scale)
    pw = int(shot.width * scale)
    shot = shot.resize((pw, ph), Image.LANCZOS)
    px = (W - pw) // 2
    py = int(H * 0.315)
    canvas.paste(shot, (px, py), shot)
    return canvas


def render_tablet(item, shot_path, size=(1920, 1280), do_uncase=False,
                  fill_notches=False, crop_bottom=0.0):
    """平板版：16:9 横版画布，文字在左、平板截图在右。

    平板截图本身是横屏，塞进手机的竖版模板会很别扭，所以单独一套版式。
    """
    W, H = size
    canvas = horizontal_gradient(size, BG_TOP, BG_BOTTOM)
    d = ImageDraw.Draw(canvas)

    blue_first = item.get('tone', 'gray-first') == 'blue-first'
    c_first, c_second = (BRAND_BLUE, TITLE_DARK) if blue_first else (TITLE_DARK, BRAND_BLUE)

    text_w = int(W * 0.235)
    x = int(W * 0.055)
    y = int(H * 0.295)          # 让文字块整体与右侧平板图垂直居中对齐
    d.text((x, y), item.get('brand', 'UBAA'), font=font(FONT_BOLD, 42), fill=BRAND_BLUE)

    y += int(H * 0.13)
    d.text((x, y), item['title'], font=font(FONT_BOLD, 58), fill=c_first)
    y += int(H * 0.115)
    d.text((x, y), item['title2'], font=font(FONT_BOLD, 58), fill=c_second)

    y += int(H * 0.085)
    for line in wrap_text(d, item['subtitle'], font(FONT_REG, 32), text_w):
        d.text((x, y), line, font=font(FONT_REG, 32), fill=SUB_GRAY)
        y += int(32 * 1.5)

    shot = load_screen(shot_path, item.get('uncase', do_uncase), crop_bottom, fill_notches,
                       item.get('screen_ratio'))
    img_w = int(W * 0.62)
    img_h = int(img_w * shot.height / shot.width)
    if img_h > int(H * 0.86):
        img_h = int(H * 0.86)
        img_w = int(img_h * shot.width / shot.height)
    shot = shot.resize((img_w, img_h), Image.LANCZOS)

    radius = int(img_w * 0.045)
    mask = rounded_mask(shot.size, radius)
    shot = shot.convert('RGBA')
    # alpha 求交：保留原图透明区，只额外切出圆角轮廓
    shot.putalpha(ImageChops.multiply(shot.getchannel('A'), mask))
    px = W - img_w - int(W * 0.04)
    py = (H - img_h) // 2
    canvas.paste(shot, (px, py), shot)
    return canvas


def fill_notch(img, y_limit=140):
    """抹掉带壳模板在状态栏上方叠加的「挖孔装饰」。

    带壳截图工具会在屏幕顶部中央画 2~3 个黑色椭圆模拟灵动岛，而真机截图
    （PLR-AL50 是居中单挖孔）不会有这种三连孔 —— 属于明显的合成痕迹。
    实测模板圆点为 RGB(8,8,9)、约 58x66px、位于屏幕坐标 x≈525~792 / y≈48~114。

    判据刻意收紧，避免误伤状态栏深色文字（RGB 48,48,49）：
      · 颜色近纯黑 max(RGB) < 30
      · 只在屏幕顶部中央 30%~70% 宽度区间、y ∈ [20, y_limit]
      · 近似正方形的连通块，填充度 > 0.55
    """
    w, h = img.size
    px = img.load()
    x0, x1 = int(w * 0.30), int(w * 0.70)
    y0, y1 = 20, min(y_limit, h)

    def dark(x, y):
        r, g, b, a = px[x, y]
        return a > 250 and max(r, g, b) < 30

    visited = set()
    filled = 0
    for sy in range(y0, y1):
        for sx in range(x0, x1):
            if (sx, sy) in visited or not dark(sx, sy):
                continue
            stack, pts = [(sx, sy)], []
            visited.add((sx, sy))
            while stack:
                cx, cy = stack.pop()
                pts.append((cx, cy))
                for nx, ny in ((cx - 1, cy), (cx + 1, cy), (cx, cy - 1), (cx, cy + 1)):
                    if not (x0 <= nx < x1 and y0 <= ny < y1) or (nx, ny) in visited:
                        continue
                    if dark(nx, ny):
                        visited.add((nx, ny))
                        stack.append((nx, ny))
            xs = [p[0] for p in pts]
            ys = [p[1] for p in pts]
            bx0, bx1, by0, by1 = min(xs), max(xs), min(ys), max(ys)
            bw, bh = bx1 - bx0 + 1, by1 - by0 + 1
            if not (25 <= bw <= 100 and 25 <= bh <= 100):
                continue
            if len(pts) < 300 or len(pts) / float(bw * bh) < 0.55:
                continue
            # 采样外圈一圈像素的中位色
            samples = []
            for x in range(max(x0, bx0 - 3), min(x1, bx1 + 4)):
                for yy in (by0 - 3, by1 + 3):
                    if y0 <= yy < y1:
                        samples.append(px[x, yy])
            for y in range(max(y0, by0 - 3), min(y1, by1 + 4)):
                for xx in (bx0 - 3, bx1 + 3):
                    if x0 <= xx < x1:
                        samples.append(px[xx, y])
            if not samples:
                continue
            samples.sort(key=lambda c: c[0] + c[1] + c[2])
            col = samples[len(samples) // 2]
            for x, y in pts:
                px[x, y] = col + (255,)
            filled += 1
    if filled:
        print(f'    [挖孔] 抹除 {filled} 处模板挖孔装饰')
    return img


def load_screen(shot_path, do_uncase=False, crop_bottom=0.0, fill_notches=False,
                screen_ratio=None):
    """载入源图并按需裁壳、裁底，返回 **RGBA** 图。

    ⚠️ 必须保留 alpha：带壳截图四周有透明像素，转成 RGB 会把透明留成黑色，
    贴到浅色背景上就是四个黑块。全程保留 RGBA，圆角外的透明区才能透出背景色。
    """
    img = Image.open(shot_path).convert('RGBA')
    if do_uncase:
        img = uncase(img, screen_ratio)
        if fill_notches:
            img = fill_notch(img)
    if crop_bottom > 0:
        w, h = img.size
        img = img.crop((0, 0, w, int(h * (1 - crop_bottom))))
    return img


def make_phone(shot_path, frame_w, use_frame=True, do_uncase=False, crop_bottom=0.0,
              fill_notches=False, screen_ratio=None):
    """把真机截图放进圆角机身，返回 (机身图 RGBA, 机身宽, 机身高)。

    机身 = 深色圆角矩形（外框）+ 内嵌的圆角截图。鸿蒙是直屏圆角、无灵动岛，
    挖孔与状态栏都在截图内部，保持原样，不额外绘制。

    use_frame=False 时不画深色边框，只做圆角裁切 —— 适用于「截图本身已带机身壳」
    的情况（此时不要再叠一层壳）。
    """
    shot = load_screen(shot_path, do_uncase, crop_bottom, fill_notches, screen_ratio)
    sw, sh = shot.size
    if not use_frame:
        # 已自带机身：原样返回（保留壳与 alpha），缩放交给调用层，避免二次缩放掉画质
        return shot

    bezel = max(8, int(frame_w * 0.018))          # 边框厚度
    radius = int(frame_w * 0.11)                  # 机身圆角
    screen_w = frame_w - bezel * 2
    screen_h = int(screen_w * sh / sw)

    screen = shot.resize((screen_w, screen_h), Image.LANCZOS)
    # ⚠️ 不要 putalpha 覆盖：裁壳后的屏幕内容自带透明圆角，
    # 覆盖会把壳的残留黑角重新变不透明。

    frame = Image.new('RGBA', (frame_w, screen_h + bezel * 2), (0, 0, 0, 0))
    fd = ImageDraw.Draw(frame)
    fd.rounded_rectangle([0, 0, frame_w - 1, screen_h + bezel * 2 - 1],
                         radius, fill=FRAME_COLOR)
    frame.paste(screen, (bezel, bezel), screen)
    return frame


def drop_shadow(phone, blur=28, offset=(0, 16), alpha=58):
    """给机身加柔和投影，返回同尺寸 RGBA。"""
    w, h = phone.size
    pad = blur * 3
    layer = Image.new('RGBA', (w + pad * 2, h + pad * 2), (0, 0, 0, 0))
    shadow = Image.new('RGBA', phone.size, (0, 0, 0, 0))
    shadow.putalpha(phone.getchannel('A'))
    shadow = Image.new('RGBA', phone.size, (30, 40, 60, alpha))
    layer.paste(shadow, (pad + offset[0], pad + offset[1]), shadow)
    layer = layer.filter(ImageFilter.GaussianBlur(blur))
    out = Image.new('RGBA', layer.size, (0, 0, 0, 0))
    out.paste(layer, (0, 0), layer)
    return out, pad


def text(draw, xy, s, f, fill, anchor='mm'):
    draw.text(xy, s, font=f, fill=fill, anchor=anchor)


def render_appstore(item, shot_path, size=(1290, 2796), use_frame=True, do_uncase=False,
                  fill_notches=False):
    W, H = size
    canvas = vertical_gradient(size, BG_TOP, BG_BOTTOM)
    d = ImageDraw.Draw(canvas)

    # tone 决定两行标题的颜色顺序：gray-first（默认，深灰在上）/ blue-first（蓝色在上）
    blue_first = item.get('tone', 'gray-first') == 'blue-first'
    c_first, c_second = (BRAND_BLUE, TITLE_DARK) if blue_first else (TITLE_DARK, BRAND_BLUE)

    brand = item.get('brand', 'UBAA')
    y = int(H * 0.043)
    text(d, (W // 2, y), brand, font(FONT_BOLD, 46), BRAND_BLUE)

    y += int(H * 0.030)
    text(d, (W // 2, y), item['title'], font(FONT_BOLD, 100), c_first)

    y += int(H * 0.036)
    text(d, (W // 2, y), item['title2'], font(FONT_BOLD, 100), c_second)

    y += int(H * 0.037)
    text(d, (W // 2, y), item['subtitle'], font(FONT_REG, 42), SUB_GRAY)

    frame_w = int(W * 0.753)
    phone = make_phone(shot_path, frame_w, use_frame, do_uncase, item.get('crop_bottom', 0.0),
                      fill_notches, item.get('screen_ratio'))
    if use_frame:
        shadow, pad = drop_shadow(phone)
        px = (W - phone.width) // 2
        py = int(H * 0.178)
        canvas.paste(shadow, (px - pad, py - pad), shadow)
        canvas.paste(phone, (px, py), phone)
    else:
        # 自带机身：按可用高度等比缩放后居中（高度对齐原版 92.8% 收口）
        avail_h = int(H * 0.75)
        scale = avail_h / phone.height
        ph = int(phone.height * scale)
        pw = int(phone.width * scale)
        phone = phone.resize((pw, ph), Image.LANCZOS)
        px = (W - pw) // 2
        py = int(H * 0.178)
        canvas.paste(phone, (px, py), phone)
    return canvas


def render_agc(item, shot_path, size=(1920, 1080), use_frame=True, do_uncase=False,
              fill_notches=False):
    W, H = size
    canvas = horizontal_gradient(size, BG_TOP, BG_BOTTOM)
    d = ImageDraw.Draw(canvas)

    left_x = int(W * 0.075)
    blue_first = item.get('tone', 'gray-first') == 'blue-first'
    c_first, c_second = (BRAND_BLUE, TITLE_DARK) if blue_first else (TITLE_DARK, BRAND_BLUE)
    brand = item.get('brand', 'UBAA')
    y = int(H * 0.24)
    d.text((left_x, y), brand, font=font(FONT_BOLD, 52), fill=BRAND_BLUE)

    y += int(H * 0.12)
    d.text((left_x, y), item['title'], font=font(FONT_BOLD, 96), fill=c_first)

    y += int(H * 0.15)
    d.text((left_x, y), item['title2'], font=font(FONT_BOLD, 96), fill=c_second)

    y += int(H * 0.11)
    d.text((left_x, y), item['subtitle'], font=font(FONT_REG, 44), fill=SUB_GRAY)

    phone_h = int(H * 0.84)
    shot = load_screen(shot_path, do_uncase, item.get('crop_bottom', 0.0))
    frame_w = int(phone_h * shot.width / shot.height)
    phone = make_phone(shot_path, frame_w, use_frame, do_uncase, item.get('crop_bottom', 0.0),
                      fill_notches, item.get('screen_ratio'))
    if use_frame:
        shadow, pad = drop_shadow(phone, blur=24, offset=(0, 12), alpha=46)
        px = W - phone.width - int(W * 0.085)
        py = (H - phone.height) // 2
        canvas.paste(shadow, (px - pad, py - pad), shadow)
        canvas.paste(phone, (px, py), phone)
    else:
        # 原图带壳：按可用高度等比缩放后靠右放置
        avail_h = int(H * 0.88)
        scale = avail_h / phone.height
        ph = int(phone.height * scale)
        pw = int(phone.width * scale)
        phone = phone.resize((pw, ph), Image.LANCZOS)
        px = W - pw - int(W * 0.06)
        py = (H - ph) // 2
        canvas.paste(phone, (px, py), phone)
    return canvas


def main() -> int:
    ap = argparse.ArgumentParser(description='生成商店介绍图')
    ap.add_argument('--shots', required=True, help='截图目录')
    ap.add_argument('--config', required=True, help='配置 JSON')
    ap.add_argument('--out', required=True, help='输出目录')
    ap.add_argument('--target', default='both',
                    choices=['appstore', 'agc', 'tablet', 'both', 'all'])
    ap.add_argument('--no-frame', action='store_true',
                    help='不画程序化机身：纯截图直接贴（或裁壳后直接贴）')
    ap.add_argument('--uncase', action='store_true',
                    help='自动裁掉带壳截图的壳体，只留屏幕内容（消除四角黑角）')
    ap.add_argument('--fill-notch', action='store_true',
                    help='额外抹除状态栏上方的模板挖孔装饰（默认不抹，保留真机形态）')
    args = ap.parse_args()

    shots = os.path.abspath(args.shots)
    outdir = os.path.abspath(args.out)
    os.makedirs(outdir, exist_ok=True)

    with open(args.config, encoding='utf-8') as f:
        items = json.load(f)

    use_frame = not args.no_frame
    n = 0
    for i, item in enumerate(items, 1):
        src = os.path.join(shots, item['file'])
        if not os.path.exists(src):
            print(f'  [跳过] 缺图: {src}')
            continue
        stem = os.path.splitext(item['file'])[0]
        if args.target == 'tablet':
            p = os.path.join(outdir, f'{stem}_tablet.png')
            render_tablet(item, src, do_uncase=args.uncase,
                          fill_notches=args.fill_notch,
                          crop_bottom=item.get('crop_bottom', 0.0)).save(p, 'PNG', optimize=True)
            print(f'  {p}  1920x1280')
        if args.target in ('appstore', 'both', 'all'):
            p = os.path.join(outdir, f'{stem}_appstore.png')
            render_appstore(item, src, use_frame=use_frame, do_uncase=args.uncase,
                            fill_notches=args.fill_notch).save(p, 'PNG', optimize=True)
            print(f'  {p}  1290x2796')
        if args.target in ('agc', 'both', 'all'):
            p = os.path.join(outdir, f'{stem}_agc.png')
            render_agc_phone(item, src, use_frame=use_frame, do_uncase=args.uncase,
                             fill_notches=args.fill_notch).save(p, 'PNG', optimize=True)
            print(f'  {p}  1080x1920')
        n += 1

    print(f'\n完成：{n} 张主题 × 每套 1 张')
    if n < 3:
        print('[!] 少于 3 个主题，商店要求 3~10 张')
    return 0


if __name__ == '__main__':
    sys.exit(main())
