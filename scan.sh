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

# next = long press (start/append session); finish = short press (one-shot or finalize).
MODE="${1:-finish}"
SESSION_TIMEOUT="${SESSION_TIMEOUT:-600}"
[[ "$SESSION_TIMEOUT" =~ ^[0-9]+$ ]] || {
    echo "ERROR: SESSION_TIMEOUT must be a number of seconds" >&2
    exit 1
}

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
command -v qpdf &>/dev/null || die "qpdf not found (install it or use the Nix dev shell)"

mkdir -p "$OUTPUT_DIR"
mkdir -p "$TMP_SCAN_PATH"

RESOLUTION="${RESOLUTION:-300}"
BACKGROUND_COLOR="${BACKGROUND_COLOR:-3}"

# Session state lives on tmpfs and is discarded after SESSION_TIMEOUT of inactivity.
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if [[ ! -d "$RUNTIME_DIR" || ! -w "$RUNTIME_DIR" ]]; then
    RUNTIME_DIR="${TMPDIR:-/tmp}"
fi
SESSION_DIR="$RUNTIME_DIR/paperlessscan-session"
SESSION_STATE="$SESSION_DIR/state"
started_at=0
last_activity=0
batch_count=0

# Remove the generated settings file on any exit, including failures.
trap 'rm -f "$SCRIPT_DIR/PaperlessScan.SF2"' EXIT

SCANNER_IP="$(discover_scanner "$SCANNER_MODEL" "${SCANNER_MAC:-}")"

scan_batch() {
    local out="$1"
    echo "Generating scanner settings..."
    cp "$SCRIPT_DIR/SF2.template" "$SCRIPT_DIR/PaperlessScan.SF2"
    sed -i "s#RESOLUTION_VAR#$RESOLUTION#g" "$SCRIPT_DIR/PaperlessScan.SF2"
    sed -i "s#TMP_SCAN_PATH_VAR#$TMP_SCAN_PATH#g" "$SCRIPT_DIR/PaperlessScan.SF2"
    sed -i "s#BACKGROUND_COLOR_VAR#$BACKGROUND_COLOR#g" "$SCRIPT_DIR/PaperlessScan.SF2"

    rm -f "${TMP_SCAN_PATH}/Scan.pdf"

    echo "Scanning..."
    if ! $EPSONSCAN2 --scan "$SCANNER_IP" "$SCRIPT_DIR/PaperlessScan.SF2"; then
        rm -f "${TMP_SCAN_PATH}/Scan.pdf" "$out"
        return 1
    fi
    if [[ ! -f "${TMP_SCAN_PATH}/Scan.pdf" ]]; then
        echo "ERROR: scanner produced no output" >&2
        return 1
    fi
    mv "${TMP_SCAN_PATH}/Scan.pdf" "$out"
    echo "Saved: $out"
}

upload_pdf() {
    local file="$1"
    if [[ -z "${PAPERLESS_URL:-}" || -z "${API_TOKEN:-}" ]]; then
        echo "Paperless upload skipped (PAPERLESS_URL or API_TOKEN not set)"
        return 0
    fi
    echo "Uploading to Paperless..."
    local http
    if ! http=$(curl -sS -w "%{http_code}" -o /dev/null -X POST \
        -H "Authorization: Token ${API_TOKEN}" \
        -H "Accept: application/json; version=9" \
        -F "document=@${file}" \
        "${PAPERLESS_URL}/api/documents/post_document/"); then
        echo "ERROR: Paperless upload request failed" >&2
        return 1
    fi
    if [[ "$http" -ge 200 && "$http" -lt 300 ]]; then
        echo "Upload complete (HTTP $http)"
        return 0
    fi
    echo "ERROR: Paperless upload failed (HTTP $http)" >&2
    return 1
}

session_reset() {
    rm -rf "$SESSION_DIR"
}

session_expire_if_needed() {
    if [[ ! -f "$SESSION_STATE" ]]; then
        [[ -d "$SESSION_DIR" ]] && session_reset
        return 0
    fi
    # shellcheck source=/dev/null
    source "$SESSION_STATE"
    local now
    now=$(date +%s)
    if ((now - last_activity >= SESSION_TIMEOUT)); then
        echo "Session expired after ${SESSION_TIMEOUT}s of inactivity; discarding." >&2
        session_reset
    fi
}

session_read() {
    [[ -f "$SESSION_STATE" ]] || return 1
    # shellcheck source=/dev/null
    source "$SESSION_STATE"
}

session_write() {
    local started="$1" last="$2" count="$3"
    mkdir -p "$SESSION_DIR"
    printf 'started_at=%s\nlast_activity=%s\nbatch_count=%s\n' \
        "$started" "$last" "$count" >"$SESSION_STATE.tmp"
    mv "$SESSION_STATE.tmp" "$SESSION_STATE"
}

session_merge() {
    local out="$1" count="$2"
    local i n1 n2
    case "$count" in
        1)
            cp "$SESSION_DIR/batch1.pdf" "$out"
            ;;
        2)
            n1=$(qpdf --show-npages "$SESSION_DIR/batch1.pdf")
            n2=$(qpdf --show-npages "$SESSION_DIR/batch2.pdf")
            if [[ "$n1" -ne "$n2" ]]; then
                echo "ERROR: duplex batches have different page counts ($n1 vs $n2)." >&2
                return 1
            fi
            local args=(--empty --pages)
            for ((i = 1; i <= n1; i++)); do
                args+=("$SESSION_DIR/batch1.pdf" "$i" "$SESSION_DIR/batch2.pdf" "$((n1 - i + 1))")
            done
            args+=(-- "$out")
            qpdf "${args[@]}"
            ;;
        *)
            local files=()
            for ((i = 1; i <= count; i++)); do
                files+=("$SESSION_DIR/batch$i.pdf")
            done
            qpdf --empty --pages "${files[@]}" -- "$out"
            ;;
    esac
}

session_add() {
    session_expire_if_needed
    local started last count
    if session_read; then
        started="$started_at"
        last="$last_activity"
        count="$batch_count"
    else
        started=$(date +%s)
        last="$started"
        count=0
    fi
    local next=$((count + 1))
    local out="$SESSION_DIR/batch$next.pdf"
    mkdir -p "$SESSION_DIR"
    if ! scan_batch "$out"; then
        echo "ERROR: scan failed; session unchanged." >&2
        return 1
    fi
    session_write "$started" "$(date +%s)" "$next"
    echo "Session batch $next added ($(qpdf --show-npages "$out") page(s)). Long press to add more, short press to finish."
}

session_finish() {
    session_expire_if_needed
    local started last count
    if ! session_read; then
        # No open session: one-shot scan + upload.
        local filename out
        filename="scan_$(date +%Y-%m-%d_%H-%M-%S).pdf"
        out="$OUTPUT_DIR/$filename"
        scan_batch "$out" || die "scan failed"
        upload_pdf "$out" || die "upload failed; saved at $out"
        return 0
    fi

    started="$started_at"
    last="$last_activity"
    count="$batch_count"
    local next=$((count + 1))
    local final="$SESSION_DIR/batch$next.pdf"
    if ! scan_batch "$final"; then
        echo "ERROR: final scan failed; session unchanged." >&2
        return 1
    fi
    count="$next"

    local filename out
    filename="scan_$(date -d "@$started" +%Y-%m-%d_%H-%M-%S).pdf"
    out="$OUTPUT_DIR/$filename"
    if ! session_merge "$out" "$count"; then
        session_reset
        die "merge failed; session discarded"
    fi
    echo "Saved: $out"

    if upload_pdf "$out"; then
        session_reset
    else
        session_reset
        die "upload failed; merged PDF kept at $out"
    fi
}

case "$MODE" in
    next) session_add ;;
    finish) session_finish ;;
    *) die "unknown mode '$MODE' (expected 'next' or 'finish')" ;;
esac
