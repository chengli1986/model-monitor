#!/usr/bin/env python3
"""
Daily image digest email - sends all images generated during the day.
Runs at midnight BJT (16:00 UTC) via cron.
Parses gateway logs for image deliveries, attaches images inline.
"""

import json
import glob
import os
import sys
import smtplib
from datetime import datetime, timezone, timedelta
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.mime.image import MIMEImage
from email.header import Header
from pathlib import Path

LOG_FILE = os.path.expanduser("~/logs/image-digest.log")
GATEWAY_LOG_DIR = "/tmp/openclaw"
BJT = timezone(timedelta(hours=8))
ENV_FILE = os.path.expanduser("~/.stock-monitor.env")


def load_env():
    """Load SMTP credentials from .stock-monitor.env."""
    env = {}
    try:
        with open(ENV_FILE) as f:
            for line in f:
                line = line.strip()
                if "=" in line and not line.startswith("#"):
                    key, _, val = line.partition("=")
                    env[key.strip()] = val.strip().strip('"').strip("'")
    except IOError:
        pass
    return env


def collect_images_for_date(target_date_str):
    """Parse gateway logs and collect unique image deliveries for a BJT date.

    A BJT date spans UTC: (D-1)T16:00 to DT16:00.
    """
    target_date = datetime.strptime(target_date_str, "%Y-%m-%d").date()

    # BJT day boundaries in UTC
    bjt_start = datetime(target_date.year, target_date.month, target_date.day,
                         tzinfo=BJT)
    bjt_end = bjt_start + timedelta(days=1)

    # Gateway log files that could contain entries for this BJT date
    utc_dates = set()
    cursor = bjt_start.astimezone(timezone.utc)
    while cursor < bjt_end.astimezone(timezone.utc):
        utc_dates.add(cursor.strftime("%Y-%m-%d"))
        cursor += timedelta(days=1)
    # Also include the UTC date of the end boundary
    utc_dates.add(bjt_end.astimezone(timezone.utc).strftime("%Y-%m-%d"))

    images = {}  # mediaUrl -> {ts_bjt, bytes, url}

    for utc_date in sorted(utc_dates):
        log_path = f"{GATEWAY_LOG_DIR}/openclaw-{utc_date}.log"
        if not os.path.isfile(log_path):
            continue
        try:
            with open(log_path) as f:
                for line in f:
                    line = line.strip()
                    if not line or '"image"' not in line:
                        continue
                    try:
                        obj = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    msg = obj.get("1", "")
                    if not isinstance(msg, dict):
                        continue
                    if msg.get("mediaKind") != "image":
                        continue
                    url = msg.get("mediaUrl", "")
                    size = msg.get("mediaSizeBytes", 0)
                    if not url or size <= 0:
                        continue
                    ts = obj.get("_meta", {}).get("date", "")
                    if not ts:
                        continue
                    try:
                        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                        dt_bjt = dt.astimezone(BJT)
                    except (ValueError, TypeError):
                        continue
                    if dt_bjt.strftime("%Y-%m-%d") != target_date_str:
                        continue
                    if url not in images:
                        images[url] = {
                            "ts": dt_bjt,
                            "bytes": size,
                            "url": url,
                        }
        except IOError:
            continue

    # Sort by timestamp
    return sorted(images.values(), key=lambda x: x["ts"])


def fmt_size(b):
    if b >= 1_048_576:
        return f"{b / 1_048_576:.1f} MB"
    if b >= 1024:
        return f"{b / 1024:.1f} KB"
    return f"{b} B"


def build_email(target_date_str, image_entries):
    """Build multipart MIME email with inline images."""
    # Filter to images that still exist on disk
    valid = []
    for entry in image_entries:
        path = entry["url"]
        if os.path.isfile(path):
            valid.append(entry)

    if not valid:
        return None

    total_bytes = sum(e["bytes"] for e in valid)
    avg_bytes = total_bytes // len(valid)

    # Build HTML
    grid_items = ""
    for i, entry in enumerate(valid):
        fname = os.path.basename(entry["url"])
        ts_str = entry["ts"].strftime("%H:%M")
        cid = f"img{i}"
        grid_items += f"""
        <div style="display:inline-block;vertical-align:top;margin:8px;text-align:center;max-width:300px;">
          <img src="cid:{cid}" style="max-width:280px;max-height:280px;border-radius:8px;
               box-shadow:0 2px 8px rgba(0,0,0,.15);display:block;margin:0 auto;" />
          <div style="font-size:11px;color:#666;margin-top:6px;word-break:break-all;">{fname}</div>
          <div style="font-size:10px;color:#999;">{ts_str} &middot; {fmt_size(entry['bytes'])}</div>
        </div>"""

    html = f"""<!DOCTYPE html>
<html><head><meta charset="UTF-8"></head>
<body style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI','PingFang SC',sans-serif;
             background:#f0f2f5;margin:0;padding:20px;">
<div style="max-width:700px;margin:0 auto;background:white;border-radius:16px;
            box-shadow:0 4px 20px rgba(0,0,0,.1);overflow:hidden;">

  <div style="background:linear-gradient(135deg,#4285f4,#667eea);color:white;padding:28px 24px;text-align:center;">
    <h1 style="margin:0;font-size:20px;font-weight:400;letter-spacing:2px;">
      🎨 今日图片汇总
    </h1>
    <div style="margin-top:8px;font-size:13px;opacity:.85;">{target_date_str}</div>
  </div>

  <div style="padding:20px 24px;">
    <div style="display:flex;gap:20px;flex-wrap:wrap;margin-bottom:20px;">
      <div style="flex:1;min-width:120px;background:#f8f9fa;border-radius:10px;padding:14px;text-align:center;">
        <div style="font-size:28px;font-weight:700;color:#333;">{len(valid)}</div>
        <div style="font-size:12px;color:#999;">张图片</div>
      </div>
      <div style="flex:1;min-width:120px;background:#f8f9fa;border-radius:10px;padding:14px;text-align:center;">
        <div style="font-size:28px;font-weight:700;color:#333;">{fmt_size(total_bytes)}</div>
        <div style="font-size:12px;color:#999;">总大小</div>
      </div>
      <div style="flex:1;min-width:120px;background:#f8f9fa;border-radius:10px;padding:14px;text-align:center;">
        <div style="font-size:28px;font-weight:700;color:#333;">{fmt_size(avg_bytes)}</div>
        <div style="font-size:12px;color:#999;">平均大小</div>
      </div>
    </div>

    <div style="text-align:center;">
      {grid_items}
    </div>
  </div>

  <div style="background:#f8f9fa;padding:16px;text-align:center;font-size:11px;color:#999;">
    🦞 龙虾助手 | 每日图片汇总 · 自动生成
  </div>

</div>
</body></html>"""

    # Build MIME message
    msg = MIMEMultipart("related")
    msg["Subject"] = Header(f"🎨 今日图片汇总 - {target_date_str} ({len(valid)} 张)", "utf-8")

    html_part = MIMEText(html, "html", "utf-8")
    msg.attach(html_part)

    # Attach images inline
    for i, entry in enumerate(valid):
        try:
            with open(entry["url"], "rb") as img_f:
                img_data = img_f.read()
            # Determine subtype from extension
            ext = os.path.splitext(entry["url"])[1].lower()
            subtype = {"png": "png", "jpg": "jpeg", "jpeg": "jpeg", "gif": "gif", "webp": "webp"}.get(ext.lstrip("."), "png")
            img_part = MIMEImage(img_data, _subtype=subtype)
            img_part.add_header("Content-ID", f"<img{i}>")
            img_part.add_header("Content-Disposition", "inline", filename=os.path.basename(entry["url"]))
            msg.attach(img_part)
        except IOError:
            continue

    return msg, len(valid)


def log(message):
    os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
    now = datetime.now(BJT).strftime("%Y-%m-%d %H:%M:%S")
    with open(LOG_FILE, "a") as f:
        f.write(f"[{now}] {message}\n")


def main():
    env = load_env()
    smtp_user = env.get("SMTP_USER", "")
    smtp_pass = env.get("SMTP_PASS", "")
    mail_to = env.get("MAIL_TO", "")

    if not all([smtp_user, smtp_pass, mail_to]):
        log("ERROR: Missing SMTP credentials in .stock-monitor.env")
        sys.exit(1)

    # Target date: today in BJT (when run at midnight, this covers the day that just ended)
    now_bjt = datetime.now(BJT)
    # If run at exactly midnight, we want "today" (the date that just started).
    # But actually we want the day that just ended. At 00:00 Feb 22, we want Feb 21's images.
    # Use yesterday if current hour is 0 (just past midnight), otherwise today.
    if now_bjt.hour == 0:
        target = (now_bjt - timedelta(days=1)).strftime("%Y-%m-%d")
    else:
        # Manual run during the day — use today
        target = now_bjt.strftime("%Y-%m-%d")

    print(f"Collecting images for {target} (BJT)...")
    entries = collect_images_for_date(target)
    print(f"Found {len(entries)} unique image deliveries")

    if not entries:
        log(f"No images found for {target}")
        print("No images found. Skipping email.")
        return

    result = build_email(target, entries)
    if result is None:
        log(f"No image files still on disk for {target}")
        print("No image files on disk. Skipping email.")
        return

    msg, count = result
    msg["From"] = smtp_user
    msg["To"] = mail_to

    try:
        with smtplib.SMTP_SSL("smtp.163.com", 465, timeout=30) as server:
            server.login(smtp_user, smtp_pass)
            server.sendmail(smtp_user, mail_to, msg.as_string())
        log(f"OK: Sent {count} images for {target}")
        print(f"Sent digest with {count} images for {target}")
    except Exception as e:
        log(f"ERROR: {e}")
        print(f"Failed to send: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
