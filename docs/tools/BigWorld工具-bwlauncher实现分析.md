# BigWorld 工具 bwlauncher 实现深度分析

> 本文档详细分析 BigWorld Engine 14.4.1 中 `bwlauncher` 工具的完整实现。`bwlauncher` 是一个 Windows 平台下的 `bigworld://` URL 协议处理器,负责将浏览器中的 URL 链接转换为本地游戏客户端的启动动作,通过注册表注册协议、本地 `.db` 文件检索游戏可执行路径、`ShellExecuteEx` 启动游戏进程,并内嵌 TinyXML 解析游戏数据库文件。本文档涵盖入口点、协议注册、权限提升、URL 解析、LaunchDB 加载与启动流程的全部细节。

---

## 目录

- [一、概述与定位](#一概述与定位)
- [二、整体架构](#二整体架构)
- [三、目录结构](#三目录结构)
- [四、入口点 wWinMain 启动流程](#四入口点-wwinmain-启动流程)
- [五、URL 协议注册机制](#五url-协议注册机制)
- [六、权限提升 runas 流程](#六权限提升-runas-流程)
- [七、processProtocolCommand 命令处理](#七processprotocolcommand-命令处理)
- [八、LaunchDB 游戏数据库](#八launchdb-游戏数据库)
- [九、utils 工具函数集](#九utils-工具函数集)
- [十、内嵌 TinyXML 库](#十内嵌-tinyxml-库)
- [十一、配置项与命令行参数](#十一配置项与命令行参数)
- [十二、与其他模块的依赖关系](#十二与其他模块的依赖关系)
- [十三、关键代码片段(带行号)](#十三关键代码片段带行号)
- [十四、设计亮点与注意事项](#十四设计亮点与注意事项)
- [附录 A:常见问题澄清](#附录-a常见问题澄清)

---

## 一、概述与定位

### 1.1 工具定位

`bwlauncher` 是 BigWorld Technology SDK 提供的一个 **轻量级 Windows URL 协议处理器**。它的核心使命是:

1. 在系统注册表中注册 `bigworld://` 自定义协议,使浏览器在用户点击 `bigworld://` 开头的链接时自动唤起 `bwlauncher.exe`;
2. 解析 URL 中的命令与参数(如 `launch`、`browse`);
3. 通过本地的 `.db` 文件(TinyXML 格式)查找游戏 ID 对应的可执行文件路径;
4. 使用 `ShellExecuteEx` 启动游戏客户端,并通过命令行参数传递用户名与密码。

该工具本质上是一个 **无窗口的 Windows 应用程序**(GUI 子系统但不可见),通过命令行参数区分"安装"、"卸载"、"注册游戏"、"协议处理"四种工作模式。

### 1.2 核心特性

| 特性 | 实现方式 | 说明 |
|------|---------|------|
| URL 协议 | Windows Registry `HKCR\bigworld` | 浏览器点击链接时由系统调用 |
| 游戏数据库 | 内嵌 TinyXML 解析 `.db` 文件 | 每个 `.db` 文件对应一个游戏 |
| 进程启动 | `ShellExecuteEx` + `SEE_MASK_NOCLOSEPROCESS` | 异步启动游戏 |
| 权限提升 | `runas` 动词 | 用于"为所有用户安装"场景 |
| 安装位置 | `CSIDL_COMMON_APPDATA` 或 `CSIDL_LOCAL_APPDATA` | 区分 AllUsers/CurrentUser |
| Unicode 支持 | `_UNICODE` 宏 + `tstring` = `wstring` | 全字符串使用宽字符 |
| 自删除 | 批处理文件循环 `del` | 卸载时删除自身 |

### 1.3 版本与规模

- **版本号**: `BWLAUNCHER_VERSION = "100"`(见 `bwlauncher_config.hpp` L6)
- **总代码规模**: 约 1300 行 C++ 代码(不含 TinyXML 内嵌库)
- **可执行文件名**: `bwlauncher.exe`(见 `bwlauncher_config.hpp` L7)
- **支持的 OS**: 仅 Windows(Win32 API 全平台依赖)

---

## 二、整体架构

### 2.1 模块组成图

```
┌────────────────────────────────────────────────────────────────────┐
│                      bwlauncher.exe (无窗口)                       │
│                                                                    │
│   ┌──────────────────────┐    ┌──────────────────────────────┐     │
│   │   wWinMain (入口)    │───►│   processProtocolCommand     │     │
│   │   bwlauncher.cpp L37 │    │   bwlauncher.cpp L344        │     │
│   └──────────────────────┘    └──────────┬───────────────────┘     │
│            │                              │                         │
│            ├── /installAll                ├── splitUrl (URL 解析)  │
│            ├── /installCurrent            │                         │
│            ├── /registerGame              ├── LaunchDB.launch()     │
│            ├── /uninstall                 │   (ShellExecuteEx)      │
│            └── (无参数→协议处理)          └── launchGameLibrary()   │
│                                                (打开浏览器)        │
│                                                                  │
│   ┌──────────────────────┐    ┌──────────────────────────────┐   │
│   │   installSelf        │    │   LaunchDB                   │   │
│   │   (注册表+文件复制)  │    │   launch_db.cpp              │   │
│   └──────────────────────┘    │   - loadPath / loadFile      │   │
│            ▲                  │   - launch (ShellExecuteEx)  │   │
│            │                  └──────────────────────────────┘   │
│   ┌──────────────────────┐                ▲                      │
│   │   utils.cpp          │                │                      │
│   │   - restartWithPriv. │                │                      │
│   │     (runas 提升权限) │                │                      │
│   │   - writeToRegistry  │────────────────┘                      │
│   │   - splitCommandArgs │                                       │
│   │   - splitUrl         │                                       │
│   └──────────────────────┘                                       │
└────────────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌────────────────────────────────────────────────────────────────────┐
│                      Windows 系统                                  │
│   ┌─────────────────────┐    ┌─────────────────────────────────┐  │
│   │  Registry           │    │  File System                    │  │
│   │  HKCR\bigworld      │    │  %CSIDL_COMMON_APPDATA%\BigWorld│  │
│   │   - URL Protocol    │    │   ├── bwlauncher.exe            │  │
│   │   - Launcher Version│    │   ├── game1.db                  │  │
│   │   - Shell\Open\Cmd  │    │   └── game2.db                  │  │
│   └─────────────────────┘    └─────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────┘
```

### 2.2 工作流程图

```
用户点击 bigworld://launch/gameID/user/pass 链接
                │
                ▼
        Windows Shell 查注册表
                │
                ▼
       启动 bwlauncher.exe "%1"
                │
                ▼
        wWinMain (L37) 解析参数
                │
        ┌───────┴───────────────┐
        │                       │
   首次运行?              已安装?
        │                       │
        ▼                       ▼
   询问安装              processProtocolCommand
   /installAll                  │
        │                       ▼
        ▼                splitUrl 分离 cmd/remainder
  restartWithPrivileges         │
  (runas 提权)                  ▼
        │                ┌──────┴──────┐
        ▼                │             │
   installSelf           ▼             ▼
   (注册表注册)        launch       browse
                       │             │
                       ▼             ▼
                LaunchDB.launch   launchGameLibrary
                (ShellExecuteEx)  (打开浏览器)
                       │
                       ▼
                  游戏客户端启动
                  (传入 user/pass)
```

---

## 三、目录结构

`bwlauncher` 工具源码位于 `programming/bigworld/tools/bwlauncher/` 目录,完整文件清单如下:

```
programming/bigworld/tools/bwlauncher/
├── bwlauncher.cpp           # 主程序入口与协议命令处理 (404 行)
├── bwlauncher.rc            # Windows 资源文件(图标、版本信息)
├── bwlauncher_config.cpp    # 全局常量定义(BW_GAMES_URL 等)
├── bwlauncher_config.hpp    # 版本号、EXE 名称、卸载 BAT 名常量
├── launch_db.cpp            # LaunchDB 类实现:加载与启动游戏 (141 行)
├── launch_db.hpp            # LaunchDB 类声明
├── utils.cpp                # 工具函数:注册表、URL 解析、权限提升 (629 行)
├── utils.hpp                # 工具函数声明与异常类
├── pch.hpp                  # 预编译头(Windows API + tstring 定义)
├── pch.cpp                  # 预编译头源文件
├── tinyxml.h                # 内嵌 TinyXML 库头文件
├── tinyxml.cpp              # 内嵌 TinyXML 实现
├── tinystr.h                # TinyXML 字符串辅助
├── tinystr.cpp              # TinyXML 字符串辅助实现
├── tinyxmlerror.cpp         # TinyXML 错误码表
├── tinyxmlparser.cpp        # TinyXML 解析器
├── CMakeLists.txt           # CMake 构建脚本
└── res/
    └── bwlauncher.ico       # 应用图标
```

### 3.1 文件规模一览

| 文件 | 行数 | 职责 |
|------|------|------|
| `bwlauncher.cpp` | 404 | 入口、安装、卸载、协议命令分发 |
| `utils.cpp` | 629 | 注册表、URL 解析、Shell 调用、字符串处理 |
| `launch_db.cpp` | 141 | `.db` 文件加载与游戏启动 |
| `bwlauncher_config.cpp` | 6 | URL 常量定义 |
| `bwlauncher_config.hpp` | 12 | 版本与可执行文件名宏 |
| `utils.hpp` | 56 | 工具函数声明 |
| `launch_db.hpp` | 20 | LaunchDB 类声明 |
| `pch.hpp` | 46 | 公共头与 `tstring` 定义 |
| TinyXML 系列 | ~4000 | 内嵌 XML 解析(第三方) |

### 3.2 预编译头 pch.hpp 关键定义

`pch.hpp` 是所有源文件的公共包含,核心定义如下(`pch.hpp` L1-46):

```cpp
#include <windows.h>
#include <cassert>
#include <tchar.h>
#include <strsafe.h>
#include <shlobj.h>

#include "cstdmf/bw_vector.hpp"
#include <string>
#include "cstdmf/bw_map.hpp"
#include <algorithm>

#ifdef _UNICODE
typedef BW::wstring tstring;
typedef std::wifstream tifstream;
#else // _UNICODE
typedef std::string tstring;
typedef std::ifstream tifstream;
#endif // _UNICODE
```

`tstring` 类型别名是整个工程的字符串基础类型,根据 `_UNICODE` 宏切换为宽字符或窄字符。`BW::vector` 和 `BW::map` 来自 BigWorld 的 `cstdmf` 库,是 STL 容器的别名包装,确保 bwlauncher 与引擎其他部分使用一致的容器类型。

---

## 四、入口点 wWinMain 启动流程

### 4.1 wWinMain 函数签名

bwlauncher 使用 GUI 子系统入口 `wWinMain`(`bwlauncher.cpp` L37-164),而非传统控制台 `main`。这是因为:

1. URL 协议处理器需要避免弹出控制台窗口;
2. 安装时需要弹窗交互(`MessageBox`);
3. 通过 `GetCommandLine()` 获取原始命令行以保留 URL 引号。

```cpp
int CALLBACK wWinMain( HINSTANCE hInstance, HINSTANCE hPrevInstance,
                       LPWSTR lpCmdLine, int nShowCmd )
{
    StringVector args;
    splitCommandArgs( GetCommandLine(), args );
    ...
}
```

注意虽然 `wWinMain` 接收 `lpCmdLine`,但实际代码使用 `GetCommandLine()` 重新获取原始命令行(`bwlauncher.cpp` L40)。这是因为 `lpCmdLine` 已经被 Windows 处理过引号,丢失了 URL 中的原始引号信息,而 `splitCommandArgs` 需要原始字符流以正确处理 `\"` 转义。

### 4.2 命令分发逻辑

`wWinMain` 通过 `gotArg` 函数检查命令行参数,按优先级分发到不同的处理分支。完整分发逻辑(`bwlauncher.cpp` L42-161)如下表:

| 命令行参数 | 处理函数 | 说明 |
|-----------|---------|------|
| `/installCurrent` | `installSelf(false)` | 为当前用户安装 |
| `/install` 或 `/installAll` | `installSelf(true)` | 为所有用户安装(需管理员) |
| `/uninstallCurrent` | `uninstall(false)` | 卸载(代码注释掉) |
| `/uninstall` 或 `/uninstallAll` | `uninstall(true)` | 卸载(代码注释掉) |
| `/registerGame gameID exePath` | `registerGame()` | 注册游戏到本地数据库 |
| 无安装且未安装 | `restartWithPrivileges("/installAll /runAfterInstall")` | 询问用户安装 |
| 已安装,无上述参数 | `processProtocolCommand(args)` | 处理 `bigworld://` URL |

### 4.3 关键分支:权限提升重试

当 `installSelf(true)` 抛出 `UnprivilegedException` 时,`wWinMain` 会捕获并尝试通过 `restartWithPrivileges` 重新以管理员权限启动自身(`bwlauncher.cpp` L62-73):

```cpp
catch(const UnprivilegedException&)
{
    if (!gotArg(_T("/restartedWithPrivileges"), args))
    {
        restartWithPrivileges( _T("/installAll") );
    }
    else
    {
        DEBUG_MSG( _T("Failed to install for all users, even after raising privileges.\n") );
        displayMessage( _T("Error installing BigWorld Launcher, could not gain required privileges."),
                        MB_ICONERROR );
    }
}
```

这里通过 `/restartedWithPrivileges` 标志位避免无限循环:若已经提权尝试过但仍失败,直接报错而不再提权重试。这是一种常见的 UAC 重试模式。

### 4.4 默认分支:协议处理

当无任何命令行参数(或仅有 URL 参数)时,进入协议处理分支(`bwlauncher.cpp` L147-161):

```cpp
else if (!checkInstallation(true) && !checkInstallation(false))
{
    int ret = displayMessage(
        _T("Do you want to install the BigWorld launcher?"),
        MB_ICONQUESTION|MB_YESNO );

    if (ret == IDYES)
    {
        restartWithPrivileges( _T("/installAll /runAfterInstall") );
    }
}
else
{
    processProtocolCommand( args );
}
```

逻辑是:先检查是否已安装(AllUsers 或 CurrentUser 任一),若未安装则弹窗询问;若已安装则进入 `processProtocolCommand`。

---

## 五、URL 协议注册机制

### 5.1 注册表结构

`bigworld://` 协议通过 Windows 注册表注册。`installSelf` 函数(`bwlauncher.cpp` L176-221)将以下键值写入注册表:

| 注册表路径 | 值名 | 值数据 | 含义 |
|-----------|------|--------|------|
| `Software\Classes\bigworld` | (默认) | `""` | 协议根键 |
| `Software\Classes\bigworld` | `Launcher Version` | `"100"` | 启动器版本 |
| `Software\Classes\bigworld` | `URL Protocol` | `""` | 标识为 URL 协议(必须存在) |
| `Software\Classes\bigworld\Shell\Open\Command` | (默认) | `"<exePath>" "%1"` | 点击链接时执行的命令 |

注册表根键根据 `allUsers` 参数选择(`bwlauncher.cpp` L208):

```cpp
HKEY baseKey = allUsers ? HKEY_LOCAL_MACHINE : HKEY_CURRENT_USER;
```

- `allUsers = true`:写 `HKEY_LOCAL_MACHINE`(需管理员权限,所有用户共享)
- `allUsers = false`:写 `HKEY_CURRENT_USER`(无需管理员,仅当前用户)

### 5.2 协议命令字符串

`getProtocolShellCmd`(`utils.cpp` L317-320)组装注册表中的命令字符串:

```cpp
tstring getProtocolShellCmd( bool allUsers )
{
    return _T("\"") + getLauncherInstalledExePath( allUsers )
         + _T("\" \"%1\"");
}
```

最终写入注册表的字符串形如:
```
"C:\ProgramData\BigWorld\bwlauncher.exe" "%1"
```

其中 `%1` 会被 Windows 替换为用户点击的 URL(如 `bigworld://launch/gameID/user/pass`)。注意整个 URL 作为单一参数传入(带引号),因此 `bwlauncher` 在 `argv[1]` 收到完整 URL。

### 5.3 安装位置

`getLauncherInstalledPath`(`utils.cpp` L294-300)确定安装目录:

```cpp
tstring getLauncherInstalledPath( bool allUsers )
{
    int flags = allUsers ? CSIDL_COMMON_APPDATA : CSIDL_LOCAL_APPDATA;
    tstring targetDir = getWindowsPath( flags|CSIDL_FLAG_CREATE );
    targetDir += _T("\\BigWorld");
    return targetDir;
}
```

| allUsers | CSIDL 常量 | 典型路径 |
|----------|-----------|---------|
| `true` | `CSIDL_COMMON_APPDATA` | `C:\ProgramData\BigWorld\` |
| `false` | `CSIDL_LOCAL_APPDATA` | `C:\Users\<user>\AppData\Local\BigWorld\` |

`CSIDL_FLAG_CREATE` 标志确保目录在不存在时自动创建。

### 5.4 安装自复制

`installSelf` 在写入注册表前,先将自己复制到目标位置(`bwlauncher.cpp` L196-205):

```cpp
if (!CopyFile( getAppFullPath().c_str(), fullTargetPath.c_str(), FALSE ))
{
    if (GetLastError() == ERROR_ACCESS_DENIED)
    {
        throw UnprivilegedException();
    }
    DEBUG_MSG( _T("Error copying executable to target location.\n") );
    return false;
}
```

`CopyFile` 第三参数 `FALSE` 表示**覆盖已存在的目标文件**(每次安装都更新到最新版本)。若失败原因是 `ERROR_ACCESS_DENIED`,抛出 `UnprivilegedException` 触发 UAC 提权重试。

### 5.5 安装校验

`checkInstallation`(`bwlauncher.cpp` L227-243)用于判断是否已正确安装,校验四个条件**全部满足**:

1. 注册表 `Software\Classes\bigworld` 默认值存在;
2. `Launcher Version` 值等于当前版本号 `"100"`;
3. `URL Protocol` 值存在;
4. `Shell\Open\Command` 默认值等于当前协议命令字符串;
5. 安装目录下的 `bwlauncher.exe` 文件存在。

注意条件 2 使用版本号比对:若旧版本安装,新版本的 `checkInstallation` 会返回 `false`,从而触发重新安装流程。这是一种简单的版本升级机制。

---

## 六、权限提升 runas 流程

### 6.1 restartWithPrivileges 实现

`restartWithPrivileges`(`utils.cpp` L334-351)使用 `ShellExecuteEx` 配合 `runas` 动词触发 UAC 提示:

```cpp
void restartWithPrivileges( const tstring& sw )
{
    SHELLEXECUTEINFO sei = { sizeof( sei ) };

    tstring fullPath = getAppFullPath();
    tstring fullParams = sw + _T( " /restartedWithPrivileges" );

    sei.fMask = SEE_MASK_NOCLOSEPROCESS;
    sei.nShow = SW_HIDE;

    sei.lpFile = fullPath.c_str();
    sei.lpVerb = _T( "runas" );

    sei.lpParameters = fullParams.c_str();

    DEBUG_MSG( _T("Restarting with elevated privileges.\n") );
    ShellExecuteEx( &sei );
}
```

关键点:

| 字段 | 值 | 含义 |
|------|-----|------|
| `sei.lpVerb` | `"runas"` | 触发 UAC 提示,请求管理员权限 |
| `sei.nShow` | `SW_HIDE` | 新进程隐藏窗口(避免双窗口) |
| `sei.lpFile` | `getAppFullPath()` | 当前 bwlauncher 自身路径 |
| `sei.lpParameters` | `sw + " /restartedWithPrivileges"` | 附加提权标志位 |
| `sei.fMask` | `SEE_MASK_NOCLOSEPROCESS` | 保留进程句柄(实际未使用) |

`/restartedWithPrivileges` 参数是新进程的"已经提权过"标志,用于避免 `wWinMain` 中再次调用 `restartWithPrivileges` 形成无限循环(参见 4.3 节)。

### 6.2 UnprivilegedException 异常机制

`UnprivilegedException`(`utils.hpp` L12-14)是一个简单的 `std::exception` 子类,无任何附加信息:

```cpp
class UnprivilegedException : std::exception
{
};
```

它在以下场景被抛出:

1. `writeToRegistry`:注册表写入返回 `ERROR_ACCESS_DENIED`(`utils.cpp` L406-409, L419-422);
2. `RegDelnodeRecurse`:删除注册表键返回 `ERROR_ACCESS_DENIED`(`utils.cpp` L490-493, L552-555);
3. `installSelf`:`CopyFile` 返回 `ERROR_ACCESS_DENIED`(`bwlauncher.cpp` L199-202);
4. `registerGame`:`_wfopen_s` 打开 `.db` 文件失败(`bwlauncher.cpp` L327-330)。

这种"抛异常→外层捕获→提权重试"的模式是 Windows 权限管理的常见做法。

### 6.3 私有 vs 公共安装的选择

| 场景 | allUsers 选择 | 是否需要提权 |
|------|--------------|-------------|
| `/installCurrent` | `false` | 否,直接安装到 `HKCU` |
| `/installAll` | `true` | 是,需写入 `HKLM` |
| `/registerGame` | 由 `findInstalledLocation` 决定 | 取决于已安装位置 |

`findInstalledLocation`(`bwlauncher.cpp` L248-262)按优先级查找已安装位置:**先 CurrentUser,后 AllUsers**。这保证若用户已私有安装,新注册的游戏写入私有目录,避免触碰公共目录的权限问题。

---

## 七、processProtocolCommand 命令处理

### 7.1 URL 格式

bwlauncher 处理的 URL 格式为:

```
bigworld://<command>/<arg1>/<arg2>/...
```

支持两种命令:

| 命令 | URL 示例 | 行为 |
|------|---------|------|
| `launch` | `bigworld://launch/gameID/username/password` | 启动指定游戏,传入凭证 |
| `browse` | `bigworld://browse/gameID` | 浏览游戏库页面(打开浏览器) |

### 7.2 URL 解析流程

`processProtocolCommand`(`bwlauncher.cpp` L344-404)解析流程:

```cpp
bool processProtocolCommand( const StringVector& args )
{
    LaunchDB db( getAppPath() );

    if (args.size() > 1)
    {
        tstring cmd;
        tstring remainder;

        // 去除 URL 末尾的 /,简化解析
        tstring url = args[ 1 ];
        if (url[ url.size()-1 ] == _T('/'))
        {
            url.resize( url.size()-1 );
        }

        splitUrl( url, cmd, remainder );
        StringVector urlParts = splitString( remainder, _T("/") );
        ...
    }
    else
    {
        // 无参数时打开默认游戏页面
        launchURL( BW_GAMES_URL );
    }
    return false;
}
```

### 7.3 splitUrl 实现

`splitUrl`(`utils.cpp` L248-275)将 URL 拆分为"命令"和"剩余部分":

```cpp
bool splitUrl( const tstring & url, tstring & cmd, tstring & remainder )
{
    size_t start = 0;

    if (_tcsnicmp( url.c_str(), _T( "bigworld:" ), 9 ) == 0)
    {
        start += 9;
    }

    while (url[ start ] == '/')
    {
        ++start;
    }

    size_t end = url.find( '/', start );

    if (end != url.npos)
    {
        cmd = url.substr( start, end - start );
        remainder = url.substr( end + 1 );
    }
    else
    {
        cmd = url.substr( start );
    }

    return true;
}
```

解析步骤:
1. 跳过 `bigworld:` 前缀(9 个字符,大小写不敏感);
2. 跳过所有前导 `/`(处理 `bigworld://` 中的双斜杠);
3. 从当前位置到下一个 `/` 之间为命令(`cmd`);
4. 第一个 `/` 之后的所有内容为 `remainder`。

例如 `bigworld://launch/gameID/user/pass` 解析结果:
- `cmd = "launch"`
- `remainder = "gameID/user/pass"`

### 7.4 launch 命令处理

```cpp
if (cmd == _T( "launch" ))
{
    if (urlParts.size() < 3)
    {
        displayMessage( _T("Invalid arguments provided to launch."),
                        MB_ICONERROR );
    }

    if (!db.launch( urlParts[0], urlParts[1], urlParts[2] ))
    {
        launchGameLibrary( urlParts[0] );
    }
}
```

`launch` 命令需要 3 个参数:`gameID`、`username`、`password`。若 `LaunchDB::launch` 失败(找不到游戏),回退到 `launchGameLibrary` 在浏览器中打开游戏库页面。

注意参数校验仅检查数量,不检查内容(空字符串等)。这是 URL 协议处理器的常见简化,因为浏览器传入的 URL 已经过 URL 编码。

### 7.5 browse 命令处理

```cpp
else if (cmd == _T( "browse" ))
{
    if (urlParts.empty() || urlParts[0].empty())
    {
        displayMessage( _T("No game ID provided."), MB_ICONERROR );
    }
    else
    {
        launchGameLibrary( urlParts[0] );
    }
}
```

`browse` 命令只需 `gameID` 一个参数,通过 `launchGameLibrary`(`utils.cpp` L49-55)打开浏览器:

```cpp
void launchGameLibrary( const tstring& gameID )
{
    StringMap tags;
    tags[ _T("%(GameID)") ] = gameID;
    tstring browseURL = replaceSubStrings( BW_GAMES_LIBRARY_URL, tags );
    launchURL( browseURL );
}
```

`BW_GAMES_LIBRARY_URL` 模板(`bwlauncher_config.cpp` L6)为:
```
http://games.bigworldtech.com:8080/library/%(GameID)/
```

`replaceSubStrings` 将 `%(GameID)` 替换为实际游戏 ID,然后用 `ShellExecute(NULL, "open", url, ...)` 打开默认浏览器。

---

## 八、LaunchDB 游戏数据库

### 8.1 LaunchDB 类定义

`LaunchDB`(`launch_db.hpp` L5-18)是游戏数据库的核心类:

```cpp
class LaunchDB
{
    BW::map<tstring, tstring> applications_;

    void loadFile( tstring path, tstring file );
    void loadPath( tstring path );

public:
    LaunchDB( tstring path );

    bool launch( const tstring& gameID, const tstring& username,
                 const tstring& password ) const;
    size_t size() const;
    std::pair<tstring, tstring> operator[]( size_t index ) const;
};
```

`applications_` 是 `gameID → exePath` 的映射表,在构造函数中从 `.db` 文件加载。

### 8.2 .db 文件格式

每个游戏对应一个 `<gameID>.db` 文件,格式为简单的 XML(`bwlauncher.cpp` L332-336 由 `registerGame` 写入):

```xml
<root>
    <exePath> C:\Games\MyGame\client.exe </exePath>
</root>
```

文件名(去掉 `.db` 扩展)即为 `gameID`。例如 `mygame.db` 对应 `gameID = "mygame"`。

### 8.3 loadFile 加载单个 .db

`loadFile`(`launch_db.cpp` L44-69)使用内嵌的 TinyXML 解析 `.db` 文件:

```cpp
void LaunchDB::loadFile( tstring path, tstring file )
{
    TiXmlDocument doc( toAnsi( file ).c_str() );

    if (!doc.LoadFile( toAnsi(path + file).c_str() ) ||
        !doc.RootElement())
    {
        return;
    }

    TiXmlNode* node = doc.RootElement()->FirstChild( "exePath" );

    if (node && node->FirstChild())
    {
        const char* value = node->FirstChild()->Value();
        tstring exePath( fromAnsi( value ) );

        DWORD attr = GetFileAttributes( exePath.c_str() );

        if (attr != INVALID_FILE_ATTRIBUTES &&
            (attr & FILE_ATTRIBUTE_DIRECTORY) == 0)
        {
            applications_[ file.substr( 0, file.size() - 3 ) ] = exePath;
        }
    }
}
```

关键逻辑:

1. 用 `TiXmlDocument` 加载 `.db` 文件;
2. 查找根元素下的 `exePath` 子节点;
3. 通过 `GetFileAttributes` 校验可执行文件存在且非目录;
4. 校验通过则加入 `applications_` 映射,key 为文件名去掉 `.db`(实际是 `file.substr(0, file.size() - 3)`,注意这里去掉的是 3 个字符 `.db`,但 `.db` 实际是 3 字符,正确)。

注意 `toAnsi` / `fromAnsi`(`launch_db.cpp` L14-39)是简单的字符级宽窄转换,仅适用于 ASCII 字符。对于非 ASCII 路径(如中文路径),这种转换会丢失信息。

### 8.4 loadPath 批量加载

`loadPath`(`launch_db.cpp` L72-93)遍历目录下所有 `.db` 文件:

```cpp
void LaunchDB::loadPath( tstring path )
{
    if (!path.empty() && *path.rbegin() != '\\')
        path += '\\';

    WIN32_FIND_DATA findData;
    HANDLE find = FindFirstFile( ( path + _T( "*.db" ) ).c_str(), &findData );

    if (find != INVALID_HANDLE_VALUE)
    {
        do
        {
            if ((findData.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0)
            {
                loadFile( path, findData.cFileName );
            }
        }
        while (FindNextFile( find, &findData ));

        FindClose( find );
    }
}
```

使用 `FindFirstFile`/`FindNextFile` 枚举 `*.db` 模式的文件,跳过子目录,逐个调用 `loadFile`。`LaunchDB` 构造函数(`launch_db.cpp` L96-99)直接调用 `loadPath`:

```cpp
LaunchDB::LaunchDB( tstring path )
{
    loadPath( path );
}
```

### 8.5 launch 启动游戏

`launch`(`launch_db.cpp` L102-125)是 LaunchDB 的核心方法,通过 `ShellExecuteEx` 启动游戏:

```cpp
bool LaunchDB::launch( const tstring& gameID, const tstring& username,
                       const tstring& password ) const
{
    if (applications_.find( gameID ) != applications_.end())
    {
        tstring exePath = applications_.find( gameID )->second;
        SHELLEXECUTEINFO sei = { sizeof( sei ) };

        sei.fMask = SEE_MASK_NOCLOSEPROCESS;
        sei.nShow = SW_SHOW;

        sei.lpFile = exePath.c_str();

        tstring params = _T( "--username " ) + username
                       + _T( " --password " ) + password;
        sei.lpParameters = params.c_str();

        if (ShellExecuteEx( &sei ) <= 32)
        {
            return true;
        }
    }

    DEBUG_MSG( _T( "Cannot launch application with ID " ) + gameID );
    return false;
}
```

注意一个**反直觉的返回值逻辑**:当 `ShellExecuteEx` 返回值 `<= 32`(表示出错)时,函数返回 `true`;而成功(返回值 > 32)时返回 `false`。这与函数名 `launch` 的语义相反。

调用方 `processProtocolCommand`(`bwlauncher.cpp` L372-375)利用了这一反逻辑:

```cpp
if (!db.launch( urlParts[0], urlParts[1], urlParts[2] ))
{
    launchGameLibrary( urlParts[0] );
}
```

即:**`launch` 返回 `false`(启动成功)时不回退到浏览器**;返回 `true`(启动失败)时打开游戏库页面。这是一个历史遗留的代码风格,文档化时需特别说明。

### 8.6 启动参数传递

游戏客户端通过命令行参数接收凭证:

```
client.exe --username <user> --password <password>
```

`--username` 和 `--password` 是 BigWorld 客户端的标准登录参数。注意密码以明文形式出现在命令行中,可能被其他进程通过 `GetCommandLine` 读取。这是 URL 协议启动模式的安全权衡:便捷性高于绝对安全。

---

## 九、utils 工具函数集

`utils.cpp`(629 行)是 bwlauncher 的工具函数集合,涵盖字符串处理、文件操作、注册表操作、Shell 调用四大类。

### 9.1 字符串处理函数

| 函数 | 行号 | 功能 |
|------|------|------|
| `splitCommandArgs` | L66-160 | 按空白分割命令行,支持引号与转义 |
| `splitString` | L586-609 | 按指定分隔符分割字符串(类似 Python `split`) |
| `replaceSubStrings` | L614-628 | 多重子串替换(用于 URL 模板) |
| `findArg` / `gotArg` | L167-186 | 命令行参数查找(大小写不敏感) |
| `getFilename` / `getBasePath` | L191-212 | 路径分解 |

#### splitCommandArgs 命令行解析

`splitCommandArgs`(`utils.cpp` L66-160)实现 Windows 风格的命令行解析,支持:

- 默认分隔符:空白字符(` \t\r\n`);
- 默认绑定符:双引号 `"`;
- 默认转义符:反斜杠 `\`;
- `\"` 在引号内表示字面引号;
- `\\"` 在引号内表示字面反斜杠 + 结束引号。

```cpp
size_t splitCommandArgs (const tstring& str, StringVector& out,
                         const tstring& delim = _T( " \t\r\n" ),
                         const tstring& bind = _T( "\"" ),
                         wchar_t escape = _T( '\\' ));
```

该函数有两个模式:`bound`(在引号内)与 `unbound`(在引号外)。在 bound 模式下,空白字符不分割;在 unbound 模式下,空白字符分割且空字符串被忽略。

#### splitString 简单分割

`splitString`(`utils.cpp` L586-609)是 `splitCommandArgs` 的简化版,仅按字面分隔符分割,不处理引号:

```cpp
StringVector splitString( const tstring& input, const tstring& delim )
{
    StringVector output;
    size_t pos = 0;
    size_t next = 0;
    while( (next = input.find(delim, pos)) != tstring::npos )
    {
        output.push_back( input.substr(pos, next-pos) );
        pos = next + 1;
    }
    if (pos < input.size())
    {
        output.push_back( input.substr(pos) );
    }
    if (output.empty())
    {
        output.push_back( _T("") );
    }
    return output;
}
```

注意 `pos = next + 1`:这里 `+1` 跳过单字符分隔符。若分隔符是多字符(如 `//`),此实现会出错——但 bwlauncher 中仅用于单字符 `/` 分割 URL,无问题。

### 9.2 文件与路径函数

| 函数 | 行号 | 功能 |
|------|------|------|
| `getAppFullPath` | L218-230 | 获取当前 exe 完整路径(含文件名) |
| `getAppPath` | L236-239 | 获取当前 exe 目录(不含文件名) |
| `getWindowsPath` | L280-289 | 包装 `SHGetFolderPath` |
| `getLauncherInstalledPath` | L294-300 | 安装目录(AllUsers/CurrentUser) |
| `getLauncherInstalledExePath` | L305-311 | 安装后的 exe 完整路径 |
| `fileExists` | L325-328 | 文件存在检查 |

#### getAppFullPath 实现

`getAppFullPath`(`utils.cpp` L218-230)使用 `GetModuleFileName` 获取当前进程的 exe 路径,并通过循环扩容缓冲区应对长路径:

```cpp
tstring getAppFullPath()
{
    BW::vector<TCHAR> path( MAX_PATH );

    while (GetModuleFileName( NULL, &path[0], (DWORD)path.size() ) == path.size())
    {
        path.resize( path.size() * 2 );
    }

    _tcslwr_s( &path[0], path.size() );

    return &path[0];
}
```

`GetModuleFileName` 在缓冲区不足时返回值等于缓冲区大小,因此循环条件 `== path.size()` 检测溢出并扩容(每次翻倍)。最后 `_tcslwr_s` 将路径转为小写,便于后续注册表比对(注册表值在 `checkInstallation` 中区分大小写)。

### 9.3 注册表函数

| 函数 | 行号 | 功能 |
|------|------|------|
| `writeToRegistry` | L399-428 | 写入注册表键值(失败抛 `UnprivilegedException`) |
| `verifyRegistry` | L372-393 | 校验注册表值是否匹配 |
| `getRegistryValue` | L433-454 | 读取注册表值 |
| `RegDelnode` / `RegDelnodeRecurse` | L469-580 | 递归删除注册表树 |

#### writeToRegistry 实现

`writeToRegistry`(`utils.cpp` L399-428)是注册表写入的核心,处理 `ERROR_ACCESS_DENIED` 异常:

```cpp
bool writeToRegistry( HKEY baseKey, LPCTSTR key, LPCTSTR name, LPCTSTR value )
{
    HKEY hkey;
    LONG result = RegCreateKey( baseKey, key, &hkey );

    if (result != ERROR_SUCCESS)
    {
        if (result == ERROR_ACCESS_DENIED)
        {
            throw UnprivilegedException();
        }
        return false;
    }

    result = RegSetValueEx( hkey, name, 0, REG_SZ, (BYTE*)value,
                            ( (DWORD)_tcslen( value ) + 1 ) * sizeof( TCHAR ) );
    RegCloseKey( hkey );

    if (result != ERROR_SUCCESS)
    {
        if (result == ERROR_ACCESS_DENIED)
        {
            throw UnprivilegedException();
        }
        return false;
    }

    return true;
}
```

注意字符串大小计算:`(_tcslen(value) + 1) * sizeof(TCHAR)` 包含终止 null 字符,且按 `TCHAR` 大小(Unicode 下为 2 字节)计算总字节数。

#### RegDelnode 递归删除

`RegDelnode`(`utils.cpp` L573-580)是注册表递归删除的入口,源自 MSDN 示例代码:

```cpp
BOOL RegDelnode (HKEY hKeyRoot, LPTSTR lpSubKey)
{
    TCHAR szDelKey[MAX_PATH*2];
    StringCchCopy (szDelKey, MAX_PATH*2, lpSubKey);
    return RegDelnodeRecurse(hKeyRoot, szDelKey);
}
```

`RegDelnodeRecurse`(`utils.cpp` L469-558)先尝试直接删除键(若键无子键则成功),失败则枚举子键递归删除。这是 Windows 注册表 API 的标准模式,因为 `RegDeleteKey` 不能删除有子键的键(Windows Vista 后的 `RegDeleteKeyEx` 可以,但代码使用兼容性更好的递归方式)。

### 9.4 Shell 调用函数

| 函数 | 行号 | 功能 |
|------|------|------|
| `restartWithPrivileges` | L334-351 | UAC 提权重启 |
| `runProgram` | L353-366 | 通用 ShellExecuteEx 调用 |
| `launchURL` | L41-44 | 打开默认浏览器 |
| `launchGameLibrary` | L49-55 | 打开游戏库页面 |
| `displayMessage` | L11-36 | 弹出 MessageBox(隐藏任务栏图标) |

#### displayMessage 隐藏任务栏图标

`displayMessage`(`utils.cpp` L11-36)创建一个不可见的父窗口作为 `MessageBox` 的父,目的是隐藏任务栏上 bwlauncher 的默认图标:

```cpp
int displayMessage( const tstring& msg, int mbFlags )
{
    HINSTANCE hInstance = GetModuleHandle(NULL);
    WNDCLASSEX wcex;
    wcex.cbSize = sizeof(WNDCLASSEX);
    wcex.style              = CS_HREDRAW | CS_VREDRAW;
    wcex.lpfnWndProc        = DefWindowProc;
    ...
    wcex.lpszClassName      = _T("BWLauncher");
    RegisterClassEx(&wcex);
    HWND wnd = ::CreateWindow(
        wcex.lpszClassName, _T("BWLauncher"), WS_ICONIC | WS_DISABLED,
      -1000, -1000, 1, 1, NULL, NULL, hInstance, NULL);

    int result = ::MessageBox( wnd, msg.c_str(), _T("BigWorld Launcher"), mbFlags );

    DestroyWindow( wnd );
    return result;
}
```

窗口位置 `(-1000, -1000)`、尺寸 `1x1`、样式 `WS_ICONIC | WS_DISABLED` 确保窗口不可见,但作为 MessageBox 的父窗口,使 MessageBox 不在任务栏单独显示图标。这是无窗口应用弹窗的标准技巧。

---

## 十、内嵌 TinyXML 库

### 10.1 为何内嵌

bwlauncher 内嵌了完整的 TinyXML 库(`tinyxml.cpp`、`tinyxmlparser.cpp`、`tinyxmlerror.cpp`、`tinystr.cpp`),而非链接外部库。原因:

1. **零依赖**:bwlauncher 是用户首次安装时运行的工具,不能依赖引擎其他 DLL;
2. **小体积**:TinyXML 是轻量级 XML 解析器,单文件实现;
3. **简单用法**:仅用于解析 `.db` 文件这种极简 XML,不需要高级特性。

### 10.2 使用场景

bwlauncher 中 TinyXML 的唯一使用点是 `LaunchDB::loadFile`(`launch_db.cpp` L44-69),解析 `.db` 文件:

```cpp
TiXmlDocument doc( toAnsi( file ).c_str() );

if (!doc.LoadFile( toAnsi(path + file).c_str() ) || !doc.RootElement())
{
    return;
}

TiXmlNode* node = doc.RootElement()->FirstChild( "exePath" );

if (node && node->FirstChild())
{
    const char* value = node->FirstChild()->Value();
    tstring exePath( fromAnsi( value ) );
    ...
}
```

注意 TinyXML 使用 ANSI `char*` 接口,因此需要 `toAnsi`/`fromAnsi` 在 `tstring`(Unicode 下为 `wstring`)与 `std::string` 之间转换。

### 10.3 registerGame 写入 .db

与读取对应,`registerGame`(`bwlauncher.cpp` L312-338)使用 `fprintf` 直接写出 XML,不通过 TinyXML:

```cpp
bool registerGame( const tstring& gameID, const tstring& exePath )
{
    tstring installedLoc = findInstalledLocation();
    if (installedLoc.empty())
    {
        return false;
    }

    tstring dbPath = installedLoc + _T("\\") + gameID + _T(".db");

    FILE* fp = NULL;
    errno_t err = _wfopen_s( &fp, dbPath.c_str(), L"w" );
    if (!fp || err != 0)
    {
        throw UnprivilegedException();
    }

    fprintf( fp, "<root>\n" );
    fprintf( fp, "\t<exePath> %S </exePath>\n",exePath.c_str() );
    fprintf( fp, "</root>\n" );

    fclose( fp );
    return true;
}
```

`%S` 格式说明符在宽字符 `fprintf` 中表示"窄字符串",用于将 `tstring`(wstring)转为 ANSI 输出。这是一种不对称的设计:读用 TinyXML,写用 `fprintf`,但两者格式兼容。

---

## 十一、配置项与命令行参数

### 11.1 编译期配置(bwlauncher_config.hpp)

```cpp
#define BWLAUNCHER_VERSION      TEXT("100")
#define BWLAUNCHER_EXE_NAME     "bwlauncher.exe"
#define BWLAUNCHER_UNINST_BAT   "bwlauncher_uninst.bat"
```

| 宏 | 值 | 用途 |
|----|-----|------|
| `BWLAUNCHER_VERSION` | `"100"` | 版本号,写入注册表用于升级检测 |
| `BWLAUNCHER_EXE_NAME` | `"bwlauncher.exe"` | 可执行文件名(自删除批处理引用) |
| `BWLAUNCHER_UNINST_BAT` | `"bwlauncher_uninst.bat"` | 卸载批处理文件名 |

### 11.2 运行期配置(bwlauncher_config.cpp)

```cpp
const TCHAR* BW_GAMES_URL          = _T( "http://games.bigworldtech.com:8080/" );
const TCHAR* BW_GAMES_LIBRARY_URL  = _T( "http://games.bigworldtech.com:8080/library/%(GameID)/" );
```

| 常量 | 用途 |
|------|------|
| `BW_GAMES_URL` | 无参数时打开的默认页面 |
| `BW_GAMES_LIBRARY_URL` | `browse` 命令的游戏库 URL 模板,`%(GameID)` 替换为实际游戏 ID |

### 11.3 命令行参数汇总

| 参数 | 是否需要提权 | 说明 |
|------|-------------|------|
| `/installCurrent` | 否 | 为当前用户安装到 `CSIDL_LOCAL_APPDATA` |
| `/install` | 是 | 同 `/installAll` |
| `/installAll` | 是 | 为所有用户安装到 `CSIDL_COMMON_APPDATA` |
| `/runAfterInstall` | 否 | 安装后立即运行已安装的 bwlauncher |
| `/restartedWithPrivileges` | 否 | 内部标志:已通过 UAC 提权重启,避免循环 |
| `/registerGame <gameID> <exePath>` | 取决于已安装位置 | 注册新游戏到 `.db` 文件 |
| `/uninstallCurrent` | 否 | 卸载(代码中注释掉,不可用) |
| `/uninstall` 或 `/uninstallAll` | 是 | 卸载(代码中注释掉,不可用) |
| (无参数,已安装) | 否 | 处理 `bigworld://` URL |

### 11.4 URL 协议参数

URL 协议参数通过 `argv[1]` 传入,格式为 `bigworld://<cmd>/<args>`:

| URL 命令 | 参数数量 | 参数含义 |
|---------|---------|---------|
| `bigworld://launch/<gameID>/<user>/<pass>` | 3 | 启动游戏,传入凭证 |
| `bigworld://browse/<gameID>` | 1 | 浏览器打开游戏库 |
| `bigworld://`(无命令) | 0 | 打开默认游戏页面 `BW_GAMES_URL` |

---

## 十二、与其他模块的依赖关系

### 12.1 依赖关系图

```
                  ┌──────────────────────────┐
                  │       bwlauncher.exe     │
                  └────────────┬─────────────┘
                               │
            ┌──────────────────┼──────────────────────┐
            │                  │                      │
            ▼                  ▼                      ▼
   ┌─────────────────┐  ┌──────────────┐    ┌──────────────────┐
   │  Windows API    │  │  cstdmf 库   │    │  内嵌 TinyXML    │
   │  - kernel32     │  │  - bw_vector │    │  - TiXmlDocument │
   │  - user32       │  │  - bw_map    │    │  - TiXmlNode     │
   │  - shell32      │  │              │    │                  │
   │  - shlwapi      │  │              │    │                  │
   │  - advapi32     │  │              │    │                  │
   └─────────────────┘  └──────────────┘    └──────────────────┘
            │
            ▼
   ┌─────────────────────────────────────┐
   │  BigWorld Client (启动目标)         │
   │  - 通过 --username/--password 登录  │
   └─────────────────────────────────────┘
```

### 12.2 依赖的 Windows API

| DLL | 使用的 API | 用途 |
|-----|-----------|------|
| `kernel32` | `GetModuleFileName`, `GetCommandLine`, `FindFirstFile`, `FindNextFile`, `GetFileAttributes`, `CopyFile`, `CreateFile`, `WriteFile`, `CloseHandle` | 文件与路径操作 |
| `user32` | `MessageBox`, `CreateWindow`, `DestroyWindow`, `RegisterClassEx`, `LoadIcon`, `LoadCursor`, `PeekMessage` | UI 交互 |
| `shell32` | `ShellExecute`, `ShellExecuteEx`, `SHGetFolderPath`, `SHCreateDirectoryEx` | Shell 集成 |
| `shlwapi` | `PathMatchSpec` | 文件名通配符匹配 |
| `advapi32` | `RegCreateKey`, `RegSetValueEx`, `RegOpenKey`, `RegQueryValueEx`, `RegDeleteKey`, `RegEnumKeyEx`, `RegCloseKey` | 注册表操作 |
| `strsafe` | `StringCchCopy` | 安全字符串操作 |

### 12.3 依赖的 BigWorld 库

bwlauncher 仅依赖 `cstdmf` 库的容器类型别名:

```cpp
#include "cstdmf/bw_vector.hpp"
#include "cstdmf/bw_map.hpp"
```

这些头文件提供 `BW::vector` 和 `BW::map`,本质是 `std::vector` 和 `std::map` 的别名,确保 bwlauncher 与引擎其他部分使用一致的 STL 实现(在多 STL 版本共存时避免链接冲突)。

### 12.4 不依赖的引擎模块

bwlauncher **不依赖**以下引擎模块,保持极简:

- `resmgr`(资源管理)
- `pyscript`(Python 脚本)
- `network`(网络通信)
- `entitydef`(实体定义)
- `moo`(图形渲染)

这使得 bwlauncher 可以独立编译为单文件 EXE,便于用户首次安装时分发。

---

## 十三、关键代码片段(带行号)

### 13.1 wWinMain 入口(bwlauncher.cpp L37-164)

```cpp
// bwlauncher.cpp L37
int CALLBACK wWinMain( HINSTANCE hInstance, HINSTANCE hPrevInstance,
                       LPWSTR lpCmdLine, int nShowCmd )
{
    StringVector args;
    splitCommandArgs( GetCommandLine(), args );   // L40

    if (gotArg(  _T( "/installCurrent" ), args))  // L42
    {
        DEBUG_MSG( _T("Attempting install for current user.\n") );
        installSelf( false );
        if (gotArg( _T("/runAfterInstall"), args))
        {
            runProgram( getLauncherInstalledExePath( false ) );
        }
    }
    else if (gotArg(  _T( "/install" ), args) || gotArg( _T("/installAll" ), args ))  // L51
    {
        try
        {
            installSelf( true );
            ...
        }
        catch(const UnprivilegedException&)  // L62
        {
            if (!gotArg(_T("/restartedWithPrivileges"), args))
            {
                restartWithPrivileges( _T("/installAll") );
            }
            ...
        }
    }
    else if (gotArg( _T("/registerGame"), args ))  // L103
    {
        ...
        registerGame( gameID, exePath );
        ...
    }
    else if (!checkInstallation(true) && !checkInstallation(false))  // L147
    {
        int ret = displayMessage(
            _T("Do you want to install the BigWorld launcher?"),
            MB_ICONQUESTION|MB_YESNO );
        if (ret == IDYES)
        {
            restartWithPrivileges( _T("/installAll /runAfterInstall") );
        }
    }
    else  // L158
    {
        processProtocolCommand( args );
    }

    return 0;
}
```

### 13.2 installSelf 注册表写入(bwlauncher.cpp L208-218)

```cpp
// bwlauncher.cpp L208
HKEY baseKey = allUsers ? HKEY_LOCAL_MACHINE : HKEY_CURRENT_USER;
tstring protocolCmd = getProtocolShellCmd( allUsers );

if (!writeToRegistry( baseKey, _T("Software\\Classes\\bigworld"), _T(""), _T("") ) ||
    !writeToRegistry( baseKey, _T("Software\\Classes\\bigworld"),
                      _T("Launcher Version"), BWLAUNCHER_VERSION ) ||
    !writeToRegistry( baseKey, _T("Software\\Classes\\bigworld"),
                      _T("URL Protocol"), _T("") ) ||
    !writeToRegistry( baseKey, _T("Software\\Classes\\bigworld\\Shell\\Open\\Command"),
                      _T(""), protocolCmd.c_str() ))
{
    DEBUG_MSG( _T("Failed to write launcher configuration keys to registry.\n") );
    return false;
}
```

### 13.3 splitUrl URL 解析(utils.cpp L248-275)

```cpp
// utils.cpp L248
bool splitUrl( const tstring & url, tstring & cmd, tstring & remainder )
{
    size_t start = 0;

    if (_tcsnicmp( url.c_str(), _T( "bigworld:" ), 9 ) == 0)  // L252
    {
        start += 9;
    }

    while (url[ start ] == '/')  // L257
    {
        ++start;
    }

    size_t end = url.find( '/', start );  // L262

    if (end != url.npos)
    {
        cmd = url.substr( start, end - start );        // L266
        remainder = url.substr( end + 1 );             // L267
    }
    else
    {
        cmd = url.substr( start );                     // L271
    }

    return true;
}
```

### 13.4 LaunchDB::launch 启动游戏(launch_db.cpp L102-125)

```cpp
// launch_db.cpp L102
bool LaunchDB::launch( const tstring& gameID, const tstring& username,
                       const tstring& password ) const
{
    if (applications_.find( gameID ) != applications_.end())  // L104
    {
        tstring exePath = applications_.find( gameID )->second;
        SHELLEXECUTEINFO sei = { sizeof( sei ) };

        sei.fMask = SEE_MASK_NOCLOSEPROCESS;
        sei.nShow = SW_SHOW;

        sei.lpFile = exePath.c_str();  // L112

        tstring params = _T( "--username " ) + username
                       + _T( " --password " ) + password;  // L114
        sei.lpParameters = params.c_str();

        if (ShellExecuteEx( &sei ) <= 32)  // L117 注意:返回值 <= 32 表示错误
        {
            return true;   // 反直觉:返回 true 表示启动失败
        }
    }

    DEBUG_MSG( _T( "Cannot launch application with ID " ) + gameID );
    return false;  // 返回 false 表示启动成功
}
```

### 13.5 restartWithPrivileges UAC 提权(utils.cpp L334-351)

```cpp
// utils.cpp L334
void restartWithPrivileges( const tstring& sw )
{
    SHELLEXECUTEINFO sei = { sizeof( sei ) };

    tstring fullPath = getAppFullPath();
    tstring fullParams = sw + _T( " /restartedWithPrivileges" );  // L339

    sei.fMask = SEE_MASK_NOCLOSEPROCESS;
    sei.nShow = SW_HIDE;                // L342 隐藏窗口

    sei.lpFile = fullPath.c_str();
    sei.lpVerb = _T( "runas" );         // L345 触发 UAC

    sei.lpParameters = fullParams.c_str();

    DEBUG_MSG( _T("Restarting with elevated privileges.\n") );
    ShellExecuteEx( &sei );             // L350
}
```

### 13.6 uninstall 自删除批处理(bwlauncher.cpp L13-18, L267-307)

```cpp
// bwlauncher.cpp L13
const char  SELF_DELETE_BAT[] =
"@echo off\n"
":Repeat\n"
"@del \""BWLAUNCHER_EXE_NAME"\" > NUL\n"
"@if exist \""BWLAUNCHER_EXE_NAME"\" goto Repeat\n"
"@del \""BWLAUNCHER_UNINST_BAT"\" > NUL\n";

// bwlauncher.cpp L267
bool uninstall( bool allUsers )
{
    HKEY baseKey = allUsers ? HKEY_LOCAL_MACHINE : HKEY_CURRENT_USER;
    if (!RegDelnode(  baseKey, _T("Software\\Classes\\bigworld") ))
    {
        return false;
    }

    // 自删除技巧:批处理文件循环 del 直到成功
    tstring uninstBat = getLauncherInstalledPath(allUsers) + _T("\\")_T(BWLAUNCHER_UNINST_BAT);

    HANDLE hfile = CreateFile( uninstBat.c_str(), GENERIC_WRITE, 0, NULL,
                                CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL );
    if (hfile)
    {
        DWORD numWritten=0;
        WriteFile( hfile, (LPCVOID*)SELF_DELETE_BAT, sizeof(SELF_DELETE_BAT)-1,
                   &numWritten, NULL );
    }
    CloseHandle(hfile);

    SHELLEXECUTEINFO sei = { sizeof( sei ) };
    tstring targetDir = getLauncherInstalledPath( allUsers );

    sei.fMask = SEE_MASK_NOCLOSEPROCESS;
    sei.nShow = SW_HIDE;
    sei.lpFile = uninstBat.c_str();
    sei.lpVerb = allUsers ? _T( "runas" ) : _T( "open" );  // L299
    sei.lpDirectory = targetDir.c_str();
    sei.lpParameters = NULL;

    ShellExecuteEx( &sei );  // L304
    return true;
}
```

自删除原理(参见 `http://www.catch22.net/tuts/selfdel`):Windows 不允许进程删除自身正在运行的 EXE,但批处理可以在 bwlauncher 退出后循环删除。批处理自身可以被 `del` 删除(批处理能删除自身)。

---

## 十四、设计亮点与注意事项

### 14.1 设计亮点

#### 14.1.1 无窗口应用的优雅交互

bwlauncher 是 GUI 子系统应用但实质无窗口,通过 `displayMessage`(`utils.cpp` L11-36)创建 1x1 不可见父窗口作为 `MessageBox` 的 owner,避免任务栏出现孤儿图标。这是 Windows 编程中处理"无 UI 工具"的标准模式。

#### 14.1.2 UAC 提权重试模式

`UnprivilegedException` + `restartWithPrivileges` + `/restartedWithPrivileges` 标志位构成完整的 UAC 重试模式:

1. 操作失败抛 `UnprivilegedException`;
2. `wWinMain` 捕获后调用 `restartWithPrivileges` 提权重启;
3. 新进程通过 `/restartedWithPrivileges` 标志位避免循环;
4. 若提权后仍失败,直接报错而非无限重试。

这种模式可推广到任何需要管理员权限的 Windows 工具。

#### 14.1.3 版本感知的安装校验

`checkInstallation` 不仅检查注册表键是否存在,还检查 `Launcher Version` 值是否等于当前版本(`bwlauncher.cpp` L233-234)。这意味着:

- 旧版本安装后,新版本 bwlauncher 会识别为"未安装",触发重新安装;
- 注册表中的版本号是升级机制的核心。

#### 14.1.4 CurrentUser 优先的游戏注册

`findInstalledLocation`(`bwlauncher.cpp` L248-262)按 **CurrentUser → AllUsers** 顺序查找已安装位置。这意味着:

- 若用户已私有安装,新注册的游戏写入私有目录;
- 避免普通用户触碰公共目录(需管理员权限)。

这是一种"权限最小化"设计。

#### 14.1.5 URL 协议的标准实现

bwlauncher 是 Windows URL 协议处理器的标准实现范例:

| 注册表项 | 作用 |
|---------|------|
| `HKCR\<scheme>` 默认值 | 协议显示名 |
| `HKCR\<scheme>\URL Protocol` | 标识为 URL 协议(必须为空字符串) |
| `HKCR\<scheme>\Shell\Open\Command` 默认值 | 点击链接时执行的命令,`%1` 替换为 URL |

这一模式被许多应用采用(如 `steam://`、`spotify://`、`zoommtg://`)。

### 14.2 注意事项

#### 14.2.1 LaunchDB::launch 返回值反直觉

`LaunchDB::launch`(`launch_db.cpp` L102-125)的返回值语义与函数名相反:

- 返回 `true`:`ShellExecuteEx` 失败(返回值 `<= 32`),需要回退到浏览器;
- 返回 `false`:启动成功,或游戏 ID 未找到。

调用方 `processProtocolCommand` 利用此反逻辑(`bwlauncher.cpp` L372-375),但代码可读性差。维护时需特别注意。

#### 14.2.2 密码明文传输

URL 中的密码以明文形式出现:

```
bigworld://launch/gameID/username/password
```

并通过命令行参数 `--password <pass>` 传给游戏客户端。这意味着:

- URL 历史记录中可能残留密码;
- 其他进程可通过 `GetCommandLine` 读取密码;
- 浏览器日志可能记录完整 URL。

这是 BigWorld 1.x 时代的设计,现代应用应使用临时令牌或加密通道。

#### 14.2.3 toAnsi/fromAnsi 仅支持 ASCII

`launch_db.cpp` L14-39 的 `toAnsi`/`fromAnsi` 是逐字符转换:

```cpp
std::string toAnsi( const tstring& str )
{
    std::string s;
    for (tstring::const_iterator iter = str.begin(); iter != str.end(); ++iter)
    {
        s += (char)*iter;
    }
    return s;
}
```

对于非 ASCII 字符(如中文路径),这种转换会丢失高位字节。因此 bwlauncher 的 `.db` 文件中 `exePath` 仅支持 ASCII 路径。若游戏安装在中文路径下,可能无法启动。

#### 14.2.4 卸载功能被注释

`bwlauncher.cpp` L76-102 的卸载分支被 `/* ... */` 注释掉,意味着 bwlauncher 实际上**无法通过命令行卸载**。用户只能手动删除注册表项和文件。这可能是因为:

- 自删除批处理在某些环境下不可靠;
- 卸载需求由安装包(如 MSI)统一处理;
- 避免误卸载导致的协议失效。

#### 14.2.5 splitString 不支持多字符分隔符

`splitString`(`utils.cpp` L586-609)使用 `pos = next + 1` 跳过分隔符,仅适用于单字符分隔符。若传入多字符分隔符(如 `//`),会跳过 1 个字符而非分隔符长度,导致解析错误。bwlauncher 中仅用于单字符 `/` 分割 URL,无问题;但若复用此函数需注意。

#### 14.2.6 注册表版本号是字符串

`BWLAUNCHER_VERSION` 定义为字符串 `"100"` 而非数字。版本比较通过字符串相等(`verifyRegistry` 中的 `_tcscmp`)。这意味着:

- `"100"` 与 `"100.0"` 会被视为不同版本;
- 版本号排序需手动维护(如 `"99"` > `"100"` 按字符串排序)。

当前仅有一个版本 `"100"`,无升级历史,问题不显现。

#### 14.2.7 无错误日志持久化

bwlauncher 的错误输出仅通过 `DEBUG_MSG`(实际是 `OutputDebugString`)和 `MessageBox`。无日志文件持久化。调试时需使用 DebugView 等工具捕获 `OutputDebugString` 输出。

### 14.3 安全考量

| 风险点 | 严重程度 | 缓解措施 |
|--------|---------|---------|
| 密码明文 URL | 高 | 设计层问题,需重新设计协议 |
| `runas` 提权 | 中 | UAC 提示用户确认 |
| 注册表写入 | 中 | 仅在安装时写入,运行时不修改 |
| `.db` 文件可写 | 中 | AllUsers 安装时目录权限受控 |
| ShellExecute 任意路径 | 中 | `.db` 文件由 `registerGame` 写入,受安装目录权限保护 |

### 14.4 与现代实践的对比

| 方面 | bwlauncher (2010s) | 现代实践 (2020s) |
|------|-------------------|------------------|
| URL 协议 | 注册表 `HKCR\bigworld` | 同左(仍是标准) |
| 安装位置 | `CSIDL_COMMON_APPDATA` | 同左(或 `FOLDERID_ProgramData`) |
| 权限提升 | `runas` 动词 | 同左(UAC 仍是标准) |
| 游戏启动 | `ShellExecuteEx` + 命令行 | 同左(或 IPC 协议) |
| 凭证传递 | URL 明文 | OAuth 令牌 / 临时码 |
| XML 解析 | 内嵌 TinyXML | 系统 XML 库或 JSON |
| 错误处理 | 异常 + MessageBox | 结构化日志 + 错误码 |

bwlauncher 的整体设计在现代仍是合理的,主要改进空间在凭证安全与日志持久化。

---

## 附录 A:常见问题澄清

### A.1 bwlauncher 是控制台程序还是 GUI 程序?

**GUI 程序**。入口为 `wWinMain`(`bwlauncher.cpp` L37),链接器子系统为 `WINDOWS`。这意味着双击运行不会弹出控制台窗口,适合作为 URL 协议处理器。所有输出通过 `OutputDebugString` 或 `MessageBox`。

### A.2 为什么不使用 lpCmdLine 而重新调用 GetCommandLine?

`wWinMain` 的 `lpCmdLine` 参数已被 Windows 处理过引号,丢失了 URL 中的原始引号信息。而 `splitCommandArgs` 需要原始字符流以正确处理 `\"` 转义。因此使用 `GetCommandLine()` 重新获取(`bwlauncher.cpp` L40)。

### A.3 安装后 bwlauncher.exe 在哪里?

- AllUsers 安装:`C:\ProgramData\BigWorld\bwlauncher.exe`
- CurrentUser 安装:`C:\Users\<user>\AppData\Local\BigWorld\bwlauncher.exe`

注册表 `Shell\Open\Command` 指向上述路径之一。

### A.4 如何调试 bwlauncher?

1. 使用 Visual Studio 附加到 `bwlauncher.exe` 进程;
2. 在命令行运行 `bwlauncher.exe /installCurrent` 触发安装流程;
3. 使用 DebugView 捕获 `OutputDebugString` 输出;
4. 在浏览器输入 `bigworld://launch/test/user/pass` 触发协议处理。

### A.5 .db 文件可以手动创建吗?

可以。`.db` 文件是简单 XML:

```xml
<root>
    <exePath> C:\Games\MyGame\client.exe </exePath>
</root>
```

将此文件放到 bwlauncher 安装目录(如 `C:\ProgramData\BigWorld\mygame.db`),即可通过 `bigworld://launch/mygame/user/pass` 启动。注意 `exePath` 必须存在且非目录。

### A.6 为什么卸载功能被注释?

代码注释 `// UNCOMMENT FOR UNINSTALL SUPPORT`(`bwlauncher.cpp` L75)表明卸载功能存在但被禁用。可能原因:

1. 自删除批处理在 Vista+ UAC 下行为不稳定;
2. 卸载由安装包(MSI/NSIS)统一处理;
3. 避免误卸载导致 `bigworld://` 协议失效。

如需启用,取消 L76-102 的注释并重新编译即可。

### A.7 bwlauncher 与 bwmachined 的关系?

无直接关系。bwlauncher 是**客户端侧**的 URL 协议处理器,用于启动游戏客户端;bwmachined 是**服务端侧**的守护进程管理器。两者分属不同子系统,仅共享 BigWorld 品牌命名。

### A.8 如何添加对新游戏的支持?

通过 `registerGame` 命令:

```bat
bwlauncher.exe /registerGame mygame "C:\Games\MyGame\client.exe"
```

这会在安装目录创建 `mygame.db` 文件。之后即可通过 `bigworld://launch/mygame/user/pass` 启动该游戏。若 bwlauncher 安装在 AllUsers 位置,此命令可能需要管理员权限。

---

## 文档信息

- **文档版本**: 1.0
- **分析对象**: BigWorld Engine 14.4.1 `bwlauncher` 工具
- **源码路径**: `programming/bigworld/tools/bwlauncher/`
- **总代码行数**: ~1300 行(不含 TinyXML)
- **最后更新**: 2026-06-30
