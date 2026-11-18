#!/usr/bin/env bash
# Starts (or stops) PeakCut and SupoClip installed by setup.sh.
#
#   ./start.sh [all|peakcut|supoclip]   start in the background
#   ./start.sh stop                     stop everything this script started
#
# Logs go to $INSTALL_DIR/peakcut/peakcut.log and $INSTALL_DIR/supoclip/*.log.
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME}"
PEAKCUT_DIR="$INSTALL_DIR/peakcut"
SUPOCLIP_DIR="$INSTALL_DIR/supoclip"
export PATH="$HOME/.local/bin:$PATH"

wait_for() {  # wait_for <name> <url> <seconds>
  for _ in $(seq 1 "$3"); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' -m 5 "$2" || true)" != 000 ] && { echo "  $1: $2"; return; }
    sleep 1
  done
  echo "  $1: not answering yet at $2 (check its log)"
}

start_peakcut() {
  [ -d "$PEAKCUT_DIR/.venv" ] || { echo "PeakCut not set up; run ./setup.sh peakcut"; return 1; }
  cd "$PEAKCUT_DIR"
  nohup .venv/bin/python -m studio.server > peakcut.log 2>&1 &
  wait_for PeakCut http://127.0.0.1:8765/ 60
}

start_supoclip() {
  [ -d "$SUPOCLIP_DIR/backend/.venv" ] || { echo "SupoClip not set up; run ./setup.sh supoclip"; return 1; }
  if [ "$(uname -s)" = Darwin ]; then
    brew services start postgresql@16 >/dev/null || true; brew services start redis >/dev/null || true
  else
    SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO=sudo
    $SUDO service postgresql start >/dev/null 2>&1 || true
    redis-cli ping >/dev/null 2>&1 || $SUDO service redis-server start >/dev/null 2>&1 || redis-server --daemonize yes >/dev/null
  fi
  cd "$SUPOCLIP_DIR/backend"
  nohup .venv/bin/uvicorn src.main:app --host 127.0.0.1 --port 8000 > ../backend.log 2>&1 &
  nohup .venv/bin/python -m src.workers.run_workers > ../worker.log 2>&1 &
  cd "$SUPOCLIP_DIR/frontend"
  nohup pnpm exec next dev -p 3107 > ../frontend.log 2>&1 &
  wait_for "SupoClip API" http://127.0.0.1:8000/health 60
  wait_for "SupoClip website" http://127.0.0.1:3107/ 120
}

stop_all() {
  pkill -f "studio.server" || true
  pkill -f "uvicorn src.main:app" || true
  pkill -f "src.workers.run_workers" || true
  pkill -f "next dev -p 3107" || true
  echo "Stopped."
}

case "${1:-all}" in
  peakcut)  start_peakcut ;;
  supoclip) start_supoclip ;;
  all)      start_peakcut; start_supoclip ;;
  stop)     stop_all ;;
  *) echo "Usage: $0 [all|peakcut|supoclip|stop]"; exit 1 ;;
esac
