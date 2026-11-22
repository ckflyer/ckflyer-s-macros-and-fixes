#!/usr/bin/env bash
# =====================================================================
#  Q2 Macro Installer  -  Box / Printer versions + bloat removal
#  For a Qidi Q2 on stock Klipper firmware. Run over SSH as the mks user:
#      bash <(curl -fsSL https://raw.githubusercontent.com/ckflyer/ckflyer-s-macros-and-fixes/main/install.sh)
# =====================================================================
set -o pipefail

VERSION="1.0"
REPO_RAW="${Q2_REPO_RAW:-https://raw.githubusercontent.com/ckflyer/ckflyer-s-macros-and-fixes/main}"
MOONRAKER="http://127.0.0.1:7125"
BACKUP_DIR="${HOME}/q2_macro_backups"
STATE_FILE="${BACKUP_DIR}/disabled_services.txt"
INSTALLED_FILE="${BACKUP_DIR}/installed_version"
DL_DIR=""
BLOAT_UNITS="algo_app QIDILink-client strongswan-starter openvpn triggerhappy bluetooth packagekit xl2tpd"
MASK_UNITS="packagekit QIDILink-client"
USER_UNITS="pulseaudio.service pulseaudio.socket"

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

if [ -f "${CONFIG_DIR}/klipper-macros-qd/gcode_macro.cfg" ]; then
    LAYOUT="new"   # firmware 01.01.02+
    MACRO_DEST="${CONFIG_DIR}/klipper-macros-qd/gcode_macro.cfg"
else
    LAYOUT="legacy"
    MACRO_DEST="${CONFIG_DIR}/gcode_macro.cfg"
fi

# ---------- helpers ----------------------------------------------------
printer_busy() {
    local state
    state=$(curl -s --max-time 3 "${MOONRAKER}/printer/objects/query?print_stats=state" 2>/dev/null \
        | grep -o '"state": *"[a-z]*"' | grep -o '"[a-z]*"$' | tr -d '"')
    [ "$state" = "printing" ] || [ "$state" = "paused" ]
}

# Downloads every file the install needs into DL_DIR first. If any download
# fails, nothing on the printer is changed.
download_files() {
    local version="$1" f
    DL_DIR=$(mktemp -d)
    mkdir -p "${DL_DIR}/KAMP"
    info "Downloading files from GitHub..."
    for f in "macros/gcode_macro-${version}.cfg" macros/printer.cfg \
             KAMP/KAMP_settings.cfg KAMP/Adaptive_Meshing.cfg KAMP/Line_Purge.cfg KAMP/Smart_Park.cfg; do
        if ! curl -fsSL --max-time 30 "${REPO_RAW}/Q2/${f}" -o "${DL_DIR}/$(basename "$f")" \
           || [ ! -s "${DL_DIR}/$(basename "$f")" ]; then
            err "Couldn't download ${f}. Check the printer's internet connection. Nothing was changed."
            rm -rf "$DL_DIR"; DL_DIR=""
            return 1
        fi
    done
    mv "${DL_DIR}"/KAMP_settings.cfg "${DL_DIR}"/Adaptive_Meshing.cfg "${DL_DIR}"/Line_Purge.cfg "${DL_DIR}"/Smart_Park.cfg "${DL_DIR}/KAMP/"
    ok "Downloaded all files"
}

make_backup() {
    mkdir -p "$BACKUP_DIR" || { err "Can't create $BACKUP_DIR"; return 1; }
    local stamp file
    stamp=$(date +%Y%m%d-%H%M%S)
    file="${BACKUP_DIR}/config-${stamp}.tar.gz"
    local n=1
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
        state=$(curl -s --max-time 3 "${MOONRAKER}/printer/info" 2>/dev/null \
            | grep -o '"state": *"[a-z]*"' | grep -o '"[a-z]*"$' | tr -d '"')
        if [ "$state" = "ready" ]; then ok "Klipper is ready"; return 0; fi
        if [ "$state" = "error" ] || [ "$state" = "shutdown" ]; then break; fi
    done
    msg=$(curl -s --max-time 3 "${MOONRAKER}/printer/info" 2>/dev/null | grep -o '"state_message": *"[^"]*"' | head -1)
    warn "Klipper isn't ready yet. ${msg}"
    warn "Check Fluidd for the error. You can roll back with option 6."
    return 1
}

# Adds "[include X]" near the top of printer.cfg if it isn't there yet.
ensure_include() {
    local inc="[include $1]" pcfg="${CONFIG_DIR}/printer.cfg"
    if grep -qF "$inc" "$pcfg"; then return 0; fi
    sed -i "1i ${inc}" "$pcfg" && ok "Added ${inc} to printer.cfg"
}

# Keeps the user's own SAVE_CONFIG block and extra [include] lines when
# printer.cfg is replaced with the template (legacy layout only).
install_printer_cfg() {
    local pcfg="${CONFIG_DIR}/printer.cfg" old new
    old=$(mktemp); new=$(mktemp)
    cp "$pcfg" "$old"
    cp "${DL_DIR}/printer.cfg" "$new"

    # Extra [include] lines the user had that the template doesn't
    local extra
    extra=$(grep -E '^\[include [^]]+\]' "$old" | while read -r line; do
        case "$line" in
            *KAMP_Settings.cfg*|*KAMP_settings.cfg*) continue ;;
        esac
        grep -qF "$line" "$new" || echo "$line"
    done)
    if [ -n "$extra" ]; then
        local tmp; tmp=$(mktemp)
        # put them right after the template's last [include] line
        local lastinc; lastinc=$(grep -n '^\[include ' "$new" | tail -1 | cut -d: -f1)
        { head -n "${lastinc:-0}" "$new"; printf '%s\n' "$extra"; tail -n +"$(( ${lastinc:-0} + 1 ))" "$new"; } > "$tmp" && mv "$tmp" "$new"
        info "Kept your extra includes: $(echo "$extra" | tr '\n' ' ')"
    fi

    # The user's own calibration (input shaper, bed meshes, PID, ...)
    if grep -q '^#\*# <---------------------- SAVE_CONFIG' "$old"; then
        printf '\n' >> "$new"
        sed -n '/^#\*# <---------------------- SAVE_CONFIG/,$p' "$old" >> "$new"
        ok "Kept your SAVE_CONFIG calibration block"
    else
        warn "No SAVE_CONFIG block found - run SHAPER_CALIBRATE and SAVE_CONFIG later."
    fi
    cp "$new" "$pcfg" && ok "printer.cfg updated"
    rm -f "$old" "$new"
}

install_kamp() {
    # Remove old/stock KAMP files that would clash with the new set
    if [ "$LAYOUT" = "new" ] && [ -f "${CONFIG_DIR}/klipper-macros-qd/KAMP_Settings.cfg" ]; then
        rm -f "${CONFIG_DIR}/klipper-macros-qd/KAMP_Settings.cfg" && info "Removed klipper-macros-qd/KAMP_Settings.cfg (clashes with the new one)"
    fi
    find "$CONFIG_DIR" -maxdepth 1 -iname '*kamp*' -type f -delete 2>/dev/null
    # Stock printer.cfg may include a root-level KAMP_Settings.cfg: comment it out
    sed -i -E 's/^\[include +KAMP_Settings\.cfg\]/# &  (replaced by KAMP\/KAMP_settings.cfg)/I' "${CONFIG_DIR}/printer.cfg"
    rm -rf "${CONFIG_DIR}/KAMP"
    mkdir -p "${CONFIG_DIR}/KAMP"
    cp "${DL_DIR}"/KAMP/*.cfg "${CONFIG_DIR}/KAMP/"
    ok "KAMP files installed to KAMP/"
    ensure_include "KAMP/KAMP_settings.cfg"
}

install_macros() {
    local version="$1"   # Box | Printer
    printf '\n%s== Install: %s version ==%s\n' "$C_B" "$version" "$C_0"
    info "Firmware layout: ${LAYOUT}   Config: ${CONFIG_DIR}"
    if printer_busy; then err "A print is running or paused. Try again when it's finished."; return 1; fi
    if [ -d "${CONFIG_DIR}/mmu" ] || [ -f "${CONFIG_DIR}/bunnybox_macros.cfg" ]; then
        warn "BunnyBox / Happy Hare files found. These macros replace the ones it needs and Klipper will error."
        confirm "Continue anyway?" || return 0
    fi
    if [ "$version" = "Box" ] && ! grep -qs '^\[box_extras\]' "${CONFIG_DIR}/box.cfg"; then
        warn "No Qidi Box found in box.cfg. You probably want the Printer version."
        confirm "Install the Box version anyway?" || return 0
    fi
    confirm "Install the ${version} version now?" || return 0

    download_files "$version" || return 1
    make_backup || { rm -rf "$DL_DIR"; return 1; }
    write_files "$version" full
    rm -rf "$DL_DIR"

    if confirm "Also remove bloat (unneeded background services) now? (recommended)"; then
        remove_bloat
    fi

    firmware_restart
    cat <<EOT

${C_B}Done.${C_0} Set this in OrcaSlicer -> Printer settings -> Machine G-code:
EOT
    if [ "$version" = "Box" ]; then
        cat <<'EOT'
  Start G-code:
    ORCA_QIDI_BOX T=[initial_tool]
    PRINT_START BED=[bed_temperature_initial_layer_single] HOTEND=[nozzle_temperature_initial_layer] CHAMBER=[chamber_temperature] EXTRUDER=[initial_no_support_extruder]
    SET_PRINT_STATS_INFO TOTAL_LAYER=[total_layer_count]
    M83
    T[initial_tool]
    M140 S[bed_temperature_initial_layer_single]
    M104 S[nozzle_temperature_initial_layer]
    M141 S[chamber_temperature]
  End G-code:
    PRINT_END T=[current_extruder]
EOT
    else
        cat <<'EOT'
  Start G-code:
    PRINT_START BED=[bed_temperature_initial_layer_single] HOTEND=[nozzle_temperature_initial_layer] CHAMBER=[chamber_temperature] EXTRUDER=[initial_no_support_extruder]
    SET_PRINT_STATS_INFO TOTAL_LAYER=[total_layer_count]
    M83
    M140 S[bed_temperature_initial_layer_single]
    M104 S[nozzle_temperature_initial_layer]
    M141 S[chamber_temperature]
  End G-code:
    PRINT_END
EOT
    fi
    echo
}

# mode "full" also replaces printer.cfg (legacy layout); "update" leaves it alone.
write_files() {
    local version="$1" mode="$2"
    cp "${DL_DIR}/gcode_macro-${version}.cfg" "$MACRO_DEST"
    ok "Macros written to ${MACRO_DEST#"${CONFIG_DIR}"/}"
    if [ "$mode" = "full" ] && [ "$LAYOUT" = "legacy" ]; then install_printer_cfg; fi
    install_kamp
    mkdir -p "$BACKUP_DIR"; echo "$version" > "$INSTALLED_FILE"
}

update_macros() {
    printf '\n%s== Update macros ==%s\n' "$C_B" "$C_0"
    local version
    version=$(cat "$INSTALLED_FILE" 2>/dev/null)
    if [ "$version" != "Box" ] && [ "$version" != "Printer" ]; then
        warn "No install recorded on this printer. Use option 1 or 2 first."; return 0
    fi
    if printer_busy; then err "A print is running or paused. Try again when it's finished."; return 1; fi
    info "Installed version: ${version}. This re-downloads the macros and KAMP files."
    info "printer.cfg is left alone."
    confirm "Update now?" || return 0
    download_files "$version" || return 1
    make_backup || { rm -rf "$DL_DIR"; return 1; }
    write_files "$version" update
    rm -rf "$DL_DIR"
    firmware_restart
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
    local tmp; tmp=$(mktemp -d)
    tar -xzf "$f" -C "$tmp" || { err "Couldn't read the backup."; rm -rf "$tmp"; return 1; }
    local src="${tmp}/$(basename "$CONFIG_DIR")"
    [ -d "$src" ] || { err "Backup doesn't contain a config folder."; rm -rf "$tmp"; return 1; }
    find "$CONFIG_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    cp -a "${src}/." "$CONFIG_DIR/" && ok "Config restored from $(basename "$f")"
    rm -rf "$tmp"
    firmware_restart
}

menu() {
    while true; do
        printf '\n%s Q2 Macro Installer v%s %s   layout: %s\n' "$C_B" "$VERSION" "$C_0" "$LAYOUT"
        echo "  1) Install Box version      (Qidi Box connected)"
        echo "  2) Install Printer version  (no Box)"
        echo "  3) Update macros            (re-download your installed version)"
        echo "  4) Remove bloat"
        echo "  5) Undo bloat removal"
        echo "  6) Restore a backup"
        echo "  0) Exit"
        read -r -p "Choose: " c
        case "$c" in
            1) install_macros Box; pause ;;
            2) install_macros Printer; pause ;;
            3) update_macros; pause ;;
            4) confirm "Disable the unneeded services?" && remove_bloat; pause ;;
            5) undo_bloat; pause ;;
            6) restore_backup; pause ;;
            0) exit 0 ;;
            *) warn "Pick 0-6" ;;
        esac
    done
}

menu
