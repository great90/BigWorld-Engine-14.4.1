# BigWorld Engine 数据存储实现深度分析

> 本文档详细分析 BigWorld Engine 14.4.1 中数据存储子系统的完整实现,涵盖 DBAppMgr、DBApp、dbapp_extensions、以及 MySQL/XML 两种存储引擎的核心机制。

---

## 目录

- [一、整体架构概览](#一整体架构概览)
- [二、DBAppMgr:数据库管理器进程](#二dbappmgr数据库管理器进程)
- [三、DBApp:数据库应用进程](#三dbapp数据库应用进程)
- [四、dbapp_extensions:数据库引擎扩展机制](#四dbapp_extensions数据库引擎扩展机制)
- [五、MySQL 数据存储实现](#五mysql-数据存储实现)
- [六、XML 数据存储实现](#六xml-数据存储实现)
- [七、MySQL 与 XML 实现对比](#七mysql-与-xml-实现对比)
- [八、关键文件路径速查](#八关键文件路径速查)
- [九、设计亮点与注意事项](#九设计亮点与注意事项)

---

## 一、整体架构概览

BigWorld 数据存储子系统采用**三层分层 + 工厂扩展**架构:

```
┌──────────────────────────────────────────────────────────────────┐
│ 第 1 层:应用进程层(server/)                                    │
│   ┌─────────────────┐      ┌─────────────────────────────────┐  │
│   │   DBAppMgr      │      │            DBApp                │  │
│   │ (单例管理进程)  │◀────▶│ (实际数据库访问进程,可多实例)  │  │
│   │ - DBApp 哈希管理│      │ - IDatabase 持有               │  │
│   │ - Alpha 选举    │      │ - BillingSystem 持有(Alpha)   │  │
│   │ - LoginApp 注册 │      │ - 实体 CRUD/登录/合并          │  │
│   └─────────────────┘      └─────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
               │                              │
               │              ┌───────────────┴───────────────┐
               │              ▼                               ▼
┌──────────────────────────────────────────────────────────────────┐
│ 第 2 层:扩展与抽象层                                            │
│   ┌────────────────────────┐   ┌────────────────────────────┐   │
│   │  dbapp_extensions/     │   │  lib/db_storage/           │   │
│   │  bwengine_mysql/       │   │  - IDatabase (接口)        │   │
│   │  bwengine_xml/         │   │  - DatabaseEngineCreator   │   │
│   │  (链接期注册的 Creator)│   │  - BillingSystem           │   │
│   └────────────────────────┘   │  - BillingSystemCreator    │   │
│                                 └────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────┘
               │                              │
               ▼                              ▼
┌──────────────────────────────────────────────────────────────────┐
│ 第 3 层:具体存储引擎实现层(lib/)                                │
│   ┌─────────────────────────────────┐  ┌─────────────────────┐   │
│   │  lib/db_storage_mysql/          │  │  lib/db_storage_xml/│   │
│   │  - MySqlDatabase                │  │  - XMLDatabase      │   │
│   │  - 90+ 源文件                   │  │  - 4 个源文件       │   │
│   │  - 完整 RDBMS 实现              │  │  - 演示/开发用      │   │
│   │    (后台任务/事务/映射/表同步)  │  │                     │   │
│   └─────────────────────────────────┘  └─────────────────────┘   │
└──────────────────────────────────────────────────────────────────┘
```

### 1.1 进程拓扑

```
bwmachined (机器守护进程)
    │
    └─ DBAppMgr (单例)
         │
         ├─ DBApp Alpha (第一个,负责首次初始化)
         │   ├─ 持有 BillingSystem
         │   ├─ 持有 DB Lock
         │   ├─ 处理登录请求(经哈希路由)
         │   ├─ 实体自动加载
         │   ├─ Space 数据恢复
         │   └─ 数据合并(关停时)
         │
         └─ DBApp Non-Alpha (后续,可扩展)
             ├─ 处理部分 DBID 范围的实体操作
             └─ 由 Rendezvous 哈希分片
```

### 1.2 核心抽象接口

`IDatabase`(`lib/db_storage/idatabase.hpp:47-485`)是所有存储引擎的统一接口,定义:

| 类别 | 方法 | 说明 |
|------|------|------|
| **生命周期** | `startup()`, `shutDown()`, `resetGameServerState()` | 启动/关闭/重置 |
| **能力查询** | `supportsMultipleDBApps()` | 是否支持多 DBApp |
| **实体 CRUD** | `getEntity()`, `putEntity()`, `delEntity()` | 实体检出/写入/删除 |
| **查询** | `lookUpEntities()`, `getDatabaseIDFromName()` | 实体查询 |
| **ID 管理** | `getIDs()`, `putIDs()` | EntityID 分配与回收 |
| **空间数据** | `writeSpaceData()`, `getSpacesData()` | 空间数据持久化 |
| **二级 DB** | `addSecondaryDB()`, `updateSecondaryDBs()`, `getSecondaryDBs()` | 二级数据库管理 |
| **锁** | `lockDB()`, `unlockDB()` | 数据库独占锁 |
| **邮箱重映射** | `remapEntityMailboxes()` | BaseApp 死亡后邮箱迁移 |
| **自动加载** | `autoLoadEntities()` | 启动时自动加载实体 |
| **计费工厂** | `createBillingSystem()` | 创建与本引擎绑定的计费系统 |
| **杂项** | `executeRawCommand()`, `getBaseAppMgrInitData()`, `setGameTime()` | 工具/初始化数据 |

---

## 二、DBAppMgr:数据库管理器进程

DBAppMgr 是数据存储子系统的"控制平面",**不直接访问数据库**,而是管理 DBApp 进程的生命周期、哈希分片与 Alpha 选举。

### 2.1 文件结构

| 文件 | 职责 |
|------|------|
| `server/dbappmgr/main.cpp` | 入口,`bwMainT<DBAppMgr>(argc, argv)` |
| `server/dbappmgr/dbappmgr.cpp/.hpp` | 核心类 `DBAppMgr`,继承 `ManagerApp + TimerHandler + Singleton<DBAppMgr>` |
| `server/dbappmgr/dbapp.cpp/.hpp` | DBApp 视图类(DBAppMgr 对一个 DBApp 的引用计数句柄) |
| `server/dbappmgr/dbappmgr_config.cpp/.hpp` | 配置类(无自有项,全继承 `ServerAppConfig`) |
| `server/dbappmgr/external_interfaces.cpp` | 实例化 `BaseAppMgrInterface`/`CellAppMgrInterface`/`LoginIntInterface` |
| `server/dbappmgr/message_handlers.cpp` | `MessageHandlerFinder<DBApp>` 路由到具体 DBApp 视图 |
| `lib/db/dbappmgr_interface.hpp` | DBAppMgrInterface 消息定义 |
| `lib/db/db_hash_schemes.hpp` | `DBAppIDBuckets` Rendezvous 哈希方案 |

### 2.2 启动流程(init,dbappmgr.cpp:121-249)

```
init() [L121]
  ├─ 阶段1:基类初始化 + 接口注册 [L123-138]
  │   ├─ ManagerApp::init(argc, argv)
  │   ├─ 校验 interface().isGood()
  │   └─ DBAppMgrInterface::registerWithInterface(interface_)
  │
  ├─ 阶段2:定位 CellAppMgr 与 BaseAppMgr [L140-167]
  │   └─ Mercury::MachineDaemon::findInterface(..., numStartupRetries)
  │
  ├─ 阶段3:同步询问 BaseAppMgr 启动状态 [L169-205]
  │   ├─ BaseAppMgrInterface::requestHasStarted (阻塞)
  │   ├─ 若 hasStarted=true → STARTUP_STATE_STARTED + gatherLoginAppsTimer(2s)
  │   └─ 若 hasStarted=false → STARTUP_STATE_NOT_STARTED
  │
  ├─ 阶段4:向 machined 注册与监听 [L209-234]
  │   ├─ DBAppMgrInterface::registerWithMachined
  │   ├─ registerBirthListener(handleDBAppMgrBirth) — 自身唯一性
  │   ├─ registerDeathListener(handleDBAppDeath, "DBInterface")
  │   ├─ registerDeathListener(handleLoginAppDeath, "LoginIntInterface")
  │   ├─ registerBirthListener(handleBaseAppMgrBirth)
  │   └─ registerBirthListener(handleCellAppMgrBirth)
  │
  ├─ 阶段5:Reviver 注册 [L236]
  │   └─ ReviverSubject::init(&interface_, "dbAppMgr")
  │
  └─ 阶段6:定时器与 Watcher [L238-246]
      ├─ tickTimer_ = addTimer(1000000/updateHertz, TIMEOUT_TICK)
      └─ BW_REGISTER_WATCHER + addWatchers()
```

### 2.3 启动状态机(三态)

```cpp
enum StartupState {
    STARTUP_STATE_NOT_STARTED,    // 全新启动,等首个 DBApp
    STARTUP_STATE_STARTED,        // 服务器已运行(恢复)
    STARTUP_STATE_INDETERMINATE   // Alpha 正在做一次性初始化
};
```

状态转换:
- `NOT_STARTED` → 第一个 DBApp 注册时,`sendDBAppHashUpdate` 给 Alpha 带 `shouldAlphaResetGameServerState=true`,转 `INDETERMINATE`(L671)
- `INDETERMINATE` → Alpha 完成后回发 `serverHasStarted`,转 `STARTED`(L812-813)
- `INDETERMINATE` + Alpha 死亡 → 异步问 BaseAppMgr,根据回复转 `STARTED` 或 `NOT_STARTED`

### 2.4 DBApp 添加与恢复

#### addDBApp(dbappmgr.cpp:480-526)

```cpp
void DBAppMgr::addDBApp(...) {
    if (startupState_ == STARTUP_STATE_INDETERMINATE) {
        // Alpha 还在初始化,空回复让 DBApp 稍后重试
        channel.bundle().startReply(header.replyID); channel.send(); return;
    }
    ++lastDBAppID_;                                       // 单调递增
    DBAppPtr pDBApp = new DBApp(interface_, srcAddr, lastDBAppID_, header.replyID);
    dbApps_.insert(std::make_pair(lastDBAppID_, pDBApp)); // Rendezvous 哈希表
    addressMap_[srcAddr] = pDBApp;
    if (wasEmpty) sendDBAppHashUpdate(true);              // 首个=Alpha,立即回复
    else dbAppAddStartWaitTime_ = timestamp();            // 非 Alpha 批量延迟 1s
}
```

#### recoverDBApp(dbappmgr.cpp:533-551)

```cpp
void DBAppMgr::recoverDBApp(..., const recoverDBAppArgs & args) {
    DBAppID id = args.id;                                 // 沿用原 ID
    if (id > lastDBAppID_) lastDBAppID_ = id;             // 防止 ID 回退
    DBAppPtr pDBApp = new DBApp(interface_, srcAddr, id, REPLY_ID_NONE); // 无回复
    dbApps_.insert(std::make_pair(id, pDBApp));
}
```

**关键差异**:
- `addDBApp`:分配新 ID,延迟回复(携带哈希),触发 Alpha 选举
- `recoverDBApp`:沿用原 ID,无回复,不立即下发哈希(等批量刷新)

### 2.5 DBApp 死亡处理与 Alpha 切换(dbappmgr.cpp:562-633)

```cpp
void DBAppMgr::handleDBAppDeath(const Mercury::Address & addr) {
    const bool wasAlpha = (addr == dbAppAlpha()->address());
    dbApps_.erase(iter->second->id());                    // 从哈希表删除
    addressMap_.erase(iter);
    if (isShuttingDown_) return;
    if (wasAlpha && startupState_ == STARTUP_STATE_INDETERMINATE) {
        // Alpha 在首次初始化期间死亡,异步问 BaseAppMgr
        baseAppMgr_.bundle().startRequest(requestHasStarted, new HasStartedRequestHandler(*this));
        return;
    }
    DBAppPtr pAlphaApp = this->dbAppAlpha();              // 新 Alpha = smallest id
    this->sendDBAppHashUpdate(wasAlpha);                  // 广播新哈希
}
```

**Alpha 选举机制**:
```cpp
DBApp * DBAppMgr::dbAppAlpha() {
    return dbApps_.empty() ? NULL : dbApps_.smallest().second;
}
```
- **隐式选举**:`dbApps_.smallest()` 即最小 DBAppID 的 DBApp
- **无状态**:无需显式 Alpha 字段,所有进程用同样规则得到同一结果
- **稳定性**:ID 单调递增且不复用,Alpha 总是"最老的存活 DBApp"

### 2.6 哈希广播机制(sendDBAppHashUpdate,dbappmgr.cpp:643-703)

```cpp
void DBAppMgr::sendDBAppHashUpdate(bool haveNewAlpha) {
    sendDBAppHashUpdateToBaseAppMgr();                    // 总是发:整张哈希表
    for (each DBApp) {
        bool shouldAlphaReset = (iter == dbApps_.begin()) &&
                                (startupState_ == STARTUP_STATE_NOT_STARTED);
        pDBApp->updateDBAppHash(dbApps_, shouldAlphaReset); // 首个 Alpha 带 reset 标志
        if (shouldAlphaReset) startupState_ = INDETERMINATE;
    }
    if (haveNewAlpha) {
        sendDBAppHashUpdateToCellAppMgr();                // 只发 Alpha 地址
        for (each LoginApp) notifyDBAppAlpha(newAlpha);   // 通知所有 LoginApp
    }
}
```

**三个广播方向**:
| 目标 | 消息 | 内容 | 触发条件 |
|------|------|------|---------|
| BaseAppMgr | `updateDBAppHash` | 整张哈希表 | 每次哈希变更 |
| 每个 DBApp | `updateDBAppHash` | 整张哈希表 + reset 标志 | 每次哈希变更 |
| CellAppMgr | `setDBAppAlpha` | 仅 Alpha 地址 | 仅 haveNewAlpha |
| LoginApps | `notifyDBAppAlpha` | 仅 Alpha 地址 | 仅 haveNewAlpha |

#### DBApp 视图类的回复合并(dbapp.hpp:60-81)

```cpp
template< typename HASH >
void DBApp::updateDBAppHash(const HASH & hash, bool shouldAlphaResetGameServerState) {
    Mercury::Bundle & bundle = channelOwner_.channel().bundle();
    if (pendingReplyID_ != Mercury::REPLY_ID_NONE) {      // addDBApp 的回复
        bundle.startReply(pendingReplyID_);
        pendingReplyID_ = Mercury::REPLY_ID_NONE;
        bundle << id_;                                    // 回复里带分配的 id
    } else {
        bundle.startMessage(DBAppInterface::updateDBAppHash); // 常规哈希更新
    }
    bundle << uint8(shouldAlphaResetGameServerState);
    bundle << hash;                                       // 序列化整张哈希表
    channelOwner_.channel().send();
}
```

**设计精妙**:同一方法承担两种语义——(a) addDBApp 的首次回复(携带 id + 哈希),(b) 后续纯哈希刷新。区分依据是 `pendingReplyID_`。

### 2.7 LoginApp 注册

#### addLoginApp(dbappmgr.cpp:741-770)

```cpp
void DBAppMgr::addLoginApp(...) {
    if (!shouldAcceptLoginApps_ || dbApps_.empty()) return;  // 零长度回复 = 稍后重试
    loginApps_.insert(srcAddr);
    bundle << ++lastLoginAppID_ << dbAppAlpha()->address();  // 回复 ID + Alpha 地址
}
```

#### gatherLoginAppsTimer(2 秒窗口)

恢复启动时,2 秒内收集所有旧 LoginApp 的 `recoverLoginApp` 回调,窗口结束后 `shouldAcceptLoginApps_ = true`。

### 2.8 tick 与批量回复

```cpp
void DBAppMgr::handleTimeout(TimerHandle handle, void * arg) {
    switch (uintptr(arg)) {
    case TIMEOUT_TICK: this->advanceTime(); break;
    case TIMEOUT_GATHER_LOGIN_APPS:
        gatherLoginAppsTimer_.clearWithoutCancel();
        shouldAcceptLoginApps_ = true;                    // 恢复窗口结束
        break;
    }
}

void DBAppMgr::onStartOfTick() {                          // 批量回复触发点
    if (dbAppAddStartWaitTime_ != 0 &&
        dbAppAddStartWaitTime_.ageInSeconds() >= ADD_WAIT_TIME_SECONDS) // 1.0s
        this->sendDBAppHashUpdate(false);
}
```

**批量合并设计**:非 Alpha DBApp 注册后等 1 秒,合并窗口内多个 DBApp 到一次广播,显著降低启动风暴期的广播量。

### 2.9 消息处理表

| 消息 | 处理方法 | 行号 | 说明 |
|------|---------|------|------|
| `addDBApp` | `addDBApp` | L480 | 新 DBApp 注册,分配 id |
| `recoverDBApp` | `recoverDBApp` | L533 | DBApp 恢复,沿用原 id |
| `handleDBAppDeath` | `handleDBAppDeath` | L562 | machined 死亡通知 |
| `handleLoginAppDeath` | `handleLoginAppDeath` | L322 | LoginApp 死亡 |
| `handleDBAppMgrBirth` | `handleDBAppMgrBirth` | L307 | 唯一性约束,新实例则自己退出 |
| `handleBaseAppMgrBirth` | `handleBaseAppMgrBirth` | L361 | BaseAppMgr 复活,重发哈希 |
| `handleCellAppMgrBirth` | `handleCellAppMgrBirth` | L372 | CellAppMgr 复活,重发 Alpha |
| `handleBaseAppDeath` | `handleBaseAppDeath` | L332 | 转发 blob 给所有 DBApp |
| `controlledShutDown` | `controlledShutDown` | L255 | 两阶段关停 |
| `addLoginApp` | `addLoginApp` | L741 | LoginApp 注册 |
| `recoverLoginApp` | `recoverLoginApp` | L781 | LoginApp 恢复 |
| `serverHasStarted` | `serverHasStarted` | L798 | Alpha 完成首次初始化通告 |

---

## 三、DBApp:数据库应用进程

DBApp 是数据存储子系统的"数据平面",**实际持有 IDatabase 实例**并执行所有数据库操作。

### 3.1 文件结构

| 文件 | 职责 |
|------|------|
| `server/dbapp/main.cpp` | 入口 |
| `server/dbapp/dbapp.cpp/.hpp/.ipp` | 主类 DBApp(2830+ 行) |
| `server/dbapp/dbapp_config.cpp/.hpp` | 配置类 |
| `server/dbapp/message_handlers.cpp` | 宏生成消息分发 |
| `server/dbapp/add_to_dbappmgr_helper.hpp` | 异步注册辅助 |
| `server/dbapp/dbappmgr_gateway.cpp/.hpp` | DBAppMgr 通道网关 |
| `server/dbapp/custom.cpp/.hpp` | 自定义扩展点 |
| `server/dbapp/consolidator.cpp/.hpp` | 数据合并器 |
| `server/dbapp/login_handler.cpp/.hpp` | 登录处理器 |
| `server/dbapp/load_entity_handler.cpp` 等 | 实体操作处理器 |
| `server/dbapp/log_on_records_cache.cpp/.hpp` | 登录记录缓存 |

### 3.2 类继承

```cpp
class DBApp : public ScriptApp,                             // 脚本层支持
             public TimerHandler,                            // 定时器
             public IDatabase::IGetBaseAppMgrInitDataHandler,
             public IDatabase::IUpdateSecondaryDBshandler,
             public Singleton< DBApp >                       // 单例
```

### 3.3 完整初始化流程(异步分阶段)

DBApp 的初始化是**事件驱动**的,核心设计:`init()` 只完成同步部分,后续在 `onDBAppMgrRegistrationCompleted()` 回调中继续,Alpha 路径还涉及多个异步回调链。

#### 阶段 1:同步初始化 init()(dbapp.cpp:191-208)

```
init() [L191]
  ├─ initNetwork() [L216]              // 网络,INIT_STATE_NETWORK
  ├─ initBaseAppMgr() [L245]           // 查找 BaseAppMgr
  ├─ initScript() [L295]               // Python,加载 database 脚本
  ├─ initEntityDefs() [L349]           // entities.xml + digest
  ├─ initExtensions() [L380]           // dlopen -extensions/*.so,INIT_STATE_EXTENSIONS
  ├─ initDatabaseCreation() [L404]     // DatabaseEngineCreator::createInstance
  └─ initDBAppMgrAsync() [L454]        // 异步注册,等待回调
       └─ (init() 返回 true,等回调)
```

关键代码:
```cpp
return this->initNetwork() &&
    this->initBaseAppMgr() &&
    this->initScript( argc, argv ) &&
    this->initEntityDefs() &&
    this->initExtensions() &&
    this->initDatabaseCreation() &&
    this->initDBAppMgrAsync();
```

#### 阶段 2:DBAppMgr 注册完成回调 onDBAppMgrRegistrationCompleted()(dbapp.cpp:488-561)

由 `AddToDBAppMgrHelper::finishInit()` 调用,从回复流读取 `id_`、`shouldAlphaResetGameServerState` 和 `dbApps_` 哈希表。

```
onDBAppMgrRegistrationCompleted(data) [L488]
  ├─ initAppIDRegistration() [L569]     // logger appID, machined 注册
  ├─ initDatabaseStartup() [L603]       // pDatabase_->startup(),非 Alpha 校验多 DBApp
  ├─ initBirthDeathListeners() [L643]   // DBAppMgr birth/death listener
  ├─ initWatchers() [L684]              // watcher "dbappXX"
  ├─ initConfig() [L740]                // shouldCacheLogOnRecords_
  ├─ initReviver() [L771]               // ReviverSubject
  ├─ initGameSpecific() [L792]          // 空扩展点
  │
  ├─ [分支 A] isAlpha() → initDBAppAlpha() [L810]  (见阶段 3)
  └─ [分支 B] 非 Alpha:
       ├─ initTimers() [L1275]
       ├─ initScriptAppReady() [L1111]  // 触发 onAppReady
       └─ onInitCompleted() [L1301]     // status=RUNNING
```

#### 阶段 3:DBApp Alpha 专属初始化 initDBAppAlpha()(dbapp.cpp:810-839)

```
initDBAppAlpha() [L810]
  ├─ initAcquireDBLock() [L847]         // pDatabase_->lockDB()
  ├─ initBillingSystem() [L859]         // BillingSystemCreator::createFromConfig
  │
  ├─ [首次启动 shouldAlphaResetGameServerState_=true]:
  │   └─ initResetGameServerState() [L881]
  │       └─ initSecondaryDBsAsync() [L901]
  │           ├─ initSecondaryDBPrefix() [L940]  // "user_YYYYMMDD_HHMMSS"
  │           ├─ if xml 类型 → onSecondaryDBsInitCompleted()
  │           ├─ if !shouldConsolidate → onSecondaryDBsInitCompleted()
  │           └─ else → consolidateData() [L1318]
  │               └─ onConsolidateProcessEnd(isOK) [L1382]  (异步)
  │                   └─ onSecondaryDBsInitCompleted() [L996]
  │
  └─ onSecondaryDBsInitCompleted() [L996]  (汇聚点)
      ├─ initBaseAppMgrInitData() [L1019]      // sendBaseAppMgrInitData
      ├─ initDatabaseResetGameServerState() [L1041]
      └─ initWaitForAppsToBecomeReadyAsync() [L1054]
          └─ status → WAITING_FOR_APPS, initTimers() [L1275]
```

#### 阶段 4:等待其他 App 就绪

```
checkStatus() [L1663]  (每秒由 TIMEOUT_STATUS_CHECK 触发)
  └─ 若 status==WAITING_FOR_APPS 且 baseAppMgr 通道已建立:
      └─ 向 BaseAppMgr 发 checkStatus 请求
          └─ handleStatusCheck(data) [L1446]  (回调)
              └─ 若 baseApps/cellApps/serviceApps 达标 → onAppsReady() [L1078]

onAppsReady() [L1078]
  ├─ initScriptAppReady() [L1111]
  ├─ [若 shouldAlphaResetGameServerState_]:
  │   ├─ status → RESTORING_STATE
  │   ├─ initSendSpaceData() [L1147]      // 从 DB 读 space 数据发往 BaseAppMgr
  │   └─ initEntityAutoLoadingAsync() [L1179]
  │       └─ onEntitiesAutoLoadCompleted(didAutoLoad) [L1219]  (异步)
  │           ├─ initNotifyServerStartup(didAutoLoad) [L1248]
  │           └─ onInitCompleted() [L1301]
  └─ [非首次]: onInitCompleted() [L1301]

onInitCompleted() [L1301]
  └─ 校验 (initState_ & NON_ALPHA_MASK) == NON_ALPHA_MASK
  └─ status → RUNNING
```

### 3.4 InitStateFlags 状态机

```cpp
enum InitStateFlags {
    INIT_STATE_NETWORK                  = (1 << 0),
    INIT_STATE_EXTENSIONS               = (1 << 1),
    INIT_STATE_DATABASE_STARTUP         = (1 << 2),
    INIT_STATE_APP_ID_REGISTRATION      = (1 << 3),
    INIT_STATE_BIRTH_DEATH_LISTENERS    = (1 << 4),
    INIT_STATE_WATCHERS                 = (1 << 5),
    INIT_STATE_CONFIG                   = (1 << 6),
    INIT_STATE_REVIVER                  = (1 << 7),
    INIT_STATE_GAME_SPECIFIC            = (1 << 8),
    INIT_STATE_SCRIPT_APP_READY         = (1 << 9),
    INIT_STATE_NON_ALPHA_MASK           = (INIT_STATE_SCRIPT_APP_READY << 1) - 1, // 0~9
    INIT_STATE_SECONDARY_DBS            = (1 << 10),  // Alpha 专属
    INIT_STATE_SPACE_DATA_RESTORE       = (1 << 11),  // Alpha 专属
    INIT_STATE_AUTO_LOADING             = (1 << 12)   // Alpha 专属
};
```

`onInitCompleted()` 通过 `NON_ALPHA_MASK` 断言所有必需步骤完成,这是一种轻量的初始化完整性保障机制。

### 3.5 DBApp Alpha 与非 Alpha 的差异

| 维度 | DBApp Alpha | DBApp Non-Alpha |
|------|-------------|-----------------|
| **判定** | `id_ == dbApps_.alpha().id()` | 同上取反 |
| **BillingSystem** | 创建(`initBillingSystem`,L859) | 不创建,`pBillingSystem_=NULL` |
| **DB 锁** | `initAcquireDBLock()` 独占 | 不加锁 |
| **二级 DB** | `initSecondaryDBsAsync()` 生成 prefix、可能合并 | 不处理 |
| **游戏状态重置** | 首次启动执行 | 不执行 |
| **BaseAppMgr initData** | `initBaseAppMgrInitData()` 发送 | 不发送 |
| **Space 数据恢复** | `initSendSpaceData()` | 不执行 |
| **实体自动加载** | `initEntityAutoLoadingAsync()` | 不执行 |
| **服务器启动通知** | `initNotifyServerStartup()` | 不执行 |
| **多 DBApp 校验** | 无 | `initDatabaseStartup()` 校验 `supportsMultipleDBApps()` |
| **BaseApp 死亡处理** | `handleBaseAppDeath()` 邮箱重映射 | 直接 `data.finish()` 忽略 |
| **关停时合并** | `shutDownNicely()` 若 shouldConsolidate 则 consolidateData | 直接 shutDown() |
| **InitStateFlags** | 额外 SECONDARY_DBS、SPACE_DATA_RESTORE、AUTO_LOADING | 不置这些位 |
| **promotion** | 可被降级 | 可经 `updateDBAppHash()` 提升为 Alpha |

### 3.6 DBStatus 状态机

```
STARTING (0)
   │ initWaitForAppsToBecomeReadyAsync() [L1064]
   ├────────────────────────────────────→ WAITING_FOR_APPS (2)
   │                                        │ onAppsReady() [L1093]
   │                                        ├─────────────→ RESTORING_STATE (3)
   │                                        │                  │ onEntitiesAutoLoadCompleted()
   │                                        │                  ├────────────→ RUNNING (4)
   │                                        │
   │   consolidateData() [L1322]             │
   ├────────────────────────────────────→ STARTUP_CONSOLIDATING (1)
   │                                        │ onConsolidateProcessEnd(OK) [L1390]
   │                                        │   → onSecondaryDBsInitCompleted()
   │                                        │       → initWaitForAppsToBecomeReadyAsync()
   │                                        │           → WAITING_FOR_APPS
   │
RUNNING (4)
   │ shutDownNicely() [L1842]
   ├────────────────────────────────────→ SHUTTING_DOWN (5)
   │   consolidateData() [L1326] (Alpha)
   │      ↓
   │   SHUTDOWN_CONSOLIDATING (6)
   │      │ onConsolidateProcessEnd() [L1405]
   │      └─→ shutDown() → breakProcessing
```

### 3.7 事件循环与 tick

```cpp
// initTimers() [L1275-1292]
statusCheckTimer_ = mainDispatcher_.addTimer(1000000, this,
    reinterpret_cast<void*>(TIMEOUT_STATUS_CHECK), "StatusCheck");   // 每秒
gameTimer_ = mainDispatcher_.addTimer(1000000/Config::updateHertz(), this,
    reinterpret_cast<void*>(TIMEOUT_GAME_TICK), "GameTick");          // 游戏 tick
```

**handleTimeout() 分发**:
- `TIMEOUT_GAME_TICK` → `advanceTime()`(注意:DBApp 的时间不与集群同步,见 L1286 注释)
- `TIMEOUT_STATUS_CHECK` → `checkStatus()`:
  1. WAITING_FOR_APPS 状态下向 BaseAppMgr 发 checkStatus
  2. 更新 `curLoad_` 负载值
  3. 递减 `mailboxRemapCheckCount_`,归零时 `endMailboxRemapping()`
  4. `checkPendingLoginAttempts()` 清理超时重登录
  5. 检测 `hasUnrecoverableError()` 触发关停

构造函数设置 `mainDispatcher.maxWait(0.02)`,即事件循环最多阻塞 20ms。

### 3.8 登录流程(logOn,dbapp.cpp:1997-2088)

**入口重载**(L1997):从消息流解析 `addrForProxy` 和 `LogOnParams`,校验 defs digest。

**核心重载**(L2022)执行四级闸门检查:

```cpp
void DBApp::logOn(...) {
    // 1. 状态检查
    if (status_ != RUNNING) return sendFailure(LOGIN_REJECTED_SERVER_NOT_READY);
    // 2. BillingSystem 检查
    if (pBillingSystem_ == NULL) return sendFailure(LOGIN_REJECTED_DBAPP_NOT_READY);
    // 3. 过载检查(容忍期机制)
    if (calculateOverloaded(isOverloaded)) return sendFailure(LOGIN_REJECTED_DBAPP_OVERLOAD);
    // 4. CellApp 过载检查
    if (hasOverloadedCellApps_) return sendFailure(LOGIN_REJECTED_CELLAPP_OVERLOAD);
    // 通过 → 创建 LoginHandler
    LoginHandler * pHandler = new LoginHandler(...);
    pHandler->login(...);
}
```

**过载容忍机制**(`calculateOverloaded`,L2095-2118):不是立即拒绝,而是记录 `overloadStartTime_`,只有持续过载超过 `overloadTolerancePeriodInStamps()` 才真正拒绝。

**LoginHandler 流程**:
```
login() → pBillingSystem->getEntityKeyForAccount()
  ├─ onGetEntityKeyForAccountSuccess → loadEntity()   (已有账号)
  ├─ onGetEntityKeyForAccountCreateNew → createNewEntity()  (新建)
  └─ onGetEntityKeyForAccountLoadFromUsername → 按用户名加载
```

### 3.9 二级数据库(Secondary DB)机制

二级数据库是 BaseApp 本地的轻量数据库,用于减少 DBApp Alpha 的写入压力。

| 消息 | 处理方法 | 行号 | 说明 |
|------|---------|------|------|
| `secondaryDBRegistration` | `secondaryDBRegistration` | L1507 | BaseApp 注册本地二级 DB |
| `updateSecondaryDBs` | `updateSecondaryDBs` | L1522 | 比对后删除不再注册的条目 |
| `getSecondaryDBDetails` | `getSecondaryDBDetails` | L1537 | 返回新二级 DB 文件名 |

**文件名生成**:基于 `secondaryDBPrefix_`(格式 `user_YYYYMMDD_HHMMSS`)和递增 `secondaryDBIndex_`,例如 `user_20260628_120000_1.db`。

**清理机制**:`onUpdateSecondaryDBsComplete()`(L1566-1587)对每个被移除的条目,调用 `sendRemoveDBCmd()`(L1622)向目标 machined 发送 `commands/remove_db` 命令删除文件。

### 3.10 数据合并(Consolidator)

`consolidateData()`(L1318-1348)根据当前状态选择目标状态:
- 启动期间 → `STARTUP_CONSOLIDATING`
- 关停期间 → `SHUTDOWN_CONSOLIDATING`

`startConsolidationProcess()`(L1357-1376)创建 `Consolidator` 对象,其 `startConsolidation()`(consolidator.cpp:167-201):
1. **先释放 DB 锁**(`unlockDB()`)
2. 通过 `ChildProcess` 启动 `commands/consolidate_dbs` 子进程
3. 管道捕获 stderr

`onChildComplete()`(consolidator.cpp:72-130)子进程结束时:
- 判断成功状态
- **重新获取 DB 锁**(最多重试 20 次,每次 sleep 1 秒)
- 调用 `dbApp_.onConsolidateProcessEnd()`

`onConsolidateProcessEnd()`(L1382-1413)状态分发:
- `STARTUP_CONSOLIDATING` + 成功 → `onSecondaryDBsInitCompleted()` 继续初始化
- `STARTUP_CONSOLIDATING` + 失败 → `shouldConsolidate(false)` 防止重试 + `startSystemControlledShutdown()`
- `SHUTDOWN_CONSOLIDATINGING` → `shutDown()` 真正退出

### 3.11 邮箱重映射(remapMailbox)

当 BaseApp 死亡时,其上的实体被迁移到备份 BaseApp,数据库中记录的 mailbox 地址需要更新。

`handleBaseAppDeath()`(L2666-2696,仅 Alpha 处理):
1. 读取 `remappingSrcAddr`(死亡 BaseApp 地址)和 `isServiceApp`
2. 从流中读取 `BackupHash` 存入 `mailboxRemapInfo_[remappingSrcAddr]`
3. 调用 `pDatabase_->remapEntityMailboxes()` 更新数据库
4. 若启用缓存,`logOnRecordsCache_.remapMailboxes()` 更新缓存
5. 设置 `mailboxRemapCheckCount_ = 5`(5 秒窗口)

`remapMailbox()`(L2713-2726)在 `putEntity()`(L1967)和 `GetEntityHandler::onGetEntityComplete()`(get_entity_handler.cpp:18-27)中被调用,将旧地址映射到新地址(保留 salt)。

`endMailboxRemapping()`(L2702-2706)在 `checkStatus()` 中 `mailboxRemapCheckCount_` 递减到 0 时调用,清空 `mailboxRemapInfo_`。这个 5 秒窗口设计是为了在 BaseApp 死亡后的短暂期间内,拦截并修正仍在途的旧地址写入。

### 3.12 受控关停

| 方法 | 行号 | 行为 |
|------|------|------|
| `shutDown(args)` | L1801 | 接收消息后直接 `shutDown()` |
| `shutDown()` | L1862 | `mainDispatcher_.breakProcessing()` 中断事件循环 |
| `shutDownNicely()` | L1832 | SHUTTING_DOWN → `processUntilChannelsEmpty()` → Alpha 合并 → `shutDown()` |
| `startSystemControlledShutdown()` | L1810 | 向 BaseAppMgr 发 `SHUTDOWN_TRIGGER` |
| `controlledShutDown(args)` | L1873 | 两阶段:REQUEST → 请求 DBAppMgr;PERFORM → `shutDownNicely()` |

### 3.13 消息处理表

#### 生命周期消息

| 消息 | 处理方法 | 行号 | 说明 |
|------|---------|------|------|
| `handleBaseAppMgrBirth` | `handleBaseAppMgrBirth` | L1747 | Alpha 时发送 initData |
| `handleDBAppMgrBirth` | `handleDBAppMgrBirth` | L1769 | 调用 `recoverDBApp(id_)` |
| `handleDBAppMgrDeath` | `handleDBAppMgrDeath` | L1782 | 清空地址 |
| `handleBaseAppDeath` | `handleBaseAppDeath` | L2666 | 启动邮箱重映射(仅 Alpha) |
| `shutDown` | `shutDown` | L1801 | 立即关停 |
| `controlledShutDown` | `controlledShutDown` | L1873 | 两阶段受控关停 |
| `cellAppOverloadStatus` | `cellAppOverloadStatus` | L1928 | 更新 `hasOverloadedCellApps_` |

#### 实体消息

| 消息 | 处理方法 | 行号 | 委托 Handler |
|------|---------|------|--------------|
| `logOn` | `logOn` | L1997/L2022 | LoginHandler |
| `authenticateAccount` | `authenticateAccount` | L2373 | AuthenticateAccountHandler |
| `loadEntity` | `loadEntity` | L2385 | LoadEntityHandler |
| `writeEntity` | `writeEntity` | L2298 | WriteEntityHandler |
| `deleteEntity` | `deleteEntity` | L2439 | DeleteEntityHandler |
| `lookupEntity` | `lookupEntity` | L2454 | LookUpEntityHandler |
| `lookupEntityByName` | `lookupEntityByName` | L2469 | LookUpEntityHandler |
| `lookupDBIDByName` | `lookupDBIDByName` | L2486 | LookUpDBIDHandler |
| `lookupEntities` | `lookupEntities` | L2509 | LookUpEntitiesHandler |

#### 杂项消息

| 消息 | 处理方法 | 行号 | 说明 |
|------|---------|------|------|
| `executeRawCommand` | `executeRawCommand` | L2569 | 执行原生 SQL |
| `putIDs` | `putIDs` | L2582 | 存储 EntityID 池 |
| `getIDs` | `getIDs` | L2636 | 获取 EntityID |
| `writeSpaces` | `writeSpaces` | L2654 | 写入 space 数据 |
| `writeGameTime` | `writeGameTime` | L2732 | 写入游戏时间 |
| `checkStatus` | `checkStatus` | L1419 | 转发到 BaseAppMgr |
| `secondaryDBRegistration` | `secondaryDBRegistration` | L1507 | 注册二级 DB |
| `updateSecondaryDBs` | `updateSecondaryDBs` | L1522 | 更新二级 DB 列表 |
| `getSecondaryDBDetails` | `getSecondaryDBDetails` | L1537 | 获取新二级 DB 文件名 |
| `updateDBAppHash` | `updateDBAppHash` | L1594 | 哈希更新,可能触发 Alpha 提升 |

### 3.14 数据成员清单

| 成员名 | 类型 | 用途 |
|--------|------|------|
| `id_` | `DBAppID` | 本 DBApp 的 ID,由 DBAppMgr 分配 |
| `dbApps_` | `DBAppsGateway` | 所有 DBApp 的网关集合(含哈希方案) |
| `pEntityDefs_` | `EntityDefs*` | 实体定义(digest、属性描述) |
| `pDatabase_` | `IDatabase*` | 数据库抽象接口实例 |
| `pBillingSystem_` | `BillingSystem*` | 计费/认证系统(仅 Alpha) |
| `status_` | `DBStatus` | 当前状态机 |
| `dbAppMgr_` | `DBAppMgrGateway` | DBAppMgr 通道网关 |
| `baseAppMgr_` | `BaseAppMgr` | BaseAppMgr 通道(非常规) |
| `initState_` | `uint16` | InitStateFlags 位掩码 |
| `shouldAlphaResetGameServerState_` | `bool` | Alpha 是否需重置游戏状态 |
| `statusCheckTimer_` | `TimerHandle` | 1 秒状态检查定时器 |
| `gameTimer_` | `TimerHandle` | 游戏 tick 定时器 |
| `pendingAttempts_` | `map<EntityKey, RelogonAttemptHandler*>` | 进行中的重登录尝试 |
| `inProgCheckouts_` | `EntityKeySet` | 正在检出中的实体集合 |
| `curLoad_` | `float` | 当前负载(0~1) |
| `hasOverloadedCellApps_` | `bool` | 是否有 CellApp 过载 |
| `overloadStartTime_` | `uint64` | 过载开始时间戳 |
| `mailboxRemapInfo_` | `map<Address, BackupHash>` | 邮箱重映射信息 |
| `mailboxRemapCheckCount_` | `int` | 重映射剩余检查次数(初始 5) |
| `secondaryDBPrefix_` | `BW::string` | 二级 DB 文件名前缀 |
| `secondaryDBIndex_` | `uint` | 二级 DB 递增索引 |
| `pConsolidator_` | `std::auto_ptr<Consolidator>` | 合并器实例 |
| `shouldCacheLogOnRecords_` | `bool` | 是否启用登录记录缓存 |
| `logOnRecordsCache_` | `LogOnRecordsCache` | 登录记录缓存 |

---

## 四、dbapp_extensions:数据库引擎扩展机制

BigWorld 的数据库引擎扩展采用 **"运行期 dlopen 装载 + 链接期静态注册"** 的混合工厂模式。

### 4.1 扩展机制总体架构

```
┌──────────────────────────────────────────────────────────────────┐
│ 第 4 层:DBApp 启动流程                                          │
│   init() → ... → initExtensions → initDatabaseCreation           │
│                  ↓                ↓                              │
│            dlopen 插件     DatabaseEngineCreator::createInstance │
└──────────────┬───────────────────────────────────────────────────┘
               │
   ┌───────────┴────────────┐
   ▼                        ▼
┌──────────────────┐   ┌──────────────────────────────────────┐
│ 第 3 层:插件装载 │   │ 第 3 层:计费系统工厂                  │
│ PluginLibrary::  │   │ BillingSystemCreator::createFromConfig│
│ loadAllFromDir-  │   │ 读 <billingSystem/type>              │
│ RelativeToApp    │   │ 遍历 g_pBillingSystemCollection       │
│ dlopen(*.so/.dle)│   │ 匹配 typeName() → create()           │
└────────┬─────────┘   └────────────────┬─────────────────────┘
         │ 触发静态初始化                 │
         ▼                              │
┌────────────────────────────────────────┐
│ 第 2 层:工厂抽象层 (lib/db_storage)    │
│  DatabaseEngineCreator (继承 Intrusive │
│   Object<DatabaseEngineCreator>)       │
│  BillingSystemCreator (继承 Intrusive  │
│   Object<BillingSystemCreator>)        │
└────────┬───────────────────────────────┘
         │ 注册到全局容器
         ▼
┌────────────────────────────────────────┐
│ 第 1 层:IntrusiveObject 模板           │
│ 构造时 push_back 进 Container*&;       │
│ 析构时 O(1) swap-pop 移除              │
└────────────────────────────────────────┘
         ▲
         │ 派生
┌────────┴───────────────────────────────┐
│ 第 0 层:具体扩展实现                   │
│  bwengine_mysql → MySqlEngineCreator   │
│  bwengine_xml   → XMLEngineCreator     │
│  (dbapp/*.cpp 中的 BillingSystemCreator)│
│   StandardBillingSystemCreator         │
│   BWAuthBillingSystemCreator           │
│   CustomBillingSystemCreator           │
└────────────────────────────────────────┘
```

### 4.2 IntrusiveObject 链接期注册机制

`IntrusiveObject<ELEMENT>`(`lib/cstdmf/intrusive_object.hpp`)是模板基类,通过构造/析构副作用自动维护全局集合:

```cpp
// L33-50:构造函数
IntrusiveObject( Container *& pContainer, bool shouldAdd = true ) :
    pContainer_( pContainer ),
    containerPos_( std::numeric_limits< size_type >::max() )
{
    if (shouldAdd) {
        if (pContainer_ == NULL) {
            pContainer_ = new Container;        // 按需创建容器
        }
        containerPos_ = pContainer_->size();
        pContainer_->push_back( pThis() );      // 把自己塞进去
    }
}

// L69-90:析构函数(O(1) swap-pop)
~IntrusiveObject() {
    if (pContainer_ != NULL && ...) {
        pContainer_->at(containerPos_) = pContainer_->back();  // 末尾元素换位
        pContainer_->at(containerPos_)->containerPos_ = containerPos_;
        pContainer_->pop_back();
        if (pContainer_->empty()) { bw_safe_delete(pContainer_); } // 空则删除
    }
}
```

**关键特性**:
- 第一个参数是 `Container *&`(指针的引用),`new Container` 的结果回写到全局指针
- 析构采用 `swap-with-last + pop_back` 的 O(1) 删除法
- 容器空时自动 `delete`,全局指针回 NULL
- `pThis()` 通过 `static_cast<ELEMENT*>` 把 `this` 转成派生类指针

#### 链接期注册实现套路

每个具体 Creator 子类在自己的 `.cpp` 文件中放置**匿名命名空间内的静态对象**:

```cpp
// mysql_engine_creator.cpp L34-39
namespace {
MySqlEngineCreator staticInitialiser;
}
```

- 匿名命名空间保证符号不外泄、避免链接冲突
- 静态对象的生命周期与所在翻译单元(进而与所在共享库)一致
- **不需要 main() 介入**,也**不需要导出 entry-point 符号**
- 只要该 `.o` 被链接进二进制(或 `.so` 被 `dlopen` 装载),静态初始化器就会自动运行

#### 全局容器存放位置

```cpp
// db_engine_creator.cpp L14-17
typedef BW::vector< DatabaseEngineCreator * > DatabaseEngines;
DatabaseEngines * g_pDatabaseEnginesCollection = NULL;

// billing_system_creator.cpp L16-19
typedef BW::vector< BillingSystemCreator * > BillingSystems;
BillingSystems * g_pBillingSystemCollection = NULL;
```

派生类构造时把 `g_pDatabaseEnginesCollection` 作为 `Container*&` 传入:
```cpp
// db_engine_creator.cpp L43-46
DatabaseEngineCreator::DatabaseEngineCreator( const BW::string & typeName ) :
    IntrusiveObject< DatabaseEngineCreator >( g_pDatabaseEnginesCollection ),
    typeName_( typeName )
{ }
```

### 4.3 DatabaseEngineCreator 类层次

```
IntrusiveObject<DatabaseEngineCreator>      (cstdmf/intrusive_object.hpp)
        ▲
        │
DatabaseEngineCreator (abstract)            (db_storage/db_engine_creator.hpp L51)
   ├─ typeName_ : BW::string
   ├─ static createInstance(type, data)
   ├─ private create(type, data)            // 按 typeName 匹配
   └─ protected virtual createImpl(data) = 0
        ▲
        ├── MySqlEngineCreator  (typeName="mysql")  [bwengine_mysql/.so]
        └── XMLEngineCreator    (typeName="xml")    [bwengine_xml/.so]
```

#### DatabaseEngineData 数据载体(`db_engine_creator.hpp` L21-41)

DBApp 传给引擎实现的"启动参数包":

```cpp
class DatabaseEngineData {
public:
    DatabaseEngineData( Mercury::NetworkInterface & interface_,
                        Mercury::EventDispatcher & dispatcher,
                        bool isProduction );
    Mercury::NetworkInterface & interface();
    Mercury::EventDispatcher & dispatcher();
    bool isProduction();
private:
    Mercury::NetworkInterface * pInterface_;
    Mercury::EventDispatcher * pDispatcher_;
    bool isProduction_;
};
```

#### 工厂流程(三步)

**第 1 步——静态分发**(`db_engine_creator.cpp` L87-115):

```cpp
/* static */ IDatabase * DatabaseEngineCreator::createInstance(
    const BW::string type, const DatabaseEngineData & dbEngineData )
{
    if (g_pDatabaseEnginesCollection == NULL) { WARNING_MSG(...); return NULL; }
    for (each creator in g_pDatabaseEnginesCollection) {
        pDatabase = (*iter)->create( type, dbEngineData );
        if (pDatabase) return pDatabase;
    }
    return NULL;
}
```

**第 2 步——类型名匹配**(`db_engine_creator.cpp` L61-73):

```cpp
IDatabase * DatabaseEngineCreator::create( const BW::string type,
        const DatabaseEngineData & dbEngineData ) const
{
    if (type.empty() || type == typeName_) {        // 空字符串视为匹配第一个
        return this->createImpl( const_cast<DatabaseEngineData &>( dbEngineData ) );
    }
    return NULL;
}
```

注意 `type.empty()` 的兜底语义:**如果配置为空,则第一个注册的 Creator 命中**——这是一个隐式的回退行为。

**第 3 步——具体实现**(见下表)。

### 4.4 MySQL / XML 引擎 Creator 对比

| 维度 | MySqlEngineCreator | XMLEngineCreator |
|------|--------------------|------------------|
| 文件 | `dbapp_extensions/bwengine_mysql/mysql_engine_creator.cpp` | `dbapp_extensions/bwengine_xml/xml_engine_creator.cpp` |
| typeName | `"mysql"` (L20) | `"xml"` (L20) |
| CMake 目标 | `BW_ADD_LIBRARY(bwengine_mysql MODULE ...)` | `BW_ADD_LIBRARY(bwengine_xml MODULE ...)` |
| 静态注册器 | `MySqlEngineCreator staticInitialiser;` (L37) | `XMLEngineCreator staticInitialiser;` (L49) |
| `createImpl` | 委托 `createMySqlDatabase(interface, dispatcher)` | 直接 `new XMLDatabase()` |
| `isProduction` 处理 | 不使用 | **检查并 ERROR_MSG 警告**:XML 仅用于演示/评估 |
| 多 DBApp 支持 | `supportsMultipleDBApps()` 默认 true | 重写为 **false** |

#### XML 引擎的生产环境警告

```cpp
// xml_engine_creator.cpp L27-43
IDatabase * createImpl( DatabaseEngineData & dbEngineData ) const
{
    IDatabase * pDatabase = new XMLDatabase();
    if (pDatabase && dbEngineData.isProduction()) {
        ERROR_MSG(
            "The XML database is suitable for demonstrations and "
            "evaluations only.\n"
            "Please use the MySQL database for serious development and "
            "production systems.\n" ... );
    }
    return pDatabase;
}
```

### 4.5 DBApp 集成点:initExtensions + initDatabaseCreation

#### initExtensions(dbapp.cpp:380-396)

```cpp
bool DBApp::initExtensions()
{
    status_.set( DBStatus::STARTING, "Loading database plugins" );
    if (!PluginLibrary::loadAllFromDirRelativeToApp( true, "-extensions" )) {
        ERROR_MSG( "DBApp::initExtensions: Failed to load plugins.\n" );
        return false;
    }
    initState_ |= INIT_STATE_EXTENSIONS;
    return true;
}
```

`PluginLibrary::loadAllFromDirRelativeToApp(true, "-extensions")` 行为:
- **Linux**:读 `/proc/self/exe` 拿到可执行文件路径,拼 `+ "-extensions/"`,扫描 `.so`,`dlopen(..., RTLD_LAZY | RTLD_GLOBAL)` 装载
- **Windows**:扫描 `.dle`,`LoadLibraryEx(..., LOAD_WITH_ALTERED_SEARCH_PATH)`
- `RTLD_GLOBAL` 保证符号对所有后续装载的库可见,这对 IntrusiveObject 的全局容器指针解析至关重要

#### initDatabaseCreation(dbapp.cpp:404-442)

```cpp
bool DBApp::initDatabaseCreation()
{
    MF_ASSERT( (initState_ & INIT_STATE_NETWORK) && (initState_ & INIT_STATE_EXTENSIONS) );
    // 校验插件先于引擎实例化装载(硬约束)
    if (!DBConfig::get().isGood()) { return false; }
    BW::string databaseType = DBConfig::get().type();  // 读取 <db/type>
    DatabaseEngineData dbEngineData( this->interface(),
        this->mainDispatcher(),
        DBAppConfig::isProduction() );
    pDatabase_ = DatabaseEngineCreator::createInstance( databaseType, dbEngineData );
    return pDatabase_ != NULL;
}
```

**时序保证**:因为 `initExtensions` 在前,所有被部署的 `-extensions/*.so` 都已 dlopen,其内部的 `staticInitialiser` 已运行,`g_pDatabaseEnginesCollection` 已填充。

### 4.6 数据库引擎选择决策流程

```
[启动] BIGWORLD_MAIN (main.cpp L9)
   │
   ▼
bwMainT<DBApp> → DBApp::init() (dbapp.cpp L191)
   │
   ├─ initExtensions ── dlopen <exe>-extensions/*.so/.dle
   │      │             (bwengine_mysql.so / bwengine_xml.so)
   │      │             触发 staticInitialiser 构造
   │      │             → g_pDatabaseEnginesCollection 填充
   │      │               {MySqlEngineCreator("mysql"),
   │      │                XMLEngineCreator("xml")}
   │      ▼
   │   INIT_STATE_EXTENSIONS 置位
   │
   └─ initDatabaseCreation (dbapp.cpp L404)
          │
          ├─ DBConfig::get().isGood() 校验
          ├─ databaseType = DBConfig::get().type()  // <db/type>,默认 "xml"
          ├─ DatabaseEngineData(interface, dispatcher, isProduction)
          │
          └─ DatabaseEngineCreator::createInstance(databaseType, ...)
                │
                ▼
             遍历 g_pDatabaseEnginesCollection
                ├─ type=="mysql" → MySqlEngineCreator.createImpl
                │      → createMySqlDatabase() → new MySqlDatabase
                ├─ type=="xml"   → XMLEngineCreator.createImpl
                │      → new XMLDatabase (isProduction 时告警)
                └─ type 为空  → 第一个注册的 Creator 命中
```

### 4.7 BillingSystem 工厂体系

#### 抽象基类

```cpp
// billing_system_creator.hpp L21-41
class BillingSystemCreator : public IntrusiveObject< BillingSystemCreator >
{
public:
    BillingSystemCreator();
    virtual BW::string typeName() = 0;
    virtual BillingSystem * create( const EntityDefs & entityDefs,
                                    ServerApp & app ) const = 0;
    static BillingSystem * createFromConfig( const EntityDefs & entityDefs,
                                             ServerApp & app );
};
```

#### 工厂入口 createFromConfig(billing_system_creator.cpp L39-79)

```cpp
BW::string type = BWConfig::get( "billingSystem/type", "standard" );  // 默认 standard
for (each creator in g_pBillingSystemCollection) {
    if ((*iter)->typeName() == type) {
        BillingSystem * pBillingSystem = (*iter)->create( entityDefs, app );
        if (pBillingSystem && !pBillingSystem->isOkay()) {
            ERROR_MSG("Billing system is not configured correctly\n");
            delete pBillingSystem;
            pBillingSystem = NULL;
        }
        return pBillingSystem;
    }
}
return NULL;
```

注意 **`isOkay()` 校验**——创建后立即检查配置正确性,失败则删除并返回 NULL。

#### 三种 BillingSystemCreator 对比

| Creator | typeName | 文件 | 用途 |
|---------|----------|------|------|
| `StandardBillingSystemCreator` | `"standard"` | `dbapp/standard_billing_system.cpp` L28 | **默认**。先尝试 Python Personality 的 `connectToBillingSystem()`;若返回 None,回退到 `IDatabase::createBillingSystem()` |
| `BWAuthBillingSystemCreator` | `"bwauth"` | `dbapp/bwauth_billing_system.cpp` L38 | 通过 RESTful API 接入 BigWorld Indie Auth 服务 |
| `CustomBillingSystemCreator` | `"custom"` | `dbapp/custom_billing_system.cpp` L21 | **骨架/示例**,供项目方填空实现 |

#### IDatabase 与 BillingSystem 的关系

**`IDatabase::createBillingSystem()` 是 IDatabase 接口的纯虚方法**(`idatabase.hpp` L73),每个数据库实现提供"与自身存储绑定的默认计费系统":

- `MySqlDatabase::createBillingSystem()` → `new MySqlBillingSystem(bgTaskManager_, *pEntityDefs_)`(账号映射存 MySQL 表)
- `XMLDatabase::createBillingSystem()` → `new XMLBillingSystem(pLogonMapSection, *pEntityDefs_, this)`(账号映射存 XML 段)

`StandardBillingSystemCreator` 形成**回退链**:
```
Python Personality 的 connectToBillingSystem()
   │
   ├─ 返回非 None → new PyBillingSystem(python对象)
   │
   └─ 返回 None → IDatabase::createBillingSystem()
                   ├─ MySqlDatabase → MySqlBillingSystem
                   └─ XMLDatabase   → XMLBillingSystem
```

**设计含义**:计费系统既可以独立于数据库(通过 `BillingSystemCreator` 工厂按 type 选择 bwauth/custom/standard-python),也可以由数据库自带(standard 回退路径)。这种双层设计让"账号映射存储位置"可以灵活选择——存在 MySQL 表里、XML 文件里,或外部 Auth 服务里。

### 4.8 Custom 扩展点清单

| 扩展点 | 文件 | 说明 |
|--------|------|------|
| `createNewEntity()` | `custom.cpp/.hpp` | 实体创建钩子,默认实现创建 XMLSection 并写入 identifier |
| `initGameSpecific()` | `dbapp.cpp` L792-801 | **空实现**,预留给项目方覆写的游戏特定初始化 |
| `PyUserTypeBinder` | `lib/db_storage_mysql/py_user_type_binder.hpp` | 通过 Python 脚本的 `bindSectionToDB` 方法动态绑定 USER_TYPE 持久化 |

### 4.9 配置项对照

| 配置路径 | 默认值 | 作用 | 来源 |
|---------|--------|------|------|
| `<db/type>` | `"xml"` | 选择数据库引擎 | `db_config.cpp` L272 |
| `<db/mysql/...>` | localhost/bigworld/... | MySQL 连接参数 | `db_config.cpp` L164-176 |
| `<db/xml/...>` | archivePeriod=3600 等 | XML 归档参数 | `db_config.cpp` L224-229 |
| `<billingSystem/type>` | `"standard"` | 选择计费系统 | `billing_system_creator.cpp` L42 |
| `<billingSystem/shouldAcceptUnknownUsers>` | false | 接受未知用户 | `billing_system.cpp` L17 |
| `<billingSystem/shouldRememberUnknownUsers>` | false | 记住未知用户 | L19 |
| `<billingSystem/authenticateViaBaseEntity>` | false | 由 base entity 认证 | L21 |
| `<billingSystem/entityTypeForUnknownUsers>` | `""` | 未知用户实体类型名 | L24 |
| `<production>/isProduction` | true | 生产环境标志 | `server_app_config.cpp` L35 |

### 4.10 关键问题解答

**Q1:为什么 BigWorld 采用链接期注册而不是运行期 dlopen?**

实际上 BigWorld **同时采用了两者**,各司其职:
- **dlopen(运行期)**:`initExtensions` 通过 `PluginLibrary::loadAllFromDirRelativeToApp` 装载 `<exe>-extensions/*.so`,决定"哪些引擎被部署到本机"。
- **链接期静态注册(侵入式)**:每个 `.so` 内的 `staticInitialiser` 在 dlopen 触发时构造,把 Creator 塞进 `g_pDatabaseEnginesCollection`,决定"被部署的引擎如何被发现"。

优势:
1. 无需为每个插件定义 `register()` 入口符号并 `dlsym` 查找,降低样板
2. 插件作者只需写一个继承 `DatabaseEngineCreator` 的类 + 一个静态对象,完全声明式
3. 主程序代码不依赖任何具体引擎符号,引擎可独立编译/部署/替换
4. 静态初始化在 dlopen 时确定性触发(因为 dlopen 在 main() 之后),避开了 C++ 跨翻译单元静态初始化顺序的未定义行为

**Q2:一个 DBApp 进程是否可以同时支持多种数据库引擎?**

**注册层面可以,实例层面不可以**。
- `g_pDatabaseEnginesCollection` 可以同时容纳 `MySqlEngineCreator` 和 `XMLEngineCreator`
- 但 `initDatabaseCreation` 只调用一次 `createInstance`,只产出**一个** `IDatabase*` 实例
- 配置 `<db/type>` 决定哪一个被实例化
- 一个 DBApp 进程同一时刻只使用一种引擎

**Q3:引擎扩展如何影响编译选项?**

- `bwengine_mysql/CMakeLists.txt` 与 `bwengine_xml/CMakeLists.txt` 都用 `BW_ADD_LIBRARY(<name> MODULE ...)`,生成动态库
- `dbapp/CMakeLists.txt` 的链接列表只含 `db_storage`(抽象层),**不含 `db_storage_mysql` 或 `db_storage_xml`**
- 部署时,构建产物 `bwengine_mysql.so`/`bwengine_xml.so` 需放到 `<dbapp 可执行文件路径>-extensions/` 目录

---

## 五、MySQL 数据存储实现

`lib/db_storage_mysql/` 目录包含 90+ 源文件,是 BigWorld 数据存储的**生产级实现**。

### 5.1 整体架构

```
┌─────────────────────────────────────────────────────────────────────┐
│                        DBApp(主线程)                                 │
│   ┌───────────────────────┐    ┌──────────────────────────────┐    │
│   │   MySqlDatabase       │    │  Mercury::EventDispatcher    │    │
│   │   (实现 IDatabase,    │    │  (doTask() 每帧调用          │    │
│   │    继承 FrequentTask) │───▶│   bgTaskManager_.tick())     │    │
│   └──────────┬────────────┘    └──────────────────────────────┘    │
│              │                                                     │
│   ┌──────────▼────────────┐  ┌─────────────────────────────────┐  │
│   │ EntityTypeMappings    │  │ BufferedEntityTasks             │  │
│   │ (按 typeID 索引       │  │ (实体级串行锁,                  │  │
│   │  EntityTypeMapping*)  │  │  multimap 缓冲待执行任务)       │  │
│   └──────────┬────────────┘  └─────────────┬───────────────────┘  │
│              │                              │                      │
│   ┌──────────▼──────────────────────────────▼──────────────────┐  │
│   │              TaskManager bgTaskManager_                    │  │
│   │      (主线程 addBackgroundTask → 工作线程队列)              │  │
│   └──────────────────────────┬─────────────────────────────────┘  │
└──────────────────────────────┼─────────────────────────────────────┘
                               │ (跨线程)
┌──────────────────────────────▼─────────────────────────────────────┐
│              N 个工作线程(numConnections_,默认5)                  │
│   ┌────────────────────────────────────────────────────────────┐  │
│   │ BackgroundTaskThread (每个线程)                            │  │
│   │  └─ MySqlThreadData (每线程独立 MySql 连接)                │  │
│   │      └─ MySql (封装 MYSQL* C API)                         │  │
│   └────────────────────────────────────────────────────────────┘  │
│   执行 MySqlBackgroundTask::doBackgroundTask():                    │
│     1. MySqlTransaction transaction(conn)  // START TRANSACTION   │
│     2. performBackgroundTask(conn)         // 子类实现SQL          │
│     3. transaction.commit()                // COMMIT              │
│     4. mgr.addMainThreadTask(this)         // 回主线程回调         │
└───────────────────────────────────────────────────────────────────┘
```

### 5.2 核心设计原则

- **主线程不阻塞**:所有 SQL 操作通过 `BackgroundTask` 下发到工作线程,主线程仅调度回调
- **每线程独占连接**:`MySqlThreadData::onStart()` 在工作线程启动时创建独立的 `MySql` 连接
- **实体级串行化**:`BufferedEntityTasks` 确保同一实体的多个写操作按序执行
- **RAII 事务**:每个 `MySqlBackgroundTask` 在工作线程中自动包裹 `MySqlTransaction`,失败自动回滚

### 5.3 MySqlDatabase 启动流程(startup,mysql_database.cpp:112-188)

#### 步骤 1:创建主连接(不锁定)

```cpp
pConnection_ = new MySqlLockedConnection( connectionInfo );
// TODO: Scalable DB, re-implement locking mechanism for DBApps
if (!pConnection_->connect( /*shouldLock*/ false )) return false;
```

注意:DBApp 启动时**不获取命名锁**(`shouldLock=false`),因为多个 DBApp 可能共享数据库(Scalable DB 场景)。锁定由 `lockDB()` 显式调用。

#### 步骤 2:校验存储引擎

`connection.checkTableEngines()`(`wrapper.cpp:594-639`):查询 `information_schema.tables` 找出非 InnoDB 表,自动 `ALTER TABLE ... ENGINE='InnoDB'`。引擎类型常量定义于 `wrapper.hpp:32`:`#define MYSQL_ENGINE_TYPE "InnoDB"`。

#### 步骤 3:表结构同步检查

```cpp
const bool shouldSyncTablesToDefs = config.mysql.syncTablesToDefs();
if (!isSpecialBigWorldTablesInSync( connection, ... ) ||
    !isEntityTablesInSync( connection, entityDefs ))
{
    bool isSynced = shouldSyncTablesToDefs ? syncTablesToDefs() : false;
    if (!isSynced) return false;
}
```

- `isSpecialBigWorldTablesInSync()`(`table_inspector.cpp:380-474`):检查 10 张系统表
- `isEntityTablesInSync()`(`table_inspector.cpp:362-373`):用 `TableValidator` 遍历所有实体类型的属性映射

#### 步骤 4:启动后台线程

```cpp
numConnections_ = config.mysql.numConnections();
this->startBackgroundThreads( connectionInfo );
```

`startBackgroundThreads()`(`mysql_database.cpp:191-199`)循环 `numConnections_` 次,每次调用 `bgTaskManager_.startThreads( "MySQL", 1, new MySqlThreadData( connectionInfo ) )`。每个线程组只含 1 个线程,各自持有独立的 `MySqlThreadData`。

#### 步骤 5:初始化实体类型映射

`entityTypeMappings_.init( entityDefs, connection )`(`entity_type_mappings.cpp:44-86`):遍历所有有效实体类型,为每个创建 `EntityTypeMapping` 对象(预编译所有 SQL 语句)。

### 5.4 表结构自动同步机制

#### 同步触发方式

`MySqlDatabase::syncTablesToDefs()`(`mysql_database.cpp:871-902`)**不直接执行同步**,而是 fork 一个子进程运行 `sync_db` 工具:

```cpp
TableSynchroniser tableSynchroniser;
if (!tableSynchroniser.run( dispatcher_ )) { ... }
```

`TableSynchroniser::run()`(`table_synchroniser.cpp:90-157`)流程:
1. 定位 `commands/sync_db` 可执行文件
2. `fork()` 子进程,`execvp()` 执行 `sync_db --run-from-dbapp`
3. 父进程注册 `ChildWaiter` 信号处理器,阻塞等待子进程结束
4. 通过 `WIFEXITED`/`WEXITSTATUS` 判断成功与否

#### 10 张 bigworld 系统表

`createSpecialBigWorldTables()`(`mysql_synchronise.cpp:266-349`)创建:

| 表名 | 列定义 | 用途 |
|------|--------|------|
| `bigworldInfo` | version INT, snapshotTime TIMESTAMP, isPasswordHashed BOOL | 数据库版本与密码哈希标志 |
| `bigworldEntityTypes` | typeID(自增), bigworldID, name | 实体类型名↔数据库内部ID映射 |
| `bigworldLogOns` | databaseID, typeID, objectID, ip, port, salt, shouldAutoLoad | 实体登录/邮箱位置记录 |
| `bigworldLogOnMapping` | logOnName, password, entityType, entityID | 账号→实体映射(计费) |
| `bigworldNewID` | id | 新ID分配计数器 |
| `bigworldUsedIDs` | id | 已回收待复用的ID池 |
| `bigworldGameTime` | time | 游戏时间 |
| `bigworldSpaces` | id | 空间ID列表 |
| `bigworldSpaceData` | id, spaceEntryID, entryKey, data | 空间数据条目 |
| `bigworldSecondaryDatabases` | ip, port, location | 二级数据库地址 |
| `bigworldEntityDefsChecksum` | checksum | 实体定义持久属性摘要 |

#### TableInspector 比对机制

`table_inspector.cpp:26-71` 的 `onVisitTable()` 是核心比对逻辑:

1. 用 `ColumnsCollector` 收集实体定义**要求**的列(通过 `PropertyMapping::visitParentColumns()`)
2. 用 `TableMetaData::getTableColumns()` 读取数据库**实际**的列(`mysql_list_fields` + `SHOW INDEX`)
3. 若实际列为空 → 调用 `onNeedNewTable()`(需新建表)
4. 否则调用 `classifyColumns()` 分类:
   - **新增列**:在 newColumns 中但不在 oldColumns 中
   - **废弃列**:在 oldColumns 中但不在 newColumns 中
   - **更新列**:列类型不匹配
   - **索引变更列**:索引类型不匹配

`TableValidator`(`table_inspector.cpp:143-160`)是只读版本,仅打印差异(用于 startup 检查);`TableInitialiser`(在 sync_db 中)是写入版本,实际执行 `CREATE TABLE`/`ALTER TABLE`。

### 5.5 类型映射体系

#### 类层次图

```
SafeReferenceCount
└─ PropertyMapping (基类, property_mapping.hpp:45)
   │  纯虚: fromStreamToDatabase / fromDatabaseToStream
   │       defaultToStream / visitParentColumns
   │  静态工厂: create()  ← 按 MetaDataType.name() 分发
   │
   ├─ NumMapping<T>            (num_mapping.hpp:18, 模板)
   │   └─ 用于 INT8/16/32/64, UINT8/16/32/64, FLOAT32/64, GameTime
   │
   ├─ StringLikeMapping        (string_like_mapping.hpp:13, 字符串族基类)
   │   │  纯虚: isBinary() / getColumnType()
   │   ├─ StringMapping         (string_mapping.hpp:12, isBinary=true)
   │   ├─ UnicodeStringMapping  (unicode_string_mapping.hpp:15, isBinary=false, UTF-8)
   │   ├─ BlobMapping           (blob_mapping.hpp:14, isBinary=true, base64)
   │   ├─ PythonMapping         (python_mapping.hpp:14, isBinary=true, pickle)
   │   └─ BlobbedSequenceMapping(blobbed_sequence_mapping.hpp:13, 序列整体序列化为BLOB)
   │
   ├─ CompositePropertyMapping (composite_property_mapping.hpp:13, 组合基类)
   │   │  管理 children_ 列表,转发所有操作
   │   ├─ ClassMapping          (class_mapping.hpp:16, CLASS/FIXED_DICT, hasProps标记null)
   │   └─ UserTypeMapping       (user_type_mapping.hpp:15, USER_TYPE, 通过PyUserTypeBinder脚本绑定)
   │
   ├─ SequenceMapping          (sequence_mapping.hpp:17, 多继承 PropertyMapping+TableProvider)
   │   └─ ARRAY/TUPLE 映射到独立子表,通过 parentID 关联
   │
   ├─ VectorMapping<Vec,DIM>   (vector_mapping.hpp:17, 模板)
   │   └─ VECTOR2/3/4 拆为多个 FLOAT 列(vm_0, vm_1, ...)
   │
   ├─ UniqueIDMapping          (unique_id_mapping.hpp:17)
   │   └─ PATROL_PATH,存为 BINARY(16) CHAR
   │   └─ UDORefMapping         (udo_ref_mapping.hpp:12, UDO_REF)
   │
   └─ TimestampMapping         (timestamp_mapping.hpp:13)
       └─ 特殊:shouldIgnore=true,不参与流读写,仅列定义 ON UPDATE CURRENT_TIMESTAMP

TableProvider (接口, table.hpp:16)
└─ EntityMapping              (entity_mapping.hpp:17, 实体主表 tbl_<entityName>)
   └─ EntityTypeMapping       (entity_type_mapping.hpp:29, 含所有SQL操作)
   └─ SequenceMapping         (序列子表,同时是PropertyMapping)
```

#### PropertyMapping::create() 工厂分发

`property_mapping.cpp:132-336` 是核心工厂方法,按 `MetaDataType::name()` 字符串分发:

| MetaDataType 名 | 创建的映射类 | 备注 |
|----------------|-------------|------|
| SequenceDataType(ARRAY/TUPLE) | `SequenceMapping` 或 `BlobbedSequenceMapping` | dbLen>0 时用 Blob 版本 |
| FixedDictDataType | `ClassMapping` | FIXED_DICT |
| ClassDataType | `ClassMapping` | CLASS |
| UserDataType | `UserTypeMapping::create()` | 调用 Python `bindSectionToDB` |
| UINT8/16/32/64, INT8/16/32/64 | `NumMapping<T>` | 按 C 类型模板实例化 |
| FLOAT32 | `NumMapping<float>` | |
| FLOAT64 | `NumMapping<double>` | |
| VECTOR2/3/4 | `VectorMapping<Vec,DIM>` | 不可索引 |
| STRING | `StringMapping` | 可索引 |
| UNICODE_STRING | `UnicodeStringMapping` | 可索引,UTF-8 |
| PYTHON | `PythonMapping` | 不可索引 |
| BLOB | `BlobMapping` | 可索引 |
| PATROL_PATH | `UniqueIDMapping` | 不可索引 |
| UDO_REF | `UDORefMapping` | 不可索引 |

注意:**索引属性**(`isIndexed=true`)只能使用简单类型(Num/String/UnicodeString/Blob),复合类型在索引时返回 NULL 并报错。

#### 各种 PropertyMapping 对应表

| 映射类 | MySQL 列类型 | 用途 | 列名前缀 |
|--------|-------------|------|---------|
| `NumMapping<uint8>` | TINYINT UNSIGNED | UINT8 | sm_ |
| `NumMapping<int8>` | TINYINT | INT8 | sm_ |
| `NumMapping<uint16>` | SMALLINT UNSIGNED | UINT16 | sm_ |
| `NumMapping<int16>` | SMALLINT | INT16 | sm_ |
| `NumMapping<uint32>` | INT UNSIGNED | UINT32 | sm_ |
| `NumMapping<int32>` | INT | INT32 | sm_ |
| `NumMapping<uint64>` | BIGINT UNSIGNED | UINT64 | sm_ |
| `NumMapping<int64>` | BIGINT | INT64 | sm_ |
| `NumMapping<float>` | FLOAT | FLOAT32 | sm_ |
| `NumMapping<double>` | DOUBLE | FLOAT64 | sm_ |
| `NumMapping<GameTime>` | INT | gameTime(元属性) | 无前缀 |
| `StringMapping` | VAR_STRING(<256) 或 BLOB族(按长度) | STRING,isBinary=true | sm_ |
| `UnicodeStringMapping` | VAR_STRING(<256) 或 BLOB族 | UNICODE_STRING,isBinary=false,UTF-8 | sm_ |
| `BlobMapping` | BLOB族(按长度) | BLOB,isBinary=true | sm_ |
| `PythonMapping` | BLOB族 | PYTHON,pickle后存储 | sm_ |
| `BlobbedSequenceMapping` | BLOB族 | ARRAY/TUPLE(整体序列化) | sm_ |
| `VectorMapping<Vector2,2>` | 2× FLOAT | VECTOR2 | vm_0, vm_1 |
| `VectorMapping<Vector3,3>` | 3× FLOAT | VECTOR3 | vm_0, vm_1, vm_2 |
| `VectorMapping<Vector4,4>` | 4× FLOAT | VECTOR4 | vm_0..vm_3 |
| `UniqueIDMapping` | BINARY(16) CHAR | PATROL_PATH(UniqueID) | sm_ |
| `UDORefMapping` | BINARY(16) CHAR | UDO_REF | sm_ |
| `TimestampMapping` | TIMESTAMP ON UPDATE CURRENT_TIMESTAMP | timestamp(元属性) | 无前缀 |
| `ClassMapping`(allowNone) | TINYINT UNSIGNED DEFAULT 1 + 子列 | CLASS/FIXED_DICT,null标记 | fm_ |
| `SequenceMapping` | 子表(id,parentID,...) | ARRAY/TUPLE(子表存储) | tbl_ |
| `UserTypeMapping` | 由脚本绑定的子列 | USER_TYPE | 由PyUserTypeBinder决定 |

**BLOB 类型选择逻辑**(`type_traits.hpp:46-64`):按字节长度自动选择 TINYBLOB(<256)/BLOB(<65536)/MEDIUMBLOB(<16777216)/LONGBLOB(其他)。超过 16MB 会触发 `CRITICAL_MSG`。

#### 复杂类型持久化机制

**CLASS/FIXED_DICT(ClassMapping)**(`class_mapping.cpp:30-54`):
- 若 `allowNone_`,先读写一个 `hasProps`(TINYINT)标记位
- `hasProps=1` → 递归调用所有子属性的 `fromStreamToDatabase`
- `hasProps=0` → 用默认值填充,避免 NULL 列

**ARRAY/TUPLE(SequenceMapping)**(`sequence_mapping.cpp:157-294`):
- 映射到独立子表,通过 `parentID` 关联父实体
- 写入流程:
  1. `getNumElemsFromStrm()`:固定大小序列读 size,变长序列读 packed int
  2. `SELECT id FROM子表 WHERE parentID=? FOR UPDATE` 锁定现有行
  3. 更新现有行(update)、删除多余行(deleteExtraQuery)、插入新行(insertQuery)
  4. 子表行数上限 `MAX_NUM_ELEMENTS=100000`(`sequence_mapping.cpp:23`)

**ARRAY/TUPLE(BlobbedSequenceMapping)**(`blobbed_sequence_mapping.cpp`):
- 当 `dbLen>0` 时使用,整个序列序列化为单个 BLOB 列
- 构造时预生成默认值流

**USER_TYPE(UserTypeMapping)**(`user_type_mapping.cpp:90-156`):
- 通过 Python 脚本的 `bindSectionToDB` 方法动态绑定
- `PyUserTypeBinder`(`py_user_type_binder.hpp:29-77`)提供 `beginTable`/`bind`/`endTable` API,脚本可自定义子表结构

**PYTHON(PythonMapping)**:pickle 序列化后存为 BLOB

### 5.6 BackgroundTask 调度机制

#### 任务基类层次

```
BackgroundTask (cstdmf/bgtask_manager.hpp)
└─ MySqlBackgroundTask (background_task.hpp:13)
   │  实现 doBackgroundTask/doMainThreadTask
   │  纯虚: performBackgroundTask(MySql&)  ← 工作线程执行
   │  纯虚: performMainThreadTask(bool)    ← 主线程回调
   │  虚:   onRetry() / onException()
   └─ EntityTask (entity_task.hpp:20)
      │  持有 entityTypeMapping_, dbID_
      │  实现 performMainThreadTask → performEntityMainThreadTask + onFinished
      └─ EntityTaskWithID (entity_task_with_id.hpp:14)
         │  增加 entityID_
         ├─ PutEntityTask
         ├─ DelEntityTask
         └─ (其他带EntityID的任务)
      └─ GetEntityTask (直接继承EntityTask,无ID)
```

#### 工作线程执行流程

`MySqlBackgroundTask::doBackgroundTask()`(`background_task.cpp:28-102`):

```cpp
void MySqlBackgroundTask::doBackgroundTask( TaskManager & mgr,
        BackgroundTaskThread * pThread )
{
    MySqlThreadData & threadData =
        *static_cast< MySqlThreadData * >( pThread->pData().get() );

    bool retry;
    do {
        retry = false;
        try {
            succeeded_ = true;
            MySqlTransaction transaction( threadData.connection() );  // START TRANSACTION
            this->performBackgroundTask( threadData.connection() );    // 子类SQL
            transaction.commit();                                      // COMMIT
        }
        catch (DatabaseException & e) {
            if (e.isLostConnection()) {
                // 重连循环,每秒一次,直到成功
                while (!threadData.reconnect()) { timespec t={1,0}; nanosleep(&t,NULL); }
                retry = true;
                this->onRetry();
            }
            else if (e.shouldRetry()) {
                // 死锁/锁等待超时,重试
                retry = true;
                this->onRetry();
            }
            else {
                this->setFailure();
                this->onException( e );
            }
        }
    } while (retry);

    mgr.addMainThreadTask( this );  // 加入主线程回调队列
}
```

**关键特性**:
- **自动事务包裹**:每个任务自动在一个事务内执行,保证原子性
- **断线重连**:`isLostConnection()` 时无限重试重连
- **死锁重试**:`shouldRetry()`(ER_LOCK_DEADLOCK/ER_LOCK_WAIT_TIMEOUT)时重试
- **主线程回调**:完成后通过 `addMainThreadTask` 加入主线程队列

#### 主线程调度

`MySqlDatabase` 继承 `Mercury::FrequentTask`,每帧调用 `doTask()`:

```cpp
void MySqlDatabase::doTask()
{
    bgTaskManager_.tick();  // 处理已完成任务的主线程回调
}
```

#### 线程池大小

`numConnections_` 默认 5(`mysql_database.cpp:71`),由配置 `config.mysql.numConnections()` 覆盖。`hasUnrecoverableError()` 检查运行线程数是否等于 `numConnections_`,若不等说明有线程崩溃。

### 5.7 实体持久化流程

#### 写入流程(putEntity → PutEntityTask)

**主线程入口** `MySqlDatabase::putEntity()`(`mysql_database.cpp:440-466`):

```cpp
void MySqlDatabase::putEntity( const EntityKey & entityKey, EntityID entityID,
        BinaryIStream * pStream, const EntityMailBoxRef * pBaseMailbox,
        bool removeBaseMailbox, bool putExplicitID,
        UpdateAutoLoad updateAutoLoad, IPutEntityHandler & handler )
{
    const EntityTypeMapping * pEntityTypeMapping = entityTypeMappings_[ entityKey.typeID ];
    pBufferedEntityTasks_->addBackgroundTask(
        new PutEntityTask( pEntityTypeMapping, entityKey.dbID, entityID,
            pStream, pBaseMailbox, removeBaseMailbox, putExplicitID,
            updateAutoLoad, handler ) );
}
```

注意:`putEntity`/`delEntity`/`getEntity` 都走 `BufferedEntityTasks`(实体级串行)。

**PutEntityTask::performBackgroundTask**(`put_entity_task.cpp:60-124`)工作线程执行:

```
1. if (writeEntityData_):
   ├─ if (dbID_ != 0 && !putExplicitID_):
   │   └─ entityTypeMapping_.update(conn, dbID_, stream_, pGameTime_)  // 更新
   ├─ else if (!putExplicitID_):
   │   └─ dbID_ = entityTypeMapping_.insertNew(conn, stream_)          // 插入新
   └─ else:
       └─ dbID_ = entityTypeMapping_.insertExplicit(conn, dbID_, stream_)  // 显式ID
2. if (writeBaseMailbox_):
   └─ entityTypeMapping_.addLogOnRecord(conn, dbID_, baseMailbox_)
3. else if (removeBaseMailbox_):
   └─ entityTypeMapping_.removeLogOnRecord(conn, dbID_)
4. if (updateAutoLoad_ != UPDATE_AUTO_LOAD_RETAIN):
   └─ entityTypeMapping_.updateAutoLoad(conn, dbID_, ...)
```

**EntityTypeMapping::insertNew/update**(`entity_type_mapping.cpp:683-744`):
使用 `UpdateFromStreamVisitor`(`entity_type_mapping.cpp:546-635`)遍历所有持久化属性:

```cpp
// entity_type_mapping.cpp:641-669
bool EntityTypeMapping::visit( EntityTypeMappingVisitor & visitor,
       bool shouldVisitMetaProps ) const
{
    bool isOkay = entityDescription.visit(
        EntityDescription::BASE_DATA | CELL_DATA | ONLY_PERSISTENT_DATA, visitor );
    if (entityDescription.canBeOnCell()) {
        for (int i = 0; i < NUM_FIXED_CELL_PROPS && isOkay; ++i)
            isOkay &= visitor.visitPropertyMapping( *fixedCellProps_[i] );
        // position, direction, spaceID
    }
    if (shouldVisitMetaProps) {
        for (int i = 0; i < NUM_FIXED_META_PROPS && isOkay; ++i)
            isOkay &= visitor.visitPropertyMapping( *fixedMetaProps_[i] );
        // gameTime, timestamp
    }
}
```

每个 `PropertyMapping::fromStreamToDatabase()` 将流数据 `pushArg` 到 `QueryRunner`,最终拼装成完整 SQL 执行。对于 `SequenceMapping`,会触发子表的独立 INSERT/UPDATE/DELETE。

**主线程回调** `PutEntityTask::performEntityMainThreadTask`(`put_entity_task.cpp:130-133`):
```cpp
handler_.onPutEntityComplete( succeeded, dbID_ );
```

**重试处理** `PutEntityTask::onRetry()`(`put_entity_task.cpp:139-142`):`stream_.rewind()` 重置流位置,使重试时能重新读取数据。

#### 读取流程(getEntity → GetEntityTask)

**主线程入口** `MySqlDatabase::getEntity()`(`mysql_database.cpp:323-378`):

```
1. 查找 EntityTypeMapping
2. needsLookup = (entityKey.dbID == 0)
3. if (needsLookup):
   └─ 查缓存 identifierToDatabaseID_(entity_type_mapping.hpp:141-142)
      ├─ 命中:dbID = cachedID, needsLookup = false
4. 创建 GetEntityTask
5. if (needsLookup):
   └─ 创建 GetDbIDTask + GetDbIDHandler
      GetDbIDTask 完成后 → GetDbIDHandler::onGetDbIDComplete
      → cacheEntityKey + updateEntityKey + scheduleGetEntityTask
      (即:先查DBID,再调度真正的GetEntityTask)
6. else:
   └─ scheduleGetEntityTask(pGetEntityTask)  // 直接调度
```

**GetEntityTask::performBackgroundTask**(`get_entity_task.cpp:38-61`)工作线程执行:

```cpp
void GetEntityTask::performBackgroundTask( MySql & conn )
{
    bool isOkay = true;
    MF_ASSERT( entityKey_.dbID != 0);
    if (pStream_ != NULL) {
        isOkay = entityTypeMapping_.getStreamByID( conn, entityKey_.dbID, threadStream_ );
    }
    if (isOkay && shouldGetBaseEntityLocation_) {
        hasBaseLocation_ = entityTypeMapping_.getLogOnRecord( conn,
                            entityKey_.dbID, baseEntityLocation_ );
    }
    if (!isOkay) this->setFailure();
}
```

`EntityTypeMapping::getStreamByID` → `getStreamFromDBRow()`(`entity_type_mapping.cpp:474-495`):
```cpp
DatabaseID EntityTypeMapping::getStreamFromDBRow( MySql & connection,
        ResultSet & resultSet, BinaryOStream & strm ) const
{
    ResultRow resultRow;
    if (!resultRow.fetchNextFrom( resultSet )) return 0;
    ResultStream resultStream( resultRow );
    GetFromDBVisitor visitor( connection, *this, resultStream, strm );
    if (!this->visit( visitor, /*shouldVisitMetaProps:*/false )) return 0;
    return visitor.databaseID();
}
```

`GetFromDBVisitor`(`entity_type_mapping.cpp:89-120`)先从结果流读 `dbID_`,然后遍历每个属性调用 `fromDatabaseToStream()`。注意:**不读取元属性**(gameTime/timestamp),只读取业务属性 + 固定 cell 属性。

**主线程回调** `GetEntityTask::performEntityMainThreadTask`(`get_entity_task.cpp:67-77`):
```cpp
void GetEntityTask::performEntityMainThreadTask( bool succeeded )
{
    if (pStream_ != NULL) {
        pStream_->transfer( threadStream_, threadStream_.size() );
        // 将线程私有流数据合并回主线程结果流
    }
    handler_.onGetEntityComplete( succeeded, entityKey_,
        hasBaseLocation_ ? &baseEntityLocation_ : NULL );
}
```

### 5.8 事务和锁机制

#### Transaction RAII 类

`MySqlTransaction`(`transaction.hpp:14-31`,`transaction.cpp:15-71`):

```cpp
MySqlTransaction::MySqlTransaction( MySql& sql ) : sql_( sql ), committed_( false )
{
    sql_.execute( "START TRANSACTION" );
    sql_.inTransaction( true );  // 标记连接在事务中(影响重连逻辑)
}

MySqlTransaction::~MySqlTransaction()
{
    if (!committed_ && !sql_.hasLostConnection()) {
        try { sql_.execute( "ROLLBACK" ); }
        catch (DatabaseException & e) { if (e.isLostConnection()) sql_.hasLostConnection(true); }
    }
    sql_.inTransaction( false );
}

bool MySqlTransaction::shouldRetry() const {
    return (sql_.getLastErrorNum() == ER_LOCK_DEADLOCK);
}

void MySqlTransaction::commit() {
    MF_ASSERT( !committed_ );
    sql_.execute( "COMMIT" );
    committed_ = true;
}
```

**关键设计**:析构时若未 commit 则自动 ROLLBACK,保证异常安全。`shouldRetry()` 仅对死锁返回 true。

#### NamedLock 实现 lockDB/unlockDB

`MySQL::NamedLock`(`named_lock.hpp:18-33`,`named_lock.cpp:30-141`)基于 MySQL 的 `GET_LOCK`/`RELEASE_LOCK` 函数:

```cpp
bool obtainNamedLock( MySql & connection, const BW::string & lockName )
{
    const Query query( "SELECT GET_LOCK( ?, 0 )" );  // 超时0,非阻塞
    ResultSet resultSet;
    query.execute( connection, lockName, &resultSet );
    int result = 0;
    resultSet.getResult( result );
    return wasLockObtained = result;  // 1=成功,0=超时,NULL=错误
}

bool releaseNamedLock( MySql & connection, const BW::string & lockName )
{
    const Query query( "SELECT RELEASE_LOCK( ? )" );
    query.execute( connection, lockName, NULL );
    return true;
}
```

**锁名生成**(`connection_info.hpp:34-40`):
```cpp
BW::string generateLockName() const
{
    BW::string lockName( "BigWorld ");
    lockName += database;  // 如 "BigWorld bigworld"
    return lockName;
}
```

#### LockedConnection

`MySqlLockedConnection`(`locked_connection.hpp:20-48`)组合了 `MySql*`(连接)和 `MySQL::NamedLock`(命名锁):
- `connect(shouldLock)`(`locked_connection.cpp:89-133`):建立连接,可选获取锁
- `connectAndLockWithRetry(numRetries)`(`locked_connection.cpp:49-68`):重试获取锁,每次间隔 1 秒
- 析构时自动 unlock + close

`MySqlDatabase::startup()` 中 `connect(false)` 不加锁,因为 Scalable DB 场景下多 DBApp 共享数据库。锁用于工具进程(sync_db)或单 DBApp 模式。

#### BufferedEntityTasks 实体级串行锁

`BufferedEntityTasks`(`buffered_entity_tasks.hpp:22-65`)确保同一实体的多个操作按序执行:

**数据结构**:
- `tasks_`:`multimap<EntityKey, EntityTaskPtr>`,按 dbID 缓冲
- `priorToDBIDTasks_`:`multimap<EntityID, EntityTaskPtr>`,新实体(dbID未知)按 entityID 缓冲
- `newEntityMap_`:`map<EntityID, DatabaseID>`,记录新实体的 entityID→dbID 映射

**锁机制**(`buffered_entity_tasks.cpp:83-115` `grabLock`):
```cpp
bool BufferedEntityTasks::grabLock( const EntityTaskPtr & pTask )
{
    DatabaseID dbID = pTask->dbID();
    // 若 dbID==PENDING,查 newEntityMap_ 找已分配的 dbID
    if (dbID == PENDING_DATABASE_ID) {
        NewEntityMap::const_iterator iter = newEntityMap_.find( entityID );
        if (iter != newEntityMap_.end()) { dbID = iter->second; pTask->dbID( dbID ); }
    }
    if (isValidDBID( dbID )) {
        return grabLockT( tasks_, pTask->entityKey() );  // 在 tasks_ 中插入 NULL 占位
    }
    if (entityID != 0) {
        return grabLockT( priorToDBIDTasks_, entityID );  // 在 priorToDBIDTasks_ 中占位
    }
    return true;  // 无 dbID 和 entityID 的任务直接执行
}
```

`grabLockT`(`buffered_entity_tasks.cpp:25-40`):若 map 中已有该 key 的条目,返回 false(已被锁);否则插入一个 `(id, NULL)` 占位条目作为锁。

**完成回调**(`buffered_entity_tasks.cpp:164-182` `onFinished`):
```cpp
void BufferedEntityTasks::onFinished( const EntityTaskPtr & pTask )
{
    if (!this->playNextTask( tasks_, entityKey )) {
        if (entityKey.dbID != 0) {
            this->onFinishedNewEntity( pTask );  // 新实体首次写入完成
        } else {
            this->playNextTask( priorToDBIDTasks_, pTask->entityID() );
        }
    }
}
```

`playNextTask`(`buffered_entity_tasks.cpp:281-327`):移除 NULL 占位(释放锁),若有缓冲任务则调度下一个。`onFinishedNewEntity`(`buffered_entity_tasks.cpp:189-241`)处理新实体首次写入:记录 entityID→dbID 映射,将 `priorToDBIDTasks_` 中缓冲的任务迁移到 `tasks_`。

### 5.9 二级数据库机制

#### 表结构

```sql
CREATE TABLE bigworldSecondaryDatabases (
    ip INT UNSIGNED NOT NULL,
    port SMALLINT UNSIGNED NOT NULL,
    location BLOB NOT NULL,
    INDEX addr (ip, port)
) ENGINE=InnoDB
```

#### 操作实现

**addSecondaryDB**(`mysql_database.cpp:772-775`):
```cpp
bgTaskManager_.addBackgroundTask( new AddSecondaryDBEntryTask( entry ) );
// INSERT INTO bigworldSecondaryDatabases (ip, port, location) VALUES (?,?,?)
```

**getSecondaryDBs**(`mysql_database.cpp:792-795`):`GetSecondaryDBsTask` 读取所有条目。

**updateSecondaryDBs**(`mysql_database.cpp:781-786`):`UpdateSecondaryDBsTask` 先查询出不在新地址列表中的条目(将删除的),再 DELETE,最后回调返回被删除的条目。WHERE 子句使用 `(ip,port) NOT IN (...)` 语法。

**numSecondaryDBs/clearSecondaryDBs**(`mysql_database.cpp:801-846`):同步操作,在主连接上执行。`clearSecondaryDBs` 带重试逻辑。

#### shouldConsolidate 标志

`shouldConsolidate_` 默认 true。此标志供 DBApp 上层决定是否触发合并流程。`onConsolidateProcessEnd()` 失败时会调用 `pDatabase_->shouldConsolidate(false)` 防止重试。

### 5.10 其他持久化功能

#### 空间数据持久化

**writeSpaceData**(`mysql_database.cpp:520-524`):`WriteSpaceDataTask` 先删除 `bigworldSpaces` 和 `bigworldSpaceData` 全表,再从流读取并插入。

**getSpacesData**(`mysql_database.cpp:584-640`):同步操作,先通过 `getAutoLoadSpacesFromEntities()`(`mysql_database.cpp:533-578`)查询所有需自动加载的实体类型及其 spaceID(`SELECT DISTINCT sm_spaceID FROM tbl_<type> ...`),再按 spaceID 查询 `bigworldSpaceData`。

#### ID 管理(getIDs / putIDs)

**GetIDsTask**(`get_ids_task.cpp:40-117`):
1. `getUsedIDs()`:`SELECT id FROM bigworldUsedIDs LIMIT ? FOR UPDATE`,从回收池取,取完 `DELETE`
2. 不足部分 `getNewIDs()`:`SELECT id FROM bigworldNewID LIMIT 1 FOR UPDATE` + `UPDATE bigworldNewID SET id=id+?`,分配连续新ID
3. ID 达到 `FIRST_LOCAL_ENTITY_ID` 时回绕到 `FIRST_ENTITY_ID`

**PutIDsTask**(`put_ids_task.cpp:25-38`):逐个 `INSERT INTO bigworldUsedIDs (id) VALUES (?)`。

#### BaseAppMgr 初始化数据

`GetBaseAppMgrInitDataTask`(`get_base_app_mgr_init_data_task.cpp:24-36`):仅读取 `bigworldGameTime` 表的 `time` 字段,通过 `onGetBaseAppMgrInitDataComplete(gameTime)` 回调。

#### setGameTime

`SetGameTimeTask`(`set_game_time_task.cpp:22-27`):`UPDATE bigworldGameTime SET time=?`。

#### executeRawCommand

`ExecuteRawCommandTask`(`execute_raw_command_task.cpp:31-78`):执行任意 SQL,支持多语句(`CLIENT_MULTI_STATEMENTS`)。结果通过 `conn.nextResult()` 循环处理,支持结果集和 affectedRows 两种返回。`onException` 将错误信息写入响应流。

#### autoLoadEntities

`MySqlDatabase::autoLoadEntities()`(`mysql_database.cpp:646-694`):同步操作:
1. `DELETE FROM bigworldLogOns WHERE NOT shouldAutoLoad` 清除非自动加载记录
2. `SELECT logOn.databaseID, entityType.bigworldID FROM bigworldLogOns ... WHERE shouldAutoLoad` 查询
3. 调用 `autoLoader.addEntity(bwTypeID, dbID)` 逐个注册
4. `UPDATE bigworldLogOns SET ip = 0, port = 0` 重置所有邮箱位置

#### remapEntityMailboxes

`MySqlDatabase::remapEntityMailboxes()`(`mysql_database.cpp:720-766`):BaseApp 死亡时重映射邮箱。同步操作,构造 `UPDATE bigworldLogOns SET ip=?, port=? WHERE ip=旧 AND port=旧 AND hash条件` 语句。

#### lookUpEntities

`LookUpEntitiesTask`(`look_up_entities_task.cpp:40-56`)调用 `EntityTypeMapping::lookUpEntitiesByProperties()`(`entity_type_mapping.cpp:378-467`):
- 动态构建 SQL:`SELECT e.id, lo.objectID, lo.ip, lo.port, lo.salt FROM tbl_<type> AS e LEFT JOIN bigworldLogOns AS lo ON ...`
- 支持 `propertyQueries`(WHERE sm_<prop>=?)、`filter`(ONLINE/OFFLINE)、`sortProperty`+`limit`/`offset`
- 限制:查询属性不能有子表(`hasTable()` 检查)

### 5.11 错误处理体系

#### DatabaseException 层次

`DatabaseException`(`database_exception.hpp:15-29`,`database_exception.cpp:16-52`)继承 `std::exception`,封装 MySQL 错误码:

```cpp
class DatabaseException : public std::exception {
    BW::string errStr_;       // mysql_error()
    unsigned int errNum_;     // mysql_errno()
    bool shouldRetry() const;  // ER_LOCK_DEADLOCK || ER_LOCK_WAIT_TIMEOUT
    bool isLostConnection() const;  // CR_SERVER_GONE_ERROR || CR_SERVER_LOST || ...
};
```

#### 错误分类与处理

| 错误类型 | 错误码 | 处理策略 |
|---------|--------|---------|
| 死锁 | ER_LOCK_DEADLOCK | `shouldRetry()=true`,任务重试 |
| 锁等待超时 | ER_LOCK_WAIT_TIMEOUT | `shouldRetry()=true`,任务重试 |
| 服务器断开 | CR_SERVER_GONE_ERROR | `isLostConnection()=true`,重连后重试 |
| 连接丢失 | CR_SERVER_LOST | `isLostConnection()=true`,重连后重试 |
| 连接错误 | CR_CONNECTION_ERROR/CR_CONN_HOST_ERROR | `isLostConnection()=true`,重连后重试 |
| 其他 | - | `setFailure()` + `onException()`,任务失败 |

#### 重连机制

`MySql::realQuery()`(`wrapper.cpp:295-340`):非事务中遇到 `CR_SERVER_LOST`/`CR_SERVER_GONE_ERROR` 时自动重连重试一次。

`MySqlBackgroundTask::doBackgroundTask()`(`background_task.cpp:49-78`):事务中(已 set inTransaction_)断线时,进入无限重连循环(每秒一次),重连成功后重试整个任务。这保证长时间网络故障后任务能恢复。

`MySql::throwError()`(`wrapper.cpp:278-288`):抛出前设置 `hasLostConnection_` 标志,`MySqlTransaction` 析构时检查此标志避免在断连上 ROLLBACK。

---

## 六、XML 数据存储实现

`lib/db_storage_xml/` 仅包含 4 个源文件,是 BigWorld 数据存储的**演示/开发实现**。

### 6.1 文件结构

| 文件 | 职责 |
|------|------|
| `xml_database.hpp/.cpp` | XMLDatabase 主类,实现 IDatabase |
| `xml_billing_system.hpp/.cpp` | XMLBillingSystem 计费系统 |

### 6.2 XMLDatabase 关键特性

```cpp
class XMLDatabase : public IDatabase, public TimerHandler
{
    // ...
    virtual bool supportsMultipleDBApps() const { return false; }  // 不支持多 DBApp
    virtual bool shouldConsolidate() const { return false; }       // 不支持合并
    virtual bool lockDB() { return true; }                         // 空实现
    virtual bool unlockDB() { return true; }                       // 空实现
    virtual void lookUpEntities(...) { ERROR_MSG("Not implemented"); }  // 未实现
};
```

### 6.3 存储模型

- **存储介质**:XML 文件(DataSection)
- **线程模型**:单线程,所有操作同步阻塞
- **数据结构**:`idToData_ map` + `nameToIdMaps_`(与 MySqlDatabase 类似但纯内存)
- **ID 管理**:内存 `spareIDs_` + `nextID_`
- **计费系统**:`XMLBillingSystem`(内存 LogonMap)
- **密码安全**:明文比较

### 6.4 适用场景

- **开发/测试环境**:单机,快速原型,无需数据库配置
- **演示/评估**:由 `XMLEngineCreator` 在 `isProduction=true` 时主动 ERROR_MSG 警告

---

## 七、MySQL 与 XML 实现对比

| 维度 | MySqlDatabase | XMLDatabase |
|------|---------------|-------------|
| **存储介质** | MySQL 关系数据库 | XML 文件(DataSection) |
| **线程模型** | 多线程(默认5工作线程),主线程非阻塞 | 单线程,操作同步阻塞 |
| **并发支持** | 支持多 DBApp(supportsMultipleDBApps 默认实现) | `supportsMultipleDBApps()=false` |
| **锁机制** | GET_LOCK 命名锁,支持 lockDB/unlockDB | 空实现返回 true |
| **lookUpEntities** | 完整实现(SQL 查询) | **未实现**,直接报错 |
| **事务** | MySqlTransaction RAII,支持回滚 | 无事务,定时 archive/save |
| **二级数据库** | 完整支持 | `shouldConsolidate()=false` |
| **持久化方式** | 流式→SQL(属性映射) | DataSection 序列化 |
| **表结构同步** | sync_db 自动同步 | 无(直接存 XML) |
| **性能** | 高(索引、连接池) | 低(全文件读写) |
| **数据结构** | idToData_ map + nameToIdMaps_ | 同左 |
| **ID 管理** | bigworldNewID/bigworldUsedIDs 表 | 内存 spareIDs_ + nextID_ |
| **计费系统** | MySqlBillingSystem(SQL 查询 bigworldLogOnMapping) | XMLBillingSystem(内存 LogonMap) |
| **空间数据** | bigworldSpaces/bigworldSpaceData 表 | DataSection 存储 |
| **密码安全** | 支持 MD5 哈希(isPasswordHashed) | 明文比较 |
| **适用场景** | 生产环境,多 DBApp 集群 | 开发/测试环境,单机 |

---

## 八、关键文件路径速查

### 8.1 应用层

| 文件 | 关键内容 |
|------|---------|
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\dbappmgr\main.cpp` | DBAppMgr 入口 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\dbappmgr\dbappmgr.cpp/.hpp` | DBAppMgr 主类 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\dbappmgr\dbapp.cpp/.hpp` | DBApp 视图类 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\dbapp\main.cpp` | DBApp 入口 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\dbapp\dbapp.cpp/.hpp/.ipp` | DBApp 主类(2830+ 行) |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\dbapp\dbapp_config.cpp/.hpp` | DBApp 配置 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\dbapp\add_to_dbappmgr_helper.hpp` | 异步注册辅助 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\dbapp\dbappmgr_gateway.cpp/.hpp` | DBAppMgr 通道网关 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\dbapp\consolidator.cpp/.hpp` | 数据合并器 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\dbapp\login_handler.cpp/.hpp` | 登录处理器 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\dbapp\custom.cpp/.hpp` | 自定义扩展点 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\dbapp\standard_billing_system.cpp` | Standard BillingSystem |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\dbapp\bwauth_billing_system.cpp/.hpp` | BWAuth BillingSystem |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\dbapp\custom_billing_system.cpp/.hpp` | Custom BillingSystem |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\dbapp\py_billing_system.cpp/.hpp` | Python BillingSystem |

### 8.2 扩展层

| 文件 | 关键内容 |
|------|---------|
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\dbapp_extensions\bwengine_mysql\mysql_engine_creator.cpp` | MySQL EngineCreator |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\dbapp_extensions\bwengine_xml\xml_engine_creator.cpp` | XML EngineCreator |

### 8.3 抽象层

| 文件 | 关键内容 |
|------|---------|
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\cstdmf\intrusive_object.hpp` | IntrusiveObject 模板 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage\idatabase.hpp` | IDatabase 接口 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage\db_engine_creator.cpp/.hpp` | DatabaseEngineCreator |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage\billing_system.cpp/.hpp` | BillingSystem 基类 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage\billing_system_creator.cpp/.hpp` | BillingSystemCreator |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage\entity_key.hpp` | EntityKey/EntityDBKey |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage\db_status.hpp/.cpp` | DBStatus 状态枚举 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db\db_config.cpp/.hpp` | DBConfig 配置 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db\dbappmgr_interface.hpp` | DBAppMgrInterface 消息 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db\dbapp_interface.hpp` | DBAppInterface 消息 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db\db_hash_schemes.hpp` | DBAppIDBuckets 哈希方案 |

### 8.4 MySQL 实现层

#### 核心数据库类

| 文件 | 关键内容 |
|------|---------|
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\mysql_database.hpp/.cpp` | MySqlDatabase(IDatabase 实现) |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\mysql_database_creation.cpp/.hpp` | createMySqlDatabase 工厂 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\wrapper.hpp/.cpp` | MySql C API 封装 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\connection_info.hpp` | ConnectionInfo + generateLockName |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\locked_connection.hpp/.cpp` | MySqlLockedConnection |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\db_config.hpp/.cpp` | DBConfig::Server |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\versions.hpp` | DBAPP_CURRENT_VERSION=9 |

#### 表与元数据

| 文件 | 关键内容 |
|------|---------|
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\table.hpp/.cpp` | TableProvider/TableVisitor |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\table_meta_data.hpp/.cpp` | ColumnInfo/MySqlTableMetadata |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\table_inspector.hpp/.cpp` | TableInspector/TableValidator |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\table_synchroniser.hpp/.cpp` | TableSynchroniser(fork sync_db) |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\bw_meta_data.hpp/.cpp` | BigWorldMetaData |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\column_type.hpp/.cpp` | ColumnType/ColumnIndexType |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\namer.hpp/.cpp` | Namer(表名/列名生成) |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\constants.hpp` | 表名前缀"tbl"、列名常量 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\type_traits.hpp` | MySqlTypeTraits |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\tools\sync_db\mysql_synchronise.cpp` | 系统表 CREATE TABLE |

#### 查询与事务

| 文件 | 关键内容 |
|------|---------|
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\query.hpp/.cpp` | Query(?占位符) |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\query_runner.hpp/.cpp` | QueryRunner |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\result_set.hpp/.cpp` | ResultSet/ResultRow |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\transaction.hpp/.cpp` | MySqlTransaction RAII |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\named_lock.hpp/.cpp` | NamedLock |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\database_exception.hpp/.cpp` | DatabaseException |

#### 类型映射

| 文件 | 关键内容 |
|------|---------|
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\mappings\property_mapping.hpp/.cpp` | PropertyMapping 基类 + create() 工厂 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\mappings\entity_type_mapping.hpp/.cpp` | EntityTypeMapping |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\mappings\entity_type_mappings.hpp/.cpp` | EntityTypeMappings 集合 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\mappings\entity_mapping.hpp/.cpp` | EntityMapping |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\mappings\class_mapping.hpp/.cpp` | ClassMapping |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\mappings\sequence_mapping.hpp/.cpp` | SequenceMapping |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\mappings\blobbed_sequence_mapping.hpp/.cpp` | BlobbedSequenceMapping |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\mappings\string_like_mapping.hpp/.cpp` | StringLikeMapping 基类 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\mappings\string_mapping.hpp/.cpp` | StringMapping |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\mappings\unicode_string_mapping.hpp/.cpp` | UnicodeStringMapping |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\mappings\blob_mapping.hpp/.cpp` | BlobMapping |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\mappings\python_mapping.hpp` | PythonMapping |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\mappings\num_mapping.hpp` | NumMapping<T> |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\mappings\vector_mapping.hpp` | VectorMapping<Vec,DIM> |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\mappings\timestamp_mapping.hpp/.cpp` | TimestampMapping |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\mappings\unique_id_mapping.hpp/.cpp` | UniqueIDMapping |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\mappings\udo_ref_mapping.hpp` | UDORefMapping |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\mappings\user_type_mapping.hpp/.cpp` | UserTypeMapping |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\mappings\composite_property_mapping.hpp/.cpp` | CompositePropertyMapping |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\mappings\property_mappings_per_type.hpp/.cpp` | PropertyMappingsPerType |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\mappings\stream_to_query_helper.hpp` | StreamToQueryHelper |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\mappings\result_to_stream_helper.hpp` | ResultToStreamHelper |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\py_user_type_binder.hpp/.cpp` | PyUserTypeBinder |

#### 后台任务系统

| 文件 | 关键内容 |
|------|---------|
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\tasks\background_task.hpp/.cpp` | MySqlBackgroundTask 基类 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\tasks\entity_task.hpp/.cpp` | EntityTask 基类 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\tasks\entity_task_with_id.hpp/.cpp` | EntityTaskWithID |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\tasks\put_entity_task.hpp/.cpp` | PutEntityTask |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\tasks\get_entity_task.hpp/.cpp` | GetEntityTask |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\tasks\del_entity_task.hpp/.cpp` | DelEntityTask |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\tasks\get_dbid_task.hpp/.cpp` | GetDbIDTask |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\tasks\look_up_entities_task.hpp/.cpp` | LookUpEntitiesTask |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\tasks\get_ids_task.hpp/.cpp` | GetIDsTask |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\tasks\put_ids_task.hpp/.cpp` | PutIDsTask |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\tasks\set_game_time_task.hpp/.cpp` | SetGameTimeTask |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\tasks\get_base_app_mgr_init_data_task.hpp/.cpp` | GetBaseAppMgrInitDataTask |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\tasks\write_space_data_task.hpp/.cpp` | WriteSpaceDataTask |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\tasks\execute_raw_command_task.hpp/.cpp` | ExecuteRawCommandTask |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\tasks\add_secondary_db_entry_task.hpp/.cpp` | AddSecondaryDBEntryTask |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\tasks\get_secondary_dbs_task.hpp/.cpp` | GetSecondaryDBsTask |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\tasks\update_secondary_dbs_task.hpp/.cpp` | UpdateSecondaryDBsTask |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\tasks\get_entity_key_for_account_task.hpp/.cpp` | GetEntityKeyForAccountTask |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\tasks\set_entity_key_for_account_task.hpp/.cpp` | SetEntityKeyForAccountTask |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\buffered_entity_tasks.hpp/.cpp` | BufferedEntityTasks |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\thread_data.hpp/.cpp` | MySqlThreadData |

#### 计费与工具

| 文件 | 关键内容 |
|------|---------|
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\mysql_billing_system.hpp/.cpp` | MySqlBillingSystem |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\database_tool_app.hpp/.cpp` | DatabaseToolApp(sync_db 等工具基类) |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_mysql\utils.hpp/.cpp` | SQL 语句构造工具 |

### 8.5 XML 实现层

| 文件 | 关键内容 |
|------|---------|
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_xml\xml_database.hpp/.cpp` | XMLDatabase |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db_storage_xml\xml_billing_system.hpp/.cpp` | XMLBillingSystem |

---

## 九、设计亮点与注意事项

### 9.1 设计亮点

#### DBAppMgr 层面

1. **Rendezvous 哈希做分片**:DBApp 集合变更时,只有映射到被删 DBApp 的 DBID 需要迁移,最小化数据搬动
2. **隐式 Alpha 选举**:`dbAppAlpha() = dbApps_.smallest().second`,无显式选举协议、无状态字段,所有进程用同样规则得到同一结果
3. **回复即哈希合并**:`DBApp::updateDBAppHash` 用 `pendingReplyID_` 区分"addDBApp 首次回复"与"后续哈希刷新",一次往返完成 id 分配 + 哈希下发
4. **批量合并回复**:非 Alpha DBApp 注册后等 1 秒,合并窗口内多个 DBApp 到一次广播
5. **三态启动状态机** + **Alpha 死亡兜底**:INDETERMINATE 态精确表达"Alpha 正在做一次性初始化"

#### DBApp 层面

1. **异步初始化架构**:通过 `AddToDBAppMgrHelper` + 回调链将原本阻塞的初始化拆解为事件驱动
2. **InitStateFlags 位掩码校验**:`onInitCompleted()` 通过 `NON_ALPHA_MASK` 断言所有必需步骤完成
3. **Alpha/非 Alpha 统一框架**:通过 `isAlpha()` 判定复用大部分代码,支持运行时 Alpha 提升
4. **邮箱重映射 5 秒窗口**:在 BaseApp 死亡后提供宽限期,拦截并修正仍在途的旧地址读写
5. **Consolidator 子进程隔离**:数据合并通过子进程执行,主进程通过 `IChildProcess` 接口监听完成事件
6. **过载容忍机制**:不是瞬时拒绝,而是要求持续过载超过 `overloadTolerancePeriod` 才拒绝登录
7. **Handler 模式解耦**:每个消息处理器独立成类,自管理生命周期

#### dbapp_extensions 层面

1. **零样板注册**:IntrusiveObject + 匿名命名空间静态对象,新增引擎只需一个 `.cpp`,无需修改任何中央注册表
2. **运行期可插拔 + 链接期自动注册的混合**:dlopen 决定"哪些引擎被部署",IntrusiveObject 决定"被部署的引擎如何被发现"
3. **O(1) 删除的侵入式容器**:`swap-with-last + pop_back` 配合 `containerPos_` 缓存
4. **XML 生产环境告警**:XMLEngineCreator 在 `isProduction` 时主动 ERROR_MSG
5. **BillingSystem 多层回退**:`StandardBillingSystemCreator` 形成 "Python Personality → IDatabase::createBillingSystem()" 的回退链
6. **配置演进检测**:`DBConfigBlock` 通过 `addObsoleteName` 标记旧选项

#### MySQL 实现层面

1. **主线程零阻塞**:所有 SQL 操作异步化,主线程仅做调度和回调
2. **实体级串行锁(BufferedEntityTasks)**:巧妙使用 `multimap` 的 NULL 占位实现轻量级锁,既保证同实体操作有序,又允许不同实体并行
3. **流式持久化**:实体数据以 `BinaryIStream`/`BinaryOStream` 形式在主线程和工作线程间传递,`PropertyMapping` 负责流↔SQL 转换,完全解耦实体内存表示与存储格式
4. **Visitor 模式贯穿始终**:`TableVisitor`/`ColumnVisitor`/`IDataDescriptionVisitor`/`EntityTypeMappingVisitor` 多种 Visitor 协同工作
5. **自动事务+智能重试**:`MySqlBackgroundTask` 自动包裹事务,区分死锁(重试)、断连(重连重试)、致命错误(失败)三种情况
6. **表结构自愈**:startup 时检测表结构差异,自动 fork sync_db 修复,支持在线 schema 演进
7. **类型映射可扩展**:USER_TYPE 通过 Python 脚本的 `bindSectionToDB` 方法动态绑定

### 9.2 注意事项

#### DBAppMgr

1. **无 DBApp 时的处理薄弱**:`handleDBAppDeath` 中若 `dbApps_.empty()` 仅 `ERROR_MSG`,注释明确 `TODO: Scalable DB: Should trigger a controlled shutdown here.`
2. **Alpha 在 auto-load 半途死亡的风险**:下一个 Alpha 会重新执行首次初始化,可能导致重复实体
3. **BaseAppMgr 同步阻塞调用**:init 中 `waitForReply` 阻塞等待 BaseAppMgr 响应

#### DBApp

1. **DBApp 时间不同步**:游戏逻辑不应依赖 DBApp 的 GameTime 精确性
2. **非 Alpha 的多 DBApp 校验**:XML 数据库不支持多 DBApp,非 Alpha 启动会失败
3. **二级 DB 文件清理风险**:`onUpdateSecondaryDBsComplete()` 若 `sendRemoveDBCmd` 失败,可能导致磁盘空间泄漏
4. **consolidation 失败后禁用重试**:数据可能未完全合并

#### dbapp_extensions

1. **遗留死代码**:`server/dbapp/mysql_engine_creator.cpp`(旧 API 签名)未被 `dbapp/CMakeLists.txt` 收录
2. **`type.empty()` 的隐式语义**:配置忘填 `<db/type>` 时,会取第一个注册的 Creator,而注册顺序取决于 dlopen 扫描目录的顺序
3. **XMLDatabase 不支持多 DBApp**:只能单进程使用
4. **`initGameSpecific` 是空钩子**:项目方若要深度定制,需直接改 dbapp 源码
5. **`RTLD_GLOBAL` 的符号污染**:扩展数量增多时需警惕符号冲突

#### MySQL 实现

1. **主连接同步操作风险**:`getSpacesData()`/`autoLoadEntities()`/`remapEntityMailboxes()` 等在主连接同步执行,可能阻塞主线程
2. **getIDs 的 FOR UPDATE 锁**:高并发 ID 分配可能成为瓶颈
3. **PutIDsTask 逐条插入**:未批量优化
4. **SequenceMapping 子表操作复杂**:大数组性能较差,元素上限 100000
5. **executeRawCommand 安全性**:直接执行原始 SQL,存在 SQL 注入风险(仅供管理工具)
6. **重连期间任务阻塞**:断连时工作线程进入无限重连循环,该线程上的后续任务会排队等待
7. **DBID 缓存一致性**:`identifierToDatabaseID_` 缓存无失效机制,依赖删除路径正确调用
8. **lookUpEntities 限制**:查询属性不能有子表,即无法按 ARRAY/CLASS 属性查询
9. **密码哈希不可逆**:只能从明文升级到 MD5,不能反向
10. **版本兼容性**:`DBAPP_CURRENT_VERSION=9`,`DBAPP_OLDEST_SUPPORTED_VERSION=1`

### 9.3 关键配置项速查

| 配置路径 | 默认值 | 说明 |
|---------|--------|------|
| `<db/type>` | `"xml"` | 数据库引擎类型 |
| `<db/mysql/numConnections>` | 5 | MySQL 工作线程数 |
| `<db/mysql/syncTablesToDefs>` | true | 启动时是否自动同步表结构 |
| `<db/mysql/maxSpaceDataSize>` | - | bigworldSpaceData.data 列的 BLOB 大小 |
| `<billingSystem/type>` | `"standard"` | 计费系统类型 |
| `<billingSystem/shouldAcceptUnknownUsers>` | false | 接受未知用户 |
| `<billingSystem/shouldRememberUnknownUsers>` | false | 记住未知用户 |
| `<billingSystem/authenticateViaBaseEntity>` | false | 由 base entity 认证 |
| `<billingSystem/entityTypeForUnknownUsers>` | `""` | 未知用户实体类型名 |
| `<billingSystem/isPasswordHashed>` | true | 是否启用密码 MD5 哈希 |
| `<production>/isProduction` | true | 生产环境标志 |

---

*本文档基于 BigWorld Engine 14.4.1 源码分析生成,涵盖 DBAppMgr、DBApp、dbapp_extensions、MySQL/XML 存储引擎的完整实现细节。所有行号引用均基于实际源码,可作为深入研究的索引基础。*
