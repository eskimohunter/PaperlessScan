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

: "${SCANNER_MODEL:?SCANNER_MODEL is not set in .env}"
: "${OUTPUT_DIR:?OUTPUT_DIR is not set in .env}"
: "${TMP_SCAN_PATH:?TMP_SCAN_PATH is not set in .env}"
: "${EPSONSCAN2:?EPSONSCAN2 is not set in .env}"

mkdir -p "$OUTPUT_DIR"
mkdir -p "$TMP_SCAN_PATH"

RESOLUTION="${RESOLUTION:-300}"
BACKGROUND_COLOR="${BACKGROUND_COLOR:-3}"

die() { echo "ERROR: $*" >&2; exit 1; }

# Resolve the scanner's current IPv4 address from its mDNS advertisement.
# SCANNER_MODEL is matched against the advertised name/model or driver ModelID;
# SCANNER_MAC optionally picks one of several same-model scanners.
discover_scanner() {
    local model="$1" mac="${2:-}"
    local model_lc="${model,,}"
    local norm_mac=""
    if [[ -n "$mac" ]]; then
        norm_mac="${mac//[:\-.]/}"
        norm_mac="${norm_mac,,}"
    fi

    command -v avahi-browse >/dev/null 2>&1 ||
        die "avahi-browse not found (install avahi-utils or use the Nix dev shell)"

    # Driver model IDs (e.g. ES025A) keyed by current IP, for matching.
    local -A model_by_ip=()
    local ip model_id
    while read -r ip model_id; do
        [[ -n "$ip" && -n "$model_id" ]] && model_by_ip["$ip"]="$model_id"
    done < <(
        $EPSONSCAN2 --list 2>/dev/null |
            awk '
                /^ipAdder[[:space:]]*:/ { ip=$0; sub(/^ipAdder[[:space:]]*:[[:space:]]*/, "", ip) }
                /^ModelID[[:space:]]*:/ { m=$0; sub(/^ModelID[[:space:]]*:/, "", m); gsub(/[[:space:]]/, "", m); if (ip != "") print ip "\t" m }
            '
    )

    local -a matches=() labels=() seen_ips=() seen_labels=()
    local event iface proto name stype domain host addr port txt uuid uuid_tail label
    local existing

    # shellcheck disable=SC2034  # only event/proto/name/addr/txt are used
    while IFS=';' read -r event iface proto name stype domain host addr port txt; do
        [[ "$event" == "=" && "$proto" == "IPv4" && -n "$addr" ]] || continue
        name="${name//\\032/ }"
        uuid=$(sed -n 's/.*UUID=\([^" ]*\).*/\1/p' <<<"$txt" | tr '[:upper:]' '[:lower:]')
        uuid_tail="${uuid: -12}"
        label="$name ($addr"
        if [[ "$uuid_tail" =~ ^[0-9a-f]{12}$ ]]; then
            label+=", MAC ${uuid_tail:0:2}:${uuid_tail:2:2}:${uuid_tail:4:2}:${uuid_tail:6:2}:${uuid_tail:8:2}:${uuid_tail:10:2}"
        fi
        label+=")"

        # Record every discovered scanner for error messages, deduplicated by IP.
        for existing in "${seen_ips[@]:-}"; do
            [[ "$existing" == "$addr" ]] && continue 2
        done
        seen_ips+=("$addr")
        seen_labels+=("$label")

        local matched=0
        if [[ "${name,,} ${txt,,}" == *"$model_lc"* ]]; then
            matched=1
        elif [[ -n "${model_by_ip[$addr]:-}" && "${model_by_ip[$addr],,}" == *"$model_lc"* ]]; then
            matched=1
        fi
        [[ "$matched" -eq 1 ]] || continue

        if [[ -n "$norm_mac" && "$uuid_tail" != "$norm_mac" ]]; then
            continue
        fi

        matches+=("$addr")
        labels+=("$label")
    done < <(avahi-browse -r -p -t _scanner._tcp 2>/dev/null)

    if [[ ${#matches[@]} -eq 0 ]]; then
        echo "ERROR: no scanner matching model '$model'${mac:+ and MAC $mac} found." >&2
        if [[ ${#seen_ips[@]} -eq 0 ]]; then
            echo "No scanners are advertising _scanner._tcp; is avahi-daemon running?" >&2
        else
            echo "Discovered scanners:" >&2
            printf '  %s\n' "${seen_labels[@]}" >&2
        fi
        exit 1
    fi

    if [[ ${#matches[@]} -gt 1 ]]; then
        echo "ERROR: multiple scanners match model '$model'; set SCANNER_MAC to one of:" >&2
        printf '  %s\n' "${labels[@]}" >&2
        exit 1
    fi

    echo "Using scanner: ${labels[0]}" >&2
    printf '%s\n' "${matches[0]}"
}

SCAN_CMD="${EPSONSCAN2%% *}"
command -v "$SCAN_CMD" &>/dev/null || die "$SCAN_CMD not found on PATH"

SCANNER_IP="$(discover_scanner "$SCANNER_MODEL" "${SCANNER_MAC:-}")"

FILENAME="scan_$(date +%Y-%m-%d_%H-%M-%S).pdf"

echo "Generating scanner settings..."
cp "$SCRIPT_DIR/SF2.template" "$SCRIPT_DIR/PaperlessScan.SF2"
sed -i "s#RESOLUTION_VAR#$RESOLUTION#g" "$SCRIPT_DIR/PaperlessScan.SF2"
sed -i "s#TMP_SCAN_PATH_VAR#$TMP_SCAN_PATH#g" "$SCRIPT_DIR/PaperlessScan.SF2"
sed -i "s#BACKGROUND_COLOR_VAR#$BACKGROUND_COLOR#g" "$SCRIPT_DIR/PaperlessScan.SF2"

if [[ -f "${TMP_SCAN_PATH}/Scan.pdf" ]]; then
    rm -f "${TMP_SCAN_PATH}/Scan.pdf"
fi

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