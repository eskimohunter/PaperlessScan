#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: .env file not found at $ENV_FILE" >&2
    echo "Copy .env.example to .env and set your scanner configuration" >&2
    exit 1
fi

set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

: "${SCANNER_DEVICE:?SCANNER_DEVICE is not set in .env}"
: "${OUTPUT_DIR:?OUTPUT_DIR is not set in .env}"

RESOLUTION="${RESOLUTION:-300}"
MODE="${MODE:-Color}"

if ! command -v scanimage &>/dev/null; then
    echo "ERROR: scanimage not found on PATH" >&2
    exit 1
fi

if ! command -v img2pdf &>/dev/null; then
    echo "ERROR: img2pdf not found on PATH" >&2
    exit 1
fi

FILENAME="scan_$(date +%Y-%m-%d_%H-%M-%S).pdf"

mkdir -p "$OUTPUT_DIR"

scanimage \
    --device "$SCANNER_DEVICE" \
    --resolution "$RESOLUTION" \
    --mode "$MODE" \
    --format=tiff \
    | img2pdf --output "$OUTPUT_DIR/$FILENAME" -

if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
    echo "ERROR: scan failed" >&2
    exit 1
fi

echo "$OUTPUT_DIR/$FILENAME"