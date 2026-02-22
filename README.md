# AI Model Usage Monitor

A comprehensive monitoring script for tracking token usage, media generation costs, and API spend across multiple AI providers. Designed for [OpenClaw](https://github.com/nicepkg/openclaw) gateway deployments, it scans session logs and produces a styled HTML email report on a scheduled basis.

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

```
┌─────────────────────────┐
│   Data Sources          │
├─────────────────────────┤
│ Session JSONL files     │──┐
│ (.jsonl / .reset / .bak)│  │
├─────────────────────────┤  │
│ media-usage.jsonl       │──┼──► Python aggregation ──► HTML report ──► SMTP email
│ (TTS + image logs)      │  │
├─────────────────────────┤  │
│ Gateway debug logs      │──┘
│ (/tmp/openclaw/*.log)   │
└─────────────────────────┘
```

- **Bash wrapper**: handles environment setup, email composition, and SMTP delivery via `curl`
- **Embedded Python**: performs all data scanning, cost calculation, deduplication, trend computation, and HTML generation

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

## Usage

### Manual Run

```bash
./model-monitor.sh
```

### Scheduled (cron)

```cron
0 * * * * /home/ubuntu/model-monitor.sh >> /home/ubuntu/logs/model-monitor-cron.log 2>&1
```

### Key File Paths

| Path | Purpose |
|------|---------|
| `~/.openclaw/agents/main/sessions/*.jsonl` | Session conversation logs |
| `~/.openclaw/logs/media-usage.jsonl` | TTS and image generation usage log |
| `/tmp/openclaw/openclaw-*.log` | Gateway debug logs (built-in tool detection) |
| `~/.openclaw/openclaw.json` | Master config with model pricing |
| `~/logs/model-monitor.log` | Script execution log |

## Design Decisions

- **Ignores JSONL `usage.cost.total`**: The gateway-reported cost field has a systematic 1000x undercount (unit interpretation bug). Costs are always calculated independently from token counts and config pricing.
- **Triple-source media tracking**: Media API usage is captured from (1) script-logged `media-usage.jsonl`, (2) gateway debug logs for built-in tools, and (3) gateway delivery logs for actual WhatsApp send stats. Built-in tool entries are persisted back to `media-usage.jsonl` for durability.
- **Message deduplication**: A `seen_ids` set prevents double-counting when the same message appears across `.jsonl`, `.reset`, and `.bak` files.
- **Timezone handling**: All JSONL timestamps are UTC; the script converts to Beijing Time (UTC+8) for date bucketing and display.

## License

MIT
