% =========================================================================
% m7_open_interactive_workbench.m
% Interactive MATLAB R2026b + Simulink + M7MultiscaleExplorer HTML Workbench
% Loads all M7.1..M7.8 fixtures into the MATLAB base workspace, executes
% m7_3d_eda_and_simulink_bridge(), opens the 4-panel interactive 3D EDA
% figure with rotate3d enabled, opens the Simulink closed-loop model
% m7_reactor_alara_closed_loop.slx, and links m7_multiscale_explorer.html.
% Pure MATLAB R2026b (zero Java dependencies, zero em/en-dashes).
% =========================================================================

function wb_state = m7_open_interactive_workbench(open_browser, force_regenerate, custom_json_path)
    if nargin < 1 || isempty(open_browser)
        open_browser = true;
    end
    if nargin < 2 || isempty(force_regenerate)
        force_regenerate = false;
    end
    if nargin < 3
        custom_json_path = '';
    end

    fixture_dir = fileparts(mfilename('fullpath'));
    addpath(fixture_dir);

    % Resolve M7Multiscale workbench HTML path without Java
    cand_html_1 = fullfile(fixture_dir, '..', 'workbench', 'm7_multiscale_explorer.html');
    cand_html_2 = '/Users/aurascoper/Developer/M7Multiscale/workbench/m7_multiscale_explorer.html';
    if isfile(cand_html_1)
        d_info = dir(cand_html_1);
        explorer_html_path = fullfile(d_info(1).folder, d_info(1).name);
    else
        explorer_html_path = cand_html_2;
    end

    % 1. Load or execute verification & Simulink/MAT generation bridge
    receipt_json_path = fullfile(fixture_dir, 'm7_matlab_r2026b_verification_receipt.json');
    mat_v7_path  = fullfile(fixture_dir, 'm7_multiscale_3d_eda_fixture_v7.mat');
    mat_v73_path = fullfile(fixture_dir, 'm7_multiscale_3d_eda_fixture_v73.mat');
    slx_path     = fullfile(fixture_dir, 'm7_reactor_alara_closed_loop.slx');
    if ~force_regenerate && isfile(receipt_json_path) && isfile(mat_v7_path) && isfile(mat_v73_path) && isfile(slx_path)
        receipt = jsondecode(fileread(receipt_json_path));
    else
        receipt = m7_3d_eda_and_simulink_bridge();
    end

    % 2. Load MAT v7 fixture variables and push to MATLAB base workspace
    loaded_vars  = load(mat_v7_path);
    default_explorer_json = fullfile(fixture_dir, 'm7_explorer_matlab_r2026b_fixture.json');
    if ~isempty(custom_json_path) && isfile(custom_json_path)
        assignin('base', 'fx_explorer', jsondecode(fileread(custom_json_path)));
    elseif isfile(default_explorer_json)
        assignin('base', 'fx_explorer', jsondecode(fileread(default_explorer_json)));
    end

    assignin('base', 'fx', loaded_vars.fx);
    assignin('base', 'X_snap', loaded_vars.X_snap);
    assignin('base', 'B_att_next', loaded_vars.B_att_next);
    assignin('base', 'controls_fixture', loaded_vars.controls_fixture);
    assignin('base', 'neurospora_4block_state', loaded_vars.neurospora_4block_state);
    assignin('base', 'm7_verification_receipt', receipt);
    assignin('base', 'explorer_html_path', explorer_html_path);
    assignin('base', 'mat_v7_path', mat_v7_path);
    assignin('base', 'mat_v73_path', mat_v73_path);
    assignin('base', 'slx_path', slx_path);

    % 3. Build interactive 4-panel 3D EDA figure
    fx = loaded_vars.fx;
    X_snap = loaded_vars.X_snap;
    t_hr = linspace(0, 24, 24);
    x_m  = double(fx.spatial_cells_3d.cell_centers_x_m(:));

    is_interactive_desktop = ~batchStartupOptionUsed;
    fig_vis = 'off';
    if is_interactive_desktop
        fig_vis = 'on';
    end
    fig = figure('Visible', fig_vis, ...
                 'Name', 'M7MultiscaleExplorer <-> MATLAB R2026b Interactive 3D EDA Workbench', ...
                 'NumberTitle', 'off', ...
                 'Color', [0.06 0.08 0.12], ...
                 'Position', [80, 80, 1440, 860]);

    ax1 = subplot(2, 2, 1, 'Parent', fig);
    [T_grid, X_grid] = meshgrid(t_hr, x_m * 1e3);
    surf(ax1, T_grid, X_grid, X_snap, 'EdgeColor', [0.2 0.85 0.55], 'FaceAlpha', 0.88);
    colormap(ax1, parula);
    set(ax1, 'Color', [0.09 0.12 0.18], 'XColor', [0.9 0.92 0.95], ...
             'YColor', [0.9 0.92 0.95], 'ZColor', [0.9 0.92 0.95], 'FontSize', 10);
    xlabel(ax1, 'Mission Time t (hr)');
    ylabel(ax1, 'Axial Pool Depth x (mm)');
    zlabel(ax1, 'Biomass (kg/m^3)');
    title(ax1, 'M7.1-M7.5: 3D Multi-Pool Biofilm & Neurospora Syncytium', 'Color', [0.35 0.95 0.65]);
    view(ax1, [-38, 26]);
    grid(ax1, 'on');

    ax2 = subplot(2, 2, 2, 'Parent', fig);
    r_vec = linspace(1.0, 15.0, 25);
    z_vec = linspace(0.0, 0.12, 25);
    [R_g, Z_g] = meshgrid(r_vec, z_vec * 100.0);
    D_surface_mGy_hr = 12.5 .* ((1.0 ./ R_g).^2) .* exp(-18.5 .* (Z_g / 100.0));
    surf(ax2, R_g, Z_g, D_surface_mGy_hr, 'EdgeColor', 'none', 'FaceAlpha', 0.90);
    set(ax2, 'Color', [0.09 0.12 0.18], 'XColor', [0.9 0.92 0.95], ...
             'YColor', [0.9 0.92 0.95], 'ZColor', [0.9 0.92 0.95], 'FontSize', 10);
    xlabel(ax2, 'Kilopower Standoff r (m)');
    ylabel(ax2, 'Composite Shielding z (cm)');
    zlabel(ax2, 'Dose Rate (mGy/hr)');
    title(ax2, 'M7.6: Health-Physics ALARA (1/r^2, Shielding + Melanin)', 'Color', [0.35 0.95 0.65]);
    view(ax2, [42, 28]);
    grid(ax2, 'on');

    ax3 = subplot(2, 2, 3, 'Parent', fig);
    pools = 1:8;
    nc = loaded_vars.neurospora_4block_state;
    plot3(ax3, pools, double(nc.S_mol_m3(:))', double(nc.B_kg_m3(:))', '-o', ...
          'Color', [0.22 0.83 0.93], 'LineWidth', 2.2, 'MarkerFaceColor', [0.22 0.83 0.93]);
    set(ax3, 'Color', [0.09 0.12 0.18], 'XColor', [0.9 0.92 0.95], ...
             'YColor', [0.9 0.92 0.95], 'ZColor', [0.9 0.92 0.95], 'FontSize', 10);
    xlabel(ax3, 'Vogel Chamber Index (1..8)');
    ylabel(ax3, 'Sucrose S_i (mol/m^3)');
    zlabel(ax3, 'Syncytial Biomass B_i (kg/m^3)');
    title(ax3, '4-Block Neurospora 8-Pool Trajectory (beta_1 = 3)', 'Color', [0.35 0.95 0.65]);
    view(ax3, [-32, 24]);
    grid(ax3, 'on');

    ax4 = subplot(2, 2, 4, 'Parent', fig);
    plot3(ax4, double(nc.M_frq(:))', double(nc.F_c(:))', double(nc.F_n(:))', '-s', ...
          'Color', [0.66 0.33 0.97], 'LineWidth', 2.2, 'MarkerFaceColor', [0.66 0.33 0.97]);
    set(ax4, 'Color', [0.09 0.12 0.18], 'XColor', [0.9 0.92 0.95], ...
             'YColor', [0.9 0.92 0.95], 'ZColor', [0.9 0.92 0.95], 'FontSize', 10);
    xlabel(ax4, 'frq mRNA M_{frq}');
    ylabel(ax4, 'Cytosolic FRQ F_c');
    zlabel(ax4, 'Nuclear FRQ F_n');
    title(ax4, 'Block 1 Circadian Oscillator Phase Portrait (ode15s)', 'Color', [0.35 0.95 0.65]);
    view(ax4, [35, 25]);
    grid(ax4, 'on');

    if is_interactive_desktop
        rotate3d(fig, 'on');
        if isfile(slx_path)
            try
                open_system(slx_path);
            catch
            end
        end
        if open_browser && isfile(explorer_html_path)
            try
                web(explorer_html_path, '-browser');
            catch
            end
        end
    else
        close(fig);
    end

    wb_state = struct( ...
        'all_checks_passed', receipt.all_checks_passed, ...
        'explorer_html_path', explorer_html_path, ...
        'fixture_dir', fixture_dir, ...
        'mat_v7_path', mat_v7_path, ...
        'mat_v73_path', mat_v73_path, ...
        'slx_path', slx_path, ...
        'n_pool', double(nc.n_pool) ...
    );
    fprintf('M7_INTERACTIVE_WORKBENCH_READY: all_checks_passed=%d, html=%s\n', ...
            wb_state.all_checks_passed, wb_state.explorer_html_path);
end
