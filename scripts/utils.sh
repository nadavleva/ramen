#!/bin/bash
# SPDX-FileCopyrightText: The RamenDR authors
# SPDX-License-Identifier: Apache-2.0

# Shared utilities for CSI replication scripts

# Detect container runtime (prefer podman, fallback to docker).
# Override with CONTAINER_RUNTIME=podman|docker
#
# Usage: detect_container_runtime [--prefer-docker]
#   --prefer-docker: use docker when both are available (for PREFER_DOCKER compatibility)
#
# Sets CONTAINER_RUNTIME. Exits on failure.
detect_container_runtime() {
    local prefer_docker=false
    [[ "${1:-}" == "--prefer-docker" ]] && prefer_docker=true

    if [ -n "${CONTAINER_RUNTIME}" ]; then
        if command -v "$CONTAINER_RUNTIME" >/dev/null 2>&1 && $CONTAINER_RUNTIME info >/dev/null 2>&1; then
            return 0
        fi
        echo "CONTAINER_RUNTIME=$CONTAINER_RUNTIME is set but not available or not responsive" >&2
        exit 1
    fi

    if $prefer_docker && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        CONTAINER_RUNTIME="docker"
    elif command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
        CONTAINER_RUNTIME="podman"
    elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        CONTAINER_RUNTIME="docker"
    else
        echo "Neither podman nor docker is available and responsive. Install podman or docker." >&2
        exit 1
    fi
}

# Initialize logging for a script
# Usage: init_logging "script-name" [log-dir]
#   script-name: Name of the script (e.g., setup-csi-replication)
#   log-dir: Optional directory for logs (defaults to Logs/ for root scripts, test/Logs/ for e2e tests)
#
# Sets LOGFILE and enables tee-ing output to both stdout and log file
init_logging() {
    local script_name="$1"
    local log_dir="${2:-}"
    local start_time
    start_time=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Auto-detect log directory based on script context
    if [[ -z "$log_dir" ]]; then
        if [[ $(pwd) == */test ]]; then
            log_dir="test/Logs"
        else
            log_dir="Logs"
        fi
    fi
    
    # Create log directory if it doesn't exist
    mkdir -p "$log_dir"
    
    # Set LOGFILE with timestamp
    LOGFILE="$log_dir/${script_name}-$(date +%Y%m%d-%H%M%S).log"
    
    # Export LOGFILE so subshells can access it
    export LOGFILE
    
    # Print header to console and log file
    {
        echo "╭─────────────────────────────────────────────────────╮"
        echo "│ Script: $script_name"
        echo "│ Started: $start_time"
        echo "│ Logging to: $LOGFILE"
        echo "╰─────────────────────────────────────────────────────╯"
        echo ""
    }
}

# Capture all output (stdout and stderr) to both terminal and log file.
# Strips ANSI escape codes (colors) when writing to the log file for readability.
# Usage: start_capture_logging
#   Call this after init_logging() to enable tee-ing to log file
#
# Note: Must be called after init_logging() has set LOGFILE
start_capture_logging() {
    if [[ -z "$LOGFILE" ]]; then
        echo "ERROR: start_capture_logging called before init_logging()" >&2
        return 1
    fi
    
    # Tee to terminal (with colors) and to file (ANSI codes stripped)
    exec 1> >(tee >(sed 's/\x1b\[[0-9;]*m//g' >> "$LOGFILE"))
    exec 2>&1
}

# Print final log location summary
# Usage: end_logging
end_logging() {
    if [[ -z "$LOGFILE" ]]; then
        return 0
    fi
    
    local end_time
    end_time=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo ""
    echo "╭─────────────────────────────────────────────────────╮"
    echo "│ Execution complete"
    echo "│ Ended: $end_time"
    echo "│ Log saved to: $LOGFILE"
    echo "╰─────────────────────────────────────────────────────╯"
}
