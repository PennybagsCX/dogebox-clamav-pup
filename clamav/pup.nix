{ pkgs ? import <nixpkgs> {} }:

# ClamAV pup for Dogebox.
# Four independent services (clamav-daemon, clamav-scanner, clamav-freshclam, clamav-webui)
# that share /storage and coordinate via socket + status files.
#
# Startup order (driven by systemd service deps):
#   clamav-freshclam  → bootstrap DB, then daemonise
#   clamav-daemon     → clamd (waits for DB via clamd.conf clamd-on-update-fork)
#   clamav-scanner    → inotify + hourly full scan, uses clamdscan / clamscan
#   clamav-webui      → Python status page on :9000
#
# Storage layout:
#   /storage/config/           config + log dir
#   /storage/config/clamav-db/ signature DB (freshclam manages)
#   /storage/config/clamd.ctl  clamd UNIX socket
#   /storage/config/watched/   symlinks: <pupID> → <pupStorage>/downloads
#   /storage/config/scanner.log
#   /storage/config/quarantine.log
#   /storage/config/freshclam.status
#   /storage/config/status.json  (scanner heartbeat)
#   /storage/quarantine/        chmod 000'd bad files

let
  app    = pkgs.clamav;
  inotify = pkgs.inotify-tools;
  python = pkgs.python3;
  jq     = pkgs.jq;

  STATUS_JSON       = "/storage/config/status.json";
  QUARANTINE_DIR    = "/storage/quarantine";
  SCANNER_LOG       = "/storage/config/scanner.log";
  QUARANTINE_LOG    = "/storage/config/quarantine.log";
  CLAMD_SOCKET      = "/storage/config/clamd.ctl";
  FRESHCLAM_STATUS  = "/storage/config/freshclam.status";
  FRESHCLAM_CONF    = "/storage/config/freshclam.conf";
  CLAMAV_DB         = "/storage/config/clamav-db";

  # ---- shared helper: write freshclam status JSON --------------------
  writeFcStatus = pkgs.writeScript "write-fc-status.sh" ''
    #!${pkgs.stdenv.shell}
    DATE=${pkgs.coreutils}/bin/date
    STAT=${pkgs.coreutils}/bin/stat
    FIND=${pkgs.findutils}/bin/find
    CAT=${pkgs.coreutils}/bin/cat
    DB_DIR="${CLAMAV_DB}"
    OUT="${FRESHCLAM_STATUS}"
    newest=$($FIND "$DB_DIR" -maxdepth 1 -type f \( -name "*.cvd" -o -name "*.cldb" \) -printf "%T@\n" 2>/dev/null | sort -nr | head -1)
    age=-1
    [ -n "$newest" ] && age=$(($($DATE +%s) - newest))
    if   [ "$age" -lt 0 ];       then st="unknown"
    elif [ "$age" -lt 172800 ];  then st="ok"
    elif [ "$age" -lt 259200 ];  then st="stale"
    else                             st="critical"; fi
    $CAT > "$OUT" <<JSON
{"status":"$st","last_attempt_iso":"$($DATE -u +%FT%TZ)","db_age_seconds":$age}
JSON
  '';

  # ---- clamd (clamav-daemon service) ---------------------------------
  clamdScript = pkgs.writeScript "clamd.sh" ''
    #!${pkgs.stdenv.shell}
    set -e
    MKDIR=${pkgs.coreutils}/bin/mkdir
    LN=${pkgs.coreutils}/bin/ln
    CAT=${pkgs.coreutils}/bin/cat
    ECHO=${pkgs.coreutils}/bin/echo

    $MKDIR -p /storage/config /storage/quarantine "${CLAMAV_DB}"

    # Symlink every pup's downloads/ into watched/<pupID>
    if [ -d /opt/dogebox/pups/storage ]; then
      for pup in /opt/dogebox/pups/storage/*/; do
        [ -d "$pup/downloads" ] && $LN -sfn "$pup/downloads" "/storage/config/watched/$(basename "$pup")" 2>/dev/null || true
      done
    fi

    $CAT > /storage/config/clamd.conf <<'EOF'
LogFile /storage/config/clamd.log
LogTime yes
DatabaseDirectory ${CLAMAV_DB}
LocalSocket ${CLAMD_SOCKET}
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

    $ECHO "[clamd] starting..."
    exec ${app}/bin/clamd --config-file=/storage/config/clamd.conf
  '';

  # ---- freshclam (clamav-freshclam service) -------------------------
  freshclamScript = pkgs.writeScript "freshclam.sh" ''
    #!${pkgs.stdenv.shell}
    set -e
    MKDIR=${pkgs.coreutils}/bin/mkdir
    CAT=${pkgs.coreutils}/bin/cat
    DATE=${pkgs.coreutils}/bin/date
    FIND=${pkgs.findutils}/bin/find
    SLEEP=${pkgs.coreutils}/bin/sleep
    ECHO=${pkgs.coreutils}/bin/echo
    TEE=${pkgs.coreutils}/bin/tee
    WRITE_FC_STATUS=${writeFcStatus}/bin/write-fc-status.sh

    $MKDIR -p "${CLAMAV_DB}"

    $CAT > ${FRESHCLAM_CONF} <<'EOF'
DatabaseDirectory ${CLAMAV_DB}
UpdateLogFile /storage/config/freshclam.log
DatabaseOwner root
DatabaseMirror database.clamav.net
Checks 4
EOF

    # Bootstrap: sync run if no DB or DB > 24 h old
    NEED_SYNC=no
    if [ ! -f "${CLAMAV_DB}"/main.cvd ] && [ ! -f "${CLAMAV_DB}"/main.cldb ]; then
      NEED_SYNC=yes
      $ECHO "[freshclam] no DB — bootstrap sync..."
    else
      newest=$($FIND "${CLAMAV_DB}" -maxdepth 1 -type f \( -name "*.cvd" -o -name "*.cldb" \) -printf "%T@\n" 2>/dev/null | sort -nr | head -1)
      [ -n "$newest" ] && [ $(($($DATE +%s) - newest)) -gt 86400 ] && NEED_SYNC=yes
    fi

    if [ "$NEED_SYNC" = "yes" ]; then
      timeout 90 ${app}/bin/freshclam --config-file=${FRESHCLAM_CONF} --no-warnings 2>&1 | $TEE -a /storage/config/freshclam.log || \
        $ECHO "[freshclam] sync failed (exit $?) — continuing"
    fi
    $WRITE_FC_STATUS

    # Background: refresh status every 5 min
    (
      while $SLEEP 300; do $WRITE_FC_STATUS; done
    ) &
    STATUS_PID=$!

    $ECHO "[freshclam] starting daemon..."
    exec ${app}/bin/freshclam --config-file=${FRESHCLAM_CONF} --daemon --no-warnings 2>>/storage/config/freshclam.log
  '';

  # ---- scanner (clamav-scanner service) -----------------------------
  scannerScript = pkgs.writeScript "scanner.sh" ''
    #!${pkgs.stdenv.shell}
    set -e
    QUARANTINE="${QUARANTINE_DIR}"
    LOG="${SCANNER_LOG}"
    STATUS="${STATUS_JSON}"
    MAX_MB=8192
    MAX_BYTES=$((MAX_MB * 1024 * 1024))
    CLAMDSCAN=${app}/bin/clamdscan
    CLAMSCAN=${app}/bin/clamscan
    SOCKET="${CLAMD_SOCKET}"
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
    JQ=${jq}/bin/jq

    $MKDIR -p "$QUARANTINE"

    # Build watch list from /storage/config/watched/<pupID>/{downloads,documents,torrents}
    WATCH_DIRS=""
    if [ -d /storage/config/watched ]; then
      for pup in /storage/config/watched/*/; do
        [ -d "$pup" ] || continue
        for sub in downloads documents torrents; do
          [ -d "$pup/$sub" ] && WATCH_DIRS="$WATCH_DIRS $pup/$sub"
        done
      done
    fi
    WATCH_DIRS=$(echo "$WATCH_DIRS" | tr ' ' '\n' | sort -u | tr '\n' ' ')
    $ECHO "[scanner] watch dirs:$WATCH_DIRS"

    scan_file() {
      local f="$1" trigger="$2"
      [ -f "$f" ] || return 0
      case "$f" in
        */quarantine/*|*/clamd.ctl|*/clamd.log|*/scanner.log|\
        */freshclam.log|*/status.json|*/freshclam.status|*.quarantine) return 0;;
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
        $ECHO "[$ts] QUARANTINE: $f -> $target ($out) trigger=$trigger" >> "${QUARANTINE_LOG}"
      fi
    }

    write_status() {
      local qn; qn=$($GREP -c '^\[' "${QUARANTINE_LOG}" 2>/dev/null || echo 0)
      local fc_status="unknown"; local fc_age=""; local fc_last=""
      if [ -f "${FRESHCLAM_STATUS}" ]; then
        fc_status=$($JQ -r '.status // "unknown"' "${FRESHCLAM_STATUS}" 2>/dev/null || echo unknown)
        fc_last=$($JQ -r '.last_attempt_iso // ""' "${FRESHCLAM_STATUS}" 2>/dev/null || echo "")
        local s; s=$($JQ -r '.db_age_seconds // -1' "${FRESHCLAM_STATUS}" 2>/dev/null || echo -1)
      fi
      local ts; ts=$($DATE -u +%FT%TZ)
      $CAT > "$STATUS" <<'JSON'
{"last_heartbeat":"$ts","quarantined_total":$qn,"watching":"$WATCH_DIRS","freshclam":{"status":"$fc_status","last_attempt":"$fc_last"}}
JSON
    }

    $ECHO '{"started":"'"$($DATE -u +%FT%TZ)"'"}' > "$STATUS"

    # inotify watch
    if [ -n "$WATCH_DIRS" ]; then
      $INOTIFYWAIT -m -r -e close_write,moved_to $WATCH_DIRS 2>>"$LOG" | \
        while read -r dir event file; do
          scan_file "$dir$file" "inotify"
        done &
      INO_PID=$!
    fi

    # Hourly full scan
    (
      while $SLEEP 3600; do
        $ECHO "[$($DATE -u +%FT%TZ)] hourly scan start" >> "$LOG"
        for d in $WATCH_DIRS; do
          $FIND "$d" -type f -size -''${MAX_MB}M 2>/dev/null | while read -r f; do
            scan_file "$f" "scheduled"
          done
        done
        $ECHO "[$($DATE -u +%FT%TZ)] hourly scan done" >> "$LOG"
      done
    ) &
    SCHED_PID=$!

    # Heartbeat
    (
      while $SLEEP 30; do write_status; done
    ) &
    HB_PID=$!

    wait $INO_PID $SCHED_PID $HB_PID
  '';

  # ---- webui (clamav-webui service) ---------------------------------
  webuiScript = pkgs.writeText "webui.py" ''
    import http.server, json, sys, os
    from urllib.parse import urlparse, parse_qs

    STATUS_FILE    = sys.argv[1]
    QUARANTINE_LOG = sys.argv[2]
    FC_STATUS_FILE = "${FRESHCLAM_STATUS}"

    def _fc():
        try:
            with open(FC_STATUS_FILE) as f:
                return json.load(f)
        except Exception:
            return {"status": "unknown"}

    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/json":
                try:
                    body = open(STATUS_FILE).read().encode()
                except Exception as e:
                    body = ('{"error":"' + str(e) + '"}').encode()
                self._send(200, "application/json", body); return
            if self.path == "/freshclam":
                self._send(200, "application/json", json.dumps(_fc()).encode()); return
            if self.path.startswith("/raw"):
                n = int(parse_qs(urlparse(self.path).query).get("lines", ["100"])[0])
                try:
                    lines = open(QUARANTINE_LOG).readlines()[-n:]
                    body = "".join(lines).encode()
                except FileNotFoundError:
                    body = b"(no events yet)"
                self._send(200, "text/plain", body); return
            try:
                body = open(STATUS_FILE).read()
            except Exception:
                body = '{"error":"no status yet"}'
            fc = _fc()
            s = fc.get("status","unknown")
            age = fc.get("db_age_seconds", -1)
            last = fc.get("last_attempt_iso","")
            age_str = f"{age//3600}h" if age >= 0 else "unknown"
            hint = ""
            if s == "critical":
                hint = "<p style='color:#c00'><b>Critical:</b> DB &gt;72 h — outbound may be blocked.</p>"
            elif s == "stale":
                hint = "<p style='color:#c80'><b>Stale:</b> DB &gt;48 h old.</p>"
            html = (
                "<!doctype html><html><head><title>ClamAV pup</title>"
                "<meta charset='utf-8'>"
                "<style>"
                "body{font-family:system-ui;margin:2rem;max-width:900px}"
                "pre{background:#111;color:#0f0;padding:1rem;border-radius:.5rem;overflow:auto}"
                ".badge{display:inline-block;padding:.25rem .75rem;border-radius:1rem;color:#fff;font-weight:600}"
                ".ok{background:#0a0}.stale{background:#c80}.critical{background:#c00}.unknown{background:#888}"
                "a{color:#08f}"
                "</style></head>"
                "<body><h1>ClamAV pup</h1>"
                "<p><a href='/json'>JSON</a> &middot; <a href='/freshclam'>freshclam</a> &middot; <a href='/raw?lines=50'>log</a></p>"
                "<h2>Signature DB</h2>"
                "<p><span class='badge "+s+"'>"+s.upper()+"</span> age:<b>"+age_str+"</b> last:<b>"+(last or "—")+"</b></p>"+hint
                "<h2>Scanner</h2><pre id='s'></pre>"
                "<script>fetch('/json').then(r=>r.text()).then(t=>{document.getElementById('s').textContent=t})</script>"
                "</body></html>"
            ).encode()
            self._send(200, "text/html; charset=utf-8", html)

        def _send(self, code, ctype, body):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def log_message(self, *a, **k): pass

    port = int(sys.argv[3]) if len(sys.argv) > 3 else 9000
    TS = getattr(http.server, "ThreadingHTTPServer", None) or http.server.HTTPServer
    with TS(("0.0.0.0", port), H) as srv:
        srv.allow_reuse_address = True
        srv.serve_forever()
  '';

in
{
  # Each attr name must match the service "name" in manifest.json
  "clamav-daemon"    = pkgs.writeScriptBin "run-clamd.sh"     '' exec ${clamdScript} '';
  "clamav-freshclam" = pkgs.writeScriptBin "run-freshclam.sh" '' exec ${freshclamScript} '';
  "clamav-scanner"   = pkgs.writeScriptBin "run-scanner.sh"   '' exec ${scannerScript} '';
  "clamav-webui"     = pkgs.writeScriptBin "run-webui.sh"     '' exec ${python}/bin/python3 ${webuiScript} ${STATUS_JSON} ${QUARANTINE_LOG} 9000 '';
}
