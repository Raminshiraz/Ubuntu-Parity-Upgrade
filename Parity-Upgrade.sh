#!/bin/bash
set -euo pipefail

# ============================================================
# Ubuntu Production Upgrade Manager
# Simulate approach: simulate upgrade on Prod, install exact
# post-upgrade state on Dev for testing.
#
# Workflow:
#   Prod:  baseline → simulate → (copy bundle .tar.gz to Dev)
#   Dev:   apply-dev → verify-dev
#   Prod:  apply-prod → verify-prod
#
# NOTE: This script does not include a software rollback.
#       Always take a VM-level snapshot before running apply-prod.
# ============================================================

if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run with sudo"
    exit 1
fi

export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/.upgrade_config"

# Dpkg options to prevent interactive conffile prompts from hanging
# the progress bar. confdef: use default if config unmodified;
# confold: keep user's version if config was modified.
DPKG_CONF_OPTS=(-o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")

# Apt output log — set to a real file by apply-dev / apply-prod.
# Wrapper functions tee all apt output here so errors are
# recoverable even when the progress bar drops them.
APT_OUTPUT_LOG="/dev/null"

# ----------------------------------------------------------
# Verbose flag & color setup
# ----------------------------------------------------------

VERBOSE=false
_ORIG_ARGS=()
for _arg in "$@"; do
    case "$_arg" in
        -v|--verbose) VERBOSE=true ;;
        *) _ORIG_ARGS+=("$_arg") ;;
    esac
done
set -- "${_ORIG_ARGS[@]+"${_ORIG_ARGS[@]}"}"

# Colors — use $'...' so escape bytes are real, not literal strings.
if [ -t 1 ]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RED=$'\033[0;31m'
    C_GREEN=$'\033[0;32m'
    C_YELLOW=$'\033[0;33m'
    C_BLUE=$'\033[0;34m'
    C_MAGENTA=$'\033[0;35m'
    C_CYAN=$'\033[0;36m'
    C_WHITE=$'\033[0;37m'
    C_BOLD_CYAN=$'\033[1;36m'
    C_BOLD_GREEN=$'\033[1;32m'
    C_BOLD_RED=$'\033[1;31m'
    C_BOLD_YELLOW=$'\033[1;33m'
    C_BOLD_BLUE=$'\033[1;34m'
    C_BOLD_MAGENTA=$'\033[1;35m'
    C_BOLD_WHITE=$'\033[1;37m'
    TERM_COLS=$(tput cols 2>/dev/null || echo 80)
else
    C_RESET='' C_BOLD='' C_DIM=''
    C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_MAGENTA='' C_CYAN='' C_WHITE=''
    C_BOLD_CYAN='' C_BOLD_GREEN='' C_BOLD_RED='' C_BOLD_YELLOW=''
    C_BOLD_BLUE='' C_BOLD_MAGENTA='' C_BOLD_WHITE=''
    TERM_COLS=80
fi

# ----------------------------------------------------------
# Single in-place progress bar
# ----------------------------------------------------------
#
# ONE bar at the bottom that keeps overwriting the same line.
# All print_* functions push past it before printing their
# permanent output, then the bar reappears on the next update.
#
# CRITICAL: the bar line must NEVER exceed TERM_COLS visible
# characters.  If it wraps, \r can't go back to column 0 and
# every line becomes permanent — exactly the bug we're fixing.
#
# Bar layout (visible chars):
#   [██████░░░░░░░░░░░░░░]  42% ─ <message>
#   1  20 chars           1  1  4  1 3 = 31 fixed + message
#
# So message is truncated to (TERM_COLS - 32) characters.

_PROGRESS_PCT=0
_PROGRESS_ACTIVE=false

# Precompute max message length for the bar
_BAR_MSG_MAX=$(( TERM_COLS - 32 ))
[ "$_BAR_MSG_MAX" -lt 10 ] && _BAR_MSG_MAX=10

# Draw / redraw the one progress bar (overwrites same line, no newline)
_draw_bar() {
    local pct="$1"
    local msg="$2"

    local bw=20
    local f=$(( pct * bw / 100 ))
    local e=$(( bw - f ))
    local bar=""
    for ((i=0; i<f; i++)); do bar+="█"; done
    for ((i=0; i<e; i++)); do bar+="░"; done

    # Hard truncate message to fit on one line
    msg="${msg:0:$_BAR_MSG_MAX}"

    printf '\r\033[K%s[%s] %3d%%%s ─ %s' \
        "${C_BOLD_MAGENTA}" "$bar" "$pct" "${C_RESET}" "$msg"
}

# Public: set progress percentage and message (stays on same line)
print_progress() {
    local pct="$1"
    shift
    _PROGRESS_PCT="$pct"
    _PROGRESS_ACTIVE=true
    _draw_bar "$pct" "$*"
}

# If the bar is sitting on the current line, emit a newline so
# the next echo starts on a clean line below it.
_newline_if_progress() {
    if [ "$_PROGRESS_ACTIVE" = true ]; then
        printf '\n'
        _PROGRESS_ACTIVE=false
    fi
}

# Erase the bar line entirely (for end-of-phase cleanup)
progress_clear() {
    if [ "$_PROGRESS_ACTIVE" = true ]; then
        printf '\r\033[K'
        _PROGRESS_ACTIVE=false
    fi
}

# ----------------------------------------------------------
# Output helper functions
# ----------------------------------------------------------

print_header() {
    _newline_if_progress
    echo ""
    echo -e "${C_BOLD_CYAN}$1${C_RESET}"
}

print_step() {
    _newline_if_progress
    echo -e "${C_CYAN}>>>${C_RESET} $1"
}

print_ok() {
    _newline_if_progress
    echo -e "${C_GREEN}>>>${C_RESET} ${C_GREEN}$1${C_RESET}"
}

print_warn() {
    _newline_if_progress
    echo -e "${C_YELLOW}>>> WARNING:${C_RESET} ${C_YELLOW}$1${C_RESET}"
}

print_err() {
    _newline_if_progress
    echo -e "${C_BOLD_RED}>>> ERROR:${C_RESET} ${C_RED}$1${C_RESET}"
}

print_detail() {
    _newline_if_progress
    echo -e "  ${C_DIM}$1${C_RESET}"
}

print_info() {
    _newline_if_progress
    echo -e "${C_BLUE}>>>${C_RESET} $1"
}

print_box_top() {
    _newline_if_progress
    echo -e "${C_BOLD_YELLOW}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
}
print_box_mid() {
    echo -e "${C_BOLD_YELLOW}╠══════════════════════════════════════════════════════════════╣${C_RESET}"
}
print_box_bot() {
    echo -e "${C_BOLD_YELLOW}╚══════════════════════════════════════════════════════════════╝${C_RESET}"
}
print_box_line() {
    echo -e "${C_BOLD_YELLOW}║${C_RESET}  $1"
}

print_summary_top() {
    _newline_if_progress
    echo -e "${C_BOLD_GREEN}============================================================${C_RESET}"
}
print_summary_line() {
    echo -e "${C_BOLD_GREEN}  $1${C_RESET}"
}
print_summary_bot() {
    echo -e "${C_BOLD_GREEN}============================================================${C_RESET}"
}

# ----------------------------------------------------------
# Apt output wrapper — single-line or verbose
# ----------------------------------------------------------
#
# Non-verbose: apt output is tee'd to APT_OUTPUT_LOG (for
#   post-mortem) and piped into the progress bar.
# Verbose (-v): full output passes through unchanged.
#
# On failure, run_apt_progress and run_quiet_rc automatically
# dump the last 25 lines of the log so the user sees what
# dpkg actually said — even though the progress bar dropped it.

_surface_apt_errors() {
    local rc="$1"
    local desc="$2"
    if [ "$rc" -ne 0 ] && [ "$APT_OUTPUT_LOG" != "/dev/null" ] && [ -f "$APT_OUTPUT_LOG" ]; then
        _newline_if_progress
        echo ""
        print_err "${desc} failed (exit code ${rc}). Last 25 lines of apt output:"
        echo -e "${C_DIM}────────────────────────────────────────────────${C_RESET}"
        tail -25 "$APT_OUTPUT_LOG" | while IFS= read -r _errline; do
            echo -e "  ${C_DIM}${_errline}${C_RESET}"
        done
        echo -e "${C_DIM}────────────────────────────────────────────────${C_RESET}"
        print_detail "Full log: ${APT_OUTPUT_LOG}"
        echo ""
    fi
}

run_quiet() {
    local desc="$1"
    shift
    if [ "$VERBOSE" = true ]; then
        _newline_if_progress
        "$@"
    else
        local pct="$_PROGRESS_PCT"
        local mmax="$_BAR_MSG_MAX"
        {
            "$@" 2>&1 || true
        } | tee -a "$APT_OUTPUT_LOG" | while IFS= read -r line; do
            _draw_bar "$pct" "${line:0:$mmax}"
        done
        # After command finishes, redraw bar with the step description
        _draw_bar "$pct" "$desc"
        _PROGRESS_ACTIVE=true
    fi
}

run_quiet_rc() {
    local desc="$1"
    shift
    if [ "$VERBOSE" = true ]; then
        _newline_if_progress
        "$@"
        return $?
    else
        local pct="$_PROGRESS_PCT"
        local mmax="$_BAR_MSG_MAX"
        local tmpfile
        tmpfile=$(mktemp)
        {
            "$@" 2>&1
            echo $? > "$tmpfile"
        } | tee -a "$APT_OUTPUT_LOG" | while IFS= read -r line; do
            _draw_bar "$pct" "${line:0:$mmax}"
        done
        local rc
        rc=$(cat "$tmpfile" 2>/dev/null || echo 1)
        rm -f "$tmpfile"
        _draw_bar "$pct" "$desc"
        _PROGRESS_ACTIVE=true
        [ "$rc" -ne 0 ] && _surface_apt_errors "$rc" "$desc"
        return "$rc"
    fi
}

# ----------------------------------------------------------
# Smart apt progress — real package-level tracking
# ----------------------------------------------------------
#
# Parses apt output lines (Get:, Unpacking, Setting up, Removing)
# and updates the ONE progress bar with:
#   ↓ curl (12/178) [227 kB]      ← downloading
#   ⚙ Unpacking curl               ← installing
#   ⚙ Setting up curl              ← configuring
#   ✕ libfoo                        ← removing
#
# Usage: run_apt_progress <start%> <end%> <total_pkgs> <cmd> [args...]
#   total_pkgs=0 → auto-detect from apt "N upgraded, M newly installed" line
#
# Weight: downloads 40% of range, unpack+setup 60% of range.
#         Pure remove operations use the full range.

run_apt_progress() {
    local start_pct="$1" end_pct="$2" total_pkgs="$3"
    shift 3

    if [ "$VERBOSE" = true ]; then
        _newline_if_progress
        "$@"
        return $?
    fi

    local tmpfile
    tmpfile=$(mktemp)
    local range=$(( end_pct - start_pct ))
    local mmax="$_BAR_MSG_MAX"

    {
        "$@" 2>&1
        echo $? > "$tmpfile"
    } | tee -a "$APT_OUTPUT_LOG" | {
        local dl_count=0 act_count=0 total="$total_pkgs"
        local dl_range=$(( range * 40 / 100 ))
        local act_range=$(( range - dl_range ))
        local cur_pct="$start_pct"

        while IFS= read -r line; do
            local pct="$cur_pct" msg=""

            # Auto-detect total from apt summary if not provided
            if [ "$total" -eq 0 ] && \
               [[ "$line" =~ ^([0-9]+)\ upgraded,\ ([0-9]+)\ newly\ installed ]]; then
                total=$(( BASH_REMATCH[1] + BASH_REMATCH[2] ))
            fi

            local eff=$(( total > 0 ? total : 1 ))
            local act_total=$(( eff * 2 ))

            case "$line" in
                Get:*)
                    dl_count=$((dl_count + 1))
                    # Parse: Get:N URL suite arch PKGNAME ...  [SIZE]
                    local _g _u _s _a _pkg _rest
                    read -r _g _u _s _a _pkg _rest <<< "$line" 2>/dev/null || true
                    local _size=""
                    [[ "$line" == *"["*"]" ]] && _size="[${line##*\[}"
                    pct=$(( start_pct + (dl_count * dl_range / eff) ))
                    msg="↓ ${_pkg} (${dl_count}/${eff}) ${_size}"
                    ;;
                Unpacking\ *)
                    act_count=$((act_count + 1))
                    local _w _pkg _rest
                    read -r _w _pkg _rest <<< "$line" 2>/dev/null || true
                    _pkg="${_pkg%%:*}"
                    pct=$(( start_pct + dl_range + (act_count * act_range / act_total) ))
                    msg="⚙ Unpacking ${_pkg}"
                    ;;
                "Setting up "*)
                    act_count=$((act_count + 1))
                    local _w1 _w2 _pkg _rest
                    read -r _w1 _w2 _pkg _rest <<< "$line" 2>/dev/null || true
                    _pkg="${_pkg%%:*}"
                    pct=$(( start_pct + dl_range + (act_count * act_range / act_total) ))
                    msg="⚙ Setting up ${_pkg}"
                    ;;
                Removing\ *|Purging\ *)
                    act_count=$((act_count + 1))
                    local _w _pkg _rest
                    read -r _w _pkg _rest <<< "$line" 2>/dev/null || true
                    _pkg="${_pkg%%:*}"
                    # Pure remove: use full range
                    pct=$(( start_pct + (act_count * range / eff) ))
                    msg="✕ ${_pkg}"
                    ;;
                "Fetched "*)
                    msg="${line:0:$mmax}"
                    ;;
                *)
                    # Skip noisy lines (dep tree, package lists, etc.)
                    continue
                    ;;
            esac

            [ "$pct" -lt "$start_pct" ] && pct="$start_pct"
            [ "$pct" -gt "$end_pct" ] && pct="$end_pct"
            cur_pct="$pct"
            _draw_bar "$pct" "${msg:0:$mmax}"
        done
    }

    local rc
    rc=$(cat "$tmpfile" 2>/dev/null || echo 1)
    rm -f "$tmpfile"
    _PROGRESS_PCT="$end_pct"
    _PROGRESS_ACTIVE=true
    [ "$rc" -ne 0 ] && _surface_apt_errors "$rc" "apt operation"
    return "$rc"
}

# ----------------------------------------------------------
# Platform detection utilities
# ----------------------------------------------------------

capture_platform_profile() {
    local OUTPUT_FILE="$1"

    local CPU_VENDOR
    CPU_VENDOR=$(lscpu 2>/dev/null | awk -F: '/Vendor ID/{gsub(/^[ \t]+/, "", $2); print $2}')
    [ -z "$CPU_VENDOR" ] && CPU_VENDOR="unknown"

    local VIRT_TYPE
    VIRT_TYPE=$(systemd-detect-virt 2>/dev/null || echo "none")

    local CLOUD_PROVIDER="unknown"
    if [ -f /sys/class/dmi/id/board_vendor ]; then
        local BOARD_VENDOR
        BOARD_VENDOR=$(cat /sys/class/dmi/id/board_vendor 2>/dev/null || echo "")
        case "$BOARD_VENDOR" in
            *Amazon*)       CLOUD_PROVIDER="aws" ;;
            *Google*)       CLOUD_PROVIDER="gcp" ;;
            *Microsoft*)    CLOUD_PROVIDER="azure" ;;
            *DigitalOcean*) CLOUD_PROVIDER="digitalocean" ;;
            *Hetzner*)      CLOUD_PROVIDER="hetzner" ;;
            *)              CLOUD_PROVIDER="other:${BOARD_VENDOR}" ;;
        esac
    fi
    if [ "$CLOUD_PROVIDER" = "unknown" ] && [ -f /sys/class/dmi/id/sys_vendor ]; then
        local SYS_VENDOR
        SYS_VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "")
        case "$SYS_VENDOR" in
            *Amazon*)       CLOUD_PROVIDER="aws" ;;
            *Google*)       CLOUD_PROVIDER="gcp" ;;
            *Microsoft*)    CLOUD_PROVIDER="azure" ;;
            *DigitalOcean*) CLOUD_PROVIDER="digitalocean" ;;
            *Hetzner*)      CLOUD_PROVIDER="hetzner" ;;
            *)              CLOUD_PROVIDER="other:${SYS_VENDOR}" ;;
        esac
    fi

    local BOOT_METHOD="bios"
    [ -d /sys/firmware/efi ] && BOOT_METHOD="efi"

    local KERNEL_FLAVOR
    KERNEL_FLAVOR=$(uname -r | sed 's/.*-//')

    local ARCH
    ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)

    local OS_VERSION="unknown"
    local OS_NAME="unknown"
    local OS_POINT_RELEASE="unknown"
    if [ -f /etc/os-release ]; then
        OS_VERSION=$(. /etc/os-release && echo "${VERSION_ID:-unknown}")
        OS_NAME=$(. /etc/os-release && echo "${NAME:-unknown}")
        OS_POINT_RELEASE=$(. /etc/os-release && echo "${VERSION:-unknown}")
    fi

    cat > "$OUTPUT_FILE" <<PROFILE
CPU_VENDOR="${CPU_VENDOR}"
VIRT_TYPE="${VIRT_TYPE}"
CLOUD_PROVIDER="${CLOUD_PROVIDER}"
BOOT_METHOD="${BOOT_METHOD}"
KERNEL_FLAVOR="${KERNEL_FLAVOR}"
ARCH="${ARCH}"
OS_VERSION="${OS_VERSION}"
OS_NAME="${OS_NAME}"
OS_POINT_RELEASE="${OS_POINT_RELEASE}"
PROFILE

    echo "$OUTPUT_FILE"
}

detect_running_kernel_packages() {
    local KERNEL_LIST="$1"
    > "$KERNEL_LIST"

    local RUNNING_KERNEL
    RUNNING_KERNEL=$(uname -r)
    local KERNEL_FLAVOR
    KERNEL_FLAVOR=$(echo "$RUNNING_KERNEL" | sed 's/.*-//')

    # Base version without flavor (e.g., 6.8.0-100-generic → 6.8.0-100)
    local KERNEL_BASE
    KERNEL_BASE=$(echo "$RUNNING_KERNEL" | sed "s/-${KERNEL_FLAVOR}$//")

    echo "linux-image-${RUNNING_KERNEL}" >> "$KERNEL_LIST"
    echo "linux-modules-${RUNNING_KERNEL}" >> "$KERNEL_LIST"

    for PKG in \
        "linux-modules-extra-${RUNNING_KERNEL}" \
        "linux-headers-${RUNNING_KERNEL}" \
        "linux-tools-${RUNNING_KERNEL}" \
        "linux-cloud-tools-${RUNNING_KERNEL}" \
        "linux-headers-${KERNEL_BASE}" \
        "linux-tools-${KERNEL_BASE}" \
        "linux-cloud-tools-${KERNEL_BASE}" \
        "linux-image-${KERNEL_FLAVOR}" \
        "linux-headers-${KERNEL_FLAVOR}" \
        "linux-${KERNEL_FLAVOR}" \
        "linux-generic" \
        "linux-image-generic" \
        "linux-headers-generic" \
        "linux-tools-common"; do
        dpkg -l "$PKG" 2>/dev/null | grep -q "^ii" && echo "$PKG" >> "$KERNEL_LIST"
    done

    sort -u -o "$KERNEL_LIST" "$KERNEL_LIST"
    echo "$KERNEL_LIST"
}

detect_protected_packages() {
    local PROTECTED_LIST="$1"
    > "$PROTECTED_LIST"

    local CPU_VENDOR
    CPU_VENDOR=$(lscpu 2>/dev/null | awk -F: '/Vendor ID/{gsub(/^[ \t]+/, "", $2); print $2}')
    case "$CPU_VENDOR" in
        GenuineIntel) dpkg -l intel-microcode 2>/dev/null | grep -q "^ii" && echo "intel-microcode" >> "$PROTECTED_LIST" ;;
        AuthenticAMD) dpkg -l amd64-microcode 2>/dev/null | grep -q "^ii" && echo "amd64-microcode" >> "$PROTECTED_LIST" ;;
    esac

    local RUNNING_KERNEL
    RUNNING_KERNEL=$(uname -r)
    echo "linux-image-${RUNNING_KERNEL}" >> "$PROTECTED_LIST"
    echo "linux-modules-${RUNNING_KERNEL}" >> "$PROTECTED_LIST"
    local KERNEL_FLAVOR
    KERNEL_FLAVOR=$(echo "$RUNNING_KERNEL" | sed 's/.*-//')
    local KERNEL_BASE
    KERNEL_BASE=$(echo "$RUNNING_KERNEL" | sed "s/-${KERNEL_FLAVOR}$//")
    for META in "linux-image-${KERNEL_FLAVOR}" "linux-headers-${KERNEL_FLAVOR}" \
                "linux-modules-extra-${RUNNING_KERNEL}" "linux-tools-${RUNNING_KERNEL}" \
                "linux-headers-${RUNNING_KERNEL}" "linux-headers-${KERNEL_BASE}" \
                "linux-tools-${KERNEL_BASE}" "linux-tools-common"; do
        dpkg -l "$META" 2>/dev/null | grep -q "^ii" && echo "$META" >> "$PROTECTED_LIST"
    done

    for BOOT_PKG in grub-efi-amd64 grub-efi-amd64-signed grub-efi-arm64 \
                     grub-pc grub-pc-bin grub-common grub2-common shim-signed; do
        dpkg -l "$BOOT_PKG" 2>/dev/null | grep -q "^ii" && echo "$BOOT_PKG" >> "$PROTECTED_LIST"
    done

    for AGENT in amazon-ssm-agent ec2-instance-connect cloud-init \
                 walinuxagent google-guest-agent google-osconfig-agent \
                 droplet-agent open-vm-tools qemu-guest-agent hyperv-daemons; do
        dpkg -l "$AGENT" 2>/dev/null | grep -q "^ii" && echo "$AGENT" >> "$PROTECTED_LIST"
    done

    for CLOUD_PKG in linux-aws linux-azure linux-gcp linux-kvm linux-oracle; do
        dpkg -l "$CLOUD_PKG" 2>/dev/null | grep -q "^ii" && echo "$CLOUD_PKG" >> "$PROTECTED_LIST"
    done

    dpkg -l 2>/dev/null | awk '/^ii.*firmware/{print $2}' >> "$PROTECTED_LIST"

    for NET_PKG in netplan.io networkd-dispatcher systemd-networkd \
                   ifupdown network-manager; do
        dpkg -l "$NET_PKG" 2>/dev/null | grep -q "^ii" && echo "$NET_PKG" >> "$PROTECTED_LIST"
    done

    for INITRD_PKG in initramfs-tools initramfs-tools-core; do
        dpkg -l "$INITRD_PKG" 2>/dev/null | grep -q "^ii" && echo "$INITRD_PKG" >> "$PROTECTED_LIST"
    done

    sort -u -o "$PROTECTED_LIST" "$PROTECTED_LIST"
    echo "$PROTECTED_LIST"
}

compare_platform_profiles() {
    local PROD_PROFILE="$1"
    local DEV_PROFILE="$2"

    source "$PROD_PROFILE"
    local PROD_CPU="$CPU_VENDOR" PROD_VIRT="$VIRT_TYPE" PROD_CLOUD="$CLOUD_PROVIDER"
    local PROD_BOOT="$BOOT_METHOD" PROD_KFLAVOR="$KERNEL_FLAVOR" PROD_ARCH="$ARCH"

    source "$DEV_PROFILE"
    local DEV_CPU="$CPU_VENDOR" DEV_VIRT="$VIRT_TYPE" DEV_CLOUD="$CLOUD_PROVIDER"
    local DEV_BOOT="$BOOT_METHOD" DEV_KFLAVOR="$KERNEL_FLAVOR" DEV_ARCH="$ARCH"

    local DIVERGED=0
    local DIVERGENCES=""

    [ "$PROD_ARCH" != "$DEV_ARCH" ] && DIVERGENCES+="  ${C_RED}Architecture:    Prod=${PROD_ARCH}  Dev=${DEV_ARCH}  [CRITICAL]${C_RESET}\n" && DIVERGED=1
    [ "$PROD_CPU" != "$DEV_CPU" ] && DIVERGENCES+="  ${C_YELLOW}CPU vendor:      Prod=${PROD_CPU}  Dev=${DEV_CPU}${C_RESET}\n" && DIVERGED=1
    [ "$PROD_VIRT" != "$DEV_VIRT" ] && DIVERGENCES+="  ${C_YELLOW}Virtualization:  Prod=${PROD_VIRT}  Dev=${DEV_VIRT}${C_RESET}\n" && DIVERGED=1
    [ "$PROD_CLOUD" != "$DEV_CLOUD" ] && DIVERGENCES+="  ${C_YELLOW}Cloud provider:  Prod=${PROD_CLOUD}  Dev=${DEV_CLOUD}${C_RESET}\n" && DIVERGED=1
    [ "$PROD_BOOT" != "$DEV_BOOT" ] && DIVERGENCES+="  ${C_YELLOW}Boot method:     Prod=${PROD_BOOT}  Dev=${DEV_BOOT}${C_RESET}\n" && DIVERGED=1
    [ "$PROD_KFLAVOR" != "$DEV_KFLAVOR" ] && DIVERGENCES+="  ${C_YELLOW}Kernel flavor:   Prod=${PROD_KFLAVOR}  Dev=${DEV_KFLAVOR}${C_RESET}\n" && DIVERGED=1

    if [ "$DIVERGED" -eq 1 ]; then
        echo ""
        print_box_top
        print_box_line "${C_BOLD_YELLOW}PLATFORM DIVERGENCE DETECTED${C_RESET}"
        print_box_mid
        print_box_line "Dev and Prod are NOT on identical platforms."
        print_box_line "Platform-specific packages on Dev will be ${C_BOLD}PROTECTED${C_RESET}."
        print_box_bot
        echo ""
        echo -e "${C_YELLOW}Divergences:${C_RESET}"
        echo -e "$DIVERGENCES"
        return 1
    fi
    return 0
}

generate_coverage_report() {
    local REPORT_FILE="$1"
    local PROTECTED_LIST="$2"
    local PROD_PROFILE="$3"
    local PURGED_LIST="$4"
    local SKIPPED_INSTALL_LIST="$5"

    source "$PROD_PROFILE"
    local PROD_KFLAVOR="$KERNEL_FLAVOR"
    local PROD_CLOUD="$CLOUD_PROVIDER"

    local PROTECTED_COUNT
    PROTECTED_COUNT=$(wc -l < "$PROTECTED_LIST")
    local PURGED_COUNT=0
    [ -f "$PURGED_LIST" ] && PURGED_COUNT=$(wc -l < "$PURGED_LIST")
    local SKIPPED_COUNT=0
    [ -f "$SKIPPED_INSTALL_LIST" ] && SKIPPED_COUNT=$(wc -l < "$SKIPPED_INSTALL_LIST")

    cat > "$REPORT_FILE" <<REPORT
==============================================================
  TEST COVERAGE REPORT — $(date)
==============================================================
  Prod kernel: ${PROD_KFLAVOR} | cloud: ${PROD_CLOUD}
  Dev kernel:  $(uname -r | sed 's/.*-//') | cloud: $(systemd-detect-virt 2>/dev/null || echo "unknown")

  Packages purged from Dev:         ${PURGED_COUNT}
  Packages protected on Dev:        ${PROTECTED_COUNT}
  Prod packages skipped (platform): ${SKIPPED_COUNT}

UNTESTED: kernel upgrades, bootloader, microcode, cloud agents, firmware
RECOMMENDATION: Use matching hardware for full coverage.
==============================================================
REPORT
    echo "$REPORT_FILE"
}

# ----------------------------------------------------------
# Snapshot source management
# ----------------------------------------------------------

add_snapshot_sources() {
    local SID="$1"
    local CODENAME
    CODENAME=$(. /etc/os-release && echo "${VERSION_CODENAME}")

    cat > /etc/apt/sources.list.d/upgrade-snapshot.list <<EOF
deb [trusted=yes] https://snapshot.ubuntu.com/ubuntu/${SID}/ ${CODENAME} main restricted universe multiverse
deb [trusted=yes] https://snapshot.ubuntu.com/ubuntu/${SID}/ ${CODENAME}-updates main restricted universe multiverse
deb [trusted=yes] https://snapshot.ubuntu.com/ubuntu-security/${SID}/ ${CODENAME}-security main restricted universe multiverse
EOF
    print_step "Added snapshot sources for ${C_BOLD}${SID}${C_RESET}."
}

remove_snapshot_sources() {
    rm -f /etc/apt/sources.list.d/upgrade-snapshot.list
    rm -f /etc/apt/apt.conf.d/50snapshot
}

# ----------------------------------------------------------
# Snapshot connectivity pre-flight check
# ----------------------------------------------------------
#
# apt-get update returns exit code 0 even when it cannot
# reach any remote repository — fetch failures are warnings
# on stderr, not fatal errors.  Combined with -qq and
# 2>/dev/null the script silently proceeds against stale
# cached package lists, producing a simulation (and later an
# upgrade) that does nothing while reporting success.
#
# This pre-flight probe catches the problem early.

verify_snapshot_connectivity() {
    print_step "Verifying snapshot endpoint is reachable..."
    local rc=0
    if command -v curl >/dev/null 2>&1; then
        curl -sf --max-time 15 -o /dev/null https://snapshot.ubuntu.com/ 2>/dev/null || rc=$?
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout=15 --spider https://snapshot.ubuntu.com/ 2>/dev/null || rc=$?
    else
        print_warn "Neither curl nor wget found — skipping connectivity pre-flight."
        return 0
    fi

    if [ "$rc" -ne 0 ]; then
        print_err "Cannot reach snapshot.ubuntu.com (no network or endpoint down)."
        print_detail "Snapshot operations require connectivity to snapshot.ubuntu.com."
        print_detail "Without it, apt-get update silently uses stale cached data"
        print_detail "and the simulation will report zero changes regardless of reality."
        print_detail "Test: curl -sf https://snapshot.ubuntu.com/"
        return 1
    fi

    print_detail "OK — snapshot.ubuntu.com is reachable."
    return 0
}

# ----------------------------------------------------------
# Apt lock pre-flight check
# ----------------------------------------------------------
#
# The progress bar pipes apt output through a while-read loop
# that silently drops unrecognised lines.  If apt fails with
# "Could not get lock", the error text is swallowed and the
# script either dies silently (set -e) or continues as if
# nothing happened (run_quiet's || true).  Checking BEFORE
# the first apt call avoids that entirely.

wait_for_apt_lock() {
    local timeout="${1:-300}"
    local waited=0
    local lock_files=(
        /var/lib/dpkg/lock-frontend
        /var/lib/dpkg/lock
        /var/lib/apt/lists/lock
    )

    while [ "$waited" -lt "$timeout" ]; do
        local locked=false
        local holder_pid="" holder_name=""

        for lf in "${lock_files[@]}"; do
            if [ -f "$lf" ] && fuser "$lf" >/dev/null 2>&1; then
                locked=true
                holder_pid=$(fuser "$lf" 2>&1 | grep -oE '[0-9]+' | head -1 || true)
                if [ -n "$holder_pid" ]; then
                    holder_name=$(ps -p "$holder_pid" -o comm= 2>/dev/null || echo "unknown")
                fi
                break
            fi
        done

        if [ "$locked" = false ]; then
            [ "$waited" -gt 0 ] && print_ok "Package manager lock released after ${waited}s."
            return 0
        fi

        if [ "$waited" -eq 0 ]; then
            echo ""
            print_warn "Package manager is locked by ${C_BOLD}${holder_name}${C_RESET} (PID ${holder_pid})."
            print_detail "This is usually unattended-upgrades or another apt process."
            print_detail "Waiting up to ${timeout}s for it to finish..."
        fi

        sleep 5
        waited=$((waited + 5))
        if [ $((waited % 30)) -eq 0 ]; then
            print_detail "Still waiting... (${waited}s / ${timeout}s)"
        fi
    done

    echo ""
    print_err "Package manager still locked after ${timeout}s."
    print_detail "Holding process: ${holder_name} (PID ${holder_pid})"
    print_detail "Options:"
    print_detail "  1. Wait for it to finish and re-run this command"
    print_detail "  2. sudo systemctl stop unattended-upgrades && sudo kill ${holder_pid}"
    return 1
}

# ----------------------------------------------------------
# Disk space pre-flight check
# ----------------------------------------------------------
#
# apt-get checks whether /var/cache/apt/archives has room for
# downloads, but it does NOT check /boot before extracting
# kernel images there.  A full /boot mid-extraction leaves the
# kernel package half-configured — a painful state to recover
# from, especially on production.

check_disk_space() {
    local warnings=0

    # Check /boot — the critical one.
    # Only a concern if /boot is its own mount; if it's on /,
    # the general root check below covers it.
    local boot_dev root_dev
    boot_dev=$(df --output=source /boot 2>/dev/null | tail -1)
    root_dev=$(df --output=source /     2>/dev/null | tail -1)

    if [ "$boot_dev" != "$root_dev" ]; then
        local boot_avail_mb
        boot_avail_mb=$(df -BM --output=avail /boot 2>/dev/null | tail -1 | tr -d ' M')
        if [ -n "$boot_avail_mb" ] && [ "$boot_avail_mb" -lt 100 ]; then
            echo ""
            print_box_top
            print_box_line "${C_BOLD_RED}LOW DISK SPACE ON /boot${C_RESET}"
            print_box_mid
            print_box_line "/boot is a separate partition with only ${C_BOLD}${boot_avail_mb}MB${C_RESET} free."
            print_box_line "A kernel upgrade needs ~150MB (vmlinuz + initrd)."
            print_box_line "If /boot fills mid-extraction, dpkg will leave the"
            print_box_line "kernel package half-configured."
            print_box_line ""
            print_box_line "Fix: ${C_BOLD}sudo apt-get purge \$(dpkg -l 'linux-image-*' | awk '/^ii/&&!/'\$(uname -r)'/{print \$2}')${C_RESET}"
            print_box_bot
            warnings=$((warnings + 1))
        fi
    fi

    # Check root filesystem (covers /var/cache/apt/archives too
    # if /var isn't a separate mount).
    local root_avail_mb
    root_avail_mb=$(df -BM --output=avail / 2>/dev/null | tail -1 | tr -d ' M')
    if [ -n "$root_avail_mb" ] && [ "$root_avail_mb" -lt 500 ]; then
        echo ""
        print_warn "Root filesystem has only ${C_BOLD}${root_avail_mb}MB${C_RESET} free."
        print_detail "A dist-upgrade may need several hundred MB for downloads and extraction."
        warnings=$((warnings + 1))
    fi

    # Check /var separately if it's its own mount
    local var_dev
    var_dev=$(df --output=source /var 2>/dev/null | tail -1)
    if [ "$var_dev" != "$root_dev" ]; then
        local var_avail_mb
        var_avail_mb=$(df -BM --output=avail /var 2>/dev/null | tail -1 | tr -d ' M')
        if [ -n "$var_avail_mb" ] && [ "$var_avail_mb" -lt 500 ]; then
            echo ""
            print_warn "/var has only ${C_BOLD}${var_avail_mb}MB${C_RESET} free (separate mount)."
            print_detail "Apt downloads to /var/cache/apt/archives/."
            warnings=$((warnings + 1))
        fi
    fi

    if [ "$warnings" -gt 0 ]; then
        echo ""
        read -p "Continue despite low disk space? (yes/no): " CONT
        [ "$CONT" != "yes" ] && echo "Aborted." && exit 1
    fi
}
# ----------------------------------------------------------

RESUME_SERVICE_NAME="upgrade-manager-resume"
RESUME_SERVICE_FILE="/etc/systemd/system/${RESUME_SERVICE_NAME}.service"
RESUME_MOTD_FILE="/etc/update-motd.d/99-upgrade-resume"

install_resume_service() {
    local SCRIPT_PATH
    SCRIPT_PATH=$(readlink -f "$0")

    # --------------------------------------------------
    # Validate script location is reachable at boot
    # --------------------------------------------------
    local script_dev root_dev
    script_dev=$(df --output=source "$(dirname "$SCRIPT_PATH")" 2>/dev/null | tail -1)
    root_dev=$(df --output=source / 2>/dev/null | tail -1)

    local path_warning=false

    # Detect tmpfs (includes /tmp on most systems)
    local script_fstype
    script_fstype=$(df --output=fstype "$(dirname "$SCRIPT_PATH")" 2>/dev/null | tail -1 | tr -d ' ')
    if [ "$script_fstype" = "tmpfs" ]; then
        echo ""
        print_box_top
        print_box_line "${C_BOLD_RED}SCRIPT LOCATION WARNING${C_RESET}"
        print_box_mid
        print_box_line "This script is on a tmpfs filesystem (${C_BOLD}$(dirname "$SCRIPT_PATH")${C_RESET})."
        print_box_line "tmpfs is cleared on reboot — the auto-resume service"
        print_box_line "will not be able to find the script after restarting."
        print_box_line ""
        print_box_line "Move the script to a permanent location first:"
        print_box_line "  ${C_BOLD}sudo cp $SCRIPT_PATH /usr/local/sbin/${C_RESET}"
        print_box_bot
        echo ""
        print_err "Cannot install resume service from tmpfs. Aborting."
        return 1
    fi

    # Detect encrypted home directories (ecryptfs / fscrypt)
    case "$SCRIPT_PATH" in
        /home/*)
            if [ "$script_fstype" = "ecryptfs" ] || \
               grep -q "^/home.*ecryptfs\|^/home.*fscrypt" /etc/fstab 2>/dev/null || \
               [ -d "$(dirname "$SCRIPT_PATH")/.ecryptfs" ]; then
                echo ""
                print_warn "Script is under /home on what may be an encrypted filesystem."
                print_detail "Encrypted home directories are not accessible until user login."
                print_detail "The systemd resume service runs before login."
                print_detail "Consider: sudo cp $SCRIPT_PATH /usr/local/sbin/"
                path_warning=true
            fi
            ;;
    esac

    if [ "$path_warning" = true ]; then
        read -p "Continue installing resume service at this path? (yes/no): " CONT
        [ "$CONT" != "yes" ] && echo "Aborted." && return 1
    fi

    # --------------------------------------------------
    # Install dynamic MOTD — checks actual state at login
    # --------------------------------------------------
    # Shows PENDING if .install_complete still exists (resume
    # running or hasn't started), COMPLETED if resume.log has
    # the success marker, or nothing if state is unclear.
    # Removed by verify-dev / verify-prod as final cleanup.
    # --------------------------------------------------
    local ABS_WORK_DIR
    ABS_WORK_DIR=$(readlink -f "${WORK_DIR}")

    cat > "$RESUME_MOTD_FILE" <<'MOTD_HEADER'
#!/bin/bash
MOTD_HEADER
    cat >> "$RESUME_MOTD_FILE" <<MOTD_VARS
_WORK_DIR="${ABS_WORK_DIR}"
_SCRIPT_PATH="${SCRIPT_PATH}"
_SERVICE_NAME="${RESUME_SERVICE_NAME}"
MOTD_VARS
    cat >> "$RESUME_MOTD_FILE" <<'MOTD_LOGIC'
if [ -f "${_WORK_DIR}/.install_complete" ]; then
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  ⚠  UPGRADE RESUME IN PROGRESS                              ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║  The post-reboot kernel cleanup is running or pending.       "
    echo "║                                                              "
    echo "║  Check service status:                                       "
    echo "║    systemctl status ${_SERVICE_NAME}                         "
    echo "║                                                              "
    echo "║  If it failed, run manually:                                 "
    echo "║    sudo ${_SCRIPT_PATH} resume ${_WORK_DIR}                 "
    echo "║                                                              "
    echo "║  Resume log: ${_WORK_DIR}/resume.log                        "
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
elif [ -f "${_WORK_DIR}/resume.log" ] && grep -q "RESUME COMPLETE" "${_WORK_DIR}/resume.log" 2>/dev/null; then
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  ✓  UPGRADE RESUME COMPLETED                                 ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║  Post-reboot kernel cleanup finished successfully.           "
    echo "║  Log: ${_WORK_DIR}/resume.log                               "
    echo "║                                                              "
    echo "║  Next: sudo ${_SCRIPT_PATH} verify-prod ${_WORK_DIR}        "
    echo "║    or: sudo ${_SCRIPT_PATH} verify-dev ${_WORK_DIR}         "
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
fi
MOTD_LOGIC
    chmod +x "$RESUME_MOTD_FILE"

    # --------------------------------------------------
    # Install systemd service
    # --------------------------------------------------
    cat > "$RESUME_SERVICE_FILE" <<EOF
[Unit]
Description=Upgrade Manager - Post-Reboot Resume (kernel cleanup)
After=network.target
ConditionPathExists=${ABS_WORK_DIR}/.install_complete

[Service]
Type=oneshot
ExecStart=${SCRIPT_PATH} resume ${ABS_WORK_DIR}
StandardOutput=append:${ABS_WORK_DIR}/resume.log
StandardError=append:${ABS_WORK_DIR}/resume.log
RemainAfterExit=no
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${RESUME_SERVICE_NAME}.service" 2>/dev/null
    print_step "Installed auto-resume service: ${C_BOLD}${RESUME_SERVICE_NAME}${C_RESET}"
}

remove_resume_service() {
    if [ -f "$RESUME_SERVICE_FILE" ]; then
        systemctl disable "${RESUME_SERVICE_NAME}.service" 2>/dev/null || true
        rm -f "$RESUME_SERVICE_FILE"
        systemctl daemon-reload
    fi
}

# ----------------------------------------------------------
# Argument parsing and config
# ----------------------------------------------------------

if [ "${1:-}" = "baseline" ]; then
    DATE=$(date +%Y%m%d)
    SNAPSHOT_ID="${DATE}T120000Z"
    WORK_DIR="${SCRIPT_DIR}/upgrade_${DATE}"
elif [ "${1:-}" = "simulate" ]; then
    if [ ! -f "$CONFIG_FILE" ]; then
        print_err "Run 'baseline' first."
        exit 1
    fi
    source "$CONFIG_FILE"
    [ -n "${2:-}" ] && SNAPSHOT_ID="${2}"
elif [ "${1:-}" = "apply-dev" ]; then
    if [ -z "${2:-}" ]; then
        echo -e "${C_BOLD}Usage:${C_RESET} sudo $0 apply-dev <UPGRADE_BUNDLE.tar.gz>"
        echo ""
        echo -e "Example: sudo $0 apply-dev ./upgrade_20250213T120000Z.tar.gz"
        echo ""
        echo "The bundle is produced by 'simulate' on Prod."
        exit 1
    fi
    BUNDLE_FILE="${2}"
    [ ! -f "$BUNDLE_FILE" ] && print_err "Not found: ${BUNDLE_FILE}" && exit 1

    # Extract bundle to temp dir, read contents, then move to WORK_DIR
    _BUNDLE_TMP=$(mktemp -d)
    if ! tar -xzf "$BUNDLE_FILE" -C "$_BUNDLE_TMP" 2>/dev/null; then
        print_err "Failed to extract bundle. Is it a valid .tar.gz?"
        rm -rf "$_BUNDLE_TMP"
        exit 1
    fi

    if [ ! -f "${_BUNDLE_TMP}/snapshot_id.txt" ]; then
        print_err "Invalid bundle: missing snapshot_id.txt"
        rm -rf "$_BUNDLE_TMP"
        exit 1
    fi
    SNAPSHOT_ID=$(cat "${_BUNDLE_TMP}/snapshot_id.txt")

    if [ ! -f "${_BUNDLE_TMP}/post_upgrade.txt" ]; then
        print_err "Invalid bundle: missing post_upgrade.txt"
        rm -rf "$_BUNDLE_TMP"
        exit 1
    fi

    WORK_DIR="${SCRIPT_DIR}/upgrade_${SNAPSHOT_ID%%T*}"
    mkdir -p "$WORK_DIR"
    cp "${_BUNDLE_TMP}"/*.txt "$WORK_DIR/" 2>/dev/null || true
    rm -rf "$_BUNDLE_TMP"

    POST_UPGRADE_FILE="${WORK_DIR}/post_upgrade.txt"
    PROD_PLATFORM_FILE=""
    [ -f "${WORK_DIR}/platform_profile.txt" ] && PROD_PLATFORM_FILE="${WORK_DIR}/platform_profile.txt"
    MANUAL_PACKAGES_FILE=""
    [ -f "${WORK_DIR}/manual_packages.txt" ] && MANUAL_PACKAGES_FILE="${WORK_DIR}/manual_packages.txt"
elif [ "${1:-}" = "verify-dev" ]; then
    if [ -n "${2:-}" ]; then
        WORK_DIR="${2%/}"
        [ ! -d "$WORK_DIR" ] && print_err "Directory not found: ${WORK_DIR}" && exit 1
    else
        WORK_DIR=""
    fi
elif [ "${1:-}" = "apply-prod" ]; then
    if [ -z "${2:-}" ]; then
        echo -e "${C_BOLD}Usage:${C_RESET} sudo $0 apply-prod <WORK_DIR>"
        echo ""
        echo -e "Example: sudo $0 apply-prod ./upgrade_20260221/"
        echo ""
        echo "The work directory is created by 'baseline' and 'simulate' on this server."
        echo "It contains snapshot_id.txt, post_upgrade.txt, and simulation results."
        exit 1
    fi
    WORK_DIR="${2%/}"
    [ ! -d "$WORK_DIR" ] && print_err "Directory not found: ${WORK_DIR}" && exit 1
    if [ ! -f "${WORK_DIR}/snapshot_id.txt" ]; then
        print_err "Missing snapshot_id.txt in ${WORK_DIR}. Run 'simulate' first."
        exit 1
    fi
    SNAPSHOT_ID=$(cat "${WORK_DIR}/snapshot_id.txt")
    if [ ! -f "${WORK_DIR}/post_upgrade.txt" ]; then
        print_err "Missing post_upgrade.txt in ${WORK_DIR}. Run 'simulate' first."
        exit 1
    fi
elif [ "${1:-}" = "verify-prod" ]; then
    if [ -n "${2:-}" ]; then
        WORK_DIR="${2%/}"
        [ ! -d "$WORK_DIR" ] && print_err "Directory not found: ${WORK_DIR}" && exit 1
    elif [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    else
        echo -e "${C_BOLD}Usage:${C_RESET} sudo $0 verify-prod [WORK_DIR]"
        echo ""
        echo "Provide the work directory, or run after apply-prod in the same session."
        exit 1
    fi
elif [ "${1:-}" = "resume" ]; then
    if [ -n "${2:-}" ]; then
        WORK_DIR="${2}"
    elif [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    else
        print_err "resume requires WORK_DIR argument or active session."
        exit 1
    fi
elif [ -n "${1:-}" ]; then
    if [ ! -f "$CONFIG_FILE" ]; then
        print_err "No active session. Run 'baseline' first."
        exit 1
    fi
    source "$CONFIG_FILE"
fi

usage() {
    echo -e "${C_BOLD_CYAN}Usage:${C_RESET} sudo $0 [-v|--verbose] <command>"
    echo ""
    echo -e "${C_BOLD}Commands (run in order):${C_RESET}"
    echo -e "  ${C_CYAN}baseline${C_RESET}       - ${C_DIM}[ON PROD]${C_RESET}  Capture current package state"
    echo -e "  ${C_CYAN}simulate${C_RESET} [SID] - ${C_DIM}[ON PROD]${C_RESET}  Simulate upgrade, produce upgrade bundle"
    echo -e "  ${C_CYAN}apply-dev${C_RESET}      - ${C_DIM}[ON DEV]${C_RESET}   Install Prod's post-upgrade state"
    echo -e "                       Args: <UPGRADE_BUNDLE.tar.gz>"
    echo -e "  ${C_CYAN}verify-dev${C_RESET}     - ${C_DIM}[ON DEV]${C_RESET}   Verify Dev health"
    echo -e "                       Args: [WORK_DIR]"
    echo -e "  ${C_CYAN}apply-prod${C_RESET}     - ${C_DIM}[ON PROD]${C_RESET}  Run actual upgrade on production"
    echo -e "                       Args: <WORK_DIR>"
    echo -e "  ${C_CYAN}verify-prod${C_RESET}    - ${C_DIM}[ON PROD]${C_RESET}  Verify Prod health"
    echo -e "                       Args: [WORK_DIR]"
    echo ""
    echo -e "${C_DIM}Options:${C_RESET}"
    echo -e "  ${C_CYAN}-v, --verbose${C_RESET}  Show full apt output (default: condensed single-line)"
    echo ""
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        echo -e "Active session: snapshot=${C_BOLD}${SNAPSHOT_ID}${C_RESET} dir=${C_BOLD}${WORK_DIR}${C_RESET}"
    fi
    exit 1
}

[ $# -lt 1 ] && usage

# ==========================================================
# COMMAND: resume (auto-called by systemd after reboot)
# ==========================================================
cmd_resume() {
    if [ ! -f "${WORK_DIR}/.install_complete" ]; then
        # Check if resume already ran successfully before reporting an error.
        # Signs of prior completion: resume.log contains the success marker,
        # or the COMPLETED MOTD was written.
        if [ -f "${WORK_DIR}/resume.log" ] && grep -q "RESUME COMPLETE" "${WORK_DIR}/resume.log" 2>/dev/null; then
            print_ok "Resume already completed for ${WORK_DIR}."
            print_detail "The post-reboot kernel cleanup finished successfully."
            print_detail "Resume log: ${WORK_DIR}/resume.log"
            echo ""
            local SCRIPT_PATH
            SCRIPT_PATH=$(readlink -f "$0")
            echo -e "  Next: ${C_BOLD}sudo ${SCRIPT_PATH} verify-prod ${WORK_DIR}${C_RESET}"
            echo -e "  or:   ${C_BOLD}sudo ${SCRIPT_PATH} verify-dev ${WORK_DIR}${C_RESET}"
            remove_resume_service
            return 0
        fi

        print_err "No resume state found at ${WORK_DIR}/.install_complete"
        print_detail "This can happen if:"
        print_detail "  1. Resume already completed (check ${WORK_DIR}/resume.log)"
        print_detail "  2. The file was manually deleted"
        print_detail "  3. apply-dev/apply-prod did not require a kernel reboot"
        remove_resume_service
        exit 1
    fi

    source "${WORK_DIR}/.install_complete"
    APT_OUTPUT_LOG="${WORK_DIR}/apt_output.log"
    echo "=== resume started $(date) ===" >> "$APT_OUTPUT_LOG"
    local CURRENT_KERNEL
    CURRENT_KERNEL=$(uname -r)

    print_header "============================================================"
    echo -e "${C_BOLD_CYAN}  RESUMING AFTER REBOOT — $(date)${C_RESET}"
    print_header "============================================================"
    echo -e "  Mode:           ${C_BOLD}${RESUME_MODE:-unknown}${C_RESET}"
    echo -e "  Old kernel:     ${C_DIM}${OLD_KERNEL}${C_RESET}"
    echo -e "  Target kernel:  ${C_BOLD_GREEN}${TARGET_KERNEL}${C_RESET}"
    echo -e "  Current kernel: ${C_BOLD}${CURRENT_KERNEL}${C_RESET}"
    echo ""

    # Check if we booted into the target kernel
    if [ "$CURRENT_KERNEL" = "$OLD_KERNEL" ]; then
        print_warn "Still running old kernel (${OLD_KERNEL})."
        echo -e "  ${C_YELLOW}The system did not boot into the target kernel.${C_RESET}"
        echo -e "  Manual fix: ${C_BOLD}sudo grub-reboot \"Advanced options for Ubuntu>Ubuntu, with Linux ${TARGET_KERNEL}\"${C_RESET}"
        echo -e "  Then: ${C_BOLD}sudo reboot${C_RESET}"
        echo ""
        echo -e "  ${C_YELLOW}Resume state preserved. Will retry on next reboot.${C_RESET}"
        return 1 2>/dev/null || exit 1
    fi

    # Clean up old kernel (includes unsigned variant)
    print_step "Cleaning up old kernel ${C_DIM}${OLD_KERNEL}${C_RESET}..."
    local OLD_FLAVOR OLD_BASE
    OLD_FLAVOR=$(echo "$OLD_KERNEL" | sed 's/.*-//')
    OLD_BASE=$(echo "$OLD_KERNEL" | sed "s/-${OLD_FLAVOR}$//")
    run_quiet "Kernel cleanup" apt-get purge -y \
        "linux-image-${OLD_KERNEL}" \
        "linux-image-unsigned-${OLD_KERNEL}" \
        "linux-modules-${OLD_KERNEL}" \
        "linux-modules-extra-${OLD_KERNEL}" \
        "linux-headers-${OLD_KERNEL}" \
        "linux-headers-${OLD_BASE}" \
        "linux-tools-${OLD_KERNEL}" \
        "linux-tools-${OLD_BASE}" \
        "linux-cloud-tools-${OLD_KERNEL}" \
        "linux-cloud-tools-${OLD_BASE}" 2>/dev/null || {
        print_warn "Some old kernel packages could not be removed."
    }

    print_step "Running autoremove..."
    run_quiet "Autoremove" apt-get autoremove -y 2>/dev/null || true
    print_ok "Old kernel cleaned."

    # Mode-specific finalization
    if [ "${RESUME_MODE:-}" = "prod" ]; then
        echo ""
        print_step "Capturing final post-upgrade state..."
        dpkg-query -W -f='${Package}=${Version}\n' | sort > "${WORK_DIR}/prod_post_upgrade.txt"
    fi

    # Clean up
    remove_snapshot_sources
    run_quiet "Apt update" apt-get update -qq 2>/dev/null || true
    rm -f "${WORK_DIR}/.install_complete"
    remove_resume_service

    echo ""
    print_summary_top
    print_summary_line "RESUME COMPLETE"
    print_summary_top
    echo -e "  Old kernel ${C_DIM}${OLD_KERNEL}${C_RESET} removed."
    echo -e "  Current kernel: ${C_BOLD_GREEN}${CURRENT_KERNEL}${C_RESET}"
    if [ "${RESUME_MODE:-}" = "dev" ]; then
        echo -e "  Next: ${C_BOLD}sudo $0 verify-dev ${WORK_DIR}${C_RESET}"
    else
        echo -e "  Next: ${C_BOLD}sudo $0 verify-prod ${WORK_DIR}${C_RESET}"
    fi
    echo ""
}

# ==========================================================
# COMMAND: baseline
# ==========================================================
cmd_baseline() {
    mkdir -p "$WORK_DIR"

    cat > "$CONFIG_FILE" <<EOF
SNAPSHOT_ID="${SNAPSHOT_ID}"
WORK_DIR="${WORK_DIR}"
EOF

    echo "$SNAPSHOT_ID" > "${WORK_DIR}/snapshot_id.txt"

    print_step "Capturing package baseline..."
    dpkg-query -W -f='${Package}=${Version}\n' | sort > "${WORK_DIR}/baseline.txt"

    print_step "Capturing running kernel..."
    uname -r > "${WORK_DIR}/running_kernel.txt"

    print_step "Capturing package manual marks..."
    apt-mark showmanual | sort > "${WORK_DIR}/manual_packages.txt"

    print_step "Capturing platform profile..."
    capture_platform_profile "${WORK_DIR}/platform_profile.txt"

    local TOTAL MANUAL_COUNT KERNEL
    TOTAL=$(wc -l < "${WORK_DIR}/baseline.txt")
    MANUAL_COUNT=$(wc -l < "${WORK_DIR}/manual_packages.txt")
    KERNEL=$(cat "${WORK_DIR}/running_kernel.txt")

    echo ""
    print_summary_top
    print_summary_line "BASELINE COMPLETE"
    print_summary_top
    echo -e "  Packages: ${C_BOLD}${TOTAL}${C_RESET} (${MANUAL_COUNT} manual)"
    echo -e "  Kernel:   ${C_BOLD_GREEN}${KERNEL}${C_RESET}"
    echo -e "  Snapshot: ${C_BOLD}${SNAPSHOT_ID}${C_RESET}"
    echo -e "  Work dir: ${C_BOLD}${WORK_DIR}${C_RESET}"
    source "${WORK_DIR}/platform_profile.txt"
    echo -e "  Platform: ${C_DIM}${CPU_VENDOR} | ${VIRT_TYPE} | ${CLOUD_PROVIDER} | ${BOOT_METHOD} | kernel=${KERNEL_FLAVOR}${C_RESET}"
    echo -e "  OS:       ${C_BOLD}${OS_NAME} ${OS_POINT_RELEASE}${C_RESET}"
    echo ""
    echo -e "Next: ${C_BOLD_CYAN}sudo $0 simulate${C_RESET}"
}

# ==========================================================
# COMMAND: simulate
# ==========================================================
cmd_simulate() {
    if [ ! -f "${WORK_DIR}/baseline.txt" ]; then
        print_err "Run 'baseline' first."
        exit 1
    fi

    print_step "Simulating upgrade with snapshot ${C_BOLD}${SNAPSHOT_ID}${C_RESET}..."
    echo ""

    # Ensure cleanup on any exit
    trap 'remove_snapshot_sources; apt-get update -qq 2>/dev/null || true' EXIT

    # Pre-flight: verify we can actually reach snapshot infrastructure
    verify_snapshot_connectivity

    # Try --snapshot flag first, fallback to explicit sources
    print_progress 10 "Updating package index..."
    print_detail "Fetching from snapshot.ubuntu.com — this is slower than regular mirrors, may take a minute or two."
    local SNAP_METHOD=""
    if apt-get update --snapshot "$SNAPSHOT_ID" -qq 2>/dev/null; then
        SNAP_METHOD="flag"
        print_detail "OK (--snapshot flag)"
    else
        print_detail "--snapshot flag not available. Adding snapshot sources..."
        add_snapshot_sources "$SNAPSHOT_ID"
        if apt-get update -qq 2>/dev/null; then
            SNAP_METHOD="sources"
            print_detail "OK (explicit snapshot sources)"
        else
            print_err "Cannot reach snapshot repos."
            echo -e "  Test: ${C_BOLD}curl -sf https://snapshot.ubuntu.com/${C_RESET}"
            exit 1
        fi
    fi

    # Run simulation
    print_progress 30 "Simulating dist-upgrade..."
    local SIM_OUTPUT
    if [ "$SNAP_METHOD" = "flag" ]; then
        SIM_OUTPUT=$(apt-get -s dist-upgrade --snapshot "$SNAPSHOT_ID" 2>&1)
    else
        SIM_OUTPUT=$(apt-get -s dist-upgrade 2>&1)
    fi

    echo "$SIM_OUTPUT" > "${WORK_DIR}/simulation.txt"
    print_progress 50 "Parsing simulation results..."

    # Parse Inst lines → package=new_version
    local SIM_INSTALLS="${WORK_DIR}/sim_installs.txt"
    echo "$SIM_OUTPUT" | awk '/^Inst / {
        pkg = $2
        for (i = 3; i <= NF; i++) {
            if (substr($i, 1, 1) == "(") {
                ver = substr($i, 2)
                print pkg "=" ver
                break
            }
        }
    }' | sort > "$SIM_INSTALLS"

    # Parse Remv lines → package names
    local SIM_REMOVALS="${WORK_DIR}/sim_removals.txt"
    echo "$SIM_OUTPUT" | awk '/^Remv / { print $2 }' | sort > "$SIM_REMOVALS"

    print_progress 70 "Computing post-upgrade state..."

    # Compute post-upgrade state:
    # Start with baseline, apply installs, remove removals
    awk -F= '
        FILENAME == ARGV[1] { installs[$1] = $0; next }
        FILENAME == ARGV[2] { removals[$1] = 1; next }
        {
            pkg = $1
            if (pkg in installs) {
                print installs[pkg]
                delete installs[pkg]
            } else if (!(pkg in removals)) {
                print
            }
        }
        END {
            for (pkg in installs) print installs[pkg]
        }
    ' "$SIM_INSTALLS" "$SIM_REMOVALS" "${WORK_DIR}/baseline.txt" \
        | sort > "${WORK_DIR}/post_upgrade.txt"

    # --------------------------------------------------
    # Post-simulation sanity check
    # --------------------------------------------------
    # If post_upgrade.txt is identical to baseline.txt, the
    # simulation found zero package changes.  This almost
    # always means the snapshot index was not fetched
    # correctly — stale cache, connectivity loss during
    # apt-get update, or a snapshot ID that predates the
    # baseline.  Do not produce a bundle from bad data.

    local SIM_CHANGES
    SIM_CHANGES=$(diff "${WORK_DIR}/baseline.txt" "${WORK_DIR}/post_upgrade.txt" | grep -c "^[<>]" || true)

    if [ "$SIM_CHANGES" -eq 0 ]; then
        print_progress 80 "WARNING: zero changes detected"
        echo ""
        print_box_top
        print_box_line "${C_BOLD_YELLOW}SIMULATION PRODUCED ZERO CHANGES${C_RESET}"
        print_box_mid
        print_box_line "post_upgrade.txt is identical to baseline.txt."
        print_box_line "The snapshot dist-upgrade found nothing to upgrade,"
        print_box_line "install, or remove."
        print_box_line ""
        print_box_line "This usually means one of:"
        print_box_line "  1. Connectivity was lost during apt-get update"
        print_box_line "     (stale cached index was used instead)"
        print_box_line "  2. Snapshot ID predates the current baseline"
        print_box_line "  3. System was recently patched to this snapshot"
        print_box_line ""
        print_box_line "If this is unexpected, re-run simulate with a"
        print_box_line "working connection to snapshot.ubuntu.com."
        print_box_bot
        echo ""
        read -p "Continue anyway and produce the bundle? (yes/no): " CONT
        [ "$CONT" != "yes" ] && echo "Aborted. No bundle created." && exit 1
    fi

    # Update config
    cat > "$CONFIG_FILE" <<EOF
SNAPSHOT_ID="${SNAPSHOT_ID}"
WORK_DIR="${WORK_DIR}"
EOF

    print_progress 90 "Creating upgrade bundle..."

    # Create snapshot_id.txt for the bundle
    echo "$SNAPSHOT_ID" > "${WORK_DIR}/snapshot_id.txt"

    # Package bundle: single tar.gz with everything apply-dev needs
    local BUNDLE_NAME="upgrade_${SNAPSHOT_ID}.tar.gz"
    local BUNDLE_PATH="${WORK_DIR}/${BUNDLE_NAME}"
    tar -czf "$BUNDLE_PATH" -C "$WORK_DIR" \
        snapshot_id.txt \
        post_upgrade.txt \
        manual_packages.txt \
        platform_profile.txt

    # Report
    local UPGRADE_COUNT NEW_COUNT REMOVE_COUNT POST_COUNT
    UPGRADE_COUNT=$(wc -l < "$SIM_INSTALLS")
    NEW_COUNT=$(echo "$SIM_OUTPUT" | grep "^Inst" | grep -cv "\[" || true)
    REMOVE_COUNT=$(wc -l < "$SIM_REMOVALS")
    POST_COUNT=$(wc -l < "${WORK_DIR}/post_upgrade.txt")

    print_progress 100 "Simulation complete."
    echo ""
    print_summary_top
    print_summary_line "SIMULATION COMPLETE"
    print_summary_top
    echo -e "  Snapshot:          ${C_BOLD}${SNAPSHOT_ID}${C_RESET}"
    echo -e "  Upgrades:          ${C_BOLD_CYAN}$((UPGRADE_COUNT - NEW_COUNT))${C_RESET}"
    echo -e "  New installs:      ${C_BOLD_GREEN}${NEW_COUNT}${C_RESET}"
    echo -e "  Removals:          ${C_BOLD_RED}${REMOVE_COUNT}${C_RESET}"
    echo -e "  Post-upgrade total: ${C_BOLD}${POST_COUNT}${C_RESET}"
    echo ""
    echo -e "  Kernel: ${C_BOLD}$(grep "^Inst linux-image" "${WORK_DIR}/simulation.txt" 2>/dev/null || echo "no change")${C_RESET}"
    echo ""
    echo -e "  ${C_BOLD}Copy to Dev:${C_RESET}"
    echo -e "    ${C_DIM}${BUNDLE_PATH}${C_RESET}"
    echo -e "    ${C_DIM}$(readlink -f "$0")${C_RESET}"
    echo ""
    echo -e "  ${C_BOLD}On Dev:${C_RESET}"
    echo -e "    ${C_CYAN}sudo ./$(basename "$0") apply-dev ./${BUNDLE_NAME}${C_RESET}"
    echo ""
    echo -e "  ${C_BOLD}After Dev testing passes, on Prod:${C_RESET}"
    echo -e "    ${C_CYAN}sudo $0 apply-prod ${WORK_DIR}${C_RESET}"
}

# ==========================================================
# COMMAND: apply-dev
# ==========================================================
cmd_apply_dev() {
    mkdir -p "$WORK_DIR"
    APT_OUTPUT_LOG="${WORK_DIR}/apt_output.log"
    echo "=== apply-dev started $(date) ===" >> "$APT_OUTPUT_LOG"

    # --------------------------------------------------
    # RESUME after reboot (fallback for manual re-run)
    # --------------------------------------------------
    if [ -f "${WORK_DIR}/.install_complete" ]; then
        cmd_resume
        return
    fi

    # --------------------------------------------------
    # NORMAL FLOW
    # --------------------------------------------------
    print_step "Install Prod's post-upgrade state on Dev."
    echo -e "  Snapshot:  ${C_BOLD}${SNAPSHOT_ID}${C_RESET}"
    echo -e "  Work dir:  ${C_BOLD}${WORK_DIR}${C_RESET}"
    echo -e "  ${C_YELLOW}Make sure this is your DEV server.${C_RESET}"
    echo ""
    print_box_top
    print_box_line "${C_BOLD_YELLOW}IMPORTANT: VM SNAPSHOT REMINDER${C_RESET}"
    print_box_mid
    print_box_line "Before running ${C_BOLD}apply-prod${C_RESET} on your production server, ensure"
    print_box_line "you have a ${C_BOLD}VM-level snapshot${C_RESET} in place. This script does not"
    print_box_line "provide a software rollback — restoring from a VM snapshot is"
    print_box_line "the only reliable way to revert if something goes wrong."
    print_box_bot
    echo ""
    read -p "Continue? (yes/no): " CONFIRM
    [ "$CONFIRM" != "yes" ] && echo "Aborted." && exit 1

    wait_for_apt_lock
    check_disk_space

    # Cleanup on any exit
    trap 'remove_snapshot_sources; apt-get update -qq 2>/dev/null || true' EXIT

    # ==================================================
    # Phase 0: Platform check
    # ==================================================
    print_progress 2 "Phase 0: Platform Compatibility Check"
    print_header "=== Phase 0: Platform Compatibility Check ==="

    print_step "Detecting Dev platform..."
    capture_platform_profile "${WORK_DIR}/dev_platform_profile.txt"

    source "${WORK_DIR}/dev_platform_profile.txt"
    print_detail "Dev: ${CPU_VENDOR} | ${VIRT_TYPE} | ${CLOUD_PROVIDER} | ${BOOT_METHOD} | kernel=${KERNEL_FLAVOR}"
    local DEV_OS_VERSION="$OS_VERSION"
    print_detail "Dev OS: ${OS_NAME} ${OS_POINT_RELEASE}"

    local PLATFORMS_MATCH=true

    if [ -n "$PROD_PLATFORM_FILE" ]; then
        source "$PROD_PLATFORM_FILE"
        print_detail "Prod OS: ${OS_NAME:-unknown} ${OS_POINT_RELEASE:-unknown}"
        print_detail "Prod: ${CPU_VENDOR} | ${VIRT_TYPE} | ${CLOUD_PROVIDER} | ${BOOT_METHOD} | kernel=${KERNEL_FLAVOR}"

        if [ "$DEV_OS_VERSION" != "$OS_VERSION" ]; then
            echo ""
            print_err "OS version mismatch. Dev=${DEV_OS_VERSION} Prod=${OS_VERSION}"
            echo -e "  ${C_RED}This tool is for upgrades within the same Ubuntu version.${C_RESET}"
            exit 1
        fi

        if ! compare_platform_profiles "$PROD_PLATFORM_FILE" "${WORK_DIR}/dev_platform_profile.txt"; then
            PLATFORMS_MATCH=false
            read -p "Continue with platform divergence? (yes/no): " CONT
            [ "$CONT" != "yes" ] && echo "Aborted." && exit 1

            print_step "Detecting Dev protected packages..."
            detect_protected_packages "${WORK_DIR}/dev_protected_packages.txt"

            # Identify Prod platform packages to skip on Dev
            > "${WORK_DIR}/prod_platform_skip.txt"
            source "$PROD_PLATFORM_FILE"
            local PROD_KFLAVOR="$KERNEL_FLAVOR"
            source "${WORK_DIR}/dev_platform_profile.txt"
            if [ "$PROD_KFLAVOR" != "$KERNEL_FLAVOR" ]; then
                grep "linux-.*${PROD_KFLAVOR}" "$POST_UPGRADE_FILE" \
                    >> "${WORK_DIR}/prod_platform_skip.txt" 2>/dev/null || true
            fi
        else
            echo ""
            print_ok "Platforms match."
        fi
    fi

    # ==================================================
    # Step 1: Analyze
    # ==================================================
    print_progress 8 "Step 1: Analyzing differences"
    print_header "=== Step 1: Analyzing differences ==="

    dpkg-query -W -f='${Package}=${Version}\n' | sort > "${WORK_DIR}/dev_current.txt"

    # Packages to install/change: in post_upgrade but not in dev (or different version)
    local NEED_INSTALL="${WORK_DIR}/need_install.txt"
    comm -23 <(sort "$POST_UPGRADE_FILE") <(sort "${WORK_DIR}/dev_current.txt") > "$NEED_INSTALL"

    # Filter platform-specific packages if needed
    if [ "$PLATFORMS_MATCH" = false ] && [ -s "${WORK_DIR}/prod_platform_skip.txt" ]; then
        grep -v -F -f <(awk -F= '{print $1"="}' "${WORK_DIR}/prod_platform_skip.txt") "$NEED_INSTALL" \
            > "${WORK_DIR}/need_install_filtered.txt" 2>/dev/null || cp "$NEED_INSTALL" "${WORK_DIR}/need_install_filtered.txt"
        mv "${WORK_DIR}/need_install_filtered.txt" "$NEED_INSTALL"
    fi

    local INSTALL_COUNT
    INSTALL_COUNT=$(wc -l < "$NEED_INSTALL")
    print_step "${C_BOLD}${INSTALL_COUNT}${C_RESET} packages to install/change."

    # Packages to remove: names in dev but NOT in post_upgrade
    local NEED_REMOVE="${WORK_DIR}/need_remove.txt"
    comm -23 \
        <(awk -F= '{print $1}' "${WORK_DIR}/dev_current.txt" | sort) \
        <(awk -F= '{print $1}' "$POST_UPGRADE_FILE" | sort) \
        > "$NEED_REMOVE"

    # Protect running kernel from removal
    print_step "Detecting running kernel packages..."
    detect_running_kernel_packages "${WORK_DIR}/running_kernel_packages.txt"
    local RK_COUNT
    RK_COUNT=$(wc -l < "${WORK_DIR}/running_kernel_packages.txt")
    print_step "${C_BOLD}${RK_COUNT}${C_RESET} running kernel packages protected."

    local KERNEL_PROTECTED="${WORK_DIR}/kernel_protected.txt"
    comm -12 "$NEED_REMOVE" "${WORK_DIR}/running_kernel_packages.txt" > "$KERNEL_PROTECTED" 2>/dev/null || true
    if [ -s "$KERNEL_PROTECTED" ]; then
        print_step "Running kernel packages kept:"
        sed "s/^/      ${C_GREEN}KEEP: /" "$KERNEL_PROTECTED" | while IFS= read -r line; do echo -e "${line}${C_RESET}"; done
        comm -23 "$NEED_REMOVE" "$KERNEL_PROTECTED" > "${WORK_DIR}/tmp_remove.txt"
        mv "${WORK_DIR}/tmp_remove.txt" "$NEED_REMOVE"
    fi

    # Protect platform packages from removal (cross-platform)
    if [ "$PLATFORMS_MATCH" = false ] && [ -f "${WORK_DIR}/dev_protected_packages.txt" ]; then
        local PLAT_PROTECTED="${WORK_DIR}/platform_protected.txt"
        comm -12 "$NEED_REMOVE" "${WORK_DIR}/dev_protected_packages.txt" > "$PLAT_PROTECTED" 2>/dev/null || true
        if [ -s "$PLAT_PROTECTED" ]; then
            print_step "Platform packages kept:"
            sed "s/^/      ${C_GREEN}KEEP: /" "$PLAT_PROTECTED" | while IFS= read -r line; do echo -e "${line}${C_RESET}"; done
            comm -23 "$NEED_REMOVE" "$PLAT_PROTECTED" > "${WORK_DIR}/tmp_remove.txt"
            mv "${WORK_DIR}/tmp_remove.txt" "$NEED_REMOVE"
        fi
    fi

    local REMOVE_COUNT
    REMOVE_COUNT=$(wc -l < "$NEED_REMOVE")
    print_step "${C_BOLD}${REMOVE_COUNT}${C_RESET} packages to remove."

    if [ "$INSTALL_COUNT" -eq 0 ] && [ "$REMOVE_COUNT" -eq 0 ]; then
        print_ok "Dev already matches post-upgrade state. Nothing to do."
        return
    fi

    # ==================================================
    # Step 2: Configure sources
    # ==================================================
    print_progress 15 "Step 2: Configuring package sources"
    print_header "=== Step 2: Configuring package sources ==="

    verify_snapshot_connectivity

    add_snapshot_sources "$SNAPSHOT_ID"
    print_step "Updating package index..."
    print_detail "Fetching from snapshot.ubuntu.com — this is slower than regular mirrors, may take a minute or two."
    run_quiet "Apt update" apt-get update -qq 2>/dev/null || true
    print_ok "Sources ready."

    # ==================================================
    # Step 3: Install
    # ==================================================
    print_progress 20 "Step 3: Installing packages"
    print_header "=== Step 3: Installing packages ==="

    if [ "$INSTALL_COUNT" -gt 0 ]; then
        print_step "Installing ${C_BOLD}${INSTALL_COUNT}${C_RESET} packages..."

        # Single apt-get call for proper dependency resolution
        if run_apt_progress 20 60 "$INSTALL_COUNT" apt-get install -y --allow-downgrades "${DPKG_CONF_OPTS[@]}" $(cat "$NEED_INSTALL"); then
            print_progress 60 "Bulk install complete"
            print_ok "Bulk install complete."
        else
            echo ""
            print_warn "Bulk install had errors. Retrying individually..."

            dpkg-query -W -f='${Package}=${Version}\n' | sort > "${WORK_DIR}/dev_partial.txt"
            comm -23 <(sort "$NEED_INSTALL") <(sort "${WORK_DIR}/dev_partial.txt") > "${WORK_DIR}/still_needed.txt"

            local STILL
            STILL=$(wc -l < "${WORK_DIR}/still_needed.txt")
            if [ "$STILL" -gt 0 ]; then
                local FAIL_COUNT=0
                local DONE_COUNT=0
                while IFS= read -r PKGVER; do
                    [ -z "$PKGVER" ] && continue
                    DONE_COUNT=$((DONE_COUNT + 1))
                    local pct=$(( 20 + (DONE_COUNT * 40 / STILL) ))
                    print_progress "$pct" "Retry ${DONE_COUNT}/${STILL}: ${PKGVER%%=*}"
                    if ! run_quiet_rc "Install ${PKGVER}" apt-get install -y --allow-downgrades "${DPKG_CONF_OPTS[@]}" "$PKGVER" 2>/dev/null; then
                        echo -e "  ${C_RED}FAILED: ${PKGVER}${C_RESET}"
                        FAIL_COUNT=$((FAIL_COUNT + 1))
                    fi
                done < "${WORK_DIR}/still_needed.txt"
                [ "$FAIL_COUNT" -gt 0 ] && print_warn "${FAIL_COUNT} packages could not be installed."
            fi
        fi
    else
        print_step "Nothing to install."
    fi

    # ==================================================
    # Step 3b: Restore auto/manual marks
    # ==================================================
    print_progress 65 "Step 3b: Restoring package marks"
    print_header "=== Step 3b: Restoring package auto/manual marks ==="

    if [ -n "${MANUAL_PACKAGES_FILE:-}" ] && [ -f "$MANUAL_PACKAGES_FILE" ]; then
        # apt-get install marks everything manual. We need to fix that.
        # Strategy: mark all just-installed packages as auto, then re-mark
        # only those that were manual on Prod.
        local INSTALLED_NAMES="${WORK_DIR}/installed_pkg_names.txt"
        awk -F= '{print $1}' "$NEED_INSTALL" | sort > "$INSTALLED_NAMES"

        # Mark all installed packages as auto first
        local AUTO_COUNT
        AUTO_COUNT=$(wc -l < "$INSTALLED_NAMES")
        if [ "$AUTO_COUNT" -gt 0 ]; then
            xargs -r apt-mark auto < "$INSTALLED_NAMES" > /dev/null 2>&1 || true
            print_step "Marked ${C_BOLD}${AUTO_COUNT}${C_RESET} packages as auto."
        fi

        # Re-mark the ones that are manual on Prod
        local RESTORE_MANUAL="${WORK_DIR}/restore_manual.txt"
        comm -12 "$INSTALLED_NAMES" "$MANUAL_PACKAGES_FILE" > "$RESTORE_MANUAL"
        local MANUAL_RESTORE_COUNT
        MANUAL_RESTORE_COUNT=$(wc -l < "$RESTORE_MANUAL")
        if [ "$MANUAL_RESTORE_COUNT" -gt 0 ]; then
            xargs -r apt-mark manual < "$RESTORE_MANUAL" > /dev/null 2>&1 || true
            print_step "Re-marked ${C_BOLD}${MANUAL_RESTORE_COUNT}${C_RESET} packages as manual (matching Prod)."
        fi

        print_ok "Auto/manual marks restored."
    else
        print_warn "No manual_packages.txt provided. Auto/manual marks NOT restored."
        echo -e "  ${C_YELLOW}Packages installed by apply-dev will be marked as manual.${C_RESET}"
        echo -e "  ${C_YELLOW}Re-run baseline on Prod and provide manual_packages.txt to fix.${C_RESET}"
    fi

    # ==================================================
    # Step 4: Remove extras
    # ==================================================
    print_progress 72 "Step 4: Removing extra packages"
    print_header "=== Step 4: Removing extra packages ==="

    if [ "$REMOVE_COUNT" -gt 0 ]; then
        print_step "Removing ${C_BOLD}${REMOVE_COUNT}${C_RESET} packages..."
        sed "s/^/      ${C_RED}REMOVE: /" "$NEED_REMOVE" | while IFS= read -r line; do echo -e "${line}${C_RESET}"; done
        echo ""

        cp "$NEED_REMOVE" "${WORK_DIR}/dev_purged_packages.txt"

        # Purge explicit extras (autoremove handles orphaned deps separately below)
        if run_apt_progress 72 80 "$REMOVE_COUNT" xargs -a "$NEED_REMOVE" apt-get purge -y; then
            :
        else
            print_warn "Bulk purge had errors. Retrying one by one..."
            while read -r PKG; do
                [ -z "$PKG" ] && continue
                run_quiet_rc "Purge ${PKG}" apt-get purge -y "$PKG" 2>/dev/null || echo -e "  ${C_RED}Could not purge: ${PKG}${C_RESET}"
            done < "$NEED_REMOVE"
        fi
        print_ok "Removal complete."
    else
        print_step "Nothing to remove."
        > "${WORK_DIR}/dev_purged_packages.txt"
    fi

    # ==================================================
    # Step 5: Verify (before autoremove — post_upgrade.txt
    #         represents state after dist-upgrade, not after autoremove)
    # ==================================================
    print_progress 82 "Step 5: Verifying"
    print_header "=== Step 5: Verifying ==="

    dpkg-query -W -f='${Package}=${Version}\n' | sort > "${WORK_DIR}/dev_after.txt"

    # Build exclude list for comparison (protected packages)
    local EXCLUDE="${WORK_DIR}/verify_exclude.txt"
    > "$EXCLUDE"
    cat "${WORK_DIR}/running_kernel_packages.txt" >> "$EXCLUDE" 2>/dev/null || true
    [ "$PLATFORMS_MATCH" = false ] && cat "${WORK_DIR}/dev_protected_packages.txt" >> "$EXCLUDE" 2>/dev/null || true
    sort -u -o "$EXCLUDE" "$EXCLUDE"

    # Build comparison target
    local TARGET="$POST_UPGRADE_FILE"
    if [ "$PLATFORMS_MATCH" = false ] && [ -s "${WORK_DIR}/prod_platform_skip.txt" ]; then
        grep -v -F -f <(awk -F= '{print $1"="}' "${WORK_DIR}/prod_platform_skip.txt") "$POST_UPGRADE_FILE" \
            > "${WORK_DIR}/compare_target.txt" 2>/dev/null || cp "$POST_UPGRADE_FILE" "${WORK_DIR}/compare_target.txt"
        TARGET="${WORK_DIR}/compare_target.txt"
    fi

    local DIFF_COUNT
    DIFF_COUNT=$(diff \
        <(grep -v -F -f <(awk '{print $1"="}' "$EXCLUDE") "$TARGET" 2>/dev/null || cat "$TARGET") \
        <(grep -v -F -f <(awk '{print $1"="}' "$EXCLUDE") "${WORK_DIR}/dev_after.txt" 2>/dev/null || cat "${WORK_DIR}/dev_after.txt") \
        | grep -c "^[<>]" || true)

    if [ "$DIFF_COUNT" -eq 0 ]; then
        print_ok "Dev matches post-upgrade state."
    else
        print_warn "${DIFF_COUNT} differences remain."
        echo -e "  ${C_YELLOW}Inspect: diff ${TARGET} ${WORK_DIR}/dev_after.txt${C_RESET}"
        read -p "Continue? (yes/no): " CONT
        [ "$CONT" != "yes" ] && echo "Aborted." && exit 1
    fi

    # ==================================================
    # Step 6: Autoremove orphaned dependencies
    # ==================================================
    print_progress 90 "Step 6: Removing orphaned dependencies"
    print_header "=== Step 6: Removing orphaned dependencies ==="

    local BEFORE_AUTO AFTER_AUTO AUTOREMOVED
    BEFORE_AUTO=$(dpkg-query -W -f='${Package}\n' | wc -l)
    run_quiet "Autoremove" apt-get autoremove -y 2>&1 || true
    AFTER_AUTO=$(dpkg-query -W -f='${Package}\n' | wc -l)
    AUTOREMOVED=$((BEFORE_AUTO - AFTER_AUTO))
    print_ok "Autoremoved ${C_BOLD}${AUTOREMOVED}${C_RESET} orphaned packages."

    # ==================================================
    # Coverage report (cross-platform)
    # ==================================================
    if [ "$PLATFORMS_MATCH" = false ]; then
        echo ""
        generate_coverage_report \
            "${WORK_DIR}/coverage_report.txt" \
            "${WORK_DIR}/dev_protected_packages.txt" \
            "$PROD_PLATFORM_FILE" \
            "${WORK_DIR}/dev_purged_packages.txt" \
            "${WORK_DIR}/prod_platform_skip.txt"
        cat "${WORK_DIR}/coverage_report.txt"
        read -p "Acknowledge coverage gaps? (yes/no): " CONT
        [ "$CONT" != "yes" ] && echo "Aborted." && exit 1
    fi

    # ==================================================
    # Kernel reboot gate
    # ==================================================
    local RUNNING_KERNEL
    RUNNING_KERNEL=$(uname -r)

    # Detect target kernel from Dev's actual installed packages,
    # using Dev's own flavor (generic, aws, gcp, etc.)
    local DEV_FLAVOR
    DEV_FLAVOR=$(echo "$RUNNING_KERNEL" | sed 's/.*-//')

    local TARGET_KERNEL=""
    TARGET_KERNEL=$(dpkg -l "linux-image-*-${DEV_FLAVOR}" 2>/dev/null \
        | grep -E '^ii.*linux-image-(unsigned-)?[0-9]' \
        | awk '{print $2}' \
        | sed 's/^linux-image-\(unsigned-\)\?//' \
        | sort -V | tail -1 || true)

    if [ -n "$TARGET_KERNEL" ] && [ "$TARGET_KERNEL" != "$RUNNING_KERNEL" ]; then
        echo ""
        print_box_top
        print_box_line "${C_BOLD_YELLOW}KERNEL REBOOT REQUIRED${C_RESET}"
        print_box_mid
        print_box_line ""
        print_box_line "Running kernel: ${C_DIM}${RUNNING_KERNEL}${C_RESET}"
        print_box_line "Target kernel:  ${C_BOLD_GREEN}${TARGET_KERNEL}${C_RESET}"
        print_box_line ""
        print_box_line "${C_BOLD}What happens next:${C_RESET}"
        print_box_line "1. System reboots into the new kernel"
        print_box_line "2. Old kernel (${RUNNING_KERNEL}) is purged automatically"
        print_box_line "3. Orphaned dependencies are cleaned up"
        print_box_line "4. You will see a confirmation at next login"
        print_box_line ""
        print_box_line "Resume log: ${C_DIM}${WORK_DIR}/resume.log${C_RESET}"
        print_box_line "After login: ${C_BOLD}sudo $0 verify-dev ${WORK_DIR}${C_RESET}"
        print_box_line ""
        print_box_bot

        cat > "${WORK_DIR}/.install_complete" <<STATE
RESUME_MODE="dev"
WORK_DIR="${WORK_DIR}"
SNAPSHOT_ID="${SNAPSHOT_ID}"
POST_UPGRADE_FILE="${POST_UPGRADE_FILE}"
PROD_PLATFORM_FILE="${PROD_PLATFORM_FILE:-}"
MANUAL_PACKAGES_FILE="${MANUAL_PACKAGES_FILE:-}"
OLD_KERNEL="${RUNNING_KERNEL}"
TARGET_KERNEL="${TARGET_KERNEL}"
STATE

        install_resume_service

        echo ""
        read -p "Reboot now? (yes/no): " REBOOT
        if [ "$REBOOT" = "yes" ]; then
            reboot
        else
            echo -e "  ${C_YELLOW}Reboot when ready. Resume will run automatically after reboot.${C_RESET}"
            exit 0
        fi
    fi

    # Clean up
    remove_snapshot_sources
    run_quiet "Apt update" apt-get update -qq 2>/dev/null || true

    print_progress 100 "Dev sync complete"
    echo ""
    print_summary_top
    print_summary_line "DEV SYNC COMPLETE"
    print_summary_top
    echo -e "  Dev now matches Prod's post-upgrade state."
    echo -e "  ${C_BOLD}Deploy your app and run tests.${C_RESET}"
    echo ""

    if [ -f /var/run/reboot-required ]; then
        print_box_top
        print_box_line "${C_BOLD_YELLOW}REBOOT REQUIRED${C_RESET}"
        print_box_line "Non-kernel packages require a reboot (libc, dbus, etc.)"
        print_box_bot
        echo ""
        read -p "Reboot now? (yes/no): " REBOOT
        if [ "$REBOOT" = "yes" ]; then
            reboot
        else
            echo -e "  Reboot when ready, then: ${C_BOLD}sudo $0 verify-dev ${WORK_DIR}${C_RESET}"
        fi
    else
        echo -e "  Next: ${C_BOLD_CYAN}sudo $0 verify-dev ${WORK_DIR}${C_RESET}"
    fi
}

# ==========================================================
# COMMAND: verify-dev
# ==========================================================
cmd_verify_dev() {
    print_header "=== Dev Server Verification ==="
    echo ""

    echo -e "${C_CYAN}>>>${C_RESET} Kernel: ${C_BOLD_GREEN}$(uname -r)${C_RESET}"

    echo ""
    print_step "Failed systemd units:"
    local FAILED
    FAILED=$(systemctl --failed --no-legend | wc -l)
    if [ "$FAILED" -gt 0 ]; then
        systemctl --failed
    else
        echo -e "  ${C_GREEN}None.${C_RESET}"
    fi

    echo ""
    print_step "Broken packages:"
    local BROKEN
    BROKEN=$(dpkg -l | grep -c "^[iU]F" || true)
    if [ "$BROKEN" -gt 0 ]; then
        dpkg -l | grep "^[iU]F"
    else
        echo -e "  ${C_GREEN}None.${C_RESET}"
    fi

    echo ""
    print_step "Apt consistency:"
    apt-get check 2>&1 || print_warn "apt check failed."

    # --------------------------------------------------
    # Package state comparison (requires WORK_DIR)
    # --------------------------------------------------
    if [ -n "$WORK_DIR" ] && [ -f "${WORK_DIR}/post_upgrade.txt" ]; then
        echo ""
        print_step "Live package state vs Prod post-upgrade target:"

        dpkg-query -W -f='${Package}=${Version}\n' | sort > "${WORK_DIR}/dev_verify_live.txt"

        # Build exclusion list (kernel + platform protected packages from apply-dev)
        local EXCLUDE="${WORK_DIR}/verify_dev_exclude.txt"
        > "$EXCLUDE"
        [ -f "${WORK_DIR}/running_kernel_packages.txt" ] && cat "${WORK_DIR}/running_kernel_packages.txt" >> "$EXCLUDE"
        [ -f "${WORK_DIR}/dev_protected_packages.txt" ] && cat "${WORK_DIR}/dev_protected_packages.txt" >> "$EXCLUDE"
        sort -u -o "$EXCLUDE" "$EXCLUDE"

        # Build comparison target (skip prod platform-specific packages)
        local TARGET="${WORK_DIR}/post_upgrade.txt"
        if [ -s "${WORK_DIR}/prod_platform_skip.txt" ]; then
            grep -v -F -f <(awk -F= '{print $1"="}' "${WORK_DIR}/prod_platform_skip.txt") "$TARGET" \
                > "${WORK_DIR}/verify_dev_target.txt" 2>/dev/null || cp "$TARGET" "${WORK_DIR}/verify_dev_target.txt"
            TARGET="${WORK_DIR}/verify_dev_target.txt"
        fi

        # Filter both sides: remove excluded packages by name
        local FILTERED_TARGET="${WORK_DIR}/verify_dev_filtered_target.txt"
        local FILTERED_LIVE="${WORK_DIR}/verify_dev_filtered_live.txt"
        if [ -s "$EXCLUDE" ]; then
            grep -v -F -f <(awk '{print $1"="}' "$EXCLUDE") "$TARGET" > "$FILTERED_TARGET" 2>/dev/null || cp "$TARGET" "$FILTERED_TARGET"
            grep -v -F -f <(awk '{print $1"="}' "$EXCLUDE") "${WORK_DIR}/dev_verify_live.txt" > "$FILTERED_LIVE" 2>/dev/null || cp "${WORK_DIR}/dev_verify_live.txt" "$FILTERED_LIVE"
        else
            cp "$TARGET" "$FILTERED_TARGET"
            cp "${WORK_DIR}/dev_verify_live.txt" "$FILTERED_LIVE"
        fi

        # Packages at wrong version: single awk pass reads target into
        # memory, then scans live list and compares.  O(N+M) not O(N*M).
        local MISMATCH_FILE="${WORK_DIR}/verify_dev_mismatches.txt"
        awk -F= '
            FILENAME == ARGV[1] { target[$1] = $2; next }
            {
                if ($1 in target && target[$1] != $2)
                    print $1 "  target=" target[$1] "  live=" $2
            }
        ' "$FILTERED_TARGET" "$FILTERED_LIVE" > "$MISMATCH_FILE"

        local VERSION_MISMATCHES
        VERSION_MISMATCHES=$(wc -l < "$MISMATCH_FILE")

        # Packages missing from Dev that target expects (not autoremoved — still in target)
        local MISSING_COUNT
        MISSING_COUNT=$(comm -23 \
            <(awk -F= '{print $1}' "$FILTERED_TARGET" | sort) \
            <(awk -F= '{print $1}' "$FILTERED_LIVE" | sort) \
            | wc -l)

        if [ "$VERSION_MISMATCHES" -eq 0 ]; then
            print_ok "All package versions match Prod post-upgrade target."
        else
            print_warn "${VERSION_MISMATCHES} packages at wrong version:"
            while IFS= read -r line; do
                echo -e "    ${C_YELLOW}${line}${C_RESET}"
            done < "$MISMATCH_FILE"
        fi

        if [ "$MISSING_COUNT" -gt 0 ]; then
            print_detail "${MISSING_COUNT} packages in target but not on Dev (likely autoremoved — expected)."
        fi
    elif [ -n "$WORK_DIR" ]; then
        echo ""
        print_warn "post_upgrade.txt not found in ${WORK_DIR} — skipping package state comparison."
    fi

    echo ""
    print_summary_top
    echo -e "  Run your test suite. If it passes:"
    echo -e "  On Prod: ${C_BOLD_CYAN}sudo $0 apply-prod ./upgrade_YYYYMMDD/${C_RESET}"
    echo -e "  ${C_DIM}(use the work directory created by baseline/simulate on Prod)${C_RESET}"
    print_summary_bot

    # Clean up resume MOTD if it exists (no longer needed after verification)
    rm -f "$RESUME_MOTD_FILE"
}

# ==========================================================
# COMMAND: apply-prod
# ==========================================================
cmd_apply_prod() {
    APT_OUTPUT_LOG="${WORK_DIR}/apt_output.log"
    echo "=== apply-prod started $(date) ===" >> "$APT_OUTPUT_LOG"

    # --------------------------------------------------
    # RESUME after reboot (fallback for manual re-run)
    # --------------------------------------------------
    if [ -f "${WORK_DIR}/.install_complete" ]; then
        source "${WORK_DIR}/.install_complete"
        if [ "${RESUME_MODE:-}" = "prod" ]; then
            cmd_resume
            return
        fi
    fi

    # --------------------------------------------------
    # NORMAL FLOW
    # --------------------------------------------------
    echo -e "${C_BOLD_RED}>>> !!! PRODUCTION UPGRADE !!!${C_RESET}"
    echo -e "  Snapshot: ${C_BOLD}${SNAPSHOT_ID}${C_RESET}"
    echo -e "  Work dir: ${C_BOLD}${WORK_DIR}${C_RESET}"
    echo -e "  ${C_BOLD_YELLOW}Make sure Dev testing passed and you have a VM-level snapshot of this server.${C_RESET}"
    echo ""
    read -p "Type 'upgrade-prod' to confirm: " CONFIRM
    [ "$CONFIRM" != "upgrade-prod" ] && echo "Aborted." && exit 1

    wait_for_apt_lock
    check_disk_space

    verify_snapshot_connectivity

    # Try --snapshot flag, fallback to explicit sources
    print_progress 5 "Pinning to snapshot ${SNAPSHOT_ID}"
    print_step "Pinning to snapshot ${C_BOLD}${SNAPSHOT_ID}${C_RESET}..."
    echo "APT::Snapshot \"${SNAPSHOT_ID}\";" > /etc/apt/apt.conf.d/50snapshot

    print_progress 10 "Updating package index"
    print_step "Updating index..."
    print_detail "Fetching from snapshot.ubuntu.com — this is slower than regular mirrors, may take a minute or two."
    if ! run_quiet_rc "Apt update" apt-get update -qq 2>/dev/null; then
        print_warn "APT::Snapshot failed. Adding snapshot sources..."
        add_snapshot_sources "$SNAPSHOT_ID"
        run_quiet "Apt update" apt-get update -qq
    fi

    print_progress 20 "Running dist-upgrade"
    print_step "Running dist-upgrade..."
    run_apt_progress 20 70 0 apt-get dist-upgrade -y "${DPKG_CONF_OPTS[@]}"

    print_progress 70 "Verifying dist-upgrade against simulation"
    echo ""
    print_step "Verifying dist-upgrade against simulation..."
    dpkg-query -W -f='${Package}=${Version}\n' | sort > "${WORK_DIR}/prod_post_distupgrade.txt"

    if [ -f "${WORK_DIR}/post_upgrade.txt" ]; then
        local PDIFF
        PDIFF=$(diff "${WORK_DIR}/post_upgrade.txt" "${WORK_DIR}/prod_post_distupgrade.txt" | grep -c "^[<>]" || true)
        if [ "$PDIFF" -eq 0 ]; then
            print_ok "Dist-upgrade matches simulation. ${C_BOLD}Exact match.${C_RESET}"
        else
            print_warn "${PDIFF} differences between simulation and actual dist-upgrade."
            echo -e "  ${C_YELLOW}Review: diff ${WORK_DIR}/post_upgrade.txt ${WORK_DIR}/prod_post_distupgrade.txt${C_RESET}"
            read -p "Continue with autoremove? (yes/no): " CONT
            [ "$CONT" != "yes" ] && echo "Aborted." && exit 1
        fi
    fi

    print_progress 80 "Running autoremove"
    echo ""
    print_step "Autoremove..."
    run_quiet "Autoremove" apt-get autoremove -y

    print_progress 90 "Capturing post-upgrade state"
    print_step "Capturing post-upgrade state..."
    dpkg-query -W -f='${Package}=${Version}\n' | sort > "${WORK_DIR}/prod_post_upgrade.txt"

    # ==================================================
    # Kernel reboot gate
    # ==================================================
    local RUNNING_KERNEL
    RUNNING_KERNEL=$(uname -r)

    local PROD_FLAVOR
    PROD_FLAVOR=$(echo "$RUNNING_KERNEL" | sed 's/.*-//')

    local TARGET_KERNEL=""
    TARGET_KERNEL=$(dpkg -l "linux-image-*-${PROD_FLAVOR}" 2>/dev/null \
        | grep -E '^ii.*linux-image-(unsigned-)?[0-9]' \
        | awk '{print $2}' \
        | sed 's/^linux-image-\(unsigned-\)\?//' \
        | sort -V | tail -1 || true)

    if [ -n "$TARGET_KERNEL" ] && [ "$TARGET_KERNEL" != "$RUNNING_KERNEL" ]; then
        print_progress 95 "Kernel reboot required"
        echo ""
        print_box_top
        print_box_line "${C_BOLD_YELLOW}KERNEL REBOOT REQUIRED${C_RESET}"
        print_box_mid
        print_box_line ""
        print_box_line "Running kernel: ${C_DIM}${RUNNING_KERNEL}${C_RESET}"
        print_box_line "Target kernel:  ${C_BOLD_GREEN}${TARGET_KERNEL}${C_RESET}"
        print_box_line ""
        print_box_line "${C_BOLD}What happens next:${C_RESET}"
        print_box_line "1. System reboots into the new kernel"
        print_box_line "2. Old kernel (${RUNNING_KERNEL}) is purged automatically"
        print_box_line "3. Orphaned dependencies are cleaned up"
        print_box_line "4. Final post-upgrade state is captured"
        print_box_line "5. You will see a confirmation at next login"
        print_box_line ""
        print_box_line "Resume log: ${C_DIM}${WORK_DIR}/resume.log${C_RESET}"
        print_box_line "After login: ${C_BOLD}sudo $0 verify-prod ${WORK_DIR}${C_RESET}"
        print_box_line ""
        print_box_line "Rollback: restore from VM snapshot if needed"
        print_box_line ""
        print_box_bot

        cat > "${WORK_DIR}/.install_complete" <<STATE
RESUME_MODE="prod"
WORK_DIR="${WORK_DIR}"
SNAPSHOT_ID="${SNAPSHOT_ID}"
OLD_KERNEL="${RUNNING_KERNEL}"
TARGET_KERNEL="${TARGET_KERNEL}"
STATE

        install_resume_service

        echo ""
        read -p "Reboot now? (yes/no): " REBOOT
        if [ "$REBOOT" = "yes" ]; then
            reboot
        else
            echo -e "  ${C_YELLOW}Reboot when ready. Resume will run automatically after reboot.${C_RESET}"
            exit 0
        fi
    fi

    # No kernel reboot needed — clean up normally
    remove_snapshot_sources
    run_quiet "Apt update" apt-get update -qq 2>/dev/null || true

    if [ -f /var/run/reboot-required ]; then
        print_progress 98 "Reboot required"
        echo ""
        print_box_top
        print_box_line "${C_BOLD_YELLOW}REBOOT REQUIRED${C_RESET}"
        print_box_line "Non-kernel packages require a reboot (libc, dbus, etc.)"
        print_box_bot
        echo ""
        read -p "Reboot now? (yes/no): " REBOOT
        if [ "$REBOOT" = "yes" ]; then
            reboot
        else
            echo -e "  Reboot when ready, then: ${C_BOLD}sudo $0 verify-prod ${WORK_DIR}${C_RESET}"
        fi
    else
        print_progress 100 "Production upgrade complete"
        echo ""
        echo -e "Next: ${C_BOLD_CYAN}sudo $0 verify-prod ${WORK_DIR}${C_RESET}"
    fi
}

# ==========================================================
# COMMAND: verify-prod
# ==========================================================
cmd_verify_prod() {
    print_header "=== Production Verification ==="
    echo ""

    echo -e "${C_CYAN}>>>${C_RESET} Kernel: ${C_BOLD_GREEN}$(uname -r)${C_RESET}"

    echo ""
    print_step "Failed systemd units:"
    local FAILED
    FAILED=$(systemctl --failed --no-legend | wc -l)
    if [ "$FAILED" -gt 0 ]; then
        systemctl --failed
    else
        echo -e "  ${C_GREEN}None.${C_RESET}"
    fi

    echo ""
    print_step "Broken packages:"
    local BROKEN
    BROKEN=$(dpkg -l | grep -c "^[iU]F" || true)
    if [ "$BROKEN" -gt 0 ]; then
        dpkg -l | grep "^[iU]F"
    else
        echo -e "  ${C_GREEN}None.${C_RESET}"
    fi

    echo ""
    print_step "Apt consistency:"
    apt-get check 2>&1 || print_warn "apt check failed."

    if [ -f "${WORK_DIR}/post_upgrade.txt" ] && [ -f "${WORK_DIR}/prod_post_distupgrade.txt" ]; then
        echo ""
        print_step "Actual dist-upgrade vs simulated:"
        local PDIFF
        PDIFF=$(diff "${WORK_DIR}/post_upgrade.txt" "${WORK_DIR}/prod_post_distupgrade.txt" | grep -c "^[<>]" || true)
        if [ "$PDIFF" -eq 0 ]; then
            echo -e "  ${C_GREEN}Exact match.${C_RESET}"
        else
            echo -e "  ${C_YELLOW}${PDIFF} differences. Review:${C_RESET}"
            echo -e "  ${C_DIM}diff ${WORK_DIR}/post_upgrade.txt ${WORK_DIR}/prod_post_distupgrade.txt${C_RESET}"
        fi
    fi

    # --------------------------------------------------
    # Live package state vs simulation target
    # --------------------------------------------------
    if [ -n "${WORK_DIR:-}" ] && [ -f "${WORK_DIR}/post_upgrade.txt" ]; then
        echo ""
        print_step "Live package state vs simulated post-upgrade target:"

        dpkg-query -W -f='${Package}=${Version}\n' | sort > "${WORK_DIR}/prod_verify_live.txt"

        local MISMATCH_FILE="${WORK_DIR}/verify_prod_mismatches.txt"
        awk -F= '
            FILENAME == ARGV[1] { target[$1] = $2; next }
            {
                if ($1 in target && target[$1] != $2)
                    print $1 "  target=" target[$1] "  live=" $2
            }
        ' "${WORK_DIR}/post_upgrade.txt" "${WORK_DIR}/prod_verify_live.txt" > "$MISMATCH_FILE"

        local VERSION_MISMATCHES
        VERSION_MISMATCHES=$(wc -l < "$MISMATCH_FILE")

        local MISSING_COUNT
        MISSING_COUNT=$(comm -23 \
            <(awk -F= '{print $1}' "${WORK_DIR}/post_upgrade.txt" | sort) \
            <(awk -F= '{print $1}' "${WORK_DIR}/prod_verify_live.txt" | sort) \
            | wc -l)

        if [ "$VERSION_MISMATCHES" -eq 0 ]; then
            print_ok "All package versions match simulated post-upgrade target."
        else
            print_warn "${VERSION_MISMATCHES} packages at wrong version:"
            while IFS= read -r line; do
                echo -e "    ${C_YELLOW}${line}${C_RESET}"
            done < "$MISMATCH_FILE"
        fi

        if [ "$MISSING_COUNT" -gt 0 ]; then
            print_detail "${MISSING_COUNT} packages in target but not live (autoremoved/kernel cleanup — expected)."
        fi
    fi

    echo ""
    print_summary_top
    print_summary_line "Production upgrade complete."
    echo -e "  Monitor services. If rollback is needed, ${C_BOLD_RED}restore from your VM snapshot${C_RESET}."
    print_summary_bot

    # Clean up resume MOTD if it exists (no longer needed after verification)
    rm -f "$RESUME_MOTD_FILE"
}

# ==========================================================
# Router
# ==========================================================
case "${1}" in
    baseline)    cmd_baseline ;;
    simulate)    cmd_simulate ;;
    apply-dev)   cmd_apply_dev ;;
    verify-dev)  cmd_verify_dev ;;
    apply-prod)  cmd_apply_prod ;;
    verify-prod) cmd_verify_prod ;;
    resume)      cmd_resume ;;
    *)           usage ;;
esac
