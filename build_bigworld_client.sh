#!/bin/bash
# =============================================================================
# BigWorld Engine 14.4.1 - WSL 客户端构建脚本
# =============================================================================
# 用途: 在 WSL Debian 12 上构建 simple_python_client (Linux 可用的客户端)
# 策略: 使用独立的构建目录和安装目录，避免与服务器构建产物冲突
#       使用 shouldDefineMFServer=1 (默认值)，与 README 文档一致
#       注意: simple_python_client 在 Linux 上需要 MF_SERVER 才能编译
#             (EntityMailBoxRef 及其 DataSource/DataSink 方法依赖 MF_SERVER)
#
# 依赖: 服务器构建已完成 (build_bigworld_server.sh)，第三方库已构建
#
# 用法:
#   wsl -d Debian -- bash /mnt/j/Work/BigWorld-Engine-14.4.1/build_bigworld_client.sh
#
# 输出:
#   /home/great/bw-build/game_client/game/bin/server/el7/examples/simple_python_client
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 全局变量
# -----------------------------------------------------------------------------
BUILD_ROOT="/home/great/bw-build"
BW_ROOT="$BUILD_ROOT/programming/bigworld"
# 关键：使用独立的中间目录和安装目录，避免覆盖服务器构建产物
BW_INTERMEDIATE_DIR_CLIENT="$BW_ROOT/build_client"
BW_INSTALL_DIR_CLIENT="$BUILD_ROOT/game_client"
LOG_DIR="$BUILD_ROOT/logs"
JOBS=$(nproc)

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()    { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()     { echo -e "${GREEN}[OK]${NC} $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()    { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()    { err "$*"; exit 1; }

section() {
    echo ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}  $*${NC}"
    echo -e "${BLUE}================================================================${NC}"
}

# =============================================================================
# 检查前置条件
# =============================================================================
check_prerequisites() {
    section "检查前置条件"

    # 检查服务器源码树是否存在
    if [ ! -d "$BW_ROOT" ]; then
        die "服务器源码树不存在: $BW_ROOT (请先运行 build_bigworld_server.sh)"
    fi
    ok "源码树存在: $BW_ROOT"

    # 检查服务器构建产物是否存在 (验证服务器构建已完成)
    local server_lib_dir="$BW_ROOT/build/el7/lib"
    if [ ! -d "$server_lib_dir" ]; then
        die "服务器构建库目录不存在: $server_lib_dir (请先运行 build_bigworld_server.sh)"
    fi

    local server_lib_count=$(find "$server_lib_dir" -name "lib*.a" 2>/dev/null | wc -l)
    if [ "$server_lib_count" -lt 10 ]; then
        die "服务器构建库数量过少 ($server_lib_count 个 .a 文件)，请先运行 build_bigworld_server.sh)"
    fi
    ok "服务器构建已完成: $server_lib_count 个静态库"

    # 检查服务器二进制是否存在
    local server_bin_dir="$BUILD_ROOT/game/bin/server/el7/server"
    if [ ! -d "$server_bin_dir" ]; then
        die "服务器二进制目录不存在: $server_bin_dir"
    fi
    ok "服务器二进制目录存在"

    # 检查 /etc/redhat-release (平台检测需要)
    if [ ! -f /etc/redhat-release ]; then
        die "/etc/redhat-release 不存在，平台检测将失败"
    fi
    ok "平台标识: $(cat /etc/redhat-release)"
}

# =============================================================================
# 应用客户端构建专用补丁
# =============================================================================
apply_client_patches() {
    section "应用客户端构建补丁"

    cd "$BW_ROOT"

    # 补丁: memory_debug.cpp 的 C++14 allocator 兼容性修复
    # 问题: ENABLE_MEMORY_DEBUG 在客户端构建 (无 MF_SERVER) 时启用，
    #       导致 memory_debug.cpp 被编译，其中的 std::map 使用了
    #       DebugStlAllocator<std::pair<Key, T>> 但 C++14 要求
    #       std::pair<const Key, T>
    # 服务器构建不受影响 (MF_SERVER 定义时 ENABLE_MEMORY_DEBUG=0)
    local MD_FILE="lib/cstdmf/memory_debug.cpp"

    if grep -q 'DebugStlAllocator< std::pair<CallstackAddressType,' "$MD_FILE" 2>/dev/null; then
        log "修复 memory_debug.cpp (C++14 allocator 类型)..."

        # 备份原文件
        if [ ! -f "${MD_FILE}.orig" ]; then
            cp "$MD_FILE" "${MD_FILE}.orig"
        fi

        # Fix 1: CallstackAddressType (void*) key - add const
        sed -i 's|std::pair<CallstackAddressType,|std::pair<const CallstackAddressType,|g' "$MD_FILE"

        # Fix 2: const char* key - need const pointer (const char * const)
        sed -i 's|std::pair<const char \*,|std::pair<const char * const,|g' "$MD_FILE"

        ok "memory_debug.cpp 已修复"
    else
        log "memory_debug.cpp 已修复，跳过"
    fi

    # 确保服务器构建的 bw_map.hpp 补丁已应用
    local BW_MAP="lib/cstdmf/bw_map.hpp"
    if grep -q 'BW::StlAllocator< std::pair< Key, T > >' "$BW_MAP" 2>/dev/null; then
        log "修复 bw_map.hpp (C++14 allocator)..."
        sed -i 's/BW::StlAllocator< std::pair< Key, T > >/BW::StlAllocator< std::pair< const Key, T > >/g' "$BW_MAP"
        ok "bw_map.hpp 已修复"
    else
        log "bw_map.hpp 已修复，跳过"
    fi

    # 补丁: EntityMailBoxRef 可用于客户端构建
    # 问题: EntityMailBoxRef 在 basictypes.hpp 中被 #if defined(MF_SERVER) || defined(__APPLE__)
    #       保护，但 mailbox_base.cpp (entitydef 库) 在所有构建中都引用它。
    #       客户端构建 (无 MF_SERVER) 在 Linux 上会失败。
    # 修复: 移除 MF_SERVER 保护，使 EntityMailBoxRef 始终可用。
    local BT_HPP="lib/network/basictypes.hpp"
    local BT_CPP="lib/network/basictypes.cpp"

    if grep -q '#if defined( MF_SERVER ) || defined( __APPLE__ )' "$BT_HPP" 2>/dev/null; then
        log "修复 basictypes.hpp (EntityMailBoxRef 可用性)..."
        [ ! -f "${BT_HPP}.orig" ] && cp "$BT_HPP" "${BT_HPP}.orig"
        sed -i 's~#if defined( MF_SERVER ) || defined( __APPLE__ )~#if 1 // Always define EntityMailBoxRef~' "$BT_HPP"
        ok "basictypes.hpp 已修复"
    else
        log "basictypes.hpp 已修复，跳过"
    fi

    # 修复 basictypes.cpp 中 componentAsStr 的 MF_SERVER 保护
    if grep -A1 '^#if defined( MF_SERVER )$' "$BT_CPP" 2>/dev/null | grep -q 'componentAsStr'; then
        log "修复 basictypes.cpp (componentAsStr 可用性)..."
        [ ! -f "${BT_CPP}.orig" ] && cp "$BT_CPP" "${BT_CPP}.orig"
        sed -i '/^#if defined( MF_SERVER )$/{N;s|#if defined( MF_SERVER )\nconst char \* EntityMailBoxRef::componentAsStr|#if 1 // Always compile componentAsStr\nconst char * EntityMailBoxRef::componentAsStr|}' "$BT_CPP"
        ok "basictypes.cpp 已修复"
    else
        log "basictypes.cpp 已修复，跳过"
    fi

    # 补丁: DataSource/DataSink 的 EntityMailBoxRef read/write 方法
    # 问题: data_source.hpp 和 data_sink.hpp 中 EntityMailBoxRef 相关方法被
    #       #if defined(MF_SERVER) 保护，但 mailbox_data_type.cpp 引用它们
    local DS_HPP="lib/entitydef/data_source.hpp"
    local DK_HPP="lib/entitydef/data_sink.hpp"

    for hdr in "$DS_HPP" "$DK_HPP"; do
        if grep -A1 '^#if defined( MF_SERVER )$' "$hdr" 2>/dev/null | grep -q 'EntityMailBoxRef'; then
            log "修复 $hdr (EntityMailBoxRef read/write)..."
            [ ! -f "${hdr}.orig" ] && cp "$hdr" "${hdr}.orig"
            awk '
            /^#if defined\( MF_SERVER \)$/ {
                if (getline next_line > 0) {
                    if (next_line ~ /EntityMailBoxRef/) {
                        print "#if 1"
                    } else {
                        print
                    }
                    print next_line
                    next
                }
            }
            { print }
            ' "${hdr}.orig" > "$hdr"
            ok "$hdr 已修复"
        else
            log "$hdr 已修复，跳过"
        fi
    done

    # 确保 GCC 14 兼容性 flags 已添加
    local COMMON_MAK="build/make/platform_common.mak"
    if ! grep -q 'Wno-error=implicit-function-declaration' "$COMMON_MAK" 2>/dev/null; then
        log "添加 GCC 14 兼容性 CFLAGS..."
        sed -i '/^CXXFLAGS += -Wfloat-equal/a CFLAGS += -Wno-error=implicit-function-declaration -Wno-error=implicit-int -Wno-error=int-conversion -Wno-error=incompatible-pointer-types -Wno-error=discarded-qualifiers -Wno-error=return-mismatch\nCXXFLAGS += -Wno-error=implicit-function-declaration -Wno-error=implicit-int -Wno-error=int-conversion -Wno-error=return-mismatch -Wno-error=deprecated-declarations -Wno-error=class-memaccess -Wno-error=expansion-to-defined -Wno-error=stringop-truncation' "$COMMON_MAK"
        ok "GCC 14 CFLAGS 已添加"
    else
        log "GCC 14 CFLAGS 已存在，跳过"
    fi
}

# =============================================================================
# 构建客户端
# =============================================================================
build_client() {
    section "构建 simple_python_client (shouldDefineMFServer=1)"

    cd "$BW_ROOT"

    # 创建独立的构建目录
    mkdir -p "$BW_INTERMEDIATE_DIR_CLIENT"
    mkdir -p "$BW_INSTALL_DIR_CLIENT"

    log "构建配置:"
    log "  BW_INTERMEDIATE_DIR = $BW_INTERMEDIATE_DIR_CLIENT"
    log "  BW_INSTALL_DIR      = $BW_INSTALL_DIR_CLIENT"
    log "  shouldDefineMFServer = 1 (默认)"
    log "  目标                = simple_python_client"
    log "  并行度              = $JOBS"
    log "  日志                = $LOG_DIR/client_build.log"
    echo ""

    # 构建命令说明:
    # - BW_INTERMEDIATE_DIR: 独立的中间文件目录，避免与服务器构建的 obj/lib 冲突
    # - BW_INSTALL_DIR: 独立的安装目录，客户端二进制放在 game_client/ 下
    # - shouldDefineMFServer=1: 定义 MF_SERVER 宏 (Linux 上 simple_python_client 需要)
    #   原因: EntityMailBoxRef 及其 DataSource/DataSink read/write 方法在源码中
    #         被 #if defined(MF_SERVER) 保护。ScriptDataSource/ScriptDataSink
    #         的覆盖方法也依赖 MF_SERVER。不定义会导致抽象类实例化错误。
    # - BW_HOST_PLATFORM=el7: 强制 el7 平台
    # - 目标 simple_python_client: 只构建客户端可执行文件及其依赖库
    local build_cmd="BW_INTERMEDIATE_DIR=$BW_INTERMEDIATE_DIR_CLIENT \
BW_INSTALL_DIR=$BW_INSTALL_DIR_CLIENT \
shouldDefineMFServer=1 \
BW_HOST_PLATFORM=el7 \
make -j$JOBS simple_python_client"

    log "执行: $build_cmd"
    echo ""

    # 执行构建
    if BW_INTERMEDIATE_DIR=$BW_INTERMEDIATE_DIR_CLIENT \
       BW_INSTALL_DIR=$BW_INSTALL_DIR_CLIENT \
       shouldDefineMFServer=1 \
       BW_HOST_PLATFORM=el7 \
       make -j"$JOBS" simple_python_client 2>&1 | tee "$LOG_DIR/client_build.log" | tail -30; then

        ok "构建命令执行完成"
    else
        err "构建失败"
        echo ""
        err "错误汇总:"
        grep -E "Error|error:|undefined reference" "$LOG_DIR/client_build.log" | sort -u | head -30
        die "客户端构建失败"
    fi

    # 检查最终错误
    if grep -q '^make:.*Error' "$LOG_DIR/client_build.log" 2>/dev/null; then
        err "构建日志中存在错误"
        grep '^make:.*Error' "$LOG_DIR/client_build.log"
        die "构建失败"
    fi

    # 检查二进制是否生成 (注意: BW_INSTALL_DIR 下会多一层 game/ 目录)
    local binary_path="$BW_INSTALL_DIR_CLIENT/game/bin/server/el7/examples/simple_python_client"
    if [ -f "$binary_path" ]; then
        ok "客户端二进制已生成: $binary_path"
        ls -lh "$binary_path"
        file "$binary_path"
    else
        err "客户端二进制未找到: $binary_path"
        err "检查构建日志: $LOG_DIR/client_build.log"
        die "构建失败"
    fi
}

# =============================================================================
# 验证客户端
# =============================================================================
verify_client() {
    section "验证客户端二进制"

    local binary_path="$BW_INSTALL_DIR_CLIENT/game/bin/server/el7/examples/simple_python_client"
    local tp_lib_dir="$BW_ROOT/third_party/build/lib"
    local client_lib_dir="$BW_ROOT/build_client/el7/lib"

    log "运行 -help 测试..."
    if LD_LIBRARY_PATH="$tp_lib_dir:$client_lib_dir" "$binary_path" -help 2>&1 | head -10; then
        ok "客户端可执行"
    else
        err "客户端执行失败"
        return 1
    fi

    echo ""
    log "客户端库依赖:"
    ldd "$binary_path" 2>&1 | head -20
}

# =============================================================================
# 主流程
# =============================================================================
main() {
    section "BigWorld 14.4.1 客户端构建 (simple_python_client)"

    check_prerequisites
    apply_client_patches
    build_client
    verify_client

    section "构建完成"
    ok "客户端二进制位置:"
    ok "  $BW_INSTALL_DIR_CLIENT/game/bin/server/el7/examples/simple_python_client"
    ok ""
    ok "构建日志:"
    ok "  $LOG_DIR/client_build.log"
    ok ""
    ok "运行方式:"
    ok "  LD_LIBRARY_PATH=$BW_ROOT/third_party/build/lib:$BW_ROOT/build_client/el7/lib \\"
    ok "  $BW_INSTALL_DIR_CLIENT/game/bin/server/el7/examples/simple_python_client \\"
    ok "  -server <server_addr>:<port> -user <user> -password <pass>"
}

main "$@"
