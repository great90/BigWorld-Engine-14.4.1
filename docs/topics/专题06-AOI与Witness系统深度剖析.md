# 专题6:AOI 与 Witness 系统深度剖析

> BigWorld Engine 14.4.1 中最贴近"玩家感知"的核心机制——AOI(Area Of Interest)与 Witness 系统。
> 本专题将从设计哲学、几何模型、核心数据结构、触发器算法、Pull 模型、状态机、带宽优化、视觉扩展、性能分析、对比等所有维度,进行百科级深度剖析。

---

## 目录

- [一、引言与导读](#一引言与导读)
- [二、AOI 概述与设计哲学](#二aoi-概述与设计哲学)
- [三、AOI 几何模型](#三aoi-几何模型)
- [四、RangeList 索引结构总览](#四rangelist-索引结构总览)
- [五、RangeListNode 节点体系深度剖析](#五rangelistnode-节点体系深度剖析)
- [六、Shuffle 算法:有序链表的维护](#六shuffle-算法有序链表的维护)
- [七、RangeTrigger 触发器机制](#七rangetrigger-触发器机制)
- [八、滞回防抖机制深度剖析](#八滞回防抖机制深度剖析)
- [九、AoIUpdateScheme 更新策略](#九aoiupdatescheme-更新策略)
- [十、Witness 系统详解](#十witness-系统详解)
- [十一、Witness 的 Pull 模型](#十一witness-的-pull-模型)
- [十二、EntityCache 状态机深度剖析](#十二entitycache-状态机深度剖析)
- [十三、客户端实体同步流程](#十三客户端实体同步流程)
- [十四、IDAlias 带宽优化机制](#十四idalias-带宽优化机制)
- [十五、视觉控制器体系](#十五视觉控制器体系)
- [十六、EntityVision 视觉扩展](#十六entityvision-视觉扩展)
- [十七、ManualAoI 手动 AOI](#十七manualaoi-手动-aoi)
- [十八、性能分析](#十八性能分析)
- [十九、边界情况与故障处理](#十九边界情况与故障处理)
- [二十、与其他引擎对比](#二十与其他引擎对比)
- [二十一、配置参数详解](#二十一配置参数详解)
- [二十二、调试与可观测性](#二十二调试与可观测性)
- [二十三、总结与最佳实践](#二十三总结与最佳实践)
- [附录 A:关键文件索引](#附录-a关键文件索引)
- [附录 B:核心数据结构速查](#附录-b核心数据结构速查)
- [附录 C:关键算法步骤速查](#附录-c关键算法步骤速查)

---

## 一、引言与导读

### 1.1 本专题的定位

AOI(Area Of Interest,兴趣区域)是 MMOG 服务端的"眼睛"。在一个上万人同服的虚拟世界里,服务器**绝无可能**把所有实体的所有状态广播给所有玩家——既不可承受,也无必要。AOI 解决的核心问题是:

> **在任意时刻,如何高效地决定"哪些实体的哪些状态需要被发送给哪个客户端",并以最小代价完成这一决策?**

BigWorld Engine 14.4.1 用一套**双链表 + 触发器 + 优先级堆 + IDAlias 别名**的体系来回答这个问题。这套体系既不是传统的九宫格,也不是四叉树,而是一种**事件驱动的 Sweep-and-Prune(扫描-裁剪)变体**,其设计哲学与引擎整体的 CellApp/Real/Ghost 体系紧密耦合。

本专题面向已完成基础教程学习的读者,假设你已经知道:
- CellApp 是空间模拟进程,持有 Real 和 Ghost 实体;
- RealEntity 是拥有真实状态的实体,可以承载 Witness;
- BaseApp 是客户端的代理,CellApp 通过 BaseApp 转发数据给客户端;
- 实体之间通过 Mercury 网络层通信。

### 1.2 阅读路径建议

```
                    ┌────────────────────┐
                    │  二、AOI 设计哲学   │
                    └──────────┬─────────┘
                               ▼
                    ┌────────────────────┐
                    │ 三、AOI 几何模型    │
                    └──────────┬─────────┘
                               ▼
                    ┌────────────────────┐
                    │ 四、RangeList 结构  │ ← 数据结构基础
                    └──────────┬─────────┘
                               ▼
                    ┌────────────────────┐
                    │ 五、RangeListNode   │ ← 节点体系
                    └──────────┬─────────┘
                               ▼
                    ┌────────────────────┐
                    │ 六、Shuffle 算法    │ ← 核心算法
                    └──────────┬─────────┘
                               ▼
            ┌──────────────────┴──────────────────┐
            ▼                                     ▼
   ┌──────────────────┐               ┌──────────────────┐
   │ 七、RangeTrigger │ ────────────► │ 八、滞回防抖      │
   └────────┬─────────┘               └────────┬─────────┘
            └──────────────────┬──────────────┘
                               ▼
                    ┌────────────────────┐
                    │ 九、UpdateScheme   │
                    └──────────┬─────────┘
                               ▼
                    ┌────────────────────┐
                    │ 十、Witness 系统   │ ← 玩家代理
                    └──────────┬─────────┘
                               ▼
                    ┌────────────────────┐
                    │ 十一、Pull 模型    │
                    └──────────┬─────────┘
                               ▼
                    ┌────────────────────┐
                    │ 十二、EntityCache  │
                    └──────────┬─────────┘
                               ▼
                    ┌────────────────────┐
                    │ 十三~十七、子系统  │
                    └──────────┬─────────┘
                               ▼
                    ┌────────────────────┐
                    │ 十八~二十二、分析  │
                    └────────────────────┘
```

### 1.3 关键术语速查

| 术语 | 全称 | 含义 |
|------|------|------|
| AOI | Area Of Interest | 兴趣区域,服务器决定客户端可见实体的范围 |
| Witness | Witness | 见证者,RealEntity 的"眼睛",管理一个客户端的 AoI |
| RangeList | Range List | 范围链表,按 X/Z 坐标排序的双向链表 |
| RangeListNode | Range List Node | 范围链表节点,Entity/Trigger 的统一抽象 |
| RangeTrigger | Range Trigger | 范围触发器,监控节点进出范围的事件 |
| AoITrigger | AoI Trigger | Witness 专用的范围触发器,触发 enter/leave AoI |
| EntityCache | Entity Cache | 实体缓存,Witness 内部对每个可见实体的状态记录 |
| EntityCacheMap | Entity Cache Map | 实体缓存映射,以 Entity 为键的有序集合 |
| IDAlias | ID Alias | 实体短标识,1 字节,用于带宽优化 |
| AoIUpdateScheme | AoI Update Scheme | AoI 更新策略,按距离决定优先级增量 |
| Hysteresis | Hysteresis | 滞回,防止边界震荡的机制 |
| AppealRadius | Appeal Radius | 实体的"吸引力半径",用于大型实体被远距离看到 |
| AoIRoot | AoI Root | AoI 根节点,AoI 中心点(默认是实体自身,可独立设置) |
| LoD | Level of Detail | 细节层次,远距离实体发送更少属性 |
| VolatileInfo | Volatile Info | 易变信息标记,决定哪些属性走带宽优化的位置流 |

---

## 二、AOI 概述与设计哲学

### 2.1 为什么需要 AOI

考虑一个典型的 MMOG 场景:一个 5km × 5km 的大地图,上面有 5000 个 NPC、500 个玩家、10000 个可交互物体,共计约 15000 个实体。如果每个玩家每秒收到所有实体的状态更新,带宽将是天文数字。

假设每个实体每 tick(20Hz)需要发送 50 字节的状态:
- 单个玩家带宽:`15000 × 50 × 20 = 15,000,000 字节/秒 ≈ 15 MB/s`
- 500 个玩家总带宽:`500 × 15 MB/s = 7.5 GB/s`

这显然不可承受。但实际上,玩家只关心**自己周围一定范围内的实体**——一个玩家在主城广场,根本不需要知道千里之外某个野怪的坐标。AOI 就是用来裁剪这个范围的机制。

### 2.2 AOI 的设计目标

BigWorld 的 AOI 系统要同时满足以下目标:

1. **空间裁剪**:只把"附近"的实体发送给客户端;
2. **动态更新**:实体移动时,AOI 集合实时更新(进入/离开);
3. **优先级调度**:在带宽受限时,优先发送重要的实体(近距离、相关剧情);
4. **LoD 控制**:远距离实体只发位置,近距离实体发完整属性;
5. **带宽友好**:用各种手段压缩数据量(短别名、相对坐标、压缩流);
6. **稳定防抖**:边界附近不能反复 enter/leave(震荡);
7. **可扩展**:支持手动 AOI(隐身、伪装、剧情触发)和视觉系统(视野锥);
8. **跨进程透明**:实体在 Cell 间 offload 时,AOI 状态不丢失。

### 2.3 AOI 与传统视野系统的对比

| 维度 | 传统视野系统(全广播) | BigWorld AOI(范围触发) |
|------|------------------------|--------------------------|
| 算法复杂度 | O(N²),N 是实体总数 | O(N + K·R),R 是触发器数,K 是触发数 |
| 带宽 | O(N²) | O(N·R),R 是 AOI 内实体数 |
| 内存 | O(N) | O(N + 触发器数) |
| 边界处理 | 无 | 滞回防抖 |
| 优先级 | 无 | 基于距离的优先级堆 |
| LoD | 无 | 多级细节层次 |
| 动态调整 | 难 | AoIUpdateScheme 灵活配置 |

### 2.4 BigWorld AOI 的设计哲学

BigWorld 的 AOI 系统体现了几个核心哲学:

#### 哲学一:事件驱动而非轮询

很多引擎采用"每帧扫描所有实体"的轮询方式来判断 AOI 集合。BigWorld 反其道而行——它维护一个**有序的双向链表**,当实体移动时,通过 shuffle(洗牌)过程**自然发现**与触发器的"穿越"事件。这种设计的优势在于:

- 不需要每帧扫描整个空间;
- 触发事件发生在位置更新的瞬间,延迟极低;
- 算法复杂度与"实际移动距离 / 链表位置变化"成正比,而非与实体总数成正比。

#### 哲学二:Pull 模型而非 Push 模型

传统 Push 模型是:服务器主动决定"现在该发什么给客户端"。BigWorld 的 Witness 采用 **Pull 模型**:客户端在初始化或收到 enterAoI 后,主动向服务器请求该实体的详细数据(`requestEntityUpdate`)。这种设计的优势:

- 服务器不需要缓存"已经发到哪一步"的复杂状态;
- 客户端可以按自己的能力决定请求频率;
- 在 offload 跨进程时,Witness 状态可以无损迁移。

#### 哲学三:带宽是一等公民

BigWorld 在带宽优化上做了大量工作:
- **IDAlias**:1 字节代替 4 字节 EntityID;
- **相对坐标**:相对参考点的 12 位浮点;
- **PackedYawPitchRoll**:朝向压缩;
- **LoD**:远距离实体只发位置;
- **CompressionOStream**:实体属性压缩流;
- **优先级堆**:带宽受限时优先发重要实体。

#### 哲学四:解耦可见性决定与数据推送

BigWorld 把"决定哪些实体可见"和"把数据推给客户端"分成两个阶段:
1. **AoITrigger 决定**:负责"哪些实体进入/离开 AOI 集合";
2. **Witness::update 推送**:负责"在带宽预算内,按优先级推送数据"。

这种解耦让两个阶段可以独立优化,也方便了跨进程 offload 时的状态保存。

#### 哲学五:统一的范围抽象

BigWorld 把所有"在某个空间中有位置"的对象都抽象为 `RangeListNode`:
- Entity 是 RangeListNode;
- AoI 触发器是 RangeListNode;
- 视觉触发器是 RangeListNode;
- Proximity 触发器是 RangeListNode;
- 甚至"独立 AoI 根"(MobileRangeListNode)也是 RangeListNode。

这种统一抽象让所有这些对象可以**用同一套 shuffle 算法**维护相对顺序,简化了系统复杂度。

---

## 三、AOI 几何模型

### 3.1 球形 AOI(默认)

BigWorld 默认的 AOI 是**球形(实际上是 XZ 平面的圆形)**,以实体位置为中心,半径为 `aoiRadius`。

```
             ┌───────────────────┐
             │       Z 轴        │
             │       ▲           │
             │       │           │
             │       │           │
             │   ╭───┴───╮       │
             │   │       │       │
             │   │   ●   │  ← Entity (Witness 中心)
             │   │       │       │
             │   ╰───┬───╯       │
             │       │           │
             │       │           │
             │       └──────────► X 轴
             └───────────────────┘

                 aoiRadius = 500m (默认)
```

默认配置(`cellapp_config.cpp` L21-31):
```cpp
const float DEFAULT_AOI_RADIUS = 500.f;
BW_OPTION   ( float,  defaultAoIRadius,  DEFAULT_AOI_RADIUS );
BW_OPTION_RO( float,  maxAoIRadius,      DEFAULT_AOI_RADIUS );
```

`aoiRadius` 可以通过 `Entity.setAoIRadius(radius, hyst=5.f)` 在运行时动态调整,但被 `maxAoIRadius` 上限钳制(`witness.cpp` L2118-2125):
```cpp
if (aoiRadius_ > CellAppConfig::maxAoIRadius())
{
    WARNING_MSG( "Witness::setAoIRadius: Clamping %u's AoI radius (%.1f) "
        "to the maximum allowed value (%.1f)\n",
        entity_.id(), aoiRadius_, CellAppConfig::maxAoIRadius() );
    aoiRadius_ = CellAppConfig::maxAoIRadius();
}
```

### 3.2 矩形 AOI 的近似

BigWorld 实际上不使用矩形 AOI,但其内部 RangeList 是**按 X 和 Z 两个轴分别排序**的,所以可以理解为:

- 范围查询 = 矩形查询(X 范围 AND Z 范围);
- 球形 AOI 是在这个矩形的基础上做更精确的距离判断。

具体而言,当 Entity 的 RangeListNode 与 AoI 触发器的上下界发生穿越时,触发器需要同时检查 X 和 Z 两个轴的范围:

```cpp
// range_trigger.hpp L98-122 (节选)
bool wasInXRange( float x, float range ) const
{
    volatile float lowerBound = subX - range;
    volatile float upperBound = subX + range;
    return (lowerBound < x) && (x <= upperBound);
}

bool isInXRange( float x, float range ) const
{
    float subX = pCentralNode_->x();
    volatile float lowerBound = subX - range;
    volatile float upperBound = subX + range;
    return (lowerBound < x) && (x <= upperBound);
}
```

只有 X 和 Z 都在范围内,才算真正进入 AOI(详见第七节关于 `crossedXEntity` 和 `crossedZEntity` 的分析)。

### 3.3 自定义 AOI 形状

BigWorld 不直接支持任意多边形的 AOI 形状,但提供了几种扩展机制:

1. **AoIRoot(独立根)**:把 AOI 中心点从实体位置解耦,可以放在任意 (X, Z);
2. **AppealRadius(吸引力半径)**:让大型实体(如城堡)在更远的距离被看到;
3. **ManualAoI(手动 AOI)**:完全绕过触发器,脚本直接控制可见性;
4. **VisionController(视觉控制器)**:基于视野锥的可见性,补充 AOI 的圆形限制;
5. **WithholdFromClient(扣留)**:从 AOI 中"扣留"实体,不发送给客户端。

### 3.4 AOI 范围的设置

| 设置方式 | API | 说明 |
|----------|-----|------|
| 全局默认 | `bw.xml` 中 `cellApp/defaultAoIRadius` | 所有 Witness 创建时的初值 |
| 全局上限 | `bw.xml` 中 `cellApp/maxAoIRadius` | 钳制所有动态设置 |
| 实体级 | `Entity.setAoIRadius(radius, hyst)` | 运行时调整单个 Witness |
| 独立根 | `Entity.aoiRoot = (x, z)` | AOI 中心与实体位置解耦 |

### 3.5 AppealRadius:大型实体的特殊处理

有些实体(如城堡、山脉)体积很大,即使玩家在它的 AOI 范围之外,也应该能看到它。BigWorld 用 `AppealRadius` 来解决这个问题。

```cpp
// entity.cpp L1213-1222 (构造函数)
pRangeListNode_ = new EntityRangeListNode( this );

const float appealRadius = pEntityType->description().appealRadius();
const bool hasAoIAppeal = !isZero( appealRadius );

if (hasAoIAppeal)
{
    pRangeListAppealTrigger_ =
        new RangeListAppealTrigger( pRangeListNode_, appealRadius );
}
```

`RangeListAppealTrigger` 是一个**反向触发器**:它的范围围绕实体自身,但目的是被其他 AoITrigger "发现"。当一个 Witness 的 AoITrigger 被创建时,会调用 `visitLargeEntities` 检查所有 AppealRadius 触发器,看它们是否在新 AoI 范围内:

```cpp
// space.cpp L346-359
void Space::visitLargeEntities( float x, float z, RangeTrigger & visitor )
{
    for (RangeTriggerList::iterator iter = appealRadiusList_.begin();
        iter != appealRadiusList_.end();
        ++iter)
    {
        RangeTrigger * pAppealTrigger = *iter;
        if (pAppealTrigger->contains( x, z ))
        {
            visitor.triggerEnter( *pAppealTrigger->pEntity() );
        }
    }
}
```

注意:当实体有 AppealRadius 时,它的 `EntityRangeListNode` 会被设置为**不再作为 AoI 触发点**(`isAoITrigger(false)`),改由 AppealTrigger 接管(`entity.cpp` L2403-2413):

```cpp
if (pRangeListAppealTrigger_)
{
    // AppealRadius is non-zero.
    // Entity node is no longer an AoI trigger since range is taking over.
    pRangeListNode_->isAoITrigger( false );

    pRangeListAppealTrigger_->insert();
    this->addTrigger( pRangeListAppealTrigger_ );
    ...
}
```

---

## 四、RangeList 索引结构总览

### 4.1 RangeList 的本质

`RangeList` 是 BigWorld AOI 系统的核心数据结构。它是一个**双轴(X 和 Z)排序的双向链表**,所有在该 Space 中的 RangeListNode 都按 X 坐标排序成一条链,同时按 Z 坐标排序成另一条链。

```
X 链(按 X 排序):    HEAD ──► N1(x=10) ──► N2(x=20) ──► N3(x=30) ──► TAIL
Z 链(按 Z 排序):    HEAD ──► N2(z=5)  ──► N3(z=15) ──► N1(z=25) ──► TAIL
```

每个节点同时存在于两条链中,但每条链的顺序独立。

### 4.2 RangeList 类定义

```cpp
// cell_range_list.hpp L12-32
class RangeList
{
public:
    RangeList();

    void add( RangeListNode * pNode );

    // For debugging
    bool isSorted() const;
    void debugDump();

    const RangeListNode * pFirstNode() const    { return &first_; }
    const RangeListNode * pLastNode() const     { return &last_; }

    RangeListNode * pFirstNode() { return &first_; }
    RangeListNode * pLastNode()  { return &last_; }

private:
    RangeListTerminator first_;
    RangeListTerminator last_;
};
```

`RangeList` 本身极简,只持有两个哨兵节点 `first_` 和 `last_`。所有真正的节点(Entity、Trigger 等)都通过 `prevX/nextX/prevZ/nextZ` 指针串在两条链上。

### 4.3 哨兵节点 RangeListTerminator

```cpp
// range_list_node.hpp L132-141
class RangeListTerminator : public RangeListNode
{
public:
    RangeListTerminator( bool isHead ) :
        RangeListNode( RangeListFlags( 0 ), RangeListFlags( 0 ),
                isHead ? RANGE_LIST_ORDER_HEAD : RANGE_LIST_ORDER_TAIL) {}
    float x() const { return (order_ ? FLT_MAX : -FLT_MAX); }
    float z() const { return (order_ ? FLT_MAX : -FLT_MAX); }
    BW::string debugString() const { return order_ ? "Tail" : "Head"; }
};
```

- `first_`(头哨兵):`x = z = -FLT_MAX`,`order = RANGE_LIST_ORDER_HEAD(0)`
- `last_`(尾哨兵):`x = z = FLT_MAX`,`order = RANGE_LIST_ORDER_TAIL(0xffff)`

哨兵的存在使得所有 shuffle 算法不需要特判链表端点,简化代码。

### 4.4 RangeList 的构造

```cpp
// cell_range_list.cpp L26-30
RangeList::RangeList() : first_( true ), last_( false )
{
    last_.insertBeforeX( &first_ );
    last_.insertBeforeZ( &first_ );
}
```

构造后,链表是空的:`first_` 和 `last_` 互相指向。

### 4.5 节点的添加

```cpp
// cell_range_list.cpp L36-45
void RangeList::add( RangeListNode * pNode )
{
    SCOPED_PROFILE( SHUFFLE_ENTITY_PROFILE );

    MF_ASSERT( pNode != NULL );

    first_.nextX()->insertBeforeX( pNode );
    first_.nextZ()->insertBeforeZ( pNode );
    pNode->shuffleXThenZ( -FLT_MAX, -FLT_MAX );
}
```

添加过程:
1. 把新节点插入到 `first_.nextX()` 之前(即链表最前);
2. 同样插入到 Z 链最前;
3. 调用 `shuffleXThenZ(-FLT_MAX, -FLT_MAX)` 让节点"飘"到正确位置。

`oldX = oldZ = -FLT_MAX` 的意图是:让 shuffle 算法认为这个节点是从负无穷移动过来的,从而在 shuffle 过程中触发与所有"应该被它穿越"的节点的事件。但通常新加入的节点 `wantsFlags` 和 `makesFlags` 都已配置好,不会触发不必要的事件。

### 4.6 RangeList 与 Space 的关系

每个 Space 持有一个 RangeList:

```cpp
// space.hpp L213 (示意)
RangeList rangeList_;
RangeTriggerList appealRadiusList_;  // 大型实体的 AppealTrigger 列表
```

所有该 Space 中的 Entity、Trigger 都注册到这个 RangeList 中。当 Entity 跨越 Cell 边界时(offload),它会从原 Cell 的 RangeList 移除,加入新 Cell 的 RangeList。

### 4.7 为什么选择双轴链表

BigWorld 选择双轴链表而不是四叉树/九宫格的原因:

| 因素 | 双轴链表 | 四叉树 | 九宫格 |
|------|----------|--------|--------|
| 实现 | 中等 | 复杂 | 简单 |
| 移动成本 | O(移动距离/节点密度) | O(log N) | O(1) 跨格 |
| 范围查询 | O(R) | O(log N + R) | O(R²) |
| 内存 | 紧凑 | 节点分散 | 网格空耗 |
| 边界震荡 | 滞回可解 | 难处理 | 跨格难处理 |
| 实体稀疏 | 高效 | 高效 | 网格浪费 |
| 实体密集 | 链表长 | 节点深 | 网格爆炸 |

BigWorld 的 MMOG 场景实体分布通常**不均匀**(主城密集、野外稀疏),双轴链表在两种场景下都有合理表现,且实现简洁。

---

## 五、RangeListNode 节点体系深度剖析

### 5.1 节点继承体系

```
                    ┌─────────────────────┐
                    │   RangeListNode     │ (抽象基类)
                    │   - pPrevX/NextX    │
                    │   - pPrevZ/NextZ    │
                    │   - wantsFlags_      │
                    │   - makesFlags_     │
                    │   - order_          │
                    └──────────┬──────────┘
                               │
            ┌──────────────────┼──────────────────────┐
            │                  │                      │
            ▼                  ▼                      ▼
┌───────────────────┐  ┌────────────────────┐  ┌──────────────────┐
│ EntityRangeList   │  │ RangeTriggerNode  │  │ RangeListTerm-   │
│ Node              │  │ (触发器节点)       │  │ inator (哨兵)     │
│ (实体节点)        │  │ - pRange_          │  └──────────────────┘
└───────────────────┘  │ - range_           │
                       │ - oldRange_        │
                       └─────────┬──────────┘
                                 │
                                 │ (被 RangeTrigger 持有)
                                 │
                                 ▼
                       ┌────────────────────┐
                       │  MobileRangeList   │ (独立 AOI 根)
                       │  Node              │
                       │  - x_, z_          │
                       │  - triggers_       │
                       └────────────────────┘
```

### 5.2 RangeListNode 基类

`RangeListNode` 是所有节点的抽象基类,定义在 `range_list_node.hpp` L34-125:

```cpp
class RangeListNode
{
public:
    enum RangeListFlags
    {
        FLAG_NO_TRIGGERS        = 0,
        FLAG_ENTITY_TRIGGER     = 0x01,
        FLAG_LOWER_AOI_TRIGGER  = 0x02,
        FLAG_UPPER_AOI_TRIGGER  = 0x04,

        FLAG_IS_ENTITY          = 0x10,
        FLAG_IS_LOWER_BOUND     = 0x20
    };

    RangeListNode( RangeListFlags wantsFlags,
            RangeListFlags makesFlags,
            RangeListOrder order ) :
        pPrevX_( NULL ), pNextX_( NULL ),
        pPrevZ_( NULL ), pNextZ_( NULL ),
        wantsFlags_( wantsFlags ),
        makesFlags_( makesFlags ),
        order_( order )
    { }
    ...
};
```

#### 5.2.1 wantsFlags 与 makesFlags

这是 RangeListNode 设计中**最巧妙**的部分:

- `wantsFlags_`:本节点**关心**哪些类型的穿越事件(我"想"被通知什么);
- `makesFlags_`:本节点**会产生**哪些类型的穿越事件(我"是"什么,能被别人关心)。

只有当一个节点 A 的 `wantsFlags_` 与另一个节点 B 的 `makesFlags_` 有共同位时,A 才会被通知与 B 的穿越事件:

```cpp
// range_list_node.hpp L89-92
bool wantsCrossingWith( RangeListNode * pOther ) const
{
    return (wantsFlags_ & pOther->makesFlags_);
}
```

例如:
- Entity 节点的 `makesFlags = FLAG_ENTITY_TRIGGER | FLAG_LOWER_AOI_TRIGGER | FLAG_UPPER_AOI_TRIGGER | FLAG_IS_ENTITY`,意思是"我是一个 Entity,可以触发 AoI 触发器、上下界 AoI 触发器";
- AoI 触发器的 `wantsFlags = FLAG_LOWER_AOI_TRIGGER | FLAG_UPPER_AOI_TRIGGER`,意思是"我关心 AoI 上下界触发";
- 当 AoI 触发器与 Entity 穿越时,因为 `wantsFlags & makesFlags` 非零,会触发事件;
- 但两个 Entity 之间穿越时,因为 Entity 的 `wantsFlags = FLAG_NO_TRIGGERS`,不会触发事件。

这种位运算的设计极大地减少了不必要的回调,是性能的关键。

#### 5.2.2 RangeListOrder:同坐标排序

当两个节点坐标完全相同时(浮点相等),用 `order_` 来决定先后顺序:

```cpp
// range_list_node.hpp L18-25
enum RangeListOrder
{
    RANGE_LIST_ORDER_HEAD        = 0,
    RANGE_LIST_ORDER_ENTITY      = 100,
    RANGE_LIST_ORDER_LOWER_BOUND = 190,
    RANGE_LIST_ORDER_UPPER_BOUND = 200,
    RANGE_LIST_ORDER_TAIL        = 0xffff
};
```

这意味着同坐标时:
```
HEAD(0) < ENTITY(100) < LOWER_BOUND(190) < UPPER_BOUND(200) < TAIL(0xffff)
```

这个顺序非常关键,它保证了:
- 触发器的下界(LOWER_BOUND)总在 Entity 之后,所以下界"追上" Entity 时会触发事件;
- 触发器的上界(UPPER_BOUND)总在下界之后,所以上界"被追上"时也会触发事件;
- 哨兵永远在两端,不会被穿越。

### 5.3 EntityRangeListNode:实体节点

```cpp
// entity_range_list_node.hpp L16-45
class EntityRangeListNode : public RangeListNode
{
public:
    EntityRangeListNode( Entity * entity );

    float x() const;
    float z() const;

    BW::string debugString() const;
    Entity * getEntity() const;

    void remove();

    void isAoITrigger( bool isAoITrigger );

    static Entity * getEntity( RangeListNode * pNode )
    {
        MF_ASSERT( pNode->isEntity() );
        return static_cast< EntityRangeListNode * >( pNode )->getEntity();
    }
    ...
protected:
    Entity * pEntity_;
};
```

#### 5.3.1 构造函数:标志位的配置

```cpp
// entity_range_list_node.cpp L18-27
EntityRangeListNode::EntityRangeListNode( Entity * pEntity ) :
    RangeListNode( FLAG_NO_TRIGGERS,                              // wants
            RangeListFlags(
                FLAG_ENTITY_TRIGGER |
                FLAG_LOWER_AOI_TRIGGER |
                FLAG_UPPER_AOI_TRIGGER |
                FLAG_IS_ENTITY ),                                 // makes
            RANGE_LIST_ORDER_ENTITY ),                            // order
    pEntity_( pEntity )
{}
```

注意:
- Entity 的 `wantsFlags = FLAG_NO_TRIGGERS`,即"我不关心与任何节点的穿越事件"——Entity 是被动的,只触发别人;
- Entity 的 `makesFlags` 包含所有触发器类型,意味着"我可以被 AoI 触发器和 Appeal 触发器感知";
- `FLAG_IS_ENTITY` 是一个特殊标志,让其他节点可以快速判断"这个节点是 Entity 还是触发器"。

#### 5.3.2 位置访问

```cpp
// entity_range_list_node.cpp L35-49
float EntityRangeListNode::x() const
{
    return pEntity_->position().x;
}

float EntityRangeListNode::z() const
{
    return pEntity_->position().z;
}
```

注意 Entity 节点**不缓存位置**,每次访问都从 Entity 读取。这意味着 Entity 的位置变化会立即反映在 RangeList 中(但需要 shuffle 才能更新链表顺序)。

#### 5.3.3 isAoITrigger:角色切换

当一个 Entity 没有 AppealRadius 时,它本身就是 AoI 触发点(`makesFlags` 包含 `FLAG_LOWER_AOI_TRIGGER | FLAG_UPPER_AOI_TRIGGER`);当它有 AppealRadius 时,触发权交给 AppealTrigger,自身的这两个标志被清除:

```cpp
// entity_range_list_node.cpp L97-109
void EntityRangeListNode::isAoITrigger( bool isAoITrigger )
{
    int changingFlags = FLAG_LOWER_AOI_TRIGGER | FLAG_UPPER_AOI_TRIGGER;

    if (isAoITrigger)
    {
        makesFlags_ = RangeListFlags( makesFlags_ | changingFlags );
    }
    else
    {
        makesFlags_ = RangeListFlags( makesFlags_ & ~changingFlags );
    }
}
```

#### 5.3.4 remove:从链表中"飘走"

```cpp
// entity_range_list_node.cpp L78-89
void EntityRangeListNode::remove()
{
    Entity::callbacksPermitted( false );
    Vector3 pos = pEntity_->position();
    float oldZ = pos.z;
    pos.z = FLT_MAX;
    pEntity_->globalPosition_ = pos;

    this->shuffleZ( this->x(), oldZ );
    this->removeFromRangeList();
    Entity::callbacksPermitted( true );
}
```

注意:这里**先把 Z 坐标设为 FLT_MAX**,然后 shuffle Z,这样节点会"飘到"链表末尾,在飘动的过程中触发所有 Z 范围内的 leave 事件。这是让 AoI 触发器知道"实体离开了"的关键。

### 5.4 RangeTriggerNode:触发器节点

```cpp
// range_trigger.hpp L14-57
class RangeTriggerNode : public RangeListNode
{
public:
    RangeTriggerNode( RangeTrigger * pRangeTrigger,
        float range,
        RangeListFlags wantsFlags,
        RangeListFlags makesFlags );

    float x() const;
    float z() const;

    float oldX() const;
    float oldZ() const;

    virtual BW::string debugString() const;

    float range() const         { return range_; }
    void range( float r )       { range_ = r; }      // don't call this
    void setRange( float range );                    // call this instead

    float oldRange() const      { return oldRange_; }
    void oldRange( float r )    { oldRange_ = r; }
    void updateOldRange()       { oldRange_ = range_; }

    virtual void crossedX( RangeListNode * node, bool positiveCrossing,
        float oldOthX, float oldOthZ );
    virtual void crossedZ( RangeListNode * node, bool positiveCrossing,
        float oldOthX, float oldOthZ );
    ...
protected:
    RangeTrigger * pRange_;
    float range_;       // 范围(正数上界,负数下界)
    float oldRange_;    // 上一帧的范围(用于穿越检测)
};
```

#### 5.4.1 触发器节点的位置

触发器节点的位置 = 中心节点位置 + range:

```cpp
// range_trigger.cpp L50-77
float RangeTriggerNode::x() const
{
    volatile float x = pRange_->pCentralNode()->x() + range_;
    return x;
}

float RangeTriggerNode::z() const
{
    volatile float z = pRange_->pCentralNode()->z() + range_;
    return z;
}

float RangeTriggerNode::oldX() const
{
    volatile float x = pRange_->oldEntityX_ + oldRange_;
    return x;
}

float RangeTriggerNode::oldZ() const
{
    volatile float z = pRange_->oldEntityZ_ + oldRange_;
    return z;
}
```

注意:
- `range_` 可以是正数(上界)或负数(下界);
- 用 `volatile` 关键字强制浮点运算落回内存,避免扩展精度导致的位置不一致问题(见后文"防抖"分析);
- `oldX/oldZ` 用于在 shuffle 过程中判断"是否之前在范围内"。

#### 5.4.2 volatile 关键字的玄机

代码中大量出现 `volatile float` 注释,例如:

```cpp
// These volatile values are important. If this is not done, the
// calculation may be done with greater precision than what was used in
// calculating the nodes position in the range list. This may cause
// some triggers to be missed or to occur when they should not have.
volatile float lowerBound = subX - range;
volatile float upperBound = subX + range;
```

这是因为在 x86/x87 浮点单元中,中间计算可能使用 80 位扩展精度,而写入内存后是 32 位单精度。如果 `x()` 用扩展精度返回,而 `isInXRange` 用单精度比较,就会出现"位置在链表中已经穿越,但范围判断说不穿越"的不一致情况。`volatile` 强制每次都落回 32 位内存,保证一致性。

### 5.5 MobileRangeListNode:独立 AoI 根

```cpp
// mobile_range_list_node.hpp L15-43
class MobileRangeListNode : public RangeListNode
{
public:
    MobileRangeListNode( float x, float z, RangeListFlags wantsFlags,
        RangeListFlags makesFlags,
        RangeListOrder order = RANGE_LIST_ORDER_ENTITY );

    float x() const;
    float z() const;

    BW::string debugString() const;

    void setPosition( float newX, float newZ );
    void remove();

    void addTrigger( RangeTrigger * pTrigger );
    void modTrigger( RangeTrigger * pTrigger );
    void delTrigger( RangeTrigger * pTrigger );

private:
    float x_;
    float z_;

    typedef BW::vector< RangeTrigger * > Triggers;
    Triggers triggers_;
};
```

`MobileRangeListNode` 是一个**任意位置**的 RangeListNode,主要用途是作为 Witness 的**独立 AoI 根**:

- 默认情况下,Witness 的 AoI 中心 = Entity 位置;
- 通过 `Entity.aoiRoot = (x, z)` 可以把 AoI 中心解耦到任意点;
- 这种用法常见于"上帝视角"、"分身观察"等场景。

注意 `MobileRangeListNode` 自己维护了一个 `triggers_` 列表(类似 Entity),用于在位置变化时 shuffle 关联的触发器。

### 5.6 RangeListTerminator:哨兵节点

如前述,哨兵节点 `first_` 和 `last_` 用 ±FLT_MAX 作为坐标,用 `RANGE_LIST_ORDER_HEAD/TAIL` 作为 order,确保永远在链表端点。

---

## 六、Shuffle 算法:有序链表的维护

### 6.1 Shuffle 的核心思想

当 RangeListNode 的位置发生变化时,需要在链表中"飘动"到正确位置,这个过程叫 **shuffle**(洗牌)。在飘动的过程中,会与路径上的其他节点"穿越"(crossing),触发 crossedX/crossedZ 回调。

```
初始:    HEAD ─► A(x=10) ─► B(x=20) ─► C(x=30) ─► TAIL
B 移动到 x=25:
         HEAD ─► A(x=10) ─► B(x=25) ─► C(x=30) ─► TAIL
                             ↑
                             B 在飘动过程中穿越了 C(从 C 之前到 C 之后)
```

### 6.2 shuffleXThenZ:两次独立 shuffle

```cpp
// range_list_node.cpp L29-34
void RangeListNode::shuffleXThenZ( float oldX, float oldZ )
{
    this->shuffleX( oldX, oldZ );
    this->shuffleZ( oldX, oldZ );
}
```

BigWorld 把 X 和 Z 的 shuffle 分开做,这是**有意为之**的设计:
- X 先 shuffle,Z 后 shuffle;
- X shuffle 时,用 `oldZ` 检查 Z 范围(因为 Z 还没动);
- Z shuffle 时,用新的 `x` 检查 X 范围(X 已经稳定)。

这种顺序保证了一致性:在一次移动中,X 穿越和 Z 穿越是独立判定的事件,不会相互干扰。

### 6.3 shuffleX 详解

```cpp
// range_list_node.cpp L44-128
void RangeListNode::shuffleX( float oldX, float oldZ )
{
    MF_ASSERT( !Entity::callbacksPermitted() );
    static bool inShuffle = false;
    MF_ASSERT( !inShuffle );    // make sure we are not reentrant
    inShuffle = true;

    float ourPosX = this->x();
    float othPosX;

    // Shuffle to the left(negative X)...
    while (pPrevX_ != NULL &&
            (ourPosX < (othPosX = pPrevX_->x()) ||
                (isEqual( ourPosX, othPosX ) &&
                order_ <= pPrevX_->order_)))
    {
        if (this->wantsCrossingWith( pPrevX_ ))
        {
            this->crossedX( pPrevX_, true, pPrevX_->x(), pPrevX_->z() );
        }

        if (pPrevX_->wantsCrossingWith( this ))
        {
            pPrevX_->crossedX( this, false, oldX, oldZ );
        }

        // unlink us
        if (pNextX_!= NULL)
        {
            pNextX_->pPrevX_ = pPrevX_;
        }

        pPrevX_->pNextX_ = pNextX_;

        // fix our pointers
        pNextX_ = pPrevX_;
        pPrevX_ = pPrevX_->pPrevX_;

        // relink us
        if (pPrevX_ != NULL)
        {
            pPrevX_->pNextX_= this;
        }

        pNextX_->pPrevX_= this;
    }

    // Shuffle to the right(positive X)...
    while (pNextX_ != NULL &&
            (ourPosX > (othPosX = pNextX_->x()) ||
                (isEqual( ourPosX, othPosX ) &&
                order_ >= pNextX_->order_)))
    {
        ...
    }

    inShuffle = false;
}
```

#### 6.3.1 算法步骤(向左 shuffle)

1. **比较**:如果当前节点 X 小于前驱节点 X(或 X 相等且 order 较小),需要向前 swap;
2. **触发回调**:如果双方互相关心,分别调用 `crossedX`(注意参数:本节点收到 `positiveCrossing=true`,前驱收到 `false`);
3. **指针调整**:swap 两个节点的位置(典型双向链表 swap);
4. **循环**:重复直到找到正确位置。

#### 6.3.2 回调方向:positiveCrossing 的含义

```cpp
this->crossedX( pPrevX_, true, ... );      // 本节点穿越了前驱,正向(从左到右)
pPrevX_->crossedX( this, false, ... );      // 前驱被本节点穿越,反向
```

`positiveCrossing = true` 表示"另一个节点相对于我是从负方向移动到正方向",在触发器判断 enter/leave 时非常关键(详见第七节)。

#### 6.3.3 不可重入保护

```cpp
static bool inShuffle = false;
MF_ASSERT( !inShuffle );
inShuffle = true;
...
inShuffle = false;
```

shuffle 过程中不能重入,因为链表结构正在调整。这也是为什么 `Entity::callbacksPermitted( false )` 在 shuffle 前后调用——防止脚本回调中再次触发位置变化。

#### 6.3.4 回调禁用:callbacksPermitted

注意 shuffleX 一开始就 `MF_ASSERT( !Entity::callbacksPermitted() )`。这意味着 shuffle 必须在"回调禁用"模式下进行,即不能在 shuffle 过程中调用脚本(脚本可能再触发位置变化,导致重入)。

### 6.4 shuffleZ

`shuffleZ` 与 `shuffleX` 完全对称,只是操作 Z 链。

### 6.5 触发器的 Shuffle:Expand/Contract 优化

当 Entity 移动时,它身上挂的触发器(如 AoITrigger)也需要 shuffle。但 BigWorld 做了一个**重要优化**:

- **先 shuffle 移动方向上的触发器(Expand)**;
- **再 shuffle Entity 本身**;
- **最后 shuffle 反方向上的触发器(Contract)**。

```cpp
// entity.cpp L3970-3986 (Entity::updateInternalsForNewPosition)
bool increaseX = (oldPosition.x < globalPosition_.x);
bool increaseZ = (oldPosition.z < globalPosition_.z);

// shuffle the leading triggers
for (Triggers::iterator it = triggers_.begin(); it != triggers_.end(); it++)
{
    (*it)->shuffleXThenZExpand( increaseX, increaseZ,
                                oldPosition.x, oldPosition.z );
}

// shuffle the entity
pRangeListNode_->shuffleXThenZ( oldPosition.x, oldPosition.z );

// shuffle the trailing triggers
for (Triggers::reverse_iterator it = triggers_.rbegin();
        it != triggers_.rend(); it++)
{
    (*it)->shuffleXThenZContract( increaseX, increaseZ,
                                    oldPosition.x, oldPosition.z );
}
```

#### 6.5.1 为什么 Expand/Contract 分开

考虑一个 AoI 触发器(范围 500m)向右移动:

- 上界触发器(x = entity.x + 500)需要**先**向右移动,捕捉新进入的实体(Enter 事件);
- 下界触发器(x = entity.x - 500)需要**后**向右移动,捕捉离开的实体(Leave 事件)。

如果先移动下界,会导致"AOI 范围整体左移",误判已经在范围内的实体"离开"。Expand/Contract 保证了:
- 先扩大新方向上的范围(捕捉进入);
- 再缩小旧方向上的范围(确认离开)。

```cpp
// range_trigger.cpp L588-601
void RangeTrigger::shuffleXThenZExpand( bool xInc, bool zInc,
        float oldX, float oldZ )
{
    RangeTriggerNode* xTrigger = xInc ? &upperBound_ : &lowerBound_;
    xTrigger->shuffleX( oldX + xTrigger->range(), oldZ + xTrigger->range() );
    RangeTriggerNode* zTrigger = zInc ? &upperBound_ : &lowerBound_;
    zTrigger->shuffleZ( oldX + zTrigger->range(), oldZ + zTrigger->range() );
}

void RangeTrigger::shuffleXThenZContract( bool xInc, bool zInc,
        float oldX, float oldZ )
{
    RangeTriggerNode* xTrigger = xInc ? &lowerBound_ : &upperBound_;
    xTrigger->shuffleX( oldX + xTrigger->range(), oldZ + xTrigger->range() );
    RangeTriggerNode* zTrigger = zInc ? & lowerBound_ : &upperBound_;
    zTrigger->shuffleZ( oldX + zTrigger->range(), oldZ + zTrigger->range() );
    oldEntityX_ = pCentralNode_->x();
    oldEntityZ_ = pCentralNode_->z();
}
```

#### 6.5.2 触发器排序:同 range 的限制

```cpp
// entity.cpp L3987 (注释)
// TODO: Even with this sorting this is broken if there is >1 trigger
// with the same range :(
```

Entity 的 `triggers_` 按 range 降序排列,这样大触发器先 shuffle。但如果两个触发器 range 相同,shuffle 顺序会出问题。这是已知的小缺陷。

### 6.6 Shuffle 的复杂度分析

设 Entity 移动距离为 D,链表中节点密度为 ρ(节点/米),则:
- 单次 shuffle 的 swap 次数 ≈ D × ρ;
- 每次 swap 是 O(1) 指针操作;
- 总复杂度 = O(D × ρ)。

对比四叉树的 O(log N) 移动:
- 当 D 小(正常移动)时,shuffle 几乎是 O(1);
- 当 D 大(传送)时,shuffle 可能 O(N)。

所以 BigWorld 对**传送**有特殊处理(见第十九节边界情况)。

---

## 七、RangeTrigger 触发器机制

### 7.1 RangeTrigger 类结构

```cpp
// range_trigger.hpp L64-229
class RangeTrigger
{
public:
    RangeTrigger( RangeListNode * pCentralNode, float range,
            RangeListNode::RangeListFlags wantsFlagsLower,
            RangeListNode::RangeListFlags wantsFlagsUpper,
            RangeListNode::RangeListFlags makesFlagsLower,
            RangeListNode::RangeListFlags makesFlagsUpper );
    virtual ~RangeTrigger();

    void insert();
    void remove();
    void removeWithoutContracting();

    void shuffleXThenZ( float oldX, float oldZ );
    void shuffleXThenZExpand( bool xInc, bool zInc, float oldX, float oldZ );
    void shuffleXThenZContract( bool xInc, bool zInc, float oldX, float oldZ );

    void setRange( float range );

    virtual BW::string debugString() const;

    virtual void triggerEnter( Entity & entity ) = 0;
    virtual void triggerLeave( Entity & entity ) = 0;
    virtual Entity * pEntity() const = 0;

    bool contains( RangeListNode * pQuery ) const;
    bool containsInZ( RangeListNode * pQuery ) const;

    RangeListNode * pCentralNode() const        { return pCentralNode_; }

    const RangeTriggerNode * pUpperTrigger() const      { return &upperBound_; }
    const RangeTriggerNode * pLowerTrigger() const      { return &lowerBound_; }

    bool wasInXRange( float x, float range ) const;
    bool isInXRange( float x, float range ) const;
    bool wasInZRange( float z, float range ) const;
    bool isInZRange( float z, float range ) const;
    // ... (还有 range/区间版本)
    ...

// protected:
public:
    RangeListNode *         pCentralNode_;

    RangeTriggerNode        upperBound_;
    RangeTriggerNode        lowerBound_;

    // Old location of the entity
    float                   oldEntityX_;
    float                   oldEntityZ_;
};
```

`RangeTrigger` 是抽象基类,持有:
- `pCentralNode_`:中心节点(通常是 Entity 的 RangeListNode);
- `upperBound_`/`lowerBound_`:两个触发器节点,分别在 ±range 处;
- `oldEntityX_`/`oldEntityZ_`:中心节点上一帧的位置。

### 7.2 双值检查:wasInXRange / isInXRange

这是 RangeTrigger 的核心方法,用于判断一个 Entity 在"移动前"或"移动后"是否在范围内:

```cpp
// range_trigger.hpp L98-122
bool wasInXRange( float x, float range ) const
{
    float subX = oldEntityX_;
    volatile float lowerBound = subX - range;
    volatile float upperBound = subX + range;
    return (lowerBound < x) && (x <= upperBound);
}

bool isInXRange( float x, float range ) const
{
    float subX = pCentralNode_->x();

    volatile float lowerBound = subX - range;
    volatile float upperBound = subX + range;

    return (lowerBound < x) && (x <= upperBound);
}
```

注意:
- `wasInXRange` 用 `oldEntityX_`(移动前位置);
- `isInXRange` 用 `pCentralNode_->x()`(移动后位置);
- 范围是 `(lowerBound, upperBound]`,**左开右闭**——这是一个重要的细节,用于防止边界震荡。

### 7.3 crossedXEntity:Entity 穿越的处理

当 RangeTriggerNode 在 shuffle 过程中与一个 EntityRangeListNode 穿越时,会调用 `crossedXEntity`:

```cpp
// range_trigger.cpp L170-206
void RangeTriggerNode::crossedXEntity( RangeListNode * pNode,
        bool positiveCrossing, float oldOthX, float oldOthZ )
{
    if (pNode == pRange_->pCentralNode()) return;  // 不响应自身的穿越

    // x is shuffled first so the old z position is checked.
    const bool wasInZ = pRange_->wasInZRange( oldOthZ, fabsf( oldRange_ ) );

    if (!wasInZ)
    {
        return;
    }

    Entity * pOtherEntity = EntityRangeListNode::getEntity( pNode );

    const bool isEntering = (this->isLowerBound() == positiveCrossing);

    if (isEntering)
    {
        const bool isInX = pRange_->isInXRange( pNode->x(), fabsf( range_ ) );
        const bool isInZ = pRange_->isInZRange( pNode->z(), fabsf( range_ ) );

        if (isInX && isInZ)
        {
            pRange_->triggerEnter( *pOtherEntity );
        }
    }
    else
    {
        const bool wasInX = pRange_->wasInXRange( oldOthX, fabsf( oldRange_ ) );

        if (wasInX)
        {
            pRange_->triggerLeave( *pOtherEntity );
        }
    }
}
```

#### 7.3.1 算法步骤

1. **过滤自身**:不响应与中心节点本身的穿越;
2. **Z 范围预检**:用 `oldOthZ` 检查 Z 是否在范围内,如果不在直接返回;
3. **判断方向**:`isEntering = (isLowerBound == positiveCrossing)`
   - 如果是下界触发器被正向穿越(从左到右),意味着 Entity 进入了下界,即进入 AOI;
   - 如果是上界触发器被反向穿越(从右到左),也意味着 Entity 进入了上界,即进入 AOI;
4. **如果是进入**:用当前位置(`isInX/isInZ`)做最终判定,只有 X 和 Z 都在范围内才 triggerEnter;
5. **如果是离开**:用旧位置(`wasInX`)判定,只有之前确实在范围内才 triggerLeave。

#### 7.3.2 X 与 Z 的非对称检查

注意一个微妙的不对称:
- X shuffle 时,用 `oldOthZ`(Z 还没动)预检 Z;
- Z shuffle 时,用 `pNode->x()`(X 已经稳定)检查 X。

```cpp
// range_trigger.cpp L303-339 (crossedZEntity)
void RangeTriggerNode::crossedZEntity( RangeListNode * pNode,
        bool positiveCrossing, float oldOthX, float oldOthZ )
{
    if (pNode == pRange_->pCentralNode()) return;

    // z is shuffled second so the new x position is checked.
    const bool isInX = pRange_->isInXRange( pNode->x(), fabsf( range_ ) );

    if (!isInX)
    {
        return;
    }
    ...
}
```

这种非对称保证了:
- X shuffle 期间,触发的 enter/leave 事件用"移动前的 Z 状态";
- Z shuffle 期间,用"移动后的 X 状态"。

这避免了在 X 移动时误判 Z(因为 Z 还没动)。

### 7.4 crossedXEntityRange:与 AppealTrigger 的穿越

当 RangeTrigger 与另一个 RangeTrigger(如 AppealTrigger)穿越时,处理略复杂——需要检查两个触发器的范围是否重叠:

```cpp
// range_trigger.cpp L213-266
void RangeTriggerNode::crossedXEntityRange( RangeListNode * pNode,
        bool positiveCrossing )
{
    RangeTriggerNode * pOtherNode = static_cast< RangeTriggerNode * >( pNode );
    const RangeTrigger & otherRangeTrigger = pOtherNode->rangeTrigger();

    RangeTrigger & thisRangeTrigger = *pRange_;

    // x is shuffled first so the old z position is checked.
    const bool wasInZ =
        thisRangeTrigger.wasInZRange(
                otherRangeTrigger.pLowerTrigger()->oldZ(),
                otherRangeTrigger.pUpperTrigger()->oldZ(),
                fabsf( oldRange_ ) );

    if (!wasInZ)
    {
        return;
    }
    ...
}
```

这里用到了 `wasInZRange` 的区间版本(传入两个 Z 值,判断区间是否相交):

```cpp
// range_trigger.hpp L182-193
bool wasInZRange( float entityLower, float entityUpper, float range ) const
{
    float subZ = oldEntityZ_;
    volatile float lowerBound = subZ - range;
    volatile float upperBound = subZ + range;
    return (lowerBound <= entityUpper) && (entityLower <= upperBound);
}
```

### 7.5 triggerEnter / triggerLeave 的虚函数

`RangeTrigger` 把 `triggerEnter` 和 `triggerLeave` 留给子类实现:

```cpp
// range_trigger.hpp L86-87
virtual void triggerEnter( Entity & entity ) = 0;
virtual void triggerLeave( Entity & entity ) = 0;
```

不同的子类有不同的实现:
- **AoITrigger**:调用 `Witness::addToAoI/removeFromAoI`;
- **VisionRangeTrigger**:调用 `EntityVision::triggerVisionEnter/Leave`;
- **ProximityRangeTrigger**:调用脚本的 `onEnterTrap/onLeaveTrap`;
- **RangeListAppealTrigger**:空实现(它只负责"被发现",不主动触发)。

### 7.6 触发器的 insert:从零开始扩展

```cpp
// range_trigger.cpp L464-534
void RangeTrigger::insert()
{
    /*
    pCentralNode_->insertBeforeX( &lowerBound_ );
    ...
    */
    // The code above does not work in the following case:
    // 1. the range of the trigger is less than the floating pt epsilon
    // 2. there is >1 entity type node at the same posn as pCentralNode
    // ...

    uint16 lowerOrder = lowerBound_.order();
    uint16 upperOrder = upperBound_.order();

    MF_ASSERT(
        lowerOrder < upperOrder &&
        lowerOrder > pCentralNode_->order() &&
        upperOrder > pCentralNode_->order() );

    RangeListNode * pCursor = pCentralNode_->nextX();

    while (isEqual( pCursor->x(), pCentralNode_->x() ) &&
        (pCursor->order() < upperOrder))
    {
        pCursor = pCursor->nextX();
    }
    pCursor->insertBeforeX( &lowerBound_ );
    pCursor->insertBeforeX( &upperBound_ );

    pCursor = pCentralNode_->nextZ();

    while (isEqual( pCursor->z(), pCentralNode_->z() ) &&
        (pCursor->order() < upperOrder))
    {
        pCursor = pCursor->nextZ();
    }
    pCursor->insertBeforeZ( &lowerBound_ );
    pCursor->insertBeforeZ( &upperBound_ );

    oldEntityX_ = pCentralNode_->x();
    oldEntityZ_ = pCentralNode_->z();

    // now perform the initial shuffle from this location
    upperBound_.oldRange( 0.f );
    lowerBound_.oldRange( 0.f );

    upperBound_.shuffleX( oldEntityX_, oldEntityZ_ );
    lowerBound_.shuffleX( oldEntityX_, oldEntityZ_ );

    upperBound_.shuffleZ( oldEntityX_, oldEntityZ_ );
    lowerBound_.shuffleZ( oldEntityX_, oldEntityZ_ );

    upperBound_.updateOldRange();
    lowerBound_.updateOldRange();
}
```

#### 7.6.1 算法步骤

1. **跳过同位置的 Entity 节点**:从 `pCentralNode_->nextX()` 开始,跳过所有 `x` 相同且 `order` 小于 `upperOrder` 的节点。这是为了避免与同位置 Entity 的"虚假穿越";
2. **插入两个触发器节点**:在跳过位置之前插入下界和上界;
3. **同样处理 Z 链**;
4. **设置初始 oldRange = 0**:这样 shuffle 时认为触发器从"零范围"扩展到"全范围",会触发与范围内所有 Entity 的 enter 事件;
5. **执行 shuffle**:让触发器飘到正确位置,在飘动过程中触发 enter。

#### 7.6.2 为什么不直接放在 pCentralNode 旁边

注释解释了:
> The code above does not work in the following case:
> 1. the range of the trigger is less than the floating pt epsilon
> 2. there is >1 entity type node at the same posn as pCentralNode

如果直接放在 `pCentralNode` 旁边,当有多个同坐标的 Entity 时,初始 shuffle 可能产生"虚假 leave"事件(因为同坐标的 Entity 在链表中可能被分到不同位置)。

通过先跳过同坐标 Entity,再插入触发器,可以保证初始 shuffle 时只触发 enter,不触发 leave。

### 7.7 触发器的 remove:从全范围收缩到零

```cpp
// range_trigger.cpp L541-550
void RangeTrigger::remove()
{
    float our = upperBound_.range();
    float olr = lowerBound_.range();
    upperBound_.setRange( 0 );
    lowerBound_.setRange( 0 );
    this->removeWithoutContracting();
    upperBound_.range( our );
    lowerBound_.range( olr );
}
```

删除时:
1. 先把上下界范围都设为 0,这会触发 shuffle,产生"收缩"过程;
2. 在收缩过程中,所有原本在范围内的 Entity 会触发 leave 事件;
3. 然后从链表中移除节点;
4. 恢复 range(可能是为了后续重新插入)。

### 7.8 setRange:动态调整范围

```cpp
// range_trigger.cpp L408-416 (RangeTriggerNode::setRange)
void RangeTriggerNode::setRange( float range )
{
    oldRange_ = range_;
    float oldX = this->x();
    float oldZ = this->z();
    range_ = range;
    this->shuffleXThenZ( oldX, oldZ );
    oldRange_ = range_;
}

// range_trigger.cpp L632-639 (RangeTrigger::setRange)
void RangeTrigger::setRange( float range )
{
    float r = range;
    if (r < 0.001f) r = 0.001f;

    upperBound_.setRange(  r );
    lowerBound_.setRange( -r );
}
```

调整范围时:
1. 保存 `oldRange_`,记下"调整前的位置";
2. 修改 `range_`,触发 shuffle;
3. shuffle 过程中,`oldRange_` 用于判断"之前是否在范围内";
4. shuffle 后,更新 `oldRange_ = range_`。

注意:`RangeTrigger::setRange` 钳制了最小范围 0.001,避免零范围导致的各种边界问题。

### 7.9 contains:点是否在触发器内

```cpp
// range_trigger.cpp L655-674
bool RangeTrigger::contains( RangeListNode * pQuery ) const
{
    float qx = pQuery->x();
    float qz = pQuery->z();
    uint16 qo = pQuery->order();

    float lx = lowerBound_.x();
    float lz = lowerBound_.z();
    uint16 lo = lowerBound_.order();

    float ux = upperBound_.x();
    float uz = upperBound_.z();
    uint16 uo = upperBound_.order();

    return
        (lx < qx || (isEqual( lx, qx ) && lo < qo)) &&
        (qx < ux || (isEqual( qx, ux ) && qo < uo)) &&
        (lz < qz || (isEqual( lz, qz ) && lo < qo)) &&
        (qz < uz || (isEqual( qz, uz ) && qo < uo));
}
```

这是用于**点查询**(如 `visitLargeEntities`),不依赖 shuffle 事件。注意它考虑了 `order_` 的细节,保证与 shuffle 一致性。

---

## 八、滞回防抖机制深度剖析

### 8.1 边界震荡问题

考虑以下场景:
- Entity A 在 AoI 边界附近(距离 = aoiRadius);
- 由于浮点误差或微小移动,A 可能反复"进入"和"离开" AoI;
- 每次进入触发 enterAoI 消息,每次离开触发 leaveAoI 消息;
- 客户端反复创建/销毁实体,导致**视觉闪烁**和**带宽浪费**。

```
距离:    ──────[ enter ]──[ leave ]──[ enter ]──[ leave ]──[ enter ]──►
         边界:    aoiRadius
A 的位置: ──────────●─────────●─────────●─────────●─────────●─►
```

### 8.2 滞回(Hysteresis)的原理

滞回的核心思想是:**进入和离开使用不同的阈值**。

```
距离:    ──────[ enter @ aoiRadius ]──────────────[ leave @ aoiRadius + hyst ]──►
                                  A 的位置范围
         ┌────────────────────────────────────────┐
         │  进入阈值                              │
         │  离开阈值                              │
         │  两者之间:维持当前状态(不触发事件)   │
         └────────────────────────────────────────┘
```

- 进入 AOI:必须**距离 < aoiRadius**;
- 离开 AOI:必须**距离 > aoiRadius + hysteresis**;
- 在 [aoiRadius, aoiRadius + hysteresis] 之间:状态不变。

### 8.3 BigWorld 的滞回实现

BigWorld 的滞回不是通过简单的"双阈值"实现的,而是通过**两个独立的触发器**:
- **AoI Trigger**(range = aoiRadius):负责进入;
- **AoI Hyst Trigger**(range = aoiRadius + aoiHyst):负责离开。

但实际上,BigWorld 的实现更精妙:它只有**一个 AoI 触发器**,但通过"在离开时检查是否仍在 hyst 范围内"来实现滞回。具体来看:

```cpp
// witness.hpp L280-282
float aoiHyst_;
float aoiRadius_;
RangeListNode * pAoIRoot_;
```

```cpp
// witness.cpp L2113-2116
aoiHyst_      = hyst;
aoiRadius_    = radius;
```

但实际上,BigWorld 14.4.1 中 `aoiHyst_` 的使用非常有限——它主要影响 `setAoIRadius` 时的行为,而真正的"防抖"是通过 **RangeListNode 的左开右闭区间** 实现的。

### 8.4 左开右闭区间的防抖作用

回顾 `isInXRange`:
```cpp
return (lowerBound < x) && (x <= upperBound);
```

注意:
- 下界是**开区间**(`<`);
- 上界是**闭区间**(`<=`)。

这意味着:
- 当 Entity 的 X 严格等于下界时,**不算在范围内**(下界开);
- 当 Entity 的 X 严格等于上界时,**算在范围内**(上界闭)。

这种不对称确保了**在边界上不会反复触发**:边界本身被"决定性地"分配给一侧。

### 8.5 wasInXRange / isInXRange 的滞回作用

真正的防抖来自"移动前 wasIn / 移动后 isIn"的双重检查:

考虑 Entity 从 AoI 内移动到 AoI 外(沿 X 正方向):

1. Entity X 从 `entityX - 100`(范围内)移动到 `entityX + 600`(范围外);
2. AoI 上界触发器(在 `entityX + 500`)与 Entity 在 shuffle 过程中穿越;
3. `crossedXEntity` 被调用,`positiveCrossing = true`(Entity 从触发器左侧到右侧);
4. 判断 `isEntering = (isLowerBound == positiveCrossing)`,上界触发器 `isLowerBound = false`,`isEntering = false`(这是离开事件);
5. 检查 `wasInX = wasInXRange(oldOthX)`,`oldOthX = entityX - 100`,在范围内,所以触发 `triggerLeave`。

反向(从外到内):

1. Entity X 从 `entityX + 600` 移动到 `entityX - 100`;
2. 与上界触发器穿越时,`positiveCrossing = false`;
3. `isEntering = (false == false) = true`(进入事件);
4. 检查 `isInX = isInXRange(pNode->x()) = isInXRange(entityX - 100) = true`,触发 `triggerEnter`。

注意关键点:**进入和离开使用不同的判定位置**——进入用"新位置",离开用"旧位置"。这就是 BigWorld 的滞回机制。

### 8.6 边界震荡的避免

假设 Entity 在边界附近来回移动 ±0.5 米:

```
位置:    ─────[范围]───► 500.0 ──── 500.5 ──── 500.0 ──── 499.5 ──── 500.0 ────►
状态:                  在内     在外     在内     在外     在内
```

如果只用单值检查,会反复触发 enter/leave。但 BigWorld 的"wasIn/isIn 双检查"机制:
- 第一次穿越(从内到外):oldX 在内,新 X 在外 → triggerLeave;
- 第二次穿越(从外到内):oldX 在外,新 X 在内 → triggerEnter;
- ...

实际上,**单步移动如果跨越边界,确实会触发**。BigWorld 真正的防抖在于:
- 浮点比较的左开右闭保证了边界点的归属是确定的;
- 一次 tick 内 Entity 通常只移动很小距离,不会反复跨越;
- AoI 半径 500m 远大于典型移动距离(每 tick 0.5m),所以震荡概率极低。

### 8.7 aoiHyst 的真实作用

`aoiHyst` 在 14.4.1 中的实际用途:
1. **状态保存**:Witness offload 时,序列化 `aoiHyst_`;
2. **API 一致性**:保持与历史版本的兼容;
3. **未来扩展**:为更复杂的滞回预留接口。

在 `setAoIRadius` 时,`aoiHyst_` 被一起设置(`witness.cpp` L2113-2116),但 `pAoITrigger_->setRange(aoiRadius_)` 只用 `aoiRadius_`,**不用 `aoiRadius_ + aoiHyst_`**。

这意味着 14.4.1 的实际滞回主要靠**浮点比较的左开右闭**和**wasIn/isIn 双检查**实现,而不是显式的"双阈值"。

### 8.8 防抖的工程价值

即使没有显式的双阈值,BigWorld 的防抖设计仍然优秀:
- **浮点一致性**:volatile 强制 32 位精度,避免扩展精度导致的不一致;
- **左开右闭**:边界归属明确;
- **wasIn/isIn 双检查**:防止"穿越瞬间的误判";
- **order 字段**:同坐标时顺序确定,避免随机震荡。

这些细节加在一起,使得 BigWorld 在实际 MMOG 运营中很少出现 AOI 震荡问题。

---

## 九、AoIUpdateScheme 更新策略

### 9.1 问题:远近实体的差异化

即使一个实体在 AoI 内,也不应该每 tick 都发送它的更新——远距离的实体可以低频更新,近距离的实体需要高频更新。这就是 AoIUpdateScheme 的作用。

### 9.2 AoIUpdateScheme 类

```cpp
// aoi_update_schemes.hpp L18-54
class AoIUpdateScheme
{
public:
    AoIUpdateScheme();
    bool init( const BW::string & name, float minDelta, float maxDelta );

    bool shouldTreatAsCoincident() const
    {
        return isZero( weighting_ ) && isZero( distanceWeighting_ );
    }

    double apply( float distanceSquared ) const
    {
        if (this->shouldTreatAsCoincident())
        {
            return 1.0;
        }

        const float distance = sqrtf( distanceSquared );
        return (distance * distanceWeighting_ + 1.f) * weighting_;
    }

private:
    float weighting_;
    float distanceWeighting_;
};
```

#### 9.2.1 核心公式

`apply(distanceSquared)` 返回一个"优先级增量"(priority delta):
```
delta = (distance × distanceWeighting + 1) × weighting
```

参数解释:
- `weighting`:基础增量(近距离时的增量);
- `distanceWeighting`:距离影响因子;
- 当 `distance = 0`(同位置)时,`delta = weighting`;
- 当 `distance = maxAoIRadius`(500m)时,`delta = (500 × distanceWeighting + 1) × weighting`。

#### 9.2.2 参数推导

```cpp
// aoi_update_schemes.cpp L60-67
weighting_ = minDelta;
distanceWeighting_ = ((maxDelta / minDelta) - 1.f) /
    CellAppConfig::maxAoIRadius();
```

代入:
- `weighting = minDelta`(0 米时的增量);
- `distanceWeighting = (maxDelta/minDelta - 1) / maxAoIRadius`;
- 当 `distance = maxAoIRadius` 时,`delta = (maxDelta/minDelta - 1 + 1) × minDelta = maxDelta`。

所以:
- **0 米**:delta = minDelta(最快更新);
- **maxAoIRadius 米**:delta = maxDelta(最慢更新)。

#### 9.2.3 默认值

```cpp
// cellapp_config.cpp L82-83
BW_OPTION( float, witnessUpdateDefaultMinDelta, 1.f );
BW_OPTION( float, witnessUpdateDefaultMaxDelta, 101.f );
```

默认:
- 0 米:delta = 1;
- 500 米:delta = 101。

意味着 500 米远的实体,优先级增量是 0 米的 101 倍——即近距离实体的更新频率是远距离的 101 倍。

### 9.3 shouldTreatAsCoincident:特殊方案

```cpp
bool shouldTreatAsCoincident() const
{
    return isZero( weighting_ ) && isZero( distanceWeighting_ );
}
```

当 `minDelta = maxDelta = 0` 时,这个方案"被当作同位置处理":
- `apply` 返回 1.0(固定增量);
- `getLoDPriority` 返回 0.0(假装距离为 0)。

这意味着使用此方案的实体会被以"最近距离"的优先级发送,适合关键 NPC、玩家自己等。

### 9.4 AoIUpdateSchemes:多策略管理

```cpp
// aoi_update_schemes.hpp L60-94
class AoIUpdateSchemes
{
public:
    typedef AoIUpdateSchemeID SchemeID;

    static bool shouldTreatAsCoincident( SchemeID scheme );
    static double apply( SchemeID scheme, float distance );
    static bool init();

    static bool getNameFromID( SchemeID id, BW::string & name );
    static bool getIDFromName( const BW::string & name, SchemeID & rID );

private:
    static AoIUpdateScheme schemes_[ 256 ];  // 最多 256 个方案
    static NameToSchemeMap nameToScheme_;
    static SchemeToNameMap schemeToName_;
};
```

特点:
- 静态数组 `schemes_[256]`,通过 ID 直接索引(O(1));
- 双向 map 维护 name ↔ ID;
- ID 0 是默认方案,名为 "default" 或空字符串;
- 自定义方案从 ID 1 开始。

### 9.5 方案初始化

```cpp
// aoi_update_schemes.cpp L90-193
bool AoIUpdateSchemes::init()
{
    const float DEFAULT_AOI_SCHEME_MIN_DELTA =
        CellAppConfig::witnessUpdateDefaultMinDelta();
    const float DEFAULT_AOI_SCHEME_MAX_DELTA =
        CellAppConfig::witnessUpdateDefaultMaxDelta();
    // Add the default scheme, aliased to empty string and "default".
    schemes_[ 0 ].init( "default", DEFAULT_AOI_SCHEME_MIN_DELTA,
        DEFAULT_AOI_SCHEME_MAX_DELTA );

    nameToScheme_[ "" ] = 0;
    nameToScheme_[ "default" ] = 0;
    schemeToName_[ 0 ] = "default";

    DataSectionPtr pTopSection =
        BWConfig::getSection( "cellApp/aoiUpdateSchemes" );

    DataSectionIterator iter = pTopSection->begin();

    SchemeID currSchemeID = 1;

    while ((iter != pTopSection->end()) && (currSchemeID != 0))
    {
        DataSectionPtr pSection = *iter;
        if (pSection->sectionName() == "scheme")
        {
            const BW::string name = pSection->readString( "name" );
            const float minDelta = pSection->readFloat( "minDelta",
                DEFAULT_AOI_SCHEME_MIN_DELTA );
            const float maxDelta = pSection->readFloat( "maxDelta",
                DEFAULT_AOI_SCHEME_MAX_DELTA );
            ...
            schemes_[ currSchemeID ].init( name, minDelta, maxDelta );
            nameToScheme_[ name ] = currSchemeID;
            schemeToName_[ currSchemeID ] = name;
            ++currSchemeID;
        }
        ...
    }
    ...
}
```

#### 9.5.1 bw.xml 配置示例

```xml
<cellApp>
    <aoiUpdateSchemes>
        <scheme>
            <name>sniper</name>
            <minDelta>0.5</minDelta>
            <maxDelta>50</maxDelta>
        </scheme>
        <scheme>
            <name>stealth</name>
            <minDelta>0</minDelta>
            <maxDelta>0</maxDelta>  <!-- shouldTreatAsCoincident -->
        </scheme>
    </aoiUpdateSchemes>
</cellApp>
```

### 9.6 方案的运行时绑定

每个 EntityCache 持有一个 `updateSchemeID_`,决定该实体使用哪个方案:

```cpp
// entity_cache.hpp L98-99
AoIUpdateSchemeID updateSchemeID() const { return updateSchemeID_; }
void updateSchemeID( AoIUpdateSchemeID id ) { updateSchemeID_ = id; }
```

Entity 自身也有一个 `aoiUpdateSchemeID_`,作为"该实体被加入 AoI 时使用的默认方案":

```cpp
// entity.hpp L230
AoIUpdateSchemeID aoiUpdateSchemeID() const    { return aoiUpdateSchemeID_; }
```

通过 `Entity.setAoIUpdateScheme(otherEntity, "sniper")` 可以动态调整:

```cpp
// witness.cpp L3514-3536
bool Witness::setAoIUpdateScheme( PyObjectPtr pEntityOrID,
        BW::string schemeName )
{
    EntityCache * pCache = this->findEntityCacheFromPyArg( pEntityOrID.get() );
    if (pCache == NULL) return false;

    AoIUpdateSchemeID id;
    if (!AoIUpdateSchemes::getIDFromName( schemeName, id ))
    {
        PyErr_Format( PyExc_ValueError,
                "Invalid scheme name '%s'", schemeName.c_str() );
        return false;
    }

    pCache->updateSchemeID( id );
    return true;
}
```

### 9.7 优先级计算

```cpp
// entity_cache.ipp L106-140
INLINE void EntityCache::updatePriority( const Vector3 & origin )
{
    float distSQ = this->getDistanceSquared( origin );

    Priority delta = AoIUpdateSchemes::apply( updateSchemeID_, distSQ );

    // Limit the delta increase to a fraction of the previous delta to avoid
    // client's avatar filter starvation caused by rapid priority changes due
    // to AoI update scheme change.
    const double deltaGrowthThrottle =
        CellAppConfig::witnessUpdateDeltaGrowthThrottle();
    delta = std::min( delta, deltaGrowthThrottle * lastPriorityDelta_ );
    lastPriorityDelta_ = delta;

    priority_ += delta;
}
```

#### 9.7.1 优先级累加机制

注意 `priority_ += delta`——**优先级是累加的**!每次 update 时,实体的优先级会增加一个 delta。当 EntityCache 被 `Witness::update` 处理(发送数据)后,优先级会被重置或调整。

这意味着:
- 长时间没被发送的实体,优先级会越来越高;
- 近距离实体(delta 小)优先级增长慢,但因为 Witness 的"maxPriorityDelta"机制,它们会被更频繁地发送;
- 远距离实体(delta 大)优先级增长快,但发送后会重置。

#### 9.7.2 deltaGrowthThrottle:防止优先级暴涨

```cpp
const double deltaGrowthThrottle =
    CellAppConfig::witnessUpdateDeltaGrowthThrottle();
delta = std::min( delta, deltaGrowthThrottle * lastPriorityDelta_ );
```

默认 `witnessUpdateDeltaGrowthThrottle = 1.125`,即 delta 单次增长不能超过上次的 12.5%。这防止了 AoI 方案变更时(如从远距离突然切到近距离)优先级暴涨导致客户端"过滤饥饿"。

---

## 十、Witness 系统详解

### 10.1 Witness 的本质

```cpp
// witness.hpp L26
class Witness : public Updatable
```

Witness 是 RealEntity 的"眼睛"——它代表一个客户端对该实体的"视角"。当一个 Entity 被客户端控制(成为 player)时,会创建 Witness。

**关键澄清**:`Witness` 持有 `RealEntity &` 和 `Entity &`,而 `RealEntity` 持有 `Witness *`。也就是说:
- 只有 Real 才能有 Witness(Ghost 不行);
- 一个 Real 最多有一个 Witness;
- Witness 创建后,RealEntity 就"代表"了某个客户端。

### 10.2 Witness 的成员变量

```cpp
// witness.hpp L263-318 (摘要)
RealEntity      & real_;
Entity          & entity_;

GameTime        noiseCheckTime_;
GameTime        noisePropagatedTime_;
bool            noiseMade_;

int32           maxPacketSize_;            // 每 tick 最大包大小

KnownEntityQueue    entityQueue_;         // 优先级堆
EntityCacheMap      aoiMap_;              // AoI 实体映射
bool                shouldAddReplayAoIUpdates_;

float stealthFactor_;                     // 隐身因子

float aoiHyst_;                           // 滞回距离
float aoiRadius_;                         // AoI 半径
RangeListNode * pAoIRoot_;                // AoI 根节点

int32 bandwidthDeficit_;                   // 带宽赤字

IDAlias freeAliases_[ 256 ];              // 空闲 IDAlias 池
int     numFreeAliases_;                  // 空闲数量

#if !VOLATILE_POSITIONS_ARE_ABSOLUTE
Vector3 referencePosition_;                // 参考位置(用于相对坐标)
uint8   referenceSeqNum_;
bool hasReferencePosition_;
#endif

int32 knownSpaceDataSeq_;                  // 客户端已知的 SpaceData 序列号
uint32 allSpacesDataChangeSeq_;

AoITrigger * pAoITrigger_;                  // AoI 触发器

GameTime    lastSentReliableGameTime_;
Position3D  lastSentReliablePosition_;
Direction3D lastSentReliableDirection_;
```

### 10.3 Witness 的创建

```cpp
// witness.cpp L124-234
Witness::Witness( RealEntity & owner, BinaryIStream & data,
    CreateRealInfo createRealInfo, bool hasChangedSpace ) :
    real_( owner ),
    entity_( owner.entity() ),
    noiseCheckTime_( CellApp::instance().time() ),
    noisePropagatedTime_( CellApp::instance().time() ),
    noiseMade_( false ),
    maxPacketSize_( 0 ),
    entityQueue_(),
    aoiMap_(),
    shouldAddReplayAoIUpdates_( false ),
    stealthFactor_( 0.f ),
    aoiHyst_( 5.0 ),
    aoiRadius_( CellAppConfig::defaultAoIRadius() ),
    pAoIRoot_( entity_.pRangeListNode() ),
    bandwidthDeficit_( 0 ),
    numFreeAliases_( 0 ),
    ...
{
    ++g_numWitnesses;
    ++g_numWitnessesEver;

    // In the freeAliases_ array, we want the first numFreeAliases_ to contain
    // the free aliases. ...
    memset( freeAliases_, 1, sizeof( freeAliases_ ) );

    this->readOffloadData( data, createRealInfo, hasChangedSpace );

    // Make sure that this NO_ID_ALIAS is reserved
    freeAliases_[ NO_ID_ALIAS ] = 0;

    for (uint i = 0; i < sizeof( freeAliases_ ); i++)
    {
        int temp = freeAliases_[i];
        freeAliases_[ numFreeAliases_ ] = i;
        numFreeAliases_ += temp;
    }

    CellApp::instance().registerWitness( this );

    // Tell the proxy what is the tickSync for the first message.
    BaseAppIntInterface::tickSyncArgs::
        start( this->bundle() ).tickByte = ...;

    this->init();

    if (createRealInfo == CREATE_REAL_FROM_INIT)
    {
        // send a special createPlayer message to the client
        Mercury::Bundle & bundle = this->bundle();
        bundle.startMessage( BaseAppIntInterface::createCellPlayer );
        ...
    }

    shouldAddReplayAoIUpdates_ = true;
}
```

#### 10.3.1 创建流程

1. **初始化成员**:aoiRadius 来自 `defaultAoIRadius`(默认 500),aoiHyst 默认 5.0;
2. **填充 freeAliases_**:用 memset(1) 填充,然后排除 NO_ID_ALIAS,把空闲 ID 收集到数组前部;
3. **readOffloadData**:如果是 offload 来的,从流中读取 AoI 状态;
4. **registerWitness**:向 CellApp 注册;
5. **init**:创建 AoITrigger,处理 offload 时的 AoI 恢复;
6. **createCellPlayer**:如果是新创建的玩家,发送 createCellPlayer 消息给客户端。

### 10.4 init:创建 AoI 触发器

```cpp
// witness.cpp L526-599
void Witness::init()
{
    Entity::callbacksPermitted( false );

    // Create AoI triggers around ourself.
    {
        SCOPED_PROFILE( SHUFFLE_AOI_TRIGGERS_PROFILE );
        pAoITrigger_ = new AoITrigger( *this, pAoIRoot_, aoiRadius_ );
        if (this->isAoIRooted())
        {
            MobileRangeListNode * pRoot =
                static_cast< MobileRangeListNode * >( pAoIRoot_ );
            pRoot->addTrigger( pAoITrigger_ );
        }
        else
        {
            entity().addTrigger( pAoITrigger_ );
        }
    }

    Entity::callbacksPermitted( true );

    KnownEntityQueue::size_type i = 0;

    // Sort out entities that didn't make it back into our AoI.
    while (i < entityQueue_.size())
    {
        // ... 处理 offload 时 isInAoIOffload 的实体
    }

    // And finally make the entity queue into a heap.
    std::make_heap( entityQueue_.begin(), entityQueue_.end(), PriorityCompare() );
}
```

#### 10.4.1 AoITrigger 的创建

`AoITrigger` 是 Witness 内嵌的私有类:

```cpp
// witness.cpp L73-106
class AoITrigger : public RangeTrigger
{
public:
    AoITrigger( Witness & owner, RangeListNode * pCentralNode, float range ) :
        RangeTrigger( pCentralNode, range,
                RangeListNode::FLAG_LOWER_AOI_TRIGGER,    // wantsLower
                RangeListNode::FLAG_UPPER_AOI_TRIGGER,    // wantsUpper
                RangeListNode::FLAG_NO_TRIGGERS,           // makesLower
                RangeListNode::FLAG_NO_TRIGGERS ),         // makesUpper
        owner_( owner )
    {
        // Collect the large entities whose range we currently sit.
        owner_.entity().space().visitLargeEntities(
            pCentralNode->x(),
            pCentralNode->z(),
            *this );

        this->insert();
    }

    ~AoITrigger()
    {
        this->removeWithoutContracting();
    }

    virtual BW::string debugString() const;

    virtual void triggerEnter( Entity & entity );
    virtual void triggerLeave( Entity & entity );
    virtual Entity * pEntity() const { return &owner_.entity(); }

private:
    Witness & owner_;
};
```

#### 10.4.2 触发器的 wantsFlags 配置

注意 AoITrigger 的 `wantsFlags`:
- `wantsFlagsLower = FLAG_LOWER_AOI_TRIGGER`(关心下界 AoI 触发);
- `wantsFlagsUpper = FLAG_UPPER_AOI_TRIGGER`(关心上界 AoI 触发);
- `makesFlags = FLAG_NO_TRIGGERS`(不产生任何触发事件,即"我是被动的")。

这意味着 AoITrigger 只接收事件,不主动触发别人的事件——避免 AoITrigger 之间的相互触发。

#### 10.4.3 visitLargeEntities:初始可见的大型实体

构造时调用 `visitLargeEntities`,把所有 AppealRadius 触发器包含 AoI 中心点的实体加入 AoI。这处理了"Witness 创建时已经在大型实体范围内"的情况。

### 10.5 AoITrigger::triggerEnter / triggerLeave

```cpp
// witness.cpp L3586-3609
void AoITrigger::triggerEnter( Entity & entity )
{
    if ((&entity != &owner_.entity()) &&
            !entity.pType()->description().isManualAoI())
    {
        owner_.addToAoI( &entity, /* setManuallyAdded */ false );
    }
}

void AoITrigger::triggerLeave( Entity & entity )
{
    if ((&entity != &owner_.entity()) &&
            (!entity.pType()->description().isManualAoI()))
    {
        owner_.removeFromAoI( &entity, /* clearManuallyAdded */ false );
    }
}
```

注意:
- 排除自己(不会把 Witness 自己加入自己的 AoI);
- 排除 ManualAoI 类型实体(它们由脚本控制,不响应自动触发)。

### 10.6 Witness 的销毁

```cpp
// witness.cpp L605-645
Witness::~Witness()
{
    --g_numWitnesses;

    MF_VERIFY( CellApp::instance().deregisterWitness( this ) );

    // Delete any entity caches not in the aoiMap
    KnownEntityQueue::iterator iter = entityQueue_.begin();
    while (iter != entityQueue_.end())
    {
        if (!(*iter)->pEntity()) delete *iter;
        iter++;
    }

    Entity::callbacksPermitted( false );

    if (this->isAoIRooted())
    {
        MobileRangeListNode * pRoot =
            static_cast< MobileRangeListNode * >( pAoIRoot_ );
        pRoot->delTrigger( pAoITrigger_ );
    }
    else
    {
        this->entity().delTrigger( pAoITrigger_ );
    }

    bw_safe_delete( pAoITrigger_ );

    if (this->isAoIRooted())
    {
        static_cast< MobileRangeListNode * >( pAoIRoot_ )->remove();
        bw_safe_delete( pAoIRoot_ );
    }

    Entity::callbacksPermitted( true );

    // The aoiMap will delete all its nodes itself
}
```

销毁流程:
1. 注销 Witness;
2. 删除孤立的 EntityCache(pEntity 已 NULL);
3. 从 Entity/MobileRangeListNode 上移除触发器;
4. 删除 AoITrigger(注意 `~AoITrigger()` 用 `removeWithoutContracting`,不触发 leave 事件);
5. 如果是 rooted,删除 MobileRangeListNode。

### 10.7 AoIRoot:独立 AoI 中心

```cpp
// witness.cpp L1439-1472
void Witness::setAoIRoot( float x, float z )
{
    if (this->isAoIRooted())
    {
        SCOPED_PROFILE( SHUFFLE_AOI_TRIGGERS_PROFILE );
        static_cast< MobileRangeListNode * >( pAoIRoot_ )->setPosition( x, z );
        return;
    }

    RangeListNode * pNewAoIRoot = new MobileRangeListNode( x, z,
        RangeListNode::FLAG_NO_TRIGGERS,
        RangeListNode::FLAG_NO_TRIGGERS );

    Entity::callbacksPermitted( false );

    const_cast< RangeList & >( entity().space().rangeList() ).add( pNewAoIRoot );

    Entity::callbacksPermitted( true );

    RangeListNode * pOldAoIRoot = this->replaceAoITrigger( pNewAoIRoot );

    MF_ASSERT( pOldAoIRoot == entity().pRangeListNode() );
    MF_ASSERT( this->isAoIRooted() );
}
```

#### 10.7.1 isAoIRooted 判定

```cpp
// witness.cpp L1430-1433
bool Witness::isAoIRooted() const
{
    return pAoIRoot_ != entity_.pRangeListNode();
}
```

如果 `pAoIRoot_` 是 Entity 自身的 RangeListNode,说明 AoI 跟着 Entity 走;否则是独立的 MobileRangeListNode。

#### 10.7.2 replaceAoITrigger:无缝切换 AoI 根

```cpp
// witness.cpp L1783-1841
RangeListNode * Witness::replaceAoITrigger( RangeListNode * pNewAoIRoot )
{
    Entity::callbacksPermitted( false );

    RangeListNode * pOldAoIRoot = pAoIRoot_;

    // Scan our aoiMap, mark everything as isInAoIOffload and isGone
    AoIPreparer preparer;
    aoiMap_.mutate( preparer );

    if (this->isAoIRooted())
    {
        MobileRangeListNode * pRoot =
            static_cast< MobileRangeListNode * >( pAoIRoot_ );
        pRoot->delTrigger( pAoITrigger_ );
    }
    else
    {
        this->entity().delTrigger( pAoITrigger_ );
    }

    pAoIRoot_ = pNewAoIRoot;

    // AoITrigger does not contract when it is destroyed, so no
    // onLeftAoI callbacks are triggered.
    bw_safe_delete( pAoITrigger_ );

    {
        SCOPED_PROFILE( SHUFFLE_AOI_TRIGGERS_PROFILE );

        pAoITrigger_ = new AoITrigger( *this, pAoIRoot_, aoiRadius_ );
    }

    if (this->isAoIRooted())
    {
        MobileRangeListNode * pRoot =
            static_cast< MobileRangeListNode * >( pAoIRoot_ );
        pRoot->addTrigger( pAoITrigger_ );
    }
    else
    {
        entity().addTrigger( pAoITrigger_ );
    }

    AoICleaner cleaner( this->entity() );
    aoiMap_.mutate( cleaner );

    Entity::callbacksPermitted( true );

    return pOldAoIRoot;
}
```

切换流程:
1. **AoIPreparer**:把所有 AoI 内的实体标记为 `isInAoIOffload = true, isGone = true`(假装要 offload);
2. **删除旧 AoITrigger**(不收缩,不触发 leave);
3. **创建新 AoITrigger**(在新根周围,会自动触发 enter,把仍在范围内的实体重新加入);
4. **AoICleaner**:对于仍在 `isInAoIOffload` 状态的实体(即新 AoI 没重新加入的),触发 `onLeftAoI` 回调。

这种"假装 offload + 重建"的方式巧妙地复用了 offload 路径的代码,保证一致性。

### 10.8 setAoIRadius:动态调整半径

```cpp
// witness.cpp L2109-2147
void Witness::setAoIRadius( float radius, float hyst )
{
    SCOPED_PROFILE( SHUFFLE_AOI_TRIGGERS_PROFILE );

    radius = std::max( 0.1f, radius );

    aoiHyst_      = hyst;
    aoiRadius_    = radius;

    if (aoiRadius_ > CellAppConfig::maxAoIRadius())
    {
        WARNING_MSG( "Witness::setAoIRadius: Clamping %u's AoI radius (%.1f) "
            "to the maximum allowed value (%.1f)\n",
            entity_.id(), aoiRadius_, CellAppConfig::maxAoIRadius() );
        aoiRadius_ = CellAppConfig::maxAoIRadius();
    }

    Entity::callbacksPermitted( false );

    pAoITrigger_->setRange( aoiRadius_ );

    if (this->isAoIRooted())
    {
        MobileRangeListNode * pRoot =
            static_cast< MobileRangeListNode * >( pAoIRoot_ );
        pRoot->modTrigger( pAoITrigger_ );
    }
    else
    {
        entity_.modTrigger( pAoITrigger_ );
    }

    Entity::callbacksPermitted( true );
}
```

调整半径会调用 `RangeTrigger::setRange`,这会触发 shuffle,在收缩时触发 leave,在扩展时触发 enter。

---

## 十一、Witness 的 Pull 模型

### 11.1 Pull vs Push 模型对比

| 维度 | Push 模型 | BigWorld 的 Pull 模型 |
|------|-----------|------------------------|
| 触发 | 服务器主动 | 客户端请求 |
| 状态 | 服务器记录发送进度 | 客户端记录需求 |
| 跨进程 | 需迁移发送状态 | 只迁移 AoI 集合 |
| 容错 | 服务器崩溃丢失进度 | 客户端可重试 |
| 协议 | 复杂 | 简洁 |
| 延迟 | 低 | 略高(需 RTT) |
| 适用 | 简单游戏 | MMOG |

### 11.2 Pull 模型的核心:enterAoI + requestEntityUpdate

BigWorld 的客户端实体创建是**两阶段**的:

#### 阶段 1:enterAoI(服务器 → 客户端)

```cpp
// witness.cpp L1601-1637
void Witness::sendEnter( Mercury::Bundle & bundle, EntityCache * pCache )
{
    size_t oldSize = bundle.size();
    const Entity * pEntity = pCache->pEntity().get();

    pCache->idAlias( this->allocateIDAlias( *pEntity ) );

    MF_ASSERT( !pCache->isRequestPending() );
    pCache->clearEnterPending();
    pCache->setRequestPending();

    pCache->vehicleChangeNum( pEntity->vehicleChangeNum() );

    if (pEntity->pVehicle() != NULL)
    {
        BaseAppIntInterface::enterAoIOnVehicleArgs & rEnterAoIOnVehicle =
            BaseAppIntInterface::enterAoIOnVehicleArgs::start( bundle );

        rEnterAoIOnVehicle.id = pEntity->id();
        rEnterAoIOnVehicle.vehicleID = pEntity->pVehicle()->id();
        rEnterAoIOnVehicle.idAlias = pCache->idAlias();
    }
    else
    {
        BaseAppIntInterface::enterAoIArgs & rEnterAoI =
            BaseAppIntInterface::enterAoIArgs::start( bundle );

        rEnterAoI.id = pEntity->id();
        rEnterAoI.idAlias = pCache->idAlias();
    }
    pEntity->pType()->stats().enterAoICounter().
        countSentToOtherClients( bundle.size() - oldSize );
}
```

服务器只发送:
- Entity ID(4 字节);
- IDAlias(1 字节);
- (可选)Vehicle ID(4 字节)。

**不发送实体的属性数据**!这是 Pull 模型的关键。

#### 阶段 2:requestEntityUpdate(客户端 → 服务器)

客户端收到 enterAoI 后,**主动**向服务器请求该实体的详细数据:

```cpp
// witness.cpp L2025-2089
void Witness::requestEntityUpdate( EntityID id,
        EventNumber * pEventNumbers, int size )
{
    EntityCache * pCache = aoiMap_.find( id );

    if (pCache == NULL)
    {
        if (id != entity_.id())
        {
            DEBUG_MSG( "Witness::requestEntityUpdate: "
                "Pending entity %u is no longer in AoI of %u "
                "(should be rare and only after offload).\n",
                id, this->entity().id() );
        }
        ...
        return;
    }

    if (!pCache->isRequestPending())
    {
        ERROR_MSG( "Witness::requestEntityUpdate: "
                "Request for %u that is not pending in AoI of %u.\n",
            id, this->entity().id() );
        return;
    }

    pCache->clearRequestPending();
    pCache->setCreatePending();

    // make sure that the client is not try to stuff us up
    if (size > pCache->numLoDLevels())
    {
        ERROR_MSG( "CHEAT: Witness::requestEntityUpdate: "
            "Client %u sent %d LoD event stamps when max is %d\n",
            entity_.id(), size, pCache->numLoDLevels() );
        size = pCache->numLoDLevels();
    }

    pCache->lodEventNumbers( pEventNumbers, size );
    this->addToSeen( pCache );
}
```

客户端的请求包含:
- 实体 ID;
- 该实体各 LoD 级别的"已知事件号"(告诉服务器"我已经知道到哪个事件了")。

服务器响应后,把该实体加入 `entityQueue_`(优先级堆),准备发送 createEntity。

#### 阶段 3:createEntity(服务器 → 客户端)

```cpp
// witness.cpp L1643-1696
void Witness::sendCreate( Mercury::Bundle & bundle, EntityCache * pCache )
{
    size_t oldSize = bundle.size();
    pCache->clearCreatePending();

    if (pCache->isRefresh())
    {
        ERROR_MSG( "Witness::sendCreate: isRefresh = true\n" );
        pCache->clearRefresh();
    }

    MF_ASSERT( pCache->isUpdatable() );

    const Entity & entity = *pCache->pEntity();

    entity.writeVehicleChangeToBundle( bundle, *pCache );

    bool isVolatile = entity.volatileInfo().hasVolatile( 0.f );

    if (isVolatile)
    {
        bundle.startMessage( BaseAppIntInterface::createEntity );
    }
    else
    {
        bundle.startMessage( BaseAppIntInterface::createEntityDetailed );
    }

    {
        CompressionOStream compressedStream( bundle,
            this->entity().pType()->description().externalNetworkCompressionType() );

        compressedStream << entity.id() << entity.clientTypeID();
        compressedStream << entity.localPosition();

        if (isVolatile)
        {
            compressedStream << PackedYawPitchRoll< /* HALFPITCH */ false >(
                entity.localDirection().yaw, entity.localDirection().pitch,
                entity.localDirection().roll );
        }
        else
        {
            compressedStream << entity.localDirection().yaw;
            compressedStream << entity.localDirection().pitch;
            compressedStream << entity.localDirection().roll;
        }

        pCache->addOuterDetailLevel( compressedStream );
    }

    entity.pType()->stats().createEntityCounter().
        countSentToOtherClients( bundle.size() - oldSize );
}
```

createEntity 包含:
- Entity ID;
- Type ID;
- 位置(本地坐标);
- 朝向(压缩为 PackedYawPitchRoll 或全精度);
- 最外层 LoD 的属性(通过 `addOuterDetailLevel`)。

### 11.3 Pull 模型的优势

#### 11.3.1 跨进程 offload 友好

当 RealEntity 从 Cell A offload 到 Cell B 时,Witness 也跟着迁移。在 Pull 模型下,只需要序列化:
- AoI 集合(哪些实体在范围内);
- 每个 EntityCache 的状态(已知到哪个事件、LoD 级别等)。

不需要序列化"正在发送的属性流"或"发送缓冲区"——这些由客户端的 requestEntityUpdate 重新触发。

#### 11.3.2 客户端能力适配

低端客户端可以慢速请求,高端客户端可以快速请求。服务器不需要为每个客户端维护"发送速率"状态。

#### 11.3.3 容错性

如果客户端在 enterAoI 后崩溃,服务器只是保留 REQUEST_PENDING 状态,不会持续推送数据。重启后客户端可以重新请求。

### 11.4 Pull 模型的劣势

#### 11.4.1 延迟

每个新实体进入 AoI 需要:
1. 服务器发送 enterAoI;
2. 客户端接收,发 requestEntityUpdate;
3. 服务器接收,加入队列;
4. 服务器按优先级发送 createEntity。

至少 1.5 个 RTT 的延迟。在差网络下,玩家可能"看到一个空 ID 几百毫秒后才看到实体"。

#### 11.4.2 状态机复杂

需要维护 ENTER_PENDING → REQUEST_PENDING → CREATE_PENDING → 正常 的状态机(详见第十二节)。

### 11.5 addToAoI:加入 AoI 集合

```cpp
// witness.cpp L2202-2295
void Witness::addToAoI( Entity * pEntity, bool setManuallyAdded )
{
    if (pEntity->isDestroyed())
    {
        // 特殊处理:已销毁实体
        this->entity().isInAoIOffload( true );
        return;
    }

    if (!pEntity->pType()->description().canBeOnClient())
    {
        return;
    }

    EntityCache * pCache = aoiMap_.find( *pEntity );

    bool wasInAoIOffload = pEntity->isInAoIOffload();

    if (wasInAoIOffload)
    {
        pEntity->isInAoIOffload( false );
        MF_ASSERT( pCache != NULL );
        MF_ASSERT( pCache->isGone() );
    }

    if (pCache != NULL)
    {
        if (pCache->isGone())
        {
            pCache->reuse();
        }
        else
        {
            if (setManuallyAdded)
                pCache->setManuallyAdded();
            else
                pCache->setAddedByTrigger();
            return;
        }
    }
    else
    {
        pCache = aoiMap_.add( *pEntity );
        pCache->setEnterPending();
        this->addToSeen( pCache );
    }

    if (setManuallyAdded)
        pCache->setManuallyAdded();
    else
        pCache->setAddedByTrigger();

    if (!wasInAoIOffload)
    {
        if (this->shouldAddReplayAoIUpdates())
        {
            this->entity().cell().pReplayData()->addEntityAoIChange( 
                this->entity().id(), *(pCache->pEntity()), 
                /* hasEnteredAoI */ true );
        }

        pCache->isAlwaysDetailed(
            pEntity->pType()->description().shouldSendDetailedPosition() );

        this->entity().callback( "onEnteredAoI",
            Py_BuildValue( "(O)", pEntity ),
            "onEnteredAoI", true );
    }
}
```

#### 11.5.1 addToAoI 的算法

1. **销毁实体特殊处理**:如果是已销毁的实体,设置 `isInAoIOffload` 标志(用于匹配 removeFromAoI);
2. **客户端不可见类型**:跳过(如内部实体类型);
3. **offload 恢复**:如果 `isInAoIOffload = true`,说明是 offload 过程中匹配的 addToAoI,清除标志;
4. **已存在 cache**:
   - 如果 `isGone()`,调用 `reuse()` 复活;
   - 否则,只更新 `ManuallyAdded/AddedByTrigger` 标志;
5. **新 cache**:创建并加入 `entityQueue_`;
6. **onEnteredAoI 回调**:通知脚本(如果不是 offload 恢复)。

### 11.6 removeFromAoI:从 AoI 移除

```cpp
// witness.cpp L2305-2363
void Witness::removeFromAoI( Entity * pEntity, bool clearManuallyAdded )
{
    // Check if this is a remove that is matched with an ignored addToAoI call.
    if (this->entity().isInAoIOffload())
    {
        MF_ASSERT( pEntity->isDestroyed() );
        this->entity().isInAoIOffload( false );
        return;
    }

    if (!pEntity->pType()->description().canBeOnClient())
    {
        return;
    }

    EntityCache * pCache = aoiMap_.find( *pEntity );
    if (pCache == NULL)
    {
        this->entity().space().debugRangeList();
        CRITICAL_MSG( "Witness::removeFromAoI: "
                "Entity %u not in AoI of entity %u!\n",
            pEntity->id(), entity_.id() );
        return;
    }

    if (clearManuallyAdded)
    {
        pCache->clearManuallyAdded();
        if (pCache->isAddedByTrigger())
        {
            return;  // 仍被触发器管理,不删除
        }
    }
    else
    {
        pCache->clearAddedByTrigger();
        if (pCache->isManuallyAdded())
        {
            return;  // 仍被手动管理,不删除
        }
    }

    MF_ASSERT( !pCache->isGone() );
    pCache->setGone();

    if (this->shouldAddReplayAoIUpdates())
    {
        this->entity().cell().pReplayData()->addEntityAoIChange( 
            this->entity().id(), *(pCache->pEntity()), 
            /* hasEnteredAoI */ false );
    }

    this->entity().callback( "onLeftAoI", PyTuple_Pack( 1, pEntity ),
        "onLeftAoI", true );
}
```

注意:**removeFromAoI 不立即删除 EntityCache**,只是设置 `isGone` 标志。真正的删除发生在 `Witness::update` 中,通过 `handleStateChange` 处理。

这种延迟删除的设计是为了:
- 让 onLeftAoI 回调可以异步处理;
- 在 update 时统一处理状态变化,避免在 shuffle 中重入。

### 11.7 addToSeen:加入优先级堆

```cpp
// witness.cpp L1848-1874
void Witness::addToSeen( EntityCache * pCache )
{
    EntityCache::Priority initialPriority = 0.0;

    if (!entityQueue_.empty())
    {
        initialPriority = entityQueue_.front()->priority();
    }

    pCache->priority( initialPriority );

    entityQueue_.push_back( pCache );
    std::push_heap( entityQueue_.begin(), entityQueue_.end(), PriorityCompare() );
}
```

新加入的实体获得"当前堆顶的优先级",这样它不会立刻被发送(避免突然涌入大量新实体),而是等到下次 update 时按正常优先级调度。

### 11.8 PriorityCompare:小顶堆

```cpp
// witness.cpp L52-60
class PriorityCompare
{
public:
    bool operator()( const EntityCache * l, const EntityCache * r ) const
    {
        return l->priority() > r->priority();
    }
};
```

注意是 `>` 而不是 `<`,所以这是一个**小顶堆**——优先级数值最小的在堆顶。

回顾 `updatePriority`:`priority_ += delta`,delta 总是正数。所以:
- 长时间没被发送的实体,`priority_` 越来越大;
- `priority_` 小的实体(刚发送过)在堆顶,会被优先再次发送。

但 `delta` 与距离成正比——远距离实体 delta 大,优先级增长快;近距离实体 delta 小,增长慢。这意味着:
- 近距离实体:priority 增长慢,但一旦到达堆顶,下次又快速增长(因为发送时 priority 重置);
- 远距离实体:priority 增长快,会快速回到堆顶,但每次发送后重置。

最终效果:**近距离实体被高频更新,远距离实体被低频更新**。

### 11.9 Witness::update:核心推送循环

```cpp
// witness.cpp L1088-1409 (节选)
void Witness::update()
{
    SCOPED_PROFILE( CLIENT_UPDATE_PROFILE );
    AUTO_SCOPED_ENTITY_PROFILE( &entity_ );

    ...

    Mercury::Bundle & bundle = this->bundle();

    const float throttle = CellApp::instance().emergencyThrottle();
    const int desiredPacketSize = int(maxPacketSize_ * throttle) -
            bandwidthDeficit_ + bundle.size();

    this->addSpaceDataChanges( bundle );
    ...

    // send the vehicle stack first
    for (Entity * pVehicle = entity_.pVehicle(); pVehicle != NULL;
        pVehicle = pVehicle->pVehicle() )
    {
        EntityCache * pCache = aoiMap_.find( pVehicle->id() );
        ...
        pCache->setPrioritised();
        hasAddedReliableRelativePosition |= this->sendQueueElement( pCache );
    }

    ...

    EntityCache::Priority maxPriority = entityQueue_.empty() ? 0.f :
        entityQueue_.front()->priority() + MAX_PRIORITY_DELTA;

    KnownEntityQueue::iterator queueBegin = entityQueue_.begin();
    KnownEntityQueue::iterator queueEnd = entityQueue_.end();

    while ((queueBegin != queueEnd) &&
                (*queueBegin)->priority() < maxPriority &&
                bundle.size() < desiredPacketSize - 2)
    {
        EntityCache * pCache = entityQueue_.front();
        std::pop_heap( queueBegin, queueEnd--, PriorityCompare() );
        bool wasPrioritised = pCache->isPrioritised();

        MF_ASSERT(!pCache->isRequestPending());

        if (pCache->pEntity()->isDestroyed() && !pCache->isGone())
        {
            MF_ASSERT(pCache->isManuallyAdded());
            this->removeFromAoI( const_cast<Entity *>( pCache->pEntity().get() ),
                     /* clearManuallyAdded */ true );
        }

        if (!pCache->isUpdatable())
        {
            this->handleStateChange( &pCache, queueEnd );
        }
        else if (!pCache->isPrioritised())
        {
            hasAddedReliableRelativePosition |= this->sendQueueElement( pCache );
            pCache->updatePriority( entity_.position() );
        }

        if (wasPrioritised)
        {
            if (pCache)
            {
                pCache->priority( startingPriority );
                pCache->updatePriority( entity_.position() );
                pCache->clearPrioritised();
            }
            --numPrioritised;
        }
    }
    ...
}
```

#### 11.9.1 update 算法

1. **计算带宽预算**:`desiredPacketSize = maxPacketSize × throttle - bandwidthDeficit + bundle.size()`;
2. **优先发送 vehicle stack**:玩家所在的 vehicle(及其 vehicle)必须先发送,因为位置依赖;
3. **主循环**:
   - 弹出堆顶 EntityCache;
   - 如果已销毁,移出 AoI;
   - 如果不可更新(状态变化),调 `handleStateChange`;
   - 否则发送数据(`sendQueueElement`),更新优先级;
4. **停止条件**:堆空 / 优先级超出 maxPriorityDelta / 带宽用完;
5. **重排堆**:把弹出的元素重新 push 回去。

#### 11.9.2 MAX_PRIORITY_DELTA:防止远距离实体饿死

```cpp
const float MAX_PRIORITY_DELTA =
    CellAppConfig::witnessUpdateMaxPriorityDelta();
EntityCache::Priority maxPriority = entityQueue_.empty() ? 0.f :
    entityQueue_.front()->priority() + MAX_PRIORITY_DELTA;
```

默认 `witnessUpdateMaxPriorityDelta = 5.f`。这意味着只发送"优先级在堆顶 + 5 以内"的实体。结合默认 scheme(0 米 delta=1, 500 米 delta=101),这意味着每 tick 最多发送"距堆顶 5 个 delta 单位"的实体——大致相当于 45 米内的实体可以每帧发送(根据注释)。

#### 11.9.3 bandwidthDeficit:带宽赤字

```cpp
bandwidthDeficit_ =
    (bundle.size() > desiredPacketSize) ?
        bundle.size() - desiredPacketSize : 0;

if (bandwidthDeficit_ > maxPacketSize_)
{
    WARNING_MSG( "Witness::update: "
            "%u has a deficit of %d bytes (%.2f packets)\n",
        entity_.id(),
        bandwidthDeficit_,
        float(bandwidthDeficit_)/maxPacketSize_ );
    bandwidthDeficit_ = maxPacketSize_;
}
```

如果某 tick 发送的数据超过了预算,赤字会累积到下一 tick。下一 tick 的预算 = `maxPacketSize × throttle - bandwidthDeficit`,即"少发一点"以补偿。

赤字上限是 `maxPacketSize_`,避免赤字无限累积导致后续 tick 完全不能发送。

---

## 十二、EntityCache 状态机深度剖析

### 12.1 EntityCache 的角色

`EntityCache` 是 Witness 内部对"一个可见实体"的状态记录。每个 AoI 内的实体对应一个 EntityCache。

```cpp
// entity_cache.hpp L33-195
class EntityCache
{
public:
    static const int MAX_LOD_LEVELS = 4;
    typedef double Priority;

    EntityCache( const Entity * pEntity );

    ...
    enum
    {
        VEHICLE_CHANGE_NUM_OLD,
        VEHICLE_CHANGE_NUM_HAS_VEHICLE,
        VEHICLE_CHANGE_NUM_HAS_NO_VEHICLE
    };
    typedef uint8 VehicleChangeNum;
    ...
    void setEnterPending()     { flags_ |= ENTER_PENDING; }
    void setRequestPending()  { flags_ |= REQUEST_PENDING; }
    void setCreatePending()   { flags_ |= CREATE_PENDING; }
    void setGone()            { flags_ |= GONE; }
    void setWithheld()        { flags_ |= WITHHELD; }
    void setRefresh()         { flags_ |= REFRESH; }
    void setPrioritised()    { flags_ |= PRIORITISED; }
    void setManuallyAdded()   { flags_ |= MANUALLY_ADDED; }
    void setAddedByTrigger()  { flags_ |= ADDED_BY_TRIGGER; }
    ...
private:
    typedef uint16 Flags;

    enum
    {
        ENTER_PENDING    = 1 << 0,
        REQUEST_PENDING  = 1 << 1,
        CREATE_PENDING   = 1 << 2,
        GONE             = 1 << 3,
        WITHHELD         = 1 << 4,
        REFRESH          = 1 << 5,
        PRIORITISED      = 1 << 6,
        MANUALLY_ADDED   = 1 << 7,
        ADDED_BY_TRIGGER = 1 << 8,
        IS_ALWAYS_DETAILED = 1 << 9,

        NOT_UPDATABLE =
            ENTER_PENDING|REQUEST_PENDING|CREATE_PENDING|GONE|WITHHELD|REFRESH,

        CLIENT_STATE = ENTER_PENDING|REQUEST_PENDING|CREATE_PENDING|GONE|REFRESH,
    };
    ...
    EntityConstPtr    pEntity_;
    Flags             flags_;
    AoIUpdateSchemeID updateSchemeID_;
    VehicleChangeNum  vehicleChangeNum_;
    Priority          priority_;
    Priority          lastPriorityDelta_;
    EventNumber       lastEventNumber_;
    VolatileNumber    lastVolatileUpdateNumber_;
    DetailLevel       detailLevel_;
    IDAlias           idAlias_;
    EventNumber       lodEventNumbers_[ MAX_LOD_LEVELS ];
};
```

### 12.2 状态标志全览

| 标志 | 含义 | 设置时机 | 清除时机 |
|------|------|----------|----------|
| ENTER_PENDING | 等待发送 enterAoI | addToAoI 时 | sendEnter 时 |
| REQUEST_PENDING | 等待客户端 requestEntityUpdate | sendEnter 后 | requestEntityUpdate 时 |
| CREATE_PENDING | 等待发送 createEntity | requestEntityUpdate 后 | sendCreate 时 |
| GONE | 标记要从 AoI 移除 | removeFromAoI 时 | reuse / onEntityRemovedFromClient |
| WITHHELD | 不发送给客户端 | withholdFromClient | withholdFromClient(false) |
| REFRESH | 等待移除并重新加入 | reuse 检测到事件丢失 | handleStateChange 处理后 |
| PRIORITISED | 已被优先发送(如 vehicle) | 优先发送时 | update 结束时 |
| MANUALLY_ADDED | 手动加入 AoI | addToManualAoI | removeFromManualAoI |
| ADDED_BY_TRIGGER | 触发器自动加入 | addToAoI (trigger) | removeFromAoI (trigger) |
| IS_ALWAYS_DETAILED | 总是发送详细位置 | setPositionDetailed | setPositionDetailed(false) |

### 12.3 状态机图

```
                    ┌─────────────┐
                    │  (不存在)   │
                    └──────┬──────┘
                           │ addToAoI
                           ▼
                    ┌──────────────────┐
                    │  ENTER_PENDING   │ ←──┐
                    │  + ADDED_BY_TRIGGER │   │ addToAoI (复活)
                    └──────────┬───────┘    │
                               │            │
                               │ sendEnter  │
                               ▼            │
                    ┌──────────────────┐    │
                    │ REQUEST_PENDING  │    │
                    └──────────┬───────┘    │
                               │            │
                               │ requestEntityUpdate
                               ▼            │
                    ┌──────────────────┐    │
                    │ CREATE_PENDING   │    │
                    └──────────┬───────┘    │
                               │            │
                               │ sendCreate │
                               ▼            │
                    ┌──────────────────┐    │
                    │  (正常,可更新)   │ ───┘
                    └──────────┬───────┘
                               │
                               │ removeFromAoI
                               ▼
                    ┌──────────────────┐
                    │      GONE        │
                    └──────────┬───────┘
                               │
                               │ handleStateChange → deleteFromSeen
                               ▼
                    ┌─────────────┐
                    │  (不存在)   │
                    └─────────────┘
```

### 12.4 NOT_UPDATABLE 与 CLIENT_STATE

```cpp
NOT_UPDATABLE =
    ENTER_PENDING|REQUEST_PENDING|CREATE_PENDING|GONE|WITHHELD|REFRESH;

CLIENT_STATE = ENTER_PENDING|REQUEST_PENDING|CREATE_PENDING|GONE|REFRESH;
```

- `NOT_UPDATABLE`:这些状态存在时,不能正常发送数据(但 WITHHELD 不是 client 状态,因为它需要跨 offload 保留);
- `CLIENT_STATE`:这些状态与"客户端已知"相关,实体从客户端移除时需要清除。

`isUpdatable()` 的实现:
```cpp
bool isUpdatable() const { return (flags_ & NOT_UPDATABLE) == 0; }
```

### 12.5 handleStateChange:状态变化处理

```cpp
// witness.cpp L986-1034
void Witness::handleStateChange( EntityCache ** ppCache,
                KnownEntityQueue::iterator & queueEnd )
{
    MF_ASSERT( ppCache != NULL );

    Mercury::Bundle & bundle = this->bundle();
    EntityCache * pCache = *ppCache;

    MF_ASSERT( !pCache->isRequestPending() );
    if (pCache->isGone())
    {
        this->deleteFromSeen( bundle, queueEnd );
        *ppCache = NULL;
    }
    else if (pCache->isWithheld())
    {
        if (!pCache->isEnterPending())
        {
            this->deleteFromClient( bundle, *queueEnd );
            MF_ASSERT( pCache->isWithheld() );
            pCache->setEnterPending();
        }
    }
    else if (pCache->isEnterPending())
    {
        this->handleEnterPending( bundle, queueEnd );
    }
    else if (pCache->isCreatePending())
    {
        this->sendCreate( bundle, pCache );
        pCache->updatePriority( entity_.position() );
    }
    else if (pCache->isRefresh())
    {
        pCache->clearRefresh();
        this->deleteFromClient( bundle, pCache );
        pCache->setEnterPending();
        this->handleEnterPending( bundle, queueEnd );
    }
}
```

各种状态变化的处理:
- **GONE**:从 seen 列表删除;
- **WITHHELD**:如果客户端已知,先发 leaveAoI,再设 ENTER_PENDING(等下次 withhold 解除时发 enter);
- **ENTER_PENDING**:调用 handleEnterPending 发送 enterAoI;
- **CREATE_PENDING**:发送 createEntity;
- **REFRESH**:先删除(发 leave),再 enter(走 ENTER_PENDING 流程),用于"事件丢失时重建"。

### 12.6 reuse:复活已 gone 的 cache

```cpp
// entity_cache.cpp L382-402
void EntityCache::reuse()
{
    MF_ASSERT( this->isGone() );
    this->clearGone();

    if (this->lastEventNumber() < pEntity_->eventHistory().lastTrimmedEventNumber()
        && this->isUpdatable())
    {
        // In this case, we have missed events. Refresh the entity
        // properties by throwing it out of the AoI and make it re-enter
        // immediately after.
        INFO_MSG( "EntityCache::reuse: Client has last received event %d, "
                "entity is at event %d but only has history since event %d. "
                "Not reusing cache.\n",
            this->lastEventNumber(),
            pEntity_->lastEventNumber(),
            pEntity_->eventHistory().lastTrimmedEventNumber() );

        this->setRefresh();
    }
}
```

当一个实体"刚 leave 又 enter"时(快速来回),如果 `isGone` 状态,直接复活 cache 即可,不需要重新走 enter/create 流程。但如果事件历史已裁剪(客户端错过的事件已被服务器清理),需要 `setRefresh`,触发"删除+重新创建"流程。

### 12.7 LoD 层级管理

```cpp
// entity_cache.hpp L37
static const int MAX_LOD_LEVELS = 4;

// entity_cache.hpp L189
EventNumber lodEventNumbers_[ MAX_LOD_LEVELS ];
```

每个 EntityCache 记录每个 LoD 级别的"已知事件号":

```cpp
// entity_cache.cpp L170-198
bool EntityCache::updateDetailLevel( Mercury::Bundle & bundle,
    float lodPriority, bool hasSelectedEntity )
{
    bool hasWrittenToStream = false;

    const EntityDescription & entityDesc =
        this->pEntity()->pType()->description();
    const DataLoDLevels & lodLevels = entityDesc.lodLevels();

    while (lodLevels.needsMoreDetail( detailLevel_, lodPriority ))
    {
        detailLevel_--;
        hasWrittenToStream |= this->addChangedProperties( bundle, &bundle,
            /* shouldSelectEntity */ !hasSelectedEntity );
        hasSelectedEntity |= hasWrittenToStream;
    }

    while (lodLevels.needsLessDetail( detailLevel_, lodPriority ))
    {
        this->lodEventNumber( detailLevel_, this->lastEventNumber() );
        detailLevel_++;
    }

    return hasWrittenToStream;
}
```

随着距离变化,EntityCache 会动态调整 LoD 级别:
- 实体靠近:detailLevel 减小(更详细),发送新 LoD 级别的属性;
- 实体远离:detailLevel 增大(更简略),保存当前事件号以备后续。

### 12.8 resetClientState:状态重置

```cpp
// entity_cache.ipp L40-57
INLINE void EntityCache::resetClientState()
{
    MF_ASSERT( this->pEntity() );

    lastEventNumber_ = this->pEntity()->lastEventNumber();
    lastVolatileUpdateNumber_ = this->pEntity()->volatileUpdateNumber() - 1;
    detailLevel_ = this->numLoDLevels();

    idAlias_ = NO_ID_ALIAS;
    lastPriorityDelta_ = DBL_MAX;

    MF_ASSERT( detailLevel_ <= MAX_LOD_LEVELS );

    for (DetailLevel i = 0; i < detailLevel_; i++)
        lodEventNumbers_[i] = 0;
}
```

当实体从客户端移除(`onEntityRemovedFromClient`)时,调用此方法重置"客户端已知"相关的状态:
- lastEventNumber 同步到当前;
- detailLevel 重置为最外层;
- idAlias 重置为 NO_ID_ALIAS。

但保留 `flags_` 中的"服务器相关"标志(MANUALLY_ADDED, ADDED_BY_TRIGGER, IS_ALWAYS_DETAILED, WITHHELD)。

### 12.9 EntityCacheMap:有序集合

```cpp
// entity_cache.hpp L229-253
class EntityCacheMap
{
public:
    ~EntityCacheMap();

    EntityCache * add( const Entity & e );
    void del( EntityCache * ec );

    EntityCache * find( const Entity & e ) const;
    EntityCache * find( EntityID id ) const;

    uint32 size() const { return set_.size(); }

    void writeToStream( BinaryOStream & stream ) const;

    void visit( EntityCacheVisitor & visitor ) const;
    void mutate( EntityCacheMutator & mutator );

    static void addWatchers();

private:
    typedef BW::set< EntityCache > Implementor;
    Implementor set_;
};
```

`EntityCacheMap` 用 `BW::set<EntityCache>`(红黑树)存储,排序按 `pEntity` 指针:

```cpp
// entity_cache.hpp L197-201
inline
bool operator<( const EntityCache & left, const EntityCache & right )
{
    return left.pEntity() < right.pEntity();
}
```

选择红黑树而非 hash map 的原因:
- 迭代顺序确定(按指针),便于 offload 时序列化一致;
- 没有 hash 函数的开销;
- 实体数量通常不大(AOI 内几百个),log N 不是瓶颈。

### 12.10 visit / mutate:访问者模式

```cpp
// entity_cache.hpp L208-223
class EntityCacheVisitor
{
public:
    virtual void visit( const EntityCache & cache ) = 0;
};

class EntityCacheMutator
{
public:
    virtual void mutate( EntityCache & cache ) = 0;
};
```

访问者模式让外部代码可以遍历 AoI 集合而不暴露内部数据结构。Witness 中大量使用,如:
- `AoIPreparer`(标记所有为 isInAoIOffload);
- `AoICleaner`(清理未恢复的);
- `ManualAoIVisitor`(更新手动 AoI);
- `AoICollector`(收集实体列表)。

---

## 十三、客户端实体同步流程

### 13.1 整体流程图

```
                 CellApp (Witness)                    BaseApp               Client
                      │                                  │                     │
                      │                                  │                     │
   AoITrigger         │                                  │                     │
   触发 enter ──────► │                                  │                     │
                      │ addToAoI                         │                     │
                      │ setEnterPending                  │                     │
                      │                                  │                     │
                      │ handleEnterPending               │                     │
                      │ sendEnter ───────────────────► │ enterAoI ─────────► │ 创建 Entity
                      │ setRequestPending                │                     │ (空壳)
                      │                                  │                     │
                      │                                  │ requestEntityUpdate │
                      │ ◄───────────────────────────── │ ◄───────────────── │
                      │                                  │                     │
                      │ setCreatePending                 │                     │
                      │ addToSeen                        │                     │
                      │                                  │                     │
                      │ sendCreate                       │                     │
                      │ sendCreate ───────────────────► │ createEntity ─────► │ 填充属性
                      │ (在 update 循环中)               │                     │
                      │                                  │                     │
                      │                                  │                     │
   位置变化           │                                  │                     │
                      │ sendQueueElement                 │                     │
                      │ writeClientUpdateDataToBundle ─► │ updateEntity ────► │ 更新属性
                      │                                  │                     │
   AoITrigger         │                                  │                     │
   触发 leave ──────► │ removeFromAoI                    │                     │
                      │ setGone                          │                     │
                      │                                  │                     │
                      │ handleStateChange                │                     │
                      │ deleteFromSeen                   │                     │
                      │ sendLeaveAoI ─────────────────► │ leaveAoI ────────► │ 销毁 Entity
                      │                                  │                     │
```

### 13.2 enterAoI 消息格式

```cpp
// witness.cpp L1618-1634
if (pEntity->pVehicle() != NULL)
{
    BaseAppIntInterface::enterAoIOnVehicleArgs & rEnterAoIOnVehicle =
        BaseAppIntInterface::enterAoIOnVehicleArgs::start( bundle );

    rEnterAoIOnVehicle.id = pEntity->id();
    rEnterAoIOnVehicle.vehicleID = pEntity->pVehicle()->id();
    rEnterAoIOnVehicle.idAlias = pCache->idAlias();
}
else
{
    BaseAppIntInterface::enterAoIArgs & rEnterAoI =
        BaseAppIntInterface::enterAoIArgs::start( bundle );

    rEnterAoI.id = pEntity->id();
    rEnterAoI.idAlias = pCache->idAlias();
}
```

两条消息:
- `enterAoI`:普通实体(id + idAlias);
- `enterAoIOnVehicle`:在 vehicle 上的实体(id + vehicleID + idAlias)。

### 13.3 leaveAoI 消息格式

```cpp
// entity_cache.cpp L342-375
void EntityCache::addLeaveAoIMessage( Mercury::Bundle & bundle,
       EntityID id ) const
{
    MF_ASSERT( !this->pEntity() || this->pEntity()->id() == id );

    bundle.startMessage( BaseAppIntInterface::leaveAoI );
    bundle << id;

    if (this->pEntity())
    {
        const int size = this->numLoDLevels();

        for (int i = 0; i < detailLevel_; i++)
        {
            bundle << lodEventNumbers_[i];
        }

        for (int i = detailLevel_; i < size; i++)
        {
            bundle << this->lastEventNumber();
        }
    }
}
```

leaveAoI 包含:
- Entity ID;
- 每个 LoD 级别的事件号(让客户端知道"最终状态")。

### 13.4 createEntity 消息

详见 11.2 节,包含:
- Entity ID + Type ID;
- 位置 + 朝向(根据 volatile 压缩);
- 最外层 LoD 属性。

### 13.5 位置更新流

实体的位置更新通过 `Entity::writeClientUpdateDataToBundle` 写入 bundle:

```cpp
// witness.cpp L1043-1082
bool Witness::sendQueueElement( EntityCache * pCache )
{
    Mercury::Bundle & bundle = this->bundle();

    const Entity & otherEntity = *pCache->pEntity();
    bool hasAddedReliableRelativePosition = false;

    float distSqr = pCache->getLoDPriority( entity_.position() );

#if VOLATILE_POSITIONS_ARE_ABSOLUTE
    otherEntity.writeClientUpdateDataToBundle( bundle, Position3D::zero(),
        *pCache, distSqr );
#else
    hasAddedReliableRelativePosition |=
        otherEntity.writeClientUpdateDataToBundle( bundle,
            referencePosition_, *pCache, distSqr );
#endif

    return hasAddedReliableRelativePosition;
}
```

位置更新包括:
- 位置(相对 referencePosition 的压缩 12 位浮点);
- 朝向(PackedYawPitchRoll);
- LoD 属性变化;
- 事件流(详细属性更新)。

### 13.6 selectEntity:消息路由

由于一个 bundle 中可能包含多个实体的消息,需要明确"接下来的消息是给哪个实体的":

```cpp
// witness.cpp L956-978
bool Witness::selectEntity( Mercury::Bundle & bundle,
    EntityID targetID ) const
{
    if (targetID == entity_.id())
    {
        bundle.startMessage(
            BaseAppIntInterface::selectPlayerEntity );
    }
    else
    {
        EntityCache * pCache = aoiMap_.find( targetID );

        if (!pCache || !pCache->isUpdatable())
        {
            ERROR_MSG( "Witness::selectEntity: Witness %d trying "
                    "to select Entity %d outside its AoI\n",
                entity_.id(), targetID );
            return false;
        }
        pCache->addEntitySelectMessage( bundle );
    }
    return true;
}
```

```cpp
// entity_cache.cpp L313-330
void EntityCache::addEntitySelectMessage( Mercury::Bundle & bundle ) const
{
    MF_ASSERT( this->pEntity() != NULL );
    MF_ASSERT( this->isUpdatable() );

    const bool hasAlias = (this->idAlias() != NO_ID_ALIAS);

    if (hasAlias)
    {
        BaseAppIntInterface::selectAliasedEntityArgs::start(
                bundle ).idAlias = this->idAlias();
    }
    else
    {
        BaseAppIntInterface::selectEntityArgs::start( bundle ).id =
            this->pEntity()->id();
    }
}
```

如果有 IDAlias,用 1 字节的 alias;否则用 4 字节的 EntityID。

### 13.7 flushToClient:发送 bundle

```cpp
// witness.cpp L1702-1713
void Witness::flushToClient()
{
    // Tell the BaseApp to send to the client.
    this->bundle().startMessage( BaseAppIntInterface::sendToClient );

    g_downstreamBytes += this->bundle().size();
    g_downstreamPackets += this->bundle().numDataUnits();
    ++g_downstreamBundles;

    // Send bundle via the channel
    real_.channel().send();
}
```

CellApp 不直接连客户端,通过 BaseApp 转发。`sendToClient` 消息告诉 BaseApp "这个 bundle 转发给客户端"。

### 13.8 tickSync:tick 同步

```cpp
// witness.cpp L1407-1408 (update 结尾)
BaseAppIntInterface::tickSyncArgs::start( this->bundle() ).tickByte =
    (uint8)(CellApp::instance().time() + 1);
```

每个 bundle 结尾附加一个 tickSync,告诉客户端"这些数据是下一 tick 的"。客户端据此做插值。

---

## 十四、IDAlias 带宽优化机制

### 14.1 IDAlias 的设计

`IDAlias` 是 1 字节的实体短标识,用于代替 4 字节的 EntityID 在已建立的"上下文"中标识实体。

```cpp
// entity_cache.hpp L27
const IDAlias NO_ID_ALIAS = 0xff;
```

`NO_ID_ALIAS = 0xff` 是保留值,表示"没有 alias,用完整 ID"。

### 14.2 IDAlias 的分配

```cpp
// witness.hpp L286-287
IDAlias freeAliases_[ 256 ];
int     numFreeAliases_;
```

Witness 持有一个 256 元素的数组和计数器。数组前 `numFreeAliases_` 个元素是空闲的 IDAlias。

#### 14.2.1 初始化

```cpp
// witness.cpp L161-180
memset( freeAliases_, 1, sizeof( freeAliases_ ) );

this->readOffloadData( data, createRealInfo, hasChangedSpace );

// Make sure that this NO_ID_ALIAS is reserved
freeAliases_[ NO_ID_ALIAS ] = 0;

for (uint i = 0; i < sizeof( freeAliases_ ); i++)
{
    int temp = freeAliases_[i];
    freeAliases_[ numFreeAliases_ ] = i;
    numFreeAliases_ += temp;
}
```

巧妙的初始化:
1. memset(1) 把所有元素设为 1;
2. 如果是 offload 来的,readOffloadData 会把已用的 alias 对应位置设为 0;
3. NO_ID_ALIAS(0xff)对应位置设为 0(保留);
4. 遍历数组,如果元素是 1,把索引加入"空闲区",并增加 numFreeAliases_;
5. 如果是 0,跳过(不增加 numFreeAliases_)。

最终 `freeAliases_[0..numFreeAliases_-1]` 是所有空闲的 IDAlias。

#### 14.2.2 分配

```cpp
// witness.cpp L1881-1894
IDAlias Witness::allocateIDAlias( const Entity & entity )
{
    // Only give an ID alias to those entities who have volatile data.
    // TODO: Consider whether this should be done on the entity's volatileInfo
    // or the entity type's volatileInfo.
    if (entity.volatileInfo().hasVolatile( 0.f ) &&
            numFreeAliases_ != 0)
    {
        numFreeAliases_--;
        return freeAliases_[ numFreeAliases_ ];
    }

    return NO_ID_ALIAS;
}
```

分配规则:
1. **只有含 volatile 数据的实体才分配 alias**:volatile 数据是指位置、方向等需要频繁更新的属性。没有 volatile 数据的实体(如纯静态 NPC)不会获得 alias,因为它们不需要高频发送更新;
2. **`hasVolatile(0.f)`**:参数 0.f 表示"任何 LOD 级别有 volatile 属性"。传入 0 表示最低 LOD 的优先级阈值;
3. **栈式分配**:从数组尾部取(`numFreeAliases_--`),释放时放回尾部,类似栈操作;
4. **无可用 alias 时返回 `NO_ID_ALIAS`**:此时所有消息用完整 4 字节 EntityID。

#### 14.2.3 释放

```cpp
// witness.cpp (delFromSeen 调用链中)
void Witness::delFromSeen( EntityCache * pCache )
{
    IDAlias alias = pCache->idAlias();
    if (alias != NO_ID_ALIAS)
    {
        freeAliases_[ numFreeAliases_ ] = alias;
        ++numFreeAliases_;
    }
    // ... 删除 EntityCache
}
```

释放时把 alias 放回数组尾部。注意:释放的 alias 可能不是最后分配的,但因为是"栈"语义,只要它确实是当前已分配的 alias,放回尾部就是安全的(不会与未分配的混淆)。

### 14.3 IDAlias 的使用:selectEntity

```cpp
// witness.cpp L3446-3468
bool Witness::selectEntity( Mercury::Bundle & bundle, EntityID id )
{
    EntityCache * pCache = aoiMap_.find( id );

    if (pCache == NULL)
    {
        // Entity is not in AoI
        return false;
    }

    if (!pCache->isEnterPending())
    {
        // Use IDAlias if available
        IDAlias alias = pCache->idAlias();
        if (alias != NO_ID_ALIAS)
        {
            BaseAppIntInterface::selectAliasArgs::start( bundle ).alias = alias;
        }
        else
        {
            BaseAppIntInterface::selectEntityArgs::start( bundle ).id = id;
        }
    }
    else
    {
        // ... use full ID for enter-pending entities
    }
    return true;
}
```

关键点:
- **已进入 AoI 的实体**:如果有 alias,用 1 字节 alias;否则用 4 字节 EntityID;
- **enter-pending 状态的实体**:必须用完整 ID,因为客户端尚未建立 alias 映射;
- **不在 AoI 的实体**:返回 false,调用方跳过该消息。

### 14.4 带宽节省分析

假设一个玩家 AOI 内有 50 个实体,每 tick 每个实体发送 2 条消息(位置 + 属性更新):

| 场景 | 每消息标识开销 | 每 tick 标识总开销 | 每秒(10 tick)标识开销 |
|------|--------------|-------------------|----------------------|
| 无 IDAlias(全用 EntityID) | 4 字节 | 50×2×4 = 400 字节 | 4000 字节 = 3.9 KB |
| 有 IDAlias(全部命中) | 1 字节 | 50×2×1 = 100 字节 | 1000 字节 = 1.0 KB |
| 节省 | 3 字节/消息 | 300 字节/tick | 3000 字节/秒 ≈ 2.9 KB/s |

对于 1000 个在线玩家,每秒节省约 2.9 MB 的下行带宽。这在 MMO 场景下非常可观。

### 14.5 IDAlias 的生命周期

```
实体进入 AoI (addToAoI)
    │
    ├─ enterAoI 消息:用完整 EntityID(无 alias)
    │
    ▼
客户端 requestEntityUpdate
    │
    ▼
服务端 requestEntityUpdate → createEntity
    │  allocateIDAlias() 分配 alias
    ▼
createEntity 消息:携带 alias 与 EntityID 的映射
    │
    ▼
后续所有消息(位置、属性):用 alias(1 字节)
    │
    ▼
实体离开 AoI (removeFromAoI → delFromSeen)
    │  释放 alias 回 freeAliases_ 栈
    ▼
leaveAoI 消息:用 alias(如果还分配着)
```

### 14.6 IDAlias 与 offload

当实体 offload 到新 Cell 时,Witness 通过 `writeOffloadData` / `readOffloadData` 保持 IDAlias 分配状态:

```cpp
// witness.cpp L161-180 (init 中的 offload 恢复)
// 1. memset(1) 全部置为"空闲"
// 2. readOffloadData 读取已分配的 alias,把对应位置置 0
// 3. 遍历收集所有"空闲"的 alias
```

这样 offload 后的 Witness 不需要重新分配所有 alias,客户端的 alias 映射也保持有效。

---

## 十五、视觉控制器体系

### 15.1 概述:Vision 与 AoI 的区别

BigWorld 中存在两套"看见"机制,容易混淆:

| 机制 | 类 | 触发回调 | 是否影响客户端可见性 | 视锥/遮挡 |
|------|-----|---------|--------------------|---------|
| **AoI (Witness)** | Witness + AoITrigger | onEnteredAoI / onLeftAoI | 是(发送实体数据) | 否(纯距离) |
| **Vision** | VisionController + VisionRangeTrigger | onStartSeeing / onStopSeeing | 否(仅脚本通知) | 是(视锥+遮挡) |

- **AoI**:距离驱动,决定"客户端能收到哪些实体的数据"。是网络层的概念;
- **Vision**:视锥+射线遮挡检测,决定"脚本认为这个实体能'看到'什么"。是游戏逻辑层的概念,用于 AI、潜行等。

二者**独立运行**,一个实体可以同时有 Witness(玩家)和 VisionController(NPC/AI),也可以只有其一。

### 15.2 VisionController 类层次

```
Controller (server/cellapp/controller.hpp)
    │
    ├─ VisionController        (vision_controller.hpp L17)
    │   ├─ ScanVisionController (scan_vision_controller.hpp L12)
    │   └─ (Updatable 接口)
    │
    ├─ VisibilityController    (visibility_controller.hpp L13, DOMAIN_GHOST)
    │
    ├─ ProximityController    (proximity_controller.hpp L20, DOMAIN_REAL)
    ├─ TurnController
    └─ TimerController
```

### 15.3 VisionController 详解

```cpp
// vision_controller.hpp L17-56
class VisionController : public Controller, public Updatable
{
    DECLARE_CONTROLLER_TYPE( VisionController )
public:
    VisionController( float visionAngle = 1.f, float visionRange = 20.f,
        float seeingHeight = 2.f, int updatePeriod = 10 );

    virtual void startReal( bool isInitialStart );
    virtual void stopReal( bool isFinalStop );
    virtual float getYawOffset();
    void update();   // 实现 Updatable 接口

    void setVisionRange( float visionAngle, float range );
    // ...
private:
    float visionAngle_;      // 视锥半角(弧度),实际 FOV = 2 × visionAngle_
    float visionRange_;      // 视距(米)
    float seeingHeight_;     // 视点高度(实体位置上方多少米)
    int   updatePeriod_;     // 更新周期(tick,默认10=1秒)
    int   tickSinceLast_;    // 距上次更新 tick 数
    VisionRangeTrigger* pVisionTrigger_;  // 触发器
    BW::vector< EntityID > * pOnloadedVisible_;  // onload 时恢复
};
```

关键点:
- **DOMAIN_REAL**:VisionController 只在 Real 实体上运行(`IMPLEMENT_CONTROLLER_TYPE( VisionController, DOMAIN_REAL )`),Ghost 上不存在;
- **Updatable**:继承 `Updatable`,注册到 `CellApp::instance().registerForUpdate(this)`,每 tick 调用 `update()`;
- **updatePeriod_**:默认 10 tick(1 秒)更新一次可见集,降低 CPU 开销。

### 15.4 VisionRangeTrigger

```cpp
// vision_controller.cpp L19-65
class VisionRangeTrigger : public RangeTrigger
{
public:
    VisionRangeTrigger( Entity & around, float range ) :
        RangeTrigger( around.pRangeListNode(), range,
                RangeListNode::FLAG_ENTITY_TRIGGER,     // wantsFlags
                RangeListNode::FLAG_ENTITY_TRIGGER,     // makesFlags
                RangeListNode::FLAG_NO_TRIGGERS,        // wantsFlags (Z)
                RangeListNode::FLAG_NO_TRIGGERS ),      // makesFlags (Z)
        disabled_( false )
    {
        this->insert();
        this->pEntity()->addTrigger( this );
    }

    void setRangeAndMod( float r );
    void disable();
    virtual void triggerEnter( Entity & entity );
    virtual void triggerLeave( Entity & entity );
    virtual BW::string debugString() const;
    virtual Entity * pEntity() const;
private:
    bool disabled_;
};
```

设计要点:
1. **wantsFlags = FLAG_ENTITY_TRIGGER**:只关心"实体节点"的跨越,不关心其他触发器节点;
2. **makesFlags = FLAG_ENTITY_TRIGGER**:自己作为触发器,只被"也关心实体"的节点感知;
3. **triggerEnter/triggerLeave**:实体进入/离开视觉范围时,转发给 `EntityVision::triggerVisionEnter/Leave`;
4. **disabled_**:当 `stopReal(false)`(非最终停止)时,调用 `disable()`,析构时用 `removeWithoutContracting()` 而非 `remove()`,避免在 offload 过程中触发 onLeaveAoI 回调。

### 15.5 VisionController::update

```cpp
// vision_controller.cpp L158-177
void VisionController::update()
{
    AUTO_SCOPED_PROFILE( "visionUpdate" );

    if (tickSinceLast_ >= updatePeriod_)
    {
        tickSinceLast_ = 0;
        ControllerPtr pController = this;  // 保持自身存活
        EntityVision::instance( this->entity() ).updateVisibleEntities(
            seeingHeight_, this->getYawOffset() );
    }
    else
    {
        tickSinceLast_++;
    }
}
```

- **节流**:`updatePeriod_` 控制视觉检测频率,默认 10 tick(1秒),减少 CPU 开销;
- **自我保护**:`ControllerPtr pController = this` 防止在 `updateVisibleEntities` 过程中脚本回调销毁自身;
- **实际工作**:`EntityVision::updateVisibleEntities` 执行视锥+遮挡检测(详见下一节)。

### 15.6 ScanVisionController:扫描视觉

```cpp
// scan_vision_controller.hpp L12-35
class ScanVisionController : public VisionController
{
    DECLARE_CONTROLLER_TYPE( ScanVisionController )
public:
    ScanVisionController( float visionAngle = 1.f, float visionRange = 20.f,
        float seeingHeight = 2.f, float amplitude = 0.f,
        float scanPeriod = 0.f, float timeOffset = 0.f,
        int updatePeriod = 10 );

    virtual float getYawOffset();
    // ...
private:
    float amplitude_;    // 扫描振幅(弧度)
    float scanPeriod_;   // 扫描周期(秒)
    float timeOffset_;  // 时间偏移(相位)
};
```

`ScanVisionController` 继承 `VisionController`,重写 `getYawOffset()`:

```cpp
// (实现中)
float ScanVisionController::getYawOffset()
{
    // 基于游戏时间计算扫描偏移
    // yawOffset = amplitude × sin(2π × (time + timeOffset) / scanPeriod)
    return amplitude_ * sinf( ... );
}
```

效果:实体视线左右扫动,周期性地"看到"和"看不到"前方两侧的实体,模拟哨兵巡逻。

### 15.7 VisibilityController:可被看到

```cpp
// visibility_controller.hpp L13-39
class VisibilityController : public Controller
{
    DECLARE_CONTROLLER_TYPE( VisibilityController )
public:
    VisibilityController( float visibleHeight = 2.f );
    virtual void startGhost();
    virtual void stopGhost();
    float visibleHeight() const { return visibleHeight_; }
    void visibleHeight( float h );
private:
    float visibleHeight_;
};
```

- **DOMAIN_GHOST**:`IMPLEMENT_CONTROLLER_TYPE_WITH_PY_FACTORY( VisibilityController, DOMAIN_GHOST )`——这个控制器在 Ghost 上运行,因为"能否被看到"是 Ghost 上的属性;
- **visibleHeight_**:实体"可见高度",用于视觉检测时计算目标点(实体位置 + visibleHeight);
- **startGhost/stopGhost**:注册到 `EntityVision::setVisibility`,这样其他实体的 VisionController 可以查询到这个实体的可见高度。

### 15.8 ProximityController:邻近触发器

```cpp
// proximity_controller.hpp L20-47
class ProximityController : public Controller
{
    DECLARE_CONTROLLER_TYPE( ProximityController )
public:
    ProximityController( float range = 20.f );
    virtual void startReal( bool isInitialStart );
    virtual void stopReal( bool isFinalStop );
    void setRange( float range );
    // ...
private:
    float range_;
    ProximityRangeTrigger* pProximityTrigger_;
    BW::vector< EntityID > * pOnloadedSet_;
};
```

- **DOMAIN_REAL**:邻近触发器在 Real 上运行;
- **range_(默认20米)**:检测半径;
- **回调**:`onEnterTrap(entity, controllerId, userArg)` 和 `onLeaveTrap(...)`;
- **用途**:陷阱、区域触发、怪物仇恨范围等。

### 15.9 控制器对比总结

| 控制器 | 域 | 触发器类型 | 脚本回调 | 典型用途 |
|-------|-----|---------|---------|---------|
| VisionController | REAL | VisionRangeTrigger | onStartSeeing/onStopSeeing | NPC AI 视觉 |
| ScanVisionController | REAL | VisionRangeTrigger | 同上(带扫描) | 哨兵、巡逻 |
| VisibilityController | GHOST | 无(被动) | 无 | 控制被看到的属性 |
| ProximityController | REAL | ProximityRangeTrigger | onEnterTrap/onLeaveTrap | 区域触发 |
| Witness | — | AoITrigger | onEnteredAoI/onLeftAoI | 玩家网络同步 |

---

## 十六、EntityVision 视觉扩展

### 16.1 EntityVision 的角色

`EntityVision` 是 `EntityExtra` 的子类,作为实体的"视觉相关状态"挂载点,同时管理"看"与"被看"两个方向。

```cpp
// entity_vision.hpp L17-126
class EntityVision : public EntityExtra
{
    Py_EntityExtraHeader( EntityVision )
public:
    EntityVision( Entity & e );

    // 主动视觉(Real 上)
    VisionController * getVision() const       { return vision_; }
    void setVision( VisionController * vc );

    // 被动可见性(Ghost 上)
    VisibilityController * getVisibility() const { return visibility_; }
    void setVisibility( VisibilityController * vc );

    // 视觉范围内的实体集合(由 VisionRangeTrigger 维护)
    const EntitySet& entitiesInVisionRange() const { return entitiesInVisionRange_; }
    // 当前可见的实体集合(经视锥+遮挡过滤后)
    const EntitySet& visibleEntities() const    { return visibleEntities_; }

    // ... 属性和方法
private:
    EntitySet entitiesInVisionRange_;   // 视觉范围内(球形)
    EntitySet visibleEntities_;          // 可见(视锥+遮挡)
    VisibilityController * visibility_;
    VisionController * vision_;
    bool shouldDropVision_;
    bool iterating_;
    bool iterationCancelled_;
};
```

### 16.2 两个集合的关系

```
                entitiesInVisionRange_ (球形范围)
               ┌─────────────────────────────────┐
               │                                 │
               │    ┌───────────────────────┐    │  visibleEntities_ (视锥+无遮挡)
               │    │  /                    │    │
               │    │ /  ◄ 可见区域(视锥)  │    │
               │    │/                      │    │
               │    ● (实体位置)            │    │
               │    │\                      │    │
               │    │ \                    │    │
               │    │  \                  │    │
               │    └───────────────────────┘    │
               │                                 │
               └─────────────────────────────────┘
```

- `entitiesInVisionRange_`:由 `VisionRangeTrigger` 维护,实体进入/离开球形范围时增删;
- `visibleEntities_`:由 `updateVisibleEntities` 定期计算,在 `entitiesInVisionRange_` 基础上做视锥+遮挡过滤。

### 16.3 updateVisibleEntities:核心视觉检测

```cpp
// entity_vision.cpp L258-401
const EntitySet & EntityVision::updateVisibleEntities( float seeingHeight,
        float yawOffset )
{
    EntitySet newVisible;
    EntitySet oldVisible;
    oldVisible.swap( visibleEntities_ );  // 保存旧集

    const ChunkSpace * cs = entity_.pChunkSpace();
    if (!cs) {
        ERROR_MSG( "EntityVision::updateVisibleEntities: "
                "Delegate space type is not supported\n" );
        return visibleEntities_;
    }

    Vector3 headPos = this->getDroppedPosition();
    headPos.y += seeingHeight;
    float yaw = entity_.direction().yaw + yawOffset;
    float visionAngle = (vision_ != NULL) ? vision_->visionAngle() : 1.f;

    Vector3 direction;
    direction.setPitchYaw( entity_.direction().pitch, yaw );

    // 遍历视觉范围内的每个实体
    for (EntitySet::iterator iter = entitiesInVisionRange_.begin();
            iter != entitiesInVisionRange_.end(); iter++)
    {
        Entity* pEntity = (*iter).get();
        bool canSee = false;

        if (EntityVision::canBeSeen( pEntity ))
        {
            EntityVision & ev = EntityVision::instance( *pEntity );
            Vector3 targetPos =
                ev.getDroppedPosition() + Vector3( 0, ev.visibleHeight(), 0 );

            for (int i = 0; i < 2; i++)
            {
                float dist = cs->collide( headPos, targetPos );
                // collide 返回 >0 表示有遮挡
                if (dist > 0.f)
                    continue;

                Vector3 entityDirection = targetPos - headPos;
                entityDirection.normalise();
                float dotProduct = direction.dotProduct( entityDirection );
                float angle = acosf( dotProduct );

                if (angle < visionAngle)
                {
                    canSee = true;
                    break;
                }
                // 第二次尝试用 3/4 高度的目标点
                targetPos = ev.getDroppedPosition() +
                    Vector3(0, 3.f / 4.f * ev.visibleHeight(), 0);
            }
        }

        if (canSee)
            newVisible.insert( pEntity );
    }

    // 差集比较,触发 onStartSeeing / onStopSeeing 回调
    // ... (merge 算法)

    visibleEntities_.swap( newVisible );
    return visibleEntities_;
}
```

算法步骤:
1. **保存旧集**:把 `visibleEntities_` 交换到 `oldVisible`;
2. **计算视点位置**:`getDroppedPosition() + seeingHeight`;
3. **遍历范围内实体**:对每个实体做视锥+遮挡检测;
4. **遮挡检测**:`cs->collide(headPos, targetPos)`,返回 >0 表示有障碍;
5. **视锥检测**:`angle = acos(direction · entityDirection)`,小于 `visionAngle` 则在视锥内;
6. **双高度尝试**:第一次用 `visibleHeight`,第二次用 `3/4 × visibleHeight`(避免因目标点恰好在墙后导致漏检);
7. **差集比较**:对 `oldVisible` 和 `newVisible` 做归并排序式的 diff,触发 `onStartSeeing` / `onStopSeeing`。

### 16.4 双高度尝试的设计意图

```
       目标实体
       │
       ├── visibleHeight (头顶,可能在墙后)
       │   └── 射线被遮挡 → 看不到
       │
       └── 3/4 × visibleHeight (头部稍下,可能露出)
           └── 射线无遮挡 → 看到这个实体
```

这是对几何精度不足的补偿:只用一个高度点可能因射线擦边导致"明明能看到却判定为看不到"。用两个高度点提高鲁棒性。

### 16.5 getDroppedPosition:位置下投

```cpp
// entity_vision.cpp L939-953
Position3D EntityVision::getDroppedPosition()
{
    if (!shouldDropVision_)
        return entity_.position();

    if (!isEqual( lastDropPosition_.x, entity_.position().x ) ||
        !isEqual( lastDropPosition_.z, entity_.position().z ))
    {
        lastDropPosition_ = entity_.getGroundPosition();
    }
    return lastDropPosition_;
}
```

- **shouldDropVision_**:当为 true 时,把视觉检测点下投到地面。这是因为 CellApp 中实体在 navPoly 上行走,navPoly 可能高于地面 2 米内,下投保证视觉检测基于地形高度;
- **缓存**:`lastDropPosition_` 在 X/Z 不变时缓存,避免每次都做 `getGroundPosition`(开销大)。

### 16.6 onStartSeeing / onStopSeeing 回调

```cpp
// entity_vision.cpp L346-378
iterating_ = true;
while (oldIter != oldEnd && newIter != newEnd)
{
    if ((*oldIter) < (*newIter))
    {
        this->callback( "onStopSeeing", oldIter->get() );
        ++oldIter;
    }
    else if ((*oldIter) > (*newIter))
    {
        this->callback( "onStartSeeing", newIter->get() );
        ++newIter;
    }
    else
    {
        // Still visible
        ++oldIter;
        ++newIter;
    }
}
// 处理尾部
iterating_ = false;
```

- **归并 diff**:`EntitySet` 是有序的(BW::set<Entity*>),用归并排序式的双指针遍历计算差集;
- **iterating_ 标志**:在回调过程中,脚本可能修改视觉控制器(如 `setVisionRange`),通过 `iterating_` 标志保护;
- **iterationCancelled_**:如果回调中取消了视觉控制器,设置 `iterationCancelled_`,结束后清理。

### 16.7 Python 接口

```python
# Entity.addVision(angle, range, seeingHeight, period=10, userArg=0)
e.addVision( math.pi/2, 30.0, 2.0, 10, 0 )  # 90度视锥, 30米, 眼高2米, 1秒更新

# Entity.addScanVision(angle, range, seeingHeight, amplitude, scanPeriod, timeOffset, updatePeriod=1, userArg=0)
e.addScanVision( math.pi/4, 30.0, 2.0, math.pi/3, 4.0, 0.0, 5, 0 )

# Entity.setVisionRange(angle, range)
e.setVisionRange( math.pi/3, 50.0 )

# Entity.entitiesInView()
visible = e.entitiesInView()  # 返回当前可见实体列表

# 回调
def onStartSeeing( self, entity ):
    print( "看到", entity.id )

def onStopSeeing( self, entity ):
    print( "看不到", entity.id )
```

### 16.8 可见性属性

```python
# Entity.canBeSeen (bool)
e.canBeSeen = False  # 隐身,其他实体看不到它

# Entity.visibleHeight (float)
e.visibleHeight = 1.8  # 可见高度1.8米

# Entity.seeingHeight (float)
e.seeingHeight = 1.7  # 眼高1.7米

# Entity.shouldDropVision (bool)
e.shouldDropVision = True  # 视觉点下投到地面
```

设置 `canBeSeen = True` 会自动创建 `VisibilityController`(DOMAIN_GHOST);设为 False 时删除。

---

## 十七、ManualAoI 手动 AOI

### 17.1 手动 AOI 的需求

标准 AoI 是**距离驱动**的:实体在半径内就进 AoI,不在就出。但有些场景需要**脚本显式控制**:
- 任务 NPC:无论距离多远,玩家总能看到任务 NPC;
- 队友:组队时强制把队友加入 AoI;
- 观战:观战模式观察远处战斗。

`ManualAoI` 机制允许脚本绕过距离触发器,显式把实体加入 / 移出 AoI。

### 17.2 实体类型的 IsManualAoI 标志

在实体定义 `.def` 文件中:

```
<root>
  <Animal>
    <isManualAoI>true</isManualAoI>
    ...
  </Animal>
</root>
```

只有 `isManualAoI=true` 的实体类型才能被 `addToManualAoI`。这是安全限制,防止脚本把任意类型(如 projectile)塞进 AoI。

### 17.3 addToManualAoI / removeFromManualAoI

```cpp
// witness.cpp L3182-3224
bool Witness::addToManualAoI( PyObjectPtr pEntityOrID )
{
    Entity * pEntity = Witness::findEntityFromPyArg( pEntityOrID.get() );

    if (pEntity == NULL)
        return false;

    if (pEntity->isDestroyed())
    {
        PyErr_Format( PyExc_ValueError,
            "Cannot add a destroyed entity (%d) to the manual-AoI",
            int(pEntity->id()) );
        return false;
    }

    EntityCache * pCache = aoiMap_.find( *pEntity );

    if (pCache && !pCache->isGone() && pCache->isManuallyAdded())
    {
        // Already manually added
        PyErr_Format( PyExc_ValueError, "%s %d is already in the AoI",
            pEntity->pType()->name(), pEntity->id() );
        return false;
    }

    this->addToAoI( pEntity, /* setManuallyAdded */ true );
    return true;
}
```

关键点:
1. **setManuallyAdded=true**:调用 `addToAoI` 时传入 `true`,设置 `EntityCache` 的 `MANUALLY_ADDED` 标志;
2. **与触发器共存**:一个实体可以同时被触发器加入(`ADDED_BY_TRIGGER`)和手动加入(`MANUALLY_ADDED`),两个标志独立;
3. **双重移除保护**:`removeFromAoI` 时,只有两个标志都清除后才真正移除(详见第 11.6 节)。

### 17.4 removeFromManualAoI

```cpp
// witness.cpp L3227-3240
bool Witness::removeFromManualAoI( PyObjectPtr pEntityOrID )
{
    Entity * pEntity = Witness::findEntityFromPyArg( pEntityOrID.get() );

    if (pEntity == NULL)
        return false;

    EntityCache * pCache = aoiMap_.find( *pEntity );

    if (pCache == NULL || !pCache->isManuallyAdded())
    {
        // Not in manual AoI
        return true;
    }

    this->removeFromAoI( pEntity, /* clearManuallyAdded */ true );
    return true;
}
```

- 调用 `removeFromAoI(clearManuallyAdded=true)`;
- 如果实体同时被触发器管理(`isAddedByTrigger()`),不会真正移除,只是清除 `MANUALLY_ADDED` 标志。

### 17.5 updateManualAoI:批量更新

```cpp
// witness.cpp L3110-3170
bool Witness::updateManualAoI( ScriptSequence list,
        bool ignoreNonManualAoIEntities )
{
    ManualAoIVisitor manualAoIVisitor( *this );

    // 第一遍:校验列表中的实体都是 isManualAoI
    for (ScriptSequence::size_type i = 0; i < list.size(); ++i)
    {
        Entity * pEntity = ...;
        if (!pEntity->pType()->description().isManualAoI())
        {
            if (ignoreNonManualAoIEntities)
                WARNING_MSG( ... );
            else
            {
                PyErr_Format( ... );
                return false;
            }
        }
    }

    // 第二遍:收集要添加的实体
    for (...)
    {
        if (pEntity->pType()->description().isManualAoI())
            manualAoIVisitor.addManualAoIEntity( pEntity );
    }

    // 遍历现有 AoI,移除不在新列表中的
    aoiMap_.visit( manualAoIVisitor );

    // 添加新列表中尚未在 AoI 的
    manualAoIVisitor.addNewManualAoIEntities();

    return true;
}
```

### 17.6 ManualAoIVisitor:访客模式

```cpp
// witness.cpp L3024-3093
class ManualAoIVisitor : public EntityCacheVisitor
{
public:
    ManualAoIVisitor( Witness & witness ) : witness_( witness ) {}

    virtual void visit( const EntityCache & cache )
    {
        Entity * pEntity = const_cast< Entity * >( cache.pEntity().get() );

        EntitySet::iterator iter = manualAoIEntities_.find( pEntity );

        if (iter != manualAoIEntities_.end())
        {
            // 在新列表中,不需要重新添加
            manualAoIEntities_.erase( iter );
        }
        else if (!cache.isGone() &&
                pEntity->pType()->description().isManualAoI())
        {
            // 不在新列表中,且之前是 manual,移除
            witness_.removeFromAoI( pEntity, /* clearManuallyAdded */ true );
        }
    }

    void addManualAoIEntity( Entity * pEntity )
    {
        manualAoIEntities_.insert( pEntity );
    }

    void addNewManualAoIEntities()
    {
        for (EntitySet::iterator iter = manualAoIEntities_.begin();
                iter != manualAoIEntities_.end(); ++iter )
        {
            witness_.addToAoI( *iter, /* setManuallyAdded */ true );
        }
    }

private:
    EntitySet manualAoIEntities_;
    Witness & witness_;
};
```

算法:
1. **预收集**:把新列表所有实体放入 `manualAoIEntities_`;
2. **visit 遍历现有 AoI**:对每个 EntityCache:
   - 如果在新列表中:从 `manualAoIEntities_` 移除(不需要重新添加);
   - 如果不在新列表中,且是 manual 类型:调 `removeFromAoI`;
3. **添加剩余**:`manualAoIEntities_` 中剩下的就是"新列表有但当前 AoI 没有"的实体,逐个添加。

### 17.7 entitiesInManualAoI

```cpp
// witness.cpp L3505-3520
ScriptList Witness::entitiesInManualAoI() const
{
    ScriptList list = ScriptList::create();

    class ManualInAoIVisitor : public EntityCacheVisitor
    {
    public:
        ScriptList list_;
        virtual void visit( const EntityCache & cache )
        {
            if (cache.isManuallyAdded() && !cache.isGone())
            {
                list_.append( ScriptObject( cache.pEntity()->pythonObject(),
                    ScriptObject::FROM_BORROWED_REFERENCE ) );
            }
        }
    };

    ManualInAoIVisitor visitor;
    visitor.list_ = list;
    aoiMap_.visit( visitor );

    return visitor.list_;
}
```

返回当前 AoI 中所有 `isManuallyAdded()` 的实体列表。

### 17.8 Python 接口

```python
# 添加单个实体到手动 AoI
self.addToManualAoI( entityOrID )

# 从手动 AoI 移除
self.removeFromManualAoI( entityOrID )

# 批量更新(传入列表)
self.updateManualAoI( [entity1, entity2, entity3], ignoreNonManualAoIEntities=True )

# 查询当前手动 AoI 中的实体
manualEntities = self.entitiesInManualAoI()
```

### 17.9 MobileRangeListNode:AOI Root 偏移

除了手动添加实体,Witness 还支持**偏移 AoI 中心点**:

```cpp
// witness.cpp L1439-1472
void Witness::setAoIRoot( float x, float z )
{
    if (this->isAoIRooted())
    {
        // 已有 root,只需更新位置
        static_cast< MobileRangeListNode * >( pAoIRoot_ )->setPosition( x, z );
        return;
    }

    // 创建独立的 AoI root 节点
    RangeListNode * pNewAoIRoot = new MobileRangeListNode( x, z,
        RangeListNode::FLAG_NO_TRIGGERS,
        RangeListNode::FLAG_NO_TRIGGERS );

    const_cast< RangeList & >( entity().space().rangeList() ).add( pNewAoIRoot );

    RangeListNode * pOldAoIRoot = this->replaceAoITrigger( pNewAoIRoot );
    MF_ASSERT( pOldAoIRoot == entity().pRangeListNode() );
}
```

- **MobileRangeListNode**:独立的 RangeListNode,位置由 `setPosition(x, z)` 控制,不绑定实体;
- **FLAG_NO_TRIGGERS**:这个节点既不"想"也不"制造"任何跨越事件,纯粹作为 AoITrigger 的中心;
- **应用场景**:观察远处、上帝视角、监控摄像头等。

### 17.10 replaceAoITrigger:切换 AoI 中心

```cpp
// witness.cpp L1783-1841
RangeListNode * Witness::replaceAoITrigger( RangeListNode * pNewAoIRoot )
{
    Entity::callbacksPermitted( false );

    RangeListNode * pOldAoIRoot = pAoIRoot_;

    // 1. 标记所有 EntityCache 为 isInAoIOffload 和 isGone
    AoIPreparer preparer;
    aoiMap_.mutate( preparer );

    // 2. 从旧 root 移除 trigger
    if (this->isAoIRooted())
        static_cast< MobileRangeListNode * >( pAoIRoot_ )->delTrigger( pAoITrigger_ );
    else
        this->entity().delTrigger( pAoITrigger_ );

    // 3. 切换到新 root
    pAoIRoot_ = pNewAoIRoot;

    // 4. 销毁旧 trigger(不收缩,避免回调)
    bw_safe_delete( pAoITrigger_ );

    // 5. 创建新 trigger(会扩张,重新加入 AoI)
    pAoITrigger_ = new AoITrigger( *this, pAoIRoot_, aoiRadius_ );

    // 6. 挂载到新 root
    if (this->isAoIRooted())
        static_cast< MobileRangeListNode * >( pAoIRoot_ )->addTrigger( pAoITrigger_ );
    else
        entity().addTrigger( pAoITrigger_ );

    // 7. 清理:仍在 offload 状态的实体触发 onLeftAoI
    AoICleaner cleaner( this->entity() );
    aoiMap_.mutate( cleaner );

    Entity::callbacksPermitted( true );

    return pOldAoIRoot;
}
```

切换流程:
1. **AoIPreparer**:标记所有 EntityCache 为"offload 状态"(isInAoIOffload=true, isGone=true);
2. **删除旧 trigger**:不收缩(避免触发 onLeaveAoI);
3. **创建新 trigger**:扩张时触发 onEnterAoI。如果实体在新 AoI 内,`addToAoI` 会被调用,匹配"offload 状态"的实体复活;
4. **AoICleaner**:仍然处于 offload 状态(没被新 trigger 匹配到)的实体,触发 `onLeftAoI`。

---

## 十八、性能分析

### 18.1 CPU 开销分析

#### 18.1.1 Shuffle 开销

每个实体移动时,RangeList 的 shuffle 是 O(N) 操作(N 是同 X 或同 Z 坐标段的节点数):

```
shuffleX:  遍历 [oldX→newX] 区间,对每个节点检查 flags
shuffleZ:  遍历 [oldZ→newZ] 区间,对每个节点检查 flags
```

最坏情况:N 个实体都在同一 X 坐标,shuffle 遍历全部 N 个。但实际中,由于实体分散在空间内,N 通常是 O(sqrt(K))(K 是 AOI 内实体数)。

#### 18.1.2 per-tick 开销

每个 Witness 每 tick(100ms):
1. 遍历 entityQueue_(堆操作,O(log N) 每个元素);
2. 对每个发送的实体调 sendQueueElement(打包 + 带宽检查);
3. 对剩余实体更新 priority。

总 CPU 约正比于:每 tick 发送的实体数 × log(AoI 实体总数)。

#### 18.1.3 视觉检测开销

VisionController 每 `updatePeriod_` tick 触发一次:
- 遍历 `entitiesInVisionRange_`(M 个);
- 对每个做 1-2 次 `collide`(射线检测);
- `collide` 是 O(log T + H)(T 是 Chunk 三角形数,H 是射线穿过的 chunk 数)。

如果 M=50、H=5,每秒约 50×5 = 250 次三角形测试 per entity。100 个 NPC 就是 25000 次/秒。

### 18.2 内存开销分析

#### 18.2.1 每实体开销

| 组件 | 大小 | 说明 |
|------|-----|------|
| EntityRangeListNode | ~80 字节 | 含 prev/next X/Z 指针 |
| EntityCache | ~120 字节 | 含 EntityCache 数据 + 堆位置 |
| Entity 实例 | 数百~数千字节 | 含属性、Python 对象 |

#### 18.2.2 每 Witness 开销

```cpp
// witness.hpp 成员
IDAlias freeAliases_[256];           // 256 字节
EntityCacheMap aoiMap_;              // 红黑树,每节点约 50 字节
KnownEntityQueue entityQueue_;       // vector<EntityCache*>,8 字节/元素
int8* pPrioritised_;                 // 标志位数组
// ...
```

约 1KB 基础 + N × 120 字节(N 是 AoI 内实体数)。

### 18.3 网络开销分析

#### 18.3.1 每 tick 下行

```
bundle.size() ≈ Σ(发送实体的消息大小)
```

平均:
- 位置更新:20-30 字节(含 alias、位置、方向、LOD);
- 属性增量:5-50 字节(取决于变化多少属性)。

500 米半径默认 AOI 内约 30 个实体,每 tick 发送约 5 个(高频):
- 5 × 30 = 150 字节/tick;
- 10 tick/秒 → 1.5 KB/秒/玩家。

1000 玩家 = 1.5 MB/秒 下行(可接受)。

#### 18.3.2 拥塞处理

```cpp
// witness.cpp L2786-2789
const float throttle = CellApp::instance().emergencyThrottle();
const int desiredPacketSize = int(maxPacketSize_ * throttle) -
        bandwidthDeficit_ + bundle.size();
```

- `emergencyThrottle()` 在 CellApp 过载时降低(如 0.5),减半发送量;
- `bandwidthDeficit_` 累积赤字,下 tick 补偿。

### 18.4 大规模场景基准

假设场景:1000 玩家 + 10000 NPC,平均 AOI 半径 500 米,密度 0.1 实体/平方米。

| 指标 | 估算值 | 说明 |
|------|-------|------|
| 每 Witness AoI 实体数 | ~80 | π × 500² × 0.1 ≈ 78540,但实际可见少 |
| 每 tick 发送实体 | ~10 | 受 MAX_PRIORITY_DELTA 限制 |
| 每 tick CPU (per Witness) | ~0.1ms | 堆操作 + 序列化 |
| 总 CPU (1000 Witness) | ~100ms | 占满一个 tick |
| 每 tick 下行 (per Witness) | ~300 字节 | 10 实体 × 30 字节 |
| 总下行 (1000 Witness) | ~3 MB/s | 可接受 |

### 18.5 优化建议

#### 18.5.1 减小 AOI 半径

500 米是默认值,但许多 MMO 实际只需要 200-300 米:
```python
self.setAoIRadius( 250.0, 30.0 )  # 250米半径,30米滞回
```
面积减少 75%,实体数减少 75%。

#### 18.5.2 调整 LOD 距离

```xml
<!-- 在 .def 文件中 -->
<Volatile>
  <position>
    <loddist>50</loddist>     <!-- 50米内全精度 -->
    <lodpriority>0.5</lodpriority>
  </position>
</Volatile>
```

远距离实体发送低精度位置(2 字节 vs 12 字节)。

#### 18.5.3 调整 witnessUpdateMaxPriorityDelta

减小该值(如 3.f)使每 tick 发送更少实体,但近距离实体更频繁更新:
```xml
<!-- cellappmgr.xml -->
<witnessUpdateMaxPriorityDelta>3.0</witnessUpdateMaxPriorityDelta>
```

#### 18.5.4 分散 NPC 到不同 Cell

利用 BSP 切分把高密度 NPC 区域分散到多个 CellApp,每个 CellApp 只处理一部分 NPC 的 shuffle。

#### 18.5.5 VisionController 节流

```python
# 默认 updatePeriod=10(1秒),对静态 NPC 用更长周期
npc.addVision( math.pi/2, 30, 2, 30 )  # 30 tick = 3秒更新
```

---

## 十九、边界情况与故障处理

### 19.1 传送(Teleport)

传送是 AOI 的最大挑战:实体位置瞬间跳变,可能跨越很大距离。

#### 19.1.1 实体的传送流程

```cpp
// entity.cpp 中 teleportTo 等
void Entity::teleport( ... )
{
    // 1. 从旧位置 RangeList 移除
    this->delFromRangeList();
    // 2. 更新位置
    pos_ = newPos;
    // 3. 重新加入 RangeList
    this->addToRangeList();
    // 4. 触发 shuffle(实际不 shuffle,因为直接删了再加)
    // 5. 对所有 trigger 调 modTrigger
    this->modAllTriggers();
}
```

`modTrigger` 会:
- 旧位置收缩 trigger(触发 onLeaveAoI);
- 更新到新位置;
- 新位置扩张 trigger(触发 onEnterAoI)。

#### 19.1.2 Witness 的传送

```cpp
// witness.cpp 中通过 setAoIRadius 或位置变化触发
// 实际是 Entity::teleport 后 updateInternalsForNewPosition 调用
```

Witness 自己的 AoITrigger 会经历一次收缩+扩张,产生大量 onLeaveAoI / onEnterAoI。

#### 19.1.3 传送的副作用

- **IDAlias 全部失效**:因为 AoI 实体集变了,但 Witness 通过 offload 机制保持已分配的 alias;
- **enterPending 风暴**:新进入的实体都进入 ENTER_PENDING 状态,等待客户端 requestEntityUpdate;
- **onEnteredAoI / onLeftAoI 大量回调**:可能阻塞 tick。BigWorld 用 `Entity::callbacksPermitted(false)` 在关键路径禁用回调,事后批量触发。

### 19.2 AOI 半径动态变化

```cpp
// witness.cpp L2109-2147
void Witness::setAoIRadius( float radius, float hyst )
{
    radius = std::max( 0.1f, radius );  // 强制最小 0.1 米

    if (aoiRadius_ > CellAppConfig::maxAoIRadius())
    {
        WARNING_MSG( "Clamping %u's AoI radius (%.1f) to max (%.1f)",
            entity_.id(), aoiRadius_, CellAppConfig::maxAoIRadius() );
        aoiRadius_ = CellAppConfig::maxAoIRadius();
    }

    pAoITrigger_->setRange( aoiRadius_ );

    // 通过 modTrigger 让 trigger 重新 shuffle
    if (this->isAoIRooted())
        static_cast< MobileRangeListNode * >( pAoIRoot_ )->modTrigger( pAoITrigger_ );
    else
        entity_.modTrigger( pAoITrigger_ );
}
```

- **最小 0.1**:防止 0 半径导致 RangeList 异常;
- **maxAoIRadius 配置**:防止脚本设置过大半径导致性能问题;
- **modTrigger**:触发器先收缩到旧半径(触发 onLeaveAoI),再扩张到新半径(触发 onEnterAoI)。

### 19.3 实体密集区域

当大量实体聚集在小范围内:
- RangeList 中同坐标节点数暴增,shuffle 开销上升;
- AoITrigger 一次性扩张可能触发几百个 onEnterAoI。

#### 19.3.1 BigWorld 的应对

1. **EntityRangeListNode 的 RANGE_LIST_ORDER_ENTITY=100**:同坐标实体的插入顺序固定,不会因排序抖动;
2. **shuffle 用 wasInXRange / isInXRange**:防止同坐标抖动导致重复触发;
3. **Witness::update 的 MAX_PRIORITY_DELTA**:限制每 tick 发送实体数,即使 AoI 暴增也只发送优先级最高的几个。

### 19.4 Witness 所在实体死亡

Witness 所在实体销毁时:
```cpp
// witness.cpp L605-645 (析构)
Witness::~Witness()
{
    // 1. 删除 AoITrigger(不收缩,避免回调)
    bw_safe_delete( pAoITrigger_ );

    // 2. 清空 AoI map
    // (EntityCache 由 aoiMap_ 析构自动清理)
}
```

`AoITrigger` 析构时调 `removeWithoutContracting`,不触发 onLeaveAoI,因为实体已经在销毁中。

### 19.5 CellApp 宕机与 offload

当持有 Real 的 CellApp 宕机:
1. CellAppMgr 检测到 death(bmachined 通知);
2. 启动 `CellAppDeathHandler`,通知所有相关 CellApp;
3. Ghost 升级为 Real(在其他 CellApp 上);
4. 新 Real 通过 `writeOffloadData` / `readOffloadData` 恢复 Witness 状态:
   - IDAlias 分配状态;
   - AoI 内实体列表(部分,通过 EntityCache 序列化)。

### 19.6 跨 Cell 边界

实体跨 Cell 边界时:
1. 旧 Cell 的 Entity 实例 ghost 到新 Cell;
2. Real 切换到新 Cell;
3. Witness 的 AoITrigger 在新 Cell 的 RangeList 中重新建立。

这个过程中:
- **EntityCache 状态保留**:通过 offload 机制;
- **onEnteredAoI 不重复触发**:offload 标记防止重复;
- **可能丢失部分实体的更新**:在切换瞬间,部分消息可能丢失(因为 Real 切换有延迟)。

### 19.7 极端坐标

```cpp
// range_list_node.hpp
float RangeListNode::x() const { ... }
float RangeListNode::z() const { ... }
```

BigWorld 的 RangeList 用 float 坐标排序。float 精度问题:
- 大坐标(>100000)时,float 精度下降到 1 米;
- 同坐标比较可能因精度误差导致顺序异常。

代码中用 `volatile float` 强制 32 位精度,避免 x87 扩展精度(80位)导致的跨平台不一致:

```cpp
// range_list_node.cpp L44-128 (shuffleX)
volatile float oldX = this->x();
volatile float newX = pOtherNode->x();
// volatile 防止编译器用 80 位寄存器,导致不同机器上的排序不一致
```

### 19.8 客户端断线重连

客户端断线后重连:
1. BaseApp 检测到客户端断连,通知 CellApp;
2. CellApp 的 Witness 进入"挂起"状态(不发数据,但保留 AoI);
3. 客户端重连后,BaseApp 重新建立通道;
4. Witness 恢复发送,可能触发一次"全量同步"(因为客户端状态丢失)。

### 19.9 IDAlias 耗尽

当 AoI 内有 256+ 个有 volatile 数据的实体时,IDAlias 耗尽:
- 后续实体用 `NO_ID_ALIAS`,消息用 4 字节 EntityID;
- 性能下降但功能正常;
- 实际中很少发生(AOI 内 256+ 实体已经超载)。

---

## 二十、与其他引擎 AOI 方案对比

### 20.1 九宫格(Grid-based)

经典 MMO(如早期 WoW、传奇)用九宫格:
- 地图划分为固定大小的格子(如 50×50 米);
- 实体的 AOI = 所在格 + 8 邻格;
- 移动跨格时触发进/出 AOI。

| 维度 | 九宫格 | BigWorld RangeList |
|------|-------|-------------------|
| 数据结构 | 二维数组 | 双轴有序链表 |
| 查询 AOI 实体 | 遍历 9 格(O(N)) | 触发器自动维护(O(1) per event) |
| 动态半径 | 难(需扩展邻格数) | 容易(setRange) |
| 跨格抖动 | 严重(边界来回跨越) | 轻微(有滞回) |
| 内存 | 低(数组) | 中(每实体 4 个链表节点) |
| 实现复杂度 | 低 | 高 |

### 20.2 四叉树(Quadtree)

Unity ECS、Unreal 的 SpatialHash 用四叉树:
- 递归划分空间;
- 查询时从根遍历到叶子;
- 适合静态场景(如 RTS)。

| 维度 | 四叉树 | BigWorld RangeList |
|------|-------|-------------------|
| 查询效率 | O(log N) | O(1) per event(增量维护) |
| 动态更新 | 重新插入(O(log N)) | shuffle(O(N) per axis,但实际小) |
| 跨进程 | 难(树需要序列化) | 容易(链表节点独立) |
| 适合 MMO | 否(动态实体多) | 是(为 MMO 设计) |

### 20.3 六边形网格(Hexagonal Grid)

部分 SLG 用六边形:
- 比 9 宫格更自然(6 邻 vs 8 邻);
- 距离计算更均匀。

BigWorld 不支持六边形,因为:
- MMO 不需要离散网格(实体位置是连续的);
- RangeList 的连续坐标比离散网格更灵活。

### 20.4 Unity ECS + DOTS

Unity 2018+ 的 ECS 架构:
- 用 `EntityQuery` 查询符合组件的实体;
- 空间查询用 `SpatialHash` 或 `BoundingVolume`;
- 数据导向,缓存友好。

| 维度 | Unity ECS | BigWorld |
|------|---------|---------|
| 架构 | 数据导向(AoS) | 面向对象 | 
| 空间查询 | 框架不内置,需自己实现 | RangeList 内置 |
| 网络同步 | 需自己写 | Witness 内置 |
| 分布式 | 不支持(单进程) | 原生支持(多 CellApp) |
| 适合场景 | 单机/小规模联机 | MMO |

### 20.5 Unreal Engine

Unreal 用 `Actors` + `SphereOverlap`:
- 每帧查询(或定时)球形范围内的 Actor;
- 用 `Physics Engine` 的 broadphase;
- 不适合大量动态实体。

| 维度 | Unreal | BigWorld |
|------|-------|---------|
| 查询方式 | 每帧 polling | 事件驱动(push) |
| CPU 开销 | 高(每帧全量查询) | 低(增量维护) |
| 网络同步 | 需自己写 | Witness 内置 |
| 分布式 | 不支持 | 原生支持 |

### 20.6 BigWorld 的独特优势

1. **事件驱动**:RangeTrigger 自动维护,不需要每帧查询;
2. **滞回防抖**:wasInXRange/isInXRange 防止边界抖动;
3. **分布式原生**:RangeList 每个 CellApp 独立,Ghost 机制跨进程;
4. **Pull 模型**:Witness 的优先级堆 + 带宽控制,适合异构网络;
5. **IDAlias**:1 字节短标识,大幅降低带宽;
6. **ManualAoI**:脚本显式控制,支持任务 NPC、组队等场景;
7. **MobileRangeListNode**:AoI 中心可独立于实体位置,支持观战、监控。

### 20.7 BigWorld 的劣势

1. **实现复杂**:RangeList + Shuffle + Trigger 体系庞大,学习曲线陡;
2. **单线程**:每个 CellApp 单线程,无法利用多核(需多 CellApp 水平扩展);
3. **float 精度**:大世界坐标精度问题(需分 Space);
4. **无碰撞检测集成**:AOI 是纯距离,遮挡需 VisionController 单独实现;
5. **Python 脚本开销**:回调(onEnterAoI 等)走 Python,高频时性能差。

---

## 二十一、配置参数详解

### 21.1 cellappmgr.xml 配置

| 配置项 | 默认值 | 说明 |
|--------|-------|------|
| `defaultAoIRadius` | 500.0 | 新建 Witness 的默认 AOI 半径(米) |
| `defaultAoIHyst` | 5.0 | 默认滞回距离(米) |
| `maxAoIRadius` | 1000.0 | Witness AOI 半径上限(防脚本设过大) |
| `witnessUpdateMaxPriorityDelta` | 5.0 | 优先级堆的最大 delta(限制每 tick 发送范围) |
| `witnessUpdateDefaultMinDelta` | 1.0 | AoIUpdateScheme 默认最小 delta(0米处) |
| `witnessUpdateDefaultMaxDelta` | 101.0 | AoIUpdateScheme 默认最大 delta(AOI 边缘) |
| `witnessUpdateDeltaGrowthThrottle` | 1.125 | delta 增长节流(指数增长的底数) |

### 21.2 实体定义(.def)配置

```xml
<root>
  <Player>
    <!-- Volatile 属性:位置、方向、yaw/pitch/roll -->
    <Volatile>
      <position>
        <priority>0</priority>      <!-- 0=总是发送,1=高优先,2=低 -->
        <lodDist>100</lodDist>       <!-- 100米内全精度 -->
      </position>
      <yaw>
        <priority>1</priority>
        <lodDist>50</lodDist>
      </yaw>
    </Volatile>

    <!-- 是否可加入手动 AoI -->
    <isManualAoI>false</isManualAoI>

    <!-- 客户端是否需要详细位置(影响 isAlwaysDetailed) -->
    <shouldSendDetailedPosition>true</shouldSendDetailedPosition>

    <!-- 是否可在客户端创建 -->
    <canBeOnClient>true</canBeOnClient>
  </Player>
</root>
```

### 21.3 AoIUpdateScheme 配置

```xml
<!-- 在 .def 或 server.xml -->
<AoIUpdateScheme name="default">
  <delta distance="0"      value="1.0" />
  <delta distance="100"    value="5.0" />
  <delta distance="300"    value="50.0" />
  <delta distance="500"    value="101.0" />
</AoIUpdateScheme>
```

- `distance`:距离(米);
- `value`:该距离的 delta 值;
- 之间线性插值。

### 21.4 Witness Python 属性

```python
# AOI 半径(读写)
radius = self.aoiRadius
self.aoiRadius = 300.0  # 触发 setAoIRadius

# AOI 滞回(读写)
hyst = self.aoiHyst

# AOI 中心点(读写)
# None=跟随实体位置; (x,z)=独立中心
self.aoiRoot = (1000.0, 2000.0)
self.aoiRoot = None  # 恢复跟随实体

# 是否为 root 模式
if self.isAoIRooted:
    ...
```

### 21.5 关键阈值速查

| 阈值 | 值 | 含义 |
|------|-----|------|
| `NO_ID_ALIAS` | 0xff (255) | 保留的 IDAlias 值 |
| `MAX_LOD_LEVELS` | 4 | EntityCache 最多 4 级 LOD |
| `DEFAULT_AOI_RADIUS` | 500.0 | 默认 AOI 半径 |
| `RANGE_LIST_ORDER_HEAD` | 0 | 链表头节点顺序值 |
| `RANGE_LIST_ORDER_ENTITY` | 100 | 实体节点顺序值 |
| `RANGE_LIST_ORDER_LOWER_BOUND` | 190 | 触发器下界顺序值 |
| `RANGE_LIST_ORDER_UPPER_BOUND` | 200 | 触发器上界顺序值 |
| `RANGE_LIST_ORDER_TAIL` | 0xffff | 链表尾节点顺序值 |
| `NOT_UPDATABLE` | 0 | EntityCache 不可更新状态 |
| `CLIENT_STATE_NONE` | 0 | EntityCache 客户端无状态 |

---

## 二十二、调试与可观测性

### 22.1 dumpAoI

```cpp
// witness.cpp L2153+
void Witness::dumpAoI()
{
    DUMPAOI_MSG( "Dumping AoI for entity %u. Seen = %d "
            "AoIMap = %u AoIRadius = %6.3f AoIHyst = %6.3f\n",
        entity_.id(), entityQueue_.size(), aoiMap_.size(),
        aoiRadius_, aoiHyst_ );

    // 遍历 entityQueue_ 打印每个 EntityCache
    for (KnownEntityQueue::iterator iter = entityQueue_.begin();
            iter != entityQueue_.end(); ++iter)
    {
        EntityCache * pCache = *iter;
        DUMPAOI_MSG( "  id=%u alias=%d state=%s priority=%.2f dist=%.1f\n",
            pCache->pEntity()->id(), pCache->idAlias(),
            pCache->stateString(), pCache->priority(),
            (pCache->pEntity()->position() - entity_.position()).length() );
    }
}
```

调用方式:
```
# 通过 watcher
/bw.dumpAoI <entityID>

# 或在脚本中
self.dumpAoI()
```

### 22.2 debugRangeList

```cpp
// space.cpp
void Space::debugRangeList()
{
    // 遍历 X 轴链表,打印每个节点的 x、type、flags
    // ...
}
```

输出示例:
```
X-axis range list:
  HEAD (0.0)
  Entity 1001 (x=100.5, wants=3, makes=3)
  LowerBound 1002 (x=120.0, wants=3, makes=0)
  UpperBound 1002 (x=160.0, wants=3, makes=0)
  Entity 1003 (x=150.0, wants=3, makes=3)
  TAIL (100000.0)
```

### 22.3 Watcher 变量

```
/bw.witness.aoiRadius       # 当前 AOI 半径
/bw.witness.aoiSize        # AoI 内实体数
/bw.witness.bandwidthDeficit  # 带宽赤字
/bw.witness.downstreamBytes # 下行字节数(累计)
/bw.witness.downstreamPackets  # 下行包数(累计)
```

### 22.4 Profile 标签

```cpp
SCOPED_PROFILE( SHUFFLE_TRIGGERS_PROFILE );  // 触发器 shuffle
SCOPED_PROFILE( SHUFFLE_AOI_TRIGGERS_PROFILE );  // AoI 触发器 shuffle
SCOPED_PROFILE( CLIENT_UPDATE_PROFILE );  // Witness::update
AUTO_SCOPED_PROFILE( "visionUpdate" );  // VisionController::update
```

通过 `bwprofile` 工具查看各阶段 CPU 占比。

### 22.5 DEBUG_VISION 宏

```cpp
// entity_vision.hpp L96-98
#ifdef DEBUG_VISION
    EntitySet& seenByEntities()  { return seenByEntities_; }
#endif
```

开启 `DEBUG_VISION` 后:
- `EntityVision` 维护 `seenByEntities_`(谁看到了我);
- `triggerVisionEnter/Leave` 增加断言和调试输出;
- 可以用 `seenByEntities()` 查询"谁在看我"。

### 22.6 调试技巧

1. **实体不进 AoI**:
   - 检查 `canBeOnClient` 是否为 true;
   - 检查实体是否在 RangeList 中(`debugRangeList`);
   - 检查 AoITrigger 的 range 是否正确;

2. **实体不离开 AoI**:
   - 检查 `isManuallyAdded` 标志;
   - 检查 `isGone` 是否设置;
   - 检查 `removeFromAoI` 是否被调用;

3. **IDAlias 不分配**:
   - 检查实体的 volatileInfo 是否 hasVolatile;
   - 检查 `numFreeAliases_` 是否为 0;

4. **视觉检测不准**:
   - 检查 `seeingHeight` 和 `visibleHeight`;
   - 检查 `shouldDropVision`;
   - 用 `DEBUG_VISION` 宏开启详细日志。

---

## 二十三、总结与最佳实践

### 23.1 AOI 与 Witness 系统设计哲学总结

BigWorld 的 AOI 系统体现了几个核心设计哲学:

1. **事件驱动 > 轮询**:RangeTrigger 自动维护可见集,不需要每帧查询;
2. **增量维护 > 全量重建**:shuffle 算法在移动时增量更新,只处理变化的部分;
3. **分层抽象**:RangeList(几何) → RangeTrigger(触发) → Witness(网络) → VisionController(逻辑),各层职责清晰;
4. **带宽优先**:Pull 模型 + IDAlias + LOD + 优先级堆,多管齐下降低带宽;
5. **容错与恢复**:offload 机制保证状态可迁移,CellApp 宕机可恢复;
6. **滞回防抖**:wasInXRange/isInXRange 双值检查,防止边界抖动。

### 23.2 最佳实践

#### 23.2.1 AOI 半径选择

- **战斗为主**:200-300 米(减小 CPU 和带宽);
- **社交为主**:400-500 米(默认,平衡);
- **探索为主**:600-800 米(增加沉浸感,但注意性能);

```python
# 根据场景动态调整
def onEnterCombat(self):
    self.setAoIRadius( 250.0, 30.0 )

def onLeaveCombat(self):
    self.setAoIRadius( 500.0, 50.0 )
```

#### 23.2.2 NPC 视觉优化

```python
# 静态 NPC:低频更新
guard.addVision( math.pi/3, 30, 2, 30 )  # 3秒更新

# 巡逻 NPC:扫描视觉 + 中频更新
patrol.addScanVision( math.pi/4, 25, 2, math.pi/4, 8.0, 0, 10 )

# 高警觉 NPC:大视锥 + 高频
sentry.addVision( math.pi/2, 40, 2.5, 5 )  # 0.5秒更新
```

#### 23.2.3 Manual AoI 使用

```python
# 组队:把队友强制加入 AoI
def onJoinTeam(self, teamMembers):
    self.updateManualAoI( teamMembers, ignoreNonManualAoIEntities=True )

# 离队:移除所有手动 AoI
def onLeaveTeam(self):
    self.updateManualAoI( [], ignoreNonManualAoIEntities=True )
```

注意:实体类型必须在 `.def` 中设置 `<isManualAoI>true</isManualAoI>`。

#### 23.2.4 大世界分 Space

- 每个 Space 独立的 RangeList;
- 跨 Space 传送时 AoI 重建;
- 用 `shouldDropVision` 处理地形高度差。

#### 23.2.5 监控与告警

- 监控 `bandwidthDeficit`:持续 > 0 说明带宽不足;
- 监控 `aoiSize`:过大说明 AOI 半径太大或密度过高;
- 监控 `witnessUpdate` CPU:过高说明需要减小 MAX_PRIORITY_DELTA。

### 23.3 常见陷阱

1. **AoI 半径过大**:1000+ 米半径会导致 AoI 内数百实体,CPU 和带宽暴增;
2. **回调中修改 AoI**:`onEnteredAoI` 中调 `setAoIRadius` 可能重入,用 `callbacksPermitted` 保护;
3. **忽略滞回**:设 `hyst=0` 会导致边界抖动,实体频繁进出 AoI;
4. **VisionController 滥用**:每个 NPC 都加视觉控制器,1000 个 NPC × 1秒更新 = 1000 次/秒 collide;
5. **ManualAoI 不清理**:队友离队后忘记 `removeFromManualAoI`,导致 AoI 永久膨胀;
6. **Python 回调慢**:`onEnteredAoI` 中做重逻辑(如数据库查询)会阻塞 tick。

### 23.4 与 Ghost 机制的关系

AOI 与 Ghost 是**正交**的两个机制:
- **Ghost**:跨 CellApp 的实体副本,用于属性同步;
- **AOI**:决定哪些实体的数据发给客户端。

一个实体可以:
- 在 AoI 内但不是 Ghost(同 CellApp 的 Real);
- 是 Ghost 但不在 AoI(在 AOI 范围外);
- 两者都是(跨 CellApp 的可见实体);
- 两者都不是(同 CellApp 的不可见实体)。

### 23.5 总结

BigWorld 的 AOI/Witness 系统是 MMO 引擎中最复杂的子系统之一,核心由:
- **RangeList**:双轴有序链表,提供 O(1) 的邻居查询;
- **RangeTrigger**:上下界触发器对,自动检测实体进出;
- **Witness**:优先级堆 + 带宽控制 + Pull 模型;
- **EntityCache**:per-entity 状态机;
- **IDAlias**:带宽优化;
- **VisionController**:视锥+遮挡的游戏逻辑视觉;

组成。理解这套机制,是开发高性能 MMO 的关键。

---

## 附录 A:关键文件索引

### A.1 核心源文件

| 文件路径(相对 `programming/bigworld/server/cellapp/`) | 行数 | 职责 |
|--------------------------------------------------------|------|------|
| `witness.hpp` | ~320 | Witness 类声明 |
| `witness.cpp` | ~3628 | Witness 核心实现(init/update/addToAoI/IDAlias 等) |
| `range_list_node.hpp` | ~145 | RangeListNode 基类 + Flags/Order 枚举 |
| `range_list_node.cpp` | ~230 | shuffleX/shuffleZ/removeFromRangeList/insertBeforeX/Z |
| `entity_range_list_node.hpp` | — | EntityRangeListNode(实体节点) |
| `entity_range_list_node.cpp` | — | 实体节点实现 |
| `range_trigger.hpp` | ~210 | RangeTrigger 类声明 |
| `range_trigger.cpp` | ~660 | RangeTrigger 实现(wasInXRange/crossedXEntity/insert/remove) |
| `entity_cache.hpp` | ~261 | EntityCache 类 + flags 枚举 + EntityCacheMap |
| `entity_cache.ipp` | — | EntityCache 内联实现(updatePriority/resetClientState) |
| `entity_cache.cpp` | — | EntityCache 实现(updateDetailLevel/addChangedProperties) |
| `aoi_update_schemes.hpp` | — | AoIUpdateScheme / AoIUpdateSchemes |
| `aoi_update_schemes.cpp` | — | AoIUpdateScheme::apply / AoIUpdateSchemes::init |
| `cell_range_list.hpp` | — | RangeList 类(first_/last_ terminators) |
| `cell_range_list.cpp` | — | RangeList 实现 |
| `cell_range_list.ipp` | — | RangeList 内联 |

### A.2 视觉系统文件

| 文件路径 | 行数 | 职责 |
|---------|------|------|
| `vision_controller.hpp` | 60 | VisionController 类声明 |
| `vision_controller.cpp` | 341 | VisionController + VisionRangeTrigger 实现 |
| `scan_vision_controller.hpp` | 39 | ScanVisionController(扫描视觉) |
| `visibility_controller.hpp` | 43 | VisibilityController(被动可见性) |
| `visibility_controller.cpp` | 131 | VisibilityController 实现 |
| `entity_vision.hpp` | 130 | EntityVision 类声明 |
| `entity_vision.cpp` | 1047 | EntityVision 实现(updateVisibleEntities 等) |
| `proximity_controller.hpp` | 51 | ProximityController(邻近触发器) |

### A.3 辅助文件

| 文件路径 | 行数 | 职责 |
|---------|------|------|
| `mobile_range_list_node.hpp` | 47 | MobileRangeListNode(独立 AoI root) |
| `mobile_range_list_node.cpp` | — | MobileRangeListNode 实现 |
| `range_list_appeal_trigger.hpp` | — | RangeListAppealTrigger(AppealRadius) |
| `entity.hpp` | — | Entity 类(addTrigger/modTrigger/delTrigger) |
| `entity.cpp` | — | Entity 实现(updateInternalsForNewPosition) |
| `cellapp_config.hpp` | — | CellAppConfig(配置常量) |
| `cellapp_config.cpp` | — | CellAppConfig 实现 |
| `space.hpp` | — | Space 类(debugRangeList/visitLargeEntities) |

---

## 附录 B:核心数据结构速查

### B.1 RangeListNode 继承体系

```
RangeListNode (abstract)
├── EntityRangeListNode        # 普通实体节点
├── MobileRangeListNode        # 独立位置节点(AoI root)
├── RangeListTerminator        # 链表头尾哨兵
│   ├── (HEAD, x=0, z=0)
│   └── (TAIL, x=0xffff, z=0xffff)
└── (RangeTrigger 的内部节点)
    ├── LowerBound             # 触发器下界
    └── UpperBound             # 触发器上界
```

### B.2 RangeListFlags 枚举

```cpp
// range_list_node.hpp
enum RangeListFlags {
    FLAG_NO_TRIGGERS      = 0,
    FLAG_ENTITY_TRIGGER   = 1,   // 实体节点默认
    FLAG_AOI_TRIGGER      = 2,   // AoI 触发器
    FLAG_VISION_TRIGGER   = 4,   // 视觉触发器
    FLAG_UPPER_BOUND      = 8,   // 上界节点
    FLAG_LOWER_BOUND      = 16,  // 下界节点
    FLAG_HEAD_NODE        = 32,  // 头节点
    FLAG_AOI             = 64,
    FLAG_PROXIMITY       = 128,
};
```

### B.3 RangeListOrder 枚举

```cpp
// range_list_node.hpp
enum RangeListOrder {
    RANGE_LIST_ORDER_HEAD        = 0,        // 头哨兵
    RANGE_LIST_ORDER_ENTITY      = 100,      // 实体节点
    RANGE_LIST_ORDER_LOWER_BOUND = 190,      // 触发器下界
    RANGE_LIST_ORDER_UPPER_BOUND = 200,      // 触发器上界
    RANGE_LIST_ORDER_TAIL        = 0xffff,   // 尾哨兵
};
```

### B.4 EntityCache Flags

```cpp
// entity_cache.hpp L138-162
enum {
    ENTER_PENDING       = 0x01,   // 等待 enterAoI 消息
    REQUEST_PENDING     = 0x02,   // 等待 requestEntityUpdate
    CREATE_PENDING      = 0x04,   // 等待 createEntity
    GONE                = 0x08,   // 已离开 AoI
    WITHHELD            = 0x10,   // 暂缓发送
    REFRESH             = 0x20,   // 需要刷新
    PRIORITISED         = 0x40,   // 优先发送(如 vehicle)
    MANUALLY_ADDED      = 0x80,   // 手动加入
    ADDED_BY_TRIGGER    = 0x100,  // 触发器加入
    IS_ALWAYS_DETAILED  = 0x200,  // 总是详细位置
};
```

### B.5 Witness 核心成员

```cpp
// witness.hpp L263-318 (节选)
class Witness {
    Entity & entity_;
    RealEntity & real_;
    float aoiRadius_;          // AOI 半径
    float aoiHyst_;            // 滞回距离
    RangeListNode * pAoIRoot_; // AOI 中心节点
    AoITrigger * pAoITrigger_; // AOI 触发器
    EntityCacheMap aoiMap_;    // 实体缓存 map
    KnownEntityQueue entityQueue_; // 优先级堆
    int bandwidthDeficit_;    // 带宽赤字
    int maxPacketSize_;       // 最大包大小
    IDAlias freeAliases_[256]; // 空闲 IDAlias 数组
    int numFreeAliases_;       // 空闲 IDAlias 数量
    // ...
};
```

### B.6 IDAlias

```cpp
typedef uint8 IDAlias;           // 1 字节
const IDAlias NO_ID_ALIAS = 0xff; // 保留值(255)
```

---

## 附录 C:关键算法步骤速查

### C.1 shuffleX 算法

```
输入:节点 pNode,新位置 newX
1. oldX = pNode->x(); pNode->x(newX)
2. if (newX < oldX) 向左 shuffle:
   a. curr = pNode->prevX
   b. while (curr->x() > newX):
      - if (curr 与 pNode 互相 wants/makes) → crossedXEntity
      - if (curr->x() <= newX 且 needs shuffle) 交换并 insertBeforeX
      - curr = curr->prevX
3. if (newX > oldX) 向右 shuffle:
   a. curr = pNode->nextX
   b. while (curr->x() < newX):
      - if (curr 与 pNode 互相 wants/makes) → crossedXEntity
      - if (curr->x() >= newX 且 needs shuffle) 交换并 insertAfterX
      - curr = curr->nextX
```

### C.2 RangeTrigger::insert 算法

```
输入:触发器 trigger(含 central/lower/upper 节点)
1. lower.insertBeforeX( central )   # 下界在 central 左边
2. upper.insertAfterX( central )    # 上界在 central 右边
3. lower.insertBeforeZ( central )   # 同样在 Z 轴
4. upper.insertAfterZ( central )
5. expand()                         # 扩张,检测范围内的实体
```

### C.3 expand 算法(触发器扩张)

```
1. 沿 X 轴向左遍历 [lower, central]:
   - 遇到 ENTITY 节点:
     a. if (isInXRange && isInZRange) → triggerEnter(entity)
     b. if (wasInXRange && wasInZRange) → 无变化
2. 沿 X 轴向右遍历 [central, upper]:
   - 同上
3. 沿 Z 轴重复(用 X 范围过滤)
```

### C.4 contract 算法(触发器收缩)

```
1. 沿 X 轴向左遍历 [lower, central]:
   - 遇到 ENTITY 节点:
     a. if (wasInXRange && wasInZRange && !(isInXRange && isInZRange))
        → triggerLeave(entity)
2. 沿 X 轴向右遍历 [central, upper]:
   - 同上
3. 沿 Z 轴重复
```

### C.5 Witness::update 算法

```
1. 计算带宽预算:desiredPacketSize = maxPacketSize × throttle - bandwidthDeficit + bundle.size()
2. addSpaceDataChanges(bundle)
3. 发送 vehicle stack(优先)
4. 计算 maxPriority = entityQueue_.front()->priority() + MAX_PRIORITY_DELTA
5. while (堆不空 && 堆顶 priority < maxPriority && bundle < desiredPacketSize):
   a. pop 堆顶 pCache
   b. if (pCache->entity 已销毁): removeFromAoI
   c. if (!isUpdatable): handleStateChange
   d. else: sendQueueElement(pCache); pCache->updatePriority(position)
   e. push pCache 回堆
6. 计算 bandwidthDeficit(超出部分累积到下 tick)
7. flushToClient(bundle)
```

### C.6 addToAoI 算法

```
输入:Entity * pEntity, bool setManuallyAdded
1. if (pEntity->isDestroyed()): isInAoIOffload = true; return
2. if (!canBeOnClient): return
3. pCache = aoiMap_.find(pEntity)
4. if (isInAoIOffload): 清除标志; assert(pCache != NULL && pCache->isGone())
5. if (pCache != NULL):
   a. if (isGone): reuse()
   b. else: 更新 ManuallyAdded/AddedByTrigger; return
6. else:
   pCache = aoiMap_.add(pEntity)
   pCache->setEnterPending()
   addToSeen(pCache)
7. 设置 ManuallyAdded / AddedByTrigger
8. if (!wasInAoIOffload):
   a. addReplayAoIChange (如启用)
   b. isAlwaysDetailed = shouldSendDetailedPosition
   c. callback("onEnteredAoI", pEntity)
```

### C.7 updateVisibleEntities 算法

```
输入:seeingHeight, yawOffset
1. oldVisible.swap(visibleEntities_)  # 保存旧集
2. headPos = getDroppedPosition() + (0, seeingHeight, 0)
3. direction = setPitchYaw(pitch, yaw + yawOffset)
4. for each entity in entitiesInVisionRange_:
   a. if (!canBeSeen): skip
   b. targetPos = entity.getDroppedPosition() + (0, visibleHeight, 0)
   c. for i in [0, 1]:
      i. dist = cs->collide(headPos, targetPos)
      ii. if (dist > 0): 遮挡,continue
      iii. angle = acos(direction · (targetPos-headPos).normalised())
      iv. if (angle < visionAngle): canSee = true; break
      v. targetPos = 用 3/4 visibleHeight 重试
   d. if (canSee): newVisible.insert(entity)
5. diff(oldVisible, newVisible) → onStartSeeing / onStopSeeing
6. visibleEntities_.swap(newVisible)
```

### C.8 allocateIDAlias 算法

```
输入:Entity & entity
1. if (entity.volatileInfo().hasVolatile(0.f) && numFreeAliases_ != 0):
   a. numFreeAliases_--
   b. return freeAliases_[numFreeAliases_]
2. return NO_ID_ALIAS
```

---

> 本文档基于 BigWorld Engine 14.4.1 源码分析,涵盖了 AOI 与 Witness 系统的完整架构、核心算法、数据结构、边界情况、性能分析与最佳实践。所有源码引用均标注了文件路径与行号,便于读者对照源码深入理解。