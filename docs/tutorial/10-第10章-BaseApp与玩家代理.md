# 第10章 BaseApp 与玩家代理

> 在第 7 章的集群拓扑里,我们曾把 BaseApp 形容为"客户端与服务器之间的最后一公里"——所有玩家发出的命令都要经过它,所有下发给客户端的状态都要先汇总到它。但 BaseApp 远不止是一个"路由器":它把每个玩家"代理"为一个驻留服务器侧的 Python 对象(`Base`/`Proxy`),让游戏逻辑可以以"面向对象"的方式处理远程客户端;它通过 `Mailbox` 系统屏蔽了"对象到底在哪个进程"的细节;它通过双因子认证 + 断线重连 + 主备备份三套机制,保证玩家在线体验不会因一次网络抖动或进程崩溃而中断。本章将带你看懂这座"虚拟世界与真实玩家之间的桥梁"。

---

## 目录

- [10.1 BaseApp 概述](#101-baseapp-概述)
- [10.2 Base 实体概念](#102-base-实体概念)
- [10.3 客户端连接管理](#103-客户端连接管理)
- [10.4 Mailbox 系统](#104-mailbox-系统)
- [10.5 BaseApp 核心](#105-baseapp-核心)
- [10.6 实体管理](#106-实体管理)
- [10.7 客户端代理流程](#107-客户端代理流程)
- [10.8 断线重连机制](#108-断线重连机制)
- [10.9 Base 备份与故障切换](#109-base-备份与故障切换)
- [10.10 特色实现深度剖析](#1010-特色实现深度剖析)
- [10.11 本章小结](#1011-本章小结)

---

## 10.1 BaseApp 概述

### 10.1.1 进程定位

如果你用一句话向新手介绍 BaseApp,最贴切的描述是:**"BaseApp 是 BigWorld 服务器集群里唯一一个直接面对客户端的进程"**。当然,LoginApp 也接客户端,但 LoginApp 只负责"门口验票",验完票就把客户端"移交"给 BaseApp;真正承载玩家游戏会话、执行玩家相关业务逻辑、维护玩家长期状态的是 BaseApp。

BigWorld 把"游戏世界"按空间切分到多个 CellApp(详见第 9 章),每个 CellApp 只看到世界的一部分;但"玩家"不能被空间切分——一个玩家只有一个"会话主体"。这个"会话主体"就放在 BaseApp 上。因此 BaseApp 在集群中的位置非常独特:

```
                客户端
                  │ (TCP+UDP)
                  ▼
            ┌───────────┐
            │  BaseApp  │ ← 玩家会话的"主"
            │  (Proxy)  │
            └─────┬─────┘
                  │
       ┌──────────┼──────────┐
       ▼          ▼          ▼
   ┌───────┐ ┌───────┐ ┌────────┐
   │CellApp│ │CellApp│ │ DBApp  │
   └───────┘ └───────┘ └────────┘
```

BaseApp 与客户端之间是 TCP/UDP 连接,与 CellApp/DBApp 之间是 BigWorld 自己的 Mercury UDP 通信。BaseApp 不持有空间数据(地图、AOI),只持有"玩家的代理 + 玩家可见的其他实体的代理"。

### 10.1.2 源码位置

BaseApp 的源码全部位于 `programming/bigworld/server/baseapp/` 目录,共 70+ 个文件。其中最关键的几个文件:

| 文件 | 行数 | 职责 |
|------|------|------|
| `baseapp.hpp` / `baseapp.cpp` | 470 / 3246 | 主类 `BaseApp`,进程入口与所有消息处理 |
| `base.hpp` / `base.cpp` | 470 / 2700+ | `Base` 类,所有 BaseApp 侧实体的基类 |
| `proxy.hpp` / `proxy.cpp` | 770 / 3300+ | `Proxy` 类,有客户端连接的 Base |
| `mailbox.hpp` | 200+ | ServerEntityMailBox 继承体系 |
| `bases.hpp` | 100+ | `Bases` 容器(map<EntityID, Base*>) |
| `backup_sender.hpp` | 75 | `BackupSender`,周期备份 |
| `archiver.hpp` | 50+ | `Archiver`,周期归档到 DBApp |
| `pending_logins.hpp` | 100+ | `PendingLogins`,登录中转 |
| `login_handler.hpp` | 60 | `LoginHandler`,客户端认证 |
| `client_entity_mailbox.hpp` | — | `ClientEntityMailBox`,向客户端发消息 |

整个 BaseApp 的代码量在 BigWorld 各进程中是最大的——`baseapp.cpp` 3246 行、`proxy.cpp` 3300+ 行、`base.cpp` 2700+ 行——这从侧面印证了 BaseApp 的"复杂度之最"地位。

### 10.1.3 与 BaseAppMgr 的关系

BigWorld 服务器集群采用**控制平面 + 数据平面**分层架构,BaseApp 与 BaseAppMgr 的关系是这一架构的典型代表:

- **BaseAppMgr**:控制平面,**单例**,不持有任何游戏实体,只管理 BaseApp 进程的生命周期、负载均衡、备份哈希、全局 Base 邮箱重定向。
- **BaseApp**:数据平面,**多实例**,可水平扩展,持有实际的 Base/Proxy 实体,处理客户端连接。

这两者的关系可以类比 Kubernetes 中的 `kube-controller-manager` 与 `kubelet`:BaseAppMgr 是"控制器",负责"该开几个 BaseApp、该把哪个 Base 放到哪个 BaseApp、哪个 BaseApp 死了让谁接管";BaseApp 是"工作节点",只负责执行。

```
┌──────────────────────────────────────────────────────────────────┐
│ 控制平面 (单例)                                                  │
│   ┌──────────────────────┐                                       │
│   │   BaseAppMgr         │  - 管理 BaseApp 生命周期              │
│   │ - 子集管理 (Base/Svc)│  - 三层负载均衡                       │
│   │ - BackupHash 维护    │  - 过载保护与登录准入                  │
│   │ - GlobalBases 重定向 │  - 受控关停                           │
│   └──────────┬───────────┘                                       │
└──────────────┼───────────────────────────────────────────────────┘
               │ 注册/回复/汇报
               ▼
┌──────────────────────────────────────────────────────────────────┐
│ 数据平面 (多实例,可水平扩展)                                    │
│   ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐  │
│   │   BaseApp #1    │  │   BaseApp #2    │  │   ServiceApp    │  │
│   │ - Proxy (客户端)│  │ - Proxy         │  │ - 不接客户端    │  │
│   │ - Base 实体     │  │ - Base 实体     │  │ - 只跑脚本      │  │
│   │ - BackupSender  │  │ - BackedUpBaseApp│  │ - 全局服务      │  │
│   │ - Archiver      │  │ - Archiver      │  │                 │  │
│   └────────┬────────┘  └────────┬────────┘  └────────┬────────┘  │
└────────────┼─────────────────────┼────────────────────┼──────────┘
             │                     │                    │
             ▼                     ▼                    ▼
   ┌─────────────────────────────────────────────────────────────┐
   │ 依赖进程:DBApp(持久化)、CellApp(实体 Ghost/AOI)、LoginApp   │
   └─────────────────────────────────────────────────────────────┘
```

BaseApp 启动后会向 BaseAppMgr 发 `add` 消息注册自己,带上自己的 ID、外部地址、是否为 ServiceApp 等信息;BaseAppMgr 收到后,把 BaseApp 纳入"已注册"子集,并把当前的 BackupHash 下发回去。BaseApp 此后每 tick 都会向 BaseAppMgr 汇报负载(`load`/`numBases`/`numProxies`),BaseAppMgr 据此做负载均衡决策。当 BaseAppMgr 决定把某 BaseApp 关停或迁移时,会下发 `controlledShutDown` 或 `retireApp` 命令。

---

## 10.2 Base 实体概念

### 10.2.1 实体的"分层":Base 与 Cell

BigWorld 把一个"游戏实体"分成两个独立的"半身":

- **Base**(持久部分):驻留在 BaseApp 上,持有实体的"持久属性"(账号、库存、技能等),不关心空间位置;**只要玩家在线,Base 就存在**。
- **Cell**(空间部分):驻留在 CellApp 上,持有实体的"空间属性"(位置、方向、AOI),可被多个 CellApp 上的 Ghost 复制;**实体的空间部分可随负载均衡在 CellApp 间迁移,与 Base 无关**。

这种分层是 BigWorld 区别于传统 MMO 服务器的核心设计。它的好处是:

1. **空间与持久解耦**:玩家从地图 A 走到地图 B,只是 Cell 实体从一个 CellApp 迁到另一个 CellApp,Base 不动;玩家下线时,Cell 实体销毁(节省 Cell 内存),Base 持久化到 DB 后销毁。
2. **客户端代理统一**:无论玩家在哪个 CellApp,客户端只和 BaseApp 通信,客户端不需要知道 CellApp 的存在。
3. **故障隔离**:CellApp 崩了,玩家 Base 还在,只是暂时"看不到空间",可以从其他 CellApp 的 Ghost 恢复或重建;BaseApp 崩了,有 Backup 接管,玩家几乎无感。

> **重要澄清**:BaseApp 侧**不存在独立的 `Entity` 类**。`Entity` 类仅存在于 CellApp(`server/cellapp/entity.hpp`)、客户端(`client/entity.hpp`)和 bots 测试进程(`server/bots/entity.hpp`)。BaseApp 侧的实体层次是 `PyObjectPlus → Base → Proxy`,通过 `typedef Base BaseOrEntity` 复用 `Base` 作为 `BaseOrEntity`(在其他进程中 `BaseOrEntity` 是 `Entity`)。

### 10.2.2 Base 类源码

`Base` 类(`base.hpp:58`)继承自 `PyObjectPlus`(即 Python 对象基类),这意味着每个 Base 实例既是一个 C++ 对象,也是一个 Python 对象,可以被脚本直接操作。它的核心成员(`base.hpp`):

```cpp
class Base : public PyObjectPlus
{
    Py_Header( BW_NAMESPACE Base, PyObjectPlus )

public:
    Base( EntityID id, DatabaseID dbID, EntityTypePtr pType );

    EntityID       id() const         { return id_; }
    DatabaseID     databaseID() const { return databaseID_; }
    EntityType *   pType() const      { return pType_; }
    PyCellData *   pCellData() const  { return pCellData_; }
    CellEntityMailBox * pCellEntityMailBox() const { return pCellEntityMailBox_; }
    SpaceID        spaceID() const    { return spaceID_; }
    Mercury::Channel * pChannel() const { return pChannel_; }

    // 状态机
    bool isCreateCellPending() const  { return isCreateCellPending_; }
    bool isGetCellPending() const     { return isGetCellPending_; }
    bool isDestroyCellPending() const { return isDestroyCellPending_; }

    // 方法调用
    void callBaseMethod( int methodID, BinaryIStream & data );
    void callCellMethod( int methodID, BinaryIStream & data );

    // 生命周期
    bool createCellEntity( const ServerEntityMailBoxPtr & pNearbyMB );
    void destroy( bool deleteFromDB, bool writeToDB, bool logOffFromDB = true );
    void discard( bool isOffload = false );

    // 持久化
    bool writeToDB( WriteDBFlags flags, WriteToDBReplyHandler * pHandler = NULL,
            PyObjectPtr pCellData = NULL, DatabaseID explicitDatabaseID = 0 );

    // 备份与迁移
    void writeBackupData( BinaryOStream & stream, bool isOffload );
    void offload( const Mercury::Address & dstAddr );
    void readBackupData( BinaryIStream & stream );

private:
    EntityID        id_;
    DatabaseID      databaseID_;
    EntityType *    pType_;
    PyCellData *    pCellData_;
    CellEntityMailBox * pCellEntityMailBox_;
    SpaceID         spaceID_;
    Mercury::Channel * pChannel_;
    // ...
};

typedef Base BaseOrEntity;
```

几个关键字段需要重点理解:

- `id_`(`EntityID`,通常 32 位整数):全局唯一实体 ID,由 DBApp Alpha 批量分配。同一实体的 Base 与 Cell 共享同一 `id_`,这是它们"互相找到对方"的钥匙。
- `databaseID_`:数据库主键,只有"从数据库加载或写入过数据库"的实体才有(初始为 0,写入 DB 后由 DBApp 分配)。`hasWrittenToDB()` / `hasFullyWrittenToDB()` 反映其状态。
- `pCellData_`:Cell 端属性的"快照",由 Base 在 `createCellEntity` 时序列化传给 CellApp;也用于 `writeToDB` 时把 Cell 状态写回。
- `pCellEntityMailBox_`:**指向 Cell 实体的邮箱**。Base 通过这个 Mailbox 调用 Cell 端方法,Cell 也通过对应的 Base Mailbox 调用 Base 端方法。Mailbox 的概念详见 10.4 节。

### 10.2.3 Base 生命周期

Base 的生命周期从"被创建"到"被销毁",中间可能经历多次"创建 Cell / 销毁 Cell / 迁移 / 备份恢复"。完整状态机如下:

```
                  创建
                   │
                   ▼
        ┌─────────────────────┐
        │  Base 已创建        │ ◀─────────────┐
        │  (无 Cell)          │               │
        └──────────┬──────────┘               │
                   │ createCellEntity         │ onLoseCell
                   ▼                          │
        ┌─────────────────────┐               │
        │  Base + Cell        │ ─────────────┘
        │  (有空间实体)        │
        └──────────┬──────────┘
                   │ destroy
                   ▼
        ┌─────────────────────┐
        │  Base 销毁中         │
        │  (写 DB / 删 DB)     │
        └─────────────────────┘
```

Base 的创建路径有五种(`entity_creator.hpp`):

| 方法 | 触发场景 |
|------|---------|
| `createBaseLocally` | Python `BigWorld.createBase` 在本 BaseApp 创建 |
| `createBaseRemotely` | 在其他 BaseApp 创建(基于候选列表) |
| `createBaseAnywhere` | 自动选择本地或远程 |
| `createBaseFromDB` | 从数据库加载并创建(玩家登录/autoLoad) |
| `createBaseFromStream` | 从流恢复(用于备份恢复/offload 接收) |

销毁路径(`base.cpp` 中的 `destroy` / `discard`):

```cpp
// Python 主动销毁
void Base::destroy( bool deleteFromDB, bool writeToDB, bool logOffFromDB = true )
{
    // 1. 若有 cell,先销毁 cell 实体
    // 2. destroyCell 完成后回调 onDestroyCellComplete
    // 3. writeToDB(若需要)
    // 4. logOffFromDB(若需要,从 DB 注销)
    // 5. discard()
}

// 立即销毁,不写 DB(offload 时用)
void Base::discard( bool isOffload = false )
{
    // 1. 从 Bases 容器移除
    // 2. delete this(触发 Python 析构)
}
```

### 10.2.4 Base 的持久化

Base 的持久化是**两阶段**的,因为 Cell 数据需要先从 CellApp 取回:

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

注意"两阶段"不是事务的两阶段提交,而是"取数据 + 写数据"两个异步步骤。中间若发生故障,Backup 机制保证数据不丢。

---

## 10.3 客户端连接管理

### 10.3.1 TCP/UDP 双接口

BaseApp 是集群中唯一同时持有**两个网络接口**的进程:

```cpp
// baseapp.hpp:381-382
Mercury::NetworkInterface    extInterface_;   // 外部接口(与 LoginApp/Client)
Mercury::NetworkInterface    intInterface_;   // 内部接口(与 BaseAppMgr/CellApp/DBApp)
```

这两个接口分别监听不同端口,使用不同的 Mercury Interface 定义:

- `intInterface_`:注册 `BaseAppIntInterface`,处理来自 BaseAppMgr/CellApp/DBApp/其他 BaseApp 的内部消息(createBase、callBaseMethod、backupBaseEntity 等)。
- `extInterface_`:注册 `BaseAppExtInterface`,处理来自客户端的消息(callClientMethod 的反向、tickSync、move 等)。

为什么内部外部要分开?最核心的原因是**安全隔离**——外部接口必须暴露在公网,内部接口只能在集群内网访问。如果合用一个接口,客户端可以伪造 BaseAppMgr 的消息源地址,直接调用 `createBase` 等危险操作。分开接口后,内网端口不对外暴露,从网络层就阻断了这种攻击。

另外,BaseApp 还持有一个 `Mercury::TCPServer`(`baseapp.hpp:463`):

```cpp
Mercury::TCPServer    tcpServer_;
```

这是为 WebSocket 客户端(如 Web 端游戏)准备的 TCP 通道。原生 BigWorld 客户端用 UDP,Web 客户端用 TCP/WebSocket。

### 10.3.2 连接认证:sessionKey 与 loginKey 双因子

BigWorld 客户端登录采用**两步认证**:

1. **LoginApp 阶段**:客户端先用账号密码登录 LoginApp(详见第 12 章),LoginApp 把请求转发给 DBApp,验证账号后,生成一个 `loginKey`(短期,登录时用),并把客户端"分配"到某个 BaseApp。
2. **BaseApp 阶段**:客户端拿到 `loginKey` 后,直接连接 BaseApp 的 `extInterface_`。BaseApp 收到客户端的 `baseAppLogin` 消息,验证 `loginKey`,验证通过后建立 `Proxy` 与客户端的 Channel 绑定。

`loginKey` 是一次性的,只在 LoginApp → BaseApp 之间的"握手"过程中使用。握手成功后,BaseApp 会生成一个**长期**的 `sessionKey`(`proxy.hpp`):

```cpp
class Proxy : public Base
{
public:
    void regenerateSessionKey();

    SessionKey sessionKey() const { return sessionKey_; }

private:
    SessionKey  sessionKey_;  // 用于重登录
    // ...
};
```

`sessionKey` 的作用是**重登录**:当客户端掉线重连时,不需要重新走一遍 LoginApp 的账号密码验证,只需向 BaseApp 出示 `sessionKey` 即可恢复会话。这一机制的工程价值详见 10.8 节。

### 10.3.3 断线检测

BaseApp 与客户端之间的连接是 Mercury 的 UDP Channel(详见第 5 章),Channel 自带**心跳机制**:

- Channel 双方定期发送 `tickSync` 消息(默认每 tick 一次,即每 100ms)。
- 若一段时间(默认 30 秒,可配置 `BaseAppConfig::externalEntityTime`)未收到对方任何消息,判定为"断线"。
- 断线后,BaseApp 触发 `Proxy::onClientDeath`,根据断线原因走不同流程(详见 10.8 节)。

`Proxy` 持有 `inactivityTimeout_`(不活跃超时)和 `Wards`(守护机制):

```cpp
class Proxy : public Base
{
private:
    Wards           wards_;              // 多个"看门狗"
    LatencyTriggers latencyTriggers_;   // 延迟触发器
    float           inactivityTimeout_; // 不活跃超时(默认 30 秒)
};
```

`Wards` 机制允许"多个 CellApp 共同守护一个 Proxy",只要任意一个 CellApp 还在向 Proxy 报告 witness,Proxy 就不会被判定为"失联"——这是为多 witness 场景(如跨 Cell 边界移动)设计的容错。

### 10.3.4 客户端实体同步

BaseApp 向客户端同步其他实体状态是**通过 CellApp 的 witness 机制**完成的:

```
            客户端
              │
              ▼ (1) 玩家移动
        ┌───────────┐
        │  BaseApp  │
        │  (Proxy)  │
        └─────┬─────┘
              │ (2) 转发给 CellApp
              ▼
        ┌───────────┐
        │  CellApp  │
        │  (witness)│
        └─────┬─────┘
              │ (3) AOI 计算后,把"可见实体"的属性变化发回 BaseApp
              ▼
        ┌───────────┐
        │  BaseApp  │
        │  (Proxy)  │
        └─────┬─────┘
              │ (4) 转发给客户端
              ▼
            客户端
```

注意:**BaseApp 不做 AOI 计算**——它不知道"哪些实体在玩家视野内"。AOI 是 CellApp 的职责(详见第 9 章)。BaseApp 只是把 CellApp 算出来的"该下发给客户端的实体属性变化"转发给客户端,反之亦然。

这种分工让 BaseApp 的负载更可预测:无论玩家在多密集的场景里,BaseApp 的工作量只与"客户端能感知到的实体数量"成正比,而不与"场景里实体总数"成正比。

---

## 10.4 Mailbox 系统

### 10.4.1 Mailbox 概念

`Mailbox`(邮箱)是 BigWorld 实现跨进程方法调用的核心抽象。它的核心理念可以用一句话概括:**"Mailbox 是一个'对象引用',你拿到它就能调它的方法,但不需要知道它具体在哪个进程"**。

类比一下 Python 的远程调用:

```python
# 不用 Mailbox 的世界:你需要显式知道目标在哪
cell_app_addr = "192.168.1.10:30000"
entity_id = 12345
send_message(cell_app_addr, "callMethod", entity_id, method_id, args)

# 用 Mailbox 的世界:你只需要一个对象引用
cell_mb = some_base.cellEntityMailBox  # 这就是个 Mailbox
cell_mb.moveTo(position)               # 调用方法,框架自动路由
```

`Mailbox` 让分布式代码读起来像本地代码——这是 BigWorld 的"分布式 OO"哲学。

### 10.4.2 ServerEntityMailBox 继承体系

BaseApp 侧的 Mailbox 体系定义在 `mailbox.hpp`:

```cpp
// mailbox.hpp
class ServerEntityMailBox: public PyEntityMailBox
{
    // 通用基类:知道目标在哪个进程
    virtual const Mercury::Address  address() const     { return addr_; }
    virtual EntityID                id() const          { return id_; }
    virtual EntityMailBoxRef::Component component() const = 0;

protected:
    Mercury::Address    addr_;     // 目标进程地址
    EntityID             id_;       // 目标实体 ID
    EntityTypePtr       pLocalType_;
};

class CommonCellEntityMailBox : public ServerEntityMailBox
{
    // Cell 邮箱的通用部分(主要是 channel 获取逻辑)
};

class CellEntityMailBox : public CommonCellEntityMailBox
{
    // BaseApp 侧持有的 Cell 邮箱
    // 调用方法 → 经 intInterface_ 路由到目标 CellApp
};

class BaseEntityMailBox : public ServerEntityMailBox
{
    // 其他进程(CellApp/其他 BaseApp)持有的 Base 邮箱
    // 调用方法 → 路由到目标 BaseApp
};
```

另外,在 `client_entity_mailbox.hpp` 中还有:

```cpp
class ClientEntityMailBox : public EntityMailBox
{
    // BaseApp 侧持有的客户端邮箱(让 Base 能调客户端方法)
    // 调用方法 → 经 extInterface_ 路由到客户端
};
```

### 10.4.3 三种 Mailbox 的对应关系

每个 Base 实例最多同时持有三种 Mailbox,分别对应"实体的三个化身":

| Mailbox 类型 | 持有者 | 指向 | 用途 |
|-------------|--------|------|------|
| `CellEntityMailBox` | Base | 同一实体的 Cell 部分 | Base 调 Cell 方法(`callCellMethod`) |
| `BaseEntityMailBox` | 其他进程 | 同一实体的 Base 部分 | CellApp/其他 BaseApp 调 Base 方法(`callBaseMethod`) |
| `ClientEntityMailBox` | Proxy | 客户端"自己"的 Proxy | Base 调客户端方法(下发状态) |

一个完整的"玩家 Proxy"同时持有这三种 Mailbox 中的两种(`pCellEntityMailBox_` 和 `pClientEntityMailBox_`),而它自己的 `BaseEntityMailBox` 则被其他进程(CellApp 上的 cell 实体、其他 BaseApp 上的相关实体)持有。

Mailbox 的"双向性"是理解 Base/Cell 通信的关键:`Base.pCellEntityMailBox.cellMethod()` 从 Base 发到 Cell;而 Cell 端持有的 `BaseEntityMailBox.baseMethod()` 从 Cell 发回 Base。它们走的是同一条逻辑通道,但方向相反。

### 10.4.4 Mailbox 的透明性

Mailbox 的"透明性"体现在两个层面:

1. **位置透明**:`cell_mb.moveTo(pos)` 这一行代码,无论目标 Cell 实体是在本机 CellApp、远程 CellApp、还是已经被迁移到另一台机器的 CellApp,代码都不变。Mailbox 内部根据 `addr_` 自动路由。
2. **故障透明**:当某 BaseApp 死亡时,所有指向它的 `BaseEntityMailBox` 都会自动失效。`ServerEntityMailBox::adjustForDeadBaseApp` 静态方法负责这一处理:

```cpp
// mailbox.hpp
static void adjustForDeadBaseApp( const Mercury::Address & deadAddr,
        const BackupHashChain & hash );
```

它遍历所有 Mailbox,把指向死亡 BaseApp 的 Mailbox 重定向到 Backup BaseApp(基于 BackupHash 找到接管者)。这一过程对游戏脚本完全透明——脚本不需要知道"我的目标 BaseApp 死了,要换个 Mailbox"。

---

## 10.5 BaseApp 核心

### 10.5.1 BaseApp 类与四重继承链

`BaseApp` 类(`baseapp.hpp:71`)的继承链是 BigWorld 中最长的之一:

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

每一层基类提供一组能力,`BaseApp` 在最末端组合它们。这种"组合优于继承"的风格在 BigWorld 中很常见——每一层都只关注自己的职责,修改某一层不会影响其他层。

```cpp
class BaseApp : public EntityApp,
    public TimerHandler,
    public Mercury::ChannelListener,
    public Singleton< BaseApp >
{
public:
    typedef BaseAppConfig Config;
    SERVER_APP_HEADER_CUSTOM_NAME( BaseApp, baseApp )

    BaseApp( Mercury::EventDispatcher & mainDispatcher,
          Mercury::NetworkInterface & internalInterface,
          bool isServiceApp = false );

    // 内部/外部接口
    Mercury::NetworkInterface & intInterface()  { return interface_; }
    Mercury::NetworkInterface & extInterface()  { return extInterface_; }

    // 与 BaseAppMgr 通信的网关
    BaseAppMgrGateway & baseAppMgr()             { return baseAppMgr_; }

    // DBApp 通道
    DBApp & dbApp()                               { return dbAppAlpha_; }
    DBAppsGateway & dbApps()                      { return dbApps_; }

    // 实体容器
    const Bases & bases() const                   { return bases_; }

    // 持久化
    SqliteDatabase* pSqliteDB() const             { return pSqliteDB_; }
    BackupHashChain & backupHashChain()            { return *pBackupHashChain_; }

    // ... 一系列消息处理方法
};
```

注意构造函数的 `isServiceApp` 参数——这是 `ServiceApp` 的开关。`ServiceApp` 是 BaseApp 的"轻量子类",**不接客户端**(没有 Proxy),只跑全局服务脚本(全局邮箱),但**共用 BaseApp 的全部代码**。这种"参数化子类"的设计避免了为 ServiceApp 写一份重复的代码。

### 10.5.2 启动流程

BaseApp 的 `init()`(`baseapp.cpp:352-521`)分为 12 步,核心步骤如下:

```
init() [L352]
  ├─ [1] ServerApp::init + 接口注册
  │   ├─ ServerApp::init(argc, argv)
  │   ├─ 创建 intInterface_(内部接口)
  │   ├─ 创建 extInterface_(外部接口)
  │   ├─ BaseAppIntInterface::registerWithInterface(intInterface_)
  │   └─ BaseAppExtInterface::registerWithInterface(extInterface_)
  │
  ├─ [2] BWResource 监控线程安全
  │   └─ BWResource::watchAccessFromCallingThread(true)
  │      // 强制:Python 与实体操作只在主线程
  │
  ├─ [3] EntityApp::init
  │   ├─ 加载 EntityDefs(entity_description_map)
  │   ├─ 初始化 IDClient(向 DBApp Alpha 申请 EntityID)
  │   └─ 初始化 SharedDataManager
  │
  ├─ [4] 创建外部网络服务
  │   ├─ extInterface_.createListener( "BaseAppExtInterface" )
  │   ├─ tcpServer_ = new Mercury::TCPListener(...)  // WebSocket
  │   └─ 向 machined 注册 extInterface_ 地址
  │
  ├─ [5] 创建内部网络服务
  │   ├─ intInterface_.createListener( "BaseAppIntInterface" )
  │   └─ 向 machined 注册 intInterface_ 地址
  │
  ├─ [6] 初始化脚本系统
  │   ├─ ScriptApp::initScript(argc, argv)
  │   ├─ BigWorldBaseAppScript::init() — 注册 BigWorld.entities/localServices/
  │   │   globalBases/services 等 Python 绑定
  │   └─ initPersonality() — 加载 personality 脚本
  │
  ├─ [7] 初始化持久化子系统
  │   ├─ pSqliteDB_ = new SqliteDatabase()
  │   ├─ pArchiver_ = new Archiver(*this)
  │   ├─ pBackupSender_ = new BackupSender(*this)
  │   └─ backedUpBaseApps_.init()
  │
  ├─ [8] 初始化实体创建器与转发器
  │   ├─ pEntityCreator_ = new EntityCreator(*this)
  │   ├─ baseMessageForwarder_ = new BaseMessageForwarder(*this)
  │   └─ proxies_ = new Proxies(*this)
  │
  ├─ [9] 启动 WorkerThread 与 BgTaskManager
  │
  ├─ [10] 注册 BaseAppMgr 通道(异步)
  │   ├─ 创建 baseAppMgr_ ChannelOwner(指向 BaseAppMgr)
  │   └─ AddToBaseAppMgrHelper::start() — 异步向 BaseAppMgr 发 add
  │
  ├─ [11] 注册 machined 死亡监听
  │   ├─ registerDeathListener(handleBaseAppMgrDeath, "BaseAppMgrInterface")
  │   ├─ registerDeathListener(handleCellAppMgrDeath, "CellAppMgrInterface")
  │   └─ registerDeathListener(handleDBAppDeath, "DBAppInterface")
  │
  └─ [12] Watcher 与定时器
      ├─ addWatchers() — 注册 30+ watcher
      └─ startGameTickTimer() — 启动游戏 tick 定时器
```

由于 `add` 到 BaseAppMgr 是**异步**的(BaseAppMgr 可能正在忙,需要等回复),BaseApp 的初始化分为三阶段:

1. **`init` 完成**:本地准备好,等 BaseAppMgr 回复。
2. **`finishInit`**:收到 BaseAppMgr 回复(包含 BackupHash),初始化 BackupSender 和 BackedUpBaseApps。
3. **`ready`**:所有 init 阶段完成,启动游戏 tick、BackupSender、Archiver,触发 Python `onAppReady`。

`AddToBaseAppMgrHelper`(`add_to_baseappmgr_helper.hpp`)是个自销毁辅助类,把"异步请求 + 回复处理"封装成一个对象:

```cpp
class AddToBaseAppMgrHelper
{
public:
    static void start()
    {
        // 向 BaseAppMgr 发 add 消息,携带 BaseAppInitData
        BaseApp::instance().baseAppMgr().channel().bundle()
            .startMessage( BaseAppMgrInterface::add );
        BaseApp::instance().baseAppMgr().channel().send();

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

这种"new 出来不等引用,回调里 delete 自己"的模式在 BigWorld 中很常见——它避免了"调用方持有一个可能悬空的指针"的复杂性。

### 10.5.3 主循环 tick

BaseApp 的主循环由 `startGameTickTimer` 启动:

```cpp
// baseapp.cpp:2016-2030
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

每 tick 触发 `handleTimeout` → `tickGameTime`:

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

**线程模型**:BaseApp 采用"主线程独占 Python + Worker 后台线程"模型:

```
主线程(MainDispatcher)
  ├─ Python 解释器(独占)
  ├─ 所有实体操作(Base/Proxy 方法调用)
  ├─ 网络消息处理(intInterface_ + extInterface_)
  ├─ tickGameTime()
  └─ Watcher 响应

WorkerThread(后台)
  ├─ SQLite 数据库写入
  ├─ BackupSender 实体序列化(避免阻塞主线程)
  └─ 其他 BgTask
```

`BWResource::watchAccessFromCallingThread(true)` 在 init 阶段开启,确保 Python 与实体操作只在主线程。Worker 线程通过 BgTask 提交任务,任务内**不能直接调用 Python**。这种"主线程串行 + Worker 并行 IO"的设计避免了 GIL 与锁的复杂性。

### 10.5.4 与 BaseAppMgr 的通信

BaseApp 通过 `BaseAppMgrGateway`(`baseappmgr_gateway.hpp`)与 BaseAppMgr 通信:

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

主要交互消息:

| 消息 | 方向 | 用途 |
|------|------|------|
| `add` | BaseApp → BaseAppMgr | 注册自己 |
| `finishedInit` | BaseApp → BaseAppMgr | 通知初始化完成 |
| `updateBaseApp` | BaseApp → BaseAppMgr | 周期上报负载 |
| `handleBaseAppDeath` | BaseAppMgr → BaseApp | 通知某 BaseApp 死亡 |
| `setBackupBaseApps` | BaseAppMgr → BaseApp | 下发新的备份关系 |
| `createBaseWithCellData` | BaseAppMgr → BaseApp | 转发 createEntity 请求 |
| `controlledShutDown` | BaseAppMgr → BaseApp | 受控关停命令 |

---

## 10.6 实体管理

### 10.6.1 Base 创建

`EntityCreator`(`entity_creator.hpp`)是 Base 创建的统一入口:

```cpp
class EntityCreator
{
public:
    PyObject * createBaseRemotely( PyObject * args, PyObject * kwargs );
    PyObject * createBaseAnywhere( PyObject * args, PyObject * kwargs );
    PyObject * createBaseLocally( PyObject * args, PyObject * kwargs );
    PyObject * createBase( EntityType * pType, PyObject * pDict,
                            PyObject * pCellData = NULL ) const;

    bool createBaseFromDB( const BW::string& entityType,
                    const BW::string& name,
                    PyObjectPtr pResultHandler );

    void createBaseWithCellData( const Mercury::Address & srcAddr,
            const Mercury::UnpackedMessageHeader& header,
            BinaryIStream & data,
            LoginHandler * pLoginHandler );
};
```

最常见的是 `createBaseFromDB`,即玩家登录时从 DB 加载实体:

```
玩家登录流程:
1. LoginApp → DBApp:logOn(账号)
2. DBApp 验证账号,加载实体数据 → BaseAppMgr:createEntity
3. BaseAppMgr 选最低负载 BaseApp,转发 createBaseWithCellData
4. 选中的 BaseApp:EntityCreator::createBaseFromStream
   ├─ 解析流:实体类型、ID、DBID、属性数据
   ├─ 向 DBApp Alpha 申请 EntityID(若 id 为 0)
   ├─ EntityType::newEntityBase(id) → Base 对象
   ├─ 反序列化属性
   ├─ 加入 Bases 容器
   └─ 若有 cellData,Base::createCellEntity(...)
5. Base 创建完成,触发 Python onBaseCreated
```

`Bases` 容器(`bases.hpp`)是个简单的 map:

```cpp
class Bases
{
public:
    bool add( Base * pBase );
    bool erase( Base * pBase );
    Base * find( EntityID id ) const;

    size_t size() const  { return bases_.size(); }

    iterator begin()     { return bases_.begin(); }
    iterator end()       { return bases_.end(); }

private:
    typedef BW::map< EntityID, Base * > Container;
    Container bases_;
};
```

BaseApp 持有两个 `Bases` 实例:

```cpp
// baseapp.hpp:400-401
Bases    bases_;                   // 玩家/普通 Base
Bases    localServiceFragments_;   // 本地服务片段(全局服务)
```

### 10.6.2 Base 销毁

Base 销毁有两条路径:

**1. 主动销毁**(`Base::destroy`):

```cpp
void Base::destroy( bool deleteFromDB, bool writeToDB, bool logOffFromDB = true )
{
    // 1. 若有 cell,先销毁 cell 实体(异步)
    // 2. destroyCell 完成后回调 onDestroyCellComplete
    // 3. writeToDB(若需要)
    // 4. logOffFromDB(若需要,从 DB 注销)
    // 5. discard()
}
```

**2. 立即丢弃**(`Base::discard`):

```cpp
void Base::discard( bool isOffload = false )
{
    // 1. 从 Bases 容器移除
    // 2. delete this(触发 Python 析构)
}
```

`discard` 不写 DB,用于 offload(迁移)场景——因为数据已经在目标 BaseApp 重建了,原 BaseApp 的副本直接丢弃即可。

### 10.6.3 Base 的 Backup

`BackupSender`(`backup_sender.hpp`)周期(默认 10 秒)将 Base 实体的**快照**发送到对端 BaseApp:

```cpp
class BackupSender
{
public:
    BackupSender( BaseApp & baseApp );

    void tick( const Bases & bases,
               Mercury::NetworkInterface & networkInterface );

    Mercury::Address addressFor( EntityID entityID ) const
    {
        return entityToAppHash_.addressFor( entityID );
    }

private:
    BackupHash    entityToAppHash_;      // 当前生效的哈希
    BackupHash    newEntityToAppHash_;   // 过渡中的新哈希
    bool          isUsingNewBackup_;
    bool          isOffloading_;
    BaseApp &     baseApp_;
};
```

备份流程:

```
1. 取下一个 Base 实体
2. 序列化(在 WorkerThread,避免阻塞主线程)
3. 基于 BackupHash 计算备份目标 BaseApp
4. 发送 backupBaseEntity 消息(BaseAppIntInterface)
5. 目标 BaseApp 收到,存入 BackedUpBaseApps
```

`BackedUpBaseApp`(`backed_up_base_app.hpp`)使用**双缓冲**设计:

```cpp
class BackedUpBaseApp
{
public:
    void startNewBackup( uint32 index, const MiniBackupHash & hash );
    void switchToNewBackup();
    void discardNewBackup();

    BW::string & getDataFor( EntityID entityID )
    {
        if (usingNew_)
            return newBackup_.getDataFor( entityID );
        else
            return currentBackup_.getDataFor( entityID );
    }

private:
    BackedUpEntitiesWithHash currentBackup_;  // 当前生效
    BackedUpEntitiesWithHash newBackup_;      // 过渡中的新缓冲
    bool usingNew_;
    bool canSwitchToNewBackup_;
};
```

**双缓冲的必要性**:当 BackupHash 变更时(新 BaseApp 加入或老 BaseApp 死亡),需要"逐步"切换备份目标。如果直接覆盖,在切换瞬间原备份已删、新备份未建立,会丢失数据。双缓冲让"旧备份"和"新备份"并存,新备份填满后 `switchToNewBackup()` 才提升为当前,旧缓冲才被丢弃。

### 10.6.4 Base 的迁移

当 BaseApp 准备退休(关停或负载过高),需要把 Base 实体迁移到其他 BaseApp,这叫 **offload**:

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

迁移过程中,可能有其他进程仍向原 BaseApp 发消息。`BaseMessageForwarder`(`base_message_forwarder.hpp`)负责转发:

```cpp
class BaseMessageForwarder
{
public:
    void addForwardingMapping( EntityID id,
                               const Mercury::Address & newAddr );
    bool forwardIfNecessary( const Mercury::Address & srcAddr,
                             EntityID id, ... );

private:
    BW::map< EntityID, Mercury::Address > forwardingMap_;
};
```

迁移中的 EntityID 临时映射到新地址,原 BaseApp 收到消息后转发到新 BaseApp,一段时间后(或新 BaseApp 确认)移除映射。

---

## 10.7 客户端代理流程

### 10.7.1 完整的客户端登录流程

把前面零散提到的流程串起来,一个玩家从"启动客户端"到"进入游戏"的完整流程:

```
1. 客户端启动,连接 LoginApp
   ↓
2. LoginApp → DBApp:logOn(账号,密码)
   ↓
3. DBApp 验证账号
   ├─ 验证成功:加载实体数据(从 DB)
   └─ 生成 loginKey(短期)
   ↓
4. DBApp → BaseAppMgr:createEntity(实体数据)
   ↓
5. BaseAppMgr 选最低负载 BaseApp
   ├─ findLeastLoadedApp()
   └─ 转发 createBaseWithCellData 给选中 BaseApp
   ↓
6. 选中 BaseApp 收到 createBaseWithCellData
   ├─ EntityCreator::createBaseFromStream
   ├─ 创建 Base 对象
   ├─ 加入 Bases 容器
   └─ Base::createCellEntity → CellAppMgr → CellApp
   ↓
7. Base 创建完成
   ├─ Proxy 对象就绪(若是玩家实体)
   ├─ PendingLogins::add(proxy, loginAppAddr)
   │   生成 loginKey,返回给 LoginApp
   └─ LoginApp 把 loginKey 转给客户端
   ↓
8. 客户端连接 BaseApp 的 extInterface_
   ├─ 发 baseAppLogin 消息(带 loginKey)
   ├─ BaseApp 验证 loginKey(在 PendingLogins 中查找)
   └─ Proxy::attachToClient( srcAddr, keyData )
   ↓
9. attachToClient 完成
   ├─ 创建 pClientChannel_(UDP Channel)
   ├─ 设置加密(若启用)
   ├─ 创建 ClientEntityMailBox
   ├─ 初始化 BundlePrimer(自动注入 authenticate+tickSync)
   ├─ 初始化限流器
   ├─ 触发 Python onClientAttached
   └─ 通知 CellApp 添加 witness
   ↓
10. 客户端开始接收游戏数据
    ├─ CellApp 的 witness 把 AOI 内实体状态发回 BaseApp
    ├─ BaseApp 转发给客户端
    └─ 客户端进入游戏
```

### 10.7.2 Base 与 Cell 建立 Mailbox

第 6 步中的 `Base::createCellEntity` 是 Base 与 Cell 建立 Mailbox 的关键:

```cpp
// base.hpp
bool createCellEntity( const ServerEntityMailBoxPtr & pNearbyMB );
```

它的执行流程:

```
Base::createCellEntity(nearbyMB)
   ↓
1. 标记 isCreateCellPending_ = true
   ↓
2. 选择目标 CellApp(通过 nearbyMB 或 CellAppMgr)
   ↓
3. 序列化 cellData(实体的空间属性)
   ↓
4. 发送 createCellEntity 消息给 CellApp
   ├─ 携带:entityID, typeID, cellData, baseMailboxRef
   └─ baseMailboxRef 让 CellApp 知道如何调回 Base
   ↓
5. CellApp 创建 Entity(空间部分)
   ├─ 设置位置、方向
   ├─ 加入空间
   └─ 保存 baseMailboxRef(用于 callBaseMethod)
   ↓
6. CellApp 回调:cellEntityCreated
   ↓
7. Base::onCellEntityCreated
   ├─ 创建 pCellEntityMailBox_(指向 Cell 实体)
   ├─ isCreateCellPending_ = false
   └─ 触发 Python onCellEntityCreated
```

完成后,Base 与 Cell 双方都持有对方的 Mailbox,可以双向调用方法:

```python
# Base 端(Python):
self.cellEntityMailBox.moveTo(position)  # 调 Cell 端方法
```

```python
# Cell 端(Python):
self.baseEntityMailBox.onInventoryChanged()  # 调 Base 端方法
```

### 10.7.3 Base 向客户端同步实体状态

`Proxy` 通过 `ClientEntityMailBox` 向客户端发消息:

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

`BundlePrimer`(在 proxy.cpp 内)在每个发送给客户端的 bundle 中自动注入:

```
Bundle 开头:
  - authenticate 消息(携带 sessionKey,首次)
  - tickSync 消息(每个 bundle,同步游戏时间)
  - 实际业务消息
```

这确保客户端始终有时间同步,且首次连接能完成认证。

**流控**通过 `sendBundleToClient`(`proxy.cpp:1900-2001`)实现:

```cpp
void Proxy::sendBundleToClient()
{
    // 1. 检查 Channel 是否就绪
    if (!pClientChannel_ || !pClientChannel_->isEstablished()) {
        return;  // 缓冲
    }

    // 2. 流控:检查 bitsPerSecondToClient 限制
    float budget = bitsPerSecondToClient_ * tickTime_;
    if (avgClientBundleDataUnits_ > budget) {
        return;  // 超预算,延迟发送
    }

    // 3. 添加 opportunistic 数据(实体属性同步)
    this->addOpportunisticData( bundle );

    // 4. 发送
    pClientChannel_->send();
}
```

### 10.7.4 客户端命令路由

客户端发来的消息经过 `extInterface_` 路由:

```
客户端 → extInterface_ → BaseAppExtInterface 消息处理
   │
   ├─ baseAppLogin     → LoginHandler::login(认证)
   ├─ callBaseMethod   → Proxy::callBaseMethod(methodID, data)
   │                      → Base::callBaseMethod → Python
   ├─ move             → 转发到 CellApp
   ├─ tickSync         → Proxy 处理时间同步
   └─ ...              → 其他客户端可调消息
```

注意:客户端**不能直接调 Cell 方法**——所有客户端请求先到 Base,Base 决定是否转发给 Cell。这种"Base 是唯一入口"的设计让游戏逻辑可以在 Base 层做权限校验(如"玩家是否可以移动到这个位置")。

---

## 10.8 断线重连机制

### 10.8.1 断线检测与原因分类

BaseApp 通过 Channel 心跳检测断线。一旦检测到断线,`Proxy::onClientDeath` 被调用,根据原因分类处理:

```cpp
// proxy.cpp:748-814
void Proxy::onClientDeath( ClientDisconnectReason reason )
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

`ClientDisconnectReason`(`proxy.hpp:45`)定义了 7 种断线原因:

```cpp
enum ClientDisconnectReason
{
    CLIENT_DISCONNECT_CLIENT_REQUESTED,     // 客户端主动断开
    CLIENT_DISCONNECT_GIVEN_TO_OTHER_PROXY, // 客户端被迁移到其他 Proxy
    CLIENT_DISCONNECT_RATE_LIMITS_EXCEEDED, // 限流超限
    CLIENT_DISCONNECT_TIMEOUT,              // 超时
    CLIENT_DISCONNECT_BASE_RESTORE,         // Base 被备份恢复
    CLIENT_DISCONNECT_SHUTDOWN,             // 服务器关停
    CLIENT_DISCONNECT_CELL_RESTORE_FAILED,  // Cell 恢复失败
};
```

不同原因走不同路径——这是 BigWorld "精细化容错"的体现。

### 10.8.2 Base 保留(超时回收)

网络抖动导致的断线(`CLIENT_DISCONNECT_REASON_NET`)走"保留 + 等待重连"流程:

```cpp
void Proxy::prepareForReLogOn()
{
    // 创建 PendingReLogOn,启动超时定时器
    pPendingReLogOn_ = new PendingReLogOn( *this );
    pPendingReLogOn_->waitForReLogOn();  // 默认 30 秒
}
```

`PendingReLogOn`(`proxy.cpp:57-86`)的核心逻辑:

```cpp
class PendingReLogOn
{
public:
    PendingReLogOn( Proxy & proxy );

    bool waitForReLogOn();      // 启动超时定时器
    void complete( Proxy & proxy, const LogOnParams & params );  // 重登录到达
    void timeout();             // 超时,放弃

private:
    Proxy &     proxy_;
    SessionKey  sessionKey_;    // 与断线前相同的 sessionKey
    TimerHandle timer_;
    float       timeout_;       // 默认 30 秒
};
```

在这 30 秒内:

- **Proxy 不销毁**——Base 实体保留,Cell 实体也保留(只是 witness 暂停)。
- **`sessionKey_` 不变**——这是重连时验证身份的凭证。
- **CellApp 端的 witness 标记为"暂停"**——其他玩家看不到这个客户端控制的角色(或看到"掉线中"标志),但角色本身还在场景里。

### 10.8.3 重连恢复

客户端重连的流程:

```
1. 客户端断开(网络问题)
   ↓
2. 客户端重连 LoginApp,携带 sessionKey(从本地存储读取)
   ↓
3. LoginApp 转发到 DBApp Alpha
   ↓
4. DBApp Alpha 查 logOnRecords,找到原 BaseApp
   ├─ logOnRecords 记录了:该玩家上次登录到哪个 BaseApp
   └─ 通过 BaseAppMgr 找到原 BaseApp 的地址
   ↓
5. 通知原 BaseApp 的 Proxy:prepareForReLogOn(已准备好了)
   ↓
6. 客户端连到原 BaseApp
   ├─ 发 baseAppLogin 消息(带 sessionKey)
   └─ LoginHandler 查 PendingLogins 找到匹配的 Proxy
   ↓
7. Proxy::completeReLogOnAttempt(sessionKey, params)
   ├─ 验证 sessionKey 匹配 PendingReLogOn 中的 sessionKey_
   ├─ PendingReLogOn::complete
   ├─ 重建 pClientChannel_
   ├─ 重建 ClientEntityMailBox
   └─ 触发 Python onClientReattached
   ↓
8. 恢复客户端连接,无需重建实体!
   ├─ Base 实体:还是原来那个
   ├─ Cell 实体:还是原来那个
   └─ 玩家感知:只是"卡了一下",游戏状态完全保留
```

### 10.8.4 与 Cell 的重新绑定

重连后,`attachToClient` 会再次通知 CellApp 添加 witness:

```cpp
// 简化的 attachToClient
void Proxy::attachToClient( const Mercury::Address & srcAddr, ... )
{
    // ... 重建 pClientChannel_, ClientEntityMailBox, ...

    // 通知 CellApp 重新启用 witness
    if (addClientEntity && pCellEntityMailBox_) {
        pCellEntityMailBox_->sendCallCellMethod(
            "addWitness", pClientChannel_->address() );
    }
}
```

注意:**Cell 实体从未销毁**——断线期间它一直在 CellApp 上。重连只是"重新挂上 witness",让 CellApp 知道"这个客户端又在线了,恢复 AOI 推送"。

这种设计的工程价值是:

- **省去重建 Cell 的开销**:Cell 实体的创建涉及空间分配、AOI 重建、Ghost 同步等重活,省下来对性能极有利。
- **保留断线瞬间的状态**:玩家被怪物攻击到一半断线,重连后怪物还在攻击,战斗状态连续。
- **简化游戏逻辑**:游戏脚本不需要处理"玩家断线 → 保存状态 → 玩家重连 → 恢复状态"的复杂流程,框架自动保留。

### 10.8.5 超时回收

如果 30 秒内客户端没重连上,`PendingReLogOn::timeout` 触发:

```
PendingReLogOn::timeout
   ↓
销毁 Proxy(执行 destroy)
   ├─ writeToDB(持久化)
   ├─ destroyCellEntity(销毁 Cell 实体)
   └─ discard
   ↓
玩家彻底下线
```

超时时间的工程权衡:

- **太短**(如 5 秒):网络抖动几秒就销毁,玩家体验差。
- **太长**(如 5 分钟):BaseApp 内存被无效 Proxy 占用,且玩家在场景里的 Cell 实体也占着 CellApp 内存。
- **30 秒**(默认):平衡——大部分网络抖动在 30 秒内恢复,而 30 秒的内存占用可接受。

---

## 10.9 Base 备份与故障切换

### 10.9.1 Primary/Backup 模型

BigWorld 的 Base 备份采用**主动备份**模型:

- **Primary Base**:BaseApp 上的"主"Base 实例,处理所有请求。
- **Backup Base**:另一个 BaseApp 上的"备份"Base 实例,**不处理请求**,只是被动接收 Primary 的快照。

当 Primary BaseApp 死亡时,Backup BaseApp 把备份"提升"为 Primary,接管业务。这个过程对客户端透明——客户端甚至感知不到切换。

```
正常状态:
   BaseApp #1 (Primary)         BaseApp #2 (Backup)
   ├─ Base A (active)           ├─ Base A 的快照
   ├─ Base B (active)           ├─ Base B 的快照
   └─ Base C (active)           └─ Base C 的快照

BaseApp #1 死亡:
   (空)                        BaseApp #2 (接管)
                               ├─ Base A (active, 从备份恢复)
                               ├─ Base B (active, 从备份恢复)
                               └─ Base C (active, 从备份恢复)
```

### 10.9.2 BackupHash 哈希

如何决定"某 Base 备份到哪个 BaseApp"?BigWorld 用 **BackupHash**——一个把 `[0, range_)` 的哈希空间映射到 BaseAppID 的数据结构:

```cpp
// lib/server/backup_hash.hpp
class BackupHash
{
    // 每个 BaseApp 持有一段连续区间
    // 用于决定:某实体的备份应存放在哪个对端 BaseApp
};
```

实体 ID 通过哈希函数映射到一个数,落在某 BaseApp 的区间内,该 BaseApp 就是这个实体的备份目标。当 BaseApp 集合变化(加入或死亡)时,区间重新划分。

为避免备份切换瞬间的"数据真空",BigWorld 使用 **BackupHashChain**(双哈希链):

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

在哈希变更时,新哈希逐步替换旧哈希——备份方知道:哪些是新增的(需要建立备份),哪些是移除的(可以清理)。过渡完成后,旧哈希被丢弃。

BaseAppMgr 通过 `adjustBackupLocations` 操作 BackupHash:

```cpp
enum AdjustBackupLocationsOp {
    ADD_APP,            // 新 BaseApp 加入,需要重新分配备份目标
    REMOVE_APP,         // BaseApp 死亡,需要把它的备份迁到其他 BaseApp
    START_BACKUP,       // 开始备份
    STOP_BACKUP,        // 停止备份(关停前)
    USE_NEW_BACKUP_HASH // 切换到新哈希(过渡完成)
};
```

### 10.9.3 故障切换流程

当某 BaseApp 死亡,完整的故障切换流程:

```
1. bwmachined 检测到 BaseApp #1 死亡(NOTIFY_DEATH)
   ↓
2. BaseAppMgr 收到 death 通知
   ├─ 从子集移除
   ├─ adjustBackupLocations(REMOVE_APP, pDeadApp)
   │   └─ 重新计算 BackupHash,通知所有存活 BaseApp
   ├─ redirectGlobalBases(pDeadApp)
   │   └─ 基于 BackupHash 找到 GlobalBase 的接管者
   ├─ 通知 CellAppMgr 该 BaseApp 死亡
   └─ 通知所有存活 BaseApp:handleBaseAppDeath(deadID)
   ↓
3. 存活 BaseApp 收到 handleBaseAppDeath(deadID)
   ├─ BackedUpBaseApps::restore(deadID)
   │   ├─ 取出该 deadID 对应的所有备份
   │   ├─ 对每个被备份的实体:
   │   │   ├─ EntityCreator::createBaseFromStream(backupData, isRestoration=true)
   │   │   ├─ 重建 Base + 重建 Cell(若有 cellData)
   │   │   └─ 触发 Python onRestored 回调
   │   └─ 这些 Base 升级为 Primary
   ↓
4. 重定向 Mailbox
   ├─ ServerEntityMailBox::adjustForDeadBaseApp(deadAddr, hash)
   └─ 所有指向 deadAddr 的 Mailbox 自动重定向到新 BaseApp
   ↓
5. 玩家客户端无感恢复
   ├─ Proxy 重建完成
   ├─ Cell 实体重建完成
   └─ 客户端 Channel 仍指向新 BaseApp(通过 LoginApp 重定向)
```

### 10.9.4 数据一致性

备份是周期(默认 10 秒)的,因此 Backup 与 Primary 之间有"最多 10 秒"的数据延迟。BaseApp 死亡时,这 10 秒内的修改可能丢失。BigWorld 的处理策略:

1. **关键操作立即备份**:某些关键修改(如升级、购买)通过 `backupBaseNow` 立即触发备份,不等周期:

```cpp
// baseapp.hpp:322
bool backupBaseNow( Base & base,
                    Mercury::ReplyMessageHandler * pHandler = NULL );
```

2. **写 DB 优先于备份**:writeToDB 是"硬持久化",备份只是"软持久化"。即使备份丢了,只要 writeToDB 完成,数据还在 DB 里。

3. **游戏逻辑层容忍**:游戏设计通常容忍"短暂回滚"——比如玩家打怪掉线,回滚 10 秒可能少打一次怪,这不会破坏游戏平衡。但涉及金钱交易等关键操作,游戏逻辑应当 `writeToDB` 而不是依赖 backup。

`BackedUpEntities`(`backed_up_base_app.hpp`)的存储是简单的 map:

```cpp
class BackedUpEntities
{
public:
    BW::string & getDataFor( EntityID entityID )
    {
        return data_[ entityID ];
    }

    bool contains( EntityID entityID ) const
    {
        return data_.count( entityID ) != 0;
    }

protected:
    typedef BW::map< EntityID, BW::string > Container;
    Container data_;
};
```

存储的是序列化后的字符串,不解析、不执行——只在新 Primary 接管时 `restore()` 才反序列化。这种"原始字节存储"避免了备份方需要知道实体类型的细节,降低了耦合。

---

## 10.10 特色实现深度剖析

### 10.10.1 Base/Cell 分层的设计哲学

BigWorld 把实体分成 Base 与 Cell 两层,这是它最核心的设计决策之一。这种分层背后有深远的工程考量:

**1. 关注点分离**

- Base 关注"持久状态 + 业务逻辑":库存、技能、好友列表、聊天。
- Cell 关注"空间状态 + AOI":位置、方向、可见性。

这两类状态的更新频率、持久化需求、负载特征完全不同。Base 状态变化少但每次都重要(玩家升级、获得物品),Cell 状态变化多但每次都"无关紧要"(位置每帧变化)。把它们放一起,要么 Base 被高频 Cell 更新拖累,要么 Cell 被低频 Base 持久化打断。分层后,各自的优化策略独立。

**2. 故障隔离**

CellApp 崩溃只影响"空间状态",玩家 Base 还在,可以快速重建 Cell(从 Base 的 `pCellData_` 重新创建);BaseApp 崩溃只影响"持久状态",有 Backup 接管。如果不分层,任一进程崩溃都需要完整重建实体,代价高得多。

**3. 负载均衡独立**

Cell 负载均衡(把 Cell 实体从繁忙 CellApp 迁到空闲 CellApp)与 Base 负载均衡(把 Base 从繁忙 BaseApp 迁到空闲 BaseApp)是独立的——一个玩家可以同时经历"Cell 迁移"和"Base 迁移"而不互相干扰。这种独立性的前提就是分层。

**4. 客户端简化**

客户端不需要知道"我在哪个 CellApp",它只和 BaseApp 通信。Cell 的迁移对客户端完全透明。这极大简化了客户端的网络逻辑。

### 10.10.2 客户端代理的透明性

`Proxy` 是"客户端在服务器侧的化身",它的透明性体现在多个层面:

**1. Base 的方法集对客户端透明**

`Proxy` 继承自 `Base`,拥有 Base 的所有方法。客户端调用的方法,经过 `callBaseMethod` 路由到 Python,与"Base 自己调用自己的方法"完全一样。游戏脚本不需要区分"这个调用来自客户端还是服务器内部"。

**2. Mailbox 的位置透明**

`Proxy.cellEntityMailBox` 指向 Cell 实体,但游戏脚本不需要知道 Cell 在哪个 CellApp——`cellEntityMailBox.moveTo(pos)` 自动路由。

**3. 故障透明**

BaseApp 死亡时,客户端被自动重定向到 Backup BaseApp,玩家甚至感知不到。CellApp 死亡时,Cell 实体从 Ghost 或 Base 重建,玩家只是看到"画面卡一下"。

**4. 迁移透明**

Base 的 offload 和 Cell 的迁移对游戏脚本完全透明。脚本不需要写"if 迁移中 then ..."这样的代码。`BaseMessageForwarder` 在框架层处理了"迁移中的消息转发"。

这种"透明性"让游戏开发者可以像写单机游戏一样写 MMOG——分布式细节被框架吸收。

### 10.10.3 断线重连的工程价值

BigWorld 的断线重连机制,其工程价值远超表面看起来的"省去重新登录":

**1. 状态连续性**

传统 MMOG 断线后,玩家重新登录时实体是从 DB 加载的"上次存档状态"。如果游戏有"未持久化的临时状态"(如正在施法的延迟效果、buff 计时),这些状态会丢失。BigWorld 的重连不销毁实体,所有内存中的状态(包括 Python 对象的所有属性)都保留。

**2. 战斗连续性**

PvP 战斗中,玩家断线会被对手"卡顿一下"——但角色还在场景里,对手可以继续攻击,只是断线玩家无法操作。重连后玩家看到的是"刚才被打了几下"的实时状态,而不是"回到存档点"。这对玩家体验至关重要。

**3. Cell 资源节省**

不销毁 Cell 实体意味着不需要重建 AOI、Ghost 等空间数据——这是分布式 MMOG 中最昂贵的操作之一。重连的开销只是"重新挂 witness",几乎可以忽略。

**4. 防外挂**

`sessionKey` 是 BaseApp 内部生成的,只在断线→重连这一短暂窗口有效,且绑定到具体 BaseApp。攻击者无法通过截获 sessionKey 来"伪装"重连——除非攻击者同时控制了客户端机器和 BaseApp 网络。

**5. 工程权衡**

30 秒的超时是个权衡:

- 太短:网络抖动几秒就销毁,失去了重连的意义。
- 太长:BaseApp 内存被无效 Proxy 占用。
- 30 秒:覆盖 95% 的网络抖动,内存占用可接受。

这种"看似简单,实则经过深思"的参数在 BigWorld 中随处可见。

### 10.10.4 Backup 机制的容错性

BigWorld 的 Backup 机制设计得非常注重容错:

**1. 双缓冲避免切换丢数据**

`BackedUpBaseApp` 的双缓冲(currentBackup_ / newBackup_)是关键设计。BackupHash 变更时:

- 旧备份继续接收(避免漏掉变更)。
- 新备份开始填充。
- 新备份填满后,`switchToNewBackup()` 才提升。
- 提升后旧缓冲才被丢弃。

这种"先建新、后拆旧"的模式在分布式系统中很常见——它保证了切换瞬间总有完整数据。

**2. BackupHashChain 应对过渡**

`BackupHashChain` 保留 previous_,让"过渡期"的消息能正确路由:

```cpp
BaseAppID appForHash( uint32 hash ) const
{
    // 优先用 current_,若 current_ 没有则退化到 previous_
}
```

过渡期是分布式系统最容易出 bug 的阶段——状态不一致、消息乱序、双重处理等问题高发。BackupHashChain 通过显式建模"过渡期",让代码可以正确处理这一阶段。

**3. 关键操作立即备份**

`backupBaseNow` 让"关键修改"不必等周期:

```cpp
bool backupBaseNow( Base & base,
                    Mercury::ReplyMessageHandler * pHandler = NULL );
```

游戏可以在升级、购买等关键操作后立即调用,确保数据不丢。这种"分级持久化"(关键立即、普通周期)平衡了性能与可靠性。

**4. 字节级存储解耦**

`BackedUpEntities` 存的是 `BW::string`(序列化后的字节流),不解析、不依赖实体类型定义。这意味着:

- 备份方不需要加载所有实体类型(EntityDefs)。
- 备份方的代码与 Primary 的实体逻辑完全解耦。
- 实体类型变化时,备份逻辑不需要改。

这种"原始字节存储"是 BigWorld 模块化设计的一个缩影——它让 BaseApp 的"备份功能"成为一个独立的、可单独测试的子系统。

**5. 故障切换的"全集群协同"**

BaseApp 死亡不是单个 BaseApp 的事,而是全集群协同处理:

- bwmachined 检测死亡(NOTIFY_DEATH)。
- BaseAppMgr 重新分配 BackupHash,通知所有 BaseApp。
- 存活 BaseApp 从备份恢复实体。
- CellAppMgr 通知 CellApp 重新指向新 BaseApp。
- GlobalBases 重定向到新 BaseApp。
- 客户端通过 LoginApp 重连到新 BaseApp。

这种"全集群协同"是 BigWorld 区别于简单主备方案的关键——它没有"单点故障",只要集群中还有足够健康的 BaseApp,就能自动恢复。

---

## 10.11 本章小结

本章我们深入剖析了 BaseApp 这个 BigWorld 服务器集群中最复杂的进程。关键要点回顾:

1. **BaseApp 是客户端与服务器的唯一桥梁**:它持有玩家会话的"代理"(Proxy),所有客户端通信经过它;它不做 AOI 计算,只做转发。

2. **Base 是实体的"持久半身"**:与 Cell 的"空间半身"配对,二者通过 Mailbox 双向通信。这种分层让故障隔离、负载均衡、客户端简化都成为可能。

3. **Mailbox 是跨进程方法调用的核心抽象**:你拿到 Mailbox 就能调方法,框架自动路由,故障时自动重定向。这让分布式代码读起来像本地代码。

4. **断线重连通过 sessionKey + 30 秒保留实现**:断线不销毁实体,重连时验证 sessionKey 恢复会话,Cell 实体全程保留。这对玩家体验至关重要。

5. **Backup 通过周期快照 + BackupHash 实现容错**:双缓冲避免切换丢数据,BackupHashChain 应对过渡期,关键操作可立即备份。BaseApp 死亡时全集群协同恢复。

6. **BaseAppMgr 是控制平面,BaseApp 是数据平面**:BaseAppMgr 不持有实体,只管调度;BaseApp 只执行,不管调度。这种分层让水平扩展变得简单。

如果你继续阅读第 11 章(DBApp 与数据持久化),会看到 Base 的 `writeToDB` 如何最终落到 DBApp;第 12 章(LoginApp 与 Reviver)会展开登录认证的完整流程;第 18 章(实体通信与 AOI 系统)会更深入地讨论 Mailbox 的 7 种类型与跨进程调用细节。

理解 BaseApp 是理解 BigWorld 服务器架构的钥匙——它承上启下,既是客户端的"代理",又是 CellApp 与 DBApp 的"指挥"。本章的篇幅最长,正是因为 BaseApp 集中了 BigWorld 最具特色的设计:Base/Cell 分层、Mailbox 透明性、断线重连、备份容错。这些设计理念在其他章节也会反复出现,构成了 BigWorld 区别于其他 MMOG 引擎的核心竞争力。
