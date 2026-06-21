#!/usr/bin/env bash
# Disable Google Gemini for the OpenClaw "fixer" agent and clean it up.
#
# Usage:
#   ./disable-gemini-fixer.sh            # fixer back to local model, keep agent
#   ./disable-gemini-fixer.sh --remove-fixer   # also delete the fixer agent entirely
#
# Always:
#   - points the fixer back to the local hailo/qwen2.5-coder:1.5b model
#   - removes the "gemini" provider (and its stored API key) from the config
#   - removes the gemini model entry from agents.defaults.models
# With --remove-fixer it additionally deletes the fixer agent from agents.list.
#
# The main agent is never touched. Config is validated and the gateway restarted.
set -euo pipefail

REMOVE_FIXER=0
[[ "${1:-}" == "--remove-fixer" ]] && REMOVE_FIXER=1

echo ">> Backing up config"
cp ~/.openclaw/openclaw.json ~/.openclaw/openclaw.json.pre-disable-gemini

PATCH_FILE="/tmp/disable-gemini-patch.json"
python3 - "$REMOVE_FIXER" "$PATCH_FILE" <<'PYEOF'
import json, os, sys
remove_fixer = sys.argv[1] == "1"
out = sys.argv[2]
cfg = json.load(open(os.path.expanduser("~/.openclaw/openclaw.json")))

lst = cfg["agents"]["list"]
if remove_fixer:
    lst = [a for a in lst if a["id"] != "fixer"]
else:
    for a in lst:
        if a["id"] == "fixer":
            a["model"] = {"primary": "hailo/qwen2.5-coder:1.5b"}

# Drop any gemini/* entries from agents.defaults.models
defmodels = cfg.get("agents", {}).get("defaults", {}).get("models", {})
defmodels = {k: v for k, v in defmodels.items() if not k.startswith("gemini/")}

patch = {
  "models": {"providers": {"gemini": None}},          # null deletes the provider+key
  "agents": {"defaults": {"models": defmodels},
             "list": lst}
}
json.dump(patch, open(out, "w"), indent=1)
print("fixer present:", any(a["id"] == "fixer" for a in lst),
      "| gemini provider -> removed")
PYEOF

echo ">> Validating patch"
openclaw config patch --file "$PATCH_FILE" --dry-run
echo ">> Applying"
openclaw config patch --file "$PATCH_FILE"
rm -f "$PATCH_FILE"

echo ">> Validating config"
openclaw config validate
echo ">> Restarting gateway"
systemctl --user restart openclaw-gateway || true
sleep 8
systemctl --user is-active openclaw-gateway || true
echo ">> Done. Gemini provider + key removed."
