#!/usr/bin/env bash
# Activate Google Gemini (Google AI Studio) for the OpenClaw "fixer" agent.
#
# Usage:
#   ./set-gemini-fixer.sh <GEMINI_API_KEY> [MODEL_ID]
#   GEMINI_API_KEY=AIza... ./set-gemini-fixer.sh
#
# MODEL_ID defaults to gemini-2.5-flash (fast, free-tier friendly, good for
# code review / repair). Other good choices: gemini-2.5-pro, gemini-2.0-flash.
#
# What it does (idempotent):
#   1. Adds/updates the "gemini" provider (api: google-generative-ai) with your key.
#   2. Registers the model under agents.defaults.models (streaming on).
#   3. Points the fixer agent at gemini/<MODEL_ID>, with a LOCAL fallback to
#      hailo/qwen2.5-coder:1.5b so the fixer keeps working if Gemini is
#      unavailable (quota, network, bad key).
#   4. Validates the config and restarts the gateway.
#   5. Smoke-tests the fixer and reports the result.
#
# The main agent stays 100% local on the Hailo NPU. Only the fixer uses Gemini.
# The key is stored locally in ~/.openclaw/openclaw.json (never committed to git).
set -euo pipefail

KEY="${1:-${GEMINI_API_KEY:-}}"
MODEL_ID="${2:-gemini-2.5-flash}"
DRYRUN="${DRYRUN:-0}"

if [[ -z "$KEY" ]]; then
  echo "ERROR: no API key. Get a free key at https://aistudio.google.com/apikey" >&2
  echo "Usage: $0 <GEMINI_API_KEY> [MODEL_ID]" >&2
  exit 1
fi

echo ">> Backing up config"
cp ~/.openclaw/openclaw.json ~/.openclaw/openclaw.json.pre-gemini 2>/dev/null || true

echo ">> Building patch (provider + model + fixer agent, preserving other agents)"
PATCH_FILE="/tmp/gemini-fixer-patch.json"
python3 - "$KEY" "$MODEL_ID" "$PATCH_FILE" <<'PYEOF'
import json, sys
key, model, out = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = json.load(open("%s/.openclaw/openclaw.json" % __import__("os").path.expanduser("~")))
lst = cfg["agents"]["list"]
found = False
for a in lst:
    if a["id"] == "fixer":
        a["model"] = {"primary": f"gemini/{model}",
                      "fallbacks": ["hailo/qwen2.5-coder:1.5b"]}
        found = True
if not found:
    raise SystemExit("ERROR: no 'fixer' agent in config")
patch = {
  "models": {"providers": {"gemini": {
      "baseUrl": "https://generativelanguage.googleapis.com/v1beta",
      "apiKey": key, "api": "google-generative-ai",
      "models": [{"id": model, "name": model, "reasoning": True,
                  "input": ["text"], "contextWindow": 1048576, "maxTokens": 8192}]}}},
  "agents": {"defaults": {"models": {f"gemini/{model}": {"streaming": True}}},
             "list": lst}
}
json.dump(patch, open(out, "w"), indent=1)
print("fixer.model ->", [a["model"] for a in lst if a["id"] == "fixer"][0])
PYEOF

if [[ "$DRYRUN" == "1" ]]; then
  echo ">> DRY-RUN: validating patch without writing"
  openclaw config patch --file "$PATCH_FILE" --dry-run
  echo ">> DRY-RUN OK"; rm -f "$PATCH_FILE"; exit 0
fi

echo ">> Patching config (provider + model + fixer agent)"
openclaw config patch --file "$PATCH_FILE"
rm -f "$PATCH_FILE"

echo ">> Validating config"
openclaw config validate

echo ">> Restarting gateway"
systemctl --user restart openclaw-gateway || true
sleep 8
systemctl --user is-active openclaw-gateway || true

echo ">> Smoke-testing the fixer agent on Gemini"
SK="fixer:gemini-smoke-$(date +%s)"
OUT=$(openclaw agent --agent fixer --session-key "$SK" \
      --message "Antworte in genau einem kurzen Satz: bestaetige, dass du (Gemini) als Fixer laeufst." \
      --timeout 60 --json 2>/dev/null || true)
echo "$OUT" | python3 -c "import sys,json,re
raw=sys.stdin.read(); i=raw.find('{')
try:
    d=json.loads(raw[i:])
    def f(o,k):
        if isinstance(o,dict):
            if k in o and isinstance(o[k],str): return o[k]
            for v in o.values():
                r=f(v,k)
                if r: return r
        elif isinstance(o,list):
            for v in o:
                r=f(v,k)
                if r: return r
    t=f(d,'finalAssistantVisibleText') or ''
    print('FIXER REPLY:', t[:200] if t else '(leer)')
except Exception as e:
    print('could not parse reply:', e)" || true

echo ">> Done. Fixer now uses gemini/$MODEL_ID (fallback: hailo/qwen2.5-coder:1.5b)."
