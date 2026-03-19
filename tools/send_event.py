#!/usr/bin/env python3
import json
import sys
import urllib.request


def main() -> int:
    if len(sys.argv) < 2:
        print("Usage:")
        print("  python tools/send_event.py spawn_tank andi")
        print("  python tools/send_event.py '{\"type\":\"comment\",\"comment\":\"!boss\",\"user\":\"andi\"}'")
        return 1

    raw = sys.argv[1]
    if raw.startswith("{"):
        payload = json.loads(raw)
    else:
        payload = {
            "action": raw,
            "user": sys.argv[2] if len(sys.argv) > 2 else "tester",
        }

    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        "http://127.0.0.1:8787/event",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    with urllib.request.urlopen(req, timeout=3) as res:
        print(res.read().decode("utf-8"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
