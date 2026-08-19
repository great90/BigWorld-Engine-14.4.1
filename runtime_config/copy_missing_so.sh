#!/bin/bash
# Copy missing C extension .so files from system Python 2.7 to lib-dynload-el7

SRC="/usr/local/lib/python2.7/lib-dynload"
DST="/home/great/bw-build/programming/bigworld/examples/client_integration/python/simple/res/scripts/server_common/lib-dynload-el7"

echo "=== Missing .so files (in system, not in our lib-dynload-el7) ==="
copied=0
for f in "$SRC"/*.so; do
    name=$(basename "$f")
    if [ ! -f "$DST/$name" ]; then
        echo "Copying: $name"
        cp "$f" "$DST/$name"
        copied=$((copied + 1))
    fi
done
echo "Copied $copied files"
echo "---total in lib-dynload-el7---"
ls "$DST"/*.so | wc -l
