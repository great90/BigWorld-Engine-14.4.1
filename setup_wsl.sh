#!/bin/bash
# Setup script for BigWorld build environment on WSL Debian
# This script creates the necessary files and symlinks to make the BigWorld
# build system think it's running on CentOS 7.

set -e

# Create /etc/redhat-release to mimic CentOS 7
echo "CentOS Linux release 7.9.2009 (Core)" | sudo tee /etc/redhat-release > /dev/null
echo "[OK] Created /etc/redhat-release"
cat /etc/redhat-release

# Create mysql_config symlink (BigWorld expects /usr/lib64/mysql/mysql_config)
sudo mkdir -p /usr/lib64/mysql
sudo ln -sf /usr/bin/mariadb_config /usr/lib64/mysql/mysql_config
echo "[OK] Created mysql_config symlink"
ls -la /usr/lib64/mysql/mysql_config
/usr/lib64/mysql/mysql_config --version

# Test platform detection
echo "--- Testing platform detection ---"
cd /mnt/j/Work/BigWorld-Engine-14.4.1
python3 programming/bigworld/build/make/platform_info.py 2>&1 || echo "platform_info.py failed (expected - uses Python 2 syntax)"

echo "[OK] Setup complete"
