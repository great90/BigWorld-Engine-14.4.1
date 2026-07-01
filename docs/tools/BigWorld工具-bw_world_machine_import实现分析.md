# BigWorld 工具 - bw_world_machine_import 实现分析

> 源码位置：`programming/bigworld/tools/bw_world_machine_import/`
> 引擎版本：BigWorld Engine 14.4.1
> 文档版本：1.0

---

## 目录

- [1. 概述](#1-概述)
  - [1.1 工具定位](#11-工具定位)
  - [1.2 World Machine 与 BigWorld 的关系](#12-world-machine-与-bigworld-的关系)
  - [1.3 核心能力](#13-核心能力)
- [2. 目录结构](#2-目录结构)
  - [2.1 文件清单](#21-文件清单)
  - [2.2 文件职责矩阵](#22-文件职责矩阵)
  - [2.3 工程文件与构建配置](#23-工程文件与构建配置)
- [3. DLL 入口与 World Machine 集成](#3-dll-入口与-world-machine-集成)
  - [3.1 插件契约](#31-插件契约)
  - [3.2 三个导出函数](#32-三个导出函数)
  - [3.3 设备枚举机制](#33-设备枚举机制)
  - [3.4 生命周期回调](#34-生命周期回调)
- [4. BWHeightImport 核心类](#4-bwheightimport-核心类)
  - [4.1 类继承关系](#41-类继承关系)
  - [4.2 类声明](#42-类声明)
  - [4.3 构造函数与参数注册](#43-构造函数与参数注册)
  - [4.4 Load/Save 项目序列化](#44-loadsave-项目序列化)
- [5. Activate 导入流程](#5-activate-导入流程)
  - [5.1 流程概览](#51-流程概览)
  - [5.2 创建目标高度场](#52-创建目标高度场)
  - [5.3 计算坐标变换参数](#53-计算坐标变换参数)
  - [5.4 计算重叠区域](#54-计算重叠区域)
  - [5.5 遍历 chunk 加载高度图](#55-遍历-chunk-加载高度图)
  - [5.6 双线性采样映射](#56-双线性采样映射)
  - [5.7 进度上报与输出](#57-进度上报与输出)
  - [5.8 loadHeightMap 辅助函数](#58-loadheightmap-辅助函数)
- [6. SpaceHelper](#6-spacehelper)
  - [6.1 类声明](#61-类声明)
  - [6.2 init 初始化](#62-init-初始化)
  - [6.3 getCDataForChunk](#63-getcdataforchunk)
  - [6.4 outsideChunkIdentifier 命名规则](#64-outsidechunkidentifier-命名规则)
- [7. 配置参数](#7-配置参数)
  - [7.1 四个参数详解](#71-四个参数详解)
  - [7.2 resetChunkScale 实现](#72-resetchunkscale-实现)
  - [7.3 selectSpace 实现](#73-selectspace-实现)
- [8. 依赖关系](#8-依赖关系)
  - [8.1 World Machine SDK 依赖](#81-world-machine-sdk-依赖)
  - [8.2 BigWorld 库依赖](#82-bigworld-库依赖)
  - [8.3 Windows API 依赖](#83-windows-api-依赖)
  - [8.4 依赖关系图](#84-依赖关系图)
- [9. 设计亮点](#9-设计亮点)
  - [9.1 跨系统坐标变换](#91-跨系统坐标变换)
  - [9.2 重叠区域计算](#92-重叠区域计算)
  - [9.3 双线性采样保真](#93-双线性采样保真)
  - [9.4 增量式 chunk 流式处理](#94-增量式-chunk-流式处理)
  - [9.5 版本化的项目序列化](#95-版本化的项目序列化)
  - [9.6 与引擎 cdata 格式解耦](#96-与引擎-cdata-格式解耦)
- [10. 常见误区与澄清](#10-常见误区与澄清)
- [11. 附录](#11-附录)
  - [11.1 术语表](#111-术语表)
  - [11.2 关键文件行号索引](#112-关键文件行号索引)

---

## 1. 概述

### 1.1 工具定位

`bw_world_machine_import` 是 BigWorld Engine 14.4.1 提供的 **World Machine 插件**，它以
DLL 形式被 World Machine（一款专业地形生成软件）加载，用于将 BigWorld 空间中已有的
地形高度数据**反向导入**到 World Machine 工程中，作为后续地形编辑、侵蚀模拟、纹理生成
等算法的输入。

| 维度 | 说明 |
|------|------|
| 工具类型 | World Machine 设备插件（Device Plugin） |
| 输出形态 | Windows DLL（`bw_height_import64.dll`） |
| 设备类型 | `TYPE_GENERATOR`（生成器，无输入端口，1 个输出端口） |
| 数据流向 | BigWorld `.cdata` → World Machine `HField` |
| 交互入口 | World Machine 设备参数面板（Height Scale / Chunk Scale / Reset / Select space） |
| 主要场景 | 在 World Machine 中对已建好的 BigWorld 地形进行二次加工 |

### 1.2 World Machine 与 BigWorld 的关系

```
┌────────────────────────┐         ┌──────────────────────────┐
│      World Machine      │         │       BigWorld 引擎       │
│   (地形编辑/侵蚀模拟)    │         │   (空间/chunk/terrain)    │
│                          │         │                          │
│  ┌──────────────────┐   │  加载    │   space.settings         │
│  │  HField (高度场)  │◄──┼─────────│   xxxxzzzzo.cdata        │
│  └────────▲─────────┘   │         │   ├─ terrain2/heights    │
│           │              │         │   └─ (压缩的高度数据)     │
│  ┌────────┴─────────┐   │         │                          │
│  │ bw_height_import │   │         │                          │
│  │   (本插件 DLL)    │───┼─────────►│                          │
│  └──────────────────┘   │  读取    │                          │
└────────────────────────┘         └──────────────────────────┘
```

World Machine 使用「设备图」（Device Graph）组织地形成型流程，每个设备（Device）继承自
`Generator`/`Modifier`/`Output` 等基类。本插件实现的 `BWHeightImport` 即是一个
`Generator`，它从 BigWorld 的 chunk 文件读取已压缩的高度图，按双线性采样写入 World
Machine 的 `HField`，从而把 BigWorld 地形"喂给"World Machine 的后续设备。

### 1.3 核心能力

1. **空间选择**：通过 `Select space` 按钮调用 Windows 通用打开对话框，选择
   `space.settings` 文件，自动解析空间边界、chunkSize、singleDir 等元数据。
2. **chunk 遍历**：根据 World Machine 高度场在世界坐标中的范围与 BigWorld 空间范围的
   交集，确定需要加载的 chunk 网格 `(chunkXMin..chunkXMax, chunkZMin..chunkZMax)`。
3. **高度图解码**：从每个 chunk 的 `.cdata` 中读取 `terrain2/heights` 二进制块，校验
   `HeightMapHeader` 的 magic 与 version，调用 `decompressHeightMap` 解压为
   `Moo::Image<float>`。
4. **坐标映射 + 双线性采样**：将 World Machine 高度场每个像素映射回 BigWorld chunk
   本地坐标，使用 `getBilinear` 进行双线性插值采样，保证不同分辨率间的平滑过渡。
5. **进度上报**：通过 `context.ReportProgress` 向 World Machine 报告逐行进度，避免长
   时间无响应。
6. **项目序列化**：`Load`/`Save` 将所选空间根路径以 `BWHI` 标签 + 版本号的形式写入
   World Machine 工程文件，便于工程复现。

---

## 2. 目录结构

### 2.1 文件清单

```
programming/bigworld/tools/bw_world_machine_import/
├── bw_height_import.cpp        # BWHeightImport 主实现（Activate 流程核心）
├── bw_height_import.hpp        # BWHeightImport 类声明
├── bw_height_import.rc         # Windows 资源文件（工具栏图标）
├── bw_height_import.sln        # Visual Studio 解决方案
├── bw_height_import.vcproj     # Visual Studio 工程文件（支持 Win32 / x64）
├── bw_height_import_icon.bmp   # 设备图标位图
├── pch.cpp                     # 预编译头源文件
├── pch.hpp                     # 预编译头（仅包含 cstdmf_windows.hpp）
├── resource.h                  # 资源 ID 定义
├── space_helper.cpp            # SpaceHelper 实现
├── space_helper.hpp            # SpaceHelper 类声明
├── wm_plugin_shell.cpp         # 3 个 DLL 导出函数实现
└── wm_plugin_shell.hpp         # 3 个 DLL 导出函数声明
```

### 2.2 文件职责矩阵

| 文件 | 行数 | 职责 | 关键内容 |
|------|------|------|----------|
| `wm_plugin_shell.hpp` | 13 | DLL 导出契约 | 3 个 `extern "C"` 导出函数声明 |
| `wm_plugin_shell.cpp` | 49 | DLL 导出实现 | `SetupGlobalAccess`/`GetHeaderVersion`/`GetDevPlugin` |
| `bw_height_import.hpp` | 42 | 主类声明 | `BWHeightImport : public Generator` |
| `bw_height_import.cpp` | 314 | 主类实现 | 构造、Load/Save、Activate、resetChunkScale、selectSpace、loadHeightMap |
| `space_helper.hpp` | 48 | 空间助手声明 | `SpaceHelper` 类 |
| `space_helper.cpp` | 93 | 空间助手实现 | init、getCDataForChunk |
| `pch.hpp` | 5 | 预编译头 | `cstdmf_windows.hpp` |
| `resource.h` | 16 | 资源 ID | `IDB_BITMAP1 = 102` |
| `bw_height_import.rc` | 68 | 资源定义 | 工具栏位图 `IDB_TOOLBAR_GFX` |

### 2.3 工程文件与构建配置

`bw_height_import.vcproj` 是 Visual Studio 2008 格式的工程文件，关键配置如下：

- **目标平台**：Win32 与 x64（实际部署以 x64 为主，输出文件名带 `64` 后缀）
- **配置类型**：`ConfigurationType="2"`（Dynamic Library，即 DLL）
- **输出文件**：`$(OutDir)\$(ProjectName)64.dll`（如 `bw_height_import64.dll`）
- **链接依赖**：
  - Debug x64：`..\lib\PluginCore64D.lib`（L126）
  - Release Win32：`PluginCore.lib`（L210）
  - Release x64：`..\lib\PluginCore64.lib`（L294）
- **附加包含目录**：`..\..\lib\third_party\worldmachine;..\..\lib`（L187）
- **预处理宏**：`WIN32;_WINDOWS;_USRDLL;_DEBUG;INVERTEREXAMPLE_EXPORTS`（L106，沿用了
  World Machine SDK 示例的宏名）
- **额外编译源**：直接编入 `..\..\lib\terrain\height_map_compress.cpp` 与
  `..\..\lib\moo\png.cpp`（L414/L430），以避免依赖完整的 terrain/moo 库

> 注：工程未提供 CMakeLists.txt，构建依赖 Visual Studio 工程；`PluginCore64.lib` 由
> World Machine SDK 提供，存放于 `..\lib\` 即 `programming/bigworld/lib/` 下的世界机器
> SDK 子目录。

---

## 3. DLL 入口与 World Machine 集成

### 3.1 插件契约

World Machine 通过一套 C 风格的导出函数契约加载第三方设备插件。每个插件 DLL 必须导出
以下三个函数，名称、签名、调用约定均由 SDK 固定：

```cpp
// wm_plugin_shell.hpp L9-13
extern "C" { 
__declspec(dllexport) void SetupGlobalAccess(WMGlobalStruc *global);
__declspec(dllexport) int  GetHeaderVersion();
__declspec(dllexport) bool GetDevPlugin(const int i, DevPluginStruc *result);
};
```

- 必须使用 `extern "C"` 避免 C++ 名称修饰，保证 World Machine 能按名称找到符号。
- `__declspec(dllexport)` 在 x64 下无需显式指定调用约定（x64 只有一种调用约定）。

### 3.2 三个导出函数

#### 3.2.1 SetupGlobalAccess

```cpp
// wm_plugin_shell.cpp L10-13
void SetupGlobalAccess(WMGlobalStruc *global) 
{
    WMGlobal = global;
};
```

- **调用时机**：DLL 加载后第一时间被调用。
- **作用**：将 World Machine 传入的全局结构指针保存到全局变量 `WMGlobal`（由 SDK 头文
  件声明）。`WMGlobal` 中包含 `km_wm_relation`（千米与 World Machine 单位换算系数）等
  后续 `Activate` 计算所需的关键常量。
- **设计要点**：这是插件访问 World Machine 运行时上下文的唯一入口，所有依赖
  World Machine 全局状态的代码都隐式依赖此处完成的初始化。

#### 3.2.2 GetHeaderVersion

```cpp
// wm_plugin_shell.cpp L19-22
int  GetHeaderVersion() 
{
    return WM_PLUGIN_HEADER_VERSION;
};
```

- **作用**：返回插件编译时所基于的 SDK 头文件版本号。
- **用途**：World Machine 在加载时会比对该版本号与自身 SDK 版本是否兼容，不匹配则拒绝
  加载，避免 ABI 不一致导致的崩溃。
- `WM_PLUGIN_HEADER_VERSION` 是 SDK 提供的宏，定义于 `core/Plugin_Header.h`。

#### 3.2.3 GetDevPlugin

```cpp
// wm_plugin_shell.cpp L28-49
bool GetDevPlugin(const int i, DevPluginStruc *result) 
{
    if (!result)
    {
        return false;
    }

    DevPluginStruc dat;

    if (i == 0)
    {
        Device *dev =  new BWHeightImport;
        dat.lifedata = dev->GetLifeVars();
        strcpy_s(dat.name, dev->GetTypeName());
        dat.type = TYPE_GENERATOR;
        delete dev;
        *result = dat;
        return true;
    }

    return false;
};
```

- **调用方式**：World Machine 以 `i = 0, 1, 2, ...` 反复调用，直到返回 `false` 为止，
  实现设备枚举。
- **本插件行为**：仅 `i == 0` 时返回一个 `BWHeightImport` 设备的信息，`i >= 1` 返回
  `false`，即整个 DLL 只注册一个设备。
- **关键技巧**：临时 `new BWHeightImport` 取其生命周期变量与类型名，再立即 `delete`。
  这是因为 `GetLifeVars()` 与 `GetTypeName()` 是虚函数，需要实例化对象才能调用；但实际
  的设备实例由 World Machine 通过 `lifedata.maker`（创建函数指针）在需要时另行创建，
  此处仅用于"元信息采样"。
- **`DevPluginStruc` 字段填充**：
  - `lifedata`：含 `maker`/`killer`/`nametag`，由 `BWHeightImport` 构造函数设置（见
    §4.3）。
  - `name`：设备显示名，拷贝自 `GetTypeName()` 返回的 `"BigWorld Height Importer"`。
  - `type`：`TYPE_GENERATOR`，告知 World Machine 这是一个生成器设备。

### 3.3 设备枚举机制

```
World Machine 加载 DLL
        │
        ▼
调用 SetupGlobalAccess(global)      ← 注入全局结构
        │
        ▼
调用 GetHeaderVersion()             ← 版本校验
        │
        ▼
调用 GetDevPlugin(0, &result)  ─────►  返回 BWHeightImport 元信息
        │
        ▼
调用 GetDevPlugin(1, &result)  ─────►  返回 false，枚举结束
        │
        ▼
设备列表中新增 "BigWorld Height Importer" (Generator)
        │
        ▼
用户拖入设备图 → World Machine 调用 lifedata.maker() 创建实例
```

### 3.4 生命周期回调

`BWHeightImport` 构造函数中设置了三个生命周期回调（见 §4.3），由 World Machine 在
需要时通过函数指针调用：

| 字段 | 函数 | 作用 |
|------|------|------|
| `lifeptrs.maker` | `BWHeightImportMaker` | `new BWHeightImport`，创建实例 |
| `lifeptrs.killer` | `BWHeightImportKiller` | `delete spr`，销毁实例 |
| `lifeptrs.nametag` | `"BWHI"` | 4 字节标签，用于 Load/Save 时识别本设备的数据块 |

```cpp
// bw_height_import.cpp L36-37
Device *BWHeightImportMaker() { return new BWHeightImport; };
void BWHeightImportKiller(Device *spr) { delete spr; };
```

---

## 4. BWHeightImport 核心类

### 4.1 类继承关系

```
World Machine SDK
    │
    ▼
  Device                       ← SDK 基类（抽象设备）
    │
    ▼
  Generator                    ← SDK 基类（生成器，无输入端口）
    │
    ▼
  BWHeightImport               ← 本插件实现
   ├── spaceHelper_ : BW::SpaceHelper   ← 组合，封装 BigWorld 空间访问
   ├── Activate()                        ← 核心导入流程
   ├── Load() / Save()                   ← 工程序列化
   ├── resetChunkScale()                 ← UI 按钮回调
   └── selectSpace()                     ← UI 按钮回调
```

`Generator` 基类提供：
- `SetLinks(inCount, outCount)`：声明输入/输出端口数。本插件 `SetLinks(0, 1)`（无输入，
  1 个高度场输出）。
- `AddParam(Parameter)`：注册参数。本插件注册 4 个参数（见 §7）。
- `ParmFRef(name)`：按名读取浮点参数值。
- `Load(in)`/`Save(out)`：基类默认的参数序列化，子类可重写以追加自定义数据。
- `GetNewHF(worldSize)`：根据世界尺寸创建新的 `HField`。
- `StoreData(map, port, context)`：将高度场输出到指定端口。

### 4.2 类声明

```cpp
// bw_height_import.hpp L12-41
class BWHeightImport :
    public Generator
{
public:

    static const char* HEIGH_SCALE_PROPERTY;     // "Height Scale"
    static const char* CHUNK_SCALE_PROPERTY;     // "Chunk Scale"

    BWHeightImport(void);
    virtual ~BWHeightImport(void);

    virtual bool Load(std::istream &in);
    virtual bool Save(std::ostream &out);

    virtual char *GetDescription() { return "Import height map from BigWorld space";};
    virtual char *GetTypeName() { return "BigWorld Height Importer"; };

    // 该生成器无原点概念
    virtual bool hasOrigin() { return false; };

    virtual bool Activate(BuildContext &context);

    void resetChunkScale();
    void selectSpace();

protected:
    BW::SpaceHelper spaceHelper_;
};
```

设计要点：
- 两个静态字符串常量 `HEIGH_SCALE_PROPERTY` / `CHUNK_SCALE_PROPERTY` 用于在注册参数与
  `Activate` 中按名引用，避免魔法字符串散落。
- `hasOrigin()` 返回 `false`：World Machine 中部分设备有"原点"概念（如噪声生成器以原
  点为参考），本导入器不需要，因为高度直接来自 BigWorld 空间。
- `spaceHelper_` 以组合方式持有，封装所有 BigWorld 空间访问逻辑，使 `BWHeightImport`
  本身聚焦于 World Machine 协议适配。

### 4.3 构造函数与参数注册

```cpp
// bw_height_import.cpp L44-64
BWHeightImport::BWHeightImport(void)
{
    lifeptrs.maker = BWHeightImportMaker;
    lifeptrs.killer = BWHeightImportKiller;
    strncpy(lifeptrs.nametag, "BWHI", 4);

    SetLinks(0, 1);

    // Parameters
    AddParam(Parameter(HEIGH_SCALE_PROPERTY, 1.f, 0.0f, 10000.0f));
    AddParam(Parameter(CHUNK_SCALE_PROPERTY, 100.f, 0.0f, 10000.0f));
    AddParam(Parameter("Reset Chunk Scale", (VPtrType)&BWHeightImport_resetChunkScale));
    AddParam(Parameter("Select space", (VPtrType)&BWHeighImport_selectSpace));

    // Help strings
    params.GetParam(0)->setHelpString("Height scale of the terrain");
    params.GetParam(1)->setHelpString("Chunk scale for the terrain");
    params.GetParam(2)->setHelpString("Reset the Chunk scale of the terrain");
    params.GetParam(3)->setHelpString("Select a space");
}
```

构造函数完成三件事：

1. **设置生命周期回调**：注册 `maker`/`killer`/`nametag`，使 World Machine 能在
   `GetDevPlugin` 之外的时机创建/销毁实例。
2. **声明端口**：`SetLinks(0, 1)` — 0 输入，1 输出（高度场）。
3. **注册 4 个参数**：
   - `Height Scale`：浮点参数，默认 `1.0`，范围 `[0, 10000]`，从 BigWorld 高度单位到
     World Machine 高度单位的缩放因子。
   - `Chunk Scale`：浮点参数，默认 `100.0`（即 BigWorld 默认网格分辨率），范围
     `[0, 10000]`，BigWorld chunk 的边长（米）。
   - `Reset Chunk Scale`：按钮参数，回调 `BWHeightImport_resetChunkScale`，将 Chunk
     Scale 重置为当前空间的 `chunkSize`。
   - `Select space`：按钮参数，回调 `BWHeighImport_selectSpace`，弹出文件选择对话框选
     择 `space.settings`。

> 注：按钮参数通过 `(VPtrType)&function` 的方式注册函数指针，World Machine 在用户点击
> 按钮时以设备实例指针为参数调用该函数（见 §7.2/§7.3 的桥接函数）。

### 4.4 Load/Save 项目序列化

World Machine 工程文件（`.tmw`/`.tmd`）会按设备树依次调用每个设备的 `Load`/`Save`，
本插件在基类参数序列化的基础上**前置**了自定义数据块：

#### 4.4.1 Save

```cpp
// bw_height_import.cpp L102-113
bool BWHeightImport::Save(std::ostream &out) 
{
    out.write( lifeptrs.nametag, 4);             // "BWHI" 标签
    int ver = 1;
    out.write((char*) &ver, 1);                  // 版本号 1 字节

    char spaceRoot[256];
    bw_snprintf( spaceRoot, 256, spaceHelper_.spaceRoot().c_str() );
    out.write( spaceRoot, 256 );                 // 空间根路径（定长 256 字节）

    return Generator::Save(out);                 // 基类参数序列化
};
```

数据布局：

```
┌──────────┬─────────┬──────────────────────────────┬────────────────┐
│ "BWHI"   │ ver(1B) │ spaceRoot(256B, 定长)        │ 基类参数数据    │
└──────────┴─────────┴──────────────────────────────┴────────────────┘
```

- `spaceRoot` 写成 256 字节定长，便于 Load 时按固定偏移读取。
- 最后调用 `Generator::Save(out)` 让基类处理参数列表的序列化。

#### 4.4.2 Load

```cpp
// bw_height_import.cpp L77-95
bool BWHeightImport::Load(std::istream &in) {
    char tag[5];
    in.read( tag, 4);
    if (strncmp(tag, lifeptrs.nametag, 4) == 0) 
    {
        int ver = 0;
        in.read((char*) &ver, 1);

        char spaceRoot[257];
        spaceRoot[256] = 0;
        in.read( spaceRoot, 256 );

        spaceHelper_.init( spaceRoot + BW::string("space.settings") );

        return Generator::Load(in);
    }
    else
        return false;
};
```

- 先读 4 字节标签，与 `"BWHI"` 比对；不匹配则返回 `false` 表示数据损坏或类型不符。
- 读 1 字节版本号（当前未使用，但为未来格式演进预留）。
- 读 256 字节空间根路径，**自动拼接** `"space.settings"` 后调用
  `spaceHelper_.init()` 重新初始化空间助手。
- 最后调用 `Generator::Load(in)` 让基类恢复参数。

设计意图：用户在 World Machine 中保存工程后重新打开，所选空间会自动恢复，无需再次手
动选择，工程可复现。

---

## 5. Activate 导入流程

`Activate` 是 `Generator` 基类的核心虚函数，World Machine 在构建设备图时调用它来产生
输出数据。本插件的 `Activate` 是整个工具的灵魂，完成从 BigWorld chunk 到 World
Machine 高度场的全部转换。

### 5.1 流程概览

```
Activate(context)
    │
    ▼
[1] map = GetNewHF(context.GetWorldSize())   ← 创建目标高度场
    │
    ▼
[2] map->Clear()
    │
    ▼
[3] spaceHelper_.valid() ?                   ← 校验空间已选择
    │   否 → 直接 StoreData(map) 返回（输出空白）
    │   是 ↓
    ▼
[4] 计算 heightScale / destOffset / destSize / chunkScale
    │
    ▼
[5] 计算 chunkXMin..chunkXMax × chunkZMin..chunkZMax（重叠区域）
    │
    ▼
[6] for chunkZ in [chunkZMin..chunkZMax]:
       for chunkX in [chunkXMin..chunkXMax]:
          [6.1] loadHeightMap(cdata, heights)   ← 解码高度图
          [6.2] 计算 chunkCorner / xStart,yStart,xEnd,yEnd
          [6.3] 计算 gradient / cornerOffset
          [6.4] for y in [yStart..yEnd):
                   for x in [xStart..xEnd):
                      (*map)[Coord(x,y)] = heightScale * heights.getBilinear(...)
                   ReportProgress(++buildProgress, numBuildSteps)
    │
    ▼
[7] StoreData(map, 0, context)               ← 输出到端口 0
    │
    ▼
返回 true
```

### 5.2 创建目标高度场

```cpp
// bw_height_import.cpp L167-170
HField *map = GetNewHF(context.GetWorldSize());
map->Clear();
```

- `context.GetWorldSize()` 返回 `SizeData` 结构，描述 World Machine 当前世界尺寸
  （分辨率、物理范围、垂直缩放等）。
- `GetNewHF` 由 `Generator` 基类提供，按 World Machine 全局设置创建一个空白
  `HField`（高度场）。
- `Clear()` 将所有高度清零，避免后续采样未覆盖区域残留脏数据。

### 5.3 计算坐标变换参数

```cpp
// bw_height_import.cpp L174-190
if (spaceHelper_.valid())
{
    const SizeData& sd = context.GetWorldSize();

    // 从 BigWorld 高度单位到 World Machine 的缩放
    float heightScale = ParmFRef( HEIGH_SCALE_PROPERTY );
    heightScale *= sd.vert_scale / 1000.f;

    // World Machine 高度场左下角在世界坐标中的位置（米）
    CoordF destOffset = context.GetPanLoc();
    destOffset *= WMGlobal->km_wm_relation * 1000.f;

    // World Machine 高度场在世界坐标中的尺寸（米）
    CoordF destSize = sd.scalesize * WMGlobal->km_wm_relation * 1000.f;

    // 用户定义的 chunk 边长（米）
    float chunkScale = ParmFRef( CHUNK_SCALE_PROPERTY );
```

参数含义：

| 变量 | 来源 | 单位 | 含义 |
|------|------|------|------|
| `heightScale` | `Height Scale` 参数 × `sd.vert_scale / 1000` | 无量纲 | BigWorld 高度（米）→ World Machine 高度单位 |
| `destOffset` | `context.GetPanLoc()` × `km_wm_relation × 1000` | 米 | WM 高度场左下角的世界坐标 |
| `destSize` | `sd.scalesize × km_wm_relation × 1000` | 米 | WM 高度场覆盖的世界尺寸 |
| `chunkScale` | `Chunk Scale` 参数 | 米 | BigWorld chunk 边长 |

- `km_wm_relation` 是 World Machine 全局变量，表示「千米」与「World Machine 内部单位」
  的换算关系。乘以 `1000` 把千米转成米，使 `destOffset`/`destSize` 与 BigWorld 的米
  制坐标统一。
- `sd.vert_scale / 1000.f`：BigWorld 高度图存储的是米，World Machine 高度场可能是
  其他单位（如 1/1000 米），此处把 `Height Scale` 参数再乘以垂直缩放因子，得到最终
  的"米 → WM 高度单位"换算系数。

### 5.4 计算重叠区域

```cpp
// bw_height_import.cpp L194-202
int chunkXMin = max( spaceHelper_.xMin(), 
    int( floorf( destOffset.x / chunkScale ) ) );
int chunkXMax = min( spaceHelper_.xMax(), 
    int( floorf( (destOffset.x + destSize.x) / chunkScale ) ) );

int chunkZMin = max( spaceHelper_.zMin(), 
    int( floorf( destOffset.y / chunkScale ) ) );
int chunkZMax = min( spaceHelper_.zMax(), 
    int( floorf( (destOffset.y + destSize.y) / chunkScale ) ) );
```

这是整个流程中**最关键的几何计算**：求 World Machine 高度场在世界坐标中的矩形范围
`[destOffset.x, destOffset.x + destSize.x] × [destOffset.y, destOffset.y + destSize.y]`
与 BigWorld 空间 chunk 网格 `[xMin..xMax] × [zMin..zMax]` 的交集，结果以 chunk 索引
表示。

```
BigWorld 空间范围
┌─────────────────────────────────────┐ zMax
│                                     │
│      ┌───────────────────┐          │
│      │ WM 高度场范围      │          │
│      │ (destOffset,size) │          │
│      └───────────────────┘          │
│                                     │
└─────────────────────────────────────┘ zMin
   xMin                         xMax

取两者交集 → [chunkXMin..chunkXMax] × [chunkZMin..chunkZMax]
```

- 用 `max` 取左下角的大者，`min` 取右上角的小者，得到交集。
- 用 `floorf` 把米坐标除以 `chunkScale` 转成 chunk 索引。
- 若两者无交集，则 `chunkXMin > chunkXMax` 或 `chunkZMin > chunkZMax`，下面的双重
  for 循环不会执行，`map` 保持空白。

### 5.5 遍历 chunk 加载高度图

```cpp
// bw_height_import.cpp L204-258
int numBuildSteps = (chunkXMax - chunkXMin + 1) * map->h();
int buildProgress = 0;

for (int chunkZ = chunkZMin; chunkZ <= chunkZMax; ++chunkZ)
{
    for (int chunkX = chunkXMin; chunkX <= chunkXMax; ++chunkX)
    {
        BW::Moo::Image<float> heights;

        if (loadHeightMap( spaceHelper_.getCDataForChunk( chunkX, chunkZ ), heights ))
        {
            // chunk 左下角在 WM 高度场坐标系中的位置（米，相对 destOffset）
            CoordF chunkCorner( float(chunkX) * chunkScale, float(chunkZ) * chunkScale );
            chunkCorner -= destOffset;

            // chunk 在目标高度场中的起始像素（浮点）
            float xChunkStart = (chunkCorner.x / destSize.x) * float(map->w());
            float yChunkStart = (chunkCorner.y / destSize.y) * float(map->h());

            // chunk 覆盖的目标像素范围（整数，裁剪到 [0, map尺寸])
            int xStart = int(ceilf( xChunkStart));
            int yStart = int(ceilf(yChunkStart));
            int xEnd = int(ceilf( ((chunkCorner.x + chunkScale) / destSize.x) * float(map->w()) ));
            int yEnd = int(ceilf( ((chunkCorner.y + chunkScale) / destSize.y) * float(map->h()) ));

            xStart = max( xStart, 0 );
            yStart = max( yStart, 0 );
            xEnd = min( xEnd, map->w() );
            yEnd = min( yEnd, map->h() );
            ...
        }
    }
}
```

逐 chunk 处理逻辑：

1. 通过 `spaceHelper_.getCDataForChunk(chunkX, chunkZ)` 获取该 chunk 的 `.cdata`
   `DataSectionPtr`。
2. 调用 `loadHeightMap` 解码出 `heights`（`Moo::Image<float>`，即浮点高度图）。
3. 计算 chunk 左下角在 World Machine 高度场坐标系中的位置：
   - `chunkCorner = (chunkX * chunkScale, chunkZ * chunkScale) - destOffset`
   - 即把 chunk 的世界坐标减去 WM 高度场左下角，得到相对 WM 高度场的米偏移。
4. 把米偏移换算成 WM 高度场的像素坐标：
   - `xChunkStart = (chunkCorner.x / destSize.x) * map->w()`
   - 即「米偏移 / 总米宽 × 总像素宽」= 起始像素。
5. 用 `ceilf` 取整得到 chunk 覆盖的像素区间 `[xStart, xEnd) × [yStart, yEnd)`，再裁剪
   到 `[0, map尺寸]`，防止越界。

> 注：用 `ceilf` 而非 `floorf` 是为了让相邻 chunk 的像素边界严格不重叠，避免同一像素
> 被两个 chunk 重复写入。

### 5.6 双线性采样映射

```cpp
// bw_height_import.cpp L237-255
// 目标高度场每个像素 → 源高度图中的浮点坐标的换算系数
Vector2 gradient( (float( heights.width() - 5) / chunkScale) / (float( map->w() ) / destSize.x),
    (float( heights.height() - 5) / chunkScale) / (float( map->h() ) / destSize.y) );

// 目标 (0,0) 像素对应的源高度图坐标
CoordF cornerOffset( -xChunkStart * gradient.x + 2.f, -yChunkStart * gradient.y + 2.f );

for (int y = yStart; y < yEnd; ++y)
{
    for (int x = xStart; x < xEnd; ++x)
    {
        (*map)[Coord(x,y)] = heightScale * 
            heights.getBilinear( 
            cornerOffset.x + float(x) * gradient.x, 
            cornerOffset.y + float(y) * gradient.y );
    }

    context.ReportProgress( this, ++buildProgress, numBuildSteps );
}
```

**gradient（梯度）的含义**：目标高度场每移动 1 个像素，对应源高度图移动多少像素。

- `float(heights.width() - 5) / chunkScale`：源高度图有效宽度（减去 5 像素边距）除以
  chunk 米宽，得到「每米对应多少源像素」。
- `float(map->w()) / destSize.x`：目标高度场总像素除以总米宽，得到「每米对应多少目标
  像素」。
- 两者相除 = (源像素/米) / (目标像素/米) = 源像素/目标像素 = gradient。

**cornerOffset 的含义**：目标像素 `(0, 0)`（即 chunk 起始像素 `xChunkStart`）对应在源
高度图中的坐标。

- `-xChunkStart * gradient.x`：从 chunk 起始像素反推到目标原点的偏移（源像素单位）。
- `+ 2.f`：源高度图边缘有 2 像素的内边距（BigWorld 高度图存储格式约定），需要补偿。

**双线性采样**：`heights.getBilinear(u, v)` 对源高度图在浮点坐标 `(u, v)` 处进行双线
性插值，返回 4 个最近像素的加权平均。这保证了：
- 当目标高度场分辨率高于源高度图时，平滑放大。
- 当目标高度场分辨率低于源高度图时，平滑缩小。
- 跨 chunk 边界处虽有 `ceilf` 避免重复写入，但因 `gradient` 与 `cornerOffset` 对每个
  chunk 独立计算，相邻 chunk 在边界像素上的采样会自然落在各自源图的有效区内，避免接缝。

### 5.7 进度上报与输出

```cpp
// bw_height_import.cpp L204-206
int numBuildSteps = (chunkXMax - chunkXMin + 1) * map->h();
int buildProgress = 0;
```

- `numBuildSteps` = chunk 列数 × 目标高度场行数。注意这里**只乘 `map->h()`**（行数），
  而非总像素数，因为进度上报的粒度是「每完成一行目标像素 +1」。
- 在内层 y 循环末尾调用 `context.ReportProgress(this, ++buildProgress, numBuildSteps)`，
  让 World Machine UI 显示进度条，避免长时间无响应。

```cpp
// bw_height_import.cpp L262-265
// pass the heightfield to the output stage.
StoreData(map,0, context); 

return true;
```

- `StoreData(map, 0, context)`：将高度场输出到端口 0（即 `SetLinks(0, 1)` 中声明的
  唯一输出端口），供下游设备消费。
- 始终返回 `true`，即使空间未选择或无 chunk 覆盖（此时输出空白高度场），不阻断设备图
  构建。

### 5.8 loadHeightMap 辅助函数

`loadHeightMap` 是匿名命名空间中的静态辅助函数，负责从 `.cdata` 中解码高度图：

```cpp
// bw_height_import.cpp L125-156
/* static */
bool  loadHeightMap( BW::DataSectionPtr pCDataSection, BW::Moo::Image<float>& oHeights )
{
    if (!pCDataSection)
    {
        return false;
    }

    bool ret = false;

    BW::BinaryPtr pHeightBlock = pCDataSection->readBinary( "terrain2/heights" );

    if (pHeightBlock)
    {
        const BW::Terrain::HeightMapHeader* pHeader = 
            (const BW::Terrain::HeightMapHeader*)pHeightBlock->data();

        if (pHeader->magic_ == BW::Terrain::HeightMapHeader::MAGIC &&
            pHeader->version_ == BW::Terrain::HeightMapHeader::VERSION_ABS_QFLOAT)
        {
            BW::BinaryPtr compData = 
                new BW::BinaryBlock((void *)(pHeader + 1), 
                pHeightBlock->len() - sizeof(*pHeader), "Terrain/HeightMap2/BinaryBlock");
                
            if (BW::Terrain::decompressHeightMap(compData, oHeights))
            {
                ret = true;
            }
        }
    }

    return ret;
}
```

流程：

1. 从 `.cdata` DataSection 读取 `terrain2/heights` 二进制块（这是 BigWorld Terrain2
   格式存储高度数据的标准路径）。
2. 把块首部解释为 `HeightMapHeader`，校验：
   - `magic_ == MAGIC`（`0x00706d68`，即 `"hmp\0"`）
   - `version_ == VERSION_ABS_QFLOAT`（值为 4，绝对量化浮点格式）
3. 跳过 header（`pHeader + 1`），把剩余字节当作压缩数据，封装成 `BinaryBlock`。
4. 调用 `BW::Terrain::decompressHeightMap(compData, oHeights)` 解压为
   `Moo::Image<float>`。

**`HeightMapHeader` 结构**（来自 `lib/terrain/terrain_data.hpp`）：

```cpp
// terrain_data.hpp L22-42
struct HeightMapHeader
{
    enum HMHVersions
    {
        VERSION_ABS_FLOAT     = 1,    // 绝对浮点
        VERSION_REL_UINT16    = 2,    // 相对 uint16
        VERSION_REL_UINT16_PNG= 3,    // 相对 uint16 + PNG 压缩
        VERSION_ABS_QFLOAT    = 4     // 绝对量化浮点（本插件唯一支持的版本）
    };

    uint32  magic_;          // 0x00706d68 ("hmp\0")
    uint32  width_;
    uint32  height_;
    HeightMapCompression compression_;
    uint32  version_;
    float   minHeight_;
    float   maxHeight_;
    uint32  pad_;

    static const uint32 MAGIC = 0x00706d68;
};
```

> 本插件**仅支持 `VERSION_ABS_QFLOAT`**（版本 4）。若 chunk 用了其他版本（旧版地形），
> `loadHeightMap` 直接返回 `false`，该 chunk 被跳过（在 Activate 中体现为对应区域保持
> 空白）。这是一个刻意的兼容性取舍：版本 4 是 BigWorld 14.x 的默认格式。

---

## 6. SpaceHelper

`SpaceHelper` 封装了所有 BigWorld 空间元数据访问与 chunk 文件定位逻辑，是
`BWHeightImport` 与 BigWorld 资源系统之间的薄层适配。

### 6.1 类声明

```cpp
// space_helper.hpp L13-44
class SpaceHelper
{
public:
    SpaceHelper();
    bool init( const BW::string& spaceSettingsPath );

    int xMin() { return xMin_; }
    int xMax() { return xMax_; }
    int zMin() { return zMin_; }
    int zMax() { return zMax_; }

    float chunkSize() const { return chunkSize_; }
    bool singleDir() const { return singleDir_; }

    const BW::string& spaceRoot() const { return spaceRoot_; }

    BW::DataSectionPtr getCDataForChunk( int x, int z );

    bool valid() const { return !spaceRoot_.empty(); }
private:
    int xMin_;
    int xMax_;
    int zMin_;
    int zMax_;

    float chunkSize_;
    
    bool singleDir_;

    BW::string spaceRoot_;
    BW::FileSystemPtr pFileSystem_;
};
```

成员含义：

| 成员 | 类型 | 含义 |
|------|------|------|
| `xMin_`/`xMax_`/`zMin_`/`zMax_` | int | 空间在 chunk 网格上的边界（来自 `space.settings` 的 `bounds` 节） |
| `chunkSize_` | float | chunk 边长（米），默认 `DEFAULT_GRID_RESOLUTION = 100.f` |
| `singleDir_` | bool | 是否使用单层目录结构（无 `sep` 子目录） |
| `spaceRoot_` | string | 空间根目录路径（含末尾分隔符） |
| `pFileSystem_` | FileSystemPtr | 用于读取 chunk 文件的本地文件系统 |
| `valid()` | bool | 空间是否已成功初始化（`spaceRoot_` 非空） |

### 6.2 init 初始化

```cpp
// space_helper.cpp L35-60
bool SpaceHelper::init( const BW::string& spaceSettingsPath )
{
    DataSectionPtr pSpaceSettings = BW::XMLSection::createFromFile( spaceSettingsPath.c_str() );

    spaceRoot_.clear();
    pFileSystem_ = NULL;

    if (pSpaceSettings)
    {
        xMin_ = pSpaceSettings->readInt( "bounds/minX" );
        xMax_ = pSpaceSettings->readInt( "bounds/maxX" );
        zMin_ = pSpaceSettings->readInt( "bounds/minY" );   // 注意：Y 映射到 Z
        zMax_ = pSpaceSettings->readInt( "bounds/maxY" );

        chunkSize_ = pSpaceSettings->readFloat( "chunkSize", DEFAULT_GRID_RESOLUTION );

        singleDir_ = pSpaceSettings->readBool( "singleDir", false );

        spaceRoot_ = BW::BWResource::getFilePath( spaceSettingsPath );

        pFileSystem_ = BW::NativeFileSystem::create( spaceRoot_ );
    }

    return pSpaceSettings.exists();
}
```

- 通过 `XMLSection::createFromFile` 解析 `space.settings`（XML 格式）。
- 读取 4 个边界值：注意 `bounds/minY`/`maxY` 在 BigWorld 中对应 **Z 轴**（垂直于 X 的
  水平方向），这里映射到 `zMin_`/`zMax_`。
- `chunkSize` 缺省时取 `DEFAULT_GRID_RESOLUTION`（100 米）。
- `singleDir` 缺省 `false`，即默认使用分层 `sep` 目录结构。
- `spaceRoot_` 通过 `BWResource::getFilePath` 从 `space.settings` 完整路径中截取目录
  部分。
- 用 `NativeFileSystem::create(spaceRoot_)` 创建一个相对于空间根的文件系统，后续
  `getCDataForChunk` 用它定位 `.cdata`。

`space.settings` 典型内容：

```xml
<root>
    <bounds>
        <minX>-5</minX>
        <maxX>5</maxX>
        <minY>-5</minY>
        <maxY>5</maxY>
    </bounds>
    <chunkSize>100.0</chunkSize>
    <singleDir>false</singleDir>
</root>
```

### 6.3 getCDataForChunk

```cpp
// space_helper.cpp L69-90
BW::DataSectionPtr SpaceHelper::getCDataForChunk( int x, int z )
{
    BW::string cDataName;

    if (x >= xMin_ &&
        x <= xMax_ &&
        z >= zMin_ &&
        z <= zMax_)
    {
        cDataName =  BW::ChunkFormat::outsideChunkIdentifier(x, z, singleDir_ ) +
            BW::string( ".cdata");
    }

    if (!cDataName.empty() &&
        pFileSystem_.exists() &&
        pFileSystem_->getFileTypeEx( cDataName ) == BW::IFileSystem::FT_ARCHIVE)
    {
        return new BW::ZipSection( cDataName, pFileSystem_ );
    }

    return NULL;
}
```

流程：

1. 越界检查：`(x, z)` 必须在 `[xMin..xMax] × [zMin..zMax]` 内，否则返回 NULL。
2. 调用 `BW::ChunkFormat::outsideChunkIdentifier(x, z, singleDir_)` 生成 chunk 标识符
   （如 `00000000o`），拼接 `.cdata` 得到相对路径。
3. 通过 `pFileSystem_->getFileTypeEx(cDataName)` 检查文件类型；只有 `FT_ARCHIVE`
   （zip 归档）才返回 `ZipSection`（懒加载的 zip 包 DataSection）。
4. 若文件不存在或不是归档格式，返回 NULL。

> `.cdata` 实际是 zip 压缩包，内含 `*.chunk`（XML）和 `terrain2/*` 等二进制资源。
> `ZipSection` 会在首次访问时按需解压条目。

### 6.4 outsideChunkIdentifier 命名规则

BigWorld 的 chunk 命名采用「十六进制坐标 + o 后缀」方案，并在网格较大时按层级建立
`sep` 子目录避免单目录文件数过多。规则见 `lib/chunk/chunk_format.hpp`：

```cpp
// chunk_format.hpp L24-56
inline BW::string outsideChunkIdentifier( int gridX, int gridZ,
    bool singleDir = false )
{
    char chunkIdentifierCStr[32];
    BW::string gridChunkIdentifier;

    uint16 gridxs = uint16(gridX), gridzs = uint16(gridZ);
    if (!singleDir)
    {
        if (uint16(gridxs + 4096) >= 8192 || uint16(gridzs + 4096) >= 8192)
        {
            bw_snprintf( chunkIdentifierCStr, sizeof(chunkIdentifierCStr), 
                "%01xxxx%01xxxx/sep/", int(gridxs >> 12), int(gridzs >> 12) );
            gridChunkIdentifier = chunkIdentifierCStr;
        }
        if (uint16(gridxs + 256) >= 512 || uint16(gridzs + 256) >= 512)
        {
            bw_snprintf( chunkIdentifierCStr, sizeof(chunkIdentifierCStr), 
                "%02xxx%02xxx/sep/", int(gridxs >> 8), int(gridzs >> 8) );
            gridChunkIdentifier += chunkIdentifierCStr;
        }
        if (uint16(gridxs + 16) >= 32 || uint16(gridzs + 16) >= 32)
        {
            bw_snprintf( chunkIdentifierCStr, sizeof(chunkIdentifierCStr), 
                "%03xx%03xx/sep/", int(gridxs >> 4), int(gridzs >> 4) );
            gridChunkIdentifier += chunkIdentifierCStr;
        }
    }
    bw_snprintf( chunkIdentifierCStr, sizeof(chunkIdentifierCStr), 
        "%04x%04xo", int(gridxs), int(gridzs) );
    gridChunkIdentifier += chunkIdentifierCStr;

    return gridChunkIdentifier;
}
```

- chunk 文件名固定为 8 位十六进制（4 位 X + 4 位 Z）+ `o`（outside）后缀，如
  `00000000o`、`ffffffffo`。
- 当网格坐标超出「中心 ±N」范围时，逐级添加 `sep/` 子目录：
  - 超出 ±16 → 加 `%03xx%03xx/sep/`（每 16×16 分桶）
  - 超出 ±256 → 加 `%02xxx%02xxx/sep/`（每 256×256 分桶）
  - 超出 ±4096 → 加 `%01xxxx%01xxxx/sep/`（每 4096×4096 分桶）
- `singleDir = true` 时跳过所有 `sep`，所有 chunk 平铺在空间根目录（适用于小空间）。

`uint16(gridxs + 4096) >= 8192` 这种写法是用无符号 16 位回绕来检测
`gridxs ∈ [-4096, 4095]` 之外，等价于 `abs(gridxs) >= 4096`，是一种常见的无分支判断
技巧。

---

## 7. 配置参数

### 7.1 四个参数详解

| # | 名称 | 类型 | 默认值 | 范围 | 用途 |
|---|------|------|--------|------|------|
| 0 | Height Scale | float | 1.0 | [0, 10000] | BigWorld 高度（米）到 World Machine 高度单位的缩放因子，再乘以 `sd.vert_scale / 1000` |
| 1 | Chunk Scale | float | 100.0 | [0, 10000] | BigWorld chunk 边长（米），默认 100 = `DEFAULT_GRID_RESOLUTION` |
| 2 | Reset Chunk Scale | button | — | — | 回调 `resetChunkScale`，把 Chunk Scale 重置为当前空间的 `chunkSize` |
| 3 | Select space | button | — | — | 回调 `selectSpace`，弹出文件对话框选择 `space.settings` |

参数注册见构造函数（§4.3），帮助字符串见 `params.GetParam(N)->setHelpString(...)`。

### 7.2 resetChunkScale 实现

按钮回调通过一个桥接函数转入成员方法：

```cpp
// bw_height_import.cpp L18-22 (匿名命名空间)
void BWHeightImport_resetChunkScale( void * pDevice )
{
    BWHeightImport* pHeightImport = (BWHeightImport*)pDevice;
    pHeightImport->resetChunkScale();
}

// bw_height_import.cpp L271-278
void BWHeightImport::resetChunkScale()
{
    Parameter* pChunkScale = params.GetParam( CHUNK_SCALE_PROPERTY );
    if (pChunkScale)
    {
        pChunkScale->setFloat( spaceHelper_.chunkSize() );
    }
}
```

- World Machine 按钮参数的回调签名是 `void(void* pDevice)`，无法直接绑定到 C++ 成员
  函数，因此用匿名命名空间中的自由函数做桥接，把 `pDevice` 强转为 `BWHeightImport*`
  再调用成员方法。
- `resetChunkScale` 通过 `params.GetParam("Chunk Scale")` 按名查找参数对象，调用
  `setFloat` 把值设为 `spaceHelper_.chunkSize()`（即 `space.settings` 中的 `chunkSize`
  字段）。
- 用户场景：选好空间后，按一下此按钮，Chunk Scale 自动对齐到该空间实际的 chunk 边长，
  避免手输错误。

### 7.3 selectSpace 实现

```cpp
// bw_height_import.cpp L27-31 (匿名命名空间)
void BWHeighImport_selectSpace( void * pDevice )
{
    BWHeightImport* pHeightImport = (BWHeightImport*)pDevice;
    pHeightImport->selectSpace();
}

// bw_height_import.cpp L284-310
void BWHeightImport::selectSpace()
{
    OPENFILENAME ofn;
    memset( &ofn, 0, sizeof(ofn) );

    char * filters = "Space Settings\0space.settings\0\0";

    char filename[512] = "";

    ofn.lStructSize = sizeof(ofn);
    ofn.hwndOwner = NULL;
    ofn.lpstrFilter = filters;
    ofn.lpstrFile = filename;
    ofn.nMaxFile = sizeof(filename);
    ofn.lpstrTitle = "Select space";
    ofn.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST |
        OFN_NOCHANGEDIR | OFN_READONLY | OFN_HIDEREADONLY;
    ofn.lpstrDefExt = "settings";

    if (GetOpenFileName( &ofn ))
    {
        if (strlen(filename) != 0)
        {
            this->spaceHelper_.init( filename );
        }
    }
}
```

- 使用 Windows 通用对话框 API `GetOpenFileName` + `OPENFILENAME` 结构弹出文件选择框。
- 过滤器只显示 `space.settings` 文件。
- 标志位组合：
  - `OFN_FILEMUSTEXIST`：文件必须存在。
  - `OFN_PATHMUSTEXIST`：路径必须存在。
  - `OFN_NOCHANGEDIR`：不改变当前工作目录（避免影响 World Machine 的相对路径）。
  - `OFN_READONLY | OFN_HIDEREADONLY`：隐藏"以只读方式打开"复选框（这里只是借用，
    实际无副作用）。
- 默认扩展名 `settings`，用户输入 `xxx` 会自动补全为 `xxx.settings`。
- 用户确认后，把完整文件路径传给 `spaceHelper_.init()`，完成空间元数据加载。

---

## 8. 依赖关系

### 8.1 World Machine SDK 依赖

| SDK 头文件 | 来源 | 用途 |
|------------|------|------|
| `core/Globals.h` | World Machine SDK | `WMGlobal` 全局变量声明、`WMGlobalStruc` 结构 |
| `core/Plugin_Header.h` | World Machine SDK | `WM_PLUGIN_HEADER_VERSION` 宏 |
| `core/IODevices.h` | World Machine SDK | `Generator` 基类、`BuildContext`、`HField`、`Parameter`、`SizeData`、`Coord`/`CoordF` |
| `core/HField.h` | World Machine SDK | `HField` 高度场接口（`Clear`/`getBilinear` 等） |

SDK 库：`PluginCore64.lib` / `PluginCore64D.lib` / `PluginCore.lib`（Debug/Release、
Win32/x64 区分），位于 `programming/bigworld/lib/` 下 World Machine SDK 子目录。

### 8.2 BigWorld 库依赖

| 库模块 | 头文件 | 用途 |
|--------|--------|------|
| `resmgr` | `resmgr/bwresource.hpp`、`resmgr/datasection.hpp`、`resmgr/file_system.hpp`、`resmgr/xml_section.hpp`、`resmgr/zip_section.hpp` | 资源系统：DataSection、XML/Zip section、NativeFileSystem、BWResource |
| `chunk` | `chunk/chunk_grid_size.hpp`、`chunk/chunk_format.hpp` | `DEFAULT_GRID_RESOLUTION`、`outsideChunkIdentifier` |
| `terrain` | `terrain/height_map_compress.hpp`、`terrain/terrain_data.hpp` | `decompressHeightMap`、`HeightMapHeader` |
| `moo` | （`Moo::Image<float>`） | 高度图图像容器（来自 `terrain_data.hpp` 间接引入） |
| `math` | `math/vector4.hpp` | `Vector2`（gradient 用）、`Vector4` |
| `cstdmf` | `cstdmf/cstdmf_windows.hpp`、`cstdmf/stdmf.hpp` | Windows 包装、`bw_snprintf` |

> 工程文件 L414/L430 显示 `height_map_compress.cpp` 与 `png.cpp` 被直接编入本 DLL，
> 这是为了避免链接完整的 terrain/moo 库（这两个 .cpp 是自包含的，依赖较少）。

### 8.3 Windows API 依赖

| 头文件 | API | 用途 |
|--------|-----|------|
| `commdlg.h` | `GetOpenFileName`、`OPENFILENAME`、`OFN_*` 标志 | 文件选择对话框 |
| `windows.h`（间接） | `strcpy_s`、`strncpy`、`memset` | 字符串/内存操作 |

`pch.hpp` 仅包含 `cstdmf/cstdmf_windows.hpp`，后者统一包装了 Windows.h 与常见 Win32
API，使本插件代码无需直接 `#include <windows.h>`。

### 8.4 依赖关系图

```
                  ┌──────────────────────────────────────┐
                  │      bw_height_import64.dll           │
                  │  (本插件产物)                          │
                  └───────────────┬──────────────────────┘
                                  │
        ┌─────────────────────────┼─────────────────────────┐
        │                         │                         │
        ▼                         ▼                         ▼
┌─────────────────┐     ┌─────────────────────┐    ┌─────────────────┐
│  World Machine   │     │   BigWorld 库        │    │   Windows API    │
│  SDK (PluginCore)│     │  resmgr / chunk /    │    │  commdlg.h       │
│                  │     │  terrain / math /    │    │  GetOpenFileName │
│  Generator       │     │  moo / cstdmf        │    └─────────────────┘
│  HField          │     │                      │
│  BuildContext    │     │  XMLSection          │
│  Parameter       │     │  ZipSection          │
│  WMGlobal        │     │  decompressHeightMap │
└─────────────────┘     │  outsideChunkIdent.  │
                        └──────────────────────┘
```

---

## 9. 设计亮点

### 9.1 跨系统坐标变换

BigWorld 与 World Machine 使用完全不同的坐标系：

| 维度 | BigWorld | World Machine |
|------|---------|---------------|
| 长度单位 | 米 | 内部单位（经 `km_wm_relation` 与千米换算） |
| 高度单位 | 米（浮点） | 内部单位（经 `vert_scale` 与米换算） |
| 空间组织 | chunk 网格（每 chunk `chunkScale` 米） | 单一高度场（`map->w() × map->h()` 像素） |
| 原点 | 空间自定义（通常世界原点） | 高度场左下角（`context.GetPanLoc()`） |

`Activate` 通过四个变换参数 `heightScale`/`destOffset`/`destSize`/`chunkScale` 把两个
系统统一到「米」坐标系下，再求交集，逻辑清晰且无歧义。这种"先把一切换算到米，再求交"
的模式是处理跨工具集成的经典做法。

### 9.2 重叠区域计算

`chunkXMin..chunkXMax` 与 `chunkZMin..chunkZMax` 的计算用一行 `max`/`min` 完成两个矩
形的交集求解，简洁且正确：

```cpp
chunkXMin = max( spaceHelper_.xMin(), floorf(destOffset.x / chunkScale) );
chunkXMax = min( spaceHelper_.xMax(), floorf((destOffset.x + destSize.x) / chunkScale) );
```

这种写法隐含了一个不变式：BigWorld 空间的 chunk 索引范围与 World Machine 高度场覆盖
的 chunk 索引范围都是闭区间 `[min, max]`，二者求交仍是闭区间。若两者无交集，则
`min > max`，后续循环自动跳过，无需特判。

### 9.3 双线性采样保真

不同 chunk 的高度图分辨率通常高于或低于 World Machine 目标高度场分辨率，直接最近邻
采样会产生锯齿/失真。本插件用 `getBilinear` 双线性插值，且通过 `gradient` 与
`cornerOffset` 把目标像素坐标精确映射到源浮点坐标，保证：

- 上采样（目标比源大）：在源像素间平滑插值，无方块感。
- 下采样（目标比源小）：4 个源像素加权平均，相当于盒滤波，抗混叠。
- `heights.width() - 5` 的 -5 余量：源高度图边缘有 2 像素内边距，减 5 而非减 4 是为
  了多留 1 像素安全边距，避免 `getBilinear` 在边界处访问越界。

### 9.4 增量式 chunk 流式处理

整个 Activate 流程**一次只加载一个 chunk 的高度图**到内存（`heights` 在内层 for 循环
作用域内构造，循环结束自动析构），而非一次性加载整个空间。这意味着：

- 内存占用 = 单个 chunk 高度图大小 + 目标高度场大小，与空间总 chunk 数无关。
- 可处理任意大的 BigWorld 空间，只要交集部分能装下目标高度场。
- 进度粒度细到「每完成一行目标像素」，UI 响应好。

### 9.5 版本化的项目序列化

`Save` 写入 `nametag("BWHI") + ver(1) + spaceRoot(256B)`，`Load` 先校验 nametag 再读
版本号，预留了未来格式演进的空间：

- 若日后需要保存更多字段（如自定义采样模式、chunk 过滤列表等），只需在 `ver > 1` 分
  支中追加读取即可，老工程（`ver == 1`）仍可加载。
- 256 字节定长 `spaceRoot` 简化了读写，但限制了路径长度上限（Windows MAX_PATH = 260，
  256 字节几乎覆盖所有合法路径）。

### 9.6 与引擎 cdata 格式解耦

`loadHeightMap` 只依赖 `HeightMapHeader` 与 `decompressHeightMap`，不引入完整的
`Terrain::TerrainData` 类，避免拉入渲染、材质等重依赖。这是"只取所需"的轻量集成原则：
本插件只需要读取高度，不需要渲染地形，因此只链接 `height_map_compress.cpp` 与
`png.cpp` 两个自包含文件，构建产物小巧（一个 DLL + 依赖的 PluginCore 库即可）。

---

## 10. 常见误区与澄清

| 误区 | 澄清 |
|------|------|
| "本插件把 World Machine 地形导出成 BigWorld 格式" | **方向反了**。本插件是「导入」：把 BigWorld 已有地形读入 World Machine，作为后续编辑的输入。导出方向由其他工具/流程处理。 |
| "GetDevPlugin 创建的设备实例会被直接使用" | 不会。`GetDevPlugin` 中 `new` 的实例只用于采样元信息，立即 `delete`。实际使用的实例由 World Machine 通过 `lifeptrs.maker` 在需要时另行创建。 |
| "Chunk Scale 必须等于 100" | 不必。默认 100 是因为 `DEFAULT_GRID_RESOLUTION = 100.f`，但 `space.settings` 可自定义 `chunkSize`。用户应点击 "Reset Chunk Scale" 自动对齐。 |
| "Activate 失败会返回 false" | 不会。无论空间是否选择、是否有 chunk 覆盖，Activate 始终返回 `true` 并输出（可能为空白的）高度场，不阻断设备图。 |
| "loadHeightMap 支持所有 BigWorld 高度图版本" | 仅支持 `VERSION_ABS_QFLOAT`(4)。其他版本（1/2/3）直接返回 false，对应 chunk 被跳过。 |
| "双线性采样的 -5 是 bug，应该是 -4" | 不是 bug。源高度图有 2 像素内边距，-4 是理论值，-5 多留 1 像素安全边距，避免 `getBilinear` 在边界访问越界像素。 |
| "selectSpace 改变了工作目录" | 不会。`OFN_NOCHANGEDIR` 标志保证对话框关闭后恢复原工作目录，避免影响 World Machine 的相对路径解析。 |
| ".cdata 是普通文件夹" | 不是。`.cdata` 是 zip 归档文件，`getCDataForChunk` 通过 `getFileTypeEx == FT_ARCHIVE` 校验后用 `ZipSection` 懒加载。 |
| "selectSpace 与 Load 都会调用 spaceHelper_.init" | 是的。两条路径都最终调用 `init(spaceSettingsPath)`，前者来自用户对话框选择，后者来自工程文件中保存的 `spaceRoot + "space.settings"`。 |
| "进度上报粒度是每个像素" | 不是。`numBuildSteps = (chunkXMax - chunkXMin + 1) * map->h()`，即「chunk 列数 × 目标行数」，进度按行上报，避免过细的回调开销。 |

---

## 11. 附录

### 11.1 术语表

| 术语 | 全称 | 说明 |
|------|------|------|
| WM | World Machine | 专业地形生成软件 |
| HField | Height Field | World Machine 中的高度场数据结构 |
| Generator | — | World Machine 设备类型之一，无输入端口，产生输出数据 |
| Device | — | World Machine 设备图中的节点基类 |
| cdata | Chunk Data | BigWorld chunk 的数据文件（zip 归档） |
| chunk | — | BigWorld 空间的基本划分单元（默认 100m × 100m） |
| space.settings | — | BigWorld 空间元数据 XML 文件 |
| nametag | — | 4 字节设备标签，用于 Load/Save 识别 |
| maker/killer | — | 设备创建/销毁函数指针 |
| km_wm_relation | — | World Machine 全局变量，千米与内部单位的换算系数 |
| vert_scale | — | SizeData 字段，垂直方向缩放因子 |
| gradient | — | Activate 中目标像素到源像素的换算系数 |
| cornerOffset | — | Activate 中目标原点对应的源坐标 |
| singleDir | — | space.settings 字段，chunk 是否平铺无 sep 子目录 |
| DEFAULT_GRID_RESOLUTION | — | BigWorld 默认 chunk 边长，100.f 米 |

### 11.2 关键文件行号索引

| 内容 | 文件 | 行号 |
|------|------|------|
| 3 个 DLL 导出函数声明 | `wm_plugin_shell.hpp` | L9-13 |
| `SetupGlobalAccess` 实现 | `wm_plugin_shell.cpp` | L10-13 |
| `GetHeaderVersion` 实现 | `wm_plugin_shell.cpp` | L19-22 |
| `GetDevPlugin` 实现 | `wm_plugin_shell.cpp` | L28-49 |
| `BWHeightImport` 类声明 | `bw_height_import.hpp` | L12-41 |
| 构造函数（参数注册） | `bw_height_import.cpp` | L44-64 |
| `Load` 实现 | `bw_height_import.cpp` | L77-95 |
| `Save` 实现 | `bw_height_import.cpp` | L102-113 |
| `loadHeightMap` 辅助函数 | `bw_height_import.cpp` | L125-156 |
| `Activate` 实现 | `bw_height_import.cpp` | L165-266 |
| 创建目标高度场 | `bw_height_import.cpp` | L167-170 |
| 计算坐标变换参数 | `bw_height_import.cpp` | L174-190 |
| 计算重叠区域 | `bw_height_import.cpp` | L194-202 |
| 遍历 chunk 加载高度图 | `bw_height_import.cpp` | L204-258 |
| 双线性采样映射 | `bw_height_import.cpp` | L237-255 |
| 进度上报与输出 | `bw_height_import.cpp` | L254, L262-265 |
| `resetChunkScale` | `bw_height_import.cpp` | L271-278 |
| `selectSpace` | `bw_height_import.cpp` | L284-310 |
| 静态常量定义 | `bw_height_import.cpp` | L313-314 |
| `SpaceHelper` 类声明 | `space_helper.hpp` | L13-44 |
| `SpaceHelper::init` | `space_helper.cpp` | L35-60 |
| `SpaceHelper::getCDataForChunk` | `space_helper.cpp` | L69-90 |
| `HeightMapHeader` 结构 | `lib/terrain/terrain_data.hpp` | L22-42 |
| `outsideChunkIdentifier` | `lib/chunk/chunk_format.hpp` | L24-56 |
| `DEFAULT_GRID_RESOLUTION` | `lib/chunk/chunk_grid_size.hpp` | L15 |
| `decompressHeightMap` 声明 | `lib/terrain/height_map_compress.hpp` | L23 |
| 工程链接依赖 | `bw_height_import.vcproj` | L126, L210, L294 |
| 工程包含目录 | `bw_height_import.vcproj` | L187 |
| 直接编入的引擎源 | `bw_height_import.vcproj` | L414, L430 |

---

> 本文档基于 BigWorld Engine 14.4.1 源码分析整理，覆盖 `bw_world_machine_import`
> 工具的全部源文件与关键依赖。如需了解 World Machine SDK 内部实现，请参阅 SDK 自带
> 文档与 `core/IODevices.h` 头文件注释。
