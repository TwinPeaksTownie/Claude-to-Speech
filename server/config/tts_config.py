import json
import os
from pathlib import Path

# Load .env from the project root so the server and the plugin share one
# configuration file.
try:
    from dotenv import load_dotenv
    project_root = Path(__file__).resolve().parents[2]
    env_file = project_root / ".env"
    if env_file.exists():
        load_dotenv(env_file)
except ImportError:
    # python-dotenv is optional; environment variables still work without it.
    pass

# Load voices configuration
VOICES_FILE = Path(__file__).parent / "voices.json"
try:
    with open(VOICES_FILE, "r") as f:
        VOICES_DATA = json.load(f)
    ACTIVE_VOICE = VOICES_DATA.get("active_voice", "Claude")
except Exception as e:
    print(f"Error loading voices: {e}")
    ACTIVE_VOICE = "Claude"
    VOICES_DATA = {}

ELEVENLABS_API_KEY = os.environ.get("ELEVENLABS_API_KEY")

# Legacy fallback: support installations that still use server/config/secret.py
if not ELEVENLABS_API_KEY:
    try:
        from .secret import ELEVENLABS_API_KEY  # noqa: F811
    except ImportError:
        pass

if not ELEVENLABS_API_KEY:
    raise ValueError(
        "ELEVENLABS_API_KEY is not set. Copy .env.example to .env and fill in "
        "your key, or export ELEVENLABS_API_KEY in the environment."
    )
