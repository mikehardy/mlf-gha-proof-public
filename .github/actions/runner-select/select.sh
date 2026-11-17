#!/usr/bin/env bash
set -euo pipefail

emit() {
  local runs_on="$1"
  local pool="$2"
  local reason="$3"
  printf 'runs-on=%s\n' "$runs_on"
  printf 'pool=%s\n' "$pool"
  printf 'reason=%s\n' "$reason"
}

fail_usage() {
  echo "runner-select: $*" >&2
  exit 2
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail_usage "missing required command: $1"
}

parse_label_input() {
  local raw="$1"
  if [[ -z "$raw" ]]; then
    return 1
  fi
  if printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
    printf '%s' "$raw" | jq -ec .
    return 0
  fi
  if [[ "$raw" == *[![:alnum:]_.-]* || "$raw" == *'://'* ]]; then
    return 1
  fi
  jq -nc --arg s "$raw" '$s'
}

read_default_json() {
  local parsed
  if ! parsed="$(parse_label_input "${INPUT_DEFAULT_RUNS_ON:-}")"; then
    if [[ -z "${INPUT_DEFAULT_RUNS_ON:-}" ]]; then
      echo 'runner-select: default-runs-on is empty' >&2
      exit 1
    fi
    echo 'runner-select: invalid default-runs-on' >&2
    exit 1
  fi
  DEFAULT_JSON="$parsed"
}

read_overflow_json() {
  local parsed
  if ! parsed="$(parse_label_input "${INPUT_OVERFLOW_RUNS_ON:-}")"; then
    echo 'runner-select: invalid overflow-runs-on' >&2
    exit 1
  fi
  OVERFLOW_JSON="$parsed"
}

placement_body_valid() {
  local body="$1"
  printf '%s' "$body" | jq -e '
    (.hosted.total.free | type) == "number"
    and (.hosted.macos.free | type) == "number"
    and (.overflow.headroom | type) == "number"
  ' >/dev/null 2>&1
}

require_cmd jq
require_cmd curl

read_default_json
read_overflow_json

MODE="${INPUT_MODE:-}"
CLASS="${INPUT_CLASS:-}"

case "$MODE" in
  off)
    emit "$DEFAULT_JSON" default off
    exit 0
    ;;
  fixed | github-app)
    ;;
  '')
    emit "$DEFAULT_JSON" default error
    exit 0
    ;;
  *)
    emit "$DEFAULT_JSON" default error
    exit 0
    ;;
esac

case "$CLASS" in
  macos | other) ;;
  *)
    emit "$DEFAULT_JSON" default error
    exit 0
    ;;
esac

URL="${INPUT_PLACEMENT_URL:-}"
TOKEN="${INPUT_PLACEMENT_TOKEN:-}"
if [[ -z "$URL" || -z "$TOKEN" ]]; then
  emit "$DEFAULT_JSON" default error
  exit 0
fi

CA_PEM="${INPUT_PLACEMENT_CA:-}"
if [[ -n "$CA_PEM" && "$CA_PEM" != *'-----BEGIN CERTIFICATE-----'* ]]; then
  echo 'runner-select: placement-ca is not a PEM certificate' >&2
  emit "$DEFAULT_JSON" default error
  exit 0
fi

TEMP_BASE="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
CFG="$(mktemp "${TEMP_BASE}/runner-select-curl.XXXXXX")"
BODY_FILE="$(mktemp "${TEMP_BASE}/runner-select-body.XXXXXX")"
CA_FILE=''
chmod 600 "$CFG"
cleanup() {
  rm -f "$CFG" "$BODY_FILE" ${CA_FILE:+"$CA_FILE"}
}
trap cleanup EXIT

{
  printf 'header = "Authorization: Bearer %s"\n' "$TOKEN"
} >"$CFG"

CURL_TLS=()
if [[ -n "$CA_PEM" ]]; then
  CA_FILE="$(mktemp "${TEMP_BASE}/runner-select-ca.XXXXXX")"
  printf '%s\n' "$CA_PEM" >"$CA_FILE"
  CURL_TLS=(--cacert "$CA_FILE")
fi

HTTP_CODE=0
if ! HTTP_CODE="$(curl --silent --show-error --max-time 10 --config "$CFG" ${CURL_TLS[@]+"${CURL_TLS[@]}"} --output "$BODY_FILE" --write-out '%{http_code}' "$URL" 2>/dev/null)"; then
  emit "$DEFAULT_JSON" default error
  exit 0
fi

if [[ "$HTTP_CODE" != "200" ]]; then
  emit "$DEFAULT_JSON" default error
  exit 0
fi

BODY="$(<"$BODY_FILE")"
if ! placement_body_valid "$BODY"; then
  emit "$DEFAULT_JSON" default error
  exit 0
fi

TOTAL_FREE="$(printf '%s' "$BODY" | jq -er '.hosted.total.free | floor')"
MACOS_FREE="$(printf '%s' "$BODY" | jq -er '.hosted.macos.free | floor')"
HEADROOM="$(printf '%s' "$BODY" | jq -er '.overflow.headroom | floor')"

HOSTED=0
if [[ "$CLASS" == macos ]]; then
  if (( TOTAL_FREE > 0 && MACOS_FREE > 0 )); then
    HOSTED=1
  fi
elif (( TOTAL_FREE > 0 )); then
  HOSTED=1
fi

if (( HOSTED )); then
  emit "$DEFAULT_JSON" hosted hosted
  exit 0
fi

if (( HEADROOM > 0 )); then
  emit "$OVERFLOW_JSON" overflow overflow
  exit 0
fi

emit "$DEFAULT_JSON" default default
exit 0