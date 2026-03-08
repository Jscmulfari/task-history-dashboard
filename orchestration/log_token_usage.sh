#!/usr/bin/env bash
set -euo pipefail

# Upsert de consumo de tokens por corrida de agente en Supabase
# Tabla: public.agent_token_usage
# Idempotencia: on_conflict=(agent_id,run_id)
#
# Credenciales (ENV o args):
#   SUPABASE_URL / --url
#   SUPABASE_SERVICE_ROLE_KEY o SUPABASE_ANON_KEY / --key
#
# Uso:
#   log_token_usage.sh --agent-id desarrollador-1 --run-id run-123 --input-tokens 120 --output-tokens 45 \
#     --task-name "sync" --model "gpt-5" --status completed --estimated-cost-usd 0.00123

SUPABASE_URL="${SUPABASE_URL:-}"
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-${SUPABASE_ANON_KEY:-}}"

AGENT_ID=""
RUN_ID=""
TASK_NAME=""
MODEL=""
INPUT_TOKENS="0"
OUTPUT_TOKENS="0"
ESTIMATED_COST_USD=""
STATUS="completed"
STARTED_AT=""
FINISHED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
META_JSON="{}"

usage() {
  cat <<'EOF'
Uso:
  log_token_usage.sh [--url URL] [--key KEY] \
    --agent-id AGENT_ID --run-id RUN_ID \
    [--task-name TASK] [--model MODEL] \
    [--input-tokens N] [--output-tokens N] \
    [--estimated-cost-usd DECIMAL] [--status STATUS] \
    [--started-at ISO8601] [--finished-at ISO8601] [--meta-json JSON]
EOF
}

is_int() { [[ "$1" =~ ^[0-9]+$ ]]; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) SUPABASE_URL="$2"; shift 2 ;;
    --key) SUPABASE_KEY="$2"; shift 2 ;;
    --agent-id) AGENT_ID="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --task-name) TASK_NAME="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --input-tokens) INPUT_TOKENS="$2"; shift 2 ;;
    --output-tokens) OUTPUT_TOKENS="$2"; shift 2 ;;
    --estimated-cost-usd) ESTIMATED_COST_USD="$2"; shift 2 ;;
    --status) STATUS="$2"; shift 2 ;;
    --started-at) STARTED_AT="$2"; shift 2 ;;
    --finished-at) FINISHED_AT="$2"; shift 2 ;;
    --meta-json) META_JSON="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Argumento no reconocido: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$SUPABASE_URL" || -z "$SUPABASE_KEY" ]]; then
  echo "Error: faltan SUPABASE_URL y key (SUPABASE_SERVICE_ROLE_KEY/SUPABASE_ANON_KEY o --key)." >&2
  exit 1
fi
if [[ -z "$AGENT_ID" || -z "$RUN_ID" ]]; then
  echo "Error: --agent-id y --run-id son obligatorios." >&2
  exit 1
fi
if ! is_int "$INPUT_TOKENS" || ! is_int "$OUTPUT_TOKENS"; then
  echo "Error: --input-tokens y --output-tokens deben ser enteros >= 0." >&2
  exit 1
fi

SUPABASE_URL="${SUPABASE_URL%/}"

json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

COST_FIELD='null'
if [[ -n "$ESTIMATED_COST_USD" ]]; then
  COST_FIELD="$ESTIMATED_COST_USD"
fi
STARTED_FIELD='null'
if [[ -n "$STARTED_AT" ]]; then
  STARTED_FIELD='"'"$(json_escape "$STARTED_AT")"'"'
fi
FINISHED_FIELD='null'
if [[ -n "$FINISHED_AT" ]]; then
  FINISHED_FIELD='"'"$(json_escape "$FINISHED_AT")"'"'
fi

payload="[{\"agent_id\":\"$(json_escape "$AGENT_ID")\",\"run_id\":\"$(json_escape "$RUN_ID")\",\"task_name\":\"$(json_escape "$TASK_NAME")\",\"model\":\"$(json_escape "$MODEL")\",\"input_tokens\":$INPUT_TOKENS,\"output_tokens\":$OUTPUT_TOKENS,\"estimated_cost_usd\":$COST_FIELD,\"status\":\"$(json_escape "$STATUS")\",\"started_at\":$STARTED_FIELD,\"finished_at\":$FINISHED_FIELD,\"meta\":$META_JSON}]"

response_file="$(mktemp)"
http_code="$(curl -sS -o "$response_file" -w '%{http_code}' \
  -X POST "$SUPABASE_URL/rest/v1/agent_token_usage?on_conflict=agent_id,run_id" \
  -H "apikey: $SUPABASE_KEY" \
  -H "Authorization: Bearer $SUPABASE_KEY" \
  -H "Content-Type: application/json" \
  -H "Prefer: resolution=merge-duplicates,return=representation" \
  -d "$payload")"

if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
  echo "Error HTTP $http_code al upsert en agent_token_usage:" >&2
  cat "$response_file" >&2
  rm -f "$response_file"
  exit 1
fi

cat "$response_file"
rm -f "$response_file"
