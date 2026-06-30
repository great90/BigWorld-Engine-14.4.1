# BigWorld Engine 基础应用 BaseApp 与 BaseAppMgr 实现深度分析

> 本文档详细分析 BigWorld Engine 14.4.1 中 BaseApp 与 BaseAppMgr 两个进程的完整实现,涵盖架构设计、启动流程、负载均衡、备份容错、实体生命周期、客户端连接、跨进程通信、迁移退休、配置体系等所有关键机制。BaseApp 是 BigWorld 服务器集群中最复杂的进程,承担客户端连接、基础实体逻辑、持久化、备份等核心职责;BaseAppMgr 则是 BaseApp 的控制平面,负责进程注册、负载均衡、备份哈希管理与全局 Base 邮箱重定向。

---

## 目录

- [一、整体架构概览](#一整体架构概览)
- [二、BaseAppMgr:基础应用管理器进程](#二baseappmgr基础应用管理器进程)
- [三、BaseApp:基础应用进程](#三baseapp基础应用进程)
- [四、实体管理](#四实体管理)
- [五、脚本系统](#五脚本系统)
- [六、持久化机制](#六持久化机制)
- [七、备份与容错](#七备份与容错)
- [八、Proxy 与客户端连接](#八proxy-与客户端连接)
- [九、跨进程通信](#九跨进程通信)
- [十、实体迁移与退休](#十实体迁移与退休)
- [十一、配置项速查](#十一配置项速查)
- [十二、关键文件路径速查](#十二关键文件路径速查)
- [十三、设计亮点与注意事项](#十三设计亮点与注意事项)

---

## 一、整体架构概览

BigWorld 服务器集群采用**控制平面 + 数据平面**分层架构,BaseApp 与 BaseAppMgr 的关系是这一架构的典型代表:

```
┌──────────────────────────────────────────────────────────────────┐
│ 控制平面 (单例)                                                  │
│   ┌──────────────────────┐                                       │
│   │   BaseAppMgr         │  管理 BaseApp 生命周期                │
│   │ - 子集管理 (Base/Svc)│  负载均衡三层调度                    │
│   │ - BackupHash 维护    │  过载保护与登录准入                   │
│   │ - GlobalBases 重定向 │  受控关停                            │
│   └──────────┬───────────┘                                       │
└──────────────┼───────────────────────────────────────────────────┘
               │ 注册/回复/汇报
               ▼
┌──────────────────────────────────────────────────────────────────┐
│ 数据平面 (多实例,可水平扩展)                                    │
│   ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐  │
│   │   BaseApp #1    │  │   BaseApp #2    │  │   BaseApp #N    │  │
│   │ - Proxy (客户端)│  │ - Proxy         │  │ - ServiceApp    │  │
│   │ - Base 实体     │  │ - Base 实体     │  │ - 全局服务      │  │
│   │ - BackupSender  │◀▶│ - BackedUpBaseApp│◀▶│ - 不接客户端    │  │
│   │ - Archiver      │  │ - Archiver      │  │ - 只跑脚本      │  │
│   │ - SqliteDB      │  │ - SqliteDB      │  │                 │  │
│   └────────┬────────┘  └────────┬────────┘  └────────┬────────┘  │
└────────────┼─────────────────────┼────────────────────┼──────────┘
             │                     │                    │
             ▼                     ▼                    ▼
   ┌─────────────────────────────────────────────────────────────┐
   │ 依赖进程:DBApp(持久化)、CellApp(实体 Ghost/AOI)、LoginApp   │
   └─────────────────────────────────────────────────────────────┘
```

### 1.1 进程拓扑

```
bwmachined (机器守护进程)
    │
    └─ BaseAppMgr (单例)
         │
         ├─ BaseApp (普通基础应用,可多实例)
         │   ├─ 持有 Proxy(客户端连接)
         │   ├─ 持有 Base 实体(Python 脚本对象)
         │   ├─ 持有 BackupSender(备份到对端 BaseApp)
         │   ├─ 持有 Archiver(归档到 DBApp)
         │   ├─ 持有 SqliteDatabase(二级数据库)
         │   └─ 持有 BaseAppMgrGateway / CellAppMgr 通道
         │
         └─ ServiceApp(薄包装,通过 isServiceApp_ 标志区分)
             ├─ 不接客户端(无 Proxy)
             ├─ 只跑全局服务脚本(GlobalBases)
             ├─ 同样参与备份哈希链
             └─ 共用 BaseApp 全部代码
```

### 1.2 与其他进程的关系

| 关系进程 | 方向 | 主要交互 |
|---------|------|---------|
| **BaseAppMgr** | 双向 | 注册、ready 通知、createEntity 调度、负载汇报、死亡接管 |
| **CellAppMgr** | 双向 | createEntityInNewSpace、createEntity、gameTimeReading、空间数据 |
| **CellApp** | 双向 | createCellEntity、cellEntityCreated、callCellMethod、witness |
| **DBApp**(经 DBAppsGateway) | 双向 | getIDs、loadEntity、writeEntity、deleteEntity、logOn、lookupEntity |
| **LoginApp** | 入站 | logOnAttempt → 转发到 DBApp Alpha → 回执后建立 Proxy |
| **其他 BaseApp** | 双向 | 备份链、giveClientTo 客户端迁移、offload 实体迁移 |

### 1.3 类继承关系总览

```
BaseAppMgr 继承链:
  ManagerApp ← ServerApp ← ComponentApp ← Mercury::InputMessageHandler
            + TimerHandler + Singleton<BaseAppMgr>

BaseApp 继承链:
  EntityApp ← ScriptApp ← ServerApp ← ComponentApp ← Mercury::InputMessageHandler
            + TimerHandler + ChannelListener + Singleton<BaseApp>

BaseAppMgr 内部视图类:
  BaseApp : ChannelOwner (持有外部地址、负载、备份哈希等元数据)

BaseApp 侧实体类层次(注意:BaseApp 侧无独立 Entity 基类):
  Proxy ← Base ← PyObjectPlus
  typedef Base BaseOrEntity  // BaseApp 侧 BaseOrEntity 即 Base
```

**关键澄清**:BaseApp 侧**不存在独立的 Entity 类**(Entity 类仅存在于 CellApp、Client、bots 目录)。BaseApp 侧实体层次为 `Proxy → Base → PyObjectPlus`,通过 `typedef Base BaseOrEntity` 复用 Base 作为 BaseOrEntity。这意味着 BaseApp 侧的所有"实体"要么是 Base(无客户端),要么是 Proxy(有客户端)。

---

## 二、BaseAppMgr:基础应用管理器进程

BaseAppMgr 是 BaseApp 的控制平面,**不持有任何游戏实体**,而是管理 BaseApp 进程的生命周期、负载均衡与备份哈希。

### 2.1 源码目录与文件结构

| 文件 | 职责 |
|------|------|
| `server/baseappmgr/main.cpp` | 入口,`bwMainT<BaseAppMgr>(argc, argv)` |
| `server/baseappmgr/baseappmgr.hpp/.cpp` | 核心类 `BaseAppMgr`,继承 `ManagerApp + TimerHandler + Singleton<BaseAppMgr>` |
| `server/baseappmgr/baseapp.hpp/.cpp` | `BaseApp` 内部视图类(BaseAppMgr 对一个 BaseApp 的引用计数句柄) |
| `server/baseappmgr/baseappmgr_config.hpp/.cpp` | `BaseAppMgrConfig` 配置类 |
| `server/baseappmgr/login_conditions_config.hpp/.cpp` | `LoginConditionsConfig` 登录准入配置 |
| `server/baseappmgr/baseappmgr_interface.hpp` | `BaseAppMgrInterface` 消息定义,`BaseAppInitData` 结构 |
| `server/baseappmgr/reply_handlers.hpp/.cpp` | 各类 ReplyHandler |
| `server/baseappmgr/util.hpp` | `BaseAppPtr`(shared_ptr)、`BaseApps`(map)、`AdjustBackupLocationsOp` 枚举 |
| `server/baseappmgr/watcher_forwarding_baseapp.hpp` | Watcher 转发到 BaseApp |

### 2.2 类结构与子集模式

`BaseAppMgr` 内部维护**三类子集**(ManagedAppSubSet 派生),对应 BaseApp 的两种角色:

```cpp
// baseappmgr.hpp
class BaseAppMgr : public ManagerApp, public TimerHandler,
                   public Singleton< BaseAppMgr >
{
private:
    CellAppMgr *                  cellAppMgr_;       // CellAppMgr 通道
    Mercury::ChannelOwner *       dbAppAlpha_;       // DBApp Alpha 通道
    DBAppsGateway                 dbApps_;           // DBApp 哈希表

    ManagedAppSubSet *            pendingApps_;      // 待注册(未完成 init)
    BaseAndServiceAppSubSet *     baseAndServiceApps_; // 已注册的 Base+Service
    BaseAppSubSet *               baseApps_;         // 仅 BaseApp 子集
    ServiceAppSubSet *            serviceApps_;      // 仅 ServiceApp 子集

    BackupHashChain *             pBackupHashChain_; // 备份哈希链
    GlobalBases *                 pGlobalBases_;     // 全局 Base 邮箱表
    ...
};
```

**三种子集类**(`util.hpp` 与 baseappmgr.cpp):

| 子集类 | 容器类型 | 包含 | 用途 |
|--------|---------|------|------|
| `ManagedAppSubSet` | 基类 | — | 抽象接口,提供 `add`/`remove`/`tick` |
| `BaseAppSubSet` : `ManagedAppSubSet` | `BaseApps`(map<id, BaseAppPtr>) | 仅普通 BaseApp | 客户端登录准入、备份哈希 |
| `ServiceAppSubSet` : `ManagedAppSubSet` | `BaseApps` | 仅 ServiceApp | 全局服务,不接客户端 |
| `BaseAndServiceAppSubSet` : `ManagedAppSubSet` | `BaseApps` | BaseApp + ServiceApp | 统一调度(如 createEntity、负载均衡候选池) |

### 2.3 内部 BaseApp 视图类

`BaseApp`(baseappmgr/baseapp.hpp)是 BaseAppMgr 对一个 BaseApp 的元数据视图,**不同于 BaseApp 进程本身**:

```cpp
class BaseApp : public ChannelOwner
{
public:
    BaseApp( NetworkInterface & nub, const Address & addr, BaseAppID id );

    BaseAppID id() const            { return id_; }
    const Address & externalAddr() const { return externalAddr_; }

    float load() const              { return load_; }
    uint16 numBases() const         { return numBases_; }
    uint16 numProxies() const       { return numProxies_; }

    const BackupHash & backupHash() const     { return backupHash_; }
    const BackupHash & newBackupHash() const  { return newBackupHash_; }
    bool isRetiring() const         { return isRetiring_; }
    bool isOffloading() const       { return isOffloading_; }
    bool isServiceApp() const       { return isServiceApp_; }
    bool backingUp() const          { return backingUp_; }

    void addEntity();
    void load( float load, uint16 numBases, uint16 numProxies );
    void retireApp();
    void checkToStartOffloading();
    void adjustBackupLocations( AdjustBackupLocationsOp op,
                                const BaseApp * pDeadApp );
    void useNewBackupHash();
    void updateDBAppHash( BinaryIStream & data );

private:
    BaseAppID       id_;
    Address         externalAddr_;     // 客户端可访问地址
    float           load_;             // 负载值(0.0 ~ 1.0+)
    uint16          numBases_;         // Base 实体数
    uint16          numProxies_;       // Proxy(客户端)数
    BackupHash      backupHash_;       // 当前生效的备份哈希
    BackupHash      newBackupHash_;    // 过渡中的新备份哈希
    bool            isRetiring_;
    bool            isOffloading_;
    bool            isServiceApp_;
    bool            backingUp_;
    ...
};
```

### 2.4 启动流程(init,baseappmgr.cpp:352-437)

```
init() [L352]
  ├─ 阶段1:基类初始化 + 接口注册 [L355-378]
  │   ├─ ManagerApp::init(argc, argv)
  │   ├─ 校验 interface().isGood()
  │   ├─ BaseAppMgrInterface::registerWithInterface(interface_)
  │   └─ 创建 pendingApps_/baseAndServiceApps_/baseApps_/serviceApps_ 子集
  │
  ├─ 阶段2:定位 CellAppMgr 与 DBApp Alpha [L380-402]
  │   ├─ MachineDaemon::findInterface(..., "CellAppMgrInterface", numStartupRetries)
  │   └─ 同步阻塞获取 CellAppMgr 地址
  │
  ├─ 阶段3:向 machined 注册与监听 [L404-420]
  │   ├─ BaseAppMgrInterface::registerWithMachined
  │   ├─ registerBirthListener(handleBaseAppMgrBirth) — 唯一性
  │   ├─ registerDeathListener(handleBaseAppDeath, "BaseAppIntInterface")
  │   ├─ registerBirthListener(handleCellAppMgrBirth)
  │   └─ registerBirthListener(handleDBAppMgrBirth)
  │
  ├─ 阶段4:Reviver 注册 [L422]
  │   └─ ReviverSubject::init(&interface_, "baseAppMgr")
  │
  ├─ 阶段5:定时器 [L424-430]
  │   ├─ tickTimer_ = addTimer(1000000/updateHertz, TIMEOUT_TICK)
  │   └─ 内含 onStartOfTick 钩子
  │
  └─ 阶段6:Watcher [L432-437]
      ├─ BW_REGISTER_WATCHER
      └─ addWatchers()
```

### 2.5 BaseApp 注册流程(两阶段)

BaseAppMgr 采用**两阶段注册**机制,BaseApp 必须先 `add` 注册元数据,再 `finishedInit` 完成初始化:

#### 阶段一:add(baseappmgr.cpp:992-1043)

```cpp
void BaseAppMgr::add( const Address & srcAddr,
                      const UnpackedMessageHeader & header,
                      BinaryIStream & data )
{
    // 1. 解析注册数据
    BaseAppInitData initData;
    data >> initData;  // { id, time, isReady, timeoutPeriod }
    
    // 2. 从 pendingApps_ 移除
    pendingApps_->erase( srcAddr );
    
    // 3. 创建视图对象
    BaseAppPtr pBaseApp = new BaseApp( interface_, srcAddr, initData.id );
    pBaseApp->externalAddr( initData.externalAddr );
    pBaseApp->isServiceApp( initData.isServiceApp );
    
    // 4. 加入 baseAndServiceApps_ 总集
    baseAndServiceApps_->add( pBaseApp );
    
    // 5. 根据角色分流
    if (pBaseApp->isServiceApp()) {
        serviceApps_->add( pBaseApp );
    } else {
        baseApps_->add( pBaseApp );
    }
    
    // 6. 启动受控关停时不接受新注册
    
    // 7. 回复:addBaseAppArgs(包含 backupHash、initData 等)
    pBaseApp->channel().bundle() << backupHash << ... ;
    pBaseApp->channel().send();
    
    // 8. 触发备份哈希重平衡(adjustBackupLocations)
    this->adjustBackupLocations( ADD_APP, NULL );
}
```

#### 阶段二:finishedInit(baseappmgr.cpp:1351-1385)

```cpp
void BaseAppMgr::finishedInit( const Address & srcAddr,
                               const BaseAppMgrInterface::finishedInitArgs & args )
{
    BaseAppPtr pBaseApp = baseAndServiceApps_->find( srcAddr );
    if (!pBaseApp) {
        ERROR_MSG("finishedInit from unknown BaseApp");
        return;
    }
    
    // 标记已就绪,纳入负载均衡候选池
    pBaseApp->isReady( true );
    
    // 如果是 ServiceApp,触发 registerServiceFragment 注册到全局服务表
    if (pBaseApp->isServiceApp()) {
        this->registerServiceFragment( pBaseApp, args );
    }
    
    // 通知 CellAppMgr 有新 BaseApp 就绪(用于实体创建调度)
    cellAppMgr_->bundle().startMessage(
        CellAppMgrInterface::baseAppReady );
    cellAppMgr_->bundle() << pBaseApp->id();
    cellAppMgr_->channel().send();
}
```

### 2.6 三层负载均衡机制

BaseAppMgr 的负载均衡是 BigWorld 最精妙的设计之一,采用**三层协同**:

#### 第一层:createEntity 选最低负载(实时调度)

当外部请求创建 Base 实体时,DBApp Alpha 或其他进程会向 BaseAppMgr 发 `createEntity` 请求:

```cpp
// baseappmgr.cpp:923-985
void BaseAppMgr::createEntity( const Address & srcAddr,
                               const UnpackedMessageHeader & header,
                               BinaryIStream & data )
{
    // 1. 从 baseAndServiceApps_ 中找最低负载
    BaseAppPtr pBestApp = baseAndServiceApps_->findLeastLoadedApp();
    
    if (!pBestApp) {
        // 没有可用 BaseApp,返回错误
        this->sendCreateEntityReply( header, srcAddr, NULL_ADDR, 0 );
        return;
    }
    
    // 2. 转发 createBase 消息给选中的 BaseApp
    Mercury::Bundle & bundle = pBestApp->channel().bundle();
    bundle.startMessage( BaseAppIntInterface::createBaseWithCellData );
    bundle.transfer( data, data.remainingLength() );
    // 附带 replyID 让 BaseApp 直接回复原请求者
    bundle << header.replyID << srcAddr;
    pBestApp->channel().send();
    
    // 3. 选中 BaseApp 的实体计数 +1(乐观更新)
    pBestApp->addEntity();
}
```

`findLeastLoadedApp` 实现(baseappmgr.cpp:478-500):

```cpp
BaseAppPtr BaseAppMgr::findLeastLoadedApp() const
{
    BaseAppPtr pBestApp;
    float minLoad = FLT_MAX;
    
    BaseApps::const_iterator iter = baseAndServiceApps_->begin();
    for (; iter != baseAndServiceApps_->end(); ++iter) {
        BaseAppPtr pApp = iter->second;
        if (!pApp->isReady() || pApp->isRetiring()) continue;
        if (pApp->load() < minLoad) {
            minLoad = pApp->load();
            pBestApp = pApp;
        }
    }
    return pBestApp;
}
```

#### 第二层:updateBestBaseApp 每 tick 通知 CellAppMgr

每 tick(BaseAppMgr 自己的 tick),BaseAppMgr 向 CellAppMgr 推送当前最佳 BaseApp 地址,供 CellApp 在创建 cell 实体时同步创建 base:

```cpp
// 每个 tick 触发
void BaseAppMgr::updateBestBaseApp()
{
    BaseAppPtr pBestApp = baseApps_->findLeastLoadedApp();
    if (!pBestApp) return;
    
    cellAppMgr_->bundle().startMessage(
        CellAppMgrInterface::setBestBaseApp );
    cellAppMgr_->bundle() << pBestApp->id()
                          << pBestApp->address();
    cellAppMgr_->channel().send();
}
```

#### 第三层:updateCreateBaseInfo 周期下发加权随机候选

为了避免每次 createEntity 都向 BaseAppMgr 发请求(网络瓶颈),BaseAppMgr 周期性(默认 5 秒)向每个 BaseApp 下发一份**加权随机候选列表**:

```cpp
// baseappmgr.cpp:1078-1160
void BaseAppMgr::updateCreateBaseInfo()
{
    // 1. 收集所有就绪且非退休的 BaseApp,按负载排序
    AddressLoadPairs apps;
    baseApps_->getAddrLoadPairs( apps );
    std::sort( apps.begin(), apps.end(), AddressLoadPair::CompareLoad() );
    
    // 2. 限制最大候选数(防止列表过大)
    if (apps.size() > BaseAppMgrConfig::maxDestinationsInCreateBaseInfo()) {
        apps.resize( BaseAppMgrConfig::maxDestinationsInCreateBaseInfo() );
    }
    
    // 3. 下发给每个 BaseApp
    BaseApps::iterator iter = baseAndServiceApps_->begin();
    for (; iter != baseAndServiceApps_->end(); ++iter) {
        Mercury::Bundle & bundle = iter->second->channel().bundle();
        bundle.startMessage( BaseAppIntInterface::updateCreateBaseInfo );
        bundle << apps;
        iter->second->channel().send();
    }
}
```

BaseApp 收到后存入本地,后续 Python 调用 `BigWorld.createBase` 时**直接从本地候选列表随机选**,不再请求 BaseAppMgr。候选列表的"加权"体现在:负载低的 BaseApp 在列表中出现次数多,被选中概率高。

### 2.7 过载保护与登录准入

`LoginConditionsConfig`(login_conditions_config.hpp/.cpp)定义三个参数:

| 参数 | 默认值 | 含义 |
|------|--------|------|
| `minLoad` | 0.8 | 低于此负载的 BaseApp 才允许接受新登录 |
| `minOverloadTolerancePeriod` | 5.0 秒 | 持续超载多久才真正拒绝登录 |
| `overloadLogins` | 10 | 即使超载,每秒仍允许的登录数 |

每 tick 检查登录准入状态:

```cpp
// 简化逻辑
bool BaseAppMgr::shouldAcceptLogins() const
{
    BaseAppPtr pBestApp = baseApps_->findLeastLoadedApp();
    if (!pBestApp) return false;
    
    if (pBestApp->load() < LoginConditionsConfig::minLoad()) {
        return true;  // 任何 BaseApp 负载低于阈值,接受
    }
    
    // 全部超载,看是否仍在容忍期或允许少量登录
    // (实际实现涉及 overloadStartTime_ 等状态)
    return false;
}
```

LoginApp 在转发 `logOnAttempt` 前,会先向 BaseAppMgr 询问 `shouldAcceptLogins`(`BaseAppMgrInterface::requestBaseAppLoginStatus`),BaseAppMgr 通过 ReplyHandler 异步回复。这避免了 LoginApp 直接向某个 BaseApp 转发后才发现被拒绝的开销。

### 2.8 BackupHash 备份哈希机制

BaseApp 的备份采用**主动管理的 BackupHash**(区别于 DBApp 的 Rendezvous 哈希):

#### BackupHash 数据结构

```cpp
// lib/server/backup_hash.hpp
class BackupHash
{
    // 将 [0, range_) 的哈希空间映射到 BaseAppID
    // 每个 BaseApp 持有一段连续区间
    // 用于决定:某实体的备份应存放在哪个对端 BaseApp
};
```

#### BackupHashChain(备份哈希链)

```cpp
// lib/server/backup_hash_chain.hpp
class BackupHashChain
{
    BackupHash current_;     // 当前生效
    BackupHash previous_;    // 上一个(过渡期)
    
    // 在哈希变更时,新哈希逐步替换旧哈希
    // 备份方知道:哪些是新增的(需要建立备份),哪些是移除的(可以清理)
};
```

#### 哈希变更流程(adjustBackupLocations)

当 BaseApp 添加或死亡时,BaseAppMgr 调用 `adjustBackupLocations`(baseappmgr.cpp):

```cpp
enum AdjustBackupLocationsOp {
    ADD_APP,            // 新 BaseApp 加入,需要重新分配备份目标
    REMOVE_APP,         // BaseApp 死亡,需要把它的备份迁到其他 BaseApp
    START_BACKUP,       // 开始备份
    STOP_BACKUP,        // 停止备份(关停前)
    USE_NEW_BACKUP_HASH // 切换到新哈希(过渡完成)
};

void BaseAppMgr::adjustBackupLocations( AdjustBackupLocationsOp op,
                                        const BaseApp * pDeadApp )
{
    // 1. 重新计算 newBackupHash
    // 2. 通知所有 BaseApp:他们各自的新备份目标
    // 3. 通知所有 BaseApp:他们各自被备份到哪些 BaseApp(用于恢复时知道找谁)
    // 4. BaseApp 完成备份切换后,回 useNewBackupHash 确认
}
```

#### BackupHash 与 Rendezvous 哈希的对比

| 维度 | BackupHash(BaseApp) | Rendezvous 哈希(DBApp) |
|------|---------------------|------------------------|
| 管理方 | BaseAppMgr 主动计算并下发 | 每个 DBApp 独立计算(同一份 DBApps 表) |
| 数据定位 | 备份目标(对端 BaseApp) | 数据分片(哪个 DBApp 持有该 DBID) |
| 变更粒度 | 区间重映射 | 单点重映射 |
| 过渡机制 | BackupHashChain 双哈希链 | 直接覆盖 |

### 2.9 BaseApp 死亡处理与 mailbox 重定向

#### onBaseAppDeath(baseappmgr.cpp:1564-1595)

```cpp
void BaseAppMgr::handleBaseAppDeath( const Address & addr )
{
    BaseAppPtr pDeadApp = baseAndServiceApps_->find( addr );
    if (!pDeadApp) return;
    
    BaseAppID deadID = pDeadApp->id();
    
    // 1. 从子集移除
    baseAndServiceApps_->erase( addr );
    if (pDeadApp->isServiceApp()) {
        serviceApps_->erase( addr );
    } else {
        baseApps_->erase( addr );
    }
    
    // 2. 重新分配备份位置(把死亡 BaseApp 的备份迁到其他 BaseApp)
    this->adjustBackupLocations( REMOVE_APP, pDeadApp );
    
    // 3. 重定向 GlobalBases(全局服务邮箱)
    this->redirectGlobalBases( pDeadApp );
    
    // 4. 通知 CellAppMgr 该 BaseApp 死亡
    cellAppMgr_->bundle().startMessage(
        CellAppMgrInterface::handleBaseAppDeath );
    cellAppMgr_->bundle() << deadID;
    cellAppMgr_->channel().send();
    
    // 5. 通知所有存活 BaseApp:某 BaseApp 死亡,接管其备份
    BaseApps::iterator iter = baseAndServiceApps_->begin();
    for (; iter != baseAndServiceApps_->end(); ++iter) {
        Mercury::Bundle & bundle = iter->second->channel().bundle();
        bundle.startMessage( BaseAppIntInterface::handleBaseAppDeath );
        bundle << deadID;
        iter->second->channel().send();
    }
}
```

#### redirectGlobalBases(baseappmgr.cpp:1713-1738)

GlobalBases 是全局服务(如 MailBox、Avatar 等)的 Base 邮箱表。当某 BaseApp 死亡,其上的 GlobalBase 邮箱失效,BaseAppMgr 基于 BackupHash 找到接管者:

```cpp
void BaseAppMgr::redirectGlobalBases( const BaseApp * pDeadApp )
{
    // 1. 找出死亡 BaseApp 上的所有 GlobalBase
    GlobalBases::iterator iter = pGlobalBases_->findForApp( pDeadApp->id() );
    
    for (; iter != pGlobalBases_->end(); ++iter) {
        // 2. 基于 BackupHash 计算接管者
        BaseAppID newOwnerID = pBackupHashChain_->current().appForHash(
            iter->second->hash() );
        
        BaseAppPtr pNewOwner = baseAndServiceApps_->find( newOwnerID );
        if (!pNewOwner) continue;
        
        // 3. 通知接管者:恢复该 GlobalBase
        Mercury::Bundle & bundle = pNewOwner->channel().bundle();
        bundle.startMessage( BaseAppIntInterface::restoreBaseApp );
        bundle << iter->first /* name */ << iter->second->ref();
        pNewOwner->channel().send();
        
        // 4. 更新全局表
        pGlobalBases_->update( iter->first, pNewOwner->id() );
    }
    
    // 5. 广播新的 GlobalBases 表给所有 BaseApp
    this->broadcastGlobalBases();
}
```

### 2.10 受控关停

BaseAppMgr 的受控关停分多路径(baseappmgr.cpp:1962-2023):

```cpp
void BaseAppMgr::controlledShutDown(
    const BaseAppMgrInterface::controlledShutDownArgs & args )
{
    ShutDownStage stage = args.stage;
    
    switch (stage) {
    case SHUTDOWN_REQUEST: {
        // 阶段1:停止接受新登录
        isShuttingDown_ = true;
        
        // 通知所有 BaseApp 开始退休
        BaseApps::iterator iter = baseAndServiceApps_->begin();
        for (; iter != baseAndServiceApps_->end(); ++iter) {
            iter->second->channel().bundle().startMessage(
                BaseAppIntInterface::controlledShutDown );
            iter->second->channel().bundle() << SHUTDOWN_REQUEST;
            iter->second->channel().send();
        }
        break;
    }
    case SHUTDOWN_PERFORM: {
        // 阶段2:实际关停
        // 通知 BaseApp 写回数据库、清理备份
        ...
        break;
    }
    }
}
```

**受控关停的多路径触发**:
- **LoginApp → DBApp Alpha → BaseAppMgr**:用户从管理工具触发,LoginApp 收到后转 DBApp Alpha,Alpha 协调 BaseAppMgr 与 CellAppMgr 同步关停
- **本地 machined 信号**:bwmachined 收到 SIGTERM,转 BaseAppMgr

### 2.11 消息处理表

| 消息 | 处理方法 | 行号 | 说明 |
|------|---------|------|------|
| `add` | `add` | L992 | BaseApp 注册(阶段一) |
| `finishedInit` | `finishedInit` | L1351 | BaseApp 完成初始化(阶段二) |
| `recoverBaseApp` | `recoverBaseApp` | L1048 | BaseApp 恢复(沿用原 ID) |
| `useNewBackupHash` | `useNewBackupHash` | L1430 | BaseApp 完成备份哈希切换 |
| `registerBaseGlobally` | `registerBaseGlobally` | L1450 | 注册 GlobalBase 邮箱 |
| `deregisterBaseGlobally` | `deregisterBaseGlobally` | L1475 | 注销 GlobalBase |
| `updateBaseApp` | `updateBaseApp` | L1495 | BaseApp 上报负载/实体数 |
| `createEntity` | `createEntity` | L923 | 外部请求创建实体 |
| `addBaseAppMgr` | `addBaseAppMgr` | — | machined birth 通知(唯一性) |
| `handleBaseAppDeath` | `handleBaseAppDeath` | L1564 | BaseApp 死亡 |
| `handleCellAppMgrBirth` | `handleCellAppMgrBirth` | — | CellAppMgr 复活 |
| `handleDBAppMgrBirth` | `handleDBAppMgrBirth` | — | DBAppMgr 复活 |
| `controlledShutDown` | `controlledShutDown` | L1962 | 受控关停 |
| `requestBaseAppLoginStatus` | `requestBaseAppLoginStatus` | L1620 | LoginApp 询问登录准入 |
| `updateDBAppHash` | `updateDBAppHash` | L1640 | DBAppMgr 推送 DBApp 哈希 |
| `gameTimeReading` | `gameTimeReading` | L1660 | CellAppMgr 推送游戏时间 |

---

## 三、BaseApp:基础应用进程

BaseApp 是 BigWorld 中**最复杂的进程**,承担客户端连接、基础实体逻辑、持久化、备份、迁移等核心职责。

### 3.1 源码目录(70+ 文件分类)

#### 入口与主类

| 文件 | 职责 |
|------|------|
| `server/baseapp/main.cpp` | 入口,根据 argv[0] basename 判断 ServiceApp vs BaseApp |
| `server/baseapp/baseapp.hpp/.cpp` | 主类 `BaseApp`(3246 行) |
| `server/baseapp/baseapp_config.hpp/.cpp` | `BaseAppConfig`(继承 `EntityAppConfig + ExternalAppConfig`) |
| `server/baseapp/baseapp_int_interface.hpp` | `BaseAppIntInterface` 内部消息(63-267 行) |
| `server/baseapp/service_app.hpp` | `ServiceApp` 薄包装,继承 BaseApp,设 `isServiceApp_=true` |
| `server/baseapp/add_to_baseappmgr_helper.hpp` | `AddToBaseAppMgrHelper` 自销毁注册辅助类 |
| `server/baseapp/controlled_shutdown_handler.hpp/.cpp` | `ControlledShutdown::start` + 两类 ShutDownHandler |

#### 实体类

| 文件 | 职责 |
|------|------|
| `server/baseapp/base.hpp/.cpp` | `Base` 类(继承 PyObjectPlus,`typedef Base BaseOrEntity`) |
| `server/baseapp/proxy.hpp/.cpp` | `Proxy` 类(继承 Base,3300+ 行) |
| `server/baseapp/bases.hpp/.cpp` | `Bases` 容器(map<EntityID, Base*>) |
| `server/baseapp/entity_type.hpp/.cpp` | `EntityType`(create/newEntityBase/createScript) |
| `server/baseapp/entity_creator.hpp/.cpp` | `EntityCreator`(createBaseLocally/Remotely/Anywhere/FromDB/FromStream) |
| `server/baseapp/base_message_forwarder.hpp/.cpp` | `BaseMessageForwarder`(转发到其他 BaseApp) |
| `server/baseapp/mailbox.hpp` | `ServerEntityMailBox` 继承体系 |

#### 客户端连接

| 文件 | 职责 |
|------|------|
| `server/baseapp/proxy.hpp/.cpp` | `Proxy` 同时是客户端连接的承载者 |
| `server/baseapp/pending_logins.hpp/.cpp` | `PendingLogins`(loginKey vs sessionKey 双因子) |
| `server/baseapp/login_handler.hpp/.cpp` | `LoginHandler`(处理 logOnAttempt) |
| `server/baseapp/rate_limit_message_filter.hpp` | `RateLimitMessageFilter` 限流 |
| `server/baseapp/initial_connection_filter.hpp` | `InitialConnectionFilter` 初始连接过滤 |
| `server/baseapp/client_entity_mailbox.hpp` | `ClientEntityMailBox` |
| `server/baseapp/client_entity_mailbox_wrapper.hpp` | `ClientEntityMailBoxWrapper` |
| `server/baseapp/client_stream_filter_factory.hpp` | `ClientStreamFilterFactory` |
| `server/baseapp/download_streamer.hpp/.cpp` | `DownloadStreamer` 下载流控 |
| `server/baseapp/data_downloads.hpp/.cpp` | `DataDownloads` |

#### 网关与跨进程

| 文件 | 职责 |
|------|------|
| `server/baseapp/baseappmgr_gateway.hpp/.cpp` | `BaseAppMgrGateway` |
| `server/baseapp/global_bases.hpp/.cpp` | `GlobalBases`(本地副本) |
| `server/baseapp/shared_data_manager.hpp/.cpp` | `SharedDataManager`(BaseAppData/GlobalData) |
| `server/baseapp/dead_cell_apps.hpp/.cpp` | `DeadCellApps`(CellApp 死亡处理) |
| `server/baseapp/ping_manager.hpp` | `PingManager` |

#### 备份与持久化

| 文件 | 职责 |
|------|------|
| `server/baseapp/backup_sender.hpp/.cpp` | `BackupSender`(周期备份到对端) |
| `server/baseapp/archiver.hpp/.cpp` | `Archiver`(周期归档到 DBApp) |
| `server/baseapp/sqlite_database.hpp/.cpp` | `SqliteDatabase`(二级数据库) |
| `server/baseapp/backed_up_base_app.hpp` | `BackedUpBaseApp`(双缓冲) |
| `server/baseapp/backed_up_base_apps.hpp/.cpp` | `BackedUpBaseApps` |
| `server/baseapp/offloaded_backups.hpp/.cpp` | `OffloadedBackups` |
| `server/baseapp/write_to_db_reply.hpp` | `WriteToDBReply` |

#### 脚本与数据

| 文件 | 职责 |
|------|------|
| `server/baseapp/script_bigworld.hpp/.cpp` | `BigWorldBaseAppScript::init`,Python 绑定 |
| `server/baseapp/py_bases.hpp/.cpp` | `PyBases`(Python 访问 bases 容器) |
| `server/baseapp/py_cell_data.hpp/.cpp` | `PyCellData` |
| `server/baseapp/py_cell_spatial_data.hpp` | `PyCellSpatialData` |
| `server/baseapp/py_replay_*.hpp/.cpp` | 回放相关 |
| `server/baseapp/bwtracer.hpp` | Tracer |

#### 其他

| 文件 | 职责 |
|------|------|
| `server/baseapp/worker_thread.hpp` | `WorkerThread`(后台线程) |
| `server/baseapp/loading_thread.hpp` | `LoadingThread` |
| `server/baseapp/load_entity_handler.hpp/.cpp` | `LoadEntityHandler` |
| `server/baseapp/create_cell_entity_handler.hpp` | `CreateCellEntityHandler` |
| `server/baseapp/entity_channel_finder.hpp` | `EntityChannelFinder` |
| `server/baseapp/id_config.hpp` | `IDConfig` |
| `server/baseapp/rate_limit_config.hpp` | `RateLimitConfig` |
| `server/baseapp/download_streamer_config.hpp` | `DownloadStreamerConfig` |
| `server/baseapp/recording_recovery_data.hpp` | `RecordingRecoveryData` |
| `server/baseapp/remote_client_method.hpp` | `RemoteClientMethod` |
| `server/baseapp/replay_data_file_writer.hpp` | `ReplayDataFileWriter` |
| `server/baseapp/service.hpp/.cpp` | `Service`(全局服务) |
| `server/baseapp/service_starter.hpp` | `ServiceStarter` |
| `server/baseapp/address_load_pair.hpp` | `AddressLoadPair` |
| `server/baseapp/message_handlers.hpp` | 消息分发 |

### 3.2 类继承与四重继承链

```
ComponentApp  (生命周期、配置、dispatcher)
    ↓
ServerApp     (服务器通用:bwmachined 注册、Reviver、Watcher)
    ↓
ScriptApp     (Python 脚本:entitydefs、personality、ScriptEvents)
    ↓
EntityApp     (实体应用:IDClient、SharedData、Updatables)
    ↓
BaseApp       (BaseApp 特有:Proxy、BackupSender、Archiver、SqliteDB)
    + TimerHandler
    + ChannelListener
    + Singleton<BaseApp>
```

### 3.3 BaseApp 类成员总览(baseapp.hpp:71-464)

```cpp
class BaseApp : public EntityApp, public TimerHandler,
                public ChannelListener, public Singleton< BaseApp >
{
public:
    SERVER_APP_HEADER( BaseApp, baseApp )

    typedef BaseAppConfig Config;

    // 网络接口
    NetworkInterface &   intInterface()   { return intInterface_; }   // 内部
    NetworkInterface &   extInterface()   { return extInterface_; }   // 外部(客户端)
    Mercury::ChannelOwner & baseAppMgr()  { return baseAppMgr_; }
    Mercury::ChannelOwner & cellAppMgr()  { return cellAppMgr_; }
    Mercury::ChannelOwner & dbAppAlpha()  { return dbAppAlpha_; }
    DBAppsGateway &      dbApps()         { return dbApps_; }

    // 容器
    Bases &              bases()          { return bases_; }
    Proxy *              proxies()        { return proxies_; }
    BaseAppMgrGateway &  baseAppMgrGateway() { return baseAppMgrGateway_; }
    GlobalBases &        globalBases()    { return globalBases_; }
    SharedDataManager &  sharedData()     { return sharedDataManager_; }

    // 持久化与备份
    BackupSender *       pBackupSender()  { return pBackupSender_; }
    Archiver *           pArchiver()      { return pArchiver_; }
    SqliteDatabase *     pSqliteDB()      { return pSqliteDB_; }
    EntityCreator &      entityCreator()  { return *pEntityCreator_; }

    // 状态查询
    bool hasStarted() const;
    bool isShuttingDown() const;
    bool isRetiring() const;
    bool inShutDownPause() const;

private:
    // 初始化阶段标志
    enum InitStateFlags
    {
        READY_BASE_APP_MGR = 0x1
        // (历史版本有更多,14.4.1 简化为仅此一项)
    };
    uint32 initStateFlags_;

    // 网络与通道
    NetworkInterface    intInterface_;      // 内部接口(与 BaseAppMgr/CellApp/DBApp)
    NetworkInterface    extInterface_;      // 外部接口(与 LoginApp/Client)
    Mercury::TCPListener * tcpServer_;      // WebSocket/TCP 服务端
    Mercury::ChannelOwner baseAppMgr_;
    Mercury::ChannelOwner cellAppMgr_;
    Mercury::ChannelOwner dbAppAlpha_;
    DBAppsGateway       dbApps_;

    // 实体容器
    Bases               bases_;             // map<EntityID, Base*>
    Bases               localServiceFragments_;
    Proxies *           proxies_;           // 客户端连接表
    GlobalBases         globalBases_;
    SharedDataManager   sharedDataManager_;

    // 持久化与备份
    auto_ptr<BackupSender>     pBackupSender_;
    auto_ptr<Archiver>         pArchiver_;
    auto_ptr<SqliteDatabase>   pSqliteDB_;
    auto_ptr<EntityCreator>    pEntityCreator_;
    BackedUpBaseApps           backedUpBaseApps_;
    OffloadedBackups           offloadedBackups_;
    DeadCellApps               deadCellApps_;

    // 线程
    WorkerThread *      pWorkerThread_;
    BgTaskManager *     pBgTaskManager_;

    // 脚本
    BigWorldBaseAppScript * pScript_;
    GlobalBases *       pGlobalBases_;
    ...
};
```

### 3.4 启动流程(init,baseapp.cpp:352-521,12 步详解)

```
init() [L352]
  ├─ [1] ServerApp::init + 接口注册 [L355-378]
  │   ├─ ServerApp::init(argc, argv)
  │   ├─ 创建 intInterface_(内部接口,BaseAppMgr/CellApp/DBApp)
  │   ├─ 创建 extInterface_(外部接口,LoginApp/Client)
  │   ├─ BaseAppIntInterface::registerWithInterface(intInterface_)
  │   └─ BaseAppExtInterface::registerWithInterface(extInterface_)
  │
  ├─ [2] BWResource 监控线程安全 [L380-385]
  │   └─ BWResource::watchAccessFromCallingThread(true)
  │      // 强制:Python 与实体操作只在主线程
  │
  ├─ [3] EntityApp::init [L387-395]
  │   ├─ 加载 EntityDefs(entity_description_map)
  │   ├─ 初始化 IDClient(向 DBApp Alpha 申请 EntityID)
  │   └─ 初始化 SharedDataManager
  │
  ├─ [4] 创建外部网络服务 [L397-410]
  │   ├─ extInterface_.createListener( Mercury::Address::NONE,
  │   │                                 "BaseAppExtInterface" )
  │   ├─ tcpServer_ = new Mercury::TCPListener(...)  // WebSocket
  │   └─ 向 machined 注册 extInterface_ 地址
  │
  ├─ [5] 创建内部网络服务 [L412-425]
  │   ├─ intInterface_.createListener( Mercury::Address::NONE,
  │   │                                "BaseAppIntInterface" )
  │   └─ 向 machined 注册 intInterface_ 地址
  │
  ├─ [6] 初始化脚本系统 [L427-450]
  │   ├─ ScriptApp::initScript(argc, argv)
  │   ├─ BigWorldBaseAppScript::init() — 注册 BigWorld.entities/localServices/
  │   │   globalBases/services 等 Python 绑定
  │   ├─ 触发 ScriptEvents::onAppReady
  │   └─ initPersonality() — 加载 personality 脚本
  │
  ├─ [7] 初始化持久化子系统 [L452-470]
  │   ├─ pSqliteDB_ = new SqliteDatabase()
  │   ├─ pSqliteDB_->init()
  │   ├─ pArchiver_ = new Archiver(*this)
  │   ├─ pBackupSender_ = new BackupSender(*this)
  │   ├─ backedUpBaseApps_.init()
  │   └─ offloadedBackups_.init()
  │
  ├─ [8] 初始化实体创建器与转发器 [L472-490]
  │   ├─ pEntityCreator_ = new EntityCreator(*this)
  │   ├─ baseMessageForwarder_ = new BaseMessageForwarder(*this)
  │   └─ proxies_ = new Proxies(*this)
  │
  ├─ [9] 启动 WorkerThread 与 BgTaskManager [L492-498]
  │   ├─ pWorkerThread_ = new WorkerThread("Worker")
  │   ├─ pWorkerThread_->start()
  │   └─ pBgTaskManager_ = new BgTaskManager()
  │
  ├─ [10] 注册 BaseAppMgr 通道 [L500-510]
  │   ├─ 创建 baseAppMgr_ ChannelOwner(指向 BaseAppMgr)
  │   └─ AddToBaseAppMgrHelper::start() — 异步向 BaseAppMgr 发 add
  │      // 注意:此步骤异步,完成后才触发 finishInit
  │
  ├─ [11] 注册 machined 死亡监听 [L512-518]
  │   ├─ registerDeathListener(handleBaseAppMgrDeath, "BaseAppMgrInterface")
  │   ├─ registerDeathListener(handleCellAppMgrDeath, "CellAppMgrInterface")
  │   ├─ registerDeathListener(handleDBAppDeath, "DBAppInterface")
  │   └─ registerBirthListener(handleBaseAppMgrBirth)
  │
  └─ [12] Watcher 与定时器 [L520]
      ├─ addWatchers() — 注册 30+ watcher
      └─ startGameTickTimer() — 启动游戏 tick 定时器(等 ready 后才真正 tick)
```

### 3.5 异步初始化:finishInit 与 ready

由于 `add` 到 BaseAppMgr 是异步的,BaseApp 的初始化分为三阶段:

#### 阶段一:init 完成,等 BaseAppMgr 回复

`AddToBaseAppMgrHelper`(add_to_baseappmgr_helper.hpp)是自销毁辅助类:

```cpp
class AddToBaseAppMgrHelper
{
public:
    static void start()
    {
        // 向 BaseAppMgr 发 add 消息,携带 BaseAppInitData
        BaseApp::instance().baseAppMgr().channel().bundle()
            .startMessage( BaseAppMgrInterface::add );
        // 附带 BaseAppInitData{id, time, isReady, timeoutPeriod, externalAddr, isServiceApp}
        BaseApp::instance().baseAppMgr().channel().send();
        
        // 自己注册到 ReplyHandler,收到回复后销毁自身
        new AddToBaseAppMgrHelper();  // 自销毁
    }
    
    void onReply( ... )
    {
        // 收到 BaseAppMgr 的回复(包含 backupHash)
        // 触发 BaseApp::finishInit(回复数据)
        BaseApp::instance().finishInit( replyData );
        delete this;  // 自销毁
    }
};
```

#### 阶段二:finishInit(baseapp.cpp:702-805)

```cpp
bool BaseApp::finishInit( BinaryIStream & data )
{
    // 1. 解析 BaseAppMgr 回复
    BackupHash backupHash;
    data >> backupHash;
    // ... 其他初始化数据
    
    // 2. 初始化 BackupSender(用收到的 backupHash)
    pBackupSender_->init( backupHash );
    
    // 3. 初始化 BackedUpBaseApps(知道自己被备份到哪些 BaseApp)
    backedUpBaseApps_.init( backupHash );
    
    // 4. 标记 READY_BASE_APP_MGR
    initStateFlags_ |= READY_BASE_APP_MGR;
    
    // 5. 向 BaseAppMgr 发 finishedInit
    baseAppMgr_.channel().bundle().startMessage(
        BaseAppMgrInterface::finishedInit );
    baseAppMgr_.channel().send();
    
    // 6. 检查所有 init 阶段是否完成,若完成则调 ready()
    this->checkReady();
    
    return true;
}
```

#### 阶段三:ready(baseapp.cpp:2037-2063)

```cpp
void BaseApp::ready()
{
    // 1. 标记 hasStarted
    hasStarted_ = true;
    
    // 2. 启动游戏 tick 定时器(真正开始 tick)
    this->startGameTickTimer();
    
    // 3. 启动 BackupSender 定时器(默认 10 秒周期)
    pBackupSender_->start();
    
    // 4. 启动 Archiver 定时器(默认 100 秒周期)
    pArchiver_->start();
    
    // 5. 触发 Python 脚本 onAppReady
    pScript_->triggerEvent( ScriptEvents::onAppReady );
    
    // 6. 如果是 Alpha BaseApp(首个),触发 autoLoad
    //    (DBApp Alpha 会扫描 shouldAutoLoad=true 的实体并下发)
    
    // 7. 通知 CellAppMgr 我们已就绪
    cellAppMgr_.channel().bundle().startMessage(
        CellAppMgrInterface::baseAppReady );
    cellAppMgr_.channel().send();
}
```

### 3.6 InitStateFlags 状态机

14.4.1 版本中,`InitStateFlags` 简化为仅一个标志:

```cpp
enum InitStateFlags
{
    READY_BASE_APP_MGR = 0x1
    // 历史版本曾有 READY_CELL_APP_MGR / READY_DB_APP 等,14.4.1 合并到 finishInit
};
```

`checkReady()` 检查所有标志位:

```cpp
void BaseApp::checkReady()
{
    if (initStateFlags_ == ALL_READY)  // 即 READY_BASE_APP_MGR
    {
        this->ready();
    }
}
```

### 3.7 线程模型

BaseApp 采用**主线程独占 Python + Worker 后台线程**模型:

```
主线程(MainDispatcher)
  ├─ Python 解释器(独占)
  ├─ 所有实体操作(Base/Proxy 方法调用)
  ├─ 网络消息处理(intInterface_ + extInterface_)
  ├─ tickGameTime()
  ├─ BackupSender 触发(只是触发,序列化在 Worker)
  └─ Watcher 响应

WorkerThread(后台)
  ├─ SQLite 数据库写入
  ├─ BackupSender 实体序列化(避免阻塞主线程)
  └─ 其他 BgTask

BgTaskManager(后台线程池)
  ├─ DBApp 写入任务(经 DBAppsGateway 转发)
  └─ 长耗时序列化
```

**关键约束**:`BWResource::watchAccessFromCallingThread(true)` 在 init 阶段开启,确保 Python 与实体操作只在主线程。Worker 线程通过 BgTask 提交任务,任务内**不能直接调用 Python**。

### 3.8 tick 机制

#### startGameTickTimer(baseapp.cpp:2016-2030)

```cpp
void BaseApp::startGameTickTimer()
{
    const float tickRate = BaseAppConfig::gameTickTime();
    // 默认 1/10 秒(10 Hz)
    tickTimer_ = intInterface_.dispatcher().addTimer(
        int64(tickRate * 1000000),  // 微秒
        this,                        // TimerHandler
        (void*)TIMEOUT_GAME_TICK,
        "BaseAppGameTick" );
}
```

#### handleTimeout(baseapp.cpp:1461-1498)

```cpp
void BaseApp::handleTimeout( TimerHandle handle, void * arg )
{
    switch (uintptr(arg)) {
    case TIMEOUT_GAME_TICK:
        this->tickGameTime();
        break;
    case TIMEOUT_SHUTDOWN:
        this->continueControlledShutDown();
        break;
    case TIMEOUT_STATUS_REPORT:
        this->sendStatusToBaseAppMgr();
        break;
    }
}
```

#### tickGameTime(baseapp.cpp:1504-1623)

每 tick 执行:

```
tickGameTime() [L1504]
  ├─ [1] 推进游戏时间 gameTime_ += tickTime
  │
  ├─ [2] 触发 Python onTick(每个实体的 onTick 方法)
  │      // 性能敏感,Python 端应快速返回
  │
  ├─ [3] 处理 Proxy 的客户端消息
  │      ├─ 限流后的消息入队
  │      ├─ 分发到对应 Base 方法
  │      └─ 处理超时(inactivityTimeout)
  │
  ├─ [4] 处理 Updatables(每 tick 调用的周期任务)
  │
  ├─ [5] BackupSender 检查(到周期则触发)
  │
  ├─ [6] Archiver 检查(到周期则触发)
  │
  ├─ [7] 向 BaseAppMgr 汇报负载
  │      // 每 N tick 一次,含 load_/numBases_/numProxies_
  │
  └─ [8] 检查退休流程进度
         // 如果 isRetiring_,检查 offload 是否完成
```

### 3.9 受控关停四阶段

BaseApp 的受控关停(controlled_shutdown_handler.hpp/.cpp + baseapp.cpp:2259-2364)分为四阶段:

```
controlledShutDown(stage)
  │
  ├─ SHUTDOWN_INFORM [阶段1]
  │   ├─ 设置 isShuttingDown_ = true
  │   ├─ 通知 BaseAppMgr 我们开始关停(从负载均衡候选池移除)
  │   ├─ 通知所有 Proxy:即将关停(让客户端断开或迁移)
  │   ├─ 触发 Python onAppShutDown
  │   └─ 启动 SHUTDOWN 定时器,继续下一阶段
  │
  ├─ SHUTDOWN_DISCONNECT_PROXIES [阶段2]
  │   ├─ 主动断开所有 Proxy(发送 disconnect 消息)
  │   ├─ 触发 offload:把 Base 实体迁移到其他 BaseApp
  │   │   ├─ Base::offload → backupBaseEntity with isOffload=true
  │   │   └─ 目标 BaseApp 用 createBaseFromStream 接收
  │   └─ 等待 offload 完成(周期检查)
  │
  ├─ SHUTDOWN_PERFORM [阶段3]
  │   ├─ writeAllToDB():把所有 Base 实体写回 DBApp
  │   ├─ 停止 BackupSender
  │   ├─ 停止 Archiver
  │   ├─ 清理 BackedUpBaseApps
  │   └─ 通知 BaseAppMgr 关停完成
  │
  └─ 退出 [阶段4]
      └─ ServerApp::shutDown() → 进程退出
```

#### ShutDownHandler 二级数据库差异

```cpp
// controlled_shutdown_handler.hpp
class ControlledShutdown
{
public:
    static void start();
    
private:
    // 二级数据库(SqliteDB)数据需要先归并回 DBApp
    // 根据是否有 SqliteDB 选择不同 Handler
    static ShutDownHandlerWithSecondaryDB * pWithSecondaryDB_;
    static ShutDownHandlerWithoutSecondaryDB * pWithoutSecondaryDB_;
};
```

### 3.10 Watcher 系统(addWatchers,baseapp.cpp:862-940)

BaseApp 注册 30+ watcher,供 machined 的工具(如 `bwmachined` web 界面、`bwcluster`)查询:

| Watcher 路径 | 类型 | 含义 |
|--------------|------|------|
| `bases` | Container | 所有 Base 实体 |
| `proxies` | Container | 所有 Proxy |
| `numBases` | int | Base 数量 |
| `numProxies` | int | Proxy 数量 |
| `load` | float | 当前负载 |
| `gameTime` | int64 | 游戏时间 |
| `backup/period` | float | 备份周期 |
| `archive/period` | float | 归档周期 |
| `isRetiring` | bool | 是否退休中 |
| `isShuttingDown` | bool | 是否关停中 |
| `entities/` | — | 转发到实体属性 |
| `dbApps/` | — | DBApp 哈希表 |
| `backedUpBaseApps/` | — | 备份关系 |
| ... | | |

---

## 四、实体管理

### 4.1 Base 类(base.hpp/.cpp)

`Base` 是 BaseApp 侧**所有实体的基类**(继承 PyObjectPlus,即 Python 对象):

```cpp
class Base : public PyObjectPlus
{
public:
    EntityID       id() const         { return id_; }
    DatabaseID     databaseID() const { return databaseID_; }
    EntityType *   pType() const      { return pType_; }
    PyCellData *   pCellData() const  { return pCellData_; }
    CellEntityMailBox * pCellEntityMailBox() const { return pCellEntityMailBox_; }
    SpaceID        spaceID() const    { return spaceID_; }
    Mercury::Channel * pChannel() const { return pChannel_; }
    PyTimer *      pPyTimer() const   { return pyTimer_; }
    IEntityDelegate * pEntityDelegate() const { return pEntityDelegate_; }

    // 状态机
    bool isCreateCellPending() const  { return isCreateCellPending_; }
    bool isGetCellPending() const     { return isGetCellPending_; }
    bool isDestroyCellPending() const { return isDestroyCellPending_; }

    // 方法调用
    void callBaseMethod( int methodID, BinaryIStream & data );  // base.cpp:1286
    void callCellMethod( int methodID, BinaryIStream & data );  // base.cpp:1391

    // 生命周期
    void createCellEntity( ... );
    void createInDefaultSpace();
    void createInNewSpace();
    void restoreTo( BinaryIStream & data );
    void migrate( const Mercury::Address & dstAddr );
    void destroy( ScriptObject arg );
    void discard();

    // 持久化
    void writeToDB( ... );  // 两阶段,见第六章

private:
    EntityID        id_;
    DatabaseID      databaseID_;
    EntityType *    pType_;
    PyCellData *    pCellData_;
    CellEntityMailBox * pCellEntityMailBox_;
    SpaceID         spaceID_;
    Mercury::Channel * pChannel_;
    PyTimer *       pyTimer_;
    IEntityDelegate * pEntityDelegate_;

    bool isCreateCellPending_;
    bool isGetCellPending_;
    bool isDestroyCellPending_;
    ...
};

typedef Base BaseOrEntity;  // BaseApp 侧 BaseOrEntity 即 Base
```

### 4.2 Proxy 类(proxy.hpp:74,proxy.cpp:3300+ 行)

`Proxy` 继承 `Base`,代表**有客户端连接**的实体:

```cpp
class Proxy : public Base
{
public:
    // 客户端连接
    void attachToClient( ... );           // proxy.cpp:584-717
    void detachFromClient( ... );         // proxy.cpp:3120-3185
    void onClientDeath( ... );            // proxy.cpp:748-814
    void logOffClient( ... );             // proxy.cpp:3197-3218

    // 客户端迁移
    void giveClientTo( ... );             // proxy.cpp:2749-2871
    void giveClientLocally( ... );        // proxy.cpp:2878-2949
    void transferClient( ... );           // proxy.cpp:981-1032

    // 重登录
    void prepareForReLogOn( ... );        // proxy.cpp:2956-2988
    void completeReLogOnAttempt( ... );   // proxy.cpp:3020-3053
    void onGiveClientToCompleted( ... );  // proxy.cpp:3060-3110

    // 认证
    void regenerateSessionKey();          // proxy.cpp:562-571
    void prepareForLogin( ... );          // proxy.cpp:1601-1612
    void acceptClient( ... );             // proxy.cpp:1547-1591

    // 消息
    void callClientMethod( ... );         // proxy.cpp:1322-1437
    void sendBundleToClient( ... );       // proxy.cpp:1900-2001
    void addOpportunisticData( ... );     // proxy.cpp:2073-2191

    // 备份
    void writeBackupData( ... );          // proxy.cpp:912-955
    void readBackupData( ... );           // proxy.cpp:1038-1085

private:
    Mercury::Channel *      pClientChannel_;
    uint8 *                 encryptionKey_;
    SessionKey              sessionKey_;          // 用于重登录
    ClientEntityMailBox *   pClientEntityMailBox_;
    BundlePrimer *          pBufferedClientBundle_;
    RateLimitMessageFilter * pRateLimiter_;
    PendingReLogOn *        pPendingReLogOn_;
    bool                    entitiesEnabled_;
    bool                    cellHasWitness_;
    bool                    isGivingClientAway_;
    float                   avgClientBundleDataUnits_;
    float                   downloadRate_;
    Wards                   wards_;               // 守护(防卡死)
    LatencyTriggers         latencyTriggers_;
    float                   inactivityTimeout_;
    ...
};
```

### 4.3 Bases 容器(bases.hpp/.cpp)

```cpp
class Bases
{
public:
    bool add( Base * pBase );
    bool erase( Base * pBase );
    Base * find( EntityID id ) const;

    size_t size() const  { return bases_.size(); }

    // 迭代器
    iterator begin()     { return bases_.begin(); }
    iterator end()       { return bases_.end(); }

private:
    typedef BW::map< EntityID, Base * > Container;
    Container bases_;
    Bases *   localServiceFragments_;  // 本地服务片段(分离存储)
};
```

### 4.4 EntityCreator(entity_creator.hpp/.cpp)

`EntityCreator` 提供多种创建 Base 实体的方式:

| 方法 | 行号 | 用途 |
|------|------|------|
| `createBaseLocally` | — | 在本 BaseApp 创建(无 Cell) |
| `createBaseRemotely` | — | 在其他 BaseApp 创建(基于 updateCreateBaseInfo 候选) |
| `createBaseAnywhere` | — | 自动选择(本地或远程) |
| `createBaseFromDB` | — | 从数据库加载并创建 |
| `createBaseFromStream` | L1011-1113 | 从流恢复(用于备份恢复/offload 接收) |
| `createBaseWithCellData` | L1120-1179 | 带 cellData 创建(用于 createEntity 转发) |

#### createBaseFromStream 流程(L1011-1113)

```cpp
Base * EntityCreator::createBaseFromStream( BinaryIStream & data,
                                            bool isPlayer,
                                            bool isRestoration )
{
    // 1. 解析流:实体类型、ID、DBID、属性数据
    EntityTypeID typeID;
    data >> typeID;
    EntityID id;
    data >> id;
    DatabaseID dbID;
    data >> dbID;
    
    // 2. 向 DBApp Alpha 申请 EntityID(若 id 为 0)
    if (id == 0) {
        id = idClient_.getNewID();
    }
    
    // 3. 创建 EntityType 并实例化
    EntityType * pType = EntityType::find( typeID );
    Base * pBase = pType->newEntityBase( id );
    
    // 4. 反序列化属性
    pBase->pType()->initEntityFromStream( pBase, data );
    
    // 5. 加入 Bases 容器
    bases_.add( pBase );
    
    // 6. 若是恢复(isRestoration),重建 Cell(若有 cellData)
    if (isRestoration && pBase->pCellData()) {
        pBase->createCellEntity( ... );
    }
    
    return pBase;
}
```

### 4.5 IDClient(EntityApp 基类)

`IDClient` 向 DBApp Alpha 批量申请 EntityID:

```cpp
class IDClient
{
    // 当本地 ID 池耗尽时,向 DBApp Alpha 发 getIDs 请求
    void getIDs( uint32 count );
    
    // DBApp Alpha 回复后,加入本地池
    void onGetIDsReply( BinaryIStream & data );
    
    // 业务侧调用
    EntityID popNewID();
    
private:
    std::queue<EntityID> idPool_;
    uint32 batchSize_;  // 默认 100,一次申请 100 个
};
```

### 4.6 实体生命周期

```
创建:
  Python BigWorld.createBase / createBaseFromDB / createBaseAnywhere
      ↓
  EntityCreator::createBaseXXX
      ↓
  EntityType::newEntityBase(id) → Base 对象
      ↓
  Bases::add( pBase )
      ↓
  (可选) Base::createCellEntity → 在 CellApp 创建 cell 实体
      ↓
  Base::onCellEntityCreated → 设置 pCellEntityMailBox_

销毁:
  Base::destroy( ScriptObject arg )  // Python 主动销毁
      ↓
  (若有 cell) 发送 destroyCellEntity 给 CellApp
      ↓
  Base::onDestroyCellComplete
      ↓
  Base::discard()  // 立即销毁,不写 DB
      ↓
  Bases::erase( pBase )
      ↓
  delete pBase

被备份恢复:
  其他 BaseApp 死亡 → BaseAppMgr 通知接管
      ↓
  BackedUpBaseApps::restore( deadBaseAppID )
      ↓
  EntityCreator::createBaseFromStream( backupData, isRestoration=true )
      ↓
  重建 Base + 重建 Cell(若有 cellData)
```

### 4.7 关键澄清:BaseApp 侧无 Entity 类

**重要**:BaseApp 侧**不存在独立的 Entity 类**。Entity 类仅存在于:
- `server/cellapp/entity.hpp` — CellApp 的实体(有空间位置/AOI)
- `client/entity.hpp` — 客户端实体
- `server/bots/entity.hpp` — bots 测试实体

BaseApp 侧的实体层次是:
```
PyObjectPlus (Python 对象基类)
    ↓
Base (BaseApp 侧所有实体基类)
    ↓
Proxy (有客户端连接的实体)
```

通过 `typedef Base BaseOrEntity` 复用 Base 作为 BaseOrEntity(在其他进程中 BaseOrEntity 是 Entity)。

---

## 五、脚本系统

### 5.1 ScriptApp 基类(lib/server/script_app.hpp)

```cpp
class ScriptApp : public ServerApp
{
public:
    bool initScript( int argc, char ** argv );
    bool triggerEvent( const ScriptEvent & event, ... );
    
protected:
    // 子类实现
    virtual bool initPersonality() = 0;
    virtual void triggerOnInit() = 0;
    
    ScriptEvents * pScriptEvents_;
    PersonalityScript * pPersonality_;
};
```

### 5.2 BigWorldBaseAppScript::init(script_bigworld.cpp:2120-2223)

```cpp
bool BigWorldBaseAppScript::init( int argc, char * argv[] )
{
    // 1. 注册 BigWorld 模块的 BaseApp 特有绑定
    ScriptModule bigworld = ScriptModule::getOrCreate( "BigWorld" );
    
    // 2. 注册 entities 容器(对应 Bases)
    bigworld.setAttribute( "entities",
        ScriptObject( new PyBases( BaseApp::instance().bases() ) ) );
    
    // 3. 注册 localServices 容器
    bigworld.setAttribute( "localServices",
        ScriptObject( new PyBases(
            BaseApp::instance().localServiceFragments() ) ) );
    
    // 4. 注册 globalBases(对应 GlobalBases)
    bigworld.setAttribute( "globalBases",
        ScriptObject( BaseApp::instance().globalBases().pyObject() ) );
    
    // 5. 注册 services 容器(ServiceApp 专用)
    bigworld.setAttribute( "services", ... );
    
    // 6. 注册方法
    bigworld.setAttribute( "createBase", ... );
    bigworld.setAttribute( "createBaseFromDB", ... );
    bigworld.setAttribute( "createBaseAnywhere", ... );
    bigworld.setAttribute( "createBaseRemotely", ... );
    bigworld.setAttribute( "lookUpBaseByDBID", ... );
    bigworld.setAttribute( "executeRawDatabaseCommand", ... );
    bigworld.setAttribute( "saveValue", ... );  // 共享数据
    bigworld.setAttribute( "loadValue", ... );
    // ... 30+ 方法
    
    // 7. 加载 personality 脚本
    return this->initPersonality();
}
```

### 5.3 EntityDescriptionMap

**重要澄清**:`lib/entitydef/entity_defs.hpp` 在代码库中**不存在**。实际使用的是:

- `lib/entitydef/entity_description_map.hpp` — `EntityDescriptionMap`(所有实体类型描述的总表)
- `lib/entitydef/entity_description.hpp` — `EntityDescription`(单个实体类型描述)

```cpp
class EntityDescriptionMap
{
public:
    bool parse( DataSectionPtr pSection );  // 从 entity_defs/*.def 解析
    int nameToIndex( const BW::string & name ) const;
    const EntityDescription & indexToDescription( int index ) const;
    
    void addToMD5( MD5 & md5 ) const;  // 加入 MD5(用于版本校验)
    void digest( BinaryOStream & stream ) const;
    
private:
    BW::vector< EntityDescription > entityDescriptions_;
    BW::map< BW::string, int > nameToIndexMap_;
};
```

### 5.4 EntityType(entity_type.hpp/.cpp)

```cpp
class EntityType
{
public:
    static EntityType * find( const BW::string & name );
    static EntityType * find( EntityTypeID typeID );
    
    static bool init( const EntityDefs & entityDefs );  // 启动时加载所有类型
    static void fini();
    static bool reloadScript();  // 热重载脚本
    
    Base * newEntityBase( EntityID id );  // 创建 Base 实例
    ScriptObject createScript( Base * pBase, bool isPlayer );
    
    const EntityDescription & description() const { return *pDescription_; }
    EntityTypeID typeID() const { return pDescription_->index(); }
    
private:
    const EntityDescription * pDescription_;
    ScriptType scriptType_;  // Python 类对象
    
    static BW::vector< EntityType > s_entityTypes_;
};
```

### 5.5 ScriptEvents

BigWorld 定义了一系列 ScriptEvents,BaseApp 在特定时机触发:

| 事件 | 触发时机 |
|------|---------|
| `onAppReady` | BaseApp::ready() |
| `onAppShutDown` | 受控关停 SHUTDOWN_INFORM 阶段 |
| `onTick` | 每 tick(tickGameTime) |
| `onEntityCreated` | 实体创建后 |
| `onEntityDestroyed` | 实体销毁前 |
| `onBaseAppDeath` | 其他 BaseApp 死亡通知到达时 |
| `onCellAppDeath` | CellApp 死亡通知到达时 |

### 5.6 IGameDelegate / IEntityDelegate(C++ 插件扩展)

```cpp
// lib/entitydef/game_delegate.hpp
class IGameDelegate
{
public:
    virtual void onBaseAppReady() = 0;
    virtual void onBaseAppShutDown() = 0;
    virtual void onTick( float dtime ) = 0;
    // ...
};

// lib/entitydef/entity_delegate.hpp
class IEntityDelegate
{
public:
    virtual void onMethodCalled( int methodID, BinaryIStream & data ) = 0;
    virtual void onPropertySet( int propertyID, BinaryIStream & data ) = 0;
    // ...
};
```

游戏可在 Base 实例上挂 `IEntityDelegate`,绕过 Python 直接用 C++ 处理高频方法,提升性能。

---

## 六、持久化机制

### 6.1 writeToDB 两阶段(Base::writeToDB)

Base 实体写回数据库分两阶段,因为 Cell 数据需要先从 CellApp 取回:

```
阶段1:请求 cellData
  Base::writeToDB( shouldWriteToDB, writeFlags )
      ↓
  若有 Cell(有 pCellEntityMailBox_)
      ↓
  向 CellApp 发送 getCellData 请求
      ↓
  CellApp 返回 cellData(实体在 Cell 端的状态)

阶段2:写入 DBApp
  Base::onGetCellDataForWriteToDB( cellDataStream, ... )
      ↓
  序列化完整实体(baseData + cellData)
      ↓
  经 DBAppsGateway 路由(Rendezvous 哈希,按 DatabaseID)
      ↓
  DBAppInterface::writeEntity
      ↓
  DBApp 回复 writeEntitySuccess
      ↓
  Base::onWriteToDBComplete( success )
      ↓
  Python 回调(若有)
```

### 6.2 SqliteDatabase 二级数据库

BaseApp 持有一个本地 SQLite 数据库,作为**临时缓冲**,降低 DBApp 压力:

```cpp
// sqlite_database.hpp
class SqliteDatabase
{
public:
    bool init();
    void putEntity( EntityID id, BinaryIStream & data );
    bool getEntity( EntityID id, BinaryOStream & data );
    void delEntity( EntityID id );
    
    // 归并回 DBApp(关停时)
    void consolidateToDBApp( ... );
    
private:
    sqlite3 * db_;
    BW::string tableName_;
};
```

**用途**:
- Archiver 周期归档时,先写 SQLite(快),再异步同步到 DBApp(慢)
- 关停时,SQLite 数据归并回 DBApp
- 死亡恢复时,从 SQLite 快速恢复(配合 BackupSender 的内存备份)

### 6.3 Archiver(archiver.hpp/.cpp)

`Archiver` 周期(默认 100 秒)将 Base 实体归档到 DBApp/SQLite:

```cpp
class Archiver
{
public:
    Archiver( BaseApp & app );
    
    void start();  // 启动定时器
    
    void tick();   // 每 tick 检查是否到周期
    
private:
    void archiveNextBatch();  // 归档一批实体(避免一次太多)
    
    BaseApp & app_;
    TimerHandle timer_;
    float period_;  // 默认 100 秒
    Bases::iterator nextBase_;  // 下一个待归档的实体(轮询)
    
    // 二级数据库模式
    bool useSecondaryDB_;
    SqliteDatabase * pSecondaryDB_;
};
```

**归档策略**:
- 轮询所有 Base,每 tick 归档一批(防止阻塞)
- 优先归档"脏"实体(有修改的)
- 若启用二级数据库,先写 SQLite,再异步同步

### 6.4 autoLoad 机制

autoLoad 是 BigWorld 的"全局服务"启动机制:

```
DBApp Alpha 启动时
  ↓
扫描数据库,找出所有 shouldAutoLoad=true 的实体
  ↓
对每个实体,经 DBAppsGateway 路由到对应 DBApp
  ↓
DBApp 加载实体数据,发 createBaseFromDB 给 BaseAppMgr
  ↓
BaseAppMgr 转发给某 BaseApp(createEntity 选最低负载)
  ↓
BaseApp 创建 Base 实体,标记 didAutoLoadEntitiesFromDB
  ↓
触发 Python onAutoLoadedEntity(让游戏逻辑决定是否注册为 GlobalBase)

工具:clear_auto_load
  清除数据库中的 shouldAutoLoad 标记(用于停服维护)
```

### 6.5 与 DBApp 的交互(DBAppsGateway)

```cpp
// lib/db/dbapps_gateway.hpp
class DBAppsGateway
{
public:
    // 添加/移除 DBApp(BaseAppMgr 推送 updateDBAppHash 时调用)
    void addDBApp( const DBAppGateway & dbApp );
    void removeDBApp( DBAppID id );
    
    // 按 DatabaseID 路由(Rendezvous 哈希)
    DBAppGateway * getDBAppForID( DatabaseID dbID ) const;
    
    // 从流更新(收到 BaseAppMgr 转发的哈希表)
    void updateFromStream( BinaryIStream & data );
    
private:
    DBHashSchemes::DBAppIDBuckets< DBAppGateway >::HashScheme dbApps_;
    
    // IUpdateVisitor 模式:批量更新时遍历所有 DBApp
    class IUpdateVisitor { ... };
};
```

**关键 DBAppInterface 消息**:

| 消息 | 用途 |
|------|------|
| `getIDs` | 申请 EntityID 批量 |
| `putIDs` | 回收 EntityID |
| `loadEntity` | 加载实体(用于 createBaseFromDB) |
| `writeEntity` | 写入实体(writeToDB) |
| `deleteEntity` | 删除实体 |
| `lookupEntity` | 按 DBID 查询 |
| `lookupEntityByName` | 按名称查询 |
| `logOn` | 登录请求(从 LoginApp 转发) |
| `executeRawCommand` | 原始 SQL(管理工具) |
| `secondaryDBRegistration` | 二级数据库注册 |
| `setGameTime` | 设置游戏时间 |

---

## 七、备份与容错

### 7.1 BackupSender(backup_sender.hpp/.cpp)

`BackupSender` 周期(默认 10 秒)将 Base 实体的**快照**发送到对端 BaseApp(备份目标):

```cpp
class BackupSender
{
public:
    BackupSender( BaseApp & app );
    
    void init( const BackupHash & backupHash );  // 用 BaseAppMgr 下发的哈希
    
    void start();  // 启动定时器
    
    void tick();   // 每 tick 检查是否到周期
    
private:
    void backupNextBatch();  // 备份一批实体
    
    BaseApp & app_;
    BackupHash backupHash_;  // 决定每个实体备份到哪个 BaseApp
    TimerHandle timer_;
    float period_;  // 默认 10 秒
    Bases::iterator nextBase_;  // 下一个待备份的实体(轮询)
};
```

**备份流程**:
```
1. 取下一个 Base 实体
2. 序列化(在 WorkerThread,避免阻塞主线程)
3. 基于 BackupHash 计算备份目标 BaseApp
4. 发送 backupBaseEntity 消息(BaseAppIntInterface)
5. 目标 BaseApp 收到,存入 BackedUpBaseApps
```

### 7.2 BackedUpBaseApp 双缓冲(backed_up_base_app.hpp)

```cpp
class BackedUpBaseApp
{
public:
    BackedUpBaseApp();
    
    void add( EntityID id, BinaryIStream & data );
    void erase( EntityID id );
    
    // 切换缓冲(哈希变更时)
    void startNewBuffer();
    void useNewBuffer();
    
    // 恢复(对端死亡时)
    void restore( BaseAppID deadAppID );
    
private:
    BackedUpEntities * currentBackup_;  // 当前生效
    BackedUpEntities * newBackup_;      // 过渡中的新缓冲
};
```

**双缓冲设计**:在 BackupHash 过渡期,旧缓冲(currentBackup_)与新缓冲(newBackup_)并存,确保不丢失备份。过渡完成后,`useNewBuffer()` 将 newBackup_ 提升为 currentBackup_。

### 7.3 BackupHashChain

```cpp
// lib/server/backup_hash_chain.hpp
class BackupHashChain
{
public:
    const BackupHash & current() const  { return current_; }
    const BackupHash & previous() const { return previous_; }
    
    void update( const BackupHash & newHash );
    
    // 查询:某哈希值当前的备份目标(考虑过渡期)
    BaseAppID appForHash( uint32 hash ) const;
    
private:
    BackupHash current_;   // 当前生效
    BackupHash previous_;  // 上一个(过渡期保留)
};
```

### 7.4 BaseApp 死亡时的接管

当某 BaseApp 死亡,BaseAppMgr 通知所有存活 BaseApp:

```
1. BaseAppMgr::handleBaseAppDeath(deadAddr)
      ↓
   adjustBackupLocations(REMOVE_APP, pDeadApp)
      ↓
   重新计算 BackupHash,通知所有存活 BaseApp
      ↓
   向每个存活 BaseApp 发 handleBaseAppDeath(deadID)

2. 存活 BaseApp 收到 handleBaseAppDeath(deadID)
      ↓
   BackedUpBaseApps::restore(deadID)
      ↓
   对每个被备份的实体:
      EntityCreator::createBaseFromStream(backupData, isRestoration=true)
      ↓
   重建 Base + 重建 Cell(若有 cellData)
      ↓
   触发 Python onRestored 回调

3. BaseAppMgr::redirectGlobalBases(pDeadApp)
      ↓
   基于 BackupHash 找到接管者
      ↓
   通知接管者 restoreBaseApp
      ↓
   更新全局 GlobalBases 表
```

---

## 八、Proxy 与客户端连接

### 8.1 Proxy 的双重身份

`Proxy` 继承 `Base`,既是实体(有 Python 脚本),又是客户端连接(管理 Channel):

```
Proxy
  ├─ 作为 Base:有 id、pType、pCellData、可被 callBaseMethod
  └─ 作为客户端:有 pClientChannel、encryptionKey、sessionKey、可 sendBundleToClient
```

### 8.2 认证:sessionKey 与 loginKey 双因子

#### loginKey(短期,登录时用)

LoginApp 在转发 logOnAttempt 前,从 DBApp Alpha 获取 loginKey。BaseApp 收到 logOnAttempt 后,用 loginKey 解密 LogOnParams。

#### sessionKey(长期,重登录用)

```cpp
// proxy.cpp:562-571
void Proxy::regenerateSessionKey()
{
    // 用当前时间戳生成新 sessionKey
    sessionKey_ = SessionKey( timestamp() );
    
    // 通过 BundlePrimer 注入到客户端的下一个 bundle
    pBufferedClientBundle_->setSessionKey( sessionKey_ );
}
```

**重登录流程**:
```
1. 客户端断开(网络问题)
2. 客户端重连 LoginApp,携带 sessionKey
3. LoginApp 转发到 DBApp Alpha
4. DBApp Alpha 查 logOnRecords,找到原 BaseApp
5. 通知原 BaseApp 的 Proxy:prepareForReLogOn
6. 客户端连到原 BaseApp
7. Proxy::completeReLogOnAttempt 验证 sessionKey
8. 恢复客户端连接,无需重建实体
```

### 8.3 attachToClient(proxy.cpp:584-717)

```cpp
void Proxy::attachToClient( const Mercury::Address & srcAddr,
                            uint8 * keyData,
                            bool addClientEntity )
{
    // 1. 创建客户端 Channel
    pClientChannel_ = &extInterface_.findOrCreateChannel( srcAddr );
    
    // 2. 设置加密(若启用)
    if (keyData) {
        EncryptionFilter * pFilter = new EncryptionFilter(
            new SymmetricBlockCipher( Blowfish, keyData, keyLen ) );
        pClientChannel_->pFilter( pFilter );
        encryptionKey_ = keyData;
    }
    
    // 3. 创建 ClientEntityMailBox(让客户端能调本实体的方法)
    pClientEntityMailBox_ = new ClientEntityMailBox(
        *this, pClientChannel_ );
    
    // 4. 初始化 BundlePrimer(自动注入 authenticate+tickSync)
    pBufferedClientBundle_ = new ClientBundlePrimer( *this );
    
    // 5. 初始化限流器
    pRateLimiter_ = new RateLimitMessageFilter( ... );
    
    // 6. 触发 Python onClientAttached
    pType_->callMethod( pType_->description().clientMethod(
        "onClientAttached" ), ScriptArgs::create( this ) );
    
    // 7. 若 addClientEntity,通知 CellApp 添加 witness
    if (addClientEntity && pCellEntityMailBox_) {
        pCellEntityMailBox_->sendCallCellMethod(
            "addWitness", pClientChannel_->address() );
    }
}
```

### 8.4 BundlePrimer 自动注入

`BundlePrimer`(在 proxy.cpp 内)在每个发送给客户端的 bundle 中自动注入:

```
Bundle 开头:
  - authenticate 消息(携带 sessionKey,首次)
  - tickSync 消息(每个 bundle,同步游戏时间)
  - 实际业务消息
```

这确保客户端始终有时间同步,且首次连接能完成认证。

### 8.5 消息处理

#### 客户端 → BaseApp(入站)

```
客户端 → extInterface_ → Proxy::callClientMethod?
   否,客户端消息不是调 Proxy 的方法,而是调实体方法:
   
客户端 → extInterface_ → BaseAppIntInterface::callBaseMethod(等)
   实际:BaseAppExtInterface 定义客户端可调的消息
   
   消息路由:
   - 客户端发 "callMethod" 消息 → Proxy::callBaseMethod(methodID, data)
   - 客户端发 "move" 消息 → 转发到 CellApp
   - 客户端发 "tickSync" 消息 → Proxy 处理时间同步
```

#### BaseApp → 客户端(出站)

```cpp
// proxy.cpp:1322-1437
void Proxy::callClientMethod( int methodID, BinaryIStream & data )
{
    // 1. 限流检查
    if (!pRateLimiter_->allow()) {
        // 超限,丢弃或延迟
        return;
    }
    
    // 2. 通过 BundlePrimer 发送
    Mercury::Bundle & bundle = pClientChannel_->bundle();
    pBufferedClientBundle_->prime( bundle );  // 注入 authenticate/tickSync
    bundle.startMessage( BaseAppExtInterface::callClientMethod );
    bundle << methodID;
    bundle.transfer( data, data.remainingLength() );
    
    // 3. 流控检查
    this->checkOverflow();
}
```

### 8.6 sendBundleToClient(proxy.cpp:1900-2001)

```cpp
void Proxy::sendBundleToClient()
{
    // 1. 检查 Channel 是否就绪
    if (!pClientChannel_ || !pClientChannel_->isEstablished()) {
        // 缓冲,等连接就绪
        return;
    }
    
    // 2. 流控:检查 bitsPerSecondToClient 限制
    float budget = bitsPerSecondToClient_ * tickTime_;
    if (avgClientBundleDataUnits_ > budget) {
        // 超预算,延迟发送
        return;
    }
    
    // 3. 添加 opportunistic 数据(实体属性同步)
    this->addOpportunisticData( bundle );
    
    // 4. 发送
    pClientChannel_->send();
}
```

### 8.7 addOpportunisticData 下载流控(proxy.cpp:2073-2191)

```cpp
void Proxy::addOpportunisticData( Mercury::Bundle & bundle )
{
    // 1. 检查 backlog(积压数据)是否超阈值
    if (downloadBacklog_ > clientOverflowLimit_) {
        // 超限,丢弃低优先级数据
        return;
    }
    
    // 2. 按 downloadRate_ 限制发送量
    float allowedBits = downloadRate_ * tickTime_;
    int sentBits = 0;
    
    // 3. 从 downloadQueue_ 取数据
    while (sentBits < allowedBits && !downloadQueue_.empty()) {
        DownloadItem & item = downloadQueue_.front();
        bundle.startMessage( BaseAppExtInterface::downloadData );
        bundle << item.id << item.data;
        sentBits += item.data.size() * 8;
        downloadQueue_.pop();
    }
    
    // 4. 更新统计
    avgClientBundleDataUnits_ = ...;
}
```

### 8.8 RateLimitMessageFilter 限流

```cpp
// rate_limit_message_filter.hpp
class RateLimitMessageFilter
{
public:
    bool allow();
    
private:
    // 滑动窗口或令牌桶
    float rate_;           // 每秒允许的消息数
    float bucket_;         // 当前令牌
    float lastRefillTime_;
};
```

### 8.9 Lag 积累与 Wards

```cpp
class Proxy : public Base
{
private:
    Wards           wards_;           // 守护:多个"看门狗"
    LatencyTriggers latencyTriggers_; // 延迟触发器
    float           inactivityTimeout_; // 不活跃超时(默认 30 秒)
};
```

**Wards 机制**:多个 CellApp 共同守护一个 Proxy(多 witness),若 Proxy 长时间无消息,wards 触发报警或断开。

**LatencyTriggers**:当客户端延迟超阈值,触发 Python 回调,让游戏逻辑降级(如减少同步频率)。

### 8.10 断开流程

#### onClientDeath(proxy.cpp:748-814)

```cpp
void Proxy::onClientDeath( const Mercury::Address & addr,
                           Reason reason )
{
    // 1. 清理 Channel
    pClientChannel_ = NULL;
    
    // 2. 触发 Python onClientDetach
    pType_->callMethod( "onClientDetach", ScriptArgs::create( this, reason ) );
    
    // 3. 通知 CellApp 移除 witness
    if (pCellEntityMailBox_) {
        pCellEntityMailBox_->sendCallCellMethod( "delWitness", addr );
    }
    
    // 4. 根据 reason 决定后续:
    //    - CLIENT_DISCONNECT_REASON_NET: 网络,等重登录
    //    - CLIENT_DISCONNECT_REASON_TIMEOUT: 超时,销毁
    //    - CLIENT_DISCONNECT_REASON_KICKED: 踢出,销毁
    //    - ...
    switch (reason) {
    case CLIENT_DISCONNECT_REASON_NET:
        this->prepareForReLogOn();
        break;
    default:
        this->destroy( ScriptObject() );
        break;
    }
}
```

#### ClientDisconnectReason 枚举(7 种)

```cpp
enum ClientDisconnectReason
{
    CLIENT_DISCONNECT_REASON_NET,        // 网络问题
    CLIENT_DISCONNECT_REASON_TIMEOUT,    // 超时
    CLIENT_DISCONNECT_REASON_KICKED,     // 踢出
    CLIENT_DISCONNECT_REASON_SHUTDOWN,   // 服务器关停
    CLIENT_DISCONNECT_REASON_MIGRATING,  // 迁移中
    CLIENT_DISCONNECT_REASON_ERROR,      // 错误
    CLIENT_DISCONNECT_REASON_OTHER       // 其他
};
```

### 8.11 重登录:PendingReLogOn(proxy.cpp:57-86)

```cpp
class PendingReLogOn
{
public:
    PendingReLogOn( Proxy & proxy );
    
    // 在超时前等待重登录
    bool waitForReLogOn();
    
    // 重登录到达
    void complete( Proxy & proxy, const LogOnParams & params );
    
    // 超时,放弃
    void timeout();
    
private:
    Proxy &     proxy_;
    SessionKey  sessionKey_;
    TimerHandle timer_;
    float       timeout_;  // 默认 30 秒
};
```

**流程**:
```
1. 客户端断开 → Proxy::prepareForReLogOn
   ↓
   创建 PendingReLogOn,启动超时定时器
   
2. (超时前)客户端重连 → LoginApp → DBApp Alpha → 原 BaseApp
   ↓
   Proxy::completeReLogOnAttempt(sessionKey, params)
   ↓
   验证 sessionKey 匹配
   ↓
   PendingReLogOn::complete
   ↓
   恢复 pClientChannel_,重建 ClientEntityMailBox
   ↓
   触发 Python onClientReattached

3. (超时)PendingReLogOn::timeout
   ↓
   销毁 Proxy(执行 destroy)
```

### 8.12 giveClientTo 客户端迁移(proxy.cpp:2749-2871)

当需要把客户端从一个 Proxy 迁移到另一个 Proxy(如换 BaseApp)时:

```cpp
void Proxy::giveClientTo( Base * pTarget,
                          bool isPlayer,
                          const Mercury::Address * pNewAddr )
{
    // 1. 标记迁移中
    isGivingClientAway_ = true;
    
    // 2. 序列化客户端状态
    BinaryOStream data;
    this->writeClientStateToStream( data );
    
    // 3. 判断目标是否在本 BaseApp
    if (pTarget->pChannel() &&
        pTarget->pChannel()->addr() == this->pChannel()->addr())
    {
        // 本地迁移
        this->giveClientLocally( pTarget, isPlayer, data );
    }
    else
    {
        // 跨 BaseApp 迁移
        // 向目标 BaseApp 发 giveClientToRemote
        Mercury::Bundle & bundle = pTarget->channel().bundle();
        bundle.startMessage( BaseAppIntInterface::acceptClient );
        bundle << pTarget->id() << isPlayer << ...;
        bundle << data;
        pTarget->channel().send();
        
        // 通知 CellApp 切换 witness
        pCellEntityMailBox_->sendCallCellMethod( "switchBaseApp",
            pTarget->pCellEntityMailBox()->addr() );
    }
    
    // 4. 分离客户端(不销毁 Proxy)
    this->detachFromClient( CLIENT_DISCONNECT_REASON_MIGRATING );
}
```

#### acceptClient(proxy.cpp:1547-1591)

目标 BaseApp 收到 `acceptClient`:

```cpp
void Proxy::acceptClient( const BaseAppIntInterface::acceptClientArgs & args,
                          BinaryIStream & data )
{
    // 1. 找到目标 Proxy
    Proxy * pProxy = dynamic_cast<Proxy*>( bases_.find( args.id ) );
    
    // 2. 反序列化客户端状态
    pProxy->readClientStateFromStream( data );
    
    // 3. 重建 ClientEntityMailBox
    pProxy->attachToClient( args.clientAddr, args.key, /* addClientEntity */ true );
    
    // 4. 触发 Python onClientAttached
    ...
}
```

### 8.13 加密:SymmetricBlockCipher + EncryptionFilter

```cpp
// lib/network/symmetric_block_cipher.hpp
class SymmetricBlockCipher
{
public:
    // Blowfish 算法
    // MIN_KEY_LEN = 4 字节
    // MAX_KEY_LEN = 56 字节
    // DEFAULT_KEY_LEN = 16 字节
    
    bool init( const uint8 * key, int keyLen );
    int encrypt( const void * src, int len, void * dst );
    int decrypt( const void * src, int len, void * dst );
};

// lib/network/encryption_filter.hpp
class EncryptionFilter : public Mercury::PacketFilter
{
public:
    EncryptionFilter( SymmetricBlockCipher * pCipher );
    
    // 在发送/接收时自动加解密
    virtual PacketFilterPtr filter( ... );
};
```

---

## 九、跨进程通信

### 9.1 BaseAppMgrGateway(baseappmgr_gateway.hpp/.cpp)

```cpp
class BaseAppMgrGateway : public ManagerAppGateway
{
public:
    BaseAppMgrGateway( BaseApp & app );
    
    void add( const Mercury::Address & baseAppMgrAddr );
    void onManagerRebirth();
    void finishedInit();
    
    void registerBaseGlobally( const BW::string & name,
                               const EntityMailBoxRef & ref );
    void deregisterBaseGlobally( const BW::string & name );
    
    void registerServiceFragment( ... );
    
private:
    BaseApp & app_;
    Mercury::ChannelOwner baseAppMgr_;
};
```

### 9.2 与 CellAppMgr 的交互

| 消息 | 方向 | 用途 |
|------|------|------|
| `createEntity` | BaseAppMgr → CellAppMgr | 在 Cell 侧创建实体(配合 Base 创建) |
| `createEntityInNewSpace` | BaseApp → CellAppMgr | 在新空间创建实体 |
| `gameTimeReading` | CellAppMgr → BaseApp | 推送游戏时间 |
| `baseAppReady` | BaseApp → CellAppMgr | 通知 BaseApp 就绪 |
| `handleBaseAppDeath` | BaseAppMgr → CellAppMgr | 通知 BaseApp 死亡 |

### 9.3 与 CellApp 的交互

| 消息 | 方向 | 用途 |
|------|------|------|
| `createCellEntity` | BaseApp → CellApp | 在 Cell 创建实体 |
| `cellEntityCreated` | CellApp → BaseApp | Cell 创建完成回调 |
| `callCellMethod` | BaseApp → CellApp | 调用 Cell 方法 |
| `callBaseMethod` | CellApp → BaseApp | Cell 调用 Base 方法 |
| `addWitness` / `delWitness` | BaseApp → CellApp | 添加/移除 witness |
| `switchBaseApp` | BaseApp → CellApp | 客户端迁移时切换 witness |
| `getCellData` | BaseApp → CellApp | 取 cellData(用于 writeToDB) |

### 9.4 ServerEntityMailBox 继承体系(mailbox.hpp)

```cpp
// lib/server/server_entity_mailbox.hpp
class ServerEntityMailBox : public EntityMailBox
{
    // 通用基类:知道目标在哪个进程
};

// mailbox.hpp
class CommonCellEntityMailBox : public ServerEntityMailBox
{
    // Cell 邮箱的通用部分
};

class CellEntityMailBox : public CommonCellEntityMailBox
{
    // BaseApp 侧持有的 Cell 邮箱
    void sendCallCellMethod( int methodID, BinaryIStream & data );
};

class BaseEntityMailBox : public ServerEntityMailBox
{
    // 其他进程(BaseApp/CellApp)持有的 Base 邮箱
    void sendCallBaseMethod( int methodID, BinaryIStream & data );
};

// client_entity_mailbox.hpp
class ClientEntityMailBox : public EntityMailBox
{
    // BaseApp 侧持有的客户端邮箱(让 Base 能调客户端方法)
    void sendCallClientMethod( int methodID, BinaryIStream & data );
};
```

### 9.5 方法调用机制

#### callBaseMethod(base.cpp:1286-1342)

```cpp
void Base::callBaseMethod( int methodID, BinaryIStream & data )
{
    // 1. 查 EntityDescription,获取方法定义
    const MethodDescription * pMethod =
        pType_->description().base().method( methodID );
    
    // 2. 若有 IEntityDelegate,优先用 C++ 处理
    if (pEntityDelegate_) {
        pEntityDelegate_->onMethodCalled( methodID, data );
        return;
    }
    
    // 3. 调用 Python 方法
    ScriptObject pyMethod = pyObject_.getAttribute(
        pMethod->name() );
    if (pyMethod) {
        ScriptArgs args = pMethod->createArgs( data, ... );
        pyMethod.call( ScriptArgs::create( this ), args, ... );
    }
}
```

#### callCellMethod(base.cpp:1391-1449)

```cpp
void Base::callCellMethod( int methodID, BinaryIStream & data )
{
    // 若无 Cell 邮箱,报错
    if (!pCellEntityMailBox_) {
        ERROR_MSG("callCellMethod without cell");
        return;
    }
    
    // 转发到 CellApp
    pCellEntityMailBox_->sendCallCellMethod( methodID, data );
}
```

### 9.6 TwoWayMethodForwardingReplyHandler(双向调用)

某些调用需要 BaseApp 与 CellApp 双向协商(如迁移):

```cpp
class TwoWayMethodForwardingReplyHandler : public Mercury::ReplyMessageHandler
{
public:
    // 发起方收到回复后,转发给原始请求者
    void handleMessage( ... ) override;
    
    // 处理超时
    void handleTimeout( ... ) override;
};
```

---

## 十、实体迁移与退休

### 10.1 offload 机制(退休前迁移)

当 BaseApp 准备退休(关停或负载过高),需要把 Base 实体迁移到其他 BaseApp:

```
BaseApp 退休流程:
1. BaseAppMgr::retireApp( baseAppID )
      ↓
   BaseApp::requestRetirement()
      ↓
   isRetiring_ = true
      ↓
   startOffloading()

2. startOffloading()
      ↓
   周期性(每 tick)检查:
   - 若仍有 Base 实体,选一个,触发 offload
   - Base::offload() → backupBaseEntity with isOffload=true
      ↓
   经 BackupHash 找到目标 BaseApp
      ↓
   发送 backupBaseEntity(isOffload=true)

3. 目标 BaseApp 收到
      ↓
   EntityCreator::createBaseFromStream(backupData, isRestoration=false)
      ↓
   创建新 Base 实体
      ↓
   回复 offloadComplete(原 BaseApp)

4. 原 BaseApp 收到 offloadComplete
      ↓
   销毁原 Base(已迁移)
      ↓
   检查是否所有 Base 都已迁移
      ↓
   若是,完成退休 → controlledShutDown
```

### 10.2 BaseMessageForwarder(base_message_forwarder.hpp/.cpp)

当 Base 实体正在迁移中,可能有其他进程仍向原 BaseApp 发消息。`BaseMessageForwarder` 负责转发:

```cpp
class BaseMessageForwarder
{
public:
    void addForwardingMapping( EntityID id,
                               const Mercury::Address & newAddr );
    void forwardIfNecessary( const Mercury::Address & srcAddr,
                             EntityID id,
                             BinaryIStream & data );
    
private:
    // EntityID → 新地址 的临时映射
    BW::map< EntityID, Mercury::Address > forwardingMap_;
};
```

**流程**:
```
1. offload 触发,原 BaseApp 在 BaseMessageForwarder 注册映射
2. 其他进程向原 BaseApp 发消息(带 EntityID)
3. 原 BaseApp 收到,BaseMessageForwarder::forwardIfNecessary
4. 发现映射,转发到新 BaseApp
5. 一段时间后(或新 BaseApp 确认),移除映射
```

### 10.3 transferClient(proxy.cpp:981-1032)

`transferClient` 是 `giveClientTo` 的内部实现,用于客户端 Proxy 迁移:

```cpp
void Proxy::transferClient( Proxy & newProxy,
                            const Mercury::Address & newClientAddr )
{
    // 1. 序列化客户端状态(实体属性、witness 状态等)
    BinaryOStream data;
    this->writeClientStateToStream( data );
    
    // 2. 通知 CellApp 切换 witness 到新 BaseApp
    pCellEntityMailBox_->sendCallCellMethod( "switchBaseApp",
        newProxy.pCellEntityMailBox_->addr() );
    
    // 3. 在新 Proxy 上恢复
    newProxy.readClientStateFromStream( data );
    newProxy.attachToClient( newClientAddr, encryptionKey_, true );
    
    // 4. 原 Proxy 分离客户端
    this->detachFromClient( CLIENT_DISCONNECT_REASON_MIGRATING );
}
```

### 10.4 退休流程总结

```
触发退休:
  - BaseAppMgr 主动调 retireApp(负载均衡)
  - 受控关停 SHUTDOWN_REQUEST 阶段
  - 运维工具触发

退休流程:
  requestRetirement
      ↓
  isRetiring_ = true
      ↓
  BaseAppMgr 从负载均衡候选池移除
      ↓
  startOffloading
      ↓
  周期检查(每 tick):
    - 还有 Base 实体?
        是 → offload 一个
        否 → 完成
      ↓
  完成 → controlledShutDown
      ↓
  写回数据库(SHUTDOWN_PERFORM)
      ↓
  退出
```

---

## 十一、配置项速查

### 11.1 BaseAppMgrConfig(baseappmgr_config.hpp/.cpp)

| 配置项 | 默认值 | 含义 |
|--------|--------|------|
| `maxDestinationsInCreateBaseInfo` | 250 | updateCreateBaseInfo 候选列表最大长度 |
| `updateCreateBaseInfoPeriod` | 5.0 秒 | updateCreateBaseInfo 周期 |
| `baseAppTimeout` | 5.0 秒 | BaseApp 心跳超时 |

### 11.2 LoginConditionsConfig(login_conditions_config.hpp/.cpp)

| 配置项 | 默认值 | 含义 |
|--------|--------|------|
| `minLoad` | 0.8 | 接受登录的最大负载 |
| `minOverloadTolerancePeriod` | 5.0 秒 | 超载容忍时间 |
| `overloadLogins` | 10 | 超载时每秒仍允许的登录数 |

### 11.3 BaseAppConfig(baseapp_config.hpp/.cpp)

继承 `EntityAppConfig + ExternalAppConfig`,20+ 配置项:

| 配置项 | 默认值 | 含义 |
|--------|--------|------|
| `backupPeriod` | 10 秒 | BackupSender 周期 |
| `archivePeriod` | 100 秒 | Archiver 周期 |
| `inactivityTimeout` | 30 秒 | 客户端不活跃超时 |
| `bitsPerSecondToClient` | 20000 | 每客户端带宽上限 |
| `clientOverflowLimit` | 1000 | 客户端积压超限阈值 |
| `gameUpdateHertz` | 10 | tick 频率 |
| `shouldReverseUpdateDodb` | true | 是否反向更新 DB |
| `useSecondaryDB` | false | 是否启用二级数据库 |
| `maxDropTickProcessed` | 10 | 一次 tick 处理的最大 drop 数 |
| `externalAddress` | — | 外部监听地址 |
| `internalAddress` | — | 内部监听地址 |
| `tcpEnable` | false | 是否启用 WebSocket/TCP |
| `encryption` | false | 是否启用客户端加密 |
| `maxClientOverflowLimit` | 1000 | 客户端溢出最大限制 |
| `loadSmoothingBias` | 0.1 | 负载平滑系数 |
| `loadScale` | 1.0 | 负载缩放 |
| `createEntityLocalCall` | true | 是否本地调用 createEntity |

### 11.4 RateLimitConfig(rate_limit_config.hpp)

| 配置项 | 默认值 | 含义 |
|--------|--------|------|
| `rate` | — | 每秒允许消息数 |
| `windowSize` | — | 滑动窗口大小 |

### 11.5 DownloadStreamerConfig(download_streamer_config.hpp)

| 配置项 | 默认值 | 含义 |
|--------|--------|------|
| `bitsPerSecond` | — | 下载带宽 |
| `overflowLimit` | — | 溢出限制 |

---

## 十二、关键文件路径速查

### 12.1 BaseAppMgr 相关

| 路径 | 说明 |
|------|------|
| `programming/bigworld/server/baseappmgr/main.cpp` | 入口 |
| `programming/bigworld/server/baseappmgr/baseappmgr.hpp` | BaseAppMgr 类声明 |
| `programming/bigworld/server/baseappmgr/baseappmgr.cpp` | BaseAppMgr 实现 |
| `programming/bigworld/server/baseappmgr/baseapp.hpp` | BaseApp 内部视图类 |
| `programming/bigworld/server/baseappmgr/baseapp.cpp` | BaseApp 内部视图实现 |
| `programming/bigworld/server/baseappmgr/baseappmgr_config.hpp` | 配置 |
| `programming/bigworld/server/baseappmgr/login_conditions_config.hpp` | 登录准入配置 |
| `programming/bigworld/server/baseappmgr/baseappmgr_interface.hpp` | 消息定义 |
| `programming/bigworld/server/baseappmgr/reply_handlers.hpp` | ReplyHandler |
| `programming/bigworld/server/baseappmgr/util.hpp` | 工具类 |
| `programming/bigworld/lib/server/backup_hash.hpp` | BackupHash |
| `programming/bigworld/lib/server/backup_hash_chain.hpp` | BackupHashChain |
| `programming/bigworld/lib/server/manager_app.hpp` | ManagerApp 基类 |

### 12.2 BaseApp 主类与启动

| 路径 | 说明 |
|------|------|
| `programming/bigworld/server/baseapp/main.cpp` | 入口 |
| `programming/bigworld/server/baseapp/baseapp.hpp` | BaseApp 类声明 |
| `programming/bigworld/server/baseapp/baseapp.cpp` | BaseApp 实现(3246 行) |
| `programming/bigworld/server/baseapp/baseapp_config.hpp` | 配置 |
| `programming/bigworld/server/baseapp/baseapp_int_interface.hpp` | 内部消息(63-267 行) |
| `programming/bigworld/server/baseapp/service_app.hpp` | ServiceApp 薄包装 |
| `programming/bigworld/server/baseapp/add_to_baseappmgr_helper.hpp` | 异步注册辅助 |
| `programming/bigworld/server/baseapp/controlled_shutdown_handler.hpp` | 受控关停 |
| `programming/bigworld/lib/server/entity_app.hpp` | EntityApp 基类 |
| `programming/bigworld/lib/server/script_app.hpp` | ScriptApp 基类 |
| `programming/bigworld/lib/server/server_app.hpp` | ServerApp 基类 |

### 12.3 实体类

| 路径 | 说明 |
|------|------|
| `programming/bigworld/server/baseapp/base.hpp` | Base 类 |
| `programming/bigworld/server/baseapp/base.cpp` | Base 实现 |
| `programming/bigworld/server/baseapp/proxy.hpp` | Proxy 类声明 |
| `programming/bigworld/server/baseapp/proxy.cpp` | Proxy 实现(3300+ 行) |
| `programming/bigworld/server/baseapp/bases.hpp` | Bases 容器 |
| `programming/bigworld/server/baseapp/entity_type.hpp` | EntityType |
| `programming/bigworld/server/baseapp/entity_creator.hpp` | EntityCreator |
| `programming/bigworld/server/baseapp/base_message_forwarder.hpp` | 消息转发 |
| `programming/bigworld/server/baseapp/mailbox.hpp` | ServerEntityMailBox 体系 |
| `programming/bigworld/server/baseapp/client_entity_mailbox.hpp` | ClientEntityMailBox |
| `programming/bigworld/lib/entitydef/entity_description_map.hpp` | EntityDescriptionMap |
| `programming/bigworld/lib/entitydef/entity_description.hpp` | EntityDescription |
| `programming/bigworld/lib/entitydef/entity_delegate.hpp` | IEntityDelegate |

### 12.4 客户端连接

| 路径 | 说明 |
|------|------|
| `programming/bigworld/server/baseapp/pending_logins.hpp` | PendingLogins |
| `programming/bigworld/server/baseapp/login_handler.hpp` | LoginHandler |
| `programming/bigworld/server/baseapp/rate_limit_message_filter.hpp` | 限流 |
| `programming/bigworld/server/baseapp/initial_connection_filter.hpp` | 初始连接过滤 |
| `programming/bigworld/server/baseapp/download_streamer.hpp` | 下载流控 |
| `programming/bigworld/server/baseapp/data_downloads.hpp` | DataDownloads |
| `programming/bigworld/lib/network/symmetric_block_cipher.hpp` | Blowfish 加密 |
| `programming/bigworld/lib/network/encryption_filter.hpp` | EncryptionFilter |

### 12.5 备份与持久化

| 路径 | 说明 |
|------|------|
| `programming/bigworld/server/baseapp/backup_sender.hpp` | BackupSender |
| `programming/bigworld/server/baseapp/archiver.hpp` | Archiver |
| `programming/bigworld/server/baseapp/sqlite_database.hpp` | SqliteDatabase |
| `programming/bigworld/server/baseapp/backed_up_base_app.hpp` | BackedUpBaseApp 双缓冲 |
| `programming/bigworld/server/baseapp/backed_up_base_apps.hpp` | BackedUpBaseApps |
| `programming/bigworld/server/baseapp/offloaded_backups.hpp` | OffloadedBackups |
| `programming/bigworld/server/baseapp/write_to_db_reply.hpp` | WriteToDBReply |
| `programming/bigworld/lib/db/dbapps_gateway.hpp` | DBAppsGateway |
| `programming/bigworld/lib/db/dbapp_interface.hpp` | DBAppInterface |

### 12.6 跨进程网关

| 路径 | 说明 |
|------|------|
| `programming/bigworld/server/baseapp/baseappmgr_gateway.hpp` | BaseAppMgrGateway |
| `programming/bigworld/server/baseapp/global_bases.hpp` | GlobalBases |
| `programming/bigworld/server/baseapp/shared_data_manager.hpp` | SharedDataManager |
| `programming/bigworld/server/baseapp/dead_cell_apps.hpp` | DeadCellApps |
| `programming/bigworld/lib/server/manager_app_gateway.hpp` | ManagerAppGateway 基类 |

### 12.7 脚本

| 路径 | 说明 |
|------|------|
| `programming/bigworld/server/baseapp/script_bigworld.hpp` | BigWorldBaseAppScript |
| `programming/bigworld/server/baseapp/script_bigworld.cpp` | Python 绑定(L2120-2223 init) |
| `programming/bigworld/server/baseapp/py_bases.hpp` | PyBases |
| `programming/bigworld/server/baseapp/py_cell_data.hpp` | PyCellData |
| `programming/bigworld/lib/entitydef/game_delegate.hpp` | IGameDelegate |

---

## 十三、设计亮点与注意事项

### 13.1 设计亮点

#### 1. 控制平面与数据平面分离
BaseAppMgr 不持有任何实体,只负责调度。这使得 BaseAppMgr 可以轻量级重启(故障恢复快),而 BaseApp 数据完整性由 BackupHash + DBApp 双重保障。

#### 2. 三层负载均衡的协同
- **第一层**(createEntity 实时):保证立即响应,但增加 BaseAppMgr 压力
- **第二层**(updateBestBaseApp 每 tick):CellAppMgr 知道最佳 BaseApp,减少 BaseAppMgr 中转
- **第三层**(updateCreateBaseInfo 周期):BaseApp 本地有候选列表,Python 直接选,零中转

三层协同实现**响应速度与中心压力的平衡**。

#### 3. BackupHash 主动管理 vs Rendezvous 被动计算
- DBApp 用 Rendezvous 哈希:每个 DBApp 独立计算,无需中心协调(适合数据分片)
- BaseApp 用 BackupHash:BaseAppMgr 主动下发,支持双缓冲过渡(适合备份关系)

两种哈希都解决了"动态成员下的稳定映射"问题,但侧重点不同。

#### 4. 双缓冲备份过渡
`BackedUpBaseApp` 的 `currentBackup_` + `newBackup_` 双缓冲,确保 BackupHash 变更期间不丢失备份。这是分布式系统"再配置"问题的优雅解法。

#### 5. Proxy 继承 Base 的双重身份
Proxy 既是实体(有 Python 脚本、可被调方法),又是客户端连接(管理 Channel)。这避免了"实体"与"连接"分离带来的状态同步问题。

#### 6. sessionKey 用 timestamp() 生成
`regenerateSessionKey` 用 `timestamp()` 生成 sessionKey,简单且保证唯一性(在同一 BaseApp 生命周期内)。无需复杂的 token 颁发机制。

#### 7. BundlePrimer 自动注入
每个发往客户端的 bundle 自动注入 `authenticate`(首次)+ `tickSync`(每次),确保时间同步与认证无需业务代码关心。

#### 8. BaseMessageForwarder 迁移期消息转发
offload 期间,其他进程仍可能向原 BaseApp 发消息。BaseMessageForwarder 维护临时映射,透明转发到新 BaseApp,实现"无缝迁移"。

#### 9. 主线程独占 Python
`BWResource::watchAccessFromCallingThread(true)` 强制 Python 与实体操作只在主线程。这避免了 Python GIL 的复杂性,Worker 线程只做序列化/IO,不碰 Python。

#### 10. ServiceApp 薄包装复用代码
ServiceApp 通过 `isServiceApp_` 标志区分,共用 BaseApp 全部代码。这避免了"全局服务"与"普通 BaseApp"两套实现,降低维护成本。

### 13.2 注意事项

#### 1. BaseApp 侧无 Entity 类
开发者在 BaseApp 侧的 Python 代码中,`self` 是 `Base` 或 `Proxy`,不是 `Entity`。CellApp 才有 `Entity`。跨进程调用时注意类型差异。

#### 2. entity_defs.hpp 不存在
实际使用 `entity_description_map.hpp` + `entity_description.hpp`。文档与代码中若引用 `entity_defs.hpp` 是错误的。

#### 3. script_callbacks.cpp 不存在
BaseApp 侧的 Python 绑定在 `script_bigworld.cpp`,不是 `script_callbacks.cpp`。

#### 4. space_data_mappings.hpp 实际在 lib/network
不在 `server/baseapp/`,而在 `lib/network/space_data_mappings.hpp`。

#### 5. writeToDB 是两阶段
Base 实体写回数据库需要先从 CellApp 取 cellData,因此是异步的。Python 调 `base.writeToDB()` 后不会立即完成,需要通过回调确认。

#### 6. InitStateFlags 14.4.1 简化
14.4.1 中 `InitStateFlags` 仅 `READY_BASE_APP_MGR` 一个标志,历史版本的 `READY_CELL_APP_MGR` 等已合并。

#### 7. createEntity 的乐观计数
`BaseAppMgr::createEntity` 在转发后立即 `pBestApp->addEntity()`,这是乐观更新。若 BaseApp 创建失败,需要后续修正。

#### 8. Proxy 的 Wards 与 LatencyTriggers
高负载下 Wards 可能误判,需调优 `inactivityTimeout` 与 `wards` 数量。

#### 9. offload 不是同步的
`Base::offload` 只是触发,实际迁移异步进行。Python 代码不应假设 offload 后立即销毁。

#### 10. DBApp Alpha 单点
BaseApp 的 `dbAppAlpha_` 通道是单点(指向 DBApp Alpha)。若 DBApp Alpha 死亡,BaseApp 需等待 BaseAppMgr 推送新 Alpha 地址。期间 logOn/getIDs 等会失败。

### 13.3 与其他进程的对比

| 维度 | BaseApp | CellApp | DBApp | LoginApp |
|------|---------|---------|-------|----------|
| 主要职责 | 客户端 + Base 实体 | Cell 实体 + AOI | 数据持久化 | 登录网关 |
| 状态 | 有状态(实体+客户端) | 有状态(实体+空间) | 有状态(数据库) | 无状态 |
| 多实例 | 是 | 是 | 是 | 是 |
| 控制平面 | BaseAppMgr | CellAppMgr | DBAppMgr | 无 |
| 备份 | BackupHash(对端 BaseApp) | 无(实体在 BaseApp 备份) | 数据库自身 | 无 |
| 客户端连接 | 是(Proxy) | 否(witness 在 BaseApp) | 否 | 是(仅登录) |
| Python 脚本 | 是(Base/Proxy) | 是(Entity) | 否 | 否 |
| 持久化 | 经 DBApp | 经 BaseApp | 直接 | 无 |

### 13.4 性能调优建议

1. **backupPeriod**:大量 Base 实体时,适当增大(如 20 秒),减少备份压力
2. **archivePeriod**:数据库压力大时,适当增大(如 200 秒)
3. **bitsPerSecondToClient**:根据客户端网络调整,移动端建议 5000-10000
4. **clientOverflowLimit**:高延迟客户端多时,适当增大(如 2000)
5. **gameUpdateHertz**:10 Hz 是默认,实时性要求高可调到 20 Hz(但增加 CPU 压力)
6. **maxDestinationsInCreateBaseInfo**:BaseApp 数量多时,适当增大(如 500)
7. **useSecondaryDB**:实体多且 writeToDB 频繁时,启用二级数据库

---

## 附录:BaseAppIntInterface 关键消息(63-267 行)

| 消息 | 行号 | 用途 |
|------|------|------|
| `createBaseWithCellData` | — | BaseAppMgr 转发的实体创建 |
| `createBaseFromStream` | — | 从流恢复(备份/offload) |
| `logOnAttempt` | — | LoginApp 转发的登录 |
| `startup` | — | BaseAppMgr 通知启动 |
| `controlledShutDown` | — | 受控关停 |
| `backupBaseEntity` | — | 备份实体(BackupSender) |
| `handleBaseAppDeath` | — | 其他 BaseApp 死亡 |
| `updateDBAppHash` | — | DBApp 哈希更新 |
| `updateCreateBaseInfo` | — | 候选列表更新 |
| `setSharedData` | — | 共享数据更新 |
| `restoreBaseApp` | — | 恢复 GlobalBase |
| `acceptClient` | — | 接收迁移的客户端 |
| `useNewBackupHash` | — | 切换新备份哈希 |
| `registerBaseGlobally` | — | 注册全局 Base |
| `deregisterBaseGlobally` | — | 注销全局 Base |
| `baseAppMgrBirth` | — | BaseAppMgr 复活 |
| `retireApp` | — | 退休 |
| `addWitness` / `delWitness` | — | witness 管理(转 CellApp) |

---

> 本文档基于 BigWorld Engine 14.4.1 源码分析整理,涵盖了 BaseApp 与 BaseAppMgr 的架构、启动、负载均衡、备份容错、实体管理、脚本系统、持久化、客户端连接、跨进程通信、迁移退休、配置体系等所有核心机制。如需深入了解某一部分,可参照"关键文件路径速查"章节定位源码。
