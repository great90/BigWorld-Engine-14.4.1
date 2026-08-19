# BigWorld 14.4.1 运行时配置与操作流程

## 目录结构

```
runtime_config/
├── README.md                    # 本文档
│
│   ── 核心运行时脚本 ──
├── start_cluster.sh             # 启动服务器集群（8进程）
├── full_connect.ps1             # 客户端完整连接流程
├── take_screenshot.ps1          # 截图工具
├── cleanup_db.py                # 数据库清理工具
├── check_cluster.sh             # 集群状态检查
│
│   ── 构建/部署脚本（用于重新部署环境）──
├── switch_to_fantasydemo.sh     # 切换服务器到 fantasydemo 资源
├── fix_fantasydemo_deps.sh      # 修复 fantasydemo 依赖
├── create_twisted_stub.sh       # 创建 twisted 存根模块
├── copy_missing_so.sh           # 复制系统 Python 的 C 扩展
├── copy_python_libs.sh          # 复制 Python 标准库
├── create_resources_xml.sh      # 创建 resources.xml
├── crash_handler.c              # SIGSEGV 崩溃调试工具
│
│   ── 配置文件 ──
├── development_defaults.xml     # 服务器配置（已含所有修复）
├── bwmachined.conf              # bwmachined 配置参考
└── dot.bwmachined.conf          # .bwmachined.conf 模板
```

---

## 一、服务器集群启动流程

### 前置条件
- WSL Debian 已启动
- bwmachined2 已在运行（PID 可通过 `pgrep -x bwmachined2` 确认）
- `~/.bwmachined.conf` 已正确配置：
  ```
  great;/home/great/bw-build/game/res/fantasydemo:/home/great/bw-build/game/res/bigworld
  ```

### 启动命令
```bash
wsl -d Debian -- bash -c "cd /home/great/bw-build/game/res/fantasydemo && bash /mnt/j/Work/BigWorld-Engine-14.4.1/runtime_config/start_cluster.sh"
```

### 启动顺序（脚本自动处理）
1. **bwmachined2** — 机器管理守护进程（需已运行）
2. **cellappmgr** — CellApp 管理器
3. **baseappmgr** — BaseApp 管理器
4. **dbappmgr** — DBApp 管理器
5. **dbapp** — 数据库应用（XML 数据库）
6. **cellapp** — Cell 应用（游戏空间逻辑）
7. **baseapp** — Base 应用（玩家实体逻辑）
8. **loginapp** — 登录应用（客户端入口）

### 验证
```bash
wsl -d Debian -- bash -c "pgrep -la 'bwmachined2|cellappmgr|baseappmgr|dbappmgr|cellapp|baseapp|dbapp|loginapp' | sort"
```
预期输出 8 个进程。也可使用 `check_cluster.sh` 查看详细日志：
```bash
wsl -d Debian -- bash /mnt/j/Work/BigWorld-Engine-14.4.1/runtime_config/check_cluster.sh
```

### 日志文件
所有服务器日志位于 `/tmp/`：
- `/tmp/bwmachined2.log`
- `/tmp/cellappmgr.log`、`/tmp/baseappmgr.log`、`/tmp/dbappmgr.log`
- `/tmp/cellapp.log`、`/tmp/baseapp.log`、`/tmp/dbapp.log`、`/tmp/loginapp.log`

---

## 二、客户端启动与连接流程

### 前置条件
- 服务器集群已启动（8 进程运行中）
- `development_defaults.xml` 已部署到服务器资源目录
- RSA 密钥对已生成：
  - 客户端：`game/bin/client/win64/res/loginapp.pubkey`
  - 服务器：`server/loginapp.privkey`
- `scripts_config.xml` 中 host 配置为服务器地址（如 `192.168.2.210:20013`）

### 自动连接（推荐）
```powershell
powershell -File "j:\Work\BigWorld-Engine-14.4.1\runtime_config\full_connect.ps1"
```
该脚本自动完成：
1. 启动 `bwclient_h.exe -noConversion`
2. 连接到标准服务器（LoginApp:20013）
3. 确认用户名
4. 选择 Fantasy Realm
5. 创建角色（名称 "hero"）
6. 选择角色进入游戏世界
7. 每步截图保存到 `game/bin/client/win64/fc_step*.png`

### 手动启动
```powershell
cd j:\Work\BigWorld-Engine-14.4.1\game\bin\client\win64
.\bwclient_h.exe -noConversion
```

### 截图工具
```powershell
powershell -File "j:\Work\BigWorld-Engine-14.4.1\runtime_config\take_screenshot.ps1"
```
截图保存到 `game/bin/client/win64/client_screen.png`。

---

## 三、数据库清理流程

当需要清空角色数据时（如角色创建失败导致残留数据）：

```bash
wsl -d Debian -- bash -c "python2 /mnt/j/Work/BigWorld-Engine-14.4.1/runtime_config/cleanup_db.py /home/great/bw-build/game/res/fantasydemo/scripts/db.xml"
```

**注意**：清理数据库后必须重启 dbapp（或整个集群），因为 dbapp 会将数据库加载到内存中。仅修改文件不会清除内存中的旧数据。

---

## 四、环境重新部署流程

### 场景：全新 WSL 环境，需要重新部署服务器

按以下顺序执行脚本：

#### 步骤 1：切换到 fantasydemo 资源
```bash
wsl -d Debian -- bash /mnt/j/Work/BigWorld-Engine-14.4.1/runtime_config/switch_to_fantasydemo.sh
```
复制 Python Lib、zope 存根、lib-dynload-el7、development_defaults.xml、loginapp.privkey 到 fantasydemo 资源目录，并创建 resources.xml。

#### 步骤 2：修复 fantasydemo 依赖
```bash
wsl -d Debian -- bash /mnt/j/Work/BigWorld-Engine-14.4.1/runtime_config/fix_fantasydemo_deps.sh
```
创建 zope.interface 存根，验证 twisted 存根、lib-dynload-el7、UserDataObjectRef.py。

#### 步骤 3：复制缺失的 C 扩展（如步骤1未覆盖）
```bash
wsl -d Debian -- bash /mnt/j/Work/BigWorld-Engine-14.4.1/runtime_config/copy_missing_so.sh
```

#### 步骤 4：部署服务器配置
```bash
# 复制 development_defaults.xml 到服务器资源目录
wsl -d Debian -- bash -c "cp /mnt/j/Work/BigWorld-Engine-14.4.1/runtime_config/development_defaults.xml /home/great/bw-build/game/res/fantasydemo/server/"

# 配置 .bwmachined.conf
wsl -d Debian -- bash -c "cp /mnt/j/Work/BigWorld-Engine-14.4.1/runtime_config/dot.bwmachined.conf ~/.bwmachined.conf"
```

#### 步骤 5：启动集群
```bash
wsl -d Debian -- bash -c "cd /home/great/bw-build/game/res/fantasydemo && bash /mnt/j/Work/BigWorld-Engine-14.4.1/runtime_config/start_cluster.sh"
```

### 场景：单独创建 twisted 存根
```bash
wsl -d Debian -- bash /mnt/j/Work/BigWorld-Engine-14.4.1/runtime_config/create_twisted_stub.sh
```

### 场景：崩溃调试（GDB 不可用时）
```bash
# 编译 crash_handler.so
wsl -d Debian -- bash -c "gcc -shared -fPIC -o /tmp/crash_handler.so /mnt/j/Work/BigWorld-Engine-14.4.1/runtime_config/crash_handler.c -ldl"

# 使用 LD_PRELOAD 运行崩溃的服务器进程
wsl -d Debian -- bash -c "LD_PRELOAD=/tmp/crash_handler.so /home/great/bw-build/game/bin/server/el7/cellapp"
```

---

## 五、关键配置说明

### development_defaults.xml 重要配置项

| 配置项 | 值 | 说明 |
|--------|-----|------|
| `<internalInterface>` | `127.0.0.1` | 单机部署必须设置，否则 baseappmgr 断言失败 |
| `<allowLogin>` | `true` | loginApp 默认 false，必须开启否则登录被拒（status 82） |
| `<desiredServiceApps>` | `0` | 无 service app 时必须设为 0，否则服务器不就绪（status 74） |
| `<allowUnencryptedLogins>` | `true` | 开发环境允许非加密登录 |
| `<aoiUpdateSchemes>` | 空 | 避免 cellapp 空指针崩溃 |
| `<ghostDistance>` | `500.0` | 必须 >= maxAoIRadius（默认 500） |
| `<db><type>` | `xml` | 使用 XML 数据库，避免 MySQL 依赖 |

### 登录流程
```
客户端 → LoginApp:20013 (UDP) → 返回 BaseApp 地址
客户端 → BaseApp:动态端口 (UDP) → LOGGED_ON → createBasePlayer → createCellPlayer → 实体创建
```

### LogOnStatus 错误码（定义在 lib/connection/log_on_status.hpp）
- 67 = NO_SUCH_USER
- 68 = INVALID_PASSWORD
- 74 = SERVER_NOT_READY（desiredServiceApps 未满足）
- 82 = LOGINS_NOT_ALLOWED（allowLogin 未开启）

---

## 六、脚本依赖关系

```
switch_to_fantasydemo.sh
  ├── create_twisted_stub.sh（通过 fix_fantasydemo_deps.sh 调用）
  ├── copy_missing_so.sh（手动执行）
  └── copy_python_libs.sh（手动执行）

start_cluster.sh（独立，依赖 ~/.bwmachined.conf 和 development_defaults.xml）

full_connect.ps1（独立，依赖 bwclient_h.exe 和服务器运行）

cleanup_db.py（独立，操作 db.xml 文件）

check_cluster.sh（独立，只读检查）

crash_handler.c（独立，需 gcc 编译后 LD_PRELOAD 使用）
```

---

## 七、常见问题排查

### 服务器进程未全部启动
```bash
wsl -d Debian -- bash /mnt/j/Work/BigWorld-Engine-14.4.1/runtime_config/check_cluster.sh
```
查看各进程日志的尾部输出，定位启动失败原因。

### 登录失败
1. 检查 loginapp 日志：`wsl -d Debian -- tail -30 /tmp/loginapp.log`
2. 检查 baseapp 日志：`wsl -d Debian -- tail -30 /tmp/baseapp.log`
3. 检查 dbapp 日志：`wsl -d Debian -- tail -30 /tmp/dbapp.log`
4. 确认 `allowLogin=true`、`desiredServiceApps=0`

### 角色创建失败（"already exists"）
1. 停止服务器集群
2. 运行 `cleanup_db.py` 清理 db.xml
3. 重启服务器集群（必须重启，清除内存缓存）
4. 重新连接

### 客户端 .def 文件 digest 不匹配
- 服务器和客户端必须使用相同的 .def 文件集
- fantasydemo 资源（42个.def文件）digest = `BD40F9F72CD5EA96770A69D740A8B643`
- dbapp.cpp 中有安全网：digest 不匹配时 WARNING 但不拒绝登录

### cellapp/baseapp 启动时 ResMgr.openSection 不可用
- cellapp.cpp 和 baseapp.cpp 中的 `s_moduleTokens` 需要 `__attribute__((used))` 属性
- 防止编译器优化掉该变量导致 ResMgr 无法注册
