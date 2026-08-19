#!/bin/bash
# Copy Python C extensions and standard library to the correct locations
RES=/home/great/bw-build/programming/bigworld/examples/client_integration/python/simple/res
PY_BUILD=/home/great/bw-build/programming/bigworld/third_party/python/build
PY_INSTALL=/home/great/bw-build/programming/bigworld/third_party/build

# 1. Copy C extensions to scripts/server_common/lib-dynload-el7/
DYNLOAD_DST="$RES/scripts/server_common/lib-dynload-el7"
mkdir -p "$DYNLOAD_DST"
echo "=== Copying C extensions to $DYNLOAD_DST ==="
cp "$PY_BUILD"/lib.linux-x86_64-2.7/*.so "$DYNLOAD_DST/" 2>/dev/null
echo "Copied $(ls "$DYNLOAD_DST"/*.so 2>/dev/null | wc -l) .so files"

# 2. Copy Python standard library to scripts/common/Lib/
LIB_DST="$RES/scripts/common/Lib"
if [ ! -d "$LIB_DST" ]; then
    mkdir -p "$LIB_DST"
    echo "=== Copying Python standard library to $LIB_DST ==="
    if [ -d "$PY_INSTALL/lib/python2.7" ]; then
        cp -r "$PY_INSTALL/lib/python2.7"/* "$LIB_DST/" 2>/dev/null
        echo "Copied Python stdlib"
    else
        echo "Python stdlib not found at $PY_INSTALL/lib/python2.7"
    fi
    # Remove any .pyc files to save space
    find "$LIB_DST" -name "*.pyc" -delete 2>/dev/null
else
    echo "Lib directory already exists at $LIB_DST"
fi

echo ""
echo "=== Verification ==="
echo "cPickle.so: $(ls "$DYNLOAD_DST/cPickle.so" 2>/dev/null || echo 'NOT FOUND')"
echo "cStringIO.so: $(ls "$DYNLOAD_DST/cStringIO.so" 2>/dev/null || echo 'NOT FOUND')"
echo "Lib/os.py: $(ls "$LIB_DST/os.py" 2>/dev/null || echo 'NOT FOUND')"
echo "Lib/socket.py: $(ls "$LIB_DST/socket.py" 2>/dev/null || echo 'NOT FOUND')"
