#!/bin/bash
# Switch server resources from simple/res to fantasydemo
# This copies all necessary dependencies from simple/res to fantasydemo

SIMPLE=/home/great/bw-build/programming/bigworld/examples/client_integration/python/simple/res
FD=/home/great/bw-build/game/res/fantasydemo
BW=/home/great/bw-build/game/res/bigworld

echo "=== 1. Copy Python Lib (stdlib + twisted) ==="
cp -r "$SIMPLE/scripts/common/Lib" "$FD/scripts/common/Lib"
echo "Done"

echo "=== 2. Copy zope stubs ==="
cp -r "$BW/scripts/common/Lib/zope" "$FD/scripts/common/Lib/zope"
echo "Done"

echo "=== 3. Copy lib-dynload-el7 ==="
cp -r "$SIMPLE/scripts/server_common/lib-dynload-el7" "$FD/scripts/server_common/lib-dynload-el7"
echo "Done"

echo "=== 4. Copy development_defaults.xml ==="
cp "$SIMPLE/server/development_defaults.xml" "$FD/server/development_defaults.xml"
echo "Done"

echo "=== 5. Copy loginapp.privkey ==="
cp "$SIMPLE/server/loginapp.privkey" "$FD/server/loginapp.privkey"
echo "Done"

echo "=== 6. Create resources.xml ==="
echo '<root></root>' > "$FD/resources.xml"
echo "Done"

echo "=== 7. Verify ==="
echo "Lib dir:"; ls "$FD/scripts/common/Lib/" | head -5
echo "twisted:"; ls "$FD/scripts/common/Lib/twisted/" 2>/dev/null
echo "zope:"; ls "$FD/scripts/common/Lib/zope/" 2>/dev/null
echo "lib-dynload-el7 count:"; ls "$FD/scripts/server_common/lib-dynload-el7/" 2>/dev/null | wc -l
echo "development_defaults.xml:"; test -f "$FD/server/development_defaults.xml" && echo "EXISTS"
echo "loginapp.privkey:"; test -f "$FD/server/loginapp.privkey" && echo "EXISTS"
echo "resources.xml:"; test -f "$FD/resources.xml" && echo "EXISTS"

echo ""
echo "=== 8. Update ~/.bwmachined.conf ==="
echo "great;/home/great/bw-build/game/res/fantasydemo" > ~/.bwmachined.conf
cat ~/.bwmachined.conf
echo ""
echo "ALL DONE"
