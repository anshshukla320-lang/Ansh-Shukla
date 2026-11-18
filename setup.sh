#!/usr/bin/env bash
# Sets up PeakCut and SupoClip on Linux or macOS.
#
#   ./setup.sh all              both apps
#   ./setup.sh peakcut          PeakCut only
#   ./setup.sh supoclip         SupoClip, run directly (Postgres + Redis on this machine)
#   ./setup.sh supoclip-docker  SupoClip with Docker Compose instead
#
# Apps are installed into $INSTALL_DIR (default: your home folder) as
# peakcut/ and supoclip/. Running it again is safe: it updates and re-checks.
# Start them afterwards with ./start.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

INSTALL_DIR="${INSTALL_DIR:-$HOME}"
PEAKCUT_DIR="$INSTALL_DIR/peakcut"
SUPOCLIP_DIR="$INSTALL_DIR/supoclip"
PEAKCUT_REPO="https://github.com/haziqahmedqasmi/PeakCut"
SUPOCLIP_REPO="https://github.com/FujiwaraChoki/supoclip"
DB_USER=supoclip DB_PASS=supoclip_password DB_NAME=supoclip

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m!! %s\033[0m\n' "$*"; }
die()  { printf '\033[31mxx %s\033[0m\n' "$*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

SUDO=""; [ "$(id -u)" -ne 0 ] && have sudo && SUDO="sudo"
OS="$(uname -s)"

install_pkgs() {  # install_pkgs <apt names...> -- <brew names...>
  local apt=() brew=() side=apt
  for p in "$@"; do [ "$p" = "--" ] && { side=brew; continue; }; [ $side = apt ] && apt+=("$p") || brew+=("$p"); done
  if [ "$OS" = Darwin ]; then
    have brew || die "Install Homebrew first: https://brew.sh"
    brew install "${brew[@]}"
  elif have apt-get; then
    $SUDO apt-get update -q && $SUDO apt-get install -y -q "${apt[@]}"
  else
    die "Please install these yourself, then run again: ${apt[*]}"
  fi
}

clone_or_update() {  # clone_or_update <url> <dir>
  if [ -d "$2/.git" ]; then git -C "$2" pull --ff-only || warn "Could not update $2; using what is there"
  else git clone "$1" "$2"; fi
}

ensure_uv() {
  have uv && return
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
}

rand_hex() { openssl rand -hex 32; }

# ---------------------------------------------------------------- PeakCut
setup_peakcut() {
  say "PeakCut -> $PEAKCUT_DIR"
  have git    || install_pkgs git -- git
  have ffmpeg || install_pkgs ffmpeg -- ffmpeg
  ensure_uv
  clone_or_update "$PEAKCUT_REPO" "$PEAKCUT_DIR"
  cd "$PEAKCUT_DIR"
  [ -d .venv ] || uv venv -q .venv -p ">=3.10"
  VIRTUAL_ENV=.venv uv pip install -q -r requirements.txt
  [ -f .env ] || cp .env.example .env
  say "Downloading PeakCut's speech model (about 480 MB, once)"
  .venv/bin/python -m studio.fetch_model || warn "Model download failed; PeakCut will retry on first start"
  echo "PeakCut ready. Add your AI key later in the dashboard: Settings, AI."
}

# --------------------------------------------------------------- SupoClip
supoclip_keys_hint() {
  cat <<EOF

SupoClip needs two keys before it can clip:
  ASSEMBLY_AI_API_KEY  (speech to text, https://www.assemblyai.com)
  one AI key, e.g. GOOGLE_API_KEY with LLM=google-gla:gemini-3-flash-preview
Put them in: $1
EOF
}

setup_supoclip_docker() {
  say "SupoClip (Docker) -> $SUPOCLIP_DIR"
  have docker || die "Install Docker first: https://docs.docker.com/get-docker/"
  clone_or_update "$SUPOCLIP_REPO" "$SUPOCLIP_DIR"
  cd "$SUPOCLIP_DIR"
  if [ ! -f .env ]; then
    cp .env.example .env
    { echo; echo "# Added by setup.sh"
      echo "BACKEND_AUTH_SECRET=$(rand_hex)"
      echo "BETTER_AUTH_SECRET=$(rand_hex)"
      echo "APP_SETTINGS_ENCRYPTION_KEY=$(openssl rand -base64 32)"
      echo "BACKEND_CPU_ONLY=true"; } >> .env
  fi
  supoclip_keys_hint "$SUPOCLIP_DIR/.env"
  echo "Then run:  cd $SUPOCLIP_DIR && docker compose up -d --build"
  echo "Open http://localhost:3107"
}

psql_app() { PGOPTIONS="-c client_min_messages=warning" PGPASSWORD=$DB_PASS psql -h 127.0.0.1 -U $DB_USER -d $DB_NAME -v ON_ERROR_STOP=1 -q "$@"; }

start_postgres_redis() {
  if [ "$OS" = Darwin ]; then
    brew services start postgresql@16 >/dev/null || true
    brew services start redis >/dev/null || true
  else
    $SUDO service postgresql start >/dev/null 2>&1 || true
    $SUDO service redis-server start >/dev/null 2>&1 || redis-server --daemonize yes >/dev/null
  fi
  for _ in $(seq 1 20); do pg_isready -h 127.0.0.1 -q && break; sleep 1; done
  pg_isready -h 127.0.0.1 -q || die "PostgreSQL did not start"
}

pg_admin() {  # run SQL as the Postgres superuser
  if [ "$OS" = Darwin ]; then psql -d postgres -tAc "$1"
  else (cd /tmp && $SUDO -u postgres psql -tAc "$1" 2>/dev/null || su postgres -c "psql -tAc \"$1\""); fi
}

setup_supoclip_db() {
  say "SupoClip database"
  [ "$(pg_admin "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'")" = 1 ] ||
    pg_admin "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS' SUPERUSER;"
  [ "$(pg_admin "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'")" = 1 ] ||
    pg_admin "CREATE DATABASE $DB_NAME OWNER $DB_USER;"

  if [ "$(psql_app -tAc "SELECT to_regclass('public.users') IS NOT NULL")" != t ]; then
    echo "Loading init.sql"; psql_app -f init.sql >/dev/null
  fi
  # The repo has no runner for these; Docker deployments apply them by hand.
  # Each file is written to be safe to apply again.
  for f in backend/src/migrations/sql/*.sql; do
    psql_app -f "$f" >/dev/null || die "Migration failed: $f"
  done
  # One frontend (Prisma) change that init.sql and the backend migrations lack.
  if [ "$(psql_app -tAc "SELECT to_regclass('public.stripe_account_migrations') IS NOT NULL")" != t ]; then
    psql_app -f frontend/prisma/migrations/20261106150000_stripe_account_routing/migration.sql >/dev/null
  fi
  local missing
  missing=$(cd frontend && pnpm exec prisma migrate diff --from-url "postgresql://$DB_USER:$DB_PASS@127.0.0.1:5432/$DB_NAME" \
    --to-schema-datamodel prisma/schema.prisma --script 2>/dev/null | grep -cE "CREATE TABLE|ADD COLUMN" || true)
  [ "${missing:-0}" = 0 ] || warn "Database is missing $missing table/column changes the website expects (newer SupoClip?). See frontend/prisma/migrations."
}

setup_supoclip() {
  say "SupoClip -> $SUPOCLIP_DIR"
  local need_apt=() need_brew=()
  have git    || { need_apt+=(git); need_brew+=(git); }
  have ffmpeg || { need_apt+=(ffmpeg); need_brew+=(ffmpeg); }
  have redis-server || { need_apt+=(redis-server); need_brew+=(redis); }
  have tesseract || { need_apt+=(tesseract-ocr tesseract-ocr-eng); need_brew+=(tesseract); }
  have pg_isready && { have pg_ctl || ls /usr/lib/postgresql/*/bin/postgres >/dev/null 2>&1 || [ "$OS" = Darwin ]; } \
    || { need_apt+=(postgresql); need_brew+=(postgresql@16); }
  have openssl || { need_apt+=(openssl); need_brew+=(openssl); }
  [ ${#need_apt[@]} -eq 0 ] || install_pkgs "${need_apt[@]}" -- "${need_brew[@]}"
  [ "$OS" = Darwin ] && export PATH="$(brew --prefix)/opt/postgresql@16/bin:$PATH"
  have node || die "Install Node.js 20 or newer first: https://nodejs.org"
  have pnpm || { corepack enable 2>/dev/null && corepack prepare pnpm@latest --activate; } || npm install -g pnpm
  ensure_uv

  clone_or_update "$SUPOCLIP_REPO" "$SUPOCLIP_DIR"
  cd "$SUPOCLIP_DIR"

  say "Backend packages"
  (cd backend && { uv sync --frozen --extra cpu || { warn "CPU PyTorch not reachable; installing without it (only needed for local Whisper)"; uv sync --frozen; }; })
  say "Website packages"
  (cd frontend && pnpm install --frozen-lockfile)

  start_postgres_redis
  setup_supoclip_db

  # Shared secrets must match between backend and website; keep existing ones.
  local bas enc
  bas=$(grep -s '^BACKEND_AUTH_SECRET=' backend/.env | cut -d= -f2- || true); bas=${bas:-$(rand_hex)}
  enc=$(grep -s '^APP_SETTINGS_ENCRYPTION_KEY=' backend/.env | cut -d= -f2- || true); enc=${enc:-$(openssl rand -base64 32)}
  mkdir -p backend/uploads
  if [ ! -f backend/.env ]; then
    cat > backend/.env <<EOF
PYTHONPATH=.
DATABASE_URL=postgresql+asyncpg://$DB_USER:$DB_PASS@127.0.0.1:5432/$DB_NAME
REDIS_HOST=127.0.0.1
REDIS_PORT=6379
TEMP_DIR=$SUPOCLIP_DIR/backend/uploads
SELF_HOST=true
BACKEND_AUTH_SECRET=$bas
APP_SETTINGS_ENCRYPTION_KEY=$enc
CORS_ORIGINS=http://localhost:3107
TRANSCRIPTION_PROVIDER=assemblyai
# Fill these in:
ASSEMBLY_AI_API_KEY=
LLM=google-gla:gemini-3-flash-preview
GOOGLE_API_KEY=
EOF
  fi
  if [ ! -f frontend/.env.local ]; then
    cat > frontend/.env.local <<EOF
NEXT_PUBLIC_API_URL=http://localhost:8000
BACKEND_INTERNAL_URL=http://127.0.0.1:8000
NEXT_PUBLIC_SELF_HOST=true
NEXT_PUBLIC_APP_URL=http://localhost:3107
BACKEND_AUTH_SECRET=$bas
APP_SETTINGS_ENCRYPTION_KEY=$enc
DATABASE_URL=postgresql://$DB_USER:$DB_PASS@127.0.0.1:5432/$DB_NAME
BETTER_AUTH_SECRET=$(rand_hex)
BETTER_AUTH_URL=http://localhost:3107
EOF
  fi
  supoclip_keys_hint "$SUPOCLIP_DIR/backend/.env"
}

case "${1:-all}" in
  peakcut)         setup_peakcut ;;
  supoclip)        setup_supoclip ;;
  supoclip-docker) setup_supoclip_docker ;;
  all)             setup_peakcut; setup_supoclip ;;
  *) die "Usage: $0 [all|peakcut|supoclip|supoclip-docker]" ;;
esac
say "Done. Start with: $SCRIPT_DIR/start.sh ${1:-all}"
