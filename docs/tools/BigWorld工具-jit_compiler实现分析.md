# BigWorld 工具 jit_compiler 实现分析

> 本文档详细分析 BigWorld Engine 14.4.1 中 `jit_compiler`(Just-In-Time 资产编译器)的架构与实现。jit_compiler 是一个基于 WTL 的 Windows GUI 守护进程,常驻后台,基于反向依赖图做增量编译,并通过命名管道为游戏客户端提供 JIT 资产服务。它在 asset_pipeline 核心库之上构建了"事件驱动的增量编译 + 跨进程资产服务"两层架构。

---

## 目录

- [一、概述与定位](#一概述与定位)
- [二、整体架构](#二整体架构)
- [三、目录结构](#三目录结构)
- [四、入口点与启动流程](#四入口点与启动流程)
- [五、核心类与继承关系](#五核心类与继承关系)
  - [5.1 JITCompiler 多重继承](#51-jitcompiler-多重继承)
  - [5.2 TaskStore 任务存储](#52-taskstore-任务存储)
  - [5.3 TaskInfo 与 TaskInfoState](#53-taskinfo-与-taskinfostate)
  - [5.4 MainWindow 与 SystemTrayIcon](#54-mainwindow-与-systemtrayicon)
  - [5.5 MainMessageLoop 跨线程调度](#55-mainmessageloop-跨线程调度)
- [六、关键算法与数据结构](#六关键算法与数据结构)
  - [6.1 双线程架构](#61-双线程架构)
  - [6.2 反向依赖图](#62-反向依赖图)
  - [6.3 命名管道 IPC](#63-命名管道-ipc)
  - [6.4 文件变更监听](#64-文件变更监听)
  - [6.5 增量编译流程](#65-增量编译流程)
  - [6.6 目录依赖正则匹配](#66-目录依赖正则匹配)
  - [6.7 TaskStore 信号槽机制](#67-taskstore-信号槽机制)
- [七、配置项与命令行参数](#七配置项与命令行参数)
- [八、与其他模块的依赖关系](#八与其他模块的依赖关系)
- [九、关键代码片段](#九关键代码片段)
- [十、设计亮点与注意事项](#十设计亮点与注意事项)
- [附录 A:核心文件清单](#附录-a核心文件清单)
- [附录 B:典型运行时序](#附录-b典型运行时序)

---

## 一、概述与定位

`jit_compiler` 是 BigWorld Engine 工具链中的**实时资产编译守护进程**,代码量约 3000 行(含 GUI),其本质是一个"按需编译 + 文件监听 + 跨进程服务"三位一体的增量构建系统。

与 `batch_compiler` 一次性扫盘编译不同,jit_compiler 是**常驻后台**的:

| 维度 | batch_compiler | jit_compiler |
|------|---------------|--------------|
| 运行模式 | 一次性 CLI 批处理 | 常驻 GUI 守护进程 |
| 编译触发 | 启动时全量扫描 | 文件变更 + 客户端请求 |
| 依赖管理 | 正向依赖(DAG 调度) | **反向依赖图**(变更→受影响任务) |
| IPC | 无 | 命名管道(与游戏客户端) |
| UI | 无(纯控制台) | WTL 对话框 + 系统托盘 |
| 线程模型 | 多线程工作池 | 双线程(扫描 + 管理) + 工作池 |
| 输出 | HTML 报告 | 实时任务列表 + 气泡通知 |

jit_compiler 的核心职责:

1. **资产发现(Scanning)**:启动时扫描所有资源路径,建立"源文件 → ConversionTask"的映射。
2. **反向依赖图(Reverse Dependency Graph)**:每个任务完成后,记录其 primary/secondary inputs 和 outputs 的反向映射,当某文件变更时,能快速找出所有受影响的任务。
3. **文件变更监听(File Modification Monitor)**:通过 `BWResource::enableModificationMonitor` 监听资源路径下的文件变更,触发增量重建。
4. **JIT 资产服务(Asset Server)**:通过命名管道响应游戏客户端的资产请求,把客户端需要的资产"即时编译"出来并广播。
5. **GUI 反馈**:WTL 主窗口 + 系统托盘图标,实时显示 requested/current/completed 任务列表,带气泡通知。

---

## 二、整体架构

jit_compiler 采用**四层架构**:GUI 层 → 协调层 → 资产编译层 → IPC 层。

```
┌─────────────────────────────────────────────────────────────────────┐
│                       GUI 层 (WTL)                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌─────────────────────────┐    │
│  │ MainWindow   │  │ SystemTray   │  │ DetailsDialog /         │    │
│  │ (主对话框)    │  │ Icon(托盘)   │  │ OptionsDialog / About   │    │
│  └──────┬───────┘  └──────────────┘  └─────────────────────────┘    │
│         │                                                            │
│         ▼                                                            │
│  ┌──────────────┐  ┌──────────────┐                                 │
│  │ MainMessage  │  │ TaskListBox  │  (requested/current/completed) │
│  │ Loop(消息循环)│  │ × 3         │                                 │
│  └──────┬───────┘  └──────────────┘                                 │
└─────────┼───────────────────────────────────────────────────────────┘
          │  Signal/Callback
          ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    协调层 (TaskStore)                                │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  requestedTasks_ / currentTasks_ / completedTasks_ / allTasks_│  │
│  │  + Signal<TaskCallbackSignature> × 3(信号槽)                 │   │
│  └──────────────────────────────────────────────────────────────┘   │
└─────────┬───────────────────────────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────────────────────────────────────┐
│              资产编译层 (JITCompiler : AssetCompiler)                │
│  ┌────────────────┐  ┌────────────────┐  ┌──────────────────────┐   │
│  │ Scanning Thread│  │ Managing Thread│  │ Worker Threads (池)  │   │
│  │ (扫描资源)      │  │ (驱动处理循环) │  │ (实际 Converter 执行)│   │
│  └────────────────┘  └────────────────┘  └──────────────────────┘   │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  ReverseDependencyMap + ForwardDependencyMap(反向依赖图)     │   │
│  └──────────────────────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  ResourceModificationListener(文件变更监听)                  │   │
│  └──────────────────────────────────────────────────────────────┘   │
└─────────┬───────────────────────────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────────────────────────────────────┐
│                IPC 层 (JITCompiler : AssetServer)                    │
│  ┌────────────────┐  ┌────────────────┐  ┌──────────────────────┐   │
│  │ Named Pipe     │  │ Pipe Threads   │  │ Command Mutex        │   │
│  │ (双向命名管道)  │  │ (每客户端一线程)│  │ (跨进程互斥)         │   │
│  └────────────────┘  └────────────────┘  └──────────────────────┘   │
│           │                                                         │
│           ▼                                                         │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  游戏客户端(Client)通过 AssetPipe 连接,请求资产              │   │
│  └──────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

**关键设计点**:

- JITCompiler 通过**多重继承**同时扮演"资产编译器"、"IPC 服务器"、"文件监听器"三个角色。
- GUI 线程与编译线程**完全解耦**,通过 TaskStore 的信号槽机制通信。
- 反向依赖图是 jit_compiler 区别于 batch_compiler 的**核心创新**,实现了 O(1) 的变更影响范围查找。

---

## 三、目录结构

jit_compiler 位于 `programming/bigworld/tools/jit_compiler/`,目录结构如下:

```
jit_compiler/
├── CMakeLists.txt                  # CMake 构建配置
├── app.rc                          # Windows 资源文件(对话框/图标定义)
├── resource.h                      # 资源 ID 定义
├── jit.ico                         # 普通托盘图标
├── jit_error.ico                   # 错误托盘图标
├── jit_warning.ico                 # 警告托盘图标
│
├── main.cpp                        # WinMain 入口
├── jit_compiler.hpp                # JITCompiler 类声明(核心)
├── jit_compiler.cpp                # JITCompiler 类实现(核心)
├── jit_compiler_options.hpp        # JitCompilerOptions(扩展 AssetCompilerOptions)
├── jit_compiler_options.cpp
│
├── task_store.hpp                  # TaskStore 任务存储
├── task_store.cpp
├── task_info.hpp                   # TaskInfo 单任务信息
├── task_info.cpp
├── task_fwd.hpp                    # 前向声明 + TaskInfoState 枚举
│
├── main_window.hpp                 # MainWindow 主对话框
├── main_window.cpp
├── message_loop.hpp                # MainMessageLoop 消息循环
├── message_loop.cpp
├── signal.hpp                      # Signal 信号槽实现
├── signal.cpp
│
├── system_tray_icon.hpp            # SystemTrayIcon 系统托盘
├── system_tray_icon.cpp
├── task_list_box.hpp               # TaskListBox 任务列表控件
├── task_list_box.cpp
├── task_list_box_base.hpp          # TaskListBoxBase 基类
├── task_list_box_base.cpp
├── large_task_list_box.hpp         # LargeTaskListBox 大任务列表
├── large_task_list_box.cpp
│
├── about_dialog.hpp                # AboutDialog 关于对话框
├── about_dialog.cpp
├── config_dialog.hpp               # ConfigDialog 配置对话框
├── config_dialog.cpp
├── details_dialog.hpp              # DetailsDialog 任务详情对话框
├── details_dialog.cpp
├── options_dialog.hpp              # OptionsDialog 选项对话框
├── options_dialog.cpp
│
├── wtl.hpp                         # WTL 头文件统一包含
│
└── res/                            # 资源子目录
    └── original/                   # 原始图标素材(PNG,多尺寸)
        ├── jit_shortcut_48.png
        ├── jit_shortcut_red_48.png
        ├── jit_shortcut_yellow_48.png
        ├── jit_systemtray_16.png
        ├── jit_systemtray_red_16.png
        ├── jit_systemtray_yellow_16.png
        ├── jit_taskbar_32.png
        ├── jit_taskbar_red_32.png
        └── jit_taskbar_yellow_32.png
```

**文件分类**:

| 分类 | 文件数 | 说明 |
|------|--------|------|
| 核心编译逻辑 | 4 | jit_compiler.hpp/cpp + options |
| 任务存储与信息 | 6 | task_store + task_info + task_fwd |
| GUI 主框架 | 4 | main_window + message_loop + main.cpp |
| GUI 控件 | 6 | task_list_box × 3 + system_tray_icon |
| 对话框 | 8 | about + config + details + options |
| 信号机制 | 2 | signal.hpp/cpp |
| 资源 | 1 + res/ | app.rc + 图标 |

---

## 四、入口点与启动流程

jit_compiler 是 Windows GUI 程序,入口点为 `WinMain`(位于 `main.cpp` L50-102)。

### 4.1 WinMain 主流程

```cpp
// main.cpp L50-102
int WINAPI WinMain( HINSTANCE instance, HINSTANCE prevInstance, 
                    LPSTR commandLine, int showCmd )
{
    BW_SYSTEMSTAGE_MAIN();
#ifdef ENABLE_MEMTRACKER
    MemTracker::instance().setCrashOnLeak( true );
#endif

    int exitCode = 1;
    if (init())                          // 1. 初始化文件系统 + 通用控件
    {
        BW::AssetCompilerOptions options;
        options.parseCommandLine( BW::bw_wtoutf8( GetCommandLineW() ) );

        BW::TaskStore store;             // 2. 创建任务存储
        BW::MainMessageLoop messageLoop; // 3. 创建消息循环
        BW::JITCompiler jitCompiler(store);
        BW::MainWindow mainWindow(store, messageLoop, jitCompiler, jitCompiler);
        options.apply(jitCompiler);      // 4. 应用命令行选项
        jitCompiler.initPlugins();       // 5. 加载 Converter 插件
        jitCompiler.initCompiler();      // 6. 初始化编译器

        if (mainWindow.init())           // 7. 初始化主窗口
        {
            // 8. 启动扫描线程
            BW::SimpleThread jitScanningThread(scanningThreadFunc, 
                &jitCompiler, "JITCompiler Scanning Thread");
            // 9. 启动管理线程
            BW::SimpleThread jitManagingThread(managingThreadFunc, 
                &jitCompiler, "JITCompiler Process Thread");

            exitCode = messageLoop.run(); // 10. 进入消息循环(阻塞)

            jitCompiler.stop();           // 11. 退出时停止
        }

        mainWindow.fini();
        jitCompiler.finiCompiler();
        jitCompiler.finiPlugins();
    }

    fini();
    return exitCode;
}
```

### 4.2 init() 初始化函数

```cpp
// main.cpp L22-34
bool init()
{
    WTL::AtlInitCommonControls(ICC_COOL_CLASSES | ICC_BAR_CLASSES);

    // Initialise the file systems
    if (!BW::BWResource::init( BW::BWResource::appDirectory(), false ))
    {
        return false;
    }
    BW::BWResource::instance().enableModificationMonitor( true ); 
    // 启用文件修改监听,jit_compiler 的核心能力之一

    return true;
}
```

### 4.3 启动时序图

```
WinMain
  │
  ├─► init()
  │     ├─► AtlInitCommonControls  (WTL 通用控件)
  │     ├─► BWResource::init       (初始化文件系统)
  │     └─► enableModificationMonitor(true)  (开启文件监听)
  │
  ├─► AssetCompilerOptions::parseCommandLine  (解析命令行)
  │
  ├─► new TaskStore
  ├─► new MainMessageLoop
  ├─► new JITCompiler(store)        (构造时注册 ResourceModificationListener)
  ├─► new MainWindow(store, loop, compiler, loader)
  │
  ├─► options.apply(jitCompiler)    (应用 intermediatePath/outputPath/cachePath 等)
  ├─► jitCompiler.initPlugins()     (从 plugins 目录加载 .dll Converter)
  ├─► jitCompiler.initCompiler()    (初始化 TaskFinder/TaskProcessor/线程池)
  │
  ├─► mainWindow.init()             (创建对话框、托盘图标、绑定信号)
  │
  ├─► 启动 scanningThread           ──► scanningThreadMain()
  ├─► 启动 managingThread           ──► managingThreadMain()
  │
  ├─► messageLoop.run()             (主线程进入 Windows 消息循环,阻塞)
  │
  └─► (退出时) jitCompiler.stop() → terminate() → event_.set()
```

### 4.4 关键点说明

1. **命令行复用 AssetCompilerOptions**:jit_compiler 直接使用 `AssetCompilerOptions`(非 JitCompilerOptions)解析命令行,共享 `intermediatePath`/`outputPath`/`cachePath`/`j`/`forceRebuild`/`recursive` 等参数。
2. **MainWindow 构造参数**:`MainWindow(store, loop, compiler, loader)`,其中 `compiler` 和 `loader` 都是 `jitCompiler`(因为 JITCompiler 同时继承 AssetCompiler 和 PluginLoader)。
3. **双线程在 mainWindow.init() 成功后才启动**:确保 GUI 就绪后再开始扫描。
4. **消息循环阻塞主线程**:扫描和管理线程在后台 SimpleThread 中运行,通过 TaskStore 信号槽触发 UI 更新。

---

## 五、核心类与继承关系

### 5.1 JITCompiler 多重继承

JITCompiler 是 jit_compiler 的**核心类**,通过多重继承同时承担四个角色:

```cpp
// jit_compiler.hpp L13-17
class JITCompiler : public AssetCompiler
                  , public AssetServer
                  , public ResourceModificationListener
                  , public PluginLoader
{
    // ...
};
```

**继承关系图**:

```
        ┌─────────────────┐
        │   Compiler      │ (抽象基类)
        │   (private ctor)│
        └────────┬────────┘
                 │ friend
                 ▼
        ┌─────────────────┐
        │ AssetCompiler   │ (实现基类:状态机/依赖/缓存/多线程)
        └────────┬────────┘
                 │
   ┌─────────────┼──────────────┬─────────────────────┐
   │             │              │                     │
   ▼             ▼              ▼                     ▼
┌──────┐  ┌────────────┐  ┌──────────────────┐  ┌──────────────┐
│Asset │  │ResourceMod │  │PluginLoader      │  │AssetServer   │
│Server│  │ificationLis│  │(加载 .dll 插件)  │  │(命名管道 IPC)│
│      │  │tener       │  │                  │  │              │
└──┬───┘  └─────┬──────┘  └────────┬─────────┘  └──────┬───────┘
   │            │                  │                   │
   └────────────┴──────────────────┼───────────────────┘
                                    │
                                    ▼
                          ┌──────────────────┐
                          │   JITCompiler    │
                          │ (四重继承,核心)  │
                          └──────────────────┘
```

**四个角色的职责**:

| 基类 | 角色 | 关键方法 |
|------|------|----------|
| `AssetCompiler` | 资产编译器 | `ensureCompiled()`, `queueTask()`, `pause()/resume()` |
| `AssetServer` | IPC 服务器 | `broadcastAsset()`, `onAssetRequested()`(纯虚,由 JITCompiler 实现) |
| `ResourceModificationListener` | 文件监听器 | `onResourceModified()`(文件变更回调) |
| `PluginLoader` | 插件加载器 | `initPlugins()`, `finiPlugins()` |

### 5.2 JITCompiler 成员变量

```cpp
// jit_compiler.hpp L77-96
private:
    static THREADLOCAL( ConversionTask * ) st_currentTask_;  // 当前线程正在处理的任务

    SimpleMutex requestMutex_;                               // 保护 requests_
    BW::vector<std::pair<ConversionTask *, BW::string>> requests_;  // 待广播的资产请求

    SimpleEvent event_;                                      // 唤醒管理线程的事件

    // 反向依赖图核心数据结构
    typedef BW::vector<BW::string> DirectoryDependencies;
    typedef BW::vector<std::pair<ConversionTask *, bool>> ReverseDependencies;
    typedef StringHashMap<ReverseDependencies> ReverseDependencyMap;
    typedef BW::vector<StringRef> ForwardDependencies;
    typedef BW::map<ConversionTask*, ForwardDependencies> ForwardDependencyMap;
    
    DirectoryDependencies directoryDependencies_;            // 目录依赖列表(去重)
    ReverseDependencyMap reverseDependencyMap_;              // 文件 → 依赖它的任务列表
    ForwardDependencyMap forwardDependencyMap_;              // 任务 → 它依赖的文件列表

    TaskStore & store_;                                      // 任务存储引用
```

**关键数据结构解释**:

- `reverseDependencyMap_`:`文件路径 → [(任务, 是否为输出), ...]`。当某文件变更时,查此表即可找出所有受影响任务。
- `forwardDependencyMap_`:`任务 → [文件路径, ...]`。用于任务重新入队时清理旧的反向依赖。
- `directoryDependencies_`:目录依赖的字符串列表,格式 `"目录>模式>是否正则>是否递归"`,用于目录依赖的正则匹配。
- `requests_`:`[(任务, 资产路径), ...]`。客户端请求的资产,任务完成后需广播。
- `st_currentTask_`:线程局部变量,记录当前线程正在处理的任务,用于日志归因。

### 5.3 TaskStore 任务存储

TaskStore 是 JITCompiler 与 GUI 之间的**中介者**,管理任务的三态列表与信号通知。

```cpp
// task_store.hpp L24-92
class TaskStore
{
public:
    typedef std::function<void ()> CallbackFunction;
    typedef void TaskCallbackSignature(TaskInfoPtr, TaskStoreAction);
    typedef std::function<TaskCallbackSignature> TaskCallbackFunction;

    // JIT Compiler 接口
    void scanningStarted();
    void scanningStopped();
    void resetTask(ConversionTask * task);
    void addRequestedTask(ConversionTask * task);
    void setTaskCurrent(ConversionTask * task);
    void setTaskComplete(ConversionTask * task);
    void setCurrentTaskState(ConversionTask * task, TaskInfoState state);
    bool handleTaskMessage(ConversionTask * task, ...);
    void appendLogToTask(ConversionTask * task, BW::WStringRef message);
    void addOutputToTask(ConversionTask * task, const BW::StringRef & output);

    // UI 接口
    void setStatusCallbacks(CallbackFunction scanningStartedCallback, 
                            CallbackFunction scanningStoppedCallback);
    Connection registerRequestedTaskCallback(TaskCallbackFunction callback);
    Connection registerCurrentTaskCallback(TaskCallbackFunction callback);
    Connection registerCompletedTaskCallback(TaskCallbackFunction callback);

private:
    typedef BW::map<const ConversionTask *, TaskInfoPtr> ConversionTaskMap;

    SimpleMutex requestedGuard_;
    SimpleMutex currentGuard_;
    mutable SimpleMutex allTasksGuard_;

    ConversionTaskMap requestedTasks_;    // 请求队列(等待处理)
    ConversionTaskMap currentTasks_;      // 当前处理中
    ConversionTaskMap completedTasks_;    // 已完成
    ConversionTaskMap allTasks_;          // 所有任务(去重)

    TaskSignal requestedSignal_;          // 信号:新请求加入
    TaskSignal currentSignal_;            // 信号:任务开始处理
    TaskSignal completedSignal_;          // 信号:任务完成

    int failedCount_;
    int warningCount_;
};
```

**任务三态列表**:

| 列表 | 含义 | 触发时机 |
|------|------|----------|
| `requestedTasks_` | 已请求但未开始处理的任务 | `onAssetRequested` 或 `onResourceModified` 入队后 |
| `currentTasks_` | 正在处理的任务 | `onTaskStarted`/`onTaskResumed` |
| `completedTasks_` | 已完成的任务(成功/失败/警告) | `onTaskCompleted` |
| `allTasks_` | 所有任务的并集(用于查找) | 上述任一时刻 |

**信号槽机制**:TaskStore 维护三个 Signal,UI 通过 `register*Callback` 订阅,任务状态变化时自动通知 UI 更新列表。

### 5.4 TaskInfo 与 TaskInfoState

TaskInfo 是单个任务在 UI 层的**表示对象**,包装了 ConversionTask 并附加日志、输出、子任务等 UI 信息。

```cpp
// task_fwd.hpp L11-27
enum TaskInfoState
{
    NONE,                       // 无状态(已完成或未开始)
    CHECKING,                   // 检查中(哈希校验是否需要重建)
    GENERATING_DEPENDENCIES,    // 生成依赖中
    CONVERTING,                 // 转换中
};

enum TaskStoreAction
{
    ADDED,
    REMOVED
};
```

```cpp
// task_info.hpp L18-114
class TaskInfo : public std::enable_shared_from_this<TaskInfo>
{
public:
    enum LogDetailLevel
    {
        LOG_DETAIL_ALL,
        LOG_DETAIL_ERRORS,
        LOG_DETAIL_WARNINGS
    };

    enum Result
    {
        RESULT_SUCCESS,
        RESULT_WARNING,
        RESULT_ERROR,
    };

    // 状态、日志、输出、子任务管理
    void setState(TaskInfoState state);
    void appendToLog(const BW::WStringRef & message);
    void addOutput(const BW::StringRef & output);
    void addSubTask(TaskInfoPtr subTask);
    void setErrors();
    void setWarnings();

    Result getResult() const;
    BW::wstring getFormattedName() const;
    BW::wstring getFormattedLog( LogDetailLevel detailLevel ) const;
    BW::wstring getTextDump() const;

private:
    const ConversionTask * task_;
    BW::vector< TaskInfoPtr > subTasks_;
    TaskInfoState state_;
    BW::wstring log_;                    // 累积的日志文本
    BW::vector< BW::string > outputs_;   // 生成的输出文件
    bool hasError_;
    bool hasWarning_;
    Signal<CallbackSignature> changedSignal_;  // 变更通知信号
};
```

### 5.5 MainWindow 与 SystemTrayIcon

MainWindow 是 WTL 主对话框,继承 `CDialogImpl` 和 `CDialogResize`(支持拖拽缩放):

```cpp
// main_window.hpp L28-57
class MainWindow : 
    public ATL::CDialogImpl<MainWindow>,
    public WTL::CDialogResize<MainWindow>
{
public:
    enum { IDD = IDR_MAIN_DIALOG };

    MainWindow(TaskStore & store, MainMessageLoop & loop, 
        AssetCompiler & compiler, const PluginLoader & loader);

    BEGIN_MSG_MAP_EX(MainWindow)
        MSG_WM_INITDIALOG(onInitDialog)
        MSG_WM_CLOSE(onClose)
        MSG_WM_DESTROY(onDestroy)
        COMMAND_CODE_HANDLER_EX(BN_CLICKED, onButtonClicked)
        COMMAND_ID_HANDLER_EX(ID_FILE_CLOSE, onMenuClose)
        COMMAND_ID_HANDLER_EX(ID_SHOW_MAIN_WINDOW, onShowMainWindow)
        COMMAND_ID_HANDLER_EX(ID_FILE_OPTIONS, onMenuOptions)
        COMMAND_ID_HANDLER_EX(ID_FILE_QUIT, onMenuQuit)
        COMMAND_ID_HANDLER_EX(ID_HELP_CONFIG, onConfig)
        COMMAND_ID_HANDLER_EX(ID_APP_ABOUT, onAbout)
        COMMAND_HANDLER_EX(IDC_COMPLETED_SORT_COMBO, CBN_SELCHANGE, onSortSelChange)
        CHAIN_MSG_MAP_MEMBER(trayIcon_)
        CHAIN_MSG_MAP(WTL::CDialogResize<MainWindow>)
        REFLECT_NOTIFICATIONS()
    END_MSG_MAP()
    // ...
};
```

**MainWindow 成员**:

```cpp
// main_window.hpp L96-122
private:
    TaskStore & store_;
    MainMessageLoop & messageLoop_;
    AssetCompiler & compiler_;
    const PluginLoader & loader_;

    std::vector<Connection> connections_;     // 信号槽连接(用于析构时断开)

    TaskListBox requestedList_;               // 请求列表控件
    TaskListBox currentList_;                 // 当前任务列表控件
    LargeTaskListBox completedList_;          // 完成任务列表控件(带排序)
    WTL::CStatic statusText_;                 // 状态栏
    WTL::CButton normalTasksToggle_;          // "正常"过滤按钮
    WTL::CButton warningTasksToggle_;         // "警告"过滤按钮
    WTL::CButton errorTasksToggle_;           // "错误"过滤按钮
    WTL::CComboBox sortOption_;               // 排序下拉框

    WTL::CToolTipCtrl tooltip_;

    WTL::CIcon iconNormal_;                   // 正常态图标
    WTL::CIcon iconWarnings_;                 // 警告态图标
    WTL::CIcon iconErrors_;                   // 错误态图标

    SystemTrayIcon trayIcon_;                 // 系统托盘图标
    int lastFailedCount_;
    int lastWarningCount_;
    bool showBalloonNotifications_;
```

**SystemTrayIcon** 提供三种状态图标 + 气泡通知:

```cpp
// system_tray_icon.hpp L11-54
class SystemTrayIcon
{
public:
    enum BalloonType
    {
        BALLOON_NORMAL,
        BALLOON_WARNING,
        BALLOON_ERROR
    };

    void setNormal();
    void setError();
    void setWarning();
    void showBalloonPopup(const BW::WStringRef & title, 
                          const BW::WStringRef & text, BalloonType type);
    // ...
};
```

### 5.6 MainMessageLoop 跨线程调度

MainMessageLoop 包装 Windows 消息循环,并提供**跨线程 Action 队列**,让工作线程能安全地在 UI 线程执行代码:

```cpp
// message_loop.hpp L12-31
class MainMessageLoop
{
public:
    typedef std::function<void ()> Action;

    int run();                    // 进入消息循环(主线程调用)
    void addAction(Action action); // 跨线程投递 Action

private:
    void processActions();        // 处理队列中的 Action

    std::queue<Action> queue_;
    BW::SimpleMutex guard_;
};
```

**用途**:TaskStore 的信号回调是在工作线程触发的,直接操作 UI 控件不安全。通过 `messageLoop_.addAction([...]() { /* UI 操作 */ })` 把操作投递到 UI 线程执行。

### 5.7 类关系总览

```
┌─────────────────────────────────────────────────────────────────┐
│                         main.cpp (WinMain)                      │
└────────────┬───────────────┬──────────────┬────────────────────┘
             │               │              │
             ▼               ▼              ▼
      ┌────────────┐  ┌────────────┐  ┌──────────────┐
      │ TaskStore  │  │ MainMessage│  │ JITCompiler  │
      │            │  │ Loop       │  │ (四重继承)   │
      │ 3 lists +  │  │            │  │              │
      │ 3 signals  │  │ Action     │  │ ReverseDep   │
      └─────┬──────┘  │ Queue      │  │ Map +        │
            │         └─────┬──────┘  │ ForwardDep   │
            │               │         │ Map          │
            │ Signal        │         └──────┬───────┘
            │               │                │
            ▼               ▼                ▼
      ┌─────────────────────────────────────────────────┐
      │              MainWindow                        │
      │  (WTL CDialogImpl + CDialogResize)             │
      │                                                │
      │  requestedList_ / currentList_ / completedList_│
      │  SystemTrayIcon trayIcon_                      │
      └─────────────────────────────────────────────────┘
```

---

## 六、关键算法与数据结构

### 6.1 双线程架构

jit_compiler 启动两个后台线程,职责分离:

#### 6.1.1 扫描线程(scanningThreadMain)

```cpp
// jit_compiler.cpp L49-62
void JITCompiler::scanningThreadMain()
{
    store_.scanningStarted();

    // search for tasks in all resource paths
    int numPaths = BWResource::getPathNum();
    for (int i = numPaths; i > 0 && !terminating(); --i)
    {
        BW::string path = BWResource::getPath( i - 1 );
        taskFinder_.findTasks( path );   // 递归扫描,发现任务
    }

    store_.scanningStopped();
}
```

**特点**:
- **逆序扫描**:`for (int i = numPaths; i > 0; --i)`,从最后一个路径扫到第一个。这通常对应"mod 路径优先于 base 路径"的优先级。
- **可终止**:每次循环检查 `terminating()`,支持优雅退出。
- **一次性**:扫描线程只跑一次,结束后通过 `store_.scanningStopped()` 通知 UI。

#### 6.1.2 管理线程(managingThreadMain)

```cpp
// jit_compiler.cpp L64-77
void JITCompiler::managingThreadMain()
{
    // process the discovered tasks, flush the modification monitor and repeat
    while (!terminating())
    {
        event_.wait( 1000 );                          // 等待事件或 1 秒超时
        taskProcessor_.processTasks();                // 处理任务队列

        MF_VERIFY( WaitForSingleObject( taskSemaphore_, INFINITE ) == 
            WAIT_OBJECT_0 );                          // 等待所有工作线程完成
        BWResource::instance().flushModificationMonitor();  // 刷新文件监听
        MF_VERIFY( ReleaseSemaphore( taskSemaphore_, 1, NULL ) );
    }
}
```

**循环逻辑**:
1. `event_.wait(1000)`:等待事件触发(有新任务)或 1 秒超时。超时机制确保即使没事件也能周期性运行。
2. `taskProcessor_.processTasks()`:处理任务队列,派发给工作线程执行。
3. `WaitForSingleObject(taskSemaphore_)`:等待所有工作线程完成当前任务(信号量由 AssetCompiler 管理)。
4. `flushModificationMonitor()`:刷新文件修改监听器,触发 `onResourceModified` 回调。
5. `ReleaseSemaphore`:释放信号量,允许下一轮。

**设计意图**:管理线程是一个"处理 → 等待完成 → 刷新监听 → 再处理"的循环,确保:
- 每轮处理完成后才检查文件变更,避免并发冲突。
- 文件变更触发的新任务会在下一轮 `processTasks()` 中处理。
- `taskSemaphore_` 保证 flush 时没有任务在写文件,避免监听器误报。

#### 6.1.3 线程模型图

```
┌─────────────────────────────────────────────────────────────────┐
│                        主线程(UI)                                │
│  ┌───────────────────────────────────────────────────────┐      │
│  │ MainMessageLoop.run() → Windows 消息循环               │      │
│  │ 处理:对话框事件、托盘点击、定时器、Action 队列          │      │
│  └───────────────────────────────────────────────────────┘      │
└─────────────────────────────────────────────────────────────────┘
       ▲                              ▲
       │ Action 投递                   │ Signal 回调(通过 Action)
       │                              │
┌──────┴──────────┐         ┌────────┴───────────────────────────┐
│ 扫描线程         │         │ 管理线程                            │
│ (一次性)        │         │ (循环)                              │
│                 │         │                                     │
│ taskFinder_     │         │ while (!terminating()) {            │
│   .findTasks()  │         │   event_.wait(1000);                │
│                 │         │   taskProcessor_.processTasks();    │
│                 │         │   WaitForSingleObject(semaphore);   │
│                 │         │   flushModificationMonitor();       │
│                 │         │   ReleaseSemaphore(semaphore);      │
│                 │         │ }                                   │
└─────────────────┘         └─────────────────────────────────────┘
                                              │
                                              │ 派发任务
                                              ▼
                            ┌─────────────────────────────────────┐
                            │ 工作线程池(由 AssetCompiler 管理)  │
                            │ processTasksOnMultipleThreads       │
                            │                                     │
                            │ 线程1: Converter A (THREAD_SAFE)    │
                            │ 线程2: Converter B (THREAD_SAFE)    │
                            │ 线程3: Converter C (非线程安全,串行)│
                            └─────────────────────────────────────┘
```

### 6.2 反向依赖图

反向依赖图是 jit_compiler 的**核心创新**,用于解决"文件变更 → 哪些任务受影响"的快速查找问题。

#### 6.2.1 数据结构

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
|------|---------|------|
| `reverseDependencyMap_` | 文件路径 → [(任务, isOutput)] | 文件变更时查找受影响任务 |
| `forwardDependencyMap_` | 任务 → [文件路径] | 任务重新入队时清理旧的反向依赖 |
| `directoryDependencies_` | ["目录>模式>正则>递归", ...] | 目录依赖的特殊处理(正则匹配) |

`isOutput` 标志的含义:依赖项是任务的**输出**(true)还是**输入**(false)。在 `collectReverseDependencies` 中,若 `includeOutputs=false`,则跳过输出依赖(因为输出文件变更通常是任务自己产生的,不需要重建)。

#### 6.2.2 addReverseDependency 三个重载

**重载 1:基础版本(路径 + isOutput)**

```cpp
// jit_compiler.cpp L94-112
void JITCompiler::addReverseDependency( const BW::string & path,
                                        bool isOutput,
                                        ConversionTask & conversionTask )
{
    ReverseDependencyMap::iterator it = reverseDependencyMap_.find( path );
    if (it == reverseDependencyMap_.end())
    {
        it = reverseDependencyMap_.insert( 
            reverseDependencyMap_.end(), 
            std::make_pair( path, ReverseDependencies() ) );
    }

    ReverseDependencies & reverseDependencies = it->second;
    reverseDependencies.push_back( std::make_pair( &conversionTask, isOutput ) );

    // 同时维护正向映射,用于后续清理
    ForwardDependencies & forwardDependencies = forwardDependencyMap_[&conversionTask];
    forwardDependencies.push_back( it->first );
}
```

**逻辑**:
1. 在 `reverseDependencyMap_` 中查找路径,不存在则插入。
2. 追加 `(任务指针, isOutput)` 到反向列表。
3. 同步更新 `forwardDependencyMap_`,记录任务依赖了此路径。

**重载 2:目录依赖版本**

```cpp
// jit_compiler.cpp L114-131
void JITCompiler::addReverseDependency( const BW::string & directory,
                                        const BW::string & pattern,
                                        bool regex,
                                        bool recursive,
                                        ConversionTask & conversionTask )
{
    // 构造唯一键:"目录>模式>正则标志>递归标志"
    BW::string path = bw_format( "%s>%s>%s>%s", 
        directory.c_str(), pattern.c_str(),
        regex ? "1" : "0", recursive ? "1" : "0" );
    
    // 去重插入 directoryDependencies_
    if (std::find( directoryDependencies_.begin(), directoryDependencies_.end(), path ) ==
        directoryDependencies_.end())
    {
        directoryDependencies_.push_back( path );
    }
    addReverseDependency( path, false, conversionTask );  // 复用重载 1
}
```

**目录依赖的特殊键格式**:`"目录>模式>1/0>1/0"`,例如:
- `"resources/textures/>*.dds>0>1"`:递归匹配 resources/textures/ 下所有 .dds 文件
- `"scripts/.*\.py$>1>0"`:非递归正则匹配 scripts/ 下的 .py 文件(此处 pattern 为正则)

**重载 3:Dependency 类型分发版本**

```cpp
// jit_compiler.cpp L133-197
void JITCompiler::addReverseDependency( const Dependency & dependency, 
                                        ConversionTask & conversionTask )
{
    switch (dependency.getType())
    {
    case SourceFileDependencyType:
        {
            const SourceFileDependency & sourcefileDependency = 
                static_cast< const SourceFileDependency & >( dependency );
            BW::string filename = sourcefileDependency.getFileName();
            resolveSourcePath( filename );        // 解析为绝对路径
            addReverseDependency( filename, false, conversionTask );
        }
        break;

    case IntermediateFileDependencyType:
        {
            const IntermediateFileDependency & intermediatefileDependency = 
                static_cast< const IntermediateFileDependency & >( dependency );
            BW::string filename = intermediatefileDependency.getFileName();
            resolveIntermediatePath( filename );
            addReverseDependency( filename, false, conversionTask );
        }
        break;

    case OutputFileDependencyType:
        {
            const OutputFileDependency & outputfileDependency = 
                static_cast< const OutputFileDependency & >( dependency );
            BW::string filename = outputfileDependency.getFileName();
            resolveOutputPath( filename );
            addReverseDependency( filename, false, conversionTask );
        }
        break;

    case DirectoryDependencyType:
        {
            const DirectoryDependency & directoryDependency = 
                static_cast< const DirectoryDependency & >( dependency );
            BW::string directory = directoryDependency.getDirectory();
            if (directory.empty())
            {
                // 空目录表示所有资源路径
                int numPaths = BWResource::getPathNum();
                for (int i = numPaths; i > 0; --i)
                {
                    addReverseDependency( BWResource::getPath( i - 1 ), 
                                          directoryDependency.getPattern(),
                                          directoryDependency.isRegex(),
                                          directoryDependency.isRecursive(),
                                          conversionTask );
                }
            }
            else
            {
                resolveSourcePath( directory );
                addReverseDependency( directory, 
                                      directoryDependency.getPattern(),
                                      directoryDependency.isRegex(),
                                      directoryDependency.isRecursive(),
                                      conversionTask );
            }
        }
    }
}
```

**分发逻辑**:根据 Dependency 的 4 种类型(SourceFile/IntermediateFile/OutputFile/Directory),分别解析路径并调用对应的重载。

#### 6.2.3 collectReverseDependencies 两个重载

**重载 1:按文件路径收集(清理反向依赖)**

```cpp
// jit_compiler.cpp L244-286
void JITCompiler::collectReverseDependencies( const BW::string & path,
                                              bool includeOutputs,
                                              BW::vector< ConversionTask * > & conversionTasks )
{
    ReverseDependencyMap::iterator it = reverseDependencyMap_.find( path );
    if (it == reverseDependencyMap_.end())
    {
        return;  // 无依赖,直接返回
    }
    
    ReverseDependencies & reverseDependencies = it->second;
    for (size_t i = 0; i < reverseDependencies.size();)
    {
        if (!includeOutputs && reverseDependencies[i].second)
        {
            ++i;
            continue;  // 跳过输出依赖
        }

        // 使用 forwardDependencyMap 清理此任务的所有反向依赖
        // 因为任务即将重新入队,完成后会重新建立反向依赖
        ConversionTask * task = reverseDependencies[i].first;
        ForwardDependencies & forwardDependencies = forwardDependencyMap_[task];
        for ( ForwardDependencies::iterator
            forwardIt = forwardDependencies.begin(); 
            forwardIt != forwardDependencies.end(); ++forwardIt )
        {
            ReverseDependencies & tasks = reverseDependencyMap_[forwardIt->to_string()];
            ReverseDependencies::iterator taskIt;
            for (taskIt = tasks.begin(); taskIt != tasks.end(); ++taskIt)
            {
                if (taskIt->first == task)
                    break;
            }
            MF_ASSERT( taskIt != tasks.end() );
            tasks.erase( taskIt );  // 从其他反向列表中移除此任务
        }
        forwardDependencies.clear();  // 清空正向列表

        conversionTasks.push_back( task );
    }
}
```

**关键逻辑**:收集任务时**同步清理双向映射**,因为任务重新入队后,`onTaskCompleted` 会重建反向依赖。这避免了旧依赖残留。

**重载 2:按目录模式收集(正则匹配)**

```cpp
// jit_compiler.cpp L199-242
void JITCompiler::collectReverseDependencies( const BW::string & path, 
                                              const BW::StringRef & file, 
                                              BW::vector< ConversionTask * > & conversionTasks )
{
    for (DirectoryDependencies::iterator it = directoryDependencies_.begin();
        it != directoryDependencies_.end(); )
    {
        // 解析目录依赖字符串:"目录>模式>正则>递归"
        typedef BW::vector< BW::StringRef > StringArray;
        StringArray tokens;
        bw_tokenise( *it, ">", tokens );
        MF_ASSERT( tokens.size() == 4 );

        BW::string directory = tokens[0] + "/";
        StringRef pattern = tokens[1];
        bool regex = (tokens[2] == "1");
        bool recursive = (tokens[3] == "1");

        // 路径匹配检查
        if (( !recursive && path == directory ) ||
            ( recursive && path.substr( 0, directory.length() ) == directory))
        {
            if (regex)
            {
                // 正则匹配(使用 RE2 库)
                if (RE2::FullMatch( re2::StringPiece( file.data(), 
                                    static_cast< int >( file.length() ) ),
                    re2::StringPiece( pattern.data(), 
                                    static_cast< int >( pattern.length() ) ) ))
                {
                    collectReverseDependencies( *it, false, conversionTasks );
                    it = directoryDependencies_.erase( it );  // 匹配后移除
                    continue;
                }
            }
            else
            {
                // 精确匹配
                if (file == pattern)
                {
                    collectReverseDependencies( *it, false, conversionTasks );
                    it = directoryDependencies_.erase( it );
                    continue;
                }
            }
        }

        ++it;
    }
}
```

**目录依赖匹配流程**:
1. 遍历所有 `directoryDependencies_`。
2. 解析 `"目录>模式>正则>递归"` 字符串为 4 个 token。
3. 检查变更文件的路径是否在目录下(递归或非递归)。
4. 若在目录下,检查文件名是否匹配模式(正则或精确)。
5. 匹配成功则收集依赖此目录的所有任务,并从 `directoryDependencies_` 移除(一次性匹配)。

**注意**:目录依赖匹配后会**从列表移除**,这是因为目录依赖是"通配符"性质,一旦匹配即收集所有相关任务,无需保留。但任务完成后会通过 `onTaskCompleted` 重新建立目录依赖。

#### 6.2.4 反向依赖图工作流程

```
任务 T1 完成(onTaskCompleted)
  │
  ├─► 读取 .deps 文件,获取 primaryInputs/secondaryInputs/outputs
  │
  ├─► 对每个 input:
  │     └─► addReverseDependency(input, false, T1)
  │           ├─► reverseDependencyMap_[input] += [(T1, false)]
  │           └─► forwardDependencyMap_[T1] += [input]
  │
  └─► 对每个 output:
        └─► addReverseDependency(output, true, T1)
              ├─► reverseDependencyMap_[output] += [(T1, true)]
              └─► forwardDependencyMap_[T1] += [output]

文件 F 变更(onResourceModified)
  │
  ├─► collectReverseDependencies(F, includeOutputs, tasks)
  │     └─► 查 reverseDependencyMap_[F]
  │         ├─► 跳过 isOutput=true 的项(若 includeOutputs=false)
  │         ├─► 对每个匹配的任务 T:
  │         │     ├─► 用 forwardDependencyMap_[T] 清理 T 在所有反向列表中的引用
  │         │     └─► tasks += T
  │         └─► 返回 tasks
  │
  └─► 对 tasks 中的每个任务:重置状态 → 重新入队

任务 T1 再次完成
  │
  └─► 重新建立反向依赖(覆盖旧数据)
```

### 6.3 命名管道 IPC

jit_compiler 通过 `AssetServer` 提供命名管道 IPC 服务,游戏客户端连接后可请求资产。

#### 6.3.1 AssetServer 基类

```cpp
// asset_server.hpp L11-39
class AssetServer : SimpleThread
{
public:
    AssetServer();
    virtual ~AssetServer();

    void broadcastAsset( const StringRef & asset );  // 广播资产已就绪

protected:
    // 子类实现的纯虚函数
    virtual void onAssetRequested( const StringRef & asset ) = 0;
    virtual void lock() = 0;
    virtual void unlock() = 0;

private:
    void processCommand( HANDLE hPipe, const StringRef & command );
    void lock( HANDLE hPipe );
    void unlock( HANDLE hPipe );
    BW::wstring generatePipeId();

    static void serverThreadFunc( void * arg );
    static void pipeThreadFunc( void * arg );

private:
    SimpleMutex mutex_;
    HANDLE hCommandMutex_;                        // 跨进程命令互斥
    BW::map<HANDLE, SimpleThread*> pipeThreads_;  // 每客户端一个线程
    BW::vector<HANDLE> lockedPipes_;              // 已加锁的管道
    bool terminating_;
};
```

#### 6.3.2 命名管道 ID 生成

```cpp
// asset_server.cpp L132-142
BW::wstring AssetServer::generatePipeId()
{
    char path[BW_MAX_PATH];
    MF_VERIFY( BWUtil::getExecutablePath( path, ARRAY_SIZE( path ) ) );
    // 基于可执行文件路径生成哈希,确保不同安装位置的 jit_compiler 有不同管道 ID
    BW::uint64 hash = BW::Hash64::compute( 
        BWResource::correctCaseOfPath( 
        BWResource::removeExtension( path ) ) );
    wchar_t wpath[18];
    bw_snwprintf( wpath, 17, L"%.16X", hash );
    return AssetPipe::s_AssetPipelineId + wpath;
}
```

**管道命名规则**:`\\.\pipe\` + `AssetPipeline` + 16位十六进制哈希(基于可执行文件路径)。

**优点**:
- 同一台机器上不同安装位置的 jit_compiler 有不同管道 ID,互不干扰。
- 游戏客户端通过相同的哈希算法找到对应的管道。

#### 6.3.3 服务器线程与管道线程

**服务器线程**(主循环):

```cpp
// asset_server.cpp L144-207
void AssetServer::serverThreadFunc( void * arg )
{
    AssetServer & assetServer = *static_cast< AssetServer * >( arg );

    BW::wstring pipeId = assetServer.generatePipeId();
    BW::wstring pipeName = AssetPipe::s_PipePath + pipeId;
    // 创建命令互斥量(跨进程)
    BW::wstring commandMutex = AssetPipe::s_LocalPath + pipeId + 
        AssetPipe::s_CommandMutex;
    assetServer.hCommandMutex_ = CreateMutexW( NULL, false, commandMutex.c_str() );

    while (true)
    {
        // 创建命名管道(双向、消息模式)
        HANDLE hPipe = CreateNamedPipe( pipeName.c_str(), 
                                        PIPE_ACCESS_DUPLEX,
                                        PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT, 
                                        PIPE_UNLIMITED_INSTANCES, 
                                        ASSET_PIPE_SIZE,    // 4096
                                        ASSET_PIPE_SIZE, 
                                        0,
                                        NULL); 

        // 等待客户端连接(阻塞)
        if (ConnectNamedPipe( hPipe, NULL ) == false &&
            GetLastError() != ERROR_PIPE_CONNECTED)
        {
            CloseHandle( hPipe );
            continue;
        }

        // 为每个客户端创建独立线程
        {
            SimpleMutexHolder smh( assetServer.mutex_ );
            AssetServer_Locals::PipeInfo pInfo;
            pInfo.hPipe_ = hPipe;
            pInfo.assetServer_ = &assetServer;
            std::auto_ptr< SimpleThread > pipeThread( 
                new SimpleThread( pipeThreadFunc, &pInfo ) );
            if (pipeThread->handle() != NULL)
            {
                assetServer.pipeThreads_[hPipe] = pipeThread.release();
            }
        }
    }
}
```

**管道线程**(每客户端一个):

```cpp
// asset_server.cpp L209-256
void AssetServer::pipeThreadFunc( void * arg )
{
    AssetServer_Locals::PipeInfo & pInfo = 
        *static_cast< AssetServer_Locals::PipeInfo * >( arg );
    HANDLE hPipe = pInfo.hPipe_;
    AssetServer & assetServer = *pInfo.assetServer_;

    char buffer[ASSET_PIPE_SIZE];
    DWORD bufferOffset = 0;
    while (!assetServer.terminating_)
    {
        typedef BW::vector< BW::StringRef > StringArray;
        StringArray requests;
        if (!AssetPipe::readPipe( hPipe, requests, buffer, bufferOffset ))
        {
            break;  // 读失败,退出
        }

        for (StringArray::const_iterator 
            requestIt = requests.begin(); requestIt != requests.end(); ++requestIt)
        {
            if (strncmp( requestIt->begin(), ASSET_PIPE_COMMAND, 1 ) == 0)
            {
                // 命令(以 ":" 开头):Lock/Unlock
                StringRef command( requestIt->data() + 1, requestIt->length() );
                assetServer.processCommand( hPipe, command );
                AssetPipe::writePipe( hPipe, *requestIt );  // 回显确认
            }
            else
            {
                // 资产请求
                assetServer.onAssetRequested( *requestIt );
            }
        }
    }

    assetServer.unlock( hPipe );  // 退出时解锁

    {
        SimpleMutexHolder smh( assetServer.mutex_ );
        DisconnectNamedPipe( hPipe );
        CloseHandle( hPipe );
        assetServer.pipeThreads_.erase( hPipe );
    }
}
```

#### 6.3.4 协议格式

协议基于 `asset_pipe.hpp` 的常量:

```cpp
// asset_pipe.hpp L9-14
#define ASSET_PIPE_SIZE 4096              // 缓冲区大小
#define ASSET_PIPE_TOKEN "|"              // 消息分隔符
#define ASSET_PIPE_COMMAND ":"            // 命令前缀
#define ASSET_PIPE_LOCK "Lock"            // 加锁命令
#define ASSET_PIPE_UNLOCK "Unlock"        // 解锁命令
#define ASSET_PIPE_TIMEOUT 10             // 超时(秒)
```

**消息类型**:

| 消息格式 | 含义 | 处理 |
|----------|------|------|
| `:Lock` | 加锁命令(暂停编译器) | `lock()` → `pause()` |
| `:Unlock` | 解锁命令(恢复编译器) | `unlock()` → `resume()` |
| `<资产路径>` | 资产请求 | `onAssetRequested()` |

**Lock/Unlock 的用途**:游戏客户端在加载资产时,先发送 `Lock` 暂停编译器(避免文件正在写入时读取),加载完成后发送 `Unlock`。`AssetServer` 通过引用计数管理多个客户端的锁:

```cpp
// asset_server.cpp L93-130
void AssetServer::lock( HANDLE hPipe )
{
    SimpleMutexHolder smh( mutex_ );
    // 去重
    for (auto it = lockedPipes_.begin(); it != lockedPipes_.end(); ++it)
    {
        if (*it == hPipe) return;
    }
    lockedPipes_.push_back( hPipe );
    if (lockedPipes_.size() == 1)  // 第一个锁,触发实际加锁
    {
        lock();  // 调用 JITCompiler::lock() → AssetCompiler::pause()
    }
}

void AssetServer::unlock( HANDLE hPipe )
{
    SimpleMutexHolder smh( mutex_ );
    for (auto it = lockedPipes_.begin(); it != lockedPipes_.end(); ++it)
    {
        if (*it == hPipe)
        {
            lockedPipes_.erase( it );
            if (lockedPipes_.empty())  // 所有锁释放,触发实际解锁
            {
                unlock();  // 调用 JITCompiler::unlock() → AssetCompiler::resume()
            }
            return;
        }
    }
}
```

#### 6.3.5 JITCompiler 实现 onAssetRequested

```cpp
// jit_compiler.cpp L298-373
void JITCompiler::onAssetRequested( const StringRef & asset )
{
    if (!executing())
    {
        return;  // 编译器未运行,忽略
    }

    BW::string sourceFile;
    bool found = getSourceFile( asset, sourceFile );  // 反查源文件

    if (!found)
    {
        // 找不到源文件,直接广播"已完成"
        broadcastAsset( asset );
        return;
    }

    // 获取任务
    ConversionTask & task = taskFinder_.getTask( sourceFile );
    if (task.converterId_ == ConversionTask::s_unknownId)
    {
        // 无对应 Converter,直接广播
        broadcastAsset( asset );
        return;
    }

    // 尝试把任务移到队列开头(优先处理)
    {
        SimpleMutexHolder taskQueueMutexHolder( taskQueueMutex_ );
        if (task.status_ == ConversionTask::QUEUED)
        {
            // 已在队列中,移到开头
            ConversionTaskQueue::iterator it = 
                std::find( taskQueue_.begin(), taskQueue_.end(), &task );
            if (it != taskQueue_.end())
            {
                taskQueue_.erase( it );
                task.status_ = ConversionTask::NEW;
            }
        }

        if (task.status_ == ConversionTask::NEW)
        {
            taskQueue_.push_front( &task );  // 插入队首
            task.status_ = ConversionTask::QUEUED;
        }
    }

    // 若任务已完成且源文件无待处理修改,直接广播
    if (task.status_ >= ConversionTask::DONE)
    {
        BW::string relativeSourceFile = BWResolver::dissolveFilename( sourceFile );
        if (!BWResource::instance().hasPendingModification( relativeSourceFile ))
        {
            broadcastAsset( asset );
            return;
        }
    }

    // 记录请求,任务完成后广播
    BW::string request = asset.to_string();
    {
        SimpleMutexHolder smh( requestMutex_ );
        BW::vector<std::pair<ConversionTask *, BW::string>>::iterator requestIt =
            std::find( requests_.begin(), requests_.end(), 
                       std::make_pair( &task, request ) );
        if (requestIt == requests_.end())
        {
            requests_.push_back( std::make_pair( &task, request ) );
        }
    }

    store_.addRequestedTask( &task );  // 通知 UI

    event_.set();  // 唤醒管理线程
}
```

**JIT 请求处理流程**:

```
客户端请求资产 A
  │
  ├─► getSourceFile(A) 反查源文件 S
  │     └─► 失败? → broadcastAsset(A) 直接返回
  │
  ├─► taskFinder_.getTask(S) 获取任务 T
  │     └─► 无 Converter? → broadcastAsset(A) 直接返回
  │
  ├─► 任务 T 已在队列? → 移到队首(优先处理)
  ├─► 任务 T 是 NEW? → 插入队首
  │
  ├─► 任务 T 已完成且源文件无修改? → broadcastAsset(A) 直接返回
  │
  ├─► 记录请求 requests_ += [(T, A)]
  ├─► store_.addRequestedTask(T) 通知 UI
  └─► event_.set() 唤醒管理线程
        │
        └─► (任务完成后) onTaskCompleted
              └─► 遍历 requests_,匹配 T → broadcastAsset(A)
```

#### 6.3.6 broadcastAsset 广播

```cpp
// asset_server.cpp L58-76
void AssetServer::broadcastAsset( const StringRef & asset )
{
    SimpleMutexHolder smh( mutex_ );

    // 向所有连接的客户端管道写入资产路径
    for ( BW::map<HANDLE, SimpleThread *>::iterator
        it = pipeThreads_.begin(); it != pipeThreads_.end(); )
    {
        if (!AssetPipe::writePipe( it->first, asset ))
        {
            // 写失败,客户端已断开
            DisconnectNamedPipe( it->first );
            it = pipeThreads_.erase( it );
        }
        else
        {
            ++it;
        }
    }
}
```

**广播语义**:向**所有**连接的客户端广播。这意味着多个客户端同时请求同一资产时,只需编译一次,完成后所有客户端都收到通知。

### 6.4 文件变更监听

jit_compiler 通过 `ResourceModificationListener` 监听文件变更,触发增量重建。

#### 6.4.1 注册监听器

```cpp
// jit_compiler.cpp L32-42 (构造函数)
JITCompiler::JITCompiler( TaskStore & store ) :
    AssetCompiler(),
    event_( false ),  // 初始非触发态
    store_( store )
{
    addToolsResourcePaths();
    // 启用文件修改监听
    BW::BWResource::instance().enableModificationMonitor( true ); 
    BWResource::instance().addModificationListener( this );  // 注册自己
}

JITCompiler::~JITCompiler()
{
    BWResource::instance().removeModificationListener( this );
}
```

#### 6.4.2 onResourceModified 回调

```cpp
// jit_compiler.cpp L386-476
void JITCompiler::onResourceModified( const StringRef & basePath,
                                      const StringRef & resourceID,
                                      Action modType )
{
    if (terminating())
    {
        return;
    }

    BW::string fullPath = basePath + resourceID;
    if (BWResource::pathIsRelative( fullPath ))
    {
        return;  // 忽略相对路径
    }

    // 清理缓存
    purgeResource( resourceID );
    purgeResource( fullPath );

    MultiFileSystem* fs = BWResource::instance().fileSystem();
    IFileSystem::FileType ft = fs->getFileType( fullPath );
    if (ft == IFileSystem::FT_DIRECTORY)
    {
        return;  // 忽略目录变更
    }

    BW::vector< ConversionTask * > tasks;

    // 文件新增:尝试创建根任务
    if (modType == Action::ACTION_ADDED)
    {
        ConversionTask * rootTask = taskFinder_.getTask( fullPath, true );
        if (rootTask != NULL)
        {
            tasks.push_back( rootTask );
        }
    }

    // 收集所有依赖此文件的任务
    const BW::string path = BWResource::instance().getFilePath( fullPath );
    const BW::StringRef filename = BWResource::instance().getFilename( fullPath );
    bool includeOutputs = !checkFileHashUpToDate( fullPath );
    collectReverseDependencies( fullPath, includeOutputs, tasks );  // 精确路径
    collectReverseDependencies( path, filename, tasks );            // 目录模式匹配

    // 重置并重新入队受影响的任务
    for ( BW::vector< ConversionTask * >::iterator
        it = tasks.begin(); it != tasks.end(); ++it )
    {
        ConversionTask & task = **it;
        if (task.converterId_ == ConversionTask::s_unknownId)
        {
            continue;
        }

        if ( task.status_ == ConversionTask::QUEUED )
        {
            continue;  // 已在队列,跳过
        }

        MF_ASSERT( task.status_ == ConversionTask::NEW ||
            task.status_ == ConversionTask::DONE ||
            task.status_ == ConversionTask::FAILED );

        bool modifiedIsSource = ( task.source_ == fullPath );
        bool sourceExists = BWResource::fileExists( task.source_ );

        // 源文件被其他任务删除,跳过
        if (!modifiedIsSource && !sourceExists)
        {
            continue;
        }

        // 重置任务状态
        task.status_ = ConversionTask::NEW;
        task.subTasks_.clear();
        store_.resetTask( &task );

        // 源文件被删除,不重新入队
        if (modifiedIsSource && !sourceExists)
        {
            continue;
        }

        // 重新入队
        queueTask( task );

        // 唤醒管理线程
        event_.set();
    }
}
```

**文件变更处理流程**:

```
文件 F 变更(basePath + resourceID,modType)
  │
  ├─► 终止中? → return
  ├─► 相对路径? → return
  ├─► purgeResource 清理缓存
  ├─► 目录? → return
  │
  ├─► ACTION_ADDED? → taskFinder_.getTask(F, true) 创建根任务
  │
  ├─► collectReverseDependencies(F, includeOutputs, tasks)
  │     └─► 精确路径匹配 reverseDependencyMap_
  │
  ├─► collectReverseDependencies(path, filename, tasks)
  │     └─► 目录模式匹配 directoryDependencies_(正则)
  │
  └─► 对每个受影响任务:
        ├─► 已 QUEUED? → 跳过
        ├─► 重置 status_ = NEW, 清空 subTasks_
        ├─► store_.resetTask 通知 UI
        ├─► 源文件删除? → 不入队
        └─► queueTask + event_.set()
```

**关键判断**:

- `includeOutputs = !checkFileHashUpToDate( fullPath )`:若文件哈希未变(可能是 touch),不包含输出依赖(避免无谓重建)。若哈希变了,包含输出依赖(输出文件变更可能需要清理)。
- `modifiedIsSource`:变更的文件是否是任务的源文件。若是且文件已删除,则不重新入队(任务失效)。
- `sourceExists`:任务源文件是否存在。若不存在且变更的不是源文件,跳过(任务已失效)。

#### 6.4.3 purgeResource 资源清理

```cpp
// jit_compiler.cpp L288-296
void JITCompiler::purgeResource( const StringRef & resourceId )
{
    BWResource::instance().purge( resourceId );  // 清理 BWResource 缓存
    for (BW::vector< ResourceCallbacks * >::iterator 
        it = resourceCallbacks_.begin(); it != resourceCallbacks_.end(); ++it)
    {
        ( *it )->purgeResource( resourceId );  // 通知所有资源回调
    }
}
```

**清理范围**:
- `BWResource::purge`:清理 DataSection 缓存、文件系统缓存。
- `ResourceCallbacks`:通知所有注册的资源回调(如纹理、网格等资源管理器)清理相关缓存。

### 6.5 增量编译流程

增量编译是 jit_compiler 的核心场景,由"文件变更"或"客户端请求"触发。

#### 6.5.1 onTaskCompleted 反向依赖建立

任务完成后,从 `.deps` 文件读取依赖列表,建立反向依赖图:

```cpp
// jit_compiler.cpp L506-591
void JITCompiler::onTaskCompleted( ConversionTask & conversionTask )
{
    store_.setCurrentTaskState(&conversionTask, TaskInfoState::NONE);

    // 1. 广播已完成的资产请求
    {
        SimpleMutexHolder smh( requestMutex_ );
        for ( BW::vector<std::pair<ConversionTask *, BW::string>>::iterator
            it = requests_.begin(); it != requests_.end(); )
        {
            if (it->first == &conversionTask)
            {
                broadcastAsset( it->second );  // 通知客户端
                it = requests_.erase( it );
            }
            else
            {
                ++it;
            }
        }
    }

    store_.setTaskComplete(&conversionTask);

    MF_ASSERT(&conversionTask == st_currentTask_);
    st_currentTask_ = nullptr;

    // 2. 读取 .deps 文件,建立反向依赖
    DependencyList depList(*this);
    BW::StringBuilder depListFileNameBuilder( MAX_PATH );
    depListFileNameBuilder.append( conversionTask.source_ );
    depListFileNameBuilder.append( ".deps" );
    BW::string depListFileName = depListFileNameBuilder.string();
    MF_VERIFY(resolveIntermediatePath( depListFileName ));
    DataResource depListResource( depListFileName, RESOURCE_TYPE_XML );
    DataSectionPtr depListRoot = depListResource.getRootSection();
    MF_ASSERT( depListRoot != NULL );
    depList.serialiseIn( depListRoot );  // 反序列化依赖列表

    {
        static SimpleMutex reverseDependencyMutex;
        SimpleMutexHolder reverseDependencyMutexHolder( reverseDependencyMutex );

        // 3. 无 primaryInputs 时,把源文件作为依赖
        if (depList.primaryInputs().empty())
        {
            addReverseDependency( conversionTask.source_, false, conversionTask );
        }

        // 4. 为所有 primaryInputs 建立反向依赖
        const BW::vector< DependencyList::Input > & primaryInputs = depList.primaryInputs();
        for ( BW::vector< DependencyList::Input >::const_iterator
            it = primaryInputs.begin(); it != primaryInputs.end(); ++it )
        {
            addReverseDependency( *it->first, conversionTask );
        }

        // 5. 为所有 secondaryInputs 建立反向依赖
        const BW::vector< DependencyList::Input > & secondaryInputs = depList.secondaryInputs();
        for ( BW::vector< DependencyList::Input >::const_iterator
            it = secondaryInputs.begin(); it != secondaryInputs.end(); ++it )
        {
            addReverseDependency( *it->first, conversionTask );
        }

        // 6. 任务成功时,为 outputs 建立反向依赖
        if (conversionTask.status_ != ConversionTask::FAILED)
        {
            const BW::vector< DependencyList::Output > & intermediateOutputs = 
                depList.intermediateOutputs();
            for ( BW::vector< DependencyList::Output >::const_iterator
                it = intermediateOutputs.begin(); it != intermediateOutputs.end(); ++it )
            {
                BW::string filename = it->first;
                resolveIntermediatePath( filename );
                addReverseDependency( filename, true, conversionTask );
            }

            const BW::vector< DependencyList::Output > & outputs = depList.outputs();
            for ( BW::vector< DependencyList::Output >::const_iterator
                it = outputs.begin(); it != outputs.end(); ++it )
            {
                BW::string filename = it->first;
                resolveOutputPath( filename );
                addReverseDependency( filename, true, conversionTask );
            }
        }
    }

    AssetCompiler::onTaskCompleted( conversionTask );
}
```

**关键点**:
1. **先广播再建图**:先处理 `requests_` 广播,再建立反向依赖。确保客户端尽快收到通知。
2. **静态互斥量**:`static SimpleMutex reverseDependencyMutex`,保护反向依赖图的并发修改。
3. **失败任务不建输出依赖**:`if (conversionTask.status_ != ConversionTask::FAILED)`,失败时输出可能不完整,不应作为依赖。
4. **无 primaryInputs 的兜底**:若任务无 primaryInputs,把源文件作为依赖(确保源文件变更能触发重建)。

#### 6.5.2 增量编译完整时序

```
场景:纹理 texture.dds 变更,影响材质 material.model 和模型 character.model

1. 文件监听器检测到 texture.dds 变更
   └─► onResourceModified("resources/", "texture.dds", ACTION_MODIFIED)
         ├─► purgeResource 清理缓存
         ├─► collectReverseDependencies("resources/texture.dds", true, tasks)
         │     └─► reverseDependencyMap_["resources/texture.dds"] = 
         │           [(material.material, false), (character.model, false)]
         │     └─► tasks = [material.material, character.model]
         ├─► collectReverseDependencies("resources", "texture.dds", tasks)
         │     └─► 检查 directoryDependencies_,无匹配
         └─► 对 tasks 中每个任务:
               ├─► material.material: 重置 → queueTask → event_.set()
               └─► character.model: 重置 → queueTask → event_.set()

2. 管理线程被唤醒
   └─► managingThreadMain
         ├─► event_.wait() 返回
         ├─► taskProcessor_.processTasks()
         │     ├─► 处理 material.material
         │     │     ├─► onTaskStarted → store_.setTaskCurrent
         │     │     ├─► 检查依赖哈希 → 需要重建
         │     │     ├─► onPreConvert → Converter 执行
         │     │     ├─► onPostConvert
         │     │     └─► onTaskCompleted
         │     │           ├─► 广播(若有 requests_)
         │     │           ├─► 读取 .deps
         │     │           └─► 重建反向依赖(reverseDependencyMap_ 更新)
         │     └─► 处理 character.model(同上)
         ├─► WaitForSingleObject(taskSemaphore_) 等待完成
         ├─► flushModificationMonitor() 触发新一轮 onResourceModified(若有)
         └─► ReleaseSemaphore → 进入下一轮

3. 客户端(若有)收到 broadcastAsset 通知
```

### 6.6 目录依赖正则匹配

目录依赖是 jit_compiler 处理"通配符依赖"的机制,例如"任务 A 依赖 scripts/ 目录下所有 .py 文件"。

#### 6.6.1 目录依赖字符串格式

```
"目录>模式>正则标志>递归标志"
```

**示例**:

| 字符串 | 含义 |
|--------|------|
| `"scripts/>*.py>0>0"` | scripts/ 目录下(非递归)所有 .py 文件 |
| `"scripts/>*.py>0>1"` | scripts/ 目录下(递归)所有 .py 文件 |
| `"scripts/.*\.py$>1>0"` | scripts/ 目录下(非递归)正则匹配 .*\.py$ |
| `"resources/textures/>.*\.dds>1>1"` | resources/textures/ 下(递归)所有 .dds 文件 |

#### 6.6.2 匹配算法

见 [6.2.3 collectReverseDependencies 重载 2](#重载-2按目录模式收集正则匹配),核心逻辑:

1. **路径前缀匹配**:
   - 非递归:`path == directory`(完全匹配目录)
   - 递归:`path.substr(0, directory.length()) == directory`(前缀匹配)
2. **文件名匹配**:
   - 非正则:`file == pattern`(精确匹配)
   - 正则:`RE2::FullMatch(file, pattern)`(RE2 全匹配)
3. **匹配后移除**:目录依赖是"一次性通配符",匹配后从 `directoryDependencies_` 移除,避免重复触发。任务完成后会通过 `onTaskCompleted` 重新建立。

#### 6.6.3 RE2 正则库

jit_compiler 使用 Google 的 [RE2](https://github.com/google/re2) 库做正则匹配:

```cpp
// jit_compiler.cpp L22
#include "re2/re2.h"

// 使用示例(L221-222)
if (RE2::FullMatch( re2::StringPiece( file.data(), static_cast< int >( file.length() ) ),
    re2::StringPiece( pattern.data(), static_cast< int >( pattern.length() ) ) ))
{
    // 匹配成功
}
```

**RE2 优势**:
- 线性时间复杂度(无回溯),适合处理用户提供的模式。
- 线程安全,可在多线程环境使用。
- C++ API 简洁。

### 6.7 TaskStore 信号槽机制

TaskStore 通过 Signal 类实现观察者模式,让 UI 订阅任务变化。

#### 6.7.1 Signal 实现

```cpp
// signal.hpp(基于 task_info.hpp 中的使用)
template<typename Signature>
class Signal
{
public:
    typedef std::function<Signature> Slot;

    Connection connect(Slot slot);   // 订阅
    void disconnect(Connection conn); // 取消订阅
    void emit(Args... args);         // 触发信号
};
```

#### 6.7.2 TaskStore 的三个信号

```cpp
// task_store.hpp L84-88
TaskSignal requestedSignal_;   // 任务加入请求队列
TaskSignal currentSignal_;     // 任务开始处理
TaskSignal completedSignal_;   // 任务完成
```

**订阅接口**:

```cpp
// task_store.hpp L54-56
Connection registerRequestedTaskCallback(TaskCallbackFunction callback);
Connection registerCurrentTaskCallback(TaskCallbackFunction callback);
Connection registerCompletedTaskCallback(TaskCallbackFunction callback);
```

**触发时机**:

| 信号 | 触发方法 | 时机 |
|------|----------|------|
| `requestedSignal_` | `addRequestedTask` | 客户端请求或文件变更入队 |
| `currentSignal_` | `setTaskCurrent` | `onTaskStarted`/`onTaskResumed` |
| `completedSignal_` | `setTaskComplete` | `onTaskCompleted` |

#### 6.7.3 MainWindow 订阅

MainWindow 在 `init()` 中订阅三个信号:

```cpp
// main_window.cpp(伪代码,基于 main_window.hpp 的 connections_ 成员)
bool MainWindow::init()
{
    // ... 创建对话框 ...
    
    connections_.push_back(store_.registerRequestedTaskCallback(
        [this](TaskInfoPtr task, TaskStoreAction action) {
            // 通过 messageLoop_ 投递到 UI 线程
            messageLoop_.addAction([this, task, action]() {
                changeTaskList(requestedList_, task, action);
            });
        }));
    
    connections_.push_back(store_.registerCurrentTaskCallback(
        [this](TaskInfoPtr task, TaskStoreAction action) {
            messageLoop_.addAction([this, task, action]() {
                changeTaskList(currentList_, task, action);
            });
        }));
    
    connections_.push_back(store_.registerCompletedTaskCallback(
        [this](TaskInfoPtr task, TaskStoreAction action) {
            messageLoop_.addAction([this, task, action]() {
                changeTaskList(completedList_, task, action);
                updateStatus();  // 更新状态栏
            });
        }));
    
    // ... 其他初始化 ...
}
```

**线程安全**:信号回调在工作线程触发,通过 `messageLoop_.addAction` 投递到 UI 线程执行,避免直接操作控件。

---

## 七、配置项与命令行参数

### 7.1 命令行参数

jit_compiler 复用 `AssetCompilerOptions` 解析命令行:

```cpp
// main.cpp L60-61
BW::AssetCompilerOptions options;
options.parseCommandLine( BW::bw_wtoutf8( GetCommandLineW() ) );
```

**支持的参数**(来自 `asset_compiler_options.cpp` L60-88):

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `intermediatePath` | 路径 | - | 中间文件目录(.deps 等) |
| `outputPath` | 路径 | - | 最终输出目录 |
| `cachePath` | 路径 | - | 内容寻址缓存目录 |
| `j` | 整数 | 0(自动) | 工作线程数 |
| `recursive` | 标志 | false | 递归扫描(对 jit_compiler 通常默认 true) |
| `forceRebuild` | 标志 | false | 强制重建所有任务 |
| `enableCacheRead` | 标志 | true | 启用缓存读 |
| `enableCacheWrite` | 标志 | true | 启用缓存写 |

**示例命令行**:

```
jit_compiler.exe -intermediatePath "C:/bw/intermediate" -outputPath "C:/bw/output" -cachePath "C:/bw/cache" -j 4
```

### 7.2 JitCompilerOptions 扩展

`JitCompilerOptions` 继承 `AssetCompilerOptions`,增加 GUI 特有选项:

```cpp
// jit_compiler_options.hpp L10-23
class JitCompilerOptions : public AssetCompilerOptions
{
public:
    JitCompilerOptions();
    explicit JitCompilerOptions( const AssetCompiler & compiler );

    bool enableBalloonNotifications() const;
    void enableBalloonNotifications( bool enable );

protected:
    bool enableBalloonNotifications_;
};
```

**扩展选项**:

| 选项 | 类型 | 说明 |
|------|------|------|
| `enableBalloonNotifications_` | bool | 是否启用系统托盘气泡通知 |

**注意**:`JitCompilerOptions` 主要用于 OptionsDialog 的持久化,WinMain 中实际使用的是基类 `AssetCompilerOptions`(未读取气泡通知选项)。

### 7.3 配置文件

jit_compiler 通过 `BWResource` 读取配置文件,典型配置包括:

- **资源路径**(`paths.xml`):定义资源搜索路径,通常包含 base 和 mod 两个层级。
- **Converter 插件**(`plugins/` 目录):.dll 形式的 Converter,通过 `PluginLoader` 加载。
- **转换规则**(`asset_rules.xml`):定义文件扩展名到 Converter 的映射,由 `GenericConversionRule` 加载。

### 7.4 运行时配置对话框

jit_compiler 提供 GUI 配置对话框:

| 对话框 | 文件 | 功能 |
|--------|------|------|
| OptionsDialog | options_dialog.hpp/cpp | 编译选项(路径、线程数等) |
| ConfigDialog | config_dialog.hpp/cpp | 资源路径配置 |
| AboutDialog | about_dialog.hpp/cpp | 关于信息 |
| DetailsDialog | details_dialog.hpp/cpp | 任务详情(日志、输出、子任务) |

---

## 八、与其他模块的依赖关系

### 8.1 模块依赖图

```
┌─────────────────────────────────────────────────────────────────┐
│                       jit_compiler (exe)                        │
└────────────┬────────────────────────────────────────────────────┘
             │
    ┌────────┴────────┬──────────────┬─────────────┬──────────────┐
    │                 │              │             │              │
    ▼                 ▼              ▼             ▼              ▼
┌─────────┐  ┌──────────────┐  ┌─────────┐  ┌──────────┐  ┌──────────┐
│asset_   │  │resmgr        │  │cstdmf   │  │re2       │  │WTL       │
│pipeline │  │              │  │         │  │(正则)    │  │(GUI 框架)│
│(lib)    │  │              │  │         │  │          │  │          │
└────┬────┘  └──────┬───────┘  └────┬────┘  └──────────┘  └──────────┘
     │              │               │
     │              │               │
     ▼              ▼               ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Windows API (Win32)                          │
│  Named Pipe / Mutex / Semaphore / Event / Thread                │
└─────────────────────────────────────────────────────────────────┘
```

### 8.2 依赖模块详解

| 模块 | 路径 | 用途 |
|------|------|------|
| `asset_pipeline` | `lib/asset_pipeline/` | AssetCompiler/AssetServer/ConversionTask/DependencyList 等 |
| `resmgr` | `lib/resmgr/` | BWResource 文件系统、DataSection、ResourceModificationListener |
| `cstdmf` | `lib/cstdmf/` | 并发原语(SimpleMutex/SimpleThread/SimpleEvent)、字符串、命令行 |
| `re2` | 第三方 | 正则表达式匹配(目录依赖) |
| `WTL` | 第三方 | Windows GUI 框架(对话框、控件、消息映射) |
| `plugin_system` | `lib/plugin_system/` | PluginLoader 插件加载 |

### 8.3 与 asset_pipeline 的关系

jit_compiler 是 asset_pipeline 的**上层用户**,复用其核心能力:

| asset_pipeline 组件 | jit_compiler 使用方式 |
|---------------------|----------------------|
| `AssetCompiler` | 公有继承,复用任务队列/状态机/多线程/缓存 |
| `TaskFinder` | 启动时扫描资源路径发现任务 |
| `TaskProcessor` | 管理线程驱动 `processTasks()` |
| `ConversionTask` | 任务状态机(NEW/QUEUED/PROCESSING/DONE/FAILED) |
| `DependencyList` | 任务完成后读取 `.deps` 建立反向依赖 |
| `ContentAddressableCache` | 跨构建共享依赖列表与中间产物 |
| `AssetServer` | 公有继承,提供命名管道 IPC |
| `Converter` 插件 | 通过 PluginLoader 加载,实际执行转换 |

### 8.4 与 batch_compiler 的对比

| 维度 | batch_compiler | jit_compiler |
|------|---------------|--------------|
| 基类 | AssetCompiler + PluginLoader | AssetCompiler + AssetServer + ResourceModificationListener + PluginLoader |
| 入口 | `main()` → `bw_main()` | `WinMain()` |
| 线程 | 主线程 + 工作池 | 主线程(UI) + 扫描线程 + 管理线程 + 工作池 |
| 依赖图 | 无(正向 DAG 调度) | 反向依赖图 + 正向依赖图 |
| 文件监听 | 无 | ResourceModificationListener |
| IPC | 无 | AssetServer 命名管道 |
| UI | 无 | WTL 对话框 + 系统托盘 |
| 输出 | HTML 报告 | 实时任务列表 + 气泡通知 |
| 运行时长 | 一次性(编译完退出) | 常驻(直到用户退出) |

---

## 九、关键代码片段

### 9.1 WinMain 完整启动流程

```cpp
// main.cpp L50-102
int WINAPI WinMain( HINSTANCE instance, HINSTANCE prevInstance, 
                    LPSTR commandLine, int showCmd )
{
    BW_SYSTEMSTAGE_MAIN();
#ifdef ENABLE_MEMTRACKER
    MemTracker::instance().setCrashOnLeak( true );
#endif

    int exitCode = 1;
    if (init())
    {
        BW::AssetCompilerOptions options;
        options.parseCommandLine( BW::bw_wtoutf8( GetCommandLineW() ) );

        BW::TaskStore store;
        BW::MainMessageLoop messageLoop;
        BW::JITCompiler jitCompiler(store);
        BW::MainWindow mainWindow(store, messageLoop, jitCompiler, jitCompiler);
        options.apply(jitCompiler);
        jitCompiler.initPlugins();
        jitCompiler.initCompiler();

        if (mainWindow.init())
        {
            // Spawn another thread to do the disk scanning for the JIT Compiler
            auto scanningThreadFunc = [](void * arg)
            {
                BW::JITCompiler * jitCompiler = static_cast< BW::JITCompiler *>( arg );
                jitCompiler->scanningThreadMain();
            };
            BW::SimpleThread jitScanningThread(scanningThreadFunc, &jitCompiler, 
                "JITCompiler Scanning Thread");

            auto managingThreadFunc = [](void * arg)
            {
                BW::JITCompiler * jitCompiler = static_cast< BW::JITCompiler *>( arg );
                jitCompiler->managingThreadMain();
            };
            BW::SimpleThread jitManagingThread(managingThreadFunc, &jitCompiler, 
                "JITCompiler Process Thread");

            exitCode = messageLoop.run();

            jitCompiler.stop();
        }

        mainWindow.fini();

        jitCompiler.finiCompiler();
        jitCompiler.finiPlugins();
    }

    fini();

    return exitCode;
}
```

### 9.2 构造函数:注册文件监听

```cpp
// jit_compiler.cpp L30-47
THREADLOCAL( ConversionTask * ) JITCompiler::st_currentTask_ = nullptr;

JITCompiler::JITCompiler( TaskStore & store ) :
    AssetCompiler(),
    event_( false ),  // 初始非触发态,需 event_.set() 唤醒
    store_( store )
{
    addToolsResourcePaths();
    // Create a monitor thread for all resource paths so that the JIT Compiler
    // can respond to file changes.
    BW::BWResource::instance().enableModificationMonitor( true ); 
    BWResource::instance().addModificationListener( this );
}

JITCompiler::~JITCompiler()
{
    BWResource::instance().removeModificationListener( this );
}
```

### 9.3 双线程主循环

```cpp
// jit_compiler.cpp L49-77
void JITCompiler::scanningThreadMain()
{
    store_.scanningStarted();

    // search for tasks in all resource paths
    int numPaths = BWResource::getPathNum();
    for (int i = numPaths; i > 0 && !terminating(); --i)
    {
        BW::string path = BWResource::getPath( i - 1 );
        taskFinder_.findTasks( path );
    }

    store_.scanningStopped();
}

void JITCompiler::managingThreadMain()
{
    // process the discovered tasks, flush the modification monitor and repeat
    while (!terminating())
    {
        event_.wait( 1000 );                          // 等待事件或超时
        taskProcessor_.processTasks();                // 处理任务队列

        MF_VERIFY( WaitForSingleObject( taskSemaphore_, INFINITE ) == 
            WAIT_OBJECT_0 );                          // 等待工作线程完成
        BWResource::instance().flushModificationMonitor();  // 刷新文件监听
        MF_VERIFY( ReleaseSemaphore( taskSemaphore_, 1, NULL ) );
    }
}
```

### 9.4 onAssetRequested:JIT 请求处理

```cpp
// jit_compiler.cpp L298-373(关键片段)
void JITCompiler::onAssetRequested( const StringRef & asset )
{
    if (!executing()) return;

    BW::string sourceFile;
    bool found = getSourceFile( asset, sourceFile );

    if (!found) { broadcastAsset( asset ); return; }

    ConversionTask & task = taskFinder_.getTask( sourceFile );
    if (task.converterId_ == ConversionTask::s_unknownId) 
    { broadcastAsset( asset ); return; }

    // 把任务移到队首(优先处理)
    {
        SimpleMutexHolder taskQueueMutexHolder( taskQueueMutex_ );
        if (task.status_ == ConversionTask::QUEUED)
        {
            ConversionTaskQueue::iterator it = 
                std::find( taskQueue_.begin(), taskQueue_.end(), &task );
            if (it != taskQueue_.end())
            {
                taskQueue_.erase( it );
                task.status_ = ConversionTask::NEW;
            }
        }
        if (task.status_ == ConversionTask::NEW)
        {
            taskQueue_.push_front( &task );
            task.status_ = ConversionTask::QUEUED;
        }
    }

    // 已完成且无修改?直接广播
    if (task.status_ >= ConversionTask::DONE)
    {
        BW::string relativeSourceFile = BWResolver::dissolveFilename( sourceFile );
        if (!BWResource::instance().hasPendingModification( relativeSourceFile ))
        {
            broadcastAsset( asset );
            return;
        }
    }

    // 记录请求,任务完成后广播
    BW::string request = asset.to_string();
    {
        SimpleMutexHolder smh( requestMutex_ );
        auto requestIt = std::find( requests_.begin(), requests_.end(), 
                                    std::make_pair( &task, request ) );
        if (requestIt == requests_.end())
        {
            requests_.push_back( std::make_pair( &task, request ) );
        }
    }

    store_.addRequestedTask( &task );
    event_.set();  // 唤醒管理线程
}
```

### 9.5 onResourceModified:文件变更触发重建

```cpp
// jit_compiler.cpp L386-476(关键片段)
void JITCompiler::onResourceModified( const StringRef & basePath,
                                      const StringRef & resourceID,
                                      Action modType )
{
    if (terminating()) return;

    BW::string fullPath = basePath + resourceID;
    if (BWResource::pathIsRelative( fullPath )) return;

    purgeResource( resourceID );
    purgeResource( fullPath );

    MultiFileSystem* fs = BWResource::instance().fileSystem();
    if (fs->getFileType( fullPath ) == IFileSystem::FT_DIRECTORY) return;

    BW::vector< ConversionTask * > tasks;

    if (modType == Action::ACTION_ADDED)
    {
        ConversionTask * rootTask = taskFinder_.getTask( fullPath, true );
        if (rootTask != NULL) tasks.push_back( rootTask );
    }

    const BW::string path = BWResource::instance().getFilePath( fullPath );
    const BW::StringRef filename = BWResource::instance().getFilename( fullPath );
    bool includeOutputs = !checkFileHashUpToDate( fullPath );
    collectReverseDependencies( fullPath, includeOutputs, tasks );
    collectReverseDependencies( path, filename, tasks );

    for (auto it = tasks.begin(); it != tasks.end(); ++it)
    {
        ConversionTask & task = **it;
        if (task.converterId_ == ConversionTask::s_unknownId) continue;
        if (task.status_ == ConversionTask::QUEUED) continue;

        bool modifiedIsSource = ( task.source_ == fullPath );
        bool sourceExists = BWResource::fileExists( task.source_ );
        if (!modifiedIsSource && !sourceExists) continue;

        task.status_ = ConversionTask::NEW;
        task.subTasks_.clear();
        store_.resetTask( &task );

        if (modifiedIsSource && !sourceExists) continue;

        queueTask( task );
        event_.set();
    }
}
```

### 9.6 onTaskCompleted:反向依赖建立

```cpp
// jit_compiler.cpp L506-591(关键片段)
void JITCompiler::onTaskCompleted( ConversionTask & conversionTask )
{
    store_.setCurrentTaskState(&conversionTask, TaskInfoState::NONE);

    // 广播已完成的资产请求
    {
        SimpleMutexHolder smh( requestMutex_ );
        for (auto it = requests_.begin(); it != requests_.end(); )
        {
            if (it->first == &conversionTask)
            {
                broadcastAsset( it->second );
                it = requests_.erase( it );
            }
            else ++it;
        }
    }

    store_.setTaskComplete(&conversionTask);
    st_currentTask_ = nullptr;

    // 读取 .deps 建立反向依赖
    DependencyList depList(*this);
    BW::string depListFileName = conversionTask.source_ + ".deps";
    resolveIntermediatePath( depListFileName );
    DataResource depListResource( depListFileName, RESOURCE_TYPE_XML );
    depList.serialiseIn( depListResource.getRootSection() );

    {
        static SimpleMutex reverseDependencyMutex;
        SimpleMutexHolder holder( reverseDependencyMutex );

        if (depList.primaryInputs().empty())
        {
            addReverseDependency( conversionTask.source_, false, conversionTask );
        }

        for (auto & input : depList.primaryInputs())
            addReverseDependency( *input.first, conversionTask );
        for (auto & input : depList.secondaryInputs())
            addReverseDependency( *input.first, conversionTask );

        if (conversionTask.status_ != ConversionTask::FAILED)
        {
            for (auto & output : depList.intermediateOutputs())
            {
                BW::string filename = output.first;
                resolveIntermediatePath( filename );
                addReverseDependency( filename, true, conversionTask );
            }
            for (auto & output : depList.outputs())
            {
                BW::string filename = output.first;
                resolveOutputPath( filename );
                addReverseDependency( filename, true, conversionTask );
            }
        }
    }

    AssetCompiler::onTaskCompleted( conversionTask );
}
```

### 9.7 AssetServer 命名管道创建

```cpp
// asset_server.cpp L144-207(关键片段)
void AssetServer::serverThreadFunc( void * arg )
{
    AssetServer & assetServer = *static_cast< AssetServer * >( arg );
    BW::wstring pipeId = assetServer.generatePipeId();
    BW::wstring pipeName = AssetPipe::s_PipePath + pipeId;

    while (true)
    {
        HANDLE hPipe = CreateNamedPipe( pipeName.c_str(), 
                                        PIPE_ACCESS_DUPLEX,
                                        PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT, 
                                        PIPE_UNLIMITED_INSTANCES, 
                                        ASSET_PIPE_SIZE,
                                        ASSET_PIPE_SIZE, 
                                        0,
                                        NULL); 

        if (hPipe == INVALID_HANDLE_VALUE) return;

        if (ConnectNamedPipe( hPipe, NULL ) == false &&
            GetLastError() != ERROR_PIPE_CONNECTED)
        {
            CloseHandle( hPipe );
            continue;
        }

        SimpleMutexHolder smh( assetServer.mutex_ );
        AssetServer_Locals::PipeInfo pInfo;
        pInfo.hPipe_ = hPipe;
        pInfo.assetServer_ = &assetServer;
        std::auto_ptr< SimpleThread > pipeThread( 
            new SimpleThread( pipeThreadFunc, &pInfo ) );
        if (pipeThread->handle() != NULL)
        {
            assetServer.pipeThreads_[hPipe] = pipeThread.release();
        }
    }
}
```

### 9.8 TaskStore 任务状态管理回调

```cpp
// jit_compiler.cpp L478-625(关键片段)
void JITCompiler::onTaskStarted( ConversionTask & conversionTask )
{
    store_.setTaskCurrent(&conversionTask);
    store_.setCurrentTaskState(&conversionTask, TaskInfoState::CHECKING);
    MF_ASSERT(st_currentTask_ == nullptr);
    st_currentTask_ = &conversionTask;
    AssetCompiler::onTaskStarted( conversionTask );
}

void JITCompiler::onPreCreateDependencies( ConversionTask & conversionTask )
{
    store_.setCurrentTaskState( &conversionTask, TaskInfoState::GENERATING_DEPENDENCIES );
    AssetCompiler::onPreCreateDependencies( conversionTask );
}

void JITCompiler::onPostCreateDependencies( ConversionTask & conversionTask )
{
    store_.setCurrentTaskState( &conversionTask, TaskInfoState::CHECKING );
    AssetCompiler::onPostCreateDependencies( conversionTask );
}

void JITCompiler::onPreConvert( ConversionTask & conversionTask )
{
    store_.setCurrentTaskState( &conversionTask, TaskInfoState::CONVERTING );
    AssetCompiler::onPreConvert( conversionTask );
}

void JITCompiler::onPostConvert( ConversionTask & conversionTask )
{
    store_.setCurrentTaskState( &conversionTask, TaskInfoState::CHECKING );
    AssetCompiler::onPostConvert( conversionTask );
}

void JITCompiler::onOutputGenerated( const BW::string & filename )
{
    if (st_currentTask_ != nullptr)
    {
        store_.addOutputToTask( st_currentTask_, filename );
    }
    AssetCompiler::onOutputGenerated( filename );
}
```

### 9.9 handleMessage:日志归因到任务

```cpp
// jit_compiler.cpp L627-669
bool JITCompiler::handleMessage( DebugMessagePriority messagePriority, 
                                 const char * pCategory,
                                 DebugMessageSource messageSource,
                                 const LogMetaData & metaData,
                                 const char * pFormat,
                                 va_list argPtr )
{
    BW_GUARD;

#if !ASSET_PIPELINE_CAPTURE_ASSERTS
    if (messagePriority == DebugMessagePriority::MESSAGE_PRIORITY_CRITICAL)
    {
        return false;  // 不拦截 CRITICAL,让其崩溃
    }
#endif

    bool handled = AssetCompiler::handleMessage( messagePriority, pCategory,
                                                 messageSource, metaData,
                                                 pFormat, argPtr);

    // 通过 st_currentTask_ 把日志归因到当前任务
    if (st_currentTask_ != nullptr)
    {
        const size_t count = _vscprintf(pFormat, argPtr) + 1;
        auto buffer = std::unique_ptr<char[]>(new char[count]);
        _vsnprintf(buffer.get(), count - 1, pFormat, argPtr);
        buffer.get()[count - 1] = '\0';

        BW::wstring message;
        bw_utf8tow(buffer.get(), message);
        if (store_.handleTaskMessage(st_currentTask_, 
                                     messagePriority, pCategory, message))
        {
            handled = true;
        }
    }

    return handled;
}
```

**关键点**:
- `st_currentTask_` 是 THREADLOCAL 变量,记录当前线程正在处理的任务。
- `onTaskStarted`/`onTaskResumed` 设置,`onTaskSuspended`/`onTaskCompleted` 清空。
- 日志通过 `store_.handleTaskMessage` 写入 TaskInfo,UI 可在 DetailsDialog 查看。

---

## 十、设计亮点与注意事项

### 10.1 设计亮点

#### 10.1.1 反向依赖图:O(1) 变更影响查找

传统构建系统(make/ninja)使用正向依赖图,要找出"文件 F 变更影响哪些目标"需要遍历整个图。jit_compiler 通过 `reverseDependencyMap_` 实现 O(1) 查找:

- **建图成本**:每个任务完成后建立,均摊 O(依赖数)。
- **查询成本**:文件变更时一次哈希查找 + 遍历受影响任务列表。
- **清理成本**:任务重新入队时,通过 `forwardDependencyMap_` 双向清理。

这种设计在"频繁变更 + 常驻编译"场景下远优于正向图遍历。

#### 10.1.2 双向映射的一致性维护

`reverseDependencyMap_` 和 `forwardDependencyMap_` 是双向映射,通过 `addReverseDependency` 同时维护:

```cpp
// 添加时同步更新双向映射
reverseDependencyMap_[path].push_back({task, isOutput});
forwardDependencyMap_[task].push_back(path);
```

`collectReverseDependencies` 收集任务时,通过 `forwardDependencyMap_` 清理任务在所有反向列表中的引用,确保一致性。这种"双向同步"避免了悬空引用。

#### 10.1.3 多重继承的角色分离

JITCompiler 通过四重继承清晰地分离了四个角色:

- `AssetCompiler`:资产编译能力(任务队列、状态机、多线程)。
- `AssetServer`:IPC 服务能力(命名管道、广播)。
- `ResourceModificationListener`:文件监听能力。
- `PluginLoader`:插件加载能力。

这种设计避免了组合方式的额外间接调用,且各基类的虚函数不冲突(除了 `handleMessage` 由 AssetCompiler 提供,其他都是独立接口)。

#### 10.1.4 事件驱动的管理线程

管理线程采用"事件 + 超时"双触发:

```cpp
event_.wait( 1000 );  // 等待事件或 1 秒超时
```

- **事件触发**:`onAssetRequested`/`onResourceModified` 入队后 `event_.set()`,立即唤醒。
- **超时触发**:1 秒兜底,确保即使错过事件也能周期性处理。

这种设计平衡了响应速度与 CPU 占用。

#### 10.1.5 Lock/Unlock 引用计数

`AssetServer` 的 Lock/Unlock 采用引用计数:

```cpp
lockedPipes_.push_back( hPipe );
if (lockedPipes_.size() == 1) lock();  // 第一个锁触发 pause

lockedPipes_.erase( it );
if (lockedPipes_.empty()) unlock();    // 所有锁释放触发 resume
```

支持多个客户端同时持锁,只有全部释放后才恢复编译。这避免了"客户端 A 解锁时客户端 B 还在加载"的竞态。

#### 10.1.6 THREADLOCAL 日志归因

`st_currentTask_` 是 THREADLOCAL 变量,每个工作线程独立记录当前任务。日志通过 `handleMessage` 归因到正确任务,即使多个任务并行执行也能准确区分。这比"传参式"日志归因更优雅,无需修改 Converter 接口。

#### 10.1.7 目录依赖的正则匹配

目录依赖使用 RE2 库做正则匹配,支持复杂模式:

- `.*\.dds$`:所有 .dds 文件
- `texture_\d+\.dds`:texture_0.dds, texture_1.dds, ...
- `(diffuse|normal)_.*\.dds`:diffuse_*.dds 或 normal_*.dds

RE2 的线性时间复杂度保证了用户提供的模式不会导致性能问题。

#### 10.1.8 GUI 与编译完全解耦

通过 TaskStore 信号槽 + MainMessageLoop Action 队列,GUI 线程与编译线程完全解耦:

- 编译线程触发信号 → 信号回调投递 Action 到 MainMessageLoop → UI 线程处理 Action 更新控件。
- GUI 操作(如暂停/恢复)通过 `compiler_.pause()/resume()` 线程安全调用。

这种设计让 GUI 永远不会阻塞编译,编译也不会卡死 UI。

### 10.2 注意事项

#### 10.2.1 反向依赖图的内存占用

`reverseDependencyMap_` 和 `forwardDependencyMap_` 会随任务数量线性增长。对于大型项目(数十万资产),可能占用数百 MB 内存。jit_compiler 没有提供"清理已完成任务依赖"的机制,长期运行可能内存膨胀。

**缓解方案**(用户侧):定期重启 jit_compiler。

#### 10.2.2 文件监听的延迟

`flushModificationMonitor()` 在每轮管理线程循环末尾调用,意味着文件变更最多有 1 秒 + 任务处理时间的延迟。对于快速连续修改(如编辑器自动保存),可能触发多次重建。

#### 10.2.3 命名管道的单机限制

命名管道(`\\.\pipe\`)仅支持同机通信,jit_compiler 无法跨机器服务。若需分布式编译,应使用 batch_compiler + 共享缓存。

#### 10.2.4 目录依赖的一次性匹配

目录依赖匹配后会从 `directoryDependencies_` 移除,直到任务完成后重新建立。这意味着:

- 任务正在处理时,目录内文件变更不会触发该任务的重建(因为依赖已移除)。
- 任务完成后重新建立依赖,后续变更才会触发。

这是有意设计(避免任务处理中重复触发),但用户可能感到"变更未响应"。

#### 10.2.5 requests_ 的内存累积

`requests_` 记录所有客户端请求,任务完成后才移除。若任务长时间未完成(如依赖缺失),`requests_` 会累积。极端情况下可能内存泄漏。

#### 10.2.6 静态互斥量的生命周期

`onTaskCompleted` 中的 `static SimpleMutex reverseDependencyMutex` 是函数局部静态变量,生命周期贯穿程序运行。多个 JITCompiler 实例(虽然实际只有一个)会共享此互斥量。这是有意设计(保护全局反向依赖图),但限制了多实例能力。

#### 10.2.7 CRITICAL 消息的处理

```cpp
#if !ASSET_PIPELINE_CAPTURE_ASSERTS
if (messagePriority == DebugMessagePriority::MESSAGE_PRIORITY_CRITICAL)
{
    return false;  // 不拦截,让其崩溃
}
#endif
```

默认情况下,CRITICAL 消息不被拦截,会触发崩溃。这对调试有利(保留现场),但生产环境可能导致 jit_compiler 意外退出。若需捕获,定义 `ASSET_PIPELINE_CAPTURE_ASSERTS`。

#### 10.2.8 WTL 的 Windows 依赖

jit_compiler 依赖 WTL(Windows Template Library),只能在 Windows 运行。跨平台构建需使用 batch_compiler。

### 10.3 与 batch_compiler 的协同

在实际项目中,batch_compiler 和 jit_compiler 通常配合使用:

1. **初次构建**:用 batch_compiler 全量编译,生成中间产物和缓存。
2. **日常开发**:启动 jit_compiler,基于已有缓存做增量编译。
3. **持续集成**:用 batch_compiler 做完整构建验证。

两者共享 `ContentAddressableCache`,确保缓存兼容。

### 10.4 性能优化建议

| 场景 | 优化建议 |
|------|----------|
| 大型项目首次启动 | 用 batch_compiler 预编译,jit_compiler 复用缓存 |
| 频繁文件变更 | 调整编辑器保存策略,避免连续触发 |
| 多客户端并发 | 增加 `-j` 线程数,但注意 Converter 的 THREAD_SAFE 标志 |
| 内存占用高 | 定期重启 jit_compiler,清理反向依赖图 |
| 网络资产 | jit_compiler 不支持网络路径,需本地映射 |

### 10.5 常见问题

**Q1: jit_compiler 启动后没有扫描到任务?**

A: 检查资源路径配置(`paths.xml`),确保 `BWResource::getPathNum()` 返回非零。扫描线程逆序遍历路径,若路径为空则无任务。

**Q2: 文件变更后没有触发重建?**

A: 检查:
1. `enableModificationMonitor(true)` 是否调用(main.cpp L31)。
2. 变更的文件是否在资源路径下(相对路径会被忽略)。
3. 任务是否已完成并建立反向依赖(`onTaskCompleted` 中读取 `.deps`)。

**Q3: 客户端连接后收不到资产?**

A: 检查:
1. 命名管道 ID 是否匹配(基于可执行文件路径哈希)。
2. `onAssetRequested` 是否调用了 `broadcastAsset`(找不到源文件或无 Converter 时直接广播)。
3. 任务是否卡在 `PROCESSING` 状态(Converter 异常)。

**Q4: 反向依赖图导致内存膨胀?**

A: 目前无内置清理机制,只能定期重启。可考虑修改源码,在任务长时间未触发时清理其反向依赖。

**Q5: Lock/Unlock 不生效?**

A: 检查客户端是否正确发送 `:Lock`/`:Unlock` 命令(注意冒号前缀)。`AssetServer::processCommand` 通过 `strncmp` 匹配命令字符串。

---

## 附录 A:核心文件清单

| 文件 | 行数 | 核心功能 |
|------|------|----------|
| `main.cpp` | 102 | WinMain 入口,双线程启动 |
| `jit_compiler.hpp` | 100 | JITCompiler 类声明(四重继承) |
| `jit_compiler.cpp` | 671 | JITCompiler 核心实现(反向依赖图/IPC/文件监听) |
| `jit_compiler_options.hpp` | 27 | JitCompilerOptions(扩展气泡通知选项) |
| `jit_compiler_options.cpp` | - | 选项实现 |
| `task_store.hpp` | 96 | TaskStore 任务存储声明 |
| `task_store.cpp` | - | TaskStore 实现(三态列表 + 信号槽) |
| `task_info.hpp` | 118 | TaskInfo 单任务信息 |
| `task_info.cpp` | - | TaskInfo 实现 |
| `task_fwd.hpp` | 33 | 前向声明 + TaskInfoState 枚举 |
| `main_window.hpp` | 127 | MainWindow 主对话框声明 |
| `main_window.cpp` | - | MainWindow 实现(WTL 消息处理) |
| `message_loop.hpp` | 35 | MainMessageLoop 消息循环 + Action 队列 |
| `message_loop.cpp` | - | MainMessageLoop 实现 |
| `signal.hpp` | - | Signal 信号槽实现 |
| `system_tray_icon.hpp` | 57 | SystemTrayIcon 系统托盘 |
| `system_tray_icon.cpp` | - | 系统托盘实现(三种状态图标 + 气泡) |
| `task_list_box.hpp` | - | TaskListBox 任务列表控件 |
| `large_task_list_box.hpp` | - | LargeTaskListBox 大任务列表(带排序) |
| `task_list_box_base.hpp` | - | TaskListBoxBase 基类 |
| `details_dialog.hpp` | - | DetailsDialog 任务详情 |
| `options_dialog.hpp` | - | OptionsDialog 选项配置 |
| `config_dialog.hpp` | - | ConfigDialog 资源路径配置 |
| `about_dialog.hpp` | - | AboutDialog 关于对话框 |
| `wtl.hpp` | - | WTL 头文件统一包含 |
| `app.rc` | - | Windows 资源文件 |
| `resource.h` | - | 资源 ID 定义 |

### 依赖库文件

| 文件 | 路径 | 核心功能 |
|------|------|----------|
| `asset_server.hpp` | `lib/asset_pipeline/` | AssetServer 基类(命名管道 IPC) |
| `asset_server.cpp` | `lib/asset_pipeline/` | AssetServer 实现(管道线程/Lock/Unlock) |
| `asset_pipe.hpp` | `lib/asset_pipeline/` | 协议常量(ASSET_PIPE_SIZE/LOCK/UNLOCK) |
| `asset_compiler.hpp` | `tools/asset_pipeline/compiler/` | AssetCompiler 基类 |
| `resource_modification_listener.hpp` | `lib/resmgr/` | 文件变更监听接口 |

---

## 附录 B:典型运行时序

### B.1 启动 + 首次扫描时序

```
T0: WinMain 启动
T1: init() → BWResource::init + enableModificationMonitor
T2: 创建 TaskStore / MainMessageLoop / JITCompiler / MainWindow
T3: options.apply(jitCompiler) → 设置路径/线程数
T4: jitCompiler.initPlugins() → 加载 Converter .dll
T5: jitCompiler.initCompiler() → 初始化 TaskFinder/TaskProcessor/线程池
T6: mainWindow.init() → 创建对话框 + 托盘图标 + 绑定信号
T7: 启动 scanningThread → scanningThreadMain()
      └─► 逆序遍历资源路径,taskFinder_.findTasks() 递归扫描
T8: 启动 managingThread → managingThreadMain()
      └─► event_.wait(1000) 阻塞等待
T9: messageLoop.run() → 主线程进入 Windows 消息循环

T10: scanningThread 扫描完成 → store_.scanningStopped() → UI 更新
T11: (若有扫描期间发现的任务) managingThread 被 event_ 唤醒 → processTasks()
```

### B.2 客户端请求资产时序

```
T0: 游戏客户端连接命名管道
T1: AssetServer::serverThreadFunc 接受连接 → 创建 pipeThread
T2: 客户端发送 "resources/models/hero.model"
T3: pipeThreadFunc 收到请求 → onAssetRequested("resources/models/hero.model")
T4: getSourceFile 反查源文件 → "resources/models/hero.model"
T5: taskFinder_.getTask 获取任务 T
T6: 任务 T 状态检查:
      - NEW → push_front 到队列,event_.set()
      - QUEUED → 移到队首
      - DONE 且无修改 → broadcastAsset 立即返回
      - DONE 有修改 → 记录 requests_,event_.set()
T7: managingThread 被 event_ 唤醒
T8: taskProcessor_.processTasks() → 派发任务 T 到工作线程
T9: 工作线程执行:
      - onTaskStarted → store_.setTaskCurrent(T) → UI 显示"处理中"
      - onPreCreateDependencies → 状态=GENERATING_DEPENDENCIES
      - Converter::createDependencies
      - onPostCreateDependencies → 状态=CHECKING
      - onPreConvert → 状态=CONVERTING
      - Converter::convert
      - onPostConvert → 状态=CHECKING
      - onTaskCompleted:
            ├─► 广播 requests_ 中匹配的资产 → broadcastAsset("resources/models/hero.model")
            ├─► store_.setTaskComplete(T) → UI 显示"已完成"
            └─► 读取 .deps 建立反向依赖
T10: 客户端 pipeThread 收到 broadcastAsset → 通知游戏客户端资产就绪
T11: 游戏客户端加载资产
```

### B.3 文件变更触发重建时序

```
T0: 用户在编辑器中保存 resources/textures/skin.dds
T1: BWResource 修改监听器检测到变更(下次 flushModificationMonitor 时)
T2: managingThread 循环:
      - processTasks() 完成
      - WaitForSingleObject(taskSemaphore_) 等待工作线程
      - flushModificationMonitor() → 触发 onResourceModified
T3: onResourceModified("resources/textures/", "skin.dds", ACTION_MODIFIED)
T4: purgeResource 清理缓存
T5: collectReverseDependencies("resources/textures/skin.dds", true, tasks)
      └─► reverseDependencyMap_["resources/textures/skin.dds"] = 
            [(hero.material, false), (npc.material, false)]
      └─► tasks = [hero.material, npc.material]
T6: collectReverseDependencies("resources/textures", "skin.dds", tasks)
      └─► 检查 directoryDependencies_,无匹配(假设无目录依赖)
T7: 对 tasks 中每个任务:
      - hero.material: 重置 status_=NEW,store_.resetTask,queueTask,event_.set()
      - npc.material: 同上
T8: managingThread 下一轮:
      - event_.wait() 立即返回
      - processTasks() 处理 hero.material 和 npc.material
      - 工作线程执行转换
      - onTaskCompleted 重建反向依赖
T9: (若有客户端请求) broadcastAsset 通知客户端
```

### B.4 Lock/Unlock 时序

```
T0: 游戏客户端准备加载资产,发送 ":Lock"
T1: AssetServer::processCommand → lock(hPipe)
T2: lockedPipes_.push_back(hPipe),size==1 → lock() → JITCompiler::lock()
T3: JITCompiler::lock() → AssetCompiler::pause()
      └─► 等待当前任务完成,暂停任务派发
T4: 客户端加载资产(此时 jit_compiler 不会写文件)
T5: 客户端发送 ":Unlock"
T6: AssetServer::processCommand → unlock(hPipe)
T7: lockedPipes_.erase(hPipe),empty() → unlock() → JITCompiler::unlock()
T8: JITCompiler::unlock() → AssetCompiler::resume()
      └─► 恢复任务派发

多客户端场景:
T0: 客户端 A 发送 ":Lock" → lockedPipes_=[A],pause()
T1: 客户端 B 发送 ":Lock" → lockedPipes_=[A,B],size!=1 不重复 pause
T2: 客户端 A 发送 ":Unlock" → lockedPipes_=[B],非空不 resume
T3: 客户端 B 发送 ":Unlock" → lockedPipes_=[],空 → resume()
```

### B.5 退出时序

```
T0: 用户点击托盘图标菜单"Quit"或关闭主窗口
T1: MainWindow::onMenuQuit/onClose → messageLoop 退出
T2: WinMain 中 messageLoop.run() 返回
T3: jitCompiler.stop()
      ├─► terminate() → 设置 terminating_ 标志
      │     ├─► scanningThread 循环检查 terminating() 退出
      │     └─► managingThread 循环检查 terminating() 退出
      └─► event_.set() → 唤醒 managingThread(若在 wait)
T4: scanningThread 退出
T5: managingThread 退出
T6: 工作线程(由 AssetCompiler 管理)完成当前任务后退出
T7: mainWindow.fini() → 销毁对话框、托盘图标
T8: jitCompiler.finiCompiler() → 清理 TaskFinder/TaskProcessor
T9: jitCompiler.finiPlugins() → 卸载 Converter .dll
T10: fini() → BWResource::fini + CoUninitialize
T11: WinMain 返回 exitCode
```

---

## 总结

jit_compiler 是 BigWorld Engine 工具链中**最复杂的资产编译工具**,通过四重继承(AssetCompiler + AssetServer + ResourceModificationListener + PluginLoader)整合了资产编译、IPC 服务、文件监听、插件加载四大能力。

其核心创新是**反向依赖图**(ReverseDependencyMap + ForwardDependencyMap),实现了 O(1) 的文件变更影响查找,使常驻增量编译成为可能。配合**双线程架构**(扫描 + 管理)和**事件驱动**循环,jit_compiler 能在 1 秒内响应文件变更和客户端请求。

**WTL GUI** 通过 TaskStore 信号槽 + MainMessageLoop Action 队列与编译线程完全解耦,提供实时任务列表、状态图标、气泡通知等反馈。**命名管道 IPC** 通过引用计数的 Lock/Unlock 机制,支持多客户端并发访问且避免读写冲突。

jit_compiler 与 batch_compiler 形成"常驻增量 + 一次性全量"的互补组合,共同覆盖了从日常开发到持续集成的全部资产编译场景。

---

*本文档基于 BigWorld Engine 14.4.1 源码分析撰写,代码行号引用均对应原始源文件。*
