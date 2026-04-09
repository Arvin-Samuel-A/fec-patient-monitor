#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
BUILD_DIR="$ROOT/build"
ZIP_PATH="$ROOT/notifier.zip"
VENV_DIR="$ROOT/.pack-venv"

rm -rf "$BUILD_DIR" "$ZIP_PATH" "$VENV_DIR"
mkdir -p "$BUILD_DIR"

python3 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"
python -m pip install --upgrade pip >/dev/null
python -m pip install -r "$ROOT/requirements.txt" -t "$BUILD_DIR"

cp "$ROOT/lambda_function.py" "$BUILD_DIR/lambda_function.py"

(
  cd "$BUILD_DIR"
  zip -rq "$ZIP_PATH" .
)

deactivate
rm -rf "$VENV_DIR"

echo "Created deployment zip: $ZIP_PATH"
echo "Set Lambda handler to: lambda_function.lambda_handler"
