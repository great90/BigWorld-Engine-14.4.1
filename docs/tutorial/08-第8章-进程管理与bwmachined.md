# 第8章 进程管理与 bwmachined

> 在前一章我们已经鸟瞰了整个 BigWorld 服务器集群的进程拓扑:从 bwmachined 到 DBAppMgr、CellAppMgr、BaseAppMgr,再到具体的 CellApp、BaseApp、LoginApp……这些进程并不是各自为政地被 `ssh` 拉起来的,而是由一个**每台机器一个**的守护进程统一管理——这就是 `bwmachined`。它既是集群的"户籍警"(登记进程出生与死亡),又是"产婆"(fork/exec 拉起子进程),还是"居委会"(跨机器的集群视图同步)。本章将带你看懂这把撑起整个集群的"管家钥匙"。

---

## 目录

- [8.1 bwmachined 概述](#81-bwmachined-概述)
- [8.2 源码结构全景](#82-源码结构全景)
- [8.3 MachineGuard 协议](#83-machineguard-协议)
- [8.4 主程序与启动流程](#84-主程序与启动流程)
- [8.5 三端点与广播接口发现](#85-三端点与广播接口发现)
- [8.6 主事件循环](#86-主事件循环)
- [8.7 消息分发与 handleMessage](#87-消息分发与-handlemessage)
- [8.8 进程创建流程详解](#88-进程创建流程详解)
- [8.9 进程生命周期管理](#89-进程生命周期管理)
- [8.10 Tags 系统](#810-tags-系统)
- [8.11 Listeners 进程出生/死亡通知](#811-listeners-进程出生死亡通知)
- [8.12 Cluster 集群视图](#812-cluster-集群视图)
- [8.13 平台抽象层 ServerPlatform](#813-平台抽象层-serverplatform)
- [8.14 用户与权限 UserMap](#814-用户与权限-usermap)
- [8.15 状态持久化与重启恢复](#815-状态持久化与重启恢复)
- [8.16 与 Reviver 的协作](#816-与-reviver-的协作)
- [8.17 特色实现深度剖析](#817-特色实现深度剖析)
- [8.18 本章小结](#818-本章小结)

---

## 8.1 bwmachined 概述

### 8.1.1 守护进程是什么

在 Unix 世界里,**守护进程(daemon)**是一种后台运行、没有控制终端的进程,通常在系统启动时启动,一直驻留到系统关闭。常见的 `syslogd`、`sshd`、`crond` 都属于这一类。守护进程有两个常见特点:

1. 通过 `fork()` 后父进程退出、子进程脱离控制终端(`setsid()`)的方式"后台化"。
2. 通过 `signal`(如 `SIGTERM`)接收管理指令。

BigWorld 在每台机器上跑一个 `bwmachined` 进程,本质上就是一个**专为游戏集群设计的守护进程**——但它的职责比传统 init 系统(systemd、sysvinit)更聚焦:它**只**管理 BigWorld 自己的服务器进程,而不管系统中其他无关服务。

### 8.1.2 位置与职责

`bwmachined` 的源码位于 `programming/bigworld/server/tools/bwmachined/`,在 `CMakeLists.txt` 中通过 `BW_ADD_EXECUTABLE( bwmachined ...)` 生成可执行文件,链接 `server`、`network`、`cstdmf` 三个库。它是一个**独立可执行进程**,不依赖 `BWResource`(注意 `main.cpp` 用的是 `BIGWORLD_MAIN_NO_RESMGR` 宏,而非普通的 `BIGWORLD_MAIN`)——这是因为 `bwmachined` 启动时还没有资源根,资源路径是从配置文件读出来的。

它的核心职责可以概括为五点:

| 职责 | 描述 | 关键源码 |
|---|---|---|
| 进程创建 | 接收 CreateMessage,fork/exec 拉起子进程 | `bwmachined.cpp:handleCreateMessage`、`linux_machine_guard.cpp:startProcess` |
| 进程注册与发现 | 子进程启动后向本地 bwmachined 注册自己的 pid/port/uid | `bwmachined.cpp:handleMessage` 的 `PROCESS_MESSAGE / REGISTER` 分支 |
| 进程信号 | 接收 SignalMessage,通过 kill() 给指定进程发信号 | `bwmachined.cpp:sendSignal` |
| 集群视图同步 | 多台机器的 bwmachined 互相发现、维护"全集群所有机器"列表 | `cluster.cpp:Cluster::chooseBuddy`、`BirthReplyHandler` |
| 资源监控 | 周期性采集 CPU/内存/网络统计,响应 WholeMachineMessage 查询 | `bwmachined.cpp:updateSystemInfo` |

### 8.1.3 设计理念

bwmachined 在设计上有几条贯穿始终的原则:

1. **中央控制、本地执行**:每个集群决策(比如"该把 BaseApp 开到哪台机器")是 BaseAppMgr 等管理器做出的,但**实际执行** fork/exec 必须由目标机器上的 bwmachined 完成——因为只有它能以正确的 uid/gid 在本地拉起进程,也只有它能管本地子进程的生命周期。
2. **轻量优先**:bwmachined 自己不依赖任何业务库,不持有实体、不读写数据库,只用 `select()` + UDP 包,保证它本身几乎不会成为故障源。
3. **去中心化的"中心"**:每台机器一个 bwmachined,它们之间通过 UDP 广播保持一份一致的集群视图,没有"主 bwmachined"的概念。这与 systemd 等单机守护进程截然不同。
4. **看门狗而非业务方**:bwmachined 不管游戏逻辑,业务故障由 Reviver 检测并委托 bwmachined 重启。这种"分工"避免了 bwmachined 卷入业务故障扩散。

---

## 8.2 源码结构全景

`server/tools/bwmachined/` 目录下约 20 个文件,可以按职责分组:

```
server/tools/bwmachined/
├── main.cpp                    # 程序入口,daemon 化,创建 BWMachined 单例
├── bwmachined.cpp/.hpp/.ipp    # 核心类 BWMachined,持有所有 Endpoint/Cluster/UserMap
├── cluster.cpp/.hpp             # 集群视图(BirthReplyHandler/FloodReplyHandler)
├── incoming_packet.cpp/.hpp    # 延迟处理的入站包封装
├── listeners.cpp/.hpp          # birth/death 监听器管理
├── linux_machine_guard.cpp/.hpp# Linux 平台特有:fork/exec、SIGCHLD、/proc 读取
├── common_machine_guard.hpp    # 跨平台公共定义:Stat、SystemInfo、ProcessInfo
├── server_platform.cpp/.hpp    # 平台抽象基类 ServerPlatform
├── server_platform_linux.cpp/.hpp # Linux 平台子类
├── usermap.cpp/.hpp            # UID -> UserMessage 映射
├── message_with_destination.hpp# 延迟发送的 Message 包装模板
├── process_binary_version.hpp  # BigWorld 版本对应的进程集合
└── CMakeLists.txt              # 构建配置
```

对应的"协议层"在另一处:`programming/bigworld/lib/network/machine_guard.hpp` 和 `machine_guard.cpp`。这是**客户端也共用**的库,任何要给 bwmachined 发消息的进程(cellapp、baseapp、reviver……)都会链接它。

理解 bwmachined 的关键是抓住一条主线:**"消息进来 → 分发 → 处理 → 回复"**。下面我们先看协议本身,再回到主程序。

---

## 8.3 MachineGuard 协议

### 8.3.1 协议位置与版本

MachineGuard 协议定义在 `lib/network/machine_guard.hpp`,所有消息都继承自 `MachineGuardMessage` 基类。这套协议本质上是**自定义的二进制 UDP 协议**,与 BigWorld 自己的 Mercury 通信框架(用于游戏内实体通信)是两套独立的设计。

`common_machine_guard.hpp` 顶部有一段长注释记录了从 Version 1 到 Version 50 的所有变更,例如:

```cpp
// Version 4: Added support for tags specified in /etc/bwmachined.conf
// Version 18: Broadcast-reply-based fault tolerance, handles segmentation
// Version 35: Preserve processes on restart; set BW_TIMING_METHOD for children
// Version 40: Added CreateWithArgsMessage
// Version 41: Added HighPrecisionMachineMessage
// Version 50: Add PARAM_GET_VERSION to UserMessage.

#define BWMACHINED_VERSION 50
```

**注意**:每次 Mercury 接口变化时这个版本号都要加 1。这与 `MERCURY_INTERFACE_VERSION`(在 `machine_guard.hpp:29` 定义为 1)是两回事——后者是游戏消息接口版本。

### 8.3.2 消息类型枚举

`MachineGuardMessage` 的核心是 `Message` 枚举(`machine_guard.hpp:124-145`),把消息分成两组:

```cpp
enum Message
{
    // tool/server -> machined messages (工具/服务进程 -> bwmachined)
    WHOLE_MACHINE_MESSAGE = 1,        // 查询整机状态(CPU/内存/网络)
    PROCESS_MESSAGE = 2,             // 进程注册/注销/通知
    PROCESS_STATS_MESSAGE = 3,       // 查询进程统计(CPU/内存)
    LISTENER_MESSAGE = 4,            // 注册 birth/death 监听器
    CREATE_MESSAGE = 5,              // 创建进程
    SIGNAL_MESSAGE = 6,              // 发送信号
    TAGS_MESSAGE = 7,                // 查询 tags
    USER_MESSAGE = 8,                // 查询用户信息
    PID_MESSAGE = 9,                  // 查询 PID 是否存活
    RESET_MESSAGE = 10,              // 重置 tags/usermap
    ERROR_MESSAGE = 11,
    QUERY_INTERFACE_MESSAGE = 12,    // 查询内部网卡 IP
    CREATE_WITH_ARGS_MESSAGE = 13,   // 创建进程(自定义参数)
    HIGH_PRECISION_MACHINE_MESSAGE = 14, // 高精度整机状态
    MACHINE_PLATFORM_MESSAGE = 15,   // 查询平台信息(OS 发行版)

    // machined -> machined messages (bwmachined 之间互发)
    MACHINED_ANNOUNCE_MESSAGE = 64,  // 机器出生/死亡/存在宣告
};
```

数值上 tool/server 消息从 1 开始,bwmachined 之间的消息从 64 开始,留出空间便于区分。这种"单枚举管理两类消息"的方式很简洁,但读代码时要注意区分——比如 `MACHINED_ANNOUNCE_MESSAGE` 永远不会被 Reviver 发出,只在 bwmachined 之间流动。

### 8.3.3 MGMPacket 包结构

多个 `MachineGuardMessage` 可以打包成一个 `MGMPacket`。包结构在 `machine_guard.hpp:41-98`:

```cpp
class MGMPacket
{
public:
    static const int MAX_SIZE = 32768;
    enum Flags {
        PACKET_STAGGER_REPLIES = 0x1   // 回复可以延迟(避免广播风暴)
    };

    uint8  flags_;
    uint32 buddy_;                      // 用于集群环
    MGMs  messages_;                    // vector<MachineGuardMessage*>
    ...
};
```

包格式如下:

```
┌──────────┬──────────┬──────────────────────────────────┐
│ flags(1) │ buddy(4) │ messages...                      │
└──────────┴──────────┴──────────────────────────────────┘
                              │
                              ▼ 每个 message 前有 uint16 长度前缀
                   ┌───────────┬────────────┬───────────┬────────┐
                   │ msglen(2) │ msgdata... │ msglen(2)│ msg... │
                   └───────────┴────────────┴───────────┴────────┘
```

`PACKET_STAGGER_REPLIES` 标志位是个非常贴心的设计——当一条消息以广播方式发出时,所有收到消息的机器会同时回包,容易造成"广播风暴"。设置了该标志后,bwmachined 会在 `0 ~ maxPacketDelayMillisec_`(默认 100ms)的随机延迟后才回包,从而把回复在时间轴上"摊平"。

### 8.3.4 关键消息类

`machine_guard.hpp` 中定义的所有消息类都继承自 `MachineGuardMessage`,主要的有:

| 类名 | 用途 | 关键字段 |
|------|------|---------|
| `CreateMessage` | 命令 bwmachined 启动一个进程 | `name_`(可执行文件名)、`config_`(Hybrid/Debug)、`uid_`、`recover_`、`fwdIp_`/`fwdPort_`(日志转发) |
| `CreateWithArgsMessage` | 同上但允许自定义命令行参数 | 在 CreateMessage 基础上增加 `Args args_` |
| `SignalMessage` | 给指定进程发 Unix 信号 | `signal_`(SIGINT/SIGQUIT/SIGUSR1)、继承自 ProcessMessage 的过滤字段 |
| `ProcessMessage` | 进程注册/注销/通知 | `param_`(REGISTER/DEREGISTER/NOTIFY_BIRTH/NOTIFY_DEATH)、`pid_`、`port_`、`uid_`、`name_`、`id_` |
| `ProcessStatsMessage` | 进程统计 | 在 ProcessMessage 上增加 `cpu_`、`mem_` |
| `ListenerMessage` | 注册 birth/death 监听器 | `preAddr_`/`postAddr_`(原始字节序列) |
| `TagsMessage` | 查询 tags | `tags_`(vector<string>)、`exists_` |
| `UserMessage` | 查询用户信息 | `uid_`、`gid_`、`username_`、`home_`、`mfroot_`、`bwrespath_`、`coredumps_` |
| `PidMessage` | 查询 PID 是否存活 | `pid_`、`running_` |
| `WholeMachineMessage` | 整机状态 | `cpuLoads_`、`mem_`、`ifStats_` |
| `MachinedAnnounceMessage` | bwmachined 之间宣告存在 | `type_`(ANNOUNCE_BIRTH/DEATH/EXISTS)、`count_`/`addr_` |

注意 `SignalMessage` 提供了三个便捷方法(`machine_guard.hpp:710-712`),把 Unix 信号映射到"业务语义":

```cpp
void setControlledShutdown() { signal_ = SIGUSR1; }  // 受控关闭
void setKill()              { signal_ = SIGINT; }   // 温和终止
void setHardKill()          { signal_ = SIGQUIT; }  // 强制终止
```

业务侧只要调用 `setControlledShutdown()`,就不用直接面对信号数值。

### 8.3.5 ReplyHandler 回调模型

bwmachined 的客户端(如 Reviver)通常不会自己解析原始字节,而是用 `ReplyHandler` 回调模型(`machine_guard.hpp:203-245`):

```cpp
class ReplyHandler
{
public:
    virtual bool onWholeMachineMessage( WholeMachineMessage &wmm, uint32 addr );
    virtual bool onCreateMessage( CreateMessage &cm, uint32 addr );
    virtual bool onSignalMessage( SignalMessage &sm, uint32 addr );
    virtual bool onTagsMessage( TagsMessage &tm, uint32 addr );
    // ... 每种消息一个回调
    virtual bool onUnhandledMsg( MachineGuardMessage &mgm, uint32 addr );
};
```

调用方实现感兴趣的回调,通过 `mgm.sendAndRecv(ep, addr, &handler)` 一次性发送请求并接收所有回复。每个回调返回 `true` 表示继续接收下一条回复,`false` 表示提前结束——这对广播查询很有用,可以"够用即停"。

---

## 8.4 主程序与启动流程

### 8.4.1 main.cpp 入口

`main.cpp` 是 bwmachined 的入口,使用 `BIGWORLD_MAIN_NO_RESMGR` 宏(而不是 `BIGWORLD_MAIN`),意味着不依赖 `BWResource`——这是因为 bwmachined 启动时还没有资源根。整个 main 函数非常短(`main.cpp:27-128`),逻辑清晰:

```cpp
int BIGWORLD_MAIN_NO_RESMGR( int argc, char * argv[] )
{
    bool daemon = true;
    BW::string pidPath = "";

    // 1. 解析命令行
    for (int i = 1; i < argc; ++i) {
        if (!strcmp( argv[i], "-f" ) || !strcmp( argv[i], "--foreground" ))
            daemon = false;
        else if ((strcmp( argv[i], "-p" ) == 0) ||
                 (strcmp( argv[i], "--pid" ) == 0)) {
            ++i;
            pidPath = argv[i];
        }
        else if ((strcmp( argv[i], "-v" ) == 0) ||
                 (strcmp( argv[i], "--version" ) == 0)) {
            // 打印版本
        }
        else if (strcmp( argv[i], "--help" ) == 0) { ... }
    }

    // 2. 打开 syslog
    openlog( argv[0], 0, LOG_DAEMON );

    // 3. 提前创建 BWMachined 实例(便于报错)
    BWMachined machined;

    if (daemon && !pidPath.empty())
        machined.setPidPath( pidPath );

    // 4. 把自己变成 daemon
    initProcessState( daemon );

    // 5. 设置 core dump 大小不限制
    rlimit rlimitData = { RLIM_INFINITY, RLIM_INFINITY };
    bw_prlimit( 0, RLIMIT_CORE, &rlimitData, NULL );

    // 6. 检查内核 socket buffer 大小
    checkSocketBufferSizes();

    // 7. 把文件描述符硬限制提到 16384
    raiseFileDescriptorHardLimit( desiredMaximumFileDescriptorHardLimit );

    // 8. 进入主循环
    if (BWMachined::pInstance())
        return machined.run();
    else
        return EXIT_FAILURE;
}
```

几个值得注意的细节:

- **daemon 化**:`initProcessState(daemon)`(在 `linux_machine_guard.cpp:58-71`)内部调用 `daemon(0,0)` 把进程脱离控制终端。同时安装 `SIGCHLD` 处理器回收僵尸子进程。
- **core 文件**:`RLIMIT_CORE` 设为 `RLIM_INFINITY`,这样子进程 crash 时能产生完整的 core dump,便于事后调试。
- **文件描述符**:`raiseFileDescriptorHardLimit(16384)` 把硬限制提到 16384。这是给子进程用的——子进程的软限制不能超过父进程的硬限制,所以 bwmachined 必须先把硬限制抬上去。注意,这只是为子进程"打开天花板",子进程自己还需要 `setrlimit` 提升软限制才能用。
- **socket buffer**:`checkSocketBufferSizes()` 检查内核的 `rmem_default`/`wmem_default`,如果太小就告警。这是 UDP 大包的兜底保护。

### 8.4.2 BWMachined 构造函数

构造函数 `BWMachined::BWMachined()` 在 `bwmachined.cpp:60-139`,做了 6 件事:

1. **初始化成员**:`pServerPlatform_ = new ServerPlatformLinux`、`birthListeners_`/`deathListeners_` 持有 platform 引用、`pServerInfo_ = new ServerInfo`、`maxPacketDelayMillisec_ = 100`。
2. **检查平台初始化**:`pServerPlatform_->isInitialised()`,Linux 平台初始化失败立即 `exit(EXIT_FAILURE)`。
3. **flush 用户表**:`users_.flush()` 读取 `/etc/passwd` 和所有 `~/.bwmachined.conf`,初始化 UID 到 UserMessage 的映射。
4. **创建 3 个 UDP Endpoint**:`ep_`、`epLocal_`、`epBroadcast_`,都 socket 为 `SOCK_DGRAM`。
5. **读配置**:`readConfigFile()` 解析 `/etc/bwmachined.conf` 和 `/etc/bigworld.conf`,填充 `tags_` map。同时提取 `timing_method`、`internal_interface`、`max_packet_delay` 等选项。
6. **初始化网络接口**:`initNetworkInterfaces()` 找到广播网卡地址、bind 三个 endpoint。
7. **采集系统信息**:`updateSystemInfo()` 第一次执行,填充 `SystemInfo` 中的 CPU/内存/网络统计字段。
8. **加载持久化状态**:`load()` 读取 `/var/run/bwmachined.state`,恢复之前 bwmachined 重启时遗留的进程表(详见 8.15 节)。
9. **注册 SIGTERM 处理器**:`signal( SIGTERM, sigterm )`,收到 SIGTERM 时调用 `save()` 把进程表写到状态文件,然后让主循环退出。

注意构造函数中会**强行 `exit()`**——这是 daemon 启动期的常见做法:既然要做"机器管家",启动期任何致命错误都直接退出,让 init.d/systemd 重启自己,而不是带病运行。

---

## 8.5 三端点与广播接口发现

### 8.5.1 三个 UDP Endpoint

bwmachined 监听三个 UDP Endpoint(`bwmachined.hpp:97-103`):

| Endpoint | 绑定地址 | 用途 |
|----------|---------|------|
| `ep_` | `<broadcastInterface>:PORT_MACHINED` | 主端点,收发常规消息(包括来自其他 bwmachined 的) |
| `epLocal_` | `127.0.0.1:PORT_MACHINED` | 本机回环,本机进程优先走这条 |
| `epBroadcast_` | `255.255.255.255:PORT_MACHINED` | 广播端点,接收广播消息 |

`PORT_MACHINED = 20018`(定义在 `lib/network/portmap.hpp:13`)。区分三个端点的好处:

- 本机进程给 bwmachined 发消息走 `127.0.0.1`,不占用网卡带宽,也不影响其他机器。
- 远程机器(其他 bwmachined、远程工具)走 `ep_` 上的真实 IP。
- 广播消息(如 `ANNOUNCE_BIRTH`)走 `epBroadcast_`,这样即使主端点 bind 到了某个非默认网卡,广播也能被收到。

### 8.5.2 广播接口自动发现

`findBroadcastInterface()`(`bwmachined.cpp:237-334`)是个非常巧妙的设计。问题是:一台机器可能有多个网卡(eth0、eth1、docker0……),bwmachined 不知道应该 bind 哪一个用于集群通信。它的解法是"**自己发自己收**":

```
1. 创建临时 endpoint epListen,bind 到 0.0.0.0:PORT_BROADCAST_DISCOVERY (20019)
2. 调用 getInterfaces() 枚举本机所有网卡 IP
3. 通过 epListen 发送 QueryInterfaceMessage 广播到 255.255.255.255
4. select() 等待 1 秒
5. 收到自己的广播包,看是从哪个网卡回来的
6. 这个网卡就是默认广播网卡(broadcastAddr_)
```

关键代码片段:

```cpp
QueryInterfaceMessage qim;
qim.sendto( epListen, htons( PORT_BROADCAST_DISCOVERY ),
            BROADCAST, MGMPacket::PACKET_STAGGER_REPLIES );

// ... select 等待 ...

// 检查收到的包是从哪个本地网卡回来的
iter = interfaces.find( (u_int32_t &)sin.sin_addr.s_addr );
if (iter != interfaces.end())
{
    broadcastAddr_ = sin.sin_addr.s_addr;
    break;
}
```

这种"自发自收"模式避免了依赖外部配置,在多网卡机器上能自动找到正确的那块网卡。如果配置文件里有 `internal_interface = eth0` 之类的选项,则优先使用配置(`bwmachined.cpp:666-733`)。

---

## 8.6 主事件循环

### 8.6.1 run() 概览

主循环在 `bwmachined.cpp:761-879`,逻辑非常清晰:

```cpp
int BWMachined::run()
{
    // 1. 启动集群出生定时器(birth handler)
    cluster_.birthHandler_.addTimer();
    cluster_.floodTriggerHandler_.addTimer();

    // 2. 启动周期更新定时器(每 1000ms 一次)
    UpdateHandler updateHandler( *this );
    callbacks_.add( this->timeStamp() + UPDATE_INTERVAL,
                    UPDATE_INTERVAL, &updateHandler, NULL, "UpdateHandler" );

    // 3. 写 PID 文件(如果配置了 -p 参数)
    if (!pidPath_.empty()) {
        FILE * pidFile = fopen( pidPath_.c_str(), "w" );
        fprintf( pidFile, "%d", mf_getpid() );
        fclose( pidFile );
    }

    // 4. 进入主 select 循环
    while (g_serverRunning)
    {
        // 4a. 处理定时器回调
        TimeQueue64::TimeStamp tickTime = this->timeStamp();
        callbacks_.process( tickTime );

        // 4b. 计算下一个定时器到期的等待时间
        TimeQueue64::TimeStamp ttn = callbacks_.nextExp( tickTime );
        timeStampToTV( ttn, tv );

        // 4c. select 等待三个端点 + 子进程状态管道
        FD_ZERO( &fds );
        FD_SET( ep_.fileno(), &fds );
        FD_SET( epBroadcast_.fileno(), &fds );
        FD_SET( epLocal_.fileno(), &fds );

        int osmaxfd = getInterestingFds( &fds, NULL, NULL );
        int selgot = select( std::max( maxfd+1, osmaxfd+1 ),
                             &fds, NULL, NULL, &tv );

        // 4d. 处理就绪的端点
        if (FD_ISSET( ep_.fileno(), &fds ))
            this->readPacket( ep_, tickTime );
        if (FD_ISSET( epLocal_.fileno(), &fds ))
            this->readPacket( epLocal_, tickTime );
        if (FD_ISSET( epBroadcast_.fileno(), &fds ))
            this->readPacket( epBroadcast_, tickTime );

        // 4e. 处理子进程状态管道(fork/exec 的状态回报)
        handleInterestingFds( &fds, NULL, NULL );
    }

    callbacks_.clear();
    return exitCode;
}
```

这是一个经典的 **reactor 模式**——单线程 + `select()` 多路复用 + 定时器队列。所有"事件"都被转化为"在 fd 上读写"或"定时器到期",在统一的循环里处理。这种设计的好处:

- **单线程**:不需要任何锁,因为只有一个执行流。
- **可预测**:任何 handler 都是同步执行,完成才会回到 select。
- **简单**:不需要协程、不需要异步框架。

代价是:**任何 handler 都不能阻塞太久**。bwmachined 的所有 handler 都被设计为非阻塞——比如 `handleCreateMessage` 拉起子进程用 `fork()`(几乎瞬时完成),不会等子进程初始化完毕。

### 8.6.2 三种"事件源"

从上面的循环可以看出,bwmachined 处理三类事件源:

1. **UDP 包**(三个 endpoint):常规 MachineGuard 消息、广播消息、本机回环消息。
2. **定时器**(`callbacks_` 是 `TimeQueue64`):
   - `UpdateHandler`:每 1000ms 触发 `update()`,采集系统信息、检查进程存活、清理死监听器、回收僵尸子进程。
   - `Cluster::BirthReplyHandler`:启动期广播 `ANNOUNCE_BIRTH` 并收集其他机器回应,确定集群规模。
   - `Cluster::FloodTriggerHandler`:周期性广播 keepalive,检测集群成员变化。
   - `IncomingPacket`:延迟处理的广播包(`PACKET_STAGGER_REPLIES` 标志触发)。
3. **子进程状态管道**(`getInterestingFds` / `handleInterestingFds`):fork 出来的子进程在 exec 之前通过管道回报"我成功 exec 了"还是"exec 失败了"——这是 8.8 节会详解的机制。

### 8.6.3 包读取与延迟处理

`readPacket()`(`bwmachined.cpp:885-923`)做了一件重要的事——如果包带 `PACKET_STAGGER_REPLIES` 标志,就**不立即处理**,而是封装成 `IncomingPacket` 扔进定时器队列,延迟一个 0~100ms 的随机时间再处理:

```cpp
if (pPacket->shouldStaggerReply())
{
    callbacks_.add( tickTime + (rand() % maxPacketDelayMillisec_),
                    0, &packetTimeoutHandler_,
                    new IncomingPacket( *this, pPacket, sin ),
                    "IncomingPacket" );
    return;
}

this->handlePacket( ep, sin, *pPacket );
```

这就是广播风暴抑制的核心实现。当一条广播发到 100 台机器时,如果大家都立刻回包,瞬间会有 100 个回包涌向源机器,可能丢包。设了 stagger 标志后,每台机器在 0~100ms 内随机挑一个时间回包,流量被自然摊平。

---

## 8.7 消息分发与 handleMessage

### 8.7.1 handlePacket 与 handleMessage

包级别的入口是 `handlePacket`(`bwmachined.cpp:1114-1144`),它遍历包内所有消息,逐个调用 `handleMessage`,把回复累积到 `replies` 包中,最后统一回送:

```cpp
void BWMachined::handlePacket( Endpoint & ep, sockaddr_in & sin,
    MGMPacket & packet )
{
    MGMPacket replies;

    for (unsigned i=0; i < packet.messages_.size(); i++)
    {
        if (!this->handleMessage( ep, sin, *packet.messages_[i], replies ))
            return;
    }

    if (replies.messages_.size() > 0)
    {
        MemoryOStream os;
        if (replies.write( os ))
            ep.sendto( os.data(), os.size(), sin );
    }
}
```

### 8.7.2 handleMessage 的 switch 分发

`handleMessage`(`bwmachined.cpp:1150-1719`)是一个超大的 switch,根据 `mgm.message_` 字段分发到对应的处理逻辑。下表是各 case 的职责:

| case | 处理逻辑 |
|------|---------|
| `LISTENER_MESSAGE` | 注册 birth/death 监听器(`birthListeners_.add` 或 `deathListeners_.add`) |
| `WHOLE_MACHINE_MESSAGE` | 返回 `systemInfo_.m`(低精度整机状态) |
| `HIGH_PRECISION_MACHINE_MESSAGE` | 返回 `systemInfo_.hpm`(高精度整机状态) |
| `MACHINE_PLATFORM_MESSAGE` | 返回 OS 信息(`PlatformInfo::str()`) |
| `PROCESS_MESSAGE` | 处理 REGISTER/DEREGISTER/NOTIFY_BIRTH/NOTIFY_DEATH 四个子类型 |
| `PROCESS_STATS_MESSAGE` | 查询匹配的进程,返回 CPU/内存占用 |
| `CREATE_MESSAGE` / `CREATE_WITH_ARGS_MESSAGE` | 委托给 `handleCreateMessage` |
| `SIGNAL_MESSAGE` | 调用 `sendSignal` 给匹配进程发 Unix 信号 |
| `TAGS_MESSAGE` | 查询 tags 列表 |
| `USER_MESSAGE` | 查询用户信息(UID/username/home/mfroot/bwrespath/coredumps) |
| `PID_MESSAGE` | 查询 PID 是否存活 |
| `RESET_MESSAGE` | 重新读 config + flush usermap |
| `MACHINED_ANNOUNCE_MESSAGE` | 处理其他 bwmachined 的 birth/death/exists 宣告 |
| `QUERY_INTERFACE_MESSAGE` | 返回本机内部网卡 IP |

注意几个**安全防护**:

- `PROCESS_MESSAGE` 的 REGISTER/DEREGISTER 子类型只接受来自 `127.0.0.1` 或 `ownAddr_` 的请求(`bwmachined.cpp:1280-1287`),防止其他机器在本地"假注册"进程。
- `QUERY_INTERFACE_MESSAGE` 只支持 `INTERNAL` 类型(`bwmachined.cpp:1694`),未来扩展会加新枚举。
- `MESSAGE_NOT_UNDERSTOOD` 标志的消息会被直接 echo 回去(`bwmachined.cpp:1156-1162`),让客户端知道"消息没被理解"。

---

## 8.8 进程创建流程详解

### 8.8.1 CreateMessage 字段

`CreateMessage`(`machine_guard.hpp:638-662`)是 bwmachined 最核心的消息之一,字段如下:

```cpp
class CreateMessage : public MachineGuardMessage
{
public:
    BW::string  name_;      // 可执行文件名,如 "cellapp"
    BW::string  config_;    // 配置类型:"Hybrid" 或 "Debug"
    UserId      uid_;       // 以哪个 UID 启动
    uint8       recover_;   // 是否带 -recover 参数(崩溃恢复模式)
    uint32      fwdIp_;     // 日志转发目标 IP
    uint16      fwdPort_;   // 日志转发目标端口
};
```

注意 `name_` **只是文件名**,不包含路径——路径由 bwmachined 根据用户的 `mfroot_` + `config_` 推导出来。比如 `name_="cellapp"`, `config_="Hybrid"`, `mfroot_="/home/bigworld"`,最终路径可能是 `/home/bigworld/game/bin/server/centos7_x86_64_debug/server/cellapp`(具体见 8.13 节的 path 后缀表)。

`CreateWithArgsMessage` 是子类,在 `CreateMessage` 基础上增加 `Args args_`(用户自定义命令行参数),不会自动加 `-machined`、`-recover`、`-forward` 等 BigWorld 标准参数。

### 8.8.2 handleCreateMessage 全流程

`handleCreateMessage`(`bwmachined.cpp:1725-1929`)是 CreateMessage 的处理函数,流程很长但分步清晰:

```
1. 收到 CreateMessage,准备 PidMessageWithDestination 用于回复
2. 用 cm.uid_ 在 UserMap 中查找用户
3. 如果用户不存在,getpwuid() 查系统密码表
4. getEnv() 读取用户的 ~/.bwmachined.conf 或 /etc/bigworld.conf
   获取 mfroot_(BigWorld 安装根) 和 bwrespath_(资源根)
5. 校验 config_ 字段,只允许 "Hybrid" 或 "Debug"
6. 安全检查:name_ 和 config_ 不能含 ".."
7. 安全检查:不能运行 commands/_helpers 下的程序(setuid root)
8. findUserBinaryDirForConfig() 推导二进制目录
9. startProcess() 调用 fork/exec 启动进程
10. 等待子进程管道回报 exec 结果,填充 PidMessage 回复
```

几个关键的安全检查值得展开:

#### (1) 路径穿越防护

```cpp
if (cm.name_.find( ".." ) != BW::string::npos ||
    cm.config_.find( ".." ) != BW::string::npos)
{
    syslog( LOG_ERR, "Illegal '..' in process name or config" );
    // 拒绝
}
```

防止攻击者构造 `name_="../../../bin/sh"` 来执行任意程序。

#### (2) setuid 程序保护

```cpp
if (cm.name_.find( "commands/_helpers" ) != BW::string::npos)
{
    syslog( LOG_ERR, "Denied request to run _helper process '%s'",
        cm.name_.c_str() );
    // 拒绝
}
```

`commands/_helpers` 目录下的程序是 setuid root 的辅助工具,不能被远程调用。代码注释也承认这个检查不严密——但既然 bwmachined 已经运行在可信环境(内网集群),这只是个"友情提示"。

#### (3) UID 必须真实存在

```cpp
struct passwd *ent = getpwuid( cm.uid_ );
if (ent == NULL)
{
    syslog( LOG_ERR, "UID %d doesn't exist on this system", cm.uid_ );
    // 拒绝
}
```

防止用不存在的 UID 启动进程——否则子进程会以 unexpected UID 运行,可能造成文件权限错乱。

### 8.8.3 fork/exec 的核心实现

`startProcess` 在 `linux_machine_guard.cpp:328-470`,这是 Linux 平台特有的实现。流程:

```
1. pipe(statusPipe) 创建父子进程间的状态管道
2. fork():
   子进程分支:
     a. close 读端
     b. fcntl(F_SETFD, FD_CLOEXEC) 让写端在 exec 时自动关闭
     c. setgid(gid) 切换组
     d. setuid(uid) 切换用户
     e. chdir 到二进制目录
     f. 组装 argv(包括 --res bwrespath)
     g. close 父进程的 endpoint(避免子进程占着 socket)
     h. close 其他子进程的状态管道
     i. putenv 设置 BW_TIMING_METHOD 和 HOME
     j. execv() 执行新程序
     k. 如果 exec 失败,write errno 到管道,exit
   父进程分支:
     a. close 写端
     b. 把读端加入 s_pendingProcesses map
     c. 设置 pPmwd->pid_ = childpid,返回 false(表示状态待定)
3. 主循环 select 检测到管道可读时:
   - read 长度 0:exec 成功(管道被 FD_CLOEXEC 关闭了)
   - read 长度 -1:read 出错,假定 exec 失败
   - read 长度 sizeof(errno):exec 失败,errno 是失败原因
```

关键代码片段:

```cpp
if ((childpid = fork()) == 0)
{
    close( statusPipe[ 0 ] );

    // FD_CLOEXEC 是关键:exec 成功时管道会被自动关闭,父进程 read 返回 0
    if (fcntl( statusPipe[ 1 ], F_SETFD, FD_CLOEXEC ) == -1)
    {
        write( statusPipe[ 1 ], &errno, sizeof( errno ) );
        exit( EXIT_FAILURE );
    }

    setgid( gid );
    setuid( uid );

    chdir( path );
    machined.closeEndpoints();   // 关闭父进程的 socket
    putEnvAlloc( "BW_TIMING_METHOD", machined.timingMethod() );
    putEnvAlloc( "HOME", home );

    int result = execv( path, const_cast< char * const * >( argv ) );

    // 走到这里说明 exec 失败
    write( statusPipe[ 1 ], &errno, sizeof( errno ) );
    exit( EXIT_FAILURE );
}
else if (childpid > 0)
{
    close( statusPipe[ 1 ] );
    s_pendingProcesses[ statusPipe[ 0 ] ] =
        std::make_pair( pPmwd, BW::string( binaryName ) );
    pPmwd->pid_ = (uint16)childpid;
    return false;
}
```

#### "管道 + FD_CLOEXEC" 技巧

这是一个非常经典的 Unix 技巧。问题:fork 之后,父进程怎么知道子进程的 `execv` 成功了没有?

- 如果 exec 成功,新程序会替换当前进程映像,所有 `FD_CLOEXEC` 标志的文件描述符都会被关闭——管道写端关闭,父进程 `read` 会读到 EOF(长度 0)。
- 如果 exec 失败,子进程仍然在原始代码里,可以 `write` errno 到管道,父进程 `read` 会读到 4 字节的 errno。

这种"FD_CLOEXEC + 管道"模式避免了父进程同步等待,既保留了异步性,又获得了 exec 状态反馈。

#### 父进程关闭子进程 socket 的必要性

```cpp
machined.closeEndpoints();   // 子进程关闭从父进程继承的 socket
```

这是 fork 后**必须**做的——否则子进程会持有 bwmachined 的 socket 副本,即使 bwmachined 退出,socket 也不会真正释放,导致 PORT_MACHINED 被占用,bwmachined 无法重启。同时子进程也会关闭其他 pending 子进程的管道(`s_pendingProcesses`),避免 fd 泄漏。

### 8.8.4 子进程的注册

`fork/exec` 成功后,新进程(cellapp、baseapp 等)启动时会通过 `bwservice` 框架向 bwmachined 发送 `PROCESS_MESSAGE / REGISTER`:

```cpp
case ProcessMessage::REGISTER:
{
    // 检查重复 PID/端口
    unsigned int i = 0;
    while (i < procs_.size()) {
        if ((pm.pid_ == psm.pid_) && (pm.category_ == psm.category_) &&
            (pm.name_ == psm.name_))
            break;
        if (pm.port_ == psm.port_) {
            // 同端口已被占用,踢掉旧的
            removeRegisteredProc( i );
        } else {
            ++i;
        }
    }

    if (i < procs_.size()) {
        // 重复注册,警告
    } else {
        procs_.push_back( ProcessInfo() );
    }

    ProcessInfo &pi = procs_[i];
    pi.m << pm;
    pi.m.outgoing( true );

    // 立即 update 两次,确保字段可读
    for (int j=0; j < 2; j++)
        updateProcessStats( pi );

    pi.init( pm );

    // 通知集群内所有 birth listener
    broadcastToListeners( pm, pm.NOTIFY_BIRTH );

    // 回 ack
    pm.outgoing( true );
    replies.append( pm );

    return true;
}
```

注意几个细节:

- **端口冲突检测**:如果新注册的进程用了已被占用端口,旧的会被踢掉(`removeRegisteredProc`),这处理了"进程死了但没来得及 deregister"的情况。
- **两次 `updateProcessStats`**:`/proc/<pid>/stat` 中的 utime/stime 是累计值,需要两次采样才能算出 delta。第一次采样只能初始化"old",第二次才能算出"cur"。
- **广播 NOTIFY_BIRTH**:任何在集群内注册过 birth listener 的进程(包括 Reviver)都会收到通知。

---

## 8.9 进程生命周期管理

### 8.9.1 完整的生命周期

把前面的内容串起来,一个进程从被创建到死亡的完整生命周期:

```
                      ┌─────────────────────────┐
                      │  CellAppMgr 决定开 cellapp │
                      └────────────┬────────────┘
                                   │ CreateMessage(uid=1001, name="cellapp")
                                   ▼
                      ┌─────────────────────────────┐
                      │  bwmachined (本机)           │
                      │  handleCreateMessage       │
                      │  → fork + exec(cellapp)    │
                      └────────────┬────────────┘
                                   │ fork/exec 成功
                                   ▼
                      ┌─────────────────────────┐
                      │  cellapp 子进程运行      │
                      │  - bwservice 初始化     │
                      │  - 发 PROCESS_MESSAGE   │
                      │    / REGISTER 给 machined │
                      └────────────┬────────────┘
                                   │ REGISTER
                                   ▼
                      ┌─────────────────────────┐
                      │  bwmachined              │
                      │  procs_.push_back(pi)   │
                      │  broadcastToListeners   │
                      │    (NOTIFY_BIRTH 广播) │
                      └────────────┬────────────┘
                                   │ NOTIFY_BIRTH
                                   ▼
                      ┌─────────────────────────┐
                      │  Reviver (集群内)        │
                      │  birthListeners_.add    │
                      │  开始定期 ping          │
                      └────────────┬────────────┘
                                   │
                                   │ 进程异常退出 / 收到 SignalMessage
                                   ▼
                      ┌─────────────────────────┐
                      │  bwmachined              │
                      │  update() 检测不到 /proc │
                      │    <pid>/stat            │
                      │  removeRegisteredProc   │
                      │  broadcastToListeners   │
                      │    (NOTIFY_DEATH 广播) │
                      └────────────┬────────────┘
                                   │ NOTIFY_DEATH
                                   ▼
                      ┌─────────────────────────┐
                      │  Reviver                 │
                      │  收到 death 通知         │
                      │  → 检查 ping 双重确认   │
                      │  → 发 CreateMessage     │
                      │    (recover=1) 重启      │
                      └──────────────────────────┘
```

### 8.9.2 update() 周期检查

`update()`(`bwmachined.cpp:1026-1049`)由 `UpdateHandler` 每 1000ms 触发,做四件事:

```cpp
void BWMachined::update()
{
    // 1. 更新整机统计(CPU/内存/网络)
    this->updateSystemInfo();

    // 2. 检查所有注册的进程
    for (unsigned int i=0; i < procs_.size(); i++)
    {
        ProcessInfo &pi = procs_[ i ];
        if (!updateProcessStats( pi ) && errno == ENOENT)
        {
            syslog( LOG_ERR, "%s (uid:%d) died without deregistering!\n",
                pi.m.c_str(), pi.m.uid_ );
            removeRegisteredProc( i-- );
        }
    }

    // 3. 清理死监听器
    birthListeners_.checkListeners();
    deathListeners_.checkListeners();

    // 4. 回收僵尸子进程(防御性,即使 SIGCHLD 没触发)
    waitpid( -1, NULL, WNOHANG );
}
```

进程存活检测在 `updateProcessStats`(`linux_machine_guard.cpp:190-236`):打开 `/proc/<pid>/stat`,如果失败且 `errno == ENOENT`,说明进程不存在了。注意还有一个**starttime 校验**机制:

```cpp
if ((pi.starttime) && (pi.starttime != starttime))
{
    syslog( LOG_ERR, "updateProcessStats: Process %d starttime differs "
            "from last known starttime (old %lu, curr %lu).",
            (int)pi.m.pid_, pi.starttime, starttime );
    return false;
}
```

如果同一个 PID 现在的 starttime 与记录的不同,说明原进程已死、PID 被新进程复用了——这也是"死亡"。这种 PID 复用是 Unix 系统中常见的陷阱,bwmachined 通过 `starttime` 字段规避了。

### 8.9.3 sendSignal 信号发送

`sendSignal`(`bwmachined.cpp:1094-1108`)是 SignalMessage 的处理函数:

```cpp
void BWMachined::sendSignal (const SignalMessage & sm)
{
    for (uint i=0; i < procs_.size(); i++)
    {
        ProcessInfo &pm = procs_[i];
        if (pm.m.matches( sm ))    // 用 ProcessMessage::matches 过滤
        {
            kill( pm.m.pid_, sm.signal_ );
            syslog( LOG_INFO, "sendSignal: signal = %d pid = %d uid = %d",
                sm.signal_, pm.m.pid_, pm.m.uid_ );
        }
    }
}
```

`matches` 方法根据 `param_` 字段中设置的过滤位(`PARAM_USE_UID`/`PARAM_USE_PID`/`PARAM_USE_PORT`/`PARAM_USE_NAME` 等)来决定是否匹配。这样一个 SignalMessage 可以**精准**到"给 pid=12345 发 SIGUSR1",也可以**批量**到"给所有 baseapp 发 SIGINT"。

### 8.9.4 优雅关闭

bwmachined 自己的优雅关闭流程:

1. 收到 `SIGTERM`(`bwmachined.cpp:46-54`)。
2. `sigterm` 处理函数调用 `save()` 把进程表写到 `/var/run/bwmachined.state`。
3. `g_serverRunning = false`,主循环退出。
4. 析构函数清理 PID 文件、删除 `pServerInfo_`。

注意 bwmachined **不会**主动给所有子进程发 SIGTERM——这是子进程自己的责任(它们自己注册了 SIGTERM handler,会自行优雅退出)。bwmachined 只是"户籍警",不主动终止进程。要"杀掉某台机器上所有 baseapp",得通过 `bwmachined_tool` 之类的工具发送 SignalMessage。

---

## 8.10 Tags 系统

### 8.10.1 Tags 是什么

Tags 是 bwmachined 配置文件中的"分类标签"机制。`/etc/bwmachined.conf` 是个简单的 INI-like 文件,格式如下:

```ini
[bwmachined]
timing_method=gettime
max_packet_delay=100

[Components]
baseapp
cellapp
loginapp

[home]
/home/bigworld

[Tags]
cell
base
```

`BWMachined::readConfigFile`(`bwmachined.cpp:543-600`)解析这个文件,把每个 `[xxx]` 段当成一个 tag,段内的每行作为该 tag 下的一个值,存入 `tags_` map:

```cpp
typedef BW::map< BW::string, Tags > TagsMap;   // Tags = vector<string>
TagsMap tags_;
```

比如上面的配置会产生:

```
tags_["bwmachined"]    = ["timing_method=gettime", "max_packet_delay=100"]
tags_["Components"]    = ["baseapp", "cellapp", "loginapp"]
tags_["home"]          = ["/home/bigworld"]
tags_["Tags"]          = ["cell", "base"]
```

### 8.10.2 Tags 的查询

`TAGS_MESSAGE` 的处理在 `bwmachined.cpp:1462-1505`:

```cpp
case MachineGuardMessage::TAGS_MESSAGE:
{
    TagsMessage &tm = static_cast< TagsMessage& >( mgm );

    // 查询必须只传一个 tag
    if (tm.tags_.size() != 1) return false;

    BW::string query = tm.tags_[0];
    tm.tags_.clear();

    // 空查询返回所有 tag 分类名
    if (query == "")
    {
        for (TagsMap::iterator it = tags_.begin(); it != tags_.end(); ++it)
            tm.tags_.push_back( it->first );
        tm.exists_ = true;
    }
    // 否则返回指定分类下的值
    else
    {
        TagsMap::iterator it = tags_.find( query );
        if (it != tags_.end())
        {
            Tags &tags = it->second;
            tm.tags_.resize( tags.size() );
            std::copy( tags.begin(), tags.end(), tm.tags_.begin() );
            tm.exists_ = true;
        }
        else
            tm.exists_ = false;
    }

    tm.outgoing( true );
    replies.append( tm );
    return true;
}
```

查询接口很简单:**空字符串** → 列出所有 tag 分类;**非空** → 返回该分类下的所有值。`exists_` 字段表示分类是否存在。

### 8.10.3 Tags 的使用场景

Tags 不是装饰品,它有几个真实的使用场景:

1. **Components tag**:Reviver 启动时会查询 `Components` tag(`reviver.cpp` 的 `queryMachinedSettings`),决定本机要监控哪些类型的进程。如果 `Components` 列了 `baseapp cellapp loginapp`,本机的 Reviver 就只监控这三类;如果某个 Component 在 tag 里没列,即使本机有这种进程在跑,Reviver 也不会管。
2. **bwmachined tag**:`bwmachined` 段下的 `timing_method`、`max_packet_delay`、`internal_interface` 等选项通过 `findOption` 提取。注意 `findOption` 走的是"行内查找"——形如 `key=value` 的行。
3. **用户自定义**:集群管理员可以加任意自定义 tag,工具可以查询它做路由决策。例如,可以在不同机器上配置 `[Roles]` 段,标记这台机器是 "login_zone" 还是 "cell_zone",然后让某个部署工具查询这个 tag 决定部署什么进程。

### 8.10.4 BaseAppMgr / CellAppMgr 与 tags

虽然 BaseAppMgr、CellAppMgr 不直接调用 `queryMachinedSettings`,但它们通过另一种方式间接使用 tags——它们在选 BaseApp/CellApp 时会查询本机进程列表(`PROCESS_STATS_MESSAGE`),而本机的进程列表本身就是被 tags 决定的(只有 Components tag 里列出的进程类型,Reviver 才会监控和重启)。所以 tags 实际上决定了"这台机器应该跑什么类型的进程"。

---

## 8.11 Listeners 进程出生/死亡通知

### 8.11.1 ListenerMessage 注册

`ListenerMessage`(`machine_guard.hpp:604-632`)继承自 `ProcessMessage`,用于在 bwmachined 注册一个 birth 或 death 监听器:

```cpp
class ListenerMessage : public ProcessMessage
{
public:
    enum Type
    {
        ADD_BIRTH_LISTENER = 0,    // 监听进程出生
        ADD_DEATH_LISTENER = 1     // 监听进程死亡
    };

    static const uint16 ANY_UID = 0xffff;  // 监听所有 UID 的进程

    BW::string  preAddr_;    // 通知前缀(原始字节)
    BW::string  postAddr_;   // 通知后缀(原始字节)
};
```

`preAddr_` 和 `postAddr_` 看起来很奇怪——它们其实是一段**自定义字节流**,在通知发生时,bwmachined 会构造 `preAddr_ + addr(6字节) + postAddr_` 的字节流,通过 UDP 发到监听者注册时的 `port_` 端口。

这种设计让监听者可以**自定义通知的 Mercury 消息格式**——`preAddr_` 包含 Mercury 消息头(包括 messageID 等),`postAddr_` 是消息尾。监听者收到这个包后,Mercury 框架会自动 dispatch 到对应 handler。

### 8.11.2 Listeners 数据结构

`Listeners` 类(`listeners.hpp`)非常简单:

```cpp
class Listeners
{
private:
    class Member {
    public:
        Member( const ListenerMessage & lm, u_int32_t addr ) :
            lm_( lm ), addr_( addr ) {}
        ListenerMessage lm_;
        u_int32_t addr_;
    };

    BW::vector< Member > members_;
    const ServerPlatform & serverPlatform_;
};
```

每个 Member 是一对 `(ListenerMessage, sourceIP)`。bwmachined 维护两个 Listeners 实例:`birthListeners_` 和 `deathListeners_`,分别对应进程出生和死亡通知。

### 8.11.3 handleNotify 通知逻辑

当 bwmachined 检测到进程出生/死亡,会调用 `Listeners::handleNotify`(`listeners.cpp:21-56`):

```cpp
void Listeners::handleNotify( const Endpoint & endpoint,
    const ProcessMessage & pm, in_addr addr )
{
    char address[6];
    memcpy( address, &addr, sizeof( addr ) );             // 4 字节 IP
    memcpy( address + sizeof( addr ), &pm.port_, sizeof( pm.port_ ) );  // 2 字节端口

    Members::iterator iter = members_.begin();
    while (iter != members_.end())
    {
        ListenerMessage &lm = iter->lm_;

        // 过滤:category 匹配 + UID 匹配 + name 匹配
        if (lm.category_ == pm.category_ &&
            (lm.uid_ == lm.ANY_UID || lm.uid_ == pm.uid_) &&
            (lm.name_ == pm.name_ || lm.name_.size() == 0))
        {
            // 构造消息:preAddr + address(6字节) + postAddr
            int msglen = lm.preAddr_.size() + sizeof( address ) + lm.postAddr_.size();
            char *data = new char[ msglen ];
            memcpy( data, lm.preAddr_.c_str(), lm.preAddr_.size() );
            memcpy( data + preSize, address, sizeof( address ) );
            memcpy( data + preSize + sizeof( address ), lm.postAddr_.c_str(), postSize );

            // 发送到注册时的端口和 IP
            endpoint.sendto( data, msglen, lm.port_, iter->addr_ );
            delete [] data;
        }
        ++iter;
    }
}
```

注意三个过滤条件:

- **category** 必须相同(`SERVER_COMPONENT` 或 `WATCHER_NUB`)。
- **uid** 要么是 ANY_UID(监听所有用户),要么必须精确匹配。
- **name** 要么为空(监听所有名字),要么必须精确匹配。

这种灵活的过滤让一个监听者可以订阅"所有 baseapp 出生"或"特定 UID 的所有进程死亡"等各种事件。

### 8.11.4 跨机器通知

注意 `broadcastToListeners`(`bwmachined.cpp:1057-1067`):

```cpp
bool BWMachined::broadcastToListeners( ProcessMessage &pm, int type )
{
    uint8 oldparam = pm.param_;
    pm.param_ = type | pm.PARAM_IS_MSGTYPE;

    bool ok = pm.sendto( ep_, htons( PORT_MACHINED ), BROADCAST,
        MGMPacket::PACKET_STAGGER_REPLIES );

    pm.param_ = oldparam;
    return ok;
}
```

这是**广播**给所有 bwmachined 的——也就是说,本机一个进程出生,会通知**所有机器**上的 bwmachined。每台 bwmachined 收到 NOTIFY_BIRTH/NOTIFY_DEATH 后,会再调用本机的 `birthListeners_.handleNotify` 把通知分发给本机的监听者。

这种"两跳分发"设计的好处:监听者只需要在本机 bwmachined 注册一次,就能收到**全集群**的出生/死亡事件,不需要自己监听集群广播。

### 8.11.5 死监听器清理

`Listeners::checkListeners`(`listeners.cpp:62-73`)在每秒一次的 `update()` 中被调用,清理掉自己已经死掉的监听者:

```cpp
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

这避免了"监听者死了之后还往它发 UDP 包"导致的资源浪费。`isProcessRunning` 在 Linux 上是 `kill(pid, 0)` 或读 `/proc/<pid>`。

---

## 8.12 Cluster 集群视图

### 8.12.1 Cluster 类的职责

`Cluster`(`cluster.hpp`)是 bwmachined 维护"集群中所有机器 IP"的核心。它持有:

```cpp
class Cluster
{
protected:
    BWMachined &machined_;

    // 集群中所有已知机器的 IP
    Addresses machines_;       // typedef BW::set< uint32 > Addresses

    uint32 ownAddr_;           // 本机 IP
    uint32 buddyAddr_;         // 我的"buddy" IP(用于环状可靠性)

    FloodTriggerHandler floodTriggerHandler_;     // 周期触发 flood 检测
    FloodReplyHandler *pFloodReplyHandler_;       // 当前 flood 在途
    BirthReplyHandler birthHandler_;              // 启动期 birth 检测
};
```

`buddyAddr_` 是个有意思的概念——每台机器在集群中选一个"伙伴",互为备份。buddy 选择算法在 `chooseBuddy`(`cluster.cpp:29-55`):

```cpp
void Cluster::chooseBuddy()
{
    uint32 oldBuddy = buddyAddr_;
    buddyAddr_ = 0;

    uint32 lowest = 0xFFFFFFFF;
    for (Addresses::iterator it = machines_.begin(); it != machines_.end(); ++it)
    {
        // 选比自己 IP 大的最小者作为 buddy
        if (*it > ownAddr_ && (buddyAddr_ == 0 || *it < buddyAddr_))
            buddyAddr_ = *it;
        if (*it < lowest && *it != ownAddr_)
            lowest = *it;
    }

    // 如果没有比自己大的,选集群中最小的(形成环)
    if (buddyAddr_ == 0 && machines_.size() > 1)
        buddyAddr_ = lowest;

    MGMPacket::setBuddy( buddyAddr_ );
}
```

这是一个**环状拓扑**——按 IP 排序,每台机器的 buddy 是 IP 比自己大的下一个,最大的机器的 buddy 是最小的机器。这个环可以用于消息在集群中的"接力传递",或者用于机器死亡的二次确认。

### 8.12.2 BirthReplyHandler 启动期发现

`BirthReplyHandler`(`cluster.cpp:272-317`)在 bwmachined 启动时触发,流程:

```
1. 广播 ANNOUNCE_BIRTH 消息(count_=0)
2. 其他 bwmachined 收到后:
   - 把本机加入 machines_
   - 回复 ANNOUNCE_BIRTH(outgoing=true, count_=集群当前规模)
3. 本机收到回复:
   - markReceived(addr, count) 把发送者加入 machines_
   - toldSize_ = max(toldSize_, count) 取最大值
4. 当 machines_.size() == toldSize_ 时认为 bootstrap 完成:
   - 调用 chooseBuddy() 形成 ring
5. 如果 timeout 仍未达到 toldSize_,重新广播
```

关键代码:

```cpp
void Cluster::BirthReplyHandler::markReceived( uint32 addr, uint32 count )
{
    cluster_.machines_.insert( addr );
    toldSize_ = std::max( toldSize_, count );   // 相信最大的数

    if (cluster_.machines_.size() == toldSize_)
    {
        syslog( LOG_INFO, "Bootstrap complete; %" PRIzu " machines on network",
            cluster_.machines_.size() );
        cluster_.chooseBuddy();
    }
}
```

"相信最大值"是个聪明的策略——集群可能有机器同时启动,各自看到不同规模的子集,取最大值能尽快收敛到正确规模。

### 8.12.3 FloodTriggerHandler 周期检测

启动后,`FloodTriggerHandler`(`cluster.cpp:91-119`)周期触发 flood 检测,默认 `AVERAGE_INTERVAL = 2000ms`,但会按集群规模动态调整:

```cpp
TimeQueue::TimeStamp Cluster::FloodTriggerHandler::delay() const
{
    TimeQueue::TimeStamp min = AVERAGE_INTERVAL;
    TimeQueue::TimeStamp max = std::max( min+1,
        TimeQueue::TimeStamp(AVERAGE_INTERVAL * cluster_.machines_.size() * 2) );

    return min + rand() % (max-min);   // 随机化,避免同步
}
```

集群越大,flood 检测间隔越长(避免流量过大),而且加了随机抖动以避免多台机器同时 flood 形成同步风暴。

### 8.12.4 FloodReplyHandler 故障检测

`FloodReplyHandler`(`cluster.cpp:145-239`)负责实际的 flood 与故障判定:

```
1. sendBroadcast() 发 WholeMachineMessage 广播
2. 收到回复的机器加入 replied_ 集合
3. timeout 后:
   - replied_ 中不在 machines_ 的 → 新发现的机器(births)
   - machines_ 中不在 replied_ 的 → 怀疑死了(deaths)
4. 如果有 births:重新 flood 一次确认
5. 如果有 deaths 但还有重试次数:重新 flood
6. 否则:发 MachinedAnnounceMessage(ANNOUNCE_DEATH) 通知全集群
```

这里有**两次重试**(`MAX_RETRIES = 2`)机制——一次 flood 没收到回复不能立刻判定死亡,可能是丢包。重试两次都失败才确认死亡。这种保守策略避免了因网络抖动误杀健康的机器。

### 8.12.5 MachinedAnnounceMessage 三种类型

`MachinedAnnounceMessage`(`machine_guard.hpp:877-904`)有三种 type:

```cpp
enum Type
{
    ANNOUNCE_BIRTH = 0,    // 我刚启动
    ANNOUNCE_DEATH = 1,    // 某机器死了
    ANNOUNCE_EXISTS = 2    // 某机器存在(给新加入者同步全集群视图)
};
```

`ANNOUNCE_EXISTS` 的设计很巧妙:当一台新机器加入集群,所有现有机器会发 `ANNOUNCE_EXISTS` 给它,让它快速建立完整的集群视图。这避免了"逐台发现"的慢启动问题。

`handleMessage` 中的 `MACHINED_ANNOUNCE_MESSAGE` 分支(`bwmachined.cpp:1611-1686`)处理这三种类型,核心是更新本机的 `machines_` 集合并调用 `chooseBuddy()` 重建环。一个有意思的细节:

```cpp
// 如果听到别人说我死了,但我自己还活着
else if (mam.type_ == mam.ANNOUNCE_DEATH && deadaddr == cluster_.ownAddr_)
{
    cluster_.birthHandler_.addTimer();   // 重新启动 birth 流程
    syslog( LOG_INFO, "Reports of my death have been greatly exaggerated!" );
}
```

引用了马克·吐温的名言"我死亡的报道被严重夸大了"——如果 bwmachined 听到别人说自己死了但自己明明还活着,说明可能是网络分区导致误判,重新启动 birth 流程广播"我还活着"。

---

## 8.13 平台抽象层 ServerPlatform

### 8.13.1 抽象基类

`ServerPlatform`(`server_platform.hpp`)是平台无关的抽象基类:

```cpp
class ServerPlatform
{
public:
    bool isInitialised() const;

    // 推导某个 BW_CONFIG 下的二进制目录
    virtual bool findUserBinaryDirForConfig( const BW::string & bwRoot,
        const BW::string & bwConfig, BW::string & binaryDir ) = 0;

    // 检查 PID 是否存活
    virtual bool isProcessRunning( uint16 pid ) const = 0;

    // 更新系统统计(CPU/内存/网络)
    virtual bool updateSystemInfo( SystemInfo & systemInfo,
        ServerInfo * pServerInfo ) = 0;

    // 检查 core dump
    virtual bool checkCoreDumps( MachineGuardMessage::UserId uid,
        const BW::string & bwRoot, UserMessage::CoreDumps & coreDumps ) = 0;

    // 检查一组二进制是否都存在
    virtual bool checkBinariesExist( MachineGuardMessage::UserId uid,
        const BW::string & bwRoot, const ProcessSet & processes ) = 0;

protected:
    bool isInitialised_;
    VersionsProcesses versionsProcesses_;  // 版本 → 进程集合
};
```

这是经典的**策略模式**——`BWMachined` 持有 `ServerPlatform*` 指针(`pServerPlatform_`),运行时调用虚函数,具体行为由子类决定。

### 8.13.2 Linux 实现

`ServerPlatformLinux`(`server_platform_linux.hpp`)是 BigWorld 14.x 唯一提供的实现。它的构造函数:

```cpp
ServerPlatformLinux::ServerPlatformLinux() :
    ServerPlatform(),
    hasExtendedStats_( false )
{
    this->initConfigSuffixes();      // 预生成所有路径后缀
    this->initKernelVersion();       // 检测内核版本
    isInitialised_ = this->initArchitecture();  // 检测 32/64 位
}
```

#### 二进制路径推导

`findUserBinaryDirForConfig` 是个非常细致的实现,因为 BigWorld 历史上改过多次目录结构,要支持所有变种:

| 配置 | 路径后缀 |
|------|---------|
| Hybrid(新) | `/game/bin/server/<PlatformBuildStr>/server` |
| Hybrid(新) | `/game/bin/server/<PlatformStr>/server` |
| Hybrid(老) | `/game/bin/server/Hybrid64` 或 `/bigworld/bin/Hybrid64` |
| Hybrid(老) | `/game/bin/server/hybrid64` 或 `/bigworld/bin/hybrid64` |
| Debug(新) | `/game/bin/server/<PlatformBuildStr>_debug/server` |
| Debug(老) | `/game/bin/server/Debug64` 或 `/bigworld/bin/Debug64` |

`initConfigSuffixes` 在构造时把所有可能的路径后缀预算好,运行时只需逐个 `stat` 检查存在性,避免运行时字符串拼接。

#### 系统信息采集

`updateSystemInfo` 从 `/proc/` 读取:

- `/proc/stat` — CPU 时间片分配(user/nice/system/idle/iowait)
- `/proc/meminfo` — MemTotal/MemFree/Cached
- `/proc/net/dev` — 每个网卡的收发包字节
- `/proc/<pid>/stat` — 进程级 CPU/内存

这种"读 /proc"的方式是 Linux 特有的——其他 Unix(如 FreeBSD)有不同的 procfs 格式,Windows 则完全没有 procfs。这就是为什么需要平台抽象。

### 8.13.3 Windows 实现的缺失

注意 `CMakeLists.txt`:

```cmake
IF( BW_PLATFORM_LINUX )
    LIST( APPEND ALL_SRCS
        server_platform_linux.cpp
        server_platform_linux.hpp
    )
ENDIF()
```

只有 Linux 平台编译 `server_platform_linux.cpp`。BigWorld 14.x 开源版**没有提供 Windows 实现**,因为 bwmachined 设计目标就是 Linux 服务器集群。Windows 上的开发测试用的是其他工具(如 `bwmachined_tool` 模拟器)。

如果要在 Windows 上跑 bwmachined,需要自己实现 `ServerPlatformWin` 子类,这会比较复杂:

- fork/exec → CreateProcess(语义不同,没有"父子共享 fd"的概念)
- /proc → 性能计数器 API(`GetProcessTimes`、`GlobalMemoryStatusEx`)
- signal → TerminateProcess(没有 SIGUSR1 等细分信号)
- /etc/passwd → NetUserGetInfo 或 SAM API

这种"Unix 哲学"在 BigWorld 中体现得很明显——bwmachined 把 Unix 系统调用当作一等公民,平台抽象只是"理论上的可能"。

---

## 8.14 用户与权限 UserMap

### 8.14.1 多租户支持

BigWorld 服务器集群的一个重要特性是**多租户**——一台机器上可以同时跑多个用户的进程(比如用户 `alice` 的 cellapp 和用户 `bob` 的 cellapp 共存)。这要求:

- 每个进程以正确的 UID/GID 启动(权限隔离)
- 每个用户有自己的 `BW_ROOT` 和 `BW_RES_PATH`
- bwmachined 能根据 UID 查询用户的环境配置

`UserMap`(`usermap.hpp`)就是这套机制的核心:

```cpp
class UserMap
{
public:
    void add( const UserMessage &um );
    UserMessage* add( struct passwd *ent );
    bool getEnv( UserMessage & um, bool userAlreadyKnown = false );
    UserMessage* fetch( uint16 uid );
    bool setEnv( const UserMessage &um );
    void flush();

protected:
    typedef BW::map< uint16, UserMessage > Map;
    Map map_;
    UserMessage notfound_;   // 查不到时的标准回复
};
```

### 8.14.2 配置文件查找顺序

`getEnv`(`usermap.cpp:106-190`)按以下顺序查找用户的环境配置:

1. **`~/.bwmachined.conf`**:用户家目录下的私有配置,格式 `<mfroot>;<bwrespath>`(分号分隔)。
2. **`/etc/bigworld.conf`**:全局配置,格式 `<uid>;<mfroot>;<bwrespath>`,按 UID 索引。

`UserMessage::getConfFilename()` 返回 `~/.bwmachined.conf`。这个文件由用户自己维护,bwmachined 启动时 `queryUserConfs()` 遍历所有真实用户,尝试读取他们的 `~/.bwmachined.conf`,把成功的加入 `map_`。

### 8.14.3 UID/GID 切换

`startProcess` 中 fork 之后,子进程首先做的两件事就是 `setgid` 和 `setuid`:

```cpp
if (setgid( gid ) == -1)
{
    syslog( LOG_ERR, "Failed to setgid() to %d for user %d", gid, uid );
}

if (setuid( uid ) == -1)
{
    syslog( LOG_ERR, "Failed to setuid to %d, aborting exec for %s",
        uid, binaryName );
    write( statusPipe[ 1 ], &errno, sizeof( errno ) );
    exit( EXIT_FAILURE );
}
```

注意**顺序很重要**——必须先 `setgid` 再 `setuid`!因为 `setuid` 之后(从 root 切到普通用户),就**没有权限**再 `setgid` 了。这是 Unix 权限的基本规则。

如果 `setuid` 失败,子进程会立即退出并通过管道回报 errno——绝对不能"以 root 跑下去",这是安全底线。

### 8.14.4 coredump 检查

`UserMessage::PARAM_CHECK_COREDUMPS` 标志会让 bwmachined 扫描用户 `BW_ROOT` 下的 core 文件和 assertion 日志,通过 `ServerPlatform::checkCoreDumps` 返回。这个特性让运维工具(如 `bwmachined_tool`)能查询"这台机器上用户 1001 最近有过几次 crash",便于故障排查。

`PARAM_GET_VERSION` 则让 bwmachined 推导用户的 BigWorld 版本(`server_platform.cpp:71-89` 的 `determineVersion`)——通过检查 BW_ROOT 下哪些二进制存在,反推这是哪个 BigWorld 版本。

---

## 8.15 状态持久化与重启恢复

### 8.15.1 save() 写状态

bwmachined 收到 `SIGTERM` 时会调用 `save()`(`bwmachined.cpp:341-379`),把进程表写到 `/var/run/bwmachined.state`:

```cpp
const char* BWMachined::STATE_FILE = "/var/run/bwmachined.state";

void BWMachined::save()
{
    FileStream out( STATE_FILE, "w" );

    for (unsigned i=0; i < procs_.size(); i++)
    {
        MemoryOStream processBuffer;
        ProcessInfo &pi = procs_[ i ];
        processBuffer << pi.cpu << pi.mem << pi.affinity << pi.starttime;
        pi.m.write( processBuffer );

        out.appendString( (const char *)processBuffer.data(),
                          processBuffer.size() );
    }
}
```

### 8.15.2 load() 读状态

`load()`(`bwmachined.cpp:385-460`)在构造时读取:

```cpp
void BWMachined::load()
{
    FileStream in( STATE_FILE, "r" );

    // 如果文件超过 10 分钟,认为过期
    if (in.stat( &statinfo ) == 0)
    {
        time_t age = time( NULL ) - statinfo.st_mtime;
        if (age > 10 * 60)
        {
            syslog( LOG_INFO, "Ignoring out-of-date %s (%d seconds old)",
                STATE_FILE, (int)age );
            unlink( STATE_FILE );
            return;
        }
    }

    while (in.tell() < len)
    {
        // 读出每条 ProcessInfo 记录
        ProcessInfo pi;
        processBuffer >> pi.cpu >> pi.mem >> pi.affinity >> pi.starttime;
        pi.m.read( processBuffer );

        // 校验进程是否还活着 + starttime 是否匹配
        if (!validateProcessInfo( pi ))
        {
            syslog( LOG_ERR, "Failed to restore %s (pid:%d uid:%d).",
                pi.m.name_.c_str(), pi.m.pid_, pi.m.uid_ );
        }
        else
        {
            procs_.push_back( pi );
            syslog( LOG_INFO, "Restored %s (pid:%d uid:%d)",
                pi.m.name_.c_str(), pi.m.pid_, pi.m.uid_ );
        }
    }

    // 读完立刻删除文件
    unlink( STATE_FILE );
}
```

关键设计:

1. **10 分钟有效期**:state 文件如果太老(可能 bwmachined 重启花了很久),就忽略它——因为里面记录的进程 PID 可能已经被复用了,恢复会出错。
2. **`validateProcessInfo`**(`linux_machine_guard.cpp:476-510`)读 `/proc/<pid>/stat` 验证 starttime——只有 starttime 完全匹配才认为"还是原来那个进程"。这是 PID 复用的关键防护。
3. **读完立即删除**:state 文件是一次性的,加载完就删,避免下次启动又读到陈旧数据。

这种"机器重启但进程还在"的场景适用于:bwmachined 自身崩溃了(但子进程继续运行),运维 `service bwmachined2 restart`,新 bwmachined 启动后能"认领"原来的子进程。

---

## 8.16 与 Reviver 的协作

### 8.16.1 分工:看门狗 vs 业务

bwmachined 和 Reviver 是 BigWorld 故障恢复体系的两条腿,分工明确:

| 维度 | bwmachined | Reviver |
|------|-----------|---------|
| 部署粒度 | 每台机器 1 个 | 整个集群 1 个或多个(主备) |
| 职责 | 进程生命周期管理 | 业务级故障检测与重启 |
| 检测机制 | /proc 检测 + 死亡通知 | birth/death listener + ping 双重确认 |
| 重启触发 | 不主动重启(除非收到 CreateMessage) | 检测到故障后发 CreateMessage 委托 bwmachined 重启 |
| 知识范围 | 本机所有进程 | 集群内被监控的几类关键进程 |

简单说:**bwmachined 管进程,Reviver 管业务**。

### 8.16.2 Reviver 委托重启

Reviver 检测到某进程故障后,会构造 `CreateMessage` 发给本机 bwmachined:

```python
# 伪代码
cm = CreateMessage()
cm.name_ = "cellapp"
cm.uid_ = 1001
cm.config_ = "Hybrid"
cm.recover_ = 1   # 关键:带 -recover 参数
bwmachined.sendAndRecv(cm)
```

bwmachined 收到后走标准的 `handleCreateMessage` 流程,fork/exec 一个新 cellapp,并自动加上 `-recover` 命令行参数(在 `bwmachined.cpp:1829-1832`):

```cpp
if (cm.recover_)
{
    argv[ argc++ ] = "-recover";
}
```

`-recover` 参数让子进程启动后进入恢复模式——从 DBAppMgr/DBApp 加载持久化状态,而不是从零开始。这是 Reviver 实现"无状态损失重启"的关键。

### 8.16.3 birth/death listener 注册

Reviver 启动时向 bwmachined 注册 birth/death listener(`reviver.cpp` 的 `Reviver::init` 步骤 5):

```cpp
if (ReviverInterface::registerWithMachined( interface_, 0 ) !=
        Mercury::REASON_SUCCESS)
{
    NETWORK_WARNING_MSG( "Reviver::init: Unable to register interface\n" );
    return false;
}
```

这个调用会通过 MachineGuard 协议发 `LISTENER_MESSAGE / ADD_BIRTH_LISTENER` 和 `ADD_DEATH_LISTENER` 给本机 bwmachined。之后,本机任何进程出生/死亡,Reviver 都会收到通知——但 Reviver 不只是被动等待,它还会主动 ping 被监控进程做"双重确认",避免 bwmachined 的死亡通知延迟或丢失。

### 8.16.4 Components tag

Reviver 还会查询 bwmachined 的 `Components` tag,决定本机要监控哪些类型的进程。这个 tag 通常在 `/etc/bwmachined.conf` 中配置:

```ini
[Components]
baseapp
cellapp
loginapp
```

这意味着本机 Reviver 只监控这三类。如果某个 Component 没列,即使本机有这种进程在跑,Reviver 也不会管——这让运维可以"在某台机器上禁用 Reviver 对某类进程的监控",便于维护。

---

## 8.17 特色实现深度剖析

### 8.17.1 bwmachined 的"看门狗"角色

bwmachined 不仅是简单的"fork 机器",它还承担了几个看门狗职责:

1. **进程存活检测**:`update()` 每秒检查所有 `procs_` 中的进程是否还在。
2. **PID 复用防护**:`starttime` 校验,防止把"复用了旧 PID 的新进程"误认为旧进程。
3. **死亡广播**:进程死了不仅自己清理,还会广播 `NOTIFY_DEATH` 给全集群,让所有监听者知道。
4. **僵尸回收**:`waitpid(-1, NULL, WNOHANG)` 在 update 中再调一次,即使 SIGCHLD 丢了也能回收僵尸子进程。

这种"多管齐下"的检测策略,确保了进程死亡的可靠检测——即使某一条机制失效(如 SIGCHLD 丢失),其他机制仍能兜底。

### 8.17.2 与 systemd/init.d 的对比

bwmachined 与传统 init 系统的对比:

| 特性 | bwmachined | systemd | sysvinit |
|------|-----------|---------|----------|
| 部署粒度 | 每台机器 1 个 | 每台机器 1 个 | 每台机器 1 个 |
| 集群感知 | ✓(集群视图同步) | ✗ | ✗ |
| 跨机器进程查询 | ✓(PROCESS_STATS_MESSAGE 广播) | ✗ | ✗ |
| UID 切换 | ✓(原生支持多租户) | 通过 User= 指令 | 通过 su/sudo |
| 业务感知 | ✗(纯进程级) | ✗ | ✗ |
| 重启策略 | 不主动重启(由 Reviver 决定) | Restart=on-failure 等自动策略 | 不主动重启 |
| 配置格式 | 自定义 INI-like | INI-like unit file | shell 脚本 |
| 状态查询 | UDP 协议(可远程) | dbus(本地为主) | ps/kill |

bwmachined 的"集群感知"是它最大的差异化——它把单机的进程管理扩展到了集群层面,通过广播协议让所有机器共享一份"集群成员"视图。这是 MMOG 集群独有的需求,通用 init 系统不需要。

bwmachined **不主动重启**进程的设计也很有意思——主动重启是 Reviver 的职责。这种分工让"什么算故障"这个判断由业务侧(Reviver)决定,而不是被 init 系统的"是否还活着"硬编码。

### 8.17.3 进程标签系统的灵活性

Tags 系统看似简单,实际非常灵活:

1. **配置即数据**:运维改 `/etc/bwmachined.conf` 后,工具可以发 `RESET_MESSAGE` 让 bwmachined 重新加载,无需重启。
2. **任意自定义**:管理员可以加任何自定义段,如 `[Roles]`、`[Zones]`,工具按需查询。
3. **Components 解耦部署与监控**:Reviver 通过 Components tag 决定监控范围,而不是写死在配置里——这让"同一份 Reviver 二进制"能在不同角色的机器上跑不同的监控策略。
4. **行内 KV 与列表共存**:`bwmachined` 段下的 `timing_method=gettime` 是 KV,而 `Components` 段下的进程名是列表。同一个 parser 通过 `findOption` vs `tags_[name]` 区分,既灵活又简单。

### 8.17.4 跨机器集群视图的一致性

bwmachined 集群视图的一致性通过几个机制保证:

1. **BirthReplyHandler 取最大值**:启动期多个机器报告不同的集群规模,取最大值——这避免了"小规模子集"误判。
2. **FloodReplyHandler 两次重试**:故障判定前要 flood 两次,避免单次丢包误杀。
3. **ANNOUNCE_EXISTS 全集群同步**:新机器加入时,所有现有机器发 EXISTS 给它,让它一次性获得完整视图。
4. **死亡宣告广播**:任何机器发现某机器死亡,广播给全集群,所有机器同步删除。
5. **自我死亡应对**:听到自己死亡的报告时,不坐以待毙,重新启动 birth 流程宣告"我还活着"。

这种"多次确认 + 主动澄清"的策略,在不可靠的 UDP 网络上保证了最终一致性。它不追求强一致(那需要 Paxos 等复杂算法),但通过"多次重试 + 取最大值"达到了"足够好"的一致性——这是工程上的合理折衷。

### 8.17.5 故障检测与 Reviver 的分工

最后再强调一下"bwmachined 管进程,Reviver 管业务"的分工:

- **bwmachined 检测**:进程是否还活着(/proc 检测)
- **Reviver 检测**:进程是否还能响应业务请求(ping)
- **bwmachined 反应**:更新进程表,广播 death 通知
- **Reviver 反应**:发 CreateMessage 委托 bwmachined 重启

为什么要两层?因为:

1. **进程可能"假死"**:/proc 还在但业务卡死(如死锁、网络挂起)。bwmachined 检测不到,Reviver 的 ping 能检测到。
2. **进程可能"真死但没通知"**:SIGCHLD 丢失、网络分区导致 death 通知未到达。Reviver 的 ping 双重确认能补救。
3. **业务级判断**:有些"故障"是业务定义的,如"LoginApp 不再接受新登录"——这需要 Reviver 自己 ping 测试。

这种"双层检测"是 BigWorld 高可用性的关键设计,值得在任何分布式系统中借鉴。

---

## 8.18 本章小结

本章详细剖析了 BigWorld 的"机器管家" `bwmachined` 的设计与实现。回顾要点:

1. **每台机器一个 bwmachined**:作为 daemon 运行,管理本机所有 BigWorld 进程的生命周期。
2. **MachineGuard 协议**:15 种 tool/server 消息 + 1 种 machined 之间消息,基于 UDP,可打包多个消息为一个 packet,支持 `PACKET_STAGGER_REPLIES` 抑制广播风暴。
3. **三端点设计**:`ep_`(主)、`epLocal_`(回环)、`epBroadcast_`(广播),分别处理不同来源的消息。
4. **fork/exec + FD_CLOEXEC 管道技巧**:子进程 exec 成功时管道自动关闭,父进程通过 read 长度判断 exec 结果,既异步又可靠。
5. **进程生命周期**:创建(CreateMessage) → 注册(PROCESS_MESSAGE/REGISTER) → 监控(update + /proc) → 死亡(NOTIFY_DEATH 广播)。
6. **Tags 系统**:INI-like 配置,支持任意自定义分类,Components tag 决定 Reviver 监控范围。
7. **Cluster 集群视图**:BirthReplyHandler 启动期发现,FloodTriggerHandler 周期检测,环状 buddy 拓扑,两次重试 + 取最大值保证最终一致性。
8. **Listeners 双层通知**:本机进程出生/死亡 → 广播给所有 bwmachined → 各 bwmachined 分发给本机监听者。
9. **平台抽象 ServerPlatform**:策略模式隔离平台差异,Linux 实现基于 /proc,Windows 实现缺失(开源版)。
10. **多租户 UserMap**:UID → 用户环境映射,~/.bwmachined.conf + /etc/bigworld.conf 双层查找,setuid/setgid 严格顺序。
11. **状态持久化**:`/var/run/bwmachined.state` 保存进程表,10 分钟有效期,starttime 校验防 PID 复用。
12. **与 Reviver 分工**:bwmachined 管进程(/proc 检测),Reviver 管业务(ping 双重确认),Reviver 通过 CreateMessage 委托 bwmachined 重启。

理解了 bwmachined,你就理解了 BigWorld 集群的"控制平面"——它本身不做任何游戏逻辑,但没有它,整个集群就无法启动、无法监控、无法恢复。下一章我们将进入"数据平面",看 CellApp 如何管理空间与实体。

---

> **延伸阅读**:
> - `docs/BigWorld恢复进程Reviver实现分析.md` — Reviver 的完整实现,重点看与 bwmachined 的交互
> - `docs/BigWorld启动流程分析.md` — 整个集群的启动序列,bwmachined 是第一个启动的进程
> - `lib/network/machine_guard.hpp` — MachineGuard 协议的完整定义
> - `lib/network/machined_utils.hpp` — 给 bwmachined 发消息的客户端工具
