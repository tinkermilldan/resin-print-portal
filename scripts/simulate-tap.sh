#!/bin/bash
# Stands in for a Pi at the printer: one fob tap against a portal, making the
# same API calls pi-agent makes (check -> claim -> download -> started). The
# real agent can't run on a dev box -- it needs the RDM6300 on /dev/serial0
# and the USB gadget -- so this is how you exercise the printer side locally.
# See docs/development.md.
#
# Usage:
#   scripts/simulate-tap.sh --slug <printer> --key <printer API key> --fob <code>
#       [--portal http://localhost:8080] [--out DIR]
#   scripts/simulate-tap.sh --slug <printer> --key <key> --finish <job id>
#
# The loaded file lands in --out (default $TMPDIR/simulated-gadget), standing
# in for the USB drive the printer would see.
set -euo pipefail

PORTAL=http://localhost:8080
SLUG=""
KEY=""
FOB=""
FINISH=""
OUT="${TMPDIR:-/tmp}/simulated-gadget"

while [ $# -gt 0 ]; do
    case "$1" in
        --portal) PORTAL="${2%/}"; shift 2 ;;
        --slug) SLUG="$2"; shift 2 ;;
        --key) KEY="$2"; shift 2 ;;
        --fob) FOB="$2"; shift 2 ;;
        --finish) FINISH="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1 (see --help)" >&2; exit 2 ;;
    esac
done

if [ -z "$SLUG" ] || [ -z "$KEY" ] || { [ -z "$FOB" ] && [ -z "$FINISH" ]; }; then
    echo "need --slug, --key, and either --fob or --finish (see --help)" >&2
    exit 2
fi

API="$PORTAL/api/v1/printers/$SLUG"

call() { curl -fsS -H "Authorization: Bearer $KEY" -H "X-Agent-Version: simulate-tap" "$@"; }

# json_get FIELD < json  ->  the field's value ("" if absent; booleans as true/false)
json_get() {
    python3 -c '
import json, sys
v = json.load(sys.stdin).get(sys.argv[1])
print("" if v is None else (str(v).lower() if isinstance(v, bool) else v))' "$1"
}

if [ -n "$FINISH" ]; then
    call -X POST -o /dev/null "$API/jobs/$FINISH/finished"
    echo "job $FINISH marked finished"
    exit 0
fi

echo "--> tap: $FOB on $SLUG"
CHECK=$(call -d "{\"rfid_code\":\"$FOB\"}" "$API/check")
echo "    check: $CHECK"

if [ "$(json_get just_certified <<<"$CHECK")" = true ]; then
    echo "certified $(json_get member_name <<<"$CHECK") for $SLUG by tap"
    exit 0
fi
if [ "$(json_get allowed <<<"$CHECK")" != true ]; then
    echo "DENIED: $(json_get reason <<<"$CHECK")" >&2
    exit 1
fi
if [ -z "$(json_get staged_filename <<<"$CHECK")" ]; then
    echo "allowed, but $(json_get member_name <<<"$CHECK") has nothing staged for $SLUG -- upload a file first"
    exit 0
fi

CLAIM=$(call -d "{\"rfid_code\":\"$FOB\"}" "$API/claim")
echo "    claim: $CLAIM"
if [ "$(json_get claimed <<<"$CLAIM")" != true ]; then
    echo "claim refused: $(json_get reason <<<"$CLAIM")" >&2
    exit 1
fi
JOB=$(json_get job_id <<<"$CLAIM")
NAME=$(basename "$(json_get filename <<<"$CLAIM")")
WANT_SHA=$(json_get sha256 <<<"$CLAIM")

# Same as the real gadget: exactly one file on the drive at a time.
mkdir -p "$OUT"
find "$OUT" -mindepth 1 -delete
call -o "$OUT/$NAME" "$API/jobs/$JOB/file"
if [ -n "$WANT_SHA" ]; then
    GOT_SHA=$(sha256sum "$OUT/$NAME" | cut -d' ' -f1)
    if [ "$GOT_SHA" != "$WANT_SHA" ]; then
        echo "sha256 mismatch: portal said $WANT_SHA, got $GOT_SHA" >&2
        exit 1
    fi
fi
call -X POST -o /dev/null "$API/jobs/$JOB/started"

echo "loaded job $JOB: $OUT/$NAME"
echo "finish it with: $0 --portal $PORTAL --slug $SLUG --key <key> --finish $JOB"
