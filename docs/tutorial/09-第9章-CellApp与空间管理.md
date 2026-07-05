# 第9章 CellApp 与空间管理

> 第 7 章我们鸟瞰了整个服务器集群,第 8 章我们看完了集群"管家" bwmachined。从本章起,我们正式进入 BigWorld 的"数据平面"。在所有数据平面进程里,**CellApp(空间应用)** 是最复杂、最有 BigWorld 特色的一类——它要同时承担"实体模拟"、"空间分割"、"跨进程透明边界"、"客户端可见性筛选"四件事,这四件事在普通单进程游戏服务器里通常都是合在一起的,而在 BigWorld 中被拆解成了一套精巧的并行架构。本章将带你逐步看懂 CellApp 的内部世界:Cell、Ghost、AOI、Witness、Controller 这五大核心概念,以及它们如何在 CellApp 三阶段异步初始化与每个 tick 中协同工作。

---

## 目录

- [9.1 CellApp 概述](#91-cellapp-概述)
- [9.2 源码结构全景](#92-源码结构全景)
- [9.3 Cell 概念详解](#93-cell-概念详解)
- [9.4 Ghost 实体](#94-ghost-实体)
- [9.5 AOI 兴趣区域](#95-aoi-兴趣区域)
- [9.6 Witness 与可见性控制](#96-witness-与可见性控制)
- [9.7 空间管理:Space 与 Cell 分配](#97-空间管理space-与-cell-分配)
- [9.8 CellApp 三阶段异步初始化](#98-cellapp-三阶段异步初始化)
- [9.9 实体生命周期](#99-实体生命周期)
- [9.10 控制器系统](#910-控制器系统)
- [9.11 特色实现深度剖析](#911-特色实现深度剖析)
- [9.12 本章小结](#912-本章小结)

---

## 9.1 CellApp 概述

### 9.1.1 它是什么

**CellApp** 是 BigWorld 集群中负责"空间实体计算"的进程。每个 CellApp 进程:

- 持有一组 **Cell**(空间分区),每个 Cell 是某个 Space 在该 CellApp 上的一个矩形/BSP 叶子区域;
- 在每个 Cell 上运行一批 **Entity**(游戏实体),这些 Entity 可能是 **Real**(真实)或 **Ghost**(影子);
- 维护一份基于距离的 **AOI**(Area Of Interest)索引,用于决定哪些实体对某个客户端可见;
- 拥有若干 **Witness**(见证者),即"挂着客户端"的 Real 实体,Witness 负责把可见实体的状态打包发给对应 BaseApp 再转给客户端;
- 通过 **CellAppChannel** 与其他 CellApp 互通,完成跨 Cell 边界的实体迁移、Ghost 同步、tick 完成通知等。

一个集群里可以同时跑多个 CellApp 进程(水平扩展),它们的协作由单例进程 **CellAppMgr**(详见第 19 章)统一调度。CellAppMgr 是控制平面,CellApp 是数据平面。

### 9.1.2 数据平面 vs 控制平面

| 维度 | CellAppMgr(控制平面) | CellApp(数据平面) |
|------|----------------------|--------------------|
| 数量 | 单例 | 多实例,水平扩展 |
| 是否持有实体 | 否 | 是 |
| 主要职责 | CellApp 生命周期管理、Space/Cell 边界划分(BSP)、负载均衡、TimeKeeper | 实体模拟、AOI、Witness、跨 Cell 协作 |
| 是否参与 tick | 调度 tick | 每个 tick 真实跑业务 |
| 与对方通信 | 通过 `CellAppInterface` 给 CellApp 发指令 | 通过 `CellAppMgrGateway` 上报负载、请求边界变更 |

这种分离让 CellApp 可以线性扩容:玩家多了就加机器跑更多 CellApp,CellAppMgr 永远只有一个,不会成为业务瓶颈。

### 9.1.3 与其他进程的关系

```
                  ┌─────────────┐
                  │ bwmachined  │  birth/death 监听
                  └──────┬──────┘
                         │
                         ▼
   ┌──────────┐   ┌──────────┐         ┌──────────┐
   │CellAppMgr│◄──┤ CellApp  │◄───────►│ BaseApp  │
   │ (单例)   │   │ (本进程) │  backup │ (Real   │
   └──────────┘   └────┬─────┘  data   │  Base)  │
                        │                └────┬────┘
                        │                     │ sendToClient
                        ▼                     ▼
                  ┌──────────┐          ┌──────────┐
                  │ DBApp    │          │  Client  │
                  │ (Alpha)  │          └──────────┘
                  └──────────┘
```

- 向 **CellAppMgr** 上报负载、边界、接收 addCell 指令;
- 向 **BaseApp** 发送 backup 数据(实体的备份快照);
- 通过 **BaseApp** 把客户端更新转发给真实客户端;
- 从 **DBApp Alpha** 申请 EntityID(IDClient)。

---

## 9.2 源码结构全景

CellApp 的源码全部位于 `programming/bigworld/server/cellapp/`,共约 130 个文件。按职责可以分为 9 组:

```
server/cellapp/
├── 主程序与配置
│   ├── main.cpp                    # 入口, bwMainT<CellApp>(argc, argv)
│   ├── cellapp.cpp/.hpp/.ipp       # CellApp 单例类,本章主角
│   ├── cellapp_config.cpp/.hpp     # CellAppConfig 配置项
│   └── cellapp_interface.cpp/.hpp  # CellAppInterface 消息定义
│
├── 空间与分区
│   ├── space.cpp/.hpp              # Space 逻辑空间(可跨多 CellApp)
│   ├── spaces.cpp/.hpp            # Spaces 集合
│   ├── space_node.hpp             # BSP 节点基类
│   ├── space_branch.cpp/.hpp      # BSP 内部节点(分割平面)
│   ├── cell.cpp/.hpp/.ipp         # Cell 单个分区(本 CellApp 视角)
│   ├── cells.cpp/.hpp             # Cells 集合
│   ├── cell_info.cpp/.hpp         # CellInfo (BSP 叶子,持有 addr 与 rect)
│   ├── cell_range_list.cpp/.hpp   # Cell 用 RangeList 索引
│   └── physical_chunk_space.cpp   # PhysicalChunkSpace (Chunk 集成)
│
├── 实体
│   ├── entity.cpp/.hpp/.ipp       # Entity(本章另一主角)
│   ├── entity_type.cpp/.hpp       # EntityType 类型系统
│   ├── entity_population.cpp/.hpp # EntityPopulation 全局实体表
│   ├── entity_cache.cpp/.hpp      # EntityCache(AOI 缓存条目)
│   ├── entity_range_list_node.*    # Entity 在 RangeList 中的节点
│   ├── mobile_range_list_node.*    # 可移动节点(AoI root)
│   ├── real_entity.cpp/.hpp       # RealEntity(Real 时附加状态)
│   └── real_caller.cpp/.hpp       # 转发到 Real 的辅助
│
├── Ghost 机制
│   ├── entity_ghost_maintainer.*   # EntityGhostMaintainer 维护某实体的所有 Ghost
│   ├── offload_checker.*          # OffloadChecker 检查 offload 与 ghost 增删
│   ├── buffered_ghost_message*    # 跨 CellApp 消息缓冲(防止乱序)
│   └── ack_cell_app_death_helper.*# 死亡 ACK 同步
│
├── AOI / Witness
│   ├── witness.cpp/.hpp           # Witness 玩家观察代理
│   ├── range_list_node.*          # RangeList 节点(双向链表索引)
│   ├── range_trigger.*            # RangeTrigger(进入/离开范围触发)
│   ├── range_list_appeal_trigger.*# AppealRadius 触发器
│   ├── aoi_update_schemes.cpp/.hpp# AoIUpdateScheme 优先级方案
│   ├── entity_vision.cpp/.hpp     # 实体视觉相关辅助
│   └── py_client.cpp/.hpp         # PyClient (向客户端发消息的 Python 接口)
│
├── 控制器(Controller)
│   ├── controller.cpp/.hpp        # Controller 基类
│   ├── controllers.cpp/.hpp       # Controllers 集合(每实体一个)
│   ├── move_controller.*          # MoveController / MoveToPoint / MoveToEntity
│   ├── navigation_controller.*   # 导航控制器
│   ├── navmesh_navigation_system.*# Navmesh 导航系统
│   ├── turn_controller.*          # YawRotatorController
│   ├── timer_controller.*         # TimerController
│   ├── vision_controller.*        # VisionController(可见性查询)
│   ├── visibility_controller.*    # VisibilityController(被看见控制)
│   ├── scan_vision_controller.*   # ScanVisionController(扫描视觉)
│   ├── proximity_controller.*    # ProximityController(陷阱/触发器)
│   ├── accelerate_*_controller.*  # 加速度系列控制器
│   ├── face_entity_controller.*   # FaceEntityController
│   ├── passenger_controller.*     # PassengerController(载具乘客)
│   └── portal_config_controller.*# Portal 开关控制器
│
├── CellApp 间通信
│   ├── cell_app_channel.cpp/.hpp  # CellAppChannel(单条连接)
│   ├── cell_app_channels.cpp/.hpp # CellAppChannels 集合(Singleton)
│   ├── cell_app_channels          # 定时 flush 通道
│   ├── cell_viewer_server.*       # CellViewerServer watcher 接入
│   └── cell_viewer_connection.*  # 单个 watcher 连接
│
├── 与 BaseApp / DBApp 协作
│   ├── mailbox.cpp/.hpp           # 实体的 BaseApp mailbox
│   ├── cellappmgr_gateway.*       # 到 CellAppMgr 的封装
│   ├── add_to_cellappmgr_helper.hpp# 注册到 CellAppMgr 的辅助
│   └── id_config.cpp/.hpp         # IDClient 配置
│
└── 其他
    ├── profile.cpp/.hpp           # CellProfiler / EntityProfiler
    ├── cell_profiler.cpp/.ipp     # Cell 级性能采集
    ├── history_event.cpp/.ipp     # EventHistory(实体事件历史)
    ├── replay_data_collector.*    # 录像采集
    ├── emergency_throttle.*      # 紧急限流
    ├── throttle_config.*         # 限流配置
    ├── noise_config.*             # 噪声/隐身配置
    └── py_entities.cpp/.hpp      # Python 暴露的 BigWorld.entities
```

理解 CellApp 的主线有两条:

1. **空间线**:Space → Cell → CellInfo → BSP 树,描述世界如何被分割;
2. **实体线**:Entity → RealEntity / Ghost → Controllers → Witness,描述实体如何被模拟、迁移、对客户端可见。

下面我们先看空间线,再看实体线,最后把两者在 tick 里串起来。

---

## 9.3 Cell 概念详解

### 9.3.1 什么是 Cell

**Cell** 是 BigWorld 空间的"分区单位"。一个 Cell 在地理上是一个矩形区域(`BW::Rect rect_`),它对应某个 Space 在某个 CellApp 上的副本。

```
                    Space #1 (跨 4 个 CellApp)
   ┌────────────────────────────────────────────┐
   │                  │                          │
   │   Cell on App#1  │   Cell on App#2         │
   │                  │                          │
   ├──────────────────┼──────────────────────────┤
   │                  │                          │
   │   Cell on App#3  │   Cell on App#4         │
   │                  │                          │
   └────────────────────────────────────────────┘
```

注意几个关键概念:

- **CellAppMgr 视角**:Space 是一棵 BSP 树,每个叶子叫 `CellData`,记录"这个矩形区域归哪个 CellApp 管";
- **CellApp 视角**:Space 里维护一棵 `CellInfo` BSP 树(从 CellAppMgr 同步过来),本 CellApp 只对其中"addr == 自己"的叶子创建真正的 `Cell` 对象;
- 一个 CellApp 可以同时持有多个 Cell(同一 Space 的多个分区,或不同 Space 的分区)。

### 9.3.2 Cell 类签名

`cell.hpp` 中 `Cell` 类的核心字段:

```cpp
// server/cellapp/cell.hpp
class Cell
{
public:
    Cell( Space & space, const CellInfo & cellInfo );

    void offloadEntity( Entity * pEntity, CellAppChannel * pChannel,
            bool isTeleport = false );
    void addRealEntity( Entity * pEntity, bool shouldSendNow );
    EntityPtr createEntityInternal( BinaryIStream & data,
            const ScriptDict & properties, bool isRestore = false, ... );

    bool checkOffloadsAndGhosts();

    const BW::Rect & rect() const  { return pCellInfo_->rect(); }
    Space & space()                { return space_; }
    Entities & realEntities();

    bool shouldOffload() const;
    void retireCell( BinaryIStream & data );
    void removeCell( BinaryIStream & data );

private:
    Entities realEntities_;       // 该 Cell 上的 Real 实体集合
    bool shouldOffload_;          // 是否参与 offload
    bool isRetiring_;              // 是否在退役
    bool isRemoved_;
    Space & space_;
    ConstCellInfoPtr pCellInfo_;  // 指向 Space 维护的 CellInfo
    StoppingState stoppingState_;
    CellProfiler profiler_;
    // ...
};
```

注意 `Cell` 持有的是 `ConstCellInfoPtr`——`CellInfo` 由 Space 持有,Cell 只读取它的 `rect()` 与 `addr()`。这种"数据归属 Space、行为在 Cell"的拆分,让 CellAppMgr 重新划分边界(BSP 重平衡)时,Space 只需要替换 `CellInfo` 树,旧 Cell 自然进入 retiring,新 Cell 自然创建,互不干扰。

### 9.3.3 Cell 的创建

CellApp 通过 `CellApp::addCell` 消息接收 CellAppMgr 发来的分区指令(`cellapp.cpp:1513`):

```cpp
void CellApp::addCell( const Mercury::Address & srcAddr,
        const Mercury::UnpackedMessageHeader & header,
        BinaryIStream & data )
{
    SpaceID spaceID;
    data >> spaceID;

    Space * pSpace = this->findSpace( spaceID );
    if (pSpace) {
        pSpace->reuse();                  // 复用已存在的 Space
    } else {
        pSpace = pSpaces_->create( spaceID );  // 新建 Space
    }

    pSpace->updateGeometry( data );       // 更新 BSP 树

    CellInfo * pCellInfo = pSpace->findCell( interface_.address() );
    if (pCellInfo) {
        Cell * pNewCell = new Cell( *pSpace, *pCellInfo );
        cells_.add( pNewCell );            // 加入本 CellApp 的 Cells 集合
    }
}
```

这里的关键是 `pSpace->updateGeometry(data)`——CellAppMgr 把整棵 BSP 树序列化发过来,Space 解析后更新自己的 `pCellInfoTree_`。然后本 CellApp 在树里查找"addr == 自己"的叶子,为它创建真正的 `Cell`。

### 9.3.4 Cell 的销毁与退役

CellAppMgr 通过两类消息让一个 Cell 退役:

- `retireCell`:Cell 进入 `isRetiring_=true` 状态,不再接受新实体创建,等所有 Real 实体 offload 走后自然消失;
- `removeCell`:强制销毁,通常用于 Space 整体卸载。

退役中的 Cell 仍然参与 tick,直到 `isReadyForDeletion()` 返回 true(所有 Real 都已 offload 且所有 Ghost 都已删除)。`checkOffloadsAndGhosts()` 的返回值就是 `isReadyForDeletion()`,CellApp 在每次 `checkOffloads` 调用中检查它,返回 true 时把 Cell 从 `cells_` 中移除。

### 9.3.5 Cell 边界与 Portal

Cell 的边界是 BSP 树的分割平面。Cell 与邻居 CellApp 之间通过 **CellAppChannel** 通信——每个邻居一个 channel,channel 上跑的消息包括 `createGhost`、`delGhost`、`ghostPositionUpdate`、`ghostSetReal`、`onload`、`onRemoteTickComplete` 等。

注意"Portal"在 BigWorld 中有两个含义:

1. **Chunk Portal**:室内场景(Chunk)之间的连接(详见第 10 章资源系统);
2. **CellApp Portal**:跨 CellApp 边界的逻辑邻接关系,通常没有专门的类,而是通过 `EntityGhostMaintainer::visit()` 遍历 BSP 树叶子自动发现。

本章主要关注第 2 种。第 1 种由 `portal_config_controller.hpp` 控制其开关,允许脚本动态关闭某条室内通道。

---

## 9.4 Ghost 实体

### 9.4.1 Ghost 是什么

**Ghost** 是 BigWorld 最具特色的设计之一。一个 Real 实体持有完整状态(所有 REAL 域属性、Witness、Controllers),而一个 Ghost 实体只持有 GHOST 域属性——它只是 Real 的"投影"。

在 `entity.hpp` 中可以看到,Ghost 与 Real 共用同一个 `Entity` 类:

```cpp
class Entity : public PyObjectPlus
{
    // ...
    RealEntity * pReal_;     // 关键字段:Real 时非 NULL,Ghost 时为 NULL

    bool isReal() const;      // 等价于 pReal_ != NULL
    bool isRealToScript() const;
    CellAppChannel * pRealChannel_;   // Ghost 持有指向 Real 所在 CellApp 的通道
    Mercury::Address nextRealAddr_;   // Real 即将迁移到的新地址
};
```

判断一个 Entity 是 Real 还是 Ghost 的唯一标准就是 `pReal_` 是否为 NULL。这套"同一类两种角色"的设计让脚本层几乎无感——Ghost 上调用 `entity.position` 一样能拿到位置(只是不可写),调用 `entity.client.method()` 也会被自动转发到 Real。

### 9.4.2 Ghost 的产生时机

Ghost 不是凭空创建的,它由 Real 实体"显式制造"——每当一个 Real 实体的 AOI 区域(以 `ghostDistance` 为半径的矩形)与某个邻居 Cell 的矩形相交,Real 就在该邻居 Cell 上创建一个 Ghost。这个判定在每个 tick 的 `checkOffloads` 阶段进行:

```
   Real Entity 所在 Cell (CellApp A)         邻居 Cell (CellApp B)
   ┌──────────────────────────┐              ┌──────────────────────────┐
   │                          │              │                          │
   │     ★ Real Entity        │              │   ○ Ghost Entity         │
   │     持有完整状态          │   create     │   只有 GHOST 域属性      │
   │     (pReal_ != NULL)     │ ──────────►  │   (pReal_ == NULL)       │
   │                          │   Ghost      │   pRealChannel_ → A      │
   │                          │              │                          │
   └──────────────────────────┘              └──────────────────────────┘
                  ▲                                       │
                  │                                       │
                  └─────── ghostPositionUpdate ◄──────────┘
                       (每个 tick 同步位置)
```

具体逻辑在 `entity_ghost_maintainer.cpp`:

```cpp
void EntityGhostMaintainer::createOrUnmarkRequiredHaunts()
{
    static const float GHOST_FUDGE = 20.f;

    const Vector3 & position = pEntity_->position();
    BW::Rect interestArea( position.x, position.z, position.x, position.z );

    // 实体的 appealRadius 也要算进来(大实体的 Ghost 范围更大)
    interestArea.inflateBy( CellAppConfig::ghostDistance() +
            pEntity_->pType()->description().appealRadius() );

    hysteresisArea_ = interestArea;
    interestArea.inflateBy( GHOST_FUDGE );   // 滞回区域,避免边界抖动

    pEntity_->space().visitRect( interestArea, *this );  // 遍历 BSP 树叶子
}

void EntityGhostMaintainer::visit( CellInfo & cellInfo )
{
    if (cellInfo.addr() == ownAddress_) return;          // 跳过自己
    if (cellInfo.isDeletePending()) return;

    CellAppChannel & channel = *CellAppChannels::instance().get( cellInfo.addr() );

    if (channel.mark() == 1) {            // 已有 Ghost,只需 unmark
        channel.mark( 0);
        return;
    }

    if (!cellInfo.rect().intersects( hysteresisArea_ )) return;  // 滞回检查

    pEntity_->pReal()->addHaunt( channel );
    pEntity_->createGhost( channel.bundle() );     // 在 bundle 上写 createGhost 消息
}
```

注意几个细节:

- **`GHOST_FUDGE = 20.f`**:滞回区(fudge),避免实体在边界附近来回穿越导致 Ghost 反复创建/删除;
- **`appealRadius`**:大型实体(NPC boss、城门等)的"吸引力半径",会让它的 Ghost 出现在更远的 Cell 上;
- **`channel.mark()`**:每轮检查开始时所有 haunt 都被 mark=1,然后 unmark 仍然需要的,最后剩下 mark=1 的就是应该删除的——经典的"标记-清扫"思路。

### 9.4.3 Real 与 Ghost 的转换

Real → Ghost 的转换在 `Entity::convertRealToGhost`(`entity.cpp:2005`):

```cpp
void Entity::convertRealToGhost( BinaryOStream * pStream,
        CellAppChannel * pChannel, bool isTeleport )
{
    MF_ASSERT( this->isReal() );
    MF_ASSERT( !pRealChannel_ );

    Entity::callbacksPermitted( false );

    if (pChannel != NULL) {
        // offload 路径:把 Real 数据写到流,发到目标 CellApp
        this->writeRealDataToStream( *pStream, isTeleport );
        pRealChannel_ = pChannel;
        nextRealAddr_ = pRealChannel_->addr();
        this->offloadReal();              // 销毁本地的 RealEntity
    } else {
        // 销毁路径:实体要被 destroy 了
        this->destroyReal();
    }

    // 把 Real-only 属性从 properties_ 里裁掉,只保留 GHOST 域
    properties_.erase( properties_.begin() + pEntityType_->propCountGhost(),
        properties_.end() );

    this->relocated();
    Entity::callbacksPermitted( true );
}
```

Ghost → Real 的转换在 `Entity::convertGhostToReal`(`entity.cpp:4657`),逻辑相反:从流里读 Real 属性,创建 RealEntity,启动 Real 控制器,把实体加入 `cell.realEntities_`。

### 9.4.4 Ghost 的消息路由

Ghost 上调用脚本方法时,消息会被转发到 Real。`Entity::forwardMessageToReal`(`entity.hpp`)就是把消息打包发到 `pRealChannel_` 的 bundle 上:

```cpp
// server/cellapp/entity.cpp
// 如果 Ghost 上调用了 client.method(...)
// 会被转发到 Real,由 Real 的 Witness 决定怎么发给客户端
```

而 Real → Ghost 的同步是单向的:Real 在每个 tick 把自己的位置、属性变更、控制器变更打包成 `ghostPositionUpdate`、`ghostedDataUpdate`、`ghostHistoryEvent`、`ghostControllerCreate` 等消息,通过 haunt 的 `CellAppChannel` 发给所有 Ghost。

为了防止"Ghost 还没创建好,但 Real 已经发了位置更新"这种乱序,BigWorld 引入了 **BufferedGhostMessages** 机制(`buffered_ghost_message.hpp`):任何到达 Ghost 但 Ghost 还没存在的消息,会被缓存起来,等 Ghost 创建后再 replay。这是一个经典的"延迟消息处理"模式。

---

## 9.5 AOI 兴趣区域

### 9.5.1 AOI 是什么

**AOI**(Area Of Interest,兴趣区域)是 MMOG 的核心概念:每个玩家只关心自己周围一小块区域里的实体,不需要知道全服所有实体的状态。BigWorld 的 AOI 实现有两个层次:

1. **Cell 间层**:用 Ghost 实现跨 CellApp 边界可见性(见 9.4);
2. **Cell 内层**:用 RangeList 索引和 RangeTrigger 实现"哪些实体进入/离开我的 AoI 半径"。

本节讨论第二层。

### 9.5.2 RangeList:基于双向链表的索引

`RangeList` 是 CellApp 内部最快的实体索引结构。它的核心思想是:

- 每个 Entity 在 X 轴和 Z 轴上各有一个 `RangeListNode`;
- 所有节点在 X 轴和 Z 轴上各组成一条**按坐标排序的双向链表**;
- 当一个实体移动时,只需要在两条链表上"挪一挪"位置(`shuffleXThenZ`),就能保持有序;
- 任何 RangeTrigger(范围触发器)想知道"谁在我周围",只需要在链表上向前向后扫一段即可。

`RangeListNode`(`range_list_node.hpp`)的字段:

```cpp
class RangeListNode
{
    // X 轴前驱/后继,Z 轴前驱/后继
    RangeListNode * pPrevX_, * pNextX_, * pPrevZ_, * pNextZ_;

    // 这个节点"想要"的 crossing 类型(LOWER_AOI_TRIGGER 等)
    RangeListFlags wantsFlags_;
    // 这个节点"产生"的 crossing 类型(IS_ENTITY 等)
    RangeListFlags makesFlags_;
    // 排序用的 order(实体 100,AOI lower bound 190,upper bound 200...)
    RangeListOrder order_;
};
```

`wantsFlags_` 与 `makesFlags_` 的位掩码机制很巧妙:当两个节点在链表上交叉(谁超过谁)时,会检查 `wantsFlags_ & other->makesFlags_`,如果非零就触发 `crossedX` / `crossedZ` 回调。比如一个 AoI lower bound 节点(wantsFlags = `FLAG_ENTITY_TRIGGER`)与一个实体节点(makesFlags = `FLAG_IS_ENTITY`)交叉时,AoI 触发器就会收到回调。

### 9.5.3 AoI 范围设置

每个 Witness 持有一个 `AoITrigger`,它是 RangeTrigger 的子类,包含两个边界节点(upper 与 lower)。当实体进入这个范围时,`triggerEnter` 被调用,Witness 把实体加入 AoI;离开时 `triggerLeave` 被调用,Witness 把实体移出 AoI。

`Witness::setAoIRadius`(`witness.cpp:2109`):

```cpp
void Witness::setAoIRadius( float radius, float hyst )
{
    radius = std::max( 0.1f, radius );
    aoiHyst_   = hyst;
    aoiRadius_ = radius;

    if (aoiRadius_ > CellAppConfig::maxAoIRadius()) {
        WARNING_MSG( "Witness::setAoIRadius: Clamping %u's AoI radius (%.1f) "
            "to the maximum allowed value (%.1f)\n", ... );
        aoiRadius_ = CellAppConfig::maxAoIRadius();
    }

    pAoITrigger_->setRange( aoiRadius_ );    // 更新两个边界节点的距离
    entity_.modTrigger( pAoITrigger_ );      // 通知 RangeList 重新洗牌
}
```

注意 `aoiHyst_`——**滞回区域**。实体进入 AoI 用 `aoiRadius_`,但离开 AoI 要等到走出 `aoiRadius_ + aoiHyst_`。这避免了实体在 AoI 边界附近抖动时反复触发 enter/leave,这是 MMOG 中非常经典的优化。

### 9.5.4 AoIUpdateScheme:更新优先级

不是所有在 AoI 里的实体都需要每 tick 更新——远处的实体可以每 5 tick 更新一次,近处的实体每 tick 都更新。`AoIUpdateScheme`(`aoi_update_schemes.hpp`)定义了这个优先级:

```cpp
class AoIUpdateScheme
{
public:
    double apply( float distanceSquared ) const
    {
        if (this->shouldTreatAsCoincident()) return 1.0;
        const float distance = sqrtf( distanceSquared );
        return (distance * distanceWeighting_ + 1.f) * weighting_;
    }
private:
    float weighting_;
    float distanceWeighting_;
};
```

每个 EntityCache 在 Witness 的优先级队列里都有一个 `priority_` 值,每 tick 通过 `Witness::update` 中的 `make_heap / pop_heap` 选出当前最该更新的实体,发到客户端。这就实现了**带宽自适应的 LOD**(Level of Detail):远处少更新,近处多更新。

`EntityCache`(`entity_cache.hpp`)的字段反映了这个机制:

```cpp
class EntityCache
{
    Priority    priority_;              // 当前优先级
    Priority    lastPriorityDelta_;     // 上次优先级变化量
    EventNumber lastEventNumber_;       // 客户端已知最新事件号
    VolatileNumber lastVolatileUpdateNumber_;  // 客户端已知最新 volatile 号
    DetailLevel detailLevel_;           // 当前 LOD 等级 (0..MAX_LOD_LEVELS)
    IDAlias     idAlias_;                // 在 bundle 中的别名(节省字节)
    Flags       flags_;                  // ENTER_PENDING / GONE / WITHHELD 等
    AoIUpdateSchemeID updateSchemeID_;  // 用的哪个 scheme
};
```

---

## 9.6 Witness 与可见性控制

### 9.6.1 Witness 是什么

**Witness** 是"挂着客户端"的 Real 实体的"客户端观察代理"。它的核心职责:

- 维护这个玩家的 AoI 列表(`aoiMap_`、`entityQueue_`);
- 每 tick 把 AoI 内实体的高优先级变更打包成 bundle,发给 BaseApp,BaseApp 再转发给客户端;
- 处理 `setAoIRadius`、`addToManualAoI`、`withholdFromClient` 等脚本调用;
- 跟踪每个 AoI 内实体的 `EntityCache`,决定何时发 enter/leave、何时发详细位置、何时发属性变更。

只有 Real 实体可以持有 Witness(Ghost 不行)。一个 Real 实体要么是"被某个客户端直接控制"的玩家角色,要么是被某个观察者(比如 GM 工具) attach 上去的实体。

### 9.6.2 Witness 的关键字段

`witness.hpp`:

```cpp
class Witness : public Updatable
{
    RealEntity & real_;
    Entity & entity_;

    KnownEntityQueue entityQueue_;   // vector<EntityCache*> 优先级队列
    EntityCacheMap aoiMap_;          // set<EntityCache> AoI 集合

    float aoiHyst_;
    float aoiRadius_;
    RangeListNode * pAoIRoot_;       // AoI 中心点(通常是 entity 本身,可被 setAoIRoot 替换)

    int32 maxPacketSize_;            // 每 tick 最大发包字节
    int32 bandwidthDeficit_;         // 上 tick 没发完的字节债

    IDAlias freeAliases_[ 256 ];     // 可用 IDAlias 池(给 AoI 实体编号)
    int    numFreeAliases_;

    AoITrigger * pAoITrigger_;        // AoI 触发器(进入/离开范围)
    GameTime noiseCheckTime_;        // 噪声检查时间
    bool noiseMade_;

    float stealthFactor_;            // 隐身因子(0=完全可见 1=完全隐身)
    // ...
};
```

`IDAlias` 是个很有意思的设计——每个进入 AoI 的实体会被分配一个 1 字节的别名(0-254,255 是 NO_ID_ALIAS),之后给客户端发的所有更新都用这个 1 字节别名而不是 4 字节 EntityID。当 AoI 里有 200 个实体时,这一项就节省了 600 字节/tick。

### 9.6.3 Witness::update 主循环

每个 tick 末尾,CellApp 会调用 `callWitnesses()`,这会触发所有 Witness 的 `update()`。`Witness::update`(`witness.cpp:1088`)是 CellApp 最核心的方法之一,大致流程:

```
Witness::update():
  1. addSpaceDataChanges        - 把 Space 数据变更写进 bundle
  2. addReferencePosition       - 写一个参考位置(用于相对位置编码)
  3. addDetailedPlayerPosition  - 玩家自己的详细位置
  4. sendQueueElement (vehicle) - 先发送载具栈(玩家骑在马上要先发马)
  5. 主循环:
     - 维护 entityQueue_ 的堆(make_heap)
     - 检查每个 EntityCache 的优先级
     - 在 maxPacketSize_ 预算内,按优先级发送实体更新
     - 远处实体按 AoIUpdateScheme 计算的频率更新
     - 近处实体每 tick 更新
  6. 处理 leaveAoI / enterAoI 待办
  7. 处理 reliable position 重传
  8. flushToClient 把 bundle 发出去
```

主循环的核心是"按优先级排序 + 带宽预算"——这保证了在带宽不足时,重要的实体(玩家附近的、载具上的、手动添加的)优先更新,不重要的(远处的)延后更新。

### 9.6.4 enterAoI / leaveAoI 触发

当 AoITrigger 检测到一个实体进入 AoI 半径时,会调用 `Witness::addToAoI`:

```cpp
void Witness::addToAoI( Entity * pEntity, bool setManuallyAdded )
{
    if (pEntity->isDestroyed()) {
        // 处理已死实体的特殊情况
        return;
    }

    if (!pEntity->pType()->description().canBeOnClient()) {
        return;   // 不该出现在客户端的类型(比如纯服务器实体)
    }

    EntityCache * pCache = aoiMap_.find( *pEntity );
    if (pCache != NULL) {
        if (pCache->isGone()) {
            pCache->reuse();        // 之前已离开但还没真正删除,现在 reuse
        } else {
            // 已经在 AoI 里,只更新标记
            return;
        }
    } else {
        pCache = aoiMap_.add( *pEntity );
        pCache->setEnterPending();
        this->addToSeen( pCache );
    }

    // 触发脚本回调
    this->entity().callback( "onEnteredAoI",
        Py_BuildValue( "(O)", pEntity ), "onEnteredAoI", true );
}
```

`onEnteredAoI` 是脚本可以监听的事件,常用于触发 NPC 对话、任务进度等。`onLeftAoI` 是对应离开事件。

### 9.6.5 VisibilityController:被看见控制

`VisionController` 决定"我能看到谁",而 `VisibilityController` 决定"谁能看到我"。后者通过设置一个 `visibleHeight_`,把实体本身的高度信息注册到 RangeList,让其他 AoI Trigger 检测时考虑这个高度。

`visibility_controller.hpp`:

```cpp
class VisibilityController : public Controller
{
    DECLARE_CONTROLLER_TYPE( VisibilityController )
public:
    VisibilityController( float visibleHeight = 2.f );
    virtual void startGhost();     // 在 Ghost 上也运行
    virtual void stopGhost();
    float visibleHeight() const { return visibleHeight_; }
    void visibleHeight( float h );
private:
    float visibleHeight_;
};
```

注意它的 domain 是 `DOMAIN_GHOST`——它在 Ghost 上也运行,这样即使 Real 实体不在某个客户端的 Cell 上,Ghost 上的 VisibilityController 也能让该客户端看到它。这是 Cell/Ghost 透明设计的典型体现。

### 9.6.6 VisionController:看见控制

`VisionController` 是从"主动视觉"角度的控制器,它维护一个 `VisionRangeTrigger`,在 X 轴和 Z 轴上各放一个边界节点,用于检测"哪些实体在我的视野范围内"。

`vision_controller.hpp`:

```cpp
class VisionController : public Controller, public Updatable
{
    DECLARE_CONTROLLER_TYPE( VisionController )
public:
    VisionController( float visionAngle = 1.f, float visionRange = 20.f,
        float seeingHeight = 2.f, int updatePeriod = 10 );

    virtual void startReal( bool isInitialStart );
    virtual void stopReal( bool isFinalStop );
    virtual void update();

    float visionAngle() const { return visionAngle_; }
    float visionRange() const { return visionRange_; }
    void setVisionRange( float visionAngle, float range );
private:
    float visionAngle_;
    float visionRange_;
    float seeingHeight_;
    int updatePeriod_;        // 每 N tick 才扫一次
    int tickSinceLast_;
    VisionRangeTrigger * pVisionTrigger_;
    BW::vector< EntityID > * pOnloadedVisible_;   // onload 时已可见的实体列表
};
```

`updatePeriod_` 默认 10 tick(1 秒),即每秒扫描一次视野。这对性能很重要——视野扫描比 AoI 触发器贵,因为它要计算可见性(考虑遮挡)。

`ScanVisionController` 是 `VisionController` 的子类,增加了"扫描"行为——视野方向随时间周期变化(`amplitude_`、`scanPeriod_`),模拟哨兵巡逻扫视。

---

## 9.7 空间管理:Space 与 Cell 分配

### 9.7.1 Space 是什么

**Space** 是一个逻辑空间(比如"主城"、"副本 #42"、"战场 #3")。一个 Space 可以:

- 跨多个 CellApp(由 BSP 树分割成多个 Cell);
- 加载一种"几何映射"(geometry mapping),通常是若干 Chunk 文件(地图资源);
- 持有 SpaceData(键值对形式的空间元数据,如时间、天气、地理配置等)。

`Space` 类(`space.hpp`)的核心字段:

```cpp
class Space : public TimerHandler, public GeometryMapper
{
    SpaceID id_;
    Cell * pCell_;                          // 本 CellApp 在该 Space 上的 Cell(可能 NULL)
    PhysicalSpacePtr pPhysicalSpace_;       // Chunk 空间(几何资源)
    SpaceDataMapping spaceDataMapping_;

    SpaceEntities entities_;                // 本 Space 上所有实体(Real+Ghost)
    CellInfos cellInfos_;                   // BSP 树(map<addr, CellInfo>)

    RangeList rangeList_;                   // X/Z 双向链表索引
    RangeTriggerList appealRadiusList_;     // 大半径实体的额外触发器

    int32 begDataSeq_, endDataSeq_;         // SpaceData 序列号范围

    SpaceNode * pCellInfoTree_;            // BSP 树根节点
    float artificialMinLoad_;               // 人为加上的最小负载(用于压测)
};
```

注意 `rangeList_` 是 Space 级别的——一个 Space 一份索引,所有 Cell 上的实体都进入同一个 RangeList。这让 AoI 检测不需要关心"对方在哪个 Cell",只看坐标即可。

### 9.7.2 一个 Space 跨多个 CellApp

下图展示了 Space #1 跨 4 个 CellApp 的情形:

```
   Space #1 (在 CellAppMgr 里是一棵 BSP 树)
   ┌──────────────────────────────────────────┐
   │  CellAppMgr:                             │
   │    CellData tree:                        │
   │       [horizontal cut at x=0]            │
   │           /                  \            │
   │      (App#1)              (App#2)       │
   │   x:[-100,0] z:[-100,100]  x:[0,100]     │
   │                            z:[-100,100]  │
   └──────────────────────────────────────────┘
            │ updateGeometry(stream)
            ▼
   每个 CellApp 收到完整的 BSP 树,但只为自己的 CellData 创建 Cell 对象:
   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐
   │  CellApp#1  │  │  CellApp#2  │  │  CellApp#3  │  │  CellApp#4  │
   │             │  │             │  │             │  │             │
   │  CellInfo:  │  │  CellInfo:  │  │  (no cell)  │  │  (no cell)  │
   │  rect=(-100,│  │  rect=(0,   │  │             │  │             │
   │  0,-100,100)│  │  100,-100,  │  │             │  │             │
   │             │  │  100)       │  │             │  │             │
   │  Cell*      │  │  Cell*      │  │             │  │             │
   └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘
```

每个 CellApp 都持有完整的 BSP 树(`pCellInfoTree_`),这样才能在 `EntityGhostMaintainer::visit` 时遍历所有邻居 Cell。但只有 `addr == 自己` 的叶子才创建真正的 `Cell` 对象。

### 9.7.3 Cell 分配算法

CellAppMgr 在分配新 Cell 时,会挑选当前负载最低的 CellApp(详见第 19 章)。但 CellApp 这一侧的逻辑相对简单——它只是被动接收 `addCell` 消息,创建 Cell,把 Cell 加入 `cells_` 集合。

但 CellApp 有一项关键决策权:**offload**。当一个 Real 实体移动到不再属于当前 Cell 的矩形时,CellApp 必须把它 offload 到正确的 CellApp。这是 `EntityGhostMaintainer::checkEntityForOffload` 的职责:

```cpp
void EntityGhostMaintainer::checkEntityForOffload()
{
    const Vector3 & position = pEntity_->position();
    const CellInfo * pHomeCell = pEntity_->space().pCellAt(
        position.x, position.z );    // 在 BSP 树里查 home cell

    if ((pHomeCell == NULL) ||
        (pHomeCell == &(this->cell().cellInfo()))) {
        return;   // 不需要 offload
    }

    if (pHomeCell->isDeletePending()) return;

    CellAppChannel * pOffloadDestination =
        CellAppChannels::instance().get( pHomeCell->addr() );
    if (!pOffloadDestination || !pOffloadDestination->isGood()) return;

    pOffloadDestination_ = pOffloadDestination;
    offloadChecker_.addToOffloads( pEntity_, pOffloadDestination_ );
}
```

这里 `pCellAt(x, z)` 走 BSP 树定位实体应该属于哪个 Cell。注意 CellApp 用的是本地缓存的 BSP 树——CellAppMgr 在重新平衡时会推送新的 BSP 给所有相关 CellApp,保证一致性。

### 9.7.4 空间加载:Chunk 集成

`Space` 同时承担"几何资源加载"的责任。它继承自 `GeometryMapper`,可以通过 `onSpaceGeometryLoaded` 回调获知某个 Space 的所有 Chunk 加载完成。

`PhysicalChunkSpace`(`physical_chunk_space.hpp`)是 CellApp 端的 Chunk 空间实现,封装了 BigWorld 资源系统的 Chunk 加载、卸载、碰撞查询等功能。这部分内容详见第 10 章。

加载流程概览:

```
1. CellAppMgr 给 CellApp 发 addCell 消息,附带 geometry mapping 信息
2. CellApp::addCell 解析 mapping,在 Space 上启动 chunk 加载
3. 后台线程(BGTaskManager)异步加载 chunk 文件
4. 加载完成后通过 LoadingTick 触发回调
5. Space::onSpaceGeometryLoaded 触发脚本事件
6. 此后实体可以在该 Space 内创建并移动
```

---

## 9.8 CellApp 三阶段异步初始化

### 9.8.1 为什么需要三阶段

CellApp 启动时不能"同步阻塞等所有依赖就绪",因为:

1. 它依赖 CellAppMgr(给它分配 ID、发送初始 Cell),而 CellAppMgr 可能还没启动好;
2. 它依赖 BaseApp(转发客户端流量),BaseApp 也可能没启动好;
3. 它依赖 DBApp Alpha(分配 EntityID),DBApp 可能切换 Alpha;
4. 它需要加载脚本、加载 Chunk 资源、初始化 Terrain 系统——这些都不能在主线程阻塞做。

所以 CellApp 采用了**异步初始化 + 事件驱动**的设计,把启动过程拆成三个阶段,通过 Mercury 的事件循环逐步推进。

### 9.8.2 阶段 1:基础服务(init)

`CellApp::init`(`cellapp.cpp:489`)做了这些事:

```cpp
bool CellApp::init( int argc, char * argv[] )
{
    // 1. 基类 EntityApp::init(脚本、配置、Watcher 等)
    EntityApp::init( argc, argv );

    // 2. 在网络接口上注册 CellAppInterface(消息处理表)
    CellAppInterface::registerWithInterface( interface_ );

    // 3. 启动 CellViewerServer(watcher 远程访问)
    pViewerServer_ = new CellViewerServer( *this );
    pViewerServer_->startup( this->mainDispatcher(), 0 );

    // 4. 加载扩展 DLL(插件)
    this->initExtensions();

    // 5. 初始化 IGameDelegate(如果用了游戏委托框架)
    if (IGameDelegate::instance() != NULL) {
        IGameDelegate::instance()->initialize( resPaths );
    }

    // 6. 启动后台线程(文件 IO、BGTask)
    fileIOTaskManager_.startThreads( "FileIO", 1 );
    bgTaskManager_.startThreads( "BGTask Manager", 1 );

    // 7. 初始化 Python 脚本系统
    this->initScript();

    // 8. 初始化 EntityType / UserDataObjectType / Terrain
    EntityType::init();
    UserDataObjectType::init();
    pTerrainManager_ = TerrainManagerPtr( new Terrain::Manager() );

    // 9. 启动定时器:trimHistoryTimer(4 分钟)、loadingTimer(每 chunkLoadingPeriod)
    trimHistoryTimer_ = mainDispatcher_.addTimer( 4*60*1000000, this, ... );
    loadingTimer_     = mainDispatcher_.addTimer( loadingTickMicroseconds, this, ... );

    // 10. 创建 CellAppChannels 集合(给其他 CellApp 通信用)
    pCellAppChannels_ = new CellAppChannels( ... );

    // 11. 异步向 CellAppMgr 注册(关键!)
    new AddToCellAppMgrHelper( *this, pViewerServer_->port() );

    return true;
}
```

注意第 11 步——`AddToCellAppMgrHelper` 是个**异步注册器**:它发起一个 `CellAppMgrInterface::add` 请求,等待 CellAppMgr 回复。在等待期间,CellApp 已经在跑事件循环,可以处理其他消息(比如 CellAppMgr 可能要先回复一个 `setGameTime`,然后才是 `startup`)。

### 9.8.3 阶段 2:与其他进程连接(finishInit)

CellAppMgr 回复后,CellApp 调用 `finishInit`(`cellapp.cpp:661`):

```cpp
bool CellApp::finishInit( const CellAppInitData & initData )
{
    if (int32( initData.id ) == -1) {
        ERROR_MSG( "CellApp::finishInit: CellAppMgr refused to let us join.\n" );
        return false;
    }

    id_ = initData.id;                       // CellAppMgr 分配的 ID
    this->setStartTime( initData.time );     // 初始游戏时间
    baseAppAddr_ = initData.baseAppAddr;     // 默认 BaseApp 地址
    dbAppAlpha_.addr( initData.dbAppAlphaAddr );
    isReadyToStart_ = initData.isReady;

    // 1. 连接 DBApp Alpha(申请 EntityID 池)
    idClient_.init( &this->dbAppAlpha(), DBAppInterface::getIDs, ... );

    // 2. 注册到 machined(让其他进程能找到自己)
    CellAppInterface::registerWithMachined( this->interface(), id_ );

    // 3. 注册 CellAppMgr birth 监听(CellAppMgr 重启时能感知)
    Mercury::MachineDaemon::registerBirthListener(
        this->interface().address(),
        CellAppInterface::handleCellAppMgrBirth, "CellAppMgrInterface" );

    // 4. 注册 Watcher
    BW_REGISTER_WATCHER( id_, "cellappNN", "cellApp", ... );

    // 5. 启动 Python 服务器(供远程调试)
    this->startPythonServer( pythonPort, id_ );

    if (isReadyToStart_) {
        this->startGameTime();    // 阶段 3
    } else {
        isReadyToStart_ = true;   // 等 startup 消息触发
    }

    return true;
}
```

这里的关键是 `isReadyToStart_`——CellAppMgr 在 `addCell` 之前可能要先发 `startup` 消息确认 BaseApp 就绪,所以 `startGameTime` 可能延迟到 `startup` 处理器里调用。

### 9.8.4 阶段 3:业务就绪(startGameTime)

`CellApp::startGameTime`(`cellapp.cpp:798`)启动真正的游戏 tick:

```cpp
void CellApp::startGameTime()
{
    INFO_MSG( "CellApp is starting\n" );

    // 1. 启动 gameTimer(默认 10Hz)
    gameTimer_ = this->mainDispatcher().addTimer(
        1000000/Config::updateHertz(), this,
        reinterpret_cast< void * >( TIMEOUT_GAME_TICK ), "GameTick" );

    // 2. 启动 TimeKeeper(与 CellAppMgr 同步游戏时间)
    pTimeKeeper_ = new TimeKeeper( interface_, gameTimer_, time_,
        Config::updateHertz(), cellAppMgr_.addr(),
        &CellAppMgrInterface::gameTimeReading,
        id_, Config::maxTickStagger() );

    // 3. 开始定期上报负载
    cellAppMgr_.isRegular( true );
}
```

至此 CellApp 进入"业务就绪"状态,开始接收 `addCell` 指令、创建实体、跑 tick。

### 9.8.5 Timer 机制驱动

注意 CellApp 整个生命周期由三类定时器驱动:

| Timer | 频率 | 用途 |
|-------|------|------|
| `gameTimer_` | `updateHertz`(默认 10Hz) | 主游戏 tick,跑实体模拟、AOI、Witness |
| `loadingTimer_` | `chunkLoadingPeriod`(默认 500ms) | Chunk 加载推进,后台任务 tick |
| `trimHistoryTimer_` | 4 分钟 | 清理过期的事件历史(EventHistory) |

`handleTimeout` 根据传入的 `arg` 区分:

```cpp
void CellApp::handleTimeout( TimerHandle /*handle*/, void * arg )
{
    switch (reinterpret_cast<uintptr>( arg )) {
        case TIMEOUT_GAME_TICK:        this->handleGameTickTimeSlice(); break;
        case TIMEOUT_TRIM_HISTORIES:   this->handleTrimHistoriesTimeSlice(); break;
        case TIMEOUT_LOADING_TICK:
            bgTaskManager_.tick();
            fileIOTaskManager_.tick();
            pSpaces_->tickChunks();
            break;
    }
}
```

---

## 9.9 实体生命周期

### 9.9.1 创建:onload / createEntity

实体在 CellApp 上有两种创建路径:

1. **从 BaseApp 创建**(`Cell::createEntity` 消息):BaseApp 决定给某个实体创建 cell 部分,发送 `createEntity` 消息到选定的 CellApp。CellApp 调用 `Cell::createEntityInternal` 创建一个 Real 实体。
2. **从其他 CellApp offload 过来**(`CellAppInterface::onload` 消息):Real 实体跨边界迁移,源 CellApp 把它转为 Ghost,目标 CellApp 接收 `onload` 消息并创建新的 Real。

`Cell::createEntityInternal`(`cell.cpp:292`)的流程:

```cpp
EntityPtr Cell::createEntityInternal( BinaryIStream & data,
    const ScriptDict & properties, bool isRestore, ... )
{
    EntityID id;
    EntityTypeID entityTypeID;
    data >> id >> entityTypeID;

    // 如果 ID 是 0,从 IDClient 申请
    if (id == 0) {
        id = CellApp::instance().idClient().getID();
    }

    // 如果该实体已存在(可能是僵尸 Ghost),先清理
    // ...

    // 创建空 Entity
    EntityPtr pNewEntity = space_.newEntity( id, entityTypeID );

    // 初始化为 Real
    pNewEntity->initReal( data, properties, isRestore, channelVersion, pNearbyEntity );

    // 加入 Cell 的 realEntities_ 列表
    this->addRealEntity( pNewEntity.get(), /*shouldSendNow:*/false );

    // 立即备份一次到 BaseApp
    pNewEntity->pReal()->backup();

    return pNewEntity;
}
```

### 9.9.2 激活:enterWorld

实体的"进入世界"是通过脚本回调 `onEnteredCell` 完成的。在 `Entity::convertGhostToReal` 中:

```cpp
this->callback( "onEnteredCell" );
```

这个回调在 `s_callbackBuffer_.enableHighPriorityBuffering()` 之间被调用,意味着它会在所有其他脚本回调之前执行,保证脚本看到的状态一致。

对应的 `onLeavingCell` / `onLeftCell` 在 offload 时调用。

### 9.9.3 移动:位置更新

实体的位置更新有两类来源:

1. **客户端控制**(`avatarUpdateImplicit` / `avatarUpdateExplicit`):玩家自己控制的角色,客户端发位置更新,CellApp 验证后应用;
2. **控制器移动**:`MoveController` 等控制器在 `update()` 中改实体位置;
3. **脚本调用**:`entity.position = (x, y, z)`(只对 Real 有效);
4. **Ghost 同步**:`ghostPositionUpdate` 消息从 Real 发到 Ghost。

无论哪种来源,最终都调用 `Entity::setGlobalPositionAndDirection`,它内部会:

- 调用 `updateGlobalPosition` 把 local position 转成 global position(考虑载具变换);
- 调用 `updateInternalsForNewPosition` 更新 RangeList 节点位置、检查 chunk crossing、通知 Space 重新评估 offload 需求;
- 标记 `volatileUpdateNumber_++` 让 Witness 知道这个实体位置变了。

### 9.9.4 跨 Cell:Ghost 切换

实体跨 Cell 边界的完整流程:

```
1. Real Entity 在 CellApp A 上,位置 (x, z)
2. EntityGhostMaintainer::checkEntityForOffload 发现 pCellAt(x,z) 是 CellApp B
3. 把 Entity 加入 offloadChecker 的待发列表
4. OffloadChecker::sendOffloads 批量发送:
   - 在 CellApp A 上调用 Entity::offload(channel_to_B)
     - Entity::convertRealToGhost(stream, channel_to_B):
       - 把 Real 数据写到 channel_to_B 的 bundle
       - 设置 pRealChannel_ = channel_to_B
       - 销毁本地的 RealEntity(pReal_ = NULL,变成 Ghost)
   - bundle 上的消息是 CellAppInterface::onload
5. CellApp B 收到 onload 消息:
   - Cell::createEntityInternal 创建新 Entity
   - Entity::initReal 读流重建 RealEntity
   - Entity::convertGhostToReal 把原本的 Ghost 状态合并进 Real
   - 触发 onEnteredCell 回调
6. CellApp B 上的新 Real 启动后:
   - 给 CellApp A 发 ghostSetReal 消息(告诉 A 它现在是 Real 了)
   - CellApp A 上的 Ghost 把 pRealChannel_ 切换到新 Real
```

整个流程对脚本透明——脚本的 `entity.position`、`entity.client.method()` 等调用始终能正常工作,只是底层自动在 Real 与 Ghost 之间转发。

### 9.9.5 销毁:onLeaveWorld

实体销毁有两种触发:

1. **BaseApp 主动销毁**(`destroyEntity` 消息):BaseApp 决定某个实体不再需要 cell 部分;
2. **CellApp 内部销毁**:`Entity::destroy()` 由脚本调用或 CellApp 退役时触发。

销毁流程:

```cpp
void Entity::destroy()
{
    if (this->isReal()) {
        this->convertRealToGhost();   // 先变成 Ghost(不 offload,只是清理 Real 状态)
    }

    // 通知所有 haunt 删除 Ghost
    pReal_->addDelGhostMessage( bundle );

    // 通知 BaseApp 实体已销毁
    this->sendCellEntityLostToBase();

    // 从 Space、Cell、RangeList 中移除
    pSpace_->removeEntity( this );
    cell_.entityDestroyed( this );

    // 标记 destroyed
    this->setDestroyed();
}
```

注意 Real → Ghost 的转换再次发生——这次不是为了 offload,而是为了"优雅地"通知所有邻居"我要走了,删除你们的 Ghost"。这是 BigWorld 一致性设计的体现:任何状态变更都通过 Real → Ghost → 邻居 的标准路径传播。

---

## 9.10 控制器系统

### 9.10.1 Controller 是什么

**Controller** 是 Entity 的扩展组件,用于实现"持续行为"——比如"朝某点移动"、"周期性转圈"、"每隔 5 秒触发一次"等。Controller 与脚本回调的区别:

- **脚本回调**是一次性的(`onEnterAoI`、`onTimer` 等);
- **Controller** 是持续性的,每个 tick 都会被 `update()` 调用,直到被 `cancel()` 或自然结束。

Controller 的核心特征:

- 只能附加到 Real 实体(Ghost 上不能跑 Real controller);
- 可以跨 offload 存活——Real 迁移时,Controller 的状态会被序列化到流,在新 Real 上恢复;
- 有 `DOMAIN_GHOST` / `DOMAIN_REAL` / `DOMAIN_GHOST_AND_REAL` 三种域,决定在 Real 还是 Ghost 上运行。

### 9.10.2 Controller 基类

`controller.hpp`:

```cpp
class Controller : public ReferenceCount
{
public:
    virtual ControllerType    type() const = 0;
    virtual ControllerDomain  domain() const = 0;
    virtual ControllerID      exclusiveID() const = 0;

    bool isAttached() const  { return !!pEntity_; }
    Entity & entity()        { return *pEntity_; }
    ControllerID id() const  { return controllerID_; }

    virtual void writeRealToStream( BinaryOStream & stream );
    virtual bool readRealFromStream( BinaryIStream & stream );
    virtual void writeGhostToStream( BinaryOStream & stream );
    virtual bool readGhostFromStream( BinaryIStream & stream );

protected:
    void cancel();
    void ghost();
    void standardCallback( const char * methodName );

private:
    virtual void startReal( bool isInitialStart );
    virtual void stopReal( bool isFinalStop );
    virtual void startGhost();
    virtual void stopGhost();

    Entity *     pEntity_;
    int          userArg_;
    ControllerID controllerID_;
};
```

`startReal` / `stopReal` / `startGhost` / `stopGhost` 是生命周期钩子——`startReal` 在 Controller 被附加或 Real 重新创建时调用,`stopReal` 在取消或 Real 即将销毁时调用。

### 9.10.3 控制器注册机制(DECLARE_CONTROLLER_TYPE)

每个 Controller 子类都要用宏 `DECLARE_CONTROLLER_TYPE(CLASS_NAME)` 声明,然后在 .cpp 里用 `IMPLEMENT_CONTROLLER_TYPE(CLASS_NAME, DOMAIN)` 实现:

```cpp
// turn_controller.hpp
class YawRotatorController : public Controller, public Updatable
{
    DECLARE_CONTROLLER_TYPE( YawRotatorController )
    // ...
};

// turn_controller.cpp
IMPLEMENT_CONTROLLER_TYPE( YawRotatorController, DOMAIN_REAL )
```

这套宏展开后是一个静态的 `TypeRegisterer` 对象,它在 main 之前注册到 `Controller::factories` 表里,让 `Controller::create(type)` 能根据类型 ID 创建实例。这是一种**自注册工厂**模式。

### 9.10.4 Controller 优先级与切换

`exclusiveID()` 用于实现"互斥控制器"——同一类控制器同时只能有一个。比如 `MoveController` 的子类都共享一个 exclusiveID,新加一个 `MoveToPointController` 时会自动取消已有的 `MoveToEntityController`。

这个互斥机制由 `Controllers`(`controllers.hpp`)类管理:

```cpp
class Controllers
{
public:
    ControllerID addController( ControllerPtr pController, int userArg, Entity * pEntity );
    bool delController( ControllerID id, Entity * pEntity, bool warnOnFailure = true );
    void modController( ControllerPtr pController, Entity * pEntity );
    void startReals();
    void stopReals( bool isFinalStop );
    // ...
private:
    typedef BW::map< ControllerID, ControllerPtr > Container;
    Container container_;
    ControllerID lastAllocatedID_;
};
```

`addController` 时会检查 `exclusiveID`,如果已有同 exclusiveID 的旧控制器,先 `stopReal` 再删除。

### 9.10.5 内置控制器一览

BigWorld 自带约 15 种 Controller,涵盖移动、转向、定时、视觉、陷阱等场景:

| 控制器 | 域 | 用途 |
|--------|-----|------|
| `MoveToPointController` | REAL | 朝一个固定点移动 |
| `MoveToEntityController` | REAL | 朝另一个实体移动,到达后停止 |
| `NavigateStepController` | REAL | 通过 Navigator 寻路 |
| `YawRotatorController` | REAL | 周期性转向(用于哨兵扫视) |
| `TimerController` | REAL | 周期触发 `onTimer` 脚本回调 |
| `VisionController` | REAL | 维护视野,检测可见实体 |
| `ScanVisionController` | REAL | 视野扫描(方向周期变化) |
| `VisibilityController` | GHOST | 控制实体的可见高度(被看见) |
| `ProximityController` | REAL | 范围触发器(陷阱),触发 `onEnterTrap`/`onLeaveTrap` |
| `FaceEntityController` | REAL | 朝向某个实体 |
| `AccelerateAlongPathController` | REAL | 沿路径加速移动 |
| `AccelerateToEntityController` | REAL | 朝某实体加速移动 |
| `AccelerateToPointController` | REAL | 朝某点加速移动 |
| `PassengerController` | REAL | 载具乘客 |
| `PortalConfigController` | GHOST_AND_REAL | 控制 Chunk Portal 开关 |

注意 `VisibilityController` 是 `DOMAIN_GHOST`——它在 Ghost 上也运行,确保即使 Real 不在本 CellApp,本 CellApp 上的其他实体也能"看见"它。这种"Ghost 也跑 Controller"的设计是 BigWorld 跨边界透明性的关键。

### 9.10.6 控制器的 Python 接口

脚本可以通过 `entity.controllers` 列表查看当前控制器,也可以通过特定方法添加:

```python
# Python 脚本示例
entity.turnTo(yaw, velocity=2.0)   # 添加 YawRotatorController
entity.moveToPoint(pos, velocity=5.0)  # 添加 MoveToPointController
entity.addTimer(start, repeat, userArg)  # 添加 TimerController
entity.cancel(controllerID)         # 取消某个控制器
```

这些方法背后由 `PY_AUTO_CONTROLLER_FACTORY_DECLARE` 宏生成的工厂函数支持,把 Python 参数转换成 Controller 构造参数,然后调用 `entity.addController(controller, userArg)`。

---

## 9.11 特色实现深度剖析

### 9.11.1 Cell/Ghost 的设计哲学:透明跨边界

BigWorld 的 Cell/Ghost 设计有一个核心哲学:**让脚本开发者忘记 Cell 边界的存在**。无论一个实体在哪个 CellApp 上,无论它现在是 Real 还是 Ghost,脚本代码都这样写:

```python
# 这段代码无论 entity 是 Real 还是 Ghost 都能正常工作
def on_some_event(self):
    other = BigWorld.entities.get(otherId)
    if other:
        other.client.someMethod()        # 自动转发到 Real
        pos = other.position              # 拿到位置(可能略滞后)
        other.callMethod(...)             # 转发到 Real
```

这种透明性是通过三层机制实现的:

1. **同一类两种角色**:`Entity` 类既表示 Real 也表示 Ghost,只是 `pReal_` 是否为 NULL 区分;
2. **消息自动转发**:Ghost 上调用的方法被 `forwardMessageToReal` 转发到 Real 所在 CellApp;
3. **状态自动同步**:Real 在每 tick 把位置、属性、控制器变更通过 haunt 通道发给所有 Ghost。

这种设计的代价是"Ghost 状态有延迟"——通常 1-2 tick(100-200ms),但对大多数游戏逻辑(显示、AOI、远程调用)是可接受的。

### 9.11.2 AOI 的性能优化:分块索引

CellApp 的 AOI 实现做了多层优化,核心是**分块索引**:

1. **Space 级 RangeList**:所有实体(Real+Ghost)在同一个 Space 的 RangeList 上,按 X/Z 双向链表排序;
2. **触发器节点**:每个 AoI Trigger 不是每次扫描整条链表,而是在链表上插入两个"哨兵节点"(upper/lower bound),当其他实体穿越哨兵时才触发回调——这是 O(1) 而非 O(N) 的检测;
3. **滞回区域**:进入 AoI 用 `aoiRadius_`,离开用 `aoiRadius_ + aoiHyst_`,避免边界抖动;
4. **优先级队列**:Witness 用堆维护"该更新的实体",按优先级在带宽预算内出队;
5. **IDAlias**:1 字节别名替代 4 字节 EntityID,带宽节省 75%;
6. **VolatileInfo**:位置/方向用差分编码,只发变化的部分;
7. **AoIUpdateScheme**:远处实体按 scheme 计算的频率更新,不是每 tick 都发。

这一系列优化让 BigWorld 在单 CellApp 上能模拟数千到上万个实体,AOI 半径 100 米时仍能保持 10Hz tick。

### 9.11.3 控制器系统的策略模式

BigWorld 的 Controller 系统是经典的**策略模式**:

- **策略接口**:`Controller` 抽象基类,定义 `startReal`、`stopReal`、`update` 等接口;
- **具体策略**:`MoveToPointController`、`YawRotatorController` 等,实现具体行为;
- **上下文**:`Entity` 持有 `Controllers` 集合,委托具体行为给 Controller;
- **动态切换**:运行时通过 `cancel` + `add` 切换策略,旧策略的状态被序列化以便恢复。

这种设计的好处是脚本可以灵活组合行为:一个 NPC 可以同时有 `ProximityController`(陷阱)+ `YawRotatorController`(扫视)+ `VisibilityController`(被看见),互不干扰。

### 9.11.4 与 CellAppMgr 的两层负载均衡

CellApp 与 CellAppMgr 的协作构成了 BigWorld 的两层负载均衡(详见第 19 章):

| 层 | 决策者 | 频率 | 操作 |
|----|-------|------|------|
| 元负载均衡 | CellAppMgr | 每 3 秒 | 跨 CellAppGroup 加/退役 Cell,把整个 Space 的分区从一个 CellApp 迁到另一个 |
| 空间内负载均衡 | CellAppMgr | 每 1 秒 | 调整 BSP 分割平面,把 Cell 的矩形重新划分,让负载更平均 |
| 实时 offload | CellApp(本章) | 每 tick | 实体跨边界时立即 offload 到正确 CellApp |

第三层是 CellApp 自主决策的,前两层由 CellAppMgr 决策后下发。这种"控制平面集中决策 + 数据平面分散执行"的架构是 BigWorld 可扩展性的基础。

### 9.11.5 RealEntity::Haunt 与跨 CellApp 通道

`RealEntity` 维护一个 `Haunts` 列表(`real_entity.hpp`):

```cpp
class RealEntity
{
public:
    class Haunt
    {
    public:
        Haunt( CellAppChannel * pChannel, GameTime creationTime );
        CellAppChannel & channel() { return *pChannel_; }
        Mercury::Bundle & bundle() { return pChannel_->bundle(); }
        const Mercury::Address & addr() const { return pChannel_->addr(); }
        GameTime creationTime() const { return creationTime_; }
    private:
        CellAppChannel * pChannel_;
        GameTime creationTime_;
    };

    typedef BW::vector< Haunt > Haunts;

    Haunts::iterator hauntsBegin();
    Haunts::iterator hauntsEnd();
    int numHaunts() const { return haunts_.size(); }

    void addHaunt( CellAppChannel & channel );
    Haunts::iterator delHaunt( Haunts::iterator iter );
};
```

**Haunt** 是"Ghost 之地"的意思——每个 Haunt 对应一个持有本 Real Ghost 的邻居 CellApp。Real 通过 Haunt 把自己的状态变更同步给所有 Ghost:

- `addHaunt(channel)`:在 channel 的 bundle 上写 `createGhost` 消息;
- `delHaunt(iter)`:在 channel 的 bundle 上写 `delGhost` 消息;
- 每个 tick:`addDelGhostMessage`、`ghostPositionUpdate` 等通过所有 haunt 的 bundle 发出。

`creationTime_` 字段是为了"幼年期保护"——刚创建的 Ghost 不会被立即删除(由 `MINIMUM_GHOST_LIFESPAN` 控制),避免抖动。

### 9.11.6 callWitnesses 的两阶段调度

CellApp 的每个 tick 末尾会调用 `callWitnesses`,但这是个**两阶段**过程:

```cpp
void CellApp::onEndOfTick()
{
    pCellAppChannels_->stopTimer();
    pCellAppChannels_->sendAll();
    this->callWitnesses( /* checkReceivedTime = */ false );  // 第一阶段
}

void CellApp::onTickProcessingComplete()
{
    this->EntityApp::onTickProcessingComplete();
    pCellAppChannels_->sendTickCompleteToAll( this->time() );
    pCellAppChannels_->startTimer( ... );
    hasCalledWitnesses_ = false;
    this->callWitnesses( /* checkReceivedTime = */ true );   // 第二阶段
}
```

第一阶段在 `onEndOfTick` 调用,Witness 开始打包,但不强制等待远端 tick 完成;
第二阶段在 `onTickProcessingComplete` 调用,此时所有邻居 CellApp 都已经收到本 tick 的 `onRemoteTickComplete`,可以确保 Ghost 位置已更新到最新。

`hasCalledWitnesses_` 标志用于避免重复调用——如果第一阶段已经调用过且 `checkReceivedTime=true`,第二阶段会跳过。这种设计在性能与一致性之间做了权衡。

### 9.11.7 EventHistory 与延迟属性同步

`Entity` 持有一个 `EventHistory eventHistory_`(`entity.hpp`),记录实体的"事件历史"。这是为客户端**延迟同步**设计的——如果某个客户端因为网络抖动错过了第 N 个 tick 的更新,它可以在恢复后通过 `requestEntityUpdate` 重新请求第 N 到当前的事件历史,而不需要全量重发。

`EventHistory` 的 `trimEventHistory(cleanUpTime)` 由 `CellApp::handleTrimHistoriesTimeSlice` 每 4 分钟调用一次,清理掉太老的事件(默认保留若干分钟),避免内存无限增长。

### 9.11.8 BaseRestoreConfirmHandler 与孤儿实体清理

`cellapp.cpp:234` 有个有趣的辅助类 `BaseRestoreConfirmHandler`:它在 CellApp 启动后 60 秒触发一次,清理"应该被 BaseApp 恢复但没收到响应"的孤儿实体:

```cpp
void BaseRestoreConfirmHandler::handleTimeout( TimerHandle handle, void * arg )
{
    for (auto & kv : Entity::population()) {
        Entity & entity = *kv.second;
        if (entity.isReal() && !entity.isDestroyed() &&
            entity.pReal()->channel().version() != 0 &&
            entity.pReal()->channel().wantsFirstPacket()) {
            WARNING_MSG( "BaseRestoreConfirmHandler: entity %d assumed "
                "to have not been restored on its baseapp.\n", kv.first );
            entity.destroy();
        }
    }
}
```

这是 BigWorld 容错设计的一部分——CellApp 重启后,BaseApp 应该恢复所有实体的 base 部分,但如果某个 BaseApp 卡死或丢失了恢复消息,CellApp 上的 Real 实体会变成"孤儿"(没有对应的 base)。这个定时器在 60 秒后清理它们,避免长期占用资源。

---

## 9.12 本章小结

本章我们深入剖析了 BigWorld 的空间数据平面 CellApp。回顾核心概念:

1. **CellApp** 是空间实体计算进程,水平扩展,每个 CellApp 持有多个 Cell;
2. **Cell** 是 Space 在单个 CellApp 上的一个矩形分区,持有 Real 实体;
3. **Ghost** 是 Real 实体的影子,跨 CellApp 边界可见,由 Real 通过 haunt 通道同步状态;
4. **AOI** 基于 RangeList 双向链表索引和 RangeTrigger 哨兵节点,O(1) 检测进入/离开;
5. **Witness** 是玩家观察代理,维护 AoI 队列,按优先级和带宽预算每 tick 发送可见实体更新;
6. **Controller** 是 Entity 的策略组件,实现持续行为(移动、转向、定时、视觉等),可跨 offload 存活;
7. **三阶段异步初始化**让 CellApp 在依赖未就绪时也能逐步启动,通过事件循环推进;
8. **Space 跨多 CellApp** 通过 BSP 树分割,每个 CellApp 持有完整 BSP 但只对自己的 Cell 创建 Cell 对象;
9. **Real/Ghost 转换**通过 `convertRealToGhost` / `convertGhostToReal` 完成,对脚本透明;
10. **两层负载均衡**:CellAppMgr 集中决策 + CellApp 自主 offload。

理解了 CellApp,你就理解了 BigWorld 空间子系统的核心。下一章我们将离开服务器,看 BigWorld 的资源管理系统——Chunk、Model、Texture 等是如何被组织、加载、流式传输到客户端的。

---

> **延伸阅读**:
> - `docs/BigWorld空间应用CellApp实现分析.md` — CellApp 与 CellAppMgr 的完整实现分析,本章的进阶版
> - `programming/bigworld/server/cellapp/cellapp.cpp` — CellApp 主类实现,3000+ 行,本章多次引用
> - `programming/bigworld/server/cellapp/entity.cpp` — Entity 类实现,5000+ 行,Real/Ghost 转换的核心
> - `programming/bigworld/server/cellapp/witness.cpp` — Witness 实现,3000+ 行,AOI 与客户端更新
> - `programming/bigworld/server/cellapp/entity_ghost_maintainer.cpp` — Ghost 维护逻辑,300 行,清晰易读
> - 第 19 章(待写)— CellAppMgr 的负载均衡、BSP 重平衡、元负载均衡详解
> - 第 18 章(待写)— Witness 与客户端可见性的客户端侧实现
