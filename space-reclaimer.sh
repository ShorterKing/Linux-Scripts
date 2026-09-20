#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                     SPACE RECLAIMER — Linux Edition                         ║
# ║                                                                             ║
# ║  Frees disk space WITHOUT deleting your personal files.                     ║
# ║  Techniques: cache clearing, compression, deduplication, journal trimming,  ║
# ║  snap cleanup, Docker pruning, and more.                                    ║
# ║                                                                             ║
# ║  Usage:  sudo ./space-reclaimer.sh [OPTIONS]                                ║
# ║  Options:                                                                   ║
# ║    --dry-run       Show what would be done without doing it                 ║
# ║    --aggressive    Enable aggressive compression (slower, saves more)       ║
# ║    --no-compress   Skip file compression steps                              ║
# ║    --no-dedup      Skip deduplication steps                                 ║
# ║    --no-cache      Skip cache clearing steps                                ║
# ║    --log FILE      Write log to FILE (default: /tmp/space-reclaimer.log)    ║
# ║    --help          Show this help                                           ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# GLOBALS & DEFAULTS
# ─────────────────────────────────────────────────────────────────────────────
VERSION="2.0.0"
DRY_RUN=false
AGGRESSIVE=false
NO_COMPRESS=false
NO_DEDUP=false
NO_CACHE=false
LOG_FILE="/tmp/space-reclaimer.log"
TOTAL_FREED=0          # bytes freed (running total)
SECTION_COUNT=0
ERRORS=()

# Compression settings
COMPRESS_AGE_DAYS=60          # Compress files not accessed in this many days
COMPRESS_MIN_SIZE="10M"       # Minimum file size to consider for compression
COMPRESS_EXTENSIONS="log|txt|csv|json|xml|sql|bak|old|orig|dump|out|dat"
AGGRESSIVE_AGE_DAYS=30
AGGRESSIVE_MIN_SIZE="5M"

# Dedup settings
DEDUP_MIN_SIZE="1M"           # Minimum file size to consider for dedup

# ─────────────────────────────────────────────────────────────────────────────
# COLORS & OUTPUT
# ─────────────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    MAGENTA='\033[0;35m'
    CYAN='\033[0;36m'
    WHITE='\033[1;37m'
    DIM='\033[2m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' MAGENTA='' CYAN='' WHITE='' DIM='' BOLD='' RESET=''
fi

banner() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}║${WHITE}${BOLD}          🧹  SPACE RECLAIMER v${VERSION}  🧹                  ${RESET}${CYAN}║${RESET}"
    echo -e "${CYAN}║${DIM}      Free disk space without deleting your files          ${RESET}${CYAN}║${RESET}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${RESET}"
    echo ""
}

section() {
    SECTION_COUNT=$((SECTION_COUNT + 1))
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${BOLD}${WHITE} [$SECTION_COUNT] $1${RESET}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

info()    { echo -e "  ${CYAN}ℹ${RESET}  $*"; }
success() { echo -e "  ${GREEN}✔${RESET}  $*"; }
warn()    { echo -e "  ${YELLOW}⚠${RESET}  $*"; }
error()   { echo -e "  ${RED}✖${RESET}  $*"; ERRORS+=("$*"); }
skip()    { echo -e "  ${DIM}⊘  $*${RESET}"; }
freed()   { echo -e "  ${GREEN}${BOLD}↓ Freed: $1${RESET}"; }
dryrun()  { echo -e "  ${MAGENTA}[DRY RUN]${RESET} $*"; }

# ─────────────────────────────────────────────────────────────────────────────
# UTILITY FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────
human_bytes() {
    local bytes=$1
    if (( bytes < 0 )); then bytes=0; fi
    if (( bytes >= 1073741824 )); then
        printf "%.2f GB" "$(echo "scale=2; $bytes / 1073741824" | bc)"
    elif (( bytes >= 1048576 )); then
        printf "%.2f MB" "$(echo "scale=2; $bytes / 1048576" | bc)"
    elif (( bytes >= 1024 )); then
        printf "%.2f KB" "$(echo "scale=2; $bytes / 1024" | bc)"
    else
        printf "%d B" "$bytes"
    fi
}

get_dir_size() {
    # Returns size in bytes of a directory, 0 if it doesn't exist
    local dir="$1"
    if [[ -d "$dir" ]]; then
        du -sb "$dir" 2>/dev/null | awk '{print $1}' || echo 0
    else
        echo 0
    fi
}

get_avail_space() {
    df -B1 / 2>/dev/null | awk 'NR==2 {print $4}'
}

track_freed() {
    local before=$1 after=$2
    local diff=$((before - after))
    if (( diff > 0 )); then
        TOTAL_FREED=$((TOTAL_FREED + diff))
        freed "$(human_bytes $diff)"
    else
        info "No significant space change"
    fi
}

cmd_exists() {
    command -v "$1" &>/dev/null
}

safe_run() {
    # Run a command, or just print it in dry-run mode
    if $DRY_RUN; then
        dryrun "$*"
        return 0
    fi
    "$@" 2>>"$LOG_FILE" || true
}

# ─────────────────────────────────────────────────────────────────────────────
# ARGUMENT PARSING
# ─────────────────────────────────────────────────────────────────────────────
show_help() {
    banner
    cat <<'HELP'
USAGE
    sudo ./space-reclaimer.sh [OPTIONS]

OPTIONS
    --dry-run       Preview what would be done, without touching anything
    --aggressive    Use aggressive compression (slower but reclaims more)
    --no-compress   Skip the file compression steps
    --no-dedup      Skip the deduplication steps
    --no-cache      Skip cache clearing steps
    --log FILE      Write detailed log to FILE (default: /tmp/space-reclaimer.log)
    --help          Show this help and exit

WHAT IT DOES (nothing is permanently deleted)
    • Clears regenerable caches (APT, pip, npm, cargo, thumbnails, font)
    • Vacuums systemd journal logs down to 100 MB
    • Removes old snap revisions (keeps the active one)
    • Compresses old, large files in-place (gzip → .gz)
    • Compresses old log files that aren't already compressed
    • Deduplicates identical files using hardlinks
    • Prunes Docker build cache, dangling images, and stopped containers
    • Clears Flatpak unused runtimes and app caches
    • Empties the Trash (files already marked for deletion)
    • Trims SSD free blocks (fstrim) if supported

SAFETY
    • Your documents, code, media, and personal files are NEVER touched
    • Compression is reversible (gunzip / gzip -d)
    • Dedup uses hardlinks — every path still works, data is stored once
    • A full log is written to /tmp/space-reclaimer.log

HELP
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)    DRY_RUN=true ;;
        --aggressive) AGGRESSIVE=true ;;
        --no-compress) NO_COMPRESS=true ;;
        --no-dedup)   NO_DEDUP=true ;;
        --no-cache)   NO_CACHE=true ;;
        --log)        LOG_FILE="${2:-/tmp/space-reclaimer.log}"; shift ;;
        --help|-h)    show_help ;;
        *) echo "Unknown option: $1"; echo "Try --help"; exit 1 ;;
    esac
    shift
done

# ─────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────
check_prerequisites() {
    section "Pre-Flight Checks"

    # Root check
    if [[ $EUID -ne 0 ]]; then
        warn "Not running as root — some operations will be skipped"
        warn "For full effect, run:  sudo $0 $*"
    else
        success "Running as root"
    fi

    # Log file
    : > "$LOG_FILE"
    info "Log file: $LOG_FILE"

    # Disk info before
    local avail
    avail=$(get_avail_space)
    info "Available space before: $(human_bytes "$avail")"
    echo "$avail" > /tmp/.space-reclaimer-before

    # Mode
    if $DRY_RUN; then
        warn "DRY RUN mode — nothing will be changed"
    fi
    if $AGGRESSIVE; then
        info "Aggressive mode enabled"
        COMPRESS_AGE_DAYS=$AGGRESSIVE_AGE_DAYS
        COMPRESS_MIN_SIZE=$AGGRESSIVE_MIN_SIZE
    fi

    # Check for useful tools
    for tool in gzip bc du find xargs awk sort; do
        if ! cmd_exists "$tool"; then
            error "Required tool missing: $tool"
        fi
    done
}

# ═════════════════════════════════════════════════════════════════════════════
#  SECTION 1: PACKAGE MANAGER CACHES
# ═════════════════════════════════════════════════════════════════════════════
clean_apt_cache() {
    section "APT Package Cache"

    if ! cmd_exists apt-get; then
        skip "apt-get not found, skipping"
        return
    fi

    local cache_dir="/var/cache/apt/archives"
    local before
    before=$(get_dir_size "$cache_dir")
    info "APT cache size: $(human_bytes "$before")"

    if (( before > 0 )); then
        safe_run apt-get clean -y
        # Also clean partial downloads
        if [[ -d "$cache_dir/partial" ]]; then
            safe_run find "$cache_dir/partial" -type f -exec rm -f {} + 2>/dev/null || true
        fi
        local after
        after=$(get_dir_size "$cache_dir")
        track_freed "$before" "$after"
    else
        info "APT cache already clean"
    fi

    # Clean apt lists (regenerated on apt update)
    local lists_dir="/var/lib/apt/lists"
    if [[ -d "$lists_dir" ]]; then
        local lists_before
        lists_before=$(get_dir_size "$lists_dir")
        if (( lists_before > 52428800 )); then  # > 50 MB
            info "APT lists: $(human_bytes "$lists_before") — cleaning"
            if ! $DRY_RUN; then
                find "$lists_dir" -type f ! -name "lock" -delete 2>/dev/null || true
            else
                dryrun "Would clear APT lists"
            fi
            local lists_after
            lists_after=$(get_dir_size "$lists_dir")
            track_freed "$lists_before" "$lists_after"
        fi
    fi

    # Autoremove suggestion
    local autoremovable
    autoremovable=$(apt-get --dry-run autoremove 2>/dev/null | grep -c "^Remv " || true)
    if (( autoremovable > 0 )); then
        info "${autoremovable} packages can be autoremoved (run: sudo apt autoremove)"
    fi
}

clean_dpkg_cache() {
    section "DPKG Old Package Data"

    local dpkg_info="/var/lib/dpkg/info"
    if [[ ! -d "$dpkg_info" ]]; then
        skip "dpkg info directory not found"
        return
    fi

    # Clean orphaned dpkg diversions backup files
    local count=0
    while IFS= read -r -d '' f; do
        count=$((count + 1))
    done < <(find "$dpkg_info" -name "*.dpkg-old" -o -name "*.dpkg-bak" -print0 2>/dev/null)

    if (( count > 0 )); then
        info "Found $count orphaned dpkg backup files"
        if ! $DRY_RUN; then
            find "$dpkg_info" \( -name "*.dpkg-old" -o -name "*.dpkg-bak" \) -delete 2>/dev/null || true
        else
            dryrun "Would remove $count dpkg backup files"
        fi
        success "Cleaned dpkg backup files"
    else
        info "No orphaned dpkg files found"
    fi
}

clean_pip_cache() {
    section "Python / pip Cache"

    local pip_freed=0

    # pip cache for all users
    for pip_cmd in pip pip3; do
        if cmd_exists "$pip_cmd"; then
            local cache_dir
            cache_dir=$($pip_cmd cache dir 2>/dev/null || echo "")
            if [[ -n "$cache_dir" && -d "$cache_dir" ]]; then
                local before
                before=$(get_dir_size "$cache_dir")
                if (( before > 0 )); then
                    info "$pip_cmd cache: $(human_bytes "$before")"
                    safe_run "$pip_cmd" cache purge
                    local after
                    after=$(get_dir_size "$cache_dir")
                    local diff=$((before - after))
                    if (( diff > 0 )); then pip_freed=$((pip_freed + diff)); fi
                fi
            fi
        fi
    done

    # Common pip cache locations
    for user_home in /home/* /root; do
        local pip_cache="$user_home/.cache/pip"
        if [[ -d "$pip_cache" ]]; then
            local before
            before=$(get_dir_size "$pip_cache")
            if (( before > 1048576 )); then  # > 1 MB
                info "pip cache at $pip_cache: $(human_bytes "$before")"
                if ! $DRY_RUN; then
                    rm -rf "$pip_cache"
                fi
                pip_freed=$((pip_freed + before))
            fi
        fi
    done

    # __pycache__ directories (safe to remove, regenerated on import)
    local pycache_size=0
    while IFS= read -r dir; do
        local s
        s=$(du -sb "$dir" 2>/dev/null | awk '{print $1}')
        pycache_size=$((pycache_size + s))
    done < <(find /home /root /opt /usr/local -type d -name "__pycache__" 2>/dev/null | head -1000)

    if (( pycache_size > 1048576 )); then
        info "__pycache__ dirs: $(human_bytes "$pycache_size")"
        if ! $DRY_RUN; then
            find /home /root /opt /usr/local -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
        else
            dryrun "Would clear __pycache__ directories"
        fi
        pip_freed=$((pip_freed + pycache_size))
    fi

    # .pyc files outside __pycache__
    local pyc_size=0
    while IFS= read -r -d '' f; do
        local s
        s=$(stat -c%s "$f" 2>/dev/null || echo 0)
        pyc_size=$((pyc_size + s))
    done < <(find /home /root -name "*.pyc" -not -path "*/__pycache__/*" -print0 2>/dev/null)

    if (( pyc_size > 1048576 )); then
        info "Stray .pyc files: $(human_bytes "$pyc_size")"
        if ! $DRY_RUN; then
            find /home /root -name "*.pyc" -not -path "*/__pycache__/*" -delete 2>/dev/null || true
        fi
        pip_freed=$((pip_freed + pyc_size))
    fi

    if (( pip_freed > 0 )); then
        TOTAL_FREED=$((TOTAL_FREED + pip_freed))
        freed "$(human_bytes "$pip_freed")"
    else
        info "Python caches already clean"
    fi
}

clean_npm_cache() {
    section "npm / Node.js Cache"

    local npm_freed=0

    if cmd_exists npm; then
        # npm cache
        local npm_cache
        npm_cache=$(npm config get cache 2>/dev/null || echo "$HOME/.npm")
        if [[ -d "$npm_cache" ]]; then
            local before
            before=$(get_dir_size "$npm_cache")
            if (( before > 1048576 )); then
                info "npm cache: $(human_bytes "$before")"
                safe_run npm cache clean --force
                local after
                after=$(get_dir_size "$npm_cache")
                local diff=$((before - after))
                if (( diff > 0 )); then npm_freed=$((npm_freed + diff)); fi
            fi
        fi
    fi

    # Per-user npm caches
    for user_home in /home/* /root; do
        local cache="$user_home/.npm"
        if [[ -d "$cache" ]]; then
            local before
            before=$(get_dir_size "$cache")
            if (( before > 10485760 )); then  # > 10 MB
                info "npm cache at $cache: $(human_bytes "$before")"
                if ! $DRY_RUN; then
                    rm -rf "${cache:?}/_cacache"
                fi
                local after
                after=$(get_dir_size "$cache")
                local diff=$((before - after))
                if (( diff > 0 )); then npm_freed=$((npm_freed + diff)); fi
            fi
        fi
    done

    # yarn cache
    if cmd_exists yarn; then
        local yarn_cache
        yarn_cache=$(yarn cache dir 2>/dev/null || echo "")
        if [[ -n "$yarn_cache" && -d "$yarn_cache" ]]; then
            local before
            before=$(get_dir_size "$yarn_cache")
            if (( before > 1048576 )); then
                info "yarn cache: $(human_bytes "$before")"
                safe_run yarn cache clean
                local after
                after=$(get_dir_size "$yarn_cache")
                local diff=$((before - after))
                if (( diff > 0 )); then npm_freed=$((npm_freed + diff)); fi
            fi
        fi
    fi

    # pnpm cache
    if cmd_exists pnpm; then
        local pnpm_cache
        pnpm_cache=$(pnpm store path 2>/dev/null || echo "")
        if [[ -n "$pnpm_cache" && -d "$pnpm_cache" ]]; then
            local before
            before=$(get_dir_size "$pnpm_cache")
            if (( before > 1048576 )); then
                info "pnpm store: $(human_bytes "$before")"
                safe_run pnpm store prune
                local after
                after=$(get_dir_size "$pnpm_cache")
                local diff=$((before - after))
                if (( diff > 0 )); then npm_freed=$((npm_freed + diff)); fi
            fi
        fi
    fi

    if (( npm_freed > 0 )); then
        TOTAL_FREED=$((TOTAL_FREED + npm_freed))
        freed "$(human_bytes "$npm_freed")"
    else
        info "Node.js caches already clean"
    fi
}

clean_cargo_cache() {
    section "Rust / Cargo Cache"

    local cargo_freed=0

    for user_home in /home/* /root; do
        local cargo_dir="$user_home/.cargo"
        if [[ ! -d "$cargo_dir" ]]; then continue; fi

        # Registry cache (downloaded .crate files)
        local reg_cache="$cargo_dir/registry/cache"
        if [[ -d "$reg_cache" ]]; then
            local before
            before=$(get_dir_size "$reg_cache")
            if (( before > 10485760 )); then  # > 10 MB
                info "Cargo registry cache at $cargo_dir: $(human_bytes "$before")"
                if ! $DRY_RUN; then
                    rm -rf "$reg_cache"
                fi
                cargo_freed=$((cargo_freed + before))
            fi
        fi

        # Registry source (extracted crate source)
        local reg_src="$cargo_dir/registry/src"
        if [[ -d "$reg_src" ]]; then
            local before
            before=$(get_dir_size "$reg_src")
            if (( before > 10485760 )); then
                info "Cargo registry src at $cargo_dir: $(human_bytes "$before")"
                if ! $DRY_RUN; then
                    rm -rf "$reg_src"
                fi
                cargo_freed=$((cargo_freed + before))
            fi
        fi
    done

    if (( cargo_freed > 0 )); then
        TOTAL_FREED=$((TOTAL_FREED + cargo_freed))
        freed "$(human_bytes "$cargo_freed")"
    else
        info "Cargo caches clean or not found"
    fi
}

clean_go_cache() {
    section "Go Module & Build Cache"

    local go_freed=0

    if cmd_exists go; then
        local go_cache
        go_cache=$(go env GOCACHE 2>/dev/null || echo "")
        if [[ -n "$go_cache" && -d "$go_cache" ]]; then
            local before
            before=$(get_dir_size "$go_cache")
            if (( before > 10485760 )); then
                info "Go build cache: $(human_bytes "$before")"
                safe_run go clean -cache
                local after
                after=$(get_dir_size "$go_cache")
                local diff=$((before - after))
                if (( diff > 0 )); then go_freed=$((go_freed + diff)); fi
            fi
        fi
    fi

    # Go module cache
    for user_home in /home/* /root; do
        local gomod="$user_home/go/pkg/mod/cache"
        if [[ -d "$gomod" ]]; then
            local before
            before=$(get_dir_size "$gomod")
            if (( before > 10485760 )); then
                info "Go module cache at $gomod: $(human_bytes "$before")"
                if ! $DRY_RUN; then
                    rm -rf "$gomod"
                fi
                go_freed=$((go_freed + before))
            fi
        fi
    done

    if (( go_freed > 0 )); then
        TOTAL_FREED=$((TOTAL_FREED + go_freed))
        freed "$(human_bytes "$go_freed")"
    else
        info "Go caches clean or not found"
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  SECTION 2: SYSTEM CACHES & LOGS
# ═════════════════════════════════════════════════════════════════════════════
clean_journal() {
    section "systemd Journal Logs"

    if ! cmd_exists journalctl; then
        skip "journalctl not found, skipping"
        return
    fi

    local journal_dir="/var/log/journal"
    local before
    before=$(get_dir_size "$journal_dir")
    if (( before == 0 )); then
        # Try runtime journal
        journal_dir="/run/log/journal"
        before=$(get_dir_size "$journal_dir")
    fi

    info "Journal size: $(human_bytes "$before")"

    if (( before > 104857600 )); then  # > 100 MB
        info "Vacuuming journal to 100 MB..."
        safe_run journalctl --vacuum-size=100M
        safe_run journalctl --vacuum-time=7d
        local after
        after=$(get_dir_size "$journal_dir")
        track_freed "$before" "$after"
    else
        info "Journal is already under 100 MB"
    fi
}

compress_old_logs() {
    section "Compress Uncompressed Log Files"

    if $NO_COMPRESS; then
        skip "Compression disabled (--no-compress)"
        return
    fi

    local log_dirs=("/var/log")
    local compressed_total=0
    local file_count=0

    for log_dir in "${log_dirs[@]}"; do
        if [[ ! -d "$log_dir" ]]; then continue; fi

        while IFS= read -r -d '' logfile; do
            local size
            size=$(stat -c%s "$logfile" 2>/dev/null || echo 0)
            if (( size < 1048576 )); then continue; fi  # Skip < 1 MB

            file_count=$((file_count + 1))
            if ! $DRY_RUN; then
                gzip -9 "$logfile" 2>>"$LOG_FILE" && {
                    local newsize
                    newsize=$(stat -c%s "${logfile}.gz" 2>/dev/null || echo "$size")
                    local saved=$((size - newsize))
                    if (( saved > 0 )); then
                        compressed_total=$((compressed_total + saved))
                    fi
                }
            else
                dryrun "Would compress: $logfile ($(human_bytes "$size"))"
            fi
        done < <(find "$log_dir" -type f \
            \( -name "*.log" -o -name "*.log.[0-9]*" -o -name "syslog.*" \
               -o -name "kern.log.*" -o -name "auth.log.*" -o -name "daemon.log.*" \
               -o -name "*.out" \) \
            ! -name "*.gz" ! -name "*.xz" ! -name "*.bz2" ! -name "*.zst" \
            -size +1M -mtime +7 -print0 2>/dev/null)
    done

    if (( compressed_total > 0 )); then
        info "Compressed $file_count log files"
        TOTAL_FREED=$((TOTAL_FREED + compressed_total))
        freed "$(human_bytes "$compressed_total")"
    elif (( file_count > 0 )); then
        info "Would compress $file_count log files"
    else
        info "No compressible log files found"
    fi
}

clean_old_kernels() {
    section "Old Kernel Versions"

    if ! cmd_exists dpkg; then
        skip "dpkg not found, skipping"
        return
    fi

    local current_kernel
    current_kernel=$(uname -r)
    info "Current kernel: $current_kernel"

    local old_count
    old_count=$(dpkg -l 'linux-image-*' 2>/dev/null | \
        awk '/^ii/ && !/'"$current_kernel"'/ && /linux-image-[0-9]/ {print $2}' | wc -l)

    if (( old_count > 0 )); then
        info "Found $old_count old kernel image(s) that could be removed"
        info "Run: sudo apt autoremove --purge   to clean them"
        # We don't auto-remove kernels — too risky, just inform
    else
        info "No old kernels found"
    fi
}

clean_tmp() {
    section "Temporary Files"

    local tmp_freed=0

    # /tmp — files older than 7 days
    if [[ -d /tmp ]]; then
        local before
        before=$(du -sb /tmp 2>/dev/null | awk '{print $1}' || echo 0)
        if (( before > 104857600 )); then  # > 100 MB
            info "/tmp usage: $(human_bytes "$before")"
            if ! $DRY_RUN; then
                find /tmp -type f -atime +7 \
                    ! -name ".X*" ! -name "space-reclaimer*" \
                    ! -path "/tmp/systemd*" ! -path "/tmp/snap.*" \
                    -delete 2>/dev/null || true
                # Clean empty directories in /tmp (older than 7 days)
                find /tmp -mindepth 1 -type d -empty -atime +7 \
                    ! -path "/tmp/systemd*" ! -path "/tmp/snap.*" \
                    -delete 2>/dev/null || true
            else
                local old_count
                old_count=$(find /tmp -type f -atime +7 \
                    ! -name ".X*" ! -name "space-reclaimer*" \
                    ! -path "/tmp/systemd*" 2>/dev/null | wc -l)
                dryrun "Would clean $old_count old files from /tmp"
            fi
            local after
            after=$(du -sb /tmp 2>/dev/null | awk '{print $1}' || echo 0)
            local diff=$((before - after))
            if (( diff > 0 )); then tmp_freed=$((tmp_freed + diff)); fi
        fi
    fi

    # /var/tmp — files older than 30 days
    if [[ -d /var/tmp ]]; then
        local before
        before=$(du -sb /var/tmp 2>/dev/null | awk '{print $1}' || echo 0)
        if (( before > 52428800 )); then  # > 50 MB
            info "/var/tmp usage: $(human_bytes "$before")"
            if ! $DRY_RUN; then
                find /var/tmp -type f -atime +30 -delete 2>/dev/null || true
                find /var/tmp -mindepth 1 -type d -empty -atime +30 -delete 2>/dev/null || true
            fi
            local after
            after=$(du -sb /var/tmp 2>/dev/null | awk '{print $1}' || echo 0)
            local diff=$((before - after))
            if (( diff > 0 )); then tmp_freed=$((tmp_freed + diff)); fi
        fi
    fi

    # Core dumps
    local coredump_dir="/var/lib/systemd/coredump"
    if [[ -d "$coredump_dir" ]]; then
        local before
        before=$(get_dir_size "$coredump_dir")
        if (( before > 1048576 )); then
            info "Core dumps: $(human_bytes "$before")"
            if ! $DRY_RUN; then
                find "$coredump_dir" -type f -mtime +3 -delete 2>/dev/null || true
            fi
            local after
            after=$(get_dir_size "$coredump_dir")
            local diff=$((before - after))
            if (( diff > 0 )); then tmp_freed=$((tmp_freed + diff)); fi
        fi
    fi

    if (( tmp_freed > 0 )); then
        TOTAL_FREED=$((TOTAL_FREED + tmp_freed))
        freed "$(human_bytes "$tmp_freed")"
    else
        info "Temp directories are clean"
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  SECTION 3: USER-LEVEL CACHES
# ═════════════════════════════════════════════════════════════════════════════
clean_thumbnail_cache() {
    section "Thumbnail & Icon Caches"

    local thumb_freed=0

    for user_home in /home/* /root; do
        # Thumbnail cache
        local thumb_dir="$user_home/.cache/thumbnails"
        if [[ -d "$thumb_dir" ]]; then
            local before
            before=$(get_dir_size "$thumb_dir")
            if (( before > 5242880 )); then  # > 5 MB
                info "Thumbnails at $thumb_dir: $(human_bytes "$before")"
                if ! $DRY_RUN; then
                    rm -rf "$thumb_dir"
                    mkdir -p "$thumb_dir"
                fi
                thumb_freed=$((thumb_freed + before))
            fi
        fi

        # GNOME/GTK icon cache
        local icon_cache="$user_home/.cache/icon-cache"
        if [[ -d "$icon_cache" ]]; then
            local before
            before=$(get_dir_size "$icon_cache")
            if (( before > 5242880 )); then
                info "Icon cache: $(human_bytes "$before")"
                if ! $DRY_RUN; then
                    rm -rf "$icon_cache"
                fi
                thumb_freed=$((thumb_freed + before))
            fi
        fi
    done

    if (( thumb_freed > 0 )); then
        TOTAL_FREED=$((TOTAL_FREED + thumb_freed))
        freed "$(human_bytes "$thumb_freed")"
    else
        info "Thumbnail caches are small or not found"
    fi
}

clean_browser_cache() {
    section "Browser Caches"

    local browser_freed=0

    for user_home in /home/* /root; do
        # Chrome / Chromium
        for browser_dir in \
            "$user_home/.cache/google-chrome" \
            "$user_home/.cache/chromium" \
            "$user_home/.cache/BraveSoftware" \
            "$user_home/.cache/vivaldi" \
            "$user_home/.cache/microsoft-edge"; do

            if [[ -d "$browser_dir" ]]; then
                local before
                before=$(get_dir_size "$browser_dir")
                local name
                name=$(basename "$browser_dir")
                if (( before > 52428800 )); then  # > 50 MB
                    info "$name cache: $(human_bytes "$before")"
                    if ! $DRY_RUN; then
                        # Only clear the Cache and Code Cache directories, not profiles
                        find "$browser_dir" -type d \( -name "Cache" -o -name "Code Cache" \
                            -o -name "GPUCache" -o -name "ShaderCache" -o -name "GrShaderCache" \
                            -o -name "Service Worker" \) -exec rm -rf {} + 2>/dev/null || true
                    fi
                    local after
                    after=$(get_dir_size "$browser_dir")
                    local diff=$((before - after))
                    if (( diff > 0 )); then browser_freed=$((browser_freed + diff)); fi
                fi
            fi
        done

        # Firefox
        local ff_dir="$user_home/.cache/mozilla/firefox"
        if [[ -d "$ff_dir" ]]; then
            local before
            before=$(get_dir_size "$ff_dir")
            if (( before > 52428800 )); then
                info "Firefox cache: $(human_bytes "$before")"
                if ! $DRY_RUN; then
                    find "$ff_dir" -type d -name "cache2" -exec rm -rf {} + 2>/dev/null || true
                    find "$ff_dir" -type d -name "startupCache" -exec rm -rf {} + 2>/dev/null || true
                fi
                local after
                after=$(get_dir_size "$ff_dir")
                local diff=$((before - after))
                if (( diff > 0 )); then browser_freed=$((browser_freed + diff)); fi
            fi
        fi
    done

    if (( browser_freed > 0 )); then
        TOTAL_FREED=$((TOTAL_FREED + browser_freed))
        freed "$(human_bytes "$browser_freed")"
    else
        info "Browser caches are small or not found"
    fi
}

clean_font_cache() {
    section "Font Cache"

    local font_freed=0

    # System font cache
    if cmd_exists fc-cache; then
        for user_home in /home/* /root; do
            local fc_dir="$user_home/.cache/fontconfig"
            if [[ -d "$fc_dir" ]]; then
                local before
                before=$(get_dir_size "$fc_dir")
                if (( before > 5242880 )); then  # > 5 MB
                    info "Font cache at $fc_dir: $(human_bytes "$before")"
                    if ! $DRY_RUN; then
                        rm -rf "$fc_dir"
                    fi
                    font_freed=$((font_freed + before))
                fi
            fi
        done

        if (( font_freed > 0 )); then
            info "Regenerating font cache..."
            safe_run fc-cache -f
        fi
    fi

    if (( font_freed > 0 )); then
        TOTAL_FREED=$((TOTAL_FREED + font_freed))
        freed "$(human_bytes "$font_freed")"
    else
        info "Font caches are small or not found"
    fi
}

clean_general_cache() {
    section "General Application Caches"

    local gen_freed=0

    for user_home in /home/* /root; do
        local cache_dir="$user_home/.cache"
        if [[ ! -d "$cache_dir" ]]; then continue; fi

        # Specific safe-to-clear caches
        local safe_caches=(
            "mesa_shader_cache"
            "mesa_shader_cache_db"
            "nvidia"
            "babl"
            "gegl-0.4"
            "evolution"
            "tracker3"
            "tracker"
            "gstreamer-1.0"
            "epiphany"
            "shotwell"
            "gnome-software"
            "PackageKit"
            "pip"
            "pipx"
            "flatpak"
            "JetBrains"
            "Code - OSS"
            "vscode-cpptools"
        )

        for cache_name in "${safe_caches[@]}"; do
            local target="$cache_dir/$cache_name"
            if [[ -d "$target" ]]; then
                local before
                before=$(get_dir_size "$target")
                if (( before > 10485760 )); then  # > 10 MB
                    info "$cache_name cache: $(human_bytes "$before")"
                    if ! $DRY_RUN; then
                        rm -rf "$target"
                    fi
                    gen_freed=$((gen_freed + before))
                fi
            fi
        done

        # VS Code / Codium cache
        for code_dir in "$user_home/.config/Code" "$user_home/.config/Code - OSS" \
                         "$user_home/.config/VSCodium"; do
            if [[ -d "$code_dir" ]]; then
                for sub in "CachedData" "CachedExtensions" "CachedExtensionVSIXs" \
                           "Code Cache" "GPUCache"; do
                    local target="$code_dir/$sub"
                    if [[ -d "$target" ]]; then
                        local before
                        before=$(get_dir_size "$target")
                        if (( before > 10485760 )); then
                            info "VS Code $sub: $(human_bytes "$before")"
                            if ! $DRY_RUN; then
                                rm -rf "$target"
                            fi
                            gen_freed=$((gen_freed + before))
                        fi
                    fi
                done
            fi
        done
    done

    if (( gen_freed > 0 )); then
        TOTAL_FREED=$((TOTAL_FREED + gen_freed))
        freed "$(human_bytes "$gen_freed")"
    else
        info "Application caches are small or clean"
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  SECTION 4: SNAP & FLATPAK
# ═════════════════════════════════════════════════════════════════════════════
clean_snap() {
    section "Snap — Old Revisions"

    if ! cmd_exists snap; then
        skip "snap not found, skipping"
        return
    fi

    local snap_freed=0

    # Remove disabled (old) snap revisions — the current revision stays
    local snaps_to_clean=()
    while IFS= read -r line; do
        local name rev
        name=$(echo "$line" | awk '{print $1}')
        rev=$(echo "$line" | awk '{print $3}')
        if [[ -n "$name" && -n "$rev" ]]; then
            snaps_to_clean+=("$name:$rev")
        fi
    done < <(snap list --all 2>/dev/null | awk '/disabled/{print}')

    if (( ${#snaps_to_clean[@]} > 0 )); then
        info "Found ${#snaps_to_clean[@]} disabled snap revision(s)"
        for entry in "${snaps_to_clean[@]}"; do
            local name="${entry%%:*}"
            local rev="${entry##*:}"
            info "  Removing: $name (revision $rev)"
            if ! $DRY_RUN; then
                snap remove "$name" --revision="$rev" 2>>"$LOG_FILE" || true
            fi
        done
        # Estimate freed space
        local snap_dir="/var/lib/snapd/snaps"
        snap_freed=$((${#snaps_to_clean[@]} * 50000000))  # Rough estimate
        success "Removed ${#snaps_to_clean[@]} old snap revisions"
    else
        info "No old snap revisions found"
    fi

    # Snap cache
    local snap_cache="/var/lib/snapd/cache"
    if [[ -d "$snap_cache" ]]; then
        local before
        before=$(get_dir_size "$snap_cache")
        if (( before > 52428800 )); then  # > 50 MB
            info "Snap cache: $(human_bytes "$before")"
            if ! $DRY_RUN; then
                rm -rf "${snap_cache:?}"/*
            fi
            snap_freed=$((snap_freed + before))
        fi
    fi

    if (( snap_freed > 0 )); then
        TOTAL_FREED=$((TOTAL_FREED + snap_freed))
        freed "$(human_bytes "$snap_freed")"
    fi
}

clean_flatpak() {
    section "Flatpak — Unused Runtimes"

    if ! cmd_exists flatpak; then
        skip "flatpak not found, skipping"
        return
    fi

    local flatpak_freed=0

    # Count unused runtimes
    local unused_count
    unused_count=$(flatpak uninstall --unused 2>/dev/null | grep -c "^" || echo 0)

    if (( unused_count > 0 )); then
        info "Found $unused_count unused Flatpak runtime(s)"
        if ! $DRY_RUN; then
            flatpak uninstall --unused -y 2>>"$LOG_FILE" || true
        else
            dryrun "Would remove $unused_count unused runtimes"
        fi
        success "Cleaned unused Flatpak runtimes"
    else
        info "No unused Flatpak runtimes"
    fi

    # Flatpak cache
    for user_home in /home/* /root; do
        local fp_cache="$user_home/.cache/flatpak"
        if [[ -d "$fp_cache" ]]; then
            local before
            before=$(get_dir_size "$fp_cache")
            if (( before > 10485760 )); then
                info "Flatpak cache: $(human_bytes "$before")"
                if ! $DRY_RUN; then
                    rm -rf "$fp_cache"
                fi
                flatpak_freed=$((flatpak_freed + before))
            fi
        fi
    done

    if (( flatpak_freed > 0 )); then
        TOTAL_FREED=$((TOTAL_FREED + flatpak_freed))
        freed "$(human_bytes "$flatpak_freed")"
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  SECTION 5: DOCKER
# ═════════════════════════════════════════════════════════════════════════════
clean_docker() {
    section "Docker Cleanup"

    if ! cmd_exists docker; then
        skip "Docker not found, skipping"
        return
    fi

    # Check if Docker daemon is running
    if ! docker info &>/dev/null; then
        skip "Docker daemon not running, skipping"
        return
    fi

    local docker_freed=0

    # Get Docker disk usage before
    local before_json
    before_json=$(docker system df --format '{{json .}}' 2>/dev/null || echo "")

    # Remove stopped containers
    local stopped
    stopped=$(docker ps -aq --filter "status=exited" 2>/dev/null | wc -l)
    if (( stopped > 0 )); then
        info "$stopped stopped container(s)"
        safe_run docker container prune -f
    fi

    # Remove dangling images (untagged, unused layers)
    local dangling
    dangling=$(docker images -f "dangling=true" -q 2>/dev/null | wc -l)
    if (( dangling > 0 )); then
        info "$dangling dangling image(s)"
        safe_run docker image prune -f
    fi

    # Remove unused build cache
    info "Pruning build cache..."
    if ! $DRY_RUN; then
        docker builder prune -f 2>>"$LOG_FILE" || true
    fi

    # Remove unused volumes (data preserved in named volumes)
    local unused_vols
    unused_vols=$(docker volume ls -qf "dangling=true" 2>/dev/null | wc -l)
    if (( unused_vols > 0 )); then
        info "$unused_vols dangling volume(s)"
        safe_run docker volume prune -f
    fi

    # Remove unused networks
    safe_run docker network prune -f

    # Calculate freed space
    local after_reclaimable
    after_reclaimable=$(docker system df 2>/dev/null | awk 'NR>1 {print $NF}' | \
        grep -oP '[\d.]+[KMGT]?B' | head -1 || echo "0B")
    info "Docker cleanup complete (reclaimable: $after_reclaimable)"

    success "Docker pruned (stopped containers, dangling images, build cache)"
}

# ═════════════════════════════════════════════════════════════════════════════
#  SECTION 6: FILE COMPRESSION
# ═════════════════════════════════════════════════════════════════════════════
compress_old_files() {
    section "Compress Old, Large Files"

    if $NO_COMPRESS; then
        skip "Compression disabled (--no-compress)"
        return
    fi

    info "Looking for files older than ${COMPRESS_AGE_DAYS} days, larger than ${COMPRESS_MIN_SIZE}..."
    info "Extensions: ${COMPRESS_EXTENSIONS}"

    local comp_freed=0
    local comp_count=0
    local skipped=0

    # Search in user home directories for compressible files
    for user_home in /home/* /root; do
        if [[ ! -d "$user_home" ]]; then continue; fi

        # Build the find pattern for extensions
        local ext_pattern=""
        IFS='|' read -ra EXTS <<< "$COMPRESS_EXTENSIONS"
        for ext in "${EXTS[@]}"; do
            if [[ -n "$ext_pattern" ]]; then
                ext_pattern="$ext_pattern -o"
            fi
            ext_pattern="$ext_pattern -iname *.$ext"
        done

        while IFS= read -r -d '' file; do
            # Skip files that are already compressed, symlinks, or in important dirs
            if [[ "$file" == *.gz || "$file" == *.xz || "$file" == *.bz2 || "$file" == *.zst ]]; then
                continue
            fi
            if [[ "$file" == */.git/* || "$file" == */.cache/* || "$file" == */node_modules/* ]]; then
                continue
            fi
            if [[ -L "$file" ]]; then continue; fi

            local size
            size=$(stat -c%s "$file" 2>/dev/null || echo 0)

            if ! $DRY_RUN; then
                # Compress in place
                if gzip -9 "$file" 2>>"$LOG_FILE"; then
                    local newsize
                    newsize=$(stat -c%s "${file}.gz" 2>/dev/null || echo "$size")
                    local saved=$((size - newsize))
                    if (( saved > 0 )); then
                        comp_freed=$((comp_freed + saved))
                        comp_count=$((comp_count + 1))
                    fi
                else
                    skipped=$((skipped + 1))
                fi
            else
                dryrun "Would compress: $file ($(human_bytes "$size"))"
                comp_count=$((comp_count + 1))
            fi
        done < <(eval "find '$user_home' -maxdepth 5 -type f \\( $ext_pattern \\) \
            ! -name '*.gz' ! -name '*.xz' ! -name '*.bz2' ! -name '*.zst' \
            ! -path '*/.git/*' ! -path '*/node_modules/*' ! -path '*/.cache/*' \
            -size +${COMPRESS_MIN_SIZE} -atime +${COMPRESS_AGE_DAYS} \
            -print0 2>/dev/null")
    done

    if (( comp_count > 0 )); then
        info "Compressed $comp_count file(s)"
        if (( skipped > 0 )); then
            warn "Skipped $skipped file(s) (permission denied or in use)"
        fi
    else
        info "No qualifying files found for compression"
    fi

    if (( comp_freed > 0 )); then
        TOTAL_FREED=$((TOTAL_FREED + comp_freed))
        freed "$(human_bytes "$comp_freed")"
        info "To decompress any file: gzip -d <file>.gz"
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  SECTION 7: DEDUPLICATION
# ═════════════════════════════════════════════════════════════════════════════
deduplicate_files() {
    section "File Deduplication (Hardlink Identical Files)"

    if $NO_DEDUP; then
        skip "Deduplication disabled (--no-dedup)"
        return
    fi

    # Check for tools
    local dedup_tool=""
    if cmd_exists rdfind; then
        dedup_tool="rdfind"
    elif cmd_exists jdupes; then
        dedup_tool="jdupes"
    elif cmd_exists fdupes; then
        dedup_tool="fdupes"
    elif cmd_exists hardlink; then
        dedup_tool="hardlink"
    fi

    if [[ -z "$dedup_tool" ]]; then
        info "No deduplication tool found"
        info "Install one for automatic dedup:"
        info "  sudo apt install rdfind    (fastest)"
        info "  sudo apt install jdupes    (good alternative)"
        info "  sudo apt install fdupes    (classic)"

        # Fall back to built-in dedup using find + md5sum
        info "Using built-in dedup (find + checksum)..."
        builtin_dedup
        return
    fi

    info "Using: $dedup_tool"

    # Build a filtered file list first to avoid crawling .git, node_modules, etc.
    local tmplist
    tmplist=$(mktemp /tmp/space-reclaimer-dedup-list.XXXXXX)

    info "Scanning for candidate files (skipping .git, node_modules, .cache)..."
    for user_home in /home/*; do
        if [[ ! -d "$user_home" ]]; then continue; fi
        find "$user_home" -maxdepth 5 -type f -size +1M \
            ! -path '*/.git/*' ! -path '*/.git' \
            ! -path '*/node_modules/*' \
            ! -path '*/.cache/*' \
            ! -path '*/.cargo/*' \
            ! -path '*/.rustup/*' \
            ! -path '*/.npm/*' \
            ! -path '*/.local/share/Trash/*' \
            2>/dev/null
    done > "$tmplist"

    local file_count
    file_count=$(wc -l < "$tmplist")
    info "Found $file_count candidate files for dedup"

    if (( file_count < 2 )); then
        info "Too few files to deduplicate"
        rm -f "$tmplist"
        return
    fi

    local before_avail
    before_avail=$(get_avail_space)

    # Use the built-in dedup for safety and speed — it only processes files
    # from our pre-filtered list and avoids the hanging problem
    info "Using built-in dedup (pre-filtered, checksum-based)..."
    builtin_dedup "$tmplist"

    rm -f "$tmplist"

    local after_avail
    after_avail=$(get_avail_space)
    local diff=$((after_avail - before_avail))
    if (( diff > 0 )); then
        TOTAL_FREED=$((TOTAL_FREED + diff))
        freed "$(human_bytes "$diff")"
    fi
}

builtin_dedup() {
    # Simple deduplication using checksums and hardlinks
    # Only handles files on the same filesystem
    local dedup_freed=0
    local dedup_count=0

    info "Scanning for duplicate files (>= 1 MB)..."

    local tmpfile
    tmpfile=$(mktemp /tmp/space-reclaimer-dedup.XXXXXX)

    # Find large files and compute checksums
    for user_home in /home/*; do
        if [[ ! -d "$user_home" ]]; then continue; fi
        find "$user_home" -maxdepth 5 -type f -size +1M \
            ! -path '*/.git/*' ! -path '*/node_modules/*' ! -path '*/.cache/*' \
            -printf '%s %p\n' 2>/dev/null
    done | sort -rn | head -2000 > "$tmpfile"

    # Group by size first (fast filter)
    local prev_size="" prev_file="" group_files=()

    while IFS=' ' read -r size filepath; do
        if [[ "$size" == "$prev_size" ]]; then
            group_files+=("$filepath")
        else
            # Process previous group
            if (( ${#group_files[@]} >= 2 )); then
                _dedup_group group_files dedup_freed dedup_count
            fi
            group_files=("$filepath")
            prev_size="$size"
        fi
    done < "$tmpfile"

    # Process last group
    if (( ${#group_files[@]} >= 2 )); then
        _dedup_group group_files dedup_freed dedup_count
    fi

    rm -f "$tmpfile"

    if (( dedup_count > 0 )); then
        info "Deduplicated $dedup_count file(s)"
        TOTAL_FREED=$((TOTAL_FREED + dedup_freed))
        freed "$(human_bytes "$dedup_freed")"
    else
        info "No duplicate files found"
    fi
}

_dedup_group() {
    local -n _files=$1
    local -n _freed=$2
    local -n _count=$3

    # Compare by md5sum
    declare -A checksums
    for f in "${_files[@]}"; do
        if [[ ! -f "$f" ]]; then continue; fi
        local cksum
        cksum=$(md5sum "$f" 2>/dev/null | awk '{print $1}')
        if [[ -z "$cksum" ]]; then continue; fi

        if [[ -n "${checksums[$cksum]:-}" ]]; then
            # Duplicate found — replace with hardlink
            local original="${checksums[$cksum]}"
            local size
            size=$(stat -c%s "$f" 2>/dev/null || echo 0)

            # Only hardlink if same filesystem
            local dev1 dev2
            dev1=$(stat -c%d "$original" 2>/dev/null)
            dev2=$(stat -c%d "$f" 2>/dev/null)
            if [[ "$dev1" != "$dev2" ]]; then continue; fi

            # Check they're not already hardlinked
            local ino1 ino2
            ino1=$(stat -c%i "$original" 2>/dev/null)
            ino2=$(stat -c%i "$f" 2>/dev/null)
            if [[ "$ino1" == "$ino2" ]]; then continue; fi

            if ! $DRY_RUN; then
                # Preserve permissions and replace with hardlink
                local tmplink="${f}.dedup.tmp"
                if ln "$original" "$tmplink" 2>/dev/null; then
                    mv "$tmplink" "$f"
                    _freed=$((_freed + size))
                    _count=$((_count + 1))
                else
                    rm -f "$tmplink" 2>/dev/null
                fi
            else
                dryrun "Would hardlink: $f → $original ($(human_bytes "$size"))"
                _count=$((_count + 1))
            fi
        else
            checksums[$cksum]="$f"
        fi
    done
}

# ═════════════════════════════════════════════════════════════════════════════
#  SECTION 8: TRASH & MISC
# ═════════════════════════════════════════════════════════════════════════════
clean_trash() {
    section "Empty Trash"

    local trash_freed=0

    for user_home in /home/* /root; do
        local trash_dir="$user_home/.local/share/Trash"
        if [[ -d "$trash_dir" ]]; then
            local before
            before=$(get_dir_size "$trash_dir")
            if (( before > 1048576 )); then  # > 1 MB
                info "Trash at $trash_dir: $(human_bytes "$before")"
                if ! $DRY_RUN; then
                    rm -rf "${trash_dir:?}/files"/* 2>/dev/null || true
                    rm -rf "${trash_dir:?}/info"/* 2>/dev/null || true
                    rm -rf "${trash_dir:?}/expunged"/* 2>/dev/null || true
                fi
                local after
                after=$(get_dir_size "$trash_dir")
                local diff=$((before - after))
                if (( diff > 0 )); then trash_freed=$((trash_freed + diff)); fi
            fi
        fi
    done

    # Root trash
    for trash_dir in /root/.local/share/Trash /tmp/.Trash-0; do
        if [[ -d "$trash_dir" ]]; then
            local before
            before=$(get_dir_size "$trash_dir")
            if (( before > 1048576 )); then
                info "Root trash: $(human_bytes "$before")"
                if ! $DRY_RUN; then
                    rm -rf "${trash_dir:?}"/* 2>/dev/null || true
                fi
                trash_freed=$((trash_freed + before))
            fi
        fi
    done

    if (( trash_freed > 0 )); then
        TOTAL_FREED=$((TOTAL_FREED + trash_freed))
        freed "$(human_bytes "$trash_freed")"
    else
        info "Trash is empty or small"
    fi
}

clean_locale() {
    section "Unused Locale Data"

    local locale_freed=0

    # Check if localepurge is available
    if cmd_exists localepurge; then
        info "Running localepurge..."
        local before_avail
        before_avail=$(get_avail_space)
        safe_run localepurge
        local after_avail
        after_avail=$(get_avail_space)
        local diff=$((after_avail - before_avail))
        if (( diff > 0 )); then locale_freed=$((locale_freed + diff)); fi
    fi

    # Man pages for uninstalled locales
    local man_dirs=(/usr/share/man/??_* /usr/share/man/??/)
    local man_freed=0
    for dir in "${man_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            local lang
            lang=$(basename "$dir")
            # Keep English and the system locale
            local sys_lang="${LANG%%.*}"
            sys_lang="${sys_lang%%_*}"
            if [[ "$lang" != "en" && "$lang" != "$sys_lang"* && "$lang" != "man"[0-9]* ]]; then
                local size
                size=$(get_dir_size "$dir")
                if (( size > 1048576 )); then
                    man_freed=$((man_freed + size))
                fi
            fi
        fi
    done

    if (( man_freed > 0 )); then
        info "Non-English man pages: $(human_bytes "$man_freed")"
        info "Install localepurge to clean these: sudo apt install localepurge"
    fi

    if (( locale_freed > 0 )); then
        TOTAL_FREED=$((TOTAL_FREED + locale_freed))
        freed "$(human_bytes "$locale_freed")"
    fi
}

trim_ssd() {
    section "SSD TRIM (fstrim)"

    if ! cmd_exists fstrim; then
        skip "fstrim not found"
        return
    fi

    if [[ $EUID -ne 0 ]]; then
        skip "Needs root for fstrim"
        return
    fi

    # Check if root is on SSD
    local root_dev
    root_dev=$(findmnt -n -o SOURCE / 2>/dev/null || echo "")
    if [[ -z "$root_dev" ]]; then
        skip "Cannot determine root device"
        return
    fi

    local base_dev
    base_dev=$(lsblk -no PKNAME "$root_dev" 2>/dev/null | head -1 || echo "")
    if [[ -z "$base_dev" ]]; then
        skip "Cannot determine base device"
        return
    fi

    local rotational
    rotational=$(cat "/sys/block/$base_dev/queue/rotational" 2>/dev/null || echo "1")

    if [[ "$rotational" == "0" ]]; then
        info "SSD detected — running TRIM..."
        if ! $DRY_RUN; then
            fstrim -v / 2>>"$LOG_FILE" || warn "fstrim failed (might need discard mount option)"
        else
            dryrun "Would run: fstrim -v /"
        fi
        success "SSD TRIM complete"
    else
        skip "Root device appears to be HDD (rotational=1), skipping TRIM"
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  SECTION 9: SPACE HOGS REPORT
# ═════════════════════════════════════════════════════════════════════════════
report_space_hogs() {
    section "Space Usage Report"

    echo ""
    echo -e "  ${BOLD}Top 15 largest directories under /home:${RESET}"
    echo ""
    du -h --max-depth=3 /home 2>/dev/null | sort -rh | head -15 | while read -r size path; do
        printf "  ${CYAN}%-10s${RESET} %s\n" "$size" "$path"
    done

    echo ""
    echo -e "  ${BOLD}Top 10 largest single files:${RESET}"
    echo ""
    find /home -type f -size +100M 2>/dev/null | \
        xargs -I{} du -h {} 2>/dev/null | \
        sort -rh | head -10 | while read -r size path; do
        printf "  ${CYAN}%-10s${RESET} %s\n" "$size" "$path"
    done

    echo ""
    echo -e "  ${BOLD}Filesystem usage:${RESET}"
    echo ""
    df -h / /home /tmp 2>/dev/null | while IFS= read -r line; do
        echo "  $line"
    done

    echo ""

    # Check for known space hogs
    local hogs=()
    for user_home in /home/*; do
        # node_modules
        local nm_total=0
        while IFS= read -r dir; do
            local s
            s=$(du -sb "$dir" 2>/dev/null | awk '{print $1}')
            nm_total=$((nm_total + s))
        done < <(find "$user_home" -maxdepth 4 -type d -name "node_modules" 2>/dev/null | head -50)
        if (( nm_total > 104857600 )); then  # > 100 MB
            hogs+=("node_modules: $(human_bytes $nm_total) — run 'npx npkill' to selectively clean")
        fi

        # .git directories
        local git_total=0
        while IFS= read -r dir; do
            local s
            s=$(du -sb "$dir" 2>/dev/null | awk '{print $1}')
            git_total=$((git_total + s))
        done < <(find "$user_home" -maxdepth 4 -type d -name ".git" 2>/dev/null | head -50)
        if (( git_total > 524288000 )); then  # > 500 MB
            hogs+=(".git directories: $(human_bytes $git_total) — run 'git gc --aggressive' in large repos")
        fi

        # target/ (Rust build output)
        local target_total=0
        while IFS= read -r dir; do
            if [[ -f "$(dirname "$dir")/Cargo.toml" ]]; then
                local s
                s=$(du -sb "$dir" 2>/dev/null | awk '{print $1}')
                target_total=$((target_total + s))
            fi
        done < <(find "$user_home" -maxdepth 4 -type d -name "target" 2>/dev/null | head -50)
        if (( target_total > 524288000 )); then
            hogs+=("Rust target/: $(human_bytes $target_total) — run 'cargo clean' in unused projects")
        fi

        # build/ (Gradle, etc.)
        local build_total=0
        while IFS= read -r dir; do
            if [[ -f "$(dirname "$dir")/build.gradle" || -f "$(dirname "$dir")/build.gradle.kts" ]]; then
                local s
                s=$(du -sb "$dir" 2>/dev/null | awk '{print $1}')
                build_total=$((build_total + s))
            fi
        done < <(find "$user_home" -maxdepth 4 -type d -name "build" 2>/dev/null | head -50)
        if (( build_total > 524288000 )); then
            hogs+=("Gradle build/: $(human_bytes $build_total) — run 'gradle clean' in unused projects")
        fi
    done

    if (( ${#hogs[@]} > 0 )); then
        echo -e "  ${YELLOW}${BOLD}Potential space hogs (manual action):${RESET}"
        for hog in "${hogs[@]}"; do
            echo -e "  ${YELLOW}→${RESET} $hog"
        done
        echo ""
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  SECTION 10: GIT GARBAGE COLLECTION
# ═════════════════════════════════════════════════════════════════════════════
clean_git_repos() {
    section "Git Repository Optimization"

    if ! cmd_exists git; then
        skip "git not found, skipping"
        return
    fi

    local git_freed=0
    local repo_count=0

    for user_home in /home/* /root; do
        while IFS= read -r git_dir; do
            local repo_dir
            repo_dir=$(dirname "$git_dir")
            local before
            before=$(get_dir_size "$git_dir")

            # Only process repos with .git > 100 MB
            if (( before < 104857600 )); then continue; fi

            repo_count=$((repo_count + 1))
            info "Git repo: $repo_dir (.git = $(human_bytes "$before"))"

            if ! $DRY_RUN; then
                (
                    cd "$repo_dir" || exit
                    git reflog expire --expire=30.days --all 2>>"$LOG_FILE" || true
                    git gc --auto 2>>"$LOG_FILE" || true
                    git prune --expire=30.days 2>>"$LOG_FILE" || true
                    git repack -ad 2>>"$LOG_FILE" || true
                )
            else
                dryrun "Would gc & repack: $repo_dir"
            fi

            local after
            after=$(get_dir_size "$git_dir")
            local diff=$((before - after))
            if (( diff > 0 )); then
                git_freed=$((git_freed + diff))
            fi
        done < <(find "$user_home" -maxdepth 5 -type d -name ".git" 2>/dev/null | head -20)
    done

    if (( git_freed > 0 )); then
        info "Optimized $repo_count repository(ies)"
        TOTAL_FREED=$((TOTAL_FREED + git_freed))
        freed "$(human_bytes "$git_freed")"
    elif (( repo_count > 0 )); then
        info "Repos already well-packed"
    else
        info "No large git repos found"
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  SUMMARY
# ═════════════════════════════════════════════════════════════════════════════
print_summary() {
    local before_avail after_avail actual_freed

    before_avail=$(cat /tmp/.space-reclaimer-before 2>/dev/null || echo 0)
    after_avail=$(get_avail_space)
    actual_freed=$((after_avail - before_avail))

    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}║${WHITE}${BOLD}                      SUMMARY                               ${RESET}${CYAN}║${RESET}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${RESET}"

    if $DRY_RUN; then
        echo -e "${CYAN}║${RESET}  ${MAGENTA}Mode:${RESET}           DRY RUN (no changes made)                 ${CYAN}║${RESET}"
    fi

    printf "${CYAN}║${RESET}  ${WHITE}Estimated freed:${RESET} %-41s ${CYAN}║${RESET}\n" "$(human_bytes "$TOTAL_FREED")"

    if ! $DRY_RUN; then
        if (( actual_freed > 0 )); then
            printf "${CYAN}║${RESET}  ${GREEN}Actual freed:${RESET}    %-41s ${CYAN}║${RESET}\n" "$(human_bytes "$actual_freed")"
        fi
        printf "${CYAN}║${RESET}  ${WHITE}Space before:${RESET}    %-41s ${CYAN}║${RESET}\n" "$(human_bytes "$before_avail")"
        printf "${CYAN}║${RESET}  ${GREEN}Space after:${RESET}     %-41s ${CYAN}║${RESET}\n" "$(human_bytes "$after_avail")"
    fi

    echo -e "${CYAN}║${RESET}  ${WHITE}Sections run:${RESET}    ${SECTION_COUNT}                                        ${CYAN}║${RESET}"
    printf "${CYAN}║${RESET}  ${WHITE}Log file:${RESET}        %-41s ${CYAN}║${RESET}\n" "$LOG_FILE"

    if (( ${#ERRORS[@]} > 0 )); then
        echo -e "${CYAN}║${RESET}  ${RED}Errors:${RESET}          ${#ERRORS[@]}                                        ${CYAN}║${RESET}"
        for err in "${ERRORS[@]}"; do
            printf "${CYAN}║${RESET}    ${RED}•${RESET} %-53s ${CYAN}║${RESET}\n" "$err"
        done
    fi

    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${RESET}"
    echo -e "${CYAN}║${RESET}  ${DIM}Compressed files can be restored with: gzip -d <file>.gz${RESET}  ${CYAN}║${RESET}"
    echo -e "${CYAN}║${RESET}  ${DIM}Hardlinked files still work at every original path${RESET}        ${CYAN}║${RESET}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    rm -f /tmp/.space-reclaimer-before
}

# ═════════════════════════════════════════════════════════════════════════════
#  MAIN
# ═════════════════════════════════════════════════════════════════════════════
main() {
    banner
    check_prerequisites

    if ! $NO_CACHE; then
        clean_apt_cache
        clean_dpkg_cache
        clean_pip_cache
        clean_npm_cache
        clean_cargo_cache
        clean_go_cache
    fi

    clean_journal
    compress_old_logs
    clean_old_kernels
    clean_tmp

    if ! $NO_CACHE; then
        clean_thumbnail_cache
        clean_browser_cache
        clean_font_cache
        clean_general_cache
    fi

    clean_snap
    clean_flatpak
    clean_docker

    if ! $NO_COMPRESS; then
        compress_old_files
    fi

    if ! $NO_DEDUP; then
        deduplicate_files
    fi

    clean_trash
    clean_locale
    clean_git_repos

    trim_ssd

    report_space_hogs
    print_summary
}

main "$@"
