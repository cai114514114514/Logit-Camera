#!/usr/bin/env python3
"""Import the local .env key into one development iPhone without bundling it."""
import argparse
import json
import subprocess
import tempfile
from pathlib import Path


def read_key(path):
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, value = line.removeprefix("export ").split("=", 1)
        if name.strip() in ("deepseek_api", "DEEPSEEK_API_KEY"):
            return value.strip().strip("\"'")
    raise SystemExit("No DeepSeek key found in .env")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    key = read_key(root / ".env")
    if not key:
        raise SystemExit("DeepSeek key is empty")
    # NamedTemporaryFile uses mode 0600. No key is passed as a CLI argument.
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", encoding="utf-8") as temporary:
        json.dump({"apiKey": key}, temporary)
        temporary.flush()
        subprocess.run([
            "xcrun", "devicectl", "device", "copy", "to", "--device", args.device,
            "--source", temporary.name, "--destination", "Library/Application Support/DeepSeekBootstrap.json",
            "--domain-type", "appDataContainer", "--domain-identifier", "com.logitcamera.aperture",
            "--timeout", "30"
        ], check=True, stdout=subprocess.DEVNULL)
    print("Private bootstrap copied. Relaunch Logit Camera to import into Keychain and delete the bootstrap.")


if __name__ == "__main__":
    main()
