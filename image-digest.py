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
MEDIA_LOG = os.path.expanduser("~/.openclaw/logs/media-usage.jsonl")
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
    """Parse gateway logs and collect image deliveries for a BJT date.

    A BJT date spans UTC: (D-1)T16:00 to DT16:00.

    Returns (unique_images, total_sends):
      - unique_images: list of unique image entries (deduped by URL), for the grid
      - total_sends: raw delivery count including resends, for the cross-check
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
    total_sends = 0

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
                    total_sends += 1
                    if url not in images:
                        images[url] = {
                            "ts": dt_bjt,
                            "bytes": size,
                            "url": url,
                        }
        except IOError:
            continue

    # Sort by timestamp
    unique_images = sorted(images.values(), key=lambda x: x["ts"])
    return unique_images, total_sends


def fmt_size(b):
    if b >= 1_048_576:
        return f"{b / 1_048_576:.1f} MB"
    if b >= 1024:
        return f"{b / 1024:.1f} KB"
    return f"{b} B"


def collect_media_log_images(target_date_str):
    """Cross-check: collect image entries in media-usage.jsonl for the same BJT date.

    Returns dict with counts and a list of generation timestamps for matching
    against gateway delivery logs.
    """
    result = {"script": 0, "builtin": 0, "script_cost": 0.0, "builtin_cost": 0.0,
              "entries": []}  # list of {"ts_bjt": datetime, "service": str, "cost": float}
    seen = set()
    if not os.path.isfile(MEDIA_LOG):
        return result
    try:
        with open(MEDIA_LOG) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                mid = obj.get("id", "")
                if mid and mid in seen:
                    continue
                if mid:
                    seen.add(mid)
                service = obj.get("service", "")
                if service not in ("image", "image-builtin"):
                    continue
                ts_str = obj.get("ts", "")
                if not ts_str:
                    continue
                try:
                    dt = datetime.fromisoformat(ts_str.replace("Z", "+00:00")).astimezone(BJT)
                    if dt.strftime("%Y-%m-%d") != target_date_str:
                        continue
                except (ValueError, TypeError):
                    continue
                cost = float(obj.get("cost", 0))
                if service == "image":
                    result["script"] += 1
                    result["script_cost"] += cost
                else:
                    result["builtin"] += 1
                    result["builtin_cost"] += cost
                result["entries"].append({"ts_bjt": dt, "service": service, "cost": cost})
    except IOError:
        pass
    return result


def classify_deliveries(image_entries, media_log_data):
    """Match gateway deliveries to media-usage.jsonl generation records.

    Returns (new_count, resend_count, resend_list) where resend_list
    contains filenames of re-delivered old images.
    """
    gen_times = [e["ts_bjt"] for e in media_log_data["entries"]]
    used = set()  # indices into gen_times already matched
    new_entries = []
    resend_entries = []

    for delivery in image_entries:
        d_ts = delivery["ts"]
        # Find closest generation record within 30 seconds
        best_idx = None
        best_delta = float("inf")
        for i, g_ts in enumerate(gen_times):
            if i in used:
                continue
            delta = abs((d_ts - g_ts).total_seconds())
            if delta < 30 and delta < best_delta:
                best_delta = delta
                best_idx = i
        if best_idx is not None:
            used.add(best_idx)
            new_entries.append(delivery)
        else:
            resend_entries.append(delivery)

    return new_entries, resend_entries


def build_email(target_date_str, image_entries, media_log_data, total_sends):
    """Build multipart MIME email with inline images and cross-check section."""
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

    # --- Cross-check: classify deliveries as new vs re-send ---
    new_entries, resend_entries = classify_deliveries(valid, media_log_data)
    ml_total = media_log_data["script"] + media_log_data["builtin"]
    ml_cost = media_log_data["script_cost"] + media_log_data["builtin_cost"]
    on_disk = len(valid)
    new_count = len(new_entries)
    resend_count = len(resend_entries)
    # total_sends = raw gateway log entries (same image sent 2x = counted 2x)
    duplicate_sends = total_sends - on_disk  # sends of the same URL again

    # Untracked = generated via media-usage but no matching delivery (API error / not sent)
    untracked = ml_total - new_count
    all_accounted = (resend_count == 0 and untracked == 0)
    status_color = "#4caf50" if all_accounted else "#ff9800"
    status_icon = "&#10003;" if all_accounted else "&#9888;"
    status_text = "完全一致" if all_accounted else "已分类"

    td_row = 'style="padding:6px 12px;font-size:12px;border-bottom:1px solid #eee;"'
    td_num = 'style="padding:6px 12px;font-size:12px;border-bottom:1px solid #eee;text-align:right;font-family:monospace;"'

    crosscheck_rows = f"""
      <tr>
        <td {td_row}>🆕 今日新生成</td>
        <td {td_num}>{new_count}</td>
        <td {td_num}>${ml_cost:.4f}</td>
      </tr>"""
    if media_log_data["script"] > 0:
        crosscheck_rows += f"""
      <tr>
        <td {td_row}>&nbsp;&nbsp;└ 脚本生成</td>
        <td {td_num}>{media_log_data["script"]}</td>
        <td {td_num}>${media_log_data["script_cost"]:.4f}</td>
      </tr>"""
    if media_log_data["builtin"] > 0:
        crosscheck_rows += f"""
      <tr>
        <td {td_row}>&nbsp;&nbsp;└ 内置工具</td>
        <td {td_num}>{media_log_data["builtin"]}</td>
        <td {td_num}>${media_log_data["builtin_cost"]:.4f}</td>
      </tr>"""
    if resend_count > 0:
        crosscheck_rows += f"""
      <tr>
        <td {td_row}>🔄 重发旧图</td>
        <td {td_num}>{resend_count}</td>
        <td {td_num}>$0 (免费)</td>
      </tr>"""
    if duplicate_sends > 0:
        crosscheck_rows += f"""
      <tr>
        <td {td_row}>📤 重复投递</td>
        <td {td_num}>{duplicate_sends}</td>
        <td {td_num}>$0 (同一文件)</td>
      </tr>"""
    crosscheck_rows += f"""
      <tr>
        <td style="padding:6px 12px;font-size:12px;">📬 投递总计</td>
        <td style="padding:6px 12px;font-size:12px;text-align:right;font-family:monospace;font-weight:600;">{total_sends}</td>
        <td style="padding:6px 12px;font-size:12px;text-align:right;font-family:monospace;">—</td>
      </tr>"""

    crosscheck_html = f"""
    <div style="margin-top:20px;padding-top:18px;border-top:1px solid #e0e0e0;">
      <div style="font-size:13px;font-weight:600;color:#555;margin-bottom:10px;">
        📊 数据校验 &nbsp;
        <span style="color:{status_color};font-size:12px;font-weight:700;">{status_icon} {status_text}</span>
      </div>
      <table style="width:100%;border-collapse:collapse;">
        <thead>
          <tr style="background:#f0f2f5;">
            <th style="padding:6px 12px;text-align:left;font-size:11px;color:#999;">分类</th>
            <th style="padding:6px 12px;text-align:right;font-size:11px;color:#999;">数量</th>
            <th style="padding:6px 12px;text-align:right;font-size:11px;color:#999;">费用</th>
          </tr>
        </thead>
        <tbody>{crosscheck_rows}</tbody>
      </table>"""

    # Show re-sent file names
    if resend_entries:
        resend_names = ", ".join(os.path.basename(e["url"]) for e in resend_entries)
        crosscheck_html += f"""
      <div style="margin-top:8px;padding:8px 12px;background:#e3f2fd;border-radius:6px;font-size:11px;color:#1565c0;">
        🔄 重发: {resend_names}
      </div>"""

    # Show untracked (generated but not delivered)
    if untracked > 0:
        crosscheck_html += f"""
      <div style="margin-top:8px;padding:8px 12px;background:#fff3e0;border-radius:6px;font-size:11px;color:#e65100;">
        ⚠️ {untracked} 张图片已生成但未投递（可能 API 错误或用户取消）
      </div>"""

    crosscheck_html += "</div>"

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
    <div style="display:flex;gap:15px;flex-wrap:wrap;margin-bottom:20px;">
      <div style="flex:1;min-width:100px;background:#f8f9fa;border-radius:10px;padding:14px;text-align:center;">
        <div style="font-size:28px;font-weight:700;color:#333;">{new_count}</div>
        <div style="font-size:12px;color:#999;">新生成</div>
      </div>
      <div style="flex:1;min-width:100px;background:#f8f9fa;border-radius:10px;padding:14px;text-align:center;">
        <div style="font-size:28px;font-weight:700;color:{('#666' if resend_count > 0 else '#ccc')};">{resend_count}</div>
        <div style="font-size:12px;color:#999;">重发</div>
      </div>
      <div style="flex:1;min-width:100px;background:#f8f9fa;border-radius:10px;padding:14px;text-align:center;">
        <div style="font-size:28px;font-weight:700;color:#333;">{fmt_size(total_bytes)}</div>
        <div style="font-size:12px;color:#999;">总大小</div>
      </div>
      <div style="flex:1;min-width:100px;background:#f8f9fa;border-radius:10px;padding:14px;text-align:center;">
        <div style="font-size:28px;font-weight:700;color:#e74c3c;">${ml_cost:.4f}</div>
        <div style="font-size:12px;color:#999;">费用</div>
      </div>
    </div>

    <div style="text-align:center;">
      {grid_items}
    </div>

    {crosscheck_html}
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
    # Cron fires at 00:00 BJT — we want the day that just ended (yesterday).
    # Use hour < 2 to guard against cron slippage past exact midnight.
    if now_bjt.hour < 2:
        target = (now_bjt - timedelta(days=1)).strftime("%Y-%m-%d")
    else:
        # Manual run during the day — use today
        target = now_bjt.strftime("%Y-%m-%d")

    print(f"Collecting images for {target} (BJT)...")
    entries, total_sends = collect_images_for_date(target)
    print(f"Found {len(entries)} unique images, {total_sends} total sends")

    # Cross-check against media-usage.jsonl
    media_log_data = collect_media_log_images(target)
    ml_total = media_log_data["script"] + media_log_data["builtin"]
    new_list, resend_list = classify_deliveries(entries, media_log_data)
    print(f"media-usage.jsonl: {ml_total} generated (script={media_log_data['script']}, builtin={media_log_data['builtin']})")
    print(f"Classification: {len(new_list)} new + {len(resend_list)} re-sent old = {len(entries)} unique")
    if total_sends > len(entries):
        print(f"  Duplicate sends: {total_sends - len(entries)} (same file sent multiple times)")
    if resend_list:
        print(f"  Re-sent old: {', '.join(os.path.basename(e['url']) for e in resend_list)}")

    if not entries:
        log(f"No images found for {target}")
        print("No images found. Skipping email.")
        return

    result = build_email(target, entries, media_log_data, total_sends)
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
