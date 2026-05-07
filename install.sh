#!/bin/bash
# ┌───────────────────────────────────────────────┐
# │  nearby                                        │
# │  get texted when a friend is within walking    │
# │  distance. no app. no sign-up. just your mac.  │
# │                                                │
# │  github.com/anabhoyrul/nearby                  │
# └───────────────────────────────────────────────┘
#
#  Install:    curl -sL https://raw.githubusercontent.com/anabhoyrul/nearby/main/install.sh | bash
#  Uninstall:  ~/.nearby/uninstall.sh

set -euo pipefail

DIR="$HOME/.nearby"
PLIST="$HOME/Library/LaunchAgents/com.nearby.bot.plist"

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

CACHE="$HOME/Library/com.apple.icloud.searchpartyd/SecureLocationCache"
if [ ! -d "$CACHE" ]; then
    echo -e "  ${red}✗ Find My data not found.${reset}"
    echo -e "  ${dim}Make sure you're signed into iCloud with Find My enabled,${reset}"
    echo -e "  ${dim}and at least one person shares their location with you.${reset}"
    exit 1
fi

COUNT=$(ls "$CACHE"/*.record 2>/dev/null | wc -l | tr -d ' ')
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
    pip3 install cryptography --quiet --user 2>/dev/null || pip3 install cryptography --quiet --break-system-packages 2>/dev/null || {
        echo -e "  ${red}✗ Couldn't install 'cryptography'. Try: pip3 install cryptography${reset}"
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
import plistlib, os, sys, json
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
                # derive display name from email
                local = email.split("@")[0]
                for c in "._-":
                    local = local.replace(c, " ")
                # strip trailing digits
                import re
                name = re.sub(r'\d+$', '', local).strip().title()
                if not name:
                    name = email.split("@")[0].title()
                friends[fmid] = {"name": name, "email": email}
                print(f"    \033[32m•\033[0m {name} ({email})")
        except Exception:
            continue

with open(os.path.expanduser("~/.nearby/friends.json"), "w") as f:
    json.dump(friends, f, indent=2)

print(f"\n  Found {len(friends)} friends")
DISCOVER

# ── Ask for iMessage address ────────────────────────────────────────────────

echo ""
echo -e -n "  ${bold}Your iMessage email or phone${reset} (to text yourself alerts): "
read IMESSAGE
if [ -z "$IMESSAGE" ]; then
    echo -e "  ${dim}Skipping iMessage — you'll still get macOS notifications${reset}"
fi

# ── Ask for radius ──────────────────────────────────────────────────────────

echo -e -n "  ${bold}Alert radius in meters${reset} [800 = ~10 min walk]: "
read RADIUS
RADIUS=${RADIUS:-800}

# ── Write config ────────────────────────────────────────────────────────────

cat > "$DIR/config.json" << EOF
{
  "beacon_key": "$KEY",
  "imessage_to": "$IMESSAGE",
  "radius_meters": $RADIUS,
  "cooldown_hours": 4,
  "quiet_start": 23,
  "quiet_end": 8
}
EOF

# ── Download bot script ─────────────────────────────────────────────────────

SCRIPT_URL="https://raw.githubusercontent.com/anabhoyrul/nearby/main/nearby.py"
if curl -sL "$SCRIPT_URL" -o "$DIR/nearby.py" 2>/dev/null && [ -s "$DIR/nearby.py" ]; then
    :
else
    # Fallback: copy from local repo if available
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    if [ -f "$SCRIPT_DIR/nearby.py" ]; then
        cp "$SCRIPT_DIR/nearby.py" "$DIR/nearby.py"
    else
        echo -e "  ${red}✗ Couldn't download nearby.py${reset}"
        exit 1
    fi
fi

# ── Uninstaller ─────────────────────────────────────────────────────────────

cat > "$DIR/uninstall.sh" << 'UNINSTALL'
#!/bin/bash
launchctl unload ~/Library/LaunchAgents/com.nearby.bot.plist 2>/dev/null
rm -f ~/Library/LaunchAgents/com.nearby.bot.plist
rm -rf ~/.nearby
echo "nearby uninstalled. 👋"
UNINSTALL
chmod +x "$DIR/uninstall.sh"

# ── Launch daemon ───────────────────────────────────────────────────────────

launchctl unload "$PLIST" 2>/dev/null || true

cat > "$PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.nearby.bot</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>${DIR}/nearby.py</string>
    </array>
    <key>StartInterval</key>
    <integer>120</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${DIR}/nearby.log</string>
    <key>StandardErrorPath</key>
    <string>${DIR}/nearby.log</string>
</dict>
</plist>
EOF

launchctl load "$PLIST"

# ── Done ────────────────────────────────────────────────────────────────────

echo ""
echo -e "  ${green}${bold}✓ nearby is running!${reset}"
echo ""
echo -e "  You'll get a text whenever a friend is within a ${RADIUS}m walk."
echo -e "  Checks every 2 minutes. Silent from 11pm–8am."
echo -e "  Won't bug you about the same friend for 4 hours."
echo ""
echo -e "  ${dim}Config:      ~/.nearby/config.json${reset}"
echo -e "  ${dim}Logs:        ~/.nearby/nearby.log${reset}"
echo -e "  ${dim}Uninstall:   ~/.nearby/uninstall.sh${reset}"
echo ""
echo -e "  ${dim}github.com/anabhoyrul/nearby${reset}"
echo ""
