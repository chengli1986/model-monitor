# AI Model Usage Monitor

A monitoring suite for tracking AI model token usage, media generation costs, and API spend across multiple providers. Designed for [OpenClaw](https://github.com/nicepkg/openclaw) gateway deployments.

### Scripts

| Script | Schedule | Purpose |
|--------|----------|---------|
| `model-monitor.sh` | Hourly | Token usage & cost report across all providers (HTML email) |
| `image-digest.py` | Daily at midnight BJT | Recap email with all AI-generated images from the day, embedded inline |

## Sample Report

A sample HTML report is included at [`sample-report.html`](sample-report.html). Open it in a browser to see the full layout. The report includes:

- A headline dual-currency cost banner (USD + RMB)
- Per-provider summary cards with call counts and token volumes
- A Media API card for TTS and image generation spend
- Detailed per-model breakdown tables (today + alltime)
- Trend cards with 7-day / 30-day rolling totals and percentage change badges
- A pricing reference table showing configured rates per 1M tokens

## Supported Providers

| Provider | Currency | Models |
|----------|----------|--------|
| OpenAI | USD | GPT-4.1, GPT-5-mini, GPT-5.2, TTS, etc. |
| Anthropic | USD | Claude Opus, Sonnet, Haiku |
| Google | USD | Gemini 2.5 Flash/Pro, Imagen |
| Moonshot | RMB | Kimi K2.5 |
| Alibaba | RMB | Qwen 3-Max, Qwen 3.5-Plus |

## What It Tracks

### Token Usage
- Input, output, cache read, and cache write tokens per model
- Cost calculated from per-model pricing defined in `openclaw.json`
- Deduplication across active, reset, and backup JSONL session files

### Media Generation
- **TTS (Text-to-Speech)**: Character count, cost, and audio file delivery stats
- **Image Generation**: Per-image cost tracking across API calls
- Tracks both skill-script media (logged to `media-usage.jsonl`) and built-in gateway tool calls (parsed from gateway debug logs)
- Built-in tool usage is automatically persisted to `media-usage.jsonl` so alltime counts survive log rotation

### Trend Analysis
- Today vs. yesterday comparison with percentage change badges
- Rolling 7-day and 30-day totals with week-over-week / month-over-month deltas
- Dual-currency (USD + RMB) breakdowns at every level

## Report Sections

The generated HTML email contains:

1. **Cost Overview** — headline dual-currency total for the day
2. **Provider Cards** — per-provider spend with call counts and token volumes
3. **Today's Model Breakdown** — table of every model used today with full token details
4. **Media API** — TTS and image generation usage with generated vs. delivered counts
5. **Trends** — yesterday, 7-day, 30-day rolling costs with directional change indicators
6. **Historical Totals** — alltime per-model cumulative usage
7. **Pricing Reference** — configured per-1M-token rates for all models

## Architecture

### model-monitor.sh

```
┌─────────────────────────┐
│   Data Sources          │
├─────────────────────────┤
│ Session JSONL files     │──┐
│ (.jsonl / .reset / .bak)│  │
├─────────────────────────┤  │
│ media-usage.jsonl       │──┼──► Python aggregation ──► HTML report ──► SMTP email (curl)
│ (TTS + image logs)      │  │
├─────────────────────────┤  │
│ Gateway debug logs      │──┘
│ (/tmp/openclaw/*.log)   │
└─────────────────────────┘
```

- **Bash wrapper**: handles environment setup, email composition, and SMTP delivery via `curl`
- **Embedded Python**: performs all data scanning, cost calculation, deduplication, trend computation, and HTML generation

### image-digest.py

```
Gateway debug logs ──► collect image deliveries ──► filter to target BJT date
(/tmp/openclaw/*.log)   for mediaKind=image          ──► embed inline (CID)
                                                      ──► MIME email (smtplib)
```

- Standalone Python script using `smtplib` (no `curl` dependency)
- Parses gateway logs for `mediaKind: "image"` delivery entries
- Attaches each image inline via `Content-ID` references (works in most email clients)
- At midnight BJT, collects the previous day's images; manual runs collect today's

## Prerequisites

- Python 3.10+
- `curl` with SSL support
- An [OpenClaw](https://github.com/nicepkg/openclaw) gateway deployment with session logging enabled
- SMTP credentials for email delivery (configured via environment variables)

## Configuration

### Environment Variables

Sourced from `~/.stock-monitor.env`:

| Variable | Description |
|----------|-------------|
| `SMTP_USER` | SMTP sender email address |
| `SMTP_PASS` | SMTP password or app-specific password |
| `MAIL_TO` | Recipient email address |

### Model Pricing

Defined in `~/.openclaw/openclaw.json` under `models.providers.<id>.models[].cost`:

```json
{
  "id": "gpt-4.1",
  "cost": {
    "input": 0.002,
    "output": 0.008,
    "cacheRead": 0.0005,
    "cacheWrite": 0.002
  }
}
```

All prices are **per 1K tokens**. The report displays them converted to per 1M tokens for readability.

### RMB vs USD Providers

Providers are classified by currency in the script:

```python
RMB_PROVIDERS = {"moonshot", "alibaba"}  # all others default to USD
```

To add a new RMB-denominated provider, add its ID to this set.

### Model Aliases

Some providers return a different model name in API responses than what's configured. The `MODEL_ALIASES` dict maps API-returned names to config names so pricing lookups succeed:

```python
MODEL_ALIASES = {
    "qwen-max": "qwen3-max",
    "qwen-plus": "qwen3.5-plus",
}
```

If you add a model and see `$0.00` costs despite actual usage, check whether the API returns a different name than your config ID — if so, add a mapping here.

## Usage

### Manual Run

```bash
# Hourly usage report
./model-monitor.sh

# Image digest (collects today's images when run during the day)
python3 image-digest.py
```

### Scheduled (cron)

```cron
# Usage report — every hour at :02
2 * * * * /path/to/model-monitor.sh >> /path/to/logs/model-monitor-cron.log 2>&1

# Image digest — midnight BJT (16:00 UTC), recaps the day's images
0 16 * * * /usr/bin/python3 /path/to/image-digest.py >> /path/to/logs/image-digest.log 2>&1
```

### Key File Paths

| Path | Purpose |
|------|---------|
| `~/.openclaw/agents/main/sessions/*.jsonl` | Session conversation logs |
| `~/.openclaw/logs/media-usage.jsonl` | TTS and image generation usage log |
| `/tmp/openclaw/openclaw-*.log` | Gateway debug logs (built-in tool detection) |
| `~/.openclaw/openclaw.json` | Master config with model pricing |
| `~/logs/model-monitor.log` | model-monitor.sh execution log |
| `~/logs/image-digest.log` | image-digest.py execution log |

## Adding a New Provider or Model

### Adding a Model to an Existing Provider

1. Add the model entry to `openclaw.json` under the provider's `models` array with `id` and `cost` fields
2. If the API returns a different model name than your `id`, add a mapping to `MODEL_ALIASES` in the script
3. Restart the gateway: `systemctl --user restart openclaw-gateway`

### Adding a New Provider

1. Add the provider config to `openclaw.json` under `models.providers` with its models and pricing
2. Add a display entry in `PROVIDER_DISPLAY` for the report card color and icon:
   ```python
   PROVIDER_DISPLAY = {
       "your-provider": ("Display Name", "#hex-color", "🔵"),
   }
   ```
3. Add the provider ID to the card rendering loop:
   ```python
   for prov in ["moonshot", "openai", "anthropic", "alibaba", "google", "your-provider"]:
   ```
4. If the provider uses RMB, add it to `RMB_PROVIDERS`
5. Restart the gateway

## Expected Data Formats

### Session JSONL Messages

Each line in a session `.jsonl` file is a JSON object. The script processes entries with `type: "message"`:

```json
{
  "type": "message",
  "id": "b0847274",
  "timestamp": "2026-02-21T18:30:39.081Z",
  "message": {
    "provider": "alibaba",
    "model": "qwen3.5-plus",
    "usage": {
      "input": 14899,
      "output": 435,
      "cacheRead": 0,
      "cacheWrite": 0
    }
  }
}
```

Required fields: `type`, `id`, `timestamp`, `message.provider`, `message.model`, `message.usage.{input,output,cacheRead,cacheWrite}`.

### Media Usage Log

Each line in `media-usage.jsonl`:

```json
{
  "id": "1c9a2a80-659a-4d93-a1f3-12211abfe0ad",
  "ts": "2026-02-21T18:28:09Z",
  "service": "tts",
  "provider": "openai",
  "model": "tts-1",
  "unit": "chars",
  "quantity": 32,
  "cost": 0.00048,
  "meta": { "voice": "alloy" }
}
```

- `service`: `"tts"` | `"image"` | `"tts-builtin"` | `"image-builtin"`
- `unit`: `"chars"` for TTS, `"image"` for image generation
- `cost`: USD cost of this API call

## Troubleshooting

### Model shows $0.00 cost despite having usage

The model ID in API responses doesn't match the `id` in `openclaw.json`. Check `MODEL_ALIASES` — you likely need to add a mapping. Run this to find unpriced models:

```bash
# Inside the script's Python, add temporarily:
for key in today_by_model:
    model = key.split("/", 1)[1]
    if model not in pricing and resolve_model(model) not in pricing:
        print(f"UNPRICED: {key}", file=sys.stderr)
```

### Report shows stale or missing models

The gateway caches its model catalog in memory. After changing `openclaw.json`, restart:

```bash
systemctl --user restart openclaw-gateway
```

### Media usage not tracked (built-in tools)

If users invoke the gateway's built-in `tts` or `image` tools (instead of skill scripts), those calls only appear in gateway debug logs at `/tmp/openclaw/openclaw-*.log`. The script auto-detects and persists these to `media-usage.jsonl`, but if the logs are rotated before the script runs, the entries are lost. The hourly cron schedule prevents this under normal conditions.

### Email delivery fails silently

Check `~/logs/model-monitor.log` for curl exit codes and error output. Common issues:
- Exit 28: connection timeout (SMTP server unreachable)
- Exit 67: authentication failed (check `SMTP_USER` / `SMTP_PASS`)
- Exit 60: SSL certificate problem

### Duplicate counting

If message counts seem inflated, check for overlapping data across `.jsonl` + `.reset.*` + `.bak.*` files. The script deduplicates by message `id`, but messages without an `id` field bypass dedup. Run:

```bash
python3 -c "
import json, glob, os
no_id = 0
for f in glob.glob(os.path.expanduser('~/.openclaw/agents/main/sessions/*.jsonl*')):
    for line in open(f):
        obj = json.loads(line.strip())
        if obj.get('type') == 'message' and not obj.get('id'):
            no_id += 1
print(f'Messages without id: {no_id}')
"
```

## Design Decisions

- **Ignores JSONL `usage.cost.total`**: The gateway-reported cost field has a systematic 1000x undercount (unit interpretation bug). Costs are always calculated independently from token counts and config pricing.
- **Triple-source media tracking**: Media API usage is captured from (1) script-logged `media-usage.jsonl`, (2) gateway debug logs for built-in tools, and (3) gateway delivery logs for actual WhatsApp send stats. Built-in tool entries are persisted back to `media-usage.jsonl` for durability.
- **Message deduplication**: A `seen_ids` set prevents double-counting when the same message appears across `.jsonl`, `.reset`, and `.bak` files.
- **Timezone handling**: All JSONL timestamps are UTC; the script converts to Beijing Time (UTC+8) for date bucketing and display.

## License

MIT
