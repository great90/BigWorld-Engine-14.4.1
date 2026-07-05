# 专题12:Reviver 与 bwmachined 双重守护机制深度剖析

> 本文档深度剖析 BigWorld Engine 14.4.1 中**进程级与业务级双重守护机制**的完整实现,涵盖 `bwmachined`(机器守护进程)与 `Reviver`(看门狗进程)的设计哲学、源码实现、数据结构、算法步骤、边界情况、性能分析与跨引擎对比。所有代码引用均带相对路径与行号,可在源码中直接定位。

---

## 目录

- [一、双重守护概述与设计哲学](#一双重守护概述与设计哲学)
- [二、bwmachined 概述](#二bwmachined-概述)
- [三、bwmachined 核心组件](#三bwmachined-核心组件)
- [四、MachineGuard 协议深度剖析](#四machineguard-协议深度剖析)
- [五、MachineGuard 消息类型详解](#五machineguard-消息类型详解)
- [六、bwmachined 主程序流程](#六bwmachined-主程序流程)
- [七、消息分发机制](#七消息分发机制)
- [八、进程创建流程详解](#八进程创建流程详解)
- [九、进程生命周期管理](#九进程生命周期管理)
- [十、Listeners 出生/死亡通知](#十listeners-出生死亡通知)
- [十一、Tags 系统](#十一tags-系统)
- [十二、Cluster 集群视图](#十二cluster-集群视图)
- [十三、状态持久化与重启恢复](#十三状态持久化与重启恢复)
- [十四、平台抽象层](#十四平台抽象层)
- [十五、用户与权限](#十五用户与权限)
- [十六、Reviver 概述](#十六reviver-概述)
- [十七、ComponentReviver 5 特化类](#十七componentreviver-5-特化类)
- [十八、双死亡检测机制](#十八双死亡检测机制)
- [十九、ReviverSubject 优先级仲裁](#十九reviversubject-优先级仲裁)
- [二十、主备切换 shutDownOnRevive](#二十主备切换-shutdownonrevive)
- [二十一、Reviver 与 bwmachined 的协作](#二十一reviver-与-bwmachined-的协作)
- [二十二、被监控进程注册方式](#二十二被监控进程注册方式)
- [二十三、配置项详解](#二十三配置项详解)
- [二十四、性能分析](#二十四性能分析)
- [二十五、边界情况](#二十五边界情况)
- [二十六、与其他引擎对比](#二十六与其他引擎对比)
- [附录](#附录)

---

## 一、双重守护概述与设计哲学

BigWorld 服务器集群由多类分工不同的进程组成(CellAppMgr、BaseAppMgr、DBAppMgr、DBApp、LoginApp、CellApp、BaseApp 等)。这些进程承担着空间管理、玩家代理、数据持久化、登录接入等关键职责,一旦崩溃将导致整个集群不可用。为此,BigWorld 设计了**两层独立但互补的守护机制**:`bwmachined`(进程级守护)与 `Reviver`(业务级守护)。

### 1.1 双层守护的分工

```
┌─────────────────────────────────────────────────────────────────────┐
│  集群视图(多机协同)                                                  │
│                                                                       │
│   机器 A                          机器 B                              │
│   ┌─────────────────────┐        ┌─────────────────────┐             │
│   │  bwmachined (本机)   │◄──────►  bwmachined (本机)   │             │
│   │  - 进程 fork/exec    │  birth/│  - 进程 fork/exec    │             │
│   │  - birth/death 广播  │  death │  - birth/death 广播  │             │
│   │  - PID/统计/标签     │ 跨机  │  - PID/统计/标签     │             │
│   │  - 集群 ring 维护   │ 通告  │  - 集群 ring 维护   │             │
│   └──────────┬──────────┘        └──────────┬──────────┘             │
│              │                              │                        │
│              │ CreateMessage/fork           │                        │
│              ▼                              ▼                        │
│   ┌─────────────────────┐        ┌─────────────────────┐             │
│   │  Reviver (业务)     │        │  Reviver (业务)     │             │
│   │  - 监控 5 类单例进程│        │  - 监控 5 类单例进程│             │
│   │  - 双死亡检测       │        │  - 双死亡检测       │             │
│   │  - 优先级仲裁       │        │  - 优先级仲裁       │             │
│   │  - 委托 bwmachined  │        │  - 委托 bwmachined  │             │
│   │    拉起新实例       │        │    拉起新实例       │             │
│   └─────────────────────┘        └─────────────────────┘             │
└─────────────────────────────────────────────────────────────────────┘
```

| 层 | 名称 | 职责 | 部署粒度 | 权限要求 | 数据平面/控制平面 |
|----|------|------|---------|---------|----------------|
| 第一层 | `bwmachined` | 进程级守护:fork/exec、信号、birth/death 广播、PID 检查、机器统计 | **每台机器一个** | root(以便切换用户启动子进程) | 控制平面 |
| 第二层 | `Reviver` | 业务级守护:监控关键单例进程、双死亡检测、优先级仲裁、主备切换 | **每机器可多个(主备)** | 普通用户即可 | 控制平面旁路 |

### 1.2 互补性分析

`bwmachined` 与 `Reviver` **不在同一层**而是**互补**关系:

- **bwmachined 不知道业务**:它只是按 `CreateMessage` 启动一个二进制,不关心该进程是不是"管理器"、是否需要从 DB 恢复、是否有主备。它的角色类似 `init`/`systemd` 的子集,但带 BigWorld 特有的 birth/death 广播、tags、用户映射。
- **Reviver 不直接 fork**:Reviver 自身不调用 `fork()`/`exec()`,而是发 `CreateMessage` 给本机 `bwmachined`,由后者实际拉起进程。这让 Reviver **不需要 root 权限**,只需普通用户即可,同时让 bwmachined 集中管理环境继承、工作目录、UID 切换等"易错的特权操作"。
- **死亡检测的两套机制**:
  - `bwmachined` 通过 `waitpid` + `/proc/<pid>/stat` 探测进程退出,然后向所有注册了 death listener 的进程广播 `NOTIFY_DEATH` 消息(UDP,可能丢包)。
  - `Reviver` 既监听 `bwmachined` 的 death 广播,又主动 ping 被监控进程,任一渠道判定死亡都会触发恢复。ping 兜底了广播丢包与"进程假死"两类场景。

### 1.3 与 systemd/init.d 的对比

| 维度 | systemd/init.d | bwmachined + Reviver |
|------|----------------|----------------------|
| 部署粒度 | 一台机器一个 init | 每台机器一个 bwmachined,可跨机协同(ring) |
| 进程启动 | 单元文件(unit) | `CreateMessage` + `bwmachined.conf` tags |
| 死亡检测 | cgroup 事件、SIGCHLD | SIGCHLD + `/proc/<pid>/stat` + 跨机广播 |
| 跨机协同 | 无(需 etcd/consul 等外部组件) | 内建 ring 拓扑 + `MachinedAnnounceMessage` |
| 业务感知 | 无 | Reviver 知道哪些是"管理器"、是否需要 -recover |
| 主备热备 | 无原生支持(需 keepalived 等) | ReviverSubject 优先级仲裁原生支持 |
| 用户隔离 | 单元文件中 User= | CreateMessage.uid_ + setuid/setgid |

`bwmachined` 在某种程度上扮演了"BigWorld 集群范围的 systemd"角色,但比 systemd 多了**跨机协同**(通过 `MachinedAnnounceMessage` 维护 ring)和**业务感知**(`Components` tags、`-recover` 参数)。

### 1.4 与 Kubernetes 的对比

| 维度 | Kubernetes | bwmachined + Reviver |
|------|-----------|----------------------|
| 调度单位 | Pod(多容器) | 单进程 |
| 调度器 | kube-scheduler(集中式) | bwmachined(每机自治 + ring) |
| 死亡检测 | liveness/readiness probe | death 广播 + ping 心跳 |
| 主备 | Deployment + leader election | ReviverSubject 仲裁 |
| 持久化 | PVC | DBApp + DB |
| 跨机通信 | Service/Ingress + CNI | Mercury + MachineGuard |
| 部署形态 | 容器 | 裸进程 |
| 资源开销 | 重(kubelet、API server 等) | 轻(bwmachined ~几千行 C++) |

Kubernetes 提供了更通用的容器编排能力,但引入了大量基础设施依赖。BigWorld 的双重守护是为**游戏服务器集群**量身定制的:它知道游戏进程的语义(管理器 vs 数据进程)、知道如何从 DB 恢复、知道如何做主备切换,且零外部依赖。在"游戏 MMO 后端"这一细分场景下,双重守护比 K8s 更轻量、更贴合业务。

### 1.5 设计哲学总结

1. **关注点分离**:bwmachined 关注"如何安全地启动/停止一个进程",Reviver 关注"何时该启动/停止哪个进程"。
2. **特权最小化**:Reviver 不需要 root,所有特权操作集中在 bwmachined。
3. **双死亡检测**:被动广播 + 主动心跳互补,既快又可靠。
4. **集群自洽**:bwmachined 之间通过 ring 协议自动发现成员,无需外部服务发现。
5. **业务感知**:`-recover` 参数 + `Components` tags 让守护机制理解业务语义。
6. **保守恢复**:`wasAttached` 守门、`shutDownOnRevive` 强制切换,宁可"误关"也不"误启"。

---

## 二、bwmachined 概述

### 2.1 位置与角色

`bwmachined` 位于 `server/tools/bwmachined/`,是 BigWorld 服务器侧的**机器级守护进程**。每台运行 BigWorld 服务器进程的机器都必须先启动一个 `bwmachined` 实例。它承担:

- **进程生命周期管理**:接收 `CreateMessage` 启动新进程,接收 `SignalMessage` 向进程发信号。
- **进程注册表**:维护本机所有 BigWorld 进程的 `procs_` 列表(PID、UID、port、name 等)。
- **birth/death 广播**:进程启动/退出时,通知所有注册了 listener 的进程。
- **机器统计**:CPU、内存、网络接口流量等(`WholeMachineMessage`、`HighPrecisionMachineMessage`)。
- **集群拓扑**:通过 `MachinedAnnounceMessage` 维护集群中所有 bwmachined 的 IP 列表,组成 ring。
- **用户映射**:管理 UID → 用户环境(mfroot、bwrespath)的映射,供 fork 子进程时继承。
- **Tags 系统**:从 `/etc/bwmachined.conf` 与 `/etc/bigworld.conf` 读取标签,供查询(如 `Components` tag)。

### 2.2 设计理念

#### 2.2.1 中央控制

每台机器只有**一个** bwmachined 实例,所有 BigWorld 进程都由它启动(或至少向它注册)。这种"中央控制"模式带来:

- **统一的环境继承**:所有子进程的 `BW_ROOT`、`BWRES_PATH`、`HOME`、`BW_TIMING_METHOD` 由 bwmachined 统一设置。
- **统一的 UID/GID 切换**:bwmachined 以 root 启动,根据 `CreateMessage.uid_` 切换到对应用户身份。
- **统一的进程表**:本机所有 BigWorld 进程都在 `procs_` 中,便于统计、查询、清理。

#### 2.2.2 生命周期管理

bwmachined 不是"启动后即忘"的守护进程,而是**全程跟踪**:

- 启动时:`fork` + `exec`,并通过管道(`FD_CLOEXEC`)感知 exec 是否成功。
- 运行时:周期性 `updateProcessStats` 读取 `/proc/<pid>/stat`,更新 CPU、内存、affinity。
- 退出时:进程退出 → SIGCHLD → `waitpid` 清理僵尸 → 从 `procs_` 移除 → 广播 death。
- 异常:进程"未注销就消失"(`updateProcessStats` 失败且 errno==ENOENT)→ 广播 death。

#### 2.2.3 跨机协同

bwmachined 之间通过 UDP 广播协同,组成一个 ring 拓扑。每个 bwmachined 维护 `machines_` 集合(本机已知的所有 bwmachined IP)。当本机进程 birth/death 时:

1. 本机 bwmachined 通过 `broadcastToListeners` 向本网段广播 `NOTIFY_BIRTH`/`NOTIFY_DEATH`。
2. 其他机器的 bwmachined 收到后,转发给本机注册了对应 listener 的进程(两跳分发)。

这种"两跳分发"让一个机器上的 listener 能收到全集群任何机器的 birth/death 事件,而无需在每个机器都注册 listener。

### 2.3 与 Reviver 的依赖关系

```
Reviver 启动时:
    ├─ registerWithMachined (向 bwmachined 登记自身存在)
    ├─ queryMachinedSettings (查询 Components tags)
    ├─ findInterface (查询被监控进程当前地址)
    └─ registerBirthListener / registerDeathListener (订阅生死事件)

Reviver 检测到死亡时:
    └─ CreateMessage → bwmachined → fork+exec 新进程
```

**bwmachined 不在则 Reviver 无法工作**。因此 bwmachined 是更高优先级的守护进程,通常由 systemd/init 直接管理,而非由 Reviver 监控。

---

## 三、bwmachined 核心组件

`server/tools/bwmachined/` 目录包含 14 个源文件,职责分工如下:

| 文件 | 行数(约) | 职责 |
|------|---------|------|
| `main.cpp` | 130 | 进程入口,解析命令行,初始化守护状态,调用 `machined.run()` |
| `bwmachined.hpp`/`.ipp`/`.cpp` | 1993 | BWMachined 主类,核心逻辑 |
| `cluster.hpp`/`.cpp` | 329/328 | Cluster 类,集群 ring 拓扑与 flood keepalive |
| `incoming_packet.hpp`/`.cpp` | 47/49 | IncomingPacket 类,延迟处理的入站包 |
| `listeners.hpp`/`.cpp` | 46/77 | Listeners 类,birth/death 监听器管理 |
| `linux_machine_guard.hpp`/`.cpp` | 19/599 | Linux 平台的进程启动与统计实现 |
| `server_platform.hpp`/`.cpp` | 117/93 | ServerPlatform 抽象基类 |
| `server_platform_linux.hpp`/`.cpp` | 66/800+ | Linux 平台特化实现 |
| `usermap.hpp`/`.cpp` | 33/206 | UserMap 类,UID → 用户环境映射 |
| `common_machine_guard.hpp` | 195 | 公共定义:ProcessInfo、SystemInfo、Stat 模板等 |
| `message_with_destination.hpp` | 81 | MessageWithDestination 模板,延迟发送的消息 |
| `process_binary_version.hpp` | - | 二进制版本号定义 |

### 3.1 BWMachined 主类

`BWMachined` 是单例(`Singleton<BWMachined>`),承担所有核心逻辑。其声明在 `bwmachined.hpp`:

```cpp
// server/tools/bwmachined/bwmachined.hpp  L20-139
class BWMachined : public Singleton< BWMachined >
{
public:
    BWMachined();
    ~BWMachined();

    bool readConfigFile();
    int run();

    void setPidPath( BW::string pidPath );

    static const char *STATE_FILE;          // 状态持久化文件路径
    void save();
    void load();

    Endpoint & endpoint();
    Cluster & cluster();
    const char * timingMethod() const;

    void closeEndpoints();                 // fork 子进程前关闭套接字

    friend class Cluster;
    friend class IncomingPacket;

private:
    void initNetworkInterfaces();

    bool handleCreateMessage( Endpoint &ep, sockaddr_in &sin,
        MachineGuardMessage &mgm, MGMPacket &replies );

    // ... 其他私有方法 ...

    class PacketTimeoutHandler : public TimerHandler { ... };
    class UpdateHandler : public TimerHandler { ... };

    // 三个 Endpoint
    u_int32_t broadcastAddr_;     // 广播接口 IP
    Endpoint ep_;                  // 主端点(绑定到 broadcastAddr_)
    Endpoint epBroadcast_;         // 监听 255.255.255.255
    Endpoint epLocal_;             // 监听 127.0.0.1

    Cluster cluster_;              // 集群视图
    typedef BW::map< BW::string, Tags > TagsMap;
    TagsMap tags_;                 // 配置文件中的 tags
    BW::string timingMethod_;      // 时间戳获取方式
    ServerPlatform * pServerPlatform_;  // 平台抽象(Linux 实现)
    SystemInfo systemInfo_;        // 机器统计
    BW::vector< ProcessInfo > procs_;   // 本机进程表
    Listeners birthListeners_;     // 出生监听器
    Listeners deathListeners_;     // 死亡监听器
    UserMap users_;                // 用户映射
    TimeQueue64 callbacks_;        // 全局定时器队列
    ServerInfo* pServerInfo_;      // 机器信息查询
    int maxPacketDelayMillisec_;   // 广播回复最大延迟(用于 stagger)
};
```

#### 3.1.1 三端点设计

bwmachined 同时监听三个 UDP 端点,均绑定到 `PORT_MACHINED`(默认 19289,见 `network/portmap.hpp`):

| 端点 | 绑定地址 | 用途 |
|------|---------|------|
| `ep_` | `broadcastAddr_`(本机主广播接口) | 接收来自其他机器的请求与广播 |
| `epLocal_` | `127.0.0.1`(LOCALHOST) | 接收本机进程的请求(避免跨网卡) |
| `epBroadcast_` | `255.255.255.255`(BROADCAST) | 接收全广播(用于集群发现) |

这种"三端点"设计让本机进程(`epLocal_`)与跨机通信(`ep_`、`epBroadcast_`)分离,避免本机消息走广播(性能差),同时让广播消息有独立通道。

#### 3.1.2 核心数据结构

##### ProcessInfo

```cpp
// server/tools/bwmachined/common_machine_guard.hpp  L170-183
struct ProcessInfo
{
    ProcessInfo() { starttime = 0; }
    HighResStat cpu, mem;       // CPU 时间与内存使用量(双缓冲,可计算 delta)
    int affinity;               // 上次所在 CPU
    ProcessStatsMessage m;      // 进程的可序列化信息(PID、UID、port、name 等)
    unsigned long int starttime;  // 进程启动时间(自系统启动起,jiffies)
    void init( const ProcessMessage &pm );  // 平台特定的初始化
};
```

`HighResStat` 是双缓冲模板,通过 `delta()` 计算两次采样差值(用于 CPU/内存增长率)。

##### SystemInfo

```cpp
// server/tools/bwmachined/common_machine_guard.hpp  L156-168
struct SystemInfo
{
    uint nCpus, cpuSpeed;
    BW::vector< MaxStat > cpu;       // 每 CPU 的负载
    MaxStat iowait;                  // IO 等待时间
    MaxStat mem;                     // 系统内存
    HighResStat packTotIn, packDropIn, packTotOut, packDropOut;  // 包统计
    BW::vector< struct InterfaceInfo > ifInfo;  // 网络接口
    WholeMachineMessage m;           // 低精度机器消息(可发送)
    HighPrecisionMachineMessage hpm;  // 高精度机器消息
};
```

`m` 与 `hpm` 都是可序列化的消息,前者用 uint8 存储统计(向后兼容),后者用 uint32(更高精度)。

##### Listeners

```cpp
// server/tools/bwmachined/listeners.hpp  L12-42
class Listeners
{
private:
    class Member
    {
    public:
        Member( const ListenerMessage & lm, u_int32_t addr ) :
            lm_( lm ), addr_( addr ) {}
        ListenerMessage lm_;     // 监听器消息(含 preAddr/postAddr)
        u_int32_t addr_;          // 监听器所在机器的 IP
    };

    typedef BW::vector< Member > Members;
    Members members_;
    const ServerPlatform & serverPlatform_;
};
```

`Listeners` 是 `Member` 的 vector,每个 `Member` 描述一个监听器:它的 `lm_` 包含触发时要发送的 `preAddr_` + Address + `postAddr_` 数据,`addr_` 是监听器所在机器的 IP。

### 3.2 Cluster 类

`Cluster` 维护集群视图,在 `cluster.hpp`/`cluster.cpp`:

```cpp
// server/tools/bwmachined/cluster.hpp  L15-109
class Cluster
{
public:
    Cluster( BWMachined &machined );
    void chooseBuddy();
    typedef BW::set< uint32 > Addresses;

protected:
    class ClusterTimeoutHandler : public TimerHandler { ... };
    class FloodTriggerHandler : public ClusterTimeoutHandler { ... };
    class FloodReplyHandler : public ClusterTimeoutHandler { ... };
    class BirthReplyHandler : public ClusterTimeoutHandler { ... };

    BWMachined &machined_;
    Addresses machines_;         // 已知的所有 bwmachined IP
    uint32 ownAddr_;              // 本机 IP
    uint32 buddyAddr_;            // buddy IP(环状拓扑中的下一个)
    FloodTriggerHandler floodTriggerHandler_;
    FloodReplyHandler *pFloodReplyHandler_;
    BirthReplyHandler birthHandler_;
};
```

Cluster 的核心是 `machines_` 集合,通过 `chooseBuddy()` 计算"下一个"buddy,组成环状拓扑。

### 3.3 Listeners 类

详见[第十章](#十listeners-出生死亡通知)。

### 3.4 UserMap 类

详见[第十五章](#十五用户与权限)。

### 3.5 ServerPlatform 抽象

详见[第十四章](#十四平台抽象层)。

---

## 四、MachineGuard 协议深度剖析

`bwmachined` 与外部世界的通信走 **MachineGuard 协议**(简称 MGM),定义在 `lib/network/machine_guard.hpp`。MGM 基于 UDP,默认端口 `PORT_MACHINED`(19289)。

### 4.1 MGMPacket 包结构

```cpp
// lib/network/machine_guard.hpp  L41-98
class MGMPacket
{
public:
    static const int MAX_SIZE = 32768;       // 单包最大 32KB

    enum Flags {
        PACKET_STAGGER_REPLIES = 0x1         // 抑制广播风暴
    };

    typedef BW::vector< MachineGuardMessage* > MGMs;

    uint8   flags_;       // 包标志(如 PACKET_STAGGER_REPLIES)
    uint32  buddy_;      // buddy 地址(环状拓扑用)
    MGMs    messages_;   // 包内消息列表(一个包可含多条 MGM)
protected:
    BW::vector< bool > delInfo_;             // 是否在析构时 delete 各消息
    bool dontDeleteMessages_;
    bool hasError_;

public:
    static void setBuddy( uint32 addr );      // 设置全局 buddy(写入所有回复)
    static uint32 s_buddy_;
};
```

**关键设计**:
- **多消息复用**:一个 UDP 包可携带多条 `MachineGuardMessage`,降低 UDP 包头开销。
- **大小限制**:32KB,超过则 `write()` 失败。
- **buddy 字段**:用于环状拓扑,让回复消息带上"我应该转发给谁"的信息。
- **STAGGER_REPLIES 标志**:见 4.3。

### 4.2 消息类型枚举

```cpp
// lib/network/machine_guard.hpp  L124-145
class MachineGuardMessage
{
public:
    enum Message
    {
        // tool/server -> machined messages
        WHOLE_MACHINE_MESSAGE = 1,             // 查询机器统计(低精度)
        PROCESS_MESSAGE = 2,                    // 进程注册/注销/通知
        PROCESS_STATS_MESSAGE = 3,              // 查询进程统计
        LISTENER_MESSAGE = 4,                   // 注册 birth/death 监听器
        CREATE_MESSAGE = 5,                     // 创建进程
        SIGNAL_MESSAGE = 6,                     // 发送信号
        TAGS_MESSAGE = 7,                        // 查询 tags
        USER_MESSAGE = 8,                        // 查询用户信息
        PID_MESSAGE = 9,                         // 查询 PID 是否存在
        RESET_MESSAGE = 10,                      // 重置 tags 与用户映射
        ERROR_MESSAGE = 11,                      // 错误消息
        QUERY_INTERFACE_MESSAGE = 12,           // 查询接口地址
        CREATE_WITH_ARGS_MESSAGE = 13,          // 带参数的创建进程
        HIGH_PRECISION_MACHINE_MESSAGE = 14,     // 高精度机器统计
        MACHINE_PLATFORM_MESSAGE = 15,           // 机器平台信息

        // machined -> machined messages
        MACHINED_ANNOUNCE_MESSAGE = 64,         // bwmachined 间通告
    };

    enum Flags
    {
        MESSAGE_DIRECTION_OUTGOING = 0x1,       // 出向(回复)
        MESSAGE_NOT_UNDERSTOOD = 0x2            // 消息类型不被识别
    };

    uint8   message_;       // 消息类型枚举
    uint8   flags_;          // 标志位
    typedef uint16 UserId;
private:
    uint16  seq_;            // 序列号(用于回复匹配)
};
```

15 个工具/服务器消息 + 1 个 machined 间消息,涵盖所有 bwmachined 操作。

### 4.3 PACKET_STAGGER_REPLIES 抑制广播风暴

当 bwmachined 收到一个带有 `PACKET_STAGGER_REPLIES` 标志的广播包时,它**不会立即回复**,而是把回复推迟一个随机时间(0 ~ `maxPacketDelayMillisec_`,默认 100ms):

```cpp
// server/tools/bwmachined/bwmachined.cpp  L885-923
void BWMachined::readPacket( Endpoint & ep, TimeQueue64::TimeStamp & tickTime )
{
    static char streamBuf[ MGMPacket::MAX_SIZE ];
    sockaddr_in sin;
    int len = ep.recvfrom( &streamBuf, sizeof( streamBuf ), sin );
    if (len == -1) { syslog( LOG_ERR, "recvfrom got an error: %s\n", strerror( errno ) ); return; }

    MemoryIStream is( streamBuf, len );
    MGMPacket *pPacket = new MGMPacket( is );

    if (is.error()) { syslog( LOG_ERR, "Dropping packet with bogus message" ); bw_safe_delete( pPacket ); return; }

    // Schedule broadcast packets for later
    if (pPacket->shouldStaggerReply())
    {
        callbacks_.add( tickTime + (rand() % maxPacketDelayMillisec_),
                        0, &packetTimeoutHandler_,
                        new IncomingPacket( *this, pPacket, sin ),
                        "IncomingPacket" );
        return;
    }

    this->handlePacket( ep, sin, *pPacket );
    bw_safe_delete( pPacket );
}
```

**作用**:当一个机器广播 `WholeMachineMessage` 查询时,所有机器都会回复。如果同时回复,会形成"广播风暴"(N 个机器同时回 N 个包,可能丢包或拥塞)。通过让每台机器在 0~100ms 内随机延迟回复,把回复分散开,避免风暴。

`IncomingPacket` 类(`incoming_packet.cpp`)就是用于延迟处理的包装:

```cpp
// server/tools/bwmachined/incoming_packet.cpp  L41-46
void IncomingPacket::handle()
{
    MemoryOStream os;
    machined_.handlePacket( machined_.endpoint(), sin_, *pPacket_ );
}
```

定时器到期后,`PacketTimeoutHandler::handleTimeout` 调用 `pIncomingPacket->handle()`,实际处理该包。

### 4.4 ReplyHandler 回调模型

`MachineGuardMessage::ReplyHandler` 是一个虚基类,调用方可继承它来处理回复:

```cpp
// lib/network/machine_guard.hpp  L203-245
class ReplyHandler
{
public:
    bool handle( MachineGuardMessage &mgm, uint32 addr );
    virtual bool onUnhandledMsg( MachineGuardMessage &mgm, uint32 addr );
    virtual bool onHighPrecisionMachineMessage( HighPrecisionMachineMessage &hpmm, uint32 addr );
    virtual bool onWholeMachineMessage( WholeMachineMessage &wmm, uint32 addr );
    virtual bool onProcessMessage( ProcessMessage &pm, uint32 addr );
    virtual bool onProcessStatsMessage( ProcessStatsMessage &psm, uint32 addr );
    virtual bool onListenerMessage( ListenerMessage &lm, uint32 addr );
    virtual bool onCreateMessage( CreateMessage &cm, uint32 addr );
    virtual bool onSignalMessage( SignalMessage &sm, uint32 addr );
    virtual bool onTagsMessage( TagsMessage &tm, uint32 addr );
    virtual bool onUserMessage( UserMessage &um, uint32 addr );
    virtual bool onPidMessage( PidMessage &pm, uint32 addr );
    virtual bool onResetMessage( ResetMessage &rm, uint32 addr );
    virtual bool onErrorMessage( ErrorMessage &em, uint32 addr );
    virtual bool onMachinedAnnounceMessage( MachinedAnnounceMessage &mam, uint32 addr );
    virtual bool onQueryInterfaceMessage( QueryInterfaceMessage &wmm, uint32 addr );
    virtual bool onCreateWithArgsMessage( CreateWithArgsMessage &cwam, uint32 addr );
    virtual bool onMachinePlatformMessage( MachinePlatformMessage &mpm, uint32 addr );
};
```

**回调契约**:
- 每个 `on*Message` 返回 `true` 表示继续处理后续回复,`false` 表示终止。
- `onUnhandledMsg` 处理未识别的消息类型。

Reviver 的 `TagsHandler` 就是 `ReplyHandler` 的子类,处理 `TagsMessage` 回复。

### 4.5 sendAndRecv 同步调用

`MachineGuardMessage::sendAndRecv` 是同步发送并等待回复的便捷方法:

```cpp
// lib/network/machine_guard.hpp  L247-254
Mercury::Reason sendAndRecv( Endpoint &ep, uint32 destaddr,
    ReplyHandler *pHandler = NULL );

Mercury::Reason sendAndRecv( uint32 srcip, uint32 destaddr,
    ReplyHandler *pHandler = NULL );

Mercury::Reason sendAndRecvFromEndpointAddr( Endpoint & ep, uint32 destaddr,
    ReplyHandler * pHandler = NULL );
```

`sendAndRecv` 内部会:
1. 创建一个临时 Endpoint 绑定到 `srcip`(若为 0 则任选)。
2. 序列化本消息到 UDP 包并发送到 `destaddr:PORT_MACHINED`。
3. 阻塞 select 等待回复(超时由 `Mercury::REASON_TIMER_EXPIRED` 表示)。
4. 收到回复后调用 `pHandler->handle()` 分发。

Reviver 大量使用 `sendAndRecv` 进行同步查询(`queryMachinedSettings`、`findInterface`、`CreateMessage`)。

### 4.6 版本协商

bwmachined 协议有版本号,定义在 `common_machine_guard.hpp`:

```cpp
// server/tools/bwmachined/common_machine_guard.hpp  L21-74
// Version 1-50 的演进历史注释
#define BWMACHINED_VERSION 50
```

50 个版本的演进涵盖了:listener 通知地址、tags 支持、变长消息、broadcast 容错、`CreateWithArgsMessage`、高精度统计、`MachinePlatformMessage`、用户映射等。

当 bwmachined 收到无法识别的消息类型时,会设置 `MESSAGE_NOT_UNDERSTOOD` 标志并回复:

```cpp
// server/tools/bwmachined/bwmachined.cpp  L1156-1162
if (mgm.flags_ & mgm.MESSAGE_NOT_UNDERSTOOD)
{
    syslog( LOG_ERR, "Received unknown message: %s", mgm.c_str() );
    mgm.outgoing( true );
    replies.append( mgm );
    return true;
}
```

这实现了**前向兼容**:新版客户端发送旧版 bwmachined 不认识的消息时,旧版 bwmachined 不会崩溃,而是回带 `MESSAGE_NOT_UNDERSTOOD` 标志,客户端可据此判断。

`main.cpp` 中 `-v` 参数可查看版本:

```cpp
// server/tools/bwmachined/main.cpp  L55-63
else if ((strcmp( argv[i], "-v" ) == 0) || (strcmp( argv[i], "--version" ) == 0))
{
    const BW::string & bwversion = BWVersion::versionString();
    printf( "BWMachined (BigWorld %s %s. %s %s)\nProtocol version %d\n",
        bwversion.c_str(), MF_CONFIG, __TIME__, __DATE__,
        BWMACHINED_VERSION );
    return EXIT_SUCCESS;
}
```

---

## 五、MachineGuard 消息类型详解

### 5.1 CreateMessage:创建进程

`CreateMessage` 是 Reviver 触发进程恢复的核心消息:

```cpp
// lib/network/machine_guard.hpp  L634-662
class CreateMessage : public MachineGuardMessage
{
public:
    BW::string      name_;      //!< Name of executable to start
    BW::string      config_;    //!< Hybrid, Debug etc
    UserId          uid_;       //!< UserID to start the process as
    uint8           recover_;   //!< Set to true to start with -recover
    uint32          fwdIp_;     //!< IP to forward output to
    uint16          fwdPort_;   //!< Port to forward output to

    CreateMessage( Message messageType = CREATE_MESSAGE ) :
                    MachineGuardMessage( messageType )
    {
    }
};
```

| 字段 | 类型 | 含义 | Reviver 设置 |
|------|------|------|-------------|
| `name_` | `BW::string` | 可执行文件名(如 `cellappmgr`) | `createParam_`(如 `"cellappmgr"`) |
| `config_` | `BW::string` | 编译配置 | `BW_COMPILE_TIME_CONFIG` 宏 |
| `uid_` | `UserId` | 启动身份 | `getUserId()`(当前用户) |
| `recover_` | `uint8` | 是否带 `-recover` 启动 | 固定为 `1` |
| `fwdIp_` | `uint32` | 输出转发 IP | 默认 0(不转发) |
| `fwdPort_` | `uint16` | 输出转发端口 | 默认 0 |

### 5.2 CreateWithArgsMessage:带参数创建

```cpp
// lib/network/machine_guard.hpp  L664-689
class CreateWithArgsMessage : public CreateMessage
{
public:
    typedef BW::vector< BW::string > Args;
    Args    args_;   //!< Arguments to pass to the command.

    CreateWithArgsMessage() : CreateMessage( CREATE_WITH_ARGS_MESSAGE ) {}
};
```

`CreateWithArgsMessage` 是 `CreateMessage` 的子类,允许调用方传任意命令行参数。与 `CreateMessage` 的区别:
- `CreateMessage` 自动加 `-machined`、`-recover`、`-forward`、`--res` 参数。
- `CreateWithArgsMessage` 只自动加 `--res`,其他参数完全由调用方控制。

### 5.3 SignalMessage:发送信号

```cpp
// lib/network/machine_guard.hpp  L696-717
class SignalMessage : public ProcessMessage
{
public:
    uint8       signal_;

    SignalMessage() { message_ = MachineGuardMessage::SIGNAL_MESSAGE; }

    void setControlledShutdown() { signal_ = SIGUSR1; }
    void setKill() { signal_ = SIGINT; }
    void setHardKill() { signal_ = SIGQUIT; }
};
```

`SignalMessage` 继承自 `ProcessMessage`,因此携带进程匹配信息(`pid_`、`uid_`、`port_`、`name_` 等)。bwmachined 收到后遍历 `procs_`,对每个匹配的进程调用 `kill(pid, signal_)`。

三种预设信号:
- `SIGUSR1`(10):controlled shutdown,优雅关闭。
- `SIGINT`(2):kill,正常关闭。
- `SIGQUIT`(3):hard kill,强制关闭。

### 5.4 ListenerMessage:监听器消息

```cpp
// lib/network/machine_guard.hpp  L604-632
class ListenerMessage : public ProcessMessage
{
public:
    enum Type
    {
        ADD_BIRTH_LISTENER = 0,
        ADD_DEATH_LISTENER = 1
    };

    static const uint16 ANY_UID = 0xffff;   // 任意 UID(用于日志守护)

    BW::string      preAddr_;
    BW::string      postAddr_;
};
```

`ListenerMessage` 是注册 birth/death 监听器的消息。`preAddr_` 与 `postAddr_` 是关键:**监听器注册时,把要触发的消息(包括 Mercury 头与负载)拆成 "地址前 + Address 占位 + 地址后" 三段**,bwmachined 触发时填入实际地址再发送。这种设计让 bwmachined 不需要理解 Mercury 协议,只做"模板替换"即可。

### 5.5 TagsMessage:标签查询

```cpp
// lib/network/machine_guard.hpp  L731-747
class TagsMessage : public MachineGuardMessage
{
public:
    Tags    tags_;
    uint8   exists_;     //!< Flag to indicate if a category exists at all
};
```

查询语义:
- 发送时 `tags_` 含 1 个元素(查询的 tag 名)。空字符串表示查询所有 tag 类别。
- 回复时 `tags_` 是该类别下的所有值,`exists_` 表示该类别是否存在。

Reviver 通过 `TagsMessage` 查询 `Components` tag,据此启用/禁用对应的 ComponentReviver。

### 5.6 Tags 类型

```cpp
// lib/network/machine_guard.hpp  L723
typedef BW::vector< BW::string > Tags;
```

`Tags` 就是 `BW::vector<BW::string>`,简单的字符串列表。

### 5.7 QueryTagsMessage / GetTags

BigWorld 没有独立的 `QueryTagsMessage` 或 `GetTags` 类——所有 tag 操作都通过 `TagsMessage` 完成,根据 `tags_` 字段的内容区分"查询"与"回复"。

### 5.8 MachinedAnnounceMessage:机器通告

```cpp
// lib/network/machine_guard.hpp  L877-904
class MachinedAnnounceMessage : public MachineGuardMessage
{
public:
    enum Type
    {
        ANNOUNCE_BIRTH = 0,     // 新 bwmachined 上线
        ANNOUNCE_DEATH = 1,     // 某 bwmachined 离线
        ANNOUNCE_EXISTS = 2     // 确认某 bwmachined 存在
    };

    uint8 type_;
    union {
        uint32 count_;          // Birth 回复中告知集群大小
        uint32 addr_;           // Death/Exists 中告知机器 IP
    };
};
```

这是 bwmachined 之间的消息,用于维护集群 ring 拓扑(详见[第十二章](#十二cluster-集群视图))。

### 5.9 其他消息

| 消息 | 用途 |
|------|------|
| `WholeMachineMessage` | 低精度机器统计(CPU/内存/网络,8 位) |
| `HighPrecisionMachineMessage` | 高精度机器统计(32 位) |
| `ProcessMessage` | 进程注册/注销/通知(REGISTER/DEREGISTER/NOTIFY_BIRTH/NOTIFY_DEATH) |
| `ProcessStatsMessage` | 进程统计查询(CPU/内存) |
| `UserMessage` | 用户信息查询(UID、用户名、mfroot、bwrespath、coredumps) |
| `PidMessage` | 查询 PID 是否在本机存在 |
| `ResetMessage` | 重置 tags 与用户映射(重新读取配置) |
| `ErrorMessage` | bwmachined 向客户端报告错误 |
| `QueryInterfaceMessage` | 查询本机内部接口地址 |
| `MachinePlatformMessage` | 查询机器平台信息(发行版、内核版本) |
| `UnknownMessage` | 未识别消息的回显(带 `MESSAGE_NOT_UNDERSTOOD` 标志) |

---

## 六、bwmachined 主程序流程

### 6.1 main.cpp 八步启动

`main.cpp` 的 `BIGWORLD_MAIN_NO_RESMGR` 宏展开后是 main 函数,完成以下八步:

```cpp
// server/tools/bwmachined/main.cpp  L27-128
int BIGWORLD_MAIN_NO_RESMGR( int argc, char * argv[] )
{
    // 步骤 1:解析命令行
    bool daemon = true;
    BW::string pidPath = "";
    for (int i = 1; i < argc; ++i) {
        // -f/--foreground: 不作为 daemon
        // -p/--pid <path>: PID 文件路径
        // -v/--version: 打印版本
        // --help: 帮助
    }

    // 步骤 2:打开 syslog
    openlog( argv[0], 0, LOG_DAEMON );

    // 步骤 3:创建 BWMachined 实例(在 daemon 化之前,便于报错)
    BWMachined machined;

    if (daemon && !pidPath.empty()) {
        machined.setPidPath( pidPath );
    }

    // 步骤 4:转为 daemon(若需要)
    initProcessState( daemon );
    srand( (int)timestamp() );

    // 步骤 5:设置 core 文件大小无限
    rlimit rlimitData;
    rlimitData.rlim_cur = RLIM_INFINITY;
    rlimitData.rlim_max = RLIM_INFINITY;
    if (bw_prlimit( 0, RLIMIT_CORE, &rlimitData, NULL ) == -1) {
        syslog( LOG_ERR, "Unable to set core file privileges: %s\n", strerror( errno ) );
    }

    // 步骤 6:检查 socket 缓冲区大小
    checkSocketBufferSizes();

    // 步骤 7:提升文件描述符硬限制(子进程继承)
    if (!raiseFileDescriptorHardLimit( desiredMaximumFileDescriptorHardLimit )) {
        if (getuid() == 0) return EXIT_FAILURE;
        // 非 root 用户失败仅打印警告
    }

    // 步骤 8:进入主循环
    if (BWMachined::pInstance()) {
        return machined.run();
    } else {
        return EXIT_FAILURE;
    }
}
```

| 步骤 | 行号 | 动作 | 失败后果 |
|------|------|------|---------|
| 1 | L31-76 | 解析 `-f`/`-p`/`-v`/`--help` | 无效参数返回 EXIT_FAILURE |
| 2 | L79 | `openlog` 打开日志 | - |
| 3 | L83 | `BWMachined machined` 构造 | 失败 exit(EXIT_FAILURE)(构造函数内) |
| 4 | L91 | `initProcessState(daemon)` daemon 化 | - |
| 5 | L94-102 | `bw_prlimit` 设置 core 无限 | 仅日志警告 |
| 6 | L105 | `checkSocketBufferSizes` 检查缓冲区 | 仅日志警告 |
| 7 | L109-118 | `raiseFileDescriptorHardLimit` 提升 fd 限制 | root 失败 EXIT_FAILURE,非 root 警告 |
| 8 | L120-127 | `machined.run()` 主循环 | - |

### 6.2 BWMachined 构造函数六步

```cpp
// server/tools/bwmachined/bwmachined.cpp  L60-139
BWMachined::BWMachined() :
    pidPath_(),
    packetTimeoutHandler_(),
    broadcastAddr_( 0 ),
    ep_(), epBroadcast_(), epLocal_(),
    cluster_( *this ),
    tags_(),
    timingMethod_( "gettime" ),
    pServerPlatform_( new ServerPlatformLinux ),  // 平台实现
    systemInfo_(),
    procs_(),
    birthListeners_( *pServerPlatform_ ),
    deathListeners_( *pServerPlatform_ ),
    users_(),
    callbacks_(),
    pServerInfo_( new ServerInfo ),
    maxPacketDelayMillisec_( 100 )
{
    syslog( LOG_INFO, "--- BWMachined start ---" );

    // 步骤 1:平台初始化
    if (!pServerPlatform_->isInitialised()) {
        syslog( LOG_CRIT, "Failed to initialise for server platform." );
        exit( EXIT_FAILURE );
    }

    // 步骤 2:刷新用户映射
    users_.flush();

    // 步骤 3:创建三个 Endpoint
    ep_.socket( SOCK_DGRAM );
    epLocal_.socket( SOCK_DGRAM );
    epBroadcast_.socket( SOCK_DGRAM );

    // 步骤 4:读取配置文件(/etc/bwmachined.conf + /etc/bigworld.conf)
    if (!this->readConfigFile()) {
        syslog( LOG_CRIT, "Invalid configuration file" );
        exit( EXIT_FAILURE );
    }

    // 步骤 5:初始化网络接口(绑定三个 Endpoint)
    this->initNetworkInterfaces();

    // 步骤 6:初始化 SystemInfo(主机名、CPU 速度等不变信息)
    const BW::vector<float> & speeds = pServerInfo_->cpuSpeeds();
    if (speeds.size() == 0) {
        syslog( LOG_CRIT, "Unable to obtain any valid processor speed info" );
        exit( EXIT_FAILURE );
    }

    SystemInfo &si = systemInfo_;
    si.nCpus = speeds.size();
    si.cpuSpeed = (int)speeds[0];
    for (uint j=0; j < si.nCpus; j++)
        si.cpu.push_back( MaxStat() );

    si.m.cpuSpeed_ = si.cpuSpeed;
    si.m.setNCpus( si.nCpus );
    si.m.hostname_ = pServerInfo_->serverName();
    si.m.version_ = BWMACHINED_VERSION;
    si.m.outgoing( true );

    si.hpm.cpuSpeed_ = si.cpuSpeed;
    si.hpm.setNCpus( si.nCpus );
    si.hpm.hostname_ = pServerInfo_->serverName();
    si.hpm.version_ = BWMACHINED_VERSION;
    si.hpm.outgoing( true );

    // 强制首次 update 让所有统计可读
    this->updateSystemInfo();

    // 尝试加载之前保存的状态(进程表)
    this->load();

    // 注册 SIGTERM 处理器(用于保存状态)
    signal( SIGTERM, sigterm );
}
```

| 步骤 | 行号 | 动作 |
|------|------|------|
| 1 | L82-86 | 平台初始化(`ServerPlatformLinux`),失败 exit |
| 2 | L88 | `users_.flush()` 加载所有用户的环境配置 |
| 3 | L91-93 | 创建三个 SOCK_DGRAM socket |
| 4 | L95-99 | `readConfigFile` 读取 `/etc/bwmachined.conf` 与 `/etc/bigworld.conf` |
| 5 | L101 | `initNetworkInterfaces` 绑定三个端口 |
| 6 | L104-138 | 初始化 SystemInfo、首次 update、加载持久化状态、注册 SIGTERM |

### 6.3 三端点与广播接口发现

`initNetworkInterfaces` 负责绑定三个端点:

```cpp
// server/tools/bwmachined/bwmachined.cpp  L189-230
void BWMachined::initNetworkInterfaces()
{
    // 1) 确定广播接口
    if (broadcastAddr_ == 0 && !this->findBroadcastInterface()) {
        syslog( LOG_CRIT, "Failed to determine default broadcast interface. ..." );
        exit( EXIT_FAILURE );
    }

    // 2) 绑定主端点到 broadcastAddr_
    if (!ep_.good() || ep_.bind( htons( PORT_MACHINED ), broadcastAddr_ ) == -1) {
        syslog( LOG_CRIT, "Failed to bind socket to '%s'. %s.", ... );
        exit( EXIT_FAILURE );
    }
    ep_.setbroadcast( true );

    // 3) 绑定本地端点到 127.0.0.1
    if (!epLocal_.good() || epLocal_.bind( htons( PORT_MACHINED ), LOCALHOST ) == -1) {
        syslog( LOG_CRIT, "Failed to bind socket to (lo). %s.", strerror(errno) );
        exit( EXIT_FAILURE );
    }

    // 4) 绑定广播端点到 255.255.255.255
    if (!epBroadcast_.good() || epBroadcast_.bind( htons( PORT_MACHINED ), BROADCAST ) == -1) {
        syslog( LOG_CRIT, "Failed to bind socket to '%s'. %s.", ... );
        exit( EXIT_FAILURE );
    }

    cluster_.ownAddr_ = broadcastAddr_;
}
```

#### 广播接口发现

`findBroadcastInterface` 通过"自播自收"确定本机的广播接口:

```cpp
// server/tools/bwmachined/bwmachined.cpp  L237-334
bool BWMachined::findBroadcastInterface()
{
    BW::map< u_int32_t, BW::string > interfaces;
    Endpoint epListen;
    // ... 创建并绑定到 PORT_BROADCAST_DISCOVERY ...

    // 1) 枚举所有网络接口
    if (!epListen.getInterfaces( interfaces )) { return false; }

    // 2) 发送广播 QueryInterfaceMessage
    QueryInterfaceMessage qim;
    qim.sendto( epListen, htons( PORT_BROADCAST_DISCOVERY ), BROADCAST, MGMPacket::PACKET_STAGGER_REPLIES );

    // 3) 等待 1 秒,接收自己发出的广播
    tv.tv_sec = 1; tv.tv_usec = 0;
    while (1) {
        FD_ZERO( &fds ); FD_SET( epListen.fileno(), &fds );
        int selgot = select( (epListen.fileno())+1, &fds, NULL, NULL, &tv );
        // ... 接收包 ...
        // 4) 检查接收到的源 IP 是否在本机接口列表中
        iter = interfaces.find( (u_int32_t &)sin.sin_addr.s_addr );
        if (iter != interfaces.end()) {
            // 找到!这就是本机的广播接口
            broadcastAddr_ = sin.sin_addr.s_addr;
            break;
        }
    }
    return true;
}
```

**为什么需要"自播自收"**:一台机器可能有多个网卡(eth0、eth1、lo、docker0...),`getinterfaces` 列出所有,但只有"能收到自己广播"的那个才是有效的 BigWorld 通信接口。通过发广播再等回响,bwmachined 自动找到正确的接口。

如果 `internal_interface` 配置项指定了接口,bwmachined 会优先使用配置(在 `readConfigFile` 中解析)。

### 6.4 主事件循环(reactor 模式 + select + TimeQueue64)

```cpp
// server/tools/bwmachined/bwmachined.cpp  L761-879
int BWMachined::run()
{
    // 1) 生成基础时间戳
    this->timeStamp();

    // 2) 启动 Cluster 的 birth 与 flood 触发定时器
    cluster_.birthHandler_.addTimer();
    cluster_.floodTriggerHandler_.addTimer();

    // 3) 启动 UpdateHandler(每 1s 触发一次)
    UpdateHandler updateHandler( *this );
    callbacks_.add( this->timeStamp() + UPDATE_INTERVAL,  // UPDATE_INTERVAL = 1000ms
        UPDATE_INTERVAL, &updateHandler, NULL, "UpdateHandler" );

    // 4) 写 PID 文件
    if (!pidPath_.empty()) { /* 写入 mf_getpid() 到 pidPath_ */ }

    // 5) 主循环
    int maxfd = std::max( ep_.fileno(), std::max( epBroadcast_.fileno(), epLocal_.fileno() ) );

    while (g_serverRunning)
    {
        // 5.1) 处理定时器回调
        TimeQueue64::TimeStamp tickTime = this->timeStamp();
        callbacks_.process( tickTime );

        // 5.2) 计算下一个定时器的等待时间
        TimeQueue64::TimeStamp ttn = callbacks_.nextExp( tickTime );
        timeStampToTV( ttn, tv );

        // 5.3) select 等待三端点 + 平台特定 FD
        FD_ZERO( &fds );
        FD_SET( ep_.fileno(), &fds );
        FD_SET( epBroadcast_.fileno(), &fds );
        FD_SET( epLocal_.fileno(), &fds );
        int osmaxfd = getInterestingFds( &fds, NULL, NULL );  // 平台特定 FD(子进程管道)

        int selgot = select( std::max( maxfd+1, osmaxfd+1 ), &fds, NULL, NULL, &tv );

        if (selgot == 0) continue;     // 超时,无数据
        if (selgot == -1) {
            if (errno != EINTR) { exitCode = EXIT_FAILURE; break; }
            continue;
        }

        // 5.4) 处理就绪的端点
        if (FD_ISSET( ep_.fileno(), &fds )) this->readPacket( ep_, tickTime );
        if (FD_ISSET( epLocal_.fileno(), &fds )) this->readPacket( epLocal_, tickTime );
        if (FD_ISSET( epBroadcast_.fileno(), &fds )) this->readPacket( epBroadcast_, tickTime );

        // 5.5) 处理平台特定 FD(子进程状态管道)
        handleInterestingFds( &fds, NULL, NULL );
    }

    callbacks_.clear();
    return exitCode;
}
```

#### 事件循环特点

1. **Reactor 模式**:单线程,通过 select 多路复用三端点 + 子进程状态管道。
2. **TimeQueue64**:所有定时器(UpdateHandler、Cluster birth/flood、PacketTimeoutHandler、子进程超时)统一管理。
3. **nextExp 计算超时**:select 的超时设为下一个定时器到期时间,避免忙等。
4. **EINTR 容忍**:select 被信号中断时 continue,不退出。
5. **g_serverRunning 全局标志**:SIGTERM 时 `sigterm()` 把它设为 false,主循环退出。

#### UpdateHandler 周期任务

```cpp
// server/tools/bwmachined/bwmachined.cpp  L1026-1049
void BWMachined::update()
{
    // 1) 更新机器统计(CPU、内存、网络)
    this->updateSystemInfo();

    // 2) 检查所有注册的进程,清理已死的
    for (unsigned int i=0; i < procs_.size(); i++) {
        ProcessInfo &pi = procs_[ i ];
        if (!updateProcessStats( pi ) && errno == ENOENT) {
            syslog( LOG_ERR, "%s (uid:%d) died without deregistering!\n", ... );
            removeRegisteredProc( i-- );   // 移除并广播 death
        }
    }

    // 3) 检查死监听器(注册了 listener 但 listener 进程已死)
    birthListeners_.checkListeners();
    deathListeners_.checkListeners();

    // 4) 清理僵尸子进程
    waitpid( -1, NULL, WNOHANG );
}
```

`update()` 每秒触发一次,完成所有"周期性维护"工作。

---

## 七、消息分发机制

### 7.1 handleMessage 15 个 case

`BWMachined::handleMessage` 是消息分发的核心,通过 switch 处理 15 种消息:

```cpp
// server/tools/bwmachined/bwmachined.cpp  L1150-1718
bool BWMachined::handleMessage( Endpoint & ep, sockaddr_in & sin,
    MachineGuardMessage & mgm, MGMPacket & replies )
{
    // 0) 检查 MESSAGE_NOT_UNDERSTOOD 标志
    if (mgm.flags_ & mgm.MESSAGE_NOT_UNDERSTOOD) {
        syslog( LOG_ERR, "Received unknown message: %s", mgm.c_str() );
        mgm.outgoing( true );
        replies.append( mgm );
        return true;
    }

    switch (mgm.message_)
    {
    case MachineGuardMessage::LISTENER_MESSAGE:               // case 1
        // 注册 birth/death 监听器
        break;

    case MachineGuardMessage::WHOLE_MACHINE_MESSAGE:         // case 2
        // 回复机器统计(低精度)或处理 flood 回复
        break;

    case MachineGuardMessage::HIGH_PRECISION_MACHINE_MESSAGE: // case 3
        // 同上,高精度
        break;

    case MachineGuardMessage::MACHINE_PLATFORM_MESSAGE:      // case 4
        // 回复平台信息
        break;

    case MachineGuardMessage::PROCESS_MESSAGE:                // case 5
        // 处理 REGISTER/DEREGISTER/NOTIFY_BIRTH/NOTIFY_DEATH
        break;

    case MachineGuardMessage::PROCESS_STATS_MESSAGE:         // case 6
        // 查询进程统计
        break;

    case MachineGuardMessage::CREATE_MESSAGE:                // case 7
    case MachineGuardMessage::CREATE_WITH_ARGS_MESSAGE:
        return this->handleCreateMessage( ep, sin, mgm, replies );

    case MachineGuardMessage::SIGNAL_MESSAGE:                // case 8
        // 向进程发送信号
        break;

    case MachineGuardMessage::TAGS_MESSAGE:                  // case 9
        // 查询 tags
        break;

    case MachineGuardMessage::USER_MESSAGE:                 // case 10
        // 查询用户信息
        break;

    case MachineGuardMessage::PID_MESSAGE:                  // case 11
        // 查询 PID 是否存在
        break;

    case MachineGuardMessage::RESET_MESSAGE:                // case 12
        // 重置 tags 与用户映射
        break;

    case MachineGuardMessage::MACHINED_ANNOUNCE_MESSAGE:    // case 13
        // 处理 bwmachined 间通告
        break;

    case MachineGuardMessage::QUERY_INTERFACE_MESSAGE:      // case 14
        // 回复内部接口地址
        break;

    default:
        syslog( LOG_ERR, "Unknown message (%d) not marked as MESSAGE_NOT_UNDERSTOOD!!!", mgm.message_ );
        return false;
    }
    return false;
}
```

15 个 case 覆盖了 bwmachined 的所有功能。每个 case 处理完后,把回复 `replies.append(...)` 到 `MGMPacket &replies`,由 `handlePacket` 统一发回。

### 7.2 CreateMessage 处理流程

```cpp
// server/tools/bwmachined/bwmachined.cpp  L1725-1929
bool BWMachined::handleCreateMessage( Endpoint &ep, sockaddr_in &sin,
    MachineGuardMessage &mgm, MGMPacket &replies )
{
    CreateMessage &cm = static_cast< CreateMessage& >( mgm );
    syslog( LOG_INFO, "Got message: %s", cm.c_str() );

    // 1) 准备 PidMessageWithDestination(用于异步回复)
    PidMessageWithDestination *pPmwd = new PidMessageWithDestination();
    pPmwd->copySeq( cm );
    pPmwd->outgoing( true );
    pPmwd->target( ep, sin.sin_port, sin.sin_addr.s_addr );

    // 2) 获取/创建用户映射
    UserMessage *pUm = users_.fetch( cm.uid_ );
    if (pUm == NULL) {
        struct passwd *ent = getpwuid( cm.uid_ );
        if (ent == NULL) {
            syslog( LOG_ERR, "UID %d doesn't exist on this system, not starting %s", ... );
            pPmwd->running_ = 0;
            replies.append( *pPmwd, true );
            return true;
        }
        pUm = users_.add( ent );
    }

    // 3) 刷新用户环境(从 ~/.bwmachined.conf 读取 mfroot/bwrespath)
    if (!users_.getEnv( *pUm )) {
        syslog( LOG_ERR, "Couldn't get env for user %s, not starting %s", ... );
        pPmwd->running_ = 0;
        replies.append( *pPmwd, true );
        return true;
    }

    // 4) 校验 config_(必须 Hybrid 或 Debug)
    const char *pConfig = cm.config_.c_str();
    if ((bw_stricmp( BW_CONFIG_HYBRID.c_str(), pConfig ) != 0) &&
        (bw_stricmp( BW_CONFIG_DEBUG.c_str(),  pConfig ) != 0)) {
        syslog( LOG_ERR, "Rejected process start request for user %s for invalid configuration '%s'", ... );
        pPmwd->running_ = 0;
        replies.append( *pPmwd, true );
        return true;
    }

    // 5) 安全检查:禁止 .. 与 _helpers 路径
    if (cm.name_.find( ".." ) != BW::string::npos ||
        cm.config_.find( ".." ) != BW::string::npos) {
        syslog( LOG_ERR, "Illegal '..' in process name or config, not starting %s/%s", ... );
        pPmwd->running_ = 0;
        replies.append( *pPmwd, true );
        return true;
    }
    if (cm.name_.find( "commands/_helpers" ) != BW::string::npos) {
        // 拒绝执行 _helpers 目录下的 setuid 程序
        pPmwd->running_ = 0;
        replies.append( *pPmwd, true );
        return true;
    }

    // 6) 构造 argv
    if (mgm.message_ == MachineGuardMessage::CREATE_MESSAGE) {
        unsigned int argc = 0;
        static const unsigned int MAX_ARGC = 10;
        const char *argv[ MAX_ARGC + NUM_SPARE_ARGS_FOR_STARTPROCESS ];

        argv[ argc++ ] = NULL;            // 占位,由 startProcess 填实际路径
        argv[ argc++ ] = "-machined";      // 标记由 bwmachined 启动
        if (cm.recover_) {
            argv[ argc++ ] = "-recover";   // 恢复模式
        }
        if (cm.fwdIp_ != 0) {
            // 输出转发参数
            argv[ argc++ ] = "-forward";
            argv[ argc++ ] = forwardArg;
        }

        // 7) 查找二进制目录
        BW::string binaryDir;
        if (!pServerPlatform_->findUserBinaryDirForConfig( pUm->mfroot_, cm.config_, binaryDir )) {
            syslog( LOG_ERR, "Not starting process %s for uid %d: unable to determine valid binary location", ... );
            pPmwd->running_ = 0;
            replies.append( *pPmwd, true );
            return true;
        }

        // 8) 调用平台特定的 startProcess
        if (startProcess( binaryDir.c_str(), pUm->bwrespath_.c_str(), binaryDir.c_str(),
            cm.name_.c_str(), pUm->uid_, pUm->gid_, pUm->home_.c_str(),
            argc, argv, *this, pPmwd )) {
            replies.append( *pPmwd, true );
        }
    } else {
        // CREATE_WITH_ARGS_MESSAGE:类似但用 cwam.args_ 作为 argv
        // ...
    }

    return true;
}
```

### 7.3 SignalMessage 处理流程

```cpp
// server/tools/bwmachined/bwmachined.cpp  L1094-1108
void BWMachined::sendSignal (const SignalMessage & sm)
{
    for (uint i=0; i < procs_.size(); i++)
    {
        ProcessInfo &pm = procs_[i];

        if (pm.m.matches( sm ))   // 按 pid/uid/port/name 匹配
        {
            kill( pm.m.pid_, sm.signal_ );   // 发送信号
            syslog( LOG_INFO, "sendSignal: signal = %d pid = %d uid = %d",
                sm.signal_, pm.m.pid_, pm.m.uid_ );
        }
    }
}
```

`matches()` 是按 param 标志位过滤:

```cpp
// lib/network/machine_guard.cpp  L932-948
bool ProcessMessage::matches( const ProcessMessage &query ) const
{
    if (query.param_ & query.PARAM_USE_UID && query.uid_ != uid_) return false;
    if (query.param_ & query.PARAM_USE_PID && query.pid_ != pid_) return false;
    if (query.param_ & query.PARAM_USE_ID && query.id_ != id_) return false;
    if (query.param_ & query.PARAM_USE_NAME && query.name_ != name_) return false;
    if (query.param_ & query.PARAM_USE_CATEGORY && query.category_ != category_) return false;
    if (query.param_ & query.PARAM_USE_PORT && query.port_ != port_) return false;
    return true;
}
```

调用方通过设置 `param_` 标志位决定按哪些字段匹配。例如 `sendSignalViaMachined` 只设置 `PARAM_USE_PORT`,按端口匹配。

---

## 八、进程创建流程详解

### 8.1 CreateMessage 字段

详见[第五章 5.1](#51-createmessage创建进程)。

### 8.2 handleCreateMessage 八步

详见[第七章 7.2](#72-createmessage-处理流程)。这里重点剖析 `startProcess` 的 fork/exec + FD_CLOEXEC 管道技巧。

### 8.3 fork/exec + FD_CLOEXEC 管道技巧

`startProcess` 在 `linux_machine_guard.cpp`:

```cpp
// server/tools/bwmachined/linux_machine_guard.cpp  L328-470
bool startProcess( const char * bwBinaryDir,
    const char * bwResPath,
    const char * config,
    const char * binaryName,
    MachineGuardMessage::UserId uid,
    uint16 gid,
    const char * home,
    int argc,
    const char ** argv,
    BWMachined &machined,
    PidMessageWithDestination * pPmwd )
{
    pid_t childpid;
    int statusPipe[ 2 ];   // { read, write }

    // 步骤 1:创建状态管道
    if (pipe( statusPipe ) == -1) {
        syslog( LOG_ERR, "Failed to create status pipe: %s, aborting exec for %s", ... );
        pPmwd->pid_ = 0;
        pPmwd->running_ = false;
        return true;
    }

    // 步骤 2:fork
    if ((childpid = fork()) == 0)
    {
        // === 子进程 ===
        close( statusPipe[ 0 ] );   // 关闭读端

        // 步骤 2a:把写端设为 close-on-exec
        if (fcntl( statusPipe[ 1 ], F_SETFD, FD_CLOEXEC ) == -1) {
            syslog( LOG_ERR, "Failed to set status pipe to close-on-exec: %s, ...", ... );
            write( statusPipe[ 1 ], &errno, sizeof( errno ) );
            exit( EXIT_FAILURE );
        }

        // 步骤 2b:setgid(必须先于 setuid,否则 setuid 后无权限 setgid)
        if (setgid( gid ) == -1) {
            syslog( LOG_ERR, "Failed to setgid() to %d for user %d, group will be root\n", gid, uid );
        }

        // 步骤 2c:setuid(切换到目标用户)
        if (setuid( uid ) == -1) {
            syslog( LOG_ERR, "Failed to setuid to %d, aborting exec for %s\n", uid, binaryName );
            write( statusPipe[ 1 ], &errno, sizeof( errno ) );
            exit( EXIT_FAILURE );
        }

        // 步骤 2d:构造完整路径并 chdir
        char path[ 512 ];
        strcpy( path, bwBinaryDir );
        strcat( path, "/" );
        chdir( path );   // 切换工作目录
        strncat( path, binaryName, 32 );
        argv[0] = path;   // argv[0] 设为完整路径

        // 步骤 2e:添加 --res 参数(BigWorld 资源路径)
        argv[ argc++ ] = "--res";
        argv[ argc++ ] = bwResPath;

        // 步骤 2f:关闭父进程的 sockets
        machined.closeEndpoints();

        // 步骤 2g:关闭其他子进程的状态管道 FD
        for (PendingProcessMap::const_iterator it = s_pendingProcesses.begin();
            it != s_pendingProcesses.end(); ++it) {
            close( it->first );
        }

        // 步骤 2h:设置环境变量
        putEnvAlloc( "BW_TIMING_METHOD", machined.timingMethod() );
        putEnvAlloc( "HOME", home );

        // 步骤 2i:execv(替换进程映像)
        syslog( LOG_INFO, "UID %d execing '%s'", uid, path );
        argv[ argc ] = NULL;
        int result = execv( path, const_cast< char * const * >( argv ) );

        // 步骤 2j:execv 失败(只有失败才会返回)
        if (result == -1) {
            syslog( LOG_ERR, "Failed to exec '%s': %s\n", path, strerror( errno ) );
        }
        write( statusPipe[ 1 ], &errno, sizeof( errno ) );
        exit( EXIT_FAILURE );
    }
    else if (childpid == -1)
    {
        // fork 失败
        close( statusPipe[ 1 ] );
        close( statusPipe[ 0 ] );
        syslog( LOG_ERR, "Failed to fork: %s, aborting exec for %s", ... );
        pPmwd->pid_ = 0;
        pPmwd->running_ = false;
        return true;
    }
    else
    {
        // === 父进程 ===
        close( statusPipe[ 1 ] );   // 关闭写端

        // 把读端加入 s_pendingProcesses,等待 select 通知
        s_pendingProcesses[ statusPipe[ 0 ] ] =
            std::make_pair( pPmwd, BW::string( binaryName ) );
        pPmwd->pid_ = (uint16)childpid;
        return false;   // false 表示 pPmwd 还未准备好发送,需等子进程状态
    }
}
```

#### FD_CLOEXEC 管道技巧

**关键设计**:子进程把管道写端设为 `FD_CLOEXEC`,然后 `execv`。

- **execv 成功**:内核自动关闭所有 `FD_CLOEXEC` 的 FD,管道写端关闭。父进程的读端 `read()` 返回 0(EOF),表示子进程 exec 成功。
- **execv 失败**:子进程继续运行,显式 `write( statusPipe[1], &errno, sizeof(errno) )` 把错误码写入管道。父进程 `read()` 返回 `sizeof(errno)`,读取错误码。

这样父进程能可靠地知道 exec 是否成功,即使 exec 失败也能拿到 errno。

#### 子进程的环境继承

子进程从父进程继承:
- **环境变量**:`BW_TIMING_METHOD`、`HOME`(通过 `putEnvAlloc` 显式设置)
- **工作目录**:通过 `chdir( path )` 切换到二进制目录
- **资源路径**:通过 `--res` 命令行参数传递 `bwResPath`
- **UID/GID**:通过 `setgid`/`setuid` 切换
- **不继承的**:父进程的 sockets(通过 `closeEndpoints` 关闭)、其他子进程的管道 FD(显式 close)

#### 父进程的异步回复

父进程不立即回复 PidMessage,而是把 `pPmwd` 存入 `s_pendingProcesses`:

```cpp
// server/tools/bwmachined/linux_machine_guard.cpp  L38-41
typedef BW::map< int, std::pair< PidMessageWithDestination *, BW::string > > PendingProcessMap;
static PendingProcessMap s_pendingProcesses;
```

主循环的 `handleInterestingFds` 处理就绪的管道 FD:

```cpp
// server/tools/bwmachined/linux_machine_guard.cpp  L111-159
void handleInterestingFds( fd_set *readfds, fd_set *writefds, fd_set *exceptfds )
{
    PendingProcessMap::iterator it = s_pendingProcesses.begin();
    while (it != s_pendingProcesses.end()) {
        int fd = it->first;
        if (!FD_ISSET( fd, readfds )) { ++it; continue; }

        PidMessageWithDestination * pPmwd = it->second.first;
        const BW::string binaryName = it->second.second;
        s_pendingProcesses.erase( it++ );

        error_t childError;
        int readlen = read( fd, &childError, sizeof( childError ) );
        close( fd );

        if (readlen == 0) {
            // 管道被 exec 关闭,exec 成功
            pPmwd->running_ = true;
        }
        else if (readlen == -1) {
            // 读错误,无法确定子进程状态
            syslog( LOG_ERR, "Error checking child status: %s, assuming exec for %s failed", ... );
            pPmwd->pid_ = 0;
            pPmwd->running_ = false;
        }
        else {
            // 读到 errno,exec 失败
            syslog( LOG_ERR, "Error starting child process %s: %s, check syslog for details", ... );
            pPmwd->pid_ = 0;
            pPmwd->running_ = false;
        }
        pPmwd->sendToTarget();   // 异步发送 PidMessage
        bw_safe_delete( pPmwd );
    }
}
```

**为什么延迟回复**:如果 exec 失败(如二进制不存在),立即回复 `pid_=0`、`running_=false` 让调用方知道。如果立即回复 `pid_=childpid`,调用方会以为进程启动成功,但实际 exec 失败子进程已退出。延迟到 exec 完成(管道关闭)再回复,才能准确反映状态。

### 8.4 注册到 cluster.cpp 维护的进程表

子进程启动后,会通过 `ProcessMessage::REGISTER` 向 bwmachined 注册自己(在 `registerWithMachined` 中):

```cpp
// lib/network/machined_utils.cpp  L50-85
Reason registerWithMachined( const Address & srcAddr,
    const BW::string & name, int id, bool isRegister )
{
    ProcessMessage pm;
    pm.param_ = (isRegister ? pm.REGISTER : pm.DEREGISTER) | pm.PARAM_IS_MSGTYPE;
    pm.category_ = ProcessMessage::SERVER_COMPONENT;
    pm.port_ = srcAddr.port;
    pm.name_ = name;
    pm.id_ = id;
    pm.majorVersion_ = BWVersion::majorNumber();
    pm.minorVersion_ = BWVersion::minorNumber();
    pm.patchVersion_ = BWVersion::patchNumber();

    ProcessMessageHandler pmh;
    const uint32 destAddr = LOCALHOST;
    Reason response = pm.sendAndRecv( srcAddr.ip, destAddr, &pmh );
    return pmh.hasResponded_ ? response : REASON_TIMER_EXPIRED;
}
```

bwmachined 收到后:

```cpp
// server/tools/bwmachined/bwmachined.cpp  L1291-1358
case ProcessMessage::REGISTER:
{
    // 检查是否已注册(同 pid+category+name)
    unsigned int i = 0;
    while (i < procs_.size()) {
        ProcessMessage &psm = procs_[ i ].m;
        if ((pm.pid_ == psm.pid_) && (pm.category_ == psm.category_) && (pm.name_ == psm.name_)) break;
        if (pm.port_ == psm.port_) {  // 端口冲突,移除旧的
            syslog( LOG_ERR, "%d registered on port (%d) that belonged to %d", ... );
            removeRegisteredProc( i );
        } else { ++i; }
    }

    if (i < procs_.size()) {
        // 重复注册
        syslog( LOG_ERR, "Received re-registration for %s\n", pm.c_str() );
    } else {
        procs_.push_back( ProcessInfo() );   // 新增条目
    }

    ProcessInfo &pi = procs_[i];
    pi.m << pm;            // 复制注册信息
    pi.m.outgoing( true );
    for (int j=0; j < 2; j++) updateProcessStats( pi );   // 两次更新确保 delta 可读
    pi.init( pm );         // 平台特定初始化

    broadcastToListeners( pm, pm.NOTIFY_BIRTH );   // 广播 birth
    pm.outgoing( true );
    replies.append( pm );   // 确认回复
    return true;
}
```

注册成功后,bwmachined 广播 `NOTIFY_BIRTH` 给所有注册了 birth listener 的进程。

---

## 九、进程生命周期管理

### 9.1 创建:fork/exec

详见[第八章](#八进程创建流程详解)。

### 9.2 监控:心跳检测、CPU/内存

`update()` 每秒调用 `updateProcessStats` 读取 `/proc/<pid>/stat`:

```cpp
// server/tools/bwmachined/linux_machine_guard.cpp  L190-236
bool updateProcessStats( ProcessInfo &pi )
{
    char pinfoFilename[ 64 ];
    bw_snprintf( pinfoFilename, sizeof( pinfoFilename ), "/proc/%d/stat", (int)pi.m.pid_ );

    FILE *pinfo;
    if ((pinfo = fopen( pinfoFilename, "r" )) == NULL) {
        if (errno != ENOENT) syslog( LOG_ERR, "Couldn't open %s: %s", ... );
        return false;
    }

    unsigned long int utime, stime, vsize, starttime;
    int cpu;
    if (!getProcessTimes( pinfo, &utime, &stime, &vsize, &starttime, &cpu )) {
        syslog( LOG_ERR, "Failed to update process stats for '%s': %s", ... );
        fclose( pinfo );
        return false;
    }

    // starttime 校验,防止 PID 复用
    if ((pi.starttime) && (pi.starttime != starttime)) {
        syslog( LOG_ERR, "updateProcessStats: Process %d starttime differs ...", ... );
        fclose( pinfo );
        return false;
    }

    pi.cpu.update( utime + stime );   // 双缓冲更新
    pi.mem.update( vsize );
    pi.affinity = cpu;
    pi.starttime = starttime;

    fclose( pinfo );
    return true;
}
```

#### /proc/<pid>/stat 解析

`getProcessTimes` 用 `fscanf` 解析 `/proc/<pid>/stat` 的 39+ 个字段:

```cpp
// server/tools/bwmachined/linux_machine_guard.cpp  L242-297
bool getProcessTimes( FILE *f, unsigned long int *utimePtr,
    unsigned long int *stimePtr, unsigned long int *vsizePtr,
    unsigned long int *starttimePtr, int *cpuPtr )
{
    // ... 大量变量声明 ...
    int returnVal = fscanf( f, "%d %s %c %d %d %d %d %d "
        "%lu %lu %lu %lu %lu %lu %lu "
        "%ld %ld %ld %ld %ld %ld "
        "%lu %lu %ld %lu %lu %lu %lu %lu %lu "
        "%lu %lu %lu %lu %lu %lu %lu "
        "%d %d %lu %lu",
        &pid, name, &state, &ppid, &pgrp, &session, &tty, &tpgid,
        &flags, &minflt, &cminflt, &majflt, &cmajflt, &utime, &stime,
        &cutime, &cstime, &priority, &nice, &num_threads, &itrealvalue,
        &starttime, &vsize, &rss,
        &rlim, &startcode, &endcode, &startstack, &kstkesp, &kstkeip,
        &signal, &blocked, &sigignore, &sigcatch, &wchan, &nswap, &cnswap,
        &exit_signal, &processor, &rt_priority, &policy );

    static const int minResultsExpected = 39;
    if ((returnVal < minResultsExpected) || (ferror( f ))) return false;

    if ( utimePtr ) *utimePtr = utime;
    if ( stimePtr ) *stimePtr = stime;
    if ( vsizePtr ) *vsizePtr = vsize;
    if ( starttimePtr ) *starttimePtr = starttime;
    if ( cpuPtr ) *cpuPtr = processor;
    return true;
}
```

提取的关键字段:
- `utime` + `stime`:用户态+内核态 CPU 时间(用于计算 CPU 占用率)
- `vsize`:虚拟内存大小
- `starttime`:进程启动时间(自系统启动起,jiffies)
- `processor`:上次运行的 CPU(affinity)

### 9.3 重启:Reviver → bwmachined

Reviver 检测到进程死亡后,通过 `CreateMessage` 委托 bwmachined 重启(详见[第二十一章](#二十一reviver-与-bwmachined-的协作))。

### 9.4 关闭:SignalMessage → 优雅关闭

通过 `SignalMessage` 向 bwmachined 发信号,bwmachined 调用 `kill(pid, signal)`:

```cpp
// server/tools/bwmachined/bwmachined.cpp  L1094-1108
void BWMachined::sendSignal (const SignalMessage & sm)
{
    for (uint i=0; i < procs_.size(); i++) {
        ProcessInfo &pm = procs_[i];
        if (pm.m.matches( sm )) {
            kill( pm.m.pid_, sm.signal_ );
            syslog( LOG_INFO, "sendSignal: signal = %d pid = %d uid = %d", ... );
        }
    }
}
```

三种预设:
- `setControlledShutdown()` → SIGUSR1:进程可处理此信号做"受控关闭"(如保存状态后退出)。
- `setKill()` → SIGINT:正常关闭。
- `setHardKill()` → SIGQUIT:强制关闭,通常伴随 core dump。

### 9.5 starttime 防 PID 复用

PID 复用是 Unix 系统的常见问题:进程 A(PID=1234)退出后,系统可能把 PID=1234 分配给新进程 B。如果 bwmachined 还以为 PID=1234 是 A,就会错误地监控/杀死 B。

BigWorld 通过 `starttime` 字段防御:

```cpp
// server/tools/bwmachined/linux_machine_guard.cpp  L220-227
if ((pi.starttime) && (pi.starttime != starttime)) {
    syslog( LOG_ERR, "updateProcessStats: Process %d starttime differs from "
            "last known starttime (old %lu, curr %lu).",
            (int)pi.m.pid_, pi.starttime, starttime );
    fclose( pinfo );
    return false;   // 视为进程已死
}
```

`starttime` 是 `/proc/<pid>/stat` 的第 22 个字段,表示"自系统启动以来的 jiffies 数"。即使 PID 复用,新进程的 starttime 与原进程不同,据此判断"原进程已死"。

`validateProcessInfo`(状态恢复时)同样校验:

```cpp
// server/tools/bwmachined/linux_machine_guard.cpp  L476-510
bool validateProcessInfo( const ProcessInfo &processInfo )
{
    char pinfoFilename[ 64 ];
    bw_snprintf( pinfoFilename, sizeof( pinfoFilename ), "/proc/%d/stat", (int)processInfo.m.pid_ );
    FILE *fp;
    if ((fp = fopen( pinfoFilename, "r" )) == NULL) return false;

    unsigned long int starttime;
    bool status = getProcessTimes( fp, NULL, NULL, NULL, &starttime, NULL );
    fclose( fp );

    if ((status) && (processInfo.starttime) && (starttime != processInfo.starttime)) {
        syslog( LOG_ERR, "validateProcessInfo: Process %d starttime differs ...", ... );
        return false;
    }
    return status;
}
```

### 9.6 异常退出处理

进程"未注销就消失"(`updateProcessStats` 失败且 `errno==ENOENT`):

```cpp
// server/tools/bwmachined/bwmachined.cpp  L1032-1041
for (unsigned int i=0; i < procs_.size(); i++) {
    ProcessInfo &pi = procs_[ i ];
    if (!updateProcessStats( pi ) && errno == ENOENT) {
        syslog( LOG_ERR, "%s (uid:%d) died without deregistering!\n",
            pi.m.c_str(), pi.m.uid_ );
        removeRegisteredProc( i-- );   // 移除并广播 death
    }
}
```

`removeRegisteredProc` 广播 death:

```cpp
// server/tools/bwmachined/bwmachined.cpp  L1073-1088
void BWMachined::removeRegisteredProc( unsigned index )
{
    if (index >= procs_.size()) {
        syslog( LOG_ERR, "Can't remove reg proc at index %d/%" PRIzu "", ... );
        return;
    }

    ProcessInfo &pinfo = procs_[ index ];
    ProcessMessage pm;
    pm << pinfo.m;
    this->broadcastToListeners( pm, pm.NOTIFY_DEATH );

    procs_.erase( procs_.begin() + index );
}
```

---

## 十、Listeners 出生/死亡通知

### 10.1 Listeners 出生/死亡通知机制(核心特色)

`Listeners` 类是 bwmachined 的"出生/死亡事件分发器"。它维护一个监听器列表,进程 birth/death 时遍历列表,向匹配的监听器发送预定义的消息。

### 10.2 ListenerMessage 注册流程

注册监听器(`ListenerMessage`)携带的关键信息:

```cpp
// lib/network/machine_guard.hpp  L604-632
class ListenerMessage : public ProcessMessage
{
public:
    enum Type { ADD_BIRTH_LISTENER = 0, ADD_DEATH_LISTENER = 1 };
    static const uint16 ANY_UID = 0xffff;

    BW::string  preAddr_;
    BW::string  postAddr_;
};
```

`preAddr_` 与 `postAddr_` 是消息模板的两段:
- `preAddr_`:Address 字段之前的内容(包括 Mercury 包头、消息 ID 等)。
- `postAddr_`:Address 字段之后的内容(可能是空)。

bwmachined 触发时,把 `preAddr_` + 实际 Address + `postAddr_` 拼接成完整消息发送:

```cpp
// server/tools/bwmachined/listeners.cpp  L21-56
void Listeners::handleNotify( const Endpoint & endpoint,
    const ProcessMessage & pm, in_addr addr )
{
    char address[6];
    memcpy( address, &addr, sizeof( addr ) );           // 4 字节 IP
    memcpy( address + sizeof( addr ), &pm.port_, sizeof( pm.port_ ) );  // 2 字节 port

    Members::iterator iter = members_.begin();
    while (iter != members_.end())
    {
        ListenerMessage &lm = iter->lm_;

        // 匹配条件:同 category、UID 匹配(或 ANY_UID)、name 匹配(或空)
        if (lm.category_ == pm.category_ &&
            (lm.uid_ == lm.ANY_UID || lm.uid_ == pm.uid_) &&
            (lm.name_ == pm.name_ || lm.name_.size() == 0))
        {
            // 拼接 preAddr + Address + postAddr
            int msglen = lm.preAddr_.size() + sizeof( address ) + lm.postAddr_.size();
            char *data = new char[ msglen ];
            int preSize = lm.preAddr_.size();
            int postSize = lm.postAddr_.size();

            memcpy( data, lm.preAddr_.c_str(), preSize );
            memcpy( data + preSize, address, sizeof( address ) );
            memcpy( data + preSize + sizeof( address ), lm.postAddr_.c_str(), postSize );

            // 发送到监听器所在机器的 port
            endpoint.sendto( data, msglen, lm.port_, iter->addr_ );
            delete [] data;
        }

        ++iter;
    }
}
```

**为什么用 preAddr/postAddr 拆分**:bwmachined 不解析 Mercury 协议,无法构造 Mercury 包头。但调用方(Reviver)通过 `registerBirthListener` 时已经把整个 Mercury 消息(包括头)序列化到 bundle 中,只是 Address 字段留空(占位)。bwmachined 把这个 bundle 拆成"前段 + Address 占位 + 后段",触发时填入实际 Address 再发送。这让 bwmachined 保持协议无关。

### 10.3 birth 通知(进程启动)

进程注册时(`ProcessMessage::REGISTER`):

```cpp
// server/tools/bwmachined/bwmachined.cpp  L1349
broadcastToListeners( pm, pm.NOTIFY_BIRTH );
```

`broadcastToListeners` 把消息广播给本机其他 bwmachined(两跳分发):

```cpp
// server/tools/bwmachined/bwmachined.cpp  L1057-1067
bool BWMachined::broadcastToListeners( ProcessMessage &pm, int type )
{
    uint8 oldparam = pm.param_;
    pm.param_ = type | pm.PARAM_IS_MSGTYPE;   // 设置 NOTIFY_BIRTH/DEATH

    bool ok = pm.sendto( ep_, htons( PORT_MACHINED ), BROADCAST,
        MGMPacket::PACKET_STAGGER_REPLIES );

    pm.param_ = oldparam;
    return ok;
}
```

其他 bwmachined 收到 `NOTIFY_BIRTH` 后,调用本机的 `birthListeners_.handleNotify()`:

```cpp
// server/tools/bwmachined/bwmachined.cpp  L1382-1386
case ProcessMessage::NOTIFY_BIRTH:
{
    birthListeners_.handleNotify( this->endpoint(), pm, sin.sin_addr );
    return true;
}
```

### 10.4 death 通知(进程死亡)

进程退出时:
1. `update()` 中检测到 `updateProcessStats` 失败且 `errno==ENOENT`。
2. 调用 `removeRegisteredProc`,内部 `broadcastToListeners( pm, pm.NOTIFY_DEATH )`。
3. 其他 bwmachined 收到 `NOTIFY_DEATH` 后,调用本机的 `deathListeners_.handleNotify()`。

```cpp
// server/tools/bwmachined/bwmachined.cpp  L1388-1392
case ProcessMessage::NOTIFY_DEATH:
{
    deathListeners_.handleNotify( this->endpoint(), pm, sin.sin_addr );
    return true;
}
```

### 10.5 跨机器两跳分发

```
机器 A                                  机器 B
┌─────────────────────┐                ┌─────────────────────┐
│ 进程 P 启动          │                │  Reviver (listener) │
│ → bwmachined         │                │  注册在机器 B       │
│   broadcastToListener│                └─────────────────────┘
│   (NOTIFY_BIRTH)     │
│        │             │
│        ▼             │                第二跳:本机 bwmachined
│   UDP 广播 ──────────┼───────────────► handleNotify(B's listener)
│                     │                │   发送 birth 消息给 Reviver
└─────────────────────┘                └─────────────────────┘
```

**两跳**:
1. **第一跳**:本机 bwmachined 广播 `NOTIFY_BIRTH/DEATH` 到所有机器。
2. **第二跳**:接收方 bwmachined 调用本机 `birthListeners_.handleNotify()` / `deathListeners_.handleNotify()`,把预定义消息发给本机的 listener 进程。

这种设计让 Reviver 只需在本机 bwmachined 注册一次 listener,就能收到全集群任何机器的 birth/death 事件。

### 10.6 死监听器清理

```cpp
// server/tools/bwmachined/listeners.cpp  L62-73
void Listeners::checkListeners()
{
    for (Members::iterator it = members_.begin(); it != members_.end(); it++)
    {
        if (!serverPlatform_.isProcessRunning( it->lm_.pid_ ))
        {
            syslog( LOG_INFO, "Dropping dead listener (for %s's) with pid %d",
                it->lm_.name_.c_str(), it->lm_.pid_ );
            members_.erase( it-- );
        }
    }
}
```

`checkListeners` 每秒(`update()` 中)调用一次,检查每个 listener 的 PID 是否还存在,若已死则移除。这避免了"死监听器累积":如果 Reviver 崩溃了,它的 listener 条目会被自动清理,不会一直触发 birth/death 通知到不存在的进程。

`isProcessRunning` 在 Linux 上通过 `kill(pid, 0)` 实现(发信号 0,只检查进程是否存在):

```cpp
// server/tools/bwmachined/server_platform_linux.cpp(简化)
bool ServerPlatformLinux::isProcessRunning( uint16 pid ) const
{
    return (::kill( pid, 0 ) == 0) || (errno != ESRCH);
}
```

---

## 十一、Tags 系统

### 11.1 Tags 来源

bwmachined 的 tags 来自两个配置文件:

```cpp
// server/tools/bwmachined/linux_machine_guard.cpp  L31-32
const char * machinedConfFile = "/etc/bwmachined.conf";
const char * bigworldConfFile = "/etc/bigworld.conf";
```

配置文件格式是 INI 风格:

```
# /etc/bwmachined.conf
[Components]
cellappmgr
baseappmgr
dbappmgr
dbapp
loginapp
cellapp
baseapp

[bwmachined]
timing_method=gettime
internal_interface=eth0
max_packet_delay=100
```

`[Components]` 段下列出本机可运行的组件名,`[bwmachined]` 段下是 bwmachined 自身的配置选项。

### 11.2 readConfigFile 解析

```cpp
// server/tools/bwmachined/bwmachined.cpp  L543-600
bool BWMachined::readConfigFile( FILE * file )
{
    char buf[ 512 ];
    BW::string currTag;
    bool isOkay = true;

    while (isOkay && (fgets( buf, sizeof( buf ), file ) != NULL))
    {
        if ((buf[0] == '#') || (buf[0] == 0) || (buf[0] == '\n')) continue;   // 注释/空行

        int len = strlen( buf );

        if (buf[0] == '[')   // 新 tag 类别
        {
            if ((buf[ len - 1 ] == '\n') && (buf[ len - 2 ] == ']')) {
                buf[ len - 2 ] = '\0';
                currTag = buf + 1;
                tags_[ currTag ];   // 即使空也插入
            } else {
                isOkay = false;
                syslog( LOG_ERR, "Invalid tag '%s'\n", buf );
            }
        }
        else if (!currTag.empty())   // 当前 tag 下的值
        {
            if (buf[ len - 1 ] == '\n') buf[ len - 1 ] = '\0';
            tags_[ currTag ].push_back( BW::string( buf ) );
        }
    }
    return isOkay;
}
```

### 11.3 readConfigFile 入口

```cpp
// server/tools/bwmachined/bwmachined.cpp  L606-755
bool BWMachined::readConfigFile()
{
    tags_.clear();

    // 1) 读取 /etc/bwmachined.conf
    FILE * file = fopen( machinedConfFile, "r" );
    if (file == NULL) {
        syslog( LOG_WARNING, "Global config file %s doesn't exist", machinedConfFile );
        return true;   // 不存在不算失败
    }
    bool hasReadMachinedConfFile = this->readConfigFile( file );
    fclose( file );

    // 2) 读取 /etc/bigworld.conf(向后兼容)
    file = fopen( bigworldConfFile, "r" );
    bool hasReadBWConfFile = false;
    if (file != NULL) {
        hasReadBWConfFile = this->readConfigFile( file );
        fclose( file );
    }

    if (!hasReadMachinedConfFile && !hasReadBWConfFile) return false;

    // 3) 解析 timing_method 选项
    const char * optionValue = this->findOption( "timing_method", "TimingMethod" );
    if (optionValue) { timingMethod_ = optionValue; ... }

    // 4) 解析 internal_interface 选项
    optionValue = this->findOption( "internal_interface", "InternalInterface" );
    if (optionValue) {
        // 解析为 IP 或接口名
        // ...
    }

    // 5) 解析 max_packet_delay 选项
    optionValue = this->findOption( "max_packet_delay", "MaxPacketDelay" );
    if (optionValue) {
        int tmpMaxPacketDelay;
        if (sscanf( optionValue, "%d", &tmpMaxPacketDelay ) == 1) {
            maxPacketDelayMillisec_ = tmpMaxPacketDelay;
        }
    }

    return true;
}
```

### 11.4 findOption 查找

```cpp
// server/tools/bwmachined/bwmachined.cpp  L480-528
const char * BWMachined::findOption( 
    const char * optionName, const char * oldOptionName )
{
    // 1) 在 [bwmachined] tag 中查找 "optionName=value"
    TagsMap::iterator tagIter = tags_.find( "bwmachined" );
    if (tagIter != tags_.end()) {
        Tags::iterator valueIter = tagIter->second.begin();
        while (valueIter != tagIter->second.end()) {
            const char * line = valueIter->c_str();
            if (strstr( line, optionName ) == line) {
                const char * pValue = strchr( line, '=' );
                if (pValue) {
                    ++pValue;
                    while (*pValue && isblank( *pValue )) ++pValue;
                    return pValue;
                }
            }
            ++valueIter;
        }
    }

    // 2) 向后兼容:查找 oldOptionName tag
    if (oldOptionName) {
        tagIter = tags_.find( oldOptionName );
        if ((tagIter != tags_.end()) && !tagIter->second.empty()) {
            return tagIter->second.front().c_str();
        }
    }

    return NULL;
}
```

`findOption` 支持"optionName=value"格式(在 `[bwmachined]` 段下)和"独立 tag"格式(向后兼容)。

### 11.5 TagsMessage 查询

通过 `TagsMessage` 查询:

- 空 `tags_[0]` → 返回所有 tag 类别名(如 `Components`、`bwmachined`)。
- 非空 `tags_[0]` → 返回该类别下的所有值。

```cpp
// server/tools/bwmachined/bwmachined.cpp  L1462-1505
case MachineGuardMessage::TAGS_MESSAGE:
{
    TagsMessage &tm = static_cast< TagsMessage& >( mgm );

    if (tm.tags_.size() != 1) {
        syslog( LOG_ERR, "Tags queries must pass only one tag (%" PRIzu " passed)", ... );
        return false;
    }
    BW::string query = tm.tags_[0];
    tm.tags_.clear();

    if (query == "") {
        // 列出所有 tag 类别
        for (TagsMap::iterator it = tags_.begin(); it != tags_.end(); ++it)
            tm.tags_.push_back( it->first );
        tm.exists_ = true;
    } else {
        // 查询特定 tag
        TagsMap::iterator it = tags_.find( query );
        if (it != tags_.end()) {
            Tags &tags = it->second;
            tm.tags_.resize( tags.size() );
            std::copy( tags.begin(), tags.end(), tm.tags_.begin() );
            tm.exists_ = true;
        } else {
            tm.exists_ = false;
        }
    }

    tm.outgoing( true );
    replies.append( tm );
    return true;
}
```

### 11.6 Components tag 用途

`Components` tag 声明本机可运行哪些组件。Reviver 启动时通过 `queryMachinedSettings` 查询此 tag,据此启用/禁用对应的 ComponentReviver:

```
# 在 DB 机器上
[Components]
dbapp
dbappmgr

# 在 App 机器上
[Components]
cellappmgr
baseappmgr
loginapp
```

这样,在 DB 机器上的 Reviver 只会监控 `dbapp` 和 `dbappmgr`,不会尝试监控 `cellappmgr`(因为本机 `Components` tag 没有声明)。**纯配置驱动**,无需修改 Reviver 启动参数。

### 11.7 用户自定义标签

用户可在 `/etc/bwmachined.conf` 中添加任意 tag,例如:

```
[Datacenter]
dc1

[Rack]
r12

[Environment]
production
```

这些 tag 可通过 `TagsMessage` 查询,用于运维工具(如 bwmachined 监控脚本)按 datacenter/rack/environment 过滤机器。

### 11.8 RESET_MESSAGE 重置

```cpp
// server/tools/bwmachined/bwmachined.cpp  L1599-1609
case MachineGuardMessage::RESET_MESSAGE:
{
    ResetMessage &rm = static_cast< ResetMessage& >( mgm );
    this->readConfigFile();   // 重新读取配置
    users_.flush();            // 重新加载用户映射
    syslog( LOG_INFO, "Flushing tags and user mapping at %s's request",
        inet_ntoa( sin.sin_addr ) );
    rm.outgoing( true );
    replies.append( rm );
    return true;
}
```

`ResetMessage` 让 bwmachined 重新读取配置文件与用户映射,无需重启 bwmachined。运维修改 `/etc/bwmachined.conf` 后发 `ResetMessage` 即可生效。

---

## 十二、Cluster 集群视图

### 12.1 Cluster 类

详见[第三章 3.2](#32-cluster-类)。

### 12.2 环状 buddy 拓扑

`chooseBuddy` 选择"下一个"bwmachined 作为 buddy,组成环状:

```cpp
// server/tools/bwmachined/cluster.cpp  L29-55
void Cluster::chooseBuddy()
{
    uint32 oldBuddy = buddyAddr_;
    buddyAddr_ = 0;

    uint32 lowest = 0xFFFFFFFF;
    for (Addresses::iterator it = machines_.begin(); it != machines_.end(); ++it)
    {
        // 1) 找比自己 IP 大的最小 IP(下一个)
        if (*it > ownAddr_ && (buddyAddr_ == 0 || *it < buddyAddr_))
            buddyAddr_ = *it;
        // 2) 同时记录全局最小 IP(用于回环)
        if (*it < lowest && *it != ownAddr_)
            lowest = *it;
    }

    // 3) 如果没有比自己大的,选全局最小(回环到环首)
    if (buddyAddr_ == 0 && machines_.size() > 1)
        buddyAddr_ = lowest;

    MGMPacket::setBuddy( buddyAddr_ );   // 设置全局 buddy(写入所有回复)

    if (buddyAddr_ != oldBuddy) {
        if (buddyAddr_)
            syslog( LOG_INFO, "Buddy is %s", inet_ntoa( (in_addr&)buddyAddr_ ) );
        else
            syslog( LOG_INFO, "I have no buddy" );
    }
}
```

**环状拓扑**:
```
IP=10.0.0.1 → 10.0.0.2 → 10.0.0.3 → 10.0.0.4 → 10.0.0.1 (回环)
```

每个 bwmachined 选择"IP 比自己大的下一个"作为 buddy。最大 IP 的 buddy 是最小 IP,形成环。

**buddy 的作用**:`MGMPacket::setBuddy` 把 buddy 地址写入所有回复包的 `buddy_` 字段。这用于容错:如果发送方失败,buddy 可接管回复。但在当前实现中 buddy 主要用于集群拓扑维护,真正的容错靠 flood keepalive。

### 12.3 BirthReplyHandler 取最大值策略

新 bwmachined 启动时,广播 `ANNOUNCE_BIRTH` 消息,其他 bwmachined 回复告知集群大小:

```cpp
// server/tools/bwmachined/cluster.cpp  L272-317
void Cluster::BirthReplyHandler::addTimer()
{
    MachinedAnnounceMessage mam;
    mam.type_ = mam.ANNOUNCE_BIRTH;
    mam.count_ = 0;
    mam.sendto( cluster_.machined_.endpoint(), htons( PORT_MACHINED ),
        BROADCAST, MGMPacket::PACKET_STAGGER_REPLIES );

    toldSize_ = 1;                       // 至少有自己
    cluster_.machines_.clear();
    cluster_.buddyAddr_ = 0;
    ClusterTimeoutHandler::addTimer();
}

void Cluster::BirthReplyHandler::handleTimeout( TimerHandle handle, void * pUser )
{
    if (cluster_.machines_.size() == toldSize_)
        this->cancel();                   // 收到的数量与被告知的一致,完成
    else
        this->addTimer();                 // 不一致,重发 ANNOUNCE_BIRTH
}

void Cluster::BirthReplyHandler::markReceived( uint32 addr, uint32 count )
{
    cluster_.machines_.insert( addr );

    // 取最大值:相信最大的集群大小
    toldSize_ = std::max( toldSize_, count );

    if (cluster_.machines_.size() == toldSize_)
    {
        syslog( LOG_INFO, "Bootstrap complete; %" PRIzu " machines on network",
            cluster_.machines_.size() );
        cluster_.chooseBuddy();
    }
}
```

**取最大值策略**:多个 bwmachined 可能回复不同的集群大小(因为它们各自看到的成员不同)。新 bwmachined 相信最大值,因为"看到更多成员"的 bwmachined 视角更全。

如果 `machines_.size() < toldSize_`,定时器会重发 `ANNOUNCE_BIRTH`,直到收齐。

### 12.4 FloodReplyHandler 两次重试

```cpp
// server/tools/bwmachined/cluster.cpp  L145-239
Cluster::FloodReplyHandler::FloodReplyHandler( Cluster &cluster ) :
    ClusterTimeoutHandler( cluster ), tries_( MAX_RETRIES )   // MAX_RETRIES = 2
{
    this->sendBroadcast();
    this->addTimer();
}

void Cluster::FloodReplyHandler::handleTimeout( TimerHandle handle, void * pUser )
{
    bool births = false;
    for (Addresses::iterator it = replied_.begin(); it != replied_.end(); ++it) {
        if (cluster_.machines_.find( *it ) == cluster_.machines_.end()) {
            births = true;
            cluster_.machines_.insert( *it );
            syslog( LOG_INFO, "Discovered new machine %s", ... );
        }
    }
    if (births) cluster_.chooseBuddy();

    BW::vector< uint32 > deaths;
    for (Addresses::iterator it = cluster_.machines_.begin(); it != cluster_.machines_.end(); ++it) {
        if (replied_.find( *it ) == replied_.end())
            deaths.push_back( *it );
    }

    tries_--;

    if (!births && deaths.empty()) {
        this->cancel();   // 无变化,完成
    }
    else if (deaths.size() && tries_ > 0) {
        this->sendBroadcast();   // 有死亡但还有重试,重发
    }
    else {
        // 重试用完或只有 births,宣布结果
        MGMPacket packet;
        if (deaths.size()) {
            syslog( LOG_INFO, "Machines have died or become unreachable" );
            for (auto it = deaths.begin(); it != deaths.end(); ++it) {
                MachinedAnnounceMessage *pMam = new MachinedAnnounceMessage();
                pMam->addr_ = *it;
                pMam->type_ = pMam->ANNOUNCE_DEATH;
                packet.append( *pMam, true );
            }
        }
        if (births) {
            // 有新机器,广播所有已知机器
            for (auto it = cluster_.machines_.begin(); it != cluster_.machines_.end(); ++it) {
                MachinedAnnounceMessage *pMam = new MachinedAnnounceMessage();
                pMam->addr_ = *it;
                pMam->type_ = pMam->ANNOUNCE_EXISTS;
                packet.append( *pMam, true );
            }
        }
        MemoryOStream os;
        packet.write( os );
        cluster_.machined_.endpoint().sendto( os.data(), os.size(), htons( PORT_MACHINED ) );
        this->cancel();
    }
}
```

**两次重试**:`MAX_RETRIES = 2`。FloodReplyHandler 发广播后等回复,如果有机器没回(可能死亡或网络分区),重试 2 次。两次都没回才宣布死亡,避免单次丢包误判。

**宣布结果**:
- 有死亡:广播 `ANNOUNCE_DEATH` 给所有 bwmachined。
- 有新机器:广播 `ANNOUNCE_EXISTS` 给所有已知机器(让它们更新 machines_ 集合)。

### 12.5 ANNOUNCE_EXISTS 全集群同步

```cpp
// server/tools/bwmachined/bwmachined.cpp  L1669-1679
else if (mam.type_ == mam.ANNOUNCE_EXISTS)
{
    if (cluster_.machines_.count( mam.addr_ ) == 0)
    {
        syslog( LOG_INFO, "Apparently %s is running machined",
            inet_ntoa( (in_addr&)mam.addr_ ) );
        cluster_.machines_.insert( mam.addr_ );
        cluster_.chooseBuddy();
    }
    return true;
}
```

`ANNOUNCE_EXISTS` 让所有 bwmachined 同步"某机器存在"。新 bwmachined 上线时,FloodReplyHandler 检测到 births 后,会广播所有已知机器的 `ANNOUNCE_EXISTS`,让全集群更新视图。

### 12.6 自我死亡应对

```cpp
// server/tools/bwmachined/bwmachined.cpp  L1645-1665
else if (mam.type_ == mam.ANNOUNCE_DEATH)
{
    uint32 deadaddr = (uint32)mam.addr_;

    if (deadaddr != cluster_.ownAddr_)
    {
        // 别的机器死了
        syslog( LOG_INFO, "%s says %s is gone", ... );
        cluster_.machines_.erase( deadaddr );
        cluster_.chooseBuddy();
    }
    else
    {
        // 报告我自己死了?重发 birth
        cluster_.birthHandler_.addTimer();
        syslog( LOG_INFO,
            "Reports of my death have been greatly exaggerated!" );
    }
    return true;
}
```

**自我死亡应对**:如果收到 `ANNOUNCE_DEATH` 报告自己死了(可能是网络分区导致其他机器误以为我死了),本机重发 `ANNOUNCE_BIRTH` 重新加入集群。这是"自我修复"机制:网络分区恢复后,被误判死亡的机器会重新出现。

---

## 十三、状态持久化与重启恢复

### 13.1 save 状态

bwmachined 收到 SIGTERM 时,把进程表保存到 `/var/run/bwmachined.state`:

```cpp
// server/tools/bwmachined/bwmachined.cpp  L31
const char* BWMachined::STATE_FILE = "/var/run/bwmachined.state";

// L46-54
static void sigterm( int sig )
{
    if (BWMachined::pInstance()) {
        BWMachined::pInstance()->save();
    }
    g_serverRunning = false;
}
```

```cpp
// server/tools/bwmachined/bwmachined.cpp  L341-379
void BWMachined::save()
{
    FileStream out( STATE_FILE, "w" );

    if (out.error()) {
        syslog( LOG_ERR, "Couldn't write process state to %s: %s", ... );
        unlink( STATE_FILE );
        return;
    }

    for (unsigned i=0; i < procs_.size(); i++)
    {
        MemoryOStream processBuffer;

        ProcessInfo &pi = procs_[ i ];
        processBuffer << pi.cpu << pi.mem << pi.affinity << pi.starttime;
        pi.m.write( processBuffer );

        out.appendString( (const char *)processBuffer.data(), processBuffer.size() );
    }

    if (out.error()) {
        syslog( LOG_ERR, "Failed to write process table to %s: %s", ... );
        unlink( STATE_FILE );
        return;
    }

    if (procs_.size() > 0)
        syslog( LOG_INFO, "Wrote %" PRIzu " entries to %s prior to shutdown", ... );
}
```

每个进程记录包含:`cpu`、`mem`、`affinity`、`starttime`、`ProcessStatsMessage`(可序列化的进程信息)。

### 13.2 load 状态

bwmachined 启动时尝试加载之前的状态:

```cpp
// server/tools/bwmachined/bwmachined.cpp  L385-460
void BWMachined::load()
{
    FileStream in( STATE_FILE, "r" );
    struct stat statinfo;

    if (in.error()) return;   // 文件不存在,静默退出

    // 10 分钟有效期
    if (in.stat( &statinfo ) == 0) {
        time_t age = time( NULL ) - statinfo.st_mtime;
        if (age > 10 * 60) {   // 超过 10 分钟
            syslog( LOG_INFO, "Ignoring out-of-date %s (%d seconds old)", ... );
            unlink( STATE_FILE );
            return;
        }
    } else {
        syslog( LOG_ERR, "Couldn't stat %s: %s", ... );
        return;
    }

    int len = in.length();
    uint totalEntries = 0;
    while (in.tell() < len) {
        BW::string processBufferStr;
        in >> processBufferStr;

        MemoryIStream processBuffer( processBufferStr.data(), processBufferStr.size() );

        ProcessInfo pi;
        processBuffer >> pi.cpu >> pi.mem >> pi.affinity >> pi.starttime;
        pi.m.read( processBuffer );

        if (processBuffer.error() || in.error()) {
            syslog( LOG_ERR, "Process table %u in %s corrupt", ... );
            unlink( STATE_FILE );
            return;
        }

        if (!validateProcessInfo( pi )) {   // 校验 PID 仍存活且 starttime 匹配
            syslog( LOG_ERR, "Failed to restore %s (pid:%d uid:%d).", ... );
        } else {
            procs_.push_back( pi );
            syslog( LOG_INFO, "Restored %s (pid:%d uid:%d)", ... );
        }
        ++totalEntries;
    }

    if (len > 0) {
        syslog( LOG_INFO, "Restored %" PRIzu " of %u entries from %s",
            procs_.size(), totalEntries, STATE_FILE );
    }

    unlink( STATE_FILE );   // 加载完删除
}
```

### 13.3 10 分钟有效期

```cpp
time_t age = time( NULL ) - statinfo.st_mtime;
if (age > 10 * 60) {   // 超过 10 分钟
    syslog( LOG_INFO, "Ignoring out-of-date %s (%d seconds old)", ... );
    unlink( STATE_FILE );
    return;
}
```

**10 分钟有效期**:如果 bwmachined 停止超过 10 分钟才重启,认为状态过时(PID 可能已被复用),丢弃状态文件。这避免了"PID 复用导致监控错误进程"。

### 13.4 starttime 校验

`validateProcessInfo` 校验:
1. `/proc/<pid>/stat` 仍存在(进程还活着)。
2. `starttime` 匹配(同一进程,非 PID 复用)。

```cpp
// server/tools/bwmachined/linux_machine_guard.cpp  L476-510
bool validateProcessInfo( const ProcessInfo &processInfo )
{
    char pinfoFilename[ 64 ];
    bw_snprintf( pinfoFilename, sizeof( pinfoFilename ), "/proc/%d/stat", (int)processInfo.m.pid_ );
    FILE *fp;
    if ((fp = fopen( pinfoFilename, "r" )) == NULL) return false;

    unsigned long int starttime;
    bool status = getProcessTimes( fp, NULL, NULL, NULL, &starttime, NULL );
    fclose( fp );

    if ((status) && (processInfo.starttime) && (starttime != processInfo.starttime)) {
        syslog( LOG_ERR, "validateProcessInfo: Process %d starttime differs ...", ... );
        return false;
    }
    return status;
}
```

### 13.5 bwmachined 自身重启

bwmachined 自身不被 Reviver 监控(因为它在 Reviver 之下)。bwmachined 重启场景:
1. **手动重启**:`service bwmachined restart`。
2. **崩溃**:理论上 bwmachined 不应该崩溃,如果崩溃通常由 systemd/init 自动重启。
3. **升级**:停服升级 bwmachined 二进制。

重启后:
1. 加载 `/var/run/bwmachined.state` 恢复进程表。
2. 重新读取配置文件。
3. 重新加入集群 ring(广播 `ANNOUNCE_BIRTH`)。
4. 期间被监控的进程仍在运行(它们独立于 bwmachined),只是暂时无法接收 birth/death 通知。

**注意**:bwmachined 重启期间(通常几秒到几十秒),birth/death 通知会丢失。Reviver 的 ping 心跳作为兜底,能在 bwmachined 恢复后通过 ping 检测到进程状态。

---

## 十四、平台抽象层

### 14.1 ServerPlatform 抽象基类

```cpp
// server/tools/bwmachined/server_platform.hpp  L27-114
class ServerPlatform
{
public:
    typedef BW::set< BW::string > ProcessSet;

    ServerPlatform();
    bool isInitialised() const;

    virtual bool findUserBinaryDirForConfig( const BW::string & bwRoot,
        const BW::string & bwConfig, BW::string & binaryDir ) = 0;

    virtual bool isProcessRunning( uint16 pid ) const = 0;

    virtual bool updateSystemInfo( SystemInfo & systemInfo,
        ServerInfo * pServerInfo ) = 0;

    virtual bool checkCoreDumps( MachineGuardMessage::UserId uid,
        const BW::string & bwRoot, UserMessage::CoreDumps & coreDumps ) = 0;

    bool determineVersion( MachineGuardMessage::UserId uid,
        const BW::string & bwRoot, BW::string & versionString );

protected:
    void initVersionsProcesses();

    virtual bool checkBinariesExist( MachineGuardMessage::UserId uid, 
        const BW::string & bwRoot, const ProcessSet & processes ) = 0; 

    bool isInitialised_;
    typedef BW::map< ProcessBinaryVersion, ProcessSet > VersionsProcesses;
    VersionsProcesses versionsProcesses_;
};
```

四个纯虚函数:
- `findUserBinaryDirForConfig`:查找用户二进制目录。
- `isProcessRunning`:检查 PID 是否存在。
- `updateSystemInfo`:更新机器统计。
- `checkCoreDumps`:检查 core dump 文件。
- `checkBinariesExist`:检查一组二进制是否存在(用于版本判定)。

### 14.2 ServerPlatformLinux 实现

```cpp
// server/tools/bwmachined/server_platform_linux.hpp  L16-65
class ServerPlatformLinux : public ServerPlatform
{
public:
    ServerPlatformLinux();

    bool findUserBinaryDirForConfig( const BW::string & bwRoot,
        const BW::string & bwConfig, BW::string & binaryDir ) override;
    bool isProcessRunning( uint16 pid ) const override;
    bool updateSystemInfo( SystemInfo & systemInfo, ServerInfo * pServerInfo ) override;
    bool checkCoreDumps( MachineGuardMessage::UserId uid,
        const BW::string & bwRoot, UserMessage::CoreDumps & coreDumps ) override;

protected:
    bool checkBinariesExist( MachineGuardMessage::UserId uid,
        const BW::string & bwRoot, const ProcessSet & set ) override;

private:
    typedef BW::vector< BW::string > StringList;

    void initConfigSuffixes();
    void initKernelVersion();
    bool initArchitecture();

    bool configDirectoryExists( const BW::string & bwRoot,
        const StringList & pregeneratedConfigPaths, BW::string & binaryDir );
    bool visitBinaryPaths( MachineGuardMessage::UserId uid,
        const BW::string & bwRoot, BinaryPathVisitor & visitor,
        const char * purposeString = NULL );

    StringList preparedHybridSuffix_;
    StringList preparedDebugSuffix_;
    StringList preparedOldHybridSuffix_;
    StringList preparedOldDebugSuffix_;

    uint8 hostArchitecture_;     // 32 / 64
    BW::string architecture_;

    bool hasExtendedStats_;
};
```

#### 14.2.1 二进制目录查找

`initConfigSuffixes` 预生成所有可能的二进制路径后缀(因 BigWorld 历史上有多种目录结构):

```cpp
// server/tools/bwmachined/server_platform_linux.cpp  L99-200(节选)
void ServerPlatformLinux::initConfigSuffixes()
{
    const BW::string newDirectoryPrefix( "/game/bin/server/" );
    const BW::string oldDirectoryPrefix( "/bigworld/bin/" );
    const BW::string serverSuffix( "/server" );
    const BW::string arch64Suffix( "64" );
    const BW::string bwConfigAsLowerHybrid( "hybrid" );
    const BW::string bwConfigAsLowerDebug( "debug" );

    const BW::string & platformBuildStr = BW::PlatformInfo::buildStr();
    const BW::string & platformStr = BW::PlatformInfo::str();

    // Hybrid 后缀(多种历史路径)
    // /game/bin/server/<platform_build>/server
    preparedHybridSuffix_.push_back( newDirectoryPrefix + platformBuildStr + serverSuffix );
    // /game/bin/server/<platform>/server
    preparedHybridSuffix_.push_back( newDirectoryPrefix + platformStr + serverSuffix );
    // /game/bin/server/Hybrid64
    preparedHybridSuffix_.push_back( newDirectoryPrefix + BW_CONFIG_HYBRID_OLD + arch64Suffix );
    // /game/bin/server/hybrid64
    preparedHybridSuffix_.push_back( newDirectoryPrefix + bwConfigAsLowerHybrid + arch64Suffix );
    // /bigworld/bin/<platform_build>/server (旧目录)
    // /bigworld/bin/<platform>/server
    // /bigworld/bin/Hybrid64
    // /bigworld/bin/hybrid64

    // Debug 后缀(类似 Hybrid)
    // ...
}
```

`findUserBinaryDirForConfig` 遍历这些后缀,找到第一个存在的目录:

```cpp
bool ServerPlatformLinux::findUserBinaryDirForConfig( const BW::string & bwRoot,
    const BW::string & bwConfig, BW::string & binaryDir )
{
    const StringList & suffixes = (bwConfig == BW_CONFIG_HYBRID) ? preparedHybridSuffix_ :
                                   (bwConfig == BW_CONFIG_DEBUG) ? preparedDebugSuffix_ : ...;

    for (StringList::const_iterator it = suffixes.begin(); it != suffixes.end(); ++it) {
        BW::string path = bwRoot + *it;
        if (directoryExists( path )) {
            binaryDir = path;
            return true;
        }
    }
    return false;
}
```

#### 14.2.2 进程检查

```cpp
bool ServerPlatformLinux::isProcessRunning( uint16 pid ) const
{
    return (::kill( pid, 0 ) == 0) || (errno != ESRCH);
}
```

`kill(pid, 0)` 发信号 0,只检查进程是否存在,不实际发信号。`ESRCH` 表示"无此进程"。

#### 14.2.3 系统信息更新

`updateSystemInfo` 读取 `/proc/stat`、`/proc/meminfo`、`/proc/net/dev` 等,填充 `SystemInfo`。详见 `server_platform_linux.cpp` 实现。

### 14.3 Windows 实现的缺失

`server/platform/` 目录只有 Linux 实现,**没有 Windows 实现**。这意味着:
- bwmachined **只能在 Linux 上运行**。
- Windows 上无法运行 BigWorld 服务器集群(只能运行客户端/工具)。

这是 BigWorld 的设计选择:服务器侧坚定地基于 Linux,客户端侧才跨平台(Windows、macOS)。

### 14.4 fork/exec vs CreateProcess

| 维度 | Linux fork/exec | Windows CreateProcess |
|------|-----------------|----------------------|
| 进程创建 | `fork()` 复制当前进程,`exec()` 替换映像 | `CreateProcess()` 一步创建 |
| 文件描述符继承 | 默认全部继承,可用 `FD_CLOEXEC` 关闭 | 默认不继承,需 `bInheritHandles=TRUE` |
| UID 切换 | `setuid`/`setgid` | `CreateProcessAsUser` |
| 管道 | `pipe()` + `FD_CLOEXEC` | `CreatePipe()` + `SetHandleInformation` |
| 信号 | `kill(pid, sig)` | `TerminateProcess` (无信号概念) |
| /proc | `/proc/<pid>/stat` | `GetProcessTimes` API |

bwmachined 的设计深度依赖 Linux 特性(`/proc`、`fork`、`setuid`、信号),移植到 Windows 需要重写大量代码。

---

## 十五、用户与权限

### 15.1 UserMap 类

```cpp
// server/tools/bwmachined/usermap.hpp  L9-30
class UserMap
{
public:
    UserMap();
    void add( const UserMessage &um );
    UserMessage* add( struct passwd *ent );

    bool getEnv( UserMessage & um, bool userAlreadyKnown = false );
    UserMessage* fetch( uint16 uid );
    bool setEnv( const UserMessage &um );
    void flush();

    friend class BWMachined;

protected:
    typedef BW::map< uint16, UserMessage > Map;
    Map map_;
    UserMessage notfound_;

    void queryUserConfs();
};
```

`UserMap` 维护 `uid → UserMessage` 映射,`UserMessage` 包含:
- `uid_`、`gid_`:用户 ID、组 ID
- `username_`、`fullname_`:用户名、全名
- `home_`:家目录
- `mfroot_`:BigWorld 根目录
- `bwrespath_`:资源路径
- `coredumps_`:core dump 列表

### 15.2 UID/GID 管理

```cpp
// server/tools/bwmachined/usermap.cpp  L23-40
void UserMap::queryUserConfs()
{
    struct passwd *pEnt;
    while ((pEnt = getpwent()) != NULL)   // 遍历所有用户
    {
        UserMessage um;
        um.outgoing( true );
        um.init( *pEnt );

        if (this->getEnv( um, /*userAlreadyKnown*/ true ))   // 仅加载有 .bwmachined.conf 的用户
        {
            this->add( um );
        }
    }
    endpwent();
}
```

`queryUserConfs` 遍历 `/etc/passwd` 中所有用户,但只加载有 `~/.bwmachined.conf` 的用户。

### 15.3 setgid/setuid 严格顺序

```cpp
// server/tools/bwmachined/linux_machine_guard.cpp  L368-381
if (setgid( gid ) == -1)
{
    syslog( LOG_ERR, "Failed to setgid() to %d for user %d, group will be root\n", gid, uid );
}

if (setuid( uid ) == -1)
{
    syslog( LOG_ERR, "Failed to setuid to %d, aborting exec for %s\n", uid, binaryName );
    write( statusPipe[ 1 ], &errno, sizeof( errno ) );
    exit( EXIT_FAILURE );
}
```

**严格顺序**:必须先 `setgid` 再 `setuid`。原因:
- `setuid` 后从 root 切换到普通用户,**失去 root 权限**。
- 普通用户不能 `setgid` 到其他组(除非该用户属于那个组)。
- 所以必须以 root 身份先 `setgid`,再 `setuid`。

如果 `setgid` 失败,仅警告(组保持 root,虽然不理想但能继续);如果 `setuid` 失败,直接 exit(因为不能以 root 身份运行游戏进程,安全风险)。

### 15.4 多租户支持

bwmachined 支持多用户:不同 `CreateMessage.uid_` 启动的进程以不同用户身份运行。每个用户的:
- `BW_ROOT`(mfroot_):BigWorld 安装根目录(可不同用户用不同版本)。
- `BWRES_PATH`(bwrespath_):资源路径(可隔离不同用户的数据)。
- `HOME`:家目录(用于配置文件查找)。

这让一台机器可以同时运行多个独立的 BigWorld 集群(不同用户),共享一个 bwmachined。

### 15.5 ~/.bwmachined.conf + /etc/bigworld.conf 双层查找

`getEnv` 双层查找用户环境:

```cpp
// server/tools/bwmachined/usermap.cpp  L106-190
bool UserMap::getEnv( UserMessage & um, bool userAlreadyKnown )
{
    char buf[ 1024 ], mfroot[ 256 ], bwrespath[ 1024 ];
    const char *filename = um.getConfFilename();   // ~/.bwmachined.conf
    bool hasFoundEnv = false;

    if (!userAlreadyKnown && (getpwuid( um.uid_ ) == NULL)) {
        syslog( LOG_ERR, "Uid %d doesn't exist on this system!", um.uid_ );
        return false;
    }

    // 1) 首先查找 ~/.bwmachined.conf
    FILE * file;
    if ((file = fopen( filename, "r" )) != NULL) {
        while (fgets( buf, sizeof(buf)-1, file ) != NULL) {
            if (buf[0] != '#' && buf[0] != 0) {
                if (sscanf( buf, "%[^;];%s", mfroot, bwrespath ) == 2) {
                    um.mfroot_ = mfroot;
                    um.bwrespath_ = bwrespath;
                    hasFoundEnv = true;
                    break;
                } else if (!Util::isEmpty( buf )) {
                    syslog( LOG_ERR, "%s has invalid line '%s'\n", filename, buf );
                }
            }
        }
    }
    if (file != NULL) fclose( file );

    if (hasFoundEnv) return true;

    // 2) 回退到 /etc/bwmachined.conf
    if ((file = fopen( machinedConfFile, "r" )) == NULL) return false;

    while (fgets( buf, sizeof(buf)-1, file ) != NULL) {
        if (buf[0] == '#' || buf[0] == 0) continue;
        if (buf[0] == '[') break;   // 到达 tags 段,退出

        int file_uid;
        if (sscanf( buf, "%d;%[^;];%s", &file_uid, mfroot, bwrespath ) == 3 &&
            file_uid == um.uid_)
        {
            um.mfroot_ = mfroot;
            um.bwrespath_ = bwrespath;
            hasFoundEnv = true;
            break;
        }
    }
    fclose( file );

    return hasFoundEnv;
}
```

**双层查找**:
1. **用户级**:`~/.bwmachined.conf`,格式 `<mfroot>;<bwrespath>`(每用户一个)。
2. **系统级**:`/etc/bwmachined.conf`,格式 `<uid>;<mfroot>;<bwrespath>`(集中管理)。

用户级优先,系统级作为回退。这让"普通用户"可以通过修改 `~/.bwmachined.conf` 自定义自己的 BW_ROOT,而"运维"可以通过 `/etc/bwmachined.conf` 集中管理所有用户。

### 15.6 getConfFilename

```cpp
// lib/network/machine_guard.cpp  L1285-1291
const char * UserMessage::getConfFilename() const
{
    static char buf[ 256 ];
    bw_snprintf( buf, sizeof( buf ), "%s/.bwmachined.conf", home_.c_str() );
    return buf;
}
```

`getConfFilename` 返回 `~/.bwmachined.conf` 路径(基于 `home_` 字段)。

---

## 十六、Reviver 概述

### 16.1 位置与角色

`Reviver` 位于 `server/reviver/`,是 BigWorld 服务器侧的**业务级看门狗进程**。它监控 5 类关键单例进程,在它们崩溃时通过 bwmachined 拉起新实例:

| 被监控进程 | 角色 | 是否单例 |
|-----------|------|---------|
| CellAppMgr | 空间管理器 | 是 |
| BaseAppMgr | Base 进程管理器 | 是 |
| DBAppMgr | DB 进程管理器 | 是 |
| DBApp | 数据库进程 | 是(可多实例,但每实例独立监控) |
| LoginApp | 登录进程 | 否(可多实例) |

**注意**:Reviver **不监控 CellApp 和 BaseApp**(空间/实体承载进程)。这两类进程的容错由各自的管理器(CellAppMgr/BaseAppMgr)处理。

### 16.2 三重继承

```cpp
// server/reviver/reviver.hpp  L28-29
class Reviver : public ServerApp, public TimerHandler,
    public Singleton< Reviver >
```

| 基类 | 作用 | 来源 |
|------|------|------|
| `ServerApp` | 服务器应用基类,提供 `init`/`run`/`shutDown` 框架、watcher 注册、network interface 管理 | `server/server_app.hpp` |
| `TimerHandler` | 定时器回调基类,实现 `handleTimeout` | `network/event_dispatcher.hpp` |
| `Singleton<Reviver>` | 单例模式,通过 `Reviver::pInstance()` 全局访问 | `cstdmf/singleton.hpp` |

类声明中使用宏 `SERVER_APP_HEADER( Reviver, reviver )` 展开为 ServerApp 框架所需的静态成员与工厂方法,并 `typedef ReviverConfig Config` 绑定配置类。

### 16.3 监控 5 类进程

| 进程 | configName | createName | interfaceName | 注册点 |
|------|-----------|------------|---------------|--------|
| CellAppMgr | `cellAppMgr` | `cellappmgr` | `CellAppMgrInterface` | `server/cellappmgr/cellappmgr.cpp:183` |
| BaseAppMgr | `baseAppMgr` | `baseappmgr` | `BaseAppMgrInterface` | `server/baseappmgr/baseappmgr.cpp:365` |
| DBAppMgr | `dbAppMgr` | `dbappmgr` | `DBAppMgrInterface` | `server/dbappmgr/dbappmgr.cpp:236` |
| DBApp | `dbApp` | `dbapp` | `DBAppInterface` | `server/dbapp/dbapp.cpp:778` |
| LoginApp | `loginApp` | `loginapp` | `LoginIntInterface` | `server/loginapp/loginapp.cpp:270` |

### 16.4 入口

```cpp
// server/reviver/main.cpp  L32-44
int BIGWORLD_MAIN( int argc, char * argv[] )
{
    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--help" ) == 0) {
            printHelp( argv[0] );
            return 0;
        }
    }
    return bwMainT< Reviver >( argc, argv );
}
```

`BIGWORLD_MAIN` 宏展开为标准 main,`bwMainT<Reviver>` 模板创建 Reviver 实例并调用其 `init`/`run`。

### 16.5 关键成员

```cpp
// server/reviver/reviver.hpp  L67-84
private:
    virtual bool init( int argc, char * argv[] );
    virtual bool run();

    enum TimeoutType
    {
        TIMEOUT_REATTACH,   // 重新附着周期触发
        TIMEOUT_TICK        // 主 tick 触发
    };

    TimerHandle      timerHandle_;    // REATTACH 定时器
    TimerHandle      tickTimer_;      // 主 tick 定时器

    ComponentRevivers components_;   // 所有 ComponentReviver 列表

    bool             shuttingDown_;  // 是否正在关闭
    bool             isDirty_;       // 输出脏标记,用于日志节流
```

- `components_`:从全局 `g_pComponentRevivers` 拷贝而来(5 个特化类通过 `IntrusiveObject` 自动注册)。
- `isDirty_`:组件附着/脱离状态变化时置 true,REATTACH 周期据此决定是否打印 summary。

### 16.6 TagsHandler 内部类

```cpp
// server/reviver/reviver.hpp  L57-65
class TagsHandler : public MachineGuardMessage::ReplyHandler
{
public:
    TagsHandler( Reviver &reviver ) : reviver_( reviver ) {}
    virtual bool onTagsMessage( TagsMessage &tm, uint32 addr );
private:
    Reviver &reviver_;
};
```

`TagsHandler` 处理 `queryMachinedSettings()` 发出的 `TagsMessage` 异步回复。

### 16.7 构造与析构

```cpp
// server/reviver/reviver.cpp  L37-43
Reviver::Reviver( Mercury::EventDispatcher & mainDispatcher,
       Mercury::NetworkInterface & interface ) :
    ServerApp( mainDispatcher, interface ),
    shuttingDown_( false ),
    isDirty_( true )
{
}
```

构造简单,仅初始化基类与两个 bool 标记。`isDirty_` 初始为 true,保证首次 REATTACH 周期打印 summary。

```cpp
// server/reviver/reviver.cpp  L49-53
Reviver::~Reviver()
{
    timerHandle_.cancel();
    tickTimer_.cancel();
}
```

析构时取消两个定时器,防止回调到已销毁对象

---

## 十七、ComponentReviver 5 特化类

### 17.1 ComponentReviver 基类总览

`ComponentReviver` 是 Reviver 体系中**最核心的运行时单元**——每个被监控组件类型(CellAppMgr / BaseAppMgr / DBAppMgr / DBApp / Login)对应一个 `ComponentReviver` 实例。它继承自四个基类,职责高度耦合:

```cpp
// server/reviver/component_reviver.hpp  L22-26
class ComponentReviver : public Mercury::ShutdownSafeReplyMessageHandler,
    public TimerHandler,
    public Mercury::InputMessageHandler,
    public IntrusiveObject< ComponentReviver >
```

| 基类 | 职责 |
|------|------|
| `ShutdownSafeReplyMessageHandler` | 处理 ping 回复(在 shutdown 期间仍可处理,避免悬挂请求) |
| `TimerHandler` | 实现 `handleTimeout`,周期性发 ping |
| `InputMessageHandler` | 处理来自 bwmachined 的 birth/death 通知 |
| `IntrusiveObject<ComponentReviver>` | **自注册**:构造时把自己加入全局链表 `g_pComponentRevivers`,供 `Reviver` 遍历 |

**自注册模式**是 BigWorld 模块化设计的精髓:

```cpp
// server/reviver/component_reviver.cpp  L23
ComponentRevivers * g_pComponentRevivers;

// L30
ComponentReviver::ComponentReviver( ... ) :
    IntrusiveObject< ComponentReviver >( g_pComponentRevivers ),
    ...
```

每个特化类(如 `CellAppMgrReviver`)在 .cpp 中声明一个全局变量 `g_reviverOfCellAppMgr`,其构造函数会把 `this` 指针挂入 `g_pComponentRevivers`。Reviver 在 `init()` 中通过 `*g_pComponentRevivers` 拿到完整链表。

### 17.2 关键成员与状态机

```cpp
// server/reviver/component_reviver.hpp  L82-99
private:
    Mercury::EventDispatcher * pDispatcher_;
    Mercury::NetworkInterface * pInterface_;
    Mercury::Address addr_;             // 被监控进程的当前地址

    BW::string configName_;             // 如 "cellAppMgr",用于 BWConfig
    BW::string name_;                   // 如 "CellAppMgr",用于日志
    BW::string interfaceName_;          // 如 "CellAppMgrInterface"
    const char * createParam_;         // 如 "cellappmgr",传给 CreateMessage

    ReviverPriority priority_;          // 主备仲裁优先级(0=未激活)

    TimerHandle timerHandle_;           // ping 周期定时器
    int pingsToMiss_;                   // 剩余可丢失 ping 数
    int maxPingsToMiss_;                // 最大容忍丢失数(默认 3)
    int pingPeriod_;                    // 微秒,默认 100000(100ms)

    bool isAttached_;                   // 当前是否成功 attach 到被监控进程
    bool isEnabled_;                    // 是否被启用(--add/--del 或 tags 控制)
```

**状态机**:

```
       init()                  activate(p)
   ┌──────────┐              ┌──────────┐
   │ DISABLED │──┐           │ WATCHING │◄────┐
   └──────────┘  │           └──────────┘     │
       ▲         │              │             │
       │         │    ping=YES  │             │ ping=NO
       │         │              ▼             │ 或 death 通知
       │         │           ┌──────────┐     │
       │         │           │ ATTACHED │─────┘
       │         │           └──────────┘
       │         │              │
       │         │  pingsToMiss=0
       │         │              │
       │         │              ▼
       │         │           ┌──────────┐
       │         │           │ REVIVING │
       │         │           └──────────┘
       │         │              │
       │         │      bwmachined fork 成功
       │         │              │
       └─────────┴──────────────┘
                         │
                         ▼
                      (循环)
```

`isAttached_` 是核心状态:只有当 ping 回复返回 `REVIVER_PING_YES` 时才置 true。一旦被监控进程不再回复 `YES`(可能因为更高优先级的 Reviver 接管),`deactivate()` 会被调用,`isAttached_` 复位。

### 17.3 init() 详解:配置、查找、注册监听

```cpp
// server/reviver/component_reviver.cpp  L62-111
bool ComponentReviver::init( Mercury::EventDispatcher & dispatcher,
        Mercury::NetworkInterface & interface )
{
    bool isOkay = true;
    MF_ASSERT( pDispatcher_ == NULL );
    pDispatcher_ = &dispatcher;
    pInterface_ = &interface;

    BW::string prefix = "reviver/";
    float pingPeriodInSeconds =
        BWConfig::get( (prefix + configName_ + "/pingPeriod").c_str(),
            ReviverConfig::pingPeriod() );

    if (pingPeriodInSeconds >
            BWConfig::get( (prefix + configName_ + "/subjectTimeout").c_str(),
                ReviverConfig::subjectTimeout() ))
    {
        CRITICAL_MSG( "ComponentReviver::init: ...subjectTimeout must be larger..." );
    }

    pingPeriod_ = int( pingPeriodInSeconds * 1000000 );
    maxPingsToMiss_ = BWConfig::get( (prefix + configName_ + "/timeoutInPings").c_str(),
                            ReviverConfig::timeoutInPings() );

    this->initInterfaceElements();  // 子类设置 pBirthMessage_ 等

    if (Mercury::MachineDaemon::findInterface( interfaceName_.c_str(), 0,
                    addr_, 4 ) != Mercury::REASON_SUCCESS)
    {
        ERROR_MSG( "ComponentReviver::init: failed to find %s\n", interfaceName_.c_str() );
        isOkay = false;
    }

    Mercury::MachineDaemon::registerBirthListener( interface.address(),
            *pBirthMessage_, const_cast<char *>( interfaceName_.c_str() ) );
    Mercury::MachineDaemon::registerDeathListener( interface.address(),
            *pDeathMessage_, const_cast<char *>( interfaceName_.c_str() ) );

    return isOkay;
}
```

**6 步解析**:

1. **断言**:首次初始化,不允许重复。
2. **配置覆盖**:读取 `reviver/<configName>/pingPeriod`,fallback 到全局 `reviver/pingPeriod`(默认 0.1s)。同样支持 `subjectTimeout`。
3. **配置健全性**:要求 `pingPeriod < subjectTimeout`,否则 `CRITICAL_MSG` 中止进程。这是为了确保被监控进程的 `ReviverSubject::msTimeout_` 大于 ping 周期,避免误判超时。
4. **派生子类钩子**:调用 `initInterfaceElements()`,由各特化类设置三个 `InterfaceElement` 指针:`pBirthMessage_`、`pDeathMessage_`、`pPingMessage_`。
5. **同步查找当前进程**:`findInterface` 向本机 bwmachined 发 `ProcessStatsMessage`,最多重试 4 次。如果找不到(可能进程尚未启动),仅记日志,不退出——后续 birth listener 会通知 Reviver 进程何时上线。
6. **注册 birth/death listener**:把自身的 `Address`(Mercury 端口)+ `InterfaceElement` 注册到 bwmachined。bwmachined 会在该类型进程上下线时回调该 InterfaceElement 对应的消息。

### 17.4 revive():wasAttached 守门

```cpp
// server/reviver/component_reviver.cpp  L117-130
void ComponentReviver::revive()
{
    bool wasAttached = isAttached_;

    this->deactivate();
    addr_.ip = 0;
    addr_.port = 0;

    if (wasAttached)
    {
        INFO_MSG( "Reviving %s\n", name_.c_str() );
        Reviver::pInstance()->revive( createParam_ );
    }
}
```

**关键守门 `wasAttached`**:只有当前**已经 attach** 的进程死亡才会触发拉起新实例。这避免了以下问题:

- 进程 A 启动时 Reviver 还未启动 → Reviver 后启动时通过 `findInterface` 找到 A,但 `isAttached_=false`(因为还没 ping 通)。
- 此时 A 死亡 → death 通知到达 → 调用 `revive()` → 因 `wasAttached=false` 而**不**拉起新实例。
- 这避免了"双重启"竞态:Reviver 启动前进程已经死了,Reviver 启动后没必要再去拉一次——可能其他 Reviver 已经拉过了。

但 `deactivate()` 仍然被无条件调用,以清理定时器、复位 priority。`addr_` 也被清零,确保后续 birth 通知能正常设置新地址。

### 17.5 ping 周期与 handleTimeout

```cpp
// server/reviver/component_reviver.cpp  L252-267
void ComponentReviver::handleTimeout( TimerHandle /*handle*/, void * /*arg*/ )
{
    if (pingsToMiss_ > 0)
    {
        --pingsToMiss_;
        Mercury::UDPBundle bundle;
        bundle.startRequest( *pPingMessage_, this );
        bundle << priority_;
        pInterface_->send( addr_, bundle );
    }
    else
    {
        INFO_MSG( "ComponentReviver::handleTimeout: Missed too many\n" );
        this->revive();
    }
}
```

**算法**:
1. 每个 `pingPeriod_`(默认 100ms)触发一次 timeout。
2. 若 `pingsToMiss_ > 0`,递减并发送 ping(`pingsToMiss_` 初始等于 `maxPingsToMiss_`,默认 3)。
3. 若收到回复 `REVIVER_PING_YES`,`pingsToMiss_` 重置为 `maxPingsToMiss_`(见 `handleMessage` 下半部分)。
4. 若 `pingsToMiss_` 减到 0(连续 3 次没收到回复),触发 `revive()` 拉起新实例。

**默认配置**:`pingPeriod=0.1s`,`maxPingsToMiss=3`(由 `timeout=3.0 / pingPeriod=0.1 = 30` 推导出?不对,实际是 `timeout=3.0`,`timeoutInPings=0` 时按 `int(timeout / pingPeriod + 0.5)` 推导,所以 `3.0/0.1=30`,但代码注释 `maxPingsToMiss_( 3 )` 是构造函数默认值,实际由 `ReviverConfig::postInit()` 推导为 30)。

**注意**:这里 `bundle << priority_` 把 Reviver 的优先级塞进 ping 包,被监控进程的 `ReviverSubject` 会用它做主备仲裁(详见第十九章)。

### 17.6 handleMessage(双 overload):birth/death 与 ping 回复

```cpp
// server/reviver/component_reviver.cpp  L180-217  (InputMessageHandler 重载)
void ComponentReviver::handleMessage( const Mercury::Address & source,
    Mercury::UnpackedMessageHeader & header,
    BinaryIStream & data )
{
    MF_ASSERT( (header.identifier == pBirthMessage_->id()) ||
                (header.identifier == pDeathMessage_->id()) );

    Mercury::Address addr;
    data >> addr;

    if (header.identifier == pBirthMessage_->id())
    {
        addr_ = addr;  // 更新为最新地址(可能 PID/IP/port 变了)
        INFO_MSG( "ComponentReviver::handleMessage: %s at %s has started.\n", ... );
        return;
    }

    INFO_MSG( "ComponentReviver::handleMessage: %s at %s has died.\n", ... );

    if (addr == addr_)
    {
        this->revive();  // 当前监控的进程死了,触发恢复
    }
    else if (isAttached_)
    {
        ERROR_MSG( "ComponentReviver::handleMessage: %s component died at %s. Expected %s\n", ... );
    }
}

// L223-246  (ReplyHandler 重载,处理 ping 回复)
void ComponentReviver::handleMessage( const Mercury::Address & source,
    Mercury::UnpackedMessageHeader & header,
    BinaryIStream & data, void * arg )
{
    uint8 returnCode;
    data >> returnCode;
    if (returnCode == REVIVER_PING_YES)
    {
        pingsToMiss_ = maxPingsToMiss_;  // 重置

        if (!isAttached_)
        {
            Reviver::pInstance()->markAsDirty();
            INFO_MSG( "ComponentReviver: %s (%s) has attached.\n", ... );
            isAttached_ = true;
        }
    }
    else
    {
        this->deactivate();  // 别的 Reviver 抢占了,主动退让
    }
}
```

**两个重载的职责**:
- **3 参版**(InputMessageHandler):由 bwmachined 通过 birth/death listener 触发,数据流是 `Mercury::Address`(被监控进程的地址)。birth 时只更新 `addr_`,不激活;death 时若地址匹配则 `revive()`。
- **4 参版**(ReplyHandler):由 ping 请求的回复触发,数据流是 `uint8` 返回码。`YES` 重置计数 + 标记 attach;`NO` 调用 `deactivate()` 退让。

**关键细节**:`deactivate()` 内部调用 `markAsDirty()`,使下一个 REATTACH 周期打印 summary,让运维看到状态变化。

### 17.7 5 个特化类:MF_REVIVER_HANDLER 宏

```cpp
// server/reviver/component_reviver.cpp  L298-323
#define MF_REVIVER_HANDLER( CONFIG, COMPONENT, CREATE_WHAT )                \
    MF_REVIVER_HANDLER2( CONFIG, COMPONENT, COMPONENT, CREATE_WHAT )

#define MF_REVIVER_HANDLER2( CONFIG, COMPONENT, COMPONENT2, CREATE_WHAT )    \
class COMPONENT##Reviver : public ComponentReviver                          \
{                                                                           \
public:                                                                     \
    COMPONENT##Reviver() :                                                  \
        ComponentReviver( #CONFIG, #COMPONENT, #COMPONENT2 "Interface",     \
                CREATE_WHAT )                                               \
    {}                                                                      \
    virtual void initInterfaceElements()                                    \
    {                                                                       \
        pBirthMessage_ = &ReviverInterface::handle##COMPONENT##Birth;       \
        pDeathMessage_ = &ReviverInterface::handle##COMPONENT##Death;       \
        pPingMessage_ = &COMPONENT2##Interface::reviverPing;                \
    }                                                                       \
} g_reviverOf##COMPONENT;

MF_REVIVER_HANDLER( cellAppMgr, CellAppMgr, "cellappmgr" )
MF_REVIVER_HANDLER( baseAppMgr, BaseAppMgr, "baseappmgr" )
MF_REVIVER_HANDLER( dbAppMgr,   DBAppMgr,   "dbappmgr" )
MF_REVIVER_HANDLER( dbApp,      DBApp,      "dbapp" )
MF_REVIVER_HANDLER2( loginApp,   Login, LoginInt,   "loginapp" )
```

**5 个特化实例**:

| 全局变量名 | 类名 | configName | name | interfaceName | createParam |
|-----------|------|-----------|------|--------------|-------------|
| `g_reviverOfCellAppMgr` | `CellAppMgrReviver` | `cellAppMgr` | `CellAppMgr` | `CellAppMgrInterface` | `"cellappmgr"` |
| `g_reviverOfBaseAppMgr` | `BaseAppMgrReviver` | `baseAppMgr` | `BaseAppMgr` | `BaseAppMgrInterface` | `"baseappmgr"` |
| `g_reviverOfDBAppMgr` | `DBAppMgrReviver` | `dbAppMgr` | `DBAppMgr` | `DBAppMgrInterface` | `"dbappmgr"` |
| `g_reviverOfDBApp` | `DBAppReviver` | `dbApp` | `DBApp` | `DBAppInterface` | `"dbapp"` |
| `g_reviverOfLogin` | `LoginReviver` | `loginApp` | `Login` | `LoginIntInterface` | `"loginapp"` |

**为何使用宏**:每个特化类的逻辑高度雷同,只有 3 个 `InterfaceElement` 指针不同。宏展开避免了 5 份几乎相同的样板代码,同时保证全局变量名遵循 `g_reviverOf<COMPONENT>` 模式,使 `BW_REVIVER_MSGS` 宏可以引用。

**Login 的特殊处理**:`MF_REVIVER_HANDLER2( loginApp, Login, LoginInt, "loginapp" )`。这里 `COMPONENT=Login`、`COMPONENT2=LoginInt`、`CREATE_WHAT="loginapp"`。原因是 LoginApp 有两套接口:
- `LoginInterface`:对外的客户端接口(玩家登录入口)。
- `LoginIntInterface`:**内部接口**,供其他服务器进程访问(包括 `reviverPing`)。

Reviver 走内部接口以避免与客户端流量竞争。

**为何只监控 5 类进程,不监控 CellApp/BaseApp**:
- CellApp、BaseApp 是**多实例进程**,由 CellAppMgr、BaseAppMgr 负责创建与负载均衡。如果它们崩溃,管理器会感知(通过 waitpid + 内部 death listener)并按需重启。
- 5 类被监控进程都是**单例或关键管理器**:CellAppMgr/BaseAppMgr/DBAppMgr 是各自范围的单例,DBApp 是 DBAppMgr 选出的主 DBApp,LoginApp 虽然多实例但承担登录鉴权关键路径。

### 17.8 activate/deactivate 状态转换

```cpp
// server/reviver/component_reviver.cpp  L136-150
bool ComponentReviver::activate( ReviverPriority priority )
{
    isAttached_ = false;

    if (!timerHandle_.isSet() && (addr_.ip != 0))
    {
        pingsToMiss_ = maxPingsToMiss_;
        timerHandle_ = pDispatcher_->addTimer( pingPeriod_, this, NULL, "ComponentReviver" );
        priority_ = priority;
        return true;
    }
    return false;
}

// L156-174
bool ComponentReviver::deactivate()
{
    if (isAttached_)
    {
        Reviver::pInstance()->markAsDirty();
        INFO_MSG( "ComponentReviver: %s (%s) has detached\n", addr_.c_str(), name_.c_str() );
        isAttached_ = false;
    }

    if (timerHandle_.isSet())
    {
        timerHandle_.cancel();
        priority_ = 0;
        return true;
    }
    return false;
}
```

**activate 触发条件**:
- 定时器未启动(避免重复)
- `addr_.ip != 0`(已经通过 birth 通知或 `findInterface` 知道进程地址)

满足后:
1. `isAttached_ = false`(刚激活,还没 ping 通)
2. 重置 `pingsToMiss_`
3. 启动 ping 定时器
4. 记录 `priority_`

**deactivate 时机**:
- 收到 `REVIVER_PING_NO`(被抢占)
- death 通知触发 `revive()` 时调用
- 进程关闭时

**两次"has detached"日志的差异**:
- `deactivate()` 在 `isAttached_` 为 true 时打印 "has detached"
- `revive()` 在 `wasAttached` 为 true 时打印 "Reviving %s"
- 区别:detach 表示"我不再是该进程的 Reviver",revive 表示"我要拉起新实例"。detach 不一定 revive(可能是被抢占,主动让位)。

---

## 十八、双死亡检测机制

### 18.1 双渠道检测概述

Reviver 对被监控进程的死亡检测有**两条独立渠道**:

```
┌──────────────────────────────────────────────────────────────────┐
│  被监控进程                                                       │
│  (CellAppMgr 等)                                                  │
└──────┬────────────────────────────────────┬────────────────────┘
       │ SIGCHLD                          │ 停止回复 ping
       ▼                                  ▼
┌──────────────────────┐          ┌──────────────────────┐
│  本机 bwmachined     │          │  ComponentReviver    │
│  waitpid 检测退出    │          │  ping 超时检测        │
│  → death listener   │          │  (maxPingsToMiss 次) │
│    广播              │          │                      │
└──────┬───────────────┘          └──────────────────────┘
       │ NOTIFY_DEATH (UDP)
       ▼
┌──────────────────────────────────────────────────────────────┐
│  ComponentReviver.handleMessage (3 参重载,birth/death 通知) │
│  if (addr == addr_) revive();                                │
└──────────────────────────────────────────────────────────────┘
```

### 18.2 渠道一:bwmachined 广播 death

bwmachined 通过两条子渠道检测进程退出:

1. **SIGCHLD + waitpid**:`bwmachined` 是子进程的父进程(因为 fork 出来的),子进程退出时收到 SIGCHLD,`waitpid` 取回 exit code 并触发 `bwmachined.cpp` 中的 `notifyListenersDeath`。
2. **/proc/<pid>/stat 轮询**:对于非 bwmachined 直接 fork 的进程(如 cellapp fork 出的 baseapp,虽然这种场景在 BigWorld 中不常见),`updateProcessStats` 周期读 `/proc/<pid>/stat`,若读到 `state==Z`(zombie)或 `stat` 不存在,判定死亡。

**广播机制**:

```cpp
// server/tools/bwmachined/listeners.cpp  handleNotify (NotifyDeath)
void Listeners::handleNotify( bool isBirth, const ProcessInfo & info )
{
    // 取出该 uid + name 的所有 listener
    ...
    for (...)
    {
        // 拼接 preAddr_ + Address + postAddr_ 作为完整包
        ...
        // 发到 listener 的 srcAddr
    }
}
```

`preAddr_` 和 `postAddr_` 的设计见第十章,这里的关键是 **UDP 单发**——不保证送达。如果 listener 处于 GC 暂停、网络拥塞或包丢失,通知会丢失。

### 18.3 渠道二:ping 心跳超时

```cpp
// server/reviver/component_reviver.cpp  L252-267
void ComponentReviver::handleTimeout( TimerHandle /*handle*/, void * /*arg*/ )
{
    if (pingsToMiss_ > 0)
    {
        --pingsToMiss_;
        // 发 ping
    }
    else
    {
        INFO_MSG( "ComponentReviver::handleTimeout: Missed too many\n" );
        this->revive();
    }
}
```

**默认参数**(由 `reviver_config.cpp` 推导):
- `pingPeriod = 0.1s`(100ms)
- `timeout = 3.0s`
- `timeoutInPings = int(3.0 / 0.1 + 0.5) = 30`

所以一个被监控进程若连续 30 次 ping 没回复(3 秒),Reviver 会判定其死亡并触发 `revive()`。

**ping 超时检测的兜底作用**:
- 进程**假死**:网络正常但进程死循环 → SIGCHLD 不触发(进程未退出),但 ping 也无法回复 → 3 秒后 Reviver 拉起新实例。这是 bwmachined 无法做到的(bwmachined 看进程还活着)。
- 通知包丢失:death 广播 UDP 丢失 → ping 渠道仍能感知。
- 进程被强制 kill -9:SIGCHLD 立刻触发,death 广播先于 ping 超时(几毫秒 vs 3 秒)。

### 18.4 双渠道的协同

| 场景 | bwmachined death 广播 | Reviver ping 超时 | 谁先触发 revive |
|------|----------------------|------------------|----------------|
| 进程崩溃(SIGSEGV) | < 1ms 触发 | 3 秒后触发 | bwmachined 渠道 |
| 进程被 kill -9 | < 1ms 触发 | 3 秒后触发 | bwmachined 渠道 |
| 进程假死(死循环) | 不触发 | 3 秒后触发 | Reviver ping |
| 进程网络断开 | bwmachined 不感知 | 3 秒后触发 | Reviver ping |
| UDP 通知丢失 | 通知发了但丢失 | 3 秒后触发 | Reviver ping |
| 进程主动 exit() | < 1ms 触发 | 3 秒后触发 | bwmachined 渠道 |

**`wasAttached` 守门避免双触发**:
- 即使两个渠道都触发了 `revive()`,第二次调用因 `isAttached_==false`(已被 `deactivate()` 复位)而**不会**发送 `CreateMessage`。
- 但 `deactivate()` 仍会被调用,这是幂等的(定时器已 cancel,重复 cancel 无副作用)。

### 18.5 检测精度与延迟

| 渠道 | 最快响应 | 最慢响应 | 准确率 |
|------|---------|---------|--------|
| SIGCHLD | ~1ms | ~1ms | 100%(进程真的退出) |
| /proc stat 轮询 | 1 个轮询周期 | 1 个轮询周期 | 100% |
| death 广播 | 同 SIGCHLD | 同 SIGCHLD + 1 个 UDP 包 RTT | 99%(UDP 可能丢) |
| ping 超时 | 3s | 3s + 1 ping 周期 | 100%(进程不回复就触发) |

**网络分区场景**:
- Reviver 与被监控进程网络分区:Reviver ping 不通,3s 后判定死亡并 `revive()`。但被监控进程可能还活着,只是网络分区。
- 这会导致**双主**:旧进程还在处理业务,新进程被 bwmachined fork 出来也接受业务。
- 缓解:`shutDownOnRevive=true`(默认),Reviver 拉起新实例后**自己退出**,让集群里其他 Reviver 接管。详见第二十章。

---

## 十九、ReviverSubject 优先级仲裁

### 19.1 ReviverSubject 在被监控进程中的角色

`ReviverSubject` 是嵌入到**被监控进程**(CellAppMgr/BaseAppMgr/DBAppMgr/DBApp/LoginApp)中的单例对象,负责**仲裁多个 Reviver 谁是主**。它本身不是 Reviver 的一部分,而是 lib/server 中的通用组件,被 5 类被监控进程共同使用。

```cpp
// lib/server/reviver_subject.hpp  L14-37
class ReviverSubject : public Mercury::InputMessageHandler
{
public:
    ReviverSubject();
    void init( Mercury::NetworkInterface * pInterface, const char * componentName );
    void fini();

    static ReviverSubject & instance() { return instance_; }

private:
    virtual void handleMessage( const Mercury::Address & srcAddr,
            Mercury::UnpackedMessageHeader & header,
            BinaryIStream & data );

    Mercury::NetworkInterface *     pInterface_;
    Mercury::Address    reviverAddr_;
    uint64              lastPingTime_;
    ReviverPriority     priority_;

    int                 msTimeout_;

    static ReviverSubject instance_;
};

#define MF_REVIVER_PING_MSG()       \
        MERCURY_VARIABLE_MESSAGE( reviverPing, 2, &ReviverSubject::instance() )
```

**关键设计**:
- 单例模式(`static instance_`):每个进程只有一个 `ReviverSubject`。
- 通过 `MF_REVIVER_PING_MSG()` 宏注册 `reviverPing` 消息(2 字节负载 = 1 字节 priority + 1 字节回复 code)。
- 通过 `init()` 接受 `componentName`,以读取组件级配置 `reviver/<componentName>/subjectTimeout`。

### 19.2 init:配置超时与健全性检查

```cpp
// lib/server/reviver_subject.cpp  L44-65
void ReviverSubject::init( Mercury::NetworkInterface * pInterface,
                            const char * componentName )
{
    pInterface_ = pInterface;
    char buf[128];
    bw_snprintf( buf, sizeof(buf), "reviver/%s/subjectTimeout", componentName );

    msTimeout_ = int( BWConfig::get( buf,
                BWConfig::get( "reviver/subjectTimeout",
                    REVIVER_DEFAULT_SUBJECT_TIMEOUT ) ) * 1000 );
    INFO_MSG( "ReviverSubject::init: msTimeout_ = %d\n", msTimeout_ );

    bw_snprintf( buf, sizeof(buf), "reviver/%s/pingPeriod", componentName );
    if (int( BWConfig::get( buf,
            BWConfig::get( "reviver/pingPeriod",
                REVIVER_DEFAULT_PING_PERIOD ) ) * 1000 ) > msTimeout_)
    {
        CRITICAL_MSG( "ReviverSubject::init: ...subjectTimeout must be larger than pingPeriod." );
    }
}
```

**默认值**(来自 `reviver_common.hpp`):
```cpp
// lib/server/reviver_common.hpp  L13-16
const ReviverPriority REVIVER_PING_NO  = 0;
const ReviverPriority REVIVER_PING_YES = 1;
const float REVIVER_DEFAULT_SUBJECT_TIMEOUT = 0.2f;   // 200ms
const float REVIVER_DEFAULT_PING_PERIOD = 0.1f;        // 100ms
```

**配置优先级**:
1. `reviver/<componentName>/subjectTimeout` (如 `reviver/CellAppMgr/subjectTimeout`)
2. `reviver/subjectTimeout`
3. 默认 0.2s

**健全性约束**:`pingPeriod < subjectTimeout`(否则即使 Reviver 每 100ms ping 一次,被监控进程 200ms 后误判超时切换主)。约束不满足时 `CRITICAL_MSG` 中止进程。

### 19.3 handleMessage:仲裁算法

```cpp
// lib/server/reviver_subject.cpp  L84-154
void ReviverSubject::handleMessage( const Mercury::Address & srcAddr,
        Mercury::UnpackedMessageHeader & header,
        BinaryIStream & data )
{
    if (pInterface_ == NULL)
    {
        ERROR_MSG( "ReviverSubject::handleMessage: ReviverSubject not initialised\n" );
        return;
    }

    uint64 currentPingTime = timestamp();

    ReviverPriority priority;
    data >> priority;

    bool accept = (reviverAddr_ == srcAddr);    // 来自当前主 Reviver

    if (!accept)
    {
        if (priority < priority_)              // 更高优先级(数值更小)
        {
            if (priority_ == 0xff)             // 0xff 表示尚未指定主
            {
                INFO_MSG( "ReviverSubject::handleMessage: Reviver is %s (Priority %d)\n",
                            srcAddr.c_str(), priority );
            }
            else
            {
                INFO_MSG( "ReviverSubject::handleMessage: %s has a better priority (%d)\n",
                            srcAddr.c_str(), priority );
            }
            accept = true;
        }
        else
        {
            uint64 delta = (currentPingTime - lastPingTime_) * uint64(1000);
            delta /= stampsPerSecond();
            int msBetweenPings = int(delta);

            if (msBetweenPings > msTimeout_)
            {
                BW::string oldAddr = reviverAddr_.c_str();
                INFO_MSG( "ReviverSubject::handleMessage: %s timed out (%d ms). Now using %s\n",
                            oldAddr.c_str(), msBetweenPings, srcAddr.c_str() );
                accept = true;
            }
        }
    }

    Mercury::UDPBundle bundle;
    bundle.startReply( header.replyID );

    if (accept)
    {
        reviverAddr_ = srcAddr;
        lastPingTime_ = currentPingTime;
        priority_ = priority;
        bundle << REVIVER_PING_YES;
    }
    else
    {
        bundle << REVIVER_PING_NO;
    }

    pInterface_->send( srcAddr, bundle );
}
```

### 19.4 三种接受(accept)情形

仲裁算法有三种触发 `accept=true` 的情形:

**情形 A:来自当前主 Reviver**
```cpp
bool accept = (reviverAddr_ == srcAddr);
```
只要 ping 来自当前已绑定的 `reviverAddr_`,无条件接受。这是最常见的"主 Reviver 心跳"场景,无需任何额外检查。

**情形 B:更高优先级的 Reviver 抢占**
```cpp
if (priority < priority_)    // 数值更小 = 优先级更高
```
Reviver 的 `priority_` 数值范围是 1-255(0 表示未激活)。`priority_==0xff` 是初始值,表示"尚未指定主"。当某个 Reviver 发来 ping 且 `priority < priority_`,被监控进程切换主 Reviver 为它。

**为什么数值小代表高优先级**:这是 BigWorld 的约定。Reviver 启动时按 `++priority`(从 1 开始)分配,所以 priority=1 是最早激活的、优先级最高的。

**情形 C:当前主 Reviver 超时,新 Reviver 接管**
```cpp
if (msBetweenPings > msTimeout_)
```
即使新 ping 的 priority 不更高,只要当前主 Reviver 超过 `msTimeout_`(默认 200ms)没发 ping,就切换为新 Reviver。

**这三种情形的覆盖范围**:
- 情形 A 保证主 Reviver 持续工作。
- 情形 B 处理"运维手动调整 Reviver 优先级"或"新 Reviver 启动时配置更高优先级"。
- 情形 C 处理"主 Reviver 崩溃后备用 Reviver 接管"——这是高可用的关键路径。

### 19.5 优先级数值语义

```cpp
// server/reviver/reviver.cpp  L195-209
ReviverPriority priority = 0;
ComponentRevivers::iterator iter = components_.begin();
while (iter != endIter)
{
    if ((*iter)->isEnabled())
    {
        (*iter)->activate( ++priority );
    }
    ++iter;
}
```

Reviver 启动时按顺序给每个 `ComponentReviver` 分配 `priority`(`1, 2, 3, 4, 5`)。但因为不同 Reviver 启动顺序可能不同,且每个 Reviver 只监控自己机器上有的组件,所以:

| Reviver 实例 | 监控组件 | CellAppMgr priority | BaseAppMgr priority |
|--------------|---------|---------------------|---------------------|
| Reviver@A | CellAppMgr | 1 | (不监控) |
| Reviver@B | CellAppMgr, BaseAppMgr | 1 | 2 |

如果 Reviver@A 是 CellAppMgr 的主(priority=1),Reviver@B 也监控 CellAppMgr(priority=1,但是它激活顺序中第一个),那么 CellAppMgr 看到 Reviver@B 的 priority=1 时:
- `priority < priority_` 不成立(1 < 1 是 false)
- 进入情形 C 检查,如果 Reviver@A 还在 200ms 内 ping 过,不切换
- 如果 Reviver@A 超过 200ms 没 ping,切换为 Reviver@B

**REATTACH 优先级重排**(`reviver.cpp` `handleTimeout` `TIMEOUT_REATTACH`):

每 10 秒(默认 `reattachPeriod=10`),Reviver 重排优先级,把 active 的 ComponentReviver 按当前 priority 排序,deactive 的随机洗牌后追加:

```cpp
// server/reviver/reviver.cpp  L332-356
Map::iterator mapIter = activeSet.begin();
ReviverPriority priority = 0;
while (mapIter != activeSet.end())
{
    ++priority;
    if (mapIter->first != priority)
    {
        mapIter->second->priority( priority );
    }
    ++mapIter;
}

std::random_shuffle( deactive.begin(), deactive.end() );
iter = deactive.begin();
endIter = deactive.end();
while (iter != endIter)
{
    (*iter)->activate( ++priority );
    ++iter;
}
```

**重排的目的**:
- 让 active 的 ComponentReviver 占据 1~N 的小数值(高优先级)。
- deactive 的(可能因被抢占而退出的)重新激活,但 priority 更大(低优先级),准备好抢占备用。

### 19.6 边界情况:0xff 初始优先级

```cpp
// lib/server/reviver_subject.cpp  L32-34
ReviverSubject::ReviverSubject() :
    pInterface_( NULL ),
    reviverAddr_( 0, 0 ),
    lastPingTime_( 0 ),
    priority_( 0xff ),
    msTimeout_( 0 )
{
}
```

`priority_` 初始 0xff,语义是"还没有任何 Reviver 注册"。第一个发来 ping 的 Reviver(无论 priority 多少)都会被接受(因为 `priority < 0xff` 恒成立),打印 "Reviver is %s" 而不是 "%s has a better priority"(因为这是首次绑定)。

### 19.7 拒绝(REVIVER_PING_NO)的后果

```cpp
bundle << REVIVER_PING_NO;
pInterface_->send( srcAddr, bundle );
```

被监控进程回复 `REVIVER_PING_NO` 后:

```cpp
// server/reviver/component_reviver.cpp  L240-245
else
{
    this->deactivate();  // 别的 Reviver 抢占了,主动退让
}
```

ComponentReviver 调用 `deactivate()`:
- 取消定时器
- `priority_ = 0`
- `isAttached_ = false`
- 打印 "has detached" 日志

之后该 ComponentReviver 进入 WATCHING 但未 ATTACHED 状态,等下一次 REATTACH 周期重新激活为低优先级备用。

### 19.8 仲裁的时间维度

```
时间轴       t=0            t=100ms        t=200ms        t=300ms
            │              │              │              │
Reviver A   ping(prio=1)   ping(prio=1)   ❌ 崩溃        -
            │              │              │
被监控进程   accept         accept         -              -
            (reviverAddr=A) │              │              │
            │              │              │              │
Reviver B   ping(prio=2)   ping(prio=2)   ping(prio=2)   ping(prio=2)
            (拒绝,因为     (拒绝,因为     (情形 C:       (accept=true,
             priority 2    priority 2     200ms 超时)    reviverAddr=B)
             不 < 1)       不 < 1)
```

**关键观察**:
- 在 t=200ms,Reviver A 崩溃但被监控进程不知道,直到 t=300ms 时 Reviver B 的 ping 触发情形 C(超时切换)。
- 实际上,`msTimeout_=200ms` 是从 `lastPingTime_` 开始计算。如果 t=100ms 时 Reviver A 的 ping 被接受,`lastPingTime_=t=100ms`,到 t=300ms 时 `delta=200ms`,刚好等于 `msTimeout_`(200ms),不切换;到 t=400ms 时 `delta=300ms > 200ms`,切换。

所以实际切换延迟是 `2 * msTimeout_` ~ `3 * msTimeout_`(400-600ms),取决于 ping 周期。

---

## 二十、主备切换 shutDownOnRevive

### 20.1 shutDownOnRevive 设计意图

```cpp
// server/reviver/reviver_config.cpp  L18
BW_OPTION( bool, shutDownOnRevive, true );
```

默认 `true`。语义:**Reviver 拉起新实例后立即退出**。

这个看似反直觉的设计是为了解决**双主问题**:

```
场景:Reviver A 监控 CellAppMgr,CellAppMgr 网络分区
1. Reviver A ping 不通 CellAppMgr(网络分区)
2. Reviver A 3 秒后判定死亡,发 CreateMessage 给 bwmachined
3. bwmachined fork 出新 CellAppMgr'
4. 旧 CellAppMgr 还活着,网络恢复后两个 CellAppMgr 同时存在
5. 集群混乱!
```

**shutDownOnRevive 的缓解方案**:
- Reviver A 拉起新实例后**自己退出**。
- 集群里其他机器上的 Reviver B(配置相同监控 CellAppMgr)接管为新主 Reviver。
- Reviver B 看到新 CellAppMgr' 的 birth 通知,开始 ping 它,完成仲裁。

**这不是完美方案**:
- 旧 CellAppMgr 还在,可能导致双主。
- 真正的解决需要靠 CellAppMgr 自身的"主选举"逻辑(基于 DBAppMgr 的协调),而不是 Reviver。

### 20.2 revive() 的 shutDownOnRevive 流程

```cpp
// server/reviver/reviver.cpp  L440-474
void Reviver::revive( const char * createComponent )
{
    if (shuttingDown_)
    {
        INFO_MSG( "Reviver::revive: Trying to revive a process while shutting down.\n" );
        return;
    }

    CreateMessage cm;
    cm.uid_ = getUserId();
    cm.recover_ = 1;
    cm.name_ = createComponent;
    cm.config_ = BW_COMPILE_TIME_CONFIG;

    uint32 srcaddr = 0, destaddr = htonl( 0x7f000001U );
    if (cm.sendAndRecv( srcaddr, destaddr ) != Mercury::REASON_SUCCESS)
    {
        ERROR_MSG( "ComponentReviver::revive: Could not send request.\n" );
    }

    if (Config::shutDownOnRevive())
    {
        shuttingDown_ = true;
        this->shutDown();
    }
}
```

**4 步流程**:
1. **shuttingDown_ 守门**:若已在退出中,直接返回(避免重复退出)。
2. **构造 CreateMessage**:
   - `uid_ = getUserId()`:以当前用户身份启动子进程
   - `recover_ = 1`:**关键参数**,告诉新进程"你是被恢复的,需要从 DB 加载状态"
   - `name_ = createComponent`:如 "cellappmgr"
   - `config_ = BW_COMPILE_TIME_CONFIG`:编译期配置名
3. **同步发送**:`sendAndRecv` 阻塞等待 bwmachined 回复。bwmachined 收到后 fork 子进程并返回 ack。
4. **若 shutDownOnRevive=true**,设置 `shuttingDown_=true` 并调用 `shutDown()`。

### 20.3 shutDown() 详解

```cpp
// server/reviver/reviver.cpp  L419-434
void Reviver::shutDown()
{
    shuttingDown_ = true;
    mainDispatcher_.breakProcessing();

    ComponentRevivers::iterator iter = components_.begin();
    while (iter != components_.end())
    {
        if ((*iter)->isEnabled())
        {
            (*iter)->deactivate();
        }
        ++iter;
    }
}
```

**3 步**:
1. 标记 `shuttingDown_=true`(防止 `revive()` 重入)
2. `breakProcessing()`:让 `mainDispatcher_.processContinuous()` 退出,主循环结束
3. 遍历所有 ComponentReviver,deactivate 已启用的(取消定时器、清理状态)

`breakProcessing()` 后,`ServerApp::run()` 的主循环退出,Reviver 进程进入析构阶段,`~Reviver()` 取消 timerHandle 与 tickTimer,进程退出。

### 20.4 -recover 启动参数的传递

`CreateMessage.recover_=1` 被 bwmachined 转化为子进程的命令行参数 `-recover 1`:

```cpp
// server/tools/bwmachined/bwmachined.cpp  handleCreateMessage
// (具体实现见第八章)
// 最终调用 execve 时 argv 类似:
//   cellappmgr -recover 1 -config <config>
```

被恢复进程在 main() 中解析 `-recover` 参数,知道自己是被 Reviver 拉起的,需要:

1. **加载持久化状态**:CellAppMgr 从 BaseAppMgr 同步空间信息;DBApp 从数据库恢复 entity 状态;LoginApp 重新加载会话表。
2. **跳过首次初始化**:某些初始化逻辑只在全新启动时跑(如 CellAppMgr 首次创建默认 space),`-recover` 时跳过。
3. **通知其他进程**:`-recover` 进程通过 birth 通知宣告自己上线,其他进程感知到新主。

### 20.5 不开启 shutDownOnRevive 的场景

```cpp
// 在 bw.xml 中
<reviver>
    <shutDownOnRevive> false </shutDownOnRevive>
</reviver>
```

某些场景下运维可能希望:
- Reviver 拉起新实例后**继续运行**,继续监控其他组件。
- 避免每次 revive 都要重启 Reviver 自身(可能因为某组件频繁崩溃导致 Reviver 频繁重启)。
- Reviver 自身可能监控多个组件,只为一个 revive 退出整个 Reviver 不划算。

**风险**:失去了双主缓解,需要更高可靠的网络与进程隔离。

### 20.6 主备切换的完整时序

```
t=0    CellAppMgr@M1 网络分区
t=3s   Reviver@M1 ping 超时,触发 revive()
t=3s   Reviver@M1 → bwmachined@M2: CreateMessage(cellappmgr, recover=1)
t=3s   bwmachined@M2 fork → CellAppMgr'@M2
t=3s   CellAppMgr'@M2 启动,broadcast birth 通知
t=3s   Reviver@M1 (shutDownOnRevive=true) → shutDown() → 进程退出
t=3s   Reviver@M2 收到 CellAppMgr' birth 通知 → addr_ 更新
t=3s+ε Reviver@M2 ping CellAppMgr' → accept → 成为新主 Reviver
t=3s+ε CellAppMgr' 从 DBAppMgr 同步状态 → 处理业务
t=10s  CellAppMgr@M1 网络恢复,广播 birth
       → 集群出现两个 CellAppMgr@M1 与 CellAppMgr'@M2
       → CellAppMgr 自身的主选举逻辑介入(基于 DBAppMgr 协调)
       → 旧 CellAppMgr@M1 通常会主动 shutDown(发现自己不是主)
```

**双主窗口**:`t=10s`(网络恢复) 到 旧 CellAppMgr 退出,这段时间是双主风险窗口。`shutDownOnRevive` 不能消除这个窗口,只能确保 Reviver 自身不会重复拉起。

---

## 二十一、Reviver 与 bwmachined 的协作

### 21.1 协作拓扑

```
┌─────────────────────────────────────────────────────────────────────────┐
│  机器 A                                                                  │
│  ┌─────────────────┐                                                     │
│  │ Reviver (用户 U)│──┐                                                  │
│  │ 5 个 Component │  │ 1. ProcessStatsMessage (findInterface)            │
│  │ Reviver       │  ├──────────────────────────►┐                         │
│  │ 优先级仲裁    │  │                          │                         │
│  └───────────────┘  │ 2. ListenerMessage (birth/death)                  │
│       ▲             ├──────────────────────────►┌                         │
│       │              │                          │                         │
│       │              │ 3. CreateMessage         │                         │
│       │              │   (uid=U, recover=1)      │                         │
│       │              ├──────────────────────────►│                         │
│       │              │                          ▼                         │
│       │              │             ┌──────────────────────────┐          │
│       │              │             │  bwmachined (root)       │          │
│       │              │             │  - fork/exec             │          │
│       │              │             │  - setuid(U)             │          │
│       │              │             │  - birth/death 广播      │          │
│       │              │             └──────────┬───────────────┘          │
│       │              │                        │                          │
│       │ birth/death  │                        │ fork                     │
│       │ UDP 通知     │◄───────────────────────┤                          │
│       │              │                        │                          │
│       │              │                        ▼                          │
│       │              │             ┌──────────────────────────┐          │
│       │              │             │  CellAppMgr (用户 U)    │          │
│       │              │             │  -reviverPing handler   │          │
│       │              │ 4. reviverPing (priority=N)           │          │
│       │              ├─────────────────────────────────────►│            │
│       │              │ 5. reply: REVIVER_PING_YES/NO         │            │
│       │              │◄─────────────────────────────────────┤            │
│       │              │             └──────────────────────────┘          │
│       │              │                                                     │
│       │ ping 回复     │                                                     │
│       │(通过 Mercury │                                                     │
│       │ 回复机制)    │                                                     │
│       └──────────────┘                                                     │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

### 21.2 协作的 5 类消息流

| 流向 | 消息类型 | 用途 | 时机 |
|------|---------|------|------|
| Reviver → bwmachined | `ProcessStatsMessage` | `findInterface` 查找当前被监控进程地址 | init 时(每次 Reviver 启动) |
| Reviver → bwmachined | `ListenerMessage` | 注册 birth/death 监听器 | init 时 |
| Reviver → bwmachined | `CreateMessage` | 拉起新进程(recover=1) | revive() 触发时 |
| bwmachined → Reviver | `NOTIFY_BIRTH` / `NOTIFY_DEATH` | birth/death 通知 | 进程上下线时 |
| Reviver → 被监控进程 | `reviverPing`(Mercury 业务消息) | 主备仲裁 | 每 pingPeriod(100ms) |

### 21.3 init 阶段:双向握手

Reviver 启动时的 `init()`(详见 `reviver.cpp` L59-222)分多步:

1. **ServerApp::init**:基础初始化。
2. **ReviverInterface::registerWithInterface**:把 ReviverInterface(处理 birth/death 的 Mercury 接口)绑定到本地 interface_。
3. **ReviverInterface::registerWithMachined**:发 `ProcessMessage` 给 bwmachined,告诉它"我是 Reviver 进程"。bwmachined 把 Reviver 加入进程表。
4. **遍历 ComponentRevivers**(由 IntrusiveObject 自注册的 5 个特化实例),对每个 enabled 的:
   - 调用 `(*iter)->init()`,内部:
     - 发 `ProcessStatsMessage` 查找当前被监控进程(同步阻塞,最多重试 4 次)。
     - 发 `ListenerMessage` 注册 birth/death listener。
5. **queryMachinedSettings**:发 `TagsMessage` 查询 bwmachined 的 `Components` tag,确认本机被允许运行哪些组件类型。
6. **addTimer**:启动 REATTACH 定时器(10s)与 TICK 定时器(1ms 周期,处理事件循环)。

### 21.4 运行时:ping 与超时

进入主循环后,每个 ComponentReviver 每 100ms:
1. `handleTimeout` 触发。
2. 递减 `pingsToMiss_`,通过 Mercury 发 `reviverPing` 给被监控进程。
3. 被监控进程的 `ReviverSubject::handleMessage` 处理,回复 `YES`/`NO`。
4. ComponentReviver 的 `handleMessage`(4 参 ReplyHandler 重载)处理回复,重置或退让。

每 10s,REATTACH 定时器触发 `Reviver::handleTimeout(TIMEOUT_REATTACH)`:
1. 重新读取 `g_pComponentRevivers`(可能有新组件被启用)。
2. 按 priority 排序 active 集合,重排 priority(1, 2, 3, ...)。
3. 随机洗牌 deactive 集合,追加 activate。
4. 若 `isDirty_`,打印当前 attached 组件 summary。

### 21.5 revive 阶段:委托 bwmachined

Reviver 自身**不调用 fork/exec**——它发 `CreateMessage` 给本机 bwmachined,后者负责:

```cpp
// server/reviver/reviver.cpp  L450-454
CreateMessage cm;
cm.uid_ = getUserId();
cm.recover_ = 1;
cm.name_ = createComponent;
cm.config_ = BW_COMPILE_TIME_CONFIG;
```

**4 个关键字段**:
- `uid_`:目标用户 ID,bwmachined 会 `setuid` 到该用户启动子进程。
- `recover_`:1 表示这是恢复启动,bwmachined 在 argv 中加 `-recover 1`。
- `name_`:进程类型名,如 "cellappmgr",bwmachined 在 `bwmachined.conf` 中查找对应可执行文件路径。
- `config_`:编译期配置名,影响子进程读取哪个 `bw.xml`。

bwmachined 收到 `CreateMessage` 后:
1. 在 `bwmachined.conf` 中找到 `<name_>` 对应的可执行路径(详见第八章)。
2. fork → 子进程中 setuid(uid_) → execve 启动二进制。
3. 父进程把子进程的 PID 加入进程表,广播 birth 通知。
4. 同步回复 Reviver 一个 ack(`sendAndRecv` 阻塞等的就是这个)。

### 21.6 隔离与权限边界

| 维度 | Reviver | bwmachined |
|------|---------|------------|
| 用户身份 | 普通用户(运行 Reviver 的用户) | root(必须) |
| 网络绑定 | 任意可用端口 | PORT_MACHINED=19289 |
| 能否 fork | 不能(非 root) | 能(root) |
| 能否 setuid | 不能 | 能 |
| 启动时机 | 任意(机器启动后) | 系统启动早期(/etc/init.d) |
| 生命周期 | 可重启(主备切换) | 长驻(关机才退) |
| 业务感知 | 知道监控哪些组件 | 不感知业务 |

**这种隔离的好处**:
- Reviver 进程崩溃不影响 bwmachined,bwmachined 仍可被其他 Reviver 接管。
- Reviver 不需要 root,普通用户即可启动,降低权限放大风险。
- bwmachined 集中管理"易错的特权操作"(setuid、fork、文件描述符继承),Reviver 只发请求。

---

## 二十二、被监控进程注册方式

### 22.1 5 类被监控进程的注册点

被监控进程(CellAppMgr/BaseAppMgr/DBAppMgr/DBApp/LoginApp)在自身 `init()` 流程中调用 `ReviverSubject::init()` 与 `MF_REVIVER_PING_MSG()` 注册,使自身可被 Reviver ping。下面是 5 个进程的注册点行号:

| 进程 | 文件 | 行号 | 注册代码片段 |
|------|------|------|--------------|
| CellAppMgr | `server/cellappmgr/cellappmgr.cpp` | 183 | `ReviverSubject::init( &interface_, "CellAppMgr" ); MF_REVIVER_PING_MSG();` |
| BaseAppMgr | `server/baseappmgr/baseappmgr.cpp` | 365 | `ReviverSubject::init( &interface_, "BaseAppMgr" ); MF_REVIVER_PING_MSG();` |
| DBAppMgr | `server/dbappmgr/dbappmgr.cpp` | 236 | `ReviverSubject::init( &interface_, "DBAppMgr" ); MF_REVIVER_PING_MSG();` |
| DBApp | `server/dbapp/dbapp.cpp` | 778 | `ReviverSubject::init( &interface_, "DBApp" ); MF_REVIVER_PING_MSG();` |
| LoginApp | `server/loginapp/loginapp.cpp` | 270 | `ReviverSubject::init( &interface_, "LoginApp" ); MF_REVIVER_PING_MSG();` |

**注册流程**:
1. 调用 `ReviverSubject::init(&interface_, "<componentName>")`:
   - 把 `interface_` 保存到 `pInterface_`(用于回复 ping)。
   - 读取 `reviver/<componentName>/subjectTimeout` 配置,设置 `msTimeout_`。
   - 检查 `pingPeriod < subjectTimeout`,否则 CRITICAL_MSG。
2. 调用 `MF_REVIVER_PING_MSG()` 宏:
   ```cpp
   #define MF_REVIVER_PING_MSG()       \
       MERCURY_VARIABLE_MESSAGE( reviverPing, 2, &ReviverSubject::instance() )
   ```
   该宏展开为 `MERCURY_VARIABLE_MESSAGE` 调用,把 `reviverPing` 消息(2 字节负载)绑定到 `ReviverSubject::instance()` 的 `handleMessage` 上。

### 22.2 MF_REVIVER_PING_MSG 宏展开

`MERCURY_VARIABLE_MESSAGE` 是 Mercury 框架的消息注册宏,展开后大致等价于:

```cpp
static Mercury::InterfaceElement g_reviverPingIE(
    "reviverPing",                            // 消息名
    2,                                        // 负载大小(1 字节 priority + 1 字节回复 code)
    &ReviverSubject::instance(),              // handler 对象
    &ReviverSubject::handleMessage             // handler 函数
);
g_reviverPingIE.registerWith( interface );   // 注册到 interface
```

**为什么是 2 字节**:
- 请求方向(Reviver → 被监控):1 字节 `ReviverPriority priority`。
- 回复方向(被监控 → Reviver):1 字节 `uint8 returnCode`(REVIVER_PING_YES=1 或 NO=0)。

Mercury 的 `startReply` 机制使用 header.replyID 关联请求与回复,不需要在负载中放请求 ID。

### 22.3 被监控进程的注册时机

5 个进程都在自身 `init()` 末尾注册 ReviverSubject。这是因为:

1. **必须先初始化 NetworkInterface**:ReviverSubject 需要持有 `pInterface_` 指针用于回复,所以必须在 interface_ 创建后注册。
2. **必须在主循环开始前**:消息处理需要 EventDispatcher 运行,但注册本身不依赖。
3. **可以延后到 ServerApp::init 后段**:因为 Reviver 通常稍后才会 ping 它,即使延后几毫秒注册也不会丢消息(Reviver 的 `findInterface` 有重试 4 次,每次 1 秒)。

### 22.4 多 Reviver 共存时的注册

虽然每个被监控进程**只调用一次** `ReviverSubject::init`,但**多个 Reviver 可以同时 ping 它**。`ReviverSubject::handleMessage` 通过比较 srcAddr 与 priority 决定接受谁。这意味着:

- Reviver A(主)每 100ms ping,被接受。
- Reviver B(备,更低优先级)每 100ms 也 ping,被拒绝(返回 NO)。
- Reviver B 的 ComponentReviver 收到 NO 后 `deactivate()`,停止 ping。
- 等 Reviver A 崩溃后,Reviver B 在 REATTACH 周期(10s 内)重新 activate,继续 ping,这次因为超时切换被接受。

**ReviverSubject 不需要"反注册"**:
- 被监控进程退出时,ReviverSubject 析构,无需通知任何 Reviver。
- Reviver 通过 death listener 或 ping 超时感知,触发 revive。

### 22.5 Tags 与被监控进程的 Components 关系

bwmachined 启动时读取 `bwmachined.conf`,设置 `Components` tag 列出本机可运行的组件类型(如 `cellappmgr baseappmgr dbapp`)。Reviver 启动时通过 `queryMachinedSettings()` 询问本机 Components,只监控列出的组件:

```cpp
// server/reviver/reviver.cpp  L228-265
bool Reviver::TagsHandler::onTagsMessage( TagsMessage &tm, uint32 addr )
{
    if (tm.exists_)
    {
        Tags &tags = tm.tags_;
        ComponentRevivers::iterator iter = reviver_.components_.begin();
        ComponentRevivers::iterator endIter = reviver_.components_.end();

        while (iter != endIter)
        {
            ComponentReviver & component = **iter;

            if (std::find( tags.begin(), tags.end(), component.createName() )
                != tags.end() ||
                std::find( tags.begin(), tags.end(), component.configName() )
                != tags.end())
            {
                component.isEnabled( true );
            }
            else
            {
                CONFIG_INFO_MSG( "\t%s disabled via bwmachined's Components tags\n",
                            component.name().c_str() );
                component.isEnabled( false );
            }
            ++iter;
        }
    }
    else
    {
        CONFIG_ERROR_MSG( "Reviver::init: BWMachined has no Components tags\n" );
    }
    return false;
}
```

**双匹配逻辑**:tag 既匹配 `createName`("cellappmgr",小写,与 CreateMessage 的 `name_` 一致),也匹配 `configName`("cellAppMgr",驼峰,与 BWConfig key 一致)。这给运维两种风格的配置选择。

### 22.6 bwmachined.conf 中的 Components tag 配置

`bwmachined.conf` 示例:
```
# /etc/bwmachined.conf
components = cellappmgr baseappmgr dbappmgr dbapp loginapp
```

或者通过 tags file:
```
# /var/run/bwmachined.tags
Components = cellappmgr baseappmgr
```

bwmachined 启动时读取该配置,在内存中维护 `Tags` 映射。Reviver 询问时,返回 `Components` tag 列表。

---

## 二十三、配置项详解

### 23.1 ReviverConfig 完整配置项

```cpp
// server/reviver/reviver_config.hpp  L9-16
class ReviverConfig : public ServerAppConfig
{
public:
    static ServerAppOption< float > reattachPeriod;
    static ServerAppOption< float > pingPeriod;
    static ServerAppOption< float > subjectTimeout;
    static ServerAppOption< bool > shutDownOnRevive;
    static ServerAppOption< int > timeoutInPings;
    static ServerAppOption< float > timeout;
    static bool postInit();
};
```

```cpp
// server/reviver/reviver_config.cpp  L15-20
BW_OPTION_RO( float, reattachPeriod, 10.f );
BW_OPTION( float, pingPeriod, REVIVER_DEFAULT_PING_PERIOD );         // 0.1
BW_OPTION( float, subjectTimeout, REVIVER_DEFAULT_SUBJECT_TIMEOUT );  // 0.2
BW_OPTION( bool, shutDownOnRevive, true );
BW_OPTION( float, timeout, 3.0 );
BW_OPTION( int, timeoutInPings, 0 );
```

| 配置项 | 类型 | 默认值 | 含义 |
|--------|------|--------|------|
| `reviver/reattachPeriod` | float | 10.0s | REATTACH 周期,重排 ComponentReviver 优先级 |
| `reviver/pingPeriod` | float | 0.1s(100ms) | ComponentReviver ping 周期 |
| `reviver/subjectTimeout` | float | 0.2s(200ms) | ReviverSubject 主 Reviver 超时,超过则切换 |
| `reviver/shutDownOnRevive` | bool | true | revive 后是否退出 Reviver 自身 |
| `reviver/timeoutInPings` | int | 0(自动推导) | ping 容忍丢失次数,0 表示从 timeout 推导 |
| `reviver/timeout` | float | 3.0s | Reviver 判定被监控进程死亡的总超时 |

### 23.2 postInit:timeoutInPings 自动推导

```cpp
// server/reviver/reviver_config.cpp  L26-60
bool ReviverConfig::postInit()
{
    bool result = ServerAppConfig::postInit();

    if (result)
    {
        if (ReviverConfig::timeoutInPings() == 0)
        {
            timeoutInPings.set( int( timeout() / pingPeriod() + 0.5f ) );

            if (timeoutInPings() < 1)
            {
                ERROR_MSG( "ReviverConfig::postInit: reviver/timeout is too "
                            "small. timeout = %.2f. pingPeriod = %.2f\n",
                            timeout(), pingPeriod() );
                result = false;
            }
        }
        else
        {
            INFO_MSG( "ReviverConfig::postInit: "
                "The reviver/timeoutInPings option is deprecated. Use "
                "reviver/timeout instead.\n" );
        }

        if (pingPeriod() > subjectTimeout())
        {
            CRITICAL_MSG( "ReviverConfig::postInit: "
                "The revier/subjectTimeout must be larger than "
                "reviver/pingPeriod." );
        }
    }
    return result;
}
```

**推导公式**:`timeoutInPings = int(timeout / pingPeriod + 0.5)`(四舍五入)。

**默认值推导**:`3.0 / 0.1 + 0.5 = 30.5 → int = 30`。

所以默认 `maxPingsToMiss_ = 30`,即连续 30 次 ping(3 秒)没回复才判定死亡。

**deprecated warning**:如果运维显式配置了 `timeoutInPings`,Reviver 打印 deprecated 警告,推荐改用 `timeout`。这是因为 `timeout` 更直观(秒),而 `timeoutInPings` 是间接的(需要乘以 pingPeriod)。

### 23.3 组件级配置覆盖

每个 ComponentReviver 在 `init()` 中读取组件级配置:

```cpp
// server/reviver/component_reviver.cpp  L73-90
float pingPeriodInSeconds =
    BWConfig::get( (prefix + configName_ + "/pingPeriod").c_str(),
        ReviverConfig::pingPeriod() );

if (pingPeriodInSeconds >
        BWConfig::get( (prefix + configName_ + "/subjectTimeout").c_str(),
            ReviverConfig::subjectTimeout() ))
{
    CRITICAL_MSG( "ComponentReviver::init: ...subjectTimeout must be larger..." );
}

pingPeriod_ = int( pingPeriodInSeconds * 1000000 );

maxPingsToMiss_ =
    BWConfig::get( (prefix + configName_ + "/timeoutInPings").c_str(),
                        ReviverConfig::timeoutInPings() );
```

**配置路径**:
- `reviver/cellAppMgr/pingPeriod`
- `reviver/cellAppMgr/subjectTimeout`
- `reviver/cellAppMgr/timeoutInPings`

类似地,ReviverSubject 也读取:
- `reviver/CellAppMgr/subjectTimeout`
- `reviver/CellAppMgr/pingPeriod`

**注意大小写差异**:
- ComponentReviver 的 configName 是 `cellAppMgr`(驼峰,首字母小写)。
- ReviverSubject 的 componentName 是 `CellAppMgr`(驼峰,首字母大写)。
- 这两者**不匹配**,因为它们分别由不同代码路径生成(ComponentReviver 用 `#CONFIG` 宏参数,ReviverSubject 用 `"CellAppMgr"` 字符串字面量)。
- 实际上,BWConfig 是大小写敏感的,所以 `reviver/cellAppMgr/pingPeriod` 与 `reviver/CellAppMgr/pingPeriod` 是两个不同的 key。运维需要确保两侧配置一致(如果使用组件级覆盖)。

### 23.4 配置示例(bw.xml)

```xml
<root>
    <reviver>
        <reattachPeriod> 10 </reattachPeriod>
        <pingPeriod> 0.1 </pingPeriod>
        <subjectTimeout> 0.2 </subjectTimeout>
        <shutDownOnRevive> true </shutDownOnRevive>
        <timeout> 3.0 </timeout>
        <!-- 组件级覆盖示例 -->
        <cellAppMgr>
            <pingPeriod> 0.05 </pingPeriod>     <!-- CellAppMgr 需要 50ms 心跳 -->
            <subjectTimeout> 0.15 </subjectTimeout>
        </cellAppMgr>
        <DBApp>
            <pingPeriod> 0.5 </pingPeriod>      <!-- DBApp 心跳慢一些,降低 DB 压力 -->
        </DBApp>
    </reviver>
</root>
```

**注意**:DBApp 配置使用 `DBApp`(大写 D),因为 ReviverSubject 用 `"DBApp"`。但 ComponentReviver 用 `dbApp`(小写 d),所以 `<dbApp>` 不会覆盖 ComponentReviver 的 pingPeriod(除非 configName 实际是 `dbApp`)。这是 BigWorld 配置的一个不一致点。

### 23.5 bwmachined 配置(bwmachined.conf)

bwmachined 的配置**不走 BWConfig**(因为 bwmachined 在 BWConfig 系统初始化前就启动了),而是直接读 `/etc/bwmachined.conf` 与 `~/.bwmachined.conf`:

```
# /etc/bwmachined.conf
# 用户特定配置
users = user1:user2:user3

# 各组件可执行路径
cellappmgr = /opt/bigworld/bin/cellappmgr
baseappmgr = /opt/bigworld/bin/baseappmgr
dbappmgr = /opt/bigworld/bin/dbappmgr
dbapp = /opt/bigworld/bin/dbapp
loginapp = /opt/bigworld/bin/loginapp

# Components tag(本机可运行的组件)
components = cellappmgr baseappmgr dbappmgr dbapp loginapp

# 工作目录与日志路径
workdir = /var/bigworld
```

详见 `usermap.cpp` 的双层查找逻辑(第十五章)。

### 23.6 关键约束总结

| 约束 | 失败后果 | 检查位置 |
|------|---------|---------|
| `pingPeriod < subjectTimeout` | `CRITICAL_MSG` 中止 Reviver | `ReviverConfig::postInit()` |
| `pingPeriod < subjectTimeout` (组件级) | `CRITICAL_MSG` 中止 ComponentReviver | `ComponentReviver::init()` |
| `pingPeriod < subjectTimeout` (Subject 端) | `CRITICAL_MSG` 中止被监控进程 | `ReviverSubject::init()` |
| `timeoutInPings >= 1` | `ERROR_MSG` + Reviver 启动失败 | `ReviverConfig::postInit()` |
| Components tags 存在 | `ERROR_MSG` + Reviver 仍启动但全 disabled | `Reviver::TagsHandler::onTagsMessage` |

---

## 二十四、性能分析

### 24.1 bwmachined 性能特征

#### 24.1.1 消息处理延迟

bwmachined 的 `run()` 主循环每次:
1. `endpoint_.getInputDefault(..., 0.1)` 阻塞最多 100ms 等待 UDP 包。
2. 处理所有待处理消息。
3. 周期任务(进程统计更新、cluster keepalive 等)。

**典型延迟**:
- 消息到达 → 处理:**< 1ms**(单线程,无锁)
- CreateMessage → fork 完成回复:~10ms(fork/exec 开销)
- 广播 birth/death 通知:~1ms(UDP 发送)

**瓶颈**:
- 旧机器上 `updateProcessStats` 读 `/proc/<pid>/stat`:每进程 ~100μs,100 个进程 = 10ms(每秒一次,可接受)。
- `MachinedAnnounceMessage` 广播:UDP 广播不阻塞,但接收方处理可能慢。

#### 24.1.2 内存占用

```
bwmachined 内存结构                估算大小
─────────────────────────────────────────
ComponentProcessMap (进程表)         ~1KB/进程 * N进程
Listeners (监听器表)                 ~100B/listener * M监听器
Tags (标签)                          ~50B/tag * K tag
Cluster (集群视图)                    ~4B/IP * L 机器
IncomingPackets (待处理包队列)        ~1KB/包 * P 包
─────────────────────────────────────────
总计:几十 KB ~ 几 MB(取决于集群规模)
```

#### 24.1.3 网络流量

每秒 bwmachined 网络流量:
- **进程 stats 更新广播**:`SystemInfo` ~256B/包,每秒一次,广播到所有监听者。
- **cluster keepalive**:`MachinedAnnounceMessage` ~50B,每秒一次,广播。
- **birth/death 通知**:每次进程启动/退出触发一次,~64B/包。
- **CreateMessage 处理**:每次 revive 一次,~100B 请求 + ack。

典型 10 节点集群,每秒约 1-5KB 控制流量(忽略业务流量)。

### 24.2 Reviver 性能特征

#### 24.2.1 ping 流量

每个 ComponentReviver 每 100ms 发 1 个 ping:
- 5 个被监控进程 = 50 ping/秒
- 每个 ping ~3B(1B priority + Mercury header ~20B) + 回复 ~3B
- 总流量:**~2KB/s**(可忽略)

#### 24.2.2 CPU 占用

Reviver 主循环每 1ms 触发一次 TICK:
- 大部分 TICK 是空转(只检查 timer)
- 每 100ms 触发一次 ping 发送(发 5 个 ping)
- 每 10s 触发一次 REATTACH(重排优先级,打印 summary)

**CPU 占用**:**< 1%**(单核)

#### 24.2.3 revive() 延迟

```cpp
// server/reviver/reviver.cpp  L463-464
if (cm.sendAndRecv( srcaddr, destaddr ) != Mercury::REASON_SUCCESS)
```

`sendAndRecv` 是同步阻塞调用,等待 bwmachined 回复。bwmachined 的处理流程:
1. 收到 CreateMessage(~1ms)
2. 查找 bwmachined.conf(~1ms)
3. fork()(~5-10ms)
4. 子进程 setuid + execve(~5-10ms)
5. 父进程把 PID 加入进程表(~1ms)
6. 回复 ack(~1ms)

**总 revive 延迟**:**10-30ms**(主要是 fork/exec 开销)。

**注意**:子进程的初始化(从 DB 加载状态、birth 广播)在 `sendAndRecv` 返回后异步进行,不计入 revive 延迟。

### 24.3 性能优化点

#### 24.3.1 PACKET_STAGGER_REPLIES

bwmachined 在广播消息时使用 `MGMPacket::PACKET_STAGGER_REPLIES` 标志:

```cpp
// server/tools/bwmachined/cluster.cpp  L328-329
mam.sendto( cluster_.machined_.endpoint(), htons( PORT_MACHINED ),
    BROADCAST, MGMPacket::PACKET_STAGGER_REPLIES );
```

`PACKET_STAGGER_REPLIES` 让接收方在回复时**错峰发送**(随机延迟 0-100ms),避免 N 个 bwmachined 同时回复造成网络风暴。

#### 24.3.2 raiseFileDescriptorHardLimit

bwmachined 启动时调用 `raiseFileDescriptorHardLimit()` 提升文件描述符上限:

```cpp
// server/tools/bwmachined/linux_machine_guard.cpp  startProcess 中调用
```

这是因为 bwmachined 可能管理大量进程(每个进程 fork 时占用 FD),需要高 RLIMIT_NOFILE。

#### 24.3.3 /proc 读取优化

`updateProcessStats` 一次读 `/proc/<pid>/stat` 取回所有信息(PID、starttime、CPU、内存),避免多次 `open/close`:

```cpp
// server/tools/bwmachined/linux_machine_guard.cpp  updateProcessStats
// 单次 fopen + fscanf 取所有字段
```

#### 24.3.4 Listeners 死监听器清理

```cpp
// server/tools/bwmachined/listeners.cpp  checkListeners
// 周期性清理"已死亡进程"注册的 listener,避免内存泄漏
```

这避免了 Listeners 表无限增长。

### 24.4 性能基准(估算)

基于源码分析的估算值(无实际测量):

| 操作 | 延迟 | 吞吐 |
|------|------|------|
| bwmachined 处理 1 个 MGM 消息 | < 1ms | > 10K msg/s |
| Reviver ping 往返 | < 1ms(本机) / < 5ms(跨机) | - |
| fork + exec(cellappmgr) | 10-30ms | ~30/s |
| bwmachined 启动到 cluster 收敛 | 1-5s(取决于 cluster 大小) | - |
| Reviver 启动到 attach 完成 | 1-2s | - |
| 主备切换(Reviver A 崩溃 → Reviver B 接管) | 200-600ms | - |
| 进程死亡检测 | 1ms(SIGCHLD) ~ 3s(ping 超时) | - |

---

## 二十五、边界情况

### 25.1 bwmachined 边界情况

#### 25.1.1 PID 复用(PID recycling)

Linux 的 PID 是循环分配的,经过足够长时间后,PID 会回到之前用过的值。bwmachined 通过 `/proc/<pid>/stat` 中的 `starttime` 字段防 PID 复用:

```cpp
// server/tools/bwmachined/linux_machine_guard.cpp  validateProcessInfo
// 比较 ProcessInfo 中存的 starttime 与 /proc/<pid>/stat 读出的 starttime
// 不一致说明 PID 已被新进程占用,旧进程已退出
```

**场景**:
1. bwmachined fork 出 cellappmgr,PID=12345,starttime=T1。
2. cellappmgr 崩溃,PID 12345 释放。
3. 系统启动另一个进程(可能是非 BigWorld 的),恰好分到 PID=12345,starttime=T2(T2 > T1)。
4. bwmachined 周期读 `/proc/12345/stat`,看到 starttime=T2 ≠ T1,判定 cellappmgr 已死。
5. 触发 death 通知 + revive。

**没有 starttime 检查会怎样**:
- bwmachined 误以为 cellappmgr 还活着(因为 PID 12345 还在)。
- 永远不会触发 revive,业务受损。

#### 25.1.2 fork 后 exec 失败

```cpp
// server/tools/bwmachined/linux_machine_guard.cpp  startProcess
// 子进程 exec 失败时通过管道写错误信息给父进程
```

**场景**:
1. bwmachined fork 子进程。
2. 子进程 setuid 后 execve("/opt/bigworld/bin/cellappmgr"),但文件不存在或权限不对。
3. 子进程通过 pipe 写错误信息给父进程。
4. 父进程读管道,记录错误,把子进程标记为失败。
5. **不会**触发 birth 通知,因为子进程未成功 exec。
6. Reviver 的 `sendAndRecv` 收到错误回复。

**关键设计**:`FD_CLOEXEC` 让管道在 exec 成功时自动关闭。如果 exec 失败,管道保留,子进程可以写错误。父进程通过管道是否有数据判断 exec 是否成功。

#### 25.1.3 父子进程 stdout/stderr 处理

bwmachined fork 子进程时,把子进程的 stdout/stderr 重定向到日志文件:

```cpp
// server/tools/bwmachined/linux_machine_guard.cpp  startProcess
// freopen(logfile, "a", stdout); freopen(logfile, "a", stderr);
```

**边界情况**:
- 日志文件路径不可写 → freopen 失败,子进程 stdout/stderr 仍指向 bwmachined 的 stdout。
- 多个 bwmachined 实例(不该有,但理论上)可能竞争同一日志文件。
- 日志文件无限增长 → 需要外部 logrotate。

#### 25.1.4 UDP 包丢失

bwmachined 的所有通信走 UDP(PORT_MACHINED=19289),UDP 不保证送达:

- **CreateMessage 丢失**:Reviver 的 `sendAndRecv` 超时,返回 REASON_TIMER_EXPIRED。Reviver 记录 "Could not send request" 错误,但**不会**自动重试(因为可能 bwmachined 已经 fork 了子进程,只是 ack 丢了,重试会导致双 fork)。
- **NOTIFY_BIRTH/DEATH 丢失**:Reviver 不会收到 birth/death 通知,但通过 ping 兜底(3 秒后判定死亡)。
- **ListenerMessage 丢失**:bwmachined 不会注册 listener,Reviver 的 ComponentReviver 永远不会收到通知,但通过 `findInterface`(同步有重试)兜底。

#### 25.1.5 bwmachined 自身崩溃

bwmachined 是 root 启动的长驻进程,理论上不会崩溃。但如果它崩溃了:

- 状态持久化:`/var/run/bwmachined.state`(10 分钟有效期)。
- 重启后从 state 文件恢复进程表。
- 10 分钟外的状态丢失,但被监控进程仍在运行(它们的 bwmachined 已经死了一段时间,但 ping 仍正常)。
- 重启后需要重新 cluster bootstrap(广播 ANNOUNCE_BIRTH)。

**没有持久化的状态**:Listeners(birth/death 监听器)不持久化,因为 listener 进程地址可能在重启期间变了。Listener 进程需要自己重新注册(通常在 Reviver 重启时通过 `registerBirthListener` 等)。

### 25.2 Reviver 边界情况

#### 25.2.1 Reviver 与被监控进程启动顺序

**场景 A:Reviver 先启动,被监控进程后启动**
1. Reviver 启动,`findInterface` 找不到 cellappmgr(未启动)。
2. ComponentReviver.init 失败但仅记日志,不退出。
3. cellappmgr 启动,bwmachined 广播 birth 通知。
4. ComponentReviver.handleMessage 收到 birth,更新 addr_。
5. activate 时需要 addr_.ip != 0(已满足),开始 ping。
6. 第一次 ping=YES → attach 完成。

**场景 B:被监控进程先启动,Reviver 后启动**
1. cellappmgr 启动,Reviver 不在。
2. Reviver 启动,`findInterface` 找到 cellappmgr。
3. ComponentReviver.init 设置 addr_。
4. activate 后开始 ping。
5. cellappmgr 的 ReviverSubject 第一次收到 ping,`priority_==0xff`,接受(情形 B)。

**场景 C:两者同时启动(竞态)**
1. Reviver 启动,`findInterface` 找不到 cellappmgr(还没注册)。
2. cellappmgr 启动,bwmachined 广播 birth。
3. Reviver 收到 birth 通知,addr_ 更新。
4. Reviver 启动 ping,正常 attach。

#### 25.2.2 多个 Reviver 同时启动

**场景**:5 个 Reviver 同时启动(主备高可用集群)。

1. 每个 Reviver 都 `findInterface` cellappmgr,各自拿到相同地址。
2. 每个 Reviver 都注册 birth/death listener(bwmachined 维护 5 个 listener)。
3. 每个 Reviver activate 时分配不同 priority(1, 2, 3, 4, 5)。
4. cellappmgr 的 ReviverSubject 接受 priority=1 的 Reviver,拒绝其他。
5. priority=1 的 Reviver 是主,其他是备,各自 standby。

**问题**:Reviver 启动顺序不同,priority 分配不同。如果运维希望特定 Reviver 是主,需要按顺序启动(先启动 priority=1 的)。

#### 25.2.3 Reviver 崩溃后的恢复

**场景**:Reviver A(主)崩溃,Reviver B(备)接管。

1. Reviver A 崩溃,被监控进程(cellappmgr)的 ReviverSubject 在 200ms 后超时(`msTimeout_`)。
2. Reviver B 在下一个 ping 周期被接受(情形 C:超时切换)。
3. Reviver B 成为新主,继续监控 cellappmgr。

**问题**:Reviver B 如何知道 cellappmgr 还活着?它一直在 ping,只是被拒绝。一旦 Reviver A 崩溃,Reviver B 的下一次 ping 就会被接受。

**问题**:Reviver A 崩溃后,谁重启它?
- 没人。Reviver 不是被监控进程,它没有 ReviverSubject。
- 如果 Reviver 是被 systemd/init.d 启动的,systemd 会重启它。
- 如果 Reviver 是手动启动的,需要运维介入。
- bwmachined 不会主动重启 Reviver(因为它不是被监控进程)。

#### 25.2.4 进程双死亡但 Reviver 不同步

**场景**:cellappmgr 崩溃,Reviver A 与 Reviver B 都感知到。

1. Reviver A 通过 death 通知(快,< 1ms)感知,触发 revive,发 CreateMessage 给 bwmachined。
2. Reviver B 也通过 death 通知感知,触发 revive,发 CreateMessage 给 bwmachined。
3. bwmachined 收到两个 CreateMessage,**fork 两个 cellappmgr'**?

**实际行为**:bwmachined **会**fork 两个,因为 `handleCreateMessage` 不去重。这导致两个 cellappmgr' 同时启动。

**缓解**:
- Reviver A fork 完成后 `shutDownOnRevive=true` 退出。
- Reviver B 也 fork 完成后退出。
- 两个 cellappmgr' 通过自身的主选举逻辑(基于 DBAppMgr)决定谁是主。
- 另一个 cellappmgr' 通常会主动 shutDown(发现自己不是主)。

**风险**:短暂的双 cellappmgr' 共存可能造成业务混乱(两个都接收客户端请求)。

#### 25.2.5 CreateMessage 的 recover_ 字段

```cpp
cm.recover_ = 1;
```

被恢复进程在 main() 中解析 `-recover 1`,知道自己是被 Reviver 拉起的。如果运维手动启动一个进程(无 `-recover`),它不会执行恢复逻辑,只做全新初始化。

**边界情况**:运维误用手动启动(无 -recover)替代 revive:
- 进程启动但状态为空,无法接替旧主。
- 其他进程可能误以为这是新主,把业务路由过来,造成数据丢失。
- 解决:运维严格使用 Reviver 工具或 bwmachined CLI 启动,不要手动起。

#### 25.2.6 BW_COMPILE_TIME_CONFIG 不匹配

```cpp
cm.config_ = BW_COMPILE_TIME_CONFIG;
```

如果 bwmachined 与 Reviver 的 BW_COMPILE_TIME_CONFIG 不同(可能编译时配置不同):
- bwmachined 用 Reviver 传来的 config_ 启动子进程。
- 子进程读取 `<config_>.xml` 而不是默认 `bw.xml`。
- 配置不一致可能导致子进程行为异常。

**约束**:同一集群的所有 BigWorld 二进制必须用相同 BW_COMPILE_TIME_CONFIG 编译。

### 25.3 Cluster 边界情况

#### 25.3.1 网络分区导致 cluster 分裂

**场景**:5 节点集群,网络分区为 {A, B} 与 {C, D, E}。

- A 与 B 互相可见,但无法联系 C/D/E。
- C/D/E 互相可见,但无法联系 A/B。
- 每个 bwmachined 通过 `MachinedAnnounceMessage` 广播,但分区阻止跨组通信。

**结果**:
- 组 {A, B}:认为 cluster 只有 2 个节点。
- 组 {C, D, E}:认为 cluster 有 3 个节点。
- 两组各自选 buddy,各自维护 cluster 视图。
- 如果某进程死亡,只在本组内被感知、被 revive。

**网络恢复后**:
- 两组重合,bwmachined 通过 ANNOUNCE_BIRTH 重新收敛 cluster 视图。
- 但在分裂期间,可能有多余的 fork(每组各自 fork 了一份)。

#### 25.3.2 buddy 失效

```cpp
// server/tools/bwmachined/cluster.cpp  chooseBuddy
// buddy 是"IP 比自己大的下一个"
```

**场景**:buddy 机器宕机。
- bwmachined 不主动重新选 buddy(选择是静态的,基于 IP 排序)。
- 如果 buddy 死了,`buddy_` 字段仍指向死掉的 IP,但 flood keepalive 兜底。
- FloodReplyHandler 两次重试,确保即使 buddy 失效,消息也能广播到所有存活机器。

#### 25.3.3 同时启动多个 bwmachined

**场景**:误在同一机器启动两个 bwmachined 实例(端口冲突)。

- 第二个 bwmachined `bind(PORT_MACHINED)` 失败,启动失败。
- 不会有两个 bwmachined 同时运行。

但如果是不同端口(理论上 bwmachined 不支持,但代码可改):
- 两个 bwmachined 互相不知道对方。
- 两个都广播 ANNOUNCE_BIRTH,但对方的 ANNOUNCE_BIRTH 收不到(不同端口)。
- 集群视图分裂。

### 25.4 配置边界情况

#### 25.4.1 配置值边界

| 配置 | 下界 | 上界 | 边界值后果 |
|------|------|------|-----------|
| `pingPeriod` | > 0 | 无 | 0 → 除零;负 → 时间倒流 |
| `subjectTimeout` | > `pingPeriod` | 无 | ≤ pingPeriod → CRITICAL_MSG |
| `timeout` | ≥ `pingPeriod` | 无 | < pingPeriod → timeoutInPings < 1 → ERROR |
| `reattachPeriod` | > 0 | 无 | 0 → REATTACH 不触发 |
| `timeoutInPings` | ≥ 1 | 无 | 0 → 自动推导 |

#### 25.4.2 配置一致性

集群中所有 Reviver 必须用相同配置:
- 不同 `pingPeriod` 导致 Reviver A 与 B 发 ping 的频率不同,可能造成主备切换抖动。
- 不同 `subjectTimeout` 导致被监控进程对 A 与 B 行为不一致(虽然 subjectTimeout 是被监控进程的配置,但通常集群统一)。

#### 25.4.3 Components tag 与 Reviver --add/--del 冲突

**场景**:bwmachined.conf 的 `Components = cellappmgr`,但 Reviver 用 `--add baseappmgr` 启动。

- Reviver 启动时先 `queryMachinedSettings()` 查询 Components tag,发现只有 `cellappmgr`,把所有 ComponentReviver 标记为 disabled。
- `--add baseappmgr` 在 init 阶段把所有 ComponentReviver 标记为 disabled,然后 enable baseappmgr。
- 但 `queryMachinedSettings` 又把 baseappmgr 标记为 disabled(因为 tag 没有)。
- 最终:baseappmgr 被 disabled,Reviver 不监控任何组件。

**修复**:运维需要确保 bwmachined.conf 的 Components tag 与 Reviver 的 --add/--del 参数一致。

---

## 二十六、与其他引擎对比

### 26.1 与 systemd 对比

| 维度 | systemd | bwmachined + Reviver |
|------|---------|----------------------|
| 部署粒度 | 一台机器一个 systemd | 每台机器一个 bwmachined,集群协同 |
| 进程定义 | unit 文件(/etc/systemd/system/) | bwmachined.conf + CreateMessage |
| 启动方式 | `systemctl start` | `CreateMessage` MGM 或 `bwmachined` CLI |
| 死亡检测 | cgroup v2 事件 + SIGCHLD | SIGCHLD + `/proc/<pid>/stat` |
| 重启策略 | `Restart=always/on-failure` | Reviver 监控 + 自动 revive |
| 用户切换 | `User=` in unit | CreateMessage.uid_ + setuid |
| 环境变量 | `Environment=` in unit | bwmachined 继承环境 + bwmachined.conf |
| 资源限制 | `LimitNOFILE=` 等 | bwmachined 启动时 raiseFileDescriptorHardLimit |
| 业务感知 | 无 | Reviver 知道 5 类组件,支持 -recover |
| 主备热备 | 无(需 keepalived) | ReviverSubject 优先级仲裁原生支持 |
| 跨机协同 | 无(需 etcd/consul) | 内建 ring 拓扑 + MachinedAnnounceMessage |
| 日志 | journald | freopen 重定向到文件 |
| 依赖管理 | `Requires=` / `After=` | 无(bwmachined 不管依赖) |
| 配置重载 | `systemctl daemon-reload` | 重启 bwmachined |
| API | D-Bus | UDP MGM(19289) |

**核心差异**:
- systemd 是**单机**初始化系统,需要 etcd/consul 等外部组件做跨机协调。
- bwmachined 内建跨机 cluster 视图(基于 UDP 广播 + ring 拓扑),不需要外部依赖。
- Reviver 提供 systemd 没有的"业务感知"——知道 5 类被监控组件、支持 `-recover` 启动参数。

### 26.2 与 init.d / SysV 对比

| 维度 | init.d (SysV) | bwmachined |
|------|---------------|------------|
| 启动脚本 | /etc/init.d/<service> shell 脚本 | bwmachined.conf + binary path |
| 启动方式 | `service <name> start` | CreateMessage MGM |
| 死亡检测 | 无(脚本启动后退出,不监控) | SIGCHLD + /proc stat + death 广播 |
| 重启策略 | 无(需 monit/supervisor) | Reviver 接管 |
| 用户切换 | `su -c` 或 `start-stop-daemon --chuid` | setuid() |
| 状态查询 | `service <name> status`(检查 PID) | ProcessStatsMessage MGM |
| 信号 | `service <name> stop` 调用 `kill` | SignalMessage MGM |
| 配置 | shell 脚本变量 | bwmachined.conf INI-like |
| 跨机 | 无 | ring cluster |

**核心差异**:init.d 是"启动即忘"的脚本系统,不监控进程;而 bwmachined 是持续监控的守护进程。

### 26.3 与 Kubernetes 对比

| 维度 | Kubernetes | bwmachined + Reviver |
|------|------------|----------------------|
| 部署粒度 | 集群级(多 master + 多 worker) | 每机器一个 bwmachined |
| 进程模型 | Pod(可能多容器) | 单进程(fork/exec) |
| 隔离 | 容器 + namespace + cgroup | 进程级(共享 OS) |
| 调度 | kube-scheduler(基于资源) | 静态(本机 bwmachined 启动) |
| 自愈 | kube-controller-manager + kubelet | Reviver |
| 死亡检测 | kubelet probe + SIGCHLD | SIGCHLD + /proc stat + Reviver ping |
| 跨机协同 | etcd 强一致 | bwmachined UDP 广播最终一致 |
| 配置 | ConfigMap + Secret | bwmachined.conf + bw.xml |
| 状态持久化 | etcd | /var/run/bwmachined.state(10 分钟) |
| 服务发现 | Service + DNS | bwmachined + ProcessStatsMessage 查询 |
| 滚动更新 | Deployment + ReplicaSet | 无(需手动重启) |
| 资源限制 | cgroup limits | 无 |
| 健康 probe | livenessProbe / readinessProbe | Reviver ping |
| 业务感知 | 无(只关心 Pod 状态) | Reviver 知道 5 类组件类型 |
| 主备热备 | StatefulSet + leader election | ReviverSubject 优先级仲裁 |
| 网络分区处理 | PodExtraction、网络策略 | UDP 广播可能丢、ping 兜底 |
| 日志 | kubectl logs + 集中日志 | freopen 重定向到本机文件 |

**核心差异**:
- Kubernetes 是**容器编排系统**,关注 Pod 调度、资源管理、滚动更新。
- bwmachined + Reviver 是**进程守护系统**,关注本机进程的 fork/exec 与监控,不做调度。
- Kubernetes 通过 etcd 实现强一致,K8s master 是高可用的;BigWorld 通过 cluster ring 实现最终一致,bwmachined 之间无主从。
- Kubernetes 的 Pod 重启后是新实例(无状态);Reviver 通过 `-recover` 让新实例从 DB 加载状态(状态恢复)。

### 26.4 与 supervisor / monit 对比

| 维度 | supervisor | monit | bwmachined + Reviver |
|------|-----------|-------|----------------------|
| 部署粒度 | 每机器一个 supervisord | 每机器一个 monit 守护 | 每机器一个 bwmachined |
| 进程定义 | /etc/supervisor/conf.d/*.ini | /etc/monit/monitrc | bwmachined.conf |
| 启动方式 | supervisorctl start | monit start | CreateMessage MGM |
| 死亡检测 | SIGCHLD + 子进程 waitpid | 周期性 ping 进程 | SIGCHLD + /proc stat + Reviver ping |
| 重启策略 | autorestart=true | restart = 3 cycles | Reviver 监控 + revive |
| 用户切换 | user= in ini | as uid user in conf | CreateMessage.uid_ + setuid |
| 跨机协同 | 无 | 无 | 内建 ring cluster |
| 业务感知 | 无 | 无 | Reviver 知道 5 类组件 |
| 主备热备 | 无 | 无 | ReviverSubject 仲裁 |
| API | XML-RPC | HTTP | UDP MGM |
| 状态查询 | supervisorctl status | monit status | ProcessStatsMessage |

**核心差异**:
- supervisor 与 monit 是**单机**进程管理器,无跨机协同。
- bwmachined 与 supervisor/monit 最相似,但多了跨机 cluster 与业务感知(通过 Reviver)。
- supervisor/monit 的进程定义在配置文件中;bwmachined 的进程通过 CreateMessage 动态创建,更灵活。

### 26.5 与 Nomad / Mesos 对比

| 维度 | Nomad | Mesos | bwmachined + Reviver |
|------|-------|-------|----------------------|
| 调度器 | nomad scheduler(集群级) | Mesos master + framework | 无调度(本机启动) |
| 资源管理 | cgroup + resource stanza | Mesos allocator | 无 |
| 跨机协同 | Raft 强一致 | ZooKeeper | UDP 广播最终一致 |
| 进程模型 | 单进程或容器 | Task(executor + task) | 单进程 fork/exec |
| 主备 | 无原生支持 | framework 责任 | ReviverSubject 仲裁 |
| 业务感知 | 无 | framework 知道业务 | Reviver 知道 5 类组件 |

**核心差异**:Nomad/Mesos 是**集群调度器**,关注资源分配与任务调度。bwmachined 不做调度,只做本机进程管理。BigWorld 的"调度"由 CellAppMgr/BaseAppMgr 自己负责(知道哪些机器有 cellapp,基于 bwmachined 的 Components tag 选择)。

### 26.6 总体定位

```
┌────────────────────────────────────────────────────────────────────┐
│  系统初始化层级                                                    │
│                                                                      │
│  ┌──────────────────┐  机器启动                                    │
│  │ BIOS / UEFI      │                                              │
│  └────────┬─────────┘                                              │
│           │                                                          │
│  ┌────────▼─────────┐  内核加载                                    │
│  │ Linux Kernel     │                                              │
│  └────────┬─────────┘                                              │
│           │                                                          │
│  ┌────────▼─────────┐  PID 1                                       │
│  │ systemd / init   │  ← 单机初始化                                 │
│  └────────┬─────────┘                                              │
│           │                                                          │
│  ┌────────▼─────────┐  BigWorld 守护                                │
│  │ bwmachined       │  ← 机器级守护,跨机 cluster                    │
│  └────────┬─────────┘                                              │
│           │                                                          │
│  ┌────────▼─────────┐  业务级守护                                   │
│  │ Reviver          │  ← 业务感知,知道 5 类组件,主备仲裁         │
│  └────────┬─────────┘                                              │
│           │                                                          │
│  ┌────────▼─────────┐  业务进程                                    │
│  │ CellAppMgr 等    │                                              │
│  └──────────────────┘                                              │
└────────────────────────────────────────────────────────────────────┘
```

**BigWorld 双重守护的独特价值**:
1. **跨机协同无外部依赖**:不依赖 etcd/zookeeper,K8s 之外的另一选择。
2. **业务感知**:`-recover` 启动参数让新进程从 DB 恢复状态,不是无状态重启。
3. **主备仲裁内置**:ReviverSubject 在被监控进程内仲裁,不需要外部 leader election。
4. **轻量**:bwmachined + Reviver 加起来代码量 ~5000 行,远小于 K8s 或 Nomad。
5. **耦合性高**:专为 BigWorld 5 类组件设计,不通用,但配置简单。

**BigWorld 双重守护的局限**:
1. **无资源管理**:不像 K8s 有 cgroup limits,进程可能占用所有资源。
2. **无滚动更新**:升级 BigWorld 需要手动重启进程,Reviver 不会做滚动更新。
3. **无网络策略**:不像 K8s NetworkPolicy,进程间网络无隔离。
4. **状态持久化弱**:bwmachined state 只 10 分钟,Reviver 无持久化。
5. **跨机一致性弱**:UDP 广播可能丢包,最终一致而非强一致。

---

## 附录

### 附录 A:关键源码文件清单

#### A.1 bwmachined 部分

| 文件路径 | 行数(约) | 主要内容 |
|---------|----------|---------|
| `programming/bigworld/server/tools/bwmachined/main.cpp` | 130 | BIGWORLD_MAIN_NO_RESMGR 八步启动 |
| `programming/bigworld/server/tools/bwmachined/bwmachined.hpp` | 147 | BWMachined 类声明(三端点) |
| `programming/bigworld/server/tools/bwmachined/bwmachined.ipp` | 79 | 内联函数 |
| `programming/bigworld/server/tools/bwmachined/bwmachined.cpp` | 1994 | 主类实现(handleMessage、handleCreateMessage、run、save/load) |
| `programming/bigworld/server/tools/bwmachined/cluster.hpp` | 113 | Cluster 类声明 |
| `programming/bigworld/server/tools/bwmachined/cluster.cpp` | 329 | 环状 buddy 拓扑、BirthReplyHandler、FloodReplyHandler |
| `programming/bigworld/server/tools/bwmachined/listeners.hpp` | 46 | Listeners 类 |
| `programming/bigworld/server/tools/bwmachined/listeners.cpp` | 77 | handleNotify、checkListeners |
| `programming/bigworld/server/tools/bwmachined/linux_machine_guard.cpp` | 599 | startProcess、updateProcessStats、validateProcessInfo |
| `programming/bigworld/server/tools/bwmachined/common_machine_guard.hpp` | 195 | BWMACHINED_VERSION=50、ProcessInfo、Stat 模板 |
| `programming/bigworld/server/tools/bwmachined/usermap.hpp` | 33 | UserMap 类 |
| `programming/bigworld/server/tools/bwmachined/usermap.cpp` | 206 | 双层查找 ~/.bwmachined.conf + /etc/bwmachined.conf |
| `programming/bigworld/server/tools/bwmachined/server_platform.hpp` | 117 | ServerPlatform 抽象基类 |
| `programming/bigworld/server/tools/bwmachined/server_platform.cpp` | 93 | initVersionsProcesses |
| `programming/bigworld/server/tools/bwmachined/server_platform_linux.hpp` | 66 | ServerPlatformLinux |
| `programming/bigworld/server/tools/bwmachined/server_platform_linux.cpp` | ~200 | initConfigSuffixes、Linux 特定实现 |
| `programming/bigworld/server/tools/bwmachined/incoming_packet.hpp/.cpp` | ~150 | 延迟处理广播包 |
| `programming/bigworld/server/tools/bwmachined/message_with_destination.hpp` | 81 | MessageWithDestination 模板 |

#### A.2 共享协议部分

| 文件路径 | 行数(约) | 主要内容 |
|---------|----------|---------|
| `programming/bigworld/lib/network/machine_guard.hpp` | 981 | MGM 完整协议、15 种消息、ReplyHandler |
| `programming/bigworld/lib/network/machine_guard.cpp` | (大) | matches 函数、序列化 |
| `programming/bigworld/lib/network/machined_utils.cpp` | 220 | registerWithMachined、registerBirthListener 等 |

#### A.3 Reviver 部分

| 文件路径 | 行数(约) | 主要内容 |
|---------|----------|---------|
| `programming/bigworld/server/reviver/main.cpp` | 46 | BIGWORLD_MAIN bwMainT<Reviver> |
| `programming/bigworld/server/reviver/reviver.hpp` | 88 | Reviver 类声明(三重继承) |
| `programming/bigworld/server/reviver/reviver.cpp` | 499 | init 12 步、queryMachinedSettings、revive、handleTimeout REATTACH |
| `programming/bigworld/server/reviver/component_reviver.hpp` | 104 | ComponentReviver 基类(四重继承) |
| `programming/bigworld/server/reviver/component_reviver.cpp` | 340 | MF_REVIVER_HANDLER 宏、5 个特化、handleMessage |
| `programming/bigworld/server/reviver/reviver_config.hpp` | 21 | 6 个配置项 |
| `programming/bigworld/server/reviver/reviver_config.cpp` | 64 | 默认值与 postInit 推导 timeoutInPings |
| `programming/bigworld/server/reviver/reviver_interface.hpp` | 48 | BW_REVIVER_MSGS 宏、10 条 birth/death 消息 |

#### A.4 ReviverSubject 部分(嵌入被监控进程)

| 文件路径 | 行数(约) | 主要内容 |
|---------|----------|---------|
| `programming/bigworld/lib/server/reviver_subject.hpp` | 44 | ReviverSubject 单例、MF_REVIVER_PING_MSG 宏 |
| `programming/bigworld/lib/server/reviver_subject.cpp` | 158 | handleMessage 仲裁逻辑 |
| `programming/bigworld/lib/server/reviver_common.hpp` | 20 | REVIVER_PING_YES=1/NO=0、默认值 |

#### A.5 5 个被监控进程的 ReviverSubject 注册点

| 进程 | 文件路径 | 注册点行号 |
|------|---------|-----------|
| CellAppMgr | `programming/bigworld/server/cellappmgr/cellappmgr.cpp` | 183 |
| BaseAppMgr | `programming/bigworld/server/baseappmgr/baseappmgr.cpp` | 365 |
| DBAppMgr | `programming/bigworld/server/dbappmgr/dbappmgr.cpp` | 236 |
| DBApp | `programming/bigworld/server/dbapp/dbapp.cpp` | 778 |
| LoginApp | `programming/bigworld/server/loginapp/loginapp.cpp` | 270 |

### 附录 B:MachineGuard 消息类型速查

| 消息类型 | 用途 | 触发者 | 处理者 |
|---------|------|--------|--------|
| `CreateMessage` | 创建进程 | Reviver / 运维工具 | bwmachined |
| `SignalMessage` | 发信号 | 运维工具 | bwmachined |
| `TagsMessage` | 标签查询/设置 | Reviver / 工具 | bwmachined |
| `ListenerMessage` | 注册 birth/death listener | Reviver / 业务进程 | bwmachined |
| `ProcessMessage` | 注册/反注册进程 | 业务进程 | bwmachined |
| `ProcessStatsMessage` | 进程统计查询 | Reviver / 工具 | bwmachined + 业务进程 |
| `QueryInterfaceMessage` | 内部/外部接口查询 | 业务进程 | bwmachined |
| `MachinedAnnounceMessage` | 集群通告(birth/death/keepalive) | bwmachined | bwmachined |
| `MachineMessage` | 机器统计 | bwmachined | 监控工具 |
| `MachineSearchMessage` | 查找机器 | 工具 | bwmachined |
| `UserMessage` | 用户查询 | 工具 | bwmachined |
| `WatchMessage` | watcher 系统 | 工具 | bwmachined + 业务进程 |
| `NotifyMessage` | birth/death 通知(广播) | bwmachined | Reviver / 业务进程 |
| `ComponentMessage` | 组件查询 | 工具 | bwmachined |
| `GridMessage` | grid 系统 | 工具 | bwmachined |

### 附录 C:Reviver 优先级数值约定

| Priority 值 | 含义 |
|-------------|------|
| 0 | 未激活(deactivate 状态) |
| 1 | 最高优先级(主 Reviver) |
| 2, 3, ... | 备用 Reviver,数值越大优先级越低 |
| 0xff | 初始值,表示"尚未指定主"(ReviverSubject 内部使用) |

### 附录 D:配置参考表

#### D.1 bw.xml 中的 reviver 段

```xml
<root>
    <reviver>
        <!-- 全局配置 -->
        <reattachPeriod> 10.0 </reattachPeriod>
        <pingPeriod> 0.1 </pingPeriod>
        <subjectTimeout> 0.2 </subjectTimeout>
        <shutDownOnRevive> true </shutDownOnRevive>
        <timeout> 3.0 </timeout>
        <!-- timeoutInPings 已 deprecated,推荐用 timeout -->

        <!-- 组件级覆盖(可选) -->
        <cellAppMgr>
            <pingPeriod> 0.05 </pingPeriod>
        </cellAppMgr>
    </reviver>
</root>
```

#### D.2 bwmachined.conf

```
# /etc/bwmachined.conf
users = user1:user2:user3

# Components tag:本机可运行的组件类型
components = cellappmgr baseappmgr dbappmgr dbapp loginapp

# 各组件可执行文件路径
cellappmgr = /opt/bigworld/bin/cellappmgr
baseappmgr = /opt/bigworld/bin/baseappmgr
dbappmgr = /opt/bigworld/bin/dbappmgr
dbapp = /opt/bigworld/bin/dbapp
loginapp = /opt/bigworld/bin/loginapp
cellapp = /opt/bigworld/bin/cellapp
baseapp = /opt/bigworld/bin/baseapp

# 工作目录(可选,默认 /var/bigworld)
workdir = /var/bigworld

# 日志目录(可选,默认 /var/log/bigworld)
logdir = /var/log/bigworld
```

#### D.3 用户配置文件

```
# ~/.bwmachined.conf(用户特定,优先级高于 /etc/bwmachined.conf)
# 当前用户可运行的组件
components = cellappmgr dbapp
```

### 附录 E:关键算法复杂度

| 算法 | 时间复杂度 | 空间复杂度 | 备注 |
|------|-----------|-----------|------|
| bwmachined handleMessage 派发 | O(1)(hash) | O(1) | 15 种消息类型,switch case |
| handleCreateMessage | O(N) | O(1) | N = 配置文件中组件数 |
| Listeners handleNotify | O(L) | O(L) | L = 该 uid+name 的 listener 数 |
| Cluster BirthReplyHandler | O(M) | O(M) | M = 集群机器数,每个 bwmachined 回复一次 |
| updateProcessStats | O(P) | O(P) | P = 进程数,每进程读一次 /proc |
| Reviver init | O(5) | O(5) | 固定 5 个 ComponentReviver |
| Reviver REATTACH | O(5 log 5) | O(5) | 排序 5 个 ComponentReviver |
| ComponentReviver handleMessage | O(1) | O(1) | 直接比较 |
| ReviverSubject handleMessage | O(1) | O(1) | 直接比较 |

### 附录 F:常见运维操作

#### F.1 启动 Reviver 监控特定组件

```bash
# 监控所有(默认)
reviver

# 只监控 CellAppMgr
reviver --add cellAppMgr
# 或
reviver --add cellappmgr

# 监控除 LoginApp 外的所有
reviver --del loginApp
```

#### F.2 查询 bwmachined 状态

```bash
# 列出所有进程
bwmachined_msg -m processStats

# 查询某机器
bwmachined_msg -m machineSearch -t cellapp

# 查询 tags
bwmachined_msg -m tags -t Components
```

#### F.3 手动启动一个进程(替代 revive)

```bash
# 通过 bwmachined 启动(带 recover)
bwmachined_msg -m create -n cellappmgr -r 1

# 直接 exec(不推荐,绕过 bwmachined)
/opt/bigworld/bin/cellappmgr -recover 1
```

#### F.4 重启 bwmachined

```bash
# 停止
/etc/init.d/bwmachined stop

# 启动(状态从 /var/run/bwmachined.state 恢复,10 分钟内)
/etc/init.d/bwmachined start

# 重启
/etc/init.d/bwmachined restart
```

#### F.5 查看进程死亡原因

```bash
# bwmachined 日志(通常在 /var/log/syslog 或 /var/log/bwmachined.log)
grep "death" /var/log/syslog

# Reviver 日志
grep "Reviving\|has detached\|Missed too many" /var/log/bigworld/reviver.log

# 进程的 stdout/stderr(被 bwmachined 重定向)
cat /var/log/bigworld/cellappmgr.log
```

### 附录 G:Mercury 消息机制速查

BigWorld 的 Mercury 网络框架提供两类消息:

| 类型 | 注册宏 | 用途 |
|------|--------|------|
| Fixed Message | `MERCURY_FIXED_MESSAGE(name, size, handler)` | 固定大小消息,高效 |
| Variable Message | `MERCURY_VARIABLE_MESSAGE(name, size, handler)` | 可变大小消息 |

`reviverPing` 是 variable message,因为 reply 部分 1 字节,但请求方向也包含 1 字节 priority。

**消息处理流程**:
1. 收到 UDP 包,Mercury 解析 header(包括 replyID、identifier)。
2. 根据 identifier 查找 InterfaceElement。
3. 调用 InterfaceElement.handler->handleMessage(srcAddr, header, data)。
4. 若是 request(header.replyID 不为 0),handler 决定是否 startReply。

**关键区别**:
- **request**:发送方期望回复,通过 `startRequest` 启动,handler 收到回复后调用 ReplyHandler。
- **message**:发送方不期望回复,通过 `startMessage` 启动。
- **reply**:发送方是回复某个 request,通过 `startReply(replyID)` 启动。

Reviver 的 ping 用 `startRequest`(期望 YES/NO 回复),birth/death 通知用 message(单向)。

### 附录 H:Mercury Address 表示

```cpp
struct Address {
    uint32 ip;     // 网络字节序
    uint16 port;   // 网络字节序
    uint16 salt;   // 用于防欺骗(通常为 0)
};
```

`Address::NONE` 是 `{0, 0, 0}`,Mercury 特殊处理(不发送)。

Reviver 在 `init` 时通过 `interface_.address()` 获取自己的 Address,传给 bwmachined 注册 listener。bwmachined 后续用这个 Address 发送 birth/death 通知。

### 附录 I:总结

BigWorld 的双重守护机制是**面向业务的游戏服务器专用方案**,与通用容器编排(K8s)或通用进程管理(systemd/supervisor)有本质差异:

1. **bwmachined** 充当"BigWorld 集群范围的 systemd",提供:
   - 跨机协同(基于 UDP 广播 + ring 拓扑)
   - 进程 fork/exec(以 root 身份,setuid 切换用户)
   - birth/death 广播(UDP,Reviver 兜底)
   - 集群状态持久化(10 分钟)

2. **Reviver** 充当"业务感知的看门狗",提供:
   - 5 类关键单例进程的监控(CellAppMgr/BaseAppMgr/DBAppMgr/DBApp/LoginApp)
   - 双死亡检测(bwmachined death 广播 + ping 超时)
   - 主备仲裁(ReviverSubject 在被监控进程内仲裁)
   - 状态恢复(通过 `-recover` 启动参数)

两者通过 MachineGuard 协议(UDP,端口 19289)解耦:Reviver 不直接 fork,而是发 CreateMessage 委托 bwmachined。这降低了 Reviver 的权限要求(普通用户即可),同时让 bwmachined 集中管理特权操作(setuid、fork、FD 继承)。

这套设计的核心价值在于**轻量、业务感知、跨机协同无外部依赖**。代价是**无资源管理、无滚动更新、跨机一致性弱**。对于游戏服务器这种"进程少、状态重、需要主备热备"的场景,是合理且高效的折衷。

---

*本文档基于 BigWorld Engine 14.4.1 源码分析整理,所有代码引用均带相对路径与行号,可在源码中直接定位。如发现遗漏或错误,请对照源码核查。*
