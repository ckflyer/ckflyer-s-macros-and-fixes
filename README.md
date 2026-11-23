# ckflyer's macros and fixes for the Qidi Q2

My `PRINT_START` and `PRINT_END` for a stock Qidi Q2, the KAMP adaptive mesh and purge line, and an optional cleanup of background services that printing doesn't need. Works with or without a Qidi Box. Everything else in your config stays as it is.

## Install

SSH into the printer as `mks` (not root) and run:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ckflyer/ckflyer-s-macros-and-fixes/main/install.sh)
```

| Option | What it does |
| --- | --- |
| 1) Install / update print macros + KAMP | Installs `print_macros.cfg` and the `KAMP` folder. Run it again any time to get the latest version |
| 2) Remove bloat | Turns off unneeded background services (list below) |
| 3) Undo bloat removal | Turns them back on |
| 4) Restore a backup | Puts back a saved copy of your whole config folder |

What option 1 changes:

- Adds `print_macros.cfg` (`PRINT_START`, `PRINT_END`, `ORCA_QIDI_BOX`) and the four `KAMP` files, and their `[include]` lines in `printer.cfg`.
- Comments out any older `PRINT_START`, `PRINT_END` or `ORCA_QIDI_BOX` in your other config files, so there's only one of each. Nothing else is touched.

Before changing anything it saves your whole config folder to `~/q2_macro_backups/`; the first backup is marked "before first install" in the restore menu. It won't run during a print, downloads everything before changing anything, and restarts Klipper at the end. It works on both firmware layouts (legacy and 01.01.02+).

## OrcaSlicer G-code

**Printer settings → Machine G-code.** The purge line runs inside `PRINT_START`, so the start G-code has no purge of its own.

Start G-code with a Qidi Box:

```
ORCA_QIDI_BOX T=[initial_tool]
PRINT_START BED=[bed_temperature_initial_layer_single] HOTEND=[nozzle_temperature_initial_layer] CHAMBER=[chamber_temperature] EXTRUDER=[initial_no_support_extruder]
SET_PRINT_STATS_INFO TOTAL_LAYER=[total_layer_count]
M83
T[initial_tool]
```

Start G-code without a Box: the same, without the `ORCA_QIDI_BOX` and `T[initial_tool]` lines.

End G-code (both):

```
PRINT_END T=[current_extruder]
```

## What the macros do

**`PRINT_START`:** heats the bed and chamber while it homes, loads and flushes the Box filament (Box only), cleans the nozzle in the chute, levels with Z tilt, waits for the bed and chamber, runs a KAMP adaptive mesh of just the print area, heats the nozzle 5 mm above the purge spot, then runs the purge line.

**`PRINT_END`:** retracts, lowers the bed 3 mm before moving anywhere, cuts and unloads the filament (Box only), parks at the back, lowers the bed to the middle (or 3 mm more if the print is taller, never back up), then turns everything off and resets like Qidi's stock end macro.

**`ORCA_QIDI_BOX`:** maps slicer tools T0–T15 to Box slots, or turns the Box off when the first tool isn't in a Box.

## Bloat removal

Turns off: `algo_app` and `QIDILink-client` (Qidi app link and AI detection), `bluetooth`, `pulseaudio`, the VPN services `xl2tpd`, `strongswan-starter` and `openvpn`, `triggerhappy` (hotkey daemon) and `packagekit` (background package polling). The touchscreen and `polkitd` (needed by Moonraker) keep running. Reboot afterwards. Option 3 undoes it.

## Credits

`PRINT_START` started from [Catsarecool700's QIDI-Q2-optimised-start-macro](https://github.com/Catsarecool700/QIDI-Q2-optimised-start-macro). The `KAMP` files are from [Klipper Adaptive Meshing & Purging](https://github.com/kyleisah/Klipper-Adaptive-Meshing-Purging) (GPL-3.0, see `Q2/KAMP/LICENSE`); the purge line in `Line_Purge.cfg` is the version from [Qidi-Q2-superuser](https://github.com/Camden-Winder/Qidi-Q2-superuser).
