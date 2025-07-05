#!/bin/bash

###############################################################################
# emmc_analyzer.sh — Professional eMMC lifetime and health analysis tool
# • Works with: curl -fsSL <url> | bash (using /dev/tty for input)
# • Works with: ./emmc_analyzer.sh
# • Works with: bash emmc_analyzer.sh
# • Detects all available eMMC devices in the system
# • Reads hardware lifetime estimates from eMMC registers
# • Calculates precise wear metrics and remaining lifespan
# • Provides detailed health assessment and recommendations
# • Supports multiple device analysis in a single session
###############################################################################

# ── Configuration ─────────────────────────────────────────────────────────────
readonly CYCLES_MAX=3000                    # Standard eMMC P/E cycles
readonly BYTES_PER_SECTOR=512               # Standard sector size
readonly SECONDS_PER_DAY=86400              # Time conversion
readonly DAYS_PER_YEAR=365                  # Time conversion
readonly WEAR_THRESHOLD_WARNING=50          # Warning threshold percentage
readonly WEAR_THRESHOLD_CRITICAL=80         # Critical threshold percentage

# ── Color definitions ─────────────────────────────────────────────────────────
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly NC='\033[0m'

# ── Logging utility ───────────────────────────────────────────────────────────
log()     { echo -e "$(date '+%F %T') | $*" >&2; }
info()    { echo -e "${BLUE}$*${NC}" >&2; }
success() { echo -e "${GREEN}$*${NC}" >&2; }
warning() { echo -e "${YELLOW}$*${NC}" >&2; }
error()   { echo -e "${RED}$*${NC}" >&2; }
title()   { echo -e "${BOLD}${CYAN}$*${NC}" >&2; }
subtitle(){ echo -e "${BOLD}${BLUE}$*${NC}" >&2; }
label()   { echo -e "${DIM}$*${NC}"; }
newline() { printf '\n' >&2; }

# ── Error handler ─────────────────────────────────────────────────────────────
error_handler() { 
    error "ERROR at line $1: $2"
    exit 1
}

# ── Validate system requirements ──────────────────────────────────────────────
validate_requirements() {
    if [[ ! -e /dev/tty ]]; then
        error "This script requires an interactive terminal. Please run it from a terminal session."
        exit 1
    fi
    
    if ! command -v mmc >/dev/null 2>&1; then
        error "mmc-utils not installed. Use: sudo apt install mmc-utils"
        exit 1
    fi
    
    if ! command -v bc >/dev/null 2>&1; then
        error "bc calculator not installed. Use: sudo apt install bc"
        exit 1
    fi
}

# ── Discover available eMMC devices ───────────────────────────────────────────
discover_emmc_devices() {
    local devices=()
    
    while IFS= read -r device; do
        [[ -n "$device" && -b "/dev/$device" ]] && devices+=("$device")
    done < <(lsblk -dno NAME | grep -E '^mmcblk[0-9]+' || true)

    (( ${#devices[@]} )) || return 1

    printf '%s\n' "${devices[@]}"
}

# ── Display devices menu ──────────────────────────────────────────────────────
show_menu() {
    local devices=("$@")

    newline
    subtitle "Available SD/eMMC devices:"
    newline

    for idx in "${!devices[@]}"; do
        local dev=${devices[$idx]}
        local size_sectors=$(cat "/sys/block/$dev/size" 2>/dev/null || echo 0)
        local size_gb=$(( size_sectors * BYTES_PER_SECTOR / 1024 / 1024 / 1024 ))
        echo -e "${DIM}  $((idx+1)))${NC} /dev/${dev} (${size_gb} GB)" >&2
    done

    newline
    echo -e "${DIM}  0)${NC} Exit" >&2
    newline
}

# ── Interactive device selection (always uses /dev/tty) ───────────────────────
select_device() {
    mapfile -t devices < <(discover_emmc_devices)
    if (( ${#devices[@]} == 0 )); then
        newline
        error "No SD/eMMC devices found. Please insert a device and retry."
        newline
        return 1
    fi

    while true; do
        show_menu "${devices[@]}"
        echo -n "Please select a device (1-${#devices[@]}, or 0 to exit): " >&2
        read -r choice < /dev/tty

        # Trim whitespace
        choice=$(echo "$choice" | tr -d '[:space:]')

        if [[ "$choice" == "0" ]]; then
            newline
            info "Exiting selection…"
            return 1
        fi

        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#devices[@]} )); then
            echo "${devices[choice-1]}"
            return 0
        fi

        newline
        warning "Invalid selection. Try again."
    done
}

# ── Calculate device capacity ─────────────────────────────────────────────────
get_device_capacity() {
    local device="$1"
    local size_sectors
    
    size_sectors=$(cat "/sys/block/${device}/size" 2>/dev/null || echo "0")
    echo $((size_sectors * BYTES_PER_SECTOR / 1024 / 1024 / 1024))
}

# ── Read device statistics ────────────────────────────────────────────────────
read_device_stats() {
    local device="$1"
    local stat_file="/sys/block/${device}/stat"
    
    if [[ ! -r "$stat_file" ]]; then
        error "Cannot read device statistics: $stat_file"
        return 1
    fi
    
    local sectors_written write_time_ms
    sectors_written=$(awk '{print $7}' "$stat_file")
    write_time_ms=$(awk '{print $11}' "$stat_file")
    
    printf '%s %s\n' "$sectors_written" "$write_time_ms"
}

# ── Calculate write statistics ────────────────────────────────────────────────
calculate_write_stats() {
    local sectors_written="$1"
    local uptime="$2"
    
    local daily_gb total_gb
    daily_gb=$(awk -v s="$sectors_written" -v u="$uptime" -v spd="$SECONDS_PER_DAY" -v bps="$BYTES_PER_SECTOR" \
        'BEGIN{if(u>0) printf "%.2f", s*bps*(spd/u)/1e9; else printf "0.00"}')
    
    total_gb=$(awk -v s="$sectors_written" -v bps="$BYTES_PER_SECTOR" \
        'BEGIN{printf "%.2f", s*bps/1e9}')
    
    printf '%s %s\n' "$daily_gb" "$total_gb"
}

# ── Read eMMC extended CSD registers ──────────────────────────────────────────
read_emmc_registers() {
    local device="$1"
    local extcsd_output
    
    if ! extcsd_output=$(sudo mmc extcsd read "/dev/$device" 2>/dev/null); then
        error "Failed to read eMMC registers for /dev/$device"
        return 1
    fi
    
    echo "$extcsd_output"
}

# ── Parse lifetime estimates from eMMC registers ──────────────────────────────
parse_lifetime_estimates() {
    local extcsd_data="$1"
    local a_hex b_hex pre_eol_hex
    
    a_hex=$(echo "$extcsd_data" | awk -F': ' '/EXT_CSD_DEVICE_LIFE_TIME_EST_TYP_A/ {gsub(/0x/,"",$2); print $2}')
    b_hex=$(echo "$extcsd_data" | awk -F': ' '/EXT_CSD_DEVICE_LIFE_TIME_EST_TYP_B/ {gsub(/0x/,"",$2); print $2}')
    pre_eol_hex=$(echo "$extcsd_data" | awk -F': ' '/EXT_CSD_PRE_EOL_INFO/ {gsub(/0x/,"",$2); print $2}')
    
    printf '%s %s %s\n' "$a_hex" "$b_hex" "$pre_eol_hex"
}

# ── Convert hex values to wear percentages ────────────────────────────────────
calculate_wear_percentages() {
    local a_hex="$1" b_hex="$2"
    local a_dec b_dec a_pct b_pct avg_pct
    
    if [[ -n "$a_hex" && -n "$b_hex" ]]; then
        a_dec=$((16#$a_hex))
        b_dec=$((16#$b_hex))
        
        a_pct=$(( (a_dec <= 10) ? a_dec * 10 : 100 ))
        b_pct=$(( (b_dec <= 10) ? b_dec * 10 : 100 ))
        avg_pct=$(( (a_pct + b_pct) / 2 ))
    else
        a_dec=0
        b_dec=0
        a_pct=0
        b_pct=0
        avg_pct=0
    fi
    
    printf '%d %d %d %d %d\n' "$a_dec" "$b_dec" "$a_pct" "$b_pct" "$avg_pct"
}

# ── Interpret Pre-EOL status ──────────────────────────────────────────────────
interpret_pre_eol_status() {
    local pre_eol_hex="$1"
    local pre_eol_dec status
    
    if [[ -n "$pre_eol_hex" ]]; then
        pre_eol_dec=$((16#$pre_eol_hex))
        case $pre_eol_dec in
            1) status="Normal" ;;
            2) status="Warning (80% reserved blocks consumed)" ;;
            3) status="Urgent (90% reserved blocks consumed)" ;;
            *) status="Undefined" ;;
        esac
    else
        pre_eol_dec=0
        status="Not available"
    fi
    
    printf '%d %s\n' "$pre_eol_dec" "$status"
}

# ── Calculate remaining lifespan ──────────────────────────────────────────────
calculate_remaining_lifespan() {
    local capacity_gb="$1" avg_wear_pct="$2" daily_gb="$3"
    local tbw_max remaining_pct days_left years_left
    
    tbw_max=$((capacity_gb * CYCLES_MAX))
    remaining_pct=$((100 - avg_wear_pct))
    
    if [[ "$daily_gb" != "0.00" && "$remaining_pct" -gt 0 && "$capacity_gb" -gt 0 ]]; then
        days_left=$(echo "scale=0; $tbw_max * (100 - $avg_wear_pct) / 100 / $daily_gb" | bc 2>/dev/null || echo "infinity")
        years_left=$(echo "scale=1; $days_left / $DAYS_PER_YEAR" | bc 2>/dev/null || echo "infinity")
    else
        days_left="infinity"
        years_left="infinity"
    fi
    
    printf '%s %s %s %s\n' "$tbw_max" "$remaining_pct" "$days_left" "$years_left"
}

# ── Assess device health ──────────────────────────────────────────────────────
assess_device_health() {
    local avg_wear_pct="$1" pre_eol_dec="$2"
    local status
    
    if [[ "$avg_wear_pct" -le "$WEAR_THRESHOLD_WARNING" && "$pre_eol_dec" -eq 1 ]]; then
        status="excellent"
    elif [[ "$avg_wear_pct" -le "$WEAR_THRESHOLD_CRITICAL" && "$pre_eol_dec" -le 2 ]]; then
        status="good"
    else
        status="attention_required"
    fi
    
    echo "$status"
}

# ── Generate recommendations ──────────────────────────────────────────────────
generate_recommendations() {
    local avg_wear_pct="$1"
    
    if [[ "$avg_wear_pct" -gt "$WEAR_THRESHOLD_CRITICAL" ]]; then
        echo -e "   ${RED}•${NC} Consider device replacement soon"
        echo -e "   ${RED}•${NC} Reduce non-essential write operations"
        echo -e "   ${RED}•${NC} Implement regular backup procedures"
    elif [[ "$avg_wear_pct" -gt "$WEAR_THRESHOLD_WARNING" ]]; then
        echo -e "   ${YELLOW}•${NC} Monitor device status regularly"
        echo -e "   ${YELLOW}•${NC} Optimize write-intensive applications"
        echo -e "   ${YELLOW}•${NC} Plan for eventual replacement"
    else
        echo -e "   ${GREEN}•${NC} Device is in excellent condition"
        echo -e "   ${GREEN}•${NC} Annual monitoring is sufficient"
        echo -e "   ${GREEN}•${NC} Continue normal operation"
    fi
}

# ── Display comprehensive analysis report ─────────────────────────────────────
display_analysis_report() {
    local device="$1" capacity_gb="$2" uptime="$3"
    local daily_gb="$4" total_gb="$5" write_time_ms="$6"
    local a_dec="$7" b_dec="$8" a_pct="$9" b_pct="${10}" avg_pct="${11}"
    local pre_eol_dec="${12}" pre_eol_status="${13}"
    local tbw_max="${14}" remaining_pct="${15}" days_left="${16}" years_left="${17}"
    local health_status="${18}"
    
    local uptime_days write_time_sec cycles_used tbw_remaining
    uptime_days=$(echo "scale=1; $uptime / $SECONDS_PER_DAY" | bc 2>/dev/null || echo "0.0")
    write_time_sec=$(echo "scale=1; $write_time_ms / 1000" | bc 2>/dev/null || echo "0.0")
    cycles_used=$((avg_pct * CYCLES_MAX / 100))
    tbw_remaining=$((tbw_max * remaining_pct / 100))
    
    newline
    title "==============================================================================="
    title "eMMC LIFETIME ANALYSIS REPORT"
    title "==============================================================================="
    newline
    
    subtitle "Device Information"
    echo -e "   $(label 'Device Path     :') /dev/$device"
    echo -e "   $(label 'Capacity        :') ${capacity_gb} GB"
    echo -e "   $(label 'System Uptime   :') $(printf "%.1f" "$uptime") seconds (${uptime_days} days)"
    newline
    
    subtitle "Write Statistics"
    echo -e "   $(label 'Daily Write Rate:') $daily_gb GB/day"
    echo -e "   $(label 'Total Written   :') $total_gb GB (since boot)"
    echo -e "   $(label 'Write Time      :') ${write_time_sec} seconds"
    newline
    
    subtitle "Flash Memory Status"
    echo -e "   $(label 'Life Time Est A :') $a_dec (${a_pct}%)"
    echo -e "   $(label 'Life Time Est B :') $b_dec (${b_pct}%)"
    echo -e "   $(label 'Average Wear    :') ${avg_pct}%"
    echo -e "   $(label 'Cycles Used     :') ~${cycles_used}/${CYCLES_MAX}"
    
    printf "   $(label 'Pre-EOL Status  :') "
    case $pre_eol_dec in
        1) success "$pre_eol_status" ;;
        2) warning "$pre_eol_status" ;;
        3) error "$pre_eol_status" ;;
        *) echo "$pre_eol_status" ;;
    esac
    newline
    
    subtitle "Lifespan Projection"
    echo -e "   $(label 'Maximum TBW     :') $tbw_max GB"
    echo -e "   $(label 'Remaining TBW   :') $tbw_remaining GB"
    echo -e "   $(label 'Estimated Life  :') $days_left days (~$years_left years)"
    newline
    
    subtitle "Health Assessment"
    printf "   $(label 'Status          :') "
    case $health_status in
        "excellent") success "Excellent" ;;
        "good") warning "Good" ;;
        "attention_required") error "Attention Required" ;;
        *) echo "Unknown" ;;
    esac
    newline
    
    subtitle "Recommendations"
    generate_recommendations "$avg_pct"
    newline
    title "==============================================================================="
}

# ── Analyze single device ────────────────────────────────────────────────────
analyze_device() {
    local device="$1"
    local capacity_gb uptime
    local sectors_written write_time_ms daily_gb total_gb
    local extcsd_data a_hex b_hex pre_eol_hex
    local a_dec b_dec a_pct b_pct avg_pct
    local pre_eol_dec pre_eol_status
    local tbw_max remaining_pct days_left years_left
    local health_status

    newline
    
    # Validate device exists
    if [[ ! -e "/dev/$device" ]]; then
        error "Device /dev/$device does not exist"
        return 1
    fi
    
    # Gather device information
    info "Reading device specifications..."
    capacity_gb=$(get_device_capacity "$device")
    uptime=$(awk '{print $1}' /proc/uptime)
    
    # Read device statistics
    info "Analyzing write statistics..."
    if ! read -r sectors_written write_time_ms < <(read_device_stats "$device"); then
        error "Failed to read device statistics for /dev/$device"
        return 1
    fi
    read -r daily_gb total_gb < <(calculate_write_stats "$sectors_written" "$uptime")
    
    # Read eMMC registers
    info "Reading eMMC hardware registers..."
    if ! extcsd_data=$(read_emmc_registers "$device"); then
        error "Failed to read eMMC registers for /dev/$device"
        return 1
    fi
    
    # Parse lifetime data
    info "Parsing lifetime estimates..."
    read -r a_hex b_hex pre_eol_hex < <(parse_lifetime_estimates "$extcsd_data")
    read -r a_dec b_dec a_pct b_pct avg_pct < <(calculate_wear_percentages "$a_hex" "$b_hex")
    read -r pre_eol_dec pre_eol_status < <(interpret_pre_eol_status "$pre_eol_hex")
    
    # Calculate projections
    info "Calculating lifespan projections..."
    read -r tbw_max remaining_pct days_left years_left < <(calculate_remaining_lifespan "$capacity_gb" "$avg_pct" "$daily_gb")
    
    # Assess health
    health_status=$(assess_device_health "$avg_pct" "$pre_eol_dec")
    
    # Display comprehensive report
    display_analysis_report "$device" "$capacity_gb" "$uptime" \
        "$daily_gb" "$total_gb" "$write_time_ms" \
        "$a_dec" "$b_dec" "$a_pct" "$b_pct" "$avg_pct" \
        "$pre_eol_dec" "$pre_eol_status" \
        "$tbw_max" "$remaining_pct" "$days_left" "$years_left" \
        "$health_status"
    
    return 0
}

# ── Main execution flow ───────────────────────────────────────────────────────
main() {
    local device selected

    info "eMMC Lifetime Analyzer - Professional Analysis Tool"
    newline
    validate_requirements

    while true; do
        newline
        info "Scanning for SD/eMMC devices…"

        if selected=$(select_device); then
            device=$selected
            info "Selected device: /dev/$device"

            # Analyze the selected device
            if analyze_device "$device"; then
                newline
                success "Analysis completed successfully!"
                newline
            else
                newline
                error "Analysis failed for device /dev/$device"
                newline
            fi
        else
            # User chose 0 or no devices → exit loop
            break
        fi
    done

    newline
    success "eMMC Lifetime Analyzer exited."
    newline
    exit 0
}

trap 'newline; newline; success "eMMC Lifetime Analyzer exited."; newline; exit 0' INT

main "$@"
