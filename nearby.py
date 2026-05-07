#!/usr/bin/env python3
"""
nearby — get texted when a friend is within walking distance.

Decrypts Apple's Find My location cache on your Mac, checks who's close,
and sends you an iMessage. Runs in the background, even with the lid closed.

No app. No sign-up. No API keys. Just your Mac doing what it already knows.
"""

import plistlib
import json
import math
import subprocess
import datetime
import time
import urllib.request
from pathlib import Path

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

# ── Paths ─────────────────────────────────────────────────────────────────────

INSTALL_DIR = Path.home() / ".nearby"
CONFIG_FILE = INSTALL_DIR / "config.json"
FRIENDS_FILE = INSTALL_DIR / "friends.json"
STATE_FILE = INSTALL_DIR / "state.json"
CACHE_DIR = Path.home() / "Library/com.apple.icloud.searchpartyd/SecureLocationCache"
BEACON_DIR = Path.home() / "Library/com.apple.icloud.searchpartyd/BeaconEstimatedLocation"

# ── Config (written by install.sh) ────────────────────────────────────────────

CONFIG = json.loads(CONFIG_FILE.read_text()) if CONFIG_FILE.exists() else {}
FRIENDS = json.loads(FRIENDS_FILE.read_text()) if FRIENDS_FILE.exists() else {}

BEACON_KEY = bytes.fromhex(CONFIG.get("beacon_key", "")) if CONFIG.get("beacon_key") else b""
ALERT_RADIUS = CONFIG.get("radius_meters", 800)
COOLDOWN_HOURS = CONFIG.get("cooldown_hours", 4)
QUIET_START = CONFIG.get("quiet_start", 23)
QUIET_END = CONFIG.get("quiet_end", 8)
IMESSAGE_TO = CONFIG.get("imessage_to", "")
MY_DEVICE_ID = CONFIG.get("my_device_id", "")


def log(msg):
    print(f"[{datetime.datetime.now().strftime('%H:%M')}] {msg}")


def haversine(lat1, lon1, lat2, lon2):
    """Distance in meters between two GPS coordinates."""
    R = 6371000
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def is_quiet():
    """Check if we're in quiet hours (no alerts)."""
    h = datetime.datetime.now().hour
    if QUIET_START > QUIET_END:
        return h >= QUIET_START or h < QUIET_END
    return QUIET_START <= h < QUIET_END


def send_imessage(to, message):
    """Send an iMessage via AppleScript. Returns True on success."""
    # Escape quotes for AppleScript (preserve \n — osascript interprets it as newline)
    safe_msg = message.replace('"', '\\"')
    safe_to = to.replace('"', '\\"')
    script = (
        'tell application "Messages"\n'
        '  set targetService to 1st account whose service type = iMessage\n'
        f'  set targetBuddy to participant "{safe_to}" of targetService\n'
        f'  send "{safe_msg}" to targetBuddy\n'
        'end tell'
    )
    result = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return result.returncode == 0


def send_notification(title, body):
    """Show a macOS notification."""
    safe_body = body.replace('"', '\\"')
    safe_title = title.replace('"', '\\"')
    subprocess.run([
        "osascript", "-e",
        f'display notification "{safe_body}" with title "{safe_title}" sound name "Ping"'
    ], capture_output=True)


def notify(name, dist_m):
    """Alert the user that a friend is nearby."""
    mins = max(1, int(dist_m / 80))  # ~80m per minute walking speed
    body = f"{name} is {mins} min walk away ({int(dist_m)}m)"

    if IMESSAGE_TO:
        if send_imessage(IMESSAGE_TO, "Friend Nearby! 👋\\n" + body):
            log(f"📱 iMessage sent to {IMESSAGE_TO}")
        else:
            log(f"⚠️  iMessage failed — sending notification instead")

    send_notification("nearby 👋", body)
    return body


def load_state():
    try:
        return json.loads(STATE_FILE.read_text())
    except Exception:
        return {}


def save_state(state):
    STATE_FILE.write_text(json.dumps(state, indent=2))


def in_cooldown(state, fmid):
    last = state.get(fmid)
    if not last:
        return False
    try:
        elapsed = (datetime.datetime.now() - datetime.datetime.fromisoformat(last)).total_seconds()
        return elapsed < COOLDOWN_HOURS * 3600
    except Exception:
        return False


def decrypt_locations():
    """Read and decrypt the Find My SecureLocationCache."""
    if not CACHE_DIR.exists():
        log("⚠️  SecureLocationCache not found")
        return {}

    aes = AESGCM(BEACON_KEY)
    locations = {}

    for record in CACHE_DIR.glob("*.record"):
        try:
            with open(record, "rb") as f:
                data = plistlib.load(f)
            plaintext = aes.decrypt(data[0][:16], data[2] + data[1], None)
            loc = plistlib.loads(plaintext).get("secureLocation", {})
            fmid = loc.get("findMyId")
            if fmid and loc.get("latitude"):
                locations[fmid] = (loc["latitude"], loc["longitude"])
        except Exception:
            continue

    return locations


def get_my_location():
    """Get YOUR location by reading your iPhone's GPS from Find My's cache.
    Your Mac tracks your phone via Find My — same encrypted cache, same key.
    Works even when your Mac is at home and you're walking around with your phone."""

    if not MY_DEVICE_ID:
        log("⚠️  No my_device_id in config — run install.sh to set your device")
        return _fallback_location()

    device_dir = BEACON_DIR / MY_DEVICE_ID
    if not device_dir.exists():
        log(f"⚠️  Device dir not found: {MY_DEVICE_ID}")
        return _fallback_location()

    aes = AESGCM(BEACON_KEY)
    best_ts = None
    best_lat, best_lon = None, None

    for record in device_dir.glob("*.record"):
        try:
            with open(record, "rb") as f:
                data = plistlib.load(f)
            pt = aes.decrypt(data[0][:16], data[2] + data[1], None)
            parsed = plistlib.loads(pt)
            lat = parsed.get("latitude", 0)
            lon = parsed.get("longitude", 0)
            ts = parsed.get("timestamp")
            if lat and lon and ts and (best_ts is None or str(ts) > str(best_ts)):
                best_ts, best_lat, best_lon = ts, lat, lon
        except Exception:
            continue

    if best_lat is not None:
        log(f"📍 iPhone GPS: {best_lat:.4f}, {best_lon:.4f}")
        return best_lat, best_lon

    log("⚠️  No location found for your iPhone")
    return _fallback_location()


def _fallback_location():
    """Fallback: CoreLocation (if Mac is open) or IP geolocation."""
    locator_app = INSTALL_DIR / "Locator.app"
    location_file = INSTALL_DIR / "location.txt"
    if locator_app.exists():
        try:
            location_file.unlink(missing_ok=True)
            subprocess.run(["open", str(locator_app)], capture_output=True, timeout=5)
            for _ in range(30):
                time.sleep(0.5)
                if location_file.exists():
                    break
            if location_file.exists():
                content = location_file.read_text().strip()
                if not content.startswith("error:"):
                    parts = content.split()
                    lat, lon = float(parts[0]), float(parts[1])
                    log(f"📍 CoreLocation fallback: {lat:.4f}, {lon:.4f}")
                    return lat, lon
        except Exception:
            pass

    try:
        resp = urllib.request.urlopen("http://ip-api.com/json/", timeout=5)
        data = json.loads(resp.read())
        if data.get("status") == "success":
            log(f"📍 IP fallback: {data['lat']:.4f}, {data['lon']:.4f} (approximate)")
            return data["lat"], data["lon"]
    except Exception:
        pass

    return None, None


def main():
    if not BEACON_KEY or not FRIENDS:
        log("❌ Run install.sh first — no config or friends found")
        return

    if not CACHE_DIR.exists() or not any(CACHE_DIR.glob("*.record")):
        log("⚠️  Can't read Find My data — python3 may need Full Disk Access")
        log("   Fix: System Settings → Privacy & Security → Full Disk Access → add /usr/bin/python3")
        return

    my_lat, my_lon = get_my_location()
    if my_lat is None:
        return

    locations = decrypt_locations()
    if not locations:
        log("No locations found in cache")
        return

    quiet = is_quiet()
    state = load_state()
    found_nearby = False

    for fmid, info in FRIENDS.items():
        if fmid not in locations:
            continue

        lat, lon = locations[fmid]
        dist = haversine(my_lat, my_lon, lat, lon)

        if dist >= ALERT_RADIUS:
            continue
        if quiet:
            log(f"💤 {info['name']} is {int(dist)}m away but it's quiet hours")
            continue
        if in_cooldown(state, fmid):
            log(f"⏳ {info['name']} is {int(dist)}m away (cooldown active)")
            continue

        msg = notify(info["name"], dist)
        log(f"🔔 {msg}")
        state[fmid] = datetime.datetime.now().isoformat()
        found_nearby = True

    if not found_nearby:
        log(f"Checked {len(locations)} locations — no friends nearby")

    save_state(state)


if __name__ == "__main__":
    main()
