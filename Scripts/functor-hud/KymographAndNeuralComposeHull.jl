#!/usr/bin/env julia
# ==============================================================================
# KymographAndNeuralComposeHull.jl
# 1. Part A: 2D (r, t) Kymograph vs. 3D Paired-Isosurface Audit on the 60-Frame
#    Revision-0 Cycle (f00..f59, 32^3 grid, 16.0 m cube, dx = 0.5 m, b = 0.17).
#    Quantifies cube-boundary clipping ("circular window" artifact) and plots
#    the topological birth/death of the 8.00 umol/L core and 160 C core.
# 2. Part B: NeuralCompose 60-Frame 3D Phase-Space Attractor & Dialectical
#    Memory Hull (Fast Wireframe Drive vs. Slow Consolidated Memory Core +
#    Hollow Habituation-Plasticity Shell) with MRC-2014 + ChimeraX .cxc export.
# Epistemic Boundary: [MODEL ILLUSTRATION - RUNG_4_MODEL]
# Dependencies: Julia Base, LinearAlgebra, Statistics, Printf, Test stdlibs only.
# Strictly zero em-dashes and zero en-dashes.
# ==============================================================================

module KymographAndNeuralComposeHull

using LinearAlgebra
using Statistics
using Printf
using Test

export PrescribedCycleAudit, NeuralComposeFrameMetrics
export audit_prescribed_60frame_kymograph, render_ascii_kymograph
export simulate_neural_compose_dialectic_60f, export_neural_compose_chimerax_series

# ------------------------------------------------------------------------------
# Part A: 2D (r, t) Kymograph & Cube-Clipping Audit of the 60-Frame R0 Cycle
# ------------------------------------------------------------------------------

struct PrescribedCycleAudit
    n_frames::Int
    phases::Vector{Float64}
    times_min::Vector{Float64}
    radii_m::Vector{Float64}
    temp_core_max_C::Vector{Float64}
    hyd_core_min::Vector{Float64}
    poly_max_umol_L::Vector{Float64}
    poly_kymograph_rt::Matrix{Float64}      # (n_radii, n_frames)
    clip_fraction_3p20::Vector{Float64}     # Fraction of 3.20 shell hitting cube walls
    core_8p00_volume_m3::Vector{Float64}    # Volume of 8.00 umol/L inner core
    hysteresis_area_T_poly::Float64         # Loop area in (Mean T, Max Polymer) plane
end

"""
    _prescribed_r0_fields(r_m::Float64, z_m::Float64, p::Float64) -> NamedTuple

Evaluates the closed-form Revision-0 prescribed radial-axial fields at phase
`p in [0, 1)` matching the Slide 12 keyframe anchors:
  - `f00` (`p = 0.000`): T_max = 90.9 C,  Hyd_min = 0.753, Poly_max = 10.08 umol/L
  - `f20` (`p = 0.333`): T_max = 172.2 C, Hyd_min = 0.517, Poly_max = 14.45 umol/L
  - `f40` (`p = 0.667`): T_max = 94.9 C,  Hyd_min = 0.753, Poly_max = 5.72 umol/L
"""
function _prescribed_r0_fields(r_m::Float64, z_m::Float64, p::Float64)
    # Smooth periodic pulse peaking near p = 1/3 (f20) and relaxing at p = 2/3 (f40)
    pulse_T = exp(-0.5 * ((sin(pi * (p - 1.0 / 3.0))) / 0.28)^2)
    T_peak  = 90.9 + (172.2 - 90.9) * pulse_T + 4.0 * sin(2.0 * pi * p)
    temp_C  = 26.7 + (T_peak - 26.7) * exp(-(r_m / 4.2)^2) * (1.0 + 0.08 * (z_m / 8.0))

    hyd_min = 0.753 - (0.753 - 0.517) * pulse_T
    hyd_val = 0.930 - (0.930 - hyd_min) * exp(-(r_m / 3.8)^2)

    # Polymer yield lives in the hollow clay halo shell (r ~ 5.6 m), destroyed at r -> 0
    # and phase-lagged behind temperature (10.08 at f00, peaks at f20 with 14.45, drops to 5.72 at f40)
    poly_amp = 10.085 + (4.365 / (sqrt(3.0) / 2.0)) * sin(2.0 * pi * p)
    shell_profile = ((r_m / 5.6)^2) * exp(1.0 - (r_m / 5.6)^2)
    poly_umol = poly_amp * shell_profile

    return (temp_C = temp_C, hyd = hyd_val, poly_umol = poly_umol)
end

"""
    audit_prescribed_60frame_kymograph(; n_frames=60, n_grid=32, dx_m=0.5) -> PrescribedCycleAudit

Computes the 2D `(r, t)` kymograph on the 60-frame series and measures what fraction
of the `3.20 umol/L` outer wireframe cage is artificially clipped by the 6 faces
of the `16.0 m x 16.0 m x 16.0 m` bounding box.
"""
function audit_prescribed_60frame_kymograph(;
    n_frames::Int = 60,
    n_grid::Int = 32,
    dx_m::Float64 = 0.5,
)::PrescribedCycleAudit
    half_box = 0.5 * n_grid * dx_m # 8.0 m
    xs = range(-half_box + 0.5 * dx_m, half_box - 0.5 * dx_m; length = n_grid)
    radii = collect(range(0.0, 10.0; length = 25))

    phases = [Float64(f) / Float64(n_frames) for f in 0:(n_frames - 1)]
    times_min = [180.0 * p for p in phases]

    temp_core_max = zeros(Float64, n_frames)
    hyd_core_min  = zeros(Float64, n_frames)
    poly_max      = zeros(Float64, n_frames)
    kymo_rt       = zeros(Float64, length(radii), n_frames)
    clip_frac     = zeros(Float64, n_frames)
    core_8_vol    = zeros(Float64, n_frames)
    voxel_vol     = dx_m^3

    for (f_idx, p) in enumerate(phases)
        # 1. Fill 2D (r, t) Kymograph along midplane z = 0
        for (r_idx, r) in enumerate(radii)
            st = _prescribed_r0_fields(r, 0.0, p)
            kymo_rt[r_idx, f_idx] = st.poly_umol
        end

        # 2. Evaluate 32^3 grid for clipping and threshold volumes
        t_max = -Inf
        h_min = Inf
        p_max = -Inf
        n_shell_vox = 0
        n_boundary_clipped = 0
        n_core8_vox = 0

        for iz in 1:n_grid, iy in 1:n_grid, ix in 1:n_grid
            x, y, z = xs[ix], xs[iy], xs[iz]
            r = sqrt(x * x + y * y + z * z)
            st = _prescribed_r0_fields(r, z, p)
            st.temp_C > t_max && (t_max = st.temp_C)
            st.hyd < h_min    && (h_min = st.hyd)
            st.poly_umol > p_max && (p_max = st.poly_umol)

            if st.poly_umol >= 3.20
                n_shell_vox += 1
                if ix == 1 || ix == n_grid || iy == 1 || iy == n_grid || iz == 1 || iz == n_grid
                    n_boundary_clipped += 1
                end
            end
            if st.poly_umol >= 8.00
                n_core8_vox += 1
            end
        end

        temp_core_max[f_idx] = t_max
        hyd_core_min[f_idx]  = h_min
        poly_max[f_idx]      = p_max
        clip_frac[f_idx]     = n_shell_vox > 0 ? (Float64(n_boundary_clipped) / Float64(n_shell_vox)) : 0.0
        core_8_vol[f_idx]    = n_core8_vox * voxel_vol
    end

    # Signed shoelace hysteresis area in (T_max, Poly_max) phase plane over the 60-frame cycle
    area_sum = 0.0
    for i in 1:n_frames
        j = (i % n_frames) + 1
        area_sum += 0.5 * (temp_core_max[i] * poly_max[j] - temp_core_max[j] * poly_max[i])
    end

    return PrescribedCycleAudit(
        n_frames,
        phases,
        times_min,
        radii,
        temp_core_max,
        hyd_core_min,
        poly_max,
        kymo_rt,
        clip_frac,
        core_8_vol,
        abs(area_sum),
    )
end

"""
    render_ascii_kymograph(audit::PrescribedCycleAudit; io::IO = stdout)

Prints the static 2D `(r, t)` Kymograph of Polymer Yield across all 60 frames,
marking the `3.20 umol/L` outer wireframe contour (`.`) and the `8.00 umol/L`
inner core contour (`#`), plus the vertical cube-wall clipping line at `r = 8.0 m`.
"""
function render_ascii_kymograph(audit::PrescribedCycleAudit; io::IO = stdout)
    println(io, "================================================================================")
    println(io, "STATIC 2D (r, t) KYMOGRAPH OF 60-FRAME POLYMER YIELD (REPLACES 60-FRAME 3D LOOP)")
    println(io, "Legend: ' ' < 3.20 | '.' 3.20..8.00 (Wireframe Cage) | '#' >= 8.00 (Inner Core)")
    println(io, "        Horizontal axis: Frame f00..f59 (0..180 min) | Vertical: Radius r [m]")
    println(io, "================================================================================")
    println(io, "  r [m] | f00                 f20                 f40                f59")
    println(io, "--------+------------------------------------------------------------")
    for (r_idx, r) in enumerate(audit.radii_m)
        row_chars = Vector{Char}(undef, audit.n_frames)
        for f in 1:audit.n_frames
            val = audit.poly_kymograph_rt[r_idx, f]
            row_chars[f] = val >= 8.00 ? '#' : (val >= 3.20 ? '.' : ' ')
        end
        wall_tag = isapprox(r, 8.0; atol = 0.21) ? " <-- 16m Cube Wall Clipping (r=8m)" : ""
        @printf(io, " %6.2f | %s%s\n", r, String(row_chars), wall_tag)
    end
    println(io, "--------+------------------------------------------------------------")
    @printf(io, "Keyframes: f00 Poly_max = %5.2f | f20 Poly_max = %5.2f | f40 Poly_max = %5.2f umol/L\n",
            audit.poly_max_umol_L[1], audit.poly_max_umol_L[21], audit.poly_max_umol_L[41])
    @printf(io, "8.00 Core: f00 Vol = %6.1f m^3 | f20 Vol = %6.1f m^3 | f40 Vol = %6.1f m^3 (VANISHED)\n",
            audit.core_8p00_volume_m3[1], audit.core_8p00_volume_m3[21], audit.core_8p00_volume_m3[41])
    @printf(io, "Cube-Wall Clipping on 3.20 Cage at f20: %.1f%% of shell boundary voxels clipped by box\n",
            100.0 * audit.clip_fraction_3p20[21])
    @printf(io, "Thermal-Polymer Hysteresis Loop Area:   %.2f (deg C * umol/L)\n",
            audit.hysteresis_area_T_poly)
end

# ------------------------------------------------------------------------------
# Part B: NeuralCompose 60-Frame 3D Phase-Space Attractor & Dialectical Memory
# ------------------------------------------------------------------------------

struct NeuralComposeFrameMetrics
    frame_idx::Int
    time_s::Float64
    z_eeg::NTuple{3, Float64}           # (Valence_Asym, Arousal_Slope, Coherence_PLV)
    mu_fast::NTuple{3, Float64}         # Fast working-memory centroid (Wireframe)
    mu_slow::NTuple{3, Float64}         # Slow consolidated centroid (Solid Core)
    mahalanobis_tension::Float64        # D_M(mu_fast, mu_slow; Sigma_slow)
    principal_axis_angle_deg::Float64   # 3D covariance rotation angle (invisible in 1D!)
    overhang_escape_fraction::Float64   # Vol(Wireframe \ Core) / Vol(Wireframe)
    hollow_shell_volume_fraction::Float64 # Fraction of grid in active plasticity shell
end

function _write_mrc2014_32(filepath::AbstractString, vol::Array{Float32, 3}, voxel_size::Float32, label_str::AbstractString)
    nx, ny, nz = size(vol)
    dmin, dmax = extrema(vol)
    dmean = mean(vol)
    drms  = std(vol; corrected = false)

    open(filepath, "w") do io
        write(io, htol(Int32(nx)), htol(Int32(ny)), htol(Int32(nz)))
        write(io, htol(Int32(2))) # MODE 2 (Float32)
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
        # Center origin at (-half, -half, -half) so (0,0,0) is phase-space origin
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

"""
    simulate_neural_compose_dialectic_60f(; n_frames=60, dt_s=0.25, tau_fast_s=1.2, tau_slow_s=8.0)

Simulates a 60-frame `NeuralCompose` 3D phase-space stream across three regime phases:
  - Frames 1..20:  Baseline alpha-coherent rest attractor near origin
  - Frames 21..40: Cognitive/musical novelty excursion (rotates 3D covariance axis
                   and inflates fast wireframe outside slow memory core)
  - Frames 41..60: Memory consolidation & recovery (slow core migrates partially
                   toward excursion while fast drive returns, creating hysteresis)
Returns `(metrics, fast_fields, slow_fields, shell_fields)`.
"""
function simulate_neural_compose_dialectic_60f(;
    n_frames::Int = 60,
    dt_s::Float64 = 0.25,
    tau_fast_s::Float64 = 1.2,
    tau_slow_s::Float64 = 8.0,
    n_grid::Int = 32,
)
    mu_f = zeros(Float64, 3)
    mu_s = zeros(Float64, 3)
    Sig_f = Matrix{Float64}(Diagonal([0.55, 0.22, 0.18]))
    Sig_s = Matrix{Float64}(Diagonal([0.55, 0.22, 0.18]))

    metrics = Vector{NeuralComposeFrameMetrics}(undef, n_frames)
    fast_fields  = [zeros(Float32, n_grid, n_grid, n_grid) for _ in 1:n_frames]
    slow_fields  = [zeros(Float32, n_grid, n_grid, n_grid) for _ in 1:n_frames]
    shell_fields = [zeros(Float32, n_grid, n_grid, n_grid) for _ in 1:n_frames]

    coords = range(-3.5, 3.5; length = n_grid)

    for k in 1:n_frames
        t = (k - 1) * dt_s
        # 3D EEG State Stream: (Valence_Asym, Arousal_Slope, Frontotemporal_PLV)
        z = if k <= 20
            # Phase 1: Baseline rest oscillation aligned with axis 1
            [0.85 * cos(0.7 * t), 0.20 * sin(0.7 * t), 0.15 * cos(1.4 * t)]
        elseif k <= 40
            # Phase 2: Cognitive/musical novelty drive (tilts into diagonal y-z plane)
            s = (k - 20) / 20.0
            [0.25 * cos(1.2 * t), 1.85 * sin(0.5 * pi * s) + 0.55 * sin(1.8 * t), 1.65 * sin(0.5 * pi * s) + 0.45 * cos(1.8 * t)]
        else
            # Phase 3: Post-stimulus consolidation & return
            s = (k - 40) / 20.0
            [-0.4 * (1.0 - s) + 0.4 * cos(0.9 * t), 0.6 * exp(-2.0 * s) + 0.3 * sin(0.9 * t), 0.5 * exp(-1.5 * s)]
        end

        # Coupled two-timescale tensor updates
        alpha_f = dt_s / (tau_fast_s + dt_s)
        alpha_s = dt_s / (tau_slow_s + dt_s)

        diff_f = z .- mu_f
        mu_f  .= mu_f .+ alpha_f .* diff_f
        Sig_f .= (1.0 - alpha_f) .* Sig_f .+ alpha_f .* (diff_f * diff_f' .+ Matrix{Float64}(Diagonal([0.32, 0.18, 0.16])))

        diff_s = mu_f .- mu_s
        mu_s  .= mu_s .+ alpha_s .* diff_s
        Sig_s .= (1.0 - alpha_s) .* Sig_s .+ alpha_s .* Sig_f

        inv_Sig_f = inv(Symmetric(Sig_f))
        inv_Sig_s = inv(Symmetric(Sig_s))

        # 1. Mahalanobis tension between fast wireframe centroid and slow memory centroid
        d_ten = sqrt(dot(diff_s, inv_Sig_s * diff_s))

        # 2. 3D Principal-Axis Rotation Angle between fast and slow covariance ellipsoids
        ef = eigen(Symmetric(Sig_f))
        es = eigen(Symmetric(Sig_s))
        v1_f = ef.vectors[:, end]
        v1_s = es.vectors[:, end]
        cos_ang = clamp(abs(dot(v1_f, v1_s)), 0.0, 1.0)
        ang_deg = rad2deg(acos(cos_ang))

        # 3. Evaluate 3D Phase-Space Density Fields & Overhang Escape Ratio
        n_fast_vox   = 0
        n_escape_vox = 0
        n_shell_vox  = 0

        F_vol = fast_fields[k]
        S_vol = slow_fields[k]
        P_vol = shell_fields[k]

        for iz in 1:n_grid, iy in 1:n_grid, ix in 1:n_grid
            pt = SVector3(coords[ix], coords[iy], coords[iz])
            df2 = _quad_form(pt, mu_f, inv_Sig_f)
            ds2 = _quad_form(pt, mu_s, inv_Sig_s)

            rho_fast = exp(-0.5 * df2)
            rho_slow = exp(-0.5 * ds2)
            # Dialectical Plasticity Shell: High fast activation * habituation suppression at slow core
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

        escape_frac = n_fast_vox > 0 ? (Float64(n_escape_vox) / Float64(n_fast_vox)) : 0.0
        shell_frac  = Float64(n_shell_vox) / Float64(n_grid^3)

        metrics[k] = NeuralComposeFrameMetrics(
            k,
            t,
            (z[1], z[2], z[3]),
            (mu_f[1], mu_f[2], mu_f[3]),
            (mu_s[1], mu_s[2], mu_s[3]),
            d_ten,
            ang_deg,
            escape_frac,
            shell_frac,
        )
    end

    return (
        metrics = metrics,
        fast_fields = fast_fields,
        slow_fields = slow_fields,
        shell_fields = shell_fields,
    )
end

@inline function SVector3(x::Float64, y::Float64, z::Float64)
    return (x, y, z)
end

@inline function _quad_form(pt::NTuple{3, Float64}, mu::Vector{Float64}, A::AbstractMatrix{Float64})::Float64
    dx = pt[1] - mu[1]
    dy = pt[2] - mu[2]
    dz = pt[3] - mu[3]
    return dx * (A[1, 1] * dx + A[1, 2] * dy + A[1, 3] * dz) +
           dy * (A[2, 1] * dx + A[2, 2] * dy + A[2, 3] * dz) +
           dz * (A[3, 1] * dx + A[3, 2] * dy + A[3, 3] * dz)
end

"""
    export_neural_compose_chimerax_series(out_dir, sim_res) -> String

Writes the 60-frame `.mrc` series (`fast_wireframe_fXX.mrc`, `slow_core_fXX.mrc`,
`plasticity_shell_fXX.mrc`), a 3D EEG trajectory `.bild` file, and a synchronized
60-frame ChimeraX 1.12 command script (`neural_compose_dialectical_60f.cxc`).
"""
function export_neural_compose_chimerax_series(out_dir::AbstractString, sim_res)::String
    mkpath(out_dir)
    n_frames = length(sim_res.metrics)
    voxel_sz = Float32(7.0 / 32.0)

    for k in 1:n_frames
        tag = @sprintf("f%02d", k - 1)
        _write_mrc2014_32(
            joinpath(out_dir, "neural_fast_drive_$(tag).mrc"),
            sim_res.fast_fields[k],
            voxel_sz,
            "[MODEL ILLUSTRATION - RUNG_4_MODEL] NeuralCompose Fast Sensory Drive (Wire)",
        )
        _write_mrc2014_32(
            joinpath(out_dir, "neural_slow_core_$(tag).mrc"),
            sim_res.slow_fields[k],
            voxel_sz,
            "[MODEL ILLUSTRATION - RUNG_4_MODEL] NeuralCompose Slow Memory Attractor (Core)",
        )
        _write_mrc2014_32(
            joinpath(out_dir, "neural_plasticity_shell_$(tag).mrc"),
            sim_res.shell_fields[k],
            voxel_sz,
            "[MODEL ILLUSTRATION - RUNG_4_MODEL] NeuralCompose Habituation-Plasticity Shell",
        )
    end

    # Export 3D Phase-Space Trajectory & Coordinate Axes to .bild
    bild_path = joinpath(out_dir, "neural_phase_trajectory.bild")
    open(bild_path, "w") do io
        println(io, ".comment [MODEL ILLUSTRATION - RUNG_4_MODEL] NeuralCompose 3D Phase-Space Axes & Trajectory")
        println(io, ".color 0.58 0.64 0.72")
        println(io, ".arrow -3.2 0.0 0.0 3.2 0.0 0.0 0.03 0.08 0.92")
        println(io, ".arrow 0.0 -3.2 0.0 0.0 3.2 0.0 0.03 0.08 0.92")
        println(io, ".arrow 0.0 0.0 -3.2 0.0 0.0 3.2 0.03 0.08 0.92")
        println(io, ".color 0.22 0.74 0.97")
        for k in 1:(n_frames - 1)
            p1 = sim_res.metrics[k].mu_fast
            p2 = sim_res.metrics[k + 1].mu_fast
            d2 = (p2[1] - p1[1])^2 + (p2[2] - p1[2])^2 + (p2[3] - p1[3])^2
            d2 < 1.0e-6 && continue
            @printf(io, ".cylinder %.4f %.4f %.4f %.4f %.4f %.4f 0.045\n",
                    p1[1], p1[2], p1[3], p2[1], p2[2], p2[3])
        end
    end

    cxc_path = joinpath(out_dir, "neural_compose_dialectical_60f.cxc")
    open(cxc_path, "w") do io
        println(io, "# UCSF ChimeraX 1.12 Synchronized 60-Frame Phase-Space Attractor Script")
        println(io, "windowsize 1600 960")
        println(io, "set bgColor #0b0f19")
        println(io, "open neural_fast_drive_f*.mrc vseries true")
        println(io, "open neural_slow_core_f*.mrc vseries true")
        println(io, "open neural_plasticity_shell_f*.mrc vseries true")
        println(io, "open neural_phase_trajectory.bild")
        println(io, "volume #1 style mesh level 0.30 color #38bdf8 squareMesh true capFaces false")
        println(io, "volume #2 style surface level 0.45 color #a855f7 transparency 0.25")
        println(io, "volume #3 style mesh level 0.22 color #34d399 squareMesh true capFaces false")
        println(io, "lighting soft")
        println(io, "view")
        println(io, "vseries play #1-3 loop true maxFrameRate 15")
    end
    return cxc_path
end

end # module KymographAndNeuralComposeHull

# ==============================================================================
# Self-Contained Verification of Both Parts (Kymograph vs. NeuralCompose Hull)
# ==============================================================================
using Test
using Printf
using .KymographAndNeuralComposeHull

if abspath(PROGRAM_FILE) == @__FILE__
    @testset "Part A (60-Frame R0 Kymograph) & Part B (NeuralCompose 3D Hull)" begin
        # 1. Verify Part A: 60-Frame R0 Kymograph & Cube-Clipping Artifact
        audit = audit_prescribed_60frame_kymograph()
        render_ascii_kymograph(audit)

        # At f00 (index 1) and f20 (index 21), 8.00 umol/L core volume > 0;
        # at f40 (index 41, p = 0.667), poly_max < 8.00 so inner core volume == 0!
        @test audit.core_8p00_volume_m3[1] > 0.0
        @test audit.core_8p00_volume_m3[21] > audit.core_8p00_volume_m3[1]
        @test audit.core_8p00_volume_m3[41] == 0.0
        # Verify cube-boundary clipping occurs on the 3.20 umol/L cage
        @test audit.clip_fraction_3p20[21] > 0.05
        @test audit.hysteresis_area_T_poly > 100.0

        # 2. Verify Part B: NeuralCompose 60-Frame 3D Phase-Space Attractor
        sim = simulate_neural_compose_dialectic_60f()
        m_rest = sim.metrics[15]
        m_surg = sim.metrics[32]
        m_rec  = sim.metrics[58]

        println("\n================================================================================")
        println("NEURALCOMPOSE 60-FRAME 3D PHASE-SPACE ATTRACTOR DIAGNOSTICS")
        println("================================================================================")
        for m in (m_rest, m_surg, m_rec)
            @printf("  Frame f%02d (t=%5.2fs) | D_M Tension = %5.2f | 3D Axis Tilt = %5.1f deg | Wireframe Escape = %5.1f%% | Hollow Shell = %5.2f%%\n",
                    m.frame_idx - 1, m.time_s, m.mahalanobis_tension,
                    m.principal_axis_angle_deg, 100.0 * m.overhang_escape_fraction,
                    100.0 * m.hollow_shell_volume_fraction)
        end

        # During novelty excursion (Frame 32), wireframe escapes slow core (> 40%)
        # and 3D principal covariance axis rotates relative to slow memory (> 15 deg)
        @test m_surg.overhang_escape_fraction > m_rest.overhang_escape_fraction + 0.30
        @test m_surg.mahalanobis_tension > m_rest.mahalanobis_tension + 0.80
        @test m_surg.principal_axis_angle_deg > 15.0

        # Verify MRC-2014 + .bild + .cxc export
        tmp_dir = mktempdir()
        cxc_file = export_neural_compose_chimerax_series(tmp_dir, sim)
        @test isfile(cxc_file)
        @test filesize(joinpath(tmp_dir, "neural_fast_drive_f00.mrc")) == 1024 + 4 * 32^3
        rm(tmp_dir; recursive = true, force = true)
    end
    println("[PASS] Both Part A (2D Kymograph Audit) and Part B (NeuralCompose 3D Hull) verified.")
end
