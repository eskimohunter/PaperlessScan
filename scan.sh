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

FILENAME="scan_$(date +%Y-%m-%d_%H-%M-%S).pdf"

# Update config files with the current values from .env
cp SF2.template PaperlessScan.SF2
sed -i "s#RESOLUTION_VAR#$RESOLUTION#g" PaperlessScan.SF2
sed -i "s#TMP_SCAN_PATH_VAR#$TMP_SCAN_PATH#g" PaperlessScan.SF2
sed -i "s#BACKGROUND_COLOR_VAR#3#g" PaperlessScan.SF2

# If the file already exists, delete it so a new scan can be created
if [[ -f "${TMP_SCAN_PATH}/Scan.pdf" ]]; then
    rm -f "${TMP_SCAN_PATH}/Scan.pdf"
fi

$EPSONSCAN2 --scan $SCANNER_IP PaperlessScan.SF2

mv "${TMP_SCAN_PATH}/Scan.pdf" "${OUTPUT_DIR}/${FILENAME}"

# --- Upload Document ---
curl -s -X POST \
  -H "Authorization: Token ${API_TOKEN}" \
  -H "Accept: application/json; version=9" \
  -F "document=@${OUTPUT_DIR}/${FILENAME}" \
  "${PAPERLESS_URL}/api/documents/post_document/"