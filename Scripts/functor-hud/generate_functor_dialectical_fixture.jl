#!/usr/bin/env julia
# ==============================================================================
# generate_functor_dialectical_fixture.jl
# 4-Pillar Category-Theoretic Functor Network Graph & 3D Dialectical Phase-Hull
# Fixture Generator for NeuralCompose (60 frames: f00..f59, b=0.17 benchmark).
#
# Integrates the 4-Stage Composed Functor F = F_MM o F_Mem o F_ST o F_Laya:
#   1. Pillar 1 (Laya / LeJEPA Front-End): Dynamic Channel Mixer expanding 4 Muse
#      electrodes (TP9, AF7, AF8, TP10) x 5 bands (delta, theta, alpha, beta, gamma)
#      into Q = 20 specialized query nodes with L_query orthogonality loss + Global
#      ZCA SIGReg Whitening Gate (Sigma_global == I_3, kappa == 1.00).
#   2. Pillar 2 (ST-JEMA + Tarjan Homology): Dual Node & Edge Decoders (g_node,
#      g_edge) with iterative Tarjan bridge-finding (EDGE_CYCLE vs EDGE_BRIDGE_OR_TREE
#      vs EDGE_SELF_LOOP) tracking Betti numbers (beta_0, beta_1).
#   3. Pillar 3 (Memory Dialectic): Coupled Fast Context Wireframe Cage W_k
#      (tau_f = 1.2s) vs Slow Consolidated Memory Core C_k (tau_s = 8.0s) + Hollow
#      Habituation-Plasticity Shell Psi_k inside the SIGReg-whitened 3D phase space.
#   4. Pillar 4 (Multimodal Musical Laya): Cross-modal acoustic cadence alignment
#      (Vilambit -> Drut -> Madhya/Vilambit Laya) guiding fast wireframe absorption
#      back into the consolidated slow core.
#
# Epistemic Boundary: [MODEL ILLUSTRATION - RUNG_4_MODEL]
# Dependencies: Julia Base, LinearAlgebra, Statistics, Printf, Test stdlibs only,
# plus local ExportChimeraX.jl, KymographAndNeuralComposeHull.jl, and
# NeuralComposeLayaJEMAFixture.jl.
# Strictly zero em-dashes and zero en-dashes.
# ==============================================================================

module FunctorDialecticalFixture

using LinearAlgebra
using Statistics
using Printf
using Test

include(joinpath(@__DIR__, "ExportChimeraX.jl"))
using .ExportChimeraX

include(joinpath(@__DIR__, "KymographAndNeuralComposeHull.jl"))
using .KymographAndNeuralComposeHull

include(joinpath(@__DIR__, "NeuralComposeLayaJEMAFixture.jl"))
using .NeuralComposeLayaJEMAFixture: apply_sigreg_whitening_gate, evaluate_st_jema_decoders

export NetGraphObject, NetGraphMorphism, PhaseHullObject, PhaseHullMorphism
export FunctorFrameRecord, FunctorFixtureBundle
export functor_map_object, functor_map_morphism, apply_netgraph_morphism, apply_phasehull_morphism
export compose_netgraph_morphisms, compose_phasehull_morphisms
export build_functor_dialectical_fixture_60f, export_functor_fixture_assets

# ------------------------------------------------------------------------------
# 1. Domain Category: NetGraph (Q = 20 Specialized Laya Query Nodes & Morphisms)
# ------------------------------------------------------------------------------

struct NetGraphNodeMeta
    id::Int
    label::String
    channel_band::String
    role::String
    base_pos::NTuple{3, Float64}
end

const CANONICAL_NODES = [
    # Channel 1: TP9 (Left temporo-parietal) x 5 bands
    NetGraphNodeMeta(1,  "TP9_delta",  "TP9 (delta 1-4Hz)",    "coherenceSeeking",    (-1.45, -0.85, -0.75)),
    NetGraphNodeMeta(2,  "TP9_theta",  "TP9 (theta 4-8Hz)",    "coherenceSeeking",    (-1.55, -0.35, -0.45)),
    NetGraphNodeMeta(3,  "TP9_alpha",  "TP9 (alpha 8-12Hz)",   "coherenceSeeking",    (-1.35,  0.10, -0.10)),
    NetGraphNodeMeta(4,  "TP9_beta",   "TP9 (beta 13-30Hz)",   "displacementSeeking", (-1.15,  0.65,  0.45)),
    NetGraphNodeMeta(5,  "TP9_gamma",  "TP9 (gamma 30-45Hz)",  "displacementSeeking", (-0.95,  1.15,  0.95)),
    # Channel 2: AF7 (Left anterior-frontal) x 5 bands
    NetGraphNodeMeta(6,  "AF7_delta",  "AF7 (delta 1-4Hz)",    "coherenceSeeking",    (-0.55, -0.75, -0.60)),
    NetGraphNodeMeta(7,  "AF7_theta",  "AF7 (theta 4-8Hz)",    "coherenceSeeking",    (-0.65, -0.20, -0.15)),
    NetGraphNodeMeta(8,  "AF7_alpha",  "AF7 (alpha 8-12Hz)",   "coherenceSeeking",    (-0.60,  0.30,  0.25)),
    NetGraphNodeMeta(9,  "AF7_beta",   "AF7 (beta 13-30Hz)",   "displacementSeeking", (-0.50,  0.85,  0.70)),
    NetGraphNodeMeta(10, "AF7_gamma",  "AF7 (gamma 30-45Hz)",  "displacementSeeking", (-0.35,  1.35,  1.15)),
    # Channel 3: AF8 (Right anterior-frontal) x 5 bands
    NetGraphNodeMeta(11, "AF8_delta",  "AF8 (delta 1-4Hz)",    "coherenceSeeking",    ( 0.55, -0.75, -0.60)),
    NetGraphNodeMeta(12, "AF8_theta",  "AF8 (theta 4-8Hz)",    "coherenceSeeking",    ( 0.65, -0.20, -0.15)),
    NetGraphNodeMeta(13, "AF8_alpha",  "AF8 (alpha 8-12Hz)",   "synthesis",           ( 0.60,  0.30,  0.25)),
    NetGraphNodeMeta(14, "AF8_beta",   "AF8 (beta 13-30Hz)",   "displacementSeeking", ( 0.50,  0.85,  0.70)),
    NetGraphNodeMeta(15, "AF8_gamma",  "AF8 (gamma 30-45Hz)",  "displacementSeeking", ( 0.35,  1.35,  1.15)),
    # Channel 4: TP10 (Right temporo-parietal) x 5 bands
    NetGraphNodeMeta(16, "TP10_delta", "TP10 (delta 1-4Hz)",   "coherenceSeeking",    ( 1.45, -0.85, -0.75)),
    NetGraphNodeMeta(17, "TP10_theta", "TP10 (theta 4-8Hz)",   "coherenceSeeking",    ( 1.55, -0.35, -0.45)),
    NetGraphNodeMeta(18, "TP10_alpha", "TP10 (alpha 8-12Hz)",  "synthesis",           ( 1.35,  0.10, -0.10)),
    NetGraphNodeMeta(19, "TP10_beta",  "TP10 (beta 13-30Hz)",  "displacementSeeking", ( 1.15,  0.65,  0.45)),
    NetGraphNodeMeta(20, "TP10_gamma", "TP10 (gamma 30-45Hz)", "witness",             ( 0.95,  1.15,  0.95)),
]

struct NetGraphObject
    frame_idx::Int
    time_s::Float64
    node_coords::Matrix{Float64}             # (20, 3) coordinates in whitened R^3
    edges::Vector{Tuple{Int, Int}}           # 1-indexed edge list (includes self-loops)
    edge_weights::Vector{Float64}            # PLV/PAC coupling weights in [0, 1]
    topo::NetworkTopologyClassification      # Tarjan bridge/cycle classification
    beta_0::Int                              # Connected components count
    beta_1::Int                              # First Betti number (homological cycle rank)
    z_drive::Vector{Float64}                 # SIGReg-whitened 3D phase-space drive vector
    S_drive::Matrix{Float64}                 # Graph-induced 3x3 spectral dispersion tensor
    mu_fast_state::Vector{Float64}           # Internal fast moment state carried on graph
    Sig_fast_state::Matrix{Float64}
    mu_slow_state::Vector{Float64}           # Internal slow moment state carried on graph
    Sig_slow_state::Matrix{Float64}
end

struct NetGraphMorphism
    src_frame::Int
    dst_frame::Int
    alpha_fast::Float64
    alpha_slow::Float64
    delta_beta_0::Int
    delta_beta_1::Int
    target_z_drive::Vector{Float64}
    target_S_drive::Matrix{Float64}
    # Exact affine transport representation for arbitrary morphism composition:
    # mu_f'  = A_f * mu_f + b_f
    # Sig_f' = A_f * Sig_f + B_f
    # mu_s'  = A_s * mu_s + C_s * mu_f + b_s
    # Sig_s' = A_s * Sig_s + C_s * Sig_f + B_s
    A_f::Float64
    b_f::Vector{Float64}
    B_f::Matrix{Float64}
    A_s::Float64
    C_s::Float64
    b_s::Vector{Float64}
    B_s::Matrix{Float64}
    dst_node_coords::Matrix{Float64}
    dst_edges::Vector{Tuple{Int, Int}}
    dst_edge_weights::Vector{Float64}
    dst_topo::NetworkTopologyClassification
    dst_beta_0::Int
    dst_beta_1::Int
end

# ------------------------------------------------------------------------------
# 2. Codomain Category: PhaseHull (Objects H_k and Transport Morphisms M_{k->k+1})
# ------------------------------------------------------------------------------

struct PhaseHullObject
    frame_idx::Int
    time_s::Float64
    mu_fast::Vector{Float64}
    Sigma_fast::Matrix{Float64}
    mu_slow::Vector{Float64}
    Sigma_slow::Matrix{Float64}
    beta_0::Int
    beta_1::Int
end

struct PhaseHullMorphism
    src_frame::Int
    dst_frame::Int
    delta_beta_0::Int
    delta_beta_1::Int
    A_f::Float64
    b_f::Vector{Float64}
    B_f::Matrix{Float64}
    A_s::Float64
    C_s::Float64
    b_s::Vector{Float64}
    B_s::Matrix{Float64}
    dst_time_s::Float64
end

"""
    functor_map_object(G::NetGraphObject) -> PhaseHullObject

Object map of the Functor `F: NetGraph -> PhaseHull`.
Extracts the 3D phase-space manifold state `(mu_fast, Sigma_fast, mu_slow, Sigma_slow)`
and homological invariants `(beta_0, beta_1)` from `G_k`.
"""
function functor_map_object(G::NetGraphObject)::PhaseHullObject
    return PhaseHullObject(
        G.frame_idx,
        G.time_s,
        copy(G.mu_fast_state),
        copy(G.Sig_fast_state),
        copy(G.mu_slow_state),
        copy(G.Sig_slow_state),
        G.beta_0,
        G.beta_1,
    )
end

"""
    functor_map_morphism(T::NetGraphMorphism; dst_time_s::Float64 = 0.0) -> PhaseHullMorphism

Morphism map of the Functor `F: NetGraph -> PhaseHull`.
Maps a graph transition morphism `T_{k->k+1}` to the corresponding covariance
transport operator `M_{k->k+1} = F(T_{k->k+1})` in `PhaseHull`.
"""
function functor_map_morphism(T::NetGraphMorphism; dst_time_s::Float64 = 0.25 * (T.dst_frame - 1))::PhaseHullMorphism
    return PhaseHullMorphism(
        T.src_frame,
        T.dst_frame,
        T.delta_beta_0,
        T.delta_beta_1,
        T.A_f,
        copy(T.b_f),
        copy(T.B_f),
        T.A_s,
        T.C_s,
        copy(T.b_s),
        copy(T.B_s),
        dst_time_s,
    )
end

"""
    apply_netgraph_morphism(T::NetGraphMorphism, G::NetGraphObject) -> NetGraphObject

Applies morphism `T_{k->k+1}` to `G_k` in category `NetGraph`.
"""
function apply_netgraph_morphism(T::NetGraphMorphism, G::NetGraphObject)::NetGraphObject
    G.frame_idx == T.src_frame || throw(ArgumentError("Domain mismatch: G.frame_idx=$(G.frame_idx) != T.src_frame=$(T.src_frame)"))
    mu_f_next  = T.A_f .* G.mu_fast_state .+ T.b_f
    Sig_f_next = T.A_f .* G.Sig_fast_state .+ T.B_f
    mu_s_next  = T.A_s .* G.mu_slow_state .+ T.C_s .* G.mu_fast_state .+ T.b_s
    Sig_s_next = T.A_s .* G.Sig_slow_state .+ T.C_s .* G.Sig_fast_state .+ T.B_s

    return NetGraphObject(
        T.dst_frame,
        0.25 * (T.dst_frame - 1),
        copy(T.dst_node_coords),
        copy(T.dst_edges),
        copy(T.dst_edge_weights),
        T.dst_topo,
        G.beta_0 + T.delta_beta_0,
        G.beta_1 + T.delta_beta_1,
        copy(T.target_z_drive),
        copy(T.target_S_drive),
        mu_f_next,
        Sig_f_next,
        mu_s_next,
        Sig_s_next,
    )
end

"""
    apply_phasehull_morphism(M::PhaseHullMorphism, H::PhaseHullObject) -> PhaseHullObject

Applies transport morphism `M_{k->k+1}` to `H_k` in category `PhaseHull`.
"""
function apply_phasehull_morphism(M::PhaseHullMorphism, H::PhaseHullObject)::PhaseHullObject
    H.frame_idx == M.src_frame || throw(ArgumentError("Domain mismatch: H.frame_idx=$(H.frame_idx) != M.src_frame=$(M.src_frame)"))
    mu_f_next  = M.A_f .* H.mu_fast .+ M.b_f
    Sig_f_next = M.A_f .* H.Sigma_fast .+ M.B_f
    mu_s_next  = M.A_s .* H.mu_slow .+ M.C_s .* H.mu_fast .+ M.b_s
    Sig_s_next = M.A_s .* H.Sigma_slow .+ M.C_s .* H.Sigma_fast .+ M.B_s

    return PhaseHullObject(
        M.dst_frame,
        M.dst_time_s,
        mu_f_next,
        Sig_f_next,
        mu_s_next,
        Sig_s_next,
        H.beta_0 + M.delta_beta_0,
        H.beta_1 + M.delta_beta_1,
    )
end

"""
    compose_netgraph_morphisms(T2::NetGraphMorphism, T1::NetGraphMorphism) -> NetGraphMorphism

Composes `T2 o T1` in `NetGraph` where `T1: G_k -> G_m` and `T2: G_m -> G_n`.
"""
function compose_netgraph_morphisms(T2::NetGraphMorphism, T1::NetGraphMorphism)::NetGraphMorphism
    T1.dst_frame == T2.src_frame || throw(ArgumentError("Non-composable NetGraph morphisms"))
    A_f = T2.A_f * T1.A_f
    b_f = T2.A_f .* T1.b_f .+ T2.b_f
    B_f = T2.A_f .* T1.B_f .+ T2.B_f

    A_s = T2.A_s * T1.A_s
    C_s = T2.A_s * T1.C_s + T2.C_s * T1.A_f
    b_s = T2.A_s .* T1.b_s .+ T2.C_s .* T1.b_f .+ T2.b_s
    B_s = T2.A_s .* T1.B_s .+ T2.C_s .* T1.B_f .+ T2.B_s

    return NetGraphMorphism(
        T1.src_frame,
        T2.dst_frame,
        1.0 - A_f,
        1.0 - A_s,
        T1.delta_beta_0 + T2.delta_beta_0,
        T1.delta_beta_1 + T2.delta_beta_1,
        copy(T2.target_z_drive),
        copy(T2.target_S_drive),
        A_f,
        b_f,
        B_f,
        A_s,
        C_s,
        b_s,
        B_s,
        copy(T2.dst_node_coords),
        copy(T2.dst_edges),
        copy(T2.dst_edge_weights),
        T2.dst_topo,
        T2.dst_beta_0,
        T2.dst_beta_1,
    )
end

"""
    compose_phasehull_morphisms(M2::PhaseHullMorphism, M1::PhaseHullMorphism) -> PhaseHullMorphism

Composes `M2 o M1` in `PhaseHull` where `M1: H_k -> H_m` and `M2: H_m -> H_n`.
"""
function compose_phasehull_morphisms(M2::PhaseHullMorphism, M1::PhaseHullMorphism)::PhaseHullMorphism
    M1.dst_frame == M2.src_frame || throw(ArgumentError("Non-composable PhaseHull morphisms"))
    A_f = M2.A_f * M1.A_f
    b_f = M2.A_f .* M1.b_f .+ M2.b_f
    B_f = M2.A_f .* M1.B_f .+ M2.B_f

    A_s = M2.A_s * M1.A_s
    C_s = M2.A_s * M1.C_s + M2.C_s * M1.A_f
    b_s = M2.A_s .* M1.b_s .+ M2.C_s .* M1.b_f .+ M2.b_s
    B_s = M2.A_s .* M1.B_s .+ M2.C_s .* M1.B_f .+ M2.B_s

    return PhaseHullMorphism(
        M1.src_frame,
        M2.dst_frame,
        M1.delta_beta_0 + M2.delta_beta_0,
        M1.delta_beta_1 + M2.delta_beta_1,
        A_f,
        b_f,
        B_f,
        A_s,
        C_s,
        b_s,
        B_s,
        M2.dst_time_s,
    )
end

# ------------------------------------------------------------------------------
# 3. Homology & Laya Query Specialization Helpers
# ------------------------------------------------------------------------------

function _compute_betti_numbers(n_vertices::Int, edges::Vector{Tuple{Int, Int}})::Tuple{Int, Int}
    parent = collect(1:n_vertices)
    function find_root(x::Int)
        while parent[x] != x
            parent[x] = parent[parent[x]]
            x = parent[x]
        end
        return x
    end

    simple_edges = Set{Tuple{Int, Int}}()
    for (u, v) in edges
        u == v && continue
        a, b = u < v ? (u, v) : (v, u)
        push!(simple_edges, (a, b))
        ra, rb = find_root(a), find_root(b)
        if ra != rb
            parent[ra] = rb
        end
    end

    roots = Set{Int}()
    for i in 1:n_vertices
        push!(roots, find_root(i))
    end
    beta_0 = length(roots)
    e_simple = length(simple_edges)
    beta_1 = e_simple - n_vertices + beta_0
    return (beta_0, beta_1)
end

function _compute_laya_query_loss(z_white::Vector{Float64}, k::Int, n_queries::Int = 20)
    Q_feat = zeros(Float64, n_queries, 8)
    for ch in 1:4, band in 1:5
        q_idx = (ch - 1) * 5 + band
        phase_shift = 0.12 * k + 0.7 * ch + 1.1 * band
        for d in 1:8
            Q_feat[q_idx, d] = cos(d * phase_shift + 0.4 * q_idx) + 0.15 * z_white[(d % 3) + 1]
        end
        Q_feat[q_idx, :] ./= norm(Q_feat[q_idx, :])
    end
    gram = Q_feat * Q_feat'
    off_diag_sq = 0.0
    for j in 1:n_queries, i in 1:n_queries
        i == j && continue
        off_diag_sq += gram[i, j]^2
    end
    l_query = off_diag_sq / Float64(n_queries * (n_queries - 1))
    return (Q_feat = Q_feat, l_query = l_query)
end

# ------------------------------------------------------------------------------
# 4. Construct the 60-Frame Coupled 4-Pillar Functor Network & Phase-Hull Series
# ------------------------------------------------------------------------------

struct FunctorFrameRecord
    frame_idx::Int                        # 1..60 (f00..f59)
    frame_tag::String                     # "f00".."f59"
    time_s::Float64
    phase_regime::String
    # Pillar 1: Laya (LeJEPA) Front-End Metrics
    laya_sigreg_loss::Float64
    laya_query_loss::Float64
    # Pillar 2: ST-JEMA + Tarjan Homology Metrics
    beta_0::Int
    beta_1::Int
    n_cycle_edges::Int
    n_bridge_edges::Int
    n_self_loops::Int
    st_node_pred_loss::Float64
    st_edge_pred_loss::Float64
    # Pillar 3: Memory Dialectic (Fast Wireframe vs Slow Core + Hollow Shell)
    mahalanobis_tension::Float64
    principal_axis_angle_deg::Float64
    overhang_escape_fraction::Float64
    hollow_shell_volume_fraction::Float64
    fast_eigvals::NTuple{3, Float64}
    fast_eigvecs::Matrix{Float64}         # 3x3 columns are eigenvectors
    slow_eigvals::NTuple{3, Float64}
    slow_eigvecs::Matrix{Float64}
    dialectic_coherence::Float64
    dialectic_resonance::Float64
    dialectic_novelty::Float64
    dialectic_potential::Float64
    selection_temperature::Float64
    dialectic_outcome::String
    functor_commutativity_err::Float64
    # Pillar 4: Multimodal Musical Laya Biofeedback
    z_music_target::NTuple{3, Float64}
    tempo_bpm::Float64
    laya_cadence_state::String
    multimodal_alignment_loss::Float64
    laya_absorption_index::Float64
    # Fractal 1/f Spectral Geometry (WorldModel/synthetic_1f.py & RESEARCH_spectral_geometry.md)
    fractal_exponent_chi::Float64         # Aperiodic 1/f^chi exponent in [0.85, 1.70]
    aperiodic_offset_log10::Float64       # Broadband log10 offset
    alpha_theta_ratio::Float64            # alpha / (alpha + theta) atmosphere uniform
    # Client-Native Phase-Space & Takens Delay Attractor (neuralcompose-viz + NeuralWorkspaceView)
    takens_delay_ribbon::Matrix{Float64}  # (24, 3) [V(t+2*tau), V(t), V(t+tau)], tau=16 samples (62.5 ms)
    takens_color_tp10::Vector{Float64}    # (24,) normalized TP10(t+2*tau) color in [0, 1]
    cross_channel_pt::NTuple{4, Float64}  # (AF7, AF8, TP9, TP10) cross-channel state
    concept_nodes_shell::Matrix{Float64}  # (8, 4) [x, y, z, brightness] with 0.985^dk decay
end

struct FunctorFixtureBundle
    n_frames::Int
    nodes_meta::Vector{NetGraphNodeMeta}
    graph_objects::Vector{NetGraphObject}
    graph_morphisms::Vector{NetGraphMorphism}
    hull_objects::Vector{PhaseHullObject}
    hull_morphisms::Vector{PhaseHullMorphism}
    records::Vector{FunctorFrameRecord}
    fast_fields::Vector{Array{Float32, 3}}
    slow_fields::Vector{Array{Float32, 3}}
    shell_fields::Vector{Array{Float32, 3}}
    neural_kymograph_rt::Matrix{Float64}      # (24, 60) radial plasticity shell profile
    neural_kymo_radii::Vector{Float64}
    fractal_1f_kymograph_ft::Matrix{Float64}  # (24, 60) 1/f^chi + oscillatory bumps log-power spectrum
    fractal_kymo_freqs_hz::Vector{Float64}    # (24,) frequencies in [1.0, 45.0] Hz
    prescribed_audit::PrescribedCycleAudit    # Part A R0 comparison kymograph + clipping audit
    hysteresis_area_beta1_DM::Float64         # Closed-loop area |oint D_M d(beta_1)|
    max_functor_commutativity_err::Float64
    max_functor_composition_err::Float64
    global_cov_whitened::Matrix{Float64}      # Pillar 1 SIGReg global whitened covariance (== I_3)
    global_cond_number::Float64               # Pillar 1 global condition number (== 1.00)
end

"""
    _build_frame_edges_and_weights(k::Int, t::Float64) -> Tuple{Vector{Tuple{Int, Int}}, Vector{Float64}}

Constructs the dynamic 20-node multiplex 1-skeleton edges `E_k` and PLV/PAC
weights `w_k` for frame `k in 1..60` across the 4 Muse channels x 5 bands:
  - 2 intra-node auto-coherence self-loops on `TP9_alpha` (3) and `AF8_alpha` (13).
  - 16 within-electrode cross-frequency PAC chain edges + 3 inter-electrode alpha
    backbone bridges = 19 tree edges spanning all 20 nodes (`beta_0 == 1`).
  - Dynamic phase-locked loop recruitment closing 2..9 cycles (`beta_1` in `[2..9]`),
    rising during Phase 2 Novelty Excursion and exhibiting reverberatory memory
    in Phase 3 Consolidation before pruning back to 2.
"""
function _build_frame_edges_and_weights(k::Int, t::Float64)
    edges = Tuple{Int, Int}[]
    weights = Float64[]

    function add_edge!(u::Int, v::Int, w::Float64)
        push!(edges, (u, v))
        push!(weights, clamp(w, 0.10, 0.99))
    end

    # 2 Self-loops (intra-node auto-coherence on TP9_alpha=3 and AF8_alpha=13)
    add_edge!(3, 3, 0.86 + 0.08 * cos(0.5 * t))
    add_edge!(13, 13, 0.82 + 0.09 * sin(0.6 * t))

    # Within-electrode cross-frequency chain (4 electrodes x 4 links = 16 edges)
    for ch in 1:4, b in 1:4
        u = (ch - 1) * 5 + b
        add_edge!(u, u + 1, 0.74 + 0.04 * b)
    end

    # Inter-electrode alpha backbone bridges connecting the 4 electrodes (3 edges -> 19 spanning tree edges)
    add_edge!(3, 8, 0.84)
    add_edge!(8, 13, 0.86)
    add_edge!(13, 18, 0.83)

    # 2 Persistent baseline theta-alpha cycles (contributes +2 to beta_1 in all frames -> beta_1 >= 2)
    add_edge!(2, 7, 0.80)   # Closes cycle (2 - 3 - 8 - 7 - 2)
    add_edge!(12, 17, 0.79) # Closes cycle (12 - 13 - 18 - 17 - 12)

    # Dynamic loop recruitment across the 60-frame cycle (creating hysteretic beta_1 in [2..9])
    # Loops recruit during Phase 2 peak tension (k = 24..38) and reverberate in Phase 3
    # (k = 41..48) while D_M absorbs, then prune at low D_M (k = 49..59).
    loop_level = if k <= 23
        0
    elseif k <= 26
        1
    elseif k <= 28
        2
    elseif k <= 30
        4
    elseif k <= 33
        5
    elseif k <= 48
        6 # Peak cycle rank beta_1 = 9 persists through early/mid consolidation!
    elseif k <= 51
        5
    elseif k <= 53
        4
    elseif k <= 55
        2
    elseif k <= 57
        1
    else
        0
    end

    if loop_level >= 1
        add_edge!(7, 12, 0.78)  # Inter-hemispheric frontal theta loop (+1 -> beta_1 = 3)
    end
    if loop_level >= 2
        add_edge!(1, 6, 0.76)   # Left temporo-frontal delta loop (+1 -> beta_1 = 4)
    end
    if loop_level >= 3
        add_edge!(11, 16, 0.77) # Right fronto-temporal delta loop (+1 -> beta_1 = 5)
    end
    if loop_level >= 4
        add_edge!(4, 9, 0.85)   # Left fronto-temporal beta binding (+1 -> beta_1 = 6)
    end
    if loop_level >= 5
        add_edge!(9, 14, 0.88)  # Bi-frontal beta phase lock (+1 -> beta_1 = 7)
        add_edge!(14, 19, 0.84) # Right fronto-temporal beta lock (+1 -> beta_1 = 8)
    end
    if loop_level >= 6
        add_edge!(5, 10, 0.91)  # Left gamma burst binding (+1 -> beta_1 = 9; node 20 stays a cut-edge bridge!)
    end

    return (edges, weights)
end

function build_functor_dialectical_fixture_60f(;
    n_frames::Int = 60,
    dt_s::Float64 = 0.25,
    tau_fast_s::Float64 = 1.2,
    tau_slow_s::Float64 = 8.0,
    n_grid::Int = 32,
)::FunctorFixtureBundle
    n_verts = length(CANONICAL_NODES)
    alpha_f = dt_s / (tau_fast_s + dt_s)
    alpha_s = dt_s / (tau_slow_s + dt_s)

    graph_objects   = Vector{NetGraphObject}(undef, n_frames)
    hull_objects    = Vector{PhaseHullObject}(undef, n_frames)
    records         = Vector{FunctorFrameRecord}(undef, n_frames)
    fast_fields     = [zeros(Float32, n_grid, n_grid, n_grid) for _ in 1:n_frames]
    slow_fields     = [zeros(Float32, n_grid, n_grid, n_grid) for _ in 1:n_frames]
    shell_fields    = [zeros(Float32, n_grid, n_grid, n_grid) for _ in 1:n_frames]

    kymo_radii      = collect(range(0.0, 3.4; length = 24))
    neural_kymo_rt  = zeros(Float64, length(kymo_radii), n_frames)
    fractal_freqs   = [1.0 * (45.0 / 1.0)^((i - 1) / 23.0) for i in 1:24]
    fractal_kymo_ft = zeros(Float64, length(fractal_freqs), n_frames)
    grid_coords     = range(-3.5, 3.5; length = n_grid)

    # Step 1: Build raw 3D multi-band trajectory and apply Pillar 1 Laya SIGReg Whitening Gate
    Z_raw = zeros(Float64, 3, n_frames)
    for k in 1:n_frames
        t = (k - 1) * dt_s
        if k <= 20
            Z_raw[:, k] = [0.16 * cos(0.8 * t), 0.12 * sin(0.8 * t), 0.10 * sin(1.6 * t)]
        elseif k <= 40
            s = (k - 20) / 20.0
            Z_raw[:, k] = [
                1.75 * sin(pi * s) + 0.25 * cos(1.3 * t),
                2.25 * sin(0.5 * pi * s) + 0.35 * sin(1.8 * t),
                1.95 * sin(0.5 * pi * s) - 0.65 * cos(pi * s) + 0.25 * cos(1.8 * t),
            ]
        else
            s = (k - 40) / 20.0
            decay = exp(-3.2 * s)
            Z_raw[:, k] = [
                0.35 * decay * cos(0.9 * t) + 0.08 * cos(0.8 * t),
                0.85 * decay + 0.08 * sin(0.9 * t),
                0.75 * decay + 0.08 * sin(1.4 * t),
            ]
        end
    end

    sigreg = apply_sigreg_whitening_gate(Z_raw)
    Z_white = sigreg.Z_whitened

    # Initialize moment states at k = 1 at the Phase 1 resting attractor
    mu_rest_init = vec(mean(Z_white[:, 1:15]; dims = 2))
    mu_f  = copy(mu_rest_init)
    mu_s  = copy(mu_rest_init)
    Sig_f = Matrix{Float64}(Diagonal([0.52, 0.24, 0.20]))
    Sig_s = Matrix{Float64}(Diagonal([0.55, 0.26, 0.22]))

    # Step 2: Build 20-node coordinates, edges, Tarjan topology, and graph drives per frame
    raw_coords  = Vector{Matrix{Float64}}(undef, n_frames)
    raw_edges   = Vector{Vector{Tuple{Int, Int}}}(undef, n_frames)
    raw_weights = Vector{Vector{Float64}}(undef, n_frames)
    raw_topos   = Vector{NetworkTopologyClassification}(undef, n_frames)
    raw_beta0   = zeros(Int, n_frames)
    raw_beta1   = zeros(Int, n_frames)
    raw_z_drive = Vector{Vector{Float64}}(undef, n_frames)
    raw_S_drive = Vector{Matrix{Float64}}(undef, n_frames)

    mu_f_track  = copy(mu_f)
    Sig_f_track = copy(Sig_f)

    for k in 1:n_frames
        t = (k - 1) * dt_s
        edges, weights = _build_frame_edges_and_weights(k, t)
        topo = classify_network_topology(n_verts, edges)
        b0, b1 = _compute_betti_numbers(n_verts, edges)

        z_eeg = Z_white[:, k]
        # Couple Pillar 4 Multimodal Musical Laya cadence into Phase 3 consolidation drive
        z = if k > 40
            s_laya = (k - 40) / 20.0
            gain_pull = 0.22 * s_laya
            (1.0 - gain_pull) .* z_eeg .+ gain_pull .* mu_rest_init
        else
            copy(z_eeg)
        end

        raw_edges[k]   = edges
        raw_weights[k] = weights
        raw_topos[k]   = topo
        raw_beta0[k]   = b0
        raw_beta1[k]   = b1
        raw_z_drive[k] = z

        # Local window dispersion tensor: anisotropic excursion tilt during Phase 2
        aniso_excursion = if 21 <= k <= 40
            u_tilt = [0.15, 0.78, 0.61]
            1.45 .* (u_tilt * u_tilt')
        else
            zeros(Float64, 3, 3)
        end
        dz_rest = z .- mu_rest_init
        raw_S_drive[k] = 0.45 .* (dz_rest * dz_rest') .+ aniso_excursion .+
                         Matrix{Float64}(Diagonal([0.36 + 0.01 * b1, 0.18 + 0.015 * b1, 0.16 + 0.015 * b1]))

        # Advance tracked fast ellipsoid state so all Q = 20 query nodes are embedded
        # strictly inside the active Fast Context Wireframe Cage W_k (rho_fast >= 0.30)
        mu_f_track  .= (1.0 - alpha_f) .* mu_f_track .+ alpha_f .* raw_z_drive[k]
        Sig_f_track .= (1.0 - alpha_f) .* Sig_f_track .+ alpha_f .* raw_S_drive[k]
        ef_k = eigen(Symmetric(Sig_f_track))
        L_stretch = ef_k.vectors * Diagonal(sqrt.(max.(ef_k.values, 1.0e-4))) * ef_k.vectors'

        coords = zeros(Float64, n_verts, 3)
        for (i, nm) in enumerate(CANONICAL_NODES)
            band = ((i - 1) % 5) + 1
            vclass = topo.vertex_classes[i]
            cyc_mod = vclass === VERT_CYCLE ? 0.06 : (vclass === VERT_TREE_OR_BRIDGE ? 0.0 : -0.04)
            # Band shell radius in Mahalanobis units: strictly < sqrt(2.41) = 1.552
            band_radius = 0.35 + 0.16 * band + cyc_mod + 0.03 * sin(0.9 * t + 0.45 * i)
            base_vec = [nm.base_pos[1], nm.base_pos[2], nm.base_pos[3]]
            base_dir = base_vec ./ max(norm(base_vec), 1.0e-6)
            pt = mu_f_track .+ band_radius .* (L_stretch * base_dir)
            coords[i, 1] = pt[1]
            coords[i, 2] = pt[2]
            coords[i, 3] = pt[3]
        end
        raw_coords[k] = coords
    end

    # Initialize Frame 1 NetGraphObject and PhaseHullObject
    z1 = raw_z_drive[1]
    diff_f1 = z1 .- mu_f
    mu_f  .= mu_f .+ alpha_f .* diff_f1
    Sig_f .= (1.0 - alpha_f) .* Sig_f .+ alpha_f .* raw_S_drive[1]
    diff_s1 = mu_f .- mu_s
    mu_s  .= mu_s .+ alpha_s .* diff_s1
    Sig_s .= (1.0 - alpha_s) .* Sig_s .+ alpha_s .* Sig_f

    graph_objects[1] = NetGraphObject(
        1, 0.0, raw_coords[1], raw_edges[1], raw_weights[1], raw_topos[1],
        raw_beta0[1], raw_beta1[1], raw_z_drive[1], raw_S_drive[1],
        copy(mu_f), copy(Sig_f), copy(mu_s), copy(Sig_s),
    )
    hull_objects[1] = functor_map_object(graph_objects[1])

    graph_morphisms = Vector{NetGraphMorphism}(undef, n_frames - 1)
    hull_morphisms  = Vector{PhaseHullMorphism}(undef, n_frames - 1)

    A_f = 1.0 - alpha_f
    A_s = 1.0 - alpha_s
    C_s = alpha_s

    for k in 1:(n_frames - 1)
        z_next = raw_z_drive[k + 1]
        S_next = raw_S_drive[k + 1]
        b_f = alpha_f .* z_next
        B_f = alpha_f .* S_next
        b_s = zeros(Float64, 3)
        B_s = zeros(Float64, 3, 3)

        T_k = NetGraphMorphism(
            k,
            k + 1,
            alpha_f,
            alpha_s,
            raw_beta0[k + 1] - raw_beta0[k],
            raw_beta1[k + 1] - raw_beta1[k],
            z_next,
            S_next,
            A_f,
            b_f,
            B_f,
            A_s,
            C_s,
            b_s,
            B_s,
            raw_coords[k + 1],
            raw_edges[k + 1],
            raw_weights[k + 1],
            raw_topos[k + 1],
            raw_beta0[k + 1],
            raw_beta1[k + 1],
        )
        M_k = functor_map_morphism(T_k; dst_time_s = k * dt_s)

        graph_morphisms[k] = T_k
        hull_morphisms[k]  = M_k

        # Advance via morphism in NetGraph
        graph_objects[k + 1] = apply_netgraph_morphism(T_k, graph_objects[k])
        # Map via Functor F
        hull_objects[k + 1]  = functor_map_object(graph_objects[k + 1])
    end

    # Verify Functorial Commutativity and compute 3D volumes + 4-Pillar invariants per frame
    max_comm_err = 0.0
    for k in 1:n_frames
        G_k = graph_objects[k]
        H_k = hull_objects[k]

        comm_err = 0.0
        if k > 1
            H_via_transport = apply_phasehull_morphism(hull_morphisms[k - 1], hull_objects[k - 1])
            err_muf  = maximum(abs.(H_k.mu_fast .- H_via_transport.mu_fast))
            err_sigf = maximum(abs.(H_k.Sigma_fast .- H_via_transport.Sigma_fast))
            err_mus  = maximum(abs.(H_k.mu_slow .- H_via_transport.mu_slow))
            err_sigs = maximum(abs.(H_k.Sigma_slow .- H_via_transport.Sigma_slow))
            err_b    = Float64(abs(H_k.beta_0 - H_via_transport.beta_0) + abs(H_k.beta_1 - H_via_transport.beta_1))
            comm_err = max(err_muf, err_sigf, err_mus, err_sigs, err_b)
            comm_err > max_comm_err && (max_comm_err = comm_err)
        end

        inv_Sig_f = inv(Symmetric(H_k.Sigma_fast))
        inv_Sig_s = inv(Symmetric(H_k.Sigma_slow))

        diff_s = H_k.mu_fast .- H_k.mu_slow
        d_ten = sqrt(max(0.0, dot(diff_s, inv_Sig_s * diff_s)))

        ef = eigen(Symmetric(H_k.Sigma_fast))
        es = eigen(Symmetric(H_k.Sigma_slow))
        v1_f = ef.vectors[:, end]
        v1_s = es.vectors[:, end]
        cos_ang = clamp(abs(dot(v1_f, v1_s)), 0.0, 1.0)
        ang_deg = rad2deg(acos(cos_ang))

        # Evaluate 32^3 density grids
        n_fast_vox   = 0
        n_escape_vox = 0
        n_shell_vox  = 0
        F_vol = fast_fields[k]
        S_vol = slow_fields[k]
        P_vol = shell_fields[k]

        for iz in 1:n_grid, iy in 1:n_grid, ix in 1:n_grid
            pt = (grid_coords[ix], grid_coords[iy], grid_coords[iz])
            df2 = _quad_form3(pt, H_k.mu_fast, inv_Sig_f)
            ds2 = _quad_form3(pt, H_k.mu_slow, inv_Sig_s)

            rho_fast  = exp(-0.5 * df2)
            rho_slow  = exp(-0.5 * ds2)
            psi_shell = rho_fast * (1.0 - exp(-0.8 * ds2))

            F_vol[ix, iy, iz] = Float32(rho_fast)
            S_vol[ix, iy, iz] = Float32(rho_slow)
            P_vol[ix, iy, iz] = Float32(psi_shell)

            if rho_fast >= 0.30
                n_fast_vox += 1
                rho_slow < 0.30 && (n_escape_vox += 1)
            end
            psi_shell >= 0.22 && (n_shell_vox += 1)
        end

        # Fill 2D radial kymograph along direction of excursion from slow centroid
        dir_vec = norm(diff_s) > 1.0e-4 ? (diff_s ./ norm(diff_s)) : [0.0, 1.0, 0.0]
        for (r_idx, r_val) in enumerate(kymo_radii)
            pt_r = (
                H_k.mu_slow[1] + r_val * dir_vec[1],
                H_k.mu_slow[2] + r_val * dir_vec[2],
                H_k.mu_slow[3] + r_val * dir_vec[3],
            )
            df2 = _quad_form3(pt_r, H_k.mu_fast, inv_Sig_f)
            ds2 = _quad_form3(pt_r, H_k.mu_slow, inv_Sig_s)
            neural_kymo_rt[r_idx, k] = exp(-0.5 * df2) * (1.0 - exp(-0.8 * ds2))
        end

        escape_frac = n_fast_vox > 0 ? (Float64(n_escape_vox) / Float64(n_fast_vox)) : 0.0
        shell_frac  = Float64(n_shell_vox) / Float64(n_grid^3)

        # Pillar 1: Laya SIGReg & Query Specialization Metrics (from sliding-window sketched 1D projections)
        laya_sigreg_loss = sigreg.l_sigreg_frames[k]
        q_res            = _compute_laya_query_loss(G_k.z_drive, k, n_verts)
        laya_query_loss  = q_res.l_query

        # Pillar 2: ST-JEMA Node & Edge Prediction Losses via g_node and g_edge decoders
        dec_losses   = evaluate_st_jema_decoders(q_res.Q_feat, G_k.edges, G_k.topo.edge_classes)
        st_node_loss = dec_losses.st_node_loss
        st_edge_loss = dec_losses.st_edge_loss

        # Pillar 4: Multimodal Musical Laya Controller
        tempo_bpm, cadence_lbl, laya_gain = if k <= 20
            (72.0, "Vilambit (Slow Ground, 72 BPM)", 0.28)
        elseif k <= 40
            (128.0, "Drut (Fast Excursion, 128 BPM)", 0.12)
        else
            s = (k - 40) / 20.0
            bpm = 128.0 - (128.0 - 64.0) * s
            (bpm, "Madhya -> Vilambit ($(round(Int, bpm)) BPM)", 0.65)
        end
        z_music = (1.0 - laya_gain) .* H_k.mu_fast .+ laya_gain .* H_k.mu_slow
        mm_loss = norm(G_k.z_drive .- z_music)^2
        laya_abs_idx = 1.0 / (1.0 + d_ten)

        # 1/f Fractal Spectral Slope chi(t) & specparam periodic/aperiodic decomposition
        # (WorldModel/synthetic_1f.py & RESEARCH_spectral_geometry.md + neuralcompose-viz alpha/(alpha+theta))
        chi_k, offset_k, alpha_theta_k = if k <= 20
            (1.60 + 0.04 * cos(0.5 * G_k.time_s), 1.42, 0.73 + 0.04 * cos(0.6 * G_k.time_s))
        elseif k <= 40
            s_ex = (k - 20) / 20.0
            (1.60 - 0.66 * sin(pi * s_ex), 1.18 + 0.22 * (1.0 - sin(pi * s_ex)), 0.72 - 0.38 * sin(pi * s_ex))
        else
            s_ab = (k - 40) / 20.0
            (1.16 + 0.46 * s_ab, 1.24 + 0.18 * s_ab, 0.44 + 0.31 * s_ab)
        end

        for (f_idx, freq_hz) in enumerate(fractal_freqs)
            log_f = log10(freq_hz)
            aperiodic_logp = offset_k - chi_k * log_f
            # Periodic oscillatory bumps in log-freq space (theta 6Hz, alpha 10Hz, beta/gamma 22-36Hz)
            bump_theta = 0.28 * (1.0 - alpha_theta_k) * exp(-0.5 * ((log_f - log10(6.0)) / 0.11)^2)
            bump_alpha = 0.52 * alpha_theta_k * exp(-0.5 * ((log_f - log10(10.0)) / 0.10)^2)
            bump_beta  = (21 <= k <= 42 ? 0.44 : 0.14) * exp(-0.5 * ((log_f - log10(24.0)) / 0.14)^2)
            fractal_kymo_ft[f_idx, k] = clamp(aperiodic_logp + bump_theta + bump_alpha + bump_beta, 0.0, 2.2)
        end

        # Client-Native Phase-Space & Takens Delay-Coordinate Attractor
        # (neuralcompose-client-native/crates/neuralcompose-viz/src/signal.rs:
        #  X = V(t + 2*tau), Y = V(t), Z = V(t + tau), Color = TP10(t + 2*tau), tau = 16 samples / 62.5 ms)
        n_takens = 24
        takens_ribbon = zeros(Float64, n_takens, 3)
        takens_tp10   = zeros(Float64, n_takens)
        tau_s = 16.0 / 256.0  # 0.0625 s (62.5 ms delay at 256 Hz)
        omega_dom = 2.0 * pi * (k <= 20 ? 10.0 : (k <= 40 ? 18.0 : 9.5))
        amp_takens = 0.38 + 0.16 * d_ten

        for idx_t in 1:n_takens
            t_sub = G_k.time_s + (idx_t - 1) * (0.35 / n_takens)
            v_t0   = amp_takens * (0.72 * sin(omega_dom * t_sub) + 0.28 * cos(0.5 * omega_dom * t_sub + 0.3 * k))
            v_tau1 = amp_takens * (0.72 * sin(omega_dom * (t_sub + tau_s)) + 0.28 * cos(0.5 * omega_dom * (t_sub + tau_s) + 0.3 * k))
            v_tau2 = amp_takens * (0.72 * sin(omega_dom * (t_sub + 2.0 * tau_s)) + 0.28 * cos(0.5 * omega_dom * (t_sub + 2.0 * tau_s) + 0.3 * k))
            # Center the Takens delay attractor ribbon around mu_fast in SIGReg-whitened R^3
            takens_ribbon[idx_t, 1] = H_k.mu_fast[1] + v_tau2
            takens_ribbon[idx_t, 2] = H_k.mu_fast[2] + v_t0
            takens_ribbon[idx_t, 3] = H_k.mu_fast[3] + v_tau1
            takens_tp10[idx_t] = clamp(0.5 + 0.45 * sin(omega_dom * (t_sub + 2.0 * tau_s) + 0.8), 0.05, 0.98)
        end

        cross_ch = (
            H_k.mu_fast[1] + 0.22 * cos(0.9 * G_k.time_s),
            H_k.mu_fast[2] + 0.22 * sin(0.9 * G_k.time_s),
            H_k.mu_fast[3] + 0.18 * cos(1.4 * G_k.time_s),
            takens_tp10[end],
        )

        # Stage 1c/1d ConceptNode Shell (NeuralCompose/Sources/BCIEEG/NeuralWorkspaceView.swift:
        # spoken dialectic concept spheres on outer shell with multiplicative brightness decay 0.985^dk)
        n_concepts = 8
        concept_shell = zeros(Float64, n_concepts, 4)
        shell_rad = 1.92
        for c_idx in 1:n_concepts
            birth_frame = mod1(k - (c_idx - 1) * 5, 60)
            age_frames  = mod(k - birth_frame + 60, 60)
            brightness  = clamp(0.985^age_frames, 0.18, 1.0)
            golden_phi  = acos(1.0 - 2.0 * (c_idx - 0.5) / n_concepts)
            golden_th   = pi * (1.0 + sqrt(5.0)) * c_idx + 0.04 * k
            concept_shell[c_idx, 1] = H_k.mu_slow[1] + shell_rad * sin(golden_phi) * cos(golden_th)
            concept_shell[c_idx, 2] = H_k.mu_slow[2] + shell_rad * cos(golden_phi)
            concept_shell[c_idx, 3] = H_k.mu_slow[3] + shell_rad * sin(golden_phi) * sin(golden_th)
            concept_shell[c_idx, 4] = brightness
        end

        # NeuralCompose DialecticalDynamics scoring state coupled to the frame
        coh = clamp(0.85 - 0.18 * d_ten + 0.03 * G_k.beta_1, 0.10, 0.98)
        res = clamp(0.55 + 0.05 * G_k.beta_1 - 0.08 * escape_frac, 0.10, 0.98)
        nov = clamp(0.25 + 0.28 * d_ten + 0.30 * escape_frac, 0.10, 0.99)
        pot = 1.0 * coh + 0.6 * res + 0.8 * nov
        norm_ten = clamp(d_ten / 3.2, 0.0, 1.0)
        tau_sel = max(0.12, 0.50 - 0.35 * norm_ten)

        outcome_str = if G_k.beta_1 >= 7 && norm_ten >= 0.45
            "synthesized:synthesis"
        elseif k <= 20
            "spoke:coherenceSeeking"
        elseif k <= 40
            "spoke:displacementSeeking"
        else
            "synthesized:synthesis"
        end

        regime_str = k <= 20 ? "Phase 1: Alpha Rest (Vilambit Ground)" :
                    (k <= 40 ? "Phase 2: Novelty Excursion (Drut Surge)" :
                               "Phase 3: Laya Absorption & Consolidation")

        records[k] = FunctorFrameRecord(
            k,
            @sprintf("f%02d", k - 1),
            G_k.time_s,
            regime_str,
            laya_sigreg_loss,
            laya_query_loss,
            G_k.beta_0,
            G_k.beta_1,
            G_k.topo.n_cycle_edges,
            G_k.topo.n_bridge_edges,
            G_k.topo.n_self_loops,
            st_node_loss,
            st_edge_loss,
            d_ten,
            ang_deg,
            escape_frac,
            shell_frac,
            (max(1e-4, ef.values[1]), max(1e-4, ef.values[2]), max(1e-4, ef.values[3])),
            ef.vectors,
            (max(1e-4, es.values[1]), max(1e-4, es.values[2]), max(1e-4, es.values[3])),
            es.vectors,
            coh,
            res,
            nov,
            pot,
            tau_sel,
            outcome_str,
            comm_err,
            (z_music[1], z_music[2], z_music[3]),
            tempo_bpm,
            cadence_lbl,
            mm_loss,
            laya_abs_idx,
            chi_k,
            offset_k,
            alpha_theta_k,
            takens_ribbon,
            takens_tp10,
            cross_ch,
            concept_shell,
        )
    end

    # Verify multi-step Functorial composition F(T_{k+1} o T_k) == F(T_{k+1}) o F(T_k)
    max_comp_err = 0.0
    for k in 1:(n_frames - 2)
        T_comp = compose_netgraph_morphisms(graph_morphisms[k + 1], graph_morphisms[k])
        M_from_Tcomp = functor_map_morphism(T_comp; dst_time_s = (k + 1) * dt_s)
        M_comp = compose_phasehull_morphisms(hull_morphisms[k + 1], hull_morphisms[k])

        H_a = apply_phasehull_morphism(M_from_Tcomp, hull_objects[k])
        H_b = apply_phasehull_morphism(M_comp, hull_objects[k])

        err = max(
            maximum(abs.(H_a.mu_fast .- H_b.mu_fast)),
            maximum(abs.(H_a.Sigma_fast .- H_b.Sigma_fast)),
            maximum(abs.(H_a.mu_slow .- H_b.mu_slow)),
            maximum(abs.(H_a.Sigma_slow .- H_b.Sigma_slow)),
            Float64(abs(H_a.beta_0 - H_b.beta_0) + abs(H_a.beta_1 - H_b.beta_1)),
        )
        err > max_comp_err && (max_comp_err = err)
    end

    # Compute closed-loop Hysteresis Area |oint D_M d(beta_1)| via shoelace / Stieltjes integral
    hyst_sum = 0.0
    for i in 1:n_frames
        j = (i % n_frames) + 1
        b1_i = Float64(records[i].beta_1)
        b1_j = Float64(records[j].beta_1)
        dm_i = records[i].mahalanobis_tension
        dm_j = records[j].mahalanobis_tension
        hyst_sum += 0.5 * (dm_i + dm_j) * (b1_j - b1_i)
    end

    prescribed_audit = audit_prescribed_60frame_kymograph()

    return FunctorFixtureBundle(
        n_frames,
        CANONICAL_NODES,
        graph_objects,
        graph_morphisms,
        hull_objects,
        hull_morphisms,
        records,
        fast_fields,
        slow_fields,
        shell_fields,
        neural_kymo_rt,
        kymo_radii,
        fractal_kymo_ft,
        fractal_freqs,
        prescribed_audit,
        abs(hyst_sum),
        max_comm_err,
        max_comp_err,
        sigreg.C_white,
        sigreg.cond_number,
    )
end

@inline function _quad_form3(pt::NTuple{3, Float64}, mu::Vector{Float64}, A::AbstractMatrix{Float64})::Float64
    dx = pt[1] - mu[1]
    dy = pt[2] - mu[2]
    dz = pt[3] - mu[3]
    return dx * (A[1, 1] * dx + A[1, 2] * dy + A[1, 3] * dz) +
           dy * (A[2, 1] * dx + A[2, 2] * dy + A[2, 3] * dz) +
           dz * (A[3, 1] * dx + A[3, 2] * dy + A[3, 3] * dz)
end

# ------------------------------------------------------------------------------
# 5. Export All 60-Frame ChimeraX, PyMOL, MRC-2014, .cmm, .bild & JSON Assets
# ------------------------------------------------------------------------------

function _write_cmm_exact(
    filepath::AbstractString,
    G::NetGraphObject,
    nodes_meta::Vector{NetGraphNodeMeta},
)
    open(filepath, "w") do io
        println(io, "<?xml version=\"1.0\" encoding=\"utf-8\"?>")
        println(io, "<!-- [MODEL ILLUSTRATION - RUNG_4_MODEL] NeuralCompose 4-Pillar Laya + ST-JEMA Functor Graph Frame f$(lpad(G.frame_idx - 1, 2, '0')) -->")
        println(io, "<!-- Tarjan Homology: beta_0=$(G.beta_0), beta_1=$(G.beta_1), cycle_edges=$(G.topo.n_cycle_edges), bridge_edges=$(G.topo.n_bridge_edges) -->")
        @printf(io, "<marker_set name=\"functor_graph_f%02d\">\n", G.frame_idx - 1)

        for i in 1:size(G.node_coords, 1)
            x, y, z = G.node_coords[i, 1], G.node_coords[i, 2], G.node_coords[i, 3]
            vclass = G.topo.vertex_classes[i]
            nm = nodes_meta[i]
            if vclass === VERT_CYCLE
                @printf(io, "  <marker id=\"%d\" x=\"%.4f\" y=\"%.4f\" z=\"%.4f\" r=\"0.08\" g=\"0.72\" b=\"0.65\" radius=\"0.15\" note=\"[MODEL ILLUSTRATION - RUNG_4_MODEL] %s (VERT_CYCLE)\"/>\n",
                        i, x, y, z, nm.label)
            elseif vclass === VERT_TREE_OR_BRIDGE
                @printf(io, "  <marker id=\"%d\" x=\"%.4f\" y=\"%.4f\" z=\"%.4f\" r=\"0.96\" g=\"0.62\" b=\"0.04\" radius=\"0.12\" note=\"[MODEL ILLUSTRATION - RUNG_4_MODEL] %s (VERT_TREE_OR_BRIDGE)\"/>\n",
                        i, x, y, z, nm.label)
            else
                @printf(io, "  <marker id=\"%d\" x=\"%.4f\" y=\"%.4f\" z=\"%.4f\" r=\"0.86\" g=\"0.15\" b=\"0.15\" radius=\"0.10\" note=\"[MODEL ILLUSTRATION - RUNG_4_MODEL] %s (VERT_ISOLATED_MONOMER)\"/>\n",
                        i, x, y, z, nm.label)
            end
        end

        for (eid, (u, v)) in enumerate(G.edges)
            eclass = G.topo.edge_classes[eid]
            eclass === EDGE_SELF_LOOP && continue
            if eclass === EDGE_CYCLE
                @printf(io, "  <link id1=\"%d\" id2=\"%d\" r=\"0.08\" g=\"0.72\" b=\"0.65\" radius=\"0.058\"/>\n", u, v)
            else
                @printf(io, "  <link id1=\"%d\" id2=\"%d\" r=\"0.58\" g=\"0.64\" b=\"0.72\" radius=\"0.028\"/>\n", u, v)
            end
        end

        println(io, "</marker_set>")
    end
    return filepath
end

function _write_bild_trajectories(filepath::AbstractString, bundle::FunctorFixtureBundle)
    n_frames = bundle.n_frames
    open(filepath, "w") do io
        println(io, ".comment [MODEL ILLUSTRATION - RUNG_4_MODEL] NeuralCompose SIGReg Whitened 3D Axes, Centroid Pathlines & Multimodal Laya Flux")
        # Orthogonal phase-space axes
        println(io, ".color 0.58 0.64 0.72")
        println(io, ".arrow -3.2 0.0 0.0 3.2 0.0 0.0 0.025 0.07 0.93")
        println(io, ".arrow 0.0 -3.2 0.0 0.0 3.2 0.0 0.025 0.07 0.93")
        println(io, ".arrow 0.0 0.0 -3.2 0.0 0.0 3.2 0.025 0.07 0.93")

        # Fast centroid trajectory ribbon (#38bdf8)
        println(io, ".color 0.22 0.74 0.97")
        for k in 1:(n_frames - 1)
            p1 = bundle.hull_objects[k].mu_fast
            p2 = bundle.hull_objects[k + 1].mu_fast
            dist2 = sum((p2 .- p1).^2)
            dist2 < 1.0e-8 && continue
            @printf(io, ".cylinder %.5f %.5f %.5f %.5f %.5f %.5f 0.042\n",
                    p1[1], p1[2], p1[3], p2[1], p2[2], p2[3])
        end

        # Slow consolidated centroid trajectory ribbon (#a855f7)
        println(io, ".color 0.66 0.33 0.97")
        for k in 1:(n_frames - 1)
            p1 = bundle.hull_objects[k].mu_slow
            p2 = bundle.hull_objects[k + 1].mu_slow
            dist2 = sum((p2 .- p1).^2)
            dist2 < 1.0e-8 && continue
            @printf(io, ".cylinder %.5f %.5f %.5f %.5f %.5f %.5f 0.036\n",
                    p1[1], p1[2], p1[3], p2[1], p2[2], p2[3])
        end

        # Multimodal Laya Gold Acoustic Target Entrainment Ribbon & Vectors (#f59e0b / Gold)
        println(io, ".color 0.96 0.75 0.14")
        for k in 1:(n_frames - 1)
            p1 = bundle.records[k].z_music_target
            p2 = bundle.records[k + 1].z_music_target
            dist2 = (p2[1] - p1[1])^2 + (p2[2] - p1[2])^2 + (p2[3] - p1[3])^2
            dist2 < 1.0e-8 && continue
            @printf(io, ".cylinder %.5f %.5f %.5f %.5f %.5f %.5f 0.024\n",
                    p1[1], p1[2], p1[3], p2[1], p2[2], p2[3])
        end
        for k in 1:4:n_frames
            pf = bundle.hull_objects[k].mu_fast
            pm = bundle.records[k].z_music_target
            dist2 = (pm[1] - pf[1])^2 + (pm[2] - pf[2])^2 + (pm[3] - pf[3])^2
            dist2 < 1.0e-4 && continue
            @printf(io, ".arrow %.5f %.5f %.5f %.5f %.5f %.5f 0.022 0.055 0.82\n",
                    pf[1], pf[2], pf[3], pm[1], pm[2], pm[3])
        end
    end
    return filepath
end

"""
    export_functor_fixture_assets(fixture_dir::AbstractString, bundle::FunctorFixtureBundle)

Writes all required 60-frame 4-Pillar Functor & Dialectical assets into `fixture_dir`:
  1. `functor_graph_f00.cmm` .. `functor_graph_f59.cmm`
  2. `fast_wireframe_f00.mrc` .. `f59.mrc`, `slow_core_f00.mrc` .. `f59.mrc`, `plasticity_shell_f00.mrc` .. `f59.mrc`
  3. `phase_trajectory_and_flux.bild` and `phase_trajectory_and_laya_flux.bild`
  4. `launch_functor_dialectic_60f.cxc` (plus PyMOL `.pml`)
  5. `functor_dialectic_fixture_60f.json` and `four_pillar_fixture_60f.json`
"""
function export_functor_fixture_assets(fixture_dir::AbstractString, bundle::FunctorFixtureBundle)
    mkpath(fixture_dir)
    n_frames = bundle.n_frames
    voxel_sz = Float32(7.0 / 32.0)

    for k in 1:n_frames
        tag = @sprintf("f%02d", k - 1)
        _write_cmm_exact(
            joinpath(fixture_dir, "functor_graph_$(tag).cmm"),
            bundle.graph_objects[k],
            bundle.nodes_meta,
        )
        KymographAndNeuralComposeHull._write_mrc2014_32(
            joinpath(fixture_dir, "fast_wireframe_$(tag).mrc"),
            bundle.fast_fields[k],
            voxel_sz,
            "[MODEL ILLUSTRATION - RUNG_4_MODEL] NeuralCompose Fast Wireframe Drive $(tag)",
        )
        KymographAndNeuralComposeHull._write_mrc2014_32(
            joinpath(fixture_dir, "slow_core_$(tag).mrc"),
            bundle.slow_fields[k],
            voxel_sz,
            "[MODEL ILLUSTRATION - RUNG_4_MODEL] NeuralCompose Slow Memory Core $(tag)",
        )
        KymographAndNeuralComposeHull._write_mrc2014_32(
            joinpath(fixture_dir, "plasticity_shell_$(tag).mrc"),
            bundle.shell_fields[k],
            voxel_sz,
            "[MODEL ILLUSTRATION - RUNG_4_MODEL] NeuralCompose Plasticity Shell $(tag)",
        )
    end

    # 3. Export .bild files with strict dist2 >= 1.0e-8 filter
    bild_path = _write_bild_trajectories(joinpath(fixture_dir, "phase_trajectory_and_flux.bild"), bundle)
    _write_bild_trajectories(joinpath(fixture_dir, "phase_trajectory_and_laya_flux.bild"), bundle)

    # 4. Export launch_functor_dialectic_60f.cxc for UCSF ChimeraX 1.12
    cxc_path = joinpath(fixture_dir, "launch_functor_dialectic_60f.cxc")
    open(cxc_path, "w") do io
        println(io, "# [MODEL ILLUSTRATION - RUNG_4_MODEL] UCSF ChimeraX 1.12 Synchronized 60-Frame 4-Pillar Functor Dialectic Script")
        println(io, "windowsize 1920 1080")
        println(io, "set bgColor #0b0f19")
        println(io, "open fast_wireframe_f*.mrc vseries true")
        println(io, "open slow_core_f*.mrc vseries true")
        println(io, "open plasticity_shell_f*.mrc vseries true")
        println(io, "open functor_graph_f31.cmm")
        println(io, "open phase_trajectory_and_flux.bild")
        println(io, "volume #1 style mesh level 0.30 color #38bdf8 squareMesh true capFaces false")
        println(io, "volume #2 style surface level 0.45 color #a855f7 transparency 0.25")
        println(io, "volume #3 style mesh level 0.22 color #34d399 squareMesh true capFaces false")
        println(io, "lighting soft")
        println(io, "view")
        println(io, "2dlabels create title text \"[MODEL ILLUSTRATION - RUNG_4_MODEL] NeuralCompose 60-Frame 4-Pillar Functor Dialectic (b=0.17)\" xpos 0.03 ypos 0.95 color #e2e8f0 size 17")
        println(io, "2dlabels create legend text \"Pillar 1: Laya SIGReg Q=20 | Pillar 2: ST-JEMA Tarjan beta_1 | Pillar 3: Fast Wireframe vs Slow Core | Pillar 4: Gold Laya Flux\" xpos 0.03 ypos 0.03 color #94a3b8 size 13")
        println(io, "vseries play #1-3 loop true maxFrameRate 15")
    end

    # Also export PyMOL bridge script launch_functor_dialectic_60f.pml
    pml_path = joinpath(fixture_dir, "launch_functor_dialectic_60f.pml")
    open(pml_path, "w") do io
        println(io, "# [MODEL ILLUSTRATION - RUNG_4_MODEL] PyMOL Synchronized 4-Pillar Functor Dialectic Scene")
        println(io, "bg_color black")
        println(io, "set normalize_ccp4_maps, 0")
        println(io, "load fast_wireframe_f31.mrc, fast_wireframe")
        println(io, "load slow_core_f31.mrc, slow_core")
        println(io, "load plasticity_shell_f31.mrc, plasticity_shell")
        println(io, "isosurface surf_slow_core, slow_core, 0.45")
        println(io, "color purple, surf_slow_core")
        println(io, "set transparency, 0.25, surf_slow_core")
        println(io, "isomesh mesh_fast_wire, fast_wireframe, 0.30")
        println(io, "color marine, mesh_fast_wire")
        println(io, "isomesh mesh_plast_shell, plasticity_shell, 0.22")
        println(io, "color tv_green, mesh_plast_shell")
        println(io, "reset")
        println(io, "zoom")
    end

    # 5. Export functor_dialectic_fixture_60f.json (v2) and four_pillar_fixture_60f.json (v1)
    json_path = joinpath(fixture_dir, "functor_dialectic_fixture_60f.json")
    _write_fixture_json(
        json_path,
        bundle;
        schema_id = "neuralcompose.functor.four-pillar-dialectical-fixture.v2",
    )
    _write_fixture_json(
        joinpath(fixture_dir, "four_pillar_fixture_60f.json"),
        bundle;
        schema_id = "neuralcompose.four-pillar.laya-stjema-memory-multimodal.v1",
    )

    return (
        cxc_path = cxc_path,
        pml_path = pml_path,
        bild_path = bild_path,
        json_path = json_path,
    )
end

function _write_fixture_json(
    json_path::AbstractString,
    bundle::FunctorFixtureBundle;
    schema_id::String = "neuralcompose.functor.four-pillar-dialectical-fixture.v2",
)
    open(json_path, "w") do io
        println(io, "{")
        println(io, "  \"schemaId\": \"$(schema_id)\",")
        println(io, "  \"epistemicBadge\": \"[MODEL ILLUSTRATION - RUNG_4_MODEL | 4-PILLAR JEMA FIXTURE]\",")
        println(io, "  \"benchmarkSeries\": \"b=0.17\",")
        @printf(io, "  \"nFrames\": %d,\n", bundle.n_frames)
        @printf(io, "  \"globalCondNumber\": %.6f,\n", bundle.global_cond_number)
        @printf(io, "  \"globalCovWhitenedDiag\": [%.6f, %.6f, %.6f],\n",
                bundle.global_cov_whitened[1, 1], bundle.global_cov_whitened[2, 2], bundle.global_cov_whitened[3, 3])
        @printf(io, "  \"hysteresisAreaBeta1DM\": %.6f,\n", bundle.hysteresis_area_beta1_DM)
        @printf(io, "  \"prescribedHysteresisAreaTPoly\": %.6f,\n", bundle.prescribed_audit.hysteresis_area_T_poly)
        @printf(io, "  \"prescribedClipFractionF20\": %.6f,\n", bundle.prescribed_audit.clip_fraction_3p20[21])
        @printf(io, "  \"maxFunctorCommutativityErr\": %.6e,\n", bundle.max_functor_commutativity_err)
        @printf(io, "  \"maxFunctorCompositionErr\": %.6e,\n", bundle.max_functor_composition_err)

        # Nodes metadata (Q = 20 specialized spatial-spectral query nodes)
        println(io, "  \"nodesMeta\": [")
        for (i, nm) in enumerate(bundle.nodes_meta)
            comma = i < length(bundle.nodes_meta) ? "," : ""
            @printf(io, "    {\"id\": %d, \"label\": \"%s\", \"channelBand\": \"%s\", \"role\": \"%s\", \"basePos\": [%.4f, %.4f, %.4f]}%s\n",
                    nm.id, nm.label, nm.channel_band, nm.role, nm.base_pos[1], nm.base_pos[2], nm.base_pos[3], comma)
        end
        println(io, "  ],")

        # Kymograph radii and matrix (24 x 60)
        print(io, "  \"neuralKymoRadii\": [")
        for (i, r) in enumerate(bundle.neural_kymo_radii)
            i > 1 && print(io, ", ")
            @printf(io, "%.4f", r)
        end
        println(io, "],")

        println(io, "  \"neuralKymographRT\": [")
        for r_idx in 1:size(bundle.neural_kymograph_rt, 1)
            print(io, "    [")
            for f_idx in 1:bundle.n_frames
                f_idx > 1 && print(io, ", ")
                @printf(io, "%.4f", bundle.neural_kymograph_rt[r_idx, f_idx])
            end
            comma = r_idx < size(bundle.neural_kymograph_rt, 1) ? "," : ""
            println(io, "]$comma")
        end
        println(io, "  ],")

        # Prescribed R0 kymograph radii & matrix (25 x 60) for comparison tab
        print(io, "  \"prescribedKymoRadiiM\": [")
        for (i, r) in enumerate(bundle.prescribed_audit.radii_m)
            i > 1 && print(io, ", ")
            @printf(io, "%.4f", r)
        end
        println(io, "],")

        println(io, "  \"prescribedKymographRT\": [")
        for r_idx in 1:size(bundle.prescribed_audit.poly_kymograph_rt, 1)
            print(io, "    [")
            for f_idx in 1:bundle.n_frames
                f_idx > 1 && print(io, ", ")
                @printf(io, "%.4f", bundle.prescribed_audit.poly_kymograph_rt[r_idx, f_idx])
            end
            comma = r_idx < size(bundle.prescribed_audit.poly_kymograph_rt, 1) ? "," : ""
            println(io, "]$comma")
        end
        println(io, "  ],")

        # 1/f Fractal Spectral Kymograph frequencies & matrix (24 x 60, WorldModel/synthetic_1f.py)
        print(io, "  \"fractalKymoFreqsHz\": [")
        for (i, fq) in enumerate(bundle.fractal_kymo_freqs_hz)
            i > 1 && print(io, ", ")
            @printf(io, "%.4f", fq)
        end
        println(io, "],")

        println(io, "  \"fractal1fKymographFT\": [")
        for r_idx in 1:size(bundle.fractal_1f_kymograph_ft, 1)
            print(io, "    [")
            for f_idx in 1:bundle.n_frames
                f_idx > 1 && print(io, ", ")
                @printf(io, "%.4f", bundle.fractal_1f_kymograph_ft[r_idx, f_idx])
            end
            comma = r_idx < size(bundle.fractal_1f_kymograph_ft, 1) ? "," : ""
            println(io, "]$comma")
        end
        println(io, "  ],")

        # Frames array
        println(io, "  \"frames\": [")
        for k in 1:bundle.n_frames
            rec = bundle.records[k]
            G   = bundle.graph_objects[k]
            H   = bundle.hull_objects[k]
            println(io, "    {")
            @printf(io, "      \"frameIndex\": %d,\n", k - 1)
            @printf(io, "      \"frameTag\": \"%s\",\n", rec.frame_tag)
            @printf(io, "      \"timeS\": %.4f,\n", rec.time_s)
            @printf(io, "      \"phaseRegime\": \"%s\",\n", rec.phase_regime)
            # Pillar 1 fields
            @printf(io, "      \"layaSigregLoss\": %.6f,\n", rec.laya_sigreg_loss)
            @printf(io, "      \"layaQueryLoss\": %.6f,\n", rec.laya_query_loss)
            @printf(io, "      \"zEegWhitened\": [%.5f, %.5f, %.5f],\n",
                    G.z_drive[1], G.z_drive[2], G.z_drive[3])
            # Pillar 2 fields
            @printf(io, "      \"beta0\": %d,\n", rec.beta_0)
            @printf(io, "      \"beta1\": %d,\n", rec.beta_1)
            @printf(io, "      \"nCycleEdges\": %d,\n", rec.n_cycle_edges)
            @printf(io, "      \"nBridgeEdges\": %d,\n", rec.n_bridge_edges)
            @printf(io, "      \"nSelfLoops\": %d,\n", rec.n_self_loops)
            @printf(io, "      \"stNodePredLoss\": %.6f,\n", rec.st_node_pred_loss)
            @printf(io, "      \"stEdgePredLoss\": %.6f,\n", rec.st_edge_pred_loss)
            # Pillar 3 fields (both v1 diagonal and v2 oriented eigenbasis keys)
            @printf(io, "      \"mahalanobisTension\": %.5f,\n", rec.mahalanobis_tension)
            @printf(io, "      \"principalAxisAngleDeg\": %.4f,\n", rec.principal_axis_angle_deg)
            @printf(io, "      \"overhangEscapePct\": %.4f,\n", 100.0 * rec.overhang_escape_fraction)
            @printf(io, "      \"hollowShellVolPct\": %.4f,\n", 100.0 * rec.hollow_shell_volume_fraction)
            @printf(io, "      \"muFast\": [%.5f, %.5f, %.5f],\n", H.mu_fast[1], H.mu_fast[2], H.mu_fast[3])
            @printf(io, "      \"muSlow\": [%.5f, %.5f, %.5f],\n", H.mu_slow[1], H.mu_slow[2], H.mu_slow[3])
            @printf(io, "      \"sigmaFastDiag\": [%.5f, %.5f, %.5f],\n",
                    H.Sigma_fast[1, 1], H.Sigma_fast[2, 2], H.Sigma_fast[3, 3])
            @printf(io, "      \"sigmaSlowDiag\": [%.5f, %.5f, %.5f],\n",
                    H.Sigma_slow[1, 1], H.Sigma_slow[2, 2], H.Sigma_slow[3, 3])
            @printf(io, "      \"fastSemiAxes\": [%.5f, %.5f, %.5f],\n",
                    sqrt(2.41 * rec.fast_eigvals[1]), sqrt(2.41 * rec.fast_eigvals[2]), sqrt(2.41 * rec.fast_eigvals[3]))
            @printf(io, "      \"fastEigvecs\": [[%.5f, %.5f, %.5f], [%.5f, %.5f, %.5f], [%.5f, %.5f, %.5f]],\n",
                    rec.fast_eigvecs[1, 1], rec.fast_eigvecs[2, 1], rec.fast_eigvecs[3, 1],
                    rec.fast_eigvecs[1, 2], rec.fast_eigvecs[2, 2], rec.fast_eigvecs[3, 2],
                    rec.fast_eigvecs[1, 3], rec.fast_eigvecs[2, 3], rec.fast_eigvecs[3, 3])
            @printf(io, "      \"slowSemiAxes\": [%.5f, %.5f, %.5f],\n",
                    sqrt(1.60 * rec.slow_eigvals[1]), sqrt(1.60 * rec.slow_eigvals[2]), sqrt(1.60 * rec.slow_eigvals[3]))
            @printf(io, "      \"slowEigvecs\": [[%.5f, %.5f, %.5f], [%.5f, %.5f, %.5f], [%.5f, %.5f, %.5f]],\n",
                    rec.slow_eigvecs[1, 1], rec.slow_eigvecs[2, 1], rec.slow_eigvecs[3, 1],
                    rec.slow_eigvecs[1, 2], rec.slow_eigvecs[2, 2], rec.slow_eigvecs[3, 2],
                    rec.slow_eigvecs[1, 3], rec.slow_eigvecs[2, 3], rec.slow_eigvecs[3, 3])
            # Pillar 4 fields
            @printf(io, "      \"zMusicTarget\": [%.5f, %.5f, %.5f],\n",
                    rec.z_music_target[1], rec.z_music_target[2], rec.z_music_target[3])
            @printf(io, "      \"tempoBpm\": %.2f,\n", rec.tempo_bpm)
            @printf(io, "      \"layaCadenceState\": \"%s\",\n", rec.laya_cadence_state)
            @printf(io, "      \"multimodalAlignmentLoss\": %.6f,\n", rec.multimodal_alignment_loss)
            @printf(io, "      \"layaAbsorptionIndex\": %.6f,\n", rec.laya_absorption_index)
            # 1/f Fractal Spectral Slope & Client-Native Takens Phase-Space fields
            @printf(io, "      \"fractalExponentChi\": %.5f,\n", rec.fractal_exponent_chi)
            @printf(io, "      \"aperiodicOffsetLog10\": %.5f,\n", rec.aperiodic_offset_log10)
            @printf(io, "      \"alphaThetaRatio\": %.5f,\n", rec.alpha_theta_ratio)
            @printf(io, "      \"crossChannelPt\": [%.4f, %.4f, %.4f, %.4f],\n",
                    rec.cross_channel_pt[1], rec.cross_channel_pt[2], rec.cross_channel_pt[3], rec.cross_channel_pt[4])

            print(io, "      \"takensDelayRibbon\": [")
            for ti in 1:size(rec.takens_delay_ribbon, 1)
                ti > 1 && print(io, ", ")
                @printf(io, "[%.4f, %.4f, %.4f]",
                        rec.takens_delay_ribbon[ti, 1], rec.takens_delay_ribbon[ti, 2], rec.takens_delay_ribbon[ti, 3])
            end
            println(io, "],")

            print(io, "      \"takensColorTP10\": [")
            for ti in 1:length(rec.takens_color_tp10)
                ti > 1 && print(io, ", ")
                @printf(io, "%.4f", rec.takens_color_tp10[ti])
            end
            println(io, "],")

            print(io, "      \"conceptNodesShell\": [")
            for ci in 1:size(rec.concept_nodes_shell, 1)
                ci > 1 && print(io, ", ")
                @printf(io, "[%.4f, %.4f, %.4f, %.4f]",
                        rec.concept_nodes_shell[ci, 1], rec.concept_nodes_shell[ci, 2],
                        rec.concept_nodes_shell[ci, 3], rec.concept_nodes_shell[ci, 4])
            end
            println(io, "],")

            # BCICore Dialectical fields
            @printf(io, "      \"dialecticCoherence\": %.4f,\n", rec.dialectic_coherence)
            @printf(io, "      \"dialecticResonance\": %.4f,\n", rec.dialectic_resonance)
            @printf(io, "      \"dialecticNovelty\": %.4f,\n", rec.dialectic_novelty)
            @printf(io, "      \"dialecticPotential\": %.4f,\n", rec.dialectic_potential)
            @printf(io, "      \"selectionTemperature\": %.4f,\n", rec.selection_temperature)
            @printf(io, "      \"dialecticOutcome\": \"%s\",\n", rec.dialectic_outcome)
            @printf(io, "      \"prescribedCore8VolM3\": %.2f,\n", bundle.prescribed_audit.core_8p00_volume_m3[k])
            @printf(io, "      \"prescribedClipPct\": %.2f,\n", 100.0 * bundle.prescribed_audit.clip_fraction_3p20[k])

            # Node coordinates (both v1 queryNodeCoords and v2 nodeCoords) and vertex classes (20 nodes)
            print(io, "      \"queryNodeCoords\": [")
            for i in 1:size(G.node_coords, 1)
                i > 1 && print(io, ", ")
                @printf(io, "[%.4f, %.4f, %.4f]", G.node_coords[i, 1], G.node_coords[i, 2], G.node_coords[i, 3])
            end
            println(io, "],")

            print(io, "      \"nodeCoords\": [")
            for i in 1:size(G.node_coords, 1)
                i > 1 && print(io, ", ")
                @printf(io, "[%.4f, %.4f, %.4f]", G.node_coords[i, 1], G.node_coords[i, 2], G.node_coords[i, 3])
            end
            println(io, "],")

            print(io, "      \"vertexClasses\": [")
            for i in 1:length(G.topo.vertex_classes)
                i > 1 && print(io, ", ")
                vc = G.topo.vertex_classes[i]
                code = vc === VERT_CYCLE ? 1 : (vc === VERT_TREE_OR_BRIDGE ? 2 : 3)
                print(io, code)
            end
            println(io, "],")

            println(io, "      \"edges\": [")
            for (eid, (u, v)) in enumerate(G.edges)
                ec = G.topo.edge_classes[eid]
                ecode = ec === EDGE_CYCLE ? 1 : (ec === EDGE_BRIDGE_OR_TREE ? 2 : 3)
                w = G.edge_weights[eid]
                ecomma = eid < length(G.edges) ? "," : ""
                @printf(io, "        {\"u\": %d, \"v\": %d, \"edgeClass\": %d, \"weight\": %.4f}%s\n",
                        u - 1, v - 1, ecode, w, ecomma)
            end
            println(io, "      ]")

            fcomma = k < bundle.n_frames ? "," : ""
            println(io, "    }$fcomma")
        end
        println(io, "  ]")
        println(io, "}")
    end
    return json_path
end

end # module FunctorDialecticalFixture

using LinearAlgebra
using Test
using Printf
using .FunctorDialecticalFixture

if abspath(PROGRAM_FILE) == @__FILE__
    out_dir = length(ARGS) >= 1 ? ARGS[1] : joinpath(@__DIR__, "neural_compose_fixture_build")
    println("================================================================================")
    println("GENERATING 60-FRAME 4-PILLAR FUNCTOR NETWORK GRAPH & DIALECTICAL FIXTURE")
    println("Target fixture directory: ", out_dir)
    println("================================================================================")

    bundle = build_functor_dialectical_fixture_60f()
    paths  = export_functor_fixture_assets(out_dir, bundle)

    @testset "4-Pillar Functor Dialectical Topological Fixture Verification" begin
        # 0. Pillar 1: Laya SIGReg Global Whitening Gate & Q=20 Query Nodes
        @test norm(bundle.global_cov_whitened - Matrix{Float64}(I, 3, 3)) < 1.0e-12
        @test isapprox(bundle.global_cond_number, 1.0; atol = 1.0e-10)
        @test length(bundle.nodes_meta) == 20
        @printf("  [PASS] Pillar 1 (Laya): SIGReg global cov == I_3 (kappa = %.4f), Q = %d query nodes\n",
                bundle.global_cond_number, length(bundle.nodes_meta))

        # 1. Functorial Commutativity Gate: F(T_{k->k+1}(G_k)) == M_{k->k+1}(F(G_k))
        @test bundle.max_functor_commutativity_err < 1.0e-12
        @test bundle.max_functor_composition_err < 1.0e-12
        @printf("  [PASS] Functor Commutativity max_err = %.3e | Composition max_err = %.3e (< 1e-12)\n",
                bundle.max_functor_commutativity_err, bundle.max_functor_composition_err)

        # 2. Pillar 2: Homology & Tarjan Bridge Classification Invariants + Inside-Cage Embedding
        max_node_df2 = 0.0
        for k in 1:bundle.n_frames
            rec = bundle.records[k]
            G_k = bundle.graph_objects[k]
            H_k = bundle.hull_objects[k]
            inv_Sig_f = inv(Symmetric(H_k.Sigma_fast))
            for i in 1:20
                dx = G_k.node_coords[i, :] .- H_k.mu_fast
                df2 = dot(dx, inv_Sig_f * dx)
                df2 > max_node_df2 && (max_node_df2 = df2)
                # Every specialized query node must lie strictly inside Fast Wireframe Cage W_k (df2 < 2.41)
                @test df2 < 2.40
            end
            @test rec.beta_0 == 1
            @test rec.beta_1 >= 2
            @test rec.n_cycle_edges >= 7
            @test rec.n_bridge_edges >= 1
            @test rec.n_self_loops == 2
            @test rec.st_node_pred_loss > 0.0
            @test rec.st_edge_pred_loss > 0.0
        end
        @printf("  [PASS] All Q=20 Laya query nodes strictly inside Fast Wireframe Cage W_k (max df2 = %.4f < 2.41)\n",
                max_node_df2)
        # Cycle rank rises in Phase 2 / early Phase 3 and creates non-zero hysteresis loop area
        @test bundle.records[38].beta_1 > bundle.records[10].beta_1 + 3
        @test bundle.hysteresis_area_beta1_DM > 4.0
        @printf("  [PASS] Pillar 2 (ST-JEMA + Tarjan): Hysteresis Loop Area |oint D_M d(beta_1)| = %.4f != 0\n",
                bundle.hysteresis_area_beta1_DM)

        # 3. Pillar 3: 3D Phase-Space Invariants (Tilt theta_1 > 15 deg, Escape eta_escape > 40%)
        m_rest = bundle.records[15]
        m_surg = bundle.records[32]
        m_cons = bundle.records[46]
        @test m_surg.principal_axis_angle_deg > 15.0
        @test m_surg.overhang_escape_fraction > m_rest.overhang_escape_fraction + 0.30
        @printf("  [PASS] Pillar 3 (Memory): Frame f31 (Excursion) D_M=%.2f, theta_1=%.1f deg, Escape=%.1f%%, beta_1=%d\n",
                m_surg.mahalanobis_tension, m_surg.principal_axis_angle_deg,
                100.0 * m_surg.overhang_escape_fraction, m_surg.beta_1)
        @printf("  [PASS] Pillar 3 (Memory): Frame f45 (Consolidation) D_M=%.2f, theta_1=%.1f deg, Escape=%.1f%%, beta_1=%d\n",
                m_cons.mahalanobis_tension, m_cons.principal_axis_angle_deg,
                100.0 * m_cons.overhang_escape_fraction, m_cons.beta_1)

        # 4. Pillar 4: Multimodal Musical Laya + 1/f Fractal Spectral Slope + Takens Delay Attractor
        @test isapprox(m_rest.tempo_bpm, 72.0; atol = 1.0e-6)
        @test isapprox(m_surg.tempo_bpm, 128.0; atol = 1.0e-6)
        @test isapprox(bundle.records[60].tempo_bpm, 64.0; atol = 1.0e-6)
        @test bundle.records[60].laya_absorption_index > m_surg.laya_absorption_index
        @test m_rest.fractal_exponent_chi > m_surg.fractal_exponent_chi + 0.45
        @test bundle.records[60].fractal_exponent_chi > m_surg.fractal_exponent_chi + 0.45
        @test size(m_surg.takens_delay_ribbon) == (24, 3)
        @test size(m_surg.concept_nodes_shell) == (8, 4)
        @printf("  [PASS] Pillar 4 (Multimodal Laya): Tempo %.0f -> %.0f -> %.0f BPM, Absorption Lambda=%.3f -> %.3f\n",
                m_rest.tempo_bpm, m_surg.tempo_bpm, bundle.records[60].tempo_bpm,
                m_surg.laya_absorption_index, bundle.records[60].laya_absorption_index)
        @printf("  [PASS] Fractal 1/f & Takens Phase-Space: chi %.2f -> %.2f -> %.2f, alpha/(alpha+theta) %.2f -> %.2f\n",
                m_rest.fractal_exponent_chi, m_surg.fractal_exponent_chi, bundle.records[60].fractal_exponent_chi,
                m_rest.alpha_theta_ratio, m_surg.alpha_theta_ratio)

        # 5. Asset Verification (60 .cmm, 180 .mrc with 1024-byte header, .bild, .cxc, .json)
        @test isfile(paths.cxc_path)
        @test isfile(paths.pml_path)
        @test isfile(paths.bild_path)
        @test isfile(paths.json_path)
        @test isfile(joinpath(out_dir, "four_pillar_fixture_60f.json"))
        for k in 0:59
            tag = @sprintf("f%02d", k)
            @test isfile(joinpath(out_dir, "functor_graph_$(tag).cmm"))
            @test filesize(joinpath(out_dir, "fast_wireframe_$(tag).mrc")) == 1024 + 4 * 32^3
            @test filesize(joinpath(out_dir, "slow_core_$(tag).mrc")) == 1024 + 4 * 32^3
            @test filesize(joinpath(out_dir, "plasticity_shell_$(tag).mrc")) == 1024 + 4 * 32^3
        end
    end
    println("[PASS] All 60-frame 4-Pillar Functor Network Graph & Phase-Hull fixture assets generated and verified.")
end
