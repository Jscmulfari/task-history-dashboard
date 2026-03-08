#!/usr/bin/env bash
set -euo pipefail

# Upsert de consumo de tokens por corrida de agente en Supabase
# Tabla: public.agent_token_usage
# Idempotencia: on_conflict=(agent_id,run_id)

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
META_JSON='{}'
COST_SOURCE="provider"

usage() {
  cat <<'EOF'
Uso:
  log_token_usage.sh [--url URL] [--key KEY] \
    --agent-id AGENT_ID --run-id RUN_ID \
    [--task-name TASK] [--model MODEL] \
    [--input-tokens N] [--output-tokens N] \
    [--estimated-cost-usd DECIMAL] [--cost-source provider|computed|unknown] \
    [--status STATUS] [--started-at ISO8601] [--finished-at ISO8601] [--meta-json JSON]
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
    --cost-source) COST_SOURCE="$2"; shift 2 ;;
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
if [[ "$AGENT_ID" == "main" ]]; then
  echo "Error: agent_id='main' no permitido para evitar agregación inválida. Use ID real o 'unknown'." >&2
  exit 1
fi
if ! is_int "$INPUT_TOKENS" || ! is_int "$OUTPUT_TOKENS"; then
  echo "Error: --input-tokens y --output-tokens deben ser enteros >= 0." >&2
  exit 1
fi

SUPABASE_URL="${SUPABASE_URL%/}"

python3 - "$SUPABASE_URL" "$SUPABASE_KEY" "$AGENT_ID" "$RUN_ID" "$TASK_NAME" "$MODEL" "$INPUT_TOKENS" "$OUTPUT_TOKENS" "$ESTIMATED_COST_USD" "$STATUS" "$STARTED_AT" "$FINISHED_AT" "$META_JSON" "$COST_SOURCE" <<'PY'
import json, sys, urllib.request
(
  supabase_url, key, agent_id, run_id, task_name, model,
  input_tokens, output_tokens, estimated_cost, status,
  started_at, finished_at, meta_json, cost_source
) = sys.argv[1:]

try:
  meta = json.loads(meta_json) if meta_json else {}
except Exception:
  raise SystemExit("Error: --meta-json inválido")

if not isinstance(meta, dict):
  raise SystemExit("Error: --meta-json debe ser objeto JSON")

meta["cost_source"] = cost_source or "unknown"

row = {
  "agent_id": agent_id,
  "run_id": run_id,
  "task_name": task_name,
  "model": model,
  "input_tokens": int(input_tokens),
  "output_tokens": int(output_tokens),
  "estimated_cost_usd": None,
  "status": status,
  "started_at": started_at or None,
  "finished_at": finished_at or None,
  "meta": meta,
}
if estimated_cost != "":
  row["estimated_cost_usd"] = float(estimated_cost)

payload = json.dumps([row]).encode("utf-8")
req = urllib.request.Request(
  f"{supabase_url}/rest/v1/agent_token_usage?on_conflict=agent_id,run_id",
  data=payload,
  method="POST",
  headers={
    "apikey": key,
    "Authorization": f"Bearer {key}",
    "Content-Type": "application/json",
    "Prefer": "resolution=merge-duplicates,return=representation",
  },
)
try:
  with urllib.request.urlopen(req, timeout=30) as resp:
    print(resp.read().decode("utf-8"))
except urllib.error.HTTPError as e:
  body = e.read().decode("utf-8", errors="ignore")
  print(f"Error HTTP {e.code} al upsert en agent_token_usage:\n{body}", file=sys.stderr)
  raise
PY
