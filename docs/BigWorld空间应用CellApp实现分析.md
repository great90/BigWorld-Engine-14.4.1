# BigWorld Engine 空间应用 CellApp 与 CellAppMgr 实现深度分析

> 本文档详细分析 BigWorld Engine 14.4.1 中 CellApp(空间应用进程)与 CellAppMgr(空间应用管理器进程)的完整实现,涵盖进程管理、两层负载均衡、BSP 空间分割、Ghost 机制、AOI/Witness、实体生命周期、跨进程通信、备份容错、tick 同步等所有关键机制。

---

## 目录

- [一、整体架构概览](#一整体架构概览)
- [二、CellAppMgr:空间应用管理器进程](#二cellappmgr空间应用管理器进程)
- [三、CellApp:空间应用进程](#三cellapp空间应用进程)
- [四、Entity 与 Ghost 机制](#四entity-与-ghost-机制)
- [五、AOI 与 Witness 系统](#五aoi-与-witness-系统)
- [六、空间管理:Space、Cell 与 BSP 树](#六空间管理spacecell-与-bsp-树)
- [七、跨进程通信](#七跨进程通信)
- [八、备份与容错](#八备份与容错)
- [九、Tick 同步与游戏时间](#九tick-同步与游戏时间)
- [十、配置项速查](#十配置项速查)
- [十一、消息处理表](#十一消息处理表)
- [十二、关键文件路径速查](#十二关键文件路径速查)
- [十三、设计亮点与注意事项](#十三设计亮点与注意事项)
- [附录 A:常见误区澄清](#附录-a常见误区澄清)

---

## 一、整体架构概览

BigWorld 的"空间子系统"由 **CellAppMgr(控制平面)** 与 **CellApp(数据平面)** 两类进程构成,共同承担游戏世界中所有"有空间位置的实体"的模拟。

### 1.1 进程定位

```
┌──────────────────────────────────────────────────────────────────┐
│ 控制平面                                                          │
│   ┌──────────────────────────────────────────────┐                │
│   │  CellAppMgr (单例)                           │                │
│   │  - 管理 CellApp 生命周期                     │                │
│   │  - Space/Cell 的创建与边界划分(BSP)        │                │
│   │  - 两层负载均衡(空间内 + 元跨组)           │                │
│   │  - 游戏时间权威(TimeKeeper)               │                │
│   │  - Space 持久化(writeSpacesToDB)           │                │
│   └──────────────────────────────────────────────┘                │
└──────────────────────────────────────────────────────────────────┘
                            │
                            │ addApp / recoverCellApp / startup / informOfLoad
                            ▼
┌──────────────────────────────────────────────────────────────────┐
│ 数据平面(可多实例,水平扩展)                                    │
│   ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐  │
│   │   CellApp #1    │  │   CellApp #2    │  │   CellApp #N    │  │
│   │ - 持有多个 Cell │  │ - 持有多个 Cell │  │ - 持有多个 Cell │  │
│   │ - Real/Ghost 实体│  │ - Real/Ghost 实体│  │ - Real/Ghost 实体│  │
│   │ - Witness/AOI   │  │ - Witness/AOI   │  │ - Witness/AOI   │  │
│   │ - 跨 CellApp 通道│  │ - 跨 CellApp 通道│  │ - 跨 CellApp 通道│  │
│   └─────────────────┘  └─────────────────┘  └─────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
        │                       │                       │
        └───────────────────────┴───────────────────────┘
                            CellAppChannels 互通
```

### 1.2 与其他进程的关系

```
                  ┌─────────────┐
                  │  bwmachined │
                  └──────┬──────┘
                         │ birth/death 监听
        ┌────────────────┼───────────────────┐
        ▼                ▼                   ▼
   ┌─────────┐     ┌──────────┐        ┌──────────┐
   │CellAppMgr│◄──►│ BaseAppMgr│       │ DBAppMgr │
   └────┬─────┘     └─────┬────┘        └────┬─────┘
        │                 │                  │
        │  informBaseAppDeath /            │ setDBAppAlpha
        │  handleBaseAppBirth              ▼
        │                          ┌────────────┐
        │                          │ DBApp Alpha│
        │                          └─────┬──────┘
        │                                │ IDClient::pullIDs
        ▼                                ▼
   ┌──────────┐  createEntity   ┌──────────────┐
   │ CellApp  │────────────────►│  BaseApp     │
   │          │◄────────────────│  (Real Base) │
   └────┬─────┘  backupCellEntity└──────────────┘
        │
        │ sendToClient(经 BaseApp 转发)
        ▼
   ┌──────────┐
   │  Client  │
   └──────────┘
```

### 1.3 核心抽象

| 概念 | 定义 | 所在文件 |
|------|------|---------|
| **Space** | 一个独立的游戏空间(可能跨多个 CellApp) | `server/cellappmgr/space.hpp`, `server/cellapp/space.hpp` |
| **Cell** | Space 在单个 CellApp 上的一个分区(矩形/BSP 叶子) | `server/cellappmgr/cell_data.hpp`, `server/cellapp/cell.hpp` |
| **CellData** | CellAppMgr 视角下的 Cell(BSP 节点) | `server/cellappmgr/cell_data.hpp` |
| **CellInfo** | CellApp 视角下的 Cell(BSP 叶子,继承 SpaceNode) | `server/cellapp/cell_info.hpp` |
| **Entity** | CellApp 上的实体(可能 Real 或 Ghost) | `server/cellapp/entity.hpp` |
| **RealEntity** | 持有真实状态的 Entity(有 Witness/Haunt) | `server/cellapp/real_entity.hpp` |
| **Ghost** | pReal_==NULL 的 Entity(仅有属性快照) | (无独立文件) |
| **Witness** | 玩家观察世界的代理(AOI 管理) | `server/cellapp/witness.hpp` |
| **CellAppGroup** | 元负载均衡分组(洪水填充形成) | `server/cellappmgr/cell_app_group.hpp` |
| **CellAppChannels** | CellApp 之间通信通道集合 | `server/cellapp/cell_app_channels.hpp` |

---

## 二、CellAppMgr:空间应用管理器进程

CellAppMgr 是空间子系统的控制平面,**不持有任何游戏实体**,而是管理 CellApp 生命周期、划分 Space/Cell、调度负载均衡、维护游戏时间。

### 2.1 文件结构

| 文件 | 行数 | 职责 |
|------|------|------|
| `server/cellappmgr/main.cpp` | - | 入口,`bwMainT<CellAppMgr>(argc, argv)` |
| `server/cellappmgr/cellappmgr.hpp` | 322 | CellAppMgr 类声明 |
| `server/cellappmgr/cellappmgr.cpp` | 2535 | 核心实现(init/addApp/loadBalance/handleCellAppDeath 等) |
| `server/cellappmgr/cellapp.hpp` | - | CellApp 内部视图类(继承 ChannelOwner) |
| `server/cellappmgr/cellapp.cpp` | 617 | CellApp 视图实现(informOfLoad/markGroup/handleUnexpectedDeath) |
| `server/cellappmgr/cellapps.hpp` | - | CellApps 集合容器 |
| `server/cellappmgr/cellapps.cpp` | 833 | findLeastLoadedCellApp/findBestCellApp/leastLoaded |
| `server/cellappmgr/space.hpp/.cpp/.ipp` | - | Space 类,CellData BSP 树 |
| `server/cellappmgr/cell_data.hpp/.cpp/.ipp` | - | CellData(继承 BSPNode) |
| `server/cellappmgr/cell_app_group.hpp/.cpp` | - | CellAppGroup 元负载均衡分组 |
| `server/cellappmgr/cell_app_groups.hpp/.cpp` | - | CellAppGroups 多组管理 |
| `server/cellappmgr/cell_app_death_handler.hpp/.cpp` | - | CellAppDeathHandler 同步等待 ACK |
| `server/cellappmgr/shutdown_handler.hpp/.cpp` | - | ShutDownHandler 两阶段关停 |
| `server/cellappmgr/cellappmgr_config.hpp/.cpp` | - | CellAppMgrConfig 配置 |
| `server/cellappmgr/login_conditions_config.hpp/.cpp` | - | LoginConditionsConfig 登录过载判断 |
| `server/cellappmgr/cellappmgr_interface.hpp` | 140 | CellAppMgrInterface 消息定义 |

### 2.2 类继承

```cpp
// server/cellappmgr/cellappmgr.hpp
class CellAppMgr : public ManagerApp,
    public TimerHandler,
    public Singleton< CellAppMgr >
{
    MANAGER_APP_HEADER( CellAppMgr, cellAppMgr )
    typedef CellAppMgrConfig Config;
    // ...
};
```

**关键澄清**:CellAppMgr **不使用 `ManagedAppSubSet` 模式**(BaseAppMgr 才用)。全局搜索确认 `ManagedAppSubSet` 仅存在于 `server/baseappmgr/`。CellAppMgr 使用扁平 `CellApps` map + `CellAppGroup`/`CellAppGroups` 元分组来管理 CellApp。

### 2.3 关键成员(cellappmgr.hpp)

```cpp
private:
    // 就绪位掩码
    enum { READY_CELL_APP = 1, READY_BASE_APP_MGR = 2, READY_BASE_APP = 4, READY_ALL = 7 };
    int readyFlags_;

    // CellApp 集合(扁平 map,非子集)
    CellApps cellApps_;
    CellApps pendingApps_;          // 等待 finishInit 的 CellApp

    // 空间集合
    Spaces spaces_;

    // 元负载均衡分组(多个 CellAppGroup)
    CellAppGroups cellAppGroups_;

    // 邻居管理器通道
    BaseAppMgr  baseAppMgr_;        // typedef Mercury::ChannelOwner BaseAppMgr
    CellAppMgr  cellAppMgr_;
    DBAppAlpha  dbAppAlpha_;        // typedef Mercury::ChannelOwner DBAppAlpha

    // 时间权威
    TimeKeeper * pTimeKeeper_;

    // 三类定时器
    TimerHandle loadBalanceTimer_;       // 每秒触发:Space 内 Cell 边界重分
    TimerHandle metaLoadBalanceTimer_;   // 每 3 秒触发:跨 Group 加/退役 Cell
    TimerHandle gameTimer_;              // 10Hz 游戏时间推进

    bool isShuttingDown_;
};
```

### 2.4 启动流程(init,cellappmgr.cpp:155-285)

```
init() [L155]
  ├─ 阶段1:基类初始化 + 接口注册 [L157-176]
  │   ├─ ManagerApp::init(argc, argv)
  │   ├─ 校验 interface().isGood()
  │   └─ CellAppMgrInterface::registerWithInterface(interface_)
  │
  ├─ 阶段2:创建 TimeKeeper [L178-195]
  │   ├─ pTimeKeeper_ = new TimeKeeper(interface_, timeStorageTravelDir)
  │   └─ TimeKeeper::init() — 加载持久化时间
  │
  ├─ 阶段3:定位 BaseAppMgr 与 DBAppMgr [L197-219]
  │   └─ Mercury::MachineDaemon::findInterface(..., numStartupRetries)
  │
  ├─ 阶段4:向 machined 注册与监听 [L221-252]
  │   ├─ CellAppMgrInterface::registerWithMachined
  │   ├─ registerBirthListener(handleCellAppMgrBirth)   — 自身唯一性
  │   ├─ registerDeathListener(handleCellAppDeath, "CellApp")  — CellApp 死亡
  │   ├─ registerBirthListener(handleBaseAppMgrBirth)
  │   ├─ registerBirthListener(handleDBAppMgrBirth)
  │   └─ registerDeathListener(handleBaseAppDeath, "BaseAppMgr")
  │
  ├─ 阶段5:Reviver 注册 [L254]
  │   └─ ReviverSubject::init(&interface_, "cellAppMgr")
  │
  ├─ 阶段6:启动三类定时器 [L256-273]
  │   ├─ gameTimer_ = addTimer(100000/gameHertz, TIMEOUT_GAME_TICK)       // 10Hz
  │   ├─ loadBalanceTimer_ = addTimer(1000000*loadBalancePeriod, TIMEOUT_LOAD_BALANCE)  // 1s
  │   └─ metaLoadBalanceTimer_ = addTimer(1000000*metaLoadBalancePeriod, TIMEOUT_META_LOAD_BALANCE) // 3s
  │
  └─ 阶段7:Watcher [L275-285]
      ├─ BW_REGISTER_WATCHER + addWatchers()
      └─ CellApps::addWatchers
```

### 2.5 就绪状态机

CellAppMgr 等待三类进程就绪后才开始接受业务:

```cpp
enum { 
    READY_CELL_APP    = 1,   // 至少一个 CellApp 注册完成
    READY_BASE_APP_MGR= 2,   // BaseAppMgr 已通信
    READY_BASE_APP    = 4,   // BaseApp 已就绪
    READY_ALL         = 7
};

bool isReady() const { return readyFlags_ == READY_ALL; }
```

- 收到 `addCellApp` 后置 `READY_CELL_APP`
- 收到 `handleBaseAppMgrBirth` 后置 `READY_BASE_APP_MGR`
- 收到 `handleBaseAppBirth`(经 BaseAppMgr 转发)后置 `READY_BASE_APP`

### 2.6 CellApp 视图类(cellapp.hpp)

CellAppMgr 内部用一个 `CellApp` 类表示它对一个真实 CellApp 进程的视图(区别于真实 CellApp 进程自身的 `CellApp` 类):

```cpp
// server/cellappmgr/cellapp.hpp
class CellApp : public Mercury::ChannelOwner
{
public:
    CellApp( CellAppMgr & mgr, const Mercury::Address & addr,
        CellAppID id, Mercury::ReplyID replyID );

    CellAppID id() const                 { return id_; }
    bool isRetiring() const              { return isRetiring_; }

    // 负载上报
    void informOfLoad( float currLoad, float extraLoad );
    float currLoad() const               { return currLoad_; }
    float smoothedLoad() const           { return smoothedLoad_; }
    float estimatedLoad() const          { return estimatedLoad_; }
    int   numEntities() const            { return numEntities_; }

    // 该 CellApp 上持有的 Cell 列表
    const Cells & cells() const          { return cells_; }

    // 元负载均衡分组(洪水填充后赋值)
    CellAppGroup * pGroup() const        { return pGroup_; }
    void markGroup( CellAppGroup & group, CellAppGroups & groups );

    // 意外死亡处理
    void handleUnexpectedDeath( CellAppMgr & mgr, bool cutOverSpace );

private:
    CellAppID           id_;
    float               currLoad_;          // 最近一次上报的瞬时负载
    float               lastReceivedLoad_;
    float               smoothedLoad_;      // 指数平滑后的负载
    float               estimatedLoad_;     // 包含预估(新建 Cell)
    int                 numEntities_;
    Cells               cells_;             // 此 CellApp 持有的 Cell 视图
    bool                isRetiring_;
    CellAppGroup *      pGroup_;            // 所属元负载均衡分组
};
```

#### 负载平滑算法(informOfLoad,L72-90)

```cpp
void CellApp::informOfLoad( float currLoad, float extraLoad )
{
    currLoad_ = currLoad;
    // 指数加权移动平均(EWMA)
    smoothedLoad_ = (currLoad * (1.f - LOAD_SMOOTHING_BIAS)) +
                    (smoothedLoad_ * LOAD_SMOOTHING_BIAS);
    // 估计负载 = 当前负载 + 即将到来的负载(新创建尚未上报)
    estimatedLoad_ = smoothedLoad_ + extraLoad;
}
```

- `LOAD_SMOOTHING_BIAS = 0.05`(配置项 `loadSmoothingBias`):每秒只吸收 5% 的新值,避免抖动。
- `extraLoad`:CellAppMgr 在为该 CellApp 新建 Cell 时累加,等真实负载上报后自然吸收。

#### 元负载均衡分组(markGroup,L536-568)

```cpp
void CellApp::markGroup( CellAppGroup & group, CellAppGroups & groups )
{
    // BFS 洪水填充:从本 CellApp 出发,所有"与同 Space 中 Cell 邻接的 CellApp"归为同组
    MF_ASSERT( pGroup_ == NULL );
    pGroup_ = &group;
    group.addCellApp( this );

    // 遍历本 CellApp 上的每个 Cell,找其邻居 Cell 所属的 CellApp
    Cells::iterator iter = cells_.begin();
    while (iter != cells_.end()) {
        CellData * pCell = *iter;
        const CellAppSet & neighbors = pCell->cellAppNeighbors();  // 同 Space 相邻 Cell 的 CellApp
        CellAppSet::const_iterator nIter = neighbors.begin();
        while (nIter != neighbors.end()) {
            if ((*nIter)->pGroup() == NULL) {
                (*nIter)->markGroup( group, groups );  // 递归
            }
            ++nIter;
        }
        ++iter;
    }
}
```

**关键**:只有"同 Space 且 Cell 邻接"的 CellApp 才会被分到同一组。`metaLoadBalance` 时只在组内做加/退役,避免跨 Space 干扰。

### 2.7 CellApp 集合(cellapps.hpp)

```cpp
class CellApps {
public:
    CellApp * find( CellAppID id ) const;
    CellApp * find( const Mercury::Address & addr ) const;

    // 选择最低负载的 CellApp(用于新建 Space/Cell)
    CellApp * findLeastLoadedCellApp() const;

    // 在指定 Space 中选最合适的 CellApp
    CellApp * findBestCellApp( const Space & space,
        bool isNewSpace, float additionalLoad ) const;

    // 在某个组里选最低负载
    CellApp * leastLoaded( const CellAppGroup & group,
        bool shouldCheckRetiring ) const;

    void add( CellApp * pApp );
    void erase( CellAppID id );

private:
    typedef BW::map< CellAppID, CellApp * > Map;
    Map map_;
};
```

#### findLeastLoadedCellApp(L446-463)

```cpp
CellApp * CellApps::findLeastLoadedCellApp() const
{
    CellApp * pBest = NULL;
    Map::const_iterator iter = map_.begin();
    while (iter != map_.end()) {
        CellApp * pApp = iter->second;
        if (!pApp->isRetiring()) {
            if (!pBest || pApp->estimatedLoad() < pBest->estimatedLoad()) {
                pBest = pApp;
            }
        }
        ++iter;
    }
    return pBest;
}
```

排除 `isRetiring_` 的 CellApp,选 `estimatedLoad_` 最小者。

### 2.8 两阶段注册

CellApp 注册分两阶段(类似 BaseApp,但路径不同):

#### 阶段1:addApp(cellappmgr.cpp:1245-1384)

```cpp
void CellAppMgr::addApp( const Mercury::Address & srcAddr,
    const Mercury::UnpackedMessageHeader & header,
    const CellAppMgrInterface::addAppArgs & args )
{
    // 1. 创建 CellApp 视图,放入 pendingApps_(尚未完成初始化)
    CellApp * pApp = new CellApp( *this, srcAddr, args.id, header.replyID );
    pendingApps_.add( pApp );
    addressMap_[ srcAddr ] = pApp;

    // 2. 构造 CellAppInitData 回复(携带 id/time/邻居地址/是否 ready 等)
    CellAppInitData initData;
    initData.id = args.id;
    initData.time = pTimeKeeper_->gameTime();
    initData.baseAppAddr = baseAppMgr_.addr();
    initData.dbAppAlphaAddr = dbAppAlpha_.addr();
    initData.isReady = this->isReady();
    initData.timeoutPeriod = ...;

    // 3. 发送 startup 回复(此时 CellApp 收到后开始 finishInit)
    pApp->sendStartup( initData );

    // 4. 置 READY_CELL_APP 位
    readyFlags_ |= READY_CELL_APP;
}
```

#### 阶段2:startup(cellappmgr.cpp:1755-1768)

CellApp 完成 `finishInit` 后回发 `startup` 消息,CellAppMgr 将其从 `pendingApps_` 移入 `cellApps_`:

```cpp
void CellAppMgr::startup( const Mercury::Address & srcAddr,
    const CellAppMgrInterface::startupArgs & args )
{
    CellApp * pApp = pendingApps_.find( srcAddr );
    MF_ASSERT( pApp );
    pendingApps_.erase( pApp->id() );
    cellApps_.add( pApp );

    // 触发元负载均衡分组重算
    cellAppGroups_.clear();
    // 空闲 CellApp 将被打包为 "default group"
}
```

### 2.9 两层负载均衡

BigWorld 的负载均衡分两层,分别由不同定时器驱动:

#### 第1层:loadBalance(每秒,cellappmgr.cpp:795-819)

**作用**:在每个 Space 内部,调整 Cell 边界(切割/合并),使各 Cell 的负载相近。

```cpp
void CellAppMgr::loadBalance()
{
    Spaces::iterator iter = spaces_.begin();
    while (iter != spaces_.end()) {
        Space * pSpace = iter->second;
        pSpace->loadBalance();   // 调用 Space::loadBalance,内部会做 BSP 树重分
        ++iter;
    }
}
```

- **粒度**:Space 内部的 Cell 边界(BSP 切分线)。
- **算法**:基于 Cell 的负载统计,移动 BSP 切分线,使两子树负载平衡。
- **触发**:每秒(`loadBalancePeriod=1s`)。
- **限制**:不跨 CellApp 移动 Cell(那是第2层的事)。

#### 第2层:metaLoadBalance(每3秒,cellappmgr.cpp:768-789)

**作用**:跨 CellAppGroup,**新建或退役 Cell**,把负载从过载的 CellApp 转移到空闲的 CellApp。

```cpp
void CellAppMgr::metaLoadBalance()
{
    // 1. 重新计算分组(洪水填充)
    cellAppGroups_.clear();
    CellApps::iterator iter = cellApps_.begin();
    while (iter != cellApps_.end()) {
        CellApp * pApp = iter->second;
        if (pApp->pGroup() == NULL) {
            CellAppGroup * pGroup = cellAppGroups_.newGroup();
            pApp->markGroup( *pGroup, cellAppGroups_ );   // 递归洪水填充
        }
        ++iter;
    }

    // 2. 对每个组检查负载,过载则加 Cell,空闲则退役 Cell
    CellAppGroups::iterator giter = cellAppGroups_.begin();
    while (giter != cellAppGroups_.end()) {
        CellAppGroup * pGroup = *giter;
        this->balanceGroup( *pGroup );
        ++giter;
    }
}
```

- **粒度**:CellApp(整进程级)。
- **算法**:在 Group 内比较各 CellApp 的 `smoothedLoad_`,过载 CellApp 上的某个 Cell 会被迁移到组内最低负载的 CellApp(以 Ghost 形式重建)。
- **触发**:每 3 秒(`metaLoadBalancePeriod=3s`)。

#### 两层关系

| 维度 | 第1层 loadBalance | 第2层 metaLoadBalance |
|------|-------------------|----------------------|
| 频率 | 1s | 3s |
| 范围 | Space 内部 | CellAppGroup 内部 |
| 对象 | Cell 边界(BSP 切分线) | Cell 所在的 CellApp |
| 操作 | 移动切分线 | 新建/退役 Cell |
| 是否触发 Ghost 迁移 | 否(只是边界微调) | 是(整个 Cell 切换所属 CellApp) |

### 2.10 BSP 空间分割

#### CellData 继承 BSPNode

```cpp
// server/cellappmgr/cell_data.hpp
class CellData : public BSPNode
{
public:
    CellData( Space & space, CellApp * pApp, const Rect & rect );
    CellApp * pCellApp() const        { return pCellApp_; }
    const Rect & rect() const         { return rect_; }
    // ...
private:
    Space *     pSpace_;
    CellApp *   pCellApp_;
    Rect        rect_;
};
```

#### Space 持有 BSP 树

```cpp
// server/cellappmgr/space.hpp
class Space {
private:
    BSPNode *   pRoot_;   // BSP 树根,叶节点是 CellData
    // ...
};
```

- 每个 Space 用一棵 BSP 树分割世界空间。
- BSP 叶子 = CellData = 一个 Cell(由某个 CellApp 持有)。
- 内部节点 = 切分线(沿 X 或 Z 轴)。
- `loadBalance` 通过移动切分线让两子树负载平衡。
- `metaLoadBalance` 通过把某个叶子(CellData)重新分配给另一个 CellApp。

#### addCell 流程

`Space::addCell` 有多个重载,核心逻辑:

1. 找到合适的 CellApp(经 `cellApps_.findLeastLoadedCellApp()`)。
2. 创建 `CellData`(BSP 叶子),挂在 BSP 树的合适位置。
3. 通知该 CellApp 创建对应的 `Cell` 实例(经 `CellAppInterface::createCell` 消息)。
4. 通知 BaseAppMgr 更新映射(便于 BaseApp 找到 Real 所在)。

### 2.11 实体创建

#### createEntity(cellappmgr.cpp:967-986)

BaseAppMgr 通过该消息请求 CellAppMgr 在某 Space 创建实体:

```cpp
void CellAppMgr::createEntity( const Mercury::Address & srcAddr,
    const CellAppMgrInterface::createEntityArgs & args,
    BinaryIStream & data )
{
    Space * pSpace = spaces_.find( args.spaceID );
    MF_ASSERT( pSpace );
    // 选定目标 Cell(根据 args.position 走 BSP 树定位)
    CellData * pCellData = pSpace->pRoot_->findLeaf( args.position );
    CellApp * pApp = pCellData->pCellApp();
    // 转发到具体 CellApp
    pApp->send( CellAppInterface::createEntity, args.spaceID, data );
}
```

#### createEntityInNewSpace(L728-761)

```cpp
void CellAppMgr::createEntityInNewSpace( ... )
{
    // 1. 创建新 Space
    Space * pSpace = spaces_.newSpace( args.spaceID, ... );
    // 2. 选最低负载 CellApp 创建首个 Cell
    CellApp * pApp = cellApps_.findLeastLoadedCellApp();
    pSpace->addCell( pApp, ... );
    // 3. 转发创建实体消息
    pApp->send( CellAppInterface::createEntity, args.spaceID, data );
}
```

### 2.12 CellApp 死亡处理

#### 触发链

1. machined 检测到 CellApp 进程死亡 → 调用 CellAppMgr 注册的 `handleCellAppDeath` 回调。
2. CellAppMgr 进入 `CellAppDeathHandler` 状态机,先发 `ackCellAppDeath` 给所有相关 CellApp,等所有 ACK 回来后才真正清理。

#### handleCellAppDeath(cellappmgr.cpp:1806-1906)

```cpp
void CellAppMgr::handleCellAppDeath( const Mercury::Address & addr )
{
    CellApp * pApp = cellApps_.find( addr );
    if (!pApp) return;

    // 1. 启动死亡处理器(同步等 ACK)
    CellAppDeathHandler * pHandler = new CellAppDeathHandler( *this, *pApp );
    deathHandlers_.push_back( pHandler );

    // 2. 通知所有 CellApp:某个 CellApp 死了,需要清理与它的 Ghost/Real 引用
    CellApps::iterator iter = cellApps_.begin();
    while (iter != cellApps_.end()) {
        iter->second->send( CellAppInterface::ackCellAppDeath, pApp->id() );
        ++iter;
    }

    // 3. 通知 BaseAppMgr(BaseApp 上的 Real Base 需要重新选 Cell)
    baseAppMgr_.send( BaseAppMgrInterface::handleCellAppDeath, pApp->id() );

    // 4. 清理本进程视图(由 DeathHandler 在所有 ACK 收齐后回调)
    // pHandler->onAllAcksReceived() -> 真正 erase
}
```

#### CellAppDeathHandler

```cpp
// server/cellappmgr/cell_app_death_handler.hpp
class CellAppDeathHandler : public TimerHandler {
public:
    CellAppDeathHandler( CellAppMgr & mgr, CellApp & deadApp );
    void onAckReceived( CellAppID ackerID );
private:
    void handleTimeout( TimerHandle, void * ) /* override */;
    CellAppMgr &   mgr_;
    CellApp &      deadApp_;
    int            numOutstandingAcks_;   // 还差几个 ACK
    TimerHandle    timer_;                // 超时强制清理
};
```

**关键**:必须等所有相关 CellApp 都回 ACK,才能安全清理。否则会出现"Ghost 还指向已死的 CellApp"的悬空引用。

### 2.13 受控关停(controlledShutDown)

CellAppMgr 的关停分两阶段,由 `ShutDownHandler` 驱动:

#### 阶段1:InformHandler

通知所有 CellApp 准备关停,CellApp 完成最后一批 tick 后回 ACK。

```cpp
void CellAppMgr::controlledShutDown( ShutDownStage stage )
{
    if (stage == SHUTDOWN_REQUEST) {
        // 启动 InformHandler
        pShutDownHandler_ = new ShutDownHandler( *this );
        pShutDownHandler_->startInform();
    }
}
```

#### 阶段2:PerformBaseAppsHandler

所有 CellApp ACK 后,通知 BaseAppMgr 关闭 BaseApp,再关闭自己。

```cpp
// server/cellappmgr/shutdown_handler.hpp
class ShutDownHandler {
private:
    class InformHandler;
    class PerformBaseAppsHandler;
    InformHandler          * pInformHandler_;
    PerformBaseAppsHandler * pPerformHandler_;
};
```

### 2.14 游戏时间(TimeKeeper)

CellAppMgr 是游戏时间的**唯一权威**:

```cpp
// lib/server/time_keeper.hpp
class TimeKeeper {
public:
    GameTime gameTime() const        { return *pGameTime_; }
    void     gameTimerInited()       { /* 持久化到 DB */ }
    void     advanceTime()           { ++*pGameTime_; }
private:
    GameTime * pGameTime_;   // 共享内存或本地变量
};
```

- CellAppMgr 每 `1/gameHertz`(10Hz)调用 `pTimeKeeper_->advanceTime()`。
- 所有 CellApp 在 `addApp` 时通过 `CellAppInitData.time` 拿到当前 `gameTime`,本地维护。
- CellApp 之间通过 `sendTickCompleteToAll` 同步 tick,确保跨 CellApp 的实体调用时序一致。

### 2.15 过载检查(overloadCheck)

```cpp
// cellappmgr.cpp handleTimeout(TIMEOUT_LOAD_BALANCE)
void CellAppMgr::overloadCheck()
{
    // 计算所有 CellApp 的平均负载与最大负载
    float avgLoad = 0, maxLoad = 0;
    CellApps::iterator iter = cellApps_.begin();
    while (iter != cellApps_.end()) {
        float l = iter->second->smoothedLoad();
        avgLoad += l;
        if (l > maxLoad) maxLoad = l;
        ++iter;
    }
    avgLoad /= cellApps_.size();

    // 经 LoginConditionsConfig 判断是否拒绝新登录
    bool isOverloaded = (avgLoad > loginConditions_.avgLoad) ||
                        (maxLoad > loginConditions_.maxLoad);
    if (isOverloaded) {
        if (++overloadCount_ > loginConditions_.tolerancePeriod) {
            this->setLoginAppAccepting( false );
        }
    } else {
        overloadCount_ = 0;
        this->setLoginAppAccepting( true );
    }
}
```

### 2.16 Space 持久化(writeSpacesToDB,L2457-2486)

```cpp
void CellAppMgr::writeSpacesToDB()
{
    if (!dbAppAlpha_.addr().isValid()) return;

    Mercury::Bundle & bundle = dbAppAlpha_.bundle();
    bundle.startMessage( DBAppInterface::writeSpaces );

    Spaces::iterator iter = spaces_.begin();
    while (iter != spaces_.end()) {
        iter->second->writeToStream( bundle );   // 序列化 Space 数据
        ++iter;
    }
    dbAppAlpha_.send();
}
```

触发时机:
- 受控关停前。
- 定期(配置项)。
- Space 显式销毁时。

### 2.17 CellAppMgrConfig(cellappmgr_config.hpp)

| 配置项 | 默认值 | 含义 |
|--------|--------|------|
| `maxLoadingCells` | 4 | 单个 CellApp 同时加载的 Cell 数上限 |
| `cellAppTimeout` | 3s | CellApp 心跳超时 |
| `loadBalancePeriod` | 1s | 第1层负载均衡周期 |
| `metaLoadBalancePeriod` | 3s | 第2层负载均衡周期 |
| `estimatedInitialCellLoad` | 0.1 | 新建 Cell 的预估负载 |
| `loadSmoothingBias` | 0.05 | 负载 EWMA 平滑系数 |

### 2.18 LoginConditionsConfig(login_conditions_config.hpp)

| 配置项 | 默认值 | 含义 |
|--------|--------|------|
| `avgLoad` | 0.85 | 平均负载阈值 |
| `maxLoad` | 0.95 | 单进程最大负载阈值 |
| `tolerancePeriod` | 30 | 容忍秒数(连续超阈值才拒绝登录) |

---

## 三、CellApp:空间应用进程

CellApp 是空间子系统的数据平面,**持有真实的游戏实体**,负责模拟、AOI 计算、客户端可见性推送、跨 CellApp 通信。

### 3.1 文件结构概览

CellApp 是 BigWorld 中**最复杂**的进程,源文件超过 150 个,主要分类:

#### 核心进程类

| 文件 | 行数 | 职责 |
|------|------|------|
| `server/cellapp/main.cpp` | - | 入口 |
| `server/cellapp/cellapp.hpp` | 389 | CellApp 类声明 |
| `server/cellapp/cellapp.cpp` | 3688 | 核心实现 |
| `server/cellapp/cellapp_config.hpp/.cpp` | - | CellAppConfig(继承 EntityAppConfig) |
| `server/cellapp/cellapp_interface.hpp` | 391 | 消息定义(CellApp/Space/Cell/Entity 四级) |
| `server/cellapp/add_to_cellappmgr_helper.hpp` | 52 | 异步注册辅助 |
| `server/cellapp/cellappmgr_gateway.hpp/.cpp` | - | CellAppMgr 通道网关 |

#### Entity 与 Ghost

| 文件 | 行数 | 职责 |
|------|------|------|
| `server/cellapp/entity.hpp` | 894 | Entity 类声明 |
| `server/cellapp/entity.cpp` | 6900+ | 实体实现(全文件最长) |
| `server/cellapp/entity.ipp` | 358 | 内联实现 |
| `server/cellapp/real_entity.hpp` | 267 | RealEntity 类 |
| `server/cellapp/real_entity.cpp` | 1500+ | RealEntity 实现 |
| `server/cellapp/entity_type.hpp/.cpp/.ipp` | - | EntityType(类型描述) |
| `server/cellapp/entity_ghost_maintainer.hpp/.cpp` | - | Ghost 边界维护 |
| `server/cellapp/offload_checker.hpp/.cpp` | - | 实体 offload 检查 |

#### Witness 与 AOI

| 文件 | 行数 | 职责 |
|------|------|------|
| `server/cellapp/witness.hpp` | 322 | Witness 类 |
| `server/cellapp/witness.cpp` | 3580 | AOI 实现 |
| `server/cellapp/entity_cache.hpp` | 261 | EntityCache 优先级队列 |
| `server/cellapp/aoi_update_schemes.hpp/.cpp` | - | AoIUpdateScheme 多策略 |

#### 空间管理

| 文件 | 行数 | 职责 |
|------|------|------|
| `server/cellapp/space.hpp` | 252 | Space 类 |
| `server/cellapp/space.cpp` | 2400+ | Space 实现 |
| `server/cellapp/spaces.hpp/.cpp` | - | Spaces 容器 |
| `server/cellapp/cell.hpp` | 226 | Cell 类 |
| `server/cellapp/cell.cpp` | 1200+ | Cell 实现 |
| `server/cellapp/cells.hpp/.cpp` | - | Cells 容器 |
| `server/cellapp/cell_info.hpp` | - | CellInfo(BSP 叶子) |

#### 跨进程通信

| 文件 | 行数 | 职责 |
|------|------|------|
| `server/cellapp/mailbox.hpp` | 163 | ServerEntityMailBox 体系 |
| `server/cellapp/mailbox.cpp` | 1216 | Mailbox 实现 |
| `server/cellapp/cell_app_channel.hpp/.cpp` | - | CellAppChannel(跨 CellApp) |
| `server/cellapp/cell_app_channels.hpp/.cpp` | - | CellAppChannels 集合 |
| `server/cellapp/ack_cell_app_death_helper.hpp/.cpp` | - | ACK 死亡辅助 |
| `server/cellapp/cellapp_death_listener.hpp/.cpp` | - | 死亡监听器 |
| `server/cellapp/buffered_ghost_message*.hpp/.cpp` | - | Ghost 消息缓冲 |
| `server/cellapp/history_event.hpp/.cpp/.ipp` | - | 实体事件历史 |

### 3.2 类继承链

```cpp
// server/cellapp/cellapp.hpp L68-69
class CellApp : public EntityApp,
    public TimerHandler,
    public GeometryMapper,
    public Singleton< CellApp >
{
    SERVER_APP_HEADER( CellApp, cellApp )
    // ...
};
```

**继承层次**:

```
Singleton<CellApp>
       ▲
       │
GeometryMapper  TimerHandler
       ▲           ▲
       │           │
       └─────┬─────┘
             │
          EntityApp
             │
          ScriptApp
             │
          ServerApp
             │
        (Mercury 事件循环 + NetworkInterface + Config)
```

**关键澄清**:
- CellApp **不继承 ComponentApp**(全局搜索确认 ComponentApp 不存在)。
- CellApp **不继承 ChannelListener**(ChannelListener 仅在客户端 `ServerConnection` 中)。

### 3.3 关键成员(cellapp.hpp)

```cpp
class CellApp : public EntityApp, public TimerHandler,
                public GeometryMapper, public Singleton< CellApp >
{
private:
    enum TimeOutType {
        TIMEOUT_GAME_TICK,         // 10Hz 游戏逻辑 tick
        TIMEOUT_TRIM_HISTORIES,    // 4 分钟清理历史
        TIMEOUT_LOADING_TICK       // 50Hz 加载阶段 tick
    };

    // 空间与实体容器
    Cells       cells_;            // map<SpaceID, Cell*>
    Spaces *    pSpaces_;          // 全部 Space

    // 邻居通信
    CellAppMgrGateway   cellAppMgr_;       // 与 CellAppMgr 的通道
    IDClient *          pIDClient_;        // 向 DBApp Alpha 申请 EntityID
    CellAppChannels *   pCellAppChannels_; // 跨 CellApp 通道集合
    Mercury::ChannelOwner dbAppAlpha_;     // 与 DBApp Alpha 的通道

    // 定时器
    TimerHandle  gameTimer_;              // TIMEOUT_GAME_TICK
    TimerHandle  loadingTimer_;           // TIMEOUT_LOADING_TICK
    TimerHandle  trimHistoryTimer_;       // TIMEOUT_TRIM_HISTORIES

    // 时间权威
    TimeKeeper * pTimeKeeper_;

    // Witness 列表(本 CellApp 上所有有 Witness 的 RealEntity)
    Witnesses   witnesses_;

    // 后台任务
    FileIOTaskManager * pFileIOTaskManager_;
    BGTaskManager *     pBGTaskManager_;

    // 启动控制
    bool isReadyToStart_;    // 收到 CellAppMgr 的 isReady=true 后置位
    bool isStarted_;         // gameTimer 启动后置位

    // 节流
    float throttle_;         // tick 节流比例(reservedTickFraction)
};
```

### 3.4 三阶段异步初始化

CellApp 的初始化是**异步的**,跨多次消息往返:

```
进程启动
   │
   ├─ 阶段1: init() 同步初始化 [L489-654]
   │     ├─ 基类 ServerApp::init / ScriptApp::init / EntityApp::init
   │     ├─ 创建 Spaces / Cells / CellAppChannels
   │     ├─ 加载 EntityDefs
   │     ├─ 创建 TimeKeeper
   │     ├─ initScript() (L3385-3529):注册 BigWorld 模块、BigWorld.cellApp
   │     ├─ 创建 AddToCellAppMgrHelper (自销毁,构造即 send addApp)
   │     └─ 启动 loadingTimer_(50Hz)
   │
   ├─ 阶段2: finishInit() [L661-732]
   │     (在收到 CellAppMgr 的 startup 回复后调用)
   │     ├─ 解析 CellAppInitData:取得 id / time / baseAppAddr / dbAppAlphaAddr / isReady
   │     ├─ 创建与 BaseAppMgr、DBApp Alpha 的通道
   │     ├─ pIDClient_ = new IDClient( dbAppAlpha_ )
   │     ├─ 注册 birth/death 监听器
   │     ├─ 若 isReady=true → 调用 startGameTime()
   │     ├─ 启动 trimHistoryTimer_(4分钟周期)
   │     └─ 向 CellAppMgr 发送 startup 消息(完成注册)
   │
   └─ 阶段3: startGameTime() [L798-823]
         (在 CellAppMgr 就绪后调用)
         ├─ loadingTimer_.cancel()
         ├─ gameTimer_ = addTimer(100000/gameHertz, TIMEOUT_GAME_TICK)  // 10Hz
         ├─ pTimeKeeper_->gameTimerInited()   // 通知 CellAppMgr 持久化
         └─ isStarted_ = true
```

### 3.5 init() 27 步详解(cellapp.cpp:489-654)

```cpp
bool CellApp::init( int argc, char * argv[] )
{
    // 1. 基类 init
    EntityApp::init( argc, argv );

    // 2. 创建 Spaces 容器
    pSpaces_ = new Spaces;

    // 3. 创建 Cells 容器
    // cells_ 默认构造

    // 4. 创建 CellAppChannels
    pCellAppChannels_ = new CellAppChannels( interface_ );

    // 5. 创建 TimeKeeper
    pTimeKeeper_ = new TimeKeeper( interface_ );

    // 6. 加载 EntityDefs(基类 EntityApp 已加载,这里只是引用)

    // 7. 创建 IDClient(占位,实际在 finishInit 后绑定 dbAppAlpha_)
    // pIDClient_ = new IDClient(...)

    // 8. 初始化脚本(BigWorld.cellApp / BigWorld.entity)
    initScript();   // L3385-3529

    // 9. 注册 BigWorld 模块的所有 method
    // ...

    // 10. 创建 CellAppMgrGateway(占位,等待 finishInit 填充)
    cellAppMgr_ = CellAppMgrGateway( interface_ );

    // 11. 加载 CellAppConfig
    CellAppConfig::init( *this );

    // 12. 启动 loadingTimer_(50Hz,加载阶段 tick)
    loadingTimer_ = addTimer( 100000/loadingHertz, TIMEOUT_LOADING_TICK );

    // 13. 创建 FileIO 后台线程
    pFileIOTaskManager_ = new FileIOTaskManager( "FileIO" );
    pFileIOTaskManager_->startThreads( numFileIOThreads );

    // 14. 创建 BGTask 后台线程
    pBGTaskManager_ = new BGTaskManager( "BGTask" );
    pBGTaskManager_->startThreads( numBGTaskThreads );

    // 15. 注册 Watchers
    addWatchers();   // L860-916

    // 16. 创建 Reviver 注册
    ReviverSubject::init( &interface_, "cellApp" );

    // 17. 注册 birth/death 监听器(部分,需 finishInit 后才能注册完整)
    registerDeathListener( "CellApp", handleCellAppDeath );
    registerDeathListener( "BaseApp", handleBaseAppDeath );

    // 18-27. 其他初始化(SpaceDataMappings、AoIUpdateSchemes、Controllers 等)
    // ...

    // 启动 AddToCellAppMgrHelper(异步向 CellAppMgr 注册)
    AddToCellAppMgrHelper * pHelper = new AddToCellAppMgrHelper( *this );
    // 构造即 send addApp,自销毁
    return true;
}
```

### 3.6 AddToCellAppMgrHelper

```cpp
// server/cellapp/add_to_cellappmgr_helper.hpp (52 行)
class AddToCellAppMgrHelper : public AddToManagerHelper
{
public:
    AddToCellAppMgrHelper( CellApp & app ) :
        AddToManagerHelper( app.cellAppMgr().channel(),
            CellAppMgrInterface::addApp, app )
    {
        // 构造函数即发送 addApp 消息
        this->send( args );
    }
};
```

- 继承 `AddToManagerHelper`(基类提供"等回复→调 onManagerRegistrationCompleted"机制)。
- **自销毁**:回复到达后,基类会 `delete this`。

### 3.7 CellAppInitData 结构

```cpp
// lib/server/cell_app_init_data.hpp
struct CellAppInitData {
    CellAppID           id;
    GameTime            time;             // 当前游戏时间
    Mercury::Address    baseAppAddr;      // BaseAppMgr 地址
    Mercury::Address    dbAppAlphaAddr;   // DBApp Alpha 地址
    bool                isReady;          // CellAppMgr 是否就绪
    float               timeoutPeriod;    // 心跳超时
};
```

由 CellAppMgr 在 `addApp` 回复中下发,CellApp 在 `finishInit` 中解析。

### 3.8 三类定时器

```cpp
enum TimeOutType {
    TIMEOUT_GAME_TICK,        // 10Hz 游戏逻辑 tick
    TIMEOUT_TRIM_HISTORIES,   // 4 分钟清理历史
    TIMEOUT_LOADING_TICK      // 50Hz 加载阶段 tick
};
```

| 定时器 | 频率 | 触发场景 | 处理函数 |
|--------|------|---------|---------|
| `TIMEOUT_GAME_TICK` | 10Hz | 正常运行期 | `handleGameTickTimeSlice` (L1302) |
| `TIMEOUT_LOADING_TICK` | 50Hz | 仅启动期(等 CellAppMgr 就绪) | `handleLoadingTick` |
| `TIMEOUT_TRIM_HISTORIES` | 4 分钟 | 全程 | `trimHistories` |

**关键**:启动期只有 `loadingTimer_`,等 CellAppMgr 就绪(`isReady=true`)后切换到 `gameTimer_`。两者不会同时运行。

### 3.9 Tick 机制(handleTimeout,L942-974)

```cpp
void CellApp::handleTimeout( TimerHandle handle, void * arg )
{
    switch (uintptr(arg)) {
    case TIMEOUT_GAME_TICK:
        this->handleGameTickTimeSlice();   // L1302-1340
        break;
    case TIMEOUT_LOADING_TICK:
        this->handleLoadingTick();
        break;
    case TIMEOUT_TRIM_HISTORIES:
        this->trimHistories();
        break;
    }
}
```

#### handleGameTickTimeSlice(L1302-1340)

```cpp
void CellApp::handleGameTickTimeSlice()
{
    // 1. 推进游戏时间
    pTimeKeeper_->advanceTime();

    // 2. 通知所有 Space:tick 开始
    this->onStartOfTick();   // L1346-1354

    // 3. 让所有 Witness 更新(AOI 计算 + 客户端推送)
    witnesses_.callWitnesses( &Witness::update );

    // 4. 让所有 Entity 跑控制器/脚本回调
    cells_.tick( pTimeKeeper_->gameTime() );

    // 5. 通知所有 Space:tick 处理完成
    this->onTickProcessingComplete();   // L1373-1383

    // 6. 通知所有 Space:tick 结束
    this->onEndOfTick();   // L1360-1366

    // 7. 检查是否需要触发关停
    this->tickShutdown();
}
```

#### onStartOfTick(L1346-1354)

```cpp
void CellApp::onStartOfTick()
{
    // 处理 buffered ghost messages(上一 tick 期间累积的 Ghost 消息)
    cells_.processBufferedGhostMessages();
}
```

#### onEndOfTick(L1360-1366)

```cpp
void CellApp::onEndOfTick()
{
    // 1. 发送本 tick 完成通知给所有其他 CellApp
    pCellAppChannels_->sendTickCompleteToAll( pTimeKeeper_->gameTime() );

    // 2. 检查所有 CellApp 是否都已收到时间(跨 CellApp tick 同步)
    pCellAppChannels_->callWitnesses( &Witness::haveAllChannelsReceivedTime );
}
```

### 3.10 受控关停

**关键澄清**:CellApp 的受控关停**仅处理 `SHUTDOWN_INFORM` 阶段**,不像 BaseApp 那样有四阶段。

```cpp
// cellapp.cpp:1448-1497
void CellApp::controlledShutDown( ShutDownStage stage )
{
    if (stage == SHUTDOWN_INFORM) {
        // 标记自己为 retiring,不再接收新 Cell/Entity
        isRetiring_ = true;

        // 通知 CellAppMgr
        cellAppMgr_.retireApp();

        // 把所有 Real Entity 迁移到其他 CellApp(可选,或交给 BaseApp 重新选)
        // ...

        // 完成后回 ACK
        cellAppMgr_.ackShutdown();
    }
    // 其他阶段(SHUTDOWN_REQUEST/SHUTDOWN_PERFORM 等)由 CellAppMgr 推进
}
```

- **无 `controlled_shutdown_handler.hpp`**:全局搜索确认该文件**仅存在于 BaseApp**。
- CellApp 不维护 `InitStateFlags`(那是 DBApp 独有),只用 `isReadyToStart_` 布尔值。
- `hasStarted()` 基于 `gameTimer_.isSet()`:

```cpp
bool CellApp::hasStarted() const {
    return gameTimer_.isSet();   // gameTimer_ 在 startGameTime 中创建
}
```

### 3.11 Watcher(addWatchers,L860-916)

```cpp
void CellApp::addWatchers()
{
    BW_REGISTER_WATCHER( "cellApp" );

    // 进程级 watcher
    ADD_WATCHER( numEntities, cells_.size() );
    ADD_WATCHER( numSpaces, pSpaces_->size() );
    ADD_WATCHER( numWitnesses, witnesses_.size() );
    ADD_WATCHER( load, smoothedLoad_ );
    ADD_WATCHER( isReady, isReadyToStart_ );
    ADD_WATCHER( isRetiring, isRetiring_ );
    ADD_WATCHER( gameTick, pTimeKeeper_->gameTime() );

    // Entity 类型 watcher
    EntityTypes::addWatchers();

    // Spaces / Cells 级 watcher
    pSpaces_->addWatchers();
    cells_.addWatchers();
}
```

### 3.12 CellAppConfig(cellapp_config.hpp)

继承 `EntityAppConfig`(再继承 `ScriptAppConfig`/`ServerAppConfig`),共 35+ 项。核心:

| 配置项 | 默认值 | 含义 |
|--------|--------|------|
| `loadSmoothingBias` | 0.05 | 负载 EWMA 平滑系数 |
| `ghostDistance` | 500 | Ghost 距离(超出则不维护 Ghost) |
| `defaultAoIRadius` | 500 | 默认 AOI 半径 |
| `backupPeriod` | 10s | Real Entity 备份到 BaseApp 的周期 |
| `ghostUpdateHertz` | 50 | Ghost 属性更新频率 |
| `reservedTickFraction` | 0.05 | tick 节流(预留 5% 给其他任务) |
| `chunkLoadingPeriod` | 0.02 | Chunk 加载周期 |

### 3.13 线程模型

CellApp 进程内有**多个线程**:

| 线程 | 数量 | 职责 |
|------|------|------|
| **主线程** | 1 | Mercury 事件循环 + 游戏逻辑 tick |
| **FileIO 线程** | 配置 | 文件读写(资源加载、Space 持久化) |
| **BGTask 线程** | 配置 | 后台任务(脚本异步、压缩等) |
| **Mercury 网络** | 内置 | UDP 收发(异步) |

**关键**:
- 主线程独占 Entity/Cell/Space 等游戏对象。
- 后台线程只能访问 `BGTaskManager` 提交的不可变数据。
- 通过 `FileIOTaskManager` 把磁盘 IO 卸载到独立线程。

### 3.14 handleCellAppDeath(cellapp.cpp:1672-1797)

```cpp
void CellApp::handleCellAppDeath( const Mercury::Address & addr )
{
    // 1. 通过 CellAppDeathListeners 通知所有监听者
    CellAppDeathListeners::notify( addr );

    // 2. 销毁本 CellApp 上所有引用了死 CellApp 的 Mailbox
    //    (CellEntityMailBox 的目标 CellApp 死了 → 该 mailbox 失效)
    cells_.handleCellAppDeath( addr );

    // 3. 清理 CellAppChannels 中对应的通道
    pCellAppChannels_->handleCellAppDeath( addr );

    // 4. 回 ACK 给 CellAppMgr(经 AckCellAppDeathHelper)
    cellAppMgr_.ackCellAppDeath( deadAppID );
}
```

### 3.15 handleBaseAppDeath(cellapp.cpp:1804-1857)

```cpp
void CellApp::handleBaseAppDeath( BinaryIStream & data )
{
    // 解析 BaseAppMgr 发来的死亡通知 + 新 BaseApp 地址
    Mercury::Address deadAddr, newAddr;
    data >> deadAddr >> newAddr;

    // 1. 通知所有 mailbox 重定向(adjustForDeadBaseApp)
    cells_.adjustForDeadBaseApp( deadAddr, newAddr );

    // 2. RealEntity 的 pRealChannel_ 重连到新 BaseApp
    cells_.rebaseRealChannels( deadAddr, newAddr );
}
```

---

## 四、Entity 与 Ghost 机制

Entity 是 CellApp 上最核心的对象,Ghost 是 Entity 的一种"轻量副本"形态。

### 4.1 Entity 类继承

```cpp
// server/cellapp/entity.hpp L138
class Entity : public PyObjectPlus
{
    Py_Header( Entity, PyObjectPlus )
public:
    typedef Entity BaseOrEntity;   // L65 — CellApp 用 Entity 直接作为"Base"
    // ...
};
```

**关键澄清**:
- CellApp 的 Entity **直接继承 PyObjectPlus**(单层),不像 BaseApp 那样有 `Base : Entity : PyObjectPlus` 两层。
- `typedef Entity BaseOrEntity` 让通用代码可以无差别引用 `BaseOrEntity`(在 BaseApp 是 Base,在 CellApp 是 Entity)。

### 4.2 Entity 关键成员

```cpp
class Entity : public PyObjectPlus
{
private:
    Space *             pSpace_;            // 所属 Space
    EntityID            id_;                // 全局唯一 ID
    EntityType *        pEntityType_;       // 类型描述
    Vector3             globalPosition_;    // 世界坐标
    Mercury::Address    baseAddr_;          // Real Base 所在的 BaseApp 地址
    Mercury::UDPChannel* pRealChannel_;     // 到 Real Base 的通道
    Mercury::Address    nextRealAddr_;      // 待切换的下一个 Real Base 地址

    // Real/Ghost 区分核心
    RealEntity *        pReal_;             // 非 NULL = Real,NULL = Ghost

    // 属性
    ScriptTuple         properties_;        // Python 对象属性
    EventHistory *      eventHistory_;      // 事件历史

    // AOI
    RangeListNode *     pRangeListNode_;    // 在 Space 的 RangeList 中的节点

    // 控制器
    Controllers *       pControllers_;

    // Offload 计数
    int                 numTimesRealOffloaded_;
};
```

### 4.3 Ghost 的本质

**关键澄清**:**Ghost 不是独立类**,而是 `pReal_ == NULL` 的 Entity 实例。

```cpp
bool Entity::isReal() const     { return pReal_ != NULL; }
bool Entity::isGhost() const    { return pReal_ == NULL; }
```

- **Real Entity**:`pReal_` 指向一个 `RealEntity` 对象,持有完整状态(属性、Witness、Haunt 列表、Channel)。
- **Ghost Entity**:`pReal_ == NULL`,仅有属性快照(由 Real 推送),没有 Witness,不能跑逻辑脚本。

整个代码库**没有 `ghost.hpp`**,所有 Ghost 行为都在 `entity.cpp` 中通过 `if (pReal_)` 分支处理。

### 4.4 RealEntity 类

```cpp
// server/cellapp/real_entity.hpp
class RealEntity : public ReferenceCount
{
public:
    // 初始化来源
    enum CreateRealInfo {
        FROM_INIT,      // 实体首次创建即为 Real
        FROM_OFFLOAD,   // 从其他 CellApp offload 过来
        FROM_RESTORE    // 从 BaseApp 恢复
    };

    void init( Entity & e, CreateRealInfo info, BinaryIStream * pStream );
    void destroy();

    // Witness(玩家观察)
    Witness * pWitness() const         { return pWitness_; }
    void enableWitness( ... );
    void disableWitness();

    // Haunt 列表(本 Real 在哪些 CellApp 上有 Ghost)
    class Haunt {
    public:
        CellAppChannel *   pChannel_;
        CellInfo *         pCellInfo_;
        bool               isOffloaded_;
    };
    typedef BW::vector<Haunt> Haunts;
    Haunts & haunts()                  { return haunts_; }

    // 备份
    void backup();
    void writeBackupProperties( Mercury::Bundle & bundle );

    // Offload(把 Real 迁移到另一个 CellApp)
    void readOffloadData( ... );

    // Teleport
    void teleport( ... );

private:
    Entity *            pEntity_;
    Haunts              haunts_;        // L245
    Witness *           pWitness_;      // L243 — 注意:在 RealEntity 而非 Entity
    Mercury::UDPChannel* pRealChannel_;
};
```

#### Haunt 内嵌类(L76-98)

`Haunt` 描述"本 RealEntity 在哪个 CellApp 上有一个 Ghost"。

```cpp
class Haunt {
public:
    CellAppChannel *   pChannel_;     // 到该 CellApp 的通道
    CellInfo *         pCellInfo_;    // 该 Ghost 所在的 Cell
    bool               isOffloaded_;  // 该 Ghost 是否即将变成 Real(offload 中)
};
```

### 4.5 Entity 创建流程

#### newEntity(entity_type.cpp:125-151)

```cpp
Entity * EntityType::newEntity( EntityID id, Space & space, real_type * pReal )
{
    // 1. Python 类型对象分配
    PyObject * pObject = PyType_GenericAlloc( this->pPyType(), 0 );
    // 2. placement new 在 PyObject 内部构造 Entity
    Entity * pEntity = new (pObject) Entity( this, id, space );
    // 3. 若有 pReal(从 BaseApp 恢复),初始化 Real
    if (pReal) {
        pEntity->pReal_ = pReal;
        pReal->pEntity_ = pEntity;
    }
    return pEntity;
}
```

#### Cell::createEntity(cell.cpp:483-546)

```cpp
Entity * Cell::createEntity( const EntityData & entityData, ... )
{
    // 1. 经 EntityType 创建 Entity 对象
    Entity * pEntity = entityType.newEntity( id, space, NULL );

    // 2. 创建 RealEntity
    RealEntity * pReal = new RealEntity();
    pReal->init( *pEntity, RealEntity::FROM_INIT, NULL );
    pEntity->pReal_ = pReal;

    // 3. 加入 Cell 的实体列表
    entities_.add( pEntity );

    // 4. 加入 Space 的 RangeList(用于 AOI)
    space.addEntity( *pEntity );

    // 5. 触发 Ghost 创建(在邻居 CellApp 上创建对应 Ghost)
    pReal->createGhosts();

    return pEntity;
}
```

### 4.6 Real ↔ Ghost 转换

#### convertRealToGhost(entity.cpp:2005-2061)

```cpp
void Entity::convertRealToGhost( const Mercury::Address & srcAddr,
    BinaryIStream & data )
{
    MF_ASSERT( pReal_ != NULL );

    // 1. 销毁 RealEntity 的 Real-only 部分(Witness/Haunt/Channel)
    pReal_->destroy();
    delete pReal_;
    pReal_ = NULL;

    // 2. 从流中读取 Real 推送过来的属性快照
    data >> properties_;

    // 3. 标记为 Ghost,加入 Cell 的 Ghost 列表
    pSpace_->onEntityBecomeGhost( *this );
}
```

#### convertGhostToReal(entity.cpp:4657-4703)

```cpp
void Entity::convertGhostToReal( BinaryIStream & data )
{
    MF_ASSERT( pReal_ == NULL );

    // 1. 从流中读取 Real 的完整状态(RealEntity::readOffloadData)
    pReal_ = new RealEntity();
    pReal_->init( *this, RealEntity::FROM_OFFLOAD, &data );

    // 2. 从 Cell 的 Ghost 列表移到 Real 列表
    pSpace_->onEntityBecomeReal( *this );

    // 3. 触发 Ghost 创建(若该 Real 周围有其他 CellApp,需要新建 Ghost)
    pReal_->createGhosts();
}
```

### 4.7 Offload 与 Onload

**Offload**:把 Real Entity 从本 CellApp 迁移到另一个 CellApp(变成 Ghost 给本 CellApp)。

#### offload(entity.cpp:1968-1991)

```cpp
void Entity::offload( CellAppChannel & channel, ... )
{
    // 1. 把 Real 状态序列化
    Mercury::Bundle & bundle = channel.bundle();
    bundle.startMessage( CellAppInterface::onloadEntity );
    pReal_->writeOffloadData( bundle );

    // 2. 通知目标 CellApp 加载
    channel.send();

    // 3. 本地转换为 Ghost
    this->convertRealToGhost( ... );
}
```

#### onload(entity.cpp:4560-4640)

```cpp
void Entity::onload( BinaryIStream & data )
{
    // 在目标 CellApp 上,把 Ghost 转为 Real
    this->convertGhostToReal( data );
}
```

### 4.8 EntityGhostMaintainer

```cpp
// server/cellapp/entity_ghost_maintainer.hpp
class EntityGhostMaintainer : public CellInfoVisitor
{
public:
    void check( RealEntity & realEntity );
private:
    void markHaunts( ... );             // 标记需要的 Haunt
    void createOrUnmarkRequiredHaunts(); // 创建新 Haunt
    void deleteMarkedHaunts();           // 删除多余 Haunt
};
```

**职责**:确保 Real Entity 周围所有"应该有 Ghost"的 Cell 都有 Ghost,所有"不需要 Ghost"的 Cell 都被清理。

**触发**:Real Entity 移动时,会调用 `EntityGhostMaintainer::check`,基于 AOI 距离判断哪些 CellApp 需要 Ghost。

### 4.9 OffloadChecker

```cpp
// server/cellapp/offload_checker.hpp
class OffloadChecker : public CellInfoVisitor
{
    // 检查 Real Entity 是否应该被 offload 到另一个 CellApp(若已离开本 Cell 范围)
};
```

### 4.10 实体销毁(destroy,entity.cpp:2886-2998)

```cpp
void Entity::destroy()
{
    // 1. 从 Space 的 RangeList 移除
    pSpace_->removeEntity( *this );

    // 2. 从 Cell 的实体列表移除
    pSpace_->cell().entities_.erase( this );

    // 3. 若是 Real,销毁 RealEntity(以及所有 Haunt 上的 Ghost)
    if (pReal_) {
        pReal_->deleteGhosts();    // 通知所有 Haunt 对应的 CellApp 删除 Ghost
        pReal_->destroy();
        delete pReal_;
        pReal_ = NULL;
    }

    // 4. 通知 BaseApp 销毁 Real Base
    // (经 BaseAppIntInterface::destroyCellEntity)

    // 5. 释放 Python 对象
    Py_DECREF( this );
}
```

### 4.11 实体方法调用

CellApp 上的 Entity 有三类方法调用入口:

| 方法 | 入口 | 说明 |
|------|------|------|
| `callBaseMethod` | entity.cpp:5255-5299 | 调用对应 Real Base 的方法(经 `pRealChannel_`) |
| `callClientMethod` | entity.cpp:5305-5334 | 调用客户端方法(经 BaseApp 转发到 Client) |
| `runExposedMethod` | entity.cpp:5399-5407 | 调用本实体的 Python exposed 方法 |

**关键澄清**:CellApp **不支持 two-way 方法调用**(所有 mailbox `getStream` 检测到 `pHandler` 非空时报错)。`TwoWayMethodForwardingReplyHandler` 仅在 BaseApp 端存在。

### 4.12 实体属性备份(backup)

**关键澄清**:CellApp **没有独立的 BackupSender 类**(那是 BaseApp 独有)。备份通过 `RealEntity::backup()` 直接推到 BaseApp:

```cpp
// real_entity.cpp:884-906
void RealEntity::backup()
{
    if (!pRealChannel_) return;

    Mercury::Bundle & bundle = pRealChannel_->bundle();
    bundle.startMessage( BaseAppIntInterface::backupCellEntity );

    // 写入 EntityID + 所有持久化属性
    bundle << pEntity_->id();
    this->writeBackupProperties( bundle );

    pRealChannel_->send();
}
```

`backup()` 由 CellApp 主 tick 周期性触发(默认 `backupPeriod=10s`),把 Real Entity 的属性推到 BaseApp,BaseApp 持久化到 DBApp。

### 4.13 IDClient(申请 EntityID)

```cpp
// lib/server/id_client.hpp
class IDClient {
public:
    IDClient( Mercury::ChannelOwner & dbAppAlpha );
    void pullIDs( int numIDs );
    EntityID popID();

private:
    void onIDsReceived( BinaryIStream & data );
    Mercury::ChannelOwner & dbAppAlpha_;
    std::queue<EntityID> availableIDs_;
};
```

- CellApp 创建新 Real Entity 时,若本地 ID 池为空,向 DBApp Alpha 批量申请(默认一次 100 个)。
- DBApp Alpha 维护全局 ID 池(从 DB 获取)。
- **批量申请**:减少跨进程往返。

### 4.14 EntityType

```cpp
// server/cellapp/entity_type.hpp
class EntityType : public ReferenceCount
{
public:
    EntityType( const EntityDescription & desc, CellApp & app );
    Entity * newEntity( EntityID id, Space & space, real_type * pReal );
    void reloadScript();
    bool migrate();

private:
    int                 propCountGhost_;   // Ghost 属性数
    int                 propCountReal_;    // Real 属性数
    PropertyOwner **    propDescs_;        // 属性描述数组
    ScriptTypeObject *  pPyType_;          // Python 类型对象
};
```

---

## 五、AOI 与 Witness 系统

AOI(Area Of Interest)是 CellApp 把"客户端能看见的实体"推送给客户端的核心机制。

### 5.1 Witness 类

```cpp
// server/cellapp/witness.hpp
class Witness : public Updatable
{
public:
    Witness( Entity & e );
    ~Witness();

    // AOI 配置
    float aoiRadius() const             { return aoiRadius_; }
    void  aoiRadius( float r );
    float aoiHyst() const               { return aoiHyst_; }

    // AOI 触发器
    AoITrigger * pAoITrigger() const    { return pAoITrigger_; }

    // EntityCacheMap(本 Witness 当前 AOI 内的所有实体)
    EntityCacheMap & aoiMap()           { return aoiMap_; }

    // 优先级队列(决定推送顺序)
    PrioritisedEntityQueue & entityQueue() { return entityQueue_; }

    // AOI 增删
    void addToAoI( Entity & e, EntityCache::DetailLevel dl );
    void removeFromAoI( Entity & e );

    // 更新(每 tick 调用)
    void update();

    // 推送到客户端
    void flushToClient();

private:
    Entity *                pEntity_;           // 拥有此 Witness 的 Real Entity
    float                   aoiRadius_;         // AOI 半径
    float                   aoiHyst_;           // 滞后距离(避免抖动)
    AoITrigger *            pAoITrigger_;       // 触发器(在 RangeList 中)
    EntityCacheMap          aoiMap_;            // AOI 内的实体集合
    PrioritisedEntityQueue  entityQueue_;       // 优先级堆
};
```

**关键澄清**:`pWitness_` 在 **RealEntity** 而非 Entity(因为只有 Real 才能是玩家,Ghost 不能有 Witness)。

### 5.2 EntityCache 与优先级队列

```cpp
// server/cellapp/entity_cache.hpp
class EntityCache {
public:
    EntityCache() : flags_( 0 ), priority_( 0 ),
        lastEventNumber_( 0 ), detailLevel_( 0 ), idAlias_( 0 ) {}

    uint8   flags_;            // 状态标志
    float   priority_;         // 当前优先级(距离倒数等)
    EventNumber lastEventNumber_; // 上次推送的事件号
    DetailLevel detailLevel_;  // 细节级别(LOD)
    EntityIDAlias idAlias_;    // 客户端别名(节省带宽)
};

class EntityCacheMap {
    // hash map: Entity* -> EntityCache
};

class PrioritisedEntityQueue {
    // 优先级堆:按 priority_ 排序,高优先级先推送
};
```

### 5.3 AOI 触发器(AoITrigger)

`AoITrigger` 是 RangeList 中的一个查询节点,当其他 Entity 进入/离开半径时触发回调:

```cpp
class AoITrigger : public RangeListNode {
public:
    AoITrigger( Witness & witness );
    void onEnteredRange( RangeListNode & node ) {
        witness_.addToAoI( static_cast<Entity&>(node), ... );
    }
    void onLeavedRange( RangeListNode & node ) {
        witness_.removeFromAoI( static_cast<Entity&>(node) );
    }
};
```

### 5.4 addToAoI(witness.cpp:2202-2295)

```cpp
void Witness::addToAoI( Entity & e, EntityCache::DetailLevel dl )
{
    MF_ASSERT( !aoiMap_.contains( e ) );

    // 1. 创建 EntityCache
    EntityCache & cache = aoiMap_[ &e ];
    cache.detailLevel_ = dl;

    // 2. 计算优先级(基于距离)
    cache.priority_ = this->calcPriority( e );

    // 3. 加入优先级队列
    entityQueue_.add( cache );

    // 4. 发送 createEntity 消息给客户端(经 BaseApp 转发)
    this->sendCreate( e );
}
```

### 5.5 removeFromAoI(witness.cpp:2305-2369)

```cpp
void Witness::removeFromAoI( Entity & e )
{
    EntityCacheMap::iterator iter = aoiMap_.find( &e );
    MF_ASSERT( iter != aoiMap_.end() );

    // 1. 从优先级队列移除
    entityQueue_.erase( iter->second );

    // 2. 发送 leave 消息给客户端
    this->sendLeave( e );

    // 3. 从 map 移除
    aoiMap_.erase( iter );
}
```

### 5.6 update(witness.cpp:1088-1414)

每 tick 调用,核心算法:

```cpp
void Witness::update()
{
    // 1. 更新所有 EntityCache 的优先级(基于距离变化)
    EntityCacheMap::iterator iter = aoiMap_.begin();
    while (iter != aoiMap_.end()) {
        iter->second.priority_ = this->calcPriority( *iter->first );
        ++iter;
    }

    // 2. 重排优先级队列
    entityQueue_.resort();

    // 3. 在带宽预算内,按优先级推送事件
    int budget = maxBytesPerTick_;
    while (!entityQueue_.empty() && budget > 0) {
        EntityCache & cache = entityQueue_.top();
        if (cache.lastEventNumber_ >= cache.events_.size()) break;

        // 推送一个事件
        int sent = this->sendQueueElement( cache );
        budget -= sent;
        ++cache.lastEventNumber_;

        entityQueue_.pop();
        entityQueue_.push( cache );   // 重新入队(下一轮可能再推)
    }
}
```

### 5.7 flushToClient(witness.cpp:1702-1713)

```cpp
void Witness::flushToClient()
{
    // 经 BaseApp 转发到客户端(BaseAppIntInterface::sendToClient)
    if (!pEntity_->baseAddr_.isValid()) return;

    Mercury::Bundle & bundle = pEntity_->pReal_->pRealChannel_->bundle();
    bundle.startMessage( BaseAppIntInterface::sendToClient );
    bundle << pEntity_->id();
    aoiBundle_.flushToStream( bundle );
    pEntity_->pReal_->pRealChannel_->send();
}
```

**关键**:CellApp **不直接连客户端**,所有客户端流量经 BaseApp 转发。BaseApp 是客户端的"代理",CellApp 是"世界模拟器"。

### 5.8 AoIUpdateScheme

```cpp
// server/cellapp/aoi_update_schemes.hpp
class AoIUpdateScheme {
public:
    void setUpdateHertz( int hz );
    bool shouldUpdate( GameTime now ) const;
private:
    int hz_;
    GameTime lastUpdate_;
};

class AoIUpdateSchemes {
    // 每个 Entity 类型可以有独立的 AOI 更新频率
};
```

---

## 六、空间管理:Space、Cell 与 BSP 树

### 6.1 Space 类(cellapp 端)

```cpp
// server/cellapp/space.hpp
class Space : public TimerHandler, public GeometryMapper
{
public:
    Space( SpaceID id, CellApp & app );
    ~Space();

    Cell * pCell() const               { return pCell_; }
    void cell( Cell * pCell )          { pCell_ = pCell; }

    Cell * createCell( CellID id, const BW::string & data );
    void destroyCell( Cell * pCell );

    // Entity 管理
    void addEntity( Entity & e );
    void removeEntity( Entity & e );
    Entity * newEntity( ... );

    // Ghost 创建
    void createGhost( Entity & realEntity, ... );

    // SpaceData
    void spaceDataEntry( SpaceEntryID & entryID, const BW::string & data );

    // BSP
    CellInfo * pCellInfoTree() const   { return pCellInfoTree_; }

private:
    Cell *              pCell_;            // 本 CellApp 上该 Space 的 Cell(可能 NULL)
    Spaces *            pSpaces_;
    PhysicalSpace *     pPhysicalSpace_;   // 物理空间(碰撞/导航)
    SpaceDataMapping *  pSpaceDataMapping_;
    Cell::Entities      entities_;         // 本 Cell 上的实体
    CellInfos           cellInfos_;        // 本 CellApp 知道的所有 CellInfo
    RangeList *         pRangeList_;       // AOI 用的范围列表
    CellInfo *          pCellInfoTree_;    // BSP 树根(本 CellApp 视角)
};
```

### 6.2 Cell 类

```cpp
// server/cellapp/cell.hpp L51-81
class Cell {
public:
    class Entities {
    public:
        // 注意:只存 Real Entity,Ghost 不在这里
        void add( Entity * pEntity );
        void erase( Entity * pEntity );
    private:
        typedef BW::set<Entity*> Container;
        Container container_;
    };

    Cell( Space & space, CellID id );
    ~Cell();

    Entity * createEntity( const EntityData & data, ... );
    void destroyEntity( Entity * pEntity );

    void backup();   // 备份所有 Real Entity 到 BaseApp
    void offloadEntity( Entity & e, CellAppChannel & channel );

    Space & space()                 { return space_; }
    Entities & entities()           { return entities_; }

private:
    Space &     space_;
    CellID      id_;
    Entities    entities_;          // **只存 Real Entity**
    // ...
};
```

**关键澄清**:**EntityContainer 类不存在**(全局搜索确认)。CellApp 用 `Cell::Entities` 内嵌类替代,只存 Real Entity(Ghost 在 `Space::entities_` 或单独管理)。

### 6.3 CellInfo(BSP 叶子)

```cpp
// server/cellapp/cell_info.hpp
class CellInfo : public SpaceNode, public ReferenceCount
{
public:
    CellInfo( Space & space, const Rect & rect, CellAppChannel * pChannel );
    // 注意:CellInfo 是 BSP 叶子,SpaceNode 是 BSP 节点基类

    const Rect & rect() const         { return rect_; }
    CellAppChannel * pChannel() const { return pChannel_; }

private:
    Rect                rect_;
    CellAppChannel *    pChannel_;   // 该 Cell 所属的 CellApp 通道(若非本 CellApp,则是 Ghost)
};
```

### 6.4 BSP 树构建

CellApp 上的 BSP 树**镜像**了 CellAppMgr 上的 BSP 树,但只包含与本 CellApp 相关的子集:

- **本 CellApp 持有的 Cell**:对应 `CellInfo` 的 `pChannel_` 指向自己的内部通道。
- **其他 CellApp 持有的 Ghost**:对应 `CellInfo` 的 `pChannel_` 指向那个 CellApp 的 `CellAppChannel`。

`EntityGhostMaintainer` 遍历这棵 BSP 树,判断哪些 CellApp 需要 Ghost。

### 6.5 Spaces / Cells 容器

```cpp
// server/cellapp/spaces.hpp
class Spaces {
public:
    Space * find( SpaceID id ) const;
    Space * create( SpaceID id, ... );
    void    destroy( SpaceID id );
    void    tick( GameTime time );
    void    addWatchers();
private:
    typedef BW::map<SpaceID, Space*> Map;
    Map map_;
};

// server/cellapp/cells.hpp
class Cells {
public:
    Cell * find( SpaceID id ) const;
    void   add( Cell * pCell );
    void   erase( SpaceID id );
    void   tick( GameTime time );
    void   handleCellAppDeath( const Mercury::Address & addr );
    void   adjustForDeadBaseApp( ... );
private:
    typedef BW::map<SpaceID, Cell*> Map;
    Map map_;
};
```

### 6.6 SpaceDataMapping

```cpp
// lib/network/space_data_mapping.hpp
class SpaceDataMapping {
public:
    // 存储 Space 的键值对数据(由 CellAppMgr 下发)
    void setEntry( SpaceEntryID id, const BW::string & key, const BW::string & value );
    const BW::string * getEntry( const BW::string & key ) const;
};

// lib/network/space_data_mappings.hpp
class SpaceDataMappings {
    // 多个 Space 的 SpaceDataMapping 集合
};
```

**关键澄清**:`space_data_mappings.hpp` 位于 `lib/network/` 而非 `server/cellapp/`,因为 BaseApp 也需要使用(BigWorld 早期版本路径混乱)。

### 6.7 Space 创建流程

```
1. BaseAppMgr 收到 createEntityInNewSpace
2. 转发给 CellAppMgr::createEntityInNewSpace (L728)
3. CellAppMgr 创建 Space,选最低负载 CellApp
4. CellAppMgr 给 CellApp 发 CellAppInterface::createCell
5. CellApp 收到后:
   ├─ Spaces::create(spaceID) 创建 Space
   ├─ Space::createCell 创建 Cell
   ├─ 初始化 BSP 树(单叶子)
   └─ 通知 CellAppMgr(若需要)
6. CellAppMgr 在 CellAppMgr 侧也创建 Space + CellData(BSP 叶子)
```

---

## 七、跨进程通信

### 7.1 CellAppMgrGateway

```cpp
// server/cellapp/cellappmgr_gateway.hpp
class CellAppMgrGateway : public ManagerAppGateway
{
public:
    CellAppMgrGateway( Mercury::NetworkInterface & interface );

    // 启动消息
    void add( CellAppID id );
    void startup();

    // 负载上报
    void informOfLoad( float currLoad, float extraLoad );

    // 死亡 ACK
    void ackCellAppDeath( CellAppID deadID );
    void ackShutdown();

    // 边界更新
    void updateBounds( ... );

    // 复活处理
    void onManagerRebirth();

    // Space 关停
    void shutDownSpace( SpaceID id );
};
```

继承 `ManagerAppGateway`(`lib/server/manager_app_gateway.hpp`),提供"通道管理 + 自动重连"基础能力。

### 7.2 Mailbox 体系

CellApp 上的 Mailbox 用于"调用其他进程上的实体方法",共 7 种组件类型:

```cpp
// server/cellapp/mailbox.hpp
// 基类
class ServerEntityMailBox : public ScriptObject { ... };

// 7 种派生 mailbox
class CellEntityMailBox       : public ServerEntityMailBox { ... };  // 调用其他 CellApp 上的 Entity
class BaseEntityMailBox       : public ServerEntityMailBox { ... };  // 调用本进程 Real Base 所在 BaseApp 上的 Base
class CommonBaseEntityMailBox : public ServerEntityMailBox { ... };  // 调用任意 BaseApp 上的 Base

// 复合 mailbox(经过中间进程转发)
class BaseViaCellMailBox      : public ServerEntityMailBox { ... };  // 客户端 → CellApp → BaseApp
class ClientViaCellMailBox    : public ServerEntityMailBox { ... };  // CellApp → BaseApp → Client
class CellViaBaseMailBox      : public ServerEntityMailBox { ... };  // CellApp → BaseApp → 另一 CellApp
class ClientViaBaseMailBox    : public ServerEntityMailBox { ... };  // CellApp → BaseApp → Client
```

#### adjustForDeadBaseApp(mailbox.cpp:645-654)

```cpp
void ServerEntityMailBox::adjustForDeadBaseApp(
    const Mercury::Address & deadAddr,
    const Mercury::Address & newAddr )
{
    if (pChannel_->addr == deadAddr) {
        pChannel_ = interface_.findOrCreateChannel( newAddr );
    }
}
```

BaseApp 死亡后,所有指向死 BaseApp 的 mailbox 自动重定向到新 BaseApp。

### 7.3 CellAppChannel / CellAppChannels

```cpp
// server/cellapp/cell_app_channel.hpp
class CellAppChannel : public Mercury::ChannelOwner {
public:
    CellAppChannel( const Mercury::Address & addr,
        Mercury::NetworkInterface & interface );
    void sendTickComplete( GameTime time );
    bool hasReceivedTime( GameTime time ) const;
private:
    GameTime lastReceivedTime_;
};

// server/cellapp/cell_app_channels.hpp
class CellAppChannels {
public:
    CellAppChannel * get( const Mercury::Address & addr, bool createIfMissing );
    void sendTickCompleteToAll( GameTime time );
    bool haveAllChannelsReceivedTime( GameTime time ) const;
    void handleCellAppDeath( const Mercury::Address & addr );
private:
    typedef BW::map<Mercury::Address, CellAppChannel*> Map;
    Map map_;
};
```

### 7.4 跨 CellApp Tick 同步

BigWorld 通过"每 tick 互相发送 `tickComplete`"来同步所有 CellApp 的进度:

```
tick N 开始
   │
   ├─ 每个 CellApp 各自跑 tick N 的逻辑
   │
   ├─ tick N 结束(onEndOfTick)
   │   └─ 给所有其他 CellApp 发送 tickComplete(N)
   │
   ├─ 等待所有其他 CellApp 的 tickComplete(N)到达
   │
   └─ haveAllChannelsReceivedTime(N) == true → 开始 tick N+1
```

**关键**:这保证了**跨 CellApp 的实体调用时序一致**——CellApp A 在 tick N 调用 CellApp B 上的实体方法,该方法会在 CellApp B 的 tick N+1 才被执行,不会出现"未来调用过去"。

### 7.5 handleCellAppDeath 流程

```
1. CellAppMgr 收到 machined 通知
2. CellAppMgr 给所有 CellApp 发 ackCellAppDeath(deadID)
3. 每个 CellApp 收到后:
   ├─ CellAppDeathListeners::notify(addr) — 通知所有监听者
   ├─ cells_.handleCellAppDeath(addr) — 清理引用死 CellApp 的 Mailbox
   ├─ pCellAppChannels_->handleCellAppDeath(addr) — 关闭通道
   └─ cellAppMgr_.ackCellAppDeath(deadID) — 回 ACK
4. CellAppMgr 收齐所有 ACK → 真正清理 CellApp 视图
5. CellAppMgr 通知 BaseAppMgr → BaseApp 重新选择 CellApp 创建 Entity
```

### 7.6 AckCellAppDeathHelper

```cpp
// server/cellapp/ack_cell_app_death_helper.hpp
class AckCellAppDeathHelper : public TimerHandler,
    public ShutdownSafeReplyMessageHandler
{
public:
    AckCellAppDeathHelper( CellApp & app, CellAppID deadAppID );
    void sendAck();
private:
    void handleTimeout( TimerHandle, void * ) /* override */;
    CellApp &   app_;
    CellAppID   deadAppID_;
    TimerHandle timer_;
};
```

**职责**:确保 ACK 一定能送达。若超时未收到回复,重发。

### 7.7 CellAppDeathListener

```cpp
// server/cellapp/cellapp_death_listener.hpp
class CellAppDeathListener {
public:
    virtual void onCellAppDeath( const Mercury::Address & addr ) = 0;
};

class CellAppDeathListeners {
public:
    static void add( CellAppDeathListener * pListener );
    static void notify( const Mercury::Address & addr );
};
```

**用途**:任何 CellApp 内部组件若关心 CellApp 死亡事件,实现该接口并注册即可。例如:
- `CellAppChannels`:关闭通道
- `Cells`:清理 Mailbox
- `RealEntity`:销毁指向死 CellApp 的 Haunt

### 7.8 Ghost 消息缓冲

```cpp
// server/cellapp/buffered_ghost_message.hpp
class BufferedGhostMessage {
    // 当 Ghost 还没就绪时,先收到的 Real 推送消息需要缓冲
};

class BufferedGhostMessages {
    // 按 EntityID 分组的缓冲队列
};
```

**场景**:Real Entity 推送属性更新到 Ghost,但 Ghost 还在创建过程中(异步消息往返),此时 CellApp 把消息缓冲,等 Ghost 就绪后批量处理。

### 7.9 HistoryEvent / EventHistory

```cpp
// server/cellapp/history_event.hpp
class HistoryEvent : public ReferenceCount {
    // 实体事件(如属性变化、方法调用)的历史记录
};

class EventHistory {
public:
    void add( HistoryEvent * pEvent );
    void trim( GameTime before );
private:
    typedef BW::list<HistoryEvent*> Events;
    Events events_;
};
```

**关键澄清**:**HistoryServer 不存在**。CellApp 仅有 `HistoryEvent`/`EventHistory` 用于实体事件历史(主要用于 Ghost 同步:Ghost 创建时拉取 Real 的事件历史,补齐到当前状态)。

### 7.10 BackupHash / BackupHashChain

```cpp
// lib/server/backup_hash.hpp
class BackupHash {
    // BaseApp 死亡后,把其上的 Entity 迁移到其他 BaseApp 的哈希表
};

// lib/server/backup_hash_chain.hpp
class BackupHashChain {
    // 多次 BaseApp 死亡/恢复形成的哈希链
};
```

CellApp 不直接使用,但通过 BaseApp 间接关联。

---

## 八、备份与容错

### 8.1 备份模型(无 BackupSender)

**关键澄清**:CellApp **没有独立的 BackupSender 类**(那是 BaseApp 独有)。备份通过 `RealEntity::backup()` 直接推到 BaseApp:

```
CellApp                            BaseApp
   │                                 │
   │ RealEntity::backup()            │
   │ (每 backupPeriod=10s 触发)      │
   │                                 │
   │ BaseAppIntInterface::           │
   │   backupCellEntity              │
   ├────────────────────────────────►│
   │                                 │
   │                                 ├─ BaseApp::backupCellEntity
   │                                 │   ├─ 更新 Base 的属性
   │                                 │   └─ 触发 Base 持久化到 DBApp
   │                                 │
   │                                 │
```

### 8.2 CellApp 死亡时 Real 重建

```
1. CellApp X 死亡
2. machined → CellAppMgr::handleCellAppDeath
3. CellAppMgr 通知 BaseAppMgr
4. BaseAppMgr 通知所有 BaseApp:重新创建 Real Entity
5. 每个 BaseApp:
   ├─ 找出原本在 CellApp X 上的 Real Entity
   ├─ 向 CellAppMgr 请求 createEntity(在新 CellApp 上)
   └─ CellAppMgr 选最低负载 CellApp,转发 createEntity
6. 新 CellApp 上 Entity 重建,RealEntity::init(FROM_RESTORE)
7. BaseApp 的 Real Base 更新 mailbox 指向新 CellApp
```

### 8.3 BaseApp 死亡时邮箱重定向

```
1. BaseApp X 死亡
2. BaseAppMgr 检测到,选新 BaseApp 接管
3. BaseAppMgr 通知所有 CellApp:handleBaseAppDeath(deadAddr, newAddr)
4. CellApp::handleBaseAppDeath (L1804-1857):
   ├─ cells_.adjustForDeadBaseApp(deadAddr, newAddr)
   │   └─ 所有 ServerEntityMailBox 重定向到新 BaseApp
   └─ cells_.rebaseRealChannels(deadAddr, newAddr)
       └─ RealEntity::pRealChannel_ 重连到新 BaseApp
5. 新 BaseApp 接管 Real Base,继续接收 backupCellEntity
```

### 8.4 双向容错对比

| 场景 | 数据来源 | 重建方式 |
|------|---------|---------|
| CellApp 死亡 → Real Entity 丢失 | BaseApp 有最近一次 backup 的属性 | BaseApp 重新请求 CellAppMgr 创建 Entity |
| BaseApp 死亡 → Real Base 丢失 | DBApp 有持久化的 Entity 数据 | DBApp 重新加载 Base,Base 重新创建 Real Entity |
| CellApp Ghost 死亡 | Real Entity 还在 | Real Entity 自动重新创建 Ghost(经 EntityGhostMaintainer) |

---

## 九、Tick 同步与游戏时间

### 9.1 TimeKeeper 体系

```cpp
// lib/server/time_keeper.hpp
class TimeKeeper {
public:
    TimeKeeper( Mercury::NetworkInterface & interface,
        const BW::string & storageDir );
    GameTime gameTime() const          { return *pGameTime_; }
    void gameTimerInited()             { /* 持久化到 DB */ }
    void advanceTime()                 { ++*pGameTime_; }
private:
    GameTime *     pGameTime_;
    Mercury::NetworkInterface & interface_;
};
```

- **CellAppMgr** 持有 TimeKeeper,每 10Hz 调用 `advanceTime()`。
- **CellApp** 在 `addApp` 时通过 `CellAppInitData.time` 拿到当前 gameTime,本地自增。
- 两者的 gameTime **必须严格对齐**,通过 `sendTickCompleteToAll` 保证。

### 9.2 跨 CellApp 同步流程

```
CellAppMgr                CellApp A              CellApp B
    │                          │                       │
    │ tick N: advanceTime      │                       │
    │                          │                       │
    │                          │ tick N 处理           │
    │                          │ onStartOfTick         │
    │                          │ witnesses.update      │
    │                          │ cells.tick            │
    │                          │ onEndOfTick           │
    │                          │   ├─ sendTickCompleteToAll(N)
    │                          │   ├──────────────────►│ tickComplete(N)
    │                          │   │                   │
    │                          │                       │ tick N 处理
    │                          │                       │ onStartOfTick
    │                          │                       │ witnesses.update
    │                          │                       │ cells.tick
    │                          │                       │ onEndOfTick
    │                          │                       │   ├─ sendTickCompleteToAll(N)
    │                          │◄─┼────────────────────│ tickComplete(N)
    │                          │   │                   │
    │                          │ haveAllChannelsReceivedTime(N) == true
    │                          │ → 开始 tick N+1       │
    │                          │                       │ → 开始 tick N+1
```

### 9.3 tick 节流

```cpp
// cellapp.cpp 中
float throttle_ = reservedTickFraction;  // 0.05
// 每个 tick 实际可用时间 = 100ms * (1 - 0.05) = 95ms
// 剩余 5ms 留给其他后台任务
```

`reservedTickFraction` 配置项控制:每个 tick 留多少比例给 IO/脚本/网络等次要任务。

---

## 十、配置项速查

### 10.1 CellAppMgrConfig

| 配置项 | 默认值 | 含义 |
|--------|--------|------|
| `maxLoadingCells` | 4 | 单个 CellApp 同时加载的 Cell 数上限 |
| `cellAppTimeout` | 3s | CellApp 心跳超时 |
| `loadBalancePeriod` | 1s | 第1层负载均衡周期 |
| `metaLoadBalancePeriod` | 3s | 第2层负载均衡周期 |
| `estimatedInitialCellLoad` | 0.1 | 新建 Cell 的预估负载 |
| `loadSmoothingBias` | 0.05 | 负载 EWMA 平滑系数 |

### 10.2 LoginConditionsConfig

| 配置项 | 默认值 | 含义 |
|--------|--------|------|
| `avgLoad` | 0.85 | 平均负载阈值 |
| `maxLoad` | 0.95 | 单进程最大负载阈值 |
| `tolerancePeriod` | 30 | 容忍秒数(连续超阈值才拒绝登录) |

### 10.3 CellAppConfig(核心项)

| 配置项 | 默认值 | 含义 |
|--------|--------|------|
| `loadSmoothingBias` | 0.05 | 负载 EWMA 平滑系数 |
| `ghostDistance` | 500 | Ghost 距离(超出则不维护 Ghost) |
| `defaultAoIRadius` | 500 | 默认 AOI 半径 |
| `backupPeriod` | 10s | Real Entity 备份到 BaseApp 的周期 |
| `ghostUpdateHertz` | 50 | Ghost 属性更新频率 |
| `reservedTickFraction` | 0.05 | tick 节流(预留 5%) |
| `chunkLoadingPeriod` | 0.02 | Chunk 加载周期 |
| `gameHertz` | 10 | 游戏 tick 频率 |
| `loadingHertz` | 50 | 加载阶段 tick 频率 |
| `trimHistoryPeriod` | 240s | 历史清理周期 |

---

## 十一、消息处理表

### 11.1 CellAppMgrInterface 消息

| 消息 | 处理方法 | 行号 | 说明 |
|------|---------|------|------|
| `addApp` | `addApp` | L1245 | 新 CellApp 注册 |
| `recoverCellApp` | `recoverCellApp` | L1390 | CellApp 恢复(沿用原 ID) |
| `startup` | `startup` | L1755 | CellApp 完成初始化 |
| `informOfLoad` | `informOfLoad` | - | CellApp 上报负载 |
| `retireApp` | `retireApp` | - | CellApp 请求退役 |
| `ackCellAppDeath` | `ackCellAppDeath` | - | CellApp 回 ACK |
| `ackShutdown` | `ackShutdown` | - | CellApp 关停 ACK |
| `createEntity` | `createEntity` | L967 | 在指定 Space 创建实体 |
| `createEntityInNewSpace` | `createEntityInNewSpace` | L728 | 在新 Space 创建实体 |
| `handleCellAppDeath` | `handleCellAppDeath` | L1806 | machined 死亡通知 |
| `handleBaseAppMgrBirth` | `handleBaseAppMgrBirth` | - | BaseAppMgr 复活 |
| `handleBaseAppBirth` | `handleBaseAppBirth` | - | BaseApp 就绪 |
| `handleDBAppMgrBirth` | `handleDBAppMgrBirth` | - | DBAppMgr 复活 |
| `setDBAppAlpha` | `setDBAppAlpha` | - | DBApp Alpha 地址更新 |
| `controlledShutDown` | `controlledShutDown` | L1138 | 受控关停 |
| `handleTimeout` | `handleTimeout` | L2297 | 三类定时器触发 |
| `writeSpacesToDB` | `writeSpacesToDB` | L2457 | Space 持久化 |

### 11.2 CellAppInterface 消息

| 消息分类 | 消息 | 说明 |
|---------|------|------|
| **CellApp 级** | `createCell` | 在指定 Space 创建 Cell |
| | `destroyCell` | 销毁 Cell |
| | `ackCellAppDeath` | ACK 某个 CellApp 死亡 |
| | `informOfLoad` | 上报本 CellApp 负载 |
| | `startup` | 通知 CellAppMgr 启动完成 |
| **Space 级** | `createEntity` | 在指定 Space 创建 Entity |
| | `shutDownSpace` | 关停 Space |
| | `spaceData` | Space 数据更新 |
| **Cell 级** | `backup` | 备份所有 Real Entity |
| | `onloadEntity` | 接收 offload 过来的 Real |
| **Entity 级** | `createEntity` | 创建 Entity(细粒度) |
| | `destroyEntity` | 销毁 Entity |
| | `callMethod` | 调用 Entity 方法 |
| | `convertRealToGhost` | Real 转 Ghost |
| | `convertGhostToReal` | Ghost 转 Real |

### 11.3 EntityReality 枚举(cellapp_interface.hpp)

```cpp
enum EntityReality {
    GHOST_ONLY,    // 只在 Ghost 上调用
    REAL_ONLY,     // 只在 Real 上调用
    WITNESS_ONLY   // 只在有 Witness 的 Real 上调用
};
```

用于 Entity 级消息的派发过滤:某些方法只对 Real 有意义(如修改持久化属性),某些只对 Witness 有意义(如客户端可见状态)。

---

## 十二、关键文件路径速查

### 12.1 CellAppMgr

| 类别 | 文件路径 |
|------|---------|
| 入口 | `server/cellappmgr/main.cpp` |
| 核心 | `server/cellappmgr/cellappmgr.hpp/.cpp` |
| CellApp 视图 | `server/cellappmgr/cellapp.hpp/.cpp` |
| CellApps 集合 | `server/cellappmgr/cellapps.hpp/.cpp` |
| Space | `server/cellappmgr/space.hpp/.cpp/.ipp` |
| CellData | `server/cellappmgr/cell_data.hpp/.cpp/.ipp` |
| CellAppGroup | `server/cellappmgr/cell_app_group.hpp/.cpp` |
| CellAppGroups | `server/cellappmgr/cell_app_groups.hpp/.cpp` |
| 死亡处理 | `server/cellappmgr/cell_app_death_handler.hpp/.cpp` |
| 关停处理 | `server/cellappmgr/shutdown_handler.hpp/.cpp` |
| 配置 | `server/cellappmgr/cellappmgr_config.hpp/.cpp` |
| 登录条件 | `server/cellappmgr/login_conditions_config.hpp/.cpp` |
| 消息定义 | `server/cellappmgr/cellappmgr_interface.hpp` |

### 12.2 CellApp 核心

| 类别 | 文件路径 |
|------|---------|
| 入口 | `server/cellapp/main.cpp` |
| 核心 | `server/cellapp/cellapp.hpp/.cpp` |
| 配置 | `server/cellapp/cellapp_config.hpp/.cpp` |
| 消息定义 | `server/cellapp/cellapp_interface.hpp` |
| 注册辅助 | `server/cellapp/add_to_cellappmgr_helper.hpp` |
| 网关 | `server/cellapp/cellappmgr_gateway.hpp/.cpp` |
| 初始化数据 | `lib/server/cell_app_init_data.hpp` |

### 12.3 Entity / Ghost

| 类别 | 文件路径 |
|------|---------|
| Entity | `server/cellapp/entity.hpp/.cpp/.ipp` |
| RealEntity | `server/cellapp/real_entity.hpp/.cpp` |
| EntityType | `server/cellapp/entity_type.hpp/.cpp/.ipp` |
| Ghost 维护 | `server/cellapp/entity_ghost_maintainer.hpp/.cpp` |
| Offload 检查 | `server/cellapp/offload_checker.hpp/.cpp` |
| IDClient | `lib/server/id_client.hpp/.cpp` |

### 12.4 Witness / AOI

| 类别 | 文件路径 |
|------|---------|
| Witness | `server/cellapp/witness.hpp/.cpp` |
| EntityCache | `server/cellapp/entity_cache.hpp` |
| AoI 策略 | `server/cellapp/aoi_update_schemes.hpp/.cpp` |

### 12.5 空间管理

| 类别 | 文件路径 |
|------|---------|
| Space | `server/cellapp/space.hpp/.cpp` |
| Spaces | `server/cellapp/spaces.hpp/.cpp` |
| Cell | `server/cellapp/cell.hpp/.cpp` |
| Cells | `server/cellapp/cells.hpp/.cpp` |
| CellInfo | `server/cellapp/cell_info.hpp` |
| SpaceDataMapping | `lib/network/space_data_mapping.hpp/.cpp` |
| SpaceDataMappings | `lib/network/space_data_mappings.hpp` |

### 12.6 跨进程通信

| 类别 | 文件路径 |
|------|---------|
| Mailbox | `server/cellapp/mailbox.hpp/.cpp` |
| CellAppChannel | `server/cellapp/cell_app_channel.hpp/.cpp` |
| CellAppChannels | `server/cellapp/cell_app_channels.hpp/.cpp` |
| ACK 死亡辅助 | `server/cellapp/ack_cell_app_death_helper.hpp/.cpp` |
| 死亡监听 | `server/cellapp/cellapp_death_listener.hpp/.cpp` |
| Ghost 消息缓冲 | `server/cellapp/buffered_ghost_message*.hpp/.cpp` |
| 历史事件 | `server/cellapp/history_event.hpp/.cpp/.ipp` |
| 消息路由 | `server/cellapp/message_handlers.cpp` |
| ManagerAppGateway | `lib/server/manager_app_gateway.hpp` |
| TimeKeeper | `lib/server/time_keeper.hpp` |
| BackupHash | `lib/server/backup_hash.hpp` |
| BackupHashChain | `lib/server/backup_hash_chain.hpp` |

### 12.7 公共

| 类别 | 文件路径 |
|------|---------|
| ShutDownStage 枚举 | `lib/server/common.hpp` |
| BSPNode | `lib/scene/bsp_node.hpp` |

---

## 十三、设计亮点与注意事项

### 13.1 设计亮点

#### 1. 控制平面/数据平面分离

CellAppMgr 只做调度不持实体,CellApp 只持实体不调度。这种分离让 CellAppMgr 可以专注做负载均衡决策,CellApp 专注做游戏模拟,两者职责清晰。

#### 2. 两层负载均衡

- 第1层(1s):Space 内 Cell 边界微调,低成本、不跨进程。
- 第2层(3s):跨 CellApp 整 Cell 迁移,高成本、影响大。
- 频率差异:细粒度高频,粗粒度低频,平衡精度与开销。

#### 3. 元负载均衡分组(洪水填充)

`CellAppGroup` 通过"同 Space 且 Cell 邻接"递归洪水填充形成,确保 `metaLoadBalance` 只在"真正需要互通的 CellApp 之间"做迁移,避免跨 Space 干扰。

#### 4. BSP 树空间分割

- CellAppMgr 与每个 CellApp 都维护 BSP 树。
- CellAppMgr 的树是"权威树",CellApp 的树是"镜像子集"。
- BSP 让空间查询(O(log N))、Cell 定位、Ghost 维护都高效。

#### 5. Ghost 即"轻量 Entity"

Ghost 不是独立类,而是 `pReal_==NULL` 的 Entity。这种设计:
- 复用 Entity 的所有属性存储代码。
- Real↔Ghost 转换只需增删 `pReal_`,无需重新分配 Entity。
- 通用代码可通过 `isReal()`/`isGhost()` 分支处理。

#### 6. RealEntity 持有 Haunt 列表

`RealEntity::haunts_` 列表记录"本 Real 在哪些 CellApp 上有 Ghost",反向推送属性时直接遍历这个列表,无需查 BSP 树。

#### 7. 跨 CellApp Tick 同步

通过 `sendTickCompleteToAll` + `haveAllChannelsReceivedTime` 实现"barrier 同步",保证跨 CellApp 的实体调用时序严格一致。

#### 8. ACK 死亡处理

CellAppMgr 等所有 CellApp 回 ACK 才真正清理死亡 CellApp,避免悬空引用。`AckCellAppDeathHelper` 提供超时重发,确保 ACK 可靠。

#### 9. 批量 ID 申请

IDClient 向 DBApp Alpha 一次申请 100 个 EntityID,本地缓存。减少跨进程往返,提升创建实体吞吐。

#### 10. 受控关停简化

CellApp 只处理 `SHUTDOWN_INFORM` 阶段,关停流程由 CellAppMgr 的 `ShutDownHandler` 统一编排。简化了 CellApp 的关停逻辑。

### 13.2 注意事项

#### 1. CellApp 无 two-way 调用

所有 mailbox `getStream` 检测到 `pHandler` 非空时报错。`TwoWayMethodForwardingReplyHandler` 仅在 BaseApp 端存在。若脚本误用 two-way 调用,会立即报错。

#### 2. CellApp 不直连客户端

所有客户端流量经 BaseApp 转发(`BaseAppIntInterface::sendToClient`)。BaseApp 是客户端的代理,CellApp 是世界模拟器。这种分层让 CellApp 可以无状态地处理玩家切换。

#### 3. CellApp 无 BackupSender

备份通过 `RealEntity::backup()` 直接推到 BaseApp,没有独立的 BackupSender 类。这与 BaseApp 的 BackupSender(向 DBApp 推送)形成对比。

#### 4. CellApp 无 InitStateFlags

CellApp 用 `isReadyToStart_` 布尔值与 `hasStarted()`(基于 `gameTimer_.isSet()`)判断状态,不像 DBApp 有 `InitStateFlags` 状态机。

#### 5. CellApp 受控关停仅 SHUTDOWN_INFORM

CellApp 只处理 `SHUTDOWN_INFORM` 阶段,不处理 `SHUTDOWN_REQUEST`/`SHUTDOWN_PERFORM` 等。`controlled_shutdown_handler.hpp` 仅存在于 BaseApp。

#### 6. CellApp 无 ComponentApp/ChannelListener

CellApp 继承链是 `EntityApp → ScriptApp → ServerApp` + TimerHandler + GeometryMapper + Singleton。`ComponentApp` 在整个代码库中不存在,`ChannelListener` 仅在客户端 `ServerConnection` 中。

#### 7. Ghost 不是独立类

`ghost.hpp` 文件不存在。所有 Ghost 行为在 `entity.cpp` 中通过 `if (pReal_)` 分支处理。

#### 8. EntityContainer 不存在

`EntityContainer` 类不存在,CellApp 用 `Cell::Entities` 内嵌类替代,只存 Real Entity。

#### 9. EntityCreator 不存在于 CellApp

`EntityCreator` 仅在 BaseApp,CellApp 的实体创建直接在 `Cell::createEntity` 中处理。

#### 10. pWitness_ 在 RealEntity 而非 Entity

`pWitness_` 是 `RealEntity` 的成员(L243),不是 `Entity` 的成员。因为只有 Real 才能是玩家,Ghost 不能有 Witness。

#### 11. callCellMethod 不存在

CellApp 没有 `callCellMethod` 函数。跨 CellApp 调用通过 `CellEntityMailBox` 完成。

#### 12. dead_base_apps.hpp 不存在于 CellApp

`dead_base_apps.hpp` 仅在 BaseApp,CellApp 用 `adjustForDeadBaseApp` 直接重定向 mailbox。

#### 13. switchBaseApp 是客户端协议

`switchBaseApp` 不在 CellApp 代码中,是 `ClientInterface` 的消息,由 BaseApp/Proxy 发给客户端。

#### 14. CellAppMgr 不使用 ManagedAppSubSet

`ManagedAppSubSet` 仅存在于 BaseAppMgr。CellAppMgr 使用扁平 `CellApps` map + `CellAppGroup`/`CellAppGroups` 元分组。

#### 15. space_data_mappings.hpp 在 lib/network

`space_data_mappings.hpp` 位于 `lib/network/` 而非 `server/cellapp/`,因为 BaseApp 也需要使用。

#### 16. entity_defs.hpp 不存在

`entity_defs.hpp` 文件不存在(那是早期版本的产物),14.4.1 用 `entity_description_map.hpp` 替代。

#### 17. script_callbacks.cpp 不存在

`script_callbacks.cpp` 不存在,相关功能在 `script_bigworld.cpp` 中。

---

## 附录 A:常见误区澄清

| 误区 | 真相 |
|------|------|
| CellApp 继承 ComponentApp | ComponentApp 不存在,继承 EntityApp |
| CellApp 继承 ChannelListener | ChannelListener 仅在客户端 |
| CellApp 有 InitStateFlags | InitStateFlags 仅在 DBApp,CellApp 用 isReadyToStart_ |
| CellApp 受控关停四阶段 | 仅处理 SHUTDOWN_INFORM |
| CellApp 有 controlled_shutdown_handler.hpp | 仅 BaseApp 有 |
| Ghost 是独立类(ghost.hpp) | Ghost 是 pReal_==NULL 的 Entity |
| CellApp 有 EntityContainer | 不存在,用 Cell::Entities 内嵌类 |
| CellApp 有 EntityCreator | 仅 BaseApp 有 |
| pWitness_ 在 Entity | 在 RealEntity |
| CellApp 有 callCellMethod | 不存在,用 CellEntityMailBox |
| CellApp 有 BackupSender | 仅 BaseApp 有,CellApp 用 RealEntity::backup() |
| CellApp 有 dead_base_apps.hpp | 仅 BaseApp 有 |
| switchBaseApp 在 CellApp | 是客户端协议,BaseApp/Proxy 发给客户端 |
| HistoryServer 存在 | 不存在,仅有 EventHistory |
| CellAppMgr 使用 ManagedAppSubSet | 仅 BaseAppMgr 用,CellAppMgr 用 CellApps + CellAppGroup |
| space_data_mappings.hpp 在 server/cellapp | 在 lib/network |
| entity_defs.hpp 存在 | 不存在,用 entity_description_map.hpp |
| CellApp 支持 two-way 调用 | 不支持,所有 mailbox getStream 检测 pHandler 非空报错 |

---

## 总结

BigWorld 的 CellApp/CellAppMgr 子系统是整个引擎中最复杂的部分,其设计体现了若干关键工程思想:

1. **分层职责**:控制平面(CellAppMgr)与数据平面(CellApp)严格分离。
2. **两层负载均衡**:细粒度高频调整 + 粗粒度低频迁移,精度与开销平衡。
3. **BSP 空间分割**:O(log N) 空间查询,CellAppMgr 与 CellApp 镜像同步。
4. **Ghost 即轻量 Entity**:无独立类,通过 pReal_ 区分,转换零开销。
5. **跨进程 Tick 同步**:barrier 同步保证调用时序严格一致。
6. **ACK 死亡处理**:可靠清理,避免悬空引用。
7. **批量 ID 申请**:减少跨进程往返。
8. **简化关停**:CellApp 只处理 INFORM 阶段,关停流程统一编排。

这些设计让 BigWorld 能够支撑大规模 MMO 世界:数百万实体、数千 CellApp、上百个 Space,在保证一致性的前提下水平扩展。
