#!/bin/bash
# 全模型使用监控 - OpenAI / Anthropic / Moonshot
# 每小时运行，扫描 JSONL 会话日志，按模型汇总 token 用量和费用
# 生成 HTML 邮件报告

LOG_FILE="/home/ubuntu/logs/model-monitor.log"
mkdir -p /home/ubuntu/logs

source ~/.stock-monitor.env

NOW_UTC=$(date '+%Y-%m-%d %H:%M:%S')
NOW=$(TZ="Asia/Shanghai" date '+%Y-%m-%d %H:%M:%S')
TODAY_DATE=$(TZ="Asia/Shanghai" date '+%Y-%m-%d')

# ============================================================
# 用 Python 采集数据 + 生成 HTML
# ============================================================
HTML=$(python3 << 'PYEOF'
import json, glob, os, sys
from datetime import datetime, timezone, timedelta

SESSION_DIR = os.path.expanduser("~/.openclaw/agents/main/sessions")
CONFIG_FILE = os.path.expanduser("~/.openclaw/openclaw.json")
MEDIA_LOG = os.path.expanduser("~/.openclaw/logs/media-usage.jsonl")
THINKING_LOG = os.path.expanduser("~/.openclaw/logs/gemini-thinking-tokens.jsonl")

BJT = timezone(timedelta(hours=8))
now_bjt = datetime.now(BJT)
today_str = now_bjt.strftime("%Y-%m-%d")

# ============================================================
# 币种定义: RMB 厂商 vs USD 厂商
# ============================================================
RMB_PROVIDERS = {"moonshot", "alibaba"}   # 人民币计费

def is_rmb(provider):
    return provider in RMB_PROVIDERS

def currency_symbol(provider):
    return "¥" if is_rmb(provider) else "$"

# ============================================================
# 1. 读取配置 - 获取模型定价
#    moonshot: ¥/1K tokens;  openai/anthropic: $/1K tokens
# ============================================================
pricing = {}
try:
    with open(CONFIG_FILE) as f:
        config = json.load(f)
    providers_cfg = config.get("models", {}).get("providers", {})
    if isinstance(providers_cfg, dict):
        for prov_id, prov in providers_cfg.items():
            for m in prov.get("models", []):
                mid = m.get("id", "")
                p = m.get("cost", {})
                pricing[mid] = {
                    "input": p.get("input", 0) or 0,
                    "output": p.get("output", 0) or 0,
                    "cache_read": p.get("cacheRead", 0) or 0,
                    "cache_write": p.get("cacheWrite", 0) or 0,
                    "context": m.get("contextWindow", 0),
                    "provider": prov_id,
                }
except Exception:
    pass

# ============================================================
# 3. 扫描 JSONL - 按模型 & 币种汇总
# ============================================================
all_files = sorted(
    glob.glob(f"{SESSION_DIR}/*.jsonl") +
    glob.glob(f"{SESSION_DIR}/*.jsonl.reset.*") +
    glob.glob(f"{SESSION_DIR}/*.jsonl.bak.*")
)

# --- 数据容器 ---
today_by_model = {}; today_by_provider = {}
yesterday_by_model = {}; yesterday_by_provider = {}
alltime_by_model = {}; alltime_by_provider = {}
# 按日期汇总 (provider 维度)，用于 7 天 / 30 天统计
daily_by_provider = {}   # { "2026-02-19": { "openai": {...}, ... } }

# API 返回的模型名 → 配置中的模型名
MODEL_ALIASES = {
    "qwen-max": "qwen3-max",
    "qwen-plus": "qwen3.5-plus",
}
def resolve_model(model_id):
    return MODEL_ALIASES.get(model_id, model_id)

def calc_cost(model_id, inp, out, cache_r, cache_w):
    p = pricing.get(resolve_model(model_id))
    if not p:
        return 0.0
    return (inp * p["input"] + out * p["output"] +
            cache_r * p["cache_read"] + cache_w * p["cache_write"]) / 1000

def add_to(d, key, inp, out, cache_r, cache_w, cost):
    if key not in d:
        d[key] = {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0, "cost": 0.0, "msgs": 0}
    d[key]["input"] += inp
    d[key]["output"] += out
    d[key]["cache_read"] += cache_r
    d[key]["cache_write"] += cache_w
    d[key]["cost"] += cost
    d[key]["msgs"] += 1

yesterday_dt = now_bjt - timedelta(days=1)
yesterday_str = yesterday_dt.strftime("%Y-%m-%d")

seen_ids = set()
for fpath in all_files:
    try:
        with open(fpath) as f:
            for line in f:
                try:
                    line = line.strip()
                    if not line:
                        continue
                    obj = json.loads(line)
                    if obj.get("type") != "message":
                        continue

                    # 去重：防止 .jsonl + .reset + .bak 重复计算
                    msg_id = obj.get("id", "")
                    if msg_id and msg_id in seen_ids:
                        continue
                    if msg_id:
                        seen_ids.add(msg_id)

                    msg = obj.get("message", {})
                    usage = msg.get("usage")
                    if not usage:
                        continue
                    provider = msg.get("provider", "")
                    model = msg.get("model", "")
                    if provider == "openclaw" or model == "delivery-mirror":
                        continue
                    if not provider or not model:
                        continue
                    model = resolve_model(model)

                    inp = usage.get("input", 0) or 0
                    out = usage.get("output", 0) or 0
                    cache_r = usage.get("cacheRead", 0) or 0
                    cache_w = usage.get("cacheWrite", 0) or 0

                    cost = calc_cost(model, inp, out, cache_r, cache_w)

                    # 解析日期 (UTC → BJT)
                    ts_str = obj.get("timestamp", "")
                    date_str = None
                    if ts_str:
                        try:
                            ts_dt = datetime.fromisoformat(ts_str.replace("Z", "+00:00")).astimezone(BJT)
                            date_str = ts_dt.strftime("%Y-%m-%d")
                        except (ValueError, TypeError):
                            pass

                    model_key = f"{provider}/{model}"

                    # 全量
                    add_to(alltime_by_model, model_key, inp, out, cache_r, cache_w, cost)
                    add_to(alltime_by_provider, provider, inp, out, cache_r, cache_w, cost)

                    if date_str:
                        # 今日
                        if date_str == today_str:
                            add_to(today_by_model, model_key, inp, out, cache_r, cache_w, cost)
                            add_to(today_by_provider, provider, inp, out, cache_r, cache_w, cost)
                        # 昨日
                        if date_str == yesterday_str:
                            add_to(yesterday_by_model, model_key, inp, out, cache_r, cache_w, cost)
                            add_to(yesterday_by_provider, provider, inp, out, cache_r, cache_w, cost)
                        # 按日汇总
                        if date_str not in daily_by_provider:
                            daily_by_provider[date_str] = {}
                        add_to(daily_by_provider[date_str], provider, inp, out, cache_r, cache_w, cost)
                except (json.JSONDecodeError, KeyError, TypeError):
                    continue
    except IOError:
        continue

# ============================================================
# 3-think. 扫描 gemini-thinking-tokens.jsonl - 思考 token 用量
# ============================================================
thinking_by_model = {}     # { "google/gemini-2.5-pro": {"today": N, "yesterday": N, "alltime": N} }
thinking_cost_by_model = {}  # same structure but costs
thinking_cost_today_usd = 0.0
thinking_cost_yesterday_usd = 0.0
thinking_cost_alltime_usd = 0.0
thinking_by_provider_daily = {}  # { "2026-02-24": {"google": cost} }

if os.path.isfile(THINKING_LOG):
    try:
        with open(THINKING_LOG) as f:
            for line in f:
                try:
                    line = line.strip()
                    if not line:
                        continue
                    obj = json.loads(line)
                    model = obj.get("model", "")
                    thinking = obj.get("thinking", 0) or 0
                    if thinking <= 0 or not model:
                        continue

                    # Resolve model alias and find pricing
                    resolved = resolve_model(model)
                    key = f"google/{resolved}"
                    p = pricing.get(resolved, {})
                    output_rate = p.get("output", 0)
                    cost = thinking * output_rate / 1000  # pricing is per 1K tokens

                    # Parse timestamp (UTC → BJT)
                    ts_str = obj.get("ts", "")
                    date_str = None
                    if ts_str:
                        try:
                            ts_dt = datetime.fromisoformat(ts_str.replace("Z", "+00:00")).astimezone(BJT)
                            date_str = ts_dt.strftime("%Y-%m-%d")
                        except (ValueError, TypeError):
                            pass

                    # Initialize model entries
                    if key not in thinking_by_model:
                        thinking_by_model[key] = {"today": 0, "yesterday": 0, "alltime": 0}
                    if key not in thinking_cost_by_model:
                        thinking_cost_by_model[key] = {"today": 0.0, "yesterday": 0.0, "alltime": 0.0}

                    # Alltime
                    thinking_by_model[key]["alltime"] += thinking
                    thinking_cost_by_model[key]["alltime"] += cost
                    thinking_cost_alltime_usd += cost

                    if date_str:
                        if date_str == today_str:
                            thinking_by_model[key]["today"] += thinking
                            thinking_cost_by_model[key]["today"] += cost
                            thinking_cost_today_usd += cost
                        if date_str == yesterday_str:
                            thinking_by_model[key]["yesterday"] += thinking
                            thinking_cost_by_model[key]["yesterday"] += cost
                            thinking_cost_yesterday_usd += cost
                        # Inject into daily_by_provider for trend calculation
                        if date_str not in thinking_by_provider_daily:
                            thinking_by_provider_daily[date_str] = 0.0
                        thinking_by_provider_daily[date_str] += cost
                except (json.JSONDecodeError, KeyError, TypeError, ValueError):
                    continue
    except IOError:
        pass

# Inject thinking costs into daily_by_provider for trend calculations
for d_str, think_cost in thinking_by_provider_daily.items():
    if d_str not in daily_by_provider:
        daily_by_provider[d_str] = {}
    dp = daily_by_provider[d_str]
    if "_thinking" not in dp:
        dp["_thinking"] = {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0, "cost": 0.0, "msgs": 0}
    dp["_thinking"]["cost"] += think_cost

# ============================================================
# 3a. 扫描 off-gateway media-usage.jsonl (TTS / 图片生成)
# ============================================================
media_today = {}; media_yesterday = {}; media_alltime = {}
media_daily = {}  # { "2026-02-21": { "openai/tts-1": {...}, ... } }
media_today_usd = 0.0; media_alltime_usd = 0.0

MEDIA_SERVICE_DISPLAY = {
    "tts": ("TTS 语音", "#10a37f", "🔊"),
    "image": ("图片生成", "#4285f4", "🎨"),
    "tts-builtin": ("内置TTS (未追踪)", "#ff9800", "🔇"),
    "image-builtin": ("内置图片 (未追踪)", "#ff5722", "🖼️"),
}

def media_info(service):
    return MEDIA_SERVICE_DISPLAY.get(service, (service, "#666", "⚪"))

def add_media(d, k, data):
    if k not in d:
        d[k] = {"cost": 0.0, "quantity": 0, "calls": 0, "unit": data["unit"],
                 "service": data["service"], "provider": data["provider"], "model": data["model"]}
    d[k]["cost"] += data["cost"]
    d[k]["quantity"] += data["quantity"]
    d[k]["calls"] += 1

media_seen = set()
if os.path.isfile(MEDIA_LOG):
    try:
        with open(MEDIA_LOG) as f:
            for line in f:
                try:
                    line = line.strip()
                    if not line:
                        continue
                    obj = json.loads(line)
                    mid = obj.get("id", "")
                    if mid and mid in media_seen:
                        continue
                    if mid:
                        media_seen.add(mid)

                    service = obj.get("service", "")
                    provider = obj.get("provider", "")
                    model = obj.get("model", "")
                    cost = float(obj.get("cost", 0))
                    quantity = int(obj.get("quantity", 0))
                    unit = obj.get("unit", "")
                    meta = obj.get("meta", {})

                    ts_str = obj.get("ts", "")
                    date_str = None
                    if ts_str:
                        try:
                            ts_dt = datetime.fromisoformat(ts_str.replace("Z", "+00:00")).astimezone(BJT)
                            date_str = ts_dt.strftime("%Y-%m-%d")
                        except (ValueError, TypeError):
                            pass

                    key = f"{provider}/{model}"
                    entry_data = {"cost": cost, "quantity": quantity, "unit": unit, "service": service, "provider": provider, "model": model}

                    add_media(media_alltime, key, entry_data)
                    media_alltime_usd += cost

                    if date_str:
                        if date_str == today_str:
                            add_media(media_today, key, entry_data)
                            media_today_usd += cost
                        if date_str == yesterday_str:
                            add_media(media_yesterday, key, entry_data)
                        if date_str not in media_daily:
                            media_daily[date_str] = {}
                        add_media(media_daily[date_str], key, entry_data)

                except (json.JSONDecodeError, KeyError, TypeError, ValueError):
                    continue
    except IOError:
        pass

# ============================================================
# 3b. 扫描 gateway 日志 - 捕获内置 TTS / Image 工具用量
#     这些工具绕过 media-usage.jsonl，只出现在 gateway 调试日志中
# ============================================================
GATEWAY_LOG_DIR = "/tmp/openclaw"

BUILTIN_MEDIA_DISPLAY = {
    "tts": ("内置TTS (未追踪)", "#ff9800", "🔇"),
    "image": ("内置图片 (未追踪)", "#ff5722", "🖼️"),
}

def parse_gateway_logs_for_builtin_media():
    """Parse gateway logs for built-in tts/image tool calls not tracked in media-usage.jsonl."""
    import re
    results = []  # list of {"service","ts","file_bytes"}
    seen_tool_call_ids = set()  # global dedup across log files

    # Collect all relevant log files (today + recent days for alltime)
    log_files = sorted(glob.glob(f"{GATEWAY_LOG_DIR}/openclaw-*.log"))
    if not log_files:
        return results

    # Regex to extract toolCallId from log message
    tool_call_id_re = re.compile(r'toolCallId=(\S+)')

    for log_file in log_files:
        # Extract date from filename: openclaw-YYYY-MM-DD.log
        fname = os.path.basename(log_file)
        m = re.match(r'openclaw-(\d{4}-\d{2}-\d{2})\.log', fname)
        if not m:
            continue

        tts_calls = []    # (timestamp_str,)
        image_calls = []  # (timestamp_str,)
        # Only match built-in TTS deliveries: /tmp/tts-XXXX/voice-*.mp3
        # Exclude skill-script deliveries: /tmp/tts-output-*.mp3
        media_deliveries = []  # (timestamp_str, mediaUrl, mediaSizeBytes)

        try:
            with open(log_file) as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        obj = json.loads(line)
                    except json.JSONDecodeError:
                        continue

                    msg = obj.get("1", "")
                    meta = obj.get("_meta", {})
                    ts = meta.get("date", "")

                    # Detect tool=tts or tool=image start entries
                    if isinstance(msg, str) and "embedded run tool start:" in msg:
                        # Extract toolCallId for dedup across log files
                        tcid_match = tool_call_id_re.search(msg)
                        tcid = tcid_match.group(1) if tcid_match else None
                        if tcid and tcid in seen_tool_call_ids:
                            continue
                        if tcid:
                            seen_tool_call_ids.add(tcid)

                        if " tool=tts " in msg:
                            tts_calls.append((ts, tcid))
                        elif " tool=image " in msg:
                            image_calls.append((ts, tcid))

                    # Detect media delivery entries with built-in TTS audio files
                    # Built-in pattern: /tmp/tts-XXXX/voice-*.mp3
                    # Script pattern:   /tmp/tts-output-*.mp3 (excluded)
                    if isinstance(msg, dict) and msg.get("mediaKind") == "audio":
                        url = msg.get("mediaUrl", "")
                        if "/tmp/tts-" in url and url.endswith(".mp3") and "/tts-output-" not in url:
                            media_deliveries.append({
                                "ts": ts,
                                "url": url,
                                "bytes": msg.get("mediaSizeBytes", 0),
                            })
        except IOError:
            continue

        # Deduplicate media deliveries by URL (same file can be sent multiple times)
        seen_urls = set()
        unique_deliveries = []
        for md in media_deliveries:
            if md["url"] not in seen_urls:
                seen_urls.add(md["url"])
                unique_deliveries.append(md)

        # For TTS: match each tool call to the nearest media delivery
        # Use delivery data for file size; fall back to 0 if no match
        used_deliveries = set()
        for call_ts, tcid in tts_calls:
            best_delivery = None
            best_delta = float("inf")
            for i, md in enumerate(unique_deliveries):
                if i in used_deliveries:
                    continue
                try:
                    ct = datetime.fromisoformat(call_ts.replace("Z", "+00:00"))
                    dt = datetime.fromisoformat(md["ts"].replace("Z", "+00:00"))
                    delta = abs((dt - ct).total_seconds())
                    if delta < 15 and delta < best_delta:
                        best_delta = delta
                        best_delivery = (i, md)
                except (ValueError, TypeError):
                    continue
            file_bytes = 0
            if best_delivery:
                used_deliveries.add(best_delivery[0])
                file_bytes = best_delivery[1]["bytes"]
            results.append({"service": "tts", "ts": call_ts, "file_bytes": file_bytes, "tcid": tcid})

        # For image: just count tool calls (no file size data in logs)
        for call_ts, tcid in image_calls:
            results.append({"service": "image", "ts": call_ts, "file_bytes": 0, "tcid": tcid})

    return results

builtin_entries = parse_gateway_logs_for_builtin_media()

# Persist NEW built-in entries to media-usage.jsonl so alltime counts survive log rotation.
# Entries already persisted in previous runs are in media_seen (loaded above) and will be skipped.
import uuid as _uuid
new_jsonl_lines = []
for entry in builtin_entries:
    service = entry["service"]
    ts_str = entry["ts"]
    tcid = entry.get("tcid", "")

    # Use toolCallId as stable id (prefix with "builtin-" to avoid collision with script ids)
    stable_id = f"builtin-{tcid}" if tcid else f"builtin-{_uuid.uuid4()}"
    if stable_id in media_seen:
        continue  # already persisted & counted by the jsonl reader above

    if service == "tts":
        # Estimate characters from MP3 file size:
        # MP3 ~128kbps = ~16000 bytes/sec audio, average ~5 chars/sec spoken
        audio_secs = entry["file_bytes"] / 16000 if entry["file_bytes"] > 0 else 0
        est_chars = max(int(audio_secs * 5), 50) if entry["file_bytes"] > 0 else 100
        est_cost = est_chars / 1000 * 0.015  # tts-1 rate
        key = "openai/tts-builtin"
        entry_data = {"cost": est_cost, "quantity": est_chars, "unit": "chars",
                       "service": "tts-builtin", "provider": "openai", "model": "tts-builtin"}
    else:
        # Image: assume flash model default price
        est_cost = 0.039
        key = "google/image-builtin"
        entry_data = {"cost": est_cost, "quantity": 1, "unit": "image",
                       "service": "image-builtin", "provider": "google", "model": "image-builtin"}

    add_media(media_alltime, key, entry_data)
    media_alltime_usd += entry_data["cost"]

    date_str = None
    if ts_str:
        try:
            ts_dt = datetime.fromisoformat(ts_str.replace("Z", "+00:00")).astimezone(BJT)
            date_str = ts_dt.strftime("%Y-%m-%d")
        except (ValueError, TypeError):
            pass

    if date_str:
        if date_str == today_str:
            add_media(media_today, key, entry_data)
            media_today_usd += entry_data["cost"]
        if date_str == yesterday_str:
            add_media(media_yesterday, key, entry_data)
        if date_str not in media_daily:
            media_daily[date_str] = {}
        add_media(media_daily[date_str], key, entry_data)

    # Queue for writing to jsonl
    media_seen.add(stable_id)
    jsonl_record = {"id": stable_id, "ts": ts_str, "service": entry_data["service"],
                    "provider": entry_data["provider"], "model": entry_data["model"],
                    "unit": entry_data["unit"], "quantity": entry_data["quantity"],
                    "cost": entry_data["cost"], "meta": {"source": "gateway-log", "tcid": tcid}}
    new_jsonl_lines.append(json.dumps(jsonl_record))

# Append new built-in entries to media-usage.jsonl
if new_jsonl_lines:
    try:
        with open(MEDIA_LOG, "a") as f:
            for jl in new_jsonl_lines:
                f.write(jl + "\n")
    except IOError:
        pass

# ============================================================
# 3c. 今日媒体投递统计 - 从 gateway 日志统计实际发送的音频/图片
# ============================================================
import re as _re
today_audio_files = {}   # url -> bytes (dedup)
today_image_files = {}   # url -> bytes (dedup)
# Classify image deliveries by source
today_image_by_source = {}  # source_label -> {"count": N, "bytes": N}
# Scan ALL gateway log files (not just UTC-today).  A long-running gateway
# process writes to the log file it opened at startup, so today's (BJT)
# entries may live in any older file.  The BJT filter below ensures only
# today's entries are counted — same approach as section 3b.
for _today_log in sorted(glob.glob(f"{GATEWAY_LOG_DIR}/openclaw-*.log")):
    try:
        with open(_today_log) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                msg = obj.get("1", "")
                if not isinstance(msg, dict):
                    continue
                url = msg.get("mediaUrl", "")
                size = msg.get("mediaSizeBytes", 0)
                kind = msg.get("mediaKind", "")
                ts = obj.get("_meta", {}).get("date", "")
                # Filter to today (BJT) — skip entries without timestamp
                if not ts:
                    continue
                try:
                    dt = datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone(BJT)
                    if dt.strftime("%Y-%m-%d") != today_str:
                        continue
                except (ValueError, TypeError):
                    continue
                if kind == "audio" and url and size > 0:
                    if url not in today_audio_files:
                        today_audio_files[url] = size
                elif kind == "image" and url and size > 0:
                    if url not in today_image_files:
                        today_image_files[url] = size
                        # Classify by source
                        if "/media/browser/" in url:
                            src = "🌐 浏览器截图"
                        elif "/tts-" in url:
                            src = "🔊 TTS"  # unlikely but safe
                        else:
                            src = "🎨 图片生成"
                        if src not in today_image_by_source:
                            today_image_by_source[src] = {"count": 0, "bytes": 0}
                        today_image_by_source[src]["count"] += 1
                        today_image_by_source[src]["bytes"] += size
    except IOError:
        pass

def fmt_size(b):
    if b >= 1_048_576: return f"{b/1_048_576:.1f} MB"
    if b >= 1024: return f"{b/1024:.1f} KB"
    return f"{b} B"

audio_count = len(today_audio_files)
audio_total_bytes = sum(today_audio_files.values())
audio_avg_bytes = audio_total_bytes // audio_count if audio_count > 0 else 0
image_count = len(today_image_files)
image_total_bytes = sum(today_image_files.values())
image_avg_bytes = image_total_bytes // image_count if image_count > 0 else 0

# Build image source breakdown string
image_source_breakdown = ""
if len(today_image_by_source) > 0:
    parts = []
    for src_label in sorted(today_image_by_source.keys()):
        src_data = today_image_by_source[src_label]
        parts.append(f'{src_label} {src_data["count"]}张 ({fmt_size(src_data["bytes"])})')
    image_source_breakdown = " · ".join(parts)

# Count audio/images actually generated today (from media_today, excludes re-sent old files)
audio_generated_count = sum(d["calls"] for d in media_today.values()
                           if d.get("service") in ("tts", "tts-builtin"))
image_generated_count = sum(d["calls"] for d in media_today.values()
                           if d.get("service") in ("image", "image-builtin"))

# Inject media costs into daily_by_provider for trend calculations
for d_str, d_models in media_daily.items():
    if d_str not in daily_by_provider:
        daily_by_provider[d_str] = {}
    day_media_cost = sum(m["cost"] for m in d_models.values())
    day_media_calls = sum(m["calls"] for m in d_models.values())
    if day_media_cost > 0:
        dp = daily_by_provider[d_str]
        if "_media_api" not in dp:
            dp["_media_api"] = {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0, "cost": 0.0, "msgs": 0}
        dp["_media_api"]["cost"] += day_media_cost
        dp["_media_api"]["msgs"] += day_media_calls

# ============================================================
# 3d. Web Search (Brave API) 用量统计
# ============================================================
BRAVE_COST_PER_QUERY = 0.005  # $5 per 1000 queries

web_search_today = 0
web_search_yesterday = 0
web_search_alltime = 0
web_search_today_queries = []   # list of query strings for display
web_search_today_ms = 0         # total response time today
web_search_errors_today = 0

ws_seen_ids = set()
for fpath in all_files:
    try:
        with open(fpath) as f:
            for line in f:
                try:
                    line = line.strip()
                    if not line:
                        continue
                    obj = json.loads(line)
                    if obj.get("type") != "message":
                        continue
                    msg = obj.get("message", {})
                    if msg.get("role") != "toolResult" or msg.get("toolName") != "web_search":
                        continue
                    msg_id = obj.get("id", "")
                    if msg_id and msg_id in ws_seen_ids:
                        continue
                    if msg_id:
                        ws_seen_ids.add(msg_id)

                    # Parse timestamp
                    ts_str = obj.get("timestamp", "")
                    date_str = None
                    if ts_str:
                        try:
                            ts_dt = datetime.fromisoformat(ts_str.replace("Z", "+00:00")).astimezone(BJT)
                            date_str = ts_dt.strftime("%Y-%m-%d")
                        except (ValueError, TypeError):
                            pass

                    # Check if error
                    details = msg.get("details", {})
                    is_error = bool(details.get("error"))

                    # Parse result content for query and tookMs
                    query_str = ""
                    took_ms = 0
                    content = msg.get("content", [])
                    if content and isinstance(content, list):
                        for c in content:
                            if c.get("type") == "text":
                                try:
                                    result_data = json.loads(c["text"])
                                    query_str = result_data.get("query", "")
                                    took_ms = result_data.get("tookMs", 0)
                                except (json.JSONDecodeError, KeyError):
                                    pass

                    if not is_error:
                        web_search_alltime += 1
                        if date_str == today_str:
                            web_search_today += 1
                            web_search_today_ms += took_ms
                            if query_str:
                                web_search_today_queries.append(query_str)
                            # Inject cost into daily_by_provider
                            if today_str not in daily_by_provider:
                                daily_by_provider[today_str] = {}
                            dp = daily_by_provider[today_str]
                            if "_web_search" not in dp:
                                dp["_web_search"] = {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0, "cost": 0.0, "msgs": 0}
                            dp["_web_search"]["cost"] += BRAVE_COST_PER_QUERY
                            dp["_web_search"]["msgs"] += 1
                        elif date_str == yesterday_str:
                            web_search_yesterday += 1
                        # Inject into daily_by_provider for all dates
                        if date_str and date_str != today_str:
                            if date_str not in daily_by_provider:
                                daily_by_provider[date_str] = {}
                            dp = daily_by_provider[date_str]
                            if "_web_search" not in dp:
                                dp["_web_search"] = {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0, "cost": 0.0, "msgs": 0}
                            dp["_web_search"]["cost"] += BRAVE_COST_PER_QUERY
                            dp["_web_search"]["msgs"] += 1
                    else:
                        if date_str == today_str:
                            web_search_errors_today += 1
                except (json.JSONDecodeError, KeyError, TypeError):
                    continue
    except IOError:
        continue

web_search_today_cost = web_search_today * BRAVE_COST_PER_QUERY
web_search_alltime_cost = web_search_alltime * BRAVE_COST_PER_QUERY
web_search_avg_ms = web_search_today_ms // web_search_today if web_search_today > 0 else 0

# ============================================================
# 3b. 计算近 7 天 / 30 天 及环比
# ============================================================
def range_sum(daily, start_date, days):
    """汇总 [start_date - days+1, start_date] 范围内的数据"""
    rmb_cost = 0.0; usd_cost = 0.0; msgs = 0; inp_total = 0; out_total = 0
    for i in range(days):
        d = (start_date - timedelta(days=i)).strftime("%Y-%m-%d")
        for prov, data in daily.get(d, {}).items():
            if is_rmb(prov):
                rmb_cost += data["cost"]
            else:
                usd_cost += data["cost"]
            msgs += data["msgs"]
            inp_total += data["input"]
            out_total += data["output"]
    return {"rmb": rmb_cost, "usd": usd_cost, "msgs": msgs, "input": inp_total, "output": out_total}

# 近 7 天 = 今天 + 前 6 天
last7 = range_sum(daily_by_provider, now_bjt.date(), 7)
prev7 = range_sum(daily_by_provider, now_bjt.date() - timedelta(days=7), 7)
# 近 30 天
last30 = range_sum(daily_by_provider, now_bjt.date(), 30)
prev30 = range_sum(daily_by_provider, now_bjt.date() - timedelta(days=30), 30)

def pct_change(current, previous):
    """计算变化百分比"""
    if previous == 0:
        return None
    return (current - previous) / previous * 100

# ============================================================
# 4. 辅助函数
# ============================================================
def fmt_tokens(n):
    if n >= 1_000_000: return f"{n/1_000_000:.1f}M"
    if n >= 1_000:     return f"{n/1_000:.1f}k"
    return str(n)

def fmt_cost(c, sym="$"):
    if c >= 1:    return f"{sym}{c:.2f}"
    if c >= 0.01: return f"{sym}{c:.4f}"
    if c > 0:     return f"{sym}{c:.6f}"
    return f"{sym}0.00"

def age_str(ms):
    if ms < 60_000:     return f"{ms//1000}秒前"
    if ms < 3_600_000:  return f"{ms//60_000}分钟前"
    return f"{ms//3_600_000}小时前"

PROVIDER_DISPLAY = {
    "openai":    ("OpenAI",    "#10a37f", "🟢"),
    "anthropic": ("Anthropic", "#d97706", "🟠"),
    "moonshot":  ("Moonshot",  "#6366f1", "🟣"),
    "alibaba":   ("Alibaba",   "#ff6a00", "🟠"),
    "google":    ("Google",    "#4285f4", "🔵"),
}
def prov_info(p):
    return PROVIDER_DISPLAY.get(p, (p.title(), "#666", "⚪"))

# ============================================================
# 5. 计算双币种汇总
# ============================================================
def sum_by_currency(by_provider, scope="today"):
    """分 RMB / USD 汇总"""
    rmb = {"cost": 0.0, "msgs": 0, "input": 0, "output": 0}
    usd = {"cost": 0.0, "msgs": 0, "input": 0, "output": 0}
    for prov, d in by_provider.items():
        t = rmb if is_rmb(prov) else usd
        t["cost"] += d["cost"]
        t["msgs"] += d["msgs"]
        t["input"] += d["input"]
        t["output"] += d["output"]
    return rmb, usd

today_rmb, today_usd = sum_by_currency(today_by_provider)
yest_rmb, yest_usd = sum_by_currency(yesterday_by_provider)
all_rmb, all_usd = sum_by_currency(alltime_by_provider)
# Include off-gateway media API costs in USD totals
today_usd["cost"] += media_today_usd
today_media_calls = sum(d["calls"] for d in media_today.values())
today_usd["msgs"] += today_media_calls
all_usd["cost"] += media_alltime_usd
all_media_calls = sum(d["calls"] for d in media_alltime.values())
all_usd["msgs"] += all_media_calls
yest_media_usd = sum(d["cost"] for d in media_yesterday.values())
yest_media_calls = sum(d["calls"] for d in media_yesterday.values())
yest_usd["cost"] += yest_media_usd
yest_usd["msgs"] += yest_media_calls
# Include Gemini thinking token costs in USD totals
today_usd["cost"] += thinking_cost_today_usd
yest_usd["cost"] += thinking_cost_yesterday_usd
all_usd["cost"] += thinking_cost_alltime_usd
today_total_msgs = today_rmb["msgs"] + today_usd["msgs"]
today_total_input = today_rmb["input"] + today_usd["input"]
today_total_output = today_rmb["output"] + today_usd["output"]
yest_total_msgs = yest_rmb["msgs"] + yest_usd["msgs"]

# ============================================================
# 6. 生成 HTML
# ============================================================
th = 'style="padding:10px 12px;text-align:left;color:white;font-weight:600;font-size:13px;"'
td = 'style="padding:10px 12px;font-size:13px;border-bottom:1px solid #eee;"'
td_mono = 'style="padding:10px 12px;font-size:13px;border-bottom:1px solid #eee;font-family:monospace;text-align:right;"'
td_mono_cost = 'style="padding:10px 12px;font-size:13px;border-bottom:1px solid #eee;font-family:monospace;text-align:right;font-weight:bold;color:#e74c3c;"'
td_wrap = 'style="padding:10px 12px;font-size:13px;border-bottom:1px solid #eee;max-width:250px;word-break:break-all;"'
td_muted = 'style="padding:10px 12px;font-size:13px;border-bottom:1px solid #eee;color:#999;"'

# --- 今日厂商卡片 ---
provider_cards = ""
for prov in ["moonshot", "openai", "anthropic", "alibaba", "google"]:
    name, color, icon = prov_info(prov)
    d = today_by_provider.get(prov, {"input": 0, "output": 0, "cost": 0, "msgs": 0})
    if d["msgs"] == 0 and prov not in alltime_by_provider:
        continue
    sym = currency_symbol(prov)
    # For Google, include thinking token cost
    prov_display_cost = d["cost"]
    thinking_annotation = ""
    if prov == "google" and thinking_cost_today_usd > 0:
        prov_display_cost += thinking_cost_today_usd
        # Sum today's thinking tokens across all Google models
        today_thinking_tokens = sum(v["today"] for v in thinking_by_model.values())
        thinking_annotation = f'''
      <div style="font-size:11px;color:#9c27b0;margin-top:4px;">
        🧠 思考 {fmt_tokens(today_thinking_tokens)} tokens (+{fmt_cost(thinking_cost_today_usd, "$")})
      </div>'''
    provider_cards += f"""
    <div style="flex:1;min-width:200px;background:white;border-radius:12px;padding:18px;
                box-shadow:0 2px 8px rgba(0,0,0,.08);border-top:4px solid {color};">
      <div style="font-size:14px;color:#666;margin-bottom:8px;">{icon} {name}</div>
      <div style="font-size:24px;font-weight:700;color:#333;">{fmt_cost(prov_display_cost, sym)}</div>
      <div style="font-size:12px;color:#999;margin-top:6px;">
        {d["msgs"]} 次调用 · {fmt_tokens(d["input"])} 输入 · {fmt_tokens(d["output"])} 输出
      </div>{thinking_annotation}
    </div>"""

# --- Media API 卡片 (TTS + 图片) ---
if today_media_calls > 0:
    provider_cards += f"""
    <div style="flex:1;min-width:200px;background:white;border-radius:12px;padding:18px;
                box-shadow:0 2px 8px rgba(0,0,0,.08);border-top:4px solid #9c27b0;">
      <div style="font-size:14px;color:#666;margin-bottom:8px;">🎨 Media API</div>
      <div style="font-size:24px;font-weight:700;color:#333;">{fmt_cost(media_today_usd, "$")}</div>
      <div style="font-size:12px;color:#999;margin-top:6px;">
        {today_media_calls} 次调用 · TTS + 图片生成
      </div>
    </div>"""

# --- 用量趋势卡片 ---
def trend_cost_str(d, key_rmb="rmb", key_usd="usd"):
    """格式化双币种费用"""
    parts = []
    rmb_val = d[key_rmb] if isinstance(d, dict) and key_rmb in d else 0
    usd_val = d[key_usd] if isinstance(d, dict) and key_usd in d else 0
    if rmb_val > 0: parts.append(f"¥{rmb_val:.2f}")
    if usd_val > 0: parts.append(f"${usd_val:.4f}")
    return " + ".join(parts) if parts else "—"

def change_badge(pct):
    """百分比变化徽章"""
    if pct is None:
        return '<span style="color:#999;font-size:12px;">—</span>'
    color = "#e74c3c" if pct > 0 else ("#4caf50" if pct < 0 else "#999")
    arrow = "↑" if pct > 0 else ("↓" if pct < 0 else "→")
    return f'<span style="color:{color};font-size:13px;font-weight:600;">{arrow} {abs(pct):.1f}%</span>'

# 今日 vs 昨日 同比
today_total_cost_rmb = today_rmb["cost"]
today_total_cost_usd = today_usd["cost"]
yest_total_cost_rmb = yest_rmb["cost"]
yest_total_cost_usd = yest_usd["cost"]
vs_yest_rmb_pct = pct_change(today_total_cost_rmb, yest_total_cost_rmb)
vs_yest_usd_pct = pct_change(today_total_cost_usd, yest_total_cost_usd)
vs_yest_msgs_pct = pct_change(today_total_msgs, yest_total_msgs)

# 7 天环比
l7_rmb_pct = pct_change(last7["rmb"], prev7["rmb"])
l7_usd_pct = pct_change(last7["usd"], prev7["usd"])
l7_msgs_pct = pct_change(last7["msgs"], prev7["msgs"])
# 30 天环比
l30_rmb_pct = pct_change(last30["rmb"], prev30["rmb"])
l30_usd_pct = pct_change(last30["usd"], prev30["usd"])
l30_msgs_pct = pct_change(last30["msgs"], prev30["msgs"])

card_style = 'style="flex:1;min-width:180px;background:white;border-radius:12px;padding:16px;box-shadow:0 2px 8px rgba(0,0,0,.08);"'
label_style = 'style="font-size:12px;color:#999;margin-bottom:6px;"'
val_style = 'style="font-size:18px;font-weight:700;color:#333;"'
sub_style = 'style="font-size:12px;color:#666;margin-top:6px;"'

trend_cards = f"""
    <div {card_style}>
      <div {label_style}>📅 昨日 ({yesterday_str})</div>
      <div {val_style}>{trend_cost_str({"rmb": yest_total_cost_rmb, "usd": yest_total_cost_usd})}</div>
      <div {sub_style}>{yest_total_msgs} 次调用</div>
    </div>
    <div {card_style}>
      <div {label_style}>📊 今日 vs 昨日</div>
      <div {val_style}>
        {"¥ " + change_badge(vs_yest_rmb_pct) if yest_total_cost_rmb > 0 or today_total_cost_rmb > 0 else ""}
        {"&nbsp;&nbsp;$ " + change_badge(vs_yest_usd_pct) if yest_total_cost_usd > 0 or today_total_cost_usd > 0 else ""}
      </div>
      <div {sub_style}>调用 {change_badge(vs_yest_msgs_pct)}</div>
    </div>
    <div {card_style}>
      <div {label_style}>📈 近 7 天</div>
      <div {val_style}>{trend_cost_str(last7)}</div>
      <div {sub_style}>{last7["msgs"]} 次调用 · 环比 {"¥ " + change_badge(l7_rmb_pct) if last7["rmb"] > 0 or prev7["rmb"] > 0 else ""} {"$ " + change_badge(l7_usd_pct) if last7["usd"] > 0 or prev7["usd"] > 0 else ""}</div>
    </div>
    <div {card_style}>
      <div {label_style}>📉 近 30 天</div>
      <div {val_style}>{trend_cost_str(last30)}</div>
      <div {sub_style}>{last30["msgs"]} 次调用 · 环比 {"¥ " + change_badge(l30_rmb_pct) if last30["rmb"] > 0 or prev30["rmb"] > 0 else ""} {"$ " + change_badge(l30_usd_pct) if last30["usd"] > 0 or prev30["usd"] > 0 else ""}</div>
    </div>
"""

# --- 今日模型明细表 ---
td_mono_think = 'style="padding:10px 12px;font-size:13px;border-bottom:1px solid #eee;font-family:monospace;text-align:right;color:#9c27b0;"'

model_rows_today = ""
for key in sorted(today_by_model.keys(), key=lambda k: -today_by_model[k]["msgs"]):
    d = today_by_model[key]
    prov, model = key.split("/", 1)
    name, color, icon = prov_info(prov)
    sym = currency_symbol(prov)
    think_tokens = thinking_by_model.get(key, {}).get("today", 0)
    think_cost = thinking_cost_by_model.get(key, {}).get("today", 0.0)
    total_cost = d["cost"] + think_cost
    think_cell = f'{fmt_tokens(think_tokens)}' if think_tokens > 0 else '—'
    model_rows_today += f"""
    <tr>
      <td {td}>{icon} <span style="color:{color};font-weight:600;">{name}</span></td>
      <td {td}><b>{model}</b></td>
      <td {td_mono}>{d["msgs"]}</td>
      <td {td_mono}>{fmt_tokens(d["input"])}</td>
      <td {td_mono}>{fmt_tokens(d["output"])}</td>
      <td {td_mono_think}>{think_cell}</td>
      <td {td_mono}>{fmt_tokens(d["cache_read"])}</td>
      <td {td_mono_cost}>{fmt_cost(total_cost, sym)}</td>
    </tr>"""
if not model_rows_today:
    model_rows_today = '<tr><td colspan="8" style="padding:20px;text-align:center;color:#999;">今日暂无调用记录</td></tr>'

# --- 历史模型明细表 (按币种分组，费用降序) ---
def build_alltime_rows(currency_filter):
    """Build table rows for models matching the currency filter, sorted by cost desc."""
    rows = ""
    keys = [k for k in alltime_by_model if is_rmb(k.split("/", 1)[0]) == currency_filter]
    # Sort by total cost including thinking
    def total_cost(k):
        return alltime_by_model[k]["cost"] + thinking_cost_by_model.get(k, {}).get("alltime", 0.0)
    for key in sorted(keys, key=lambda k: -total_cost(k)):
        d = alltime_by_model[key]
        prov, model = key.split("/", 1)
        name, color, icon = prov_info(prov)
        sym = currency_symbol(prov)
        think_tokens = thinking_by_model.get(key, {}).get("alltime", 0)
        think_cost = thinking_cost_by_model.get(key, {}).get("alltime", 0.0)
        row_total_cost = d["cost"] + think_cost
        think_cell = f'{fmt_tokens(think_tokens)}' if think_tokens > 0 else '—'
        rows += f"""
    <tr>
      <td {td}>{icon} <span style="color:{color};font-weight:600;">{name}</span></td>
      <td {td}><b>{model}</b></td>
      <td {td_mono}>{d["msgs"]}</td>
      <td {td_mono}>{fmt_tokens(d["input"])}</td>
      <td {td_mono}>{fmt_tokens(d["output"])}</td>
      <td {td_mono_think}>{think_cell}</td>
      <td {td_mono}>{fmt_tokens(d["cache_read"])}</td>
      <td {td_mono_cost}>{fmt_cost(row_total_cost, sym)}</td>
    </tr>"""
    return rows

model_rows_all_usd = build_alltime_rows(False)
model_rows_all_rmb = build_alltime_rows(True)

alltime_total_msgs = sum(d["msgs"] for d in alltime_by_provider.values())

# --- Media API 明细 ---
UNIT_DISPLAY = {"chars": "字符", "image": "张"}
media_rows_today = ""
for key in sorted(media_today.keys(), key=lambda k: -media_today[k]["cost"]):
    d = media_today[key]
    svc_name, svc_color, svc_icon = media_info(d["service"])
    unit_label = UNIT_DISPLAY.get(d["unit"], d["unit"])
    media_rows_today += f"""
    <tr>
      <td {td}>{svc_icon} <span style="color:{svc_color};font-weight:600;">{svc_name}</span></td>
      <td {td}><b>{d["model"]}</b></td>
      <td {td_mono}>{d["calls"]}</td>
      <td {td_mono}>{d["quantity"]:,} {unit_label}</td>
      <td {td_mono_cost}>{fmt_cost(d["cost"], "$")}</td>
    </tr>"""

media_rows_all = ""
for key in sorted(media_alltime.keys(), key=lambda k: -media_alltime[k]["cost"]):
    d = media_alltime[key]
    svc_name, svc_color, svc_icon = media_info(d["service"])
    unit_label = UNIT_DISPLAY.get(d["unit"], d["unit"])
    media_rows_all += f"""
    <tr>
      <td {td}>{svc_icon} <span style="color:{svc_color};font-weight:600;">{svc_name}</span></td>
      <td {td}><b>{d["model"]}</b></td>
      <td {td_mono}>{d["calls"]}</td>
      <td {td_mono}>{d["quantity"]:,} {unit_label}</td>
      <td {td_mono_cost}>{fmt_cost(d["cost"], "$")}</td>
    </tr>"""

# --- 定价参考 (按币种分组，输出价格降序) ---
def build_pricing_rows(currency_filter):
    rows = ""
    items = [(mid, p) for mid, p in pricing.items()
             if is_rmb(p.get("provider", "")) == currency_filter]
    # Sort by output price descending (most expensive first)
    for mid, p in sorted(items, key=lambda x: -x[1]["output"]):
        prov = p.get("provider", "")
        sym = "¥" if is_rmb(prov) else "$"
        m_in = p["input"] * 1000
        m_out = p["output"] * 1000
        m_cache = p["cache_read"] * 1000
        name, color, icon = prov_info(prov)
        rows += f"""
    <tr>
      <td {td}>{icon} <b>{mid}</b></td>
      <td {td_mono}>{sym}{m_in:.2f}</td>
      <td {td_mono}>{sym}{m_out:.2f}</td>
      <td {td_mono}>{sym}{m_cache:.2f}</td>
      <td {td_mono}>{fmt_tokens(p["context"])}</td>
    </tr>"""
    return rows

pricing_rows_usd = build_pricing_rows(False)
pricing_rows_rmb = build_pricing_rows(True)

now_bj = now_bjt.strftime("%Y年%m月%d日 %H:%M")
media_table_scope = "— 今日" if media_rows_today else "— 历史累计"

# --- 预计算 Web Search 区块 (避免 f-string 嵌套) ---
def build_web_search_section():
    if web_search_alltime == 0 and web_search_today == 0:
        return ""
    queries_html = ""
    if web_search_today_queries:
        items = ""
        for q in web_search_today_queries[-10:]:  # show last 10
            import html as _html
            items += f'<div style="padding:3px 0;font-size:12px;color:#555;">🔍 {_html.escape(q)}</div>'
        queries_html = f'<div style="margin-top:12px;padding:10px;background:#f8f9fa;border-radius:6px;">{items}</div>'
    error_note = f' · <span style="color:#e74c3c;">{web_search_errors_today} 失败</span>' if web_search_errors_today > 0 else ""
    avg_note = f" · 平均 {web_search_avg_ms}ms" if web_search_avg_ms > 0 else ""
    return f"""
  <div style="padding:0 30px 25px;">
    <div style="font-size:16px;color:#302b63;font-weight:600;
                border-bottom:2px solid #667eea;padding-bottom:10px;margin-bottom:15px;">
      🔎 Web Search (Brave API)
    </div>
    <div style="display:flex;gap:12px;flex-wrap:wrap;">
      <div style="flex:1;min-width:140px;background:white;border-radius:12px;padding:16px;
                  box-shadow:0 2px 8px rgba(0,0,0,.08);border-left:4px solid #fb542b;">
        <div style="font-size:13px;color:#666;margin-bottom:6px;">今日搜索</div>
        <div style="font-size:22px;font-weight:700;color:#333;">{web_search_today} <span style="font-size:14px;color:#999;">次</span></div>
        <div style="font-size:12px;color:#666;margin-top:6px;">${web_search_today_cost:.3f}{avg_note}{error_note}</div>
      </div>
      <div style="flex:1;min-width:140px;background:white;border-radius:12px;padding:16px;
                  box-shadow:0 2px 8px rgba(0,0,0,.08);border-left:4px solid #fb542b;">
        <div style="font-size:13px;color:#666;margin-bottom:6px;">昨日搜索</div>
        <div style="font-size:22px;font-weight:700;color:#333;">{web_search_yesterday} <span style="font-size:14px;color:#999;">次</span></div>
        <div style="font-size:12px;color:#666;margin-top:6px;">${web_search_yesterday * BRAVE_COST_PER_QUERY:.3f}</div>
      </div>
      <div style="flex:1;min-width:140px;background:white;border-radius:12px;padding:16px;
                  box-shadow:0 2px 8px rgba(0,0,0,.08);border-left:4px solid #fb542b;">
        <div style="font-size:13px;color:#666;margin-bottom:6px;">累计搜索</div>
        <div style="font-size:22px;font-weight:700;color:#333;">{web_search_alltime} <span style="font-size:14px;color:#999;">次</span></div>
        <div style="font-size:12px;color:#666;margin-top:6px;">${web_search_alltime_cost:.3f}</div>
      </div>
    </div>
    {queries_html}
  </div>"""

web_search_section = build_web_search_section()

# --- 预计算定价参考区块 (避免 f-string 嵌套) ---
pricing_th = 'style="padding:8px 12px;text-align:left;font-size:12px;color:#666;"'
pricing_th_r = 'style="padding:8px 12px;text-align:right;font-size:12px;color:#666;"'
pricing_table_head = f"""<tr style="background:#f0f0f0;">
          <th {pricing_th}>模型</th>
          <th {pricing_th_r}>输入</th><th {pricing_th_r}>输出</th>
          <th {pricing_th_r}>缓存读</th><th {pricing_th_r}>上下文窗口</th>
        </tr>"""

def build_pricing_section(title, rows):
    if not rows:
        return ""
    return f"""
  <div style="padding:0 30px 15px;">
    <div style="font-size:14px;color:#555;font-weight:600;margin-bottom:10px;">{title}</div>
    <div style="overflow-x:auto;">
    <table style="width:100%;border-collapse:collapse;background:white;border-radius:8px;overflow:hidden;">
      <thead>{pricing_table_head}</thead>
      <tbody>{rows}</tbody>
    </table>
    </div>
  </div>"""

pricing_usd_section = build_pricing_section("💵 USD 模型", pricing_rows_usd)
pricing_rmb_section = build_pricing_section("💴 RMB 模型", pricing_rows_rmb)

# --- 预计算历史累计区块 (避免 f-string 嵌套) ---
th_hist = 'style="padding:10px 12px;text-align:left;color:white;font-weight:600;font-size:13px;"'
hist_table_head = f"""<tr style="background:linear-gradient(135deg,#667eea,#764ba2);">
          <th {th_hist}>厂商</th><th {th_hist}>模型</th><th {th_hist}>调用</th>
          <th {th_hist}>输入</th><th {th_hist}>输出</th><th {th_hist}>🧠思考</th><th {th_hist}>缓存读</th><th {th_hist}>费用</th>
        </tr>"""

def build_history_section(title, rows, total_msgs, total_cost_str):
    if not rows:
        return ""
    return f"""
  <div style="padding:0 30px 25px;">
    <div style="font-size:16px;color:#302b63;font-weight:600;
                border-bottom:2px solid #667eea;padding-bottom:10px;margin-bottom:15px;">
      📈 {title} ({total_msgs} 次调用 · {total_cost_str})
    </div>
    <div style="overflow-x:auto;">
    <table style="width:100%;border-collapse:collapse;background:white;border-radius:8px;overflow:hidden;">
      <thead>{hist_table_head}</thead>
      <tbody>{rows}</tbody>
    </table>
    </div>
  </div>"""

history_usd_section = build_history_section(
    "历史累计 · USD", model_rows_all_usd,
    all_usd["msgs"], f"${all_usd['cost']:.4f}")
history_rmb_section = build_history_section(
    "历史累计 · RMB", model_rows_all_rmb,
    all_rmb["msgs"], f"¥{all_rmb['cost']:.2f}")

# --- 费用总览区块 ---
def cost_badge(rmb_d, usd_d, label):
    """生成双币种费用 badge"""
    parts = []
    if rmb_d["msgs"] > 0:
        parts.append(f'<span style="color:#e74c3c;font-size:32px;font-weight:700;">¥{rmb_d["cost"]:.2f}</span>')
    if usd_d["msgs"] > 0:
        parts.append(f'<span style="color:#2196f3;font-size:32px;font-weight:700;">${usd_d["cost"]:.4f}</span>')
    if not parts:
        parts.append('<span style="color:#999;font-size:24px;">暂无数据</span>')
    sep = '<span style="color:#ccc;font-size:20px;margin:0 15px;">+</span>'
    return sep.join(parts)

html = f"""<!DOCTYPE html>
<html><head><meta charset="UTF-8"></head>
<body style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI','PingFang SC',sans-serif;
             background:linear-gradient(135deg,#0f0c29 0%,#302b63 50%,#24243e 100%);
             margin:0;padding:20px;">
<div style="max-width:900px;margin:0 auto;background:#f5f5f5;border-radius:16px;
            box-shadow:0 20px 60px rgba(0,0,0,.4);overflow:hidden;">

  <!-- 头部 -->
  <div style="background:linear-gradient(135deg,#e8eaf6 0%,#f5f5f5 50%,#e3e7ed 100%);
              color:#333;padding:35px 30px;text-align:center;">
    <h1 style="margin:0;font-size:24px;font-weight:300;letter-spacing:3px;color:#222;">🤖 AI 模型使用监控</h1>
    <div style="margin-top:8px;color:#666;font-size:13px;">OpenAI · Anthropic · Google · Moonshot · Alibaba | Token + TTS + 图片 全平台统一监控</div>
    <div style="margin-top:14px;font-size:14px;background:rgba(0,0,0,.06);color:#444;
                display:inline-block;padding:8px 22px;border-radius:20px;">{now_bj} 北京时间</div>
  </div>

  <!-- 今日费用总览 - 双币种 -->
  <div style="padding:25px 30px;">
    <div style="text-align:center;margin-bottom:20px;">
      <div style="font-size:14px;color:#666;margin-bottom:12px;">今日费用 ({today_str})</div>
      <div style="margin:10px 0;">{cost_badge(today_rmb, today_usd, "today")}</div>
      <div style="font-size:13px;color:#999;margin-top:10px;">
        {today_total_msgs} 次调用 · {fmt_tokens(today_total_input)} 输入 · {fmt_tokens(today_total_output)} 输出
      </div>
    </div>
    <div style="display:flex;gap:15px;flex-wrap:wrap;">
      {provider_cards}
    </div>
  </div>

  <!-- 今日按模型明细 -->
  <div style="padding:0 30px 25px;">
    <div style="font-size:16px;color:#302b63;font-weight:600;
                border-bottom:2px solid #667eea;padding-bottom:10px;margin-bottom:15px;">
      📊 今日按模型明细
    </div>
    <div style="overflow-x:auto;">
    <table style="width:100%;border-collapse:collapse;background:white;border-radius:8px;overflow:hidden;">
      <thead>
        <tr style="background:linear-gradient(135deg,#667eea,#764ba2);">
          <th {th}>厂商</th><th {th}>模型</th><th {th}>调用</th>
          <th {th}>输入</th><th {th}>输出</th><th {th}>🧠思考</th><th {th}>缓存读</th><th {th}>费用</th>
        </tr>
      </thead>
      <tbody>{model_rows_today}</tbody>
    </table>
    </div>
  </div>

  <!-- Media API (TTS / 图片) -->
  {"" if not media_rows_today and not media_rows_all else f"""
  <div style="padding:0 30px 25px;">
    <div style="font-size:16px;color:#302b63;font-weight:600;
                border-bottom:2px solid #667eea;padding-bottom:10px;margin-bottom:15px;">
      🎨 Media API (TTS / 图片生成) {media_table_scope}
    </div>
    <div style="overflow-x:auto;">
    <table style="width:100%;border-collapse:collapse;background:white;border-radius:8px;overflow:hidden;">
      <thead>
        <tr style="background:linear-gradient(135deg,#667eea,#764ba2);">
          <th {th}>服务</th><th {th}>模型</th><th {th}>调用</th>
          <th {th}>用量</th><th {th}>费用</th>
        </tr>
      </thead>
      <tbody>{media_rows_today if media_rows_today else media_rows_all}</tbody>
    </table>
    </div>
    <div style="font-size:11px;color:#999;margin-top:8px;text-align:right;">
      {'今日 $' + f'{media_today_usd:.4f}' if media_today_usd > 0 else '今日无调用'}
       · 累计 ${f'{media_alltime_usd:.4f}'} ({all_media_calls} 次)
    </div>
    {"" if audio_count == 0 and image_count == 0 else f'''
    <div style="display:flex;gap:12px;flex-wrap:wrap;margin-top:15px;">
      {"" if audio_count == 0 else f"""
      <div style="flex:1;min-width:200px;background:white;border-radius:12px;padding:16px;
                  box-shadow:0 2px 8px rgba(0,0,0,.08);border-left:4px solid #10a37f;">
        <div style="font-size:13px;color:#666;margin-bottom:6px;">🔊 今日语音</div>
        <div style="font-size:22px;font-weight:700;color:#333;">{audio_generated_count} <span style="font-size:14px;color:#999;">条生成</span>
          {f' · {audio_count} <span style="font-size:14px;color:#999;">条投递</span>' if audio_count != audio_generated_count else ''}</div>
        <div style="font-size:12px;color:#666;margin-top:8px;">
          总大小 {fmt_size(audio_total_bytes)} · 平均 {fmt_size(audio_avg_bytes)}/条
        </div>
      </div>
      """}
      {"" if image_count == 0 else f"""
      <div style="flex:1;min-width:200px;background:white;border-radius:12px;padding:16px;
                  box-shadow:0 2px 8px rgba(0,0,0,.08);border-left:4px solid #4285f4;">
        <div style="font-size:13px;color:#666;margin-bottom:6px;">🎨 今日图片</div>
        <div style="font-size:22px;font-weight:700;color:#333;">{image_generated_count} <span style="font-size:14px;color:#999;">张生成</span>
          {f' · {image_count} <span style="font-size:14px;color:#999;">张投递</span>' if image_count != image_generated_count else ''}</div>
        <div style="font-size:12px;color:#666;margin-top:8px;">
          总大小 {fmt_size(image_total_bytes)} · 平均 {fmt_size(image_avg_bytes)}/张
        </div>
        {f'<div style="font-size:11px;color:#888;margin-top:6px;">{image_source_breakdown}</div>' if image_source_breakdown else ''}
      </div>
      """}
    </div>
    '''}
  </div>
  """}

  {web_search_section}

  <!-- 用量趋势：昨日 / 同比 / 7天 / 30天 / 环比 -->
  <div style="padding:0 30px 25px;">
    <div style="font-size:16px;color:#302b63;font-weight:600;
                border-bottom:2px solid #667eea;padding-bottom:10px;margin-bottom:15px;">
      📆 用量趋势
    </div>
    <div style="display:flex;gap:12px;flex-wrap:wrap;">
      {trend_cards}
    </div>
  </div>

  {history_usd_section}
  {history_rmb_section}

  <!-- 定价参考 -->
  <div style="padding:0 30px 25px;">
    <div style="font-size:16px;color:#302b63;font-weight:600;
                border-bottom:2px solid #667eea;padding-bottom:10px;margin-bottom:15px;">
      💰 模型定价参考 (每 1M tokens)
    </div>
    {pricing_usd_section}
    {pricing_rmb_section}
    <div style="font-size:11px;color:#999;margin-top:8px;padding:0 4px;">
      🧠 Gemini 推理模型的思考 token 按输出价格计费，通过 thinking-proxy 单独追踪
    </div>
  </div>

  <!-- 页脚 -->
  <div style="background:#1a1a2e;color:rgba(255,255,255,.7);padding:22px;
              text-align:center;font-size:12px;line-height:1.8;">
    <p>📡 数据来源: OpenClaw 会话日志 ({len(all_files)} 个文件) + Media API 日志 + Thinking Proxy 日志</p>
    <p>💱 Moonshot / Alibaba 以人民币计费 | OpenAI / Anthropic / Google 以美元计费</p>
    <p>⏱️ 每小时自动推送 | 费用基于 openclaw.json 配置定价</p>
    <p style="opacity:.6;">🦞 龙虾助手 | AI 模型使用监控</p>
  </div>

</div>
</body></html>"""

print(html)
PYEOF
)

if [ -z "$HTML" ]; then
    echo "[$NOW] ❌ HTML 生成失败" >> "$LOG_FILE"
    exit 1
fi

# ============================================================
# 发送邮件
# ============================================================
MAIL_FILE=$(mktemp)
trap "rm -f '$MAIL_FILE'" EXIT
DATE_LABEL=$(TZ='Asia/Shanghai' date '+%m月%d日 %H:%M')
SUBJECT=$(echo -n "🤖 AI模型监控 - ${DATE_LABEL}" | base64 -w 0)

printf "From: \"AI模型监控\" <%s>\r\nTo: %s\r\nSubject: =?UTF-8?B?%s?=\r\nContent-Type: text/html; charset=UTF-8\r\nMIME-Version: 1.0\r\n\r\n%s" \
    "$SMTP_USER" "$MAIL_TO" "$SUBJECT" "$HTML" > "$MAIL_FILE"

CURL_OUTPUT=$(curl --silent --ssl-reqd \
    --max-time 30 \
    --url "smtps://smtp.163.com:465" \
    --user "$SMTP_USER:$SMTP_PASS" \
    --mail-from "$SMTP_USER" \
    --mail-rcpt "$MAIL_TO" \
    --upload-file "$MAIL_FILE" 2>&1)

SEND_RESULT=$?

# 记录日志
echo "[$NOW] Report sent (result: $SEND_RESULT) ${CURL_OUTPUT:+| $CURL_OUTPUT}" >> "$LOG_FILE"

if [ $SEND_RESULT -eq 0 ]; then
    echo "✅ AI模型监控报告已发送 - 北京时间 $NOW"
else
    echo "❌ 邮件发送失败 - 北京时间 $NOW"
fi
