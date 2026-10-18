#!/bin/bash
# Shared settings for the aegnux dzn scripts. Override any of them in the environment.
# Nothing here points at a personal path; defaults follow the aegnux layout.

AEGNUX_HOME="${AEGNUX_HOME:-$HOME/.local/share/aegnux}"
WINE_BIN_DIR="${WINE_BIN_DIR:-$AEGNUX_HOME/runner/bin}"
WINEPREFIX="${WINEPREFIX:-$AEGNUX_HOME/wineprefix}"
AE_DIR="${AE_DIR:-$AEGNUX_HOME/AE}"
MESA_SRC="${MESA_SRC:-$HOME/src/mesa-25.2.8}"
MESA_BUILD="${MESA_BUILD:-$MESA_SRC/build}"
DZN_PREFIX="${DZN_PREFIX:-$AEGNUX_HOME/dzn}"
AEGNUX_LAYER_DIR="${AEGNUX_LAYER_DIR:-$AEGNUX_HOME/layer}"
AEGNUX_LOG_DIR="${AEGNUX_LOG_DIR:-$AEGNUX_HOME/logs}"
AEGNUX_TEST_DIR="${AEGNUX_TEST_DIR:-$AEGNUX_HOME/tests}"

export AEGNUX_HOME WINE_BIN_DIR WINEPREFIX AE_DIR MESA_SRC MESA_BUILD DZN_PREFIX
export AEGNUX_LAYER_DIR AEGNUX_LOG_DIR AEGNUX_TEST_DIR

# Environment for running Wine, DXVK and dzn together (WSLg display variables are
# taken from the caller's environment).
aegnux_env() {
    export PATH="$WINE_BIN_DIR:$PATH"
    export WINEPREFIX
    export VK_ICD_FILENAMES="$DZN_PREFIX/share/vulkan/icd.d/dzn_icd.x86_64.json"
    export VK_LAYER_PATH="$AEGNUX_LAYER_DIR"
    export VK_LOADER_LAYERS_ENABLE=VK_LAYER_AEGNUX_apiversion
    export WINEDLLOVERRIDES="mscoree,mshtml="
    export WINEDEBUG=err+module,err+d3d,err+dxgi,err+vulkan,warn+d3d,err+seh
}