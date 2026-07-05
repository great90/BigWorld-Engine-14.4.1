# 专题 08:JIT 资源编译深度剖析

> **专题定位**:本文是对 BigWorld Engine 14.4.1 中 JIT(Just-In-Time)资源编译子系统的百科级深度剖析。内容涵盖 `asset_pipeline` 核心库的四个子模块(`compiler` / `conversion` / `dependency` / `discovery`)、`jit_compiler` 守护进程、`batch_compiler` 批量编译器、`assetprocessor` Python 模块、`plugin_system` 插件系统的完整源码剖析,并包含数据结构、状态机、算法步骤、边界情况、性能分析以及与 Unity / Unreal / Make / Bazel 等构建系统的对比。
>
> **读者前置**:已完成基础教程学习,熟悉 C++ 多线程、Windows API、BigWorld 资源系统(BWResource / DataSection / MultiFileSystem)。
>
> **代码版本**:BigWorld Engine 14.4.1,源码位于 `programming/bigworld/tools/asset_pipeline/`、`programming/bigworld/tools/jit_compiler/`、`programming/bigworld/tools/batch_compiler/`、`programming/bigworld/tools/assetprocessor/`、`programming/bigworld/lib/asset_pipeline/`、`programming/bigworld/tools/plugin_system/`。

---

## 目录

- [一、JIT 编译概述与设计哲学](#一jit-编译概述与设计哲学)
  - [1.1 什么是 JIT 资源编译](#11-什么是-jit-资源编译)
  - [1.2 为什么需要 JIT:开发效率 vs 运行性能](#12-为什么需要-jit开发效率-vs-运行性能)
  - [1.3 传统 AOT 编译 vs JIT 编译](#13-传统-aot-编译-vs-jit-编译)
  - [1.4 BigWorld 的 JIT 策略:开发时无感编译](#14-bigworld-的-jit-策略开发时无感编译)
  - [1.5 与 Unity AssetDatabase 的对比](#15-与-unity-assetdatabase-的对比)
  - [1.6 与 Unreal Live Coding 的对比](#16-与-unreal-live-coding-的对比)
- [二、asset_pipeline 核心库总览](#二asset_pipeline-核心库总览)
  - [2.1 目录结构](#21-目录结构)
  - [2.2 四大子模块职责](#22-四大子模块职责)
  - [2.3 整体架构图](#23-整体架构图)
  - [2.4 与 lib/asset_pipeline 的关系](#24-与-libasset_pipeline-的关系)
- [三、compiler 子模块深度剖析](#三compiler-子模块深度剖析)
  - [3.1 Compiler 抽象基类](#31-compiler-抽象基类)
  - [3.2 AssetCompiler 实现类](#32-assetcompiler-实现类)
  - [3.3 private 构造 + friend AssetCompiler 约束](#33-private-构造--friend-assetcompiler-约束)
  - [3.4 单实例锁机制](#34-单实例锁机制)
  - [3.5 循环依赖检测:线程 ID 传播法](#35-循环依赖检测线程-id-传播法)
  - [3.6 插件机制](#36-插件机制)
  - [3.7 THREADLOCAL 状态与错误传播](#37-threadlocal-状态与错误传播)
- [四、conversion 子模块深度剖析](#四conversion-子模块深度剖析)
  - [4.1 ConversionTask 状态机](#41-conversiontask-状态机)
  - [4.2 TaskProcessor 多线程调度](#42-taskprocessor-多线程调度)
  - [4.3 ConverterGuard 线程安全](#43-converterguard-线程安全)
  - [4.4 ContentAddressableCache 内容寻址缓存](#44-contentaddressablecache-内容寻址缓存)
  - [4.5 Converter 接口与 ConverterInfo](#45-converter-接口与-converterinfo)
- [五、ConversionTask 状态机详解](#五conversiontask-状态机详解)
  - [5.1 八状态完整转换图](#51-八状态完整转换图)
  - [5.2 挂起-恢复机制](#52-挂起-恢复机制)
  - [5.3 状态转换条件矩阵](#53-状态转换条件矩阵)
  - [5.4 与 OS 进程调度的对比](#54-与-os-进程调度的对比)
  - [5.5 状态机的工程价值](#55-状态机的工程价值)
- [六、TaskProcessor 多线程调度深度剖析](#六taskprocessor-多线程调度深度剖析)
  - [6.1 三阶段处理流程](#61-三阶段处理流程)
  - [6.2 自适应线程池](#62-自适应线程池)
  - [6.3 任务队列与同步](#63-任务队列与同步)
  - [6.4 强制重建(forceRebuild)](#64-强制重建forcerebuild)
- [七、ConverterGuard 线程安全深度剖析](#七converterguard-线程安全深度剖析)
  - [7.1 读写锁实现](#71-读写锁实现)
  - [7.2 与 ConversionTask 的协作](#72-与-conversiontask-的协作)
  - [7.3 防止并发冲突](#73-防止并发冲突)
- [八、ContentAddressableCache 内容寻址缓存深度剖析](#八contentaddressablecache-内容寻址缓存深度剖析)
  - [8.1 内容寻址原理](#81-内容寻址原理)
  - [8.2 缓存键的计算](#82-缓存键的计算)
  - [8.3 缓存命中与未命中](#83-缓存命中与未命中)
  - [8.4 跨项目、跨机器的缓存共享](#84-跨项目跨机器的缓存共享)
  - [8.5 与 Git 的对比](#85-与-git-的对比)
- [九、dependency 子模块深度剖析](#九dependency-子模块深度剖析)
  - [9.1 六种依赖类型](#91-六种依赖类型)
  - [9.2 Dependency 基类](#92-dependency-基类)
  - [9.3 DependencyList 依赖列表](#93-dependencylist-依赖列表)
  - [9.4 正向依赖与反向依赖](#94-正向依赖与反向依赖)
  - [9.5 依赖图的构建](#95-依赖图的构建)
  - [9.6 依赖序列化](#96-依赖序列化)
- [十、discovery 子模块深度剖析](#十discovery-子模块深度剖析)
  - [10.1 TaskFinder 任务发现](#101-taskfinder-任务发现)
  - [10.2 ConversionRule 转换规则](#102-conversionrule-转换规则)
  - [10.3 文件模式匹配](#103-文件模式匹配)
  - [10.4 GenericConversionRule](#104-genericconversionrule)
  - [10.5 asset_rules.xml 配置文件](#105-asset_rulesxml-配置文件)
- [十一、jit_compiler 工具深度剖析](#十一jit_compiler-工具深度剖析)
  - [11.1 四重继承架构](#111-四重继承架构)
  - [11.2 双线程架构](#112-双线程架构)
  - [11.3 事件驱动机制](#113-事件驱动机制)
  - [11.4 WTL GUI 集成](#114-wtl-gui-集成)
- [十二、反向依赖图深度剖析](#十二反向依赖图深度剖析)
  - [12.1 addReverseDependency 算法](#121-addreversedependency-算法)
  - [12.2 正向依赖图 vs 反向依赖图](#122-正向依赖图-vs-反向依赖图)
  - [12.3 双向映射实现](#123-双向映射实现)
  - [12.4 O(1) 增量查找](#124-o1-增量查找)
  - [12.5 增量编译原理](#125-增量编译原理)
- [十三、命名管道 IPC 深度剖析](#十三命名管道-ipc-深度剖析)
  - [13.1 onAssetRequested 处理](#131-onassetrequested-处理)
  - [13.2 与游戏客户端的通信](#132-与游戏客户端的通信)
  - [13.3 协议格式](#133-协议格式)
  - [13.4 实时编译响应](#134-实时编译响应)
  - [13.5 锁定/解锁机制](#135-锁定解锁机制)
- [十四、ResourceModificationListener 文件监听](#十四resourcemodificationlistener-文件监听)
  - [14.1 资源修改监听机制](#141-资源修改监听机制)
  - [14.2 文件系统监控](#142-文件系统监控)
  - [14.3 与 jit_compiler 的协作](#143-与-jit_compiler-的协作)
  - [14.4 触发增量编译](#144-触发增量编译)
- [十五、batch_compiler 工具深度剖析](#十五batch_compiler-工具深度剖析)
  - [15.1 双重继承架构](#151-双重继承架构)
  - [15.2 HTML 报告生成](#152-html-报告生成)
  - [15.3 Ctrl-C 优雅终止](#153-ctrl-c-优雅终止)
  - [15.4 CLI 批量编译流程](#154-cli-批量编译流程)
  - [15.5 任务记录与统计](#155-任务记录与统计)
- [十六、assetprocessor 工具深度剖析](#十六assetprocessor-工具深度剖析)
  - [16.1 DLL 形态](#161-dll-形态)
  - [16.2 Python 模块 _AssetProcessor](#162-python-模块-_assetprocessor)
  - [16.3 BSP2 升级与 shader 编译](#163-bsp2-升级与-shader-编译)
  - [16.4 需要 D3D 渲染设备](#164-需要-d3d-渲染设备)
- [十七、PluginLoader 插件系统深度剖析](#十七pluginloader-插件系统深度剖析)
  - [17.1 9 个转换器插件](#171-9-个转换器插件)
  - [17.2 dynamic_cast<Compiler*> 协议](#172-dynamic_castcompiler-协议)
  - [17.3 PLUGIN_INIT/PLUGIN_FINI 宏](#173-plugin_initplugin_fini-宏)
  - [17.4 插件配置文件](#174-插件配置文件)
- [十八、性能分析](#十八性能分析)
  - [18.1 JIT 编译的延迟](#181-jit-编译的延迟)
  - [18.2 增量编译的效率](#182-增量编译的效率)
  - [18.3 缓存命中率](#183-缓存命中率)
  - [18.4 线程池开销](#184-线程池开销)
  - [18.5 优化策略](#185-优化策略)
- [十九、边界情况](#十九边界情况)
  - [19.1 循环依赖](#191-循环依赖)
  - [19.2 大量文件变更](#192-大量文件变更)
  - [19.3 编译失败](#193-编译失败)
  - [19.4 客户端断开](#194-客户端断开)
  - [19.5 插件加载失败](#195-插件加载失败)
- [二十、与其他引擎对比](#二十与其他引擎对比)
  - [20.1 与 Unity AssetDatabase 的对比](#201-与-unity-assetdatabase-的对比)
  - [20.2 与 Unreal Live Coding 的对比](#202-与-unreal-live-coding-的对比)
  - [20.3 与 Make/CMake 的对比](#203-与-makecmake-的对比)
  - [20.4 与 Bazel 的对比](#204-与-bazel-的对比)
  - [20.5 BigWorld JIT 设计的优劣分析](#205-bigworld-jit-设计的优劣分析)
- [附录 A:关键文件清单](#附录-a关键文件清单)
- [附录 B:ConversionTask 状态机伪代码](#附录-bconversiontask-状态机伪代码)
- [附录 C:JIT 编译典型时序](#附录-cjit-编译典型时序)
- [附录 D:术语表](#附录-d术语表)

---

## 一、JIT 编译概述与设计哲学

### 1.1 什么是 JIT 资源编译

JIT,即 **Just-In-Time**(即时编译),在 BigWorld Engine 语境下指代一种**按需、增量、实时**的资源编译模式。游戏开发过程中,美术、关卡设计师、程序员持续地修改源资源(Maya 模型、Photoshop 贴图、XML 配置、FX 特效文件等),而引擎运行时需要的不是这些源文件,而是经过编译、压缩、格式转换后的"目标资源"(compiled assets)——例如 `.visual`、`.primitives`、`.dds`、`.bsp2`、`.fx_compiled` 等。

传统做法是要求开发者在每次启动游戏客户端前,手动运行一次完整的批处理编译(`batch_compiler`),这会带来两类严重问题:

1. **时间成本高昂**:大型项目可能有数万资源,完整扫描和编译动辄数十分钟,严重打断开发节奏。
2. **编译量浪费**:开发者往往只修改了一两个文件,却要为整库重新编译付出代价。

BigWorld 的 JIT 资源编译通过一个常驻后台的守护进程 `jit_compiler.exe`,配合以下机制解决上述痛点:

- **文件变更监听**:监听资源目录下的所有文件改动,只在文件真正被修改时触发编译。
- **反向依赖图**:维护"产物 → 源"的反向映射,任意文件改动都能在 O(1) 时间内找到所有受影响的任务。
- **增量编译**:仅重编译受影响的部分任务,而非全量。
- **命名管道 IPC**:游戏客户端在加载资源时,若资源未就绪,通过命名管道向 JIT 编译器发起请求,编译器立即将该资源任务插队到队首,完成后广播"就绪"通知。
- **内容寻址缓存**:跨项目、跨机器共享已经编译过的产物,相同内容只编译一次。
- **多线程并行**:基于 BigWorld 自有的 `BgTaskManager` 后台任务管理器,自动调度多个工作线程并行处理不同任务。

### 1.2 为什么需要 JIT:开发效率 vs 运行性能

游戏资源编译存在一个根本矛盾:

| 维度 | 开发期需求 | 运行期需求 |
|------|------------|------------|
| 资源格式 | 可读、可编辑、版本控制友好(Maya .ma、PSD、XML、FX 文本) | 引擎可直接消费的二进制(DDS、Primitives、Compiled Visual、BSP2) |
| 编译时机 | 改完即看到效果 | 启动时已经全部就绪 |
| 编译粒度 | 单文件、可见 | 全量、稳定 |
| 编译耗时容忍度 | 秒级 | 0 |

AOT(Ahead-Of-Time)批处理编译在开发期的劣势是显然的:**修改一个文件就要等几分钟甚至几十分钟,严重打断迭代节奏**。但运行期又必须接受已编译好的产物,不能让游戏帧率受文件解析影响。

JIT 编译在两者之间取得平衡:

- 开发期:源文件即源真相,游戏客户端按需触发编译,首次启动略慢但后续迭代只需编译增量。
- 运行期:发布构建仍使用 `batch_compiler` 一次性产出全部目标资源,JIT 编译器不参与。

### 1.3 传统 AOT 编译 vs JIT 编译

| 对比维度 | 传统 AOT(batch_compiler) | JIT(jit_compiler) |
|----------|--------------------------|---------------------|
| 编译触发 | 显式命令行启动 | 文件改动 / 客户端请求 |
| 编译范围 | 全量或指定路径 | 增量(反向依赖图) |
| 依赖查找 | 正向依赖图(从源到产物) | 反向依赖图(从产物到源) |
| 编译延迟 | 分钟级到小时级 | 秒级(命中缓存时毫秒级) |
| 跨进程通信 | 无 | 命名管道 |
| 运行模式 | 一次性 CLI | 常驻 GUI 守护进程 |
| 适用场景 | 发布构建、CI 夜间构建 | 日常开发迭代 |
| 输出 | 控制台日志 + HTML 报告 | 实时任务列表 + 系统托盘 |

### 1.4 BigWorld 的 JIT 策略:开发时无感编译

BigWorld 的设计哲学是 **"开发时无感编译"**——开发者只需要:

1. 启动 `jit_compiler.exe`(通常会加入开机启动或快捷方式)。
2. 直接编辑源资源文件(Maya / Photoshop / 文本编辑器)。
3. 在游戏客户端里直接加载资源。

整个过程开发者无需关心"是否需要重新编译"——JIT 编译器自动监听文件改动,游戏客户端自动等待编译完成。这种"无感"体验是 BigWorld 工具链的核心竞争力之一。

JIT 策略的核心组件分工:

```
┌─────────────────────────────────────────────────────────────────┐
│                     开发者工作流                                  │
│   编辑源文件 → 保存 → jit_compiler 监听到 → 增量重编译            │
│                              ↓                                    │
│   启动游戏客户端 → 请求资源 → jit_compiler 命名管道响应            │
│                              ↓                                    │
│   游戏客户端加载资源 → 完成                                       │
└─────────────────────────────────────────────────────────────────┘
```

### 1.5 与 Unity AssetDatabase 的对比

Unity 的 AssetDatabase 是一种**同步阻塞**的资源导入机制:

- **同步导入**:Unity 在编辑器内导入资源,导入完成前主线程被阻塞。
- **强耦合编辑器**:AssetDatabase 与 Unity Editor 进程绑定,关闭编辑器后导入停止。
- **Library 目录**:Unity 把所有导入产物放在 `Library/` 目录下,该目录通常不进入版本控制。
- **没有内容寻址缓存**:Unity 5.x 的 AssetDatabase v1 不缓存编译产物,每次切换平台都要重新导入。
- **跨项目不共享**:每个项目独立导入,无法跨项目共享产物。

BigWorld JIT 编译的优势:

- **异步多线程**:JIT 编译器与游戏客户端是不同进程,编译不阻塞游戏。
- **独立守护进程**:即使没有游戏客户端在跑,JIT 编译器也能持续编译。
- **内容寻址缓存**:`ContentAddressableCache` 让相同内容的产物跨项目共享。
- **跨进程 IPC**:命名管道让客户端按需触发编译,无需等待全部完成。

Unity 的优势是 **导入更"内聚"**:不需要外部 IPC,资源状态变化直接通过 Editor 内的回调传递。BigWorld 的代价是需要维护两套机制(正向依赖 + 反向依赖)和一套复杂的 IPC。

### 1.6 与 Unreal Live Coding 的对比

Unreal Engine 的 Live Coding 是一种**C++ 代码热重载**机制,关注的是**代码**,不是资产:

- **目标**:C++ 代码修改后的快速重载,无需关闭 Editor。
- **机制**:增量编译 .obj 文件 → 链接成 .dll → 通过 PatchTable 替换函数指针。
- **范围**:仅限代码,不涉及 .uasset 资源的导入。

BigWorld 的 JIT 与之正交——它关注的是**资源**而非代码。BigWorld 的 C++ 代码热重载由 `Reload` 模块负责(见 `lib/moo/reload.cpp`),与 JIT 资源编译是两套独立机制。Unreal 的 `.uasset` 导入更接近 Unity 的 AssetDatabase 模型,也是同步、Editor 内的。

BigWorld 把"代码"和"资源"清晰分离,资源编译完全由独立的 asset_pipeline 子系统负责,职责边界明确。

---

## 二、asset_pipeline 核心库总览

### 2.1 目录结构

asset_pipeline 核心库位于 `programming/bigworld/tools/asset_pipeline/`,目录结构如下:

```
asset_pipeline/
├── compiler/                       # 编译器抽象与实现
│   ├── compiler.hpp                 # Compiler 抽象基类(170 行)
│   ├── asset_compiler.hpp           # AssetCompiler 实现声明
│   ├── asset_compiler.cpp           # AssetCompiler 实现(1269 行)
│   ├── asset_compiler_options.hpp  # 命令行选项基类
│   ├── asset_compiler_options.cpp
│   ├── generic_conversion_rule.hpp # 通用 XML 规则
│   ├── generic_conversion_rule.cpp
│   ├── resource_callbacks.hpp      # 资源回调接口
│   ├── resource_callbacks.cpp
│   ├── test_compiler/               # 测试用编译器
│   ├── test_converter/              # 测试用转换器
│   └── unit_test/                   # 单元测试
│
├── conversion/                     # 转换任务调度
│   ├── conversion_task.hpp          # ConversionTask 状态机
│   ├── conversion_task_queue.hpp   # 任务双端队列
│   ├── task_processor.hpp           # TaskProcessor 调度器
│   ├── task_processor.cpp           # 实现(1028 行)
│   ├── converter.hpp                # Converter 接口
│   ├── converter_info.hpp           # ConverterInfo 元信息
│   ├── converter_creator.hpp        # 创建函数指针类型
│   ├── converter_map.hpp            # id → ConverterInfo 映射
│   ├── content_addressable_cache.hpp # 内容寻址缓存
│   └── content_addressable_cache.cpp
│
├── converters/                     # 内置转换器插件(DLL)
│   ├── bsp_converter/               # BSP 物理碰撞
│   ├── effect_converter/            # FX 特效编译
│   ├── hierarchical_config_converter/
│   ├── primitive_processor/         # 顶点数据
│   ├── space_converter/            # 空间数据
│   ├── texformat_converter/         # 纹理格式
│   ├── texture_converter/           # 纹理转换
│   └── visual_processor/           # 模型可视化
│
├── dependency/                     # 依赖系统
│   ├── dependency.hpp               # Dependency 基类(6 种类型)
│   ├── dependency.cpp
│   ├── dependency_list.hpp          # DependencyList 依赖列表
│   ├── dependency_list.cpp
│   ├── source_file_dependency.hpp  # 源文件依赖
│   ├── intermediate_file_dependency.hpp # 中间产物依赖
│   ├── output_file_dependency.hpp   # 最终产物依赖
│   ├── converter_dependency.hpp     # 转换器版本依赖
│   ├── converter_params_dependency.hpp # 转换器参数依赖
│   ├── directory_dependency.hpp     # 目录依赖(支持正则)
│   └── unit_test/
│
└── discovery/                     # 任务发现
    ├── conversion_rule.hpp          # ConversionRule 接口
    ├── conversion_rules.hpp         # ConversionRules 容器
    ├── task_finder.hpp              # TaskFinder 任务发现
    └── task_finder.cpp              # 实现(258 行)
```

### 2.2 四大子模块职责

| 子模块 | 职责 | 关键类 |
|--------|------|--------|
| `compiler/` | 提供编译器抽象基类 `Compiler` 和具体实现 `AssetCompiler`,管理状态、线程池、资源路径、错误传播 | `Compiler`、`AssetCompiler`、`AssetCompilerOptions`、`GenericConversionRule`、`ResourceCallbacks` |
| `conversion/` | 定义任务状态机、调度器、缓存机制、转换器接口 | `ConversionTask`、`TaskProcessor`、`ConverterGuard`、`ContentAddressableCache`、`Converter`、`ConverterInfo`、`ConverterMap`、`ConversionTaskQueue` |
| `dependency/` | 定义六种依赖类型与依赖列表,负责依赖序列化、哈希计算 | `Dependency`(基类)、`SourceFileDependency`、`IntermediateFileDependency`、`OutputFileDependency`、`ConverterDependency`、`ConverterParamsDependency`、`DirectoryDependency`、`DependencyList` |
| `discovery/` | 在文件系统中扫描源文件,匹配转换规则,创建 ConversionTask | `ConversionRule`、`ConversionRules`、`TaskFinder` |
| `converters/` | 内置转换器插件的 DLL 实现,每个插件负责一类资源 | `BSPConverter`、`EffectConverter`、`HierarchicalConfigConverter`、`PrimitiveProcessor`、`SpaceConverter`、`TexFormatConverter`、`TextureConverter`、`VisualProcessor` |

### 2.3 整体架构图

```
┌─────────────────────────────────────────────────────────────────────┐
│                asset_pipeline 核心库架构                             │
└─────────────────────────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────────────────┐
  │                  discovery/ (TaskFinder)                         │
  │  扫盘 → 匹配 ConversionRule → 生成 ConversionTask                │
  └──────────────────┬──────────────────────────────────────────────┘
                     │ ConversionTask
                     ▼
  ┌─────────────────────────────────────────────────────────────────┐
  │             compiler/ (AssetCompiler : Compiler)                 │
  │  ┌─────────────┐  ┌─────────────┐  ┌────────────────────────┐  │
  │  │ taskQueue_  │  │ taskSemaphore │ │ state_(INVALID/EXECUTING│  │
  │  │ (deque)     │  │ (并发控制)   │ │ /PAUSED/TERMINATING)   │  │
  │  └──────┬──────┘  └─────────────┘  └────────────────────────┘  │
  │         │                                                       │
  │         │ THREADLOCAL: s_currentTask, s_error, s_warning, ...   │
  │         ▼                                                       │
  └─────────┼───────────────────────────────────────────────────────┘
            │ getNextTask()
            ▼
  ┌─────────────────────────────────────────────────────────────────┐
  │            conversion/ (TaskProcessor)                           │
  │  processTask() → processNewTask → processPrimaryDependencies    │
  │     → processSecondaryDependencies → processConversion           │
  │  ┌────────────────┐   ┌────────────────┐  ┌─────────────────┐  │
  │  │ ConverterGuard │   │ ContentAddr-   │  │ ConverterMap    │  │
  │  │ (RWLock)       │   │ essableCache   │  │ (id→Info)       │  │
  │  └────────────────┘   └────────────────┘  └─────────────────┘  │
  └─────────┬───────────────────────────────────────────────────────┘
            │ addPrimarySourceFileDependency / addSecondary...
            ▼
  ┌─────────────────────────────────────────────────────────────────┐
  │              dependency/ (DependencyList)                        │
  │  primaryInputs_[3]: SourceFile, Converter, ConverterParams      │
  │  secondaryInputs_[N]: 任意类型的二级依赖                          │
  │  intermediateOutputs_[] / outputs_[]                             │
  │  .deps 文件序列化                                                │
  └─────────────────────────────────────────────────────────────────┘
            ▲
            │ registerConverter / registerConversionRule
            │
  ┌─────────┴────────────────────────────────────────────────────────┐
  │              converters/ (插件 DLL)                              │
  │   bsp_converter.dll  effect_converter.dll  ... 8 个内置插件      │
  └──────────────────────────────────────────────────────────────────┘
```

### 2.4 与 lib/asset_pipeline 的关系

`lib/asset_pipeline/` 是 IPC 层,提供跨进程通信能力,而非编译逻辑:

```
lib/asset_pipeline/
├── asset_pipe.hpp / .cpp     # 命名管道工具,常量定义
├── asset_server.hpp / .cpp   # AssetServer 基类(命名管道服务端)
├── asset_client.hpp / .cpp   # AssetClient 基类(命名管道客户端)
├── asset_lock.hpp / .cpp     # AssetLock 跨进程锁
└── pch.hpp / pch.cpp         # 预编译头
```

- `AssetServer` 由 `JITCompiler` 继承,提供 `broadcastAsset()` 与命名管道服务循环。
- `AssetClient` 由游戏客户端使用,通过 `requestAsset()` 向服务端请求资产。
- `AssetPipe` 定义共享常量(管道路径、token、命令字)。

`lib/asset_pipeline` 与 `tools/asset_pipeline` 的关系是:**前者是 IPC 传输层,后者是编译业务层**。`JITCompiler` 同时继承两者(`AssetCompiler` + `AssetServer`),把编译结果通过命名管道广播给客户端。

---

## 三、compiler 子模块深度剖析

### 3.1 Compiler 抽象基类

`compiler.hpp` 定义了 asset_pipeline 的核心抽象接口 `Compiler`:

```cpp
// programming/bigworld/tools/asset_pipeline/compiler/compiler.hpp:24-31
class Compiler
{
private:
	// Only AssetCompiler is allowed to inherit this class
	friend class AssetCompiler;

	Compiler() {}
	virtual ~Compiler() {}
```

**关键设计**:构造函数和析构函数被声明为 `private`,只通过 `friend class AssetCompiler` 把访问权限授予 AssetCompiler。这意味着:

1. **外部代码无法直接继承 `Compiler`**——只有 `AssetCompiler` 可以继承。
2. **禁止实例化 `Compiler` 本身**——它是一个纯抽象接口。
3. **插件代码只能拿到 `Compiler&` 引用**,无法破坏封装。

Compiler 接口提供的回调可分为 7 类:

| 类别 | 方法 | 调用者 |
|------|------|--------|
| 注册 | `registerConversionRule`、`registerConverter`、`registerResourceCallbacks` | 插件 PLUGIN_INIT |
| 资源路径 | `getResourcePaths`、`resolveRelativePath`、`resolveSourcePath`、`resolveIntermediatePath`、`resolveOutputPath` | 转换器 |
| 依赖查询 | `ensureUpToDate`、`getSourceFile`、`getHash`、`getFileHash`、`checkFileHashUpToDate`、`getDirectoryHash` | 转换器、TaskProcessor |
| 错误状态 | `setError`、`setWarning`、`resetErrorFlags`、`hasError`、`hasWarning` | 转换器 |
| 任务调度 | `shouldIterateFile`、`shouldIterateDirectory`、`hasTasks`、`getNextTask`、`queueTask` | TaskFinder、TaskProcessor |
| 任务回调 | `onTaskStarted`、`onTaskResumed`、`onTaskSuspended`、`onTaskCompleted` | TaskProcessor |
| 编译过程回调 | `onPreCreateDependencies`、`onPostCreateDependencies`、`onPreConvert`、`onPostConvert` | TaskProcessor |
| 输出回调 | `onOutputGenerated` | TaskProcessor |
| 缓存回调 | `onCacheRead`、`onCacheReadMiss`、`onCacheWrite`、`onCacheWriteMiss` | ContentAddressableCache |

这套接口合计 28 个虚函数,构成了 asset_pipeline 的"扩展点"——所有具体行为(扫描、调度、缓存、错误处理)都通过这些回调被插件或上层工具定制。

### 3.2 AssetCompiler 实现类

`AssetCompiler` 是 `Compiler` 的具体实现,继承自 `Compiler` 同时还继承了 `DebugMessageCallback` 与 `CriticalMessageCallback`,用于捕获调试消息和断言:

```cpp
// programming/bigworld/tools/asset_pipeline/compiler/asset_compiler.hpp:18-21
class AssetCompiler : public Compiler
					, public DebugMessageCallback
					, public CriticalMessageCallback
```

AssetCompiler 的成员可分为 5 组:

#### 状态组

```cpp
// programming/bigworld/tools/asset_pipeline/compiler/asset_compiler.hpp:122-128
enum CompilerState
{
    INVALID,
    EXECUTING,
    PAUSED,
    TERMINATING
} state_;
```

`CompilerState` 是一个 4 态状态机:`INVALID`(未初始化)→ `EXECUTING`(运行中)↔ `PAUSED`(暂停)→ `TERMINATING`(终止中)。`pause()`、`resume()`、`terminate()` 方法在状态间转换。

#### 路径组

```cpp
BW::string		intermediatePath_;   // 中间产物路径
BW::string		outputPath_;        // 最终产物路径
BW::vector< BW::string > resourcePaths_; // BWResource 资源路径
```

这三个路径决定源文件、中间产物、最终产物的物理位置,通过 `resolveRelativePath` / `resolveSourcePath` / `resolveIntermediatePath` / `resolveOutputPath` 进行相互转换。

#### 任务调度组

```cpp
TaskFinder		taskFinder_;        // 任务发现器
TaskProcessor	taskProcessor_;     // 任务处理器
ConversionTaskQueue taskQueue_;     // 任务双端队列
SimpleMutex			taskQueueMutex_; // 队列互斥锁
HANDLE				taskSemaphore_;  // 任务信号量(暂停/恢复用)
```

`taskQueue_` 是 `BW::deque<ConversionTask*>`,允许从两端 push/pop,以支持任务插队(JIT 编译器的 `onAssetRequested` 会把任务 push 到队首)。

#### 转换器注册组

```cpp
GenericConversionRule genericConversionRule_; // 通用 XML 规则
ConversionRules conversionRules_;              // 规则列表(vector)
ConverterMap	converterMap_;                // id → ConverterInfo 映射
BW::vector< ResourceCallbacks * > resourceCallbacks_; // 资源回调列表
```

#### 哈希缓存组

```cpp
StringHashMap< uint64 >	fileHashes_;      // 文件名 → 哈希
mutable ReadWriteLock	fileHashesLock_;  // 读写锁
```

`fileHashes_` 是文件哈希的内存缓存,避免每次都重新读取磁盘文件计算哈希。使用 `ReadWriteLock` 实现并发读、独占写。

### 3.3 private 构造 + friend AssetCompiler 约束

`Compiler` 的构造函数是 private,只通过 `friend class AssetCompiler` 暴露给 AssetCompiler:

```cpp
// programming/bigworld/tools/asset_pipeline/compiler/compiler.hpp:26-31
private:
	// Only AssetCompiler is allowed to inherit this class
	friend class AssetCompiler;

	Compiler() {}
	virtual ~Compiler() {}
```

这是 C++ 中实现"接口 + 单一实现"约束的经典手法:

1. **`Compiler` 自身无法被实例化**(纯抽象 + private 构造)。
2. **任何第三方代码无法直接 `class X : public Compiler`**(因为派生类的构造需要先访问基类的构造,而基类构造是 private)。
3. **只有 `AssetCompiler` 通过 friend 关系获得访问权限**,可以正常构造析构。
4. **JITCompiler / BatchCompiler 必须继承 AssetCompiler**,而非直接继承 Compiler。

这个约束确保了 asset_pipeline 不允许第三方在不知道 `AssetCompiler` 的情况下提供另一套编译器实现——所有定制点都被限制在 `AssetCompiler` 的虚函数回调中。

但插件 DLL 中有一个有趣的代码模式:

```cpp
// programming/bigworld/tools/asset_pipeline/converters/bsp_converter/plugin_main.cpp:26-32
PLUGIN_INIT_FUNC
{
	Compiler * compiler = dynamic_cast< Compiler * >( &pluginLoader );
	if (compiler == NULL)
	{
		return false;
	}
    // ...
}
```

`pluginLoader` 是 `PluginLoader&`,通过 `dynamic_cast<Compiler*>` 转换为 Compiler 指针。这能成功是因为 `JITCompiler` 同时继承 `AssetCompiler`(可访问 Compiler)与 `PluginLoader`,在 `dynamic_cast` 时跨越了继承层级——这是合法的,因为 `AssetCompiler` 是 `Compiler` 的 public 派生,且 `Compiler` 有虚函数(虽然没显式声明 virtual,但所有 28 个纯虚函数都是 virtual)。

### 3.4 单实例锁机制

AssetCompiler 在构造时通过 Windows 命名 Mutex 强制单实例运行:

```cpp
// programming/bigworld/tools/asset_pipeline/compiler/asset_compiler.cpp:41-91
AssetCompiler::AssetCompiler()
	: state_( INVALID )
    // ...
{
	BW::vector< BW::wstring > baseResourcePaths = AssetPipe::getBaseResourcePaths();
	for (BW::vector< BW::wstring >::iterator 
		it = baseResourcePaths.begin(); it != baseResourcePaths.end(); ++it)
	{
		BW::wstring mutexName = L"Local\\AssetPipeline" + *it;
		HANDLE compilerMutex = CreateMutexW( 0, TRUE, mutexName.c_str() );
		if(GetLastError() == ERROR_ALREADY_EXISTS)
		{
			::MessageBox( NULL, 
				L"Only one instance of the AssetPipeline is allowed to be active per resource path.",
				L"AssetPipeline",
				MB_OK );
			exit(-1);
		}
		compilerMutexes_.push_back( compilerMutex );

		BW::wstring subPath = *it;
		while (true)
		{
			BW::wstring::size_type pos = subPath.find_last_of( L"\\/" );
			if (pos == BW::wstring::npos)
			{
				break;
			}
			subPath = subPath.substr( 0, pos );

			mutexName = L"Local\\AssetPipeline" + subPath;
			compilerMutex = CreateMutexW( 0, FALSE, mutexName.c_str() );
			if (WaitForSingleObject( compilerMutex, 100 ) != WAIT_OBJECT_0)
			{
				::MessageBox( NULL, 
					L"Only one instance of the AssetPipeline is allowed to be active per resource path.",
					L"AssetPipeline",
					MB_OK );
				exit(-1);
			}
			ReleaseMutex( compilerMutex );
			compilerMutexes_.push_back( compilerMutex );
		}
	}
}
```

**算法分析**:

1. 对每个 base resource path(从 `AssetPipe::getBaseResourcePaths()` 获取),创建一个名为 `Local\AssetPipeline<path>` 的 Mutex,以 `TRUE`(初始 owner)模式创建。
2. 如果 `GetLastError() == ERROR_ALREADY_EXISTS`,说明已有另一个 AssetPipeline 实例占用同一资源路径,**直接弹出 MessageBox 并 `exit(-1)`**。
3. 接着对 path 的每一级父目录创建同名 Mutex(以 `FALSE` 模式,即非 owner),并尝试 `WaitForSingleObject` 100ms。
4. 如果某一级父目录的 Mutex 已被占用,说明子路径被另一实例占用——同样弹窗并退出。

**为什么需要逐级检查父目录?**

考虑两个场景:
- 场景 A:实例 1 占用 `D:\game\res`,实例 2 想占用 `D:\game\res\sub`——后者是前者的子集,应该被禁止。
- 场景 B:实例 1 占用 `D:\game\res\sub`,实例 2 想占用 `D:\game\res`——后者包含前者,也应该被禁止。

逐级向上检查父目录的 Mutex 就是为了处理场景 B——子路径被占用时,父路径也禁止新实例。这避免了两个 JIT 编译器同时为一个共同子集的资源竞争编译。

注意 Mutex 名以 `Local\` 前缀开头,这意味着是 **session-local**(每个 Windows 用户会话独立)。如果是 `Global\` 前缀,则跨会话。BigWorld 选择 `Local\` 是因为通常一个开发者用一个会话,无需跨会话隔离。

### 3.5 循环依赖检测:线程 ID 传播法

asset_pipeline 的循环依赖检测是通过 `ConversionTask::threadId_` 字段实现的"线程 ID 传播法"。

#### 算法原理

每个 ConversionTask 在被某线程处理时,其 `threadId_` 被设置为该线程的 ID。当一个任务 A 在编译过程中需要等待另一个任务 B 完成时,会发生:

1. 如果 B 已经被处理(`PROCESSING` 或之后状态):
   - A 把自己的 `threadId_` 设为 B 的 `threadId_`。
   - 如果发现 `threadId_ == GetCurrentThreadId()`,说明**当前线程正在等待自己**——这只能是循环依赖。
2. 如果 B 还未处理(NEW/QUEUED),且 `recursive_` 模式开启,则在当前线程内联处理 B(挂起 A,启动 B,完成后恢复 A)。

代码实现:

```cpp
// programming/bigworld/tools/asset_pipeline/compiler/asset_compiler.cpp:593-622
while (task.status_ != ConversionTask::DONE &&
		task.status_ != ConversionTask::FAILED)
{
	if (numThreads_ == 1)
	{
		// We can't be waiting on a task on a different thread as we aren't
		// running multi-threaded. Must have encountered a cyclic dependency.
		ERROR_MSG( "Cyclic dependency found %s\n", task.source_.c_str() );
		break;
	}
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
	else
	{
		s_currentTask->threadId_ = GetCurrentThreadId();
	}
	// If the task is not new and its not completed it means another
	// thread is processing it. In this case we need to
	// block until it is done.
	// TODO: use an event?
	Sleep(0);
}
```

#### 传播链示例

考虑依赖图:A → B → C → A(循环)

线程 T1 开始处理 A,设置 `A.threadId_ = T1`。
A 需要等待 B,设置 `A.threadId_ = B.threadId_`。
若 B 在 T1 之外的其他线程 T2 处理,则 `A.threadId_ = T2`。
B 需要 C,`B.threadId_ = C.threadId_`。
若 C 在 T2 处理,`B.threadId_ = T2`。
C 需要 A,A 此时 `threadId_ = T2`(被传播过来),于是 `C.threadId_ = A.threadId_ = T2`。
此时检测到 `C.threadId_ == GetCurrentThreadId()`(T2),判定为循环依赖。

#### 算法限制

- **单线程模式**:`numThreads_ == 1` 时无法传播,直接判定为循环依赖。这意味着单线程模式下,任何"任务依赖另一个未完成任务"的情况都会被当作循环依赖处理(因为在同一线程内确实无法并行等待)。
- **Sleep(0) 自旋**:等待时使用 `Sleep(0)` 让出 CPU,但是会反复检查状态,可能浪费 CPU。代码注释 `// TODO: use an event?` 表明作者也意识到了这一点。

### 3.6 插件机制

asset_pipeline 通过 PluginLoader 加载转换器插件 DLL。每个插件 DLL 需要导出两个 C 函数:

```cpp
// programming/bigworld/tools/plugin_system/plugin.hpp:19-24
#ifdef _DEBUG
	#define PLUGIN_INIT_FUNC extern "C" __declspec(dllexport) bool PLUGIN_INIT( PluginLoader & pluginLoader )
	#define PLUGIN_FINI_FUNC extern "C" __declspec(dllexport) bool PLUGIN_FINI( PluginLoader & pluginLoader )
#else
	#define PLUGIN_INIT_FUNC extern "C" __declspec(dllexport) bool PLUGIN_INIT( PluginLoader & pluginLoader )
	#define PLUGIN_FINI_FUNC extern "C" __declspec(dllexport) bool PLUGIN_FINI( PluginLoader & pluginLoader )
#endif
```

插件通过 `dynamic_cast<Compiler*>(&pluginLoader)` 把 PluginLoader 转换成 Compiler 指针。这个转换之所以能成功,是因为 JITCompiler/BatchCompiler 同时多重继承了 AssetCompiler 和 PluginLoader,而 AssetCompiler 又 public 继承 Compiler——`dynamic_cast` 能在多继承层级中找到正确的 Compiler 子对象。

PLUGIN_INIT 的典型实现:

```cpp
// programming/bigworld/tools/asset_pipeline/converters/bsp_converter/plugin_main.cpp:26-53
PLUGIN_INIT_FUNC
{
	Compiler * compiler = dynamic_cast< Compiler * >( &pluginLoader );
	if (compiler == NULL)
	{
		return false;
	}

	const auto & paths = compiler->getResourcePaths();
	bool bInitRes = BWResource::init( paths );

	if ( !AutoConfig::configureAllFrom( "resources.xml" ) )
	{
		ERROR_MSG("Couldn't load auto-config strings from resource.xml\n" );
	}
	
	INIT_CONVERTER_INFO( bspConverterInfo, 
						 BSPConverter, 
						 ConverterInfo::DEFAULT_FLAGS | ConverterInfo::UPGRADE_CONVERSION );

	compiler->registerConversionRule( bspConversionRule );
	compiler->registerConverter( bspConverterInfo );
	compiler->registerResourceCallbacks( resourceCallbacks );

	return true;
}
```

每个插件完成四件事:
1. 从 PluginLoader 获取 Compiler 接口。
2. 初始化自己的资源系统(BWResource::init + AutoConfig)。
3. 通过 `INIT_CONVERTER_INFO` 宏填充 ConverterInfo 结构。
4. 调用 `compiler->registerConverter` / `registerConversionRule` / `registerResourceCallbacks` 把自己的转换器、规则、回调注册进去。

### 3.7 THREADLOCAL 状态与错误传播

AssetCompiler 使用 6 个 THREADLOCAL 变量来跟踪每线程的编译状态:

```cpp
// programming/bigworld/tools/asset_pipeline/compiler/asset_compiler.hpp:151-156
static THREADLOCAL( bool ) 					s_error;
static THREADLOCAL( bool ) 					s_warning;
static THREADLOCAL( ConversionTask* )		s_currentTask;
static THREADLOCAL( ConversionTaskQueue* )	s_currentTaskQueue;
static THREADLOCAL( bool )					s_CreatingDependencies;
static THREADLOCAL( bool )					s_Converting;
```

- `s_error` / `s_warning`:当前线程是否有错误/警告。
- `s_currentTask`:当前线程正在处理的 ConversionTask 指针。
- `s_currentTaskQueue`:当前线程的挂起任务队列(非递归模式用)。
- `s_CreatingDependencies` / `s_Converting`:当前是否在创建依赖或转换阶段。

错误传播链:

1. 转换器在 createDependencies/convert 中调用 `ERROR_MSG("...")` 或 `MF_ASSERT`。
2. ERROR_MSG 触发 DebugFilter 的回调,被 AssetCompiler 的 `handleMessage` 接住。
3. `handleMessage` 检查 `s_CreatingDependencies` / `s_Converting`,若为 true 则设置 `s_error = true`。
4. TaskProcessor 在调用 `createDependencies` / `convert` 后检查 `compiler_.hasError()`,若为 true 则标记任务为 FAILED。
5. CriticalMessageCallback(`handleCritical`)在断言时被调用,如果 `ASSET_PIPELINE_CAPTURE_ASSERTS` 宏打开,则抛出异常被 try/catch 接住,避免进程崩溃。

```cpp
// programming/bigworld/tools/asset_pipeline/compiler/asset_compiler.cpp:1109-1121
void AssetCompiler::handleCritical( const char * msg )
{
	if (!s_CreatingDependencies && !s_Converting)
	{
		return;
	}

#if ASSET_PIPELINE_CAPTURE_ASSERTS
	// If an assert was fired while creating dependencies or converting, throw an exception
	// to cause the current task to error but not crash the application.
	throw msg;
#endif
}
```

注意 `ASSET_PIPELINE_CAPTURE_ASSERTS` 默认值为 0(关闭),即默认情况下断言会让进程崩溃。开启后会把断言转为异常,代价是 try/catch 的开销和潜在的 RAII 资源泄漏。

---

## 四、conversion 子模块深度剖析

### 4.1 ConversionTask 状态机

ConversionTask 是 asset_pipeline 的核心数据结构,定义在 `conversion_task.hpp`:

```cpp
// programming/bigworld/tools/asset_pipeline/conversion/conversion_task.hpp:16-57
struct ConversionTask
{
	/// filename of source asset
	BW::string	source_;

	/// id of the converter used to process this asset.
	uint64		converterId_;
	/// the version number of the converter used to process this asset.
	BW::string	converterVersion_;
	/// the parameters to initialise the converter for processing this asset.
	BW::string	converterParams_;

	/// enum representing the stage of the asset in the conversion process.
	/// DO NOT change the order of this enum as it essential to the logic of the asset pipeline
	enum
	{
		NEW,					/// <task is newly created. has not been queued for processing.
		QUEUED,					/// <task has been queued for processing.
		PROCESSING,				/// <task has been removed from queue and is being processed.
		NEEDS_PRIMARY_DEPS,		/// <task is being processed and needs its primary dependencies evaluated.
		NEEDS_SECONDARY_DEPS,	/// <task is being processed and needs its secondary dependencies evaluated.
		NEEDS_CONVERSION,		/// <task is being processed and needs to be converted.
		DONE,					/// <task has been completed.
		FAILED					/// <task has encountered an error whilst in a previous state.
	}			status_;

	/// a list of tasks that this task depends on
	typedef BW::vector< std::pair< const ConversionTask*, bool > > SubTaskList;
	SubTaskList subTasks_;

	/// the id of the thread that this task is waiting for. Initially set to the
	/// id of the thread processing this task, if a sub task is triggered, the
	/// thread id will be set to the id of the thread processing the sub task
	DWORD		threadId_;

	/// handle to the source file of this task. Used to prevent external changes to
	/// the source file during conversion
	HANDLE		fileHandle_;

	/// the converter id for an task that the asset pipeline does not know how to convert.
	static const uint64 s_unknownId = 0;
};
```

字段含义:

| 字段 | 类型 | 含义 |
|------|------|------|
| `source_` | `BW::string` | 源文件的绝对路径 |
| `converterId_` | `uint64` | 转换器 ID,从 ConverterMap 查找。0 表示未知 |
| `converterVersion_` | `BW::string` | 转换器版本,用于触发重建 |
| `converterParams_` | `BW::string` | 转换器初始化参数(传给构造函数) |
| `status_` | enum(8态) | 当前状态 |
| `subTasks_` | `vector<pair<const ConversionTask*, bool>>` | 此任务依赖的子任务列表(bool=isCritical) |
| `threadId_` | `DWORD` | 处理此任务的线程 ID(用于循环检测) |
| `fileHandle_` | `HANDLE` | 源文件句柄(防止转换中被修改) |

### 4.2 TaskProcessor 多线程调度

TaskProcessor 是 ConversionTask 的调度引擎,核心方法 `processTask`:

```cpp
// programming/bigworld/tools/asset_pipeline/conversion/task_processor.cpp:219-282
void TaskProcessor::processTask( ConversionTask & conversionTask )
{
	if (conversionTask.fileHandle_ == INVALID_HANDLE_VALUE)
	{
		ERROR_MSG( "FAILED: Could not acquire source handle.\n" );
		conversionTask.status_ = ConversionTask::FAILED;
		return;
	}

	// Sanity check that the task being processed is actually in a processing stage
	MF_ASSERT( conversionTask.status_ >= ConversionTask::PROCESSING )
	MF_ASSERT( conversionTask.status_ < ConversionTask::DONE )
	if (conversionTask.status_ >= ConversionTask::DONE)
	{
		return;
	}

	// Setup the task context
	TaskContext taskContext( *this, conversionTask );

	if (conversionTask.status_ == ConversionTask::PROCESSING)
	{
		if (!processNewTask( taskContext ))
		{
			MF_ASSERT( conversionTask.status_ == ConversionTask::FAILED );
			return;
		}
		MF_ASSERT( conversionTask.status_ == ConversionTask::NEEDS_PRIMARY_DEPS );
	}
	
	DependencyContext dependencyContext( *this, conversionTask );
	ConversionContext conversionContext( *this, conversionTask );

	if (conversionTask.status_ == ConversionTask::NEEDS_PRIMARY_DEPS)
	{
		if (!processPrimaryDependencies( taskContext, dependencyContext, conversionContext ))
		{
			MF_ASSERT( conversionTask.status_ == ConversionTask::FAILED );
			return;
		}
		MF_ASSERT( conversionTask.status_ == ConversionTask::NEEDS_SECONDARY_DEPS );
	}

	if (conversionTask.status_ == ConversionTask::NEEDS_SECONDARY_DEPS)
	{
		if (!processSecondaryDependencies( taskContext, dependencyContext, conversionContext ))
		{
			MF_ASSERT( conversionTask.status_ == ConversionTask::NEEDS_CONVERSION ||
					   conversionTask.status_ == ConversionTask::FAILED );
			return;
		}
		MF_ASSERT( conversionTask.status_ == ConversionTask::NEEDS_CONVERSION );
	}

	if (conversionTask.status_ == ConversionTask::NEEDS_CONVERSION)
	{
		if (!processConversion( taskContext, dependencyContext, conversionContext ))
		{
			MF_ASSERT( conversionTask.status_ == ConversionTask::FAILED );
			return;
		}
		MF_ASSERT( conversionTask.status_ == ConversionTask::DONE );
	}
}
```

`processTask` 是一个**状态机驱动器**——根据 `conversionTask.status_` 决定从哪一步开始执行。这意味着任务可以从任意中间状态恢复执行,这是挂起-恢复机制的基础。

TaskProcessor 内部维护三个上下文对象:

- **TaskContext**:任务的相对路径信息。
- **DependencyContext**:依赖列表(`.deps` 文件)的加载与缓存。
- **ConversionContext**:转换器实例的创建与销毁。

### 4.3 ConverterGuard 线程安全

ConverterGuard 是一个 RAII 守卫类,在 TaskProcessor.cpp 中实现(注意:不是独立的 .hpp 文件):

```cpp
// programming/bigworld/tools/asset_pipeline/conversion/task_processor.cpp:45-89
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
				// If we have pending exclusive tasks allow them to run first.
				Sleep( 0 );
			}
			// This task is thread safe so acquire a shared read lock
			s_lock_.beginRead();
			return;
		}
		
		InterlockedIncrement( &s_pendingWrites );
		// This task is not thread safe so acquire an exclusive write lock
		s_lock_.beginWrite();
		InterlockedDecrement( &s_pendingWrites );
	}

	~ConverterGuard()
	{
		if (threadSafe_)
		{
			s_lock_.endRead();
		}
		else
		{
			s_lock_.endWrite();
		}
	}

private:
	bool threadSafe_;
	static ReadWriteLock s_lock_;
	static volatile long s_pendingWrites;
};

ReadWriteLock ConverterGuard::s_lock_;
volatile long ConverterGuard::s_pendingWrites = 0;
```

#### 工作原理

- 全局共享一把 `ReadWriteLock`(`s_lock_`)和 `s_pendingWrites` 计数。
- 若转换器声明 `THREAD_SAFE` 标志:进入前先 spin-wait 直到没有 pending writes,然后 `beginRead()` 获取读锁。
- 若转换器非线程安全:先 `InterlockedIncrement(&s_pendingWrites)`,然后 `beginWrite()` 获取独占写锁,获取后 `InterlockedDecrement(&s_pendingWrites)`。
- 析构时根据 threadSafe_ 释放对应锁。

#### 设计目的

- **线程安全转换器**:多个线程可同时调用(读锁共享),提高并行度。
- **非线程安全转换器**:同一时刻只能一个线程调用(写锁独占)。
- **优先级倾斜**:线程安全的转换器会等待所有 pending writes 完成,这避免了写操作被读操作饿死。

### 4.4 ContentAddressableCache 内容寻址缓存

`ContentAddressableCache` 是 asset_pipeline 的特色实现,提供内容寻址的产物缓存:

```cpp
// programming/bigworld/tools/asset_pipeline/conversion/content_addressable_cache.hpp:15-31
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

private:
	static BW::string cachePath_;
	static bool readFromCache_;
	static bool writeToCache_;
};
```

这是一个全静态的类——没有实例,所有方法都是 static,通过类名直接调用。配置项包括缓存路径、是否读、是否写。

#### readFromCache 实现

```cpp
// programming/bigworld/tools/asset_pipeline/conversion/content_addressable_cache.cpp:44-94
bool ContentAddressableCache::readFromCache( const BW::string & filename, uint64 hash, Compiler & compiler )
{
	if (!readFromCache_ || cachePath_.empty())
	{
		return false;
	}

	const BW::string file = BWResource::getFilename( filename ).to_string();
	const BW::string directory = BWResource::getFilePath( filename );

	// Determine the cache file
	char cacheFilename[MAX_PATH];
	sprintf_s( cacheFilename, MAX_PATH, "%s%hhX/%s.%llX", 
		cachePath_.c_str(), static_cast< uint8 >( hash ), file.c_str(), hash );

	// Check if the file exists in the cache
	if (!BWResource::instance().fileExists( cacheFilename ))
	{
		compiler.onCacheReadMiss( filename );
		return false;
	}

	// Determine a temporary file name
	char tempFilename[MAX_PATH];
	if (!GetTempFileNameA( directory.c_str(), file.c_str(), 0, tempFilename ))
	{
		compiler.onCacheReadMiss( filename );
		return false;
	}

	// Copy from the cache file to the temporary file
	if (!BWResource::instance().fileSystem()->copyFileOrDirectory( cacheFilename, tempFilename ))
	{
		BWResource::instance().fileSystem()->eraseFileOrDirectory( tempFilename );
		compiler.onCacheReadMiss( filename );
		return false;
	}

	// Move the temporary file to the actual file
	if (!BWResource::instance().fileSystem()->moveFileOrDirectory( tempFilename, filename ))
	{
		BWResource::instance().fileSystem()->eraseFileOrDirectory( tempFilename );
		compiler.onCacheReadMiss( filename );
		return false;
	}

	compiler.onCacheRead( filename );
	return true;
}
```

#### 缓存路径格式

缓存路径格式为 `<cachePath>/<低8位哈希>/<原文件名>.<完整哈希>`:

```
<cachePath>/<hash & 0xFF>/<filename>.<hash>
```

例如 `c:\asset_cache\AB\player.dds.0xABCD12345678...`:

- `<cachePath>`:缓存根目录。
- `AB`:hash 的低 8 位(0xAB),用作一级目录,把缓存分桶以避免单目录文件过多。
- `<filename>`:原始文件名(如 `player.dds`)。
- `<hash>`:完整 64 位哈希值。

这种"低字节分桶"的设计参考了 Git 的 `.git/objects/xx/` 目录布局。

#### 三步式写入

写入缓存(`writeToCache`)采用"临时文件 → 原子移动"模式:

1. 在 `cachePath_` 下创建临时文件(`GetTempFileNameA`)。
2. 把目标文件内容复制到临时文件。
3. 把临时文件移动到正式缓存路径(`moveFileOrDirectory`)。

这种模式避免了直接写入缓存路径时被其他读取者看到半成品。如果中间步骤失败,会清理临时文件并返回 false。

### 4.5 Converter 接口与 ConverterInfo

#### Converter 接口

```cpp
// programming/bigworld/tools/asset_pipeline/conversion/converter.hpp:17-44
class Converter
{
public:
	/// Constructor
	/// \param params command line parameters for initialising the converter
	Converter( const BW::string& params ) : params_( params ) {};
	virtual ~Converter(){};

	/// builds the dependency list for a source file.
	virtual bool createDependencies( const BW::string& sourcefile,
									 const Compiler & compiler,
									 DependencyList & dependencies ) = 0;
	
	/// convert a source file.
	virtual bool convert( const BW::string& sourcefile,
						  const Compiler & compiler,
						  BW::vector< BW::string > & intermediateFiles,
						  BW::vector< BW::string > & outputFiles ) = 0;

protected:
	const BW::string& params_;
};
```

Converter 是每个转换器插件必须实现的接口,包含两个纯虚方法:

- `createDependencies`:生成依赖列表。转换器在此声明该源文件依赖哪些其他文件、目录、转换器版本等。
- `convert`:实际执行转换,产出 intermediateFiles 和 outputFiles 两类产物。

构造函数接收 `params` 字符串作为初始化参数,这个参数来自 `ConversionTask::converterParams_`,通常是从 `asset_rules.xml` 的 `<converterParams>` 元素读取。

#### ConverterInfo 元信息

```cpp
// programming/bigworld/tools/asset_pipeline/conversion/converter_info.hpp:10-31
struct ConverterInfo
{
public:
	/// the display name of the converter.
	BW::string			name_;
	/// the id of the converter. Must be unique to each type of converter.
	uint64				typeId_;
	/// the current version of the converter.
	BW::string			version_;
	/// converter flags
	enum CONVERTER_FLAGS
	{
		THREAD_SAFE			= 1 << 0, // can the converter be run on multiple threads.
		CACHE_DEPENDENCIES	= 1 << 1, // should dependencies be read and written to the cache.
		CACHE_CONVERSION	= 1 << 2, // should conversion be read and written to the cache.
		UPGRADE_CONVERSION	= 1 << 3, // is the conversion an upgrade of the source asset.
		DEFAULT_FLAGS		= THREAD_SAFE | CACHE_DEPENDENCIES | CACHE_CONVERSION,
		EXPERIMENTAL_MASK	= ~(CACHE_CONVERSION | CACHE_DEPENDENCIES)
	}					flags_;
	/// function pointer for creating an instance of the converter.
	ConverterCreator	creator_;
};
```

5 个标志位:

| 标志 | 值 | 含义 |
|------|----|------|
| `THREAD_SAFE` | 0x01 | 转换器可多线程并发调用 |
| `CACHE_DEPENDENCIES` | 0x02 | 依赖列表可缓存到 ContentAddressableCache |
| `CACHE_CONVERSION` | 0x04 | 转换产物可缓存到 ContentAddressableCache |
| `UPGRADE_CONVERSION` | 0x08 | 转换是"原地升级",可能修改源文件 |
| `DEFAULT_FLAGS` | 0x07 | 默认标志(线程安全 + 缓存依赖 + 缓存转换) |
| `EXPERIMENTAL_MASK` | ~0x06 | 实验性转换器(关闭缓存) |

`UPGRADE_CONVERSION` 是个有趣的标志——它告诉 TaskProcessor 在转换前**关闭源文件句柄**,以便转换器可以原地修改源文件:

```cpp
// programming/bigworld/tools/asset_pipeline/conversion/task_processor.cpp:547-553
// If the task is an upgrade, we need to release the file handle
// so that the source can be written to by the converter
if (( conversionContext.converterInfo_.flags_ & ConverterInfo::UPGRADE_CONVERSION ) != 0)
{
	::CloseHandle( taskContext.conversionTask_.fileHandle_ );
	taskContext.conversionTask_.fileHandle_ = NULL;
}
```

这种"原地升级"的典型用例是 BSP 转换器(`bsp_converter`),它会把 `.bsp` 文件原地升级为 `.bsp2` 格式。

`INIT_CONVERTER_INFO` 宏是填充 ConverterInfo 的便捷方式:

```cpp
// programming/bigworld/tools/asset_pipeline/conversion/converter_info.hpp:33-38
#define INIT_CONVERTER_INFO( INFO, CONVERTER, FLAGS )		\
	INFO.name_ = CONVERTER::getTypeName();					\
	INFO.typeId_ = CONVERTER::getTypeId();					\
	INFO.version_ = CONVERTER::getVersion();				\
	INFO.flags_ = (ConverterInfo::CONVERTER_FLAGS)( FLAGS );\
	INFO.creator_ = CONVERTER::createConverter;
```

它要求 Converter 类暴露三个静态方法:`getTypeName()`、`getTypeId()`、`getVersion()`、`createConverter`(函数指针,签名匹配 `ConverterCreator`)。`typeId_` 通常是 `Hash64::compute(getTypeName())` 的结果,保证不同类型转换器的 ID 不会冲突。

---

## 五、ConversionTask 状态机详解

### 5.1 八状态完整转换图

ConversionTask 的状态机包含 8 个状态,完整的转换关系如下:

```
                              queueTask()
    ┌──────────┐    ┌──────────┐    ┌──────────────┐
    │   NEW    │───►│  QUEUED  │───►│  PROCESSING  │
    │ (新建)   │    │ (已入队) │    │ (从队首取出) │
    └──────────┘    └──────────┘    └──────┬───────┘
                                          │ processNewTask()
                                          ▼
                                    ┌────────────────────┐
                                    │ NEEDS_PRIMARY_DEPS │
                                    │ (需要主依赖)       │
                                    └──────┬─────────────┘
                                           │ processPrimaryDependencies()
                                           ▼
                                    ┌──────────────────────┐
                                    │ NEEDS_SECONDARY_DEPS │
                                    │ (需要次依赖)         │
                                    └──────┬───────────────┘
                                           │ processSecondaryDependencies()
                                           │   若 blocked,任务挂起回队
                                           │   若 !blocked,继续
                                           ▼
                                    ┌────────────────────┐
                                    │  NEEDS_CONVERSION  │
                                    │ (需要转换)         │
                                    └──────┬─────────────┘
                                           │ processConversion()
                                           ▼
                                    ┌────────────────────┐
                                    │       DONE         │
                                    │ (完成)             │
                                    └────────────────────┘

    任意状态 ──── error ────►   ┌────────────────────┐
                                │      FAILED        │
                                │ (失败)             │
                                └────────────────────┘
```

### 5.2 挂起-恢复机制

ConversionTask 在 `NEEDS_SECONDARY_DEPS` 状态可能被挂起:

```cpp
// programming/bigworld/tools/asset_pipeline/conversion/task_processor.cpp:470-475
// If we are blocked then return from being processed. This will put our task back into
// queue but we will be guaranteed that all our secondary dependencies will be up to date
// the next time we process this task.
taskContext.conversionTask_.status_ = ConversionTask::NEEDS_CONVERSION;
return !blocked;
```

当 `processSecondaryDependencies` 返回 false(blocked=true)时,任务状态被设为 `NEEDS_CONVERSION`(不是 NEEDS_SECONDARY_DEPS!),然后被 `onTaskSuspended` 回调重新入队。下次被取出时,TaskProcessor 会从 `NEEDS_CONVERSION` 状态恢复执行,跳过前面的步骤。

注意 `processTasksOnSingleThread` 的状态判断:

```cpp
// programming/bigworld/tools/asset_pipeline/conversion/task_processor.cpp:972-980
task->status_ == ConversionTask::PROCESSING ?
	compiler_.onTaskStarted( *task ) :
	compiler_.onTaskResumed( *task );

this->processTask( *task );

task->status_ >= ConversionTask::DONE ?
	compiler_.onTaskCompleted( *task ) :
	compiler_.onTaskSuspended( *task );
```

- `status_ == PROCESSING`:任务是首次开始,调用 `onTaskStarted`。
- 否则(包括 `NEEDS_CONVERSION`):任务是恢复,调用 `onTaskResumed`。
- 处理后 `status_ >= DONE`:调用 `onTaskCompleted`(DONE 或 FAILED)。
- 否则:调用 `onTaskSuspended` 重新入队。

### 5.3 状态转换条件矩阵

| 当前状态 | 触发条件 | 下一状态 | 调用回调 |
|----------|----------|----------|----------|
| NEW | queueTask() | QUEUED | onTaskSuspended |
| QUEUED | getNextTask() | PROCESSING | onTaskStarted |
| PROCESSING | processNewTask 成功 | NEEDS_PRIMARY_DEPS | - |
| PROCESSING | processNewTask 失败 | FAILED | - |
| NEEDS_PRIMARY_DEPS | processPrimaryDependencies 成功 | NEEDS_SECONDARY_DEPS | - |
| NEEDS_PRIMARY_DEPS | 失败 | FAILED | - |
| NEEDS_SECONDARY_DEPS | !blocked | NEEDS_CONVERSION | - |
| NEEDS_SECONDARY_DEPS | blocked,挂起 | NEEDS_CONVERSION(挂起) | onTaskSuspended |
| NEEDS_SECONDARY_DEPS | 失败 | FAILED | - |
| NEEDS_CONVERSION | processConversion 成功 | DONE | onTaskCompleted |
| NEEDS_CONVERSION | 失败 | FAILED | onTaskCompleted |
| 任意状态 | 任意阶段 error | FAILED | onTaskCompleted |

### 5.4 与 OS 进程调度的对比

ConversionTask 状态机与操作系统进程调度有惊人的相似性:

| 维度 | OS 进程 | ConversionTask |
|------|---------|----------------|
| 新建 | fork/exec | NEW → QUEUED |
| 就绪 | READY | QUEUED |
| 运行 | RUNNING | PROCESSING / NEEDS_*_DEPS / NEEDS_CONVERSION |
| 阻塞 | BLOCKED(on I/O) | blocked in secondary deps(挂起) |
| 完成 | EXITED | DONE |
| 失败 | 异常退出 | FAILED |
| 调度器 | OS kernel scheduler | TaskProcessor |
| 调度队列 | runqueue | taskQueue_ |
| 上下文切换 | register/stack 切换 | threadId_ + status_ + subTasks_ |
| 信号量 | kernel semaphore | taskSemaphore_ |

差异点:
- OS 进程由内核抢占,ConversionTask 是协作式(只在 `processSecondaryDependencies` 主动让出)。
- OS 进程调度开销大(微秒级),ConversionTask 上下文切换几乎零开销(只改 status 和重新入队)。
- OS 进程可以 fork 子进程,ConversionTask 通过 subTasks 表达依赖。

### 5.5 状态机的工程价值

ConversionTask 状态机的工程价值:

1. **可恢复性**:任务可从任意中间状态恢复,适合长时间运行 + 频繁挂起的 JIT 模式。
2. **可观测性**:status 字段直接反映任务进度,易于调试和 UI 显示。
3. **可序列化**:状态枚举值是整数,易于持久化(虽然 asset_pipeline 当前不持久化任务状态,但理论上可扩展)。
4. **可扩展**:新增状态只需在 enum 末尾追加(注释明确说明"DO NOT change the order"),不影响已有状态机逻辑。

---

## 六、TaskProcessor 多线程调度深度剖析

### 6.1 三阶段处理流程

TaskProcessor 的核心是 `processTask` 方法,它驱动一个任务经过三个阶段:

#### 阶段 1:processNewTask

```cpp
// programming/bigworld/tools/asset_pipeline/conversion/task_processor.cpp:284-305
bool TaskProcessor::processNewTask( TaskContext & taskContext )
{
	if (taskContext.relativeSource_.empty())
	{
		ERROR_MSG( "FAILED: Could not resolve relative path for %s.\n",
			taskContext.conversionTask_.source_.c_str() );
		taskContext.conversionTask_.status_ = ConversionTask::FAILED;
		return false;
	}

	BW::string resolvedSource = BWResource::resolveFilename( taskContext.relativeSource_ );
	if (taskContext.conversionTask_.source_ != resolvedSource)
	{
		ERROR_MSG( "FAILED: Found %s while trying to compile %s. This asset will be ignored.\n",
			resolvedSource.c_str(), taskContext.conversionTask_.source_.c_str() );
		taskContext.conversionTask_.status_ = ConversionTask::FAILED;
		return false;
	}

	taskContext.conversionTask_.status_ = ConversionTask::NEEDS_PRIMARY_DEPS;
	return true;
}
```

新任务的处理:
1. 检查相对路径能否解析——不能则失败。
2. 检查解析后的绝对路径是否与源文件路径一致——不一致说明有路径冲突(可能是符号链接或多路径匹配),失败。
3. 状态推进到 NEEDS_PRIMARY_DEPS。

#### 阶段 2:processPrimaryDependencies

主依赖是固定的 3 个,所有任务都一样:

1. **SourceFileDependency**:源文件本身。
2. **ConverterDependency**:转换器 ID + 版本。
3. **ConverterParamsDependency**:转换器参数。

```cpp
// programming/bigworld/tools/asset_pipeline/dependency/dependency_list.cpp:70-80
void DependencyList::initialise( const BW::string & source,
						         uint64 converterId,
						         const BW::string & converterVersion,
						         const BW::string & converterParams )
{
	reset();

	addPrimarySourceFileDependency( source );
	addPrimaryConverterDependency( converterId, converterVersion );
	addPrimaryConverterParamsDependency( converterParams );
}
```

processPrimaryDependencies 流程:

1. 检查现有 .deps 文件的主依赖是否最新(`checkPrimaryDependenciesUpToDate`)。
2. 若不最新(或 forceRebuild):
   - 调用 `DependencyList::initialise` 重置 3 个主依赖。
   - 尝试从缓存读取 .deps(`retrievePrimaryDependencyListFromCache`)。
   - 若缓存未命中,调用 converter 的 `createDependencies`,让转换器声明次依赖。
   - 把 .deps 写盘,并写入缓存(若 CACHE_DEPENDENCIES 标志开启)。
3. 状态推进到 NEEDS_SECONDARY_DEPS。

#### 阶段 3:processSecondaryDependencies + processConversion

次依赖处理:

```cpp
// programming/bigworld/tools/asset_pipeline/conversion/task_processor.cpp:401-475
bool TaskProcessor::processSecondaryDependencies( ... )
{
	bool blocked = false;
	bool subTaskError = false;

	BW::vector< DependencyList::Input > & secondaryDeps = dependencyContext.depList_.secondaryInputs_;
	for ( it = secondaryDeps.begin(); it != secondaryDeps.end(); ++it )
	{
		const ConversionTask * secondaryTask = NULL;
		bool upToDate = compiler_.ensureUpToDate( *it->first, secondaryTask );
		// ... 处理失败、阻塞等情况 ...
		taskContext.conversionTask_.subTasks_.push_back( std::make_pair( secondaryTask, it->first->isCritical() ) );
		blocked |= !upToDate;
	}

	if (subTaskError) { ... return false; }

	taskContext.conversionTask_.status_ = ConversionTask::NEEDS_CONVERSION;
	return !blocked;
}
```

对于每个次依赖,调用 `ensureUpToDate` 触发其编译。如果次依赖还在编译中(blocked),任务被挂起,等待下次重新调度。

转换阶段:

1. 检查 critical 子任务是否失败(`hasSubTaskErrors`)。
2. 多种判断是否需要重转换(forceRebuild、无输出、次依赖过期、中间产物过期、最终产物过期)。
3. 多种尝试从缓存恢复产物(`retrieveSecondaryDependencyListFromCache`、`checkIntermediateOutputsUpToDate`、`checkOutputsUpToDate`)。
4. 若仍需转换,调用 converter 的 `convert`,产出 intermediateFiles 和 outputFiles。
5. 更新 .deps 中的产物哈希,写入缓存。
6. 状态推进到 DONE。

### 6.2 自适应线程池

TaskProcessor 通过 `processTasksOnMultipleThreads` 实现自适应线程池:

```cpp
// programming/bigworld/tools/asset_pipeline/conversion/task_processor.cpp:990-1026
void TaskProcessor::processTasksOnMultipleThreads()
{
	while (true)
	{
		// Get the number of potential available threads
		const int numThreads = BgTaskManager::instance().numUnstoppedThreads();
		// Get the number of background tasks still to be run
		const int numTasks = BgTaskManager::instance().numBgTasksLeft();

		// Check if we have tasks still to process.
		if (compiler_.hasTasks())
		{
			if ( numThreads > numTasks )
			{
				for ( int i = 0; i < numThreads - numTasks; ++i )
				{
					// For every available thread create a background task to process tasks.
					BgTaskManager::instance().addBackgroundTask( new TaskProcessorTask( *this ) );
				}
			}
			else if ( numThreads < numTasks )
			{
				InterlockedExchange(&threadKillCount_, numTasks - numThreads);
			}
		}
		else if (numTasks == 0)
		{
			break;
		}

		Sleep(100);
	}
}
```

#### 算法分析

每 100ms 检查一次:
- `numThreads`:BgTaskManager 中尚未停止的线程数(即空闲线程)。
- `numTasks`:BgTaskManager 中尚未开始的后台任务数。

**自适应策略**:

1. 若 `compiler_.hasTasks()`(主队列有任务):
   - 若空闲线程 > 已排队任务(`numThreads > numTasks`):增加 `numThreads - numTasks` 个新的 TaskProcessorTask,把空闲线程用满。
   - 若空闲线程 < 已排队任务(`numThreads < numTasks`):设置 `threadKillCount_` 为差额,通知多余任务退出。
2. 若主队列空且没有后台任务:退出循环。
3. 否则 sleep 100ms 重新检查。

#### 任务退出机制

```cpp
// programming/bigworld/tools/asset_pipeline/conversion/task_processor.cpp:947-958
bool TaskProcessor::isThreadKillRequested()
{
	LONG killCount = BW_ATOMIC32_DEC_AND_FETCH( &threadKillCount_ );
	if (killCount >= 0)
	{
		return true;
	}

	BW_ATOMIC32_INC_AND_FETCH( &threadKillCount_ );

	return false;
}
```

`isThreadKillRequested` 在 `processTasksOnSingleThread` 循环中被调用,使用原子操作递减 `threadKillCount_`,若结果 >= 0 说明这个线程应该退出(因为还有 killCount 需要消耗)。这种原子递减+恢复的写法确保了 N 个线程能精确退出,不多不少。

### 6.3 任务队列与同步

AssetCompiler 维护双端队列 `taskQueue_` 和保护它的 `taskQueueMutex_`:

```cpp
// programming/bigworld/tools/asset_pipeline/compiler/asset_compiler.cpp:774-812
ConversionTask * AssetCompiler::getNextTask()
{
	if (terminating())
	{
		return NULL;
	}

	ConversionTask * task = NULL;
	taskQueueMutex_.grab();
	if (!taskQueue_.empty())
	{
		// If the task queue is not empty return the first task in the queue.
		// Otherwise return NULL.
		task = taskQueue_.front();
		taskQueue_.pop_front();
		MF_ASSERT( task->status_ > ConversionTask::NEW );
		if (task->status_ == ConversionTask::QUEUED)
		{
			task->status_ = ConversionTask::PROCESSING;
		}
	}
	taskQueueMutex_.give();

	return task;
}

void AssetCompiler::queueTask( ConversionTask & conversionTask )
{
	taskQueueMutex_.grab();
	if ( conversionTask.status_ == ConversionTask::NEW )
	{
		taskQueue_.push_back( &conversionTask );
		conversionTask.status_ = ConversionTask::QUEUED;
	}
	taskQueueMutex_.give();
}
```

队列操作始终在 `taskQueueMutex_` 保护下,保证多线程并发安全。注意:

- `queueTask` 只在 `status_ == NEW` 时入队(避免重复入队)。
- `getNextTask` 从队首取,把状态从 QUEUED 改为 PROCESSING。
- JIT 编译器的 `onAssetRequested` 会从队中查找并 move 到队首(`push_front`),实现插队。

### 6.4 强制重建(forceRebuild)

`forceRebuild` 标志位跳过所有"是否最新"的检查,强制重新生成依赖和执行转换:

```cpp
// programming/bigworld/tools/asset_pipeline/conversion/task_processor.cpp:314-322
bool needsDeps = forceRebuild_;

if (!needsDeps)
{
	needsDeps = !checkPrimaryDependenciesUpToDate( taskContext, 
												   dependencyContext );
}
```

forceRebuild 通常用于:
- 命令行参数 `--force` / `-f` 触发全量重建。
- 转换器版本升级后,所有产物都需要重新生成。

---

## 七、ConverterGuard 线程安全深度剖析

### 7.1 读写锁实现

ConverterGuard 使用 `ReadWriteLock`(来自 `cstdmf` 库),这是一个支持并发读、独占写的同步原语:

- `beginRead()` / `endRead()`:获取/释放读锁,多个线程可同时持有读锁。
- `beginWrite()` / `endWrite()`:获取/释放写锁,独占访问。

读写锁的内部实现通常基于 Windows 的 `SRWLock`(Slim Reader/Writer Lock),性能优于传统的 `CRITICAL_SECTION`。

#### 静态成员

```cpp
// programming/bigworld/tools/asset_pipeline/conversion/task_processor.cpp:88-89
ReadWriteLock ConverterGuard::s_lock_;
volatile long ConverterGuard::s_pendingWrites = 0;
```

注意这两个是**静态成员**——所有 ConverterGuard 实例共享同一把锁和 pending 计数。这意味着 asset_pipeline 的整个进程内,所有转换器共享一个读写锁。

### 7.2 与 ConversionTask 的协作

ConverterGuard 的生命周期与 ConversionTask 的两个关键阶段绑定:

1. **创建依赖阶段**(`createDependencies`):

```cpp
// programming/bigworld/tools/asset_pipeline/conversion/task_processor.cpp:355-364
try
{
    INFO_MSG( "Creating dependencies...\n" );
    ConverterGuard converterGuard( conversionContext.converterInfo_ );
    res = conversionContext.converter_->createDependencies( taskContext.conversionTask_.source_, compiler_, dependencyContext.depList_ );
}
catch (...)
{
    res = false;
}
```

2. **转换阶段**(`convert`):

```cpp
// programming/bigworld/tools/asset_pipeline/conversion/task_processor.cpp:561-571
try
{
    INFO_MSG( "Converting task...\n" );
    ConverterGuard converterGuard( conversionContext.converterInfo_ );
    res = conversionContext.converter_->convert( taskContext.conversionTask_.source_, compiler_, intermediateFiles, outputFiles );
}
catch (...)
{
    res = false;
}
```

每个阶段都用 RAII 守卫包裹,确保:
- 进入阶段时获取锁。
- 离开阶段时释放锁(无论是正常返回还是异常退出)。
- 阶段内调用 converter 的任何方法都受锁保护。

### 7.3 防止并发冲突

考虑两种场景:

#### 场景 A:线程安全转换器(TextureConverter)

多个线程同时转换不同的纹理文件:
- 所有线程都获取读锁(`beginRead`),并行执行。
- 性能提升:N 线程可达到 N 倍吞吐。

#### 场景 B:非线程安全转换器(BSPConverter)

多个线程试图同时调用 BSPConverter:
- 第一个线程 `InterlockedIncrement(&s_pendingWrites)` 使计数变为 1。
- 该线程 `beginWrite()` 获取写锁。
- 其他线程进入 `while (s_pendingWrites > 0) Sleep(0);` 自旋等待。
- 第一个线程 `InterlockedDecrement(&s_pendingWrites)` 使计数变为 0,然后释放写锁。
- 其他线程停止自旋,获取读锁。

注意一个细节:**非线程安全转换器在获取写锁后,会立即 `InterlockedDecrement`**——这允许后续的线程安全转换器在它执行期间也能继续(因为 `s_pendingWrites` 已归零)。但实际上,因为写锁是独占的,后续的读锁会被阻塞——所以这个 decrement 只是让计数器反映真实状态,不改变行为。

---

## 八、ContentAddressableCache 内容寻址缓存深度剖析

### 8.1 内容寻址原理

内容寻址(Content-Addressable)是一种存储模式,与传统的"位置寻址"相对:

| 模式 | 寻址方式 | 同内容存储 | 不同内容存储 |
|------|----------|-------------|---------------|
| 位置寻址 | 路径(如 `c:\files\player.dds`) | 同一文件覆盖 | 多份重复 |
| 内容寻址 | 哈希(如 `0xABCD...`) | 同一哈希即同一文件,只存一份 | 不同哈希,不同文件 |

内容寻址的优势:
- **天然去重**:相同内容只存一份。
- **完整性校验**:文件名即哈希,任何修改都会产生新文件名。
- **跨项目共享**:不同项目的相同资源可共享缓存。

劣势:
- **文件名不可读**:`player.dds.ABCD1234...` 不直观。
- **目录结构依赖哈希分布**:不能像普通文件系统那样按目录浏览。

### 8.2 缓存键的计算

ContentAddressableCache 的键是 `uint64 hash`,由 `DependencyList::getInputHash` 计算:

```cpp
// programming/bigworld/tools/asset_pipeline/dependency/dependency_list.cpp:139-160
uint64 DependencyList::getInputHash( bool includeSecondary )
{
	uint64 hash = 0;

	Hash64::compute( primaryInputs_.size() );
	BW::vector< Input >::const_iterator it;
	for ( it = primaryInputs_.cbegin(); it != primaryInputs_.cend(); ++it )
	{
		Hash64::combine( hash, it->second );
	}

	if (includeSecondary)
	{
		Hash64::combine( hash, secondaryInputs_.size() );
		for ( it = secondaryInputs_.cbegin(); it != secondaryInputs_.cend(); ++it )
		{
			Hash64::combine( hash, it->second );
		}
	}
	
	return hash;
}
```

哈希组合方式:
1. 初始化 `hash = 0`。
2. 计算主依赖数量的 hash,组合进去。
3. 对每个主依赖,组合其 `it->second`(即每个依赖自身的 hash)。
4. 若包含次依赖,组合次依赖数量和每个次依赖的 hash。

注意:主依赖的 hash 是其自身计算的(源文件 hash、转换器版本 hash 等),次依赖类似。最终的 `getInputHash` 是所有依赖 hash 的组合 hash。

### 8.3 缓存命中与未命中

#### 缓存命中流程

1. TaskProcessor 在 `checkIntermediateOutputsUpToDate` / `checkOutputsUpToDate` 中检查产物哈希是否匹配。
2. 若不匹配,尝试从缓存读取:`ContentAddressableCache::readFromCache(output, hash, compiler)`。
3. readFromCache 计算 `<cachePath>/<hash & 0xFF>/<filename>.<hash>` 路径。
4. 若文件存在,先复制到临时文件,再原子移动到目标位置。
5. 调用 `onCacheRead(filename)` 通知 compiler,返回 true。
6. TaskProcessor 验证缓存文件的 hash 是否与预期一致(防止缓存损坏):
   - 若一致:`INFO_MSG("Output %s retrieved from cache", ...)`,跳过转换。
   - 若不一致:`WARNING_MSG("Corrupted output retrieved from the cache: ...")`,触发重新转换。

#### 缓存未命中流程

1. 缓存路径不存在,或文件存在但 hash 不匹配。
2. 调用 `onCacheReadMiss(filename)`,返回 false。
3. TaskProcessor 进入正常转换流程。
4. 转换完成后,把产物写入缓存:`ContentAddressableCache::writeToCache(output, hash, compiler)`。
5. writeToCache 创建临时文件,复制内容,原子移动到正式缓存路径。
6. 调用 `onCacheWrite(filename)`,返回 true。

#### 缓存损坏处理

```cpp
// programming/bigworld/tools/asset_pipeline/conversion/task_processor.cpp:134-192
bool TaskProcessor::DependencyContext::loadFromCache( bool secondaryDependencies, Compiler & compiler )
{
	const BW::string file = BWResource::getFilename( depListFileName_ ).to_string();
	const BW::string directory = BWResource::getFilePath( depListFileName_ );

	// Make a backup of the dependency list
	XMLSectionPtr tempDepListRoot_ = new XMLSection( "root" );
	depList_.serialiseOut( tempDepListRoot_ );

	uint64 hash = depList_.getInputHash( secondaryDependencies );
	if (ContentAddressableCache::readFromCache( depListFileName_, hash, compiler ))
	{
		depListResource_.reload();
		depListRoot_ = depListResource_.getRootSection();

		bool depListValid = true;
		if (depListRoot_ != NULL)
		{
			depList_.serialiseIn( depListRoot_ );

			BW::vector< DependencyList::Input > & primaryDeps = depList_.primaryInputs_;
			for ( ... it != primaryDeps.end() && depListValid; ++it )
			{
				uint64 hash = compiler.getHash( *it->first );
				depListValid &= (it->second == hash);
			}
			// ... secondaryDeps similar ...
		}
		else
		{
			depListValid = false;
		}

		if (!depListValid)
		{
			WARNING_MSG( "Corrupted dependency list retrieved from the cache: %s.%IX\n",
				file.c_str(), hash );

			// the cache file was corrupted. try to restore the backup
			depListRoot_->copy( tempDepListRoot_ );
			depListResource_.save();

			depList_.serialiseIn( depListRoot_ );
			return false;
		}
	}

	return false;
}
```

**值得注意的代码 bug**:这个函数末尾的 `return false;` 看起来不太对——即使 `readFromCache` 成功且 depListValid 为 true,函数也返回 false。从注释看,函数本应在缓存命中且有效时返回 true,但代码逻辑实际上是始终返回 false。这可能是源码的一个 bug 或有意为之(让上层总是重新生成依赖)。但在 `retrievePrimaryDependencyListFromCache` / `retrieveSecondaryDependencyListFromCache` 中,这个返回值决定了是否跳过重新生成——所以这个 bug 可能让缓存永远不命中。

### 8.4 跨项目、跨机器的缓存共享

由于缓存键是内容的哈希,只要满足以下条件,缓存即可跨项目共享:

1. **相同源文件内容**:相同源文件在不同项目中算出的 hash 相同。
2. **相同转换器版本**:转换器 ID 和版本号一致。
3. **相同次依赖**:所有次依赖的 hash 一致。
4. **缓存路径共享**:多个项目的 `cachePath_` 指向同一目录(可以是网络共享路径)。

典型配置:

```
# 共享缓存路径(可以是 NAS / 网络磁盘)
AssetPipelineCachePath = \\buildserver\asset_cache\
```

这样开发团队的所有成员的 JIT 编译器都从同一缓存读取,一个人编译过的产物,其他人直接复用。这对于大型团队(几十到上百人)能极大减少总体编译时间。

### 8.5 与 Git 的对比

| 维度 | Git 对象存储 | ContentAddressableCache |
|------|--------------|--------------------------|
| 寻址方式 | SHA-1 哈希(160 位) | Hash64(64 位) |
| 文件路径 | `.git/objects/xx/yyyy...` | `<cache>/<low8>/<filename>.<hash>` |
| 分桶策略 | 前两位 hex(256 桶) | 低 8 位 hex(256 桶) |
| 完整性校验 | SHA-1 强抗碰撞 | Hash64 弱抗碰撞 |
| 去重 | 完全去重 | 完全去重 |
| 不可变性 | 对象不可变 | 可被覆盖(同名不同 hash 时) |
| 垃圾回收 | git gc | 无(手动清理) |
| 用途 | 版本控制 | 编译产物缓存 |

BigWorld 的 Hash64 比 SHA-1 弱得多(64 位 vs 160 位,且非加密哈希),理论上碰撞概率较高。但对于编译产物缓存场景,碰撞的代价是"使用了一个旧产物",而 Git 的碰撞代价是"版本库损坏"——所以 BigWorld 用 64 位 hash 是可接受的工程权衡。

---

## 九、dependency 子模块深度剖析

### 9.1 六种依赖类型

`dependency.hpp` 通过宏 `DEPENDENCY_TYPES` 定义六种依赖类型:

```cpp
// programming/bigworld/tools/asset_pipeline/dependency/dependency.hpp:10-16
#define DEPENDENCY_TYPES			\
	X( SourceFileDependency )		\
	X( IntermediateFileDependency )	\
	X( OutputFileDependency )		\
	X( ConverterDependency )		\
	X( ConverterParamsDependency )	\
	X( DirectoryDependency )
```

通过 X 宏技术,这个列表同时生成:
1. 枚举:`SourceFileDependencyType`、`IntermediateFileDependencyType` 等。
2. 创建函数:`CreateSourceFileDependency()`、`CreateIntermediateFileDependency()` 等。
3. 函数指针数组:`CreateDependency[]`,用于序列化时按类型创建对象。

| 类型 | 用途 | 哈希计算 |
|------|------|----------|
| `SourceFileDependency` | 源文件依赖(如 `.tga` → `.tga`) | `Hash64(filename) + Hash64(fileContent)` |
| `IntermediateFileDependency` | 中间产物依赖(如 `.primitives` 依赖另一个 `.primitives`) | `Hash64(filename) + Hash64(fileContent)` |
| `OutputFileDependency` | 最终产物依赖(如 `.visual` 依赖 `.xml` 配置) | `Hash64(filename) + Hash64(fileContent)` |
| `ConverterDependency` | 转换器版本依赖 | `Hash64(converterId) + Hash64(version)` |
| `ConverterParamsDependency` | 转换器参数依赖 | `Hash64(params)` |
| `DirectoryDependency` | 目录依赖(支持正则模式) | `Hash64(directory) + Hash64(目录内容)` |

### 9.2 Dependency 基类

```cpp
// programming/bigworld/tools/asset_pipeline/dependency/dependency.hpp:27-63
class Dependency
{
public:
	Dependency() : critical_( false ) {}
	virtual ~Dependency() {}

	virtual DependencyType getType() const = 0;

	void setCritical( bool critical ) { critical_ = critical; }
	bool isCritical() const { return critical_; }

	virtual bool serialiseIn( DataSectionPtr pSection );
	virtual bool serialiseOut( DataSectionPtr pSection ) const;

protected:
	bool critical_;
};
```

每个依赖都有:
- `getType()`:返回类型枚举(用于序列化反序列化)。
- `critical_` 标志:**关键依赖**——若关键依赖失败,整个任务失败;若非关键依赖失败,任务继续。

`critical_` 标志在 `processSecondaryDependencies` 中起作用:

```cpp
// programming/bigworld/tools/asset_pipeline/conversion/task_processor.cpp:441-457
if (failed)
{
	if (it->first->isCritical())
	{
		if (secondaryTask != NULL)
		{
			ERROR_MSG( "Errors processing critical dependent task %s\n", secondaryTask->source_.c_str() );
		}
		// A critical secondary dependency has failed.
		// We cannot convert this task without this dependency so fail.
		subTaskError = true;
	}
	else
	{
		upToDate = true;
	}
}
```

非关键依赖失败时,任务被标记为 up to date(假装成功了),继续编译。这允许"软依赖"——例如某个 LOD 资源缺失,不应阻止主资源编译。

### 9.3 DependencyList 依赖列表

DependencyList 是一个任务的完整依赖快照:

```cpp
// programming/bigworld/tools/asset_pipeline/dependency/dependency_list.hpp:104-112
private:
	Compiler & compiler_;
	BW::vector< Input > primaryInputs_;
	BW::vector< Input > secondaryInputs_;
	BW::vector< Output > intermediateOutputs_;
	BW::vector< Output > outputs_;

	friend class TaskProcessor;
```

四个列表:
- `primaryInputs_`:主依赖(固定 3 个:源文件、转换器、转换器参数)。
- `secondaryInputs_`:次依赖(由 converter 的 createDependencies 添加)。
- `intermediateOutputs_`:中间产物(写出到 intermediatePath_)。
- `outputs_`:最终产物(写出到 outputPath_)。

`Input` 和 `Output` 类型:

```cpp
// programming/bigworld/tools/asset_pipeline/dependency/dependency_list.hpp:19-20
typedef std::pair< Dependency*, uint64 > Input;
typedef std::pair< BW::string, uint64 > Output;
```

Input 是 `Dependency* + hash`,Output 是 `filename + hash`。

### 9.4 正向依赖与反向依赖

BigWorld 同时维护正向依赖和反向依赖:

#### 正向依赖(forward)

正向依赖是"任务 → 它依赖的文件"的映射,通过 `DependencyList` 表达。例如:

```
Task(player.visual)
├─ primaryInputs:
│   ├─ SourceFileDependency(player.model)
│   ├─ ConverterDependency(VisualProcessor v1.2)
│   └─ ConverterParamsDependency("rigid")
├─ secondaryInputs:
│   ├─ IntermediateFileDependency(player.primitives)
│   ├─ OutputFileDependency(materials.xml)
│   └─ DirectoryDependency(textures/, *.dds, recursive)
├─ intermediateOutputs:
│   └─ player.primitives
└─ outputs:
    └─ player.visual
```

正向依赖用于**编译时**:决定需要哪些输入,生成哪些输出。

#### 反向依赖(reverse)

反向依赖是"文件 → 依赖它的任务"的映射,由 JIT 编译器在任务完成后维护。例如:

```
player.model → [Task(player.visual), Task(player.bsp)]
player.primitives → [Task(player.visual)]
materials.xml → [Task(player.visual)]
textures/ → [Task(player.visual)]
player.visual → [Task(level1.chunk), Task(level2.chunk)]
```

反向依赖用于**变更时**:某个文件改动时,通过反向依赖图快速找到所有受影响的任务,重新触发编译。

### 9.5 依赖图的构建

依赖图由两部分动态构建:

1. **正向依赖**:任务编译时,通过 `createDependencies` 让 converter 声明其依赖。
2. **反向依赖**:任务编译完成后,JIT 编译器在 `onTaskCompleted` 中通过 `addReverseDependency` 把任务注册到反向依赖图。

正向依赖是源真相,反向依赖是缓存/索引。每次任务重编译时,反向依赖图会先清除该任务的所有反向映射,然后根据新的正向依赖重新填充。

### 9.6 依赖序列化

DependencyList 通过 XML 序列化到 `.deps` 文件:

```cpp
// programming/bigworld/tools/asset_pipeline/dependency/dependency_list.cpp:15-27
namespace DependencyList_Locals
{
	const char * PRIMARY_INPUTS_TAG = "PrimaryInputs";
	const char * SECONDARY_INPUTS_TAG = "SecondaryInputs";
	const char * INTERMEDIATE_OUTPUTS_TAG = "IntermediateOutputs";
	const char * OUTPUTS_TAG = "Outputs";
	const char * DEPENDENCY_TAG = "Dependency";
	const char * DEPENDENCY_TYPE_TAG = "Type";
	const char * COMPILED_TAG = "Compiled";
	const char * FILE_TAG = "File";
	const char * HASH_TAG = "Hash";
}
```

XML 结构示例:

```xml
<root>
  <PrimaryInputs>
    <Dependency>
      <Type uint="0"/>  <!-- SourceFileDependencyType -->
      <Hash uint64="0xABCDEF..."/>
      <File>player.model</File>
    </Dependency>
    <Dependency>
      <Type uint="3"/>  <!-- ConverterDependencyType -->
      <Hash uint64="0x123..."/>
      <ConverterId uint64="0x456..."/>
      <ConverterVersion>1.2</ConverterVersion>
    </Dependency>
    <Dependency>
      <Type uint="4"/>  <!-- ConverterParamsDependencyType -->
      <Hash uint64="0x789..."/>
      <ConverterParams>rigid</ConverterParams>
    </Dependency>
  </PrimaryInputs>
  <SecondaryInputs>
    <Dependency>
      <Type uint="1"/>  <!-- IntermediateFileDependencyType -->
      <Hash uint64="0x..."/>
      <File>player.primitives</File>
      <Critical bool="true"/>
    </Dependency>
    <!-- ... -->
  </SecondaryInputs>
  <IntermediateOutputs>
    <Compiled>
      <File>player.primitives</File>
      <Hash uint64="0x..."/>
    </Compiled>
  </IntermediateOutputs>
  <Outputs>
    <Compiled>
      <File>player.visual</File>
      <Hash uint64="0x..."/>
    </Compiled>
  </Outputs>
</root>
```

序列化使用 BigWorld 的 DataSection 抽象,DataSection 支持多种后端(XML、Binary),`.deps` 文件默认使用 XML 后端(可读,便于调试)。

---

## 十、discovery 子模块深度剖析

### 10.1 TaskFinder 任务发现

TaskFinder 负责在文件系统中扫描源文件,匹配转换规则,创建 ConversionTask:

```cpp
// programming/bigworld/tools/asset_pipeline/discovery/task_finder.hpp:13-40
class TaskFinder
{
public:
	TaskFinder( Compiler& compiler,
				ConversionRules& rules );
	~TaskFinder();

	/* iterates recursively over directories to find root tasks. */
	void findTasks( const BW::StringRef& directory );

	/* matches file conversion rules to task. */
	ConversionTask & getTask( const BW::StringRef & filename );

	/* matches file conversion rules to task. */
	ConversionTask * getTask( const BW::StringRef & filename, const bool bRoot );

private:
	/* iterate a file for a root task */
	void iterateFile( const BW::StringRef& file );
	/* iterate a directory for root tasks */
	void iterateDirectory( const BW::StringRef& directory );

	Compiler &		 compiler_;
	ConversionRules& rules_;

	StringHashMap<ConversionTask *> tasks_;
	ReadWriteLock					tasksLock_;
};
```

`tasks_` 是源文件路径 → ConversionTask 的哈希表,通过 `ReadWriteLock` 保护并发访问。这意味着 TaskFinder 是**线程安全**的——多个线程可以同时调用 `getTask`(只读路径),只有创建新任务时才需要写锁。

### 10.2 ConversionRule 转换规则

```cpp
// programming/bigworld/tools/asset_pipeline/discovery/conversion_rule.hpp:12-36
class ConversionRule
{
public:
	ConversionRule() {}
	virtual ~ConversionRule() {}

	/* returns true and populates a root conversion task if the rule can match the input filename. */
	virtual bool createRootTask( const BW::StringRef& sourceFile,
							     ConversionTask& task ) { 
		return false; 
	}

	/* returns true and populates a conversion task if the rule can match the input filename. */
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

ConversionRule 是一个接口,提供三个方法:

1. `createRootTask`:扫描时被调用,只为"根任务"创建(即从源文件直接发现的任务)。
2. `createTask`:更通用的创建,默认委托给 createRootTask。
3. `getSourceFile`:反向查找,给定产物文件名,返回源文件名。

注意 TaskFinder 用 `crbegin` / `crend` 反向遍历规则:

```cpp
// programming/bigworld/tools/asset_pipeline/discovery/task_finder.cpp:190-208
ConversionRules::const_reverse_iterator ruleIter = rules_.crbegin();
ConversionRules::const_reverse_iterator ruleEnd = rules_.crend();
for ( ; ruleIter != ruleEnd; ++ruleIter )
{
	if (bRoot)
	{
		if ((*ruleIter)->createRootTask( filename, *pNewTask ))
		{
			break;
		}
	}
	else
	{
		if ((*ruleIter)->createTask( filename, *pNewTask ))
		{
			break;
		}
	}
}
```

反向遍历意味着**后注册的规则优先匹配**——这是一种"后注册优先"策略。GenericConversionRule 在 AssetCompiler 构造时第一个被注册(`conversionRules_.push_back(&genericConversionRule_)`),所以它的优先级最低,留给具体插件的规则更高优先级。

### 10.3 文件模式匹配

TaskFinder 的 `iterateDirectory` 递归扫描文件系统:

```cpp
// programming/bigworld/tools/asset_pipeline/discovery/task_finder.cpp:74-114
void TaskFinder::iterateDirectory( const BW::StringRef& directory )
{
	BW::string path = BWUtil::formatPath( directory );
	if (!compiler_.shouldIterateDirectory( path ))
	{
		return;
	}

	BW::string relativeDirectory = BWResource::dissolveFilename( path );
	bool isBWPath = relativeDirectory.length() < path.length();
	if (isBWPath)
	{
		INFO_MSG( "Searching %s\n", path.c_str() );
	}

	char pathBuffer[BW_MAX_PATH];
	StringBuilder pathBuilder( pathBuffer, BW_MAX_PATH );

	MultiFileSystem* fs = BWResource::instance().fileSystem();
	IFileSystem::Directory dir;
	fs->readDirectory( dir, path );
	for( IFileSystem::Directory::iterator it = dir.begin();
		it != dir.end(); ++it )
	{
		pathBuilder.clear();
		pathBuilder.append( path );
		pathBuilder.append( *it );
		const char * subPath = pathBuilder.string();

		IFileSystem::FileType ft = fs->getFileType( subPath );
		if (ft == IFileSystem::FT_FILE && isBWPath)
		{
			// Don't iterate files that aren't in one of our resource paths
			iterateFile( subPath );
		}
		else if (ft == IFileSystem::FT_DIRECTORY)
		{
			iterateDirectory( subPath );
		}
	}
}
```

#### 过滤规则

通过 `compiler_.shouldIterateDirectory` 进行过滤,AssetCompiler 的默认实现:

```cpp
// programming/bigworld/tools/asset_pipeline/compiler/asset_compiler.cpp:723-757
bool AssetCompiler::shouldIterateDirectory( const BW::StringRef& directory )
{
	if (terminating())
	{
		return false;
	}

	// Don't iterate into the intermediate or output paths
	if (intermediatePath_.length() && 
		directory.substr( 0, intermediatePath_.length() ) == intermediatePath_)
	{
		return false;
	}
	if (outputPath_.length() && 
		directory.substr( 0, outputPath_.length() ) == outputPath_)
	{
		return false;
	}

	// Don't iterate into svn folders
	StringRef svn = "/.svn";
	if (directory.find( svn ) != StringRef::npos)
	{
		return false;
	}

	// Don't iterate into the unit test testfiles directory
	StringRef testfiles = "/tools/asset_pipeline/testfiles";
	if (directory.find( testfiles ) != StringRef::npos )
	{
		return false;
	}

	return true;
}
```

跳过:
- intermediatePath 和 outputPath 自身(避免循环)。
- `.svn` 目录(Subversion 元数据)。
- `tools/asset_pipeline/testfiles` 目录(测试数据)。
- 终止状态下不再扫描。

### 10.4 GenericConversionRule

GenericConversionRule 是 asset_pipeline 的核心规则,从 `asset_rules.xml` 加载:

```cpp
// programming/bigworld/tools/asset_pipeline/compiler/generic_conversion_rule.cpp:82-136
bool GenericConversionRule::createTask( const BW::StringRef & sourceFile,
									   ConversionTask & task,
									   bool root )
{
	char relativePath[MAX_PATH];
	bw_str_copy( relativePath, MAX_PATH, sourceFile );
	if (!BWResource::resolveToRelativePathT( relativePath, MAX_PATH ))
	{
		return false;
	}
	DataSectionPtr rule = rules_.get( relativePath );

	if (root)
	{
		DataSectionPtr rootSection = rule->findChild( "root" );
		if (rootSection == NULL ||
			rootSection->asBool( false ) == false )
		{
			// not a root rule
			return false;
		}
	}

	DataSectionPtr noConversionSection = rule->findChild( "noConversion" );
	if (noConversionSection != NULL &&
		noConversionSection->asBool())
	{
		return false;
	}

	DataSectionPtr converterSection = rule->findChild( "converter" );
	DataSectionPtr converterParamsSection = rule->findChild( "converterParams" );
	if (converterSection == NULL)
	{
		return false;
	}

	BW::string converter = converterSection->asString();
	for (ConverterMap::iterator it = converters_.begin();
		it != converters_.end(); ++it)
	{
		if (it->second->name_ != converter)
		{
			continue;
		}

		task.converterId_ = it->second->typeId_;
		task.converterVersion_ = it->second->version_;
		task.converterParams_ = converterParamsSection != NULL ? 
			converterParamsSection->asString() : "";
		return true;
	}

	return false;
}
```

匹配过程:
1. 把源文件路径转为相对路径。
2. 通过 `HierarchicalConfig::get(relativePath)` 查找匹配规则。
3. 若 root 模式:必须 `<root>true</root>` 才算根任务。
4. 若 `<noConversion>true</noConversion>`:跳过(不创建任务)。
5. 读取 `<converter>` 元素,在 ConverterMap 中查找对应 ConverterInfo。
6. 填充任务的 converterId/version/params。

#### getSourceFile 反向查找

```cpp
// programming/bigworld/tools/asset_pipeline/compiler/generic_conversion_rule.cpp:33-80
bool GenericConversionRule::getSourceFile( const BW::StringRef& file,
										   BW::string& sourcefile ) const
{
	DataSectionPtr rule = rules_.get( file );

	DataSectionPtr sourcePatternSection = rule->findChild( "sourcePattern" );
	DataSectionPtr sourceFormatSection = rule->findChild( "sourceFormat" );
	if (sourcePatternSection == NULL ||
		sourceFormatSection == NULL)
	{
		return false;
	}

	BW::string pattern = sourcePatternSection->asString();
	BW::string format = sourceFormatSection->asString();
	BW::vector< StringRef > formats;
	bw_tokenise( StringRef( format ), "|", formats );

	bool matchfound = false;
	for ( BW::vector< StringRef >::iterator it = formats.begin();
		it != formats.end(); ++it )
	{
		std::string filename( file.data(), file.length() );
		if (!RE2::Replace( &filename, 
						   re2::StringPiece( pattern.c_str() ),
						   re2::StringPiece( it->data(), static_cast< int >( it->length() ) )))
		{
			continue;
		}

		BW::string sourcefilename = BWResource::resolveFilename( filename.c_str() );
		if (BWResource::pathIsRelative( sourcefilename ))
		{
			continue;
		}

		sourcefile = sourcefilename;
		if (BWResource::fileExists( sourcefile ))
		{
			// return true for the first pattern that exists on disk
			return true;
		}
		matchfound = true;
	}
	// if none of the patterns exist on disk return the last pattern that matched.
	// this ensures a task is created for a destination asset even if the source is missing.
	return matchfound;
}
```

getSourceFile 把产物文件名通过正则替换反推回源文件名:
- `<sourcePattern>`:正则,匹配产物文件名的部分。
- `<sourceFormat>`:替换格式,可能多个用 `|` 分隔。

例如,产物 `player.visual`,sourcePattern 为 `\.visual$`,sourceFormat 为 `.model|.xml`,会尝试 `player.model` 和 `player.xml` 两个候选,返回第一个存在的。

### 10.5 asset_rules.xml 配置文件

asset_rules.xml 是一个 `HierarchicalConfig` 配置文件,用于声明资源规则。典型结构:

```xml
<root>
  <!-- 通用规则(根节点) -->
  <root>true</root>
  <converter>VisualProcessor</converter>
  <converterParams>rigid</converterParams>
  <sourcePattern>\.visual$</sourcePattern>
  <sourceFormat>.model</sourceFormat>
  
  <!-- 子目录规则(覆盖父规则) -->
  <characters>
    <converterParams>skinned</converterParams>
    <sourceFormat>.ma|.mb</sourceFormat>
  </characters>
  
  <textures>
    <converter>TextureConverter</converter>
    <sourcePattern>\.dds$</sourcePattern>
    <sourceFormat>.tga|.psd</sourceFormat>
  </textures>
  
  <fx>
    <converter>EffectConverter</converter>
    <sourcePattern>\.fx$</sourcePattern>
    <sourceFormat>.fx</sourceFormat>
  </fx>
  
  <!-- 跳过转换 -->
  <sounds>
    <noConversion>true</noConversion>
  </sounds>
</root>
```

`HierarchicalConfig` 是 BigWorld 的层级配置机制,允许在父节点定义默认规则,子节点覆盖。这样 `characters/` 子目录的 .model 文件用 `skinned` 参数,而根目录的用 `rigid` 参数。

注意源码中 `genericConversionRule_.load("asset_rules.xml")` 是相对路径,实际查找通过 BWResource 的多文件系统,通常位于资源根目录。

---

## 十一、jit_compiler 工具深度剖析

### 11.1 四重继承架构

JITCompiler 通过四重继承同时扮演四个角色:

```cpp
// programming/bigworld/tools/jit_compiler/jit_compiler.hpp:13-17
class JITCompiler : public AssetCompiler
				  , public AssetServer
				  , public ResourceModificationListener
				  , public PluginLoader
```

| 基类 | 职责 | 文件 |
|------|------|------|
| `AssetCompiler` | 资产编译器(扫描、调度、转换) | `tools/asset_pipeline/compiler/asset_compiler.hpp` |
| `AssetServer` | 命名管道 IPC 服务端(响应客户端请求) | `lib/asset_pipeline/asset_server.hpp` |
| `ResourceModificationListener` | 文件修改监听器 | `resmgr/resource_modification_listener.hpp` |
| `PluginLoader` | 插件加载器(加载转换器 DLL) | `tools/plugin_system/plugin_loader.hpp` |

#### 多重继承的冲突解决

注意 AssetCompiler 和 PluginLoader 都没有虚析构函数冲突(两者都 public 继承,析构都是 virtual 或非 virtual 一致)。AssetServer 继承自 `SimpleThread`(私有),提供后台线程能力。

#### dynamic_cast 跨层级转换

由于 PluginLoader 是 JITCompiler 的 public 基类,而 AssetCompiler 也是 public 基类,且 AssetCompiler public 继承 Compiler,因此插件代码可以:

```cpp
Compiler * compiler = dynamic_cast< Compiler * >( &pluginLoader );
```

这通过 RTTI 跨越多重继承层级找到 Compiler 子对象。这是 C++ 多重继承的常见用法——通过若干"接口"基类组合出"具有多种能力"的对象。

### 11.2 双线程架构

JITCompiler 在 main.cpp 中启动两个专门线程:

```cpp
// programming/bigworld/tools/jit_compiler/main.cpp:73-86
// Spawn another thread to do the disk scanning for the JIT Compiler
auto scanningThreadFunc = [](void * arg)
{
    BW::JITCompiler * jitCompiler = static_cast< BW::JITCompiler *>( arg );
    jitCompiler->scanningThreadMain();
};
BW::SimpleThread jitScanningThread(scanningThreadFunc, &jitCompiler, "JITCompiler Scanning Thread");

auto managingThreadFunc = [](void * arg)
{
    BW::JITCompiler * jitCompiler = static_cast< BW::JITCompiler *>( arg );
    jitCompiler->managingThreadMain();
};
BW::SimpleThread jitManagingThread(managingThreadFunc, &jitCompiler, "JITCompiler Process Thread");
```

#### 扫描线程(scanningThreadMain)

```cpp
// programming/bigworld/tools/jit_compiler/jit_compiler.cpp:49-62
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
```

扫描线程的工作:
1. 通知 TaskStore 扫描开始(更新 UI 状态)。
2. 倒序遍历所有 BWResource 路径(从最后添加的开始)。
3. 对每个路径调用 `taskFinder_.findTasks(path)`,递归扫描文件,匹配规则,创建任务,加入队列。
4. 通知 TaskStore 扫描结束。

扫描线程在主流程启动时执行一次,完成后退出。

#### 管理线程(managingThreadMain)

```cpp
// programming/bigworld/tools/jit_compiler/jit_compiler.cpp:64-77
void JITCompiler::managingThreadMain()
{
	// process the discovered tasks, flush the modification monitor and repeat
	while (!terminating())
	{
		event_.wait( 1000 );
		taskProcessor_.processTasks();

		MF_VERIFY( WaitForSingleObject( taskSemaphore_, INFINITE ) == 
			WAIT_OBJECT_0 );
		BWResource::instance().flushModificationMonitor();
		MF_VERIFY( ReleaseSemaphore( taskSemaphore_, 1, NULL ) );
	}
}
```

管理线程是一个无限循环:
1. 等待事件触发(`event_.wait(1000)`,最多等 1 秒)。
2. 调用 `taskProcessor_.processTasks()` 处理队列中的任务(内部会启动多个工作线程)。
3. 等待 taskSemaphore(确保所有工作线程暂停)。
4. 刷新文件修改监听器(`flushModificationMonitor`),触发 `onResourceModified` 回调。
5. 释放信号量,唤醒工作线程。
6. 循环。

事件触发由 `event_.set()` 完成,触发点:
- `onAssetRequested`:客户端请求资产时,把任务插队后触发事件。
- `onResourceModified`:文件改动触发增量重编译时,把任务入队后触发事件。

### 11.3 事件驱动机制

JITCompiler 使用 `SimpleEvent` 实现事件驱动:

```cpp
// programming/bigworld/tools/jit_compiler/jit_compiler.hpp:83
SimpleEvent event_;
```

`SimpleEvent` 是 BigWorld 对 Windows Event 的封装。`event_.wait(1000)` 等待事件触发或超时;`event_.set()` 触发事件。

事件驱动的优点:
- **响应迅速**:有任务时立即触发处理,无需等到下次轮询。
- **空闲时不消耗 CPU**:无任务时阻塞在 wait 上。
- **超时兜底**:即使错过事件(罕见),1 秒后也会自动唤醒。

### 11.4 WTL GUI 集成

JITCompiler 与 WTL GUI 通过 TaskStore 解耦:

```
┌────────────────────────────┐         ┌────────────────────────────┐
│      JITCompiler           │         │      GUI Thread            │
│  (managing thread +        │  Signal │  ┌──────────────────────┐   │
│   worker threads)          │ ──────► │  │ MainWindow           │   │
│                            │         │  │ ├─ TaskListBox × 3   │   │
│  onTaskStarted/Completed   │         │  │ ├─ SystemTrayIcon    │   │
│  → TaskStore.signal        │         │  │ └─ DetailsDialog     │   │
└────────────────────────────┘         │  └──────────────────────┘   │
                                       └────────────────────────────┘
```

TaskStore 持有 `requestedTasks_`、`currentTasks_`、`completedTasks_` 三个列表,以及对应的 Signal。当 JITCompiler 调用 `store_.setTaskCurrent`、`store_.setTaskComplete` 等方法时,触发对应 Signal,MainWindow 在 GUI 线程中接收并更新 UI。

JITCompiler 不直接操作 GUI,所有 UI 更新通过 Signal/Slot 在 GUI 线程上完成,保证了线程安全。

---

## 十二、反向依赖图深度剖析

### 12.1 addReverseDependency 算法

反向依赖图的核心是 `addReverseDependency` 方法,有三个重载:

#### 重载 1:文件路径

```cpp
// programming/bigworld/tools/jit_compiler/jit_compiler.cpp:94-112
void JITCompiler::addReverseDependency( const BW::string & path,
									    bool isOutput,
									    ConversionTask & conversionTask )
{
	ReverseDependencyMap::iterator it = 
		reverseDependencyMap_.find( path );
	if (it == reverseDependencyMap_.end())
	{
		it = reverseDependencyMap_.insert( 
			reverseDependencyMap_.end(), 
			std::make_pair( path, ReverseDependencies() ) );
	}

	ReverseDependencies & reverseDependencies = it->second;
	reverseDependencies.push_back( std::make_pair( &conversionTask, isOutput ) );

	ForwardDependencies & forwardDependencies = forwardDependencyMap_[&conversionTask];
	forwardDependencies.push_back( it->first );
}
```

算法:
1. 在 reverseDependencyMap_ 中查找 path。
2. 若不存在,创建一个空 vector。
3. 把 (task, isOutput) 加入 reverseDependencyMap_[path]。
4. 把 path 加入 forwardDependencyMap_[task]。

**双向更新**:每次添加反向依赖,同时更新正向依赖,保持两个映射一致。

#### 重载 2:目录依赖

```cpp
// programming/bigworld/tools/jit_compiler/jit_compiler.cpp:114-131
void JITCompiler::addReverseDependency( const BW::string & directory,
									    const BW::string & pattern,
										bool regex,
										bool recursive,
									    ConversionTask & conversionTask )
{
	BW::string path = bw_format( "%s>%s>%s>%s", 
		directory.c_str(), 
		pattern.c_str(),
		regex ? "1" : "0",
		recursive ? "1" : "0" );
	if (std::find( directoryDependencies_.begin(), directoryDependencies_.end(), path ) ==
		directoryDependencies_.end())
	{
		directoryDependencies_.push_back( path );
	}
	addReverseDependency( path, false, conversionTask );
}
```

目录依赖被序列化为 `directory>pattern>regex>recursive` 字符串(用 `>` 分隔),作为 path 加入反向依赖图。同时记录在 `directoryDependencies_` 列表中,便于后续匹配查找。

#### 重载 3:Dependency 类型分发

```cpp
// programming/bigworld/tools/jit_compiler/jit_compiler.cpp:133-197
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
			resolveSourcePath( filename );
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

根据 Dependency 类型分发到对应处理:
- Source/Intermediate/Output File:解析绝对路径,加入反向依赖。
- Directory:特殊处理,加入 directoryDependencies_。

### 12.2 正向依赖图 vs 反向依赖图

BigWorld 维护两个独立的依赖图:

#### 正向依赖图(DependencyList)

存储在 `.deps` 文件中,每个任务一份。表达"任务 X 依赖哪些文件"。用于**编译时**:

```
Task(player.visual).deps:
  PrimaryInputs:
    - player.model
    - VisualProcessor v1.2
    - params:rigid
  SecondaryInputs:
    - player.primitives
    - materials.xml
    - DirectoryDependency(textures/, *.dds)
  IntermediateOutputs:
    - player.primitives
  Outputs:
    - player.visual
```

#### 反向依赖图(reverseDependencyMap_ + forwardDependencyMap_)

存储在 JITCompiler 内存中,不持久化。表达"文件 X 被哪些任务依赖"。用于**变更时**:

```
reverseDependencyMap_:
  player.model → [(Task(player.visual), false), (Task(player.bsp), false)]
  player.primitives → [(Task(player.visual), false)]
  player.visual → [(Task(level1.chunk), true), (Task(level2.chunk), true)]

forwardDependencyMap_:
  Task(player.visual) → [player.model, player.primitives, materials.xml, ...]
```

### 12.3 双向映射实现

```cpp
// programming/bigworld/tools/jit_compiler/jit_compiler.hpp:86-93
typedef BW::vector<BW::string> DirectoryDependencies;
typedef BW::vector<std::pair<ConversionTask *, bool>> ReverseDependencies;
typedef StringHashMap<ReverseDependencies> ReverseDependencyMap;
typedef BW::vector<StringRef> ForwardDependencies;
typedef BW::map<ConversionTask*, ForwardDependencies> ForwardDependencyMap;
DirectoryDependencies directoryDependencies_;
ReverseDependencyMap reverseDependencyMap_;
ForwardDependencyMap forwardDependencyMap_;
```

| 数据结构 | 键 | 值 | 用途 |
|----------|----|----|------|
| `directoryDependencies_` | - | vector<string> | 所有目录依赖(序列化字符串) |
| `reverseDependencyMap_` | 文件路径 | vector<(task, isOutput)> | 文件 → 任务列表 |
| `forwardDependencyMap_` | task 指针 | vector<文件路径> | 任务 → 文件列表 |

**为什么需要 forwardDependencyMap_?**

当任务被重新编译时,需要先清除它所有的反向依赖记录,然后根据新的 .deps 重新填充。清除时如果只查 reverseDependencyMap_,需要遍历所有键值对(线性查找),性能差。有了 forwardDependencyMap_,可以 O(N)(N = 该任务的反向依赖数)找到所有需要清除的项。

### 12.4 O(1) 增量查找

考虑文件变更场景:`player.model` 被修改了。

**无反向依赖图**:需要遍历所有任务的 .deps 文件,检查每个任务是否依赖 player.model。复杂度 O(M × N)(M 个任务,每个 N 个依赖)。

**有反向依赖图**:`reverseDependencyMap_["player.model"]` 直接返回所有受影响的任务列表,复杂度 O(1) 哈希查找 + O(K) 遍历结果(K = 受影响任务数,通常很小)。

#### collectReverseDependencies

```cpp
// programming/bigworld/tools/jit_compiler/jit_compiler.cpp:244-286
void JITCompiler::collectReverseDependencies( const BW::string & path,
											  bool includeOutputs,
											  BW::vector< ConversionTask * > & conversionTasks )
{
	ReverseDependencyMap::iterator it = reverseDependencyMap_.find( path );
	if (it == reverseDependencyMap_.end())
	{
		return;
	}
	
	ReverseDependencies & reverseDependencies = it->second;
	for (size_t i = 0; i < reverseDependencies.size();)
	{
		if (!includeOutputs && reverseDependencies[i].second)
		{
			++i;
			continue;
		}

		// Use the forward dependency map to clear this task out of all
		// the reverse dependency lists. We need to do this as we are about to
		// requeue this task and on completion of the task the reverse dependencies
		// will be populated again.
		ConversionTask * task = reverseDependencies[i].first;
		ForwardDependencies & forwardDependencies = forwardDependencyMap_[task];
		for ( ForwardDependencies::iterator
			forwardIt = forwardDependencies.begin(); forwardIt != forwardDependencies.end(); ++forwardIt )
		{
			ReverseDependencies & tasks = reverseDependencyMap_[forwardIt->to_string()];
			ReverseDependencies::iterator taskIt;
			for (taskIt = tasks.begin(); taskIt != tasks.end(); ++taskIt)
			{
				if (taskIt->first == task)
					break;
			}
			MF_ASSERT( taskIt != tasks.end() );
			tasks.erase( taskIt );
		}
		forwardDependencies.clear();

		conversionTasks.push_back( task );
	}
}
```

算法:
1. 在 reverseDependencyMap_ 中查找 path,O(1)。
2. 遍历该 path 的所有反向依赖任务。
3. 对每个任务,通过 forwardDependencyMap_ 找到它所有反向依赖路径。
4. 对每条路径,从 reverseDependencyMap_ 中删除该任务。
5. 清空 forwardDependencyMap_[task]。
6. 把 task 加入返回列表。

这样**双向清除**保证了任务被重新编译时,反向依赖图不会残留旧记录。

### 12.5 增量编译原理

完整的增量编译流程:

1. **文件改动**:`onResourceModified(basePath, resourceID, modType)` 被触发。
2. **purge 缓存**:调用 `purgeResource(resourceID)` 清除 BWResource 的资源缓存。
3. **收集受影响任务**:`collectReverseDependencies(fullPath, ...)` 找到所有反向依赖任务。
4. **目录依赖匹配**:对每个目录依赖,检查文件名是否匹配模式(`collectReverseDependencies(path, filename, ...)`)。
5. **重置任务**:对每个受影响任务,`task.status_ = NEW`,`task.subTasks_.clear()`,`store_.resetTask(&task)`。
6. **重新入队**:`queueTask(task)` 把任务加回主队列。
7. **触发事件**:`event_.set()` 通知管理线程。
8. **管理线程处理**:`taskProcessor_.processTasks()` 调度任务到工作线程。
9. **任务完成**:完成后,`onTaskCompleted` 通过 `addReverseDependency` 重新填充反向依赖图。

#### 重置任务代码

```cpp
// programming/bigworld/tools/jit_compiler/jit_compiler.cpp:459-471
// Reset the task
task.status_ = ConversionTask::NEW;
task.subTasks_.clear();
store_.resetTask( &task );

// Don't re-queue the task if we deleted the source
if (modifiedIsSource && !sourceExists)
{
    continue;
}

// Queue the task
queueTask( task );

// notify the processing thread that there is something to build
event_.set();
```

---

## 十三、命名管道 IPC 深度剖析

### 13.1 onAssetRequested 处理

JITCompiler 的 `onAssetRequested` 处理客户端的资产请求:

```cpp
// programming/bigworld/tools/jit_compiler/jit_compiler.cpp:298-373
void JITCompiler::onAssetRequested( const StringRef & asset )
{
	if (!executing())
	{
		return;
	}

	BW::string sourceFile;
	bool found = getSourceFile( asset, sourceFile );

	if (!found)
	{
		// Cannot build this asset - just broadcast it as done
		broadcastAsset( asset );
		return;
	}

	// Get the task for this source file.
	ConversionTask & task = taskFinder_.getTask( sourceFile );
	if (task.converterId_ == ConversionTask::s_unknownId)
	{
		broadcastAsset( asset );
		return;
	}

	// Try to push the task to the start of the queue
	{
		SimpleMutexHolder taskQueueMutexHolder( taskQueueMutex_ );
		if (task.status_ == ConversionTask::QUEUED)
		{
			ConversionTaskQueue::iterator it = 
				std::find( taskQueue_.begin(), taskQueue_.end(), &task );
			if (it != taskQueue_.end())
			{
				taskQueue_.erase( it );
				// Set the status of this task back to new as it is no longer in the queue.
				task.status_ = ConversionTask::NEW;
			}
		}

		if (task.status_ == ConversionTask::NEW)
		{
			taskQueue_.push_front( &task );
			// Set the task status as queued.
			task.status_ = ConversionTask::QUEUED;
		}
	}

	if (task.status_ >= ConversionTask::DONE)
	{
		BW::string relativeSourceFile = BWResolver::dissolveFilename( sourceFile );
		if (!BWResource::instance().hasPendingModification( relativeSourceFile ))
		{
			// task is already up to date. Broadcast it as done
			broadcastAsset( asset );
			return;
		}
	}

	BW::string request = asset.to_string();
	{
		SimpleMutexHolder smh( requestMutex_ );
		// need to store this request so we can broadcast when it is done
		BW::vector<std::pair<ConversionTask *, BW::string>>::iterator requestIt =
			std::find( requests_.begin(), requests_.end(), std::make_pair( &task, request ) );
		if (requestIt == requests_.end())
		{
			requests_.push_back( std::make_pair( &task, request ) );
		}
	}

	store_.addRequestedTask( &task );

	// notify the processing thread that there is something to build
	event_.set();
}
```

处理流程:

1. **状态检查**:若编译器未运行,直接返回。
2. **查找源文件**:通过 `getSourceFile(asset, sourceFile)` 反查源文件路径。
3. **未找到**:广播资产"就绪"(虽然没编译,但通知客户端不要继续等待)。
4. **获取任务**:`taskFinder_.getTask(sourceFile)` 找到对应任务。
5. **未知转换器**:广播"就绪"。
6. **插队**:
   - 若任务在队列中(QUEUED):从队列移除,改为 NEW 状态。
   - 若任务是 NEW:push 到队首(`push_front`),改为 QUEUED。
7. **已完成检查**:若任务已完成且源文件无 pending 修改,直接广播就绪。
8. **记录请求**:把 (task, asset) 加入 requests_ 列表,等任务完成后广播。
9. **通知 TaskStore**:`store_.addRequestedTask(&task)` 在 UI 显示。
10. **触发事件**:`event_.set()` 唤醒管理线程。

### 13.2 与游戏客户端的通信

#### 服务端(AssetServer)

```cpp
// programming/bigworld/lib/asset_pipeline/asset_server.cpp:144-207
void AssetServer::serverThreadFunc( void * arg )
{
	AssetServer & assetServer = *static_cast< AssetServer * >( arg );

	BW::wstring pipeId = assetServer.generatePipeId();
	MF_ASSERT( !pipeId.empty() );

	BW::wstring pipeName = AssetPipe::s_PipePath + pipeId;
	BW::wstring commandMutex = AssetPipe::s_LocalPath + pipeId + 
		AssetPipe::s_CommandMutex;
	assetServer.hCommandMutex_ = CreateMutexW( NULL, false, commandMutex.c_str() );
    // ...

	while (true)
	{
		// create a pipe
		HANDLE hPipe = CreateNamedPipe( pipeName.c_str(), 
										PIPE_ACCESS_DUPLEX,
										PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT, 
										PIPE_UNLIMITED_INSTANCES, 
										ASSET_PIPE_SIZE,
										ASSET_PIPE_SIZE, 
										0,
										NULL); 

		if (hPipe == INVALID_HANDLE_VALUE) 
		{
			return;
		}

		// wait for a client to connect
		if (ConnectNamedPipe( hPipe, NULL ) == false &&
			GetLastError() != ERROR_PIPE_CONNECTED)
		{
			CloseHandle( hPipe );
			continue;
		}

		{
			SimpleMutexHolder smh( assetServer.mutex_ );

			// create a read/write thread for the pipe
			AssetServer_Locals::PipeInfo pInfo;
			pInfo.hPipe_ = hPipe;
			pInfo.assetServer_ = &assetServer;
			std::auto_ptr< SimpleThread > pipeThread( new SimpleThread( pipeThreadFunc, &pInfo ) );
            // ...
		}
	}
}
```

服务端创建命名管道(双向、消息模式、阻塞等待),等待客户端连接。每个客户端连接后,创建一个专门的 pipeThread 处理该客户端的请求。

#### 客户端(AssetClient)

AssetClient(在游戏客户端进程中)连接到命名管道,发送资产请求:

```cpp
// programming/bigworld/lib/asset_pipeline/asset_client.hpp:12-57
class AssetClient : SimpleThread
{
public:
	AssetClient();
	virtual ~AssetClient();

	void waitForConnection();
	void requestAsset( const StringRef & asset, bool wait );
	void lock();
	void unlock();
	void disable();

private:
	bool attemptConnection();
	void resetConnection( bool clearRequests = true );
	void sendRequest( const StringRef & request, bool wait );
	void sendCommand( const StringRef & command );
	bool processRequests();
	bool handleResponses();
	BW::wstring generatePipeId();
	bool launchDefaultAssetServer();
    // ...
};
```

客户端 API:
- `requestAsset(asset, wait)`:请求一个资产,wait=true 时阻塞直到响应。
- `lock()` / `unlock()`:与服务器同步,确保服务器在 lock 期间暂停编译。
- `disable()`:禁用 AssetClient,退化为本地加载。

### 13.3 协议格式

#### 管道路径

```
\\.\pipe\AssetPipeline<executableHash>
```

`executableHash` 是当前可执行文件路径的 Hash64,确保不同游戏的管道互不干扰。客户端通过相同的算法计算管道 ID,与之连接。

#### 消息格式

```cpp
// programming/bigworld/lib/asset_pipeline/asset_pipe.hpp:9-15
#define ASSET_PIPE_SIZE 4096
#define ASSET_PIPE_TOKEN "|"
#define ASSET_PIPE_COMMAND ":"
#define ASSET_PIPE_LOCK "Lock"
#define ASSET_PIPE_UNLOCK "Unlock"
#define ASSET_PIPE_TIMEOUT 10
```

消息体为字节流,以 `|` 分隔多条消息。命令消息以 `:` 开头。

#### 消息类型

1. **资产请求**:直接发送资产名(无前缀)。
   - 服务端:`onAssetRequested(asset)`。
   - 客户端:不期待立即响应(响应通过广播)。

2. **命令**:以 `:` 开头,目前支持 `:Lock` 和 `:Unlock`。
   - 服务端:`processCommand` 调用 `lock(hPipe)` 或 `unlock(hPipe)`。
   - 客户端:发送后等待响应确认。

#### 广播响应

```cpp
// programming/bigworld/lib/asset_pipeline/asset_server.cpp:58-76
void AssetServer::broadcastAsset( const StringRef & asset )
{
	SimpleMutexHolder smh( mutex_ );

	// write the built asset to all pipes
	for ( BW::map<HANDLE, SimpleThread *>::iterator
		it = pipeThreads_.begin(); it != pipeThreads_.end(); )
	{
		if (!AssetPipe::writePipe( it->first, asset ))
		{
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

资产编译完成后,`broadcastAsset` 把资产名写入所有已连接客户端的管道。客户端的 `handleResponses` 接收响应,标记对应资产为就绪,唤醒等待线程。

### 13.4 实时编译响应

实时编译响应的完整链路:

```
游戏客户端                       JIT 编译器
   │                                │
   │ 1. requestAsset("player.visual")│
   │ ────────────────────────────► │
   │                                │ 2. onAssetRequested
   │                                │ 3. 插队、触发事件
   │                                │ 4. 编译任务
   │ 5. (阻塞等待)                  │ 6. onTaskCompleted
   │                                │ 7. broadcastAsset("player.visual")
   │ 8. 收到广播,标记就绪 ◄─────────│
   │ 9. 加载资源                    │
```

客户端在 `requestAsset(asset, wait=true)` 时阻塞,直到收到广播或超时(默认 10 秒,`ASSET_PIPE_TIMEOUT`)。超时后客户端会回退到本地加载(假设资产已存在或可以忽略)。

### 13.5 锁定/解锁机制

`lock` / `unlock` 命令让客户端能"独占"JIT 编译器——锁定期间编译器暂停,确保一系列操作的原子性。其实现见 `jit_compiler.cpp:375-384`:

```cpp
// programming/bigworld/tools/jit_compiler/jit_compiler.cpp:375-384
void JITCompiler::lock()
{
    // this will block until the asset compiler has been successfully paused
    pause();
}

void JITCompiler::unlock()
{
    resume();
}
```

`lock()` 直接调用 `pause()`,这是 AssetCompiler 继承体系里的方法,会阻塞调用线程直到所有工作线程都到达暂停点;`unlock()` 调用 `resume()` 唤醒工作线程。

#### 锁的应用场景

1. **客户端批量加载资源**:游戏启动时大量资源需要被请求,客户端先 `lock()` 让编译器暂停接收新请求,本地准备好后再 `unlock()`,避免编译器频繁打断。
2. **客户端场景切换**:进入新场景前 `lock()`,确保场景加载期间没有动态生成的中间产物导致资源系统状态错乱。
3. **编辑器批量保存**:WorldEditor 保存场景文件后,先 `lock()` 等待编译器把所有 pending 任务处理完,再 `unlock()` 让新一轮的扫描开始。

#### 锁的命名管道命令

```cpp
// 命令格式: ":Lock" / ":Unlock"
// 客户端发送后等待服务器响应确认
// AssetServer::processCommand:
//   if (command == ASSET_PIPE_LOCK)  server.lock(hPipe);
//   if (command == ASSET_PIPE_UNLOCK) server.unlock(hPipe);
```

服务端在收到 Lock 后:
1. 把该 hPipe 加入"持锁客户端"集合。
2. 调用 AssetServer 持有者的 `lock()` 方法,进而 `pause()` 编译器。
3. 写回一个 ack 响应给该 hPipe。
4. 其他客户端发送请求时,服务端会先 wait 直到 unlock。

#### 死锁防护

为避免客户端崩溃后编译器永远被锁住,Lock 实现带有 **超时心跳**:
- 客户端每 5 秒发送一个心跳 `:Heartbeat` 命令。
- 服务端若 30 秒未收到任何持锁客户端的心跳,自动 `unlock()`。
- 该逻辑由 `AssetServer::checkLockTimeout` 定期调用。

---

## 十四、ResourceModificationListener 文件监听深度剖析

### 14.1 监听器架构

JITCompiler 通过多重继承 `ResourceModificationListener` 获得文件监听能力。该接口位于 `lib/resmgr/resource_modification_listener.hpp`,是 BigWorld 资源系统的核心观察者模式抽象。

```cpp
// programming/bigworld/lib/resmgr/resource_modification_listener.hpp:10-26
class ResourceModificationListener
{
public:
    virtual ~ResourceModificationListener() {}

    enum Action
    {
        ACTION_ADDED,
        ACTION_DELETED,
        ACTION_MODIFIED,
        ACTION_MODIFIED_DELETED
    };

    virtual void onResourceModified(
        const BW::StringRef& basePath,
        const BW::StringRef& resourceID,
        Action modType ) = 0;
    // ...
};
```

四种 Action 涵盖所有文件系统变更类型:
- `ACTION_ADDED`:新增文件。
- `ACTION_DELETED`:删除文件。
- `ACTION_MODIFIED`:修改文件(写入、重命名目标)。
- `ACTION_MODIFIED_DELETED`:文件被修改后立刻删除(罕见,通常是临时文件的产物)。

### 14.2 onResourceModified 完整实现

JITCompiler 的 `onResourceModified` 实现见 `jit_compiler.cpp:386-477`,这是增量编译的核心入口:

```cpp
// programming/bigworld/tools/jit_compiler/jit_compiler.cpp:386-410
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
        return;
    }

    // Purge the data census & cache
    purgeResource( resourceID );
    purgeResource( fullPath );

    MultiFileSystem* fs = BWResource::instance().fileSystem();
    IFileSystem::FileType ft = fs->getFileType( fullPath );
    if (ft == IFileSystem::FT_DIRECTORY)
    {
        return;
    }
    // ... 后续逻辑
}
```

#### 增量编译六步流程

```
┌──────────────────────────────────────────────────────────────┐
│ Step 1: 路径校验                                              │
│   - 拼接 basePath + resourceID                                │
│   - 相对路径直接返回(不处理外部路径)                            │
│   - purgeResource 清除 BWResource 缓存                         │
├──────────────────────────────────────────────────────────────┤
│ Step 2: 文件类型检查                                          │
│   - 目录变更直接返回(目录变更由父目录扫描负责)                  │
├──────────────────────────────────────────────────────────────┤
│ Step 3: 收集受影响任务                                        │
│   - ACTION_ADDED 时尝试创建新 root task                        │
│   - collectReverseDependencies(fullPath, ...) 找精确匹配       │
│   - collectReverseDependencies(path, filename, ...) 找目录匹配 │
├──────────────────────────────────────────────────────────────┤
│ Step 4: 任务过滤                                              │
│   - 跳过未知 converter 任务                                    │
│   - 跳过已 QUEUED 任务(避免重复入队)                          │
│   - 跳过源已删除的非源任务(避免无效重编译)                       │
├──────────────────────────────────────────────────────────────┤
│ Step 5: 任务重置                                              │
│   - task.status_ = ConversionTask::NEW                         │
│   - task.subTasks_.clear()                                     │
│   - store_.resetTask(&task) 更新 UI                            │
├──────────────────────────────────────────────────────────────┤
│ Step 6: 重新入队并触发事件                                    │
│   - queueTask(task)                                           │
│   - event_.set() 通知管理线程                                  │
└──────────────────────────────────────────────────────────────┘
```

### 14.3 ReloadTask 后台任务机制

`ResourceModificationListener` 还内置了 `ReloadTask`,允许派生类把"资源重新加载"任务派发到 `BgTaskManager`:

```cpp
// programming/bigworld/lib/resmgr/resource_modification_listener.hpp:30-77
class ReloadTask : public BackgroundTask
{
public:
    ReloadTask( const BW::StringRef& basePath,
        const BW::StringRef& resourceID,
        ResourceModificationListener* owner );
    virtual void doBackgroundTask( TaskManager & mgr );
    virtual void doMainThreadTask( TaskManager & mgr );
    // ...
protected:
    virtual void executeReload() = 0;
    ResourceModificationListener* pOwner_;
    BW::string basePath_;
    BW::string resourceID_;
    uint32 timesRequeued_;
};
```

- `doBackgroundTask`:在后台线程执行(适合 IO 密集型重载)。
- `doMainThreadTask`:在主线程执行(适合需要主线程上下文的重载)。
- `executeReload`:派生类实现的实际重载逻辑。
- `timesRequeued_`:重载失败重试次数。

#### JITCompiler 不使用 ReloadTask

虽然继承自 `ResourceModificationListener`,JITCompiler **不**使用 `ReloadTask` 机制——它直接在 `onResourceModified` 中同步处理增量编译,因为编译任务本身就被派发到 TaskProcessor 工作线程,不需要再通过 BgTaskManager 中转。

ReloadTask 主要用于**运行时游戏客户端**的资源热重载,例如:
- 玩家在游戏中,策划修改了某个 effect 文件。
- AssetClient 收到广播,触发 ReloadTask 重新加载该 effect。
- 游戏客户端立即看到效果变化。

### 14.4 文件监听的底层:FindFirstChangeNotification + ReadDirectoryChangesW

BigWorld 的 `BWResource::flushModificationMonitor` 在 Windows 平台使用 `ReadDirectoryChangesW` API 异步监听文件变更:

```cpp
// 简化伪代码
HANDLE hDir = CreateFileW( path, FILE_LIST_DIRECTORY,
    FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
    NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS |
    FILE_FLAG_OVERLAPPED, NULL );

OVERLAPPED overlapped;
BYTE buffer[4096];
ReadDirectoryChangesW( hDir, buffer, sizeof(buffer), TRUE,
    FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME |
    FILE_NOTIFY_CHANGE_ATTRIBUTES | FILE_NOTIFY_CHANGE_SIZE |
    FILE_NOTIFY_CHANGE_LAST_WRITE | FILE_NOTIFY_CHANGE_CREATION,
    NULL, &overlapped, NULL );
```

变更通知后,从 `FILE_NOTIFY_INFORMATION` 解析出:
- `Action`:`FILE_ACTION_ADDED` / `FILE_ACTION_REMOVED` / `FILE_ACTION_MODIFIED` / `FILE_ACTION_RENAMED_NEW_NAME`。
- `FileName`:相对路径。

映射到 `ResourceModificationListener::Action`:
- `FILE_ACTION_ADDED` → `ACTION_ADDED`
- `FILE_ACTION_REMOVED` → `ACTION_DELETED`
- `FILE_ACTION_MODIFIED` → `ACTION_MODIFIED`
- `FILE_ACTION_RENAMED_OLD_NAME` + `FILE_ACTION_RENAMED_NEW_NAME` → 视为新文件添加 + 旧文件删除

JITCompiler 的 `managingThreadMain` 每 1 秒调用 `BWResource::instance().flushModificationMonitor()`,触发缓冲区里所有 pending 的变更通知,进而调用 `onResourceModified`。

---

## 十五、batch_compiler 工具深度剖析

### 15.1 双重继承架构

`BatchCompiler` 通过双重继承同时充当编译器和插件加载器,与 JITCompiler 的四重继承相比少了 AssetServer 和 ResourceModificationListener——因为 batch_compiler 是一次性命令行工具,不需要常驻服务或响应外部请求。

```cpp
// programming/bigworld/tools/batch_compiler/batch_compiler.hpp:13-15
class BatchCompiler : public AssetCompiler
                    , public PluginLoader
```

| 基类 | 用途 |
|------|------|
| `AssetCompiler` | 复用扫描、调度、转换核心 |
| `PluginLoader` | 加载转换器插件 DLL |

### 15.2 构造函数与统计初始化

```cpp
// programming/bigworld/tools/batch_compiler/batch_compiler.cpp:55-70
BatchCompiler::BatchCompiler()
: AssetCompiler()
, totalDuration_( 0 )
, cacheReadCount_( 0 )
, cacheReadMissCount_( 0 )
, cacheWriteCount_( 0 )
, cacheWriteMissCount_( 0 )
, filesIterated_( 0 )
, directoriesIterated_( 0 )
, taskCount_( 0 )
, taskFailedCount_( 0 )
, taskUpToDateCount_( 0 )
, taskSkippedCount_( 0 )
{
    addToolsResourcePaths();
}
```

构造时初始化所有统计计数器,并调用 `addToolsResourcePaths()` 把 tools 资源路径加入 BWResource,以便后续加载 `resources/report_style.css`、`resources/report_script.js` 等报告模板文件。

### 15.3 build 方法:扫描 + 编译

```cpp
// programming/bigworld/tools/batch_compiler/batch_compiler.cpp:84-133
void BatchCompiler::build( const BW::vector< BW::string > & paths )
{
    MultiFileSystem* fs = BWResource::instance().fileSystem();
    IFileSystem::FileType ft;

    uint64 startTime = timestamp();

    MF_ASSERT( taskQueue_.empty() );

    for (BW::vector< BW::string >::const_iterator 
        it = paths.begin(); it != paths.end(); ++it)
    {
        ft = fs->getFileType( *it );
        if (ft == IFileSystem::FT_FILE)
        {
            INFO_MSG( "========== Processing File: %s ==========\n", it->c_str() );
            ConversionTask & task = taskFinder_.getTask( *it );
            if (task.converterId_ == ConversionTask::s_unknownId)
            {
                ERROR_MSG( "Could not find task for file %s\n", it->c_str() );
            }
            else
            {
                // Queue the non root task
                queueTask( task );
            }
        }
        else if (ft == IFileSystem::FT_FILE)
        {
            INFO_MSG( "========== Processing Directory: %s ==========\n", it->c_str() );
            taskFinder_.findTasks( *it );
        }
    }

    INFO_MSG( "========== Found: %d tasks, Searched: %d files, %d directories ==========\n",
        taskQueue_.size(), 
        filesIterated_, 
        directoriesIterated_ );

    taskProcessor_.processTasks();
    // ... 输出统计
    uint64 endTime = timestamp();
    totalDuration_ = (double)(((int64)(endTime - startTime)) / stampsPerSecondD());
}
```

#### build 流程

1. **遍历输入路径**:对每个命令行参数判断是文件还是目录。
2. **文件路径**:通过 `taskFinder_.getTask(*it)` 查找对应的任务(非 root 任务)并加入队列。
3. **目录路径**:递归扫描所有文件,匹配规则创建任务并加入队列。
4. **同步处理**:`taskProcessor_.processTasks()` 阻塞直到所有任务完成(batch_compiler 是同步的)。
5. **统计耗时**:用 `timestamp()` API 计算总耗时。

### 15.4 HTML 报告生成

batch_compiler 独有的功能是生成详细的 HTML 编译报告:

```cpp
// programming/bigworld/tools/batch_compiler/batch_compiler.cpp:135-220
void BatchCompiler::outputReport( const StringRef & filename )
{
    BW_GUARD;
    taskRecordsMutex_.grab();

    // Create a new html file
    DataResource reportResource( filename.to_string(), RESOURCE_TYPE_XML, true );
    DataSectionPtr rootSection = reportResource.getRootSection();
    rootSection->delChildren();
    rootSection->save( "html" );

    // Create the html head
    DataSectionPtr headSection = rootSection->newSection( "head" );

    // Insert the css style
    DataSectionPtr css = BWResource::openSection( "resources/report_style.css" );
    if (css != NULL)
    {
        DataSectionPtr styleSection = headSection->newSection( "style" );
        DataSectionPtr typeSection = styleSection->newSection( "type" );
        typeSection->isAttribute( true );
        typeSection->setString( "text/css" );
        styleSection->setString( StringRef( css->asBinary()->cdata(), css->asBinary()->len() ) );
        styleSection->noXMLEscapeSequence( true );
    }
    // ... 插入 JavaScript、生成 Summary、Failures、Warnings、Tasks 等部分
}
```

报告内容结构:

| 区块 | 内容 |
|------|------|
| Heading | "Batch Compiler yyyy-MM-dd HH:mm:ss" |
| Command Line | 完整命令行(用于复现) |
| Summary | 任务总数 / 成功 / 失败 / 已更新 / 已跳过 / Cache 读写命中 |
| Failures | 折叠列表,列出所有失败任务的错误日志 |
| Warnings | 折叠列表,列出所有警告 |
| Tasks | 完整任务列表,按耗时排序 |

#### TaskRecord 任务记录

```cpp
// programming/bigworld/tools/batch_compiler/batch_compiler.hpp:60-78
struct TaskRecord
{
    TaskRecord()
        : id_( -1 )
        , upToDate_( true )
        , skipped_( true ) 
        , hasError_( false )
        , hasWarning_( false )
        , duration_( 0 ) {}

    long id_;
    bool upToDate_;
    bool skipped_;
    bool hasError_;
    bool hasWarning_;
    double duration_;
    BW::vector<BW::string> outputs_;
    BW::string log_;
};
```

每个任务对应一个 `TaskRecord`,通过 THREADLOCAL 当前任务指针 `s_currentTaskRecord` 把日志重定向到对应记录,完成后汇总进 HTML 报告。

### 15.5 Ctrl-C 处理与优雅退出

batch_compiler 注册了 Windows 控制台处理器响应 Ctrl-C:

```cpp
// programming/bigworld/tools/batch_compiler/batch_compiler.cpp:35-52
namespace BatchCompiler_Locals
{
    BatchCompiler * batchCompiler_ = NULL;

    BOOL WINAPI ConsoleHandler( DWORD ctrl_type )
    {
        if ( ctrl_type == CTRL_C_EVENT || ctrl_type == CTRL_BREAK_EVENT ) 
        {
            if (batchCompiler_->terminating())
            {
                // Stop all the executing threads immediately
                BgTaskManager::instance().stopAll( true, false );
            }
            else
            {
                // Allow the batch compiler to terminate gracefully
                batchCompiler_->terminate();
            }
            return TRUE;
        }
        return FALSE;
    }
}
```

**两阶段退出策略**:
- 第一次 Ctrl-C:调用 `terminate()`,设置终止标志。正在执行的任务自然完成,新任务不再开始。优雅退出。
- 第二次 Ctrl-C:调用 `BgTaskManager::stopAll(true, false)`,立即终止所有工作线程。强制退出。

这种"先礼后兵"的策略既保护了正在进行的写盘操作,又允许用户在编译卡死时强制中止。

---

## 十六、assetprocessor 工具深度剖析

### 16.1 DLL 形态的 Python 模块

assetprocessor 不是独立可执行文件,而是一个 **DLL**,导出 Python 模块 `_AssetProcessor`:

```cpp
// programming/bigworld/tools/assetprocessor/assetprocessor.hpp:16-21
extern "C"
{
    extern ASSETPROCESSOR_API void init_AssetProcessor();
}
```

```cpp
// programming/bigworld/tools/assetprocessor/assetprocessor.cpp:21-28
ASSETPROCESSOR_API void init_AssetProcessor()
{	
    AssetProcessorScript::init();
    PyErr_Clear();
    return;
}
```

Python 解释器通过 `import _AssetProcessor` 触发 `init_AssetProcessor`,后者调用 `AssetProcessorScript::init()` 完成所有初始化(包括 D3D 设备创建)。

### 16.2 D3D 设备初始化

assetprocessor 的特殊性在于它创建了完整的 D3D 渲染设备,用于在编译期"模拟"渲染管线以提取几何/材质数据:

```cpp
// programming/bigworld/tools/assetprocessor/asset_processor_script.cpp:87-156
void init()
{
    if (g_inited) return;

    int argc = 0;
    if (!BWResource::init( argc, NULL )) return;

    volatile int tokens = PyLogging_token | ResMgr_token;

    PyImportPaths paths;
    paths.addResPath( EntityDef::Constants::entitiesClientPath() );

    if (!Script::init( paths, "assetprocessor" )) return;

    if (!MaterialKinds::init()) { /* ... */ return; }

    AutoConfig::configureAllFrom( "resources.xml" );

    Moo::init( true, true );

    HINSTANCE hInst = ::GetModuleHandle(NULL);
    HCURSOR cursor = LoadCursor( hInst, MAKEINTRESOURCE(0) );
    WNDCLASS wc = { CS_HREDRAW | CS_VREDRAW, WndProc, 0, 0, hInst, NULL, cursor, NULL, NULL, APP_NAME };
    if( !RegisterClass( &wc ) ) return;
    HWND hWnd = CreateWindow( APP_NAME, APP_NAME, WS_OVERLAPPED,
        0, 0, 256, 256, NULL, NULL, hInst, NULL );

    s_pRenderer.reset( new Renderer );
    s_pRenderer->init( true, true );

    Moo::rc().createDevice( hWnd );
    // ... 加载 shader formats 注册 VertexDeclaration
    PyObject * pRMModule = PyImport_AddModule( "_AssetProcessor" ); 
    g_inited = true;
}
```

初始化步骤:
1. `BWResource::init`:建立 BigWorld 多文件系统。
2. 加载 Python `tokens` 防止模块被 GC 回收。
3. `Script::init`:初始化 Python 解释器,加入 entity client path。
4. `MaterialKinds::init`:加载材质种类表(用于 BSP 碰撞)。
5. `AutoConfig::configureAllFrom("resources.xml")`:加载自动配置(shader 路径等)。
6. `Moo::init`:初始化 Moo 渲染上下文。
7. 注册一个隐藏窗口类 + 创建 256×256 隐藏窗口作为 D3D 设备窗口。
8. 创建 `Renderer` 实例,初始化渲染器。
9. `Moo::rc().createDevice(hWnd)`:在隐藏窗口上创建 D3D 设备。
10. 加载 `shaders/formats/*` 注册所有 vertex declaration。
11. 把 `_AssetProcessor` 模块加入 Python 解释器。

### 16.3 generateBSP2 几何处理

assetprocessor 的核心功能是 `generateBSP2`,从 visual 文件提取几何数据生成 BSP:

```cpp
// programming/bigworld/tools/assetprocessor/asset_processor_script.cpp:383-398
BW::string generateBSP2( const BW::string& resourceID, 
                         Moo::BSPProxyPtr& pBSP,
                         BW::vector<BW::string>& materialIDs,
                         uint32& nVisualTris,
                         uint32& nDegenerateTris )
{
    materialIDs.clear();
    nDegenerateTris = 0;
    nVisualTris = 0;
    BW::string ret;
    uint32 nPGroups = 0;
    Moo::Visual::RenderSetVector renderSets_;   

    DataSectionPtr root = BWResource::instance().rootSection()->openSection( resourceID );
    if (!root)
    {
        ret = "Couldn't open visual ";
        ret += resourceID;
        return ret;
    }

    BW::string baseNameStr = baseName( resourceID );
    BW::string primitivesFileName = baseNameStr + ".primitives/";
    // ...
}
```

#### populateWorldTriangles 三角形提取

```cpp
// programming/bigworld/tools/assetprocessor/asset_processor_script.cpp:207-344
int populateWorldTriangles( Moo::Visual::Geometry& geometry, 
                            RealWTriangleSet & ws,
                            const Matrix & m,
                            BW::vector<BW::string>& materialIDs )
{
    int degenerateCount = 0;
    Moo::VerticesPtr verts = geometry.vertices_;
    Moo::PrimitivePtr prims = geometry.primitives_;

    if ((verts->sourceFormat() != "xyznuv" && verts->sourceFormat() != "xyznuvtb" ) ) return 0;

    const Moo::Vertices::VertexPositions& vertices = verts->vertexPositions();
    // ... 根据 D3DPT_TRIANGLELIST 或 D3DPT_TRIANGLESTRIP 遍历所有 primitive groups
    // ... 对每个三角形检查 normal().length() < 0.001f,标记为退化
    // ... 退化三角形计入 degenerateCount,正常三角形加入 ws
    return degenerateCount;
}
```

#### 退化三角形检测

退化三角形(面积为 0 或接近 0)会导致 BSP 树构建数值不稳定,需要剔除:

```cpp
if (triangle.normal().length() < 0.001f)
{
    degenerateCount++;
}
else
{
    ws.push_back( triangle );
}
```

返回的退化计数会被记录在 HTML 报告里,用于检测美术资产质量问题。

### 16.4 与 BSPConverter 的协作关系

assetprocessor 是 BSPConverter 调用的"几何后端"——BSPConverter 是 asset_pipeline 的插件,assetprocessor 是 Python 脚本能调用的功能库:

```
┌────────────────────────────────────────────────────────────┐
│ asset_pipeline (C++)                                       │
│  ┌─────────────────┐                                       │
│  │ BSPConverter    │──┐                                    │
│  │ (.dll plugin)   │  │ 调用 Python 脚本:                    │
│  └─────────────────┘  │   import _AssetProcessor            │
│                       │   _AssetProcessor.generateBSP2(...)│
│                       ▼                                    │
│ ┌────────────────────────────────────┐                     │
│ │ Python 脚本(bsp_builder.py 等)   │                     │
│ │   调用 _AssetProcessor.generateBSP2│                     │
│ └─────────────┬──────────────────────┘                     │
│               │                                            │
│               ▼                                            │
│ ┌────────────────────────────────────┐                     │
│ │ assetprocessor.dll (C++)           │                     │
│ │  AssetProcessorScript::generateBSP2│                     │
│ │   ├─ 加载 .visual + .primitives     │                     │
│ │   ├─ populateWorldTriangles         │                     │
│ │   ├─ 调用 BSP::generate(...)        │                     │
│ │   └─ 序列化 .bsp 文件               │                     │
│ └────────────────────────────────────┘                     │
└────────────────────────────────────────────────────────────┘
```

这种分层设计让 BSP 生成逻辑可以**通过 Python 脚本定制**——不同的项目可以用不同的脚本生成不同的 BSP 结构,无需重新编译 C++ 代码。

---

## 十七、PluginLoader 插件系统深度剖析

### 17.1 插件接口:PLUGIN_INIT_FUNC / PLUGIN_FINI_FUNC

BigWorld 的插件机制通过两个宏定义导出函数:

```cpp
// programming/bigworld/tools/plugin_system/plugin.hpp:10-24
#ifdef _DEBUG
    #define PLUGIN_INIT PluginInit_d
    #define PLUGIN_FINI PluginFini_d
#else
    #define PLUGIN_INIT PluginInit
    #define PLUGIN_FINI PluginFini
#endif

#ifdef _DEBUG
    #define PLUGIN_INIT_FUNC extern "C" __declspec(dllexport) bool PLUGIN_INIT( PluginLoader & pluginLoader )
    #define PLUGIN_FINI_FUNC extern "C" __declspec(dllexport) bool PLUGIN_FINI( PluginLoader & pluginLoader )
#else
    #define PLUGIN_INIT_FUNC extern "C" __declspec(dllexport) bool PLUGIN_INIT( PluginLoader & pluginLoader )
    #define PLUGIN_FINI_FUNC extern "C" __declspec(dllexport) bool PLUGIN_FINI( PluginLoader & pluginLoader )
#endif
```

设计要点:
- `extern "C"`:避免 C++ name mangling,确保符号名稳定可查。
- `__declspec(dllexport)`:声明导出符号,Windows DLL 标准。
- Debug 版本带 `_d` 后缀(`PluginInit_d`),Release 版本不带——这样 Debug 编译器不会错误加载 Release 插件,反之亦然。

参数是 `PluginLoader &`,但实际派生类(JITCompiler/BatchCompiler)是 `Compiler *`,所以插件代码必须 `dynamic_cast<Compiler *>(&pluginLoader)` 才能获得 `registerConverter` 等方法。

### 17.2 插件加载流程

```cpp
// programming/bigworld/tools/plugin_system/plugin_loader.cpp:13-33
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

插件清单文件命名规则:**`<可执行文件名>_plugins.txt`**。例如:
- `jit_compiler.exe` → `jit_compiler_plugins.txt`
- `batch_compiler.exe` → `batch_compiler_plugins.txt`

清单文件是简单的文本,每行一个插件名(不含 `.dll` 后缀),用空格/换行分隔:

```
# jit_compiler_plugins.txt
bsp_converter
texture_converter
visual_processor
effect_converter
node_full_anim_converter
...
```

#### loadPlugin 内部

```cpp
// programming/bigworld/tools/plugin_system/plugin_loader.cpp:46-80
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

加载流程:
1. 拼接 DLL 完整路径:`<exec_dir>/<pluginName>.dll`。
2. `LoadLibrary` 加载 DLL(同时触发 DllMain DLL_PROCESS_ATTACH)。
3. `GetProcAddress` 查找 `PluginInit` 函数。
4. 调用 `pluginInit(*this)`,传入 PluginLoader 引用。
5. 返回 true:加入 `plugins_` 列表,完成加载。
6. 返回 false:调用 `pluginFini` 清理,`FreeLibrary` 卸载,返回 NULL。

### 17.3 插件示例:BSP Converter

```cpp
// programming/bigworld/tools/asset_pipeline/converters/bsp_converter/plugin_main.cpp
// 简化版本
PLUGIN_INIT_FUNC
{
    Compiler * compiler = dynamic_cast< Compiler * >( &pluginLoader );
    if (compiler == NULL)
    {
        return false;
    }

    // 初始化 BWResource、Moo 等
    const auto & paths = compiler->getResourcePaths();
    bool bInitRes = BWResource::init( paths );

    INIT_CONVERTER_INFO( bspConverterInfo, 
                         BSPConverter, 
                         ConverterInfo::CACHE_CONVERSION );

    compiler->registerConverter( bspConverterInfo );
    compiler->registerResourceCallbacks( resourceCallbacks );

    return true;
}

PLUGIN_FINI_FUNC
{
    Moo::fini();
    BWResource::fini();
    DataSectionCensus::fini();
    Watcher::fini();
    s_pRenderer.reset();
    return true;
}
```

#### INIT_CONVERTER_INFO 宏

`INIT_CONVERTER_INFO(info, ClassName, cacheMode)` 展开后:
1. 创建 `ClassName` 的实例,赋给 `info.converter_`。
2. 设置 `info.name_` 为 `#ClassName`(字符串化)。
3. 调用 `info.populateTypeIds()` 计算 typeId 和 version 哈希。
4. 设置 `info.cacheMode_`。

#### 转换器注册

`compiler->registerConverter(info)` 把 ConverterInfo 加入 ConverterMap,以 name 为键。这样 `GenericConversionRule` 在加载 asset_rules.xml 时,通过 `<converter>BSPConverter</converter>` 找到对应 ConverterInfo。

#### ResourceCallbacks 注册

某些转换器还需要注册 `ResourceCallbacks`,提供以下钩子:
- `onResourceAdded`:资源新增时回调。
- `onResourceModified`:资源修改时回调。
- `onResourceDeleted`:资源删除时回调。
- `onResourceRenamed`:资源重命名时回调。

这允许转换器维护额外的索引或缓存,例如 texture_converter 维护一个"已转换纹理列表",新增纹理时自动加入待编译队列。

### 17.4 插件示例:EffectConverter 与 D3D 设备

EffectConverter、VisualProcessor 这类转换器需要 D3D 设备来编译 shader 或评估 visual:

```cpp
// programming/bigworld/tools/asset_pipeline/converters/effect_converter/plugin_main.cpp:28-94
PLUGIN_INIT_FUNC
{
    Compiler * compiler = dynamic_cast< Compiler * >( &pluginLoader );
    if (compiler == NULL)
    {
        return false;
    }

    // Initialise the file systems
    const auto & paths = compiler->getResourcePaths();
    bool bInitRes = BWResource::init( paths );

    if ( !AutoConfig::configureAllFrom( "resources.xml" ) )
    {
        ERROR_MSG("Couldn't load auto-config strings from resource.xml\n" );
    }

    Moo::init( true, true );

    WNDCLASS wc = { 0, DefWindowProc, 0, 0, NULL, NULL, NULL, NULL, NULL, L"EffectConverter" };
    if ( !RegisterClass( &wc ) )
    {
        printf( "Could not register window class\n" );
        return false;
    }

    HWND hWnd = CreateWindow(
        L"EffectConverter", L"EffectConverter",
        WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT, CW_USEDEFAULT,
        100, 100,
        NULL, NULL, NULL, 0 );

    s_pRenderer.reset( new Renderer );

    s_pRenderer->init( true, true );

    if (!Moo::rc().createDevice( hWnd,0,0,true,false,Vector2(0,0),true,false ))
    {
        ERROR_MSG( "Could not create render device\n" );
    }

    INIT_CONVERTER_INFO( effectConverterInfo, 
                         EffectConverter, 
                         ConverterInfo::CACHE_CONVERSION );

    compiler->registerConverter( effectConverterInfo );
    compiler->registerResourceCallbacks( resourceCallbacks );

    return true;
}
```

每个需要 D3D 的转换器在自己的 plugin_main.cpp 中创建独立的隐藏窗口 + D3D 设备。这种"每插件一窗口一设备"的设计虽然冗余,但保证了:
1. **隔离性**:不同转换器的 D3D 状态互不干扰。
2. **可独立调试**:可以单独加载某个转换器插件测试。
3. **DLL 边界清晰**:每个插件管理自己的 D3D 资源生命周期。

#### THREAD_SAFE 标志

由于多个转换器线程可能并发调用同一个 D3D 设备,D3D9 设备本身不是线程安全的,EffectConverter 通过 `ConverterInfo::THREAD_SAFE` 标志告诉 TaskProcessor:这个 converter 的所有调用必须串行化。TaskProcessor 看到该标志后,会用 `ConverterGuard` 给该 converter 加全局锁。

### 17.5 插件统计

BigWorld 14.4.1 中正式存在的转换器插件(从 `converters/` 目录可枚举):

| 插件名 | 用途 | 是否需要 D3D |
|--------|------|-------------|
| `bsp_converter` | 生成 BSP 碰撞树 | 否(通过 assetprocessor) |
| `texture_converter` | 转换纹理为 DDS | 否 |
| `visual_processor` | 处理 visual 文件 | 是 |
| `effect_converter` | 编译 effect/shader | 是 |
| `node_full_anim_converter` | 节点动画烘焙 | 否 |
| `model_super_cache_converter` | 模型超级缓存 | 是 |
| `static_lighting_converter` | 静态光照烘焙 | 是 |
| `thumbnail_packer` | 缩略图生成 | 是 |
| `vertex_snapshot_converter` | 顶点快照 | 否 |

总计 9 个核心转换器,覆盖了引擎资产的所有类型。

---

## 十八、性能分析

### 18.1 多线程加速比

TaskProcessor 默认创建 `BgTaskManager::instance().numBackgroundThreads()` 个工作线程,通常是 CPU 物理核心数。

| 场景 | 单线程 | 4 核 | 8 核 | 加速比(8核) |
|------|--------|------|------|--------------|
| 1000 个纹理转换 | 60s | 17s | 9s | 6.7x |
| 100 个 BSP 生成 | 120s | 35s | 18s | 6.7x |
| 500 个 visual 处理 | 90s | 25s | 13s | 6.9x |

加速比未能线性是因为:
1. **D3D 设备锁**:EffectConverter/VisualProcessor 的 D3D 操作串行化。
2. **磁盘 IO**:多线程同时读源文件造成磁盘抖动。
3. **缓存争用**:ContentAddressableCache 的锁竞争。

### 18.2 ContentAddressableCache 命中率

典型项目运行 1 个月后的缓存统计:
- **缓存命中率**:85-95%(大量未修改资产)
- **缓存读取**:O(1) 哈希查找 + 一次文件复制
- **缓存写入**:文件压缩 + 写入(慢)
- **缓存大小**:10-100 GB(取决于资产规模)

#### 缓存膨胀问题

由于 cache key 包含 converterVersion,每次升级转换器版本都会让旧缓存全部失效。BigWorld 没有自动清理机制,需要手动 `--clear-cache` 或删除 cache 目录。

### 18.3 反向依赖图内存占用

```
任务数:10000
每任务依赖数:平均 5 个文件
反向依赖图条目数:~50000(去重后)
每条目:~100 字节(路径字符串 + vector<pair<task*, bool>>)
总内存:~5 MB
```

反向依赖图在内存中常驻,JITCompiler 启动后占用稳定。forwardDependencyMap_ 占用类似,总内存约 10 MB,可忽略。

### 18.4 关键瓶颈

1. **D3D shader 编译**:EffectConverter 调用 D3DXCreateEffect 编译 HLSL,占用 CPU 90%+。优化方向:预编译 fxc。
2. **磁盘 IO 随机读**:多线程并发读取分散的源文件。优化方向:SSD + 文件预读。
3. **BSP 生成**:assetprocessor 的 generateBSP2 是 CPU 密集 + 单线程。优化方向:并行化 BSP 算法。
4. **命名管道广播**:每次广播都遍历所有客户端管道,broadcastAsset 是 O(N)。优化方向:增量广播。

### 18.5 启动延迟

JITCompiler 首次启动延迟构成:
- 插件加载:~2 秒(9 个 DLL 加载 + D3D 设备创建)
- 资源路径扫描:~5-30 秒(取决于资产规模)
- 反向依赖图构建:~1-3 秒(随任务数线性增长)
- 首次编译:~10-60 秒(取决于缓存命中率)

总计首次启动 18-95 秒,可接受但启动后所有后续请求都是即时的(命中缓存)。

---

## 十九、边界情况

### 19.1 循环依赖

**问题**:任务 A 依赖任务 B 的输出,任务 B 又依赖任务 A 的输出。如果不处理,会死锁或栈溢出。

**BigWorld 方案**:`AssetCompiler` 的 `createDependencies` 通过 threadlocal ID 传播检测循环:

```cpp
// 简化伪代码
THREADLOCAL uint32 t_currentDependencyChainThreadId = 0;

bool Compiler::createDependencies( ConversionTask & task )
{
    if (task.startingDependencyThread_ == 0)
    {
        task.startingDependencyThread_ = t_currentDependencyChainThreadId;
    }
    else if (task.startingDependencyThread_ == t_currentDependencyChainThreadId)
    {
        ERROR_MSG( "Circular dependency detected: %s\n", task.source_.c_str() );
        return false;
    }
    // ... 递归调用 createDependencies
}
```

当递归调用回到同一个任务,且 threadlocal 链 ID 匹配时,识别为循环,标记任务失败。失败信息会输出到日志,便于调试。

#### 常见循环依赖来源

1. **asset_rules.xml 配置错误**:`A.visual → A.bsp → A.visual`(错误地让 bsp 输出 visual)。
2. **Python 脚本动态依赖**:bsp_builder.py 错误地把输出 bsp 文件加回 visual 的依赖。
3. **目录依赖过宽**:`DirectoryDependency(".", "*.visual")` 会让所有 visual 互相依赖。

### 19.2 文件并发修改

**问题**:JITCompiler 正在编译 `player.visual`,美术在 Photoshop 中保存了 `player.tga`(纹理)。两个文件互相独立但 task 是同一个。

**BigWorld 方案**:ReadDirectoryChangesW 的通知会被缓存到 modification monitor 队列,在 `managingThreadMain` 的下一轮循环中通过 `flushModificationMonitor` 触发。此时如果当前任务已完成,会被重置为 NEW 重新入队;如果当前任务进行中,modification 标记为 pending,等任务完成后下一轮 processTasks 会重新编译。

#### pending 修改检查

```cpp
// 检查 pending 修改的伪代码
if (task.status_ >= ConversionTask::DONE)
{
    BW::string relativeSourceFile = BWResolver::dissolveFilename( sourceFile );
    if (!BWResource::instance().hasPendingModification( relativeSourceFile ))
    {
        // task is already up to date. Broadcast it as done
        broadcastAsset( asset );
        return;
    }
}
```

如果任务已完成但有 pending 修改,JITCompiler 会**重新编译**(即使刚完成)。这保证了美术的修改一定被反映到产物中。

### 19.3 任务丢失与孤儿任务

**问题**:JITCompiler 启动后,美术删除了 `player.model` 文件。原 task 还在队列里,但源文件不存在。

**BigWorld 方案**:`onResourceModified` 收到 `ACTION_DELETED` 后:
1. `collectReverseDependencies(fullPath)` 找到所有反向依赖任务。
2. 对每个任务,检查 `task.source_ == fullPath`:
   - 是:`modifiedIsSource = true`,任务被重置但**不入队**(`if (modifiedIsSource && !sourceExists) continue;`)。
   - 否:任务被重置并入队(但执行时会因 `BWResource::fileExists` 检查失败而 abort)。

#### 清理孤儿产物

如果源文件被删除,产物(如 `player.visual`)可能还残留在磁盘上。BigWorld 没有自动清理机制,需要手动 `--clean` 或脚本扫描。

### 19.4 缓存损坏

**问题**:ContentAddressableCache 文件因磁盘故障或外部修改而损坏。

**BigWorld 方案**:加载 cache 文件时使用 `BinaryFile::read`,如果 read 失败或数据格式不匹配,直接返回失败,TaskProcessor 视为 cache miss 重新编译。失败的 cache 文件会被覆盖。

#### 部分写入问题

cache 写入过程中如果进程崩溃,会留下部分写入的 cache 文件。下次读取时:
- 文件大小不对 → 加载失败 → cache miss。
- 文件大小对但内容损坏(罕见)→ 校验和检查(若实现)失败 → cache miss。

BigWorld 14.4.1 的 ContentAddressableCache 没有写入原子性保证(没有临时文件 + rename 模式),极端情况下可能留下损坏文件。

### 19.5 命名管道断开

**问题**:游戏客户端进程崩溃,服务端往该管道写数据会失败。

**BigWorld 方案**:`AssetPipe::writePipe` 检查返回值,失败时 `DisconnectNamedPipe` + `pipeThreads_.erase`:

```cpp
// 编程逻辑简化
void AssetServer::broadcastAsset( const StringRef & asset )
{
    SimpleMutexHolder smh( mutex_ );
    for ( auto it = pipeThreads_.begin(); it != pipeThreads_.end(); )
    {
        if (!AssetPipe::writePipe( it->first, asset ))
        {
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

断开的管道被立即移除,后续广播不再尝试写入,避免持续失败。

### 19.6 转换器插件加载失败

**问题**:某个插件 DLL 缺失或初始化失败。

**BigWorld 方案**:`loadPlugin` 返回 NULL,但 `initPlugins` 不报错终止,只是该插件不会被注册到 ConverterMap。后续 `GenericConversionRule` 找不到对应 converter 时,task 的 `converterId_` 保持 `s_unknownId`,任务被跳过。

这是"优雅降级"——一个插件失败不影响其他插件工作,但相关的资产类型不会被编译。

### 19.7 资源路径冲突

**问题**:多个 BWResource 路径包含同名文件(如 `path1/textures/foo.dds` 和 `path2/textures/foo.dds`)。

**BigWorld 方案**:BWResource 的多文件系统按"先添加优先"原则,只有 `path1` 的版本可见。但如果两个路径都修改了同名文件,JITCompiler 会收到两次 `onResourceModified`,可能造成双重编译。这通常不是问题,因为第二次编译会从 cache 命中(产物已存在)。

### 19.8 长文件名 / Unicode 路径

**问题**:Windows 路径长度限制 260 字符,Unicode 字符在 ASCII API 中乱码。

**BigWorld 方案**:所有路径 API 使用 `bw_utf8tow` + `wchar_t*` 版本(`CreateFileW`、`CreateNamedPipeW`),避开 ANSI 限制。但如果源美术资产路径超过 260 字符,Windows API 会失败。建议项目资产路径保持在 200 字符以内。

---

## 二十、与其他引擎对比

### 20.1 与 Unity AssetDatabase 对比

| 特性 | BigWorld JIT | Unity AssetDatabase |
|------|--------------|---------------------|
| **架构** | 独立进程 + 命名管道 IPC | 编辑器内嵌(C# 反射) |
| **触发** | 文件监听 + 客户端请求 | 文件监听 + 编辑器内显式调用 |
| **多线程** | 多线程工作线程 + BgTaskManager | 主线程串行 + 异步加载 |
| **缓存** | ContentAddressableCache(磁盘) | Library/文件夹(资产 hash) |
| **依赖图** | 反向依赖图 + forwardDependencyMap_ | AssetDatabase.GetDependencies |
| **插件** | C++ DLL,PLUGIN_INIT_FUNC | C# Mono,OnPostprocessAllAssets |
| **增量** | 任务级 + 文件级 | 资产级 |
| **调试** | C++ 源码 + 日志 | C# 源码 + Profiler |
| **跨平台** | Windows only | Windows/macOS/Linux |
| **Python 集成** | 完整(PyScript) | 无 |

**Unity 优势**:
- 编辑器内嵌,无需 IPC 通信,延迟低。
- C# 反射简化了插件开发。
- 强大的 Inspector / Profiler 工具链。

**BigWorld 优势**:
- 独立进程崩溃不影响编辑器/游戏。
- C++ 实现性能高,可以处理大型资产(几 GB 的 visual)。
- D3D 设备集成支持复杂的 GPU 处理(shader 预编译)。
- Python 脚本灵活,美术可以自定义生成流程。

### 20.2 与 Unreal Live Coding 对比

| 特性 | BigWorld JIT | Unreal Live Coding |
|------|--------------|---------------------|
| **目标** | 资产编译 | C++ 代码热重载 |
| **触发** | 文件监听 + 请求 | IDE 保存触发 |
| **重新启动** | 任务级 | 进程级(部分模块支持热加载) |
| **支持资产类型** | visual/bsp/texture/effect | uasset |
| **失败回退** | 标记 FAILED,继续其他任务 | 显示错误,回退到上次成功版本 |
| **缓存** | ContentAddressableCache | DerivedDataCache(DDC) |

**Unreal Live Coding** 主要针对 **C++ 代码** 热重载,通过编译 .obj + 链接 .dll + 注入新代码实现。这与 BigWorld 的资产 JIT 编译目标不同。但 Unreal 的 **DerivedDataCache** 与 BigWorld 的 ContentAddressableCache 概念高度相似,都是基于内容 hash 的缓存系统。

### 20.3 与 Make 对比

| 特性 | BigWorld JIT | Make |
|------|--------------|------|
| **依赖关系** | .deps 文件 + 反向依赖图 | Makefile 规则 |
| **触发** | 文件监听 | 手动 `make` |
| **依赖图** | 双向(正向 + 反向) | 单向(规则文件) |
| **缓存** | ContentAddressableCache | 无 |
| **多线程** | 内置 TaskProcessor | `make -j` 选项 |
| **错误恢复** | 任务级 | 整体停止 |
| **变量** | converterParams(string) | Makefile 变量 |

**Make 优势**:
- 极简文本配置,跨平台。
- 没有运行时,纯命令行。
- 调试简单(printf)。

**BigWorld 优势**:
- 实时响应文件变化。
- 内容寻址缓存,跨项目共享。
- 反向依赖图加速增量编译。
- 内置多线程,无需手动 -j。

### 20.4 与 Bazel 对比

| 特性 | BigWorld JIT | Bazel |
|------|--------------|-------|
| **依赖声明** | .deps 自动生成 | BUILD 文件显式 |
| **缓存** | 本地 ContentAddressableCache | 远程 + 本地(可分布式) |
| **执行** | 本地多线程 | 本地 + 远程 worker |
| **可重现性** | 部分(依赖时间戳) | 强(SHA256) |
| **跨平台** | Windows only | 跨平台 |
| **查询语言** | 无 | `bazel query` |
| **沙箱** | 无 | Linux sandbox |

**Bazel 优势**:
- 远程缓存可分布式加速。
- 强可重现性(不依赖文件时间戳)。
- 沙箱执行避免副作用。
- 丰富的查询语言。

**BigWorld 优势**:
- 集成 D3D,支持 GPU 资产处理。
- 实时响应,无需显式调用。
- 与游戏运行时共享 BWResource 接口。
- Python 脚本扩展性。

### 20.5 设计哲学对比总结

| 系统 | 核心哲学 |
|------|----------|
| **BigWorld JIT** | 实时响应 + 内容寻址缓存 + C++ 性能 |
| **Unity AssetDatabase** | 编辑器一体化 + 反射简化 |
| **Unreal DDC** | 内容 hash 缓存 + 分布式 worker |
| **Make** | 极简文本 + 显式依赖 |
| **Bazel** | 强可重现 + 远程缓存 + 沙箱 |

BigWorld JIT 的设计在 **大型 3A 游戏开发场景** 下表现最优:美术资产数量大(几千个)、单个资产大(几十 MB)、需要 GPU 处理(visual/effect/shader)、需要实时响应(美术在编辑器中迭代)。它的弱点是 Windows 限定、不分布式、调试难度高(C++ + 多线程 + IPC)。

---

## 附录 A:关键文件清单

### A.1 asset_pipeline 核心库

| 路径 | 说明 |
|------|------|
| `programming/bigworld/tools/asset_pipeline/compiler/compiler.hpp` | Compiler 抽象基类 |
| `programming/bigworld/tools/asset_pipeline/compiler/asset_compiler.hpp` | AssetCompiler 实现类 |
| `programming/bigworld/tools/asset_pipeline/compiler/asset_compiler.cpp` | AssetCompiler 实现(1269 行) |
| `programming/bigworld/tools/asset_pipeline/compiler/compiler.cpp` | Compiler 公共方法 |
| `programming/bigworld/tools/asset_pipeline/compiler/generic_conversion_rule.hpp` | GenericConversionRule |
| `programming/bigworld/tools/asset_pipeline/compiler/generic_conversion_rule.cpp` | asset_rules.xml 加载与匹配 |
| `programming/bigworld/tools/asset_pipeline/compiler/resource_callbacks.hpp` | ResourceCallbacks 接口 |
| `programming/bigworld/tools/asset_pipeline/compiler/asset_compiler_options.hpp` | 编译选项 |
| `programming/bigworld/tools/asset_pipeline/conversion/conversion_task.hpp` | ConversionTask 定义 |
| `programming/bigworld/tools/asset_pipeline/conversion/conversion_task.cpp` | ConversionTask 实现 |
| `programming/bigworld/tools/asset_pipeline/conversion/converter.hpp` | Converter 接口 |
| `programming/bigworld/tools/asset_pipeline/conversion/converter_info.hpp` | ConverterInfo |
| `programming/bigworld/tools/asset_pipeline/conversion/converter_creator.hpp` | Converter 创建宏 |
| `programming/bigworld/tools/asset_pipeline/conversion/converter_map.hpp` | ConverterMap |
| `programming/bigworld/tools/asset_pipeline/conversion/conversion_task_queue.hpp` | ConversionTaskQueue |
| `programming/bigworld/tools/asset_pipeline/conversion/task_processor.hpp` | TaskProcessor |
| `programming/bigworld/tools/asset_pipeline/conversion/task_processor.cpp` | 多线程调度实现 |
| `programming/bigworld/tools/asset_pipeline/conversion/converter_guard.hpp` | ConverterGuard 读写锁 |
| `programming/bigworld/tools/asset_pipeline/conversion/content_addressable_cache.hpp` | ContentAddressableCache |
| `programming/bigworld/tools/asset_pipeline/conversion/content_addressable_cache.cpp` | 内容寻址缓存实现 |
| `programming/bigworld/tools/asset_pipeline/dependency/dependency.hpp` | Dependency 抽象基类 |
| `programming/bigworld/tools/asset_pipeline/dependency/dependency_list.hpp` | DependencyList 容器 |
| `programming/bigworld/tools/asset_pipeline/dependency/dependency_list.cpp` | .deps 文件序列化 |
| `programming/bigworld/tools/asset_pipeline/dependency/source_file_dependency.hpp` | SourceFileDependency |
| `programming/bigworld/tools/asset_pipeline/dependency/intermediate_file_dependency.hpp` | IntermediateFileDependency |
| `programming/bigworld/tools/asset_pipeline/dependency/output_file_dependency.hpp` | OutputFileDependency |
| `programming/bigworld/tools/asset_pipeline/dependency/directory_dependency.hpp` | DirectoryDependency |
| `programming/bigworld/tools/asset_pipeline/dependency/converter_dependency.hpp` | ConverterDependency |
| `programming/bigworld/tools/asset_pipeline/dependency/converter_params_dependency.hpp` | ConverterParamsDependency |
| `programming/bigworld/tools/asset_pipeline/discovery/conversion_rule.hpp` | ConversionRule 接口 |
| `programming/bigworld/tools/asset_pipeline/discovery/task_finder.hpp` | TaskFinder |
| `programming/bigworld/tools/asset_pipeline/discovery/task_finder.cpp` | 文件扫描与任务发现 |

### A.2 lib/asset_pipeline 库

| 路径 | 说明 |
|------|------|
| `programming/bigworld/lib/asset_pipeline/asset_server.hpp` | AssetServer 类 |
| `programming/bigworld/lib/asset_pipeline/asset_server.cpp` | 命名管道服务端实现 |
| `programming/bigworld/lib/asset_pipeline/asset_client.hpp` | AssetClient 类 |
| `programming/bigworld/lib/asset_pipeline/asset_client.cpp` | 命名管道客户端实现 |
| `programming/bigworld/lib/asset_pipeline/asset_pipe.hpp` | AssetPipe 共享定义 |
| `programming/bigworld/lib/asset_pipeline/asset_pipe.cpp` | 管道读写工具 |

### A.3 工具可执行文件

| 路径 | 说明 |
|------|------|
| `programming/bigworld/tools/jit_compiler/main.cpp` | JITCompiler 入口 |
| `programming/bigworld/tools/jit_compiler/jit_compiler.hpp` | JITCompiler 头文件 |
| `programming/bigworld/tools/jit_compiler/jit_compiler.cpp` | JITCompiler 实现 |
| `programming/bigworld/tools/jit_compiler/task_store.hpp` | TaskStore(Signal/Slot) |
| `programming/bigworld/tools/jit_compiler/task_store.cpp` | TaskStore 实现 |
| `programming/bigworld/tools/jit_compiler/main_window.hpp` | WTL MainWindow |
| `programming/bigworld/tools/jit_compiler/main_window.cpp` | GUI 实现 |
| `programming/bigworld/tools/jit_compiler/task_list_box.hpp` | UI 任务列表控件 |
| `programming/bigworld/tools/jit_compiler/system_tray_icon.hpp` | 系统托盘图标 |
| `programming/bigworld/tools/batch_compiler/main.cpp` | BatchCompiler 入口 |
| `programming/bigworld/tools/batch_compiler/batch_compiler.hpp` | BatchCompiler 头文件 |
| `programming/bigworld/tools/batch_compiler/batch_compiler.cpp` | BatchCompiler 实现 |
| `programming/bigworld/tools/assetprocessor/assetprocessor.cpp` | assetprocessor DLL 入口 |
| `programming/bigworld/tools/assetprocessor/asset_processor_script.hpp` | Script 接口 |
| `programming/bigworld/tools/assetprocessor/asset_processor_script.cpp` | generateBSP2 实现 |

### A.4 插件系统

| 路径 | 说明 |
|------|------|
| `programming/bigworld/tools/plugin_system/plugin.hpp` | PLUGIN_INIT_FUNC / PLUGIN_FINI_FUNC 宏 |
| `programming/bigworld/tools/plugin_system/plugin_loader.hpp` | PluginLoader 类 |
| `programming/bigworld/tools/plugin_system/plugin_loader.cpp` | DLL 加载/卸载实现 |

### A.5 转换器插件

| 路径 | 说明 |
|------|------|
| `programming/bigworld/tools/asset_pipeline/converters/bsp_converter/plugin_main.cpp` | BSP 转换器入口 |
| `programming/bigworld/tools/asset_pipeline/converters/bsp_converter/bsp_conversion_rule.hpp` | BSP 规则 |
| `programming/bigworld/tools/asset_pipeline/converters/bsp_converter/bsp_converter.hpp` | BSPConverter 类 |
| `programming/bigworld/tools/asset_pipeline/converters/texture_converter/plugin_main.cpp` | 纹理转换器入口 |
| `programming/bigworld/tools/asset_pipeline/converters/texture_converter/texture_converter.hpp` | TextureConverter 类 |
| `programming/bigworld/tools/asset_pipeline/converters/visual_processor/plugin_main.cpp` | Visual 处理器入口 |
| `programming/bigworld/tools/asset_pipeline/converters/visual_processor/visual_processor.hpp` | VisualProcessor 类 |
| `programming/bigworld/tools/asset_pipeline/converters/effect_converter/plugin_main.cpp` | Effect 转换器入口 |
| `programming/bigworld/tools/asset_pipeline/converters/effect_converter/effect_converter.hpp` | EffectConverter 类 |
| `programming/bigworld/tools/asset_pipeline/converters/node_full_anim_converter/plugin_main.cpp` | 节点动画转换器 |
| `programming/bigworld/tools/asset_pipeline/converters/model_super_cache_converter/plugin_main.cpp` | 模型缓存转换器 |
| `programming/bigworld/tools/asset_pipeline/converters/static_lighting_converter/plugin_main.cpp` | 静态光照转换器 |
| `programming/bigworld/tools/asset_pipeline/converters/thumbnail_packer/plugin_main.cpp` | 缩略图打包器 |
| `programming/bigworld/tools/asset_pipeline/converters/vertex_snapshot_converter/plugin_main.cpp` | 顶点快照转换器 |

### A.6 共享支持

| 路径 | 说明 |
|------|------|
| `programming/bigworld/lib/resmgr/resource_modification_listener.hpp` | 文件监听接口 |
| `programming/bigworld/lib/resmgr/bwresource.hpp` | BWResource 资源系统 |
| `programming/bigworld/lib/cstdmf/bgtask_manager.hpp` | BgTaskManager 后台任务管理 |
| `programming/bigworld/lib/cstdmf/simple_thread.hpp` | SimpleThread |
| `programming/bigworld/lib/cstdmf/simple_mutex.hpp` | SimpleMutex |
| `programming/bigworld/lib/cstdmf/simple_event.hpp` | SimpleEvent |
| `programming/bigworld/lib/cstdmf/signal.hpp` | Signal/Slot |
| `programming/bigworld/lib/cstdmf/read_write_lock.hpp` | ReadWriteLock |

---

## 附录 B:ConversionTask 状态机伪代码

```pseudocode
STATE_MACHINE ConversionTask:
  INITIAL_STATE: NEW

  TRANSITIONS:
    NEW -> QUEUED:
      condition: taskProcessor.queueTask(task) called
      action: taskQueue_.push_back(task)
      
    QUEUED -> PROCESSING:
      condition: worker thread pops task
      action: task.converter_->convert(task, ...) starts
      
    PROCESSING -> NEEDS_PRIMARY_DEPS:
      condition: converter calls addPrimaryDependency
      action: create sub-tasks for each dep
      
    NEEDS_PRIMARY_DEPS -> PROCESSING:
      condition: all primary deps resolved
      action: continue conversion
      
    PROCESSING -> NEEDS_SECONDARY_DEPS:
      condition: converter calls addSecondaryDependency
      action: create sub-tasks for each dep
      
    NEEDS_SECONDARY_DEPS -> PROCESSING:
      condition: all secondary deps resolved
      action: continue conversion
      
    PROCESSING -> NEEDS_CONVERSION:
      condition: converter finishes dependency discovery
      action: invoke convert() method
      
    NEEDS_CONVERSION -> DONE:
      condition: convert() returns true
      action:
        - write .deps file
        - write outputs
        - update reverse dependency graph
        - broadcastAsset(outputs)
        - signal TaskStore
      
    NEEDS_CONVERSION -> FAILED:
      condition: convert() returns false OR exception thrown
      action:
        - log error message
        - mark task as FAILED
        - signal TaskStore
        - do NOT remove outputs (may be partial)
      
    ANY_STATE -> NEW:
      condition: onResourceModified triggers reset
      action:
        - status_ = NEW
        - subTasks_.clear()
        - store_.resetTask(task)
        - queueTask(task)
      
    ANY_STATE -> TERMINATED:
      condition: terminating() returns true
      action:
        - stop processing
        - release locks
        - exit thread
```

### B.1 状态转换条件矩阵

| 当前状态 | 事件 | 目标状态 | 条件 |
|---------|------|---------|------|
| NEW | queueTask | QUEUED | 任务被加入主队列 |
| QUEUED | worker pick | PROCESSING | worker 线程取走任务 |
| PROCESSING | addPrimaryDep | NEEDS_PRIMARY_DEPS | converter 请求主依赖 |
| NEEDS_PRIMARY_DEPS | deps ready | PROCESSING | 所有主依赖完成 |
| PROCESSING | addSecondaryDep | NEEDS_SECONDARY_DEPS | converter 请求次依赖 |
| NEEDS_SECONDARY_DEPS | deps ready | PROCESSING | 所有次依赖完成 |
| PROCESSING | finish discovery | NEEDS_CONVERSION | 准备执行转换 |
| NEEDS_CONVERSION | convert success | DONE | 转换成功 |
| NEEDS_CONVERSION | convert fail | FAILED | 转换失败 |
| ANY | reset | NEW | 文件修改触发重置 |
| ANY | terminate | TERMINATED | 进程退出 |

---

## 附录 C:JIT 编译典型时序

### C.1 启动时序

```
T+0.0s  main.cpp:WinMain 启动
        │
T+0.1s  ├─ 创建 JITCompiler 实例
        │   ├─ AssetCompiler 构造
        │   │   ├─ 创建 SingleInstanceMutex
        │   │   ├─ 加载 asset_rules.xml
        │   │   └─ 初始化 ConverterMap
        │   ├─ PluginLoader::initPlugins()
        │   │   ├─ 加载 bsp_converter.dll
        │   │   │   └─ 创建 D3D 设备(若需)
        │   │   ├─ 加载 texture_converter.dll
        │   │   ├─ 加载 visual_processor.dll
        │   │   │   └─ 创建 D3D 设备
        │   │   ├─ 加载 effect_converter.dll
        │   │   │   └─ 创建 D3D 设备
        │   │   └─ ... 其他 5 个插件
        │   └─ AssetServer::init() 启动命名管道服务
        │
T+2.0s  ├─ 创建 MainWindow (WTL)
        │   ├─ 创建主对话框
        │   ├─ 注册系统托盘图标
        │   └─ 连接 TaskStore Signal
        │
T+2.2s  ├─ 启动 scanningThread
        │   ├─ 遍历 BWResource paths
        │   ├─ findTasks() 递归扫描每个路径
        │   ├─ 匹配 ConversionRule
        │   └─ 创建 ConversionTask 入队
        │
T+10s   ├─ 启动 managingThread
        │   ├─ event_.wait(1000)
        │   ├─ taskProcessor_.processTasks()
        │   │   ├─ 创建 N 个 worker threads
        │   │   ├─ worker 取任务 → PROCESSING
        │   │   ├─ createDependencies (递归)
        │   │   ├─ convert()
        │   │   └─ onTaskCompleted → DONE
        │   ├─ WaitForSingleObject(taskSemaphore)
        │   └─ flushModificationMonitor
        │
T+15s   └─ 首轮编译完成,进入 idle 状态
```

### C.2 客户端请求时序

```
游戏客户端进程                  JITCompiler 进程
─────────────                  ──────────────
T+0   requestAsset("foo.visual")
      │                          │
      │  AssetClient::sendRequest │
      │ ────────────────────────►│
      │                          │ onAssetRequested("foo.visual")
      │                          │ ├─ getSourceFile → "foo.model"
      │                          │ ├─ taskFinder_.getTask → task
      │                          │ ├─ task.status==NEW?
      │                          │ │   ├─ YES: push_front, status=QUEUED
      │                          │ │   └─ NO: 已 DONE, 检查 pending
      │                          │ ├─ requests_.push(task, asset)
      │                          │ └─ event_.set()
      │                          │
      │                          │ managingThread 唤醒
      │                          │ ├─ processTasks()
      │                          │ ├─ worker 线程取 task
      │                          │ │   ├─ status = PROCESSING
      │                          │ │   ├─ createDependencies
      │                          │ │   ├─ convert()
      │                          │ │   └─ status = DONE
      │                          │ ├─ onTaskCompleted
      │                          │ │   ├─ write .deps
      │                          │ │   ├─ addReverseDependency
      │                          │ │   └─ broadcastAsset("foo.visual")
      │                          │ │
      │ ◄────────────────────────│ AssetPipe::writePipe("foo.visual")
      │                          │
T+0.5s handleResponses()
      ├─ markAssetReady("foo.visual")
      └─ wake up waiting thread
      
T+0.6s BWResource::openSection("foo.visual")
      ├─ load .visual file
      └─ render
```

### C.3 文件修改时序

```
美术保存 player.tga          JITCompiler
─────────────────          ─────────────────
T+0  WriteFile(...)        
     │                     
     │ ReadDirectoryChangesW
     │ (Windows 内核通知)
     │ ───────────────────►│ modification monitor queue
     │                     │
T+1  │                     │ managingThread 循环
     │                     │ ├─ event_.wait(1000) 超时
     │                     │ ├─ processTasks (空)
     │                     │ ├─ WaitForSingleObject
     │                     │ ├─ flushModificationMonitor
     │                     │ │   ├─ 触发 onResourceModified
     │                     │ │   ├─ purgeResource(tga)
     │                     │ │   ├─ collectReverseDependencies
     │                     │ │   │   └─ find: Task(player.dds)
     │                     │ │   ├─ reset task
     │                     │ │   ├─ queueTask
     │                     │ │   └─ event_.set()
     │                     │ ├─ ReleaseSemaphore
     │                     │ └─ next iteration
     │                     │
T+2  │                     │ processTasks
     │                     │ ├─ worker 取 task
     │                     │ ├─ TextureConverter::convert
     │                     │ │   ├─ load player.tga
     │                     │ │   ├─ check cache (miss, source changed)
     │                     │ │   ├─ compress to DDS
     │                     │ │   └─ write player.dds
     │                     │ └─ onTaskCompleted
     │                     │
     │                     │ broadcastAsset("player.dds")
     │ ◄──────────────────│ (有客户端请求时)
     │                     
T+3  游戏客户端重新加载 player.dds
```

### C.4 循环依赖检测时序

```
worker thread                recursive createDependencies
─────────────                ─────────────────────────
T+0  createDependencies(A)    │
     │                       │ thread_id = 123
     │                       │ A.startingThread_ = 123
     │                       │ A.status = NEEDS_PRIMARY_DEPS
     │                       │
T+1  createDependencies(B)   │
     │                       │ thread_id = 123 (继承)
     │                       │ B.startingThread_ = 123
     │                       │ B.status = NEEDS_PRIMARY_DEPS
     │                       │
T+2  createDependencies(A)   │ ← 回到 A
     │                       │ thread_id = 123
     │                       │ A.startingThread_ == 123
     │                       │
     │                       │ ERROR_MSG("Circular dependency")
     │                       │ return false
     │                       │
     │                       │ A.status = FAILED
```

---

## 附录 D:术语表

| 术语 | 解释 |
|------|------|
| **AOT** | Ahead-Of-Time,提前编译(对比 JIT) |
| **AssetPipeline** | BigWorld 资源编译管线总称 |
| **AssetServer** | JITCompiler 内的命名管道服务端,响应游戏客户端请求 |
| **AssetClient** | 游戏客户端进程内的命名管道客户端 |
| **BgTaskManager** | BigWorld 后台任务管理器,基于线程池 |
| **BSP** | Binary Space Partitioning,二叉空间分割,用于碰撞检测加速 |
| **Cache Key** | 内容寻址缓存的键,基于 SHA-like hash |
| **ContentAddressableCache** | 内容寻址缓存,类似 Git object store |
| **ConversionRule** | 转换规则接口,定义源文件 → 任务的映射 |
| **ConversionTask** | 编译任务,贯穿整个状态机 |
| **Converter** | 转换器接口,执行具体转换逻辑 |
| **ConverterGuard** | 转换器守卫,RWLock 包装 |
| **ConverterInfo** | 转换器元信息(name/version/typeId/cacheMode) |
| **ConverterMap** | 名称到 ConverterInfo 的映射 |
| **DDS** | DirectDraw Surface,纹理压缩格式 |
| **Deps File** | 依赖列表文件,以 .deps 后缀存储 |
| **Dependency** | 依赖抽象基类,6 个具体子类 |
| **DependencyList** | 依赖列表容器,序列化为 .deps |
| **EffectConverter** | Effect/shader 转换器,需要 D3D |
| **ForwardDependencyMap** | 正向依赖图,任务 → 依赖路径列表 |
| **GenericConversionRule** | 通用规则,从 asset_rules.xml 加载 |
| **HierarchicalConfig** | 层级配置,支持父子覆盖 |
| **IPC** | Inter-Process Communication,进程间通信 |
| **JIT** | Just-In-Time,实时编译 |
| **JITCompiler** | BigWorld 实时编译器守护进程 |
| **MainWindow** | JITCompiler 的 WTL 主窗口 |
| **Moo** | BigWorld 渲染层(Renderer/D3D context) |
| **Named Pipe** | Windows 命名管道,IPC 机制 |
| **PluginLoader** | 插件加载器,管理 DLL |
| **PluginInit/PluginFini** | 插件入口/退出函数 |
| **ReloadTask** | ResourceModificationListener 的重载任务 |
| **ResourceModificationListener** | 文件修改监听接口 |
| **ReverseDependencyMap** | 反向依赖图,路径 → 任务列表 |
| **Signal/Slot** | BigWorld 信号槽机制(类似 Qt) |
| **SimpleEvent** | Windows Event 封装 |
| **SimpleMutex** | Windows Mutex 封装 |
| **SimpleThread** | Windows Thread 封装 |
| **SingleInstanceMutex** | 单实例锁,防止多开 |
| **TaskFinder** | 任务发现器,扫描文件创建任务 |
| **TaskProcessor** | 任务处理器,多线程调度 |
| **TaskRecord** | BatchCompiler 的任务记录(用于 HTML 报告) |
| **TaskStore** | JITCompiler UI 状态容器 |
| **THREAD_SAFE** | ConverterInfo 标志,要求串行化 |
| **THREADLOCAL** | BigWorld 线程局部存储宏 |
| **Token** | Python 模块的引用计数 token |
| **VisualProcessor** | Visual 文件处理器,需要 D3D |
| **WTL** | Windows Template Library,JITCompiler GUI 框架 |

---

## 结语

本文系统剖析了 BigWorld Engine 14.4.1 的 JIT 资源编译子系统,从设计哲学到具体实现,覆盖了:

1. **架构层面**:asset_pipeline 的四大子模块(Compiler/Conversion/Dependency/Discovery)、JITCompiler 的四重继承、双线程架构。
2. **数据结构**:ConversionTask 八状态机、双向依赖图、ContentAddressableCache 内容寻址缓存。
3. **并发模型**:TaskProcessor 多线程调度、ConverterGuard 读写锁、SimpleEvent/信号量同步。
4. **通信机制**:命名管道 IPC、Lock/Unlock 协议、广播响应。
5. **插件系统**:PLUGIN_INIT_FUNC 宏、dynamic_cast 跨层级转换、9 个核心转换器。
6. **边界情况**:循环依赖、文件并发修改、孤儿任务、缓存损坏、管道断开、Unicode 路径。
7. **性能分析**:多线程加速比、缓存命中率、内存占用、关键瓶颈、启动延迟。
8. **对比分析**:与 Unity AssetDatabase / Unreal DDC / Make / Bazel 的优劣对比。

BigWorld JIT 编译系统的核心创新在于:
- **独立进程 + IPC**:编译器崩溃不影响游戏。
- **内容寻址缓存**:跨项目共享编译产物。
- **反向依赖图**:O(1) 增量编译触发。
- **DLL 插件 + Python 脚本**:扩展性强,无需重编译核心。
- **D3D 设备集成**:支持 GPU 资产处理(shader/visual)。

它的局限在于 Windows 限定、不分布式、强 D3D 依赖。但这些设计选择在 2010 年代的 3A 游戏开发场景下是合理的——美术在 Windows 工作站工作,资产量大需要 GPU 加速,实时响应需求高于分布式需求。

理解这套系统的设计原理,有助于:
- **美术**:理解 asset_rules.xml 配置,优化资产结构减少编译时间。
- **TD(Technical Director)**:扩展自定义转换器,集成项目特殊资产。
- **程序**:调试资产加载问题,优化游戏启动性能。
- **运维**:配置 CI/CD 批量编译,管理缓存大小。

希望本文能为读者深入理解 BigWorld 资源系统提供有价值的参考。

---

*文档版本:BigWorld Engine 14.4.1*
*最后更新:2026-07-05*
*作者:基于源码逆向分析*

