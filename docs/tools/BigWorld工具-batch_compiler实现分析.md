# BigWorld 工具 batch_compiler 实现分析

> 本文档详细分析 BigWorld Engine 14.4.1 中 batch_compiler 工具的架构与实现。batch_compiler 是 asset_pipeline 的 CLI 批量编译前端,继承自 AssetCompiler,负责一次性扫描资源目录、构建所有过期资产、生成 HTML 报告,并支持 Ctrl-C 优雅终止。它是一个 Windows 控制台程序,代码量约 1100 行。

---

## 目录

- [一、概述与定位](#一概述与定位)
- [二、整体架构](#二整体架构)
- [三、目录结构](#三目录结构)
- [四、入口点与启动流程](#四入口点与启动流程)
  - [4.1 main / bw_main](#41-main--bw_main)
  - [4.2 命令行解析 BatchCompilerOptions](#42-命令行解析-batchcompileroptions)
  - [4.3 启动序列](#43-启动序列)
- [五、核心类与继承关系](#五核心类与继承关系)
  - [5.1 BatchCompiler 类定义](#51-batchcompiler-类定义)
  - [5.2 TaskRecord 任务记录](#52-taskrecord-任务记录)
  - [5.3 BatchCompilerOptions](#53-batchcompileroptions)
- [六、关键算法与数据结构](#六关键算法与数据结构)
  - [6.1 build 主流程](#61-build-主流程)
  - [6.2 onTask* 回调与任务统计](#62-ontask-回调与任务统计)
  - [6.3 handleMessage 日志重定向](#63-handlemessage-日志重定向)
  - [6.4 outputReport HTML 报告生成](#64-outputreport-html-报告生成)
  - [6.5 ConsoleHandler Ctrl-C 优雅终止](#65-consolehandler-ctrl-c-优雅终止)
  - [6.6 输入路径解析与去重](#66-输入路径解析与去重)
- [七、配置项与命令行参数](#七配置项与命令行参数)
- [八、与其他模块的依赖关系](#八与其他模块的依赖关系)
- [九、关键代码片段](#九关键代码片段)
- [十、设计亮点与注意事项](#十设计亮点与注意事项)

---

## 一、概述与定位

`batch_compiler` 是 BigWorld Engine 资产管线的**命令行批量编译工具**。它的典型用途是:

- **CI/构建服务器**:在 nightly build 中执行 `batch_compiler.exe resources/ -report build.html`,把整个项目的所有过期资产编译一遍,生成 HTML 报告供 QA 检查。
- **美术资源提交钩子**:提交资产后触发 batch_compiler 编译,确保不破坏构建。
- **首次构建**:新开发环境初始化时,批量编译所有资产到 intermediate/output 目录。

与 `jit_compiler`(常驻 GUI 守护进程)相比,batch_compiler 的特点是:

| 维度 | batch_compiler | jit_compiler |
|---|---|---|
| 形态 | CLI 控制台程序 | WTL GUI 应用 |
| 生命周期 | 一次性,编完即退出 | 常驻,直到用户关闭 |
| 触发 | 命令行参数指定 | 文件变更/IPC 请求 |
| 多线程 | 默认非递归 + 多线程队列调度 | 递归模式 + 双线程 |
| 输出 | HTML 报告 + stdout 日志 | GUI 任务列表 |
| 终止 | Ctrl-C 优雅终止 | 关闭窗口按钮 |

batch_compiler 代码量约 1100 行,其中 `batch_compiler.cpp` 991 行,`batch_compiler.hpp` 112 行。它**几乎不实现编译逻辑**——所有编译流程都由基类 `AssetCompiler` 完成,batch_compiler 只负责:

1. 解析命令行参数。
2. 重写 `onTask*` 回调以收集任务记录。
3. 重写 `handleMessage` 以重定向日志到 stdout + TaskRecord。
4. 生成 HTML 报告。
5. 处理 Ctrl-C。

这种"薄前端 + 厚基类"的设计让 batch_compiler 极为简洁,同时与 jit_compiler 共享同一套编译内核。

---

## 二、整体架构

batch_compiler 的架构是 asset_pipeline 的最薄可能前端:

```
┌──────────────────────────────────────────────────────────────────┐
│              batch_compiler.exe (CLI)                            │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ main() / bw_main()                                        │  │
│  │  - SetConsoleCtrlHandler(ConsoleHandler)                  │  │
│  │  - BWResource::init                                       │  │
│  │  - BatchCompilerOptions::parseCommandLine                 │  │
│  │  - BatchCompiler bc                                       │  │
│  │  - options.apply(bc)                                      │  │
│  │  - bc.initPlugins() / initCompiler() / build(paths)       │  │
│  │  - bc.outputReport()                                      │  │
│  │  - bc.finiCompiler() / finiPlugins()                      │  │
│  └────────────────────────────────────────────────────────────┘  │
│         │ 派生                                                   │
│         ▼                                                        │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ BatchCompiler : AssetCompiler, PluginLoader               │  │
│  │  重写:                                                     │  │
│  │   - onTaskStarted/Resumed/Suspended/Completed             │  │
│  │   - onPreCreateDependencies / onPreConvert                │  │
│  │   - onOutputGenerated / onCacheRead/...                   │  │
│  │   - handleMessage(日志重定向)                             │  │
│  │   - shouldIterateFile/Directory                           │  │
│  │  新增:                                                     │  │
│  │   - build(paths)                                          │  │
│  │   - outputReport(filename)                                │  │
│  │   - TaskRecord 任务记录                                    │  │
│  │   - ConsoleHandler (Ctrl-C)                               │  │
│  └────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
                              │ 继承 asset_pipeline 全部能力
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│ asset_pipeline (核心库,见 asset_pipeline 实现分析)              │
│  AssetCompiler / TaskFinder / TaskProcessor / ConverterMap / ...│
└──────────────────────────────────────────────────────────────────┘
```

整体调用流:

```
bw_main(argc, argv)
    ├─ SetConsoleCtrlHandler
    ├─ BWResource::init + AutoConfig
    ├─ BatchCompilerOptions::parseCommandLine
    ├─ BatchCompiler bc
    ├─ options.apply(bc)
    ├─ bc.initPlugins()         # 加载 converters/*.dll
    ├─ bc.initCompiler()        # asset_pipeline 启动
    ├─ bc.build(paths)          # 扫描 + 编译
    │    ├─ TaskFinder.findTasks(dir)
    │    └─ TaskProcessor.processTasks()   # 多线程
    │         └─ AssetCompiler 回调 → BatchCompiler.onTask*
    ├─ bc.outputReport(path)    # HTML
    ├─ bc.finiCompiler()
    └─ bc.finiPlugins()
```

---

## 三、目录结构

batch_compiler 源码位于 `programming/bigworld/tools/batch_compiler/`,目录极为简洁:

```
batch_compiler/
├── batch_compiler.hpp     # BatchCompiler 类声明(112 行)
├── batch_compiler.cpp     # BatchCompiler + bw_main + main 实现(991 行)
└── (依赖 asset_pipeline, plugin_system)
```

整个工具只有 2 个源文件,这与 jit_compiler(20+ 文件)形成鲜明对比——CLI 工具天然不需要 UI 相关的对话框、主窗口等代码。

构建产物为 `batch_compiler.exe`,部署时通常和 `asset_rules.xml`、`converters/*.dll`、`resources/report_style.css`、`resources/report_script.js` 一起发布。

---

## 四、入口点与启动流程

### 4.1 main / bw_main

`batch_compiler.cpp:988-990` 是标准 C `main`:

```cpp
988→int main( int argc, char* argv[] )
989→{
990→	return BW_NAMESPACE bw_main( argc, argv );
991→}
```

`bw_main`(`batch_compiler.cpp:935-984`)是 BigWorld 标准的入口模板,负责完整启动序列:

```cpp
935→int bw_main( int argc, char* argv[] )
936→{
937→	BW_GUARD;
939→	SetConsoleCtrlHandler( BatchCompiler_Locals::ConsoleHandler, TRUE );
941→	BW_SYSTEMSTAGE_MAIN();
942→#ifdef ENABLE_MEMTRACKER
943→	MemTracker::instance().setCrashOnLeak( true );
944→#endif
947→	bool bInitRes = BWResource::init( BW::BWResource::appDirectory(), false );
949→	if ( !AutoConfig::configureAllFrom( "resources.xml" ) )
950→	{
951·		ERROR_MSG("Couldn't load auto-config strings from resource.xml\n" );
952→	}
954→	int retval = 0;
956→	BatchCompilerOptions options;
957→	if (options.parseCommandLine( bw_wtoutf8( GetCommandLine() ) ))
958→	{
959→		BatchCompiler bc;
960·        BatchCompiler_Locals::batchCompiler_ = &bc;       // 给 ConsoleHandler 用
961→		options.resolveInputPaths();
962→		options.apply( bc );
963·		bc.initPlugins();
964·		bc.initCompiler();
965·		bc.build( options.getInputPaths() );
966→		if (options.generateReport())
967·		{
968·			bc.outputReport( options.getReportPath() );
969·		}
970·		bc.finiCompiler();
971·		bc.finiPlugins();
972·        BatchCompiler_Locals::batchCompiler_ = NULL;
973→
974·		retval = bc.getFailedCount();     // 进程退出码 = 失败任务数
975→	}
978→	BWResource::fini();
981→	DataSectionCensus::fini();
983→	return retval;
984→}
```

关键设计:

1. **L939 SetConsoleCtrlHandler**:在 `bw_main` 第一行就安装 Ctrl-C 处理器,确保后续所有阶段都能被 Ctrl-C 中断。
2. **L943 setCrashOnLeak**:启用 MemTracker 时,内存泄漏直接 crash,便于调试(发布版关闭)。
3. **L947 BWResource::init**:用 `appDirectory()` 而非 argv[0] 初始化资源路径,避免 argv[0] 被修改的问题。
4. **L960 batchCompiler_ 全局指针**:把当前 BatchCompiler 实例存到全局指针,供 `ConsoleHandler`(静态函数)访问。这是个简化设计,因为 batch_compiler 进程内只会有一个 BatchCompiler 实例。
5. **L974 退出码 = 失败任务数**:CI 系统可据此判断构建是否成功(0=全成功,>0=有失败),且失败数能反映严重程度。

### 4.2 命令行解析 BatchCompilerOptions

`BatchCompilerOptions`(`batch_compiler.cpp:798-931`)继承 `AssetCompilerOptions`,扩展了输入路径与报告路径:

```cpp
798→class BatchCompilerOptions : public AssetCompilerOptions
799→{
801→	typedef BW::vector< BW::string > Paths;
803→	BatchCompilerOptions()
804·		: AssetCompilerOptions()
805·		, reportPath_()
806·	{
807·	}
809→	virtual bool parseCommandLine( const BW::string & commandString ) override;
811→	void resolveInputPaths();
813→	bool generateReport() const { return !reportPath_.empty(); }
818→	const BW::string & getReportPath() const { return reportPath_; }
823→	const Paths & getInputPaths() const { return inputPaths_; }
828→	bool parseInputPaths( const CommandLine & commandLine );
832→	Paths parsedPaths_;      // 用户原始输入
833→	Paths inputPaths_;       // 去重后的实际输入
835·	BW::string reportPath_;
836→};
```

`parseCommandLine`(`batch_compiler.cpp:838-857`)先解析输入路径与报告路径,再调用基类 `AssetCompilerOptions::parseCommandLine` 解析通用参数:

```cpp
838→bool BatchCompilerOptions::parseCommandLine( const BW::string & commandString )
839→{
840·	CommandLine	commandLine( commandString.c_str() );
842·	if (!parseInputPaths( commandLine ))
843·	{
844·		ERROR_MSG("ERROR: No valid inputs\n");
845·		return false;
846·	}
848·	if (commandLine.hasParam( "report" ))
849·	{
850·		BW::string report = commandLine.getParam( "report" );
851·		reportPath_ = AssetCompiler::sanitisePathParam( BWResource::getFilePath( report ).c_str() )
852·			+ BWResource::getFilename( report );
853·		BWResource::ensureAbsolutePathExists( reportPath_ );
854·	}
856·	return AssetCompilerOptions::parseCommandLine( commandString );
857→}
```

`parseInputPaths`(`batch_compiler.cpp:859-895`)遍历命令行参数,跳过开关参数(`-xxx`),把非开关参数当作输入路径:

```cpp
859→bool BatchCompilerOptions::parseInputPaths( const CommandLine & commandLine )
860→{
861·	MultiFileSystem* fs = BWResource::instance().fileSystem();
862·	bool hasInput = false;
865→	for (uint i = 1; i < commandLine.size(); ++i)
866·	{
867·		const char * input = commandLine.getParamByIndex( i );
868·		if (strlen( input ) == 0) continue;
872·		if (CommandLine::hasSwitch(input)) { ++i; continue; }  // 跳过开关 + 其值
878·		hasInput = true;
879·		BW::string inputPath = input;
880·		BWResource::resolveToAbsolutePath( inputPath );
881·		inputPath = AssetCompiler::sanitisePathParam( inputPath.c_str() );
883·		auto ft = fs->getFileType( inputPath );
884·		if (ft != IFileSystem::FT_FILE && ft != IFileSystem::FT_DIRECTORY)
885·		{
886·			WARNING_MSG("Invalid input: %s\n", input);
887·			continue;
888·		}
891·		parsedPaths_.push_back( inputPath );
892·	}
894→	return hasInput != parsedPaths_.empty();
895→}
```

注意 L872 的 `hasSwitch(input)` 判断——如果参数本身是开关(如 `-report`),则跳过它和它的下一个参数(值)。这避免了把 `-report build.html` 中的 `build.html` 误识别为输入路径。

### 4.3 启动序列

完整的启动序列(对照 4.1 的代码):

| 步骤 | 代码 | 作用 |
|---|---|---|
| 1 | `SetConsoleCtrlHandler` | 安装 Ctrl-C 处理器 |
| 2 | `BW_SYSTEMSTAGE_MAIN()` | 设置系统阶段标识(调试用) |
| 3 | `MemTracker::setCrashOnLeak` | 启用泄漏即崩(调试版) |
| 4 | `BWResource::init(appDirectory, false)` | 初始化资源管理器 |
| 5 | `AutoConfig::configureAllFrom("resources.xml")` | 加载自动配置 |
| 6 | `BatchCompilerOptions::parseCommandLine` | 解析命令行 |
| 7 | `BatchCompiler bc` | 构造(创建单实例互斥锁) |
| 8 | `options.resolveInputPaths()` | 输入路径去重 |
| 9 | `options.apply(bc)` | 应用选项到编译器 |
| 10 | `bc.initPlugins()` | 加载 converters 插件 |
| 11 | `bc.initCompiler()` | 启动 BgTaskManager、加载 asset_rules.xml |
| 12 | `bc.build(paths)` | 扫描 + 编译(主耗时) |
| 13 | `bc.outputReport(path)` | 生成 HTML 报告(可选) |
| 14 | `bc.finiCompiler()` | 停止工作线程 |
| 15 | `bc.finiPlugins()` | 卸载插件 |
| 16 | `BWResource::fini()` | 清理资源管理器 |
| 17 | `DataSectionCensus::fini()` | 清理 DataSection 引用计数 |
| 18 | `return bc.getFailedCount()` | 退出码 = 失败数 |

---

## 五、核心类与继承关系

### 5.1 BatchCompiler 类定义

`batch_compiler.hpp:13-108` 是 BatchCompiler 的完整声明:

```cpp
13→class BatchCompiler : public AssetCompiler
14·				, public PluginLoader
15→{
16→public:
17·	BatchCompiler();
18·	virtual ~BatchCompiler();
20·	void build( const BW::vector< BW::string > & paths );
21·	void outputReport( const StringRef & filename );
23·	long getFailedCount() const { return taskFailedCount_; }
25→private:
26·	DataSectionPtr writeSection( DataSectionPtr pDataSection, const StringRef & id, const StringRef & classType );
27·	DataSectionPtr writeBreak( DataSectionPtr pDataSection );
28·	DataSectionPtr writeHeading( DataSectionPtr pDataSection, const StringRef & heading, uint8 size = 1 );
29·	DataSectionPtr writeText( DataSectionPtr pDataSection, const StringRef & text, const StringRef & style );
30·	DataSectionPtr writeLink( DataSectionPtr pDataSection, const StringRef & link, const StringRef & text, const StringRef & style );
32→public:
33·	virtual bool shouldIterateFile( const StringRef & file );
34·	virtual bool shouldIterateDirectory( const StringRef & directory );
36·	virtual void onTaskStarted( ConversionTask & conversionTask );
37·	virtual void onTaskResumed( ConversionTask & conversionTask );
38·	virtual void onTaskSuspended( ConversionTask & conversionTask );
39·	virtual void onTaskCompleted( ConversionTask & conversionTask );
41·	virtual void onPreCreateDependencies( ConversionTask & conversionTask );
43·	virtual void onPreConvert( ConversionTask & conversionTask );
45·	virtual void onOutputGenerated( const BW::string & filename );
47·	virtual void onCacheRead( const BW::string & filename );
48·	virtual void onCacheReadMiss( const BW::string & filename );
49·	virtual void onCacheWrite( const BW::string & filename );
50·	virtual void onCacheWriteMiss( const BW::string & filename );
52·	virtual bool handleMessage( DebugMessagePriority messagePriority, ... );
59→public:
60·	struct TaskRecord
61·	{
62·		TaskRecord()
63·			: id_( -1 )
64·			, upToDate_( true )
65·			, skipped_( true )
66·			, hasError_( false )
67·			, hasWarning_( false )
68·			, duration_( 0 ) {}
70·		long id_;
71·		bool upToDate_;
72·		bool skipped_;
73·		bool hasError_;
74·		bool hasWarning_;
75·		double duration_;
76·		BW::vector<BW::string> outputs_;
77·		BW::string log_;
78·	};
80→private:
82·	BW::map<const ConversionTask *, TaskRecord *>	taskRecords_;
83·	SimpleMutex										taskRecordsMutex_;
84·	static THREADLOCAL( TaskRecord * )				s_currentTaskRecord;
85·	static THREADLOCAL( uint64 )					s_currentTaskStartTime;
87·	// General stats
88·	double			totalDuration_;
89·	volatile long	cacheReadCount_;
90·	volatile long	cacheReadMissCount_;
91·	volatile long	cacheWriteCount_;
92·	volatile long	cacheWriteMissCount_;
94·	// Discovery stats
95·	long			filesIterated_;
96·	long			directoriesIterated_;
98·	// Conversion stats
99·	volatile long	taskCount_;
100·	volatile long	taskFailedCount_;
101·	volatile long	taskUpToDateCount_;
102·	volatile long	taskSkippedCount_;
103→
108→};
```

继承关系:

```
Compiler (asset_pipeline 抽象基类)
   ▲
   │
AssetCompiler (asset_pipeline 实现基类)
   ▲
   │
BatchCompiler : AssetCompiler, PluginLoader    // CLI 批量编译
```

注意 `BatchCompiler` 同时继承 `AssetCompiler`(编译能力)和 `PluginLoader`(插件加载)。`PluginLoader` 负责在运行时加载 `converters/*.dll`,这些 DLL 通过 `INIT_CONVERTER_INFO` 宏注册 Converter 到 `AssetCompiler::converterMap_`。

### 5.2 TaskRecord 任务记录

`TaskRecord`(`batch_compiler.hpp:60-78`)是 batch_compiler 为每个任务维护的统计记录:

```cpp
60→	struct TaskRecord
61→	{
62·		TaskRecord()
63·			: id_( -1 )
64·			, upToDate_( true )      // 默认认为 up to date(不需转换)
65·			, skipped_( true )       // 默认认为 skipped(依赖也没重新生成)
66·			, hasError_( false )
67·			, hasWarning_( false )
68·			, duration_( 0 ) {}
70·		long id_;                   // 全局唯一任务 ID(从 1 递增)
71·		bool upToDate_;             // 依赖生成但转换跳过
72·		bool skipped_;              // 依赖与转换都跳过
73·		bool hasError_;             // 是否有错误
74·		bool hasWarning_;           // 是否有警告
75·		double duration_;            // 累计耗时(秒)
76·		BW::vector<BW::string> outputs_;  // 生成的输出文件列表
77·		BW::string log_;            // 完整日志(含 ERROR/WARNING/assert)
78·	};
```

`upToDate_` 与 `skipped_` 的区别很重要(见 L101-106 注释):

- `skipped_ = true`:任务完全跳过(依赖列表与转换都未执行,因为所有依赖哈希都没变)。
- `upToDate_ = true && skipped_ = false`:依赖列表重新生成了(因为 primary 依赖变了),但转换被跳过(因为 secondary 依赖都没变,输出未过期)。
- `upToDate_ = false && skipped_ = false`:执行了转换。

这三个状态对应 HTML 报告中的 "Converted" / "Up To Date" / "Skipped" 三个分类。

`TaskRecord` 通过 `BW::map<const ConversionTask *, TaskRecord *> taskRecords_` 持久化,以 `ConversionTask*` 为 key。`s_currentTaskRecord` 是线程局部存储,每个工作线程维护自己当前正在处理的 TaskRecord,无需加锁。

### 5.3 BatchCompilerOptions

`BatchCompilerOptions`(`batch_compiler.cpp:798-836`)的继承关系:

```
AssetCompilerOptions (asset_pipeline)
   ▲
   │
BatchCompilerOptions : AssetCompilerOptions
   新增:
    - parsedPaths_   (用户原始输入路径)
    - inputPaths_    (去重后的实际输入路径)
    - reportPath_    (HTML 报告路径)
   重写:
    - parseCommandLine  (先解析输入/报告,再调基类)
    - resolveInputPaths (去重子路径)
```

`resolveInputPaths`(`batch_compiler.cpp:897-931`)的作用是去除"父子路径"的冗余——如果用户同时指定了 `resources/` 和 `resources/textures/`,后者是前者的子路径,会被去除:

```cpp
897→void BatchCompilerOptions::resolveInputPaths()
898→{
899·	MultiFileSystem* fs = BWResource::instance().fileSystem();
902·	if (parsedPaths_.empty())
903·	{
904·		const int numPaths = BWResource::getPathNum();
905·		for (int i = 0; i < numPaths; ++i)
906·		{
907·			BW::string inputPath = AssetCompiler::sanitisePathParam( BWResource::getPath( i ).c_str() );
908·			parsedPaths_.push_back( inputPath );
909·		}
910·	}
913·	inputPaths_.clear();
914·	std::copy_if(std::begin(parsedPaths_), std::end(parsedPaths_), std::back_inserter(inputPaths_),
915·		[this, fs]( const BW::string & inputPath ) -> bool
916·	{
918·		if (fs->getFileType( inputPath ) == IFileSystem::FT_FILE)
919·			return true;          // 文件总是保留
923·		const bool subPath = std::any_of(std::begin(parsedPaths_), std::end(parsedPaths_),
924·			[&inputPath](const BW::string & path) -> bool
925·		{
926·			return path.compare(0, path.length(), inputPath) == 0 && inputPath.length() != path.length();
927·		});
929·		return !subPath;          // 是某路径的子路径则去除
930·	});
931→}
```

注意 L902-910:**如果用户没指定输入路径,默认使用所有 BWResource 路径**。这是 `batch_compiler.exe`(无参数)能直接编译整个项目的机制。

---

## 六、关键算法与数据结构

### 6.1 build 主流程

`BatchCompiler::build`(`batch_compiler.cpp:84-133`)是 batch_compiler 的主入口:

```cpp
84→void BatchCompiler::build( const BW::vector< BW::string > & paths )
85→{
86·	MultiFileSystem* fs = BWResource::instance().fileSystem();
87·	IFileSystem::FileType ft;
89·	uint64 startTime = timestamp();
91·	MF_ASSERT( taskQueue_.empty() );     // 必须从空队列开始
93·	for (BW::vector< BW::string >::const_iterator
94·		it = paths.begin(); it != paths.end(); ++it)
95·	{
96·		ft = fs->getFileType( *it );
97·		if (ft == IFileSystem::FT_FILE)
98·		{
99·			INFO_MSG( "========== Processing File: %s ==========\n", it->c_str() );
100·			ConversionTask & task = taskFinder_.getTask( *it );
101·			if (task.converterId_ == ConversionTask::s_unknownId)
102·			{
103·				ERROR_MSG( "Could not find task for file %s\n", it->c_str() );
104·			}
105·			else
107·			{
108·				// Queue the non root task
109·				queueTask( task );          // 直接入队(非根任务)
110·			}
111·		}
112·		else if (ft == IFileSystem::FT_DIRECTORY)
113·		{
114·			INFO_MSG( "========== Processing Directory: %s ==========\n", it->c_str() );
115·			taskFinder_.findTasks( *it );   // 递归扫描目录
116·		}
117·	}
119→	INFO_MSG( "========== Found: %d tasks, Searched: %d files, %d directories ==========\n",
120·		taskQueue_.size(), filesIterated_, directoriesIterated_ );
123·	taskProcessor_.processTasks();        # 实际编译(多线程)
124·	INFO_MSG( "========== Conversion: %d succeeded, %d failed, %d converted, %d up-to-date, %d skipped ==========\n",
125·		taskCount_ - taskFailedCount_,
126·		taskFailedCount_,
127·		taskCount_ - ( taskFailedCount_ + taskUpToDateCount_ + taskSkippedCount_ ),
128·		taskUpToDateCount_,
129·		taskSkippedCount_ );
131·	uint64 endTime = timestamp();
132·	totalDuration_ = (double)(((int64)(endTime - startTime)) / stampsPerSecondD());
133→}
```

注意 L97-110 vs L112-116 的区别:

- **文件路径**:`taskFinder_.getTask(*it)` 创建**非根任务**(`bRoot=false`),直接入队。这意味着指定单个文件时,不会触发目录扫描。
- **目录路径**:`taskFinder_.findTasks(*it)` 递归扫描,通过 `iterateFile` 创建**根任务**。

L101-103 的检查:`s_unknownId` 表示没有规则匹配该文件——如果是用户显式指定的文件,这是个错误(用户期望它被编译);如果是目录扫描遇到的,会被 `iterateFile` 跳过(不报错)。

L123 的 `taskProcessor_.processTasks()` 是阻塞调用,内部会调 `processTasksOnMultipleThreads`(见 asset_pipeline 文档 6.8.1),直到所有任务完成才返回。

### 6.2 onTask* 回调与任务统计

batch_compiler 重写了 4 个 `onTask*` 回调来维护 TaskRecord:

#### 6.2.1 onTaskStarted

`batch_compiler.cpp:517-538`:

```cpp
517→void BatchCompiler::onTaskStarted( ConversionTask & conversionTask )
518→{
519·	BW_GUARD;
521·	MF_ASSERT( s_currentTaskRecord == NULL );
524·	s_currentTaskRecord = new TaskRecord();          // 新建记录
527·	taskRecordsMutex_.grab();
528·	taskRecords_[&conversionTask] = s_currentTaskRecord;
529·	taskRecordsMutex_.give();
532·	s_currentTaskRecord->id_ = InterlockedIncrement( &taskCount_ );   // 原子递增
533·	s_currentTaskStartTime = timestamp();
535·	INFO_MSG( "------ Task started: %s ------\n", conversionTask.source_.c_str() );
537·	AssetCompiler::onTaskStarted( conversionTask );  // 调基类
538→}
```

`InterlockedIncrement` 保证多线程下 `taskCount_` 唯一递增,作为 TaskRecord 的全局 ID(用于 HTML 报告中的锚点跳转)。

#### 6.2.2 onTaskResumed

`batch_compiler.cpp:540-557`:

```cpp
540→void BatchCompiler::onTaskResumed( ConversionTask & conversionTask )
541→{
544·	MF_ASSERT( s_currentTaskRecord == NULL );
547·	taskRecordsMutex_.grab();
548·	BW::map<const ConversionTask *, TaskRecord *>::iterator it =
549·		taskRecords_.find( &conversionTask );
550·	MF_ASSERT( it != taskRecords_.end() );
551·	s_currentTaskRecord = it->second;                // 恢复已存在的记录
552·	taskRecordsMutex_.give();
554·	s_currentTaskStartTime = timestamp();            // 重置开始时间
556·	AssetCompiler::onTaskResumed( conversionTask );
557→}
```

任务被 suspend 后再 resume 时,从 `taskRecords_` 中找回原记录(通过 `ConversionTask*`),继续累计耗时。

#### 6.2.3 onTaskSuspended

`batch_compiler.cpp:559-574`:

```cpp
559→void BatchCompiler::onTaskSuspended( ConversionTask & conversionTask )
560→{
563·	MF_ASSERT( s_currentTaskRecord != NULL );
566·	uint64 currentTime = timestamp();
567·	s_currentTaskRecord->duration_ += (double)(((int64)(currentTime - s_currentTaskStartTime)) / stampsPerSecondD());
570·	s_currentTaskRecord = NULL;
571·	s_currentTaskStartTime = 0;
573·	AssetCompiler::onTaskSuspended( conversionTask );
574→}
```

suspend 时把当前段时间累加到 `duration_`,然后清空 `s_currentTaskRecord`。**注意累加而非赋值**——任务可能被多次 suspend/resume,总耗时是各段之和。

#### 6.2.4 onTaskCompleted

`batch_compiler.cpp:576-604`:

```cpp
576→void BatchCompiler::onTaskCompleted( ConversionTask & conversionTask )
577→{
580·	MF_ASSERT( s_currentTaskRecord != NULL );
582·	if (conversionTask.status_ == ConversionTask::FAILED)
583·	{
584·		InterlockedIncrement( &taskFailedCount_ );
585·	}
586·	else if (s_currentTaskRecord->skipped_)
587·	{
588·		InterlockedIncrement( &taskSkippedCount_ );
589·	}
590·	else if (s_currentTaskRecord->upToDate_)
591·	{
592·		InterlockedIncrement( &taskUpToDateCount_ );
593·	}
596·	uint64 currentTime = timestamp();
597·	s_currentTaskRecord->duration_ += (double)(((int64)(currentTime - s_currentTaskStartTime)) / stampsPerSecondD());
600·	s_currentTaskRecord= NULL;
601·	s_currentTaskStartTime = 0;
603·	AssetCompiler::onTaskCompleted( conversionTask );
604→}
```

完成时根据 `status_` 与 `skipped_`/`upToDate_` 分类统计:

| status_ | skipped_ | upToDate_ | 计入 |
|---|---|---|---|
| FAILED | - | - | taskFailedCount_ |
| DONE | true | - | taskSkippedCount_ |
| DONE | false | true | taskUpToDateCount_ |
| DONE | false | false | (none,归入 converted) |

converted 数 = `taskCount_ - failed - upToDate - skipped`(见 L127)。

#### 6.2.5 onPreCreateDependencies / onPreConvert

这两个回调用于翻转 `skipped_` / `upToDate_` 标志:

```cpp
606→void BatchCompiler::onPreCreateDependencies( ConversionTask & conversionTask )
612·	s_currentTaskRecord->skipped_ = false;       // 要重新生成依赖,不算 skipped
617→void BatchCompiler::onPreConvert( ConversionTask & conversionTask )
624·	s_currentTaskRecord->upToDate_ = false;      // 要转换,不算 up to date
625·	s_currentTaskRecord->skipped_ = false;
```

这两个标志的初始值都是 `true`(构造函数),只有在对应回调被触发时才翻为 `false`。这保证了"什么都没做"的任务最终归入 `skipped`。

### 6.3 handleMessage 日志重定向

`BatchCompiler::handleMessage`(`batch_compiler.cpp:680-794`)是日志系统的核心,重写自 `DebugMessageCallback`:

```cpp
680→bool BatchCompiler::handleMessage( DebugMessagePriority messagePriority,
681·								   const char * pCategory, ... )
685→{
689→#if !ASSET_PIPELINE_CAPTURE_ASSERTS
690·	if (messagePriority == DebugMessagePriority::MESSAGE_PRIORITY_CRITICAL)
691·	{
692·		return false;        // 不捕获 assert,让其弹窗
693·	}
694→#endif
696·	bool handled = AssetCompiler::handleMessage( ... );  // 调基类
703·	if (s_CreatingDependencies || s_Converting)
704·	{
705·		switch (messagePriority)
706·		{
708·		case DebugMessagePriority::MESSAGE_PRIORITY_CRITICAL:
709·			if (s_currentTaskRecord != NULL)
710·			{
712·				char buf[2048];
713·				bw_vsnprintf( buf, 2048, pFormat, argPtr );
714·				char * line = strtok( buf, "\n" );
716·				// Ignore the first three lines of the assert message
717·				for ( int i = 0; i < 3; ++i )
718·					line = strtok( NULL, "\n" );
722·				if (line != NULL)
723·				{
724·					size_t logSize = s_currentTaskRecord->log_.size();
725·					s_currentTaskRecord->log_.append( line );
726·					s_currentTaskRecord->log_.append( "\n" );
728·					fprintf( stdout, "%d>  %s", s_currentTaskRecord->id_, msg );   // 同时打印到 stdout
729·				}
730·				line = strtok( NULL, "\n" );
731·				if (line != NULL) { ... 同上打印第 5 行 ... }
740·				handled = true;
742·			}
743·			break;
744→		case DebugMessagePriority::MESSAGE_PRIORITY_ERROR:
745→			// 类似,但只加 "ERROR: " 前缀,打印所有行
758·			break;
762→		case DebugMessagePriority::MESSAGE_PRIORITY_WARNING:
765·			// 类似,加 "WARNING: " 前缀
778·			break;
780→		}
781→	}
782·	else if (pCategory != NULL && strcmp( pCategory, ASSET_PIPELINE_CATEGORY ) == 0)
783→	{
784·		// asset_pipeline 自身的日志,带 task id 前缀打印
788·		vfprintf( stdout, reformat, argPtr );
790·		handled = true;
791·	}
793→	return handled;
794→}
```

关键设计:

1. **L689 `ASSET_PIPELINE_CAPTURE_ASSERTS`**:默认不捕获 CRITICAL(assert),让其走默认的弹窗流程;若定义则捕获并记入 TaskRecord。批处理场景通常关闭捕获,让 assert 直接弹窗以便调试。
2. **L703 `s_CreatingDependencies || s_Converting`**:只在 Converter 执行期间记录日志,避免 asset_pipeline 自身的 INFO 日志(如 "Checking primary dependencies...")被错误归到当前任务。
3. **L716-719 跳过 assert 前 3 行**:BigWorld assert 消息格式是 `Module/File:Line: Function: Expression\nStack trace...`,前 3 行是文件位置与表达式,后 2 行才是有意义的调用栈。这种"跳过前 3 行,取后 2 行"的解析硬编码了消息格式。
4. **L728/L756/L774 fprintf stdout**:同时打印到 stdout,带 `<taskid>>` 前缀,便于 CI 日志追踪。
5. **L782 `ASSET_PIPELINE_CATEGORY` 过滤**:只处理 asset_pipeline 类别的日志,其他类别(如 network)交给默认处理器。

### 6.4 outputReport HTML 报告生成

`BatchCompiler::outputReport`(`batch_compiler.cpp:135-406`)生成 HTML 报告,这是个冗长但直观的函数。它使用 `DataResource` + `XMLSection` 构造 HTML DOM,然后保存为 `.html`:

```cpp
135→void BatchCompiler::outputReport( const StringRef & filename )
136→{
137·	BW_GUARD;
139·	taskRecordsMutex_.grab();
142·	DataResource reportResource( filename.to_string(), RESOURCE_TYPE_XML, true );
143·	DataSectionPtr rootSection = reportResource.getRootSection();
144·	rootSection->delChildren();
145·	rootSection->save( "html" );
148→	DataSectionPtr headSection = rootSection->newSection( "head" );
151·	DataSectionPtr css = BWResource::openSection( "resources/report_style.css" );
152·	if (css != NULL)
153·	{
154·		DataSectionPtr styleSection = headSection->newSection( "style" );
155·		DataSectionPtr typeSection = styleSection->newSection( "type" );
156·		typeSection->isAttribute( true );
157·		typeSection->setString( "text/css" );
158·		styleSection->setString( StringRef( css->asBinary()->cdata(), css->asBinary()->len() ) );
159·		styleSection->noXMLEscapeSequence( true );
160·	}
163·	DataSectionPtr javascript = BWResource::openSection( "resources/report_script.js" );
164·	if (javascript != NULL)
165·	{
166·		DataSectionPtr scriptSection = headSection->newSection( "script" );
167·		// ... 同上,嵌入 JS
172·	}
174→	time_t ttime = ::time( NULL );
175·	BW::string formattedTime;
176·	DateTimeUtils::format( formattedTime, ttime, true );
179·	DataSectionPtr bodySection = rootSection->newSection( "body" );
182→	StringBuilder heading(1024);
183·	heading.append( "Batch Compiler " );
184·	heading.append( formattedTime );
185→	writeHeading( bodySection, heading.string() );
188→	DataSectionPtr infoSection = writeSection( bodySection, "", "" );
189·	writeText( infoSection, bw_wtoutf8( GetCommandLine() ), "" );   // 命令行
194·	DataSectionPtr summarySection = writeSection( bodySection, "", "Group" );
195·	writeText( summarySection, "Summary", "font-size:150%;font-weight:bold;" );
197→	BW::string discoverySummary = bw_format( "Found: %d tasks, Searched: %d files, %d directories",
198·		taskQueue_.size(), filesIterated_, directoriesIterated_ );
199·	writeText( summarySection, discoverySummary, "" );
203·	BW::string conversionSummary = bw_format( "Conversion: %d succeeded, %d failed, %d converted, %d up-to-date, %d skipped", ... );
209·	writeText( summarySection, conversionSummary, "" );
211·	writeText( summarySection,
212·		bw_format( "Cache: %d Reads, %d Failed Reads, %d Writes, %d Failed Writes",
213·			cacheReadCount_, cacheReadMissCount_, cacheWriteCount_, cacheWriteMissCount_ ), "" );
214·	writeText( summarySection, bw_format( "Total Duration: %f seconds", totalDuration_ ), "" );
```

报告结构(由 `writeSection`/`writeText`/`writeLink` 等 helper 构造):

```
<html>
  <head>
    <style>...CSS...</style>
    <script>...JS...</script>
  </head>
  <body>
    <h1>Batch Compiler 2026-06-30 12:34:56</h1>
    <div>batch_compiler.exe -j 8 -report build.html resources/</div>
    <div class="Group">
      <div style="font-size:150%;font-weight:bold;">Summary</div>
      <div>Found: 1234 tasks, Searched: 5678 files, 90 directories</div>
      <div>Conversion: 1200 succeeded, 34 failed, 100 converted, 800 up-to-date, 300 skipped</div>
      <div>Cache: 500 Reads, 12 Failed Reads, 100 Writes, 0 Failed Writes</div>
      <div>Total Duration: 123.456789 seconds</div>
      <div class="SubGroup">
        <a href="javascript:Toggle('Failures');">Failures (34)</a>
        <div id="Failures" class="Toggleable">
          <a href="javascript:GoTo('5');">objects/hero/body.visual</a><br/>
          ... 34 个失败任务链接 ...
        </div>
      </div>
      <div class="SubGroup">...Warnings (12)...</div>
      <div class="SubGroup">...Converted (100)...</div>
      <div class="SubGroup">...Up To Date (800)...</div>
      <div class="SubGroup">...Skipped (300)...</div>
    </div>
    <div class="Group">
      <div style="font-size:150%;font-weight:bold;">Tasks</div>
      <div id="1" class="Task">
        <a href="javascript:Toggle('1');">1. objects/hero/body.visual</a>
        <div class="Toggleable">
          <div>Duration: 0.123s</div>
          <div>Outputs: hero/body.visual, hero/body.primitives</div>
          <pre>...log...</pre>
        </div>
      </div>
      <div id="2" class="Task">...</div>
      ... 所有任务详情 ...
    </div>
  </body>
</html>
```

关键设计点:

1. **CSS/JS 内嵌**:`report_style.css` 与 `report_script.js` 被读取并内嵌到 `<style>`/`<script>` 标签,生成的 HTML 是单文件,便于邮件分享。
2. **JS 交互**:`Toggle(id)` 折叠/展开分组,`GoTo(id)` 跳转到具体任务,让大报告(数千任务)也易于浏览。
3. **5 个分类分组**:Failures/Warnings/Converted/UpToDate/Skipped,每个都带计数;空分组会被删除(`subgroupSection->delChild(failuresSection)`),保持报告简洁。
4. **任务详情区**:每个任务一个 `<div id="<id>">`,内含耗时、输出列表、完整日志(`<pre>`),通过 `Toggle` 折叠。

`writeSection`/`writeText`/`writeLink` 等 helper(`batch_compiler.cpp:408-510`)是 HTML DOM 构造的便捷封装,本质是 `DataSection::newSection` + 属性设置的组合。

### 6.5 ConsoleHandler Ctrl-C 优雅终止

`batch_compiler.cpp:35-52` 实现了 Ctrl-C 处理器:

```cpp
31→namespace BatchCompiler_Locals
32→{
33·	BatchCompiler * batchCompiler_ = NULL;
35·	BOOL WINAPI ConsoleHandler( DWORD ctrl_type )
36·	{
37·		if ( ctrl_type == CTRL_C_EVENT || ctrl_type == CTRL_BREAK_EVENT )
38·		{
39·			if (batchCompiler_->terminating())
40·			{
41·				// Stop all the executing threads immediately
42·				BgTaskManager::instance().stopAll( true, false );  // 强制停止
43·			}
44·			else
45·			{
46·				// Allow the batch compiler to terminate gracefully
47·				batchCompiler_->terminate();   // 优雅终止
48·			}
49·			return TRUE;
50·		}
51·		return FALSE;
52·	}
53→}
```

**两次 Ctrl-C 设计**:

- **第一次 Ctrl-C**:调 `batchCompiler_->terminate()`,设置 `state_ = TERMINATING`,让正在执行的任务自然完成,然后退出。这是"优雅终止"。
- **第二次 Ctrl-C**(在 `terminating()` 为 true 时):调 `BgTaskManager::stopAll(true, false)`,**强制停止所有工作线程**。第二个参数 `false` 表示不等待它们完成。

这种"先礼后兵"的设计让用户能控制终止力度:偶尔按一次 Ctrl-C 是"请尽快结束",连续按两次是"立刻停下来,我等不及了"。

`AssetCompiler::terminate()` 的实现(在 asset_pipeline)会设置 `state_ = TERMINATING`,`shouldIterateFile/Directory` 等返回 false 中断扫描,工作线程在下一个任务检查点退出。

### 6.6 输入路径解析与去重

见 5.3 节,`resolveInputPaths` 去除父子路径冗余,这里补充几个细节:

- L902-910:**无参数时默认编译所有 BWResource 路径**。这让 `batch_compiler.exe` 无参数运行就能编译整个项目,非常方便。
- L918-921:**文件路径总是保留**,不去重——用户显式指定的文件,即使其父目录也被指定,也要单独处理(可能因为目录扫描被 `shouldIterateFile` 过滤掉了)。
- L926 的 `path.compare(0, path.length(), inputPath) == 0`:判断 `inputPath` 是否是 `path` 的前缀。注意这里的参数顺序——`path.compare(pos, len, str)` 是把 `path` 的 `[pos, pos+len)` 与 `str` 比较。

---

## 七、配置项与命令行参数

batch_compiler 完整的命令行参数(继承自 `AssetCompilerOptions` + 自有扩展):

| 参数 | 类型 | 默认值 | 作用 | 来源 |
|---|---|---|---|---|
| `<path1> <path2> ...` | 路径列表 | 所有 BWResource 路径 | 输入路径(文件或目录) | BatchCompilerOptions |
| `-report <path>` | string | "" | HTML 报告输出路径 | BatchCompilerOptions |
| `-intermediatePath <path>` | string | "" | 中间产物目录 | AssetCompilerOptions |
| `-outputPath <path>` | string | "" | 最终产物目录 | AssetCompilerOptions |
| `-cachePath <path>` | string | 默认 | 内容寻址缓存目录 | AssetCompilerOptions |
| `-j <N>` | int | 1 | 工作线程数 | AssetCompilerOptions |
| `-recursive` | flag | false | 递归模式(子任务嵌套处理) | AssetCompilerOptions |
| `-forceRebuild` | flag | false | 强制重建所有任务 | AssetCompilerOptions |
| `-enableCacheRead <0/1>` | bool | true | 是否从缓存读 | AssetCompilerOptions |
| `-enableCacheWrite <0/1>` | bool | true | 是否写缓存 | AssetCompilerOptions |

典型用法示例:

```bash
# 编译整个项目,8 线程,生成报告
batch_compiler.exe -j 8 -report build.html

# 只编译某个目录,强制重建
batch_compiler.exe resources/objects/ -forceRebuild

# 编译单个文件
batch_compiler.exe resources/objects/hero/body.visual

# 自定义输出目录
batch_compiler.exe -outputPath C:\build\output -intermediatePath C:\build\intermediate resources/
```

asset_pipeline 还会从 `resources.xml` 加载 `AutoConfig` 配置(如 shader include 路径),以及从 `asset_rules.xml` 加载文件扩展名到 Converter 的映射。

---

## 八、与其他模块的依赖关系

```
┌──────────────────────────────────────────────────────────────────┐
│ batch_compiler.exe                                               │
└──┬───────────────────────────────────────────────────────────────┘
   │ 链接(静态库依赖)
   ├─ asset_pipeline  : AssetCompiler, AssetCompilerOptions, TaskFinder,
   │                    TaskProcessor, ConverterMap, ContentAddressableCache,
   │                    DependencyList, ConversionTask, ...
   ├─ plugin_system   : PluginLoader(动态加载 converters/*.dll)
   ├─ cstdmf/         : timestamp, date_time_utils, string_builder, command_line,
   │                    guard, concurrency, debug_message_callbacks
   ├─ resmgr/         : BWResource, DataResource, DataSection, XMLSection,
   │                    MultiFileSystem, AutoConfig, data_section_census
   └─ (隐式) converters/* : 通过 PluginLoader 运行时加载

   │ 运行时依赖
   └─ resources/report_style.css, resources/report_script.js
      (HTML 报告的样式与脚本,从 BWResource 加载)
```

batch_compiler 与 assetprocessor 的关系:

- batch_compiler **不直接依赖** assetprocessor DLL。
- 但某些 Converter(如 `effect_converter`)可能在 `convert()` 内部 `import _AssetProcessor` 调用 shader 编译——这是通过 Python 间接耦合,而非 C++ 链接。

batch_compiler 与 jit_compiler 的关系:

- 两者都派生自 AssetCompiler,共享编译内核。
- batch_compiler 是"一次性 + 多线程队列",jit_compiler 是"常驻 + 递归 + 反向依赖图"。
- 两者不能同时运行在同一资源路径(asset_pipeline 的单实例互斥锁会阻止)。

---

## 九、关键代码片段

### 9.1 构造函数初始化

`batch_compiler.cpp:55-70`:

```cpp
55→BatchCompiler::BatchCompiler()
56→: AssetCompiler()
57→, totalDuration_( 0 )
58→, cacheReadCount_( 0 )
59→, cacheReadMissCount_( 0 )
60·, cacheWriteCount_( 0 )
61·, cacheWriteMissCount_( 0 )
62·, filesIterated_( 0 )
63·, directoriesIterated_( 0 )
64·, taskCount_( 0 )
65·, taskFailedCount_( 0 )
66·, taskUpToDateCount_( 0 )
67·, taskSkippedCount_( 0 )
68→{
69·	addToolsResourcePaths();      # 添加 tools/ 资源路径,确保能找到 report_style.css 等
70→}
```

`addToolsResourcePaths()` 是 AssetCompiler 的方法,把 `tools/` 目录加入 BWResource 路径,确保后续 `BWResource::openSection("resources/report_style.css")` 能找到文件。

### 9.2 shouldIterateFile/Directory 统计

`batch_compiler.cpp:495-515`:

```cpp
495→bool BatchCompiler::shouldIterateFile( const StringRef & file )
496→{
497·	if (!AssetCompiler::shouldIterateFile( file ))
498·		return false;
500·	++filesIterated_;
501·	return true;
502→}
504→bool BatchCompiler::shouldIterateDirectory( const StringRef & directory )
505→{
506·	BW_GUARD;
508·	if (!AssetCompiler::shouldIterateDirectory( directory ))
509·		return false;
511·	++directoriesIterated_;
513→	return true;
514→}
```

通过重写 `shouldIterateFile/Directory` 并调基类,batch_compiler 在不改变过滤逻辑的前提下完成了统计——这是个干净的开闭原则应用。

### 9.3 onOutputGenerated / onCacheRead 等回调

`batch_compiler.cpp:629-674`:

```cpp
629→void BatchCompiler::onOutputGenerated( const BW::string & filename )
630→{
633·	s_currentTaskRecord->outputs_.push_back( filename );    # 记录输出文件
637·	AssetCompiler::onOutputGenerated( filename );
638→}
640→void BatchCompiler::onCacheRead( const BW::string & filename )
641→{
644·	InterlockedIncrement( &cacheReadCount_ );               # 原子递增缓存统计
647·	AssetCompiler::onCacheRead( filename );
648→}
649→void BatchCompiler::onCacheReadMiss( const BW::string & filename )
650→{
653·	InterlockedIncrement( &cacheReadMissCount_ );
655·	AssetCompiler::onCacheReadMiss( filename );
656→}
658→void BatchCompiler::onCacheWrite( const BW::string & filename )
659→{
662·	InterlockedIncrement( &cacheWriteCount_ );
665·	AssetCompiler::onCacheWrite( filename );
666·}
667→void BatchCompiler::onCacheWriteMiss( const BW::string & filename )
668→{
671·	InterlockedIncrement( &cacheWriteMissCount_ );
674·	AssetCompiler::onCacheWriteMiss( filename );
675→}
```

所有缓存统计都用 `InterlockedIncrement` 保证多线程安全。注意每个回调最后都调基类实现——确保 asset_pipeline 的内部状态(如 `s_Converting` 等)被正确维护。

### 9.4 HTML helper 函数

`batch_compiler.cpp:408-510`(部分):

```cpp
408→DataSectionPtr BatchCompiler::writeSection( DataSectionPtr pDataSection, const StringRef & id, const StringRef & classType )
409→{
410·	DataSectionPtr pSection = pDataSection->newSection( "div" );
411·	if (id.length()) pSection->setString( "id", id );      # id 属性
412·	if (classType.length()) pSection->setString( "class", classType );  # class 属性
413·	return pSection;
414→}
426→DataSectionPtr BatchCompiler::writeText( DataSectionPtr pDataSection, const StringRef & text, const StringRef & style )
427→{
428·	DataSectionPtr pSection = pDataSection->newSection( "div" );
429·	if (style.length()) pSection->setString( "style", style );
430·	pSection->setString( text );
431·	return pSection;
432→}
435→DataSectionPtr BatchCompiler::writeLink( DataSectionPtr pDataSection, const StringRef & link, const StringRef & text, const StringRef & style )
436→{
437·	DataSectionPtr pSection = pDataSection->newSection( "a" );
438·	pSection->setString( "href", link );
439·	if (style.length()) pSection->setString( "style", style );
440·	if (text.length()) pSection->setString( text );
441·	return pSection;
442→}
```

这些 helper 把 HTML DOM 构造封装为简单的 `writeSection/writeText/writeLink` 调用,让 `outputReport` 的代码接近声明式——读起来就像在描述 HTML 结构。`DataSection` 的 `setString` 重载既能设属性(带 key)又能设文本内容(不带 key),非常灵活。

### 9.5 DllMain 风格的退出清理

`batch_compiler.cpp:970-983`:

```cpp
970·		bc.finiCompiler();        # 停止 BgTaskManager
971·		bc.finiPlugins();         # 卸载 converter DLL
972·        BatchCompiler_Locals::batchCompiler_ = NULL;
974·		retval = bc.getFailedCount();
975·	}
978·	BWResource::fini();
981·	DataSectionCensus::fini();
983·	return retval;
984→}
```

注意 `BWResource::fini()` 与 `DataSectionCensus::fini()` 在 `if` 块外——即使命令行解析失败(L957 返回 false),也要清理 BWResource(它已在 L947 初始化)。这是健壮的资源清理模式。

---

## 十、设计亮点与注意事项

### 10.1 设计亮点

1. **薄前端 + 厚基类**:batch_compiler 只 1100 行就实现了完整的批量编译 + 报告 + Ctrl-C,得益于 asset_pipeline 的良好抽象。新增 CLI 工具的代价极低。
2. **TaskRecord 线程局部 + 全局 map 结合**:`s_currentTaskRecord`(THREADLOCAL)让回调无需加锁,`taskRecords_`(全局 map)在 suspend/resume 时用 mutex 短暂加锁,平衡了性能与一致性。
3. **InterlockedIncrement 统计**:所有计数器(`taskCount_`、`taskFailedCount_` 等)用原子操作,无需锁,多线程下零争用。
4. **HTML 报告单文件**:CSS/JS 内嵌,生成的 `.html` 可直接邮件分享,无需打包资源。
5. **5 分类 + JS 折叠**:Failures/Warnings/Converted/UpToDate/Skipped 分组,`Toggle`/`GoTo` JS 交互,让大报告(数千任务)也易于浏览。
6. **空分组自动删除**:某分类若无任务,对应 `<div>` 会被 `delChild` 移除,保持报告简洁。
7. **两次 Ctrl-C 设计**:第一次优雅终止,第二次强制停止,给用户精确控制权。
8. **退出码 = 失败数**:CI 系统可据此判断严重程度,而非简单的 0/1。
9. **无参数默认编译全部**:`resolveInputPaths` 在 `parsedPaths_` 为空时填入所有 BWResource 路径,`batch_compiler.exe` 无参数即可编译整个项目。
10. **父子路径去重**:`resolveInputPaths` 去除子路径冗余,避免重复扫描。
11. **handleMessage 的 ASSET_PIPELINE_CAPTURE_ASSERTS 开关**:开发时打开捕获 assert 到日志,生产时关闭让其弹窗,灵活适配场景。
12. **日志带 task id 前缀**:`fprintf(stdout, "%d>  %s", taskid, msg)`,多线程日志可读性大幅提升。

### 10.2 注意事项与潜在坑

1. **单实例限制**:同一资源路径只能运行一个 batch_compiler(或 jit_compiler),asset_pipeline 构造期会 `exit(-1)` 弹窗。CI 并行构建需用不同资源路径副本。
2. **退出码上限**:`getFailedCount()` 返回 `long`,但进程退出码在 Windows 上只有 8 位(0-255),失败数超过 255 会被截断。CI 应检查 `> 0` 而非精确值。
3. **Ctrl-C 第二次强制停止的风险**:`BgTaskManager::stopAll(true, false)` 强制终止工作线程,可能导致正在写的 `.deps`/输出文件损坏。仅在确实紧急时使用。
4. **报告路径必须存在**:`BWResource::ensureAbsolutePathExists(reportPath_)` 会创建目录,但如果路径非法(如 `Q:\nonexistent\`),会失败。
5. **report_style.css / report_script.js 必须可访问**:从 `resources/` 路径加载,若 BWResource 路径配置错误,报告会缺少样式与交互(但 HTML 仍能生成)。
6. **handleMessage 的 assert 格式硬编码**:跳过前 3 行、取后 2 行的逻辑假设了 BigWorld assert 消息格式,若 `debug.cpp` 的格式变更,这里会解析错。
7. **TaskRecord 通过 ConversionTask* 索引**:任务指针必须稳定(asset_pipeline 保证 ConversionTask 一旦创建不移动),否则 map 会失效。这限制了 asset_pipeline 不能用 `vector<ConversionTask>`(会 realloc),必须用 `new` 分配。
8. **taskRecords_ 内存增长**:每个任务的 TaskRecord 持续累积,大项目(10万+任务)会占用可观内存。析构时统一释放,但运行中峰值可能高。
9. **多线程日志交织**:虽然带 task id 前缀,但多线程的 `fprintf` 可能交错(stdout 是线程安全的但不是原子的),复杂日志需结合 HTML 报告查看。
10. **`BW_GUARD` 宏**:每个回调开头都有 `BW_GUARD`,这是 BigWorld 的栈跟踪守卫,异常时打印调用栈。开发期必选,发布版可关闭以省性能。
11. **`-recursive` 模式与默认差异**:batch_compiler 默认非递归(用队列重排),适合大批量;`-recursive` 切换到嵌套模式,适合任务量小但依赖深的场景。误用可能导致死锁(asset_pipeline 单线程下的循环依赖)或低效。
12. **`AutoConfig::configureAllFrom("resources.xml")` 失败只警告**:`bw_main` L949-952 在 AutoConfig 失败时只打印 ERROR 但继续执行,可能导致后续 Converter 找不到 shader include 等配置。生产环境应检查 resources.xml 完整性。

### 10.3 与 asset_pipeline 的协作要点

batch_compiler 几乎所有编译行为都由 asset_pipeline 决定,batch_compiler 只通过以下方式介入:

| 介入点 | batch_compiler 行为 | asset_pipeline 默认行为 |
|---|---|---|
| `shouldIterateFile/Directory` | 累加计数后调基类 | 跳过 intermediate/output/.svn |
| `onTaskStarted/Resumed/Suspended/Completed` | 维护 TaskRecord 与统计 | 维护 `s_currentTask`/队列重排 |
| `onPreCreateDependencies/onPreConvert` | 翻转 `skipped_`/`upToDate_` 标志 | (无操作,纯虚或空实现) |
| `onOutputGenerated` | 记录输出文件到 TaskRecord | (空实现) |
| `onCacheRead/Write/...` | 累加缓存统计 | (空实现) |
| `handleMessage` | 重定向到 TaskRecord.log_ + stdout | 设置 `s_error`/`s_warning` 标志 |

batch_compiler **完全不改变编译逻辑**,只观察与记录。这是"开放回调,封闭内核"的设计典范。

---

## 附录:核心文件清单

| 文件 | 行数 | 职责 |
|---|---|---|
| `batch_compiler.hpp` | 112 | BatchCompiler 类声明 + TaskRecord 结构 |
| `batch_compiler.cpp` | 991 | BatchCompiler 实现 + bw_main + ConsoleHandler + BatchCompilerOptions |

---

## 附录:典型运行示例

### 示例 1:CI nightly build

```bash
# 8 线程编译整个项目,生成报告,失败则非零退出
batch_compiler.exe -j 8 -forceRebuild -report nightly.html
if %errorlevel% neq 0 (
    echo Build failed with %errorlevel% errors
    exit /b 1
)
```

### 示例 2:增量构建

```bash
# 只编译过期的(默认行为),不强制重建
batch_compiler.exe -j 4 resources/
```

### 示例 3:单文件调试

```bash
# 编译单个文件,1 线程便于调试
batch_compiler.exe -j 1 resources/objects/hero/body.visual
```

### 示例 4:自定义输出目录

```bash
# 中间文件与最终输出分离
batch_compiler.exe \
    -intermediatePath C:\build\intermediate \
    -outputPath C:\build\output \
    -j 8 \
    resources/
```

### 报告示例(简化的 HTML 结构)

```html
<html>
<head>
<style>...CSS...</style>
<script>...JS...</script>
</head>
<body>
<h1>Batch Compiler 2026-06-30 12:34:56</h1>
<div>batch_compiler.exe -j 8 -report build.html</div>
<div class="Group">
  <div style="font-size:150%;font-weight:bold;">Summary</div>
  <div>Found: 1234 tasks, Searched: 5678 files, 90 directories</div>
  <div>Conversion: 1200 succeeded, 34 failed, 100 converted, 800 up-to-date, 300 skipped</div>
  <div>Cache: 500 Reads, 12 Failed Reads, 100 Writes, 0 Failed Writes</div>
  <div>Total Duration: 123.456789 seconds</div>
  <div class="SubGroup">
    <a href="javascript:Toggle('Failures');">Failures (34)</a>
    <div id="Failures" class="Toggleable">
      <a href="javascript:GoTo('5');">objects/hero/body.visual</a><br/>
      ...
    </div>
  </div>
</div>
<div class="Group">
  <div style="font-size:150%;font-weight:bold;">Tasks</div>
  <div id="1" class="Task">
    <a href="javascript:Toggle('1');">1. objects/foo.visual</a>
    <div class="Toggleable">
      <div>Duration: 0.123s</div>
      <div>Outputs: foo.visual, foo.primitives</div>
      <pre>...log...</pre>
    </div>
  </div>
</div>
</body>
</html>
```

---

> **文档版本**:BigWorld Engine 14.4.1
> **分析对象**:`programming/bigworld/tools/batch_compiler/`
> **行号引用**:本文中所有 `文件:行号` 均基于 14.4.1 源码原始行号。
