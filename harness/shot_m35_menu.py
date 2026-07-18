"""One-shot: screenshot the Rijay main menu (client launched with NO
credentials, so the login terminal owns the screen). No server needed.

Run:  python harness/shot_m35_menu.py
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

from automation import GodotAutomation, launch_client, terminate_client

OUT_DIR = Path(__file__).resolve().parent / "out"


def main() -> int:
    OUT_DIR.mkdir(exist_ok=True)
    proc = launch_client([])  # --automation only: manual_login path
    automation = GodotAutomation()
    try:
        automation.connect(timeout=60.0)
        time.sleep(2.0)  # fonts/logo load, layout settles
        path = OUT_DIR / "m35_menu.png"
        automation.screenshot(str(path).replace("\\", "/"))
        print("shot:", path)
        return 0
    finally:
        automation.close()
        terminate_client(proc)


if __name__ == "__main__":
    sys.exit(main())
