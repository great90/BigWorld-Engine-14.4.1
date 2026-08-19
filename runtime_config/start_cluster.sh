#!/bin/bash
# Start the complete BigWorld server cluster in the correct order.
# Order: bwmachined2 (already running) -> managers -> dbapp -> cellapp -> baseapp -> loginapp

BINS=/home/great/bw-build/game/bin/server/el7
RES=/home/great/bw-build/game/res/fantasydemo
export LD_LIBRARY_PATH=/home/great/bw-build/programming/bigworld/third_party/build/lib:$LD_LIBRARY_PATH

cd "$RES" || { echo "Cannot cd to $RES"; exit 1; }

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }

start_proc() {
    local name=$1
    local bin=$2
    local sleep_sec=${3:-3}
    local log_file="/tmp/${name}.log"

    pkill -x "$name" 2>/dev/null || true
    sleep 0.5

    log "Starting $name..."
    nohup "$BINS/$bin" > "$log_file" 2>&1 &
    local pid=$!
    sleep "$sleep_sec"

    if pgrep -x "$name" >/dev/null 2>&1; then
        ok "$name is running (PID=$(pgrep -x $name | head -1))"
        return 0
    else
        fail "$name is NOT running"
        echo "--- ${name} log (tail 20) ---"
        tail -20 "$log_file" 2>/dev/null
        return 1
    fi
}

# === Phase 1: Stop all server processes (except bwmachined2) ===
log "=== Stopping all existing server processes (except bwmachined2) ==="
for proc in cellapp baseapp dbapp loginapp cellappmgr baseappmgr dbappmgr reviver serviceapp; do
    pkill -x "$proc" 2>/dev/null || true
done
sleep 2

log "Remaining processes:"
pgrep -la 'bwmachined2|cellappmgr|baseappmgr|dbappmgr|cellapp|baseapp|dbapp|loginapp' | sort

# === Phase 2: Start managers (cellappmgr first, then baseappmgr, dbappmgr) ===
log ""
log "=== Phase 2: Starting managers ==="
start_proc cellappmgr server/cellappmgr 3
start_proc baseappmgr server/baseappmgr 3
start_proc dbappmgr   server/dbappmgr   3

# === Phase 3: Start dbapp (provides init data to baseappmgr) ===
log ""
log "=== Phase 3: Starting dbapp ==="
start_proc dbapp server/dbapp 6

# Wait for dbapp to send init data to baseappmgr
log "Waiting for dbapp to send init data to baseappmgr..."
sleep 5

# === Phase 4: Start cellapp (needs cellappmgr) ===
log ""
log "=== Phase 4: Starting cellapp ==="
start_proc cellapp server/cellapp 5 || true

# === Phase 5: Start baseapp (needs baseappmgr + dbapp init data) ===
log ""
log "=== Phase 5: Starting baseapp ==="
start_proc baseapp server/baseapp 6

# === Phase 6: Start loginapp (needs baseapp) ===
log ""
log "=== Phase 6: Starting loginapp ==="
start_proc loginapp server/loginapp 4

# === Summary ===
log ""
log "=== Cluster status ==="
echo ""
pgrep -la 'bwmachined2|cellappmgr|baseappmgr|dbappmgr|cellapp|baseapp|dbapp|loginapp' | sort

echo ""
COUNT=$(pgrep -c 'bwmachined2|cellappmgr|baseappmgr|dbappmgr|cellapp|baseapp|dbapp|loginapp' 2>/dev/null || echo 0)
log "Total server processes running: $COUNT (expected 8)"

echo ""
log "=== Manager logs (tail 5 each) ==="
for m in cellappmgr baseappmgr dbappmgr; do
    echo "--- $m ---"
    tail -5 "/tmp/${m}.log" 2>/dev/null
    echo ""
done

log "=== cellapp log (tail 5) ==="
tail -5 /tmp/cellapp.log 2>/dev/null
