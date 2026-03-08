#!/usr/bin/env bash
set -euo pipefail

SUPABASE_URL="${SUPABASE_URL:-}"
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-${SUPABASE_ANON_KEY:-}}"
SOURCE_DIR="${SOURCE_DIR:-/root/.openclaw/agents/main/sessions}"
LIMIT="${LIMIT:-200}"

if [[ -z "$SUPABASE_URL" || -z "$SUPABASE_KEY" ]]; then
  echo "Error: faltan SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY/SUPABASE_ANON_KEY" >&2
  exit 1
fi

python3 - "$SOURCE_DIR" "$LIMIT" "$SUPABASE_URL" "$SUPABASE_KEY" <<'PY'
import glob, json, os, re, sys, urllib.request

source_dir, limit_s, supabase_url, key = sys.argv[1:]
limit = int(limit_s)


def infer_agent(msg, session_id):
    for k in ("agent_id", "agentId", "agent"):
        v = (msg.get("meta") or {}).get(k)
        if isinstance(v, str) and v.strip() and v.strip().lower() != "main":
            return v.strip()
    m = re.search(r"(desarrollador-\d+|agent-\d+)", session_id, re.I)
    if m:
        return m.group(1).lower()
    return "unknown"

rows = []
for fp in glob.glob(os.path.join(source_dir, "*.jsonl")):
    session_id = os.path.basename(fp).replace(".jsonl", "")
    with open(fp, "r", encoding="utf-8") as f:
        for ln in f:
            try:
                obj = json.loads(ln)
            except Exception:
                continue
            msg = obj.get("message") or {}
            usage = msg.get("usage") or {}
            if not usage:
                continue
            inp = int(usage.get("input") or 0)
            out = int(usage.get("output") or 0)
            total = int(usage.get("totalTokens") or (inp + out))
            if total <= 0:
                continue
            cost_obj = usage.get("cost") or {}
            provider_cost = cost_obj.get("total")
            cost_source = "provider" if isinstance(provider_cost, (int, float)) else "unknown"

            run_id = str(obj.get("id") or f"{session_id}-{obj.get('timestamp') or len(rows)}")
            row = {
                "agent_id": infer_agent(msg, session_id),
                "run_id": run_id,
                "task_name": "openclaw_session_message",
                "model": msg.get("model") or "",
                "input_tokens": inp,
                "output_tokens": out,
                "estimated_cost_usd": float(provider_cost) if isinstance(provider_cost, (int, float)) else None,
                "status": msg.get("stopReason") or "completed",
                "started_at": None,
                "finished_at": obj.get("timestamp"),
                "meta": {
                    "provider": msg.get("provider"),
                    "api": msg.get("api"),
                    "session_id": session_id,
                    "source": "openclaw_jsonl_backfill",
                    "cost_source": cost_source,
                },
            }
            rows.append(row)

rows.sort(key=lambda r: r.get("finished_at") or "", reverse=True)
rows = rows[:limit]

payload = json.dumps(rows).encode("utf-8")
req = urllib.request.Request(
    f"{supabase_url.rstrip('/')}/rest/v1/agent_token_usage?on_conflict=agent_id,run_id",
    data=payload,
    method="POST",
    headers={
        "apikey": key,
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
        "Prefer": "resolution=merge-duplicates,return=representation",
    },
)
with urllib.request.urlopen(req, timeout=60) as resp:
    data = json.loads(resp.read().decode("utf-8"))
    print(len(data) if isinstance(data, list) else 0)
PY
