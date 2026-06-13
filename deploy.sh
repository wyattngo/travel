#!/usr/bin/env bash
# One-command deploy for ToursTravel Kenya.
# Builds the self-contained image and starts app + database.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f .env.docker ]; then
    echo "✗ .env.docker not found. Copy and edit it before deploying." >&2
    exit 1
fi

echo "🚀 Building and starting containers…"
docker compose up -d --build

echo
docker compose ps
PORT="$(grep -E '^APP_PORT=' .env.docker | cut -d= -f2 | tr -d '[:space:]')"
echo
echo "✅ Deployed. App available on http://localhost:${PORT:-8000}"
echo "   Logs:  docker compose logs -f app"
echo "   Stop:  docker compose down"
