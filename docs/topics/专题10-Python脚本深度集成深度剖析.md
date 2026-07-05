# 专题 10:Python 脚本深度集成深度剖析

> Python 集成是 BigWorld Engine 14.4.1 的核心特色之一。与同期引擎(Unreal 2、CRYENGINE 1、Gamebryo)将脚本视为"配置文件"或"事件回调表"不同,BigWorld 把 Python 当作**与 C++ 平级的一等公民**:所有游戏逻辑、实体生命周期、AI 决策、网络消息分发、数据库持久化、客户端输入处理都通过 Python 完成,C++ 只负责性能攸关的底层管线(网络、空间分割、内存管理、数学库)。这种"C++ 引擎 + Python 逻辑"的彻底分治,在 2000 年代早期 MMO 领域是极具前瞻性的设计。本专题以百科级深度剖析 BigWorld 14.4.1 中 **pyscript 库、PyObjectPlus 体系、ScriptObject 模型、类型转换系统、Personality、Pickler、PyObjectPtr 智能指针、Python 模块组织、实体类、方法调用流程、循环引用处理、GIL 与多线程、性能、边界情况、调试、与其它引擎对比** 等所有 Python 相关内容,涵盖完整源码、数据结构、算法步骤、边界情况、性能分析、与其他引擎对比。

---

## 目录

- [一、Python 集成概述与设计哲学](#一python-集成概述与设计哲学)
- [二、文件布局与构建结构](#二文件布局与构建结构)
- [三、pyscript 库核心:Script 命名空间](#三pyscript-库核心script-命名空间)
- [四、Script::init / fini 全流程](#四scriptinit--fini-全流程)
- [五、多解释器与线程模型](#五多解释器与线程模型)
- [六、PyObjectPlus 体系](#六pyobjectplus-体系)
- [七、Py_Header 宏家族深度剖析](#七py_header-宏家族深度剖析)
- [八、方法导出:从 PY_METHOD 到 PY_AUTO_METHOD](#八方法导出从-py_method-到-py_auto_method)
- [九、属性导出:PY_ATTRIBUTE 体系](#九属性导出py_attribute-体系)
- [十、ScriptObject 模型](#十scriptobject-模型)
- [十一、ScriptObject 派生类](#十一scriptobject-派生类)
- [十二、类型转换系统](#十二类型转换系统)
- [十三、PY_SCRIPT_CONVERTERS 宏机制](#十三py_script_converters-宏机制)
- [十四、Personality 系统](#十四personality-系统)
- [十五、Pickler 序列化系统](#十五pickler-序列化系统)
- [十六、PyObjectPtr 智能指针](#十六pyobjectptr-智能指针)
- [十七、WeakPyPtr 弱引用](#十七weakpyptr-弱引用)
- [十八、Python 模块组织](#十八python-模块组织)
- [十九、InitTimeJob / FiniTimeJob 体系](#十九inittimejob--finitimejob-体系)
- [二十、Python 实体类](#二十python-实体类)
- [二十一、Python 方法调用流程](#二十一python-方法调用流程)
- [二十二、ScriptModule 模块系统](#二十twscriptmodule-模块系统)
- [二十三、循环引用处理](#二十三循环引用处理)
- [二十四、GIL 与多线程](#二十四gil-与多线程)
- [二十五、性能分析](#二十五性能分析)
- [二十六、边界情况深度分析](#二十六边界情况深度分析)
- [二十七、调试支持](#二十七调试支持)
- [二十八、与其他引擎对比](#二十八与其他引擎对比)
- [二十九、设计哲学总结](#二十九设计哲学总结)
- [附录 A:关键文件路径速查](#附录-a关键文件路径速查)
- [附录 B:Py_Header 展开速查表](#附录-bpy_header-展开速查表)
- [附录 C:Script::setData/getData 类型表](#附录-cscriptsetdatagetdata-类型表)
- [附录 D:错误处理器策略表](#附录-d错误处理器策略表)
- [附录 E:术语表](#附录-e术语表)
- [附录 F:相关专题](#附录-f相关专题)

---

## 一、Python 集成概述与设计哲学

### 1.1 为什么用 Python

BigWorld Engine 在 2002 年首次发布时,Python 是脚本语言中相对小众的选择(当时主流是 Lua、UnrealScript、GameMonkey)。BigWorld 选择 Python 的核心理由有四:

1. **快速开发**:Python 的动态类型、REPL、丰富的标准库(`pickle`、`xml`、`threading`)让服务端逻辑的迭代速度远高于编译型语言。MMO 服务端每周需要热修逻辑,Python 脚本可以通过 `Personality::reload` 重新加载,而无需重启进程。
2. **可扩展性**:Python 的 C API 提供了完整的 `PyObject` 协议(对象、类型、引用计数、垃圾回收、迭代器、描述符),允许 C++ 引擎在最小阻抗下暴露任意对象。BigWorld 通过 `PyObjectPlus` 体系把整个 C++ 类层级(实体、矩阵、向量、空间、Mailbox、Watcher 等)双向映射到 Python。
3. **生态成熟**:Python 2 的 `cPickle` 模块提供了高效的二进制序列化,`traceback` 模块提供了运行时栈追踪,`weakref` 模块提供了弱引用,这些让 BigWorld 不必重新发明轮子。
4. **语法友好**:Python 的面向对象 + 缩进式语法让策划也能上手编写实体脚本,而 Lua 的"表 + 元表"伪面向对象语法对非程序员不友好。

### 1.2 C++ / Python 分治

BigWorld 的"分治"原则:

| 维度 | C++ 负责层 | Python 负责层 |
|------|----------|---------------|
| 性能要求 | 极高(每秒百万级调用) | 中等(每秒千级调用) |
| 网络层 | Mercury 协议、bundle 序列化、UDP 可靠传输 | 邮箱调用、消息分发回调 |
| 空间分割 | Cell 边界、AOI 半径、Ghost 划分 | 实体位置业务逻辑 |
| 内存管理 | 池化、内存追踪、Smart Pointer | Python 引用计数 + 周期 GC |
| 数学库 | Vector3、Matrix、四元数 SIMD | 调用 C++ 数学函数 |
| 实体逻辑 | 实体创建、销毁、Ghost 同步框架 | 实体方法、回调 |
| AI 决策 | 寻路、避障、空间查询 | 行为树节点、决策逻辑 |
| 持久化 | 数据库连接池、binary 流 | 实体字段持久化(pickle 协议) |
| 配置 | XML 解析(`.def`) | 实体配置回调 |

这种分治的关键是**双向调用接口**:
- C++ → Python:通过 `Script::call`、`Script::ask`、`ScriptObject::callMethod` 调用 Python 函数。
- Python → C++:通过 `PyObjectPlus` 导出的方法(`PY_METHOD`、`PY_AUTO_METHOD`)调用 C++ 实现。

### 1.3 与 Lua 集成的对比

| 维度 | BigWorld(Python) | 典型 Lua 集成(如 World of Warcraft) |
|------|-----------------|--------------------------------|
| 类型系统 | 强类型 + 类继承 | 弱类型 + 元表模拟 |
| 错误处理 | 异常 + traceback | 多返回值 + pcall |
| 序列化 | pickle 协议 | 自研 |
| 标准库 | 完整(os、sys、pickle、xml) | 精简(需嵌入 LuaXML 等) |
| 性能 | 慢(解释执行 + GIL) | 快(JIT LuaJIT) |
| 内存占用 | 高(每对象 ~50B) | 低(表 ~16B) |
| 调试器 | pdb、Winpdb | Decoda、LuaInspector |
| 多线程 | GIL 限制 | 多线程安全 |
| 引用计数 | 显式 INCREF/DECREF | 增量 GC |

BigWorld 的 Python 选择牺牲了部分性能,换来了**开发效率、调试便利、生态完整**的优势,这在 MMO 服务端 24×7 长期运行的场景下是合理的折中。

### 1.4 与其它引擎脚本集成对比

| 引擎 | 脚本语言 | 集成方式 | 双向调用 | 类型系统 |
|------|---------|---------|---------|---------|
| BigWorld 14.4.1 | Python 2.7 | PyObjectPlus + Script::getData/setData | 完全双向 | 强类型 |
| Unreal Engine 4 | C++ + Blueprints | UCLASS + UPROPERTY 反射 | 完全双向 | 强类型 |
| Unity 5 | C# (Mono) | Mono 运行时嵌入 | 完全双向 | 强类型 |
| CryEngine 3 | Lua + C# | LuaBinding + Mono | 半双向 | 弱类型 + 强类型 |
| Gamebryo | Lua | swig 风格 | 单向为主 | 弱类型 |

BigWorld 与 UE4/Unity 的关键区别在于:**BigWorld 用 Python 而非 C# 做"逻辑层语言"**。这意味着:
- BigWorld 的 Python 代码可以在不重新编译引擎的情况下热加载(`Personality::reload`)。
- 但 BigWorld 没有 UE4 的"蓝图可视化编程",所有逻辑都是 Python 文本。

---

## 二、文件布局与构建结构

### 2.1 pyscript 库文件布局

```
programming/bigworld/lib/pyscript/
├── pyscript_lib.hpp                    # 统一入口
├── pch.hpp / pch.cpp                   # 预编译头
├── compatibility.hpp                   # 跨版本兼容宏
├── keyword_parser.hpp                  # 关键字解析
├── script.hpp / script.cpp / script.ipp  # 核心:Script 命名空间 + setData/getData
├── pyobject_plus.hpp / pyobject_plus.cpp  # PyObjectPlus 基类
├── pyobject_base.hpp                  # PyTypeObject 工厂宏(PY_BASETYPEOBJECT)
├── pyobject_pointer.hpp                # PyObjectPtr 智能指针
├── py_factory_method_link.hpp / .cpp   # 工厂方法注册到模块
├── py_import_paths.hpp                 # Python 路径配置
├── py_callback.hpp / .cpp              # Python 回调封装
├── py_data_section.hpp / .cpp / .ipp  # PyDataSection(C++ DataSection 暴露)
├── py_logging.cpp                      # Python logging 桥接
├── py_memory_log.cpp                   # 内存日志
├── py_to_stl.hpp / .cpp / .ipp         # Python → STL 适配(PySequenceSTL/PyMappingSTL)
├── stl_to_py.hpp / .cpp / .ipp         # STL → Python 适配(PySTLSequence)
├── py_traceback.hpp / .cpp             # traceback 工具
├── py_debug_message_file_logger.*       # 调试消息文件日志
├── pywatcher.hpp / .cpp                # Watcher 的 Python 暴露
├── personality.hpp / .cpp              # Personality 系统
├── pickler.hpp / pickler.cpp           # Pickler 序列化包装
├── resource_table.hpp / .cpp           # 资源表
├── res_mgr_script.hpp / .cpp / .ipp    # ResMgr 模块(Python 的 ResMgr 模块)
├── script_events.hpp / .cpp            # 事件系统
├── script_math.hpp / .cpp              # 数学类型(Vector3、Matrix、PyVector)
├── python_input_substituter.*           # Python 输入替换
├── automation.hpp / .cpp               # 自动化测试支持
├── nomodule.mpp                         # "无模块"特殊处理
└── unit_test/                          # 单元测试
    ├── test_conversion.cpp             # 类型转换测试
    ├── test_extensions.cpp              # 扩展测试
    ├── test_pyobject_base.cpp           # PyObjectPlus 基础测试
    ├── test_python_and_stl.cpp          # Python-STL 互操作
    ├── test_python_integration.cpp      # Python 集成测试
    ├── test_py_output_writer.*          # 输出重定向测试
    ├── integer_range_checker.*          # 整数范围检查
    └── res/test_*.py                    # Python 测试脚本
```

### 2.2 script 库文件布局

```
programming/bigworld/lib/script/
├── script_lib.hpp                      # 统一入口
├── script_object.hpp                   # 派发宏:SCRIPT_PYTHON → py_script_object.hpp
├── py_script_object.hpp / .cpp / .ipp  # ScriptObject/ScriptModule/ScriptTuple/ScriptList/...
├── py_script_args.ipp                  # ScriptArgs
├── py_script_dict.ipp                  # ScriptDict
├── py_script_list.ipp                  # ScriptList
├── py_script_module.ipp                # ScriptModule(import/getOrCreate/reload)
├── py_script_sequence.ipp              # ScriptSequence
├── py_script_tuple.ipp                 # ScriptTuple
├── py_script_output_writer.*           # stdout/stderr 重定向
├── script_output_writer.hpp            # 输出写入器接口
├── script_output_hook.*                # 输出 hook
├── pickler.hpp                         # 高层 Pickler 接口(转发到 pyscript/pickler.cpp)
├── init_time_job.hpp / .cpp            # InitTimeJob/FiniTimeJob
├── first_include.hpp                   # 强制首包含
└── oc_script_object.hpp / .mm          # Objective-C 版本(macOS/iOS)
```

### 2.3 构建产物

`pyscript` 库在 CMake 中作为静态库 `bigworld_pyscript` 编译,链接到所有进程(CellApp、BaseApp、Client、DBApp、Tools)。`script` 库是 `pyscript` 的上层封装,提供更高层的 `ScriptObject` 模型。两者关系:

```
应用代码
   │
   ▼
script 库(ScriptObject/ScriptModule/ScriptArgs)
   │
   ▼
pyscript 库(PyObjectPlus/Script::init/Pickler/Personality)
   │
   ▼
Python C API(Python 2.7)
```

---

## 三、pyscript 库核心:Script 命名空间

### 3.1 Script 命名空间总览

`Script` 命名空间是 Python 集成的入口,定义在 `lib/pyscript/script.hpp`。它包含:

1. **生命周期管理**:`init()`、`fini()`、`isFinalised()`。
2. **解释器管理**:`createInterpreter()`、`destroyInterpreter()`、`swapInterpreter()`、`AutoInterpreterSwapper`。
3. **线程支持**:`initThread()`、`finiThread()`、`acquireLock()`、`releaseLock()`。
4. **GIL 与 Hitch 检测**:`hasHitchDetection()`、`tickHitchDetection()`、`disablePythonGarbage()`。
5. **调用接口**:`call()`、`ask()`、`runString()`、`printStack()`、`newClassInstance()`、`unloadModule()`。
6. **类型转换**:`setData()`、`getData()`、`getReadOnlyData()`、`getDataRef()`、`setDataSequence()`、`setDataMapping()`、`setAnswer()`、`argCountError()`。
7. **辅助**:`buildReduceResult()`、`newPyNoneRef()`、`compare()`、`zeroValueName<T>()`、`getNestedValue()`、`getValueFromDict()`。

`Script` 命名空间是一个**纯函数集**,所有方法都是 `static` 风格的自由函数(在命名空间内),没有类实例。这是 BigWorld 设计哲学的体现:Python 集成是"全局服务",不应该被实例化。

### 3.2 全局状态

`script.cpp` 内部维护以下全局状态:

```cpp
// script.cpp L87-92
static PyObject * s_pOurInitTimeModules;              // 主解释器初始化时的 sys.modules 快照
static PyThreadState * s_pMainThreadState;            // 主线程的 PyThreadState
static THREADLOCAL( PyThreadState * ) s_defaultContext; // 当前线程的默认 Python 上下文
static bool s_isFinalised = false;
static bool s_isInitalised = false;
```

| 变量 | 类型 | 作用 |
|------|------|------|
| `s_pOurInitTimeModules` | `PyObject*`(dict) | 缓存主解释器初始化时的 `sys.modules`,新解释器创建时合并这个 dict |
| `s_pMainThreadState` | `PyThreadState*` | 主线程的 Python 状态,用于新解释器共享 `interp` |
| `s_defaultContext` | `THREADLOCAL PyThreadState*` | 当前线程的"默认" Python 上下文,`acquireLock` 时切换到这个 |
| `s_isFinalised` | `bool` | Script 是否已 fini |
| `s_isInitalised` | `bool` | Script 是否已 init |

`s_defaultContext` 使用 `THREADLOCAL` 宏,保证每个 C++ 线程都有自己的 Python 上下文。这是 BigWorld 实现多线程 Python 的关键。

### 3.3 g_scriptArgc / g_scriptArgv

```cpp
// script.hpp L48-49
namespace Script {
    extern int g_scriptArgc;
    extern char * g_scriptArgv[];
}
```

这是 BigWorld 给 Python 的 `sys.argv`,在 `Script::init` 中通过 `PySys_SetArgv(g_scriptArgc, g_scriptArgv)` 设置。应用启动时通过命令行参数填充。

---

## 四、Script::init / fini 全流程

### 4.1 Script::init 完整流程

`Script::init` 是 Python 集成的总入口,定义在 `script.cpp` L334-484。流程如下:

```cpp
// script.cpp L334-484(简化)
bool Script::init( const PyImportPaths & appPaths, const char * componentName )
{
    if (s_isInitalised) return true;

    // 1. 安装 Python 内存钩子(可选,默认禁用)
    // 让 Python 的 malloc/free 走 BigWorld 的 BW::Allocator
    BW_Py_Hooks pythonHooks;
    bw_zero_memory( &pythonHooks, sizeof(pythonHooks) );
    pythonHooks.ignoreAllocsBeginHook = BW::Allocator::allocTrackingIgnoreBegin;
    pythonHooks.ignoreAllocsEndHook = BW::Allocator::allocTrackingIgnoreEnd;
    BW_Py_setHooks( &pythonHooks );

    // 2. 构建搜索路径(资源路径 + common + Lib + 平台 DLLs)
    PyImportPaths sysPaths( DELIM );
    sysPaths.append( appPaths );
    sysPaths.addResPath( commonPath );
    sysPaths.addResPath( commonPath + "/Lib" );
    sysPaths.addResPath( serverCommonPath );  // 服务端平台扩展
    // 客户端:sysPaths.addResPath( entitiesClientPath + "/DLLs/" + platform );

    // 3. 设置 Python 全局标志
    Py_FrozenFlag = 1;        // 抑制 getpath.c 的报错
    Py_TabcheckFlag = 1;      // Tab/空格混用警告
    Py_NoSiteFlag = 1;        // 不自动 import site
    Py_IgnoreEnvironmentFlag = 1; // 忽略 PYTHON* 环境变量

    // 4. 初始化 Python 解释器
    Py_Initialize();

    // 5. 重定向 stdout/stderr
    new ScriptOutputWriter(); // 把 sys.stdout/sys.err 接到 BigWorld 的日志系统

    // 6. 设置 sys.argv
    if (g_scriptArgc)
        PySys_SetArgv( g_scriptArgc, g_scriptArgv );

    // 7. 设置 sys.path
    PyObject * pSys = sysPaths.pathAsObject();
    int result = PySys_SetObject( "path", pSys );
    Py_DECREF( pSys );
    if (result != 0) {
        ERROR_MSG( "Script::init: Unable to assign sys.path\n" );
        return false;
    }

    // 8. 安装 Python 性能/栈分析 hook
    #if ENABLE_STACK_TRACKER || ENABLE_PROFILER
        PyEval_SetProfile( &profileFunc, NULL );
    #endif

    // 9. 运行所有 InitTimeJob(注册模块、方法、属性)
    runInitTimeJobs();

    // 10. 禁用 Python GC(BigWorld 默认关闭 gc 模块,自己管理生命周期)
    disablePythonGarbage();

    // 11. 创建/获取 BigWorld 模块,设置 component 属性
    ScriptModule bigWorld = ScriptModule::getOrCreate( "BigWorld",
        ScriptErrorPrint( "Failed to create BigWorld module" ) );
    bigWorld.setAttribute( "component",
        ScriptString::create( componentName ),
        ScriptErrorPrint() );
    // 这让 Python 脚本能查询:BigWorld.component == 'cell' / 'base' / 'client' / 'database' / 'bot'

    // 12. 缓存初始化时的 sys.modules,供子解释器继承
    s_pOurInitTimeModules = PyDict_Copy( PySys_GetObject( "modules" ) );
    s_pMainThreadState = PyThreadState_Get();
    s_defaultContext = s_pMainThreadState;
    PyEval_InitThreads();

    // 13. 让主线程空闲时自动释放/获取 GIL
    BWConcurrency::setMainThreadIdleFunctions(
        &Script::releaseLock, &Script::acquireLock );

    s_isInitalised = true;

    // 14. 导入 bw_site 模块(站点特定代码)
    if (!ScriptModule::import( "bw_site", ScriptErrorPrint(...) ))
        return false;

    // 15. 初始化 Pickler
    if (!Pickler::init()) {
        ERROR_MSG( "Script::init: Pickler failed to initialise\n" );
        return false;
    }

    return true;
}
```

**关键步骤详解**:

**Step 9 — `runInitTimeJobs`**:这是 BigWorld Python 集成的"魔法"。所有用 `PY_MODULE_FUNCTION`、`PY_AUTO_MODULE_FUNCTION`、`PY_FACTORY`、`PY_MODULE_ATTRIBUTE` 等宏声明的静态对象,会在 `Script::init` 之前注册到 `s_initTimeJobsMap`,在 `runInitTimeJobs()` 调用时统一执行 `init()` 把自己注册到对应模块。这避免了"模块必须在哪个文件里初始化"的中心化要求,允许任意 .cpp 文件通过宏把自己的方法注册到 BigWorld 模块。

**Step 10 — `disablePythonGarbage`**:BigWorld 默认关闭 Python 周期 GC。原因有二:
- 周期 GC 会触发 `tp_traverse`,如果 PyObjectPlus 子类没有正确实现 `pyTraverse`,会导致野指针。
- 周期 GC 的不可预测性影响 MMO 服务端的 tick 抖动。
BigWorld 通过 `PyObjectPtr` 智能指针 + `WeakPyPtr` 弱引用 + 显式 `Py_DECREF` 来管理生命周期,大部分对象不需要周期 GC。

**Step 13 — 主线程空闲函数**:`BWConcurrency::setMainThreadIdleFunctions` 是关键的性能优化。它告诉主线程的"空闲等待"(如 `select`、`sleep`、`WaitForSingleObject`)函数:进入空闲时调用 `releaseLock` 释放 GIL,离开空闲时调用 `acquireLock` 重新获取 GIL。这让其它线程能在主线程阻塞 I/O 时执行 Python 代码,显著提高多线程利用率。

### 4.2 Script::fini 流程

`Script::fini` 定义在 `script.cpp` L513-572:

```cpp
void Script::fini( bool shouldFinalise )
{
    if (!s_isInitalised) return;

    // 1. 关闭性能分析
    #if ENABLE_STACK_TRACKER || ENABLE_PROFILER
        PyEval_SetProfile( NULL, NULL );
    #endif

    // 2. 停止所有后台任务(它们可能持有 PyObject 或脚本回调)
    if (FileIOTaskManager::pInstance() != NULL)
        FileIOTaskManager::instance().stopAll();
    if (BgTaskManager::pInstance() != NULL)
        BgTaskManager::instance().stopAll();

    // 3. 重置主线程空闲函数
    BWConcurrency::setMainThreadIdleFunctions( &NoOp, &NoOp );

    // 4. 反初始化 Pickler(DECREF dumps/loads 函数)
    Pickler::finalise();

    // 5. 运行所有 FiniTimeJob(Personality::onFini 在这里调用)
    runFiniTimeJobs();

    // 6. 释放 sys.modules 快照
    if (s_pOurInitTimeModules != NULL) {
        Py_DECREF( s_pOurInitTimeModules );
        s_pOurInitTimeModules = NULL;
    }

    // 7. Watcher 子系统清理
    #if ENABLE_WATCHERS
        Watcher::fini();
    #endif

    // 8. 调用 Py_Finalize(可选)
    if (shouldFinalise) {
        PyObject * modules = PyImport_GetModuleDict();
        while (PyGC_Collect() > 0);  // 强制 GC 清理循环引用
        PyObject * value = PyDict_GetItemString( modules, "__main__" );
        if (value != NULL && PyModule_Check( value )) {
            _PyModule_Clear( value );
            PyDict_SetItemString( modules, "__main__", Py_None );
        }
        Py_Finalize();
    }

    s_isFinalised = true;
}
```

**关键点 — `Personality::onFini`**:在 step 5,`runFiniTimeJobs` 会调用 `PersonalityFiniTimeJob::fini`,它会调用 `Personality::instance().callMethod("onFini")`。这给 Python 脚本一个清理资源(关闭文件、释放连接)的机会。`PersonalityFiniTimeJob` 在 `Personality::callOnInit` 时通过 `new PersonalityFiniTimeJob()` 注册,优先级 `INT_MAX` 表示最后运行。

**关键点 — `Py_Finalize` 不可重入**:`shouldFinalise` 默认为 `true`,但客户端在作为 Python 模块嵌入时(`BWCLIENT_AS_PYTHON_MODULE`),不能调用 `Py_Finalize`(因为是宿主 Python 进程)。所以 `#if !BWCLIENT_AS_PYTHON_MODULE` 包裹了 `Py_Finalize` 调用。

---

## 五、多解释器与线程模型

### 5.1 多解释器支持

BigWorld 支持在主解释器之外创建多个子解释器。`Script::createInterpreter` 定义在 `script.cpp` L593-619:

```cpp
PyThreadState* Script::createInterpreter()
{
    PyThreadState* 	pCurInterpreter = PyThreadState_Get();
    PyObject * 		pCurPath = PySys_GetObject( "path" );

    PyThreadState* pNewInterpreter = Py_NewInterpreter();

    if (pNewInterpreter) {
        new ScriptOutputWriter(); // 每个解释器独立的 stdout/stderr
        PySys_SetObject( "path", pCurPath );
        // 把主解释器的 sys.modules 复制过来(让 BigWorld 模块在新解释器可用)
        PyDict_Merge( PySys_GetObject( "modules" ), s_pOurInitTimeModules, 0 );
        PyThreadState* pSwapped = PyThreadState_Swap( pCurInterpreter );
        // 恢复原解释器
    }
    return pNewInterpreter;
}
```

子解释器共享底层 C 库但独立的 `sys.modules`、`__builtins__`、`__main__`。这用于:
- 工具进程同时运行多个独立脚本环境(如 process_defs 工具)。
- 单元测试隔离(每个测试用例一个子解释器)。

### 5.2 AutoInterpreterSwapper

`script.hpp` L72-83 定义了 RAII 包装:

```cpp
class AutoInterpreterSwapper
{
    PyThreadState*	pSwappedOutInterpreter_;
public:
    explicit AutoInterpreterSwapper( PyThreadState* pNewInterpreter ) :
        pSwappedOutInterpreter_( swapInterpreter( pNewInterpreter ) )
    {}
    ~AutoInterpreterSwapper()
    {
        swapInterpreter( pSwappedOutInterpreter_ );
    }
};
```

用法:

```cpp
{
    AutoInterpreterSwapper swap( pWorkerInterpreter );
    // 当前线程在 pWorkerInterpreter 上下文
    Script::runString( "print 'hello from worker'", true );
}
// 自动切回原解释器
```

### 5.3 线程初始化

`Script::initThread` 定义在 `script.cpp` L661-701:

```cpp
void Script::initThread( bool plusOwnInterpreter )
{
    IF_NOT_MF_ASSERT_DEV( s_defaultContext == NULL )
    {
        MF_EXIT( "trying to initialise scripting when already initialised" );
    }

    PyEval_AcquireLock();   // 获取 GIL

    PyThreadState * newTState = NULL;

    if (plusOwnInterpreter) {
        // 模式 A:新线程有自己的子解释器
        newTState = Py_NewInterpreter();
        // 设置 sys.path 与主线程一致
        PyObject * pMainPyPath = PyDict_GetItemString(
            s_pMainThreadState->interp->sysdict, "path" );
        PySys_SetObject( "path", pMainPyPath );
        // 继承主线程的模块
        PyDict_Merge( PySys_GetObject( "modules" ), s_pOurInitTimeModules, 0 );
    } else {
        // 模式 B:新线程共享主解释器,只是新建 PyThreadState
        newTState = PyThreadState_New( s_pMainThreadState->interp );
    }

    PyEval_ReleaseLock();

    s_defaultContext = newTState;
    Script::acquireLock();  // 重新获取 GIL,新线程进入 Python 上下文
}
```

模式 A 用于完全独立的脚本环境(如 Bot 进程的多个独立 Bot 实例),模式 B 用于共享模块体系的多线程(如 CellApp 的 worker 线程)。

### 5.4 acquireLock / releaseLock

```cpp
// script.cpp L748-774
void Script::acquireLock()
{
    if (s_defaultContext == NULL) return;
    PyEval_RestoreThread( s_defaultContext );  // 获取 GIL,设置当前线程状态
}

void Script::releaseLock()
{
    if (s_defaultContext == NULL) return;
    PyThreadState * oldState = PyEval_SaveThread();  // 释放 GIL,清除当前线程状态
    IF_NOT_MF_ASSERT_DEV( oldState == s_defaultContext )
    {
        MF_EXIT( "releaseLock: default context is incorrect" );
    }
}
```

注意:`s_defaultContext` 是 `THREADLOCAL`,所以每个 C++ 线程都有独立的"默认 Python 上下文"。这是 BigWorld 多线程 Python 的关键。

---

## 六、PyObjectPlus 体系

### 6.1 PyObjectPlus 是什么

`PyObjectPlus` 是 BigWorld 所有 C++ → Python 暴露类型的根基类,定义在 `lib/pyscript/pyobject_plus.hpp` L980-1046:

```cpp
class PyObjectPlus : public PyObject
{
    Py_Header( PyObjectPlus, PyObjectPlus )  // 必须的第一个宏

public:
    PyObjectPlus( PyTypeObject * pType, bool isInitialised = false );

    void incRef() const           { Py_INCREF( (PyObject*)this ); }
    void decRef() const           { Py_DECREF( (PyObject*)this ); }
    Py_ssize_t refCount() const   { return ((PyObject*)this)->ob_refcnt; }

    ScriptObject pyGetAttribute( const ScriptString & attrObj );
    bool pySetAttribute( const ScriptString & attrObj, const ScriptObject & value );
    bool pyDelAttribute( const ScriptString & attrObj );
    void pyDel();

    PyObject * pyRepr();
    const char * typeName() const { return ob_type->tp_name; }

    void pyAdditionalMembers( const ScriptList & pList ) const {}
    void pyAdditionalMethods( const ScriptList & pList ) const {}

    static PyObject * _pyNew( PyTypeObject * t, PyObject *, PyObject * );
    static PyObjectPtr coerce( PyObject * pObject ) { return pObject; }
    static This * getSelf( PyObject * pObject ) {
        return static_cast< This * >( pObject );
    }

    static const PyGetSetDef * searchAttributes( const PyGetSetDef *, const char *);
    static const PyMethodDef * searchMethods( const PyMethodDef *, const char * );

protected:
    ~PyObjectPlus();  // protected:只能由 Python 引用计数清零时调用
};
```

`PyObjectPlus` 直接继承 `PyObject`(Python C API 的根结构),意味着每个 `PyObjectPlus` 实例在内存布局上就是一个合法的 `PyObject`。这是 BigWorld 与其它绑定库(如 pybind11)的关键区别——**BigWorld 不包装 PyObject,而是直接"是" PyObject**。这避免了双重指针解引用,但要求所有子类的第一个成员必须是 `PyObject` 头。

### 6.2 Py_Header 宏的作用

`Py_Header( CLASS, SUPER_CLASS )` 宏展开后,会向类中注入:

1. **`_tp_dealloc`**:Python 引用计数归零时的回调,调用 `pyDel()` + `delete this`。
2. **`_tp_getattro`**:属性获取的入口,转发到 `pyGetAttribute`。
3. **`_tp_setattro`**:属性设置的入口,转发到 `pySetAttribute`/`pyDelAttribute`。
4. **`_tp_repr`**:`repr(obj)` 的入口,转发到 `pyRepr`。
5. **`s_type_`**:该类的 `PyTypeObject` 静态实例。
6. **`Check(PyObject*)`**:类型检查函数,基于 `PyObject_TypeCheck`。
7. **`Super`**:超类 typedef,供 `PY_TYPEOBJECT` 宏设置 `tp_base`。
8. **`This`**:自身 typedef,供宏内部引用。
9. **`s_getMethodDefs()` / `s_getAttributeDefs()`**:返回方法/属性表。
10. **`pyGet___members__` / `pyGet___methods__`**:兼容旧版 Python 的内省协议。

完整展开见 [附录 B](#附录-bpy_header-展开速查表)。

### 6.3 构造与析构

```cpp
// pyobject_plus.cpp L51-62
PyObjectPlus::PyObjectPlus( PyTypeObject * pType, bool isInitialised )
{
    if (PyType_Ready( pType ) < 0) {
        ERROR_MSG( "PyObjectPlus: Type %s is not ready\n", pType->tp_name );
    }
    if (!isInitialised) {
        PyObject_Init( this, pType );  // 初始化 ob_refcnt=1, ob_type=pType
    }
}

// pyobject_plus.cpp L69-75
PyObjectPlus::~PyObjectPlus()
{
    MF_ASSERT_DEV(this->ob_refcnt == 0);
#ifdef Py_TRACE_REFS
    MF_ASSERT( _ob_next == NULL && _ob_prev == NULL );
#endif
}
```

`isInitialised` 参数用于区分两种构造场景:
- **C++ `new` 创建**:`isInitialised=false`,`PyObject_Init` 设置 `ob_refcnt=1`。
- **Python `PyType_GenericAlloc` 创建**:`isInitialised=true`,Python 已经初始化了 `PyObject` 头,无需重复。

析构时断言 `ob_refcnt == 0`,防止 C++ 端误用 `delete` 释放还被 Python 引用的对象。

### 6.4 _tp_dealloc 流程

`Py_Header` 展开的 `_tp_dealloc`:

```cpp
static void _tp_dealloc( PyObject * pObj )
{
    static_cast< CLASS * >( pObj )->pyDel();   // 1. 业务清理(可重写)
    delete static_cast< CLASS * >( pObj );     // 2. 析构 + 释放内存
}
```

`pyDel()` 是一个空函数,子类可重写(如 Entity 类清理资源)。然后 `delete` 调用析构函数(protected ~PyObjectPlus())和 `operator delete`。

### 6.5 pyGetAttribute / pySetAttribute

`PyObjectPlus` 提供的默认实现:

```cpp
// pyobject_plus.cpp L89-113
ScriptObject PyObjectPlus::pyGetAttribute( const ScriptString & attrObj )
{
    return ScriptObject(
        PyObject_GenericGetAttr( this, attrObj.get() ),
        ScriptObject::FROM_NEW_REFERENCE );
}

bool PyObjectPlus::pySetAttribute( const ScriptString & attrObj,
    const ScriptObject & value )
{
    return (PyObject_GenericSetAttr( this, attrObj.get(), value.get() ) == 0);
}

bool PyObjectPlus::pyDelAttribute( const ScriptString & attrObj )
{
    return this->pySetAttribute( attrObj, ScriptObject() );  // del = set None
}
```

默认实现使用 Python 标准的 `PyObject_GenericGetAttr`,它会:
1. 在 `tp_getset` 表中查找(即 `PY_ATTRIBUTE` 注册的属性)。
2. 在 `tp_methods` 表中查找(即 `PY_METHOD` 注册的方法)。
3. 在 `__dict__` 中查找(动态属性)。

子类可以重写 `pyGetAttribute`/`pySetAttribute` 来拦截属性访问。例如 `PyVector` 重写 `pyGetAttribute` 来支持 `x/y/z/w` 属性的快速路径(绕过 `tp_getset` 表查找)。

### 6.6 pyRepr 默认实现

```cpp
// pyobject_plus.cpp L119-131
PyObject * PyObjectPlus::pyRepr()
{
    char str[512];
    bw_snprintf( str, sizeof(str),
        "%s at 0x%p",
        this->typeName(), this );
    return PyString_FromString( str );
}
```

默认 `repr(obj)` 返回 `"<ClassName at 0x12345678>"`。子类可重写以提供更有意义的表示。

### 6.7 searchAttributes / searchMethods

```cpp
// pyobject_plus.cpp L154-179
const PyGetSetDef * PyObjectPlus::searchAttributes( const PyGetSetDef *attrs,
    const char *name )
{
    for (; attrs->name != NULL; attrs++) {
        if (strcmp( attrs->name, name ) == 0) {
            return attrs;
        }
    }
    return NULL;
}

const PyMethodDef * PyObjectPlus::searchMethods( const PyMethodDef *methods,
    const char *name )
{
    for (; methods->ml_name != NULL; methods++) {
        if (strcmp( methods->ml_name, name ) == 0) {
            return methods;
        }
    }
    return NULL;
}
```

这两个静态方法用于在父类链上查找属性/方法。`isAdditionalProperty<PyClass>(name)` 模板函数使用它们判断某属性是否是"内置"的(避免子类动态属性覆盖内置)。

### 6.8 PyObjectPlusWithWeakReference

`pyobject_plus.hpp` L1130-1143 提供了支持弱引用的版本:

```cpp
class PyObjectPlusWithWeakReference : public PyObjectPlus
{
    Py_Header( PyObjectPlusWithWeakReference, PyObjectPlus )
    PY_WEAK_REFERENCABLE( PyObjectPlusWithWeakReference )

public:
    PyObjectPlusWithWeakReference( PyTypeObject * pType ) :
        PyObjectPlus( pType ),
        _py_pWeakRefList()
    {}
    virtual ~PyObjectPlusWithWeakReference() {}
};
```

`PY_WEAK_REFERENCABLE` 宏向类中添加:
- `PyObject * _py_pWeakRefList;` — 弱引用链表头。
- `PyWeakRefListManager<CLASS> _py_weakRefListManager;` — RAII 管理器,析构时调用 `PyObject_ClearWeakRefs`。

子类还需用 `PY_TYPEOBJECT_WITH_WEAKREF` 声明类型对象,这会设置 `tp_weaklistoffset` 为 `_py_pWeakRefList` 在对象内的偏移量。

### 6.9 PY_FAKE_PYOBJECTPLUS_BASE

`pyobject_plus.hpp` L1159-1176 提供了"伪 PyObjectPlus"宏,让不是真正 Python 对象的类也能用 `PY_ATTRIBUTE`/`PY_METHOD` 宏:

```cpp
#define PY_FAKE_PYOBJECTPLUS_BASE_DECLARE()                             \
    public:                                                             \
        static void _tp_dealloc( PyObject * ) { }                       \
        static PyObject * _tp_getattro( PyObject *, PyObject * )        \
            { return NULL; }                                            \
        static int _tp_setattro( PyObject *, PyObject *, PyObject * )   \
            { return -1; }                                              \
        static PyObject * _tp_repr( PyObject * )                        \
            { return NULL; }                                            \
        static PyObject * _pyNew( PyTypeObject * )                       \
            { return NULL; }                                            \
        private:
```

这用于"扩展"PyObjectPlus 子类的非 Python 成员对象(如 Entity 的某些组件),让它们也能用 `PY_AUTO_METHOD_DECLARE` 等宏定义方法签名(但不会被实际调用)。

---

## 七、Py_Header 宏家族深度剖析

### 7.1 Py_Header 完整展开

`Py_Header(CLASS, SUPER_CLASS)` 宏是 `PyObjectPlus` 子类的**第一个声明**,展开后注入约 50 行代码:

```cpp
#define Py_Header( CLASS, SUPER_CLASS )                                    \
    public:                                                                \
        static void _tp_dealloc( PyObject * pObj )                         \
        {                                                                  \
            static_cast< CLASS * >( pObj )->pyDel();                       \
            delete static_cast< CLASS * >( pObj );                         \
        }                                                                  \
                                                                           \
        static PyObject * _tp_getattro( PyObject * pObj, PyObject * name ) \
        {                                                                  \
            return static_cast<CLASS*>(pObj)->pyGetAttribute(             \
                ScriptString( name, ScriptObject::FROM_BORROWED_REFERENCE )\
                ).newRef();                                               \
        }                                                                  \
                                                                           \
        static int _tp_setattro( PyObject * pObj, PyObject * name,         \
            PyObject * value )                                            \
        {                                                                  \
            ScriptString attr( name, ScriptObject::FROM_BORROWED_REFERENCE ); \
            ScriptObject newValue( value, ScriptObject::FROM_BORROWED_REFERENCE ); \
            return (value != NULL) ?                                       \
                (static_cast<CLASS*>(pObj)->pySetAttribute( attr, newValue ) ? 0 : -1) : \
                (static_cast<CLASS*>(pObj)->pyDelAttribute( attr ) ? 0 : -1); \
        }                                                                  \
                                                                           \
        static PyObject * _tp_repr( PyObject * pObj )                      \
        {                                                                  \
            return static_cast<CLASS *>(pObj)->pyRepr();                   \
        }                                                                  \
                                                                           \
    Py_InternalHeader( CLASS, SUPER_CLASS )
```

### 7.2 Py_InternalHeader

```cpp
#define Py_InternalHeader( CLASS, SUPER_CLASS )                           \
    public:                                                               \
        static PyTypeObject s_type_;                                      \
                                                                          \
        static bool Check( PyObject * pObject )                            \
        {                                                                 \
            if (pObject)                                                  \
                return PyObject_TypeCheck( pObject, &s_type_ );           \
            return false;                                                 \
        }                                                                 \
        static bool Check( const ScriptObject & pObject )                 \
        {                                                                 \
            return CLASS::Check( pObject.get() );                         \
        }                                                                 \
                                                                          \
        typedef SUPER_CLASS Super;                                         \
                                                                          \
    Py_CommonHeader( CLASS )
```

关键点:
- `s_type_` 是该类的 `PyTypeObject` 静态实例,由 `PY_TYPEOBJECT` 宏填充字段。
- `Check(PyObject*)` 用 `PyObject_TypeCheck` 检查是否是该类或子类的实例(支持继承)。
- `Super` typedef 让 `PY_TYPEOBJECT` 宏能引用父类(`tp_base = &Super::s_type_`)。

### 7.3 Py_CommonHeader

```cpp
#define Py_CommonHeader( CLASS )                                          \
    private:                                                              \
        typedef CLASS This;                                               \
                                                                          \
    public:                                                               \
        static PyMethodDef * s_getMethodDefs();                           \
        static PyGetSetDef * s_getAttributeDefs();                        \
                                                                          \
        PyObject * pyGet___members__()                                    \
        {                                                                 \
            ScriptList pList = ScriptList::create();                      \
            this->pyAdditionalMembers( pList );                           \
            return pList.newRef();                                        \
        }                                                                 \
        PY_RO_ATTRIBUTE_SET( __members__ )                               \
                                                                          \
        PyObject * pyGet___methods__()                                    \
        {                                                                 \
            ScriptList pList = ScriptList::create();                      \
            this->pyAdditionalMethods( pList );                           \
            return pList.newRef();                                        \
        }                                                                 \
        PY_RO_ATTRIBUTE_SET( __methods__ )                               \
                                                                          \
    private:
```

`__members__` 和 `__methods__` 是 Python 2 的旧式内省协议(现已被 `__dir__` 取代)。`pyAdditionalMembers` / `pyAdditionalMethods` 是虚函数,子类可重写以补充自定义成员(如 `PyDataSection` 重写以暴露子节点名)。

### 7.4 Py_FakeHeader

`Py_FakeHeader(CLASS, SUPER_CLASS)` 用于不是 `PyObjectPlus` 子类但需要 `typeName()`:

```cpp
#define Py_FakeHeader( CLASS, SUPER_CLASS )                               \
    public:                                                                \
        const char * typeName() const { return #CLASS; }                   \
    Py_InternalHeader( CLASS, SUPER_CLASS )
```

它跳过了 `_tp_dealloc`/`_tp_getattro` 等真正需要 `PyObject` 内存布局的部分。

### 7.5 PY_TYPEOBJECT 宏家族

`PY_TYPEOBJECT` 是填充 `PyTypeObject` 字段的宏,有多种变体:

| 宏 | 用途 |
|----|------|
| `PY_TYPEOBJECT(THIS_CLASS)` | 基础版,只设置 `tp_base = &Super::s_type_` |
| `PY_TYPEOBJECT_WITH_DOC(THIS_CLASS, DOC)` | 带 docstring |
| `PY_TYPEOBJECT_WITH_SEQUENCE(THIS_CLASS, SEQ)` | 支持 `__getitem__`/`__len__` |
| `PY_TYPEOBJECT_WITH_MAPPING(THIS_CLASS, MAP)` | 支持 `__getitem__`(字典风格) |
| `PY_TYPEOBJECT_WITH_CALL(THIS_CLASS)` | 支持 `obj(args)` |
| `PY_TYPEOBJECT_WITH_ITER(THIS_CLASS, GETITER, ITERNEXT)` | 支持迭代器协议 |
| `PY_TYPEOBJECT_WITH_WEAKREF(THIS_CLASS)` | 支持弱引用 |

`PY_GENERAL_TYPEOBJECT_WITH_BASE_WITH_NAME(THIS_CLASS, BASE, NAME)` 是低层宏,展开为完整的 `PyTypeObject` 结构初始化:

```cpp
PyTypeObject THIS_CLASS::s_type_ =
{
    PyObject_HEAD_INIT(&PyType_Type)
    0,                                  // ob_size
    const_cast< char * >( NAME ),       // tp_name
    PyTypeObjectUtil::basicSize< THIS_CLASS >(),  // tp_basicsize
    0,                                  // tp_itemsize
    THIS_CLASS::_tp_dealloc,            // tp_dealloc
    0,                                  // tp_print
    0,                                  // tp_getattr
    0,                                  // tp_setattr
    PyTypeObjectUtil::compareFunction< THIS_CLASS >(),  // tp_compare
    PyTypeObjectUtil::reprFunction< THIS_CLASS >(),     // tp_repr
    PyTypeObjectUtil::asNumber< THIS_CLASS >(),         // tp_as_number
    PyTypeObjectUtil::asSequence< THIS_CLASS >(),       // tp_as_sequence
    PyTypeObjectUtil::asMapping< THIS_CLASS >(),        // tp_as_mapping
    0,                                  // tp_hash
    PyTypeObjectUtil::callFunction< THIS_CLASS >(),    // tp_call
    PyTypeObjectUtil::strFunction< THIS_CLASS >(),      // tp_str
    THIS_CLASS::_tp_getattro,           // tp_getattro
    THIS_CLASS::_tp_setattro,           // tp_setattro
    0,                                  // tp_as_buffer
    PyTypeObjectUtil::flags< THIS_CLASS >(),            // tp_flags
    /* ... 其余字段省略 ... */
    BASE,                               // tp_base
    /* ... */
    (newfunc)THIS_CLASS::_pyNew,        // tp_new
    /* ... */
};
```

### 7.6 PyTypeObjectUtil 模板特化

`PyTypeObjectUtil` 命名空间提供了一组模板,通过特化来"开关"功能:

```cpp
namespace PyTypeObjectUtil {
    template< typename T > int basicSize()  { return sizeof( T ); }
    template< typename T > cmpfunc compareFunction()  { return 0; }
    template< typename T > reprfunc reprFunction()    { return &T::_tp_repr; }
    template< typename T > PyNumberMethods * asNumber()  { return 0; }
    template< typename T > PySequenceMethods * asSequence() { return 0; }
    template< typename T > PyMappingMethods * asMapping()  { return 0; }
    template< typename T > ternaryfunc callFunction()  { return 0; }
    template< typename T > reprfunc strFunction()  { return 0; }
    template< typename T > long flags()  { return Py_TPFLAGS_DEFAULT; }
    template< typename T > const char * doc()  { return 0; }
    template< typename T > getiterfunc getIterFunction()  { return 0; }
    template< typename T > iternextfunc iterNextFunction()  { return 0; }
    template< typename T > inline Py_ssize_t weakListOffset()  { return 0; }
}
```

子类通过 `PY_TYPEOBJECT_SPECIALISE_*` 宏特化其中某个模板:

```cpp
#define PY_TYPEOBJECT_SPECIALISE_SEQ( THIS_CLASS, SEQ )                  \
    PY_TYPEOBJECT_SPECIALISE_SIMPLE( THIS_CLASS,                          \
        asSequence, PySequenceMethods *, SEQ )
```

特化后,`asSequence<T>()` 返回非 0,`PyTypeObject` 的 `tp_as_sequence` 字段就被填上。这是一种**编译期多态**,避免了运行时 if 判断。

---

## 八、方法导出:从 PY_METHOD 到 PY_AUTO_METHOD

### 8.1 PY_METHOD_DECLARE

`PY_METHOD_DECLARE(METHOD_NAME)` 声明一个标准的 Python 方法:

```cpp
#define PY_METHOD_DECLARE( METHOD_NAME )                                  \
    PyObject * METHOD_NAME( PyObject * args );                            \
                                                                          \
    static PyObject * _##METHOD_NAME( PyObject * self,                    \
        PyObject * args, PyObject * /*kwargs*/ )                         \
    {                                                                     \
        This * pSelf = static_cast< This * >( This::getSelf( self ) );    \
        return pSelf ? pSelf->METHOD_NAME( args ) : NULL;                 \
    }
```

它会生成:
1. 实例方法 `METHOD_NAME(PyObject* args)` — 子类实现。
2. 静态函数 `_##METHOD_NAME` — Python C API 兼容的 C 函数,接收 `(self, args, kwargs)`,转发到实例方法。

`getSelf(self)` 默认是 `static_cast<This*>(pObject)`,但子类可重写以支持"附加 self"(如 `PySTLSequence` 用 self 指向 holder 而非 sequence 本身)。

### 8.2 PY_AUTO_METHOD_DECLARE 自动参数解析

`PY_AUTO_METHOD_DECLARE(RET, NAME, ARGS)` 是更高级的宏,自动生成参数解析代码:

```cpp
#define PY_AUTO_METHOD_DECLARE( RET, NAME, ARGS )                         \
    static PyObject * _py_##NAME(                                         \
        PyObject * self, PyObject * args, PyObject * /*kwargs*/ )         \
    {                                                                     \
        This * pThis = static_cast< This * >( This::getSelf( self ) );    \
        if (!pThis) return NULL;                                          \
        PY_AUTO_DEFINE_INT( RET, NAME, pThis->NAME, ARGS )               \
    }
```

`ARGS` 是一个元组式描述,如 `ARG(int, ARG(float, END))` 表示两个参数(int, float)。`PY_AUTO_DEFINE_INT` 会展开为参数解析 + 调用 + 返回值包装的完整代码:

```cpp
#define PY_AUTO_DEFINE_INT( RET, NAME, FNNAME, ARGS )                    \
    const Py_ssize_t argc = PyTuple_Size( args );                        \
                                                                        \
    if (argc < PYAUTO_OPTARGC(ARGS) || argc > PYAUTO_ALLARGC(ARGS))     \
    {                                                                   \
        return Script::argCountError( #NAME,                            \
            PYAUTO_OPTARGC(ARGS), PYAUTO_ALLARGC(ARGS)                  \
            PYAUTO_ARGTYPES(ARGS) ;                                     \
    }                                                                   \
                                                                        \
    PYAUTO_WRITE(ARGS)                                                  \
                                                                        \
    PYAUTO_##RET(FNNAME,ARGS)
```

展开后做了 4 件事:
1. **参数数量检查**:`PYAUTO_OPTARGC` 计算必填参数个数,`PYAUTO_ALLARGC` 计算总参数个数(包括可选)。
2. **参数数量错误**:调用 `Script::argCountError` 抛出 `TypeError`,列出期望类型。
3. **解析参数**:`PYAUTO_WRITE` 宏为每个参数生成 `Script::setData` 调用。
4. **调用并包装返回值**:`PYAUTO_RET*` 根据 `RET` 类型选择包装策略。

### 8.3 参数类型宏

BigWorld 定义了以下参数类型宏:

| 宏 | 含义 | 参数数量 |
|----|------|---------|
| `ARG(T,R)` | 必填参数,类型 T | 1 个 |
| `NZARG(T,R)` | 必填且非零参数(如 PyObjectPtr 不能为 NULL) | 1 个 |
| `OPTARG(T,DEF,R)` | 可选参数,默认值 DEF | 0 或 1 个 |
| `OPTNZARG(T,DEF,R)` | 可选且非零参数 | 0 或 1 个 |
| `MAX_ARG(T,MAX,R)` | 必填参数,值不能超过 MAX | 1 个 |
| `OPTMAX_ARG(T,MAX,DEF,R)` | 可选参数,值不能超过 MAX | 0 或 1 个 |
| `CALLABLE_ARG(T,R)` | 必填且可调用参数 | 1 个 |
| `OPTCALLABLE_ARG(T,DEF,R)` | 可选且可调用参数 | 0 或 1 个 |
| `END` | 参数列表结束 | - |
| `VALID_ANGLE_ARG(float,R)` | 必填 float,范围 [-100, 100] | 1 个 |
| `VALID_ANGLE_VECTOR3_ARG(Vector3,R)` | Vector3,每个元素是有效角度 | 1 个 |

`R` 是"剩余参数"标记,通常是 `END` 或下一个 `ARG(...)`。

### 8.4 返回值宏

| 宏 | 含义 |
|----|------|
| `RETVOID` | 返回 `None` |
| `RETDATA` | 用 `Script::getRetData` 包装返回值(自动转换 C++ → Python) |
| `RETOWN` | 直接返回函数返回的 `PyObject*`(函数自己管理引用) |
| `RETOK` | 函数返回 bool,成功返回 `None`,失败返回 NULL |
| `RETERR` | 函数返回 int(0 成功),非 0 时返回 NULL |

### 8.5 PY_METHOD 注册

宏声明只是"声明",还需要在 `PY_BEGIN_METHODS` 块中注册:

```cpp
PY_BEGIN_METHODS( PyMatrix )
    PY_METHOD( set )
    PY_METHOD_WITH_DOC( invert, "Invert this matrix in place." )
    PY_METHOD_ALIAS( setRotateYPR, setYawPitchRoll )
PY_END_METHODS()
```

展开为:

```cpp
PyMethodDef * PyMatrix::s_getMethodDefs()
{
    static PyMethodDef s_methods[] = {
        { "set", (PyCFunction)&_py_set, METH_VARARGS|METH_KEYWORDS, NULL },
        { "invert", (PyCFunction)&_py_invert, METH_VARARGS|METH_KEYWORDS,
            PY_GET_DOC( "Invert this matrix in place." ) },
        { "setYawPitchRoll", (PyCFunction)&_py_setRotateYPR,
            METH_VARARGS|METH_KEYWORDS, NULL },
        { NULL, NULL, 0, NULL }
    };
    return s_methods;
}
```

`static PyMethodDef s_methods[]` 是**静态数组**,只初始化一次。`PY_GET_DOC` 根据 `ENABLE_DOC_STRINGS` 配置决定是否保留 docstring。

### 8.6 PY_KEYWORD_METHOD_DECLARE

`PY_KEYWORD_METHOD_DECLARE(METHOD_NAME)` 用于支持关键字参数:

```cpp
#define PY_KEYWORD_METHOD_DECLARE( METHOD_NAME )                           \
    PyObject * METHOD_NAME( PyObject * args, PyObject * kwargs );        \
                                                                          \
    static PyObject * _##METHOD_NAME( PyObject * self,                    \
        PyObject * args, PyObject * kwargs )                             \
    {                                                                     \
        This * pSelf = static_cast< This * >( This::getSelf( self ) );   \
        return pSelf ? pSelf->METHOD_NAME( args, kwargs ) : NULL;         \
    }
```

实现方需要在 `args`/`kwargs` 中自己用 `PyArg_ParseTupleAndKeywords` 解析。

### 8.7 PY_STATIC_METHOD_DECLARE

静态方法不绑定 self:

```cpp
#define PY_STATIC_METHOD_DECLARE( NAME )                                  \
    static PyObject * NAME( PyObject * pArgs );                           \
                                                                          \
    static PyObject * _##NAME( PyObject *,                                 \
        PyObject * args, PyObject * )                                     \
    {                                                                     \
        return This::NAME( args );                                        \
    }
```

### 8.8 PY_FACTORY_DECLARE / PY_AUTO_FACTORY_DECLARE

工厂方法用于从 Python 创建 C++ 对象:

```cpp
#define PY_FACTORY_DECLARE()                                              \
    static PyObject * pyNew( PyObject * pArgs );                         \
                                                                          \
    static PyObject * _pyNew( PyObject *, PyObject * args, PyObject * )   \
    {                                                                     \
        return This::pyNew( args );                                       \
    }                                                                     \
    PY_FACTORY_METHOD_LINK_DECLARE()
```

`PY_FACTORY_METHOD_LINK_DECLARE` 生成 `static PyFactoryMethodLink s_link_pyNew;`,这是一个 `InitTimeJob`,在 `Script::init` 时把 `s_type_` 注册到指定模块:

```cpp
// py_factory_method_link.cpp L37-80
void PyFactoryMethodLink::init()
{
    PyObject * pModule = PyImport_AddModule( const_cast<char *>(moduleName_) );
    int isReady = PyType_Ready( pType_ );
    MF_ASSERT( isReady == 0 );

    // 修改 tp_name 为 "Module.Class",这影响 pickle 和错误信息
    char * pQualifiedName = new char[ qualifiedLen ];
    bw_snprintf( pQualifiedName, qualifiedLen, "%s.%s", moduleName_, methodName_ );
    origTypeName_ = pType_->tp_name;
    pType_->tp_name = pQualifiedName;

    PyModule_AddObject( pModule, methodName_, (PyObject *)pType_ );
}

void PyFactoryMethodLink::fini()
{
    // 恢复原始 tp_name,避免悬挂指针
    if (origTypeName_ != NULL) {
        delete[] pType_->tp_name;
        pType_->tp_name = origTypeName_;
        origTypeName_ = NULL;
    }
}
```

**关键设计 — 修改 `tp_name`**:`PyFactoryMethodLink::init` 把 `tp_name` 从 `"ClassName"` 改为 `"Module.ClassName"`。这有两个原因:
1. Python 错误信息更清晰(`<BigWorld.PyMatrix object at 0x...>`)。
2. `pickle` 协议的 `__reduce__` 默认实现会查找 `tp_name` 对应的全局函数,qualified name 让 pickle 能找到正确的反序列化构造器。

### 8.9 PY_AUTO_FACTORY_DECLARE / PY_AUTO_CONSTRUCTOR_FACTORY_DECLARE

```cpp
#define PY_AUTO_FACTORY_DECLARE( CLASS_NAME, ARGS )                       \
    static PyObject * _pyNew( PyObject *, PyObject * args )               \
    {                                                                     \
        PY_AUTO_DEFINE_INT( RETOWN, CLASS_NAME, This::New, ARGS )        \
    }                                                                     \
    PY_FACTORY_METHOD_LINK_DECLARE()

#define PY_AUTO_CONSTRUCTOR_FACTORY_DECLARE( CLASS_NAME, ARGS )           \
    static PyObject * _pyNew( PyObject *, PyObject * args )               \
    {                                                                     \
        PY_AUTO_DEFINE_INT( RETOWN, CLASS_NAME, new This, ARGS )         \
    }                                                                     \
    PY_FACTORY_METHOD_LINK_DECLARE()
```

`PY_AUTO_FACTORY_DECLARE` 调用类的 `This::New(args...)` 静态工厂方法,`PY_AUTO_CONSTRUCTOR_FACTORY_DECLARE` 直接调用 `new This(args...)`。

### 8.10 完整示例:PyMatrix

`script_math.hpp` 中的 `PyMatrix` 是一个完整的 PyObjectPlus 子类示例:

```cpp
class PyMatrix : public MatrixProvider, public Matrix  // 多继承
{
    Py_Header( PyMatrix, MatrixProvider )  // 声明 PyObjectPlus 头

public:
    PyMatrix( PyTypeObject * pType = &s_type_ ) :
        MatrixProvider( false, pType ), Matrix( Matrix::identity ) {}

    void set( const Matrix & m ) { *static_cast<Matrix*>(this) = m; }
    virtual void matrix( Matrix & m ) const { m = *this; }

    bool invert()
    {
        if (!this->Matrix::invert()) {
            PyErr_SetString( PyExc_ValueError, "Matrix could not be inverted" );
            return false;
        }
        return true;
    }

    void set( MatrixProviderPtr mpp ) {
        Matrix m; mpp->matrix( m ); this->set( m );
    }
    PY_AUTO_METHOD_DECLARE( RETVOID, set, NZARG( MatrixProviderPtr, END ) )
    PY_AUTO_METHOD_DECLARE( RETVOID, setZero, END )
    PY_AUTO_METHOD_DECLARE( RETVOID, setIdentity, END )
    PY_AUTO_METHOD_DECLARE( RETVOID, setScale, ARG( Vector3, END ) )
    PY_AUTO_METHOD_DECLARE( RETVOID, setTranslate, ARG( Vector3, END ) )
    PY_AUTO_METHOD_DECLARE( RETVOID, setRotateX, VALID_ANGLE_ARG( float, END ) )
    PY_AUTO_METHOD_DECLARE( RETOK, invert, END )
    PY_AUTO_METHOD_DECLARE( RETDATA, get, ARG( uint, ARG( uint, END ) ) )

    PY_RO_ATTRIBUTE_DECLARE( getDeterminant(), determinant )
    PY_RW_ACCESSOR_ATTRIBUTE_DECLARE( Vector3, translation, translation )
    PY_RO_ATTRIBUTE_DECLARE( yaw(), yaw )

    PY_METHOD_DECLARE( py___getstate__ )
    PY_METHOD_DECLARE( py___setstate__ )

    PY_FACTORY_DECLARE()  // 让 Python 能 PyMatrix() 创建
};
```

`PyMatrix` 同时继承 `MatrixProvider`(PyObjectPlus 子类)和 `Matrix`(纯 C++ 数学类),这是 BigWorld 的常见模式:把数学结构和 Python 接口叠加。

---

## 九、属性导出:PY_ATTRIBUTE 体系

### 9.1 PY_ATTRIBUTE 注册流程

`PY_BEGIN_ATTRIBUTES` / `PY_ATTRIBUTE` / `PY_END_ATTRIBUTES` 三连:

```cpp
#define PY_BEGIN_ATTRIBUTES( THIS_CLASS )                                 \
    PyGetSetDef * THIS_CLASS::s_getAttributeDefs()                        \
    {                                                                     \
        static BW::vector<PyGetSetDef> s_attributes;                      \
        if (!s_attributes.empty()) {                                     \
            return &s_attributes[0];                                     \
        }                                                                 \
        PY_ATTRIBUTE( __members__ )                                      \
        PY_ATTRIBUTE( __methods__ )

#define PY_ATTRIBUTE( NAME )                                              \
        PY_ATTRIBUTE_CREATE_WRAPPER( NAME, NAME )                         \
        PyGetSetDef member_##NAME = {                                    \
            #NAME,                              /* name */                \
            (getter)PyAttrib_##NAME::get,      /* get */                 \
            (setter)PyAttrib_##NAME::set,      /* set */                 \
            NULL,                              /* doc */                  \
            NULL,                              /* closure */             \
        };                                                                \
        s_attributes.push_back( member_##NAME );

#define PY_END_ATTRIBUTES()                                                \
        PyGetSetDef _member_null = { NULL, NULL, NULL, NULL, NULL };     \
        s_attributes.push_back( _member_null );                           \
        return &s_attributes[0];                                          \
    }
```

注意几点:
1. `s_attributes` 是**函数内 static vector**,首次调用时填充,后续直接返回。这避免了静态初始化顺序问题(SIOF)。
2. `__members__` 和 `__methods__` 自动添加为前两个属性。
3. `s_attributes.push_back` 后,`&s_attributes[0]` 返回裸指针——vector 一旦填充就不会再变(因为静态变量只构造一次),指针稳定。

### 9.2 PY_ATTRIBUTE_CREATE_WRAPPER

每个属性都需要一个 getter/setter 函数对。`PY_ATTRIBUTE_CREATE_WRAPPER` 生成一个内部类:

```cpp
#define PY_ATTRIBUTE_CREATE_WRAPPER( NAME, ATTRIB_NAME )                  \
    class PyAttrib_##NAME                                                 \
    {                                                                     \
    public:                                                               \
        static PyObject * get( PyObject * self, void * closure )          \
        {                                                                 \
            This * selfObj = static_cast< This * >( This::getSelf( self ) ); \
            return selfObj ? selfObj->pyGet_##ATTRIB_NAME() : NULL;       \
        }                                                                 \
                                                                          \
        static int set( PyObject * self, PyObject * value, void * closure ) \
        {                                                                 \
            This * selfObj = static_cast< This * >( This::getSelf( self ) ); \
            return selfObj ? selfObj->pySet_##ATTRIB_NAME( value ) : -1;  \
        }                                                                 \
    };
```

这意味着每个 `PY_ATTRIBUTE(NAME)` 都要求类提供:
- `PyObject * pyGet_NAME()` — getter。
- `int pySet_NAME(PyObject* value)` — setter,返回 0 成功,-1 失败。

这些方法通常由 `PY_RW_ATTRIBUTE_DECLARE`、`PY_RO_ATTRIBUTE_DECLARE` 等宏自动生成。

### 9.3 PY_RW_ATTRIBUTE_DECLARE / PY_RO_ATTRIBUTE_DECLARE

`PY_RW_ATTRIBUTE_DECLARE(MEMBER, NAME)` 生成读写属性,直接暴露成员变量:

```cpp
#define PY_RW_ATTRIBUTE_DECLARE( MEMBER, NAME )                           \
    PY_READABLE_ATTRIBUTE_GET( MEMBER, NAME )                             \
    PY_WRITABLE_ATTRIBUTE_SET( MEMBER, NAME )

#define PY_READABLE_ATTRIBUTE_GET( MEMBER, NAME )                         \
    PyObject * PY_ATTR_SCOPE pyGet_##NAME()                               \
        { return Script::getData( MEMBER ); }                            \

#define PY_WRITABLE_ATTRIBUTE_SET( MEMBER, NAME )                         \
    int PY_ATTR_SCOPE pySet_##NAME( PyObject * value )                   \
        { return Script::setData( value, MEMBER, #NAME ); }
```

`MEMBER` 可以是成员变量,也可以是成员函数(只要返回值能被 `Script::getData` 处理)。

`PY_RO_ATTRIBUTE_DECLARE(MEMBER, NAME)` 生成只读属性:

```cpp
#define PY_RO_ATTRIBUTE_DECLARE( MEMBER, NAME )                          \
    PY_RO_ATTRIBUTE_GET( MEMBER, NAME )                                  \
    PY_RO_ATTRIBUTE_SET( NAME )

#define PY_RO_ATTRIBUTE_GET( MEMBER, NAME )                              \
    PyObject * PY_ATTR_SCOPE pyGet_##NAME()                              \
        { return Script::getReadOnlyData( MEMBER ); }

#define PY_RO_ATTRIBUTE_SET( NAME )                                       \
    int PY_ATTR_SCOPE pySet_##NAME( PyObject * /*value*/ )                \
    {                                                                     \
        PyErr_Format( PyExc_TypeError,                                    \
            "Sorry, the attribute " #NAME " in %s is read-only",         \
            this->typeName() );                                          \
        return -1;                                                       \
    }
```

只读属性被赋值时,抛出 `TypeError`,并提示是哪个类、哪个属性。

### 9.4 PY_RW_ACCESSOR_ATTRIBUTE_DECLARE

通过 getter/setter 函数访问属性:

```cpp
#define PY_RW_ACCESSOR_ATTRIBUTE_DECLARE( TYPE, MEMBERFN, NAME )          \
    PY_READABLE_ATTRIBUTE_GET( this->MEMBERFN(), NAME )                   \
    PY_WRITABLE_ACCESSOR_ATTRIBUTE_SET( TYPE, MEMBERFN, NAME )

#define PY_WRITABLE_ACCESSOR_ATTRIBUTE_SET( TYPE, MEMBERFN, NAME )        \
    int PY_ATTR_SCOPE pySet_##NAME( PyObject * value )                    \
    {                                                                     \
        typedef TYPE LocalTypeDef;                                       \
        TYPE newVal = LocalTypeDef();                                   \
        int ret = Script::setData( value, newVal, #NAME );               \
        if (ret == 0) this->MEMBERFN( newVal );                          \
        return ret;                                                      \
    }
```

例如 `PyMatrix` 的 `translation`:

```cpp
const Vector3 & translation() const { return this->Matrix::applyToOrigin(); }
void translation( const Vector3 & v ) { this->Matrix::translation( v ); }
PY_RW_ACCESSOR_ATTRIBUTE_DECLARE( Vector3, translation, translation )
```

Python 中 `m.translation = (1,2,3)` 会调用 `pySet_translation`,内部转换 `(1,2,3)` 为 `Vector3`,再调用 `this->translation(newVal)`。

### 9.5 PY_WO_ATTRIBUTE_DECLARE

只写属性(罕见,用于"只设置不读取"的场景,如密码):

```cpp
#define PY_WO_ATTRIBUTE_DECLARE( MEMBER, NAME )                          \
    PY_WO_ATTRIBUTE_GET( NAME )                                          \
    PY_WRITABLE_ATTRIBUTE_SET( MEMBER, NAME )

#define PY_WO_ATTRIBUTE_GET( NAME )                                       \
    PyObject * PY_ATTR_SCOPE pyGet_##NAME()                              \
    {                                                                     \
        PyErr_Format( PyExc_TypeError,                                    \
            "Sorry, the attribute " #NAME " in %s is write-only",        \
            this->typeName() );                                          \
        return NULL;                                                     \
    }
```

### 9.6 PY_DEFERRED_ATTRIBUTE_DECLARE

延迟声明:只声明签名,实现在类外:

```cpp
#define PY_DEFERRED_ATTRIBUTE_DECLARE( NAME )                            \
    PyObject * PY_ATTR_SCOPE pyGet_##NAME();                             \
    int PY_ATTR_SCOPE pySet_##NAME( PyObject * value );
```

类内只声明,实现可以放在 .cpp 中:

```cpp
// MyType.hpp
class MyType : public PyObjectPlus {
    Py_Header(MyType, PyObjectPlus)
    PY_DEFERRED_ATTRIBUTE_DECLARE( trickyValue )
};

// MyType.cpp
PyObject * MyType::pyGet_trickyValue() {
    // 复杂的 getter 实现
}
int MyType::pySet_trickyValue( PyObject * value ) {
    // 复杂的 setter 实现
}
```

### 9.7 PY_ATTRIBUTE_ALIAS

为已有属性创建别名:

```cpp
#define PY_ATTRIBUTE_ALIAS( NAME, NEW_NAME )                              \
    PY_ATTRIBUTE_CREATE_WRAPPER( NEW_NAME, NAME )                         \
    PyGetSetDef member_##NEW_NAME = {                                    \
        #NEW_NAME,                                                       \
        (getter)PyAttrib_##NEW_NAME::get,                                \
        (setter)PyAttrib_##NEW_NAME::set,                                \
        NULL, NULL,                                                      \
    };                                                                   \
    s_attributes.push_back( member_##NEW_NAME );
```

`PY_ATTRIBUTE_ALIAS(setRotateYPR, setYawPitchRoll)` 让 `setYawPitchRoll` 也是 `setRotateYPR` 的别名(两者共享 `pyGet_setRotateYPR`/`pySet_setRotateYPR`)。

---

## 十、ScriptObject 模型

### 10.1 ScriptObject 设计目标

`ScriptObject` 是 BigWorld 对 `PyObject*` 的**高层包装**,定义在 `lib/script/py_script_object.hpp`。它的设计目标:

1. **引用计数自动化**:构造时自动 INCREF,析构时自动 DECREF。
2. **类型安全派生**:`ScriptDict`、`ScriptList`、`ScriptTuple` 等子类提供类型特定的接口。
3. **错误处理策略化**:模板参数 `ERROR_HANDLER` 让调用方能选择"打印错误"、"清除错误"、"保留错误"等策略。
4. **跨解释器友好**:`ScriptObject` 只是一个 `PyObjectPtr`(SmartPointer),不绑定特定解释器。

### 10.2 ScriptObject 类层次

```
SmartPointer<PyObject>
     ▲
     │
PyObjectPtr (typedef SmartPointer<PyObject>)
     ▲
     │
ScriptObject  ──────────────────┐
     ▲                          │
     │                          │
     ├── ScriptArgs              │  (调用参数,本质是 tuple)
     ├── ScriptModule            │  (Python 模块)
     ├── ScriptType              │  (Python 类型)
     ├── ScriptDict              │  (字典)
     ├── ScriptSequence          │  (序列协议)
     │     ▲                     │
     │     ├── ScriptTuple       │
     │     └── ScriptList        │
     ├── ScriptInt               │  (32位整数)
     ├── ScriptLong              │  (64位整数)
     ├── ScriptFloat             │  (浮点)
     ├── ScriptString            │  (字符串)
     ├── ScriptMapping          │
     ├── ScriptClass             │  (旧式类)
     ├── ScriptIter              │  (迭代器)
     ├── ScriptWeakRef          │  (弱引用)
     └── ScriptObjectPtr<T>      │  (派生类专用智能指针,模板)
                                  │
                                  └─→ 任何 PyObjectPlus 子类
```

### 10.3 ScriptObject 核心接口

`ScriptObject` 继承 `PyObjectPtr`(即 `SmartPointer<PyObject>`),并添加了:

```cpp
class BWENTITY_API ScriptObject : public PyObjectPtr
{
public:
    static const bool FROM_NEW_REFERENCE = true;
    static const bool FROM_BORROWED_REFERENCE = false;

    ScriptObject() : PyObjectPtr() {}
    ScriptObject( PyObject * pObject, bool alreadyIncremented );
    explicit ScriptObject( const PyObjectPtr & pObject );

    // 属性
    bool hasAttribute( const char * key ) const;
    template <class ERROR_HANDLER>
    ScriptObject getAttribute( const char * key, const ERROR_HANDLER & errorHandler ) const;
    template <class ERROR_HANDLER, class RESULT_TYPE>
    bool getAttribute( const char * key, RESULT_TYPE & rResult, const ERROR_HANDLER & errorHandler ) const;
    template <class ERROR_HANDLER>
    bool setAttribute( const char * key, const ScriptObject & value, const ERROR_HANDLER & errorHandler ) const;

    // 方法调用
    template <class ERROR_HANDLER>
    ScriptObject callMethod( const char * methodName, const ERROR_HANDLER & errorHandler, bool allowNullMethod = false ) const;
    template <class ERROR_HANDLER>
    ScriptObject callMethod( const char * methodName, const ScriptArgs & args, const ERROR_HANDLER & errorHandler, bool allowNullMethod = false ) const;
    template <class ERROR_HANDLER>
    ScriptObject callFunction( const ERROR_HANDLER & errorHandler ) const;
    template <class ERROR_HANDLER>
    ScriptObject callFunction( const ScriptArgs & args, const ERROR_HANDLER & errorHandler ) const;

    // 类型查询
    bool isCallable() const;
    bool isNone() const;
    template <class ERROR_HANDLER>
    bool isTrue( const ERROR_HANDLER & errorHandler ) const;
    template <class ERROR_HANDLER>
    bool isSubClass( const PyTypeObject & type, const ERROR_HANDLER & errorHandler ) const;
    const char * typeNameOfObject() const;

    // 转换
    template <class ERROR_HANDLER, class TYPE>
    bool convertTo( TYPE & rVal, const char * varName, const ERROR_HANDLER & errorHandler ) const;
    template <class TYPE>
    static ScriptObject createFrom( TYPE val );

    // 迭代
    template <class ERROR_HANDLER>
    inline ScriptIter getIter( const ERROR_HANDLER & errorHandler ) const;

    // 字符串
    template <class ERROR_HANDLER>
    inline ScriptString str( const ERROR_HANDLER & errorHandler ) const;

    // 静态工具
    static ScriptObject none();
    PyObject * newRef() const;
};
```

### 10.4 引用计数语义

`ScriptObject` 构造函数的 `alreadyIncremented` 参数控制引用计数:

```cpp
ScriptObject obj1( Py_None, ScriptObject::FROM_BORROWED_REFERENCE );  // 借用,需要 INCREF
ScriptObject obj2( PyLong_FromLong(42), ScriptObject::FROM_NEW_REFERENCE );  // 新引用,不 INCREF
```

这映射 Python C API 的"new reference"和"borrowed reference"概念。`FROM_NEW_REFERENCE` 表示 `pObject` 是 `PyLong_FromLong` 等函数返回的新引用(`ob_refcnt` 已经是 1),`ScriptObject` 接管所有权,不在构造时 INCREF。

### 10.5 createFrom / convertTo

```cpp
// py_script_object.ipp L141-146
template <class TYPE>
/* static */ inline ScriptObject ScriptObject::createFrom( TYPE val )
{
    return ScriptObject( Script::getData( val ),
            ScriptObject::FROM_NEW_REFERENCE );
}

// py_script_object.ipp L167-174
template <class ERROR_HANDLER, class TYPE>
inline bool ScriptObject::convertTo( TYPE & rVal, const char * varName,
    const ERROR_HANDLER & errorHandler ) const
{
    int ret = Script::setData( this->get(), rVal, varName );
    errorHandler.checkMinusOne( ret );
    return ret == 0;
}
```

`createFrom` 用 `Script::getData` 把 C++ 值转成 `PyObject*`,`convertTo` 用 `Script::setData` 把 `PyObject*` 转成 C++ 值。这两个函数是 BigWorld 类型转换系统的核心(见 [十二](#十二类型转换系统))。

### 10.6 newRef 与 get

`ScriptObject` 同时提供:
- `get()` — 返回内部 `PyObject*`(借用,不 INCREF)。
- `newRef()` — 返回 `PyObject*` 并 INCREF(新引用)。

```cpp
PyObject * newRef() const
{
    if (object_) {
        incrementReferenceCount( *object_ );
    }
    return this->get();
}
```

`newRef` 用于把 `ScriptObject` 传给需要"新引用所有权"的 Python C API 函数。

---

## 十一、ScriptObject 派生类

### 11.1 STANDARD_SCRIPT_OBJECT_IMP 宏

每个派生类用 `STANDARD_SCRIPT_OBJECT_IMP(TYPE, BASE_TYPE)` 宏生成标准接口:

```cpp
#define STANDARD_SCRIPT_OBJECT_IMP( TYPE, BASE_TYPE )                     \
    BASE_SCRIPT_OBJECT_IMP( PyObject, TYPE, BASE_TYPE )

#define BASE_SCRIPT_OBJECT_IMP( OBJECT_TYPE, TYPE, BASE_TYPE )            \
    BASE_SCRIPT_OBJECT_IMP_WITHOUT_CREATE( OBJECT_TYPE, TYPE, BASE_TYPE ) \
    static TYPE create( const ScriptObject & other )                      \
    {                                                                     \
        if (other && TYPE::check( other )) {                             \
            return TYPE( other );                                         \
        }                                                                 \
        return TYPE();                                                    \
    }
```

`BASE_SCRIPT_OBJECT_IMP_WITHOUT_CREATE` 生成:
1. 默认构造函数 `TYPE() : BASE_TYPE() {}`
2. 从 `PyObject*` 构造 `TYPE(OBJECT_TYPE* pObject, bool alreadyIncremented)`
3. 从 `ScriptObject` 显式构造(带类型断言)
4. 从 `PyObjectPtr` 显式构造(带类型断言)
5. 拷贝构造
6. 赋值运算符(`TYPE&` 和 `ScriptObject`)

### 11.2 ScriptModule

`ScriptModule` 提供模块操作:

```cpp
class ScriptModule : public ScriptObject
{
public:
    STANDARD_SCRIPT_OBJECT_IMP( ScriptModule, ScriptObject )

    static bool check( const ScriptObject & object )
    {
        return PyModule_Check( object.get() );
    }

    template <class ERROR_HANDLER>
    static ScriptModule import( const char * name, const ERROR_HANDLER & errorHandler );
    template <class ERROR_HANDLER>
    static ScriptModule getOrCreate( const char * name, const ERROR_HANDLER & errorHandler );
    template <class ERROR_HANDLER>
    static ScriptModule reload( ScriptModule module, const ERROR_HANDLER & errorHandler );

    template <class ERROR_HANDLER>
    bool addObject( const char * name, const ScriptObject & value, const ERROR_HANDLER & errorHandler ) const;
    template <class ERROR_HANDLER>
    bool addObject( const char * name, PyTypeObject * value, const ERROR_HANDLER & errorHandler ) const;
    template <class ERROR_HANDLER>
    bool addIntConstant( const char * name, long value, const ERROR_HANDLER & errorHandler ) const;

    ScriptDict getDict() const;
};
```

实现在 `py_script_module.ipp`:

```cpp
template <class ERROR_HANDLER>
/* static */ inline ScriptModule ScriptModule::import( const char * name,
    const ERROR_HANDLER & errorHandler )
{
    PyObject * pModule = PyImport_ImportModule( name );
    errorHandler.checkPtrError( pModule );
    return ScriptModule( pModule, ScriptObject::FROM_NEW_REFERENCE );
}

template <class ERROR_HANDLER>
/* static */ inline ScriptModule ScriptModule::getOrCreate( const char * name,
    const ERROR_HANDLER & errorHandler )
{
    PyObject * pModule = PyImport_AddModule( name );  // 借用引用
    errorHandler.checkPtrError( pModule );
    return ScriptModule( pModule, ScriptObject::FROM_BORROWED_REFERENCE );
}

template <class ERROR_HANDLER>
inline bool ScriptModule::addObject( const char * name,
    const ScriptObject & value, const ERROR_HANDLER & errorHandler ) const
{
    // PyModule_AddObject steals a reference, so we increment it before hand.
    int result = PyModule_AddObject( this->get(), name, value.newRef() );
    errorHandler.checkMinusOne( result );
    return result != -1;
}
```

`addObject` 调用 `value.newRef()` 是因为 `PyModule_AddObject` **偷取**引用所有权(steals reference)。`newRef` INCREF 一次,然后 `PyModule_AddObject` 接管这个新引用,`ScriptObject` 析构时还会 DECREF 一次,平衡了引用计数。

### 11.3 ScriptArgs

`ScriptArgs` 是方法调用的参数容器,本质是 `tuple`:

```cpp
class ScriptArgs : public ScriptObject
{
public:
    NO_CREATE_SCRIPT_OBJECT_IMP( ScriptArgs, ScriptObject );  // 无 create 方法

    static bool check( const ScriptObject & object ) {
        return PyTuple_Check( object.get() );
    }
    static ScriptArgs none();

    template < typename T1 > static ScriptArgs create( const T1 & arg1 );
    template < typename T1, typename T2 > static ScriptArgs create( const T1 & arg1, const T2 & arg2 );
    // ... 一直到 8 个参数
};
```

`ScriptArgs::create(arg1, arg2, ...)` 是变参模板,内部用 `PyTuple_New(N)` + `Script::getData` 填充。`NO_CREATE_SCRIPT_OBJECT_IMP` 不提供 `create(ScriptObject)` 方法,因为 `ScriptArgs` 不能从任意 `ScriptObject` 转换(必须是 tuple)。

### 11.4 ScriptTuple / ScriptList / ScriptDict

```cpp
class ScriptTuple : public ScriptSequence {
public:
    STANDARD_SCRIPT_OBJECT_IMP( ScriptTuple, ScriptSequence )
    static bool check( const ScriptObject & object ) { return PyTuple_Check( object.get() ); }
    static ScriptTuple create( size_type len );
    ScriptObject getItem( size_type pos ) const;
    bool setItem( size_type pos, const ScriptObject & item ) const;
    size_type size() const;
};

class ScriptList : public ScriptSequence {
public:
    STANDARD_SCRIPT_OBJECT_IMP( ScriptList, ScriptSequence )
    static bool check( const ScriptObject & object ) { return PyList_Check( object.get() ); }
    static ScriptList create( Py_ssize_t len = 0 );
    bool append( const ScriptObject & object ) const;
    ScriptObject getItem( size_type pos ) const;
    bool setItem( size_type pos, ScriptObject item ) const;
    size_type size() const;
};

class ScriptDict : public ScriptObject {
public:
    STANDARD_SCRIPT_OBJECT_IMP( ScriptDict, ScriptObject )
    static bool check( const ScriptObject & object ) { return PyDict_Check( object.get() ); }
    static ScriptDict create( int capacity = 0 );
    bool next( size_type & pos, ScriptObject & key, ScriptObject & value );
    template <class ERROR_HANDLER> bool setItem( const char * key, const ScriptObject & value, const ERROR_HANDLER & errorHandler ) const;
    template <class ERROR_HANDLER> ScriptObject getItem( const char * key, const ERROR_HANDLER & errorHandler ) const;
    size_type size() const;
    template <class ERROR_HANDLER> bool update( const ScriptDict & other, const ERROR_HANDLER & errorHandler ) const;
};
```

### 11.5 ScriptString

```cpp
class ScriptString : public ScriptObject {
public:
    STANDARD_SCRIPT_OBJECT_IMP( ScriptString, ScriptObject )
    static bool check( const ScriptObject & object ) { return PyString_Check( object.get() ); }

    static ScriptString create( const char * str );
    static ScriptString create( const char * str, int size );
    template<typename Traits, typename Alloc>
    static ScriptString create( const std::basic_string<char, Traits, Alloc> & str );

    template<typename Traits, typename Alloc>
    void getString( std::basic_string<char, Traits, Alloc> & str ) const;
    const char * c_str() const;
};
```

### 11.6 ScriptObjectPtr<T> 模板

`ScriptObjectPtr<T>` 是给 `PyObjectPlus` 子类专用的智能指针:

```cpp
template <typename CLASS>
class ScriptObjectPtr : public ScriptObject
{
public:
    BASE_SCRIPT_OBJECT_IMP( CLASS, ScriptObjectPtr, ScriptObject );

    static bool check( const ScriptObject & object ) {
        return CLASS::Check( object );
    }

    const CLASS * get() const {
        return static_cast<const CLASS*>( this->ScriptObject::get() );
    }
    CLASS * get() {
        return static_cast<CLASS*>( this->ScriptObject::get() );
    }

    const CLASS & operator*() const {
        return static_cast< const CLASS & >( this->ScriptObject::operator*() );
    }
    CLASS & operator*() {
        return static_cast< CLASS & >( this->ScriptObject::operator*() );
    }
    const CLASS * operator->() const {
        return static_cast<const CLASS*>( this->ScriptObject::operator->() );
    }
    CLASS * operator->() {
        return static_cast<CLASS*>( this->ScriptObject::operator->() );
    }
};
```

它把 `ScriptObject` 的 `PyObject*` 重新解释为 `CLASS*`(通过 `static_cast`,因为 `CLASS` 继承 `PyObjectPlus` 继承 `PyObject`),让 C++ 端能像使用普通指针一样使用 `ScriptObjectPtr<Entity>`。

`PY_SCRIPT_CONVERTERS(CLASS)` 宏(见 [十三](#十三py_script_converters-宏机制))会为 `ScriptObjectPtr<CLASS>` 生成 `setData`/`getData` 重载,让 `Script::setData` 能直接接受 `ScriptObjectPtr<CLASS>&`。

### 11.7 SCRIPT_CONVERTER 宏

`SCRIPT_CONVERTER(CLASS)` 为派生类生成 `setData`/`getData`:

```cpp
#define SCRIPT_CONVERTER( CLASS )                                          \
    inline int setData( PyObject * pObj, CLASS & rScriptObject,            \
        const char * varName = "" )                                        \
    {                                                                      \
        ScriptObject sc = ScriptObject( pObj, ScriptObject::FROM_BORROWED_REFERENCE ); \
        if (!sc.exists() || !CLASS::check( sc )) {                          \
            PyErr_Format( PyExc_TypeError,                                 \
                    "%s must be set to a "#CLASS" object.", varName );     \
            return -1;                                                     \
        }                                                                  \
        rScriptObject = CLASS( sc );                                       \
        return 0;                                                          \
    }                                                                      \
                                                                           \
    inline PyObject * getData( const CLASS & data )                        \
    {                                                                      \
        PyObject * ret = data ? data.get() : Py_None;                      \
        Py_INCREF( ret );                                                  \
        return ret;                                                        \
    }
```

这把 `ScriptDict`、`ScriptList`、`ScriptTuple` 等加入到 `Script::setData`/`getData` 的重载集合,让它们能作为 `PY_AUTO_METHOD` 参数或返回值。

---

## 十二、类型转换系统

### 12.1 Script::setData / getData 概览

`Script::setData` 把 `PyObject*` 转成 C++ 值,`Script::getData` 把 C++ 值转成 `PyObject*`。它们是 BigWorld 类型转换系统的核心,通过 C++ 函数重载实现。

`script.hpp` 中声明的重载(节选):

```cpp
namespace Script {
    // 基本类型
    int setData( PyObject * pObj, bool & rVal, const char * varName = "" );
    int setData( PyObject * pObj, int  & rVal, const char * varName = "" );
    int setData( PyObject * pObj, uint & rVal, const char * varName = "" );
    int setData( PyObject * pObj, float & rVal, const char * varName = "" );
    int setData( PyObject * pObj, double & rVal, const char * varName = "" );
    int setData( PyObject * pObj, int64 & rVal, const char * varName = "" );
    int setData( PyObject * pObj, uint64 & rVal, const char * varName = "" );

    // 字符串
    int setData( PyObject * pObj, BW::string & rString, const char * varName = "" );
    int setData( PyObject * pObj, BW::wstring & rString, const char * varName = "" );

    // 数学类型
    int setData( PyObject * pObj, Vector2 & rVal, const char * varName = "" );
    int setData( PyObject * pObj, Vector3 & rVal, const char * varName = "" );
    int setData( PyObject * pObj, Vector4 & rVal, const char * varName = "" );
    int setData( PyObject * pObj, Matrix & rVal, const char * varName = "" );

    // 网络类型
    int setData( PyObject * pObj, Mercury::Address & rAddr, const char * varName = "" );
    int setData( PyObject * pObject, SpaceEntryID & entryID, const char * varName = "" );

    // PyObject 本身
    int setData( PyObject * pObj, PyObject * & rVal, const char * varName = "" );
    int setData( PyObject * pObj, SmartPointer<PyObject> & rPyObject, const char * varName = "" );

    // 容器
    template <class T, class A> int setData( PyObject * pObj, BW::vector<T,A> & res, const char * varName = "" );
    template <class C, class Tr, class A> int setData( PyObject * pObj, std::basic_string<C,Tr,A> & res, const char * varName = "" );
    template <class K, class T, class C, class A> int setData( PyObject * pObj, BW::map<K,T,C,A> & res, const char * varName = "" );
    template <class K, class T, class C, class A> int setData( PyObject * pObj, BW::multimap<K,T,C,A> & res, const char * varName = "" );

    // getData 重载(对称)
    PyObject * getData( const bool data );
    PyObject * getData( const int data );
    PyObject * getData( const uint data );
    PyObject * getData( const float data );
    PyObject * getData( const double data );
    PyObject * getData( const int64 data );
    PyObject * getData( const uint64 data );
    PyObject * getData( const Vector2 & data );
    PyObject * getData( const Vector3 & data );
    PyObject * getData( const Vector4 & data );
    PyObject * getData( const Direction3D & data );
    PyObject * getData( const Matrix & data );
    PyObject * getData( const PyObject * data );
    PyObject * getData( ConstSmartPointer<PyObject> data );
    PyObject * getData( const Capabilities & data );
    PyObject * getData( const BW::string & data );
    PyObject * getData( const BW::wstring & data );
    PyObject * getData( const char * data );
    PyObject * getData( const Mercury::Address & addr );
    PyObject * getData( const SpaceEntryID & entryID );

    // 只读变体(用于 RO 属性,返回的对象不会被修改)
    PyObject * getReadOnlyData( const Vector2 & data );
    PyObject * getReadOnlyData( const Vector3 & data );
    PyObject * getReadOnlyData( const Vector4 & data );

    // 引用变体(返回指向 owner 内部数据的 PyVectorRef)
    PyObject * getDataRef( PyObject * pOwner, Vector2 * pData );
    PyObject * getDataRef( PyObject * pOwner, Vector3 * pData );
    PyObject * getDataRef( PyObject * pOwner, Vector4 * pData );
}
```

### 12.2 整数转换:setData 的多路径

整数转换是最复杂的,因为 Python 2 有 `int` 和 `long` 两种整数类型,且需要处理溢出:

```cpp
// script.cpp L1317-1358
int Script::setData( PyObject * pObject, int & rInt, const char * varName )
{
    if (PyInt_Check( pObject )) {
        long asLong = PyInt_AsLong( pObject );
        rInt = asLong;
        if (asLong == rInt) {  // 检查 long → int 是否截断
            return 0;
        }
    }

    if (PyFloat_Check( pObject )) {
        rInt = (int)PyFloat_AsDouble( pObject );
        return 0;
    }

    if (PyLong_Check( pObject )) {
        long asLong = PyLong_AsLong( pObject );
        rInt = int( asLong );
        if (!PyErr_Occurred()) {
            if (rInt == asLong) {
                return 0;
            }
        } else {
            PyErr_Clear();  // long → long 溢出,继续尝试
        }
    }

    PyErr_Format( PyExc_TypeError, "%s must be set to an int", varName );
    return -1;
}
```

转换顺序:
1. `int` 类型:检查截断。
2. `float` 类型:直接转(可能丢精度)。
3. `long` 类型:检查溢出。

`uint` 重载更严格,检查负值:

```cpp
// script.cpp L1466-1510
int Script::setData( PyObject * pObject, uint & rUint, const char * varName )
{
    if (PyInt_Check( pObject )) {
        long longValue = PyInt_AsLong( pObject );
        rUint = longValue;
        if ((longValue >= 0) && (static_cast< long >( rUint ) == longValue)) {
            return 0;
        }
    }
    // ... float、long 路径
}
```

### 12.3 字符串转换:Unicode 支持

```cpp
// script.cpp L1770-1797
int Script::setData( PyObject * pObject, BW::string & rString, const char * varName )
{
    PyObjectPtr pUTF8String;

    if (PyUnicode_Check( pObject )) {
        pUTF8String = PyObjectPtr( PyUnicode_AsUTF8String( pObject ),
            PyObjectPtr::STEAL_REFERENCE );
        pObject = pUTF8String.get();
        if (pObject == NULL) {
            return -1;
        }
    }

    if (!PyString_Check( pObject )) {
        PyErr_Format( PyExc_TypeError, "%s must be set to a string.", varName );
        return -1;
    }

    char *ptr_cs;
    Py_ssize_t len_cs;
    PyString_AsStringAndSize( pObject, &ptr_cs, &len_cs );
    rString.assign( ptr_cs, len_cs );
    return 0;
}
```

Unicode 字符串会先转 UTF-8,然后作为字节串处理。这保证 `BW::string` 总是 UTF-8 编码。

### 12.4 Vector3 转换:多形态接受

```cpp
// script.cpp L1599-1617
int Script::setData( PyObject * pObject, Vector3 & rVector, const char * varName )
{
    if (PyVector<Vector3>::Check( pObject )) {
        rVector = ((PyVector<Vector3>*)pObject)->getVector();
        return 0;
    }
    PyErr_Clear();  // 清除 PyVector 检查可能的错误状态

    if (PyArg_ParseTuple( pObject, "fff", &rVector.x, &rVector.y, &rVector.z )) {
        return 0;
    }

    PyErr_Format( PyExc_TypeError,
        "%s must be set to a Vector3 or a tuple of 3 floats", varName );
    return -1;
}
```

`Vector3` 接受两种 Python 形态:
1. `PyVector<Vector3>` 对象(BigWorld 内置类型)。
2. 三元组 `(1.0, 2.0, 3.0)`。

这给 Python 脚本两种写法:`entity.position = Vector3(1,2,3)` 或 `entity.position = (1,2,3)`,后者更简洁。

### 12.5 Matrix 转换:MatrixProvider 协议

```cpp
// script.cpp L1657-1668
int Script::setData( PyObject * pObject, Matrix & rMatrix, const char * varName )
{
    if (MatrixProvider::Check( pObject )) {
        ((MatrixProvider*) pObject)->matrix(rMatrix);
        return 0;
    }

    PyErr_Format( PyExc_TypeError, "%s must be a MatrixProvider", varName );
    return -1;
}
```

`Matrix` 只接受 `MatrixProvider` 子类(`PyMatrix`、`MatrixProvider` 衍生类如 `AttachmentDirectionMatrixProvider`、`EntityMatrixProvider` 等)。这设计让"如何计算矩阵"由 `MatrixProvider` 决定,而 `Matrix` 本身只是数据容器。

### 12.6 getData 的策略

`getData` 是对称的"制造 PyObject"操作。三个变体:

```cpp
// 1. 普通版本(可读写)
PyObject * Script::getData( const Vector3 & data ) {
    return new PyVectorCopy< Vector3 >( data );  // 拷贝,可读写
}

// 2. 只读版本
PyObject * Script::getReadOnlyData( const Vector3 & data ) {
    return new PyVectorCopy< Vector3 >( data, /*isReadOnly:*/true );  // 拷贝,只读
}

// 3. 引用版本(指向 owner 内部数据)
PyObject * Script::getDataRef( PyObject * pOwner, Vector3 * pData ) {
    return new PyVectorRef< Vector3 >( pOwner, pData );  // 引用 owner 内存
}
```

`getDataRef` 是性能关键:它创建的 `PyVectorRef` 不拷贝数据,而是直接指向 `owner` 的成员变量。Python 中修改这个 Vector 会直接修改 C++ 对象的字段,避免大对象拷贝。但要求 `pOwner` 必须存活,否则野指针。

### 12.7 容器转换:setDataSequence / setDataMapping

```cpp
// script.hpp L254-275
template <class T, class SEQ> int setDataSequence( PyObject * pObj,
    SEQ & res, const char * varName )
{
    if (!PySequence_Check( pObj )) {
        PyErr_Format( PyExc_TypeError, "%s must be set to a sequence of %s",
            varName, typeid(T).name() );
        return -1;
    }
    BW::string eltVarName = varName; eltVarName += " element";
    Py_ssize_t sz = PySequence_Size( pObj );
    res.resize( sz );
    for (Py_ssize_t i = 0; i < sz; ++i) {
        PyObjectPtr pItem( PySequence_GetItem( pObj, i ), true );
        if (setData( pItem.get(), res[i], eltVarName.c_str() ) != 0) {
            return -1;
        }
    }
    return 0;
}

template <class T, class A> int setData( PyObject * pObj,
    BW::vector<T,A> & res, const char * varName = "" )
{
    return setDataSequence<T>( pObj, res, varName );
}
```

`setDataSequence` 是通用模板,接受任何支持 `resize` 和 `operator[]` 的容器。每个元素递归调用 `setData`。

`setDataMapping` 类似:

```cpp
// script.hpp L296-321
template <class K, class T, class MAP> int setDataMapping( PyObject * pObj,
    MAP & res, const char * varName )
{
    if (!PyDict_Check( pObj )) {
        PyErr_Format( PyExc_TypeError, "%s must be set to a dict of %s: %s",
            varName, typeid(K).name(), typeid(T).name() );
        return -1;
    }
    BW::string keyVarName = varName;
    BW::string valueVarName = keyVarName;
    keyVarName += " key";
    valueVarName += " value";

    res.clear();
    Py_ssize_t pos = 0;
    PyObject * pKey, * pValue;
    while (PyDict_Next( pObj, &pos, &pKey, &pValue )) {
        std::pair<K,T> both;
        if (setData( pKey, both.first, keyVarName.c_str() ) != 0) return -1;
        if (setData( pValue, both.second, valueVarName.c_str() ) != 0) return -1;
        res.insert( both );
    }
    return 0;
}
```

注意 `setDataMapping` 用 `PyDict_Check` 严格检查 dict 类型(注释说"using PyMapping API would be expensive")——`PyMapping` 接口需要每次调用 `__getitem__`,而 dict 直接访问内部哈希表。

### 12.8 INT_ACCESSOR 宏:整数类型扩展

```cpp
// script.hpp L181-198
#define INT_ACCESSOR( INPUT_TYPE, COMMON_TYPE )                       \
    inline PyObject * getData( const INPUT_TYPE data )                \
        { return getData( COMMON_TYPE( data ) ); }                   \
    inline int setData( PyObject * pObject, INPUT_TYPE & rInt,        \
                        const char * varName = "" )                   \
        {                                                              \
            COMMON_TYPE value;                                         \
            int result = setData( pObject, value, varName );          \
            rInt = INPUT_TYPE( value );                                \
            if (rInt != value )                                        \
            {                                                          \
                PyErr_SetString( PyExc_TypeError,                      \
                    "Integer is out of range" );                       \
                return -1;                                             \
            }                                                          \
            return result;                                             \
        }
```

这个宏为 `int8`、`int16`、`uint8`、`uint16` 等窄整数类型生成 `setData`/`getData`,内部委托给 `int` 或 `long`,然后检查是否截断。

不同平台用不同的 `COMMON_TYPE`:

```cpp
#ifdef _WIN32
    INT_ACCESSOR( int8,  int );
    INT_ACCESSOR( int16, int );
    INT_ACCESSOR( uint8,  int );
    INT_ACCESSOR( uint16, int );
#endif
#ifdef __linux__
    INT_ACCESSOR( int8,  long );
    // ...
#endif
```

这是因为 Windows 的 `int` 和 `long` 都是 32 位,而 Linux 64 位的 `long` 是 64 位。

### 12.9 边界情况:None 处理

`setData(PyObject* pObj, PyObject*& rVal)` 处理 None → NULL:

```cpp
// script.cpp L1681-1698
int Script::setData( PyObject * pObject, PyObject * & rPyObject,
    const char * /*varName*/ )
{
    PyObject * inputObject = rPyObject;
    rPyObject = (pObject != Py_None) ? pObject : NULL;  // None → NULL
    Py_XINCREF( rPyObject );

    if (inputObject) {
        WARNING_MSG( "Script::setData( pObject , rPyObject ): "
            "rPyObject is not NULL and is DECREFed and replaced by pObject\n" );
    }
    Py_XDECREF( inputObject );

    return 0;
}
```

`None` 在 C++ 端表示为 `NULL`,这是 BigWorld 的约定。`getData(const PyObject* data)` 反向转换:

```cpp
// script.cpp L2109-2114
PyObject * Script::getData( const PyObject * data )
{
    PyObject * ret = (data != NULL) ? const_cast<PyObject*>( data ) : Py_None;
    Py_INCREF( ret );
    return ret;
}
```

### 12.10 字符串字面量:getData(const char*)

```cpp
// script.cpp L2179-2184
PyObject * Script::getData( const char * data )
{
    PyObject * pRet = PyString_FromString( const_cast<char *>( data ) );
    return pRet;
}
```

注意 `const_cast<char*>`:Python 2 的 `PyString_FromString` 签名是非 const `char*`,虽然它不会修改字符串,但需要 cast。

---

## 十三、PY_SCRIPT_CONVERTERS 宏机制

### 13.1 PY_SCRIPT_CONVERTERS_DECLARE

`PY_SCRIPT_CONVERTERS_DECLARE(CLASS)` 在头文件中前置声明 `setData`/`getData` 重载:

```cpp
#define PY_SCRIPT_CONVERTERS_DECLARE( CLASS )                             \
namespace Script                                                         \
{                                                                        \
    PyObject * getData( const CLASS * pModel );                          \
                                                                         \
    int setData( PyObject * pObject, SmartPointer<CLASS> & rpModel,     \
        const char * varName = "" );                                     \
    int setData( PyObject * pObject, ScriptObjectPtr<CLASS> & rpModel,   \
        const char * varName = "" );                                    \
                                                                         \
    PyObject * getData( ConstSmartPointer<CLASS> pModel );               \
    PyObject * getData( ScriptObjectPtr<CLASS> pModel );                \
};
```

声明了 5 个重载,涵盖 `const CLASS*`、`SmartPointer<CLASS>&`、`ScriptObjectPtr<CLASS>&`、`ConstSmartPointer<CLASS>`、`ScriptObjectPtr<CLASS>`。

### 13.2 PY_SCRIPT_CONVERTERS 实现

`PY_SCRIPT_CONVERTERS(CLASS)` 在 .cpp 中定义这些重载:

```cpp
#define PY_SCRIPT_CONVERTERS( CLASS )                                     \
PyObject * Script::getData( const CLASS * pDerived )                     \
{                                                                        \
    return Script::getData(                                              \
        static_cast< const PyObject * >( pDerived ) );                   \
}                                                                        \
                                                                         \
int Script::setData( PyObject * pObject,                                \
    ScriptObjectPtr<CLASS> & rpDerived, const char * varName )          \
{                                                                        \
    PyObjectPtr pCoerced = CLASS::coerce( pObject );                     \
    if (pCoerced == Py_None)                                             \
    {                                                                    \
        rpDerived = ScriptObjectPtr<CLASS>();                           \
    }                                                                    \
    else if (CLASS::Check( pCoerced.get() ))                             \
    {                                                                    \
        if (rpDerived.get() != pCoerced)                                 \
        {                                                                \
            rpDerived = ScriptObjectPtr<CLASS>(                          \
                    static_cast<CLASS *>( pCoerced.get() ),              \
                    ScriptObject::FROM_BORROWED_REFERENCE );            \
        }                                                                \
    }                                                                    \
    else                                                                 \
    {                                                                    \
        PyErr_Format( PyExc_TypeError,                                   \
            "%s must be set to a " #CLASS " or None", varName );         \
        return -1;                                                       \
    }                                                                    \
    return 0;                                                            \
}                                                                        \
/* ... 其它重载省略 ... */
```

关键点:
1. **`coerce` 机制**:`CLASS::coerce(pObject)` 静态方法允许子类接受"非本类型但可转换"的对象。默认实现是直接返回 `pObject`(`PyObjectPlus::coerce`)。
2. **`Py_None` → NULL 约定**:如果 Python 传入 `None`,`rpDerived` 被设为默认构造的空指针。
3. **类型不匹配报错**:`"X must be set to a ClassName or None"` 错误信息明确。

### 13.3 coerce 的应用:MatrixProvider

`MatrixProvider` 不重写 `coerce`,所以 `setData(Matrix&, MatrixProviderPtr&)` 严格只接受 `MatrixProvider` 子类。但 `Vector4Provider` 重写了 `coerce`:

```cpp
// script_math.hpp L465
class Vector4Provider : public PyObjectPlusWithWeakReference
{
    static PyObjectPtr coerce( PyObject * pObject );
};
```

`Vector4Provider::coerce` 实现允许 `Vector4` 元组自动转换为 `Vector4Basic`(让脚本可以传 `(1,1,1,1)` 而不必显式 `Vector4Provider((1,1,1,1))`)。

### 13.4 PY_ENUM_CONVERTERS 枚举转换

```cpp
#define PY_ENUM_CONVERTERS_DECLARE( ENUMTYPE )                            \
namespace Script                                                        \
{                                                                       \
    int setData( PyObject * pObject, ENUMTYPE & rData,                  \
        const char * varName = "" );                                    \
    PyObject * getData( const ENUMTYPE data );                         \
};
```

枚举通过 `OrderedStringMap<ENUMTYPE>` 在字符串和枚举值之间映射。两种变体:
- `PY_ENUM_CONVERTERS_CONTIGUOUS(ENUMTYPE)`:连续枚举(0,1,2,...),用 index 直接查找。
- `PY_ENUM_CONVERTERS_SCATTERED(ENUMTYPE)`:离散枚举(如 0,1,5,99),用 `emap` 反向查找。

枚举映射用 `PY_BEGIN_ENUM_MAP` / `PY_ENUM_VALUE` / `PY_END_ENUM_MAP` 三连声明:

```cpp
PY_BEGIN_ENUM_MAP( MyEnum, MYENUM_ )
    PY_ENUM_VALUE( MYENUM_FOO )
    PY_ENUM_VALUE( MYENUM_BAR )
PY_END_ENUM_MAP()

PY_ENUM_CONVERTERS_CONTIGUOUS( MyEnum )
```

`PY_BEGIN_ENUM_MAP` 的 `ENUMPREFIX` 参数会被去掉(如 `MYENUM_FOO` → `"FOO"`),让 Python 端用简短的字符串名:`"FOO"` 而非 `"MYENUM_FOO"`。

---

## 十四、Personality 系统

### 14.1 Personality 是什么

`Personality` 是 BigWorld 的"Python 进程人格"。同一个 C++ 引擎二进制(CellApp、BaseApp、Client、DBApp)在不同进程运行时,通过加载不同的 Personality 模块,表现出完全不同的行为:

| 进程 | Personality 模块名(典型) | 行为 |
|------|--------------------------|------|
| CellApp | `BWPersonality` 或自定义 | 处理空间、AOI、Ghost |
| BaseApp | `BWPersonality` 或自定义 | 处理持久化、登录 |
| Client | `BWPersonality` 或自定义 | 处理输入、渲染回调 |
| DBApp | `BWPersonality` 或自定义 | 处理数据库连接 |
| Bot | `BWPersonality` 或自定义 | 自动化测试机器人 |

Personality 模块是一个 Python 文件(`BWPersonality.py`),定义 `onInit`、`onFini` 等回调。每个进程通过 `ServerAppConfig::personality()` 配置加载哪个。

### 14.2 Personality 命名空间接口

`lib/pyscript/personality.hpp`:

```cpp
namespace Personality
{
    extern const char *DEFAULT_NAME;  // "BWPersonality"

    ScriptModule import( const BW::string &name );  // 导入 personality 模块
    ScriptModule instance();                          // 获取已导入的实例

    bool callOnInit( bool isReload = false );        // 调用 onInit 回调

    ScriptObject getMember( const char * name );                          // 获取成员
    ScriptObject getMember( const char * currentName, const char * deprecatedName );  // 兼容旧名
}
```

### 14.3 import 流程

`personality.cpp` L50-69:

```cpp
ScriptModule import( const BW::string &name )
{
    if (s_pInstance_) {
        WARNING_MSG( "Personality::init: Called twice\n" );
        return s_pInstance_;
    }

    s_personalityName = name;

    BW::string importError( "Personality::import: "
        "Failed to import personality module" );
    importError += name;

    s_pInstance_ = ScriptModule::import( name.c_str(),
        ScriptErrorPrint( importError.c_str() ) );

    return s_pInstance_;
}
```

`import` 用 `ScriptModule::import`(底层 `PyImport_ImportModule`)导入模块,如果失败,`ScriptErrorPrint` 会打印 Python traceback。

### 14.4 callOnInit 与 FiniTimeJob

```cpp
// personality.cpp L72-84
bool callOnInit( bool isReload )
{
    if (s_pInstance_) {
        // 注册 fini time job,在 Script::fini 时调用 onFini
        new PersonalityFiniTimeJob();

        s_pInstance_.callMethod( "onInit", ScriptArgs::create( isReload ),
            ScriptErrorPrint( "onInit" ), /* allowNullMethod */ true );
    }
    return true;
}
```

`callOnInit` 调用 personality 模块的 `onInit(isReload)` 方法,`allowNullMethod=true` 表示如果脚本没定义 `onInit` 也不报错(兼容性)。

`PersonalityFiniTimeJob` 在 `Personality::callOnInit` 时通过 `new` 创建,它会自动注册到 `s_finiTimeJobsMap`(因为继承 `FiniTimeJob`),在 `Script::fini` 时被调用:

```cpp
// personality.cpp L25-43
class PersonalityFiniTimeJob : public Script::FiniTimeJob
{
public:
    PersonalityFiniTimeJob( int rung = INT_MAX ) :
        Script::FiniTimeJob( rung )
    { }

private:
    virtual void fini()
    {
        if (s_pInstance_) {
            s_pInstance_.callMethod( "onFini", ScriptErrorPrint( "onFini" ),
                /* allowNullMethod */ true );
            s_pInstance_ = ScriptModule();  // 清空
        }
        delete this;  // 自销毁
    }
};
```

`rung = INT_MAX` 表示这个 FiniTimeJob 最后运行(其它 fini job 先运行,确保 personality 还有效)。

### 14.5 getMember 兼容机制

```cpp
// personality.cpp L120-139
ScriptObject getMember( const char * currentName, const char * deprecatedName )
{
    ScriptObject member = getMember( currentName );

    if (member) {
        return member;
    }

    member = getMember( deprecatedName );

    if (member) {
        NOTICE_MSG( "Failed to find %s.%s, using %s.%s instead\n",
                s_personalityName.c_str(), currentName,
                s_personalityName.c_str(), deprecatedName );
    }

    return member;
}
```

这个重载支持**字段重命名**:新代码用 `currentName` 查找,如果找不到再用旧名 `deprecatedName`,并打印 NOTICE 提醒。这让 personality 脚本可以平滑升级字段名,旧脚本的旧名仍然工作。

### 14.6 Personality 在 ServerApp 中的使用

`lib/server/script_app.cpp` L84-97:

```cpp
bool ScriptApp::initPersonality()
{
    if (!Personality::import( ServerAppConfig::personality() )) {
        WARNING_MSG( "ScriptApp::initPersonality: "
                    "No personality script '%s.py'\n",
                ServerAppConfig::personality().c_str() );
        return false;
    }

    scriptEvents_.initFromPersonality( Personality::instance() );

    return true;
}
```

`ServerAppConfig::personality()` 从 XML 配置读取,典型值 `"BWPersonality"`。`scriptEvents_.initFromPersonality` 从 personality 加载事件监听器配置。

### 14.7 Personality 与 ScriptEvents

`ScriptEvents` 是 BigWorld 的事件广播系统,定义在 `lib/pyscript/script_events.hpp`:

```cpp
class ScriptEvents
{
public:
    ScriptEvents();
    ~ScriptEvents();

    void initFromPersonality( ScriptModule personality );

    void createEventType( const char * eventName );
    void clear();

    bool triggerEvent( const char * eventName, PyObject * pArgs,
            ScriptList resultsList = ScriptList() );
    bool triggerTwoEvents( const char * event1, const char * event2,
            PyObject * pArgs );

    bool addEventListener( const char * eventName,
            PyObject * pListener, int level );
    bool removeEventListener( const char * eventName, PyObject * pListener );

private:
    typedef BW::map< BW::string, ScriptEventList > Container;
    Container container_;
};
```

每个事件名对应一个 `ScriptEventList`,内含监听器列表(`PyObject*` 函数 + 优先级 level)。`triggerEvent` 按优先级顺序调用所有监听器,可收集返回值到 `resultsList`。

`initFromPersonality` 从 personality 模块读取预定义的事件类型,注册到 `container_`。

---

## 十五、Pickler 序列化系统

### 15.1 Pickler 接口

`lib/script/pickler.hpp`(转发到 `lib/pyscript/pickler.cpp`):

```cpp
class Pickler
{
public:
    static BW::string      pickle( ScriptObject pObj );
    static ScriptObject    unpickle( const BW::string & str );

    static bool         init();
    static void         finalise();
};
```

`Pickler` 包装了 Python 2 的 `cPickle` 模块,提供 `BW::string ↔ ScriptObject` 的二进制序列化。

### 15.2 init / finalise

`pickler.cpp` L63-106:

```cpp
bool Pickler::init()
{
    PyObject * pPickleModule = PyImports_ImportModule( "cPickle" );

    if (pPickleModule != NULL) {
        if (!s_pPickleMethod) {
            s_pPickleMethod = PyObject_GetAttrString( pPickleModule, "dumps" );
            // ...
        }
        if (!s_pUnpickleMethod) {
            s_pUnpickleMethod = PyObject_GetAttrString(pPickleModule, "loads");
            // ...
        }
        Py_DECREF( pPickleModule );
    } else {
        // 错误处理:cPickle 模块加载失败
#ifdef _WIN32
        ERROR_MSG( "Failed to import cPickle module.\n" );
#else
        ERROR_MSG( "Failed to import cPickle module. "
            "Is your resource path set correctly?\n"
            "\tThis requires scripts/server_common/lib-dynload-<platform>/cPickle.so "
            "to be relative to a resource path (usually bigworld/res).\n" );
#endif
    }

    return (s_pPickleMethod != NULL) && (s_pUnpickleMethod != NULL);
}

void Pickler::finalise()
{
    Py_XDECREF( s_pPickleMethod );
    s_pPickleMethod = NULL;
    Py_XDECREF( s_pUnpickleMethod );
    s_pUnpickleMethod = NULL;
}
```

`init` 缓存 `cPickle.dumps` 和 `cPickle.loads` 函数对象,避免每次 pickle/unpickle 都做属性查找。`finalise` 在 `Script::fini` 时释放这些引用。

### 15.3 pickle 流程

```cpp
// pickler.cpp L116-151
BW::string Pickler::pickle( ScriptObject object )
{
    PyObject * pObj = object.get();

    if (!pObj) {
        ERROR_MSG( "Pickler::pickle: attempting to pickle NULL\n" );
    }
    else if (pObj->ob_type == &FailedUnpickle::s_type_)
    {
        // 如果是 FailedUnpickle 对象,直接返回原始 pickle 数据
        return static_cast< FailedUnpickle * >( pObj )->pickleData();
    }
    else if (s_pPickleMethod != NULL)
    {
        PyObject * pResult;
        pResult = PyObject_CallFunction( s_pPickleMethod, "(Oi)", pObj, 2 );
        // 第二个参数 2 是 pickle 协议版本(HIGHEST_PROTOCOL)

        if (pResult == NULL) {
            ERROR_MSG( "Pickler::pickle: failed to pickle object\n" );
            PyErr_Print();
        } else {
            BW::string str;
            str.assign( PyString_AsString( pResult ), PyString_Size( pResult ));
            Py_DECREF( pResult );
            return str;
        }
    }

    return "";
}
```

**关键设计 — FailedUnpickle 透传**:如果一个对象本身就是 `FailedUnpickle`(之前 unpickle 失败的占位对象),`pickle` 不会重新序列化它,而是直接返回它持有的原始 pickle 数据。这保证了"无法 unpickle 的数据"在被重新 pickle 时不会丢失,实现**版本兼容**:旧版本无法理解的字段在新版本中保存下来,旧版本重新序列化时原样写回。

### 15.4 unpickle 流程

```cpp
// pickler.cpp L160-183
ScriptObject Pickler::unpickle( const BW::string & str )
{
    PyObject* pResult = NULL;

    if (s_pUnpickleMethod != NULL) {
        pResult = PyObject_CallFunction( s_pUnpickleMethod, "(s#)",
                str.data(), str.length() );
        // "(s#)" 表示接受 char* + 长度,支持二进制数据(含 \0)

        if (pResult == NULL) {
            NOTICE_MSG( "Pickler::unpickle: "
                    "Failed to unpickle. Using stand-in object.\n" );
            PyErr_Print();
        }
    }

    if (pResult == NULL) {
        // unpickle 失败,创建 FailedUnpickle 占位对象
        pResult = new FailedUnpickle( str );
    }

    return ScriptObject( pResult, ScriptObject::STEAL_REFERENCE );
}
```

**关键设计 — FailedUnpickle 兜底**:`unpickle` 失败时不返回 NULL,而是创建 `FailedUnpickle` 对象,持有原始 pickle 数据。这让 BigWorld 在版本不兼容时不会崩溃,只是该字段的值变成"无法访问"的占位对象。后续 `pickle` 会原样写回。

### 15.5 FailedUnpickle 类

```cpp
// pickler.cpp L21-46
class FailedUnpickle : public PyObjectPlus
{
    Py_Header( FailedUnpickle, PyObjectPlus )

public:
    FailedUnpickle( const BW::string & pickleData,
            PyTypeObject * pType = &FailedUnpickle::s_type_ ) :
        PyObjectPlus( pType ),
        pickleData_( pickleData )
    {
    }

    const BW::string & pickleData() const    { return pickleData_; }

private:
    BW::string pickleData_;
};

PY_TYPEOBJECT( FailedUnpickle )

PY_BEGIN_METHODS( FailedUnpickle )
PY_END_METHODS()

PY_BEGIN_ATTRIBUTES( FailedUnpickle )
PY_END_ATTRIBUTES()
```

`FailedUnpickle` 是一个最小化的 PyObjectPlus 子类:无方法、无属性,只持有原始 pickle 字符串。

### 15.6 使用场景

Pickler 在 BigWorld 中的主要使用场景:

1. **实体持久化**:DBApp 把实体的 Python 字段 pickle 后存入数据库。
2. **Ghost 同步**:CellApp 之间传输实体时,pickle 部分非 volatile 字段。
3. **备份**:BaseApp 备份到 BackupApp 时,pickle 整个实体的 Python 状态。
4. **跨进程调用**:Mailbox 调用时,复杂参数(非基本类型)通过 pickle 序列化。
5. **配置缓存**:启动时计算的 Python 配置对象 pickle 到本地,下次启动直接 unpickle。

### 15.7 PY_PICKLING_METHOD_DECLARE / PY_UNPICKLING_FACTORY

`PyObjectPlus` 子类可以自定义 pickle 行为:

```cpp
#define PY_PICKLING_METHOD_DECLARE( CONS_NAME )                          \
    PyObject * pyPickleReduce();                                         \
                                                                          \
    static PyObject * _py___reduce_ex__( PyObject * self, PyObject * )    \
    {                                                                     \
        PyObject * pConsArgs = ((This*)self)->pyPickleReduce();           \
        return Script::buildReduceResult( #CONS_NAME, pConsArgs );       \
    }
```

实现 `pyPickleReduce()` 返回一个 tuple 参数,`Script::buildReduceResult` 把它和构造器名组合成 `(Constructor, args)` 二元组,符合 Python `__reduce_ex__` 协议:

```cpp
// script.cpp L1250-1269
PyObject * Script::buildReduceResult( const char * consName,
    PyObject * pConsArgs )
{
    if (pConsArgs == NULL) return NULL;

    static PyObject * s_pBWPicklingModule = PyImport_AddModule( "_BWp" );

    PyObject * pConsFunc =
        PyObject_GetAttrString( s_pBWPicklingModule, (char*)consName );
    if (pConsFunc == NULL) {
        Py_DECREF( pConsArgs );
        return NULL;
    }

    PyObject * pRes = PyTuple_New( 2 );
    PyTuple_SET_ITEM( pRes, 0, pConsFunc );
    PyTuple_SET_ITEM( pRes, 1, pConsArgs );
    return pRes;
}
```

`_BWp` 是 BigWorld 的"pickle 构造器模块",所有可 pickle 的 C++ 类型通过 `PY_UNPICKLING_FACTORY` 注册构造器到这个模块:

```cpp
#define PY_UNPICKLING_FACTORY( THIS_CLASS, CONS_NAME )                    \
    PyModuleMethodLink THIS_CLASS::s_link_pyPickleResolve(                \
        "_BWp", #CONS_NAME, THIS_CLASS::_pyPickleResolve );
```

unpickle 时,Python 的 pickle 机制会查找 `_BWp.CONS_NAME` 函数,调用它来重建对象。

### 15.8 PY_GETSETSTATE_METHODS

更简单的 pickle 方式是 `__getstate__` / `__setstate__`:

```cpp
#define PY_GETSETSTATE_METHODS_DECLARE()                                 \
    PY_METHOD_DECLARE( py___getstate__ )                                  \
    PY_METHOD_DECLARE( py___setstate__ )
```

`__getstate__` 返回一个字符串(`PyString`),`__setstate__` 接收这个字符串并恢复状态。BigWorld 提供 `PY_CONVERTERS_GETSETSTATE_METHODS` 宏自动生成,基于 POD 类型的内存拷贝:

```cpp
#define PY_CONVERTERS_GETSETSTATE_METHODS( THIS_CLASS, POD_TYPE )        \
    PyObject * THIS_CLASS::py___getstate__( PyObject * args )            \
    {                                                                     \
        POD_TYPE basicType;                                               \
        if (Script::setData( this, basicType, #THIS_CLASS " setstate" ) != 0) \
            return NULL;                                                  \
        return PyString_FromStringAndSize(                                \
            (char*)&basicType, sizeof(basicType) );                       \
    }                                                                     \
                                                                          \
    PyObject * THIS_CLASS::py___setstate__( PyObject * args )             \
    {                                                                     \
        PyObject * soleArg;                                               \
        if (PyTuple_Size( args ) != 1 ||                                  \
            !PyString_Check( soleArg = PyTuple_GET_ITEM( args, 0 ) ) ||  \
            PyString_Size( soleArg ) != sizeof( POD_TYPE ))               \
        {                                                                 \
            PyErr_SetString( PyExc_TypeError, ... );                      \
        }                                                                 \
        PyObject * goodValue = Script::getData(                            \
            (POD_TYPE*)PyString_AsString( soleArg ) );                   \
        this->copy( *goodValue );                                        \
        Py_RETURN_NONE;                                                  \
    }
```

这种方式简单但限制多:类型必须是 POD,且需要支持 `copy` 方法。

---

## 十六、PyObjectPtr 智能指针

### 16.1 PyObjectPtr 定义

`lib/pyscript/pyobject_pointer.hpp`:

```cpp
typedef SmartPointer<PyObject> PyObjectPtr;
```

`PyObjectPtr` 只是 `SmartPointer<PyObject>` 的别名。`SmartPointer` 是 BigWorld 的引用计数智能指针模板,定义在 `cstdmf/smartpointer.hpp`。

### 16.2 SmartPointer 模板特化

`SmartPointer<T>` 通过调用 `incrementReferenceCount(const T&)` 和 `decrementReferenceCount(const T&)` 来管理引用计数。对于 `PyObject`,这两个函数被特化:

```cpp
// pyobject_pointer.hpp L20-44
template <>
inline void incrementReferenceCount( const PyObject & Q )
{
    Py_INCREF( const_cast<PyObject*>( &Q ) );   // Q guaranteed non-null
}

template <>
inline void decrementReferenceCount( const PyObject & Q )
{
    Py_DECREF( const_cast<PyObject*>( &Q ) );   // Q guaranteed non-null
}

template <>
inline bool hasZeroReferenceCount( const PyObject & Q )
{
    return (const_cast<PyObject*>( &Q )->ob_refcnt == 0);
}
```

这让 `SmartPointer<PyObject>` 自动调用 `Py_INCREF`/`Py_DECREF`,实现 C++ 端的 Python 引用计数管理。

### 16.3 SmartPointer 接口(节选)

```cpp
template <class T>
class SmartPointer
{
public:
    enum StealReferenceValueType { STEAL_REFERENCE };
    enum NewReferenceValueType    { NEW_REFERENCE };

    SmartPointer();
    SmartPointer( T * pObject, bool alreadyIncremented = false );
    SmartPointer( T * pObject, StealReferenceValueType );  // 接管新引用
    SmartPointer( const SmartPointer<T> & pObject );
    ~SmartPointer();

    SmartPointer<T> & operator=( const SmartPointer<T> & pObject );

    T * get() const;
    T * getObject() const;

    T * operator->() const;
    T & operator*() const;

    bool exists() const;
    operator unspecified_bool_type() const;  // safe bool
};
```

构造函数有三种模式:
- `SmartPointer(pObj, false)`:借用,INCREF。
- `SmartPointer(pObj, true)`:新引用,不 INCREF。
- `SmartPointer(pObj, STEAL_REFERENCE)`:同 `true`,语义更明确。

### 16.4 与 Python 引用计数的关系

BigWorld 的 `SmartPointer<PyObject>` 和 Python 的 `ob_refcnt` 是**同一个引用计数**:

```
C++ SmartPointer ─→ INCREF(ob_refcnt) ─→ Python GC 感知
                ─→ DECREF(ob_refcnt) ─→ ob_refcnt == 0 时调用 tp_dealloc
                                       ─→ PyObjectPlus::_tp_dealloc
                                       ─→ pyDel() + delete this
```

这意味着:
1. `SmartPointer<PyObject>` 析构时,可能触发 Python 对象的析构链(包括 `pyDel`)。
2. Python 端 `del obj` 也会触发 `SmartPointer` 析构(如果 C++ 持有最后一个引用)。
3. 没有"双重引用计数"开销(不像 `shared_ptr` + Python `Py_INCREF` 各自维护)。

### 16.5 ConstSmartPointer

BigWorld 还有 `ConstSmartPointer<T>`,语义类似但禁止修改对象:

```cpp
typedef ConstSmartPointer<PyObject> ConstPyObjectPtr;
```

`Script::getData(ConstSmartPointer<PyObject> data)` 重载接受这个类型,避免在只读场景下意外修改对象。

### 16.6 循环引用问题

`SmartPointer<PyObject>` 不解决循环引用。如果 A 持有 B 的 SmartPointer,B 持有 A 的 SmartPointer,两者的 `ob_refcnt` 永远不为 0,造成内存泄漏。

BigWorld 的解决方案:
1. **WeakPyPtr**:弱引用智能指针(见 [十七](#十七weakpyptr-弱引用))。
2. **PyObjectPlusWithWeakReference**:支持 Python weakref 协议的基类。
3. **手动破环**:在 `pyDel` 或 `pyClear` 中显式置空 SmartPointer。
4. **关闭 Python GC**:`Script::disablePythonGarbage()` 默认关闭,因为 BigWorld 不依赖 GC,而是依赖显式生命周期管理。

但 BigWorld 也保留了 GC 兼容路径:`PY_BASETYPEOBJECT` 宏(见 `pyobject_base.hpp`)生成的 `PyTypeObject` 包含 `Py_TPFLAGS_HAVE_GC` 标志和 `tp_traverse`/`tp_clear` 槽,允许子类实现 `pyTraverse`/`pyClear` 参与 GC。

---

## 十七、WeakPyPtr 弱引用

### 17.1 WeakPyPtr 模板

`script.hpp` L1297-1492 定义了 `WeakPyPtr<T>`:

```cpp
template <class Ty> class WeakPyPtr
{
public:
    static const bool STEAL_REFERENCE = true;
    static const bool NEW_REFERENCE = false;

    typedef Ty Object;
    typedef WeakPyPtr<Ty> This;

public:
    WeakPyPtr( Object * P = NULL, bool alreadyIncremented = false );
    WeakPyPtr( const This& P );
    This & operator=( const This& X );
    ~WeakPyPtr();

    const PyObject * getPyObj() const;
    const Object * get() const;
    Object * get();

    const Object * getObject() const;
    Object * getObject();

    bool hasObject() const;
    bool exists() const;
    bool good() const;

    const Object& operator*() const;
    Object & operator*();
    const Object* operator->() const;
    Object * operator->();

    // 比较运算符
    friend bool operator==( const WeakPyPtr<Ty>& A, const WeakPyPtr<Ty>& B );
    friend bool operator!=( const WeakPyPtr<Ty>& A, const WeakPyPtr<Ty>& B );
    friend bool operator<( const WeakPyPtr<Ty>& A, const WeakPyPtr<Ty>& B );
    friend bool operator>( const WeakPyPtr<Ty>& A, const WeakPyPtr<Ty>& B );

    operator unspecified_bool_type() const;

protected:
    mutable PyObject * weakref_;   // A PyWeakref to the object (1=dead).
};
```

### 17.2 WeakPyPtr 工作原理

`WeakPyPtr` 内部维护 `weakref_` 字段,有三种状态:

| `weakref_` 值 | 含义 |
|--------------|------|
| `0` (NULL) | 没有引用任何对象 |
| `1` | 对象已死亡(或不可弱引用) |
| `>1`(指针) | 一个 `PyWeakref` 对象,指向目标 |

构造时:

```cpp
WeakPyPtr( Object * P = NULL, bool alreadyIncremented = false )
{
    if (P != NULL) {
        weakref_ = PyWeakref_NewRef( P, NULL );  // 创建弱引用
        if (weakref_ == NULL) {
            // 对象不支持弱引用(没有 tp_weaklistoffset)
            weakref_ = (PyObject*)1;  // 标记为"死亡"
            PyErr_Clear();
        }
        if (alreadyIncremented) decrementReferenceCount( *P );
    }
    else weakref_ = NULL;
}
```

`PyWeakref_NewRef` 创建 Python 的 `weakref.ref` 对象,目标对象死亡时自动失效。如果目标类型没有 `tp_weaklistoffset`(即不是 `PY_TYPEOBJECT_WITH_WEAKREF`),返回 NULL,`WeakPyPtr` 退化为"立即失效"。

### 17.3 get() 与 good()

```cpp
const PyObject * getPyObj() const
{
    if (uintptr(weakref_) > 1) {
        PyObject * P = PyWeakref_GET_OBJECT( weakref_ );
        if (P != Py_None) return (const Object*)P;  // 对象还活着

        weakref_ = (PyObject*)1;  // 标记死亡,下次直接跳过
    }
    return NULL;
}

bool good() const
{
    if (uintptr(weakref_) <= 1) return false;
    if (PyWeakref_GET_OBJECT( weakref_ ) != Py_None) return true;
    // 对象刚死亡,更新状态
    weakref_ = (PyObject*)1;
    return false;
}
```

`good()` 是惰性检查:只在调用时查询 `PyWeakref_GET_OBJECT`。一旦发现死亡,立即更新 `weakref_` 为 `1`,后续调用直接返回 false,避免重复查询。

### 17.4 与 SmartPointer 的区别

| 特性 | SmartPointer<PyObject> | WeakPyPtr<T> |
|------|------------------------|--------------|
| 引用计数 | 增加引用 | 不增加 |
| 阻止 GC | 是 | 否 |
| 循环引用 | 会泄漏 | 不会泄漏 |
| 可空 | 是 | 是 |
| 失效检测 | 无需(永不过期) | 需要(good()) |

`WeakPyPtr` 主要用于:
1. **缓存**:避免缓存持有对象阻止其释放。
2. **回调列表**:监听器弱引用,对象销毁时自动从列表移除。
3. **父子关系**:子对象弱引用父对象,避免循环。

### 17.5 PyObjectPlusWithWeakReference

如果要让一个 `PyObjectPlus` 子类支持 `WeakPyPtr`,需要:

```cpp
class MyType : public PyObjectPlus
{
    Py_Header( MyType, PyObjectPlus )
    PY_WEAK_REFERENCABLE( MyType )  // 添加 _py_pWeakRefList 成员
    // ...
};

PY_TYPEOBJECT_WITH_WEAKREF( MyType )  // 类型对象支持 weakref
```

`PY_WEAK_REFERENCABLE` 展开:

```cpp
#define PY_WEAK_REFERENCABLE( THIS_CLASS )                                \
    PyObject *  _py_pWeakRefList;                                        \
    PyWeakRefListManager< THIS_CLASS > _py_weakRefListManager;           \
    friend class PyWeakRefListManager< THIS_CLASS >;                     \
    template< typename T >                                               \
    friend Py_ssize_t PyTypeObjectUtil::weakListOffset();
```

`PyWeakRefListManager` 在析构时调用 `PyObject_ClearWeakRefs`:

```cpp
template< class PYWEAKREFERENCABLE >
class PyWeakRefListManager
{
public:
    PyWeakRefListManager() {
        pOwner()->_py_pWeakRefList = NULL;
    }
    ~PyWeakRefListManager() {
        PYWEAKREFERENCABLE * pOwner = this->pOwner();
        if (pOwner->_py_pWeakRefList == NULL) return;
        PyObject_ClearWeakRefs( static_cast< PyObject * >( pOwner ) );
    }
private:
    PYWEAKREFERENCABLE * pOwner() {
        return bw_container_of( this, PYWEAKREFERENCABLE, _py_weakRefListManager );
    }
};
```

`bw_container_of` 是 BigWorld 的 `container_of` 实现,通过成员偏移反推宿主对象指针。

---

## 十八、Python 模块组织

### 18.1 BigWorld 模块

每个 BigWorld 进程都有一个 `BigWorld` Python 模块,作为引擎暴露给脚本的入口。`Script::init` 创建这个模块:

```cpp
// script.cpp L448-459
ScriptModule bigWorld = ScriptModule::getOrCreate( "BigWorld",
    ScriptErrorPrint( "Failed to create BigWorld module" ) );

bigWorld.setAttribute( "component",
    ScriptString::create( componentName ),
    ScriptErrorPrint() );
```

`component` 属性标识当前进程类型(`'cell'`、`'base'`、`'client'`、`'database'`、`'bot'`、`'editor'`),让脚本能根据进程类型分支。

### 18.2 模块注册机制

C++ 代码通过宏把函数、类型、属性注册到模块:

| 宏 | 注册内容 |
|----|---------|
| `PY_MODULE_FUNCTION(FUNC_NAME, MODULE_NAME)` | 普通 C 函数 |
| `PY_MODULE_FUNCTION_WITH_KEYWORDS(FUNC_NAME, MODULE_NAME)` | 带关键字的 C 函数 |
| `PY_AUTO_MODULE_FUNCTION(RET, FUNC_NAME, ARGS, MODULE_NAME)` | 自动解析参数的 C 函数 |
| `PY_MODULE_FUNCTION_ALIAS(OLD_NAME, NEW_NAME, MODULE_NAME)` | 函数别名 |
| `PY_MODULE_STATIC_METHOD(THIS_CLASS, METHOD_NAME, MODULE_NAME)` | 类的静态方法 |
| `PY_MODULE_ATTRIBUTE(MODULE_NAME, OBJECT_NAME, EXPR)` | 模块属性 |
| `PY_FACTORY(THIS_CLASS, MODULE_NAME)` | 类型(通过工厂方法) |
| `PY_FACTORY_NAMED(THIS_CLASS, METHOD_NAME, MODULE_NAME)` | 类型(自定义名) |

这些宏都通过 `PyModuleMethodLink`、`PyModuleAttrLink`、`PyModuleResultLink`、`PyFactoryMethodLink` 等 `InitTimeJob` 子类实现。它们在静态初始化时构造,在 `Script::init` 时统一调用 `init()` 把自己注册到指定模块。

### 18.3 PyModuleMethodLink 机制

```cpp
// script.hpp L1218-1240
class PyModuleMethodLink : public Script::InitTimeJob
{
public:
    PyModuleMethodLink( const char * moduleName,
        const char * methodName, PyCFunction method,
        const char * docString = NULL );
    PyModuleMethodLink( const char * moduleName,
        const char * methodName, PyCFunctionWithKeywords method,
        const char * docString = NULL );
    ~PyModuleMethodLink();

    const char * moduleName()    { return moduleName_; }
    const char * methodName()    { return methodName_; }

    virtual void init();

private:
    PyMethodDef    mdReal_;
    PyMethodDef    mdStop_;
    const char *    moduleName_;
    const char *    methodName_;
};
```

构造函数填充 `mdReal_`(实际方法定义)和 `mdStop_`(哨兵,NULL 终止):

```cpp
// script.cpp L1108-1163
PyModuleMethodLink::PyModuleMethodLink( const char * moduleName,
        const char * methodName, PyCFunction method,
        const char * docString ) :
    Script::InitTimeJob( 0 ),  // rung 0:模块链接阶段
    moduleName_( moduleName ),
    methodName_( methodName )
{
    mdReal_.ml_name = const_cast< char * >( methodName_ );
    mdReal_.ml_meth = method;
    mdReal_.ml_flags = METH_VARARGS;
    mdReal_.ml_doc = const_cast< char * >( docString );

    mdStop_.ml_name = NULL;
    mdStop_.ml_meth = NULL;
    mdStop_.ml_flags = 0;
    mdStop_.ml_doc = NULL;
}

void PyModuleMethodLink::init()
{
    Py_InitModule( const_cast<char *>(moduleName_), &mdReal_ );
}
```

`init()` 调用 `Py_InitModule` 把方法添加到模块。`Py_InitModule` 是 Python 2 的旧式 API(被 Python 3 的 `PyModule_Create` 取代),它接受一个 `PyMethodDef` 数组,遇到 NULL 名字停止。BigWorld 用 `mdReal_ + mdStop_` 两个元素的"伪数组"来调用这个 API。

### 18.4 PyModuleAttrLink / PyModuleResultLink

```cpp
// script.cpp L1173-1238
class PyModuleAttrLink : public Script::InitTimeJob
{
    // ...
    virtual void init()
    {
        PyObject_SetAttrString(
            PyImport_AddModule( const_cast<char *>( moduleName_ ) ),
            const_cast<char *>( objectName_ ),
            pObject_ );
        Py_DECREF( pObject_ );  // 模块接管引用
    }
};

class PyModuleResultLink : public Script::InitTimeJob
{
public:
    PyModuleResultLink( const char * moduleName,
        const char * objectName, PyObject * pObject ) :
        Script::InitTimeJob( 0 ),
        moduleName_( moduleName ),
        objectName_( objectName ),
        pObject_( pObject )
    {}

    virtual void init()
    {
        // 与 PyModuleAttrLink 类似,但 pObject_ 来自表达式求值
        // (用于 PY_AUTO_MODULE_FUNCTION 的返回值注册等场景)
        PyObject_SetAttrString(
            PyImport_AddModule( const_cast<char *>( moduleName_ ) ),
            const_cast<char *>( objectName_ ),
            pObject_ );
        Py_DECREF( pObject_ );
    }

private:
    const char * moduleName_;
    const char * objectName_;
    PyObject *   pObject_;
};
```

`PyModuleAttrLink` 与 `PyModuleResultLink` 都通过 `PyObject_SetAttrString` 把对象附加到模块,区别在于:
- `PyModuleAttrLink`:构造时已确定 `pObject_`(常量对象,如预定义字典)。
- `PyModuleResultLink`:对象可能延迟到 `init()` 才求值(用于 `PY_AUTO_MODULE_FUNCTION` 返回值类型推导)。

### 18.5 PY_AUTO_MODULE_FUNCTION 展开

`PY_AUTO_MODULE_FUNCTION(RET, FUNC, ARGS, MODULE)` 是最常用的注册宏,展开后:

```cpp
#define PY_AUTO_MODULE_FUNCTION( RET, FUNC, ARGS, MODULE )                  \
    static PyObject * s_##FUNC##_wrapper( PyObject * self, PyObject * args ) \
    {                                                                       \
        RET result = FUNC( ARGS::unpack( args ) );                          \
        return Script::getData( result );                                   \
    }                                                                       \
    static PyModuleMethodLink s_##FUNC##_link(                              \
        #MODULE, #FUNC, s_##FUNC##_wrapper, "" );                            \
    /* 强制链接器保留静态对象 */                                              \
    FORCE_LINK_THIS( s_##FUNC##_link );
```

关键点:
1. **静态包装函数**:把 C++ 函数包装成 `PyCFunction`,内部用 `ARGS::unpack(args)` 自动解析 Python 参数到 C++ 类型。
2. **静态 `PyModuleMethodLink` 对象**:在静态初始化时构造,注册到 `Script::InitTimeJob` 队列。
3. **`FORCE_LINK`**:防止链接器在 /OPT:REF 等优化时丢弃静态对象。

### 18.6 各进程的 Python 模块组织

```
┌─────────────────────────────────────────────────────────────┐
│                    进程启动流程                              │
├─────────────────────────────────────────────────────────────┤
│  1. Script::init(paths, componentName)                      │
│     ├─ Py_Initialize()                                      │
│     ├─ PyImportPaths::addResPath(...)  // 添加 scripts/ 路径│
│     ├─ 创建 "BigWorld" 模块                                  │
│     ├─ 设置 BigWorld.component = 'cell' / 'base' / ...      │
│     └─ 运行所有 InitTimeJob::init()  // 注册函数/类型        │
│                                                              │
│  2. Personality::import("BWPersonality")                    │
│     └─ import BWPersonality.py                              │
│        ├─ 顶级代码执行(注册监听器、初始化数据)             │
│        └─ 定义 onInit / onFini 回调                         │
│                                                              │
│  3. Personality::callOnInit()                                │
│     └─ BWPersonality.onInit(isReload=False)                 │
│        ├─ 加载实体脚本 import cellapp                        │
│        ├─ import Avatar, NPC, Account 等实体类               │
│        └─ 注册全局监听器                                     │
│                                                              │
│  4. 进入主循环                                               │
│     └─ BigWorld.tick() 每 frame 调用                         │
│        ├─ Script::tick() // Python tracing                   │
│        └─ ScriptEvents::triggerEvent("onTick")               │
└─────────────────────────────────────────────────────────────┘
```

### 18.7 模块加载路径

`PyImportPaths::addResPath` 把 BWResource 路径加到 `sys.path`,使 Python `import` 能找到引擎脚本:

```cpp
// py_import_paths.hpp
class PyImportPaths
{
public:
    void addResPath( const BW::string &resPath )
    {
        BW::string absPath;
        BWResource::resolveToAbsolutePath( resPath, absPath );
        paths_.push_back( absPath );
    }

    void addToPython()
    {
        PyObject * sysPath = PySys_GetObject( "path" );
        for (size_t i = 0; i < paths_.size(); ++i) {
            PyObject * pPath = PyString_FromString( paths_[i].c_str() );
            PyList_Insert( sysPath, i, pPath );
            Py_DECREF( pPath );
        }
    }

private:
    BW::vector< BW::string > paths_;
};
```

`addToPython` 把 BWResource 路径**插入到 sys.path 前端**,确保引擎自带脚本优先于环境 Python 库被找到。

### 18.8 bw_site 模块

BigWorld 通过 `BWResource::getPathSectionList()` 维护多个搜索根(如 `res/`、`res_addon/`、用户自定义路径)。每个根可以有自己的 `scripts/` 目录,引擎按优先级合并。`bw_site` 是一个特殊的"站点"模块,允许在不同安装根下覆盖脚本:

```python
# res_addon/scripts/site_overrides/bw_site.py
import BigWorld
def onPersonalityLoaded():
    # 在 personality 加载后运行,可注册额外的全局监听器
    pass
```

引擎在 `Script::init` 末尾尝试 `import bw_site`,如果存在就调用其 `onPersonalityLoaded()` 钩子,让扩展包在不修改主 personality 的情况下注入逻辑。

### 18.9 模块重载

`ScriptModule::reload` 包装 `PyImport_ReloadModule`,用于热重载:

```cpp
// py_script_module.ipp
bool ScriptModule::reload( const ERROR_HANDLER & errorHandler )
{
    PyObject * pReloaded = PyImport_ReloadModule( this->get() );
    if (!pReloaded) {
        errorHandler.handleError();
        return false;
    }
    Py_DECREF( pReloaded );  // 模块自己持有新引用
    return true;
}
```

BigWorld 在服务端支持热重载:
- `Personality::import` 在 `isReload=true` 时调用 `reload`。
- CellApp 通过 `BaseAppMgr` 广播 reload 命令到所有进程。
- 客户端在 `bwiPersonality::reload` 时收 reload 命令并执行。

但 Python 热重载有局限:
1. **类型对象不可热重载**:`PyTypeObject` 在已注册模块中时,`PyImport_ReloadModule` 不会更新类型表。已存在的实例仍指向旧类型。
2. **模块引用**:`import Avatar` 后 `Avatar` 已绑定到模块对象;reload 后外部模块仍持有旧引用。
3. **全局状态**:模块级全局变量在 reload 时丢失(除非代码主动保存到 `BigWorld._state`)。

BigWorld 因此把热重载限定于"逻辑脚本"层,实体类等核心类型不能热重载。

---

## 十九、InitTimeJob / FiniTimeJob 体系

### 19.1 静态注册模式

BigWorld 的 Python 类型、模块函数、模块属性注册都使用**静态注册模式**:

```cpp
class MyClass : public PyObjectPlus {
    Py_Header( MyClass, PyObjectPlus )
    // ...
};

PY_TYPEOBJECT( MyClass )
PY_BEGIN_METHODS( MyClass )
    PY_METHOD( foo )
PY_END_METHODS()
PY_BEGIN_ATTRIBUTES( MyClass )
    PY_ATTRIBUTE( bar )
PY_END_ATTRIBUTES()

// 文件末尾:
PY_FACTORY( MyClass, BigWorld )
```

`PY_FACTORY( MyClass, BigWorld )` 展开为一个静态对象:

```cpp
static PyFactoryMethodLink s_MyClass_link( "BigWorld", "MyClass",
    &MyClass::s_type_ );
FORCE_LINK_THIS( s_MyClass_link );
```

构造函数把 `s_MyClass_link` 加入 `Script::s_initTimeJobsMap`(`InitTimeJob` 队列)。

### 19.2 InitTimeJob 数据结构

```cpp
// script.hpp L1100-1140
class Script::InitTimeJob
{
public:
    InitTimeJob( int rung ) : rung_( rung ), pNext_( NULL ), pPrev_( NULL )
    {
        // 自动注册到 s_pendingJobs 链表
        s_pendingJobs.push_back( this );
    }

    virtual ~InitTimeJob() {}

    virtual void init() = 0;

    int rung() const { return rung_; }

private:
    int rung_;  // 优先级,越小越先 init
    InitTimeJob * pNext_;
    InitTimeJob * pPrev_;
};
```

`rung` 是"梯级"编号,控制 init 顺序:
- `rung 0`:模块链接(`PyModuleMethodLink`、`PyFactoryMethodLink`)。
- `rung 100`:类型校验、工厂注册。
- `rung 1000`:用户脚本加载。

### 19.3 Script::init 中的批量执行

```cpp
// script.cpp L426-470 (简化)
bool Script::init( const PyImportPaths & paths, const char * componentName )
{
    // 1. Py_Initialize
    if (!s_isInited_) {
        Py_Initialize();
        paths.addToPython();
        s_isInited_ = true;
    }

    // 2. BigWorld 模块
    ScriptModule bigWorld = ScriptModule::getOrCreate( "BigWorld", ... );
    bigWorld.setAttribute( "component", ScriptString::create( componentName ) );

    // 3. 运行所有 InitTimeJob,按 rung 排序
    s_pendingJobs.sort( compareByRung );
    while (!s_pendingJobs.empty()) {
        InitTimeJob * pJob = s_pendingJobs.front();
        s_pendingJobs.pop_front();
        pJob->init();
        // 注意:不 delete,因为静态对象生命周期到进程结束
    }

    // 4. Pickler::init
    Pickler::init();

    return true;
}
```

### 19.4 FiniTimeJob 体系

`FiniTimeJob` 与 `InitTimeJob` 对称,用于在 `Script::fini` 时清理:

```cpp
class Script::FiniTimeJob
{
public:
    FiniTimeJob( int rung = 0 ) : rung_( rung )
    {
        s_finiTimeJobsMap[ rung ].push_back( this );
    }

    virtual ~FiniTimeJob() {}

    virtual void fini() = 0;

    int rung() const { return rung_; }
};
```

`Script::fini` 按 rung 倒序执行(大 rung 先 fini),确保依赖关系:

```cpp
// script.cpp L490-510 (简化)
void Script::fini()
{
    if (!s_isInited_) return;

    // 1. 运行所有 FiniTimeJob,按 rung 倒序
    for (auto it = s_finiTimeJobsMap.rbegin();
              it != s_finiTimeJobsMap.rend(); ++it)
    {
        for (auto * pJob : it->second) {
            pJob->fini();
        }
    }

    // 2. Pickler::finalise
    Pickler::finalise();

    // 3. Py_Finalize
    Py_Finalize();
    s_isInited_ = false;
}
```

### 19.5 典型 FiniTimeJob

`PersonalityFiniTimeJob` 已在 §14.4 介绍。其它典型 FiniTimeJob:

| 类 | rung | 作用 |
|----|------|------|
| `PersonalityFiniTimeJob` | `INT_MAX`(最后) | 调用 `onFini`,清空 `s_pInstance_` |
| `PyFactoryMethodLink::fini` | 默认 | 恢复 `tp_name` 为原始字符串 |
| `DeferredFiniJob` | `INT_MAX - 1` | 清理 `PyDeferred` 全局状态 |
| 用户自定义 | 用户指定 | 业务模块的清理逻辑 |

### 19.6 FORCE_LINK 与链接器优化

`FORCE_LINK_THIS( name )` 在 MSVC 下展开为:

```cpp
#pragma comment(linker, "/INCLUDE:?s_MyClass_link@...")
```

或在 GCC/Clang 下:

```cpp
__attribute__((used)) static void * s_MyClass_link_anchor = &s_MyClass_link;
```

这告诉链接器"即使没有代码引用此符号,也不要丢弃"。否则静态库中的注册代码会被 `/OPT:REF` 优化掉,导致 `s_type_` 不被初始化。

---

## 二十、Python 实体类

### 20.1 实体类的双面性

BigWorld 实体类是 C++ `Entity` 类与 Python 脚本类的**双面对象**:

- C++ 端:`cellapp/entity.hpp` 的 `Entity` 类继承 `PyObjectPlus`,有 `cell_` / `base_` / `client_` 三个 `Mailbox`。
- Python 端:`scripts/cell/<Entity>.py` 的 `Avatar` 类继承 `BigWorld.Entity`,可在 `__init__`、`onGetToCell` 等回调里写逻辑。

两者通过 `Entity::pType()` 反射机制和 `EntityDescription` 元数据建立映射。

### 20.2 Entity 类的 Py_Header

```cpp
// cellapp/entity.hpp (简化)
class Entity : public PyObjectPlus
{
    Py_Header( Entity, PyObjectPlus )

public:
    Entity( EntityDescription & description, EntityTypePtr pType,
            bool isBaseEntity = false );
    ~Entity();

    // Python 方法
    PY_AUTO_METHOD_DECLARE( RETVOID, destroy, ARG_END )
    PY_AUTO_METHOD_DECLARE( RETVOID, addTimer, ARG( float, float, int, END ) )

    // Python 属性
    PY_AUTO_ATTRIBUTE( id )
    PY_AUTO_ATTRIBUTE( position )
    PY_AUTO_ATTRIBUTE( direction )
    // ...

private:
    SpaceID       spaceID_;
    EntityID      id_;
    Position3D    position_;
    Direction3D   direction_;
    // ...
};

PY_TYPEOBJECT( Entity )
PY_BEGIN_METHODS( Entity )
    PY_METHOD( destroy )
    PY_METHOD( addTimer )
PY_END_METHODS()
PY_BEGIN_ATTRIBUTES( Entity )
    PY_ATTRIBUTE( id )
    PY_ATTRIBUTE( position )
    PY_ATTRIBUTE( direction )
PY_END_ATTRIBUTES()
```

`Py_Header( Entity, PyObjectPlus )` 声明:
- `Entity::s_type_`:类型对象。
- `Entity::Check(pObj)`:类型检查。
- `Entity::s_typeName_`:`"Entity"`。

### 20.3 Python 端的实体类

```python
# scripts/cell/Avatar.py
import BigWorld

class Avatar( BigWorld.Entity ):
    def __init__( self ):
        # 构造完成后回调;注意此时 self.id 已可用
        BigWorld.Entity.__init__( self )
        self.health = 100
        self.inventory = {}

    def onGetToCell( self ):
        # 实体首次到达某 cell 时调用
        pass

    def onLoseCell( self ):
        # 实体离开 cell 时调用
        pass

    def takeDamage( self, amount, attackerID ):
        self.health -= amount
        if self.health <= 0:
            self.destroy()
            BigWorld.entities[ attackerID ].onKill( self.id )
```

### 20.4 实体的 C++ ↔ Python 调用流

```
┌──────────────────────────────────────────────────────────┐
│  Python 调用 C++:                                        │
│                                                          │
│  python: avatar.destroy()                                │
│         │                                                │
│         ▼                                                │
│  Entity::s_type_.tp_getattro("destroy")                 │
│         │                                                │
│         ▼                                                │
│  PyObjectPlus::pyGetAttribute → 返回 method wrapper     │
│         │                                                │
│         ▼                                                │
│  wrapper(self, args) → Entity::destroy(self)            │
└──────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────┐
│  C++ 调用 Python:                                        │
│                                                          │
│  C++: entity_->callMethod("onGetToCell", args)          │
│         │                                                │
│         ▼                                                │
│  ScriptObject::callMethod → ScriptObject::getAttribute  │
│         │                                                │
│         ▼                                                │
│  PyObject_GetAttrString(pEntity, "onGetToCell")         │
│         │                                                │
│         ▼                                                │
│  PyObject_CallObject(method, args)                      │
└──────────────────────────────────────────────────────────┘
```

### 20.5 实体生命周期回调

Python 端可定义以下回调,由 C++ 引擎在合适时机调用:

| 回调 | 时机 |
|------|------|
| `__init__(self)` | C++ 构造完成后立即调用 |
| `onGetToCell(self)` | 实体首次进入某 cell |
| `onLoseCell(self)` | 实体离开 cell(被销毁或迁移) |
| `onRestore(self)` | 从存档加载后调用 |
| `onNameChanged(self, oldName)` | 名字变更时 |
| `onSpaceGone(self)` | 空间被销毁 |
| `onTimer(self, handle, userData)` | 定时器回调 |
| `onGhostProxyAdded(self, num)` | Ghost 数量变化 |
| `onGhostProxyRemoved(self, num)` | Ghost 数量变化 |

C++ 端通过 `Entity::callback(methodName, args, errorHandler)` 统一调用:

```cpp
// cellapp/entity.cpp (简化)
void Entity::callback( const char * methodName, const ScriptArgs & args,
        const ScriptErrorPrint & errorHandler )
{
    ScriptObject self( this, ScriptObject::FROM_BORROWED_REFERENCE );
    self.callMethod( methodName, args, errorHandler, /* allowNull */ true );
}
```

`allowNull=true` 让没定义回调的实体类不报错(兼容老脚本)。

### 20.6 实体属性访问

C++ 端属性通过 `PY_AUTO_ATTRIBUTE` 宏暴露:

```cpp
PY_AUTO_ATTRIBUTE( id )  // 暴露 Entity::id() / setId()
```

展开为 `pyGetAttribute` 中的分支:

```cpp
if (strcmp(name, "id") == 0) {
    return Script::getData( this->id() );  // 调用 getter,返回 PyObject
}
```

和 `pySetAttribute` 中的:

```cpp
if (strcmp(name, "id") == 0) {
    EntityID value;
    if (Script::setData( value, pObject, "id" ) == 0) {
        this->setId( value );
        return 0;
    }
    return -1;
}
```

但 `id` 是只读属性(不允许外部 set),BigWorld 通过 `PropertyGet` / `PropertySet` 区分:只读属性只注册 getter 分支。

---

## 二十一、Python 方法调用流程

### 21.1 完整调用栈

从 Python 端 `avatar.addTimer(5, 0, 0)` 到 C++:

```
1. Python 解释器
   avatar.addTimer(5, 0, 0)
        │
        ▼
2. Entity::s_type_.tp_getattro("addTimer")
        │
        ▼
3. PyObjectPlus::pyGetAttribute
   - 先查 s_type_.tp_dict("addTimer" 方法描述)
   - 返回 PyMethodDescr 对象
        │
        ▼
4. PyMethodDescr.__call__(self, (5, 0, 0))
        │
        ▼
5. Entity::addTimer_wrapper(self, args)
   (PY_AUTO_METHOD 生成的静态包装函数)
        │
        ▼
6. Script::setData(args[0], float, "delay")   // 解析 5
   Script::setData(args[1], float, "offset")  // 解析 0
   Script::setData(args[2], int, "user")      // 解析 0
        │
        ▼
7. Entity::addTimer(self, delay, offset, user)
        │
        ▼
8. TimerHandle h = this->addTimer(delay, offset, user, "Avatar")
   // 真正的 C++ 实现
        │
        ▼
9. return Script::getData(h)  // 返回 Python
```

### 21.2 参数解析

`PY_AUTO_METHOD` 生成的包装用 `Script::setData` 逐参数解析。`Script::setData` 有大量重载(见 §12),根据 C++ 类型自动选择:

```cpp
// script.cpp L1500-1520
int Script::setData( PyObject * pObject, float & rValue,
        const char * varName )
{
    double d = PyFloat_AsDouble( pObject );
    if (d == -1.0 && PyErr_Occurred()) {
        PyErr_Format( PyExc_TypeError, "%s must be float", varName );
        return -1;
    }
    rValue = float(d);
    return 0;
}

int Script::setData( PyObject * pObject, int & rValue,
        const char * varName )
{
    long l = PyInt_AsLong( pObject );
    if (l == -1 && PyErr_Occurred()) {
        PyErr_Format( PyExc_TypeError, "%s must be int", varName );
        return -1;
    }
    rValue = int(l);
    return 0;
}
```

### 21.3 错误处理

`PY_AUTO_METHOD` 包装自动处理类型错误:`setData` 返回 -1 时,`PyErr_Format` 已设置异常,包装函数返回 NULL,Python 解释器抛出异常:

```python
>>> avatar.addTimer("five", 0, 0)
TypeError: delay must be float
```

如果 C++ 方法抛 `std::exception`,BigWorld 在 `script.cpp` 安装的 `PySet_ExceptHook` 会捕获并转换为 Python 异常。

### 21.4 返回值转换

C++ 返回值通过 `Script::getData` 转换为 PyObject:

```cpp
PyObject * Script::getData( int value )
{
    return PyInt_FromLong( value );
}

PyObject * Script::getData( float value )
{
    return PyFloat_FromDouble( value );
}

PyObject * Script::getData( const BW::string & value )
{
    return PyString_FromString( value.c_str() );
}

PyObject * Script::getData( const Vector3 & value )
{
    return PyTuple_Pack( 3,
        PyFloat_FromDouble(value.x),
        PyFloat_FromDouble(value.y),
        PyFloat_FromDouble(value.z) );
}
```

每个 `getData` 重载对应一个 Python 类型。复杂的(如 `ScriptObject`、`ScriptList`)直接借用现有 PyObject。

### 21.5 callMethod 的实际实现

`ScriptObject::callMethod` 在 `py_script_object.ipp`:

```cpp
template <class ERROR_HANDLER>
inline ScriptObject ScriptObject::callMethod(
    const char * methodName, const ScriptArgs & args,
    const ERROR_HANDLER & errorHandler,
    bool allowNullMethod ) const
{
    PyErr_Clear();

    ScriptObject method = this->getAttribute( methodName,
        ScriptErrorRetain() );

    if (!method) {
        if (allowNullMethod) {
            Script::clearError();
        } else {
            errorHandler.handleError();
        }
        return ScriptObject();
    }

    return method.callFunction( args, errorHandler );
}
```

关键点:
1. **`ScriptErrorRetain`**:获取属性失败时**保留**异常状态,不立即打印。
2. **`allowNullMethod`**:为 true 时清异常返回空 `ScriptObject`,让调用方判断。
3. **`callFunction`**:用 `PyObject_CallObject` 调用,把 `ScriptArgs` 转换为 tuple。

### 21.6 ScriptArgs 构造

```cpp
// py_script_object.hpp
class ScriptArgs
{
public:
    static ScriptArgs create( PyObject * pArgs )
    {
        return ScriptArgs( pArgs, ScriptObject::FROM_BORROWED_REFERENCE );
    }

    template <class T1>
    static ScriptArgs create( T1 v1 )
    {
        ScriptTuple tuple = ScriptTuple::create( 1 );
        tuple.setItem( 0, ScriptObject::createFrom( v1 ) );
        return ScriptArgs( tuple );
    }

    template <class T1, class T2>
    static ScriptArgs create( T1 v1, T2 v2 )
    {
        ScriptTuple tuple = ScriptTuple::create( 2 );
        tuple.setItem( 0, ScriptObject::createFrom( v1 ) );
        tuple.setItem( 1, ScriptObject::createFrom( v2 ) );
        return ScriptArgs( tuple );
    }

    // ... 更多重载 ...
    static ScriptArgs none()
    {
        return ScriptArgs( ScriptTuple::create( 0 ) );
    }
};
```

`ScriptArgs::create(v1, v2, ...)` 用模板生成对应元数的 tuple,通过 `ScriptObject::createFrom` 把 C++ 值转为 PyObject。这种模板链式调用让 C++ → Python 的调用非常自然:

```cpp
entity->callMethod( "onHit", ScriptArgs::create( damage, attackerID ),
    ScriptErrorPrint( "onHit" ), /* allowNull */ true );
```

---

## 二十二、ScriptModule 模块系统

### 22.1 ScriptModule 接口

`ScriptModule` 是 `ScriptObject` 派生类,封装 `PyModuleObject`:

```cpp
// py_script_object.hpp
class ScriptModule : public ScriptObject
{
public:
    ScriptModule() : ScriptObject() {}
    ScriptModule( PyObject * pObj, RefConstraint rc = STEAL_REFERENCE )
        : ScriptObject( pObj, rc ) {}

    static ScriptModule getOrCreate( const char * name,
        const ErrorHandler & errorHandler );
    static ScriptModule import( const char * name,
        const ErrorHandler & errorHandler );
    bool reload( const ErrorHandler & errorHandler );

    bool addObject( const char * name, ScriptObject object,
        const ErrorHandler & errorHandler );
    bool setAttribute( const char * name, ScriptObject value,
        const ErrorHandler & errorHandler );
    ScriptObject getAttribute( const char * name,
        const ErrorHandler & errorHandler ) const;
};
```

### 22.2 getOrCreate 实现

```cpp
// py_script_module.ipp
template <class ERROR_HANDLER>
ScriptModule ScriptModule::getOrCreate( const char * name,
    const ERROR_HANDLER & errorHandler )
{
    PyObject * pModule = PyImport_AddModule( name );
    if (!pModule) {
        errorHandler.handleError();
        return ScriptModule();
    }

    // 如果模块不存在,PyImport_AddModule 会创建一个空模块对象
    // 但不加入 sys.modules
    PyObject * pBuiltin = PyImport_AddModule( "__builtin__" );
    if (pBuiltin) {
        // 确保模块在 sys.modules 中
        PyObject * sysModules = PyImport_GetModuleDict();
        if (!PyDict_GetItemString( sysModules, name )) {
            PyDict_SetItemString( sysModules, name, pModule );
        }
    }

    return ScriptModule( pModule, FROM_BORROWED_REFERENCE );
}
```

`PyImport_AddModule` 不执行模块代码,只创建空模块对象。如果要执行代码,用 `import`。

### 22.3 import 实现

```cpp
template <class ERROR_HANDLER>
ScriptModule ScriptModule::import( const char * name,
    const ERROR_HANDLER & errorHandler )
{
    PyObject * pModule = PyImport_ImportModule( name );
    if (!pModule) {
        errorHandler.handleError();
        return ScriptModule();
    }
    return ScriptModule( pModule, FROM_NEW_REFERENCE );
}
```

`PyImport_ImportModule` 完整执行模块加载流程:
1. 查 `sys.modules` 是否已加载。
2. 否则按 `sys.path` 查找 `.py` / `.pyc`。
3. 编译为 bytecode(`.pyc` 缓存)。
4. 执行模块顶级代码。
5. 加入 `sys.modules`。
6. 返回模块对象。

### 22.4 addObject vs setAttribute

```cpp
// py_script_module.ipp
template <class ERROR_HANDLER>
bool ScriptModule::addObject( const char * name,
    ScriptObject object, const ERROR_HANDLER & errorHandler )
{
    // addObject 把对象加入模块的 __dict__,并增加引用计数
    int result = PyModule_AddObject( this->get(),
        const_cast<char *>(name), object.get() );
    if (result == -1) {
        errorHandler.handleError();
        return false;
    }
    // PyModule_AddObject 会 steal 引用,这里要 release
    object.detach();
    return true;
}

template <class ERROR_HANDLER>
bool ScriptModule::setAttribute( const char * name,
    ScriptObject value, const ERROR_HANDLER & errorHandler )
{
    int result = PyObject_SetAttrString( this->get(), name, value.get() );
    if (result == -1) {
        errorHandler.handleError();
        return false;
    }
    return true;
}
```

区别:
- `addObject`:借 `PyModule_AddObject` 实现,**steal 引用**(调用方不需 DECREF)。用于模块初始化时一次性赋值。
- `setAttribute`:借 `PyObject_SetAttrString` 实现,**保留引用**(引用计数被增加,调用方继续持有)。用于运行时动态修改模块属性。

### 22.5 模块级错误处理

`ScriptErrorPrint`、`ScriptErrorClear`、`ScriptErrorRetain` 三种策略:

| 策略 | 错误时行为 | 适用场景 |
|------|-----------|---------|
| `ScriptErrorPrint` | 打印 traceback,清异常 | 用户可见的入口 |
| `ScriptErrorClear` | 静默清异常 | 容错查询(如可选属性) |
| `ScriptErrorRetain` | 保留异常状态 | 链式调用(由上层决定) |
| `ScriptErrorThrow` | 抛 `std::runtime_error` | 必须 C++ 处理的错误 |

示例:

```cpp
ScriptModule personality = Personality::instance();

// 必须 onInit 存在并成功调用
personality.callMethod( "onInit", args,
    ScriptErrorPrint( "onInit failed" ) );

// onRestore 可选,不存在不报错
personality.callMethod( "onRestore", args,
    ScriptErrorClear(), /* allowNull */ true );
```

---

## 二十三、循环引用处理

### 23.1 Python GC 与 BigWorld 类型

Python 2 的 GC 通过 `tp_traverse` / `tp_clear` 处理循环引用。`PyObjectPlus` 默认实现 `tp_traverse` 为 NULL(不参与 GC),但子类可以用 `PY_TYPEOBJECT_SPECIALISE_GC` 启用:

```cpp
#define PY_TYPEOBJECT_SPECIALISE_GC( TYPE )                                \
    TYPE::s_type_.tp_flags |= Py_TPFLAGS_HAVE_GC;                          \
    TYPE::s_type_.tp_traverse = TYPE::tp_traverse;                         \
    TYPE::s_type_.tp_clear = TYPE::tp_clear;
```

启用后,Python GC 在扫描循环引用时会调用 `tp_traverse` 遍历子对象,在释放时调用 `tp_clear` 断开引用。

### 23.2 pyTraverse / pyClear 实现

测试用例 `unit_test/test_pyobject_base.cpp` 演示了完整模式:

```cpp
class BaseObj : public PyObjectPlus
{
    Py_Header( BaseObj, PyObjectPlus )
public:
    BaseObj( PyTypeObject * pType, PyObject * ref = NULL );
    ~BaseObj();

    int pyTraverse( visitproc visit, void * arg );
    int pyClear();

private:
    PyObject * ref_;  // 可指向另一个 PyObject(可能形成循环)
};

int BaseObj::pyTraverse( visitproc visit, void * arg )
{
    Py_VISIT( ref_ );
    return 0;
}

int BaseObj::pyClear()
{
    Py_CLEAR( ref_ );
    return 0;
}
```

- **`Py_VISIT(pObj)`**:展开为 `visit(pObj, arg)`,告诉 GC 此对象引用了 `pObj`,GC 应继续扫描 `pObj` 的子引用。
- **`Py_CLEAR(pObj)`**:展开为 `Py_XDECREF(pObj); pObj = NULL;`,断开引用,让循环引用被解除。

### 23.3 GC 测试

```cpp
TEST_F( PyScriptUnitTestHarness, CyclicReferences )
{
    BaseObj::s_instCount = 0;

    PyObject * obj1 = PyType_GenericAlloc( &BaseObj::s_type_, 0 );
    PyObject * obj2 = PyType_GenericAlloc( &BaseObj::s_type_, 0 );

    // 构造循环引用:obj1.ref_ = obj2, obj2.ref_ = obj1
    new ( obj1 ) BaseObj( &BaseObj::s_type_, obj2 );
    new ( obj2 ) BaseObj( &BaseObj::s_type_, obj1 );

    Py_XDECREF( obj1 );  // 释放外部引用
    Py_XDECREF( obj2 );

    // GC 应该回收两个对象
    while (PyGC_Collect() > 0);

    CHECK_EQUAL( 0, BaseObj::s_instCount );
}
```

如果没有 `tp_traverse` / `tp_clear`,这两个对象会泄漏(外部引用都已释放,但循环引用计数仍 ≥ 1)。`PyGC_Collect` 检测到循环后,调用 `tp_clear` 解除引用,析构函数运行,实例计数归零。

### 23.4 Entity 的循环引用

`Entity` 类(尤其 BaseApp 端)持有 `Mailbox` 引用,Mailbox 又可能持有 Entity 的回引:

```
EntityA ──► MailboxA(指向 EntityB)
EntityB ──► MailboxB(指向 EntityA)
```

如果 Mailbox 持有强引用,会形成循环。BigWorld 通过两种方式避免:
1. **Mailbox 不参与 GC**:`Mailbox` 不注册 `tp_traverse`,引用计数管理。
2. **Mailbox 弱引用 Entity**:`Mailbox::pEntity_` 是 `WeakPyPtr<Entity>`,不增引用计数。

这样循环被切断:Entity 强引用 Mailbox,Mailbox 弱引用 Entity。Entity 销毁时,Mailbox 的 `WeakPyPtr::good()` 返回 false,自动失效。

### 23.5 ScriptObject 的引用语义

`ScriptObject` 是 `SmartPointer<PyObject>`,析构时 DECREF。在 C++ 临时变量中持有 `ScriptObject` 不会泄漏:

```cpp
void someFunc()
{
    ScriptObject obj = ScriptObject::createFrom( 42 );
    // obj 引用计数 = 1
}  // 析构 DECREF,引用计数 = 0,对象释放
```

但如果两个 `ScriptObject` 互相持有对方引用(如 `ScriptDict` 互为 value),会形成循环。BigWorld 约定:
- **C++ 临时变量用 `ScriptObject`**(强引用)。
- **持久存储用 `WeakPyPtr`**(弱引用)。
- **缓存用 `WeakPyPtr`,定期清理失效项**。

---

## 二十四、GIL 与多线程

### 24.1 BigWorld 的线程模型

BigWorld 服务端是**单线程事件驱动**:

```
┌──────────────────────────────────────────────────────┐
│             CellApp / BaseApp 主线程                  │
│                                                      │
│   ┌─── event dispatcher loop ───┐                   │
│   │                              │                   │
│   │   1. Mercury 网络消息       │                   │
│   │   2. Entity tick            │                   │
│   │   3. Script::tick            │                   │
│   │   4. DBApp 回调              │                   │
│   │   5. Personality.onTick     │                   │
│   │   ...                        │                   │
│   └──────────────────────────────┘                   │
│                                                      │
│   所有 Python 代码都在主线程运行,GIL 不竞争           │
└──────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────┐
│             后台线程(独立)                          │
│                                                      │
│   - 网络接收线程(Mercury 内部)                       │
│   - 数据库 I/O 线程                                  │
│   - 资源加载线程                                     │
│                                                      │
│   这些线程不调用 Python,无需 GIL                     │
└──────────────────────────────────────────────────────┘
```

### 24.2 GIL 的必要性

虽然主线程独占 Python,但有些场景仍需 GIL:

1. **多进程内嵌 Python Server**:`ScriptApp::startPythonServer` 启动一个 Manhole 服务器(基于 Twisted),允许远程连接执行任意 Python 代码。Twisted 的 reactor 跑在独立线程,需要在调用 Python 时 acquire GIL。

2. **数据库回调**:某些异步 DB 接口在 I/O 完成时回调,如果在后台线程触发,需要 acquire GIL 才能调用 Python 回调。

3. **资源加载完成回调**:BigWorld 的异步资源加载(纹理、模型)在后台线程完成,完成回调可能调用 Python(如通知脚本"加载完成")。

### 24.3 AutoInterpreterSwapper

`AutoInterpreterSwapper` 是 RAII 风格的 GIL 管理器:

```cpp
class AutoInterpreterSwapper
{
public:
    AutoInterpreterSwapper( PyInterpreterState * pTargetInterpreter = NULL )
    {
        // 保存当前 thread state,切换到目标解释器
        pSavedThreadState_ = PyThreadState_Swap( pTargetInterpreter );
    }

    ~AutoInterpreterSwapper()
    {
        // 恢复原 thread state
        PyThreadState_Swap( pSavedThreadState_ );
    }

private:
    PyThreadState * pSavedThreadState_;
};
```

用于跨子解释器切换(见 §5.4)。

### 24.4 Script::acquireLock / releaseLock

```cpp
// script.cpp
void Script::acquireLock()
{
    PyGILState_STATE state = PyGILState_Ensure();
    // 保存到 thread-local
    s_lockOwner.set( state );
}

void Script::releaseLock()
{
    PyGILState_STATE state = s_lockOwner.get();
    PyGILState_Release( state );
}
```

`PyGILState_Ensure` / `Release` 是 Python 2.3+ 的 API,自动管理 GIL:如果当前线程已持有 GIL,不做任何事;否则获取 GIL,记录状态。`Release` 根据状态决定是否释放。

### 24.5 THREADLOCAL

BigWorld 用 `THREADLOCAL` 宏抽象跨平台的线程局部存储:

```cpp
#ifdef _WIN32
    #define THREADLOCAL __declspec(thread)
#else
    #define THREADLOCAL __thread
#endif
```

`__declspec(thread)` / `__thread` 是 TLS(Thread Local Storage)的编译器扩展,在编译期分配。Python 的 `PyGILState` API 内部也用 TLS,但 BigWorld 额外用 `THREADLOCAL` 保存自己的状态(如 `s_lockOwner`),便于在 C++ 层追踪 GIL 状态。

### 24.6 Python 子线程的常见模式

```cpp
void backgroundTask()
{
    Script::acquireLock();
    // 现在持有 GIL,可调用 Python
    ScriptObject result = ScriptObject::createFrom( 42 );
    callPythonCallback( result );
    Script::releaseLock();
}
```

注意:GIL 持有时间应短,避免阻塞主线程的 Python 调用。长时间 Python 操作应拆分为多个 tick。

---

## 二十五、性能分析

### 25.1 Python 调用开销

每次 C++ ↔ Python 边界穿越都有开销:

| 操作 | 典型开销(ns) | 备注 |
|------|-------------|------|
| `PyObject_CallObject` | 200-500 | 函数调用基础开销 |
| `Script::setData(int)` | 30 | `PyInt_FromLong` |
| `Script::setData(float)` | 50 | `PyFloat_FromDouble` |
| `Script::setData(string)` | 100 + 字符串长度 | 拷贝字符 |
| `Script::setData(Vector3)` | 300 | 创建 tuple + 3 float |
| `Script::getData(int)` | 30 | `PyInt_AsLong` |
| `Script::getData(string)` | 100 | 字符串拷贝 |
| `PyObject_GetAttrString` | 200 | 字符串 hash + 查表 |
| `PyTuple_New(n)` | 50 + n×30 | 分配 + 设置元素 |

数值为 Python 2.7 在 x86-64 的典型值,实际取决于 CPU 与缓存。

### 25.2 性能瓶颈分析

BigWorld 实体 tick 性能瓶颈:

1. **每帧调用所有实体的 onTick**:如果有 10000 个实体,每帧 10000 次 Python 调用,每次约 1μs,总开销 10ms。在 60fps 游戏中,占用 60% 帧时间。
2. **属性 get/set 跨边界**:Python 频繁访问 C++ 字段(如 `entity.position.x`)每次都跨边界。
3. **mailbox 调用**:跨进程方法调用要序列化参数、网络发送、反序列化、调用 Python。

### 25.3 优化策略

BigWorld 的优化:

1. **批量回调**:把多个实体的 onTick 合并到一次 Python 调用,传 list of entities:
   ```python
   def onTick( entities, dt ):
       for e in entities:
           # 处理
   ```
   减少 Python 调用次数。

2. **属性缓存**:C++ 端把热点属性(`position`、`direction`)在 Python 端缓存,只在变更时同步。

3. **Vector3 直接暴露**:`PyVector3` 让 C++ `Vector3` 直接映射 Python 对象,避免每次 tuple 创建/销毁。

4. **JIT 编译**:BigWorld 14.4.1 在客户端使用 `psyco`(已废弃)或自研 JIT,把热点 Python 函数编译为机器码。

5. **C++ 关键路径**:AOI 计算、Ghost 同步、网络序列化等性能关键代码用 C++,Python 仅做高层逻辑。

### 25.4 性能测量

BigWorld 提供 `gProfilingOn` 标志和 `PythonProfile` 类:

```cpp
class PythonProfile
{
public:
    PythonProfile( const char * name );
    ~PythonProfile();
};

#define PY_PROFILE(name) PythonProfile _profile(name)
```

在 `script.cpp` 中,`Script::call` 内部根据 `gProfilingOn` 决定是否记录耗时到 `PythonProfileManager`:

```cpp
template <class RETURN_VALUE>
RETURN_VALUE Script::call( PyObject * pFunction,
        const char * functionSignature, ... )
{
    PY_PROFILE( functionSignature );
    // ...
}
```

测量结果通过 `BigWorld.profile()` Python API 暴露:

```python
import BigWorld
stats = BigWorld.profile.getStats()
for name, time, count in stats:
    print( f"{name}: {count} calls, {time*1000:.1f} ms" )
```

### 25.5 性能对比:C++ vs Python

| 操作 | C++ (ns) | Python (ns) | 比率 |
|------|---------|------------|------|
| 整数加法 | 1 | 100 | 100× |
| 浮点乘法 | 1 | 120 | 120× |
| 函数调用 | 5 | 200 | 40× |
| 字符串拼接 | 30 | 500 | 16× |
| 字典查找 | 20 | 100 | 5× |
| 列表迭代 | 2 | 50 | 25× |

Python 适合 I/O 密集、事件驱动的逻辑(脚本编写灵活),C++ 适合 CPU 密集的批量计算。BigWorld 的分工正是基于这一差异。

---

## 二十六、边界情况深度分析

### 26.1 递归调用栈溢出

Python 默认递归深度限制 1000。BigWorld 在初始化时调整:

```cpp
// script.cpp L440
PySys_SetObject( "recursionlimit", PyInt_FromLong( 50000 ) );
```

但实际栈空间有限,过深递归仍可能 segfault。引擎在 Entity::callback 等入口检查 `PyErr_ExceptionMatches(PyExc_RecursionError)`,捕获后转 WARNING。

### 26.2 NULL PyObject 处理

`ScriptObject` 构造接受 NULL 不报错,但调用方法会失败:

```cpp
ScriptObject obj( NULL );
obj.callMethod( "foo" );  // PyObject_GetAttrString(NULL, "foo") → segfault
```

BigWorld 在 `ScriptObject::callMethod` 等入口加 `MF_ASSERT(this->get())`,把 segfault 转为 assertion failure,带可调试堆栈。

### 26.3 解释器未初始化

某些 C++ 全局对象的析构(如 `static ScriptModule s_pInstance_`)在 `Script::fini` 之后运行,这时 Python 已 `Py_Finalize`,操作 `PyObject*` 会 segfault。BigWorld 的解法:
1. `Script::fini` 显式清空所有静态 `ScriptObject`(`s_pInstance_ = ScriptModule()`)。
2. `~ScriptModule` 检查 `g_isInited`,不调用 `Py_DECREF`。

### 26.4 多线程下的 ScriptObject

`ScriptObject` 跨线程传递不安全。后台线程创建的 `ScriptObject` 传到主线程后,可能已被 GC。BigWorld 约定:
- 跨线程数据用 C++ 数据结构(`BW::vector<int>` 等),不传 `ScriptObject`。
- 后台线程结果回调到主线程的 `EventDispatcher::addOnce`,在主线程构造 `ScriptObject`。

### 26.5 Personality 加载失败

```cpp
bool ScriptApp::initPersonality()
{
    if (!Personality::import( ServerAppConfig::personality() )) {
        WARNING_MSG( "ScriptApp::initPersonality: "
                    "No personality script '%s.py'\n",
                ServerAppConfig::personality().c_str() );
        return false;
    }
    // ...
}
```

`Personality::import` 失败时返回空 `ScriptModule`,后续 `instance()` 也返回空。引擎检测到空实例,跳过 `callOnInit` 等调用,只警告不崩溃,允许"裸 C++"模式启动(用于测试)。

### 26.6 脚本异常未捕获

Python 异常未捕获时,Python 解释器调用 `sys.excepthook`。BigWorld 安装自定义 hook:

```cpp
// script.cpp L510-530
static void bigworld_excepthook( PyObject * type, PyObject * value,
        PyObject * traceback )
{
    ERROR_MSG( "Unhandled Python exception:\n" );
    Script::printError();
}

void Script::installExceptHook()
{
    PyObject * sysExcepthook = PySys_GetObject( "excepthook" );
    PyMethodDef * md = new PyMethodDef;
    md->ml_name = "bigworld_excepthook";
    md->ml_meth = (PyCFunction)bigworld_excepthook;
    md->ml_flags = METH_VARARGS;
    md->ml_doc = NULL;
    PyObject * pHook = PyCFunction_New( md, NULL );
    PySys_SetObject( "excepthook", pHook );
}
```

这样所有未捕获异常都进 `ERROR_MSG`,记录到 BigWorld 日志(而非 stderr)。

### 26.7 类型未注册的 PY_TYPEOBJECT

如果 `PY_TYPEOBJECT(MyClass)` 在某 .cpp 文件,但该 .cpp 未被链接,`s_type_` 不初始化,运行时 `MyClass::Check()` 永远返回 false。`FORCE_LINK` 宏解决此问题,但要求在头文件用 `FORCE_LINK_DECLARE` + 在某 .cpp 用 `FORCE_LINK_THIS`。

### 26.8 Python 字节码缓存(.pyc)

`scripts/cell/Avatar.py` 首次 import 后会生成 `Avatar.pyc`,后续启动跳过编译。但 `.pyc` 与 Python 版本绑定,跨版本不兼容(BigWorld 升级 Python 2.5 → 2.7 时 `.pyc` 失效,自动重新生成)。`.pyc` 文件权限检查:BigWorld 在工具链中用 `process_defs` 强制刷新所有 `.pyc`,避免部署时漏文件。

### 26.9 跨进程类型一致性

CellApp 与 BaseApp 同时持有 `Avatar::s_type_`,但两者的 `s_type_` 是不同二进制实例(不同进程)。如果两端 `tp_name` 不一致(如 CellApp 用 `BigWorld.Avatar`,BaseApp 漏注册),`mailbox.callMethod` 序列化时找不到对应类型。BigWorld 通过 `process_defs` 在生成代码时验证两端类型注册一致。

---

## 二十七、调试支持

### 27.1 Python traceback

`py_traceback.hpp` 提供 `PyTraceback` 类,格式化异常堆栈:

```cpp
class PyTraceback
{
public:
    static BW::string getTraceback( PyObject * pType = NULL,
        PyObject * pValue = NULL, PyObject * pTraceback = NULL );
    static void printTraceback();
    static BW::string formatException();
};
```

`Script::printError` 内部用 `PyTraceback::printTraceback` 输出:

```
Traceback (most recent call last):
  File "scripts/cell/Avatar.py", line 42, in onHit
    self.health -= amount
AttributeError: 'Avatar' object has no attribute 'health'
```

### 27.2 Python Server(Manhole)

`ScriptApp::startPythonServer` 启动一个 Twisted Manhole 服务器,允许远程登录到运行中的 CellApp/BaseApp,在 Python 解释器中检查状态:

```
$ telnet cellapp1 9876
Welcome to CellApp 1
Version: 14.4.1
>>> import BigWorld
>>> BigWorld.entities
{1: <Avatar object>, 2: <NPC object>, ...}
>>> BigWorld.entities[1].position
(123.4, 56.7, 89.0)
```

这对线上诊断极为有用:不需重启进程,直接连上去查状态。Manhole 服务器跑在独立线程,通过 `Script::acquireLock` 获取 GIL 后调用 Python。

### 27.3 调试钩子:onPreCall / onPostCall

`Script::setCallHook` 允许注册钩子在每次 C++ → Python 调用前后回调:

```cpp
typedef void (*CallHook)( const char * functionSignature,
    PyObject * pFunction, PyObject * pArgs );

void Script::setPreCallHook( CallHook hook );
void Script::setPostCallHook( CallHook hook );
```

调试时注册钩子记录所有调用,用于追踪性能瓶颈或定位死循环。

### 27.4 实体调试命令

CellApp / BaseApp 通过 `cmd_line.py` 暴露调试命令:

```python
# scripts/server_common/cmd_line.py
import BigWorld

def list_entities( filter = None ):
    for id, e in BigWorld.entities.items():
        if filter and filter not in type(e).__name__:
            continue
        print( f"{id}: {type(e).__name__} pos={e.position}" )

def find_entity( entity_id ):
    return BigWorld.entities.get( entity_id )

def call_on_all( method_name, *args ):
    for e in BigWorld.entities.values():
        if hasattr( e, method_name ):
            getattr( e, method_name )( *args )
```

这些函数被 `cmd` 模块暴露,可在 Manhole 终端直接调用。

### 27.5 Watch 窗口

`MF_WATCH` 宏允许把 C++ 变量暴露到调试系统,可通过 `BigWorld.watch.get()` Python API 读取:

```cpp
int g_activeEntities = 0;
MF_WATCH( "activeEntities/count", g_activeEntities );
```

```python
>>> BigWorld.watch.get( "activeEntities/count" )
42
```

这与 Python 集成无关,但让 Python 调试代码能访问 C++ 内部状态。

### 27.6 单元测试

`pyscript/unit_test/` 下有测试套件,基于 `test_harness.hpp` 框架:

```cpp
TEST_F( PyScriptUnitTestHarness, BaseCreation )
{
    BaseObj::s_instCount = 0;
    PyObject * obj = PyType_GenericAlloc( &BaseObj::s_type_, 0 );
    CHECK( obj );
    CHECK( BaseObj::Check( obj ) );

    if (obj) {
        new ( obj ) BaseObj( &BaseObj::s_type_ );
        while (PyGC_Collect() > 0);
    }

    Py_XDECREF( obj );
    while (PyGC_Collect() > 0);
    CHECK_EQUAL( 0, BaseObj::s_instCount );
}
```

`PyScriptUnitTestHarness` 在 setUp 时初始化 Python 解释器,tearDown 时 finalize,确保每个测试用例有干净的 Python 环境。

---

## 二十八、与其他引擎对比

### 28.1 与 Unreal Engine 对比

Unreal 2(2002,BigWorld 同期)使用 UnrealScript(自研脚本语言),Unreal 3+ 引入 Kismet(可视化脚本)和蓝(Blueprint)。Python 与之对比:

| 维度 | BigWorld(Python) | Unreal(Blueprint) |
|------|-------------------|---------------------|
| 类型 | 通用动态语言 | 可视化节点图 |
| 表达能力 | 完整(任何逻辑都能写) | 限于预定义节点 |
| 性能 | 慢(解释执行) | C++ 编译,接近原生 |
| 调试 | 文本 traceback,Manhole | 节点高亮,断点 |
| 团队协作 | 文件 diff 友好 | 二进制 / 节点编辑 |
| 学习曲线 | Python 程序员直接上手 | 需学 Blueprint 概念 |

Unreal 4 起也支持 C++ 直接写逻辑,Blueprint 主要给非程序员(策划、美术)用。BigWorld 选择 Python,让"程序员写所有逻辑"成为可能,牺牲了可视化脚本的友好性,换取了表达能力和可维护性。

### 28.2 与 CRYENGINE 对比

Crytek 1-2 代用 Lua 脚本,CryEngine 3+ 引入 Schematyc(ECS + 反射)。Lua 与 Python 对比:

| 维度 | Python(BigWorld) | Lua(Crytek) |
|------|-------------------|---------------|
| 启动时间 | 慢(500ms+) | 快(<50ms) |
| 内存占用 | 高(20MB+) | 低(<5MB) |
| 性能 | 中等 | 快(JIT) |
| 标准库 | 完整 | 极简(需搭配 lfs 等) |
| 生态 | 巨大(PyPI) | 中等(Luarocks) |
| 多线程 GIL | 有(限制) | 无 |

Lua 在嵌入式游戏领域更受欢迎,因为更轻量。BigWorld 选 Python 是为了标准库完整、生态丰富(MMO 服务端常用 web/DB 库)。LuaJIT 出现后,性能也超越 CPython,但 2000 年代早期 Lua 性能不及 Python。

### 28.3 与 Unity 对比

Unity 用 C# (Mono / .NET)作为脚本语言:

| 维度 | Python(BigWorld) | C#(Unity) |
|------|-------------------|------------|
| 类型系统 | 动态 | 静态 |
| 性能 | 慢 | 快(JIT) |
| 编译 | 无(运行时解析) | 编译为 DLL |
| IDE 支持 | 弱(PyDev) | 强(IntelliSense, Refactoring) |
| 反射 | 运行时 | 编译时 + 运行时 |

C# 的静态类型让大型项目更易维护,IDE 重构工具成熟。Python 的动态类型在 MMO 大型代码库中容易出 bug(如拼写错误),BigWorld 通过 `process_defs` 生成的代码 + 类型检查部分弥补。

### 28.4 与 ECS 框架对比

现代 ECS(Bevy、entt、Unity DOTS)把"行为"从"对象方法"改为"系统批量处理组件数据"。BigWorld 的 Python 实体是 OOP 风格:

```python
# BigWorld 风格
class Avatar( BigWorld.Entity ):
    def onTick( self, dt ):
        self.health -= self.poison * dt
        if self.health <= 0:
            self.die()
```

```rust
// ECS 风格
fn poison_system( mut query: Query<&mut Health, With<Poison>>, time: Res<Time> ) {
    for mut health in query.iter_mut() {
        health.0 -= 1.0 * time.delta_seconds();
    }
}
```

ECS 在批量处理上快 100-1000×(数据局部性、SIMD),但 Python 风格更直观、易调试。BigWorld 选择 OOP 是因为 MMO 的瓶颈在"网络 + 持久化",而非"单机 CPU 吞吐"。

### 28.5 与传统服务器框架对比

同期 MMO 服务器(Lineage 2、WoW)用 C++ 写所有逻辑,脚本仅做配置:

| 维度 | BigWorld(Python) | 传统(C++ Only) |
|------|-------------------|-----------------|
| 开发速度 | 快(脚本即改即跑) | 慢(需编译重启) |
| 性能 | 慢 | 快 |
| 热重载 | 支持 | 不支持 |
| 团队门槛 | 程序员+脚本师分工 | 都是 C++ 程序员 |
| 调试 | Python traceback | GDB |

BigWorld 让"逻辑程序员写 Python,引擎程序员写 C++"成为可能,大幅降低 MMO 开发门槛。代价是性能损失约 30-50%,通过热点 C++ 化缓解。

---

## 二十九、设计哲学总结

### 29.1 Python 集成的 6 大原则

```
┌─────────────────────────────────────────────────────────────┐
│        BigWorld Python 集成的 6 大设计原则                  │
├─────────────────────────────────────────────────────────────┤
│  1. 平级一等公民:Python 与 C++ 同级,非"配置脚本"          │
│  2. 双向透明:C++ ↔ Python 双向调用,无边界摩擦             │
│  3. 数据驱动:实体定义、字段同步由 .def 元数据驱动           │
│  4. 进程人格:Personality 让同一二进制表现不同进程行为       │
│  5. 静态注册:InitTimeJob 让类型/函数自动注册,无需集中维护  │
│  6. 容错降级:allowNullMethod、FailedUnpickle 等机制容错    │
└─────────────────────────────────────────────────────────────┘
```

### 29.2 与现代引擎的呼应

BigWorld 在 2000 年代早期选 Python,与现代引擎(如 Godot 4 用 GDScript、Bevy 用 Rust 反射)的思路一致:
- **脚本语言降低迭代成本**:策划/美术不重新编译就能调整逻辑。
- **元数据驱动**:EntityDef 类似 Unity 的 SerializeReference、Bevy 的 Reflect。
- **静态注册**:`FORCE_LINK` 类似 Rust 的 `inventory` crate、C# 的 `[Register]` attribute。

但 BigWorld 受限于时代:
- **Python 2**:GIL、字符串编码、性能都不及现代 Python / LuaJIT。
- **无类型检查**:`process_defs` 生成的代码不做静态检查,IDE 弱。
- **无 ECS**:OOP 实体不适合现代数据驱动设计。

### 29.3 历史意义

BigWorld 的 Python 集成在 2000 年代 MMO 领域是开创性的:
- **首个用 Python 写全部游戏逻辑的 MMO 引擎**:同期竞品(Lineage、WoW)用 C++ 写逻辑。
- **EntityDef + Python 的组合**:数据契约 + 动态逻辑,是 ECS 之前的"组件化"思路。
- **Personality + InitTimeJob**:模块化的进程人格配置,让同一二进制服务多种 MMO 类型。
- **Manhole 调试**:线上诊断能力远超同期引擎。

这些设计影响了后续引擎:Kotlin + ECS 的开源 MMO 框架、Unity 的 DOTS + C# Job System、Godot 4 的 GDExtension 都有 BigWorld 思想的影子。

### 29.4 局限性

| 局限 | 描述 | 现代解法 |
|------|------|---------|
| Python 2 GIL | 单线程瓶颈 | Python 3 + asyncio / 多进程 |
| 无静态类型 | IDE 弱,大型项目易出 bug | mypy / Python 3 type hints |
| 无热重载类型对象 | PyTypeObject 不可更新 | 卸载子解释器 + reload |
| OOP 实体 | 数据布局不紧凑 | ECS + SoA |
| cPickle 二进制 | 跨版本不兼容 | Protobuf / FlatBuffers |

### 29.5 总结

BigWorld 14.4.1 的 Python 集成是"在正确时间做的正确选择":2000 年代早期,Python 2 是少数成熟、生态丰富、易学的脚本语言,BigWorld 通过 `PyObjectPlus` 体系、`ScriptObject` 模型、`Script::setData/getData` 类型转换、`Personality` 系统、`InitTimeJob` 静态注册等机制,把 Python 嵌入到引擎的每一个毛细血管中,让 C++ 与 Python 真正"平级"。这种设计的代价是性能损失和 GIL 限制,但换来了 MMO 开发的快速迭代、热重载、远程调试能力,在 MMO 黄金时代支撑了《黑暗与光明》《激战》等项目。其架构思想在 20 年后仍值得借鉴。

---

## 附录 A:关键文件路径速查

### A.1 pyscript 库

| 文件 | 行数 | 主要内容 |
|------|------|---------|
| `programming/bigworld/lib/pyscript/script.hpp` | 1528 | Script 命名空间接口、所有宏定义 |
| `programming/bigworld/lib/pyscript/script.cpp` | 2300 | Script::init/fini、setData/getData 实现 |
| `programming/bigworld/lib/pyscript/script.ipp` | 100 | Script::call 内联实现 |
| `programming/bigworld/lib/pyscript/pyobject_plus.hpp` | 1193 | PyObjectPlus 基类、Py_Header 宏家族 |
| `programming/bigworld/lib/pyscript/pyobject_plus.cpp` | 197 | pyGetAttribute/pySetAttribute/pyRepr |
| `programming/bigworld/lib/pyscript/pyobject_base.hpp` | 89 | PY_BASETYPEOBJECT 宏 |
| `programming/bigworld/lib/pyscript/pyobject_pointer.hpp` | 48 | PyObjectPtr = SmartPointer<PyObject> |
| `programming/bigworld/lib/pyscript/pickler.cpp` | 199 | cPickle 包装、FailedUnpickle |
| `programming/bigworld/lib/pyscript/personality.cpp` | 200 | Personality 命名空间实现 |
| `programming/bigworld/lib/pyscript/script_events.hpp` | 150 | ScriptEvents 事件广播 |
| `programming/bigworld/lib/pyscript/py_factory_method_link.cpp` | 98 | PyFactoryMethodLink 工厂注册 |
| `programming/bigworld/lib/pyscript/script_math.hpp` | 800 | PyMatrix、PyVector、MatrixProvider |
| `programming/bigworld/lib/pyscript/py_import_paths.hpp` | 60 | PyImportPaths |
| `programming/bigworld/lib/pyscript/py_to_stl.hpp` | 200 | PySequenceSTL/PyMappingSTL |

### A.2 script 库

| 文件 | 行数 | 主要内容 |
|------|------|---------|
| `programming/bigworld/lib/script/py_script_object.hpp` | 1800 | ScriptObject/ScriptModule/ScriptArgs 等 |
| `programming/bigworld/lib/script/py_script_object.ipp` | 174 | ScriptObject::callMethod/callFunction |
| `programming/bigworld/lib/script/py_script_module.ipp` | 100 | ScriptModule::import/getOrCreate/reload |
| `programming/bigworld/lib/script/pickler.hpp` | 28 | Pickler 接口 |
| `programming/bigworld/lib/script/init_time_job.hpp` | 80 | InitTimeJob/FiniTimeJob |

### A.3 服务端示例

| 文件 | 用途 |
|------|------|
| `programming/bigworld/lib/server/script_app.cpp` | Personality::import 调用 |
| `programming/bigworld/server/cellapp/entity.hpp` | Entity 类用 Py_Header |
| `programming/bigworld/server/cellapp/entity.cpp` | callback 调用 |

### A.4 单元测试

| 文件 | 测试内容 |
|------|---------|
| `programming/bigworld/lib/pyscript/unit_test/test_pyobject_base.cpp` | PyObjectPlus GC、循环引用 |

---

## 附录 B:Py_Header 展开速查表

### B.1 Py_Header 展开

```cpp
// 输入:
class MyClass : public PyObjectPlus {
    Py_Header( MyClass, PyObjectPlus )
};

// 展开为:
class MyClass : public PyObjectPlus
{
public:
    static PyTypeObject s_type_;
    static const char * s_typeName_;
    static bool Check( PyObject * pObject )
    {
        return PyObject_TypeCheck( pObject, &s_type_ );
    }
    virtual PyTypeObject * pType() const { return &MyClass::s_type_; }
    virtual const char * pTypeName() const { return s_typeName_; }
protected:
    MyClass( PyTypeObject * pType = &MyClass::s_type_, bool initial = true )
        : PyObjectPlus( pType, initial ) {}
};
```

### B.2 PY_TYPEOBJECT 展开

```cpp
// 输入:
PY_TYPEOBJECT( MyClass )

// 展开为:
PyTypeObject MyClass::s_type_ =
{
    PyObject_HEAD_INIT( NULL )
    0,                                  // ob_size
    "BigWorld.MyClass",                  // tp_name
    sizeof( MyClass ),                  // tp_basicsize
    0,                                  // tp_itemsize
    /* ... 大量 NULL 字段 ... */
    Py_TPFLAGS_DEFAULT | Py_TPFLAGS_BASETYPE,  // tp_flags
    "MyClass",                           // tp_doc
    /* ... */
};
```

### B.3 PY_BASETYPEOBJECT 展开

```cpp
// 输入:
PY_BASETYPEOBJECT( MyClass )

// 展开为(简化):
static int s_register_MyClass_type = ([]() {
    MyClass::s_type_.ob_type = &PyType_Type;
    MyClass::s_type_.tp_base = PyObjectPlus::pType();
    PyType_Ready( &MyClass::s_type_ );
    return 0;
})();
```

### B.4 PY_BEGIN_METHODS / PY_END_METHODS

```cpp
// 输入:
PY_BEGIN_METHODS( MyClass )
    PY_METHOD( foo )
    PY_METHOD( bar, "do bar" )
PY_END_METHODS()

// 展开为:
static PyMethodDef MyClass_methods[] = {
    { "foo", &MyClass::foo_wrapper, METH_VARARGS, NULL },
    { "bar", &MyClass::bar_wrapper, METH_VARARGS, "do bar" },
    { NULL, NULL, 0, NULL }  // 哨兵
};
MyClass::s_type_.tp_methods = MyClass_methods;
```

### B.5 PY_BEGIN_ATTRIBUTES / PY_END_ATTRIBUTES

```cpp
// 输入:
PY_BEGIN_ATTRIBUTES( MyClass )
    PY_ATTRIBUTE( value )
    PY_ATTRIBUTE( name, "display name" )
PY_END_ATTRIBUTES()

// 展开为:
static PyGetSetDef MyClass_attributes[] = {
    { "value", &MyClass::pyGet_value, &MyClass::pySet_value, NULL, NULL },
    { "name", &MyClass::pyGet_name, &MyClass::pySet_name, "display name", NULL },
    { NULL, NULL, NULL, NULL, NULL }
};
MyClass::s_type_.tp_getset = MyClass_attributes;
```

---

## 附录 C:Script::setData/getData 类型表

### C.1 基本类型

| C++ 类型 | setData 实现 | getData 实现 | Python 类型 |
|---------|-------------|-------------|------------|
| `bool` | `PyBool_FromLong` | `PyBool_Check` + 取值 | `bool` |
| `int8_t` | `PyInt_FromLong` | `PyInt_AsLong` | `int` |
| `uint8_t` | `PyInt_FromLong` | `PyInt_AsLong` | `int` |
| `int16_t` | `PyInt_FromLong` | `PyInt_AsLong` | `int` |
| `uint16_t` | `PyInt_FromLong` | `PyInt_AsLong` | `int` |
| `int32_t` | `PyInt_FromLong` | `PyInt_AsLong` | `int` |
| `uint32_t` | `PyLong_FromUnsignedLong` | `PyLong_AsUnsignedLong` | `long` |
| `int64_t` | `PyLong_FromLongLong` | `PyLong_AsLongLong` | `long` |
| `float` | `PyFloat_FromDouble` | `PyFloat_AsDouble` | `float` |
| `double` | `PyFloat_FromDouble` | `PyFloat_AsDouble` | `float` |
| `BW::string` | `PyString_FromString` | `PyString_AsString` | `str` |
| `BW::wstring` | `PyUnicode_FromWideChar` | `PyUnicode_AsWideChar` | `unicode` |
| `char *` | `PyString_FromString` | `PyString_AsString` | `str` |

### C.2 容器类型

| C++ 类型 | setData | getData |
|---------|---------|---------|
| `BW::vector<T>` | 遍历 list/tuple,递归 setData | 创建 list,逐项 getData |
| `BW::list<T>` | 遍历 list,递归 setData | 创建 list,逐项 getData |
| `BW::map<K,V>` | 遍历 dict,递归 | 创建 dict,逐项 |
| `BW::set<T>` | 遍历 set/frozenset | 创建 set |

### C.3 数学类型

| C++ 类型 | Python 表示 |
|---------|------------|
| `Vector2` | tuple `(x, y)` 或 `PyVector2` 对象 |
| `Vector3` | tuple `(x, y, z)` 或 `PyVector3` 对象 |
| `Vector4` | tuple `(x, y, z, w)` 或 `PyVector4` 对象 |
| `Matrix` | `PyMatrix` 对象(4×4) |
| `Quaternion` | tuple `(x, y, z, w)` |
| `Angle` | float(弧度) |

### C.4 引擎类型

| C++ 类型 | Python 类型 |
|---------|------------|
| `Entity *` | `BigWorld.Entity` 子类实例 |
| `EntityID` | `int` |
| `SpaceID` | `int` |
| `Mailbox *` | `BigWorld.Mailbox` 实例 |
| `ScriptObject` | 任意 PyObject |
| `ScriptModule` | 模块对象 |
| `DataType *` | `DataType` 实例 |

---

## 附录 D:错误处理器策略表

### D.1 错误处理器列表

| 错误处理器 | 行为 | 适用场景 |
|-----------|------|---------|
| `ScriptErrorPrint(msg)` | 打印 traceback + msg,清异常 | 用户可见入口 |
| `ScriptErrorPrint()` | 打印 traceback,清异常 | 内部调用 |
| `ScriptErrorClear()` | 静默清异常 | 容错查询 |
| `ScriptErrorRetain()` | 保留异常状态 | 链式调用 |
| `ScriptErrorThrow(msg)` | 抛 `std::runtime_error` | C++ 必须处理 |
| `ScriptErrorCheck()` | 断言失败,abort | 不可能错的位置 |

### D.2 用法示例

```cpp
// 1. 必须成功的调用
ScriptObject result = obj.callMethod( "compute",
    ScriptErrorPrint( "compute failed" ) );

// 2. 可选属性
ScriptObject opt = obj.getAttribute( "optional",
    ScriptErrorClear() );
if (opt) { /* 存在 */ }

// 3. 链式判断
ScriptObject method = obj.getAttribute( "onInit",
    ScriptErrorRetain() );
if (!method) {
    // 没有定义 onInit,清异常继续
    Script::clearError();
} else {
    method.callFunction( ScriptErrorPrint( "onInit raised" ) );
}

// 4. 严格入口
ScriptObject result = obj.callMethod( "critical",
    ScriptErrorThrow( "critical failed" ) );  // 抛 C++ 异常

// 5. 不可能错
MF_ASSERT( obj.callMethod( "init",
    ScriptErrorCheck() ) == true );
```

### D.3 自定义错误处理器

实现 `checkPtrError`、`checkMinusOne`、`handleError` 三个方法即可:

```cpp
class MyErrorHandler
{
public:
    void checkPtrError( PyObject * pResult )
    {
        if (!pResult) {
            ERROR_MSG( "Python call failed: %s",
                PyTraceback::formatException().c_str() );
            PyErr_Clear();
        }
    }

    void checkMinusOne( int result )
    {
        if (result == -1) {
            ERROR_MSG( "Python setData failed" );
            PyErr_Clear();
        }
    }

    void handleError()
    {
        ERROR_MSG( "Python error" );
        PyErr_Clear();
    }
};
```

---

## 附录 E:术语表

| 术语 | 含义 |
|------|------|
| **PyObjectPlus** | BigWorld 的 C++ → Python 类型映射基类 |
| **Py_Header** | 在 C++ 类内声明 Python 类型所需成员的宏 |
| **Script::init / fini** | Python 解释器初始化与终结的命名空间函数 |
| **ScriptObject** | PyObject* 的 C++ 智能包装,引用计数自动管理 |
| **ScriptModule** | Python 模块的 C++ 包装 |
| **ScriptArgs** | Python 调用参数(tuple)的 C++ 包装 |
| **Personality** | 进程人格脚本,定义 onInit/onFini 等回调 |
| **InitTimeJob** | 静态注册的初始化任务,在 Script::init 时统一执行 |
| **FiniTimeJob** | 静态注册的清理任务,在 Script::fini 时按 rung 逆序执行 |
| **Pickler** | cPickle 包装,提供 ScriptObject ↔ string 序列化 |
| **FailedUnpickle** | 反序列化失败的占位对象,保留原始 pickle 数据 |
| **PyObjectPtr** | SmartPointer<PyObject>,等同 ScriptObject |
| **WeakPyPtr<T>** | Python 对象的弱引用模板,不增引用计数 |
| **PY_TYPEOBJECT** | 声明 PyTypeObject 静态实例的宏 |
| **PY_BASETYPEOBJECT** | 注册基类型的宏(使类型可被继承) |
| **PY_FACTORY** | 把类型作为工厂方法注册到 Python 模块 |
| **PY_AUTO_METHOD** | 自动解析参数的 C++ 方法导出宏 |
| **PY_AUTO_ATTRIBUTE** | 自动生成 getter/setter 的属性导出宏 |
| **PY_SCRIPT_CONVERTERS** | 为 ScriptObjectPtr<T> 生成 setData/getData 重载 |
| **PY_ENUM_CONVERTERS** | 为枚举类型生成 setData/getData 重载 |
| **GIL** | Python 全局解释器锁 |
| **AutoInterpreterSwapper** | RAII 切换 Python 子解释器 |
| **THREADLOCAL** | 跨平台线程局部存储宏 |
| **Manhole** | Twisted 提供的远程 Python 交互式终端 |
| **EntityDescription** | 实体的元数据描述,由 .def 文件解析而来 |
| **Mailbox** | 跨进程实体引用,可调用远程方法 |
| **FORCE_LINK** | 防止链接器丢弃静态注册对象的宏 |

---

## 附录 F:相关专题

- **专题 09:EntityDef 数据驱动架构深度剖析** — `.def` 元数据如何与 Python 实体类协作
- **专题 05:Mailbox 通信机制深度剖析** — Mailbox 如何在 Python 层调用跨进程方法
- **专题 06:AOI 与 Witness 系统深度剖析** — Python 端如何接收 AOI 通知
- **专题 07:Mercury 网络协议深度剖析** — Python 调用如何最终走 Mercury 传输
- **专题 12:Reviver 与 bwmachined 双重守护机制** — 进程崩溃后 Personality 状态如何恢复
- **专题 13:资源管理器 BWResource** — Python `import` 如何通过 BWResource 查找脚本
- **专题 02:负载均衡算法深度剖析** — Python 决策如何影响实体分布

---

> **文档版本**:BigWorld Engine 14.4.1
> **专题编号**:10
> **行数**:5125 行
> **覆盖范围**:pyscript 库、PyObjectPlus 体系、ScriptObject 模型、类型转换、Personality、Pickler、PyObjectPtr、Python 模块组织、实体类、方法调用、循环引用、GIL、性能、边界情况、调试、与其他引擎对比
> **完成日期**:2026-07-05
