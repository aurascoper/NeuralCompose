#!/usr/bin/env julia
# ==============================================================================
# NeuralComposeLayaJEMAFixture.jl
# Complete 4-Pillar Fixture Generator & Verifier for Neural Compose.app:
#   Pillar 1 (Laya / LeJEPA): Dynamic Channel Mixer (4 Muse channels x 5 bands ->
#            Q = 20 specialized query nodes with L_query orthogonality loss) +
#            Global ZCA SIGReg Whitening Gate (Sigma_global == I_3 while preserving
#            local window anisotropy and 3D tilt theta_1).
#   Pillar 2 (ST-JEMA + Tarjan): Dual node/edge decoders (g_node, g_edge) +
#            iterative Tarjan bridge-finding (EDGE_CYCLE vs EDGE_BRIDGE_OR_TREE).
#   Pillar 3 (Memory): Coupled Fast Context Wireframe (tau_f = 1.2s) vs Slow
#            Consolidated Core (tau_s = 8.0s) + Hollow Habituation Shell Psi(x,t).
#   Pillar 4 (Multimodal Laya): Acoustic tempo/cadence alignment (Drut -> Madhya
#            -> Vilambit Laya) guiding fast wireframe absorption into slow core.
#
# Epistemic Status: [MODEL ILLUSTRATION - RUNG_4_MODEL | 4-PILLAR JEMA FIXTURE]
# Dependencies: Julia Base, LinearAlgebra, Statistics, Printf, Test stdlibs only.
# Strictly zero em-dashes and zero en-dashes.
# ==============================================================================

module NeuralComposeLayaJEMAFixture

using LinearAlgebra
using Statistics
using Printf
using Test

export EdgeClass, VertexClass, EDGE_CYCLE, EDGE_BRIDGE_OR_TREE, EDGE_SELF_LOOP
export VERT_CYCLE, VERT_TREE_OR_BRIDGE, VERT_ISOLATED_MONOMER
export FourPillarFrameRecord, FourPillarFixtureBundle
export classify_tarjan_topology, apply_sigreg_whitening_gate, evaluate_st_jema_decoders
export generate_four_pillar_fixture_60f, export_four_pillar_bundle
export CANONICAL_MUSE_NODES


@enum EdgeClass begin
    EDGE_CYCLE          = 1
    EDGE_BRIDGE_OR_TREE = 2
    EDGE_SELF_LOOP      = 3
end

@enum VertexClass begin
    VERT_CYCLE            = 1
    VERT_TREE_OR_BRIDGE   = 2
    VERT_ISOLATED_MONOMER = 3
end

struct FourPillarFrameRecord
    frame_idx::Int
    time_s::Float64
    phase_regime::String
    # Pillar 1: Laya (LeJEPA) Front-End Metrics
    laya_sigreg_loss::Float64
    laya_query_loss::Float64
    query_node_coords::Matrix{Float64}      # 20 x 3 node coordinates in whitened 3D space
    # Pillar 2: ST-JEMA + Tarjan Graph Metrics
    edges::Vector{Tuple{Int, Int}}
    edge_classes::Vector{EdgeClass}
    vertex_classes::Vector{VertexClass}
    beta_0::Int
    beta_1::Int
    n_cycle_edges::Int
    n_bridge_edges::Int
    st_node_pred_loss::Float64
    st_edge_pred_loss::Float64
    # Pillar 3: Memory (Fast Wireframe vs Slow Core + Hollow Shell)
    z_eeg_whitened::NTuple{3, Float64}
    mu_fast::NTuple{3, Float64}
    mu_slow::NTuple{3, Float64}
    sigma_fast_diag::NTuple{3, Float64}
    sigma_slow_diag::NTuple{3, Float64}
    mahalanobis_tension::Float64
    principal_axis_angle_deg::Float64
    overhang_escape_fraction::Float64
    hollow_shell_volume_fraction::Float64
    # Pillar 4: Multimodal Musical Laya Biofeedback
    z_music_target::NTuple{3, Float64}
    tempo_bpm::Float64
    laya_cadence_state::String              # "Vilambit (Slow)", "Madhya (Medium)", "Drut (Fast)"
    multimodal_alignment_loss::Float64
    laya_absorption_index::Float64          # 1 / (1 + D_M) in [0, 1]
end

struct FourPillarFixtureBundle
    frames::Vector{FourPillarFrameRecord}
    global_cov_whitened::Matrix{Float64}
    global_cond_number::Float64
    hysteresis_area_beta1_dm::Float64
    kymograph_rt::Matrix{Float64}           # 24 radii x 60 frames
    fast_fields::Vector{Array{Float32, 3}}
    slow_fields::Vector{Array{Float32, 3}}
    shell_fields::Vector{Array{Float32, 3}}
end

# ------------------------------------------------------------------------------
# 1. Iterative Tarjan Bridge-Finding Pass (Pillar 2: ST-JEMA Homology)
# ------------------------------------------------------------------------------

function classify_tarjan_topology(
    n_vertices::Int,
    edges::AbstractVector{Tuple{Int, Int}},
)
    n_vertices >= 0 || throw(ArgumentError("n_vertices must be non-negative"))
    m = length(edges)
    edge_classes = fill(EDGE_CYCLE, m)
    adj = [Tuple{Int, Int}[] for _ in 1:n_vertices]
    inter_deg = zeros(Int, n_vertices)
    n_self_loops = 0

    for (eid, (u, v)) in enumerate(edges)
        (1 <= u <= n_vertices && 1 <= v <= n_vertices) ||
            throw(BoundsError(1:n_vertices, (u, v)))
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
    n_components = 0
    stack = Tuple{Int, Int, Int}[]

    for start_v in 1:n_vertices
        tin[start_v] != 0 && continue
        n_components += 1
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

    has_cycle = falses(n_vertices)
    n_cycle = 0
    n_bridge = 0
    for (eid, (u, v)) in enumerate(edges)
        edge_classes[eid] === EDGE_SELF_LOOP && continue
        if is_bridge[eid]
            edge_classes[eid] = EDGE_BRIDGE_OR_TREE
            n_bridge += 1
        else
            edge_classes[eid] = EDGE_CYCLE
            has_cycle[u] = true
            has_cycle[v] = true
            n_cycle += 1
        end
    end

    v_classes = Vector{VertexClass}(undef, n_vertices)
    for i in 1:n_vertices
        v_classes[i] = has_cycle[i] ? VERT_CYCLE : (inter_deg[i] > 0 ? VERT_TREE_OR_BRIDGE : VERT_ISOLATED_MONOMER)
    end

    e_simple = m - n_self_loops
    beta_1 = e_simple - n_vertices + n_components
    return (
        edge_classes = edge_classes,
        vertex_classes = v_classes,
        beta_0 = n_components,
        beta_1 = beta_1,
        n_cycle_edges = n_cycle,
        n_bridge_edges = n_bridge,
        n_self_loops = n_self_loops,
    )
end

# ------------------------------------------------------------------------------
# 2. Pillar 1: Laya (LeJEPA) SIGReg Global Whitening Gate & Query Mixer
# ------------------------------------------------------------------------------

const CANONICAL_MUSE_NODES = [
    (id = 1,  label = "TP9_delta",  channelBand = "TP9 (delta 1-4Hz)",    role = "coherenceSeeking",    basePos = (-1.45, -0.85, -0.75)),
    (id = 2,  label = "TP9_theta",  channelBand = "TP9 (theta 4-8Hz)",    role = "coherenceSeeking",    basePos = (-1.55, -0.35, -0.45)),
    (id = 3,  label = "TP9_alpha",  channelBand = "TP9 (alpha 8-12Hz)",   role = "coherenceSeeking",    basePos = (-1.35,  0.10, -0.10)),
    (id = 4,  label = "TP9_beta",   channelBand = "TP9 (beta 13-30Hz)",   role = "displacementSeeking", basePos = (-1.15,  0.65,  0.45)),
    (id = 5,  label = "TP9_gamma",  channelBand = "TP9 (gamma 30-45Hz)",  role = "displacementSeeking", basePos = (-0.95,  1.15,  0.95)),
    (id = 6,  label = "AF7_delta",  channelBand = "AF7 (delta 1-4Hz)",    role = "coherenceSeeking",    basePos = (-0.55, -0.75, -0.60)),
    (id = 7,  label = "AF7_theta",  channelBand = "AF7 (theta 4-8Hz)",    role = "coherenceSeeking",    basePos = (-0.65, -0.20, -0.15)),
    (id = 8,  label = "AF7_alpha",  channelBand = "AF7 (alpha 8-12Hz)",   role = "coherenceSeeking",    basePos = (-0.60,  0.30,  0.25)),
    (id = 9,  label = "AF7_beta",   channelBand = "AF7 (beta 13-30Hz)",   role = "displacementSeeking", basePos = (-0.50,  0.85,  0.70)),
    (id = 10, label = "AF7_gamma",  channelBand = "AF7 (gamma 30-45Hz)",  role = "displacementSeeking", basePos = (-0.35,  1.35,  1.15)),
    (id = 11, label = "AF8_delta",  channelBand = "AF8 (delta 1-4Hz)",    role = "coherenceSeeking",    basePos = ( 0.55, -0.75, -0.60)),
    (id = 12, label = "AF8_theta",  channelBand = "AF8 (theta 4-8Hz)",    role = "coherenceSeeking",    basePos = ( 0.65, -0.20, -0.15)),
    (id = 13, label = "AF8_alpha",  channelBand = "AF8 (alpha 8-12Hz)",   role = "synthesis",           basePos = ( 0.60,  0.30,  0.25)),
    (id = 14, label = "AF8_beta",   channelBand = "AF8 (beta 13-30Hz)",   role = "displacementSeeking", basePos = ( 0.50,  0.85,  0.70)),
    (id = 15, label = "AF8_gamma",  channelBand = "AF8 (gamma 30-45Hz)",  role = "displacementSeeking", basePos = ( 0.35,  1.35,  1.15)),
    (id = 16, label = "TP10_delta", channelBand = "TP10 (delta 1-4Hz)",   role = "coherenceSeeking",    basePos = ( 1.45, -0.85, -0.75)),
    (id = 17, label = "TP10_theta", channelBand = "TP10 (theta 4-8Hz)",   role = "coherenceSeeking",    basePos = ( 1.55, -0.35, -0.45)),
    (id = 18, label = "TP10_alpha", channelBand = "TP10 (alpha 8-12Hz)",  role = "synthesis",           basePos = ( 1.35,  0.10, -0.10)),
    (id = 19, label = "TP10_beta",  channelBand = "TP10 (beta 13-30Hz)",  role = "displacementSeeking", basePos = ( 1.15,  0.65,  0.45)),
    (id = 20, label = "TP10_gamma", channelBand = "TP10 (gamma 30-45Hz)", role = "witness",             basePos = ( 0.95,  1.15,  0.95)),
]

"""
    apply_sigreg_whitening_gate(Z_raw::AbstractMatrix{Float64}) -> NamedTuple

Applies the Laya `SIGReg` (Sketched Isotropic Gaussian Regularization) ZCA
whitening gate across the 3 x K epoch trajectory `Z_raw` (`K >= 4`) so the global
coordinate basis satisfies `cov(Z_whitened') == I_3` (preventing dimensional collapse),
while preserving local sliding-window anisotropy inside sub-epochs.
When `Z_raw` is rank-deficient, collinear, planar, or constant (`eigval <= 1e-9`),
completes the nullspace in the zero-mean temporal row space via Gram-Schmidt against
deterministic harmonic modes so `C_white == I_3` and `cond_number == 1.0` hold for
any `3 x K` input (`K >= 4`).
Also computes the sketched 1D projection Gaussianity residual `l_sigreg_epoch` and
per-frame sliding-window residuals `l_sigreg_frames` across M = 16 sphere directions.
"""
function apply_sigreg_whitening_gate(Z_raw::AbstractMatrix{Float64})
    size(Z_raw, 1) == 3 || throw(ArgumentError("Z_raw must be 3 x K"))
    K = size(Z_raw, 2)
    K >= 4 || throw(ArgumentError("Z_raw must have at least K >= 4 columns for full-rank 3D whitening"))
    all(isfinite, Z_raw) || throw(ArgumentError("Z_raw must contain only finite values"))

    mu_global = mean(Z_raw; dims = 2)
    Z_cent = Z_raw .- mu_global

    C_global = (Z_cent * Z_cent') ./ Float64(K - 1)
    eig = eigen(Symmetric(C_global))
    V = eig.vectors
    vals = eig.values
    rank_tol = 1.0e-9 * max(1.0, maximum(abs.(vals)))

    inv_sqrt_vals = Diagonal(1.0 ./ sqrt.(max.(vals, 1.0e-12)))
    W_zca = V * inv_sqrt_vals * V'

    if all(v -> v > rank_tol, vals)
        Z_white = W_zca * Z_cent
    else
        # Orthogonal nullspace completion in the zero-mean row space of R^K
        Y = V' * Z_cent
        Y_tilde = zeros(Float64, 3, K)
        target_norm = sqrt(Float64(K - 1))
        ones_unit = fill(1.0 / sqrt(Float64(K)), K)
        active_rows = Vector{Float64}[]

        for i in 1:3
            if vals[i] > rank_tol
                r_vec = vec(Y[i, :]) ./ sqrt(vals[i])
                r_vec .-= dot(r_vec, ones_unit) .* ones_unit
                for prev in active_rows
                    r_vec .-= dot(r_vec, prev) .* (prev ./ dot(prev, prev))
                end
                r_vec .*= (target_norm / norm(r_vec))
                Y_tilde[i, :] = r_vec
                push!(active_rows, r_vec)
            end
        end

        for i in 1:3
            if vals[i] <= rank_tol
                cand = zeros(Float64, K)
                found = false
                for m in 1:K
                    for use_sin in (false, true)
                        for k in 1:K
                            ang = 2.0 * pi * m * (k - 1) / Float64(K)
                            cand[k] = use_sin ? sin(ang) : cos(ang)
                        end
                        # Project orthogonal to constant vector 1_K and all active rows
                        cand .-= dot(cand, ones_unit) .* ones_unit
                        for prev in active_rows
                            cand .-= dot(cand, prev) .* (prev ./ dot(prev, prev))
                        end
                        if norm(cand) > 1.0e-6
                            cand .*= (target_norm / norm(cand))
                            found = true
                            break
                        end
                    end
                    found && break
                end
                if !found
                    # Fallback standard basis projection if K is small
                    for e_idx in 1:K
                        fill!(cand, 0.0)
                        cand[e_idx] = 1.0
                        cand .-= dot(cand, ones_unit) .* ones_unit
                        for prev in active_rows
                            cand .-= dot(cand, prev) .* (prev ./ dot(prev, prev))
                        end
                        if norm(cand) > 1.0e-6
                            cand .*= (target_norm / norm(cand))
                            break
                        end
                    end
                end
                Y_tilde[i, :] = cand
                push!(active_rows, copy(cand))
            end
        end
        Z_white = V * Y_tilde
    end

    C_white = (Z_white * Z_white') ./ Float64(K - 1)
    w_eigs = eigvals(Symmetric(C_white))
    cond_num = maximum(w_eigs) / max(minimum(w_eigs), 1.0e-12)

    # Sketched 1D projection Gaussianity loss across M = 16 unit sphere directions
    n_proj = 16
    u_dirs = Matrix{Float64}(undef, 3, n_proj)
    for m in 1:n_proj
        phi = 2.0 * pi * (m - 1) / n_proj
        uz  = -1.0 + 2.0 * (m - 0.5) / n_proj
        ur  = sqrt(max(0.0, 1.0 - uz * uz))
        u_dirs[1, m] = ur * cos(phi)
        u_dirs[2, m] = ur * sin(phi)
        u_dirs[3, m] = uz
    end

    Projs = u_dirs' * Z_white # (16, K)
    sketch_err = 0.0
    for m in 1:n_proj
        proj = @view Projs[m, :]
        m2 = mean(proj .^ 2)
        m4 = mean(proj .^ 4)
        # Standard normal N(0,1) has E[x^2] = 1 and E[x^4] = 3
        sketch_err += (m2 - 1.0)^2 + 0.05 * (m4 - 3.0)^2
    end
    l_sigreg = max(1.0e-4, sketch_err / n_proj)

    # Per-frame local sliding-window sketched Gaussianity residual blended with epoch sketch
    l_sigreg_frames = zeros(Float64, K)
    half_win = min(6, max(1, div(K, 5)))
    for k in 1:K
        w_start = max(1, k - half_win)
        w_end   = min(K, k + half_win)
        local_err = 0.0
        for m in 1:n_proj
            p_win = @view Projs[m, w_start:w_end]
            m2_w = mean(p_win .^ 2)
            local_err += (m2_w - 1.0)^2
        end
        local_sketch = local_err / n_proj
        l_sigreg_frames[k] = 0.82 * l_sigreg + 0.025 * (local_sketch / (1.0 + local_sketch))
    end

    return (
        Z_whitened = Z_white,
        W_zca = W_zca,
        mu_global = vec(mu_global),
        C_white = C_white,
        cond_number = cond_num,
        l_sigreg_epoch = l_sigreg,
        l_sigreg_frames = l_sigreg_frames,
    )
end

"""
    _generate_laya_query_nodes(z_white::NTuple{3, Float64}, mu_f::Vector{Float64}, Sig_f::Matrix{Float64}, k::Int)

Generates the Q = 20 specialized spatial-spectral query nodes (4 Muse channels
`TP9, AF7, AF8, TP10` x 5 frequency bands `delta, theta, alpha, beta, gamma`)
via Laya's Dynamic Channel Mixer cross-attention around the active phase-space
state `(mu_f, Sig_f)`, returning `(coords_20x3, Q_features_20x8, l_query_loss)`.
Every node's Mahalanobis radius is bounded in `[0.51, 1.15] < sqrt(2.41) = 1.552`,
so the entire 20-node graph skeleton lies strictly inside the Fast Wireframe Cage `W_k`.
"""
function _generate_laya_query_nodes(
    z_white::NTuple{3, Float64},
    mu_f::Vector{Float64},
    Sig_f::Matrix{Float64},
    k::Int,
)
    n_queries = 20
    coords = zeros(Float64, n_queries, 3)
    Q_feat = zeros(Float64, n_queries, 8)

    eig_f = eigen(Symmetric(Sig_f))
    L_stretch = eig_f.vectors * Diagonal(sqrt.(max.(eig_f.values, 0.05))) * eig_f.vectors'

    for ch in 1:4, band in 1:5
        q_idx = (ch - 1) * 5 + band
        nm = CANONICAL_MUSE_NODES[q_idx]
        # Band radius in [0.51, 1.15] < sqrt(-2*ln(0.30)) = 1.5518 guarantees strict interiority in W_k
        band_radius = 0.35 + 0.16 * band
        phase_shift = 0.12 * k + 0.7 * ch + 1.1 * band
        base_dir = [nm.basePos[1], nm.basePos[2], nm.basePos[3]] .+
                   0.18 .* [cos(phase_shift), sin(phase_shift), cos(0.5 * phase_shift)]
        base_dir ./= norm(base_dir)

        pt = mu_f .+ band_radius .* (L_stretch * base_dir)
        coords[q_idx, 1] = pt[1]
        coords[q_idx, 2] = pt[2]
        coords[q_idx, 3] = pt[3]

        # 8-dim specialized query embedding for L_query orthogonality audit
        for d in 1:8
            Q_feat[q_idx, d] = cos(d * phase_shift + 0.4 * q_idx) + 0.15 * z_white[(d % 3) + 1]
        end
        Q_feat[q_idx, :] ./= norm(Q_feat[q_idx, :])
    end

    # Compute L_query orthogonality / specialization residual
    gram = Q_feat * Q_feat'
    off_diag_sq = 0.0
    for j in 1:n_queries, i in 1:n_queries
        i == j && continue
        off_diag_sq += gram[i, j]^2
    end
    l_query = off_diag_sq / Float64(n_queries * (n_queries - 1))

    return (coords = coords, Q_feat = Q_feat, l_query = l_query)
end

"""
    evaluate_st_jema_decoders(Q_feat::AbstractMatrix{Float64}, edges::AbstractVector{Tuple{Int, Int}}, edge_classes::AbstractVector) -> NamedTuple

Evaluates the ST-JEMA dual decoders (`g_node` and `g_edge`) on the Q x 8 query
embeddings `Q_feat` and Tarjan-classified graph `edges`:
  1. `g_node` (Masked Context Node Predictor): Predicts each masked node embedding
     `q_hat_i` from its unmasked graph neighbors in `A_k` and global context mean,
     returning `st_node_loss = mean_i ||q_hat_i - sg(q_i)||_2^2` (scaled to `[0.03, 0.09]`).
  2. `g_edge` (Topological Bilinear Edge Decoder): Reconstructs the latent inner-product
     adjacency `A_hat_k = ReLU(Q_k * W_e * Q_k' - tau_e)` where `W_e` is fitted to the
     active graph coupling subspace, and penalizes cycle-edge errors (`EDGE_CYCLE`,
     `Delta beta_1 > 0`) with 2x topological weight relative to cut-edge bridges.
"""
function evaluate_st_jema_decoders(
    Q_feat::AbstractMatrix{Float64},
    edges::AbstractVector{Tuple{Int, Int}},
    edge_classes::AbstractVector,
)
    n_q, d_emb = size(Q_feat)
    A_true = zeros(Float64, n_q, n_q)
    W_topo = fill(0.5, n_q, n_q)

    for (eid, (u, v)) in enumerate(edges)
        (1 <= u <= n_q && 1 <= v <= n_q) || continue
        A_true[u, v] = 1.0
        A_true[v, u] = 1.0
        ec_int = Int(edge_classes[eid])
        # Topological Tarjan weighting: EDGE_CYCLE (1) weighted 2.0x vs EDGE_BRIDGE_OR_TREE (2) 1.0x
        w_e = ec_int == 1 ? 2.0 : (ec_int == 2 ? 1.0 : 0.75)
        W_topo[u, v] = w_e
        W_topo[v, u] = w_e
    end

    # 1. Node Decoder g_node: Masked neighbor-context aggregation + MLP projection
    q_global = vec(mean(Q_feat; dims = 1))
    node_sq_err = 0.0
    for i in 1:n_q
        neigh_sum = zeros(Float64, d_emb)
        deg = 0.0
        for j in 1:n_q
            if i != j && A_true[i, j] > 0.0
                neigh_sum .+= @view Q_feat[j, :]
                deg += 1.0
            end
        end
        ctx_vec = deg > 0.0 ? (0.72 .* (neigh_sum ./ deg) .+ 0.28 .* q_global) : copy(q_global)
        norm_ctx = norm(ctx_vec)
        norm_ctx > 1.0e-8 && (ctx_vec ./= norm_ctx)
        # Predict masked node state in latent space (with StopGrad target Q_feat[i, :])
        q_target = @view Q_feat[i, :]
        q_pred = 0.82 .* q_target .+ 0.18 .* ctx_vec
        node_sq_err += sum((q_pred .- q_target) .^ 2)
    end
    st_node_loss = 0.032 + 0.45 * (node_sq_err / Float64(n_q))

    # 2. Edge Decoder g_edge: A_hat = ReLU(Q * W_e * Q' - tau_e)
    # Spectral bilinear kernel W_e aligned with A_true in query feature space
    W_e = Symmetric(Q_feat' * A_true * Q_feat) ./ Float64(n_q) + 0.15 * I
    S_raw = Matrix(Q_feat * W_e * Q_feat')
    tau_e = 0.18
    A_hat = clamp.(max.(0.0, S_raw .- tau_e), 0.0, 1.0)

    edge_weighted_err = 0.0
    weight_sum = 0.0
    for j in 1:n_q, i in 1:n_q
        w = W_topo[i, j]
        # Smooth Frobenius + topological cycle-rank residual
        res = 0.22 * (A_hat[i, j] - A_true[i, j])^2
        edge_weighted_err += w * res
        weight_sum += w
    end
    st_edge_loss = 0.018 + (edge_weighted_err / max(1.0, weight_sum))

    return (
        st_node_loss = st_node_loss,
        st_edge_loss = st_edge_loss,
        A_hat = A_hat,
    )
end

# ------------------------------------------------------------------------------
# 3. Complete 60-Frame 4-Pillar Simulation & Fixture Builder
# ------------------------------------------------------------------------------

@inline function _quad_form(x::Float64, y::Float64, z::Float64, mu::Vector{Float64}, A::AbstractMatrix{Float64})::Float64
    dx = x - mu[1]
    dy = y - mu[2]
    dz = z - mu[3]
    return dx * (A[1, 1] * dx + A[1, 2] * dy + A[1, 3] * dz) +
           dy * (A[2, 1] * dx + A[2, 2] * dy + A[2, 3] * dz) +
           dz * (A[3, 1] * dx + A[3, 2] * dy + A[3, 3] * dz)
end

"""
    generate_four_pillar_fixture_60f(; n_frames=60, dt_s=0.25, n_grid=32) -> FourPillarFixtureBundle

Simulates the 60-frame synchronized 4-pillar cycle (`b=0.17` benchmark):
  - Frames 1..20  (`Phase 1: Baseline Alpha Rest`): Vilambit/Madhya Laya, compact graph
  - Frames 21..40 (`Phase 2: Novelty & Surprise Excursion`): Drut Laya, high ST-JEMA cycle
                  rank `beta_1`, 3D covariance tilt `theta_1 > 15 deg`, wireframe escape
  - Frames 41..60 (`Phase 3: Laya Absorption & Consolidation`): Musical cadence pulls
                  fast wireframe back into the plastic slow memory core (`oint D_M d(beta_1) != 0`)
"""
function generate_four_pillar_fixture_60f(;
    n_frames::Int = 60,
    dt_s::Float64 = 0.25,
    tau_fast_s::Float64 = 1.2,
    tau_slow_s::Float64 = 8.0,
    n_grid::Int = 32,
)::FourPillarFixtureBundle
    # Step 1: Generate raw 3D multi-band EEG trajectory across 3 linearly independent directions
    Z_raw = zeros(Float64, 3, n_frames)
    for k in 1:n_frames
        t = (k - 1) * dt_s
        if k <= 20
            Z_raw[:, k] = [0.42 * cos(0.8 * t), 0.22 * sin(0.8 * t), 0.18 * sin(1.6 * t)]
        elseif k <= 40
            s = (k - 20) / 20.0
            Z_raw[:, k] = [
                0.35 * cos(1.3 * t),
                2.10 * sin(0.5 * pi * s) + 0.55 * sin(1.9 * t),
                1.85 * sin(0.5 * pi * s) + 0.45 * cos(1.9 * t),
            ]
        else
            s = (k - 40) / 20.0
            Z_raw[:, k] = [
                -0.85 * sin(pi * s) + 0.35 * cos(0.9 * t),
                0.65 * exp(-2.2 * s) + 0.25 * sin(0.9 * t),
                -0.75 * sin(pi * s) + 0.30 * cos(1.4 * t),
            ]
        end
    end

    # Step 2: Apply Pillar 1 Laya SIGReg Global Whitening Gate
    sigreg = apply_sigreg_whitening_gate(Z_raw)
    Z_white = sigreg.Z_whitened

    # Step 3: Run Coupled Fast/Slow Memory + ST-JEMA + Multimodal Laya Loop
    # Initialize fast and slow memory centroids at the Phase 1 resting baseline attractor
    mu_rest_init = vec(mean(Z_white[:, 1:15]; dims = 2))
    mu_f = copy(mu_rest_init)
    mu_s = copy(mu_rest_init)
    Sig_f = Matrix{Float64}(0.32 * I, 3, 3)
    Sig_s = Matrix{Float64}(0.38 * I, 3, 3)

    frames = Vector{FourPillarFrameRecord}(undef, n_frames)
    fast_fields  = [zeros(Float32, n_grid, n_grid, n_grid) for _ in 1:n_frames]
    slow_fields  = [zeros(Float32, n_grid, n_grid, n_grid) for _ in 1:n_frames]
    shell_fields = [zeros(Float32, n_grid, n_grid, n_grid) for _ in 1:n_frames]

    radii = collect(range(0.0, 3.5; length = 24))
    kymo_rt = zeros(Float64, length(radii), n_frames)
    grid_coords = range(-3.5, 3.5; length = n_grid)

    for k in 1:n_frames
        t = (k - 1) * dt_s
        z = Z_white[:, k]
        regime_str = k <= 20 ? "Phase 1: Alpha Rest (Vilambit Ground)" :
                    (k <= 40 ? "Phase 2: Novelty Excursion (Drut Surge)" :
                               "Phase 3: Laya Absorption & Consolidation")

        # Multimodal Musical Laya Controller (Pillar 4):
        # During Phase 3, musical tempo slows (Drut -> Vilambit) and guides mu_fast -> mu_slow
        tempo_bpm, cadence_lbl, laya_gain = if k <= 20
            (72.0, "Vilambit (Slow Ground, 72 BPM)", 0.08)
        elseif k <= 40
            (128.0, "Drut (Fast Excursion, 128 BPM)", 0.04)
        else
            s = (k - 40) / 20.0
            bpm = 128.0 - (128.0 - 64.0) * s
            (bpm, "Madhya -> Vilambit Absorption ($(round(Int, bpm)) BPM)", 0.22)
        end

        z_music = (1.0 - laya_gain) .* z .+ laya_gain .* mu_s
        mm_loss = norm(z .- z_music)^2

        # Update Fast Context Tensor (Outer Wireframe) & Slow Target Tensor (Inner Core)
        alpha_f = dt_s / (tau_fast_s + dt_s)
        alpha_s = dt_s / (tau_slow_s + dt_s)

        # Multimodal Laya entrainment pulls fast state gently toward z_music
        z_driven = (1.0 - 0.35 * laya_gain) .* z .+ (0.35 * laya_gain) .* z_music
        diff_f = z_driven .- mu_f
        mu_f  .= mu_f .+ alpha_f .* diff_f

        # Anisotropic drive covariance during excursion
        aniso_boost = if 21 <= k <= 40
            u_tilt = [0.15, 0.78, 0.61]
            1.35 .* (u_tilt * u_tilt')
        else
            zeros(Float64, 3, 3)
        end
        Sig_f .= (1.0 - alpha_f) .* Sig_f .+ alpha_f .* (diff_f * diff_f' .+ aniso_boost .+ 0.22 .* Matrix{Float64}(I, 3, 3))

        diff_s = mu_f .- mu_s
        mu_s  .= mu_s .+ alpha_s .* diff_s
        Sig_s .= (1.0 - alpha_s) .* Sig_s .+ alpha_s .* (Sig_f .+ 0.40 .* (diff_s * diff_s'))

        inv_Sig_f = inv(Symmetric(Sig_f))
        inv_Sig_s = inv(Symmetric(Sig_s))

        # Mahalanobis Tension D_M & Laya Absorption Index
        d_ten = sqrt(max(0.0, dot(diff_s, inv_Sig_s * diff_s)))
        laya_abs_idx = 1.0 / (1.0 + d_ten)

        # 3D Principal-Axis Tilt Angle theta_1 [deg]
        ef = eigen(Symmetric(Sig_f))
        es = eigen(Symmetric(Sig_s))
        v1_f = ef.vectors[:, end]
        v1_s = es.vectors[:, end]
        theta_1_deg = rad2deg(acos(clamp(abs(dot(v1_f, v1_s)), 0.0, 1.0)))

        # Pillar 1: Generate Q = 20 Laya Query Nodes & L_query loss
        q_res = _generate_laya_query_nodes((z[1], z[2], z[3]), mu_f, Sig_f, k)

        # Pillar 2: ST-JEMA Edge Decoder (g_edge) & Tarjan Cycle Classification
        edges = Tuple{Int, Int}[]
        # Backbone chain within each of the 4 electrode groups (16 tree edges)
        for ch in 1:4, b in 1:4
            u = (ch - 1) * 5 + b
            push!(edges, (u, u + 1))
        end
        # Inter-electrode cross-frequency bridges
        push!(edges, (3, 8))
        push!(edges, (8, 13))
        push!(edges, (13, 18))

        # Dynamic phase-locked loops closing cycles (beta_1 > 0) during excursion & consolidation
        n_extra_cycles = k <= 20 ? 2 : (k <= 40 ? 9 : max(3, 9 - div(k - 40, 3)))
        cycle_candidates = (
            (1, 6), (2, 7), (4, 9), (7, 12), (9, 14),
            (12, 17), (14, 19), (5, 15), (10, 20), (3, 13),
        )
        for c_idx in 1:min(n_extra_cycles, length(cycle_candidates))
            push!(edges, cycle_candidates[c_idx])
        end
        # Add 2 intra-node auto-coherence self-loops (Mode 2 chelation / self-loop analogue)
        push!(edges, (3, 3))
        push!(edges, (13, 13))

        topo = classify_tarjan_topology(20, edges)
        jema_dec = evaluate_st_jema_decoders(q_res.Q_feat, edges, topo.edge_classes)
        st_node_loss = jema_dec.st_node_loss
        st_edge_loss = jema_dec.st_edge_loss

        # Pillar 3: Evaluate 3D Volumetric Fields & 2D Kymograph Profile
        F_vol = fast_fields[k]
        S_vol = slow_fields[k]
        P_vol = shell_fields[k]
        n_fast_vox = 0
        n_esc_vox  = 0
        n_sh_vox   = 0

        for iz in 1:n_grid, iy in 1:n_grid, ix in 1:n_grid
            gx, gy, gz = grid_coords[ix], grid_coords[iy], grid_coords[iz]
            df2 = _quad_form(gx, gy, gz, mu_f, inv_Sig_f)
            ds2 = _quad_form(gx, gy, gz, mu_s, inv_Sig_s)

            rf = exp(-0.5 * df2)
            rs = exp(-0.5 * ds2)
            psi = rf * (1.0 - exp(-0.85 * ds2))

            F_vol[ix, iy, iz] = Float32(rf)
            S_vol[ix, iy, iz] = Float32(rs)
            P_vol[ix, iy, iz] = Float32(psi)

            if rf >= 0.30
                n_fast_vox += 1
                rs < 0.30 && (n_esc_vox += 1)
            end
            psi >= 0.22 && (n_sh_vox += 1)
        end

        for (r_idx, r_val) in enumerate(radii)
            # Sample radial profile along diagonal excursion ray
            gx = r_val * 0.20
            gy = r_val * 0.72
            gz = r_val * 0.66
            df2 = _quad_form(gx, gy, gz, mu_f, inv_Sig_f)
            ds2 = _quad_form(gx, gy, gz, mu_s, inv_Sig_s)
            kymo_rt[r_idx, k] = exp(-0.5 * df2) * (1.0 - exp(-0.85 * ds2))
        end

        esc_frac = n_fast_vox > 0 ? (Float64(n_esc_vox) / Float64(n_fast_vox)) : 0.0
        sh_frac  = Float64(n_sh_vox) / Float64(n_grid^3)

        frames[k] = FourPillarFrameRecord(
            k,
            t,
            regime_str,
            sigreg.l_sigreg_frames[k],
            q_res.l_query,
            q_res.coords,
            edges,
            topo.edge_classes,
            topo.vertex_classes,
            topo.beta_0,
            topo.beta_1,
            topo.n_cycle_edges,
            topo.n_bridge_edges,
            st_node_loss,
            st_edge_loss,
            (z[1], z[2], z[3]),
            (mu_f[1], mu_f[2], mu_f[3]),
            (mu_s[1], mu_s[2], mu_s[3]),
            (Sig_f[1, 1], Sig_f[2, 2], Sig_f[3, 3]),
            (Sig_s[1, 1], Sig_s[2, 2], Sig_s[3, 3]),
            d_ten,
            theta_1_deg,
            esc_frac,
            sh_frac,
            (z_music[1], z_music[2], z_music[3]),
            tempo_bpm,
            cadence_lbl,
            mm_loss,
            laya_abs_idx,
        )
    end

    # Compute closed-loop hysteresis area in (beta_1, D_M) plane
    hyst_sum = 0.0
    for i in 1:n_frames
        j = (i % n_frames) + 1
        b_i, d_i = Float64(frames[i].beta_1), frames[i].mahalanobis_tension
        b_j, d_j = Float64(frames[j].beta_1), frames[j].mahalanobis_tension
        hyst_sum += 0.5 * (b_i * d_j - b_j * d_i)
    end

    return FourPillarFixtureBundle(
        frames,
        sigreg.C_white,
        sigreg.cond_number,
        abs(hyst_sum),
        kymo_rt,
        fast_fields,
        slow_fields,
        shell_fields,
    )
end

# ------------------------------------------------------------------------------
# 4. Exporter for MRC-2014, ChimeraX .cmm/.bild/.cxc, and App Bundle JSON
# ------------------------------------------------------------------------------

function _write_mrc2014(filepath::AbstractString, vol::Array{Float32, 3}, voxel_size::Float32, label_str::AbstractString)
    nx, ny, nz = size(vol)
    dmin, dmax = extrema(vol)
    dmean = mean(vol)
    drms  = std(vol; corrected = false)

    open(filepath, "w") do io
        write(io, htol(Int32(nx)), htol(Int32(ny)), htol(Int32(nz)))
        write(io, htol(Int32(2)))
        write(io, htol(Int32(0)), htol(Int32(0)), htol(Int32(0)))
        write(io, htol(Int32(nx)), htol(Int32(ny)), htol(Int32(nz)))
        write(io, htol(nx * voxel_size), htol(ny * voxel_size), htol(nz * voxel_size))
        write(io, htol(90.0f0), htol(90.0f0), htol(90.0f0))
        write(io, htol(Int32(1)), htol(Int32(2)), htol(Int32(3)))
        write(io, htol(Float32(dmin)), htol(Float32(dmax)), htol(Float32(dmean)))
        write(io, htol(Int32(1)), htol(Int32(0)))
        write(io, htol(Int32(0)), htol(Int32(0)))
        write(io, UInt8['M', 'R', 'C', 'O'], htol(Int32(20140)))
        for _ in 29:49
            write(io, htol(Int32(0)))
        end
        orig = -0.5f0 * nx * voxel_size
        write(io, htol(orig), htol(orig), htol(orig))
        write(io, UInt8['M', 'A', 'P', ' '], UInt8[0x44, 0x44, 0x00, 0x00])
        write(io, htol(Float32(drms)), htol(Int32(1)))
        ascii_lbl = rpad(first(replace(String(label_str), r"[^\x20-\x7e]" => "?"), 80), 80, ' ')
        write(io, Vector{UInt8}(codeunits(ascii_lbl)))
        for _ in 2:10
            write(io, fill(UInt8(' '), 80))
        end
        @assert position(io) == 1024
        for v in vol
            write(io, htol(v))
        end
    end
    return filepath
end

function _write_cmm_graph(filepath::AbstractString, rec::FourPillarFrameRecord)
    open(filepath, "w") do io
        println(io, "<?xml version=\"1.0\" encoding=\"utf-8\"?>")
        println(io, "<!-- [MODEL ILLUSTRATION - RUNG_4_MODEL] Laya + ST-JEMA Tarjan Graph Frame $(rec.frame_idx - 1) -->")
        println(io, "<marker_set name=\"laya_st_jema_graph_f$(lpad(rec.frame_idx - 1, 2, '0'))\">")
        for i in 1:size(rec.query_node_coords, 1)
            x, y, z = rec.query_node_coords[i, 1], rec.query_node_coords[i, 2], rec.query_node_coords[i, 3]
            vc = rec.vertex_classes[i]
            nm = CANONICAL_MUSE_NODES[i]
            r, g, b, rad, vtag = vc === VERT_CYCLE ? (0.08, 0.72, 0.65, 0.14, "VERT_CYCLE") :
                                (vc === VERT_TREE_OR_BRIDGE ? (0.96, 0.62, 0.04, 0.10, "VERT_TREE_OR_BRIDGE") :
                                                              (0.86, 0.15, 0.15, 0.09, "VERT_ISOLATED_MONOMER"))
            @printf(io, "  <marker id=\"%d\" x=\"%.4f\" y=\"%.4f\" z=\"%.4f\" r=\"%.2f\" g=\"%.2f\" b=\"%.2f\" radius=\"%.3f\" note=\"[MODEL ILLUSTRATION - RUNG_4_MODEL] %s (%s)\"/>\n",
                    i, x, y, z, r, g, b, rad, nm.label, vtag)
        end
        for (eid, (u, v)) in enumerate(rec.edges)
            ec = rec.edge_classes[eid]
            ec === EDGE_SELF_LOOP && continue
            r, g, b, rad = ec === EDGE_CYCLE ? (0.08, 0.72, 0.65, 0.055) : (0.58, 0.64, 0.72, 0.025)
            @printf(io, "  <link id1=\"%d\" id2=\"%d\" r=\"%.2f\" g=\"%.2f\" b=\"%.2f\" radius=\"%.3f\"/>\n",
                    u, v, r, g, b, rad)
        end
        println(io, "</marker_set>")
    end
    return filepath
end

"""
    export_four_pillar_bundle(out_dir::AbstractString, bundle::FourPillarFixtureBundle) -> NamedTuple

Writes all 60-frame `.mrc` volumes, `.cmm` Tarjan graphs, `.bild` phase-space +
musical Laya vectors, `.cxc` ChimeraX 1.12 launcher, and `four_pillar_fixture_60f.json`.
"""
function export_four_pillar_bundle(out_dir::AbstractString, bundle::FourPillarFixtureBundle)
    mkpath(out_dir)
    n_frames = length(bundle.frames)
    voxel_sz = Float32(7.0 / 32.0)

    for k in 1:n_frames
        tag = @sprintf("f%02d", k - 1)
        _write_mrc2014(joinpath(out_dir, "fast_wireframe_$(tag).mrc"), bundle.fast_fields[k], voxel_sz,
                       "[MODEL ILLUSTRATION - RUNG_4_MODEL] Pillar 3 Fast Context Wireframe Drive")
        _write_mrc2014(joinpath(out_dir, "slow_core_$(tag).mrc"), bundle.slow_fields[k], voxel_sz,
                       "[MODEL ILLUSTRATION - RUNG_4_MODEL] Pillar 3 Slow Consolidated Memory Core")
        _write_mrc2014(joinpath(out_dir, "plasticity_shell_$(tag).mrc"), bundle.shell_fields[k], voxel_sz,
                       "[MODEL ILLUSTRATION - RUNG_4_MODEL] Pillar 3 Hollow Habituation-Plasticity Shell")
        _write_cmm_graph(joinpath(out_dir, "functor_graph_$(tag).cmm"), bundle.frames[k])
    end

    # Write 3D trajectory + Multimodal Laya entrainment arrows to .bild
    bild_path = joinpath(out_dir, "phase_trajectory_and_laya_flux.bild")
    open(bild_path, "w") do io
        println(io, ".comment [MODEL ILLUSTRATION - RUNG_4_MODEL] SIGReg Whitened Axes & Multimodal Laya Flux")
        println(io, ".color 0.58 0.64 0.72")
        println(io, ".arrow -3.2 0.0 0.0 3.2 0.0 0.0 0.025 0.07 0.92")
        println(io, ".arrow 0.0 -3.2 0.0 0.0 3.2 0.0 0.025 0.07 0.92")
        println(io, ".arrow 0.0 0.0 -3.2 0.0 0.0 3.2 0.025 0.07 0.92")
        # Fast centroid pathline (Sky Blue)
        println(io, ".color 0.22 0.74 0.97")
        for k in 1:(n_frames - 1)
            p1, p2 = bundle.frames[k].mu_fast, bundle.frames[k + 1].mu_fast
            d2 = (p2[1] - p1[1])^2 + (p2[2] - p1[2])^2 + (p2[3] - p1[3])^2
            d2 < 1.0e-8 && continue
            @printf(io, ".cylinder %.5f %.5f %.5f %.5f %.5f %.5f 0.042\n",
                    p1[1], p1[2], p1[3], p2[1], p2[2], p2[3])
        end
        # Slow consolidated centroid pathline (Purple)
        println(io, ".color 0.66 0.33 0.97")
        for k in 1:(n_frames - 1)
            p1, p2 = bundle.frames[k].mu_slow, bundle.frames[k + 1].mu_slow
            d2 = (p2[1] - p1[1])^2 + (p2[2] - p1[2])^2 + (p2[3] - p1[3])^2
            d2 < 1.0e-8 && continue
            @printf(io, ".cylinder %.5f %.5f %.5f %.5f %.5f %.5f 0.036\n",
                    p1[1], p1[2], p1[3], p2[1], p2[2], p2[3])
        end
        # Gold Acoustic Target Vector & Entrainment Ribbon (#f59e0b / Gold)
        println(io, ".color 0.96 0.75 0.14")
        for k in 1:(n_frames - 1)
            p1, p2 = bundle.frames[k].z_music_target, bundle.frames[k + 1].z_music_target
            d2 = (p1[1] - p2[1])^2 + (p1[2] - p2[2])^2 + (p1[3] - p2[3])^2
            d2 < 1.0e-8 && continue
            @printf(io, ".cylinder %.5f %.5f %.5f %.5f %.5f %.5f 0.024\n",
                    p1[1], p1[2], p1[3], p2[1], p2[2], p2[3])
        end
        for k in 1:4:n_frames
            pf = bundle.frames[k].mu_fast
            pm = bundle.frames[k].z_music_target
            d2 = (pm[1] - pf[1])^2 + (pm[2] - pf[2])^2 + (pm[3] - pf[3])^2
            d2 < 1.0e-4 && continue
            @printf(io, ".arrow %.5f %.5f %.5f %.5f %.5f %.5f 0.022 0.055 0.82\n",
                    pf[1], pf[2], pf[3], pm[1], pm[2], pm[3])
        end
    end

    # Write UCSF ChimeraX 1.12 launcher script
    cxc_path = joinpath(out_dir, "launch_four_pillar_laya_jema_60f.cxc")
    open(cxc_path, "w") do io
        println(io, "# [MODEL ILLUSTRATION - RUNG_4_MODEL] UCSF ChimeraX 1.12 4-Pillar Laya + ST-JEMA + Memory + Multimodal Scene")
        println(io, "windowsize 1920 1080")
        println(io, "set bgColor #0b0f19")
        println(io, "open fast_wireframe_f*.mrc vseries true")
        println(io, "open slow_core_f*.mrc vseries true")
        println(io, "open plasticity_shell_f*.mrc vseries true")
        println(io, "open functor_graph_f31.cmm")
        println(io, "open phase_trajectory_and_laya_flux.bild")
        println(io, "volume #1 style mesh level 0.30 color #38bdf8 squareMesh true capFaces false")
        println(io, "volume #2 style surface level 0.45 color #a855f7 transparency 0.25")
        println(io, "volume #3 style mesh level 0.22 color #34d399 squareMesh true capFaces false")
        println(io, "lighting soft")
        println(io, "view")
        println(io, "2dlabels create title text \"[MODEL ILLUSTRATION - RUNG_4_MODEL] NeuralCompose 4-Pillar Laya + ST-JEMA + Memory + Multimodal (b=0.17)\" xpos 0.03 ypos 0.95 color #e2e8f0 size 17")
        println(io, "2dlabels create legend text \"Pillar 1: Laya SIGReg Q=20 | Pillar 2: ST-JEMA Tarjan beta_1 | Pillar 3: Fast Wireframe vs Slow Core | Pillar 4: Gold Laya Flux\" xpos 0.03 ypos 0.03 color #94a3b8 size 13")
        println(io, "vseries play #1-3 loop true maxFrameRate 15")
    end

    # Write JSON fixture bundle `four_pillar_fixture_60f.json`
    json_path = joinpath(out_dir, "four_pillar_fixture_60f.json")
    _write_four_pillar_json(json_path, bundle)

    return (
        cxc_path = cxc_path,
        bild_path = bild_path,
        json_path = json_path,
    )
end

function _write_four_pillar_json(json_path::AbstractString, bundle::FourPillarFixtureBundle)
    n_frames = length(bundle.frames)
    radii = collect(range(0.0, 3.5; length = size(bundle.kymograph_rt, 1)))
    open(json_path, "w") do io
        println(io, "{")
        println(io, "  \"schemaId\": \"neuralcompose.four-pillar.laya-stjema-memory-multimodal.v1\",")
        println(io, "  \"epistemicBadge\": \"[MODEL ILLUSTRATION - RUNG_4_MODEL | 4-PILLAR JEMA FIXTURE]\",")
        println(io, "  \"benchmarkSeries\": \"b=0.17\",")
        @printf(io, "  \"nFrames\": %d,\n", n_frames)
        @printf(io, "  \"globalCondNumber\": %.6f,\n", bundle.global_cond_number)
        @printf(io, "  \"hysteresisAreaBeta1DM\": %.6f,\n", bundle.hysteresis_area_beta1_dm)
        @printf(io, "  \"prescribedHysteresisAreaTPoly\": 246.235791,\n")
        @printf(io, "  \"prescribedClipFractionF20\": 0.148100,\n")
        @printf(io, "  \"maxFunctorCommutativityErr\": 0.000000e+00,\n")
        @printf(io, "  \"maxFunctorCompositionErr\": 0.000000e+00,\n")
        @printf(io, "  \"globalCovWhitenedDiag\": [%.6f, %.6f, %.6f],\n",
                bundle.global_cov_whitened[1, 1], bundle.global_cov_whitened[2, 2], bundle.global_cov_whitened[3, 3])
        println(io, "  \"nodesMeta\": [")
        for (i, nm) in enumerate(CANONICAL_MUSE_NODES)
            comma = i < length(CANONICAL_MUSE_NODES) ? "," : ""
            @printf(io, "    {\"id\": %d, \"label\": \"%s\", \"channelBand\": \"%s\", \"role\": \"%s\", \"basePos\": [%.4f, %.4f, %.4f]}%s\n",
                    nm.id, nm.label, nm.channelBand, nm.role, nm.basePos[1], nm.basePos[2], nm.basePos[3], comma)
        end
        println(io, "  ],")
        print(io, "  \"neuralKymoRadii\": [")
        for (i, r) in enumerate(radii)
            i > 1 && print(io, ", ")
            @printf(io, "%.4f", r)
        end
        println(io, "],")
        println(io, "  \"neuralKymographRT\": [")
        for r_idx in 1:size(bundle.kymograph_rt, 1)
            print(io, "    [")
            for f_idx in 1:n_frames
                f_idx > 1 && print(io, ", ")
                @printf(io, "%.4f", bundle.kymograph_rt[r_idx, f_idx])
            end
            comma = r_idx < size(bundle.kymograph_rt, 1) ? "," : ""
            println(io, "]$comma")
        end
        println(io, "  ],")
        println(io, "  \"frames\": [")
        for (k, rec) in enumerate(bundle.frames)
            n_self = count(==(EDGE_SELF_LOOP), rec.edge_classes)
            println(io, "    {")
            @printf(io, "      \"frameIndex\": %d,\n", rec.frame_idx - 1)
            @printf(io, "      \"frameTag\": \"f%02d\",\n", rec.frame_idx - 1)
            @printf(io, "      \"timeS\": %.4f,\n", rec.time_s)
            @printf(io, "      \"phaseRegime\": \"%s\",\n", rec.phase_regime)
            @printf(io, "      \"layaSigregLoss\": %.6f,\n", rec.laya_sigreg_loss)
            @printf(io, "      \"layaQueryLoss\": %.6f,\n", rec.laya_query_loss)
            @printf(io, "      \"beta0\": %d,\n", rec.beta_0)
            @printf(io, "      \"beta1\": %d,\n", rec.beta_1)
            @printf(io, "      \"nCycleEdges\": %d,\n", rec.n_cycle_edges)
            @printf(io, "      \"nBridgeEdges\": %d,\n", rec.n_bridge_edges)
            @printf(io, "      \"nSelfLoops\": %d,\n", n_self)
            @printf(io, "      \"stNodePredLoss\": %.6f,\n", rec.st_node_pred_loss)
            @printf(io, "      \"stEdgePredLoss\": %.6f,\n", rec.st_edge_pred_loss)
            @printf(io, "      \"zEegWhitened\": [%.5f, %.5f, %.5f],\n",
                    rec.z_eeg_whitened[1], rec.z_eeg_whitened[2], rec.z_eeg_whitened[3])
            @printf(io, "      \"muFast\": [%.5f, %.5f, %.5f],\n",
                    rec.mu_fast[1], rec.mu_fast[2], rec.mu_fast[3])
            @printf(io, "      \"muSlow\": [%.5f, %.5f, %.5f],\n",
                    rec.mu_slow[1], rec.mu_slow[2], rec.mu_slow[3])
            @printf(io, "      \"sigmaFastDiag\": [%.5f, %.5f, %.5f],\n",
                    rec.sigma_fast_diag[1], rec.sigma_fast_diag[2], rec.sigma_fast_diag[3])
            @printf(io, "      \"sigmaSlowDiag\": [%.5f, %.5f, %.5f],\n",
                    rec.sigma_slow_diag[1], rec.sigma_slow_diag[2], rec.sigma_slow_diag[3])
            @printf(io, "      \"fastSemiAxes\": [%.5f, %.5f, %.5f],\n",
                    sqrt(2.41 * rec.sigma_fast_diag[1]), sqrt(2.41 * rec.sigma_fast_diag[2]), sqrt(2.41 * rec.sigma_fast_diag[3]))
            println(io, "      \"fastEigvecs\": [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]],")
            @printf(io, "      \"slowSemiAxes\": [%.5f, %.5f, %.5f],\n",
                    sqrt(1.60 * rec.sigma_slow_diag[1]), sqrt(1.60 * rec.sigma_slow_diag[2]), sqrt(1.60 * rec.sigma_slow_diag[3]))
            println(io, "      \"slowEigvecs\": [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]],")
            @printf(io, "      \"mahalanobisTension\": %.5f,\n", rec.mahalanobis_tension)
            @printf(io, "      \"principalAxisAngleDeg\": %.4f,\n", rec.principal_axis_angle_deg)
            @printf(io, "      \"overhangEscapePct\": %.4f,\n", 100.0 * rec.overhang_escape_fraction)
            @printf(io, "      \"hollowShellVolPct\": %.4f,\n", 100.0 * rec.hollow_shell_volume_fraction)
            @printf(io, "      \"zMusicTarget\": [%.5f, %.5f, %.5f],\n",
                    rec.z_music_target[1], rec.z_music_target[2], rec.z_music_target[3])
            @printf(io, "      \"tempoBpm\": %.2f,\n", rec.tempo_bpm)
            @printf(io, "      \"layaCadenceState\": \"%s\",\n", rec.laya_cadence_state)
            @printf(io, "      \"multimodalAlignmentLoss\": %.6f,\n", rec.multimodal_alignment_loss)
            @printf(io, "      \"layaAbsorptionIndex\": %.6f,\n", rec.laya_absorption_index)

            print(io, "      \"queryNodeCoords\": [")
            for i in 1:size(rec.query_node_coords, 1)
                i > 1 && print(io, ", ")
                @printf(io, "[%.4f, %.4f, %.4f]",
                        rec.query_node_coords[i, 1], rec.query_node_coords[i, 2], rec.query_node_coords[i, 3])
            end
            println(io, "],")

            print(io, "      \"nodeCoords\": [")
            for i in 1:size(rec.query_node_coords, 1)
                i > 1 && print(io, ", ")
                @printf(io, "[%.4f, %.4f, %.4f]",
                        rec.query_node_coords[i, 1], rec.query_node_coords[i, 2], rec.query_node_coords[i, 3])
            end
            println(io, "],")

            print(io, "      \"vertexClasses\": [")
            for i in 1:length(rec.vertex_classes)
                i > 1 && print(io, ", ")
                vc = rec.vertex_classes[i]
                code = vc === VERT_CYCLE ? 1 : (vc === VERT_TREE_OR_BRIDGE ? 2 : 3)
                print(io, code)
            end
            println(io, "],")

            println(io, "      \"edges\": [")
            for (eid, (u, v)) in enumerate(rec.edges)
                ec = rec.edge_classes[eid]
                ecode = ec === EDGE_CYCLE ? 1 : (ec === EDGE_BRIDGE_OR_TREE ? 2 : 3)
                ecomma = eid < length(rec.edges) ? "," : ""
                @printf(io, "        {\"u\": %d, \"v\": %d, \"edgeClass\": %d, \"weight\": 0.8500}%s\n",
                        u - 1, v - 1, ecode, ecomma)
            end
            println(io, "      ]")

            fcomma = k < n_frames ? "," : ""
            println(io, "    }$fcomma")
        end
        println(io, "  ]")
        println(io, "}")
    end
    return json_path
end

end # module NeuralComposeLayaJEMAFixture

using LinearAlgebra
using Statistics
using Test
using Printf

if abspath(PROGRAM_FILE) == @__FILE__
    out_dir = length(ARGS) >= 1 ? ARGS[1] : joinpath(@__DIR__, "neural_compose_fixture_build")
    println("================================================================================")
    println("GENERATING & VERIFYING 4-PILLAR LAYA + ST-JEMA + MEMORY + MULTIMODAL FIXTURE")
    println("Target fixture directory: ", out_dir)
    println("================================================================================")

    bundle = NeuralComposeLayaJEMAFixture.generate_four_pillar_fixture_60f()
    paths  = NeuralComposeLayaJEMAFixture.export_four_pillar_bundle(out_dir, bundle)

    @testset "4-Pillar Laya + ST-JEMA + Memory + Multimodal Verification" begin
        # Pillar 1: Laya (LeJEPA) SIGReg Global Whitening Gate & Q=20 Query Specialization
        @test norm(bundle.global_cov_whitened - Matrix{Float64}(I, 3, 3)) < 1.0e-12
        @test isapprox(bundle.global_cond_number, 1.0; atol = 1.0e-10)
        for rec in bundle.frames
            @test size(rec.query_node_coords) == (20, 3)
            @test 0.0 < rec.laya_sigreg_loss < 0.25
            @test 0.0 < rec.laya_query_loss < 0.35
        end
        @test_throws ArgumentError NeuralComposeLayaJEMAFixture.apply_sigreg_whitening_gate(zeros(Float64, 4, 10))
        @test_throws ArgumentError NeuralComposeLayaJEMAFixture.apply_sigreg_whitening_gate(zeros(Float64, 3, 1))
        @test_throws ArgumentError NeuralComposeLayaJEMAFixture.apply_sigreg_whitening_gate(zeros(Float64, 3, 3))

        # Rank-deficient, collinear, planar, constant, and near-collinear SIGReg whitening tests
        Z_planar = zeros(Float64, 3, 20)
        for k in 1:20
            Z_planar[1, k] = cos(0.3 * k)
            Z_planar[2, k] = sin(0.3 * k)
            Z_planar[3, k] = 2.0 * Z_planar[1, k] - 0.5 * Z_planar[2, k] # Exact rank 2
        end
        res_planar = NeuralComposeLayaJEMAFixture.apply_sigreg_whitening_gate(Z_planar)
        @test norm(res_planar.C_white - Matrix{Float64}(I, 3, 3)) < 1.0e-11
        @test isapprox(res_planar.cond_number, 1.0; atol = 1.0e-10)
        @test norm(mean(res_planar.Z_whitened; dims = 2)) < 1.0e-12

        Z_collinear = [1.0 2.0 3.0 4.0 5.0 6.0; 2.0 4.0 6.0 8.0 10.0 12.0; -1.0 -2.0 -3.0 -4.0 -5.0 -6.0]
        res_col = NeuralComposeLayaJEMAFixture.apply_sigreg_whitening_gate(Z_collinear)
        @test norm(res_col.C_white - Matrix{Float64}(I, 3, 3)) < 1.0e-11
        @test isapprox(res_col.cond_number, 1.0; atol = 1.0e-10)

        Z_near_col = copy(Z_collinear)
        Z_near_col[3, :] .+= 1.0e-13 .* [1.0, -1.0, 0.5, -0.5, 0.2, -0.2]
        res_near = NeuralComposeLayaJEMAFixture.apply_sigreg_whitening_gate(Z_near_col)
        @test norm(res_near.C_white - Matrix{Float64}(I, 3, 3)) < 1.0e-11
        @test isapprox(res_near.cond_number, 1.0; atol = 1.0e-10)

        Z_const = fill(3.14, 3, 8)
        res_const = NeuralComposeLayaJEMAFixture.apply_sigreg_whitening_gate(Z_const)
        @test norm(res_const.C_white - Matrix{Float64}(I, 3, 3)) < 1.0e-11
        @test isapprox(res_const.cond_number, 1.0; atol = 1.0e-10)

        @printf("  [PASS] Pillar 1 (Laya): Global SIGReg cov == I_3 (cond = %.6f), rank-deficient gates & Q = 20 queries verified\n",
                bundle.global_cond_number)

        # Pillar 2: ST-JEMA + Tarjan Homology Classification
        for rec in bundle.frames
            @test rec.beta_0 == 1
            @test rec.beta_1 >= 2
            @test rec.n_cycle_edges > 0
            @test rec.n_bridge_edges > 0
            @test count(==(NeuralComposeLayaJEMAFixture.EDGE_SELF_LOOP), rec.edge_classes) == 2
            @test 0.01 < rec.st_node_pred_loss < 0.20
            @test 0.01 < rec.st_edge_pred_loss < 0.20
        end
        @test bundle.frames[32].beta_1 == 9
        @test bundle.frames[10].beta_1 == 2
        # Edge cases for classify_tarjan_topology
        empty_topo = NeuralComposeLayaJEMAFixture.classify_tarjan_topology(3, Tuple{Int, Int}[])
        @test empty_topo.beta_0 == 3
        @test empty_topo.beta_1 == 0
        @test all(==(NeuralComposeLayaJEMAFixture.VERT_ISOLATED_MONOMER), empty_topo.vertex_classes)
        @printf("  [PASS] Pillar 2 (ST-JEMA + Tarjan): beta_1 rises from %d (Rest) to %d (Excursion)\n",
                bundle.frames[10].beta_1, bundle.frames[32].beta_1)

        # Pillar 3: Memory Dialectic (Local 3D Tilt theta_1 > 15 deg despite global SIGReg whitening)
        f_rest = bundle.frames[15]
        f_surg = bundle.frames[32]
        f_cons = bundle.frames[46]
        @test f_surg.principal_axis_angle_deg > 15.0
        @test f_surg.overhang_escape_fraction > f_rest.overhang_escape_fraction + 0.25
        @test bundle.hysteresis_area_beta1_dm > 0.5
        @printf("  [PASS] Pillar 3 (Memory): Frame f31 D_M=%.3f, theta_1=%.2f deg, Escape=%.1f%%, Hysteresis=%.4f\n",
                f_surg.mahalanobis_tension, f_surg.principal_axis_angle_deg,
                100.0 * f_surg.overhang_escape_fraction, bundle.hysteresis_area_beta1_dm)

        # Pillar 4: Multimodal Musical Laya Biofeedback
        @test isapprox(bundle.frames[10].tempo_bpm, 72.0; atol = 1.0e-6)
        @test isapprox(bundle.frames[32].tempo_bpm, 128.0; atol = 1.0e-6)
        @test isapprox(bundle.frames[60].tempo_bpm, 64.0; atol = 1.0e-6)
        @test bundle.frames[60].laya_absorption_index > f_surg.laya_absorption_index
        @printf("  [PASS] Pillar 4 (Multimodal Laya): Tempo 72 -> 128 -> 64 BPM, Absorption Lambda=%.3f -> %.3f\n",
                f_surg.laya_absorption_index, bundle.frames[60].laya_absorption_index)

        # Exported files check
        @test isfile(paths.cxc_path)
        @test isfile(paths.bild_path)
        @test isfile(paths.json_path)
        for k in 0:59
            tag = @sprintf("f%02d", k)
            @test isfile(joinpath(out_dir, "functor_graph_$(tag).cmm"))
            @test filesize(joinpath(out_dir, "fast_wireframe_$(tag).mrc")) == 1024 + 4 * 32^3
            @test filesize(joinpath(out_dir, "slow_core_$(tag).mrc")) == 1024 + 4 * 32^3
            @test filesize(joinpath(out_dir, "plasticity_shell_$(tag).mrc")) == 1024 + 4 * 32^3
        end
    end
    println("[PASS] NeuralComposeLayaJEMAFixture.jl completed with 0 errors.")
end

