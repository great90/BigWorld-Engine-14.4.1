# 第14章 Chunk 空间加载系统

> 第 9 章我们看完了服务器侧的 **Cell** 与空间分割:CellApp 把世界切成一片片矩形/BSP 区域,每片由一个 CellApp 进程负责模拟。但那是服务器视角。本章我们换到**客户端**视角,看看 BigWorld 是怎么把"几乎无限大"的世界一点点"喂"给玩家显示出来的——这就是 **Chunk 系统**。Chunk 是 BigWorld 客户端的流式加载基石:它把整个世界切成成千上万个小立方体文件,玩家走到哪、加载到哪,通过 **Portal** 把相邻 Chunk 缝合起来,做到"无缝大世界"。本章带你逐步看懂:Chunk 的概念与文件格式、`Chunk` 类的核心机制、`ChunkLoader` 异步加载流程、`ChunkItem` 工厂模式、Portal 视锥剔除、VLO 跨 Chunk 大对象,以及 `compiled_space` / `chunk_scene_adapter` 这些"上层壳"。

---

## 目录

- [14.1 Chunk 系统概述](#141-chunk-系统概述)
- [14.2 源码结构全景](#142-源码结构全景)
- [14.3 Chunk 概念详解](#143-chunk-概念详解)
- [14.4 Chunk 类核心](#144-chunk-类核心)
- [14.5 空间加载流程](#145-空间加载流程)
- [14.6 Chunk 项系统](#146-chunk-项系统)
- [14.7 Portal 系统](#147-portal-系统)
- [14.8 VLO(Very Large Object)](#148-vlovery-large-object)
- [14.9 Chunk 链接系统](#149-chunk-链接系统)
- [14.10 compiled_space 与 chunk_scene_adapter](#1410-compiled_space-与-chunk_scene_adapter)
- [14.11 特色实现深度剖析](#1411-特色实现深度剖析)
- [14.12 本章小结](#1412-本章小结)

---

## 14.1 Chunk 系统概述

### 14.1.1 它是什么

**Chunk 系统**是 BigWorld 客户端(以及工具链)用于管理世界几何数据的核心。它的本质是一句话:**把整个连续世界离散化成大量小立方体,每个立方体一个文件,玩家走到附近才加载**。

一个典型的 MMO 世界可能有几十平方公里,如果一次性把所有地形、模型、灯光、粒子都加载进内存,客户端会直接爆掉。BigWorld 的做法是:

- 把世界按网格切成 **Chunk**(默认每边 100 米);
- 每个 Chunk 是一个 `.chunk` 文件,里面打包了这一格内的所有静态物体;
- 客户端只加载玩家附近的 Chunk,玩家走远了就把远处 Chunk 卸载;
- 相邻 Chunk 通过 **Portal** 缝合,做到视觉上无接缝。

这种思路在游戏引擎领域有个通用名字:**流式加载(Streaming)**。BigWorld 的实现是这一思路的早期典范,与后来的 Unreal Engine World Composition、CryEngine 的 Streaming 别无二致,但 BigWorld 的 Portal 系统做得尤其精致。

### 14.1.2 流式加载 vs 一次性加载

| 维度 | 一次性加载(传统关卡) | 流式加载(Chunk 系统) |
|------|----------------------|----------------------|
| 世界大小 | 受内存限制,通常几公里 | 几乎无限大 |
| 加载时机 | 进关卡前 loading 屏幕 | 玩家移动中分帧加载 |
| 内存占用 | 全部常驻 | 仅玩家附近常驻 |
| 实现难度 | 简单 | 复杂(要处理边界缝合) |
| 适用场景 | FPS / 单机关卡 | MMO / 开放世界 |

Chunk 系统的复杂度主要来自两件事:

1. **何时该加载/卸载哪个 Chunk**——需要一个聪明的扫描算法;
2. **相邻 Chunk 之间怎么无缝衔接**——这就是 Portal 系统要解决的问题。

### 14.1.3 与服务器 Cell 系统的对比

第 9 章我们讲过服务器侧的 Cell:CellApp 把世界按 BSP 切成 Cell,每个 Cell 由一个 CellApp 进程模拟。本章的 Chunk 是客户端的概念,两者**都是空间分割**,但目的完全不同:

| 维度 | 服务器 Cell(第 9 章) | 客户端 Chunk(本章) |
|------|----------------------|---------------------|
| 切分方式 | BSP 动态切分 | 固定网格(室外)+ 自由形状(室内) |
| 切分目的 | 实体模拟负载分布 | 几何数据流式加载 |
| 单元大小 | 动态,负载均衡时变 | 固定(默认 100m 网格) |
| 数据内容 | Entity + AOI 索引 | 模型、地形、灯光、粒子 |
| 跨边界协议 | Ghost + 实体迁移 | Portal 渲染缝合 |
| 由谁调度 | CellAppMgr 控制平面 | 客户端本地 ChunkManager |

简单说:**Cell 是服务器按负载切的动态网格,Chunk 是客户端按地图切的静态网格**。服务器关心"哪个进程算这些实体",客户端关心"哪些几何数据要进显卡"。两者各自独立工作,共同支撑了 BigWorld 的无缝大世界。

### 14.1.4 与其他模块的关系

```
              ┌──────────────────────┐
              │   World Editor      │  ← 关卡编辑器,产出 .chunk 文件
              └──────────┬───────────┘
                         │ .chunk / .cdata
                         ▼
   ┌──────────────────────────────────────────┐
   │            ChunkManager(单例)            │
   │   扫描玩家附近 → 决定加载哪些 Chunk      │
   └──────┬───────────────────┬───────────────┘
          │                   │
          ▼                   ▼
   ┌──────────────┐   ┌──────────────────┐
   │  ChunkLoader │   │   ChunkSpace     │
   │  后台线程加载 │   │   所有 chunk 索引│
   └──────┬───────┘   └────────┬─────────┘
          │                    │
          ▼                    ▼
   ┌──────────────────────────────────────┐
   │   Chunk(.chunk 文件解析后的对象)      │
   │   ├── ChunkModel(模型)               │
   │   ├── ChunkLight(灯光)              │
   │   ├── ChunkTerrain(地形)            │
   │   ├── ChunkTree(树)                 │
   │   └── ... 各种 ChunkItem            │
   └──────────────────────────────────────┘
          │
          ▼
   ┌──────────────────────────────────────┐
   │      Moo 渲染层(第 15 章会讲)        │
   └──────────────────────────────────────┘
```

Chunk 系统处于"资源层"和"渲染层"之间:从资源管理器(`resmgr`)读取 `.chunk` 文件,解析成内存对象,再交给 Moo 渲染。

---

## 14.2 源码结构全景

Chunk 系统的源码分布在 `programming/bigworld/lib/` 下的四个目录:

### 14.2.1 `lib/chunk/` —— 核心库

这是 Chunk 系统的"主战场",共约 130 个文件。按职责分组:

```
lib/chunk/
├── 核心类
│   ├── chunk.hpp/.cpp                # Chunk 类,本章主角
│   ├── chunk_item.hpp/.cpp           # ChunkItem 基类 + 工厂
│   ├── chunk_boundary.hpp/.cpp       # Chunk 边界 + Portal
│   ├── chunk_space.hpp/.cpp          # ChunkSpace 空间索引
│   ├── chunk_manager.hpp/.cpp        # ChunkManager 单例
│   ├── chunk_loader.hpp/.cpp         # ChunkLoader 后台加载器
│   └── geometry_mapping.hpp/.cpp     # 资源目录到空间的映射
│
├── ChunkItem 子类(典型几个)
│   ├── chunk_model.hpp/.cpp          # 静态模型
│   ├── chunk_light.hpp/.cpp          # 灯光(点/聚/方向/环境)
│   ├── chunk_terrain.hpp/.cpp        # 地形块
│   ├── chunk_tree.hpp/.cpp           # SpeedTree 树
│   ├── chunk_water.hpp/.cpp          # 水面
│   ├── chunk_flora.hpp/.cpp          # 草丛
│   ├── chunk_flare.hpp/.cpp          # 镜头光晕
│   └── chunk_marker.hpp/.cpp         # 标记点
│
├── 特殊机制
│   ├── chunk_vlo.hpp/.cpp            # VLO 跨 Chunk 大对象
│   ├── chunk_link.hpp/.cpp           # Chunk 项之间的链接
│   ├── chunk_cache.hpp/.cpp/.ipp     # 每 Chunk 缓存(灯光、Umbra 等)
│   ├── chunk_obstacle.hpp/.cpp       # 碰撞三角形
│   ├── chunk_overlapper.hpp/.cpp     # 跨边界重叠管理
│   └── chunk_exit_portal.hpp/.cpp    # 出口 Portal(用于天空/地面)
│
├── 客户端 / 服务器 / 编辑器变体
│   ├── client_chunk_space.hpp/.cpp    # 客户端 ChunkSpace
│   ├── server_chunk_space.hpp/.cpp    # 服务器 ChunkSpace(导航/碰撞用)
│   ├── editor_chunk_item.hpp/.ipp    # 编辑器扩展基类
│   └── ...
│
└── 辅助
    ├── chunk_format.hpp              # Chunk 标识符编码
    ├── chunk_lib.hpp                 # 库导出宏
    ├── forward_declarations.hpp      # 前向声明
    └── pch.hpp                       # 预编译头
```

### 14.2.2 `lib/chunk_loading/` —— 边界映射加载

只有 9 个文件,主要服务于"服务器加载整个空间"的场景:

```
lib/chunk_loading/
├── preloaded_chunk_space.hpp/.cpp    # 预加载 ChunkSpace(增量加载不卸载)
├── edge_geometry_mapping.hpp/.cpp    # 单个边界 GeometryMapping
├── edge_geometry_mappings.hpp/.cpp   # 多个边界 mapping 集合
├── loading_column.hpp/.cpp           # 加载列
├── loading_edge.hpp/.cpp             # 加载边
├── chunk_loading_ref_count.hpp/.cpp  # 加载引用计数
└── geometry_mapper.hpp               # mapping 工厂接口
```

服务器端 CellApp 在启动时会把整个空间一次性加载(用于导航生成、物理碰撞),用这个库。

### 14.2.3 `lib/chunk_scene_adapter/` —— 场景适配器

只有 3 个文件,作用是把老的 `ChunkSpace` 接口适配到新一代的 `ClientSpace` / `Scene` 接口:

```
lib/chunk_scene_adapter/
├── client_chunk_space_adapter.hpp/.cpp   # 适配器
└── pch.hpp/.cpp
```

### 14.2.4 `lib/compiled_space/` —— 编译后的二进制空间

这是新一代的"二进制空间格式",取代了传统的 `.chunk` 文本/XML 格式,加载更快:

```
lib/compiled_space/
├── 编译期写入器 binary_writers/   # 工具链用,把 .chunk 编译成二进制
├── 运行期加载
│   ├── compiled_space.hpp/.cpp    # CompiledSpace 类
│   ├── loader.hpp/.cpp            # ILoader 加载器接口
│   ├── compiled_space_mapping.hpp/.cpp
│   ├── static_scene_provider.hpp/.cpp
│   ├── light_scene_provider.hpp/.cpp
│   ├── terrain2_scene_provider.hpp/.cpp
│   └── ...
└── unit_test/                     # 单元测试
```

后续 14.10 节会专门讲这两个"上层壳"。

---

## 14.3 Chunk 概念详解

### 14.3.1 Chunk 是什么

打开 `chunk.hpp`,看 `Chunk` 类的注释:

> This class defines a chunk, the node of our scene graph.
> A chunk is a convex three dimensional volume. It contains a description of the scene objects that reside inside it.

翻译过来就是:**Chunk 是场景图的一个节点,代表三维空间中一个凸体积,里面装着这个体积内的所有场景物体**。

关键点有三个:

1. **凸体积(Convex Volume)**——Chunk 的边界由一组平面组成,这些平面围出一个凸区域。凸性是为了让碰撞、剔除等算法简单。
2. **场景物体描述**——Chunk 不直接持有 GPU 资源,它持有的是"描述":哪个模型、什么变换、哪个灯光、什么颜色。这些描述由 `ChunkItem` 子类承担。
3. **场景图节点**——Chunk 之间通过 Portal 互相引用,构成一个图(不是树,因为有环)。

### 14.3.2 室外 Chunk 与室内 Chunk

BigWorld 的 Chunk 分两类:

**室外 Chunk(Outside Chunk)**

- 标识符以 `o` 结尾,如 `00a5017fo`;
- 是固定大小的立方体,边长由 `gridSize` 决定(默认 100 米,可配置);
- 高度范围固定,通常 `[MIN_CHUNK_HEIGHT, MAX_CHUNK_HEIGHT]`;
- 地形(ChunkTerrain)通常放在室外 Chunk 里;
- 顶面通常接 **Heaven Portal**(看天空),底面接 **Earth Portal**(看地形)。

**室内 Chunk(Inside/Shell Chunk)**

- 标识符不以 `o` 结尾,通常是房间名如 `abc_room01`;
- 形状由 `boundingBox` 决定,可以是任意凸多面体;
- 不放地形,主要放模型(墙、地板、家具)、灯光、粒子;
- 通过 Portal 与外界(室外 Chunk 或其他室内 Chunk)连接。

`chunk.cpp` 构造函数里有这段代码,体现了室外 Chunk 的几何是自动算出来的:

```cpp
// chunk.cpp 构造函数片段
if ( isOutsideChunk() )
{
    pMapping->gridFromChunkName( this->identifier(), x_, z_ );
    float xf = float(x_) * gridSize;
    float zf = float(z_) * gridSize;
    localBB_ = BoundingBox( Vector3( 0.f, MIN_CHUNK_HEIGHT, 0.f ),
        Vector3( gridSize, MAX_CHUNK_HEIGHT, gridSize ) );
    boundingBox_ = BoundingBox( Vector3( xf, MIN_CHUNK_HEIGHT, zf ),
        Vector3( xf + gridSize, MAX_CHUNK_HEIGHT, zf + gridSize ) );
    unmappedTransform_.setTranslate( xf, 0.f, zf );
    transform_.setTranslate( xf, 0.f, zf );
    transform_.postMultiply( pMapping->mapper() );
    // ...
}
```

也就是说:**室外 Chunk 的位置和包围盒是从它的网格坐标 `(x_, z_)` 直接算出来的**,不需要在文件里指定。

### 14.3.3 Chunk 文件格式(.chunk)

打开 `lib/chunk/chunk format.txt`,这是 Chunk 文件的人类可读格式说明:

```
<root>	?LABEL
	*<include>
		<resource>	RES_FILE_NAME.chunk/.prefab/.mfo		</resource>
		<transform> ... </tranform>
	</include>

	*<light>	?LABEL
		<type>			Omni/etc	</type>
		<colour>		85.00 251.00 189.00		</colour>
		<innerRadius>	6.60		</innerRadius>
		<outerRadius>	13.50		</outerRadius>
		<transform> ... </transform>
	</light>

	*<model>	?LABEL
		+<resource>	RES_FILE_NAME.model/.mfo	</resource>
		?<animation> ... </animation>
		<transform> ... </transform>
	</model>

	+<terrain>
		<resource>	RES_FILE_NAME.terrain </resource>
	</terrain>

	*<entity> ... </entity>
	*<sound> ... </sound>

	+4<boundary>
		<normal>	.f	.f	.f	</normal>
		<d>	.f	</d>
		*<portal>	?LABEL
			?<internal>		false	</internal>
			?<permissive>	true	</permissive>
			?<chunk>		SPACE_RELATIVE_FILE_NAME	</chunk>
			<uAxis>	.f	.f	.f	</uAxis>
			+3<point>	.f	.f	0	</point>
		</portal>
	</boundary>

	<transform> ... </transform>
	<boundingBox>
		<min>	.f	.f	.f	</min>
		<max>	.f	.f	.f	</max>
	</boundingBox>
</root>
```

语法符号含义:

- `?` 表示 0 或 1 个;
- `*` 表示 0 或多个;
- `+` 表示 1 或多个;
- `+n` 表示 n 或多个(如 `+4<boundary>` 表示至少 4 个 boundary)。

一个 `.chunk` 文件本质上是一个 XML,根节点包含:

- **`<include>`**:引用其他 `.chunk` 文件,实现复用(类似 prefab);
- **`<light>`**:灯光(omni/spot/directional/ambient);
- **`<model>`**:静态模型(`.model` 文件);
- **`<terrain>`**:地形块(`.terrain` 文件,室外 Chunk 才有);
- **`<entity>`**:隐式实体(在 chunk 里直接定义实体);
- **`<sound>`**:声源;
- **`<boundary>`**:边界平面,带若干 `<portal>`(通向其他 chunk);
- **`<transform>`**:chunk 自身的变换(室内用,室外由网格坐标算);
- **`<boundingBox>`**:包围盒(室内用)。

实际运行时客户端读的不是 `.chunk` 文本,而是 `.cdata` 二进制(`binFileName()`)。`.chunk` 是源格式,`.cdata` 是编译产物,加载更快。`ChunkLoader::load` 里同时打开两个:

```cpp
// chunk_loader.cpp
DataSectionPtr pDS = BWResource::openSection( pChunk->resourceID() );
DataSectionPtr pCData = BWResource::openSection( pChunk->binFileName() );
pChunk->load( pDS );
```

### 14.3.4 Chunk 标识符与网格

室外 Chunk 的标识符是它网格坐标的十六进制编码加 `o`,见 `chunk_format.hpp`:

```cpp
inline BW::string outsideChunkIdentifier( int gridX, int gridZ,
    bool singleDir = false )
{
    // ... 处理子目录分桶
    bw_snprintf( chunkIdentifierCStr, sizeof(chunkIdentifierCStr),
        "%04x%04xo", int(gridxs), int(gridzs) );
    gridChunkIdentifier += chunkIdentifierCStr;
    return gridChunkIdentifier;
}
```

所以 `00a5017fo` 表示网格 `(0x00a5, 0x017f) = (165, 383)`。如果 gridSize 是 100 米,那么这个 chunk 的世界坐标就是 `(16500, 38300)` 起步。

注意中间还有一截目录分桶逻辑(`sep/` 子目录):当网格坐标超过某个范围时,会自动加一层目录,避免单个目录下文件过多。这是 BigWorld 处理"海量小文件"的常见技巧。

---

## 14.4 Chunk 类核心

### 14.4.1 Chunk 类定义

`Chunk` 类位于 `chunk.hpp`,核心字段如下(精简版):

```cpp
class Chunk
{
public:
    Chunk( const BW::string & identifier, GeometryMapping * pMapping,
            const Matrix& transform = Matrix::identity,
            const BoundingBox& localBounds = BoundingBox::s_insideOut_ );

    bool load( DataSectionPtr pSection );
    void unload();
    void bind( bool shouldFormPortalConnections );
    void unbind( bool cut );
    void focus();

    // 静态/动态项管理
    bool addStaticItem( ChunkItemPtr pItem );
    void addDynamicItem( ChunkItemPtr pItem );
    bool addLoanItem( ChunkItemPtr pItem );

    // 状态查询
    bool loading()  const { return loading_; }
    bool loaded()   const { return loaded_; }
    bool isBound()  const { return isBound_; }
    bool completed()const { return completed_; }

    // 标识与位置
    const BW::string & identifier() const { return identifier_; }
    int16 x() const { return x_; }
    int16 z() const { return z_; }
    GeometryMapping * mapping() const { return pMapping_; }
    ChunkSpace * space() const { return pSpace_; }
    const BoundingBox & boundingBox() const { return boundingBox_; }

    // 边界与 Portal
    ChunkBoundaries & bounds() { return bounds_; }
    ChunkBoundaries & joints() { return joints_; }

    // 工厂注册
    static void registerFactory( const BW::string & section,
        const ChunkItemFactory & factory );

private:
    BW::string      identifier_;
    int16           x_, z_;
    GeometryMapping * pMapping_;
    ChunkSpace      * pSpace_;
    bool            isOutsideChunk_;

    bool            loading_, loaded_, isBound_, completed_;
    int             focusCount_;

    Matrix          transform_, transformInverse_;
    BoundingBox     localBB_, boundingBox_;

    ChunkBoundaries bounds_;   // 物理边界(凸包面)
    ChunkBoundaries joints_;   // 逻辑连接(Portal 所在)

    Items           selfItems_;    // 静态项
    Items           dynoItems_;    // 动态项
    Lenders         lenders_;     // 借给别的 chunk 的项
    Borrowers       borrowers_;   // 从别的 chunk 借来的项

    ChunkCache * *  caches_;      // 每 chunk 缓存(灯光、Umbra 等)
    // ...
};
```

几个要点:

- **`identifier_`** + **`pMapping_`** 唯一确定一个 Chunk;
- **`x_, z_`** 是室外 Chunk 的网格坐标,室内 Chunk 用不上;
- **`bounds_` vs `joints_`**:`bounds_` 是物理边界(凸包面),`joints_` 是逻辑连接(Portal 所在位置)。两者类型都是 `ChunkBoundaries`,但语义不同;
- **`selfItems_` / `dynoItems_`** 区分静态、动态项;
- **`caches_`** 是个指针数组,每个 Chunk 可以挂多个 `ChunkCache`(灯光缓存、Umbra 缓存等)。

### 14.4.2 状态机:loading / loaded / bound / completed

Chunk 的生命周期是一台状态机。`chunk.hpp` 注释里说:

> See note about chunk states at the bottom of the cpp file

四个核心状态(都是布尔字段):

| 状态 | 含义 | 进入条件 |
|------|------|---------|
| `loading_` | 正在后台加载 | `ChunkLoader::load` 调用,提交 `LoadChunkTask` |
| `loaded_` | 数据已读入内存 | `Chunk::load` 返回,所有 ChunkItem 已构造 |
| `isBound_` | 已绑定,Portal 已连接 | `Chunk::bind` 完成 |
| `completed_` | 所有依赖 Shell 已聚焦 | `updateCompleted` 检查通过 |

状态转移大致是:

```
[空] ──load()──> loading ──数据读完──> loaded ──bind()──> isBound ──所有 shell focused──> completed
                                                │
                                                └──unbind()──> loaded(可重 bind)
       completed ──unload()──> [空]
```

`bind()` 是从 loading 到 bound 的关键步骤,代码片段:

```cpp
// chunk.cpp
void Chunk::bind( bool shouldFormPortalConnections )
{
    MF_ASSERT( MainThreadTracker::isCurrentThreadMain() );

    if (std::find( s_bindingChunks_.begin(), s_bindingChunks_.end(), this )
        != s_bindingChunks_.end())
    {
        return;  // 已在绑定中,避免递归
    }
    s_bindingChunks_.push_back( this );
    MF_ASSERT( this->loaded() );

    if (this->loading()) {
        this->loading( false );
    }

    this->syncInit();                              // 1. 同步初始化(创建 Umbra 对象等)
    this->bindPortals( shouldFormPortalConnections,
        /*shouldNotifyCaches:*/false );            // 2. 绑定所有 Portal
    this->notifyCachesOfBind( /*isUnbind:*/ false ); // 3. 通知缓存(灯光等)
    isBound_ = true;
    pSpace_->noticeChunk( this );                  // 4. 让 ChunkSpace 知道我准备好了
    // ... 处理 overlapper
    s_bindingChunks_.pop_back();
}
```

注意 `s_bindingChunks_` 这个静态栈——它防止 `bindPortals` 递归绑定相邻 chunk 时无限循环(因为绑定 Portal 时可能触发相邻 chunk 的 bind)。

### 14.4.3 静态项与动态项

`Chunk` 持有两类 ChunkItem:

- **`selfItems_`(静态项)**:从 `.chunk` 文件加载时就存在的物体,如模型、地形、灯光。生命周期与 chunk 相同,chunk 卸载它们也卸载。
- **`dynoItems_`(动态项)**:运行时加入的物体,如玩家、NPC、临时特效。可以跨 chunk 移动。

`addStaticItem` / `addDynamicItem` 是加入方法。静态项加入后还会被 `updateBoundingBoxes` 用来扩展 chunk 的包围盒。

```cpp
// chunk.hpp
bool addStaticItem( ChunkItemPtr pItem );      // 加入并扩展 BB
void addDynamicItem( ChunkItemPtr pItem );     // 临时加入(如玩家走过)
bool addLoanItem( ChunkItemPtr pItem );         // 从别的 chunk 借来的
```

### 14.4.4 借出(Lend)与借入(Borrow)机制

这是一个有点 tricky 但很重要的设计。考虑这个场景:一个超大的雕像模型,它的中心在 Chunk A,但它的胳膊伸到了 Chunk B。这个模型该归谁?

BigWorld 的答案是:**模型归 A,但 A 把它"借"(lend)给 B**,这样 B 渲染时也能画到这条胳膊。

`Chunk` 内部有:

- **`lenders_`** —— "我借给别人的"列表,元素是 `Lender` 对象,记录借给哪个 chunk、借了哪些 item;
- **`borrowers_`** —— "我向谁借的"列表,记录借主 chunk 指针。

`Lender` 类是嵌套类:

```cpp
class Lender : public ReferenceCount
{
public:
    ~Lender();
    void releaseItems( Chunk * pOwner );
    Chunk * pLender_;   // 借主
    Items items_;       // 借出的项
};
typedef SmartPointer<Lender> LenderPtr;
```

`ChunkItemBase` 里也有对应的 `borrowers_` 集合和 `addBorrower`/`delBorrower` 方法。整个机制是双向的,卸载时要双向清理,所以 `Lender::~Lender` 里有断言:

```cpp
Chunk::Lender::~Lender()
{
    // 借出的项必须通过 releaseItems / delLoanItem 显式清理
    // 否则会因为 incref 不匹配导致内存泄漏
    MF_ASSERT( items_.empty() );
}
```

这种 Lend/Borrow 机制让"跨 chunk 大模型"成为可能,是 BigWorld 渲染连续性的关键之一。

---

## 14.5 空间加载流程

### 14.5.1 整体流程

把所有零件串起来,玩家走到一个新位置时,发生的事情是:

```
1. 客户端主循环每帧调用 ChunkManager::tick(dTime)
2. tick 检测玩家位置变化,如果移动超过阈值,触发 scan()
3. scan() 在玩家附近的网格内,逐圈向外找需要加载的 chunk
4. 对每个待加载 chunk:
   a. ChunkManager::loadChunk(chunk, priority)
   b. ChunkLoader::load(chunk, priority)
   c. FileIOTaskManager 提交 LoadChunkTask 到后台 IO 线程
5. 后台线程:LoadChunkTask::doBackgroundTask
   a. BWResource::openSection(chunk->resourceID())  读 .chunk
   b. BWResource::openSection(chunk->binFileName()) 读 .cdata
   c. chunk->load(pDS)  解析所有 ChunkItem
6. 加载完成,chunk 标记 loaded_=true
7. 主线程下一帧:ChunkManager::checkLoadingChunks 检测到 loaded
   a. 调用 chunk->appointAsAuthoritative()  让 space 接受它
   b. 调用 chunk->bind(true)  绑定 Portal
8. bind 过程中,如果 Portal 指向的邻居 chunk 没加载,触发邻居的加载(递归)
9. chunk 完成绑定,可被渲染遍历到
```

下面分步骤详细看。

### 14.5.2 种子 Chunk(Seed Chunk)

玩家第一次进入世界(或被传送到新位置)时,客户端不知道自己在哪个 chunk 里。这时要找"种子 chunk"——从玩家所在位置找到的第一个已加载 chunk。

`ChunkLoader::findSeed` 负责这件事:

```cpp
// chunk_loader.hpp
class FindSeedTask : public BackgroundTask
{
public:
    FindSeedTask( ChunkSpace * pSpace, const Vector3 & where );
    virtual void doBackgroundTask( TaskManager & mgr );
    virtual void doMainThreadTask( TaskManager & mgr );
    Chunk* foundSeed();
    // ...
};

class ChunkLoader
{
public:
    static void load( Chunk * pChunk, int priority = 0 );
    static void loadNow( Chunk * pChunk );
    static FindSeedTask* findSeed( ChunkSpace * pSpace, const Vector3 & where );
};
```

`findSeed` 也是后台任务,它会:

1. 在 `doBackgroundTask` 里调 `pSpace_->guessChunk(where_)`,猜出玩家可能在哪个 chunk;
2. 如果猜中了,加载该 chunk;
3. 切回主线程(`doMainThreadTask`)通知完成。

种子 chunk 加载完成后,后续的 chunk 都可以通过 Portal 关系"爬"着加载,不需要再 guess。

### 14.5.3 ChunkLoader 异步加载

`ChunkLoader::load` 是入口:

```cpp
// chunk_loader.cpp
void ChunkLoader::load( Chunk * pChunk, int priority )
{
    MF_ASSERT( !pChunk->loading() );
    pChunk->loading( true );

    FileIOTaskManager::instance().addBackgroundTask(
        new LoadChunkTask( pChunk ),
        priority );
}
```

注意它用的是 **`FileIOTaskManager`** 而不是普通的 `BgTaskManager`——这是因为 chunk 加载主要是磁盘 IO,放专门的 IO 线程池里不会阻塞计算任务。

`LoadChunkTask::doBackgroundTask` 干的活很简单:

```cpp
// chunk_loader.cpp
virtual void doBackgroundTask( TaskManager & mgr )
{
    load( pChunk_ );
}

static void load( Chunk * pChunk )
{
    DataSectionPtr pDS = BWResource::openSection( pChunk->resourceID() );
    DataSectionPtr pCData = BWResource::openSection( pChunk->binFileName() );
    pChunk->load( pDS );
    TRACE_MSG( "ChunkLoader: Loaded chunk '%s'\n", pChunk->resourceID().c_str() );
}
```

注意:后台线程**只负责把数据读进内存、构造 ChunkItem 对象**。所有需要访问主线程资源的操作(如创建 GPU 资源、注册到渲染器)都推迟到主线程的 `syncInit` 里做。

还有一个 `loadNow` 用于同步加载(阻塞主线程直到加载完),主要用于编辑器或切场景时:

```cpp
void ChunkLoader::loadNow( Chunk * pChunk )
{
    MF_ASSERT( !pChunk->loading() );
    pChunk->loading( true );
    LoadChunkTask::load( pChunk );  // 直接在主线程加载
}
```

### 14.5.4 Chunk::load 解析

`Chunk::load` 在后台线程被调用,负责把 `DataSection` 解析成具体的 ChunkItem:

```cpp
// chunk.cpp 简化
bool Chunk::load( DataSectionPtr pSection )
{
    MF_ASSERT_DEV( !loaded_ );

    if (!pSection) {  // 文件不存在
        // 给个最小包围盒,标记 loaded 但什么也没有
        localBB_ = BoundingBox( Vector3(0,0,0), Vector3(1,1,1) );
        boundingBox_ = localBB_;
        boundingBox_.transformBy( transform_ );
        loaded_ = true;
        return false;
    }

    bool good = true;
    // 1. 读 transform 和 boundingBox
    // 2. 调用 loadInclude 递归处理 <include>
    // 3. formBoundaries 构造 bounds_ 和 joints_
    // 4. 遍历所有子节点,对每个调用 loadItem
    //    loadItem 内部用工厂模式创建对应 ChunkItem
    // 5. 标记 loaded_ = true
    return good;
}
```

`loadItem` 是工厂模式的核心入口:

```cpp
// chunk.hpp
ChunkItemFactory::Result loadItem( DataSectionPtr pSection );
static ChunkItemFactory::Result loadItem(
    DataSectionPtr pSection, Chunk * chunk );
```

它会根据子节点的 section name(如 `"model"`、`"light"`、`"terrain"`),在全局工厂表 `pFactories_` 里查找对应的工厂,调用工厂的 `create` 方法。工厂机制细节见 14.6 节。

### 14.5.5 bind:绑定与 Portal 连接

`bind` 在主线程被调用(因为要动主线程资源)。前面 14.4.2 已展示过它的代码,关键三步:

1. **`syncInit()`**——给 ChunkItem 机会创建 GPU 资源(如 SuperModel、Umbra Object);
2. **`bindPortals(shouldFormPortalConnections)`**——遍历所有 `unboundPortals_`,把它们指向的相邻 chunk 找出来,移到 `boundPortals_`;
3. **`notifyCachesOfBind(false)`**——通知挂在 chunk 上的 `ChunkCache`(如灯光缓存),让它知道 chunk 已绑定。

`bindPortals` 是 Portal 系统的核心,14.7 节细讲。

### 14.5.6 卸载(unload)

玩家走远后,chunk 应该被卸载释放内存。`ChunkManager::scan` 会维护一个"路径和(pathSum)"——chunk 离玩家的最短路径长度。当某个 chunk 的路径和超过 `minUnloadPath_` 阈值,它就被标记可卸载。

```cpp
// chunk.hpp
void unload();
```

`unload` 会:

1. 先 `unbind(false)` 断开所有 Portal 连接;
2. 删除所有 `selfItems_`(触发 ChunkItem 析构,释放 GPU 资源);
3. 清空 `bounds_` 和 `joints_`;
4. 标记 `loaded_ = false`,可重新加载。

注意 `Chunk` 对象本身**不会**被销毁,它只是回到"空"状态,留着下次再用。这是出于性能考虑——`Chunk` 对象是个有点分量的对象(有 Matrix、BoundingBox、各种 mutex),反复 new/delete 不划算。

### 14.5.7 ChunkManager 的扫描与边界检查

`ChunkManager::tick` 是每帧入口:

```cpp
// chunk_manager.cpp
void ChunkManager::tick( float dTime )
{
    ++tickMark_;
    totalTickTimeInMS_ += uint64(dTime * 1000.f);
    dTime_ = dTime;

    // 重置统计
    s_chunksTraversed = 0;
    s_chunksVisible   = 0;
    // ...

    if (!initted_) return;

    updateTiming();  // 加载计时状态机
    // 处理 pendingChunkPtrs_:后台加载完成的 chunk 加入 space

    // 检查相机是否跨过 chunk 边界
    if (cameraChunk_ && cameraChunk_->isBound()) {
        checkCameraBoundaries();
    }

    // scan 检查需要加载/卸载哪些 chunk
    if (scanEnabled_ && !busy()) {
        scan();
    }

    // 给所有 chunk 机会 tick 自己的 item
    // ...
}
```

`checkCameraBoundaries` 检查相机是否穿过当前 chunk 的 Portal 进入了相邻 chunk:

```cpp
// chunk_manager.cpp
void ChunkManager::checkCameraBoundaries()
{
    Matrix localCamera = cameraChunk_->transformInverse();
    localCamera.preMultiply( cameraTrans_ );

    ChunkBoundaries& cb = cameraChunk_->bounds();
    for (size_t i = 0; i < cb.size(); i++) {
        for (uint32 j = 0; j < cb[i]->boundPortals_.size(); j++) {
            ChunkBoundary::Portal* p = cb[i]->boundPortals_[j];
            if (p->hasChunk() && !(p->pChunk->isOutsideChunk()
                && cameraChunk_->isOutsideChunk())) {
                // 如果相机位置在 Portal 的另一侧
                //  说明玩家进入了 p->pChunk
                //  更新 cameraChunk_ = p->pChunk
            }
        }
    }
}
```

注意"室外 chunk 之间不做 Portal 切换"的优化:室外 chunk 是大网格,玩家在哪个网格就用网格坐标算,不需要走 Portal。

`scan` 则是真正决定"加载哪些 chunk"的地方:

```cpp
// chunk_manager.cpp
bool ChunkManager::scan()
{
    // 1. 计算玩家网格附近的候选 chunk 列表(按距离排序)
    // 2. 对每个候选 chunk:
    //    a. 如果未加载且在 maxLoadPath_ 内 → loadChunk
    //    b. 如果已加载且路径和 > minUnloadPath_ → 标记可卸载
    // 3. 处理 maxUnloadChunks_ 限制(每帧最多卸载几个,避免卡顿)
}
```

`maxLoadPath_` / `minUnloadPath_` 是关键阈值:

- `maxLoadPath_`:超过这个路径距离的 chunk 不主动加载(默认约 750m);
- `minUnloadPath_`:超过这个路径距离才允许卸载(默认约 1000m,比 maxLoadPath 大,留出 hysteresis 避免来回加载/卸载)。

可通过 `autoSetPathPaths(farPlane)` 让阈值自动跟着相机远裁剪面走。

---

## 14.6 Chunk 项系统

### 14.6.1 ChunkItem 基类与 WantFlags

`ChunkItemBase`(在 `chunk_item.hpp`)是所有"住在 chunk 里的东西"的基类:

```cpp
class ChunkItemBase : private SafeReferenceCount
{
public:
    enum WantFlags
    {
        WANTS_NOTHING  = 0,
        WANTS_DRAW     = 1 << 0,   // 想被 draw
        WANTS_TICK     = 1 << 1,   // 想每帧 tick
        WANTS_UPDATE   = 1 << 2,   // 想被 updateAnimations
        WANTS_SWAY     = 1 << 3,   // 想响应风吹(草、树)
        WANTS_NEST     = 1 << 4,   // 想被 nest(放到 space)
        FORCE_32_BIT   = 1 << 31
    };

    explicit ChunkItemBase( WantFlags wantFlags = WANTS_NOTHING );

    // 关键虚函数,子类按需重写
    virtual void toss( Chunk * pChunk );            // 加入/离开 chunk
    virtual void draw( Moo::DrawContext& drawContext ) { }
    virtual void tick( float /*dTime*/ ) { }
    virtual void sway( const Vector3 & src, const Vector3 & dst,
        const float /*radius*/ ) { }
    virtual void lend( Chunk * /*pLender*/ ) { }
    virtual void nest( ChunkSpace * /*pSpace*/ ) { }

    virtual void syncInit() {}  // 主线程同步初始化

    // 引用计数(可与 PyObjectPlus 共存)
    virtual void incRef() const;
    virtual void decRef() const;
    virtual int refCount() const;

    Chunk * chunk() const { return pChunk_; }
    void chunk( Chunk * pChunk ) { pChunk_ = pChunk; }

    bool wantsDraw() const { return !!(wantFlags_ & WANTS_DRAW); }
    // ...
};
```

几个关键设计:

**WantFlags 标志位**

每个 item 在构造时声明自己"想要"什么——想 draw?想 tick?想 sway?这些标志位让 `ChunkManager` 知道该 item 需要被纳入哪些遍历列表。比如:

- 静态模型 `WANTS_DRAW`(要画);
- 粒子 `WANTS_DRAW | WANTS_TICK`(要画且要更新);
- 草 `WANTS_DRAW | WANTS_SWAY`(要画且响应风);
- 灯光默认 `WANTS_NOTHING`(灯光通过 ChunkLightCache 单独管理)。

**`toss(Chunk*)` —— "扔进 chunk"**

`toss` 是个有点卖萌的名字,实际就是"把这个 item 放到某个 chunk 里"。它会在 item 加入/离开 chunk 时被调用,子类重写它来注册/注销到渲染器、碰撞系统等。

```cpp
// chunk_item.hpp
virtual void toss( Chunk * pChunk ) { this->chunk( pChunk ); }
```

基类版本只是改 `pChunk_` 指针;子类版本会做更多(如 ChunkModel::toss 会把模型注册到 SuperModelCache)。

**`syncInit()` —— 主线程同步初始化**

后台线程加载 chunk 时,只能构造对象、读数据;不能动 GPU。`syncInit` 是 chunk 被 `bind` 时(主线程)给 item 一个机会创建 GPU 资源。比如 ChunkTree 会在 syncInit 里创建 SpeedTree renderer。

### 14.6.2 工厂模式:DECLARE/IMPLEMENT_CHUNK_ITEM 宏

BigWorld 用宏实现了一套"自注册工厂"模式。每个 ChunkItem 子类声明时写:

```cpp
class ChunkModel : public ChunkItem, public ReloadListener
{
    DECLARE_CHUNK_ITEM( ChunkModel )
    DECLARE_CHUNK_ITEM_ALIAS( ChunkModel, shell )
    // ...
};
```

`DECLARE_CHUNK_ITEM` 展开成:

```cpp
// chunk_item.hpp
#define DECLARE_CHUNK_ITEM( CLASS )
    static ChunkItemFactory::Result create( Chunk * pChunk,
        DataSectionPtr pSection );
    static ChunkItemFactory factory_;
```

也就是声明一个静态 `factory_` 成员和一个静态 `create` 方法。

`cpp` 文件里用 `IMPLEMENT_CHUNK_ITEM` 实例化工厂:

```cpp
// chunk_model.cpp
IMPLEMENT_CHUNK_ITEM( ChunkModel, model, 0 )
// 等价于:
//   ChunkItemFactory ChunkModel::factory_( "model", 0, ChunkModel::create );
//   ChunkItemFactory::Result ChunkModel::create(Chunk* pChunk, DataSectionPtr pSection) {
//       SmartPointer<ChunkModel> pItem = new ChunkModel();
//       BW::string errorString;
//       if (pItem->load(pSection)) {
//           pChunk->addStaticItem(pItem);
//           return ChunkItemFactory::Result(pItem);
//       }
//       return ChunkItemFactory::Result(NULL, errorString);
//   }
```

关键是 `ChunkItemFactory` 构造函数会把自身注册到全局表:

```cpp
// chunk_item.cpp(概念)
ChunkItemFactory::ChunkItemFactory( const BW::string & section,
    int priority, Creator creator )
    : priority_( priority ), creator_( creator )
{
    Chunk::registerFactory( section, *this );  // 注册到全局 pFactories_
}
```

这样当 `Chunk::load` 遍历 `.chunk` 文件子节点时,看到 `<model>` 节点,就去 `pFactories_["model"]` 找到 `ChunkModel::factory_`,调用它的 `create`,得到一个 `ChunkModel` 实例并加入 `selfItems_`。

整个流程是**完全解耦**的:`Chunk` 类不需要知道有几种 ChunkItem,新增 ChunkItem 类型不需要改 Chunk 类代码——只要在某个 cpp 里 `IMPLEMENT_CHUNK_ITEM` 就行。

`DECLARE_CHUNK_ITEM_ALIAS(ChunkModel, shell)` 是给同一个类注册第二个标签——`<shell>` 节点也用 `ChunkModel` 工厂处理(shell 是室内 chunk 的外壳模型,本质就是个 model)。

### 14.6.3 典型子类

`lib/chunk/` 下有几十种 ChunkItem,常用的有:

| 类名 | XML 标签 | 文件 | 职责 |
|------|---------|------|------|
| `ChunkModel` | `<model>` / `<shell>` | `chunk_model.hpp` | 静态模型(墙、家具等) |
| `ChunkTerrain` | `<terrain>` | `chunk_terrain.hpp` | 地形块(室外 chunk 必有) |
| `ChunkTree` | `<tree>` | `chunk_tree.hpp` | SpeedTree 树 |
| `ChunkWater` | `<water>` | `chunk_water.hpp` | 水面 |
| `ChunkFlora` | `<flora>` | `chunk_flora.hpp` | 草丛 |
| `ChunkOmniLight` | `<light type=Omni>` | `chunk_light.hpp` | 点光源 |
| `ChunkSpotLight` | `<light type=Spot>` | `chunk_light.hpp` | 聚光灯 |
| `ChunkDirectionalLight` | `<light type=Directional>` | `chunk_light.hpp` | 方向光(太阳) |
| `ChunkAmbientLight` | `<light type=Ambient>` | `chunk_light.hpp` | 环境光 |
| `ChunkMarker` | `<marker>` | `chunk_marker.hpp` | 标记点(给脚本用) |
| `ChunkExitPortal` | (内部生成) | `chunk_exit_portal.hpp` | 室内 chunk 的天空出口 |
| `ChunkVLO` | `<vlo>` | `chunk_vlo.hpp` | VLO 引用(见 14.8) |

举 `ChunkLight` 的类层次看一下设计:

```cpp
// chunk_light.hpp
class ChunkLight : public ChunkItem {
    virtual const Moo::Colour & colour() const = 0;
    virtual void addToCache( ChunkLightCache& cache ) const = 0;
    virtual void addToContainer( Moo::LightContainerPtr pLC ) const = 0;
    virtual void delFromContainer( Moo::LightContainerPtr pLC ) const = 0;
    virtual void updateLight( const Matrix& world ) const = 0;
};

class ChunkMooLight : public ChunkLight { /* 共享 Moo 集成 */ };
class ChunkOmniLight : public ChunkMooLight { DECLARE_CHUNK_ITEM(ChunkOmniLight) ... };
class ChunkSpotLight : public ChunkMooLight { DECLARE_CHUNK_ITEM(ChunkSpotLight) ... };
class ChunkDirectionalLight : public ChunkMooLight { DECLARE_CHUNK_ITEM(ChunkDirectionalLight) ... };
class ChunkAmbientLight : public ChunkLight { DECLARE_CHUNK_ITEM(ChunkAmbientLight) ... };
```

灯光不直接 draw 自己,而是把自己 `addToContainer` 到 chunk 的 `Moo::LightContainer`,Moo 渲染时统一应用。这种"chunk item 不直接画,而是把数据塞给渲染器"的设计在 BigWorld 里很常见。

### 14.6.4 toss:加入/离开 chunk

`toss(Chunk*)` 是 chunk item 生命周期中最常被调用的方法之一。当 item 被加进 chunk(或从 chunk 移走)时调用:

```cpp
// chunk_model.hpp
virtual void toss( Chunk * pChunk );
```

子类典型实现会做这些事:

1. **如果新 chunk 不为空**:
   - 调用基类 `toss` 设置 `pChunk_`;
   - 把自己注册到渲染器(如 SuperModelCache);
   - 加入碰撞场景(如果支持碰撞);
   - 调用 `lend` 把跨界部分借给邻居 chunk。
2. **如果新 chunk 为空(被移除)**:
   - 从渲染器注销;
   - 从碰撞场景移除;
   - 通知所有 borrowers 不再借。

`ChunkModel::toss` 比较复杂,因为它要处理 SuperModel 重载监听、BSP 模型等。`ChunkTerrain::toss` 简单些,主要是把地形块注册到 `Terrain::BaseTerrainBlock`。

---

## 14.7 Portal 系统

### 14.7.1 ChunkBoundary 与 Portal

Portal 系统的源码在 `chunk_boundary.hpp`。先看类结构:

```cpp
struct ChunkBoundary : public ReferenceCount
{
    PlaneEq plane_;                  // 这个边界的平面方程
    Portals boundPortals_;          // 已绑定的 Portal(目标 chunk 已加载)
    Portals unboundPortals_;        // 未绑定的 Portal(目标 chunk 还没加载)
};

typedef BW::vector<ChunkBoundaryPtr> ChunkBoundaries;

struct ChunkBoundary::Portal
{
    bool            internal;       // 内部 portal(逻辑减法)
    bool            permissive;     // 允许物体穿过
    Chunk           * pChunk;       // 通向哪个 chunk(或特殊值 HEAVEN/EARTH/...)
    V2Vector        points;         // portal 多边形顶点(2D)
    Vector3         uAxis, vAxis;   // 局部坐标轴
    Vector3         origin;         // 局部原点
    Vector3         lcentre;        // 局部中心
    Vector3         centre;         // 世界中心
    PlaneEq         plane;          // 与所在 boundary 同
    BW::string      label;

    enum { NOTHING=0, HEAVEN=1, EARTH=2, INVASIVE=3, EXTERN=4, LAST_SPECIAL=15 };
};
```

理解 Portal:

- **`ChunkBoundary`** 是 chunk 的一个面(凸包的一面),包含一个平面方程;
- **`Portal`** 是 boundary 上的一个"洞"——一个多边形(2D,在 boundary 平面内),通向另一个 chunk;
- 一个 boundary 可以有多个 portal(如同一面墙上开两扇门);
- portal 通过 `pChunk` 指针指向目标 chunk;未绑定时 `pChunk` 可能为 NULL 或特殊值。

`Chunk` 持有两个 `ChunkBoundaries` 集合:

```cpp
// chunk.hpp
ChunkBoundaries bounds_;   // 物理边界(凸包的各个面)
ChunkBoundaries joints_;   // 逻辑连接(Portal 实际所在)
```

`bounds_` 是 chunk 真正的物理外壳——决定一个点是否在这个 chunk 内。`joints_` 是 portal 所在的"接缝"——可能是 bounds_ 的一部分,也可能是内部的(invasive portal)。平时迭代 portal 主要用 `joints_`,所以 `Chunk` 提供了 `pbegin()/pend()` 简化遍历:

```cpp
// chunk.hpp
piterator pbegin() { return piterator( joints_, false ); }
piterator pend()   { return piterator( joints_, true ); }
```

### 14.7.2 Portal 的种类

`pChunk` 字段有几个特殊值,代表不同种类的"伪 portal":

| 特殊值 | 含义 | 用途 |
|--------|------|------|
| `HEAVEN` | 通向天空 | 室外 chunk 顶面,看天空盒/太阳/云 |
| `EARTH` | 通向大地 | 室外 chunk 底面(很少用) |
| `INVASIVE` | 入侵 portal | 内部 chunk 侵入自己的体积(用于"内室嵌入") |
| `EXTERN` | 外部 portal | 指向"另一个 mapping"(用于跨空间映射) |
| 普通 `Chunk*` | 真实邻居 | 通向另一个已加载的 chunk |

`isHeaven()` / `isEarth()` 等判断方法用 `uintptr` 比较实现:

```cpp
// chunk_boundary.hpp
bool isHeaven() const
    { return uintptr(pChunk) == uintptr(HEAVEN); }
bool hasChunk() const
    { return uintptr( pChunk ) > uintptr( LAST_SPECIAL ); }
```

### 14.7.3 Portal 绑定过程

`Chunk::bindPortals` 遍历所有 `unboundPortals_`,把它们转成 `boundPortals_`:

```cpp
// chunk.cpp 简化
void Chunk::bindPortals( bool shouldFormPortalConnections, bool shouldNotifyCaches )
{
    for (uint jindex = 0; jindex < joints_.size(); ++jindex)
    {
        ChunkBoundaryPtr ourBoundary = joints_[ jindex ];

        for (uint unboundPortalIndex = 0;
            unboundPortalIndex < ourBoundary->unboundPortals_.size();
            unboundPortalIndex++)
        {
            ChunkBoundary::Portal *& pPortal =
                ourBoundary->unboundPortals_[ unboundPortalIndex ];
            ChunkBoundary::Portal & unboundPortal = *pPortal;

            // 1. HEAVEN portal:室内 chunk 创建 ExitPortal
            if (unboundPortal.isHeaven()) {
                if (!this->isOutsideChunk_) {
                    SmartPointer<ChunkExitPortal> pExitPortal =
                        new ChunkExitPortal(unboundPortal);
                    this->addStaticItem( pExitPortal.get() );
                }
                ourBoundary->bindPortal( unboundPortalIndex-- );
                continue;
            }

            // 2. 处理 condemned mapping(已废弃的 mapping)
            if (unboundPortal.hasChunk() &&
                unboundPortal.pChunk->mapping()->condemned()) {
                // 释放旧 chunk,重新尝试 resolveExtern
                delete unboundPortal.pChunk;
                unboundPortal.pChunk = (Chunk*)ChunkBoundary::Portal::EXTERN;
            }

            // 3. EXTERN portal:尝试在所有 mapping 里找
            if (unboundPortal.isExtern()) {
                unboundPortal.resolveExtern( this );
            }

            // 4. 如果还没有目标 chunk
            if (!unboundPortal.hasChunk()) {
                if (!shouldFormPortalConnections) continue;

                // 在 portal 中心点附近找 chunk
                Vector3 conPt = transform_.applyPoint(
                    unboundPortal.lcentre + unboundPortal.plane.normal() * -0.001f );
                Chunk * pFound = NULL;
                ChunkSpace::Column * pCol = pSpace_->column( conPt, false );
                if (pCol != NULL) {
                    pFound = pCol->findChunk( conPt );
                }
                if (pFound == NULL || pFound == this) continue;

                unboundPortal.pChunk = pFound;
            }

            // 5. 递归 formPortal,连接两边
            if (this->formPortal( unboundPortal.pChunk, unboundPortal )) {
                ourBoundary->bindPortal( unboundPortalIndex-- );
            }
        }
    }
}
```

关键点:

- **HEAVEN/EARTH portal 不需要找目标**,直接 bind;
- **EXTERN portal** 跨 mapping,需要 `resolveExtern` 在所有 mapping 里找;
- 普通未绑定 portal 通过 **"在 portal 中心点附近找 chunk"** 确定目标——这是 BigWorld 的聪明设计:portal 不写死目标 chunk 名,而是按几何位置找,这样改名/重组都不会断;
- 找到目标后调 `formPortal`,它会把两个 chunk 的 portal 配对;
- `bindPortal(unboundPortalIndex--)` 把 portal 从 unbound 列表移到 bound 列表(自减是为了不跳过下一个)。

### 14.7.4 跨 Portal 渲染与视锥剔除

Portal 系统最大的价值在渲染时的视锥剔除:不画看不到的 chunk。

`ChunkManager::draw` 是渲染入口:

```cpp
// chunk_manager.cpp
void ChunkManager::draw( Moo::DrawContext& drawContext )
{
    ++ChunkManager::s_drawPass;
    ChunkExitPortal::seenExitPortals().clear();

    if (cameraChunk_ == NULL || !cameraChunk_->isBound()) return;

    // 1. 从 cameraChunk_ 开始
    // 2. 用相机视锥对当前 chunk 的所有 portal 做裁剪
    // 3. 通过的 portal → 进入相邻 chunk,递归
    // 4. 每个 visited chunk 加入可见列表
    // 5. 可见 chunk 的所有 selfItems_/lenders_ 调用 draw
}
```

`ChunkBoundary::Portal::traverse` 是核心裁剪函数:

```cpp
// chunk_boundary.hpp
Portal2DRef traverse(
    const Matrix & world,
    const Matrix & worldInverse,
    Portal2DRef pClipPortal,
    const TraversalData& traversalData,
    float* nearDepth = NULL) const;
```

它做的事:

1. 把这个 portal 的多边形从 chunk 局部坐标变换到世界坐标;
2. 用相机视锥裁剪这个多边形,得到屏幕上的可见区域(`Portal2D`);
3. 与父级 clip portal 求交集——只有同时落在父 portal 可见区域和当前 portal 多边形内的部分才继续;
4. 返回新的 `Portal2DRef`,作为相邻 chunk 的 clip portal。

这样递归下去,**只有 portal 与相机视锥交集内的 chunk 才会被画**,大幅减少 draw call。特别是室内场景:一个走廊里有 100 个房间,但玩家只能看到眼前 3 个房间的门,那只有这 3 个房间的 chunk 被画,其他 97 个都剔除掉。

室外 chunk 之间不做 portal 裁剪(因为网格大,通常用距离剔除 + Umbra 遮挡剔除就够),只有"室外→室内"或"室内→室内"才走 portal。

### 14.7.5 Invasive Portal:内部 chunk 嵌入

`internal` 标志的 portal 比较特殊。`chunk format.txt` 注释:

> An 'internal' portal means that the specified boundary is not a boundary,
> but rather that the space occupied by the chunk it connects to (and all
> chunks that that chunk connects to) should be logically subtracted from
> the space owned by this chunk.

简单说:**invasive portal 把目标 chunk 的体积从自己这里"挖掉"**。典型场景:室外 chunk 里有一个房子的入口 portal,通向室内 chunk(房间);室内 chunk 的体积在室外 chunk 看来应该被"挖掉",否则玩家进房子后,室外 chunk 的地形会从房子地板下穿出来。

这就是"内室嵌入"——室内 chunk 像寄生虫一样挂在室外 chunk 上,但物理上是减法关系。

---

## 14.8 VLO(Very Large Object)

### 14.8.1 为什么需要 VLO

考虑一个场景:一条大河横跨 20 个 chunk。如果按普通 ChunkItem 处理:

- 每个 chunk 里都有"半截河"的 ChunkWater;
- 20 个 ChunkWater 之间要同步水位、波浪相位、流向;
- 加载时第 5 个 chunk 加载了但第 6 个还没加载,河就断了一截。

这种"跨多个 chunk 的大型连续对象"需要特殊处理。BigWorld 的方案是 **VLO(Very Large Object)**。

### 14.8.2 VeryLargeObject 与 ChunkVLO

VLO 系统在 `chunk_vlo.hpp`。两个核心类:

```cpp
// chunk_vlo.hpp
class VeryLargeObject : public SafeReferenceCount, public EditorChunkCommonLoadSave
{
public:
    typedef StringHashMap<VeryLargeObjectPtr> UniqueObjectList;
    typedef BW::list<ChunkVLO*> ChunkItemList;

    VeryLargeObject( BW::string uid, BW::string type );

    virtual void drawInChunk( Moo::DrawContext& drawContext, Chunk* pChunk ) = 0;
    virtual void lend( Chunk * pChunk ) {}
    virtual void unlend( Chunk * pChunk ) {}

    void addItem( ChunkVLO* item );
    void removeItem( ChunkVLO* item, bool destroy = false );
    ChunkVLO* containsChunk( const Chunk * pChunk ) const;

    static VeryLargeObjectPtr getObject( const BW::string& uid );

    BW::string getUID() const { return uid_; }
    BoundingBox& boundingBox() { return bb_; }

protected:
    static UniqueObjectList s_uniqueObjects_;   // 全局 UID → VLO 映射
    BW::string uid_;
    BW::string type_;
    BoundingBox bb_;
    ChunkItemList itemList_;   // 所有引用了本 VLO 的 ChunkVLO
};

class ChunkVLO : public ChunkItem
{
public:
    static ChunkItemFactory::Result create(
        ChunkVLO * pVLO, Chunk * pChunk, DataSectionPtr pSection );

    virtual void draw( Moo::DrawContext& drawContext );
    virtual void lend( Chunk * pChunk );
    virtual void toss( Chunk * pChunk );
    virtual bool load( DataSectionPtr pSection, Chunk * pChunk );

    VeryLargeObjectPtr object() const { return pObject_; }

protected:
    VeryLargeObjectPtr pObject_;   // 指向真正的 VLO(共享)
};
```

设计要点:

- **`VeryLargeObject`** 是真正的"大对象"(如整条河),全局唯一,通过 UID 标识,所有引用它的 chunk 共享同一份;
- **`ChunkVLO`** 是 chunk 里的"引用"——每个引用了 VLO 的 chunk 里有一个 `ChunkVLO` ChunkItem,但它们 `pObject_` 指向同一个 `VeryLargeObject`;
- **`s_uniqueObjects_`** 是全局静态映射,UID → VLO 指针。`getObject(uid)` 通过 UID 取共享对象,实现去重;
- **`addItem` / `removeItem`** 让 VLO 知道哪些 chunk 引用了自己;
- **`drawInChunk(drawContext, chunk)`** 是 VLO 的绘制接口——注意它带 chunk 参数,意味着 VLO 知道"我现在是为哪个 chunk 画的",可以只画该 chunk 内的部分。

### 14.8.3 加载与去重

加载流程:

1. Chunk 解析时遇到 `<vlo>` 节点,触发 `ChunkVLO::create`;
2. create 读取 VLO 的 UID 和类型;
3. 调 `VeryLargeObject::getObject(uid)` 查全局表——
   - 如果已有,直接用;
   - 如果没有,创建新的 VLO,加载它的资源(如 `.water` 文件),存入全局表;
4. 创建 `ChunkVLO` 实例,`pObject_` 指向共享 VLO;
5. VLO 调用 `addItem(this)` 把自己加入引用列表;
6. ChunkVLO 加入 chunk 的 selfItems_。

这样无论 VLO 跨多少个 chunk,真正的大对象只存在一份,所有 chunk 共享。

VLO 还有自己的 `tickAll(dTime)` 静态方法,每帧统一更新所有 VLO(避免每个 ChunkVLO 单独 tick 导致状态不一致):

```cpp
// chunk_vlo.hpp
static void tickAll( float dTime );
```

典型 VLO 子类:`ChunkWater`(水面)、大型粒子系统、长墙体等。

---

## 14.9 Chunk 链接系统

### 14.9.1 ChunkLink 类

`ChunkLink` 在 `chunk_link.hpp`,代表**两个 ChunkItem 之间的引用关系**:

```cpp
class ChunkLink : public ChunkItem
{
public:
    enum Direction
    {
        DIR_NONE      = 0,
        DIR_START_END = 1,   // 起点 → 终点
        DIR_END_START = 2,   // 终点 → 起点
        DIR_BOTH      = DIR_END_START | DIR_START_END  // 双向
    };

    ChunkLink();
    ~ChunkLink();

    ChunkItemPtr startItem() const;
    void startItem(ChunkItemPtr item);

    ChunkItemPtr endItem() const;
    void endItem(ChunkItemPtr item);

    Direction direction() const;
    void direction(Direction dir);

private:
    ChunkItemPtr    startItem_;
    ChunkItemPtr    endItem_;
    Direction       direction_;
};

typedef SmartPointer<ChunkLink> ChunkLinkPtr;
```

注意 `ChunkLink` 本身也是个 `ChunkItem`——它住在某个 chunk 里,但它引用(可能跨 chunk)另外两个 item。典型用途:

- 一个开关 item 控制一个门 item(开关 → 门);
- 一个触发器 item 触发一个脚本事件 item;
- 一个 patroller NPC 沿着 waypoint item 链移动。

`Direction` 字段表示方向性:`DIR_START_END` 单向(start 触发 end),`DIR_BOTH` 双向互动。

### 14.9.2 加载依赖

ChunkLink 引入了"加载依赖"问题:如果 link 的 endItem 在另一个还没加载的 chunk 里,这个 link 就暂时连不上。BigWorld 的处理方式:

1. 加载时记录 link 的目标(item 标识 + chunk 标识);
2. 当目标 chunk 也加载并 bind 时,resolve link,把 `endItem_` 指针填上;
3. 在此之前 link 处于"未连接"状态,使用方需要检查。

类似的依赖处理也出现在 Portal 系统(目标 chunk 没加载就先 unbound)和 VLO 系统(VLO 对象可能先于引用它的 chunk 创建)。

---

## 14.10 compiled_space 与 chunk_scene_adapter

前面讲的 `.chunk` 文件格式是 BigWorld 的**传统格式**——基于 XML 的 `DataSection`,人类可读但运行时解析慢。新版 BigWorld 引入了**编译后的二进制空间格式**,这就是 `lib/compiled_space/`。

### 14.10.1 chunk_scene_adapter 适配器

先看 `lib/chunk_scene_adapter/`,它是个薄薄的适配层。背景:

BigWorld 后期重构了"场景"系统,引入了新一代 `ClientSpace` / `Scene` / `SceneProvider` 抽象(在 `lib/space/`、`lib/scene/`)。老的 `ChunkSpace` 不直接实现这些接口,需要一个适配器。

`ClientChunkSpaceAdapter` 就是这个适配器:

```cpp
// client_chunk_space_adapter.hpp
class ClientChunkSpaceAdapter : public ClientSpace
{
public:
    ClientChunkSpaceAdapter( ChunkSpace * pChunkSpace );
    static ChunkSpacePtr getChunkSpace( const ClientSpacePtr& space );
    static ClientSpacePtr getSpace( const ChunkSpacePtr& space );
    static void init();

protected:
    virtual bool doAddMapping( GeometryMappingID mappingID,
        Matrix& transform, const BW::string & path,
        const SmartPointer< DataSection >& pSettings );
    virtual void doDelMapping( GeometryMappingID mappingID );

    virtual float doGetLoadStatus( float distance ) const;
    virtual AABB doGetBounds() const;
    virtual Vector3 doClampToBounds( const Vector3& position ) const;
    virtual float doCollide( const Vector3 & start, const Vector3 & end,
        CollisionCallback & cc ) const;
    virtual float doFindTerrainHeight( const Vector3 & position ) const;
    virtual void doClear();
    virtual EnviroMinder & doEnviro();
    virtual void doTick( float dTime );
    virtual void doUpdateAnimations( float dTime );
    // ... 各种 do* 方法
};
```

它把 `ChunkSpace` 的功能包装成新一代 `ClientSpace` 接口,业务代码统一用 `ClientSpace` 而不直接用 `ChunkSpace`。`init()` 还会注册 `ClientChunkSpaceFactory`:

```cpp
// client_chunk_space_adapter.hpp
class ClientChunkSpaceFactory : public IClientSpaceFactory
{
public:
    virtual ClientSpace * createSpace( SpaceID spaceID ) const;
    virtual IEntityEmbodimentPtr createEntityEmbodiment(
        const ScriptObject& object ) const;
    virtual IOmniLightEmbodiment * createOmniLightEmbodiment(
        const PyOmniLight & pyOmniLight ) const;
    virtual ISpotLightEmbodiment * createSpotLightEmbodiment(
        const PySpotLight & pySpotLight ) const;
};
```

这样 `SpaceManager` 创建空间时会自动用上适配器。`ClientChunkSpaceAdapter` 还内嵌一个 `SceneProvider`,把 chunk 系统的 Portal、阴影、相交查询等接入新 Scene 系统。

### 14.10.2 compiled_space 二进制空间

`lib/compiled_space/` 是新一代实现,完全绕过 `.chunk` 文件,直接用编译后的二进制格式。它的结构:

```
lib/compiled_space/
├── compiled_space.hpp/.cpp        # CompiledSpace,实现 ClientSpace
├── compiled_space_mapping.hpp/.cpp # 二进制 mapping
├── loader.hpp/.cpp                # ILoader 加载器接口
├── binary_format.hpp/.cpp         # 二进制文件格式
├── string_table.hpp/.cpp          # 字符串表(用 ID 替代字符串)
│
├── 各种 SceneProvider
│   ├── static_scene_provider.hpp/.cpp       # 静态几何
│   ├── light_scene_provider.hpp/.cpp         # 灯光
│   ├── terrain2_scene_provider.hpp/.cpp       # 地形
│   ├── static_scene_water.hpp/.cpp            # 水面
│   ├── static_scene_speed_tree.hpp/.cpp       # 树
│   ├── static_scene_decal.hpp/.cpp            # 贴花
│   ├── static_scene_flare.hpp/.cpp            # 光晕
│   ├── static_texture_streaming_scene_provider.hpp/.cpp  # 纹理流送
│   └── cached_semi_dynamic_shadow_scene_provider.hpp/.cpp # 半动态阴影
│
├── binary_writers/  (编译期工具)
│   ├── space_writer.hpp/.cpp           # 空间总写入器
│   ├── static_scene_writer.hpp/.cpp     # 静态场景写入器
│   ├── chunk_converter.hpp/.cpp        # 把 .chunk 转换成二进制
│   ├── terrain2_writer.hpp/.cpp         # 地形写入器
│   └── ...
│
└── unit_test/  (单元测试)
```

**二进制格式的优势**:

1. **加载快**——直接 mmap 文件,不需要解析 XML;
2. **体积小**——字符串去重(StringTable)、数据紧凑布局;
3. **缓存友好**——按类型分组(static geometry、light、terrain 各一组),渲染时遍历连续内存;
4. **支持流送**——可以按需加载场景的某一部分,粒度比 chunk 更细。

`ILoader` 是加载器接口:

```cpp
// loader.hpp
class ILoader
{
public:
    bool loadFromSpace( ClientSpace * pSpace,
        BinaryFormat& reader,
        const DataSectionPtr& pSpaceSettings,
        const Matrix& mappingTransform,
        const StringTable& stringTable );
    bool bind();
    void unload();
    float loadStatus() const;

protected:
    virtual float percentLoaded() const = 0;
    virtual bool doLoadFromSpace(...) = 0;
    virtual bool doBind();
    virtual void doUnload() = 0;

private:
    enum LoadStatus { UNLOADED=0, LOADING, LOADED, FAILED };
    mutable LoadStatus loadStatus_;
};
```

每个 SceneProvider(StaticGeometry、LightScene、Terrain2Scene...)都是一个 `ILoader`,各自负责从二进制流加载自己的数据。`chunk_converter.hpp` 是工具链的桥梁,负责把老的 `.chunk` 文件转成新的二进制格式。

### 14.10.3 chunk_loading 边界映射

`lib/chunk_loading/` 这个小库主要给服务器用。服务器启动时需要把**整个空间**一次性加载(用于物理碰撞、导航生成、AOI 索引等),不能像客户端那样只加载玩家附近的。`PreloadedChunkSpace` 就是干这个的:

```cpp
// preloaded_chunk_space.hpp
class PreloadedChunkSpace
{
public:
    PreloadedChunkSpace( BW::Matrix m, const BW::string & path,
            const SpaceEntryID & entryID, SpaceID spaceID,
            GeometryMapper & mapper );
    void chunkTick();   // 每 tick 增量加载若干 chunk
    void prepareNewlyLoadedChunksForDelete();
    ChunkSpacePtr pChunkSpace() const { return pChunkSpace_; }
private:
    ChunkSpacePtr pChunkSpace_;
    EdgeGeometryMappings geometryMappings_;
    SpaceEntryID entryID_;
};
```

`chunkTick()` 每 tick 加载一批 chunk,而不是一次性全加载(避免卡服务器启动)。它用 `EdgeGeometryMappings` 管理"边界 mapping"——即空间的边缘部分,这些部分可能要叠加多个 mapping(比如一个基础地图 + 一个补丁)。

`LoadColumn`、`LoadEdge` 这些类管理加载过程中的网格状态:哪些列已加载、哪些边缘还没处理。这套机制确保服务器能在不阻塞启动的前提下,逐步把整个空间"灌"进内存。

---

## 14.11 特色实现深度剖析

### 14.11.1 流式加载的性能优势

为什么 BigWorld 要费力做 Chunk 系统?算笔账:

假设一个 MMO 世界 10km × 10km,每平方米几何数据约 1KB,总共 100GB。这显然不可能全加载。但用 chunk 切分:

- 每格 100m,共 10000 个 chunk;
- 每个 chunk 平均 10MB,共 100GB(同上);
- 玩家附近只需加载 5×5 = 25 个 chunk = 250MB(可接受);
- 配合视锥剔除,实际可见的更少。

所以 chunk 是把"无限大世界"塞进"有限显存"的唯一办法。BigWorld 还做了几个性能优化:

**1. 后台 IO 线程**

`ChunkLoader` 用 `FileIOTaskManager`(专门的文件 IO 线程池),不阻塞主线程也不阻塞计算线程:

```cpp
// chunk_loader.cpp
FileIOTaskManager::instance().addBackgroundTask(
    new LoadChunkTask( pChunk ),
    priority );
```

主线程继续渲染,后台慢慢加载,加载完再切回主线程做 bind。

**2. 优先级**

`ChunkLoader::load(chunk, priority)` 的 priority 参数让"玩家正前方"的 chunk 比"侧面"的优先加载,玩家几乎察觉不到加载过程:

```cpp
// chunk_loader.hpp
static void load( Chunk * pChunk, int priority = 0 );
```

`priority` 越小越先加载。`scan()` 在排序候选 chunk 时,会把玩家正前方的 priority 设低,身后的设高。

**3. Hysteresis 卸载**

`maxLoadPath_` 比 `minUnloadPath_` 小(默认 750m vs 1000m),这意味着:chunk 在玩家 750m 内会被加载,要走到 1000m 外才卸载。中间留出 250m 缓冲,玩家来回走动时不会反复加载/卸载(否则会产生严重的卡顿)。

**4. Chunk 对象复用**

`unload` 不销毁 `Chunk` 对象,只清空内容。下次加载同一 chunk 时直接复用对象,省 new/delete 开销。

### 14.11.2 Portal 渲染优化

Portal 系统的渲染优化原理:

```
玩家在房间 A,通过门 P1 看到 走廊 B,再通过门 P2 看到 房间 C。
玩家视锥只覆盖 P1 的一部分。
→ 走廊 B 的可见区域 = P1 ∩ 视锥,可能只占 B 的一小块
→ 房间 C 的可见区域 = P2 ∩ (P1 ∩ 视锥),更小
→ 房间 D 的门 P3 不在 P2 ∩ 视锥里 → 不画 D
```

代码上,`ChunkBoundary::Portal::traverse` 做的就是这个递归裁剪。每经过一个 portal,可见区域 `Portal2D` 会被父 portal 多边形进一步收窄:

```cpp
// chunk_boundary.hpp
Portal2DRef traverse(
    const Matrix & world,
    const Matrix & worldInverse,
    Portal2DRef pClipPortal,           // 父 portal 的可见区域
    const TraversalData& traversalData,
    float* nearDepth = NULL) const;
```

效果:在密集室内场景,Portal 剔除可以减少 90% 以上的 draw call。这正是为什么 BigWorld 的室内关卡可以做得非常复杂(几千个房间)而不掉帧。

**Heaven Portal 与天空**

室外 chunk 顶面的 HEAVEN portal 不通向任何 chunk,而是告诉渲染系统"这里可以看到天空"。`ChunkManager::draw` 在遍历可见 chunk 时,如果遇到 HEAVEN portal,就标记"这一帧需要画天空盒";天空盒在所有 chunk 之后画,确保深度正确。

`canSeeHeaven()` 方法检查 chunk 是否有任何已绑定的 heaven portal:

```cpp
// chunk.hpp
bool canSeeHeaven();
```

如果 chunk 完全被屋顶盖住(没有 heaven portal),就不会画天空,节省一次 fullscreen pass。

### 14.11.3 Chunk 项的解耦设计

`ChunkItem` 的工厂模式让 chunk 系统与具体 item 类型完全解耦:

```
Chunk::load 遍历 DataSection
     ↓
查 pFactories_[sectionName]
     ↓
调用 factory.create(chunk, section)
     ↓
创建具体 ChunkItem 子类实例
     ↓
chunk->addStaticItem(item)
```

这意味着:

- **新增 ChunkItem 类型**不需要改 `Chunk` 类——只要在某个 cpp 里 `IMPLEMENT_CHUNK_ITEM` 就行;
- **服务器/客户端/编辑器**可以共用同一套加载逻辑,只是注册的工厂不同(如 `ServerChunkModel` 替代 `ChunkModel`);
- **条件编译**(`#ifdef EDITOR_ENABLED`)让编辑器有更多 ChunkItem 类型(如 `EditorChunkItem` 子类)而不影响客户端。

`#ifdef MF_SERVER` 的处理也很有意思:服务器不需要画模型,但有 `ServerChunkModel` 替代,只保留碰撞、LOD 信息:

```cpp
// chunk.cpp
#ifdef MF_SERVER
#include "server_chunk_model.hpp"
#else
#include "chunk_model.hpp"
#endif
```

同一个 `<model>` 标签,客户端和服务器用不同工厂处理,产出不同类型的对象。

### 14.11.4 Lend/Borrow 跨 Chunk 渲染

前面 14.4.4 讲了 Lend/Borrow 机制,这里看它如何用于渲染连续性。

考虑一个大雕像,中心在 chunk A,胳膊伸到 chunk B:

1. ChunkModel 加载时调 `lend(B)`,把自己的胳膊部分借给 B;
2. `Chunk::addLoanItem` 把它加入 B 的 lenders_;
3. B 渲染时,除了画自己的 selfItems_,还要画 lenders_ 里所有借来的 item;

```cpp
// chunk.hpp
bool drawSelf( Moo::DrawContext& drawContext, bool lentOnly = false );
```

`lentOnly=true` 时只画借来的部分,用于"补充渲染"(B 已经画过自己的东西,再补上 A 借来的胳膊)。

这种机制让"跨 chunk 大模型"成为可能,不需要把模型硬切分。代价是 `Chunk` 多了 `lenders_` / `borrowers_` 双向引用,卸载时要小心清理(这就是 `Lender::~Lender` 那个 `MF_ASSERT(items_.empty())` 的原因)。

### 14.11.5 与 CellApp Cell 系统的对比(再回顾)

回到 14.1.3 的对比,现在可以看得更深:

| 维度 | 服务器 Cell | 客户端 Chunk |
|------|------------|-------------|
| 切分依据 | 实体负载(BSP 动态切) | 几何位置(固定网格) |
| 切分粒度 | 大(整个区域) | 小(100m 一格) |
| 跨边界 | Ghost + 实体迁移(网络) | Portal + Lend/Borrow(本地) |
| 加载时机 | CellApp 启动时全加载 | 玩家移动时分帧加载 |
| 卸载 | 不卸载(CellApp 死才释放) | 玩家走远就卸载 |
| 可见性 | AOI(基于距离) | Portal + 视锥 + Umbra |

两套系统的共性是"空间分割 + 跨边界缝合",但目标不同:Cell 关心"谁来算",Chunk 关心"何时画"。一个 MMO 同时跑这两套,各自管自己的事,通过 `spaceID` 关联(Space 是同一个概念,服务器和客户端共享一个 spaceID)。

### 14.11.6 ChunkCache 缓存扩展

`ChunkCache` 是个扩展点,允许在 Chunk 上挂任意缓存数据:

```cpp
// chunk_cache.hpp(概念)
class ChunkCache
{
public:
    virtual void bind( bool isUnbind ) {}
    virtual void draw( Moo::DrawContext& drawContext ) {}

    static int cacheNum();
    static Instance<ChunkCache> * getCacheType( int id );
};

// chunk.hpp
ChunkCache * & cache( int index ) const { return caches_[index]; }
```

`Chunk` 持有一个 `caches_` 数组,每个槽位对应一种 `ChunkCache` 子类。已实现的缓存:

- **`ChunkLightCache`** —— 缓存 chunk 里所有灯光,管理灯光渗透(seep,即灯光穿过 portal 照到邻居 chunk);
- **`ChunkOverlappers`** —— 缓存跨界重叠的 chunk(室内 chunk 嵌入室外 chunk 时用);
- **`EditorChunkCache`** —— 编辑器专用,记录 dirty 状态、修改历史;
- **Umbra 相关缓存** —— 集成 Umbra 遮挡剔除库。

`ChunkCache` 通过 `Instance<T>` 模板实现"类型 ID 自分配",新加一种 cache 不需要改 `Chunk` 类:

```cpp
// chunk_cache.hpp(概念)
template<typename T>
class Instance
{
public:
    Instance() : id_( nextID() ) {}
    static T & instance( Chunk & chunk ) {
        return *static_cast<T*>( chunk.cache( instance_.id_ ) );
    }
private:
    static int nextID();
    int id_;
    static Instance<T> instance_;
};
```

这种设计让 chunk 系统可扩展性极强——任何"每 chunk 一份"的数据都可以做成 cache,不污染 `Chunk` 类本身。

---

## 14.12 本章小结

本章我们深入剖析了 BigWorld 客户端的 Chunk 空间加载系统,核心要点回顾:

**概念层**:

- **Chunk** 是世界的一个凸体积单元,客户端按需加载的基本单位;
- **室外 Chunk** 是固定网格(默认 100m),**室内 Chunk** 是自由形状;
- **Portal** 是 chunk 边界上的"门",连接相邻 chunk,支撑视锥剔除;
- **VLO** 用于跨多个 chunk 的大型连续对象(如河流);
- **ChunkLink** 表达 ChunkItem 之间的引用关系(如开关控制门)。

**实现层**:

- **`Chunk` 类**(`chunk.hpp`)是核心,有 loading/loaded/bound/completed 四状态机;
- **`ChunkLoader`**(`chunk_loader.hpp`)用 `FileIOTaskManager` 后台加载,主线程做 bind;
- **`ChunkManager`**(`chunk_manager.hpp`)是单例,负责扫描、加载调度、渲染入口;
- **`ChunkItem`**(`chunk_item.hpp`)用工厂宏(`DECLARE/IMPLEMENT_CHUNK_ITEM`)实现解耦扩展;
- **`ChunkBoundary::Portal`**(`chunk_boundary.hpp`)是 portal 视锥剔除的核心;
- **`VeryLargeObject` / `ChunkVLO`**(`chunk_vlo.hpp`)用全局 UID 表去重,多 chunk 共享。

**架构层**:

- **`lib/chunk/`** 是核心库,客户端/服务器/编辑器共用主体;
- **`lib/chunk_loading/`** 给服务器用,增量加载整个空间;
- **`lib/chunk_scene_adapter/`** 是适配层,把老 `ChunkSpace` 接入新 `ClientSpace` / `Scene` 系统;
- **`lib/compiled_space/`** 是新一代二进制格式,加载更快、缓存更友好。

**性能与设计哲学**:

- 流式加载让"无限大世界"成为可能,关键是后台 IO + 优先级 + Hysteresis 卸载;
- Portal 系统在室内场景剔除效果显著,可达 90%+ draw call 减少;
- 工厂模式 + ChunkCache 扩展点让系统可扩展性极强;
- Lend/Borrow 机制让跨 chunk 大模型无需硬切分;
- 客户端 Chunk 与服务器 Cell 各司其职,共同支撑 BigWorld 的无缝大世界。

下一章我们会进入 Moo 渲染层,看看这些 ChunkItem 是怎么最终画到屏幕上的。

---

> **源码索引**(本章涉及的主要文件,均位于 `programming/bigworld/lib/`):
>
> - 核心类:`chunk/chunk.hpp`、`chunk/chunk.cpp`、`chunk/chunk_item.hpp`、`chunk/chunk_boundary.hpp`、`chunk/chunk_manager.hpp`、`chunk/chunk_loader.hpp`、`chunk/geometry_mapping.hpp`、`chunk/chunk_space.hpp`
> - ChunkItem 子类:`chunk/chunk_model.hpp`、`chunk/chunk_terrain.hpp`、`chunk/chunk_light.hpp`、`chunk/chunk_tree.hpp`、`chunk/chunk_water.hpp`
> - 特殊机制:`chunk/chunk_vlo.hpp`、`chunk/chunk_link.hpp`、`chunk/chunk_cache.hpp`、`chunk/chunk_overlapper.hpp`、`chunk/chunk_exit_portal.hpp`
> - 文件格式:`chunk/chunk_format.hpp`、`chunk/chunk format.txt`
> - 边界加载:`chunk_loading/preloaded_chunk_space.hpp`、`chunk_loading/edge_geometry_mappings.hpp`
> - 适配器:`chunk_scene_adapter/client_chunk_space_adapter.hpp`
> - 编译空间:`compiled_space/compiled_space.hpp`、`compiled_space/loader.hpp`、`compiled_space/binary_format.hpp`
