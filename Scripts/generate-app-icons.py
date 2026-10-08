#!/usr/bin/env python3
"""生成 Movo 的 App 图标资源（iOS + macOS）。

设计概念：同心环形进度（“渐成”）。外环留一处顶部缺口表示仍在推进，内层一个
更细的完整圆环表示已经沉淀下来的积累。配色取 DesignSystem 的品牌主色
#247367 系（浅色主色 #247367 / 深色主色 #8ED1BC）。

几何规范：
  - iOS：满幅正方形，不透明、无 alpha，圆角由系统遮罩裁切。
  - macOS：系统不会为图标裁切圆角，必须自行绘制。按 Apple 模板，1024 画布
    内主体 824×824（左右留白 100，上 90 / 下 110），圆角用超椭圆（squircle）
    逼近，并在主体下方叠一层投影，留白用于容纳系统级阴影。

依赖：Python 3 + Pillow。Pillow 只用于本地重新生成图标，应用本身无 Python 依赖。

用法：
    python3 Scripts/generate-app-icons.py

结果直接写入 Movo/Assets.xcassets/AppIcon.appiconset/ 并同步 Contents.json。
仅在需要调整图标外观时运行；日常构建不需要执行。
"""

from __future__ import annotations

import json
import math
import os

from PIL import Image, ImageDraw, ImageFilter

# ---------------------------------------------------------------- 路径

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICON_SET = os.path.join(REPO_ROOT, "Movo", "Assets.xcassets", "AppIcon.appiconset")

# ---------------------------------------------------------------- 构图参数

SUPERSAMPLE = 4  # 超采样倍率，用于消除圆弧与超椭圆边缘的锯齿

# 半径与描边宽度均以画面边长的比例表示；半径为圆环中线。
# 起始角与张角使用钟表语义：0° 在 12 点方向，顺时针为正。
OUTER_RING = {"radius": 0.305, "stroke": 0.092, "start": 60.65, "sweep": 238.7}
INNER_RING = {"radius": 0.157, "stroke": 0.062, "start": 0.0, "sweep": 360.0}

MACOS_CANVAS = 1024
MACOS_BODY = 824
MACOS_MARGIN_SIDE = 100
MACOS_MARGIN_TOP = 90
MACOS_CORNER_RADIUS = 185.4
SQUIRCLE_EXPONENT = 5.0  # 超椭圆指数，越大越接近直角

SHADOW_ALPHA = 60  # 0-255，约 24%，比 Apple 模板略轻，避免小尺寸下发灰
SHADOW_BLUR_RATIO = 0.030
SHADOW_OFFSET_RATIO = 0.018

# ---------------------------------------------------------------- 配色

PALETTES = {
    # 默认（浅色）：品牌主色渐变 + 近白外环 + 薄荷内环
    "light": {
        "bg_top": "#2C8475",
        "bg_bottom": "#1D6155",
        "ring_outer": "#F3FBF8",
        "ring_inner": "#8ED1BC",
    },
    # 深色：压暗底色并提亮圆环，保证在深色主屏上仍有层次
    "dark": {
        "bg_top": "#1F5A4E",
        "bg_bottom": "#0E2C26",
        "ring_outer": "#CBEFE2",
        "ring_inner": "#74BCA8",
    },
    # 着色：只提供灰度，亮度交给系统按用户选择的颜色映射
    "tinted": {
        "bg_top": "#2C8475",
        "bg_bottom": "#1D6155",
        "ring_outer": "#F3FBF8",
        "ring_inner": "#8ED1BC",
    },
}


def hex_to_rgb(value: str) -> tuple[int, int, int]:
    s = value.lstrip("#")
    return int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16)


# ---------------------------------------------------------------- 基础绘制


def linear_gradient(size: int, top: str, bottom: str) -> Image.Image:
    """竖直线性渐变。先构造 1px 宽的列再放大，避免逐像素填充。"""
    c0, c1 = hex_to_rgb(top), hex_to_rgb(bottom)
    column = Image.new("RGB", (1, size))
    pixels = column.load()
    for y in range(size):
        t = y / (size - 1) if size > 1 else 0.0
        pixels[0, y] = tuple(round(c0[i] + (c1[i] - c0[i]) * t) for i in range(3))
    return column.resize((size, size), Image.Resampling.BICUBIC)


def draw_ring(
    draw: ImageDraw.ImageDraw,
    center: tuple[float, float],
    radius: float,
    stroke: float,
    start_deg: float,
    sweep_deg: float,
    color: tuple[int, int, int],
) -> None:
    """画一段带圆头端帽的圆弧，半径为圆环中线。

    PIL 的 `arc(width=)` 是自外缘向内扩宽，因此包围盒要按「中线半径 + 半个
    描边」给出，圆环才会正好跨在中线两侧；端帽是半径 stroke/2 的实心圆，圆心
    落在中线的角度端点，与弧端严丝合缝。
    """
    cx, cy = center
    bbox_radius = radius + stroke / 2.0
    bbox = [cx - bbox_radius, cy - bbox_radius, cx + bbox_radius, cy + bbox_radius]

    # 钟表语义 → PIL 角度（PIL 以 3 点钟为 0°，顺时针增大）
    start = 270.0 + start_deg
    end = start + sweep_deg
    draw.arc(bbox, start, end, fill=color, width=max(1, round(stroke)))

    if sweep_deg < 360.0 - 1e-6:  # 整圆时两端重合，无需端帽
        cap_radius = stroke / 2.0
        for angle in (start, end):
            rad = math.radians(angle)
            px = cx + radius * math.cos(rad)
            py = cy + radius * math.sin(rad)
            draw.ellipse(
                [px - cap_radius, py - cap_radius, px + cap_radius, py + cap_radius],
                fill=color,
            )


def render_artwork(side: int, palette: dict[str, str]) -> Image.Image:
    """在边长 `side` 的正方形内绘制完整图案（不含圆角与投影）。"""
    image = linear_gradient(side, palette["bg_top"], palette["bg_bottom"])
    draw = ImageDraw.Draw(image)
    center = (side / 2.0, side / 2.0)

    for ring, color_key in ((OUTER_RING, "ring_outer"), (INNER_RING, "ring_inner")):
        draw_ring(
            draw,
            center,
            radius=side * ring["radius"],
            stroke=side * ring["stroke"],
            start_deg=ring["start"],
            sweep_deg=ring["sweep"],
            color=hex_to_rgb(palette[color_key]),
        )
    return image


def squircle_mask(side: int, exponent: float) -> Image.Image:
    """超椭圆（squircle）遮罩，用于逼近 Apple 图标的连续曲率圆角。

    用解析参数方程生成高密度多边形并 4 倍超采样，再缩至目标尺寸。
    指数大于 2 时超椭圆在顶点附近趋于平直、在角部平滑过渡，正是 squircle 的形态。
    """
    scale = 4
    big = side * scale
    half = big / 2.0
    steps = 2048
    points = []
    for i in range(steps):
        theta = 2.0 * math.pi * i / steps
        cos_t, sin_t = math.cos(theta), math.sin(theta)
        x = math.copysign(abs(cos_t) ** (2.0 / exponent), cos_t)
        y = math.copysign(abs(sin_t) ** (2.0 / exponent), sin_t)
        points.append((half + x * half, half + y * half))

    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).polygon(points, fill=255)
    return mask.resize((side, side), Image.Resampling.LANCZOS)


# ---------------------------------------------------------------- 导出


def render_ios(size: int, palette: dict[str, str], tinted: bool) -> Image.Image:
    work = size * SUPERSAMPLE
    image = render_artwork(work, palette).resize((size, size), Image.Resampling.LANCZOS)
    if tinted:
        image = image.convert("L").convert("RGB")  # 只保留亮度，由系统着色
    return image.convert("RGB")  # iOS 图标不得携带 alpha


def render_macos(size: int, palette: dict[str, str]) -> Image.Image:
    work = size * SUPERSAMPLE
    body = round(work * MACOS_BODY / MACOS_CANVAS)
    margin_side = (work - body) / 2.0
    margin_top = work * MACOS_MARGIN_TOP / MACOS_CANVAS

    artwork = render_artwork(body, palette)
    mask = squircle_mask(body, SQUIRCLE_EXPONENT)
    artwork.putalpha(mask)

    canvas = Image.new("RGBA", (work, work), (0, 0, 0, 0))

    blur = max(1.0, body * SHADOW_BLUR_RATIO)
    offset = body * SHADOW_OFFSET_RATIO
    shadow_mask = mask.filter(ImageFilter.GaussianBlur(blur))
    shadow = Image.new("RGBA", (body, body), (0, 0, 0, SHADOW_ALPHA))
    shadow.putalpha(shadow_mask.point(lambda v: v * SHADOW_ALPHA // 255))
    canvas.alpha_composite(shadow, (round(margin_side), round(margin_top + offset)))
    canvas.alpha_composite(artwork, (round(margin_side), round(margin_top)))

    return canvas.resize((size, size), Image.Resampling.LANCZOS)


MAC_SLOTS = [
    ("AppIcon-macOS-16.png", 16),
    ("AppIcon-macOS-16@2x.png", 32),
    ("AppIcon-macOS-32.png", 32),
    ("AppIcon-macOS-32@2x.png", 64),
    ("AppIcon-macOS-128.png", 128),
    ("AppIcon-macOS-128@2x.png", 256),
    ("AppIcon-macOS-256.png", 256),
    ("AppIcon-macOS-256@2x.png", 512),
    ("AppIcon-macOS-512.png", 512),
    ("AppIcon-macOS-512@2x.png", 1024),
]

MAC_ENTRIES = [
    ("1x", "16x16", "AppIcon-macOS-16.png"),
    ("2x", "16x16", "AppIcon-macOS-16@2x.png"),
    ("1x", "32x32", "AppIcon-macOS-32.png"),
    ("2x", "32x32", "AppIcon-macOS-32@2x.png"),
    ("1x", "128x128", "AppIcon-macOS-128.png"),
    ("2x", "128x128", "AppIcon-macOS-128@2x.png"),
    ("1x", "256x256", "AppIcon-macOS-256.png"),
    ("2x", "256x256", "AppIcon-macOS-256@2x.png"),
    ("1x", "512x512", "AppIcon-macOS-512.png"),
    ("2x", "512x512", "AppIcon-macOS-512@2x.png"),
]


def build_contents() -> dict:
    ios_appearances = [
        (None, "AppIcon-iOS-1024.png"),
        ("dark", "AppIcon-iOS-Dark-1024.png"),
        ("tinted", "AppIcon-iOS-Tinted-1024.png"),
    ]
    images = []
    for appearance, filename in ios_appearances:
        entry = {
            "filename": filename,
            "idiom": "universal",
            "platform": "ios",
            "size": "1024x1024",
        }
        if appearance is not None:
            entry["appearances"] = [{"appearance": "luminosity", "value": appearance}]
        images.append(entry)

    for scale, size, filename in MAC_ENTRIES:
        images.append(
            {"filename": filename, "idiom": "mac", "scale": scale, "size": size}
        )

    return {"images": images, "info": {"author": "xcode", "version": 1}}


def main() -> None:
    os.makedirs(ICON_SET, exist_ok=True)
    written: list[str] = []

    def save(image: Image.Image, name: str) -> None:
        image.save(os.path.join(ICON_SET, name), format="PNG", optimize=True)
        written.append(name)

    # iOS 26：单一 1024 尺寸，附带深色与着色外观变体
    save(render_ios(1024, PALETTES["light"], tinted=False), "AppIcon-iOS-1024.png")
    save(render_ios(1024, PALETTES["dark"], tinted=False), "AppIcon-iOS-Dark-1024.png")
    save(render_ios(1024, PALETTES["tinted"], tinted=True), "AppIcon-iOS-Tinted-1024.png")

    # macOS：每个槽位独立文件，不依赖资源目录对同名文件的去重行为
    for name, size in MAC_SLOTS:
        save(render_macos(size, PALETTES["light"]), name)

    with open(os.path.join(ICON_SET, "Contents.json"), "w", encoding="utf-8") as handle:
        json.dump(build_contents(), handle, indent=2, ensure_ascii=False)
        handle.write("\n")

    print(f"已写入 {ICON_SET}")
    for name in written:
        byte_size = os.path.getsize(os.path.join(ICON_SET, name))
        print(f"  {name:32s} {byte_size / 1024:8.1f} KB")


if __name__ == "__main__":
    main()
