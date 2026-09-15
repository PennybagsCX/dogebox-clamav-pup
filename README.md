# 🛡️ ClamAV for Dogebox

<p align="center"><img src="clamav/logo.png" width="110" alt="ClamAV pup logo"></p>

**[ClamAV](https://www.clamav.net) antivirus scanner packaged as a [Dogebox](https://dogebox.org) pup** — defense-in-depth on top of qBittorrent's bubblewrap sandbox. Watches every pup's downloads/ in real time via inotify, plus an hourly scheduled full sweep. Infected files are quarantined to `/storage/quarantine` (chmod 000) so Radarr/Sonarr's `DownloadedMoviesScan`/`DownloadedEpisodesScan` never imports them. Signature DB updates automatically via `freshclam` 4×/day. WebUI status page on port 9000.

> ⚖️ ClamAV catches known signatures (most consumer-grade torrent malware, Windows EXE/LNK/RTF, malicious Office macros, common ZIPs). It's **not** a sandbox and won't stop zero-days — pair with the qBittorrent pup's bubblewrap sandbox for layered defense.

## Install

1. First, make sure qBittorrent's bubblewrap sandbox is in place (v0.0.5+, gives `/storage/quarantine` as part of the sandbox's bind mounts so qB can still write there for the scanner to pick up).
2. Pup Store → Manage Sources → add `https://github.com/PennybagsCX/dogebox-clamav-pup.git` → install **ClamAV**.
3. Wait ~30s on first boot — `freshclam` downloads ~250MB of signatures. Subsequent boots use the cached DB.
4. Open the webUI (dogebox maps a host port) to confirm `clamd ready` and the heartbeat status.

## What gets scanned

The scanner watches every `downloads/` directory across all installed pups:

- qBittorrent pup downloads (`/storage/quarantine` symlink is also watched — if you manually drop a file there for review, the scanner picks it up too)
- Radarr pup downloads
- Sonarr pup downloads

…plus any future pup with a `downloads/` subdir under `/opt/dogebox/pups/storage/<id>/`.

Scan triggers:
- **Inotify** (`close_write` and `moved_to`) — within seconds of a torrent finishing
- **Scheduled hourly** — full directory sweep of everything `<8GB` (configurable in `pup.nix`)

## Quarantine behavior

When ClamAV flags a file:
1. The file is `chmod 000`'d in place (instant unreadable) and moved to `/storage/quarantine/<full-path-with-slashes-replaced-by-underscores>.quarantine`
2. An entry is appended to `/storage/config/quarantine.log` (also accessible via the webUI at `/raw`)
3. Radarr/Sonarr's next `DownloadedMoviesScan`/`DownloadedEpisodesScan` skips it (no longer in `/storage/downloads`)
4. The webUI status updates within 30s

To **review** a quarantined file later (it stays chmod 000):
```bash
ssh shibe@10.0.0.98
sudo ls /opt/dogebox/pups/storage/<pup-storage-dir>/quarantine/    # list
sudo chmod 400 /opt/dogebox/pups/storage/<...>/quarantine/file.quarantine
# Inspect it however you like, then re-quarantine:
sudo chmod 000 /opt/dogebox/pups/storage/<...>/quarantine/file.quarantine
# Or delete:
sudo rm /opt/dogebox/pups/storage/<...>/quarantine/file.quarantine
```

## WebUI

`http://<box>:<clamav-web-port>/` (dogebox maps a 10000-range port; check the pup card on the dashboard for the exact number).

- `/` — HTML status page with heartbeat + recent quarantine events
- `/json` — raw JSON status (heartbeat timestamp, watch dirs, quarantine count)
- `/raw?lines=200` — last 200 lines of the quarantine log

## Performance

On a NanoPC-T6 (RK3588, ARM Cortex-A76, 16GB RAM):
- **Idle** — `clamd` + scanner use ~300MB RAM, ~0% CPU
- **During scan** — 1-2 cores busy, files scan at 30-50MB/s/core
- **freshclam** — runs 4×/day, takes 10-30s, negligible
- **Hourly sweep** — runs in the background, no impact on other pups unless they happen to be writing a file at the same instant (inotify + scanner coordination handles that)

## Configuration

All paths and thresholds are in `clamav/pup.nix`. To change the max file size (default 8GB), max scan size, or scan recursion depth, edit the `scanner.sh` block and the `clamd.conf` heredoc in `pup.nix`, then bump the version + `nixFileSha256` in `manifest.json`.

## Limitations

- **ClamAV is signature-based.** It catches known malware but not novel/unknown threats. Pair with the qBittorrent sandbox (v0.0.5) which prevents malware from running even if it slips through.
- **Archive scanning is enabled** but the default `MaxFileSize` is 0 (unlimited). Setting a hard cap on scan size prevents a malicious multi-GB zip bomb from locking up the daemon.
- **Real-time inotify depends on inotify-tools** (`inotifywait`). The scanner falls back to scheduled-only if `inotifywait` exits.
- **No automatic deletion** of quarantined files. They accumulate until you manually review/remove them.

## License

MIT for the packaging. ClamAV is GPLv2 — this repo only packages it.
