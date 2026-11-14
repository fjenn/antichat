# shellcheck shell=bash
# Source me: puts the pinned toolchain first on PATH (environment.md §3 step 3).
_ac_root="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
export ANTICHAT_ROOT="$_ac_root"
export ANTICHAT_TOOLS_HOME="${ANTICHAT_TOOLS_HOME:-$HOME/.local/share/antichat-tools}"
export MISE_DATA_DIR="$ANTICHAT_TOOLS_HOME/mise"
export MISE_CONFIG_DIR="$ANTICHAT_TOOLS_HOME/mise-config"
export MISE_CACHE_DIR="$ANTICHAT_TOOLS_HOME/mise-cache"
export MISE_YES=1
export UV_PROJECT_ENVIRONMENT="$_ac_root/tools/.venv"
export PATH="$_ac_root/.tools/bin:$_ac_root/tools/.venv/bin:$MISE_DATA_DIR/shims:$ANTICHAT_TOOLS_HOME/bin:$PATH"
unset _ac_root
