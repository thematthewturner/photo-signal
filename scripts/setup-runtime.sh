#!/bin/zsh
set -eu
cd "${0:A:h}/.."
RUNTIME="$HOME/Library/Application Support/PhotoSignal/benchmark-venv"
python3 -m venv "$RUNTIME"
"$RUNTIME/bin/python" -m pip install -r requirements.txt
print "Runtime ready: $RUNTIME"
