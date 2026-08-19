#!/bin/bash
# Wait and check cluster status, then show key logs

echo "=== Waiting 5 seconds for cluster to stabilise ==="
sleep 5

echo ""
echo "=== Cluster status ==="
pgrep -la 'bwmachined2|cellappmgr|baseappmgr|dbappmgr|cellapp|baseapp|dbapp|loginapp' | sort

echo ""
echo "=== Process count ==="
COUNT=$(pgrep -c 'bwmachined2|cellappmgr|baseappmgr|dbappmgr|cellapp|baseapp|dbapp|loginapp' 2>/dev/null || echo 0)
echo "Total server processes running: $COUNT (expected 8)"

echo ""
echo "=== cellappmgr log (tail 15) ==="
tail -15 /tmp/cellappmgr.log 2>/dev/null

echo ""
echo "=== cellapp log (tail 15) ==="
tail -15 /tmp/cellapp.log 2>/dev/null

echo ""
echo "=== baseappmgr log (tail 10) ==="
tail -10 /tmp/baseappmgr.log 2>/dev/null

echo ""
echo "=== baseapp log (tail 10) ==="
tail -10 /tmp/baseapp.log 2>/dev/null
