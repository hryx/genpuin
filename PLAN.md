# genpuin — Generative Art Tool Design Plan

## Context

We want a lightweight, code-driven generative art tool inspired by [weird](https://github.com/inconvergent/weird). Unlike Processing or p5.js, this should be a minimal **pure library** — not a framework — where the user writes scripts that produce art. No IDE, no GUI, no runtime window, no C host. Just code in, image out.

The tool has **two complementary modes** of expression:
1. **Constructive**: build shapes explicitly (geometry-as-data) and draw them onto a canvas
2. **Procedural**: use **pens** — stateful agents that move through space, leaving marks

Both modes output to the same canvas and compose freely. Precision by default; organic effects (wobble, taper) are opt-in.

## Decisions Made

- **Architecture**: Pure scripting library (no C host). SVG is just strings, PPM is just bytes — no C needed.
- **Output**: SVG (primary) + PPM/P6 (secondary, for raster experimentation)
- **Scope**: Phase 1 (core MVP) + Phase 2 (noise, flow fields, patterns, PPM)
- **Language**: **Lua** — chosen after Step 0 POC comparison (see below).
- **Dual mode**: Both explicit geometry AND pen/walker agents as core abstractions.
- **Precision first**: Clean geometric output by default. Organic effects are functions you apply.

## Step 0 — Language Comparison (completed)

Built the same POC in both Janet and Lua (see `poc/` for both). Both produce identical SVG output (30 HSV circles + 200-step pen walk).

**Result**: Chose **Lua**. Reasons:
- Method syntax (`p:forward(10)`) reads naturally for sequential pen operations
- Infix arithmetic is cleaner for math-heavy art code (`0.15 * math.sin(step * 0.1)` vs nested S-expressions)
- Lua 5.4's native 64-bit integers avoid precision issues (Janet's all-float numbers required `int/s64` workaround for our LCG)
- Janet's advantages (macros, richer stdlib, immutable data) don't strongly serve the art-scripting use case

## Output Format Details

**SVG** — Plain text XML. Our minimal subset:
- `<svg>` wrapper with `xmlns`, `width`, `height`, `viewBox`
- `<rect>` for background
- `<circle cx="" cy="" r=""/>`
- `<line x1="" y1="" x2="" y2=""/>`
- `<path d="M... L... Q... C... Z"/>` for polylines, polygons, Bézier curves
- `<g>` for layers/groups
- Style attributes: `stroke`, `fill`, `stroke-width`, `opacity`, `stroke-linecap`

**PPM (P6)** — Binary raster. Header: `P6\n{W} {H}\n255\n`, then W×H×3 raw bytes (RGB). Requires a simple software rasterizer (Bresenham lines, filled circles/polygons). Convert to PNG externally: `convert out.ppm out.png`.

**Tradeoffs:**
- SVG: Infinite resolution, small files, plotter-friendly. No pixel effects.
- PPM: Pixel-level control, good for noise/density art. Fixed resolution, large files.
- Both are trivial to emit — supporting both costs little.

## Architecture

```
┌──────────────────────────────────────────────────┐
│                  User Script                     │
│              (Lua source file)                   │
├──────────────────────────────────────────────────┤
│  Two modes of expression:                        │
│                                                  │
│  Constructive        Procedural                  │
│  ─────────────       ──────────────              │
│  geo.circle(...)     pen = pen(canvas)            │
│  geo.line(...)       pen:forward(10)             │
│  geo.polygon(...)    pen:turn(0.3)               │
│  canvas:draw(shape)  pen:stroke()                │
│                                                  │
├────────┬────────┬────────┬──────┬────────────────┤
│  geo   │  rand  │ color  │ xform│    field       │
│ shapes,│  RNG,  │  RGB,  │affine│  flow, noise   │
│ paths, │ noise, │  HSV,  │matrix│  trace         │
│ curves │ dist   │  mix   │      │                │
├────────┴────────┴────────┴──────┴────────────────┤
│               canvas (scene)                     │
│      accumulates styled geometry from            │
│      both shapes and pen trails                  │
├──────────────────────────────────────────────────┤
│          export: SVG writer | PPM writer         │
└──────────────────────────────────────────────────┘
```

All geometry is **data** — shapes and pen trails are both just collections of points with style metadata. The canvas doesn't care how geometry was created.

## Module API Reference

### pen — Stateful Drawing Agent

A pen is a cursor with position, heading, and style. It accumulates a path as it moves. Call `stroke` to commit the current path to the canvas, or `lift` to start a new path segment.

| Function | Description |
|----------|-------------|
| `pen(canvas)` | Create a pen attached to a canvas |
| `pen:move-to(pos)` | Teleport pen (no mark). Starts a new sub-path. |
| `pen:forward(dist)` | Move forward along current heading, drawing a line |
| `pen:forward-to(pos)` | Move to a specific point, drawing a line |
| `pen:turn(angle)` | Rotate heading by angle (radians) |
| `pen:heading(angle)` | Set heading absolutely |
| `pen:stroke()` | Commit current path to canvas with current style, start new path |
| `pen:lift()` | Pick up pen (start new sub-path without committing) |
| `pen:set(key, value)` | Set style: `:color`, `:width`, `:opacity` |
| `pen:pos()` | Get current position as vec2 |
| `pen:x()`, `pen:y()` | Get current coordinates |

**Key behavior**: Style changes mid-path create a new segment. So if you change color halfway through, you get two styled polylines. This keeps SVG output clean.

### geo — Geometry Primitives

All geometry is immutable data. Shapes know nothing about color or style.

| Function | Description |
|----------|-------------|
| `vec2(x, y)` | 2D point/vector |
| `line(a, b)` | Line segment between two vec2s |
| `polyline(points)` | Open path through points |
| `polygon(points)` | Closed path through points |
| `circle(center, r)` | Circle |
| `arc(center, r, start, end)` | Circular arc |
| `rect(x, y, w, h)` | Rectangle |
| `bezier(p0, p1, p2, p3)` | Cubic Bézier curve |
| `sample-along(path, n)` | Sample n evenly-spaced points along a path |
| `subdivide(path, n)` | Insert midpoints, smoothing a path |
| `resample(path, n)` | Redistribute n points evenly along path |

### rand — Randomness & Noise

| Function | Description |
|----------|-------------|
| `seed(n)` | Set RNG seed for reproducibility |
| `rand()` | Random float in [0, 1) |
| `rand-range(lo, hi)` | Random float in [lo, hi) |
| `rand-int(lo, hi)` | Random integer in [lo, hi] |
| `gaussian(mean, stddev)` | Normal distribution (Box-Muller) |
| `pick(list)` | Random element from list |
| `shuffle(list)` | Fisher-Yates shuffle (returns new list) |
| `weighted-pick(list, weights)` | Weighted random selection |
| `rand-in-circle(center, r)` | Random point inside circle |
| `rand-on-circle(center, r)` | Random point on circle perimeter |
| `rand-in-rect(x, y, w, h)` | Random point inside rectangle |
| `perlin(x, y)` | Perlin noise, returns [-1, 1] *(Phase 2)* |
| `simplex(x, y)` | Simplex noise, returns [-1, 1] *(Phase 2)* |
| `fbm(x, y, octaves, lacunarity, gain)` | Fractal Brownian motion *(Phase 2)* |
| `poisson-disk(bounds, min-dist)` | Blue noise point distribution *(Phase 2)* |

### color — Color Manipulation

All colors are RGBA tuples/tables with values in [0, 1].

| Function | Description |
|----------|-------------|
| `rgb(r, g, b)` | Create color (alpha defaults to 1) |
| `rgba(r, g, b, a)` | Create color with alpha |
| `hsv(h, s, v)` | Create from HSV (h in [0, 1]) |
| `hsl(h, s, l)` | Create from HSL |
| `hex(str)` | Parse hex string `"#rrggbb"` or `"#rrggbbaa"` |
| `lerp-color(c1, c2, t)` | Interpolate between colors |
| `darken(c, amount)` | Darken by amount (0–1) |
| `lighten(c, amount)` | Lighten by amount (0–1) |
| `with-alpha(c, a)` | Return color with new alpha |

### xform — Spatial Transformations

Transforms produce **new geometry** (functional, no mutation).

| Function | Description |
|----------|-------------|
| `translate(shape, dx, dy)` | Move shape |
| `rotate(shape, angle)` | Rotate around origin (radians) |
| `rotate-around(shape, angle, pivot)` | Rotate around a point |
| `scale(shape, sx, sy?)` | Scale (uniform if sy omitted) |
| `scale-around(shape, sx, sy, pivot)` | Scale around a point |
| `reflect-x(shape)` / `reflect-y(shape)` | Mirror |

### canvas — Scene Accumulation

| Function | Description |
|----------|-------------|
| `canvas(width, height)` | Create drawing surface |
| `background(canvas, color)` | Set background color |
| `draw(canvas, shape, style)` | Add styled shape to canvas |
| `style(opts)` | Create style: stroke, fill, stroke-width, opacity |
| `layer(canvas, name)` | Start a named layer (SVG `<g>`) |

### export — Output

| Function | Description |
|----------|-------------|
| `export-svg(canvas, filename)` | Write SVG file |
| `export-ppm(canvas, filename, scale?)` | Rasterize to PPM *(Phase 2)* |

### field — Vector & Scalar Fields *(Phase 2)*

| Function | Description |
|----------|-------------|
| `flow-field(fn)` | Field from function `(x, y) -> angle` |
| `noise-field(scale)` | Perlin noise-based flow field |
| `trace(field, start, steps, step-size)` | Trace a streamline, returns polyline |

Fields compose naturally with pens — drive a pen's heading from a field value at its current position.

### repeat — Pattern & Symmetry *(Phase 2)*

| Function | Description |
|----------|-------------|
| `grid(cols, rows, spacing, fn)` | Call fn(x, y, col, row) at each grid cell |
| `radial(n, center, radius, fn)` | Call fn(pos, angle, i) around circle |
| `scatter(n, bounds, fn)` | Place n items using fn for position |

### fx — Organic Effects *(Phase 2, opt-in)*

Apply to paths or pen trails for hand-drawn character.

| Function | Description |
|----------|-------------|
| `jitter(path, amount)` | Displace each point by random amount |
| `smooth(path, iterations)` | Chaikin curve smoothing |
| `taper(path, start-width, end-width)` | Varying stroke width along path |
| `stipple(shape, density)` | Fill a shape with dots instead of solid fill |

### util — Math Helpers

| Function | Description |
|----------|-------------|
| `lerp(a, b, t)` | Linear interpolation |
| `map-range(v, in-lo, in-hi, out-lo, out-hi)` | Remap value |
| `clamp(v, lo, hi)` | Clamp to range |
| `dist(a, b)` | Euclidean distance |
| `angle(a, b)` | Angle from a to b |
| `norm(v)` | Normalize vec2 |

## Example: Both Modes Together (Janet)

```janet
(import gen)

(def c (gen/canvas 800 800))
(gen/background c (gen/hex "#0a0a1a"))
(gen/seed 42)

# --- Constructive mode: place circles at Poisson-distributed points ---
(def points (gen/poisson-disk [0 0 800 800] 60))
(each pt points
  (gen/draw c (gen/circle pt 2)
    (gen/style :fill (gen/hsv (/ (pt 0) 800) 0.3 0.5) :opacity 0.3)))

# --- Procedural mode: pens walk between nearby points ---
(loop [i :range [0 50]]
  (let [start (gen/pick points)
        p (gen/pen c)]
    (pen/move-to p start)
    (pen/set p :color (gen/hsv (/ i 50) 0.7 0.9))
    (pen/set p :width 0.8)
    (loop [_ :range [0 80]]
      (let [nearby (gen/pick points)
            angle (gen/angle (pen/pos p) nearby)]
        (pen/turn p (* 0.3 (- angle (pen/heading p))))
        (pen/forward p 4)))
    (pen/stroke p)))

(gen/export-svg c "constellation.svg")
```

## Example: Both Modes Together (Lua)

```lua
local gen = require("gen")

local c = gen.canvas(800, 800)
gen.background(c, gen.hex("#0a0a1a"))
gen.seed(42)

-- Constructive: place circles at Poisson-distributed points
local points = gen.poisson_disk({0, 0, 800, 800}, 60)
for _, pt in ipairs(points) do
    gen.draw(c, gen.circle(pt, 2),
        gen.style({ fill = gen.hsv(pt[1] / 800, 0.3, 0.5), opacity = 0.3 }))
end

-- Procedural: pens walk between nearby points
for i = 1, 50 do
    local start = gen.pick(points)
    local p = gen.pen(c)
    p:move_to(start)
    p:set("color", gen.hsv(i / 50, 0.7, 0.9))
    p:set("width", 0.8)
    for j = 1, 80 do
        local nearby = gen.pick(points)
        local a = gen.angle(p:pos(), nearby)
        p:turn(0.3 * (a - p:heading()))
        p:forward(4)
    end
    p:stroke()
end

gen.export_svg(c, "constellation.svg")
```

## Implementation Plan

### Step 0: Language Comparison POC ✓
Completed. Chose Lua. See `poc/` for both implementations.

### Phase 1: Core MVP
1. **Project setup** — directory structure, module layout
2. **vec2 + geo module** — point, line, polyline, polygon, circle, rect, bezier
3. **color module** — rgb, hsv, hsl, hex, lerp-color, darken, lighten
4. **style + canvas module** — canvas creation, draw, background, layers
5. **SVG export** — emit valid SVG from canvas contents
6. **pen module** — pen creation, move-to, forward, forward-to, turn, heading, stroke, lift, style changes creating new segments
7. **rand module** — seed, rand, rand-range, gaussian, pick, shuffle, geometric random points
8. **xform module** — translate, rotate, scale (applied to geometry data)
9. **util module** — lerp, map-range, clamp, dist, angle, norm
10. **Example scripts** — 3–4 scripts demonstrating both constructive and pen modes

### Phase 2: Expressive Power
11. **Perlin/Simplex noise** — pure implementation (classic algorithms)
12. **Flow fields** — flow-field, noise-field, trace; pen integration (drive heading from field)
13. **Poisson disk sampling** — Bridson's algorithm
14. **Repeat/pattern module** — grid, radial, scatter
15. **fx module** — jitter, smooth, taper, stipple (opt-in organic effects)
16. **PPM raster export** — P6 writer + simple software rasterizer (Bresenham lines, scanline polygon fill, midpoint circle)
17. **Path operations** — sample-along, subdivide, resample
18. **More example scripts** — flow fields, Poisson compositions, tiled patterns, pen + field combinations

## File Structure (tentative)

```
genpuin/
├── init.lua                    # main entry, re-exports all modules
├── geo.lua                     # geometry primitives
├── pen.lua                     # pen/walker agent
├── color.lua                   # color creation and manipulation
├── canvas.lua                  # scene accumulation
├── svg.lua                     # SVG export
├── ppm.lua                     # PPM export (Phase 2)
├── rand.lua                    # RNG + distributions
├── noise.lua                   # Perlin/Simplex (Phase 2)
├── field.lua                   # flow/scalar fields (Phase 2)
├── xform.lua                   # spatial transforms
├── repeat.lua                  # patterns/symmetry (Phase 2)
├── fx.lua                      # organic effects (Phase 2)
├── util.lua                    # math helpers
└── examples/
    ├── random-walk.lua         # basic pen walk
    ├── circles.lua             # constructive mode demo
    ├── constellation.lua       # both modes together
    ├── flow-field.lua          # Phase 2
    ├── poisson.lua             # Phase 2
    └── tiling.lua              # Phase 2
```

## Verification

- Run each example script, open SVG in browser — visual inspection
- Same seed produces identical output (reproducibility)
- Phase 2: render same scene to SVG and PPM, compare visually
- Stress test: 10k+ shapes / long pen trails for performance
- Ergonomics test: write a new art script from scratch using only the API
