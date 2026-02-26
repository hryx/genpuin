# TODO

- [ ] Support Lua 5.1+ and LuaJIT (currently requires Lua 5.4)
- [ ] Add LuaRocks rockspec for package distribution
- [ ] Windows support (PowerShell install script or LuaRocks-only)

## Phase 1: Primitives & Math
- [x] Ellipse primitive (geo, svg, ppm, xform)
- [x] Rounded rectangles (geo, svg, ppm)
- [x] Bezier point/tangent evaluation (geo)
- [x] Vector math utilities (geo, util)

## Phase 2: Curves & Paths
- [ ] Catmull-Rom splines (geo, svg, ppm, xform)
- [ ] Dashed lines — SVG style attrs
- [ ] Dashed lines — FX function `dash()`
- [ ] Dashed lines — pen property
- [ ] PPM support for dashed lines

## Phase 3: Compositing & Color
- [ ] Gradients — linear and radial (gradient, svg, color)
- [ ] Gradients — pen integration
- [ ] Blend modes — SVG
- [ ] Blend modes — PPM
- [ ] Blend modes — pen property
- [ ] PPM support for gradients
