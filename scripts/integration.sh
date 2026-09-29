#!/bin/zsh
# End-to-end tests against a throw-away local SFTP server (`rclone serve sftp` on 127.0.0.1), no real data or
# account needed. Runs `--selftest` (browser + transfers) and the backup safety scenarios from CONTRIBUTING.md.
#   scripts/build.sh && scripts/integration.sh
# The same tests against this Mac's own OpenSSH server (System Settings → Sharing → Remote Login), with a key
# that is in ~/.ssh/authorized_keys. Everything happens in a throw-away folder in your home folder:
#   OPENSSH_KEY=path/to/key scripts/integration.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP_EXE="$PWD/build/Burrow.app/Contents/MacOS/Burrow"
RCLONE="$PWD/build/Burrow.app/Contents/Resources/rclone"
[[ -x "$APP_EXE" ]] || { echo "Run scripts/build.sh first"; exit 1; }

WORK="$(mktemp -d)"
export CFFIXED_USER_HOME="$WORK/home"     # config, keys, known_hosts, logs, LaunchAgent label all separate
export BURROW_QUIET=1                        # no notifications from test runs
if [[ -n "${OPENSSH_KEY:-}" ]]; then
  SERVER_ROOT="$(mktemp -d "$HOME/_burrow_it_XXXXXXXX")"  # exclusive: never reuse a user's folder
  TEST_DIR="${SERVER_ROOT:t}"
  REMOTE_BASE="$TEST_DIR/"
else
  SERVER_ROOT="$WORK/server"              # what the SFTP server serves as the login folder
  REMOTE_BASE=""
fi
SRC="$WORK/src"                           # the "local folder" being backed up
SUPPORT="$CFFIXED_USER_HOME/Library/Application Support/Burrow"
mkdir -p "$CFFIXED_USER_HOME/.ssh" "$SERVER_ROOT" "$SRC" "$SUPPORT"
SERVER_PID=""
cleanup() {
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
  [[ -n "${TEST_DIR:-}" ]] && rm -rf -- "$SERVER_ROOT"
  rm -rf "$WORK"
}
trap cleanup EXIT

FAILED=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILED=$((FAILED + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi }

# --- server ---
if [[ -n "${OPENSSH_KEY:-}" ]]; then
  echo "== server: OpenSSH on this Mac (Remote Login)"
  KEY="$OPENSSH_KEY"; PORT=22; SFTP_USER="$USER"
  mkdir -p "$SERVER_ROOT"
  # It's this Mac's own server, so trusting what it presents is safe here.
  # All key types, like the app's fingerprint confirmation: rclone may negotiate any of them.
  ssh-keyscan -t ed25519,ecdsa,rsa 127.0.0.1 2>/dev/null > "$CFFIXED_USER_HOME/.ssh/known_hosts"
else
  echo "== server: rclone serve sftp"
  KEY="$CFFIXED_USER_HOME/.ssh/id_ed25519"; SFTP_USER="test"
  ssh-keygen -q -t ed25519 -N "" -f "$KEY"
  ssh-keygen -q -t ed25519 -N "" -f "$WORK/hostkey"
  PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
  "$RCLONE" serve sftp "$SERVER_ROOT" --addr "127.0.0.1:$PORT" --key "$WORK/hostkey" \
    --authorized-keys "$KEY.pub" --user test --bwlimit 20M --log-file "$WORK/server.log" &
  SERVER_PID=$!
  for _ in {1..50}; do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.2; done
  # Trust exactly the key we generated (what the fingerprint confirmation does in the app).
  echo "[127.0.0.1]:$PORT $(cut -d' ' -f1,2 "$WORK/hostkey.pub")" > "$CFFIXED_USER_HOME/.ssh/known_hosts"
fi

# --- browser + transfers ---
echo "== selftest"
if "$APP_EXE" --selftest 127.0.0.1 "$PORT" "$SFTP_USER" "$KEY"; then pass "selftest"; else fail "selftest"; fi

# --- backup scenarios ---
echo "== backup"
cat > "$SUPPORT/config.json" <<EOF
{"host":"127.0.0.1","port":$PORT,"user":"$SFTP_USER","keyFile":"$KEY","remoteShell":false,
 "localPath":"$SRC","remotePath":"${REMOTE_BASE}dst","versionsPath":"${REMOTE_BASE}_versions","scheduleEnabled":false,
 "maxDelete":300,"minFileRatio":0.8,"retentionDays":90}
EOF
backup() { "$APP_EXE" --run --trigger=manual >/dev/null 2>&1; }
last_result() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["runs"][0]["result"])' "$SUPPORT/status.json"; }
versions() { find "$SERVER_ROOT/_versions" -type f -name "$1" 2>/dev/null | head -1; }

mkdir -p "$SRC/sub"
echo v1 > "$SRC/a.txt"; echo keep > "$SRC/sub/b.txt"
for i in {1..8}; do echo "$i" > "$SRC/f$i.txt"; done
check "first backup succeeds" 'backup && [[ "$(last_result)" == ok ]]'
check "files uploaded" '[[ "$(cat "$SERVER_ROOT/dst/a.txt")" == v1 && -f "$SERVER_ROOT/dst/sub/b.txt" ]]'

"$APP_EXE" --dry-run --trigger=manual >/dev/null 2>&1 || true
echo "version 2" > "$SRC/a.txt"   # different size: same-second, same-size edits look unchanged without checksums
"$APP_EXE" --dry-run --trigger=manual >/dev/null 2>&1 || true
check "preview changes nothing" '[[ "$(cat "$SERVER_ROOT/dst/a.txt")" == v1 ]]'

rm "$SRC/sub/b.txt"
check "second backup succeeds" 'backup && [[ "$(last_result)" == ok ]]'
check "changed file uploaded" '[[ "$(cat "$SERVER_ROOT/dst/a.txt")" == "version 2" ]]'
check "old version kept in versions folder" '[[ -n "$(versions a.txt)" && "$(cat "$(versions a.txt)")" == v1 ]]'
check "deleted file moved to versions folder" '[[ ! -e "$SERVER_ROOT/dst/sub/b.txt" && -n "$(versions b.txt)" ]]'

# A failed rclone run must not remove an unrelated server file merely because its name resembles a temp file.
echo keep > "$SERVER_ROOT/dst/manual.deadbeef.partial"
echo unreadable > "$SRC/unreadable.txt"
chmod 000 "$SRC/unreadable.txt"
check "unreadable source makes backup fail" '! backup && [[ "$(last_result)" == error ]]'
check "failed backup preserves remote partial-named file" '[[ "$(cat "$SERVER_ROOT/dst/manual.deadbeef.partial")" == keep ]]'
chmod 600 "$SRC/unreadable.txt"
rm "$SRC/unreadable.txt"

rm "$SRC"/f{1..6}.txt
check "safety brake blocks a large drop" '! backup && [[ "$(last_result)" == blocked ]]'
check "blocked run changed nothing" '[[ -f "$SERVER_ROOT/dst/f1.txt" ]]'
touch "$SUPPORT/force-next"
check "run anyway succeeds" 'backup && [[ "$(last_result)" == ok && ! -e "$SERVER_ROOT/dst/f1.txt" && -n "$(versions f1.txt)" ]]'

NFD=$(python3 -c 'import unicodedata; print(unicodedata.normalize("NFD", "Izvještaj.txt"))')
echo nfd > "$SRC/$NFD"
check "NFD name backed up" 'backup && [[ "$(last_result)" == ok ]]'
check "server name is NFC" 'python3 -c "import os,sys,unicodedata; n=[f for f in os.listdir(sys.argv[1]) if f.startswith(\"Izvje\")]; sys.exit(0 if n and all(f == unicodedata.normalize(\"NFC\", f) for f in n) and len(n) == 1 else 1)" "$SERVER_ROOT/dst"'

rm -rf "$SRC"/*
check "empty source is refused" '! backup && [[ "$(last_result)" == blocked && -f "$SERVER_ROOT/dst/a.txt" ]]'

echo
if (( FAILED == 0 )); then echo "INTEGRATION: ALL PASSED"; else echo "INTEGRATION: $FAILED FAILED"; exit 1; fi
