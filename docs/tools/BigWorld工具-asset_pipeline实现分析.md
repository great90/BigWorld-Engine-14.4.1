# BigWorld 工具 asset_pipeline 实现分析

> 本文档详细分析 BigWorld Engine 14.4.1 中 asset_pipeline(资产管线核心库)的架构与实现。asset_pipeline 是 batch_compiler 与 jit_compiler 共同依赖的底层编译框架,负责资产任务的发现、依赖管理、状态机驱动的转换以及多线程调度。

---

## 目录

- [一、概述与定位](#一概述与定位)
- [二、整体架构](#二整体架构)
- [三、目录结构](#三目录结构)
- [四、入口点与启动流程](#四入口点与启动流程)
- [五、核心类与继承关系](#五核心类与继承关系)
  - [5.1 Compiler 抽象基类](#51-compiler-抽象基类)
  - [5.2 AssetCompiler 实现基类](#52-assetcompiler-实现基类)
  - [5.3 Converter 插件接口](#53-converter-插件接口)
  - [5.4 ConversionRule 规则接口](#54-conversionrule-规则接口)
- [六、关键算法与数据结构](#六关键算法与数据结构)
  - [6.1 ConversionTask 状态机](#61-conversiontask-状态机)
  - [6.2 DependencyList 依赖列表](#62-dependencylist-依赖列表)
  - [6.3 6 种 Dependency 类型](#63-6-种-dependency-类型)
  - [6.4 TaskProcessor 三阶段处理](#64-taskprocessor-三阶段处理)
  - [6.5 TaskFinder 任务发现](#65-taskfinder-任务发现)
  - [6.6 内容寻址缓存](#66-内容寻址缓存)
  - [6.7 循环依赖检测](#67-循环依赖检测)
  - [6.8 多线程调度与 ConverterGuard](#68-多线程调度与-converterguard)
- [七、配置项与命令行参数](#七配置项与命令行参数)
- [八、与其他模块的依赖关系](#八与其他模块的依赖关系)
- [九、关键代码片段](#九关键代码片段)
- [十、设计亮点与注意事项](#十设计亮点与注意事项)

---

## 一、概述与定位

`asset_pipeline` 是 BigWorld Engine 工具链中的**资产编译核心库**,代码量约 8500 行(4 个核心子模块),其本质是一个**声明式、依赖驱动的资产构建系统**,类似于一个针对游戏资源定制的 `make`/`ninja`。

它的核心职责包括:

1. **任务发现(Discovery)**:递归扫描资源目录,根据规则匹配生成"根任务",并能从输出文件反查源文件。
2. **依赖管理(Dependency)**:维护每个任务的 primary/secondary 依赖列表,持久化为 `.deps` 文件,通过哈希校验判定是否过期。
3. **转换调度(Conversion)**:驱动一个状态机 `NEW → QUEUED → PROCESSING → NEEDS_PRIMARY_DEPS → NEEDS_SECONDARY_DEPS → NEEDS_CONVERSION → DONE`,在状态切换时回调 Converter 插件。
4. **缓存(Cache)**:基于内容哈希的内容寻址缓存(ContentAddressableCache),用于跨构建共享依赖列表与中间产物。
5. **多线程(Threading)**:通过 `BgTaskManager` 拉起后台工作线程,以 `ReadWriteLock` 区分线程安全与非线程安全 Converter。

asset_pipeline 本身**不是可执行程序**,而是一个静态库,被以下两个工具复用:

- **batch_compiler**:CLI 批量编译工具,把整个目录扫一遍一次性编译完。
- **jit_compiler**:WTL GUI 守护进程,常驻后台,基于反向依赖图做增量编译,通过命名管道为游戏客户端提供 JIT 资产服务。

这种"核心库 + 多种前端"的设计让两者共享同一套编译逻辑,只在"何时编译什么"上不同。

---

## 二、整体架构

asset_pipeline 内部分为 4 个子模块,采用经典的"分层 + 插件"结构:

```
┌──────────────────────────────────────────────────────────────────────┐
│                      上层工具(batch_compiler / jit_compiler)        │
│        继承 AssetCompiler,重写 onTask* / onPreConvert 等回调         │
└──────────────────────────────────────────────────────────────────────┘
                                  │ 依赖
                                  ▼
┌──────────────────────────────────────────────────────────────────────┐
│                          compiler 子模块                             │
│   ┌──────────────┐  ┌──────────────────┐  ┌──────────────────────┐   │
│   │ Compiler     │←─│ AssetCompiler    │  │ AssetCompilerOptions │   │
│   │ (抽象接口)   │  │ (实现 + 单实例锁)│  │ (命令行解析)         │   │
│   └──────────────┘  └──────────────────┘  └──────────────────────┘   │
│   ┌────────────────────┐  ┌────────────────────────────────┐         │
│   │ GenericConversion  │  │ ResourceCallbacks              │         │
│   │ Rule(asset_rules)  │  │ (资源事件回调,如 purgeResource)│         │
│   └────────────────────┘  └────────────────────────────────┘         │
└──────────────────────────────────────────────────────────────────────┘
                                  │ 组合
                                  ▼
┌─────────────────────────┬──────────────────────────┬────────────────┐
│  discovery 子模块       │  conversion 子模块       │ dependency 子  │
│                         │                          │ 模块           │
│ ┌────────────┐          │ ┌────────────────────┐   │                │
│ │TaskFinder  │          │ │ TaskProcessor      │   │ DependencyList │
│ │(递归遍历)  │          │ │ (状态机驱动)       │   │ (primary/      │
│ └────────────┘          │ └────────────────────┘   │  secondary     │
│ ┌────────────┐          │ ┌────────────────────┐   │  inputs/       │
│ │ConversionRule│        │ │ ConverterMap       │   │  outputs)      │
│ │(规则匹配)  │          │ │ ConverterInfo      │   │                │
│ └────────────┘          │ │ Converter(插件)    │   │ 6 种 Dependency│
│                         │ └────────────────────┘   │  子类          │
│                         │ ┌────────────────────┐   │                │
│                         │ │ContentAddressable- │   │                │
│                         │ │Cache(内容寻址缓存) │   │                │
│                         │ └────────────────────┘   │                │
└─────────────────────────┴──────────────────────────┴────────────────┘
                                  │ 加载
                                  ▼
┌──────────────────────────────────────────────────────────────────────┐
│           converters 插件目录(各自独立 DLL/静态库)                  │
│  visual_processor / texture_converter / texformat_converter /        │
│  space_converter / primitive_processor / hierarchical_config_        │
│  converter / effect_converter / bsp_converter                        │
└──────────────────────────────────────────────────────────────────────┘
```

整体调用流如下(简化):

```
TaskFinder.findTasks(dir)
    └─> ConversionRule.createRootTask() ─> ConversionTask(NEW)
            └─> AssetCompiler.queueTask() ─> ConversionTask(QUEUED)
                    └─> TaskProcessor.processTask()
                            ├─> processNewTask()              [→ NEEDS_PRIMARY_DEPS]
                            ├─> processPrimaryDependencies()  [→ NEEDS_SECONDARY_DEPS]
                            │       └─> Converter.createDependencies()
                            ├─> processSecondaryDependencies()[→ NEEDS_CONVERSION]
                            │       └─> Compiler.ensureUpToDate() (递归子任务)
                            └─> processConversion()            [→ DONE]
                                    └─> Converter.convert()
```

---

## 三、目录结构

asset_pipeline 源码位于 `programming/bigworld/tools/asset_pipeline/`,目录组织如下:

```
asset_pipeline/
├── compiler/                          # 编译器接口与实现
│   ├── compiler.hpp                   # Compiler 抽象基类(170 行)
│   ├── asset_compiler.hpp             # AssetCompiler 声明(168 行)
│   ├── asset_compiler.cpp             # AssetCompiler 实现(1270 行)
│   ├── asset_compiler_options.hpp     # 选项配置(命令行/数据段)
│   ├── asset_compiler_options.cpp
│   ├── generic_conversion_rule.hpp    # 通用规则(读 asset_rules.xml)
│   ├── generic_conversion_rule.cpp
│   ├── resource_callbacks.hpp         # 资源事件回调接口
│   ├── resource_callbacks.cpp
│   ├── test_compiler/                 # 单元测试用编译器
│   └── unit_test/                     # 单元测试
│
├── conversion/                        # 转换子模块
│   ├── conversion_task.hpp            # ConversionTask 结构(状态机)
│   ├── conversion_task_queue.hpp      # 任务队列(基于 deque)
│   ├── task_processor.hpp             # TaskProcessor 声明(142 行)
│   ├── task_processor.cpp             # TaskProcessor 实现(1027 行)
│   ├── converter.hpp                  # Converter 插件接口
│   ├── converter_info.hpp             # ConverterInfo 元信息
│   ├── converter_creator.hpp          # ConverterCreator 函数指针类型
│   ├── converter_map.hpp              # id → ConverterInfo 映射
│   ├── content_addressable_cache.hpp  # 内容寻址缓存(34 行)
│   └── content_addressable_cache.cpp
│
├── dependency/                        # 依赖子模块
│   ├── dependency.hpp                 # Dependency 基类 + 6 种类型宏
│   ├── dependency.cpp
│   ├── dependency_list.hpp            # DependencyList 容器
│   ├── dependency_list.cpp
│   ├── source_file_dependency.hpp     # 源文件依赖
│   ├── intermediate_file_dependency.hpp  # 中间文件依赖
│   ├── output_file_dependency.hpp     # 输出文件依赖
│   ├── converter_dependency.hpp       # Converter 自身依赖(版本)
│   ├── converter_params_dependency.hpp   # Converter 参数依赖
│   ├── directory_dependency.hpp       # 目录依赖(支持正则/递归)
│   └── unit_test/
│
├── discovery/                         # 发现子模块
│   ├── task_finder.hpp                # TaskFinder 声明(44 行)
│   ├── task_finder.cpp                # TaskFinder 实现(258 行)
│   ├── conversion_rule.hpp            # ConversionRule 抽象
│   └── conversion_rules.hpp           # ConversionRules 容器
│
└── converters/                        # 内置 Converter 插件
    ├── visual_processor/              # .visual 处理
    ├── texture_converter/             # 纹理转换
    ├── texformat_converter/           # 纹理格式转换
    ├── space_converter/               # Space(空间)转换
    ├── primitive_processor/           # .primitives 处理
    ├── hierarchical_config_converter/ # 层级配置合并
    ├── effect_converter/              # .fx Effect 编译
    └── bsp_converter/                 # BSP 转换
```

每个 converter 子目录通常包含 `plugin_main.cpp`(插件注册入口)、`xxx_converter.hpp/cpp`(Converter 实现)、可选的 `xxx_conversion_rule.hpp/cpp`(配套规则)。

---

## 四、入口点与启动流程

asset_pipeline 是库,本身没有 `main`。但其 `AssetCompiler` 提供了两个关键生命周期方法,被上层工具调用:

| 方法 | 位置 | 作用 |
|---|---|---|
| `AssetCompiler::AssetCompiler()` | `asset_compiler.cpp:41-92` | 构造,创建互斥锁确保单实例 |
| `AssetCompiler::initCompiler()` | `asset_compiler.cpp:106-139` | 加载规则、启动 BgTaskManager、注册消息回调 |
| `AssetCompiler::finiCompiler()` | `asset_compiler.cpp:141-159` | 终止后台线程、关闭信号量、注销回调 |
| `AssetCompiler::~AssetCompiler()` | `asset_compiler.cpp:94-104` | 关闭所有互斥锁句柄 |

### 4.1 构造期的单实例互斥锁

asset_pipeline 在每个资源路径上**只允许运行一个实例**,通过命名互斥锁在构造期强制保证。代码位于 `asset_compiler.cpp:41-92`:

```cpp
41→AssetCompiler::AssetCompiler()
42→	: state_( INVALID )
43→	, recursive_( false )
44→	, forceRebuild_( false )
45→	, numThreads_( 1 )
46→	, intermediatePath_()
47→	, outputPath_()
48→	, taskFinder_( *this, conversionRules_ )
49→	, taskProcessor_( *this, converterMap_, true )
50→	, genericConversionRule_( converterMap_ )
51→{
52→	BW::vector< BW::wstring > baseResourcePaths = AssetPipe::getBaseResourcePaths();
53→	for (BW::vector< BW::wstring >::iterator
54→		it = baseResourcePaths.begin(); it != baseResourcePaths.end(); ++it)
55→	{
56→		BW::wstring mutexName = L"Local\\AssetPipeline" + *it;
57→		HANDLE compilerMutex = CreateMutexW( 0, TRUE, mutexName.c_str() );
58→		if(GetLastError() == ERROR_ALREADY_EXISTS)
59→		{
60→			::MessageBox( NULL,
61→				L"Only one instance of the AssetPipeline is allowed to be active per resource path.",
62→				L"AssetPipeline",
63→				MB_OK );
64→			exit(-1);
65→		}
66→		compilerMutexes_.push_back( compilerMutex );
67→		// ... 还会对每个父目录创建子互斥锁,防止父子路径同时运行
68→	}
91→}
```

这种"按资源路径加锁"的设计避免了两个编译器同时写同一个 intermediate 目录造成冲突。

### 4.2 initCompiler 启动流程

```cpp
106→void AssetCompiler::initCompiler()
107→{
108→	WinFileSystem::useFileTypeCache( true );
112→	XMLSection::shouldReadXMLAttributes( true );
113→	XMLSection::shouldWriteXMLAttributes( true );
114→
115→	genericConversionRule_.load( "asset_rules.xml" );
116→	conversionRules_.push_back( &genericConversionRule_ );
117→
118→	if (forceRebuild_)
119→	{
120→		taskProcessor_.forceRebuild( true );
121→	}
122→
124→	taskSemaphore_ = ::CreateSemaphore( NULL, numThreads_, numThreads_, NULL );
130→	BgTaskManager::init();
132→	BgTaskManager::instance().startThreads( ASSET_PIPELINE_CATEGORY, numThreads_ );
134→	DebugFilter::instance().addMessageCallback(this);
135→	DebugFilter::instance().addCriticalCallback(this);
137→
138→	state_ = EXECUTING;
139→}
```

关键步骤:

1. 启用文件类型缓存(加速 `getFileType`)。
2. 加载 `asset_rules.xml`(规则文件,声明哪些扩展名走哪个 converter)。
3. 创建信号量 `taskSemaphore_`,初值与最大值均为线程数,用于暂停/恢复工作线程。
4. 启动 `BgTaskManager` 工作线程(默认 1 个,可通过 `-j` 调整)。
5. 注册 `DebugMessageCallback` 与 `CriticalMessageCallback`,把日志/断言重定向到 asset_pipeline。
6. 状态切换到 `EXECUTING`。

### 4.3 上层工具的调用顺序

batch_compiler 和 jit_compiler 的启动序列一致:

```
options.parseCommandLine(...)
AssetCompiler 子类 obj;
options.apply(obj);          // 把选项应用到编译器
obj.initPlugins();           // 加载 converters/*.dll 插件
obj.initCompiler();          // 见 4.2
obj.build(paths) 或 jitCompiler.scanningThreadMain();
obj.outputReport(...)        // 仅 batch_compiler
obj.finiCompiler();
obj.finiPlugins();
```

---

## 五、核心类与继承关系

### 5.1 Compiler 抽象基类

`Compiler` 是 asset_pipeline 对外暴露的**纯接口**(`compiler.hpp:24`),其构造函数是 `private`,只允许 `AssetCompiler` 通过 `friend` 继承。这一设计的目的是:外部插件(Converter)只能拿到 `Compiler&` 引用,无法独自继承,从而保证回调实现统一由 `AssetCompiler` 提供。

`Compiler` 接口可以分为 5 组,共约 30 个虚函数:

| 分组 | 主要方法 | 用途 |
|---|---|---|
| 注册 | `registerConversionRule`、`registerConverter`、`registerResourceCallbacks` | 注册规则、转换器、资源回调 |
| 路径 | `getResourcePaths`、`resolveRelativePath`、`resolveSourcePath`、`resolveIntermediatePath`、`resolveOutputPath` | 4 类路径互转 |
| 哈希 | `getHash(dep)`、`getFileHash(file, force)`、`checkFileHashUpToDate`、`getDirectoryHash` | 计算依赖/文件/目录哈希 |
| 任务 | `ensureUpToDate`、`getSourceFile`、`hasTasks`、`getNextTask`、`queueTask` | 任务查询与触发 |
| 回调 | `onTaskStarted/Resumed/Suspended/Completed`、`onPreCreateDependencies`、`onPostCreateDependencies`、`onPreConvert`、`onPostConvert`、`onOutputGenerated`、`onCacheRead/ReadMiss/Write/WriteMiss`、`shouldIterateFile/Directory`、`setError/setWarning/...` | 生命周期回调 |

Compiler 接口的关键设计:**所有回调都是同步的**,由 TaskProcessor 在持锁/合适时机调用,Converter 在 `createDependencies`/`convert` 中通过 `Compiler&` 反向触发子任务(见 `ensureUpToDate`)。

### 5.2 AssetCompiler 实现基类

`AssetCompiler`(`asset_compiler.hpp:18`)是 `Compiler` 的默认实现,同时继承 `DebugMessageCallback` 与 `CriticalMessageCallback` 用于接管日志:

```
Compiler (friend AssetCompiler)
   ▲
   │
AssetCompiler ── DebugMessageCallback
              ── CriticalMessageCallback
   ▲
   │
BatchCompiler : AssetCompiler, PluginLoader        // CLI
JITCompiler   : AssetCompiler, AssetServer,
                  ResourceModificationListener,
                  PluginLoader                     // GUI
```

`AssetCompiler` 持有的核心成员(`asset_compiler.hpp:115-164`):

```cpp
115→protected:
116→	void addToolsResourcePaths();
118→	bool resolveCustomPath( const BW::string & basePath, BW::string & path ) const;
120→	BW::vector< HANDLE > compilerMutexes_;        // 单实例锁
122→	enum CompilerState { INVALID, EXECUTING, PAUSED, TERMINATING } state_;
130→	bool            recursive_;
131→	bool            forceRebuild_;
132→	int             numThreads_;
133→	BW::string      intermediatePath_;
134→	BW::string      outputPath_;
136→	BW::vector< BW::string > resourcePaths_;
138→	TaskFinder      taskFinder_;                  // 发现
139→	TaskProcessor   taskProcessor_;               // 转换
141→	GenericConversionRule genericConversionRule_; // asset_rules.xml
142→	ConversionRules conversionRules_;
143→	ConverterMap    converterMap_;
144→	BW::vector< ResourceCallbacks * > resourceCallbacks_;
146→	ConversionTaskQueue taskQueue_;               // 全局任务队列
147→	SimpleMutex         taskQueueMutex_;
149→	HANDLE              taskSemaphore_;            // 暂停/恢复信号量
151→	static THREADLOCAL( bool )                  s_error;
152→	static THREADLOCAL( bool )                  s_warning;
153→	static THREADLOCAL( ConversionTask* )       s_currentTask;
154→	static THREADLOCAL( ConversionTaskQueue* )  s_currentTaskQueue;
155→	static THREADLOCAL( bool )                  s_CreatingDependencies;
156→	static THREADLOCAL( bool )                  s_Converting;
158→	StringHashMap< uint64 >  fileHashes_;        // 文件哈希缓存
159→	mutable ReadWriteLock    fileHashesLock_;    // 读写锁
164→	static const ConversionTask s_invalidTask;
```

注意:**线程局部存储(THREADLOCAL)被大量使用**,因为同一个 AssetCompiler 实例会被多个 BgTaskManager 工作线程并发调用,`s_currentTask`/`s_error` 等必须线程隔离。

`AssetCompiler` 的状态机(`state_`)有 4 个状态:

| 状态 | 含义 |
|---|---|
| `INVALID` | 构造前/析构后 |
| `EXECUTING` | 正在执行,工作线程运行 |
| `PAUSED` | 暂停(信号量被消费) |
| `TERMINATING` | 终止中,工作线程正在收尾 |

### 5.3 Converter 插件接口

`Converter`(`converter.hpp:17`)是 asset_pipeline 的**核心插件接口**,每种资产类型对应一个 Converter 实现(放在 `converters/` 目录):

```cpp
17→class Converter
18→{
22→	Converter( const BW::string& params ) : params_( params ) {};
29→	virtual bool createDependencies( const BW::string& sourcefile,
30→	                                 const Compiler & compiler,
31→	                                 DependencyList & dependencies ) = 0;
37→	virtual bool convert( const BW::string& sourcefile,
38→	                      const Compiler & compiler,
39→	                      BW::vector< BW::string > & intermediateFiles,
40→	                      BW::vector< BW::string > & outputFiles ) = 0;
43→	const BW::string& params_;
44→};
```

每个 Converter 通过 `ConverterInfo`(`converter_info.hpp:10`)注册:

```cpp
10→struct ConverterInfo
11→{
14→	BW::string      name_;             // 显示名
16→	uint64          typeId_;           // 唯一 ID
18→	BW::string      version_;          // 版本号
20→	enum CONVERTER_FLAGS {
22→		THREAD_SAFE         = 1 << 0,  // 是否线程安全
23→		CACHE_DEPENDENCIES  = 1 << 1,  // 依赖列表是否入缓存
24→		CACHE_CONVERSION    = 1 << 2,  // 转换产物是否入缓存
25→		UPGRADE_CONVERSION  = 1 << 3,  // 是否为升级式转换
26→		DEFAULT_FLAGS       = THREAD_SAFE | CACHE_DEPENDENCIES | CACHE_CONVERSION,
27→		EXPERIMENTAL_MASK   = ~(CACHE_CONVERSION | CACHE_DEPENDENCIES)
28→	}                 flags_;
30→	ConverterCreator creator_;         // 工厂函数
31→};
```

`CONVERTER_FLAGS` 是非常关键的设计:

- `THREAD_SAFE`:决定 Converter 在多线程下走共享读锁还是独占写锁(见 6.8)。
- `CACHE_DEPENDENCIES`/`CACHE_CONVERSION`:决定该 Converter 的产物是否进入内容寻址缓存(默认都进)。某些 Converter(如 `space_converter` 涉及大量 chunk)可能关闭缓存以避免缓存膨胀。

### 5.4 ConversionRule 规则接口

`ConversionRule`(`conversion_rule.hpp:12`)负责"文件 → 任务"的映射,有 3 个虚方法:

```cpp
19→	virtual bool createRootTask( const BW::StringRef& sourceFile,
20→	                             ConversionTask& task ) { return false; }
25→	virtual bool createTask( const BW::StringRef& sourceFile,
26→	                         ConversionTask& task ) {
27→		return createRootTask( sourceFile, task );
28→	}
31→	virtual bool getSourceFile( const BW::StringRef& file,
32→	                         BW::string& sourcefile ) const { return false; }
```

- `createRootTask`:从源文件创建"根任务"(由 TaskFinder 主动扫描时调用)。
- `createTask`:从任意文件创建任务(包括非根任务,如中间产物),默认转发到 `createRootTask`。
- `getSourceFile`:**反向查找**——给定输出/中间文件,返回其源文件,用于 `ensureUpToDate`。

asset_pipeline 默认注册的是 `GenericConversionRule`,从 `asset_rules.xml` 加载规则。各 converter 也可以提供自己的 ConversionRule(如 `bsp_conversion_rule`、`texformat_conversion_rule`)。

---

## 六、关键算法与数据结构

### 6.1 ConversionTask 状态机

`ConversionTask`(`conversion_task.hpp:16`)是 asset_pipeline 的核心数据结构,记录单个资产任务的全部上下文:

```cpp
16→struct ConversionTask
17→{
19→	BW::string  source_;              // 源文件绝对路径
21→	uint64      converterId_;         // Converter 类型 ID
22→	BW::string  converterVersion_;    // Converter 版本
25→	BW::string  converterParams_;     // Converter 初始化参数
28→	enum {
29→		/// DO NOT change the order of this enum as it essential to the logic of the asset pipeline
30→		NEW,                    // <task is newly created. has not been queued for processing.
31→		QUEUED,                 // <task has been queued for processing.
32→		PROCESSING,             // <task has been removed from queue and is being processed.
33→		NEEDS_PRIMARY_DEPS,     // <task is being processed and needs its primary dependencies evaluated.
34→		NEEDS_SECONDARY_DEPS,   // <task is being processed and needs its secondary dependencies evaluated.
35→		NEEDS_CONVERSION,       // <task is being processed and needs to be converted.
36→		DONE,                   // <task has been completed.
37→		FAILED                  // <task has encountered an error whilst in a previous state.
38→	}           status_;
43→	typedef BW::vector< std::pair< const ConversionTask*, bool > > SubTaskList;
44→	SubTaskList subTasks_;            // 依赖的子任务列表(critical 标志)
49→	DWORD       threadId_;            // 当前处理线程 ID(用于循环依赖检测)
53→	HANDLE      fileHandle_;          // 源文件句柄(防止转换中外改)
56→	static const uint64 s_unknownId = 0;   // 未知 converter id
57→};
```

**状态机迁移图**:

```
       ┌──────────────────────────────────────────────────────────────┐
       │                                                              │
       ▼                                                              │
   ┌───────┐  queueTask   ┌────────┐  getNextTask  ┌────────────┐     │
   │  NEW  │ ──────────►  │ QUEUED │ ────────────► │ PROCESSING │     │
   └───────┘              └────────┘               └────────────┘     │
                                                          │            │
                                                          │ processNewTask
                                                          ▼            │
                                                ┌─────────────────────┴──┐
                                                │ NEEDS_PRIMARY_DEPS     │
                                                └────────────────────────┘
                                                          │ processPrimaryDependencies
                                                          ▼
                                                ┌────────────────────────┐
                                                │ NEEDS_SECONDARY_DEPS  │
                                                └────────────────────────┘
                                                          │ processSecondaryDependencies
                                                          ▼
                                                ┌────────────────────────┐
                                                │  NEEDS_CONVERSION     │
                                                └────────────────────────┘
                                                          │ processConversion
                                                          ▼
                                                ┌────────────────────────┐
                                                │         DONE          │
                                                └────────────────────────┘

   任何状态遇错 ──► FAILED
```

注释 L29 特别强调 **"DO NOT change the order of this enum as it essential to the logic of the asset pipeline"**,因为 TaskProcessor 多处用 `>= PROCESSING`、`< DONE` 等比较运算,顺序变更会破坏逻辑。

### 6.2 DependencyList 依赖列表

`DependencyList`(`dependency_list.hpp:16`)是每个任务持久化在 `<source>.deps` 文件中的依赖清单:

```cpp
19→	typedef std::pair< Dependency*, uint64 > Input;   // 依赖指针 + 上次哈希
20→	typedef std::pair< BW::string, uint64 > Output;   // 输出文件名 + 哈希
26→	const BW::vector< Input > & primaryInputs() const;
27→	const BW::vector< Input > & secondaryInputs() const;
28→	const BW::vector< Output > & intermediateOutputs() const;
29→	const BW::vector< Output > & outputs() const;
```

依赖被刻意分为 4 类:

| 类别 | 含义 | 检查时机 |
|---|---|---|
| `primaryInputs` | 源文件、Converter 版本、Converter 参数 | 第一阶段;一旦变化即重新生成依赖列表 |
| `secondaryInputs` | 其他源文件、中间文件、输出文件、目录 | 第二阶段;变化则需重新转换 |
| `intermediateOutputs` | 写入 intermediate 目录的产物 | 转换后写入,下次构建检查是否过期 |
| `outputs` | 写入 output 目录的最终产物 | 同上 |

`primaryInputs` 与 `secondaryInputs` 的关键区别:**primary 变化会导致 Converter 重新 `createDependencies`**(因为依赖列表本身可能改变),而 secondary 变化只触发 `convert`。这种分层避免了"重新发现依赖"的高昂代价。

每个 Input 还存了上次的哈希值 `uint64`,下次构建时重新算哈希对比即可判断是否变化。

### 6.3 6 种 Dependency 类型

`dependency.hpp:10-16` 通过 X-Macro 定义了 6 种依赖类型:

```cpp
10→#define DEPENDENCY_TYPES            \
11→	X( SourceFileDependency )        \
12→	X( IntermediateFileDependency )  \
13→	X( OutputFileDependency )        \
14→	X( ConverterDependency )         \
15→	X( ConverterParamsDependency )   \
16→	X( DirectoryDependency )
18→BW_BEGIN_NAMESPACE
20→#define X( type ) type##Type,
21→	enum DependencyType { DEPENDENCY_TYPES InvalidDependencyType };
22→#undef X
```

X-Macro 模式保证了 `DependencyType` 枚举、序列化字符串、`getType()` 实现三者同步,新增类型只需在宏中添加一行。

| 类型 | 文件 | 用途 |
|---|---|---|
| `SourceFileDependency` | `source_file_dependency.hpp` | 依赖某个源文件(最常见) |
| `IntermediateFileDependency` | `intermediate_file_dependency.hpp` | 依赖某个中间产物(如 `.primitives`) |
| `OutputFileDependency` | `output_file_dependency.hpp` | 依赖某个最终输出(会触发对应任务) |
| `ConverterDependency` | `converter_dependency.hpp` | 依赖 Converter 的 ID + 版本(Converter 升级时全部重建) |
| `ConverterParamsDependency` | `converter_params_dependency.hpp` | 依赖 Converter 的初始化参数 |
| `DirectoryDependency` | `directory_dependency.hpp` | 依赖整个目录(支持 pattern/regex/recursive) |

`DirectoryDependency` 是最强力的依赖类型,支持正则匹配与递归,通过 `getDirectoryHash` 计算目录哈希(见 `asset_compiler.cpp:474-521`)。

### 6.4 TaskProcessor 三阶段处理

`TaskProcessor`(`task_processor.hpp:19`)是状态机的实际驱动者,其 `processTask` 方法(`task_processor.cpp:219-282`)是 asset_pipeline 最核心的代码:

```cpp
219→void TaskProcessor::processTask( ConversionTask & conversionTask )
220→{
221→	if (conversionTask.fileHandle_ == INVALID_HANDLE_VALUE)
222→	{
223→		ERROR_MSG( "FAILED: Could not acquire source handle.\n" );
224→		conversionTask.status_ = ConversionTask::FAILED;
225→		return;
226→	}
229→	MF_ASSERT( conversionTask.status_ >= ConversionTask::PROCESSING )
230→	MF_ASSERT( conversionTask.status_ < ConversionTask::DONE )
231→	if (conversionTask.status_ >= ConversionTask::DONE)
232→	{
233→		return;
234→	}
237→	TaskContext taskContext( *this, conversionTask );
239→	if (conversionTask.status_ == ConversionTask::PROCESSING)
240→	{
241→		if (!processNewTask( taskContext ))
242→		{
243→			MF_ASSERT( conversionTask.status_ == ConversionTask::FAILED );
244→			return;
245→		}
246→		MF_ASSERT( conversionTask.status_ == ConversionTask::NEEDS_PRIMARY_DEPS );
247→	}
249→	DependencyContext dependencyContext( *this, conversionTask );
250→	ConversionContext conversionContext( *this, conversionTask );
252→	if (conversionTask.status_ == ConversionTask::NEEDS_PRIMARY_DEPS)
253→	{
254→		if (!processPrimaryDependencies( taskContext, dependencyContext, conversionContext ))
255→		{
256→			MF_ASSERT( conversionTask.status_ == ConversionTask::FAILED );
257→			return;
258→		}
259→		MF_ASSERT( conversionTask.status_ == ConversionTask::NEEDS_SECONDARY_DEPS );
260→	}
262→	if (conversionTask.status_ == ConversionTask::NEEDS_SECONDARY_DEPS)
263→	{
264→		if (!processSecondaryDependencies( taskContext, dependencyContext, conversionContext ))
265→		{
266→			MF_ASSERT( conversionTask.status_ == ConversionTask::NEEDS_CONVERSION ||
267→					   conversionTask.status_ == ConversionTask::FAILED );
268→			return;
269→		}
270→		MF_ASSERT( conversionTask.status_ == ConversionTask::NEEDS_CONVERSION );
271→	}
273→	if (conversionTask.status_ == ConversionTask::NEEDS_CONVERSION)
274→	{
275→		if (!processConversion( taskContext, dependencyContext, conversionContext ))
276→		{
277→			MF_ASSERT( conversionTask.status_ == ConversionTask::FAILED );
278→			return;
279→		}
280→		MF_ASSERT( conversionTask.status_ == ConversionTask::DONE );
281→	}
282→}
```

注意 L239/L252/L262/L273 的设计:**每个阶段都先检查 `status_` 是否处于对应状态**,这意味着任务被 suspend 后再次 resume 时,可以从中间状态继续,而不必从头开始。这是 asset_pipeline 支持嵌套依赖(suspend 当前任务去构建子任务)的关键。

#### 6.4.1 processPrimaryDependencies

`processPrimaryDependencies`(`task_processor.cpp:307-399`)负责检查 primary 依赖:

```cpp
307→bool TaskProcessor::processPrimaryDependencies( ... )
308→{
314→	bool needsDeps = forceRebuild_;
316→	if (!needsDeps)
320→		needsDeps = !checkPrimaryDependenciesUpToDate( taskContext, dependencyContext );
324→	if (needsDeps)
325→	{
328→		dependencyContext.depList_.initialise( taskContext.relativeSource_, ... );
335→		needsDeps = !retrievePrimaryDependencyListFromCache( ... );  // 尝试从缓存取
339→	if (needsDeps)
340→	{
347→		MF_VERIFY( conversionContext.initConverter() );
350→		compiler_.onPreCreateDependencies( taskContext.conversionTask_ );
355→		try {
357→			INFO_MSG( "Creating dependencies...\n" );
358→			ConverterGuard converterGuard( conversionContext.converterInfo_ );
359→			res = conversionContext.converter_->createDependencies(
360→			        taskContext.conversionTask_.source_, compiler_, dependencyContext.depList_ );
361→		}
362→		catch (...) { res = false; }
365→		compiler_.onPostCreateDependencies( taskContext.conversionTask_ );
376→		if (!compiler_.hasWarning() && dependencyContext.depListRoot_ != NULL)
377→		{
378→			dependencyContext.depList_.serialiseOut( dependencyContext.depListRoot_ );
379→			dependencyContext.depListResource_.save();
382→			if ((conversionContext.converterInfo_.flags_ & ConverterInfo::CACHE_DEPENDENCIES) != 0)
384→				ContentAddressableCache::writeToCache( ... );
387→		}
388→	}
397→	taskContext.conversionTask_.status_ = ConversionTask::NEEDS_SECONDARY_DEPS;
398→	return true;
399→}
```

注意几个要点:

1. `forceRebuild_` 直接短路所有检查。
2. `checkPrimaryDependenciesUpToDate` 重新计算每个 primary 依赖的哈希,与 `.deps` 中存的对比。
3. 缓存查找 `retrievePrimaryDependencyListFromCache` 通过 `ContentAddressableCache::readFromCache` 按 input hash 取依赖列表;若缓存命中且校验通过,可跳过 `createDependencies`。
4. `ConverterGuard` 包裹 `createDependencies` 调用,提供读写锁保护(见 6.8)。
5. `try/catch(...)` 兜底——Converter 内部任何 assert/异常都会被捕获并标记任务失败,不会让进程崩溃。
6. 写入 `.deps` 文件并按 `CACHE_DEPENDENCIES` 标志决定是否同步写入内容寻址缓存。

#### 6.4.2 processSecondaryDependencies

`processSecondaryDependencies`(`task_processor.cpp:401-475`)遍历每个 secondary 依赖,通过 `compiler_.ensureUpToDate` 触发子任务:

```cpp
401→bool TaskProcessor::processSecondaryDependencies( ... )
404→{
409→	bool blocked = false;
410→	bool subTaskError = false;
412→	BW::vector< DependencyList::Input > & secondaryDeps = dependencyContext.depList_.secondaryInputs_;
414→	for ( it = secondaryDeps.begin(); it != secondaryDeps.end(); ++it )
415→	{
416→		const ConversionTask * secondaryTask = NULL;
417→		bool upToDate = compiler_.ensureUpToDate( *it->first, secondaryTask );  // 递归!
419→		bool failed = !upToDate;
420→		if (secondaryTask != NULL)
421→		{
422→			if (secondaryTask->status_ == ConversionTask::FAILED ||
423→				secondaryTask->threadId_ == GetCurrentThreadId())
424→			{
425→				upToDate = true;   // 失败或同线程已被阻塞,不再阻塞
429→			}
434→			failed = false;  // 仍在处理中,不算失败
438→			taskContext.conversionTask_.subTasks_.push_back(
439→			    std::make_pair( secondaryTask, it->first->isCritical() ) );
440→		}
441→		if (failed && it->first->isCritical())
444→		{
448→			subTaskError = true;
456→		}
460→		blocked |= !upToDate;
461→	}
463→	if (subTaskError) { ... return false; }
473→	taskContext.conversionTask_.status_ = ConversionTask::NEEDS_CONVERSION;
474→	return !blocked;     // blocked 时返回 false,任务被 suspend 重新入队
475→}
```

`ensureUpToDate` 会调用 `ensureCompiled`(`asset_compiler.cpp:523-689`),后者在 `recursive_` 模式下**递归 suspend 当前任务、构建子任务、resume 当前任务**;在非递归模式下,把子任务推入 `s_currentTaskQueue` 并让当前任务回到队列。这是 asset_pipeline 处理依赖图的精髓(见 6.7)。

#### 6.4.3 processConversion

`processConversion`(`task_processor.cpp:477+`)实际调用 `Converter::convert`:

```cpp
489→	bool needsConversion = forceRebuild_;
496→	needsConversion = !hasOutputs( dependencyContext );     // 没有输出 → 需要转换
501→	// ... 检查每个输出文件是否过期
524→	if (needsConversion)
525→	{
527→		MF_VERIFY( conversionContext.initConverter() );
529→		// 尝试从内容寻址缓存读取输出
530→		if ((conversionContext.converterInfo_.flags_ & ConverterInfo::CACHE_CONVERSION) != 0)
531→			// 从 cache 拷贝输出到 intermediate/output
540→		if (needsConversion)
541→		{
547→			compiler_.onPreConvert( taskContext.conversionTask_ );
553→			ConverterGuard converterGuard( conversionContext.converterInfo_ );
554→			res = conversionContext.converter_->convert(
555→			        source_, compiler_, intermediateFiles, outputFiles );
558→			compiler_.onPostConvert( taskContext.conversionTask_ );
560→			if (!res || compiler_.hasError()) { ... FAILED; }
575→			// 写入缓存
581→			ContentAddressableCache::writeToCache( ... );
583→		}
584→	}
```

转换阶段也走"先尝试缓存、再实际转换"的两步流程,最大化复用历史产物。

### 6.5 TaskFinder 任务发现

`TaskFinder`(`task_finder.hpp:13`、`task_finder.cpp`)负责扫描目录、创建任务:

```cpp
42→void TaskFinder::findTasks( const BW::StringRef& directory )
44→{
45→	MultiFileSystem* fs = BWResource::instance().fileSystem();
46→	IFileSystem::FileType ft = fs->getFileType( directory );
50→	if (ft == IFileSystem::FT_FILE)
52→		iterateFile( directory );
54→	else if (ft == IFileSystem::FT_DIRECTORY)
56→		iterateDirectory( directory );
57→}
60→void TaskFinder::iterateFile( const BW::StringRef& file )
62→{
64→	if (!compiler_.shouldIterateFile( file )) return;
67→	ConversionTask * task = getTask( file, true );
68→	if (task != NULL)
70→		compiler_.queueTask( *task );
72→}
74→void TaskFinder::iterateDirectory( const BW::StringRef& directory )
76→{
78→	if (!compiler_.shouldIterateDirectory( path )) return;
83→	BW::string relativeDirectory = BWResource::dissolveFilename( path );
84→	bool isBWPath = relativeDirectory.length() < path.length();
92→	MultiFileSystem* fs = BWResource::instance().fileSystem();
94→	fs->readDirectory( dir, path );
95→	for (...) {
103→		if (ft == IFileSystem::FT_FILE && isBWPath)
104→			iterateFile( subPath );             // 递归文件
109→		else if (ft == IFileSystem::FT_DIRECTORY)
110→			iterateDirectory( subPath );         // 递归子目录
111→	}
112→}
```

注意 L83-86:**只有 BigWorld 资源路径下的文件才会被迭代**,防止误编译第三方依赖。

`getTask(filename, bRoot)`(`task_finder.cpp:153-257`)是关键的去重入口,通过 `StringHashMap<ConversionTask*> tasks_` 保证每个源文件只创建一次任务:

```cpp
165→	tasksLock_.beginRead();
166→	if (!this->tasks_.empty())
168→		StringHashMap<ConversionTask* >::iterator taskIter = this->tasks_.find( source );
171→		if (taskIter != this->tasks_.end())
172→			pTask = taskIter->second;       // 已存在,直接返回
175→	tasksLock_.endRead();
177→	if (pTask != NULL) return pTask;
184→	ConversionTask *pNewTask = new ConversionTask;
190→	ConversionRules::const_reverse_iterator ruleIter = rules_.crbegin();
192→	for ( ; ruleIter != ruleEnd; ++ruleIter )          // 逆序遍历规则(后注册优先)
194→	{
195→		if (bRoot)
197→			if ((*ruleIter)->createRootTask( filename, *pNewTask )) break;
201→		else
203→			if ((*ruleIter)->createTask( filename, *pNewTask )) break;
207→	}
212→	if ( ruleIter == ruleEnd )                          // 没规则匹配
214→	{
216→		bw_safe_delete( pNewTask ); return NULL;        // 根任务:返回 NULL
222→		pNewTask->converterId_ = ConversionTask::s_unknownId;
226→		pNewTask->status_ = ConversionTask::FAILED;     // 非根任务:FAILED
228→	}
246→	tasksLock_.beginWrite();
248→	std::pair< ... > insertIt = tasks_.insert( std::make_pair( source, pNewTask ) );
249→	if (!insertIt.second)                               // 双重检查
251→		delete pNewTask; pNewTask = insertIt.first->second;
254→	tasksLock_.endWrite();
256→	return pNewTask;
257→}
```

关键点:
- 规则按**逆序**遍历,后注册的规则优先(允许覆盖)。
- `tasks_` 用 `ReadWriteLock` 保护,支持多线程并发查表(扫描线程与其他触发任务创建的线程并存)。
- 双重检查锁定模式,避免重复创建。

### 6.6 内容寻址缓存

`ContentAddressableCache`(`content_addressable_cache.hpp:15`)是一个简单的静态类,按文件内容的 64 位哈希存储:

```cpp
17→public:
18→	static const BW::string & getCachePath();
19→	static bool getReadFromCache();
20→	static bool getWriteToCache();
24→	static bool readFromCache( const BW::string & filename, uint64 hash, Compiler & compiler );
25→	static bool writeToCache( const BW::string & filename, uint64 hash, Compiler & compiler );
```

`readFromCache` 用 `(filename, hash)` 在缓存目录中查找匹配文件,命中则拷贝到目标路径,并回调 `Compiler::onCacheRead`;未命中回调 `onCacheReadMiss`。`writeToCache` 反之。

缓存命中是 asset_pipeline 跨构建加速的核心机制——只要输入哈希相同,即可跳过昂贵的 `createDependencies` 与 `convert`,直接拷贝上次的产物。

### 6.7 循环依赖检测

asset_pipeline 通过 `ConversionTask::threadId_` 检测循环依赖。`ensureCompiled`(`asset_compiler.cpp:593-622`)在等待子任务时记录"我在等哪个线程":

```cpp
593→		while (task.status_ != ConversionTask::DONE &&
594→				task.status_ != ConversionTask::FAILED)
595→		{
596→			if (numThreads_ == 1)
597→			{
598→				// 单线程不可能等别的线程,必定是循环
600→				ERROR_MSG( "Cyclic dependency found %s\n", task.source_.c_str() );
601→				break;
602→			}
603→			else if (task.threadId_ != 0)
604→			{
606→				s_currentTask->threadId_ = task.threadId_;   // 沿依赖链向上传
607→				if (s_currentTask->threadId_ == GetCurrentThreadId())
608→				{
609→					ERROR_MSG( "Cyclic dependency found %s\n", task.source_.c_str() );
610→					break;                                    // 回到自己 = 环
611→				}
612→			}
613→			else
614→			{
615→				s_currentTask->threadId_ = GetCurrentThreadId();
616→			}
621→			Sleep(0);   // 让出 CPU
622→		}
626→		s_currentTask->threadId_ = GetCurrentThreadId();  // 恢复
```

算法本质:**每个任务在等待时把自己 threadId 改为它等待的任务的 threadId**,如果环闭合,最终会回到 `GetCurrentThreadId()`,从而检测出循环。这是个非常巧妙的"并查集式"传递算法。

### 6.8 多线程调度与 ConverterGuard

#### 6.8.1 多线程主循环

`TaskProcessor::processTasksOnMultipleThreads`(`task_processor.cpp:990-1026`)是 asset_pipeline 多线程的核心调度循环:

```cpp
990→void TaskProcessor::processTasksOnMultipleThreads()
991→{
992→	while (true)
993→	{
994→		const int numThreads = BgTaskManager::instance().numUnstoppedThreads();
997→		const int numTasks = BgTaskManager::instance().numBgTasksLeft();
1000→		if (compiler_.hasTasks())
1001→		{
1002→			if ( numThreads > numTasks )
1003→			{
1004→				for ( int i = 0; i < numThreads - numTasks; ++i )
1005→				{
1006→					BgTaskManager::instance().addBackgroundTask( new TaskProcessorTask( *this ) );
1008→				}
1009→			}
1010→			else if ( numThreads < numTasks )
1011→			{
1012→				InterlockedExchange(&threadKillCount_, numTasks - numThreads);
1013→			}
1014→		}
1015→		else if (numTasks == 0)
1016→			break;     // 没任务且没在跑的工作线程 → 退出
1024→		Sleep(100);
1025→	}
1026→}
```

策略:**动态伸缩工作线程数**。如果还有任务但工作线程不够,就 `addBackgroundTask` 增加;如果工作线程过多,通过 `threadKillCount_` 原子计数让多余线程自杀。

#### 6.8.2 ConverterGuard 读写锁

`ConverterGuard`(`task_processor.cpp:45-89`)根据 ConverterInfo 的 `THREAD_SAFE` 标志选择共享读锁或独占写锁:

```cpp
45→class ConverterGuard
47→{
48→public:
49→	ConverterGuard( ConverterInfo & converterInfo )
50→	{
51→		threadSafe_ = ( (converterInfo.flags_ & ConverterInfo::THREAD_SAFE) != 0 );
53→		if (threadSafe_)
54→		{
55→			while (s_pendingWrites > 0)
56→				Sleep( 0 );          // 有写者在等,先让出
60→			s_lock_.beginRead();     // 共享读
61→			return;
62→		}
64→		InterlockedIncrement( &s_pendingWrites );
66→		s_lock_.beginWrite();       // 独占写
67→		InterlockedDecrement( &s_pendingWrites );
68→	}
70→	~ConverterGuard()
72→	{
74→		if (threadSafe_) s_lock_.endRead();
78→		else s_lock_.endWrite();
79→	}
84→	static ReadWriteLock s_lock_;
85→	static volatile long s_pendingWrites;
86→};
```

注意 L53-62 的细节:**线程安全的 Converter 也需要等待 pending writer 完成**,这是为了避免 writer starvation,即非线程安全的 Converter 调用时不会有线程安全 Converter 同时跑。

所有 Converter 共享同一个 `s_lock_`(进程内全局),这意味着**同一时刻只有一个非线程安全 Converter 在跑,但多个线程安全 Converter 可以并发**。

#### 6.8.3 onTaskSuspended 的重排逻辑

`AssetCompiler::onTaskSuspended`(`asset_compiler.cpp:919-1016`)是非递归模式下重新排序任务队列的关键。当任务 A 被发现依赖任务 B 时,A 被 suspend,其依赖图被"重排":

```cpp
941→	else  // 非 recursive 模式
944→		taskQueueMutex_.grab();
949→		// 找出当前任务依赖的、已经在队列里的任务,移除它们
951→		for ( it = s_currentTaskQueue->begin(); ...; ++it )
953→			if ((*it)->status_ != ConversionTask::QUEUED) continue;
958→			for ( itQueued = taskQueue_.begin(); ...; ++itQueued )
960→				if ( *it == *itQueued ) { taskQueue_.erase( itQueued ); ...; break; }
967→		}
970→		// 找出已经开始处理的依赖任务,记录插入位置(插在它们后面)
974→		ConversionTaskQueue::iterator itInsert = taskQueue_.begin();
975→		for ( it = s_currentTaskQueue->begin(); ...; ++it )
983→			for ( itQueued = itInsert; ...; ++itQueued )
985→				if ( *it == *itQueued ) { itInsert = itQueued + 1; break; }
991→		}
994→		taskQueue_.insert( itInsert, s_currentTask );   // 当前任务插在依赖之后
1004→		for ( it = s_currentTaskQueue->begin(); ...; ++it )
1005→			taskQueue_.push_front( *it );               // 依赖推到队首,优先处理
1007→			(*it)->status_ = ConversionTask::QUEUED;
1008→		}
1015→	MF_VERIFY( ReleaseSemaphore( taskSemaphore_, 1, NULL ) );
```

这种重排保证了:**依赖任务优先于依赖者运行,且依赖者紧随其后**,最大化吞吐。

---

## 七、配置项与命令行参数

`AssetCompilerOptions`(`asset_compiler_options.hpp:14`、`asset_compiler_options.cpp:60-88`)定义了通用命令行参数:

| 参数 | 类型 | 默认值 | 作用 |
|---|---|---|---|
| `-intermediatePath <path>` | string | "" | 中间产物目录(存放 `.deps`、缓存中间文件) |
| `-outputPath <path>` | string | "" | 最终产物目录;为空表示源目录即输出目录 |
| `-cachePath <path>` | string | 默认缓存目录 | 内容寻址缓存目录 |
| `-j <N>` | int | 1 | 工作线程数 |
| `-recursive` | flag | false | 启用递归模式(子任务在同线程内嵌套处理,而非重排队列) |
| `-forceRebuild` | flag | false | 强制重建所有任务,忽略哈希检查 |
| `-enableCacheRead` | bool | true | 是否从缓存读取 |
| `-enableCacheWrite` | bool | true | 是否写入缓存 |

batch_compiler 扩展了 `-report <path>` 参数,用于生成 HTML 报告。

asset_pipeline 还通过 `asset_rules.xml` 配置文件声明文件扩展名到 Converter 的映射,典型规则如下(示意):

```xml
<rule>
    <sourcePattern>*.visual</sourcePattern>
    <converterId>...</converterId>
    <converterParams>...</converterParams>
</rule>
```

`GenericConversionRule::load("asset_rules.xml")` 在 `initCompiler` 时被调用。

---

## 八、与其他模块的依赖关系

asset_pipeline 对内对外依赖如下:

```
┌─────────────────────────────────────────────────────────────────┐
│ asset_pipeline                                                  │
└──┬──────────────────────────────────────────────────────────────┘
   │ 依赖(BigWorld 标准库)
   ├─ cstdmf/        : bw_hash64, concurrency(ReadWriteLock/SimpleMutex
   │                   /SimpleEvent/SimpleThread), debug_filter,
   │                   guard, string_builder, command_line, timestamp
   ├─ resmgr/        : BWResource, MultiFileSystem, WinFileSystem,
   │                   DataSection, DataResource, XMLSection,
   │                   AutoConfig, HierarchicalConfig
   ├─ re2/           : Google RE2 正则引擎(DirectoryDependency 用)
   └─ plugin_system/ : PluginLoader(被上层工具继承)

   │ 被依赖
   ├─→ batch_compiler  : AssetCompiler + PluginLoader 派生
   ├─→ jit_compiler    : AssetCompiler + AssetServer + ResourceModificationListener
   │                    + PluginLoader 派生
   └─→ converters/*    : 各 Converter 插件通过 Converter 接口反向使用 Compiler

   │ 对外接口
   └─→ Compiler& 传递给所有 Converter::createDependencies / convert
```

asset_pipeline 不依赖 moo、physics2 等运行时模块(那是 assetprocessor 的事),保持纯工具属性。

asset_pipeline 中的 `asset_pipe.hpp/cpp`(在 `lib/asset_pipeline/`)定义了 `AssetPipe` 命名管道协议常量与读写函数,被 `AssetServer` 使用——这其实是 `jit_compiler` 与游戏客户端 IPC 的底层。

---

## 九、关键代码片段

### 9.1 文件哈希缓存(getFileHash)

`asset_compiler.cpp:419-452`,展示 asset_pipeline 如何用读写锁缓存文件哈希:

```cpp
419→uint64 AssetCompiler::getFileHash( const BW::string & fileName, bool forceUpdate )
420→{
422→	if (!forceUpdate)
423→	{
427→		ReadWriteLock::ReadGuard lockGuard( fileHashesLock_ );   // 读锁
428→		StringHashMap< uint64 >::const_iterator hashIt = fileHashes_.find( fileName );
429→		if (hashIt != fileHashes_.cend())
430→			return hashIt->second;
434→	}
439→	uint64 hash = 0;
440→	BinaryPtr sourceFilePtr = BWResource::instance().fileSystem()->readFile( fileName );
441→	if (sourceFilePtr.hasObject())
442→		hash = Hash64::compute( sourceFilePtr->data(), sourceFilePtr->len() );
447→	ReadWriteLock::WriteGuard lockGuard( fileHashesLock_ );      // 写锁
449→	fileHashes_[fileName] = hash;
451→	return hash;
452→}
```

### 9.2 目录哈希(getDirectoryHash)

`asset_compiler.cpp:474-521`,递归计算目录哈希,支持正则/通配符:

```cpp
474→uint64 AssetCompiler::getDirectoryHash( const BW::string & directory,
475→        const BW::string & pattern, bool regex, bool recursive )
476→{
477→	uint64 hash = 0;
478→	BW::string path = BWUtil::formatPath( directory );
480→	MultiFileSystem* fs = BWResource::instance().fileSystem();
481→	IFileSystem::Directory dir;
482→	fs->readDirectory( dir, directory );
483→	std::sort( dir.begin(), dir.end() );              // 排序保证哈希稳定
485→	for( IFileSystem::Directory::iterator it = dir.begin(); ...; ++it )
488→	{
489→		BW::string subPath = path + (*it);
490→		IFileSystem::FileType ft = fs->getFileType( subPath );
491→		if (ft == IFileSystem::FT_FILE)
492→		{
493→			if (regex)
494→				if (RE2::FullMatch( ..., pattern )) ...
497→				Hash64::combine( hash, *it );
498→				Hash64::combine( hash, getFileHash( subPath, false ));
503→			else if (*it == pattern) ...
510→		else if (ft == IFileSystem::FT_DIRECTORY && recursive)
511→			Hash64::combine( hash, getDirectoryHash( subPath, pattern, regex, recursive ) );
518→	}
521→	return hash;
522→}
```

注意 L483 的 `std::sort`——文件系统返回的目录列表顺序不保证稳定,排序后才能保证相同内容得到相同哈希。

### 9.3 目录遍历过滤(shouldIterateDirectory)

`asset_compiler.cpp:723-755`,asset_pipeline 默认会跳过中间目录、SVN 目录、单元测试目录:

```cpp
723→bool AssetCompiler::shouldIterateDirectory( const BW::StringRef & directory )
724→{
725→	if (terminating()) return false;
731→	if (intermediatePath_.length() &&
732→		directory.substr( 0, intermediatePath_.length() ) == intermediatePath_)
734→		return false;                              // 跳过 intermediate
737→	if (outputPath_.length() && ...)
740→		return false;                              // 跳过 output
743→	StringRef svn = "/.svn";
744→	if (directory.find( svn ) != StringRef::npos)
745→		return false;                              // 跳过 .svn
749→	StringRef testfiles = "/tools/asset_pipeline/testfiles";
750→	if (directory.find( testfiles ) != StringRef::npos)
752→		return false;                              // 跳过测试文件
754→	return true;
755→}
```

### 9.4 ConversionContext 的 Converter 创建

`task_processor.cpp:194-217`,展示 Converter 的延迟创建与销毁:

```cpp
194→TaskProcessor::ConversionContext::ConversionContext( TaskProcessor & taskProcessor,
195→	                                                 ConversionTask & conversionTask )
196→	: converterInfo_( *taskProcessor.converterMap_[conversionTask.converterId_] )
197→	, converterParams_( conversionTask.converterParams_ )
198→	, converter_( NULL )
201→{ }
203→bool TaskProcessor::ConversionContext::initConverter()
205→{
207→	if (converter_ == NULL)
208→		converter_ = converterInfo_.creator_( converterParams_ );   // 工厂调用
211→	return converter_ != NULL;
212→}
214→TaskProcessor::ConversionContext::~ConversionContext()
216→{
217→	delete converter_;        // 每个任务独立 Converter 实例,销毁时释放
218→}
```

注意:**每个任务创建独立的 Converter 实例**,而非共享。这是因为 Converter 持有的 `params_` 因任务而异,且非线程安全 Converter 不能并发。

### 9.5 DependencyList 序列化

`dependency_list.hpp:79-102`,`.deps` 文件通过 DataSection 序列化:

```cpp
79→	bool serialiseIn( DataSectionPtr pSection );
84→	bool serialiseOut( DataSectionPtr pSection ) const;
86→	// 私有 helper:
90→	bool serialiseIn( DataSectionPtr pSection, BW::vector< Input > & dependencies );
94→	bool serialiseOut( DataSectionPtr pSection, const BW::vector< Input > & dependencies ) const;
98→	bool serialiseIn( DataSectionPtr pSection, BW::vector< Output > & outputs );
102→	bool serialiseOut( DataSectionPtr pSection, const BW::vector< Output > & outputs ) const;
```

`.deps` 文件实际是 XML 格式,典型结构(示意):

```xml
<root>
  <primaryInputs>
    <SourceFileDependency critical="1">
      <fileName>...</fileName>
      <hash>...</hash>
    </SourceFileDependency>
    <ConverterDependency>...</ConverterDependency>
  </primaryInputs>
  <secondaryInputs>...</secondaryInputs>
  <intermediateOutputs>...</intermediateOutputs>
  <outputs>...</outputs>
</root>
```

---

## 十、设计亮点与注意事项

### 10.1 设计亮点

1. **状态机驱动的可恢复处理**:ConversionTask 的 7 状态机让任务在任意阶段被 suspend 后都能从断点续做,极大地方便了嵌套依赖处理与 GUI 暂停。
2. **primary/secondary 依赖分层**:把"决定依赖列表的依赖"与"决定是否转换的依赖"分开,避免了 secondary 变化时昂贵的依赖重新发现。
3. **X-Macro 依赖类型**:6 种 Dependency 类型用 X-Macro 集中声明,枚举、序列化、工厂代码三同步,扩展零遗漏。
4. **内容寻址缓存**:以输入哈希为 key 的全局缓存让跨构建、跨项目的产物复用成为可能,显著降低增量构建时间。
5. **ConverterGuard 读写锁**:简洁地解决了"线程安全 Converter 并发 + 非线程安全 Converter 串行"的混合需求,pending writer 优先避免 starvation。
6. **threadId 传递式循环检测**:用最简单的字段完成了多线程下的循环依赖检测,无需维护全局依赖图。
7. **规则逆序匹配**:`TaskFinder::getTask` 逆序遍历 ConversionRules,允许后注册的规则覆盖前者,与 Python 类方法解析顺序一致,符合直觉。
8. **单实例互斥锁按资源路径**:避免同一资源路径被两个编译器同时操作,同时不阻塞不同路径的并发编译。
9. **THREADLOCAL 状态**:`s_currentTask`/`s_error`/`s_CreatingDependencies` 等用线程局部存储,无需加锁,工作线程隔离干净。
10. **try/catch 兜底 Converter 调用**:Converter 内部的 assert 不会让进程崩溃,而是被捕获为单个任务失败,符合"批量编译要尽可能多完成"的工程需求。

### 10.2 注意事项与潜在坑

1. **状态机枚举顺序不可变**:`ConversionTask::status_` 的注释明确警告 `DO NOT change the order`,代码各处用 `>=`、`<` 比较,重排会引发难调的 bug。
2. **单实例限制**:同一资源路径下,asset_pipeline 不允许同时运行两个实例(batch_compiler + jit_compiler 不能共用同一资源路径),会直接 `exit(-1)` 弹窗。
3. **Windows-only**:大量使用 `HANDLE`、`CreateMutexW`、`CreateSemaphore`、`InterlockedIncrement` 等 Win32 API,asset_pipeline 是纯 Windows 实现。
4. **recursive vs 非递归模式差异大**:
   - `recursive_=true`:子任务在当前线程内嵌套处理,适合任务量小、依赖浅的场景。
   - `recursive_=false`(默认):子任务回到全局队列,通过 `onTaskSuspended` 重排,适合大规模批量编译。
   两者在 `ensureCompiled` 与 `onTaskSuspended` 中的行为截然不同,选择错误会导致死锁或低效。
5. **fileHashes_ 缓存无失效**:`StringHashMap<uint64> fileHashes_` 一旦写入即长期保留,文件被外部修改时需要 `forceUpdate=true` 才能重算(jit_compiler 在 `onResourceModified` 中会通过 `checkFileHashUpToDate` 主动失效)。
6. **DirectoryDependency 哈希昂贵**:`getDirectoryHash` 会读取目录下所有匹配文件并计算哈希,大目录(如 `particles/`)会拖慢构建,应谨慎使用 `recursive=true`。
7. **转换中文件锁**:`ConversionTask::fileHandle_` 在任务开始时打开源文件句柄,防止转换中外改;若源文件被外部进程长期占用,会触发 `TASK_START_TIMEOUT`(5 秒)与 `TASK_TRY_MAX_TIMES`(5 次)重试。
8. **缓存命中校验**:`ContentAddressableCache::readFromCache` 命中后还会校验 primary 依赖哈希,防止缓存损坏导致错误结果(见 `task_processor.cpp:134-192` 的 `loadFromCache`)。
9. **`.deps` 文件并发写**:多个任务可能同时写各自的 `.deps`,但因为是不同文件,无需互斥;但 `DataResource::save` 内部对同一文件的多次写需要上层保证( asset_pipeline 通过"每个任务独立 `depListResource_`"来保证)。
10. **Converter 实例不共享**:每个任务 `new` 一个 Converter 实例并 `delete`,对创建昂贵的 Converter(如 `EffectCompiler`)是性能损耗,需通过 `ConverterInfo::THREAD_SAFE` + 缓存标志缓解。

### 10.3 与 batch_compiler / jit_compiler 的协作要点

| 关注点 | batch_compiler | jit_compiler |
|---|---|---|
| 模式 | 一次性批量,默认非递归 | 常驻增量,递归 + 反向依赖图 |
| 重写关键回调 | `onTaskStarted/Completed`、`handleMessage`、`outputReport` | `onTaskCompleted`(建立反向依赖)、`onResourceModified`(文件变更触发重建)、`onAssetRequested`(IPC 请求触发) |
| 扩展状态 | `TaskRecord` 记录每个任务耗时、日志、错误 | `TaskStore` + `TaskInfo` 用于 UI 展示 |
| 终止处理 | `ConsoleHandler` Ctrl-C 优雅终止 | `stop()` 设置 `terminating_` 并唤醒事件 |
| 多线程 | `processTasksOnMultipleThreads` | `managingThreadMain` 调 `processTasks` |

---

## 附录:核心文件清单

| 文件 | 行数 | 职责 |
|---|---|---|
| `compiler/compiler.hpp` | 170 | Compiler 抽象基类 |
| `compiler/asset_compiler.hpp` | 168 | AssetCompiler 声明 |
| `compiler/asset_compiler.cpp` | 1270 | AssetCompiler 实现(状态机/哈希/调度) |
| `compiler/asset_compiler_options.cpp` | 253 | 命令行解析 |
| `compiler/generic_conversion_rule.hpp/cpp` | - | asset_rules.xml 加载 |
| `conversion/conversion_task.hpp` | 60 | ConversionTask 状态机 |
| `conversion/task_processor.hpp` | 142 | TaskProcessor 声明 |
| `conversion/task_processor.cpp` | 1027 | TaskProcessor 实现(三阶段) |
| `conversion/content_addressable_cache.hpp` | 34 | 内容寻址缓存接口 |
| `conversion/converter.hpp` | 47 | Converter 插件接口 |
| `conversion/converter_info.hpp` | 41 | ConverterInfo 元信息 |
| `dependency/dependency.hpp` | 67 | Dependency 基类 + X-Macro |
| `dependency/dependency_list.hpp` | 115 | DependencyList 容器 |
| `discovery/task_finder.hpp` | 44 | TaskFinder 声明 |
| `discovery/task_finder.cpp` | 258 | TaskFinder 实现(递归遍历) |
| `discovery/conversion_rule.hpp` | 39 | ConversionRule 抽象 |

---

> **文档版本**:BigWorld Engine 14.4.1
> **分析对象**:`programming/bigworld/tools/asset_pipeline/`
> **行号引用**:本文中所有 `文件:行号` 均基于 14.4.1 源码原始行号。
