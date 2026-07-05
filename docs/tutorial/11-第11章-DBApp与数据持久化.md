# 第11章 DBApp 与数据持久化

> 在前面几章里,我们谈过 BaseApp 把"玩家会话"留在内存里、CellApp 把"虚拟世界"切分到多个进程、CellAppMgr/BaseAppMgr 把进程的生命周期管起来。但只要服务器一断电,这一切都会消失。一个真正的 MMOG 必须回答两个问题:**"玩家下线了,他的等级、装备、好友列表存到哪儿?"**以及**"服务器重启后,这些数据怎么自动恢复回来?"**。BigWorld 的答案是 DBApp——一个用 C++ 写的、面向"持久化"而非"游戏逻辑"的进程。它有三大职责:实体持久化、二级数据库管理、登录认证。它还有一个有意思的"双引擎"设计:可以在 XML(开发用)和 MySQL(生产用)之间切换,而调用方一行代码都不用改。本章就带你走进这座"游戏世界的长期记忆"。

---

## 目录

- [11.1 DBApp 概述](#111-dbapp-概述)
- [11.2 双存储引擎架构](#112-双存储引擎架构)
- [11.3 实体持久化流程](#113-实体持久化流程)
- [11.4 二级数据库](#114-二级数据库)
- [11.5 登录认证](#115-登录认证)
- [11.6 快照机制](#116-快照机制)
- [11.7 核心 Handler 类](#117-核心-handler-类)
- [11.8 自动加载机制](#118-自动加载机制)
- [11.9 数据库同步工具](#119-数据库同步工具)
- [11.10 特色实现深度剖析](#1110-特色实现深度剖析)
- [11.11 本章小结](#1111-本章小结)

---

## 11.1 DBApp 概述

### 11.1.1 进程定位

如果用一句话向新手介绍 DBApp,最贴切的描述是:**"DBApp 是 BigWorld 服务器集群里唯一一个直接持有数据库连接、并对实体做长期持久化的进程"**。BaseApp 把玩家留在内存里,但内存不能持久;CellApp 把世界切分到多个进程,但每个 CellApp 一死自己负责的空间数据就丢了。DBApp 不参与"实时游戏循环",它只做一件事:**把"需要长期保存的状态"写到磁盘上,以及在合适的时候读回来**。

在 BigWorld 集群拓扑里,DBApp 处于数据平面的最底层:

```
                  客户端
                    │ (TCP)
                    ▼
              ┌───────────┐
              │ LoginApp  │  ← 只验账号,不存档
              └─────┬─────┘
                    │ Mercury
                    ▼
              ┌───────────┐         ┌──────────────┐
              │  BaseApp  │◀───────▶│   CellApp    │
              └─────┬─────┘         └──────────────┘
                    │ saveEntity / loadEntity
                    ▼
              ┌───────────┐
              │   DBApp   │  ← 唯一持有数据库的进程
              └─────┬─────┘
                    │
                    ▼
        ┌───────────────────────┐
        │  MySQL / XML 存储     │
        └───────────────────────┘
```

DBApp 不直接面对客户端,它只通过 Mercury 协议与 BaseApp、BaseAppMgr、LoginApp、DBAppMgr 通信。它的"客户"是其它服务器进程,它的"产品"是可靠的、可恢复的实体数据。

### 11.1.2 源码位置

DBApp 的源码全部位于 `programming/bigworld/server/dbapp/` 目录,共 50+ 个文件。最关键的几个:

| 文件 | 行数(约) | 职责 |
|------|----------|------|
| `dbapp.hpp` / `dbapp.cpp` | 500 / 2830+ | 主类 `DBApp`,进程入口与所有消息处理 |
| `dbapp_config.hpp` / `.cpp` | 30 / 100+ | 配置类,继承自 `ServerAppConfig` |
| `message_handlers.cpp` | 100+ | 宏生成的消息分发 |
| `login_handler.hpp` / `.cpp` | 140 / 500+ | 登录流程处理器 |
| `load_entity_handler.hpp` / `.cpp` | 65 / 200+ | 加载实体处理器 |
| `write_entity_handler.hpp` / `.cpp` | 55 / 200+ | 写入实体处理器 |
| `delete_entity_handler.hpp` / `.cpp` | 45 / 100+ | 删除实体处理器 |
| `get_entity_handler.hpp` / `.cpp` | 35 / 100+ | `GetEntityHandler` 基类(回调拦截层) |
| `look_up_entity_handler.hpp` / `.cpp` | 55 / 200+ | 查询实体邮箱处理器 |
| `look_up_dbid_handler.hpp` / `.cpp` | 40 / 100+ | 查询实体 DBID 处理器 |
| `look_up_entities_handler.hpp` / `.cpp` | — / 200+ | 批量查询实体处理器 |
| `entity_auto_loader.hpp` / `.cpp` | 50 / 315 | 启动时自动加载器 |
| `consolidator.hpp` / `.cpp` | 50 / 200+ | 二级数据库合并器(子进程封装) |
| `authenticate_account_handler.hpp` | 70 | 账号认证处理器 |
| `relogon_attempt_handler.hpp` | — | 重连尝试处理器 |
| `log_on_records_cache.hpp` / `.cpp` | — / 100+ | 登录记录缓存 |

与 DBApp 配套的"扩展库"位于 `programming/bigworld/server/dbapp_extensions/`,数据库工具位于 `programming/bigworld/server/tools/`,这些会在后面的小节里展开。

### 11.1.3 与 DBAppMgr 的关系

BigWorld 在数据存储子系统里同样采用了**控制平面 + 数据平面**的分层架构,这与 BaseApp/BaseAppMgr 的关系是同构的:

- **DBAppMgr**:控制平面,**单例**,不直接访问数据库,只管理 DBApp 进程的生命周期、Alpha 选举、Rendezvous 哈希分片、LoginApp 注册。
- **DBApp**:数据平面,**多实例**(可水平扩展),实际持有 `IDatabase` 接口实例,执行实体 CRUD、登录查询、二级数据库合并等具体操作。

两者的分工可以类比 Kubernetes 中的 `kube-scheduler` 与 `kubelet`:DBAppMgr 决定"该开几个 DBApp、哪个是 Alpha、新的 LoginApp 该把登录请求路由给哪个 DBApp",而 DBApp 只负责"接到任务就老老实实执行"。

```
┌──────────────────────────────────────────────────────────────────┐
│ 控制平面 (单例)                                                  │
│   ┌──────────────────────┐                                       │
│   │      DBAppMgr       │  ← 管理 DBApp 生命周期、哈希、Alpha 选举│
│   │   (不持数据库连接)   │                                       │
│   └──────────┬───────────┘                                       │
│              │ addDBApp / updateDBAppHash                         │
└──────────────┼───────────────────────────────────────────────────┘
               │
       ┌───────┴────────┐
       ▼                ▼
┌─────────────┐   ┌─────────────┐
│ DBApp Alpha │   │ DBApp #2    │  ← 数据平面,水平扩展
│ (持 IDatabase│   │ (持 IDatabase│
│  + Billing)  │   │   不持 Billing│
│  + DB Lock)  │   │              │
└──────┬──────┘   └──────┬──────┘
       │                 │
       └────────┬────────┘
                ▼
         MySQL 集群 / XML 文件
```

#### DBApp Alpha 的特殊性

DBApp 集群中"DBApp Alpha"承担了额外的初始化职责。Alpha 是**隐式选举**的:`dbApps_.smallest().second()`,即 DBAppID 最小的那个。这种设计避免了显式选举协议——所有进程用同一规则得到同一结果,无需"投票"。

Alpha 与非 Alpha 的关键差异:

| 维度 | DBApp Alpha | Non-Alpha DBApp |
|------|-------------|-----------------|
| **BillingSystem** | 创建 | 不创建(`pBillingSystem_=NULL`) |
| **DB 独占锁** | `lockDB()` 加锁 | 不加锁 |
| **二级 DB 合并** | 负责生成 prefix、启动合并 | 不参与 |
| **游戏状态重置** | 首次启动执行 | 不执行 |
| **BaseAppMgr initData** | 发送 | 不发送 |
| **Space 数据恢复** | 从 DB 读出并发往 BaseAppMgr | 不执行 |
| **实体自动加载** | 启动时自动加载持久化实体 | 不执行 |

这种"单点职责"的设计很务实:数据库的"首次初始化"操作(建表、清状态、合并二级 DB)本就不该并发执行,把它集中到 Alpha 上,避免了多 DBApp 同时操作时的竞争。

### 11.1.4 类继承

`DBApp` 类的继承结构很有意思,它通过多重继承把"应用层"、"定时器"、"几个 IDatabase 回调接口"组合到一起:

```cpp
// programming/bigworld/server/dbapp/dbapp.hpp:57
class DBApp : public ScriptApp,                              // 脚本层支持
             public TimerHandler,                            // 定时器
             public IDatabase::IGetBaseAppMgrInitDataHandler, // 取 BaseAppMgr 初始化数据
             public IDatabase::IUpdateSecondaryDBshandler,   // 二级 DB 更新完成
             public Singleton< DBApp >                        // 单例
```

`ScriptApp` 提供 Python 脚本支持(每个 DBApp 都加载 `database` 脚本目录);`TimerHandler` 提供周期性触发的定时器(用于状态检查);两个 `IDatabase::*Handler` 接口让 DBApp 自身可以作为 `IDatabase` 异步操作的回调对象——这是一种"自回调"模式,省去了额外的 handler 对象。

### 11.1.5 DBApp 的核心成员

打开 `dbapp.hpp` 的私有数据区,你能一眼看清 DBApp 持有哪些"重型资源":

```cpp
// programming/bigworld/server/dbapp/dbapp.hpp:433
DBAppID             id_;                    // 由 DBAppMgr 分配的 ID
DBAppsGateway       dbApps_;                // 所有 DBApp 的哈希视图

EntityDefs*         pEntityDefs_;           // 实体定义(entities.xml 解析结果)
IDatabase *         pDatabase_;             // ★ 数据库引擎实例(XML 或 MySQL)
BillingSystem *     pBillingSystem_;        // ★ 计费系统实例(仅 Alpha)

DBStatus            status_;                // 启动状态机
DBAppMgrGateway     dbAppMgr_;              // 到 DBAppMgr 的通道
BaseAppMgr          baseAppMgr_;             // 到 BaseAppMgr 的通道

uint16              initState_;             // InitStateFlags 位图
BW::string          secondaryDBPrefix_;      // 二级 DB 路径前缀(Alpha)
uint                secondaryDBIndex_;      // 二级 DB 序号(Alpha)
std::auto_ptr< Consolidator >   pConsolidator_;  // 合并器(Alpha)
LogOnRecordsCache   logOnRecordsCache_;     // 登录记录缓存
```

`pDatabase_` 是整个 DBApp 的"心脏",所有实体操作最终都会落到这个指针上。`pBillingSystem_` 只在 Alpha 上非空,因为登录认证要查"账号→实体"映射,这种映射的存储因计费系统而异。`initState_` 是个 16 位标志位图,记录"哪些初始化步骤已完成",在 `onInitCompleted()` 时用 `NON_ALPHA_MASK` 断言所有必需步骤都跑完了——这是一种轻量的初始化完整性保障。

### 11.1.6 启动状态机

DBApp 启动是**事件驱动**的,核心设计是:`init()` 只做同步能完成的部分,后续在 `onDBAppMgrRegistrationCompleted()` 回调中继续,Alpha 路径还要串联多个异步回调。`DBStatus` 的状态机大致如下:

```
STARTING
   │  (init() 同步部分完成)
   ▼
WAITING_FOR_DBAPP_MGR  ── 异步注册到 DBAppMgr ──▶ (回调)
   │
   ▼
WAITING_FOR_APPS       ── Alpha 还要等 BaseAppMgr/CellAppMgr 就绪 ──▶
   │
   ▼
RESTORING_STATE        ── 仅 Alpha:恢复 space 数据 + 自动加载实体 ──▶
   │
   ▼
RUNNING
```

`InitStateFlags` 是这个状态机的"位图记账":

```cpp
// programming/bigworld/server/dbapp/dbapp.hpp:449
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
    INIT_STATE_NON_ALPHA_MASK           = (INIT_STATE_SCRIPT_APP_READY << 1) - 1,
    INIT_STATE_SECONDARY_DBS            = (1 << 10),  // Alpha 专属
    INIT_STATE_SPACE_DATA_RESTORE       = (1 << 11),  // Alpha 专属
    INIT_STATE_AUTO_LOADING             = (1 << 12)   // Alpha 专属
};
```

`NON_ALPHA_MASK` 覆盖 0~9 位,即所有 DBApp(无论 Alpha 与否)都必须完成的步骤;10~12 位是 Alpha 专属。`onInitCompleted()` 通过 `(initState_ & NON_ALPHA_MASK) == NON_ALPHA_MASK` 断言非 Alpha 步骤全部完成,这是一种"轻量的初始化完整性保障"——避免漏跑某一步导致运行时崩溃。

---

## 11.2 双存储引擎架构

### 11.2.1 为什么需要"双引擎"

如果你做过 Web 开发,你会习惯"开发用 SQLite、生产用 PostgreSQL"这种切换。BigWorld 在 2003 年的设计也是同一思路:

- **开发/演示阶段**:用 XML 文件做存储,零依赖、零配置,改完代码立刻能跑;缺点是不能并发、性能差。
- **生产阶段**:用 MySQL 做存储,支持事务、并发、备份;缺点是要装 MySQL、要配账号密码、要同步表结构。

BigWorld 把这两种实现抽象成同一个接口 `IDatabase`,让上层(DBApp)完全感知不到差异。这就是经典的 **Strategy(策略)模式**:接口不变,实现可换。

### 11.2.2 IDatabase 抽象接口

`IDatabase` 是所有存储引擎的统一接口,定义在 `programming/bigworld/lib/db_storage/idatabase.hpp:47`。它的设计有几个关键特征:

**第一,大量使用嵌套的回调接口**。因为数据库操作可能是异步的(MySQL 后台线程执行 SQL),每个核心方法都配套一个 `I*Handler` 内部类:

```cpp
// programming/bigworld/lib/db_storage/idatabase.hpp:47
class IDatabase
{
public:
    virtual ~IDatabase() {}

    // 生命周期
    virtual bool startup( const EntityDefs& entityDefs,
            Mercury::EventDispatcher & dispatcher, int numRetries ) = 0;
    virtual bool shutDown() = 0;
    virtual bool resetGameServerState() { return true; }

    // 创建与本引擎绑定的计费系统
    virtual BillingSystem * createBillingSystem() = 0;

    // 是否支持多 DBApp(可扩展)
    virtual bool supportsMultipleDBApps() const { return true; }

    // 实体 CRUD
    class IGetEntityHandler { /* onGetEntityComplete() */ };
    virtual void getEntity( const EntityDBKey & entityKey,
            BinaryOStream * pStream,
            bool shouldGetBaseEntityLocation,
            IGetEntityHandler & handler ) = 0;

    class IPutEntityHandler { /* onPutEntityComplete() */ };
    virtual void putEntity( const EntityKey & entityKey,
            EntityID entityID, BinaryIStream * pStream,
            const EntityMailBoxRef * pBaseMailbox,
            bool removeBaseMailbox, bool putExplicitID,
            UpdateAutoLoad updateAutoLoad,
            IPutEntityHandler & handler ) = 0;

    class IDelEntityHandler { /* onDelEntityComplete() */ };
    virtual void delEntity( const EntityDBKey & ekey, EntityID entityID,
            IDelEntityHandler& handler ) = 0;

    // 查询
    virtual void getDatabaseIDFromName( const EntityDBKey & entityKey,
            IGetDbIDHandler & handler ) = 0;
    virtual void lookUpEntities( EntityTypeID entityTypeID,
            const LookUpEntitiesCriteria & criteria,
            ILookUpEntitiesHandler & handler ) = 0;

    // ID 管理
    virtual void putIDs( int count, const EntityID * ids ) = 0;
    virtual void getIDs( int count, IGetIDsHandler& handler ) = 0;

    // 空间数据
    virtual void writeSpaceData( BinaryIStream& spaceData ) = 0;
    virtual bool getSpacesData( BinaryOStream& strm ) = 0;

    // 自动加载
    virtual void autoLoadEntities( IEntityAutoLoader & autoLoader ) = 0;

    // 邮箱重映射(BaseApp 死亡后)
    virtual void remapEntityMailboxes( const Mercury::Address& srcAddr,
            const BackupHash & destAddrs ) = 0;

    // 二级数据库
    virtual bool shouldConsolidate() const = 0;
    virtual void shouldConsolidate( bool shouldConsolidate ) = 0;
    virtual void addSecondaryDB( const SecondaryDBEntry& entry ) = 0;
    virtual void updateSecondaryDBs( const SecondaryDBAddrs& addrs,
            IUpdateSecondaryDBshandler& handler ) = 0;
    virtual void getSecondaryDBs( IGetSecondaryDBsHandler& handler ) = 0;
    virtual uint32 numSecondaryDBs() = 0;
    virtual int clearSecondaryDBs() = 0;

    // 数据库锁
    virtual bool lockDB() = 0;
    virtual bool unlockDB() = 0;

    // 杂项
    virtual void setGameTime( GameTime time ) {};
    virtual bool hasUnrecoverableError() const { return false; }
    virtual void getBaseAppMgrInitData( IGetBaseAppMgrInitDataHandler& handler ) = 0;
    virtual void executeRawCommand( const BW::string & command,
            IExecuteRawCommandHandler& handler ) = 0;
};
```

接口设计上有几个细节值得注意:

1. **`startup()` 接收 `EntityDefs`**:引擎启动时就需要实体定义,因为 MySQL 要根据 entities.xml 里的 `Persistent=true` 字段建表。
2. **`createBillingSystem()`**:让引擎自己决定配套的计费系统实现——MySQL 引擎配套的计费系统可以直接查 `accounts` 表;XML 引擎则没有真正的计费,只能"放行所有用户"。
3. **`shouldConsolidate()` 这一对方法**:二级数据库是 MySQL 引擎特有的功能,XML 引擎返回 `false` 即可。
4. **`IGetEntityHandler` 等接口是抽象类**:调用方(`DBApp`)继承这些接口并提供实现,引擎完成后通过这些接口回调。

### 11.2.3 DatabaseEngineCreator:工厂与链接期注册

BigWorld 没有在运行时通过配置文件选择引擎,而是采用了**链接期注册**的工厂模式。核心是 `DatabaseEngineCreator` 类(`programming/bigworld/lib/db_storage/db_engine_creator.hpp:51`):

```cpp
// programming/bigworld/lib/db_storage/db_engine_creator.hpp:51
class DatabaseEngineCreator : public IntrusiveObject< DatabaseEngineCreator >
{
public:
    DatabaseEngineCreator( const BW::string & typeName );

    // 静态工厂方法:按 typeName 查找已注册的 Creator,创建实例
    static IDatabase * createInstance( const BW::string type,
                                    const DatabaseEngineData & dbEngineData );

protected:
    // 子类实现:实际创建引擎
    virtual IDatabase * createImpl( DatabaseEngineData & dbEngineData ) const = 0;

private:
    BW::string typeName_;
};
```

`IntrusiveObject<DatabaseEngineCreator>` 是 BigWorld 自己的"侵入式对象注册表":任何子类在构造时自动把自己加入全局列表,析构时自动移除。这意味着只要某个 `.cpp` 文件被链接进可执行文件,它的 Creator 就自动可用——这就是"链接期注册"。

#### MySQL 引擎 Creator

```cpp
// programming/bigworld/server/dbapp_extensions/bwengine_mysql/mysql_engine_creator.cpp:13
class MySqlEngineCreator : public DatabaseEngineCreator
{
public:
    MySqlEngineCreator() :
        DatabaseEngineCreator( "mysql" )    // 注册名为 "mysql"
    { }

    IDatabase * createImpl( DatabaseEngineData & dbEngineData ) const
    {
        return createMySqlDatabase( dbEngineData.interface(),
                                    dbEngineData.dispatcher() );
    }
};

namespace // (anonymous)
{
MySqlEngineCreator staticInitialiser;   // ★ 静态对象,链接即注册
}
```

文件底部那个 `staticInitialiser` 是关键:它是个匿名命名空间里的静态对象,程序一启动就构造,构造时调用基类构造函数把 `"mysql"` 注册到全局表。DBApp 启动时只需要:

```cpp
// programming/bigworld/server/dbapp/dbapp.cpp:430
const BW::string & databaseType = DBConfig::get().type();    // 读 bw.xml 的 <dbEngine>mysql</dbEngine>
pDatabase_ = DatabaseEngineCreator::createInstance( databaseType, dbEngineData );
```

就能拿到对应的 `IDatabase` 实例。

#### XML 引擎 Creator

XML 引擎的 Creator 几乎一模一样,但有个额外的"生产环境警告":

```cpp
// programming/bigworld/server/dbapp_extensions/bwengine_xml/xml_engine_creator.cpp:13
class XMLEngineCreator : public DatabaseEngineCreator
{
public:
    XMLEngineCreator() :
        DatabaseEngineCreator( "xml" )    // 注册名为 "xml"
    { }

    IDatabase * createImpl( DatabaseEngineData & dbEngineData ) const
    {
        IDatabase * pDatabase = new XMLDatabase();

        if (pDatabase && dbEngineData.isProduction())
        {
            ERROR_MSG(
                "The XML database is suitable for demonstrations and "
                "evaluations only.\n"
                "Please use the MySQL database for serious development and "
                "production systems.\n" );
        }

        return pDatabase;
    }
};
```

注意这个 `isProduction` 检查——XML 引擎在"生产模式"下会主动报错。这是一种"防御性设计":避免运维误把演示用引擎部署到正式服务器上,导致数据丢失。

### 11.2.4 引擎选择与切换

引擎的切换是**配置驱动**的,不需要改一行代码。在 `bw.xml` 配置文件里有这么一段:

```xml
<dbManager>
    <type>mysql</type>   <!-- 或 "xml" -->
    <mysql>
        <host>localhost</host>
        <port>3306</port>
        <username>bigworld</username>
        <password>...</password>
        <database>bigworld</database>
    </mysql>
</dbManager>
```

DBApp 启动时:

1. `initDatabaseCreation()` 读取 `DBConfig::get().type()`,得到 `"mysql"` 或 `"xml"`。
2. `DatabaseEngineCreator::createInstance("mysql", ...)` 在已注册的 Creator 表里找到 `MySqlEngineCreator`,调用它的 `createImpl()`,返回 `MySqlDatabase*`(向上转成 `IDatabase*`)。
3. DBApp 持有 `pDatabase_` 指针,后续所有操作都通过这个指针调用——它根本不知道底层是 MySQL 还是 XML。

这套设计的工程价值在于:**新增一个存储引擎(比如 PostgreSQL)只需要写一个新的 `*EngineCreator` + 实现 `IDatabase` 接口,链接进 DBApp 即可,DBApp 代码完全不用动**。这就是 Strategy 模式 + 链接期注册的威力。

### 11.2.5 引擎实现的代码量差异

XML 和 MySQL 两个引擎的实现复杂度有天壤之别,从代码量就能看出来:

| 引擎 | 实现位置 | 源文件数 | 复杂度 |
|------|---------|---------|--------|
| XML | `lib/db_storage_xml/` | 4 个 | 极简,直接读写 XML 文件,无事务、无并发 |
| MySQL | `lib/db_storage_mysql/` | 90+ 个 | 完整 RDBMS 实现,有后台任务、事务、表同步、连接池 |

XML 引擎存在的主要价值是"开箱即用"——你下载了 BigWorld 源码,不装 MySQL 也能跑起来一个 demo 服务器,看到实体能保存到 `bigworld\entities\<entity_type>\<dbid>.xml` 这种文件里。但生产环境绝对不能用,因为它**不支持多 DBApp 并发写**(会文件冲突)、**没有事务**(中途崩溃数据就坏了)、**性能极差**(每次读写都解析整个 XML)。

---

## 11.3 实体持久化流程

### 11.3.1 实体的"持久化字段"概念

在 BigWorld 里,不是实体的所有字段都会被持久化。实体的字段定义在 `entities.xml` 里,每个 `<Property>` 都有个 `Persistent` 属性:

```xml
<Entity name="Avatar">
    <Properties>
        <name>
            <Type> STRING </Type>
            <Flags> BASE </Flags>
            <Persistent> true </Persistent>     <!-- ★ 持久化 -->
        </name>
        <level>
            <Type> INT32 </Type>
            <Flags> BASE </Flags>
            <Persistent> true </Persistent>
        </level>
        <health>
            <Type> FLOAT </Type>
            <Flags> CELL </Flags>
            <Persistent> false </Persistent>    <!-- 不持久化 -->
        </health>
    </Properties>
</Entity>
```

`Persistent=true` 的字段才会被写入数据库。这种设计有几个好处:

1. **减少数据库压力**:像"当前血量"、"正在播放的动画"这种临时状态不需要存档。
2. **避免数据不一致**:Cell 上的状态每帧都在变,存了也会立刻过时。
3. **逻辑解耦**:游戏策划改"血量恢复速度"不需要迁移存档数据。

实体定义解析后,`EntityDefs`(`lib/db_storage/db_entitydefs.hpp`)会持有"哪些字段是 persistent"的元信息,`IDatabase::startup()` 时 MySQL 引擎会根据这些信息建表/改表。

### 11.3.2 saveEntity 流程:BaseApp → DBApp

最常见的持久化场景是 BaseApp 主动调用 `BigWorld.saveEntity()` 把实体状态写到 DBApp。完整流程:

```
[BaseApp 侧]
  BigWorld.saveEntity( entity, dbID )        ← Python 脚本调用
        │
        ▼
  BaseApp::saveEntity()                       ← C++ 入口
        │  把 persistent 字段序列化到 BinaryIStream
        ▼
  Mercury 发送 writeEntity 消息到 DBApp
        │
        ▼
[DBApp 侧]
  DBApp::writeEntity()                        ← dbapp.cpp
        │  从流里解出 EntityTypeID + dbID + flags
        ▼
  new WriteEntityHandler( ekey, entityID, flags, replyID, srcAddr )
        │
        ▼
  WriteEntityHandler::writeEntity( data, entityID )   ← write_entity_handler.cpp
        │  根据 flags 决定:
        │    - WRITE_BASE_CELL_DATA → 写实体数据
        │    - WRITE_LOG_OFF → 同时清除 mailbox
        │    - WRITE_AUTO_LOAD_YES/NO → 更新 autoload 标志
        ▼
  DBApp::putEntity() → pDatabase_->putEntity()        ← 调用引擎
        │
        ▼
[引擎侧,以 MySQL 为例]
  MySqlDatabase::putEntity()                  ← lib/db_storage_mysql/
        │  生成 INSERT/UPDATE SQL
        │  后台线程执行
        ▼
  完成后回调 WriteEntityHandler::onPutEntityComplete( isOK, dbID )
        │
        ▼
  WriteEntityHandler::finalise( isOK )         ← 回复 BaseApp
        │
        ▼
  Mercury 发送回复给 BaseApp
```

注意几个细节:

1. **`WRITE_LOG_OFF` 标志**:玩家下线时,BaseApp 调 `saveEntity` 会带这个标志,让 DBApp 在写完数据后**同时清除 mailbox 字段**——表示"这个实体已经没人持有,可以从 DB 重新加载"。
2. **`WRITE_AUTO_LOAD_YES/NO`**:`autoLoad` 是实体上的一个布尔标志,标记"服务器重启时是否需要自动加载"。实体被创建时设为 YES,被销毁时设为 NO,这样重启后只有"应该自动恢复"的实体会被加载回来。
3. **dbID 可能为 0**:如果是新实体第一次写入,`ekey.dbID == 0`,引擎会自动分配一个新的 DBID 并通过回调返回。

### 11.3.3 loadEntity 流程:DBApp → 引擎 → BaseApp

加载实体的流程是反向的,但更复杂一点,因为要处理"实体已经被检出"的情况:

```
[BaseApp 侧]
  BaseApp::loadEntity( typeID, name/dbID )     ← 脚本调用
        │
        ▼
  Mercury 发送 loadEntity 消息到 DBApp
        │
        ▼
[DBApp 侧]
  DBApp::loadEntity()                          ← dbapp.cpp
        │
        ▼
  new LoadEntityHandler( ekey, srcAddr, entityID, replyID )
        │
        ▼
  LoadEntityHandler::loadEntity()              ← load_entity_handler.cpp
        │  准备回复 bundle,预留 dbID 位置
        ▼
  DBApp::getEntity( ekey, &replyBundle_, shouldGetBase=true, *this )
        │
        ▼
  pDatabase_->getEntity() → 引擎读取实体数据,直接流式写入 bundle
        │
        ▼
  LoadEntityHandler::onGetEntityCompleted( isOK, ekey, pBaseEntityLocation )
        │
        ├── 若 pBaseEntityLocation != NULL:实体已被检出
        │     → sendAlreadyCheckedOutReply( *pBaseEntityLocation )
        │        (告诉 BaseApp "这个实体在 xxx BaseApp 上,你别加载了")
        │
        ├── 若 onStartEntityCheckout( entityKey ) == true:未被检出
        │     → setBaseEntityLocation( ekey, baseRef_ )  写入新 mailbox
        │     → 等回调,再发送 createBase 给 BaseAppMgr
        │
        └── 否则:正在被检出中
              → registerCheckoutCompletionListener()
                 (等其他检出的 BaseApp 完成后再通知当前 BaseApp)
```

这个流程体现了 BigWorld 的一个重要约束:**同一个实体在同一时刻只能被一个 BaseApp 持有**。如果两个 BaseApp 同时尝试 loadEntity 同一个实体,后到的会被"挂起"等待先到的完成,然后被告知"这个实体在 xxx 那里,你别加载了"。

`LoadEntityHandler` 同时继承 `ICheckoutCompletionListener`,就是用来处理这种"等待别人完成检出"的场景:

```cpp
// programming/bigworld/server/dbapp/load_entity_handler.hpp:17
class LoadEntityHandler : public GetEntityHandler,
                          public IDatabase::IPutEntityHandler,
                          public DBApp::ICheckoutCompletionListener
```

### 11.3.4 透明持久化

对 Python 脚本来说,持久化是"半透明"的:

```python
# 在 BaseApp 的脚本里
BigWorld.saveEntity( self )           # 主动保存
entity = BigWorld.lookUpEntityByDBID( typeID, dbID )  # 查询
BigWorld.destroyEntity( entity )      # 销毁(连带从 DB 删)
```

脚本不需要知道数据存到哪儿了、用的是什么引擎、是同步还是异步。但有几个"隐形约定":

1. **`Persistent=true` 的字段才会被保存**——脚本如果想加新存档字段,要改 `entities.xml`。
2. **保存是异步的**——`saveEntity` 返回后并不代表数据已经落盘,只是"请求已发出"。
3. **实体销毁不会自动从 DB 删**——除非显式调 `destroyEntity`,否则实体记录还在。

这种"半透明"设计是务实的选择:既给脚本程序员"我点保存就保存"的简单心智模型,又通过 `Persistent` 标志让性能优化(只存必要字段)有抓手。

---

## 11.4 二级数据库

### 11.4.1 什么是"二级数据库"

如果你做过大型 MMOG,可能遇到过这种问题:**数据库写入压力大,主库扛不住**。BigWorld 的"二级数据库"(Secondary Database)是一个有点独特的设计,它的核心思想是:

- **主数据库**(Primary DB):MySQL,集中存储所有实体的"权威版本"。
- **二级数据库**(Secondary DB):SQLite 文件,分散在各个 BaseApp 机器上,作为写入缓冲。

每个 BaseApp 在写实体时,可以先把数据写到本机的 SQLite 二级库里(快、无网络),然后定期"合并"(consolidate)到主 MySQL 库。这种设计的优势是:

1. **降低主库写压力**:大量小写入被二级库吸收。
2. **网络友好**:二级库在本地,主库合并是批量操作。
3. **可恢复**:BaseApp 崩溃后,二级库里的未合并数据还能找回来。

缺点也很明显:

1. **复杂性大幅上升**:多了一层存储,要处理合并、冲突、清理。
2. **合并窗口期数据不一致**:二级库里的数据主库看不到,主库里的数据二级库可能不知道已被改。
3. **只 MySQL 引擎支持**:XML 引擎没有二级库概念。

`IDatabase` 接口里关于二级库的方法是这一段:

```cpp
// programming/bigworld/lib/db_storage/idatabase.hpp:377
virtual bool shouldConsolidate() const = 0;
virtual void shouldConsolidate( bool shouldConsolidate ) = 0;

class SecondaryDBEntry {
public:
    Mercury::Address   addr;        // 二级库所在的 BaseApp 地址
    BW::string         location;    // 二级库在 BaseApp 机器上的路径
};
typedef BW::vector< SecondaryDBEntry > SecondaryDBEntries;

virtual void addSecondaryDB( const SecondaryDBEntry& entry ) = 0;
virtual void updateSecondaryDBs( const SecondaryDBAddrs& addrs,
        IUpdateSecondaryDBshandler& handler ) = 0;
virtual void getSecondaryDBs( IGetSecondaryDBsHandler& handler ) = 0;
virtual uint32 numSecondaryDBs() = 0;
virtual int clearSecondaryDBs() = 0;
```

### 11.4.2 二级数据库的生命周期

二级库的"生"与"死"都跟 DBApp Alpha 绑定:

```
[DBApp Alpha 启动]
   │
   ▼
initSecondaryDBsAsync()                       ← dbapp.cpp:901
   │
   ├── initSecondaryDBPrefix()                ← dbapp.cpp:940
   │     生成 prefix = "user_YYYYMMDD_HHMMSS"
   │     这个 prefix 用于本次运行的所有二级库文件名
   │
   ├── if 引擎是 XML 类型 → onSecondaryDBsInitCompleted() 直接跳过
   │
   ├── if !shouldConsolidate → onSecondaryDBsInitCompleted() 跳过
   │
   └── else → consolidateData()                ← dbapp.cpp:1318
         │   启动 consolidate_dbs 子进程
         │   把上次运行遗留的二级库全部合并到主库
         ▼
       onConsolidateProcessEnd( isOK )         ← dbapp.cpp:1382
         │
         ▼
       onSecondaryDBsInitCompleted()           ← dbapp.cpp:996
```

注意"上次运行遗留的二级库"这个细节——服务器正常关停时,所有 BaseApp 的二级库不会立刻合并到主库(为了快速关停);下次启动时,Alpha 要先把这些遗留二级库合并完,才能开始新的服务。这就是 `consolidateData()` 的作用。

### 11.4.3 consolidate_dbs 工具

`consolidate_dbs` 是个独立的可执行文件,源码位于 `programming/bigworld/server/tools/consolidate_dbs/`。它的入口很简单:

```cpp
// programming/bigworld/server/tools/consolidate_dbs/main.cpp:35
int main( int argc, char * argv[] )
{
    ConsolidateDBsApp app( !options.shouldIgnoreSqliteErrors() );

    if (options.shouldClear())
    {
        return app.clearSecondaryDBEntries() ? EXIT_SUCCESS : EXIT_FAILURE;
    }

    if (options.shouldList())
    {
        return app.printDatabases() ? EXIT_SUCCESS : EXIT_FAILURE;
    }

    if (!app.checkPrimaryDBEntityDefsMatch())
    {
        return EXIT_FAILURE;
    }

    if (options.hadNonOptionArgs())
    {
        // 命令行直接给了二级库文件列表
        return app.consolidateSecondaryDBs( options.secondaryDatabases() ) ?
            EXIT_SUCCESS : EXIT_FAILURE;
    }
    else
    {
        // 没给文件,从主库里查所有注册的二级库,先传输再合并
        return app.transferAndConsolidate() ? EXIT_SUCCESS : EXIT_FAILURE;
    }
}
```

它支持三种模式:

1. **`--clear`**:清空主库里所有二级库注册记录(用于强制重置)。
2. **`--list`**:列出主库里所有二级库注册记录。
3. **默认模式**:执行实际的合并。如果命令行给了文件列表,直接合并这些文件;否则从主库查所有注册的二级库,先把 SQLite 文件从各 BaseApp 机器传输过来,再合并。

#### SecondaryDatabase 类:合并的核心

合并单个二级库的逻辑在 `SecondaryDatabase` 类:

```cpp
// programming/bigworld/server/tools/consolidate_dbs/secondary_database.hpp:22
class SecondaryDatabase
{
public:
    bool init( const BW::string & dbPath );      // 打开 SQLite 文件
    uint numEntities() const { return numEntities_; }
    bool consolidate( PrimaryDatabaseUpdateQueue & primaryDBQueue,
            ConsolidationProgressReporter & progressReporter,
            bool shouldIgnoreErrors,
            bool & shouldAbort );                 // ★ 执行合并
private:
    bool readTables();
    bool tableExists( const BW::string & tableName );
    void sortTablesByAge();                        // 按年龄排序,先合旧数据
    BW::string                         path_;
    std::auto_ptr< SqliteConnection >  pConnection_;
    Tables                             tables_;   // 二级库里的表
    uint                               numEntities_;
};
```

`sortTablesByAge()` 这个细节很有意思——同一个实体可能在二级库里有多次写入(玩家边玩边存),合并时要按时间顺序应用,否则旧数据会覆盖新数据。

### 11.4.4 transfer_db 工具

`transfer_db` 是另一个独立工具,源码在 `programming/bigworld/server/tools/transfer_db/`。它的作用是**传输**二级库文件或主库快照,支持三种命令:

```cpp
// programming/bigworld/server/tools/transfer_db/main.cpp:48
for (int i = 1; i < argc; ++i)
{
    if (strcmp( argv[i], "consolidate" ) == 0)
    {
        // transfer_db consolidate <sqlite_file> <receiving IP>:<port>
        // 把一个二级库文件传输到远端,准备合并
        transferDB.consolidate( secondaryDB, sendToAddr );
    }
    else if (strcmp( argv[i], "snapshotprimary" ) == 0)
    {
        // transfer_db snapshotprimary <dest IP> <dest path> <limit kbps>
        // 把主库快照传输到远端
        transferDB.snapshotPrimary( destIP, destPath, limitKbps );
    }
    else if (strcmp( argv[i], "snapshotsecondary" ) == 0)
    {
        // transfer_db snapshotsecondary <sqlitefile> <destIP> <destpath> <limit kbps>
        // 把一个二级库文件传输到远端
        transferDB.snapshotSecondary( secondaryDB, destIP, destPath, limitKbps );
    }
}
```

`<limit kbps>` 参数支持限速传输,避免备份操作占满网络带宽影响在线服务。这是 BigWorld 在工程细节上的考究之处——一个简单的文件传输工具也考虑了生产环境的真实需求。

### 11.4.5 二级库的工程价值与争议

二级库的设计是 BigWorld 在 2000 年代初期为应对 MySQL 写入性能瓶颈的方案。它的价值在于:

1. **写入削峰**:大量小写入被二级库吸收,主库只承受批量合并的写。
2. **故障恢复**:BaseApp 崩溃后,本地二级库的未合并数据不丢。

但这个设计也有争议:

1. **复杂性极高**:增加了合并、传输、清理一整套工具链。
2. **一致性弱**:合并窗口内主库与二级库数据不一致。
3. **现代 MySQL 性能已大幅提升**:SSD、InnoDB 优化、连接池让单库写入性能足够支撑大多数 MMOG。

在 BigWorld 14.x 版本,这个机制依然保留,但 `shouldConsolidate` 可以被设为 `false`,跳过整个二级库流程——直接每次写主库。对新手项目来说,**关闭二级库**是更简单的选择。

---

## 11.5 登录认证

### 11.5.1 登录流程总览

DBApp 在登录链路里处于"账号查询"的位置。完整流程:

```
[客户端]
   │  发送账号密码
   ▼
[LoginApp]
   │  把账号密码转发给 DBApp Alpha
   ▼
[DBApp Alpha]
   │  询问 BillingSystem:"这个账号对应哪个实体?"
   ▼
[BillingSystem]
   │  查 accounts 表 / 调外部计费 HTTP / 查 BWAuth
   ▼
[DBApp Alpha]
   │  拿到 EntityKey( typeID, dbID )
   │  调 getEntity() 从 DB 读实体数据
   │  调 setBaseEntityLocation() 占住 mailbox
   │  发 createBase 给 BaseAppMgr
   ▼
[BaseAppMgr]
   │  选一个 BaseApp 创建实体
   ▼
[BaseApp]
   │  持有实体,回复客户端"登录成功"
   ▼
[客户端]
   │  进入游戏
```

注意几个关键点:

1. **只有 DBApp Alpha 处理登录**:非 Alpha DBApp 收到登录请求会拒绝。这是因为 `BillingSystem` 只在 Alpha 上创建。
2. **登录涉及两次 DB 写入**:第一次是 `setBaseEntityLocation()` 占住 mailbox(防止别的客户端同时登录同一个账号),第二次是登录成功后写最终的 mailbox。
3. **`LoginHandler` 是个状态机**:它要处理"账号不存在怎么办"、"实体已经被检出怎么办"、"BaseApp 创建失败怎么办"等多种情况。

### 11.5.2 LoginHandler 的状态机

`LoginHandler` 是 DBApp 里最复杂的 Handler 之一,它的类声明:

```cpp
// programming/bigworld/server/dbapp/login_handler.hpp:41
class LoginHandler : public Mercury::ReplyMessageHandler,
                     public IGetEntityKeyForAccountHandler,
                     public ISetEntityKeyForAccountHandler,
                     public GetEntityHandler,
                     public IDatabase::IPutEntityHandler
```

它继承了 5 个接口,意味着它要扮演 5 种角色:

| 接口 | 何时被回调 |
|------|----------|
| `IGetEntityKeyForAccountHandler` | `BillingSystem::getEntityKeyForAccount()` 完成 |
| `ISetEntityKeyForAccountHandler` | `BillingSystem::setEntityKeyForAccount()` 完成 |
| `GetEntityHandler` | `DBApp::getEntity()` 完成(实体读出来了) |
| `IPutEntityHandler` | `DBApp::putEntity()` 完成(mailbox 写入了) |
| `ReplyMessageHandler` | BaseAppMgr 回复 createBase 的结果 |

这就是一个典型的"多阶段异步状态机"。每个回调对应一个阶段,LoginHandler 内部用私有方法(`checkOutEntity()`、`createNewEntity()`、`loadEntity()`、`sendCreateEntityMsg()`、`sendReply()`)串起整个流程。

`BillingSystem` 返回的结果有 4 种,对应 4 个回调:

```cpp
// programming/bigworld/lib/db_storage/billing_system.hpp:28
virtual void onGetEntityKeyForAccountSuccess(            // 账号存在,直接给 dbID
        const EntityKey & ekey, ... );

virtual void onGetEntityKeyForAccountLoadFromUsername(    // 账号不存在,但允许用 username 加载实体
        EntityTypeID entityType, const BW::string & username,
        bool shouldCreateNewOnLoadFailure, ... );

virtual void onGetEntityKeyForAccountCreateNew(           // 账号不存在,创建新实体
        EntityTypeID entityType, bool shouldRemember, ... );

virtual void onGetEntityKeyForAccountFailure(             // 拒绝登录
        LogOnStatus status, const BW::string & errorMsg );
```

这 4 种结果分别走不同的代码路径——"已存在"、"用名字找"、"新建"、"拒绝"。这种设计让计费系统的策略可以非常灵活:严格计费系统永远走"已存在"或"拒绝";宽松的演示系统可以让任何账号自动创建新角色。

### 11.5.3 BillingSystem:计费系统的抽象

`BillingSystem` 是登录认证的核心抽象,定义在 `programming/bigworld/lib/db_storage/billing_system.hpp:97`:

```cpp
// programming/bigworld/lib/db_storage/billing_system.hpp:97
class BillingSystem
{
public:
    BillingSystem( const EntityDefs & entityDefs );
    virtual ~BillingSystem() {}

    // 把 user/pass 转成 EntityKey
    virtual void getEntityKeyForAccount(
            const BW::string & username, const BW::string & password,
            const Mercury::Address & clientAddr,
            IGetEntityKeyForAccountHandler & handler ) = 0;

    // 设置 user/pass 与 EntityKey 的映射
    virtual void setEntityKeyForAccount( const BW::string & username,
            const BW::string & password, const EntityKey & ekey,
            ISetEntityKeyForAccountHandler & handler ) = 0;

    virtual bool isOkay() const { /* ... */ }

protected:
    // 来自 bw.xml 的配置
    bool shouldAcceptUnknownUsers_;       // 是否接受未知用户
    bool shouldRememberUnknownUsers_;    // 是否记住未知用户
    bool authenticateViaBaseEntity_;     // 是否用 Base 实体的方法认证
    EntityTypeID entityTypeIDForUnknownUsers_;
    BW::string entityTypeForUnknownUsers_;
};
```

注意几个设计要点:

1. **`getEntityKeyForAccount` 是异步的**:可能要查外部计费系统(HTTP 请求),所以走回调。
2. **`setEntityKeyForAccount` 用于"绑定账号"**:比如玩家首次创建角色后,把账号与新建实体的 DBID 绑定。
3. **配置项控制行为**:`shouldAcceptUnknownUsers_` 等开关让同一份代码可以走"严格认证"或"开放注册"两种模式。

### 11.5.4 多种计费后端

BigWorld 内置了三种计费系统实现,通过 `BillingSystemCreator` 子类注册:

#### Standard 计费系统

最常用的实现,代码在 `programming/bigworld/server/dbapp/standard_billing_system.cpp`:

```cpp
// programming/bigworld/server/dbapp/standard_billing_system.cpp:47
BillingSystem * StandardBillingSystemCreator::create(
    const EntityDefs & entityDefs, ServerApp & app ) const
{
    BillingSystem * pBillingSystem = NULL;
    ScriptObject func;

    if (Personality::instance())
    {
        func = Personality::instance().getAttribute( "connectToBillingSystem",
            ScriptErrorClear() );
    }

    if (func)
    {
        // 调用 Python 的 BWPersonality.connectToBillingSystem()
        ScriptObject billingSystem = func.callFunction( ScriptErrorPrint() );
        if (!billingSystem)
        {
            ERROR_MSG( "..." );
            return NULL;
        }

        if (!billingSystem.isNone())
        {
            pBillingSystem = new PyBillingSystem( billingSystem.get(), entityDefs );
        }
    }

    if (pBillingSystem == NULL)
    {
        // 没有脚本实现,回落到引擎自带的计费
        pBillingSystem = DBApp::instance().getIDatabase().createBillingSystem();
    }

    return pBillingSystem;
}
```

它的逻辑是:

1. 先看 Python 的 `BWPersonality` 有没有 `connectToBillingSystem()` 方法。
2. 有的话调用它,得到一个 Python 计费对象,用 `PyBillingSystem` 包起来。
3. 没有的话,回落到 `IDatabase::createBillingSystem()`——MySQL 引擎会返回一个查 `accounts` 表的实现;XML 引擎返回一个"放行所有用户"的实现。

这种"脚本优先,引擎兜底"的设计让游戏可以**完全用 Python 实现计费逻辑**(比如调外部 HTTP API、连第三方计费 SDK),不需要改 C++ 代码。

#### Custom 计费系统

`custom_billing_system.cpp` 是个示例,演示如何用 C++ 直接写一个计费系统。游戏可以参照这个模板接入自家的计费后端。

#### BWAuth 计费系统

`bwauth_billing_system.cpp` 是 BigWorld 自带的认证系统实现,适合内部测试环境。

### 11.5.5 look_up_entity_handler 与登录的辅助查询

除了 `LoginHandler`,DBApp 还有一组 `look_up_*_handler` 用于辅助查询:

| Handler | 作用 |
|---------|------|
| `look_up_entity_handler` | 查询单个实体的 mailbox(已检出实体的位置) |
| `look_up_dbid_handler` | 查询实体名→DBID 的映射 |
| `look_up_entities_handler` | 批量查询(按属性过滤) |
| `authenticate_account_handler` | 账号认证(给 LoginApp 用) |
| `relogon_attempt_handler` | 重连尝试(玩家断线重连) |

`LookUpEntityHandler` 的接口:

```cpp
// programming/bigworld/server/dbapp/look_up_entity_handler.hpp:14
class LookUpEntityHandler : public GetEntityHandler, IDatabase::IGetDbIDHandler
{
public:
    void lookUpEntity( EntityTypeID typeID, const BW::string & name );
    void lookUpEntity( EntityTypeID typeID, DatabaseID databaseID );

    virtual void onGetEntityCompleted( bool isOK,
            const EntityDBKey & entityKey,
            const EntityMailBoxRef * pBaseEntityLocation );
    virtual void onGetDbIDComplete( bool isOK, const EntityDBKey & entityKey );
};
```

它支持两种查询方式:

1. **按 name**:先调 `getDatabaseIDFromName()` 把名字转成 DBID,再调 `getEntity()` 取邮箱。
2. **按 DBID**:直接调 `getEntity()`。

这种"name → DBID → 实体数据"的两级查询是数据库设计的常见模式——name 是逻辑标识,DBID 是物理标识,两者解耦让改名、迁移更容易。

---

## 11.6 快照机制

### 11.6.1 快照的需求

数据库的"快照"是灾难恢复的核心手段。即使有二级库合并、有 binlog,你依然需要定期对整个数据库做"全量快照",以便:

1. **快速恢复**:从一个完整的状态点恢复,比回放 binlog 快得多。
2. **灾难备份**:把快照传到异地,主数据中心挂了也能恢复。
3. **版本归档**:保留历史快照,可以回滚到任意时间点。

BigWorld 的快照机制主要靠 `snapshot_helper` 工具实现,源码在 `programming/bigworld/server/tools/snapshot_helper/snapshot_helper.cpp`。它是个**需要 root 权限的 setuid 程序**——因为它要做 LVM 卷快照,这是个特权操作。

### 11.6.2 snapshot_helper 的工作原理

`snapshot_helper` 的核心思路是利用 Linux 的 LVM(Logical Volume Manager)做文件系统级快照。流程:

```
1. 连接 MySQL,执行 FLUSH TABLES WITH READ LOCK     ← 锁住所有表
2. lvcreate -L<size>G -s -n <snapshot> /dev/<group>/<origin>  ← 创建 LVM 快照
3. UNLOCK TABLES                                    ← 解锁
4. mount /dev/<group>/<snapshot> /mnt/<snapshot>/   ← 挂载快照
5. chmod -R 755 /mnt/<snapshot>/<datadir>           ← 放宽权限
6. 输出快照路径,供 transfer_db 传输
```

源码里这部分逻辑很清晰:

```cpp
// programming/bigworld/server/tools/snapshot_helper/snapshot_helper.cpp:142
bool acquire_snapshot( ConfigReader & config,
    const char * dbUser, const char * dbPass )
{
    if (!becomeRootUser())            // setuid(0) 提权
    {
        return false;
    }

    // ... 读取配置(datadir, lvgroup, lvorigin, lvsnapshot, lvsizegb)

    MYSQL sql;
    mysql_init( &sql );
    mysql_real_connect( &sql, "localhost", dbUser, dbPass, NULL, 0, NULL, 0 );

    // 1. 锁表
    mysql_real_query( &sql, "FLUSH TABLES WITH READ LOCK", ... );

    // 2. 创建 LVM 快照
    execl( LVCREATE,
        (BW::string("-L") + lvSizeGB + "G").c_str(),
        "-s", "-n", lvSnapshot.c_str(),
        (BW::string("/dev/") + lvGroup + "/" + lvOrigin).c_str(),
        NULL );

    // 3. 解锁
    mysql_real_query( &sql, "UNLOCK TABLES", ... );
    mysql_close( &sql );

    // 4. 挂载快照
    execl( "mount",
        ("/dev/" + lvGroup + "/" + lvSnapshot).c_str(),
        ("/mnt/" + lvSnapshot + "/").c_str(),
        NULL );

    // 5. 放宽权限(便于后续 transfer_db 读取)
    execl( "chmod", "-R", "755", snapshotFiles.c_str(), NULL );

    printf( "%s\n", snapshotFiles.c_str() );   // 输出快照路径
    return true;
}
```

注意几个细节:

1. **`FLUSH TABLES WITH READ LOCK` + `lvcreate` 的组合**:这是 MySQL+LVM 的标准快照套路——锁表确保内存里的脏数据刷到磁盘,LVM 快照保证文件系统一致性。
2. **锁表时间极短**:只在 `lvcreate` 期间持锁(毫秒级),完成后立刻 `UNLOCK TABLES`,不影响在线服务。
3. **setuid 的安全考量**:程序开头有注释说明——这个二进制必须用 root 拥有、设置 setuid 位(`chmod 4511`),且配置文件 `/etc/bigworld.conf` 必须 root-only writable。这是为了避免普通用户滥用提权。

### 11.6.3 release_snapshot:清理快照

快照用完后要清理,否则 LVM 卷会越来越满。`release_snapshot` 做两件事:

```cpp
// programming/bigworld/server/tools/snapshot_helper/snapshot_helper.cpp:254
bool release_snapshot( ConfigReader & config )
{
    if (!becomeRootUser())
    {
        return false;
    }

    // 1. 卸载快照挂载点
    execl( "umount", ("/mnt/" + lvSnapshot + "/").c_str(), NULL );

    // 2. 删除 LVM 快照卷
    execl( LVREMOVE, "-f",
        ("/dev/" + lvGroup, "/" + lvSnapshot).c_str(), NULL );

    return isOK;
}
```

### 11.6.4 快照配合 transfer_db 的完整流程

一个典型的"快照备份到异地"流程:

```
[机器 A:运行 MySQL 的 DBApp 主机]
   │
   ├── snapshot_helper acquire-snapshot <dbuser> <dbpass>
   │     输出:/mnt/snap_20260704/bigworld/
   │
   ├── transfer_db snapshotprimary <机器B IP> /backups/ 100000
   │     把快照目录传到机器 B,限速 100Mbps
   │
   └── snapshot_helper release-snapshot
         清理本地快照
   │
   ▼
[机器 B:备份服务器]
   收到 /backups/snap_20260704/bigworld/
   可以归档到磁带,或用于恢复
```

### 11.6.5 全量快照与增量更新

`snapshot_helper` 只做**全量快照**——每次都是数据库的完整副本。BigWorld 没有内置"增量快照"机制,增量靠 MySQL 自身的 binlog 实现:

- **全量快照**:定期(如每天凌晨)用 `snapshot_helper` 做一次,作为恢复基线。
- **增量更新**:MySQL binlog 持续记录所有写操作,恢复时回放 binlog 到指定时间点。

这种"全量 + binlog"的组合是 MySQL 灾难恢复的标准实践,BigWorld 只是把它工程化成了两个工具。

---

## 11.7 核心 Handler 类

### 11.7.1 Handler 的设计模式

DBApp 处理消息的核心套路是 **"每消息一个 Handler 对象"**:消息进来,new 一个 Handler;Handler 持有所有需要的上下文(回复地址、replyID、实体 key);Handler 调用 `IDatabase` 异步方法,把自己作为回调对象传进去;回调完成后,Handler 发送回复并 `delete this`。

这种模式的好处是:

1. **无状态**:`DBApp` 主类不持有"正在处理的请求"的状态,所有状态在 Handler 上。
2. **可并发**:多个请求可以同时进行,各自有独立的 Handler。
3. **易理解**:每个 Handler 的代码自成一体,从构造到析构就是一个完整的请求生命周期。

### 11.7.2 GetEntityHandler:回调拦截基类

所有"读实体"相关的 Handler 都继承自 `GetEntityHandler`,它是个**装饰器**(Decorator):

```cpp
// programming/bigworld/server/dbapp/get_entity_handler.hpp:14
class GetEntityHandler : public IDatabase::IGetEntityHandler
{
public:
    // 拦截 IDatabase 的回调,允许 DBApp 在中间"做手脚"
    virtual void onGetEntityComplete( bool isOK,
                const EntityDBKey & entityKey,
                const EntityMailBoxRef * pBaseEntityLocation );

    // 子类实现这个,而不是 onGetEntityComplete
    virtual void onGetEntityCompleted( bool isOK,                // ★ 注意多了个 'd'
                const EntityDBKey & entityKey,
                const EntityMailBoxRef * pBaseEntityLocation ) = 0;

    static bool isActiveMailBox( const EntityMailBoxRef * pBaseRef );
};
```

注意方法名的差异:`onGetEntityComplete`(没有 d)是 `IDatabase` 接口的方法,`onGetEntityCompleted`(有 d)是子类要实现的。这种"中间拦截层"的设计让 DBApp 可以在调用真正的回调前做一些通用处理(比如邮箱重映射检查),子类只需关心业务逻辑。

### 11.7.3 LoadEntityHandler:加载实体

`LoadEntityHandler` 用于把实体从 DB 读出来,创建到指定的 BaseApp 上。它的核心逻辑(`load_entity_handler.cpp:12`):

```cpp
// programming/bigworld/server/dbapp/load_entity_handler.cpp:12
void LoadEntityHandler::loadEntity()
{
    // 提前开始构造回复 bundle,让 getEntity() 可以直接流式写入
    replyBundle_.startReply( replyID_ );
    replyBundle_ << (uint8) LogOnStatus::LOGGED_ON;

    if (ekey_.dbID)
    {
        replyBundle_ << ekey_.dbID;
    }
    else
    {
        // dbID 未知,先预留位置,后面再回填
        pStrmDbID_ = reinterpret_cast< DatabaseID * >(
                        replyBundle_.reserve( sizeof( *pStrmDbID_ ) ) );
    }

    DBApp::instance().getEntity( ekey_, &replyBundle_, true, *this );
}
```

"预留位置后面回填"这个细节体现了性能优化意识——避免"先 getEntity 到临时缓冲,再拷贝到回复 bundle"的双重拷贝。`BinaryOStream::reserve()` 返回一个可写指针,引擎直接把数据写到 bundle 里。

### 11.7.4 WriteEntityHandler:写入实体

`WriteEntityHandler` 用于把实体状态写入 DB。它的 `writeEntity` 方法根据 `flags` 走不同分支(`write_entity_handler.cpp:36`):

```cpp
// programming/bigworld/server/dbapp/write_entity_handler.cpp:36
void WriteEntityHandler::writeEntity( BinaryIStream & data, EntityID entityID )
{
    UpdateAutoLoad updateAutoLoad =
        (flags_ & WRITE_AUTO_LOAD_YES) ?  UPDATE_AUTO_LOAD_TRUE :
        (flags_ & WRITE_AUTO_LOAD_NO)  ?  UPDATE_AUTO_LOAD_FALSE:
                                         UPDATE_AUTO_LOAD_RETAIN;

    if (flags_ & WRITE_BASE_CELL_DATA)
    {
        pStream = &data;     // 写实体数据
    }

    if (flags_ & WRITE_LOG_OFF)
    {
        // 玩家下线:写数据 + 清除 mailbox
        this->putEntity( pStream, updateAutoLoad,
                /* pBaseMailbox: */ NULL,
                /* removeBaseMailbox: */ true );
    }
    else if (ekey_.dbID == 0 || (flags_ & WRITE_EXPLICIT_DBID))
    {
        // 新实体:写数据 + 占住 mailbox
        baseRef_.init( entityID, srcAddr_, EntityMailBoxRef::BASE, ekey_.typeID );
        this->putEntity( pStream, updateAutoLoad, &baseRef_ );
    }
    else
    {
        // 已存在实体:只写数据
        this->putEntity( pStream, updateAutoLoad );
    }
}
```

`flags` 是个位图,常见组合:

| flags | 场景 |
|-------|------|
| `WRITE_BASE_CELL_DATA` | 写实体数据(持久字段) |
| `WRITE_LOG_OFF` | 玩家下线,清除 mailbox |
| `WRITE_AUTO_LOAD_YES` | 设为自动加载(实体创建时) |
| `WRITE_AUTO_LOAD_NO` | 取消自动加载(实体销毁时) |
| `WRITE_DELETE_FROM_DB` | 从 DB 删除(配合 `deleteEntity()`) |
| `WRITE_EXPLICIT_DBID` | 用指定的 dbID(迁移场景) |

### 11.7.5 DeleteEntityHandler:删除实体

`DeleteEntityHandler` 的逻辑稍特殊——它先调 `getEntity` 看实体是否已被检出,再决定能否删除:

```cpp
// programming/bigworld/server/dbapp/delete_entity_handler.hpp:14
class DeleteEntityHandler : public GetEntityHandler,
                            public IDatabase::IDelEntityHandler
{
public:
    DeleteEntityHandler( EntityTypeID typeID, DatabaseID dbID,
        const Mercury::Address& srcAddr, Mercury::ReplyID replyID );

    void deleteEntity();

    // GetEntityHandler override
    virtual void onGetEntityCompleted( bool isOK,
            const EntityDBKey & entityKey,
            const EntityMailBoxRef * pBaseEntityLocation );

    // IDatabase::IDelEntityHandler override
    virtual void onDelEntityComplete( bool isOK );
};
```

"先查再删"的逻辑:如果实体已经被检出(有 mailbox),不能直接删——要先通知持有它的 BaseApp 卸载。这是为了防止"DB 里没了但内存里还在"的不一致。

### 11.7.6 look_up_*_handler 系列

这一组 Handler 都比较简单,主要负责"查询并回复":

| Handler | 接口 | 作用 |
|---------|------|------|
| `LookUpEntityHandler` | `IGetEntityHandler` + `IGetDbIDHandler` | 查单个实体的邮箱 |
| `LookUpDBIDHandler` | `IGetDbIDHandler` | 查 name→dbID 映射 |
| `LookUpEntitiesHandler` | `ILookUpEntitiesHandler` | 按属性批量查询 |

`LookUpEntitiesHandler` 比较有意思——它支持"按属性过滤"的查询,比如"找出所有 level > 50 的 Avatar"。这种查询在 MySQL 引擎里直接转成 SQL `WHERE` 子句,在 XML 引擎里只能全表扫描内存里的数据结构。

---

## 11.8 自动加载机制

### 11.8.1 为什么需要自动加载

考虑这个场景:服务器正常关停时,有 1000 个玩家在线。这些玩家的 Base 实体都在各自 BaseApp 的内存里,关停时 `BigWorld.saveEntity()` 把状态写到了 DB。服务器重启后,如果没有"自动加载"机制,这 1000 个玩家就静静地躺在 DB 里,需要每个玩家重新登录才会被加载——这对"服务器维护后无感恢复"是不可接受的。

`autoLoad` 标志解决这个问题:每个实体有个 `autoLoad` 布尔字段,标记"服务器重启时是否需要自动加载"。玩家角色的 `autoLoad=true`,临时 NPC 的 `autoLoad=false`。服务器启动时,DBApp Alpha 会扫描所有 `autoLoad=true` 的实体,把它们加载到合适的 BaseApp 上。

### 11.8.2 EntityAutoLoader 的实现

`EntityAutoLoader` 是个"批量并发加载器",代码在 `programming/bigworld/server/dbapp/entity_auto_loader.cpp`。它的核心设计:

```cpp
// programming/bigworld/server/dbapp/entity_auto_loader.hpp:16
class EntityAutoLoader : public IEntityAutoLoader
{
public:
    EntityAutoLoader();

    virtual void reserve( int numEntities );      // 预分配
    virtual void start();                          // 开始加载
    virtual void abort();                          // 中止
    virtual void addEntity( EntityTypeID entityTypeID, DatabaseID dbID );
    virtual void onAutoLoadEntityComplete( bool isOK );

private:
    void checkFinished();
    void sendNext();

    bool allSent() const { return numSent_ >= int(entities_.size()); }

    typedef BW::vector< std::pair< EntityTypeID, DatabaseID > > Entities;
    Entities    entities_;          // 待加载列表
    int         numOutstanding_;     // 当前在途数量
    int         maxOutstanding_;     // 最大并发数(配置)
    int         numSent_;            // 已发送数量
    bool        hasErrors_;
};
```

`maxOutstanding_` 来自配置 `DBAppConfig::maxConcurrentEntityLoaders()`,默认是个合理值(如 50)。这个并发控制很关键——如果有 10000 个实体要加载,一次性全部并发会让 BaseApp 瞬间过载。`EntityAutoLoader` 用"滑动窗口"模式:

```
初始:numOutstanding=0, maxOutstanding=50
   │
   ├── start() 一次性发出 50 个请求
   │     numOutstanding=50
   │
   ├── 每完成一个,onAutoLoadEntityComplete() 被回调
   │     numOutstanding-- → 49
   │     sendNext() → 发出下一个,numOutstanding=50
   │
   └── 全部发完(allSent()==true)且 numOutstanding==0
         → onEntitiesAutoLoadCompleted() 通知 DBApp
```

#### AutoLoadingEntityHandler 的状态机

每个实体的加载过程又是一个小状态机,由 `AutoLoadingEntityHandler` 实现:

```cpp
// programming/bigworld/server/dbapp/entity_auto_loader.cpp:55
enum State
{
    StateInit,
    StateWaitingForSetBaseToLoggingOn,   // 已设 mailbox 为"加载中"
    StateWaitingForCreateBase,            // 已请求 BaseAppMgr 创建 base
    StateWaitingForSetBaseToFinal         // 已设 mailbox 为最终位置
};
```

完整流程:

```
StateInit
   │
   ├── prepareCreateEntityBundle()  预构造 createBase 消息
   ├── getEntity()                   从 DB 读实体数据,流式写入 bundle
   ▼
[getEntity 完成]
StateWaitingForSetBaseToLoggingOn
   │
   ├── setBaseEntityLocation( LOGGING_ON )  在 DB 占住 mailbox
   ▼
[putEntity 完成]
StateWaitingForCreateBase
   │
   ├── 把 bundle 发给 BaseAppMgr,请求创建 base
   ▼
[BaseAppMgr 回复:base 已创建]
StateWaitingForSetBaseToFinal
   │
   ├── setBaseEntityLocation( 最终 baseRef )  更新 mailbox 为真实地址
   ▼
[putEntity 完成]
delete this  → 通知 EntityAutoLoader 一个完成
```

这个状态机的精妙之处在于:**每一步都是异步的,但通过状态机串联起来,逻辑清晰**。每一步都有对应的回调方法,出错时通过 `isOK_` 标志传递到 `mgr_.onAutoLoadEntityComplete()`。

### 11.8.3 与 BaseAppMgr 的协作

`EntityAutoLoader` 不直接选 BaseApp,而是通过 BaseAppMgr 分配。这是 BigWorld 的"控制平面"分工:

- **DBApp** 负责决定"哪些实体需要加载"和"实体数据是什么"。
- **BaseAppMgr** 负责决定"加载到哪个 BaseApp"——基于负载均衡。

DBApp 用 `prepareCreateEntityBundle()` 构造好消息,发给 BaseAppMgr;BaseAppMgr 选好 BaseApp 后,BaseApp 创建实体并回复 mailbox;DBApp 收到回复后,把最终 mailbox 写回 DB。这个协作通过 `AutoLoadingEntityHandler::handleMessage` 实现:

```cpp
// programming/bigworld/server/dbapp/entity_auto_loader.cpp:104
void AutoLoadingEntityHandler::handleMessage( const Mercury::Address & srcAddr,
        Mercury::UnpackedMessageHeader & header,
        BinaryIStream & data, void * )
{
    Mercury::Address proxyAddr;
    data >> proxyAddr;
    EntityMailBoxRef baseRef;
    data >> baseRef;
    data.finish();

    state_ = StateWaitingForSetBaseToFinal;

    DBApp & dbApp = DBApp::instance();
    dbApp.setBaseEntityLocation( ekey_, baseRef, *this );   // 写最终 mailbox

    if (dbApp.shouldCacheLogOnRecords())
    {
        dbApp.logOnRecordsCache().insert( ekey_, baseRef );  // 缓存
    }
}
```

`logOnRecordsCache` 是个性能优化——缓存"实体 → mailbox"的映射,后续登录请求可以先查缓存,避免每次都查 DB。

### 11.8.4 自动加载的工程价值

`EntityAutoLoader` 体现了几个工程上的考量:

1. **并发控制**:`maxOutstanding_` 限制并发,防止启动风暴。
2. **错误容忍**:某个实体加载失败不影响其他实体,`hasErrors_` 只记录"有错误",不中止整个流程。
3. **状态机清晰**:每个加载过程有明确的状态转移,便于调试。
4. **与控制平面协作**:DBApp 不直接选 BaseApp,通过 BaseAppMgr 做负载均衡。

这种"批量 + 并发限制 + 异步状态机"的模式,在分布式系统的"启动恢复"场景里非常常见——比如 Kafka 的分区重平衡、Elasticsearch 的分片恢复,都是类似的设计。

---

## 11.9 数据库同步工具

### 11.9.1 sync_db 工具

当你在 `entities.xml` 里加了新字段、改了字段类型、加了新实体类型,MySQL 里的表结构就需要同步更新。这个工作由 `sync_db` 工具完成,源码在 `programming/bigworld/server/tools/sync_db/`。

它的入口很简单:

```cpp
// programming/bigworld/server/tools/sync_db/main.cpp:25
int main( int argc, char * argv[] )
{
    ArgParser argParser( "sync_db" );
    argParser.add( "verbose", "Display verbose program output to the console" );
    argParser.add( "run-from-dbapp", "Flags if running within DBApp" );
    argParser.add( "dry-run", "Perform a trial run with no changes made" );
    argParser.add( "host", "MySql Host" );
    argParser.add( "port", "MySQL Port" );
    argParser.add( "database", "MySQL Database" );
    argParser.add( "username", "MySQL Username" );
    argParser.add( "password", "MySQL Password" );
    argParser.add( "secure-auth", "..." );

    // ...

    MySqlSynchronise mysqlSynchronise;
    if (!mysqlSynchronise.init( isVerbose, shouldLock, isDryRun, conn ))
    {
        return EXIT_FAILURE;
    }

    if (!mysqlSynchronise.run())
    {
        return EXIT_FAILURE;
    }

    return EXIT_SUCCESS;
}
```

注意几个有用的选项:

1. **`--dry-run`**:试运行,只打印要执行的 SQL,不真正修改。这对验证 `entities.xml` 改动是否正确非常有用。
2. **`--run-from-dbapp`**:标记本次同步是在 DBApp 启动流程里触发的(而非手动运行),影响是否加锁。
3. **`--verbose`**:打印详细日志,包括每条执行的 SQL。

### 11.9.2 MySqlSynchronise 的核心逻辑

`MySqlSynchronise`(`programming/bigworld/server/tools/sync_db/mysql_synchronise.hpp`)是同步的核心类:

```cpp
// programming/bigworld/server/tools/sync_db/mysql_synchronise.hpp:14
class MySqlSynchronise : public DatabaseToolApp
{
public:
    bool init( bool isVerbose, bool shouldLock, bool isDryRun,
        DBConfig::ConnectionInfo & connectionInfo );
    bool run();

    bool synchroniseEntityDefinitions( bool allowNew,
        const BW::string & characterSet = "",
        const BW::string & collation = "" );

private:
    bool doSynchronise();
    void createSpecialBigWorldTables();      // 创建 BW 内部表(如 sm_*)
    bool updatePasswordHash( bool wasHashed );
    bool alterDBCharSet( const BW::string & characterSet,
        const BW::string & collation );
    bool isDryRun_;
};
```

`run()` 内部做的事情:

1. **`synchroniseEntityDefinitions()`**:对每个实体类型,检查 MySQL 里有没有对应的表,字段是否匹配,缺的建,多的(谨慎)删,类型不一致的 `ALTER`。
2. **`createSpecialBigWorldTables()`**:创建 BigWorld 内部用的表,比如 `bigworldEntityDefs`(记录实体定义的 digest,用于检测实体定义变化)、`sm_*` 表(二级数据库注册)。
3. **`updatePasswordHash()`**:如果密码哈希算法升级,迁移已有数据。
4. **`alterDBCharSet()`**:修改数据库字符集(从 latin1 升级到 utf8 等)。

### 11.9.3 mysql_table_initialiser 与 mysql_upgrade_database

这两个文件是 sync_db 的子模块:

- **`mysql_table_initialiser.cpp`**:负责"建新表"。当 `entities.xml` 里出现一个新实体类型时,根据其 persistent 字段定义生成 `CREATE TABLE` 语句。
- **`mysql_upgrade_database.cpp`**:负责"升级已有表"。当字段类型变化、字段增减时,生成 `ALTER TABLE` 语句。

这两个子模块的设计原则是**非破坏性**——`ALTER TABLE` 时尽量用 `ADD COLUMN` 而不是 `DROP COLUMN`,避免误删数据。删除字段需要运维手动执行 SQL,这是 BigWorld 在"易用性 vs 安全性"上的取舍。

### 11.9.4 EntityDefs digest 的一致性校验

`sync_db` 还做一件重要的事:**校验实体定义的 digest**。`EntityDefs::getDigest()` 会根据 `entities.xml` 的内容算一个哈希,存到 MySQL 的 `bigworldEntityDefs` 表里。每次 DBApp 启动或 `sync_db` 运行时,会比对当前 digest 与数据库里存的:

- 不匹配 → 报错,提示运维先跑 `sync_db`。
- 匹配 → 正常启动。

这是个"防呆设计"——避免 DBApp 用新版本的 `entities.xml` 启动,但 MySQL 表结构还是旧的,导致运行时 SQL 错误。

### 11.9.5 与 DBApp 启动流程的集成

DBApp 启动时,如果检测到 MySQL 表结构与 `entities.xml` 不匹配,会拒绝启动并提示:

```
ERROR: Entity definitions digest mismatch.
       Expected: <hash1>, in DB: <hash2>
       Please run sync_db to update the database schema.
```

`sync_db` 既可以手动运行,也可以在 DBApp 启动流程里自动触发(通过 `--run-from-dbapp` 标志)。生产环境通常推荐手动运行,因为它会修改表结构,需要运维确认。

---

## 11.10 特色实现深度剖析

### 11.10.1 双引擎抽象:Strategy + 链接期注册

BigWorld 的双引擎设计是教科书级的 Strategy 模式应用,但有个工程上的巧思:**链接期注册**。

传统的 Strategy 模式通常这样写:

```cpp
// 传统写法
if (type == "mysql")
    return new MySqlDatabase();
else if (type == "xml")
    return new XMLDatabase();
else
    return nullptr;
```

这种写法的问题:每加一个新引擎,都要修改 `DBApp::initDatabaseCreation()`,违反开闭原则。BigWorld 的写法是:

```cpp
// BigWorld 的写法
// 1. 引擎自己写一个 Creator,在 .cpp 里放一个静态对象
class MySqlEngineCreator : public DatabaseEngineCreator { /* ... */ };
namespace { MySqlEngineCreator staticInitialiser; }   // 链接即注册

// 2. DBApp 用统一的工厂方法
pDatabase_ = DatabaseEngineCreator::createInstance( type, data );
```

**关键点**:那个匿名命名空间里的 `staticInitialiser` 是"链接期注册"的核心。只要这个 `.cpp` 文件被链接进可执行文件,它的 Creator 就自动注册到全局表;不链接就不注册,完全零开销。这种模式让"新增引擎"成了"加一个新文件 + 链接"的事,不需要改任何现有代码。

同样的模式也用在 `BillingSystemCreator` 上——Standard、Custom、BWAuth 三种计费后端都是通过链接期注册的 Creator 加入的。

### 11.10.2 二级数据库的性能权衡

二级数据库是个"以复杂性换性能"的典型设计。我们用一个简单的数字估算来说明:

假设一个 MMOG 有 10000 在线玩家,每个玩家平均每 10 秒触发一次 `saveEntity`(位置变化、状态更新)。这意味着:

- **不用二级库**:每秒 1000 次主库写入,主库 QPS = 1000。
- **用二级库**:每秒 1000 次二级库写入(分散到 100 个 BaseApp,每个 10 次/秒),主库每 10 分钟合并一次,合并时 QPS 突刺 = 60000(但只持续几秒)。

对于 2003 年的 MySQL,1000 QPS 是有压力的;二级库把压力"削峰填谷"。但对于现代 MySQL(SSD + InnoDB + 连接池),1000 QPS 完全不是问题,二级库的复杂性收益就不划算了。

BigWorld 在 14.x 版本保留了二级库但允许 `shouldConsolidate=false` 关闭,这是个务实的折中。**新手项目建议直接关闭二级库**,等真有性能瓶颈再开。

### 11.10.3 自动加载的工程价值

`EntityAutoLoader` 看似简单,但它体现了一个重要的工程理念:**故障恢复应该是自动的,而不是手动的**。

考虑没有自动加载的场景:服务器宕机重启后,运维要手动跑脚本把所有"应该在线"的玩家实体加载回来,还要保证负载均衡,还要处理加载失败的情况。这个过程又慢又容易出错。

`EntityAutoLoader` 把这一切自动化了:

1. **自动扫描**:`IDatabase::autoLoadEntities()` 扫描所有 `autoLoad=true` 的实体。
2. **并发控制**:`maxOutstanding_` 限制并发,防止启动风暴。
3. **负载均衡**:通过 BaseAppMgr 分配,自动均衡到各 BaseApp。
4. **错误容忍**:单个实体加载失败不影响整体,只记录 `hasErrors_`。

这种"故障自动恢复"的能力是 MMOG 服务器的基本要求——玩家不应该感知到"服务器重启了"。`EntityAutoLoader` 让这件事对脚本层完全透明,体现了 BigWorld 在运维体验上的考究。

### 11.10.4 与 BaseApp 的透明持久化

最后说说"透明持久化"的设计哲学。从 BaseApp 的 Python 脚本视角看,持久化是这么用的:

```python
# BaseApp 的 Python 脚本
class Avatar( BigWorld.Base ):
    def onSave( self ):
        BigWorld.saveEntity( self )      # 保存自己

    def onLoad( self, dbID ):
        # 实体从 DB 加载回来,这个方法被调用
        pass

    def onDestroy( self ):
        BigWorld.destroyEntity( self )   # 从 DB 删除
```

脚本完全不需要知道:

- 数据存到 MySQL 还是 XML?
- 是同步还是异步?
- 经过哪些 Handler?
- mailbox 是怎么管理的?

这种"透明性"是通过 `IDatabase` 抽象 + Handler 模式 + 异步回调链实现的。每一层都只关心自己的职责:

- **脚本层**:关心"什么时候保存、保存什么"。
- **BaseApp**:关心"序列化、网络传输、回复处理"。
- **DBApp**:关心"路由到 Handler、调用引擎、管理 mailbox"。
- **IDatabase**:关心"实际存储、读取、查询"。
- **MySQL/XML**:关心"具体存储格式"。

这种分层让每一层都可以独立演进——比如未来要加 PostgreSQL 引擎,只需要写一个新的 `IDatabase` 实现 + Creator,其他层完全不用动。这是 BigWorld 在 2003 年的设计就具备的"面向未来"的架构能力。

---

## 11.11 本章小结

本章我们深入剖析了 BigWorld 的数据持久化核心进程——DBApp。回顾要点:

1. **DBApp 是数据平面的最底层**,持有 `IDatabase` 实例,执行所有实体的持久化、查询、登录认证。DBAppMgr 是它的控制平面,负责进程生命周期与哈希分片。

2. **双存储引擎架构**是 Strategy 模式的经典应用:XML 引擎用于开发演示,MySQL 引擎用于生产。通过 `IDatabase` 抽象 + `DatabaseEngineCreator` 链接期注册,引擎切换只需改配置,代码零修改。

3. **实体持久化流程**通过 Handler 模式实现:BaseApp 发 `writeEntity`/`loadEntity` 消息 → DBApp new 一个 Handler → Handler 调 `IDatabase` 异步方法 → 回调完成后回复。每个 Handler 是个独立的小状态机。

4. **二级数据库**是 BigWorld 为应对 MySQL 性能瓶颈的写入缓冲设计:BaseApp 写本地 SQLite,定期合并到主 MySQL。`consolidate_dbs` 工具负责合并,`transfer_db` 负责传输。现代场景可关闭。

5. **登录认证**通过 `BillingSystem` 抽象 + `LoginHandler` 状态机实现。`BillingSystem` 支持 Standard(脚本优先,引擎兜底)、Custom、BWAuth 三种后端,让游戏可以灵活接入自家计费系统。

6. **快照机制**通过 `snapshot_helper` 工具实现,利用 LVM 做文件系统级快照,配合 MySQL `FLUSH TABLES WITH READ LOCK` 保证一致性。配合 `transfer_db` 传输,构成完整的备份方案。

7. **自动加载机制**通过 `EntityAutoLoader` 实现:服务器启动时扫描 `autoLoad=true` 的实体,用滑动窗口并发加载,通过 BaseAppMgr 分配到各 BaseApp,实现"服务器重启后无感恢复"。

8. **数据库同步工具 sync_db** 负责把 `entities.xml` 的实体定义同步到 MySQL 表结构,支持 `--dry-run` 试运行、digest 一致性校验,防止实体定义与表结构不匹配导致运行时错误。

DBApp 的设计有几个值得借鉴的工程思想:

- **抽象优先**:`IDatabase`、`BillingSystem`、`DatabaseEngineCreator` 都是抽象,让具体实现可替换。
- **链接期注册**:用静态对象的构造副作用做注册,零运行时开销,符合开闭原则。
- **Handler 模式**:每消息一个 Handler 对象,无状态、可并发、易理解。
- **异步状态机**:用回调 + 状态枚举串联异步流程,比线程同步更轻量。
- **透明持久化**:让脚本层不感知存储细节,只关心业务逻辑。

理解了 DBApp,你就理解了 BigWorld 如何把"游戏世界"和"持久存储"解耦——游戏逻辑在 BaseApp/CellApp 里跑,持久状态在 DBApp 里存,两者通过清晰的 Mercury 消息接口协作。这种解耦让 BigWorld 可以支持从单机 demo 到大规模 MMOG 的各种部署形态,是它能在 20 年后依然有参考价值的核心原因之一。

下一章我们将探讨 CellAppMgr 与空间分配,继续深入 BigWorld 的服务器集群管理。