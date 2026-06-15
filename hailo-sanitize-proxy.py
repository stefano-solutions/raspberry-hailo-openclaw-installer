#!/usr/bin/env python3
"""
Sanitizing reverse proxy for hailo-ollama.

Sits between OpenClaw and hailo-ollama on port 8000.
Uses OpenAI-compatible /v1/chat/completions endpoint.

Key functions:
1. Strip unsupported request fields (tools, stream_options, store)
2. Replace massive system prompt with minimal one (2048-token context)
3. Force stream:false, convert response to SSE if client requested streaming
4. Fix response: nanosecond timestamps, missing usage/system_fingerprint
5. Fake /api/show to avoid hailo-ollama DTO crash
6. Expose /v1/models for OpenAI-compatible model discovery clients

Listens on port 8081, forwards to hailo-ollama on port 8000.
"""

import http.server
import json
import os
import re
import html
import sys
import time
import itertools
import shlex
import urllib.request
import urllib.error
import urllib.parse
import subprocess

LISTEN_PORT = int(os.environ.get("HAILO_PROXY_PORT", "8081"))
UPSTREAM = "http://127.0.0.1:8000"
DEFAULT_MODEL_ID = os.environ.get("HAILO_MODEL", "qwen2:1.5b")
WORKSPACE_SKILLS_DIR = os.path.expanduser("~/.openclaw/workspace/skills")
MAX_TOOL_DESCRIPTION_CHARS = 120
MAX_TOOL_COUNT_IN_PROMPT = 10
UPSTREAM_TIMEOUT = 300  # seconds — generation is slow (~8 tok/s)
CORS_ALLOWED_ORIGINS = {
    item.strip()
    for item in os.environ.get(
        "HAILO_PROXY_ALLOWED_ORIGINS",
        "http://localhost:8787,http://127.0.0.1:8787",
    ).split(",")
    if item.strip()
}
CORS_ALLOW_NO_ORIGIN = os.environ.get("HAILO_PROXY_ALLOW_NO_ORIGIN", "1").strip().lower() not in {
    "0", "false", "no", "off"
}
CORS_ALLOW_METHODS = "GET, POST, OPTIONS"
CORS_ALLOW_HEADERS = os.environ.get(
    "HAILO_PROXY_CORS_ALLOW_HEADERS",
    "Authorization, Content-Type, X-Requested-With",
)
ALLOWED_HOSTS = {
    item.strip().lower()
    for item in os.environ.get(
        "HAILO_PROXY_ALLOWED_HOSTS",
        "127.0.0.1:8081,localhost:8081,[::1]:8081,127.0.0.1,localhost,[::1]",
    ).split(",")
    if item.strip()
}
ALLOWED_HOSTS.update({
    f"127.0.0.1:{LISTEN_PORT}",
    f"localhost:{LISTEN_PORT}",
    f"[::1]:{LISTEN_PORT}",
})


def _env_int(name, default):
    value = os.environ.get(name)
    if value is None:
        return default
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _env_float(name, default):
    value = os.environ.get(name)
    if value is None:
        return default
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


TRACE_ENABLED = os.environ.get("HAILO_PROXY_TRACE", "1").strip().lower() not in {
    "0", "false", "no", "off"
}
TRACE_DIR = os.environ.get("HAILO_PROXY_TRACE_DIR", "/tmp/hailo-proxy-traces")
TRACE_MAX_BYTES = _env_int("HAILO_PROXY_TRACE_MAX_BYTES", 250000)
# ════════════════════════════════════════════════════════════════════════════
# TUNING — HARTE PARAMETER. Direkt hier im Skript editieren (kein venv, kein env).
# Nach Änderung:  sudo systemctl restart hailo-sanitize-proxy.service
# Verifiziert auf Pi5 + Hailo 5.3.0, qwen3:1.7b. Lokale Hailo-Inferenz ist gratis
# und unbegrenzt; die Token-Caps begrenzen NUR Latenz (~8 tok/s) und verhindern,
# dass kleine 1-2B-Modelle in Wiederhol-Loops kippen.
#
# Unsere Defaults (konservativ, faktenstabil):
#     temperature 0.15 / top_p 0.85 / top_k aus / penalties aus
# Zum Vergleich die jordanskole/hailo-node-Werte (einfach hier eintragen):
#     PROXY_TEMPERATURE=0.7  PROXY_TOP_P=0.8  PROXY_TOP_K=20
#     PROXY_FREQUENCY_PENALTY=1.1  MAX_PROXY_COMPLETION_TOKENS=1024
#     CODE/WEB/DEFAULT_*=1024  MAX_HISTORY_MESSAGES=40
# ────────────────────────────────────────────────────────────────────────────
# Token-Budgets (Output) je Aufgabentyp:
MAX_PROXY_COMPLETION_TOKENS = 1024     # Chat-Obergrenze  [hailo-node]
CODE_PROXY_COMPLETION_TOKENS = 1024    # Code-Obergrenze  [hailo-node]
CODE_MIN_COMPLETION_TOKENS = 384       # Code-Untergrenze (nie weniger)
WEB_PROXY_COMPLETION_TOKENS = 1024     # web-gegroundete Antworten  [hailo-node]
DEFAULT_PROXY_COMPLETION_TOKENS = 1024 # Fallback ohne max_tokens  [hailo-node]
MAX_HISTORY_MESSAGES = 40              # behaltene Verlaufs-Nachrichten  [hailo-node]
MAX_MESSAGE_CONTENT_CHARS = 1200       # max. Zeichen je Nachricht
# Sampling:
PROXY_TEMPERATURE = 0.7                # Standard-Temperatur  [hailo-node]
PROXY_TEMPERATURE_MAX = 0.7            # Deckel, falls Client höher schickt
PROXY_TOP_P = 0.8                      # nucleus sampling  [hailo-node]
PROXY_TOP_K = 20                       # top_k  [hailo-node]
PROXY_FREQUENCY_PENALTY = 1.1          # frequency_penalty  [hailo-node]
PROXY_PRESENCE_PENALTY = 0.0           # 0 = aus
# Feature toggles.
WEB_SEARCH_ENABLED = os.environ.get("HAILO_PROXY_WEB_SEARCH", "1").strip().lower() not in {
    "0", "false", "no", "off"
}
COLLAPSE_REPETITION_ENABLED = os.environ.get(
    "HAILO_PROXY_COLLAPSE_REPETITION", "1"
).strip().lower() not in {"0", "false", "no", "off"}
MODEL_TOKEN_CAPS = {
    "qwen3:1.7b": 1024,
    "qwen2.5-coder:1.5b": 1024,
    "qwen2.5:1.5b": 1024,
    "qwen2:1.5b": 1024,
    "llama3.2:1b": 1024,
    "deepseek_r1:1.5b": 1024,
}
_TRACE_SEQ = itertools.count(1)

MINIMAL_SYSTEM_PROMPT = (
    "You are a helpful personal assistant. "
    "Answer the user's questions concisely and helpfully. "
    "If you don't know something, say so."
)

ALLOWED_CHAT_FIELDS = {
    "model", "messages", "temperature", "top_p", "top_k", "n", "stream",
    "max_tokens", "max_completion_tokens", "presence_penalty",
    "frequency_penalty", "seed", "tools", "tool_choice",
    "parallel_tool_calls",
}
ALLOWED_MESSAGE_FIELDS = {
    "role", "content", "tool_calls", "name", "tool_call_id"
}
TOOL_INTENT_TOKENS = (
    " use ", " tool", "skill", "/rag", "rag ", "molt", "run ", "execute"
)
MEDIA_ATTACHED_MARKER_RE = re.compile(r"\[media attached:[^\]]+\]", re.IGNORECASE)

# Tool-calling strategy (aligned with how small models actually behave):
# `exec` is the only OpenClaw tool a 1.5-1.7B model drives reliably, so instead of
# SILENTLY DROPPING file/listing tool calls (which left raw JSON in the reply and
# looked broken to the user), we REMAP them onto `exec` with a concrete shell
# command. Tools that cannot be expressed as a single shell command are still
# suppressed — but their raw JSON is scrubbed from the content (never shown).
#
# Remappable -> exec:
FILE_READ_TOOL_NAMES = {"read", "view", "open", "cat", "get_file", "readfile"}
LIST_TOOL_NAMES = {"search", "find", "glob", "ls", "list", "list_files", "process"}
# Hard-suppressed (no safe single-command equivalent for a tiny model):
BLOCKED_TOOL_NAMES = {
    "write", "edit", "apply_patch",
    "sessions_list", "sessions_history", "sessions_send",
    "sessions_spawn", "session_status",
}


def _next_trace_id():
    return f"{int(time.time() * 1000)}-{next(_TRACE_SEQ):06d}"


def _ensure_trace_dir():
    if not TRACE_ENABLED:
        return
    try:
        os.makedirs(TRACE_DIR, exist_ok=True)
    except Exception:
        pass


def _parse_json_dict(body_bytes):
    try:
        data = json.loads(body_bytes)
    except Exception:
        return None
    return data if isinstance(data, dict) else None


def _json_preview(value, limit=220):
    try:
        text = json.dumps(value, ensure_ascii=False)
    except Exception:
        text = str(value)
    if len(text) > limit:
        return text[:limit].rstrip() + "..."
    return text


def _summarize_request_body(body_bytes):
    data = _parse_json_dict(body_bytes)
    if data is None:
        return f"non-json body_bytes={len(body_bytes)}"
    keys = sorted(data.keys())
    model = data.get("model")
    stream = data.get("stream")
    max_tokens = data.get("max_tokens")
    max_completion_tokens = data.get("max_completion_tokens")
    msg_count = 0
    role_counts = {}
    content_chars = 0
    if isinstance(data.get("messages"), list):
        msg_count = len(data["messages"])
        for msg in data["messages"]:
            if not isinstance(msg, dict):
                continue
            role = msg.get("role", "unknown")
            role_counts[role] = role_counts.get(role, 0) + 1
            content = msg.get("content", "")
            if isinstance(content, list):
                for part in content:
                    if isinstance(part, dict):
                        content_chars += len(str(part.get("text", "")))
                    else:
                        content_chars += len(str(part))
            else:
                content_chars += len(str(content))
    tools_count = len(data.get("tools", [])) if isinstance(data.get("tools"), list) else 0
    return (
        f"model={model} stream={stream} keys={','.join(keys)} "
        f"messages={msg_count} roles={_json_preview(role_counts, 100)} chars={content_chars} "
        f"max_tokens={max_tokens} max_completion_tokens={max_completion_tokens} tools={tools_count}"
    )


def _summarize_response_body(body_bytes):
    data = _parse_json_dict(body_bytes)
    if data is None:
        return f"non-json body_bytes={len(body_bytes)}"
    choices = data.get("choices") if isinstance(data.get("choices"), list) else []
    content_preview = ""
    if choices and isinstance(choices[0], dict):
        msg = choices[0].get("message")
        if isinstance(msg, dict):
            content_preview = _json_preview(msg.get("content", ""), 140)
        else:
            content_preview = _json_preview(choices[0].get("text", ""), 140)
    usage = data.get("usage") if isinstance(data.get("usage"), dict) else {}
    return (
        f"id={data.get('id')} model={data.get('model')} object={data.get('object')} "
        f"choices={len(choices)} content_preview={content_preview} usage={_json_preview(usage, 140)}"
    )


def _extract_tool_names(body_bytes):
    data = _parse_json_dict(body_bytes)
    if data is None:
        return set()
    tools = data.get("tools")
    if not isinstance(tools, list):
        return set()
    names = set()
    for item in tools:
        if not isinstance(item, dict):
            continue
        if item.get("type") != "function":
            continue
        fn = item.get("function")
        if not isinstance(fn, dict):
            continue
        name = fn.get("name")
        if isinstance(name, str) and name:
            names.add(name)
    return names


def _extract_latest_user_text(body_bytes):
    data = _parse_json_dict(body_bytes)
    if data is None:
        return ""
    messages = data.get("messages")
    if not isinstance(messages, list):
        return ""
    for msg in reversed(messages):
        if not isinstance(msg, dict):
            continue
        if msg.get("role") != "user":
            continue
        content = msg.get("content", "")
        if isinstance(content, list):
            parts = []
            for part in content:
                if isinstance(part, dict):
                    if part.get("type") == "text":
                        parts.append(str(part.get("text", "")))
                elif isinstance(part, str):
                    parts.append(part)
            return "\n".join(parts)
        return str(content)
    return ""


def _has_explicit_tool_intent(text):
    """Decide whether to expose tools to the model for this request.

    The small model needs tools enabled to actually read files / run commands.
    The previous version only matched a handful of literal words (" run ",
    "execute", ...), so natural requests like "Gib mir alle Dateinamen im Ordner
    Downloads" fell through and the model just hallucinated. We now also detect
    filesystem / system-info / shell intent in German and English, plus explicit
    absolute paths. Pure knowledge questions ("Was ist die Hauptstadt?") still
    don't match, so they answer directly without tool noise.
    """
    normalized = f" {str(text or '').strip().lower()} "
    if not normalized.strip():
        return False
    if any(token in normalized for token in TOOL_INTENT_TOKENS):
        return True
    # Filesystem / system / shell intent (substring match is fine here).
    intent_markers = [
        # files & directories (DE)
        "datei", "dateien", "dateiname", "ordner", "verzeichnis", "pfad",
        # files & directories (EN)
        "file", "files", "folder", "directory", "directories", "path ",
        # common locations
        "downloads", "desktop", "dokumente", "documents", "/home", "/etc",
        "/var", "/usr", "/tmp", "~/",
        # list / show / read actions
        "auflisten", "liste alle", "liste mir", "zeig mir", "zeige mir",
        "zeig die", "zeige die", "inhalt von", "inhalt des", "lies ", "lese ",
        "list ", "show me", "read ", "cat ", " ls ",
        # system info
        "speicherplatz", "festplatte", "arbeitsspeicher", "speicher frei",
        "wieviel speicher", "wie viel speicher", "prozesse", "systeminfo",
        "system info", "disk space", "free memory", "uptime", "cpu-last",
        "cpu last", "auslastung",
        # shell / command
        "befehl", "kommando", "shell", "terminal", "bash", "skript ausführen",
        "command", "run command",
    ]
    if any(m in normalized for m in intent_markers):
        return True
    # An absolute or home path anywhere in the text strongly implies file ops.
    if re.search(r"(^|\s)(/[a-zA-Z0-9._-]+){2,}", str(text or "")):
        return True
    return False


def model_token_cap(model_id):
    key = str(model_id or "").strip().lower()
    return MODEL_TOKEN_CAPS.get(key, MAX_PROXY_COMPLETION_TOKENS)


def _write_trace(trace_id, suffix, body_bytes):
    if not TRACE_ENABLED:
        return
    _ensure_trace_dir()
    try:
        payload = body_bytes if isinstance(body_bytes, (bytes, bytearray)) else str(body_bytes).encode("utf-8", errors="replace")
        if len(payload) > TRACE_MAX_BYTES:
            marker = (
                f"\n\n...TRUNCATED... original_bytes={len(payload)} limit={TRACE_MAX_BYTES}\n"
            ).encode("utf-8")
            payload = payload[:TRACE_MAX_BYTES] + marker
        path = os.path.join(TRACE_DIR, f"{trace_id}-{suffix}")
        with open(path, "wb") as f:
            f.write(payload)
    except Exception:
        pass


def normalize_message_content(content):
    """Normalize mixed content so upstream text model won't crash on media markers."""
    if isinstance(content, list):
        parts = []
        for part in content:
            if isinstance(part, dict):
                part_type = str(part.get("type", "")).strip().lower()
                if part_type == "text":
                    parts.append(str(part.get("text", "")))
            elif isinstance(part, str):
                parts.append(part)
        text = " ".join(p for p in parts if p)
        text = MEDIA_ATTACHED_MARKER_RE.sub("", text)
        # Replace newlines with spaces to avoid JSON serialization issues
        return " ".join(line.strip() for line in text.splitlines() if line.strip()).strip()
    text = str(content or "")
    text = MEDIA_ATTACHED_MARKER_RE.sub("", text)
    # Replace newlines with spaces to avoid JSON serialization issues
    return " ".join(line.strip() for line in text.splitlines() if line.strip()).strip()


def clean_user_query(text):
    """Recover the real user question from OpenClaw channel-wrapped content.

    Inbound channel messages (Signal, etc.) arrive wrapped with metadata, e.g.
        [Sun 2026-06-14 13:05 GMT+2] Conversation info (untrusted metadata):
        ```json { "chat_id": "+49..." } ``` Sender (untrusted metadata):
        ```json { "name": "Stefan" } ``` Such mir die heutigen WM Spiele raus
    Feeding that whole blob to Google News returns nothing, so the web-search
    grounding never fires. Strip the wrappers down to the actual question.
    """
    t = str(text or "")
    # Remove fenced code blocks (```json ... ``` metadata payloads).
    t = re.sub(r"```.*?```", " ", t, flags=re.DOTALL)
    # Remove "... (untrusted metadata):" labels.
    t = re.sub(r"(?i)\b\w[\w ]*\(untrusted metadata\)\s*:", " ", t)
    # Remove leading [timestamp] markers like [Sun 2026-06-14 13:05 GMT+2].
    t = re.sub(r"\[[^\]]*\b\d{4}\b[^\]]*\]", " ", t)
    # Collapse whitespace.
    t = re.sub(r"\s+", " ", t).strip()
    return t or str(text or "").strip()


def is_code_task(user_message):
    """Detect programming/code-generation requests.

    Such tasks need a higher token budget than chat (a small class easily
    exceeds 192 tokens) and must never be web-grounded. Structured code is far
    less prone to the prose repetition loops that justify the tight default cap.
    """
    text = str(user_message or "").lower()
    markers = [
        "schreib", "programmier", "code", "coden", "funktion", "function",
        "python", "javascript", " java", "bash", "skript", "script",
        "schleife", "loop", "klasse", "class ", "algorithm", "algorithmus",
        "refactor", "debug", "def ", "html", "css", "sql", "regex",
        "json", "yaml", "api", "methode", "method",
    ]
    return any(m in text for m in markers)


def should_trigger_web_search(user_message):
    """Decide if a message genuinely needs a live web lookup.

    Precision matters far more than recall here: a false positive injects
    irrelevant search snippets plus a "say you found nothing" instruction,
    which derails NORMAL tasks (coding, writing, math) on the tiny model.

    Strategy:
      1. Hard NEGATIVE guard: never web-search creation/coding/translation
         tasks, even if they happen to contain a stray keyword.
      2. Require EXPLICIT research intent: either a research phrase
         ("im internet", "recherche", "suche ... nach") or a current-events /
         live-data keyword matched on WORD BOUNDARIES (not as a substring).
    """
    text = str(user_message or "").lower()
    if not text.strip():
        return False

    # 1) Negative guard: imperative creation / coding / transformation tasks.
    # These must be answered by the model itself, never grounded on web data.
    negative_markers = [
        "schreib", "programmier", "code", "coden", "funktion", "function",
        "python", "javascript", "java", "bash", "skript", "script",
        "schleife", "loop", "klasse", "class", "algorithm", "algorithmus",
        "refactor", "debug", "erklär", "explain", "übersetz", "translate",
        "fasse zusammen", "summarize", "rechne", "berechne", "calculate",
        "gedicht", "geschichte", "story", "poem", "essay",
    ]
    if any(m in text for m in negative_markers):
        return False

    # 2a) Explicit research phrases (strongest signal).
    research_phrases = [
        "im internet", "im netz", "online such", "recherch", "google",
        "such im", "suche im", "such das im", "suche das im", "such nach",
        "suche nach", "such mir", "such mal", "schau nach", "find heraus",
        "finde heraus", "search the web", "search online", "look up",
    ]
    if any(p in text for p in research_phrases):
        return True

    # 2b) Current-events / live-data keywords, matched on word boundaries so
    # "neu" no longer fires on "neue Funktion" and "now" not on "knowledge".
    live_keywords = [
        "wm", "fifa", "fußball", "fussball", "spielplan", "ergebnis",
        "ergebnisse", "today", "heute", "aktuell", "aktuelle", "aktuellen",
        "latest", "nachrichten", "news", "schlagzeile", "schlagzeilen",
        "wetter", "weather", "kurs", "preis", "preise", "price", "kosten",
        "börse", "boerse", "wechselkurs", "wer gewinnt", "wer spielt",
        "was spielt", "who plays", "live",
    ]
    for kw in live_keywords:
        if re.search(r"\b%s\b" % re.escape(kw), text):
            return True
    return False


_SEARCH_UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
    "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"
)


def _search_duckduckgo(query):
    """General web search via the DuckDuckGo Lite endpoint (no API key).

    Returns real result snippets (actual page text) for ANY topic - weather,
    sports, prices, facts - not just news headlines. The Lite endpoint accepts a
    POST form and returns plain result rows that are easy to parse and, unlike
    the JS/html.duckduckgo.com endpoints, does not bot-challenge simple clients.
    """
    data = urllib.parse.urlencode({"q": query}).encode("utf-8")
    req = urllib.request.Request(
        "https://lite.duckduckgo.com/lite/",
        data=data,
        headers={
            "User-Agent": _SEARCH_UA,
            "Referer": "https://lite.duckduckgo.com/",
            "Content-Type": "application/x-www-form-urlencoded",
        },
    )
    with urllib.request.urlopen(req, timeout=12) as response:
        page = response.read().decode("utf-8", "ignore")

    def _clean(raw):
        return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", raw))).strip()

    titles = [_clean(t) for t in re.findall(r'class=["\']result-link["\'][^>]*>(.*?)</a>', page, re.S)]
    snippets = [_clean(s) for s in re.findall(r'class=["\']result-snippet["\'][^>]*>(.*?)</td>', page, re.S)]

    items = []
    for i, snip in enumerate(snippets):
        if not snip:
            continue
        title = titles[i] if i < len(titles) else ""
        # Title + snippet gives the model both the source label and real facts.
        entry = ("%s: %s" % (title, snip)).strip(": ") if title else snip
        if entry and entry not in items:
            items.append(entry)
        if len(items) >= 4:
            break
    if not items:
        return None
    return " | ".join(items)[:700]


def _search_google_news(query):
    """Fallback: Google News RSS headlines (used only if DDG returns nothing)."""
    url = (
        "https://news.google.com/rss/search?q="
        + urllib.parse.quote(query)
        + "&hl=de&gl=DE&ceid=DE:de"
    )
    req = urllib.request.Request(url, headers={"User-Agent": _SEARCH_UA})
    with urllib.request.urlopen(req, timeout=10) as response:
        xml = response.read().decode("utf-8", "ignore")
    titles = re.findall(r"<title>(.*?)</title>", xml, re.DOTALL)
    items = []
    for raw in titles[1:8]:  # first <title> is the feed name
        value = html.unescape(re.sub(r"<[^>]+>", " ", raw)).strip()
        if not value or value.lower() == "google news":
            continue
        value = re.sub(r"\s*[-\u2013]\s*[^-\u2013]{2,30}$", "", value).strip()
        if value and value not in items:
            items.append(value)
        if len(items) >= 5:
            break
    if not items:
        return None
    return " | ".join(items)[:500]


def perform_web_search(query):
    """Run a general web search and return real grounding text for any query.

    Primary source is DuckDuckGo Lite (real result snippets for every topic).
    Google News RSS is only a fallback when DDG yields nothing. The search must
    never crash the proxy, so all errors degrade to None.
    """
    for source in (_search_duckduckgo, _search_google_news):
        try:
            result = source(query)
            if result:
                return result
        except Exception as exc:  # noqa: BLE001 - search must never crash the proxy
            sys.stderr.write(
                "hailo-proxy: web search (%s) failed: %s\n" % (source.__name__, exc)
            )
            sys.stderr.flush()
    return None

def sanitize_chat_body(body_bytes, tool_prompt_enabled=True):
    """Strip unsupported fields from /v1/chat/completions request."""
    try:
        data = json.loads(body_bytes)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return body_bytes
    if not isinstance(data, dict):
        return body_bytes

    sanitized = {
        k: v for k, v in data.items() if k in ALLOWED_CHAT_FIELDS and v is not None
    }
    tools_payload = sanitized.pop("tools", None)
    clean_query = ""
    if not tool_prompt_enabled:
        tools_payload = None
    if tools_payload is not None:
        try:
            with open("/tmp/hailo-proxy-tools.json", "w", encoding="utf-8") as f:
                json.dump(tools_payload, f, indent=2)
        except Exception:
            pass

    if "messages" in sanitized and isinstance(sanitized["messages"], list):
        clean_msgs = []
        for msg in sanitized["messages"]:
            if not isinstance(msg, dict):
                continue
            clean_msg = {k: v for k, v in msg.items() if k in ALLOWED_MESSAGE_FIELDS}
            clean_msg["content"] = normalize_message_content(clean_msg.get("content"))
            clean_msgs.append(clean_msg)
        sanitized["messages"] = clean_msgs
        
        # Trigger web search if user asks for research
        web_search_injected = False
        if clean_msgs:
            last_user_msg = None
            for msg in reversed(clean_msgs):
                if msg.get("role") == "user":
                    last_user_msg = msg.get("content", "")
                    break
            
            if last_user_msg:
                # Strip channel metadata wrappers FIRST (timestamps, JSON blobs),
                # then decide on web search. Otherwise the metadata timestamp
                # ("[Sun 2026-...]") would trigger a search on EVERY message.
                clean_query = clean_user_query(last_user_msg)
            else:
                clean_query = ""

            if WEB_SEARCH_ENABLED and clean_query and should_trigger_web_search(clean_query):
                search_result = perform_web_search(clean_query)
                if search_result:
                    sys.stderr.write(
                        "hailo-proxy: web search result: %s\n" % search_result[:120]
                    )
                    sys.stderr.flush()
                    # Inject as a fresh user turn that both supplies the live data
                    # AND instructs the model to answer from it (the small model
                    # otherwise replies "can only be looked up online").
                    grounding = (
                        "AKTUELLE INTERNET-DATEN (heute abgerufen) zu meiner Frage "
                        "\"%s\": %s. "
                        "Beantworte meine Frage in HOECHSTENS 3 kurzen Saetzen, "
                        "ausschliesslich auf Basis dieser Daten. Nenne nur "
                        "konkrete Fakten (Namen, Zahlen, Daten) und KEINE "
                        "Wiederholungen. Erfinde NICHTS: Wenn die Daten die "
                        "konkrete Antwort NICHT enthalten, sage genau einen Satz: "
                        "'Dazu finde ich aktuell keine konkreten Angaben.' und fasse "
                        "danach kurz die relevanten Daten zusammen. Sage NICHT, dass "
                        "man es online nachschlagen muss."
                    ) % (clean_query, search_result)
                    clean_msgs.append({"role": "user", "content": grounding})
                    web_search_injected = True
        
        sanitized["messages"] = clean_msgs

    sanitized["stream"] = False

    max_tokens = sanitized.get("max_tokens")
    max_completion_tokens = sanitized.get("max_completion_tokens")
    if isinstance(max_tokens, int) and max_tokens > 0:
        requested_tokens = max_tokens
    elif isinstance(max_completion_tokens, int) and max_completion_tokens > 0:
        requested_tokens = max_completion_tokens
    else:
        requested_tokens = DEFAULT_PROXY_COMPLETION_TOKENS

    # OpenClaw occasionally sends max_tokens=1 for local providers. On Hailo this
    # hard-truncates every reply to a single token ("I", "ACT", ...). Promote this
    # pathological value to a sensible default while still capping upper bounds.
    if requested_tokens <= 1:
        requested_tokens = DEFAULT_PROXY_COMPLETION_TOKENS

    model_id = sanitized.get("model")
    per_model_cap = model_token_cap(model_id)
    proxy_cap = MAX_PROXY_COMPLETION_TOKENS
    # Coding tasks need more room so functions/classes aren't truncated. Raise
    # BOTH the per-model and the global proxy ceiling, and apply a sensible
    # floor so a stingy client max_tokens can't truncate code either.
    if is_code_task(clean_query):
        proxy_cap = CODE_PROXY_COMPLETION_TOKENS
        per_model_cap = max(per_model_cap, CODE_PROXY_COMPLETION_TOKENS)
        requested_tokens = max(requested_tokens, CODE_MIN_COMPLETION_TOKENS)
    sanitized["max_tokens"] = min(requested_tokens, per_model_cap, proxy_cap)
    # Web-grounded answers: the useful fact is in the first 1-2 sentences. Cap
    # tighter so the small model stops before it degenerates into number loops
    # ("1. Halbzeit, 2., 3., ..."). collapse_repetition cleans the rest.
    if web_search_injected:
        sanitized["max_tokens"] = min(sanitized["max_tokens"], WEB_PROXY_COMPLETION_TOKENS)
    sanitized.pop("max_completion_tokens", None)

    if isinstance(sanitized.get("n"), int) and sanitized["n"] > 1:
        sanitized["n"] = 1

    temperature = sanitized.get("temperature")
    if not isinstance(temperature, (int, float)):
        temperature = PROXY_TEMPERATURE
    sanitized["temperature"] = max(0.0, min(float(temperature), PROXY_TEMPERATURE_MAX))

    top_p = sanitized.get("top_p")
    if not isinstance(top_p, (int, float)):
        top_p = PROXY_TOP_P
    sanitized["top_p"] = max(0.7, min(float(top_p), 0.95))

    # Optionale Sampling-Regler (harte Parameter oben; 0 = aus, nicht senden).
    if PROXY_TOP_K > 0:
        sanitized["top_k"] = PROXY_TOP_K
    if PROXY_FREQUENCY_PENALTY:
        sanitized["frequency_penalty"] = PROXY_FREQUENCY_PENALTY
    if PROXY_PRESENCE_PENALTY:
        sanitized["presence_penalty"] = PROXY_PRESENCE_PENALTY

    if "messages" in sanitized:
        tool_prompt = build_tool_prompt(tools_payload)
        sanitized["messages"] = simplify_messages(sanitized["messages"], tool_prompt)

    return json.dumps(sanitized).encode("utf-8")


def simplify_messages(messages, tool_prompt=None):
    """Replace OpenClaw's massive system prompt with a minimal one."""
    if not messages:
        return messages
    # Keep conversational context. We also preserve TOOL RESULTS: when the model
    # emits a tool call, OpenClaw executes it and sends the result back as a
    # role="tool" message. Small Hailo models don't understand the tool role, so
    # we fold each result into a plain user message ("Werkzeug-Ergebnis ...") and
    # render assistant tool-call turns as short text, so the model can read the
    # data and answer. Without this the file listing would never reach the model.
    converted = []
    for m in messages:
        role = m.get("role")
        if role == "tool":
            result = str(m.get("content", "")).strip()
            if result:
                converted.append({
                    "role": "user",
                    "content": "Werkzeug-Ergebnis: " + result
                    + " | Beantworte damit meine vorige Frage in kurzen Saetzen, "
                    "ohne erneut ein Werkzeug aufzurufen.",
                })
        elif role == "assistant":
            content = str(m.get("content", "") or "").strip()
            if not content and m.get("tool_calls"):
                # Pure tool-call turn: summarise so the conversation stays coherent.
                try:
                    calls = m.get("tool_calls") or []
                    names = ", ".join(
                        c.get("function", {}).get("name", "?") for c in calls
                    )
                    content = "(Werkzeug aufgerufen: %s)" % names
                except Exception:
                    content = "(Werkzeug aufgerufen)"
            if content:
                converted.append({"role": "assistant", "content": content})
        elif role == "user":
            converted.append({"role": "user", "content": str(m.get("content", ""))})

    convo_msgs = converted
    if len(convo_msgs) > MAX_HISTORY_MESSAGES:
        convo_msgs = convo_msgs[-MAX_HISTORY_MESSAGES:]
    # Avoid starting context with an assistant reply that has no user prompt.
    while convo_msgs and convo_msgs[0].get("role") == "assistant":
        convo_msgs = convo_msgs[1:]
    other_msgs = []
    for msg in convo_msgs:
        content = str(msg.get("content", ""))
        if len(content) > MAX_MESSAGE_CONTENT_CHARS:
            content = content[-MAX_MESSAGE_CONTENT_CHARS:]
        other_msgs.append({"role": msg.get("role"), "content": content})
    original_sys_msgs = [m.get("content", "") for m in messages if m.get("role") == "system"]
    original_sys_len = sum(len(c) for c in original_sys_msgs)
    if original_sys_len > len(MINIMAL_SYSTEM_PROMPT):
        sys.stderr.write(
            "hailo-sanitize-proxy: replaced system prompt (%d -> %d chars)\n"
            % (original_sys_len, len(MINIMAL_SYSTEM_PROMPT))
        )
        sys.stderr.flush()
        if original_sys_msgs:
            dump_path = "/tmp/hailo-proxy-system-prompt.txt"
            try:
                with open(dump_path, "w", encoding="utf-8") as f:
                    f.write("\n\n".join(original_sys_msgs))
            except Exception:
                pass
    system_content = MINIMAL_SYSTEM_PROMPT
    skills_block = build_skills_block_from_workspace()
    if tool_prompt:
        system_content = f"{system_content}\n\n{tool_prompt}"
    if skills_block:
        system_content = f"{system_content}\n\nAvailable skills:\n{skills_block}"
    # CRITICAL: hailo-ollama's GenAI template crashes (HTTP 500 "Failed to
    # generate") on raw newlines inside a system message. Flatten to single
    # line with " | " separators; the JSON tool examples contain no internal
    # newlines so they survive intact.
    system_content = _flatten_for_hailo(system_content)
    try:
        with open("/tmp/hailo-proxy-sanitized-system-prompt.txt", "w", encoding="utf-8") as f:
            f.write(system_content)
    except Exception:
        pass
    # Hailo constraint: system messages only allowed on first prompt (no continuations)
    # If other_msgs has history (>1 message), don't include system message
    is_continuation = len(other_msgs) > 1

    # Has a tool already run in this conversation? (converted results are tagged.)
    def _is_tool_result(msg):
        return (
            msg.get("role") == "user"
            and str(msg.get("content", "")).startswith("Werkzeug-Ergebnis:")
        )

    has_tool_result = any(_is_tool_result(m) for m in other_msgs)

    if is_continuation:
        if has_tool_result:
            # A tool already executed. RE-INJECTING the "call a tool" prompt here is
            # what caused infinite tool loops: the small model always obeys the most
            # recent instruction, so it kept calling tools instead of answering.
            # Instead, surface the latest tool result as the FINAL, most salient
            # message with a firm "answer now, do not call another tool" directive.
            last_idx = None
            for i in range(len(other_msgs) - 1, -1, -1):
                if _is_tool_result(other_msgs[i]):
                    last_idx = i
                    break
            if last_idx is not None:
                result_msg = other_msgs.pop(last_idx)
                raw = result_msg["content"]
                # Drop any previously appended instruction, keep just the data.
                data = raw.split(" | Beantworte", 1)[0]
                data = data[len("Werkzeug-Ergebnis:"):].strip()
                other_msgs.append({
                    "role": "user",
                    "content": _flatten_for_hailo(
                        "Werkzeug-Ergebnis: " + data
                        + " | Das ist das Ergebnis des Werkzeugs. Beantworte damit "
                        "JETZT die urspruengliche Frage des Nutzers in kurzen Saetzen. "
                        "Rufe KEIN weiteres Werkzeug auf und gib KEIN JSON aus."
                    ),
                })
            return other_msgs
        # No tool has run yet: keep tool access alive on continuations by
        # re-injecting a compact tool instruction into the LAST user message.
        if tool_prompt and other_msgs:
            flat_tool_prompt = _flatten_for_hailo(tool_prompt)
            for i in range(len(other_msgs) - 1, -1, -1):
                if other_msgs[i].get("role") == "user":
                    other_msgs[i] = {
                        "role": "user",
                        "content": flat_tool_prompt + " | " + other_msgs[i]["content"],
                    }
                    break
        return other_msgs
    return [{"role": "system", "content": system_content}] + other_msgs


def _flatten_for_hailo(text):
    """Collapse newlines to ' | ' so hailo-ollama's template doesn't crash.

    The Hailo GenAI chat template returns HTTP 500 ("Failed to generate") when a
    message contains raw newline characters. We join lines with a visible
    separator that preserves structure for the model while staying single-line.
    """
    if not text:
        return text
    return " | ".join(
        line.strip() for line in str(text).splitlines() if line.strip()
    ).strip()


def build_tool_prompt(tools_payload):
    if not tools_payload or not isinstance(tools_payload, list):
        return ""
    # Collect available tool names so we only advertise capabilities that exist.
    available = set()
    for tool in tools_payload:
        if isinstance(tool, dict) and tool.get("type") == "function":
            fn = tool.get("function", {})
            if fn.get("name"):
                available.add(fn["name"])

    lines = [
        "WERKZEUGE / TOOLS: Du laeufst auf einem Raspberry Pi und hast ECHTEN "
        "Zugriff auf das Dateisystem und die Shell ueber die unten gelisteten "
        "Werkzeuge. Sage NIEMALS, dass du keinen Zugriff auf Dateien oder das "
        "System hast - rufe stattdessen das passende Werkzeug auf.",
        "",
        "So rufst du ein Werkzeug auf - antworte mit GENAU EINER Zeile JSON und "
        "sonst NICHTS:",
        '  {"tool": "<name>", "arguments": { ... }}',
        "",
    ]
    # Concrete, high-value examples for the most common filesystem tasks. Only
    # show examples for tools that are actually available.
    examples = []
    if "exec" in available:
        examples.append(
            'Frage "Welche Dateien sind in /home/pi/Downloads?" '
            '-> {"tool": "exec", "arguments": {"command": "ls -1 /home/pi/Downloads"}}'
        )
        examples.append(
            'Frage "Wie viel Speicher ist frei?" '
            '-> {"tool": "exec", "arguments": {"command": "df -h"}}'
        )
    if "read" in available:
        examples.append(
            'Frage "Zeige den Inhalt von /etc/hostname" '
            '-> {"tool": "read", "arguments": {"file_path": "/etc/hostname"}}'
        )
    if examples:
        lines.append("BEISPIELE:")
        lines.extend("  " + e for e in examples)
        lines.append("")
    lines.append("REGEL: Bei Fragen zu Dateien, Ordnern, Verzeichnissen, "
                 "Systeminfo, Prozessen oder dem Ausfuehren von Befehlen MUSST "
                 "du ein Werkzeug aufrufen. Bei normalen Wissensfragen antworte "
                 "direkt ohne Werkzeug.")
    lines.append("")
    lines.append("Verfuegbare Werkzeuge:")
    # Prioritise the high-value filesystem/shell tools so they survive the
    # MAX_TOOL_COUNT_IN_PROMPT truncation (OpenClaw sends ~27 tools).
    priority = ["exec", "read", "write", "edit", "process", "web_search", "web_fetch"]
    func_tools = [
        t for t in tools_payload
        if isinstance(t, dict) and t.get("type") == "function"
        and t.get("function", {}).get("name")
    ]
    func_tools.sort(
        key=lambda t: priority.index(t["function"]["name"])
        if t["function"]["name"] in priority else len(priority)
    )
    tool_count = 0
    for tool in func_tools:
        fn = tool.get("function", {})
        name = fn.get("name")
        desc = fn.get("description", "").strip().replace("\n", " ")
        if len(desc) > MAX_TOOL_DESCRIPTION_CHARS:
            desc = desc[:MAX_TOOL_DESCRIPTION_CHARS].rstrip() + "..."
        params = fn.get("parameters", {})
        props = params.get("properties", {}) if isinstance(params, dict) else {}
        args = ", ".join(sorted(props.keys())) if isinstance(props, dict) else ""
        label = f"- {name}"
        if desc:
            label += f": {desc}"
        if args:
            label += f" (args: {args})"
        lines.append(label)
        tool_count += 1
        if tool_count >= MAX_TOOL_COUNT_IN_PROMPT:
            lines.append("- ...")
            break
    return "\n".join(lines)


def extract_skills_block(system_text):
    if not system_text:
        return ""
    match = re.search(r"<available_skills>(.*?)</available_skills>", system_text, re.DOTALL)
    if not match:
        return ""
    block = match.group(1).strip()
    if not block:
        return ""
    return block


def build_skills_block_from_workspace():
    if not os.path.isdir(WORKSPACE_SKILLS_DIR):
        return ""
    skills = []
    for entry in sorted(os.listdir(WORKSPACE_SKILLS_DIR)):
        skill_dir = os.path.join(WORKSPACE_SKILLS_DIR, entry)
        skill_md = os.path.join(skill_dir, "SKILL.md")
        if not os.path.isfile(skill_md):
            continue
        name = None
        desc = ""
        try:
            with open(skill_md, "r", encoding="utf-8") as f:
                lines = f.read().splitlines()
            if lines and lines[0].strip() == "---":
                for line in lines[1:]:
                    if line.strip() == "---":
                        break
                    if line.startswith("name:"):
                        name = line.split(":", 1)[1].strip()
                    elif line.startswith("description:"):
                        desc = line.split(":", 1)[1].strip()
        except Exception:
            continue
        if not name:
            name = entry
        skills.append({
            "name": name,
            "description": desc,
            "location": skill_md,
        })
    if not skills:
        return ""
    parts = ["<available_skills>"]
    for skill in skills:
        parts.append("  <skill>")
        parts.append(f"    <name>{skill['name']}</name>")
        if skill["description"]:
            parts.append(f"    <description>{skill['description']}</description>")
        parts.append(f"    <location>{skill['location']}</location>")
        parts.append("  </skill>")
    parts.append("</available_skills>")
    return "\n".join(parts)


def parse_tool_call(content, allowed_names=None):
    if not content or not isinstance(content, str):
        return None
    raw = content.strip()
    if raw.startswith("```"):
        raw = raw.strip("`")
        raw = raw.replace("json", "", 1).strip()

    payload = None
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        start = raw.find("{")
        if start != -1:
            depth = 0
            end = -1
            for idx, ch in enumerate(raw[start:], start=start):
                if ch == "{":
                    depth += 1
                elif ch == "}":
                    depth -= 1
                    if depth == 0:
                        end = idx + 1
                        break
            if end != -1:
                candidate = raw[start:end]
                try:
                    payload = json.loads(candidate)
                except json.JSONDecodeError:
                    return None
            else:
                return None
        else:
            name_match = re.search(
                r'"(?:tool|name|tool_name|skill)"\s*:\s*"([^"]+)"', raw
            )
            if not name_match:
                return None
            payload = {"tool": name_match.group(1), "arguments": {}}

            command_match = re.search(r'"command"\s*:\s*"([^"]+)"', raw)
            file_path_match = re.search(
                r'"(?:file_path|path)"\s*:\s*"([^"]+)"', raw
            )
            message_match = re.search(r'"message"\s*:\s*"([^"]+)"', raw)
            session_key_match = re.search(r'"sessionKey"\s*:\s*"([^"]+)"', raw)

            if command_match:
                payload["arguments"]["command"] = command_match.group(1)
            if file_path_match:
                payload["arguments"]["file_path"] = file_path_match.group(1)
            if message_match:
                payload["arguments"]["message"] = message_match.group(1)
            if session_key_match:
                payload["arguments"]["sessionKey"] = session_key_match.group(1)
    if not isinstance(payload, dict):
        return None
    name = payload.get("tool") or payload.get("name") or payload.get("tool_name") or payload.get("skill")
    args = payload.get("arguments") or payload.get("args") or {}
    if not name:
        return None
    if allowed_names is not None and name not in allowed_names:
        try:
            sys.stderr.write(
                "hailo-sanitize-proxy: forwarding unknown tool name from model: %s\n"
                % name
            )
            sys.stderr.flush()
        except Exception:
            pass
    if not isinstance(args, dict):
        return None
    return {"name": name, "arguments": args}


def normalize_exec_command(command):
    if not isinstance(command, str):
        return ""
    cmd = command.strip()
    if cmd.startswith(". "):
        cmd = cmd[2:].strip()
    if cmd.endswith(".py") and not cmd.startswith("python"):
        cmd = f"python3 {cmd}"
    return cmd


def _normalize_fs_path(path):
    """Best-effort cleanup of model-written paths (e.g. 'Home/pi/Downloads')."""
    if not isinstance(path, str):
        return ""
    p = path.strip().strip('"').strip("'")
    if not p:
        return ""
    if p.startswith("~"):
        return os.path.expanduser(p)
    # Model frequently writes 'Home/pi/...' / 'home/pi/...' without a leading slash.
    if p.lower().startswith("home/"):
        p = "/home/" + p[5:]
    return p


def _looks_like_dir(path, user_text):
    """Heuristic: does the user want a directory listing rather than file contents?"""
    p = (path or "").rstrip("/")
    base = os.path.basename(p).lower()
    # A trailing slash is an explicit directory marker.
    if (path or "").rstrip().endswith("/"):
        return True
    # A real file extension on the last segment → treat as a file (cat), even if
    # the prompt mentions "Inhalt"/"content".
    has_ext = "." in base and not base.startswith(".")
    if has_ext:
        return False
    txt = str(user_text or "").lower()
    listing_words = (
        "dateinamen", "dateien", "ordner", "verzeichnis", "übersicht", "uebersicht",
        "filenames", "files", "folder", "directory", "list", "liste", "auflist",
    )
    if any(w in txt for w in listing_words):
        return True
    # No extension and no listing hint → still most likely a directory path.
    return True


def remap_tool_call(tool_call, latest_user_text, allowed_tool_names):
    """Normalize/translate a parsed tool call.

    Returns (tool_call_or_None, suppressed_bool). When suppressed_bool is True the
    caller must scrub the raw JSON from the assistant content so the user never
    sees a broken tool-call block.
    """
    if not tool_call or not isinstance(tool_call, dict):
        return tool_call, False

    name = tool_call.get("name")
    args = tool_call.get("arguments") if isinstance(tool_call.get("arguments"), dict) else {}

    # exec: pass through, just normalize the command string.
    if name == "exec":
        cmd = normalize_exec_command(args.get("command", ""))
        if cmd:
            tool_call["arguments"] = {"command": cmd}
        return tool_call, False

    # If OpenClaw didn't even offer exec, we can't remap — fall through to block.
    exec_available = (allowed_tool_names is None) or ("exec" in allowed_tool_names)

    path = (
        args.get("path") or args.get("file_path") or args.get("filepath")
        or args.get("dir") or args.get("directory") or args.get("target") or ""
    )
    path = _normalize_fs_path(path)

    # read/view/open/cat → exec (ls for directories, cat for files).
    if name in FILE_READ_TOOL_NAMES and path and exec_available:
        if _looks_like_dir(path, latest_user_text):
            cmd = "ls -1 %s" % shlex.quote(path)
        else:
            cmd = "cat %s" % shlex.quote(path)
        return {"name": "exec", "arguments": {"command": cmd}}, False

    # search/find/glob/process → exec (grep when a pattern is given, else ls).
    if name in LIST_TOOL_NAMES and exec_available:
        pattern = args.get("pattern") or args.get("query") or args.get("q") or ""
        target = path or "."
        if isinstance(pattern, str) and pattern.strip():
            cmd = "grep -rn %s %s" % (shlex.quote(pattern.strip()), shlex.quote(target))
        else:
            cmd = "ls -1 %s" % shlex.quote(target)
        return {"name": "exec", "arguments": {"command": cmd}}, False

    # Hard-suppressed tools: drop the call AND signal a content scrub.
    if name in BLOCKED_TOOL_NAMES:
        try:
            sys.stderr.write(
                "hailo-sanitize-proxy: suppressing blocked tool call: %s\n" % name
            )
            sys.stderr.flush()
        except Exception:
            pass
        return None, True

    # Unknown/other tool the model offered: let it through unchanged.
    return tool_call, False


def _has_rag_intent(text):
    norm = str(text or "").lower()
    return "rag" in norm


def _collapse_prose(text):
    """De-duplicate run-away repeated sentences/phrases in a prose segment.

    Preserves newlines so lists ("1. ...\n2. ...") and paragraphs keep their
    structure. Only consecutive/duplicate sentence content is removed.
    """
    # Process line by line so newlines (lists, paragraphs) survive.
    out_lines = []
    seen = set()
    for line in text.split("\n"):
        # Split a line into sentence-like chunks for de-duplication.
        parts = re.split(r"(?<=[.!?])\s+", line.strip())
        kept = []
        for part in parts:
            norm = re.sub(r"\s+", " ", part.strip().lower())
            norm = re.sub(r"[^\w ]", "", norm)
            if not norm:
                if part.strip():
                    kept.append(part.strip())
                continue
            if norm in seen:
                continue
            seen.add(norm)
            kept.append(part.strip())
        out_lines.append(" ".join(kept))
    result = "\n".join(out_lines)
    # Collapse immediate repeated word groups within a line, tolerating
    # whitespace OR punctuation separators ("die WM, die WM, die WM").
    result = re.sub(r"(.{3,50}?)(?:[ \t,;:.\u2013-]+\1){2,}", r"\1", result)
    # Collapse runaway enumerations like "M1, M2, M3, ... M28" to first 3 items.
    enum = re.search(r"((?:[A-Za-z]?\d+,\s*){5,})", result)
    if enum:
        head = ", ".join(enum.group(1).split(",")[:3]).strip().rstrip(",")
        result = result[:enum.start()] + head + " usw." + result[enum.end():]
    # Squash 3+ blank lines down to a single blank line.
    result = re.sub(r"\n{3,}", "\n\n", result)
    return result.strip()


def collapse_repetition(text):
    """Remove run-away repeated sentences/phrases from small-model output.

    The 1.x-2B Hailo models frequently degenerate into loops such as
    "Die Tuerkei spielt heute. Die Tuerkei spielt heute. ...". This collapses
    consecutive duplicate (or near-duplicate) sentences and immediate phrase
    repetitions so the user gets a clean answer.

    CRITICAL: fenced code blocks (```...```) and their newlines are preserved
    verbatim. The previous version rejoined everything with single spaces,
    which destroyed indentation and made every emitted Python/JS snippet
    invalid. We now only de-duplicate the PROSE segments and never touch the
    bytes inside code fences.
    """
    if not text or not isinstance(text, str):
        return text

    # Split on fenced code blocks, keeping the fences. Odd indices are code.
    # An UNCLOSED fence (model truncated mid-code) would otherwise be treated as
    # prose and get its indentation stripped — guard against that by closing a
    # dangling opening fence at end-of-text first.
    if text.count("```") % 2 == 1:
        text = text + "\n```"
    segments = re.split(r"(```.*?```)", text, flags=re.DOTALL)
    rebuilt = []
    for i, seg in enumerate(segments):
        if i % 2 == 1:
            # Code block: pass through untouched (preserve all newlines/indent).
            # Guarantee the opening/closing fences sit on their own line so
            # Markdown renders the block correctly.
            if rebuilt and not rebuilt[-1].endswith("\n"):
                rebuilt.append("\n")
            rebuilt.append(seg)
            rebuilt.append("\n")
        else:
            rebuilt.append(_collapse_prose(seg) if seg.strip() else seg)
    return "".join(rebuilt).strip()


def sanitize_response(
    data,
    allowed_tool_names=None,
    tool_calls_enabled=True,
    latest_user_text="",
):
    """Fix hailo-ollama response for OpenAI SDK compatibility."""
    try:
        resp = json.loads(data)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return data
    if not isinstance(resp, dict):
        return data

    created = resp.get("created", 0)
    if isinstance(created, int) and created > 1e15:
        resp["created"] = int(created // 1000000000)
    elif not created:
        resp["created"] = int(time.time())

    resp.setdefault("object", "chat.completion")
    resp.setdefault("system_fingerprint", "hailo-ollama")

    total_chars = 0
    if "choices" in resp:
        for choice in resp["choices"]:
            choice.setdefault("finish_reason", "stop")
            choice.setdefault("logprobs", None)
            msg = choice.get("message", {})
            content = msg.get("content", "")
            tool_call = None
            suppressed = False
            if tool_calls_enabled:
                parsed = parse_tool_call(content, allowed_names=allowed_tool_names)
                tool_call, suppressed = remap_tool_call(
                    parsed,
                    latest_user_text=latest_user_text,
                    allowed_tool_names=allowed_tool_names,
                )
            if COLLAPSE_REPETITION_ENABLED:
                content = collapse_repetition(content)
            # If we parsed a tool call but suppressed it, never leak the raw JSON
            # block to the user — replace it with a short, honest fallback.
            if suppressed:
                content = (
                    "Diese Aktion kann ich mit dem lokalen Modell nicht direkt "
                    "ausführen. Bitte formuliere die Aufgabe so um, dass sie sich "
                    "mit einem Shell-Befehl (exec) erledigen lässt."
                )
            total_chars += len(content)
            choice["message"] = {
                "role": msg.get("role", "assistant"),
                "content": content,
                "refusal": None,
            }
            if tool_call:
                choice["message"]["content"] = ""
                choice["message"]["tool_calls"] = [
                    {
                        "id": f"call_{int(time.time() * 1000)}",
                        "type": "function",
                        "function": {
                            "name": tool_call["name"],
                            "arguments": json.dumps(tool_call["arguments"]),
                        },
                    }
                ]

    if "usage" not in resp:
        est_tokens = max(1, total_chars // 4)
        resp["usage"] = {
            "prompt_tokens": 100,
            "completion_tokens": est_tokens,
            "total_tokens": 100 + est_tokens,
        }

    return json.dumps(resp).encode("utf-8")


def to_sse(data):
    """Convert a non-streaming response to SSE format for the OpenAI SDK."""
    try:
        resp = json.loads(data)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return b"data: " + data + b"\n\ndata: [DONE]\n\n"

    cid = resp.get("id", "chatcmpl-0")
    model = resp.get("model", "unknown")
    created = resp.get("created", int(time.time()))
    fp = resp.get("system_fingerprint", "hailo-ollama")
    usage = resp.get("usage", {})
    content = ""
    tool_calls = None
    if resp.get("choices"):
        msg = resp["choices"][0].get("message", {})
        content = msg.get("content", "")
        tool_calls = msg.get("tool_calls")

    parts = []
    # role chunk
    parts.append("data: %s\n\n" % json.dumps({
        "id": cid, "object": "chat.completion.chunk", "created": created,
        "model": model, "system_fingerprint": fp,
        "choices": [{"index": 0, "delta": {"role": "assistant", "content": "", "refusal": None},
                     "logprobs": None, "finish_reason": None}],
    }))
    # tool call chunk
    if tool_calls:
        parts.append("data: %s\n\n" % json.dumps({
            "id": cid, "object": "chat.completion.chunk", "created": created,
            "model": model, "system_fingerprint": fp,
            "choices": [{"index": 0, "delta": {"tool_calls": tool_calls},
                         "logprobs": None, "finish_reason": None}],
        }))
    # content chunk
    if content and not tool_calls:
        parts.append("data: %s\n\n" % json.dumps({
            "id": cid, "object": "chat.completion.chunk", "created": created,
            "model": model, "system_fingerprint": fp,
            "choices": [{"index": 0, "delta": {"content": content},
                         "logprobs": None, "finish_reason": None}],
        }))
    # finish chunk
    parts.append("data: %s\n\n" % json.dumps({
        "id": cid, "object": "chat.completion.chunk", "created": created,
        "model": model, "system_fingerprint": fp,
        "choices": [{"index": 0, "delta": {}, "logprobs": None, "finish_reason": "stop"}],
        "usage": usage,
    }))
    parts.append("data: [DONE]\n\n")
    return "".join(parts).encode("utf-8")


def convert_chat_to_completion(data):
    try:
        resp = json.loads(data)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return data
    if not isinstance(resp, dict):
        return data
    choice = None
    if resp.get("choices"):
        choice = resp["choices"][0]
    text = ""
    finish_reason = None
    if choice:
        msg = choice.get("message", {})
        text = msg.get("content", "") or ""
        finish_reason = choice.get("finish_reason")
    completion = {
        "id": resp.get("id", "cmpl-0"),
        "object": "text_completion",
        "created": resp.get("created", int(time.time())),
        "model": resp.get("model", "unknown"),
        "choices": [
            {
                "index": 0,
                "text": text,
                "logprobs": None,
                "finish_reason": finish_reason or "stop",
            }
        ],
    }
    if "usage" in resp:
        completion["usage"] = resp["usage"]
    return json.dumps(completion).encode("utf-8")


def fake_api_show(body_bytes):
    """Return a fake /api/show response to avoid hailo-ollama's DTO crash."""
    try:
        data = json.loads(body_bytes)
    except Exception:
        data = {}
    model = data.get("name", data.get("model", "qwen2:1.5b"))
    return json.dumps({
        "modelfile": "FROM %s" % model,
        "parameters": "stop <|im_end|>",
        "template": "{{ .System }}{{ .Prompt }}",
        "details": {
            "parent_model": "", "format": "gguf", "family": "qwen2",
            "families": ["qwen2"], "parameter_size": "1.5B",
            "quantization_level": "Q4_0",
        },
        "model_info": {},
    }).encode("utf-8")


def _unique_model_ids(values):
    seen = set()
    ordered = []
    for value in values:
        if not isinstance(value, str):
            continue
        model_id = value.strip()
        if not model_id:
            continue
        if model_id in seen:
            continue
        seen.add(model_id)
        ordered.append(model_id)
    return ordered


def discover_upstream_model_ids():
    """Discover models from upstream `/api/tags` with local fallback."""
    tags_url = "%s/api/tags" % UPSTREAM
    discovered = []

    try:
        req = urllib.request.Request(tags_url, method="GET")
        with urllib.request.urlopen(req, timeout=8) as resp:
            payload = json.loads(resp.read())
    except Exception:
        payload = None

    if isinstance(payload, dict):
        rows = payload.get("models")
        if isinstance(rows, list):
            for row in rows:
                if isinstance(row, dict):
                    name = row.get("name") or row.get("model") or row.get("id")
                else:
                    name = row
                if isinstance(name, str):
                    discovered.append(name)

        rows = payload.get("data")
        if isinstance(rows, list):
            for row in rows:
                if isinstance(row, dict):
                    name = row.get("id") or row.get("name") or row.get("model")
                else:
                    name = row
                if isinstance(name, str):
                    discovered.append(name)

    models = _unique_model_ids(discovered)
    if not models:
        models = [DEFAULT_MODEL_ID]
    return models


def fake_v1_models_list():
    now = int(time.time())
    models = [
        {
            "id": model_id,
            "object": "model",
            "created": now,
            "owned_by": "hailo-ollama",
        }
        for model_id in discover_upstream_model_ids()
    ]
    return json.dumps({"object": "list", "data": models}).encode("utf-8")


def fake_v1_model(model_id):
    now = int(time.time())
    return json.dumps(
        {
            "id": model_id,
            "object": "model",
            "created": now,
            "owned_by": "hailo-ollama",
        }
    ).encode("utf-8")


class ProxyHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self._proxy("GET")

    def do_POST(self):
        self._proxy("POST")

    def do_OPTIONS(self):
        trace_id = _next_trace_id()
        started = time.time()
        path = self.path.rstrip("/")
        if not self._validate_request_security(trace_id, "OPTIONS", path, started):
            return
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()
        sys.stderr.write(
            "hailo-sanitize-proxy[%s]: OPTIONS %s -> 204 preflight duration_ms=%d\n"
            % (trace_id, path, int((time.time() - started) * 1000))
        )
        sys.stderr.flush()

    def _origin_header(self):
        origin = self.headers.get("Origin")
        return origin.strip() if origin else ""

    def _host_header(self):
        host = self.headers.get("Host")
        return host.strip().lower() if host else ""

    def _is_origin_allowed(self, origin):
        if not origin:
            return CORS_ALLOW_NO_ORIGIN
        return origin in CORS_ALLOWED_ORIGINS

    def _is_host_allowed(self, host):
        if not host:
            return False
        return host in ALLOWED_HOSTS

    def _deny_request(self, trace_id, method, path, started, reason, details):
        payload = json.dumps({"error": reason, "details": details}).encode("utf-8")
        self._send_json(403, payload)
        sys.stderr.write(
            "hailo-sanitize-proxy[%s]: %s %s -> 403 denied reason=%s details=%s duration_ms=%d\n"
            % (trace_id, method, path, reason, details, int((time.time() - started) * 1000))
        )
        sys.stderr.flush()

    def _validate_request_security(self, trace_id, method, path, started):
        host = self._host_header()
        if not self._is_host_allowed(host):
            self._deny_request(trace_id, method, path, started, "forbidden host", host or "(missing)")
            return False

        origin = self._origin_header()
        if not self._is_origin_allowed(origin):
            self._deny_request(trace_id, method, path, started, "forbidden origin", origin or "(missing)")
            return False

        return True

    def _send_cors_headers(self):
        origin = self._origin_header()
        if not origin:
            return
        if origin not in CORS_ALLOWED_ORIGINS:
            return
        self.send_header("Vary", "Origin")
        self.send_header("Access-Control-Allow-Origin", origin)
        self.send_header("Access-Control-Allow-Methods", CORS_ALLOW_METHODS)
        self.send_header("Access-Control-Allow-Headers", CORS_ALLOW_HEADERS)
        self.send_header("Access-Control-Max-Age", "86400")

    def end_headers(self):
        self._send_cors_headers()
        super().end_headers()

    def _proxy(self, method):
        trace_id = _next_trace_id()
        started = time.time()
        path = self.path.rstrip("/")
        if not self._validate_request_security(trace_id, method, path, started):
            return
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""
        allowed_tool_names = _extract_tool_names(body) if body else set()
        latest_user_text = _extract_latest_user_text(body) if body else ""
        allow_tool_calls = _has_explicit_tool_intent(latest_user_text)

        _write_trace(trace_id, "client-request.raw", body)
        sys.stderr.write(
            "hailo-sanitize-proxy[%s]: IN %s %s bytes=%d summary=%s\n"
            % (trace_id, method, path, len(body), _summarize_request_body(body))
        )
        if body:
            sys.stderr.write(
                "hailo-sanitize-proxy[%s]: TOOL_INTENT enabled=%s latest_user=%s\n"
                % (trace_id, allow_tool_calls, _json_preview(latest_user_text, 180))
            )
        sys.stderr.flush()

        # Fake /api/show
        if path == "/api/show" and method == "POST":
            resp_body = fake_api_show(body)
            _write_trace(trace_id, "proxy-response.fake-api-show", resp_body)
            self._send_json(200, resp_body)
            sys.stderr.write(
                "hailo-sanitize-proxy[%s]: %s %s -> 200 faked duration_ms=%d\n"
                % (trace_id, method, path, int((time.time() - started) * 1000))
            )
            sys.stderr.flush()
            return

        # OpenAI-compatible model discovery for clients (Nanobot, Moltis, etc.)
        if path == "/v1/models" and method == "GET":
            resp_body = fake_v1_models_list()
            _write_trace(trace_id, "proxy-response.fake-v1-models", resp_body)
            self._send_json(200, resp_body)
            sys.stderr.write(
                "hailo-sanitize-proxy[%s]: %s %s -> 200 faked model list duration_ms=%d\n"
                % (trace_id, method, path, int((time.time() - started) * 1000))
            )
            sys.stderr.flush()
            return

        if path.startswith("/v1/models/") and method == "GET":
            model_id = path.split("/v1/models/", 1)[1].strip()
            if not model_id:
                self._send_json(404, b'{"error":"model not found"}')
                return
            resp_body = fake_v1_model(model_id)
            _write_trace(trace_id, "proxy-response.fake-v1-model", resp_body)
            self._send_json(200, resp_body)
            sys.stderr.write(
                "hailo-sanitize-proxy[%s]: %s %s -> 200 faked model detail duration_ms=%d\n"
                % (trace_id, method, path, int((time.time() - started) * 1000))
            )
            sys.stderr.flush()
            return

        # Detect streaming + sanitize for chat completions
        client_wants_stream = False
        is_chat = path == "/v1/chat/completions" and method == "POST"
        is_completion = path == "/v1/completions" and method == "POST"
        original_body = body
        if is_completion and body:
            try:
                payload = json.loads(body)
            except (json.JSONDecodeError, UnicodeDecodeError):
                payload = None
            if isinstance(payload, dict):
                prompt = payload.get("prompt", "")
                model = payload.get("model")
                chat_payload = {
                    "model": model,
                    "messages": [{"role": "user", "content": prompt or ""}],
                    "temperature": payload.get("temperature"),
                    "top_p": payload.get("top_p"),
                    "max_tokens": payload.get("max_tokens"),
                    "stream": False,
                }
                body = json.dumps(chat_payload).encode("utf-8")
                is_chat = True
        if is_chat and body:
            try:
                parsed_request = json.loads(body)
                client_wants_stream = parsed_request.get("stream", False)
            except Exception:
                pass
            body = sanitize_chat_body(body, tool_prompt_enabled=allow_tool_calls)

        upstream_path = "/v1/chat/completions" if is_completion else self.path

        _write_trace(trace_id, "upstream-request.body", body)
        sys.stderr.write(
            "hailo-sanitize-proxy[%s]: UPSTREAM %s %s body_bytes=%d summary=%s\n"
            % (trace_id, method, upstream_path, len(body), _summarize_request_body(body))
        )
        sys.stderr.flush()

        url = "%s%s" % (UPSTREAM, upstream_path)
        req = urllib.request.Request(url, data=body if body else None, method=method)
        for header in self.headers:
            lower = header.lower()
            if lower not in (
                "host",
                "content-length",
                "transfer-encoding",
                "origin",
                "access-control-request-method",
                "access-control-request-headers",
            ):
                req.add_header(header, self.headers[header])
        if body:
            req.add_header("Content-Length", str(len(body)))

        try:
            upstream_started = time.time()
            resp = urllib.request.urlopen(req, timeout=UPSTREAM_TIMEOUT)
            data = resp.read()
            _write_trace(trace_id, "upstream-response.raw", data)

            upstream_ms = int((time.time() - upstream_started) * 1000)
            sys.stderr.write(
                "hailo-sanitize-proxy[%s]: UPSTREAM-RESP %s %s status=%d duration_ms=%d bytes=%d summary=%s\n"
                % (trace_id, method, upstream_path, resp.status, upstream_ms, len(data), _summarize_response_body(data))
            )
            sys.stderr.flush()

            if is_chat:
                data = sanitize_response(
                    data,
                    allowed_tool_names=allowed_tool_names,
                    tool_calls_enabled=allow_tool_calls,
                    latest_user_text=latest_user_text,
                )
            if is_completion:
                data = convert_chat_to_completion(data)

            _write_trace(trace_id, "proxy-response.final", data)

            if is_chat and client_wants_stream and not is_completion:
                sse_data = to_sse(data)
                _write_trace(trace_id, "proxy-response.sse", sse_data)
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Connection", "close")
                self.send_header("Content-Length", str(len(sse_data)))
                self.end_headers()
                self.wfile.write(sse_data)
                self.wfile.flush()
                sys.stderr.write(
                    "hailo-sanitize-proxy[%s]: %s %s -> %d SSE (%d bytes) duration_ms=%d\n"
                    % (trace_id, method, path, resp.status, len(sse_data), int((time.time() - started) * 1000))
                )
            else:
                self._send_json(resp.status, data)
                sys.stderr.write(
                    "hailo-sanitize-proxy[%s]: %s %s -> %d (%d bytes) duration_ms=%d\n"
                    % (trace_id, method, path, resp.status, len(data), int((time.time() - started) * 1000))
                )
            sys.stderr.flush()
        except urllib.error.HTTPError as e:
            err_data = e.read()
            _write_trace(trace_id, "upstream-response.error", err_data)
            if is_chat and e.code == 500:
                try:
                    ts = int(time.time())
                    with open(f"/tmp/hailo-proxy-500-raw-{ts}.json", "wb") as f:
                        f.write(original_body or b"")
                    with open(f"/tmp/hailo-proxy-500-sanitized-{ts}.json", "wb") as f:
                        f.write(body or b"")
                except Exception:
                    pass
            self.send_response(e.code)
            for h, v in e.headers.items():
                if h.lower() not in ("transfer-encoding",):
                    self.send_header(h, v)
            self.end_headers()
            self.wfile.write(err_data)
            sys.stderr.write(
                "hailo-sanitize-proxy[%s]: %s %s -> %d ERROR duration_ms=%d summary=%s\n"
                % (trace_id, method, path, e.code, int((time.time() - started) * 1000), _summarize_response_body(err_data))
            )
            sys.stderr.flush()
        except TimeoutError:
            sys.stderr.write(
                "hailo-sanitize-proxy[%s]: %s %s -> 504 TIMEOUT after_ms=%d\n"
                % (trace_id, method, path, int((time.time() - started) * 1000))
            )
            sys.stderr.flush()
            try:
                self._send_json(504, b'{"error":"upstream timeout"}')
            except BrokenPipeError:
                pass
        except BrokenPipeError:
            sys.stderr.write(
                "hailo-sanitize-proxy[%s]: %s %s -> client disconnected (broken pipe) after_ms=%d\n"
                % (trace_id, method, path, int((time.time() - started) * 1000))
            )
            sys.stderr.flush()
        except Exception as e:
            try:
                msg = ("Proxy error: %s" % e).encode("utf-8")
                self._send_json(502, msg)
            except BrokenPipeError:
                pass
            sys.stderr.write(
                "hailo-sanitize-proxy[%s]: %s %s -> 502 EXCEPTION after_ms=%d: %s\n"
                % (trace_id, method, path, int((time.time() - started) * 1000), e)
            )
            sys.stderr.flush()

    def _send_json(self, code, data):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format, *args):
        pass


def main():
    _ensure_trace_dir()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", LISTEN_PORT), ProxyHandler)
    server.daemon_threads = True
    print(
        "hailo-sanitize-proxy: listening on 127.0.0.1:%d -> %s"
        % (LISTEN_PORT, UPSTREAM),
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()


if __name__ == "__main__":
    main()
