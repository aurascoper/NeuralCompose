# Glued Double-Tree Horizon Bridge

This is an abstract graph-topology research visualization in the isolated
`WorldModelDemo` target. AdS/dS terminology labels upper/lower regions and a
central horizon analogy; this graph is not a discretization of a derived
Lorentzian spacetime solution.

## Topology choice matters

There are two distinct graph operations:

1. **Identify matching horizon leaves.** The lower leaves are quotiented onto
   their matching upper leaves. This is still a tree, so `beta1 = 0`.
2. **Add one paired horizon edge per leaf pair.** Keep both leaf sets distinct
   and join each corresponding pair with an explicit cross-edge. The result
   has one connected component and `beta1 = 2^n_H - 1`.

For the paired-link construction, each rooted tree has
`2^(n_H+1)-1` vertices and `2^(n_H+1)-2` edges. Two disjoint copies joined
by `2^n_H` matching edges have:

- `V = 2^(n_H+2) - 2`
- `E = 2^(n_H+2) - 4 + 2^n_H`
- `beta0 = 1`
- `beta1 = E - V + beta0 = 2^n_H - 1`

The value displayed in the app is always calculated from the frame's actual
edge and vertex sets. Tarjan's algorithm separately reports bridge edges.

## Build and tests

```bash
swift test --filter DoubleTreeHorizonBridgeTests
swift test
```

## Generate exports

The graph fixture API is exposed through
`DoubleTreeHorizonBridge.make(depth:topology:)`. The exporter writes one
ChimeraX marker file (`.cmm`), one BILD edge file, and one JSON metadata file
per frame. Open a matching pair in ChimeraX:

```
open horizon-bridge-02.cmm
open horizon-bridge-02-edges.bild
```

The `.cmm` marker model is for node coordinates and colors. The companion
`.bild` contains graph edges, since marker files are not the graph-edge
transport format. JSON is the authoritative machine-readable node/edge list
and count record.

## Visual interpretation

Upper branches are cyan, lower branches purple, and the horizon nodes/links
gold. The central band is a visual separator/highlight only; it does not
insert extra vertices or edges. Three frames show the upper tree, both tree
halves before horizon linking, and the final paired-horizon-link graph.

The SceneKit/SwiftUI viewer is an abstract topology viewer. Its coordinates
are layout coordinates, not physical distances, and the curvature or
cosmological interpretation requires an independent metric construction.
