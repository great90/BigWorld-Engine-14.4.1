# BigWorld 工具 common (tools_common) 实现深度分析

> 本文档详细分析 BigWorld Engine 14.4.1 中 `tools/common` 目录的实现,该目录构建为 `tools_common` 静态库,是 BigWorld 工具链(WorldEditor、ModelEditor 等)的**公共基础库**。本文档涵盖库的架构定位、目录组织、被链接方式、核心类(UndoRedo 撤销重做、BWLockDConnection 协作锁、EditorChunkCacheBase chunk 缓存、SpaceEditor 空间编辑回调、RompHarness 环境管理)、关键算法与数据结构、新旧 Undo 系统并存、配置与依赖关系等核心机制。

---

## 目录

- [一、整体架构概览](#一整体架构概览)
- [二、源码目录结构](#二源码目录结构)
- [三、库的构建与被链接方式](#三库的构建与被链接方式)
- [四、核心类与继承关系](#四核心类与继承关系)
- [五、关键算法与数据结构](#五关键算法与数据结构)
- [六、配置项与命令行参数](#六配置项与命令行参数)
- [七、与其他模块的依赖关系](#七与其他模块的依赖关系)
- [八、关键代码片段](#八关键代码片段)
- [九、设计亮点与注意事项](#九设计亮点与注意事项)

---

## 一、整体架构概览

### 1.1 tools_common 在工具链中的定位

`tools_common` 是 BigWorld 工具链的**公共基础库**,为 WorldEditor、ModelEditor 等工具提供共享的:

1. 撤销/重做系统(`UndoRedo` 多态 Operation + Barrier,`undo.h` 旧式 C 风格遗留)
2. 多人协作锁连接(`BWLockDConnection`,连接 bwlockd 守护进程)
3. Chunk 编辑缓存基类(`EditorChunkCacheBase`,特化 `ChunkCache::Instance`)
4. 空间编辑回调接口(`SpaceEditor`,单例注入模式)
5. 环境管理器(`RompHarness`,Python 暴露的时间/天气/雾)
6. 各类相机(Base/Orbit/MouseLook/Orthographic/Tools)
7. 材质编辑、属性表、导航网格处理、地形阴影处理等通用组件

### 1.2 整体架构拓扑

```
┌─────────────────────────────────────────────────────────────────┐
│                    tools_common 静态库                          │
│                                                                 │
│  ┌──────────────┐  ┌─────────────────┐  ┌────────────────────┐  │
│  │  UndoRedo    │  │ BWLockDConn     │  │ EditorChunkCache-  │  │
│  │  (单例)      │  │ (TCP 连接)      │  │ Base (chunk 缓存)  │  │
│  │  Operation   │  │ GridStatus x4   │  │ ChunkSaver/        │  │
│  │  Barrier     │  │ Rect/Lock/Comp  │  │ CdataSaver         │  │
│  └──────────────┘  └─────────────────┘  └────────────────────┘  │
│                                                                 │
│  ┌──────────────┐  ┌─────────────────┐  ┌────────────────────┐  │
│  │ SpaceEditor  │  │ RompHarness     │  │ 各类相机/材质/属性 │  │
│  │ (单例注入)   │  │ (PyObjectPlus)  │  │ NavmeshProcessor/  │  │
│  │ changedChunk │  │ setTime/fog     │  │ RecastProcessor/   │  │
│  └──────────────┘  └─────────────────┘  │ TerrainShadowProc  │  │
│                                          └────────────────────┘  │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  旧式遗留:undo.h (C 风格, AnsiString, TAction)           │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
              ▲                    ▲                    ▲
              │链接                │链接                │链接
      ┌───────┴───────┐    ┌───────┴───────┐    ┌──────┴──────┐
      │  worldeditor  │    │ modeleditor_  │    │ 其他工具    │
      │  (BW_ADD_     │    │ core          │    │             │
      │   TOOL_EXE)   │    │               │    │             │
      └───────────────┘    └───────────────┘    └─────────────┘
```

### 1.3 关键设计原则

| 原则 | 说明 |
|------|------|
| **静态库复用** | 通过 `BW_ADD_LIBRARY(tools_common)` 构建为静态库,被多个工具链接,避免代码重复 |
| **单例注入** | `SpaceEditor`/`UndoRedo` 采用单例,`SpaceEditor` 支持外部注入实例(由 WorldManager 注入) |
| **接口与实现分离** | `SpaceEditor` 是抽象基类,WorldManager 继承并注入,工具库不依赖具体实现 |
| **多态 Operation** | `UndoRedo::Operation` 抽象基类 + `Barrier` 分组,支持撤销/重做栈与复合操作 |
| **新旧并存** | 新式 `UndoRedo`(C++)与旧式 `undo.h`(C 风格 AnsiString)并存,后者遗留 |
| **Python 暴露** | `RompHarness` 继承 `PyObjectPlus`,环境参数暴露给脚本 |
| **条件编译** | bwlockd 相关代码受 `BIGWORLD_CLIENT_ONLY` 控制 |

### 1.4 规模与组成

`tools_common` 源码位于 `programming/bigworld/tools/common/`,约 80 个源文件,由 `CMakeLists.txt` 通过 `BW_BLOB_SOURCES` 打包为单一静态库。主要分组:

| 分组 | 代表文件 | 说明 |
|------|---------|------|
| 撤销/重做 | `undoredo.hpp/.cpp/.ipp`、`undo.h` | 新旧两套系统 |
| 协作锁 | `bwlockd_connection.hpp/.cpp` | bwlockd TCP 连接 |
| Chunk 缓存 | `editor_chunk_cache_base.hpp/.cpp`、`editor_chunk_processor_cache.hpp/.cpp` | 编辑器 chunk 扩展 |
| 空间编辑 | `space_editor.hpp` | 回调接口 |
| 环境管理 | `romp_harness.hpp/.cpp` | RompHarness |
| 相机 | `base_camera.hpp/.ipp`、`orbit_camera.hpp`、`mouse_look_camera.hpp`、`orthographic_camera.hpp`、`tools_camera.hpp` | 各类相机 |
| 材质 | `material_editor.hpp`、`material_properties.hpp`、`material_proxies.hpp`、`material_utility.hpp` | 材质编辑 |
| 属性 | `base_properties_helper.hpp`、`properties_helper.hpp`、`property_list.hpp`、`property_table.hpp`、`base_property_table.hpp`、`cdialog_property_table.hpp`、`array_properties_helper.hpp` | 属性表 |
| 导航 | `navmesh_processor.hpp/.cpp`、`recast_processor.hpp/.cpp`、`waypoint_annotator.hpp/.cpp` | 导航网格 |
| 地形 | `editor_chunk_terrain_base.hpp/.cpp`、`editor_chunk_terrain_cache.hpp/.cpp`、`editor_chunk_terrain_lod_cache.hpp/.cpp`、`terrain_shadow_processor.hpp/.cpp`、`chunk_flooder.hpp/.cpp` | 地形处理 |
| 模型/实体 | `editor_chunk_model_base.hpp/.cpp`、`editor_chunk_entity_base.hpp/.cpp` | 模型/实体基类 |
| 杂项 | `tools_common.hpp/.cpp`、`compile_time.hpp/.cpp`、`command_line.hpp`、`grid_coord.hpp/.cpp`、`space_mgr.hpp/.cpp`、`utilities.hpp/.cpp`、`format.hpp/.cpp`、`string_utils.hpp/.cpp` 等 | 工具函数 |

---

## 二、源码目录结构

### 2.1 顶层目录

```
tools/common/
├── CMakeLists.txt              # 构建定义, BW_ADD_LIBRARY(tools_common)
├── pch.hpp / pch.cpp / pch.h   # 预编译头
├── resource.h                  # 资源 ID
├── undoredo.hpp/.cpp/.ipp      # ★新式撤销/重做
├── undo.h                      # ★旧式撤销(C 风格遗留)
├── bwlockd_connection.hpp/.cpp # ★bwlockd 协作锁连接
├── editor_chunk_cache_base.hpp/.cpp             # ★chunk 缓存基类
├── editor_chunk_processor_cache.hpp/.cpp        # chunk 处理器缓存
├── editor_chunk_terrain_base.hpp/.cpp           # 地形 chunk 基类
├── editor_chunk_terrain_cache.hpp/.cpp          # 地形缓存
├── editor_chunk_terrain_lod_cache.hpp/.cpp      # 地形 LOD 缓存
├── editor_chunk_navmesh_cache_base.hpp/.cpp     # 导航网格缓存基类
├── editor_chunk_model_base.hpp/.cpp             # 模型 chunk 基类
├── editor_chunk_entity_base.hpp/.cpp            # 实体 chunk 基类
├── space_editor.hpp            # ★空间编辑回调接口
├── romp_harness.hpp/.cpp       # ★环境管理器(Python 暴露)
├── base_camera.hpp/.ipp        # 相机基类
├── orbit_camera.hpp/.cpp       # 轨道相机
├── mouse_look_camera.hpp/.ipp  # 鼠标查看相机
├── orthographic_camera.hpp/.cpp# 正交相机
├── tools_camera.hpp/.cpp       # 工具相机
├── material_*.hpp/.cpp         # 材质系列
├── *_properties_helper.hpp/.cpp# 属性助手系列
├── property_list.hpp/.cpp      # 属性列表
├── property_table.hpp/.cpp     # 属性表
├── navmesh_processor.hpp/.cpp  # 导航网格处理
├── recast_processor.hpp/.cpp   # Recast 处理
├── waypoint_annotator.hpp/.cpp # 路径点标注
├── terrain_shadow_processor.hpp/.cpp # 地形阴影
├── chunk_flooder.hpp/.cpp      # chunk 泛洪
├── grid_coord.hpp/.cpp         # 网格坐标
├── space_mgr.hpp/.cpp          # 空间管理
├── tools_common.hpp/.cpp       # 公共工具
├── compile_time.hpp/.cpp       # 编译时间
├── command_line.hpp            # 命令行
├── directory_check.hpp         # 目录检查
├── cooperative_moo.hpp/.cpp    # 协作 MOO
├── dxenum.hpp/.cpp             # DX 枚举
├── editor_group.hpp/.cpp       # 编辑器分组
├── editor_views.hpp/.cpp       # 编辑器视图
├── floor.hpp/.cpp              # 地面
├── girth.hpp/.cpp              # 围长
├── lighting_influence.hpp/.cpp # 光照影响
├── lighting_plan.h             # 光照计划
├── physics_handler.hpp/.cpp    # 物理处理
├── popup_menu.hpp/.cpp         # 弹出菜单
├── python_adapter.hpp/.cpp     # Python 适配器
├── resource_loader.hpp/.cpp    # 资源加载器
├── shader_loading_dialog.hpp/.cpp # 着色器加载对话框
├── snaps.hpp/.cpp              # 吸附
├── string_utils.hpp/.cpp       # 字符串工具
├── ual_entity_provider.hpp/.cpp# UAL 实体提供者
├── user_messages.hpp           # 用户消息
├── utilities.hpp/.cpp          # 工具函数
├── bw_message_info.hpp/.cpp    # 消息信息
├── base_mainframe.hpp          # 主框架基类
├── base_panel_manager.hpp/.cpp # 面板管理器基类
├── brush_thumb_provider.hpp/.cpp # 笔刷缩略图
├── chop_poly.hpp/.cpp          # 多边形裁剪
├── collision_advance.hpp/.cpp  # 碰撞推进
├── collision_callbacks.hpp/.cpp# 碰撞回调
├── common_utility.h/.cpp       # 通用工具(C 风格遗留)
├── common_utility_dx.cpp       # DX 通用工具
├── delay_redraw.hpp/.cpp       # 延迟重绘
├── format.hpp/.cpp             # 格式化
├── graphics_settings_table.hpp/.cpp # 图形设置表
├── page_graphics_settings.hpp/.cpp # 图形设置页
├── page_messages.hpp/.cpp      # 页面消息
└── node_selector.h             # 节点选择器(C 风格)
```

### 2.2 关键文件规模

| 文件 | 规模 | 作用 |
|------|------|------|
| `undoredo.hpp` | 118 行 | 新式撤销/重做接口 |
| `undo.h` | 141 行 | 旧式撤销(C 风格) |
| `bwlockd_connection.hpp` | 202 行 | bwlockd 连接 |
| `editor_chunk_cache_base.hpp` | 90 行 | chunk 缓存基类 |
| `space_editor.hpp` | 64 行 | 空间编辑回调 |
| `romp_harness.hpp` | 75 行 | 环境管理器 |

---

## 三、库的构建与被链接方式

### 3.1 CMakeLists.txt 构建

`tools/common/CMakeLists.txt` 定义静态库:

```cmake
# CMakeLists.txt:1-6
CMAKE_MINIMUM_REQUIRED( VERSION 2.8 )
PROJECT( tools_common )

INCLUDE( BWStandardProject )
INCLUDE( BWStandardMFCProject )
INCLUDE( BWStandardLibrary )
```

注意包含 `BWStandardMFCProject`,因部分代码(对话框、属性表)依赖 MFC。

所有源文件通过 `BW_BLOB_SOURCES` 打包:

```cmake
# CMakeLists.txt:8-112
SET( ALL_SRCS
    base_camera.cpp
    ...
    waypoint_annotator.cpp
)
SOURCE_GROUP( "" FILES ${ALL_SRCS} )

BW_BLOB_SOURCES( BLOB_SRCS ${ALL_SRCS} )
BW_ADD_LIBRARY( tools_common ${BLOB_SRCS} )
```

### 3.2 链接依赖

`tools_common` 自身链接(`CMakeLists.txt:114-119`):

```cmake
BW_TARGET_LINK_LIBRARIES( tools_common INTERFACE
    cstdmf
    editor_shared
    navigation_recast
    waypoint_generator
)
```

注意是 `INTERFACE`,表示这些依赖传递给 `tools_common` 的使用者。

### 3.3 被链接方式

`tools_common` 被以下工具链接:

| 工具 | CMakeLists 引用 |
|------|----------------|
| worldeditor | `tools/worldeditor/CMakeLists.txt:930` |
| modeleditor_core | `tools/modeleditor_core/CMakeLists.txt` |

以 worldeditor 为例:

```cmake
# worldeditor/CMakeLists.txt:912-934
BW_TARGET_LINK_LIBRARIES( worldeditor
    ...
    tools_common          # 工具公共库
    ...
)
```

此外,worldeditor 还**直接编译部分 common 文件**(COMMON_CODE_SRCS),而非仅链接库:

```cmake
# worldeditor/CMakeLists.txt:18-46
SET( COMMON_CODE_SRCS
    ../common/array_properties_helper.cpp
    ../common/base_mainframe.hpp
    ../common/bwlockd_connection.cpp
    ../common/cdialog_property_table.cpp
    ../common/format.cpp
    ../common/graphics_settings_table.cpp
    ../common/grid_coord.cpp
    ../common/material_editor.cpp
    ../common/orthographic_camera.cpp
    ../common/properties_helper.cpp
    ../common/ual_entity_provider.cpp
)
```

这种"部分文件直接编译 + 部分链接库"的混合方式是历史遗留,可能是为避免符号重复或调整编译选项。

### 3.4 作为库无入口点

`tools_common` 是**静态库,无入口点**(`main`/`WinMain`)。其初始化依赖使用者在自身初始化流程中调用,例如:

- `UndoRedo::instance()` 首次调用时构造单例
- `SpaceEditor::instance(worldManager)` 由 WorldManager 构造时注入
- `BWLockDConnection` 由 WorldManager 持有成员,`WorldManager::init` 中调用 `conn_.init`
- `RompHarness` 由 WorldManager 持有,`initRomp` 中构造

---

## 四、核心类与继承关系

### 4.1 UndoRedo 撤销/重做系统

`UndoRedo`(`undoredo.hpp:11`)是新式撤销/重做系统,采用**单例 + 多态 Operation + Barrier 分组**:

```cpp
// undoredo.hpp:11-13
class UndoRedo
{
public:
    UndoRedo();
    ~UndoRedo();
```

#### 4.1.1 Operation 抽象基类

`Operation`(`undoredo.hpp:27-50`)是撤销操作的抽象基类:

```cpp
// undoredo.hpp:27-50
class Operation
{
public:
    Operation( int kind ) : kind_( kind ) { }
    virtual ~Operation() { }

    virtual void undo() = 0;

    bool operator==( const Operation & oth ) const
    {
        if (kind_ != oth.kind_ || !kind_) return false;
        return this->iseq( oth );
    };

    bool operator!=( const Operation & oth ) const
    {
        return !( *this == oth );
    }

    virtual bool iseq( const Operation & oth ) const = 0;

protected:
    int kind_;
};
```

关键设计:
- `kind_` 标识操作类型(用 `int(typeid(*this).name())`),用于判断两个 Operation 是否同类
- `undo()` 纯虚函数,子类实现具体撤销
- `iseq` 纯虚函数,判断两个同类 Operation 是否引用同一对象同一数据(用于合并而非叠加)
- `operator==` 先比 `kind_`,再调 `iseq`

#### 4.1.2 Barrier 分组

`Barrier`(`undoredo.hpp:95-102`)是一组 Operation 的容器,代表一个"可撤销单元":

```cpp
// undoredo.hpp:95-105
class Barrier : public ReferenceCount
{
public:
    ~Barrier();
    BW::string      what_;
    Operations      ops_;
};

typedef SmartPointer<Barrier> BarrierPtr;
typedef BW::vector<BarrierPtr> Barriers;

Barriers    undoList_;  // back is additions since latest barrier
Barriers    redoList_;  // back is next Operations to redo
bool        undoing_;
```

`Barrier` 继承 `ReferenceCount`,通过 `BarrierPtr`(SmartPointer)管理,确保操作链安全。

#### 4.1.3 add 自动分流

`add`(`undoredo.hpp:60-66`)根据 `undoing_` 标志自动分流到 undo 或 redo 列表:

```cpp
// undoredo.hpp:60-66
void add( Operation * op )
{
    if (!undoing_)
        this->addUndo( op );
    else
        this->addRedo( op );
}
```

注释说明(`undoredo.hpp:88-90`):
- 当修改发生时,`addUndo` 被调用
- 当 `undo` 撤销时,`addRedo` 被调用
- 当 `redo` 重做时,`addUndo` 再次被调用

这种设计使**同一 Operation 类既能用于 undo 也能用于 redo**,只需在 `undo()` 实现中调用 `UndoRedo::instance().add(redoOp)` 记录反向操作。

### 4.2 undo.h 旧式 C 风格遗留

`undo.h` 是**旧式 C 风格**撤销系统,使用 `AnsiString`、`UndoData`(char*)、`TAction` 等 VCL/Borland 风格类型:

```cpp
// undo.h:33-58
typedef char* UndoData;

typedef struct
{
    unsigned int    id;
    unsigned int    opCode;
    AnsiString      description;
    UndoData        data;
    int             size;
    bool            linked;
} UndoInfo;

typedef bool(*UndoFunc)(unsigned int, UndoData);

typedef BW::list<UndoInfo*> UndoInfoVector;
typedef BW::list<UndoFunc>  UndoFuncsVector;

class Undo
{
    ...
    UndoInfoVector          undoList_;
    UndoInfoVector          redoList_;
    UndoFuncsVector         undoFuncs_;
    ...
    TAction*        undoAction_;
    TAction*        redoAction_;
};
```

特征:
- `AnsiString`、`TAction`、`TStrings` 是 Borland VCL 类型,在 MFC 构建中**不可用**
- 使用函数指针 `UndoFunc` 而非多态
- `addUndoData`/`addRedoData` 分离,无自动分流

**该文件是历史遗留**,现代代码使用 `UndoRedo`。`undo.h` 保留可能是为兼容旧 ModelEditor(Borland 版本)的代码移植。在 14.4.1 的 MFC 构建中,该文件可能不被实际编译(无对应 .cpp,且依赖 VCL 类型)。

### 4.3 BWLockDConnection 协作锁连接

`BWLockDConnection`(`bwlockd_connection.hpp:109`)是 bwlockd 守护进程的 TCP 客户端连接:

```cpp
// bwlockd_connection.hpp:109-193
class BWLockDConnection
{
public:
    class Notification
    {
    public:
        virtual ~Notification(){}
        virtual void changed() = 0;
    };

    BWLockDConnection();

    void registerNotification( Notification* n );
    void unregisterNotification( Notification* n );
    void notify() const;

    bool enabled() const    {   return enabled_;    }
    bool init( const BW::string& hoststr, const BW::string& username, int xExtent, int zExtent );
    bool connect();
    bool changeSpace( BW::string newSpace );
    void disconnect();
    bool connected() const;

    int xExtent() const {   return xExtent_;    }
    int zExtent() const {   return zExtent_;    }

    void linkPoint( int16 oldLeft, int16 oldTop, int16 newLeft, int16 newTop );

    bool lock( const GridRect& rect, const BW::string description );
    void unlock( Rect rect, const BW::string description );

    bool isWritableByMe( int16 x, int16 z ) const;
    bool isLockedByMe( int16 x, int16 z ) const;
    bool isLockedByOthers( int16 x, int16 z ) const;
    bool isSameLock( int16 x1, int16 z1, int16 x2, int16 z2 ) const;
    bool isAllLocked() const;

    GridInfo getGridInformation( int16 x, int16 z ) const;
    BW::set<Rect> getLockRects( int16 x, int16 z ) const;

    bool tick();// return true => the lock rects has been updated

    BW::vector<unsigned char> getLockData( int minX, int minY, unsigned int gridWidth, unsigned int gridHeight );

    BW::string host() const;

    void addCommentary( const BW::wstring& msg, bool isCritical );
    void addCommentary( const BW::string& msg, bool isCritical );
private:
    BW::set<Notification*> notifications_;
    ...
    Endpoint ep_;
    ...
    BW::vector<GridStatus> gridStatus_;
};
```

#### 4.3.1 GridStatus 四种状态

`GridStatus`(`bwlockd_connection.hpp:24-36`)枚举网格锁定状态:

```cpp
// bwlockd_connection.hpp:24-36
enum GridStatus
{
    // this grid is not locked by anyone
    GS_NOT_LOCKED = 0,
    // this grid is locked by me, but not editable
    GS_LOCKED_BY_ME,
    // this grid is locked by sb. else
    GS_LOCKED_BY_OTHERS,
    // this grid is locked by me and editable
    GS_WRITABLE_BY_ME,
    // count of grid status
    GS_MAX
};
```

| 状态 | 含义 | 可编辑 |
|------|------|--------|
| `GS_NOT_LOCKED` | 无人锁定 | 否 |
| `GS_LOCKED_BY_ME` | 我锁定但不可编辑 | 否 |
| `GS_LOCKED_BY_OTHERS` | 他人锁定 | 否 |
| `GS_WRITABLE_BY_ME` | 我锁定且可编辑 | **是** |

#### 4.3.2 Rect/Lock/Computer 数据结构

```cpp
// bwlockd_connection.hpp:38-103
struct Rect
{
    short left_;
    short top_;
    short right_;
    short bottom_;
    template<typename T>
    Rect( T left, T top, T right, T bottom ) : ... {}
    bool in( int x, int y ) const;
    bool intersect( const Rect& that ) const;
    bool operator<( const Rect& that ) const;
};

struct Lock
{
    Rect rect_;
    BW::string username_;
    BW::string desc_;
    float time_;
};

struct Computer
{
    BW::string name_;
    BW::vector<Lock> locks_;
};
```

`Rect` 提供点包含、矩形相交判断与字典序比较(用于 `BW::set<Rect>` 排序)。`Lock` 记录锁定者、描述、时间。`Computer` 聚合一台计算机的所有锁。

#### 4.3.3 Notification 观察者

`BWLockDConnection` 内嵌 `Notification` 接口(`bwlockd_connection.hpp:112-117`),允许外部注册回调以响应锁状态变化:

```cpp
class Notification
{
public:
    virtual ~Notification(){}
    virtual void changed() = 0;
};

void registerNotification( Notification* n );
void unregisterNotification( Notification* n );
void notify() const;
```

`tick` 返回 true 时表示锁矩形已更新,触发 `notify` 通知观察者刷新 UI(如 LockMap 纹理)。

### 4.4 EditorChunkCacheBase chunk 缓存基类

`EditorChunkCacheBase`(`editor_chunk_cache_base.hpp:32`)是编辑器对 chunk 的扩展缓存,继承 `EditorChunkProcessorCache`:

```cpp
// editor_chunk_cache_base.hpp:32-60
class EditorChunkCacheBase : public EditorChunkProcessorCache
{
public:
    EditorChunkCacheBase( Chunk & chunk );

    virtual bool load( DataSectionPtr pSec, DataSectionPtr pCdata );

    static void touch( Chunk & chunk );

    bool edSave();
    bool edSaveCData();

    const char* id() const { return "Lighting"; }

    DataSectionPtr pChunkSection();
    DataSectionPtr pCDataSection();

    static Instance<EditorChunkCacheBase>  instance;

protected:
    virtual bool saveCDataInternal( DataSectionPtr ds, const BW::string& filename );

    Chunk & chunk_;
    DataSectionPtr pChunkSection_;
};
```

#### 4.4.1 ChunkCache::Instance 特化

`editor_chunk_cache_base.hpp:17-18` 特化 `ChunkCache::Instance`:

```cpp
// editor_chunk_cache_base.hpp:17-18
class EditorChunkCacheBase;
template <>
EditorChunkCacheBase & ChunkCache::Instance<EditorChunkCacheBase>::operator()( Chunk & chunk ) const;
```

这使 `EditorChunkCacheBase::instance(chunk)` 能从 chunk 查询其编辑器缓存实例。特化在 `editor_chunk_cache_base.cpp` 实现,实际调用 worldeditor 的 `EditorChunkCache`(派生类)。

#### 4.4.2 ChunkSaver/CdataSaver

`editor_chunk_cache_base.hpp:63-86` 定义两个 `UnsavedChunks::IChunkSaver` 实现:

```cpp
// editor_chunk_cache_base.hpp:63-86
class ChunkSaver : public UnsavedChunks::IChunkSaver
{
    virtual bool save( Chunk* chunk )
    {
        return EditorChunkCacheBase::instance( *chunk ).edSave();
    }
    bool isDeleted( Chunk& chunk ) const { return false; }
};

class CdataSaver : public UnsavedChunks::IChunkSaver
{
    virtual bool save( Chunk* chunk )
    {
        return EditorChunkCacheBase::instance( *chunk ).edSaveCData();
    }
    bool isDeleted( Chunk& chunk ) const { return false; }
};
```

这两个 Saver 注册到 `UnsavedChunks` 系统,统一管理 chunk 的 `.chunk` 与 `.cdata` 保存。

### 4.5 SpaceEditor 空间编辑回调接口

`SpaceEditor`(`space_editor.hpp:18`)是空间编辑的**抽象回调接口 + 单例注入**:

```cpp
// space_editor.hpp:18-60
class SpaceEditor
{
public:
    virtual ~SpaceEditor() {}

    virtual void    changedChunk( Chunk* pPrimaryChunk,
        InvalidateFlags flags = InvalidateFlags::FLAG_THUMBNAIL )  {}
    virtual void    changedChunks( BW::set<Chunk*>& primaryChunks,
        InvalidateFlags flags = InvalidateFlags::FLAG_THUMBNAIL )  {}

    virtual void    changedChunk( Chunk* pPrimaryChunk,
        EditorChunkItem& changedItem ) {}
    virtual void    changedChunks( BW::set<Chunk*>& primaryChunks,
        EditorChunkItem& changedItem ) {}

    virtual void    changedChunk( Chunk* pPrimaryChunk,
        InvalidateFlags flags,
        EditorChunkItem& changedItem ) {}
    virtual void    changedChunks( BW::set<Chunk*>& primaryChunks,
        InvalidateFlags flags,
        EditorChunkItem& changedItem ) {}

    virtual void addError( Chunk* chunk, ChunkItem* item, const char * format, ... ) {};

    virtual void onDeleteVLO( const BW::string& id )    {};

    virtual bool isChunkWritable( Chunk* chunk ) const { return true;};

    static SpaceEditor& instance( SpaceEditor* editor = NULL )
    {
        static SpaceEditor* s_editor = NULL;
        if (editor)
        {
            // Used in WE passed with WorldManager instance
            s_editor = editor;
        }
        MF_ASSERT( s_editor );
        return *s_editor;
    }
};
```

#### 4.5.1 单例注入模式

`instance(SpaceEditor* editor = NULL)`(`space_editor.hpp:47-59`)是**单例注入**:

- 首次调用传入具体实现(如 `WorldManager`),注册到静态指针
- 后续调用无参数,返回已注册实例
- 未注册时 `MF_ASSERT` 失败

`WorldManager` 构造函数中注入(`world_manager.cpp:709`):

```cpp
SpaceEditor::instance( this );
```

这使得 `tools_common` 中的代码(如 `EditorChunkCacheBase`)能调用 `SpaceEditor::instance().changedChunk(...)` 通知 WorldManager,而**不依赖 worldeditor 具体类型**,实现库间解耦。

#### 4.5.2 回调接口职责

| 方法 | 职责 |
|------|------|
| `changedChunk` (flags) | chunk 内容改变,需重算缩略图/光照等 |
| `changedChunk` (item) | 特定 item 改变 |
| `changedChunk` (flags+item) | 带 flags 的特定 item 改变 |
| `changedChunks` | 批量 chunk 改变 |
| `addError` | 记录 chunk/item 错误 |
| `onDeleteVLO` | VLO 删除通知 |
| `isChunkWritable` | chunk 是否可写(查询 bwlockd 状态) |

### 4.6 RompHarness 环境管理器

`RompHarness`(`romp_harness.hpp:26`)继承 `PyObjectPlus`,暴露到 Python:

```cpp
// romp_harness.hpp:26-71
class RompHarness : public PyObjectPlus
{
    Py_Header( RompHarness, PyObjectPlus )
public:
    RompHarness( PyTypeObject * pType = &s_type_ );
    ~RompHarness();

    bool    init();
    void    changeSpace();
    void    initWater( DataSectionPtr pProject );

    void    setTime( float t );
    void    setSecondsPerHour( float sph );
    void    fogEnable( bool state );
    bool    fogEnable() const;

    void    update( float dTime, bool globalWeather );
    void    drawPreSceneStuff( bool sparkleCheck = false, bool renderEnvironment = true );
    void    drawSceneStuff( bool showWeather = true,
        bool showFlora = true, bool showFloraShadowing = false );
    void    drawDelayedSceneStuff( bool renderEnvironment = true );
    void    drawPostSceneStuff( Moo::DrawContext& drawContext, bool showWeather = true );
    void    drawPostProcessStuff();

    TimeOfDay*  timeOfDay() const;
    EnviroMinder& enviroMinder() const;

    PY_METHOD_DECLARE( py_setTime )
    PY_METHOD_DECLARE( py_setSecondsPerHour )
    PY_RW_ACCESSOR_ATTRIBUTE_DECLARE( bool, fogEnable, fogEnable )
protected:
    virtual void disturbWater() {};

    Vector3     waterMovement_[2];
private:
    float       dTime_;
    class Distortion* distortion_;
    bool        inited_;
};
```

#### 4.6.1 PyObjectPlus 派生

`RompHarness` 继承 `PyObjectPlus`,通过 `Py_Header` 宏声明 Python 类型,使实例可作为 Python 对象访问。`WorldManager::init` 中将 `romp_` 注册为 `WorldEditor` 模块属性:

```cpp
// world_manager.cpp:829-833(fini 中反向操作)
PyObject * pMod = PyImport_AddModule( "WorldEditor" );
PyObject_DelAttrString( pMod, "romp" );
Py_DECREF( romp_ );
romp_ = NULL;
```

#### 4.6.2 职责

`RompHarness` 管理空间环境:
- `setTime`/`setSecondsPerHour`:时间与时间流速
- `fogEnable`:雾开关
- `update`:每帧更新(dTime + 全局天气)
- `drawPreSceneStuff`/`drawSceneStuff`/`drawDelayedSceneStuff`/`drawPostSceneStuff`/`drawPostProcessStuff`:分阶段渲染环境
- `enviroMinder()`:访问底层 `EnviroMinder`(雾/天气/天空)
- `timeOfDay()`:访问 `TimeOfDay`

worldeditor 的 `world_editor_romp_harness.hpp/.cpp` 提供编辑器专用派生类,增加编辑能力。

### 4.7 EditorChunkProcessorCache

`EditorChunkProcessorCache`(`editor_chunk_processor_cache.hpp`)是 `EditorChunkCacheBase` 的父类,集成 `ChunkCache` 与 `ChunkProcessor`,提供后台处理能力。地形、导航网格等缓存派生自此。

### 4.8 相机类层次

```
BaseCamera (base_camera.hpp)
├── OrbitCamera (orbit_camera.hpp)
├── MouseLookCamera (mouse_look_camera.hpp)
├── OrthographicCamera (orthographic_camera.hpp)
└── ToolsCamera (tools_camera.hpp)
```

`BaseCamera` 提供相机基础(位置/方向/视野),子类实现不同交互模式。worldeditor 的 `WorldEditorCamera`(misc/)组合这些相机。

---

## 五、关键算法与数据结构

### 5.1 UndoRedo 栈算法

`UndoRedo` 维护两个 `Barriers` 列表(`undoList_`/`redoList_`):

```
undoList_: [Barrier_old, ..., Barrier_prev, Barrier_current]
                                                  ▲ addUndo 追加到 current
redoList_: [Barrier_redo1, Barrier_redo2, ...]
                                  ▲ addRedo 追加
```

#### 5.1.1 undo 流程

1. 取 `undoList_.back()`(当前 Barrier)
2. 设 `undoing_ = true`
3. 反向遍历 Barrier 的 `ops_`,对每个 Operation 调 `op->undo()`(undo 实现中调 `add(redoOp)` 记录反向操作)
4. 将 Barrier 移到 `redoList_`
5. 设 `undoing_ = false`

#### 5.1.2 redo 流程

1. 取 `redoList_.back()`
2. 遍历 ops,调 `op->undo()`(此时 `undoing_=false`,反向操作记入 undo)
3. Barrier 移回 `undoList_`

#### 5.1.3 barrier 分组

`barrier(what, skipIfNoChange)`(`undoredo.hpp:71`)创建新 Barrier:
- 若当前 Barrier 无操作且 `skipIfNoChange`,丢弃
- 否则封存当前 Barrier,推入 `undoList_`,清空 `redoList_`(新操作后不可 redo)

### 5.2 Operation 合并判断

`Operation::operator==`(`undoredo.hpp:35-39`)用于判断两操作是否可合并:

```cpp
bool operator==( const Operation & oth ) const
{
    if (kind_ != oth.kind_ || !kind_) return false;
    return this->iseq( oth );
};
```

- `kind_` 不同 → 不等
- `kind_` 为 0(未设置)→ 不等(强制不合并)
- 同类 → 调 `iseq` 判断是否引用同一数据

子类实现 `iseq` 比较具体标识(如 chunk ID + 字段名),相同则合并(替换而非叠加),避免撤销栈膨胀。

### 5.3 BWLockDConnection 网格状态重建

`gridStatus_`(`bwlockd_connection.hpp:192`)是 `BW::vector<GridStatus>`,按一维索引存储每格状态。`rebuildGridStatus()`(私有)根据 `computers_`(所有计算机的锁)与 `self_`(本机用户名)重建:

```
for each computer in computers_:
    for each lock in computer.locks_:
        for each grid in lock.rect_:
            if computer.name_ == self_:
                gridStatus_[grid] = GS_LOCKED_BY_ME  (初始)
                if lock is writable: gridStatus_[grid] = GS_WRITABLE_BY_ME
            else:
                if gridStatus_[grid] == GS_NOT_LOCKED:
                    gridStatus_[grid] = GS_LOCKED_BY_OTHERS
```

`linkPoints_`(`bwlockd_connection.hpp:183`)记录跨锁定区域的链接点,`getLockRects(x,z)` 返回包含该格的所有锁矩形(含 link 展开的)。

### 5.4 EditorChunkCacheBase DataSection 缓存

`EditorChunkCacheBase` 为每个 chunk 缓存:
- `pChunkSection_`:chunk 的 `.chunk` 文件 DataSection
- `pCDataSection_`:chunk 的 `.cdata` 文件 DataSection

注释(`editor_chunk_cache_base.hpp:24-31`)强调:**必须使用此缓存的 DataSection,不可通过 BWResource 重新读取**——因缓存可能是唯一正确版本(场景保存时 chunk 可能被删除后又撤销,文件可能不存在)。

`edSave()`/`edSaveCData()` 保存到磁盘,由 `ChunkSaver`/`CdataSaver` 在 `UnsavedChunks` 系统统一调度。

### 5.5 SpaceEditor 单例注入线程安全

`SpaceEditor::instance` 使用函数内 `static` 指针(`space_editor.hpp:49`):

```cpp
static SpaceEditor* s_editor = NULL;
```

C++11 起函数内 static 初始化线程安全,但 14.4.1 代码未明确依赖此保证。注入发生在 WorldManager 构造(主线程启动早期),早于多线程启用,实际无竞争。

### 5.6 RompHarness 分阶段渲染

`RompHarness` 将环境渲染分为多阶段:

| 阶段 | 方法 | 内容 |
|------|------|------|
| PreScene | `drawPreSceneStuff` | 天空盒、远景(在场景前) |
| Scene | `drawSceneStuff` | 天气、植被、植被阴影 |
| DelayedScene | `drawDelayedSceneStuff` | 延迟的环境元素 |
| PostScene | `drawPostSceneStuff` | 后场景(雨/雪叠加) |
| PostProcess | `drawPostProcessStuff` | 后处理链 |

`WorldManager::render` 按序调用这些阶段,穿插 chunk/地形/gizmo 渲染。

---

## 六、配置项与命令行参数

`tools_common` 作为库不直接读取配置,但其类被使用者配置:

| 配置项(使用者侧) | 类型 | 说明 |
|------------------|------|------|
| `bwlockd/use` | bool | 是否启用 `BWLockDConnection` |
| `bwlockd/host` | string | bwlockd 服务器地址 |
| `bwlockd/username` | string | 用户名(空则取系统) |

`command_line.hpp` 定义命令行解析工具,供工具复用。

`compile_time.hpp/.cpp` 提供编译时间戳,用于版本信息显示。

---

## 七、与其他模块的依赖关系

### 7.1 链接依赖

`tools_common` 依赖(`CMakeLists.txt:114-119`):

| 库 | 类型 | 用途 |
|----|------|------|
| `cstdmf` | INTERFACE | 基础类型、调试、守卫 |
| `editor_shared` | INTERFACE | GUI 抽象(IEditorApp/IMainFrame 等) |
| `navigation_recast` | INTERFACE | Recast 导航网格 |
| `waypoint_generator` | INTERFACE | 路径点生成 |

### 7.2 被依赖

`tools_common` 被以下链接:

| 使用者 | 链接方式 |
|--------|---------|
| worldeditor | 链接库 + 直接编译部分文件 |
| modeleditor_core | 链接库 |

### 7.3 依赖关系图

```
        ┌─────────────────────────────────────┐
        │            tools_common              │
        └──┬──────┬──────┬──────┬──────┬──────┘
           │      │      │      │      │
           ▼      ▼      ▼      ▼      ▼
       ┌──────┐┌──────┐┌──────┐┌──────┐┌──────┐
       │cstdmf││editor││naviga││waypoi││chunk │
       │      ││_shared││tion_ ││nt_gen││(运行│
       │      ││      ││recast││      ││时)  │
       └──────┘└──────┘└──────┘└──────┘└──────┘
                      │
                      ▼
                ┌──────────┐
                │   mfc    │ (BWStandardMFCProject)
                │ (Win32)  │
                └──────────┘
```

### 7.4 运行时依赖

| 运行时模块 | 关系 |
|-----------|------|
| `BWLockDConnection` → bwlockd 进程 | TCP 连接 |
| `EditorChunkCacheBase` → `EditorChunkCache`(worldeditor) | 特化委托(worldeditor 提供派生类) |
| `SpaceEditor` → `WorldManager`(worldeditor) | 单例注入 |
| `RompHarness` → `EnviroMinder`/`TimeOfDay`(romp) | 组合 |
| `UndoRedo` → `Operation` 子类(worldeditor undo_redo/) | 多态调用 |

---

## 八、关键代码片段

### 8.1 UndoRedo::Operation 抽象与比较

```cpp
// undoredo.hpp:27-50
class Operation
{
public:
    Operation( int kind ) : kind_( kind ) { }
    virtual ~Operation() { }

    virtual void undo() = 0;

    bool operator==( const Operation & oth ) const
    {
        if (kind_ != oth.kind_ || !kind_) return false;
        return this->iseq( oth );
    };

    bool operator!=( const Operation & oth ) const
    {
        return !( *this == oth );
    }

    virtual bool iseq( const Operation & oth ) const = 0;

protected:
    int kind_;
};
```

### 8.2 UndoRedo::add 自动分流

```cpp
// undoredo.hpp:60-66
void add( Operation * op )
{
    if (!undoing_)
        this->addUndo( op );
    else
        this->addRedo( op );
}
```

### 8.3 UndoRedo::Barrier 引用计数容器

```cpp
// undoredo.hpp:95-110
class Barrier : public ReferenceCount
{
public:
    ~Barrier();
    BW::string      what_;
    Operations      ops_;
};

typedef SmartPointer<Barrier> BarrierPtr;
typedef BW::vector<BarrierPtr> Barriers;

Barriers    undoList_;  // back is additions since latest barrier
Barriers    redoList_;  // back is next Operations to redo
                        //  (except during undo when it's additions)
bool        undoing_;
```

### 8.4 BWLockDConnection::GridStatus 四状态

```cpp
// bwlockd_connection.hpp:24-36
enum GridStatus
{
    // this grid is not locked by anyone
    GS_NOT_LOCKED = 0,
    // this grid is locked by me, but not editable
    GS_LOCKED_BY_ME,
    // this grid is locked by sb. else
    GS_LOCKED_BY_OTHERS,
    // this grid is locked by me and editable
    GS_WRITABLE_BY_ME,
    // count of grid status
    GS_MAX
};
```

### 8.5 BWLockDConnection::Rect 几何判断

```cpp
// bwlockd_connection.hpp:50-61
bool in( int x, int y ) const
{
    return x >= left_ && x <= right_ && y >= top_ && y <= bottom_;
}
bool intersect( const Rect& that ) const
{
    if( in( that.left_, that.top_ ) || in( that.right_, that.top_ )
        || in( that.left_, that.bottom_ ) || in( that.right_, that.bottom_ ) )
        return true;
    return that.in( left_, top_ ) || that.in( right_, top_ )
        || that.in( left_, bottom_ ) || that.in( right_, bottom_ );
}
```

### 8.6 EditorChunkCacheBase 特化与 Saver

```cpp
// editor_chunk_cache_base.hpp:17-18
class EditorChunkCacheBase;
template <>
EditorChunkCacheBase & ChunkCache::Instance<EditorChunkCacheBase>::operator()( Chunk & chunk ) const;
```

```cpp
// editor_chunk_cache_base.hpp:63-73
class ChunkSaver : public UnsavedChunks::IChunkSaver
{
    virtual bool save( Chunk* chunk )
    {
        return EditorChunkCacheBase::instance( *chunk ).edSave();
    }
    bool isDeleted( Chunk& chunk ) const
    {
        return false;
    }
};
```

### 8.7 SpaceEditor 单例注入

```cpp
// space_editor.hpp:47-59
static SpaceEditor& instance( SpaceEditor* editor = NULL )
{
    static SpaceEditor* s_editor = NULL;

    if (editor)
    {
        // Used in WE passed with WorldManager instance
        s_editor = editor;
    }

    MF_ASSERT( s_editor );
    return *s_editor;
}
```

### 8.8 RompHarness PyObjectPlus 派生

```cpp
// romp_harness.hpp:26-31
class RompHarness : public PyObjectPlus
{
    Py_Header( RompHarness, PyObjectPlus )
public:
    RompHarness( PyTypeObject * pType = &s_type_ );
    ~RompHarness();
```

### 8.9 旧式 undo.h 的 C 风格结构

```cpp
// undo.h:33-43
typedef char* UndoData;

typedef struct
{
    unsigned int    id;
    unsigned int    opCode;
    AnsiString      description;
    UndoData        data;
    int             size;
    bool            linked;
} UndoInfo;
```

```cpp
// undo.h:55
typedef bool(*UndoFunc)(unsigned int, UndoData);
```

---

## 九、设计亮点与注意事项

### 9.1 设计亮点

#### 9.1.1 UndoRedo 的双向自动分流

`add(Operation*)` 根据 `undoing_` 标志自动分流到 undo/redo 列表,使同一 Operation 类在 `undo()` 实现中调用 `add(redoOp)` 即可记录反向操作,无需维护两套类。这是**命令模式 + 反向操作记录**的优雅实现。

#### 9.1.2 Barrier 引用计数分组

`Barrier` 继承 `ReferenceCount`,通过 `SmartPointer` 管理。这解决了 Operation 跨 Barrier 共享(如链接操作)的生命周期问题——多个 Barrier 可安全引用同一 Operation,引用归零自动释放。

#### 9.1.3 Operation kind_ 合并机制

`kind_ = int(typeid(*this).name())` 利用 RTTI 自动生成类型标识,`operator==` 先比 kind 再调 `iseq`,使子类只需实现 `iseq` 即可获得合并能力,避免撤销栈因连续同类操作(如鼠标拖动)膨胀。

#### 9.1.4 SpaceEditor 单例注入解耦

`SpaceEditor` 是抽象接口 + 单例注入,使 `tools_common` 能回调 worldeditor 的具体实现而不依赖其头文件。这是**依赖倒置**的典型应用——库定义接口,使用者注入实现。

#### 9.1.5 EditorChunkCacheBase DataSection 缓存策略

注释明确要求使用缓存的 DataSection 而非重新读取文件,因编辑过程中 chunk 可能被删除又撤销,文件状态不可靠。缓存持有"编辑会话内唯一正确版本",是编辑器健壮性的关键。

#### 9.1.6 BWLockDConnection 观察者模式

`Notification` 内嵌接口允许外部注册锁状态变化回调,`tick` 检测更新后 `notify`。这使 LockMap 纹理、UI 状态等能实时响应,而无需轮询。

#### 9.1.7 RompHarness 分阶段渲染

将环境渲染拆为 PreScene/Scene/DelayedScene/PostScene/PostProcess 五阶段,与 chunk/地形/gizmo 渲染穿插,实现正确的渲染顺序(天空在前、雨雪在后、后处理最后)。

### 9.2 注意事项

#### 9.2.1 新旧 Undo 系统并存

`undoredo.hpp`(新式)与 `undo.h`(旧式)并存。**新代码必须使用 `UndoRedo`**。`undo.h` 依赖 `AnsiString`/`TAction` 等 VCL 类型,在 MFC 构建中不可用,可能不被实际编译。维护时需识别文件属于哪套系统。

#### 9.2.2 BWLockDConnection 的 CLIENT_ONLY 条件

`bwlockd_connection.hpp` 全文包裹 `#if !defined( BIGWORLD_CLIENT_ONLY )`(`bwlockd_connection.hpp:5, 198`):

```cpp
#if !defined( BIGWORLD_CLIENT_ONLY )
// ... 全部内容 ...
#endif // BIGWORLD_CLIENT_ONLY
```

CLIENT_ONLY 构建下无此类。使用者(worldeditor)的相关代码同样条件编译。

#### 9.2.3 SpaceEditor 注入时机

`SpaceEditor::instance(editor)` 必须在任意 `SpaceEditor::instance()` 调用前注入。worldeditor 在 `WorldManager` 构造函数(`world_manager.cpp:709`)注入,早于 chunk 加载等可能回调的时机。若其他工具使用 `tools_common` 但未注入,`MF_ASSERT` 会触发。

#### 9.2.4 EditorChunkCacheBase 特化委托

`EditorChunkCacheBase::instance(chunk)` 的特化实际委托给 worldeditor 的 `EditorChunkCache`(派生类)。这意味着 `tools_common` 中的 `ChunkSaver`/`CdataSaver` 调用会进入 worldeditor 的具体实现,库与使用者之间存在运行时耦合。

#### 9.2.5 worldeditor 的混合编译

worldeditor 既链接 `tools_common` 库,又直接编译部分 common 文件(`COMMON_CODE_SRCS`)。修改 common 文件时需确认是库内还是 worldeditor 直接编译,避免符号重复或修改不生效。

#### 9.2.6 undo.h 的 VCL 遗留

`undo.h` 中的 `AnsiString`、`TAction`、`TStrings` 是 Borland VCL 类型。若该文件被 MFC 构建包含,会编译失败。实际可能通过条件编译排除或未被任何 .cpp 包含。维护时应避免引用。

#### 9.2.7 RompHarness 的 Python 所有权

`RompHarness` 继承 `PyObjectPlus`,实例被 Python 引用持有。worldeditor 在 fini 中需 `PyObject_DelAttrString` 删除模块属性并 `Py_DECREF`,否则泄漏。`world_manager.cpp:829-833` 展示了正确的清理顺序。

#### 9.2.8 MFC 依赖

`tools_common` 包含 `BWStandardMFCProject`,部分文件(对话框、属性表)依赖 MFC。非 MFC 工具无法直接链接完整库,需挑选无 MFC 依赖的子集。

### 9.3 关键文件速查

| 文件 | 作用 |
|------|------|
| `undoredo.hpp` | 新式撤销/重做接口(Operation/Barrier) |
| `undo.h` | 旧式撤销(C 风格遗留,勿用) |
| `bwlockd_connection.hpp` | bwlockd TCP 连接 + GridStatus |
| `editor_chunk_cache_base.hpp` | chunk 缓存基类 + Saver |
| `editor_chunk_processor_cache.hpp` | chunk 处理器缓存 |
| `space_editor.hpp` | 空间编辑回调接口 + 单例注入 |
| `romp_harness.hpp` | 环境管理器(Python 暴露) |
| `base_camera.hpp` | 相机基类 |
| `tools_common.hpp` | 公共工具函数 |
| `command_line.hpp` | 命令行解析 |
| `grid_coord.hpp` | 网格坐标 |
| `CMakeLists.txt` | 静态库构建定义 |

### 9.4 类关系总览

```
UndoRedo (单例)
├── Operation (抽象, kind_ + iseq)
│   └── 子类在 worldeditor/undo_redo/ 实现
└── Barrier (ReferenceCount, SmartPointer 管理)
    └── Operations = vector<Operation*>

BWLockDConnection
├── Notification (观察者接口)
├── GridStatus (4 状态枚举)
├── Rect / Lock / Computer (数据结构)
└── gridStatus_ = vector<GridStatus>

EditorChunkCacheBase : EditorChunkProcessorCache
├── 特化 ChunkCache::Instance<EditorChunkCacheBase>
├── pChunkSection_ / pCDataSection_ (DataSection 缓存)
└── ChunkSaver / CdataSaver (UnsavedChunks::IChunkSaver)

SpaceEditor (抽象, 单例注入)
└── WorldManager 实现(worldeditor)

RompHarness : PyObjectPlus
├── setTime / setSecondsPerHour / fogEnable
├── update / draw*Stuff (分阶段渲染)
└── enviroMinder() / timeOfDay()
```

### 9.5 与其他库的差异

| 特性 | tools_common | editor_shared | cstdmf |
|------|-------------|---------------|--------|
| 类型 | 静态库 | 静态库 | 静态库 |
| MFC 依赖 | 是 | 部分(MFC/QT 双模式) | 否 |
| 入口点 | 无 | 无 | 无 |
| Python 暴露 | RompHarness | 无 | 无 |
| 单例注入 | SpaceEditor | 无 | 无 |
| 撤销系统 | UndoRedo + undo.h | 无 | 无 |
| 协作锁 | BWLockDConnection | 无 | 无 |

`tools_common` 是工具链的"业务公共层",`editor_shared` 是"GUI 抽象层",`cstdmf` 是"基础类型层"。三者分工明确,共同支撑 worldeditor 等工具的复用。
