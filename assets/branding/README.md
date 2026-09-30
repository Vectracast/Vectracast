# Vectracast 图标资源

- `vectracast-logo.png`：1254 × 1254 RGBA 主图，保留深色圆角底板，底板外透明。
- `vectracast-menu-template.png`：1254 × 1254 RGBA 单色模板，保留轨道、箭头和两端节点，透明底。
- `launcher-rocket.svg`：用户提供的火箭路径，用于启动台左下角和顶部菜单栏；收紧画布留白，以单色模板适配系统外观。构建时导出 18pt 的 1x、2x、3x 透明 PNG。

图案来自用户提供的 Logo。本轮使用内置 image_gen 工具去除外部棋盘格、整理高清边缘，并生成简化菜单栏版本。原稿未覆盖。

运行 `npm run build` 会通过 `scripts/prepare-icons.swift` 保留 alpha 导出 16–1024px 的应用图标，再用 macOS iconutil 生成 AppIcon.icns；菜单栏导出 18pt 的 1x、2x、3x 位图并以 NSImage 模板模式显示。输出位于 `build/branding/`，应用资源同步写入 Vectracast.app。

## 主图生成提示词

```text
Use case: background-extraction.
Edit target: the attached user-designed Vectracast macOS app logo. Create a faithful high-resolution production app icon, ideally 2048 by 2048 RGBA PNG.
Change only: remove the checkerboard OUTSIDE the dark rounded square so the exterior is genuine transparent alpha, and clean/upscale the image for crisp antialiased edges and smooth lines. Preserve the dark charcoal rounded-square tile itself and its subtle diagonal gray gradient, the exact orbital/elliptical line composition, the ascending curved vector arrow pointing upper right, white outlined circular nodes, gray outer orbital arcs and small tick/dot details. Maintain the original geometry and line hierarchy; do not redesign. Center the tile with a narrow uniform transparent margin, about 2 percent per side. The interior dark tile remains opaque. No rendered checkerboard, no white background, no drop shadow, no text, no additional objects. Deliver one square icon image only.
```

## 菜单栏生成提示词

```text
Use case: logo-brand.
Input image: reference for Vectracast brand geometry, not a mockup to reproduce.
Create a simplified macOS menu bar template icon derived from the white inner lines of this logo. Output one centered square PNG with genuinely transparent alpha background, black ink only, no dark tile, no checkerboard, no gradients, no shadows, no words.
The mark: one diagonal orbital elliptical swoosh from lower left to upper right, two small open circular endpoint nodes at lower left and upper right, and a clear curved vector arrow pointing upper-right through the middle. Retain this distinctive directional gesture from the reference. Remove outer gray concentric arcs, all dotted ticks, crosshairs, and the extra small middle node. Simplify to an elegant continuous orbital sweep and vector arrow. Bold even smooth rounded strokes that remain legible at 18x18 points, roughly 70px stroke at a 1024px canvas. Comfortable 8 percent padding. Keep openings in the rings large enough to survive downsampling. Single flat black silhouette linework with fully transparent negative space; no white filling inside circles.
```

## 菜单栏最终加粗提示词

```text
Edit target: attached transparent black Vectracast menu bar mark. Preserve the existing orbital ellipse, upper-right vector arrow and two ring endpoints. Change only optical weight and simplify the doubled lower arc: use ONE lower elliptical arc, not parallel double strokes, and make every stroke about TWICE its current thickness with round caps and joins. This is an 18pt macOS menu-bar symbol: the original is too thin at that size. Ring centers and all negative spaces must remain genuinely transparent, no white fill. Pure black ink, transparent alpha everywhere else, no background tile, no text, no additional elements. Keep centered with generous padding.
```
