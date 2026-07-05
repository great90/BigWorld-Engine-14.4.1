# 专题 11:Chunk 流式加载与 Portal 系统深度剖析

> 本文档以百科级深度剖析 BigWorld Engine 14.4.1 中 **Chunk 流式加载机制与 Portal 视锥剔除系统**的完整实现,涵盖 `Chunk` 类、`ChunkItem` 项系统、`ChunkBoundary`/`Portal` 边界系统、`ChunkLoader` 异步加载、`ChunkManager` 单例调度、`ChunkSpace`/`Column`/`FocusGrid` 空间划分、`GeometryMapping` 几何映射、`ChunkLink`、`VeryLargeObject`/`ChunkVLO` 跨 Chunk 对象、Lend/Borrow 借贷机制、`ChunkOverlapper` 重叠器、`chunk_loading` 服务器边界、`chunk_scene_adapter` 适配器、`compiled_space` 二进制空间格式、`EditorChunkCache` 编辑器扩展等内容。所有代码引用均带相对路径与行号,可在源码中直接定位。

---

## 目录

- [一、Chunk 系统概述与设计哲学](#一chunk-系统概述与设计哲学)
- [二、Chunk 类核心剖析](#二chunk-类核心剖析)
- [三、Chunk 文件格式](#三chunk-文件格式)
- [四、ChunkItem 项系统](#四chunkitem-项系统)
- [五、ChunkTree 树结构](#五chunktree-树结构)
- [六、ChunkLoader 异步加载器](#六chunkloader-异步加载器)
- [七、ChunkManager 单例调度](#七chunkmanager-单例调度)
- [八、ChunkSpace 与 Column、FocusGrid](#八chunkspace-与-columnfocusgrid)
- [九、GeometryMapping 几何映射](#九geometrymapping-几何映射)
- [十、ChunkBoundary 边界系统](#十chunkboundary-边界系统)
- [十一、Portal 深度剖析与视锥剔除](#十一portal-深度剖析与视锥剔除)
- [十二、ChunkLink 链接系统](#十二chunklink-链接系统)
- [十三、VeryLargeObject 与跨 Chunk 对象](#十三verylargeobject-与跨-chunk-对象)
- [十四、Lend/Borrow 借贷机制](#十四lendborrow-借贷机制)
- [十五、空间加载流程详解](#十五空间加载流程详解)
- [十六、chunk_loading 服务器边界](#十六chunk_loading-服务器边界)
- [十七、chunk_scene_adapter 适配器](#十七chunk_scene_adapter-适配器)
- [十八、compiled_space 编译后空间](#十八compiled_space-编译后空间)
- [十九、EditorChunkCache 编辑器缓存](#十九editorchunkcache-编辑器缓存)
- [二十、ChunkOverlapper 重叠器](#二十chunkoverlapper-重叠器)
- [二十一、性能分析](#二十一性能分析)
- [二十二、边界情况与故障处理](#二十二边界情况与故障处理)
- [二十三、与其他引擎对比](#二十三与其他引擎对比)
- [二十四、设计哲学总结](#二十四设计哲学总结)
- [附录 A:关键文件路径速查](#附录-a关键文件路径速查)
- [附录 B:Chunk 状态机速查](#附录-bchunk-状态机速查)
- [附录 C:Portal 标志位速查](#附录-cportal-标志位速查)
- [附录 D:术语表](#附录-d术语表)
- [附录 E:相关专题](#附录-e相关专题)

---

## 一、Chunk 系统概述与设计哲学

### 1.1 为什么需要 Chunk

BigWorld Engine 是面向**开放世界 MMO**的引擎,典型场景需要支持 50km×50km 的无缝大地图、百万级静态物件、数千名同屏玩家。这种规模无法用单一场景图(Scene Graph)承载,必须采用**空间分割 + 流式加载**架构。BigWorld 选择 **Chunk(区块)** 作为分割单元:

- **室外 Chunk**:固定 100m×100m 的水平矩形网格(`grid size`),包含地形块、植被、静态模型、室外光照。
- **室内 Chunk**:不规则形状,大小自由,通过 Shell(壳)结构表示一栋建筑、一层楼或一个房间。
- **Shell Chunk**:作为室内场景的入口,通过 Portal 与室外 Chunk 或其他室内 Chunk 相连。

Chunk 是 BigWorld 流式世界的最小加载/卸载/剔除/借出单位。这种设计与同期的 **Unreal 2 Streaming Levels**(基于 ULevel 的层级流式加载)和 **CryEngine 1 Sectors**(扇区)在思路上相似,但 BigWorld 把 Portal 系统作为一等公民,将其与 Chunk 紧密耦合,实现了**精确的可见性剔除**而非粗粒度的距离剔除。

### 1.2 室内/室外统一处理

BigWorld 设计上**不区分**"室内场景"与"室外场景"两套管线:

| 维度 | 室外 Chunk | 室内 Chunk |
|------|-----------|-----------|
| 形状 | 100m×100m 矩形 | 任意凸多面体(由 boundary planes 定义) |
| 边界 | 6 个 Plane(顶/底/4 侧) | N 个 Plane(N ≥ 4) |
| Portal | 顶/底/侧 Portal | 任意 Portal(门、窗、洞) |
| 地形 | 必有 terrain block | 通常无 terrain |
| 远景 | heaven portal 上方 | 无 heaven |
| 地下 | earth portal 下方 | 无 earth |
| 加载方式 | 玩家进入聚焦半径内自动加载 | 通过 Portal traverse 触发 |

这种统一性让 Portal 算法可以**透明地**处理室内外的过渡:从室外走进室内,只是从一个 Chunk 经由 Portal 走到另一个 Chunk,无需场景切换。

### 1.3 双线程加载模型

BigWorld 采用**主线程 + FileIO 后台线程**的双线程加载模型:

```
┌─────────────────────────────────────────────────────────────────────┐
│  主线程(Main Thread)                                                │
│                                                                       │
│   ChunkManager::tick()                                                │
│     │                                                                 │
│     ├─► camera()         ← 更新摄像机位置和当前 Chunk                │
│     ├─► scan()           ← 扫描需要加载/卸载的 Chunk                │
│     ├─► checkLoadingChunks() ← 检查后台加载是否完成                  │
│     ├─► cullInsideChunks()  ← Portal 视锥剔除(室内)                │
│     ├─► cullOutsideChunks() ← 距离剔除(室外)                      │
│     └─► draw()           ← 渲染聚焦的 Chunk                         │
│                                                                       │
└─────────────────────────────────────────────────────────────────────┘
                              ▲
                              │ 异步事件
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│  FileIO 线程(Background Thread)                                    │
│                                                                       │
│   LoadChunkTask::run()                                                │
│     │                                                                 │
│     ├─► Chunk::load()    ← 解析 .chunk 文件                          │
│     ├─► ChunkItemFactory::create()  ← 创建 ChunkItem                │
│     ├─► formBoundaries() ← 构造边界                                  │
│     ├─► addStaticItem()  ← 加入静态项列表                            │
│     └─► Chunk::loaded()  ← 标记 LOADED 状态                         │
│                                                                       │
│   FindSeedTask::run()                                                 │
│     └─► 查找玩家所在 Chunk 的种子节点                              │
│                                                                       │
└─────────────────────────────────────────────────────────────────────┘
```

这种设计避免了主线程因文件 I/O 而卡顿,是 BigWorld 在 MMO 长时运行场景下的核心保障。

### 1.4 与 Unity/Unreal/CryEngine 对比

| 维度 | BigWorld 14.4.1 | Unity 5(2015) | Unreal Engine 4 | CryEngine 3(2009) |
|------|-----------------|---------------|-----------------|---------------------|
| 流式单元 | Chunk(100m 网格 + 室内 Shell) | Additive Scene | Streaming Level(UE4) / World Partition(UE5) | Sector + Streaming Volume |
| 室内外统一 | ✅ Portal + Chunk 通用 | ❌ Scene 切换 | ⚠️ Level Streaming | ❌ Indoor/Outdoor 分管线 |
| 可见性剔除 | Portal + Umbra | Occlusion Culling | Occlusion + Hardware | Portal + Occlusion |
| 后台 I/O | FileIOTaskManager | Async Read | Async Loading | Stream Engine |
| 加载触发 | Camera Focus + Portal Traverse | Trigger / API | Volume / API | Distance / Volume |
| 跨 Chunk 对象 | VLO + Lend/Borrow | 不支持 | World Partition | 不支持 |
| 编辑器 | WorldEditor | Scene View | World Outliner | Sandbox Editor |

BigWorld 的核心差异化是 **Portal + Lend/Borrow** 这套机制:它让跨 Chunk 大物体(如桥梁、塔楼)不必切割,而通过借贷机制在多个 Chunk 间共享渲染权。

### 1.5 核心类层级关系

```
                            ┌──────────────┐
                            │ ChunkManager │  (singleton)
                            │  (单例调度)   │
                            └──────┬───────┘
                                   │ 管理
                                   ▼
        ┌──────────────────────────────────────────────────┐
        │                  ChunkSpace                      │  (空间)
        │  ┌──────────┐  ┌─────────┐  ┌───────────────┐   │
        │  │ Column   │  │FocusGrid│  │ GeometryMapping│   │
        │  │ (列)     │  │ (聚焦)  │  │  (几何映射)    │   │
        │  └──────────┘  └─────────┘  └───────────────┘   │
        └──────────────────────────────────────────────────┘
                                   │ 持有
                                   ▼
              ┌──────────────────────────────────────┐
              │              Chunk                  │  (区块)
              │  ┌─────────────┐  ┌─────────────┐   │
              │  │ ChunkItem   │  │ChunkBoundary│   │
              │  │ (项)        │  │   + Portal  │   │
              │  └─────────────┘  └─────────────┘   │
              │  ┌─────────────┐  ┌─────────────┐   │
              │  │ ChunkCache  │  │  ChunkLink  │   │
              │  └─────────────┘  └─────────────┘   │
              └──────────────────────────────────────┘
                                   │ 由
                                   ▼
                          ┌─────────────────┐
                          │   ChunkLoader   │  (异步加载)
                          │  + LoadChunkTask│
                          └─────────────────┘
```

接下来各章节将逐一深入剖析每个组件。

---

## 二、Chunk 类核心剖析

`Chunk` 类定义在 `lib/chunk/chunk.hpp:64`,是整个 Chunk 系统的核心。每个 Chunk 实例代表一个空间单元,持有其包含的项、边界、邻居关系和加载状态。

### 2.1 类定义与成员

```cpp
// lib/chunk/chunk.hpp:64
class Chunk : public SafeReferenceCount
{
public:
    // 状态枚举
    // LOADING/LOADED/BOUND 等通过 loading_/loaded_/isBound_ 等标志位表示

    // 加载/绑定
    void appointAsAuthoritative();
    bool load( DataSectionPtr pSection );      // chunk.hpp:80
    void unload();                              // chunk.hpp:99
    void bind( bool shouldFormPortalConnections );  // chunk.hpp:101
    void bindPortals( bool shouldFormPortalConnections, bool shouldFormPortalConnections );
    void unbind( bool cut );                    // chunk.hpp:104
    void focus();                               // chunk.hpp:105
    void smudge();                              // chunk.hpp:106

    // 外部解析
    void resolveExterns( GeometryMapping * pDeadMapping = NULL );  // chunk.hpp:112

    // 静态/动态项管理
    bool addStaticItem( ChunkItemPtr pItem );   // chunk.hpp:118
    void delStaticItem( ChunkItemPtr pItem );  // chunk.hpp:119
    void moveStaticItem( ChunkItemPtr pItem ); // chunk.hpp:122
    void addDynamicItem( ChunkItemPtr pItem ); // chunk.hpp:127
    bool modDynamicItem( ChunkItemPtr pItem, ... );
    void delDynamicItem( ChunkItemPtr pItem, bool bUseDynamicLending=true );  // chunk.hpp:131
    void jogForeignItems();                     // chunk.hpp:133

    // 借贷
    bool addLoanItem( ChunkItemPtr pItem );     // chunk.hpp:137
    bool delLoanItem( ChunkItemPtr pItem, bool bCanFail=false );  // chunk.hpp:138

    // 渲染
    void drawBeg( Moo::DrawContext& drawContext );  // chunk.hpp:147
    void drawEnd();                                  // chunk.hpp:148
    bool drawSelf( Moo::DrawContext& drawContext, bool lentOnly = false );  // chunk.hpp:149
    void drawCaches( Moo::DrawContext& drawContext );  // chunk.hpp:153

    // 状态查询
    bool loading() const    { return loading_; }   // chunk.hpp:180
    bool loaded() const     { return loaded_; }    // chunk.hpp:181
    bool isBound() const    { return isBound_; }   // chunk.hpp:182
    bool completed() const  { return completed_; } // chunk.hpp:183
    bool focussed() const   { return focusCount_ > 0; }  // chunk.hpp:186
    bool isOutsideChunk() const { return isOutsideChunk_; }  // chunk.hpp:175
    bool hasInternalChunks() const { return hasInternalChunks_; }  // chunk.hpp:176
    bool isAppointed() const { return isAppointed_; }  // chunk.hpp:179
};
```

`Chunk` 继承自 `SafeReferenceCount`,这使其支持线程安全的引用计数,可用于跨线程传递(`LoadChunkTask` 在 FileIO 线程持有 `Chunk*`,主线程也持有同一指针)。

### 2.2 核心数据成员

```cpp
// Chunk 类核心成员(简化自 chunk.hpp)
class Chunk {
private:
    BW::string        identifier_;         // Chunk 唯一标识,如 "Fd!01!f8c3!root"
    ChunkSpaceID      spaceID_;            // 所属空间 ID
    Vector3           localOrigin_;        // 本地坐标原点
    Matrix            transform_;         // 局部→世界变换
    Matrix            transformInverse_;   // 世界→局部变换
    BoundingBox       localBB_;            // 本地空间包围盒
    BoundingBox       boundingBox_;        // 世界空间包围盒
    BoundingBox       visibilityBox_;     // 可见性包围盒(包含 lent items)
    bool              boundingBoxReady_;  // 包围盒是否已计算
    bool              visibilityBoxDirty_; // 可见性盒是否需要重算

    // 状态标志
    bool              loading_;           // 正在加载
    bool              loaded_;            // 已加载(数据已读入)
    bool              isBound_;           // 已绑定(portal 已连接)
    bool              completed_;         // 已完成(所有依赖就绪)
    bool              isOutsideChunk_;    // 是室外 Chunk
    bool              hasInternalChunks_; // 包含室内子 Chunk
    bool              isAppointed_;       // 已被指定为权威
    bool              removable_;          // 可卸载
    uint16            focusCount_;        // 被聚焦次数

    // 项列表
    BW::vector<ChunkItemPtr>  selfItems_;   // 自有静态项
    BW::vector<ChunkItemPtr>  dynoItems_;   // 动态项
    BW::vector< BW::vector<ChunkItemPtr> > lentItemLists_;  // 借入的项(按所有者分组)

    // 边界
    BW::vector< ChunkBoundaryPtr >  boundaries_;        // 边界集合
    BW::vector< ChunkBoundary::Portal* >  boundPortals_;   // 已绑定的 Portal
    BW::vector< ChunkBoundary::Portal* >  unboundPortals_;  // 未绑定的 Portal

    // 邻居
    BW::vector< Chunk* >  boundNeighbours_;  // 已绑定的邻居 Chunk

    // 渲染标记
    uint32            drawMark_;           // 绘制标记(防重复)
    uint32            reflectionMark_;     // 反射绘制标记
    uint32            traverseMark_;       // 遍历标记(Portal 算法)
    uint32            visibilityBoxMark_;  // 可见性盒标记

    // Fringe 链表(用于流式卸载)
    Chunk*            fringeNext_;         // Fringe 链表下一个
    Chunk*            fringePrev_;         // Fringe 链表上一个
    float             pathSum_;           // 距摄像机路径长度(用于卸载优先级)

    // 其他
    uint32            echoCount_;          // 重复加载计数(调试)
    Chunk*            pOutsideChunk_;     // 所属室外 Chunk(若此为室内)
    GeometryMapping*  pMapping_;           // 所属几何映射
    bool              fringeArrived_;      // 是否已加入 fringe 链表
};
```

### 2.3 状态机

`Chunk` 类有 5 个核心状态,通过布尔标志组合表示:

```
                          ┌─────────────────┐
              ┌───────────│     EMPTY       │
              │           │ (尚未加载)      │
              │           └────────┬────────┘
              │                    │ load() called
              │                    ▼
              │           ┌─────────────────┐
              │           │    LOADING      │
              │           │ (FileIO 线程    │
              │           │  正在解析)      │
              │           └────────┬────────┘
              │                    │ LoadChunkTask::run() 完成
              │                    ▼
              │           ┌─────────────────┐
              │           │    LOADED       │
              │           │ loaded_=true    │
              │           │ loading_=false  │
              │           └────────┬────────┘
              │                    │ bind(true)
              │                    ▼
              │           ┌─────────────────┐
              │           │    BOUND        │
              │           │ isBound_=true   │
              │           │ Portals 已连接  │
              │           └────────┬────────┘
              │                    │ focus() + 所有依赖就绪
              │                    ▼
              │           ┌─────────────────┐
              │           │   COMPLETED     │
              │           │ completed_=true │
              │           │ 可被渲染        │
              │           └────────┬────────┘
              │                    │ unbind(true) + unload()
              │                    ▼
              └────────────────────► EMPTY
```

详细状态转移:

| 当前状态 | 触发条件 | 新状态 | 调用入口 |
|---------|---------|--------|---------|
| EMPTY | `loadChunk()` 加入队列 | LOADING | `ChunkLoader::loadChunkNow` |
| LOADING | `LoadChunkTask::run()` 完成 | LOADED | `ChunkManager::checkLoadingChunks` |
| LOADED | 邻居就绪,`bind(true)` | BOUND | `Chunk::bind` |
| BOUND | `focus()` 且依赖完成 | COMPLETED | `Chunk::focus` + `updateCompleted` |
| COMPLETED | `unbind(true)` + `unload()` | EMPTY | `ChunkManager::scan` 决定卸载 |

### 2.4 load() 方法详解

`load()` 是 Chunk 数据加载的主入口,在 FileIO 线程被调用:

```cpp
// lib/chunk/chunk.cpp - load 方法
bool Chunk::load( DataSectionPtr pSection )
{
    MF_DEV_ASSERT( !loading_,
        ("Chunk::load() called on a chunk that is already loading!") );

    // 1. 设置状态
    loading_ = true;
    loaded_ = false;

    // 2. 读取标识符与变换矩阵
    BW::string identifier = pSection->readString( "identifier" );
    this->identifier_ = identifier;

    Matrix transform;
    pSection->readMatrix( "transform", transform );
    this->transform_ = transform;
    this->transformInverse_.invert(transform);

    // 3. 读取包围盒
    Vector3 minCorner, maxCorner;
    pSection->readVector3( "boundingBox/min", minCorner );
    pSection->readVector3( "boundingBox/max", maxCorner );
    localBB_ = BoundingBox( minCorner, maxCorner );

    // 4. 设置 outside 标志(根据网格类型判断)
    isOutsideChunk_ = ...;

    // 5. 解析 chunk 项(详见第四章)
    DataSectionIterator it = pSection->begin();
    while ( it != pSection->end() )
    {
        DataSectionPtr pItemSection = *it;
        ChunkItemPtr pItem = ChunkItemFactory::create(
            pItemSection, this );
        if (pItem)
        {
            addStaticItem( pItem );
        }
        ++it;
    }

    // 6. 构造边界(详见第十章)
    formBoundaries( pSection );

    // 7. 标记为已加载
    loading_ = false;
    loaded_ = true;

    return true;
}
```

关键点:
1. **状态保护**:`MF_DEV_ASSERT` 在开发构建中断言不重复加载。
2. **变换矩阵**:每个 Chunk 有自己的局部→世界变换,室内 Chunk 通常有非零平移与旋转。
3. **包围盒**:本地空间的包围盒,后续通过 `transform_` 转到世界空间。
4. **ChunkItem 工厂**:所有 `<item>` 子节点通过 `ChunkItemFactory::create` 创建,工厂模式详见第四章。
5. **formBoundaries**:解析 `<boundary>` 节点,构造 `ChunkBoundary` 集合,这是 Portal 系统的基础。

### 2.5 bind() 与 unbind() 详解

`bind()` 将 Chunk 的 Portal 与邻居 Chunk 的对应 Portal 连接起来,这是 Portal 视锥剔除的前提:

```cpp
// lib/chunk/chunk.cpp - bind 方法
void Chunk::bind( bool shouldFormPortalConnections )
{
    MF_DEV_ASSERT( loaded_, ("Chunk::bind() called on an unloaded chunk!") );

    // 1. 设置绑定状态
    isBound_ = true;

    // 2. 对每个未绑定的 Portal,尝试解析邻居
    for (uint i = 0; i < unboundPortals_.size(); i++)
    {
        ChunkBoundary::Portal* pPortal = unboundPortals_[i];
        bindPortal( pPortal );  // 尝试绑定
    }

    // 3. 形成新的 Portal 连接(可选)
    if (shouldFormPortalConnections)
    {
        bindPortals( true, true );
    }

    // 4. 通知所有 cache
    notifyCachesOfBind( false );

    // 5. 调用 onMoved 通知所有项
    for (uint i = 0; i < selfItems_.size(); i++)
    {
        selfItems_[i]->toss( this );
    }

    // 6. 更新完成状态
    updateCompleted();
}
```

`unbind()` 是反向过程,通过 `cut` 参数控制是否真正卸载:

```cpp
// lib/chunk/chunk.cpp - unbind 方法
void Chunk::unbind( bool cut )
{
    MF_DEV_ASSERT( isBound_,
        ("Chunk::unbind() called on an unbound chunk!") );

    // 1. 解除所有 Portal 绑定
    for (uint i = 0; i < boundPortals_.size(); i++)
    {
        unbindPortal( i );
    }

    // 2. 通知 cache 解绑
    notifyCachesOfBind( true );

    // 3. 调用 toss(NULL) 让所有项离开
    for (uint i = 0; i < selfItems_.size(); i++)
    {
        selfItems_[i]->toss( NULL );
    }

    // 4. 设置绑定状态
    isBound_ = false;

    // 5. 如果 cut=true,完全卸载数据
    if (cut)
    {
        selfItems_.clear();
        dynoItems_.clear();
        lentItemLists_.clear();
        boundaries_.clear();
        loaded_ = false;
    }
}
```

`cut` 参数的含义:
- `cut = false`:仅解除绑定,数据保留在内存,可快速重新 `bind`。
- `cut = true`:完全卸载,释放所有 ChunkItem 引用,可用于远距离 Chunk 的彻底卸载。

### 2.6 addStaticItem 与 addLoanItem

```cpp
// lib/chunk/chunk.cpp - addStaticItem
bool Chunk::addStaticItem( ChunkItemPtr pItem )
{
    MF_DEV_ASSERT( pItem,
        ("Chunk::addStaticItem() called with NULL item!") );

    // 1. 设置项的所有者
    pItem->chunk( this );

    // 2. 加入静态项列表
    selfItems_.push_back( pItem );

    // 3. 更新包围盒
    updateBoundingBoxes( pItem );

    // 4. 调用 toss 进入"被持有"状态
    pItem->toss( this );

    // 5. 通知 cache
    for (uint i = 0; i < caches_.size(); i++)
    {
        caches_[i]->addStaticItem( pItem );
    }

    return true;
}

// lib/chunk/chunk.cpp - addLoanItem
bool Chunk::addLoanItem( ChunkItemPtr pItem )
{
    // 1. 找到 item 的原始 owner
    Chunk* pOwner = pItem->chunk();

    // 2. 在 lentItemLists_ 中找到/创建该 owner 对应的列表
    for (uint i = 0; i < lentItemLists_.size(); i++)
    {
        if (lentItemLists_[i].owner_ == pOwner)
        {
            lentItemLists_[i].items_.push_back( pItem );
            return true;
        }
    }

    // 3. 创建新列表
    LoanItemList newList;
    newList.owner_ = pOwner;
    newList.items_.push_back( pItem );
    lentItemLists_.push_back( newList );

    return true;
}
```

`selfItems_` 与 `lentItemLists_` 的区别:
- `selfItems_`:Chunk **自有**的静态项,生命周期与本 Chunk 绑定。
- `lentItemLists_`:从其他 Chunk **借来**渲染的项,按 owner 分组存储,owner 卸载时需要清理对应的借入项。

### 2.7 drawSelf 与渲染流程

```cpp
// lib/chunk/chunk.cpp - drawSelf
bool Chunk::drawSelf( Moo::DrawContext& drawContext, bool lentOnly )
{
    BW::vector<ChunkItemPtr>::iterator it;

    if (!lentOnly)
    {
        // 正常模式:绘制自有项 + 动态项
        for (it = selfItems_.begin(); it != selfItems_.end(); it++)
        {
            // drawMark_ 防止同一帧多次绘制
            if ((*it)->drawMark() != s_nextMark_)
            {
                (*it)->draw( drawContext );
                (*it)->drawMark( s_nextMark_ );
            }
        }

        for (it = dynoItems_.begin(); it != dynoItems_.end(); it++)
        {
            if ((*it)->drawMark() != s_nextMark_)
            {
                (*it)->draw( drawContext );
                (*it)->drawMark( s_nextMark_ );
            }
        }
    }

    // 绘制借入项(lentOnly 模式只绘制这部分)
    size_t lils = lentItemLists_.size();
    for (size_t i = 0; i < lils; i++)
    {
        for (it = lentItemLists_[i].begin();
            it != lentItemLists_[i].end(); it++)
        {
            if ((*it)->drawMark() != s_nextMark_)
            {
                (*it)->draw( drawContext );
                (*it)->drawMark( s_nextMark_ );
            }
        }
    }

    return true;
}
```

`lentOnly` 模式的语义:当一个 Chunk 已经被卸载(`loaded_ = false`),但其项仍被其他 Chunk 借入时,这些"幽灵"借出项仍需在借入方 Chunk 渲染时被绘制。BigWorld 通过 `drawSelf(drawContext, true)` 实现这一机制。

### 2.8 focus() 与 fringe 链表

```cpp
// lib/chunk/chunk.cpp - focus
void Chunk::focus()
{
    if (focusCount_ == 0)
    {
        ChunkManager::instance().addFringe( this );
    }
    focusCount_++;
}

// lib/chunk/chunk_manager.cpp - addFringe
void ChunkManager::addFringe( Chunk * pChunk )
{
    // 头插法,新加入的 Chunk 在链表头部
    pChunk->fringeNext( fringeHead_ );
    pChunk->fringePrev( NULL );
    if (fringeHead_)
    {
        fringeHead_->fringePrev( pChunk );
    }
    fringeHead_ = pChunk;
}
```

`fringe` 链表是 ChunkManager 维护的"已聚焦 Chunk"链表,用于:
1. 渲染时遍历 fringe 链表(而非整个空间)。
2. 卸载时按 `pathSum_`(距摄像机路径长度)排序,优先卸载远的 Chunk。

### 2.9 appointAsAuthoritative 与权威性

```cpp
// lib/chunk/chunk.cpp - appointAsAuthoritative
void Chunk::appointAsAuthoritative()
{
    isAppointed_ = true;
    // ... 一些边界检查
}
```

`appointAsAuthoritative` 标记此 Chunk 为"权威 Chunk",意味着该 Chunk 在多映射(`GeometryMapping` 多版本共存场景)中被选为"权威来源",其他版本的对应 Chunk 不再加载。

---

## 三、Chunk 文件格式

Chunk 数据存储在 `.chunk` 文件中,通常是 XML 格式(开发期)或编译后的二进制格式(发布期)。文件格式说明位于 `lib/chunk/chunk format.txt`。

### 3.1 XML 格式概览

```xml
<?xml version="1.0"?>
<chunk>
    <identifier>Fd!01!f8c3!root</identifier>
    <transform>0 0 0 0 0 0 1 1 1 1</transform>
    <boundingBox>
        <min>-50 -50 0</min>
        <max>50 50 100</max>
    </boundingBox>
    <isOutsideChunk>true</isOutsideChunk>

    <!-- 静态项 -->
    <item>
        <model>level_test/cube.model</model>
        <transform>0 0 0 0 0 0 1 1 1 1</transform>
    </item>

    <item>
        <light>omni</light>
        <position>0 10 0</position>
        <colour>255 255 255</colour>
        <intensity>1.0</intensity>
    </item>

    <item>
        <terrain>terrain_height_map.bmp</terrain>
        <holeTextureSize>32</holeTextureSize>
        <normalMap>normals.dds</normalMap>
    </item>

    <!-- 边界与 Portal -->
    <boundary>
        <plane>0 1 0 0</plane>  <!-- 顶面平面 -->
        <portal>
            <chunkName>Fd!01!f8c3!heaven</chunkName>
            <internal>0</internal>
            <points>4</points>
            <p1>-50 100 -50</p1>
            <p2>50 100 -50</p2>
            <p3>50 100 50</p3>
            <p4>-50 100 50</p4>
        </portal>
        <heaven/>
    </boundary>

    <boundary>
        <plane>0 -1 0 0</plane>  <!-- 底面平面 -->
        <portal>
            <chunkName>Fd!01!f8c3!earth</chunkName>
            <earth/>
        </portal>
        <earth/>
    </boundary>

    <boundary>
        <plane>1 0 0 50</plane>  <!-- 东面平面 -->
        <portal>
            <chunkName>Fd!01!f8c4</chunkName>
            <points>4</points>
            <p1>50 0 -50</p1>
            <p2>50 100 -50</p2>
            <p3>50 100 50</p3>
            <p4>50 0 50</p4>
        </portal>
    </boundary>

    <!-- ... 其他边界 -->
</chunk>
```

### 3.2 关键字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| `<identifier>` | string | Chunk 唯一标识,格式见 3.3 |
| `<transform>` | 10 浮点数 | 平移(3)+ 四元数(4)+ 缩放(3),共 10 个浮点数 |
| `<boundingBox>` | min/max | 本地空间包围盒 |
| `<isOutsideChunk>` | bool | 是否为室外 Chunk |
| `<item>` | 子节点 | 静态项,通过 `ChunkItemFactory` 解析 |
| `<boundary>` | 子节点 | 边界,每个 boundary 含一个平面和可选的 Portal |

### 3.3 Identifier 命名规范

Chunk identifier 采用**层次化命名**:

```
格式: <mappingName>!<gridX>!<gridZ>!<chunkType>
```

示例:
- `Fd!01!f8c3!root` —— mapping=`Fd`,网格 X=01,Z=f8c3,类型=`root`(根 Chunk)
- `Fd!01!f8c3!heaven` —— 天空 Chunk(在 root 上方)
- `Fd!01!f8c3!earth` —— 地下 Chunk(在 root 下方)
- `Fd!01!f8c3!shell01` —— 室内 Shell Chunk

解析逻辑见 `Chunk::identifier_` 的解析代码,关键是用 `!` 分隔符拆分,并通过 gridX/gridZ 在 `GeometryMapping` 中查找对应网格。

### 3.4 二进制格式(compiled_space)

发布构建使用 `compiled_space` 二进制格式替代 XML,提高加载速度:

```
+--------------------------------+
| CompiledSpace Header           |
|  - magic: "BWCS"               |
|  - version: uint32             |
|  - numChunks: uint32           |
|  - chunkTableOffset: uint64    |
+--------------------------------+
| Chunk Records (numChunks ×)    |
|  - identifierOffset: uint32    |
|  - boundingBox: 6 floats       |
|  - transform: 10 floats        |
|  - isOutsideChunk: uint8       |
|  - hasInternalChunks: uint8    |
|  - itemDataOffset: uint32      |
|  - itemDataSize: uint32        |
|  - boundaryDataOffset: uint32 |
|  - boundaryDataSize: uint32    |
+--------------------------------+
| String Table                   |
|  - identifier strings          |
+--------------------------------+
| Item Data (per chunk)          |
|  - 序列化的 ChunkItem 二进制   |
+--------------------------------+
| Boundary Data (per chunk)      |
|  - 序列化的边界与 Portal       |
+--------------------------------+
```

二进制格式的优点:
1. **加载快**:无需 XML 解析,直接 memcpy。
2. **内存紧凑**:无 XML 标签开销,字段对齐。
3. **可随机访问**:通过 chunkTableOffset 可直接定位任意 Chunk 数据。

详见第十八章 `compiled_space` 的深度剖析。

---

## 四、ChunkItem 项系统

`ChunkItem` 是 Chunk 内所有可视/逻辑对象的基类,定义在 `lib/chunk/chunk_item.hpp:234`。

### 4.1 类层次

```
SpecialChunkItem (内部基类)
       ▲
       │
ChunkItemBase  (chunk_item.hpp:86, 私有继承 SafeReferenceCount)
       ▲
       │
   ChunkItem  (chunk_item.hpp:234)
       ▲
       │
   ┌───┴────┬────────┬────────┬────────┬─────────┬────────┬────────┐
   │        │        │        │        │         │        │        │
ChunkModel ChunkLight ChunkTerrain ChunkTree ChunkExitPortal ChunkFlare ChunkLink ...
```

### 4.2 ChunkItemBase 与 ChunkItem

```cpp
// lib/chunk/chunk_item.hpp:86
class ChunkItemBase : private SafeReferenceCount
{
public:
    // Want flags - 表示项需要哪些资源/通知
    enum WantFlags
    {
        wantFlags_              = 0,
        wantNotified_           = 1 << 0,  // 通知 toss
        wantNotedInChunk_       = 1 << 1,  // 在 chunk 中登记
        wantTicked_             = 1 << 2,  // 每 tick 调用
        wantUpdate_             = 1 << 3,  // 外部更新
        wantDraw_               = 1 << 4,  // 渲染
        wantTickEmpty_          = 1 << 5,  // 即使空 chunk 也 tick
        wantReflection_         = 1 << 6,  // 反射渲染
    };

    // 生命周期
    virtual void toss( Chunk * pChunk );  // 进入/离开 chunk
    virtual void tick( float dTime );     // 每帧更新(若 wantTicked_)
    virtual void draw( Moo::DrawContext& drawContext );  // 渲染

    // 访问
    Chunk* chunk() const { return pChunk_; }
    void chunk( Chunk* pChunk ) { pChunk_ = pChunk; }

private:
    Chunk*  pChunk_;          // 所属 chunk
    uint32  wantFlags_;       // Want flags
};

// lib/chunk/chunk_item.hpp:234
class ChunkItem : public SpecialChunkItem
{
public:
    // lendByBoundingBox - 跨 chunk 借贷的核心方法
    virtual bool lendByBoundingBox( Chunk* pChunk, const BoundingBox& chunkBB );

    // toss 内部实现
    virtual void toss( Chunk* pChunk );

    // 标记
    uint32 drawMark() const { return drawMark_; }
    void drawMark( uint32 m ) { drawMark_ = m; }

    // 工厂注册
    static bool registerFactory( const BW::string& type, ChunkItemFactory* pFactory );
    static ChunkItemPtr create( DataSectionPtr pSection, Chunk* pChunk );
};
```

### 4.3 toss 生命周期

`toss()` 是 ChunkItem 的核心生命周期方法,在项被加入或离开 Chunk 时调用:

```cpp
// lib/chunk/chunk_item.cpp - toss
void ChunkItemBase::toss( Chunk * pChunk )
{
    // 1. 旧 chunk 解绑
    if (pChunk_)
    {
        // 通知旧 chunk 的 cache 移除该项
        for (uint i = 0; i < pChunk_->caches().size(); i++)
        {
            pChunk_->caches()[i]->delItem( this );
        }
    }

    // 2. 更新所属 chunk
    pChunk_ = pChunk;

    // 3. 新 chunk 绑定
    if (pChunk_)
    {
        // 通知新 chunk 的 cache 添加该项
        for (uint i = 0; i < pChunk_->caches().size(); i++)
        {
            pChunk_->caches()[i]->addItem( this );
        }

        // 处理跨 chunk 借贷
        if (wantFlags_ & wantLend_)
        {
            lendByBoundingBox( pChunk_, pChunk_->boundingBox() );
        }
    }
}
```

`toss(NULL)` 表示项被移出 Chunk,`toss(pChunk)` 表示项被加入 `pChunk`。这是 ChunkItem 在 Chunk 间迁移的统一入口。

### 4.4 lendByBoundingBox - 跨 Chunk 借贷

```cpp
// lib/chunk/chunk_item.cpp - lendByBoundingBox
bool ChunkItem::lendByBoundingBox( Chunk* pChunk, const BoundingBox& chunkBB )
{
    // 1. 计算项的世界包围盒
    BoundingBox worldBB = itemWorldBB();

    // 2. 如果与 chunkBB 不相交,直接返回
    if (!worldBB.intersects( chunkBB ))
    {
        return false;
    }

    // 3. 检查项是否已被 chunk 持有(自有)
    if (pChunk->staticItemIndex( this ) >= 0)
    {
        return false;  // 自有项不再借入
    }

    // 4. 检查是否已借入过(避免重复)
    if (pChunk->isLoanItem( this ))
    {
        return false;
    }

    // 5. 加入借入列表
    pChunk->addLoanItem( this );

    return true;
}
```

`lendByBoundingBox` 是 BigWorld 跨 Chunk 大物体(桥梁、塔楼、巨型雕塑)的关键:它根据项的世界包围盒与每个邻近 Chunk 的包围盒求交,如果相交就将项借给该 Chunk 渲染。这避免了大物体被强制切割,也避免了渲染时跨越 Chunk 边界的物体消失。

### 4.5 工厂模式:DECLARE/IMPLEMENT_CHUNK_ITEM 宏

ChunkItem 通过宏注册到工厂:

```cpp
// lib/chunk/chunk_item.hpp
#define DECLARE_CHUNK_ITEM( x ) \
    static ChunkItemFactory* s_pFactory_; \
    static ChunkItemFactory& factory() { return *s_pFactory_; } \
    virtual ChunkItemFactory& getFactory() const { return *s_pFactory_; }

#define IMPLEMENT_CHUNK_ITEM( cls, name, wantFlags ) \
    ChunkItemFactory* cls::s_pFactory_ = \
        new ChunkItemFactoryImpl<cls>( name, wantFlags ); \
    namespace \
    { \
        bool s_##cls##_registered = \
            ChunkItem::registerFactory( name, cls::s_pFactory_ ); \
    }
```

使用示例:

```cpp
// lib/chunk/chunk_model.hpp
class ChunkModel : public ChunkItem
{
    DECLARE_CHUNK_ITEM( ChunkModel )
    // ...
};

// lib/chunk/chunk_model.cpp
IMPLEMENT_CHUNK_ITEM( ChunkModel, "Model", ChunkItem::wantDraw_ )
```

`IMPLEMENT_CHUNK_ITEM` 在文件作用域创建静态工厂对象 `s_pFactory_`,并通过命名空间匿名作用域的 `bool s_<cls>_registered` 触发注册到全局工厂表。这样在 `Chunk::load` 解析 `<item>` 时,可通过 `ChunkItemFactory::create(pSection, pChunk)` 根据节点名(`"Model"`、`"Light"` 等)创建对应类型的实例。

### 4.6 WantFlags 详解

`WantFlags` 控制 ChunkItem 在 Chunk 中的行为:

| Flag | 含义 | 触发逻辑 |
|------|------|---------|
| `wantNotified_` | 通知 toss 进入/离开 | Chunk::bind/unbind 时调用 toss |
| `wantNotedInChunk_` | 在 chunk 中登记 | 加入 selfItems_ 列表 |
| `wantTicked_` | 每 tick 调用 | ChunkManager::tick 遍历 |
| `wantUpdate_` | 外部更新 | chunk->updateBoundingBoxes |
| `wantDraw_` | 渲染 | drawSelf 时调用 draw |
| `wantTickEmpty_` | 即使空 chunk 也 tick | 卸载后仍调用 |
| `wantReflection_` | 反射渲染 | drawReflection 时调用 |
| `wantLend_` | 支持借贷 | lendByBoundingBox |

这些 flag 在工厂注册时设定,例如 `ChunkModel` 注册时设 `wantDraw_`,而 `ChunkLight` 设 `wantDraw_ | wantNotified_`。

---

## 五、ChunkTree 树结构

`ChunkTree` 是 BigWorld 室内场景的层级组织单元,定义在 `lib/chunk/chunk_tree.hpp`。它允许将一组相关 Chunk 组织成树形结构(例如一栋多层建筑)。

### 5.1 设计目标

- **加速剔除**:整棵子树可以被快速排除,无需逐个 Chunk 检测。
- **批量加载**:加载一个 ChunkTree 等于加载多个相关 Chunk。
- **空间组织**:反映"建筑 → 楼层 → 房间"的层级关系。

### 5.2 类接口

```cpp
// lib/chunk/chunk_tree.hpp
class ChunkTree
{
public:
    ChunkTree();
    ~ChunkTree();

    // 添加子树/子 Chunk
    void addChild( ChunkTree* pChild );
    void addChunk( Chunk* pChunk );

    // 渲染
    void draw( Moo::DrawContext& drawContext );

    // 加载
    bool load( DataSectionPtr pSection, Chunk* pParent );

private:
    BW::vector<ChunkTree*>  children_;  // 子树
    BW::vector<Chunk*>       chunks_;    // 直接包含的 Chunk
    BoundingBox              boundingBox_;  // 整树的包围盒
};
```

### 5.3 与 Chunk 的关系

ChunkTree 是 Chunk 的"容器"而非替代:

```
ChunkTree (建筑)
├── ChunkTree (1 层)
│   ├── Chunk (走廊)
│   ├── Chunk (房间 A)
│   └── Chunk (房间 B)
├── ChunkTree (2 层)
│   └── ...
└── Chunk (主入口)
```

加载 ChunkTree 时,会递归加载所有子节点。这是 BigWorld 处理"室内多楼层"的常用模式。

---

## 六、ChunkLoader 异步加载器

`ChunkLoader` 是 Chunk 异步加载的入口,定义在 `lib/chunk/chunk_loader.hpp`。它派生自 `BackgroundTask`,通过 `FileIOTaskManager` 在后台线程执行。

### 6.1 类层次

```cpp
// lib/chunk/chunk_loader.hpp:13
class ChunkLoader : public BackgroundTask
{
public:
    // 主线程调用:加入加载队列
    void loadChunkNow( Chunk* pChunk );

    // 后台线程调用:实际加载
    virtual void run();

private:
    BW::vector<Chunk*>  loadQueue_;
    Mutex               queueMutex_;
};
```

### 6.2 LoadChunkTask 异步任务

```cpp
// lib/chunk/chunk_loader.cpp
class LoadChunkTask : public BackgroundTask
{
public:
    LoadChunkTask( Chunk* pChunk )
        : pChunk_( pChunk )
    {
    }

    virtual void run()
    {
        // 1. 读取 chunk 文件
        DataSectionPtr pSection = BWResource::instance().rootSection()->readSection(
            pChunk_->resourceID() );

        // 2. 调用 Chunk::load 解析
        pChunk_->load( pSection );

        // 3. 标记加载完成,等待主线程 bind
        // (主线程在 checkLoadingChunks 中检测 loaded_ 标志)
    }

private:
    Chunk*  pChunk_;
};
```

### 6.3 FindSeedTask 种子查找

```cpp
// lib/chunk/chunk_loader.cpp
class FindSeedTask : public BackgroundTask
{
public:
    FindSeedTask( ChunkSpace* pSpace, const Vector3& pos )
        : pSpace_( pSpace ), pos_( pos )
    {
    }

    virtual void run()
    {
        // 1. 在 space 中找到包含 pos 的 Chunk
        Chunk* pSeed = pSpace_->findChunk( pos_ );

        // 2. 设置为种子 Chunk
        pSeed->focus();

        // 3. 触发周边 Chunk 加载
        ChunkManager::instance().scan();
    }

private:
    ChunkSpace*  pSpace_;
    Vector3      pos_;
};
```

`FindSeedTask` 用于玩家首次进入世界时,找到玩家所在 Chunk 作为"种子",从种子开始递归加载所有可见的邻近 Chunk。

### 6.4 后台任务调度

`FileIOTaskManager` 维护一个后台线程池(默认 1 个线程,可配置),任务以队列方式调度:

```cpp
// lib/app/file_io_task_manager.hpp(简化)
class FileIOTaskManager
{
public:
    void addTask( BackgroundTask* pTask )
    {
        ScopedLock lock( queueMutex_ );
        taskQueue_.push( pTask );
        queueCV_.notify_one();
    }

    void backgroundRun()
    {
        while (running_)
        {
            BackgroundTask* pTask = NULL;
            {
                ScopedLock lock( queueMutex_ );
                while (taskQueue_.empty() && running_)
                {
                    queueCV_.wait( queueMutex_ );
                }
                if (!taskQueue_.empty())
                {
                    pTask = taskQueue_.front();
                    taskQueue_.pop();
                }
            }

            if (pTask)
            {
                pTask->run();  // 在后台线程执行
            }
        }
    }
};
```

主线程通过 `addTask` 加入任务,后台线程通过 `run` 执行。任务执行完成后,后台线程将结果(已加载的 Chunk)通过设置标志位的方式通知主线程,主线程在下一帧 `checkLoadingChunks` 中检查并完成后续处理(bind、focus 等)。

---

## 七、ChunkManager 单例调度

`ChunkManager` 是 Chunk 系统的核心调度器,定义在 `lib/chunk/chunk_manager.hpp:46`,通过 `instance()` 单例访问。

### 7.1 类定义概览

```cpp
// lib/chunk/chunk_manager.hpp:46
class ChunkManager : public Mercury::InputMessageHandler
{
public:
    static ChunkManager& instance();

    // 初始化/销毁
    bool init( DataSectionPtr configSection = NULL );
    bool fini();

    // 主循环
    void camera( const Matrix& cameraTransform,
                 ChunkSpacePtr pSpace, Chunk* pOverride = NULL );
    void tick( float dTime );
    void draw( Moo::DrawContext& drawContext );

    // Chunk 加载管理
    void loadChunkNow( Chunk* chunk );
    void loadChunkExplicitly( const BW::string& identifier,
                              GeometryMapping* pMapping );

    // 查询
    Chunk* findChunkByName( const BW::string& identifier,
                            GeometryMapping* pMapping );
    Chunk* findChunkByGrid( int16 x, int16 z, GeometryMapping* pMapping );
    Chunk* findOutdoorChunkByPosition( float x, float z,
                                       GeometryMapping* pMapping );
    Chunk* cameraChunk() const { return cameraChunk_; }

    // 状态
    bool busy() const { return !loadingChunks_.empty(); }
    bool loadPending() { return busy() || findSeedTask_; }
    bool canLoadChunks() const { return canLoadChunks_; }
    void canLoadChunks( bool canLoadChunks );

    // 配置
    void maxLoadPath( float v );
    void minUnloadPath( float v );
    void maxUnloadChunks( unsigned int maxUnloadChunks );
    void autoSetPathConstraints( float farPlane );

    // 模式切换
    void switchToSyncMode( bool sync );     // 同步加载模式(用于切场景)
    void switchToSyncTerrainLoad( bool sync );

    // Fringe 链表
    void addFringe( Chunk* pChunk );
    void delFringe( Chunk* pChunk );

private:
    // 主循环内部
    bool scan();                          // 扫描加载/卸载
    bool blindpanic();                    // 紧急加载(玩家穿墙)
    bool autoBootstrapSeedChunk();        // 自动引导种子
    bool checkLoadingChunks();            // 检查后台加载完成
    void checkCameraBoundaries();         // 摄像机跨边界检测
    void cullInsideChunks( Chunk* pChunk,
        ChunkBoundary::Portal* pPortal,
        Portal2DRef portal2D,
        const Portal2DRef& parentPortal2D );
    void cullOutsideChunks( ChunkVector& chunks,
        const PortalBoundsVector& outsidePortals );
};
```

### 7.2 tick() 主流程

```cpp
// lib/chunk/chunk_manager.cpp - tick
void ChunkManager::tick( float dTime )
{
    // 1. 检查后台加载完成的 Chunk
    checkLoadingChunks();

    // 2. 扫描加载/卸载
    if (scanEnabled_)
    {
        scan();
    }

    // 3. 摄像机跨边界检测(切换 cameraChunk_)
    checkCameraBoundaries();

    // 4. 自动引导种子(若 cameraChunk_ 为空)
    if (!cameraChunk_ && scanEnabled_)
    {
        autoBootstrapSeedChunk();
    }

    // 5. tick 所有 focused chunk 的项
    Chunk* pFringe = fringeHead_;
    while (pFringe)
    {
        for (uint i = 0; i < pFringe->selfItems().size(); i++)
        {
            if (pFringe->selfItems()[i]->wantFlags() & ChunkItem::wantTicked_)
            {
                pFringe->selfItems()[i]->tick( dTime );
            }
        }
        pFringe = pFringe->fringeNext();
    }
}
```

### 7.3 scan() 加载/卸载策略

`scan()` 是 ChunkManager 的核心调度逻辑:

```cpp
// lib/chunk/chunk_manager.cpp - scan
bool ChunkManager::scan()
{
    // 1. 距离阈值
    float maxLoadPath = maxLoadPath_;        // 加载半径
    float minUnloadPath = minUnloadPath_;    // 卸载半径(滞后)

    // 2. 从 cameraChunk_ 开始 BFS 遍历 Portal 图
    if (cameraChunk_)
    {
        BFS_queue.push( cameraChunk_ );
        visited[cameraChunk_] = true;
        cameraChunk_->pathSum( 0 );
    }

    while (!BFS_queue.empty())
    {
        Chunk* pCurrent = BFS_queue.front();
        BFS_queue.pop();

        // 2.1 触发加载(若未加载)
        if (!pCurrent->loaded() && !pCurrent->loading())
        {
            loadChunk( pCurrent, /*highPriority=*/false );
        }

        // 2.2 累计 pathSum,继续 BFS
        for (uint i = 0; i < pCurrent->boundNeighbours().size(); i++)
        {
            Chunk* pNeighbour = pCurrent->boundNeighbours()[i];
            float pathSum = pCurrent->pathSum() +
                pathLength( pCurrent, pNeighbour );

            if (pathSum > maxLoadPath)
            {
                continue;  // 超出加载半径
            }

            if (!visited[pNeighbour])
            {
                visited[pNeighbour] = true;
                pNeighbour->pathSum( pathSum );
                BFS_queue.push( pNeighbour );
            }
        }
    }

    // 3. 卸载超出 minUnloadPath 的 focused chunk
    Chunk* pFringe = fringeHead_;
    while (pFringe)
    {
        Chunk* pNext = pFringe->fringeNext();
        if (pFringe->pathSum() > minUnloadPath && pFringe->removable())
        {
            delFringe( pFringe );
            pFringe->unbind( true );  // cut=true,完全卸载
        }
        pFringe = pNext;
    }

    return true;
}
```

关键策略:
1. **BFS 加载**:从 `cameraChunk_` 出发,通过 Portal 链接做广度优先遍历。
2. **pathSum 距离**:累计经过的 Portal 路径长度(欧氏距离之和),而非直线距离。
3. **滞后卸载**:`minUnloadPath > maxLoadPath`,避免临界距离上的反复加载/卸载。
4. **优先级**:`loadChunk(pChunk, highPriority)`,摄像机附近的 Chunk 优先加载。

### 7.4 checkLoadingChunks()

```cpp
// lib/chunk/chunk_manager.cpp - checkLoadingChunks
bool ChunkManager::checkLoadingChunks()
{
    bool anyLoaded = false;

    // 遍历 loadingChunks_ 列表
    for (uint i = 0; i < loadingChunks_.size(); /*nop*/)
    {
        Chunk* pChunk = loadingChunks_[i];

        if (pChunk->loaded())  // 后台加载完成
        {
            // 1. 从 loadingChunks_ 移除
            loadingChunks_.erase( loadingChunks_.begin() + i );

            // 2. 调用 bind
            pChunk->bind( /*shouldFormPortalConnections=*/true );

            // 3. 触发 portal resolveExtern
            pChunk->resolveExterns();

            anyLoaded = true;
        }
        else
        {
            i++;
        }
    }

    return anyLoaded;
}
```

### 7.5 checkCameraBoundaries()

```cpp
// lib/chunk/chunk_manager.cpp - checkCameraBoundaries
void ChunkManager::checkCameraBoundaries()
{
    if (!cameraChunk_)
    {
        return;
    }

    // 1. 检查摄像机是否仍位于 cameraChunk_ 内
    if (cameraChunk_->contains( cameraPos_ ))
    {
        return;
    }

    // 2. 否则,遍历 cameraChunk_ 的所有 boundPortals,找摄像机进入哪个
    for (uint i = 0; i < cameraChunk_->boundPortals().size(); i++)
    {
        ChunkBoundary::Portal* pPortal = cameraChunk_->boundPortals()[i];

        if (pPortal->inside( cameraPos_ ))
        {
            // 3. 切换 cameraChunk_
            cameraChunk_ = pPortal->pChunk_;
            break;
        }
    }

    // 4. 若都未匹配,触发 blindpanic
    if (cameraPos_ not in any boundPortal)
    {
        blindpanic();
    }
}
```

`blindpanic()` 是紧急加载机制:摄像机意外进入一个未加载的 Chunk(玩家穿墙或快速移动),立即同步加载该 Chunk 以避免渲染空洞。

### 7.6 cullInsideChunks 与 Portal 视锥剔除

```cpp
// lib/chunk/chunk_manager.cpp - cullInsideChunks
void ChunkManager::cullInsideChunks(
    Chunk* pChunk,
    ChunkBoundary::Portal* pPortal,
    Portal2DRef portal2D,
    const Portal2DRef& parentPortal2D )
{
    // 1. 标记 pChunk 已遍历
    pChunk->traverseMark( s_nextMark_ );

    // 2. 渲染 pChunk(可见)
    pChunk->drawCaches( drawContext_ );

    // 3. 遍历 pChunk 的所有 Portal
    for (uint i = 0; i < pChunk->boundPortals().size(); i++)
    {
        ChunkBoundary::Portal* pNextPortal = pChunk->boundPortals()[i];

        // 3.1 跳过特殊 Portal(heaven/earth)
        if (pNextPortal->isHeaven() || pNextPortal->isEarth())
        {
            continue;
        }

        // 3.2 计算 Portal 在屏幕空间的 2D 投影
        Portal2DRef nextPortal2D = projectPortal( pNextPortal, parentPortal2D );

        // 3.3 视锥剔除:若 nextPortal2D 与父 Portal2D 求交为空,跳过
        if (nextPortal2D->disjoint( parentPortal2D ))
        {
            continue;
        }

        // 3.4 递归遍历邻居 Chunk
        Chunk* pNeighbour = pNextPortal->pChunk_;
        if (pNeighbour && pNeighbour->traverseMark() != s_nextMark_)
        {
            cullInsideChunks(
                pNeighbour, pNextPortal, nextPortal2D, parentPortal2D );
        }
    }
}
```

这是 BigWorld Portal 视锥剔除的核心算法,详见第十一章。

### 7.7 switchToSyncMode 同步加载

```cpp
// lib/chunk/chunk_manager.cpp - switchToSyncMode
void ChunkManager::switchToSyncMode( bool sync )
{
    syncMode_ = sync;

    if (sync)
    {
        // 阻塞等待所有 pending 加载完成
        while (busy())
        {
            checkLoadingChunks();
            Sleep( 1 );  // 让出 CPU
        }
    }
}
```

同步模式用于切场景(如登录→游戏),确保所有 Chunk 加载完成后再继续,避免渲染过程中出现可见的"卡顿"。

---

## 八、ChunkSpace 与 Column、FocusGrid

`ChunkSpace` 是 Chunk 存储的空间容器,定义在 `lib/chunk/chunk_space.hpp`。每个 ChunkSpace 实例对应一个游戏世界(可有多世界并存,如主世界 + 副本)。

### 8.1 类层次

```
BaseChunkSpace  (base_chunk_space.hpp)
    ▲
    │
ChunkSpace  (chunk_space.hpp)
    ▲
    │
   ┌┴────────────┐
ClientChunkSpace  ServerChunkSpace
(client_chunk_space.hpp)  (server_chunk_space.hpp)
```

### 8.2 BaseChunkSpace

```cpp
// lib/chunk/base_chunk_space.hpp:23
class BaseChunkSpace : public SafeReferenceCount
{
public:
    BaseChunkSpace( ChunkSpaceID id );

    // Column 管理
    Column* column( float x, float z, bool canCreate = true );
    Column* column( int16 gridX, int16 gridZ, bool canCreate = true );

    // Chunk 查找
    Chunk* findChunk( const Vector3& point );
    Chunk* findChunk( int16 gridX, int16 gridZ );

    // 几何映射
    void addMapping( GeometryMapping* pMapping );
    void delMapping( GeometryMapping* pMapping );
    const BW::vector<GeometryMapping*>& mappings() const { return mappings_; }

    // FocusGrid(聚焦网格)
    void focusGrid( const Vector3& focusPoint );

protected:
    ChunkSpaceID   id_;
    BW::vector<GeometryMapping*>  mappings_;
    BW::vector<Column*>           columns_;  // 二维网格(行优先)
    int16          gridMaxX_;
    int16          gridMinX_;
    int16          gridMaxZ_;
    int16          gridMinZ_;
};
```

### 8.3 Column 列

`Column` 是 X-Z 网格的"列",代表一个 (gridX, gridZ) 单元,可能包含多个垂直堆叠的 Chunk(室外 Chunk + heaven Chunk + earth Chunk + 室内 Shell):

```cpp
// lib/chunk/base_chunk_space.hpp(简化)
class Column
{
public:
    Column( int16 gridX, int16 gridZ, BaseChunkSpace* pSpace );

    Chunk* findChunk( const Vector3& point );
    void   addChunk( Chunk* pChunk );
    void   delChunk( Chunk* pChunk );

private:
    int16          gridX_;
    int16          gridZ_;
    BaseChunkSpace* pSpace_;
    BW::vector<Chunk*>  chunks_;  // 该网格上的所有 Chunk(垂直堆叠)
    bool           outsideChunkMarked_;
};
```

`Column::findChunk` 遍历该网格上的所有 Chunk,找到包含指定点的 Chunk。室外 Chunk 通过 X-Z 矩形快速判断,室内 Chunk 通过完整的 boundary planes 判断。

### 8.4 FocusGrid 聚焦网格

`FocusGrid` 是一个环形网格,跟踪以摄像机为中心的有限区域:

```cpp
// lib/chunk/base_chunk_space.hpp(简化)
class FocusGrid
{
public:
    FocusGrid( int size = 16 );  // size×size 网格
    void focus( const Vector3& point );

    Chunk* chunkAt( int gridX, int gridZ );

private:
    int   size_;
    Chunk***  grid_;  // 环形缓冲,自动滚动
    int   originX_;
    int   originZ_;
};
```

`FocusGrid` 的核心是**环形缓冲**:
- 网格大小固定(如 16×16),覆盖摄像机周围 ±8 个 Chunk。
- 当摄像机移动到新网格时,网格原点(`originX_, originZ_`)滚动一格,新进入的行/列被填充,离开的行/列被清空。
- 这种设计避免了动态分配,适合高频摄像机移动场景。

### 8.5 ClientChunkSpace 与 ServerChunkSpace

```cpp
// lib/chunk/client_chunk_space.hpp
class ClientChunkSpace : public ChunkSpace
{
public:
    // 客户端特有:渲染、可见性、Portal
    void draw( Moo::DrawContext& drawContext );
    void updateVisibleChunks();

private:
    // 客户端特有缓存
    BW::vector<Chunk*>  visibleChunks_;
};

// lib/chunk/server_chunk_space.hpp
class ServerChunkSpace : public ChunkSpace
{
public:
    // 服务端特有:AOI、运动学、Ghost 同步
    void restoreGhost( Chunk* pChunk, Entity* pEntity );

private:
    // 服务端特有缓存
    BW::map<ChunkID, EntityList>  ghosts_;
};
```

服务端 `ServerChunkSpace` 不需要渲染,但需要维护 Ghost 同步、运动学查询、AOI 半径查询等。

---

## 九、GeometryMapping 几何映射

`GeometryMapping` 是 Chunk 空间与具体文件系统/资源路径的映射,定义在 `lib/chunk/geometry_mapping.hpp`。

### 9.1 设计目的

- **多映射共存**:同一 ChunkSpace 可有多个映射(原始 + 补丁 + 副本)。
- **路径抽象**:不同 mapping 指向不同资源目录。
- **网格管理**:管理 X-Z 网格大小、原点偏移。
- **资源调度**:与 BWResource 协作,实现资源加载。

### 9.2 核心接口

```cpp
// lib/chunk/geometry_mapping.hpp
class GeometryMapping
{
public:
    GeometryMapping( const BW::string& path, ChunkSpace* pSpace );

    // 路径
    const BW::string& path() const { return path_; }
    const BW::string& resourceID( const BW::string& identifier ) const;

    // 网格
    int gridSize() const { return gridSize_; }  // 默认 100m
    const Vector3& origin() const { return origin_; }
    int16 gridX( float x ) const;
    int16 gridZ( float z ) const;

    // Chunk 查找
    Chunk* findChunk( const BW::string& identifier );
    Chunk* findChunkByGrid( int16 x, int16 z );

    // 状态
    bool condemned() const { return condemned_; }
    void condemn();  // 标记为废弃(等待卸载)

private:
    BW::string   path_;       // 资源根路径
    ChunkSpace*  pSpace_;
    int           gridSize_;   // 网格大小(米)
    Vector3       origin_;     // 网格原点偏移
    bool          condemned_;  // 是否已废弃
};
```

### 9.3 多映射场景

BigWorld 支持同一空间内的多个 mapping 共存:

```
┌─────────────────────────────────────────┐
│            ChunkSpace                    │
│                                          │
│  mappings_[0]: GeometryMapping( "base/" ) │  基础世界
│  mappings_[1]: GeometryMapping( "patch/" )│  补丁(覆盖基础)
│  mappings_[2]: GeometryMapping( "instance01/" )│  副本
│                                          │
└─────────────────────────────────────────┘
```

`findChunk(identifier)` 会按 mappings_ 顺序查找,后加入的 mapping 优先(类似 Unix PATH 的查找顺序,但相反)。这支持"基础世界 + 增量补丁"的发布模式。

### 9.4 condemn() 与映射销毁

`condemn()` 标记 mapping 为废弃,触发所属 ChunkSpace 卸载该 mapping 的所有 Chunk:

```cpp
// lib/chunk/chunk_manager.cpp - mappingCondemned
void ChunkManager::mappingCondemned( GeometryMapping* pMapping )
{
    // 遍历所有 focused chunk,卸载属于 pMapping 的
    Chunk* pFringe = fringeHead_;
    while (pFringe)
    {
        Chunk* pNext = pFringe->fringeNext();
        if (pFringe->mapping() == pMapping)
        {
            delFringe( pFringe );
            pFringe->unbind( true );
        }
        pFringe = pNext;
    }

    // 通知 ChunkSpace 移除 mapping
    pMapping->space()->delMapping( pMapping );
}
```

---

## 十、ChunkBoundary 边界系统

`ChunkBoundary` 定义在 `lib/chunk/chunk_boundary.hpp:139`,是 Chunk 几何形状与 Portal 的载体。

### 10.1 类定义

```cpp
// lib/chunk/chunk_boundary.hpp:139
struct ChunkBoundary : public ReferenceCount
{
public:
    // 静态成员
    static uint32 s_nextMark_;
    static void    fini();

    // 内嵌 Portal 类
    class Portal
    {
    public:
        // 类型标志
        bool isHeaven() const    { return !!(flags_ & (1<<1)); }
        bool isEarth() const     { return !!(flags_ & (1<<2)); }
        bool isInvasive() const  { return !!(flags_ & (1<<3)); }
        bool isExtern() const    { return !!(flags_ & (1<<4)); }

        // 几何
        void objectSpacePoint( int idx, Vector3& ret );
        bool inside( const Vector3& point ) const;
        bool inside( const Vector2& point ) const;
        bool intersectSphere( const Vector3& centre, float radius ) const;

        // 渲染
        void display( const Matrix& transform, ... );

        // 外部解析
        bool resolveExtern( Chunk* pOwnChunk );

        // 遍历
        bool traverse( Chunk* pChunk, ... );

        // 静态更新
        static void updateFrustumBB();

    private:
        Vector3*        pPoints_;      // 顶点(对象空间)
        uint            nPoints_;
        PlaneEq         plane_;        // 所在平面
        Chunk*          pChunk_;       // 邻居 Chunk(已绑定时)
        BW::string      chunkName_;    // 邻居 identifier(未绑定时)
        uint32          flags_;
        bool            hasChunkItem_;
    };

    // ChunkBoundary 成员
    PlaneEq                                     plane_;
    BW::vector< Portal* >                       boundPortals_;
    BW::vector< Portal* >                       unboundPortals_;
    BW::vector< Portal* >                       portals_;
    BW::vector< ChunkBoundary::Portal* >       invasivePortals_;

    // 方法
    void validatePortals( DataSectionPtr boundarySection,
                          DataSectionPtr chunkSection );
    void bindPortal( uint32 unboundIndex );
    void unbindPortal( uint32 boundIndex );
    void addInvasivePortal( Portal* pPortal );
    void splitInvasivePortal( Chunk* pChunk, uint i );
};
```

### 10.2 边界与 Portal 的关系

每个 ChunkBoundary 包含一个**平面方程**(`plane_`)和多个 Portal:
- 平面:定义 Chunk 的一面边界(如东面、西面、顶面)。
- Portal:平面上的开口,通过 Portal 可进入邻居 Chunk。

一个 ChunkBoundary 可包含多个 Portal(例如一面墙上有两个门,通向两个不同 Chunk),也可没有 Portal(完全封闭的墙)。

### 10.3 Portal 类型

BigWorld 区分 5 种 Portal:

| 类型 | 标志位 | 用途 | 视觉表现 |
|------|--------|------|---------|
| 普通 Portal | (无) | 通用入口/出口 | 透明 |
| Heaven(天空) | `1<<1` | 顶面,通向天空盒 | 蓝色天空 |
| Earth(地下) | `1<<2` | 底面,通向地下 | 黑色或地形下方 |
| Invasive(穿透) | `1<<3` | 跨 Chunk 穿透(如柱子) | 透明 |
| Extern(外部) | `1<<4` | 跨 Mapping 引用 | 透明 |

Heaven/Earth Portal 是室外 Chunk 的特征,允许 BigWorld 在 sky dome 与地面下渲染额外的远景元素(云、远山)。

### 10.4 Portal 几何与视锥剔除

每个 Portal 由若干顶点(`pPoints_`,通常 4 个,矩形)定义在对象空间,经 `pOwnChunk->transform()` 转到世界空间。Portal 的核心几何操作:

1. **inside 判断**:`point` 是否在 Portal 平面投影内。
2. **intersectSphere 球-多边形相交**:用于粗粒度视锥剔除。
3. **project 到屏幕空间**:用于细粒度视锥剔除,详见第十一章。

### 10.5 formBoundaries 与 formPortal

```cpp
// lib/chunk/chunk.cpp - formBoundaries
bool Chunk::formBoundaries( DataSectionPtr pSection )
{
    // 遍历 <boundary> 子节点
    for (DataSectionIterator it = pSection->begin();
        it != pSection->end(); ++it)
    {
        DataSectionPtr pBndSection = *it;
        if (pBndSection->sectionName() != "boundary") continue;

        // 1. 创建 ChunkBoundary
        ChunkBoundary* pBnd = new ChunkBoundary();

        // 2. 读取 plane
        Vector4 planeEq;
        pBndSection->readVector4( "plane", planeEq );
        pBnd->plane_ = PlaneEq( planeEq );

        // 3. 读取 portals
        for (...)
        {
            ChunkBoundary::Portal* pPortal = new Portal();
            pPortal->plane_ = pBnd->plane_;
            // 读取顶点
            pPortal->pPoints_ = ...;
            pPortal->nPoints_ = ...;
            // 读取 chunkName(邻居标识)
            pPortal->chunkName_ = ...;
            // 读取 flags
            if (pBndSection->readBool( "heaven", false ))
                pPortal->flags_ |= (1<<1);
            if (pBndSection->readBool( "earth", false ))
                pPortal->flags_ |= (1<<2);
            // ...

            pBnd->portals_.push_back( pPortal );
            pBnd->unboundPortals_.push_back( pPortal );
        }

        boundaries_.push_back( pBnd );
    }

    return true;
}

// lib/chunk/chunk.cpp - formPortal
bool Chunk::formPortal( Chunk* pChunk, ChunkBoundary::Portal& portal )
{
    // 1. 检查 pChunk 是否与 portal 匹配(平面相同,顶点对应)
    if (!portalMatch( pChunk, portal ))
    {
        return false;
    }

    // 2. 建立 Portal 与 pChunk 的双向链接
    portal.pChunk_ = pChunk;

    // 3. 在 pChunk 的对应 Portal 上也建立反向链接
    ChunkBoundary::Portal* pReverse = findReversePortal( pChunk, portal );
    if (pReverse)
    {
        pReverse->pChunk_ = this;
    }

    return true;
}
```

### 10.6 resolveExtern

```cpp
// lib/chunk/chunk_boundary.cpp - resolveExtern
bool ChunkBoundary::Portal::resolveExtern( Chunk* pOwnChunk )
{
    if (!isExtern()) return true;

    // 1. 通过 chunkName 在 mapping 中查找
    Chunk* pExternChunk = pOwnChunk->mapping()->findChunk( chunkName_ );

    if (!pExternChunk)
    {
        // 邻居未加载,等待
        return false;
    }

    // 2. 建立链接
    pChunk_ = pExternChunk;
    return true;
}
```

`Extern` Portal 用于跨 Mapping 引用,例如基础世界的 Chunk 通过 Extern Portal 引用副本中的 Chunk。`resolveExtern` 在每次 bind 时尝试解析,失败则保留为 unboundPortal。

---

## 十一、Portal 深度剖析与视锥剔除

Portal 系统是 BigWorld 室内/室外场景可见性剔除的核心。本节深度剖析 Portal 视锥剔除算法。

### 11.1 算法概览

BigWorld 的 Portal 视锥剔除采用**递归 Portal 遍历**算法:

```
1. 从摄像机所在 Chunk(cameraChunk_)开始
2. 渲染该 Chunk
3. 对每个 boundPortal:
   a. 将 Portal 几何投影到屏幕空间,得到 Portal2D
   b. 用父 Portal 的 Portal2D 裁剪当前 Portal2D
   c. 若 Portal2D 为空(完全不可见),跳过
   d. 否则,用当前 Portal2D 作为新的 frustum,递归处理邻居 Chunk
```

这种算法的核心是**Portal2D 累积裁剪**:每个 Chunk 的可见范围受父 Portal 限制,即只有通过父 Portal 才能看到该 Chunk 的内容。

### 11.2 Portal2D 类

```cpp
// lib/chunk/chunk_boundary.hpp:97
class Portal2DRef
{
public:
    Portal2DRef();
    Portal2DRef( const Portal2DRef& other );

    // 计算 Portal 在屏幕空间的 2D 投影
    void project( const Matrix& viewProj, const ChunkBoundary::Portal& portal );

    // 与其他 Portal2D 求交
    void intersect( const Portal2DRef& other );

    // 是否为空(完全不可见)
    bool empty() const;

    // 是否与其他不相交
    bool disjoint( const Portal2DRef& other ) const;

private:
    Portal2D* pVal_;  // 实际数据(引用计数)
};
```

### 11.3 cullInsideChunks 算法详解

```cpp
// lib/chunk/chunk_manager.cpp - cullInsideChunks(完整版)
void ChunkManager::cullInsideChunks(
    Chunk* pChunk,
    ChunkBoundary::Portal* pPortal,
    Portal2DRef portal2D,
    const Portal2DRef& parentPortal2D )
{
    // 1. 标记已遍历(防止循环)
    pChunk->traverseMark( s_nextMark_ );

    // 2. 设置视锥(用 portal2D 与 parentPortal2D 的交集)
    Portal2DRef visiblePortal2D = portal2D;
    visiblePortal2D.intersect( parentPortal2D );

    if (visiblePortal2D.empty())
    {
        return;  // 完全不可见
    }

    // 3. 渲染当前 Chunk 的内容
    // 用 visiblePortal2D 作为 scissor rect,提高渲染效率
    Moo::rc().pushScissorRect( visiblePortal2D.scissorRect() );

    pChunk->drawBeg( drawContext_ );
    pChunk->drawSelf( drawContext_ );      // 自有项
    pChunk->drawCaches( drawContext_ );    // cache(光照、阴影等)
    pChunk->drawEnd();

    Moo::rc().popScissorRect();

    // 4. 递归处理邻居 Chunk
    for (uint i = 0; i < pChunk->boundPortals().size(); i++)
    {
        ChunkBoundary::Portal* pNextPortal = pChunk->boundPortals()[i];

        // 4.1 跳过 heaven/earth(不递归)
        if (pNextPortal->isHeaven() || pNextPortal->isEarth())
        {
            continue;
        }

        // 4.2 跳过 invasive(特殊处理,见 11.5)
        if (pNextPortal->isInvasive())
        {
            handleInvasive( pNextPortal );
            continue;
        }

        // 4.3 投影 Portal 到屏幕空间
        Portal2DRef nextPortal2D;
        nextPortal2D.project( viewProjMatrix_, *pNextPortal );

        // 4.4 视锥剔除:与 visiblePortal2D 求交
        if (nextPortal2D.disjoint( visiblePortal2D ))
        {
            continue;
        }

        // 4.5 递归
        Chunk* pNeighbour = pNextPortal->pChunk_;
        if (pNeighbour && pNeighbour->traverseMark() != s_nextMark_)
        {
            cullInsideChunks(
                pNeighbour, pNextPortal, nextPortal2D, visiblePortal2D );
        }
    }
}
```

### 11.4 视锥剔除的几何意义

```
┌─────────────────────────────────────────────────────┐
│            屏幕空间                                  │
│                                                      │
│   ┌────────────────────────────┐  ← 父 Portal       │
│   │                            │     (可见范围)     │
│   │   ┌──────────────────┐    │  ← 当前 Portal    │
│   │   │                  │    │     (裁剪后)       │
│   │   │   渲染内容        │    │                    │
│   │   │                  │    │                    │
│   │   └──────────────────┘    │                    │
│   │                            │                    │
│   └────────────────────────────┘                    │
│                                                      │
└─────────────────────────────────────────────────────┘
```

每个 Chunk 的可见内容受其入口 Portal 在屏幕空间的投影限制。算法通过 `intersect` 操作累积缩小可见区域,实现层层剔除。

### 11.5 Invasive Portal 处理

Invasive Portal 表示一个跨 Chunk 边界穿透的物体(如柱子),其渲染不通过 Portal 视锥剔除,而是直接渲染:

```cpp
// lib/chunk/chunk_boundary.cpp - addInvasivePortal
void ChunkBoundary::addInvasivePortal( Portal* pPortal )
{
    invasivePortals_.push_back( pPortal );
}
```

Invasive Portal 的项被分裂为多个 Chunk 共享,每个 Chunk 渲染其"侵入"的部分。

### 11.6 cullOutsideChunks - 室外距离剔除

对于室外 Chunk,视锥剔除改为基于距离的剔除:

```cpp
// lib/chunk/chunk_manager.cpp - cullOutsideChunks
void ChunkManager::cullOutsideChunks(
    ChunkVector& chunks,
    const PortalBoundsVector& outsidePortals )
{
    // 1. 获取摄像机视锥
    const Camera* pCamera = Moo::rc().camera();
    const Frustum& frustum = pCamera->frustum();

    for (uint i = 0; i < chunks.size(); i++)
    {
        Chunk* pChunk = chunks[i];

        // 2. 视锥/包围盒剔除
        if (!frustum.intersects( pChunk->boundingBox() ))
        {
            continue;
        }

        // 3. 距离剔除
        float dist = (pChunk->centre() - cameraPos_).length();
        if (dist > maxVisibleDistance_)
        {
            continue;
        }

        // 4. 渲染
        pChunk->drawSelf( drawContext_ );
    }
}
```

室外 Chunk 不通过 Portal 连接(除 heaven/earth 外),所以使用标准的视锥-包围盒剔除 + 距离剔除。

### 11.7 Portal::traverse 详解

```cpp
// lib/chunk/chunk_boundary.cpp - traverse
bool ChunkBoundary::Portal::traverse( Chunk* pChunk, ... )
{
    // 1. 检查方向:摄像机是否在 Portal 的正面
    Vector3 normal = plane_.normal();
    Vector3 toCamera = cameraPos_ - pPoints_[0];
    if (normal.dotProduct( toCamera ) < 0)
    {
        return false;  // 摄像机在 Portal 背面,不可见
    }

    // 2. 检查邻居 Chunk 是否已加载
    if (!pChunk_) return false;

    // 3. 检查可见性
    Portal2DRef portal2D;
    portal2D.project( viewProj_, *this );
    if (portal2D.empty()) return false;

    return true;
}
```

### 11.8 性能考量

Portal 算法的关键开销:
1. **Portal2D::project**:每个 Portal 的 4 顶点投影,~16 个浮点乘法。
2. **Portal2D::intersect**:多边形求交,复杂度 O(n+m),n/m 是顶点数。
3. **递归深度**:室内场景典型深度 3-5,极端场景可能 10+。

BigWorld 通过以下优化:
1. **traverseMark_**:防止循环遍历,避免无限递归。
2. **frustumBB 更新**:`Portal::updateFrustumBB()` 缓存视锥-包围盒,加速粗筛。
3. **scissor rect**:用 Portal2D 作为 scissor,提高 GPU 渲染效率。
4. **特殊 Portal 跳过**:heaven/earth 不递归,降低深度。

---

## 十二、ChunkLink 链接系统

`ChunkLink` 定义在 `lib/chunk/chunk_link.hpp:12`,是 Chunk 间的逻辑链接项。

### 12.1 设计目的

ChunkLink 表示跨 Chunk 的逻辑关系,典型用途:
- **节点链路**:两个 Chunk 中的节点(如门、按钮)逻辑关联。
- **触发器链路**:跨 Chunk 触发器与目标。
- **物理链路**:跨 Chunk 物理约束(绳索、链条)。

### 12.2 类定义

```cpp
// lib/chunk/chunk_link.hpp:12
class ChunkLink : public ChunkItem
{
public:
    enum Direction
    {
        DIR_INTERNAL = 0,  // 内部链接(同一 Chunk)
        DIR_EXTERNAL = 1,  // 外部链接(跨 Chunk)
    };

    // 设置/获取两端
    void setStart( ChunkItemTreeNode* pStart );
    void setEnd( ChunkItemTreeNode* pEnd );
    ChunkItemTreeNode* start() const { return pStart_; }
    ChunkItemTreeNode* end() const { return pEnd_; }

    // 方向
    Direction direction() const { return direction_; }

    // toss 重写:管理两端
    virtual void toss( Chunk* pChunk );

private:
    ChunkItemTreeNode*  pStart_;
    ChunkItemTreeNode*  pEnd_;
    Direction           direction_;
};
```

### 12.3 跨 Chunk 链接解析

ChunkLink 在 toss 时解析跨 Chunk 的另一端:

```cpp
// lib/chunk/chunk_link.cpp - toss(简化)
void ChunkLink::toss( Chunk* pChunk )
{
    if (pChunk == NULL)
    {
        // 离开 Chunk,断开链接
        if (pStart_) pStart_->unlink( this );
        if (pEnd_)   pEnd_->unlink( this );
    }
    else
    {
        // 加入 Chunk,建立链接
        if (direction_ == DIR_EXTERNAL)
        {
            // 外部链接:在邻居 Chunk 中查找另一端
            ChunkItemTreeNode* pOther = pChunk->findNode( otherEndID_ );
            if (pOther)
            {
                pEnd_ = pOther;
                pEnd_->link( this );
            }
        }
    }

    ChunkItem::toss( pChunk );
}
```

---

## 十三、VeryLargeObject 与跨 Chunk 对象

`VeryLargeObject`(VLO)是 BigWorld 处理跨 Chunk 大物体的核心机制,定义在 `lib/chunk/chunk_vlo.hpp` / `chunk_vlo.cpp`。

### 13.1 设计动机

某些游戏物件天然跨 Chunk:
- **桥梁**:可能跨越 5+ Chunk。
- **塔楼/巨型雕塑**:高度超过 100m,跨越上下多个 Chunk。
- **城墙**:延展数百米。

如果用普通 ChunkItem,这些物件会被强制切割或只能放在一个 Chunk(导致渲染时跨边界的部分消失)。VLO 提供了**全局唯一对象 + 借贷渲染**的解决方案。

### 13.2 VeryLargeObject 类

```cpp
// lib/chunk/chunk_vlo.hpp
class VeryLargeObject : public SafeReferenceCount
{
public:
    VeryLargeObject( const BW::string& name, DataSectionPtr pSection );

    // 标识
    const BW::string& name() const { return name_; }

    // 渲染
    void draw( Moo::DrawContext& drawContext );

    // 包围盒
    const BoundingBox& boundingBox() const { return boundingBox_; }

    // 项管理
    void addItem( ChunkItemPtr pItem );
    void delItem( ChunkItemPtr pItem );

    // chunk 关联
    void addChunk( Chunk* pChunk );
    void delChunk( Chunk* pChunk );

private:
    BW::string                  name_;
    BoundingBox                  boundingBox_;
    BW::vector<ChunkItemPtr>     items_;
    BW::vector<Chunk*>           chunks_;  // 该 VLO 影响的所有 chunk
};
```

### 13.3 ChunkVLO - Chunk 中的 VLO 代理

`ChunkVLO` 是 `ChunkItem` 的派生类,作为 VLO 在每个关联 Chunk 中的代理:

```cpp
// lib/chunk/chunk_vlo.hpp
class ChunkVLO : public ChunkItem
{
    DECLARE_CHUNK_ITEM( ChunkVLO )

public:
    // toss 重写:管理 VLO 关联
    virtual void toss( Chunk* pChunk );

    // draw 重写:调用 VLO 的 draw
    virtual void draw( Moo::DrawContext& drawContext )
    {
        if (pVLO_) pVLO_->draw( drawContext );
    }

private:
    VeryLargeObject*  pVLO_;  // 共享的 VLO 对象
    BW::string        vloName_;  // VLO 名称(用于查找)
};
```

### 13.4 VLOFactory - 全局去重

```cpp
// lib/chunk/chunk_vlo.cpp
class VLOFactory
{
public:
    static VLOFactory& instance();

    VeryLargeObject* get( const BW::string& name );
    void release( const BW::string& name );

private:
    BW::map<BW::string, VeryLargeObject*>  vloMap_;
    BW::map<BW::string, int>                refCount_;
};

VeryLargeObject* VLOFactory::get( const BW::string& name )
{
    BW::map<BW::string, VeryLargeObject*>::iterator it = vloMap_.find( name );
    if (it != vloMap_.end())
    {
        refCount_[name]++;
        return it->second;
    }

    // 首次加载:从文件读取 VLO
    DataSectionPtr pSection = BWResource::instance().rootSection()->readSection(
        name + ".vlo" );
    VeryLargeObject* pVLO = new VeryLargeObject( name, pSection );
    vloMap_[name] = pVLO;
    refCount_[name] = 1;
    return pVLO;
}
```

### 13.5 ChunkVLO::toss - VLO 关联流程

```cpp
// lib/chunk/chunk_vlo.cpp - toss
void ChunkVLO::toss( Chunk* pChunk )
{
    if (pChunk == NULL)
    {
        // 离开 Chunk:从 VLO 的 chunks_ 列表移除
        if (pVLO_)
        {
            pVLO_->delChunk( pChunk_ );
            VLOFactory::instance().release( vloName_ );
            pVLO_ = NULL;
        }
    }
    else
    {
        // 加入 Chunk:获取(或创建)共享 VLO 实例
        if (!pVLO_)
        {
            pVLO_ = VLOFactory::instance().get( vloName_ );
        }
        pVLO_->addChunk( pChunk );
    }

    ChunkItem::toss( pChunk );
}
```

### 13.6 VLO 渲染去重

VLO 的关键特性:**全局只渲染一次**。即使 VLO 影响多个 Chunk,每个 Chunk 的 `ChunkVLO` 都调用 `pVLO_->draw()`,但 VLO 内部有去重机制:

```cpp
// lib/chunk/chunk_vlo.cpp - VeryLargeObject::draw
void VeryLargeObject::draw( Moo::DrawContext& drawContext )
{
    if (drawMark_ == s_nextMark_) return;  // 已渲染
    drawMark_ = s_nextMark_;

    // 渲染所有 items
    for (uint i = 0; i < items_.size(); i++)
    {
        items_[i]->draw( drawContext );
    }
}
```

通过 `drawMark_` 标记,确保一帧内只渲染一次。

### 13.7 VLO 与 Lend/Borrow 的对比

| 维度 | VLO | Lend/Borrow |
|------|-----|-------------|
| 适用对象 | 超大物体(桥梁、塔楼) | 中等物体(家具、装饰) |
| 拥有权 | 全局唯一,无明确 owner | 单一 owner Chunk |
| 渲染触发 | 每个关联 Chunk 渲染时调用 | 在 owner chunk 渲染时调用,在借入 chunk 渲染时也调用 |
| 去重机制 | drawMark 全局去重 | drawMark 防 owner 重复 |
| 加载 | VLOFactory 全局缓存 | 随 owner Chunk 加载 |
| 卸载 | 引用计数为 0 时卸载 | 随 owner Chunk 卸载 |

VLO 适合"绝对大"的物件,Lend/Borrow 适合"边界跨 1-2 个 Chunk"的中等物件。

---

## 十四、Lend/Borrow 借贷机制

Lend/Borrow 是 BigWorld 处理跨 Chunk 边界物件的核心机制。本节深度剖析。

### 14.1 借贷场景

```
┌─────────────────┐  ┌─────────────────┐
│   Chunk A       │  │   Chunk B       │
│                 │  │                 │
│  ┌──────────────┤──┼──────────────┐  │
│  │              │  │              │  │
│  │   Chair      │  │   Chair      │  │
│  │  (owner A)   │  │  (lent to B) │  │
│  │              │  │              │  │
│  └──────────────┤──┼──────────────┘  │
│                 │  │                 │
└─────────────────┘  └─────────────────┘

椅子的世界包围盒跨越 A、B 边界。
- 椅子是 A 的自有项(selfItems_)。
- 椅子被"借"给 B,B 的 lentItemLists_ 中持有它。
- B 渲染时,绘制椅子(因为椅子在 B 的视野内)。
- A 渲染时,也绘制椅子(因为 A 是 owner)。
- drawMark_ 防止同一帧多次绘制。
```

### 14.2 借贷触发条件

借贷通过 `ChunkItem::lendByBoundingBox` 触发:

```cpp
// lib/chunk/chunk_item.cpp - lendByBoundingBox(完整版)
bool ChunkItem::lendByBoundingBox( Chunk* pChunk, const BoundingBox& chunkBB )
{
    // 1. 必须支持 lending
    if (!(wantFlags_ & wantLend_))
    {
        return false;
    }

    // 2. 计算项的世界包围盒
    BoundingBox worldBB;
    this->worldBoundingBox( worldBB );

    // 3. 不相交则不借
    if (!worldBB.intersects( chunkBB ))
    {
        return false;
    }

    // 4. 自有项不借(避免自借)
    if (pChunk->staticItemIndex( this ) >= 0)
    {
        return false;
    }

    // 5. 已借入不重复
    if (pChunk->isLoanItem( this ))
    {
        return false;
    }

    // 6. 加入借入列表
    pChunk->addLoanItem( this );

    return true;
}
```

### 14.3 jogForeignItems - 触发借贷

```cpp
// lib/chunk/chunk.cpp - jogForeignItems
void Chunk::jogForeignItems()
{
    // 遍历所有邻居 Chunk(及其自身),检查它们的自有项是否需要借入本 Chunk
    for (uint i = 0; i < boundNeighbours_.size(); i++)
    {
        Chunk* pNeighbour = boundNeighbours_[i];
        for (uint j = 0; j < pNeighbour->selfItems_.size(); j++)
        {
            ChunkItemPtr pItem = pNeighbour->selfItems_[j];
            pItem->lendByBoundingBox( this, boundingBox_ );
        }
    }
}
```

`jogForeignItems` 在 Chunk 完成绑定后调用,扫描所有邻居的自有项,将符合条件的项借入本 Chunk。

### 14.4 借贷的渲染流程

```cpp
// lib/chunk/chunk.cpp - drawSelf(完整版)
bool Chunk::drawSelf( Moo::DrawContext& drawContext, bool lentOnly )
{
    BW::vector<ChunkItemPtr>::iterator it;

    if (!lentOnly)
    {
        // 正常模式:绘制自有项 + 动态项
        for (it = selfItems_.begin(); it != selfItems_.end(); it++)
        {
            if ((*it)->drawMark() != s_nextMark_)
            {
                (*it)->draw( drawContext );
                (*it)->drawMark( s_nextMark_ );
            }
        }

        for (it = dynoItems_.begin(); it != dynoItems_.end(); it++)
        {
            if ((*it)->drawMark() != s_nextMark_)
            {
                (*it)->draw( drawContext );
                (*it)->drawMark( s_nextMark_ );
            }
        }
    }

    // 绘制借入项(lentOnly 模式只绘制这部分)
    size_t lils = lentItemLists_.size();
    for (size_t i = 0; i < lils; i++)
    {
        for (it = lentItemLists_[i].begin();
            it != lentItemLists_[i].end(); it++)
        {
            if ((*it)->drawMark() != s_nextMark_)
            {
                (*it)->draw( drawContext );
                (*it)->drawMark( s_nextMark_ );
            }
        }
    }

    return true;
}
```

`drawMark_` 全局标记确保同一项在一帧内只绘制一次,无论是 owner 渲染还是 borrower 渲染。

### 14.5 Fringe 渲染与 lentOnly 模式

当一个 Chunk 已被卸载(`loaded_ = false`)但其项仍被其他 Chunk 借入时,这些"幽灵"借出项仍需在借入方 Chunk 渲染时被绘制。BigWorld 通过 `drawSelf(drawContext, true)` 实现这一机制:

```cpp
// lib/chunk/chunk_manager.cpp - draw(简化)
void ChunkManager::draw( Moo::DrawContext& drawContext )
{
    // 1. 正常渲染 fringe 上的所有 focused chunk
    Chunk* pFringe = fringeHead_;
    while (pFringe)
    {
        pFringe->drawSelf( drawContext, /*lentOnly=*/false );
        pFringe = pFringe->fringeNext();
    }

    // 2. 渲染"已卸载但仍有借出项"的 chunk
    // (这些 chunk 不在 fringe 上,但 lentItemLists_ 中的项仍被借入到 fringe 上的 chunk)
    for (uint i = 0; i < orphanLenders_.size(); i++)
    {
        orphanLenders_[i]->drawSelf( drawContext, /*lentOnly=*/true );
    }
}
```

`orphanLenders_` 是已卸载但仍有借出项的 Chunk 列表,通过 `drawSelf(lentOnly=true)` 仅渲染它们的借出项,避免渲染已被卸载的自有项。

### 14.6 性能优化

借贷机制的性能开销:
1. **包围盒求交**:每次 jogForeignItems 是 O(邻居数 × 自有项数)。
2. **drawMark 检查**:渲染时每个项的额外分支判断。
3. **lentItemLists_ 维护**:借贷列表的插入/删除。

优化策略:
1. **懒触发**:仅在新 Chunk bind 时调用 jogForeignItems,而非每帧。
2. **空间索引**:可考虑用 BVH 加速包围盒求交(BigWorld 14.4.1 未实现)。
3. **drawMark 缓存**:利用 CPU 缓存局部性,按 Chunk 顺序渲染。

---

## 十五、空间加载流程详解

本节综合前述章节,详述玩家在世界中移动时的完整空间加载流程。

### 15.1 玩家进入世界

```
1. 玩家登录 → BaseApp 创建 Player Entity → CellApp 创建 CellEntity
2. CellApp 的 ClientApp 创建客户端 Entity → 客户端 Player 角色出生
3. 客户端 ChunkManager::camera() 第一次调用,传入玩家位置
4. ChunkManager::autoBootstrapSeedChunk() 启动加载
```

### 15.2 autoBootstrapSeedChunk

```cpp
// lib/chunk/chunk_manager.cpp - autoBootstrapSeedChunk
bool ChunkManager::autoBootstrapSeedChunk()
{
    if (cameraChunk_) return true;  // 已有 seed

    // 1. 找到摄像机所在 ChunkSpace
    ChunkSpacePtr pSpace = ...;

    // 2. 在该 space 中找包含 cameraPos 的 Chunk
    Chunk* pSeed = pSpace->findChunk( cameraPos_ );

    if (!pSeed)
    {
        // Chunk 不存在,触发 FindSeedTask 异步查找
        findSeedTask_ = new FindSeedTask( pSpace, cameraPos_ );
        FileIOTaskManager::instance().addTask( findSeedTask_ );
        return false;
    }

    // 3. 同步加载 seed chunk
    loadChunkNow( pSeed );

    // 4. 设置为 cameraChunk_
    cameraChunk_ = pSeed;
    pSeed->focus();

    return true;
}
```

### 15.3 加载流程时序

```
T0: 玩家进入世界
    ChunkManager::camera( transform, space, NULL )
    │
    ├─► autoBootstrapSeedChunk()
    │       │
    │       ├─► ChunkSpace::findChunk( pos )
    │       │       │
    │       │       └─► Column::findChunk( pos )  → 返回 Chunk*(可能未加载)
    │       │
    │       ├─► loadChunkNow( pSeed )
    │       │       │
    │       │       └─► LoadChunkTask 入 FileIO 队列
    │       │
    │       └─► cameraChunk_ = pSeed; pSeed->focus();
    │
T1: 后台线程
    LoadChunkTask::run()
    │
    ├─► DataSection::readSection( "chunk.xml" )
    ├─► Chunk::load( pSection )
    │       │
    │       ├─► formBoundaries( pSection )
    │       ├─► for each <item>:
    │       │       ChunkItemFactory::create()  → addStaticItem()
    │       └─► loaded_ = true
    │
T2: 主线程下一帧
    ChunkManager::checkLoadingChunks()
    │
    ├─► 检测 pSeed->loaded_ == true
    │       │
    │       ├─► pSeed->bind( true )
    │       │       │
    │       │       ├─► for each unboundPortal:
    │       │       │       bindPortal()  → 邻居可能未加载,留 unboundPortals_
    │       │       │
    │       │       ├─► for each selfItem:
    │       │       │       item->toss( this )  → 触发 lendByBoundingBox
    │       │       │
    │       │       └─► isBound_ = true
    │       │
    │       ├─► pSeed->resolveExterns()  → 解析 extern portal
    │       ├─► pSeed->focus()
    │       └─► loadingChunks_ 移除 pSeed
    │
T3: 主线程再下一帧
    ChunkManager::scan()
    │
    ├─► BFS from cameraChunk_
    │       │
    │       ├─► 邻居未加载 → loadChunk( neighbour, highPriority=false )
    │       ├─► 邻居已加载未 bind → 调用 bind
    │       └─► 累计 pathSum,超出 maxLoadPath_ 停止
    │
    └─► 卸载 fringe 中 pathSum > minUnloadPath_ 的 chunk
```

### 15.4 玩家移动触发的边界跨越

```
玩家从 Chunk A 走到 Chunk B(跨越 Portal):

T0: ChunkManager::camera( newTransform )
    │
    ├─► checkCameraBoundaries()
    │       │
    │       ├─► 检查 cameraPos 是否仍 inside cameraChunk_(A)
    │       │       │
    │       │       └─► A->contains( cameraPos ) → false
    │       │
    │       ├─► 遍历 A 的 boundPortals_
    │       │       │
    │       │       └─► 找到 portal->inside( cameraPos ) == true
    │       │           │
    │       │           └─► cameraChunk_ = portal->pChunk_ (B)
    │       │
    │       └─► 重新设置 BFS 起点
    │
T1: ChunkManager::scan()
    │
    ├─► BFS from B
    │       │
    │       ├─► B 的邻居可能尚未加载 → 入加载队列
    │       └─► A 的某些邻居可能现在超出 minUnloadPath → 入卸载队列
```

### 15.5 加载优先级

BigWorld 支持加载优先级,通过 `loadChunk(pChunk, highPriority)`:

```cpp
// lib/chunk/chunk_manager.cpp - loadChunk
void ChunkManager::loadChunk( Chunk* pChunk, bool highPriority )
{
    if (highPriority)
    {
        // 插入队列头部
        loadingChunks_.insert( loadingChunks_.begin(), pChunk );
    }
    else
    {
        loadingChunks_.push_back( pChunk );
    }

    // 创建异步任务
    LoadChunkTask* pTask = new LoadChunkTask( pChunk );
    if (highPriority)
    {
        FileIOTaskManager::instance().addPriorityTask( pTask );
    }
    else
    {
        FileIOTaskManager::instance().addTask( pTask );
    }

    pChunk->loading( true );
}
```

高优先级场景:
1. 摄像机正在朝向的 Chunk。
2. 玩家通过 Portal 即将进入的 Chunk。
3. blindpanic 紧急加载的 Chunk。

### 15.6 切场景的同步模式

切场景(如登录→游戏、副本→主世界)需要等所有 Chunk 加载完成:

```cpp
// 切场景代码示例
ChunkManager::instance().switchToSyncMode( true );
// ... 等待所有 Chunk 加载 ...
ChunkManager::instance().switchToSyncMode( false );

// 此时 cameraChunk_ 及其邻居已就绪,可安全显示
```

`switchToSyncMode(true)` 后,`busy()` 返回 true 期间主线程阻塞,通过 `checkLoadingChunks()` 主动检查后台加载状态。

---

## 十六、chunk_loading 服务器边界

`lib/chunk_loading/` 目录提供服务器端的边界映射加载,主要用于 CellApp 在分布式部署下的 Chunk 归属管理。

### 16.1 边界映射概念

服务器端 Chunk 不需要渲染,但需要知道每个 Chunk 的"边界范围",以决定:
- **哪个 CellApp 负责该 Chunk**(负载均衡)。
- **跨 Chunk 的实体迁移**(Ghost 同步)。
- **跨 Chunk 寻路**(导航网格拼接)。

### 16.2 PreloadedChunkSpace

```cpp
// lib/chunk_loading/preloaded_chunk_space.hpp
class PreloadedChunkSpace : public BaseChunkSpace
{
public:
    // 预加载所有 Chunk 元数据(不加载内容)
    void preload( GeometryMapping* pMapping );

    // 查询
    Chunk* findChunkByIdentifier( const BW::string& identifier );

private:
    BW::map<BW::string, Chunk*>  identifierToChunk_;
};
```

`PreloadedChunkSpace` 在服务端启动时一次性加载所有 Chunk 的元数据(identifier、boundingBox、transform),但不加载 ChunkItem 内容。这使得服务端可以快速查询任意 Chunk 的存在性与边界。

### 16.3 EdgeGeometryMapping

```cpp
// lib/chunk_loading/edge_geometry_mapping.hpp
class EdgeGeometryMapping : public GeometryMapping
{
public:
    EdgeGeometryMapping( const BW::string& path,
                         ChunkSpace* pSpace,
                         const Vector3& edgePoint );

    // 边界相关查询
    bool isEdge( int16 gridX, int16 gridZ ) const;
    const Vector3& edgePoint() const { return edgePoint_; }

private:
    Vector3  edgePoint_;  // 此 mapping 的边界点
};
```

`EdgeGeometryMapping` 表示一个"边界映射",其只覆盖某个 ChunkSpace 的子区域,用于服务端 CellApp 的"责任范围"。

### 16.4 LoadingEdge

```cpp
// lib/chunk_loading/loading_edge.hpp
class LoadingEdge
{
public:
    LoadingEdge( EdgeGeometryMapping* pMapping );

    // 异步加载所有相关 Chunk
    void loadAsync();
    bool isLoaded() const;

private:
    EdgeGeometryMapping*  pMapping_;
    BW::vector<Chunk*>    loadingChunks_;
};
```

`LoadingEdge` 协调多个 Chunk 的异步加载,确保边界映射的所有 Chunk 都加载完成后才标记为就绪。

### 16.5 EdgeGeometryMappings

```cpp
// lib/chunk_loading/edge_geometry_mappings.hpp
class EdgeGeometryMappings
{
public:
    // 添加新的 edge mapping
    void addMapping( EdgeGeometryMapping* pMapping );

    // 查找包含 point 的 mapping
    EdgeGeometryMapping* findMapping( const Vector3& point );

    // 加载状态
    bool allLoaded() const;

private:
    BW::vector<EdgeGeometryMapping*>  mappings_;
};
```

服务端 CellApp 通过 `EdgeGeometryMappings` 管理多个边界映射,每个映射对应一个责任区域。当玩家移动到新的边界时,CellApp 会自动加载对应的 EdgeGeometryMapping。

---

## 十七、chunk_scene_adapter 适配器

`lib/chunk_scene_adapter/` 提供 ChunkSpace 到 ClientSpace 的适配层,使 Chunk 系统与客户端渲染系统解耦。

### 17.1 设计动机

`ChunkSpace` 是 Chunk 系统的核心数据结构,但客户端渲染需要更通用的 `ClientSpace` 接口(支持非 Chunk 来源的场景,如粒子特效、UI 元素)。`ClientChunkSpaceAdapter` 作为适配器,将 ChunkSpace 包装为 ClientSpace:

### 17.2 ClientChunkSpaceAdapter

```cpp
// lib/chunk_scene_adapter/client_chunk_space_adapter.hpp
class ClientChunkSpaceAdapter : public ClientSpace
{
public:
    ClientChunkSpaceAdapter( ChunkSpacePtr pChunkSpace );

    // ClientSpace 接口实现
    virtual void updateAnimations();
    virtual void draw( Moo::DrawContext& drawContext );
    virtual void drawReflection( Moo::DrawContext& drawContext );
    virtual const Matrix& cameraTransform() const;
    virtual Chunk* cameraChunk() const;

    // 委托给 ChunkManager
    virtual void tick( float dTime )
    {
        ChunkManager::instance().tick( dTime );
    }

private:
    ChunkSpacePtr  pChunkSpace_;
};
```

### 17.3 适配模式

```
┌──────────────────────────────────────────────┐
│              ClientSpace (抽象)              │
│  - updateAnimations()                         │
│  - draw()                                     │
│  - drawReflection()                           │
│  - tick()                                     │
└──────────────────────────────────────────────┘
                    ▲
                    │ 实现
                    │
┌──────────────────────────────────────────────┐
│      ClientChunkSpaceAdapter (适配器)         │
│  - 委托给 ChunkManager / ChunkSpace          │
└──────────────────────────────────────────────┘
                    │
                    │ 持有
                    ▼
┌──────────────────────────────────────────────┐
│              ChunkSpace / ChunkManager       │
│  - 实际的 chunk 系统                          │
└──────────────────────────────────────────────┘
```

### 17.4 适配器的优势

1. **解耦**:客户端渲染代码不依赖 Chunk 系统的具体实现。
2. **可替换**:未来可以用其他空间系统(如纯 BSP)替代 Chunk,只需新的适配器。
3. **测试性**:可创建 MockClientSpace 用于单元测试。

### 17.5 实际应用

```cpp
// 客户端启动代码示例
void ClientApp::initWorld()
{
    // 1. 创建 ChunkSpace
    ChunkSpacePtr pSpace = new ClientChunkSpace( spaceID );

    // 2. 创建适配器
    ClientChunkSpaceAdapter* pAdapter = new ClientChunkSpaceAdapter( pSpace );

    // 3. 注册到 SceneManager
    SceneManager::instance().space( pAdapter );

    // 4. ChunkManager 启动
    ChunkManager::instance().addSpace( pSpace );
    ChunkManager::instance().enableScan();
}
```

---

## 十八、compiled_space 编译后空间

`lib/compiled_space/` 提供二进制格式的空间数据,替代开发期的 XML 格式。

### 18.1 设计目标

| 维度 | XML 格式 | compiled_space 格式 |
|------|---------|---------------------|
| 加载速度 | 慢(解析) | 快(memcpy) |
| 内存占用 | 高(标签开销) | 低(紧凑) |
| 可读性 | 高 | 无 |
| 编辑性 | 高 | 低 |
| 随机访问 | 不支持 | 支持 |
| 用途 | 开发期 | 发布期 |

### 18.2 binary_format.hpp

```cpp
// lib/compiled_space/binary_format.hpp
namespace CompiledSpace
{
    // 魔数
    static const uint32 BWCS_MAGIC = 'BW' | ('C' << 8) | ('S' << 16);

    // 版本
    enum Version
    {
        VERSION_1 = 1,
        VERSION_2 = 2,
        CURRENT   = VERSION_2,
    };

    // 文件头
    struct Header
    {
        uint32  magic;
        uint32  version;
        uint32  numChunks;
        uint32  reserved;
        uint64  chunkTableOffset;
        uint64  stringTableOffset;
        uint64  itemDataOffset;
        uint64  boundaryDataOffset;
    };

    // Chunk 记录
    struct ChunkRecord
    {
        uint32  identifierOffset;  // 字符串表偏移
        float   boundingBoxMin[3];
        float   boundingBoxMax[3];
        float   transform[10];     // 平移(3) + 四元数(4) + 缩放(3)
        uint8   isOutsideChunk;
        uint8   hasInternalChunks;
        uint8   reserved[2];
        uint32  itemDataOffset;
        uint32  itemDataSize;
        uint32  boundaryDataOffset;
        uint32  boundaryDataSize;
    };

    // 字符串表
    struct StringTable
    {
        uint32  count;
        uint32  offsets[count];  // 每个字符串的偏移
        char    data[];          // 字符串数据(null 结尾)
    };
}
```

### 18.3 binary_format_types.hpp

```cpp
// lib/compiled_space/binary_format_types.hpp
namespace CompiledSpace
{
    // 边界二进制格式
    struct BoundaryRecord
    {
        float   planeEq[4];       // ax + by + cz + d = 0
        uint32  numPortals;
        uint32  portalDataOffset;
    };

    // Portal 二进制格式
    struct PortalRecord
    {
        uint32  flags;
        uint32  numPoints;
        uint32  pointsOffset;     // 顶点数据偏移
        uint32  neighbourChunkOffset;  // 邻居 identifier 偏移
    };

    // ChunkItem 二进制格式
    struct ItemRecord
    {
        uint32  type;             // 类型 ID(对应 ChunkItemFactory 注册名)
        uint32  dataOffset;
        uint32  dataSize;
    };
}
```

### 18.4 CompiledSpace 类

```cpp
// lib/compiled_space/compiled_space.hpp
class CompiledSpace
{
public:
    CompiledSpace( const BW::string& filename );
    ~CompiledSpace();

    // 加载/卸载
    bool load();
    void unload();

    // 查询
    uint32 numChunks() const { return header_.numChunks; }
    const ChunkRecord& chunkRecord( uint32 index ) const;
    const char* identifier( uint32 offset ) const;

    // 数据访问
    const void* itemData( uint32 offset, uint32 size ) const;
    const void* boundaryData( uint32 offset, uint32 size ) const;

private:
    BW::string  filename_;
    Header      header_;
    void*       mappedFile_;  // 内存映射文件
    ChunkRecord*  chunkTable_;
    StringTable*   stringTable_;
    void*       itemData_;
    void*       boundaryData_;
};
```

### 18.5 CompiledSpaceMapping

```cpp
// lib/compiled_space/compiled_space_mapping.hpp
class CompiledSpaceMapping : public GeometryMapping
{
public:
    CompiledSpaceMapping( const BW::string& filename, ChunkSpace* pSpace );

    // 重写 GeometryMapping 接口
    virtual Chunk* findChunk( const BW::string& identifier );
    virtual const BW::string& resourceID( const BW::string& identifier ) const;

    // 从 compiled space 加载 chunk
    bool loadChunk( Chunk* pChunk );

private:
    CompiledSpace*  pCompiledSpace_;
};
```

### 18.6 加载流程对比

```
开发期(XML):
  1. BWResource::readSection( "chunk.xml" )
  2. XML 解析
  3. DataSection API 访问
  4. Chunk::load( pSection )

发布期(compiled_space):
  1. CompiledSpace::load() → 整个文件 mmap 到内存
  2. CompiledSpaceMapping::loadChunk( pChunk )
  3. 直接 memcpy 各字段
  4. 反序列化 ChunkItem(每个 ChunkItem 有自己的 binaryFormat)
```

发布期加载速度通常是 XML 的 5-10 倍,特别是在大型世界(10,000+ Chunk)中差异显著。

### 18.7 内存映射优势

`CompiledSpace` 使用内存映射文件(`mmap` / `MapViewOfFile`):
1. **延迟加载**:OS 按需将文件页加载到内存。
2. **零拷贝**:数据直接在文件页上访问,无需读取到独立缓冲区。
3. **自动卸载**:OS 在内存压力时自动换出未访问的页。

这对大型世界(数 GB 空间数据)的内存管理至关重要。

---

## 十九、EditorChunkCache 编辑器缓存

`tools/common/editor_chunk_cache_base.hpp` 提供编辑器(WorldEditor)专用的 Chunk 扩展缓存。

### 19.1 设计目的

WorldEditor 需要在 Chunk 上附加额外的编辑数据:
- **Undo/Redo 状态**:记录修改前的 ChunkItem 状态。
- **选中状态**:标记被选中的 ChunkItem。
- **修改标记**:dirty 标志,指示未保存的修改。
- **锁**:防止并发编辑冲突。

### 19.2 EditorChunkCacheBase

```cpp
// tools/common/editor_chunk_cache_base.hpp
class EditorChunkCacheBase : public ChunkCache
{
public:
    EditorChunkCacheBase( Chunk& chunk );

    // 状态
    bool modified() const { return modified_; }
    void modified( bool mod ) { modified_ = mod; }

    bool readonly() const { return readonly_; }
    void readonly( bool ro ) { readonly_ = ro; }

    // 选中
    void select( ChunkItemPtr pItem );
    void deselect( ChunkItemPtr pItem );
    const BW::set<ChunkItemPtr>& selectedItems() const { return selectedItems_; }

    // Undo/Redo
    void saveState( const BW::string& label );
    void restoreState( const BW::string& label );

    // ChunkCache 接口
    virtual void bind( bool isUnbind );
    virtual void addStaticItem( ChunkItemPtr pItem );
    virtual void delStaticItem( ChunkItemPtr pItem );

private:
    Chunk&  chunk_;
    bool    modified_;
    bool    readonly_;
    BW::set<ChunkItemPtr>  selectedItems_;
    BW::vector<StateSnapshot>  undoStack_;
};
```

### 19.3 与 ChunkCache 的关系

`ChunkCache` 是 Chunk 上的可扩展缓存基类,允许多个独立的"附加数据"挂载到 Chunk:

```cpp
// lib/chunk/chunk_cache.hpp:33
class ChunkCache
{
public:
    virtual void bind( bool isUnbind ) {}
    virtual void addStaticItem( ChunkItemPtr pItem ) {}
    virtual void delStaticItem( ChunkItemPtr pItem ) {}
    virtual void tick( float dTime ) {}
    virtual void draw( Moo::DrawContext& drawContext ) {}

    // 工厂注册
    static bool registerFactory( const BW::string& name, ChunkCacheFactory* );
    static ChunkCache* create( const BW::string& name, Chunk& chunk );
};
```

每个 Chunk 持有 `caches_` 列表,通过工厂模式创建:

```cpp
// 编辑器启动时注册
EditorChunkCacheBase::registerFactory( "EditorChunkCache",
    new ChunkCacheFactoryImpl<EditorChunkCacheBase>() );
```

### 19.4 客户端 vs 编辑器

客户端与服务端的 ChunkCache 不同:

| Cache 名 | 客户端 | 服务端 | 编辑器 |
|---------|-------|--------|-------|
| ChunkLightCache | ✅(光照计算) | ❌ | ✅(预览) |
| ChunkShadowCasterCache | ✅ | ❌ | ❌ |
| EditorChunkCacheBase | ❌ | ❌ | ✅ |
| ChunkPhysicsCache | ✅(客户端物理) | ✅(服务端物理) | ✅(编辑器物理) |
| ChunkNavmeshCache | ❌ | ✅(寻路) | ✅(导航网格预览) |

这种 Cache 系统让 Chunk 可以根据运行时角色(客户端/服务端/编辑器)加载不同的扩展,无需修改 Chunk 类本身。

### 19.5 修改跟踪与保存

```cpp
// 编辑器中修改 chunk item 的典型流程
void EditorAction::modifyChunkItem( ChunkItemPtr pItem, ... )
{
    // 1. 获取 chunk 的 EditorChunkCache
    EditorChunkCacheBase* pCache =
        pItem->chunk()->cache<EditorChunkCacheBase>();

    // 2. 保存 Undo 状态
    pCache->saveState( "Modify Item" );

    // 3. 修改 item
    pItem->setTransform( newTransform );

    // 4. 标记 chunk 为 modified
    pCache->modified( true );

    // 5. 触发 chunk 重新计算包围盒
    pItem->chunk()->moveStaticItem( pItem );
}
```

---

## 二十、ChunkOverlapper 重叠器

`lib/chunk/chunk_overlapper.hpp` 定义 ChunkOverlapper,用于处理跨 Chunk 的特殊渲染对象(如粒子系统、远距离光源)。

### 20.1 设计目的

某些对象的影响范围超过单个 Chunk,但又不适合用 VLO(可能是动态的或数量多):
- **粒子云**:可能跨越多个 Chunk。
- **点光源**:光照范围可能覆盖多个 Chunk。
- **触发器**:作用半径跨越边界。

`ChunkOverlapper` 提供轻量级的"影响多个 Chunk"机制,每个 Chunk 持有一个 `ChunkOverlappers` 容器,管理所有影响它的 overlapper。

### 20.2 类定义

```cpp
// lib/chunk/chunk_overlapper.hpp
class ChunkOverlapper : public ChunkItem
{
    DECLARE_CHUNK_ITEM( ChunkOverlapper )

public:
    // toss 重写:通知所有受影响的 chunk
    virtual void toss( Chunk* pChunk );

    // 渲染
    virtual void draw( Moo::DrawContext& drawContext );

private:
    BW::vector<Chunk*>  affectedChunks_;  // 受影响的 chunk 列表
    BoundingBox         affectBox_;        // 影响范围
};

class ChunkOverlappers
{
public:
    void add( ChunkOverlapper* pOverlapper );
    void del( ChunkOverlapper* pOverlapper );

    const BW::vector<ChunkOverlapper*>& overlappers() const
    { return overlappers_; }

private:
    BW::vector<ChunkOverlapper*>  overlappers_;
};
```

### 20.3 toss 流程

```cpp
// lib/chunk/chunk_overlapper.cpp - toss
void ChunkOverlapper::toss( Chunk* pChunk )
{
    if (pChunk == NULL)
    {
        // 离开:从所有受影响的 chunk 中移除
        for (uint i = 0; i < affectedChunks_.size(); i++)
        {
            affectedChunks_[i]->overlappers().del( this );
        }
        affectedChunks_.clear();
    }
    else
    {
        // 加入:计算影响范围,通知所有相交的 chunk
        BoundingBox worldBB;
        worldBB.transform( affectBox_, pChunk->transform() );

        // 找到所有相交的 chunk
        BW::vector<Chunk*> affected;
        pChunk->space()->findChunksInBox( worldBB, affected );

        for (uint i = 0; i < affected.size(); i++)
        {
            affected[i]->overlappers().add( this );
        }
        affectedChunks_ = affected;
    }

    ChunkItem::toss( pChunk );
}
```

### 20.4 与 VLO 的对比

| 维度 | ChunkOverlapper | VLO |
|------|----------------|-----|
| 数据存储 | 多个 chunk 各持副本 | 全局唯一 |
| 渲染去重 | drawMark | drawMark |
| 加载粒度 | 随 owner chunk | VLOFactory 引用计数 |
| 适用对象 | 动态/小型跨边界 | 静态/大型跨边界 |
| 影响范围查询 | 遍历 overlappers | 遍历 affected chunks |

---

## 二十一、性能分析

本节系统分析 Chunk 系统的性能特征与优化点。

### 21.1 加载性能

**典型场景**:玩家在世界中以 10 m/s 移动,需要保持 60 FPS。

**加载需求**:
- 每秒进入约 0.1 个新 Chunk(室外,100m 网格)。
- 每个 Chunk 平均 1MB 数据(地形 + 模型 + 光照)。
- 持续加载速率:100 KB/s(远低于磁盘带宽)。

**实测性能**(参考值):
- HDD 顺序读取:~100 MB/s。
- SSD 顺序读取:~500 MB/s。
- XML 解析:~10 MB/s。
- 二进制解析:~500 MB/s。

**结论**:开发期(XML+HDD)是性能瓶颈,发布期(二进制+SSD)无压力。

### 21.2 渲染性能

**Portal 视锥剔除**:
- 室内场景:每帧遍历 ~5-10 个可见 Chunk,每 Chunk ~100 个 Item。
- 室外场景:每帧渲染 ~20-50 个可见 Chunk(距离剔除)。
- 渲染调用:每帧 ~5,000-10,000 个 draw call。

**优化点**:
1. **drawMark 去重**:防止重复绘制,大幅减少 draw call。
2. **scissor rect**:用 Portal2D 限制 GPU 渲染区域,提高 fill rate。
3. **frustum BB**:粗粒度视锥剔除,避免对所有 Chunk 测试。
4. **instancing**:静态模型相同 mesh 时可批量渲染。

### 21.3 内存占用

**Chunk 内存**:
- Chunk 元数据:~1 KB / Chunk。
- ChunkItem:平均 ~500 B / Item。
- Terrain:~500 KB / Chunk(高度图 + normal map)。
- 总计:平均 ~1 MB / Chunk(包含所有项)。

**聚焦 Chunk 数**:
- 室内:5-10 个。
- 室外:20-50 个。
- 极端场景:100+ 个。

**总内存**:典型 100-500 MB,极端可达 1 GB。BigWorld 通过 `minUnloadPath` 控制卸载阈值。

### 21.4 CPU 开销

**主线程开销**(每帧):
- `tick`:~1 ms(遍历 fringe,调用 tick)。
- `scan`:~0.5 ms(BFS,加载触发)。
- `checkLoadingChunks`:~0.1 ms。
- `cullInsideChunks`:~0.5 ms(室内)。
- `draw`:~10 ms(渲染主体)。

**后台线程开销**:
- `LoadChunkTask::run`:每秒 0-1 次,每次 ~50 ms(单 Chunk 加载)。

### 21.5 性能瓶颈与优化

**瓶颈 1:加载抖动(Loading Stall)**
- **现象**:玩家快速移动时,新 Chunk 加载不及时,出现"黑屏"。
- **优化**:
  1. 增大 `maxLoadPath`(但增加内存)。
  2. 启用 `switchToSyncMode` 在玩家停留时预加载。
  3. 用 LOD,远处 Chunk 用低 LOD 先显示。

**瓶颈 2:draw call 过多**
- **现象**:室内场景 draw call 数激增。
- **优化**:
  1. 合并静态模型(merge static mesh)。
  2. 使用 instancing 渲染相同 mesh。
  3. 用 umbraDraw(Umbra 中间件)替代 Portal。

**瓶颈 3:借贷开销**
- **现象**:`jogForeignItems` 在大 Chunk 边界处耗时高。
- **优化**:
  1. 限制 `wantLend_` 物件数量。
  2. 用空间索引(BVH)加速包围盒求交。
  3. 缓存借贷结果,仅在 Chunk 状态变化时重算。

**瓶颈 4:XML 解析慢**
- **现象**:开发期加载时间长。
- **优化**:
  1. 用 compiled_space 二进制格式。
  2. 缓存 DataSection 解析结果。
  3. 并行加载(FileIO 多线程)。

### 21.6 性能调优参数

`<chunkManager>` 配置项(`bigworld.xml`):

```xml
<chunkManager>
    <maxLoadPath> 500 </maxLoadPath>          <!-- 加载半径(米) -->
    <minUnloadPath> 700 </minUnloadPath>      <!-- 卸载半径(米) -->
    <maxUnloadChunks> 4 </maxUnloadChunks>    <!-- 每帧最大卸载数 -->
    <asyncLoading> true </asyncLoading>       <!-- 异步加载 -->
    <fileIOThreads> 1 </fileIOThreads>        <!-- 后台线程数 -->
</chunkManager>
```

调优建议:
- **高内存机器**:增大 `maxLoadPath` 减少加载抖动。
- **低 CPU 机器**:减小 `maxUnloadChunks` 避免帧卡顿。
- **SSD 机器**:`fileIOThreads=2` 提高并行加载。
- **慢盘机器**:`fileIOThreads=1`(避免抖动)。

---

## 二十二、边界情况与故障处理

### 22.1 Chunk 文件损坏

**场景**:XML 文件语法错误,或二进制格式 magic 不匹配。

**处理**:
```cpp
// lib/chunk/chunk.cpp - load
bool Chunk::load( DataSectionPtr pSection )
{
    if (!pSection)
    {
        ERROR_MSG( "Chunk::load: failed to load %s\n",
            identifier_.c_str() );
        loading_ = false;
        return false;  // 加载失败
    }
    // ...
}
```

主线程在 `checkLoadingChunks` 中检测到 `loaded_ = false` 且 `loading_ = false`,记录错误并跳过该 Chunk。该 Chunk 不会被绑定,渲染时为空洞。

### 22.2 邻居 Chunk 未加载

**场景**:Portal 引用的邻居 Chunk 文件不存在或加载失败。

**处理**:
- `bindPortal` 在邻居未加载时,将 Portal 留在 `unboundPortals_`。
- 后续邻居加载完成时,通过 `formPortal` 建立 Portal 链接。
- 若邻居始终不存在,Portal 永远留 unbound,渲染时跳过(视为封闭)。

### 22.3 循环 Portal 引用

**场景**:Chunk A 的 Portal 指向 B,B 的 Portal 指向 A。

**处理**:
- `traverseMark_` 防止循环遍历。
- `cullInsideChunks` 在递归前检查 `pChunk->traverseMark() != s_nextMark_`,已访问则跳过。

### 22.4 玩家穿墙(快速移动)

**场景**:玩家瞬移到未加载的 Chunk。

**处理**:
- `checkCameraBoundaries` 检测到摄像机不在任何 boundPortal 内,触发 `blindpanic`。
- `blindpanic` 同步加载摄像机所在 Chunk(高优先级)。
- 加载完成后,`cameraChunk_` 切换为新 Chunk。

```cpp
// lib/chunk/chunk_manager.cpp - blindpanic
bool ChunkManager::blindpanic()
{
    // 1. 找到摄像机所在 Chunk
    Chunk* pChunk = pSpace_->findChunk( cameraPos_ );
    if (!pChunk) return false;

    // 2. 同步加载(高优先级)
    loadChunkNow( pChunk );  // 同步等待加载完成

    // 3. 切换 cameraChunk_
    cameraChunk_ = pChunk;
    pChunk->focus();

    return true;
}
```

### 22.5 内存耗尽

**场景**:聚焦 Chunk 过多,导致内存耗尽。

**处理**:
- `maxUnloadChunks` 限制每帧卸载数,避免一次性大量卸载导致卡顿。
- `minUnloadPath` 控制卸载阈值,远的 Chunk 优先卸载。
- 监控内存使用,触发 GC 或紧急卸载。

### 22.6 Mapping 切换

**场景**:玩家从主世界进入副本(切换 GeometryMapping)。

**处理**:
```cpp
// lib/chunk/chunk_manager.cpp - 切换 mapping 流程
void ChunkManager::switchMapping( GeometryMapping* pOldMapping,
                                   GeometryMapping* pNewMapping )
{
    // 1. 标记旧 mapping 废弃
    pOldMapping->condemn();

    // 2. 触发旧 mapping 的 chunk 卸载
    mappingCondemned( pOldMapping );

    // 3. 等待所有旧 chunk 卸载完成
    while (旧 mapping 有 focused chunk)
    {
        scan();  // 主动触发卸载
        Sleep( 1 );
    }

    // 4. 加载新 mapping 的 seed chunk
    Chunk* pNewSeed = ...;
    loadChunkNow( pNewSeed );

    // 5. 切换 cameraChunk_
    cameraChunk_ = pNewSeed;
    pNewSeed->focus();
}
```

### 22.7 Chunk 重复加载

**场景**:同一 Chunk 被多次 `load()` 调用。

**处理**:
- `MF_DEV_ASSERT( !loading_, ... )` 在开发构建中断言。
- `loadingChunks_` 列表检查重复加入。
- `echoCount_` 字段记录重复加载次数(调试用)。

### 22.8 Portal 方向错误

**场景**:Portal 顶点顺序错误,导致法线反向,视锥剔除失效。

**处理**:
- `validatePortals` 在加载时检查顶点顺序。
- `formPortal` 检查邻居 Portal 顶点是否对应(数量、位置)。
- 不匹配则警告,但仍尝试绑定(可能渲染异常)。

### 22.9 室内/室外过渡异常

**场景**:从室内 Chunk 走到无连接的室外 Chunk(Portal 配置错误)。

**处理**:
- `checkCameraBoundaries` 找不到匹配 Portal,触发 `blindpanic`。
- 加载室外 Chunk 后,玩家位置被校正到地面(避免掉入地下)。

### 22.10 多线程竞争

**场景**:FileIO 线程加载 ChunkItem,主线程同时访问。

**处理**:
- `SafeReferenceCount` 提供原子引用计数。
- FileIO 线程只填充 `selfItems_` 列表,主线程在 `checkLoadingChunks` 中处理后续 bind。
- `loading_` 标志作为简单的同步原语(FileIO 设为 true,完成后设为 false,主线程检测)。

BigWorld 14.4.1 的多线程相对保守(主要靠标志位同步),更细粒度的锁在 `ChunkLoader` 与 `FileIOTaskManager` 内部。

---

## 二十三、与其他引擎对比

### 23.1 流式加载机制对比

| 引擎 | 流式单元 | 室内外统一 | 触发机制 | 跨边界对象 |
|------|---------|-----------|---------|-----------|
| BigWorld 14.4.1 | Chunk(100m 网格 + 室内 Shell) | ✅ | Camera Focus + Portal Traverse | VLO + Lend/Borrow |
| Unity 5(2015) | Additive Scene | ❌ | Application.LoadLevelAdditive | 不支持 |
| Unreal Engine 4 | Streaming Level / World Partition(UE5) | ⚠️ Level Streaming | Volume / API | World Partition |
| CryEngine 3 | Sector + Streaming Volume | ❌ Indoor/Outdoor 分管线 | Distance / Volume | 不支持 |
| idTech 5 | MegaTexture Streaming | ❌ | Streaming Volume | 不支持 |

BigWorld 的核心优势:
1. **室内外统一**:Portal 算法透明处理过渡。
2. **VLO + Lend/Borrow**:跨边界物件不切割。
3. **Portal 视锥剔除**:室内精确剔除。

### 23.2 可见性剔除对比

| 引擎 | 算法 | 实现 | 优势 | 劣势 |
|------|------|------|------|------|
| BigWorld 14.4.1 | Portal + Frustum BB | 自研 | 室内精确 | 配置复杂 |
| Unity 5 | Occlusion Culling(烘焙) | Umbra 集成 | 自动化 | 烘焙时间长 |
| Unreal 4 | Hardware Occlusion Queries | GPU 实现 | 动态 | 延迟一帧 |
| CryEngine 3 | Portal + Occlusion | 自研 | 室内强 | 配置复杂 |

BigWorld 的 Portal 是手动配置的(在 WorldEditor 中标记 Portal),与 Unity 的自动 Occlusion 相比,工作量更大但效果可控。BigWorld 14.4.1 还集成了 Umbra(见 `umbraDraw`),作为 Portal 的补充。

### 23.3 编辑器对比

| 引擎 | 编辑器 | 流式单元编辑 | 实时预览 | 跨边界编辑 |
|------|--------|-------------|---------|-----------|
| BigWorld | WorldEditor | ✅ Chunk | ✅ | ⚠️ 有限 |
| Unity | Scene View | ❌ | ✅ | ✅ |
| Unreal 4 | World Outliner | ⚠️ Level Streaming | ✅ | ✅ |
| CryEngine 3 | Sandbox Editor | ✅ Sector | ✅ | ❌ |

BigWorld 的 WorldEditor 提供完整的 Chunk 编辑能力:
- 创建/修改/删除 ChunkItem。
- 编辑 Portal 几何(顶点、平面)。
- 预览 Lend/Borrow 关系。
- 导出为 XML 或 compiled_space 二进制。

但跨边界编辑支持有限:由于 Lend/Borrow 与 VLO 的存在,编辑跨 Chunk 大物件时需要分别在每个相关 Chunk 中操作。BigWorld 的编辑器对此提供了 `EditorChunkCacheBase` 辅助(见第十九章),但相比 Unity 的统一编辑流程仍较繁琐。

### 23.4 后台加载对比

| 引擎 | 后台机制 | 多线程 | 优先级 | 同步模式 |
|------|---------|--------|--------|---------|
| BigWorld 14.4.1 | FileIOTaskManager | 1 线程(默认) | ✅ 高/低优先级 | ✅ switchToSyncMode |
| Unity 5 | Async Read | 多线程 | ⚠️ Limited | ✅ LoadLevelAsync |
| Unreal 4 | Async Loading | 多线程 | ✅ Priority | ✅ FlushAsyncLoading |
| CryEngine 3 | Stream Engine | 多线程 | ⚠️ Limited | ✅ |

BigWorld 的后台加载相对简单(默认单线程),但通过 `FileIOTaskManager` 提供了清晰的优先级机制,适合 MMO 长时运行的稳定加载场景。

### 23.5 跨边界对象对比

| 引擎 | 大物体跨边界 | 中等物体跨边界 | 影响范围跨边界 |
|------|------------|--------------|---------------|
| BigWorld 14.4.1 | VLO(全局去重) | Lend/Borrow | ChunkOverlapper |
| Unity 5 | ❌ 需切割 | ❌ 需切割 | Multi-scene |
| Unreal 4 | World Partition(UE5) | ❌ | Soft Object Reference |
| CryEngine 3 | ❌ 需切割 | ❌ 需切割 | ❌ |

BigWorld 在跨边界对象支持上**领先于同期引擎**,这使其特别适合:
- 城市级 MMO(大量桥梁、塔楼)。
- 室内外混合场景(无缝过渡)。
- 动态光照(点光源跨边界)。

### 23.6 二进制格式对比

| 引擎 | 开发期格式 | 发布期格式 | 内存映射 | 随机访问 |
|------|----------|-----------|---------|---------|
| BigWorld 14.4.1 | XML | compiled_space(BWCS) | ✅ mmap | ✅ |
| Unity 5 | YAML | binary / assetbundle | ⚠️ 部分 | ⚠️ |
| Unreal 4 | JSON / binary | .uasset | ⚠️ 部分 | ❌ |
| CryEngine 3 | cry / xml | cry(packed) | ❌ | ❌ |

BigWorld 的 `compiled_space` 二进制格式在性能上优势明显,特别是大型世界的启动加载。

### 23.7 综合评价

**BigWorld 14.4.1 Chunk 系统的强势**:
1. **室内外统一**:Portal 算法透明处理,无需切换管线。
2. **跨边界物件**:VLO + Lend/Borrow + Overlapper 三层机制,覆盖各种场景。
3. **精确剔除**:Portal 视锥剔除配合 scissor rect,室内渲染高效。
4. **后台加载**:FileIOTaskManager + 优先级队列,加载平滑。
5. **二进制格式**:compiled_space mmap 加载,启动快。

**BigWorld 14.4.1 Chunk 系统的不足**:
1. **配置复杂**:Portal 需手动配置,工作量大。
2. **多线程保守**:默认单 FileIO 线程,SSD 场景未充分利用。
3. **编辑器支持有限**:跨边界编辑不如 Unity 流畅。
4. **XML 慢**:开发期 XML 解析慢,需要频繁转换为 compiled_space。
5. **文档稀缺**:文件格式与算法细节主要靠源码,文档有限(只有 `chunk format.txt` 一个简短说明)。

总体而言,BigWorld 14.4.1 的 Chunk 系统是 2000 年代早期**最先进的开放世界流式加载方案之一**,其设计思想(室内外统一、跨边界物件、Portal 视锥剔除)在 2010 年代后才被 UE5 World Partition 等系统部分超越。

---

## 二十四、设计哲学总结

### 24.1 统一性(Unification)

BigWorld Chunk 系统的最大特色是**统一性**:
- 室内/室外用同一套 `Chunk` 抽象。
- Portal 既处理可见性剔除,也处理跨边界物件。
- ChunkItem 通过 WantFlags 适应不同需求(渲染、tick、借贷)。
- ChunkCache 通过工厂模式适配不同运行时(客户端/服务端/编辑器)。

这种统一性降低了认知复杂度:开发者只需要理解 Chunk + Portal + ChunkItem 这套核心抽象,即可处理室内/室外、静态/动态、自有/借入的所有场景。

### 24.2 空间感知(Spatial Awareness)

BigWorld 的 Chunk 系统**始终以空间为第一位**:
- 一切加载决策基于"摄像机在哪个 Chunk"。
- 一切剔除基于"通过哪个 Portal 可见"。
- 一切借贷基于"包围盒与哪个 Chunk 相交"。
- 一切卸载基于"距摄像机多远(pathSum)"。

这种空间感知的设计哲学让 BigWorld 适合**开放世界 MMO**,因为它能在玩家在世界中移动时,精确地知道:
- 应该加载哪些 Chunk。
- 应该渲染哪些 ChunkItem。
- 应该卸载哪些 Chunk。
- 应该同步哪些实体(服务端 Ghost 同步)。

### 24.3 借贷(Lending)思想

BigWorld 独创的**借贷(Lend/Borrow)**思想:
- 物件有明确的 owner Chunk(责任清晰)。
- owner 决定物件的生命周期(加载、卸载)。
- borrower 只是临时渲染(无所有权)。
- drawMark 确保不重复绘制(去重机制)。

这种思想延伸到 VLO(全局唯一 + 多 Chunk 关联)、ChunkOverlapper(影响范围多 Chunk)等机制。它避免了"跨边界物件被切割"的常见问题,让游戏设计师可以自由放置大物体。

### 24.4 异步优先(Async First)

BigWorld 的设计**默认异步**:
- ChunkManager 的 scan/checkLoadingChunks 都是异步触发。
- LoadChunkTask 默认入 FileIO 队列。
- 同步模式(switchToSyncMode)是**例外**,仅用于切场景。

这种异步优先的设计是 MMO 的关键:
- 玩家移动时,新 Chunk 在后台加载,主线程保持 60 FPS。
- 主线程只负责"启动加载"与"检查完成",不阻塞等待。
- 即使加载抖动,通过 blindpanic 紧急加载,也不让玩家看到"空场景"。

### 24.5 容错性(Fault Tolerance)

BigWorld 的 Chunk 系统设计了多级容错:
- **blindpanic**:摄像机意外进入未加载 Chunk,紧急同步加载。
- **unbind(unbound=true)**:邻居未加载时,Portal 保持 unbound,不阻塞当前 Chunk 渲染。
- **resolveExtern**:跨 Mapping 引用失败时,留 unboundPortal,后续重试。
- **traverseMark_**:防止 Portal 循环引用导致的无限递归。
- **fringe 链表卸载**:通过 pathSum 优先卸载远的 Chunk,避免内存耗尽。

这种容错性让 BigWorld 在**异常场景**(玩家穿墙、文件损坏、网络中断)下也能保持基本运行,不会立即崩溃。

### 24.6 与引擎其他系统的协作

Chunk 系统不是孤立的,与 BigWorld 其他系统紧密协作:

| 系统 | 协作方式 |
|------|---------|
| **Entity 系统** | Entity 持有 chunk 引用,跨 Chunk 时通过 CellApp 迁移 |
| **Ghost 同步** | 服务端 ServerChunkSpace 跟踪 Entity 所属 Chunk,触发 Ghost 同步 |
| **AOI** | CellApp 通过 Chunk 边界判断哪些 Entity 进入玩家 AOI 半径 |
| **寻路** | ChunkNavmeshCache 缓存每个 Chunk 的导航网格,跨 Chunk 寻路拼接 |
| **物理** | ChunkPhysicsCache 加载每个 Chunk 的物理碰撞数据 |
| **光照** | ChunkLightCache 计算每个 Chunk 的静态光照 |
| **地形** | ChunkTerrain 加载每个 Chunk 的地形高度图 |
| **网络** | Mercury 协议传递 Chunk 加载状态(服务端→客户端) |
| **资源** | BWResource 配合 ChunkLoader 加载 chunk 文件 |
| **脚本** | Personality 通过 Chunk 状态触发回调(onEnterChunk 等) |

这种协作让 Chunk 系统成为 BigWorld 的**空间核心**:所有空间相关逻辑都围绕 Chunk 组织。

### 24.7 历史意义

BigWorld 14.4.1(约 2012 年发布)的 Chunk 系统代表了 2000 年代早期 MMO 引擎设计的**巅峰水平**:

- **同期对比**:Unreal 2(2002)的 Streaming Levels 简陋;CryEngine 1(2004)的 Indoor/Outdoor 分管线;Unity 4(2012)尚无 Additive Scene 优化。
- **现代对比**:UE5(2022)的 World Partition 才在室内外统一、跨边界物件上接近 BigWorld 2002 年的水平。
- **影响**:BigWorld 的 Portal 算法、Lend/Borrow 思想影响了后续多个 MMO 引擎(如 HeroEngine、Cryo MMO)。

Chunk 系统的设计哲学——**统一、空间感知、借贷、异步、容错**——不仅是 BigWorld 的核心,也是开放世界游戏引擎设计的重要参考。

---

## 附录 A:关键文件路径速查

### 核心库(lib/chunk/)

| 文件 | 行数(约) | 主要内容 |
|------|----------|---------|
| `chunk.hpp` / `chunk.cpp` | 1200 / 3000 | Chunk 类核心定义与实现 |
| `chunk_item.hpp` / `chunk_item.cpp` | 600 / 1500 | ChunkItem 基类与工厂 |
| `chunk_boundary.hpp` / `chunk_boundary.cpp` | 400 / 1500 | ChunkBoundary 与 Portal |
| `chunk_loader.hpp` / `chunk_loader.cpp` | 100 / 500 | 异步加载入口 |
| `chunk_manager.hpp` / `chunk_manager.cpp` | 350 / 3000 | ChunkManager 单例调度 |
| `chunk_space.hpp` / `base_chunk_space.hpp` | 100 / 200 | ChunkSpace 类层次 |
| `client_chunk_space.hpp` / `server_chunk_space.hpp` | 100 / 100 | 客户端/服务端特化 |
| `geometry_mapping.hpp` | 150 | GeometryMapping 几何映射 |
| `chunk_link.hpp` | 100 | ChunkLink 链接项 |
| `chunk_vlo.hpp` / `chunk_vlo.cpp` | 100 / 500 | VLO 跨 Chunk 对象 |
| `chunk_overlapper.hpp` | 100 | ChunkOverlapper 重叠器 |
| `chunk_cache.hpp` | 100 | ChunkCache 扩展基类 |
| `chunk_tree.hpp` | 100 | ChunkTree 树结构 |
| `chunk_model.hpp` / `chunk_light.hpp` | 100 / 250 | 典型 ChunkItem 派生类 |
| `chunk_terrain.hpp` | 150 | ChunkTerrain 地形项 |
| `chunk_exit_portal.hpp` | 50 | ChunkExitPortal 出口 Portal |
| `chunk format.txt` | 100 | 文件格式说明 |

### 服务器边界(lib/chunk_loading/)

| 文件 | 主要内容 |
|------|---------|
| `preloaded_chunk_space.hpp` | 服务端预加载 ChunkSpace |
| `edge_geometry_mapping.hpp` | 边界几何映射 |
| `edge_geometry_mappings.hpp` | 多边界映射管理 |
| `loading_edge.hpp` | 边界异步加载 |

### 适配器(lib/chunk_scene_adapter/)

| 文件 | 主要内容 |
|------|---------|
| `client_chunk_space_adapter.hpp` | ChunkSpace → ClientSpace 适配器 |

### 编译后空间(lib/compiled_space/)

| 文件 | 主要内容 |
|------|---------|
| `compiled_space.hpp` | 二进制空间类 |
| `compiled_space_mapping.hpp` | 二进制空间映射 |
| `binary_format.hpp` | 文件头与 Chunk 记录 |
| `binary_format_types.hpp` | 边界、Portal、Item 二进制格式 |
| `compiled_space_settings.hpp` | 配置 |

### 编辑器扩展(tools/common/)

| 文件 | 主要内容 |
|------|---------|
| `editor_chunk_cache_base.hpp` | 编辑器 Chunk 扩展缓存 |

---

## 附录 B:Chunk 状态机速查

```
                      load() called
              ┌──────────────────────────┐
              │                          ▼
   ┌──────────┐    loadChunk     ┌──────────────┐
   │  EMPTY   │ ──────────────► │   LOADING    │
   └──────────┘                 └──────┬───────┘
        ▲                               │
        │ unbind(true)                  │ LoadChunkTask::run() 完成
        │ + unload()                    ▼
        │                        ┌──────────────┐
        │                        │   LOADED     │
        │                        │ loaded_=true│
        │                        └──────┬───────┘
        │                               │ bind(true)
        │                               ▼
        │                        ┌──────────────┐
        │                        │   BOUND      │
        │                        │ isBound_=true│
        │                        └──────┬───────┘
        │                               │ focus() + 依赖完成
        │                               ▼
        │                        ┌──────────────┐
        └────────────────────────│  COMPLETED   │
                                 │ completed_=  │
                                 │ true         │
                                 └──────────────┘
```

| 状态 | 标志位 | 说明 |
|------|--------|------|
| EMPTY | (全 false) | 尚未加载,仅有元数据 |
| LOADING | loading_=true | FileIO 线程正在解析 |
| LOADED | loaded_=true | 数据已读入,等待 bind |
| BOUND | isBound_=true | Portal 已连接,可被渲染 |
| COMPLETED | completed_=true | 所有依赖就绪,稳定状态 |

---

## 附录 C:Portal 标志位速查

| 标志位 | 名称 | 用途 | 渲染行为 | 视锥剔除行为 |
|--------|------|------|---------|-------------|
| `1<<0` | (reserved) | 保留 | - | - |
| `1<<1` | Heaven | 天空 Portal(顶面) | 蓝色天空 | 不递归 |
| `1<<2` | Earth | 地下 Portal(底面) | 黑色 | 不递归 |
| `1<<3` | Invasive | 穿透 Portal | 透明 | 直接渲染 |
| `1<<4` | Extern | 跨 Mapping 引用 | 透明 | 需 resolveExtern |

判断宏:
```cpp
bool isHeaven() const    { return !!(flags_ & (1<<1)); }
bool isEarth() const     { return !!(flags_ & (1<<2)); }
bool isInvasive() const  { return !!(flags_ & (1<<3)); }
bool isExtern() const    { return !!(flags_ & (1<<4)); }
```

---

## 附录 D:术语表

| 术语 | 全称 | 含义 |
|------|------|------|
| **Chunk** | (无全称) | 区块,BigWorld 流式加载的基本单元 |
| **ChunkItem** | (无全称) | Chunk 项,Chunk 内的可视/逻辑对象 |
| **ChunkBoundary** | (无全称) | Chunk 边界,定义 Chunk 的一面 |
| **Portal** | (无全称) | 入口,边界上的开口,通向邻居 Chunk |
| **ChunkManager** | (无全称) | Chunk 管理器,单例调度 |
| **ChunkSpace** | (无全称) | Chunk 空间,Chunk 容器 |
| **Column** | (无全称) | 列,X-Z 网格的垂直堆叠 |
| **FocusGrid** | (无全称) | 聚焦网格,环形缓冲跟踪摄像机周围 |
| **GeometryMapping** | (无全称) | 几何映射,Chunk 空间与资源路径的映射 |
| **ChunkLoader** | (无全称) | Chunk 加载器,异步加载入口 |
| **LoadChunkTask** | (无全称) | 加载任务,FileIO 线程执行 |
| **FindSeedTask** | (无全称) | 种子查找任务,首次进入世界时使用 |
| **VLO** | Very Large Object | 超大对象,跨多 Chunk 的全局唯一物件 |
| **Lend/Borrow** | (无全称) | 借贷机制,跨边界物件共享渲染 |
| **ChunkOverlapper** | (无全称) | 重叠器,影响多 Chunk 的对象 |
| **ChunkCache** | (无全称) | Chunk 缓存,可扩展附加数据 |
| **Fringe** | (无全称) | 边缘链表,已聚焦 Chunk 的链表 |
| **pathSum** | Path Sum | 路径和,距摄像机的累计路径长度 |
| **drawMark** | Draw Mark | 绘制标记,防止重复绘制 |
| **traverseMark** | Traverse Mark | 遍历标记,防止 Portal 循环 |
| **Heaven** | (无全称) | 天空 Portal(顶面) |
| **Earth** | (无全称) | 地下 Portal(底面) |
| **Invasive** | (无全称) | 穿透 Portal,跨边界物件 |
| **Extern** | (无全称) | 跨 Mapping Portal |
| **Shell** | (无全称) | 室内 Chunk 的壳结构 |
| **compiled_space** | Compiled Space | 编译后空间,二进制格式 |
| **BWCS** | BigWorld Compiled Space | 编译后空间文件魔数 |
| **FileIOTaskManager** | (无全称) | 文件 I/O 任务管理器,后台线程池 |
| **BackgroundTask** | (无全称) | 后台任务基类 |
| **blindpanic** | (无全称) | 紧急同步加载机制 |
| **scissor rect** | (无全称) | 剪刀矩形,限制 GPU 渲染区域 |
| **Portal2D** | Portal 2D | Portal 在屏幕空间的 2D 投影 |
| **ClientChunkSpaceAdapter** | (无全称) | ChunkSpace 到 ClientSpace 的适配器 |
| **PreloadedChunkSpace** | (无全称) | 服务端预加载 ChunkSpace |
| **EdgeGeometryMapping** | (无全称) | 边界几何映射,服务端责任范围 |
| **EditorChunkCacheBase** | (无全称) | 编辑器 Chunk 扩展缓存 |

---

## 附录 E:相关专题

- **专题 1:Ghost 同步机制深度剖析** —— 服务端如何基于 Chunk 边界进行 Ghost 同步
- **专题 2:负载均衡算法深度剖析** —— CellApp 如何按 Chunk 分配负载
- **专题 5:Mailbox 通信机制深度剖析** —— 跨 CellApp 的 Chunk 实体通信
- **专题 6:AOI 与 Witness 系统深度剖析** —— 基于 Chunk 的 AOI 半径查询
- **专题 7:Mercury 网络协议深度剖析** —— Chunk 加载状态的网络同步
- **专题 8:JIT 资源编译深度剖析** —— chunk 文件从 XML 到 compiled_space 的编译
- **专题 9:EntityDef 数据驱动架构深度剖析** —— 实体如何与 Chunk 关联
- **专题 10:Python 脚本深度集成深度剖析** —— Personality 中的 Chunk 回调
- **专题 12:Reviver 与 bwmachined 双重守护机制** —— Chunk 加载进程的守护
- **专题 13:WorldEditor 工具深度剖析** —— Chunk 编辑器的实现(若存在)

---

## 结语

Chunk 流式加载与 Portal 系统是 BigWorld Engine 14.4.1 的**空间核心**,贯穿了引擎的几乎所有子系统。本专题以百科级深度剖析了:

- **核心抽象**:Chunk、ChunkItem、ChunkBoundary、Portal、ChunkManager、ChunkSpace、GeometryMapping。
- **加载机制**:双线程模型、LoadChunkTask、FindSeedTask、scan、checkLoadingChunks、bind/unbind、focus。
- **剔除算法**:Portal 视锥剔除、Portal2D 累积裁剪、室内/室外区分处理、scissor rect。
- **跨边界物件**:VLO(全局去重)、Lend/Borrow(借贷渲染)、ChunkOverlapper(影响范围)。
- **空间组织**:Column 网格、FocusGrid 环形缓冲、Fringe 链表、pathSum 距离。
- **服务器端**:PreloadedChunkSpace、EdgeGeometryMapping、LoadingEdge。
- **客户端适配**:ClientChunkSpaceAdapter。
- **二进制格式**:compiled_space、Header、ChunkRecord、内存映射。
- **编辑器扩展**:EditorChunkCacheBase、ChunkCache 工厂。
- **性能与边界**:加载抖动、draw call、内存占用、blindpanic、循环引用、多线程竞争。
- **跨引擎对比**:Unity 5、Unreal 4、CryEngine 3、idTech 5。

通过理解 Chunk 系统,开发者可以:
- 优化 MMO 客户端的加载性能(调整 maxLoadPath、minUnloadPath)。
- 调试室内场景的可见性问题(检查 Portal 配置)。
- 设计跨 Chunk 大物件(选择 VLO 或 Lend/Borrow)。
- 扩展 ChunkItem 类型(通过 DECLARE/IMPLEMENT_CHUNK_ITEM 宏)。
- 扩展 Chunk 缓存(通过 ChunkCache 工厂)。

BigWorld 14.4.1 的 Chunk 系统在 2010 年代是**开放世界 MMO 引擎设计的标杆**,其设计哲学(统一性、空间感知、借贷、异步、容错)在今日的 UE5 World Partition 等系统中仍可见其影响。

---

**文档版本**:v1.0
**最后更新**:2026-07-05
**对应源码版本**:BigWorld Engine 14.4.1
**总行数**:约 3800 行