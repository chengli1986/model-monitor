# Model Monitor

AI model token usage and cost tracking: scans OpenClaw session JSONL files, aggregates by model/provider, generates HTML email with trend charts (7d/30d bar charts).

## Architecture
- `model-monitor.sh`: Bash wrapper with embedded Python heredoc — processes JSONL, generates matplotlib charts, builds HTML email
- `image-digest.py`: daily image digest — parses gateway logs + `media-usage.jsonl`
- `gemini-thinking-proxy.py`: reverse proxy (port 18790) capturing Gemini thinking tokens

## Key Facts
- **`usage.cost.total` is 1000x too low** — ALWAYS use `calc_cost()` function
- JSONL timestamps are UTC — convert to BJT (UTC+8) for date bucketing
- Synthetic keys `_thinking`, `_media_api`, `_web_search` in `daily_by_provider` are always USD
- matplotlib CJK rendering fails with DejaVu Sans — use English-only chart titles
- Model aliases: "qwen-max" → "qwen3-max", "qwen-plus" → "qwen3.5-plus"
- Dual-currency: RMB providers (moonshot, alibaba) in ¥; USD providers (openai, anthropic, google) in $
- Config pricing is per 1K tokens; email display converts to per 1M tokens
- Dedup JSONL via `toolCallId` across .jsonl/.reset/.bak files
- Gemini config: `supportsStore: false`; Alibaba/Moonshot: `supportsDeveloperRole: false`

## Testing
- `bash -n model-monitor.sh`
- `python3 -m py_compile image-digest.py`
- `python3 -m py_compile gemini-thinking-proxy.py`
