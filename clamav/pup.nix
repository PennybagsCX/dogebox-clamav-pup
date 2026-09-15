{ pkgs ? import <nixpkgs> {} }:

# ClamAV pup for Dogebox.
# One service that starts freshclam, then clamd, then inotify+scheduled scanner,
# then a tiny Python status page on port 9000. All four share /storage.
#
# Layout:
#   /storage/config/             writable config + log dir
#   /storage/config/clamav-db/   signature DB (managed by freshclam)
#   /storage/config/clamd.ctl    clamd UNIX socket
#   /storage/config/watched/     symlinks to every pup's downloads/ dir
#   /storage/config/scanner.log  all scan events (append)
#   /storage/config/quarantine.log   only quarantine events (append)
#   /storage/config/status.json  live status (heartbeat every 30s)
#   /storage/quarantine/         chmod 000'd bad files
let
  app = pkgs.clamav;
  inotify = pkgs.inotify-tools;
  python = pkgs.python3;

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

    # Build watch list from /opt/dogebox/pups/storage/*/downloads
    WATCH_DIRS=""
    if [ -d /storage/config/watched ]; then
      for d in /storage/config/watched/*/; do
        [ -d "$d" ] && WATCH_DIRS="$WATCH_DIRS $d"
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
        $CAT > "$STATUS" <<JSON
    {"last_heartbeat":"$ts","quarantined_total":$qn,"log":"/storage/config/scanner.log","watching":"$WATCH_DIRS"}
    JSON
      done
    ) &
    HB_PID=$!

    wait $INO_PID $SCHED_PID $HB_PID
  '';

  # Minimal Python stdlib status page
  webuiScript = pkgs.writeText "webui.py" ''
    import http.server, json, sys
    from urllib.parse import urlparse, parse_qs

    STATUS_FILE = sys.argv[1]
    LOG_FILE = sys.argv[2]

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/json":
                try:
                    body = open(STATUS_FILE).read().encode()
                except Exception as e:
                    body = ('{"error":"' + str(e) + '"}').encode()
                self._send(200, "application/json", body)
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
            html = (
                "<!doctype html><html><head><title>ClamAV pup status</title>"
                "<meta charset='utf-8'>"
                "<style>body{font-family:system-ui;margin:2rem;max-width:920px}"
                "pre{background:#111;color:#0f0;padding:1rem;border-radius:.5rem;overflow:auto}"
                "a{color:#08f}</style></head>"
                "<body><h1>ClamAV pup</h1>"
                "<p><a href='/json'>raw JSON</a> &middot; "
                "<a href='/raw?lines=50'>recent log</a></p>"
                "<h2>Status</h2><pre id='status'>" + body.replace("<","&lt;") + "</pre>"
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

    port = int(sys.argv[3])
    # ThreadingHTTPServer is Python 3.12+; fall back to ThreadingTCPServer on older interpreters
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

    # Start freshclam daemon (4x/day checks)
    ${app}/bin/freshclam --config-file=/storage/config/freshclam.conf &
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
    ${python}/bin/python3 ${webuiScript} /storage/config/status.json /storage/config/quarantine.log 9000 &
    WEBUI_PID=$!

    # Wait for any child to die
    wait -n 2>/dev/null || true
    kill $FRESHCLAM_PID $CLAMD_PID $SCANNER_PID $WEBUI_PID 2>/dev/null || true
  '';

in
{
  clamav = runScript;
}
