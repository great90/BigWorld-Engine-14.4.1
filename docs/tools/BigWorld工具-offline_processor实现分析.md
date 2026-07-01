# BigWorld 工具 offline_processor 实现深度分析

> 本文档详细分析 BigWorld Engine 14.4.1 中 `offline_processor` 工具的完整实现。`offline_processor` 是一个**离线数据处理工具**,基于**命令模式(Command Pattern)** 组织多个子命令,主要用于:(1) 离线生成场景的导航网格(navmesh);(2) 升级 BSP(Binary Space Partitioning)数据到最新格式。本文档涵盖入口点、CommandManager 调度、Command/BatchCommand 抽象基类、process-chunks 命令的完整引擎初始化、upgrade-bsp 命令的批量文件处理、OfflineChunkProcessorManager 的 RC4-like 哈希集群分片、ProcessProgress 控制台进度展示的全部细节。

---

## 目录

- [一、概述与定位](#一概述与定位)
- [二、整体架构](#二整体架构)
- [三、目录结构](#三目录结构)
- [四、入口点 main 启动流程](#四入口点-main-启动流程)
- [五、CommandManager 命令管理器](#五commandmanager-命令管理器)
- [六、Command 基类与继承关系](#六command-基类与继承关系)
- [七、BatchCommand 批量处理基类](#七batchcommand-批量处理基类)
- [八、process-chunks 命令详解](#八process-chunks-命令详解)
- [九、upgrade-bsp 命令详解](#九upgrade-bsp-命令详解)
- [十、OfflineChunkProcessorManager 与集群分片](#十offlinechunkprocessormanager-与集群分片)
- [十一、ProcessProgress 进度展示](#十一processprogress-进度展示)
- [十二、配置项与命令行参数](#十二配置项与命令行参数)
- [十三、与其他模块的依赖关系](#十三与其他模块的依赖关系)
- [十四、关键代码片段(带行号)](#十四关键代码片段带行号)
- [十五、设计亮点与注意事项](#十五设计亮点与注意事项)
- [附录 A:两个命令对照表](#附录-a两个命令对照表)
- [附录 B:常见问题澄清](#附录-b常见问题澄清)

---

## 一、概述与定位

### 1.1 工具定位

`offline_processor` 是 BigWorld Technology SDK 提供的一个**离线数据处理工具**。它的核心使命是:

1. 基于**命令模式**组织多个子命令,当前支持两个:
   - `process-chunks`:离线处理场景 chunk,生成导航网格(navmesh);
   - `upgrade-bsp`:升级 `.primitives` 和 `.bsp2` 文件中的 BSP 数据到最新格式;
2. `process-chunks` 命令会**完整初始化 BigWorld 引擎**(BWResource、Moo、D3D、Python、Chunk、Terrain、Water、SpeedTree 等),用于加载场景并生成导航数据;
3. `upgrade-bsp` 命令继承自 `BatchCommand`,支持**批量文件/目录处理**和 `-recursive` 递归;
4. 通过 `OfflineChunkProcessorManager` 支持**集群分片**:多台机器并行处理不同 chunk,使用 RC4-like 哈希决定每个 chunk 归属哪台机器;
5. 通过 `ProcessProgress` 在控制台实时展示**处理进度、剩余时间、内存占用**;
6. 支持 `-nogui`(纯命令行)和 `-unattended`(自动测试)模式。

该工具是一个**Windows GUI 子系统应用**(因 `process-chunks` 需要创建窗口初始化 D3D),但通常以命令行方式运行。

### 1.2 核心特性

| 特性 | 实现方式 | 说明 |
|------|---------|------|
| 命令模式 | `Command` 抽象基类 + `CommandManager` 调度 | 每个子命令一个类 |
| 批量处理 | `BatchCommand` 子类 + `processFiles` 递归 | 支持目录/文件/递归 |
| 引擎初始化 | `InitInstance` 完整初始化 | Moo/Python/Chunk/Terrain |
| 集群分片 | RC4-like `bw_hash` 哈希 | `hash(chunk) % clusterSize == clusterIndex` |
| 进度展示 | `ProcessProgress` + Console API | 实时刷新控制台 |
| 中断处理 | `SetConsoleCtrlHandler` | CTRL+C 优雅终止 |
| 资源系统 | `BWResource::init` + `paths.xml` | 自动查找资源路径 |
| 测试支持 | `CommandManager(testCommandLine)` 构造函数 | 单元测试注入命令行 |
| 调试过滤 | `CommandManagerDebugMessageCallback` | verbose 模式控制日志 |
| 内存监控 | `isMemoryLow` (90% 阈值) | 低内存时卸载 chunk |

### 1.3 版本与规模

- **总代码规模**: 约 1900 行 C++ 代码
- **可执行文件名**: `offline_processor.exe`
- **依赖的关键库**: `BWResource`、`Moo`、`Chunk`、`Terrain`、`physics2/bsp`、`Python`、`SpeedTree`
- **支持的 OS**: 仅 Windows(大量 Win32 API:Console、Window、SetConsoleCtrlHandler)
- **命令数量**: 2 个(process-chunks、upgrade-bsp)

---

## 二、整体架构

### 2.1 模块组成图

```
┌────────────────────────────────────────────────────────────────────┐
│                  offline_processor.exe (GUI 子系统)                │
│                                                                    │
│   ┌──────────────────────┐                                        │
│   │   main (入口)        │  offline_processor_main.cpp L22       │
│   │   创建 CommandManager│                                        │
│   └──────────┬───────────┘                                        │
│              │                                                     │
│              ▼                                                     │
│   ┌──────────────────────────────────────────────────────────┐    │
│   │              CommandManager (调度器)                     │    │
│   │              command_manager.cpp L28                     │    │
│   │              - init() 注册命令          L59              │    │
│   │              - selectCommand() 匹配命令 L118             │    │
│   │              - run() 主流程              L174            │    │
│   │              - DebugMessageCallback     L73              │    │
│   └────────────────────────────┬─────────────────────────────┘    │
│                                │                                   │
│               ┌────────────────┴────────────────┐                  │
│               ▼                                 ▼                  │
│   ┌──────────────────────┐          ┌──────────────────────┐      │
│   │ Command (抽象基类)   │          │ CommandManager       │      │
│   │ command.hpp L18      │          │ DebugMessageCallback │      │
│   │ - strCommand()=0     │          │ - handleMessage()    │      │
│   │ - process()=0        │          │ - verbose_           │      │
│   │ - showHelp()=0       │          └──────────────────────┘      │
│   └──────────┬───────────┘                                         │
│              │ 继承                                                 │
│   ┌──────────┴──────────────────────┐                              │
│   │                                 │                              │
│   ▼                                 ▼                              │
│   ┌──────────────────────┐  ┌──────────────────────┐              │
│   │ BatchCommand         │  │ CommandProcessChunks │              │
│   │ command.hpp L46      │  │ command_process_chunks│              │
│   │ - process() 实现     │  │ - process() 实现     │              │
│   │ - processFile()=0    │  │ - InitInstance       │              │
│   │ - processFiles()     │  │ - ExitInstance       │              │
│   │ - initResourceSystem │  │ - ProcessProgress    │              │
│   └──────────┬───────────┘  └──────────────────────┘              │
│              │ 继承                                                 │
│              ▼                                                      │
│   ┌──────────────────────┐                                         │
│   │ CommandUpgradeBSP    │                                         │
│   │ command_upgrade_bsp  │                                         │
│   │ - processFile() 实现 │                                         │
│   │ - upgrade primitives │                                         │
│   │ - upgrade bsp2       │                                         │
│   └──────────────────────┘                                         │
│                                                                    │
│   ┌──────────────────────────────────────────────────────────────┐ │
│   │              OfflineChunkProcessorManager                    │ │
│   │              offline_chunk_processor_manager.cpp             │ │
│   │              - bw_hash (RC4-like 集群分片)   L23             │ │
│   │              - isChunkEditable               L126            │ │
│   │              - isMemoryLow (90% 阈值)        L71             │ │
│   │              - unloadChunks                  L85             │ │
│   │              - tick (消息泵)                 L107            │ │
│   └──────────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌────────────────────────────────────────────────────────────────────┐
│                      BigWorld 引擎核心                              │
│   ┌─────────────┐  ┌─────────┐  ┌──────────┐  ┌────────────────┐ │
│   │ BWResource  │  │ Moo/D3D │  │ Chunk    │  │ physics2/bsp   │ │
│   │ (资源系统)  │  │ (渲染)  │  │ (场景块) │  │ (BSP 树)       │ │
│   └─────────────┘  └─────────┘  └──────────┘  └────────────────┘ │
│   ┌─────────────┐  ┌─────────┐  ┌──────────┐  ┌────────────────┐ │
│   │ Terrain     │  │ Python  │  │ Water    │  │ SpeedTree      │ │
│   │ (地形系统)  │  │ (脚本)  │  │ (水面)   │  │ (植被)         │ │
│   └─────────────┘  └─────────┘  └──────────┘  └────────────────┘ │
└────────────────────────────────────────────────────────────────────┘
```

### 2.2 命令分派流程图

```
命令行: offline_processor process-chunks -space spaces/highlands -nogui
                │
                ▼
        main() L22
                │
                ▼
   CommandManager manager;        (L25)
   manager.run();                 (L26)
                │
                ▼
   ┌────────────────────────────────┐
   │ CommandManager::run() L174     │
   │ 1. 检查 "help" 参数           │
   │ 2. 检查 "unattended" 参数     │
   │ 3. 设置 verbose 模式          │
   │ 4. selectCommand() 匹配       │
   └────────────┬───────────────────┘
                │
                ▼
   ┌────────────────────────────────┐
   │ selectCommand() L118           │
   │ 遍历 commands_ vector          │
   │ 匹配 strCommand() == 位置参数1 │
   └────────────┬───────────────────┘
                │
        ┌───────┴───────┐
        ▼               ▼
   "process-chunks"  "upgrade-bsp"
        │               │
        ▼               ▼
   CommandProcessChunks  CommandUpgradeBSP
   .process()            .process()
        │               │
        ▼               ▼
   InitInstance +     BatchCommand::process()
   导航网格生成       initResourceSystem +
        │             processFiles 递归
        ▼               │
   ProcessProgress      ▼
   进度展示            processFile 逐文件
                        升级 BSP
```

### 2.3 两种命令对比

```
┌─────────────────────────────────────────────────────────────┐
│                     Command (接口)                          │
│   strCommand() / process() / showHelp()                    │
└────────────────────────┬────────────────────────────────────┘
                         │
    ┌────────────────────┴───────────────────┐
    │                                        │
    ▼                                        ▼
┌────────────────────┐               ┌────────────────────┐
│ CommandProcessChunks│               │ BatchCommand       │
│ (直接继承 Command) │               │ (批量处理基类)     │
└────────────────────┘               └─────────┬──────────┘
    │                                          │ 继承
    │ 实现                                      ▼
    ▼                                   ┌────────────────────┐
• 完整引擎初始化 (InitInstance)         │ CommandUpgradeBSP  │
• 创建 D3D 窗口                         │ (升级 BSP)         │
• OfflineChunkProcessorManager          └────────────────────┘
• 集群分片处理 chunk                    │ 实现
• 进度展示 ProcessProgress              ▼
• 生成导航网格                         • 资源系统初始化
                                       • 递归文件遍历
                                       • .primitives 升级
                                       • .bsp2 升级
```

---

## 三、目录结构

### 3.1 源码目录

```
programming/bigworld/tools/offline_processor/
├── offline_processor_main.cpp     ( 29 行)  最小入口,创建 CommandManager
├── command.hpp                    ( 84 行)  Command + BatchCommand 基类声明
├── command.cpp                    (348 行)  BatchCommand 实现(资源初始化/批量处理)
├── command_manager.hpp            ( 51 行)  CommandManager + DebugCallback 声明
├── command_manager.cpp            (231 行)  CommandManager 实现(调度/帮助/日志)
├── command_process_chunks.hpp     ( 33 行)  CommandProcessChunks 声明
├── command_process_chunks.cpp     (715 行)  process-chunks 命令(最复杂)
├── command_upgrade_bsp.hpp        ( 41 行)  CommandUpgradeBSP 声明
├── command_upgrade_bsp.cpp        (138 行)  upgrade-bsp 命令
├── offline_chunk_processor_manager.hpp  ( 38 行)  管理器声明
├── offline_chunk_processor_manager.cpp  (165 行)  管理器实现(bw_hash/集群)
├── pch.hpp                        (  - )    预编译头
├── resource.h                     (  - )    资源头(IDI_OFFLINE_PROCESSOR)
└── offline_processor.rc           (  - )    资源文件(图标)
```

### 3.2 文件分类

| 类别 | 文件 | 行数 | 职责 |
|------|------|------|------|
| **入口** | offline_processor_main.cpp | 29 | 创建 CommandManager 并运行 |
| **框架核心** | command.hpp | 84 | Command/BatchCommand 抽象基类 |
| **框架核心** | command.cpp | 348 | BatchCommand 批量处理实现 |
| **框架核心** | command_manager.hpp | 51 | CommandManager 调度器声明 |
| **框架核心** | command_manager.cpp | 231 | CommandManager 调度器实现 |
| **具体命令** | command_process_chunks.* | 748 | process-chunks(完整引擎初始化) |
| **具体命令** | command_upgrade_bsp.* | 179 | upgrade-bsp(BSP 格式升级) |
| **管理器** | offline_chunk_processor_manager.* | 203 | 集群分片/内存管理/消息泵 |

---

## 四、入口点 main 启动流程

### 4.1 main 函数

`offline_processor_main.cpp` 是整个工具的入口,极其简洁:

```cpp
// offline_processor_main.cpp L22-28
int main()
{
    BW_SYSTEMSTAGE_MAIN();
    BW_NAMESPACE OfflineProcessor::CommandManager manager;
    bool bSuccess = manager.run();
    return bSuccess ? 0 : 1;
}
```

**关键点**:
- `BW_SYSTEMSTAGE_MAIN()` 标记进入主阶段(调试用);
- 构造 `CommandManager manager` 时,构造函数会调用 `GetCommandLine()` 获取真实命令行;
- `manager.run()` 执行命令分派和处理;
- 返回值 0 表示成功,1 表示失败。

### 4.2 main 之前的全局初始化

在 `main` 函数之前,文件顶部有几个全局宏:

```cpp
// offline_processor_main.cpp L16-20
BW_BEGIN_NAMESPACE
DECLARE_WATCHER_DATA( NULL )
DECLARE_COPY_STACK_INFO( false )
DEFINE_CREATE_EDITOR_PROPERTY_STUB
BW_END_NAMESPACE
```

这些宏定义了调试监视器数据、栈拷贝开关、编辑器属性桩,确保 BigWorld 核心库的全局状态正确初始化。

### 4.3 启动流程时序

```
程序启动
    │
    ▼
全局对象初始化 (DECLARE_WATCHER_DATA 等)
    │
    ▼
main() L22
    │
    ├─► BW_SYSTEMSTAGE_MAIN()
    │
    ├─► CommandManager manager (构造)
    │       │
    │       ├─► applicationCommandLine_(GetCommandLine())  L29
    │       ├─► init()  L59
    │       │       ├─► commands_.push_back(new CommandProcessChunks)
    │       │       ├─► commands_.push_back(new CommandUpgradeBSP)
    │       │       └─► DebugFilter::addMessageCallback
    │       └─► (构造完成)
    │
    ├─► manager.run()  L174
    │       │
    │       ├─► 检查 "help" 参数
    │       ├─► 检查 "unattended" 参数
    │       ├─► 设置 verbose 模式
    │       ├─► selectCommand() 匹配命令
    │       └─► pCommand->process() 执行
    │
    └─► return bSuccess ? 0 : 1
```

---

## 五、CommandManager 命令管理器

### 5.1 类定义

`command_manager.hpp` 定义了核心调度器:

```cpp
// command_manager.hpp L24-48
class CommandManager
{
public:
    CommandManager();
    // alternative constructor for unit tests
    CommandManager( const char *testCommandLine );
    ~CommandManager();

    bool run();

private:
    void showAllSupportedCommands() const;
    void displayHelp( const char* helpCmd ) const;
    void init();
    void fini();

    Command* selectCommand() const;

    typedef BW::vector<Command*> ProcessorCommands;

    ProcessorCommands    commands_;
    CommandLine          applicationCommandLine_;
    CommandManagerDebugMessageCallback debugCallback_;
    bool                 verbose_;
};
```

### 5.2 构造函数

```cpp
// command_manager.cpp L28-34
CommandManager::CommandManager():
applicationCommandLine_( bw_wtoutf8( GetCommandLine() ).c_str() ),
verbose_( false )
{
    this->init();
}
```

**关键**: 使用 `GetCommandLine()` 获取完整的 Windows 命令行(Unicode 转 UTF-8),而非 `main` 的 `argv`。这是因为 `main()` 没有接收 `argc/argv`,所有命令行信息由 `CommandManager` 自行获取。

### 5.3 测试构造函数

```cpp
// command_manager.cpp L41-46
CommandManager::CommandManager(const char *testCommandLine):
    applicationCommandLine_( testCommandLine),
    verbose_( false )
{
    this->init();
}
```

此构造函数接收字符串参数,用于**单元测试**注入命令行,无需依赖真实 `GetCommandLine()`。

### 5.4 init() 命令注册

```cpp
// command_manager.cpp L59-66
void CommandManager::init()
{
    commands_.push_back( new CommandProcessChunks( applicationCommandLine_ ) );
    commands_.push_back( new CommandUpgradeBSP( applicationCommandLine_ ) );

    DebugFilter::instance().addMessageCallback( &debugCallback_ );
}
```

**注册方式**:与 `res_packer` 的 `PackerFactory` 自动注册不同,`offline_processor` 采用**显式 `push_back`**。新增命令需修改 `init()` 函数。这种方式更直观,但开闭原则支持较弱。

### 5.5 selectCommand() 命令匹配

```cpp
// command_manager.cpp L118-130
Command* CommandManager::selectCommand() const
{
    for (ProcessorCommands::const_iterator it = commands_.begin();
        it != commands_.end(); ++it)
    {
        // format is: offline_processor [command] [options]
        if (applicationCommandLine_.hasFullParam( (*it)->strCommand(), 1 ) )
        {
            return *it;
        }
    }
    return NULL;
}
```

**匹配逻辑**:检查命令行的**第 1 个位置参数**(index=1,因 index=0 是程序名)是否等于某命令的 `strCommand()`。匹配成功返回该命令对象,否则返回 NULL。

### 5.6 run() 主流程

```cpp
// command_manager.cpp L174-226
bool CommandManager::run()
{
    // 1. 检查 help 参数
    const char* helpCmd = applicationCommandLine_.getFullParam( "help");
    if (helpCmd)
    {
        this->displayHelp( helpCmd );
        return true;
    }

    // 2. 检查 unattended 模式
    const char* unattendedCmd = applicationCommandLine_.getFullParam( "unattended");
    if (unattendedCmd)
    {
        CStdMf::checkUnattended();
    }

    // 3. 设置 verbose 日志模式
    this->debugCallback_.verbose_ = applicationCommandLine_.hasParam("verbose");
    DebugMessagePriority previousThreshold = DebugFilter::instance().filterThreshold();
    if (this->debugCallback_.verbose_)
    {
        DebugFilter::instance().filterThreshold( MESSAGE_PRIORITY_TRACE );
    }

    // 4. 选择并执行命令
    bool bRes = true;
    Command* pCommand = this->selectCommand();
    if (pCommand)
    {
        bRes = pCommand->process();
    }
    else
    {
        bRes = false;
        const char* cmd = applicationCommandLine_.getParamByIndex( 1 );
        if (cmd != NULL && strlen(cmd) > 0)
        {
            ERROR_MSG("[CommandManager::run()] ERROR: Cannot recognise command %s\n", cmd);
        }
        this->showAllSupportedCommands();
    }

    // 5. 恢复日志阈值
    DebugFilter::instance().filterThreshold(previousThreshold);

    return bRes;
}
```

### 5.7 DebugMessageCallback 日志过滤

```cpp
// command_manager.cpp L73-112
bool CommandManagerDebugMessageCallback::handleMessage(
        DebugMessagePriority messagePriority, const char * pCategory,
        DebugMessageSource /*messageSource*/, const LogMetaData & /*metaData*/,
        const char * pFormat, va_list argPtr )
{
    // only filter out trace messages or lower priority
    if (messagePriority <= MESSAGE_PRIORITY_TRACE)
    {
        if (verbose_)
        {
            // 发送 CommandManager & ConvertTextureTask 类别到控制台
            if (pCategory &&
                ((strcmp( pCategory, "CommandManager") == 0) ||
                    (strcmp( pCategory, "ConvertTextureTask") == 0)))
            {
                const char * pPriorityName = messagePrefix( messagePriority );
                fprintf( DebugFilter::consoleOutputFile(), "%s: ", pPriorityName );
                fprintf( DebugFilter::consoleOutputFile(), "[%s] ", pCategory );
                vfprintf( DebugFilter::consoleOutputFile(), pFormat, argPtr );
            }
            return false; // 继续处理
        }
        else
        {
            return true; // 吞掉消息(非 verbose 模式)
        }
    }
    return false; // 非 TRACE 消息继续处理
}
```

**设计**:默认情况下,TRACE 级别日志被吞掉(返回 true 表示已处理,不再传播)。`-verbose` 模式下,CommandManager 和 ConvertTextureTask 类别的 TRACE 日志输出到控制台。

### 5.8 showAllSupportedCommands 帮助

```cpp
// command_manager.cpp L135-152
void CommandManager::showAllSupportedCommands() const
{
    std::cout << "BigWorld offline processor" << std::endl << std::endl;
    std::cout << "Usage: offline_processor [command] [options]" << std::endl << std::endl;
    std::cout << "Commands:" << std::endl << std::endl;

    for (ProcessorCommands::const_iterator it = commands_.begin();
        it != commands_.end(); ++it)
    {
        (*it)->showShortHelp();
        std::cout << std::endl;
    }

    std::cout << "help\t\t\tShow this help" << std::endl << std::endl;
    std::cout << "Use offline_processor help [command]";
    std::cout <<" for detailed help" << std::endl;
}
```

---

## 六、Command 基类与继承关系

### 6.1 类继承图

```
                    ┌─────────────────────────────────┐
                    │   Command (抽象基类)             │
                    │   command.hpp L18               │
                    │   - strCommand() = 0            │
                    │   - process() = 0               │
                    │   - showDetailedHelp() = 0      │
                    │   - showShortHelp() = 0         │
                    │   - initCommand()/finiCommand() │
                    │   # commandLine_ (引用)          │
                    └────────────┬────────────────────┘
                                 │ 公有继承
                ┌────────────────┴────────────────┐
                │                                 │
                ▼                                 ▼
    ┌──────────────────────┐          ┌──────────────────────┐
    │ BatchCommand         │          │ CommandProcessChunks │
    │ command.hpp L46      │          │ 直接继承 Command     │
    │ - process() 已实现   │          │ - process() 实现     │
    │ - processFile()=0    │          │ - 完整引擎初始化     │
    │ - processFiles()     │          │ - 集群处理 chunk     │
    │ - initResourceSystem │          └──────────────────────┘
    │ # allowMissingFiles_ │
    │ # numErrors_         │
    └──────────┬───────────┘
               │ 公有继承
               ▼
    ┌──────────────────────┐
    │ CommandUpgradeBSP    │
    │ - processFile() 实现 │
    │ - upgrade primitives │
    │ - upgrade bsp2       │
    └──────────────────────┘
```

### 6.2 Command 抽象基类

```cpp
// command.hpp L18-34
class Command
{
public:
    Command( const CommandLine& commandLine );
    virtual ~Command() {}

    virtual bool initCommand() { return true; }
    virtual void finiCommand() {}

    virtual const char* strCommand() const = 0;
    virtual void showDetailedHelp() const = 0;
    virtual void showShortHelp() const = 0;
    virtual bool process() = 0;

protected:
    const CommandLine& commandLine_;
};
```

**方法语义**:

| 方法 | 类型 | 职责 |
|------|------|------|
| `initCommand()` | 虚(默认 true) | 命令初始化(BatchCommand::process 调用) |
| `finiCommand()` | 虚(默认空) | 命令清理(BatchCommand::process 调用) |
| `strCommand()` | 纯虚 | 返回命令名(如 "process-chunks") |
| `showDetailedHelp()` | 纯虚 | 显示详细帮助 |
| `showShortHelp()` | 纯虚 | 显示简短帮助 |
| `process()` | 纯虚 | 执行命令 |

### 6.3 为什么有两个继承分支?

`Command` 有两个直接/间接子类:
- **CommandProcessChunks** 直接继承 `Command`:因为 `process-chunks` 不处理单个文件,而是处理整个场景空间(space),流程复杂(引擎初始化、集群分片、进度展示),不适合用 `BatchCommand` 的通用批量框架。
- **CommandUpgradeBSP** 继承 `BatchCommand`:因为 `upgrade-bsp` 是**逐文件处理**,天然适合 `BatchCommand` 的 `processFiles` 递归框架。

---

## 七、BatchCommand 批量处理基类

### 7.1 类定义

```cpp
// command.hpp L46-79
class BatchCommand : public Command
{
public:
    BatchCommand( const CommandLine& commandLine,
                  bool allowMissingFiles = false );
    virtual ~BatchCommand() {}

    enum FileProcessResult
    {
        RESULT_SUCCESS,
        RESULT_FAILURE,
        RESULT_UNSUPPORTED_FILE
    };

    virtual bool process();
    virtual FileProcessResult processFile( const BW::string& fileName,
                                           const BW::string& outFileName = "" ) = 0;

    int numErrors() const { return numErrors_; }

protected:
    enum ResourceSystemInitResult
    {
        RES_INIT_SUCCESS_FILE,
        RES_INIT_SUCCESS_DIRECTORY,
        RES_INIT_FAILED
    };
    ResourceSystemInitResult initResourceSystem( const BW::string& fileName );
    int processFiles( const BW::string& fileName, bool processRecursively,
                      const BW::string& outFileName );

    bool allowMisssingFiles_;
    int  numErrors_;
};
```

### 7.2 BatchCommand::process() 主流程

`command.cpp L231-344` 实现了通用的批量处理流程:

```cpp
// command.cpp L231-344 (简化)
bool BatchCommand::process()
{
    // 1. 获取命令路径参数(第1个位置参数)
    BW::string path(commandLine_.getFullParam( strCommand(), 1 ));
    BW::string outPath;
    if (commandLine_.size() > 3 && commandLine_.hasParam( "output" ))
        outPath = commandLine_.getParam( "output" );

    // 2. 参数校验
    bool bCommandParamValid = path.length() > 0 && !CommandLine::hasSwitch( path.c_str() );
    bool processRecursively = commandLine_.hasParam("recursive");

    if (!bCommandParamValid && processRecursively)
    {
        path = "."; // -recursive 可省略路径,默认当前目录
        bCommandParamValid = true;
    }
    if (!bCommandParamValid)
    {
        this->showDetailedHelp();
        return false;
    }

    // 3. 初始化资源系统
    ResourceSystemInitResult resInit = initResourceSystem( path );

    // 4. 解析输出路径为绝对路径
    if (!outPath.empty() && BWResource::pathIsRelative( outPath ))
    {
        // 逐步截取路径,找到已存在的父目录,拼接出绝对路径
        // ...
        BWResource::ensureAbsolutePathExists( outPath );
    }

    // 5. 执行批量处理
    int numFilesProcessed = 0;
    if (resInit != RES_INIT_FAILED)
    {
        if (this->initCommand())
        {
            path = BWResource::dissolveFilename( path ); // 转为相对路径
            numFilesProcessed = this->processFiles( path, processRecursively, outPath );
            this->finiCommand();
        }
    }
    else
    {
        ERROR_MSG("[OfflineProcessor] ERROR: Can' find path %s.\n", path.c_str());
        numErrors_ = 1;
    }

    // 6. 输出统计
    TRACE_MSG("%d files processed.\n", numFilesProcessed);
    TRACE_MSG("%d error (s).\n", numErrors_);
    if (resInit == RES_INIT_SUCCESS_DIRECTORY && numFilesProcessed == 0 && !processRecursively)
        TRACE_MSG("Did you forget to add -recursive option ?\n");

    BWResource::fini();
    return numErrors_ == 0;
}
```

### 7.3 initResourceSystem() 资源系统初始化

```cpp
// command.cpp L40-134 (简化)
BatchCommand::ResourceSystemInitResult BatchCommand::initResourceSystem( const BW::string& fileName )
{
    // 1. 加载 paths.xml(不传命令行路径参数)
    const char* cmdLine[] = { "" };
    if (!BWResource::init( 1, cmdLine, false ))
        return RES_INIT_FAILED;

    // 2. 检测文件/目录类型
    MultiFileSystem* fs = BWResource::instance().fileSystem();
    BW::string resName = fileName;
    IFileSystem::FileType ft = fs->getFileType( resName );

    // 3. 相对路径回退到当前目录查找
    if (ft == IFileSystem::FT_NOT_FOUND && BWResource::pathIsRelative( resName ))
    {
        BW::string resNameCurrentDir = BWResource::getCurrentDirectory() + resName;
        ft = fs->getFileType( resNameCurrentDir );
        if (ft != IFileSystem::FT_NOT_FOUND)
            resName = resNameCurrentDir;
    }

    // 4. 根据类型返回结果
    ResourceSystemInitResult res = RES_INIT_FAILED;
    if (ft == IFileSystem::FT_FILE)
    {
        res = RES_INIT_SUCCESS_FILE;
        resName = BWResource::getFilePath( resName ); // 取目录部分
    }
    else if (ft == IFileSystem::FT_DIRECTORY)
    {
        res = RES_INIT_SUCCESS_DIRECTORY;
    }
    else if (ft == IFileSystem::FT_NOT_FOUND && allowMisssingFiles_)
    {
        res = RES_INIT_SUCCESS_FILE;
        resName = BWResource::getFilePath( resName );
    }
    else
        return RES_INIT_FAILED;

    // 5. 若路径不在已知 paths 中,添加之
    BW::string relatvefilename = BWResource::instance().dissolveFilename( resName );
    if (relatvefilename == "")
        BWResource::addPath( resName );

    // 6. 客户端加载 resources.xml
#ifndef MF_SERVER
    if ( !AutoConfig::configureAllFrom( "resources.xml" ) )
        ERROR_MSG("Couldn't load auto-config strings from resource.xml\n");
#endif
    return res;
}
```

### 7.4 processFiles() 递归文件处理

```cpp
// command.cpp L149-222
int BatchCommand::processFiles( const BW::string& fileName,
                                bool processRecursively,
                                const BW::string& outFileName )
{
    int numFilesProcessed = 0;
    MultiFileSystem* fs = BWResource::instance().fileSystem();
    IFileSystem::FileType ft = fs->getFileType( fileName, NULL );

    if (ft == IFileSystem::FT_FILE ||
        (ft == IFileSystem::FT_NOT_FOUND && allowMisssingFiles_))
    {
        // 单文件:直接处理
        FileProcessResult pr = this->processFile( fileName, outFileName );
        if (pr == RESULT_SUCCESS) numFilesProcessed++;
        else if (pr == RESULT_FAILURE) numErrors_++;
    }
    else
    {
        // 目录:遍历所有子项
        IFileSystem::Directory dirList;
        fs->readDirectory( dirList, fileName );

        for (IFileSystem::Directory::iterator it = dirList.begin();
            it != dirList.end(); ++it)
        {
            BW::string subName = BWUtil::formatPath( fileName ) + (*it);
            // 去除 "./" 前缀
            const char * rootPrefix = "./";
            if (strncmp(subName.c_str(), rootPrefix, strlen(rootPrefix)) == 0)
                subName = subName.substr( strlen(rootPrefix), subName.length() );

            bool bIsDirectory = (fs->getFileType( subName, NULL ) == IFileSystem::FT_DIRECTORY);

            if (processRecursively && bIsDirectory)
            {
                // 递归处理子目录
                BW::string outPathName = outFileName;
                if (!outPathName.empty())
                {
                    outPathName += (*it);
                    outPathName = BWResource::formatPath( outPathName );
                }
                numFilesProcessed += this->processFiles( subName, processRecursively, outPathName );
            }
            else if (!bIsDirectory)
            {
                // 处理文件
                BWResource::ensureAbsolutePathExists(outFileName);
                FileProcessResult pr = this->processFile( subName, outFileName );
                if (pr == RESULT_SUCCESS) numFilesProcessed++;
                else if (pr == RESULT_FAILURE) numErrors_++;
            }
        }
    }
    return numFilesProcessed;
}
```

**关键设计**:
- `RESULT_UNSUPPORTED_FILE` 返回值不会增加 `numErrors_`,允许 Packer 跳过不支持的扩展名;
- `-recursive` 标志控制是否递归子目录;
- 输出路径会镜像输入目录结构。

---

## 八、process-chunks 命令详解

### 8.1 命令声明

```cpp
// command_process_chunks.hpp L16-28
class CommandProcessChunks : public Command
{
public:
    CommandProcessChunks( const CommandLine& commandLine );
    virtual ~CommandProcessChunks();

    virtual const char* strCommand() const { return "process-chunks"; };

    virtual void showDetailedHelp() const;
    virtual void showShortHelp() const;

    virtual bool process();
};
```

### 8.2 帮助信息

```cpp
// command_process_chunks.cpp L86-97
void CommandProcessChunks::showDetailedHelp() const
{
    std::cout << "Usage: offline_processor " << strCommand() << " [options]" << std::endl;
    std::cout << "Runs offline chunk processing generating navigation data:" << std::endl;
    std::cout << "Options:" << std::endl;
    std::cout << "\t-space <space path>\t\tProcess the given space" << std::endl;
    std::cout << "\t-cluster-index <cluster index>\tSet the computer index in cluster" << std::endl;
    std::cout << "\t-cluster-size <cluster size>\tSet the number of computers in cluster" << std::endl;
    std::cout << "\t-overwrite\t\t\tOverwrite all existing generated data" << std::endl;
    std::cout << "\t-nogui\t\t\t\tDisplay no GUI" << std::endl;
    std::cout << "\t-unattended\t\t\tRun offline_processor in autotest mode" << std::endl;
}
```

### 8.3 process() 主流程

`command_process_chunks.cpp L422-548` 实现了完整的处理流程:

```cpp
// command_process_chunks.cpp L422-548 (简化)
bool CommandProcessChunks::process()
{
    int exitCode = 1;
    unsigned int clusterSize = 1;
    unsigned int clusterIndex = 0;

    // 1. 解析集群参数
    if (commandLine_.hasParam( "cluster-index" ) &&
        commandLine_.hasParam( "cluster-size" ))
    {
        clusterSize = std::max<unsigned int>(atoi(commandLine_.getParam( "cluster-index" )), 1);
        clusterIndex = std::min<unsigned int>(atoi(commandLine_.getParam( "cluster-size" )), clusterSize - 1);
    }

    // 2. 注册窗口类并初始化实例
    MyRegisterClass( (HINSTANCE)GetModuleHandle( NULL ) );
    if (!InitInstance( (HINSTANCE)GetModuleHandle( NULL ) ))
        return FALSE;

    // 3. 注册控制台 CTRL+C 处理
    SetConsoleCtrlHandler( consoleCtrlHandler, TRUE );

    // 4. 创建处理器管理器(含集群分片)
    CpuInfo cpuInfo;
    OfflineChunkProcessorManager processorManager(
        cpuInfo.numberOfSystemCores(), clusterSize, clusterIndex );

    // 5. 获取 space 路径
    BW::string space = commandLine_.getParam( "space" );
    bool nogui = commandLine_.hasParam( "nogui" );

    // 6. GUI 模式下浏览选择 space
    if (space.empty() && !nogui)
    {
        BW::wstring wpath = bw_utf8tow( BWResolver::resolveFilename( "spaces/highlands" ) );
        // ... GetFullPathName 解析 ...
        space = SpaceNameManager::browseForSpaces( g_hWnd, wpath );
        if (!space.empty())
            space = BWResolver::dissolveFilename( space );
    }

    // 7. 打开 space.settings
    DataSectionPtr spaceSettings = BWResource::openSection( space + "/space.settings" );

    if (!space.empty() && spaceSettings != NULL)
    {
        disableConsoleCursor();
        ensureVisible( 7 );

        // 8. 初始化处理器
        processorManager.init( space );

        ChunkSaver chunkSaver;
        CdataSaver thumbnailSaver;
        bool quitting = false;

        // 9. 检查 navmeshGenerator 必须为 "recast"
        BW::string navmeshGenerator = spaceSettings->readString( "navmeshGenerator" );
        if (navmeshGenerator != "recast")
        {
            // 报错:仅支持 recast
            ExitInstance();
            return 1;
        }

        // 10. -overwrite 模式:失效所有 chunk
        if (commandLine_.hasParam( "overwrite" ))
        {
            quitting = !processorManager.invalidateAllChunks(
                processorManager.geometryMapping(), &g_processProgress, true);
        }

        // 11. 保存(处理)所有 chunk
        if (!quitting)
        {
            exitCode = !processorManager.saveChunks(
                processorManager.geometryMapping()->gatherChunks(),
                chunkSaver, thumbnailSaver, &g_processProgress, true);
        }

        processorManager.stopAll();
        clearConsoleOutput();
        enableConsoleCursor();
    }
    else
    {
        // 报错:未指定 space 或无法打开
    }

    ExitInstance();
    return exitCode == 0;
}
```

### 8.4 InitInstance 完整引擎初始化

`command_process_chunks.cpp L568-682` 是整个工具最复杂的初始化函数,完整初始化 BigWorld 引擎:

```cpp
// command_process_chunks.cpp L568-682 (关键步骤)
BOOL InitInstance( HINSTANCE hInstance )
{
    // 1. 创建隐藏窗口
    g_hWnd = CreateWindow( _T("BWOPCLASS"), _T("BigWorld Offline Processor"),
        WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, 0, CW_USEDEFAULT, 0, ...);

    // 2. 初始化 BWResource
    BWResource* bwResource = new BWResource();
    BWResource::init( args, NULL );

    // 3. 加载语言文件
    StringProvider::instance().load( BWResource::openSection("helpers/languages/files_en.xml") );
    StringProvider::instance().setLanguage();

    // 4. 初始化 Options
    Options::init( 0, 0, L"offlineprocessor.options" );

    // 5. 初始化 Moo (渲染系统)
    Moo::init();

    // 6. 初始化后台任务管理器
    new AmortiseChunkItemDelete();
    BgTaskManager::init();
    BgTaskManager::instance().startThreads( "InitInstance", 1 );
    FileIOTaskManager::init();
    FileIOTaskManager::instance().startThreads( "FileIOTaskManager", 1 );

    // 7. 初始化输入设备
    InputDevices * pInputDevices = new InputDevices();
    InputDevices::instance().init( hInstance, g_hWnd );

    // 8. 加载 resources.xml
    AutoConfig::configureAllFrom( "resources.xml" );

    // 9. 加载 engine_config.xml
    DataSectionPtr configRoot = BWResource::instance().openSection( s_engineConfigXML.value() );
    XMLSection::shouldReadXMLAttributes( configRoot->readBool(...) );
    XMLSection::shouldWriteXMLAttributes( configRoot->readBool(...) );

    // 10. 关闭水面背景加载
    Water::backgroundLoad( false );

    // 11. 初始化 Python
    PyImportPaths paths;
    paths.addResPath( BWResolver::resolveFilename( EntityDef::Constants::entitiesEditorPath() ) );
    Script::init( paths );

    // 12. 初始化 MaterialKinds
    MaterialKinds::init();

    // 13. 创建 D3D 设备
    Moo::TextureManager::init();
    Moo::rc().createDevice( g_hWnd );

    // 14. 初始化水面/SpeedTree/地形/环境
    Waters::instance().init();
    speedtree::SpeedTreeRenderer::enviroMinderLighting( false );
    s_pTerrainManager = TerrainManagerPtr( new Terrain::Manager() );
    s_pTextureFeeds = TextureFeedsPtr( new TextureFeeds() );
    s_pLensEffectManager = LensEffectManagerPtr( new LensEffectManager() );
    ChunkManager::instance().init();
    EnviroMinder::init();

    // 15. 地形同步加载
    Terrain::ResourceBase::defaultStreamType( Terrain::RST_Syncronous );

    // 16. 禁用 chunk 扫描
    ChunkManager::instance().disableScan();

    return TRUE;
}
```

**初始化顺序的重要性**:
1. `BWResource` 必须最先初始化(其他模块依赖资源路径);
2. `Moo::init()` 必须在 `Moo::rc().createDevice()` 之前;
3. `BgTaskManager` 必须在 `ChunkManager` 之前(chunk 异步加载依赖后台线程);
4. `Script::init`(Python)必须在 `ChunkManager::init` 之前(chunk item 可能引用 Python);
5. `Terrain::Manager` 必须在 `ChunkManager::init` 之前(terrain chunk 依赖)。

### 8.5 ExitInstance 清理

```cpp
// command_process_chunks.cpp L685-696
void ExitInstance()
{
    BgTaskManager::instance().stopAll();
    ChunkManager::instance().tick( 0.f );
    ChunkManager::instance().fini();
    MaterialKinds::fini();
    Script::fini();
    s_pTextureFeeds.reset();
    s_pTerrainManager.reset();
    s_pLensEffectManager.reset();
}
```

### 8.6 navmeshGenerator 限制

```cpp
// command_process_chunks.cpp L492-510
BW::string navmeshGenerator = spaceSettings->readString( "navmeshGenerator" );
if (navmeshGenerator != "recast")
{
    BW::wstring errorMsg = L"The navmeshGenerator specified in space.settings is not supported.\n";
    errorMsg += L"offline_processor supports \"recast\" only.";
    if (!nogui)
        MessageBox( g_hWnd, errorMsg.c_str(), L"Warning", MB_OK | MB_ICONWARNING );
    else
        std::cerr << "The navmeshGenerator specified in space.settings is not supported."
                     "offline_processor supports \"recast\" only." << std::endl;
    ExitInstance();
    return 1;
}
```

**限制**: `offline_processor` 仅支持 `recast` 导航网格生成器。若 `space.settings` 中指定其他生成器,直接报错退出。

---

## 九、upgrade-bsp 命令详解

### 9.1 命令声明

```cpp
// command_upgrade_bsp.hpp L19-35
class CommandUpgradeBSP : public BatchCommand
{
public:
    CommandUpgradeBSP( const CommandLine& commandLine );
    virtual ~CommandUpgradeBSP();

    virtual const char* strCommand() const { return "upgrade-bsp"; };

    virtual void showDetailedHelp() const;
    virtual void showShortHelp() const;

    virtual FileProcessResult processFile( const BW::string& fileName,
                                           const BW::string& outFileName = "" );

private:
    bool doFormatUpgradeBSPInPrimitives( const BW::string& primName );
    bool doFormatUpgradeStandaloneBSPFile( const BW::string& bspName );
};
```

### 9.2 帮助信息

```cpp
// command_upgrade_bsp.cpp L23-32
void CommandUpgradeBSP::showDetailedHelp() const
{
    std::cout << "Usage: offline_processor " << strCommand();
    std::cout << " [file] [options]" << std::endl;
    std::cout << "Loads and saves bsp data upgrading it to the latest format:" << std::endl;
    std::cout << "[file] name can be a folder name" << std::endl;
    std::cout << "Options:" << std::endl;
    std::cout << "\t-recursive\t\tProcess all files recursively starting from the given folder." << std::endl;
}
```

### 9.3 processFile 文件分派

```cpp
// command_upgrade_bsp.cpp L120-134
BatchCommand::FileProcessResult
CommandUpgradeBSP::processFile( const BW::string& fileName, const BW::string& outFileName )
{
    const BW::string disFileName = BWResolver::dissolveFilename( fileName );
    BW::StringRef ext = BWResource::getExtension( disFileName );
    if (ext == "primitives")
    {
        return doFormatUpgradeBSPInPrimitives( disFileName ) ? RESULT_SUCCESS : RESULT_FAILURE;
    }
    else if (ext == "bsp2" )
    {
        return doFormatUpgradeStandaloneBSPFile( disFileName ) ? RESULT_SUCCESS : RESULT_FAILURE;
    }
    return RESULT_UNSUPPORTED_FILE;
}
```

**关键**: 不支持的扩展名返回 `RESULT_UNSUPPORTED_FILE`,不会被计入错误,允许批量处理时跳过无关文件。

### 9.4 升级 .primitives 中的 BSP

```cpp
// command_upgrade_bsp.cpp L46-89
bool CommandUpgradeBSP::doFormatUpgradeBSPInPrimitives( const BW::string& primName )
{
    DataSectionPtr primDS = BWResource::openSection( primName );
    if (!primDS)
    {
        std::cerr << "ERROR: Unable to open primitives " << primName << std::endl;
        return false;
    }

    // 读取 bsp2 段
    BinaryPtr bp = primDS->readBinary( "bsp2" );
    if (!bp)
    {
        // primitives 可能不含 bsp 段,这不是错误
        return true;
    }

    // 加载 BSP 树
    BSPTree* pBSP = BSPTreeTool::loadBSP( bp );
    if (!pBSP)
    {
        std::cerr << "ERROR: Can't load bsp for " << primName << std::endl;
        return false;
    }

    // 重新保存到内存
    bp = BSPTreeTool::saveBSPInMemory( pBSP );
    bw_safe_delete( pBSP );
    MF_ASSERT( bp );

    // 写回 primitives 文件
    bool bRes = primDS->writeBinary( "bsp2", bp );
    if (!bRes) { std::cerr << "ERROR: Failed to write regenerated bsp\n"; return false; }

    // 保存文件
    bRes = primDS->save( primName );
    if (!bRes) { std::cerr << "ERROR: Failed to save regenerated bsp\n"; return false; }

    std::cout << "regenerating bsp in " << primName << std::endl;
    return true;
}
```

### 9.5 升级独立 .bsp2 文件

```cpp
// command_upgrade_bsp.cpp L94-115
bool CommandUpgradeBSP::doFormatUpgradeStandaloneBSPFile( const BW::string& bspName )
{
    DataSectionPtr bspSect = BWResource::openSection( bspName );
    if (!bspSect.exists())
    {
        std::cout << "ERROR: Could not load BSP section from " << bspName << std::endl;
        return false;
    }

    BinaryPtr bp = bspSect->asBinary();
    if (!bp.exists())
    {
        std::cout << "ERROR: Could not load BSP data from file " << bspName << std::endl;
        return false;
    }

    BSPTree* pBSP = BSPTreeTool::loadBSP( bp );
    BSPTreeTool::saveBSPInFile( pBSP, bspName.c_str() );
    bw_safe_delete( pBSP );
    std::cout << "regenerating bsp in " << bspName << std::endl;
    return true;
}
```

### 9.6 BSP 升级原理

BSP 格式升级的核心是"**加载-保存**":旧格式的 BSP 数据通过 `BSPTreeTool::loadBSP` 加载到内存中的 `BSPTree` 对象,再用 `saveBSPInMemory`/`saveBSPInFile` 以最新格式保存。这要求 BSP 格式向后兼容(新版本能读取旧版本数据)。

---

## 十、OfflineChunkProcessorManager 与集群分片

### 10.1 类定义

```cpp
// offline_chunk_processor_manager.hpp L10-34
class OfflineChunkProcessorManager :
    public ChunkProcessorManager,
    public SpaceEditor
{
    GeometryMapping* mapping_;
    unsigned int clusterSize_;
    unsigned int clusterIndex_;
    bool terminated_;

    virtual bool isMemoryLow( bool testNow = false ) const;
    virtual void unloadChunks();
    virtual bool tick();
    virtual bool isChunkEditable( const BW::string& chunk ) const;

public:
    OfflineChunkProcessorManager( int numThread,
        unsigned int clusterSize, unsigned int clusterIndex );

    void init( const BW::string& spaceDir );
    void fini();
    void terminate() { terminated_ = true; }

    virtual GeometryMapping* geometryMapping() { return mapping_; }
    virtual const GeometryMapping* geometryMapping() const { return mapping_; };
};
```

**多重继承**: 继承 `ChunkProcessorManager`(处理逻辑)和 `SpaceEditor`(空间编辑接口),复用引擎的 chunk 处理框架。

### 10.2 bw_hash RC4-like 哈希函数

```cpp
// offline_chunk_processor_manager.cpp L23-51
unsigned int bw_hash( const char* str )
{
    BW_GUARD;

    static unsigned char hash[ 256 ];
    static bool inithash = true;
    if (inithash)
    {
        inithash = false;
        // 初始化 hash 表:hash[i] = i
        for( int i = 0; i < 256; ++i )
            hash[ i ] = i;
        // RC4-like KSA(密钥调度算法),k=7 作为"密钥"
        int k = 7;
        for( int j = 0; j < 4; ++j )
            for( int i = 0; i < 256; ++i )
            {
                unsigned char s = hash[ i ];
                k = ( k + s ) % 256;
                hash[ i ] = hash[ k ];
                hash[ k ] = s;
            }
    }
    // 计算哈希值
    unsigned char result = ( 123 + strlen( str ) ) % 256;
    for( unsigned int i = 0; i < strlen( str ); ++i )
    {
        result = ( result + str[ i ] ) % 256;
        result = hash[ result ];
    }
    return result;
}
```

**算法分析**:
1. **KSA 阶段**:类似 RC4 的密钥调度,用固定"密钥" k=7 打乱 256 字节的 hash 表,迭代 4 轮增强混淆;
2. **哈希阶段**:初始值 `(123 + strlen) % 256`(123 是魔数),逐字节累加并通过 hash 表置换;
3. **结果**:返回 0-255 的哈希值,用于 `% clusterSize` 分片。

**设计目的**:将 chunk 名称均匀分布到 [0, clusterSize) 区间,使多台机器能并行处理不同的 chunk,避免重复。RC4-like 的置换表保证了良好的分布性。

### 10.3 isChunkEditable 集群分片判断

```cpp
// offline_chunk_processor_manager.cpp L126-129
bool OfflineChunkProcessorManager::isChunkEditable( const BW::string& chunk ) const
{
    return bw_hash( chunk.c_str() ) % clusterSize_ == clusterIndex_;
}
```

**分片逻辑**: `bw_hash(chunkName) % clusterSize == clusterIndex` 决定该 chunk 是否由当前机器处理。例如:
- `clusterSize=4, clusterIndex=2`:处理哈希值 mod 4 == 2 的 chunk;
- 4 台机器分别处理 mod 0/1/2/3 的 chunk,无重叠且覆盖全部。

### 10.4 构造函数

```cpp
// offline_chunk_processor_manager.cpp L132-145
OfflineChunkProcessorManager::OfflineChunkProcessorManager(
    int numThread, unsigned int clusterSize, unsigned int clusterIndex )
    : ChunkProcessorManager( numThread ), mapping_ ( NULL ),
    clusterSize_( clusterSize ), clusterIndex_( clusterIndex ),
    terminated_( false )
{
    MF_ASSERT( !gProcessorManager_ );  // 单例断言

    gProcessorManager_ = this;
    SetConsoleCtrlHandler( ConsoleHandlerRoutine, TRUE );  // 注册 CTRL+C

    SpaceEditor::instance( this );  // 设置 SpaceEditor 单例
}
```

### 10.5 init 空间初始化

```cpp
// offline_chunk_processor_manager.cpp L148-159
void OfflineChunkProcessorManager::init( const BW::string& spaceDir )
{
    fini();

    ChunkSpacePtr chunkSpace = ChunkManager::instance().space( 1 );
    const Matrix& identityMtx = Matrix::identity;

    mapping_ = chunkSpace->addMapping( SpaceEntryID(), (float*)&identityMtx, spaceDir );
    chunkSpace->terrainSettings()->defaultHeightMapLod( 0 );
    ChunkManager::instance().camera( Matrix::identity, chunkSpace );
    this->ChunkProcessorManager::onChangeSpace();
}
```

### 10.6 isMemoryLow 内存监控

```cpp
// offline_chunk_processor_manager.cpp L71-78
bool OfflineChunkProcessorManager::isMemoryLow( bool testNow ) const
{
    if ( Memory::memoryLoad() > 90.0f )
    {
        return true;
    }
    return false;
}
```

**阈值**: 内存占用超过 90% 时触发低内存处理,`ChunkProcessorManager` 会调用 `unloadChunks` 卸载已处理的 chunk。

### 10.7 unloadChunks 卸载机制

```cpp
// offline_chunk_processor_manager.cpp L85-102
void OfflineChunkProcessorManager::unloadChunks()
{
    const ChunkMap& chunkMap = mapping_->pSpace()->chunks();

    // 1. 标记所有 chunk 为可移除
    for (ChunkMap::const_iterator iter = chunkMap.begin();
        iter != chunkMap.end(); ++iter)
    {
        for (BW::vector<Chunk*>::const_iterator cit = iter->second.begin();
            cit != iter->second.end(); ++cit)
        {
            (*cit)->removable( true );
        }
    }

    // 2. mark() 标记正在使用的 chunk(覆盖 removable=false)
    mark();

    // 3. 卸载所有仍标记为可移除的 chunk
    this->unloadRemovableChunks();
}
```

### 10.8 tick 消息泵

```cpp
// offline_chunk_processor_manager.cpp L107-123
bool OfflineChunkProcessorManager::tick()
{
    MSG msg;

    // Windows 消息泵(D3D 设备需要)
    while (PeekMessage( &msg, NULL, 0, 0, PM_REMOVE))
    {
        if (msg.message == WM_QUIT)
            return false;
        TranslateMessage( &msg );
        DispatchMessage( &msg );
    }

    return !terminated_ && ChunkProcessorManager::tick();
}
```

**关键**: 即使 `-nogui` 模式,也需要消息泵,因为 D3D 设备依赖窗口消息处理。`terminated_` 标志由 CTRL+C 处理器设置。

### 10.9 ConsoleHandlerRoutine 中断处理

```cpp
// offline_chunk_processor_manager.cpp L57-62
BOOL WINAPI ConsoleHandlerRoutine( DWORD dwCtrlType )
{
    gProcessorManager_->terminate();
    return FALSE;
}
```

CTRL+C 触发 `terminate()` 设置 `terminated_=true`,下次 `tick()` 返回 false,优雅停止处理。

---

## 十一、ProcessProgress 进度展示

### 11.1 类定义

`ProcessProgress` 继承自 `Progress`,在 `command_process_chunks.cpp L210-397` 定义,是内部类:

```cpp
// command_process_chunks.cpp L210-397
class ProcessProgress : public Progress
{
    bool cancelled_;
    DWORD startTick_;
    float totalTasks_;
    float tasksLeft_;
    BW::string task_;

    void name( const BW::string& task ) { task_ = task; }
    void length( float totalTasks ) { /* 设置总数 */ }
    void update();  // 刷新控制台显示
    bool set( float tasksFinished );
    bool step( float step );

public:
    ProcessProgress();
    bool started() const;
    bool ended() const;
    const BW::string& task() const;
    DWORD tickElapsed() const;
    DWORD averageTickPerTask() const;
    float totalTasks() const;
    float tasksLeft() const;
    void generateStatus(char* outputBuf, size_t sizeBuf) const;
    void cancel();
    bool isCancelled();
};
```

### 11.2 generateStatus 状态生成

```cpp
// command_process_chunks.cpp L351-386
void ProcessProgress::generateStatus(char* outputBuf, size_t sizeBuf) const
{
    BW::StringBuilder strBuilder( outputBuf, sizeBuf );

    if (started() && !ended())
    {
        int totalTask = int( totalTasks() );
        int taskProcessed = totalTask - int( tasksLeft() );
        DWORD ticks = tickElapsed();

        strBuilder.appendf( "%s\n", this->task().c_str() );
        strBuilder.append( "========================================================\n" );
        strBuilder.appendf( "%d of %d tasks processed\n", taskProcessed, totalTask );
        strBuilder.appendf( "%d chunks loaded",
            ChunkManager::instance().cameraSpace()->boundChunkNum() );
        if (ChunkManager::instance().busy())
            strBuilder.append( " and is loading\n" );
        else
            strBuilder.append( "\n" );
        convertSecondsToFullTime( tickElapsed(), strBuilder );
        strBuilder.append( " elapsed\n" );
        strBuilder.appendf( "average %2.4f seconds per task\n", averageTickPerTask() / 1000.0f );
        strBuilder.append( "approximately " );
        convertSecondsToFullTime( int( averageTickPerTask() * tasksLeft() ), strBuilder );
        strBuilder.append( " left\n");
        strBuilder.appendf( "Memory load: %d%%\n", (int)Memory::memoryLoad() );
    }
    else
    {
        strBuilder.append( "Initialising ...\n" );
    }
}
```

**展示信息**:
- 当前任务名称;
- 已处理/总任务数;
- 已加载 chunk 数(及是否正在加载);
- 已用时间(时/分/秒);
- 平均每任务耗时;
- 预计剩余时间;
- 内存占用百分比。

### 11.3 控制台输出机制

`ProcessProgress::update()` 使用 `WriteConsoleOutput` Win32 API 直接写入控制台缓冲区,支持原地刷新(不滚动):

```cpp
// command_process_chunks.cpp L230-283 (简化)
void ProcessProgress::update()
{
    HANDLE output = GetStdHandle( STD_OUTPUT_HANDLE );
    if (output != INVALID_HANDLE_VALUE)
    {
        CONSOLE_SCREEN_BUFFER_INFO scbi;
        char status[4096];
        this->generateStatus( status, ARRAY_SIZE(status) );
        BW::vector<CHAR_INFO> charInfo;
        size_t row = std::count( status, status + ARRAY_SIZE(status), '\n' );

        GetConsoleScreenBufferInfo( output, &scbi );
        charInfo.resize( scbi.dwMaximumWindowSize.X * row );

        // 将 status 字符串转为 CHAR_INFO 数组
        for (int y = 0; y < size.Y; ++y)
        {
            for (int x = 0; x < size.X; ++x)
            {
                charInfo[...].Attributes = scbi.wAttributes;
                charInfo[...].Char.UnicodeChar = status[...] 或 ' ';
            }
        }

        // 写入控制台
        WriteConsoleOutput( output, &charInfo[0], size, coord, &rect );
    }
}
```

### 11.4 辅助控制台函数

- `disableConsoleCursor()` / `enableConsoleCursor()`:隐藏/显示光标(避免刷新时闪烁);
- `ensureVisible(int row)`:滚动控制台确保指定行数可见;
- `clearConsoleOutput()`:清除进度区域的内容。

---

## 十二、配置项与命令行参数

### 12.1 命令行参数总表

#### process-chunks 命令

| 参数 | 类型 | 必需 | 说明 |
|------|------|------|------|
| `-space <path>` | 路径 | 是(或 GUI 选择) | 空间目录路径 |
| `-cluster-index <n>` | 整数 | 否 | 集群中的机器索引(0-based) |
| `-cluster-size <n>` | 整数 | 否 | 集群机器总数 |
| `-overwrite` | 标志 | 否 | 失效所有已生成的导航数据,重新生成 |
| `-nogui` | 标志 | 否 | 不显示 GUI,纯命令行模式 |
| `-unattended` | 标志 | 否 | 自动测试模式(不交互) |

#### upgrade-bsp 命令

| 参数 | 类型 | 必需 | 说明 |
|------|------|------|------|
| `<file/dir>` | 位置参数 1 | 是 | 文件或目录路径 |
| `-recursive` | 标志 | 否 | 递归处理子目录 |
| `-output <path>` | 路径 | 否 | 输出目录 |

#### 全局参数

| 参数 | 类型 | 说明 |
|------|------|------|
| `help [command]` | 命令 | 显示帮助 |
| `-verbose` | 标志 | 启用详细日志 |
| `-unattended` | 标志 | 自动测试模式 |

### 12.2 使用示例

```bash
# 处理单个空间(集群单机)
offline_processor process-chunks -space spaces/highlands -nogui

# 4 台机器集群处理(机器 0)
offline_processor process-chunks -space spaces/highlands -nogui \
    -cluster-size 4 -cluster-index 0

# 覆盖已有导航数据
offline_processor process-chunks -space spaces/highlands -nogui -overwrite

# 升级单个 .primitives 的 BSP
offline_processor upgrade-bsp models/hero.primitives

# 递归升级目录下所有 BSP
offline_processor upgrade-bsp models/ -recursive

# 显示帮助
offline_processor help process-chunks
offline_processor help upgrade-bsp

# 详细日志
offline_processor process-chunks -space spaces/highlands -nogui -verbose
```

### 13.3 cluster 参数注意事项

```cpp
// command_process_chunks.cpp L428-435
if (commandLine_.hasParam( "cluster-index" ) &&
    commandLine_.hasParam( "cluster-size" ))
{
    clusterSize = std::max<unsigned int>(
        atoi( commandLine_.getParam( "cluster-index" ) ), 1 );
    clusterIndex = std::min<unsigned int>(
        atoi( commandLine_.getParam( "cluster-size" ) ), clusterSize - 1 );
}
```

**注意**: 这里有一个**参数赋值错误**——`clusterSize` 被赋值为 `cluster-index` 参数,`clusterIndex` 被赋值为 `cluster-size` 参数。这意味着实际使用时:
- `-cluster-size 4 -cluster-index 2` 会被解析为 `clusterSize=2, clusterIndex=min(4, 1)=1`;
- 用户需注意参数名与语义的反转,或这是一个 bug。

---

## 十三、与其他模块的依赖关系

### 13.1 依赖关系图

```
┌─────────────────────┐
│  offline_processor  │
└──────────┬──────────┘
           │
   ┌───────┴───────────────────────────────────────────┐
   │                                                   │
   ▼                         ▼                         ▼
┌──────────┐          ┌──────────┐              ┌──────────┐
│ cstdmf   │          │ resmgr   │              │ chunk    │
│ - debug  │          │ - BWResource            │ - Chunk  │
│ - command│          │ - DataSection           │ - ChunkManager│
│ - memory │          │ - AutoConfig            │ - GeometryMapping│
│ - bgtask │          │ - MultiFileSystem       │ - ChunkProcessorManager│
└──────────┘          └──────────┘              └──────────┘
   │                                                   │
   ▼                                                   ▼
┌──────────┐          ┌──────────┐              ┌──────────┐
│ moo      │          │ physics2 │              │ terrain  │
│ - init   │          │ - bsp    │              │ - TerrainSettings│
│ - rc()   │          │ - BSPTreeTool            │ - Manager│
│ - TextureMgr│       │ - BSPTree │              └──────────┘
└──────────┘          └──────────┘
   │
   ▼
┌──────────┐          ┌──────────┐              ┌──────────┐
│ python   │          │ romp     │              │ speedtree│
│ - Script │          │ - Water  │              │ - SpeedTreeRenderer│
│ - PyImportPaths│    │ - LensEffectMgr         └──────────┘
└──────────┘          │ - TextureFeeds│
                      └──────────┘
   │
   ▼
┌──────────┐          ┌──────────┐
│ input    │          │ common   │
│ - InputDevices│     │ - SpaceEditor│
└──────────┘          │ - SpaceMgr│
                      └──────────┘
```

### 13.2 关键依赖说明

| 模块 | 用途 | 使用命令 |
|------|------|---------|
| `BWResource` | 资源路径、DataSection | 两者 |
| `CommandLine` (cstdmf) | 命令行解析 | 两者 |
| `ChunkProcessorManager` | chunk 处理框架 | process-chunks |
| `SpaceEditor` | 空间编辑接口 | process-chunks |
| `BSPTreeTool` (physics2) | BSP 树加载/保存 | upgrade-bsp |
| `Moo` | D3D 渲染 | process-chunks |
| `Script` (Python) | 脚本初始化 | process-chunks |
| `ChunkManager` | chunk 加载/管理 | process-chunks |
| `Terrain` | 地形系统 | process-chunks |
| `Water`/`SpeedTree` | 水面/植被 | process-chunks |
| `BgTaskManager` | 后台任务 | process-chunks |
| `MaterialKinds` | 材质种类 | process-chunks |

### 13.3 为什么 upgrade-bsp 不需要 Moo?

`upgrade-bsp` 继承 `BatchCommand`,其 `initResourceSystem` 只初始化 `BWResource` 和 `AutoConfig`(若客户端),不调用 `Moo::init`。BSP 升级仅涉及文件 I/O 和 `BSPTreeTool` 的纯数据操作,不需要 D3D 设备。因此 `upgrade-bsp` 比 `process-chunks` 轻量得多。

---

## 十四、关键代码片段(带行号)

### 14.1 main 入口 (offline_processor_main.cpp L22-28)

```cpp
int main()
{
    BW_SYSTEMSTAGE_MAIN();
    BW_NAMESPACE OfflineProcessor::CommandManager manager;
    bool bSuccess = manager.run();
    return bSuccess ? 0 : 1;
}
```

### 14.2 CommandManager 构造与命令注册 (command_manager.cpp L28-66)

```cpp
CommandManager::CommandManager():
applicationCommandLine_( bw_wtoutf8( GetCommandLine() ).c_str() ),
verbose_( false )
{
    this->init();
}

void CommandManager::init()
{
    commands_.push_back( new CommandProcessChunks( applicationCommandLine_ ) );
    commands_.push_back( new CommandUpgradeBSP( applicationCommandLine_ ) );
    DebugFilter::instance().addMessageCallback( &debugCallback_ );
}
```

### 14.3 selectCommand 命令匹配 (command_manager.cpp L118-130)

```cpp
Command* CommandManager::selectCommand() const
{
    for (ProcessorCommands::const_iterator it = commands_.begin();
        it != commands_.end(); ++it)
    {
        if (applicationCommandLine_.hasFullParam( (*it)->strCommand(), 1 ) )
        {
            return *it;
        }
    }
    return NULL;
}
```

### 14.4 bw_hash RC4-like 哈希 (offline_chunk_processor_manager.cpp L23-51)

```cpp
unsigned int bw_hash( const char* str )
{
    static unsigned char hash[ 256 ];
    static bool inithash = true;
    if (inithash)
    {
        inithash = false;
        for( int i = 0; i < 256; ++i )
            hash[ i ] = i;
        int k = 7;
        for( int j = 0; j < 4; ++j )
            for( int i = 0; i < 256; ++i )
            {
                unsigned char s = hash[ i ];
                k = ( k + s ) % 256;
                hash[ i ] = hash[ k ];
                hash[ k ] = s;
            }
    }
    unsigned char result = ( 123 + strlen( str ) ) % 256;
    for( unsigned int i = 0; i < strlen( str ); ++i )
    {
        result = ( result + str[ i ] ) % 256;
        result = hash[ result ];
    }
    return result;
}
```

### 14.5 isChunkEditable 集群分片 (offline_chunk_processor_manager.cpp L126-129)

```cpp
bool OfflineChunkProcessorManager::isChunkEditable( const BW::string& chunk ) const
{
    return bw_hash( chunk.c_str() ) % clusterSize_ == clusterIndex_;
}
```

### 14.6 isMemoryLow 内存监控 (offline_chunk_processor_manager.cpp L71-78)

```cpp
bool OfflineChunkProcessorManager::isMemoryLow( bool testNow ) const
{
    if ( Memory::memoryLoad() > 90.0f )
    {
        return true;
    }
    return false;
}
```

### 14.7 BatchCommand::processFiles 递归 (command.cpp L149-222)

```cpp
int BatchCommand::processFiles( const BW::string& fileName,
                                bool processRecursively,
                                const BW::string& outFileName )
{
    int numFilesProcessed = 0;
    MultiFileSystem* fs = BWResource::instance().fileSystem();
    IFileSystem::FileType ft = fs->getFileType( fileName, NULL );

    if (ft == IFileSystem::FT_FILE ||
        (ft == IFileSystem::FT_NOT_FOUND && allowMisssingFiles_))
    {
        FileProcessResult pr = this->processFile( fileName, outFileName );
        if (pr == RESULT_SUCCESS) numFilesProcessed++;
        else if (pr == RESULT_FAILURE) numErrors_++;
    }
    else
    {
        IFileSystem::Directory dirList;
        fs->readDirectory( dirList, fileName );
        for (IFileSystem::Directory::iterator it = dirList.begin();
            it != dirList.end(); ++it)
        {
            BW::string subName = BWUtil::formatPath( fileName ) + (*it);
            bool bIsDirectory = (fs->getFileType( subName, NULL ) == IFileSystem::FT_DIRECTORY);
            if (processRecursively && bIsDirectory)
            {
                numFilesProcessed += this->processFiles( subName, processRecursively, outFileName );
            }
            else if (!bIsDirectory)
            {
                FileProcessResult pr = this->processFile( subName, outFileName );
                if (pr == RESULT_SUCCESS) numFilesProcessed++;
                else if (pr == RESULT_FAILURE) numErrors_++;
            }
        }
    }
    return numFilesProcessed;
}
```

### 14.8 CommandUpgradeBSP::processFile 分派 (command_upgrade_bsp.cpp L120-134)

```cpp
BatchCommand::FileProcessResult
CommandUpgradeBSP::processFile( const BW::string& fileName, const BW::string& outFileName )
{
    const BW::string disFileName = BWResolver::dissolveFilename( fileName );
    BW::StringRef ext = BWResource::getExtension( disFileName );
    if (ext == "primitives")
        return doFormatUpgradeBSPInPrimitives( disFileName ) ? RESULT_SUCCESS : RESULT_FAILURE;
    else if (ext == "bsp2" )
        return doFormatUpgradeStandaloneBSPFile( disFileName ) ? RESULT_SUCCESS : RESULT_FAILURE;
    return RESULT_UNSUPPORTED_FILE;
}
```

### 14.9 process-chunks 集群参数解析 (command_process_chunks.cpp L428-435)

```cpp
if (commandLine_.hasParam( "cluster-index" ) &&
    commandLine_.hasParam( "cluster-size" ))
{
    clusterSize = std::max<unsigned int>(
        atoi( commandLine_.getParam( "cluster-index" ) ), 1 );
    clusterIndex = std::min<unsigned int>(
        atoi( commandLine_.getParam( "cluster-size" ) ), clusterSize - 1 );
}
```

### 14.10 ProcessProgress 状态生成 (command_process_chunks.cpp L361-380)

```cpp
strBuilder.appendf( "%s\n", this->task().c_str() );
strBuilder.append( "========================================================\n" );
strBuilder.appendf( "%d of %d tasks processed\n", taskProcessed, totalTask );
strBuilder.appendf( "%d chunks loaded",
    ChunkManager::instance().cameraSpace()->boundChunkNum() );
if (ChunkManager::instance().busy())
    strBuilder.append( " and is loading\n" );
else
    strBuilder.append( "\n" );
convertSecondsToFullTime( tickElapsed(), strBuilder );
strBuilder.append( " elapsed\n" );
strBuilder.appendf( "average %2.4f seconds per task\n", averageTickPerTask() / 1000.0f );
strBuilder.append( "approximately " );
convertSecondsToFullTime( int( averageTickPerTask() * tasksLeft() ), strBuilder );
strBuilder.append( " left\n");
strBuilder.appendf( "Memory load: %d%%\n", (int)Memory::memoryLoad() );
```

### 14.11 tick 消息泵 (offline_chunk_processor_manager.cpp L107-123)

```cpp
bool OfflineChunkProcessorManager::tick()
{
    MSG msg;
    while (PeekMessage( &msg, NULL, 0, 0, PM_REMOVE))
    {
        if (msg.message == WM_QUIT)
            return false;
        TranslateMessage( &msg );
        DispatchMessage( &msg );
    }
    return !terminated_ && ChunkProcessorManager::tick();
}
```

---

## 十五、设计亮点与注意事项

### 15.1 设计亮点

#### 15.1.1 命令模式的清晰组织

`offline_processor` 通过 `Command` 抽象基类 + `CommandManager` 调度器,将多个子命令解耦:
- 新增命令只需继承 `Command`(或 `BatchCommand`),实现 `strCommand`/`process`/`showHelp`;
- 在 `CommandManager::init()` 中 `push_back` 注册;
- `selectCommand()` 自动按命令名分派。

这种模式比 `res_packer` 的 `PackerFactory` 自动注册更直观,适合命令数量较少的场景。

#### 15.1.2 BatchCommand 的通用批量框架

`BatchCommand` 提供了通用的文件/目录批量处理框架:
- `initResourceSystem` 统一初始化 `BWResource`;
- `processFiles` 统一处理文件/目录/递归;
- `processFile` 由子类实现具体的文件处理逻辑;
- `RESULT_UNSUPPORTED_FILE` 允许跳过不支持的文件,不计入错误。

`CommandUpgradeBSP` 只需实现 `processFile`,即可获得完整的批量处理能力,代码复用度高。

#### 15.1.3 RC4-like 哈希的集群分片

`bw_hash` 使用 RC4-like 的密钥调度算法(KSA)初始化置换表,保证 chunk 名称到 [0,255] 的均匀映射。`hash(chunk) % clusterSize == clusterIndex` 的分片策略:
- **无重叠**:不同 `clusterIndex` 的机器处理不同的 chunk;
- **全覆盖**:所有 chunk 都会被某台机器处理;
- **确定性**:同一 chunk 名总是映射到同一机器,便于重试和验证;
- **均匀性**:RC4-like 置换保证良好的分布,避免热点。

#### 15.1.4 完整引擎初始化的离线处理

`process-chunks` 命令通过 `InitInstance` 完整初始化 BigWorld 引擎(BWResource/Moo/Python/Chunk/Terrain/Water/SpeedTree),使离线处理能复用引擎的全部能力(碰撞检测、导航网格生成、地形加载)。这种"离线引擎"模式避免了维护单独的离线处理库。

#### 15.1.5 ProcessProgress 的控制台原地刷新

`ProcessProgress` 使用 `WriteConsoleOutput` Win32 API 直接写入控制台缓冲区,实现进度信息的**原地刷新**(不滚动)。相比 `printf` 滚动输出,这种方式更清晰,适合长时间运行的任务。同时展示了丰富的信息:任务名、进度、chunk 加载状态、已用时间、平均耗时、预计剩余、内存占用。

#### 15.1.6 内存感知的 chunk 卸载

`isMemoryLow` 监控内存占用(90% 阈值),触发 `unloadChunks` 卸载已处理的 chunk。`unloadChunks` 的策略是:
1. 先标记所有 chunk 为可移除;
2. `mark()` 重新标记正在使用的 chunk 为不可移除;
3. 卸载仍标记为可移除的 chunk。

这保证不会卸载正在处理中的 chunk,同时释放已完成 chunk 的内存。

#### 15.1.7 测试构造函数支持单元测试

`CommandManager(const char* testCommandLine)` 构造函数允许注入命令行字符串,无需依赖 `GetCommandLine()`。这使得 `CommandManager` 的命令分派逻辑可通过单元测试验证,符合依赖注入原则。

#### 15.1.8 BSP 升级的"加载-保存"模式

`upgrade-bsp` 通过 `BSPTreeTool::loadBSP` 加载旧格式,再用 `saveBSPInMemory`/`saveBSPInFile` 保存为新格式。这种模式:
- **简单**:只需 load + save,无需理解 BSP 内部结构;
- **通用**:适用于任何向后兼容的格式升级;
- **安全**:load 失败时不会破坏原文件。

### 15.2 注意事项

#### 15.2.1 cluster 参数赋值疑似 bug

`command_process_chunks.cpp L428-435` 中,`clusterSize` 被赋值为 `cluster-index` 参数,`clusterIndex` 被赋值为 `cluster-size` 参数。这与参数名语义相反,可能是 bug。使用时需注意:
- 想让 4 台机器的第 2 台处理,应使用 `-cluster-size 2 -cluster-index 4`(而非直觉的 `-cluster-size 4 -cluster-index 2`)。

#### 15.2.2 InitInstance 的沉重初始化

`process-chunks` 的 `InitInstance` 初始化了完整的引擎(Moo/D3D/Python/Chunk/Terrain/Water/SpeedTree),即使只需要导航网格生成。这导致:
- 启动时间长(数秒到数十秒);
- 内存占用高(数百 MB);
- 依赖 D3D 设备(需 Windows 有显卡驱动)。

若只需 BSP 升级,应使用轻量的 `upgrade-bsp` 命令。

#### 15.2.3 navmeshGenerator 仅支持 recast

`process-chunks` 硬编码检查 `navmeshGenerator == "recast"`,其他生成器直接报错退出。若需支持其他导航网格生成器,需修改 `command_process_chunks.cpp L495-510`。

#### 15.2.4 bw_hash 的静态初始化非线程安全

`bw_hash` 的 `inithash` 静态变量初始化非线程安全(首次调用时初始化 hash 表)。若多线程并发首次调用,可能重复初始化。但由于 `OfflineChunkProcessorManager` 在构造时即开始使用,且 `bw_hash` 主要在 `isChunkEditable` 中调用(单线程上下文),实际无问题。但若未来并行化 `processFile`,需注意。

#### 15.2.5 unloadChunks 的全量标记风险

`unloadChunks` 先将**所有** chunk 标记为可移除,再通过 `mark()` 恢复正在使用的。若 `mark()` 遗漏某些正在使用的 chunk,可能导致其被误卸载,引发崩溃。这种"先全部标记,再恢复"的策略风险较高,需确保 `mark()` 覆盖所有活跃引用。

#### 15.2.6 GUI 模式的窗口浏览

未指定 `-nogui` 且未指定 `-space` 时,`process-chunks` 会弹出窗口让用户浏览选择空间。这在自动化脚本中不适用,自动化场景必须使用 `-nogui -space <path>`。

#### 15.2.7 ConsoleHandlerRoutine 返回 FALSE

`ConsoleHandlerRoutine` 返回 `FALSE`,表示不阻止后续处理器的调用。这可能导致系统默认的 CTRL+C 处理(终止进程)也被触发。若想完全捕获 CTRL+C,应返回 `TRUE`。

#### 15.2.8 tick 的消息泵阻塞

`OfflineChunkProcessorManager::tick` 使用 `PeekMessage`(非阻塞)处理消息,避免阻塞。但若消息频繁,`while` 循环可能消耗较多 CPU。不过对于离线处理,这通常不是瓶颈。

#### 15.2.9 BatchCommand 的相对输出路径解析

`BatchCommand::process` 中,相对 `outPath` 的解析逻辑复杂(L260-293):逐步截取路径,找到已存在的父目录,拼接出绝对路径。若 `outPath` 的任何父目录都不存在,会回退到当前目录。这可能产生意外的输出位置,建议使用绝对路径。

#### 15.2.10 命令注册的显式性

与 `res_packer` 的 `PackerFactory` 自动注册不同,`offline_processor` 在 `CommandManager::init()` 中显式 `push_back`。新增命令需修改 `init()`,违反开闭原则。但好处是命令注册顺序明确,且无需 `token` 机制防止链接器优化。

### 15.3 性能考量

#### 15.3.1 集群分片的负载均衡

`bw_hash % clusterSize` 的分片策略依赖 chunk 名称的均匀分布。若空间内 chunk 命名不均匀(如大量 `chunk001`-`chunk010` 和少量 `chunkAAA`),可能导致某些机器负载高。但对于 BigWorld 的网格化 chunk 命名(`xxYYYY`),分布通常均匀。

#### 15.3.2 InitInstance 的单次开销

`InitInstance` 的初始化成本(引擎启动)是**固定开销**,与 chunk 数量无关。对于大型空间(数千 chunk),单次初始化后批量处理,平均成本可接受。对于小型空间(几十 chunk),初始化开销占比可能较高。

#### 15.3.3 内存卸载的频率

`isMemoryLow` 在每次 `tick` 时被检查。若内存频繁接近 90%,会频繁触发 `unloadChunks`,导致 chunk 反复加载/卸载,影响性能。建议空间大小匹配机器内存,避免频繁卸载。

---

## 附录 A:两个命令对照表

| 特性 | process-chunks | upgrade-bsp |
|------|---------------|-------------|
| **基类** | Command(直接) | BatchCommand |
| **命令名** | `process-chunks` | `upgrade-bsp` |
| **职责** | 生成导航网格 | 升级 BSP 格式 |
| **引擎初始化** | 完整(InitInstance) | 仅 BWResource |
| **D3D 设备** | 需要 | 不需要 |
| **Python** | 需要 | 不需要 |
| **批量处理** | 不支持(整体处理空间) | 支持(文件/目录/递归) |
| **集群分片** | 支持(cluster-index/size) | 不支持 |
| **进度展示** | ProcessProgress(原地刷新) | TRACE_MSG(滚动) |
| **内存监控** | isMemoryLow(90%) | 无 |
| **支持文件** | space 目录 | `.primitives`/`.bsp2` |
| **代码量** | 748 行 | 179 行 |
| **复杂度** | 高 | 中 |

---

## 附录 B:常见问题澄清

### B.1 为什么 process-chunks 直接继承 Command 而非 BatchCommand?

`process-chunks` 处理的是**整个空间**(space),而非单个文件。它需要完整初始化引擎、加载空间、遍历所有 chunk、生成导航网格,流程复杂且不可拆分为 `processFile`。`BatchCommand` 的文件级批量框架不适用。而 `upgrade-bsp` 是逐文件处理,天然适合 `BatchCommand`。

### B.2 为什么 process-chunks 需要创建窗口?

`process-chunks` 初始化了 Moo(D3D 渲染系统),D3D 设备的创建需要一个窗口(即使不显示)。此外,`-nogui` 模式下若未指定 `-space`,会弹出文件浏览对话框让用户选择空间。窗口类 `BWOPCLASS` 在 `MyRegisterClass` 中注册。

### B.3 bw_hash 为什么用 RC4-like 算法?

RC4 的 KSA(密钥调度算法)能产生良好的置换表,使输入均匀分布到 [0,255]。相比简单哈希(如 `sum % 256`),RC4-like 的混淆更强,避免相似 chunk 名称(如 `chunk001`/`chunk002`)映射到相近值,保证集群分片的均匀性。

### B.4 cluster 参数赋值是否是 bug?

`command_process_chunks.cpp L428-435` 中,`clusterSize` 读取 `cluster-index` 参数,`clusterIndex` 读取 `cluster-size` 参数,这与参数名语义相反,极可能是 bug。但若所有调用方都"将错就错"地使用,改反会导致兼容性问题。建议查阅调用方代码或测试确认。

### B.5 upgrade-bsp 为什么不需要 Moo?

BSP(Binary Space Partitioning)是纯几何数据结构,`BSPTreeTool::loadBSP`/`saveBSP` 只做二进制数据的解析和序列化,不涉及渲染。因此 `upgrade-bsp` 只需 `BWResource`(文件访问)和 `physics2/bsp`(BSPTreeTool),无需 D3D 设备。

### B.6 ProcessProgress 为什么用 WriteConsoleOutput 而非 printf?

`printf` 输出会滚动控制台,进度信息会被冲掉。`WriteConsoleOutput` 直接写入控制台屏幕缓冲区的指定区域,实现**原地刷新**,进度信息始终显示在固定位置,不滚动。这适合长时间运行的任务监控。

### B.7 isMemoryLow 的 90% 阈值能否配置?

90% 阈值硬编码在 `isMemoryLow` 中,不可通过命令行配置。若需调整,需修改源码重新编译。对于大内存机器(如 64GB),90% 仍有 6.4GB 余量;对于小内存机器(如 4GB),90% 只剩 400MB,可能不够。

### B.8 BatchCommand 的 allowMissingFiles 有何用?

`allowMissingFiles=true` 时,即使文件不存在也按单文件处理(`RES_INIT_SUCCESS_FILE`)。这用于某些命令需要处理"将要创建"的文件。`CommandUpgradeBSP` 默认 `allowMissingFiles=false`,即文件必须存在。

### B.9 为什么 CommandManager 用 GetCommandLine 而非 main 的 argv?

`offline_processor_main.cpp` 的 `main()` 不接收 `argc/argv`。`CommandManager` 通过 `GetCommandLine()` 自行获取 Windows 命令行(Unicode),转为 UTF-8 构造 `CommandLine` 对象。这避免了修改 `main` 签名,且 `GetCommandLine` 能获取完整的原始命令行(包括引号处理)。

### B.10 OfflineChunkProcessorManager 的多重继承有何风险?

`OfflineChunkProcessorManager` 同时继承 `ChunkProcessorManager` 和 `SpaceEditor`。若两者有同名方法或成员,会产生歧义。目前代码中两者职责分明(处理 vs 编辑),无冲突。但多重继承增加了维护复杂度,若未来父类演化出同名接口,需注意。

---

> **文档总结**: `offline_processor` 通过命令模式组织两个子命令:`process-chunks`(完整引擎初始化,生成导航网格,支持集群分片)和 `upgrade-bsp`(轻量批量升级 BSP 格式)。`OfflineChunkProcessorManager` 的 RC4-like `bw_hash` 实现了均匀的集群分片,`ProcessProgress` 使用 `WriteConsoleOutput` 实现原地进度刷新。整体设计复用了引擎的 chunk 处理框架,适合大型空间的离线数据处理。需注意 cluster 参数赋值的疑似 bug 和 InitInstance 的沉重初始化开销。
