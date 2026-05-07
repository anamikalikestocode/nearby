#!/bin/bash
# ┌──────────────────────────────────────────────────┐
# │  nearby                                          │
# │  get texted when a friend is within walking      │
# │  distance. no app. no sign-up. just your mac.    │
# │                                                  │
# │  github.com/anamikalikestocode/nearby            │
# └──────────────────────────────────────────────────┘
#
#  Install:    curl -sL https://raw.githubusercontent.com/anamikalikestocode/nearby/main/install.sh | bash
#  Uninstall:  ~/.nearby/uninstall.sh

set -euo pipefail

DIR="$HOME/.nearby"
PLIST="$HOME/Library/LaunchAgents/com.nearby.daemon.plist"

bold="\033[1m"
dim="\033[2m"
green="\033[32m"
yellow="\033[33m"
red="\033[31m"
reset="\033[0m"

echo ""
echo -e "${bold}  nearby${reset} — get texted when a friend is close"
echo -e "${dim}  ───────────────────────────────────────────${reset}"
echo ""

# ── Preflight ───────────────────────────────────────────────────────────────

if [[ "$(uname)" != "Darwin" ]]; then
    echo -e "  ${red}✗ macOS only. Sorry.${reset}"; exit 1
fi

if ! xcode-select -p &>/dev/null; then
    echo -e "  ${dim}Installing Xcode Command Line Tools (needed once)...${reset}"
    xcode-select --install 2>/dev/null
    echo -e "  ${yellow}!${reset} Complete the Xcode Tools install popup, then re-run this script."
    exit 0
fi

CACHE="$HOME/Library/com.apple.icloud.searchpartyd/SecureLocationCache"
if [ ! -d "$CACHE" ]; then
    echo -e "  ${red}✗ Find My data not found.${reset}"
    echo -e "  ${dim}Make sure you're signed into iCloud with Find My enabled,${reset}"
    echo -e "  ${dim}and at least one person shares their location with you.${reset}"
    exit 1
fi

COUNT=$(find "$CACHE" -maxdepth 1 -name "*.record" 2>/dev/null | wc -l | tr -d ' ')
if [ "$COUNT" -eq 0 ]; then
    echo -e "  ${red}✗ No shared locations found.${reset}"
    echo -e "  ${dim}You need at least one person sharing their Find My location with you.${reset}"
    exit 1
fi
echo -e "  ${green}✓${reset} Found ${bold}$COUNT${reset} device locations in Find My"

# ── Get encryption key ──────────────────────────────────────────────────────

echo ""
echo -e "  ${yellow}Reading encryption key from your Keychain...${reset}"
echo -e "  ${dim}You'll see a popup — click \"Allow\" (or \"Always Allow\" to skip next time)${reset}"
echo ""

KEY=$(security find-generic-password -s "BeaconStore" -a "BeaconStoreKey" -w 2>&1) || true
if [[ "$KEY" == *"could not be found"* ]] || [[ -z "$KEY" ]] || [[ ${#KEY} -lt 60 ]]; then
    echo -e "  ${red}✗ Couldn't read BeaconStore key.${reset}"
    echo -e "  ${dim}Make sure Find My is enabled on this Mac.${reset}"
    exit 1
fi
echo -e "  ${green}✓${reset} Got decryption key"

# ── Python dependency ───────────────────────────────────────────────────────

if ! python3 -c "from cryptography.hazmat.primitives.ciphers.aead import AESGCM" 2>/dev/null; then
    echo -e "  ${dim}Installing cryptography...${reset}"
    python3 -m pip install cryptography --quiet --user 2>/dev/null || python3 -m pip install cryptography --quiet --break-system-packages 2>/dev/null || pip3 install cryptography --quiet 2>/dev/null || {
        echo -e "  ${red}✗ Couldn't install 'cryptography'. Try: python3 -m pip install cryptography${reset}"
        exit 1
    }
fi
echo -e "  ${green}✓${reset} Python ready"

# ── Create install dir ──────────────────────────────────────────────────────

mkdir -p "$DIR"

# ── Discover friends ────────────────────────────────────────────────────────

echo -e "  ${dim}Discovering your Find My contacts...${reset}"
echo ""

python3 - "$KEY" << 'DISCOVER'
import plistlib, os, sys, json, re
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

key = bytes.fromhex(sys.argv[1])
aes = AESGCM(key)
friends = {}

keys_dir = os.path.expanduser("~/Library/com.apple.icloud.searchpartyd/SecureLocationSharedKeys/")
if os.path.exists(keys_dir):
    for fname in sorted(os.listdir(keys_dir)):
        if not fname.endswith(".record"):
            continue
        try:
            with open(os.path.join(keys_dir, fname), "rb") as f:
                data = plistlib.load(f)
            pt = aes.decrypt(data[0][:16], data[2] + data[1], None)
            parsed = plistlib.loads(pt)
            fmid = parsed.get("findMyId", "")
            dest = parsed.get("ownerHandle", {}).get("destination", "")
            email = dest.split("mailto:")[-1] if "mailto:" in dest else ""
            if fmid and email:
                local = re.sub(r'[._-]', ' ', email.split("@")[0])
                name = re.sub(r'\d+$', '', local).strip().title() or email.split("@")[0].title()
                friends[fmid] = {"name": name, "email": email}
                print(f"    \033[32m•\033[0m {name} ({email})")
        except Exception:
            continue

with open(os.path.expanduser("~/.nearby/friends.json"), "w") as f:
    json.dump(friends, f, indent=2)

print(f"\n  Found {len(friends)} friends")
if not friends:
    print(f"  \033[31m✗ No friends found. Make sure someone shares their Find My location with you.\033[0m")
    sys.exit(1)
DISCOVER

# ── Detect your iPhone ─────────────────────────────────────────────────────

echo ""
echo -e "  ${dim}Looking for your iPhone in Find My...${reset}"

MY_DEVICE_ID=$(python3 - "$KEY" << 'DETECT_PHONE'
import plistlib, sys, os
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

key = bytes.fromhex(sys.argv[1])
aes = AESGCM(key)

owned = os.path.expanduser("~/Library/com.apple.icloud.searchpartyd/OwnedBeacons/")
beacon_loc = os.path.expanduser("~/Library/com.apple.icloud.searchpartyd/BeaconEstimatedLocation/")
phones = []

if not os.path.isdir(owned):
    print("")
    print(f"    \033[33m!\033[0m No iPhone found — will use Mac location instead", file=sys.stderr)
    sys.exit(0)

for fname in sorted(os.listdir(owned)):
    if not fname.endswith(".record"):
        continue
    try:
        with open(os.path.join(owned, fname), "rb") as f:
            data = plistlib.load(f)
        pt = aes.decrypt(data[0][:16], data[2] + data[1], None)
        parsed = plistlib.loads(pt)
        model = parsed.get("model", "")
        ident = parsed.get("identifier", "")
        # Check if this device has location data
        has_location = os.path.isdir(os.path.join(beacon_loc, ident))
        if "iPhone" in model and has_location:
            phones.append((parsed.get("pairingDate", ""), ident, model))
    except:
        continue

if phones:
    # Pick the most recently paired iPhone
    phones.sort(reverse=True)
    best = phones[0]
    print(best[1])  # identifier (stdout → captured by shell)
    print(f"    \033[32m✓\033[0m Found your {best[2]} in Find My", file=sys.stderr)
    if len(phones) > 1:
        print(f"    \033[2m(picked most recent — {len(phones)} iPhones found)\033[0m", file=sys.stderr)
else:
    print("")
    print(f"    \033[33m!\033[0m No iPhone found — will use Mac location instead", file=sys.stderr)
    print(f"    \033[2mFor best results, make sure Find My is enabled on your iPhone\033[0m", file=sys.stderr)
DETECT_PHONE
)

# ── Ask for iMessage address ────────────────────────────────────────────────

echo ""
echo -e -n "  ${bold}Your iMessage email or phone${reset} (to text yourself alerts): "
read IMESSAGE < /dev/tty
if [ -z "$IMESSAGE" ]; then
    echo -e "  ${dim}Skipping iMessage — you'll still get macOS notifications${reset}"
fi

# ── Ask for radius ──────────────────────────────────────────────────────────

echo -e -n "  ${bold}Alert radius in meters${reset} [800 = ~10 min walk]: "
read RADIUS < /dev/tty
RADIUS=${RADIUS:-800}
# Validate radius is a number
if ! [[ "$RADIUS" =~ ^[0-9]+$ ]]; then
    echo -e "  ${dim}Invalid number — using default 800m${reset}"
    RADIUS=800
fi

# ── Write config ────────────────────────────────────────────────────────────

cat > "$DIR/config.json" << EOF
{
  "beacon_key": "$KEY",
  "imessage_to": "$IMESSAGE",
  "radius_meters": $RADIUS,
  "cooldown_hours": 4,
  "quiet_start": 23,
  "quiet_end": 8,
  "my_device_id": "$MY_DEVICE_ID"
}
EOF

# ── Download files ─────────────────────────────────────────────────────────

REPO="https://raw.githubusercontent.com/anamikalikestocode/nearby/main"
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || SCRIPT_DIR=""

download() {
    local file="$1" required="$2"
    if curl -sL "$REPO/$file" -o "$DIR/$file" 2>/dev/null && [ -s "$DIR/$file" ]; then
        return 0
    elif [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/$file" ]; then
        cp "$SCRIPT_DIR/$file" "$DIR/$file"
        return 0
    elif [ "$required" = "1" ]; then
        echo -e "  ${red}✗ Couldn't download $file${reset}"
        exit 1
    fi
    return 1
}

download "nearby.py" 1
download "daemon.swift" 1

echo -e "  ${dim}Compiling background daemon...${reset}"
if swiftc -o "$DIR/nearbyd" "$DIR/daemon.swift" -framework Foundation 2>/dev/null; then
    echo -e "  ${green}✓${reset} Background daemon compiled"
else
    echo -e "  ${red}✗ Couldn't compile daemon. Make sure Xcode CLI tools are installed.${reset}"
    exit 1
fi

# Only compile CoreLocation fallback if no iPhone was detected
if [ -z "$MY_DEVICE_ID" ]; then
    download "locator.swift" 0
    if [ -f "$DIR/locator.swift" ]; then
        echo -e "  ${dim}No iPhone found — compiling Mac location helper...${reset}"
        APP="$DIR/Locator.app"
        mkdir -p "$APP/Contents/MacOS"
        cat > "$APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.nearby.locator</string>
    <key>CFBundleName</key>
    <string>Locator</string>
    <key>CFBundleExecutable</key>
    <string>locator</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>NSLocationUsageDescription</key>
    <string>nearby uses your location to check if friends are within walking distance.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>nearby uses your location to check if friends are within walking distance.</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST
        if swiftc -o "$APP/Contents/MacOS/locator" "$DIR/locator.swift" -framework CoreLocation 2>/dev/null; then
            echo -e "  ${green}✓${reset} CoreLocation helper compiled"
            echo ""
            echo -e "  ${yellow}Requesting location access...${reset}"
            echo -e "  ${dim}You may see a popup — click \"Allow\"${reset}"
            echo ""
            rm -f "$DIR/location.txt"
            open "$APP"
            for i in $(seq 1 30); do
                [ -f "$DIR/location.txt" ] && break
                sleep 0.5
            done
            if [ -f "$DIR/location.txt" ] && ! grep -q "^error:" "$DIR/location.txt"; then
                echo -e "  ${green}✓${reset} Location access granted (GPS-accurate)"
            else
                echo -e "  ${yellow}!${reset} Location access not granted — falling back to IP geolocation"
                echo -e "  ${dim}To fix: System Settings → Privacy & Security → Location Services → enable Locator${reset}"
            fi
        else
            echo -e "  ${yellow}!${reset} Couldn't compile location helper — using IP geolocation"
            echo -e "  ${dim}(distances may be approximate)${reset}"
        fi
    fi
fi

# ── Uninstaller ─────────────────────────────────────────────────────────────

cat > "$DIR/uninstall.sh" << 'UNINSTALL'
#!/bin/bash
launchctl unload ~/Library/LaunchAgents/com.nearby.daemon.plist 2>/dev/null
launchctl remove com.nearby.daemon 2>/dev/null
rm -f ~/Library/LaunchAgents/com.nearby.daemon.plist
tccutil reset LocationServices com.nearby.locator 2>/dev/null
rm -rf ~/.nearby
echo "nearby uninstalled. 👋"
UNINSTALL
chmod +x "$DIR/uninstall.sh"

# ── Launch daemon ───────────────────────────────────────────────────────────

launchctl unload "$PLIST" 2>/dev/null || true

# The daemon uses NSBackgroundActivityScheduler to run during macOS maintenance
# wakes — this means it checks even when your laptop lid is closed.
cat > "$PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.nearby.daemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>${DIR}/nearbyd</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${DIR}/nearby.log</string>
    <key>StandardErrorPath</key>
    <string>${DIR}/nearby.log</string>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
EOF

launchctl load "$PLIST"

# ── Done ────────────────────────────────────────────────────────────────────

echo ""
echo -e "  ${green}${bold}✓ nearby is running!${reset}"
echo ""
if [ -n "$MY_DEVICE_ID" ]; then
    echo -e "  Tracking your iPhone's location via Find My."
    echo -e "  Works even with your Mac closed — just leave the house."
else
    echo -e "  Using your Mac's location (works best with lid open)."
fi
echo -e "  You'll get a text whenever a friend is within a ${RADIUS}m walk."
echo -e "  Checks every ~15 minutes, even with the lid closed. Silent from 11pm–8am."
echo -e "  Won't bug you about the same friend for 4 hours."
echo ""
echo -e "  ${dim}Config:      ~/.nearby/config.json${reset}"
echo -e "  ${dim}Logs:        ~/.nearby/nearby.log${reset}"
echo -e "  ${dim}Uninstall:   ~/.nearby/uninstall.sh${reset}"
echo ""
echo -e "  ${dim}github.com/anamikalikestocode/nearby${reset}"
echo ""
