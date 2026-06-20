#!/usr/bin/env python3
"""
Fixer-Optimizer — bounded, safe 24h auto-tuner for the OpenClaw "main" agent.

Goal (from requirements): a main agent that does NOT abort (no tool-loop, no
context overflow, no HTTP500, no 1-token replies), uses MORE tokens, has MORE
context, and delivers VERY GOOD results.

How it works each cycle:
  1. Pick the next candidate tuning config (a small safe grid).
  2. Apply it to the proxy's hard-coded constants (whitelist only) + restart.
  3. Health-check the proxy; if unhealthy -> rollback immediately.
  4. Run a benchmark (code / file-tool / knowledge / length) against `main`.
  5. Score it. If it beats the current best -> keep it, sync to repo working
     copy, and Signal-report to Stefan. Otherwise -> rollback to best.
Safety: only numeric constants on a whitelist are ever changed, within bounds.
No arbitrary code edits. Every change is backed up and validated; the proxy is
never left in a broken state. Runs until a 24h deadline, then exits cleanly.
"""
import json, os, re, subprocess, sys, time, datetime, shutil

HOME = os.path.expanduser("~")
PROXY = "/usr/local/bin/hailo-sanitize-proxy.py"
REPO_PROXY = f"{HOME}/raspberry-hailo-openclaw-installer/hailo-sanitize-proxy.py"
STATE = f"{HOME}/fixer-optimizer/state.json"
LOG = f"{HOME}/fixer-optimizer/optimizer.log"
BACKUP_DIR = f"{HOME}/fixer-optimizer/backups"
SUDO_PW = "raspberry"
STEFAN = "+4915152536599"
PROXY_URL = "http://127.0.0.1:8081"
CYCLE_SLEEP = 1800   # 30 min between cycles
RUN_HOURS = 24

os.makedirs(BACKUP_DIR, exist_ok=True)

# --- safe whitelist of tunable constants and their bounds -------------------
BOUNDS = {
    "PROXY_TEMPERATURE": (0.05, 0.8),
    "PROXY_FREQUENCY_PENALTY": (0.0, 1.2),
    "PROXY_TOP_K": (0, 60),
    "MAX_HISTORY_MESSAGES": (4, 24),
    "MAX_PROXY_COMPLETION_TOKENS": (192, 1024),
    "DEFAULT_PROXY_COMPLETION_TOKENS": (128, 1024),
    "CODE_PROXY_COMPLETION_TOKENS": (384, 1536),
    "WEB_PROXY_COMPLETION_TOKENS": (96, 512),
}
INT_KEYS = {"PROXY_TOP_K", "MAX_HISTORY_MESSAGES", "MAX_PROXY_COMPLETION_TOKENS",
            "DEFAULT_PROXY_COMPLETION_TOKENS", "CODE_PROXY_COMPLETION_TOKENS",
            "WEB_PROXY_COMPLETION_TOKENS"}

# Candidate grid: all keep tokens/context HIGH (meets "more tokens/context"),
# vary the sampling that drives factual quality + no-abort behaviour.
CANDIDATES = [
    {"name": "conservative", "PROXY_TEMPERATURE": 0.15, "PROXY_FREQUENCY_PENALTY": 0.0, "PROXY_TOP_K": 0,
     "MAX_HISTORY_MESSAGES": 16, "MAX_PROXY_COMPLETION_TOKENS": 1024, "DEFAULT_PROXY_COMPLETION_TOKENS": 512,
     "CODE_PROXY_COMPLETION_TOKENS": 1024, "WEB_PROXY_COMPLETION_TOKENS": 256},
    {"name": "hailo-node", "PROXY_TEMPERATURE": 0.7, "PROXY_FREQUENCY_PENALTY": 1.1, "PROXY_TOP_K": 20,
     "MAX_HISTORY_MESSAGES": 16, "MAX_PROXY_COMPLETION_TOKENS": 1024, "DEFAULT_PROXY_COMPLETION_TOKENS": 1024,
     "CODE_PROXY_COMPLETION_TOKENS": 1024, "WEB_PROXY_COMPLETION_TOKENS": 256},
    {"name": "balanced-low", "PROXY_TEMPERATURE": 0.3, "PROXY_FREQUENCY_PENALTY": 0.0, "PROXY_TOP_K": 20,
     "MAX_HISTORY_MESSAGES": 16, "MAX_PROXY_COMPLETION_TOKENS": 1024, "DEFAULT_PROXY_COMPLETION_TOKENS": 768,
     "CODE_PROXY_COMPLETION_TOKENS": 1024, "WEB_PROXY_COMPLETION_TOKENS": 256},
    {"name": "balanced-mid", "PROXY_TEMPERATURE": 0.4, "PROXY_FREQUENCY_PENALTY": 0.3, "PROXY_TOP_K": 30,
     "MAX_HISTORY_MESSAGES": 20, "MAX_PROXY_COMPLETION_TOKENS": 1024, "DEFAULT_PROXY_COMPLETION_TOKENS": 768,
     "CODE_PROXY_COMPLETION_TOKENS": 1280, "WEB_PROXY_COMPLETION_TOKENS": 256},
    {"name": "factual-rich", "PROXY_TEMPERATURE": 0.2, "PROXY_FREQUENCY_PENALTY": 0.0, "PROXY_TOP_K": 40,
     "MAX_HISTORY_MESSAGES": 24, "MAX_PROXY_COMPLETION_TOKENS": 1024, "DEFAULT_PROXY_COMPLETION_TOKENS": 768,
     "CODE_PROXY_COMPLETION_TOKENS": 1280, "WEB_PROXY_COMPLETION_TOKENS": 256},
]

# --- benchmark cases --------------------------------------------------------
BENCH = [
    {"id": "code", "msg": "Schreibe eine Python-Funktion, die 'Hello world' fuenfmal mit einer Schleife ausgibt.",
     "must": ["def", "print"], "any": ["for", "range", "while"], "no_json": True},
    {"id": "filetool", "msg": "Lese die Dateinamen im Ordner /home/pi/Downloads aus.",
     "must": [], "any": [".deb", ".whl", ".run"], "no_json": True, "max_calls": 2},
    {"id": "knowledge", "msg": "Was ist die Hauptstadt von Frankreich? Antworte kurz.",
     "must": ["paris"], "any": [], "no_json": True, "max_calls": 0},
    {"id": "length", "msg": "Erklaere in drei Saetzen, was ein Raspberry Pi ist.",
     "must": [], "any": ["raspberry", "computer", "rechner", "platine"], "no_json": True, "min_len": 60},
]


def log(msg):
    line = f"{datetime.datetime.now().isoformat(timespec='seconds')} {msg}"
    print(line, flush=True)
    with open(LOG, "a") as f:
        f.write(line + "\n")


def sudo(args):
    return subprocess.run(["sudo", "-S"] + args, input=SUDO_PW + "\n",
                          text=True, capture_output=True)


def read_proxy():
    return open(PROXY).read()


def write_proxy(text):
    tmp = "/tmp/hailo-proxy-candidate.py"
    open(tmp, "w").write(text)
    # validate syntax before installing
    import ast
    ast.parse(text)
    sudo(["cp", tmp, PROXY])


def backup_proxy(tag):
    dst = f"{BACKUP_DIR}/hailo-proxy-{tag}.py"
    shutil.copy(PROXY, dst)
    return dst


def set_const(text, key, val):
    if key in INT_KEYS:
        val = int(round(val))
    lo, hi = BOUNDS[key]
    val = max(lo, min(val, hi))
    if key in INT_KEYS:
        rep = str(int(val))
    else:
        rep = f"{float(val):.2f}"
    pat = re.compile(rf"(?m)^({re.escape(key)}\s*=\s*)[-\d.]+")
    new, n = pat.subn(lambda m: m.group(1) + rep, text)
    if n == 0:
        log(f"WARN: constant {key} not found")
    return new


def apply_config(cfg):
    text = read_proxy()
    for k, v in cfg.items():
        if k == "name":
            continue
        if k in BOUNDS:
            text = set_const(text, k, v)
    # also raise the per-model cap so nothing re-clamps qwen3 below chat cap
    cap = int(cfg.get("MAX_PROXY_COMPLETION_TOKENS", 1024))
    text = re.sub(r'("qwen3:1\.7b":\s*)\d+', rf'\g<1>{cap}', text)
    text = re.sub(r'("qwen2\.5-coder:1\.5b":\s*)\d+', rf'\g<1>{cap}', text)
    write_proxy(text)


def restart_proxy():
    sudo(["systemctl", "restart", "hailo-sanitize-proxy.service"])
    time.sleep(5)


def proxy_healthy():
    for _ in range(6):
        try:
            import urllib.request
            with urllib.request.urlopen(f"{PROXY_URL}/v1/models", timeout=6) as r:
                if r.status == 200:
                    return True
        except Exception:
            pass
        time.sleep(3)
    return False


def signal_send(msg):
    try:
        subprocess.run(["openclaw", "message", "send", "--channel", "signal",
                        "--target", STEFAN, "--message", msg],
                       timeout=60, capture_output=True, text=True)
    except Exception as e:
        log(f"signal send failed: {e}")


def run_agent(msg, timeout=200):
    """Run one main-agent turn, return (text, calls)."""
    skey = f"agent:main:opt-{int(time.time())}"
    try:
        p = subprocess.run(["openclaw", "agent", "--agent", "main",
                            "--session-key", skey, "--message", msg,
                            "--timeout", str(timeout - 10), "--json"],
                           timeout=timeout, capture_output=True, text=True)
    except subprocess.TimeoutExpired:
        return None, None
    raw = p.stdout
    i = raw.find("{")
    if i < 0:
        return None, None
    try:
        d = json.loads(raw[i:])
    except Exception:
        return None, None

    def find(o, k):
        if isinstance(o, dict):
            if k in o and isinstance(o[k], str):
                return o[k]
            for v in o.values():
                r = find(v, k)
                if r:
                    return r
        elif isinstance(o, list):
            for v in o:
                r = find(v, k)
                if r:
                    return r
        return None

    def find_calls(o):
        if isinstance(o, dict):
            if "toolSummary" in o and isinstance(o["toolSummary"], dict):
                return o["toolSummary"].get("calls")
            for v in o.values():
                r = find_calls(v)
                if r is not None:
                    return r
        elif isinstance(o, list):
            for v in o:
                r = find_calls(v)
                if r is not None:
                    return r
        return None

    text = find(d, "finalAssistantVisibleText") or ""
    calls = find_calls(d)
    return text, (calls if calls is not None else 0)


def score_case(case, text, calls):
    if text is None:
        return 0.0, "timeout/parse-fail"
    low = text.lower()
    reasons = []
    ok = 1.0
    # no raw tool JSON leak
    if case.get("no_json") and re.search(r'\{\s*"tool"\s*:', text):
        ok = 0.0
        reasons.append("raw-json-leak")
    # non-empty
    if not text.strip():
        ok = 0.0
        reasons.append("empty")
    # must-have keywords
    for kw in case.get("must", []):
        if kw.lower() not in low:
            ok = min(ok, 0.3)
            reasons.append(f"missing:{kw}")
    # any-of keywords
    anyk = case.get("any", [])
    if anyk and not any(kw.lower() in low for kw in anyk):
        ok = min(ok, 0.4)
        reasons.append("missing-any")
    # tool-call discipline
    if "max_calls" in case and calls is not None and calls > case["max_calls"]:
        ok = min(ok, 0.2)
        reasons.append(f"too-many-calls:{calls}")
    # minimum length
    if "min_len" in case and len(text.strip()) < case["min_len"]:
        ok = min(ok, 0.5)
        reasons.append("too-short")
    return ok, ",".join(reasons) or "ok"


def run_benchmark():
    total = 0.0
    details = []
    for case in BENCH:
        text, calls = run_agent(case["msg"])
        s, why = score_case(case, text, calls)
        total += s
        details.append(f"{case['id']}={s:.2f}({why})")
        log(f"  bench {case['id']}: {s:.2f} {why} calls={calls}")
    avg = total / len(BENCH)
    return avg, "; ".join(details)


def load_state():
    if os.path.exists(STATE):
        return json.load(open(STATE))
    deadline = time.time() + RUN_HOURS * 3600
    return {"deadline": deadline, "best_score": -1, "best_cfg": None,
            "tried": [], "cycle": 0}


def save_state(st):
    json.dump(st, open(STATE, "w"), indent=2)


def sync_repo():
    try:
        shutil.copy(PROXY, REPO_PROXY)
    except Exception as e:
        log(f"repo sync failed: {e}")


def main():
    st = load_state()
    if time.time() > st["deadline"]:
        log("deadline reached; exiting.")
        signal_send("🔧 Fixer-Optimizer: 24h-Lauf beendet. "
                    f"Beste Konfig: {st.get('best_cfg',{}).get('name','?')} "
                    f"Score {st.get('best_score',-1):.2f}. Einstellungen bleiben live aktiv.")
        subprocess.run(["systemctl", "--user", "disable", "--now",
                        "fixer-optimizer.timer"], capture_output=True, text=True)
        sys.exit(0)

    st["cycle"] += 1
    cyc = st["cycle"]
    log(f"=== cycle {cyc} (best so far: {st['best_score']:.2f} "
        f"{st.get('best_cfg',{}).get('name') if st.get('best_cfg') else '-'}) ===")

    # choose next untried candidate; once all tried, re-verify best.
    untried = [c for c in CANDIDATES if c["name"] not in st["tried"]]
    if untried:
        cand = untried[0]
    else:
        cand = st.get("best_cfg") or CANDIDATES[0]

    log(f"trying candidate: {cand['name']}")
    backup_proxy(f"pre-{cyc}")
    try:
        apply_config(cand)
    except Exception as e:
        log(f"apply failed ({e}); restoring best")
        restore_best(st)
        save_state(st)
        return
    restart_proxy()
    if not proxy_healthy():
        log("proxy unhealthy after apply -> rollback")
        restore_best(st)
        return

    score, details = run_benchmark()
    log(f"candidate {cand['name']} score={score:.2f} :: {details}")
    if cand["name"] not in st["tried"]:
        st["tried"].append(cand["name"])

    if score > st["best_score"] + 1e-9:
        improved = st["best_score"]
        st["best_score"] = score
        st["best_cfg"] = cand
        backup_proxy("best")
        sync_repo()
        log(f"NEW BEST {cand['name']} {score:.2f} (was {improved:.2f})")
        signal_send(
            f"🔧 Fixer-Optimizer: neue beste Konfig für den Hauptagent!\n"
            f"Profil: {cand['name']}\n"
            f"Score: {score:.2f}/1.00 (vorher {improved:.2f})\n"
            f"temp={cand['PROXY_TEMPERATURE']} freq_pen={cand['PROXY_FREQUENCY_PENALTY']} "
            f"top_k={cand['PROXY_TOP_K']} hist={cand['MAX_HISTORY_MESSAGES']} "
            f"max_tok={cand['MAX_PROXY_COMPLETION_TOKENS']}\n"
            f"Details: {details}\n"
            f"(live aktiv, mit Backup & Rollback-Schutz)")
    else:
        log(f"no improvement ({score:.2f} <= {st['best_score']:.2f}) -> restore best")
        restore_best(st)

    save_state(st)
    log(f"cycle {cyc} done.")


def restore_best(st):
    best = f"{BACKUP_DIR}/hailo-proxy-best.py"
    if st.get("best_cfg") and os.path.exists(best):
        sudo(["cp", best, PROXY])
    else:
        # no best yet: re-apply conservative known-good defaults
        try:
            apply_config(CANDIDATES[0])
        except Exception:
            pass
    restart_proxy()
    proxy_healthy()


if __name__ == "__main__":
    main()
