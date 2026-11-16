#!/usr/bin/env python3
"""把真机截图批量转换成华为应用市场可用的商店截图。

AGC 要求：宽高比 16:9（横向）或 9:16（竖向），最低 1920x1080（竖向 1080x1920），
格式 PNG / JPG / JPEG（<=5 MB）或 WEBP（<=200 KB）。

裁剪策略（重要）：
  · 竖屏（9:16）—— **不裁内容**。原图 1316x2832 等比缩到高 1920（宽 892），
    左右用品牌蓝补边到 1080。居中裁剪会把状态栏和底部页签各切一半，
    底部页签是这个应用的主要导航，缺一不可。
  · 横屏（16:9）—— 居中裁切。横屏界面左右是次要内容，裁掉不影响信息完整性。

用法：
    python prep-screenshots.py <输入目录> [--out 输出目录] [--mode both|landscape|portrait]
                             [--width 1920] [--height 1080]

处理规则：
  · 横屏原图（宽 > 高）→ 居中裁到 16:9 → 缩放到 1920x1080
  · 竖屏原图（宽 <= 高）→ 等比缩放不裁 → 左右品牌色补边 → 1080x1920
  · 输出统一命名 01_<原文件名>.png，按文件名自然序编号
"""

import argparse
import os
import re
import sys

from PIL import Image

EXTS = ('.jpg', '.jpeg', '.png', '.webp', '.bmp')
BRAND = (25, 118, 210)          # #1976D2，与应用图标底色一致


def natural_key(name: str):
    """让 'shot2.png' 排在 'shot10.png' 前面。"""
    return [int(t) if t.isdigit() else t.lower() for t in re.split(r'(\d+)', name)]


def crop_to_ratio(im: Image.Image, num: int, den: int) -> Image.Image:
    """居中裁到 num:den（宽:高）比例。"""
    w, h = im.size
    target = num / den
    cur = w / h
    if abs(cur - target) < 1e-3:
        return im
    if cur > target:                       # 太宽，裁左右
        new_w = int(round(h * target))
        left = (w - new_w) // 2
        return im.crop((left, 0, left + new_w, h))
    new_h = int(round(w / target))          # 太高，裁上下
    top = (h - new_h) // 2
    return im.crop((0, top, w, top + new_h))


def fit_with_pad(im: Image.Image, tw: int, th: int, pad: tuple) -> Image.Image:
    """等比缩放完整放入 (tw, th)，余下用 pad 色填充。绝不裁内容。"""
    w, h = im.size
    scale = min(tw / w, th / h)
    nw, nh = max(1, int(round(w * scale))), max(1, int(round(h * scale)))
    inner = im.convert('RGB').resize((nw, nh), Image.LANCZOS)
    canvas = Image.new('RGB', (tw, th), pad)
    canvas.paste(inner, ((tw - nw) // 2, (th - nh) // 2))
    return canvas


def main() -> int:
    ap = argparse.ArgumentParser(description='生成 AGC 商店截图')
    ap.add_argument('indir', help='输入目录（放真机截图）')
    ap.add_argument('--out', default=None, help='输出目录，默认 <indir>/../store')
    ap.add_argument('--mode', default='both', choices=['both', 'landscape', 'portrait'])
    ap.add_argument('--width', type=int, default=1920)
    ap.add_argument('--height', type=int, default=1080)
    ap.add_argument('--max-mb', type=float, default=4.5, help='单张 PNG 上限 MB，留余量')
    args = ap.parse_args()

    indir = os.path.abspath(args.indir)
    outdir = os.path.abspath(args.out) if args.out else os.path.join(indir, '..', 'store')
    if not os.path.isdir(indir):
        print(f'[!] 输入目录不存在: {indir}')
        return 1
    os.makedirs(outdir, exist_ok=True)

    files = sorted(
        [f for f in os.listdir(indir)
         if f.lower().endswith(EXTS) and not f.startswith('.')],
        key=natural_key)
    if not files:
        print(f'[!] {indir} 里没有找到图片')
        return 1

    print(f'输入 {indir} 共 {len(files)} 张 → 输出 {outdir}')
    made = []
    for i, name in enumerate(files, 1):
        src = os.path.join(indir, name)
        try:
            im = Image.open(src)
            im.load()
        except Exception as e:                      # noqa: BLE001
            print(f'  跳过 {name}: {e}')
            continue

        landscape = im.width > im.height
        if args.mode == 'landscape' and not landscape:
            continue
        if args.mode == 'portrait' and landscape:
            continue

        if landscape:
            # 横屏：居中裁到 16:9（横屏界面左右是次要内容），再缩放到目标尺寸
            out = crop_to_ratio(im, 16, 9).convert('RGB').resize(
                (args.width, args.height), Image.LANCZOS)
        else:
            # 竖屏：完整保留内容，等比缩放后左右品牌色补边（居中裁会切掉状态栏和底部页签）
            out = fit_with_pad(im, args.height, args.width, BRAND)

        stem = os.path.splitext(name)[0]
        dst = os.path.join(outdir, f'{i:02d}_{stem}.png')
        out.save(dst, 'PNG', optimize=True)

        size_mb = os.path.getsize(dst) / 1024 / 1024
        flag = '  [!] 超过上限' if size_mb > args.max_mb else ''
        print(f'  {name} {im.size} → {out.size} {size_mb:.2f} MB{flag}')
        made.append(dst)

    print(f'\n完成：{len(made)} 张')
    if len(made) < 3:
        print('[!] 少于 3 张，AGC 要求 3~10 张，请补图')
    if len(made) > 10:
        print(f'[!] 超过 10 张上限，请删减到 10 张以内')
    return 0


if __name__ == '__main__':
    sys.exit(main())
