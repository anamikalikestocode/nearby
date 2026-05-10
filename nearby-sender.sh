#!/bin/bash
# nearby-sender.sh — Polls Supabase message_queue and sends iMessages via AppleScript
# Runs on Anamika's Mac only. DO NOT distribute this file.

SUPABASE_URL="https://tsixhtjsmwqadwgrawbs.supabase.co"
SERVICE_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRzaXhodGpzbXdxYWR3Z3Jhd2JzIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3MjA4NTU2MSwiZXhwIjoyMDg3NjYxNTYxfQ.CDk9_xlJxB1oKP__evNbbE5budTDcVwyCsrClbC5waQ"
POLL_INTERVAL=30

send_imessage() {
    local phone="$1"
    local message="$2"

    # Escape for AppleScript: backslashes then double quotes
    local escaped_msg
    escaped_msg=$(printf '%s' "$message" | sed 's/\\/\\\\/g; s/"/\\"/g')
    local escaped_phone
    escaped_phone=$(printf '%s' "$phone" | sed 's/\\/\\\\/g; s/"/\\"/g')

    osascript -e "tell application \"Messages\" to send \"${escaped_msg}\" to buddy \"${escaped_phone}\" of (1st account whose service type = iMessage)" 2>/dev/null
    return $?
}

mark_sent() {
    local id="$1"
    curl -s -X PATCH "${SUPABASE_URL}/rest/v1/message_queue?id=eq.${id}" \
        -H "apikey: ${SERVICE_KEY}" \
        -H "Authorization: Bearer ${SERVICE_KEY}" \
        -H "Content-Type: application/json" \
        -d "{\"status\":\"sent\",\"sent_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" > /dev/null
}

mark_failed() {
    local id="$1"
    local error="$2"
    local escaped_error
    escaped_error=$(printf '%s' "$error" | sed 's/"/\\"/g')
    curl -s -X PATCH "${SUPABASE_URL}/rest/v1/message_queue?id=eq.${id}" \
        -H "apikey: ${SERVICE_KEY}" \
        -H "Authorization: Bearer ${SERVICE_KEY}" \
        -H "Content-Type: application/json" \
        -d "{\"status\":\"failed\",\"error\":\"${escaped_error}\"}" > /dev/null
}

echo "🚀 nearby sender started — polling every ${POLL_INTERVAL}s"
echo "   Press Ctrl+C to stop"
echo ""

while true; do
    # Fetch pending messages (oldest first, max 10 per cycle)
    response=$(curl -s "${SUPABASE_URL}/rest/v1/message_queue?status=eq.pending&order=created_at.asc&limit=10" \
        -H "apikey: ${SERVICE_KEY}" \
        -H "Authorization: Bearer ${SERVICE_KEY}")

    # Check if we got any messages
    count=$(echo "$response" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

    if [ "$count" -gt "0" ]; then
        echo "[$(date +%H:%M:%S)] 📬 ${count} message(s) to send"

        # Process each message
        echo "$response" | python3 -c "
import sys, json
msgs = json.load(sys.stdin)
for m in msgs:
    print(f\"{m['id']}|{m['recipient_phone']}|{m['message']}\")
" | while IFS='|' read -r id phone message; do
            if send_imessage "$phone" "$message"; then
                mark_sent "$id"
                echo "[$(date +%H:%M:%S)] ✅ Sent to ${phone}: ${message:0:50}..."
            else
                mark_failed "$id" "AppleScript failed"
                echo "[$(date +%H:%M:%S)] ❌ Failed to send to ${phone}"
            fi
            # Small delay between messages to avoid throttling
            sleep 2
        done
    fi

    sleep "$POLL_INTERVAL"
done
