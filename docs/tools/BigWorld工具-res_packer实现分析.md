# BigWorld 工具 res_packer 实现深度分析

> 本文档详细分析 BigWorld Engine 14.4.1 中 `res_packer` 工具的完整实现。`res_packer` 是一个**资源打包/发布工具**,负责将开发态的资源文件(XML、贴图、模型、地形、Chunk、Shader)转换为运行态优化格式,通过 **6 种 Packer 策略(Strategy Pattern)** 按优先级注册并处理不同扩展名的资源。本文档涵盖入口点、命令行解析(兼容模式/批量模式)、BasePacker 抽象基类、PackerFactory 自动注册机制、6 个具体 Packer(XmlPacker/ChunkPacker/CDataPacker/FxPacker/ImagePacker/ModelAnimPacker)的实现细节、PackerHelper 辅助类、`MF_SERVER` 宏控制客户端/服务端行为差异的全部内容。

---

## 目录

- [一、概述与定位](#一概述与定位)
- [二、整体架构](#二整体架构)
- [三、目录结构](#三目录结构)
- [四、入口点 main 启动流程](#四入口点-main-启动流程)
- [五、核心类与继承关系](#五核心类与继承关系)
- [六、Packer 注册机制](#六packer-注册机制)
- [七、6 个 Packer 详细分析](#七6-个-packer-详细分析)
- [八、PackerHelper 辅助工具类](#八packerhelper-辅助工具类)
- [九、CDataPacker 深度剖析](#九cdatapacker-深度剖析)
- [十、配置项与命令行参数](#十配置项与命令行参数)
- [十一、与其他模块的依赖关系](#十一与其他模块的依赖关系)
- [十二、关键代码片段(带行号)](#十二关键代码片段带行号)
- [十三、设计亮点与注意事项](#十三设计亮点与注意事项)
- [附录 A:6 个 Packer 对照表](#附录-a6-个-packer-对照表)
- [附录 B:常见问题澄清](#附录-b常见问题澄清)

---

## 一、概述与定位

### 1.1 工具定位

`res_packer` 是 BigWorld Technology SDK 提供的一个**命令行资源打包工具**。它的核心使命是:

1. 将开发态的资源文件(文本 XML、贴图源文件、模型、地形数据、Chunk、Shader 源码)转换为**运行态优化格式**(二进制 Packed Section、DDS 贴图、压缩动画等);
2. 在打包过程中**剥离**编辑器专用数据、导航网格、缩略图、LOD 数据等运行时不需要的内容;
3. 通过 **6 种 Packer 策略** 分别处理不同扩展名的资源,由 `Packers` 单例按优先级统一调度;
4. 支持两种工作模式:**兼容模式**(单文件处理,老用法)和**批量列表模式**(从 asset list 文件批量处理,新用法);
5. 通过 `MF_SERVER` 宏区分**客户端打包**与**服务端打包**,生成不同的发布产物。

该工具本质上是一个**控制台应用程序**,无 GUI,通过 `printf` 输出处理进度,通过 `SIGINT`/`SIGBREAK` 信号支持中断恢复。

### 1.2 核心特性

| 特性 | 实现方式 | 说明 |
|------|---------|------|
| 策略模式 | `BasePacker` 抽象基类 + 6 个子类 | 每种资源类型对应一个 Packer |
| 优先级注册 | `PackerFactory` 全局对象 + `IMPLEMENT_PACKER` 宏 | 程序启动时自动注册 |
| 文件分派 | `Packers::find()` 遍历调用 `prepare()` | 第一个返回 true 的 Packer 处理 |
| 兜底处理 | `XmlPacker` 设为 `LOWEST_PRIORITY` | 处理所有未识别的 XML 文本文件 |
| 客户端/服务端 | `MF_SERVER` 宏条件编译 | 服务端跳过图形资源 |
| 资源初始化 | `BWResource::init` + `Moo::init` | 客户端需创建 D3D 设备 |
| 批量处理 | asset list 文件 + `--in`/`--out` 路径 | 新的高速模式 |
| 中断恢复 | `SIGINT` 信号处理 + `y/n` 交互确认 | CTRL+C 后询问是否继续 |
| 错误日志 | `--err` 参数写入失败文件列表 | 便于重试 |
| 加密支持 | `--encrypt` 参数 + `XmlPacker::shouldEncrypt` | DDS 也走 XML 打包加密 |

### 1.3 版本与规模

- **总代码规模**: 约 2200 行 C++ 代码(含 6 个 Packer 实现)
- **可执行文件名**: `res_packer.exe`
- **依赖的关键库**: `BWResource`(资源系统)、`Moo`(渲染基础,仅客户端)、`Chunk`(地形块)、`Terrain`(地形系统)、`PackedSection`(二进制段)
- **支持的 OS**: Windows(主)/Linux(部分,服务端可编译)

---

## 二、整体架构

### 2.1 模块组成图

```
┌────────────────────────────────────────────────────────────────────┐
│                      res_packer.exe (控制台)                       │
│                                                                    │
│   ┌──────────────────────┐    ┌──────────────────────────────┐     │
│   │   main (入口)        │───►│   命令行解析 (while 循环)    │     │
│   │   main.cpp L217      │    │   main.cpp L259-339          │     │
│   └──────────────────────┘    └──────────┬───────────────────┘     │
│            │                              │                         │
│            ├── 兼容模式 (单文件)         ├── 批量列表模式           │
│            │   L481-548                   │   L354-480              │
│            │                              │                         │
│            ▼                              ▼                         │
│   ┌──────────────────────────────────────────────────────────┐     │
│   │              Packers 单例 (分派器)                       │     │
│   │              packers.cpp L7 instance()                   │     │
│   │              - add(packer, priority)  L13                │     │
│   │              - find(src, dst)         L28                │     │
│   └────────────────────────────┬─────────────────────────────┘     │
│                                │ prepare(src,dst) 返回 true        │
│                                ▼                                    │
│   ┌──────────────────────────────────────────────────────────┐     │
│   │              BasePacker 抽象基类 (base_packer.hpp L9)    │     │
│   │              - prepare() / print() / pack()              │     │
│   └────────────────────────────┬─────────────────────────────┘     │
│                                │ 继承                               │
│   ┌──────────┬──────────┬──────┴───────┬──────────┬──────────┐    │
│   │ XmlPacker│ChunkPack │CDataPacker   │FxPacker  │ImagePack │    │
│   │ LOWEST   │ HIGHEST  │ HIGHEST      │ HIGHEST  │ HIGHEST  │    │
│   │ PRIORITY │          │              │          │          │    │
│   └──────────┴──────────┴──────────────┴──────────┴──────────┘    │
│                                │                                    │
│                                │ ModelAnimPacker                    │
│                                │ HIGHEST                            │
│                                └────────────┐                       │
│   ┌──────────────────────────────────────────┘                      │
│   │                                                                  │
│   │   ┌──────────────────────┐    ┌──────────────────────────────┐ │
│   │   │ PackerHelper         │    │ MsgHandler                   │ │
│   │   │ (静态工具类)         │    │ (BW 库消息→cout)             │ │
│   │   │ - initResources      │    │                              │ │
│   │   │ - initMoo (D3D)      │    │                              │ │
│   │   │ - copyFile           │    │                              │ │
│   │   └──────────────────────┘    └──────────────────────────────┘ │
└────────────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌────────────────────────────────────────────────────────────────────┐
│                      BigWorld 核心库                                │
│   ┌─────────────────┐  ┌──────────────┐  ┌──────────────────────┐ │
│   │ BWResource      │  │ PackedSection│  │ Moo (D3D, 仅客户端)  │ │
│   │ (资源路径管理)  │  │ (二进制压缩) │  │ - TextureManager     │ │
│   └─────────────────┘  └──────────────┘  │ - Renderer           │ │
│                                          └──────────────────────┘ │
│   ┌─────────────────┐  ┌──────────────┐  ┌──────────────────────┐ │
│   │ Chunk           │  │ Terrain      │  │ Model                │ │
│   │ (地形块)        │  │ (地形系统)   │  │ (模型/动画)          │ │
│   └─────────────────┘  └──────────────┘  └──────────────────────┘ │
└────────────────────────────────────────────────────────────────────┘
```

### 2.2 工作流程图

```
命令行: res_packer --list assets.txt --in /src --out /dst --err err.log
                │
                ▼
        main() L217 入口
                │
                ▼
   ┌────────────────────────────┐
   │ setSignalHandler()         │  注册 SIGINT/SIGBREAK
   │ MsgHandler msgHandler      │  消息重定向
   │ ScopedWriteToConsole       │  RAII 控制台输出
   └────────────┬───────────────┘
                │
                ▼
   ┌────────────────────────────┐
   │ 命令行解析 while 循环      │  L259-339
   │ --list / --in / --out /    │
   │ --err / --res / --encrypt /│
   │ --strip                    │
   └────────────┬───────────────┘
                │
                ▼
   ┌────────────────────────────┐
   │ 参数校验 L342              │
   │ (list 模式需 in+out)       │
   │ (兼容模式需 1-3 个位置参数)│
   └────────────┬───────────────┘
                │
        ┌───────┴───────┐
        ▼               ▼
   批量列表模式    兼容模式
   L354-480        L481-548
        │               │
        ▼               ▼
   ┌────────────────────────────┐
   │ PackerHelper::initResources│  BWResource 初始化
   │ PackerHelper::initMoo      │  D3D 设备(客户端)
   │ MaterialKinds::init        │  材质种类(客户端)
   └────────────┬───────────────┘
                │
                ▼
   ┌────────────────────────────┐
   │ 对每个文件:                │
   │ Packers::find(src,dst)     │  L399/L514
   │   遍历所有 Packer           │
   │   调用 prepare(src,dst)     │
   │   返回第一个 true 的 Packer │
   └────────────┬───────────────┘
                │
        ┌───────┴───────┐
        ▼               ▼
   packer==NULL     packer!=NULL
   未知类型         已识别
        │               │
        ▼               ▼
   copyFile         packer->pack()
   直接复制         按策略处理
                │
                ▼
   ┌────────────────────────────┐
   │ 失败计数 / 错误日志写入    │
   │ SIGINT 检查 (y/n 继续)     │
   └────────────────────────────┘
                │
                ▼
        清理资源 (Moo::fini / BWResource::fini)
        返回 EXIT_SUCCESS / EXIT_FAILURE
```

### 2.3 Packer 优先级与分派流程

```
文件: xxx.chunk
                │
                ▼
   Packers::find() 遍历 packers_ (按 priority 升序)
                │
   ┌────────────┼────────────────────────────────────┐
   │ priority=0 │ priority=0      │ ... │ priority=0xFFFF│
   │ ChunkPacker│ CDataPacker     │     │ XmlPacker      │
   │ prepare()  │ prepare()       │     │ prepare()      │
   │ ext==chunk?│ ext==cdata?     │     │ 是 XML 文本?   │
   │ ✓ true     │ ✗ false         │     │ (未到此处)     │
   └────────────┴─────────────────┘     └────────────────┘
                │
                ▼
   返回 ChunkPacker* → 调用 packer->pack()
```

---

## 三、目录结构

### 3.1 源码目录

```
programming/bigworld/tools/res_packer/
├── main.cpp                 (564 行)  入口、命令行解析、两种模式分派
├── base_packer.hpp          ( 31 行)  BasePacker 抽象基类
├── packers.hpp              ( 59 行)  Packers 单例 + PackerFactory + 宏
├── packers.cpp              ( 40 行)  Packers 单例实现 (add/find)
├── packer_helper.hpp        ( 92 行)  PackerHelper 静态工具类声明
├── packer_helper.cpp        (254 行)  PackerHelper 实现 (资源/Moo 初始化)
├── config.hpp               (  3 行)  Shader 打包开关宏
├── msg_handler.hpp          (  - )    MsgHandler 声明
├── msg_handler.cpp          (  - )    BW 库消息→cout 重定向
├── xml_packer.hpp           ( 53 行)  XmlPacker 声明 (LOWEST_PRIORITY)
├── xml_packer.cpp           (117 行)  XmlPacker 实现 (兜底 XML 打包)
├── chunk_packer.hpp         (  - )    ChunkPacker 声明
├── chunk_packer.cpp         (113 行)  ChunkPacker 实现 (.chunk 处理)
├── cdata_packer.hpp         ( 44 行)  CDataPacker 声明 (最复杂)
├── cdata_packer.cpp         (395 行)  CDataPacker 实现 (LOD/地形剥离)
├── fx_packer.hpp            (  - )    FxPacker 声明
├── fx_packer.cpp            ( 89 行)  FxPacker 实现 (Shader 文件)
├── image_packer.hpp         (  - )    ImagePacker 声明
├── image_packer.cpp         (184 行)  ImagePacker 实现 (贴图/DDS)
└── model_anim_packer.cpp    (124 行)  ModelAnimPacker 实现 (模型/动画)
```

### 3.2 文件分类

| 类别 | 文件 | 行数 | 职责 |
|------|------|------|------|
| **入口与分派** | main.cpp | 564 | 命令行解析、模式选择、资源初始化 |
| **框架核心** | base_packer.hpp | 31 | 抽象基类定义 |
| **框架核心** | packers.hpp/cpp | 99 | 单例调度器 + 工厂 + 注册宏 |
| **辅助工具** | packer_helper.hpp/cpp | 346 | 资源/Moo 初始化、文件复制 |
| **辅助工具** | msg_handler.* | - | 消息重定向到 stdout |
| **配置** | config.hpp | 3 | Shader 打包开关 |
| **具体 Packer** | xml_packer.* | 170 | XML→PackedSection(兜底) |
| **具体 Packer** | chunk_packer.* | 113 | .chunk 实体剥离 |
| **具体 Packer** | cdata_packer.* | 439 | .cdata 地形 LOD 剥离(最复杂) |
| **具体 Packer** | fx_packer.* | 89 | .fx/.fxh/.fxo Shader |
| **具体 Packer** | image_packer.* | 184 | 贴图/DDS 字体检测 |
| **具体 Packer** | model_anim_packer.* | 124 | .model/.animation/.anca |

---

## 四、入口点 main 启动流程

### 4.1 main 函数签名与位置

`main.cpp` 第 217 行定义了标准的 C/C++ 入口:

```cpp
// main.cpp L217
int main( int argc, char *argv[] )
{
    BW_SYSTEMSTAGE_MAIN();
    // ...
}
```

### 4.2 Packer Token 注册(L38-51)

在 `main` 函数之前,通过全局静态变量的初始化确保 6 个 Packer 被链接进可执行文件:

```cpp
// main.cpp L37-51
// Packer tokens to ensure that they get compiled
extern int XmlPacker_token;
extern int ImagePacker_token;
extern int FxPacker_token;
extern int ChunkPacker_token;
extern int CDataPacker_token;
extern int ModelAnimPacker_token;
static int s_chunkTokenSet = 0
    | XmlPacker_token
    | ImagePacker_token
    | FxPacker_token
    | ChunkPacker_token
    | CDataPacker_token
    | ModelAnimPacker_token
    ;
```

**说明**:BigWorld 使用 `*_token` 全局变量机制防止链接器在静态库链接时丢弃未直接引用的对象。每个 Packer 的 `.cpp` 中会定义 `int XxxPacker_token = 0;`,同时通过 `IMPLEMENT_PACKER` 宏创建一个 `PackerFactory` 全局对象,该对象在 `main` 之前调用 `Packers::add()` 完成注册。`s_chunkTokenSet` 通过 `|` 运算"使用"这些 token,确保链接器不会优化掉对应的 `.o` 文件。

### 4.3 main 函数执行步骤

| 步骤 | 行号 | 操作 | 说明 |
|------|------|------|------|
| 1 | L219 | `BW_SYSTEMSTAGE_MAIN()` | 标记进入主阶段(调试用) |
| 2 | L236 | `setSignalHandler()` | 注册 SIGINT/SIGBREAK 信号处理 |
| 3 | L239 | `MsgHandler msgHandler` | 重定向 BW 库消息到 cout |
| 4 | L243 | `ScopedWriteToConsole` | RAII 限制控制台输出范围 |
| 5 | L259-339 | 命令行解析 while 循环 | 解析所有 `--xxx` 参数 |
| 6 | L342-347 | 参数校验 | 模式互斥检查 |
| 7 | L349 | `PackerHelper::paths(inPath,outPath)` | 保存输入输出根路径 |
| 8 | L351-352 | `doBgTaskManagerInit` / `doFileIOTaskManagerInit` | 后台任务线程(客户端) |
| 9 | L354/L481 | 模式分派 | 批量模式 / 兼容模式 |
| 10 | L552-559 | 资源清理 | `Moo::fini` / `BWResource::fini` |
| 11 | L561 | 返回结果 | `EXIT_SUCCESS` / `EXIT_FAILURE` |

### 4.4 命令行解析(L259-339)

命令行解析采用 `while (processedFlag)` 循环结构,每轮处理一对参数(`--opt value`),`processedFlag` 标记本轮是否处理了参数,若未处理则退出循环:

```cpp
// main.cpp L259-339 (简化)
while (processedFlag)
{
    processedFlag = false;

    if ((numArgs > 1) && (strcmp(pArgs[0],"--res") == 0 || strcmp(pArgs[0],"-r") == 0))
    { /* 跳过 -r 搜索路径,已由 BWResource 处理 */ }

    else if ((numArgs > 1) && (strcmp(pArgs[0], "--list") == 0 || strcmp(pArgs[0],"-l") == 0))
    { hasAssetList = true; assetList = bw_fopen(pArgs[1], "r"); }

    else if ((numArgs > 1) && (strcmp(pArgs[0], "--in") == 0 || strcmp(pArgs[0],"-i") == 0))
    { hasInPath = true; strcpy(inPath, removeTrailingSlash(pArgs[1]).c_str()); }

    else if ((numArgs > 1) && (strcmp(pArgs[0], "--out") == 0 || strcmp(pArgs[0],"-o") == 0))
    { hasOutPath = true; strcpy(outPath, removeTrailingSlash(pArgs[1]).c_str()); }

    else if ((numArgs > 1) && (strcmp(pArgs[0], "--err") == 0 || strcmp(pArgs[0],"-e") == 0))
    { useErrorLog = true; errorLog = bw_fopen(pArgs[1], "w"); }

    else if ((numArgs > 0) && (strcmp(pArgs[0], "--encrypt") == 0))
    { XmlPacker::shouldEncrypt(true); /* 未文档化 */ }

    else if ((numArgs > 1) && (strcmp(pArgs[0], "--strip") == 0))
    { CDataPacker::addStripSection(pArgs[1]); /* 未文档化 */ }
}
```

**注意**:`--encrypt` 和 `--strip` 两个选项在 `printUsage` 中**未文档化**(见 L321、L330 注释 `NOTE: This option is currently not documented.`),属于内部/隐藏功能。

### 4.5 参数校验(L342-347)

```cpp
// main.cpp L342-347
if ((hasAssetList && (!hasInPath || !hasOutPath || numArgs > 0)) || // list 模式
    (!hasAssetList && (numArgs < 1 || numArgs > 3))) // compatible mode
{
    printUsage( exeName );
    return EXIT_FAILURE;
}
```

校验规则:
- **批量列表模式**(`hasAssetList==true`):必须提供 `--in` 和 `--out`,且不能有剩余位置参数;
- **兼容模式**(`hasAssetList==false`):必须有 1-3 个位置参数(输入文件、输出文件、base_path)。

### 4.6 后台任务管理器初始化(L169-201)

```cpp
// main.cpp L169-185
void doBgTaskManagerInit()
{
#ifndef MF_SERVER
    // only needed by the cdata packer
    bool bSuccessfulInit = BgTaskManager::init();
    if (bSuccessfulInit && BgTaskManager::instance().numRunningThreads() == 0)
    {
        BgTaskManager::instance().startThreads("Background Thread: res_packer", 1);
    }
#endif // MF_SERVER
}
```

`BgTaskManager` 和 `FileIOTaskManager` 仅在客户端(`!MF_SERVER`)初始化,因为 CDataPacker 在加载地形块时需要后台线程异步加载纹理/法线数据。服务端打包不需要这些图形资源。

---

## 五、核心类与继承关系

### 5.1 类继承图

```
                    ┌─────────────────────────┐
                    │   BasePacker (抽象基类)  │
                    │   base_packer.hpp L9     │
                    │   - prepare() = 0        │
                    │   - print()   = 0        │
                    │   - pack()    = 0        │
                    └────────────┬────────────┘
                                 │ 公有继承
        ┌────────────┬───────────┼───────────┬────────────┬──────────┐
        ▼            ▼           ▼           ▼            ▼          ▼
  ┌──────────┐ ┌──────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌──────────┐
  │XmlPacker │ │ChunkPack │ │CDataPck │ │FxPacker │ │ImagePack│ │ModelAnim │
  │          │ │          │ │         │ │         │ │         │ │ Packer   │
  │LOWEST    │ │HIGHEST   │ │HIGHEST  │ │HIGHEST  │ │HIGHEST  │ │HIGHEST   │
  │PRIORITY  │ │          │ │         │ │         │ │         │ │          │
  └──────────┘ └──────────┘ └─────────┘ └─────────┘ └─────────┘ └──────────┘
```

### 5.2 BasePacker 抽象基类

`base_packer.hpp` 定义了所有 Packer 的统一接口:

```cpp
// base_packer.hpp L9-27
class BasePacker
{
public:
    /**
     *  Returns true if it can process the files, and if so, prepares itself.
     */
    virtual bool prepare( const BW::string & src, const BW::string & dst ) = 0;

    /**
     *  Output the class's string representation to stdout. Useful for XML.
     */
    virtual bool print() = 0;

    /**
     *  Pack the resource. Usualy requires copying the file to the destination,
     *  and doing whatever processing is required.
     */
    virtual bool pack() = 0;
};
```

三个纯虚方法的语义:

| 方法 | 调用时机 | 职责 | 返回 true 含义 |
|------|---------|------|---------------|
| `prepare(src, dst)` | `Packers::find()` 遍历时 | 判断是否能处理该文件扩展名/内容,保存 src/dst | 我能处理此文件,返回我 |
| `print()` | 兼容模式单参数时 | 输出文件字符串表示到 stdout | 输出成功 |
| `pack()` | 实际打包时 | 复制并处理文件,剥离无用数据 | 打包成功 |

**关键设计**:`prepare()` 同时承担"能力声明"和"状态准备"两个职责。如果返回 `false`,不仅表示"我不能处理",也意味着"不要选我"。这要求 `prepare()` 必须是**无副作用的**(或副作用可逆),因为 `find()` 会连续调用多个 Packer 的 `prepare()`。

### 5.3 各 Packer 的 prepare() 判断逻辑

| Packer | 判断依据 | 扩展名 | 额外条件 |
|--------|---------|--------|---------|
| XmlPacker | 文件内容以 `<` 开头 | 任意 | `LOWEST_PRIORITY`,兜底;`canPack()` 或 `shouldEncrypt` |
| ChunkPacker | 扩展名 `.chunk` | `.chunk` | 无 |
| CDataPacker | 扩展名 `.cdata` + 有 `space.settings` | `.cdata` | 必须能找到 space.settings |
| FxPacker | 扩展名 `.fx`/`.fxh`/`.fxo` | 三种 | 无 |
| ImagePacker | 扩展名 `.bmp`/`.tga`/`.png`/`.jpg`/`.dds` | 五种 | 若 `shouldEncrypt` 则拒绝(让 XmlPacker 处理) |
| ModelAnimPacker | 扩展名 `.model`/`.animation`/`.anca` | 三种 | 无 |

---

## 六、Packer 注册机制

### 6.1 Packers 单例调度器

`packers.hpp` 定义了全局唯一的 Packer 调度器:

```cpp
// packers.hpp L16-36
class Packers
{
private:
    typedef std::pair<unsigned short,BasePacker*> Item;
    typedef BW::vector<Item> Items;

public:
    static const unsigned short HIGHEST_PRIORITY = 0;
    static const unsigned short LOWEST_PRIORITY  = 0xFFFF;

    static Packers& instance();

    void add( BasePacker* packer, unsigned short priority );

    BasePacker* find( const BW::string& src, const BW::string& dst );

private:
    Packers() {};
    Items packers_;
};
```

**关键点**:
- `packers_` 是 `vector<pair<priority, packer*>>`,**按 priority 升序排列**;
- `HIGHEST_PRIORITY = 0`(数值越小优先级越高);
- `LOWEST_PRIORITY = 0xFFFF`(数值最大,最后处理);
- 构造函数私有,只能通过 `instance()` 访问(Meyers 单例)。

### 6.2 add() 有序插入(L13-26)

```cpp
// packers.cpp L13-26
void Packers::add( BasePacker* packer, unsigned short priority )
{
    if ( !packer )
        return;

    // insert ordered by priority
    Items::iterator i = packers_.begin();
    for( ; i != packers_.end(); ++i )
    {
        if ( (*i).first > priority )
            break;
    }
    packers_.insert( i, Item( priority, packer ) );
}
```

插入时找到第一个**优先级数值大于**当前 priority 的位置,在其前面插入。这保证 `packers_` 始终按 priority 升序排列。相同 priority 的 Packer 按**注册顺序**排列(稳定)。

### 6.3 find() 遍历匹配(L28-38)

```cpp
// packers.cpp L28-38
BasePacker* Packers::find( const BW::string& src, const BW::string& dst )
{
    // return the first packer that can handle the data
    for( Items::iterator i = packers_.begin();
        i != packers_.end(); ++i )
    {
        if ( (*i).second->prepare( src, dst ) )
            return (*i).second;
    }
    return NULL;
}
```

**核心分派逻辑**:按优先级顺序(高→低)依次调用 `prepare()`,**第一个返回 true 的 Packer 胜出**。由于 `XmlPacker` 注册为 `LOWEST_PRIORITY`,它会在所有专用 Packer 都拒绝后才被尝试,起到**兜底**作用。

### 6.4 PackerFactory 自动注册

`packers.hpp` L39-46 定义了工厂类,其构造函数即注册:

```cpp
// packers.hpp L39-46
class PackerFactory
{
public:
    PackerFactory( BasePacker* packer, unsigned short priority = Packers::HIGHEST_PRIORITY )
    {
        Packers::instance().add( packer, priority );
    }
};
```

### 6.5 注册宏(L48-54)

```cpp
// packers.hpp L48-54
#define DECLARE_PACKER()        \
    static PackerFactory s_packer_factory_;

#define IMPLEMENT_PACKER( P )   \
    PackerFactory P::s_packer_factory_( new P() );

#define IMPLEMENT_PRIORITISED_PACKER( P, PRIORITY )     \
    PackerFactory P::s_packer_factory_( new P(), PRIORITY );
```

**使用方式**:

| 宏 | 位置 | 作用 |
|----|------|------|
| `DECLARE_PACKER()` | 类定义体内(private) | 声明静态 `s_packer_factory_` 成员 |
| `IMPLEMENT_PACKER(P)` | 类外(通常 .cpp) | 定义静态成员,`new P()` 并以 `HIGHEST_PRIORITY` 注册 |
| `IMPLEMENT_PRIORITISED_PACKER(P, PRIO)` | 类外 | 定义静态成员,以指定优先级注册 |

### 6.6 自动注册时序

```
程序启动 (main 之前)
        │
        ▼
全局静态对象初始化阶段
        │
        ├─► XmlPacker::s_packer_factory_ 构造
        │   └─► PackerFactory(new XmlPacker(), LOWEST_PRIORITY)
        │       └─► Packers::instance().add(packer, 0xFFFF)
        │           └─► packers_ = [(0xFFFF, XmlPacker*)]
        │
        ├─► ChunkPacker::s_packer_factory_ 构造
        │   └─► PackerFactory(new ChunkPacker(), HIGHEST_PRIORITY)
        │       └─► add(packer, 0)
        │           └─► packers_ = [(0, ChunkPacker*), (0xFFFF, XmlPacker*)]
        │
        ├─► CDataPacker::s_packer_factory_ 构造 (priority=0)
        │   └─► packers_ = [(0, ChunkPacker*), (0, CDataPacker*), (0xFFFF, XmlPacker*)]
        │
        ├─► FxPacker, ImagePacker, ModelAnimPacker (均 priority=0)
        │   └─► packers_ = [0:Chunk, 0:CData, 0:Fx, 0:Image, 0:ModelAnim, 0xFFFF:Xml]
        │
        ▼
main() 执行
        │
        ▼
Packers::find() 按 packers_ 顺序遍历
```

**关键**:`packers_` 中 priority=0 的 5 个 Packer 顺序取决于**全局对象初始化顺序**(编译单元顺序),但这不影响正确性,因为它们处理的扩展名互斥。`XmlPacker` 永远最后被尝试。

---

## 七、6 个 Packer 详细分析

### 7.1 XmlPacker(兜底 XML 打包器)

- **文件**: `xml_packer.hpp` / `xml_packer.cpp` (117 行)
- **优先级**: `LOWEST_PRIORITY` (0xFFFF)
- **注册**: `IMPLEMENT_PRIORITISED_PACKER( XmlPacker, Packers::LOWEST_PRIORITY )` (xml_packer.cpp L14)

**职责**: 处理所有未被专用 Packer 接管的 XML 文本文件,将其转换为二进制 `PackedSection` 格式以减小体积和加载时间。

**prepare() 逻辑** (xml_packer.cpp L20-64):
1. 打开源文件,读取全部内容到 `BinaryBlock`;
2. 调用 `DataSection::createAppropriateSection("root", data)`;
3. 若返回 NULL(非 XML 文件),返回 false;
4. 若 `!canPack() && !shouldEncrypt`,返回 false(已打包且不加密则不处理);
5. 保存 src/dst,返回 true。

**pack() 逻辑** (xml_packer.cpp L78-97):
```cpp
// xml_packer.cpp L92-97
BW::vector< BW::string > stripSections;
stripSections.push_back( "metaData" ); // 粒子是 .xml 文件,移除元数据
return PackedSection::convert( src_, dst_, &stripSections, s_shouldEncrypt );
```

**关键设计**: `metaData` section 在所有 XML 文件打包时都会被剥离,因为它存储编辑器元数据(粒子特效的编辑信息)。`s_shouldEncrypt` 控制是否对 PackedSection 进行加密。

**print() 实现** (xml_packer.cpp L99-117): 递归打印 DataSection 树,带缩进。

### 7.2 ChunkPacker(Chunk 文件打包器)

- **文件**: `chunk_packer.cpp` (113 行)
- **优先级**: `HIGHEST_PRIORITY` (0)
- **扩展名**: `.chunk`

**职责**: 处理场景块文件,根据 `MF_SERVER` 宏剥离对方阵营的实体(客户端剥离服务端实体,服务端剥离客户端实体),并移除导航网格、编辑器专用数据。

**prepare() 逻辑** (chunk_packer.cpp L17-27): 仅检查扩展名是否为 `.chunk`。

**pack() 逻辑** (chunk_packer.cpp L42-113):
1. 复制源文件到临时文件 `dst_ + ".packerTemp"`(因 PackedSection 不可编辑);
2. 用 `FileDeleter` RAII 确保临时文件删除;
3. 打开临时文件为 DataSection,遍历所有 `entity` section:
   - **客户端**(`!MF_SERVER`): 删除 `clientOnly==false` 的实体(即服务端实体);
   - **服务端**(`MF_SERVER`): 删除 `clientOnly==true` 的实体(即客户端实体);
4. 保存修改;
5. 调用 `PackedSection::convert` 转换为二进制格式,剥离 section 列表:
   - `editorOnly`(编辑器专用)
   - `metaData`(元数据)
   - `navmesh`(导航网格)
   - **客户端额外**:`worldNavmesh`(世界导航网格)
6. `strip sections up to depth 2`(只剥离深度 2 以内的 section)。

**关键代码** (chunk_packer.cpp L66-92):
```cpp
// 客户端:删除 clientOnly==false 的实体(服务端实体)
#ifndef MF_SERVER
    bool delSection = !(*i)->readBool( "clientOnly", false );
#else // MF_SERVER
    // 服务端:删除 clientOnly==true 的实体(客户端实体)
    bool delSection = (*i)->readBool( "clientOnly", false );
#endif // MF_SERVER
```

### 7.3 CDataPacker(地形数据打包器)— 最复杂

- **文件**: `cdata_packer.hpp` (44 行) / `cdata_packer.cpp` (395 行)
- **优先级**: `HIGHEST_PRIORITY` (0)
- **扩展名**: `.cdata`

**职责**: 剥离 `.cdata` 文件中的运行时不需要的数据:
- **客户端**: 移除导航网格、缩略图、根据 LOD 距离判断剥离地形层、LOD 纹理、法线;
- **服务端**: 仅移除缩略图。

由于 CDataPacker 极其复杂,详见[第九章](#九cdatapacker-深度剖析)。

### 7.4 FxPacker(Shader 文件打包器)

- **文件**: `fx_packer.cpp` (89 行)
- **优先级**: `HIGHEST_PRIORITY` (0)
- **扩展名**: `.fx`(源)/`.fxh`(头)/`.fxo`(编译后)

**prepare() 逻辑** (fx_packer.cpp L17-34): 按扩展名设置 `type_` 为 `FX`/`FXH`/`FXO`。

**pack() 逻辑** (fx_packer.cpp L54-89):
- **客户端**:
  - 若 `PACK_SHADER_BINARIES` 未定义且 `type_==FXO`:跳过(返回 true);
  - 若 `PACK_SHADER_SOURCE` 未定义且 `type_==FX/FXH`:跳过;
  - 否则直接复制文件(Shader 编译是独立的离线步骤);
- **服务端**: 直接跳过所有 Shader 文件。

**配置宏** (config.hpp):
```cpp
//#define PACK_SHADER_SOURCE // 默认不打包源 Shader
#define PACK_SHADER_BINARIES
```

默认行为:**打包编译后 Shader (.fxo),不打包源 Shader (.fx/.fxh)**。

### 7.5 ImagePacker(贴图打包器)

- **文件**: `image_packer.cpp` (184 行)
- **优先级**: `HIGHEST_PRIORITY` (0)
- **扩展名**: `.bmp`/`.tga`/`.png`/`.jpg`(IMAGE)/`.dds`(DDS)

**prepare() 逻辑** (image_packer.cpp L23-48):
1. **特殊处理**: 若 `XmlPacker::shouldEncrypt()` 为 true,返回 false(让 XmlPacker 处理 DDS 加密);
2. 按扩展名设置 `type_` 为 `IMAGE` 或 `DDS`。

**pack() 逻辑** (image_packer.cpp L65-184) — 仅客户端:
- **DDS 类型**:
  - 检测是否为字体 DDS(扫描同目录 `.font` 文件,比对 `creation/sourceFont` + `sourceFontSize` 拼接的名称);
  - 若 `PACK_FONT_DDS` 未定义且是字体 DDS:跳过(不复制);
  - 否则:若目标不存在则复制;
- **IMAGE 类型**:
  - 查找同名的 `.dds` 文件,若存在则复制 DDS 而非源图;
  - 否则若源和目标扩展名相同,直接复制;
  - 否则报错;
- **服务端**: 跳过所有图片文件。

**字体检测逻辑** (image_packer.cpp L80-121):
```cpp
// 读取 .font 文件的 creation/sourceFont 和 sourceFontSize
BW::string sourceFont = fontFile->readString( "creation/sourceFont", "" );
int fontSize = abs( fontFile->readInt( "creation/sourceFontSize", 0 ) );
char buffer[256];
bw_snprintf( buffer, sizeof(buffer), "%s_%d", sourceFont.c_str(), fontSize );
if (fontName == buffer) { isFont = true; }
```

### 7.6 ModelAnimPacker(模型动画打包器)

- **文件**: `model_anim_packer.cpp` (124 行)
- **优先级**: `HIGHEST_PRIORITY` (0)
- **扩展名**: `.model`(MODEL)/`.animation`(ANIMATION)/`.anca`(ANCA,压缩动画)

**prepare() 逻辑** (model_anim_packer.cpp L21-38): 按扩展名设置 `type_`。

**pack() 逻辑** (model_anim_packer.cpp L57-124) — 仅客户端:
1. 仅处理 `.model` 文件,`.animation`/`.anca` 直接跳过(返回 true);
2. 打开 model DataSection,检查是否有 `nodefullVisual` section;
3. 若有,调用 `Model::loadAnimations(dissolved)` 生成 `.anca` 压缩动画文件;
4. 检查目标 `.anca` 是否已生成:
   - 若未生成,检查源目录是否有 `.anca`,有则复制;
   - 若源目录也没有,认为该模型无动画(非错误);
5. 调用 `PackedSection::convert` 打包 `.model` 文件,剥离 `metaData`。

**关键**: `Moo::InterpolatedAnimationChannel::inhibitCompression(false)` 确保压缩开启,生成 `.anca` 文件。

---

## 八、PackerHelper 辅助工具类

### 8.1 类职责

`PackerHelper` (`packer_helper.hpp` L14) 是一个**纯静态工具类**,为所有 Packer 提供共享的基础设施:资源系统初始化、Moo 渲染初始化、文件操作、路径管理。

### 8.2 静态成员

```cpp
// packer_helper.hpp L54-59
private:
    static int s_argc_;
    static char** s_argv_;
    static BW::string s_basePath_;
    static BW::string s_inPath;
    static BW::string s_outPath;
```

### 8.3 关键方法

#### 8.3.1 initResources() (packer_helper.cpp L47-86)

```cpp
bool PackerHelper::initResources()
{
#ifdef _WIN32
    // 切换工作目录到 exe 所在目录(便于查找 paths.xml)
    wchar_t buffer[MAX_PATH];
    GetModuleFileName( NULL, buffer, ARRAY_SIZE( buffer ) );
    SetCurrentDirectory( bw_utf8tow( BWResource::getFilePath( bw_wtoutf8( buffer ) ) ).c_str() );
#endif
    if ( !BWResource::init( s_argc_, (const char **)s_argv_ ) )
        return false;

    // basePath 作为第一个搜索路径
    s_basePath_ = BWUtil::normalisePath( s_basePath_ ) + '/';
    if (!BWResource::ensureAbsolutePathExists( s_basePath_ ))
        return false;
    BWResource::addPath( s_basePath_, 0 );

#ifndef MF_SERVER
    if ( !AutoConfig::configureAllFrom( "resources.xml" ) )
        return false;
#endif
    return true;
}
```

#### 8.3.2 initMoo() (packer_helper.cpp L123-172)

`initMoo()` 仅在客户端编译,创建一个隐藏窗口和 D3D 设备,供贴图格式转换、模型加载使用:

```cpp
bool PackerHelper::initMoo()
{
#ifndef MF_SERVER
    Moo::init( true, true );
    // 注册窗口类 "packer_helper"
    WNDCLASS wc = { 0, WndProc, ... };
    RegisterClass( &wc );
    // 创建 100x100 隐藏窗口
    HWND hWnd = CreateWindow( L"packer_helper", ..., 100, 100, ... );
    s_pRenderer.reset( new Renderer );
    s_pRenderer->init( true, true );
    // Vista+ 用 HAL,XP 用 REF(软件模拟)
    bool isVista = ose.dwMajorVersion > 5;
    bool forceRef = !isVista;
    Moo::rc().createDevice( hWnd, 0, 0, true, false, Vector2(0,0), true, forceRef );
    initTextureFormats(); // 设置光标纹理格式为 A8R8G8B8
#endif
    return true;
}
```

**Vista 判断**: `ose.dwMajorVersion > 5`(XP=5.1, Vista=6.0)。XP 上强制使用参考光栅器(REF),因为某些 D3D 功能在 XP HAL 上不可靠。

#### 8.3.3 copyFile() (packer_helper.cpp L174-220)

平台无关的文件复制,使用 32KB 缓冲区:

```cpp
bool PackerHelper::copyFile( const BW::string& src, const BW::string& dst, bool silent )
{
    #define PACKER_COPY_BUF_SIZE 32768
    static char buf[ PACKER_COPY_BUF_SIZE ];
    // fopen/fread/fwrite 循环
}
```

**注意**: 使用 `static` 缓冲区,非线程安全。

#### 8.3.4 FileDeleter RAII (packer_helper.hpp L45-52)

```cpp
class FileDeleter
{
public:
    FileDeleter( const BW::string& file ) : file_( file ) {};
    ~FileDeleter() { remove( file_.c_str() ); }
private:
    BW::string file_;
};
```

用于确保临时文件在作用域结束时删除,即使发生异常。ChunkPacker 使用它清理 `.packerTemp` 文件。

### 8.4 方法清单

| 方法 | 位置 | 作用 |
|------|------|------|
| `argc()` / `argv()` | L18-19 | 获取命令行参数 |
| `paths(in, out)` | L21 | 设置输入/输出根路径 |
| `inPath()` / `outPath()` | L23-25 | 获取根路径 |
| `initResources()` | L28 | 初始化 BWResource + AutoConfig |
| `initMoo()` | L31 | 初始化 Moo + D3D 设备(客户端) |
| `copyFile(src, dst, silent)` | L34-35 | 复制文件(32KB 缓冲) |
| `fileExists(file)` | L38 | 检测文件存在 |
| `isFileNewer(f1, f2)` | L41-42 | 比较文件修改时间(Win32) |
| `setCmdLine(argc, argv)` | L74-78 | 保存命令行(内部用) |
| `setBasePath(basePath)` | L80-87 | 设置并规范化 base 路径 |

---

## 九、CDataPacker 深度剖析

CDataPacker 是 6 个 Packer 中**最复杂**的,涉及地形系统的 LOD 判断、后台任务等待、地形块加载劫持等高级技术。

### 9.1 类成员 (cdata_packer.hpp)

```cpp
// cdata_packer.hpp L18-40
class CDataPacker : public BasePacker
{
public:
    virtual bool prepare( const BW::string & src, const BW::string & dst );
    virtual bool print();
    virtual bool pack();

    static void addStripSection( const char * sectionName );

    CDataPacker();

private:
    DECLARE_PACKER()
    BW::string src_;
    BW::string dst_;
    bool stripWorldNavMesh_;
    bool stripLayers_;
    bool stripLodTextures_;
    bool stripQualityNormals_;
    bool stripLodNormals_;
    int32 heightMapLodToPreserve_;
    BW::string  terrainDataSectionName_;
};
```

### 9.2 构造函数默认值 (cdata_packer.cpp L150-159)

```cpp
CDataPacker::CDataPacker() :
    stripWorldNavMesh_( true ),    // 默认剥离世界导航网格
    stripLayers_( false ),
    stripLodTextures_( false ),
    stripQualityNormals_( false ),
    stripLodNormals_( false ),
    heightMapLodToPreserve_( -1 )  // -1 表示不剥离高度图 LOD
{
}
```

### 9.3 prepare() 流程 (cdata_packer.cpp L174-288)

```
prepare(src, dst)
        │
        ▼
   扩展名 == .cdata? ──否──► return false
        │是
        ▼
   查找 space.settings
        │
   找不到? ──是──► WARNING + return false (如 blank_legacy.cdata)
        │否
        ▼
   stripWorldNavMesh_ = !readBool("clientNavigation/enabled")
        │
        ▼
   ┌──────────────────────────────────────┐
   │ 仅客户端 ( !MF_SERVER )              │
   │                                      │
   │ terrainVersion = readInt("terrain/version")
        │                                      │
   │ version >= 200? ──否──► return true (不剥离地形 LOD)
        │是                                    │
        ▼                                      │
   │ 设置 s_terrainChunkCDataFilename         │
   │ InitTerrainDependencies RAII 初始化      │
        │                                      │
        ▼                                      │
   │ 渲染器为 NULL? ──是──► 清空 src/dst, return true
        │否                                    │
        ▼                                      │
   │ 加载 .chunk 文件                         │
   │ 等待后台任务完成 (Yield 循环)            │
        │                                      │
        ▼                                      │
   │ terrainBlock == NULL? ──是──► return true
        │否                                    │
        ▼                                      │
   │ heightMapLodToPreserve_ = getForcedLod() │
        │                                      │
   │ < 0? ──是──► return true (无 LOD 可剥离) │
        │否                                    │
        ▼                                      │
   │ 计算 vertexLod 距离区间                  │
   │ 计算 renderTextureMask (load+draw flag)  │
        │                                      │
        ▼                                      │
   │ stripLayers_       = !(RTM_DrawBlend)    │
   │ stripLodTextures_  = !stripLayers_       │
   │ stripLodNormals_   = !(RTM_DrawLODNormals)
   │ stripQualityNormals_= !stripLodNormals_  │
   └──────────────────────────────────────┘
        │
        ▼
   return true
```

### 9.4 DummyChunkTerrain 地形加载劫持 (cdata_packer.cpp L45-87)

CDataPacker 通过一个**伪造的 ChunkItem 子类**劫持地形块的加载过程,只加载地形数据而不加载其他 ChunkItem:

```cpp
// cdata_packer.cpp L45-87
class DummyChunkTerrain : public ChunkItem
{
    DECLARE_CHUNK_ITEM( DummyChunkTerrain )
public:
    bool load( DataSectionPtr pSection, BW::string* errorString )
    {
        BW::string resName = pSection->readString( "resource" );
        // 截取 .cdata 路径
        size_t cDataPathEnd = resName.rfind( CDATA_PATH_EXT );
        // ...
        // 替换为当前处理的 cdata 文件名
        resName = s_terrainChunkCDataFilename + resName.substr( cDataPathEnd );
        s_terrainBlock = BaseTerrainBlock::loadBlock(
            resName, Matrix::identity, Vector3::zero(),
            s_terrainSettings, errorString );
        return true;
    }

    static void registerFactory()
    {
        Chunk::registerFactory( "terrain", DummyChunkTerrain::factory_ );
    }

    static BW::string s_terrainChunkCDataFilename;
    static BaseTerrainBlockPtr s_terrainBlock;
    static TerrainSettingsPtr s_terrainSettings;
};
```

**设计意图**: 正常的 Chunk 加载会触发完整的渲染资源加载,这里通过替换 `Chunk::getFactories()`,只保留 `DummyChunkTerrain` 工厂,从而**仅加载地形块数据**用于 LOD 判断,避免加载模型、粒子等无关资源。

### 9.5 InitTerrainDependencies RAII (cdata_packer.cpp L97-146)

```cpp
class InitTerrainDependencies
{
public:
    InitTerrainDependencies( DataSectionPtr terrainSettingsData )
    {
        Terrain::ResourceBase::defaultStreamType( RST_Syncronous ); // 同步加载
        AutoConfig::configureAllFrom( AutoConfig::s_resourcesXML );
        DummyChunkTerrain::s_terrainSettings = new TerrainSettings();
        BaseTerrainBlock::s_disableStreaming_ = true; // 禁用流式加载
        float gridSize = GeometryMapping::getGridSize( terrainSettingsData );
        // 初始化 TerrainSettings
        DummyChunkTerrain::s_terrainSettings->init( gridSize, terrainSettings );
        // 备份并替换 Chunk 工厂
        backupFactories_ = *Chunk::getFactories();
        Chunk::clearFactories();
        DummyChunkTerrain::registerFactory(); // 只注册 DummyChunkTerrain
    }

    ~InitTerrainDependencies()
    {
        // 恢复 Chunk 工厂
        Chunk::clearFactories();
        Chunk::setFactories( backupFactories_ );
        BaseTerrainBlock::s_disableStreaming_ = false;
    }

private:
    Chunk::Factories backupFactories_;
    Manager terrainManager_;
};
```

### 9.6 LOD 判断逻辑 (cdata_packer.cpp L251-285)

```cpp
heightMapLodToPreserve_ = DummyChunkTerrain::s_terrainBlock->getForcedLod();
if (heightMapLodToPreserve_ < 0)
    return true; // 无 LOD 可剥离

terrainDataSectionName_ = DummyChunkTerrain::s_terrainBlock->dataSectionName();

float minDistance, maxDistance;
DummyChunkTerrain::s_terrainSettings->vertexLod().getDistanceForLod(
    heightMapLodToPreserve_, minDistance, maxDistance );

// 计算 LOD 距离区间内的渲染标志
uint8 renderTextureMask = TerrainRenderer2::getLoadFlag(
    minDistance,
    DummyChunkTerrain::s_terrainSettings->absoluteBlendPreloadDistance(),
    DummyChunkTerrain::s_terrainSettings->absoluteNormalPreloadDistance());

renderTextureMask = TerrainRenderer2::getDrawFlag(
    renderTextureMask, minDistance, maxDistance,
    DummyChunkTerrain::s_terrainSettings );

// 根据标志位决定剥离哪些数据
stripLayers_        = ( renderTextureMask & TerrainRenderer2::RTM_DrawBlend ) == false;
stripLodTextures_   = !stripLayers_;
stripLodNormals_    = ( renderTextureMask & TerrainRenderer2::RTM_DrawLODNormals ) == false;
stripQualityNormals_= !stripLodNormals_;
```

**设计哲学**: 根据 chunk 在 LOD 层级下的**实际渲染需求**,剥离运行时不会绘制的数据。如果某 LOD 层级不绘制混合纹理(`RTM_DrawBlend`),则剥离 `layers`;否则剥离 `lodTextures`(二选一)。法线数据同理。

### 9.7 pack() 剥离操作 (cdata_packer.cpp L303-394)

```cpp
bool CDataPacker::pack()
{
    if ( !PackerHelper::copyFile( src_, dst_ ) )
        return false;

    DataSectionPtr root = BWResource::openSection( BWResolver::dissolveFilename( dst_ ) );
    if ( !root ) return false;

    // 1. 删除缩略图(客户端+服务端)
    root->delChild( "thumbnail.dds" );
    // 2. 删除 chunk 内 navmesh
    root->delChild( "navmesh" );
    // 3. 根据配置删除 worldNavmesh
    if (stripWorldNavMesh_)
        root->delChild( "worldNavmesh" );
    // 4. 删除命令行指定的额外 section (--strip)
    SectionsToStrip::iterator iter = s_sectionsToStrip.begin();
    while (iter != s_sectionsToStrip.end())
        root->delChild( *iter++ );

#ifndef MF_SERVER
    // 5. 客户端:根据 LOD 判断剥离地形数据
    DataSectionPtr dataSectionPtr = root->openSection( terrainDataSectionName_, false );
    if (dataSectionPtr != NULL)
    {
        if (stripLayers_)
            dataSectionPtr->deleteSections( TerrainBlock2::LAYER_SECTION_NAME );
        if (stripLodTextures_)
            dataSectionPtr->deleteSections( TerrainBlock2::LOD_TEXTURE_SECTION_NAME );
        if (stripQualityNormals_)
            dataSectionPtr->deleteSections( TerrainNormalMap2::NORMALS_SECTION_NAME );
        if (stripLodNormals_)
            dataSectionPtr->deleteSections( TerrainNormalMap2::LOD_NORMALS_SECTION_NAME );
        CommonTerrainBlock2::stripUnusedHeightSections(
            dataSectionPtr, heightMapLodToPreserve_ );
    }
#endif
    // 保存
    if ( !root->save() ) return false;
    return true;
}
```

### 9.8 MF_SERVER 行为差异

CDataPacker 是体现 `MF_SERVER` 宏差异最明显的 Packer:

| 操作 | 客户端 (!MF_SERVER) | 服务端 (MF_SERVER) |
|------|---------------------|-------------------|
| thumbnail.dds | 删除 | 删除 |
| navmesh | 删除 | 删除 |
| worldNavmesh | 根据 clientNavigation 配置 | 根据 clientNavigation 配置 |
| 地形 LOD 判断 | 执行(DummyChunkTerrain) | **不执行** |
| layers/lodTextures/normals | 根据 LOD 剥离 | **保留** |
| heightMap LOD | 剥离未使用层级 | **保留** |

**结论**: 服务端的 `.cdata` 保留完整地形数据,因为服务端需要做碰撞检测和寻路;客户端只保留运行时会渲染的 LOD 层级数据。

---

## 十、配置项与命令行参数

### 10.1 命令行参数总表

| 参数 | 简写 | 类型 | 必需 | 说明 |
|------|------|------|------|------|
| `--list` | `-l` | 文件路径 | 批量模式必需 | asset list 文件,每行一个相对路径 |
| `--in` | `-i` | 目录路径 | 批量模式必需 | 输入根目录 |
| `--out` | `-o` | 目录路径 | 批量模式必需 | 输出根目录 |
| `--err` | `-e` | 文件路径 | 可选 | 错误日志文件,记录失败的源文件路径 |
| `--res` | `-r` | 路径列表 | 可选 | 资源搜索路径(分号分隔) |
| `--encrypt` | 无 | 标志 | 可选(隐藏) | 启用加密,DDS 交给 XmlPacker |
| `--strip` | 无 | section 名 | 可选(隐藏) | 额外剥离的 cdata section 名 |
| 位置参数 1 | - | 文件路径 | 兼容模式必需 | 输入文件 |
| 位置参数 2 | - | 文件路径 | 兼容模式可选 | 输出文件(省略则 print) |
| 位置参数 3 | - | 目录路径 | 兼容模式可选 | base_path |

### 10.2 兼容模式参数组合

```
# 打印文件信息(不打包)
res_packer input.xml

# 打包单个文件
res_packer input.xml output.xml

# 打包并指定 base_path(用于 .font/.model)
res_packer input.model output.model /bw/finalgame/res
```

### 10.3 批量模式参数组合

```
# 标准批量打包
res_packer --list assets.txt \
           --in /bw/fantasydemo/res \
           --out /bw/fantasydemo/res_packed \
           --err error.log \
           --res /bw/fantasydemo/res;/bw/bigworld/res
```

### 10.4 config.hpp 编译时配置

```cpp
// config.hpp
//#define PACK_SHADER_SOURCE   // 注释掉:不打包 .fx/.fxh 源文件
#define PACK_SHADER_BINARIES   // 定义:打包 .fxo 编译后文件
```

| 宏 | 默认 | 影响 |
|----|------|------|
| `PACK_SHADER_SOURCE` | 未定义 | FxPacker 跳过 `.fx`/`.fxh` |
| `PACK_SHADER_BINARIES` | 已定义 | FxPacker 复制 `.fxo` |
| `PACK_FONT_DDS` | 未定义 | ImagePacker 跳过字体 DDS |

### 10.5 asset list 文件格式

每行一个**相对路径**(相对于 `--in`/`--out` 根目录),例如:

```
models/hero.model
textures/hero_diffuse.bmp
spaces/highlands/rr0010.cdata
shaders/standard.fxo
```

程序会拼接为 `inPath + "\\" + line` 和 `outPath + "\\" + line`,并将反斜杠替换为正斜杠。

---

## 十一、与其他模块的依赖关系

### 11.1 依赖关系图

```
┌─────────────────┐
│   res_packer    │
└────────┬────────┘
         │
   ┌─────┴──────────────────────────────────────────┐
   │                                                  │
   ▼                          ▼                       ▼
┌──────────┐           ┌──────────┐           ┌──────────┐
│ cstdmf   │           │ resmgr   │           │ moo      │
│ (基础工具)│           │ (资源系统)│           │ (渲染基础)│
│ - debug  │           │ - BWResource          │ - init    │
│ - bw_util│           │ - DataSection         │ - TextureMgr│
│ - command│           │ - PackedSection       │ - Renderer │
│ - bgtask │           │ - AutoConfig          │ - rc()     │
└──────────┘           │ - MultiFileSystem     └──────┬─────┘
                       └──────────┘                   │
   ┌─────┴──────────────────────────────────────────┐
   │                                                  │
   ▼                          ▼                       ▼
┌──────────┐           ┌──────────┐           ┌──────────┐
│ chunk    │           │ terrain  │           │ model    │
│ (地形块) │           │ (地形系统)│           │ (模型)   │
│ - Chunk  │           │ - BaseTerrainBlock    │ - Model   │
│ - ChunkItem│         │ - TerrainSettings     │ - AnimChannel│
│ - GeometryMapping     │ - TerrainRenderer2   └──────────┘
│ - ChunkSpace│        │ - TerrainNormalMap2
└──────────┘           │ - CommonTerrainBlock2
                       └──────────┘
   ┌─────┴──────────────────────────────────────────┐
   │                                                  │
   ▼                          ▼                       ▼
┌──────────┐           ┌──────────┐           ┌──────────┐
│ physics2 │           │ romp     │           │ speedtree│
│ (物理)   │           │ (渲染特效)│           │ (树木)   │
│ - MaterialKinds       │ - Water  │           │ - SpeedtreeRenderer│
└──────────┘           │ - LensEffectMgr       └──────────┘
                       │ - TextureFeeds
                       └──────────┘
```

### 11.2 关键依赖说明

| 模块 | 用途 | 客户端/服务端 |
|------|------|--------------|
| `BWResource` | 资源路径解析、DataSection 读写 | 两者 |
| `PackedSection` | XML→二进制转换 | 两者 |
| `Moo` | D3D 设备创建、纹理管理 | 仅客户端 |
| `Chunk` | Chunk 加载、工厂注册 | 仅客户端(CDataPacker) |
| `Terrain` | 地形块加载、LOD 判断 | 仅客户端(CDataPacker) |
| `Model` | 模型动画加载、anca 生成 | 仅客户端(ModelAnimPacker) |
| `MaterialKinds` | 材质种类初始化 | 仅客户端 |
| `BgTaskManager` | 后台任务(地形异步加载) | 仅客户端 |
| `FileIOTaskManager` | 文件 IO 后台线程 | 仅客户端 |

### 11.3 MF_SERVER 宏的影响范围

`MF_SERVER` 宏在编译时决定生成的可执行文件是**客户端打包器**还是**服务端打包器**:

| 代码区域 | 客户端 (!MF_SERVER) | 服务端 (MF_SERVER) |
|---------|---------------------|-------------------|
| `main.cpp` doBgTaskManagerInit | 初始化 BgTaskManager | 空函数 |
| `main.cpp` doFileIOTaskManagerInit | 初始化 FileIOTaskManager | 空函数 |
| `main.cpp` MaterialKinds::init | 调用 | 跳过 |
| `packer_helper.cpp` initMoo | 创建 D3D 设备 | 直接返回 true |
| `cdata_packer.cpp` prepare | LOD 判断 | 跳过 |
| `cdata_packer.cpp` pack | 剥离地形数据 | 跳过 |
| `chunk_packer.cpp` pack | 删除服务端实体 + worldNavmesh | 删除客户端实体 |
| `fx_packer.cpp` pack | 复制 Shader 文件 | 跳过 |
| `image_packer.cpp` pack | 复制贴图 | 跳过 |
| `model_anim_packer.cpp` pack | 加载模型生成 anca | 跳过 |

**结论**: 服务端打包器仅处理 `.chunk`(删除客户端实体)、`.cdata`(仅删缩略图/navmesh)和 XML 文件,其他图形资源原样跳过(由调用方决定是否复制)。

---

## 十二、关键代码片段(带行号)

### 12.1 main 入口与 token 注册 (main.cpp L37-51)

```cpp
// Packer tokens to ensure that they get compiled
extern int XmlPacker_token;
extern int ImagePacker_token;
extern int FxPacker_token;
extern int ChunkPacker_token;
extern int CDataPacker_token;
extern int ModelAnimPacker_token;
static int s_chunkTokenSet = 0
    | XmlPacker_token
    | ImagePacker_token
    | FxPacker_token
    | ChunkPacker_token
    | CDataPacker_token
    | ModelAnimPacker_token
    ;
```

### 12.2 信号处理 (main.cpp L133-161)

```cpp
static volatile bool s_quitRequested = false;

static void quitSignalHandler( int signo )
{
    if (signo == SIGINT
#ifdef WIN32
        || signo == SIGBREAK
#endif
        )
    {
        printf( "\n\nCTRL+%s has been pressed. "
            "Finishing processing current asset...\n\n",
            (signo == SIGINT) ? "C" : "Break" );
        s_quitRequested = true;
        signal( signo, SIG_IGN ); // 忽略后续信号
    }
}
```

### 12.3 批量模式核心循环 (main.cpp L386-450)

```cpp
char buf[ MAX_FILEPATH ];
int fails = 0;
while (fgets( buf, MAX_FILEPATH, assetList ) != 0)
{
    buf[ strlen(buf) - 1 ] = 0; // 去掉换行符
    BW::string pInputName = BW::string( inPath ) + "\\" + BW::string( buf );
    BW::string pOutputName = BW::string( outPath ) + "\\" + BW::string( buf );

    // 反斜杠转正斜杠
    std::replace( pInputName.begin(), pInputName.end(), '\\', '/' );
    std::replace( pOutputName.begin(), pOutputName.end(), '\\', '/' );

    BasePacker* packer = Packers::instance().find( pInputName, pOutputName );
    // ... print 模式分支 ...

    printf( "Processing %s...", pInputName.c_str() );

    bool failed = false;
    if ( !packer )
        failed = !PackerHelper::copyFile( pInputName, pOutputName ); // 未知类型直接复制
    else
        failed = !packer->pack();

    if (failed)
    {
        fails++;
        if (useErrorLog && (errorLog != NULL))
            fprintf( errorLog, "%s\n", pInputName.c_str() );
    }
    printf( " %s\n", failed ? "failed" : "succeeded" );

    // SIGINT 中断处理
    if (s_quitRequested)
    {
        printf( "\nDo you want to continue [y/n]? " );
        char c = getchar();
        getchar(); // 吃掉换行符
        if (c != 'Y' && c != 'y')
            break;
        s_quitRequested = false;
        setSignalHandler(); // 重新注册信号处理
    }
}
```

### 12.4 Packers 有序插入 (packers.cpp L13-26)

```cpp
void Packers::add( BasePacker* packer, unsigned short priority )
{
    if ( !packer )
        return;
    Items::iterator i = packers_.begin();
    for( ; i != packers_.end(); ++i )
    {
        if ( (*i).first > priority ) // 找到第一个 priority 更大的
            break;
    }
    packers_.insert( i, Item( priority, packer ) ); // 在其前插入
}
```

### 12.5 find 遍历匹配 (packers.cpp L28-38)

```cpp
BasePacker* Packers::find( const BW::string& src, const BW::string& dst )
{
    for( Items::iterator i = packers_.begin();
        i != packers_.end(); ++i )
    {
        if ( (*i).second->prepare( src, dst ) )
            return (*i).second;
    }
    return NULL;
}
```

### 12.6 ChunkPacker 客户端/服务端实体剥离 (chunk_packer.cpp L66-92)

```cpp
BW::vector<DataSectionPtr> sections;
root->openSections( "entity", sections );
for ( BW::vector<DataSectionPtr>::iterator i = sections.begin();
    i != sections.end(); )
{
#ifndef MF_SERVER
    // 客户端:删除非 clientOnly 的实体(服务端实体)
    bool delSection = !(*i)->readBool( "clientOnly", false );
#else // MF_SERVER
    // 服务端:删除 clientOnly 的实体(客户端实体)
    bool delSection = (*i)->readBool( "clientOnly", false );
#endif
    if ( delSection )
    {
        root->delChild( *i );
        i = sections.erase( i );
    }
    else
        ++i;
}
```

### 12.7 CDataPacker 后台任务等待 (cdata_packer.cpp L241-244)

```cpp
// 确保所有后台加载任务完成
while (BgTaskManager::instance().numBgTasksLeft() > 0)
{
    Yield();
}
```

### 12.8 ImagePacker 字体 DDS 检测 (image_packer.cpp L93-119)

```cpp
for (; !isFont && it != end; ++it)
{
    BW::string fileName = directory + (*it);
    if (BWResource::getExtension( fileName ) == "font")
    {
        DataSectionPtr fontFile = BWResource::openSection( fileName );
        if (fontFile)
        {
            BW::string sourceFont = fontFile->readString( "creation/sourceFont", "" );
            int fontSize = abs( fontFile->readInt( "creation/sourceFontSize", 0 ) );
            char buffer[256];
            bw_snprintf( buffer, sizeof(buffer), "%s_%d", sourceFont.c_str(), fontSize );
            if (fontName == buffer)
                isFont = true;
        }
    }
}
```

### 12.9 PackerFactory 自动注册宏 (packers.hpp L48-54)

```cpp
#define DECLARE_PACKER()        \
    static PackerFactory s_packer_factory_;

#define IMPLEMENT_PACKER( P )   \
    PackerFactory P::s_packer_factory_( new P() );

#define IMPLEMENT_PRIORITISED_PACKER( P, PRIORITY )     \
    PackerFactory P::s_packer_factory_( new P(), PRIORITY );
```

### 12.10 ScopedWriteToConsole RAII (main.cpp L203-215)

```cpp
class ScopedWriteToConsole
{
public:
    ScopedWriteToConsole()
    {
        DebugFilter::shouldWriteToConsole( true );
    }
    ~ScopedWriteToConsole()
    {
        DebugFilter::shouldWriteToConsole( false );
    }
};
```

**用途**: 限制 BW 库的调试输出只在 `main` 函数执行期间输出到控制台,避免退出时的内存泄漏报告污染输出。

---

## 十三、设计亮点与注意事项

### 13.1 设计亮点

#### 13.1.1 策略模式 + 优先级注册的优雅分派

`res_packer` 通过 `BasePacker` 抽象基类 + `PackerFactory` 全局对象 + `Packers` 单例的有序 vector,实现了**开闭原则**:新增一种资源类型的打包器,只需:
1. 继承 `BasePacker`;
2. 实现 `prepare`/`print`/`pack`;
3. 在 `.cpp` 中写 `IMPLEMENT_PACKER(NewPacker)`;
4. 在 `main.cpp` 添加 `extern int NewPacker_token;` 并加入 `s_chunkTokenSet`。

无需修改 `main` 或 `Packers` 的任何代码。

#### 13.1.2 LOWEST_PRIORITY 兜底机制

`XmlPacker` 注册为 `LOWEST_PRIORITY`,在 `find()` 中最后被尝试。它的 `prepare()` 通过**读取文件内容**判断是否为 XML(以 `<` 开头),而非仅看扩展名。这使得任何未识别扩展名的 XML 文本文件都能被正确打包,而专用 Packer 优先处理已知的扩展名。这种"专用优先,通用兜底"的设计非常稳健。

#### 13.1.3 prepare() 的无副作用契约

`prepare()` 同时承担能力声明和状态准备,但要求无副作用(或可逆),因为 `find()` 会连续调用多个 Packer。各 Packer 的实现都遵循此契约:
- 扩展名不匹配时立即返回 false,不修改任何状态;
- 内容检查失败时也返回 false;
- 只有确定能处理时才保存 src/dst。

#### 13.1.4 MF_SERVER 宏的统一差异控制

通过 `MF_SERVER` 宏的条件编译,同一份源码可生成两种打包器:
- **客户端打包器**:剥离服务端实体、保留客户端实体、处理图形资源、LOD 优化;
- **服务端打包器**:剥离客户端实体、保留服务端实体、跳过图形资源、保留完整地形数据。

这避免了维护两套代码,同时保证发布产物精简。

#### 13.1.5 FileDeleter RAII 临时文件管理

`PackerHelper::FileDeleter` 在构造时保存文件路径,析构时删除文件。ChunkPacker 用它管理 `.packerTemp`:

```cpp
BW::string tempFile = dst_ + ".packerTemp";
PackerHelper::copyFile( src_, tempFile );
PackerHelper::FileDeleter deleter( tempFile ); // 作用域结束自动删除
// ... 处理 tempFile ...
```

即使处理过程抛异常,临时文件也会被清理。

#### 13.1.6 DummyChunkTerrain 地形加载劫持

CDataPacker 通过临时替换 `Chunk::getFactories()`,只注册一个 `DummyChunkTerrain` 工厂,从而**只加载地形块数据**用于 LOD 判断,避免加载模型、粒子等无关渲染资源。这是一种**精巧的依赖注入**手法,通过 RAII(`InitTerrainDependencies`)保证工厂恢复。

#### 13.1.7 LOD 感知的按需剥离

CDataPacker 不是机械地剥离所有 LOD 数据,而是根据 chunk 的 `getForcedLod()` 和 `TerrainRenderer2::getDrawFlag` 判断**该 LOD 层级实际会绘制哪些数据**,只剥离不绘制的部分。这最大化保留了运行时需要的数据,同时最小化发布体积。

#### 13.1.8 中断恢复的交互式确认

批量模式下,CTRL+C 不会立即终止程序,而是:
1. 信号处理设置 `s_quitRequested = true`;
2. 当前文件处理完成后询问 `Do you want to continue [y/n]?`;
3. 输入 `y` 则重新注册信号处理继续,输入 `n` 则退出。

这避免了处理到一半的文件损坏,同时给用户选择权。

### 13.2 注意事项

#### 13.2.1 Packer 单例状态污染

`CDataPacker` 的 `DummyChunkTerrain` 静态成员(`s_terrainBlock`/`s_terrainSettings`/`s_terrainChunkCDataFilename`)是**共享状态**。如果 `Packers::find()` 调用 `CDataPacker::prepare()` 但随后又调用了其他 Packer 的 `prepare()`(因 CDataPacker 返回 true 不会发生),但这些静态变量在下次调用时会被覆盖。当前设计安全,因为 `find()` 找到第一个就返回。

#### 13.2.2 prepare() 的副作用风险

虽然约定 `prepare()` 应无副作用,但 `CDataPacker::prepare()` 会**修改全局 Chunk 工厂**(通过 `InitTerrainDependencies`),且会**加载地形块**到静态变量。如果 `prepare()` 返回 true 后,由于某种原因 `pack()` 未被调用(如 `print` 模式),这些状态会残留。不过 `InitTerrainDependencies` 是 RAII,会在 `prepare()` 返回时恢复工厂。

#### 13.2.3 全局对象初始化顺序

`PackerFactory` 是全局静态对象,其初始化顺序跨编译单元**未定义**。但由于所有 priority=0 的 Packer 处理的扩展名互斥,顺序不影响正确性。若新增一个与现有 Packer 扩展名重叠的 Packer,需显式设置优先级。

#### 13.2.4 token 机制的脆弱性

`*_token` 机制依赖链接器不丢弃未直接引用的 `.o` 文件。如果 `main.cpp` 遗漏某个 token,对应的 Packer 可能被链接器优化掉,导致运行时 `find()` 找不到处理器。新增 Packer 必须同步更新 `main.cpp` 的 `s_chunkTokenSet`。

#### 13.2.5 copyFile 的 static 缓冲区非线程安全

`PackerHelper::copyFile` 使用 `static char buf[32768]`,若多线程并发调用会数据竞争。当前 `res_packer` 是单线程处理(批量模式串行),无问题。但若未来并行化需改造。

#### 13.2.6 isFileNewer 的 Linux 未实现

`PackerHelper::isFileNewer` 在非 Windows 平台直接返回 false(`// ***TODO***`),意味着 Linux 上增量打包不可用。不过实际发布流程通常在 Windows 上进行。

#### 13.2.7 隐藏参数 --encrypt 与 --strip

`--encrypt` 和 `--strip` 在 `printUsage` 中未文档化,属于内部功能。`--encrypt` 用于 1.8.0 评估版的 DDS 加密(让 XmlPacker 接管 DDS),`--strip` 用于运行时动态指定剥离的 cdata section。普通用户不应依赖这些参数,因未来版本可能变更。

#### 13.2.8 服务端打包的"跳过"语义

服务端打包时,FxPacker/ImagePacker/ModelAnimPacker 的 `pack()` 直接返回 true 但**不复制文件**。这意味着服务端发布产物**不包含**这些图形资源文件。调用方需自行决定是否复制(通常服务端不需要图形资源)。

#### 13.2.9 asset list 的换行符处理

`buf[ strlen(buf) - 1 ] = 0;` 简单地去除最后一个字符(假设是 `\n`)。若文件使用 `\r\n`(Windows)换行,`\r` 会残留,可能导致路径错误。建议使用 `fgets` 后显式去除 `\r\n`。当前代码在 Windows 上运行时,`fgets` 会保留 `\n`,所以 `buf[strlen-1]=0` 去掉 `\n`,但若文件是 Unix 换行则在 Windows 上可能有问题。

#### 13.2.10 Moo 初始化的窗口残留

`PackerHelper::initMoo` 创建了一个 100x100 的 `WS_OVERLAPPEDWINDOW` 窗口,但代码中**未显式销毁**。依赖进程退出时的资源回收。这在长时间运行的批量模式下不会有问题,但不够优雅。

### 13.3 性能考量

#### 13.3.1 find() 的线性遍历

`Packers::find()` 最坏需调用所有 6 个 Packer 的 `prepare()`。由于扩展名检查是 O(1) 字符串比较,性能可接受。但 CDataPacker 的 `prepare()` 会加载地形块(磁盘 IO + 解析),若大量 `.cdata` 文件处理,每次 `find()` 都会触发 CDataPacker 的 `prepare()` 失败路径(扩展名不匹配,立即返回 false),无性能影响。

#### 13.3.2 兼容模式 vs 批量模式的资源初始化

两种模式都调用 `initResources` + `initMoo`,但批量模式只初始化一次,处理 N 个文件;兼容模式每次运行只处理 1 个文件。因此**批量模式效率远高于兼容模式**(无需重复初始化 D3D 设备)。`printUsage` 也强调 "The batch list mode is the new, fast way of using res_packer"。

#### 13.3.3 CDataPacker 的同步等待

`while (BgTaskManager::instance().numBgTasksLeft() > 0) { Yield(); }` 是忙等待,会消耗 CPU。代码注释提到 `BgTaskManager::numBgTasksLeft` 有竞态条件(任务在 active list 和 task list 之间迁移的窗口),可能导致提前退出。原作者保留了现有行为,等待正确修复。

---

## 附录 A:6 个 Packer 对照表

| Packer | 优先级 | 扩展名 | 客户端行为 | 服务端行为 | 复杂度 |
|--------|--------|--------|-----------|-----------|--------|
| **XmlPacker** | LOWEST (0xFFFF) | 任意(XML 内容) | PackedSection::convert + 剥离 metaData | 同客户端 | 低 |
| **ChunkPacker** | HIGHEST (0) | `.chunk` | 剥离服务端实体 + editorOnly/metaData/navmesh/worldNavmesh | 剥离客户端实体 + editorOnly/metaData/navmesh | 中 |
| **CDataPacker** | HIGHEST (0) | `.cdata` | 剥离缩略图/navmesh + LOD 感知剥离地形数据 | 仅剥离缩略图/navmesh | **高** |
| **FxPacker** | HIGHEST (0) | `.fx`/`.fxh`/`.fxo` | 按 config.hpp 复制 | 全部跳过 | 低 |
| **ImagePacker** | HIGHEST (0) | `.bmp`/`.tga`/`.png`/`.jpg`/`.dds` | DDS 字体检测 + 优先复制 DDS | 全部跳过 | 中 |
| **ModelAnimPacker** | HIGHEST (0) | `.model`/`.animation`/`.anca` | 加载模型生成 anca + PackedSection | 全部跳过 | 中 |

---

## 附录 B:常见问题澄清

### B.1 为什么 XmlPacker 用 LOWEST_PRIORITY?

`XmlPacker` 的 `prepare()` 通过**读取文件内容**判断是否为 XML(以 `<` 开头),而非扩展名。若它的优先级高,会"抢走" `.chunk` 等 XML 格式文件,导致专用 Packer 无法处理。设为 `LOWEST_PRIORITY` 保证专用 Packer 优先,只有它们都拒绝时才由 XmlPacker 兜底。

### B.2 为什么 CDataPacker 需要加载地形块?

CDataPacker 需要**判断运行时该 chunk 的 LOD 层级会绘制哪些数据**,这必须加载地形块(`BaseTerrainBlock`)获取 `getForcedLod()`,并结合 `TerrainRenderer2` 的距离判断。仅靠文件扩展名或 DataSection 无法获得这些信息。

### B.3 为什么需要 DummyChunkTerrain?

正常的 `Chunk::loadInclude` 会加载所有 ChunkItem(模型、粒子、灯光等),这非常耗时且不需要。`DummyChunkTerrain` 替换正常的 `ChunkTerrain` 工厂,只加载地形块数据,忽略其他 ChunkItem,大幅加速 LOD 判断。

### B.4 为什么服务端打包跳过图形资源?

服务端不渲染图形,不需要贴图、模型、Shader。但服务端需要 `.chunk`(碰撞检测、实体位置)和 `.cdata`(地形碰撞、寻路)。因此 FxPacker/ImagePacker/ModelAnimPacker 在服务端直接跳过,而 ChunkPacker/CDataPacker 仍处理但保留更多数据。

### B.5 --encrypt 为什么让 ImagePacker 拒绝 DDS?

加密模式下,DDS 文件需要通过 `PackedSection::convert` 加密。`ImagePacker` 只是复制文件,不支持加密,因此 `prepare()` 检测到 `shouldEncrypt` 时返回 false,让 `XmlPacker` 接管 DDS 文件进行加密打包。这是 1.8.0 评估版的临时方案。

### B.6 为什么 ChunkPacker 先复制到临时文件?

`PackedSection`(二进制段)是**只读**的,无法直接编辑。ChunkPacker 需要删除 `entity` section,必须先复制到可编辑的文本 XML 临时文件,修改后再用 `PackedSection::convert` 转换为二进制。`FileDeleter` 确保临时文件清理。

### B.7 PackerFactory 为什么不用 std::shared_ptr?

`PackerFactory` 构造时 `new P()` 裸指针交给 `Packers::add()`,`Packers` 也只存储裸指针。这是因为 Packer 是**进程级单例**,程序退出时由 OS 回收,无需手动释放。使用智能指针反而增加复杂度且无实际收益。

### B.8 为什么 ModelAnimPacker 跳过 .animation 和 .anca?

`.animation` 和 `.anca` 文件在打包 `.model` 时会被**间接处理**:`Model::loadAnimations` 会读取 `.animation` 并生成压缩的 `.anca`。直接打包 `.anca` 没有意义(它已二进制),`.animation` 也不需要单独打包(会被模型引用)。因此 `pack()` 对这两种类型直接返回 true(跳过)。

### B.9 asset list 文件能否用相对路径?

可以,且**必须**用相对路径。程序拼接为 `inPath + "\\" + line`,若 line 是绝对路径会出错。asset list 中的路径相对于 `--in`/`--out` 根目录。

### B.10 res_packer 能否增量打包?

`PackerHelper::isFileNewer` 提供了文件时间比较能力,但 `res_packer` 本身**未实现增量逻辑**——它总是处理 asset list 中的所有文件。增量打包需由调用方(如构建系统)通过 `isFileNewer` 筛选后生成 asset list。

---

> **文档总结**: `res_packer` 通过策略模式 + 优先级注册实现了可扩展的资源打包框架,6 个 Packer 各司其职,通过 `MF_SERVER` 宏统一控制客户端/服务端差异。CDataPacker 是最复杂的 Packer,涉及地形加载劫持和 LOD 感知剥离。XmlPacker 作为 LOWEST_PRIORITY 兜底,处理所有未识别的 XML 文件。整体设计遵循开闭原则,新增 Packer 无需修改框架代码。
