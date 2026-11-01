# Glued Double-Tree Horizon Bridge

`[MODEL ILLUSTRATION - RUNG_4_MODEL]`

This is an abstract graph-topology research visualization in the isolated
`WorldModelDemo` target. AdS/dS terminology labels upper and lower regions and a
central horizon analogy; this graph is not a discretization of a derived
Lorentzian spacetime solution.

## Topology choice and cellular homotopy equivalence

Each rooted binary tree of depth `n_H` has `2^(n_H+1) - 1` vertices,
`2^(n_H+1) - 2` edges, and `2^n_H` horizon leaves. Before gluing, the two
disjoint trees (Frame 1) form a two-component forest with:

- `V_0 = 2 * (2^(n_H+1) - 1) = 4 * 2^n_H - 2`
- `E_0 = 2 * (2^(n_H+1) - 2) = 4 * 2^n_H - 4`
- `beta0 = 2`, `beta1 = 0`, and `bridges = E_0`

Three distinct horizon operations are supported in `HorizonBridgeFixture.Topology`:

1. **`pairedHorizonLinks` (collar bridge across distinct leaf rows):**
   Retains both copies of the `2^n_H` horizon leaves (placed at `y = +0.25` and
   `y = -0.25`) and connects each matched leaf pair with an explicit vertical
   horizon edge (`2^n_H` cross-edges total):
   - `V = 4 * 2^n_H - 2`
   - `E = 5 * 2^n_H - 4`
   - `beta0 = 1`
   - `beta1 = E - V + beta0 = 2^n_H - 1`
   - `bridges = 0` (every tree edge and horizon link now lies on a fundamental cycle)

2. **`identifyLeaves` (quotient seam at `y = 0`):**
   Quotients each lower leaf onto its matching upper partner at `y = 0`
   (matching Panel B of the reference figure). Because the `2^n_H` horizon
   links in `pairedHorizonLinks` form a vertex-disjoint matching (a 1-dimensional
   forest), contracting those `2^n_H` edges reduces both `V` and `E` by `2^n_H`
   and is a cellular homotopy equivalence:
   - `V = 3 * 2^n_H - 2`
   - `E = 4 * 2^n_H - 4`
   - `beta0 = 1`
   - `beta1 = E - V + beta0 = 2^n_H - 1`
   - `bridges = 0`

3. **`singleHorizonBridge` (single-contact tree control, `beta1 = 0`):**
   Retains both leaf sets and joins only the primary leaf pair (`index = 0`)
   with a single bridge edge. Connecting two trees at a single contact point
   produces one connected tree with zero cycles:
   - `V = 4 * 2^n_H - 2`
   - `E = 4 * 2^n_H - 3`
   - `beta0 = 1`
   - `beta1 = 0`
   - `bridges = E = 4 * 2^n_H - 3`

### Exact counts for depths 1 to 6

| Depth `n_H` | Horizon Leaves `2^n_H` | `pairedHorizonLinks` `(V, E, beta1, bridges)` | `identifyLeaves` `(V, E, beta1, bridges)` | `singleHorizonBridge` `(V, E, beta1, bridges)` |
| :---: | :---: | :---: | :---: | :---: |
| 1 | 2 | `(6, 6, 1, 0)` | `(4, 4, 1, 0)` | `(6, 5, 0, 5)` |
| 2 | 4 | `(14, 16, 3, 0)` | `(10, 12, 3, 0)` | `(14, 13, 0, 13)` |
| 3 | 8 | `(30, 36, 7, 0)` | `(22, 28, 7, 0)` | `(30, 29, 0, 29)` |
| 4 | 16 | `(62, 76, 15, 0)` | `(46, 60, 15, 0)` | `(62, 61, 0, 61)` |
| 5 | 32 | `(126, 156, 31, 0)` | `(94, 124, 31, 0)` | `(126, 125, 0, 125)` |
| 6 | 64 | `(254, 316, 63, 0)` | `(190, 252, 63, 0)` | `(254, 253, 0, 253)` |

The values displayed in the app and exported in JSON are always calculated from
the frame's actual edge and vertex sets. Tarjan's DFS algorithm independently
reports bridge edges and is verified against a brute-force edge-removal oracle.

## Build and tests

```bash
swift test --filter DoubleTreeHorizonBridgeTests
swift test
```

## Generate exports

The graph fixture API is exposed through
`DoubleTreeHorizonBridge.make(depth:topology:)`. The exporter writes one
ChimeraX marker file (`.cmm`), one BILD edge file, and one JSON metadata file
per frame. Open a frame in ChimeraX:

```
open horizon-bridge-02.cmm
open horizon-bridge-02-edges.bild
```

The `.cmm` marker model includes both `<marker>` vertex coordinates/colors and
`<link>` edge connectivity. The companion `.bild` provides explicit non-zero
length cylinder geometry. JSON is the authoritative machine-readable node/edge
list and homology record.

## Visual interpretation

Upper branches are cyan, lower branches purple, and the horizon nodes/links
gold. The central band is a visual separator/highlight only; it does not
insert extra vertices or edges. Three frames show the upper tree (Frame 0),
both tree halves before horizon linking (Frame 1), and the final glued graph
(Frame 2).

The SceneKit/SwiftUI viewer is an abstract topology viewer. Its coordinates
are layout coordinates, not physical distances, and any curvature or
cosmological interpretation requires an independent metric construction.
