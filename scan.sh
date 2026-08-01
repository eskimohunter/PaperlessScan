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
: "${TMP_SCAN_PATH:?TMP_SCAN_PATH is not set in .env}"
: "${EPSONSCAN2:?EPSONSCAN2 is not set in .env}"

RESOLUTION="${RESOLUTION:-300}"
BACKGROUND_COLOR="${BACKGROUND_COLOR:-3}"

die() { echo "ERROR: $*" >&2; exit 1; }

SCAN_CMD="${EPSONSCAN2%% *}"
command -v "$SCAN_CMD" &>/dev/null || die "$SCAN_CMD not found on PATH"

FILENAME="scan_$(date +%Y-%m-%d_%H-%M-%S).pdf"

echo "Generating scanner settings..."
cp "$SCRIPT_DIR/SF2.template" "$SCRIPT_DIR/PaperlessScan.SF2"
sed -i "s#RESOLUTION_VAR#$RESOLUTION#g" "$SCRIPT_DIR/PaperlessScan.SF2"
sed -i "s#TMP_SCAN_PATH_VAR#$TMP_SCAN_PATH#g" "$SCRIPT_DIR/PaperlessScan.SF2"
sed -i "s#BACKGROUND_COLOR_VAR#$BACKGROUND_COLOR#g" "$SCRIPT_DIR/PaperlessScan.SF2"

if [[ -f "${TMP_SCAN_PATH}/Scan.pdf" ]]; then
    rm -f "${TMP_SCAN_PATH}/Scan.pdf"
fi

mkdir -p "$OUTPUT_DIR"

echo "Scanning..."
$EPSONSCAN2 --scan "$SCANNER_IP" "$SCRIPT_DIR/PaperlessScan.SF2"

mv "${TMP_SCAN_PATH}/Scan.pdf" "${OUTPUT_DIR}/${FILENAME}"
echo "Saved: ${OUTPUT_DIR}/${FILENAME}"

if [[ -n "${PAPERLESS_URL:-}" && -n "${API_TOKEN:-}" ]]; then
    echo "Uploading to Paperless..."
    HTTP_CODE=$(curl -sS --fail-with-body -w "%{http_code}" -o /dev/null -X POST \
      -H "Authorization: Token ${API_TOKEN}" \
      -H "Accept: application/json; version=9" \
      -F "document=@${OUTPUT_DIR}/${FILENAME}" \
      "${PAPERLESS_URL}/api/documents/post_document/")
    if [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]; then
        echo "Upload complete (HTTP $HTTP_CODE)"
    else
        echo "Upload failed (HTTP $HTTP_CODE)"
        exit 1
    fi
else
    echo "Paperless upload skipped (PAPERLESS_URL or API_TOKEN not set)"
fi

rm -f "$SCRIPT_DIR/PaperlessScan.SF2"