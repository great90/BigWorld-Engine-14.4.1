# 专题1:Ghost 同步机制深度剖析

> BigWorld Engine 14.4.1 最具特色的设计——跨 Cell 边界的实体透明性。
> 本专题将从设计哲学、数据结构、源码实现、消息路由、性能分析等所有维度,对 Ghost 机制进行百科级深度剖析。

---

## 目录

- [一、引言与导读](#一引言与导读)
- [二、Ghost 的本质与设计哲学](#二ghost-的本质与设计哲学)
- [三、Ghost 的数据结构总览](#三ghost-的数据结构总览)
- [四、Entity 类的 Real/Ghost 二态](#四entity-类的-realghost-二态)
- [五、RealEntity 与 Haunt 内嵌类](#五realentity-与-haunt-内嵌类)
- [六、EntityGhostMaintainer 深度剖析](#六entityghostmaintainer-深度剖析)
- [七、Ghost 的创建流程](#七ghost-的创建流程)
- [八、Ghost 的销毁流程](#八ghost-的销毁流程)
- [九、Real/Ghost 转换](#九realghost-转换)
- [十、Haunt 通道详解](#十haunt-通道详解)
- [十一、消息路由核心机制](#十一消息路由核心机制)
- [十二、跨 Cell 边界流程](#十二跨-cell-边界流程)
- [十三、Ghost 数据同步详解](#十三ghost-数据同步详解)
- [十四、Buffered Ghost Messages 详解](#十四buffered-ghost-messages-详解)
- [十五、性能分析](#十五性能分析)
- [十六、边界情况与故障处理](#十六边界情况与故障处理)
- [十七、与其他引擎对比](#十七与其他引擎对比)
- [十八、配置参数详解](#十八配置参数详解)
- [十九、调试与可观测性](#十九调试与可观测性)
- [二十、总结与最佳实践](#二十总结与最佳实践)
- [附录 A:关键文件索引](#附录-a关键文件索引)
- [附录 B:关键消息一览表](#附录-b关键消息一览表)
- [附录 C:术语表](#附录-c术语表)

---

## 一、引言与导读

### 1.1 为什么需要 Ghost

在传统的 MMOG(Massively Multiplayer Online Game)服务器架构中,游戏世界通常被切分为多个独立的"区(zone)"或"线(shard)",每个区域由一个独立的进程(或一组进程)负责。当一个玩家从 A 区移动到 B 区时,通常会发生一次"换线":

```
玩家在 A 区 ──(下线/迁移)──> 玩家在 B 区重新登录
```

这种设计的缺陷是显而易见的:

1. **边界不透明**:玩家会感知到"切换"过程(loading、断线、重连)。
2. **跨区交互困难**:A 区玩家无法看到 B 区玩家,无法对 B 区玩家施法、交易。
3. **负载不均衡**:热门区域所在进程过载,冷门区域资源闲置。
4. **难以实现大世界无缝**:无法支持万人同屏、跨区战场等场景。

BigWorld Engine 引入了 **Cell** 概念——将一个无缝大世界按空间分割成多个 Cell,每个 Cell 由 CellApp 进程承载。Cell 之间通过 BSP 树划分边界。一个玩家可能站在 Cell A 的边界附近,同时又可以看到 Cell B 中的其他实体。要让这种"跨边界可见性"对玩家和脚本完全透明,BigWorld 引入了 **Ghost** 机制。

### 1.2 Ghost 一句话定义

> **Ghost 是 Real Entity 在其他 CellApp 上的轻量级"影子"副本。Real 持有权威状态,Ghost 持有 Real 推送过来的快照。**

### 1.3 本专题的阅读顺序

本专题共 20 章,建议按以下顺序阅读:

1. **第 2-3 章**:建立整体认识,理解 Ghost 是什么、由哪些类组成。
2. **第 4-6 章**:深入 Entity、RealEntity、EntityGhostMaintainer 三个核心类。
3. **第 7-9 章**:掌握 Ghost 的生命周期——创建、销毁、Real/Ghost 互换。
4. **第 10-12 章**:理解 Haunt 通道、消息路由、跨边界流程。
5. **第 13-14 章**:深入数据同步、消息缓冲等细节。
6. **第 15-17 章**:性能、边界情况、横向对比。
7. **第 18-20 章**:配置、调试、总结。

### 1.4 涉及的核心源文件

| 路径 | 说明 |
|------|------|
| `server/cellapp/entity.hpp` / `entity.cpp` / `entity.ipp` | Entity 类定义与实现 |
| `server/cellapp/real_entity.hpp` / `real_entity.cpp` | RealEntity 类(Real 状态的扩展) |
| `server/cellapp/entity_ghost_maintainer.hpp` / `.cpp` | Ghost 维护器 |
| `server/cellapp/offload_checker.hpp` / `.cpp` | Offload 检查器 |
| `server/cellapp/cell.hpp` / `cell.cpp` | Cell 类(管理一组 Real 实体) |
| `server/cellapp/space.hpp` / `space.cpp` | Space 类(管理一个空间) |
| `server/cellapp/cell_app_channel.hpp` / `.cpp` | CellApp 间通道 |
| `server/cellapp/cell_app_channels.hpp` / `.cpp` | 通道集合 |
| `server/cellapp/buffered_ghost_message*.hpp` / `.cpp` | Ghost 消息缓冲 |
| `server/cellapp/message_handlers.cpp` | 消息路由分发 |
| `server/cellapp/cellapp_interface.hpp` | 消息接口定义 |
| `server/cellapp/cellapp_config.hpp` / `.cpp` | 配置参数 |

---

## 二、Ghost 的本质与设计哲学

### 2.1 Ghost 的本质:pReal_ == NULL

BigWorld 中最关键、最容易被误解的设计是:**Ghost 不是独立的类**。整个代码库中**没有 `ghost.hpp` 或 `Ghost.cpp`**。一个 Entity 实例本身就是 Real 或 Ghost,完全由 `pReal_` 字段是否为 NULL 决定:

```cpp
// server/cellapp/entity.ipp:104-116
INLINE
bool Entity::isReal() const
{
    // You shouldn't be able to have a real and a real channel at the same time.
    MF_ASSERT( !(pReal_ && pRealChannel_) );

    return pReal_ != NULL;
}
```

**核心论断**:
- `pReal_ != NULL` → 这是一个 **Real Entity**(权威实体)。
- `pReal_ == NULL` → 这是一个 **Ghost Entity**(影子实体)。

注意 `MF_ASSERT( !(pReal_ && pRealChannel_) )` 这个断言:**一个 Entity 不能同时持有 RealEntity 对象和到 Real 的通道**。两者是互斥状态:

| 状态 | `pReal_` | `pRealChannel_` | 含义 |
|------|---------|------------------|------|
| Real | 指向 RealEntity | NULL | 我是权威,我持有 RealEntity |
| Ghost | NULL | 指向 Real 所在 CellApp 的通道 | 我是影子,我通过通道与 Real 通信 |
| 切换中 | NULL | NULL | 暂态(短暂出现,如 Real 销毁后 Ghost 还未收到 ghostSetReal) |

### 2.2 Real 与 Ghost 的关系

| 关系 | 描述 |
|------|------|
| 一对一 | 一个 Entity ID 全集群内只有 1 个 Real |
| 一对多 | 一个 Real 可以同时有 0 到 N 个 Ghost(每个 Ghost 在不同的 CellApp 上) |
| 多对一 | 多个 Ghost 共享同一个 Real |
| 不能共存 | 同一个 CellApp 上,同一个 Entity ID 不能同时存在 Real 和 Ghost |

### 2.3 为什么需要 Ghost

考虑一个场景:玩家 P 站在 Cell A(由 CellApp #1 承载)中,他的视野半径 500 米。在视野范围内,有 NPC X 在 Cell B(由 CellApp #2 承载)。

```
            ┌─────────────────┐ ┌─────────────────┐
            │   CellApp #1     │ │   CellApp #2     │
            │   (Cell A)       │ │   (Cell B)       │
            │                  │ │                  │
            │   玩家 P (Real)   │ │   NPC X (Real)   │
            │       │          │ │       │          │
            │       │ 视野 500m │ │       │          │
            │       └──────────┼─> X 在视野内         │
            │                  │ │                  │
            │   X 的 Ghost      │ │                  │
            │   (CellApp#1上的  │ │                  │
            │    影子副本)       │ │                  │
            └─────────────────┘ └─────────────────┘
```

要让 CellApp #1 上的 P 的 Witness 能够"看到"X,CellApp #1 必须有 X 的一个**影子副本**。这个副本就是 Ghost。Ghost 不跑游戏逻辑,只是 X 状态的快照,由 Real X 通过 Haunt 通道推送更新。

### 2.4 Ghost 与 Real 的职责划分

| 职责 | Real Entity | Ghost Entity |
|------|------------|--------------|
| 跑脚本逻辑(`__init__`、`onTick` 等) | ✅ | ❌(只跑 `onGhostCreated` / `onGhostDestroyed`) |
| 持有 Witness(玩家视野) | ✅ | ❌ |
| 接受客户端输入(avatarUpdate) | ✅(经 BaseApp 转发) | ❌ |
| 跑 Controller(MoveController 等) | ✅ Real Controller | ✅ Ghost Controller(只读) |
| 持有 Real 属性(`CELL_DATA` + `REAL_DATA`) | ✅ | ❌ |
| 持有 Ghost 属性(`GHOSTED_DATA`) | ✅ | ✅(快照) |
| 与 BaseApp 通信(backup、setClient) | ✅ | ❌ |
| 决定位置和方向(权威) | ✅ | ❌(由 Real 推送) |
| 接受来自其他实体的 cell 方法调用 | ✅(直接调用) | ✅(转发到 Real) |
| 触发 AoI 事件(`onEnterAoI` 等) | ✅(对 Real 周围) | ✅(对 Ghost 周围,事件经 Real 同步) |
| 持有 Haunt 列表 | ✅ | ❌ |
| 持有到 Real 的通道(`pRealChannel_`) | ❌ | ✅ |

### 2.5 与传统 MMOG 的对比

| 维度 | 传统分区分服 | BigWorld Ghost 机制 |
|------|------------|---------------------|
| 边界 | 硬边界(玩家必须 logout/login) | 软边界(玩家无感知) |
| 跨区交互 | 不支持 | 支持(Ghost 让对方可见) |
| 负载均衡 | 静态(按区分配) | 动态(Cell 可在 CellApp 间迁移) |
| 状态一致性 | 强(单一进程内) | 最终一致(Real → Ghost 推送) |
| 故障恢复 | 整区不可用 | Real 可在备份 CellApp 上恢复 |
| 网络开销 | 区间无 | Ghost 通信占用带宽 |
| 实现复杂度 | 简单 | 极高(Ghost 同步是 CellApp 最复杂部分) |

### 2.6 设计哲学

BigWorld Ghost 机制体现了几个关键设计哲学:

1. **权威单一(Source of Truth)**:整个集群中,某个 Entity 的权威状态只存在一个地方(Real)。所有 Ghost 都是 Real 的副本,没有"分布式一致性"问题。
2. **位置透明(Location Transparency)**:脚本不需要知道一个 Entity 是 Real 还是 Ghost。调用 `entity.teleport(...)` 在 Real 和 Ghost 上行为一致(只是 Ghost 会转发给 Real)。
3. **最终一致性(Eventual Consistency)**:Ghost 的状态会滞后于 Real,但在网络正常情况下滞后很小(几十毫秒级)。
4. **就近服务(Locality)**:Real 周围的 CellApp 都有 Ghost,使得跨 Cell 的视野、碰撞、AoI 都能在本地解决,不需要每次都跨进程查 Real。
5. **故障隔离(Failure Isolation)**:Real 死了,可以由 Backup 恢复;Ghost 死了,Real 会重新创建。

---

## 三、Ghost 的数据结构总览

### 3.1 总体类图

```
                ┌─────────────────────────────────────────────┐
                │                  Entity                     │
                │  (Python 对象,Real 或 Ghost 二态)           │
                │                                             │
                │ - pReal_      : RealEntity*  (NULL=Ghost)  │
                │ - pRealChannel_ : CellAppChannel* (NULL=Real)│
                │ - nextRealAddr_ : Mercury::Address          │
                │ - numTimesRealOffloaded_ : uint16           │
                │ - properties_ : vector<ScriptObject>        │
                │ - volatileInfo_ : VolatileInfo              │
                │ - lastEventNumber_ : EventNumber           │
                │ - eventHistory_ : EventHistory             │
                │ - pSpace_      : Space*                    │
                │ - pRangeListNode_ : EntityRangeListNode*   │
                └────────────┬────────────────────────────────┘
                             │
                ┌────────────┴───────────────┐
                │ (pReal_ != NULL 时)         │ (pReal_ == NULL 时)
                ▼                            ▼
   ┌───────────────────────────┐     ┌──────────────────────────┐
   │       RealEntity          │     │  (无独立类)              │
   │  (Real 扩展数据)          │     │  Ghost 共用 Entity 主体  │
   │                           │     └──────────────────────────┘
   │ - haunts_ : Haunts        │
   │ - pWitness_ : Witness*    │
   │ - pChannel_ : UDPChannel* │
   │ - controlledBy_ : MailBoxRef │
   │ - velocity_ : Vector3     │
   │ - creationTime_ : GameTime│
   │ - removalHandle_          │
   └───────────────────────────┘
                │
                │ contains
                ▼
   ┌───────────────────────────┐
   │   RealEntity::Haunt       │
   │  (一个 Ghost 在某个         │
   │   CellApp 上的位置)         │
   │                           │
   │ - pChannel_ : CellAppChannel* │
   │ - creationTime_ : GameTime│
   └───────────────────────────┘
                ▲
                │ managed by
                │
   ┌───────────────────────────┐
   │   EntityGhostMaintainer   │
   │   : public CellInfoVisitor│
   │                           │
   │ - offloadChecker_         │
   │ - pEntity_                │
   │ - ownAddress_             │
   │ - hysteresisArea_         │
   │ - pOffloadDestination_    │
   │ - numGhostsCreated_       │
   └───────────────────────────┘
```

### 3.2 关键数据关系

```
Real Entity (CellApp #1)
  │
  │ 持有 RealEntity::Haunts (vector<Haunt>)
  │
  ├── Haunt[0] -> CellAppChannel -> CellApp #2 (Ghost 在那里)
  ├── Haunt[1] -> CellAppChannel -> CellApp #3 (Ghost 在那里)
  └── Haunt[2] -> CellAppChannel -> CellApp #4 (Ghost 在那里)

每个 Ghost 通过 Entity::pRealChannel_ 指回 CellApp #1 (Real 所在)
```

### 3.3 Cell 与 Entity 的关系

```
Space (一个无缝空间)
  │
  │ 包含多个 Cell (按 BSP 树划分)
  │
  ├── Cell A (在 CellApp #1)
  │     │
  │     │ realEntities_ : vector<Entity*>
  │     │
  │     ├── Real Entity P
  │     ├── Real Entity Q
  │     └── ...
  │
  ├── Cell B (在 CellApp #2)
  │     │
  │     │ realEntities_ : vector<Entity*>
  │     │
  │     ├── Real Entity X
  │     └── ...
  │
  └── (CellApp #1 上的 Cell A' 是 Cell A 在另一个 Space 的副本,
       如果有的话——通常一个 CellApp 承载多个 Cell)
```

**关键洞察**:**Cell 只持有 Real Entity 列表**。Ghost Entity 由 Space 持有(在 `Space::entities_` 中),但**不在** Cell::realEntities_ 中。这是 Ghost 与 Real 在数据结构层面的根本区分。

参考 `server/cellapp/cell.hpp:51-81`:

```cpp
class Entities
{
public:
    typedef BW::vector< EntityPtr > Collection;
    // ...
private:
    Collection collection_;
};

// Cell 类
class Cell
{
    // ...
private:
    Entities realEntities_;   // 仅 Real Entity
    // ...
};
```

---

## 四、Entity 类的 Real/Ghost 二态

### 4.1 Entity 类关键字段

下面列出 Entity 类中与 Ghost 机制直接相关的字段(完整定义见 `server/cellapp/entity.hpp:138-860`):

```cpp
// server/cellapp/entity.hpp:765-851
class Entity : public PyObjectPlus
{
    // ...
private:
    Space *             pSpace_;             // 所属 Space

    EntityID            id_;                 // 实体 ID(全局唯一)
    EntityTypePtr       pEntityType_;        // 实体类型

    Position3D          globalPosition_;     // 全局位置
    Direction3D         globalDirection_;    // 全局方向

    Position3D          localPosition_;      // 局部位置(相对于 Vehicle)
    Direction3D         localDirection_;     // 局部方向

    Mercury::Address    baseAddr_;           // Base 实体地址(在 BaseApp 上)

    Entity *            pVehicle_;           // 当前乘坐的 Vehicle
    uint8               vehicleChangeNum_;    // Vehicle 变更计数

    AoIUpdateSchemeID   aoiUpdateSchemeID_;  // AoI 更新方案 ID

    // =================== Real/Ghost 区分核心字段 ===================
    NumTimesRealOffloadedType numTimesRealOffloaded_;  // Real 被 offload 次数

    CellAppChannel *    pRealChannel_;       // Ghost 持有:指向 Real 所在 CellApp
    Mercury::Address    nextRealAddr_;       // 切换中:下一个 Real 的地址

    RealEntity *        pReal_;              // Real 持有:RealEntity 对象
    // =================================================================

    typedef BW::vector<ScriptObject> Properties;
    Properties           properties_;        // 实体属性(Real+Ghost 或仅 Ghost)

    PropertyOwnerLink<Entity> propertyOwner_;

    EventHistory         eventHistory_;      // 事件历史(Real 与 Ghost 都有)

    bool                 isDestroyed_;
    bool                 inDestroy_;
    bool                 isInAoIOffload_;
    bool                 isOnGround_;

    VolatileInfo         volatileInfo_;      // 易变信息(是否同步 pos/dir 等)
    VolatileNumber       volatileUpdateNumber_;

    float                topSpeed_;
    float                topSpeedY_;
    uint16               physicsCorrections_;
    uint64               physicsLastValidated_;
    float                physicsNetworkJitterDebt_;

    PropertyEventStamps   propertyEventStamps_;
    EventNumber           lastEventNumber_;

    EntityRangeListNode * pRangeListNode_;   // 范围链表节点
    RangeTrigger *        pRangeListAppealTrigger_;

    Controllers *         pControllers_;     // 控制器集合

    bool                  shouldReturnID_;

    EntityExtra **        extras_;           // 扩展槽

    typedef BW::vector< RangeTrigger * > Triggers;
    Triggers              triggers_;

    ScriptDict            exposedForReplayClientProperties_;

    enum { NOT_WITNESSED_THRESHOLD = 3 };
    mutable int           periodsWithoutWitness_;

    Chunk*                pChunk_;
    Entity*               pPrevInChunk_;
    Entity*               pNextInChunk_;

    EntityProfiler        profiler_;

    static EntityPopulation population_;
    static EntityCallbackBuffer s_callbackBuffer_;

    friend class RealEntity;
    friend class EntityRangeListNode;
};
```

### 4.2 关键字段解读

#### 4.2.1 `pReal_` 与 `pRealChannel_` 的互斥性

这是 Real/Ghost 二态的核心。再次强调断言:

```cpp
// server/cellapp/entity.ipp:113
MF_ASSERT( !(pReal_ && pRealChannel_) );
```

设计意图:**任意时刻,Entity 要么是 Real(持有 RealEntity),要么是 Ghost(持有到 Real 的通道)**。两者不可共存,除非在非常短暂的转换窗口(实际上代码通过 `nextRealAddr_` 字段来处理这种过渡,见 4.2.2)。

#### 4.2.2 `nextRealAddr_`:Ghost 切换 Real 的过渡状态

`nextRealAddr_` 是 Ghost 同步机制中最微妙的字段之一。它表示:**Ghost 已被告知下一个 Real 的地址,但还未收到 `ghostSetReal` 确认**。

```cpp
// server/cellapp/entity.hpp:197-198
const Mercury::Address & nextRealAddr() const { return nextRealAddr_; }
```

三种状态:

| `pRealChannel_` | `nextRealAddr_` | 含义 |
|-----------------|------------------|------|
| 非 NULL | `Address::NONE` | 正常 Ghost 状态,Real 在 `pRealChannel_->addr()` |
| 非 NULL | 非 NONE | Real 正在 offload,`nextRealAddr_` 是新 Real 地址 |
| NULL | `Address::NONE` | Real 实体(本身是 Real) |

`isOffloadingTo` 方法利用这两个字段判断 Ghost 是否正在向某地址 offload:

```cpp
// server/cellapp/entity.cpp:1952-1955
bool Entity::isOffloadingTo( const Mercury::Address & addr ) const
{
    return this->realAddr() == nextRealAddr_ && nextRealAddr_ == addr;
}
```

#### 4.2.3 `numTimesRealOffloaded_`:Ghost 切换的"代际"标识

每次 Real offload(从一个 CellApp 迁移到另一个),`numTimesRealOffloaded_` 会递增。这个值用于**检测乱序消息**:

```cpp
// server/cellapp/entity.cpp:4831-4849
void Entity::ghostSetReal( const CellAppInterface::ghostSetRealArgs & args )
{
    AUTO_SCOPED_PROFILE( "ghostSetReal" );
    NumTimesRealOffloadedType expected = numTimesRealOffloaded_ + 1;

    if (args.numTimesRealOffloaded != expected)
    {
        WARNING_MSG( "Entity::ghostSetReal( %u ): "
                    "Invalid subsequence id. Expected %d. Got %d\n",
                id_, expected, args.numTimesRealOffloaded );

        // 消息乱序,缓冲到 BufferedGhostMessages
        BufferedGhostMessages & bufferedMessages =
            CellApp::instance().bufferedGhostMessages();
        BufferedGhostMessage * pMsg =
            BufferedGhostMessageFactory::createGhostSetRealMessage( id_, args );

        bufferedMessages.delaySubsequence( id_, args.owner, pMsg );
        return;
    }

    numTimesRealOffloaded_ = args.numTimesRealOffloaded;
    // ...
}
```

如果 Ghost 收到的 `ghostSetReal` 消息中 `numTimesRealOffloaded` 不是 `current + 1`,说明消息乱序(可能旧 Real 的消息还在路上),需要缓冲等待。

#### 4.2.4 `properties_`:Real 与 Ghost 持有不同的属性集

BigWorld 的 EntityDef 中,属性按数据域划分为:

| 域 | 标识 | 持有者 | 说明 |
|----|------|--------|------|
| `CELL_DATA` | Ghost 属性 | Real + Ghost | Ghost 也能访问的属性(如位置相关) |
| `REAL_DATA` | Real 属性 | 仅 Real | 只有 Real 持有(如内部状态、CD 等) |

`propCountGhost()` 返回 Ghost 属性数,`propCountGhostPlusReal()` 返回总数。

```cpp
// server/cellapp/entity.cpp:2047-2056 (convertRealToGhost 中)
MF_ASSERT( properties_.size() == pEntityType_->propCountGhostPlusReal() );
for (uint i = pEntityType_->propCountGhost(); i < properties_.size(); ++i)
{
    if (properties_[i])
    {
        pEntityType_->propIndex(i)->dataType()->detach( properties_[i] );
    }
}
properties_.erase( properties_.begin() + pEntityType_->propCountGhost(),
    properties_.end() );
```

**Real → Ghost 转换时,Real 属性被 detach 并从 `properties_` 中删除**。反向转换(Ghost → Real)时,会从流中读取 Real 属性并 attach:

```cpp
// server/cellapp/entity.cpp:4732-4750 (readRealDataFromStreamForOnloadInternal)
MF_ASSERT( properties_.size() == pEntityType_->propCountGhost() );
properties_.insert( properties_.end(),
    pEntityType_->propCountGhostPlusReal()-properties_.size(),
    ScriptObject() );
for (uint i = pEntityType_->propCountGhost(); i < properties_.size(); ++i)
{
    DataDescription * pDataDescr = pEntityType_->propIndex( i );
    // ... 从流中读取并 attach
}
```

### 4.3 Entity 的关键方法分类

Entity 的方法可按 Real/Ghost 维度分类:

| 方法 | Real 调用 | Ghost 调用 | 备注 |
|------|----------|------------|------|
| `isReal()` | true | false | 二态判定 |
| `isRealToScript()` | true | 视配置 | 用于脚本可见性 |
| `initReal()` | ✅ | ❌ | Real 初始化 |
| `initGhost()` | ❌ | ✅ | Ghost 初始化 |
| `convertRealToGhost()` | ✅ | ❌ | Real 变 Ghost |
| `convertGhostToReal()` | ❌ | ✅ | Ghost 变 Real |
| `createGhost()` | ✅ | ❌ | Real 创建远程 Ghost |
| `delGhost()` | ❌ | ✅ | Ghost 自销毁 |
| `offload()` | ✅ | ❌ | Real offload 到别处 |
| `onload()` | ❌ | ✅ | Ghost 收到 offload 数据,变 Real |
| `ghostSetReal()` | ❌ | ✅ | Ghost 收到 Real 切换通知 |
| `ghostSetNextReal()` | ❌ | ✅ | Ghost 收到 Real 即将切换通知 |
| `ghostPositionUpdate()` | ❌ | ✅ | Ghost 收到 Real 推送的位置 |
| `ghostHistoryEvent()` | ❌ | ✅ | Ghost 收到 Real 推送的事件 |
| `forwardMessageToReal()` | 静态 | 静态 | 转发消息到 Real |

---

## 五、RealEntity 与 Haunt 内嵌类

### 5.1 RealEntity 类定义

`RealEntity` 是 Entity 在 Real 状态下的"扩展数据载体"。它**不是** Entity 的子类,而是一个独立的类,由 Entity 持有指针 `pReal_`。

```cpp
// server/cellapp/real_entity.hpp:46-263
class RealEntity
{
public:
    class Haunt
    {
        // ... 见 5.2
    };

    typedef BW::vector< Haunt > Haunts;

    static void addWatchers();

    RealEntity( Entity & owner );

    bool init( BinaryIStream & data, CreateRealInfo createRealInfo,
            Mercury::ChannelVersion channelVersion = Mercury::SEQ_NULL,
            const Mercury::Address * pBadHauntAddr = NULL );

    void destroy( const Mercury::Address * pNextRealAddr = NULL );

    void writeOffloadData( BinaryOStream & data, bool isTeleport );

    // ... Witness 管理
    void enableWitness( BinaryIStream & data, Mercury::ReplyID replyID );
    void disableWitness( bool isRestore = false );

    Entity & entity()                                { return entity_; }
    Witness * pWitness()                             { return pWitness_; }

    Haunts::iterator hauntsBegin() { return haunts_.begin(); }
    Haunts::iterator hauntsEnd() { return haunts_.end(); }
    int numHaunts() const { return haunts_.size(); }

    void addHaunt( CellAppChannel & channel );
    Haunts::iterator delHaunt( Haunts::iterator iter );

    HistoryEvent * addHistoryEvent( uint8 type,
        MemoryOStream & stream,
        const MemberDescription & description,
        int16 msgStreamSize,
        HistoryEvent::Level level = FLT_MAX );

    void backup();
    void autoBackup();

    void addDelGhostMessage( Mercury::Bundle & bundle );
    void deleteGhosts();

    const Vector3 & velocity() const                { return velocity_; }

    EntityRemovalHandle removalHandle() const        { return removalHandle_; }
    void removalHandle( EntityRemovalHandle h )      { removalHandle_ = h; }

    const EntityMailBoxRef & controlledByRef() const { return controlledBy_; }

    GameTime creationTime() const    { return creationTime_; }

    void delControlledBy( EntityID deadID );

    Mercury::UDPChannel & channel()    { return *pChannel_; }

    bool controlledBySelf() const    { return entity_.id() == controlledBy_.id; }
    bool controlledByOther() const
        { return !this->controlledBySelf() && (controlledBy_.id != 0); }

    void teleport( const EntityMailBoxRef & dstMailBoxRef );
    bool teleport( const EntityMailBoxRef & nearbyMBRef,
        const Vector3 & position, const Vector3 & direction );

    bool isWitnessed() const;

private:
    ~RealEntity();

    bool readOffloadData( BinaryIStream & data,
        const Mercury::Address * pBadHauntAddr = NULL,
        bool * pHasChangedSpace = NULL );
    void readBackupData( BinaryIStream & data );
    // ...

    Entity & entity_;
    Witness * pWitness_;
    Haunts haunts_;
    EntityRemovalHandle removalHandle_;
    EntityMailBoxRef controlledBy_;
    Vector3 velocity_;
    Vector3 positionSample_;
    GameTime positionSampleTime_;
    GameTime creationTime_;
    AutoBackupAndArchive::Policy shouldAutoBackup_;
    Mercury::UDPChannel * pChannel_;
    SpaceEntryID recordingSpaceEntryID_;
};
```

### 5.2 RealEntity 持有的关键数据

| 字段 | 类型 | 用途 |
|------|------|------|
| `entity_` | `Entity &` | 反向引用(所属 Entity) |
| `pWitness_` | `Witness *` | 玩家视野对象(仅玩家 Real 才有) |
| `haunts_` | `Haunts` | **本 Real 在哪些 CellApp 上有 Ghost** |
| `removalHandle_` | `EntityRemovalHandle` | 在 Cell::realEntities_ 中的句柄 |
| `controlledBy_` | `EntityMailBoxRef` | 控制本实体的客户端(玩家 Base) |
| `velocity_` | `Vector3` | 实体速度(由位置采样计算) |
| `positionSample_` | `Vector3` | 上次位置采样 |
| `positionSampleTime_` | `GameTime` | 上次采样时间 |
| `creationTime_` | `GameTime` | Real 创建时间(用于 Ghost 最小寿命检查) |
| `shouldAutoBackup_` | `AutoBackupAndArchive::Policy` | 自动备份策略 |
| `pChannel_` | `Mercury::UDPChannel *` | 到 BaseApp 的通道(用于 backup、setClient 等) |
| `recordingSpaceEntryID_` | `SpaceEntryID` | 录制相关 |

### 5.3 Haunt 内嵌类

`Haunt` 是 RealEntity 的内嵌类,表示"本 Real 在某个 CellApp 上有一个 Ghost"。

```cpp
// server/cellapp/real_entity.hpp:76-98
class Haunt
{
public:
    Haunt( CellAppChannel * pChannel, GameTime creationTime ) :
        pChannel_( pChannel ),
        creationTime_( creationTime )
    {}

    // A note about these accessors.  We don't need to guard their callers
    // with ChannelSenders because having haunts guarantees that the
    // underlying channel is regularly sent.  If haunts are destroyed and
    // the channel becomes irregular, unsent data is sent immediately.
    CellAppChannel & channel() { return *pChannel_; }
    Mercury::Bundle & bundle() { return pChannel_->bundle(); }
    const Mercury::Address & addr() const { return pChannel_->addr(); }

    void creationTime( GameTime time )    { creationTime_ = time; }
    GameTime creationTime() const            { return creationTime_; }

private:
    CellAppChannel * pChannel_;
    GameTime creationTime_;
};
```

#### 5.3.1 Haunt 的设计要点

1. **轻量**:只持有 `CellAppChannel *` 和 `creationTime_`。
2. **不持有 Ghost 的指针**:Real 不直接持有 Ghost 实体的指针,只持有到 Ghost 所在 CellApp 的通道。这种间接性是必须的——Ghost 可能在本 CellApp 不存在(在另一个 CellApp 上),即使存在,直接访问会破坏进程隔离。
3. **creationTime_ 用于最小寿命检查**:见 8.2 节,刚创建的 Ghost 不会被立即删除,避免抖动。
4. **bundle() 直接访问**:Real 通过 `haunt.bundle()` 直接将消息写入到对应 CellApp 的 Bundle 中,Mercury 网络层会自动批量发送。

#### 5.3.2 Haunt 的注释分析

源码注释中的这段话非常重要:

> A note about these accessors. We don't need to guard their callers with ChannelSenders because having haunts guarantees that the underlying channel is regularly sent. If haunts are destroyed and the channel becomes irregular, unsent data is sent immediately.

含义:
- 只要 Real 还有 Haunt,对应 CellAppChannel 就会被**定期发送**(因为 Real 在每个 tick 都会推送 ghostPositionUpdate)。
- 不需要显式调用 `ChannelSender` 守卫来保证发送。
- 当 Haunt 被销毁且 Channel 不再被定期使用时,Mercury 会立即发送未送数据(防止数据丢失)。

### 5.4 RealEntity 的关键方法

#### 5.4.1 `addHaunt` / `delHaunt`

```cpp
// server/cellapp/real_entity.cpp:845-858
void RealEntity::addHaunt( CellAppChannel & channel )
{
    haunts_.push_back( Haunt( &channel, CellApp::instance().time() ) );
}

RealEntity::Haunts::iterator RealEntity::delHaunt( Haunts::iterator iter )
{
    return haunts_.erase( iter );
}
```

注意 `delHaunt` 返回下一个迭代器,这是 STL erase 的标准模式,允许在遍历中安全删除。

#### 5.4.2 `deleteGhosts`:销毁所有 Ghost

```cpp
// server/cellapp/real_entity.cpp:753-761
void RealEntity::deleteGhosts()
{
    for (Haunts::iterator iter = haunts_.begin(); iter != haunts_.end(); ++iter)
    {
        this->addDelGhostMessage( iter->bundle() );
    }

    haunts_.clear();
}
```

这个方法在 Entity::destroy() 中被调用,用于 Real 销毁前通知所有 Ghost 也销毁。

#### 5.4.3 `addDelGhostMessage`:向某个 Haunt 发送 delGhost

```cpp
// server/cellapp/real_entity.cpp:741-746
void RealEntity::addDelGhostMessage( Mercury::Bundle & bundle )
{
    // TODO: Better handling of prefixed empty messages
    bundle.startMessage( CellAppInterface::delGhost );
    bundle << entity_.id();
}
```

注意:这里只是把消息添加到 bundle,真正的发送由 Mercury 在 channel 定期发送时完成。

#### 5.4.4 `writeOffloadData`:offload 时序列化 Real 数据

```cpp
// server/cellapp/real_entity.cpp:487-565
void RealEntity::writeOffloadData( BinaryOStream & data, bool isTeleport )
{
    StreamHelper::addRealEntity( data );
    // --------    above here read off in our constructor above

    pChannel_->addToStream( data );

    // Put on velocity
    data << velocity_ << entity_.topSpeed_ << entity_.topSpeedY_
        << entity_.physicsCorrections_;

    data << uint8( shouldAutoBackup_ );

    // Write current space ID so a change can be detected
    data << entity_.space().id();

    data << isTeleport;

    bool isAlreadyHaunted = false;

    const Mercury::Address & ourAddr =
        CellApp::instance().interface().address();
    for (Haunts::iterator iter = haunts_.begin(); iter != haunts_.end(); ++iter)
    {
        isAlreadyHaunted |= (iter->addr() == ourAddr);
    }

    int numHaunts = haunts_.size();

    if (!isAlreadyHaunted)
    {
        numHaunts += 1;
    }

    data << numHaunts;

    // Send all the addresses it has ghosts on. We don't send cell IDs
    // because if the destination doesn't have a cell ID that we have a
    // ghost on, it needs the address so it can tell the cell to delGhost
    for (Haunts::const_iterator iter = haunts_.begin();
            iter != haunts_.end();
            ++iter)
    {
        const Haunt & haunt = *iter;
        data << haunt.addr();
    }

    // Always add our address since we will turn into a ghost after the offload.
    if (!isAlreadyHaunted)
    {
        data << ourAddr;
    }

    data << controlledBy_;

    CellApp::instance().adjustLoadForOffload( entity_.profiler().load() );

    data << entity_.profiler();

    entity_.writeRealControllersToStream( data );

    data << entity_.periodsWithoutWitness_;

    data << recordingSpaceEntryID_;

    // ----- below here read off in our constructor above
    if (pWitness_ != NULL)
    {
        data << 'W';
        pWitness_->writeOffloadData( data );
    }
    else
    {
        data << '-';
    }
}
```

**关键设计**:
1. **Haunt 地址列表**被序列化到流中,目标 CellApp 收到后会通知这些 Haunt:"新的 Real 在我这里"。
2. **本机地址**总是被加入列表(即使已存在),因为 offload 后本机将变成 Ghost。
3. **Witness 数据**用 `'W'` 或 `'-'` 标记是否存在。

#### 5.4.5 `readOffloadData`:目标 CellApp 收到 offload 后反序列化

```cpp
// server/cellapp/real_entity.cpp:296-413
bool RealEntity::readOffloadData( BinaryIStream & data,
        const Mercury::Address * pBadHauntAddr, bool * pHasChangedSpace )
{
    pChannel_->initFromStream( data, entity_.baseAddr() );

    // Get velocity
    data >> velocity_ >> entity_.topSpeed_ >> entity_.topSpeedY_ >>
        entity_.physicsCorrections_;
    entity_.physicsLastValidated_ = timestamp(); // don't offload > once/sec

    uint8 shouldAutoBackup;
    data >> shouldAutoBackup;
    shouldAutoBackup_ = AutoBackupAndArchive::Policy( shouldAutoBackup );

    SpaceID oldSpaceID;
    data >> oldSpaceID;
    bool isTeleported;
    data >> isTeleported;

    bool hasChangedSpace = (oldSpaceID != entity_.space().id());

    if (pHasChangedSpace)
    {
        *pHasChangedSpace = hasChangedSpace;
    }

    // If the data was sent from a previous RealEntity, the data should
    // contain a list of the haunts for this entity.
    unsigned int numHaunts;
    data >> numHaunts;

    MF_ASSERT( numHaunts > 0 );

    bool        areWeHaunted = false;
    CellAppInterface::ghostSetRealArgs setRealArgs;
    setRealArgs.numTimesRealOffloaded = entity_.numTimesRealOffloaded();
    setRealArgs.owner = CellApp::instance().interface().address();

    for (int i = 0; i < (int)numHaunts; i++)
    {
        Mercury::Address    addr;
        data >> addr;

        // we don't care if it's our own address -
        // it could be from a local teleport or some such
        if (addr == CellApp::instance().interface().address())
        {
            areWeHaunted = true;
            continue;
        }

        // Skip address if this is the bad haunt address - this is part of an
        // onload from a failed teleport back to the originating cellapp, and
        // no ghost was created on the destination.
        if (pBadHauntAddr && addr == *pBadHauntAddr)
        {
            WARNING_MSG( "RealEntity::readOffloadData: "
                "Not notifying app %s because of failed teleport for %u\n",
                pBadHauntAddr->c_str(), entity_.id() );
            continue;
        }

        // find the channel for that address
        CellAppChannel * pAppChannel = CellAppChannels::instance().get( addr );

        if ((pAppChannel == NULL) ||
                !pAppChannel->isGood())
        {
            WARNING_MSG( "RealEntity::readOffloadData: "
                "Not notifying ghost for %u on dead app %s\n",
                entity_.id(), addr.c_str() );

            continue;
        }

        Mercury::ChannelSender sender( pAppChannel->channel() );
        Mercury::Bundle & bundle = sender.bundle();

        if (!hasChangedSpace && !isTeleported)
        {
            this->addHaunt( *pAppChannel );

            CellAppInterface::ghostSetRealArgs & rGhostSetRealArgs =
                CellAppInterface::ghostSetRealArgs::start( bundle,
                    entity_.id() );

            rGhostSetRealArgs = setRealArgs;
        }
        else
        {
            this->addDelGhostMessage( pAppChannel->bundle() );
        }
    }

    // They should not have offloaded the entity without creating a ghost
    // here first.
    MF_ASSERT( areWeHaunted );

    data >> controlledBy_;

    data >> entity_.profiler();

    CellApp::instance().adjustLoadForOffload( -entity_.profiler().load() );

    entity_.readRealControllersFromStream( data );

    data >> entity_.periodsWithoutWitness_;

    data >> recordingSpaceEntryID_;

    // INVALID_POSITION indicates position is not yet set. This will be
    // done in onTeleportSuccess.
    const bool needsPhysicsCorrection =
        isTeleported && (entity_.localPosition_ != Entity::INVALID_POSITION);

    return needsPhysicsCorrection;
}
```

**核心逻辑**:
1. 读取所有 Haunt 地址。
2. 对每个地址:
   - 如果是自己,标记 `areWeHaunted = true`(说明本机之前有 Ghost,现在变 Real)。
   - 如果是 teleport 失败的 bad haunt,跳过。
   - 否则,向该地址发送 `ghostSetReal` 消息(告诉 Ghost 新 Real 在这里),并将该 Haunt 加入新的 Real 的 `haunts_` 列表。
   - 如果是跨 Space 的 teleport 或显式 teleport,则发送 `delGhost`(让旧 Ghost 销毁,因为新 Space 中不需要)。
3. 断言 `areWeHaunted`:**offload 必须保证目标 CellApp 已经先创建了 Ghost**。这是 offload 的前置条件。

---

## 六、EntityGhostMaintainer 深度剖析

### 6.1 类定义与职责

```cpp
// server/cellapp/entity_ghost_maintainer.hpp:31-57
class EntityGhostMaintainer : public CellInfoVisitor
{
public:
    EntityGhostMaintainer( OffloadChecker & offloadChecker,
            EntityPtr pEntity );
    virtual ~EntityGhostMaintainer();

    void check();

    // Override from CellInfoVisitor.
    virtual void visit( CellInfo & cellInfo );

private:
    Cell & cell();

    void checkEntityForOffload();
    bool markHaunts();
    void createOrUnmarkRequiredHaunts();
    void deleteMarkedHaunts();

    OffloadChecker &            offloadChecker_;
    EntityPtr                  pEntity_;
    const Mercury::Address &    ownAddress_;
    BW::Rect                   hysteresisArea_;
    CellAppChannel *            pOffloadDestination_;
    uint                        numGhostsCreated_;
};
```

#### 6.1.1 职责

`EntityGhostMaintainer` 负责为**单个 Real Entity**维护 Ghost 集合:

1. **检测是否需要 offload**:如果 Real 不在它的"home cell"上(基于位置),应该 offload 到正确的 Cell。
2. **标记所有现有 Haunt**:遍历 `pReal_->haunts_`,将每个 channel 标记为 1。
3. **创建或取消标记需要的 Haunt**:遍历 Real 周围所有 Cell,对每个应该有 Ghost 的 Cell:
   - 如果已有 Haunt(channel 已标记),取消标记(标记为 0)。
   - 如果没有 Haunt,创建新 Ghost。
4. **删除被标记的 Haunt**:剩下的标记为 1 的 Haunt 是不再需要的,删除它们(发送 delGhost)。

### 6.2 check() 主流程

```cpp
// server/cellapp/entity_ghost_maintainer.cpp:46-65
void EntityGhostMaintainer::check()
{
    if (this->cell().shouldOffload())
    {
        this->checkEntityForOffload();
    }

    // We mark all the haunts for this entity, and then we unmark all the valid
    // ones. The invalid ghosts are left marked and are deleted.

    bool doesOffloadDestinationHaveGhost = this->markHaunts();

    this->createOrUnmarkRequiredHaunts();

    MF_ASSERT( (pOffloadDestination_ == NULL) ||
            doesOffloadDestinationHaveGhost ||
            (numGhostsCreated_ == 1) );

    this->deleteMarkedHaunts();
}
```

**算法步骤**:
1. **可选**:如果本 Cell 配置了 `shouldOffload`,检查 Real 是否需要 offload 到另一个 Cell。
2. **markHaunts()**:把所有现有 Haunt 的 channel 标记为 1。返回 offload 目标是否已有 Ghost。
3. **createOrUnmarkRequiredHaunts()**:遍历应该有 Ghost 的 Cell,取消标记(标记为 0)或创建新 Ghost。
4. **断言**:如果 offload 目标存在,要么目标已有 Ghost,要么本次刚创建了一个 Ghost。这保证 offload 不会丢失 Ghost。
5. **deleteMarkedHaunts()**:删除仍标记为 1 的 Haunt(不再需要的 Ghost)。

### 6.3 checkEntityForOffload():检测 Real 是否应该迁移

```cpp
// server/cellapp/entity_ghost_maintainer.cpp:81-113
void EntityGhostMaintainer::checkEntityForOffload()
{
    // Find out where we really want to live.
    const Vector3 & position = pEntity_->position();
    const CellInfo * pHomeCell = pEntity_->space().pCellAt(
        position.x, position.z );

    if ((pHomeCell == NULL) || (pHomeCell == &(this->cell().cellInfo())))
    {
        // Don't offload to ourselves.
        return;
    }

    if (pHomeCell->isDeletePending())
    {
        // Don't offload to a cell that is being deleted.
        return;
    }

    CellAppChannel * pOffloadDestination =
        CellAppChannels::instance().get( pHomeCell->addr() );

    if (!pOffloadDestination || !pOffloadDestination->isGood())
    {
        // Don't offload if other cell has failed or died.
        return;
    }

    // OK to offload now.
    pOffloadDestination_ = pOffloadDestination;

    offloadChecker_.addToOffloads( pEntity_, pOffloadDestination_ );
}
```

**判定逻辑**:
1. 根据 Real 当前位置,查询它"应该"所在的 Cell(`Space::pCellAt`)。
2. 如果"home cell"就是当前 cell,不 offload。
3. 如果 home cell 正在被删除,不 offload。
4. 如果 home cell 的 CellAppChannel 不可用(故障),不 offload。
5. 否则,记录 offload 目标,加入 OffloadChecker 的待 offload 列表。

### 6.4 markHaunts():标记现有 Haunt

```cpp
// server/cellapp/entity_ghost_maintainer.cpp:125-144
bool EntityGhostMaintainer::markHaunts()
{
    RealEntity * pReal = pEntity_->pReal();

    bool doesOffloadDestinationHaveGhost = false;

    RealEntity::Haunts::iterator iHaunt = pReal->hauntsBegin();
    while (iHaunt != pReal->hauntsEnd())
    {
        if (pOffloadDestination_ == &(iHaunt->channel()))
        {
            doesOffloadDestinationHaveGhost = true;
        }

        iHaunt->channel().mark( 1 );
        ++iHaunt;
    }

    return doesOffloadDestinationHaveGhost;
}
```

**算法**:遍历 Real 的所有 Haunt,把每个 channel 的 mark 设为 1。同时检测 offload 目标是否已有 Ghost(用于后续断言)。

**mark 的妙用**:`CellAppChannel::mark(int)` 是一个通用标记位,不同的使用者可以复用。这里 EntityGhostMaintainer 用 1 表示"待删除候选",稍后 createOrUnmarkRequiredHaunts 会把仍需要的设回 0,最后 deleteMarkedHaunts 删除仍为 1 的。

### 6.5 createOrUnmarkRequiredHaunts():遍历需要 Ghost 的 Cell

```cpp
// server/cellapp/entity_ghost_maintainer.cpp:159-178
void EntityGhostMaintainer::createOrUnmarkRequiredHaunts()
{
    // TODO: Make this configurable.
    static const float GHOST_FUDGE = 20.f;

    const Vector3 & position = pEntity_->position();

    // Find all the haunts that we should have.
    BW::Rect interestArea( position.x, position.z, position.x, position.z );

    // Entities with an appeal raidus have to ghost more
    interestArea.inflateBy( CellAppConfig::ghostDistance() +
            pEntity_->pType()->description().appealRadius() );

    hysteresisArea_ = interestArea;

    interestArea.inflateBy( GHOST_FUDGE );

    pEntity_->space().visitRect( interestArea, *this );
}
```

**算法**:
1. 以 Real 位置为中心,构造一个矩形区域。
2. 矩形大小 = `ghostDistance + appealRadius`(appealRadius 是实体类型的"吸引力半径",如大型 Boss 需要更远的可见性)。
3. 保存这个矩形作为 `hysteresisArea_`(滞回区域)。
4. 再扩展 `GHOST_FUDGE = 20.f`(额外的边界容差,避免边界抖动)。
5. 用 `Space::visitRect` 遍历所有与该矩形相交的 CellInfo,对每个调用 `visit()`。

### 6.6 visit():对每个候选 Cell 的处理

```cpp
// server/cellapp/entity_ghost_maintainer.cpp:184-231
void EntityGhostMaintainer::visit( CellInfo & cellInfo )
{
    const Mercury::Address & remoteAddress = cellInfo.addr();

    // discard it if it is ourself
    if (remoteAddress == ownAddress_)
    {
        return;
    }

    if (cellInfo.isDeletePending())
    {
        // Do not have ghosts on cells that are about to be deleted.
        return;
    }

    // If it has been marked as an existing haunt then unmark it and bail.
    CellAppChannel & channel = *CellAppChannels::instance().get(
        remoteAddress );

    if (channel.mark() == 1)
    {
        channel.mark( 0 );
        return;
    }

    // Do not create a ghost if we are about to be offloaded. Let the
    // destination do this. This helps with not creating CellAppChannels
    // unnecessarily and also helps prevent race conditions. We still create
    // the ghost on the destination cell.
    if (pOffloadDestination_ && pOffloadDestination_->addr() != remoteAddress)
    {
        return;
    }

    // and if we are not far enough in then toss it too (hysteresis check)
    if (!cellInfo.rect().intersects( hysteresisArea_ ))
    {
        return;
    }

    // Otherwise we should create a new ghost.

    pEntity_->pReal()->addHaunt( channel );
    pEntity_->createGhost( channel.bundle() );

    ++numGhostsCreated_;
}
```

**算法**:
1. **跳过自己**:本 CellApp 的地址跳过(本机是 Real,不需要在本机创建 Ghost)。
2. **跳过待删除 Cell**:正被删除的 Cell 不创建 Ghost。
3. **已存在 Haunt**:如果 channel 已标记为 1(说明已有 Haunt),取消标记为 0,返回。
4. **offload 期间的特殊处理**:如果本 Real 即将被 offload,不在其他 Cell 创建 Ghost(交给目标 Cell 处理),但目标 Cell 仍要创建 Ghost。
5. **滞回检查**:Cell 的矩形必须与 `hysteresisArea_` 相交,才创建 Ghost。这是防抖机制——避免边界抖动导致 Ghost 频繁创建/销毁。
6. **创建 Ghost**:调用 `addHaunt` 加入 Haunt 列表,调用 `createGhost` 发送 createGhost 消息到目标 CellApp。

### 6.7 deleteMarkedHaunts():删除多余 Haunt

```cpp
// server/cellapp/entity_ghost_maintainer.cpp:248-299
void EntityGhostMaintainer::deleteMarkedHaunts()
{
    static const int NEW_REAL_KEEP_GHOST_PERIOD_IN_SECONDS = 2;
    const GameTime NEW_REAL_KEEP_GHOST_PERIOD =
        NEW_REAL_KEEP_GHOST_PERIOD_IN_SECONDS * CellAppConfig::updateHertz();

    const GameTime MINIMUM_GHOST_LIFESPAN =
        CellAppConfig::minGhostLifespanInTicks();

    const GameTime gameTime = CellApp::instance().time();

    RealEntity * pReal = pEntity_->pReal();
    RealEntity::Haunts::iterator iHaunt = pReal->hauntsBegin();

    while (iHaunt != pReal->hauntsEnd())
    {
        RealEntity::Haunt & haunt = *iHaunt;
        CellAppChannel & channel = haunt.channel();

        const bool shouldDelGhost =
            // Too many ghosts deleted in this iteration.
            offloadChecker_.canDeleteMoreGhosts() &&

            // Keep the ghost if we're offloading there.
            (&channel != pOffloadDestination_) &&

            // Keep the ghost if the real entity is new.
            (gameTime - pReal->creationTime() > NEW_REAL_KEEP_GHOST_PERIOD) &&

            // Keep the ghost if the ghost is new.
            (gameTime - haunt.creationTime() > MINIMUM_GHOST_LIFESPAN);

        if (channel.mark() && shouldDelGhost)
        {
            // only bother telling it if it hasn't failed
            if (channel.isGood())
            {
                pReal->addDelGhostMessage( channel.bundle() );
                offloadChecker_.addDeletedGhost();
            }

            iHaunt = pReal->delHaunt( iHaunt );
        }
        else
        {
            ++iHaunt;
        }

        // always clear the mark for the next user
        channel.mark( 0 );
    }
}
```

**删除前的多重保护**:
1. **本 tick 删除配额未满**:`offloadChecker_.canDeleteMoreGhosts()` 检查本 tick 删除的 Ghost 数量未超过上限。
2. **不是 offload 目标**:不要删除即将 offload 的目标 Cell 上的 Ghost(那里需要 Ghost 来接收 offload)。
3. **Real 不是新建的**:Real 创建 2 秒内不删除任何 Ghost(给 Real 一个稳定期)。
4. **Ghost 不是新建的**:Ghost 创建 `minGhostLifespanInTicks`(默认 5 秒)内不删除,避免抖动。

**清理 mark**:无论是否删除,最后都把 mark 清零,为下一个使用者准备。

### 6.8 EntityGhostMaintainer 与 OffloadChecker 的协作

`EntityGhostMaintainer` 是 `OffloadChecker::run()` 在每个 Real 上调用的工具类:

```cpp
// server/cellapp/offload_checker.cpp:43-70
void OffloadChecker::run()
{
    // If this space is shutting down, don't offload any entities so that
    // they are not lost when the cells are shut down.
    if (cell_.space().isShuttingDown())
    {
        return;
    }

    static ProfileVal localProfile( "boundaryCheck" );
    START_PROFILE( localProfile );

    Cell::Entities::iterator iEntity = cell_.realEntities().begin();
    while (iEntity != cell_.realEntities().end())
    {
        EntityPtr pEntity = *iEntity;

        MF_ASSERT( &cell_ == &(pEntity->cell()) );

        EntityGhostMaintainer entityGhostMaintainer( *this, pEntity );
        entityGhostMaintainer.check();
        ++iEntity;
    }

    this->sendOffloads();

    STOP_PROFILE_WITH_DATA( localProfile, offloadList_.size() );
}
```

**调用频率**:`OffloadChecker::run()` 在每个 Cell 的 `checkOffloadsAndGhosts()` 中调用,而后者由 CellApp 在 tick 中定期调用(`checkOffloadsPeriod` 默认 0.1 秒,即每秒 10 次)。

```cpp
// server/cellapp/cell.cpp:163-169
bool Cell::checkOffloadsAndGhosts()
{
    OffloadChecker offloadChecker( *this );
    offloadChecker.run();

    return this->isReadyForDeletion();
}
```

### 6.9 EntityGhostMaintainer 工作流总览

```
                    OffloadChecker::run()
                          │
                          ▼
            遍历 cell_.realEntities_
                          │
              ┌───────────┴───────────┐
              │                       │
              ▼                       ▼
      Real Entity P                Real Entity Q
              │
              ▼
    EntityGhostMaintainer::check()
              │
              ├─► checkEntityForOffload()
              │     └─► 检测 P 是否应该 offload 到另一个 Cell
              │         └─► 如需,offloadChecker_.addToOffloads(pEntity, dest)
              │
              ├─► markHaunts()
              │     └─► 遍历 pReal->haunts_,把 channel.mark(1)
              │
              ├─► createOrUnmarkRequiredHaunts()
              │     └─► 计算需要的 AoI 区域
              │     └─► space.visitRect(area, *this)
              │           └─► 对每个 CellInfo 调用 visit()
              │                 ├─► 已有 Haunt → mark(0) 取消标记
              │                 └─► 应有但无 Haunt → addHaunt + createGhost
              │
              └─► deleteMarkedHaunts()
                    └─► 遍历 haunts_,删除仍标记为 1 的
                    └─► 检查多重保护(配额、寿命、新创建)
                    └─► addDelGhostMessage + delHaunt
```

---

## 七、Ghost 的创建流程

### 7.1 触发条件

Ghost 创建由 **Real 一方主动发起**,触发条件是:

1. Real Entity 移动到了一个新的位置,导致它周围出现了新的 Cell。
2. `EntityGhostMaintainer::check()` 在定期检查中发现某个应该有 Ghost 的 Cell 还没有 Ghost。

### 7.2 创建流程的源码追踪

#### 7.2.1 步骤 1:EntityGhostMaintainer 决定创建 Ghost

见 6.6 节的 `visit()` 方法:

```cpp
// 决定创建 Ghost 后
pEntity_->pReal()->addHaunt( channel );        // 1. 加入 Haunt 列表
pEntity_->createGhost( channel.bundle() );    // 2. 写 createGhost 消息到 bundle
++numGhostsCreated_;
```

#### 7.2.2 步骤 2:Entity::createGhost 写消息到 Bundle

```cpp
// server/cellapp/entity.cpp:4646-4651
void Entity::createGhost( Mercury::Bundle & bundle )
{
    bundle.startMessage( CellAppInterface::createGhost );
    bundle << this->cell().space().id();
    this->writeGhostDataToStream( bundle );
}
```

**消息格式**:
- `createGhost` 消息 ID
- SpaceID
- Ghost 数据流(由 `writeGhostDataToStream` 写入)

#### 7.2.3 步骤 3:writeGhostDataToStream 序列化 Ghost 数据

```cpp
// server/cellapp/entity.cpp:1819-1829
void Entity::writeGhostDataToStream( BinaryOStream & stream ) const
{
    // Note: The id and entityTypeID is not read off by readGhostDataFromStream.
    // They are read by Space::createGhost
    // Note: Also read by BufferGhostMessage to get numTimesRealOffloaded_.
    stream << id_ << this->entityTypeID();

    CompressionOStream compressionStream( stream,
            pEntityType_->description().internalNetworkCompressionType() );
    this->writeGhostDataToStreamInternal( compressionStream );
}
```

```cpp
// server/cellapp/entity.cpp:1836-1876
void Entity::writeGhostDataToStreamInternal( BinaryOStream & stream ) const
{
    stream << numTimesRealOffloaded_ << localPosition_ << isOnGround_ <<
        lastEventNumber_ << volatileInfo_;

    stream << CellApp::instance().interface().address();  // Real 地址
    stream << baseAddr_;
    stream << localDirection_;

    propertyEventStamps_.addToStream( stream );

    TOKEN_ADD( stream, "GProperties" );

    // write our ghost properties to the stream
    for (uint32 i = 0; i < pEntityType_->propCountGhost(); ++i)
    {
        MF_ASSERT( properties_[i] );

        DataDescription * pDataDesc = pEntityType_->propIndex( i );

        ScriptDataSource source( properties_[i] );
        if (!pDataDesc->addToStream( source, stream, false ))
        {
            CRITICAL_MSG( "Entity::writeGhostDataToStream(%u): "
                    "Could not write ghost property %s.%s to stream\n",
                id_, this->pType()->name(), pDataDesc->name().c_str() );
        }
    }
    TOKEN_ADD( stream, "GController" );

    this->writeGhostControllersToStream( stream );

    TOKEN_ADD( stream, "GTail" );
    stream << periodsWithoutWitness_ << aoiUpdateSchemeID_;
}
```

**Ghost 数据流格式**(从 Real 传到 Ghost):

```
┌─────────────────────────────────────────────────────────┐
│ EntityID  id_                                            │
│ EntityTypeID entityTypeID_                               │
├───── CompressionOStream 开始 ─────────────────────────────┤
│ NumTimesRealOffloadedType numTimesRealOffloaded_         │
│ Position3D localPosition_                                 │
│ bool isOnGround_                                         │
│ EventNumber lastEventNumber_                              │
│ VolatileInfo volatileInfo_                                │
│ Mercury::Address realAddr(=本 Real 所在 CellApp)         │
│ Mercury::Address baseAddr_                               │
│ Direction3D localDirection_                              │
│ PropertyEventStamps propertyEventStamps_                 │
│ TOKEN "GProperties"                                      │
│ [Ghost 属性数据 × propCountGhost]                       │
│ TOKEN "GController"                                      │
│ [Ghost Controller 数据]                                  │
│ TOKEN "GTail"                                            │
│ int periodsWithoutWitness_                               │
│ AoIUpdateSchemeID aoiUpdateSchemeID_                     │
├───── CompressionOStream 结束 ─────────────────────────────┤
└─────────────────────────────────────────────────────────┘
```

**关键点**:
1. **Real 地址**:Ghost 收到后,会用这个地址初始化 `pRealChannel_`。
2. **numTimesRealOffloaded_**:用于检测后续 ghostSetReal 消息的乱序。
3. **Ghost 属性**:只发送 `CELL_DATA` 域的属性,不发送 `REAL_DATA`。
4. **TOKEN 标记**:用于流完整性检查,防止版本不匹配。

#### 7.2.4 步骤 4:目标 CellApp 收到 createGhost 消息

```cpp
// server/cellapp/space.cpp:228-266
void Space::createGhost( const Mercury::Address & srcAddr,
        const Mercury::UnpackedMessageHeader & header, BinaryIStream & data )
{
    EntityID entityID;
    data >> entityID;

    CellApp & app = ServerApp::getApp< CellApp >( header );
    Entity * pExistingEntity = app.findEntity( entityID );

    BufferedGhostMessages & bufferedMessages = app.bufferedGhostMessages();

    if ((pExistingEntity != NULL) ||
            bufferedMessages.hasMessagesFor( entityID, srcAddr ))
    {
        // 已存在,缓冲到 BufferedGhostMessages
        BufferedGhostMessage * pMsg =
            BufferedGhostMessageFactory::createBufferedCreateGhostMessage(
                srcAddr, entityID, id_, data );

        if (bufferedMessages.hasMessagesFor( entityID, srcAddr ))
        {
            bufferedMessages.add( entityID, srcAddr, pMsg );
        }
        else // if pExistingEntity != NULL
        {
            TRACE_MSG( "Space::createGhost: "
                    "delaying subsequence for %d from %s\n",
                entityID, srcAddr.c_str() );
            bufferedMessages.delaySubsequence( entityID, srcAddr, pMsg );
        }

        WARNING_MSG( "Space::createGhost(%u): "
                    "Buffered createGhost message for entity %u from %s\n",
                id_, entityID, srcAddr.c_str() );
    }
    else
    {
        this->createGhost( entityID, data );
    }
}
```

**关键判断**:
- 如果 EntityID 已存在(可能 Real 在这里,或已有 Ghost),或已有缓冲消息来自同一地址,**不能直接创建**,而是缓冲到 `BufferedGhostMessages`。
- 否则,直接调用 `createGhost(entityID, data)`。

#### 7.2.5 步骤 5:Space::createGhost 内部版本

```cpp
// server/cellapp/space.cpp:273-295
void Space::createGhost( const EntityID entityID, BinaryIStream & data )
{
    //ToDo: remove when load balancing is supported on Delegate types
    if (IGameDelegate::instance() != NULL) {
        ERROR_MSG( "Space::createGhost: "
            "Currently not supported by Delegate Physical spaces" );
        return;
    }

    AUTO_SCOPED_PROFILE( "createGhost" );
    SCOPED_PROFILE( TRANSIENT_LOAD_PROFILE );

    // Build up the Entity structure
    EntityTypeID entityTypeID;

    data >> entityTypeID;

    EntityPtr pNewEntity = this->newEntity( entityID, entityTypeID );
    pNewEntity->initGhost( data );

    Entity::population().notifyObservers( *pNewEntity );
}
```

**步骤**:
1. 读取 `entityTypeID`。
2. 调用 `Space::newEntity` 创建 Entity 对象(只是 Python 对象,未初始化)。
3. 调用 `Entity::initGhost(data)` 初始化为 Ghost。
4. 通知 population observer(用于实体发现)。

#### 7.2.6 步骤 6:Entity::initGhost 初始化 Ghost

```cpp
// server/cellapp/entity.cpp:1676-1731
void Entity::initGhost( BinaryIStream & data )
{
    static ProfileVal localProfile( "initGhost" );
    START_PROFILE( localProfile );

    int dataSize = data.remainingLength();

    this->createEntityDelegate();

    this->readGhostDataFromStream( data );

    // TODO: Consider putting this above readGhostDataFromStream.
    // In case any of the ghostControllers or entity extras cause
    // a script method to be called back on some entity.
    // (obv. a different one to this one which is just a ghost).
    // e.g. if a ghost controller added it to some plane of entities
    // that others got script notifications of (like with a proximity
    // controller) and then they couldn't find this entity as it was
    // not yet in the space ... anyway, yeah, worth thinking about,
    // but not for this commit.
    Entity::callbacksPermitted( false );    //{

    pSpace_->addEntity( this );
    this->onPositionChanged();

    // make sure the chunk is NULL (controller could have set it already)
    if (pChunk_ != NULL)
        CellChunk::instance( *pChunk_ ).removeEntity( this );

    // find which chunk we are in
    pChunk_ = this->pChunkSpace()->findChunkFromPointExact(
        globalPosition_ + Vector3(0.f, 0.1f, 0.f) );

    // add us to its list
    if (pChunk_ != NULL)
        CellChunk::instance( *pChunk_ ).addEntity( this );

    Entity::callbacksPermitted( true );        //}

    STOP_PROFILE( localProfile );

    // ... 性能告警 ...

    this->callback( "onGhostCreated" );
}
```

**步骤**:
1. 创建 EntityDelegate(如果配置)。
2. 调用 `readGhostDataFromStream` 从流读取所有 Ghost 数据。
3. 禁用 callback(防止在初始化过程中触发脚本)。
4. 加入 Space 的实体列表。
5. 触发 `onPositionChanged`(更新范围链表)。
6. 找到所在 Chunk,加入 Chunk 的实体列表。
7. 启用 callback。
8. **回调脚本 `onGhostCreated`**(Ghost 创建后脚本可以做一些初始化)。

#### 7.2.7 步骤 7:readGhostDataFromStreamInternal 读取 Ghost 数据

```cpp
// server/cellapp/entity.cpp:1752-1810
void Entity::readGhostDataFromStreamInternal( BinaryIStream & data )
{
    // This was streamed on by Entity::writeGhostDataToStream.
    data >> numTimesRealOffloaded_ >> localPosition_ >> isOnGround_ >>
        lastEventNumber_ >> volatileInfo_;

    eventHistory_.lastTrimmedEventNumber( lastEventNumber_ );

    globalPosition_ = localPosition_;

    // Initialise the structure that stores the time-stamps for when
    // clientServer properties were last changed.
    propertyEventStamps_.init( pEntityType_->description() );

    Mercury::Address realAddr;
    data >> realAddr;
    pRealChannel_ = CellAppChannels::instance().get( realAddr );

    data >> baseAddr_;
    data >> localDirection_;
    globalDirection_ = localDirection_;

    propertyEventStamps_.removeFromStream( data );

    TOKEN_CHECK( data, "GProperties" );

    // Read in the ghost properties
    MF_ASSERT( properties_.size() == pEntityType_->propCountGhost() );
    for (uint32 i = 0; i < properties_.size(); ++i)
    {
        DataDescription & dataDescr = *pEntityType_->propIndex( i );

        DataType & dt = *dataDescr.dataType();
        // read and attach the property
        ScriptDataSink sink;
        MF_VERIFY( dt.createFromStream( data, sink,
            /* isPersistentOnly */ false ) );
        ScriptObject value = sink.finalise();
        if (!(properties_[i] = dt.attach( value, &propertyOwner_, i )))
        {
            CRITICAL_MSG( "Entity::initGhost(%u):"
                "Error streaming off entity property %u\n", id_, i );
        }
    }

    TOKEN_CHECK( data, "GController" );

    // Finally get controllers
    this->readGhostControllersFromStream( data );

    TOKEN_CHECK( data, "GTail" );
    data >> periodsWithoutWitness_ >> aoiUpdateSchemeID_;

    MF_ASSERT( data.remainingLength() == 0 );
    MF_ASSERT( !data.error() );
}
```

**关键点**:
1. **设置 `pRealChannel_`**:用流中的 Real 地址创建到 Real 所在 CellApp 的通道。**这就是 Ghost 与 Real 的"血脉"**。
2. **TOKEN_CHECK**:每个 TOKEN 验证流的完整性,防止版本不匹配或流损坏。
3. **属性 attach**:Ghost 属性被 attach 到 `propertyOwner_`,允许后续的 `setProperty` 触发变更通知。
4. **断言流完整**:`remainingLength() == 0` 和 `!data.error()` 确保流被完整读取。

### 7.3 Ghost 创建流程时序图

```
CellApp #1 (Real)                    CellApp #2 (创建 Ghost)
─────────────────                    ─────────────────────────
EntityGhostMaintainer::check()
  │
  ├─ visit(cellInfo#2)
  │   │
  │   ├─ addHaunt(channel#2)
  │   ├─ createGhost(channel#2.bundle())
  │   │   │
  │   │   ├─ bundle.startMessage(createGhost)
  │   │   ├─ bundle << spaceID
  │   │   └─ writeGhostDataToStream(bundle)
  │   │       ├─ bundle << id << entityTypeID
  │   │       └─ (压缩) bundle << numOffloaded << pos << ...
  │   │
  │   └─ numGhostsCreated_++
  │
  │           ╔══════════════════╗
  │           ║ Mercury 网络      ║
  │           ║ (Bundle 发送)    ║
  │           ╚══════════════════╝
  │                   │
  │                   ▼
  │           Space::createGhost(srcAddr, header, data)
  │                   │
  │                   ├─ if (entity 已存在)
  │                   │     └─ 缓冲到 BufferedGhostMessages
  │                   │
  │                   └─ else
  │                       └─ Space::createGhost(entityID, data)
  │                             │
  │                             ├─ newEntity(entityTypeID)
  │                             ├─ Entity::initGhost(data)
  │                             │   ├─ createEntityDelegate()
  │                             │   ├─ readGhostDataFromStream(data)
  │                             │   │   ├─ 设置 pRealChannel_
  │                             │   │   ├─ attach 所有 Ghost 属性
  │                             │   │   └─ 读取 Ghost Controllers
  │                             │   ├─ pSpace_->addEntity(this)
  │                             │   ├─ onPositionChanged()
  │                             │   ├─ 加入 Chunk
  │                             │   └─ callback("onGhostCreated")
  │                             │
  │                             └─ population.notifyObservers()
```

### 7.4 Ghost 创建的边界情况

#### 7.4.1 Entity 已存在(Real 或 Ghost)

如果 `findEntity(entityID)` 返回非空,说明本 CellApp 已有同 ID 实体。这种情况不能直接创建,而是缓冲:

```cpp
if ((pExistingEntity != NULL) ||
        bufferedMessages.hasMessagesFor( entityID, srcAddr ))
{
    BufferedGhostMessage * pMsg =
        BufferedGhostMessageFactory::createBufferedCreateGhostMessage(
            srcAddr, entityID, id_, data );

    if (bufferedMessages.hasMessagesFor( entityID, srcAddr ))
    {
        bufferedMessages.add( entityID, srcAddr, pMsg );
    }
    else // if pExistingEntity != NULL
    {
        bufferedMessages.delaySubsequence( entityID, srcAddr, pMsg );
    }
}
```

**两种子情况**:
- 已有缓冲消息:追加到现有队列。
- 仅有现存 Entity:创建新队列,把这个 createGhost 作为 subsequence 起点(`delaySubsequence` 会创建一个新队列)。

这种情况通常发生在:
- Real offload 到本 CellApp,但旧 Ghost 还未销毁(过渡期)。
- 消息乱序,先收到了 createGhost,后才收到 delGhost。

#### 7.4.2 CellAppChannel 不可用

如果 Real 端检测到目标 CellAppChannel 不可用(`!isGood()`),不会创建 Ghost:

```cpp
// EntityGhostMaintainer::visit 中 implicitly 检查
CellAppChannel & channel = *CellAppChannels::instance().get(
    remoteAddress );

if (channel.mark() == 1)
{
    channel.mark( 0 );
    return;
}
```

注意:这里 `get` 总会返回一个 CellAppChannel(必要时创建),但 `isGood()` 检查放在 `deleteMarkedHaunts` 中。在 `visit` 中如果 channel 失败,通常会被 `markHaunts` 标记为 1,然后 `deleteMarkedHaunts` 检查 `isGood()` 跳过发送 delGhost。

#### 7.4.3 Delegate Physical Space 不支持

```cpp
// server/cellapp/space.cpp:277-281
if (IGameDelegate::instance() != NULL) {
    ERROR_MSG( "Space::createGhost: "
        "Currently not supported by Delegate Physical spaces" );
    return;
}
```

Delegate 物理空间(用于自定义物理引擎集成的特殊模式)暂不支持 Ghost 创建。

---

## 八、Ghost 的销毁流程

### 8.1 触发条件

Ghost 销毁的触发条件有:

1. **Real 主动销毁**:Real 调用 `destroy()`,会通知所有 Haunt 销毁对应 Ghost。
2. **Real offload**:Real 迁移到另一个 CellApp,但目标 CellApp 不需要这个 Ghost(如目标 Space 不同),发送 delGhost。
3. **EntityGhostMaintainer 检测到不再需要**:Ghost 超出 Real 的 AoI 范围,被 `deleteMarkedHaunts` 删除。
4. **Ghost 收到 delGhost 消息**:`Entity::delGhost()` 被调用。

### 8.2 删除前的保护:最小寿命与配额

参见 6.7 节 `deleteMarkedHaunts` 的源码,删除前需通过 4 个检查:

```cpp
const bool shouldDelGhost =
    // 1. 本 tick 删除配额未满
    offloadChecker_.canDeleteMoreGhosts() &&

    // 2. 不是 offload 目标(那里需要 Ghost 接收 offload)
    (&channel != pOffloadDestination_) &&

    // 3. Real 不是新建的(创建 2 秒内不删除任何 Ghost)
    (gameTime - pReal->creationTime() > NEW_REAL_KEEP_GHOST_PERIOD) &&

    // 4. Ghost 不是新建的(创建 minGhostLifespanInTicks 内不删除)
    (gameTime - haunt.creationTime() > MINIMUM_GHOST_LIFESPAN);
```

这些保护机制防止 Ghost 频繁创建/销毁导致的"抖动":
- 在边界附近,实体来回跨越会让某个 Cell 反复需要/不需要 Ghost。
- 最小寿命(默认 5 秒)给 Ghost 一个稳定期。
- 配额(默认 100/tick)防止单 tick 删除过多 Ghost 导致网络拥塞。

### 8.3 Real 主动销毁所有 Ghost

当 Real 即将销毁时,会调用 `deleteGhosts` 通知所有 Haunt 销毁对应 Ghost:

```cpp
// server/cellapp/entity.cpp:2930 (destroy 中)
pReal_->deleteGhosts();
```

```cpp
// server/cellapp/real_entity.cpp:753-761
void RealEntity::deleteGhosts()
{
    for (Haunts::iterator iter = haunts_.begin(); iter != haunts_.end(); ++iter)
    {
        this->addDelGhostMessage( iter->bundle() );
    }

    haunts_.clear();
}
```

### 8.4 Ghost 端收到 delGhost

```cpp
// server/cellapp/entity.cpp:4888-4896
void Entity::delGhost()
{
    AUTO_SCOPED_PROFILE( "deleteGhost" );
    SCOPED_PROFILE( TRANSIENT_LOAD_PROFILE );

    MF_ASSERT( !this->isReal() );

    this->destroy();
}
```

Ghost 端的 `delGhost` 处理极简——直接调用 `destroy()` 销毁自己。

### 8.5 Entity::destroy() 完整流程

```cpp
// server/cellapp/entity.cpp:2886-2998
void Entity::destroy()
{
    if (inDestroy_)
        return;

    inDestroy_ = true;

    EntityPtr pThis = this;

    MF_ASSERT( !isDestroyed_ );

    const bool wasReal = this->isReal();
    Cell & cell = this->cell();

    if (this->isReal())
    {
        // Real 销毁流程
        this->callback( "onDestroy" );

        if (this->hasBase())
        {
            if (!this->sendCellEntityLostToBase())
            {
                // 通知 BaseApp 失败,降级为 cellEntityLost
                Mercury::Bundle & bundle = pReal_->channel().bundle();
                BaseAppIntInterface::setClientArgs setClientArgs = { id_ };
                bundle << setClientArgs;
                bundle.startMessage( BaseAppIntInterface::cellEntityLost );
                pReal_->channel().send();
            }
        }

        this->setDestroyed();

        pReal_->deleteGhosts();                // 通知所有 Ghost 销毁
        this->cell().entityDestroyed( this );  // 从 Cell 列表移除
        this->convertRealToGhost();            // 转换为 Ghost(便于后续清理)

        if (!this->hasBase())
        {
            shouldReturnID_ = true;
        }

        population_.forgetRealChannel( id_ );
    }
    else
    {
        // Ghost 销毁流程
        this->callback( "onGhostDestroyed" );

        // 记住 Real 通道,以防后续消息到达
        if (pRealChannel_)
        {
            population_.rememberRealChannel( id_, *pRealChannel_ );
        }
    }

    this->setDestroyed();

    pEntityDelegate_ = IEntityDelegatePtr();

    Entity::callbacksPermitted( false ); // {

    bw_safe_delete( pControllers_ );

    pSpace_->removeEntity( this );
    pSpace_ = NULL;

    if (pChunk_ != NULL)
    {
        CellChunk::instance( *pChunk_ ).removeEntity( this );
        pChunk_ = NULL;
    }

    // 清理 EntityExtra
    for (uint i = 0; i < s_entityExtraInfo().size(); i++)
    {
        delete extras_[i];
        extras_[i] = NULL;
    }

    // 清理 pRealChannel_,防止 CellApp 死亡时悬挂指针
    pRealChannel_ = NULL;

    this->clearPythonProperties();

    inDestroy_ = false;

    Entity::callbacksPermitted( true ); // }

    if (wasReal && cell.pReplayData())
    {
        cell.pReplayData()->deleteEntity( id_ );
    }

    // 处理可能存在的 createGhost 缓冲消息
    CellApp::instance().bufferedGhostMessages().
        playNewLifespanFor( this->id() );
}
```

#### 8.5.1 Real 与 Ghost 销毁的差异

| 步骤 | Real 销毁 | Ghost 销毁 |
|------|----------|------------|
| 脚本回调 | `onDestroy` | `onGhostDestroyed` |
| 通知 BaseApp | ✅(`sendCellEntityLostToBase` 或 `cellEntityLost`) | ❌ |
| 通知其他 Ghost | ✅(`deleteGhosts` 发送 delGhost) | ❌ |
| 从 Cell::realEntities_ 移除 | ✅(`cell.entityDestroyed`) | ❌(不在其中) |
| 转换为 Ghost | ✅(`convertRealToGhost` 清理 Real 状态) | ❌(已是 Ghost) |
| 记住 Real 通道 | ❌ | ✅(`rememberRealChannel`) |
| 录制删除 | ✅(若 `cell.pReplayData()`) | ❌ |
| 触发缓冲 createGhost | ✅(`playNewLifespanFor`) | ✅(同) |

#### 8.5.2 Real 销毁后转换为 Ghost 的设计

注意一个微妙的设计:**Real 销毁时会调用 `convertRealToGhost()` 转换为 Ghost 形态**。这看似多余(Real 都要销毁了,为什么还要变 Ghost?),原因有:

1. **统一的清理路径**:`convertRealToGhost` 中的清理 Real 属性、销毁 RealEntity 等操作,可以被销毁路径复用。
2. **缓冲消息处理**:销毁后,如果有缓冲的 createGhost 消息(说明 Real 在销毁过程中又有新的 CellApp 想创建 Ghost——可能是 Real 之前 offload 出去的 Real 又回来了),需要重新创建 Ghost。`playNewLifespanFor` 会处理这种情况。

### 8.6 Ghost 销毁流程时序图

```
CellApp #1 (Real)                    CellApp #2 (Ghost)
─────────────────                    ─────────────────────────
Entity::destroy()
  │
  ├─ callback("onDestroy")
  ├─ sendCellEntityLostToBase()  ───► BaseApp
  ├─ pReal_->deleteGhosts()
  │   │
  │   ├─ for each haunt:
  │   │   └─ addDelGhostMessage(haunt.bundle())
  │   │       ├─ bundle.startMessage(delGhost)
  │   │       └─ bundle << entity_.id()
  │   │
  │   └─ haunts_.clear()
  │
  ├─ cell.entityDestroyed(this)
  ├─ convertRealToGhost()
  │
  │           ╔══════════════════╗
  │           ║ Mercury 网络      ║
  │           ╚══════════════════╝
  │                   │
  │                   ▼
  │           Entity::delGhost()
  │                   │
  │                   ├─ ASSERT(!isReal())
  │                   └─ this->destroy()
  │                       │
  │                       ├─ callback("onGhostDestroyed")
  │                       ├─ rememberRealChannel(用于后续消息)
  │                       ├─ setDestroyed()
  │                       ├─ bw_safe_delete(pControllers_)
  │                       ├─ pSpace_->removeEntity(this)
  │                       ├─ removeEntity from Chunk
  │                       ├─ pRealChannel_ = NULL
  │                       ├─ clearPythonProperties()
  │                       └─ playNewLifespanFor(处理缓冲 createGhost)
  │
  └─ (后续清理,最终 decRef 到 0 时析构)
```

---

## 九、Real/Ghost 转换

### 9.1 转换的场景

Real 与 Ghost 之间的转换发生在以下场景:

| 场景 | 转换方向 | 触发 |
|------|---------|------|
| Real 跨 Cell 边界迁移 | Real → Ghost(本机) + Ghost → Real(目标) | `offload` / `onload` |
| 客户端 teleport 到另一个 CellApp 的附近 | Real → Ghost + Ghost → Real | `RealEntity::teleport` |
| Real 销毁 | Real → Ghost | `Entity::destroy` |
| Real 从备份恢复 | Ghost → Real | `Entity::initReal` (with isRestore) |

### 9.2 convertRealToGhost:Real 变 Ghost

```cpp
// server/cellapp/entity.cpp:2005-2061
void Entity::convertRealToGhost( BinaryOStream * pStream,
        CellAppChannel * pChannel, bool isTeleport )
{
    MF_ASSERT( this->isReal() );
    MF_ASSERT( !pRealChannel_ );

    Entity::callbacksPermitted( false );

    Witness * pWitness = this->pReal()->pWitness();
    if (pWitness != NULL)
    {
        pWitness->flushToClient();
    }

    if (pChannel != NULL)
    {
        // Offload the entity if we have a pChannel to the next real.
        MF_ASSERT( pStream != NULL );

        this->writeRealDataToStream( *pStream, isTeleport );

        pRealChannel_ = pChannel;

        // Once the real is created on the other CellApp, it will send a
        // ghostSetReal back to this app, so we better be ready for it.
        nextRealAddr_ = pRealChannel_->addr();

        // Delete the real part (includes decrementing refs of haunts
        // and notifying haunts of our nextRealAddr_)
        this->offloadReal();
    }
    else
    {
        // Delete the real part (includes decrementing refs of haunts)
        // as we're being destroyed.
        this->destroyReal();
    }
    MF_ASSERT( !this->isReal() );

    // make it a ghost script
    //this->pType()->convertToGhostScript( this );
    // .. by dropping all the properties of the real
    MF_ASSERT( properties_.size() == pEntityType_->propCountGhostPlusReal() );
    for (uint i = pEntityType_->propCountGhost(); i < properties_.size(); ++i)
    {
        if (properties_[i])
        {
            pEntityType_->propIndex(i)->dataType()->detach( properties_[i] );
        }
    }
    properties_.erase( properties_.begin() + pEntityType_->propCountGhost(),
        properties_.end() );

    this->relocated();

    Entity::callbacksPermitted( true );
}
```

#### 9.2.1 算法步骤

1. **断言前置条件**:必须先是 Real,且没有 `pRealChannel_`(否则违反互斥性)。
2. **禁用 callbacks**:防止脚本在转换过程中干扰。
3. **flush Witness**:如果有 Witness(玩家),把待发送数据冲到客户端。
4. **根据是否有 pChannel 分支**:
   - **有 pChannel(offload 场景)**:
     - 序列化 Real 数据到流。
     - 设置 `pRealChannel_ = pChannel`(即将成为 Ghost,通道指向新 Real)。
     - 设置 `nextRealAddr_`(等待 ghostSetReal 确认)。
     - 调用 `offloadReal()` 销毁 RealEntity 部分,通知所有 Haunt 新 Real 地址。
   - **无 pChannel(销毁场景)**:
     - 调用 `destroyReal()` 销毁 RealEntity 部分(通知 BaseApp condemn 通道)。
5. **断言变为 Ghost**:`!isReal()`。
6. **detach Real 属性**:遍历 Real 属性,从 `propertyOwner_` detach。
7. **删除 Real 属性**:`properties_.erase` 移除 Real 属性槽位。
8. **触发 relocated 通知**。
9. **启用 callbacks**。

### 9.3 offloadReal vs destroyReal

#### 9.3.1 offloadReal

```cpp
// server/cellapp/entity.cpp:3046-3058
void Entity::offloadReal()
{
    // This is the one time where we have both a pRealChannel_ and a pReal_
    MF_ASSERT( pReal_ != NULL && pRealChannel_ != NULL );
    pReal_->destroy( &(nextRealAddr_) );
    // RealEntity::destroy calls 'delete this'
    pReal_ = NULL;

    if (pEntityDelegate_)
    {
        pEntityDelegate_->onEntityPositionUpdatable( /* isUpdatable */ false );
    }
}
```

**关键**:调用 `pReal_->destroy(&nextRealAddr_)` 传入 nextRealAddr,这告诉 RealEntity 在销毁前通知所有 Haunt 新的 Real 地址(发送 `ghostSetNextReal`)。

#### 9.3.2 destroyReal

```cpp
// server/cellapp/entity.cpp:3029-3040
void Entity::destroyReal()
{
    MF_ASSERT( this->isReal() );
    pReal_->destroy( NULL );
    // RealEntity::destroy calls 'delete this'
    pReal_ = NULL;

    if (pEntityDelegate_)
    {
        pEntityDelegate_->onEntityPositionUpdatable( /* isUpdatable */ false );
    }
}
```

**关键**:调用 `pReal_->destroy(NULL)` 传入 NULL,表示这是销毁场景,不需要通知 Haunt 新 Real 地址,只是 condemn 通道。

#### 9.3.3 RealEntity::destroy 的两个分支

```cpp
// server/cellapp/real_entity.cpp:246-283
void RealEntity::destroy( const Mercury::Address * pNextRealAddr )
{
    // Offloading
    if (pNextRealAddr)
    {
        // Notify all ghosts that this real is about to be offloaded
        for (Haunts::iterator iter = haunts_.begin();
                iter != haunts_.end(); ++iter)
        {
            Haunt & haunt = *iter;

            if (haunt.addr() != *pNextRealAddr)
            {
                CellAppInterface::ghostSetNextRealArgs & args =
                    CellAppInterface::ghostSetNextRealArgs::start(
                        haunt.bundle(), entity_.id() );

                args.nextRealAddr = *pNextRealAddr;
            }
        }

        // Clear out the channel's resend history so that when Channel::condemn() is
        // called it is destroyed immediately.  The resend history is now the
        // responsibility of the channel that will be created on the dest app.
        pChannel_->reset( Mercury::Address::NONE, false );
        pChannel_->destroy();
    }

    // Destroying
    else
    {
        pChannel_->condemn();
    }

    pChannel_ = NULL;
    delete this;
}
```

**两个分支**:
- **Offloading**(`pNextRealAddr` 非 NULL):
  - 遍历所有 Haunt,发送 `ghostSetNextReal` 消息(告诉 Ghost:新 Real 在 `pNextRealAddr`)。
  - **跳过目标地址**(目标 CellApp 即将成为 Real,不需要这个消息)。
  - reset 通道(让目标 CellApp 接管 resend history)。
  - destroy 通道(立即销毁)。
- **Destroying**(`pNextRealAddr` 为 NULL):
  - condemn 通道(让通道自然死亡,等待未送达消息处理)。

### 9.4 convertGhostToReal:Ghost 变 Real

```cpp
// server/cellapp/entity.cpp:4657-4703
void Entity::convertGhostToReal( BinaryIStream & data,
        const Mercury::Address * pBadHauntAddr )
{
    ++numTimesRealOffloaded_;

    // Make sure the entity doesn't have a zero refcount when between lists.
    // Also if the entity destroys itself in this call. Actually, let's stop
    // script callbacks too so it can't do anything potentially even worse.
    EntityPtr pCopy = this;
    Entity::callbacksPermitted( false );

    // Throw away the channel to the (former) real entity
    MF_ASSERT( pRealChannel_ );
    pRealChannel_ = NULL;

    // do the work of creating the real entity
    this->readRealDataFromStreamForOnload( data, pBadHauntAddr );
    MF_ASSERT( this->isReal() );

    // add it to the cell's collection of reals
    this->cell().addRealEntity( this, /*shouldSendNow:*/true );

    if ((globalPosition_ != INVALID_POSITION) && this->cell().pReplayData())
    {
        this->cell().pReplayData()->addEntityState( *this );
    }

    this->relocated();

    // We want this to happen before other callbacks have a chance to run.
    {
        // We don't want to stop callbacks here but we also do not yet want to
        // replay any queued callbacks yet.
        s_callbackBuffer_.enableHighPriorityBuffering();

        this->callback( "onEnteredCell" );

        s_callbackBuffer_.disableHighPriorityBuffering();
    }

    // let the scripting environment have its way with the entity -
    // it could destroy it, offload (teleport) it, whatever.
    Entity::callbacksPermitted( true );
}
```

#### 9.4.1 算法步骤

1. **递增 numTimesRealOffloaded_**:每次 Real 切换都递增,作为"代际"标识。
2. **持有自引用**:`EntityPtr pCopy = this` 防止脚本中 destroy 自身导致悬挂指针。
3. **禁用 callbacks**。
4. **清空 pRealChannel_**:抛弃到旧 Real 的通道。
5. **读取 Real 数据**:`readRealDataFromStreamForOnload` 创建 RealEntity,从流中读取 Real 属性、控制器等。
6. **断言变为 Real**。
7. **加入 Cell 的 Real 列表**:`addRealEntity` 会通知 BaseApp 当前 CellApp 地址。
8. **录制状态**(若有 ReplayData)。
9. **触发 relocated**。
10. **回调 `onEnteredCell`**(高优先级缓冲,先于其他 callbacks)。
11. **启用 callbacks**。

### 9.5 onload:接收 offload 数据

`onload` 是 Ghost 端收到 Real 数据后,转换为 Real 的入口:

```cpp
// server/cellapp/entity.cpp:4560-4640
void Entity::onload( const Mercury::Address & srcAddr,
        const Mercury::UnpackedMessageHeader & header,
        BinaryIStream & data )
{
    static ProfileVal localProfile( "onloadEntity" );
    SCOPED_PROFILE( TRANSIENT_LOAD_PROFILE );
    START_PROFILE( localProfile );

    // ... DEBUG_FAULT_TOLERANCE 代码 ...

    bool teleportFailure = false;
    data >> teleportFailure;

    int dataSize = data.remainingLength();

    MF_ASSERT( !this->isReal() );

    this->callback( "onEnteringCell" );

    this->convertGhostToReal( data, teleportFailure ? &srcAddr : NULL );

    // ... 性能告警 ...

    if (teleportFailure)
    {
        // Remove the haunt to the failed destination as the ghost did not get
        // created.
        RealEntity::Haunts::iterator iHaunt = pReal_->hauntsBegin();
        while (iHaunt != pReal_->hauntsEnd())
        {
            if (iHaunt->channel().addr() == srcAddr)
            {
                pReal_->delHaunt( iHaunt );
                break;
            }
            ++iHaunt;
        }

        if (this->cell().pReplayData())
        {
            this->cell().pReplayData()->addEntityState( *this );
        }

        this->callback( "onTeleportFailure" );
    }
}
```

**关键点**:
1. **teleportFailure 标志**:流中第一个字段,表示这次 onload 是 teleport 失败回退。
2. **必须是 Ghost**:`MF_ASSERT( !this->isReal() )`。
3. **回调 `onEnteringCell`**:在转换前通知脚本。
4. **转换**:调用 `convertGhostToReal`。
5. **teleport 失败处理**:删除指向失败目的地的 Haunt,回调 `onTeleportFailure`。

### 9.6 Real/Ghost 转换的状态机

```
                     ┌────────────────┐
                     │   Entity 创建   │
                     │  (newEntity)    │
                     └────────┬───────┘
                              │
              ┌───────────────┴───────────────┐
              │                                │
              ▼                                ▼
       initReal()                       initGhost()
              │                                │
              ▼                                ▼
     ┌─────────────────┐              ┌─────────────────┐
     │     Real         │              │     Ghost        │
     │  (pReal_ != NULL) │              │ (pReal_ == NULL)│
     │                  │              │                  │
     │  pRealChannel_   │              │  pRealChannel_   │
     │  == NULL         │              │  != NULL         │
     └────────┬────────┘              └────────┬────────┘
              │                                │
              │ offload()                      │ onload() / convertGhostToReal()
              │ convertRealToGhost()           │
              ▼                                │
     ┌─────────────────┐                       │
     │  转换中(短暂)   │                       │
     │  pReal_ = NULL   │                       │
     │  pRealChannel_   │                       │
     │  != NULL         │                       │
     │  nextRealAddr_   │                       │
     │  != NONE         │                       │
     └────────┬────────┘                       │
              │                                │
              │ ghostSetReal 收到后             │
              │                                │
              ▼                                ▼
     ┌─────────────────────────────────────────────┐
     │                  Ghost                       │
     │            (稳定状态)                        │
     └─────────────────────────────────────────────┘
                              │
                              │ destroy() (Ghost 销毁)
                              ▼
                       ┌─────────────┐
                       │  Destroyed  │
                       └─────────────┘

                  ▲
                  │
        (Real 销毁路径)
        Entity::destroy()
          ├─ if (isReal):
          │   ├─ deleteGhosts() (通知所有 Ghost 销毁)
          │   ├─ cell.entityDestroyed()
          │   ├─ convertRealToGhost() (无 pChannel,即 destroyReal)
          │   └─ → 进入 Ghost 状态后再清理
          └─ (Ghost 销毁路径)
              ├─ callback("onGhostDestroyed")
              └─ rememberRealChannel()
```

---

## 十、Haunt 通道详解

### 10.1 Haunt = Real 与 Ghost 的通信通道

**Haunt** 是 BigWorld 的一个术语,指**Real Entity 与其某个 Ghost 之间的通信通道**。Haunt 在数据结构上是一个 `CellAppChannel *`(指向到目标 CellApp 的通道),配合 `creationTime_` 用于生命周期管理。

```cpp
// server/cellapp/real_entity.hpp:76-98
class Haunt
{
public:
    Haunt( CellAppChannel * pChannel, GameTime creationTime ) :
        pChannel_( pChannel ),
        creationTime_( creationTime )
    {}

    CellAppChannel & channel() { return *pChannel_; }
    Mercury::Bundle & bundle() { return pChannel_->bundle(); }
    const Mercury::Address & addr() const { return pChannel_->addr(); }

    void creationTime( GameTime time )    { creationTime_ = time; }
    GameTime creationTime() const            { return creationTime_; }

private:
    CellAppChannel * pChannel_;
    GameTime creationTime_;
};
```

### 10.2 Haunt 与 CellAppChannel 的关系

**Haunt 是 Real 一方的视角**:**"我在 cellApp X 上有一个 Ghost"**。这个映射在 Real 端维护(`RealEntity::haunts_`)。

**Ghost 一方的对应物是 `Entity::pRealChannel_`**:**"我的 Real 在 cellApp Y 上"**。这是一个简单的反向指针。

```
Real Entity (CellApp #1)                      Ghost Entity (CellApp #2)
─────────────────────                         ──────────────────────────
RealEntity                                    Entity
  └─ haunts_ (vector<Haunt>)                   └─ pRealChannel_ 
       ├─ Haunt -> CellAppChannel #2                  └─ -> CellAppChannel #1
       ├─ Haunt -> CellAppChannel #3             
       └─ Haunt -> CellAppChannel #4             
```

### 10.3 CellAppChannel 简介

`CellAppChannel` 是两个 CellApp 之间的双向通信通道。它封装了 Mercury 的 `UDPChannel`,并提供了 Bundle 缓冲:

```cpp
// server/cellapp/cell_app_channel.hpp (摘要)
class CellAppChannel
{
public:
    CellAppChannel( const Mercury::Address & addr );
    ~CellAppChannel();

    Mercury::UDPChannel & channel();
    Mercury::Bundle & bundle();

    const Mercury::Address & addr() const;
    bool isGood() const;

    void send();

    int mark() const;
    void mark( int value );

    // ...
};
```

**关键特性**:
- **bundle()**:每个 CellAppChannel 有一个 Bundle,可以累积多个消息一次性发送。
- **mark()**:通用标记位,不同使用者复用(如 EntityGhostMaintainer 用它标记 Haunt 是否需要删除)。
- **isGood()**:通道健康状态(故障检测)。

### 10.4 Haunt 通道的建立

Haunt 在以下时机建立:

1. **EntityGhostMaintainer 创建新 Ghost 时**:

```cpp
// server/cellapp/entity_ghost_maintainer.cpp:227-228
pEntity_->pReal()->addHaunt( channel );
pEntity_->createGhost( channel.bundle() );
```

2. **Real offload 时,新 Real 接收原 Haunt 列表时**:

```cpp
// server/cellapp/real_entity.cpp:377 (readOffloadData 中)
this->addHaunt( *pAppChannel );
```

3. **teleport 时,目标 CellApp 加入 Haunt**:

```cpp
// server/cellapp/real_entity.cpp:1292 (teleport 中)
this->addHaunt( *pChannel );
```

### 10.5 Haunt 通道的断开

Haunt 在以下时机断开:

1. **EntityGhostMaintainer 删除多余 Ghost 时**:

```cpp
// server/cellapp/entity_ghost_maintainer.cpp:280-289
if (channel.mark() && shouldDelGhost)
{
    if (channel.isGood())
    {
        pReal->addDelGhostMessage( channel.bundle() );
        offloadChecker_.addDeletedGhost();
    }

    iHaunt = pReal->delHaunt( iHaunt );
}
```

2. **Real 销毁前,deleteGhosts() 清空所有 Haunt**:

```cpp
// server/cellapp/real_entity.cpp:760
haunts_.clear();
```

3. **teleport 时,先清空所有 Haunt**(因为目标 Space 可能不需要这些 Ghost):

```cpp
// server/cellapp/real_entity.cpp:1267-1279
while (!haunts_.empty())
{
    CellAppChannel * pCellAppChannel =
        CellAppChannels::instance().get( haunts_.front().addr(),
        /* shouldCreate = */ false );

    Mercury::Bundle & hauntBundle = pCellAppChannel->bundle();
    this->addDelGhostMessage( hauntBundle );
    this->delHaunt( haunts_.begin() );
}
```

### 10.6 Haunt 通道的可靠性

Haunt 通道基于 Mercury 的 `UDPChannel`,提供**可靠有序**的消息传输:

- **可靠**:消息丢失会重传。
- **有序**:同一通道的消息按发送顺序到达。
- **流控**:有拥塞控制机制。

但是,**跨通道**的消息顺序不保证。例如,Real 同时通过 Haunt A 和 Haunt B 发送消息,Ghost A 和 Ghost B 收到的顺序可能不同。这就是 BufferedGhostMessages 存在的原因(见第十四章)。

### 10.7 Haunt 通道的发送优化

注释中提到:

> A note about these accessors. We don't need to guard their callers with ChannelSenders because having haunts guarantees that the underlying channel is regularly sent.

含义:
- Real 在每个 tick 都会向所有 Haunt 推送 `ghostPositionUpdate`(见 13.2 节)。
- 这意味着只要 Real 有 Haunt,对应 CellAppChannel 就会被定期发送。
- 因此不需要显式调用 `ChannelSender` 来守卫每次写入 Bundle。
- 但在 Haunt 销毁时,如果 Channel 不再被定期使用,Mercury 会立即发送未送数据,防止数据丢失。

---

## 十一、消息路由核心机制

### 11.1 消息路由总览

Ghost 机制的最核心特色是**消息路由的透明性**。脚本调用 `entity.someMethod(...)` 时,无论 entity 是 Real 还是 Ghost,行为都应该一致。

### 11.2 消息的分类

BigWorld 的 Cell 消息按"目的地"分类,定义在 `cellapp_interface.hpp`:

```cpp
// server/cellapp/cellapp_interface.hpp (摘要)
enum EntityReality
{
    REAL_ONLY,        // 仅 Real 处理
    GHOST_ONLY,        // 仅 Ghost 处理
    REAL_OR_GHOST,    // Real 或 Ghost 都可处理
    WITNESS_ONLY        // 仅 Witness(玩家 Real)处理
};
```

每个消息都用 `MF_*_ENTITY_MSG` 宏声明其类别:

```cpp
// server/cellapp/cellapp_interface.hpp:296-326
MF_RAW_VARLEN_ENTITY_MSG( onload, GHOST_ONLY )

MF_BEGIN_ENTITY_MSG( ghostPositionUpdate, GHOST_ONLY )
    Position3D            pos;
    YawPitchRoll        dir;
    bool                isOnGround;
    VolatileNumber        updateNumber;
END_STRUCT_MESSAGE()

MF_VARLEN_ENTITY_MSG( ghostHistoryEvent, GHOST_ONLY )

MF_BEGIN_ENTITY_MSG( ghostSetReal, GHOST_ONLY )
    NumTimesRealOffloadedType numTimesRealOffloaded;
    Mercury::Address    owner;
END_STRUCT_MESSAGE()

MF_BEGIN_ENTITY_MSG( ghostSetNextReal, GHOST_ONLY )
    Mercury::Address    nextRealAddr;
END_STRUCT_MESSAGE()

MF_EMPTY_ENTITY_MSG( delGhost, GHOST_ONLY )

MF_BEGIN_ENTITY_MSG( ghostVolatileInfo, GHOST_ONLY )
    VolatileInfo    volatileInfo;
END_STRUCT_MESSAGE()

MF_VARLEN_ENTITY_MSG( ghostControllerCreate, GHOST_ONLY )
MF_VARLEN_ENTITY_MSG( ghostControllerDelete, GHOST_ONLY )
MF_VARLEN_ENTITY_MSG( ghostControllerUpdate, GHOST_ONLY )

MF_VARLEN_ENTITY_MSG( ghostedDataUpdate, GHOST_ONLY )
```

### 11.3 EntityMessageHandler 的路由逻辑

`EntityMessageHandler` 是所有 Entity 消息的统一入口。其 `handleMessage` 方法实现了完整的路由逻辑:

```cpp
// server/cellapp/message_handlers.cpp:107-261
void EntityMessageHandler::handleMessage( const Mercury::Address & srcAddr,
    Mercury::UnpackedMessageHeader & header,
    BinaryIStream & data,
    EntityID entityID )
{
    CellApp & app = ServerApp::getApp< CellApp >( header );
    Entity * pEntity = app.findEntity( entityID );

    AUTO_SCOPED_ENTITY_PROFILE( pEntity );

    BufferedGhostMessages & bufferedMessages = app.bufferedGhostMessages();

    bool shouldBufferGhostMessage =
        !pEntity ||
        pEntity->shouldBufferMessagesFrom( srcAddr ) ||
        bufferedMessages.isDelayingMessagesFor( entityID, srcAddr );

    bool isForDestroyedGhost = false;

    // Message is for a destroyed ghost if it is out of subsequence order.
    if (reality_ == GHOST_ONLY)
    {
        // Destroyed by restored real.
        if (pEntity && pEntity->isReal())
        {
            isForDestroyedGhost = true;
        }

        // Destroyed by restored real, then recreated when offload to sender.
        else if (pEntity && pEntity->isOffloadingTo( srcAddr ) &&
                !BufferedGhostMessages::isSubsequenceStart( header.identifier ))
        {
            isForDestroyedGhost = true;
        }

        // Destroyed when senders death was handled.
        else if (shouldBufferGhostMessage && 
                !bufferedMessages.hasMessagesFor( entityID, srcAddr ) &&
                !BufferedGhostMessages::isSubsequenceStart( header.identifier ))
        {
            isForDestroyedGhost = true;
        }
    }

    // Drop GHOST_ONLY messages for destroyed ghost.
    if (isForDestroyedGhost)
    {
        WARNING_MSG( "EntityMessageHandler::handleMessage( %s [id: %d] ): "
                "Dropping ghost message for entity %u from %s, "
                "ghost was destroyed while in-flight.\n",
            header.msgName(), int( header.identifier ),
            entityID, srcAddr.c_str() );

        this->sendFailure( srcAddr, header, data, entityID );
    }

    // Buffer GHOST_ONLY messages that are out of sender order.
    else if (reality_ == GHOST_ONLY && shouldBufferGhostMessage)
    {
        BufferedGhostMessage * pMsg =
            BufferedGhostMessageFactory::createBufferedMessage(
                srcAddr, header, data, entityID, this );

        bufferedMessages.add( entityID, srcAddr, pMsg );

        WARNING_MSG( "EntityMessageHandler::handleMessage( %s [id: %d] ): "
                   "Buffered ghost message for entity %u from %s\n",
                   header.msgName(), int( header.identifier ),
                   entityID, srcAddr.c_str() );
    }

    // REAL_ONLY messages should be forwarded if we don't have the real.
    else if (reality_ >= REAL_ONLY && (!pEntity || !pEntity->isReal()))
    {
        // We only try to look up the cached channel for the entity if it
        // doesn't exist, since calling findRealChannel() for ghosts will
        // cause an assertion.
        CellAppChannel * pChannel = pEntity ?
            pEntity->pRealChannel() :
            Entity::population().findRealChannel( entityID );

        if (pChannel)
        {
            Entity::forwardMessageToReal( *pChannel, entityID,
                header.identifier, data, srcAddr, header.replyID );
        }
        else
        {
            ERROR_MSG( "EntityMessageHandler::handleMessage( %s [id: %d] ): "
                "Dropped real message for unknown entity %u\n",
                header.msgName(), int( header.identifier ), entityID );

            this->sendFailure( srcAddr, header, data, entityID );
        }
    }

    // Drop WITNESS_ONLY message for entities without a witness.
    else if (reality_ == WITNESS_ONLY && !pEntity->pReal()->pWitness())
    {
        DEBUG_MSG( "EntityMessageHandler::handleMessage( %s [id: %d] ): "
            "Received witness message for entity %u with no witness "
            "from %s\n",
            header.msgName(), int( header.identifier ),
            entityID, srcAddr.c_str() );

        this->sendFailure( srcAddr, header, data, entityID );
    }

    // Message is good, call through to the handler.
    else if (shouldBufferIfTickPending_ && app.nextTickPending())
    {
        // ... tick 边界缓冲 ...
    }

    else
    {
        // 正常处理:调用具体的 handler
        this->callHandler( srcAddr, header, data, pEntity, entityID );
    }
}
```

### 11.4 路由决策树

```
                        收到消息 (entityID, srcAddr, data)
                                  │
                                  ▼
                    ┌──────────────────────────┐
                    │ 查找 Entity               │
                    │ pEntity = findEntity(id)  │
                    └──────────┬───────────────┘
                               │
                  ┌────────────┴────────────┐
                  │                         │
                  ▼                         ▼
        reality_ == GHOST_ONLY        reality_ >= REAL_ONLY
                  │                         │
                  ▼                         ▼
        ┌─────────────────┐        ┌────────────────────┐
        │ 判断是否已销毁   │        │ 判断本机是否有 Real │
        │ 的 Ghost         │        │                    │
        └────────┬────────┘        └──────────┬─────────┘
                 │                            │
       ┌─────────┴─────────┐            ┌────┴────┐
       │                   │            │         │
       ▼                   ▼            ▼         ▼
  isForDestroyedGhost  shouldBuffer   有 Real   无 Real
       │                   │            │         │
       ▼                   ▼            ▼         ▼
  sendFailure       bufferedMessages  正常处理  forwardMessageToReal
  (丢弃)            .add              (callHandler)  (转发)
```

### 11.5 GHOST_ONLY 消息的处理

GHOST_ONLY 消息(如 `ghostPositionUpdate`、`ghostSetReal` 等)只能由 Ghost 处理。如果本机 Entity 是 Real,说明消息发错了——可能是:

1. **Ghost 已被销毁,但消息在路上**(Real 已恢复)。
2. **Ghost 正在 offload,但发送方还不知道**(消息已发出)。

这些情况都需要丢弃或缓冲消息。

#### 11.5.1 已销毁 Ghost 的检测

```cpp
if (reality_ == GHOST_ONLY)
{
    // Destroyed by restored real.
    if (pEntity && pEntity->isReal())
    {
        isForDestroyedGhost = true;
    }

    // Destroyed by restored real, then recreated when offload to sender.
    else if (pEntity && pEntity->isOffloadingTo( srcAddr ) &&
            !BufferedGhostMessages::isSubsequenceStart( header.identifier ))
    {
        isForDestroyedGhost = true;
    }

    // Destroyed when senders death was handled.
    else if (shouldBufferGhostMessage && 
            !bufferedMessages.hasMessagesFor( entityID, srcAddr ) &&
            !BufferedGhostMessages::isSubsequenceStart( header.identifier ))
    {
        isForDestroyedGhost = true;
    }
}
```

**三种"已销毁 Ghost"的情况**:
1. **被恢复的 Real 替代**:本机 Entity 现在是 Real(说明 Ghost 已被销毁,Real 在本机恢复)。
2. **被销毁后又重建,但发送方还在用旧地址**:本机 Entity 正在 offload 到发送方,且不是 subsequence 起点。
3. **发送方死亡已处理**:本应缓冲,但没有现有缓冲,且不是 subsequence 起点。

**subsequence 起点的特殊处理**:`ghostSetReal` 是 subsequence 起点(`isSubsequenceStart` 返回 true),即使 Ghost 已销毁,也要缓冲,因为它可能是新 Ghost 生命周期的开始。

### 11.6 REAL_ONLY 消息的转发

REAL_ONLY 消息(如 `avatarUpdateImplicit`、`enableWitness` 等)只能由 Real 处理。如果本机没有 Real,需要转发到 Real 所在 CellApp:

```cpp
else if (reality_ >= REAL_ONLY && (!pEntity || !pEntity->isReal()))
{
    CellAppChannel * pChannel = pEntity ?
        pEntity->pRealChannel() :
        Entity::population().findRealChannel( entityID );

    if (pChannel)
    {
        Entity::forwardMessageToReal( *pChannel, entityID,
            header.identifier, data, srcAddr, header.replyID );
    }
    else
    {
        ERROR_MSG( "..." );
        this->sendFailure( srcAddr, header, data, entityID );
    }
}
```

**通道查找**:
- 如果 Entity 存在(是 Ghost),用 `pEntity->pRealChannel()`。
- 如果 Entity 不存在(已销毁),用 `Entity::population().findRealChannel(entityID)`(从缓存中找)。

### 11.7 forwardMessageToReal:转发实现

```cpp
// server/cellapp/entity.cpp:2268-2294
void Entity::forwardMessageToReal(
        CellAppChannel & realChannel,
        EntityID entityID,
        uint8 messageID, BinaryIStream & data,
        const Mercury::Address & srcAddr, Mercury::ReplyID replyID )
{
    AUTO_SCOPED_PROFILE( "forwardToReal" );

    Mercury::ChannelSender sender( realChannel.channel() );
    Mercury::Bundle & bundle = sender.bundle();

    const Mercury::InterfaceElement & ie =
        CellAppInterface::gMinder.interfaceElement( messageID );

    if (replyID == Mercury::REPLY_ID_NONE)
    {
        bundle.startMessage( ie );
    }
    else
    {
        bundle.startRequest( ie, new ReplyForwarder( srcAddr, replyID ) );
    }

    bundle << entityID;

    bundle.transfer( data, data.remainingLength() );
}
```

**关键点**:
1. **使用 ChannelSender**:确保通道正确发送。
2. **ReplyForwarder**:如果是 request 消息(有 replyID),需要把回复转发回原始发送方。`ReplyForwarder` 是一个回调对象,收到 Real 的回复后转发到 `srcAddr`。
3. **保留原消息格式**:`bundle << entityID` 后,把原始数据 `transfer` 到新 Bundle 中。

### 11.8 ReplyForwarder:回复转发

```cpp
// server/cellapp/entity.cpp:2224-2253
class ReplyForwarder : public Mercury::ShutdownSafeReplyMessageHandler
{
public:
    ReplyForwarder( const Mercury::Address& destAddr,
            Mercury::ReplyID replyID ) :
        destAddr_( destAddr ), replyID_( replyID ) {}

private:
    virtual void handleMessage( const Mercury::Address& source,
            Mercury::UnpackedMessageHeader& header, BinaryIStream& data,
            void * arg )
    {
        Mercury::ChannelSender sender( CellApp::getChannel( destAddr_ ) );
        sender.bundle().startReply( replyID_ );
        sender.bundle().transfer( data, data.remainingLength() );
        delete this;
    }

    virtual void handleException( const Mercury::NubException& exception,
            void * arg )
    {
        ERROR_MSG( "ReplyForwarder::handleException: destAddr_ = %s\n",
               destAddr_.c_str() );
        delete this;
    }

    Mercury::Address destAddr_;
    Mercury::ReplyID replyID_;
};
```

**设计**:`ReplyForwarder` 是一次性的——处理完回复(或异常)后 `delete this`。这避免了维护长期回调表的开销。

### 11.9 shouldBufferMessagesFrom:Ghost 端的乱序检测

```cpp
// server/cellapp/entity.cpp:7730-7751
bool Entity::shouldBufferMessagesFrom( const Mercury::Address & addr ) const
{
    MF_ASSERT( addr != Mercury::Address::NONE );

    // Reals and zombie ghosts don't buffer
    if (pRealChannel_ == NULL)
    {
        return false;
    }

    // If set, buffer message not from our next real.
    else if (nextRealAddr_ != Mercury::Address::NONE)
    {
        return nextRealAddr_ != addr;
    }

    // Otherwise, buffer messages not from our current real.
    else
    {
        return this->realAddr() != addr;
    }
}
```

**逻辑**:
- Real Entity 不缓冲(它直接处理)。
- "Zombie Ghost"(`pRealChannel_ == NULL` 但 `pReal_` 也是 NULL,过渡态)不缓冲。
- **如果 `nextRealAddr_` 已设置**(Real 已发 ghostSetNextReal,即将切换):
  - 来自 `nextRealAddr_` 的消息:**不缓冲**(新 Real 的消息可处理)。
  - 来自其他地址(旧 Real)的消息:**缓冲**(可能是乱序的旧消息)。
- **否则(正常 Ghost 状态)**:
  - 来自 `realAddr()`(当前 Real)的消息:**不缓冲**。
  - 来自其他地址的消息:**缓冲**(可能是乱序的)。

### 11.10 路由的延迟与顺序保证

| 维度 | 保证 | 说明 |
|------|------|------|
| 同一通道内消息顺序 | 严格有序 | Mercury UDPChannel 保证 |
| 跨通道消息顺序 | 不保证 | 不同 CellApp 的消息可能乱序 |
| Real → Ghost 推送延迟 | 通常 1 tick | 每 tick 推送 ghostPositionUpdate |
| Ghost → Real 转发延迟 | 通常 1 tick | forwardMessageToReal 立即发送 |
| Real 切换期间消息 | 缓冲保证不丢 | BufferedGhostMessages 处理 |
| Real 死亡时消息 | 可能丢失 | 网络分区时的不可避免损失 |

---

## 十二、跨 Cell 边界流程

### 12.1 场景描述

考虑一个完整的跨 Cell 边界场景:

- 玩家 P 在 Cell A(由 CellApp #1 承载),是 Real。
- P 向 Cell B(由 CellApp #2 承载)方向移动。
- 当 P 越过 Cell A / Cell B 边界时,需要把 Real 从 CellApp #1 迁移到 CellApp #2。

### 12.2 迁移前的状态

```
CellApp #1                                    CellApp #2
─────────                                     ─────────
Cell A                                        Cell B
  │                                             │
  ├─ Real P (位置接近边界)                       ├─ Ghost P (P 在 #1,在 #2 也有 Ghost)
  │                                             │
  └─ Real P 的 haunts_:                         └─ Ghost P 的 pRealChannel_
       └─ Haunt -> CellAppChannel #2 (Ghost P)        └─ -> CellAppChannel #1 (Real P)
```

注意:**CellApp #2 上已有 Ghost P**(因为 P 接近边界时,EntityGhostMaintainer 已经创建了 Ghost)。这是 offload 的前置条件。

### 12.3 迁移触发

迁移由 `EntityGhostMaintainer::checkEntityForOffload` 检测触发:

```cpp
// server/cellapp/entity_ghost_maintainer.cpp:81-113
void EntityGhostMaintainer::checkEntityForOffload()
{
    const Vector3 & position = pEntity_->position();
    const CellInfo * pHomeCell = pEntity_->space().pCellAt(
        position.x, position.z );

    if ((pHomeCell == NULL) || (pHomeCell == &(this->cell().cellInfo())))
    {
        return;  // 还在 home cell
    }

    if (pHomeCell->isDeletePending()) return;
    
    CellAppChannel * pOffloadDestination = ...;
    if (!pOffloadDestination || !pOffloadDestination->isGood()) return;

    pOffloadDestination_ = pOffloadDestination;
    offloadChecker_.addToOffloads( pEntity_, pOffloadDestination_ );
}
```

**判定**:P 的当前位置已经不在 Cell A 的范围内,而在 Cell B 的范围内 → 应该 offload 到 CellApp #2。

### 12.4 offload 流程

#### 12.4.1 OffloadChecker::sendOffload

```cpp
// server/cellapp/offload_checker.cpp:110-117
void OffloadChecker::sendOffload( OffloadList::const_iterator iOffload )
{
    EntityPtr pEntity = iOffload->first;
    CellAppChannel * pOffloadDestination = iOffload->second;

    cell_.offloadEntity( pEntity.get(), pOffloadDestination, 
            /* isTeleport: */ false );
}
```

#### 12.4.2 Cell::offloadEntity

```cpp
// server/cellapp/cell.cpp:183-217
void Cell::offloadEntity( Entity * pEntity, CellAppChannel * pChannel,
       bool isTeleport )
{
    AUTO_SCOPED_PROFILE( "offloadEntity" );
    SCOPED_PROFILE( TRANSIENT_LOAD_PROFILE );

    MF_ASSERT( pEntity->pReal() != NULL );

    EntityPtr pCopy = pEntity;

    if (!isTeleport)
    {
        pEntity->callback( "onLeavingCell" );
    }

    if (pEntity->isReal())
    {
        if (pReplayData_ && isTeleport)
        {
            pReplayData_->deleteEntity( pEntity->id() );
        }

        realEntities_.remove( pEntity );
        pEntity->offload( pChannel, isTeleport );
        pEntity->callback( "onLeftCell" );
    }
}
```

**步骤**:
1. 断言是 Real。
2. 持有引用防止销毁。
3. 回调 `onLeavingCell`(非 teleport)。
4. 从 Cell::realEntities_ 移除。
5. 调用 `Entity::offload` 执行转换。
6. 回调 `onLeftCell`(此时已是 Ghost)。

#### 12.4.3 Entity::offload

```cpp
// server/cellapp/entity.cpp:1968-1991
void Entity::offload( CellAppChannel * pChannel, bool isTeleport )
{
#ifdef DEBUG_FAULT_TOLERANCE
    if (g_crashOnOffload)
    {
        MF_ASSERT( !"Entity::offload: Crash on offload" );
    }
#endif

    MF_ASSERT( this->isReal() );

    Mercury::Bundle & bundle = pChannel->bundle();

    // if we are teleporting then we already have a message on the bundle
    if (!isTeleport)
    {
        bundle.startMessage( CellAppInterface::onload );
    }

    this->convertRealToGhost( &bundle, pChannel, isTeleport );
}
```

**步骤**:
1. 断言是 Real。
2. 在目标通道的 Bundle 上开始 `onload` 消息(非 teleport)。
3. 调用 `convertRealToGhost` 进行转换(见 9.2 节)。

### 12.5 迁移过程的状态变化

```
时间轴 ─────────────────────────────────────────────────────────►

CellApp #1 (P 的原 Real)                CellApp #2 (P 的新 Real)
─────────────────────────                ─────────────────────────

T0: P 是 Real
    haunts_ = [Haunt#2 (Ghost P)]

T1: EntityGhostMaintainer::check()
    │
    ├─ checkEntityForOffload() → 应该 offload 到 #2
    │   (P 的位置已不在 Cell A)
    │
    └─ (EntityGhostMaintainer 不会创建新 Ghost
       因为 pOffloadDestination_ != NULL, visit() 跳过其他 Cell)

T2: OffloadChecker::sendOffloads()
    │
    └─ cell_.offloadEntity(P, channel#2)
        │
        ├─ realEntities_.remove(P)
        ├─ P.callback("onLeavingCell")
        └─ P.offload(channel#2)
            │
            └─ convertRealToGhost(bundle, channel#2)
                │
                ├─ writeRealDataToStream(bundle)  ────► bundle#2
                ├─ pRealChannel_ = channel#2
                ├─ nextRealAddr_ = #2.addr
                ├─ offloadReal()
                │   └─ pReal_->destroy(&nextRealAddr_)
                │       ├─ for each haunt (Haunt#2):
                │       │   └─ 跳过(Haunt#2 == 目标)
                │       └─ pChannel_->destroy()
                ├─ properties_.erase(Real props)
                └─ P.callback("onLeftCell")
                                          
                                           ╔══════════════════╗
                                           ║ Mercury 网络传输   ║
                                           ╚══════════════════╝
                                                            │
                                                            ▼

                                       T3: Entity::onload(srcAddr=#1, data)
                                           │
                                           ├─ data >> teleportFailure
                                           ├─ P.callback("onEnteringCell")
                                           └─ convertGhostToReal(data)
                                               │
                                               ├─ numTimesRealOffloaded_++
                                               ├─ pRealChannel_ = NULL
                                               ├─ readRealDataFromStreamForOnload
                                               │   ├─ 创建 RealEntity
                                               │   ├─ RealEntity::init
                                               │   │   └─ readOffloadData
                                               │   │       ├─ numHaunts = 1
                                               │   │       │  (来自流的 Haunt 地址)
                                               │   │       ├─ addr=#1 → areWeHaunted=true
                                               │   │       │  (本机之前有 Ghost)
                                               │   │       ├─ addHaunt(channel#1)
                                               │   │       └─ 向 Haunt#1 发送 ghostSetReal
                                               │   └─ cell.addRealEntity(P)

T4: CellApp #1 收到 ghostSetReal         T5: P.callback("onEnteredCell")
    │
    └─ Entity::ghostSetReal(args)
        │
        ├─ 检查 numTimesRealOffloaded
        │   (期望 = current+1,否则缓冲)
        ├─ numTimesRealOffloaded_ = args.numTimesRealOffloaded
        ├─ pRealChannel_ = get(args.owner)
        ├─ nextRealAddr_ = NONE
        └─ P.relocated()

T6: P 是 Ghost,在 CellApp #1 上
    pRealChannel_ -> CellApp #2
```

### 12.6 ghostSetReal:Ghost 接收新 Real 通知

```cpp
// server/cellapp/entity.cpp:4831-4860
void Entity::ghostSetReal( const CellAppInterface::ghostSetRealArgs & args )
{
    AUTO_SCOPED_PROFILE( "ghostSetReal" );
    NumTimesRealOffloadedType expected = numTimesRealOffloaded_ + 1;

    if (args.numTimesRealOffloaded != expected)
    {
        WARNING_MSG( "Entity::ghostSetReal( %u ): "
                    "Invalid subsequence id. Expected %d. Got %d\n",
                id_, expected, args.numTimesRealOffloaded );

        BufferedGhostMessages & bufferedMessages =
            CellApp::instance().bufferedGhostMessages();
        BufferedGhostMessage * pMsg =
            BufferedGhostMessageFactory::createGhostSetRealMessage( id_, args );

        bufferedMessages.delaySubsequence( id_, args.owner, pMsg );
        return;
    }

    numTimesRealOffloaded_ = args.numTimesRealOffloaded;

    MF_ASSERT( !this->isReal() );
    MF_ASSERT( nextRealAddr_ == args.owner );

    pRealChannel_ = CellAppChannels::instance().get( args.owner );
    nextRealAddr_ = Mercury::Address::NONE;

    this->relocated();
}
```

**关键点**:
1. **代际检查**:`numTimesRealOffloaded_` 必须连续递增。如果不匹配,说明消息乱序,缓冲到 `BufferedGhostMessages`。
2. **断言 nextRealAddr_ 一致**:`ghostSetReal` 的 owner 必须等于之前 `ghostSetNextReal` 设置的 `nextRealAddr_`。
3. **更新 pRealChannel_**:正式切换到新 Real。
4. **清空 nextRealAddr_**:转换完成。
5. **触发 relocated**。

### 12.7 ghostSetNextReal:Real 即将切换的预通知

```cpp
// server/cellapp/entity.cpp:4868-4881
void Entity::ghostSetNextReal(
    const CellAppInterface::ghostSetNextRealArgs & args )
{
    MF_ASSERT( nextRealAddr_ == Mercury::Address::NONE );
    MF_ASSERT( args.nextRealAddr != Mercury::Address::NONE );

    // This is the last message from our current real, so now we will only
    // accept GHOST_ONLY messages from nextRealAddr_.
    nextRealAddr_ = args.nextRealAddr;

    // Play any buffered messages for this ghost.
    CellApp::instance().bufferedGhostMessages().playSubsequenceFor( id_,
           nextRealAddr_ );
}
```

**关键点**:
1. **必须是过渡态**:`nextRealAddr_` 之前必须是 NONE。
2. **设置 nextRealAddr_**:从此只接受新 Real 的消息。
3. **播放缓冲消息**:之前缓冲的、来自新 Real 的消息现在可以处理了。

### 12.8 客户端透明性

整个迁移过程对客户端是**完全透明**的:

1. 客户端只与 BaseApp 通信,不直接与 CellApp 交互。
2. BaseApp 持有 Real 的 CellApp 地址(`currentCell`)。
3. 当 Real 迁移时,新 CellApp 上的 Real 会通过 `addRealEntity → informBaseOfAddress` 通知 BaseApp 更新地址。
4. 客户端发送的 avatarUpdate 等消息由 BaseApp 转发到"当前 Real"。

```cpp
// server/cellapp/cell.cpp:227-240
void Cell::addRealEntity( Entity * pEntity, bool shouldSendNow )
{
    if (!pEntity->isReal())
    {
        ERROR_MSG( "Cell::addRealEntity called on ghost entity id %u!\n",
            pEntity->id() );
        return;
    }

    pEntity->informBaseOfAddress( CellApp::instance().interface().address(),
        this->spaceID(), shouldSendNow );

    realEntities_.add( pEntity );
}
```

---

## 十三、Ghost 数据同步详解

### 13.1 同步的数据类型

Real 向 Ghost 同步的数据类型:

| 数据类型 | 同步方式 | 频率 |
|---------|---------|------|
| 位置和方向 | `ghostPositionUpdate` | 每 tick(Real 移动时) |
| 易变信息(VolatileInfo) | `ghostVolatileInfo` | 变更时 |
| 事件历史 | `ghostHistoryEvent` | 添加事件时 |
| Ghost 属性 | `ghostedDataUpdate` | 属性变更时 |
| Controller 创建/删除/更新 | `ghostControllerCreate` 等 | Controller 变化时 |
| Real 切换 | `ghostSetReal` / `ghostSetNextReal` | offload 时 |
| AoI 方案 | `aoiUpdateSchemeChange` | 变更时 |
| 销毁 | `delGhost` | Ghost 不再需要时 |

### 13.2 位置同步:ghostPositionUpdate

Real 每次位置变化都会触发 `updateInternalsForNewPositionOfReal`,该方法向所有 Haunt 推送位置更新:

```cpp
// server/cellapp/entity.cpp:3902-3945
void Entity::updateInternalsForNewPositionOfReal( const Vector3 & oldPosition,
        bool isVehicleMovement )
{
    MF_ASSERT( this->isReal() );

    ++volatileUpdateNumber_;

    CellAppInterface::ghostPositionUpdateArgs ghostArgs;

    ghostArgs.pos = Position3D( localPosition_ );
    ghostArgs.isOnGround = isOnGround_;

    // TODO: We could store the compressed pitch and yaw.
    ghostArgs.dir.set(
        localDirection_.yaw, localDirection_.pitch, localDirection_.roll );
    ghostArgs.updateNumber = volatileUpdateNumber_;

    RealEntity::Haunts::iterator iter = pReal_->hauntsBegin();

    while (iter != pReal_->hauntsEnd())
    {
        Mercury::Bundle & bundle = iter->bundle();

        CellAppInterface::ghostPositionUpdateArgs & rGhostPositionUpdate =
            CellAppInterface::ghostPositionUpdateArgs::start( bundle, id_ );

        rGhostPositionUpdate = ghostArgs;

        ++iter;
    }

    Entity::callbacksPermitted( false ); // onNoise may be called.
    // Tell the real about it for velocity calcns, etc.
    pReal_->newPosition( globalPosition_ );

    if (this->cell().pReplayData())
    {
        this->cell().pReplayData()->queueEntityVolatile( *this );
    }

    // Update internals for new position
    this->updateInternalsForNewPosition( oldPosition, isVehicleMovement );
    Entity::callbacksPermitted( true );
}
```

**消息格式**(定义见 `cellapp_interface.hpp:298-303`):

```cpp
MF_BEGIN_ENTITY_MSG( ghostPositionUpdate, GHOST_ONLY )
    Position3D            pos;
    YawPitchRoll        dir;
    bool                isOnGround;
    VolatileNumber        updateNumber;
END_STRUCT_MESSAGE()
```

**Ghost 端处理**:

```cpp
// server/cellapp/entity.cpp:4792-4808
void Entity::ghostPositionUpdate(
        const CellAppInterface::ghostPositionUpdateArgs & args )
{
    AUTO_SCOPED_PROFILE( "ghostPositionUpdate" );

    volatileUpdateNumber_++;

    MF_ASSERT( !this->isReal() );

    localPosition_.set( args.pos.x, args.pos.y, args.pos.z );
    isOnGround_ = args.isOnGround;
    args.dir.get(
        localDirection_.yaw, localDirection_.pitch, localDirection_.roll );
    volatileUpdateNumber_ = args.updateNumber;

    this->updateGlobalPosition();
}
```

**关键点**:
- Real 端 `volatileUpdateNumber_` 自增后发送。
- Ghost 端先用本地 `volatileUpdateNumber_++`(可能是为了触发其他更新),然后用消息中的值覆盖。
- `updateGlobalPosition` 更新全局位置和范围链表。

### 13.3 事件历史同步:ghostHistoryEvent

Real Entity 上的事件历史(EventHistory)记录了最近发生的若干事件(如 `onTick`、属性变化、`onTakeDamage` 等)。当 Ghost 被创建或收到 Real 推送的 `ghostHistoryEvent` 消息时,会重放到自己的事件历史中,以便在 AoI 事件触发时保持与 Real 一致的上下文。

```cpp
// server/cellapp/real_entity.cpp:703-735(节选)
HistoryEvent * RealEntity::addHistoryEvent( uint8 type, GameTime time,
        MemoryIStream & stream )
{
    // 如果超过最大长度,丢弃最老的事件
    while (eventHistory_.size() >= MAX_EVENT_HISTORY_SIZE)
    {
        eventHistory_.pop_front();
    }

    HistoryEvent * pEvent = new HistoryEvent( type, time, stream );
    eventHistory_.push_back( pEvent );

    // 同步给所有 Ghost
    for (Haunts::iterator it = haunts_.begin(); it != haunts_.end(); ++it)
    {
        CellAppChannel & channel = *it->pChannel();
        channel.bundle().startMessage( CellAppInterface::ghostHistoryEvent );
        channel.bundle() << this->entity().id() << type << time;
        channel.bundle().transfer( stream, stream.remainingLength() );
    }
    return pEvent;
}
```

**关键点**:

1. `eventHistory_` 是一个 `std::deque<HistoryEvent*>`,大小受限(由 `MAX_EVENT_HISTORY_SIZE` 控制),溢出时弹出最老的事件。
2. 同步循环中遍历所有 Haunt,将事件编码后通过 `ghostHistoryEvent` 消息发送给每个 Ghost。
3. Ghost 端收到后调用 `Entity::ghostHistoryEvent` 重放事件到自己的 `eventHistory_` 中。

```cpp
// server/cellapp/entity.cpp:ghostHistoryEvent 处理函数(节选)
void Entity::ghostHistoryEvent( const Mercury::UnpackedMessageHeader & header,
        BinaryIStream & data )
{
    uint8 type;
    GameTime time;
    data >> type >> time;

    // 检查时间戳,丢弃过期事件
    if (this->lastEventNumber_ >= header.extra)
    {
        return;
    }

    this->lastEventNumber_ = header.extra;

    // 加入本地事件历史
    while (eventHistory_.size() >= MAX_EVENT_HISTORY_SIZE)
    {
        eventHistory_.pop_front();
    }

    eventHistory_.push_back( new HistoryEvent( type, time, data ) );
}
```

**设计意图**:Ghost 不参与游戏逻辑,但需要为 `onEnterAoI` 等事件提供历史上下文(例如新进入 AoI 的玩家可能查询最近 N 个 tick 内的事件)。事件历史同步让 Ghost 也能回答这类查询,避免每次都跨进程向 Real 询问。

### 13.4 Ghost 属性同步:ghostedDataUpdate

`GHOSTED_DATA` 属性是 Real 和 Ghost 都持有的属性类别,通常用于需要在 Ghost 上即可读取的轻量状态(如 `hitpoints`、`teamID`、`state` 等)。Real 修改这些属性后,会通过 `ghostedDataUpdate` 消息批量推送到所有 Ghost。

```cpp
// server/cellapp/entity.cpp:writeGhostsToStream(概念节选)
// 将属性变化打包发送给所有 Ghost
void Entity::writeGhostsToStream( PropertyChange & change )
{
    if (!this->isReal())
    {
        return;
    }

    RealEntity::Haunts & haunts = pReal_->haunts();
    for (RealEntity::Haunts::iterator it = haunts.begin();
            it != haunts.end(); ++it)
    {
        CellAppChannel & channel = *it->pChannel();
        channel.bundle().startMessage(
            CellAppInterface::ghostedDataUpdate );
        channel.bundle() << this->id();
        change.write( channel.bundle() );
    }
}
```

**Ghost 端处理**:

```cpp
// server/cellapp/entity.cpp:ghostedDataUpdate 处理函数(节选)
void Entity::ghostedDataUpdate( BinaryIStream & data )
{
    PropertyChange change;
    change.read( data );

    // 应用到本地属性
    this->applyPropertyChange( change, GHOSTED_DATA );
}
```

**关键点**:

1. **属性划分**:BigWorld 在 `.def` 文件中声明每个属性属于 `CELL_DATA`(仅 Real)、`REAL_DATA`(仅 Real,持久化)还是 `GHOSTED_DATA`(Real+Ghost)。
2. **变更追踪**:Real 端通过 `PropertyChange` 对象记录变更的字段索引和新值,只发送增量,节省带宽。
3. **批量优化**:多个属性变更通常合并到一个 `ghostedDataUpdate` 消息中,减少消息数量。
4. **乱序处理**:由于属性更新基于字段索引,无版本号,因此依赖 Mercury 通道的有序投递保证。

### 13.5 Controller 同步

Real 上的 Controller(如 `MoveController`、`TrackController`)也会同步到 Ghost,以便 Ghost 端的客户端预测和动画播放。Controller 同步涉及三个消息:

- `ghostControllerCreate`:创建 Ghost 端 Controller
- `ghostControllerUpdate`:更新 Ghost 端 Controller 状态
- `ghostControllerDelete`:删除 Ghost 端 Controller

```cpp
// server/cellapp/entity.cpp:writeGhostControllerMessage(概念节选)
void Entity::writeGhostControllerMessage( int controllerID,
        ServerAppInterface::ControllerMessageID msgID,
        BinaryOStream & data )
{
    if (!this->isReal())
    {
        return;
    }

    RealEntity::Haunts & haunts = pReal_->haunts();
    for (RealEntity::Haunts::iterator it = haunts.begin();
            it != haunts.end(); ++it)
    {
        CellAppChannel & channel = *it->pChannel();
        channel.bundle().startMessage( msgID );
        channel.bundle() << this->id() << controllerID;
        channel.bundle().transfer( data, data.remainingLength() );
    }
}
```

**Ghost 端 Controller**:

Ghost 上的 Controller 通常是 Real Controller 的"只读"副本——它会接收相同的状态更新,执行动画/位置插值,但**不会**触发服务器端的游戏逻辑回调(这些回调在 Real 上触发)。Ghost Controller 的核心用途是让 Ghost 周围的玩家看到一致的动画表现。

### 13.6 VolatileInfo 与位置同步

`VolatileInfo` 描述了哪些位置/方向分量应该同步给 Ghost:

```cpp
// server/cellapp/volatile_info.hpp(概念节选)
class VolatileInfo
{
public:
    // 哪些分量是 volatile 的
    bool isVolatile( int position3D, int direction3D ) const;
    bool position3D_isVolatile[3];
    bool direction3D_isVolatile[3];
};
```

Real 在每次 tick 后,如果位置/方向变化且对应分量是 volatile 的,会发送 `ghostPositionUpdate` 消息(见 13.2 节)。VolatileInfo 在 `.def` 文件中声明:

```
<Volatile>
    <position3D/>       // 同步位置全部三个分量
    <direction3D yaw="true" pitch="false" roll="false"/>  // 只同步 yaw
</Volatile>
```

**设计意图**:不同实体对位置/方向精度的需求不同。例如玩家 avatar 需要全部分量同步,而静态 NPC 可能只需要 yaw 同步。VolatileInfo 提供了细粒度的带宽优化。

---

## 十四、Buffered Ghost Messages 详解

### 14.1 为什么需要消息缓冲

Ghost 通信中存在一个经典问题:**Real 与 Ghost 之间的消息可能在 Ghost 还未创建时到达**。例如:

1. CellApp #1 上的 Real X 决定创建 Ghost 在 CellApp #2 上,发送 `createGhost` 消息。
2. 紧接着 Real X 修改了属性,发送 `ghostedDataUpdate` 消息。
3. 由于 UDP 的多路径投递或不同 CellAppChannel 的发送时机差异,`ghostedDataUpdate` 可能**先于** `createGhost` 到达 CellApp #2。
4. CellApp #2 收到 `ghostedDataUpdate` 时,找不到 Entity X,这条消息就会丢失。

为解决此问题,BigWorld 引入了 **Buffered Ghost Messages** 机制。

### 14.2 类层次结构

```
BufferedGhostMessageQueue (按 EntityID 分桶)
  │
  ├── map<EntityID, BufferedGhostMessagesForEntity*>
  │
  └── BufferedGhostMessagesForEntity (按 srcAddr 分桶)
        │
        ├── map<Address, BufferedGhostMessageList*>
        │
        └── BufferedGhostMessageList (按顺序的链表)
              │
              └── BufferedGhostMessage (基类)
                    ├── createBufferedCreateGhostMessage
                    ├── BufferedGhostMessageImpl<SpecificMsg>
                    └── ...
```

### 14.3 BufferedGhostMessage 基类

```cpp
// server/cellapp/buffered_ghost_message.hpp(节选)
class BufferedGhostMessage
{
public:
    BufferedGhostMessage( const Mercury::Address & srcAddr ) :
        srcAddr_( srcAddr )
    {}
    virtual ~BufferedGhostMessage() {}

    const Mercury::Address & srcAddr() const { return srcAddr_; }

    // 投递到目标 Entity。如果返回 false,说明 Entity 还未准备好(应该继续缓冲)
    virtual bool deliver( Entity & entity ) = 0;

    // 处理 Ghost 被销毁的情况
    virtual void ghostDestroyed( EntityID ghostID ) {}

private:
    Mercury::Address srcAddr_;
};
```

**核心方法**:
- `deliver()`:尝试将消息投递给目标 Entity。如果 Entity 还未准备好(如 `initGhost` 未完成),返回 false,继续保留在缓冲队列中。
- `ghostDestroyed()`:Ghost 被销毁时回调,允许缓冲消息清理或转发到 Real。

### 14.4 BufferedGhostMessagesForEntity

```cpp
// server/cellapp/buffered_ghost_messages.hpp(节选)
class BufferedGhostMessagesForEntity
{
public:
    BufferedGhostMessagesForEntity( EntityID entityID ) :
        entityID_( entityID )
    {}

    void add( BufferedGhostMessage * pMsg );
    void deliverTo( Entity & entity );
    void ghostDestroyed();

private:
    EntityID entityID_;
    typedef BW::list< BufferedGhostMessage * > Messages;
    Messages messages_;
};
```

### 14.5 subsequence 概念

**subsequence** 是 Buffered Ghost Messages 机制中最关键的概念之一。它指的是:Real 发送给 Ghost 的消息序列中,**createGhost 必须是第一条**,后续的消息(属性更新、位置更新等)构成一个"subsequence"。

```cpp
// server/cellapp/buffered_ghost_messages.cpp:delaySubsequence(概念节选)
void BufferedGhostMessages::delaySubsequence( EntityID entityID,
        const Mercury::Address & srcAddr,
        BufferedGhostMessage * pFirstMsg )
{
    // 找到或创建该 EntityID 的桶
    BufferedGhostMessagesForEntity * pForEntity = this->getOrCreate( entityID );

    // 延迟该 subsequence:将该消息标记为 subsequence 起始
    // 后续来自相同 srcAddr 的消息会被追加到该 subsequence 中
    pForEntity->delaySubsequence( srcAddr, pFirstMsg );
}
```

**工作流程**:

1. CellApp 收到 `createGhost` 消息,但发现 EntityID 已存在(可能是上一次的 Ghost 还未销毁,或并发创建)。
2. CellApp 不立即处理,而是将 `createGhost` 消息缓冲,标记为 subsequence 起始。
3. 后续来自相同 `srcAddr` 的消息(如 `ghostedDataUpdate`、`ghostPositionUpdate`)被追加到该 subsequence。
4. 当条件满足(如旧 Ghost 销毁完成)时,subsequence 被投递:
   - 先处理 `createGhost`,创建新的 Ghost。
   - 再依次处理后续消息。

### 14.6 BufferedGhostMessageQueue 主流程

```cpp
// server/cellapp/buffered_ghost_messages.hpp(节选)
class BufferedGhostMessages
{
public:
    // 检查是否有该 Entity 的缓冲消息
    bool hasMessagesFor( EntityID entityID,
            const Mercury::Address & srcAddr ) const;

    // 添加消息到缓冲
    void add( EntityID entityID, const Mercury::Address & srcAddr,
            BufferedGhostMessage * pMsg );

    // 延迟 subsequence
    void delaySubsequence( EntityID entityID,
            const Mercury::Address & srcAddr,
            BufferedGhostMessage * pFirstMsg );

    // 当 Ghost 创建完成后,投递缓冲的消息
    void deliverBufferedMessagesFor( EntityID entityID );

    // 当 Ghost 被销毁时,清理相关缓冲
    void ghostDestroyed( EntityID entityID );

private:
    typedef BW::map< EntityID, BufferedGhostMessagesForEntity * > EntitiesMap;
    EntitiesMap entitiesMap_;
};
```

### 14.7 投递时机

缓冲消息在以下时机被投递:

1. **Ghost 创建完成**:`Entity::initGhost()` 完成后,调用 `BufferedGhostMessages::deliverBufferedMessagesFor`,投递所有针对该 Entity 的缓冲消息。
2. **下一 tick**:如果 Entity 还未准备好,消息继续保留,直到下一次 tick 重试。
3. **Ghost 销毁**:如果 Ghost 在投递前被销毁,相关缓冲消息被清理或转发到 Real(取决于消息类型)。

### 14.8 性能与边界考虑

| 维度 | 设计选择 |
|------|----------|
| 内存 | 每条缓冲消息独立分配,subsequence 内消息以链表组织 |
| 复杂度 | 投递和清理为 O(N),N 为单 Entity 的缓冲消息数 |
| 上限 | 无硬上限,但 Ghost 创建完成后立即投递,通常缓冲量很小 |
| 持久性 | 缓冲消息不持久化,CellApp 重启后丢失 |
| 故障恢复 | Ghost 销毁时调用 `ghostDestroyed`,清理所有相关缓冲 |

---

## 十五、性能分析

### 15.1 内存开销

#### 15.1.1 Real Entity 内存

Real Entity 在 Entity 主体(约 1-2KB,取决于属性数量)之外,还要持有:

| 组件 | 大小(估算) |
|------|--------------|
| RealEntity 对象 | ~200 字节 |
| Haunts 数组 | 24 字节 * Haunt 数量 |
| 每个 Haunt 的 CellAppChannel | 共享(不单独分配) |
| Witness(如果持有) | ~500 字节 |
| Controller 集合 | ~200 字节 + 每个 Controller |
| Real 属性 | 取决于 def 定义 |

**典型 Avatar Real** 约 3-5 KB(不含 Python 对象),加上 Python 对象和属性 ScriptObject 后,通常为 10-20 KB。

#### 15.1.2 Ghost Entity 内存

Ghost 没有独立的 RealEntity 对象,但持有 `pRealChannel_`:

| 组件 | 大小(估算) |
|------|--------------|
| Entity 主体(无 Real 部分) | ~1-2 KB |
| pRealChannel_(共享) | 不单独计算 |
| Ghost 属性 | 取决于 def 定义,通常少于 Real |
| Controller(Ghost 版本) | ~100 字节 + 每个 |

**典型 Avatar Ghost** 约 2-4 KB,显著小于 Real。

#### 15.1.3 总体内存估算

假设一个 CellApp 承载 5000 个 Real 和 50000 个 Ghost:

- Real:5000 * 15 KB = 75 MB
- Ghost:50000 * 3 KB = 150 MB
- **总计** 约 225 MB,在合理范围内。

### 15.2 网络开销

#### 15.2.1 Haunt 通道消息

每 tick(50Hz,20ms),Real 发送给每个 Ghost 的消息:

| 消息类型 | 频率 | 大小(典型) |
|---------|------|---------------|
| ghostPositionUpdate | 每次位置变化 | ~24 字节(pos+dir+num) |
| ghostedDataUpdate | 属性变化时 | 变长,平均 ~50 字节 |
| ghostHistoryEvent | 事件触发时 | 变长 |
| ghostControllerUpdate | Controller 状态变化 | ~40 字节 |

假设平均每个 Ghost 每秒接收 10 个消息,平均 30 字节:

- 单 Ghost 带宽:10 * 30 * 8 = 2.4 Kbps(下行)
- 50000 Ghost:120 Mbps

这是一个相当大的带宽需求,因此 BigWorld 提供了多种优化:
- PackedXZ 位置压缩(2 字节 / 分量)
- IDAlias 替代 EntityID(1 字节 vs 4 字节)
- VolatileInfo 仅同步必要分量
- Hysteresis 减少 Ghost 创建/销毁震荡

### 15.3 Ghost 数量与性能关系

```
单 Real 的 Ghost 数量
        │
   CPU  │                ╱
        │              ╱
        │            ╱
        │          ╱
        │       ╱
        │    ╱
        │ ╱
        └──────────────── Ghost 数量
        0   10   20   30   50
```

- **0-10 Ghost**:CPU 开销线性增长,可忽略。
- **10-30 Ghost**:线性增长,但每次 ghostPositionUpdate 的发送开销累积。
- **30-50 Ghost**:开始非线性增长,因为 Real 端的 Haunts 遍历和发送循环成为热点。
- **>50 Ghost**:严重瓶颈,通常表明 Hysteresis 配置不当或 AoI 半径过大。

### 15.4 优化策略

#### 15.4.1 Hysteresis 防抖

```cpp
// server/cellapp/entity_ghost_maintainer.hpp(概念)
// Hysteresis 区域:在 ghostDistance 内创建,在 ghostDistance + HYSTERESIS 外销毁
const float HYSTERESIS_FACTOR = 1.1f;  // 通常 10%
float hysteresisDistance_ = ghostDistance_ * HYSTERESIS_FACTOR;
```

**效果**:避免实体在边界附近反复进出导致 Ghost 震荡创建/销毁。

#### 15.4.2 MINIMUM_GHOST_LIFESPAN 与配额

```cpp
// 配置参数
maxGhostsToDelete = 100;     // 每 tick 最多删除 100 个 Ghost
minGhostLifespan = 5.0f;     // Ghost 至少存活 5 秒
```

**目的**:
- `maxGhostsToDelete`:防止大规模 Ghost 销毁风暴,避免一次 tick 处理过多销毁。
- `minGhostLifespan`:防止新创建的 Ghost 立即被销毁(避免震荡)。

#### 15.4.3 GHOST_FUDGE

```cpp
// server/cellapp/entity_ghost_maintainer.cpp
static const float GHOST_FUDGE = 0.5f;  // 边界 fudge 因子
```

在判断 Ghost 是否在边界附近时,加入一个小偏移,避免浮点精度问题导致判断不稳定。

### 15.5 性能监控指标

CellApp 提供了以下 Watcher 指标用于 Ghost 性能监控:

| 指标 | 含义 |
|------|------|
| `ghosts/count` | 当前 CellApp 上的 Ghost 总数 |
| `ghosts/created` | 累计创建的 Ghost 数 |
| `ghosts/destroyed` | 累计销毁的 Ghost 数 |
| `ghosts/bufferedMessages` | 当前缓冲的消息数 |
| `cells/realCount` | Real 数量 |
| `cells/avgGhostsPerReal` | 平均每个 Real 的 Ghost 数 |

---

## 十六、边界情况与故障处理

### 16.1 多 Cell 边界同时迁移

当一个 Real 同时位于多个 Cell 的边界附近时,可能同时触发多个 Ghost 创建:

```
        CellApp #1   │  CellApp #2
                     │
   Real X ───────────┼──────────
        │            │
        │            │
   ─────┼────────────┼──────────
        │ CellApp #3  │  CellApp #4
        │             │
        │  Ghost A    │  Ghost B
```

**处理**:`EntityGhostMaintainer::visit()` 遍历 CellInfoTree 的所有叶子,为每个符合条件的 Cell 创建 Ghost。所有 Ghost 创建消息在同一个 tick 内批量发送。

### 16.2 Cell 销毁

当一个 Cell 被销毁(例如 CellApp 下线,Cell 被 CellAppMgr 重新分配):

1. Real 在该 Cell 上的实体被迁移到其他 Cell(通过 `offload` + `onload`)。
2. Ghost 在该 Cell 上的实体被简单销毁,Real 端的 Haunt 被移除。
3. Real 端检测到 Haunt 失效(通道断开),`EntityGhostMaintainer` 在下一个 tick 重新评估是否需要创建新的 Ghost。

### 16.3 网络故障

如果 CellApp #1 与 CellApp #2 之间的网络中断:

- CellApp #1 上的 Real X 仍持有指向 CellApp #2 的 Haunt,但 `CellAppChannel` 标记为不可达。
- 发送给 CellApp #2 的消息进入 `CellAppChannel::bundle()`,但不实际发送。
- 经过若干 tick 后,CellApp #2 被集群视为故障,CellAppMgr 通知 CellApp #1。
- CellApp #1 清除 Haunt,触发 `EntityGhostMaintainer` 重新评估。

### 16.4 Real/Ghost 同时销毁

如果 Real 和某个 Ghost 在同一 tick 内被销毁:

- Real 销毁时,`Entity::destroy()` 遍历 Haunts,发送 `delGhost` 消息。
- Ghost 销毁时,`delGhost` 消息可能已被缓冲(因为 Ghost 已销毁)。
- `BufferedGhostMessages::ghostDestroyed()` 清理所有针对该 Entity 的缓冲消息。
- 结果:无内存泄漏,无悬挂引用。

### 16.5 Zombie Ghost

**Zombie Ghost** 指 Ghost 仍然存在,但 Real 已经迁移到其他 CellApp,旧的 `pRealChannel_` 失效的情况。

**检测**:`numTimesRealOffloaded_` 代际标识。Real 每次 offload 时递增,Ghost 收到 `ghostSetReal` 时验证:

```cpp
// server/cellapp/entity.cpp:ghostSetReal(简化)
void Entity::ghostSetReal( const Mercury::Address & realAddr,
        NumTimesRealOffloadedType numTimesRealOffloaded )
{
    if (numTimesRealOffloaded_ != numTimesRealOffloaded)
    {
        // 代际不匹配,说明这是旧的迁移消息
        // 忽略或更新到最新的 Real 地址
        return;
    }
    // 正常处理
    pRealChannel_ = ...;  // 指向新的 Real 地址
}
```

### 16.6 nextRealAddr_ 过渡状态

在 Real offload 期间,Ghost 可能处于过渡状态:

| 字段 | 状态 | 含义 |
|------|------|------|
| `pRealChannel_` | NULL | 旧通道已断开 |
| `nextRealAddr_` | 非 NULL | 新 Real 地址已知,但还未建立通道 |
| `pReal_` | NULL | 仍是 Ghost |

**处理**:
- 此期间收到的 cell 方法调用消息被 `forwardMessageToReal` 转发到 `nextRealAddr_`。
- 一旦收到 `ghostSetReal`,建立新的 `pRealChannel_`,`nextRealAddr_` 清空。

### 16.7 CellApp 启动时的 Ghost 状态

CellApp 启动时,从备份恢复 Real Entity。此时:

- 所有 Real 暂时没有 Ghost(因为其他 CellApp 还没建立 Haunt)。
- 经过若干 tick,其他 CellApp 的 `EntityGhostMaintainer` 检测到新 Real,开始创建 Ghost。
- 这个过程是**渐进的**,不会一次性创建所有 Ghost,避免网络风暴。

---

## 十七、与其他引擎对比

### 17.1 与传统分区分服 MMOG 对比

| 维度 | 传统分区分服 | BigWorld Ghost |
|------|------------|----------------|
| 边界 | 硬边界(logout/login) | 软边界(Ghost 透明) |
| 状态一致性 | 强(单进程) | 最终一致(Real→Ghost) |
| 跨区交互 | 不支持 | 完全支持 |
| 负载均衡 | 静态 | 动态(Cell 迁移) |
| 故障恢复 | 整区不可用 | Real 备份恢复 |
| 实现复杂度 | 低 | 极高 |
| 玩家体验 | 切换明显 | 无缝 |

### 17.2 与 ECS 架构对比(以 Unity DOTS / Unreal Mass 为例)

| 维度 | ECS 架构 | BigWorld Ghost |
|------|---------|----------------|
| 实体模型 | 组件组合(EntityID + Components) | 继承(EntityType + Properties) |
| 跨进程 | 通常单进程,需要额外网络层 | 原生跨进程(Real/Ghost) |
| 同步模型 | 显式 RPC / Snapshot Interpolation | 隐式 Haunt 通道推送 |
| 脚本集成 | 通常 C# / C++ | Python(深度集成) |
| 可见性 | 显式 Query | 自动(AoI + Ghost) |
| 性能 | 极高(数据局部性) | 中等(动态分配 + Python) |

### 17.3 与分布式游戏服务器对比(以 Improbable SpatialOS 为例)

| 维度 | SpatialOS | BigWorld |
|------|----------|----------|
| 实体模型 | Component-based, authoritative worker | Real/Ghost 二态 |
| 跨进程 | Authority lease + write authority | Real 持有, Ghost 副本 |
| 负载均衡 | 自动 authority 迁移 | Cell offload + Ghost 重建 |
| 可扩展性 | 横向扩展至数千 worker | 限于百级 CellApp |
| 一致性 | Strong-ish(单 authority) | 最终一致(Real→Ghost) |
| 复杂度 | 极高(需写 worker) | 中等(脚本 + 配置) |

### 17.4 Ghost 机制的优劣分析

**优势**:
1. **透明性**:脚本无需关心 Real/Ghost,大幅简化游戏逻辑开发。
2. **可扩展**:CellApp 数量可动态增减,Ghost 自动适应。
3. **故障容错**:Real 备份,Ghost 重建,故障影响有限。
4. **就近计算**:Ghost 在本地解决 AoI/碰撞,无需跨进程查询 Real。

**劣势**:
1. **带宽开销**:Ghost 同步占用大量带宽(每个 Ghost 每秒 KB 级)。
2. **延迟**:Ghost 状态滞后于 Real(几十毫秒)。
3. **实现复杂度**:CellApp 中 Ghost 相关代码占比约 30%,bug 风险高。
4. **状态不一致**:网络故障时,Ghost 可能与 Real 短期不一致。
5. **调试困难**:跨进程的状态追踪需要专门工具(Watcher、DEBUG_FAULT_TOLERANCE)。

---

## 十八、配置参数详解

### 18.1 ghostDistance

```cpp
// server/cellapp/cellapp_config.cpp
BW_OPTION_RO( float, ghostDistance, DEFAULT_AOI_RADIUS );  // 500.0f
```

**含义**:Ghost 的创建距离。Real 周围 `ghostDistance` 范围内的 Cell 都会创建 Ghost。

**约束**:`maxAoIRadius <= ghostDistance`(否则玩家视野超出 Ghost 覆盖范围)。

**调优**:
- 增大:Ghost 覆盖更广,但带宽和内存开销线性增长。
- 减小:节省资源,但可能导致视野边缘实体不可见。

### 18.2 maxGhostsToDelete

```cpp
// server/cellapp/cellapp_config.cpp
BW_OPTION( uint, maxGhostsToDelete, 100 );
```

**含义**:单个 tick 内最多销毁的 Ghost 数量。

**目的**:防止大规模 Ghost 销毁风暴(例如 CellApp 重启后大量 Real 迁移导致)。

**调优**:
- 增大:销毁更快,但单 tick CPU 开销增大。
- 减小:销毁更平滑,但可能积累过多待销毁 Ghost。

### 18.3 minGhostLifespan

```cpp
// server/cellapp/cellapp_config.cpp
BW_OPTION_RO( float, minGhostLifespan, 5.f );  // 5 秒
DERIVED_BW_OPTION( int, minGhostLifespanInTicks );
```

**含义**:Ghost 创建后至少存活 5 秒,期间不允许销毁。

**目的**:防止边界震荡——实体在边界附近反复进出导致 Ghost 反复创建/销毁。

### 18.4 ghostUpdateHertz

```cpp
// server/cellapp/cellapp_config.cpp
BW_OPTION_RO( int, ghostUpdateHertz, 50 );
```

**含义**:Ghost 状态更新频率(50Hz = 每 20ms 更新一次)。

**调优**:
- 增大:Ghost 状态更新更频繁,延迟更低,但带宽开销增大。
- 减小:节省带宽,但 Ghost 状态滞后增加。

### 18.5 checkOffloadsPeriod

```cpp
// server/cellapp/cellapp_config.cpp
BW_OPTION_RO( float, checkOffloadsPeriod, 0.1f );  // 100ms
```

**含义**:OffloadChecker 检查周期。每 100ms 检查一次是否需要 offload Real 或创建/销毁 Ghost。

### 18.6 backupPeriod

```cpp
// server/cellapp/cellapp_config.cpp
BW_OPTION_RO( float, backupPeriod, 10.f );  // 10 秒
```

**含义**:Real Entity 的备份周期。每 10 秒将 Real 状态备份到 BackupHashChain。

### 18.7 enforceGhostDecorators

```cpp
// server/cellapp/cellapp_config.cpp
BW_OPTION( bool, enforceGhostDecorators, true );
```

**含义**:是否强制 Ghost 装饰器(enforce ghost decorators)。开启后,Real 上的某些方法调用会自动转发给所有 Ghost。

### 18.8 treatAllOtherEntitiesAsGhosts

```cpp
// server/cellapp/cellapp_config.cpp
BW_OPTION( bool, treatAllOtherEntitiesAsGhosts, true );
```

**含义**:将所有其他实体视为 Ghost 处理(优化路径)。

### 18.9 配置参数总览表

| 参数 | 默认值 | 含义 |
|------|--------|------|
| `ghostDistance` | 500.0 | Ghost 创建距离 |
| `maxGhostsToDelete` | 100 | 单 tick 最多销毁 Ghost 数 |
| `minGhostLifespan` | 5.0s | Ghost 最小寿命 |
| `ghostUpdateHertz` | 50 | Ghost 更新频率 |
| `checkOffloadsPeriod` | 0.1s | Offload 检查周期 |
| `backupPeriod` | 10s | Real 备份周期 |
| `enforceGhostDecorators` | true | 强制 Ghost 装饰器 |
| `treatAllOtherEntitiesAsGhosts` | true | 优化:其他实体视为 Ghost |
| `maxAoIRadius` | 500.0 | 最大 AoI 半径 |
| `defaultAoIRadius` | 500.0 | 默认 AoI 半径 |

---

## 十九、调试与可观测性

### 19.1 Watcher 系统

CellApp 暴露了大量 Watcher 指标,可通过 `bwdebug` 工具或 HTTP 接口查询:

```
cells/                         # Cell 相关
  count/                       # Cell 数量
  realCount/                   # Real 总数
  ghostCount/                  # Ghost 总数
  avgGhostsPerReal/            # 平均每个 Real 的 Ghost 数

entities/                      # Entity 相关
  count/                       # Entity 总数
  real/                        # Real 数量
  ghosts/                      # Ghost 数量

ghosts/                        # Ghost 专门指标
  created/                     # 累计创建数
  destroyed/                   # 累计销毁数
  bufferedMessages/            # 缓冲消息数

network/                       # 网络相关
  bytesSent/                   # 发送字节数
  bytesReceived/               # 接收字节数
  channels/                    # 通道数
```

### 19.2 DEBUG_FAULT_TOLERANCE

```cpp
// server/cellapp/entity.cpp(条件编译)
#ifdef DEBUG_FAULT_TOLERANCE
    DEBUG_MSG( "Entity %u: state transition %s -> %s\n",
        id_, oldState, newState );
#endif
```

启用 `DEBUG_FAULT_TOLERANCE` 编译选项后,会输出详细的 Ghost 状态转换日志,用于调试故障恢复流程。

### 19.3 Profile 系统

BigWorld 内置 Profile 系统,可测量函数执行时间:

```cpp
AUTO_SCOPED_PROFILE( "createGhost" );
SCOPED_PROFILE( TRANSIENT_LOAD_PROFILE );
```

通过 `bwdebug` 工具可查看每个 CellApp 的 Profile 数据,识别 Ghost 相关的热点函数:

```
Profile: createGhost          avg=0.5ms  calls=100
Profile: ghostPositionUpdate avg=0.1ms  calls=5000
Profile: offloadChecker      avg=2.0ms  calls=10
Profile: entityGhostMaintainer avg=5.0ms  calls=10
```

### 19.4 TRACE_MSG 与 WARNING_MSG

源码中使用了大量日志宏:

- `TRACE_MSG`:详细信息,默认不输出,可通过 `bwdebug -t` 启用。
- `DEBUG_MSG`:调试信息,默认输出。
- `INFO_MSG`:一般信息。
- `WARNING_MSG`:警告,通常表示潜在问题(如 Ghost 创建延迟)。
- `ERROR_MSG`:错误,通常表示严重问题(如配置错误)。

例如 `Space::createGhost` 中的 WARNING:

```cpp
WARNING_MSG( "Space::createGhost(%u): "
        "Buffered createGhost message for entity %u from %s\n",
    id_, entityID, srcAddr.c_str() );
```

这条 WARNING 表示 createGhost 消息被缓冲,通常意味着 Entity 已存在或正在创建中,可能是并发的 Ghost 创建。

### 19.5 调试技巧

#### 19.5.1 跟踪单个 Entity 的 Ghost 状态

通过 Watcher 查看 Entity 的状态:

```
bwdebug --watch "entities/byID/12345/isReal"
bwdebug --watch "entities/byID/12345/numTimesRealOffloaded"
bwdebug --watch "entities/byID/12345/haunts/count"
```

#### 19.5.2 跟踪 Haunt 通道

通过 `CellAppChannel` 的 Watcher:

```
bwdebug --watch "channels/byAddr/192.168.1.10:30000/bundlesSent"
bwdebug --watch "channels/byAddr/192.168.1.10:30000/bundlesReceived"
```

#### 19.5.3 检查 Ghost 数量异常

如果 Ghost 数量异常增长:

1. 检查 `maxGhostsToDelete` 是否过小。
2. 检查 `ghostDistance` 是否过大。
3. 检查 `EntityGhostMaintainer` 是否正常工作(Watcher 查看 `visits` 次数)。
4. 检查是否有 Zombie Ghost(`numTimesRealOffloaded_` 不匹配)。

---

## 二十、总结与最佳实践

### 20.1 Ghost 机制核心总结

BigWorld Engine 14.4.1 的 Ghost 同步机制是一种**优雅而复杂**的设计,核心思想可以总结为五点:

1. **二态统一**:`Entity` 类通过 `pReal_` 字段是否为 NULL 区分 Real/Ghost,避免独立 Ghost 类的代码重复。
2. **权威单一**:Real 是唯一的权威来源,Ghost 是 Real 的影子副本,通过 Haunt 通道接收推送。
3. **位置透明**:脚本和大部分 C++ 代码无需关心 Real/Ghost 区分,通过消息路由实现透明转发。
4. **就近服务**:Ghost 让跨 Cell 边界的视野、AoI、碰撞在本地 CellApp 解决,无需跨进程查询 Real。
5. **故障容错**:Real 备份 + Ghost 重建,网络或 CellApp 故障不会永久丢失状态。

### 20.2 关键设计权衡

| 权衡点 | 选择 | 代价 |
|--------|------|------|
| 简单性 vs 性能 | 二态统一 | 部分代码需运行时分支 |
| 一致性 vs 可用性 | 最终一致 | Ghost 状态可能滞后 |
| 透明性 vs 控制 | 自动 Ghost 管理 | 调试困难 |
| 带宽 vs 延迟 | 50Hz 推送 | 高带宽需求 |
| 故障恢复 vs 复杂度 | 备份+重建 | 实现复杂 |

### 20.3 最佳实践

#### 20.3.1 配置调优

1. **`ghostDistance`** 应与 `maxAoIRadius` 一致或略大,确保视野全覆盖。
2. **`maxGhostsToDelete`** 在大规模场景应调大(如 200-500),避免销毁积压。
3. **`minGhostLifespan`** 在边界密集场景应增大(如 10s),避免震荡。
4. **`ghostUpdateHertz`** 在带宽紧张时可降至 30Hz,延迟可接受。

#### 20.3.2 脚本设计

1. **避免在 Ghost 上跑逻辑**:Ghost 只应处理 `onGhostCreated`、`onGhostDestroyed`、`onEnterAoI`、`onLeaveAoI` 等少量回调。
2. **`GHOSTED_DATA` 属性应精简**:只放必要的状态(如 `hitpoints`、`teamID`),避免带宽浪费。
3. **避免跨 Real/Ghost 的强引用**:跨 CellApp 的引用应使用 Mailbox,而非直接 Python 引用。
4. **VolatileInfo 精确声明**:静态实体不需要同步方向,只 volatile 必要分量。

#### 20.3.3 故障排查

1. **Ghost 数量异常**:检查 `EntityGhostMaintainer` 是否正常,`numTimesRealOffloaded_` 是否匹配。
2. **状态不一致**:检查 `BufferedGhostMessages` 是否积压,Haunt 通道是否可达。
3. **性能瓶颈**:使用 Profile 系统定位热点,通常是 `ghostPositionUpdate` 或 Haunts 遍历。

#### 20.3.4 扩展开发

1. **新属性**:正确声明 `CELL_DATA` / `REAL_DATA` / `GHOSTED_DATA` 类别。
2. **新 Controller**:实现 Real 版本和 Ghost 版本,Ghost 版本应只读。
3. **新消息**:正确选择 `REAL_ONLY` / `GHOST_ONLY` / `REAL_OR_GHOST` 路由策略。

### 20.4 延伸阅读

完成本专题后,建议继续阅读:

- **专题 2 负载均衡算法**:理解 Cell 如何通过 offload/onload 实现 Real 迁移。
- **专题 3 容灾备份与恢复机制**:理解 Real 备份如何工作,故障切换流程。
- **专题 5 Mailbox 通信机制**:理解跨进程方法调用的底层机制。
- **专题 6 AOI 与 Witness 系统**:理解 Ghost 如何被 Witness 看到,AoI 更新流程。
- **专题 7 Mercury 网络协议**:理解 Haunt 通道的底层 UDP 传输。

### 20.5 结语

Ghost 同步机制是 BigWorld Engine 最具特色的设计,也是 CellApp 中最复杂的部分。深入理解 Ghost 机制,是构建大规模无缝 MMOG 世界的基石。本专题从设计哲学、数据结构、源码实现、消息路由、性能分析、边界情况、横向对比等多个维度进行了穷尽式剖析,希望能为开发者提供一份权威、深入的参考。

---

## 附录 A:关键文件索引

### A.1 核心源文件

| 文件路径 | 主要内容 |
|---------|---------|
| `server/cellapp/entity.hpp` | Entity 类定义,Real/Ghost 二态字段 |
| `server/cellapp/entity.cpp` | Entity 类实现,initGhost、convertRealToGhost 等 |
| `server/cellapp/entity.ipp` | Entity 内联函数,isReal() 等 |
| `server/cellapp/real_entity.hpp` | RealEntity 类定义,Haunt 内嵌类 |
| `server/cellapp/real_entity.cpp` | RealEntity 实现,Haunt 管理、offload 序列化 |
| `server/cellapp/entity_ghost_maintainer.hpp` | EntityGhostMaintainer 类定义 |
| `server/cellapp/entity_ghost_maintainer.cpp` | Ghost 维护逻辑 |
| `server/cellapp/offload_checker.hpp` | OffloadChecker 类定义 |
| `server/cellapp/offload_checker.cpp` | Offload 检查循环 |
| `server/cellapp/cell.hpp` | Cell 类定义,realEntities_ |
| `server/cellapp/cell.cpp` | Cell 实现,offloadEntity、addRealEntity |
| `server/cellapp/space.hpp` | Space 类定义,entities_ |
| `server/cellapp/space.cpp` | Space 实现,createGhost |
| `server/cellapp/cell_app_channel.hpp` | CellAppChannel 类定义 |
| `server/cellapp/cell_app_channels.hpp` | CellAppChannels 集合 |
| `server/cellapp/buffered_ghost_message.hpp` | BufferedGhostMessage 基类 |
| `server/cellapp/buffered_ghost_messages.hpp` | BufferedGhostMessages 队列 |
| `server/cellapp/buffered_ghost_messages.cpp` | 缓冲消息投递逻辑 |
| `server/cellapp/buffered_ghost_message_factory.hpp` | 缓冲消息工厂 |
| `server/cellapp/message_handlers.cpp` | 消息路由分发 |
| `server/cellapp/cellapp_interface.hpp` | 消息接口定义,GHOST_ONLY/REAL_ONLY |
| `server/cellapp/cellapp_config.hpp` | 配置参数声明 |
| `server/cellapp/cellapp_config.cpp` | 配置参数默认值 |

### A.2 关键代码行索引

| 功能 | 文件:行号 |
|------|----------|
| `Entity::isReal()` | `server/cellapp/entity.ipp:104-116` |
| `Entity::initGhost()` | `server/cellapp/entity.cpp:1676-1731` |
| `Entity::convertRealToGhost()` | `server/cellapp/entity.cpp:2005-2061` |
| `Entity::convertGhostToReal()` | `server/cellapp/entity.cpp:4657-4703` |
| `Entity::ghostSetReal()` | `server/cellapp/entity.cpp:4831-4860` |
| `Entity::ghostSetNextReal()` | `server/cellapp/entity.cpp:4868-4881` |
| `Entity::delGhost()` | `server/cellapp/entity.cpp:4888-4896` |
| `Entity::destroy()` | `server/cellapp/entity.cpp:2886-2998` |
| `Entity::offload()` | `server/cellapp/entity.cpp:1968-1991` |
| `Entity::forwardMessageToReal()` | `server/cellapp/entity.cpp:2268-2294` |
| `Entity::shouldBufferMessagesFrom()` | `server/cellapp/entity.cpp:7730-7751` |
| `Entity::writeGhostDataToStreamInternal()` | `server/cellapp/entity.cpp:1836-1876` |
| `Entity::readGhostDataFromStreamInternal()` | `server/cellapp/entity.cpp:1752-1810` |
| `RealEntity::addHaunt()` | `server/cellapp/real_entity.cpp:845-848` |
| `RealEntity::delHaunt()` | `server/cellapp/real_entity.cpp:855-858` |
| `RealEntity::deleteGhosts()` | `server/cellapp/real_entity.cpp:753-761` |
| `RealEntity::addDelGhostMessage()` | `server/cellapp/real_entity.cpp:741-746` |
| `RealEntity::writeOffloadData()` | `server/cellapp/real_entity.cpp:487-565` |
| `RealEntity::readOffloadData()` | `server/cellapp/real_entity.cpp:296-413` |
| `RealEntity::destroy()` | `server/cellapp/real_entity.cpp:246-283` |
| `RealEntity::addHistoryEvent()` | `server/cellapp/real_entity.cpp:703-735` |
| `Space::createGhost()` | `server/cellapp/space.cpp:228-295` |
| `Cell::offloadEntity()` | `server/cellapp/cell.cpp:183-217` |
| `Cell::addRealEntity()` | `server/cellapp/cell.cpp:227-240` |
| `Cell::checkOffloadsAndGhosts()` | `server/cellapp/cell.cpp:163-169` |

---

## 附录 B:关键消息一览表

### B.1 Ghost 创建/销毁相关消息

| 消息名 | 方向 | 用途 |
|--------|------|------|
| `createGhost` | Real → Ghost CellApp | 创建一个 Ghost |
| `delGhost` | Real → Ghost CellApp | 删除一个 Ghost |
| `ghostSetReal` | Real → Ghost | 通知 Ghost:Real 已迁移 |
| `ghostSetNextReal` | Real → Ghost | 通知 Ghost:Real 即将迁移 |
| `ghostSetNextRealAck` | Ghost → Real | 确认收到迁移通知 |

### B.2 Real/Ghost 转换相关消息

| 消息名 | 方向 | 用途 |
|--------|------|------|
| `offload` | CellA → CellB | 将 Real offload 到目标 Cell |
| `onload` | CellB → CellB | 在目标 Cell 上 onload Real |
| `convertRealToGhost` | CellA 内部 | Real 转 Ghost |
| `convertGhostToReal` | CellA 内部 | Ghost 转 Real |

### B.3 Ghost 状态同步消息

| 消息名 | 方向 | 用途 |
|--------|------|------|
| `ghostPositionUpdate` | Real → Ghost | 同步位置/方向 |
| `ghostedDataUpdate` | Real → Ghost | 同步 GHOSTED_DATA 属性 |
| `ghostHistoryEvent` | Real → Ghost | 同步事件历史 |
| `ghostControllerCreate` | Real → Ghost | 创建 Ghost Controller |
| `ghostControllerUpdate` | Real → Ghost | 更新 Ghost Controller |
| `ghostControllerDelete` | Real → Ghost | 删除 Ghost Controller |

### B.4 消息路由类别

| 类别 | 含义 | 示例 |
|------|------|------|
| `REAL_ONLY` | 仅 Real 处理 | `offload`, `onload` |
| `GHOST_ONLY` | 仅 Ghost 处理 | `createGhost`, `delGhost` |
| `WITNESS_ONLY` | 仅 Witness 处理 | 客户端可见性相关 |
| `REAL_OR_GHOST` | Real 或 Ghost 都可处理 | 通用 cell 方法调用 |

### B.5 转发相关消息

| 消息名 | 方向 | 用途 |
|--------|------|------|
| `forwardMessageToReal` | Ghost → Real | 转发到 Real |
| `forwardedCall` | Real → Ghost | 转发的调用 |
| `replyForwarder` | Real → Ghost | 转发回复 |

---

## 附录 C:术语表

| 术语 | 英文 | 含义 |
|------|------|------|
| Ghost | Ghost | Real Entity 在其他 CellApp 上的影子副本 |
| Real | Real Entity | 权威实体,持有完整状态 |
| Haunt | Haunt | Real 持有的"鬼宅"——一个 Ghost 在某 CellApp 上的位置 |
| CellApp | Cell Application | 承载 Cell 的进程 |
| Cell | Cell | 一个无缝空间的分区 |
| Space | Space | 一个完整的无缝空间(由多个 Cell 组成) |
| Offload | Offload | 将 Real 从一个 Cell 迁移到另一个 Cell |
| Onload | Onload | 在目标 Cell 上恢复 Real |
| Witness | Witness | 玩家视野,由 Real 持有 |
| AoI | Area of Interest | 兴趣区域 |
| Haunt Channel | Haunt Channel | Real 到 Ghost 的通信通道(基于 CellAppChannel) |
| CellAppChannel | CellAppChannel | 两个 CellApp 之间的通信通道 |
| CellInfoTree | CellInfoTree | Cell 信息树,描述 Space 中 Cell 的空间分布 |
| CellInfoVisitor | CellInfoVisitor | 遍历 CellInfoTree 的访问者基类 |
| Hysteresis | Hysteresis | 滞回区域,防抖机制 |
| numTimesRealOffloaded | numTimesRealOffloaded | Real 被 offload 的次数(代际标识) |
| nextRealAddr | nextRealAddr | 切换中:下一个 Real 的地址 |
| pRealChannel | pRealChannel_ | Ghost 持有:指向 Real 所在 CellApp 的通道 |
| pReal | pReal_ | Real 持有:RealEntity 对象指针 |
| BufferedGhostMessage | Buffered Ghost Message | 缓冲的 Ghost 消息(等待 Entity 就绪) |
| subsequence | subsequence | 缓冲消息中的子序列(createGhost + 后续消息) |
| EntityGhostMaintainer | EntityGhostMaintainer | Ghost 维护器,继承自 CellInfoVisitor |
| OffloadChecker | OffloadChecker | Offload 检查器,周期性调用 EntityGhostMaintainer |
| VolatileInfo | VolatileInfo | 易变信息(哪些位置/方向分量同步) |
| EventHistory | EventHistory | 事件历史(Real 与 Ghost 都有) |
| PropertyChange | PropertyChange | 属性变更(增量同步) |
| GHOSTED_DATA | GHOSTED_DATA | Ghost 也持有的属性类别 |
| CELL_DATA | CELL_DATA | 仅 Real 的属性类别 |
| REAL_DATA | REAL_DATA | 仅 Real 且持久化的属性类别 |
| Mercury | Mercury | BigWorld 的网络层 |
| Bundle | Bundle | Mercury 中的消息批次 |
| UDPChannel | UDPChannel | Mercury 的可靠 UDP 通道 |
| GHOST_FUDGE | GHOST_FUDGE | 边界判断的 fudge 因子(0.5) |
| MINIMUM_GHOST_LIFSPAN | MINIMUM_GHOST_LIFESPAN | Ghost 最小寿命(5 秒) |
| maxGhostsToDelete | maxGhostsToDelete | 单 tick 最多销毁 Ghost 数(100) |

---

> 本专题深度剖析了 BigWorld Engine 14.4.1 的 Ghost 同步机制,从设计哲学到源码实现,从数据结构到性能分析,从边界情况到横向对比,力求穷尽细节。希望本专题能成为开发者深入理解 BigWorld 引擎内部机制的权威参考。

**专题1:Ghost 同步机制深度剖析** · 完