#!/usr/bin/env julia
# ==============================================================================
# ExportChimeraX.jl
# Multi-Scale UCSF ChimeraX Exporter for Mesoscale Biofilm Models:
#   1. Tarjan Bridge-Finding Cycle Classifier (separates true cycle edges from
#      2-core bridge/isthmus edges, tree branches, and isolated monomers).
#   2. .cmm (Marker Set XML) Exporter with 3-state vertex coloring (Teal cycle,
#      Amber tree/bridge, Red isolated monomer) and 2-state edge coloring.
#   3. .bild (3D Geometric Arrow) Exporter for cell kinesis & director fields.
#   4. .mrc (MRC-2014 Binary Volume) Exporter with strict 1024-byte header
#      verification for 3D H2O2, O2, and pH reaction-diffusion fields.
#
# Epistemic Boundary: All outputs are [MODEL ILLUSTRATION - RUNG_4_MODEL].
# Governing Principle: A passing software or schema check establishes a property of
# the software implementation and source-audit trail; it does not, by itself,
# establish the truth of a scientific claim, validate a biological model, or
# authorize institutional release.
# When comparing atomic structures in ChimeraX or PyMOL, note that PDB:4K0R
# (Xing et al. 2013) is Mus musculus (mouse) CRY2 bound to FBXL3 (not CRY1,
# not human), and PDB coordinates are in Angstroms (1 A = 1e-4 um).
# Dependencies: Julia Base and Test stdlib only. Zero em/en-dashes.
# ==============================================================================

module ExportChimeraX

export EdgeTopologyClass, VertexTopologyClass, NetworkTopologyClassification
export EDGE_CYCLE, EDGE_BRIDGE_OR_TREE, EDGE_SELF_LOOP
export VERT_CYCLE, VERT_TREE_OR_BRIDGE, VERT_ISOLATED_MONOMER
export classify_network_topology, ensure_unit_suffix
export export_network_to_chimerax_cmm, export_kinesis_vectors_to_bild, export_volume_to_mrc2014
export export_streamlines_to_bild, export_velocity_arrows_to_bild
export verify_scene_coordinate_alignment, export_chimerax_hydro_cxc_script
export export_bild_to_pymol_cgo_py, export_pymol_hydro_scene_script
export MRC2014Volume, read_and_verify_mrc2014

@enum EdgeTopologyClass begin
    EDGE_CYCLE          = 1 # Lies on >= 1 simple cycle (bridgeless / 2-edge-connected)
    EDGE_BRIDGE_OR_TREE = 2 # Cut-edge (bridge between loops or dangling tree branch)
    EDGE_SELF_LOOP      = 3 # u == v intra-chain primary loop (elastically inactive)
end

@enum VertexTopologyClass begin
    VERT_CYCLE            = 1 # Incident to >= 1 EDGE_CYCLE (Teal)
    VERT_TREE_OR_BRIDGE   = 2 # Inter-chain degree >= 1, but on 0 cycles (Amber)
    VERT_ISOLATED_MONOMER = 3 # Inter-chain degree == 0 (Red)
end

struct NetworkTopologyClassification
    n_vertices::Int
    edge_classes::Vector{EdgeTopologyClass}
    vertex_classes::Vector{VertexTopologyClass}
    n_cycle_edges::Int
    n_bridge_edges::Int
    n_self_loops::Int
end

"""
    ensure_unit_suffix(filepath, scene_unit, ext) -> String

Ensures `filepath` carries an explicit `_scene_<unit><ext>` suffix so ChimeraX
users never confuse mesoscale micrometer (`um`) models with atomic Angstrom (`A`) PDBs.
"""
function ensure_unit_suffix(
    filepath::AbstractString,
    scene_unit::AbstractString,
    ext::AbstractString,
)::String
    s_path = String(filepath)
    s_unit = replace(strip(String(scene_unit)), r"[^A-Za-z0-9]" => "")
    s_ext  = startswith(ext, ".") ? String(ext) : "." * String(ext)
    expected_tail = "_scene_" * s_unit * s_ext
    endswith(s_path, expected_tail) && return s_path
    base = endswith(lowercase(s_path), lowercase(s_ext)) ? s_path[1:end-length(s_ext)] : s_path
    return base * expected_tail
end

# ------------------------------------------------------------------------------
# 1. Iterative Tarjan Bridge-Finding Algorithm (O(|V| + |E|), Stack-Safe)
# ------------------------------------------------------------------------------

"""
    classify_network_topology(n_vertices, edges) -> NetworkTopologyClassification

Classifies every edge into `EDGE_CYCLE` (on >= 1 simple cycle),
`EDGE_BRIDGE_OR_TREE` (cut-edge: removing it increases connected components `beta_0`),
or `EDGE_SELF_LOOP` (`u == v`), using an iterative Tarjan bridge-finding pass.
Unlike a vertex 2-core filter, this correctly identifies a single bridge strand
joining two cyclic clusters (e.g. a barbell graph) as `EDGE_BRIDGE_OR_TREE`.
"""
function classify_network_topology(
    n_vertices::Int,
    edges::AbstractVector{Tuple{Int, Int}},
)::NetworkTopologyClassification
    n_vertices >= 0 || throw(ArgumentError("n_vertices must be >= 0"))
    m = length(edges)
    edge_classes = fill(EDGE_CYCLE, m)
    adj = [Tuple{Int, Int}[] for _ in 1:n_vertices] # (neighbor_vertex, edge_index)
    inter_deg = zeros(Int, n_vertices)
    n_self_loops = 0

    for (eid, (u, v)) in enumerate(edges)
        (1 <= u <= n_vertices && 1 <= v <= n_vertices) ||
            throw(BoundsError("Edge $eid = ($u, $v) out of bounds 1:$n_vertices"))
        if u == v
            edge_classes[eid] = EDGE_SELF_LOOP
            n_self_loops += 1
        else
            push!(adj[u], (v, eid))
            push!(adj[v], (u, eid))
            inter_deg[u] += 1
            inter_deg[v] += 1
        end
    end

    tin = zeros(Int, n_vertices)
    low = zeros(Int, n_vertices)
    timer = 0
    is_bridge = falses(m)

    # Iterative DFS stack frame: (u, parent_eid, next_adj_idx)
    stack = Tuple{Int, Int, Int}[]

    for start_v in 1:n_vertices
        tin[start_v] != 0 && continue
        timer += 1
        tin[start_v] = timer
        low[start_v] = timer
        push!(stack, (start_v, 0, 1))

        while !isempty(stack)
            u, p_eid, idx = stack[end]
            if idx <= length(adj[u])
                stack[end] = (u, p_eid, idx + 1)
                v, eid = adj[u][idx]
                eid == p_eid && continue
                if tin[v] != 0
                    # Back-edge to an already visited ancestor
                    low[u] = min(low[u], tin[v])
                else
                    timer += 1
                    tin[v] = timer
                    low[v] = timer
                    push!(stack, (v, eid, 1))
                end
            else
                pop!(stack)
                if !isempty(stack)
                    parent_u, _, _ = stack[end]
                    low[parent_u] = min(low[parent_u], low[u])
                    if low[u] > tin[parent_u]
                        is_bridge[p_eid] = true
                    end
                end
            end
        end
    end

    has_cycle_edge = falses(n_vertices)
    n_cycle_edges  = 0
    n_bridge_edges = 0

    for (eid, (u, v)) in enumerate(edges)
        edge_classes[eid] === EDGE_SELF_LOOP && continue
        if is_bridge[eid]
            edge_classes[eid] = EDGE_BRIDGE_OR_TREE
            n_bridge_edges += 1
        else
            edge_classes[eid] = EDGE_CYCLE
            has_cycle_edge[u] = true
            has_cycle_edge[v] = true
            n_cycle_edges += 1
        end
    end

    vertex_classes = Vector{VertexTopologyClass}(undef, n_vertices)
    for i in 1:n_vertices
        if has_cycle_edge[i]
            vertex_classes[i] = VERT_CYCLE
        elseif inter_deg[i] > 0
            vertex_classes[i] = VERT_TREE_OR_BRIDGE
        else
            vertex_classes[i] = VERT_ISOLATED_MONOMER
        end
    end

    return NetworkTopologyClassification(
        n_vertices,
        edge_classes,
        vertex_classes,
        n_cycle_edges,
        n_bridge_edges,
        n_self_loops,
    )
end

# ------------------------------------------------------------------------------
# 2. UCSF ChimeraX .cmm (Marker Set XML) Network Exporter
# ------------------------------------------------------------------------------

"""
    export_network_to_chimerax_cmm(filepath, coords, edges; scene_unit="um", set_name="biofilm_model_network") -> String

Writes a 3D polymer graph to a ChimeraX `.cmm` file using Tarjan bridge classification:
- Cycle vertices (`VERT_CYCLE`): Teal (`r=0.08, g=0.72, b=0.65, radius=0.45`)
- Tree / Bridge vertices (`VERT_TREE_OR_BRIDGE`): Amber (`r=0.96, g=0.62, b=0.04, radius=0.30`)
- Isolated monomers (`VERT_ISOLATED_MONOMER`, degree 0): Red (`r=0.86, g=0.15, b=0.15, radius=0.25`)
- Cycle edges (`EDGE_CYCLE`): Thick Teal cylinders (`radius=0.20`)
- Bridge / Tree edges (`EDGE_BRIDGE_OR_TREE`): Thin Gray cylinders (`radius=0.08`)
"""
function export_network_to_chimerax_cmm(
    filepath::AbstractString,
    coords::AbstractMatrix{<:Real},
    edges::AbstractVector{Tuple{Int, Int}};
    scene_unit::AbstractString = "um",
    set_name::AbstractString = "biofilm_model_network",
)::String
    n_verts = size(coords, 1)
    size(coords, 2) == 3 || throw(ArgumentError("coords must be an N x 3 matrix"))
    topo = classify_network_topology(n_verts, edges)
    out_path = ensure_unit_suffix(filepath, scene_unit, ".cmm")

    open(out_path, "w") do io
        println(
            io,
            "<!-- [MODEL ILLUSTRATION - RUNG_4_MODEL, NOT EMPIRICAL EVIDENCE] ",
            "scene_unit=", scene_unit,
            " (Note: ChimeraX treats 1 scene unit as 1 Angstrom when opened alongside atomic PDBs) -->",
        )
        println(
            io,
            "<marker_set name=\"", set_name, "_scene_", scene_unit, "\">",
        )
        for i in 1:n_verts
            x, y, z = Float64(coords[i, 1]), Float64(coords[i, 2]), Float64(coords[i, 3])
            vclass = topo.vertex_classes[i]
            r, g, b, rad, note = if vclass === VERT_CYCLE
                (0.08, 0.72, 0.65, 0.45, "cycle_vertex")
            elseif vclass === VERT_TREE_OR_BRIDGE
                (0.96, 0.62, 0.04, 0.30, "tree_or_bridge_vertex")
            else
                (0.86, 0.15, 0.15, 0.25, "isolated_monomer")
            end
            println(
                io,
                "  <marker id=\"$i\" x=\"$x\" y=\"$y\" z=\"$z\" ",
                "r=\"$r\" g=\"$g\" b=\"$b\" radius=\"$rad\" note=\"$note\"/>",
            )
        end

        for (eid, (u, v)) in enumerate(edges)
            eclass = topo.edge_classes[eid]
            eclass === EDGE_SELF_LOOP && continue
            r, g, b, rad = if eclass === EDGE_CYCLE
                (0.08, 0.72, 0.65, 0.20)
            else
                (0.58, 0.64, 0.72, 0.08)
            end
            println(
                io,
                "  <link id1=\"$u\" id2=\"$v\" ",
                "r=\"$r\" g=\"$g\" b=\"$b\" radius=\"$rad\"/>",
            )
        end
        println(io, "</marker_set>")
    end
    return out_path
end

# ------------------------------------------------------------------------------
# 3. UCSF ChimeraX .bild (3D Vector Field) Exporter
# ------------------------------------------------------------------------------

"""
    export_kinesis_vectors_to_bild(filepath, origins, vectors; scene_unit="um", scale=1.0) -> String

Writes a 3D cell kinesis velocity field or surface director field to a ChimeraX
`.bild` file with an explicit scene-unit header comment.
"""
function export_kinesis_vectors_to_bild(
    filepath::AbstractString,
    origins::AbstractMatrix{<:Real},
    vectors::AbstractMatrix{<:Real};
    scene_unit::AbstractString = "um",
    scale::Real = 1.0,
)::String
    n_pts = size(origins, 1)
    (size(origins, 2) == 3 && size(vectors) == (n_pts, 3)) ||
        throw(ArgumentError("origins and vectors must be N x 3 matrices"))

    out_path = ensure_unit_suffix(filepath, scene_unit, ".bild")
    s = Float64(scale)
    open(out_path, "w") do io
        println(
            io,
            ".comment [MODEL ILLUSTRATION - RUNG_4_MODEL, NOT EMPIRICAL EVIDENCE] scene_unit=",
            scene_unit,
        )
        println(io, ".color 0.22 0.53 0.96")
        for i in 1:n_pts
            x1, y1, z1 = Float64(origins[i, 1]), Float64(origins[i, 2]), Float64(origins[i, 3])
            dx, dy, dz = s * Float64(vectors[i, 1]), s * Float64(vectors[i, 2]), s * Float64(vectors[i, 3])
            (dx * dx + dy * dy + dz * dz) < 1.0e-12 && continue
            x2, y2, z2 = x1 + dx, y1 + dy, z1 + dz
            println(io, ".arrow $x1 $y1 $z1 $x2 $y2 $z2 0.08 0.20 0.75")
        end
    end
    return out_path
end

# ------------------------------------------------------------------------------
# 4. Pure-Base MRC-2014 Binary Volume Exporter (Strict 1024-Byte Header)
# ------------------------------------------------------------------------------

function _pad_ascii_80(text::AbstractString)::Vector{UInt8}
    ascii_str = replace(String(text), r"[^\x20-\x7e]" => "?")
    clipped = length(ascii_str) > 80 ? ascii_str[1:80] : rpad(ascii_str, 80, ' ')
    return Vector{UInt8}(codeunits(clipped))
end

"""
    export_volume_to_mrc2014(filepath, vol_3d; voxel_size=(1.0, 1.0, 1.0), origin=(0.0, 0.0, 0.0), scene_unit="um", field_name="H2O2_mM") -> String

Writes a 3D `Float32` scalar field (e.g. H2O2, O2, or pH) to a standard CCP4 /
MRC-2014 binary volume file (`.mrc`) for UCSF ChimeraX:
  - Enforces an exact 1024-byte header (`MODE = 2`, `NVERSION = 20140`, `MAP = "MAP "`,
    little-endian `MACHST = [0x44, 0x44, 0x00, 0x00]`).
  - Records `voxel_size` via `CELLA = (NX * dx, NY * dy, NZ * dz)` and stamps
    `[MODEL ILLUSTRATION - RUNG_4_MODEL]` + `scene_unit` into the 80-char MRC labels.
"""
function export_volume_to_mrc2014(
    filepath::AbstractString,
    vol_3d::AbstractArray{<:Real, 3};
    voxel_size::NTuple{3, Real} = (1.0, 1.0, 1.0),
    origin::NTuple{3, Real} = (0.0, 0.0, 0.0),
    scene_unit::AbstractString = "um",
    field_name::AbstractString = "H2O2_mM",
    nsymbt::Integer = 0,
    extended_header::AbstractString = "",
)::String
    nx, ny, nz = size(vol_3d)
    (nx >= 1 && ny >= 1 && nz >= 1) || throw(ArgumentError("Volume dimensions must be >= 1"))
    dx, dy, dz = Float32(voxel_size[1]), Float32(voxel_size[2]), Float32(voxel_size[3])
    (dx > 0.0f0 && dy > 0.0f0 && dz > 0.0f0) || throw(ArgumentError("voxel_size must be positive"))
    nsym = Int(nsymbt)
    (nsym >= 0 && (nsym % 80 == 0)) || throw(ArgumentError("nsymbt must be a non-negative multiple of 80, got $nsym"))

    data_f32 = Array{Float32, 3}(undef, nx, ny, nz)
    dmin = Inf32
    dmax = -Inf32
    dsum = 0.0

    @inbounds for i in eachindex(vol_3d)
        val = Float32(vol_3d[i])
        isfinite(val) || throw(ArgumentError("Volume contains non-finite value at index $i"))
        data_f32[i] = val
        val < dmin && (dmin = val)
        val > dmax && (dmax = val)
        dsum += Float64(val)
    end

    n_tot = length(data_f32)
    dmean = Float32(dsum / n_tot)
    var_sum = 0.0
    @inbounds for i in eachindex(data_f32)
        diff = Float64(data_f32[i]) - Float64(dmean)
        var_sum += diff * diff
    end
    drms = Float32(sqrt(var_sum / n_tot))

    out_path = ensure_unit_suffix(filepath, scene_unit, ".mrc")

    open(out_path, "w") do io
        # Words 1..3: NX, NY, NZ (Int32)
        write(io, htol(Int32(nx)), htol(Int32(ny)), htol(Int32(nz)))
        # Word 4: MODE = 2 (Float32)
        write(io, htol(Int32(2)))
        # Words 5..7: NXSTART, NYSTART, NZSTART
        write(io, htol(Int32(0)), htol(Int32(0)), htol(Int32(0)))
        # Words 8..10: MX, MY, MZ (grid intervals)
        write(io, htol(Int32(nx)), htol(Int32(ny)), htol(Int32(nz)))
        # Words 11..13: CELLA (bounding box dimensions in scene units)
        write(io, htol(Float32(nx) * dx), htol(Float32(ny) * dy), htol(Float32(nz) * dz))
        # Words 14..16: CELLB (angles alpha, beta, gamma = 90 deg)
        write(io, htol(90.0f0), htol(90.0f0), htol(90.0f0))
        # Words 17..19: MAPC, MAPR, MAPS (1, 2, 3)
        write(io, htol(Int32(1)), htol(Int32(2)), htol(Int32(3)))
        # Words 20..22: DMIN, DMAX, DMEAN
        write(io, htol(dmin), htol(dmax), htol(dmean))
        # Word 23: ISPG = 1 (single 3D volume space group)
        write(io, htol(Int32(1)))
        # Word 24: NSYMBT (bytes of extended header, multiple of 80)
        write(io, htol(Int32(nsym)))
        # Words 25..26: EXTRA[1..2] = 0
        write(io, htol(Int32(0)), htol(Int32(0)))
        # Word 27: EXTTYPE = "MRCO"
        write(io, UInt8['M', 'R', 'C', 'O'])
        # Word 28: NVERSION = 20140 (MRC-2014 standard)
        write(io, htol(Int32(20140)))
        # Words 29..49: Remaining 21 words of EXTRA = 0
        for _ in 29:49
            write(io, htol(Int32(0)))
        end
        # Words 50..52: ORIGIN (x0, y0, z0 in scene units)
        write(io, htol(Float32(origin[1])), htol(Float32(origin[2])), htol(Float32(origin[3])))
        # Word 53: MAP = "MAP "
        write(io, UInt8['M', 'A', 'P', ' '])
        # Word 54: MACHST = [0x44, 0x44, 0x00, 0x00] (little-endian)
        write(io, UInt8[0x44, 0x44, 0x00, 0x00])
        # Word 55: RMS (standard deviation)
        write(io, htol(drms))
        # Word 56: NLABL = 2 or 3 labels used
        has_ext_label = !isempty(extended_header)
        write(io, htol(Int32(has_ext_label ? 3 : 2)))
        # Words 57..256: 10 x 80-byte ASCII labels (800 bytes)
        max_f_len = max(1, 80 - 42 - 6 - length(String(scene_unit)))
        f_tag = length(String(field_name)) > max_f_len ? first(String(field_name), max_f_len) : String(field_name)
        lbl1 = "[MODEL ILLUSTRATION - RUNG_4_MODEL] field=$(f_tag) unit=$(scene_unit)"
        lbl2 = "voxel_size=($(dx),$(dy),$(dz)) $(scene_unit); not empirical evidence"
        write(io, _pad_ascii_80(lbl1))
        write(io, _pad_ascii_80(lbl2))
        if has_ext_label
            write(io, _pad_ascii_80(String(extended_header)))
            for _ in 4:10
                write(io, _pad_ascii_80(""))
            end
        else
            for _ in 3:10
                write(io, _pad_ascii_80(""))
            end
        end

        # Strict header-size invariant gate (1024 bytes before extended header / voxel stream)
        @assert position(io) == 1024 "MRC-2014 header misalignment: position(io) = $(position(io)) != 1024"

        if nsym > 0
            n_records = div(nsym, 80)
            # Standard CCP4/MRC-2014 80-byte P1 crystallographic identity symmetry operator record
            # for ISPG=1 so UCSF ChimeraX's chimerax.crystal.parse_symop parses NSYMBT=80 with 0 warnings
            symop_str = (occursin(",", extended_header) && length(split(extended_header, ",")) == 3) ?
                String(extended_header) :
                "X, Y, Z"
            for _ in 1:n_records
                write(io, _pad_ascii_80(symop_str))
            end
            @assert position(io) == 1024 + nsym "MRC-2014 extended header misalignment: position(io) = $(position(io)) != $(1024 + nsym)"
        end

        for val in data_f32
            write(io, htol(val))
        end
    end

    expected_bytes = 1024 + nsym + 4 * n_tot
    actual_bytes = filesize(out_path)
    @assert actual_bytes == expected_bytes "MRC file size mismatch: $actual_bytes != $expected_bytes"
    return out_path
end

struct MRC2014Volume
    nx::Int32
    ny::Int32
    nz::Int32
    mode::Int32
    nxstart::Int32
    nystart::Int32
    nzstart::Int32
    mx::Int32
    my::Int32
    mz::Int32
    cella::Tuple{Float32, Float32, Float32}
    cellb::Tuple{Float32, Float32, Float32}
    mapc::Int32
    mapr::Int32
    maps::Int32
    dmin::Float32
    dmax::Float32
    dmean::Float32
    ispg::Int32
    nsymbt::Int32
    exttype::String
    nversion::Int32
    origin::Tuple{Float32, Float32, Float32}
    map_stamp::String
    machst::NTuple{4, UInt8}
    rms::Float32
    nlabl::Int32
    labels::Vector{String}
    voxel_size::Tuple{Float32, Float32, Float32}
    data::Array{Float32, 3}
end

"""
    read_and_verify_mrc2014(
        filepath::AbstractString;
        expected_nx::Union{Nothing, Integer} = nothing,
        expected_ny::Union{Nothing, Integer} = nothing,
        expected_nz::Union{Nothing, Integer} = nothing,
        expected_voxel_size::Union{Nothing, NTuple{3, Real}} = nothing,
        expected_origin::Union{Nothing, NTuple{3, Real}} = nothing,
        expected_data::Union{Nothing, AbstractArray{<:Real, 3}} = nothing,
        expected_nsymbt::Union{Nothing, Integer} = 0,
    ) -> MRC2014Volume

Independently reads an MRC-2014 binary volume file from disk, parses all 56 header
words (224 bytes), 10 x 80-byte labels (800 bytes), optional extended header
(`NSYMBT` bytes), and the 3D Float32 payload, and strictly validates:
  - File size == 1024 + NSYMBT + 4 * nx * ny * nz (with NSYMBT == expected_nsymbt)
  - MODE == 2 (32-bit signed IEEE float)
  - Axis order (MAPC, MAPR, MAPS) == (1, 2, 3) (fast X, medium Y, slow Z)
  - Sampling grid (MX, MY, MZ) == (NX, NY, NZ)
  - Unit cell angles CELLB == (90.0f0, 90.0f0, 90.0f0)
  - Space group ISPG == 1 and extended header size NSYMBT >= 0 (divisible by 80)
  - EXTTYPE == "MRCO" and NVERSION == 20140
  - MAP stamp == "MAP " at bytes 209..212 (1-based) and MACHST == (0x44, 0x44, 0x00, 0x00)
  - Header statistics (DMIN, DMAX, DMEAN, RMS) match the payload voxels
  - Optional round-trip equality against expected dimensions, voxel spacing, origin, and 3D array
"""
function read_and_verify_mrc2014(
    filepath::AbstractString;
    expected_nx::Union{Nothing, Integer} = nothing,
    expected_ny::Union{Nothing, Integer} = nothing,
    expected_nz::Union{Nothing, Integer} = nothing,
    expected_voxel_size::Union{Nothing, NTuple{3, Real}} = nothing,
    expected_origin::Union{Nothing, NTuple{3, Real}} = nothing,
    expected_data::Union{Nothing, AbstractArray{<:Real, 3}} = nothing,
    expected_nsymbt::Union{Nothing, Integer} = 0,
)
    @assert isfile(filepath) "MRC-2014 file does not exist: $filepath"
    raw = read(filepath)
    @assert length(raw) >= 1024 "MRC-2014 file shorter than 1024-byte header: $(length(raw)) bytes"

    word_i32(w::Int) = ltoh(reinterpret(Int32, raw[(4 * (w - 1) + 1):(4 * w)])[1])
    word_f32(w::Int) = ltoh(reinterpret(Float32, raw[(4 * (w - 1) + 1):(4 * w)])[1])
    word_str4(w::Int) = String(copy(raw[(4 * (w - 1) + 1):(4 * w)]))

    nx = word_i32(1)
    ny = word_i32(2)
    nz = word_i32(3)
    mode = word_i32(4)
    nxstart = word_i32(5)
    nystart = word_i32(6)
    nzstart = word_i32(7)
    mx = word_i32(8)
    my = word_i32(9)
    mz = word_i32(10)
    cella = (word_f32(11), word_f32(12), word_f32(13))
    cellb = (word_f32(14), word_f32(15), word_f32(16))
    mapc = word_i32(17)
    mapr = word_i32(18)
    maps = word_i32(19)
    dmin = word_f32(20)
    dmax = word_f32(21)
    dmean = word_f32(22)
    ispg = word_i32(23)
    nsymbt = word_i32(24)
    exttype = word_str4(27)
    nversion = word_i32(28)
    origin = (word_f32(50), word_f32(51), word_f32(52))
    map_stamp = word_str4(53)
    machst = (raw[213], raw[214], raw[215], raw[216])
    rms = word_f32(55)
    nlabl = word_i32(56)

    @assert nx > 0 && ny > 0 && nz > 0 "Invalid MRC-2014 grid dimensions: ($nx, $ny, $nz)"
    @assert mode == 2 "MRC-2014 MODE must be 2 (Float32), got $mode"
    @assert (mx, my, mz) == (nx, ny, nz) "Sampling grid ($mx, $my, $mz) != ($nx, $ny, $nz)"
    @assert cellb == (90.0f0, 90.0f0, 90.0f0) "MRC-2014 CELLB angles must be (90,90,90), got $cellb"
    @assert (mapc, mapr, maps) == (1, 2, 3) "MRC-2014 axis order (MAPC,MAPR,MAPS) must be (1,2,3), got ($mapc,$mapr,$maps)"
    @assert ispg == 1 "MRC-2014 space group ISPG must be 1, got $ispg"
    @assert nsymbt >= 0 && (nsymbt % 80 == 0) "MRC-2014 NSYMBT must be a non-negative multiple of 80, got $nsymbt"
    if expected_nsymbt !== nothing
        @assert nsymbt == Int32(expected_nsymbt) "MRC-2014 NSYMBT must be $expected_nsymbt, got $nsymbt"
    end
    @assert exttype == "MRCO" "MRC-2014 EXTTYPE must be 'MRCO', got '$exttype'"
    @assert nversion == 20140 "MRC-2014 NVERSION must be 20140, got $nversion"
    @assert map_stamp == "MAP " "MRC-2014 MAP stamp must be 'MAP ', got '$map_stamp'"
    @assert machst == (0x44, 0x44, 0x00, 0x00) "MRC-2014 MACHST must be (0x44, 0x44, 0x00, 0x00), got $machst"
    @assert 0 <= nlabl <= 10 "MRC-2014 NLABL out of range [0, 10]: $nlabl"

    # Verify reserved words 25..26 and 29..49 are zero
    for w in (25, 26)
        @assert word_i32(w) == 0 "MRC-2014 reserved word $w is non-zero: $(word_i32(w))"
    end
    for w in 29:49
        @assert word_i32(w) == 0 "MRC-2014 reserved word $w is non-zero: $(word_i32(w))"
    end

    labels = String[]
    for idx in 1:10
        offset = 224 + 80 * (idx - 1)
        lbl_str = rstrip(String(copy(raw[(offset + 1):(offset + 80)])))
        push!(labels, lbl_str)
    end

    n_voxels = Int(nx) * Int(ny) * Int(nz)
    expected_bytes = 1024 + Int(nsymbt) + 4 * n_voxels
    @assert length(raw) == expected_bytes "MRC-2014 byte length $(length(raw)) != expected $expected_bytes"

    voxels_f32 = Vector{Float32}(undef, n_voxels)
    voxel_start = 1025 + Int(nsymbt)
    raw_voxels = reinterpret(Float32, @view(raw[voxel_start:end]))
    for i in 1:n_voxels
        voxels_f32[i] = ltoh(raw_voxels[i])
    end
    data = reshape(voxels_f32, (Int(nx), Int(ny), Int(nz)))

    # Recompute stats from payload and verify against header DMIN, DMAX, DMEAN, RMS
    calc_min = minimum(data)
    calc_max = maximum(data)
    calc_mean = Float32(sum(Float64, data) / n_voxels)
    var_acc = 0.0
    for val in data
        diff = Float64(val) - Float64(calc_mean)
        var_acc += diff * diff
    end
    calc_rms = Float32(sqrt(var_acc / n_voxels))

    @assert isapprox(dmin, calc_min; rtol = 1e-5, atol = 1e-6) "DMIN mismatch: header=$dmin vs payload=$calc_min"
    @assert isapprox(dmax, calc_max; rtol = 1e-5, atol = 1e-6) "DMAX mismatch: header=$dmax vs payload=$calc_max"
    @assert isapprox(dmean, calc_mean; rtol = 1e-5, atol = 1e-6) "DMEAN mismatch: header=$dmean vs payload=$calc_mean"
    @assert isapprox(rms, calc_rms; rtol = 1e-5, atol = 1e-6) "RMS mismatch: header=$rms vs payload=$calc_rms"

    voxel_size = (
        cella[1] / Float32(mx),
        cella[2] / Float32(my),
        cella[3] / Float32(mz),
    )

    if expected_nx !== nothing
        @assert nx == Int32(expected_nx) "Expected NX=$expected_nx, got $nx"
    end
    if expected_ny !== nothing
        @assert ny == Int32(expected_ny) "Expected NY=$expected_ny, got $ny"
    end
    if expected_nz !== nothing
        @assert nz == Int32(expected_nz) "Expected NZ=$expected_nz, got $nz"
    end
    if expected_voxel_size !== nothing
        @assert isapprox(voxel_size[1], Float32(expected_voxel_size[1]); rtol = 1e-5, atol = 1e-6)
        @assert isapprox(voxel_size[2], Float32(expected_voxel_size[2]); rtol = 1e-5, atol = 1e-6)
        @assert isapprox(voxel_size[3], Float32(expected_voxel_size[3]); rtol = 1e-5, atol = 1e-6)
    end
    if expected_origin !== nothing
        @assert isapprox(origin[1], Float32(expected_origin[1]); rtol = 1e-5, atol = 1e-6)
        @assert isapprox(origin[2], Float32(expected_origin[2]); rtol = 1e-5, atol = 1e-6)
        @assert isapprox(origin[3], Float32(expected_origin[3]); rtol = 1e-5, atol = 1e-6)
    end
    if expected_data !== nothing
        exp_f32 = Float32.(expected_data)
        @assert size(data) == size(exp_f32) "Round-trip array shape $(size(data)) != $(size(exp_f32))"
        @assert data == exp_f32 "Round-trip Float32 voxel array mismatch"
    end

    return MRC2014Volume(
        nx, ny, nz, mode,
        nxstart, nystart, nzstart,
        mx, my, mz,
        cella, cellb,
        mapc, mapr, maps,
        dmin, dmax, dmean,
        ispg, nsymbt,
        exttype, nversion,
        origin, map_stamp, machst, rms, nlabl,
        labels, voxel_size, data,
    )
end

# ------------------------------------------------------------------------------
# 5. Hydrodynamic 3D Velocity Arrows, Streamline/Pathline BILD Polylines,
#    Scene Coordinate-Alignment Gate, and ChimeraX .cxc Script Generator
# ------------------------------------------------------------------------------

function _extract_velocity_components(u_vec_3d::AbstractArray{<:Real, 4})
    size(u_vec_3d, 4) == 3 || throw(ArgumentError("4D velocity array must have size(u_vec_3d, 4) == 3"))
    return (@view(u_vec_3d[:, :, :, 1]), @view(u_vec_3d[:, :, :, 2]), @view(u_vec_3d[:, :, :, 3]))
end

function _extract_velocity_components(
    u_vec_3d::Tuple{AbstractArray{<:Real, 3}, AbstractArray{<:Real, 3}, AbstractArray{<:Real, 3}},
)
    size(u_vec_3d[1]) == size(u_vec_3d[2]) == size(u_vec_3d[3]) ||
        throw(ArgumentError("3D velocity component arrays must have identical dimensions"))
    return u_vec_3d
end

"""
    export_velocity_arrows_to_bild(
        filepath::AbstractString,
        grid_origin::NTuple{3, Real},
        voxel_size::NTuple{3, Real},
        u_vec_3d;
        stride::Int = 3,
        scale::Real = 1.0,
        scene_unit::AbstractString = "0p5m",
        color::NTuple{3, Real} = (0.10, 0.65, 0.90),
        min_speed::Real = 1.0e-12,
    ) -> String

Samples a 3D Darcy or pore-space velocity field `u_vec_3d` (either a 4D array of
shape `(nx, ny, nz, 3)` or a 3-tuple of 3D arrays `(u_x, u_y, u_z)`) at every
`stride`-th grid cell `(ix, iy, iz)` and writes ChimeraX `.bild` 3D arrows from:
    x = grid_origin + ((ix - 1) * dx, (iy - 1) * dy, (iz - 1) * dz)
to:
    x_end = x + scale * u(ix, iy, iz)
where `scale` (`s`) is a visualization scale factor kept consistent across snapshots.
"""
function export_velocity_arrows_to_bild(
    filepath::AbstractString,
    grid_origin::NTuple{3, Real},
    voxel_size::NTuple{3, Real},
    u_vec_3d;
    stride::Int = 3,
    scale::Real = 1.0,
    scene_unit::AbstractString = "0p5m",
    color::NTuple{3, Real} = (0.10, 0.65, 0.90),
    min_speed::Real = 1.0e-12,
)::String
    stride >= 1 || throw(ArgumentError("stride must be >= 1, got $stride"))
    s = Float64(scale)
    (isfinite(s) && s > 0.0) || throw(ArgumentError("scale must be finite and positive, got $scale"))
    ox, oy, oz = Float64(grid_origin[1]), Float64(grid_origin[2]), Float64(grid_origin[3])
    (isfinite(ox) && isfinite(oy) && isfinite(oz)) || throw(ArgumentError("grid_origin must be finite"))
    dx, dy, dz = Float64(voxel_size[1]), Float64(voxel_size[2]), Float64(voxel_size[3])
    (isfinite(dx) && isfinite(dy) && isfinite(dz) && dx > 0.0 && dy > 0.0 && dz > 0.0) ||
        throw(ArgumentError("voxel_size components must be finite and positive"))
    cr, cg, cb = Float64(color[1]), Float64(color[2]), Float64(color[3])
    (0.0 <= cr <= 1.0 && 0.0 <= cg <= 1.0 && 0.0 <= cb <= 1.0) ||
        throw(ArgumentError("RGB color components must lie in [0, 1]"))

    ux, uy, uz = _extract_velocity_components(u_vec_3d)
    nx, ny, nz = size(ux)
    (nx >= 1 && ny >= 1 && nz >= 1) || throw(ArgumentError("Velocity grid dimensions must be >= 1"))

    out_path = ensure_unit_suffix(filepath, scene_unit, ".bild")
    min_sq = Float64(min_speed)^2

    open(out_path, "w") do io
        println(
            io,
            ".comment [MODEL ILLUSTRATION - RUNG_4_MODEL, NOT EMPIRICAL EVIDENCE] scene_unit=",
            scene_unit,
        )
        println(
            io,
            ".comment geometry=velocity_arrows origin=($ox,$oy,$oz) voxel_size=($dx,$dy,$dz) grid_shape=($nx,$ny,$nz) stride=$stride scale=$s",
        )
        println(io, ".color $cr $cg $cb")
        for iz in 1:stride:nz, iy in 1:stride:ny, ix in 1:stride:nx
            vx = Float64(ux[ix, iy, iz])
            vy = Float64(uy[ix, iy, iz])
            vz = Float64(uz[ix, iy, iz])
            (isfinite(vx) && isfinite(vy) && isfinite(vz)) ||
                throw(ArgumentError("Non-finite velocity vector at ($ix, $iy, $iz)"))
            (vx * vx + vy * vy + vz * vz) < min_sq && continue
            x1 = ox + (ix - 1) * dx
            y1 = oy + (iy - 1) * dy
            z1 = oz + (iz - 1) * dz
            dx_arr = s * vx
            dy_arr = s * vy
            dz_arr = s * vz
            # Guard against UCSF ChimeraX z_align Float32 endpoint coincidence (< 1e-4 scene units)
            (dx_arr * dx_arr + dy_arr * dy_arr + dz_arr * dz_arr) < 1.0e-8 && continue
            x2 = x1 + dx_arr
            y2 = y1 + dy_arr
            z2 = z1 + dz_arr
            println(io, ".arrow $x1 $y1 $z1 $x2 $y2 $z2 0.025 0.08 0.75")
        end
    end
    return out_path
end

function _polyline_to_points(poly::AbstractVector{<:NTuple{3, Real}})::Vector{NTuple{3, Float64}}
    pts = Vector{NTuple{3, Float64}}(undef, length(poly))
    for (i, p) in enumerate(poly)
        x, y, z = Float64(p[1]), Float64(p[2]), Float64(p[3])
        (isfinite(x) && isfinite(y) && isfinite(z)) ||
            throw(ArgumentError("Polyline contains non-finite point ($x, $y, $z)"))
        pts[i] = (x, y, z)
    end
    return pts
end

function _polyline_to_points(poly::AbstractMatrix{<:Real})::Vector{NTuple{3, Float64}}
    size(poly, 2) == 3 || throw(ArgumentError("Matrix polyline must have shape N x 3"))
    n = size(poly, 1)
    pts = Vector{NTuple{3, Float64}}(undef, n)
    for i in 1:n
        x, y, z = Float64(poly[i, 1]), Float64(poly[i, 2]), Float64(poly[i, 3])
        (isfinite(x) && isfinite(y) && isfinite(z)) ||
            throw(ArgumentError("Polyline contains non-finite point ($x, $y, $z)"))
        pts[i] = (x, y, z)
    end
    return pts
end

"""
    export_streamlines_to_bild(
        filepath::AbstractString,
        polylines::AbstractVector;
        scene_unit::AbstractString = "0p5m",
        color::NTuple{3, Real} = (0.15, 0.60, 0.40),
        line_kind::Symbol = :streamline,
        origin::Union{Nothing, NTuple{3, Real}} = nothing,
        voxel_size::Union{Nothing, NTuple{3, Real}} = nothing,
        grid_shape::Union{Nothing, NTuple{3, Integer}} = nothing,
    ) -> String

Writes pre-integrated 3D flow trajectories to a UCSF ChimeraX `.bild` file using
connected `.move x0 y0 z0` and `.draw x1 y1 z1 ...` line segments:
  - `line_kind = :streamline`: instantaneous tangent curves `dx/ds = u(x, t_k)` at fixed snapshot `t_k`
  - `line_kind = :pathline`: time-dependent parcel trajectories `dx/dt = u(x(t), t)` across an episodic pulse
Explicitly labels the representation (`:streamline` vs `:pathline`) in the BILD header comments,
and enforces a minimum segment length `dist >= 1.0e-4` scene units (`dist2 >= 1.0e-8`) so that
UCSF ChimeraX (`chimerax.bild` Float32 `z_align`) never encounters coincident segment endpoints.
"""
function export_streamlines_to_bild(
    filepath::AbstractString,
    polylines::AbstractVector;
    scene_unit::AbstractString = "0p5m",
    color::NTuple{3, Real} = (0.15, 0.60, 0.40),
    line_kind::Symbol = :streamline,
    origin::Union{Nothing, NTuple{3, Real}} = nothing,
    voxel_size::Union{Nothing, NTuple{3, Real}} = nothing,
    grid_shape::Union{Nothing, NTuple{3, Integer}} = nothing,
)::String
    line_kind in (:streamline, :pathline) ||
        throw(ArgumentError("line_kind must be :streamline or :pathline, got :$line_kind"))
    cr, cg, cb = Float64(color[1]), Float64(color[2]), Float64(color[3])
    (0.0 <= cr <= 1.0 && 0.0 <= cg <= 1.0 && 0.0 <= cb <= 1.0) ||
        throw(ArgumentError("RGB color components must lie in [0, 1]"))

    converted = Vector{Vector{NTuple{3, Float64}}}()
    for poly in polylines
        raw_pts = _polyline_to_points(poly)
        isempty(raw_pts) && continue
        pts = NTuple{3, Float64}[raw_pts[1]]
        for k in 2:length(raw_pts)
            x_prev, y_prev, z_prev = pts[end]
            xk, yk, zk = raw_pts[k]
            dist2 = (xk - x_prev)^2 + (yk - y_prev)^2 + (zk - z_prev)^2
            # Require segment displacement >= 1.0e-4 scene units (dist2 >= 1.0e-8)
            # to prevent Float32 z_align endpoint warnings in UCSF ChimeraX
            if dist2 >= 1.0e-8
                push!(pts, (xk, yk, zk))
            end
        end
        length(pts) >= 2 && push!(converted, pts)
    end

    out_path = ensure_unit_suffix(filepath, scene_unit, ".bild")
    kind_desc = line_kind === :streamline ?
        "streamline (instantaneous velocity tangent curve dx/ds = u(x, t_k) at fixed snapshot)" :
        "pathline (time-dependent fluid parcel trajectory dx/dt = u(x(t), t) across pulse)"

    open(out_path, "w") do io
        println(
            io,
            ".comment [MODEL ILLUSTRATION - RUNG_4_MODEL, NOT EMPIRICAL EVIDENCE] scene_unit=",
            scene_unit,
        )
        println(io, ".comment line_kind=$kind_desc n_polylines=$(length(converted))")
        if origin !== nothing && voxel_size !== nothing && grid_shape !== nothing
            ox, oy, oz = Float64(origin[1]), Float64(origin[2]), Float64(origin[3])
            dx, dy, dz = Float64(voxel_size[1]), Float64(voxel_size[2]), Float64(voxel_size[3])
            nx, ny, nz = Int(grid_shape[1]), Int(grid_shape[2]), Int(grid_shape[3])
            println(
                io,
                ".comment geometry=$(line_kind) origin=($ox,$oy,$oz) voxel_size=($dx,$dy,$dz) grid_shape=($nx,$ny,$nz)",
            )
        end
        println(io, ".color $cr $cg $cb")
        for pts in converted
            x0, y0, z0 = pts[1]
            println(io, ".move $x0 $y0 $z0")
            for k in 2:length(pts)
                xk, yk, zk = pts[k]
                println(io, ".draw $xk $yk $zk")
            end
        end
    end
    return out_path
end

"""
    verify_scene_coordinate_alignment(
        mrc_paths::AbstractVector{<:AbstractString},
        bild_paths::AbstractVector{<:AbstractString};
        expected_origin::NTuple{3, Real} = (0.0, 0.0, 0.0),
        expected_voxel_size::NTuple{3, Real} = (1.0, 1.0, 1.0),
        expected_scene_unit::AbstractString = "0p5m",
    ) -> NamedTuple

Release Check 1 (Coordinate Alignment & Scene-Unit Gate):
Parses all MRC-2014 binary volume headers in `mrc_paths` and all BILD geometric
files in `bild_paths` and asserts that every file in the scene shares the exact
same origin, voxel spacing, axis ordering `(1, 2, 3)`, `_scene_<unit>` suffix,
and spatial domain bounding box.
"""
function verify_scene_coordinate_alignment(
    mrc_paths::AbstractVector{<:AbstractString},
    bild_paths::AbstractVector{<:AbstractString};
    expected_origin::NTuple{3, Real} = (0.0, 0.0, 0.0),
    expected_voxel_size::NTuple{3, Real} = (1.0, 1.0, 1.0),
    expected_scene_unit::AbstractString = "0p5m",
)
    @assert !isempty(mrc_paths) "mrc_paths must contain at least one MRC-2014 volume"
    @assert !isempty(bild_paths) "bild_paths must contain at least one BILD geometry file"
    s_unit = replace(strip(String(expected_scene_unit)), r"[^A-Za-z0-9]" => "")
    ox, oy, oz = Float64(expected_origin[1]), Float64(expected_origin[2]), Float64(expected_origin[3])
    dx, dy, dz = Float64(expected_voxel_size[1]), Float64(expected_voxel_size[2]), Float64(expected_voxel_size[3])

    ref_nx = Int32(0)
    ref_ny = Int32(0)
    ref_nz = Int32(0)
    ref_cella = (0.0f0, 0.0f0, 0.0f0)

    for (idx, mrc_p) in enumerate(mrc_paths)
        @assert endswith(mrc_p, "_scene_$(s_unit).mrc") "MRC file $mrc_p lacks expected _scene_$(s_unit).mrc suffix"
        hdr = read_and_verify_mrc2014(
            mrc_p;
            expected_voxel_size = expected_voxel_size,
            expected_origin = expected_origin,
            expected_nsymbt = nothing,
        )
        @assert occursin("unit=$(expected_scene_unit)", hdr.labels[1]) "MRC label 1 in $mrc_p missing unit=$(expected_scene_unit)"
        if idx == 1
            ref_nx, ref_ny, ref_nz = hdr.nx, hdr.ny, hdr.nz
            ref_cella = hdr.cella
        else
            @assert (hdr.nx, hdr.ny, hdr.nz) == (ref_nx, ref_ny, ref_nz) "Grid shape mismatch in $mrc_p: $((hdr.nx, hdr.ny, hdr.nz)) != $((ref_nx, ref_ny, ref_nz))"
            @assert hdr.cella == ref_cella "CELLA bounding box mismatch in $mrc_p: $(hdr.cella) != $ref_cella"
        end
    end

    xmin, ymin, zmin = ox, oy, oz
    xmax = ox + Float64(ref_nx) * dx
    ymax = oy + Float64(ref_ny) * dy
    zmax = oz + Float64(ref_nz) * dz
    tol = 1.0e-4

    for bild_p in bild_paths
        @assert isfile(bild_p) "BILD file does not exist: $bild_p"
        @assert endswith(bild_p, "_scene_$(s_unit).bild") "BILD file $bild_p lacks expected _scene_$(s_unit).bild suffix"
        txt = read(bild_p, String)
        @assert occursin("[MODEL ILLUSTRATION - RUNG_4_MODEL", txt) "BILD file $bild_p missing RUNG_4_MODEL comment"
        @assert occursin("scene_unit=$(expected_scene_unit)", txt) "BILD file $bild_p missing scene_unit=$(expected_scene_unit)"

        # Check optional embedded origin / voxel_size / grid_shape metadata in BILD header
        m_orig = match(r"origin=\(([^,]+),([^,]+),([^)]+)\)", txt)
        if m_orig !== nothing
            box_x = parse(Float64, m_orig.captures[1])
            box_y = parse(Float64, m_orig.captures[2])
            box_z = parse(Float64, m_orig.captures[3])
            @assert isapprox(box_x, ox; atol = 1e-5) && isapprox(box_y, oy; atol = 1e-5) && isapprox(box_z, oz; atol = 1e-5) "BILD origin ($box_x,$box_y,$box_z) != expected ($ox,$oy,$oz) in $bild_p"
        end
        m_vox = match(r"voxel_size=\(([^,]+),([^,]+),([^)]+)\)", txt)
        if m_vox !== nothing
            v_x = parse(Float64, m_vox.captures[1])
            v_y = parse(Float64, m_vox.captures[2])
            v_z = parse(Float64, m_vox.captures[3])
            @assert isapprox(v_x, dx; atol = 1e-5) && isapprox(v_y, dy; atol = 1e-5) && isapprox(v_z, dz; atol = 1e-5) "BILD voxel_size ($v_x,$v_y,$v_z) != expected ($dx,$dy,$dz) in $bild_p"
        end
        m_shape = match(r"grid_shape=\((\d+),(\d+),(\d+)\)", txt)
        if m_shape !== nothing
            gnx = parse(Int32, m_shape.captures[1])
            gny = parse(Int32, m_shape.captures[2])
            gnz = parse(Int32, m_shape.captures[3])
            @assert (gnx, gny, gnz) == (ref_nx, ref_ny, ref_nz) "BILD grid_shape ($gnx,$gny,$gnz) != MRC grid ($ref_nx,$ref_ny,$ref_nz) in $bild_p"
        end

        n_primitives = 0
        for line in split(txt, '\n')
            s_ln = strip(line)
            if startswith(s_ln, ".arrow ")
                parts = split(s_ln)
                @assert length(parts) >= 7 "Malformed .arrow directive in $bild_p: $s_ln"
                x1 = parse(Float64, parts[2])
                y1 = parse(Float64, parts[3])
                z1 = parse(Float64, parts[4])
                x2 = parse(Float64, parts[5])
                y2 = parse(Float64, parts[6])
                z2 = parse(Float64, parts[7])
                @assert isfinite(x1) && isfinite(y1) && isfinite(z1) && isfinite(x2) && isfinite(y2) && isfinite(z2) "Non-finite .arrow coordinate in $bild_p"
                @assert (xmin - tol <= x1 <= xmax + tol) && (ymin - tol <= y1 <= ymax + tol) && (zmin - tol <= z1 <= zmax + tol) "Arrow base ($x1,$y1,$z1) outside MRC domain [$xmin,$xmax]x[$ymin,$ymax]x[$zmin,$zmax] in $bild_p"
                n_primitives += 1
            elseif startswith(s_ln, ".move ") || startswith(s_ln, ".draw ")
                parts = split(s_ln)
                @assert length(parts) == 4 "Malformed polyline directive in $bild_p: $s_ln"
                px = parse(Float64, parts[2])
                py = parse(Float64, parts[3])
                pz = parse(Float64, parts[4])
                @assert isfinite(px) && isfinite(py) && isfinite(pz) "Non-finite polyline coordinate in $bild_p"
                @assert (xmin - tol <= px <= xmax + tol) && (ymin - tol <= py <= ymax + tol) && (zmin - tol <= pz <= zmax + tol) "Polyline vertex ($px,$py,$pz) outside MRC domain [$xmin,$xmax]x[$ymin,$ymax]x[$zmin,$zmax] in $bild_p"
                n_primitives += 1
            end
        end
        @assert n_primitives >= 1 "BILD file $bild_p contains no geometric directives (.arrow/.move/.draw)"
    end

    return (
        aligned = true,
        grid_shape = (Int(ref_nx), Int(ref_ny), Int(ref_nz)),
        origin = (ox, oy, oz),
        voxel_size = (dx, dy, dz),
        bbox_min = (xmin, ymin, zmin),
        bbox_max = (xmax, ymax, zmax),
        n_mrc_verified = length(mrc_paths),
        n_bild_verified = length(bild_paths),
    )
end

"""
    export_chimerax_hydro_cxc_script(
        filepath::AbstractString,
        scene_files::AbstractDict;
        scene_legend::AbstractString = "1 scene unit = 0.5 m",
        clay_level::Real = 0.5,
        water_level::Real = 0.5,
    ) -> String

Generates a ready-to-run UCSF ChimeraX `.cxc` script implementing the three-layer
hydrodynamic scene architecture:
  - Layer A (Geological context): semi-transparent/mesh surfaces for `clay_halo_mask`,
    plus optional `core_mask` and `fracture_mask`.
  - Layer B (Velocity arrows & streamlines/pathlines): sparse `.bild` arrows and
    RK4-integrated `.bild` streamlines/pathlines.
  - Layer C (One scalar field at a time): opens `water_volume_fraction` (or `temperature`)
    at a field-appropriate isosurface threshold, with explicit notes on examining
    flow geometry before turning on scalar surfaces and a 2D scene-scale legend.
"""
function export_chimerax_hydro_cxc_script(
    filepath::AbstractString,
    scene_files::AbstractDict;
    scene_legend::AbstractString = "1 scene unit = 0.5 m",
    clay_level::Real = 0.5,
    water_level::Real = 0.5,
)::String
    for k in ("clay_halo_mask", "water_volume_fraction", "flow_vectors", "streamlines")
        haskey(scene_files, k) || throw(ArgumentError("scene_files missing required key '$k'"))
    end
    out_path = endswith(lowercase(String(filepath)), ".cxc") ? String(filepath) : String(filepath) * ".cxc"
    legend_full = occursin("[MODEL ILLUSTRATION", scene_legend) ?
        String(scene_legend) :
        String(scene_legend) * " [MODEL ILLUSTRATION - RUNG_4_MODEL]"

    open(out_path, "w") do io
        println(io, "# ==============================================================================")
        println(io, "# ChimeraX Three-Layer Hydrodynamic & Geological Compartment Scene Script (.cxc)")
        println(io, "# Epistemic Tag: [MODEL ILLUSTRATION - RUNG_4_MODEL, NOT EMPIRICAL CFD EVIDENCE]")
        println(io, "# Scene Scale Convention: ", legend_full)
        println(io, "# Streamline vs Pathline Note: Streamlines trace instantaneous velocity tangents")
        println(io, "# at fixed snapshot t_k; pathlines trace fluid parcel trajectories across time.")
        println(io, "# ==============================================================================")
        println(io, "set bgColor white")
        println(io, "")
        println(io, "# Layer A: Geological context (restrained mesh / semi-transparent frame)")
        model_id = 1
        println(io, "open ", scene_files["clay_halo_mask"])
        println(io, "volume #", model_id, " style mesh level ", Float64(clay_level), " color tan")
        if haskey(scene_files, "fracture_mask")
            model_id += 1
            println(io, "open ", scene_files["fracture_mask"])
            println(io, "volume #", model_id, " style surface level 0.5 color #94a3b8 transparency 0.78")
        end
        if haskey(scene_files, "core_mask")
            model_id += 1
            println(io, "open ", scene_files["core_mask"])
            println(io, "volume #", model_id, " style surface level 0.5 color #d97706 transparency 0.75")
        end
        println(io, "")
        water_model_id = model_id + 1
        println(io, "# Layer C: One scalar field as an isosurface (threshold 0.5 for water fraction in [0, 1];")
        println(io, "# do not reuse 0.5 blindly for pressure or velocity magnitude).")
        println(io, "# First-pass tip: run `volume #", water_model_id, " hide` while inspecting arrows and streamlines,")
        println(io, "# then re-enable with low visual prominence (`transparency 0.65`).")
        println(io, "open ", scene_files["water_volume_fraction"])
        println(io, "volume #", water_model_id, " style surface level ", Float64(water_level), " color cyan transparency 0.65")
        if haskey(scene_files, "vorticity_mag")
            vort_model_id = water_model_id + 1
            vort_lvl = get(scene_files, "vorticity_level", "0.08")
            println(io, "# Optional DEC 2-Form Vorticity Magnitude ||curl(u)||_2 (permeability-jump vortex sheet + baroclinic torque):")
            println(io, "open ", scene_files["vorticity_mag"])
            println(io, "volume #", vort_model_id, " style surface level ", vort_lvl, " color #a855f7 transparency 0.72")
        end
        println(io, "")
        println(io, "# Layer B: Sparse velocity arrows (x_end = x + s * u) and RK4 streamlines (BILD)")
        println(io, "open ", scene_files["flow_vectors"])
        println(io, "open ", scene_files["streamlines"])
        if haskey(scene_files, "pathlines")
            println(io, "# Optional time-integrated fluid parcel pathlines across the episodic pulse:")
            println(io, "open ", scene_files["pathlines"])
        end
        println(io, "")
        println(io, "# Explicit scene-coordinate scale legend (MRC headers lack macroscopic unit labels)")
        println(
            io,
            "2dlabels create scene_scale_legend text \"",
            legend_full,
            "\" xpos 0.03 ypos 0.94 size 16 color black",
        )
        println(io, "view")
    end
    return out_path
end

# ------------------------------------------------------------------------------
# 6. PyMOL CGO Bridge for .bild Velocity Arrows, Streamlines & Pathlines + .mrc
# ------------------------------------------------------------------------------

function _parse_bild_to_cgo_records(
    bild_path::AbstractString;
    default_line_radius::Real = 0.03,
)
    @assert isfile(bild_path) "BILD file does not exist: $bild_path"
    cr, cg, cb = 0.20, 0.50, 0.85
    has_curr = false
    curr_x, curr_y, curr_z = 0.0, 0.0, 0.0
    r_line = Float64(default_line_radius)

    cylinders = NTuple{10, Float64}[]
    cones = NTuple{10, Float64}[]
    n_arrows = 0
    n_segments = 0

    for line in eachline(bild_path)
        s = strip(line)
        (isempty(s) || startswith(s, ".comment")) && continue
        if startswith(s, ".color ")
            parts = split(s)
            @assert length(parts) == 4 "Malformed .color directive in $bild_path: $s"
            cr = parse(Float64, parts[2])
            cg = parse(Float64, parts[3])
            cb = parse(Float64, parts[4])
        elseif startswith(s, ".arrow ")
            parts = split(s)
            @assert length(parts) >= 7 "Malformed .arrow directive in $bild_path: $s"
            x1 = parse(Float64, parts[2])
            y1 = parse(Float64, parts[3])
            z1 = parse(Float64, parts[4])
            x2 = parse(Float64, parts[5])
            y2 = parse(Float64, parts[6])
            z2 = parse(Float64, parts[7])
            r_cyl = length(parts) >= 8 ? parse(Float64, parts[8]) : 0.025
            r_cone = length(parts) >= 9 ? parse(Float64, parts[9]) : 0.08
            frac = length(parts) >= 10 ? parse(Float64, parts[10]) : 0.75
            xm = x1 + frac * (x2 - x1)
            ym = y1 + frac * (y2 - y1)
            zm = z1 + frac * (z2 - z1)
            push!(cylinders, (x1, y1, z1, xm, ym, zm, r_cyl, cr, cg, cb))
            push!(cones, (xm, ym, zm, x2, y2, z2, r_cone, cr, cg, cb))
            n_arrows += 1
        elseif startswith(s, ".move ")
            parts = split(s)
            @assert length(parts) == 4 "Malformed .move directive in $bild_path: $s"
            curr_x = parse(Float64, parts[2])
            curr_y = parse(Float64, parts[3])
            curr_z = parse(Float64, parts[4])
            has_curr = true
        elseif startswith(s, ".draw ")
            parts = split(s)
            @assert length(parts) == 4 "Malformed .draw directive in $bild_path: $s"
            @assert has_curr ".draw encountered before .move in $bild_path"
            nx_p = parse(Float64, parts[2])
            ny_p = parse(Float64, parts[3])
            nz_p = parse(Float64, parts[4])
            push!(cylinders, (curr_x, curr_y, curr_z, nx_p, ny_p, nz_p, r_line, cr, cg, cb))
            curr_x, curr_y, curr_z = nx_p, ny_p, nz_p
            n_segments += 1
        end
    end

    return (
        cylinders = cylinders,
        cones = cones,
        n_arrows = n_arrows,
        n_segments = n_segments,
        n_cgo_primitives = length(cylinders) + length(cones),
    )
end

function _sanitize_pymol_obj_name(raw_name::AbstractString)::String
    base = replace(basename(String(raw_name)), r"\.bild$"i => "")
    cleaned = replace(base, r"[^A-Za-z0-9_]" => "_")
    return isempty(cleaned) ? "bild_cgo" : cleaned
end

"""
    export_bild_to_pymol_cgo_py(
        bild_paths::AbstractVector{<:AbstractString},
        out_py_path::AbstractString;
        default_line_radius::Real = 0.03,
    ) -> NamedTuple

Translates one or more UCSF ChimeraX `.bild` files (`.color`, `.arrow`, `.move`, `.draw`)
into a self-contained PyMOL Compiled Graphics Objects (CGO) Python script (`cgo.CYLINDER`
and `cgo.CONE`) stamped `[MODEL ILLUSTRATION - RUNG_4_MODEL]`, and returns exact counts
of translated arrows, polyline segments, CGO cylinders, and CGO cones.
"""
function export_bild_to_pymol_cgo_py(
    bild_paths::AbstractVector{<:AbstractString},
    out_py_path::AbstractString;
    default_line_radius::Real = 0.03,
)
    @assert !isempty(bild_paths) "bild_paths must contain at least one .bild file"
    py_path = endswith(lowercase(String(out_py_path)), ".py") ? String(out_py_path) : String(out_py_path) * ".py"

    parsed_items = Vector{Pair{String, NamedTuple}}()
    tot_arrows = 0
    tot_segments = 0
    tot_cylinders = 0
    tot_cones = 0

    for bp in bild_paths
        rec = _parse_bild_to_cgo_records(bp; default_line_radius = default_line_radius)
        obj_name = _sanitize_pymol_obj_name(bp)
        push!(parsed_items, obj_name => rec)
        tot_arrows += rec.n_arrows
        tot_segments += rec.n_segments
        tot_cylinders += length(rec.cylinders)
        tot_cones += length(rec.cones)
    end
    tot_primitives = tot_cylinders + tot_cones

    open(py_path, "w") do io
        println(io, "#!/usr/bin/env python3")
        println(io, "# ==============================================================================")
        println(io, "# PyMOL CGO Bridge Script translated from ChimeraX .bild files")
        println(io, "# Epistemic Tag: [MODEL ILLUSTRATION - RUNG_4_MODEL, NOT EMPIRICAL CFD EVIDENCE]")
        println(io, "# Summary: n_files=$(length(bild_paths)) n_arrows=$tot_arrows n_segments=$tot_segments n_cylinders=$tot_cylinders n_cones=$tot_cones n_cgo_primitives=$tot_primitives")
        println(io, "# ==============================================================================")
        println(io, "from pymol import cmd, cgo")
        println(io, "")
        for (obj_name, rec) in parsed_items
            println(io, "# Object: $obj_name (arrows=$(rec.n_arrows), segments=$(rec.n_segments), cgo_primitives=$(rec.n_cgo_primitives))")
            println(io, "cgo_$(obj_name) = [")
            for (x1, y1, z1, x2, y2, z2, r_c, cr, cg, cb) in rec.cylinders
                println(io, "    cgo.CYLINDER, $x1, $y1, $z1, $x2, $y2, $z2, $r_c, $cr, $cg, $cb, $cr, $cg, $cb,")
            end
            for (x1, y1, z1, x2, y2, z2, r_cone, cr, cg, cb) in rec.cones
                println(io, "    cgo.CONE, $x1, $y1, $z1, $x2, $y2, $z2, $r_cone, 0.0, $cr, $cg, $cb, $cr, $cg, $cb, 1.0, 1.0,")
            end
            println(io, "]")
            println(io, "cmd.load_cgo(cgo_$(obj_name), \"$(obj_name)\")")
            println(io, "")
        end
    end

    return (
        py_path = py_path,
        n_files = length(bild_paths),
        n_arrows = tot_arrows,
        n_segments = tot_segments,
        n_cylinders = tot_cylinders,
        n_cones = tot_cones,
        n_cgo_primitives = tot_primitives,
    )
end

function export_bild_to_pymol_cgo_py(
    bild_path::AbstractString,
    out_py_path::AbstractString;
    default_line_radius::Real = 0.03,
)
    return export_bild_to_pymol_cgo_py([String(bild_path)], out_py_path; default_line_radius = default_line_radius)
end

"""
    export_pymol_hydro_scene_script(
        filepath::AbstractString,
        scene_files::AbstractDict;
        scene_legend::AbstractString = "1 scene unit = 0.5 m",
        clay_level::Real = 0.5,
        water_level::Real = 0.5,
        vorticity_level::Real = 0.08,
        png_filename::AbstractString = "pymol_hydro_stage3_venting_model_rung4.png",
    ) -> NamedTuple

Generates a self-contained PyMOL Python script (`hydro_scene_5stage_0p5m_pymol.py`)
that loads the 3D geological compartment and scalar `.mrc` volumes (`format="ccp4"`)
alongside PyMOL CGO (`cgo.CYLINDER`, `cgo.CONE`) translations of the `.bild` velocity
arrows, streamlines, and pathlines (`[MODEL ILLUSTRATION - RUNG_4_MODEL]`), prints the
loaded object inventory and CGO counts, and saves a `1920x1080` PNG verification image.
"""
function export_pymol_hydro_scene_script(
    filepath::AbstractString,
    scene_files::AbstractDict;
    scene_legend::AbstractString = "1 scene unit = 0.5 m",
    clay_level::Real = 0.5,
    water_level::Real = 0.5,
    vorticity_level::Real = 0.08,
    png_filename::AbstractString = "pymol_hydro_stage3_venting_model_rung4.png",
)
    for k in ("clay_halo_mask", "water_volume_fraction", "flow_vectors", "streamlines")
        haskey(scene_files, k) || throw(ArgumentError("scene_files missing required key '$k'"))
    end
    out_path = endswith(lowercase(String(filepath)), ".py") ? String(filepath) : String(filepath) * ".py"
    base_dir = dirname(abspath(out_path))

    resolve_p(p::AbstractString) = isabspath(p) ? String(p) : joinpath(base_dir, String(p))

    bild_keys = String["flow_vectors", "streamlines"]
    haskey(scene_files, "pathlines") && push!(bild_keys, "pathlines")

    parsed_cgos = Vector{Tuple{String, NamedTuple}}()
    tot_arrows = 0
    tot_segments = 0
    tot_cylinders = 0
    tot_cones = 0

    for bk in bild_keys
        bp = resolve_p(String(scene_files[bk]))
        rec = _parse_bild_to_cgo_records(bp; default_line_radius = (bk == "pathlines" ? 0.035 : 0.028))
        push!(parsed_cgos, (bk, rec))
        tot_arrows += rec.n_arrows
        tot_segments += rec.n_segments
        tot_cylinders += length(rec.cylinders)
        tot_cones += length(rec.cones)
    end
    tot_primitives = tot_cylinders + tot_cones

    legend_full = occursin("[MODEL ILLUSTRATION", scene_legend) ?
        String(scene_legend) :
        String(scene_legend) * " [MODEL ILLUSTRATION - RUNG_4_MODEL]"

    open(out_path, "w") do io
        println(io, "#!/usr/bin/env python3")
        println(io, "# ==============================================================================")
        println(io, "# PyMOL Three-Layer Hydrodynamic & Geological Compartment Scene Script (.py)")
        println(io, "# Epistemic Tag: [MODEL ILLUSTRATION - RUNG_4_MODEL, NOT EMPIRICAL CFD EVIDENCE]")
        println(io, "# Scene Scale Convention: ", legend_full)
        println(io, "# CGO Summary: n_arrows=$tot_arrows n_segments=$tot_segments n_cylinders=$tot_cylinders n_cones=$tot_cones n_cgo_primitives=$tot_primitives")
        println(io, "# ==============================================================================")
        println(io, "import os")
        println(io, "import struct")
        println(io, "import tempfile")
        println(io, "from pymol import cmd, cgo")
        println(io, "")
        println(io, "DEFAULT_SCENE_DIR = $(repr(base_dir))")
        println(io, "SCRIPT_DIR = DEFAULT_SCENE_DIR if os.path.isdir(DEFAULT_SCENE_DIR) else os.getcwd()")
        println(io, "")
        println(io, "def load_mrc2014_as_ccp4(filename, map_name):")
        println(io, "    path = filename if os.path.isabs(filename) else os.path.join(SCRIPT_DIR, filename)")
        println(io, "    with open(path, 'rb') as f:")
        println(io, "        raw = bytearray(f.read())")
        println(io, "    nsymbt = struct.unpack('<i', raw[92:96])[0]")
        println(io, "    if nsymbt > 0:")
        println(io, "        # Strip extended symmetry/metadata bytes for strict CCP4 map compatibility in PyMOL")
        println(io, "        clean_raw = raw[:1024] + raw[1024 + nsymbt:]")
        println(io, "        clean_raw[92:96] = struct.pack('<i', 0)")
        println(io, "        fd, tmp_p = tempfile.mkstemp(suffix='.ccp4')")
        println(io, "        os.close(fd)")
        println(io, "        with open(tmp_p, 'wb') as tf:")
        println(io, "            tf.write(clean_raw)")
        println(io, "        cmd.load(tmp_p, map_name, format='ccp4')")
        println(io, "        os.remove(tmp_p)")
        println(io, "    else:")
        println(io, "        cmd.load(path, map_name, format='ccp4')")
        println(io, "")
        println(io, "cmd.bg_color('white')")
        println(io, "")
        println(io, "# Layer A: Geological compartment context")
        println(io, "load_mrc2014_as_ccp4($(repr(basename(String(scene_files["clay_halo_mask"])))), 'clay_halo_map')")
        println(io, "cmd.isomesh('clay_halo_mesh', 'clay_halo_map', $(Float64(clay_level)))")
        println(io, "cmd.color('tan', 'clay_halo_mesh')")
        if haskey(scene_files, "fracture_mask")
            println(io, "load_mrc2014_as_ccp4($(repr(basename(String(scene_files["fracture_mask"])))), 'fracture_map')")
            println(io, "cmd.isosurface('fracture_surf', 'fracture_map', 0.5)")
            println(io, "cmd.color('slate', 'fracture_surf')")
            println(io, "cmd.set('transparency', 0.78, 'fracture_surf')")
        end
        if haskey(scene_files, "core_mask")
            println(io, "load_mrc2014_as_ccp4($(repr(basename(String(scene_files["core_mask"])))), 'core_map')")
            println(io, "cmd.isosurface('core_surf', 'core_map', 0.5)")
            println(io, "cmd.color('tv_orange', 'core_surf')")
            println(io, "cmd.set('transparency', 0.75, 'core_surf')")
        end
        println(io, "")
        println(io, "# Layer C: Scalar field isosurfaces (water volume fraction & optional DEC vorticity)")
        println(io, "load_mrc2014_as_ccp4($(repr(basename(String(scene_files["water_volume_fraction"])))), 'water_map')")
        println(io, "cmd.isosurface('water_surf', 'water_map', $(Float64(water_level)))")
        println(io, "cmd.color('cyan', 'water_surf')")
        println(io, "cmd.set('transparency', 0.65, 'water_surf')")
        if haskey(scene_files, "vorticity_mag")
            println(io, "load_mrc2014_as_ccp4($(repr(basename(String(scene_files["vorticity_mag"])))), 'vorticity_map')")
            println(io, "cmd.isosurface('vorticity_surf', 'vorticity_map', $(Float64(vorticity_level)))")
            println(io, "cmd.color('violetpurple', 'vorticity_surf')")
            println(io, "cmd.set('transparency', 0.72, 'vorticity_surf')")
        end
        println(io, "")
        println(io, "# Layer B: PyMOL CGO 3D velocity arrows, streamlines, and pathlines")
        for (bk, rec) in parsed_cgos
            obj_name = "$(bk)_cgo"
            println(io, "cgo_$(bk) = [")
            for (x1, y1, z1, x2, y2, z2, r_c, cr, cg, cb) in rec.cylinders
                println(io, "    cgo.CYLINDER, $x1, $y1, $z1, $x2, $y2, $z2, $r_c, $cr, $cg, $cb, $cr, $cg, $cb,")
            end
            for (x1, y1, z1, x2, y2, z2, r_cone, cr, cg, cb) in rec.cones
                println(io, "    cgo.CONE, $x1, $y1, $z1, $x2, $y2, $z2, $r_cone, 0.0, $cr, $cg, $cb, $cr, $cg, $cb, 1.0, 1.0,")
            end
            println(io, "]")
            println(io, "cmd.load_cgo(cgo_$(bk), $(repr(obj_name)))")
        end
        println(io, "")
        println(io, "cmd.orient()")
        println(io, "loaded_names = cmd.get_names('all')")
        println(io, "print('[PyMOL-RUNG4-SCENE] loaded_objects =', loaded_names)")
        println(io, "print('[PyMOL-RUNG4-SCENE] cgo_counts: arrows=$tot_arrows segments=$tot_segments cylinders=$tot_cylinders cones=$tot_cones total_primitives=$tot_primitives')")
        println(io, "png_out = os.path.join(SCRIPT_DIR, $(repr(String(png_filename))))")
        println(io, "cmd.png(png_out, width=1920, height=1080, dpi=300, ray=1)")
        println(io, "print('[PyMOL-RUNG4-SCENE] saved_png =', png_out)")
    end

    return (
        py_path = out_path,
        n_arrows = tot_arrows,
        n_segments = tot_segments,
        n_cylinders = tot_cylinders,
        n_cones = tot_cones,
        n_cgo_primitives = tot_primitives,
    )
end

function export_pymol_hydro_scene_script(
    stage_dir::AbstractString;
    out_py_name::AbstractString = "hydro_scene_5stage_0p5m_pymol.py",
    scene_unit::AbstractString = "0p5m",
    active_stage::AbstractString = "3_venting",
    scene_legend::AbstractString = "1 scene unit = 0.5 m",
    clay_level::Real = 0.5,
    water_level::Real = 0.5,
    vorticity_level::Real = 0.08,
    png_filename::AbstractString = "pymol_hydro_stage3_venting_model_rung4.png",
)
    s_unit = replace(strip(String(scene_unit)), r"[^A-Za-z0-9]" => "")
    scene_files = Dict{String, String}(
        "clay_halo_mask" => joinpath(stage_dir, "clay_halo_mask_scene_$(s_unit).mrc"),
        "water_volume_fraction" => joinpath(stage_dir, "water_volume_fraction_$(active_stage)_scene_$(s_unit).mrc"),
        "flow_vectors" => joinpath(stage_dir, "flow_vectors_$(active_stage)_scene_$(s_unit).bild"),
        "streamlines" => joinpath(stage_dir, "streamlines_$(active_stage)_scene_$(s_unit).bild"),
    )
    frac_p = joinpath(stage_dir, "fracture_mask_scene_$(s_unit).mrc")
    isfile(frac_p) && (scene_files["fracture_mask"] = frac_p)
    core_p = joinpath(stage_dir, "core_mask_scene_$(s_unit).mrc")
    isfile(core_p) && (scene_files["core_mask"] = core_p)
    path_p = joinpath(stage_dir, "pathlines_full_cycle_scene_$(s_unit).bild")
    isfile(path_p) && (scene_files["pathlines"] = path_p)
    vort_p = joinpath(stage_dir, "vorticity_mag_scene_$(s_unit).mrc")
    isfile(vort_p) && (scene_files["vorticity_mag"] = vort_p)

    return export_pymol_hydro_scene_script(
        joinpath(stage_dir, out_py_name),
        scene_files;
        scene_legend = scene_legend,
        clay_level = clay_level,
        water_level = water_level,
        vorticity_level = vorticity_level,
        png_filename = png_filename,
    )
end

end # module ExportChimeraX

# ==============================================================================
# Self-Contained Unit Tests (Barbell Bridge Gate, 3-State Colors, MRC-2014 1024B)
# ==============================================================================
using Test
using .ExportChimeraX

if abspath(PROGRAM_FILE) == @__FILE__
    @testset "ExportChimeraX: Tarjan Bridge Gate, Monomer Colors & MRC-2014 Layout" begin
        # 1. Barbell Graph + Leaf + Isolated Monomer Test (8 vertices):
        #    - Triangle A: (1,2), (2,3), (3,1) -> 3 cycle edges
        #    - Bridge inside 2-core: (3,4)     -> MUST be EDGE_BRIDGE_OR_TREE (NOT cycle!)
        #    - Triangle B: (4,5), (5,6), (6,4) -> 3 cycle edges
        #    - Dangling leaf branch: (6,7)     -> EDGE_BRIDGE_OR_TREE, vertex 7 is VERT_TREE_OR_BRIDGE
        #    - Self-loop on vertex 7: (7,7)    -> EDGE_SELF_LOOP
        #    - Vertex 8: no inter-chain edges  -> VERT_ISOLATED_MONOMER (Red)
        edges = [
            (1, 2), (2, 3), (3, 1), # eid 1..3: Triangle A
            (3, 4),                 # eid 4:    Bridge connecting the two triangles
            (4, 5), (5, 6), (6, 4), # eid 5..7: Triangle B
            (6, 7),                 # eid 8:    Dangling leaf branch
            (7, 7),                 # eid 9:    Intra-chain self-loop
        ]
        topo = classify_network_topology(8, edges)
        @test topo.n_cycle_edges == 6
        @test topo.n_bridge_edges == 2
        @test topo.n_self_loops == 1
        @test topo.edge_classes[1] === EDGE_CYCLE
        @test topo.edge_classes[4] === EDGE_BRIDGE_OR_TREE # Bridge inside 2-core caught!
        @test topo.edge_classes[5] === EDGE_CYCLE
        @test topo.edge_classes[8] === EDGE_BRIDGE_OR_TREE
        @test topo.edge_classes[9] === EDGE_SELF_LOOP

        for v in 1:6
            @test topo.vertex_classes[v] === VERT_CYCLE
        end
        @test topo.vertex_classes[7] === VERT_TREE_OR_BRIDGE
        @test topo.vertex_classes[8] === VERT_ISOLATED_MONOMER

        # 2. Verify .cmm output contains all 3 vertex states (Teal, Amber, Red) and unit suffix
        coords = zeros(Float64, 8, 3)
        for i in 1:8
            coords[i, 1] = Float64(i)
        end
        cmm_tmp = tempname()
        cmm_path = export_network_to_chimerax_cmm(cmm_tmp, coords, edges; scene_unit = "um")
        @test endswith(cmm_path, "_scene_um.cmm")
        cmm_text = read(cmm_path, String)
        @test occursin("note=\"cycle_vertex\"", cmm_text)
        @test occursin("note=\"tree_or_bridge_vertex\"", cmm_text)
        @test occursin("note=\"isolated_monomer\"", cmm_text)
        @test occursin("r=\"0.86\" g=\"0.15\" b=\"0.15\" radius=\"0.25\" note=\"isolated_monomer\"", cmm_text)
        @test occursin("[MODEL ILLUSTRATION - RUNG_4_MODEL, NOT EMPIRICAL EVIDENCE]", cmm_text)
        rm(cmm_path; force = true)

        # 2b. Verify .bild vector field exporter and unit suffix
        vecs = ones(Float64, 8, 3)
        bild_tmp = tempname()
        bild_path = export_kinesis_vectors_to_bild(bild_tmp, coords, vecs; scene_unit = "um", scale = 0.5)
        @test endswith(bild_path, "_scene_um.bild")
        bild_text = read(bild_path, String)
        @test occursin(".comment [MODEL ILLUSTRATION - RUNG_4_MODEL, NOT EMPIRICAL EVIDENCE] scene_unit=um", bild_text)
        @test occursin(".arrow 1.0 0.0 0.0 1.5 0.5 0.5", bild_text)
        rm(bild_path; force = true)

        # 3. Verify MRC-2014 binary volume writer and independent round-trip reader
        vol = reshape(collect(Float32, 1:(4 * 5 * 6)), (4, 5, 6))
        mrc_tmp = tempname()
        mrc_path = export_volume_to_mrc2014(
            mrc_tmp, vol;
            voxel_size = (2.0, 2.5, 3.0),
            origin = (-1.0, 0.5, 4.0),
            scene_unit = "um",
            field_name = "H2O2_mM",
        )
        @test endswith(mrc_path, "_scene_um.mrc")
        @test filesize(mrc_path) == 1024 + 4 * (4 * 5 * 6)

        parsed_mrc = read_and_verify_mrc2014(
            mrc_path;
            expected_nx = 4,
            expected_ny = 5,
            expected_nz = 6,
            expected_voxel_size = (2.0, 2.5, 3.0),
            expected_origin = (-1.0, 0.5, 4.0),
            expected_data = vol,
        )
        @test parsed_mrc.nx == 4
        @test parsed_mrc.ny == 5
        @test parsed_mrc.nz == 6
        @test parsed_mrc.mode == 2
        @test (parsed_mrc.mapc, parsed_mrc.mapr, parsed_mrc.maps) == (1, 2, 3)
        @test parsed_mrc.cella == (8.0f0, 12.5f0, 18.0f0)
        @test parsed_mrc.cellb == (90.0f0, 90.0f0, 90.0f0)
        @test parsed_mrc.exttype == "MRCO"
        @test parsed_mrc.nversion == 20140
        @test parsed_mrc.map_stamp == "MAP "
        @test parsed_mrc.machst == (0x44, 0x44, 0x00, 0x00)
        @test parsed_mrc.dmin == 1.0f0
        @test parsed_mrc.dmax == 120.0f0
        @test parsed_mrc.data == vol
        @test occursin("field=H2O2_mM unit=um", parsed_mrc.labels[1])

        # 3b. Verify extended header (NSYMBT = 80) and axis-order permutation handling
        raw_orig = read(mrc_path)
        ext_mrc_path = mrc_tmp * "_ext80_scene_um.mrc"
        ext_raw = vcat(raw_orig[1:1024], fill(UInt8('S'), 80), raw_orig[1025:end])
        # Word 24 (bytes 93..96, 1-based) is NSYMBT = 80
        ext_raw[93:96] = reinterpret(UInt8, [htol(Int32(80))])
        write(ext_mrc_path, ext_raw)
        # Default expected_nsymbt = 0 must reject NSYMBT = 80
        @test_throws AssertionError read_and_verify_mrc2014(ext_mrc_path)
        # When expected_nsymbt = 80 (or nothing), reader skips the 80-byte extended header and round-trips vol
        parsed_ext = read_and_verify_mrc2014(
            ext_mrc_path;
            expected_nx = 4,
            expected_ny = 5,
            expected_nz = 6,
            expected_data = vol,
            expected_nsymbt = 80,
        )
        @test parsed_ext.nsymbt == 80
        @test parsed_ext.data == vol
        rm(ext_mrc_path; force = true)

        # Non-standard axis permutation (MAPC, MAPR, MAPS) = (3, 2, 1) must be rejected
        perm_mrc_path = mrc_tmp * "_perm_scene_um.mrc"
        perm_raw = copy(raw_orig)
        perm_raw[65:76] = reinterpret(UInt8, [htol(Int32(3)), htol(Int32(2)), htol(Int32(1))])
        write(perm_mrc_path, perm_raw)
        @test_throws AssertionError read_and_verify_mrc2014(perm_mrc_path)
        rm(perm_mrc_path; force = true)
        rm(mrc_path; force = true)

        # 4. Verify multigraph parallel-edge handling in Tarjan bridge-finding:
        #    Vertices 1 and 2 connected by two parallel edges (eids 1 and 2 -> 2-edge cycle),
        #    vertex 3 connected to vertex 2 by single cut-edge (eid 3 -> bridge),
        #    and vertex 4 isolated.
        multi_edges = [(1, 2), (1, 2), (2, 3)]
        multi_topo = classify_network_topology(4, multi_edges)
        @test multi_topo.n_cycle_edges == 2
        @test multi_topo.n_bridge_edges == 1
        @test multi_topo.edge_classes[1] === EDGE_CYCLE
        @test multi_topo.edge_classes[2] === EDGE_CYCLE
        @test multi_topo.edge_classes[3] === EDGE_BRIDGE_OR_TREE
        @test multi_topo.vertex_classes[1] === VERT_CYCLE
        @test multi_topo.vertex_classes[2] === VERT_CYCLE
        @test multi_topo.vertex_classes[3] === VERT_TREE_OR_BRIDGE
        @test multi_topo.vertex_classes[4] === VERT_ISOLATED_MONOMER

        # 5. Verify Hydrodynamic Velocity Arrows (.bild), Streamlines vs Pathlines (.bild),
        #    Scene Coordinate-Alignment Gate, and ChimeraX .cxc Script Generator
        hydro_dir = mktempdir()
        orig_h = (1.0, 2.0, 0.0)
        vox_h = (0.5, 0.5, 0.5)
        clay_vol = fill(0.6f0, (6, 6, 8))
        water_vol = fill(0.75f0, (6, 6, 8))
        clay_mrc = export_volume_to_mrc2014(
            joinpath(hydro_dir, "clay_halo_mask"),
            clay_vol;
            voxel_size = vox_h,
            origin = orig_h,
            scene_unit = "0p5m",
            field_name = "clay_halo_mask",
        )
        water_mrc = export_volume_to_mrc2014(
            joinpath(hydro_dir, "water_volume_fraction"),
            water_vol;
            voxel_size = vox_h,
            origin = orig_h,
            scene_unit = "0p5m",
            field_name = "water_volume_fraction",
        )

        u_4d = zeros(Float64, 6, 6, 8, 3)
        u_4d[:, :, :, 1] .= 0.2
        u_4d[:, :, :, 2] .= 0.1
        u_4d[:, :, :, 3] .= 0.4
        arrows_bild = export_velocity_arrows_to_bild(
            joinpath(hydro_dir, "flow_vectors"),
            orig_h,
            vox_h,
            u_4d;
            stride = 3,
            scale = 2.0,
            scene_unit = "0p5m",
        )
        arrows_txt = read(arrows_bild, String)
        @test occursin(".color 0.1 0.65 0.9", arrows_txt)
        @test occursin(".arrow 1.0 2.0 0.0 1.4 2.2 0.8 0.025 0.08 0.75", arrows_txt)

        # Include consecutive duplicate points and a stationary 2-point polyline to test deduplication
        polylines_sl = [
            [(1.5, 2.5, 0.5), (1.7, 2.6, 1.0), (1.7, 2.6, 1.0), (1.9, 2.8, 1.6)],
            [(2.0, 3.0, 0.5), (2.1, 3.1, 1.2)],
            [(1.8, 2.8, 0.8), (1.8, 2.8, 0.8)],
        ]
        sl_bild = export_streamlines_to_bild(
            joinpath(hydro_dir, "streamlines"),
            polylines_sl;
            scene_unit = "0p5m",
            color = (0.15, 0.60, 0.40),
            line_kind = :streamline,
            origin = orig_h,
            voxel_size = vox_h,
            grid_shape = (6, 6, 8),
        )
        sl_txt = read(sl_bild, String)
        @test occursin("line_kind=streamline", sl_txt)
        @test occursin("n_polylines=2", sl_txt)
        @test occursin(".move 1.5 2.5 0.5", sl_txt)
        @test occursin(".draw 1.7 2.6 1.0", sl_txt)
        @test occursin(".draw 1.9 2.8 1.6", sl_txt)
        @test length(collect(eachmatch(r"\.draw 1\.7 2\.6 1\.0", sl_txt))) == 1

        pl_mat = [1.5 2.5 0.5; 1.8 2.9 1.4; 2.2 3.3 2.5]
        pl_bild = export_streamlines_to_bild(
            joinpath(hydro_dir, "pathlines"),
            [pl_mat];
            scene_unit = "0p5m",
            color = (0.85, 0.35, 0.10),
            line_kind = :pathline,
            origin = orig_h,
            voxel_size = vox_h,
            grid_shape = (6, 6, 8),
        )
        pl_txt = read(pl_bild, String)
        @test occursin("line_kind=pathline", pl_txt)
        @test occursin(".move 1.5 2.5 0.5", pl_txt)
        @test occursin(".draw 2.2 3.3 2.5", pl_txt)

        align_res = verify_scene_coordinate_alignment(
            [clay_mrc, water_mrc],
            [arrows_bild, sl_bild, pl_bild];
            expected_origin = orig_h,
            expected_voxel_size = vox_h,
            expected_scene_unit = "0p5m",
        )
        @test align_res.aligned == true
        @test align_res.grid_shape == (6, 6, 8)
        @test align_res.n_mrc_verified == 2
        @test align_res.n_bild_verified == 3

        # Coordinate misalignment gate must reject empty bild_paths, mismatched origin, or out-of-bounds BILD
        @test_throws AssertionError verify_scene_coordinate_alignment(
            [clay_mrc],
            String[];
            expected_origin = orig_h,
            expected_voxel_size = vox_h,
            expected_scene_unit = "0p5m",
        )
        @test_throws AssertionError verify_scene_coordinate_alignment(
            [clay_mrc, water_mrc],
            [arrows_bild, sl_bild];
            expected_origin = (0.0, 0.0, 0.0),
            expected_voxel_size = vox_h,
            expected_scene_unit = "0p5m",
        )
        oob_bild = export_streamlines_to_bild(
            joinpath(hydro_dir, "oob_streamlines"),
            [[(1.5, 2.5, 0.5), (99.0, 99.0, 99.0)]];
            scene_unit = "0p5m",
        )
        @test_throws AssertionError verify_scene_coordinate_alignment(
            [clay_mrc],
            [oob_bild];
            expected_origin = orig_h,
            expected_voxel_size = vox_h,
            expected_scene_unit = "0p5m",
        )

        # Verify .cxc script generation (both minimal 4-key and full 7-key with fracture_mask & core_mask)
        cxc_path = export_chimerax_hydro_cxc_script(
            joinpath(hydro_dir, "open_hydro_scene.cxc"),
            Dict(
                "clay_halo_mask" => clay_mrc,
                "fracture_mask" => "fracture_mask_scene_0p5m.mrc",
                "core_mask" => "core_mask_scene_0p5m.mrc",
                "water_volume_fraction" => water_mrc,
                "flow_vectors" => arrows_bild,
                "streamlines" => sl_bild,
                "pathlines" => pl_bild,
            );
            scene_legend = "1 scene unit = 0.5 m [MODEL ILLUSTRATION - RUNG_4_MODEL]",
        )
        @test isfile(cxc_path)
        cxc_txt = read(cxc_path, String)
        @test occursin("set bgColor white", cxc_txt)
        @test occursin("volume #1 style mesh level 0.5 color tan", cxc_txt)
        @test occursin("volume #2 style surface level 0.5 color #94a3b8 transparency 0.78", cxc_txt)
        @test occursin("volume #3 style surface level 0.5 color #d97706 transparency 0.75", cxc_txt)
        @test occursin("volume #4 style surface level 0.5 color cyan", cxc_txt)
        @test occursin("1 scene unit = 0.5 m [MODEL ILLUSTRATION - RUNG_4_MODEL]", cxc_txt)
        @test !occursin("[MODEL ILLUSTRATION - RUNG_4_MODEL] [MODEL ILLUSTRATION - RUNG_4_MODEL]", cxc_txt)
        @test !occursin('\u2014', cxc_txt)
        @test !occursin('\u2013', cxc_txt)

        # Edge cases: invalid line_kind, stride, scale, color
        @test_throws ArgumentError export_streamlines_to_bild(joinpath(hydro_dir, "bad"), polylines_sl; line_kind = :streakline)
        @test_throws ArgumentError export_velocity_arrows_to_bild(joinpath(hydro_dir, "bad"), orig_h, vox_h, u_4d; stride = 0)
        @test_throws ArgumentError export_velocity_arrows_to_bild(joinpath(hydro_dir, "bad"), orig_h, vox_h, u_4d; scale = -1.0)

        # 6. Verify direct NSYMBT=80 writer support and PyMOL CGO Bridge (export_bild_to_pymol_cgo_py & export_pymol_hydro_scene_script)
        vort_vol = fill(0.12f0, (6, 6, 8))
        vort_mrc = export_volume_to_mrc2014(
            joinpath(hydro_dir, "vorticity_mag"),
            vort_vol;
            voxel_size = vox_h,
            origin = orig_h,
            scene_unit = "0p5m",
            field_name = "vorticity_mag",
            nsymbt = 80,
            extended_header = "[MODEL ILLUSTRATION - RUNG_4_MODEL] DEC_VORTICITY_2FORM",
        )
        @test filesize(vort_mrc) == 1024 + 80 + 4 * (6 * 6 * 8)
        parsed_vort = read_and_verify_mrc2014(vort_mrc; expected_nsymbt = 80, expected_data = vort_vol)
        @test parsed_vort.nsymbt == 80

        cgo_only_res = export_bild_to_pymol_cgo_py(
            [arrows_bild, sl_bild, pl_bild],
            joinpath(hydro_dir, "test_cgo_bridge.py"),
        )
        @test isfile(cgo_only_res.py_path)
        @test cgo_only_res.n_files == 3
        @test cgo_only_res.n_arrows == 12
        @test cgo_only_res.n_segments == 5
        @test cgo_only_res.n_cylinders == 12 + 5
        @test cgo_only_res.n_cones == 12
        @test cgo_only_res.n_cgo_primitives == 29

        pymol_scene_res = export_pymol_hydro_scene_script(
            joinpath(hydro_dir, "hydro_scene_5stage_0p5m_pymol.py"),
            Dict(
                "clay_halo_mask" => clay_mrc,
                "water_volume_fraction" => water_mrc,
                "vorticity_mag" => vort_mrc,
                "flow_vectors" => arrows_bild,
                "streamlines" => sl_bild,
                "pathlines" => pl_bild,
            );
            scene_legend = "1 scene unit = 0.5 m [MODEL ILLUSTRATION - RUNG_4_MODEL]",
        )
        @test isfile(pymol_scene_res.py_path)
        @test pymol_scene_res.n_arrows == 12
        @test pymol_scene_res.n_segments == 5
        @test pymol_scene_res.n_cgo_primitives == 29
        py_txt = read(pymol_scene_res.py_path, String)
        @test occursin("from pymol import cmd, cgo", py_txt)
        @test occursin("cgo.CYLINDER", py_txt)
        @test occursin("cgo.CONE", py_txt)
        @test occursin("load_mrc2014_as_ccp4", py_txt)
        @test !occursin('\u2014', py_txt)
        @test !occursin('\u2013', py_txt)

        rm(hydro_dir; recursive = true, force = true)
    end
    println("[PASS] All ExportChimeraX Tarjan bridge, 3-state vertex, hydrodynamic .bild/.cxc, PyMOL CGO bridge, coordinate-alignment, and 1024B MRC-2014 round-trip tests passed.")
end
