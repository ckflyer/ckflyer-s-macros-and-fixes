# ckflyer's macros and fixes for the Qidi Q2

Klipper macros for a stock Qidi Q2, in two versions (**Box**, for a Qidi Box, and **Printer**, for no Box), plus removal of background services that printing doesn't need.

> **Work in progress:** the macro files are being added. The installer won't work until they're in the repo.

## Install

SSH into the printer as `mks` (not root) and run:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ckflyer/ckflyer-s-macros-and-fixes/main/install.sh)
```

| Option | What it does |
| --- | --- |
| 1) Install Box version | Your Q2 has a Qidi Box connected |
| 2) Install Printer version | No Box |
| 3) Update macros | Re-downloads the macro files for the version you installed |
| 4) Remove bloat | Turns off unneeded background services |
| 5) Undo bloat removal | Turns them back on |
| 6) Restore a backup | Puts back a saved copy of your whole config folder |

Every install and update first saves your whole config folder to `~/q2_macro_backups/`. The installer won't run during a print, downloads everything before changing anything, and restarts Klipper at the end.

## Bloat removal

Turns off: `algo_app` and `QIDILink-client` (Qidi app link and AI detection), `bluetooth`, `pulseaudio`, the VPN services `xl2tpd`, `strongswan-starter` and `openvpn`, `triggerhappy` (hotkey daemon) and `packagekit` (background package polling). The touchscreen and `polkitd` (needed by Moonraker) keep running. Reboot afterwards. Option 5 undoes it.
