{ pkgs ? import <nixpkgs> {} }:

# ClamAV pup for Dogebox.
# One service that starts freshclam, then clamd, then inotify+scheduled scanner,
# then a tiny Python status page on port 9000. All four share /storage.
#
# Auto-update flow:
#   1. On startup, check if /storage/config/clamav-db/main.{cvd,cldb} exists.
#      - If absent OR freshness file says >24h old: run freshclam synchronously
#        ONCE to bootstrap (this is where the box needs outbound to database.clamav.net).
#        The result is recorded in /storage/config/freshclam.status.
#      - If recent: skip the sync run (saves ~30s on every boot).
#   2. Then start freshclam in --daemon mode (Checks=4 → ~6h interval).
#   3. clamd starts once DB is present (whether from disk or the sync run).
#   4. The webUI reads freshclam.status and shows DB age + status. A DB >48h old
#      is flagged as "stale — outbound may be blocked"; >72h is critical.
#
# Layout:
#   /storage/config/             writable config + log dir
#   /storage/config/clamav-db/   signature DB (managed by freshclam)
#   /storage/config/clamd.ctl    clamd UNIX socket
#   /storage/config/watched/     symlinks to every pup's downloads/ dir
#   /storage/config/scanner.log  all scan events (append)
#   /storage/config/quarantine.log   only quarantine events (append)
#   /storage/config/freshclam.status   {last_successful_update_iso, last_attempt_iso, db_age_seconds, status: ok|stale|critical|unknown}
#   /storage/config/status.json  live scanner status (heartbeat every 30s)
#   /storage/quarantine/         chmod 000'd bad files
let
  app = pkgs.clamav;
  inotify = pkgs.inotify-tools;
  python = pkgs.python3;
  jq = pkgs.jq;

  # inotify watch list of pup download dirs is computed at runtime from
  # /opt/dogebox/pups/storage/*/downloads. This script does the scan.
  scannerScript = pkgs.writeScript "scanner.sh" ''
    #!${pkgs.stdenv.shell}
    QUARANTINE=/storage/quarantine
    LOG=/storage/config/scanner.log
    STATUS=/storage/config/status.json
    MAX_MB=8192
    MAX_BYTES=$((MAX_MB * 1024 * 1024))
    CLAMDSCAN=${app}/bin/clamdscan
    CLAMSCAN=${app}/bin/clamscan
    SOCKET=/storage/config/clamd.ctl
    MV=${pkgs.coreutils}/bin/mv
    CHMOD=${pkgs.coreutils}/bin/chmod
    MKDIR=${pkgs.coreutils}/bin/mkdir
    DATE=${pkgs.coreutils}/bin/date
    STAT=${pkgs.coreutils}/bin/stat
    ECHO=${pkgs.coreutils}/bin/echo
    GREP=${pkgs.gnugrep}/bin/grep
    TR=${pkgs.coreutils}/bin/tr
    SLEEP=${pkgs.coreutils}/bin/sleep
    INOTIFYWAIT=${inotify}/bin/inotifywait
    FIND=${pkgs.findutils}/bin/find
    CAT=${pkgs.coreutils}/bin/cat
    SUDO=${pkgs.sudo}/bin/sudo

    $MKDIR -p "$QUARANTINE"

    # Build watch list from /opt/dogebox/pups/storage/*/downloads AND any
    # media/downloads subdir (the Samba share exposes media/downloads as
    # the user-writable destination from native Mac apps).
    WATCH_DIRS=""
    if [ -d /storage/config/watched ]; then
      for d in /storage/config/watched/*/; do
        [ -d "$d" ] && WATCH_DIRS="$WATCH_DIRS $d"
      done
      # Also include the Samba pup's media/{downloads,documents,torrents} if present.
      # The Samba pup has no top-level downloads/, so the simple /watched/*/ loop
      # above misses it — explicitly check for media subdirs.
      for pup in /storage/config/watched/*/; do
        [ -d "$pup" ] || continue
        for sub in downloads documents torrents; do
          [ -d "$pup/media/$sub" ] && WATCH_DIRS="$WATCH_DIRS $pup/media/$sub"
        done
      done
    fi
    $ECHO "scanner watch dirs: $WATCH_DIRS"

    scan_file() {
      local f="$1" trigger="$2"
      [ -f "$f" ] || return 0
      case "$f" in
        */quarantine/*|*/clamd.ctl|*/clamd.log|*/scanner.log|*/freshclam.log|*/status.json|*.quarantine) return 0;;
      esac
      local sz; sz=$($STAT -c%s "$f" 2>/dev/null || echo 0)
      [ "$sz" -gt "$MAX_BYTES" ] && { $ECHO "skip (too big): $f" >> "$LOG"; return 0; }

      local out
      if [ -S "$SOCKET" ]; then
        out=$($CLAMDSCAN --quiet --infected --no-summary "$f" 2>&1) || true
      else
        out=$($CLAMSCAN --quiet --infected --no-summary "$f" 2>/dev/null) || true
      fi
      if [ -n "$out" ]; then
        local safe; safe=$($ECHO "$f" | $TR '/' '_')
        local target="$QUARANTINE/$safe.quarantine"
        $MV "$f" "$target" 2>/dev/null || $SUDO -n $MV "$f" "$target"
        $CHMOD 000 "$target" 2>/dev/null || true
        local ts; ts=$($DATE -u +%FT%TZ)
        $ECHO "[$ts] QUARANTINE: $f -> $target ($out) trigger=$trigger" >> "$LOG"
        $ECHO "[$ts] QUARANTINE: $f -> $target ($out) trigger=$trigger" >> /storage/config/quarantine.log
      fi
    }

    # Initial status
    $ECHO '{"started":"'$($DATE -u +%FT%TZ)'","watching":""}' > "$STATUS"

    # inotify watch (foreground — when it exits, we restart it)
    if [ -n "$WATCH_DIRS" ]; then
      $INOTIFYWAIT -m -r -e close_write,moved_to $WATCH_DIRS 2>>"$LOG" | \
        while read -r dir event file; do
          scan_file "$dir$file" "inotify"
        done &
      INO_PID=$!
    fi

    # Hourly scheduled full scan
    (
      while $SLEEP 3600; do
        $ECHO "[$($DATE -u +%FT%TZ)] hourly scheduled scan starting" >> "$LOG"
        for d in $WATCH_DIRS; do
          $FIND "$d" -type f -size -''${MAX_MB}M 2>/dev/null | while read -r f; do
            scan_file "$f" "scheduled"
          done
        done
        $ECHO "[$($DATE -u +%FT%TZ)] hourly scheduled scan done" >> "$LOG"
      done
    ) &
    SCHED_PID=$!

    # Heartbeat: every 30s update status.json
    (
      while $SLEEP 30; do
        local qn; qn=$($GREP -c '^\[' /storage/config/quarantine.log 2>/dev/null || echo 0)
        local ts; ts=$($DATE -u +%FT%TZ)
        # Read freshclam status (written by the freshclam wrapper in run.sh)
        local fc_status="unknown"; local fc_last_iso=""; local fc_db_age=""
        if [ -f /storage/config/freshclam.status ]; then
          fc_status=$(${jq}/bin/jq -r '.status // "unknown"' /storage/config/freshclam.status 2>/dev/null || echo unknown)
          fc_last_iso=$(${jq}/bin/jq -r '.last_successful_update_iso // ""' /storage/config/freshclam.status 2>/dev/null || echo "")
          local db_age_seconds=$(${jq}/bin/jq -r '.db_age_seconds // -1' /storage/config/freshclam.status 2>/dev/null || echo -1)
          if [ "$db_age_seconds" -ge 0 ]; then
            local hours=$((db_age_seconds / 3600))
            fc_db_age="''${hours}h"
          else
            fc_db_age="unknown"
          fi
        fi
        $CAT > "$STATUS" <<JSON
    {"last_heartbeat":"$ts","quarantined_total":$qn,"log":"/storage/config/scanner.log","watching":"$WATCH_DIRS","freshclam":{"status":"$fc_status","last_successful_update":"$fc_last_iso","db_age":"$fc_db_age"}}
    JSON
      done
    ) &
    HB_PID=$!

    wait $INO_PID $SCHED_PID $HB_PID
  '';

  # Minimal Python stdlib status page
  webuiScript = pkgs.writeText "webui.py" ''
    import http.server, json, sys, os
    from urllib.parse import urlparse, parse_qs

    STATUS_FILE = sys.argv[1]
    LOG_FILE = sys.argv[2]
    FRESHCLAM_LOG_FILE = sys.argv[3] if len(sys.argv) > 3 else "/storage/config/freshclam.log"
    FRESHCLAM_STATUS_FILE = "/storage/config/freshclam.status"

    def _read_freshclam():
        try:
            with open(FRESHCLAM_STATUS_FILE) as f:
                return json.load(f)
        except Exception:
            return {"status": "unknown"}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/json":
                try:
                    body = open(STATUS_FILE).read().encode()
                except Exception as e:
                    body = ('{"error":"' + str(e) + '"}').encode()
                self._send(200, "application/json", body)
                return
            if self.path == "/freshclam":
                self._send(200, "application/json", json.dumps(_read_freshclam()).encode())
                return
            if self.path.startswith("/raw"):
                n = int(parse_qs(urlparse(self.path).query).get("lines", ["100"])[0])
                try:
                    lines = open(LOG_FILE).readlines()[-n:]
                    body = "".join(lines).encode()
                except FileNotFoundError:
                    body = b"(no quarantine events yet)"
                self._send(200, "text/plain", body)
                return
            try:
                body = open(STATUS_FILE).read()
            except Exception:
                body = '{"error":"no status yet"}'
            fc = _read_freshclam()
            fc_status = fc.get("status", "unknown")
            fc_age = fc.get("db_age_seconds", -1)
            fc_last = fc.get("last_successful_update_iso", "")
            color_map = {"ok": "#0a0", "stale": "#c80", "critical": "#c00", "unknown": "#888"}
            color = color_map.get(fc_status, "#888")
            if fc_age is None or fc_age < 0:
                age_str = "unknown"
            elif fc_age < 3600:
                age_str = str(fc_age // 60) + " min"
            else:
                age_str = str(fc_age // 3600) + " h"
            hint = ""
            if fc_status == "critical":
                hint = ("<p style='color:#c00'><b>Critical:</b> signature DB is over 72h old. "
                        "Likely cause: outbound blocked. Check /storage/config/freshclam.log and "
                        "allow outbound HTTPS to database.clamav.net, or the scanner will only catch "
                        "older known signatures.</p>")
            elif fc_status == "stale":
                hint = ("<p style='color:#c80'><b>Stale:</b> signature DB is over 48h old. "
                        "freshclam likely failed to reach the update mirror.</p>")
            html = (
                "<!doctype html><html><head><title>ClamAV pup status</title>"
                "<meta charset='utf-8'>"
                "<style>"
                "body{font-family:system-ui;margin:2rem;max-width:920px}"
                "pre{background:#111;color:#0f0;padding:1rem;border-radius:.5rem;overflow:auto}"
                ".badge{display:inline-block;padding:.25rem .75rem;border-radius:1rem;color:#fff;font-weight:600}"
                ".badge.ok{background:#0a0}.badge.stale{background:#c80}.badge.critical{background:#c00}.badge.unknown{background:#888}"
                "a{color:#08f}"
                "</style></head>"
                "<body><h1>ClamAV pup</h1>"
                "<p><a href='/json'>status JSON</a> &middot; "
                "<a href='/freshclam'>freshclam JSON</a> &middot; "
                "<a href='/raw?lines=50'>recent log</a></p>"
                "<h2>Signature DB freshness</h2>"
                "<p><span class='badge " + fc_status + "'>" + fc_status.upper() + "</span> &middot; "
                "age: <b>" + age_str + "</b> &middot; last update: <b>" + (fc_last or "unknown") + "</b></p>"
                + hint +
                "<h2>Scanner status</h2><pre id='status'>" + body.replace("<","&lt;") + "</pre>"
                "<h2>Recent quarantine events</h2><pre id='log'>"
                "(see /raw?lines=200)</pre>"
                "<script>"
                "fetch('/json').then(r=>r.text()).then(t=>{document.getElementById('status').textContent=t})"
                ".catch(e=>{document.getElementById('status').textContent='err: '+e})"
                "fetch('/raw?lines=20').then(r=>r.text()).then(t=>{document.getElementById('log').textContent=t})"
                "</script></body></html>"
            ).encode()
            self._send(200, "text/html; charset=utf-8", html)

        def _send(self, code, ctype, body):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args, **kwargs):
            pass

    port = int(sys.argv[4])
    TS = getattr(http.server, "ThreadingHTTPServer", None) or http.server.ThreadingTCPServer
    with TS(("0.0.0.0", port), Handler) as s:
        s.allow_reuse_address = True
        s.serve_forever()
  '';

  runScript = pkgs.writeScriptBin "run.sh" ''
    #!${pkgs.stdenv.shell}
    set -e
    export HOME=/storage/config
    MKDIR=${pkgs.coreutils}/bin/mkdir
    LN=${pkgs.coreutils}/bin/ln
    CAT=${pkgs.coreutils}/bin/cat
    SLEEP=${pkgs.coreutils}/bin/sleep
    ECHO=${pkgs.coreutils}/bin/echo
    DATE=${pkgs.coreutils}/bin/date
    TOUCH=${pkgs.coreutils}/bin/touch
    FIND=${pkgs.findutils}/bin/find
    STAT=${pkgs.coreutils}/bin/stat
    GREP=${pkgs.gnugrep}/bin/grep
    TEE=${pkgs.coreutils}/bin/tee
    JQ=${jq}/bin/jq

    $MKDIR -p /storage/config /storage/quarantine /storage/config/clamav-db /storage/config/watched

    # Symlink every pup's downloads/ into /storage/config/watched/<pupID>
    if [ -d /opt/dogebox/pups/storage ]; then
      for pup in /opt/dogebox/pups/storage/*/; do
        [ -d "$pup/downloads" ] || continue
        $LN -sfn "$pup/downloads" "/storage/config/watched/$(basename "$pup")" 2>/dev/null || true
      done
    fi

    # freshclam config
    $CAT > /storage/config/freshclam.conf <<EOF
    DatabaseDirectory /storage/config/clamav-db
    UpdateLogFile /storage/config/freshclam.log
    DatabaseOwner root
    DatabaseMirror database.clamav.net
    Checks 4
    NotifyClamd /storage/config/clamd.conf
    EOF

    # Helper: write freshclam status JSON with current freshness heuristic.
    # Reads the most recent successful update from /storage/config/freshclam.log.
    write_freshclam_status() {
      local last_iso=""
      # freshclam logs look like: "ClamAV update process started at Tue Sep 14 20:00:00 2026"
      # and on success: "main.cvd updated (version: 62, sigs: ...)"
      # Simpler: track the mtime of the newest cvd/clvd file in the DB dir.
      local newest_db
      newest_db=$($FIND /storage/config/clamav-db -maxdepth 1 -type f \( -name "*.cvd" -o -name "*.cldb" \) -printf "%T@ %p\n" 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2-)
      local now_epoch=$($DATE +%s)
      local db_age=-1
      if [ -n "$newest_db" ] && [ -f "$newest_db" ]; then
        local db_mtime=$($STAT -c %Y "$newest_db")
        db_age=$((now_epoch - db_mtime))
      fi
      # Try to extract last success from freshclam.log
      if [ -f /storage/config/freshclam.log ]; then
        last_iso=$($GREP -oE "[A-Z][a-z]+ [A-Z][a-z]+ +[0-9]+ +[0-9]+:[0-9]+:[0-9]+ [0-9]+" /storage/config/freshclam.log 2>/dev/null | tail -1 || true)
        if [ -z "$last_iso" ]; then
          if [ -f /storage/config/clamav-db/main.cvd ]; then
            last_iso=$($STAT -c %y /storage/config/clamav-db/main.cvd 2>/dev/null || true)
          elif [ -f /storage/config/clamav-db/main.cldb ]; then
            last_iso=$($STAT -c %y /storage/config/clamav-db/main.cldb 2>/dev/null || true)
          fi
        fi
      fi
      local status_str
      if [ "$db_age" -lt 0 ]; then
        status_str="unknown"
      elif [ "$db_age" -lt 172800 ]; then
        status_str="ok"
      elif [ "$db_age" -lt 259200 ]; then
        status_str="stale"
      else
        status_str="critical"
      fi
      $CAT > /storage/config/freshclam.status <<JSON
    {"status":"$status_str","last_successful_update_iso":"$last_iso","last_attempt_iso":"$($DATE -u +%FT%TZ)","db_age_seconds":$db_age}
    JSON
    }

    # Decide if we need a synchronous freshclam run.
    DB_NEEDS_UPDATE=no
    if [ ! -f /storage/config/clamav-db/main.cvd ] && [ ! -f /storage/config/clamav-db/main.cldb ]; then
      DB_NEEDS_UPDATE=yes
      $ECHO "[clamav-pup] no signature DB found, will bootstrap"
    else
      # Check freshness — if >24h old, force a sync run
      local newest_db db_mtime_epoch db_age
      newest_db=$($FIND /storage/config/clamav-db -maxdepth 1 -type f \( -name "*.cvd" -o -name "*.cldb" \) -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f1)
      if [ -n "$newest_db" ]; then
        db_mtime_epoch=$newest_db
        db_age=$(( $($DATE +%s) - db_mtime_epoch ))
        if [ "$db_age" -gt 86400 ]; then
          DB_NEEDS_UPDATE=yes
          $ECHO "[clamav-pup] DB is $((db_age/3600))h old, will refresh"
        else
          $ECHO "[clamav-pup] DB is recent ($((db_age/3600))h), daemon-only mode"
        fi
      fi
    fi

    # Sync freshclam run (only on first boot or stale DB; bounded by a timeout).
    if [ "$DB_NEEDS_UPDATE" = "yes" ]; then
      $ECHO "[clamav-pup] running freshclam (sync, 60s timeout, may fail if no outbound)..."
      timeout 60 ${app}/bin/freshclam --config-file=/storage/config/freshclam.conf --no-warnings 2>&1 | $TEE -a /storage/config/freshclam.log || {
        rc=$?
        $ECHO "[clamav-pup] freshclam sync failed (exit $rc) — likely no outbound; clamd will start with whatever DB is present"
      }
    fi

    # Write initial status JSON
    write_freshclam_status

    # Start freshclam daemon (4x/day checks)
    ${app}/bin/freshclam --config-file=/storage/config/freshclam.conf --daemon --no-warnings 2>>/storage/config/freshclam.log &
    FRESHCLAM_PID=$!

    # Wait for signature DB to be present
    $ECHO "[clamav-pup] waiting for signature DB..."
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
      if [ -f /storage/config/clamav-db/main.cvd ] || [ -f /storage/config/clamav-db/main.cldb ]; then
        $ECHO "[clamav-pup] DB ready after $i attempts"
        break
      fi
      $SLEEP 2
    done
    write_freshclam_status

    # clamd config
    $CAT > /storage/config/clamd.conf <<EOF
    LogFile /storage/config/clamd.log
    LogTime yes
    DatabaseDirectory /storage/config/clamav-db
    LocalSocket /storage/config/clamd.ctl
    LocalSocketMode 660
    User root
    Foreground yes
    ScanPE yes
    ScanELF yes
    ScanOLE2 yes
    ScanMail yes
    ScanArchive yes
    ArchiveBlockEncrypted no
    MaxFileSize 0
    MaxScanSize 0
    MaxRecursion 16
    MaxFiles 10000
    EOF

    # Start clamd in background
    ${app}/bin/clamd --config-file=/storage/config/clamd.conf 2>>/storage/config/clamd.log &
    CLAMD_PID=$!

    # Wait for clamd socket
    for i in 1 2 3 4 5 6 7 8 9 10; do
      [ -S /storage/config/clamd.ctl ] && break
      $SLEEP 1
    done
    if [ ! -S /storage/config/clamd.ctl ]; then
      $ECHO "[clamav-pup] WARN: clamd not up; scanner will fall back to clamscan"
    else
      $ECHO "[clamav-pup] clamd ready"
    fi

    # Start scanner
    ${scannerScript} &
    SCANNER_PID=$!

    # Start webui
    ${python}/bin/python3 ${webuiScript} /storage/config/status.json /storage/config/quarantine.log /storage/config/freshclam.log 9000 &
    WEBUI_PID=$!

    # Background task: refresh freshclam.status every 5min so the webUI stays current
    (
      while $SLEEP 300; do
        write_freshclam_status
      done
    ) &
    FCSTATUS_PID=$!

    # Wait for any child to die
    wait -n 2>/dev/null || true
    kill $FRESHCLAM_PID $CLAMD_PID $SCANNER_PID $WEBUI_PID $FCSTATUS_PID 2>/dev/null || true
  '';

in
{
  clamav = runScript;
}
