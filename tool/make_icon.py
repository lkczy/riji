# -*- coding: utf-8 -*-
"""把一张图片转成 Windows 程序图标（多尺寸 .ico）。

用法：
    python tool/make_icon.py <图片路径>
    python tool/make_icon.py <图片路径> --crop        # 非正方形时居中裁切

生成物直接覆盖 windows/runner/resources/app_icon.ico，重新构建即生效。
那个文件同时决定两件事：exe 在资源管理器里的图标，以及窗口/任务栏图标
（见 windows/runner/win32_window.cpp 里的 LoadIcon(IDI_APP_ICON)）。

## 为什么必须是多尺寸

Windows 在不同位置用不同尺寸：任务栏和 Alt+Tab 用 32，桌面大图标用 256，
详细列表用 16。只塞一张 256 的话，Windows 会自己缩放，小尺寸下又糊又脏。
所以这里一次生成一整套。

## 非正方形怎么办

默认**留白居中**补成正方形，而不是裁切：裁掉的部分找不回来，而图标留白
最多是难看一点，不会丢东西。确实想裁切就加 --crop。
"""
import argparse
import sys
from pathlib import Path

from PIL import Image

# Windows 实际会用到的尺寸。24 / 64 在较新的系统里也会出现。
SIZES = (16, 24, 32, 48, 64, 128, 256)


def to_square(image, crop):
    if image.width == image.height:
        return image
    if crop:
        side = min(image.size)
        left = (image.width - side) // 2
        top = (image.height - side) // 2
        return image.crop((left, top, left + side, top + side))
    side = max(image.size)
    canvas = Image.new('RGBA', (side, side), (0, 0, 0, 0))
    canvas.paste(image, ((side - image.width) // 2, (side - image.height) // 2), image)
    return canvas


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('source', help='源图片（PNG 最好，能带透明）')
    parser.add_argument('--out', default='windows/runner/resources/app_icon.ico')
    parser.add_argument('--crop', action='store_true',
                        help='非正方形时居中裁切，而不是留白')
    args = parser.parse_args()

    path = Path(args.source)
    if not path.exists():
        print('找不到图片：%s' % path)
        return 1

    with Image.open(path) as opened:
        image = opened.convert('RGBA')
        original = opened.size

    if min(original) < 256:
        print('提示：原图是 %dx%d，偏小。256 那张会被放大，会有点糊；'
              '建议用 512 以上的图。' % original)

    image = to_square(image, args.crop)

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    image.save(out, format='ICO', sizes=[(s, s) for s in SIZES])

    print('已生成 %s' % out)
    print('  源图 %dx%d → 补成 %dx%d → %d 个尺寸：%s'
          % (original[0], original[1], image.width, image.height,
             len(SIZES), ', '.join(str(s) for s in SIZES)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
