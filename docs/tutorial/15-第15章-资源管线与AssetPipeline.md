# 第15章 资源管线与 AssetPipeline

> 第 14 章我们看了客户端怎么"读"世界——Chunk 系统把世界切成小块按需加载。但 Chunk 文件、`.visual`、`.primitives`、`.texture` 这些**编译后的资产**是怎么来的?美术用 Maya/3ds Max 导出的是"原始资源",而引擎运行时读的是"已编译资源"——这中间的桥梁就是本章主角:**Asset Pipeline(资产管线)**。BigWorld 的资产管线不是某一个小工具,而是一整套"声明式、依赖驱动、可缓存、可并行"的构建系统,堪比为游戏资源量身打造的 `make`/`ninja`。本章带你从概念走到实现:从原始 `.mb/.max/.tga` 到运行时 `.visual/.primitives/.texture`,中间发生了什么、状态机怎么驱动、缓存怎么命中、增量怎么算、JIT 怎么做到"开发时无感"。读完本章,你会明白为什么在 BigWorld 项目里改一个纹理、保存,客户端几乎立刻就能看到结果——背后是整整一套工程化的资产管线。

---

## 目录

- [15.1 资源管线概述](#151-资源管线概述)
- [15.2 源码结构全景](#152-源码结构全景)
- [15.3 compiler 子模块](#153-compiler-子模块)
- [15.4 conversion 子模块(状态机与多线程)](#154-conversion-子模块状态机与多线程)
- [15.5 dependency 子模块](#155-dependency-子模块)
- [15.6 discovery 子模块](#156-discovery-子模块)
- [15.7 batch_compiler 工具](#157-batch_compiler-工具)
- [15.8 jit_compiler 工具(反向依赖图 + JIT)](#158-jit_compiler-工具反向依赖图--jit)
- [15.9 assetprocessor 工具](#159-assetprocessor-工具)
- [15.10 特色实现深度剖析](#1510-特色实现深度剖析)
- [15.11 本章小结](#1511-本章小结)

---

## 15.1 资源管线概述

### 15.1.1 为什么需要资产管线

游戏资源与"普通文件"有两点根本不同,这两点决定了我们必须有一套专门的管线:

1. **原始资源不能直接给引擎用**。美术在 DCC(Maya/3ds Max/Photoshop)里产出的是 `.mb`、`.max`、`.psd`,而引擎运行时需要的是优化过的二进制:`.visual`(几何)、`.primitives`(顶点/索引)、`.texture`(GPU 压缩纹理)、`.fx`(已编译 shader)。中间要做导出、合并、压缩、生成 BSP 树、烘焙光照等数十种处理。

2. **资源之间互相依赖,改一处要重做一片**。一个 `.visual` 引用了一个 `.primitives`,后者引用了源 `.mb`,源文件一改,所有下游都要重建。这种"按依赖传播"的重建逻辑正是 `make`、`ninja`、`bazel` 解决的问题——但游戏资产又比 C/C++ 编译复杂得多:依赖可能跨文件类型、跨目录、甚至动态文件列表,所以不能用通用构建工具,得专门设计。

资产管线的职责一言以蔽之:**给定一组原始资源,产出引擎运行时可加载的资产;且只在必要时重建,不重复劳动**。

### 15.1.2 BigWorld 资产管线的设计理念

BigWorld 14.4.1 的资产管线(`tools/asset_pipeline/`)体现了四个核心设计理念:

**任务化(Task-based)**:每个资源文件对应一个 `ConversionTask`,任务有状态、有依赖、有产物。处理过程不是"按文件流水线"而是"按任务调度",这让并行变得简单——只要任务间无依赖,就可以多线程跑。

**可缓存(Content-addressable)**:每个中间产物和依赖列表都用其内容的哈希作为键存到缓存。两台机器、两个项目编译同一资源,缓存可以共享,甚至缓存命中可以跳过整个 `convert()`。

**可并行(Multi-threaded)**:`TaskProcessor` 通过 `BgTaskManager` 拉起多个后台线程,辅以 `ConverterGuard` 用读写锁区分"线程安全 Converter"和"非线程安全 Converter",做到尽量并发、必要时串行。

**声明式插件(Plugin-based)**:核心库 `asset_pipeline` 不认识具体格式,所有"知道怎么处理 .visual/.texture/.bsp"的逻辑都是外挂的 Converter 插件。核心库只提供调度框架,具体格式由 `converters/` 子目录下的 DLL 各自实现。这使得引擎可以无限扩展新格式而不动核心代码。

### 15.1.3 三个上层工具

资产管线核心是**静态库**(`asset_pipeline.lib`),不能独立运行。它被三个上层工具复用:

| 工具 | 位置 | 形态 | 用途 |
|---|---|---|---|
| `batch_compiler` | `tools/batch_compiler/` | CLI 可执行 | 一把扫一遍整个资源目录,把所有任务一次性编译完。常用于 nightly build 或大版本升级。 |
| `jit_compiler` | `tools/jit_compiler/` | GUI 守护进程(WTL) | 常驻后台,监听文件变更,基于反向依赖图做增量编译,通过命名管道给游戏客户端提供 JIT 资产请求服务。开发时美术/策划保存即看到效果,几乎无感。 |
| `assetprocessor` | `tools/assetprocessor/` | DLL(Python 模块 `_AssetProcessor`) | 给 World Editor / Python 脚本调用,做 BSP2 升级、shader 编译、顶点格式升级等需要 D3D 渲染设备的高级处理。 |

三者共享 `AssetCompiler` 基类(下一节展开),只在"何时编译什么"上不同:

- **batch**:扫一遍全编。
- **jit**:监听变更、增量编译。
- **assetprocessor**:被调用时单次处理特定资产。

这种"核心库 + 多种前端"的设计,让一份编译逻辑被三个工具复用,是 BigWorld 工具链的精髓之一。

### 15.1.4 与其他章节的关系

```
        DCC(Maya/Max) ─── 导出 ──► 原始资源(.mb/.tga/.fx)
                                          │
                              (本章)Asset Pipeline
                                          │
                                          ▼
                            编译后资产(.visual/.primitives/.texture)
                                          │
            ┌─────────────────────────────┼──────────────────────────┐
            ▼                             ▼                          ▼
       World Editor(16 章)         Chunk 系统(14 章)         Moo 渲染(13 章)
            │                             │                          │
            └─────────────────────────────┴──────────────────────────┘
                                          │
                                          ▼
                                  游戏客户端运行
```

资产管线处于 DCC 与运行时之间,产出供 World Editor 编辑、Chunk 加载、Moo 渲染使用。它在工具链中的位置类似编译器之于 IDE——平时不显眼,但没有它整个项目跑不起来。

---

## 15.2 源码结构全景

资产管线源码分布在 `programming/bigworld/tools/` 下四个目录,加上 `lib/asset_pipeline/` 一个小辅助库:

```
programming/bigworld/
├── tools/
│   ├── asset_pipeline/                 # 核心静态库(本章主体)
│   │   ├── compiler/                   # 4.1 compiler 子模块
│   │   │   ├── compiler.hpp            # Compiler 抽象基类(170 行)
│   │   │   ├── asset_compiler.hpp/cpp  # AssetCompiler 实现基类
│   │   │   ├── asset_compiler_options.* # 命令行选项
│   │   │   ├── generic_conversion_rule.* # 读 asset_rules.xml 的通用规则
│   │   │   ├── resource_callbacks.*    # 资源事件回调
│   │   │   ├── test_compiler/          # 测试用编译器
│   │   │   └── unit_test/
│   │   ├── conversion/                 # 4.2 conversion 子模块
│   │   │   ├── conversion_task.hpp     # ConversionTask 状态机
│   │   │   ├── conversion_task_queue.hpp # 任务队列(deque)
│   │   │   ├── task_processor.hpp/cpp  # TaskProcessor 三阶段处理
│   │   │   ├── converter.hpp           # Converter 插件接口
│   │   │   ├── converter_info.hpp      # ConverterInfo 元信息 + flags
│   │   │   ├── converter_creator.hpp   # ConverterCreator 函数指针类型
│   │   │   ├── converter_map.hpp       # id → ConverterInfo 映射
│   │   │   └── content_addressable_cache.* # 内容寻址缓存
│   │   ├── dependency/                 # 4.3 dependency 子模块
│   │   │   ├── dependency.hpp          # Dependency 基类 + 6 种类型宏
│   │   │   ├── dependency_list.hpp/cpp # DependencyList 容器
│   │   │   ├── source_file_dependency.*  # 源文件依赖
│   │   │   ├── intermediate_file_dependency.* # 中间文件依赖
│   │   │   ├── output_file_dependency.*  # 输出文件依赖
│   │   │   ├── converter_dependency.*  # Converter 自身依赖
│   │   │   ├── converter_params_dependency.* # Converter 参数依赖
│   │   │   ├── directory_dependency.* # 目录依赖(支持正则/递归)
│   │   │   └── unit_test/
│   │   ├── discovery/                  # 4.4 discovery 子模块
│   │   │   ├── task_finder.hpp/cpp     # TaskFinder 递归遍历
│   │   │   ├── conversion_rule.hpp     # ConversionRule 抽象
│   │   │   └── conversion_rules.hpp    # ConversionRules 容器
│   │   └── converters/                 # 内置 Converter 插件(DLL)
│   │       ├── visual_processor/       # .visual 处理
│   │       ├── texture_converter/      # 纹理转换
│   │       ├── texformat_converter/    # 纹理格式转换
│   │       ├── space_converter/         # Space(空间)转换
│   │       ├── primitive_processor/    # .primitives 处理
│   │       ├── hierarchical_config_converter/ # 层级配置合并
│   │       ├── effect_converter/       # .fx Effect 编译
│   │       └── bsp_converter/          # BSP 转换
│   ├── batch_compiler/                 # CLI 批量编译
│   │   ├── batch_compiler.hpp/cpp
│   │   └── CMakeLists.txt
│   ├── jit_compiler/                  # GUI 守护进程
│   │   ├── jit_compiler.hpp/cpp        # JITCompiler(四重继承核心类)
│   │   ├── main.cpp / main_window.*    # WTL 主窗口
│   │   ├── task_store.*               # 任务存储(中介者)
│   │   ├── task_info.*                 # 任务 UI 信息
│   │   ├── signal.*                    # 信号槽
│   │   ├── message_loop.*             # 跨线程 Action 队列
│   │   ├── system_tray_icon.*          # 系统托盘
│   │   └── ...
│   └── assetprocessor/                # DLL(_AssetProcessor Python 模块)
│       ├── assetprocessor.hpp/cpp      # DLL 入口
│       ├── asset_processor_script.*    # Python 暴露的脚本函数
│       └── pch.hpp/cpp
└── lib/asset_pipeline/
    └── asset_pipe.hpp / asset_server.* # 命名管道 IPC 服务端
```

每个 `converters/<name>/` 子目录通常包含:`plugin_main.cpp`(插件注册入口,被 `PluginLoader` 加载)、`<name>_converter.hpp/cpp`(Converter 实现)、可选的 `<name>_conversion_rule.hpp/cpp`(配套规则)。

整个 `asset_pipeline/` 核心库约 8500 行 C++ 代码,但本章我们会逐层剖析每个子模块的关键设计,而不必逐行读。

---

## 15.3 compiler 子模块

`compiler/` 子模块是资产管线的"上层壳":它定义了**编译器接口**(`Compiler`)、**实现基类**(`AssetCompiler`)、**命令行选项**、**通用规则**和**资源回调**。它本身不做编译,只是把 `discovery`、`conversion`、`dependency` 三个子模块粘合在一起。

### 15.3.1 Compiler 抽象基类

`compiler.hpp` 中的 `Compiler` 类是所有编译器对外的**纯接口**。它的设计有个独特约束——构造函数是 `private` 且只有 `friend AssetCompiler` 能访问:

```cpp
// programming/bigworld/tools/asset_pipeline/compiler/compiler.hpp L24-32
class Compiler
{
private:
    // Only AssetCompiler is allowed to inherit this class
    friend class AssetCompiler;

    Compiler() {}
    virtual ~Compiler() {}
```

这是一个**编译期约束**:任何第三方想继承 `Compiler` 都会因无法调用构造函数而失败。BigWorld 这样做是为了保证只有 `AssetCompiler` 是合法的实现基类,避免外部错误地继承和实现 `Compiler` 接口。

`Compiler` 的接口按职责分组:

| 分组 | 主要方法 | 用途 |
|---|---|---|
| 注册 | `registerConversionRule` / `registerConverter` / `registerResourceCallbacks` | 让插件告诉编译器"我能处理什么格式" |
| 路径 | `getResourcePaths` / `resolveRelativePath` / `resolveSourcePath` / `resolveIntermediatePath` / `resolveOutputPath` | 在源路径、中间路径、输出路径之间互转 |
| 依赖查询 | `ensureUpToDate` / `getSourceFile` / `getHash` / `getFileHash` / `getDirectoryHash` / `checkFileHashUpToDate` | 查询文件是否最新、获取哈希 |
| 任务调度 | `hasTasks` / `getNextTask` / `queueTask` | 任务队列操作 |
| 状态回调 | `onTaskStarted/Resumed/Suspended/Completed` / `onPreCreateDependencies` / `onPostCreateDependencies` / `onPreConvert` / `onPostConvert` | 任务生命周期钩子 |
| 输出回调 | `onOutputGenerated` / `onCacheRead(Miss)` / `onCacheWrite(Miss)` | 产物与缓存事件 |
| 错误 | `setError` / `setWarning` / `hasError` / `hasWarning` / `resetErrorFlags` | 错误状态管理 |
| 迭代控制 | `shouldIterateFile` / `shouldIterateDirectory` | 决定扫描哪些文件 |

这套接口约 40 个纯虚函数,覆盖了从插件注册、路径解析、依赖查询、任务调度到状态回调的完整生命周期。一个 `Converter` 插件在写依赖列表或转换资产时,持有的就是 `Compiler&` 引用,通过它回调上层——这相当于"插件 ↔ 框架"的双向通信通道。

### 15.3.2 AssetCompiler 实现基类

`AssetCompiler`(在 `asset_compiler.hpp` / `asset_compiler.cpp`)是 `Compiler` 的默认实现,也是 `batch_compiler` 和 `jit_compiler` 的共同基类:

```cpp
// programming/bigworld/tools/asset_pipeline/compiler/asset_compiler.hpp L18-21
class AssetCompiler : public Compiler
                    , public DebugMessageCallback
                    , public CriticalMessageCallback
```

它还多重继承了两个回调:`DebugMessageCallback` 用于接收日志消息(`ERROR_MSG`/`WARNING_MSG`),把错误信号同步给当前任务;`CriticalMessageCallback` 用于在 `MF_ASSERT` 时抛异常而非崩溃进程(见 `handleCritical`)。

**核心成员**:

```cpp
// asset_compiler.hpp L120-164 (节选)
protected:
    enum CompilerState { INVALID, EXECUTING, PAUSED, TERMINATING } state_;

    bool            recursive_;
    bool            forceRebuild_;
    int             numThreads_;
    BW::string      intermediatePath_;      // 中间文件目录
    BW::string      outputPath_;            // 输出文件目录

    TaskFinder      taskFinder_;             // 任务发现
    TaskProcessor   taskProcessor_;         // 任务处理
    ConversionTaskQueue taskQueue_;         // 任务队列
    SimpleMutex         taskQueueMutex_;     // 队列锁
    HANDLE              taskSemaphore_;      // 限制并发线程数

    StringHashMap< uint64 >  fileHashes_;   // 文件哈希缓存
    mutable ReadWriteLock    fileHashesLock_; // 读写锁
```

`AssetCompiler` 持有任务发现器(`TaskFinder`)、任务处理器(`TaskProcessor`)、任务队列(`ConversionTaskQueue`)和文件哈希缓存(`fileHashes_`)。这几个成员是整个管线的运行时核心。

**关键生命周期方法**:

| 方法 | 位置 | 作用 |
|---|---|---|
| `AssetCompiler()` | `asset_compiler.cpp:41-92` | 构造,创建命名互斥锁确保每个资源路径只有一个 AssetPipeline 实例 |
| `initCompiler()` | `asset_compiler.cpp:106-139` | 加载 `asset_rules.xml`,启动 `BgTaskManager`,注册消息回调,创建 `taskSemaphore_` |
| `finiCompiler()` | `asset_compiler.cpp:141-159` | 终止后台线程,关闭信号量,注销回调 |
| `pause()/resume()` | `asset_compiler.cpp:161-188` | 通过 `taskSemaphore_` 暂停/恢复所有工作线程 |
| `terminate()` | `asset_compiler.cpp:190-204` | 设置 `TERMINATING` 状态,优雅停止 |

**单实例锁**是构造期的一个重要细节。`AssetCompiler` 在构造时为每个资源路径创建 Windows 命名互斥锁 `Local\AssetPipeline<路径>`:

```cpp
// asset_compiler.cpp L52-66 (节选)
BW::wstring mutexName = L"Local\\AssetPipeline" + *it;
HANDLE compilerMutex = CreateMutexW( 0, TRUE, mutexName.c_str() );
if(GetLastError() == ERROR_ALREADY_EXISTS)
{
    ::MessageBox( NULL, 
        L"Only one instance of the AssetPipeline is allowed to be active per resource path.",
        L"AssetPipeline", MB_OK );
    exit(-1);
}
```

这保证**每个资源路径只能有一个 AssetPipeline 在跑**——这是必要的,因为多个 batch_compiler 同时编译同一目录会导致中间文件冲突。jit_compiler 也走同样的逻辑,所以 batch 和 jit 不能同时操作同一资源路径。

### 15.3.3 编译循环与状态机驱动

`AssetCompiler` 自己不驱动状态机,它通过 `TaskProcessor` 把任务从队列取出、推进状态、再放回(若被阻塞)。但 `AssetCompiler` 提供了关键基础设施:

- **任务队列**(`taskQueue_`):deque 实现,`getNextTask()` 从前取,`queueTask()` 从后入。多线程下用 `taskQueueMutex_` 保护。
- **线程局部状态**(THREADLOCAL):`s_currentTask`、`s_error`、`s_warning`、`s_CreatingDependencies`、`s_Converting` 都是 thread-local,让每个工作线程独立跟踪自己正在处理的任务和错误状态。
- **文件哈希缓存**(`fileHashes_`):用读写锁保护,多线程读取哈希时共享、写入时独占。

`onTaskStarted` / `onTaskResumed` 是状态机的"入口点",会获取 `taskSemaphore_` 信号量(限制并发数),设置 `s_currentTask`,并尝试打开源文件句柄(`CreateFileW` 带共享读,防止外部写入):

```cpp
// asset_compiler.cpp L833-841 (节选)
s_currentTask->fileHandle_ = ::CreateFileW( 
    bw_utf8tow( conversionTask.source_ ).c_str(), 
    GENERIC_READ, 
    FILE_SHARE_READ, 
    0, OPEN_EXISTING, 0, 0 );
```

这个文件句柄在任务完成前一直被持有,防止源文件在编译中途被改。这是 BigWorld 保证编译一致性的关键技巧——很多引擎没考虑这点,导致编辑器保存和编译器读取并发时出现损坏的资产。

### 15.3.4 循环依赖检测

`ensureCompiled` 中有一段循环依赖检测逻辑,值得单独看。当任务 A 等待任务 B 完成时,A 把自己的 `threadId_` 设为 B 的 `threadId_`;如果发现 `threadId_ == GetCurrentThreadId()`,说明 A 等的就是自己——即循环依赖:

```cpp
// asset_compiler.cpp L603-616 (节选)
else if (task.threadId_ != 0)
{
    // Set our task thread id to the thread id of the task we are waiting for.
    s_currentTask->threadId_ = task.threadId_;
    if (s_currentTask->threadId_ == GetCurrentThreadId())
    {
        ERROR_MSG( "Cyclic dependency found %s\n", task.source_.c_str() );
        break;
    }
}
```

这是经典的"线程 ID 传播"法检测环依赖:每个等待任务都把自己的 thread id 设置为它所等待任务的 thread id。当任务在等待链上转一圈回到自己,thread id 就会变成自己的——发现匹配即报错。这种做法不需要单独维护依赖图,巧妙地利用了线程局部存储。

### 15.3.5 插件机制(简介)

`AssetCompiler::registerConversionRule` / `registerConverter` 提供了插件注册接口。每个插件 DLL 导出 `PLUGIN_INIT_FUNC` 函数,在其中调用 `compiler->registerConversionRule(...)` 和 `compiler->registerConverter(...)`。具体插件加载机制由 `PluginLoader` 负责(详见第 17 章)。这里只看一个典型插件入口:

```cpp
// programming/bigworld/tools/asset_pipeline/converters/bsp_converter/plugin_main.cpp L26-53
PLUGIN_INIT_FUNC
{
    Compiler * compiler = dynamic_cast< Compiler * >( &pluginLoader );
    if (compiler == NULL)
        return false;

    const auto & paths = compiler->getResourcePaths();
    bool bInitRes = BWResource::init( paths );
    if ( !AutoConfig::configureAllFrom( "resources.xml" ) )
        ERROR_MSG("Couldn't load auto-config strings from resource.xml\n");
    
    INIT_CONVERTER_INFO( bspConverterInfo, BSPConverter, 
                         ConverterInfo::DEFAULT_FLAGS | ConverterInfo::UPGRADE_CONVERSION );

    compiler->registerConversionRule( bspConversionRule );
    compiler->registerConverter( bspConverterInfo );
    compiler->registerResourceCallbacks( resourceCallbacks );
    return true;
}
```

`INIT_CONVERTER_INFO` 是个宏(在 `converter_info.hpp`),把 Converter 类的 `name_`、`typeId_`、`version_`、`flags_`、`creator_` 函数指针填到一个 `ConverterInfo` 结构,再注册给编译器。`creator_` 是个 `Converter* (*)(const BW::string&)` 函数指针,TaskProcessor 在需要时调用它创建 Converter 实例。

---

## 15.4 conversion 子模块(状态机与多线程)

`conversion/` 子模块是资产管线的"心脏":它定义了 `ConversionTask` 状态机、`TaskProcessor` 三阶段处理、`ConverterGuard` 线程安全包装和 `ContentAddressableCache` 内容寻址缓存。这是 BigWorld 资产管线最精巧的部分。

### 15.4.1 ConversionTask 状态机

`ConversionTask` 是个普通 struct(不是 class),定义在 `conversion_task.hpp`:

```cpp
// programming/bigworld/tools/asset_pipeline/conversion/conversion_task.hpp L16-57
struct ConversionTask
{
    BW::string  source_;            // 源文件路径
    uint64      converterId_;       // Converter 的 id
    BW::string  converterVersion_;  // Converter 的版本号
    BW::string  converterParams_;   // Converter 的初始化参数

    enum
    {
        NEW,                    // 新创建,尚未入队
        QUEUED,                 // 已入任务队列
        PROCESSING,             // 已出队,开始处理
        NEEDS_PRIMARY_DEPS,     // 需要计算主依赖
        NEEDS_SECONDARY_DEPS,   // 需要计算次依赖
        NEEDS_CONVERSION,       // 依赖已完成,需要转换
        DONE,                   // 完成
        FAILED                  // 失败
    }           status_;

    typedef BW::vector< std::pair< const ConversionTask*, bool > > SubTaskList;
    SubTaskList subTasks_;     // 此任务依赖的子任务列表

    DWORD       threadId_;    // 正在处理此任务的线程 id
    HANDLE      fileHandle_;  // 源文件句柄(防止外部修改)

    static const uint64 s_unknownId = 0;  // 未知 converter 的 id
};
```

**状态机示意**:

```
       ┌──────┐
       │ NEW  │  任务刚创建,未入队
       └───┬──┘
           │ queueTask()
           ▼
       ┌──────┐
       │QUEUED│  在 taskQueue_ 中等待
       └───┬──┘
           │ getNextTask()
           ▼
       ┌──────────┐
       │PROCESSING│  开始处理
       └─────┬────┘
             │ processNewTask()
             ▼
       ┌──────────────────┐
       │NEEDS_PRIMARY_DEPS │  计算主依赖(源文件/Converter/参数)
       └─────────┬────────┘
                 │ processPrimaryDependencies()
                 ▼
       ┌────────────────────┐
       │NEEDS_SECONDARY_DEPS│  计算次依赖(子任务)
       └─────────┬──────────┘
                 │ processSecondaryDependencies()
                 │  ── 若被阻塞 ──► 挂起,放回队列
                 │                    │
                 │                    └─► onTaskResumed 回到此状态
                 ▼
       ┌──────────────────┐
       │NEEDS_CONVERSION  │  依赖都已就绪,实际转换
       └─────────┬────────┘
                 │ processConversion()
                 ▼
       ┌──────┐         ┌──────┐
       │ DONE │ ◄─────── │FAILED│
       └──────┘         └──────┘
```

注意注释里有一行特别强调:"DO NOT change the order of this enum as it essential to the logic of the asset pipeline"。这是因为代码里到处用 `status_ == ConversionTask::PROCESSING` 这种比较,甚至有 `>= DONE` 这种范围比较——改顺序就会导致逻辑错误。这是 BigWorld 给未来维护者的明确警告。

状态机最关键的设计是 **NEEDS_SECONDARY_DEPS 的"挂起-恢复"机制**:当任务的次依赖还没就绪时,任务会被**挂起**(`onTaskSuspended`)放回队列,等依赖完成后**恢复**(`onTaskResumed`)继续处理。这种"可中断的状态机"让多任务可以并行处理相互依赖的图,而不是死等。

### 15.4.2 TaskProcessor 三阶段处理

`TaskProcessor` 是状态机的驱动器,它把每个任务的处理分成三个阶段,对应三个核心方法:

```cpp
// programming/bigworld/tools/asset_pipeline/conversion/task_processor.hpp L80-92
bool processNewTask( TaskContext & taskContext );
bool processPrimaryDependencies( ... );     // → NEEDS_SECONDARY_DEPS
bool processSecondaryDependencies( ... );    // → NEEDS_CONVERSION(若就绪)
bool processConversion( ... );               // → DONE
```

主入口 `processTask()` 是状态机的"调度循环":

```cpp
// task_processor.cpp L219-282 (节选)
void TaskProcessor::processTask( ConversionTask & conversionTask )
{
    // Sanity check
    MF_ASSERT( conversionTask.status_ >= ConversionTask::PROCESSING )
    MF_ASSERT( conversionTask.status_ < ConversionTask::DONE )

    TaskContext taskContext( *this, conversionTask );
    
    if (conversionTask.status_ == ConversionTask::PROCESSING)
    {
        if (!processNewTask( taskContext )) return;  // 失败直接返回
    }
    
    DependencyContext dependencyContext( *this, conversionTask );
    ConversionContext conversionContext( *this, conversionTask );

    if (conversionTask.status_ == ConversionTask::NEEDS_PRIMARY_DEPS)
    {
        if (!processPrimaryDependencies( ... )) return;
    }

    if (conversionTask.status_ == ConversionTask::NEEDS_SECONDARY_DEPS)
    {
        if (!processSecondaryDependencies( ... )) return;
        // 若返回 false 但状态是 NEEDS_CONVERSION,说明被阻塞,任务被挂起
    }

    if (conversionTask.status_ == ConversionTask::NEEDS_CONVERSION)
    {
        if (!processConversion( ... )) return;
    }
}
```

这是**典型的状态机驱动**:每个 `if` 检查当前状态,执行对应阶段,推进到下一状态。如果任一阶段失败,直接返回(状态被设为 FAILED)。注意 `processSecondaryDependencies` 的特殊性——如果子任务还没就绪,它会返回 false 但状态保持 `NEEDS_CONVERSION`,由调用方决定挂起还是继续。

#### 15.4.2.1 processPrimaryDependencies —— 主依赖阶段

主依赖是任务的"身份标识",由三个固定依赖组成:

1. **SourceFileDependency**:源文件本身(任务的 `source_`)
2. **ConverterDependency**:Converter 的 id 和版本号
3. **ConverterParamsDependency**:Converter 的参数字符串

这三个依赖是"框架级"的,不需要 Converter 自己声明。`processPrimaryDependencies` 的逻辑:

```cpp
// task_processor.cpp L307-399 (简化)
bool TaskProcessor::processPrimaryDependencies( ... )
{
    bool needsDeps = forceRebuild_;
    
    // 1. 检查现有 .deps 文件的主依赖是否最新
    if (!needsDeps)
        needsDeps = !checkPrimaryDependenciesUpToDate( taskContext, dependencyContext );
    
    // 2. 主依赖过期,尝试从缓存取
    if (needsDeps)
    {
        dependencyContext.depList_.initialise( source, converterId, version, params );
        needsDeps = !retrievePrimaryDependencyListFromCache( dependencyContext, conversionContext );
    }
    
    // 3. 缓存未命中,调用 Converter.createDependencies() 重新生成
    if (needsDeps)
    {
        ConverterGuard converterGuard( conversionContext.converterInfo_ );  // 加锁
        res = conversionContext.converter_->createDependencies( source, compiler_, depList_ );
        // 写回 .deps 文件,推到内容寻址缓存
        ContentAddressableCache::writeToCache( depListFileName_, hash, compiler_ );
    }
    
    taskContext.conversionTask_.status_ = ConversionTask::NEEDS_SECONDARY_DEPS;
    return true;
}
```

`checkPrimaryDependenciesUpToDate` 的实现里有个有趣细节——主依赖的前三个必须按固定顺序(SourceFile、Converter、ConverterParams),代码用 `dynamic_cast` 验证:

```cpp
// task_processor.cpp L650-691 (节选)
case 0:
    // 第一个主依赖必须是 SourceFileDependency,且文件名匹配
    SourceFileDependency * sfd = dynamic_cast< SourceFileDependency * >( dep.first );
    if (sfd == NULL || sfd->getFileName() != taskContext.relativeSource_)
        return false;
case 1:
    // 第二个必须是 ConverterDependency,id 和 version 匹配
    ConverterDependency * cd = dynamic_cast< ConverterDependency * >( dep.first );
    if (cd->getConverterId() != task.converterId_ || 
        cd->getConverterVersion() != task.converterVersion_)
        return false;
case 2:
    // 第三个必须是 ConverterParamsDependency,参数匹配
    ConverterParamsDependency * cpd = ...;
    if (cpd->getConverterParams() != task.converterParams_)
        return false;
```

这是一种"结构化校验"——不只看哈希,还验证依赖类型和顺序正确。这能捕获 `.deps` 文件被损坏或被错误 Converter 写过的情况。

#### 15.4.2.2 processSecondaryDependencies —— 次依赖阶段

次依赖是 Converter 自己声明的依赖,通常是它引用的其他资产(如 `.visual` 引用 `.primitives` 引用 `.mb`)。这阶段会递归调用 `compiler.ensureUpToDate()`,触发子任务的处理:

```cpp
// task_processor.cpp L401-475 (简化)
bool TaskProcessor::processSecondaryDependencies( ... )
{
    bool blocked = false;
    bool subTaskError = false;

    for (auto & dep : dependencyContext.depList_.secondaryInputs_)
    {
        const ConversionTask * secondaryTask = NULL;
        bool upToDate = compiler_.ensureUpToDate( *dep.first, secondaryTask );
        // ... 处理失败/阻塞
        if (!upToDate)
            blocked = true;
    }
    
    // 如果被阻塞,返回 false 但状态设为 NEEDS_CONVERSION
    // 调用方会挂起任务,等子任务完成后恢复
    taskContext.conversionTask_.status_ = ConversionTask::NEEDS_CONVERSION;
    return !blocked;
}
```

**关键点**:`ensureUpToDate` 是**递归入口**。它内部会调用 `taskFinder_.getTask()` 找到/创建子任务,如果是 recursive 模式,会**直接在当前线程同步处理子任务**(见 `asset_compiler.cpp:531-627`);否则会把子任务入队,然后挂起当前任务等待。这种"递归 + 队列"混合模式让管线既支持深度依赖图,又能多线程并行。

#### 15.4.2.3 processConversion —— 转换阶段

这是真正调用 `Converter.convert()` 的阶段,产出中间文件和输出文件:

```cpp
// task_processor.cpp L477-627 (简化)
bool TaskProcessor::processConversion( ... )
{
    bool needsConversion = forceRebuild_;
    
    // 一系列检查:有输出?次依赖最新?中间产物最新?输出最新?
    // 任一不满足则 needsConversion = true
    // 每一步都尝试从内容寻址缓存取
    
    if (needsConversion)
    {
        // 升级类 Converter 需要释放源文件句柄(因为要写源文件)
        if (converterInfo.flags_ & UPGRADE_CONVERSION)
            ::CloseHandle( task.fileHandle_ );
        
        ConverterGuard converterGuard( converterInfo );
        res = converter_->convert( source, compiler_, intermediateFiles, outputFiles );
        
        // 把产物推到内容寻址缓存
        updateIntermediateOutputs( intermediateFiles, ... );
        updateOutputs( outputFiles, ... );
    }
    
    task.status_ = ConversionTask::DONE;
    return true;
}
```

注意 **UPGRADE_CONVERSION** 标志:`.visual` 升级到 `.visual` 时,Converter 要写源文件,所以要先关闭源文件句柄(否则会锁定自己)。这是 BSP 升级、顶点格式升级等"原地升级"Converter 必备的能力。

### 15.4.3 TaskProcessor 多线程调度

`TaskProcessor` 提供两种模式:

```cpp
// task_processor.cpp L935-945
void TaskProcessor::processTasks()
{
    if (multiThreaded_)
        processTasksOnMultipleThreads();
    else
        processTasksOnSingleThread();
}
```

**单线程模式**简单:循环从队列取任务、处理、回调,直到队列空:

```cpp
// task_processor.cpp L960-988 (简化)
void TaskProcessor::processTasksOnSingleThread()
{
    while (true)
    {
        ConversionTask * task = compiler_.getNextTask();
        if (task == NULL) break;
        
        task->status_ == ConversionTask::PROCESSING ?
            compiler_.onTaskStarted( *task ) :
            compiler_.onTaskResumed( *task );
        
        this->processTask( *task );
        
        task->status_ >= ConversionTask::DONE ?
            compiler_.onTaskCompleted( *task ) :
            compiler_.onTaskSuspended( *task );
        
        if (isThreadKillRequested()) break;
    }
}
```

**多线程模式**通过 `BgTaskManager` 拉起后台任务:

```cpp
// task_processor.cpp L990-1026 (简化)
void TaskProcessor::processTasksOnMultipleThreads()
{
    while (true)
    {
        const int numThreads = BgTaskManager::instance().numUnstoppedThreads();
        const int numTasks = BgTaskManager::instance().numBgTasksLeft();
        
        if (compiler_.hasTasks())
        {
            if (numThreads > numTasks)
            {
                // 创建新的后台任务补足差额
                for (int i = 0; i < numThreads - numTasks; ++i)
                    BgTaskManager::instance().addBackgroundTask( new TaskProcessorTask( *this ) );
            }
            else if (numThreads < numTasks)
            {
                // 线程过多,通知多余线程退出
                InterlockedExchange(&threadKillCount_, numTasks - numThreads);
            }
        }
        else if (numTasks == 0)
            break;
        
        Sleep(100);  // 等 100ms 再检查
    }
}
```

这是个**自适应线程池**:每 100ms 检查一次,如果积压任务多于可用线程就动态创建后台任务,反之通知多余线程退出。`TaskProcessorTask` 是 `BackgroundTask` 的子类,在 `doBackgroundTask` 里调用 `processTasksOnSingleThread`——也就是说**每个后台线程跑的都是单线程循环,通过 `getNextTask` 共享队列**。这是经典的"工作窃取"思想的简化版。

### 15.4.4 ConverterGuard 线程安全包装

`ConverterGuard` 定义在 `task_processor.cpp` 内部(注意没有独立头文件),它根据 Converter 是否声明 `THREAD_SAFE` flag 决定加锁方式:

```cpp
// programming/bigworld/tools/asset_pipeline/conversion/task_processor.cpp L45-89
class ConverterGuard
{
public:
    ConverterGuard( ConverterInfo & converterInfo )
    {
        threadSafe_ = ( (converterInfo.flags_ & ConverterInfo::THREAD_SAFE) != 0 );

        if (threadSafe_)
        {
            while (s_pendingWrites > 0)
            {
                // 如果有排队的独占任务,让它们先跑
                Sleep( 0 );
            }
            // 线程安全 Converter:共享读锁
            s_lock_.beginRead();
            return;
        }
        
        InterlockedIncrement( &s_pendingWrites );
        // 非线程安全 Converter:独占写锁
        s_lock_.beginWrite();
        InterlockedDecrement( &s_pendingWrites );
    }

    ~ConverterGuard()
    {
        if (threadSafe_)
            s_lock_.endRead();
        else
            s_lock_.endWrite();
    }

private:
    bool threadSafe_;
    static ReadWriteLock s_lock_;
    static volatile long s_pendingWrites;
};
```

这是经典的**读写锁模式**:

- 线程安全 Converter(`THREAD_SAFE` flag):多个可以并发跑 → 共享读锁
- 非线程安全 Converter:必须独占 → 排他写锁

`s_pendingWrites` 计数器是个细节:新来的读请求会先让排队的写请求跑完,避免写被饿死。这是公平性的考虑。

`ConverterInfo::CONVERTER_FLAGS` 的完整列表(`converter_info.hpp:20-28`):

```cpp
enum CONVERTER_FLAGS
{
    THREAD_SAFE         = 1 << 0, // 可多线程并发
    CACHE_DEPENDENCIES  = 1 << 1, // 依赖列表是否写缓存
    CACHE_CONVERSION    = 1 << 2, // 转换产物是否写缓存
    UPGRADE_CONVERSION  = 1 << 3, // 是否原地升级源文件
    DEFAULT_FLAGS       = THREAD_SAFE | CACHE_DEPENDENCIES | CACHE_CONVERSION,
    EXPERIMENTAL_MASK   = ~(CACHE_CONVERSION | CACHE_DEPENDENCIES)
};
```

大部分 Converter 用 `DEFAULT_FLAGS`(线程安全 + 全缓存);BSP 升级等特殊 Converter 加 `UPGRADE_CONVERSION`。

### 15.4.5 内容寻址缓存(ContentAddressableCache)

`ContentAddressableCache` 是资产管线的"共享记忆",定义在 `content_addressable_cache.hpp`:

```cpp
// programming/bigworld/tools/asset_pipeline/conversion/content_addressable_cache.hpp L15-31
class ContentAddressableCache
{
public:
    static const BW::string & getCachePath();
    static bool getReadFromCache();
    static bool getWriteToCache();
    static void setCachePath( const BW::string & cachePath );
    static void setReadFromCache( bool readFromCache );
    static void setWriteToCache( bool writeToCache );
    static bool readFromCache( const BW::string & filename, uint64 hash, Compiler & compiler );
    static bool writeToCache( const BW::string & filename, uint64 hash, Compiler & compiler );
```

它的工作方式类似 Git 的对象存储:

- 每个文件以**内容哈希**为键存储,路径通常是 `cache_path/<hash 前两位>/<hash 后 14 位>`
- `readFromCache(filename, hash, compiler)`:在缓存里找哈希为 `hash` 的文件,复制到 `filename`
- `writeToCache(filename, hash, compiler)`:把 `filename` 复制到缓存,以 `hash` 为键

**去重效果**:两个项目编译同一个 `.texture`(输入完全相同),会得到同一个哈希,缓存只存一份。第二个项目直接从缓存取,跳过昂贵的纹理压缩。

**跨机器共享**:缓存可以放在网络共享盘或 NAS 上,整个团队共享。新人拉代码后第一次构建,大量产物能从团队缓存命中,极大加速首次构建。

`task_processor.cpp` 中有两处使用:

```cpp
// 主依赖缓存(task_processor.cpp L382-386)
if ((conversionContext.converterInfo_.flags_ & ConverterInfo::CACHE_DEPENDENCIES) != 0)
{
    ContentAddressableCache::writeToCache( dependencyContext.depListFileName_, 
        dependencyContext.depList_.getInputHash( false ), compiler_);
}

// 输出产物缓存(task_processor.cpp L892-895)
if ((conversionContext.converterInfo_.flags_ & ConverterInfo::CACHE_CONVERSION) != 0)
{
    ContentAddressableCache::writeToCache( output, hash, compiler_ );
}
```

读取时(在 `checkIntermediateOutputsUpToDate` / `checkOutputsUpToDate`):如果输出文件哈希不匹配,先尝试从缓存取——取到了就跳过 `convert()`,这是增量构建能"跳过"的核心机制。

---

## 15.5 dependency 子模块

`dependency/` 子模块定义了资产管线的依赖系统:6 种依赖类型、`DependencyList` 容器、依赖的序列化和哈希计算。

### 15.5.1 6 种依赖类型

`dependency.hpp` 用一个宏定义了所有依赖类型:

```cpp
// programming/bigworld/tools/asset_pipeline/dependency/dependency.hpp L10-16
#define DEPENDENCY_TYPES            \
    X( SourceFileDependency )       \  // 源文件依赖
    X( IntermediateFileDependency )\  // 中间文件依赖
    X( OutputFileDependency )      \  // 输出文件依赖
    X( ConverterDependency )        \  // Converter 自身依赖
    X( ConverterParamsDependency )  \  // Converter 参数依赖
    X( DirectoryDependency )          // 目录依赖(支持正则/递归)
```

这个 X-macro 模式的好处:增加新依赖类型只需在宏里加一行,枚举和工厂函数自动更新。

| 依赖类型 | 含义 | 哈希来源 |
|---|---|---|
| `SourceFileDependency` | 源文件(`.mb/.tga/.fx`) | 文件路径 + 文件内容 |
| `IntermediateFileDependency` | 中间产物(`.deps` 等) | 文件路径 + 文件内容 |
| `OutputFileDependency` | 最终输出(`.visual/.texture`) | 文件路径 + 文件内容 |
| `ConverterDependency` | Converter 自身 | Converter id + version |
| `ConverterParamsDependency` | Converter 参数 | 参数字符串 |
| `DirectoryDependency` | 整个目录(可正则/递归) | 目录 + 模式 + 所有匹配文件 |

每个类型有自己的子类(`source_file_dependency.hpp` 等),都继承 `Dependency` 基类并实现 `getType()` / `serialiseIn()` / `serialiseOut()`。基类有个 `critical_` 标志:

```cpp
// dependency.hpp L42-48
void setCritical( bool critical ) { critical_ = critical; }
bool isCritical() const { return critical_; }
```

如果某依赖是 critical 的,它失败会让整个任务失败;非 critical 依赖失败只是警告。这让 Converter 能区分"必需依赖"和"可选依赖"。

### 15.5.2 DependencyList 容器

`DependencyList` 是单个任务的依赖集合,定义在 `dependency_list.hpp`:

```cpp
// programming/bigworld/tools/asset_pipeline/dependency/dependency_list.hpp L19-29
class DependencyList
{
public:
    typedef std::pair< Dependency*, uint64 > Input;        // 依赖 + 它的哈希
    typedef std::pair< BW::string, uint64 > Output;       // 输出文件 + 它的哈希
    
    const BW::vector< Input > & primaryInputs() const { return primaryInputs_; }
    const BW::vector< Input > & secondaryInputs() const { return secondaryInputs_; }
    const BW::vector< Output > & intermediateOutputs() const { return intermediateOutputs_; }
    const BW::vector< Output > & outputs() const { return outputs_; }
```

依赖列表分四组:

- **primaryInputs**:主依赖(固定三个:SourceFile、Converter、ConverterParams),框架自动维护
- **secondaryInputs**:次依赖(Converter 自己声明的引用)
- **intermediateOutputs**:中间产物(如 `.deps` 文件)
- **outputs**:最终输出(如 `.visual` 文件)

每个 `Input` 持有 `Dependency*` 和它的哈希值 `uint64`。哈希值在依赖列表序列化时一并保存到 `.deps` 文件,下次构建时只需比较文件当前哈希和保存的哈希即可判断是否过期——这是**增量构建的基础**。

`DependencyList` 提供了一系列 `addPrimary*Dependency()` / `addSecondary*Dependency()` 方法供 Converter 调用:

```cpp
// dependency_list.hpp L44-73
void addPrimarySourceFileDependency( const BW::string & filename );
void addPrimaryConverterDependency( uint64 converterId, const BW::string & converterVersion );
void addPrimaryConverterParamsDependency( const BW::string & converterParams );

void addSecondarySourceFileDependency( const BW::string & filename, bool critical );
void addSecondaryIntermediateFileDependency( const BW::string & filename, bool critical );
void addSecondaryOutputFileDependency( const BW::string & filename, bool critical );
void addSecondaryDirectoryDependency( const BW::string & directory, 
    const BW::string & pattern, bool regex, bool recursive, bool critical );
```

注意次依赖都有 `critical` 参数——Converter 自己决定哪些是必需的、哪些是可选的。

### 15.5.3 正向依赖与反向依赖

`DependencyList` 维护的是**正向依赖**:任务 → 它依赖什么。这是构建时的视角——"我要编 X,需要先有什么"。

但在 jit_compiler 的增量场景下,问题反过来:**文件 F 变了,哪些任务受影响?**——这是**反向依赖**。`DependencyList` 自己不维护反向依赖,反向依赖图由 `JITCompiler` 在运行时构建(详见 15.8 节)。

正向依赖图存储在 `.deps` 文件里,持久化到磁盘;反向依赖图是 `JITCompiler` 启动后扫一遍所有 `.deps` 文件**在内存中重建**的,进程退出即丢失。

### 15.5.4 依赖的哈希计算

`AssetCompiler::getHash()` 按 Dependency 类型分发计算哈希:

```cpp
// asset_compiler.cpp L332-417 (节选)
case SourceFileDependencyType:
{
    uint64 hash = Hash64::compute( filename );
    resolveSourcePath( filename );
    Hash64::combine( hash, getFileHash( filename, false ) );
    return hash;
}
case ConverterDependencyType:
{
    uint64 hash = converterDependency.getConverterId();
    Hash64::combine( hash, converterDependency.getConverterVersion() );
    return hash;
}
case DirectoryDependencyType:
{
    uint64 hash = Hash64::compute( directory );
    Hash64::combine( hash, getDirectoryHash( directory, pattern, regex, recursive ) );
    return hash;
}
```

注意目录依赖的哈希要遍历目录下所有匹配文件,把每个文件的哈希都 combine 进去——这是 `getDirectoryHash` 做的:

```cpp
// asset_compiler.cpp L474-521 (节选)
uint64 AssetCompiler::getDirectoryHash( ... )
{
    uint64 hash = 0;
    MultiFileSystem* fs = BWResource::instance().fileSystem();
    IFileSystem::Directory dir;
    fs->readDirectory( dir, directory );
    std::sort( dir.begin(), dir.end() );  // 排序保证哈希稳定
    
    for (auto it = dir.begin(); it != dir.end(); ++it)
    {
        if (ft == IFileSystem::FT_FILE)
        {
            if (regex ? RE2::FullMatch(*it, pattern) : *it == pattern)
            {
                Hash64::combine( hash, *it );
                Hash64::combine( hash, getFileHash( subPath, false ) );
            }
        }
        else if (ft == IFileSystem::FT_DIRECTORY && recursive)
        {
            Hash64::combine( hash, getDirectoryHash( subPath, pattern, regex, recursive ) );
        }
    }
    return hash;
}
```

这里有个性能要点:目录依赖的哈希计算开销随目录文件数线性增长。BigWorld 排序后哈希是稳定的(同样的目录无论扫描顺序都得同一哈希),但每次构建都要全扫一遍。所以 BigWorld 缓存了 `fileHashes_`——文件内容没变就直接用缓存哈希,不必重读文件。

---

## 15.6 discovery 子模块

`discovery/` 子模块负责"把磁盘上的文件变成 ConversionTask"。它的核心是 `TaskFinder` 递归遍历 + `ConversionRule` 模式匹配。

### 15.6.1 TaskFinder 递归遍历

`TaskFinder` 的核心方法 `findTasks()`:

```cpp
// programming/bigworld/tools/asset_pipeline/discovery/task_finder.cpp L42-58
void TaskFinder::findTasks( const BW::StringRef& directory )
{
    MultiFileSystem* fs = BWResource::instance().fileSystem();
    IFileSystem::FileType ft = fs->getFileType( directory );
    if ( ft == IFileSystem::FT_NOT_FOUND )
        ERROR_MSG( "Directory passed in (%s) not found\n", ... );
    else if (ft == IFileSystem::FT_FILE)
        iterateFile( directory );
    else if (ft == IFileSystem::FT_DIRECTORY)
        iterateDirectory( directory );
}
```

`iterateDirectory` 是递归扫描的主体:

```cpp
// task_finder.cpp L74-114 (简化)
void TaskFinder::iterateDirectory( const BW::StringRef& directory )
{
    BW::string path = BWUtil::formatPath( directory );
    if (!compiler_.shouldIterateDirectory( path ))  // 由编译器决定是否扫描
        return;
    
    BW::string relativeDirectory = BWResource::dissolveFilename( path );
    bool isBWPath = relativeDirectory.length() < path.length();
    if (isBWPath)
        INFO_MSG( "Searching %s\n", path.c_str() );
    
    MultiFileSystem* fs = BWResource::instance().fileSystem();
    IFileSystem::Directory dir;
    fs->readDirectory( dir, path );
    for( auto it = dir.begin(); it != dir.end(); ++it )
    {
        BW::string subPath = path + *it;
        IFileSystem::FileType ft = fs->getFileType( subPath );
        if (ft == IFileSystem::FT_FILE && isBWPath)
            iterateFile( subPath );          // 是文件 → 试规则
        else if (ft == IFileSystem::FT_DIRECTORY)
            iterateDirectory( subPath );     // 是目录 → 递归
    }
}
```

注意 `shouldIterateDirectory` 这个钩子——`AssetCompiler` 的实现会跳过 `intermediatePath_`、`outputPath_`、`.svn` 目录、`testfiles` 测试目录。这避免了中间产物被当成源文件再扫一遍。

`iterateFile` 调用 `getTask(file, true)`(bRoot=true 表示只匹配根规则),匹配上就把任务入队:

```cpp
// task_finder.cpp L60-72
void TaskFinder::iterateFile( const BW::StringRef& file )
{
    if (!compiler_.shouldIterateFile( file ))
        return;
    ConversionTask * task = getTask( file, true );
    if ( task != NULL )
        compiler_.queueTask( *task );
}
```

### 15.6.2 ConversionRule 规则接口

`ConversionRule` 是规则抽象:

```cpp
// programming/bigworld/tools/asset_pipeline/discovery/conversion_rule.hpp L12-36
class ConversionRule
{
public:
    /* returns true and populates a root conversion task if the rule can match. */
    virtual bool createRootTask( const BW::StringRef& sourceFile,
                                 ConversionTask& task ) { 
        return false; 
    }

    /* returns true and populates a conversion task if the rule can match. */
    virtual bool createTask( const BW::StringRef& sourceFile,
                             ConversionTask& task ) {
        return createRootTask( sourceFile, task );
    }
    
    /* returns true if the rule can match the output filename. */
    virtual bool getSourceFile( const BW::StringRef& file,
                                BW::string& sourcefile ) const {
        return false;
    }
};
```

三个方法:

| 方法 | 用途 |
|---|---|
| `createRootTask` | 给定一个**源文件**,创建"根任务"(扫描时调用) |
| `createTask` | 给定一个**源文件**(可能是次依赖),创建任务。默认调 `createRootTask`,可重写 |
| `getSourceFile` | 给定一个**输出文件**(如 `.visual`),反查源文件(`.mb`)。反向查找 |

`createRootTask` vs `createTask` 的区别:`createRootTask` 只对"根"文件返回 true(比如 `.mb` 模型文件);`createTask` 还可以对被引用的非根文件返回 true(比如 `.tga` 纹理文件,虽然它本身不是根,但被 `.visual` 引用所以也需要转换)。

### 15.6.3 文件模式匹配:GenericConversionRule

BigWorld 提供了一个开箱即用的 `GenericConversionRule`(`compiler/generic_conversion_rule.hpp`),从 `asset_rules.xml` 加载规则:

```cpp
// programming/bigworld/tools/asset_pipeline/compiler/generic_conversion_rule.hpp L10-34
class GenericConversionRule : public ConversionRule
{
public:
    GenericConversionRule( ConverterMap & converters );
    void load( const StringRef & rules );     // 加载 asset_rules.xml

    virtual bool createRootTask( const BW::StringRef & sourceFile, ConversionTask & task );
    virtual bool createTask( const BW::StringRef & sourceFile, ConversionTask & task );
    virtual bool getSourceFile( const BW::StringRef & file, BW::string & sourcefile ) const;
private:
    ConverterMap & converters_;
    HierarchicalConfig rules_;                // 用层级配置存储规则
};
```

`asset_rules.xml` 是个项目级配置文件,典型内容是声明"哪种扩展名用哪个 Converter、参数是什么、对应输出是什么扩展名"。比如:

```xml
<rule>
    <sourcePattern>*.tga</sourcePattern>
    <converter>TextureConverter</converter>
    <outputPattern>*.texture</outputPattern>
</rule>
```

`GenericConversionRule` 内部用 `HierarchicalConfig` 解析这个 XML,扫描时按规则匹配文件名,产出 `ConversionTask`。

`AssetCompiler::initCompiler` 会自动加载这个规则:

```cpp
// asset_compiler.cpp L115-116
genericConversionRule_.load( "asset_rules.xml" );
conversionRules_.push_back( &genericConversionRule_ );
```

它被放在 `conversionRules_` 列表的**最前面**——其他插件注册的规则会插到后面,优先级低于内置规则。`TaskFinder` 遍历规则时是**反向遍历**(`crbegin()`),所以后注册的规则优先匹配。这让插件可以"覆盖"内置规则。

---

## 15.7 batch_compiler 工具

`batch_compiler` 是 CLI 批量编译工具,典型的 nightly build 工具。它继承 `AssetCompiler` + `PluginLoader`:

```cpp
// programming/bigworld/tools/batch_compiler/batch_compiler.hpp L13-15
class BatchCompiler : public AssetCompiler
                    , public PluginLoader
```

### 15.7.1 整体流程

`BatchCompiler::build()` 是入口:

```cpp
// programming/bigworld/tools/batch_compiler/batch_compiler.cpp L84-133 (简化)
void BatchCompiler::build( const BW::vector< BW::string > & paths )
{
    uint64 startTime = timestamp();
    MF_ASSERT( taskQueue_.empty() );

    for (auto it = paths.begin(); it != paths.end(); ++it)
    {
        ft = fs->getFileType( *it );
        if (ft == IFileSystem::FT_FILE)
        {
            // 单个文件 → 直接 getTask + queueTask
            ConversionTask & task = taskFinder_.getTask( *it );
            if (task.converterId_ != ConversionTask::s_unknownId)
                queueTask( task );
        }
        else if (ft == IFileSystem::FT_DIRECTORY)
        {
            // 目录 → findTasks 递归扫描
            taskFinder_.findTasks( *it );
        }
    }

    INFO_MSG( "========== Found: %d tasks, Searched: %d files, %d directories ==========\n",
        taskQueue_.size(), filesIterated_, directoriesIterated_ );

    taskProcessor_.processTasks();   // 处理队列
    
    uint64 endTime = timestamp();
    totalDuration_ = (double)(((int64)(endTime - startTime)) / stampsPerSecondD());
}
```

整体三步:扫描 → 处理 → 出报告。`processTasks()` 阻塞直到队列空。

### 15.7.2 HTML 报告生成

`BatchCompiler` 重写了大量 `on*` 回调来收集统计信息,然后用 `outputReport()` 生成 HTML 报告:

```cpp
// batch_compiler.hpp L60-78
struct TaskRecord
{
    long id_;
    bool upToDate_;        // 依赖最新,跳过转换
    bool skipped_;         // 依赖也跳过,完全没碰
    bool hasError_;
    bool hasWarning_;
    double duration_;      // 处理耗时
    BW::vector<BW::string> outputs_;
    BW::string log_;       // 任务日志
};
```

`TaskRecord` 记录每个任务的详细信息(是否最新、是否跳过、是否出错、耗时、输出文件、日志)。`outputReport` 把这些数据序列化成 HTML 文件,带 CSS 样式和 JavaScript 排序/过滤:

```cpp
// batch_compiler.cpp L135-200 (节选)
void BatchCompiler::outputReport( const StringRef & filename )
{
    DataResource reportResource( filename.to_string(), RESOURCE_TYPE_XML, true );
    DataSectionPtr rootSection = reportResource.getRootSection();
    rootSection->delChildren();
    rootSection->save( "html" );  // 创建 HTML 文件

    DataSectionPtr headSection = rootSection->newSection( "head" );
    
    // 插入 CSS
    DataSectionPtr css = BWResource::openSection( "resources/report_style.css" );
    if (css != NULL) { /* 写入 <style> */ }
    
    // 插入 JavaScript
    DataSectionPtr javascript = BWResource::openSection( "resources/report_script.js" );
    if (javascript != NULL) { /* 写入 <script> */ }
    
    // 写入 body、summary、各任务详情...
}
```

有意思的是 BigWorld 用 `DataSection` 生成 HTML——`DataSection` 本来是给 XML 用的,但 HTML 是 XML 的超集,所以可以直接用。每个 `<head>`、`<body>`、`<style>` 都是 `DataSectionPtr`。

报告包含的内容:
- **Summary**:发现任务数、扫描文件数、目录数
- **Discovery stats**:`filesIterated_`、`directoriesIterated_`
- **Conversion stats**:`taskCount_`、`taskFailedCount_`、`taskUpToDateCount_`、`taskSkippedCount_`
- **Cache stats**:`cacheReadCount_`、`cacheReadMissCount_`、`cacheWriteCount_`、`cacheWriteMissCount_`
- **每个任务的详情**:耗时、输出、日志(可展开)

### 15.7.3 Ctrl-C 优雅终止

`batch_compiler` 注册了 Windows 控制台事件处理器,处理 Ctrl-C:

```cpp
// batch_compiler.cpp L35-52
namespace BatchCompiler_Locals
{
    BatchCompiler * batchCompiler_ = NULL;

    BOOL WINAPI ConsoleHandler( DWORD ctrl_type )
    {
        if ( ctrl_type == CTRL_C_EVENT || ctrl_type == CTRL_BREAK_EVENT ) 
        {
            if (batchCompiler_->terminating())
            {
                // 已经在终止中,再次按 Ctrl-C 强制停止
                BgTaskManager::instance().stopAll( true, false );
            }
            else
            {
                // 第一次按 Ctrl-C,优雅终止
                batchCompiler_->terminate();
            }
            return TRUE;
        }
        return FALSE;
    }
}
```

**两级终止**:第一次 Ctrl-C 调 `terminate()`,设置 `TERMINATING` 状态,让正在处理的任务跑完再退出;第二次 Ctrl-C 调 `stopAll(true, false)`,立即杀掉所有工作线程。这是对长期构建任务的用户友好设计——避免误按 Ctrl-C 损坏资产。

### 15.7.4 命令行用法

`batch_compiler` 的典型用法(参考 `AssetCompilerOptions`):

```bash
# 编译整个资源目录
batch_compiler.exe --input resources/ --intermediate intermediate/ --output output/

# 强制重建(忽略缓存)
batch_compiler.exe --input resources/ --force

# 多线程
batch_compiler.exe --input resources/ --threads 8

# 生成报告
batch_compiler.exe --input resources/ --report report.html
```

参数包括:`--input`(输入路径)、`--intermediate`(中间路径)、`--output`(输出路径)、`--cache`(内容寻址缓存路径)、`--threads`(线程数)、`--force`(强制重建)、`--recursive`(递归处理次依赖)、`--report`(报告路径)等。

---

## 15.8 jit_compiler 工具(反向依赖图 + JIT)

`jit_compiler` 是资产管线最复杂的工具,本章的"特色实现"。它是 WTL GUI 守护进程,常驻后台,通过命名管道给游戏客户端提供 JIT 资产服务。

### 15.8.1 JITCompiler 四重继承

`JITCompiler` 通过多重继承同时扮演四个角色:

```cpp
// programming/bigworld/tools/jit_compiler/jit_compiler.hpp L13-17
class JITCompiler : public AssetCompiler
                  , public AssetServer
                  , public ResourceModificationListener
                  , public PluginLoader
```

| 基类 | 角色 | 关键方法 |
|---|---|---|
| `AssetCompiler` | 资产编译器 | `ensureCompiled()`、`queueTask()`、`pause()/resume()` |
| `AssetServer` | 命名管道 IPC 服务器 | `broadcastAsset()`、`onAssetRequested()`(纯虚) |
| `ResourceModificationListener` | 文件监听器 | `onResourceModified()` |
| `PluginLoader` | 插件加载器 | `initPlugins()`、`finiPlugins()` |

四重继承让 JITCompiler 一身兼任:既编译资产、又服务客户端请求、又监听文件变更、又加载插件。这是典型的"组合优于继承"的反例——但这里用多重继承是为了让每个角色都是接口契约,编译器强制要求实现所有纯虚函数。

### 15.8.2 双线程架构

jit_compiler 启动两个后台线程:

**扫描线程**(一次性):

```cpp
// jit_compiler.cpp L49-62
void JITCompiler::scanningThreadMain()
{
    store_.scanningStarted();

    // 逆序扫描所有资源路径(mod 路径优先)
    int numPaths = BWResource::getPathNum();
    for (int i = numPaths; i > 0 && !terminating(); --i)
    {
        BW::string path = BWResource::getPath( i - 1 );
        taskFinder_.findTasks( path );   // 递归扫描,发现所有任务
    }

    store_.scanningStopped();
}
```

扫描线程逆序遍历所有资源路径——这通常对应"mod 路径优先于 base 路径"。扫描完后线程退出,任务都进了队列等待管理线程处理。

**管理线程**(循环):

```cpp
// jit_compiler.cpp L64-77
void JITCompiler::managingThreadMain()
{
    while (!terminating())
    {
        event_.wait( 1000 );                          // 等待事件或 1 秒超时
        taskProcessor_.processTasks();                // 处理任务队列

        MF_VERIFY( WaitForSingleObject( taskSemaphore_, INFINITE ) == WAIT_OBJECT_0 );
        BWResource::instance().flushModificationMonitor();  // 刷新文件监听
        MF_VERIFY( ReleaseSemaphore( taskSemaphore_, 1, NULL ) );
    }
}
```

每轮循环:
1. `event_.wait(1000)`:等待事件触发(有新请求)或 1 秒超时
2. `taskProcessor_.processTasks()`:处理队列
3. 等所有工作线程完成
4. 刷新文件监听器,触发 `onResourceModified` 回调
5. 释放信号量,进入下一轮

**为什么需要 `taskSemaphore_` 配合?**——`flushModificationMonitor()` 会触发文件变更回调,但回调里要操作反向依赖图。如果在任务还在写文件时刷新,会产生虚假变更通知(任务自己写文件被监听器当成外部修改)。所以先等所有任务完成(信号量获取)、刷新、再释放。

### 15.8.3 反向依赖图

这是 jit_compiler 的核心创新,解决"文件变更 → 哪些任务受影响"的快速查找。JITCompiler 维护两张映射表:

```cpp
// jit_compiler.hpp L86-93
typedef BW::vector<BW::string> DirectoryDependencies;
typedef BW::vector<std::pair<ConversionTask *, bool>> ReverseDependencies;
typedef StringHashMap<ReverseDependencies> ReverseDependencyMap;
typedef BW::vector<StringRef> ForwardDependencies;
typedef BW::map<ConversionTask*, ForwardDependencies> ForwardDependencyMap;

DirectoryDependencies directoryDependencies_;     // 目录依赖列表
ReverseDependencyMap reverseDependencyMap_;       // 文件 → [(任务, isOutput)]
ForwardDependencyMap forwardDependencyMap_;       // 任务 → [文件路径]
```

**双向映射**:

| 映射 | 键 → 值 | 用途 |
|---|---|---|
| `reverseDependencyMap_` | 文件路径 → [(任务, isOutput)] | 文件变更时查找受影响任务 |
| `forwardDependencyMap_` | 任务 → [文件路径] | 任务重新入队时清理旧的反向依赖 |
| `directoryDependencies_` | ["目录>模式>正则>递归", ...] | 目录依赖的特殊处理 |

`isOutput` 标志区分依赖项是任务的**输出**(true)还是**输入**(false)——输出文件变更通常是任务自己产生的,不需要重建,所以 `collectReverseDependencies` 时可以跳过 `isOutput=true` 的项。

**反向依赖的建立**:任务完成时(`onTaskCompleted`),读取它的 `.deps` 文件,把所有 input/output 路径加入反向映射:

```cpp
// 伪代码(基于 jit_compiler.cpp addReverseDependency 三个重载)
void JITCompiler::addReverseDependency( const BW::string & path,
                                        bool isOutput,
                                        ConversionTask & conversionTask )
{
    reverseDependencyMap_[path].push_back( std::make_pair( &conversionTask, isOutput ) );
    forwardDependencyMap_[&conversionTask].push_back( path );  // 同步正向映射
}
```

**反向依赖的查询**:文件变更时(`onResourceModified`),查 `reverseDependencyMap_[文件]`,拿到所有受影响任务:

```cpp
// jit_compiler.cpp L386-440 (简化)
void JITCompiler::onResourceModified( const StringRef & basePath,
                                      const StringRef & resourceID,
                                      Action modType )
{
    BW::string fullPath = basePath + resourceID;
    
    // 清理缓存
    purgeResource( resourceID );
    purgeResource( fullPath );
    
    BW::vector< ConversionTask * > tasks;
    
    if (modType == Action::ACTION_ADDED)
    {
        // 新增文件:可能需要创建新根任务
        ConversionTask * rootTask = taskFinder_.getTask( fullPath, true );
        if (rootTask != NULL)
            tasks.push_back( rootTask );
    }
    
    // 收集所有依赖此文件的任务
    bool includeOutputs = !checkFileHashUpToDate( fullPath );
    collectReverseDependencies( fullPath, includeOutputs, tasks );
    collectReverseDependencies( path, filename, tasks );   // 目录模式匹配
    
    // 重置每个受影响任务并重新入队
    for (auto task : tasks)
    {
        task->status_ = ConversionTask::NEW;
        task->subTasks_.clear();
        store_.resetTask( task );
        // ... 入队
    }
    
    event_.set();   // 唤醒管理线程
}
```

**关键优化**:`collectReverseDependencies` 在收集任务时**同步清理双向映射**,因为任务重新完成后会重建反向依赖,旧的会自动覆盖。这避免了脏数据。

### 15.8.4 命名管道 IPC 与游戏客户端通信

`AssetServer`(`lib/asset_pipeline/asset_server.hpp`)是命名管道服务器,游戏客户端连接它来请求资产:

```cpp
// programming/bigworld/lib/asset_pipeline/asset_server.hpp L11-39
class AssetServer : SimpleThread
{
public:
    void broadcastAsset( const StringRef & asset );    // 广播资产已就绪
protected:
    virtual void onAssetRequested( const StringRef & asset ) = 0;  // 纯虚
    virtual void lock() = 0;
    virtual void unlock() = 0;
private:
    void processCommand( HANDLE hPipe, const StringRef & command );
    BW::map<HANDLE, SimpleThread*> pipeThreads_;   // 每个客户端一个线程
    BW::vector<HANDLE> lockedPipes_;
};
```

工作流程:

1. 游戏客户端启动时,连接到 jit_compiler 的命名管道(管道名由 `AssetPipe` 生成,基于资源路径)
2. 客户端要加载某资产时,通过管道发送资产路径
3. `AssetServer` 收到后调用 `onAssetRequested`(`JITCompiler` 实现)
4. JITCompiler 把对应任务推到队首,通知管理线程处理
5. 任务完成后,`broadcastAsset` 把"资产已就绪"消息广播给所有连接的客户端
6. 客户端收到通知,重新加载资产

`onAssetRequested` 的实现:

```cpp
// jit_compiler.cpp L298-373 (简化)
void JITCompiler::onAssetRequested( const StringRef & asset )
{
    BW::string sourceFile;
    bool found = getSourceFile( asset, sourceFile );
    if (!found)
    {
        broadcastAsset( asset );   // 找不到源文件,直接广播"已完成"
        return;
    }
    
    ConversionTask & task = taskFinder_.getTask( sourceFile );
    if (task.converterId_ == ConversionTask::s_unknownId)
    {
        broadcastAsset( asset );   // 无 Converter 处理,直接广播
        return;
    }
    
    // 把任务推到队首(优先处理)
    if (task.status_ == ConversionTask::QUEUED)
    {
        // 已在队列,挪到队首
        taskQueue_.erase( std::find( taskQueue_.begin(), taskQueue_.end(), &task ) );
        task.status_ = ConversionTask::NEW;
    }
    if (task.status_ == ConversionTask::NEW)
    {
        taskQueue_.push_front( &task );
        task.status_ = ConversionTask::QUEUED;
    }
    
    if (task.status_ >= ConversionTask::DONE)
    {
        // 已完成,检查是否需要重建
        if (!BWResource::instance().hasPendingModification( relativeSourceFile ))
        {
            broadcastAsset( asset );   // 已最新,直接广播
            return;
        }
    }
    
    // 记录请求,任务完成后广播
    requests_.push_back( std::make_pair( &task, asset.to_string() ) );
    
    store_.addRequestedTask( &task );
    event_.set();   // 唤醒管理线程
}
```

**lock/unlock 机制**:`AssetServer` 还支持客户端锁定/解锁编译器——客户端在做关键操作(如加载关卡)时,可以 `lock()` 暂停编译器,避免编译产物在加载中途变化;操作完成后 `unlock()` 恢复。`JITCompiler` 实现 `lock` 调用 `pause()`,`unlock` 调用 `resume()`。

### 15.8.5 JIT 编译的工程价值

"JIT(Just-In-Time)"在这里的含义是:**资产不是预先全部编译好,而是按需编译**。游戏客户端启动时不要求所有资产都 ready——它一边运行一边按需请求,jit_compiler 收到请求才编译。

这种模式给开发带来的体验:

- **美术改纹理,即时看到**:美术保存 `.tga`,文件监听触发 `onResourceModified`,反向依赖图找到所有引用此纹理的 `.texture` 任务,推到队首编译,完成后广播给客户端,客户端热重载。整个过程几秒内完成。
- **不用全量预编译**:大型 MMO 项目可能有几十万资产,全量编译要几小时。JIT 模式下美术只需要测自己改的那几个,秒级响应。
- **多人协作无冲突**:每个开发者本地跑 jit_compiler,自己的改动自己测,不影响他人。需要发布时再用 batch_compiler 做全量。

这种"按需编译 + 文件监听 + 反向依赖图"的组合,使得 BigWorld 在 2010 年代初就实现了类似 Unity 的 Hot Reload 体验,但架构上更工程化。

---

## 15.9 assetprocessor 工具

`assetprocessor` 是个特殊的工具——它**不是 AssetCompiler 的子类**,而是独立 DLL,提供 Python 模块 `_AssetProcessor`。它专门处理需要 D3D 渲染设备的高级资产操作。

### 15.9.1 DLL 形态与 Python 模块

```cpp
// programming/bigworld/tools/assetprocessor/assetprocessor.hpp L16-21
extern "C"
{
    extern ASSETPROCESSOR_API void init_AssetProcessor();
}
```

`init_AssetProcessor()` 是 Python C 扩展的入口,被 Python 解释器通过 `import _AssetProcessor` 调用:

```cpp
// programming/bigworld/tools/assetprocessor/assetprocessor.cpp L21-28
ASSETPROCESSOR_API void init_AssetProcessor()
{	
    AssetProcessorScript::init();
    PyErr_Clear();
}
```

`AssetProcessorScript::init()` 做了大量初始化工作:

```cpp
// asset_processor_script.cpp L87-156 (节选)
void init()
{
    if (g_inited) return;

    BWResource::init( argc, NULL );
    Script::init( paths, "assetprocessor" );   // 启动 Python 解释器
    MaterialKinds::init();
    AutoConfig::configureAllFrom( "resources.xml" );
    Moo::init( true, true );                    // 初始化 Moo 渲染
    
    // 创建隐藏窗口 + D3D 设备
    HWND hWnd = CreateWindow( APP_NAME, APP_NAME, WS_OVERLAPPED, 
                              0, 0, 256, 256, NULL, NULL, hInst, NULL );
    s_pRenderer.reset( new Renderer );
    s_pRenderer->init( true, true );
    Moo::rc().createDevice( hWnd );             // 创建 D3D 设备
    
    // 预加载所有 shader 顶点格式
    DataSectionPtr ptr = BWResource::instance().openSection("shaders/formats");
    if (ptr)
    {
        for (auto it = ptr->begin(); it != ptr->end(); ++it)
        {
            BW::string format = (*it)->sectionName();
            Moo::VertexDeclaration::get( format );
        }
    }
    
    PyImport_AddModule( "_AssetProcessor" );
    g_inited = true;
}
```

**为什么需要 D3D 设备?** 因为 assetprocessor 要做的事情——BSP2 生成、shader 编译、顶点格式转换——都需要 GPU 参与。比如 BSP 生成要从 `.visual` 提取三角形,BSP 树构建需要顶点位置;shader 编译需要 D3D 编译器;顶点格式转换需要 D3D 顶点声明。这些操作不能纯 CPU 完成。

### 15.9.2 BSP2 升级

`generateBSP2` 是 assetprocessor 的核心功能之一,为 `.visual` 生成 BSP2 数据:

```cpp
// asset_processor_script.cpp L383+ (函数签名,简化)
BW::string generateBSP2( const BW::string& resourceID,
                          Moo::BSPProxyPtr& ret,
                          BW::vector<BW::string>& retMaterialIDs,
                          uint32& nVisualTris,
                          uint32& nDegenerateTris );
```

它读取 `.visual` 文件,提取所有几何体的三角形,构建 BSP 树,返回 BSP 代理对象。BSP 用于客户端的碰撞检测、可见性剔除等。

`replaceBSPData` 把生成的 BSP2 数据写回 `.primitives` 文件:

```cpp
// asset_processor_script.cpp L581-621 (节选,简化)
BW::string replaceBSPData( const BW::string& visualName,
                            Moo::BSPProxyPtr pGeneratedBSP,
                            BW::vector<BW::string>& bspMaterialIDs )
{
    // 打开 .primitives 文件
    // 写入 bsp2 段(二进制)
    p->writeBinary( "bsp2", bp );
    p->writeBinary( "bsp2_materials", materialIDsSection->asBinary() );
    
    ret = "BSP2 data created successfully for " + visualName;
    return ret;
}
```

### 15.9.3 shader 编译与顶点格式升级

assetprocessor 还提供:

- `shaderNeedsRecompile(resourceID, macroCombination)`:检查 shader 在给定宏组合下是否需要重新编译
- `upgradeHardskinnedVertices(resourceID, ret)`:把硬皮肤顶点格式升级(从 `xyznuv` 升到 `xyznuviww` 等)
- `populateWorldTriangles`:把 visual 的几何三角形填充到 `RealWTriangleSet`,供 BSP 生成使用

这些功能都是 World Editor 在编辑时调用的——比如用户在编辑器里"重新生成 BSP",编辑器会通过 Python 调用 `_AssetProcessor.generateBSP2` 和 `replaceBSPData`。

### 15.9.4 DllMain 与生命周期

DLL 的 `DllMain` 处理加载/卸载:

```cpp
// assetprocessor.cpp L31-51
BOOL __stdcall DllMain( HANDLE hModule, DWORD Reason, LPVOID Reserved )
{
    // 注意:进程退出时 DLL 卸载顺序不确定,
    // D3D 可能先卸载,导致我们的 D3D 指针无效崩溃。
    // 所以建议显式调用 _AssetProcessor.fini。
    if (Reason == DLL_PROCESS_DETACH && Reserved == 0)
    {
        AssetProcessorScript::fini();
    }
    return TRUE;
}
```

注释里特别提醒:**显式调用 `_AssetProcessor.fini` 比依赖 DllMain 更安全**。这是因为 Windows DLL 卸载顺序不保证,如果 D3D 的 DLL 先卸载,assetprocessor 析构时访问 D3D 指针会崩溃。这是一个常见的 Windows 平台 DLL 编程陷阱。

---

## 15.10 特色实现深度剖析

### 15.10.1 ConversionTask 状态机的设计精妙

为什么 BigWorld 要用状态机而不是简单的"流水线函数调用"?这是资产管线最值得品味的设计。

**普通流水线**的问题:假设我们用纯函数式调用 `compile(file)`,内部 `createDeps → convert → writeOutput`。当任务 A 依赖任务 B 时,要等待 B 完成——直接同步等待会死锁(单线程时 B 永远不会跑),多线程时又复杂。而且如果 B 又依赖 C、C 依赖 D,调用栈会非常深。

**状态机的解法**:把"等待"显式化。任务 A 处理到 NEEDS_SECONDARY_DEPS 时发现 B 没就绪,就**挂起自己**(`onTaskSuspended`),放回队列。B 跑完后,A 被恢复(`onTaskResumed`)从中断点继续。这样:

- 单线程也能跑(挂起后队列里有 B,getNextTask 取出 B 处理,B 完成后再取 A 恢复)
- 多线程自然(不同线程可以同时处理 A 和 B)
- 调用栈不深(每次只处理一个阶段)
- 状态可观察(调试时能看到每个任务在哪个阶段)

这种"状态机 + 任务队列 + 挂起/恢复"模式,与操作系统调度进程的状态机(NEW → READY → RUNNING → WAITING → TERMINATED)如出一辙。BigWorld 把"任务"当成"进程"来调度,这是它设计上的高明之处。

**NEEDS_PRIMARY_DEPS 和 NEEDS_SECONDARY_DEPS 为什么要分开?** 因为两类依赖的语义不同:

- 主依赖(SourceFile、Converter、ConverterParams)是"任务身份",变了就要完全重建,且主依赖不依赖其他任务
- 次依赖是任务引用的其他资产,可能需要递归编译其他任务

分开后,主依赖检查可以快速短路(主依赖没变就跳过整个 createDependencies 调用),次依赖检查可以走递归流程。这是性能优化的分层。

### 15.10.2 反向依赖图的增量编译

传统的"make 风格"增量构建是正向的:从目标文件开始,递归检查它的依赖是否最新,递归向下传播重建。这对静态项目很好,但对**文件变更驱动**的 JIT 场景不友好——文件变更后,要找出所有"最终产出依赖于此文件"的任务,正向图很难反查。

BigWorld 的反向依赖图解决的就是这个问题。它维护"文件 → 任务"的反向映射,文件变更时直接查表得到受影响任务列表,O(1) 查找(假设哈希表)。

**双向映射的必要性**:仅维护反向图的话,任务重新入队时无法清理旧的依赖记录,会导致反向图越来越大、有脏数据。所以同时维护正向图(`任务 → 它依赖的文件`),清理时按正向图遍历删除反向图的对应条目,然后清空正向图,等任务完成时重建。

这是一个典型的"空间换时间"设计:多用一倍内存存双向图,换取 O(1) 的增量查找。

**目录依赖的特殊处理**:`DirectoryDependency` 的反向依赖用 `"目录>模式>正则>递归"` 字符串作为键,匹配时用 RE2 正则库。这是因为目录依赖是"通配符"性质——`textures/*.dds` 变了,所有依赖此模式的任务都受影响。用字符串作为键让目录依赖可以和文件依赖共用同一张哈希表。

### 15.10.3 JIT 编译的工程价值

JIT 编译模式给 BigWorld 项目带来的工程价值,可以从三个维度衡量:

**美术体验**:传统流程是"美术改文件 → 美术自己跑 batch_compiler 编译 → 把编译产物给程序 → 程序重启客户端看效果",循环周期几分钟到十几分钟。JIT 模式下,美术保存文件,客户端几秒内看到效果,循环周期从分钟降到秒。这极大提升了美术迭代效率,直接影响美术产能。

**策划体验**:策划改个数值配置、调个粒子参数,JIT 模式下立即生效。无需重启客户端、无需预编译。

**程序体验**:程序改 shader、改 visual,本地 jit_compiler 即时编译,客户端热重载。不像传统引擎那样要重新打包资源。

**多人协作**:每个开发者本地一个 jit_compiler,自己的改动自己测。需要发布时,CI 跑 batch_compiler 做全量构建。开发与发布解耦。

这种模式后来被 Unity 的 Asset Pipeline V2、Unreal 的 Live Coding 等广泛采纳,BigWorld 在 2010 年代初就走在这条路上,工程前瞻性很强。

### 15.10.4 内容寻址缓存的去重

内容寻址缓存(Content-addressable cache)是 BigWorld 的另一个工程亮点,灵感来自 Git 的对象存储。它的核心思想:**用文件内容的哈希作为存储键,而不是文件路径**。

**去重效果**:假设项目里有 100 个 `.visual` 都引用同一个 `default_diffuse.tga` 纹理。传统缓存按路径存,会有 100 份相同的 `.texture`(每个 visual 的目录下各一份)。内容寻址缓存按内容哈希存,只存一份,所有引用方共享。

**跨项目共享**:不同项目编译同一资源,得到同一哈希,缓存只存一份。新人拉代码后第一次构建,大量产物从团队缓存命中,首次构建时间从几小时降到几分钟。

**抗损坏**:哈希校验内置。读取缓存后还会校验内容哈希,不匹配则丢弃(`WARNING_MSG "Corrupted dependency list retrieved from the cache"`),不会用损坏的缓存数据。

**简化分发**:缓存可以放 NAS、可以打包传输、可以并行多机共享。不用关心"哪个文件对应哪个产物"的映射关系,只用哈希就能找到。

这种缓存模式现在已经是构建系统的标配(Bazel、Buck、Nix 都用),但 BigWorld 在 2010 年代初就实现了,且和资产管线深度集成,自动通过 `ConverterInfo::CACHE_DEPENDENCIES` / `CACHE_CONVERSION` flags 控制哪些产物入缓存——这让 Converter 作者不必操心缓存逻辑,只需声明"我的产物可缓存"。

### 15.10.5 ConverterGuard 的读写锁策略

`ConverterGuard` 用单例读写锁 + `s_pendingWrites` 计数器,实现了一个微妙的并发策略:

```cpp
// task_processor.cpp L45-89 (节选)
if (threadSafe_)
{
    while (s_pendingWrites > 0)
        Sleep( 0 );   // 有写请求排队,让它们先
    s_lock_.beginRead();   // 共享读
    return;
}

InterlockedIncrement( &s_pendingWrites );
s_lock_.beginWrite();   // 独占写
InterlockedDecrement( &s_pendingWrites );
```

**为什么需要 `s_pendingWrites`?** 如果只有读写锁,新来的读请求会立即获取读锁,即使有写请求在排队——这会导致写饿死(读源源不断,写永远等不到)。`s_pendingWrites` 让新读请求先让排队的写请求跑完,实现"写优先"。

**为什么用单例锁?** 所有 Converter 共享一个 `s_lock_`,这意味着即使是不同的 Converter,只要都声明 THREAD_SAFE,就都共享同一把读锁——它们可以同时跑。但任一非线程安全 Converter 跑时,所有 Converter 都得等它完成。

这种"全局读写锁"对资产管线的实际负载是合理的:大部分 Converter(纹理压缩、visual 处理)是线程安全的,可以充分并行;少数非线程安全的(BSP 生成、shader 编译)需要独占,但执行频率低,不会成为瓶颈。

---

## 15.11 本章小结

本章我们剖析了 BigWorld Engine 14.4.1 的资产管线系统,从概念到实现:

1. **资源管线概述**:资产管线是把原始资源(DCC 产出)转换为运行时资产的构建系统,核心职责是任务发现、依赖管理、转换调度、缓存和多线程。

2. **四大子模块**:
   - `compiler`:Compiler 抽象基类 + AssetCompiler 实现基类,提供 40+ 接口方法
   - `conversion`:ConversionTask 状态机 + TaskProcessor 三阶段处理 + ConverterGuard 读写锁 + ContentAddressableCache 内容寻址缓存
   - `dependency`:6 种依赖类型(SourceFile/IntermediateFile/OutputFile/Converter/ConverterParams/Directory)+ DependencyList 容器
   - `discovery`:TaskFinder 递归遍历 + ConversionRule 模式匹配

3. **三个上层工具**:
   - `batch_compiler`:CLI 批量编译,生成 HTML 报告,支持 Ctrl-C 优雅终止
   - `jit_compiler`:GUI 守护进程,反向依赖图 + 命名管道 IPC + JIT 编译
   - `assetprocessor`:DLL + Python 模块,BSP2 升级、shader 编译等需 D3D 的操作

4. **特色实现**:
   - ConversionTask 状态机的"挂起-恢复"机制,让多任务并行处理依赖图成为可能
   - 反向依赖图让"文件变更 → 受影响任务"O(1) 查找
   - JIT 编译模式让美术迭代周期从分钟降到秒
   - 内容寻址缓存实现跨项目、跨机器的去重共享
   - ConverterGuard 的"写优先"读写锁避免写饿死

资产管线是 BigWorld 工具链中工程量最大、设计最精细的部分之一。它体现的"声明式、依赖驱动、可缓存、可并行"思想,与现代构建系统(Bazel、Buck2、Ninja)一脉相承,但针对游戏资源的特殊性(混合依赖、二进制产物、D3D 依赖)做了大量定制。理解了资产管线,你就理解了 BigWorld 工具链的"中轴线"——所有美术资源都流经这里,然后才能被引擎使用。

下一章我们会看 **World Editor**——这是策划/美术编辑世界的工具,它产出的 `.chunk`、`.scene` 等文件,正是资产管线的下游消费者。我们会看到编辑器如何把资产组织成场景、如何管理关卡、如何与客户端的 Chunk 系统对接。

---

> **延伸阅读**:
> - 第 13 章:客户端应用框架与 Moo 渲染——assetprocessor 依赖的 D3D 设备来自 Moo
> - 第 14 章:Chunk 空间加载系统——资产管线的下游消费者
> - 第 16 章:World Editor——调用 assetprocessor 做 BSP 升级等
> - 第 17 章:DCC 导出器与 navgen——DCC 导出的原始资源是资产管线的输入
> - `docs/tools/BigWorld工具-asset_pipeline实现分析.md`:更详细的实现分析
> - `docs/tools/BigWorld工具-jit_compiler实现分析.md`:JIT 编译器的完整剖析
> - `docs/tools/BigWorld工具-batch_compiler实现分析.md`:batch_compiler 详解
> - `docs/tools/BigWorld工具-assetprocessor实现分析.md`:assetprocessor 详解
