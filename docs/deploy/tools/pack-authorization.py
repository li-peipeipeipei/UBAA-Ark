#!/usr/bin/env python3
"""生成华为应用市场「授权书及其他材料」上传用的 zip。

把 authorization-materials/ 下的源材料渲染成 PDF，再按 AGC 要求打包：
  · zip 格式，≤200 MB
  · 仅包含 JPG / JPEG / BMP / PDF
  · 文件夹层级最多三层，累计 ≤200 个文件

用法：
    python pack-authorization.py [--out 输出zip路径]
"""

import argparse
import os
import subprocess
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..', '..'))     # 工程根
TOOLS = os.path.join(ROOT, 'docs', 'deploy', 'tools')
MAT = os.path.join(ROOT, 'docs', 'deploy', 'authorization-materials')
BUILD = os.path.join(MAT, 'build')

FILES = [
    ('授权书-软件著作权授权发行书.md', '01-授权书-软件著作权授权发行书.pdf', '授权发行书'),
    ('README-材料说明.md', '04-材料说明.pdf', None),
    (None, '02-MIT许可证-LICENSE.pdf', None),
    (None, '03-隐私政策.pdf', None),
]


def render(src_md, dst_pdf, title=None):
    cmd = [sys.executable, os.path.join(TOOLS, 'md2pdf.py'), src_md, dst_pdf]
    if title:
        cmd += ['--title', title]
    r = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT)
    if r.returncode != 0:
        print(r.stdout, r.stderr)
        raise SystemExit(f'渲染失败: {src_md}')
    print(r.stdout.strip())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default=os.path.join(MAT, '授权材料-UBAA.zip'))
    args = ap.parse_args()

    os.makedirs(BUILD, exist_ok=True)
    print('渲染 PDF：')
    for src_name, dst_name, title in FILES:
        if src_name:
            render(os.path.join(MAT, src_name), os.path.join(BUILD, dst_name), title)
        elif dst_name.startswith('02-MIT'):
            render(os.path.join(ROOT, 'LICENSE'), os.path.join(BUILD, dst_name),
                   'MIT License')
        elif dst_name.startswith('03-隐私'):
            render(os.path.join(ROOT, 'docs', 'legal', 'privacy-policy.md'),
                   os.path.join(BUILD, dst_name), 'UBAA 隐私政策')

    print('\n打包：')
    files = sorted(f for f in os.listdir(BUILD) if f.lower().endswith('.pdf'))
    with zipfile.ZipFile(args.out, 'w', zipfile.ZIP_DEFLATED) as z:
        for f in files:
            z.write(os.path.join(BUILD, f), arcname=f)
            print(f'  + {f}')

    size = os.path.getsize(args.out) / 1024 / 1024
    print(f'\n{args.out}\n{len(files)} 个文件，{size:.2f} MB')
    print('\n⚠️ 上传前请补齐：')
    print('   1) 05-上游同意上架邮件.pdf（上游回复原文截图转 PDF）')
    print('   2) 01-授权书 的签字盖章版（替换包内未签字版）')
    return 0


if __name__ == '__main__':
    sys.exit(main())
