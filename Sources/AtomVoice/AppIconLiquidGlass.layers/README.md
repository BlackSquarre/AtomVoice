# AtomVoice Liquid Glass Icon Layers

This folder contains editable SVG layers derived from `../AppIcon.svg` for Icon Composer.

Use `../AppIconLiquidGlass.icon` for tuning in Icon Composer. The `.icon` bundle already includes copies of these layers under its `Assets/` directory.

Layer order is bottom to top:

1. `01-body-surface.svg`
2. `02-capsule-bezel.svg`
3. `03-inner-pill.svg`
4. `04-bars-blue.svg`
5. `05-bars-cyan.svg`
6. `06-bars-green.svg`

Design notes:

- The source keeps the original 1024 x 1024 canvas so layers drop into Icon Composer without manual alignment.
- Baked shadows and glow filters from the original SVG were removed or softened. Tune specular highlights, refraction, translucency, and shadows in Icon Composer instead.
- `../AppIconLiquidGlass.icon/icon.json` stores groups in the order Icon Composer renders correctly; this may appear reversed compared with the bottom-to-top source layer list here.
- The current shipping icon is not replaced yet. Treat this as a Liquid Glass working source.
