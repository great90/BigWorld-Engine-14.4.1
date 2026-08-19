#!/bin/bash
# Create minimal resources.xml at the root of resource tree
set -e

RES_DIR=/home/great/bw-build/programming/bigworld/examples/client_integration/python/simple/res
RES_XML=$RES_DIR/resources.xml

if [ -f "$RES_XML" ]; then
    echo "resources.xml already exists, skipping"
else
    echo "Creating minimal resources.xml at: $RES_XML"
    cat > "$RES_XML" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!-- Minimal resources.xml for cellapp startup.
     AutoConfig entries will use their built-in defaults. -->
<root>
</root>
EOF
    echo "OK: Created resources.xml"
fi

ls -la "$RES_XML"
cat "$RES_XML"
