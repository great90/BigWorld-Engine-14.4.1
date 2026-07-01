# BigWorld 工具 - plugin_system 实现分析

> 源码位置：`programming/bigworld/tools/plugin_system/`
> 引擎版本：BigWorld Engine 14.4.1
> 文档版本：1.0

---

## 目录

- [1. 概述](#1-概述)
  - [1.1 工具定位](#11-工具定位)
  - [1.2 设计目标](#12-设计目标)
  - [1.3 核心能力](#13-核心能力)
- [2. 目录结构](#2-目录结构)
  - [2.1 文件清单](#21-文件清单)
  - [2.2 文件职责](#22-文件职责)
- [3. 插件接口宏](#3-插件接口宏)
  - [3.1 PLUGIN_INIT / PLUGIN_FINI 宏](#31-plugin_init--plugin_fini-宏)
  - [3.2 PLUGIN_INIT_FUNC / PLUGIN_FINI_FUNC 宏](#32-plugin_init_func--plugin_fini_func-宏)
  - [3.3 Debug/Release 命名分离](#33-debugrelease-命名分离)
  - [3.4 宏使用范例](#34-宏使用范例)
- [4. PluginLoader 类](#4-pluginloader-类)
  - [4.1 类声明](#41-类声明)
  - [4.2 成员变量](#42-成员变量)
  - [4.3 类型别名](#43-类型别名)
  - [4.4 PLUGIN_GET_PROC_ADDRESS 宏](#44-plugin_get_proc_address-宏)
- [5. 加载/卸载流程](#5-加载卸载流程)
  - [5.1 initPlugins：批量加载](#51-initplugins批量加载)
  - [5.2 loadPlugin：单插件加载](#52-loadplugin单插件加载)
  - [5.3 unloadPlugin：单插件卸载](#53-unloadplugin单插件卸载)
  - [5.4 finiPlugins：批量卸载](#54-finiplugins批量卸载)
  - [5.5 完整生命周期](#55-完整生命周期)
- [6. 使用者与集成方式](#6-使用者与集成方式)
  - [6.1 多继承集成模式](#61-多继承集成模式)
  - [6.2 JITCompiler 集成](#62-jitcompiler-集成)
  - [6.3 BatchCompiler 集成](#63-batchcompiler-集成)
  - [6.4 插件侧的 dynamic_cast 协议](#64-插件侧的-dynamic_cast-协议)
  - [6.5 已注册的转换器插件](#65-已注册的转换器插件)
- [7. 配置](#7-配置)
  - [7.1 插件清单文件](#71-插件清单文件)
  - [7.2 文件路径解析](#72-文件路径解析)
  - [7.3 配置文件示例](#73-配置文件示例)
- [8. 设计亮点](#8-设计亮点)
  - [8.1 极简的三文件框架](#81-极简的三文件框架)
  - [8.2 双向通信的 PluginLoader 引用](#82-双向通信的-pluginloader-引用)
  - [8.3 Debug/Release 同进程共存](#83-debugrelease-同进程共存)
  - [8.4 逆序卸载保证依赖正确性](#84-逆序卸载保证依赖正确性)
  - [8.5 失败安全回退](#85-失败安全回退)
  - [8.6 编译期契约的宏](#86-编译期契约的宏)
- [9. 常见误区与澄清](#9-常见误区与澄清)
- [10. 附录](#10-附录)
  - [10.1 术语表](#101-术语表)
  - [10.2 关键文件行号索引](#102-关键文件行号索引)

---

## 1. 概述

### 1.1 工具定位

`plugin_system` 是 BigWorld Engine 14.4.1 工具链中的 **插件框架基础库**，它提供了一套
基于 Win32 `LoadLibrary` / `GetProcAddress` 的轻量级动态插件机制，让资产管线（asset
pipeline）的各个转换器（converter）可以以独立 DLL 的形式延迟加载、按需启用，并能在运行
时与宿主程序双向交互。

| 维度 | 说明 |
|------|------|
| 库类型 | 静态库（被宿主程序与插件 DLL 同时链接） |
| 平台 | Windows（依赖 `LoadLibrary`/`GetProcAddress`/`HMODULE`） |
| 接口风格 | C 风格导出函数 + C++ `PluginLoader` 引用 |
| 主要使用者 | `batch_compiler`、`jit_compiler`、`asset_pipeline` 下的 9 个转换器 |
| 配置方式 | 与可执行文件同目录的 `<exename>_plugins.txt` 清单文件 |

### 1.2 设计目标

1. **解耦**：把资产管线中可选的、重型依赖（如 Moo 图形、terrain）的转换器拆成独立 DLL，
   宿主程序只链接必要的核心，按需加载。
2. **统一接口**：所有插件遵循相同的 `PLUGIN_INIT`/`PLUGIN_FINI` 函数签名，加载与卸载
   逻辑统一。
3. **双向通信**：插件加载时接收 `PluginLoader&` 引用，可 `dynamic_cast` 到派生类（如
   `Compiler`），从而调用宿主注册转换器、获取资源路径等。
4. **Debug/Release 隔离**：通过宏在 Debug 构建下使用带 `_d` 后缀的导出符号名，避免
   Debug 插件被 Release 宿主误加载（或反之）导致 ABI 不匹配。

### 1.3 核心能力

1. **批量加载**：`initPlugins()` 读取清单文件，逐行加载插件 DLL。
2. **单插件加载/卸载**：`loadPlugin(name)` / `unloadPlugin(hModule)` 支持运行时动态增减。
3. **生命周期回调**：自动调用插件的 `PLUGIN_INIT` 进行初始化，`PLUGIN_FINI` 进行反初
   始化。
4. **失败回退**：若 `PLUGIN_INIT` 失败，自动调用 `PLUGIN_FINI` 清理后 `FreeLibrary`。
5. **已加载插件枚举**：`pluginNames()` 返回当前已加载插件的文件名列表。
6. **逆序卸载**：`finiPlugins()` 按加载的相反顺序卸载，保证后加载的插件（可能依赖先加
   载的）先被释放。

---

## 2. 目录结构

### 2.1 文件清单

```
programming/bigworld/tools/plugin_system/
├── plugin.hpp           # 插件作者使用的宏定义（PLUGIN_INIT / PLUGIN_FINI_FUNC）
├── plugin_loader.hpp    # PluginLoader 类声明 + 函数指针类型别名
└── plugin_loader.cpp    # PluginLoader 实现（initPlugins/loadPlugin/unloadPlugin/finiPlugins）
```

整个框架只有 3 个文件，不到 130 行实现代码，是 BigWorld 工具链中最小的库之一。

### 2.2 文件职责

| 文件 | 行数 | 职责 | 被谁包含 |
|------|------|------|----------|
| `plugin.hpp` | 28 | 定义 `PLUGIN_INIT`/`PLUGIN_FINI`/`PLUGIN_INIT_FUNC`/`PLUGIN_FINI_FUNC` 宏 | **每个插件 DLL** 的实现文件 |
| `plugin_loader.hpp` | 46 | `PluginLoader` 类声明、`PluginInitFunc`/`PluginFiniFunc` 类型别名 | 宿主程序与插件 |
| `plugin_loader.cpp` | 129 | `PluginLoader` 4 个方法的实现 | 仅宿主程序链接 |

> 设计要点：`plugin.hpp` 故意保持极简且不依赖 `Windows.h`，让插件作者只需包含它就能写
> 出合规的插件。`plugin_loader.hpp` 才引入 `WTypes.h`（`HMODULE`），区分了"插件作者视
> 角"与"宿主视角"。

---

## 3. 插件接口宏

### 3.1 PLUGIN_INIT / PLUGIN_FINI 宏

```cpp
// plugin.hpp L10-16
#ifdef _DEBUG
    #define PLUGIN_INIT PluginInit_d
    #define PLUGIN_FINI PluginFini_d
#else
    #define PLUGIN_INIT PluginInit
    #define PLUGIN_FINI PluginFini
#endif
```

这两个宏定义了插件导出函数的**实际符号名**：
- Release 构建：`PluginInit` / `PluginFini`
- Debug 构建：`PluginInit_d` / `PluginFini_d`

宿主程序加载时通过相同的宏（在 `plugin_loader.cpp` 中重新定义）解析符号，因此宿主与
插件必须用相同的 Debug/Release 配置编译，否则符号名不匹配，加载失败。这是一种**编译期
ABI 自检**机制。

### 3.2 PLUGIN_INIT_FUNC / PLUGIN_FINI_FUNC 宏

```cpp
// plugin.hpp L18-24
#ifdef _DEBUG
    #define PLUGIN_INIT_FUNC extern "C" __declspec(dllexport) bool PLUGIN_INIT( PluginLoader & pluginLoader )
    #define PLUGIN_FINI_FUNC extern "C" __declspec(dllexport) bool PLUGIN_FINI( PluginLoader & pluginLoader )
#else
    #define PLUGIN_INIT_FUNC extern "C" __declspec(dllexport) bool PLUGIN_INIT( PluginLoader & pluginLoader )
    #define PLUGIN_FINI_FUNC extern "C" __declspec(dllexport) bool PLUGIN_FINI( PluginLoader & pluginLoader )
#endif
```

> 注：Debug 与 Release 分支在这里**完全相同**，但仍然分开写。这是因为 `PLUGIN_INIT`/
> `PLUGIN_FINI` 宏本身已根据 `_DEBUG` 展开为不同符号名，因此函数体签名实际是不同的。
> 分开写保持了对称性，便于未来在 Debug 分支添加额外的调试属性（如 `__cdecl` 显式标注
> 或调试标记）。

插件作者只需在自己的实现文件中写：

```cpp
#include "plugin_system/plugin.hpp"

PLUGIN_INIT_FUNC
{
    // 初始化代码，返回 true 表示成功
    return true;
}

PLUGIN_FINI_FUNC
{
    // 反初始化代码，返回 true 表示成功
    return true;
}
```

宏展开后（Release）等价于：

```cpp
extern "C" __declspec(dllexport) bool PluginInit( PluginLoader & pluginLoader )
{
    ...
}
extern "C" __declspec(dllexport) bool PluginFini( PluginLoader & pluginLoader )
{
    ...
}
```

- `extern "C"`：禁用 C++ 名称修饰，保证符号名平坦，可被 `GetProcAddress` 按名查找。
- `__declspec(dllexport)`：告知链接器导出该符号，无需 `.def` 文件。
- 返回 `bool`：`true` 表示成功，`false` 表示失败。`PLUGIN_INIT` 返回 `false` 会导致
  `loadPlugin` 触发回退逻辑（见 §5.2）。

### 3.3 Debug/Release 命名分离

为何要分离 Debug/Release 符号名？

```
宿主.exe (Release) ──┬── 加载 plugin_a.dll (Release) → 查找 "PluginInit"  ✓
                     │
                     └── 加载 plugin_b.dll (Debug)    → 查找 "PluginInit"
                                                    DLL 导出 "PluginInit_d"
                                                    GetProcAddress 返回 NULL ✗
```

若不分离符号名，Release 宿主可能加载 Debug 插件（反之亦然），而 Debug/Release 的 C++
运行时布局、调试信息、断言行为不同，会导致难以诊断的崩溃。通过符号名后缀，宿主在
`GetProcAddress` 时自然找不到匹配符号，加载失败，但不会破坏进程。

### 3.4 宏使用范例

以 `visual_processor` 插件为例（完整代码见 `asset_pipeline/converters/visual_processor/plugin_main.cpp`）：

```cpp
// visual_processor/plugin_main.cpp L1-17
#include "asset_pipeline/compiler/compiler.hpp"
#include "asset_pipeline/compiler/resource_callbacks.hpp"
#include "asset_pipeline/conversion/converter_info.hpp"
#include "moo/init.hpp"
#include "moo/render_context.hpp"
#include "moo/renderer.hpp"
#include "plugin_system/plugin.hpp"               // ← 必须包含
#include "plugin_system/plugin_loader.hpp"
// ... 其他 include

BW_BEGIN_NAMESPACE

ConverterInfo visualProcessorInfo;
ResourceCallbacks resourceCallbacks;
static std::auto_ptr<Renderer> s_pRenderer;

PLUGIN_INIT_FUNC                                  // ← 展开为导出函数
{
    Compiler * compiler = dynamic_cast< Compiler * >( &pluginLoader );
    if (compiler == NULL)
    {
        return false;
    }
    // ... 初始化资源系统、注册窗口、创建渲染设备
    compiler->registerConverter( visualProcessorInfo );
    compiler->registerResourceCallbacks( resourceCallbacks );
    return true;
}

PLUGIN_FINI_FUNC                                  // ← 展开为导出函数
{
    Moo::fini();
    BWResource::fini();
    DataSectionCensus::fini();
    Watcher::fini();
    s_pRenderer.reset();
    return true;
}

BW_END_NAMESPACE
```

要点：
- 插件作者只需包含 `plugin.hpp` 与 `plugin_loader.hpp`，无需手写 `extern "C"` 与
  `__declspec`。
- `PLUGIN_INIT_FUNC` 接收 `PluginLoader &`，可通过 `dynamic_cast` 转为宿主的具体类型，
  实现双向通信。
- `PLUGIN_INIT` 返回 `false` 会触发宿主的回退（卸载已加载的 DLL）。
- `PLUGIN_FINI` 应释放 `PLUGIN_INIT` 中申请的所有资源。

---

## 4. PluginLoader 类

### 4.1 类声明

```cpp
// plugin_loader.hpp L14-40
typedef bool ( *PluginInitFunc )( PluginLoader & pluginLoader );
typedef bool ( *PluginFiniFunc )( PluginLoader & pluginLoader );

class PluginLoader
{
public:
    typedef BW::vector< BW::string > PluginNameList;

public:
    PluginLoader() {}
    virtual ~PluginLoader() {}

    void initPlugins();
    void finiPlugins();

    HMODULE loadPlugin( const BW::string& pluginName );
    bool unloadPlugin( HMODULE plugin );

    const PluginNameList & pluginNames() const;

private:

    typedef BW::vector< HMODULE > PluginList;
    PluginList plugins_;

    PluginNameList pluginNames_;
};
```

`PluginLoader` 是一个**可被多继承的混入类**（mixin）：
- 构造与析构为空 `inline`，无虚函数（除析构），不增加额外开销。
- 没有抽象方法，但实际使用者总是从它派生并组合其他基类（见 §6）。
- 持有两个并行容器：`plugins_`（DLL 句柄）与 `pluginNames_`（DLL 文件名），通过下标隐
  式对应。

### 4.2 成员变量

| 成员 | 类型 | 含义 |
|------|------|------|
| `plugins_` | `BW::vector<HMODULE>` | 已加载插件的 Win32 模块句柄列表，按加载顺序排列 |
| `pluginNames_` | `BW::vector<BW::string>`（即 `PluginNameList`） | 与 `plugins_` 一一对应的插件文件名（UTF-8 编码） |

> 两个容器**不显式配对**（无 `map<HMODULE, string>`），而是按下标隐式对应。这种设计在
> `loadPlugin` 中通过两次 `push_back` 维持一致性，在 `unloadPlugin` 中通过两次 `erase`
> 同步删除。

### 4.3 类型别名

```cpp
// plugin_loader.hpp L14-15
typedef bool ( *PluginInitFunc )( PluginLoader & pluginLoader );
typedef bool ( *PluginFiniFunc )( PluginLoader & pluginLoader );
```

这两个函数指针类型对应插件导出的 `PLUGIN_INIT`/`PLUGIN_FINI` 函数签名。在
`loadPlugin` 中通过 `PLUGIN_GET_PROC_ADDRESS` 取得地址后，强转为这两个类型调用。

### 4.4 PLUGIN_GET_PROC_ADDRESS 宏

`plugin_loader.hpp` 中定义：

```cpp
// plugin_loader.hpp L10
#define PLUGIN_GET_PROC_ADDRESS( hPlugin, func ) ::GetProcAddress( hPlugin, #func )
```

`plugin_loader.cpp` 中**重定义**为使用 `STR` 宏版本：

```cpp
// plugin_loader.cpp L8-9
#define STR( X ) #X
#define PLUGIN_GET_PROC_ADDRESS( hPlugin, func ) ::GetProcAddress( hPlugin, STR( func ) )
```

二者效果相同（都是把宏参数字符串化后传给 `GetProcAddress`），但 cpp 中的版本通过 `STR`
宏多一层间接，能正确处理宏参数本身是另一个宏的情况（如 `PLUGIN_INIT` 展开为
`PluginInit`）。

实际调用形式：

```cpp
PluginInitFunc pluginInit =
    (PluginInitFunc) PLUGIN_GET_PROC_ADDRESS( hPlugin, PLUGIN_INIT );
```

展开为：

```cpp
PluginInitFunc pluginInit =
    (PluginInitFunc) ::GetProcAddress( hPlugin, "PluginInit" );  // Release
    // 或 "PluginInit_d" (Debug)
```

---

## 5. 加载/卸载流程

### 5.1 initPlugins：批量加载

```cpp
// plugin_loader.cpp L13-33
void PluginLoader::initPlugins()
{
    BW_GUARD;

    BW::string configFile = BWUtil::executableDirectory() + 
        BWUtil::executableBasename() + "_plugins.txt";
    
    std::ifstream configStream( configFile.c_str() );
    if ( !configStream.good() )
    {
        ERROR_MSG("Could not open plugin list file %S\n", configFile);
        return;
    }

    typedef std::istream_iterator< BW::string > string_istream_iterator;
    for (auto it = string_istream_iterator(configStream), end = string_istream_iterator(); it != end; ++it)
    {
        INFO_MSG("Loading Plugin %S as specified in file\n", it->c_str());
        loadPlugin( it->c_str() );
    }
}
```

流程：

1. **定位清单文件**：路径 = `executableDirectory() + executableBasename() + "_plugins.txt"`。
   - 例如可执行文件为 `C:\bw\bin\batch_compiler.exe`，则清单文件为
     `C:\bw\bin\batch_compiler_plugins.txt`。
2. **打开清单**：用 `std::ifstream` 打开。若打开失败，记录 `ERROR_MSG` 并返回（不抛异
   常，宿主程序继续运行，只是没有插件）。
3. **逐行读取**：用 `std::istream_iterator<BW::string>` 按空白分隔的 token 读取。这意味
   着清单文件每行一个插件名（无扩展名），空白分隔，支持 `#` 风格注释需额外处理（当前实
   现不支持注释，会尝试把 `#` 当作插件名加载并失败）。
4. **逐个加载**：对每个 token 调用 `loadPlugin(name)`。

> `BW_GUARD` 是 BigWorld 的异常守卫宏，捕获函数体内的 C++ 异常并记录堆栈，避免异常逃逸
> 到 Win32 消息循环导致进程崩溃。

### 5.2 loadPlugin：单插件加载

```cpp
// plugin_loader.cpp L46-80
HMODULE PluginLoader::loadPlugin( const BW::string& pluginName )
{
    BW_GUARD;

    BW::wstring pluginFileName = bw_utf8tow( 
        BWUtil::executableDirectory() + pluginName );

    pluginFileName.append(L".dll");

    INFO_MSG( "Loading plugin file %S\n", pluginFileName.c_str() );

    HMODULE hPlugin = ::LoadLibrary( pluginFileName.c_str() );
    if (hPlugin != NULL)
    {
        PluginInitFunc pluginInit =
            (PluginInitFunc) PLUGIN_GET_PROC_ADDRESS( hPlugin, PLUGIN_INIT );

        if (pluginInit != NULL && ( *pluginInit )( *this ))
        {
            plugins_.push_back( hPlugin );
            pluginNames_.push_back( bw_wtoutf8( pluginFileName ) );
            return hPlugin;
        }

        PluginFiniFunc pluginFini =
            (PluginFiniFunc) PLUGIN_GET_PROC_ADDRESS( hPlugin, PLUGIN_FINI );

        if (pluginFini != NULL)
        {
            ( *pluginFini )( *this );
        }
        ::FreeLibrary( hPlugin );
    }
    return NULL;
}
```

流程：

1. **构造完整路径**：`executableDirectory() + pluginName + ".dll"`。`pluginName` 不含
   扩展名，由本函数补 `.dll`。
2. **UTF-8 → UTF-16**：`bw_utf8tow` 转换为 `std::wstring`，因为 `LoadLibrary` 在 Win32
   下需要宽字符（实际调用 `LoadLibraryW`）。
3. **加载 DLL**：`::LoadLibrary(pluginFileName.c_str())`。若返回 `NULL`，函数直接返回
   `NULL`（不记录错误，因为 `LoadLibrary` 自身已设置 `GetLastError`）。
4. **查找 PLUGIN_INIT**：通过 `PLUGIN_GET_PROC_ADDRESS` 取 `PluginInit`（Release）或
   `PluginInit_d`（Debug）符号。
5. **调用 PLUGIN_INIT**：若符号存在且调用返回 `true`，表示初始化成功：
   - 把 `hPlugin` 加入 `plugins_`。
   - 把文件名（UTF-8）加入 `pluginNames_`。
   - 返回 `hPlugin`。
6. **失败回退**：若 `PLUGIN_INIT` 不存在或返回 `false`：
   - 查找 `PLUGIN_FINI`，若存在则调用，给插件一个清理机会（哪怕 init 部分执行了一
     些）。
   - `::FreeLibrary(hPlugin)` 卸载 DLL。
   - 返回 `NULL`。

> 注意：`PLUGIN_INIT` 的入参是 `*this`（`PluginLoader&`），插件拿到这个引用后通常会
> `dynamic_cast` 到派生类（如 `Compiler`）来访问宿主的更多接口（见 §6.4）。

### 5.3 unloadPlugin：单插件卸载

```cpp
// plugin_loader.cpp L82-119
bool PluginLoader::unloadPlugin( HMODULE hPlugin )
{
    BW_GUARD;

    WCHAR filename[MAX_PATH];
    GetModuleFileName( hPlugin, &filename[0], MAX_PATH );
    BW::string pluginName;
    bw_wtoacp( filename, pluginName );
    INFO_MSG( "Unloading plugin %s\n", pluginName.c_str() );

    for ( auto it = plugins_.cbegin(); it != plugins_.cend(); ++it )
    {
        if (*it != hPlugin)
        {
            continue;
        }

        PluginFiniFunc pluginFini =
            (PluginFiniFunc) PLUGIN_GET_PROC_ADDRESS( *it, PLUGIN_FINI );

        if (pluginFini != NULL && !( *pluginFini )( *this ))
        {
            return false;
        }

        ::FreeLibrary( *it );
        plugins_.erase( it );

        auto nameIt = std::find( std::begin( pluginNames_ ), std::end( pluginNames_ ), pluginName );
        if (nameIt != std::end( pluginNames_ ))
        {
            pluginNames_.erase( nameIt );
        }

        break;
    }
    return true;
}
```

流程：

1. **获取插件文件名**：`GetModuleFileName` 取得 DLL 的完整路径，转为 ACP（系统 ANSI 编
   码）字符串用于日志。
2. **查找句柄**：遍历 `plugins_` 找到指定 `hPlugin`。
3. **调用 PLUGIN_FINI**：若符号存在则调用。**若 `PLUGIN_FINI` 返回 `false`，立即返回
   `false`，不卸载**。这给插件一个拒绝被卸载的机会（例如还有未完成的任务）。
4. **卸载并清理**：
   - `::FreeLibrary(*it)` 卸载 DLL。
   - 从 `plugins_` 中 `erase`。
   - 在 `pluginNames_` 中用 `std::find` 查找并 `erase` 对应文件名。
5. **break 退出循环**：句柄唯一，找到并处理完后立即退出循环。

> 注意：`pluginNames_` 中存的是 `bw_wtoutf8(pluginFileName)`（UTF-8），而这里查找用的是
> `bw_wtoacp(filename)`（ACP）。两者编码可能不一致（如路径含中文），存在理论上的查找失
> 败风险，但不影响句柄清理（句柄是主清理目标）。

### 5.4 finiPlugins：批量卸载

```cpp
// plugin_loader.cpp L35-44
void PluginLoader::finiPlugins()
{
    BW_GUARD;

    size_t numPlugins = plugins_.size();
    for ( size_t i = numPlugins; i > 0; --i )
    {
        unloadPlugin( plugins_[i - 1] );
    }
}
```

- 从后往前遍历 `plugins_`，对每个句柄调用 `unloadPlugin`。
- **逆序卸载**的关键意义：后加载的插件可能在 `PLUGIN_INIT` 中依赖了先加载的插件提供
  的资源（如注册的全局服务、单例）。逆序卸载保证被依赖者先释放依赖者，避免悬垂引用。
- 用 `i > 0; --i` 配合 `plugins_[i - 1]` 而非反向迭代器，是 BigWorld 代码库中常见的逆
  序遍历写法。

### 5.5 完整生命周期

```
宿主程序启动
    │
    ▼
[1] 构造 PluginLoader 派生类对象（如 BatchCompiler）
    │
    ▼
[2] initPlugins()
    │  ├─ 读取 <exename>_plugins.txt
    │  ├─ 对每行 pluginName:
    │  │    ├─ LoadLibrary(pluginName.dll)
    │  │    ├─ GetProcAddress("PluginInit")
    │  │    ├─ pluginInit(*this) → 插件 dynamic_cast 到 Compiler，注册转换器
    │  │    │   ├─ true  → 加入 plugins_ / pluginNames_
    │  │    │   └─ false → 调用 pluginFini + FreeLibrary（回退）
    │  │    └─ 返回 hModule / NULL
    │  └─ 完成
    │
    ▼
[3] 宿主执行主业务（编译资产等），插件提供的转换器被调用
    │
    ▼
[4] finiPlugins()
    │  └─ 逆序对每个 hPlugin:
    │       ├─ GetProcAddress("PluginFini")
    │       ├─ pluginFini(*this) → 插件清理资源
    │       │   ├─ true  → FreeLibrary + erase
    │       │   └─ false → 返回 false，不卸载（罕见）
    │       └─ 完成
    │
    ▼
[5] 析构 PluginLoader 派生类对象
    │
    ▼
宿主程序退出
```

---

## 6. 使用者与集成方式

### 6.1 多继承集成模式

`PluginLoader` 被设计为**混入基类**，宿主程序通过多继承同时获得「资产编译器」与「插件
加载器」两种能力：

```
                ┌─────────────────┐
                │   PluginLoader   │  ← 本框架
                └────────┬────────┘
                         │
                         ▼（多继承）
        ┌────────────────────────────────────┐
        │  AssetCompiler : public Compiler,  │  ← 资产管线核心
        │                public DebugMessage │
        │                Callback, ...       │
        └────────────────┬───────────────────┘
                         │
            ┌────────────┴────────────┐
            ▼                         ▼
    ┌──────────────────┐      ┌──────────────────┐
    │  BatchCompiler    │      │  JITCompiler      │
    │  : AssetCompiler, │      │  : AssetCompiler, │
    │  PluginLoader     │      │  AssetServer,     │
    │                   │      │  ResourceMod...,  │
    │                   │      │  PluginLoader     │
    └──────────────────┘      └──────────────────┘
```

这种模式让 `BatchCompiler`/`JITCompiler` 对象本身就是 `PluginLoader`，插件通过
`PLUGIN_INIT` 收到的 `PluginLoader&` 引用实际指向 `BatchCompiler`/`JITCompiler` 实例，
`dynamic_cast<Compiler*>` 能成功。

### 6.2 JITCompiler 集成

```cpp
// jit_compiler/jit_compiler.hpp L13-17
class JITCompiler : public AssetCompiler
                  , public AssetServer
                  , public ResourceModificationListener
                  , public PluginLoader
{
public:
    explicit JITCompiler( TaskStore & store );
    virtual ~JITCompiler();
    // ...
};
```

调用点（`jit_compiler/main.cpp`）：

```cpp
// jit_compiler/main.cpp L67-97（节选）
options.apply(jitCompiler);
jitCompiler.initPlugins();        // ← 加载插件
jitCompiler.initCompiler();

if (mainWindow.init())
{
    // ... 主循环
}

jitCompiler.finiCompiler();
jitCompiler.finiPlugins();        // ← 卸载插件
```

`JITCompiler` 是「即时编译器」——在编辑器运行时按需编译资产，因此插件提供的转换器在
`initPlugins` 后立即可用。

### 6.3 BatchCompiler 集成

```cpp
// batch_compiler/batch_compiler.hpp L13-15
class BatchCompiler : public AssetCompiler
                    , public PluginLoader
{
public:
    BatchCompiler();
    virtual ~BatchCompiler();
    // ...
};
```

调用点（`batch_compiler/batch_compiler.cpp`）：

```cpp
// batch_compiler/batch_compiler.cpp L962-971（节选）
options.apply( bc );
bc.initPlugins();                 // ← 加载插件
bc.initCompiler();
bc.build( options.getInputPaths() );
// ...
bc.finiCompiler();
bc.finiPlugins();                 // ← 卸载插件
BatchCompiler_Locals::batchCompiler_ = NULL;
```

`BatchCompiler` 是「批量编译器」——命令行工具，一次性编译整个工程的资产。集成方式与
JITCompiler 完全对称，体现框架的统一性。

### 6.4 插件侧的 dynamic_cast 协议

插件接收的是 `PluginLoader&`，但实际需要的是宿主更丰富的接口（如注册转换器）。这通过
`dynamic_cast` 实现，是本框架的核心协议：

```cpp
// 以 visual_processor/plugin_main.cpp L28-34 为例
PLUGIN_INIT_FUNC
{
    Compiler * compiler = dynamic_cast< Compiler * >( &pluginLoader );
    if (compiler == NULL)
    {
        return false;   // 宿主不是 Compiler 派生类，拒绝加载
    }

    // 使用 compiler 接口
    const auto & paths = compiler->getResourcePaths();
    bool bInitRes = BWResource::init( paths );
    // ...
    compiler->registerConverter( visualProcessorInfo );
    compiler->registerResourceCallbacks( resourceCallbacks );
    return true;
}
```

`Compiler` 是资产管线的核心抽象基类（见 `asset_pipeline/compiler/compiler.hpp` L24-166），
声明了插件可调用的所有宿主接口：

| 接口 | 用途 |
|------|------|
| `registerConversionRule(rule)` | 注册转换规则（决定哪些文件触发哪个转换器） |
| `registerConverter(info)` | 注册转换器（执行实际的资产转换） |
| `registerResourceCallbacks(cb)` | 注册资源事件回调（增删改通知） |
| `getResourcePaths()` | 获取资源搜索路径 |
| `ensureUpToDate(dep)` | 确保依赖资产最新 |
| `getSourceFile(file)` | 反查资产的源文件 |
| `getHash(dep)` / `getFileHash` / `getDirectoryHash` | 计算依赖/文件/目录的哈希 |
| `setError` / `setWarning` / `hasError` | 错误状态管理 |
| `shouldIterateFile` / `shouldIterateDirectory` | 过滤迭代 |
| `resolveRelativePath` / `resolveSourcePath` / `resolveOutputPath` | 路径解析 |

`dynamic_cast` 要求宿主类至少有一个虚函数（`Compiler` 有虚析构），且启用了 RTTI。这是
MSVC 默认行为，无需特殊编译选项。

> 协议要点：插件若发现 `pluginLoader` 不能转为 `Compiler*`，应返回 `false` 拒绝加载。
> 这让插件具有"自我保护"能力：被错误的宿主加载时不会崩溃。

### 6.5 已注册的转换器插件

通过 `PLUGIN_INIT_FUNC` 搜索，可定位到 9 个实际使用本框架的转换器插件：

| 插件路径 | 文件 | 转换器类型 |
|----------|------|------------|
| `asset_pipeline/converters/visual_processor/` | `plugin_main.cpp` | 可见物（visual）处理 |
| `asset_pipeline/converters/texture_converter/` | `plugin_main.cpp` | 纹理转换 |
| `asset_pipeline/converters/texformat_converter/` | `plugin_main.cpp` | 纹理格式转换 |
| `asset_pipeline/converters/space_converter/` | `plugin_main.cpp` | 空间转换 |
| `asset_pipeline/converters/primitive_processor/` | `plugin_main.cpp` | 图元处理 |
| `asset_pipeline/converters/hierarchical_config_converter/` | `plugin_main.cpp` | 层级配置转换 |
| `asset_pipeline/converters/effect_converter/` | `plugin_main.cpp` | 特效转换 |
| `asset_pipeline/converters/bsp_converter/` | `plugin_main.cpp` | BSP 转换 |
| `asset_pipeline/compiler/test_converter/` | `plugin_main.cpp` | 测试用转换器 |

每个插件的 `plugin_main.cpp` 结构高度一致：
1. 包含 `plugin_system/plugin.hpp` 与 `plugin_system/plugin_loader.hpp`。
2. 包含 `asset_pipeline/compiler/compiler.hpp` 获取 `Compiler` 接口。
3. 定义 `ConverterInfo` 与 `ResourceCallbacks` 全局对象。
4. `PLUGIN_INIT_FUNC` 中 `dynamic_cast<Compiler*>`，初始化资源，注册转换器。
5. `PLUGIN_FINI_FUNC` 中反初始化资源。

这种一致性使得新增一个转换器插件几乎是复制粘贴 + 修改转换逻辑的简单工作。

---

## 7. 配置

### 7.1 插件清单文件

插件清单是一个**纯文本文件**，路径由 `initPlugins` 自动推导：

```
<executableDirectory>/<executableBasename>_plugins.txt
```

例如：
- 可执行文件：`D:\bigworld\bin\batch_compiler.exe`
- 清单文件：`D:\bigworld\bin\batch_compiler_plugins.txt`
- 可执行文件：`D:\bigworld\bin\jit_compiler.exe`
- 清单文件：`D:\bigworld\bin\jit_compiler_plugins.txt`

这意味着同一目录下的不同可执行文件可以加载不同的插件子集——只需为每个可执行文件配备
独立的清单文件。

### 7.2 文件路径解析

`BWUtil::executableDirectory()` 与 `BWUtil::executableBasename()` 的实现
（`lib/cstdmf/bw_util.cpp`）：

```cpp
// bw_util.cpp L104-108
BW::string executableDirectory()
{
    BW_GUARD;
    return BWUtil::getFilePath( BWUtil::executablePath() );
}

// bw_util.cpp L121-124
BW::string executableBasename()
{
    BW::string exePath = BWUtil::executablePath();
    BW::StringRef filename( exePath );
    // ... 提取文件名（去扩展名）
}
```

- `executablePath()`：返回可执行文件的完整路径（通过 `GetModuleFileName` 获取）。
- `executableDirectory()`：取目录部分。
- `executableBasename()`：取文件名部分，去掉 `.exe` 扩展名。

`loadPlugin` 中的路径拼接：

```cpp
// plugin_loader.cpp L50-53
BW::wstring pluginFileName = bw_utf8tow( 
    BWUtil::executableDirectory() + pluginName );
pluginFileName.append(L".dll");
```

插件名（来自清单文件）拼接在可执行文件目录后，再加 `.dll`。这意味着插件 DLL 必须与可
执行文件位于**同一目录**。不支持子目录或绝对路径（除非清单中写入相对路径，但
`istream_iterator` 按空白切分，路径中不能含空格）。

### 7.3 配置文件示例

假设 `batch_compiler_plugins.txt` 内容如下：

```
visual_processor
texture_converter
texformat_converter
space_converter
primitive_processor
hierarchical_config_converter
effect_converter
bsp_converter
```

每行一个插件名（无 `.dll` 扩展名）。`initPlugins` 读取后，对每个名字调用 `loadPlugin`，
最终加载 8 个 DLL：`visual_processor.dll`、`texture_converter.dll` 等。

> 注意：当前实现用 `std::istream_iterator<BW::string>` 读取，按空白分隔，因此：
> - 不支持行内注释（`#` 会被当作插件名）。
> - 不支持空格路径（会被切成两个 token）。
> - 支持 Windows/Unix 换行（C++ 流统一处理）。
> - 空行自动跳过（`istream_iterator` 跳过空白）。

---

## 8. 设计亮点

### 8.1 极简的三文件框架

整个 `plugin_system` 库只有 3 个文件、约 200 行代码（含注释与空行），却支撑了整个资产
管线的 9 个转换器插件。这得益于：
- 不引入 XML/JSON 配置解析，用最朴素的 `istream_iterator` 读文本。
- 不定义复杂的插件接口类，只用 `PluginLoader&` + `dynamic_cast` 协议。
- 不维护依赖图，靠"加载顺序即依赖顺序"的隐式约定。

### 8.2 双向通信的 PluginLoader 引用

`PLUGIN_INIT_FUNC` 的签名是 `bool(PluginLoader&)`，而非 `void()`。这一个引用参数实现了
双向通信：
- **宿主 → 插件**：通过引用传递宿主对象。
- **插件 → 宿主**：插件 `dynamic_cast` 到派生类后调用宿主方法。

这避免了定义庞大的"插件上下文"结构体，让插件接口保持最小化。同时，`dynamic_cast` 失败
的回退（返回 `false`）让插件能优雅地拒绝不兼容的宿主。

### 8.3 Debug/Release 同进程共存

通过 `PLUGIN_INIT`/`PLUGIN_FINI` 宏在 Debug 下加 `_d` 后缀，实现了：
- Debug 宿主只能加载 Debug 插件（查找 `PluginInit_d`）。
- Release 宿主只能加载 Release 插件（查找 `PluginInit`）。
- 误配置时 `GetProcAddress` 返回 NULL，加载失败但进程不崩。

这是用最小的代价（4 行宏）解决 C++ 跨 Debug/Release ABI 兼容性问题的经典做法。

### 8.4 逆序卸载保证依赖正确性

`finiPlugins` 从后往前卸载，符合"后加载者先释放"的资源管理原则。考虑场景：

```
plugin_a.dll  →  PLUGIN_INIT 中注册了全局单例 ServiceX
plugin_b.dll  →  PLUGIN_INIT 中使用了 ServiceX
```

加载顺序 a → b，卸载顺序必须 b → a，否则 b 卸载时访问的 ServiceX 已被 a 释放，触发
use-after-free。逆序卸载天然满足这一约束，无需插件显式声明依赖关系。

### 8.5 失败安全回退

`loadPlugin` 在 `PLUGIN_INIT` 失败时：

```cpp
// plugin_loader.cpp L70-77
PluginFiniFunc pluginFini =
    (PluginFiniFunc) PLUGIN_GET_PROC_ADDRESS( hPlugin, PLUGIN_FINI );

if (pluginFini != NULL)
{
    ( *pluginFini )( *this );
}
::FreeLibrary( hPlugin );
```

会主动调用 `PLUGIN_FINI` 让插件清理已部分初始化的资源，再 `FreeLibrary`。这避免了
"init 执行了一半就失败，但已申请的资源没人释放"的内存/句柄泄漏。

### 8.6 编译期契约的宏

`PLUGIN_INIT_FUNC` 宏把 `extern "C" __declspec(dllexport) bool PLUGIN_INIT(PluginLoader&)`
这一长串签名固化，带来两个好处：
- **签名一致性**：所有插件的 init/fini 函数签名 100% 相同，不会因为手写遗漏 `extern "C"`
  或拼错参数类型导致 `GetProcAddress` 后强转调用崩溃。
- **作者友好**：插件作者只需写 `PLUGIN_INIT_FUNC { ... }`，无需了解 dllexport 细节。

这种"用宏固定跨 DLL 边界签名"的做法在 Win32 插件框架中很常见（如 NVIDIA 的
PhysX SDK、各游戏引擎的插件系统）。

---

## 9. 常见误区与澄清

| 误区 | 澄清 |
|------|------|
| "PluginLoader 是抽象基类，必须实现纯虚函数" | 不是。`PluginLoader` 没有纯虚函数（除析构外），可直接实例化。实际用法是多继承到宿主类。 |
| "插件清单支持 XML 格式" | 不支持。清单是纯文本，每行一个插件名，用 `istream_iterator` 按空白分隔读取。 |
| "插件可以放在任意目录" | 不行。`loadPlugin` 把插件名拼接到 `executableDirectory()` 后，插件 DLL 必须与可执行文件同目录。 |
| "Debug 宿主可以加载 Release 插件" | 不能。Debug 查找 `PluginInit_d`，Release DLL 导出 `PluginInit`，`GetProcAddress` 返回 NULL。这是刻意的 ABI 保护。 |
| "PLUGIN_INIT 返回 false 会导致宿主崩溃" | 不会。`loadPlugin` 检测到 false 后调用 `PLUGIN_FINI`（若存在）清理，再 `FreeLibrary`，返回 NULL。宿主正常继续。 |
| "finiPlugins 按加载顺序卸载" | 相反，**逆序**卸载。从 `plugins_` 末尾向前遍历，保证后加载者先释放。 |
| "插件通过继承 PluginLoader 来集成" | 错。**宿主**继承 PluginLoader；插件只包含 `plugin.hpp` 并实现 `PLUGIN_INIT_FUNC`/`PLUGIN_FINI_FUNC` 两个函数。 |
| "pluginNames() 返回插件名（无扩展名）" | 不是。返回的是 `bw_wtoutf8(pluginFileName)`，即**完整文件名**（含 `.dll`，含可执行文件目录前缀）。 |
| "PLUGIN_GET_PROC_ADDRESS 在 .hpp 和 .cpp 中定义冲突" | 不冲突。`.hpp` 中定义后立即 `#undef`（L44），`.cpp` 中重新定义为自己的版本。两版本效果等价。 |
| "unloadPlugin 找不到句柄会崩溃" | 不会。找不到时循环正常结束，函数返回 `true`（无副作用）。 |
| "插件可以拒绝被卸载" | 可以。`PLUGIN_FINI` 返回 `false` 时，`unloadPlugin` 立即返回 `false`，不调用 `FreeLibrary`。 |
| "支持运行时动态加载新插件" | 支持。`loadPlugin(name)` 是 public，可在任何时机调用；返回 `HMODULE` 表示加载成功。 |

---

## 10. 附录

### 10.1 术语表

| 术语 | 说明 |
|------|------|
| PluginLoader | 插件加载器混入类，宿主通过多继承获得加载/卸载能力 |
| PLUGIN_INIT | 插件初始化函数宏，Release 展开为 `PluginInit`，Debug 为 `PluginInit_d` |
| PLUGIN_FINI | 插件反初始化函数宏，命名规则同上 |
| PLUGIN_INIT_FUNC | 完整的 init 函数声明宏（含 `extern "C" dllexport`） |
| PLUGIN_FINI_FUNC | 完整的 fini 函数声明宏 |
| PluginInitFunc | 函数指针类型 `bool(*)(PluginLoader&)`，对应 PLUGIN_INIT |
| PluginFiniFunc | 函数指针类型，对应 PLUGIN_FINI |
| PLUGIN_GET_PROC_ADDRESS | 取导出符号地址的宏，封装 `GetProcAddress` + 字符串化 |
| PluginList | `BW::vector<HMODULE>` 的别名，存储已加载 DLL 句柄 |
| PluginNameList | `BW::vector<BW::string>` 的别名，存储已加载 DLL 文件名 |
| Compiler | 资产管线核心抽象基类，插件通过 `dynamic_cast` 获取其接口 |
| AssetCompiler | `Compiler` 的派生类，实现了所有纯虚方法 |
| BatchCompiler | 批量编译器，多继承 `AssetCompiler` 与 `PluginLoader` |
| JITCompiler | 即时编译器，多继承 `AssetCompiler`/`AssetServer`/`PluginLoader` 等 |
| ConverterInfo | 转换器元信息结构，插件通过 `registerConverter` 注册 |
| ResourceCallbacks | 资源事件回调结构，插件通过 `registerResourceCallbacks` 注册 |
| _plugins.txt | 插件清单文件，位于可执行文件同目录 |

### 10.2 关键文件行号索引

| 内容 | 文件 | 行号 |
|------|------|------|
| `PLUGIN_INIT`/`PLUGIN_FINI` 宏定义 | `plugin.hpp` | L10-16 |
| `PLUGIN_INIT_FUNC`/`PLUGIN_FINI_FUNC` 宏定义 | `plugin.hpp` | L18-24 |
| `PluginInitFunc`/`PluginFiniFunc` 类型别名 | `plugin_loader.hpp` | L14-15 |
| `PluginLoader` 类声明 | `plugin_loader.hpp` | L17-40 |
| `PluginList`/`PluginNameList` 成员 | `plugin_loader.hpp` | L20, L36-39 |
| `PLUGIN_GET_PROC_ADDRESS` 宏（hpp 版） | `plugin_loader.hpp` | L10 |
| `PLUGIN_GET_PROC_ADDRESS` 宏（cpp 版） | `plugin_loader.cpp` | L8-9 |
| `initPlugins` 实现 | `plugin_loader.cpp` | L13-33 |
| `loadPlugin` 实现 | `plugin_loader.cpp` | L46-80 |
| `unloadPlugin` 实现 | `plugin_loader.cpp` | L82-119 |
| `finiPlugins` 实现 | `plugin_loader.cpp` | L35-44 |
| `pluginNames` 访问器 | `plugin_loader.cpp` | L121-124 |
| 清单文件路径拼接 | `plugin_loader.cpp` | L17-18 |
| 失败回退逻辑 | `plugin_loader.cpp` | L70-77 |
| 逆序卸载循环 | `plugin_loader.cpp` | L39-43 |
| `JITCompiler` 多继承声明 | `jit_compiler/jit_compiler.hpp` | L13-17 |
| `BatchCompiler` 多继承声明 | `batch_compiler/batch_compiler.hpp` | L13-15 |
| `JITCompiler` 调用 `initPlugins` | `jit_compiler/main.cpp` | L68 |
| `JITCompiler` 调用 `finiPlugins` | `jit_compiler/main.cpp` | L96 |
| `BatchCompiler` 调用 `initPlugins` | `batch_compiler/batch_compiler.cpp` | L963 |
| `BatchCompiler` 调用 `finiPlugins` | `batch_compiler/batch_compiler.cpp` | L971 |
| `Compiler` 抽象基类 | `asset_pipeline/compiler/compiler.hpp` | L24-166 |
| `registerConverter` 接口 | `asset_pipeline/compiler/compiler.hpp` | L39 |
| `registerResourceCallbacks` 接口 | `asset_pipeline/compiler/compiler.hpp` | L42 |
| `visual_processor` 插件示例 | `asset_pipeline/converters/visual_processor/plugin_main.cpp` | L28-94 |
| `texture_converter` 插件示例 | `asset_pipeline/converters/texture_converter/plugin_main.cpp` | L24- |
| `BWUtil::executableDirectory` | `lib/cstdmf/bw_util.cpp` | L104-108 |
| `BWUtil::executableBasename` | `lib/cstdmf/bw_util.cpp` | L121-124 |

---

> 本文档基于 BigWorld Engine 14.4.1 源码分析整理，覆盖 `plugin_system` 框架的全部源文
> 件、9 个实际转换器插件与 2 个宿主程序（JITCompiler/BatchCompiler）的集成方式。该框架
> 以极简设计支撑了整个资产管线的可扩展性，是 BigWorld 工具链中"小而美"的典范。
