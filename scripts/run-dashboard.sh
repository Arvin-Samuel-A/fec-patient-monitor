#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT/dashboard"

if [ ! -f package-lock.json ]; then
  npm install
fi

npm run dev 
