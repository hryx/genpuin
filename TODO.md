# TODO

## Platform support
- [x] Support Lua 5.1+ and LuaJIT (currently requires Lua 5.4)
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
- [x] Gradients — linear and radial (gradient, svg, ppm, color)
- [x] Gradients — pen integration
- [x] Blend modes — SVG
- [x] Blend modes — PPM
- [x] Blend modes — pen property

## Phase 4: Spatial & Layout
- [x] Voronoi diagram (`voronoi`)
- [x] Lloyd's relaxation (`relax`) — uses Voronoi internally
- [x] Circle packing (`packCircles`)
- [x] Point-in-shape tests (`pointInRect`, `pointInCircle`, `pointInPolygon`)
- [x] Nearest neighbor / spatial queries
- [x] Simple separation (push overlapping shapes apart)
