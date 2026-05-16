#!/bin/bash
#
# Claude Code Stop Hook - Automatic TTS
# Fires after Claude finishes responding
# Extracts and speaks TTS markers from response
#

# Debug logging (set DEBUG=1 in .env to enable)
DEBUG="${DEBUG:-0}"
DEBUG_FILE="/tmp/claude_stop_hook.log"

# Get the plugin directory (parent of hooks directory)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"

# Speak script path, plus a preferred python interpreter.
# If the plugin has a local virtualenv, use it so dependencies resolve; otherwise
# fall back to system python3.
SPEAK_SCRIPT="$PLUGIN_DIR/scripts/claude_speak.py"
if [ -x "$PLUGIN_DIR/.venv/bin/python3" ]; then
    PYTHON_BIN="$PLUGIN_DIR/.venv/bin/python3"
elif [ -x "$PLUGIN_DIR/venv/bin/python3" ]; then
    PYTHON_BIN="$PLUGIN_DIR/venv/bin/python3"
else
    PYTHON_BIN="python3"
fi

# Debug path resolution
[ "$DEBUG" = "1" ] && echo "SCRIPT_DIR: $SCRIPT_DIR" >> "$DEBUG_FILE"
[ "$DEBUG" = "1" ] && echo "PLUGIN_DIR: $PLUGIN_DIR" >> "$DEBUG_FILE"
[ "$DEBUG" = "1" ] && echo "SPEAK_SCRIPT: $SPEAK_SCRIPT" >> "$DEBUG_FILE"
[ "$DEBUG" = "1" ] && echo "PYTHON_BIN: $PYTHON_BIN" >> "$DEBUG_FILE"

# Read the JSON input from stdin
INPUT=$(cat)

# Debug the raw input
[ "$DEBUG" = "1" ] && echo "=== Stop Hook Fired at $(date) ===" >> "$DEBUG_FILE"
[ "$DEBUG" = "1" ] && echo "Raw input: $INPUT" >> "$DEBUG_FILE"

# Prefer the `last_assistant_message` field when Claude Code provides it; fall
# back to reading the last entry from `transcript_path` for older hook payloads.
RESPONSE=$(echo "$INPUT" | "$PYTHON_BIN" -c "
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

msg = data.get('last_assistant_message')
if isinstance(msg, str) and msg.strip():
    print(msg)
    sys.exit(0)

path = data.get('transcript_path')
if not path:
    sys.exit(0)

try:
    with open(path, 'r', encoding='utf-8') as f:
        last_line = ''
        for line in f:
            if line.strip():
                last_line = line
    if not last_line:
        sys.exit(0)
    entry = json.loads(last_line)
    content = entry.get('message', {}).get('content', [])
    if isinstance(content, list):
        for block in content:
            if isinstance(block, dict) and block.get('type') == 'text':
                print(block.get('text', ''))
                break
    elif isinstance(content, str):
        print(content)
except Exception:
    pass
" 2>/dev/null)

[ "$DEBUG" = "1" ] && echo "Extracted response length: ${#RESPONSE} chars" >> "$DEBUG_FILE"
[ "$DEBUG" = "1" ] && echo "First 200 chars: ${RESPONSE:0:200}" >> "$DEBUG_FILE"

if [ -z "$RESPONSE" ]; then
    [ "$DEBUG" = "1" ] && echo "Empty response, nothing to process" >> "$DEBUG_FILE"
    exit 0
fi

# md5sum is GNU; macOS ships `md5 -r` with the same output shape. Try both.
if command -v md5sum >/dev/null 2>&1; then
    RESPONSE_HASH=$(printf '%s' "$RESPONSE" | md5sum | cut -d' ' -f1)
else
    RESPONSE_HASH=$(printf '%s' "$RESPONSE" | md5 -r 2>/dev/null | cut -d' ' -f1)
fi

# Atomic lock via mkdir (works without flock, e.g. on macOS).
# If the lock dir is stale (older than 30s, e.g. from a killed process), remove it.
LOCK_DIR="/tmp/claude_tts_hook.lock.d"
HASH_FILE="/tmp/claude_tts_hook.hash"
if [ -d "$LOCK_DIR" ]; then
    lock_age=$(( $(date +%s) - $(stat -f %m "$LOCK_DIR" 2>/dev/null || stat -c %Y "$LOCK_DIR" 2>/dev/null || echo 0) ))
    if [ "$lock_age" -gt 30 ]; then
        [ "$DEBUG" = "1" ] && echo "Removing stale lock dir (age=${lock_age}s)" >> "$DEBUG_FILE"
        rmdir "$LOCK_DIR" 2>/dev/null
    fi
fi
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    [ "$DEBUG" = "1" ] && echo "Another hook instance is processing, skipping" >> "$DEBUG_FILE"
    exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

LAST_HASH=$(cat "$HASH_FILE" 2>/dev/null || echo "")
if [ "$RESPONSE_HASH" = "$LAST_HASH" ]; then
    [ "$DEBUG" = "1" ] && echo "Duplicate message detected (same content hash), skipping" >> "$DEBUG_FILE"
    exit 0
fi
echo "$RESPONSE_HASH" > "$HASH_FILE"

# Check if response explicitly marks SILENT (handle both escaped and unescaped)
if echo "$RESPONSE" | grep -qE "(<\\!--|<!--) TTS: SILENT (-->|-->)"; then
    # Explicitly marked as silent - do nothing
    [ "$DEBUG" = "1" ] && echo "Found SILENT marker, skipping TTS" >> "$DEBUG_FILE"
    exit 0
fi

# Extract TTS text if present (handle both escaped and unescaped markers)
TTS_TEXT=$(echo "$RESPONSE" | sed -n 's/.*<\\!-- TTS: "\([^"]*\)".*/\1/p' | head -1)
[ "$DEBUG" = "1" ] && echo "Escaped pattern result: '$TTS_TEXT'" >> "$DEBUG_FILE"

if [ -z "$TTS_TEXT" ]; then
    # Try unescaped version as fallback
    TTS_TEXT=$(echo "$RESPONSE" | sed -n 's/.*<!-- TTS: "\([^"]*\)".*/\1/p' | head -1)
    [ "$DEBUG" = "1" ] && echo "Unescaped pattern result: '$TTS_TEXT'" >> "$DEBUG_FILE"
fi

# If we found TTS text, speak it
if [ -n "$TTS_TEXT" ]; then
    [ "$DEBUG" = "1" ] && echo "Extracted TTS text: $TTS_TEXT" >> "$DEBUG_FILE"

    if [ -f "$SPEAK_SCRIPT" ]; then
        "$PYTHON_BIN" "$SPEAK_SCRIPT" --conversation "$TTS_TEXT" 2>&1 | while IFS= read -r line; do
            [ "$DEBUG" = "1" ] && echo "TTS output: $line" >> "$DEBUG_FILE"
        done
    else
        [ "$DEBUG" = "1" ] && echo "ERROR: $SPEAK_SCRIPT not found" >> "$DEBUG_FILE"
    fi
else
    # No TTS marker found - silent by default
    [ "$DEBUG" = "1" ] && echo "No TTS marker found, defaulting to silent" >> "$DEBUG_FILE"
fi

exit 0
