#!/bin/bash
# Test functions from the actual patched SDL source; fake only IOKit/libusb.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
source_dir=${1:?Provide the SDL source directory with patches applied}
mode=${2:-after}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/IOKit"
printf '/* Boundary declarations are in the harness. */\n' > "$work/IOKit/IOKitLib.h"
python3 - "$source_dir/src/joystick/hidapi/SDL_hidapi_switch2.c" "$work/production.c" "$mode" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
def function(name):
    a=s.index('static bool '+name+'(')
    # Skip forward declarations, if present.
    while s.index(';',a) < s.index('{',a):
        a=s.index('static bool '+name+'(',a+1)
    b=s.index('{',a);depth=1;c=b+1
    while depth:
        depth += (s[c]=='{') - (s[c]=='}');c+=1
    return s[a:c]+'\n'
text='' if sys.argv[3]=='before' else function('S2USB_GetIdentity')
Path(sys.argv[2]).write_text(text+function('AcquireVendorInterface'))
PY
flags=()
[ "$mode" != before ] || flags+=(-DBASELINE)
cc "${flags[@]}" -I "$work" "$root/tests/sdl-usb/harness.c" -o "$work/test"
if [ "$mode" = before ]; then
    set +e
    "$work/test"
    result=$?
    set -e
    test "$result" -eq 42
else
    "$work/test"
fi
