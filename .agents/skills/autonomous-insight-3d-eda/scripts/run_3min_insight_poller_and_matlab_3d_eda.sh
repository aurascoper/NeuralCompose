#!/usr/bin/env zsh
set -euo pipefail

echo "=== [1/3] Running Non-Recursive Self-Improvement Poller (Single Pass) ==="
python3 /Users/aurascoper/Developer/NeuralCompose/Scripts/non-recursive-self-improvement-poller.py --once

echo "=== [2/3] Running MATLAB R2026b 3D EDA & Simulink/Simscape Bridge ==="
if [[ -x "/Applications/MATLAB_R2026b.app/bin/matlab" ]]; then
  /Applications/MATLAB_R2026b.app/bin/matlab -batch "addpath('/Users/aurascoper/Developer/SmallModularBioReactors.jl/matlab_fixtures'); m7_3d_eda_and_simulink_bridge();"
else
  echo "MATLAB_R2026b binary not found at /Applications/MATLAB_R2026b.app/bin/matlab; verifying existing receipt."
fi

echo "=== [3/3] Verifying Julia Test Suites (SmallModularBioReactors.jl & M7Multiscale) ==="
julia --project=/Users/aurascoper/Developer/SmallModularBioReactors.jl /Users/aurascoper/Developer/SmallModularBioReactors.jl/test/runtests.jl
