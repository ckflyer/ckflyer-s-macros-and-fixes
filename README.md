# ckflyer's macros and fixes for the Qidi Q2

Faster, cleaner Klipper macros for a stock Qidi Q2, in two versions (**Box**, for a Qidi Box, and **Printer**, for no Box), plus removal of the background services Qidi ships that printing doesn't need.

Based on the Just Faster Printer / Just Faster Box macros from [Camden-Winder/Qidi-Q2-superuser](https://github.com/Camden-Winder/Qidi-Q2-superuser), with the fixes listed below.

## Install

SSH into the printer as `mks` (not root) and run:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ckflyer/ckflyer-s-macros-and-fixes/main/install.sh)
```

The menu:

| Option | What it does |
| --- | --- |
| 1) Install Box version | Your Q2 has a Qidi Box connected |
| 2) Install Printer version | No Box |
| 3) Update macros | Re-downloads the macros and KAMP files for the version you installed. Leaves `printer.cfg` alone |
| 4) Remove bloat | Turns off unneeded services (list below) |
| 5) Undo bloat removal | Turns them back on |
| 6) Restore a backup | Puts back a saved copy of your whole config folder |

Any other config files you have, such as your own macro files and their `[include]` lines, are left in place.

Every install and update first saves your whole config folder to `~/q2_macro_backups/`. The first backup is marked as "before first install" in the restore menu. The installer won't run during a print, downloads everything before changing anything, and restarts Klipper at the end.

It works on both firmware layouts: legacy (`gcode_macro.cfg` in the config folder) and 01.01.02+ (`klipper-macros-qd/gcode_macro.cfg`). On 01.01.02+ it leaves `printer.cfg` in place and only adds the include lines.

## OrcaSlicer G-code

**Printer settings → Machine G-code**, for every nozzle preset you use.

### Box version

Start G-code:

```
ORCA_QIDI_BOX T=[initial_tool]
PRINT_START BED=[bed_temperature_initial_layer_single] HOTEND=[nozzle_temperature_initial_layer] CHAMBER=[chamber_temperature] EXTRUDER=[initial_no_support_extruder]
SET_PRINT_STATS_INFO TOTAL_LAYER=[total_layer_count]
M83
T[initial_tool]
M140 S[bed_temperature_initial_layer_single]
M104 S[nozzle_temperature_initial_layer]
M141 S[chamber_temperature]
```

End G-code:

```
PRINT_END T=[current_extruder]
```

### Printer version

Start G-code:

```
PRINT_START BED=[bed_temperature_initial_layer_single] HOTEND=[nozzle_temperature_initial_layer] CHAMBER=[chamber_temperature] EXTRUDER=[initial_no_support_extruder]
SET_PRINT_STATS_INFO TOTAL_LAYER=[total_layer_count]
M83
M140 S[bed_temperature_initial_layer_single]
M104 S[nozzle_temperature_initial_layer]
M141 S[chamber_temperature]
```

End G-code:

```
PRINT_END
```

The purge line runs inside `PRINT_START`, so the start G-code has no purge. `PRINT_START` doesn't touch the exhaust fan, so set it per material in each filament profile (on for PLA/PETG, off for ABS/ASA).

## What's fixed compared to the original

| Problem | Fix |
| --- | --- |
| `PRINT_END` moved to the wipe chute at last-layer height, so the nozzle could drag across the print | The bed lowers 5 mm first, then the toolhead moves |
| `PRINT_END` always ended at Z251, so a print taller than 246 mm made the bed move back **up** | The bed only ever moves down, capped below the Z limit |
| Box: `UNLOAD_FILAMENT T=[current_extruder]` used slicer syntax inside a macro, so it always unloaded T0 | The slicer passes the tool: `PRINT_END T=[current_extruder]` |
| `PRINT_START` forced the exhaust fan on/off during heat-up, overriding the slicer | Removed; the slicer controls it |
| `printer.cfg` shipped the author's own input shaper and bed mesh | Removed; the installer keeps your own `SAVE_CONFIG` block |
| `LINE_PURGE` left the printer in absolute extrusion | It stays in relative extrusion (`M83`) |

## What's included

- `Q2/macros/gcode_macro-Box.cfg`, `gcode_macro-Printer.cfg`: the main macros (installed as `gcode_macro.cfg`). The Box file also has `ORCA_QIDI_BOX`, which the Box start G-code calls to map tools to Box slots.
- `Q2/macros/printer.cfg`: template used on the legacy layout (your calibration is carried over)
- `Q2/KAMP/`: KAMP adaptive meshing, plus the superuser `LINE_PURGE` (a fixed 55 mm line at the front of the bed, with a retract and a quick move to snap the string)

### Useful macros

- `G32` before a print: skip the adaptive mesh for that one print. `PRINT_END` turns adaptive meshing back on.
- Box heater stays on after prints. To turn it off at the end of each print, remove the `#` in front of `DISABLE_BOX_HEATER` in `PRINT_END`.

## Bloat removal

Turns off: `algo_app` and `QIDILink-client` (Qidi app link and AI detection), `bluetooth`, `pulseaudio`, the VPN services `xl2tpd`, `strongswan-starter` and `openvpn`, `triggerhappy` (hotkey daemon) and `packagekit` (background package polling). The touchscreen (`lightdm`, `QD_Q2` / `qidi-client`) and `polkitd` (needed by Moonraker) keep running. Reboot afterwards. Option 5 undoes it.

## Credits and licence

Built on [Qidi-Q2-superuser](https://github.com/Camden-Winder/Qidi-Q2-superuser) by Camden-Winder and [KAMP](https://github.com/kyleisah/Klipper-Adaptive-Meshing-Purging). Licensed under GPL-3.0, like the original.
