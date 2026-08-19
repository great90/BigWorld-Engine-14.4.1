#!/bin/bash
# =============================================================================
# BigWorld Engine 14.4.1 - WSL 服务器一键构建脚本
# =============================================================================
# 用途: 在 WSL Debian 12 (bookworm) 上从源码完整构建 BigWorld 服务器
# 输出: /home/great/bw-build/game/bin/server/el7/ 下的所有服务器二进制
#
# 用法:
#   # 完整构建（含依赖安装、源码复制）
#   wsl -d Debian -- bash /mnt/j/Work/BigWorld-Engine-14.4.1/build_bigworld_server.sh
#
#   # 跳过依赖安装（已安装过）
#   wsl -d Debian -- bash /mnt/j/Work/BigWorld-Engine-14.4.1/build_bigworld_server.sh --skip-deps
#
#   # 跳过源码复制（已复制过，仅重新打补丁）
#   wsl -d Debian -- bash /mnt/j/Work/BigWorld-Engine-14.4.1/build_bigworld_server.sh --skip-copy
#
#   # 仅运行修复补丁（不构建）
#   wsl -d Debian -- bash /mnt/j/Work/BigWorld-Engine-14.4.1/build_bigworld_server.sh --patches-only
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 全局变量
# -----------------------------------------------------------------------------
SRC_WIN_DIR="/mnt/j/Work/BigWorld-Engine-14.4.1"
BUILD_ROOT="/home/great/bw-build"
BW_ROOT="$BUILD_ROOT/programming/bigworld"
OUTPUT_DIR="$BUILD_ROOT/game/bin/server/el7"
LOG_DIR="$BUILD_ROOT/logs"
JOBS=$(nproc)

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 参数解析
SKIP_DEPS=0
SKIP_COPY=0
PATCHES_ONLY=0
for arg in "$@"; do
    case $arg in
        --skip-deps)     SKIP_DEPS=1 ;;
        --skip-copy)     SKIP_COPY=1 ;;
        --patches-only)  PATCHES_ONLY=1 ;;
        --help|-h)
            head -20 "$0"
            exit 0
            ;;
    esac
done

# -----------------------------------------------------------------------------
# 工具函数
# -----------------------------------------------------------------------------
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

# 检查是否已打补丁（通过 grep 检查特征字符串）
patched() {
    grep -q "$1" "$2" 2>/dev/null
}

# =============================================================================
# Phase 1: 环境准备
# =============================================================================
phase1_environment() {
    section "Phase 1: 环境准备"

    if [ "$SKIP_DEPS" -eq 1 ]; then
        log "跳过依赖安装 (--skip-deps)"
        return 0
    fi

    # 1.1 配置清华镜像源（可选，加速 apt）
    if ! grep -q "mirrors.tuna.tsinghua.edu.cn" /etc/apt/sources.list 2>/dev/null; then
        log "配置清华镜像源..."
        sudo tee /etc/apt/sources.list > /dev/null << 'EOF'
deb https://mirrors.tuna.tsinghua.edu.cn/debian/ bookworm main contrib non-free non-free-firmware
deb https://mirrors.tuna.tsinghua.edu.cn/debian/ bookworm-updates main contrib non-free non-free-firmware
deb https://mirrors.tuna.tsinghua.edu.cn/debian/ bookworm-backports main contrib non-free non-free-firmware
deb https://mirrors.tuna.tsinghua.edu.cn/debian-security bookworm-security main contrib non-free non-free-firmware
EOF
        sudo apt update -y
        ok "镜像源已配置"
    else
        log "镜像源已配置，跳过"
    fi

    # 1.2 安装构建依赖
    log "安装构建依赖..."
    sudo apt install -y \
        build-essential g++ make scons python3 python3-pip \
        bison flex autoconf automake libtool pkg-config \
        libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev \
        libffi-dev libncursesw5-dev libgdbm-dev liblzma-dev libexpat1-dev \
        libxml2-dev libxslt1-dev libcurl4-openssl-dev \
        libboost-all-dev libmysqlclient-dev libpq-dev \
        libxml2-utils xsltproc docbook-xsl \
        git subversion wget curl unzip
    ok "依赖安装完成"

    # 1.3 模拟 CentOS 7 平台
    if [ ! -f /etc/redhat-release ]; then
        log "创建 /etc/redhat-release (模拟 CentOS 7)..."
        echo "CentOS Linux release 7.9.2009 (Core)" | sudo tee /etc/redhat-release > /dev/null
        ok "redhat-release 已创建"
    else
        log "redhat-release 已存在"
    fi

    # 1.4 mysql_config 符号链接
    if [ ! -e /usr/lib64/mysql/mysql_config ]; then
        log "创建 mysql_config 符号链接..."
        sudo mkdir -p /usr/lib64/mysql
        sudo ln -sf /usr/bin/mariadb_config /usr/lib64/mysql/mysql_config
        ok "mysql_config 链接已创建"
    else
        log "mysql_config 已存在"
    fi
}

# =============================================================================
# Phase 2: 源码准备
# =============================================================================
phase2_source() {
    section "Phase 2: 源码准备"

    mkdir -p "$BUILD_ROOT"
    mkdir -p "$LOG_DIR"

    if [ "$SKIP_COPY" -eq 1 ]; then
        log "跳过源码复制 (--skip-copy)"
        if [ ! -d "$BW_ROOT" ]; then
            die "构建目录 $BW_ROOT 不存在，请去掉 --skip-copy"
        fi
    else
        # 2.1 复制源码到 WSL 原生文件系统
        if [ ! -d "$BW_ROOT" ]; then
            log "复制源码到 $BUILD_ROOT ..."
            cp -r "$SRC_WIN_DIR" "$BUILD_ROOT"
            ok "源码复制完成"
        else
            log "构建目录已存在，跳过复制（如需重新复制请删除 $BUILD_ROOT）"
        fi
    fi

    # 2.2 修复 CRLF 行尾
    log "修复 CRLF 行尾..."
    cd "$BUILD_ROOT/programming"
    # 修复源码目录
    grep -rIlP '\r$' ./bigworld 2>/dev/null | xargs -r -d '\n' sed -i 's/\r$//' 2>/dev/null || true
    # 修复构建输出目录（如果存在）
    if [ -d "$BW_ROOT/build/el7" ]; then
        grep -rIlP '\r$' "$BW_ROOT/build/el7" 2>/dev/null | xargs -r -d '\n' sed -i 's/\r$//' 2>/dev/null || true
    fi
    ok "CRLF 修复完成"
}

# =============================================================================
# Phase 3: 第三方库构建
# =============================================================================

# 3.1 构建 Python 2.7
build_python27() {
    section "Phase 3.1: 构建 Python 2.7"

    local PY_BUILD="$BW_ROOT/third_party/python"
    local PY_INSTALLED="$BW_ROOT/third_party/build/bin/python2.7"

    if [ -f "$PY_INSTALLED" ]; then
        log "Python 2.7 已构建，跳过"
        return 0
    fi

    cd "$PY_BUILD"

    # 修复 mathmodule.c 中的 sinpi 符号冲突（检查是否已修复）
    if grep -q '\bsinpi\b' Modules/mathmodule.c 2>/dev/null && ! grep -q 'bw_sinpi' Modules/mathmodule.c 2>/dev/null; then
        log "修复 sinpi 符号冲突..."
        sed -i 's/sinpi/bw_sinpi/g' Modules/mathmodule.c
    fi

    log "配置 Python 2.7..."
    ./configure --prefix=$PWD/../build --enable-shared > "$LOG_DIR/python_configure.log" 2>&1

    log "编译 Python 2.7..."
    make -j"$JOBS" > "$LOG_DIR/python_make.log" 2>&1
    make install > "$LOG_DIR/python_install.log" 2>&1
    ok "Python 2.7 构建完成"
}

# 3.2 构建 OpenSSL
build_openssl() {
    section "Phase 3.2: 构建 OpenSSL"

    local SSL_BUILD="$BW_ROOT/third_party/openssl"
    local SSL_INSTALLED="$BW_ROOT/third_party/build/lib/libssl.a"

    if [ -f "$SSL_INSTALLED" ]; then
        log "OpenSSL 已构建，跳过"
        return 0
    fi

    cd "$SSL_BUILD"
    log "配置 OpenSSL..."
    ./config --prefix=$PWD/../build shared zlib > "$LOG_DIR/openssl_configure.log" 2>&1

    log "编译 OpenSSL..."
    make -j"$JOBS" > "$LOG_DIR/openssl_make.log" 2>&1
    make install > "$LOG_DIR/openssl_install.log" 2>&1
    ok "OpenSSL 构建完成"
}

# 3.3 构建 cURL
build_curl() {
    section "Phase 3.3: 构建 cURL"

    local CURL_BUILD="$BW_ROOT/third_party/libcurl-el7"
    local CURL_INSTALLED="$BW_ROOT/third_party/build/lib/libcurl.a"

    if [ -f "$CURL_INSTALLED" ]; then
        log "cURL 已构建，跳过"
        return 0
    fi

    # 修复 gzguts.h 中缺少 unistd.h
    local GZGUTS="$BW_ROOT/third_party/zlib/gzguts.h"
    if ! grep -q '<unistd.h>' "$GZGUTS" 2>/dev/null; then
        log "修复 gzguts.h (添加 unistd.h)..."
        sed -i '/#include <fcntl.h>/a #include <unistd.h>' "$GZGUTS"
    fi

    cd "$CURL_BUILD"
    log "运行 buildconf..."
    ./buildconf > "$LOG_DIR/curl_buildconf.log" 2>&1 || true

    log "配置 cURL..."
    CFLAGS="-Wno-error=implicit-int -Wno-error=int-conversion -Wno-error=implicit-function-declaration -Wno-error=incompatible-pointer-types -Wno-error=discarded-qualifiers" \
    ./configure --prefix=$PWD/../build --with-ssl --disable-shared > "$LOG_DIR/curl_configure.log" 2>&1

    log "编译 cURL..."
    make -j"$JOBS" > "$LOG_DIR/curl_make.log" 2>&1
    make install > "$LOG_DIR/curl_install.log" 2>&1
    ok "cURL 构建完成"
}

# 3.4 构建 MongoDB C++ 驱动
build_mongodb() {
    section "Phase 3.4: 构建 MongoDB C++ 驱动"

    local MONGO_DIR="$BW_ROOT/third_party/mongodb"
    local BOOST_DIR="$MONGO_DIR/boost"
    local MONGO_CXX_DIR="$MONGO_DIR/mongo_cxx_driver"
    local MONGO_SRC="$MONGO_CXX_DIR/mongo_cxx_driver"
    local MONGO_INSTALLED="$MONGO_CXX_DIR/build/lib/libmongoclient.a"

    if [ -f "$MONGO_INSTALLED" ]; then
        log "MongoDB 驱动已构建，跳过"
        return 0
    fi

    # 解压源码
    if [ ! -d "$MONGO_SRC" ]; then
        log "解压 MongoDB C++ 驱动源码..."
        cd "$MONGO_CXX_DIR"
        tar zxf mongo-cxx-driver-legacy-0.0-26compat-2.6.7.tar.gz
        mv mongo-cxx-driver-legacy-0.0-26compat-2.6.7 mongo_cxx_driver
    fi

    # 3.4.1 设置 Boost 符号链接（使用系统 Boost 1.83）
    log "设置 Boost 符号链接..."
    mkdir -p "$BOOST_DIR/build/lib"
    mkdir -p "$BOOST_DIR/build/include"

    for lib in system filesystem thread regex program_options; do
        local SRC="/usr/lib/x86_64-linux-gnu/libboost_${lib}.a"
        local DST="$BOOST_DIR/build/lib/libboost_${lib}-mt.a"
        if [ -f "$SRC" ] && [ ! -e "$DST" ]; then
            ln -sf "$SRC" "$DST"
        fi
    done

    # 关键：替换 Boost 1.54 头文件为系统 Boost 1.83 符号链接
    if [ -d "$BOOST_DIR/build/include/boost" ] && [ ! -L "$BOOST_DIR/build/include/boost" ]; then
        log "替换 Boost 1.54 头文件为系统 1.83 符号链接..."
        rm -rf "$BOOST_DIR/build/include/boost"
    fi
    if [ ! -e "$BOOST_DIR/build/include/boost" ]; then
        ln -sf /usr/include/boost "$BOOST_DIR/build/include/boost"
    fi
    ok "Boost 符号链接已设置"

    # 3.4.2 Python 2 → 3 兼容性修复
    log "应用 Python 2→3 兼容性修复..."

    # SConstruct 修复
    local SCONSTRUCT="$MONGO_SRC/SConstruct"
    sed -i 's/lambda(\(ctx\))/lambda \1/g' "$SCONSTRUCT"
    sed -i 's/`i`/repr(i)/g' "$SCONSTRUCT"
    # 使用 python3 处理 print 语句和 has_key
    python3 << 'PYEOF'
import re
filepath = "/home/great/bw-build/programming/bigworld/third_party/mongodb/mongo_cxx_driver/mongo_cxx_driver/SConstruct"
with open(filepath, "r") as f:
    content = f.read()
# print "..." -> print("...")
content = re.sub(r'(\bprint\s+)"([^"]*"[^#\n]*)$', lambda m: 'print("' + m.group(2) + ')', content, flags=re.MULTILINE)
content = re.sub(r"(\bprint\s+)'([^']*'[^#\n]*)$", lambda m: "print('" + m.group(2) + "')", content, flags=re.MULTILINE)
# .has_key(x) -> x in dict
content = re.sub(r'(\w+)\.has_key\(([^)]+)\)', r'\2 in \1', content)
with open(filepath, "w") as f:
    f.write(content)
PYEOF

    # 所有 .py 文件的通用修复（except, raise, iteritems 等）
    find "$MONGO_SRC" -type f \( -name "*.py" -o -name "SConstruct" -o -name "SConscript" \) 2>/dev/null | while read -r FILE; do
        # except X,e: -> except X as e:
        sed -i -E 's/(except\s+[A-Za-z][A-Za-z_.]*)\s*,\s*([a-zA-Z_]+):/\1 as \2:/g' "$FILE" 2>/dev/null || true
        # iteritems/itervalues/iterkeys
        sed -i 's/\.iteritems()/.items()/g; s/\.itervalues()/.values()/g; s/\.iterkeys()/.keys()/g' "$FILE" 2>/dev/null || true
        # lambda(x) -> lambda x
        sed -i 's/lambda(\(\w*\))/lambda \1/g' "$FILE" 2>/dev/null || true
    done

    # moduleconfig.py: imp.load_module -> importlib.util
    local MODCONF="$MONGO_SRC/buildscripts/moduleconfig.py"
    if grep -q 'import imp' "$MODCONF" 2>/dev/null; then
        log "  修复 moduleconfig.py (imp -> importlib)..."
        python3 << 'PYEOF'
filepath = "/home/great/bw-build/programming/bigworld/third_party/mongodb/mongo_cxx_driver/mongo_cxx_driver/buildscripts/moduleconfig.py"
with open(filepath, "r") as f:
    content = f.read()
content = content.replace("import imp\n", "import importlib.util\n")
content = content.replace(
    'fp = open(build_py, "r")\n            try:\n                module = imp.load_module("module_" + name, fp, build_py,\n                                         (".py", "r", imp.PY_SOURCE))\n                if getattr(module, "name", None) is None:\n                    module.name = name\n                found_modules.append(module)\n            finally:\n                fp.close()',
    'try:\n                spec = importlib.util.spec_from_file_location("module_" + name, build_py)\n                module = importlib.util.module_from_spec(spec)\n                spec.loader.exec_module(module)\n                if getattr(module, "name", None) is None:\n                    module.name = name\n                found_modules.append(module)\n            except Exception:\n                pass'
)
with open(filepath, "w") as f:
    f.write(content)
PYEOF
    fi

    # utils.py 和 libdeps.py: 添加 unicode = str 兼容垫片
    for SHIM_FILE in "$MONGO_SRC/buildscripts/utils.py" "$MONGO_SRC/site_scons/libdeps.py"; do
        if [ -f "$SHIM_FILE" ] && ! grep -q 'unicode = str' "$SHIM_FILE" 2>/dev/null; then
            log "  添加 unicode 兼容垫片: $(basename "$SHIM_FILE")..."
            python3 << PYEOF
filepath = "$SHIM_FILE"
with open(filepath, "r") as f:
    content = f.read()
lines = content.split('\n')
insert_idx = None
for i, line in enumerate(lines):
    if line.startswith('import ') or line.startswith('from '):
        insert_idx = i
        while insert_idx + 1 < len(lines) and (lines[insert_idx + 1].startswith('import ') or lines[insert_idx + 1].startswith('from ')):
            insert_idx += 1
        break
if insert_idx is not None:
    lines.insert(insert_idx + 1, "")
    lines.insert(insert_idx + 2, "try:")
    lines.insert(insert_idx + 3, "    unicode")
    lines.insert(insert_idx + 4, "except NameError:")
    lines.insert(insert_idx + 5, "    unicode = str")
else:
    lines = ["try:", "    unicode", "except NameError:", "    unicode = str", "", ""] + lines
with open(filepath, "w") as f:
    f.write('\n'.join(lines))
PYEOF
        fi
    done

    # libdeps.py: sorted(cmp=) -> sorted(key=functools.cmp_to_key())
    local LIBDEPS="$MONGO_SRC/site_scons/libdeps.py"
    if grep -q 'import functools' "$LIBDEPS" 2>/dev/null; then
        : # already patched
    else
        log "  修复 libdeps.py (sorted cmp -> key)..."
        python3 << 'PYEOF'
import re
filepath = "/home/great/bw-build/programming/bigworld/third_party/mongodb/mongo_cxx_driver/mongo_cxx_driver/site_scons/libdeps.py"
with open(filepath, "r") as f:
    content = f.read()
if "import functools" not in content:
    content = re.sub(r'(import [^\n]+\n)', r'\1import functools\n', content, count=1)
content = content.replace(
    "sorted(iterable, cmp=lambda lhs, rhs: cmp(str(lhs), str(rhs)))",
    "sorted(iterable, key=functools.cmp_to_key(lambda lhs, rhs: (str(lhs) > str(rhs)) - (str(lhs) < str(rhs))))"
)
content = content.replace("type(syslib) in (str, unicode)", "isinstance(syslib, str)")
with open(filepath, "w") as f:
    f.write(content)
PYEOF
    fi

    # SConscript.client: 八进制字面量 0644 -> 0o644
    find "$MONGO_SRC" -name "SConscript*" -o -name "SConstruct" 2>/dev/null | xargs -r sed -i "s/\b0\([0-7][0-7][0-7]\)/0o\1/g" 2>/dev/null || true

    # SConscript.buildinfo 和 generate_error_codes.py: open(...,'wb') -> open(...,'w')
    find "$MONGO_SRC" -type f \( -name "*.py" -o -name "SConscript*" -o -name "SConstruct" \) 2>/dev/null | while read -r f; do
        sed -i "s/open(\([^)]*\)'wb')/open(\1'w')/g" "$f" 2>/dev/null || true
    done

    ok "Python 2→3 修复完成"

    # 3.4.3 C++ 兼容性修复
    log "应用 C++ 兼容性修复..."

    # 创建 endian.hpp 垫片（Boost 1.75+ 移除了此头文件）
    local ENDIAN_SHIM="$MONGO_SRC/src/boost/detail/endian.hpp"
    mkdir -p "$(dirname "$ENDIAN_SHIM")"
    cat > "$ENDIAN_SHIM" << 'ENDOFHEADER'
#ifndef BOOST_DETAIL_ENDIAN_HPP
#define BOOST_DETAIL_ENDIAN_HPP
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
  #define BOOST_BIG_ENDIAN 1
#elif defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
  #define BOOST_LITTLE_ENDIAN 1
#elif defined(__i386__) || defined(__x86_64__) || defined(_M_IX86) || defined(_M_X64) || defined(_WIN32)
  #define BOOST_LITTLE_ENDIAN 1
#else
  #define BOOST_LITTLE_ENDIAN 1
#endif
#endif
ENDOFHEADER

    # 修复 GCC 14 指针比较错误: _conn > 0 -> _conn != 0
    sed -i 's/return _conn > 0;/return _conn != 0;/g' "$MONGO_SRC/src/mongo/client/connpool.h" 2>/dev/null || true
    sed -i 's/return _conn > 0;/return _conn != 0;/g' "$MONGO_SRC/src/mongo/s/shard.h" 2>/dev/null || true

    ok "C++ 修复完成"

    # 3.4.4 编译 MongoDB 驱动
    log "编译 MongoDB C++ 驱动 (scons)..."
    cd "$MONGO_SRC"
    CXXFLAGS="-Wno-error=deprecated-declarations -Wno-error=unused-variable -Wno-error=narrowing -Wno-error=shift-negative-value -Wno-error=deprecated-copy -Wno-error=class-memaccess -Wno-error=stringop-truncation -Wno-error=packed-not-aligned -Wno-error=maybe-uninitialized -Wno-error=array-bounds -Wno-error=restrict -Wno-error=stringop-overflow -Wno-error=implicit-fallthrough -Wno-error=useless-cast -Wno-error=missing-field-initializers -Wno-error=parentheses -Wno-error=invalid-offsetof" \
    scons --c++11=C++11 --full --use-system-boost --disable-warnings-as-errors \
        --prefix=$PWD/../build \
        --libpath="$BOOST_DIR/build/lib" \
        --cpppath=/usr/include \
        install-mongoclient > "$LOG_DIR/mongodb_scons.log" 2>&1 || {
        err "MongoDB 驱动构建失败，查看日志: $LOG_DIR/mongodb_scons.log"
        tail -30 "$LOG_DIR/mongodb_scons.log"
        die "构建中止"
    }
    ok "MongoDB 驱动构建完成: $(ls -lh "$MONGO_CXX_DIR/build/lib/libmongoclient.a" | awk '{print $5}')"

    # 3.4.5 在安装目录创建 endian.hpp 垫片（message_logger 编译需要）
    local BUILD_ENDIAN="$MONGO_CXX_DIR/build/include/boost/detail/endian.hpp"
    mkdir -p "$(dirname "$BUILD_ENDIAN")"
    cp "$ENDIAN_SHIM" "$BUILD_ENDIAN"
    ok "endian.hpp 垫片已安装到构建目录"
}

# =============================================================================
# Phase 4: 服务器构建修复
# =============================================================================
phase4_patches() {
    section "Phase 4: 服务器构建补丁"

    cd "$BW_ROOT"

    # 4.1 禁用 -Werror (platform_group_redhat.mak) — 仅匹配未注释的行
    local REDHAT_MAK="build/make/platform_group_redhat.mak"
    if grep -qE '^[^#]*CXXFLAGS.*-Werror' "$REDHAT_MAK" 2>/dev/null; then
        log "禁用 -Werror (platform_group_redhat.mak)..."
        sed -i 's/^\([^#]*\)CXXFLAGS[[:space:]]*+= -Werror/#CXXFLAGS\t+= -Werror  # disabled for GCC 14/' "$REDHAT_MAK"
        ok "-Werror 已禁用"
    else
        log "-Werror 已禁用，跳过"
    fi

    # 4.2 添加 GCC 14 兼容性 CFLAGS (platform_common.mak)
    local COMMON_MAK="build/make/platform_common.mak"
    if ! grep -q 'Wno-error=implicit-function-declaration' "$COMMON_MAK" 2>/dev/null; then
        log "添加 GCC 14 兼容性 CFLAGS..."
        sed -i '/^CXXFLAGS += -Wfloat-equal/a CFLAGS += -Wno-error=implicit-function-declaration -Wno-error=implicit-int -Wno-error=int-conversion -Wno-error=incompatible-pointer-types -Wno-error=discarded-qualifiers -Wno-error=return-mismatch\nCXXFLAGS += -Wno-error=implicit-function-declaration -Wno-error=implicit-int -Wno-error=int-conversion -Wno-error=return-mismatch -Wno-error=deprecated-declarations -Wno-error=class-memaccess -Wno-error=expansion-to-defined -Wno-error=stringop-truncation' "$COMMON_MAK"
        ok "GCC 14 CFLAGS 已添加"
    else
        log "GCC 14 CFLAGS 已存在，跳过"
    fi

    # 4.3 修复 bw_map.hpp (C++14 allocator 类型)
    local BW_MAP="lib/cstdmf/bw_map.hpp"
    if grep -q 'BW::StlAllocator< std::pair< Key, T > >' "$BW_MAP" 2>/dev/null; then
        log "修复 bw_map.hpp (C++14 allocator)..."
        sed -i 's/BW::StlAllocator< std::pair< Key, T > >/BW::StlAllocator< std::pair< const Key, T > >/g' "$BW_MAP"
        ok "bw_map.hpp 已修复"
    else
        log "bw_map.hpp 已修复，跳过"
    fi

    # 4.4 修复 SIGUNUSED → SIGSYS
    local SIGNAL_CPP="lib/server/signal_processor.cpp"
    if grep -q 'SIGUNUSED' "$SIGNAL_CPP" 2>/dev/null; then
        log "修复 SIGUNUSED -> SIGSYS..."
        sed -i 's/sigNum <= SIGUNUSED/sigNum <= SIGSYS/' "$SIGNAL_CPP"
        ok "SIGUNUSED 已修复"
    else
        log "SIGUNUSED 已修复，跳过"
    fi

    # 4.5 修复 Python 构建系统 (third_party_python.mak)
    local PY_MAK="build/make/third_party_python.mak"
    # 4.5.1 忽略 sharedmods 错误（_curses 等模块在现代 ncurses 上编译失败）
    if ! grep -qP '^\s*-.*MAKE_WITHOUT_JOBSERVER.*sharedmods' "$PY_MAK" 2>/dev/null; then
        log "修复 third_party_python.mak (忽略 sharedmods 错误)..."
        sed -i 's|^\t\$(MAKE_WITHOUT_JOBSERVER) -C \$(PYTHON_BUILD_DIR) sharedmods|\t-\$(MAKE_WITHOUT_JOBSERVER) -C \$(PYTHON_BUILD_DIR) sharedmods|' "$PY_MAK"
    fi
    # 4.5.2 移除无法构建的模块
    if grep -q '_hashlib\.so\| nis\.so' "$PY_MAK" 2>/dev/null; then
        log "移除 _hashlib.so 和 nis.so 模块..."
        sed -i 's/ _hashlib\.so//; s/ nis\.so//' "$PY_MAK"
    fi
    # 4.5.3 dash 兼容性: == -> =
    if grep -q '\[ \$\$? == 0 \]' "$PY_MAK" 2>/dev/null; then
        log "修复 dash 兼容性 ([ == ] -> [ = ])..."
        sed -i 's/\[ \$\$? == 0 \]/[ $$? = 0 ]/' "$PY_MAK"
    fi
    ok "Python 构建系统已修复"

    # 4.6 修复 invoke_without_jobserver.py (iteritems -> items)
    local INVOKE_PY="build/make/invoke_without_jobserver.py"
    if grep -q '\.iteritems()' "$INVOKE_PY" 2>/dev/null; then
        log "修复 invoke_without_jobserver.py (iteritems -> items)..."
        sed -i 's/\.iteritems()/.items()/g' "$INVOKE_PY"
    fi

    # 4.7 修复构建系统 Python 脚本 (print 语句 -> print())
    log "修复构建系统 Python 脚本..."
    for pyfile in $(find build/make -name '*.py' -type f 2>/dev/null); do
        if grep -qE '^\s*print\s+[^({]' "$pyfile" 2>/dev/null; then
            sed -i -E "s/^([[:space:]]*)print[[:space:]]+(.*)$/\1print(\2)/" "$pyfile" 2>/dev/null || true
        fi
    done

    # 4.8 关键修复：无条件启用 --start-group/--end-group
    local FOOTER_MAK="build/make/common_footer_config.mak"
    if grep -q 'ifeq ($(useHavok),1)' "$FOOTER_MAK" 2>/dev/null; then
        log "启用 --start-group/--end-group (common_footer_config.mak)..."
        sed -i 's/^ifeq ($(useHavok),1)$/ifeq (1,1)/' "$FOOTER_MAK"
        ok "--start-group/--end-group 已无条件启用"
    else
        log "--start-group/--end-group 已修复，跳过"
    fi

    # 4.9 修复 cURL configure CFLAGS (third_party_curl.mak)
    local CURL_MAK="build/make/third_party_curl.mak"
    if ! grep -q 'CFLAGS=' "$CURL_MAK" 2>/dev/null; then
        log "修复 cURL configure CFLAGS..."
        sed -i 's|curlConfigureOpts := \\|curlConfigureOpts := CFLAGS="-Wno-error=implicit-int -Wno-error=int-conversion -Wno-error=implicit-function-declaration -Wno-error=incompatible-pointer-types -Wno-error=discarded-qualifiers" \\|' "$CURL_MAK"
    fi

    # 4.10 修复 zip gzguts.h (如果尚未修复)
    local ZIP_GZGUTS="third_party/zip/gzguts.h"
    if [ -f "$ZIP_GZGUTS" ] && ! grep -q '<unistd.h>' "$ZIP_GZGUTS" 2>/dev/null; then
        log "修复 zip/gzguts.h (添加 unistd.h)..."
        sed -i '/#include <fcntl.h>/a #include <unistd.h>' "$ZIP_GZGUTS"
    fi

    ok "所有服务器构建补丁已应用"
}

# =============================================================================
# Phase 5: 服务器构建
# =============================================================================
phase5_build() {
    section "Phase 5: 服务器构建"

    if [ "$PATCHES_ONLY" -eq 1 ]; then
        log "仅应用补丁模式 (--patches-only)，跳过构建"
        return 0
    fi

    cd "$BW_ROOT"
    log "开始构建服务器 (make -j$JOBS bw-binaries)..."
    log "构建日志: $LOG_DIR/server_build.log"

    BW_HOST_PLATFORM=el7 make -j"$JOBS" bw-binaries 2>&1 | tee "$LOG_DIR/server_build.log" | tail -5

    # 检查构建错误
    if grep -q '^make:.*Error' "$LOG_DIR/server_build.log" 2>/dev/null; then
        err "构建有错误！"
        grep '^make:.*Error' "$LOG_DIR/server_build.log"
        echo ""
        err "未定义引用汇总:"
        grep "undefined reference" "$LOG_DIR/server_build.log" | sort -u | head -20
        die "构建失败"
    fi

    ok "服务器构建完成"
}

# =============================================================================
# Phase 6: 验证
# =============================================================================
phase6_verify() {
    section "Phase 6: 验证构建产物"

    if [ ! -d "$OUTPUT_DIR" ]; then
        die "输出目录不存在: $OUTPUT_DIR"
    fi

    echo ""
    echo "构建产物列表:"
    echo "-------------------------------------------"

    local count=0
    local total_size=0

    # 列出所有可执行文件
    while IFS=$'\t' read -r size path; do
        if [ -n "$path" ] && [ -f "$path" ]; then
            local size_mb=$((size / 1048576))
            printf "  %-30s %4dM  %s\n" "$(basename "$path")" "$size_mb" "$path"
            count=$((count + 1))
            total_size=$((total_size + size))
        fi
    done < <(find "$OUTPUT_DIR" -type f -executable -printf '%s\t%p\n' 2>/dev/null | sort -k2)

    # 列出 .so 文件
    while IFS=$'\t' read -r size path; do
        if [ -n "$path" ] && [ -f "$path" ]; then
            local size_mb=$((size / 1048576))
            printf "  %-30s %4dM  %s\n" "$(basename "$path")" "$size_mb" "$path"
            count=$((count + 1))
            total_size=$((total_size + size))
        fi
    done < <(find "$OUTPUT_DIR" -name "*.so" -printf '%s\t%p\n' 2>/dev/null | sort -k2)

    echo "-------------------------------------------"
    echo "总计: $count 个文件, $((total_size / 1048576))M"

    # 检查关键二进制
    echo ""
    echo "关键二进制检查:"
    local REQUIRED_BINS="baseapp baseappmgr cellapp cellappmgr dbapp dbappmgr loginapp reviver serviceapp bots message_logger process_defs res_packer bwmachined2"
    local missing=0
    for bin in $REQUIRED_BINS; do
        local found=""
        found=$(find "$OUTPUT_DIR" -name "$bin" -type f -executable 2>/dev/null | head -1)
        if [ -n "$found" ]; then
            echo "  [OK] $bin"
        else
            echo "  [MISSING] $bin"
            missing=$((missing + 1))
        fi
    done

    if [ "$missing" -gt 0 ]; then
        warn "有 $missing 个关键二进制缺失"
    else
        ok "所有关键二进制已构建"
    fi
}

# =============================================================================
# 主流程
# =============================================================================
main() {
    echo ""
    echo "================================================================"
    echo "  BigWorld Engine 14.4.1 - WSL 服务器一键构建"
    echo "  时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  源码: $SRC_WIN_DIR"
    echo "  构建: $BUILD_ROOT"
    echo "  输出: $OUTPUT_DIR"
    echo "  并行: $JOBS jobs"
    echo "================================================================"

    local start_time=$(date +%s)

    phase1_environment
    phase2_source

    if [ "$PATCHES_ONLY" -eq 0 ]; then
        build_python27
        build_mongodb
        # OpenSSL 和 cURL 由 BigWorld 构建系统自动构建 (make bw-binaries)
    else
        log "跳过第三方库构建 (--patches-only)"
    fi

    phase4_patches
    phase5_build

    if [ "$PATCHES_ONLY" -eq 0 ]; then
        phase6_verify
    fi

    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))
    local mins=$((elapsed / 60))
    local secs=$((elapsed % 60))

    echo ""
    echo "================================================================"
    ok "构建完成！耗时 ${mins}m${secs}s"
    echo "  输出目录: $OUTPUT_DIR"
    echo "  构建日志: $LOG_DIR/"
    echo "  构建文档: $SRC_WIN_DIR/BUILD_DOCUMENTATION.md"
    echo "================================================================"
}

main "$@"
