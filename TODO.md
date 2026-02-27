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
- [x] Catmull-Rom splines (geo, svg, ppm, xform)
- [x] Dashed lines — SVG style attrs
- [x] Dashed lines — FX function `dash()`
- [x] Dashed lines — pen property
- [x] PPM support for dashed lines

## Phase 3: Compositing & Color
- [ ] Gradients — linear and radial (gradient, svg, color)
- [ ] Gradients — pen integration
- [ ] Blend modes — SVG
- [ ] Blend modes — PPM
- [ ] Blend modes — pen property
- [ ] PPM support for gradients

## Phase 4: Spatial & Layout
- [ ] Voronoi diagram (`voronoi`)
- [ ] Lloyd's relaxation (`relax`) — uses Voronoi internally
- [ ] Circle packing (`packCircles`)
- [ ] Point-in-shape tests (`pointInRect`, `pointInCircle`, `pointInPolygon`)
- [ ] Nearest neighbor / spatial queries
- [ ] Simple separation (push overlapping shapes apart)
