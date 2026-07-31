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

: "${SCANNER_IP:?SCANNER_IP is not set in .env}"
: "${OUTPUT_DIR:?OUTPUT_DIR is not set in .env}"
: "${EPSONSCAN2:?EPSONSCAN2 is not set in .env}"

RESOLUTION="${RESOLUTION:-300}"
MODE="${MODE:-Color}"
SOURCE="${SOURCE:-Auto}"

die() { echo "ERROR: $*" >&2; exit 1; }

for cmd in epsonscan2; do
    command -v "$cmd" &>/dev/null || die "$cmd not found on PATH"
done

scan_flatbed() {
    $EPSONSCAN2 --scan $SCANNER_IP Flatbed.SF2
}

scan_adf() {
    $EPSONSCAN2 --scan $SCANNER_IP ADF.SF2
}

# --- Configuration ---
FILENAME="scan_$(date +%Y-%m-%d_%H-%M-%S).pdf"
SCAN_PATH="/run/user/1000/doc/9333e655/PaperlessScan/Scan.pdf"

# If the file already exists, delete it so a new scan can be created
if [[ -f "${SCAN_PATH}" ]]; then
    rm -f "${SCAN_PATH}"
fi

scan_adf || scan_flatbed

mv "${SCAN_PATH}" "${OUTPUT_DIR}/${FILENAME}"

# --- Upload Document ---
curl -s -X POST \
  -H "Authorization: Token ${API_TOKEN}" \
  -H "Accept: application/json; version=9" \
  -F "document=@${OUTPUT_DIR}/${FILENAME}" \
  "${PAPERLESS_URL}/api/documents/post_document/"