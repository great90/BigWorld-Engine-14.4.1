# 专题 05:Mailbox 通信机制深度剖析

> Mailbox 是 BigWorld 引擎实现"跨进程透明通信"的核心抽象。在一个 BigWorld 集群中,玩家 Proxy(在 BaseApp)、Cell 实体(在 CellApp)、客户端实体(在 Client)、Service 服务(在 BaseApp)都可能分布在不同进程、不同机器上,而业务脚本却需要像调用本地对象一样调用它们:`self.cell.onHit(damage)`、`self.base.befriend(other)`、`self.client.showLoot(item)`。Mailbox 就是把"网络地址 + 实体 ID + 实体类型 + Component 类型"打包成一个 Python 可见对象,使脚本可以无视目标在哪个进程而进行方法调用。本专题以百科级深度剖析 BigWorld 14.4.1 中 **Mailbox 类层次、EntityMailBoxRef 网络表示、7 种 Component 枚举、_VIA_ 转发机制、Bundle/Channel 协作、故障重定向、迁移、性能分析、边界情况** 等所有 Mailbox 相关内容,涵盖完整源码、数据结构、算法步骤、性能分析。

---

## 目录

- [一、Mailbox 概述与设计哲学](#一mailbox-概述与设计哲学)
- [二、位置透明性与通信模型对比](#二位置透明性与通信模型对比)
- [三、7 种 Component 类型详解](#三7-种-component-类型详解)
- [四、Mailbox 类层次结构](#四mailbox-类层次结构)
- [五、EntityMailBoxRef 网络表示](#五entitymailboxref-网络表示)
- [六、PyEntityMailBox 基类深度剖析](#六pyentitymailbox-基类深度剖析)
- [七、ServerEntityMailBox 中间层](#七serverentitymailbox-中间层)
- [八、CellEntityMailBox 深度剖析](#八cellentitymailbox-深度剖析)
- [九、BaseEntityMailBox 深度剖析](#九baseentitymailbox-深度剖析)
- [十、ClientEntityMailBox 深度剖析](#十cliententitymailbox-深度剖析)
- [十一、_VIA_ 转发机制深度剖析](#十一_via_-转发机制深度剖析)
- [十二、RemoteEntityMethod 远程方法代理](#十二remoteentitymethod-远程方法代理)
- [十三、Mailbox 调用流程端到端剖析](#十三mailbox-调用流程端到端剖析)
- [十四、Mailbox 与 Bundle/Channel 协作](#十四mailbox-与-bundlechannel-协作)
- [十五、Mailbox 创建与销毁](#十五mailbox-创建与销毁)
- [十六、Mailbox 迁移机制](#十六mailbox-迁移机制)
- [十七、Mailbox 工厂注册机制](#十七mailbox-工厂注册机制)
- [十八、Mailbox 持久化与 Pickling](#十八mailbox-持久化与-pickling)
- [十九、故障透明性:Mailbox 自动重定向](#十九故障透明性mailbox-自动重定向)
- [二十、消息分发:接收端处理](#二十消息分发接收端处理)
- [二十一、Mailbox 统计与监控](#二十一mailbox-统计与监控)
- [二十二、性能分析](#二十二性能分析)
- [二十三、边界情况深度分析](#二十三边界情况深度分析)
- [二十四、与其他引擎对比](#二十四与其他引擎对比)
- [二十五、设计哲学总结](#二十五设计哲学总结)
- [附录 A:关键文件路径速查](#附录-a关键文件路径速查)
- [附录 B:Component 枚举速查](#附录-bcomponent-枚举速查)
- [附录 C:关键消息接口](#附录-c关键消息接口)
- [附录 D:Mailbox 引用与流转图](#附录-dmailbox-引用与流转图)
- [附录 E:常见问题排查](#附录-e常见问题排查)
- [附录 F:相关专题](#附录-f相关专题)
- [附录 G:术语表](#附录-g术语表)

---

## 一、Mailbox 概述与设计哲学

### 1.1 什么是 Mailbox

在 BigWorld 中,**Mailbox** 是一个抽象的"通信地址",它指向某个进程中的某个实体的某个 Component(CELL/BASE/CLIENT)。Mailbox 让脚本可以这样写:

```python
# 业务脚本调用,完全位置透明
def onTakeDamage(self, attacker, damage):
    attacker.base.onHit(self.id, damage)        # 调用对方的 Base
    self.cell.broadCastDamage(self.id, damage) # 调用自己的 Cell
    self.client.showHealthBar(self.health)     # 调用 Client
```

无论 `attacker.base` 指向本机另一个 BaseApp、远处机器的 BaseApp,甚至是一个尚未建立 cell 的 Base(此时 Mailbox 地址 ip=0,消息会被缓冲),脚本写法完全一致。

Mailbox 的本质是把以下信息打包:

1. **目标实体 ID**(EntityID,4 字节,跨进程唯一)
2. **目标地址**(Mercury::Address,IP+Port+Salt,8 字节)
3. **目标 Component 类型**(CELL/BASE/CLIENT/_VIA_,3 bit)
4. **目标实体类型 ID**(EntityTypeID,13 bit)

这四元组通过 `EntityMailBoxRef` 结构体(共 12 字节)序列化、传输、重建。Mailbox 既是 Python 中的 `PyEntityMailBox` 派生对象,也是 C++ 中 `ServerEntityMailBox` 等派生类的实例。

### 1.2 Mailbox 的设计目标

BigWorld 引擎设计 Mailbox 时,有以下明确目标:

| 设计目标 | 实现方式 | 源码体现 |
|---------|---------|---------|
| **位置透明** | Mailbox 隐藏目标位置,脚本无需关心 | `PyEntityMailBox::pyGetAttribute` 拦截方法调用 |
| **类型安全** | 通过 MethodDescription 校验参数 | `MethodDescription::areValidArgs` |
| **可序列化** | EntityMailBoxRef 12 字节,可在网络上传输、可持久化到 DB | `EntityMailBoxRef::init` |
| **可转发** | _VIA_ 机制允许通过中间进程转发 | `BaseViaCellMailBox` 等 |
| **可恢复** | 故障时通过 BackupHashChain 重定向 | `adjustForDeadBaseApp` |
| **可统计** | 全局 Population 链表 + Watcher | `s_population_` |
| **可分辨** | 7 种 Component 类型精确指代目标 | `EntityMailBoxRef::Component` |
| **与 Python 集成** | PyTypeObject,支持属性访问、调用、Pickle | `PY_TYPEOBJECT_WITH_CALL` |

### 1.3 Mailbox 的边界

虽然 Mailbox 看起来像"远程对象引用",但它与真正的 Actor 模型或 RPC 有显著差异:

- **Mailbox 不是对象本身**:Mailbox 只是指向对象的"地址",对象本身可能在某进程内存中,也可能不存在(故障时)
- **Mailbox 方法是单向的(默认)**:大多数 Mailbox 调用是 fire-and-forget,只有显式声明的 two-way 方法才有返回值,且通过 Deferred 异步获取
- **Mailbox 不能跨进程持有"对象引用"**:跨进程只能持有 EntityMailBoxRef(12 字节),不能持有 PyObject*
- **Mailbox 不保证消息到达**:UDP 通道上,只有 RELIABLE 消息保证到达,普通消息可能丢失
- **不同 Component 上的 Mailbox 限制不同**:Cell Mailbox 不能持久化存储,Base Mailbox 可以,详见后文

### 1.4 Mailbox 在引擎中的地位

Mailbox 是 BigWorld 服务器集群的"神经通路"。没有 Mailbox,以下功能都将不可行:

- 玩家从 LoginApp 登录后,BaseApp 之间互相创建 Proxy 需要交换 Mailbox
- CellApp 之间共享 Ghost 时,需要互相通过 Mailbox 同步状态
- BaseApp 调用 Client(玩家客户端)需要 Client Mailbox
- CellApp 调用 Base(代理)需要 Base Mailbox 或 CellViaBase Mailbox
- 跨 BaseApp 的 Service 调用(Service Fragment)需要 Service Mailbox
- DBApp 写回数据时,BaseApp 通过 Mailbox 接收回复
- 故障切换时,Mailbox 自动重定向到新 BaseApp

简而言之,**Mailbox 是 BigWorld 集群内部任何跨进程通信的起点和终点**。

---

## 二、位置透明性与通信模型对比

### 2.1 位置透明性的实现原理

BigWorld 的位置透明性建立在以下机制上:

```
脚本调用 entity.cell.method(args)
        ↓
PyEntityMailBox::pyGetAttribute("method")
        ↓
返回 RemoteEntityMethod 代理对象
        ↓
RemoteEntityMethod::pyCall(args)
        ↓
PyEntityMailBox::callMethod(methodDesc, args)
        ↓
getStream()  // 在 Bundle 中写入消息头
        ↓
addToServerStream() / addToClientStream()  // 序列化参数
        ↓
sendStream()  // 通过 Channel 发送
        ↓
Mercury UDPChannel → 远端进程
        ↓
远端 Entity::callMethodXXX() 接收
        ↓
MethodDescription::callMethod(self, data)  // 反序列化、调用 Python
```

整个流程中,脚本只感知"调用 → 返回 Deferred → 异步结果",完全不需要关心目标在哪个进程。这是通过以下技术达成的:

1. **PyTypeObject 的属性拦截**:`pyGetAttribute` 是虚函数,Mailbox 派生类各自实现 `findMethod`
2. **MethodDescription 的统一描述**:服务端和客户端使用同一份 .def 文件描述方法签名
3. **Bundle 的流式序列化**:任何参数都通过 `<<` 操作符写入 BinaryOStream
4. **Channel 的复用**:同一目标进程的所有 Mailbox 共享一个 UDPChannel

### 2.2 与 RPC 的对比

| 维度 | 传统 RPC | BigWorld Mailbox |
|------|---------|-----------------|
| 调用语义 | 同步阻塞 | 默认异步,显式 two-way 才返回 |
| 接口描述 | IDL(Protobuf/Thrift) | .def 文件,MethodDescription |
| 传输协议 | TCP | UDP(Mercury),可靠性由 Channel 实现 |
| 服务发现 | DNS/Consul | 通过 Mailbox 直接定位 |
| 流量控制 | 通常无 | Bundle + Channel + Window |
| 失败模式 | 超时 / 异常 | 消息丢失 / 故障重定向 |
| 双向调用 | 通常单向请求-响应 | Mailbox 双向可调用,通过 replyID 关联 |
| 类型安全 | 编译期 | 运行时(.def 加载时校验) |
| 调用对象 | 通常 stub | Mailbox 本身就是"对象引用" |

### 2.3 与 Actor Model 的对比

Actor Model(Erlang/Akka)的核心思想是"一切皆 Actor,Actor 之间只能通过消息通信"。BigWorld Mailbox 与之有相似之处,但差异显著:

| 维度 | Erlang/Akka Actor | BigWorld Mailbox |
|------|------------------|-----------------|
| 标识 | PID(进程标识) | EntityMailBoxRef(id+addr+component+type) |
| 状态隔离 | 强隔离,Actor 状态不可外窥 | 弱隔离,Cell 实体共享空间状态 |
| 消息顺序 | 单 Actor 内消息严格有序 | UDPChannel 内有序,跨 Channel 无序 |
| 消息内容 | 任意 Erlang 项 | .def 描述的强类型参数 |
| 故障处理 | let-it-crash + 监督树 | 备份 + 重定向 |
| 调用方式 | `Pid ! Msg` 单向 | `mailbox.method(args)` 类方法调用 |
| 返回值 | 通过显式回复消息 | 通过 Deferred 或 replyID |
| 位置透明 | 内置(分布式 Erlang) | 内置(Mailbox + Mercury) |

Mailbox 的设计更接近"远程对象引用 + 远程方法调用",而不是纯粹的 Actor 模型。BigWorld 没有采用"消息不可变"的强约束,序列化时允许传入 Python 对象(通过 DataType 转换)。

### 2.4 与 Message Queue 的对比

Message Queue(Kafka/RabbitMQ)是另一种进程间通信模型。区别如下:

| 维度 | Message Queue | BigWorld Mailbox |
|------|--------------|-----------------|
| 通信模式 | 发布订阅 / 队列 | 点对点(显式地址) |
| 持久化 | 消息持久化 | Mailbox 可序列化,但消息不持久化 |
| 中间件 | 需要 Broker | 无 Broker,直连 |
| 延迟 | 通常 ms 级 | 通常 sub-ms 级(UDP 直连) |
| 解耦 | 强解耦(生产者消费者不感知) | 弱解耦(必须知道对方 Mailbox) |
| 适用场景 | 异步任务、事件流 | 实时游戏逻辑、状态同步 |

BigWorld 不使用 MQ 的原因是延迟敏感:玩家技能、移动等操作延迟必须 < 100ms,MQ 的 Broker 中转开销过大。

### 2.5 与 gRPC 的对比

gRPC 是 Google 推出的现代 RPC 框架,采用 HTTP/2 + Protobuf,与 BigWorld Mailbox 的对比:

| 维度 | gRPC | BigWorld Mailbox |
|------|------|----------------|
| 协议 | HTTP/2 over TCP | UDP(Mercury) |
| 序列化 | Protobuf | 内置 DataType 体系 |
| 流式 | 支持 stream | 通过 Bundle 累积,不支持 stream |
| 双向 | 支持双向流 | 仅请求-响应或单向 |
| 服务发现 | xDS / DNS | Mercury Channel 直连 |
| 跨语言 | 支持 11 种语言 | 仅 Python + C++ |
| 延迟 | ~1ms | ~0.1ms(UDP,无握手) |
| 流控 | HTTP/2 flow control | Channel window |

BigWorld 选择 UDP 自建协议,而不是 TCP + gRPC,主要因为:

1. **UDP 无连接开销**:每个包独立,无握手、无重传开销(由 Channel 层实现可靠性)
2. **支持不可靠消息**:AOI 更新等容忍丢失的消息可用不可靠方式发送,降低延迟
3. **避免 TCP 队头阻塞**:TCP 一个包丢失会阻塞后续所有包,UDP 不会
4. **历史原因**:BigWorld 协议设计早于 gRPC 多年

---

## 三、7 种 Component 类型详解

### 3.1 Component 枚举定义

`EntityMailBoxRef::Component` 枚举定义了 8 种 Component 类型(实际上是 7 种通信目标 + 1 种 Service),源码位于 `lib/network/basictypes.hpp`:

```cpp
// lib/network/basictypes.hpp:322-365
class EntityMailBoxRef
{
public:
    EntityID            id;
    Mercury::Address    addr;

    enum Component
    {
        CELL = 0,
        BASE = 1,
        CLIENT = 2,
        BASE_VIA_CELL = 3,
        CLIENT_VIA_CELL = 4,
        CELL_VIA_BASE = 5,
        CLIENT_VIA_BASE = 6,
        SERVICE = 7
    };
    // ...
};
```

这 8 个枚举值可以分为三类:

- **3 种直接 Mailbox**:CELL、BASE、CLIENT、SERVICE(SERVICE 复用 BASE 通道)
- **4 种 _VIA_ Mailbox**:BASE_VIA_CELL、CLIENT_VIA_CELL、CELL_VIA_BASE、CLIENT_VIA_BASE

注意:虽然枚举有 8 个,但严格意义上"7 种通信目标"是 CELL/BASE/CLIENT/SERVICE 4 种,加上 4 种 VIA 转发变体。本专题遵循读者直觉,将枚举值统一称为"7 种 Component 类型"(因 SERVICE 与 BASE 共用通道,概念上视为 BASE 的特化)。

### 3.2 各 Component 类型详解

#### 3.2.1 CELL(=0)— Cell 实体 Mailbox

**用途**:指向某个实体在 CellApp 上的 Cell 实例(空间中的实体)。

**典型场景**:
- Base 实体通过 `self.cell.method()` 调用其 Cell
- 跨进程实体通过 `otherEntity.cell.method()` 调用对方 Cell
- CellApp 之间共享 Ghost 时,通过 Cell Mailbox 通信

**特征**:
- 实体必须 `canBeOnCell()`,即在 .def 中有 `CellMethods` 段
- 在 CellApp 中存在 `CellEntityMailBox` 实现
- 在 BaseApp 中存在 `CellEntityMailBox` 实现(用途不同)
- **不可持久化存储**:Cell Mailbox 在 BaseApp 中可以临时持有,但持久化到 DB 时只能存 BASE Mailbox
- **目标进程**:CellApp

**源码实现**:
- `cellapp/mailbox.cpp` 中 `CellEntityMailBox`(本进程内调用其他 CellApp)
- `baseapp/mailbox.cpp` 中 `CellEntityMailBox`(调用本 BaseApp 上 Base 的对应 Cell)

#### 3.2.2 BASE(=1)— Base 实体 Mailbox

**用途**:指向某个实体在 BaseApp 上的 Base 实例(玩家代理、全局实体)。

**典型场景**:
- Cell 实体通过 `self.base.method()` 调用其 Base
- 跨进程实体通过 `other.base.method()` 调用对方 Base
- BaseApp 之间互相通信(Service Fragment 也使用此通道)

**特征**:
- 实体必须 `canBeOnBase()`,即在 .def 中有 `BaseMethods` 段
- **可持久化存储**:Base Mailbox 可以保存到 DB,通过 EntityMailBoxRef 12 字节
- 故障时可重定向:通过 BackupHashChain 找到新 BaseApp
- **目标进程**:BaseApp

#### 3.2.3 CLIENT(=2)— Client 实体 Mailbox

**用途**:指向某个实体在客户端上的实例(玩家自己的客户端)。

**典型场景**:
- Base 实体通过 `self.client.method()` 调用客户端
- 只能调用 `ownClient`(自身代理的客户端),不能调用其他客户端

**特征**:
- 实体必须 `canBeOnClient()`,即在 .def 中有 `ClientMethods` 段
- 必须是 Proxy 类型的 Base 才能持有 Client Mailbox
- **不能直接调用其他客户端的 Client Mailbox**:必须通过对方 Base 转发
- **不可持久化**:客户端断开就消失
- **目标进程**:Client(玩家进程)

#### 3.2.4 BASE_VIA_CELL(=3)— 通过 Cell 转发到 Base

**用途**:从 CellApp 调用某实体的 Base,但不直接发到 BaseApp,而是先发到 CellApp 上的该实体,再由其转发到 Base。

**典型场景**:
- 在 CellApp 中,实体 A 持有实体 B 的 Cell Mailbox,想调用 B 的 Base:
  ```python
  # 在 CellApp 中的脚本
  def example(self, bCellMB):
      bCellMB.base.onSomeEvent()  # 通过 b 的 Cell 转发到 b 的 Base
  ```

**优势**:
- CellApp 不需要知道 B 的 Base 在哪个 BaseApp(避免 BaseApp 地址查询)
- 通过 Cell 转发,Cell 自然知道自己的 Base 在哪里

**限制**:
- 不可持久化(因为 Cell Mailbox 不可持久化)
- 必须立即使用,不能存储

#### 3.2.5 CLIENT_VIA_CELL(=4)— 通过 Cell 转发到 Client

**用途**:从 CellApp 调用某实体的 Client,通过 Cell 转发到 Base,再由 Base 转发到 Client。

**典型场景**:
- 在 CellApp 中,实体 A 持有实体 B 的 Cell Mailbox,想调用 B 的 Client:
  ```python
  def example(self, bCellMB):
      bCellMB.client.showSomeEvent()  # 通过 b 的 Cell → b 的 Base → b 的 Client
  ```

**特征**:
- 链路最长:CellA → CellB → BaseB → ClientB
- 通常用于跨实体客户端通知

#### 3.2.6 CELL_VIA_BASE(=5)— 通过 Base 转发到 Cell

**用途**:从某进程调用某实体的 Cell,但通过其 Base 转发。

**典型场景**:
- 在 CellApp 中,实体 A 持有实体 B 的 Base Mailbox,想调用 B 的 Cell:
  ```python
  def example(self, bBaseMB):
      bBaseMB.cell.onSomeEvent()  # 通过 b 的 Base 转发到 b 的 Cell
  ```

**优势**:
- CellApp 中持有 Base Mailbox 比持有 Cell Mailbox 更通用(可持久化)
- 当需要调用对方 Cell 时,通过 Base 中转

#### 3.2.7 CLIENT_VIA_BASE(=6)— 通过 Base 转发到 Client

**用途**:从 CellApp 调用某实体的 Client,通过其 Base 转发。

**典型场景**:
- 在 CellApp 中,实体 A 持有实体 B 的 Base Mailbox,想调用 B 的 Client:
  ```python
  def example(self, bBaseMB):
      bBaseMB.client.showSomeEvent()  # 通过 b 的 Base 转发到 b 的 Client
  ```

**特征**:
- 链路:CellA → BaseB → ClientB
- 通常用于跨实体客户端通知

#### 3.2.8 SERVICE(=7)— Service 服务 Mailbox

**用途**:指向 BaseApp 上某个 Service Fragment(服务分片)。

**典型场景**:
- 跨 BaseApp 调用 Service(如全局聊天服务、邮件服务)
- Service 通过 `BaseEntityMailBox` 实现复用

**特征**:
- Component 类型为 `SERVICE` 时,在 `BaseEntityMailBox::component()` 中返回:
  ```cpp
  // baseapp/mailbox.cpp:1092-1096
  EntityMailBoxRef::Component BaseEntityMailBox::component() const
  {
      return pLocalType_->isService() ? EntityMailBoxRef::SERVICE :
          EntityMailBoxRef::BASE;
  }
  ```
- Service Fragment 不参与故障重定向(因为是逻辑服务,无备份)
- 通过 `ServicesMap` 进行服务发现

### 3.3 Component 类型对照表

| 枚举值 | 名称 | 通信目标 | 中转 | 可持久化 | 用途 |
|--------|------|---------|------|---------|------|
| 0 | CELL | CellApp 上的 Cell | 直连 | 否 | 调用空间实体方法 |
| 1 | BASE | BaseApp 上的 Base | 直连 | 是 | 调用玩家代理方法 |
| 2 | CLIENT | Client | 直连 | 否 | 调用玩家客户端方法 |
| 3 | BASE_VIA_CELL | Base | 经 Cell | 否 | Cell 中转调用 Base |
| 4 | CLIENT_VIA_CELL | Client | 经 Cell | 否 | Cell 中转调用 Client |
| 5 | CELL_VIA_BASE | Cell | 经 Base | 是 | Base 中转调用 Cell |
| 6 | CLIENT_VIA_BASE | Client | 经 Base | 是 | Base 中转调用 Client |
| 7 | SERVICE | BaseApp Service | 直连 | 是 | 调用 Service Fragment |

### 3.4 Component 编码技巧

`EntityMailBoxRef` 把 Component 类型和 EntityTypeID 巧妙编码到 `Mercury::Address::salt` 字段中(原本 salt 用于 Channel 鉴权):

```cpp
// lib/network/basictypes.hpp:347-351
Component component() const     { return (Component)(addr.salt >> 13); }
void component( Component c )   { addr.salt = type() | (uint16(c) << 13); }
EntityTypeID type() const       { return addr.salt & 0x1FFF; }
void type( EntityTypeID t )    { addr.salt = (addr.salt & 0xE000) | t; }
```

`addr.salt` 是 `uint16`,16 bit 分配如下:

```
  bit 15  bit 14  bit 13 | bit 12 ... bit 0
  [    Component 3 bit  ] [  EntityTypeID 13 bit ]
       (8 种类型)              (8192 种实体类型)
```

这种编码使 `EntityMailBoxRef` 总大小为 `sizeof(EntityID) + sizeof(Address)` = 4 + 8 = **12 字节**,极其紧凑。

### 3.5 Component 字符串表示

`componentAsStr` 函数将 Component 枚举转为可读字符串,源码如下:

```cpp
// lib/network/basictypes.cpp:237-252
const char * EntityMailBoxRef::componentAsStr( Component component )
{
    switch (component)
    {
        case EntityMailBoxRef::CELL:               return "cell";
        case EntityMailBoxRef::BASE:               return "base";
        case EntityMailBoxRef::SERVICE:            return "service";
        case EntityMailBoxRef::CLIENT:             return "client";
        case EntityMailBoxRef::BASE_VIA_CELL:      return "base_via_cell";
        case EntityMailBoxRef::CLIENT_VIA_CELL:    return "client_via_cell";
        case EntityMailBoxRef::CELL_VIA_BASE:       return "cell_via_base";
        case EntityMailBoxRef::CLIENT_VIA_BASE:    return "client_via_base";
    }
    return "<invalid>";
}
```

在 `pyRepr()` 中,Mailbox 的字符串表示也使用类似的映射:

```cpp
// lib/entitydef/mailbox_base.cpp:392-408
PyObject * PyEntityMailBox::pyRepr()
{
    EntityMailBoxRef embr;
    PyEntityMailBox::reduceToRef( this, &embr );
    const char * location =
        (embr.component() == EntityMailBoxRef::CELL)   ? "Cell" :
        (embr.component() == EntityMailBoxRef::BASE)   ? "Base" :
        (embr.component() == EntityMailBoxRef::CLIENT) ? "Client" :
        (embr.component() == EntityMailBoxRef::BASE_VIA_CELL)   ? "BaseViaCell" :
        (embr.component() == EntityMailBoxRef::CLIENT_VIA_CELL) ? "ClientViaCell" :
        (embr.component() == EntityMailBoxRef::CELL_VIA_BASE)   ? "CellViaBase" :
        (embr.component() == EntityMailBoxRef::CLIENT_VIA_BASE) ? "ClientViaBase" :
        (embr.component() == EntityMailBoxRef::SERVICE) ? "Service" : "???";

    return PyString_FromFormat( "%s mailbox id: %d type: %d addr: %s",
            location, embr.id, embr.type(), embr.addr.c_str() );
}
```

例如 `Base mailbox id: 1234 type: 5 addr: 192.168.1.10:30001`。

---

## 四、Mailbox 类层次结构

### 4.1 总体类图

BigWorld 的 Mailbox 类层次结构在不同进程中略有不同,但都继承自 `PyEntityMailBox`。下图展示完整层次:

```
                          PyEntityMailBox (lib/entitydef/mailbox_base.hpp)
                          ├── 数据成员: s_population_ 静态链表
                          ├── 纯虚: findMethod, getStream, sendStream, id, address
                          ├── 静态: constructFromRef, reduceToRef, visit
                          │
                ┌─────────┴──────────┐
                │                    │
        ServerEntityMailBox    ClientEntityMailBox (baseapp)
        (cellapp + baseapp)    - 直接给 Client 发消息
                │
        ┌───────┴────────┬───────────────┐
        │                │               │
   CellEntityMailBox  BaseEntityMailBox  CommonBaseEntityMailBox (cellapp)
   - 直接调用 Cell    - 直接调用 Base    - 通过 Base 转发的公共基类
        │                │               │
        │                │        ┌──────┴────────┬──────────────┐
        │                │        │               │              │
        │                │ CellViaBase    ClientViaBase   (BaseEntityMailBox
        │                │ MailBox        MailBox         复用 CommonBase)
        │                │
   BaseViaCellMailBox    │
   (经 Cell 调 Base)      │
        │                │
   ClientViaCellMailBox  │
   (经 Cell 调 Client)   │
                         │
                  CommonCellEntityMailBox (baseapp)
                  - 通过 Cell 转发的公共基类
                         │
                  ┌──────┴────┐
                  │           │
              BaseViaCell  CellEntityMailBox
              MailBox      (baseapp 实现)
              (经 Cell
               调 Base)
```

### 4.2 关键文件位置

| 类 | 文件路径 | 作用 |
|----|---------|------|
| `PyEntityMailBox` | `lib/entitydef/mailbox_base.hpp/cpp` | Mailbox 抽象基类 |
| `ServerEntityMailBox` (CellApp) | `server/cellapp/mailbox.hpp/cpp` | CellApp 上的服务端 Mailbox 中间层 |
| `ServerEntityMailBox` (BaseApp) | `server/baseapp/mailbox.hpp/cpp` | BaseApp 上的服务端 Mailbox 中间层 |
| `CellEntityMailBox` | 同上文件 | Cell Mailbox 实现 |
| `BaseEntityMailBox` | 同上文件 | Base Mailbox 实现 |
| `CommonBaseEntityMailBox` (CellApp) | `server/cellapp/mailbox.hpp` | CellApp 上的经 Base 转发公共基类 |
| `CommonCellEntityMailBox` (BaseApp) | `server/baseapp/mailbox.hpp` | BaseApp 上的经 Cell 转发公共基类 |
| `CellViaBaseMailBox` | 同 server mailbox.cpp | 经 Base 调 Cell |
| `BaseViaCellMailBox` | 同 server mailbox.cpp | 经 Cell 调 Base |
| `ClientViaCellMailBox` | 同 server mailbox.cpp | 经 Cell 调 Client |
| `ClientViaBaseMailBox` | 同 server mailbox.cpp | 经 Base 调 Client |
| `ClientEntityMailBox` | `server/baseapp/client_entity_mailbox.hpp/cpp` | 客户端 Mailbox(BaseApp 内) |
| `UnittestMailBox` | `lib/entitydef/unit_test/unittest_mailbox.hpp` | 单元测试用 Mailbox |
| `PyEntityMailBoxVisitor` | `lib/entitydef/mailbox_base.hpp` | Visitor 模式基类 |
| `MigrateMailBoxVisitor` | `lib/server/migrate_mailbox_visitor.hpp` | 迁移 Visitor |
| `BaseBackupSwitchMailBoxVisitor` | `lib/server/base_backup_switch_mailbox_visitor.hpp/cpp` | 故障切换 Visitor |
| `EntityMailBoxRef` | `lib/network/basictypes.hpp/cpp` | 网络表示,12 字节结构 |
| `MailBoxDataType` | `lib/entitydef/data_types/mailbox_data_type.hpp/cpp` | DataType 系统 |
| `RemoteEntityMethod` | `lib/entitydef/remote_entity_method.hpp/cpp` | 远程方法代理对象 |

### 4.3 PyEntityMailBox 基类

`PyEntityMailBox` 是所有 Mailbox 的抽象基类,定义了所有 Mailbox 必须实现的接口:

```cpp
// lib/entitydef/mailbox_base.hpp:55-121
class PyEntityMailBox: public PyObjectPlus
{
    Py_Header( PyEntityMailBox, PyObjectPlus )

public:
    PyEntityMailBox( PyTypeObject * pType = &PyEntityMailBox::s_type_ );
    virtual ~PyEntityMailBox();

    virtual ScriptObject pyGetAttribute( const ScriptString & attrObj );

    PyObject * pyRepr();

    // 以下是子类必须实现的纯虚函数
    virtual const MethodDescription * findMethod( const char * attr ) const = 0;
    virtual BinaryOStream * getStream( const MethodDescription & methodDesc, 
            std::auto_ptr< Mercury::ReplyMessageHandler > pHandler =
                std::auto_ptr< Mercury::ReplyMessageHandler >() ) = 0;
    virtual void sendStream() = 0;
    static PyObject * constructFromRef( const EntityMailBoxRef & ref );
    static bool reduceToRef( PyObject * pObject, EntityMailBoxRef * pRefOutput );

    virtual EntityID id() const = 0;
    virtual void address( const Mercury::Address & addr ) = 0;
    virtual const Mercury::Address address() const = 0;

    virtual void migrate() {}

    // 工厂注册机制
    typedef PyObject * (*FactoryFn)( const EntityMailBoxRef & ref );
    static void registerMailBoxComponentFactory(
        EntityMailBoxRef::Component c, FactoryFn fn,
        PyTypeObject * pType );

    typedef bool (*CheckFn)( PyObject * pObject );
    typedef EntityMailBoxRef (*ExtractFn)( PyObject * pObject );
    static void registerMailBoxRefEquivalent( CheckFn cf, ExtractFn ef );

    // Python 属性
    PY_RO_ATTRIBUTE_DECLARE( this->id(), id );
    PyObject * pyGet_address();
    PY_RO_ATTRIBUTE_SET( address );
    
    PY_AUTO_METHOD_DECLARE( RETOWN, callMethod, 
        ARG( ScriptString, ARG( ScriptTuple, END ) ) );
    PyObject * callMethod(
        const ScriptString & methodName, const ScriptTuple & arguments  );
    PyObject * callMethod( 
        const MethodDescription * methodDescription,
        const ScriptTuple & args );

    PY_PICKLING_METHOD_DECLARE( MailBox )

    static void visit( PyEntityMailBoxVisitor & visitor );
    static bool parseRecordingOptionFromPythonCall(
        PyObject * args, PyObject * kwargs, RecordingOption & recordingOption );
private:
    typedef BW::list< PyEntityMailBox * > Population;
    static Population s_population_;

    Population::iterator populationIter_;
};
```

### 4.4 类层次的关键设计决策

1. **使用抽象基类 + 工厂注册**:不同进程(BaseApp/CellApp/Client)对同一 `EntityMailBoxRef` 有不同的具体 Mailbox 实现,通过 `registerMailBoxComponentFactory` 在进程启动时注册
2. **Python 对象**:所有 Mailbox 都是 `PyObjectPlus` 派生类,可被 Python 脚本持有
3. **虚函数实现多态**:`findMethod`、`getStream`、`sendStream`、`component` 等都是虚函数,不同 Component 类型有不同的实现
4. **静态 Population 链表**:所有 Mailbox 自动注册到 `s_population_`,便于全局遍历(用于迁移、故障重定向)
5. **智能指针持有**:`RemoteEntityMethod` 通过 `SmartPointer<PyEntityMailBox>` 持有 Mailbox,防止悬挂

---

## 五、EntityMailBoxRef 网络表示

### 5.1 数据结构定义

`EntityMailBoxRef` 是 Mailbox 的"网络序列化形式",12 字节紧凑结构:

```cpp
// lib/network/basictypes.hpp:322-365
class EntityMailBoxRef
{
public:
    EntityID            id;        // 4 bytes - 实体 ID
    Mercury::Address    addr;      // 8 bytes - 地址(IP+Port+Salt)

    enum Component
    {
        CELL = 0,
        BASE = 1,
        CLIENT = 2,
        BASE_VIA_CELL = 3,
        CLIENT_VIA_CELL = 4,
        CELL_VIA_BASE = 5,
        CLIENT_VIA_BASE = 6,
        SERVICE = 7
    };

    EntityMailBoxRef():
        id( 0 ),
        addr( Mercury::Address::NONE )
    {}
    
    bool hasAddress() const         { return addr != Mercury::Address::NONE; }

    Component component() const    { return (Component)(addr.salt >> 13); }
    void component( Component c )   { addr.salt = type() | (uint16(c) << 13); }

    EntityTypeID type() const       { return addr.salt & 0x1FFF; }
    void type( EntityTypeID t )    { addr.salt = (addr.salt & 0xE000) | t; }

    void init() { id = 0; addr.ip = 0; addr.port = 0; addr.salt = 0; }
    void init( EntityID i, const Mercury::Address & a,
        Component c, EntityTypeID t )
    { id = i; addr = a; addr.salt = (uint16(c) << 13) | t; }

    static const char * componentAsStr( Component component );

    const char * componentName() const
    {
        return componentAsStr( this->component() );
    }
};
```

### 5.2 Mercury::Address 结构

`Mercury::Address` 是 Mercury 网络层的地址表示,定义如下:

```cpp
// lib/network/basictypes.hpp:271-304
namespace Mercury
{
    class Address
    {
    public:
        Address();
        Address( uint32 ipArg, uint16 portArg );

        uint32  ip;     // 4 bytes - IP 地址
        uint16  port;   // 2 bytes - 端口
        uint16  salt;   // 2 bytes - 用于 Channel 鉴权 + Mailbox 编码

        // ...
        bool isNone() const { return this->ip == 0; }

        static const Address NONE;
    };
}
```

`Address` 共 8 字节,其中 `salt` 字段在 Mailbox 场景下被复用编码 Component 和 EntityTypeID。

### 5.3 序列化与反序列化

`EntityMailBoxRef` 通过 BinaryStream 序列化,操作符重载位于 `lib/network/basictypes.cpp`:

```cpp
// lib/network/basictypes.cpp:199-219
BinaryOStream& operator<<( BinaryOStream &os, const Address &a )
{
    os.insertRaw( a.ip );      // 4 bytes, raw
    os.insertRaw( a.port );    // 2 bytes, raw
    os << a.salt;               // 2 bytes, network byte order

    return os;
}

BinaryIStream& operator>>( BinaryIStream &is, Address &a )
{
    is.extractRaw( a.ip );
    is.extractRaw( a.port );
    is >> a.salt;

    return is;
}
```

注意 `ip` 和 `port` 使用 `insertRaw`/`extractRaw`(不做字节序转换,因为 IP 和端口本身就是网络字节序),而 `salt` 使用 `<<`/`>>`(做字节序转换,因为它承载 Component 和 TypeID)。

`EntityMailBoxRef` 整体的序列化通过 `>>` 和 `<<` 操作符:

```cpp
// 12 bytes total: 4 (id) + 8 (addr)
BinaryOStream& operator<<( BinaryOStream &os, const EntityMailBoxRef &ref )
{
    os << ref.id;       // 4 bytes
    os << ref.addr;     // 8 bytes
    return os;
}
```

### 5.4 streamSize

`MailBoxDataType::streamSize()` 返回 Mailbox 在流中的固定大小:

```cpp
// lib/entitydef/data_types/mailbox_data_type.cpp:99-105
int MailBoxDataType::streamSize() const
{
    return sizeof( EntityMailBoxRef );  // = 12 bytes
}
```

这是固定大小,使 MethodDescription 可以预先计算消息总长度。

### 5.5 EntityMailBoxRef 与 PyEntityMailBox 的转换

两个方向:

**PyEntityMailBox → EntityMailBoxRef**(reduceToRef):

```cpp
// lib/entitydef/mailbox_base.cpp:290-320
bool PyEntityMailBox::reduceToRef( PyObject * pObject, 
        EntityMailBoxRef * pRefOutput )
{
    if (pObject == Py_None)
    {
        if (pRefOutput) pRefOutput->init();
        return true;    
    }

    if (s_pRefReg != NULL)
    {
        for (Interpreters::iterator it = s_pRefReg->inps_.begin();
            it != s_pRefReg->inps_.end();
            it++)
        {
            if ((*it->first)( pObject ))  // CheckFn
            {
                if (pRefOutput != NULL)
                {
                    *pRefOutput = (*it->second)( pObject );  // ExtractFn
                }
                return true;
            }
        }
    }

    return false;
}
```

`registerMailBoxRefEquivalent` 注册"可识别为 Mailbox 的对象"及其 reduce 函数。例如,BaseApp 注册了 `Base::Check` + `baseReduce`,CellApp 注册了 `Entity::Check` + `cellReduce`,使得本地实体也可以被 reduce 为 EntityMailBoxRef(自动取其真实地址)。

**EntityMailBoxRef → PyEntityMailBox**(constructFromRef):

```cpp
// lib/entitydef/mailbox_base.cpp:241-264
PyObject * PyEntityMailBox::constructFromRef(
    const EntityMailBoxRef & ref )
{
    if (ref.id == 0) Py_RETURN_NONE;

    if (s_pRefReg == NULL) Py_RETURN_NONE;

    Fabricators::iterator found = s_pRefReg->fabs_.find( ref.component() );
    if (found == s_pRefReg->fabs_.end()) Py_RETURN_NONE;

    PyObject * pResult = (*found->second)( ref );  // 调用 FactoryFn

    if (pResult)
    {
        return pResult;
    }
    else
    {
        WARNING_MSG( "PyEntityMailBox::constructFromRef: "
                "Could not create mailbox from id %d. addr %s. component %d\n",
                ref.id, ref.addr.c_str(), ref.component() );
        Py_RETURN_NONE;
    }
}
```

### 5.6 EntityMailBoxRef 在不同场景的存储

`EntityMailBoxRef` 作为 12 字节紧凑结构,出现在:

1. **网络消息**:作为方法参数被序列化(Bundle)
2. **持久化存储**:写入 DB 时,Mailbox 类型的 Property 通过 `MailBoxDataType::to(., DataSection)` 写为 `<id>`, `<ip>`, `<etc>`(port+salt 合并)
3. **Python Pickling**:通过 `pyPickleReduce` 把 Mailbox 转为长度为 sizeof(EntityMailBoxRef) 的字符串
4. **DataType 系统**:`MailBoxDataType` 在 .def 中标记为 `MAILBOX` 类型

`MailBoxDataType` 持久化到 DataSection 的实现:

```cpp
// lib/entitydef/data_types/mailbox_data_type.cpp:244-257
void MailBoxDataType::from( DataSectionPtr pSection, EntityMailBoxRef & mbr )
{
    mbr.id = pSection->readInt( "id" );
    mbr.addr.ip = pSection->readInt( "ip" );
    (uint32&)mbr.addr.port = pSection->readInt( "etc" );  // port+salt 合并
}

void MailBoxDataType::to( const EntityMailBoxRef & mbr, DataSectionPtr pSection )
{
    pSection->writeInt( "id", mbr.id );
    pSection->writeInt( "ip", mbr.addr.ip );
    pSection->writeInt( "etc", (uint32&)mbr.addr.port );  // 写回 port+salt
}
```

注意这里把 `port` 和 `salt` 合并为一个 32-bit 整数存储,这种简化牺牲了语义清晰性但减少了存储字段数。

### 5.7 EntityMailBoxRef 的合法性校验

`MailBoxDataType::isSameType` 在写入 Mailbox 类型 Property 时进行校验:

```cpp
// lib/entitydef/data_types/mailbox_data_type.cpp:34-63
bool MailBoxDataType::isSameType( ScriptObject pValue )
{
    if (pValue.isNone())
    {
        return true;
    }

    // Disallow non-None mailboxes with zero-IP - these are usually mailboxes
    // pending resolution of the remote side, that have been allowed to have
    // methods buffered onto them.  An example is cell mailboxes on base
    // entities after calling createCellEntity() etc. but before the
    // onGetCell() callback.
    EntityMailBoxRef ref;
    if (!PyEntityMailBox::reduceToRef( pValue.get(), &ref ))
    {
        return false;
    }

    if (ref.addr.ip == 0)
    {
        WARNING_MSG( "MailBoxDataType::isSameType: "
                "Mailbox for entity %d has not been fully initialised yet "
                "(IP address is zero)\n",
            ref.id );
        return false;
    }

    return true;
}
```

这防止了"半初始化 Mailbox"被存入 Property,避免后续故障。

---

## 六、PyEntityMailBox 基类深度剖析

### 6.1 构造与析构:Population 管理

每个 `PyEntityMailBox` 在构造时自动加入全局链表 `s_population_`,析构时移除:

```cpp
// lib/entitydef/mailbox_base.cpp:61
PyEntityMailBox::Population PyEntityMailBox::s_population_;

// lib/entitydef/mailbox_base.cpp:104-110
PyEntityMailBox::PyEntityMailBox( 
            PyTypeObject * pType /* = &PyEntityMailBox::s_type_ */ ) :
        PyObjectPlus( pType ),
        populationIter_()
{
    populationIter_ = s_population_.insert( s_population_.end(), this );
}

// lib/entitydef/mailbox_base.cpp:116-119
PyEntityMailBox::~PyEntityMailBox()
{
    s_population_.erase( populationIter_ );
}
```

注意几个细节:

1. **使用 list 而非 vector**:list 的 iterator 不会因其他元素插入/删除而失效,析构时只需 O(1) 操作
2. **保存 iterator 而非指针**:析构时直接用 iterator 删除,无需查找
3. **插入位置是 end()**:用 `s_population_.insert(s_population_.end(), this)`,相当于 push_back,保证迭代顺序

### 6.2 属性访问:pyGetAttribute

`pyGetAttribute` 是 Mailbox 与 Python 交互的核心入口,它把"访问属性"转化为"创建远程方法代理":

```cpp
// lib/entitydef/mailbox_base.cpp:66-79
ScriptObject PyEntityMailBox::pyGetAttribute( const ScriptString & attrObj )
{
    const char * attr = attrObj.c_str();

    const MethodDescription * pDescription = this->findMethod( attr );
    if (pDescription)
    {
        return ScriptObject(
            new RemoteEntityMethod( this, pDescription ),
            ScriptObject::FROM_NEW_REFERENCE );
    }

    return PyObjectPlus::pyGetAttribute( attrObj );
}
```

当脚本访问 `mailbox.someMethod` 时:

1. 调用 `findMethod("someMethod")` 查找该方法
2. 如果找到,返回 `RemoteEntityMethod` 代理对象(不是直接调用)
3. 如果未找到,走基类逻辑(查找 `address`、`id` 等内置属性)

`findMethod` 是纯虚函数,不同 Component 类型返回不同 Component 的方法描述。例如 `CellEntityMailBox::findMethod` 返回 cell methods,`BaseEntityMailBox::findMethod` 返回 base methods。

### 6.3 callMethod:核心调用流程

`callMethod` 是 Mailbox 调用的核心,接受方法描述和参数元组:

```cpp
// lib/entitydef/mailbox_base.cpp:141-234
PyObject * PyEntityMailBox::callMethod( 
        const MethodDescription * pMethodDescription,
        const ScriptTuple & pArgs )
{
    if (!pMethodDescription->areValidArgs( true, pArgs, true ))
    {
        return NULL;
    }

    ReturnValuesHandler * pReplyHandler = NULL;
    PyObjectPtr pDeferred;

    // 如果方法有返回值,创建 ReplyHandler 和 Deferred
    if (pMethodDescription->hasReturnValues())
    {
        pReplyHandler = new ReturnValuesHandler( *pMethodDescription );
        pDeferred = pReplyHandler->getDeferred();
    }

    // 获取输出流(Bundle),把 replyHandler 一并传入
    BinaryOStream * pBOS = this->getStream( *pMethodDescription,
            std::auto_ptr< Mercury::ReplyMessageHandler >( pReplyHandler ) );

    if (pBOS == NULL)
    {
        MF_ASSERT( PyErr_Occurred() );

        PyErr_Print();
        WARNING_MSG( "PyEntityMailBox::callMethod: "
                " Could not get stream to call %s\n",
            pMethodDescription->name().c_str() );
        Py_RETURN_NONE;
    }

#if ENABLE_WATCHERS
    uint32 startingSize = pBOS->size();
#endif

    // 添加参数到流,CLIENT 方法用 addToClientStream,其他用 addToServerStream
    if (pMethodDescription->component() == MethodDescription::CLIENT)
    {
        ScriptDataSource source( pArgs );
        if (!pMethodDescription->addToClientStream( source, *pBOS, this->id() ))
        {
            return NULL;
        }
    }
    else
    {
        EntityID sourceEntityID;
        ScriptTuple remainingArgs =
            pMethodDescription->extractSourceEntityID( pArgs, sourceEntityID );

        ScriptDataSource source( remainingArgs );
        if (!pMethodDescription->addToServerStream( source, *pBOS,
                sourceEntityID ))
        {
            return NULL;
        }
    }

#if ENABLE_WATCHERS
    // 统计发送字节数,根据目标 Component 分类
    EntityMailBoxRef ref;
    PyEntityMailBox::reduceToRef( this, &ref );
    int bytesSent = pBOS->size() - startingSize;
    switch(ref.component())
    {
    case EntityMailBoxRef::CELL:
    case EntityMailBoxRef::BASE_VIA_CELL:
    case EntityMailBoxRef::CLIENT_VIA_CELL:
        pMethodDescription->stats().countSentToGhosts( bytesSent );
        break;
    case EntityMailBoxRef::BASE:
    case EntityMailBoxRef::SERVICE:
    case EntityMailBoxRef::CELL_VIA_BASE:
    case EntityMailBoxRef::CLIENT_VIA_BASE:
        pMethodDescription->stats().countSentToBase( bytesSent );
        break;
    case EntityMailBoxRef::CLIENT:
        pMethodDescription->stats().countSentToOwnClient( bytesSent );
        break;
    }
#endif // ENABLE_WATCHERS

    this->sendStream();  // 实际发送

    if (pDeferred)
    {
        Py_INCREF( pDeferred.get() );
        return pDeferred.get();  // 返回 Deferred 给脚本
    }
    else
    {
        Py_RETURN_NONE;
    }
}
```

#### 6.3.1 流程步骤详解

`callMethod` 完整流程如下:

```
1. 参数校验(areValidArgs)
   ├─ 失败 → 抛出 Python 异常,返回 NULL
   └─ 成功 → 继续

2. 创建返回值处理器(如有)
   ├─ hasReturnValues() == true
   │   ├─ 创建 ReturnValuesHandler
   │   └─ 创建 PyDeferred(Python 脚本异步等待)
   └─ hasReturnValues() == false
       └─ pReplyHandler = NULL

3. 获取输出流(getStream)
   ├─ 调用子类的 getStream 实现
   ├─ 在 Bundle 中写入消息头(startMessage/startRequest)
   └─ 返回 BinaryOStream 指针

4. 写入参数(addToServerStream/addToClientStream)
   ├─ CLIENT 方法:使用 addToClientStream
   │   └─ 参数包含 clientEntityID
   └─ 非 CLIENT 方法:使用 addToServerStream
       ├─ 提取 sourceEntityID(第一个参数为 EntityID 时)
       └─ 剩余参数序列化

5. 统计字节数(ENABLE_WATCHERS)
   ├─ 根据 Component 分类统计
   ├─ CELL/BASE_VIA_CELL/CLIENT_VIA_CELL → sentToGhosts
   ├─ BASE/SERVICE/CELL_VIA_BASE/CLIENT_VIA_BASE → sentToBase
   └─ CLIENT → sentToOwnClient

6. 发送(sendStream)
   └─ 调用子类的 sendStream,通过 Channel 发送

7. 返回值
   ├─ 有 Deferred → 返回 Deferred 对象
   └─ 无 → 返回 Py_None
```

#### 6.3.2 hasReturnValues 的判断

并非所有方法都有返回值。`hasReturnValues` 通过 .def 文件中 `ReturnValues` 段判断:

```xml
<!-- .def 文件 -->
<CellMethods>
    <onHit>
        <Arg> damage </Arg>
        <Arg> attackerID </Arg>
        <ReturnValues>
            <real> actualDamage </real>
        </ReturnValues>
    </onHit>
    
    <onMoveTo>
        <Arg> position </Arg>
        <!-- 无 ReturnValues,单向调用 -->
    </onMoveTo>
</CellMethods>
```

`onHit` 是 two-way 方法(有返回值),`onMoveTo` 是 one-way 方法(无返回值)。

只有 two-way 方法才会:
- 创建 `ReturnValuesHandler`
- 在 Bundle 中用 `startRequest` 而非 `startMessage`
- 返回 `Deferred` 对象

注意:从 CellApp 发出的调用不支持 two-way,源码中明确禁止:

```cpp
// cellapp/mailbox.cpp:92-99
if (pHandler.get())
{
    PyErr_Format( PyExc_TypeError,
            "Cannot call two-way method '%s' from CellApp",
            methodDesc.name().c_str() );
    return NULL;
}
```

### 6.4 callMethod 的字符串重载

`callMethod` 还有一个用方法名作为参数的重载:

```cpp
// lib/entitydef/mailbox_base.cpp:125-138
PyObject * PyEntityMailBox::callMethod(
        const ScriptString & methodName, const ScriptTuple & arguments  )
{
    const MethodDescription * pDescription = this->findMethod( 
        methodName.c_str() );
    if (!pDescription)
    {
        PyErr_Format( PyExc_TypeError, 
            "Unable to find method %s", methodName.c_str() );
        return NULL;
    }
    
    return this->callMethod( pDescription, arguments );
}
```

这暴露给 Python:

```python
# 等价于 mailbox.someMethod(args)
mailbox.callMethod("someMethod", args)
```

`callMethod` 暴露为 Python 方法,源码:

```cpp
// lib/entitydef/mailbox_base.cpp:30-39
PY_BEGIN_METHODS( PyEntityMailBox )
    PY_PICKLING_METHOD()
    /*~ function PyEntityMailBox callMethod
     *	@components{ base, cell }
     *
     *	This method is used to call a method
     *	which name is defined at run-time
     */
    PY_METHOD( callMethod )
PY_END_METHODS()
```

### 6.5 address 与 id 属性

`address` 和 `id` 是 Mailbox 的两个只读 Python 属性:

```cpp
// lib/entitydef/mailbox_base.hpp:98-100
PY_RO_ATTRIBUTE_DECLARE( this->id(), id );
PyObject * pyGet_address();
PY_RO_ATTRIBUTE_SET( address );
```

`pyGet_address` 把 Address 转为 Python 元组 `(ip_string, port)`:

```cpp
// lib/entitydef/mailbox_base.cpp:414-419
PyObject * PyEntityMailBox::pyGet_address()
{
    Mercury::Address address = this->address();
    return Py_BuildValue( "(sH)", address.ipAsString(), 
        ntohs( address.port ) );
}
```

注意 `ntohs(address.port)` 把网络字节序转为主机字节序,因为 Address 中 port 是网络序存储。

### 6.6 visit 与 Visitor 模式

`PyEntityMailBox::visit` 提供遍历所有 Mailbox 的能力,用于故障重定向、迁移等:

```cpp
// lib/entitydef/mailbox_base.cpp:337-347
void PyEntityMailBox::visit( PyEntityMailBoxVisitor & visitor )
{
    Population::iterator iPopulation = s_population_.begin();

    while (iPopulation != s_population_.end())
    {
        PyEntityMailBox * pMailBox = *iPopulation;
        ++iPopulation;  // 先递增,允许 visitor 在 onMailBox 中删除自己
        visitor.onMailBox( pMailBox );
    }
}
```

注意"先递增 iterator 再调用 visitor"的技巧:这允许 visitor 在 `onMailBox` 中析构当前 Mailbox(从 Population 移除),而不会导致迭代器失效。

`PyEntityMailBoxVisitor` 是抽象基类:

```cpp
// lib/entitydef/mailbox_base.hpp:26-46
class PyEntityMailBoxVisitor
{
public:
    PyEntityMailBoxVisitor() {}
    virtual ~PyEntityMailBoxVisitor() {}

    virtual void onMailBox( PyEntityMailBox * pMailBox ) = 0;
};
```

引擎内置两个 Visitor:

1. `MigrateMailBoxVisitor`:用于实体类型重载后更新 Mailbox 的 EntityType 指针
2. `BaseBackupSwitchMailBoxVisitor`:用于 BaseApp 故障后重定向 Mailbox 到新 BaseApp

### 6.7 Pickling 支持

Mailbox 支持 Python 的 pickle 协议,使其可以被序列化为字符串:

```cpp
// lib/entitydef/mailbox_base.cpp:357-367
PyObject * PyEntityMailBox::pyPickleReduce()
{
    EntityMailBoxRef embr;
    PyEntityMailBox::reduceToRef( this, &embr );

    PyObject * pConsArgs = PyTuple_New( 1 );
    PyTuple_SET_ITEM( pConsArgs, 0,
        PyString_FromStringAndSize( (char*)&embr, sizeof(embr) ) );

    return pConsArgs;
}
```

反序列化通过 `PyEntityMailBox_pyPickleResolve`:

```cpp
// lib/entitydef/mailbox_base.cpp:373-385
static PyObject * PyEntityMailBox_pyPickleResolve( const BW::string & str )
{
    if (str.size() != sizeof(EntityMailBoxRef))
    {
        PyErr_SetString( PyExc_ValueError, "PyEntityMailBox_pyPickleResolve: "
            "wrong length string to unpickle" );
        return NULL;
    }

    return PyEntityMailBox::constructFromRef( *(EntityMailBoxRef*)str.data() );
}
PY_AUTO_UNPICKLING_FUNCTION( RETOWN, PyEntityMailBox_pyPickleResolve,
    ARG( BW::string, END ), MailBox )
```

这使得 Python 脚本可以:

```python
import pickle
mailbox_str = pickle.dumps(entity.cell)
# ... later, possibly on different component ...
restored_mailbox = pickle.loads(mailbox_str)
```

### 6.8 RecordingOption 解析

对于 Client 类型的 Mailbox,`callMethod` 还支持解析 recording 选项(用于回放系统):

```cpp
// lib/entitydef/mailbox_base.cpp:432-470
bool PyEntityMailBox::parseRecordingOptionFromPythonCall(
        PyObject * args, PyObject * kwargs, RecordingOption & recordingOption )
{
    if (PySequence_Size( args ) > 0)
    {
        PyErr_SetString( PyExc_TypeError, 
                "Cannot call a mailbox object with positional parameters" );
        return false;
    }

    bool shouldExposeForReplay = false;
    bool shouldRecordOnly = false;

    KeywordParser options;
    options.add( "shouldExposeForReplay", shouldExposeForReplay );
    options.add( "shouldRecordOnly", shouldRecordOnly );

    KeywordParser::ParseResult parseResult = options.parse( kwargs,
        /* shouldRemove */ true, /* allowOtherArguments */ false );

    if (parseResult == KeywordParser::EXCEPTION_RAISED)
    {
        return false;
    }

    if (parseResult == KeywordParser::NONE_FOUND)
    {
        // No arguments, just return the defaults.
        recordingOption = RECORDING_OPTION_METHOD_DEFAULT;
        return true;
    }

    recordingOption = (shouldRecordOnly ? 
            RECORDING_OPTION_RECORD_ONLY :
            (shouldExposeForReplay ?
                RECORDING_OPTION_RECORD :
                RECORDING_OPTION_DO_NOT_RECORD));
    return true;
}
```

支持的录制选项:

```python
# 默认
self.client.method(args)
# 强制录制(用于回放)
self.client(shouldExposeForReplay=True).method(args)
# 仅录制,不发送
self.client(shouldRecordOnly=True).method(args)
# 不录制
self.client(shouldExposeForReplay=False).method(args)
```

`RecordingOption` 枚举:

```cpp
// lib/server/recording_options.hpp:9-15
enum RecordingOption
{
    RECORDING_OPTION_METHOD_DEFAULT,   // Use the method's defaults.
    RECORDING_OPTION_DO_NOT_RECORD,    // Do not record.
    RECORDING_OPTION_RECORD,            // Record.
    RECORDING_OPTION_RECORD_ONLY        // Record-only, do not propagate.
};
```

注意 `callMethod` 通过 `__call__`(`pyCall`)实现,而非 `callMethod` 方法本身。具体见 Client Mailbox 章节。

### 6.9 MailBoxRefRegistry:工厂注册表

`MailBoxRefRegistry` 是一个静态全局结构,存储所有注册的工厂和 reducer:

```cpp
// lib/entitydef/mailbox_base.cpp:83-98
typedef BW::map<
    EntityMailBoxRef::Component,PyEntityMailBox::FactoryFn> Fabricators;
typedef BW::vector< std::pair<
    PyEntityMailBox::CheckFn,PyEntityMailBox::ExtractFn> > Interpreters;
typedef BW::vector< PyTypeObject * >  MailBoxTypes;

static struct MailBoxRefRegistry
{
    Fabricators     fabs_;           // Component → FactoryFn
    Interpreters    inps_;           // CheckFn/ExtractFn 链
    MailBoxTypes    mailBoxTypes_;   // 已注册的 PyTypeObject
} * s_pRefReg = NULL;
```

注册函数:

```cpp
// lib/entitydef/mailbox_base.cpp:269-275
void PyEntityMailBox::registerMailBoxComponentFactory(
    EntityMailBoxRef::Component c, FactoryFn fn, PyTypeObject * pType )
{
    if (s_pRefReg == NULL) s_pRefReg = new MailBoxRefRegistry();
    s_pRefReg->fabs_.insert( std::make_pair( c, fn ) );
    s_pRefReg->mailBoxTypes_.push_back( pType );
}

// lib/entitydef/mailbox_base.cpp:325-329
void PyEntityMailBox::registerMailBoxRefEquivalent( CheckFn cf, ExtractFn ef )
{
    if (s_pRefReg == NULL) s_pRefReg = new MailBoxRefRegistry();
    s_pRefReg->inps_.push_back( std::make_pair( cf, ef ) );
}
```

注册的时机是进程启动,详见"工厂注册机制"章节。

---

## 七、ServerEntityMailBox 中间层

`ServerEntityMailBox` 是 CellApp 和 BaseApp 中所有"服务端 Mailbox"的中间基类,提供 Channel/Bundle 的统一访问接口。它在 CellApp 和 BaseApp 中略有不同实现,但接口一致。

### 7.1 CellApp 版本

```cpp
// server/cellapp/mailbox.hpp:30-67
class ServerEntityMailBox: public PyEntityMailBox
{
    Py_Header( ServerEntityMailBox, PyEntityMailBox )

public:
    ServerEntityMailBox( EntityTypePtr pBaseType,
            const Mercury::Address & addr, EntityID id,
            PyTypeObject * pType = &s_type_ );
    virtual ~ServerEntityMailBox();

    virtual const Mercury::Address  address() const      { return addr_; }
    virtual void address( const Mercury::Address & addr ) { addr_ = addr; }
    virtual void migrate();

    virtual EntityID            id() const           { return id_; }

    PY_RO_ATTRIBUTE_DECLARE( this->componentName(), component );
    PY_RO_ATTRIBUTE_DECLARE( pLocalType_->name(), className );
    PY_RO_ATTRIBUTE_DECLARE( addr_.ip, ip );

    EntityMailBoxRef ref() const;
    virtual EntityMailBoxRef::Component component() const = 0;
    const char * componentName() const;

    static EntityMailBoxRef static_ref( PyObject * pThis )
        { return ((const ServerEntityMailBox*)pThis)->ref(); }

    static void migrateMailBoxes();
    static void adjustForDeadBaseApp( const Mercury::Address & deadAddr,
            const BackupHash & backupHash );

protected:

    Mercury::Address            addr_;
    EntityID                    id_;

    EntityTypePtr    pLocalType_;
};
```

### 7.2 BaseApp 版本

BaseApp 版本略有不同,增加了 `pChannel()` 虚函数和 `getStreamEx`:

```cpp
// server/baseapp/mailbox.hpp:26-79
class ServerEntityMailBox: public PyEntityMailBox
{
    Py_Header( ServerEntityMailBox, PyEntityMailBox )

public:
    ServerEntityMailBox( EntityTypePtr pBaseType,
            const Mercury::Address & addr, EntityID id,
            PyTypeObject * pType = &s_type_ );
    virtual ~ServerEntityMailBox();

    virtual ScriptObject pyGetAttribute( const ScriptString & attrObj );
    void sendStream();

    virtual const Mercury::Address  address() const      { return addr_; }
    virtual void address( const Mercury::Address & addr );

    virtual Mercury::UDPChannel  * pChannel() const;
    Mercury::Bundle & bundle() const { return this->pChannel()->bundle(); }

    virtual EntityID                id() const          { return id_; }

    EntityMailBoxRef ref() const;
    virtual EntityMailBoxRef::Component component() const = 0;
    const char * componentName() const;

    virtual BinaryOStream * getStream( const MethodDescription & methodDesc,
           std::auto_ptr< Mercury::ReplyMessageHandler > pHandler );

    static EntityMailBoxRef static_ref( PyObject * pThis )
        { return ((const ServerEntityMailBox*)pThis)->ref(); }

    static void adjustForDeadBaseApp( const Mercury::Address & deadAddr,
            const BackupHashChain & hash );

    EntityType & localType() const { return *pLocalType_; }

    static void migrateMailBoxes();
    virtual void migrate();

    PY_RO_ATTRIBUTE_DECLARE( this->componentName(), component );
    PY_RO_ATTRIBUTE_DECLARE( pLocalType_->name(), className );
    PY_RO_ATTRIBUTE_DECLARE( addr_.ip, ip );

    static PyObjectPtr coerce( PyObject * pObject );

protected:
    virtual BinaryOStream * getStreamEx( const MethodDescription & methodDesc,
           std::auto_ptr< Mercury::ReplyMessageHandler > pHandler ) = 0;

    Mercury::Address            addr_;
    EntityID                    id_;

    EntityTypePtr               pLocalType_;
};
```

注意:

1. BaseApp 版本的 `getStream` 不是纯虚,而是调用 `getStreamEx`(纯虚),并在 `getStream` 中加入主线程检查
2. BaseApp 版本的 `adjustForDeadBaseApp` 接受 `BackupHashChain`(CellApp 版本接受 `BackupHash`)
3. BaseApp 版本增加了 `coerce` 静态方法,用于把 Base 实体转为 BaseEntityMailBox

### 7.3 主线程检查

BaseApp 版本的 `getStream` 和 `pyGetAttribute` 在调用前检查主线程:

```cpp
// server/baseapp/mailbox.cpp:530-562
ScriptObject ServerEntityMailBox::pyGetAttribute( const ScriptString & attrObj )
{
    if (!MainThreadTracker::isCurrentThreadMain())
    {
        PyErr_Format( PyExc_AttributeError,
                "Mailbox property is not available in background threads" );
        return ScriptObject();
    }

    return this->PyEntityMailBox::pyGetAttribute( attrObj );
}

BinaryOStream * ServerEntityMailBox::getStream(
                    const MethodDescription & methodDesc,
                    std::auto_ptr< Mercury::ReplyMessageHandler > pHandler )
{
    if (!MainThreadTracker::isCurrentThreadMain())
    {
        ERROR_MSG( "ServerEntityMailBox::getStream: "
                "Cannot get stream in background thread for %s mailbox\n",
            this->componentName() );
        PyErr_Format( PyExc_TypeError,
            "Cannot get stream in background thread for %s mailbox\n",
            this->componentName() );
        return NULL;
    }

    return this->getStreamEx( methodDesc, pHandler );
}
```

这是因为 Mailbox 内部访问的 `BaseApp::instance()` 等单例不是线程安全的,加载线程(loading thread)必须避免访问。

### 7.4 sendStream 通用实现

BaseApp 的 `ServerEntityMailBox::sendStream` 是一个通用实现:

```cpp
// server/baseapp/mailbox.cpp:568-594
void ServerEntityMailBox::sendStream()
{
    Mercury::UDPChannel * pChannel = this->pChannel();

    if (!pChannel)
    {
        ERROR_MSG( "ServerEntityMailBox::sendStream: Channel is NULL."
            "Address: %s, id:%d\n", addr_.c_str(), id_ );
        return;
    }

    if (pChannel->addr().ip == 0)
    {
        INFO_MSG( "ServerEntityMailBox::sendStream: %s mailbox channel "
                "not established, buffering message for entity %d\n", 
            this->componentName(),
            id_ );
        return;
    }

    // Using this form of delayedSend() so that we send it soon regardless of
    // whether we have a player making the channel regular. 
    pChannel->networkInterface().delayedSend( *pChannel );
}
```

注意几个细节:

1. `addr_.ip == 0` 时不报错,只记 INFO 日志,因为这种情况意味着 Channel 尚未建立(如对方进程未响应),消息会自动缓冲在 Bundle 中
2. 使用 `delayedSend` 而非 `send`:这保证消息尽快发送,而不会被 Channel 的 regular/irregular 状态影响
3. Channel 为 NULL 时记 ERROR,因为这种情况通常意味着配置错误

### 7.5 pChannel 实现

```cpp
// server/baseapp/mailbox.cpp:602-610
Mercury::UDPChannel * ServerEntityMailBox::pChannel() const
{
    if (addr_.ip == 0)
    {
        return NULL;
    }

    return &BaseApp::getChannel( addr_ );
}
```

`BaseApp::getChannel(addr)` 是一个静态方法,返回该地址对应的 UDPChannel(从 ChannelMap 中查找或创建)。

### 7.6 ref() 实现

`ref()` 把 Mailbox 转换为 `EntityMailBoxRef`:

```cpp
// server/baseapp/mailbox.cpp:616-621
EntityMailBoxRef ServerEntityMailBox::ref() const
{
    EntityMailBoxRef mbr; mbr.init(
        id_, addr_, this->component(), pLocalType_->description().index() );
    return mbr;
}
```

这里调用了 `EntityMailBoxRef::init(id, addr, component, type)`,把 Component 和 EntityTypeID 编码到 `addr.salt` 中。

### 7.7 coerce 静态方法

`coerce` 是 BaseApp 独有的工具方法,用于把 Python 对象"规范化"为 Mailbox(如果它是 Base 实体):

```cpp
// server/baseapp/mailbox.cpp:679-692
PyObjectPtr ServerEntityMailBox::coerce( PyObject * pObject )
{
    if (Base::Check( pObject ))
    {
        Base * pBase = static_cast< Base * >( pObject );
        return PyObjectPtr(
                new BaseEntityMailBox( pBase->pType(),
                    BaseApp::instance().intInterface().address(),
                    pBase->id() ),
                PyObjectPtr::STEAL_REFERENCE );
    }

    return pObject;
}
```

这用于:在脚本调用某个接受 Mailbox 参数的方法时,如果传入了本地 Base 实体,自动转为 BaseEntityMailBox,使后续逻辑无需区分"本地实体"与"远程 Mailbox"。

### 7.8 componentName 实现

```cpp
// server/cellapp/mailbox.cpp:597-611
const char * ServerEntityMailBox::componentName() const
{
    switch (this->component())
    {
        case EntityMailBoxRef::CELL:            return "cell";
        case EntityMailBoxRef::BASE:            return "base";
        case EntityMailBoxRef::SERVICE:         return "service";
        case EntityMailBoxRef::CLIENT:          return "client";
        case EntityMailBoxRef::BASE_VIA_CELL:       return "base_via_cell";
        case EntityMailBoxRef::CLIENT_VIA_CELL:     return "client_via_cell";
        case EntityMailBoxRef::CELL_VIA_BASE:      return "cell_via_base";
        case EntityMailBoxRef::CLIENT_VIA_BASE:    return "client_via_base";
        default:                                return "<invalid>";
    }
}
```

注意:CellApp 版本的 `componentName` 在本地实现,而 BaseApp 版本直接调用 `EntityMailBoxRef::componentAsStr`(因为字符串完全相同)。

### 7.9 migrate 实现

`migrate` 在实体类型重载(热更新)时被调用,更新 Mailbox 持有的 EntityType 指针:

```cpp
// server/baseapp/mailbox.cpp:638-647
void ServerEntityMailBox::migrate()
{
    pLocalType_ = EntityType::getType( pLocalType_->name() );

    if (!pLocalType_)
    {
        id_ = 0;    // invalid mailbox ... but prevent crash:
        pLocalType_ = EntityType::getType( EntityTypeID( 0 ) );
    }
}
```

注意:
- 通过名字查找新类型,而不是 ID(因为重载后 ID 可能变化)
- 如果新类型不存在(类型被删除),把 id 置 0 使 Mailbox 失效
- 但仍设置一个默认类型防止 crash

`migrateMailBoxes` 静态方法通过 Visitor 模式遍历所有 Mailbox 并调用 migrate:

```cpp
// server/baseapp/mailbox.cpp:653-657
void ServerEntityMailBox::migrateMailBoxes()
{
    MigrateMailBoxVisitor visitor;
    PyEntityMailBox::visit( visitor );
}
```

---

## 八、CellEntityMailBox 深度剖析

`CellEntityMailBox` 是指向 CellApp 上 Cell 实体的 Mailbox。它在 CellApp 和 BaseApp 中有不同实现,因为它们与 CellApp 的连接方式不同。

### 8.1 CellApp 中的 CellEntityMailBox

```cpp
// server/cellapp/mailbox.hpp:75-100
class CellEntityMailBox: public ServerEntityMailBox
{
    Py_Header( CellEntityMailBox, ServerEntityMailBox )

public:
    CellEntityMailBox( EntityTypePtr pBaseType,
            const Mercury::Address & addr, EntityID id,
            PyTypeObject * pType = &s_type_ ) :
        ServerEntityMailBox( pBaseType, addr, id, pType )
    {}

    // Mailbox getter methods and generated setters.
    PyObject * pyGet_base();
    PY_RO_ATTRIBUTE_SET( base )

    PyObject * pyGet_client();
    PY_RO_ATTRIBUTE_SET( client )

    virtual BinaryOStream * getStream( const MethodDescription & methodDesc, 
        std::auto_ptr< Mercury::ReplyMessageHandler > pHandler );
    void sendStream();
    virtual const MethodDescription * findMethod( const char * attr ) const;
    virtual EntityMailBoxRef::Component component() const;
protected:
    Mercury::UDPChannel * pChannel() const;
};
```

#### 8.1.1 pChannel 实现

CellApp 之间通过 `CellAppChannel` 进行通信,这是一种优化的 Channel:

```cpp
// server/cellapp/mailbox.cpp:760-768
Mercury::UDPChannel * CellEntityMailBox::pChannel() const
{
    CellAppChannel * pCellAppChannel = CellAppChannels::instance().get( addr_ );
    if (pCellAppChannel != NULL)
    {
        return &pCellAppChannel->channel();
    }
    return NULL;
}
```

`CellAppChannels` 是一个全局单例,管理当前 CellApp 与其他 CellApp 的所有 Channel。`CellAppChannel` 是 `Mercury::ChannelOwner` 的派生类,封装了一个 `Mercury::UDPChannel`。

#### 8.1.2 getStream 实现

```cpp
// server/cellapp/mailbox.cpp:797-825
BinaryOStream * CellEntityMailBox::getStream(
        const MethodDescription & methodDesc, 
        std::auto_ptr< Mercury::ReplyMessageHandler > pHandler )
{
    Mercury::Channel * pChannel = this->pChannel();
    if (!pChannel)
    {
        return NULL;
    }

    // Get the bundle to the real's app.
    Mercury::Bundle & bundle = pChannel->bundle();

    // Not supporting return values
    if (pHandler.get())
    {
        PyErr_Format( PyExc_TypeError,
                "Cannot call two-way method '%s' from CellApp",
                methodDesc.name().c_str() );
        return NULL;
    }

    // Start the message
    bundle.startMessage( CellAppInterface::runScriptMethod );
    bundle << id_;
    bundle << methodDesc.internalIndex();

    return &bundle;
}
```

消息格式:
- 消息类型:`CellAppInterface::runScriptMethod`
- 参数 1:目标 EntityID(4 字节)
- 参数 2:方法内部索引 MethodIndex(2 字节,通常)
- 后续:方法参数(由 `addToServerStream` 写入)

#### 8.1.3 sendStream 实现

```cpp
// server/cellapp/mailbox.cpp:774-791
void CellEntityMailBox::sendStream()
{
    Mercury::UDPChannel * pChannel = this->pChannel();

    if (pChannel)
    {
        if (pChannel->addr().ip != 0)
        {
            Mercury::ChannelSender sender( *this->pChannel() );
        }
        else
        {
            INFO_MSG( "CellEntityMailBox::sendStream: cell mailbox channel"
                    " not established, buffering message for entity %d\n",
                id_ );
        }
    }
}
```

注意:这里使用 `ChannelSender` 局部对象,它的析构函数会触发 Bundle 的发送。这是 RAII 模式的应用:

```cpp
{
    Mercury::ChannelSender sender( *this->pChannel() );
    // ... bundle 数据已经在 getStream 时写入
}  // sender 析构,触发发送
```

#### 8.1.4 pyGet_base 与 pyGet_client

Cell Mailbox 可以派生出 Base Via Cell 和 Client Via Cell:

```cpp
// server/cellapp/mailbox.cpp:727-753
PyObject * CellEntityMailBox::pyGet_base()
{
    if (!pLocalType_->canBeOnBase())
    {
        PyErr_Format( PyExc_AttributeError,
            "Base has no defined script methods." );
        return NULL;
    }

    return new BaseViaCellMailBox( pLocalType_, addr_, id_ );
}

PyObject * CellEntityMailBox::pyGet_client()
{
    if (!pLocalType_->description().canBeOnClient())
    {
        PyErr_Format( PyExc_AttributeError,
            "Client has no defined script methods." );
        return NULL;
    }

    return new ClientViaCellMailBox( pLocalType_, addr_, id_ );
}
```

注意 `pyGet_base` 返回 `BaseViaCellMailBox`(不是直接 `BaseEntityMailBox`),因为 CellApp 不知道 Base 的真实地址,只能通过 Cell 转发。

#### 8.1.5 findMethod 实现

```cpp
// server/cellapp/mailbox.cpp:832-836
const MethodDescription * CellEntityMailBox::findMethod(
    const char * attr ) const
{
    return pLocalType_->description().cell().find( attr );
}
```

`description().cell()` 返回 `EntityMethods` 对象,包含所有 CellMethods。`find` 按方法名查找 `MethodDescription`。

### 8.2 BaseApp 中的 CellEntityMailBox

BaseApp 中的 `CellEntityMailBox` 实现略有不同,因为它需要通过本 BaseApp 上的 Base 来访问其 Cell:

```cpp
// server/baseapp/mailbox.hpp:110-133
class CellEntityMailBox: public CommonCellEntityMailBox
{
    Py_Header( CellEntityMailBox, CommonCellEntityMailBox )

public:
    CellEntityMailBox( EntityTypePtr pBaseType,
            const Mercury::Address & addr, EntityID id,
            PyTypeObject * pType = &s_type_ ) :
        CommonCellEntityMailBox( pBaseType, addr, id, pType )
    {}

    PyObject * pyGet_base();
    PY_RO_ATTRIBUTE_SET( base )

    PyObject * pyGet_client();
    PY_RO_ATTRIBUTE_SET( client )

    virtual BinaryOStream * getStreamEx( const MethodDescription & methodDesc, 
            std::auto_ptr< Mercury::ReplyMessageHandler > pHandler );

    virtual const MethodDescription * findMethod( const char * attr ) const;
    virtual EntityMailBoxRef::Component component() const;
};
```

注意它继承自 `CommonCellEntityMailBox`,而非直接 `ServerEntityMailBox`。`CommonCellEntityMailBox` 是 BaseApp 中所有"通过 Cell 转发的 Mailbox"的公共基类。

#### 8.2.1 CommonCellEntityMailBox 的 pChannel

```cpp
// server/baseapp/mailbox.cpp:712-743
Mercury::UDPChannel * CommonCellEntityMailBox::pChannel() const
{
    Base * pBase = BaseApp::instance().bases().findEntity( id_ );

    if (!pBase)
    {
        Mercury::UDPChannel * pChannel = this->ServerEntityMailBox::pChannel();

        if (!pChannel)
        {
            PyErr_SetString( PyExc_ValueError, "Invalid mailbox" );
            return NULL;
        }

        return pChannel;
    }

    // Disallow the call if we don't have a cell entity and we're not pending cell
    // creation, or if we're pending cell destruction.

    if ((!pBase->hasCellEntity() && 
            !pBase->isGetCellPending()) ||
        (pBase->isDestroyCellPending()))
    {
        PyErr_SetString( PyExc_ValueError, 
            "Base entity has no cell entity "
            "or cell entity is pending for destroy" );
        return NULL;
    }

    return &pBase->channel();
}
```

这里有一个重要的优化:**如果本 BaseApp 上有该 Base 实体,使用 Base 自己的 Channel,而不是按地址查找**。这样:

1. 避免了重复 Channel 创建
2. Channel 自动随 Base 状态迁移
3. 可以利用 Base 的 `hasCellEntity`/`isGetCellPending` 状态进行额外校验

#### 8.2.2 getStreamEx 实现

```cpp
// server/baseapp/mailbox.cpp:896-902
BinaryOStream * CellEntityMailBox::getStreamEx(
    const MethodDescription & methodDesc,
    std::auto_ptr< Mercury::ReplyMessageHandler > pHandler )
{
    return this->getStreamCommon( methodDesc,
        CellAppInterface::runScriptMethod, pHandler );
}
```

`getStreamCommon` 是 `CommonCellEntityMailBox` 的辅助方法:

```cpp
// server/baseapp/mailbox.cpp:750-777
BinaryOStream * CommonCellEntityMailBox::getStreamCommon(
        const MethodDescription & methodDesc, 
        const Mercury::InterfaceElement & ie,
        std::auto_ptr< Mercury::ReplyMessageHandler > pHandler )
{
    Mercury::UDPChannel * pChannel = this->pChannel();

    if (!pChannel)
    {
        return NULL;
    }

    Mercury::Bundle & bundle = pChannel->bundle();

    if (pHandler.get())
    {
        bundle.startRequest( ie, pHandler.release() );
    }
    else
    {
        bundle.startMessage( ie );
    }

    bundle << id_;
    bundle << methodDesc.internalIndex();

    return &bundle;
}
```

注意 BaseApp 版本支持 `startRequest`(two-way),而 CellApp 版本不支持。这是因为 BaseApp 的调用可以阻塞等待回复(虽然不推荐,但技术上支持),而 CellApp 永远不允许阻塞。

### 8.3 CellEntityMailBox 的限制

CellEntityMailBox 有几个重要的使用限制:

1. **不能持久化**:Cell Mailbox 的目标(Cell 实体)生命周期较短,且地址变化频繁(CellApp 重启、Cell 迁移等),持久化意义不大
2. **不可跨 BaseApp 持久化存储到 DB**:MailBoxDataType 会拒绝 ip=0 的 Mailbox,而 ip 不为 0 时也只能存 BASE 类型
3. **不能调用 two-way 方法(从 CellApp)**:CellApp 是单线程驱动,不能阻塞等待回复
4. **使用前应检查有效性**:特别是在 BaseApp 中,如果 Base 没有 Cell 实体,调用会失败

---

## 九、BaseEntityMailBox 深度剖析

`BaseEntityMailBox` 是指向 BaseApp 上 Base 实体的 Mailbox。它在 CellApp 和 BaseApp 中也有不同实现。

### 9.1 CellApp 中的 BaseEntityMailBox

```cpp
// server/cellapp/mailbox.hpp:135-157
class BaseEntityMailBox: public CommonBaseEntityMailBox
{
    Py_Header( BaseEntityMailBox, CommonBaseEntityMailBox )

public:
    BaseEntityMailBox( EntityTypePtr pBaseType,
            const Mercury::Address & addr, EntityID id,
            PyTypeObject * pType = &s_type_ ) :
        CommonBaseEntityMailBox( pBaseType, addr, id, pType )
    {}

    // Mailbox getter methods and generated setters.
    PyObject * pyGet_cell();
    PY_RO_ATTRIBUTE_SET( cell )

    PyObject * pyGet_client();
    PY_RO_ATTRIBUTE_SET( client )

    virtual BinaryOStream * getStream( const MethodDescription & methodDesc,
            std::auto_ptr< Mercury::ReplyMessageHandler > pHandler );
    virtual const MethodDescription * findMethod( const char * attr ) const;
    virtual EntityMailBoxRef::Component component() const;
};
```

注意它继承自 `CommonBaseEntityMailBox`,而非直接 `ServerEntityMailBox`。`CommonBaseEntityMailBox` 是 CellApp 中所有"通过 Base 转发或调用 Base 的 Mailbox"的公共基类。

#### 9.1.1 CommonBaseEntityMailBox 的 channel 与 bundle

```cpp
// server/cellapp/mailbox.cpp:866-925
Mercury::UDPChannel & CommonBaseEntityMailBox::channel() const
{
    Entity * pEntity = CellApp::instance().findEntity( id_ );
    return this->channel( pEntity );
}

Mercury::UDPChannel & CommonBaseEntityMailBox::channel( Entity * pEntity ) const
{
    return (pEntity && pEntity->isReal()) ?
        pEntity->pReal()->channel() : CellApp::getChannel( addr_ );
}

Mercury::Bundle & CommonBaseEntityMailBox::bundle() const
{
    Entity * pEntity = CellApp::instance().findEntity( id_ );
    Mercury::Bundle & bundle = this->channel( pEntity ).bundle();

    if (!pEntity || !pEntity->isReal())
    {
        BaseAppIntInterface::setClientArgs::start( bundle ).id = id_;
    }

    return bundle;
}
```

注意几个细节:

1. **优先使用 entity channel**:如果本 CellApp 上有该实体的 Real,使用 Real 自己的 Channel(可能是已建立的、与对方 BaseApp 直连的)
2. **否则使用 CellApp 级 Channel**:`CellApp::getChannel(addr_)` 创建/获取到对方 BaseApp 的 Channel
3. **setClientArgs 前缀**:如果实体不在本地(ghost 或者不在),需要在 Bundle 前加 `setClientArgs` 消息,告知对方 BaseApp 当前消息的目标实体 ID

#### 9.1.2 sendStream 实现

```cpp
// server/cellapp/mailbox.cpp:889-905
void CommonBaseEntityMailBox::sendStream()
{
    Mercury::UDPChannel & channel = this->channel();

    if (channel.addr().ip == 0)
    {
        NOTICE_MSG( "CommonBaseEntityMailBox::sendStream: %s mailbox channel"
                " not established, buffering message for entity %d\n",
            this->componentName(),
            id_ );
        return;
    }

    // Using this form of delayedSend() so that we send it soon regardless of
    // whether we have a player making the channel regular. 
    channel.networkInterface().delayedSend( channel );
}
```

#### 9.1.3 getStream 实现

```cpp
// server/cellapp/mailbox.cpp:1033-1052
BinaryOStream * BaseEntityMailBox::getStream(
        const MethodDescription & methodDesc,
        std::auto_ptr< Mercury::ReplyMessageHandler > pHandler )
{
    Mercury::Bundle & bundle = this->bundle();

    // Not supporting return values
    if (pHandler.get())
    {
        PyErr_Format( PyExc_TypeError,
                "Cannot call two-way method '%s' from CellApp",
                methodDesc.name().c_str() );
        return NULL;
    }

    bundle.startMessage( BaseAppIntInterface::callBaseMethod );
    bundle << methodDesc.internalIndex();

    return &bundle;
}
```

注意:与 CellEntityMailBox 不同,这里不写 `id_`,因为 `bundle()` 已经在前面写了 `setClientArgs`(如果不在本地)。

#### 9.1.4 component 实现

```cpp
// server/cellapp/mailbox.cpp:1069-1073
EntityMailBoxRef::Component BaseEntityMailBox::component() const
{
    return pLocalType_->description().isService() ? EntityMailBoxRef::SERVICE :
        EntityMailBoxRef::BASE;
}
```

如果是 Service 类型,返回 SERVICE;否则返回 BASE。

#### 9.1.5 pyGet_cell 与 pyGet_client

```cpp
// server/cellapp/mailbox.cpp:1000-1027
PyObject * BaseEntityMailBox::pyGet_cell()
{
    if (!pLocalType_->canBeOnCell())
    {
        PyErr_Format( PyExc_AttributeError,
            "Cell has no defined script methods." );
        return NULL;
    }

    return new CellViaBaseMailBox( pLocalType_, addr_, id_ );
}

PyObject * BaseEntityMailBox::pyGet_client()
{

    if (!pLocalType_->description().canBeOnClient())
    {
        PyErr_Format( PyExc_AttributeError,
            "Client has no defined script methods." );
        return NULL;
    }

    return new ClientViaBaseMailBox( pLocalType_, addr_, id_ );
}
```

注意 `pyGet_cell` 返回 `CellViaBaseMailBox`(通过 Base 转发到 Cell),`pyGet_client` 返回 `ClientViaBaseMailBox`。

### 9.2 BaseApp 中的 BaseEntityMailBox

BaseApp 中的 `BaseEntityMailBox` 用于调用其他 BaseApp 上的 Base:

```cpp
// server/baseapp/mailbox.hpp:142-169
class BaseEntityMailBox: public ServerEntityMailBox
{
    Py_Header( BaseEntityMailBox, ServerEntityMailBox )

public:
    BaseEntityMailBox( EntityTypePtr pBaseType,
            const Mercury::Address & addr, EntityID id,
            PyTypeObject * pType = &s_type_ ) :
        ServerEntityMailBox( pBaseType, addr, id, pType )
    {}

    PyObject * pyGet_cell();
    PY_RO_ATTRIBUTE_SET( cell )

    PyObject * pyGet_client();
    PY_RO_ATTRIBUTE_SET( client )

    virtual BinaryOStream * getStreamEx( const MethodDescription & methodDesc, 
            std::auto_ptr< Mercury::ReplyMessageHandler > pHandler );
    virtual const MethodDescription * findMethod( const char * attr ) const;
    virtual EntityMailBoxRef::Component component() const;
};
```

#### 9.2.1 getStreamEx 实现

```cpp
// server/baseapp/mailbox.cpp:1054-1075
BinaryOStream * BaseEntityMailBox::getStreamEx(
        const MethodDescription & methodDesc,
        std::auto_ptr< Mercury::ReplyMessageHandler > pHandler )
{
    Mercury::Bundle & bundle = this->bundle();

    BaseAppIntInterface::setClientArgs::start( bundle ).id = id_;

    if (pHandler.get())
    {
        bundle.startRequest( BaseAppIntInterface::callBaseMethod,
                pHandler.release() );
    }
    else
    {
        bundle.startMessage( BaseAppIntInterface::callBaseMethod );
    }

    bundle << methodDesc.internalIndex();

    return &bundle;
}
```

注意:BaseApp 版本支持 `startRequest`(two-way),并且总是写入 `setClientArgs`(因为目标在其他 BaseApp)。

#### 9.2.2 pyGet_client 校验 Proxy

```cpp
// server/baseapp/mailbox.cpp:1037-1048
PyObject * BaseEntityMailBox::pyGet_client()
{

    if (!pLocalType_->isProxy())
    {
        PyErr_Format( PyExc_AttributeError,
            "Client mailbox does not refer to a proxy." );
        return NULL;
    }

    return new ClientViaBaseMailBox( pLocalType_, addr_, id_ );
}
```

注意:BaseApp 版本的 `pyGet_client` 校验 `isProxy()`(必须是 Proxy 类型),而 CellApp 版本只校验 `canBeOnClient()`。这是因为只有 Proxy 类型才有 client,普通 Base 不能有 client。

### 9.3 BaseEntityMailBox 的特殊性

BaseEntityMailBox 是最重要的 Mailbox 类型之一,因为:

1. **可持久化**:可以保存到 DB,通过 EntityMailBoxRef 12 字节
2. **支持故障重定向**:通过 BackupHashChain 重新定位到新 BaseApp
3. **支持 two-way**:可以从 BaseApp 调用并接收返回值
4. **支持 Service**:通过 `isService()` 判断并返回 SERVICE Component
5. **是 Base 实体的默认 Mailbox**:在 Python 中 `entity` 自动转换为 `entity.base`

---

## 十、ClientEntityMailBox 深度剖析

`ClientEntityMailBox` 是 BaseApp 中专门用于向客户端发送消息的 Mailbox。它与其他 ServerEntityMailBox 不同,直接通过 Proxy 的 client bundle 发送。

### 10.1 类定义

```cpp
// server/baseapp/client_entity_mailbox.hpp:17-48
class ClientEntityMailBox: public PyEntityMailBox
{
    Py_Header( ClientEntityMailBox, PyEntityMailBox )

public:
    ClientEntityMailBox( Proxy & proxy );

    virtual EntityID id() const;

    virtual void address( const Mercury::Address & address ) {}
    virtual const Mercury::Address address() const;

    virtual ScriptObject pyGetAttribute( const ScriptString & attrObj );
    virtual BinaryOStream * getStream( const MethodDescription & methodDesc, 
        std::auto_ptr< Mercury::ReplyMessageHandler > pHandler );
    virtual void sendStream();
    virtual const MethodDescription * findMethod( const char * attr ) const;

    const EntityDescription& getEntityDescription() const;

    EntityMailBoxRef ref() const;

    Proxy & proxy() { return proxy_; }

    PY_KEYWORD_METHOD_DECLARE( pyCall );

    static EntityMailBoxRef static_ref( PyObject * pThis )
        { return ((const ClientEntityMailBox*)pThis)->ref(); }

private:
    Proxy & proxy_;
};
```

### 10.2 关键特征

1. **不继承自 ServerEntityMailBox**:直接继承 PyEntityMailBox,因为它不需要 Channel 概念(用 Proxy 的 client bundle)
2. **持有 Proxy 引用**:`proxy_` 是 Proxy 的引用,而不是指针(强引用,生命周期与 Proxy 绑定)
3. **address 是空操作**:因为地址由 Proxy 决定,Mailbox 不存储地址
4. **支持 __call__**:`pyCall` 用于设置 RecordingOption

### 10.3 构造函数

```cpp
// server/baseapp/client_entity_mailbox.cpp:36-39
ClientEntityMailBox::ClientEntityMailBox( Proxy & proxy ) :
        PyEntityMailBox( &ClientEntityMailBox::s_type_ ),
        proxy_( proxy )
{}
```

构造时只需要 Proxy 引用,不需要单独的 addr 和 id(从 Proxy 获取)。

### 10.4 id 和 address

```cpp
// server/baseapp/client_entity_mailbox.cpp:45-57
EntityID ClientEntityMailBox::id() const
{ 
    return proxy_.id(); 
}

const Mercury::Address ClientEntityMailBox::address() const
{
    return proxy_.clientAddr();
}
```

直接从 Proxy 获取,Mailbox 本身不存储。

### 10.5 pyGetAttribute

```cpp
// server/baseapp/client_entity_mailbox.cpp:65-78
ScriptObject ClientEntityMailBox::pyGetAttribute( const ScriptString & attrObj )
{
    const MethodDescription * pDescription = 
        this->findMethod( attrObj.c_str() );
    if (pDescription != NULL)
    {
        return ScriptObject( new RemoteClientMethod( this, 
            this->getEntityDescription().name(),
            pDescription,
            proxy_.channel() ), ScriptObject::FROM_NEW_REFERENCE );
    }

    return PyObjectPlus::pyGetAttribute( attrObj );
}
```

注意:返回的是 `RemoteClientMethod`(不是 `RemoteEntityMethod`),因为客户端方法有一些特殊处理(如 selectPlayerEntity 前缀、暴露给客户端的 msgID 等)。

### 10.6 getStream

```cpp
// server/baseapp/client_entity_mailbox.cpp:84-112
BinaryOStream * ClientEntityMailBox::getStream( 
        const MethodDescription & methodDesc,
        std::auto_ptr< Mercury::ReplyMessageHandler > pHandler )
{
    // Not supporting return values

    if (pHandler.get())
    {
        PyErr_Format( PyExc_TypeError,
                "Cannot call two-way method '%s' to Client",
                methodDesc.name().c_str() );
        return NULL;
    }

    if (!proxy_.hasClient())
    {
        PyErr_Format( PyExc_TypeError,
                "Error calling %s no client is available.",
                methodDesc.name().c_str() );
        return NULL;
    }

    Mercury::Bundle & bundle = proxy_.clientBundle();

    bundle.startMessage( ClientInterface::selectPlayerEntity );

    return proxy_.getStreamForEntityMessage(
                    methodDesc.exposedMsgID(), methodDesc.streamSize( true ) );
}
```

注意几个细节:

1. **不支持 two-way**:客户端不能给服务器返回值(协议设计如此)
2. **必须 hasClient**:如果客户端断开,调用失败
3. **selectPlayerEntity 前缀**:每个客户端消息前必须加 selectPlayerEntity,告知客户端这是哪个实体的消息
4. **使用 exposedMsgID**:客户端方法用 exposedMsgID(暴露给客户端的 ID),而不是 internalIndex

### 10.7 sendStream

```cpp
// server/baseapp/client_entity_mailbox.cpp:118-122
void ClientEntityMailBox::sendStream()
{
    // we don't actually send the stream here; we wait for the 'sendToClient'
    // message from the cell to send it off.
}
```

**特别注意**:`sendStream` 是空的!这是 ClientEntityMailBox 的独特设计:

- Bundle 数据写入后,不立即发送
- 等待 CellApp 发来 `sendToClient` 消息后才发送
- 这是为了与 CellApp 的客户端消息调度同步(避免 CellApp 还在准备数据,BaseApp 就先发了)

### 10.8 ref

```cpp
// server/baseapp/client_entity_mailbox.cpp:139-145
EntityMailBoxRef ClientEntityMailBox::ref() const
{
    EntityMailBoxRef mbr; mbr.init(
        proxy_.id(), proxy_.clientAddr(),
        EntityMailBoxRef::CLIENT, proxy_.pType()->description().index() );
    return mbr;
}
```

### 10.9 pyCall 与 RecordingOption

```cpp
// server/baseapp/client_entity_mailbox.cpp:160-178
PyObject * ClientEntityMailBox::pyCall( PyObject * args, PyObject * kwargs )
{
    RecordingOption recordingOption = RECORDING_OPTION_METHOD_DEFAULT;

    if (!this->parseRecordingOptionFromPythonCall( args, kwargs,
            recordingOption ))
    {
        return NULL;
    }

    if (recordingOption == RECORDING_OPTION_METHOD_DEFAULT)
    {
        this->incRef();
        return this;
    }

    return reinterpret_cast< PyObject * >( 
            new ClientEntityMailBoxWrapper( *this, recordingOption ) );
}
```

注意:如果 recordingOption 是默认值,直接返回 this(避免创建包装器);否则创建 `ClientEntityMailBoxWrapper`(包装一层,携带 recording option)。

### 10.10 ClientEntityMailBox 的限制

1. **只能调用 ownClient**:不能调用其他玩家的客户端
2. **不能 two-way**:协议设计上不支持
3. **必须通过 Proxy**:不存在没有 Proxy 的 Client Mailbox
4. **不能持久化**:Proxy 断开后 Mailbox 失效

---

## 十一、_VIA_ 转发机制深度剖析

_VIA_ 是 BigWorld Mailbox 系统的特色设计,允许通过中间进程转发消息,绕过网络拓扑限制。

### 11.1 为什么需要 _VIA_

考虑以下场景:在 CellApp A 中,实体 X(在 CellApp A)想调用实体 Y(在 CellApp B)的 Base(在 BaseApp B)。X 持有 Y 的 Cell Mailbox(因为它们在同一个 AOI 中)。

**不使用 _VIA_**:
- X 需要先查询 Y 的 Base 在哪个 BaseApp(通过 BaseAppMgr 查询,可能跨进程)
- 然后建立到 BaseApp B 的 Channel
- 发送调用

**使用 _VIA_(CellViaBase 不适用,这里用 BaseViaCell)**:
- X 通过 Y 的 Cell Mailbox 调用 `bCellMB.base.method()`
- 这会创建 `BaseViaCellMailBox`,发送 `callBaseMethod` 给 CellApp B
- CellApp B 上的 Y 实体收到 `callBaseMethod`,转发给 Y 的 Base
- Y 的 Base 收到调用并执行

**优势**:
- X 不需要知道 Y 的 Base 在哪里
- 复用已有的 CellApp 之间的 Channel
- 减少跨进程查询

**劣势**:
- 多一跳转发,延迟稍高
- 不能 two-way(因为 CellApp 不能阻塞)
- 不能持久化

### 11.2 4 种 _VIA_ Mailbox

BigWorld 有 4 种 _VIA_ Mailbox:

| 名称 | 从哪发出 | 转发路径 | 用途 |
|------|---------|---------|------|
| `BaseViaCellMailBox` | CellApp | Cell → Base | 在 CellApp 中通过 Cell Mailbox 调用其 Base |
| `ClientViaCellMailBox` | CellApp | Cell → Base → Client | 在 CellApp 中通过 Cell Mailbox 调用其 Client |
| `CellViaBaseMailBox` | CellApp | Base → Cell | 在 CellApp 中通过 Base Mailbox 调用其 Cell |
| `ClientViaBaseMailBox` | CellApp | Base → Client | 在 CellApp 中通过 Base Mailbox 调用其 Client |

注意:这 4 种 _VIA_ 在 CellApp 中有完整实现,在 BaseApp 中也有实现(BaseApp 也可能通过 Base 转发到 Cell)。

### 11.3 BaseViaCellMailBox 深度剖析

`BaseViaCellMailBox` 通过 Cell 转发到 Base。CellApp 实现:

```cpp
// server/cellapp/mailbox.cpp:135-241
class BaseViaCellMailBox : public CellEntityMailBox
{
    Py_Header( BaseViaCellMailBox, CellEntityMailBox )

    public:
        BaseViaCellMailBox( EntityTypePtr pBaseType,
                    const Mercury::Address & addr, EntityID id,
                    PyTypeObject * pType = &s_type_ ):
            CellEntityMailBox( pBaseType, addr, id, pType )
        {}

        ~BaseViaCellMailBox() { }

        virtual ScriptObject pyGetAttribute( const ScriptString & attrObj );
        virtual BinaryOStream * getStream( const MethodDescription & methodDesc, 
            std::auto_ptr< Mercury::ReplyMessageHandler > pHandler );
        virtual EntityMailBoxRef::Component component() const;
        virtual const MethodDescription * findMethod( const char * attr ) const;
};
```

#### 11.3.1 关键点:继承自 CellEntityMailBox

`BaseViaCellMailBox` 继承自 `CellEntityMailBox`(而不是 `BaseEntityMailBox`),这意味着:

- Channel 与 CellEntityMailBox 相同(都是到 CellApp)
- 但 `findMethod` 返回 Base 的方法描述
- `getStream` 写入 `callBaseMethod` 消息(而不是 `runScriptMethod`)

#### 11.3.2 getStream 实现

```cpp
// server/cellapp/mailbox.cpp:195-223
BinaryOStream * BaseViaCellMailBox::getStream(
        const MethodDescription & methodDesc,
        std::auto_ptr< Mercury::ReplyMessageHandler > pHandler )
{
    Mercury::Channel * pChannel = this->pChannel();
    if (!pChannel)
    {
        PyErr_Format( PyExc_TypeError,
                "Cannot get channel for %s",
                methodDesc.name().c_str() );
        return NULL;
    }
    Mercury::Bundle & bundle = pChannel->bundle();

    // Not supporting return values
    if (pHandler.get())
    {
        PyErr_Format( PyExc_TypeError,
                "Cannot call two-way method '%s' from CellApp",
                methodDesc.name().c_str() );
        return NULL;
    }

    bundle.startMessage( CellAppInterface::callBaseMethod );
    bundle << id_;
    bundle << methodDesc.internalIndex();

    return &bundle;
}
```

消息格式:
- 消息类型:`CellAppInterface::callBaseMethod`(发到 CellApp)
- 参数 1:目标 EntityID(告诉 CellApp 哪个实体转发)
- 参数 2:方法索引
- 后续:方法参数

注意与 `CellEntityMailBox::getStream` 的对比:
- CellEntityMailBox 用 `runScriptMethod`,直接执行 Cell 方法
- BaseViaCellMailBox 用 `callBaseMethod`,Cell 收到后转发给 Base

#### 11.3.3 findMethod 实现

```cpp
// server/cellapp/mailbox.cpp:237-241
const MethodDescription * BaseViaCellMailBox::findMethod(
    const char * attr ) const
{
    return pLocalType_->description().base().find( attr );
}
```

返回 Base 的方法描述,虽然通过 Cell Mailbox Channel 发送。

#### 11.3.4 component 实现

```cpp
// server/cellapp/mailbox.cpp:228-231
EntityMailBoxRef::Component BaseViaCellMailBox::component() const
{
    return EntityMailBoxRef::BASE_VIA_CELL;
}
```

#### 11.3.5 pyGetAttribute 的特殊处理

```cpp
// server/cellapp/mailbox.cpp:182-193
ScriptObject BaseViaCellMailBox::pyGetAttribute( const ScriptString & attrObj )
{
    const char * attr = attrObj.c_str();

    if (!strcmp( attr, "cell" ) && pLocalType_->canBeOnCell())
    {
        return ScriptObject( new CellEntityMailBox( pLocalType_, addr_, id_ ),
            ScriptObject::FROM_NEW_REFERENCE );
    }

    return this->CellEntityMailBox::pyGetAttribute( attrObj );
}
```

注意:访问 `.cell` 属性时,返回的是 `CellEntityMailBox`(直接到 Cell),而不是 `CellViaBaseMailBox`。这是因为已经在 Cell Mailbox 上下文中,直接用即可。

### 11.4 CellViaBaseMailBox 深度剖析

`CellViaBaseMailBox` 通过 Base 转发到 Cell。CellApp 实现:

```cpp
// server/cellapp/mailbox.cpp:42-123
class CellViaBaseMailBox : public CommonBaseEntityMailBox
{
    Py_Header( CellViaBaseMailBox, CommonBaseEntityMailBox )

    public:
        CellViaBaseMailBox( EntityTypePtr pBaseType,
                    const Mercury::Address & addr, EntityID id,
                    PyTypeObject * pType = &s_type_ ):
            CommonBaseEntityMailBox( pBaseType, addr, id, pType )
        {}

        ~CellViaBaseMailBox() { }

        virtual ScriptObject pyGetAttribute( const ScriptString & attrObj );
        virtual BinaryOStream * getStream( const MethodDescription & methodDesc,
            std::auto_ptr< Mercury::ReplyMessageHandler > pHandler );
        virtual EntityMailBoxRef::Component component() const;
        virtual const MethodDescription * findMethod( const char * attr ) const;
};
```

#### 11.4.1 继承自 CommonBaseEntityMailBox

`CellViaBaseMailBox` 继承自 `CommonBaseEntityMailBox`,这意味着:

- Channel 与 BaseEntityMailBox 相同(都是到 BaseApp)
- 复用 `bundle()` 方法(包括 setClientArgs 前缀)
- 但 `findMethod` 返回 Cell 的方法描述

#### 11.4.2 getStream 实现

```cpp
// server/cellapp/mailbox.cpp:86-105
BinaryOStream * CellViaBaseMailBox::getStream(
        const MethodDescription & methodDesc,
        std::auto_ptr< Mercury::ReplyMessageHandler > pHandler )
{
    Mercury::Bundle & bundle = this->bundle();

    // Not supporting return values
    if (pHandler.get())
    {
        PyErr_Format( PyExc_TypeError,
                "Cannot call two-way method '%s' from CellApp",
                methodDesc.name().c_str() );
        return NULL;
    }

    bundle.startMessage( BaseAppIntInterface::callCellMethod );
    bundle << methodDesc.internalIndex();

    return &bundle;
}
```

消息格式:
- 消息类型:`BaseAppIntInterface::callCellMethod`(发到 BaseApp)
- 参数 1:方法索引
- 后续:方法参数

注意:不写 `id_`,因为 `bundle()` 已经在前面写了 `setClientArgs`(如果不在本地)。

#### 11.4.3 findMethod 实现

```cpp
// server/cellapp/mailbox.cpp:119-123
const MethodDescription * CellViaBaseMailBox::findMethod(
    const char * attr ) const
{
    return pLocalType_->description().cell().find( attr );
}
```

返回 Cell 的方法描述。

#### 11.4.4 component 实现

```cpp
// server/cellapp/mailbox.cpp:110-113
EntityMailBoxRef::Component CellViaBaseMailBox::component() const
{
    return EntityMailBoxRef::CELL_VIA_BASE;
}
```

### 11.5 ClientViaBaseMailBox 深度剖析

`ClientViaBaseMailBox` 通过 Base 转发到 Client。CellApp 实现:

```cpp
// server/cellapp/mailbox.cpp:251-378
class ClientViaBaseMailBox : public CommonBaseEntityMailBox
{
    Py_Header( ClientViaBaseMailBox, CommonBaseEntityMailBox )

public:
    ClientViaBaseMailBox( EntityTypePtr pBaseType,
                const Mercury::Address & addr, EntityID id,
                RecordingOption recordingOption =
                    RECORDING_OPTION_METHOD_DEFAULT,
                PyTypeObject * pType = &s_type_ ) :
        CommonBaseEntityMailBox( pBaseType, addr, id, pType ),
        recordingOption_( recordingOption )
    {}

    virtual ~ClientViaBaseMailBox() { }

    virtual BinaryOStream * getStream( const MethodDescription & methodDesc,
            std::auto_ptr< Mercury::ReplyMessageHandler > pHandler );
    virtual EntityMailBoxRef::Component component() const;
    virtual const MethodDescription * findMethod( const char * attr ) const;

    PY_KEYWORD_METHOD_DECLARE( pyCall )

private:
    RecordingOption recordingOption_;
};
```

#### 11.5.1 getStream 实现

```cpp
// server/cellapp/mailbox.cpp:315-335
BinaryOStream * ClientViaBaseMailBox::getStream(
        const MethodDescription & methodDesc,
        std::auto_ptr< Mercury::ReplyMessageHandler > pHandler )
{
    Mercury::Bundle & bundle = this->bundle();

    // Not supporting return values
    if (pHandler.get())
    {
        PyErr_Format( PyExc_TypeError,
                "Cannot call two-way method '%s' from CellApp",
                methodDesc.name().c_str() );
        return NULL;
    }

    bundle.startMessage( BaseAppIntInterface::callClientMethod );
    bundle << methodDesc.internalIndex();
    bundle << uint8( recordingOption_ );

    return &bundle;
}
```

消息格式:
- 消息类型:`BaseAppIntInterface::callClientMethod`
- 参数 1:方法索引
- 参数 2:RecordingOption(1 字节)
- 后续:方法参数

#### 11.5.2 pyCall 与 RecordingOption

```cpp
// server/cellapp/mailbox.cpp:360-378
PyObject * ClientViaBaseMailBox::pyCall( PyObject * args, PyObject * kwargs )
{
    RecordingOption recordingOption = RECORDING_OPTION_METHOD_DEFAULT;

    if (!this->parseRecordingOptionFromPythonCall( args, kwargs,
            recordingOption ))
    {
        return NULL;
    }

    if (recordingOption == recordingOption_)
    {
        this->incRef();
        return this;
    }

    return new ClientViaBaseMailBox( pLocalType_, this->address(), this->id(),
        recordingOption );
}
```

如果 recordingOption 与当前相同,直接返回 this(避免创建新对象);否则创建新的 `ClientViaBaseMailBox` 携带新 option。

### 11.6 ClientViaCellMailBox 深度剖析

`ClientViaCellMailBox` 通过 Cell 转发到 Client(实际是 Cell → Base → Client)。CellApp 实现:

```cpp
// server/cellapp/mailbox.cpp:388-515
class ClientViaCellMailBox : public CellEntityMailBox
{
    Py_Header( ClientViaCellMailBox, CellEntityMailBox )

public:
    ClientViaCellMailBox( EntityTypePtr pBaseType,
                const Mercury::Address & addr, EntityID id,
                RecordingOption recordingOption =
                    RECORDING_OPTION_METHOD_DEFAULT,
                PyTypeObject * pType = &s_type_ ) :
        CellEntityMailBox( pBaseType, addr, id, pType ),
        recordingOption_( recordingOption )
    {}
    // ...
};
```

#### 11.6.1 getStream 实现

```cpp
// server/cellapp/mailbox.cpp:427-471
BinaryOStream * ClientViaCellMailBox::getStream(
        const MethodDescription & methodDesc,
        std::auto_ptr< Mercury::ReplyMessageHandler > pHandler )
{
    Mercury::Channel * pChannel = this->pChannel();
    if (!pChannel)
    {
        PyErr_Format( PyExc_TypeError,
                "No channel to CellApp %s",
                this->address().c_str() );
        return NULL;
    }

    Mercury::Bundle & bundle = pChannel->bundle();

    // Not supporting return values
    if (pHandler.get())
    {
        PyErr_Format( PyExc_TypeError,
                "Cannot call two-way method '%s' from CellApp",
                methodDesc.name().c_str() );
        return NULL;
    }

    bundle.startMessage( CellAppInterface::callClientMethod );
    bundle << id_; // Which cell entity
    bundle << id_; // Which entity on the client app

    uint8 flags = 0;

    if (recordingOption_ != RECORDING_OPTION_RECORD_ONLY)
    {
        flags |= MSG_FOR_OWN_CLIENT;
    }

    if (methodDesc.shouldRecord( recordingOption_ ))
    {
        flags |= MSG_FOR_REPLAY;
    }

    bundle << flags;
    bundle << methodDesc.internalIndex();

    return &bundle;
}
```

注意:

1. **写入两次 id_**:第一个是 CellApp 上的目标实体 ID,第二个是客户端上的目标实体 ID(对 ownClient 而言相同)
2. **flags 编码**:使用 `ClientMethodCallingFlags`
   - `MSG_FOR_OWN_CLIENT = 0x01`:发送到 own client
   - `MSG_FOR_OTHER_CLIENTS = 0x02`:发送到其他客户端
   - `MSG_FOR_REPLAY = 0x04`:用于回放

### 11.7 _VIA_ 与直接 Mailbox 的对比

| 维度 | 直接 Mailbox | _VIA_ Mailbox |
|------|-------------|--------------|
| 网络跳数 | 1 跳 | 2-3 跳 |
| 延迟 | 低 | 稍高 |
| Channel 复用 | 单独 Channel | 复用已有 Channel |
| two-way 支持 | 是(从 BaseApp) | 否 |
| 持久化 | 取决于 Component | 通常不能(因为依赖 Cell) |
| 故障恢复 | BackupHashChain 重定向 | 链路中任一节点故障都需要处理 |
| 适用场景 | 持有持久 Mailbox | 临时调用,无需存储 |

### 11.8 _VIA_ 转发链路图

```
                ┌────────────────────────────────────────────┐
                │       调用方进程 (CellApp A 中实体 X)         │
                │                                            │
                │  脚本: bCellMB.base.method()                │
                │  脚本: bCellMB.client.method()             │
                │  脚本: bBaseMB.cell.method()               │
                │  脚本: bBaseMB.client.method()              │
                │                                            │
                │  生成对应 _VIA_ Mailbox                     │
                │       │                                    │
                │       │  getStream() 写入转发消息             │
                │       ▼                                    │
                └────────────────────────────────────────────┘
                                │
                                ▼
                ┌────────────────────────────────────────────┐
                │       中转进程 (CellApp B / BaseApp B)      │
                │                                            │
                │  接收: callBaseMethod / callClientMethod    │
                │       / callCellMethod                      │
                │                                            │
                │  调用本地实体的方法或继续转发                  │
                │                                            │
                │       │                                    │
                │       │  如继续转发,生成新 Mailbox             │
                │       ▼                                    │
                └────────────────────────────────────────────┘
                                │
                                ▼
                ┌────────────────────────────────────────────┐
                │       目标进程 (BaseApp B / Client B)        │
                │                                            │
                │  接收: callBaseMethod / selectPlayerEntity   │
                │                                            │
                │  执行方法,可能返回结果                       │
                │                                            │
                └────────────────────────────────────────────┘
```

---

## 十二、RemoteEntityMethod 远程方法代理

`RemoteEntityMethod` 是 Mailbox 与 Python 调用之间的"代理对象",它代表"远程对象上的某个方法"。

### 12.1 类定义

```cpp
// lib/entitydef/remote_entity_method.hpp:19-49
class RemoteEntityMethod : public PyObjectPlus
{
    Py_Header( RemoteEntityMethod, PyObjectPlus )

public:
    RemoteEntityMethod( PyEntityMailBox * pMailBox,
            const MethodDescription * pMethodDescription,
            PyTypeObject * pType = &s_type_ ) :
        PyObjectPlus( pType ),
        pMailBox_( pMailBox ),
        pMethodDescription_( pMethodDescription )
    {
    }
    ~RemoteEntityMethod() { }

    PY_KEYWORD_METHOD_DECLARE( pyCall )

    ScriptDict convertReturnValuesToDict( ScriptTuple pArgs ) const;
    PY_AUTO_METHOD_DECLARE( RETDATA,
            convertReturnValuesToDict, ARG( ScriptTuple, END ) );

    ScriptObject argumentTypes() const;
    ScriptObject returnValueTypes() const;

    PY_RO_ATTRIBUTE_DECLARE( argumentTypes(), argumentTypes );
    PY_RO_ATTRIBUTE_DECLARE( returnValueTypes(), returnValueTypes );

private:
    SmartPointer< PyEntityMailBox > pMailBox_;
    const MethodDescription * pMethodDescription_;
};
```

### 12.2 关键点

1. **持有 Mailbox 智能指针**:`SmartPointer<PyEntityMailBox>`,防止 Mailbox 在代理对象之前销毁
2. **持有 MethodDescription 指针**:不持有所有权(MethodDescription 由 EntityType 管理,生命周期与进程一致)
3. **支持 __call__**:`PY_KEYWORD_METHOD_DECLARE(pyCall)` 使其可调用
4. **支持 argumentTypes/returnValueTypes 属性**:用于反射

### 12.3 pyCall 实现

```cpp
// lib/entitydef/remote_entity_method.cpp:39-55
PyObject * RemoteEntityMethod::pyCall( PyObject * args, PyObject * kwargs )
{
    ScriptTuple pArgs = ScriptTuple( args,
        ScriptTuple::FROM_BORROWED_REFERENCE );

    if (kwargs)
    {
        pArgs = pMethodDescription_->convertKeywordArgs( pArgs,
            ScriptDict( kwargs, ScriptObject::FROM_BORROWED_REFERENCE ) );

        if (!pArgs)
        {
            return NULL;
        }
    }
    return pMailBox_->callMethod( pMethodDescription_, pArgs );
}
```

注意:
- 支持关键字参数(kwargs 不为 NULL 时,通过 `convertKeywordArgs` 转为位置参数)
- 最终调用 `pMailBox_->callMethod`,即 PyEntityMailBox 的核心方法

### 12.4 工作流程

```
脚本: mailbox.someMethod(arg1, arg2)
        ↓
PyEntityMailBox::pyGetAttribute("someMethod")
        ↓
findMethod("someMethod") → MethodDescription*
        ↓
返回 new RemoteEntityMethod(this, methodDesc)
        ↓
脚本立即调用: remoteMethod(arg1, arg2)
        ↓
RemoteEntityMethod::pyCall(args, kwargs=NULL)
        ↓
PyEntityMailBox::callMethod(methodDesc, args)
        ↓
... (进入 callMethod 流程,见第六章)
```

### 12.5 convertReturnValuesToDict

```cpp
// lib/entitydef/remote_entity_method.cpp:61-65
ScriptDict RemoteEntityMethod::convertReturnValuesToDict(
        ScriptTuple pArgs ) const
{
    return pMethodDescription_->createDictFromTuple( pArgs );
}
```

这是辅助方法,把返回值元组转为字典(按返回值名称),便于脚本访问:

```python
result = yield mailbox.someMethod()
# result 是 tuple
result_dict = mailbox.someMethod.convertReturnValuesToDict(result)
# result_dict 是 dict,可按名访问
```

### 12.6 argumentTypes 和 returnValueTypes

```cpp
// lib/entitydef/remote_entity_method.cpp:80-103
ScriptObject RemoteEntityMethod::argumentTypes() const
{
    return pMethodDescription_->argumentTypesAsScript();
}

ScriptObject RemoteEntityMethod::returnValueTypes() const
{
    return pMethodDescription_->returnValueTypesAsScript();
}
```

返回元组,每个元素是 `(name, type_string)` 形式的元组:

```python
>>> mailbox.someMethod.argumentTypes
(('damage', 'FLOAT'), ('attackerID', 'ENTITY_ID'))
>>> mailbox.someMethod.returnValueTypes
(('actualDamage', 'FLOAT'),)
```

### 12.7 RemoteClientMethod 的特殊性

BaseApp 中的 `ClientEntityMailBox` 不返回 `RemoteEntityMethod`,而是返回 `RemoteClientMethod`:

```cpp
// server/baseapp/client_entity_mailbox.cpp:65-78
ScriptObject ClientEntityMailBox::pyGetAttribute( const ScriptString & attrObj )
{
    const MethodDescription * pDescription = 
        this->findMethod( attrObj.c_str() );
    if (pDescription != NULL)
    {
        return ScriptObject( new RemoteClientMethod( this, 
            this->getEntityDescription().name(),
            pDescription,
            proxy_.channel() ), ScriptObject::FROM_NEW_REFERENCE );
    }

    return PyObjectPlus::pyGetAttribute( attrObj );
}
```

`RemoteClientMethod` 比普通 `RemoteEntityMethod` 多持有 channel 引用,支持流式过滤(stream filter)等客户端特定功能。

---

## 十三、Mailbox 调用流程端到端剖析

### 13.1 完整调用时序

以 BaseApp 上的 Base 实体调用其 Cell 实体的 `onMoveTo(position)` 方法为例:

```
时序图:

  BaseApp(Base)                CellApp(Cell)              Mercury(UDP)
       │                            │                          │
       │  1. 脚本: self.cell.onMoveTo(pos)
       │                            │                          │
       │  2. PyEntityMailBox::pyGetAttribute("onMoveTo")      │
       │     └→ findMethod("onMoveTo") → MethodDescription*  │
       │     └→ new RemoteEntityMethod(this, methodDesc)      │
       │                            │                          │
       │  3. RemoteEntityMethod::pyCall((pos,))                │
       │     └→ convertKeywordArgs (无 kwargs)                │
       │     └→ pMailBox_->callMethod(methodDesc, (pos,))     │
       │                            │                          │
       │  4. PyEntityMailBox::callMethod(methodDesc, args)    │
       │     ├─ areValidArgs(pos) 校验参数                    │
       │     ├─ hasReturnValues()? 否 → pReplyHandler=NULL    │
       │     ├─ getStream(methodDesc, NULL)                   │
       │     │   └→ CommonCellEntityMailBox::getStreamEx     │
       │     │       ├─ pChannel() 获取 Base.channel()         │
       │     │       ├─ bundle = pChannel->bundle()            │
       │     │       ├─ startMessage(runScriptMethod)          │
       │     │       ├─ bundle << id_                          │
       │     │       ├─ bundle << methodDesc.internalIndex()  │
       │     │       └→ return &bundle                         │
       │     ├─ extractSourceEntityID((pos,)) → (pos,)         │
       │     ├─ addToServerStream(pos) → bundle                │
       │     ├─ countSentToGhosts(bundle.size() - startSize)  │
       │     └─ sendStream()                                   │
       │         └→ ServerEntityMailBox::sendStream            │
       │             ├─ pChannel() (同上)                       │
       │             ├─ if (channel.addr().ip == 0) → 缓冲     │
       │             └→ networkInterface.delayedSend(channel)  │
       │                            │                          │
       │                            │  5. UDP 包发送           │
       │                            │  ←─────────────────────────│
       │                            │                          │
       │                            │  6. Mercury 收到包         │
       │                            │     ├─ 解析 Bundle        │
       │                            │     ├─ 查找消息处理函数     │
       │                            │     └─ 调用 Entity::callMethod... │
       │                            │                          │
       │                            │  7. MethodDescription::callMethod │
       │                            │     ├─ getArgsFromStream(data) │
       │                            │     ├─ script method invocation │
       │                            │     └─ def onMoveTo(self, pos): │
       │                            │         ...               │
       │                            │                          │
```

### 13.2 关键步骤详解

#### 13.2.1 步骤 2:pyGetAttribute

当 Python 访问 `self.cell.onMoveTo` 时:

1. Python 调用 `CellEntityMailBox::pyGetAttribute("onMoveTo")`
2. 实际调用 `PyEntityMailBox::pyGetAttribute`(基类实现)
3. 调用 `findMethod("onMoveTo")` 查找方法描述
4. 如果找到,创建 `RemoteEntityMethod` 代理对象并返回
5. 如果未找到,走基类查找内置属性(`address`、`id` 等)

#### 13.2.2 步骤 4:getStream 写入 Bundle

`getStream` 的工作:

1. 获取 Channel(从 Base.channel() 或 CellApp.getChannel(addr))
2. 获取该 Channel 的 Bundle(每个 Channel 都有一个累积中的 Bundle)
3. 在 Bundle 中写入消息头(startMessage / startRequest)
4. 写入方法的目标信息(EntityID、MethodIndex)
5. 返回 BinaryOStream 指针供调用方继续写入参数

#### 13.2.3 步骤 4:写入参数

`addToServerStream` 把 Python 参数元组按 .def 中声明的方法签名序列化到 Bundle:

```python
# .def 文件
<onMoveTo>
    <Arg> position </Arg>  <!-- VECTOR3 -->
</onMoveTo>
```

`addToServerStream` 会:
- 校验参数数量(必须 1 个)
- 校验参数类型(必须 Vector3)
- 把 Vector3 写入 Bundle(12 字节:3 个 float)

#### 13.2.4 步骤 4:sendStream 发送

`sendStream` 的工作:

1. 获取 Channel
2. 检查 Channel 是否已建立(addr.ip != 0)
3. 调用 `networkInterface.delayedSend(channel)` 延迟发送

`delayedSend` 不是立即发送,而是在下一次 NetworkInterface::processIO 时发送。这样多个消息可以累积在 Bundle 中,合并为一个 UDP 包发送,提高效率。

#### 13.2.5 步骤 7:接收端执行

CellApp 接收到消息后:

1. Mercury 解析 UDP 包,提取 Bundle
2. 根据 messageID 查找处理函数(`CellAppInterface::runScriptMethod` → `Entity::callMethod`)
3. 调用 `MethodDescription::callMethod(self, data)`:
   - 从 data 读取参数
   - 调用 Python 方法 `onMoveTo(self, position)`
   - 处理返回值(如果有,通过 replyID 发送回去)

### 13.3 接收端消息处理

以 BaseApp 接收 `callBaseMethod` 为例:

```cpp
// server/baseapp/base.cpp:1286-1342
void Base::callBaseMethod( const Mercury::Address & srcAddr,
        const Mercury::UnpackedMessageHeader & header,
        BinaryIStream & data )
{
    MethodIndex index;
    data >> index;

    MethodDescription * pMethodDescription =
        pType_->description().base().internalMethod( index );

    if (pMethodDescription != NULL)
    {
        if (pMethodDescription->isComponentised())
        {
            MF_ASSERT(pEntityDelegate_);
            // TODO: processing of call results and error
            MF_ASSERT(header.replyID == Mercury::REPLY_ID_NONE);
            
            if (!pEntityDelegate_->handleMethodCall(*pMethodDescription, data))
            {
                ERROR_MSG( "Base::callBaseMethod: "
                    "failed to call method %s on %s entity's delegate",
                    pMethodDescription->name().c_str(),
                    this->pType()->name());
            }
        }
        else // conventional call to entity method
        {
            if (header.replyID != Mercury::REPLY_ID_NONE)
            {
                pMethodDescription->callMethod( 
                    ScriptObject( this, ScriptObject::FROM_BORROWED_REFERENCE ),
                    data, 0, header.replyID, &srcAddr, 
                    &BaseApp::instance().intInterface() );
            }
            else
            {
                pMethodDescription->callMethod( 
                    ScriptObject( this, ScriptObject::FROM_BORROWED_REFERENCE ),
                    data );
            }
        }
    }
    else
    {
        ERROR_MSG( "Base::callBaseMethod: "
            "Do not have method with index %d\n", index );

        if (header.replyID != Mercury::REPLY_ID_NONE)
        {
            MethodDescription::sendReturnValuesError(
                    "BWInternalError", "Invalid method index",
                    header.replyID, srcAddr,
                    BaseApp::instance().intInterface() );
        }
    }
}
```

注意:
1. **replyID 区分 one-way 和 two-way**:如果 replyID != REPLY_ID_NONE,说明是 two-way,需要返回值
2. **isComponentised**:如果是组件化实体(委托给 C++ 处理),走 EntityDelegate
3. **错误处理**:方法不存在时,如果是 two-way,需要发送错误回执

### 13.4 转发消息处理(callCellMethod)

当 BaseApp 收到 `callCellMethod`(即来自 CellViaBaseMailBox 的消息)时:

```cpp
// server/baseapp/base.cpp:1391-1458
void Base::callCellMethod( const Mercury::Address & srcAddr,
           const Mercury::UnpackedMessageHeader & header,
           BinaryIStream & data )
{

    if (pCellEntityMailBox_ == NULL)
    {
        ERROR_MSG( "Base::callCellMethod(%u): "
                    "Unable to locate cell entity mailbox.\n", id_ );
        data.finish();

        char msg[ 128 ];
        bw_snprintf( msg, sizeof( msg ),
                "Entity %d of type %s has no cell entity\n",
                id_, pType_->name() );

        sendTwoWayFailure( "BWNoSuchCellEntityError", msg,
                header.replyID, srcAddr );

        return;
    }

    MethodIndex methodIndex;
    data >> methodIndex;

    const MethodDescription * pDescription =
            this->pType()->description().cell().internalMethod( methodIndex );

    if (pDescription != NULL)
    {
        std::auto_ptr< Mercury::ReplyMessageHandler > pReplyHandler;

        if (header.replyID != Mercury::REPLY_ID_NONE)
        {
            pReplyHandler.reset( new TwoWayMethodForwardingReplyHandler(
                    srcAddr, header.replyID ) );
        }

        BinaryOStream * pBOS = pCellEntityMailBox_->getStream( *pDescription,
                pReplyHandler );

        if (pBOS == NULL)
        {
            PyErr_Clear();

            ERROR_MSG( "Base::callCellMethod(%u): "
                        "Failed to get stream on cell method %s.\n",
                        id_, pDescription->name().c_str() );
            data.finish();

            sendTwoWayFailure( "BWInternalError",
                    "Failed to get stream from cell mailbox",
                    header.replyID, srcAddr );
            return;
        }

        pBOS->transfer( data, data.remainingLength() );
        pCellEntityMailBox_->sendStream();
    }
    else
    {
        ERROR_MSG( "Base::callCellMethod(%u): "
                    "Invalid method index (%d) on cell.\n", id_, methodIndex );

        sendTwoWayFailure( "BWInternalError", "Invalid method index",
                header.replyID, srcAddr );
    }
}
```

注意:
1. **校验 Base 是否有 Cell Mailbox**:如果没有 Cell,无法转发,需要返回错误
2. **TwoWayMethodForwardingReplyHandler**:如果是 two-way,创建转发 handler,把 Cell 的返回值再转发给原始调用者
3. **transfer**:把剩余数据(参数)直接拷贝到新 Bundle,无需反序列化-再序列化(零拷贝优化)

---

## 十四、Mailbox 与 Bundle/Channel 协作

### 14.1 三层抽象

BigWorld 网络通信分三层:

```
┌────────────────────────────────────────────────┐
│  Mailbox 层(PyEntityMailBox 派生类)            │
│  - 抽象:目标实体 + 方法 + 参数                  │
│  - 由脚本调用                                    │
│  - 调用 Bundle/Channel 完成实际通信              │
└────────────────────────────────────────────────┘
                       │
                       ▼
┌────────────────────────────────────────────────┐
│  Bundle 层(Mercury::Bundle)                    │
│  - 抽象:消息序列(可累积多条消息)              │
│  - 流式接口(<< 操作符)                         │
│  - 由 Channel 拥有                              │
└────────────────────────────────────────────────┘
                       │
                       ▼
┌────────────────────────────────────────────────┐
│  Channel 层(Mercury::UDPChannel)               │
│  - 抽象:到某地址的可靠/不可靠通信管道           │
│  - 由 NetworkInterface 管理                      │
│  - 处理重传、确认、流量控制                       │
└────────────────────────────────────────────────┘
```

### 14.2 Mailbox 持有 Channel 的方式

Mailbox **不直接持有 Channel**,而是按需通过 `pChannel()` 获取。这有几个原因:

1. **节省内存**:一个进程可能有成千上万个 Mailbox,但只有几十个 Channel
2. **Channel 共享**:多个 Mailbox 共享同一 Channel(到同一进程)
3. **解耦**:Channel 创建/销毁由 NetworkInterface 管理,Mailbox 不需要关心

### 14.3 获取 Channel 的几种方式

#### 14.3.1 按地址查找(CellApp 版本)

```cpp
// server/cellapp/mailbox.cpp:760-768
Mercury::UDPChannel * CellEntityMailBox::pChannel() const
{
    CellAppChannel * pCellAppChannel = CellAppChannels::instance().get( addr_ );
    if (pCellAppChannel != NULL)
    {
        return &pCellAppChannel->channel();
    }
    return NULL;
}
```

通过 `CellAppChannels` 全局单例查找已建立的 Channel。

#### 14.3.2 按地址查找(BaseApp 版本)

```cpp
// server/baseapp/mailbox.cpp:602-610
Mercury::UDPChannel * ServerEntityMailBox::pChannel() const
{
    if (addr_.ip == 0)
    {
        return NULL;
    }

    return &BaseApp::getChannel( addr_ );
}
```

`BaseApp::getChannel(addr)` 是一个静态方法,从 ChannelMap 查找或创建。

#### 14.3.3 通过本地实体(BaseApp CommonCell 版本)

```cpp
// server/baseapp/mailbox.cpp:712-743
Mercury::UDPChannel * CommonCellEntityMailBox::pChannel() const
{
    Base * pBase = BaseApp::instance().bases().findEntity( id_ );

    if (!pBase)
    {
        Mercury::UDPChannel * pChannel = this->ServerEntityMailBox::pChannel();
        // ...
        return pChannel;
    }

    // ...
    return &pBase->channel();
}
```

如果本地有该 Base,直接用 Base 的 Channel(Base 与其 Cell 之间有专用 Channel)。

#### 14.3.4 通过本地实体(CellApp CommonBase 版本)

```cpp
// server/cellapp/mailbox.cpp:879-883
Mercury::UDPChannel & CommonBaseEntityMailBox::channel( Entity * pEntity ) const
{
    return (pEntity && pEntity->isReal()) ?
        pEntity->pReal()->channel() : CellApp::getChannel( addr_ );
}
```

如果本地有该 Real,用 Real 的 Channel(与其 Base 之间有专用 Channel)。

### 14.4 Bundle 累积机制

Bundle 不是每次调用都创建新的,而是每个 Channel 累积一个:

```cpp
Mercury::Bundle & bundle = pChannel->bundle();
```

`pChannel->bundle()` 返回 Channel 当前累积的 Bundle。多次调用 `getStream` 会在同一 Bundle 中追加多条消息,直到:

1. Bundle 满(超过 MTU)
2. 显式调用 `sendStream`
3. NetworkInterface 主循环触发发送

这种"批量发送"机制显著提升性能:

- 减少 UDP 包数量(每个包固定 28 字节 IP+UDP 头)
- 减少系统调用次数
- 提高带宽利用率

### 14.5 Channel 发送机制

`sendStream` 不直接发送,而是触发 Channel 的延迟发送:

```cpp
pChannel->networkInterface().delayedSend( *pChannel );
```

`delayedSend` 把 Channel 标记为"有待发送数据",在下次 `processIO` 时发送。这种设计:

- 允许一个 tick 内多次调用 Mailbox,只产生一个 UDP 包
- 与游戏 tick 同步(每 tick 发送一次)
- 避免频繁 syscall

### 14.6 Channel 的可靠性

`Bundle::startMessage` 接受 `ReliableType` 参数,默认 `RELIABLE_DRIVER`:

```cpp
// lib/network/bundle.hpp:80-81
virtual void startMessage( const InterfaceElement & ie,
    ReliableType reliable = RELIABLE_DRIVER ) = 0;
```

可靠性类型:

- `RELIABLE_DRIVER`:由 Channel 决定(玩家 Channel 可靠,其他 Channel 不可靠)
- `RELIABLE`:必须可靠(ACK + 重传)
- `UNRELIABLE`:不可靠(无 ACK)

Mailbox 默认使用 `RELIABLE_DRIVER`,即跟随 Channel 的可靠性设置。这是合理的:

- 玩家相关的 Channel(玩家自己的 Base)是可靠的,重要消息不会丢失
- 其他 Channel(其他 CellApp)可能不可靠,容忍偶尔丢失

### 14.7 流量控制

Channel 内置流量控制:

1. **发送窗口**:类似 TCP,限制 in-flight 数据量
2. **Bundle 大小限制**:不超过 MTU
3. **延迟发送**:累积多个消息再发送

Mailbox 不直接处理流量控制,完全依赖 Channel。如果 Channel 拥塞,`sendStream` 会自动缓冲。

### 14.8 Channel 与 Mailbox 的关系图

```
进程 A                                     进程 B
┌────────────────────────────┐            ┌────────────────┐
│  Mailbox 1 (entity 100)    │            │                │
│  Mailbox 2 (entity 200)    │            │                │
│  Mailbox 3 (entity 300)    │  ────┐     │                │
│                            │       │    │                │
│  Channel (→ 进程 B)        │ ◄─────┘    │                │
│  ├─ Bundle (累积中)        │            │                │
│  │   ├─ msg: callMethod    │            │                │
│  │   ├─ msg: callMethod    │            │                │
│  │   └─ msg: callMethod   │  ────►     │  Network       │
│  └─ ...                    │            │  Interface     │
└────────────────────────────┘            └────────────────┘
```

注意:3 个 Mailbox 共用 1 个 Channel,3 次调用累积在同一 Bundle 中,最终合并为 1 个 UDP 包发送。

---

## 十五、Mailbox 创建与销毁

### 15.1 创建时机

Mailbox 在以下场景被创建:

#### 15.1.1 从 EntityMailBoxRef 重建

最常见的场景。当从网络/DB 收到一个 `EntityMailBoxRef`,通过 `constructFromRef` 重建 Mailbox:

```cpp
PyObject * pMB = PyEntityMailBox::constructFromRef( ref );
```

具体工厂见"工厂注册机制"章节。

#### 15.1.2 实体创建时

当创建新实体时,自动生成对应的 Mailbox。例如,Base 创建时:

```cpp
// server/baseapp/base.cpp:2729-2739
EntityMailBoxRef Base::baseEntityMailBoxRef() const
{
    EntityMailBoxRef embr;
    embr.init( id_,
        BaseApp::instance().intInterface().address(),
        (this->isServiceFragment() ? 
            EntityMailBoxRef::SERVICE : 
            EntityMailBoxRef::BASE),
        pType_->id() );
    return embr;
}
```

**Service Fragment 判定**:Base 通过 `isServiceFragment()` 区分普通 Base 与 Service Fragment(服务碎片)。Service Fragment 是 BigWorld 14.x 引入的概念,允许把全局服务以 Base 形式部署,但其 Mailbox Component 标记为 `SERVICE`,便于接收端做特殊路由。这种设计避免 Service Fragment 与普通 Base 混淆,也使客户端能在不知道目标进程类型的情况下统一处理。

类似地,CellApp 侧提供 `cellEntityMailBoxRef()`:

```cpp
// server/cellapp/cell.cpp(示意)
EntityMailBoxRef Cell::cellEntityMailBoxRef() const
{
    EntityMailBoxRef embr;
    embr.init( id_,
        CellApp::instance().intInterface().address(),
        EntityMailBoxRef::CELL,
        pType_->id() );
    return embr;
}
```

#### 15.1.3 客户端登录时

LoginApp 完成登录后,BaseApp 会创建 ClientEntityMailBox 并下发给客户端。客户端侧通过 `BigWorld.player()` 等接口拿到的就是该 Mailbox 的客户端镜像。客户端创建 Mailbox 的代码路径见 `client/entity_mailbox` 相关实现,其本质也是 `constructFromRef`。

#### 15.1.4 _VIA_ Mailbox 的派生

当 Base 持有 Cell 的 Mailbox 但需要让第三方"经 Base 转发到 Cell"时,会构造 `CELL_VIA_BASE` 类型。这种派生通常发生在 Base 把自己的 cell mailbox 暴露给其他 Base 时:

```python
# 脚本层示例
otherBase.entity.someMethod( self.cellViaBaseMailBox )
```

`cellViaBaseMailBox` 在 Base 的 `__getattr__` 中按需生成,内部调用 `CellViaBaseMailBox` 构造函数,把 base 和 cell 的地址同时编码进 Mailbox。

### 15.2 销毁时机

Mailbox 的销毁相对复杂,涉及 Python 引用计数、Mercury Channel 生命周期、Population 链表摘除等多方面。

#### 15.2.1 Python 引用归零

PyEntityMailBox 继承自 `PyObjectPlus`,受 Python 引用计数管理。当最后一个引用消失时,析构函数被调用:

```cpp
// lib/entitydef/mailbox_base.cpp(示意)
PyEntityMailBox::~PyEntityMailBox()
{
    Population::instance().erase( *this );
}
```

`Population::erase` 把自己从全局链表摘除,这是统计与监控的基础数据结构。

#### 15.2.2 实体销毁联动

当实体被销毁时,对应的 Mailbox 也会进入销毁流程。但要注意:

1. **Mailbox 不主动销毁实体**:Mailbox 是"远程实体的引用",销毁 Mailbox 不会通知远程实体
2. **实体销毁会使其所有 Mailbox 失效**:远程持有的 Mailbox 在下次使用时会收到 `REPLY_ENTITY_LOST` 异常

#### 15.2.3 Channel 生命周期

Mailbox 持有的 Mercury Channel 是按需创建的。当 Mailbox 销毁时:

- 如果是 `RELIABLE_DRIVER` 模式的 Channel,会被显式 `stop()` 释放
- 如果是 `RELIABLE` / `UNRELIABLE` 模式,由 NetworkInterface 的 channel 表统一管理,Mailbox 销毁不立即释放

这种设计避免了短生命周期 Mailbox 频繁建拆 TCP/UDP 连接。

#### 15.2.4 Population 链表清理

`Population` 是单例,持有所有活着的 PyEntityMailBox。在 BaseApp / CellApp 关闭时,会遍历 Population 强制清理所有 Mailbox,避免内存泄漏检测误报。

### 15.3 引用计数与所有权

Mailbox 的所有权模型有几个层次:

| 层次 | 持有者 | 说明 |
|------|--------|------|
| Python 层 | 脚本变量、容器 | 标准 Python 引用计数 |
| C++ 层 | `SmartPointer<PyEntityMailBox>` | SmartPointer 模板,自动增减引用 |
| 远程引用 | `EntityMailBoxRef`(12 字节) | 不持有引用,仅作"地址快照" |
| Channel 层 | Mercury Channel | Mailbox 弱引用 Channel,Channel 由 NetworkInterface 拥有 |

`SmartPointer<PyEntityMailBox>` 在 `RemoteEntityMethod` 中被使用:

```cpp
// lib/entitydef/remote_entity_method.hpp
class RemoteEntityMethod
{
    SmartPointer<PyEntityMailBox> pMailBox_;
};
```

这保证了在 `RemoteEntityMethod` 代理对象存活期间,Mailbox 不会被销毁。

### 15.4 创建销毁的状态机

下图为 Mailbox 从创建到销毁的状态流转:

```
        ┌─────────────────┐
        │ EntityMailBoxRef│  网络/DB 12 字节
        └────────┬────────┘
                 │ constructFromRef
                 ▼
        ┌─────────────────┐
        │ PyEntityMailBox │  Python 对象
        │  (引用计数=1)   │
        └────────┬────────┘
                 │ 被脚本持有
                 ▼
        ┌─────────────────┐
        │   被使用中      │  sendStream/方法调用
        │ Channel 可能在  │
        │   此按需建立    │
        └────────┬────────┘
                 │ 引用归零
                 ▼
        ┌─────────────────┐
        │ 析构:从Population│
        │ 摘除,Channel 不 │
        │ 一定立即释放     │
        └─────────────────┘
```

---

## 十六、Mailbox 迁移机制

### 16.1 为什么需要迁移

Mailbox 迁移是 BigWorld 容灾与负载均衡的核心机制。当目标进程(CellApp/BaseApp)发生以下事件时,所有指向它的 Mailbox 都需要"迁移"到新地址:

1. **进程崩溃**:CellApp/BaseApp 死亡,其上实体被恢复到其他进程
2. **负载均衡**:CellAppMgr 把 Cell 迁移到另一台 CellApp
3. **实体迁移**:Entity 跨 Cell 移动,其 ghost 也跟着变
4. **BackupHashChain 重映射**:Base 的 backup 切换主备

如果不做迁移,Mailbox 会持续向失效的地址发包,造成消息黑洞。

### 16.2 MigrateMailBoxVisitor

BigWorld 用 Visitor 模式批量迁移 Mailbox。核心类:

```cpp
// lib/server/migrate_mailbox_visitor.hpp
class MigrateMailBoxVisitor : public EntityMailBoxRefVisitor
{
public:
    MigrateMailBoxVisitor( const Mercury::Address & srcAddr,
                           const Mercury::Address & dstAddr );
    bool visit( PyEntityMailBox & mailbox ) /* override */;
private:
    Mercury::Address srcAddr_;
    Mercury::Address dstAddr_;
};
```

`visit` 方法对每个 Mailbox 检查:如果地址匹配 `srcAddr_`,就调用 `pMailBox->migrate()`:

```cpp
bool MigrateMailBoxVisitor::visit( PyEntityMailBox & mailbox )
{
    if (mailbox.addr() == srcAddr_)
    {
        mailbox.migrate( dstAddr_ );
    }
    return true; // 继续访问
}
```

### 16.3 PyEntityMailBox::migrate

```cpp
// lib/entitydef/mailbox_base.cpp(示意)
void PyEntityMailBox::migrate( const Mercury::Address & dstAddr )
{
    pChannel_ = NULL; // 旧 Channel 作废
    addr_ = dstAddr;  // 更新地址
    // 子类可以重写以处理 Component 切换等
}
```

注意 `migrate` 只更新地址,不修改 Component 类型。这是因为迁移通常发生在同一类型进程之间(CellApp → CellApp)。

### 16.4 CellApp 调用点

```cpp
// server/cellapp/cellapp.cpp(示意)
void CellApp::adjustForDeadBaseApp( const Mercury::Address & deadAddr )
{
    // ... 找到新的 BaseApp 地址 ...
    MigrateMailBoxVisitor visitor( deadAddr, newBaseAppAddr );
    PyEntityMailBox::Population::instance().visit( visitor );
}
```

`CellApp::migrateMailBoxes` 同样用于 Cell 迁移场景。

### 16.5 BaseApp 调用点

```cpp
// server/baseapp/baseapp.cpp(示意)
void BaseApp::adjustForDeadBaseApp( const Mercury::Address & deadAddr )
{
    // ... 找到对应的 backup Base ...
    BaseBackupSwitchMailBoxVisitor visitor( deadBaseAppAddr,
        newBaseAppAddr, *pBackupHashChain_ );
    PyEntityMailBox::Population::instance().visit( visitor );
}
```

注意这里用的是 `BaseBackupSwitchMailBoxVisitor`,它额外借助 BackupHashChain 重映射 backup 地址。

### 16.6 迁移流程图

```
       ┌──────────────────────────┐
       │ 进程死亡被检测(BaseAppMgr)│
       └────────────┬─────────────┘
                    │ 通知所有相关进程
                    ▼
       ┌──────────────────────────┐
       │ CellApp / BaseApp 收到通知│
       └────────────┬─────────────┘
                    │ 构造 Visitor
                    ▼
       ┌──────────────────────────┐
       │ Population::visit        │
       │  遍历所有 Mailbox         │
       └────────────┬─────────────┘
                    │ visit() 返回 true 继续遍历
                    ▼
       ┌──────────────────────────┐
       │ 对每个匹配 srcAddr 的     │
       │ Mailbox 调用 migrate     │
       └────────────┬─────────────┘
                    │
                    ▼
       ┌──────────────────────────┐
       │ Mailbox 更新 addr,作废   │
       │ Channel,后续消息发往新址 │
       └──────────────────────────┘
```

### 16.7 迁移期间的消息处理

迁移期间,如果脚本继续调用 Mailbox 方法,会发生什么?

- **`migrate` 是同步的**:它立即更新 `addr_`,之后的调用就走新地址
- **旧 Channel 的在途消息**:由 Mercury 的 `RELIABLE_DRIVER` 保证重传,新 Channel 接管后由对端去重
- **不会丢消息**:Mercury 的 `REPLY_ID` 机制保证 two-way 调用一定有回应(成功或异常)

但是,如果在迁移瞬间正好有消息发往旧地址,旧地址已经死亡,消息会被 Mercury 标记为 `REPLY_NO_ANSWER` 异常,Python 侧收到的是 `BigWorld.NoEntity` 异常。脚本需要处理这种情况。

### 16.8 迁移与 Component 类型

通常迁移不改变 Component 类型,但有一种特殊情况:**BaseApp 崩溃后,Base 的实体被 backup 接管,但 backup 上的实体可能在另一个 CellApp 上有 ghost**。这种情况下:

- `BASE_VIA_CELL` 类型保持不变(只是 base 地址变了)
- `CELL_VIA_BASE` 类型会同时变更 base 和 cell 地址
- `CLIENT_VIA_BASE` 类似

`BaseBackupSwitchMailBoxVisitor` 通过 BackupHashChain 重映射时,会针对 _VIA_ 类型做特殊处理,确保 via 链路上的每个地址都被正确更新。

---

## 十七、Mailbox 工厂注册机制

### 17.1 为什么需要工厂

`EntityMailBoxRef` 只携带 12 字节地址 + Component + EntityTypeID。从这 12 字节重建出"对的" PyEntityMailBox 子类实例,需要根据 Component 类型分发到不同的实现类:

- `BASE` → `BaseEntityMailBox`(在 CellApp 中)或 `BaseEntityMailBox`(在 BaseApp 中,作为对其他 Base 的引用)
- `CELL` → `CellEntityMailBox`
- `CLIENT` → `ClientEntityMailBox`
- `BASE_VIA_CELL` / `CELL_VIA_BASE` 等 → 对应的 _VIA_ Mailbox

而且不同进程(CellApp/BaseApp/Client)对"同一个 Component 类型"可能有不同的实现类。例如,CellApp 中引用 BASE 时使用 `BaseEntityMailBox`(向 BaseApp 发包),而 BaseApp 中引用 BASE 时使用另一个 `BaseEntityMailBox`(向同级 BaseApp 发包),两者实现不同。

因此 BigWorld 用工厂注册模式让每个进程在初始化时注册自己的 Mailbox 子类。

### 17.2 MailBoxRefRegistry

工厂注册中心定义在 `lib/entitydef/mailbox_base.hpp`:

```cpp
// lib/entitydef/mailbox_base.hpp(示意)
class MailBoxRefRegistry
{
public:
    typedef PyEntityMailBoxPtr (*Fabricator)( const EntityMailBoxRef & );
    typedef EntityMailBoxRef (*Interpreter)( const PyEntityMailBox & );

    static MailBoxRefRegistry & instance();

    void registerFabricator( int component, Fabricator func );
    void registerInterpreter( int component, Interpreter func );

    Fabricator getFabricator( int component ) const;
    Interpreter getInterpreter( int component ) const;
private:
    std::map<int, Fabricator>  fabricators_;
    std::map<int, Interpreter> interpreters_;
};
```

`Fabricator` 是"从 ref 构造 Mailbox"的工厂函数,`Interpreter` 是"从 Mailbox 提取 ref"的反向函数。两者通过 Component 类型索引。

### 17.3 constructFromRef

```cpp
// lib/entitydef/mailbox_base.cpp(示意)
PyObject * PyEntityMailBox::constructFromRef( const EntityMailBoxRef & ref )
{
    int component = ref.component;
    MailBoxRefRegistry::Fabricator f =
        MailBoxRefRegistry::instance().getFabricator( component );
    if (!f)
    {
        ERROR_MSG( "No fabricator for component %d\n", component );
        Py_RETURN_NONE;
    }
    PyEntityMailBoxPtr pMB = f( ref );
    return pMB.getObject();
}
```

进程未注册对应 Component 的 Fabricator 时,返回 None 并打 ERROR 日志。这通常发生在把客户端 Mailbox 在 CellApp 中尝试构造,但 CellApp 未注册 CLIENT Fabricator(因为 CellApp 不直接和客户端通信)。

### 17.4 CellApp 工厂注册

```cpp
// server/cellapp/mailbox.cpp(示意)
class CellAppPostOfficeAttendant : public MailBoxRefRegistry::Attendant
{
public:
    void registerFabricators()
    {
        REGISTER_FABRICATOR( EntityMailBoxRef::BASE, BaseEntityMailBox );
        REGISTER_FABRICATOR( EntityMailBoxRef::CELL, CellEntityMailBox );
        REGISTER_FABRICATOR( EntityMailBoxRef::BASE_VIA_CELL, BaseViaCellMailBox );
        REGISTER_FABRICATOR( EntityMailBoxRef::CLIENT_VIA_CELL, ClientViaCellMailBox );
        REGISTER_FABRICATOR( EntityMailBoxRef::CELL_VIA_BASE, CellViaBaseMailBox );
        REGISTER_FABRICATOR( EntityMailBoxRef::CLIENT_VIA_BASE, ClientViaBaseMailBox );
    }
};
```

注意:CellApp 不注册 `CLIENT` 和 `SERVICE` 的 Fabricator,因为 CellApp 不直接和客户端、Service Fragment 通信。

### 17.5 BaseApp 工厂注册

```cpp
// server/baseapp/mailbox.cpp(示意)
class BaseAppPostOfficeAttendant : public MailBoxRefRegistry::Attendant
{
public:
    void registerFabricators()
    {
        REGISTER_FABRICATOR( EntityMailBoxRef::BASE, BaseEntityMailBox );
        REGISTER_FABRICATOR( EntityMailBoxRef::CELL, CommonCellEntityMailBox );
        REGISTER_FABRICATOR( EntityMailBoxRef::CLIENT, ClientEntityMailBox );
        REGISTER_FABRICATOR( EntityMailBoxRef::BASE_VIA_CELL, BaseViaCellMailBox );
        REGISTER_FABRICATOR( EntityMailBoxRef::CLIENT_VIA_CELL, ClientViaCellMailBox );
        REGISTER_FABRICATOR( EntityMailBoxRef::SERVICE, BaseEntityMailBox );
    }
};
```

注意 BaseApp 中:
- `CELL` 用 `CommonCellEntityMailBox`(轻量级,只持有地址)
- `BASE` 和 `SERVICE` 都用 `BaseEntityMailBox`(因为向其他 BaseApp 发包的实现是相同的)
- 没有 `CELL_VIA_BASE` / `CLIENT_VIA_BASE`,因为 BaseApp 自己就是 Base,不需要"经 Base 转发"

### 17.6 客户端工厂注册

客户端只注册 `BASE` 和 `CELL`(以及 _VIA_ 变体),不注册 `CLIENT`(自己就是 client)。

### 17.7 Attendant 模式

`MailBoxRefRegistry::Attendant` 是个抽象基类:

```cpp
class Attendant
{
public:
    virtual void registerFabricators() = 0;
    virtual void registerInterpreters() = 0;
};
```

每个进程在初始化时构造自己的 Attendant 子类,调用其 `registerFabricators` / `registerInterpreters`。这种模式让 Mailbox 子类不需要在编译期知道"自己被谁注册",只需在运行期由进程的初始化代码决定。

### 17.8 REGISTER_FABRICATOR 宏

```cpp
#define REGISTER_FABRICATOR( COMPONENT, CLASS ) \
    MailBoxRefRegistry::instance().registerFabricator( COMPONENT, \
        CLASS::fabricateFromRef );
```

每个 PyEntityMailBox 子类都需要实现静态方法 `fabricateFromRef`:

```cpp
static PyEntityMailBoxPtr CellEntityMailBox::fabricateFromRef(
    const EntityMailBoxRef & ref )
{
    return new CellEntityMailBox( ref );
}
```

### 17.9 工厂注册表

汇总各进程注册的 Fabricator:

| Component | CellApp | BaseApp | Client |
|-----------|---------|---------|--------|
| BASE | BaseEntityMailBox | BaseEntityMailBox | BaseEntityMailBox |
| CELL | CellEntityMailBox | CommonCellEntityMailBox | CellEntityMailBox |
| CLIENT | - | ClientEntityMailBox | - |
| SERVICE | - | BaseEntityMailBox | - |
| BASE_VIA_CELL | BaseViaCellMailBox | BaseViaCellMailBox | - |
| CLIENT_VIA_CELL | ClientViaCellMailBox | ClientViaCellMailBox | - |
| CELL_VIA_BASE | CellViaBaseMailBox | - | - |
| CLIENT_VIA_BASE | ClientViaBaseMailBox | - | - |

**对称性观察**:
- _VIA_ 的 BASE_VIA_CELL 和 CLIENT_VIA_CELL 在 CellApp 和 BaseApp 都注册,因为两者都可能持有
- CELL_VIA_BASE 和 CLIENT_VIA_BASE 仅 CellApp 注册,因为 BaseApp 自己就是 Base 不需要"经 Base 转发"
- CLIENT 仅 BaseApp 注册,因为只有 BaseApp 拥有客户端

### 17.10 工厂注册时机

工厂注册必须在 `constructFromRef` 被调用前完成。具体时机:

- CellApp / BaseApp:在 `CellApp::init` / `BaseApp::init` 早期阶段,先于脚本环境初始化
- 客户端:在 `BigWorld.init` 早期阶段

如果脚本环境初始化时,`entity.def` 加载触发了 Mailbox 属性解析,而工厂还没注册,就会出错。

### 17.11 Interpreter 注册

`Interpreter` 是反向:把 Mailbox 转成 `EntityMailBoxRef` 用于网络传输。每个 Mailbox 子类提供 `ref()` 方法返回 `EntityMailBoxRef`,该方法对应 Interpreter 的实现:

```cpp
EntityMailBoxRef SomeMailBox::interpreter( const PyEntityMailBox & mb )
{
    return mb.ref();
}
```

注册时把 `interpreter` 函数指针登记到 `MailBoxRefRegistry` 中。

---

## 十八、Mailbox 持久化与 Pickling

### 18.1 持久化需求

Mailbox 需要在以下场景被持久化:

1. **写入数据库**:Entity 的属性可能是 Mailbox 类型(`MAILBOX` data type),需要随 Entity 一起存 DB
2. **跨进程传输**:通过 Bundle 在 CellApp/BaseApp/Client 间传输 Mailbox
3. **Python Pickling**:脚本可能把 Mailbox 作为 dict 的 value,需要支持 pickle
4. **存档/重放**:RecordingOption 系统需要把 Mailbox 写入回放日志

### 18.2 MailBoxDataType

```cpp
// lib/entitydef/data_types/mailbox_data_type.hpp
class MailBoxDataType : public DataType
{
public:
    bool isType( DataType::EType type ) const { return type == DT_MAILBOX; }
    int streamSize() const { return sizeof(EntityMailBoxRef); } // 12 字节
    void addToStream( BinaryOStream & stream, const PyEntityMailBox & mb );
    void createFromStream( BinaryIStream & stream, PyEntityMailBox *& pMB );
};
```

`streamSize` 返回 `sizeof(EntityMailBoxRef) = 12` 字节。Mailbox 在网络流中始终占用固定 12 字节。

### 18.3 addToStream 实现

```cpp
void MailBoxDataType::addToStream( BinaryOStream & stream,
                                    const PyEntityMailBox & mb )
{
    // 调用对应 Component 的 Interpreter,得到 EntityMailBoxRef
    EntityMailBoxRef ref = mb.ref();
    stream << ref; // 12 字节直接写入
}
```

### 18.4 createFromStream 实现

```cpp
void MailBoxDataType::createFromStream( BinaryIStream & stream,
                                        PyEntityMailBox *& pMB )
{
    EntityMailBoxRef ref;
    stream >> ref; // 12 字节直接读出
    pMB = (PyEntityMailBox *)PyEntityMailBox::constructFromRef( ref );
}
```

### 18.5 数据库持久化

写入 DB 时,MailBox 不直接以二进制存储,而是被分解为 DataSection 节点:

```xml
<mailbox>
    <id>12345</id>
    <ip>192.168.1.100</ip>
    <port>30000</port>
    <component>BASE</component>
    <entityTypeID>5</entityTypeID>
</mailbox>
```

`MailBoxDataType::addToSection` / `createFromSection` 实现这种序列化。

### 18.6 Python Pickling 支持

PyEntityMailBox 实现 `__reduce__` 方法,使 Python 的 pickle 模块能正确序列化:

```cpp
// lib/entitydef/mailbox_base.cpp(示意)
PyObjectPtr PyEntityMailBox::pyReduce()
{
    EntityMailBoxRef ref = this->ref();
    // 返回 (constructor, args) 元组
    return Py_BuildValue( "(s(iish))", "BigWorld.Mailbox",
        ref.addr.ip, ref.addr.port, ref.component, ref.salt );
}
```

unpickle 时调用 `BigWorld.Mailbox(ip, port, component, salt)` 构造出新的 Mailbox。这个构造函数由 PyEntityMailBox 的 `__init__` 提供,内部调用 `constructFromRef`。

### 18.7 Pickling 注意事项

- **跨进程 Pickling**:如果 BaseApp pickle 了一个 Base Mailbox,在 Client 侧 unpickle,Component 类型保持一致,但客户端工厂会构造客户端版本的 BaseEntityMailBox
- **地址漂移**:如果 Mailbox 在 pickle 后被迁移,unpickle 出的 Mailbox 仍然是旧地址。因此 Pickling 仅适合短生命周期场景
- **EntityID 不可变**:EntityID 在 Mailbox 寿命内不变,即使地址变化,EntityID 仍是同一个

### 18.8 录制系统(Recording)

回放系统把 Mailbox 调用记录到日志,用于后续回放:

```cpp
// lib/server/recording_options.hpp
enum RecordingOption
{
    RECORDING_OPTION_METHOD_DEFAULT,
    RECORDING_OPTION_DO_NOT_RECORD,
    RECORDING_OPTION_RECORD,
    RECORDING_OPTION_RECORD_ONLY
};
```

录制时,Mailbox 调用被序列化为:
- 目标 MailboxRef(12 字节)
- 方法 ID(int)
- 参数列表(BinaryStream)

回放时,根据 MailboxRef 找到目标 Mailbox,重放调用。如果回放期间 Mailbox 已失效,系统会跳过该调用并打 WARNING 日志。

### 18.9 客户端方法调用标志

对于发往 Client 的方法,有额外的标志位:

```cpp
// lib/server/client_method_calling_flags.hpp
enum ClientMethodCallingFlags
{
    MSG_FOR_OWN_CLIENT     = 0x01, // 发给自己的客户端
    MSG_FOR_OTHER_CLIENTS  = 0x02, // 发给观察该 Entity 的其他客户端
    MSG_FOR_REPLAY         = 0x04  // 录制用于回放
};
```

`ClientEntityMailBox::sendStream` 根据 `recordingOption` 和 `callingFlags` 决定:
- 是否发送给 own client(`MSG_FOR_OWN_CLIENT`)
- 是否广播给其他客户端(`MSG_FOR_OTHER_CLIENTS`)
- 是否记录到回放日志(`MSG_FOR_REPLAY`)

`RECORD_ONLY` 选项只记录不发送,用于"模拟客户端响应"的测试场景。

---

## 十九、故障透明性:Mailbox 自动重定向

### 19.1 故障透明性目标

BigWorld 的设计目标是:**脚本层不需要关心目标进程是否死亡**。Mailbox 调用要么成功,要么抛出 Python 异常(可以 try/except),但脚本不需要主动检测"目标还活着吗"。

这要求 Mailbox 系统具备:
1. **自动迁移**:进程死亡后,Mailbox 自动指向新地址
2. **失败可见**:迁移失败或目标实体已死时,Mailbox 调用要抛出明确异常
3. **重试语义**:网络抖动期间的请求,要保证 idempotent 或明确失败

### 19.2 BackupHashChain

BackupHashChain 是 BaseApp 容灾的核心数据结构,定义在 `lib/server/backup_hash_chain.hpp`。它是一个一致性哈希环,记录了每个 BaseApp 的 backup 关系。

```cpp
// lib/server/backup_hash_chain.hpp(示意)
class BackupHashChain
{
public:
    Mercury::Address addressFor( int hash ) const;
    void addRange( const Mercury::Address & addr, int rangeStart, int rangeEnd );
    bool hasAddress( const Mercury::Address & addr ) const;
private:
    std::vector<Range> ranges_;
};
```

`addressFor(hash)` 根据 hash 值在哈希环上找到对应的 BaseApp 地址。这样,即使原 BaseApp 死亡,根据 EntityID hash 仍能找到新的 backup BaseApp。

### 19.3 BaseBackupSwitchMailBoxVisitor

这是故障重定向的核心 Visitor:

```cpp
// lib/server/base_backup_switch_mailbox_visitor.hpp(示意)
class BaseBackupSwitchMailBoxVisitor : public EntityMailBoxRefVisitor
{
public:
    BaseBackupSwitchMailBoxVisitor(
        const Mercury::Address & deadAddr,
        const Mercury::Address & backupAddr,
        const BackupHashChain & hashChain );

    bool visit( PyEntityMailBox & mailbox ) /* override */;
private:
    Mercury::Address deadAddr_;
    Mercury::Address backupAddr_;
    const BackupHashChain & hashChain_;
};
```

`visit` 实现:

```cpp
bool BaseBackupSwitchMailBoxVisitor::visit( PyEntityMailBox & mailbox )
{
    if (mailbox.addr() == deadAddr_)
    {
        // 通过 hash chain 找到新地址
        int hash = mailbox.id();
        Mercury::Address newAddr = hashChain_.addressFor( hash );
        mailbox.migrate( newAddr );
    }
    return true;
}
```

注意:不是简单地把 deadAddr 替换为 backupAddr。因为不同 BaseApp 上的实体可能被分散到不同 backup,需要根据 EntityID 在 hash chain 上找到对应的新 BaseApp。

### 19.4 失败模式与异常

Mailbox 调用可能遇到的异常:

| 异常 | 触发条件 | Python 异常 |
|------|---------|-------------|
| `REPLY_ENTITY_LOST` | 目标实体已销毁 | `BigWorld.NoEntity` |
| `REPLY_NO_ANSWER` | 目标进程无响应(超时) | `BigWorld.NoReply` |
| `REPLY_PROCESSING_FAILED` | 接收端处理时抛异常 | `BigWorld.ProcessingFailed` |
| `REPLY_NOT_FOUND` | 方法 ID 不存在 | `BigWorld.NotFound` |
| Channel 断开 | TCP/UDP 中断 | `BigWorld.ChannelDied` |

脚本示例:

```python
try:
    otherBase.entity.someMethod( arg1, arg2 )
except BigWorld.NoEntity:
    print( "Target entity is gone" )
except BigWorld.NoReply:
    print( "Target process is dead, will retry later" )
```

### 19.5 接收端的实体查找

接收端(BaseApp/CellApp)收到 Mailbox 调用时,通过 EntityID 查找本地实体:

```cpp
// server/baseapp/baseapp.cpp(示意)
void BaseApp::callBaseMethod( const Mercury::Address & srcAddr,
    EntityID entityID, int methodID, BinaryIStream & data )
{
    Base * pBase = this->findBase( entityID );
    if (!pBase)
    {
        // 实体不存在,返回异常
        Mercury::ReplyMessageHandler::sendException(
            REPLY_ENTITY_LOST, srcAddr, ... );
        return;
    }
    pBase->callBaseMethod( srcAddr, methodID, data );
}
```

`REPLY_ENTITY_LOST` 让调用方的 Mailbox 收到 `BigWorld.NoEntity` 异常。

### 19.6 CellApp 容灾

CellApp 容灾和 BaseApp 不同:
- **BaseApp**:有 backup,backup 上有 Base 数据副本,可立即接管
- **CellApp**:无 backup,Cell 数据在内存中,CellApp 死亡 = Cell 数据丢失

因此 CellApp 容灾是"重建"而非"切换":
1. CellAppMgr 检测 CellApp 死亡
2. 通知 BaseApp,BaseApp 重新创建 Cell Entity(`createCellEntity`)
3. 通知 CellApp,CellApp 上的 ghost 被清除,等下次 AoI 更新时重建

期间,所有指向该 CellApp 的 Mailbox 调用都会失败。脚本需要处理这种短期不可用。

### 19.7 调用方重试

BigWorld 不在 Mailbox 层做自动重试。原因:
- 重试可能造成重复执行(非 idempotent 方法)
- 重试增加延迟,反而不利于故障感知
- 脚本应明确知道调用失败

但是,Mercury 的 `RELIABLE_DRIVER` 模式会自动重传 UDP 包,这是网络层而非应用层的重试。

### 19.8 故障感知时机

调用方何时知道目标死了?
- **同步调用(two-way)**:立即,通过 Mercury 的 reply 异常
- **异步调用(one-way)**:不知道!除非:
  - 后续调用失败
  - 接收到 BaseAppMgr 的死亡通知(触发 Visitor 迁移)
  - 主动 ping 检查

这是 one-way 调用的固有缺陷。脚本需要权衡:one-way 性能好但失败感知慢,two-way 反之。

### 19.9 故障重定向流程图

```
        ┌──────────────────────────┐
        │ BaseApp 死亡,BaseAppMgr 检测│
        └────────────┬─────────────┘
                     │
                     ▼
        ┌──────────────────────────┐
        │ BaseAppMgr 通知所有其他进程│
        │ (含 CellApp、BaseApp、     │
        │  BaseAppMgr、DBApp)       │
        └────────────┬─────────────┘
                     │
        ┌────────────┴────────────┐
        ▼                         ▼
┌──────────────┐         ┌──────────────┐
│ CellApp 调用 │         │ BaseApp 调用 │
│ adjustForDead│         │ adjustForDead│
│ BaseApp      │         │ BaseApp      │
└──────┬───────┘         └──────┬───────┘
       │ MigrateMailBox         │ BaseBackupSwitchMailBox
       │  Visitor               │  Visitor + BackupHashChain
       ▼                        ▼
┌──────────────────────────────────────┐
│ Population::visit 遍历所有 Mailbox   │
│  - 替换 deadAddr → newAddr           │
│  - 作废 Channel                       │
└──────────────────────────────────────┘
```

---

## 二十、消息分发:接收端处理

### 20.1 接收端入口

当 Mailbox 调用到达接收端,Mercury 触发对应的 message handler。每个进程的 interface 文件定义了这些 handler。例如 BaseApp 的 `callBaseMethod`:

```cpp
// server/baseapp/baseapp_interface.cpp(示意)
class BaseAppInterface : public Mercury::InputMessageHandler
{
    void callBaseMethod( const Mercury::Address & srcAddr,
        Mercury::UnpackedMessageHeader & header,
        BinaryIStream & data, void * arg )
    {
        EntityID id;
        int methodIndex;
        data >> id >> methodIndex;
        Base * pBase = BaseApp::instance().getBase( id );
        if (!pBase)
        {
            // 异常回复
            return;
        }
        pBase->callBaseMethod( srcAddr, header, methodIndex, data );
    }
};
```

### 20.2 Base::callBaseMethod

`Base::callBaseMethod` 是 BaseApp 接收端的核心实现(详见 `server/baseapp/base.cpp`):

```cpp
// server/baseapp/base.cpp(节选)
void Base::callBaseMethod( const Mercury::Address & srcAddr,
    Mercury::UnpackedMessageHeader & header,
    int index, BinaryIStream & data )
{
    MethodDescription * pMethodDescription =
        this->pType()->description().base().find( index );
    if (pMethodDescription)
    {
        if (pMethodDescription->isComponentised())
        {
            // 委托给 EntityDelegate 处理(C++ 实现的方法)
            MF_ASSERT(pEntityDelegate_);
            pEntityDelegate_->handleMethodCall(*pMethodDescription, data);
        }
        else
        {
            // 调用 Python 方法
            if (header.replyID != Mercury::REPLY_ID_NONE)
            {
                // two-way 调用,需要返回值
                pMethodDescription->callMethod(
                    ScriptObject(this, ScriptObject::FROM_BORROWED_REFERENCE),
                    data, 0, header.replyID, &srcAddr,
                    &BaseApp::instance().intInterface() );
            }
            else
            {
                // one-way 调用
                pMethodDescription->callMethod(
                    ScriptObject(this, ScriptObject::FROM_BORROWED_REFERENCE),
                    data );
            }
        }
    }
    else
    {
        ERROR_MSG( "Base::callBaseMethod: Do not have method with index %d\n", index );
        if (header.replyID != Mercury::REPLY_ID_NONE)
        {
            MethodDescription::sendReturnValuesError(
                "BWInternalError", "Invalid method index",
                header.replyID, srcAddr,
                BaseApp::instance().intInterface() );
        }
    }
}
```

关键点:
1. **MethodDescription 查找**:通过 `find(index)` 找到方法描述对象
2. **isComponentised**:如果是组件化方法(由 C++ EntityDelegate 实现),走 delegate 路径
3. **replyID 区分 one-way/two-way**:`REPLY_ID_NONE` 表示 one-way
4. **错误处理**:方法不存在时,如果是 two-way,需要发送错误回复

### 20.3 ReturnValuesHandler

对于 two-way 调用,接收端需要把方法的返回值打包发送回去。`ReturnValuesHandler` 是这个流程的核心:

```cpp
// lib/entitydef/return_values_handler.hpp
class ReturnValuesHandler : public Mercury::ReplyMessageHandler
{
public:
    ReturnValuesHandler( const MethodDescription & methodDescription );
    void handleMessage( const Mercury::Address & srcAddr,
            Mercury::UnpackedMessageHeader & header,
            BinaryIStream & data, void * arg );
    void handleException( const Mercury::NubException & exception, void * arg );
    PyObjectPtr getDeferred() const { return deferred_.get(); }
private:
    const MethodDescription & methodDescription_;
    PyDeferred deferred_;
};
```

调用流程:
1. 接收端构造 `ReturnValuesHandler`,获得 `PyDeferred` 对象
2. 调用 Python 方法,把 deferred 作为参数传入
3. Python 方法执行完毕后,框架调用 `deferred.callback( returnValue )`
4. `ReturnValuesHandler::handleMessage` 把返回值序列化,作为 Mercury reply 发送
5. 如果发生异常,`handleException` 把异常信息发送回去

### 20.4 PyDeferred

`PyDeferred` 是 BigWorld 实现的 Python deferred 对象,类似 Twisted 的 Deferred。它允许异步地产生返回值,而不是阻塞 Python 方法。

```python
# 脚本示例:two-way 调用接收端
def someMethod( self, deferred, arg ):
    # 异步处理,比如读 DB
    db.get( arg, lambda v: deferred.callback( v ) )
```

如果方法签名中没有 `deferred` 参数,框架假定是同步方法,直接用方法的返回值。

### 20.5 Cell::callCellMethod

CellApp 的接收端类似,但调用的是 `Entity::callMethod`:

```cpp
// server/cellapp/entity.cpp(示意)
void Entity::callMethod( int methodIndex, BinaryIStream & data )
{
    MethodDescription * pMD = this->pType()->description().cell().find( methodIndex );
    pMD->callMethod( ScriptObject(this, ...), data );
}
```

注意 Cell 上通常没有 two-way 调用,因为 Cell 不能阻塞主线程(每帧要处理大量实体)。

### 20.6 ClientEntityMailBox 的 sendToClient

BaseApp 上的 ClientEntityMailBox 不直接发包,而是把消息缓存到 Proxy 的 sendToClient Bundle:

```cpp
// server/baseapp/client_entity_mailbox.cpp(示意)
void ClientEntityMailBox::sendStream( bool isOtherClients,
    Bundle & bundle, int methodID, RecordingOption recordingOption )
{
    // 1. 缓存到 Proxy 的 sendToClient Bundle
    pProxy_->sendToClientBundle().startMessage( ... );
    // 2. 如果 isOtherClients,广播给观察此 Entity 的其他客户端
    if (isOtherClients) this->sendToOtherClients( ... );
    // 3. 如果需要录制,写入回放日志
    if (recordingOption == RECORD || recordingOption == RECORD_ONLY)
        this->recordForReplay( ... );
}
```

这种设计让多个 Mailbox 调用合并到同一个 Bundle,减少网络包数量。

### 20.7 客户端接收端

客户端收到 server→client 消息时,通过 `ClientApp::handleMessage` 分发到对应的 Entity:

```cpp
// client/app.cpp(示意)
void ClientApp::handleEntityMethod( EntityID id, int methodIndex, BinaryIStream & data )
{
    Entity * pEntity = this->findEntity( id );
    if (!pEntity) return;
    pEntity->callClientMethod( methodIndex, data );
}
```

客户端不回复 Mercury(因为 client→server 用另一个 Channel),所以 client 方法都是 one-way。

### 20.8 主线程检查

BaseApp 在 `ClientEntityMailBox::sendStream` 中检查主线程:

```cpp
// server/baseapp/client_entity_mailbox.cpp(示意)
void ClientEntityMailBox::sendStream( ... )
{
    MainThreadTracker::instance().verify( "ClientEntityMailBox::sendStream" );
    // ... 实际发送 ...
}
```

`MainThreadTracker` 在 DEBUG 模式下断言当前线程是主线程,避免从 worker 线程误调 Mailbox 造成数据竞争。

---

## 二十一、Mailbox 统计与监控

### 21.1 Population 全局链表

`PyEntityMailBox::Population` 是单例,维护一个所有 PyEntityMailBox 的链表。每个 Mailbox 构造时自动加入链表,析构时摘除:

```cpp
// lib/entitydef/mailbox_base.hpp(示意)
class PyEntityMailBox
{
public:
    class Population
    {
    public:
        static Population & instance();
        void add( PyEntityMailBox & mb );
        void erase( PyEntityMailBox & mb );
        template<typename Visitor>
        void visit( Visitor & v );
        size_t size() const;
    private:
        PyEntityMailBox * pHead_;
        mutable SimpleMutex lock_;
    };
private:
    PyEntityMailBox * pNext_;
    PyEntityMailBox * pPrev_;
};
```

链表是双向的,加锁保护,因为 BaseApp 的 worker 线程也可能创建 Mailbox(虽然不推荐)。

### 21.2 用途

Population 用于:
1. **统计**:报告当前活着的 Mailbox 数量,按 Component 分类
2. **遍历**:Visitor 模式批量处理(migration、debug 打印等)
3. **泄漏检测**:进程关闭时,Population 应该为空(所有 Mailbox 已被 GC)

### 21.3 EntityMemberStats

更细粒度的统计在 `EntityMemberStats`:

```cpp
// lib/entitydef/entity_member_stats.hpp(示意)
class EntityMemberStats
{
public:
    void countSentToOwnClient();
    void countSentToGhosts();
    void countSentToBase();

    uint64 sentToOwnClient() const { return sentToOwnClient_; }
    uint64 sentToGhosts() const { return sentToGhosts_; }
    uint64 sentToBase() const { return sentToBase_; }
private:
    uint64 sentToOwnClient_ = 0;
    uint64 sentToGhosts_ = 0;
    uint64 sentToBase_ = 0;
};
```

每个 Entity 持有自己的 stats 对象,记录该 Entity 的 Mailbox 调用次数。三个计数器:
- `countSentToOwnClient`:发往自己客户端的次数
- `countSentToGhosts`:发往其他客户端(观察者)的次数
- `countSentToBase`:发往 Base 的次数(从 Cell 角度)

### 21.4 统计上报

BaseApp 每隔一段时间(默认 10 秒)向 BaseAppMgr 上报自己的统计:

```cpp
// server/baseapp/baseapp.cpp(示意)
void BaseApp::reportStats()
{
    Mercury::Bundle & b = BaseAppMgrInterface::reportStats.bundle();
    b << population_.size();           // 当前 Mailbox 数
    b << entityCount_;                 // 实体数
    b << sentToOwnClientTotal_;        // 累计调用数
    // ...
    BaseAppMgrInterface::reportStats.send( ... );
}
```

BaseAppMgr 汇总各 BaseApp 的统计,供运维查看。

### 21.5 应急命令

BigWorld 提供命令行工具(如 `clusterconsole`)和 HTTP 接口查询 Mailbox 状态:

```
> baseapp 1 mailbox_stats
Population: 12563
  BASE: 8721
  CELL: 3421
  CLIENT: 421
  BASE_VIA_CELL: 0
  ...
Sent stats:
  to own client: 1.2M
  to ghosts: 5.6M
  to base: 0.8M
```

### 21.6 异常检测

如果 Population 增长异常(比如 1 分钟内涨 10 倍),可能是脚本 bug 持有大量 Mailbox 不释放。运维可以通过:
- `show_population_dump`:打印所有 Mailbox 的 EntityID + Component + 地址
- 内存分析工具:配合 HeapProfiler 定位持有者

### 21.7 与实体统计的对应

Entity 持有的 Mailbox 数量本身也是统计指标。Cell 上的一个 Entity 可能有:
- `pBaseEntityMailBox_`:1 个(指向其 Base)
- 观察者 ghost:可能有 N 个(每个观察者一个 ClientEntityMailBox)

Entity 的"重"程度可以用 Mailbox 数量度量。当 Entity 的 Mailbox 数 > 阈值时,CellApp 会触发 ghost 优化(降低观察频率)。

### 21.8 Channel 统计

Mercury Channel 自带统计:

```cpp
// lib/network/udp_channel.hpp(示意)
class UDPChannel
{
public:
    uint64 bytesSent() const;
    uint64 bytesReceived() const;
    uint64 packetsSent() const;
    uint64 packetsReceived() const;
    uint64 packetsRetried() const;
    uint64 packetsLost() const;
    float   lossRate() const;
};
```

这些统计通过 `status()` 接口暴露,可以查询任意 Mailbox 对应 Channel 的网络质量。如果某 Channel 的 lossRate 持续高,说明该链路有问题(可能是网络,也可能是目标进程过载)。

---

## 二十二、性能分析

### 22.1 Mailbox 调用开销

一次 Mailbox 方调用的开销拆解:

| 阶段 | 操作 | 耗时(典型值) |
|------|------|---------------|
| Python 层 | `mb.method(args)` → `__getattr__` 创建 RemoteEntityMethod | ~1 μs |
| 序列化 | `addToStream` 把参数写入 Bundle | ~5 μs(取决于参数) |
| Bundle 启动 | `startMessage` / `startRequest` | ~0.5 μs |
| 发送 | NetworkInterface::sendBundle | ~1 μs |
| 网络传输 | UDP + 重传 | 0.1-10 ms(局域网/广域网) |
| 接收端解包 | `>>entityID >> methodID` | ~0.5 μs |
| 查找 Entity | `findBase(id)` / `findEntity(id)` | ~0.5 μs(哈希表) |
| 查找 Method | `description.find(index)` | ~0.5 μs(数组下标) |
| Python 调用 | `callMethod` | ~5-50 μs(取决于方法体) |
| 返回值序列化 | `handleMessage` 序列化返回值 | ~5 μs |
| 返回网络传输 | UDP reply | 0.1-10 ms |
| 调用方收到 reply | `handleMessage` 反序列化 | ~1 μs |
| 触发 deferred | `deferred.callback(returnValue)` | ~2 μs |

**总开销(同步调用,无网络延迟)**:~20-70 μs
**加上网络往返**:0.2-20 ms

### 22.2 性能瓶颈分析

#### 22.2.1 Bundle 频繁 flush

如果脚本每次 Mailbox 调用都触发 Bundle flush,网络包数量爆炸。优化:
- 多次调用合并到一个 Bundle(显式 `bundle.startMessage` + `bundle << args` 多次)
- BaseApp 的 ClientEntityMailBox 已经做了缓存(见 20.6)

#### 22.2.2 Python GIL

每次 Mailbox 调用都进入 Python,需要拿 GIL。BaseApp 主线程串行化所有 Mailbox 调用,这是吞吐瓶颈。优化方向:
- 用 C++ EntityDelegate 实现热点方法(避免进 Python)
- 用 EntityWorker 线程分担非主线程逻辑

#### 22.2.3 Entity 查找

`findBase(id)` 是 O(1) 哈希,但哈希函数不好时性能退化。BigWorld 用 `id % hashTableSize` 简单哈希,hashTableSize 通常是质数,避免聚类。

#### 22.2.4 远程方法分发

`description.find(index)` 实际是数组下标访问(`methods_[index]`),O(1)。但 MethodDescription 内部要遍历参数 type info,这部分是 O(arg_count)。

### 22.3 优化技术

#### 22.3.1 Bundle 合并

```python
# 错误:每次调用都触发 send
for mb in mailboxes:
    mb.method( arg )  # 100 个调用 = 100 个网络包

# 正确:批量构建 Bundle
bundle = BigWorld.Bundle()
for mb in mailboxes:
    bundle.addMessage( mb, 'method', arg )
BigWorld.sendBundle( bundle )  # 1 个网络包,100 个 message
```

#### 22.3.2 优先级 Channel

Mercury 支持按 Channel 设置优先级。重要 Mailbox 的 Channel 可以设为高优先级,优先获取发送机会:

```cpp
pChannel_->setPriority( Mercury::CHANNEL_PRIORITY_HIGH );
```

#### 22.3.3 主备分离

BaseApp 的 backup 不参与 Mailbox 调用,只是 standby。因此 backup 可以承担其他不冲突的工作负载(比如 archive 写 DB),不会和主 BaseApp 抢资源。

#### 22.3.4 CellEntityMailBox 的轻量化

CellEntityMailBox 在 CellApp 之间通信时,使用最轻量的实现:
- 不创建新 Channel,复用 CellApp 之间的固定 Channel
- 不维护 messageID → handler 映射,直接调用预定义接口

### 22.4 内存占用

一个 PyEntityMailBox 的内存占用(64 位系统):

| 部分 | 大小 |
|------|------|
| PyObject header | 16 字节 |
| PyEntityMailBox 自身字段 | ~40 字节 |
| Channel 指针(弱) | 8 字节 |
| Mercury::Address | 8 字节 |
| Population 链表节点 | 16 字节 |
| **合计** | ~88 字节 |

加上 Python dict 缓存(`__dict__`)和类型指针,实际约 120 字节。

10 万个 Mailbox 占用约 12 MB,可接受。

### 22.5 与无 Mailbox 方案对比

如果不使用 Mailbox,而用直接 ID 引用(`EntityID` + Component 类型):
- 优点:每引用仅 8 字节(EntityID 4 + Component 4)
- 缺点:每次调用都要查找目标进程地址,无法直接复用 Channel

Mailbox 用 88 字节换取了:
- 直接持有 Channel(可复用)
- 直接持有地址(无需查表)
- 类型信息(Component + EntityTypeID)便于类型检查

这是典型的"空间换时间"权衡。

### 22.6 性能测试数据(参考)

基于 BigWorld 测试集群(8 核 2.4GHz,千兆网):

| 指标 | 数值 |
|------|------|
| one-way 调用 QPS(单 BaseApp) | ~500K |
| two-way 调用 QPS(单 BaseApp) | ~50K(受网络 RTT 限制) |
| Mailbox 创建 QPS | ~1M |
| Mailbox 销毁 QPS | ~1M |
| Population 遍历(10 万 Mailbox) | ~5 ms |

---

## 二十三、边界情况深度分析

### 23.1 Mailbox 指向自己

Entity 调用自己的 Mailbox 会发生什么?

```python
class MyEntity( BigWorld.Base ):
    def someMethod( self ):
        # self.base 是自己的 Base Mailbox
        self.base.anotherMethod()  # 会发到本进程?
```

实际上,Mailbox 不会"短路"到本进程。`BaseEntityMailBox::sendStream` 仍然把消息发到 Mercury,Mercury 通过 UDP 把消息发到自己的 NetworkInterface,然后 `BaseApp::callBaseMethod` 收到这个包再分发给本进程的 Base。

为什么这么设计?
1. **统一性**:所有 Mailbox 调用走同一路径,简化逻辑
2. **顺序保证**:Mercury 的 Channel 保证消息顺序,直接调用会绕过 Channel
3. **可观察性**:统计、回放都能捕获自调用

性能损失:增加一次 UDP 往返,但通常 < 1ms。

### 23.2 循环引用

```python
a = entityA.base
b = entityB.base
a.other = b
b.other = a
```

Python 的循环引用在 GC 时会被检测到。但 PyEntityMailBox 内部不持有其他 Mailbox 的强引用,因此 Mailbox 之间不会形成循环。Mailbox 引用的目标是远程实体,远程实体的引用计数和本地 Mailbox 无关。

### 23.3 Mailbox 复制

```python
mb1 = entity.base
mb2 = mb1  # Python 引用计数 +1,不是新 Mailbox
mb3 = copy.copy( mb1 )  # 浅拷贝
mb4 = copy.deepcopy( mb1 )  # 深拷贝
```

`copy.copy` 调用 `__reduce__`,实际等同于 pickle/unpickle,会构造新的 Mailbox 对象,但 EntityMailBoxRef 相同。两个 Mailbox 共享 Channel(因为 Channel 由 NetworkInterface 管理,不归 Mailbox 所有)。

### 23.4 Mailbox 比较相等

```python
mb1 = entityA.base
mb2 = entityA.base  # 重新获取
mb1 == mb2  # True or False?
```

BigWorld 实现 `__cmp__` / `__eq__`,比较 EntityMailBoxRef 的字段(id, addr, component)。即使两次获取是不同 PyEntityMailBox 对象,只要 EntityMailBoxRef 相同就视为相等。

### 23.5 Mailbox 作为 dict key

```python
d = {}
d[ entity.base ] = "value"
```

PyEntityMailBox 实现 `__hash__`,基于 EntityMailBoxRef 的 hash。EntityID 是稳定标识,可作为 hash 输入。注意:Mailbox 在迁移后 hash 不变(因为 EntityID 不变),所以迁移前后 Mailbox 在 dict 中保持同样的位置。

### 23.6 Mailbox 跨 Entity 类型

EntityTypeID 编码在 salt 中。如果两个 Entity 类型不同但 EntityID 相同(理论上不可能,因为 EntityID 全局唯一),Mailbox 会指向错误类型的实体。

接收端在 `callBaseMethod` 时,通过 `pType_->description().base().find(methodIndex)` 查找方法,但 `pType_` 是目标 Entity 的实际类型,不是 Mailbox 中编码的 EntityTypeID。

因此,**EntityTypeID 仅用于发送端的类型检查**,接收端不验证。这避免了版本不一致问题(发送端 .def 升级但接收端还没升级)。

### 23.7 Mailbox 静默失效

如果 Mailbox 持有的地址是已死亡进程,且没有触发 Visitor 迁移(因为该进程不是当前 BaseApp/CellApp 集群成员),Mailbox 调用会一直失败。

脚本需要:
- 捕获 `BigWorld.NoReply` 异常
- 在合适时机清理 Mailbox 引用

```python
try:
    mb.method()
except BigWorld.NoReply:
    del self.cachedMB  # 清理失效 Mailbox
```

### 23.8 同时收到多个 MailboxRef 指向同一实体

```python
mb1 = entityA.base  # 从某 BaseApp 获取
mb2 = entityA.base  # 从 backup BaseApp 获取(不同地址!)
```

如果 mb1 和 mb2 的地址不同(因为 backup 上 EntityID 相同但地址不同),两者被视为不相等。但调用 `mb1.method()` 和 `mb2.method()` 实际到达同一个实体(因为 backup 已经接管)。

BigWorld 的设计是:一旦 backup 接管,所有指向原地址的 Mailbox 会被 Visitor 迁移到新地址。迁移完成后 mb1.addr == mb2.addr,两者才相等。

### 23.9 Mailbox 在析构期间被访问

```python
class MyEntity:
    def __del__( self ):
        otherEntity.base.someMethod()  # 访问其他 Mailbox
```

Python 析构期间访问 Mailbox 是允许的,因为 Mailbox 是独立对象。但如果 `otherEntity` 在析构链上,可能引发连锁析构,造成对象图紊乱。BigWorld 推荐:`__del__` 中不要做复杂逻辑。

### 23.10 Mailbox 类型不匹配

```python
mb = entity.cell  # CELL Mailbox
mb.someBaseMethod()  # 该方法只在 BASE 上定义
```

发送端不会检查方法是否在目标 Component 上定义。`mb.someBaseMethod()` 在 `__getattr__` 阶段会创建 RemoteEntityMethod,但 `findMethod` 会失败(因为 CELL description 中没有此方法),抛 `AttributeError`。

如果绕过 `__getattr__`(用 `mb.ref()` 直接发原始消息),接收端的 `description.find(index)` 找不到方法,返回 `REPLY_NOT_FOUND` 异常。

### 23.11 NetworkInterface 关闭后访问 Mailbox

进程关闭时,NetworkInterface 先关闭,Mailbox 后析构。如果脚本在关闭期间访问 Mailbox:

```python
mb.method()  # NetworkInterface 已关闭
```

`sendStream` 会发现 `pChannel_ == NULL` 且 NetworkInterface 不接受新 Channel,直接打 ERROR 日志但不抛异常(避免脚本崩溃)。消息丢失。

### 23.12 Salt 字段冲突

`salt` 字段编码 Component + EntityTypeID。如果 EntityTypeID 超过 13 位(8192 种 Entity 类型),会溢出。BigWorld 14.x 限制 EntityTypeID < 8192。

如果两个不同 Component 的 Mailbox 有相同的 salt 值(理论不可能),会被误判为相等。`componentAsStr` 函数解码 salt 时也依赖 Component << 13 | EntityTypeID 的格式。

### 23.13 _VIA_ Mailbox 的死锁

```python
# A 的 base 持有 B 的 cell_via_base
# B 的 base 持有 A 的 cell_via_base
aB.cell.method()  # 经 A 的 base 转发到 A 的 cell
bA.cell.method()  # 经 B 的 base 转发到 B 的 cell
```

VIA Mailbox 不会死锁,因为每个调用都是独立的 UDP 包,Mercury 不阻塞。但调用方会等待 reply(two-way)或立即返回(one-way)。

---

## 二十四、与其他引擎对比

### 24.1 与 Unreal Engine Replication 对比

| 维度 | BigWorld Mailbox | UE Replication |
|------|------------------|----------------|
| 通信模型 | 进程间 RPC + property 同步 | property 复制 + RPC |
| 目标标识 | EntityID + Component + Address | UObject 引用 |
| 跨进程 | 是,核心设计 | 否,进程内为主 |
| 容错 | 自动迁移 + backup | 重连 |
| 调用语义 | one-way / two-way | RPC 都是 one-way,property 是同步 |
| 性能 | 适合 MMO 大世界 | 适合小房间 |

UE Replication 假设目标是"权威服务器 → 客户端"的星型结构,不假设服务器之间有多个进程。BigWorld 设计之初就是分布式多进程。

### 24.2 与 Photon (Exit Games) 对比

Photon 是 MMO 常用框架,有类似的"Remote Procedure Call"概念。

| 维度 | BigWorld Mailbox | Photon RPC |
|------|------------------|-----------|
| 抽象层 | Mailbox 是 Python 对象 | RPC 是方法标注 |
| 类型安全 | .def 文件描述 | C# 类型系统 |
| 跨进程 | 是 | 是(主从服务器) |
| 调用语义 | one-way / two-way | 主要 one-way |
| 容错 | 自动迁移 | 重连 |

Photon 更轻量,适合小型 MMO。BigWorld 适合大型 MMO,容错和扩展性更强。

### 24.3 与 Nakama 对比

Nakama 是开源的 game server,用 Lua/JS 脚本。

| 维度 | BigWorld Mailbox | Nakama Match |
|------|------------------|--------------|
| 通信模型 | Mailbox RPC | Match 内部状态 |
| 跨进程 | 是 | 否(match 单进程) |
| 持久化 | Entity 持久化 | Match 状态持久化 |
| 容错 | 自动迁移 + backup | Match 重新分配 |

Nakama 的设计更简单,单 match 单进程,无 Mailbox 概念。扩展靠 match 间消息(类似 MQ)。

### 24.4 与 Kafka/Pulsar 等 MQ 对比

MQ 是消息队列,BigWorld Mailbox 是 RPC。两者本质不同:
- MQ:生产者-消费者,消息不绑定具体接收者
- Mailbox:RPC,消息绑定具体实体

但 BigWorld 在 BaseApp 之间也有类似 MQ 的"广播通道",用于全局消息(如 BaseAppMgr 通知)。这部分和 MQ 类似。

### 24.5 与 gRPC 对比

gRPC 是通用 RPC 框架。

| 维度 | BigWorld Mailbox | gRPC |
|------|------------------|------|
| 协议 | Mercury UDP | HTTP/2 TCP |
| 序列化 | BinaryStream 自定义 | Protobuf |
| 调用语义 | one-way / two-way | unary / streaming |
| 服务发现 | EntityID + Component | DNS / etcd |
| 容错 | 自动迁移 | 重试 + 熔断 |
| 适用场景 | 实时游戏 | 微服务 |

gRPC 假设服务是无状态的,通过服务发现定位实例。BigWorld 假设 Mailbox 是有状态的(Entity 状态在内存),Mailbox 直接持有地址。两者适合不同场景。

### 24.6 与 Akka Actor 对比

Akka 的 Actor 模型和 Mailbox 有相似之处。

| 维度 | BigWorld Mailbox | Akka Actor |
|------|------------------|------------|
| 消息模型 | RPC(方法调用) | 消息(类型化消息) |
| 持久化 | Entity + DB | Actor 持久化(persistent actor) |
| 跨进程 | 是 | 是(remote actor) |
| 容错 | backup + 迁移 | supervisor 重启 |
| 调用语义 | one-way / two-way | tell (one-way) / ask (two-way) |

Akka 的 ActorRef 类似 Mailbox,都是远程对象的本地引用。但 Akka 是消息驱动(每条消息独立),BigWorld 是方法驱动(方法签名决定参数)。

### 24.7 与定制方案对比

很多 MMO 团队选择自研网络层。对比自研方案:
- 优点:可控、可定制
- 缺点:容错、负载均衡、持久化等需要重写

BigWorld Mailbox 系统经过多年打磨,容错机制(backup、迁移、Visitor)成熟,自研方案难以匹敌。

---

## 二十五、设计哲学总结

### 25.1 透明性优先

BigWorld Mailbox 的核心设计哲学是**透明性**:脚本开发者不应该意识到 Mailbox 背后是分布式系统。

```python
# 脚本视角:本地对象 vs Mailbox,无差别
localEntity.method( arg )
remoteEntity.base.method( arg )  # 看起来一样
```

这种透明性带来的好处:
- **开发效率**:不需要写网络代码
- **可读性**:业务逻辑清晰
- **可维护性**:网络细节由框架处理

代价:
- **性能不可控**:开发者不知道一次调用花了多久
- **故障不可见**:one-way 调用失败感知慢
- **调试困难**:远程调用栈不连续

### 25.2 显式 Component 分类

7 种 Component 枚举看似复杂,实则是**显式优于隐式**的体现:
- `BASE` vs `CELL` vs `CLIENT`:身份明确
- `_VIA_` 系列:转发路径明确
- `SERVICE`:特殊服务明确

开发者一眼能看出 Mailbox 的目标,避免"这个 Mailbox 到底发到哪"的歧义。

### 25.3 12 字节紧凑表示

EntityMailBoxRef 的 12 字节是精心设计的:
- IP (4) + Port (4) = 8 字节,刚好 Mercury::Address
- ID (4) 字节,够用(40 亿 EntityID)
- Component + EntityTypeID 复用 salt 字段,避免额外字节

这种紧凑设计让 Mailbox 在网络/DB 中开销最小化。10 万个 Mailbox 仅占 1.2 MB。

### 25.4 工厂注册而非硬编码

工厂注册模式让"哪个进程用哪个 Mailbox 子类"的决定延迟到运行期。这带来:
- **解耦**:lib 层不依赖 server 层的具体实现
- **可扩展**:新增进程类型只需新增 Attendant
- **可测试**:测试环境可注册 mock Mailbox

代价是间接性:看 `constructFromRef` 代码无法直接知道构造的是哪个子类。

### 25.5 Visitor 模式批量迁移

迁移用 Visitor 而非遍历 vector,因为:
- **解耦**:Visitor 不需要知道 Population 的内部数据结构
- **可组合**:不同 Visitor 做不同迁移逻辑
- **可中断**:Visitor 返回 false 可停止遍历

`MigrateMailBoxVisitor` 和 `BaseBackupSwitchMailBoxVisitor` 是同一接口的两种实现,代码可复用。

### 25.6 异常而非返回码

Mailbox 调用失败抛 Python 异常,而非返回错误码:
```python
# 错误设计
ret = mb.method()
if ret == ERROR_NO_ENTITY:
    ...

# BigWorld 设计
try:
    mb.method()
except BigWorld.NoEntity:
    ...
```

异常的好处:
- **不可忽略**:不 catch 就崩,不会"忘了检查错误"
- **可分类**:不同异常类型对应不同处理
- **可传播**:异常可以沿调用栈向上传播

代价:Python 异常性能差,不适合高频场景。BigWorld 用 EntityDelegate (C++) 处理热点路径。

### 25.7 单线程主逻辑

BaseApp 主线程串行处理所有 Mailbox 调用,避免锁:
- **简单**:无并发 bug
- **可预测**:性能可建模
- **顺序保证**:消息顺序明确

代价:吞吐受单核限制。BigWorld 通过水平扩展(更多 BaseApp)而非垂直扩展解决。

### 25.8 持久化与 Pickling 统一

Mailbox 的 DB 持久化和 Python Pickling 都基于 EntityMailBoxRef:
- **DB**:DataSection XML 格式(人类可读)
- **Pickling**:二进制 12 字节(机器高效)
- **网络**:二进制 12 字节

三种格式共享底层表示,转换无歧义。

### 25.9 容错是默认行为

BigWorld 不要求开发者"主动处理容错":
- 进程死亡 → 框架自动迁移 Mailbox
- backup 接管 → 框架自动切流量
- 网络抖动 → Mercury 自动重传

开发者只需处理"业务异常"(NoEntity、NotFound),不需要处理"系统异常"(进程死亡、网络断开)。

### 25.10 设计反模式警示

BigWorld Mailbox 也有一些被反思的设计:
- **salt 字段复用**:把 Component 和 EntityTypeID 塞进 16 位 salt,限制 EntityTypeID < 8192。如果重做,会用 32 位字段。
- **_VIA_ 类型组合爆炸**:7 种 Component 类型已经多,_VIA_ 进一步组合。如果重做,可能用 "routing hint" 字段而非枚举。
- **Python 优先**:所有 Mailbox 都是 PyObject,C++ 接口需要间接。如果重做,可能提供 native C++ Mailbox 给性能热点。

### 25.11 总结

BigWorld Mailbox 系统的核心价值:
1. **开发体验**:透明、简洁、Pythonic
2. **运行时性能**:紧凑表示、Channel 复用、批量发送
3. **可靠性**:自动迁移、backup 接管、异常可见
4. **可观测性**:Population 统计、Channel 监控、回放系统

经过 20+ 年的演进,Mailbox 系统仍是 BigWorld 区别于其他引擎的核心竞争力之一。理解 Mailbox 是理解 BigWorld 的关键。

---

## 附录

### 附录 A:关键文件路径速查

#### A.1 核心头文件

| 路径 | 说明 |
|------|------|
| `programming/bigworld/lib/network/basictypes.hpp` | EntityMailBoxRef / Component 枚举 / Mercury::Address |
| `programming/bigworld/lib/network/basictypes.ipp` | Address 内联实现 |
| `programming/bigworld/lib/entitydef/mailbox_base.hpp` | PyEntityMailBox 抽象基类 / Population / 工厂注册 |
| `programming/bigworld/lib/entitydef/mailbox_base.cpp` | PyEntityMailBox 实现 |
| `programming/bigworld/lib/entitydef/remote_entity_method.hpp` | RemoteEntityMethod 代理对象 |
| `programming/bigworld/lib/entitydef/remote_entity_method.cpp` | RemoteEntityMethod 实现 |
| `programming/bigworld/lib/entitydef/data_types/mailbox_data_type.hpp` | MailBoxDataType 持久化 |
| `programming/bigworld/lib/entitydef/return_values_handler.hpp` | two-way 返回值处理 |
| `programming/bigworld/lib/entitydef/entity_member_stats.hpp` | 实体成员统计 |

#### A.2 Server 端 Mailbox 实现

| 路径 | 说明 |
|------|------|
| `programming/bigworld/server/cellapp/mailbox.hpp` | CellApp Mailbox 类层次 |
| `programming/bigworld/server/cellapp/mailbox.cpp` | CellApp Mailbox 实现 + 工厂注册 |
| `programming/bigworld/server/baseapp/mailbox.hpp` | BaseApp Mailbox 类层次 |
| `programming/bigworld/server/baseapp/mailbox.cpp` | BaseApp Mailbox 实现 + 工厂注册 |
| `programming/bigworld/server/baseapp/client_entity_mailbox.hpp` | ClientEntityMailBox(BaseApp 侧) |
| `programming/bigworld/server/baseapp/client_entity_mailbox.cpp` | ClientEntityMailBox 实现 |

#### A.3 Visitor 与容灾

| 路径 | 说明 |
|------|------|
| `programming/bigworld/lib/server/migrate_mailbox_visitor.hpp` | MigrateMailBoxVisitor |
| `programming/bigworld/lib/server/base_backup_switch_mailbox_visitor.hpp` | BaseBackupSwitchMailBoxVisitor |
| `programming/bigworld/lib/server/base_backup_switch_mailbox_visitor.cpp` | 实现 |
| `programming/bigworld/lib/server/backup_hash_chain.hpp` | BackupHashChain |
| `programming/bigworld/lib/server/recording_options.hpp` | RecordingOption 枚举 |
| `programming/bigworld/lib/server/client_method_calling_flags.hpp` | ClientMethodCallingFlags |

#### A.4 接收端处理

| 路径 | 说明 |
|------|------|
| `programming/bigworld/server/baseapp/base.hpp` | Base 类声明 |
| `programming/bigworld/server/baseapp/base.cpp` | Base::callBaseMethod / callCellMethod / baseEntityMailBoxRef |
| `programming/bigworld/server/cellapp/cellapp.cpp` | CellApp::adjustForDeadBaseApp / migrateMailBoxes |
| `programming/bigworld/server/baseapp/baseapp.cpp` | BaseApp::adjustForDeadBaseApp |

#### A.5 测试与示例

| 路径 | 说明 |
|------|------|
| `programming/bigworld/lib/entitydef/unit_test/unittest_mailbox.hpp` | UnittestMailBox 测试用 |
| `programming/bigworld/lib/entitydef/unit_test/` | 单元测试目录 |

### 附录 B:Component 枚举速查

```cpp
// lib/network/basictypes.hpp
enum Component
{
    CELL              = 0,   // CellApp 上的 ghost/tong
    BASE              = 1,   // BaseApp 上的 base
    CLIENT            = 2,   // 客户端
    BASE_VIA_CELL     = 3,   // 经 Cell 转发到 Base
    CLIENT_VIA_CELL   = 4,   // 经 Cell 转发到 Client
    CELL_VIA_BASE     = 5,   // 经 Base 转发到 Cell
    CLIENT_VIA_BASE   = 6,   // 经 Base 转发到 Client
    SERVICE           = 7,   // Service Fragment
};
```

| 枚举值 | 名称 | 含义 | 实际目标进程 |
|--------|------|------|-------------|
| 0 | CELL | Cell 上的实体 | CellApp |
| 1 | BASE | Base 上的实体 | BaseApp |
| 2 | CLIENT | 客户端实体 | Client(经 BaseApp 转发) |
| 3 | BASE_VIA_CELL | 经 Cell 转发到 Base | CellApp → BaseApp |
| 4 | CLIENT_VIA_CELL | 经 Cell 转发到 Client | CellApp → 客户端 |
| 5 | CELL_VIA_BASE | 经 Base 转发到 Cell | BaseApp → CellApp |
| 6 | CLIENT_VIA_BASE | 经 Base 转发到 Client | BaseApp → 客户端 |
| 7 | SERVICE | Service Fragment | BaseApp(以 Service 模式运行) |

### 附录 C:关键消息接口

#### C.1 BaseApp 接收端

```cpp
// server/baseapp/baseapp_interface.cpp(消息定义)
interface BaseApp
{
    // 接收 Mailbox 调用
    callBaseMethod( srcAddr, entityID, methodID, args... );

    // 创建/销毁 Entity
    createEntity( ... );
    destroyEntity( ... );

    // Cell 相关
    setCell( baseID, cellMailboxRef );
    onLoseCell( baseID );
};
```

#### C.2 CellApp 接收端

```cpp
interface CellApp
{
    callCellMethod( srcAddr, entityID, methodID, args... );
    createCellEntity( ... );
    destroyCellEntity( ... );
    // ...
};
```

#### C.3 客户端接收端

```cpp
interface Client
{
    callClientMethod( entityID, methodID, args... );
    // property 更新
    // ...
};
```

### 附录 D:Mailbox 引用与流转图

```
                          ┌──────────────────────────────────┐
                          │       脚本调用方(任意进程)       │
                          │   mb = entity.base / cell / ...   │
                          └────────────────┬─────────────────┘
                                           │
                          ┌────────────────┴─────────────────┐
                          │     __getattr__ 创建 RemoteEntityMethod │
                          │           持有 SmartPointer<PyEntityMailBox> │
                          └────────────────┬─────────────────┘
                                           │ pyCall
                          ┌────────────────┴─────────────────┐
                          │    PyEntityMailBox::sendStream    │
                          │  (虚函数,子类实现具体路由)       │
                          └────────────────┬─────────────────┘
                                           │
              ┌────────────────────────────┴────────────────────────────┐
              │                                                          │
   ┌──────────▼──────────┐                          ┌────────────────────▼────────────┐
   │ 直接 Mailbox         │                          │ _VIA_ Mailbox                  │
   │ (BASE/CELL/CLIENT)   │                          │ (BASE_VIA_CELL 等)             │
   │ → startMessage       │                          │ → 转发到中间进程              │
   │   → Channel.send     │                          │   → 中间进程再 sendStream    │
   └──────────┬──────────┘                          └────────────────────┬────────────┘
              │                                                          │
              └────────────────────────────┬────────────────────────────┘
                                           │ UDP 包
                          ┌────────────────┴─────────────────┐
                          │   Mercury NetworkInterface       │
                          │   → 接收端 InputMessageHandler    │
                          └────────────────┬─────────────────┘
                                           │
                          ┌────────────────┴─────────────────┐
                          │   接收端 findBase/findEntity     │
                          │   → callBaseMethod / callCellMethod │
                          │   → MethodDescription.callMethod │
                          └─────────────────────────────────┘
```

### 附录 E:常见问题排查

#### E.1 `BigWorld.NoEntity` 异常

**原因**:目标实体不存在(已销毁,或 EntityID 错误)。

**排查**:
1. 检查目标 Entity 是否还活着(`BaseApp::getBase(id)`)
2. 检查 EntityID 是否正确(脚本打印日志)
3. 检查 Mailbox 是否指向已死进程(用 `mb.addr` 检查地址)

#### E.2 `BigWorld.NoReply` 异常

**原因**:two-way 调用超时,目标进程无响应。

**排查**:
1. 检查目标进程是否活着(`ps` / `clusterconsole status`)
2. 检查网络连通性(`ping`)
3. 检查目标进程主线程是否被阻塞(可能死循环)

#### E.3 Mailbox 数量暴涨

**原因**:脚本持有大量 Mailbox 不释放。

**排查**:
1. 用 `mailbox_stats` 命令查看 Population
2. 用 `show_population_dump` 打印所有 Mailbox
3. 检查脚本是否有循环引用(Mailbox 引用 Entity,Entity 引用 Mailbox)

#### E.4 调用延迟高

**原因**:网络拥塞或目标进程过载。

**排查**:
1. 检查 Channel 的 `lossRate`(用 `channel_status`)
2. 检查目标进程的 CPU/内存使用
3. 用 `bundle_stats` 查看是否 Bundle 频繁 flush

#### E.5 `REPLY_NOT_FOUND` 异常

**原因**:方法 ID 在接收端找不到。

**排查**:
1. 检查 .def 文件版本是否一致(发送端和接收端)
2. 检查方法是否被误删
3. 检查 EntityTypeID 是否对应错误的 Entity 类型

### 附录 F:相关专题

- 专题 03:容灾备份与恢复机制深度剖析(BackupHashChain 详解)
- 专题 07:Mercury 网络协议深度剖析(Bundle/Channel/NetworkInterface 详解)
- 专题 02:CellApp 实体管理与 ghost 系统
- 专题 04:BaseApp 与 Base 实体生命周期
- 专题 06:Entity 定义与 .def 文件解析

### 附录 G:术语表

| 术语 | 英文 | 含义 |
|------|------|------|
| 邮箱 | Mailbox | 远程实体的本地引用 |
| 邮箱引用 | EntityMailBoxRef | 12 字节网络表示 |
| 组件 | Component | 实体的类型/位置枚举 |
| 经由转发 | _VIA_ | 通过中间进程转发的 Mailbox 类型 |
| 人口表 | Population | 所有 PyEntityMailBox 的全局链表 |
| 工匠 | Fabricator | 从 Ref 构造 Mailbox 的工厂函数 |
| 解释器 | Interpreter | 从 Mailbox 提取 Ref 的函数 |
| 访问者 | Visitor | 批量处理 Mailbox 的模式 |
| 备份哈希链 | BackupHashChain | BaseApp 一致性哈希环 |
| 远程实体方法 | RemoteEntityMethod | Mailbox 方法的代理对象 |
| 录制选项 | RecordingOption | 控制是否录制到回放日志 |
| 客户端方法标志 | ClientMethodCallingFlags | 区分 own/other/replay 的位标志 |
| 服务碎片 | Service Fragment | 以 Base 形式部署的全局服务 |
| 通道 | Channel | Mercury 的可靠传输抽象 |
| 包 | Bundle | Mercury 的消息聚合单元 |
| 网络接口 | NetworkInterface | 进程的网络入口 |
| 主线程追踪器 | MainThreadTracker | DEBUG 模式断言主线程 |
| 返回值处理器 | ReturnValuesHandler | two-way 调用的 reply 处理 |
| 延迟对象 | PyDeferred | 异步返回值的 Python 对象 |
| 实体类型 ID | EntityTypeID | Entity 类型的唯一编号 |

---

**全文完**

本专题系统剖析了 BigWorld Engine 14.4.1 的 Mailbox 通信机制,从 12 字节的 EntityMailBoxRef 紧凑表示,到 7 种 Component 枚举的设计动机,再到 PyEntityMailBox 的类层次、_VIA_ 转发机制、工厂注册模式、Visitor 迁移、故障透明性、性能优化等各个方面。希望读者通过本专题,能深入理解 BigWorld 的"分布式透明通信"哲学,并在实际开发中正确、高效地使用 Mailbox。

---

*引擎版本:BigWorld Engine 14.4.1 Open-Source Edition*

