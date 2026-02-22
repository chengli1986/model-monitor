---
name: modelusage
description: Run AI model usage & cost monitor and send email report.
user-invocable: true
metadata: {"openclaw":{"emoji":"📊","requires":{"bins":["bash","python3"]}}}
---

# Model Usage Monitor

Run the model usage monitor and image digest to analyze AI model token usage, costs (USD + RMB), session statistics, and daily image generation recap. Sends two HTML email reports.

## Usage

Run both commands:

```bash
bash /home/ubuntu/model-monitor.sh
python3 /home/ubuntu/image-digest.py
```

When the user types `/modelusage`, run both commands above and report the results. Always run both — the model usage report and the image digest report.
