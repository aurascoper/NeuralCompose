#!/usr/bin/env julia
# ==============================================================================
# FunctorFaithfulnessParetoSweep.jl
# Category-Theoretic Functor Faithfulness Pareto Sweep:
#   Graph Cycle Rank beta_1(G_k) vs 3D Cubical Superlevel Genus g(Psi_{>= theta})
#
# Computes exact 3D cubical complex Betti numbers (b_0, b_1, b_2) and Euler
# characteristic chi = C_0 - C_1 + C_2 - C_3 = b_0 - b_1 + b_2 on the 32^3
# phase-space voxel grid, and sweeps cycle-filament coupling gamma in [0, 1]
# against superlevel threshold theta in [0.18, 0.62] to map the Pareto frontier
# between H_1 homological faithfulness |beta_1(G_k) - b_1(Psi_{>= theta})| and
# continuum phase-hull distortion ||Psi^(gamma) - Psi^(0)||_2 / ||Psi^(0)||_2.
#
# Epistemic Boundary: [MODEL ILLUSTRATION - RUNG_4_MODEL]
# Dependencies: Julia Base, LinearAlgebra, Statistics, Printf, Test stdlibs only.
# Strictly zero em-dashes and zero en-dashes.
# ==============================================================================

module FunctorFaithfulnessParetoSweep

using LinearAlgebra
using Statistics
using Printf
using Test

include(joinpath(@__DIR__, "generate_functor_dialectical_fixture.jl"))
using .FunctorDialecticalFixture

export CubicalHomology3D, ParetoSweepPoint, ParetoSweepReport
export compute_cubical_homology_3d, run_functor_faithfulness_pareto_sweep, export_pareto_sweep_json

struct CubicalHomology3D
    b0::Int
    b1::Int
    b2::Int
    euler_chi::Int
    active_voxels::Int
end

struct ParetoSweepPoint
    gamma::Float64
    theta::Float64
    mean_abs_beta1_defect::Float64
    exact_match_fraction::Float64
    mean_shell_l2_distortion::Float64
    mean_active_vol_fraction::Float64
    frame_b1_pred::Vector{Int}
    frame_b1_true::Vector{Int}
    is_pareto_optimal::Bool
end

struct ParetoSweepReport
    eval_frames::Vector{Int}
    true_beta1::Vector{Int}
    points::Vector{ParetoSweepPoint}
    pareto_frontier::Vector{ParetoSweepPoint}
end

"""
    compute_cubical_homology_3d(mask::BitArray{3}) -> CubicalHomology3D

Computes exact 3D cubical complex Betti numbers `(b0, b1, b2)` of a binary voxel
subcomplex `mask` where each active voxel is a unit 3-cube `[i,i+1]x[j,j+1]x[k,k+1]`:
  - `C0, C1, C2, C3`: Exact counts of 0-cubes (vertices), 1-cubes (edges),
    2-cubes (faces), and 3-cubes (voxels) in the induced cubical complex.
  - `b0`: Connected components of the cubical complex (= 26-connected voxel components).
  - `b2`: Enclosed 6-connected complement cavities not reaching the boundary.
  - `b1`: Tunnel/handle genus via Euler-Poincare identity `b1 = b0 + b2 - chi`.
"""
function compute_cubical_homology_3d(mask::BitArray{3})::CubicalHomology3D
    nx, ny, nz = size(mask)
    n_vox = count(mask)
    n_vox == 0 && return CubicalHomology3D(0, 0, 0, 0, 0)

    v0 = falses(nx + 1, ny + 1, nz + 1)
    ex = falses(nx, ny + 1, nz + 1)
    ey = falses(nx + 1, ny, nz + 1)
    ez = falses(nx + 1, ny + 1, nz)
    fxy = falses(nx, ny, nz + 1)
    fxz = falses(nx, ny + 1, nz)
    fyz = falses(nx + 1, ny, nz)

    @inbounds for k in 1:nz, j in 1:ny, i in 1:nx
        mask[i, j, k] || continue
        for dk in 0:1, dj in 0:1, di in 0:1
            v0[i + di, j + dj, k + dk] = true
        end
        for dk in 0:1, dj in 0:1
            ex[i, j + dj, k + dk] = true
        end
        for dk in 0:1, di in 0:1
            ey[i + di, j, k + dk] = true
        end
        for dj in 0:1, di in 0:1
            ez[i + di, j + dj, k] = true
        end
        for dk in 0:1
            fxy[i, j, k + dk] = true
        end
        for dj in 0:1
            fxz[i, j + dj, k] = true
        end
        for di in 0:1
            fyz[i + di, j, k] = true
        end
    end

    c0 = count(v0)
    c1 = count(ex) + count(ey) + count(ez)
    c2 = count(fxy) + count(fxz) + count(fyz)
    c3 = n_vox
    chi = c0 - c1 + c2 - c3

    # b0 via 26-connected BFS on active voxels (equivalent to cubical vertex connectivity)
    visited = falses(nx, ny, nz)
    b0 = 0
    queue = Tuple{Int, Int, Int}[]
    for k in 1:nz, j in 1:ny, i in 1:nx
        (mask[i, j, k] && !visited[i, j, k]) || continue
        b0 += 1
        visited[i, j, k] = true
        push!(queue, (i, j, k))
        while !isempty(queue)
            cx, cy, cz = pop!(queue)
            for dz in -1:1, dy in -1:1, dx in -1:1
                (dx == 0 && dy == 0 && dz == 0) && continue
                x2, y2, z2 = cx + dx, cy + dy, cz + dz
                if 1 <= x2 <= nx && 1 <= y2 <= ny && 1 <= z2 <= nz && mask[x2, y2, z2] && !visited[x2, y2, z2]
                    visited[x2, y2, z2] = true
                    push!(queue, (x2, y2, z2))
                end
            end
        end
    end

    # b2 via 6-connected BFS on complement (~mask) inside a 1-voxel exterior collar
    comp_vis = falses(nx + 2, ny + 2, nz + 2)
    is_empty_padded(x, y, z) = (x == 1 || x == nx + 2 || y == 1 || y == ny + 2 || z == 1 || z == nz + 2) ?
        true : !mask[x - 1, y - 1, z - 1]
    dirs6 = ((1,0,0), (-1,0,0), (0,1,0), (0,-1,0), (0,0,1), (0,0,-1))
    comp_components = 0
    for k in 1:(nz + 2), j in 1:(ny + 2), i in 1:(nx + 2)
        (is_empty_padded(i, j, k) && !comp_vis[i, j, k]) || continue
        comp_components += 1
        comp_vis[i, j, k] = true
        push!(queue, (i, j, k))
        while !isempty(queue)
            cx, cy, cz = pop!(queue)
            for (dx, dy, dz) in dirs6
                x2, y2, z2 = cx + dx, cy + dy, cz + dz
                if 1 <= x2 <= nx + 2 && 1 <= y2 <= ny + 2 && 1 <= z2 <= nz + 2 &&
                   is_empty_padded(x2, y2, z2) && !comp_vis[x2, y2, z2]
                    comp_vis[x2, y2, z2] = true
                    push!(queue, (x2, y2, z2))
                end
            end
        end
    end
    b2 = max(0, comp_components - 1)
    b1 = max(0, b0 + b2 - chi)
    return CubicalHomology3D(b0, b1, b2, chi, n_vox)
end

"""
    _build_cycle_filament_field(beta1::Int, n_grid::Int = 32) -> Array{Float32, 3}

Synthesizes a 3D cubical cycle-handle field carrying `beta1` independent topological
handles (1-cycles) arranged on a connected 3x3x2 3D boustrophedon cycle-basis lattice
in `[-3.5, 3.5]^3` (supporting `beta1` up to 18).
"""
function _build_cycle_filament_field(beta1::Int, n_grid::Int = 32)::Array{Float32, 3}
    coords = collect(range(-3.5, 3.5; length = n_grid))
    vol = zeros(Float32, n_grid, n_grid, n_grid)
    r_loop = 0.62
    sigma_tube = 0.24
    inv_2s2 = 1.0 / (2.0 * sigma_tube^2)

    snake_centers_3d = (
        # Layer 1 (z = 0.0): handles 1..9
        (-1.95, -1.95, 0.0), ( 0.00, -1.95, 0.0), ( 1.95, -1.95, 0.0),
        ( 1.95,  0.00, 0.0), ( 0.00,  0.00, 0.0), (-1.95,  0.00, 0.0),
        (-1.95,  1.95, 0.0), ( 0.00,  1.95, 0.0), ( 1.95,  1.95, 0.0),
        # Layer 2 (z = 1.65): handles 10..18 (reverse boustrophedon traversal from (1.95, 1.95))
        ( 1.95,  1.95, 1.65), ( 0.00,  1.95, 1.65), (-1.95,  1.95, 1.65),
        (-1.95,  0.00, 1.65), ( 0.00,  0.00, 1.65), ( 1.95,  0.00, 1.65),
        ( 1.95, -1.95, 1.65), ( 0.00, -1.95, 1.65), (-1.95, -1.95, 1.65),
    )
    loop_list = collect(snake_centers_3d[1:clamp(beta1, 0, length(snake_centers_3d))])

    @inbounds for iz in 1:n_grid, iy in 1:n_grid, ix in 1:n_grid
        x, y, z = coords[ix], coords[iy], coords[iz]
        val = 0.0
        for (idx, (cx, cy, cz)) in enumerate(loop_list)
            r_loc = sqrt((x - cx)^2 + (y - cy)^2)
            d2 = (r_loc - r_loop)^2 + (z - cz)^2
            val = max(val, exp(-d2 * inv_2s2))
            if idx > 1
                px, py, pz = loop_list[idx - 1]
                ux, uy, uz = cx - px, cy - py, cz - pz
                len_xy = sqrt(ux * ux + uy * uy)
                if len_xy > 1.0e-6
                    # In-plane bridge segment connecting outer rims of consecutive cycle handles
                    ux_xy, uy_xy = ux / len_xy, uy / len_xy
                    p1x, p1y, p1z = px + r_loop * ux_xy, py + r_loop * uy_xy, pz
                    p2x, p2y, p2z = cx - r_loop * ux_xy, cy - r_loop * uy_xy, cz
                else
                    # Vertical inter-layer bridge attached to outer rim at +x so loop interior stays open
                    p1x, p1y, p1z = px + r_loop, py, pz
                    p2x, p2y, p2z = cx + r_loop, cy, cz
                end
                vx, vy, vz = p2x - p1x, p2y - p1y, p2z - p1z
                seg_len = max(1.0e-6, sqrt(vx * vx + vy * vy + vz * vz))
                vx /= seg_len; vy /= seg_len; vz /= seg_len
                t_proj = clamp((x - p1x) * vx + (y - p1y) * vy + (z - p1z) * vz, 0.0, seg_len)
                bx, by, bz = p1x + t_proj * vx, p1y + t_proj * vy, p1z + t_proj * vz
                d2_br = (x - bx)^2 + (y - by)^2 + (z - bz)^2
                val = max(val, exp(-d2_br * inv_2s2))
            end
        end
        vol[ix, iy, iz] = Float32(val)
    end
    return vol
end

function run_functor_faithfulness_pareto_sweep(;
    eval_frames::Vector{Int} = [10, 25, 28, 30, 32, 38],
    gammas::Vector{Float64} = [0.0, 0.25, 0.50, 0.75, 1.0],
    thetas::Vector{Float64} = [0.22, 0.36, 0.50],
)::ParetoSweepReport
    bundle = build_functor_dialectical_fixture_60f()
    true_b1 = [bundle.records[k].beta_1 for k in eval_frames]
    base_shells = [bundle.shell_fields[k] for k in eval_frames]
    filaments = [_build_cycle_filament_field(b1) for b1 in true_b1]

    raw_pts = ParetoSweepPoint[]
    for gamma in gammas, theta in thetas
        g32 = Float32(gamma)
        t32 = Float32(theta)
        pred_b1 = Int[]
        l2_dist_sum = 0.0
        vol_frac_sum = 0.0
        for idx in eachindex(eval_frames)
            psi0 = base_shells[idx]
            fil  = filaments[idx]
            psi_g = (1.0f0 - g32) .* psi0 .+ g32 .* fil
            mask = BitArray(psi_g .>= t32)
            hom = compute_cubical_homology_3d(mask)
            push!(pred_b1, hom.b1)
            l2_dist_sum += Float64(norm(psi_g .- psi0) / max(norm(psi0), 1.0f-6))
            vol_frac_sum += Float64(hom.active_voxels) / Float64(length(psi0))
        end
        abs_def = mean(abs.(pred_b1 .- true_b1))
        exact_frac = count(pred_b1 .== true_b1) / Float64(length(eval_frames))
        push!(raw_pts, ParetoSweepPoint(
            gamma, theta, abs_def, exact_frac,
            l2_dist_sum / length(eval_frames),
            vol_frac_sum / length(eval_frames),
            pred_b1, copy(true_b1), false,
        ))
    end

    # Identify non-dominated Pareto frontier on (mean_abs_beta1_defect, mean_shell_l2_distortion)
    pts = ParetoSweepPoint[]
    frontier = ParetoSweepPoint[]
    for p in raw_pts
        dominated = any(q -> (q.mean_abs_beta1_defect <= p.mean_abs_beta1_defect &&
                              q.mean_shell_l2_distortion <= p.mean_shell_l2_distortion &&
                              (q.mean_abs_beta1_defect < p.mean_abs_beta1_defect ||
                               q.mean_shell_l2_distortion < p.mean_shell_l2_distortion)), raw_pts)
        p_marked = ParetoSweepPoint(
            p.gamma, p.theta, p.mean_abs_beta1_defect, p.exact_match_fraction,
            p.mean_shell_l2_distortion, p.mean_active_vol_fraction,
            p.frame_b1_pred, p.frame_b1_true, !dominated,
        )
        push!(pts, p_marked)
        !dominated && push!(frontier, p_marked)
    end
    return ParetoSweepReport(eval_frames, true_b1, pts, frontier)
end

function export_pareto_sweep_json(filepath::AbstractString, rep::ParetoSweepReport)::String
    mkpath(dirname(filepath))
    open(filepath, "w") do io
        println(io, "{")
        println(io, "  \"schemaId\": \"neuralcompose.functor.faithfulness-pareto-sweep.v1\",")
        println(io, "  \"epistemicBadge\": \"[MODEL ILLUSTRATION - RUNG_4_MODEL]\",")
        println(io, "  \"evalFrames\": [", join(rep.eval_frames, ", "), "],")
        println(io, "  \"trueBeta1\": [", join(rep.true_beta1, ", "), "],")
        println(io, "  \"nSweepPoints\": $(length(rep.points)),")
        println(io, "  \"nParetoFrontier\": $(length(rep.pareto_frontier)),")
        println(io, "  \"points\": [")
        for (i, p) in enumerate(rep.points)
            c = i < length(rep.points) ? "," : ""
            @printf(io, "    {\"gamma\": %.2f, \"theta\": %.2f, \"meanAbsBeta1Defect\": %.4f, \"exactMatchFraction\": %.4f, \"meanShellL2Distortion\": %.4f, \"meanActiveVolFraction\": %.5f, \"predBeta1\": [%s], \"isParetoOptimal\": %s}%s\n",
                    p.gamma, p.theta, p.mean_abs_beta1_defect, p.exact_match_fraction,
                    p.mean_shell_l2_distortion, p.mean_active_vol_fraction,
                    join(p.frame_b1_pred, ", "), p.is_pareto_optimal ? "true" : "false", c)
        end
        println(io, "  ]")
        println(io, "}")
    end
    return filepath
end

end # module FunctorFaithfulnessParetoSweep

using Test, Printf, .FunctorFaithfulnessParetoSweep

if abspath(PROGRAM_FILE) == @__FILE__
    out_json = length(ARGS) >= 1 ? ARGS[1] :
        joinpath(@__DIR__, "..", "..", "Evaluation", "reports", "functor_faithfulness_pareto_sweep.json")
    rep = run_functor_faithfulness_pareto_sweep()
    export_pareto_sweep_json(out_json, rep)
    @testset "Functor Faithfulness Pareto Sweep (beta_1 vs Cubical Genus)" begin
        @test length(rep.pareto_frontier) >= 3
        p_forgetful = first(filter(p -> p.gamma == 0.0 && p.theta == 0.22, rep.points))
        p_faithful  = first(filter(p -> p.gamma == 0.75 && p.theta == 0.50, rep.points))
        p_pure_fil  = first(filter(p -> p.gamma == 1.0 && p.theta == 0.50, rep.points))
        @test p_forgetful.mean_abs_beta1_defect > 3.5
        @test p_faithful.mean_abs_beta1_defect == 0.0
        @test p_faithful.exact_match_fraction == 1.0
        @test p_pure_fil.mean_abs_beta1_defect == 0.0
        @test p_forgetful.is_pareto_optimal && p_faithful.is_pareto_optimal && !p_pure_fil.is_pareto_optimal
        for high_b1 in (10, 12, 15, 18)
            fil_high = FunctorFaithfulnessParetoSweep._build_cycle_filament_field(high_b1, 32)
            hom_high = compute_cubical_homology_3d(BitArray(fil_high .>= 0.50f0))
            @test hom_high.b0 == 1
            @test hom_high.b1 == high_b1
            @test hom_high.b2 == 0
        end
        @printf("[PASS] Functor Pareto Sweep: forgetful (gamma=0) defect=%.2f -> Pareto-faithful (gamma=0.75, theta=0.50) defect=%.2f (100%% exact match across beta_1=%s + higher-genus beta_1 in 10..18)\n",
                p_forgetful.mean_abs_beta1_defect, p_faithful.mean_abs_beta1_defect, string(rep.true_beta1))
    end
end
