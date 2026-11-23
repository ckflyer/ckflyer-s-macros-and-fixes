#!/usr/bin/env bash
# =====================================================================
#  ckflyer's Q2 installer: print macros, KAMP, bloat removal
#  For a Qidi Q2 on stock Klipper firmware. Run over SSH as the mks user:
#      bash <(curl -fsSL https://raw.githubusercontent.com/ckflyer/ckflyer-s-macros-and-fixes/main/install.sh)
# =====================================================================
set -o pipefail

VERSION="2.0"
REPO_RAW="${Q2_REPO_RAW:-https://raw.githubusercontent.com/ckflyer/ckflyer-s-macros-and-fixes/main}"
MOONRAKER="${Q2_MOONRAKER:-http://127.0.0.1:7125}"
BACKUP_DIR="${HOME}/q2_macro_backups"
STATE_FILE="${BACKUP_DIR}/disabled_services.txt"
MACRO_FILE="print_macros.cfg"
OUR_MACROS="PRINT_START|PRINT_END|ORCA_QIDI_BOX"
KAMP_FILES="KAMP_settings.cfg Adaptive_Meshing.cfg Line_Purge.cfg Smart_Park.cfg"
BLOAT_UNITS="algo_app QIDILink-client strongswan-starter openvpn triggerhappy bluetooth packagekit xl2tpd"
MASK_UNITS="packagekit QIDILink-client"
USER_UNITS="pulseaudio.service pulseaudio.socket"
DL_DIR=""

if [ -t 1 ]; then
    C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_C=$'\e[36m'; C_B=$'\e[1m'; C_0=$'\e[0m'
else
    C_G=""; C_Y=""; C_R=""; C_C=""; C_B=""; C_0=""
fi
ok()   { printf '%s[OK]%s   %s\n' "$C_G" "$C_0" "$*"; }
info() { printf '%s[INFO]%s %s\n' "$C_C" "$C_0" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_Y" "$C_0" "$*"; }
err()  { printf '%s[ERR]%s  %s\n' "$C_R" "$C_0" "$*" >&2; }
confirm() { local a; read -r -p "$1 [y/N]: " a; [[ "$a" =~ ^[Yy]$ ]]; }
pause()   { read -r -p "Press Enter to continue..." _; }

# ---------- environment ------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
    err "Don't run this as root. Log in as mks and run it again."
    exit 1
fi

CONFIG_DIR=""
for d in "${HOME}/printer_data/config" "${HOME}/klipper_config"; do
    if [ -f "$d/printer.cfg" ]; then CONFIG_DIR="$d"; break; fi
done
if [ -z "$CONFIG_DIR" ]; then
    err "Couldn't find printer.cfg in ~/printer_data/config. Is this a Qidi Q2?"
    exit 1
fi
if [ -d "${CONFIG_DIR}/klipper-macros-qd" ]; then LAYOUT="01.01.02+"; else LAYOUT="legacy"; fi

# ---------- helpers ----------------------------------------------------
moonraker_field() {   # moonraker_field <path> <field>
    curl -s --max-time 3 "${MOONRAKER}$1" 2>/dev/null \
        | grep -o "\"$2\": *\"[a-z]*\"" | grep -o '"[a-z]*"$' | tr -d '"'
}

printer_busy() {
    local state
    state=$(moonraker_field "/printer/objects/query?print_stats=state" state)
    [ "$state" = "printing" ] || [ "$state" = "paused" ]
}

make_backup() {
    mkdir -p "$BACKUP_DIR" || { err "Can't create $BACKUP_DIR"; return 1; }
    local stamp file n=1
    stamp=$(date +%Y%m%d-%H%M%S)
    file="${BACKUP_DIR}/config-${stamp}.tar.gz"
    while [ -e "$file" ]; do file="${BACKUP_DIR}/config-${stamp}-${n}.tar.gz"; n=$((n+1)); done
    if tar -czf "$file" -C "$(dirname "$CONFIG_DIR")" "$(basename "$CONFIG_DIR")" 2>/dev/null; then
        ok "Config backed up to $file"
        if [ ! -f "${BACKUP_DIR}/FIRST_BACKUP" ]; then
            echo "$file" > "${BACKUP_DIR}/FIRST_BACKUP"
            info "This is your first backup: the one to restore to get back to how it was before."
        fi
    else
        err "Backup failed - nothing was changed."
        return 1
    fi
}

firmware_restart() {
    info "Restarting Klipper..."
    curl -s --max-time 5 -X POST "${MOONRAKER}/printer/firmware_restart" >/dev/null 2>&1
    local i state msg
    for i in $(seq 1 20); do
        sleep 2
        state=$(moonraker_field "/printer/info" state)
        if [ "$state" = "ready" ]; then ok "Klipper is ready"; return 0; fi
        if [ "$state" = "error" ] || [ "$state" = "shutdown" ]; then break; fi
    done
    msg=$(curl -s --max-time 3 "${MOONRAKER}/printer/info" 2>/dev/null | grep -o '"state_message": *"[^"]*"' | head -1)
    warn "Klipper isn't ready yet. ${msg}"
    warn "Check Fluidd for the error. You can roll back with option 4."
    return 1
}

# Downloads every file first. If any download fails, nothing is changed.
download_files() {
    local f
    DL_DIR=$(mktemp -d)
    info "Downloading files from GitHub..."
    for f in "$MACRO_FILE" $(for k in $KAMP_FILES; do echo "KAMP/$k"; done); do
        if ! curl -fsSL --max-time 30 "${REPO_RAW}/Q2/${f}" -o "${DL_DIR}/$(basename "$f")" \
           || [ ! -s "${DL_DIR}/$(basename "$f")" ]; then
            err "Couldn't download ${f}. Check the printer's internet connection. Nothing was changed."
            rm -rf "$DL_DIR"; DL_DIR=""
            return 1
        fi
    done
    ok "Downloaded all files"
}

# Adds "[include X]" at the top of printer.cfg if it isn't there yet.
ensure_include() {
    local inc="[include $1]" pcfg="${CONFIG_DIR}/printer.cfg"
    if grep -qxF "$inc" <(tr -d '\r' < "$pcfg"); then return 0; fi
    sed -i "1i ${inc}" "$pcfg" && ok "Added ${inc} to printer.cfg"
}

# Comments out every line of any PRINT_START / PRINT_END / ORCA_QIDI_BOX
# section in a config file, so the ones in print_macros.cfg are the only ones.
comment_out_old_macros() {
    local f="$1" tmp found
    found=$(grep -cE "^\[gcode_macro (${OUR_MACROS})\][[:space:]]*(#.*)?$" "$f" 2>/dev/null)
    [ "${found:-0}" -gt 0 ] || return 0
    local names
    names=$(grep -oE "^\[gcode_macro (${OUR_MACROS})\]" "$f" | sed 's/^\[gcode_macro //; s/\]$//' | sort -u | tr '\n' ' ')
    tmp=$(mktemp)
    awk -v re="^\\\\[gcode_macro (${OUR_MACROS})\\\\][[:space:]]*(#.*)?$" '
        $0 ~ re          { inside = 1; print "# " $0; next }
        /^\[/            { inside = 0 }
        inside && /^[[:space:]]*$/ { print; next }
        inside           { print "# " $0; next }
                         { print }
    ' "$f" > "$tmp" && cat "$tmp" > "$f"
    rm -f "$tmp"
    ok "Commented out the old ${names}in ${f#"${CONFIG_DIR}"/}"
}

install_kamp() {
    if [ "$LAYOUT" = "01.01.02+" ] && [ -f "${CONFIG_DIR}/klipper-macros-qd/KAMP_Settings.cfg" ]; then
        mv "${CONFIG_DIR}/klipper-macros-qd/KAMP_Settings.cfg" "${CONFIG_DIR}/klipper-macros-qd/KAMP_Settings.cfg.disabled" \
            && info "Renamed klipper-macros-qd/KAMP_Settings.cfg to .disabled (it clashes with KAMP/)"
    fi
    # Turn off any other KAMP include (e.g. Qidi's [include ./KAMP/KAMP_Settings.cfg]),
    # otherwise two copies of KAMP load and Klipper refuses to start.
    local pcfg="${CONFIG_DIR}/printer.cfg" line
    while IFS= read -r line; do
        [ "$line" = "[include KAMP/KAMP_settings.cfg]" ] && continue
        sed -i "s|^$(printf '%s' "$line" | sed 's/[][\\.*^$|]/\\&/g')\$|# & (replaced by the KAMP folder include)|" "$pcfg"
        info "Commented out ${line} in printer.cfg"
    done < <(grep -iE '^\[include [^]]*kamp[^]]*\]' "$pcfg" | tr -d '\r')
    mkdir -p "${CONFIG_DIR}/KAMP"
    local k
    for k in $KAMP_FILES; do cp "${DL_DIR}/${k}" "${CONFIG_DIR}/KAMP/${k}"; done
    ok "KAMP files installed to KAMP/"
    ensure_include "KAMP/KAMP_settings.cfg"
}

install_macros() {
    printf '\n%s== Install / update print macros ==%s\n' "$C_B" "$C_0"
    info "Firmware layout: ${LAYOUT}   Config: ${CONFIG_DIR}"
    if printer_busy; then err "A print is running or paused. Try again when it's finished."; return 1; fi
    if [ -d "${CONFIG_DIR}/mmu" ] || [ -f "${CONFIG_DIR}/bunnybox_macros.cfg" ]; then
        warn "BunnyBox / Happy Hare files found. These macros may conflict with it."
        confirm "Continue anyway?" || return 0
    fi
    info "This installs PRINT_START, PRINT_END and ORCA_QIDI_BOX (print_macros.cfg) and the KAMP files."
    info "Any older copies of those three macros in your other config files get commented out."
    info "Nothing else in your config is changed."
    confirm "Go ahead?" || return 0

    download_files || return 1
    make_backup || { rm -rf "$DL_DIR"; return 1; }

    local f
    for f in "${CONFIG_DIR}"/*.cfg "${CONFIG_DIR}"/klipper-macros-qd/*.cfg; do
        [ -f "$f" ] || continue
        [ "$(basename "$f")" = "$MACRO_FILE" ] && continue
        comment_out_old_macros "$f"
    done
    cp "${DL_DIR}/${MACRO_FILE}" "${CONFIG_DIR}/${MACRO_FILE}"
    ok "${MACRO_FILE} installed"
    install_kamp
    ensure_include "$MACRO_FILE"
    rm -rf "$DL_DIR"

    firmware_restart
    cat <<'EOT'

Set this in OrcaSlicer -> Printer settings -> Machine G-code:

  Start G-code (with a Qidi Box):
    ORCA_QIDI_BOX T=[initial_tool]
    PRINT_START BED=[bed_temperature_initial_layer_single] HOTEND=[nozzle_temperature_initial_layer] CHAMBER=[chamber_temperature] EXTRUDER=[initial_no_support_extruder]
    SET_PRINT_STATS_INFO TOTAL_LAYER=[total_layer_count]
    M83
    T[initial_tool]

  Start G-code (no Box): the same without the ORCA_QIDI_BOX and T[initial_tool] lines.

  End G-code (both):
    PRINT_END T=[current_extruder]

EOT
}

remove_bloat() {
    printf '\n%s== Remove bloat ==%s\n' "$C_B" "$C_0"
    info "Keeping lightdm, the touchscreen service and polkitd (needed for the screen and Moonraker)."
    mkdir -p "$BACKUP_DIR"
    local u
    for u in $BLOAT_UNITS; do
        if ! systemctl list-unit-files "${u}.service" 2>/dev/null | grep -q "^${u}\.service"; then
            info "${u}: not on this printer, skipped"; continue
        fi
        if sudo systemctl disable --now "$u" >/dev/null 2>&1; then
            ok "Disabled ${u}"
            grep -qxF "$u" "$STATE_FILE" 2>/dev/null || echo "$u" >> "$STATE_FILE"
        else
            warn "Couldn't disable ${u}"
        fi
    done
    for u in $MASK_UNITS; do
        if systemctl list-unit-files "${u}.service" 2>/dev/null | grep -q "^${u}\.service"; then
            sudo systemctl mask "$u" >/dev/null 2>&1 && ok "Masked ${u} (can't be restarted by other services)"
        fi
    done
    for u in $USER_UNITS; do
        if systemctl --user disable --now "$u" >/dev/null 2>&1; then
            systemctl --user mask "$u" >/dev/null 2>&1
            ok "Disabled ${u} (user)"
            grep -qxF "user:$u" "$STATE_FILE" 2>/dev/null || echo "user:$u" >> "$STATE_FILE"
        else
            info "${u}: not running for this user, skipped"
        fi
    done
    ok "Bloat removed. A reboot finishes the job."
}

undo_bloat() {
    printf '\n%s== Undo bloat removal ==%s\n' "$C_B" "$C_0"
    if [ ! -s "$STATE_FILE" ]; then info "Nothing recorded to undo."; return 0; fi
    local line u
    while read -r line; do
        [ -n "$line" ] || continue
        if [[ "$line" == user:* ]]; then
            u="${line#user:}"
            systemctl --user unmask "$u" >/dev/null 2>&1
            systemctl --user enable "$u" >/dev/null 2>&1 && ok "Re-enabled ${u} (user)" || warn "Couldn't re-enable ${u}"
        else
            sudo systemctl unmask "$line" >/dev/null 2>&1
            sudo systemctl enable "$line" >/dev/null 2>&1 && ok "Re-enabled ${line}" || warn "Couldn't re-enable ${line}"
        fi
    done < "$STATE_FILE"
    rm -f "$STATE_FILE"
    ok "Done. Reboot to start them again."
}

restore_backup() {
    printf '\n%s== Restore a backup ==%s\n' "$C_B" "$C_0"
    if printer_busy; then err "A print is running or paused. Try again when it's finished."; return 1; fi
    local files=() f i=1 pick first=""
    [ -f "${BACKUP_DIR}/FIRST_BACKUP" ] && first=$(cat "${BACKUP_DIR}/FIRST_BACKUP")
    while IFS= read -r f; do files+=("$f"); done < <(ls -1t "${BACKUP_DIR}"/config-*.tar.gz 2>/dev/null)
    if [ ${#files[@]} -eq 0 ]; then info "No backups in ${BACKUP_DIR}."; return 0; fi
    for f in "${files[@]}"; do
        if [ "$f" = "$first" ]; then printf '  %d) %s  %s(before first install)%s\n' "$i" "$(basename "$f")" "$C_Y" "$C_0"
        else printf '  %d) %s\n' "$i" "$(basename "$f")"; fi
        i=$((i+1))
    done
    read -r -p "Restore which backup? (number, Enter to cancel): " pick
    [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le ${#files[@]} ] || { info "Cancelled."; return 0; }
    f="${files[$((pick-1))]}"
    confirm "Replace your whole config folder with $(basename "$f")?" || return 0
    make_backup || return 1   # so the restore itself can be undone
    local tmp src
    tmp=$(mktemp -d)
    tar -xzf "$f" -C "$tmp" || { err "Couldn't read the backup."; rm -rf "$tmp"; return 1; }
    src="${tmp}/$(basename "$CONFIG_DIR")"
    [ -d "$src" ] || { err "Backup doesn't contain a config folder."; rm -rf "$tmp"; return 1; }
    find "$CONFIG_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    cp -a "${src}/." "$CONFIG_DIR/" && ok "Config restored from $(basename "$f")"
    rm -rf "$tmp"
    firmware_restart
}

menu() {
    while true; do
        printf '\n%s ckflyer Q2 installer v%s %s   layout: %s\n' "$C_B" "$VERSION" "$C_0" "$LAYOUT"
        echo "  1) Install / update print macros + KAMP"
        echo "  2) Remove bloat"
        echo "  3) Undo bloat removal"
        echo "  4) Restore a backup"
        echo "  0) Exit"
        read -r -p "Choose: " c
        case "$c" in
            1) install_macros; pause ;;
            2) confirm "Disable the unneeded services?" && remove_bloat; pause ;;
            3) undo_bloat; pause ;;
            4) restore_backup; pause ;;
            0) exit 0 ;;
            *) warn "Pick 0-4" ;;
        esac
    done
}

menu
