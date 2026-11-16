#!/usr/bin/env python3
"""把 Markdown 渲染成 A4 PDF（用于软著/授权材料的 PDF 上传）。

支持：# ~ ### 标题、段落、- 无序列表、1. 有序列表、| 表格、> 引用、--- 分隔线、
`行内代码`、**加粗**。纯文本版式，够用于版权授权书与隐私政策附件。

用法：
    python md2pdf.py <输入.md> <输出.pdf> [--title "封面标题"]
"""

import argparse
import os
import re
import sys

from PIL import Image, ImageDraw, ImageFont

PAGE_W, PAGE_H = 1240, 1754          # A4 @150dpi
MARGIN = 110
FONT_REG = r'C:\Windows\Fonts\msyh.ttc'
FONT_BOLD = r'C:\Windows\Fonts\msyhbd.ttc'

FS_BODY = 26
FS_H1, FS_H2, FS_H3 = 42, 34, 30
LEAD = 1.75


def font(path, size):
    try:
        return ImageFont.truetype(path, size)
    except Exception:                                  # noqa: BLE001
        return ImageFont.load_default()


def strip_md(s):
    """去 markdown 标记，取纯文本。"""
    s = re.sub(r'`([^`]*)`', r'\1', s)
    s = re.sub(r'\*\*([^*]*)\*\*', r'\1', s)
    s = re.sub(r'\*([^*]*)\*', r'\1', s)
    s = re.sub(r'\[([^\]]*)\]\(([^)]*)\)', r'\1（\2）', s)
    return s


NO_LINE_START = '，。、；：！？）》」』%'          # 避头尾：不能出现在行首


def wrap(draw, text, f, max_w):
    """按像素宽度折行，中文按字、英文按词；标点不落行首。"""
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


def collect_continuation(lines, i):
    """收集列表项的缩进续行，返回 (合并文本, 新的行号)。"""
    parts = []
    while i < len(lines):
        nxt = lines[i]
        if not nxt.strip():
            break
        if nxt.startswith((' ', '\t')) and not re.match(r'^\s*([-*]|\d+[.)])\s+', nxt):
            parts.append(strip_md(nxt.strip()))
            i += 1
            continue
        break
    return (('　' + '　'.join(parts)) if parts else ''), i


class Renderer:
    def __init__(self):
        self.img = Image.new('RGB', (PAGE_W, PAGE_H), 'white')
        self.d = ImageDraw.Draw(self.img)
        self.y = MARGIN
        self.pages = []

    def new_page(self):
        self.pages.append(self.img.copy())
        self.img = Image.new('RGB', (PAGE_W, PAGE_H), 'white')
        self.d = ImageDraw.Draw(self.img)
        self.y = MARGIN

    def ensure(self, h):
        if self.y + h > PAGE_H - MARGIN:
            self.new_page()

    def para(self, text, size=FS_BODY, bold=False, indent=0, color=(0, 0, 0),
             gap=10, align='left'):
        f = font(FONT_BOLD if bold else FONT_REG, size)
        max_w = PAGE_W - 2 * MARGIN - indent
        for line in wrap(self.d, text, f, max_w):
            self.ensure(int(size * LEAD))
            x = MARGIN + indent
            if align == 'center':
                x = (PAGE_W - self.d.textlength(line, font=f)) / 2
            self.d.text((x, self.y), line, font=f, fill=color)
            self.y += int(size * LEAD)
        self.y += gap

    def heading(self, level, text):
        sizes = {1: FS_H1, 2: FS_H2, 3: FS_H3}
        size = sizes.get(level, FS_BODY)
        self.y += 18 if level <= 2 else 10
        self.ensure(size * 2)
        self.para(text, size=size, bold=True, gap=14 if level <= 2 else 8)

    def rule(self):
        self.ensure(20)
        self.d.line([(MARGIN, self.y), (PAGE_W - MARGIN, self.y)], fill=(200, 200, 200), width=2)
        self.y += 22

    def quote(self, text):
        f = font(FONT_REG, FS_BODY - 2)
        lines = wrap(self.d, text, f, PAGE_W - 2 * MARGIN - 40)
        h = len(lines) * int((FS_BODY - 2) * LEAD) + 24
        self.ensure(h)
        self.d.rectangle([MARGIN, self.y, MARGIN + 5, self.y + h - 16], fill=(37, 99, 235))
        yy = self.y + 6
        for line in lines:
            self.d.text((MARGIN + 24, yy), line, font=f, fill=(60, 60, 60))
            yy += int((FS_BODY - 2) * LEAD)
        self.y += h

    def table(self, rows):
        if not rows:
            return
        ncol = max(len(r) for r in rows)
        f = font(FONT_REG, FS_BODY - 4)
        fb = font(FONT_BOLD, FS_BODY - 4)
        col_w = (PAGE_W - 2 * MARGIN) // ncol
        for ri, row in enumerate(rows):
            cells = [strip_md(c) for c in row] + [''] * (ncol - len(row))
            wrapped = [wrap(self.d, c, fb if ri == 0 else f, col_w - 20) for c in cells]
            rh = max(len(w) for w in wrapped) * int((FS_BODY - 4) * 1.5) + 16
            self.ensure(rh)
            x0 = MARGIN
            for ci in range(ncol):
                self.d.rectangle([x0, self.y, x0 + col_w - 4, self.y + rh],
                                 outline=(210, 210, 210), width=1,
                                 fill=(240, 245, 252) if ri == 0 else None)
                yy = self.y + 8
                for line in wrapped[ci]:
                    self.d.text((x0 + 10, yy), line, font=fb if ri == 0 else f,
                                fill=(20, 20, 20))
                    yy += int((FS_BODY - 4) * 1.5)
                x0 += col_w
            self.y += rh
        self.y += 16

    def save(self, path):
        self.pages.append(self.img.copy())
        pages = [p.convert('RGB') for p in self.pages]
        pages[0].save(path, 'PDF', resolution=150.0, save_all=True,
                      append_images=pages[1:])
        return len(pages)


def render(md_path, pdf_path, cover_title=None, preview_png=None):
    with open(md_path, encoding='utf-8') as f:
        lines = f.read().split('\n')
    r = Renderer()
    if cover_title:
        r.para(cover_title, size=46, bold=True, align='center', gap=30)
        r.rule()
    i = 0
    while i < len(lines):
        raw = lines[i]
        line = raw.rstrip()
        s = line.strip()

        if not s:
            i += 1
            continue

        if s.startswith('|'):
            block = []
            while i < len(lines) and lines[i].strip().startswith('|'):
                cells = [c.strip() for c in lines[i].strip().strip('|').split('|')]
                if not all(re.fullmatch(r':?-{2,}:?', c) for c in cells):
                    block.append(cells)
                i += 1
            r.table(block)
            continue

        if re.fullmatch(r'-{3,}', s):
            r.rule()
            i += 1
            continue

        m = re.match(r'^(#{1,4})\s+(.*)', s)
        if m:
            r.heading(len(m.group(1)), strip_md(m.group(2)))
            i += 1
            continue

        if s.startswith('>'):
            buf = []
            while i < len(lines) and lines[i].strip().startswith('>'):
                buf.append(strip_md(lines[i].strip().lstrip('>').strip()))
                i += 1
            r.quote(' '.join(buf))
            continue

        if re.match(r'^[-*]\s+', s):
            while i < len(lines) and re.match(r'^[-*]\s+', lines[i].strip()):
                txt = strip_md(re.sub(r'^[-*]\s+', '', lines[i].strip()))
                i += 1
                cont, i = collect_continuation(lines, i)   # 合并缩进续行
                r.para('· ' + txt + cont, indent=16, gap=2)
            r.y += 10
            continue

        if re.match(r'^\d+[.)]\s+', s):
            while i < len(lines) and re.match(r'^\d+[.)]\s+', lines[i].strip()):
                raw_item = lines[i].strip()
                num = re.match(r'^(\d+)[.)]\s+', raw_item).group(1)
                txt = strip_md(re.sub(r'^\d+[.)]\s+', '', raw_item))
                i += 1
                cont, i = collect_continuation(lines, i)
                r.para(f'{num}. {txt}{cont}', indent=16, gap=2)
            r.y += 10
            continue

        buf = []
        while i < len(lines) and lines[i].strip() and not re.match(
                r'^(#{1,4}\s|\||>|\d+[.)]\s|[-*]\s|-{3,}$)', lines[i].strip()):
            buf.append(strip_md(lines[i].strip()))
            i += 1
        r.para(' '.join(buf))

    n = r.save(pdf_path)
    print(f'  {pdf_path}  {n} 页  {os.path.getsize(pdf_path)//1024} KB')
    if preview_png:
        r.pages[0].save(preview_png)
        print(f'  {preview_png}（首页预览）')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('src')
    ap.add_argument('dst')
    ap.add_argument('--title', default=None)
    ap.add_argument('--preview', default=None, help='额外导出首页 PNG 预览')
    args = ap.parse_args()
    render(args.src, args.dst, args.title, args.preview)
    return 0


if __name__ == '__main__':
    sys.exit(main())
