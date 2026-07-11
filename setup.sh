#!/usr/bin/env bash
# Setup is a web page now. This starts it and prints the URL.
# Configure the model, governance, and optional add-ons in the browser, test
# credentials in place, then press Launch. The old terminal board is gone.
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] || cp .env.example .env

echo
echo "  Setup is a web page. Starting it now."
echo "  Local:     http://127.0.0.1:8891"
echo "  Over SSH:  ssh -L 8891:127.0.0.1:8891 <user>@<this-box>   then open that URL"
echo "  (the exact URL is printed just below in case the port was taken)"
echo
exec python3 bin/portal.py
