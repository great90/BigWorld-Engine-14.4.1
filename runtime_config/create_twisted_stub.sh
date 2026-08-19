#!/bin/bash
# Create minimal twisted stub modules for BigWorld PyDeferred
LIB_DIR=/home/great/bw-build/game/res/bigworld/scripts/common/Lib

mkdir -p "$LIB_DIR/twisted/internet"
touch "$LIB_DIR/twisted/__init__.py"
touch "$LIB_DIR/twisted/internet/__init__.py"

cat > "$LIB_DIR/twisted/internet/defer.py" << 'PYEOF'
# Minimal stub of twisted.internet.defer for BigWorld PyDeferred
class Deferred(object):
    def __init__(self):
        self._callbacks = []
    def addCallback(self, cb, *args, **kw):
        self._callbacks.append((cb, args, kw))
        return self
    def addErrback(self, eb, *args, **kw):
        return self
    def addBoth(self, f, *args, **kw):
        return self
    def addCallbacks(self, cb, eb, cbArgs=None, cbKeywords=None, ebArgs=None, ebKeywords=None):
        return self
    def callback(self, result):
        self.result = result
        for cb, args, kw in self._callbacks:
            try:
                if isinstance(result, Exception):
                    continue
                result = cb(result, *args, **kw)
            except Exception as e:
                result = e
    def errback(self, failure=None):
        if failure is None:
            failure = Exception('errback called')
        self.result = failure
PYEOF

echo "Created twisted stub modules:"
find "$LIB_DIR/twisted" -type f -exec ls -la {} \;
