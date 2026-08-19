#!/bin/bash
# Fix FantasyDemo server dependencies
LIB_DIR=/home/great/bw-build/game/res/bigworld/scripts/common/Lib

# 1. Create zope.interface stub
mkdir -p "$LIB_DIR/zope"
touch "$LIB_DIR/zope/__init__.py"
cat > "$LIB_DIR/zope/interface.py" << 'PYEOF'
# Minimal stub of zope.interface for BigWorld BWTwistedReactor
class Interface(object):
    def __init__(self, *args, **kw):
        pass
class implementer(object):
    def __init__(self, *args):
        pass
    def __call__(self, cls):
        return cls
def providedBy(obj):
    return False
def implementedBy(cls):
    return []
class Attribute(object):
    def __init__(self, name):
        self.name = name
PYEOF
echo "Created zope.interface stub"

# 2. Verify twisted stub exists
if [ ! -f "$LIB_DIR/twisted/internet/defer.py" ]; then
    echo "Creating twisted stub..."
    bash /mnt/j/Work/BigWorld-Engine-14.4.1/runtime_config/create_twisted_stub.sh
fi

# 3. Verify lib-dynload-el7 exists
if [ ! -d "/home/great/bw-build/game/res/bigworld/scripts/server_common/lib-dynload-el7" ]; then
    echo "Creating lib-dynload-el7..."
    mkdir -p /home/great/bw-build/game/res/bigworld/scripts/server_common/lib-dynload-el7
    cp /usr/local/lib/python2.7/lib-dynload/*.so /home/great/bw-build/game/res/bigworld/scripts/server_common/lib-dynload-el7/
    cp /home/great/bw-build/programming/bigworld/build/el7/third_party/python/build/lib.linux-x86_64-2.7/*.so /home/great/bw-build/game/res/bigworld/scripts/server_common/lib-dynload-el7/ 2>/dev/null
fi

# 4. Verify UserDataObjectRef.py
if [ ! -f "/home/great/bw-build/game/res/bigworld/scripts/common/UserDataObjectRef.py" ]; then
    echo "Copying UserDataObjectRef.py..."
    cp /home/great/bw-build/programming/bigworld/lib/entitydef/unit_test/res/UserDataObjectRef.py /home/great/bw-build/game/res/bigworld/scripts/common/
fi

echo "=== Verification ==="
echo "zope.interface: $(ls $LIB_DIR/zope/interface.py 2>&1)"
echo "twisted.defer: $(ls $LIB_DIR/twisted/internet/defer.py 2>&1)"
echo "lib-dynload-el7: $(ls /home/great/bw-build/game/res/bigworld/scripts/server_common/lib-dynload-el7/ | wc -l) files"
echo "UserDataObjectRef: $(ls /home/great/bw-build/game/res/bigworld/scripts/common/UserDataObjectRef.py 2>&1)"
