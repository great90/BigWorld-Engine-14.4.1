# 专题7:Mercury 网络协议深度剖析

> BigWorld Engine 14.4.1 的网络核心——Mercury 可靠 UDP 协议。
> 本专题将从设计哲学、Endpoint 抽象、Packet 格式、Channel 可靠传输、Bundle 消息序列化、滑动窗口、ACK/重传算法、流量控制、InterfaceElement、Request 请求-响应、NetworkInterface 事件循环、FragmentedBundle 重组、ChannelOwner 生命周期、MachineGuard 协议、跨平台 IO 模型、性能分析与横向对比等所有维度,对 Mercury 协议进行百科级深度剖析。

---

## 目录

- [一、引言与导读](#一引言与导读)
- [二、Mercury 概述与设计哲学](#二mercury-概述与设计哲学)
- [三、Endpoint 网络端点深度剖析](#三endpoint-网络端点深度剖析)
- [四、Packet 数据包格式深度剖析](#四packet-数据包格式深度剖析)
- [五、Channel 逻辑通道架构](#五channel-逻辑通道架构)
- [六、UDPChannel 可靠传输实现](#六udpchannel-可靠传输实现)
- [七、Bundle 消息序列化机制(特色实现)](#七bundle-消息序列化机制特色实现)
- [八、可靠 UDP 算法详解](#八可靠-udp-算法详解)
- [九、流量控制与背压](#九流量控制与背压)
- [十、消息类型与 InterfaceElement](#十消息类型与-interfaceelement)
- [十一、Request 请求-响应模式](#十一request-请求-响应模式)
- [十二、NetworkInterface 顶层接口](#十二networkinterface-顶层接口)
- [十三、FragmentedBundle 分片重组](#十三fragmentedbundle-分片重组)
- [十四、ChannelOwner 通道所有者](#十四channelowner-通道所有者)
- [十五、特殊机制:PortMap/NetMask/Misc](#十五特殊机制portmapnetmaskmisc)
- [十六、MachineGuard 协议](#十六machineguard-协议)
- [十七、跨平台支持与 IO 模型](#十七跨平台支持与-io-模型)
- [十八、性能分析](#十八性能分析)
- [十九、边界情况与故障处理](#十九边界情况与故障处理)
- [二十、与其他引擎对比](#二十与其他引擎对比)
- [二十一、总结与最佳实践](#二十一总结与最佳实践)
- [附录 A:关键文件索引](#附录-a关键文件索引)
- [附录 B:Packet 标志位一览](#附录-bpacket-标志位一览)
- [附录 C:Reason 错误码一览](#附录-creason-错误码一览)
- [附录 D:术语表](#附录-d术语表)

---

## 一、引言与导读

### 1.1 为什么需要 Mercury

在 MMOG(Massively Multiplayer Online Game)服务器架构中,进程间通信(IPC)是支撑整个分布式世界的基础设施。BigWorld 集群通常包含数十甚至上百个进程:CellApp(空间计算)、BaseApp(玩家代理)、DBApp(持久化)、LoginApp(登录)、BaseAppMgr/CellAppMgr/DBAppMgr(协调)、bwmachined(守护)等。这些进程之间需要频繁地交换:

- **实时小消息**:实体位置更新、AOI 通知、ghost 同步、AOI 进出
- **请求-响应**:CellAppMgr 查询 CellApp 状态、DBApp 读写请求
- **大块数据**:Chunk 数据加载、实体迁移序列化、空间数据广播
- **控制信令**:bwmachined 的进程创建、信号、标签查询

如果使用裸 TCP,会面临以下问题:

1. **队头阻塞(Head-of-Line Blocking)**:TCP 严格要求严格有序,任何一个字节丢失会阻塞整个流。在游戏场景中,有的消息(如 RPC 调用)需要可靠有序,有的消息(如位置更新)丢失一次无所谓,把两者复用到同一个 TCP 连接上会导致位置更新被 RPC 阻塞。
2. **延迟敏感**:游戏对 RTT 极其敏感,一次 RPC 超时往往是 30 秒级别,但 TCP 的重传超时默认是 200ms 起步,在拥塞时会指数退避,完全无法接受。
3. **连接管理开销**:每个对端一条 TCP 连接,BigWorld 集群中一个 CellApp 可能要与几十个 BaseApp、其他 CellApp 通信,连接数膨胀。
4. **无法广播**:BigWorld 的 bwmachined 发现协议严重依赖广播。

Mercury 的出现正是为了在 UDP 之上构建一套灵活的、可定制的可靠传输协议,既能像 TCP 一样保证可靠有序,又能像 UDP 一样支持不可靠消息、广播、多路复用、请求-响应等模式。

### 1.2 Mercury 一句话定义

> **Mercury 是 BigWorld 在 UDP 之上构建的、面向游戏服务器的、可定制可靠等级的多路复用消息传输协议。一个 UDP socket 上可以承载多个 Channel,每个 Channel 内的可靠消息有滑动窗口、ACK、重传,但不可靠消息可以独立丢弃。**

### 1.3 本专题的阅读顺序

本专题共 21 章,建议按以下顺序阅读:

1. **第 2-3 章**:建立整体认识,理解 Mercury 设计哲学与 Endpoint 抽象。
2. **第 4-5 章**:深入 Packet 数据结构与 Channel 抽象。
3. **第 6-8 章**:UDPChannel 可靠传输、Bundle 序列化、可靠 UDP 算法核心。
4. **第 9-11 章**:流量控制、InterfaceElement、Request 请求-响应。
5. **第 12-14 章**:NetworkInterface、FragmentedBundle、ChannelOwner。
6. **第 15-17 章**:特殊机制、MachineGuard、跨平台 IO。
7. **第 18-21 章**:性能、边界、对比、总结。

### 1.4 涉及的核心源文件

| 路径 | 说明 |
|------|------|
| `programming/bigworld/lib/network/endpoint.hpp` / `endpoint.cpp` / `endpoint.ipp` | Socket 抽象层 |
| `programming/bigworld/lib/network/packet.hpp` / `packet.cpp` | 数据包格式 |
| `programming/bigworld/lib/network/channel.hpp` / `channel.cpp` / `channel.ipp` | Channel 抽象基类 |
| `programming/bigworld/lib/network/udp_channel.hpp` / `udp_channel.cpp` / `udp_channel.ipp` | UDP Channel 可靠传输 |
| `programming/bigworld/lib/network/tcp_channel.hpp` / `tcp_channel.cpp` | TCP Channel(对比实现) |
| `programming/bigworld/lib/network/bundle.hpp` / `bundle.cpp` / `bundle.ipp` | Bundle 抽象基类 |
| `programming/bigworld/lib/network/udp_bundle.hpp` / `udp_bundle.cpp` / `udp_bundle.ipp` | UDP Bundle 序列化 |
| `programming/bigworld/lib/network/msgtypes.hpp` / `msgtypes.ipp` | 消息类型与紧凑打包 |
| `programming/bigworld/lib/network/interface_element.hpp` / `interface_element.cpp` | 接口元素(消息元数据) |
| `programming/bigworld/lib/network/interface_macros.hpp` | 接口定义宏 |
| `programming/bigworld/lib/network/interface_minder.hpp` / `interface_minder.cpp` | 接口管理器 |
| `programming/bigworld/lib/network/interface_table.hpp` / `interface_table.cpp` | 接口表 |
| `programming/bigworld/lib/network/network_interface.hpp` / `network_interface.cpp` / `network_interface.ipp` | 顶层网络接口 |
| `programming/bigworld/lib/network/event_dispatcher.hpp` / `event_dispatcher.cpp` / `event_dispatcher.ipp` | 事件分发器 |
| `programming/bigworld/lib/network/event_poller.hpp` / `event_poller.cpp` | IO 多路复用 |
| `programming/bigworld/lib/network/request.hpp` / `request.cpp` | 请求-响应 |
| `programming/bigworld/lib/network/fragmented_bundle.hpp` / `fragmented_bundle.cpp` | 分片 Bundle 重组 |
| `programming/bigworld/lib/network/channel_owner.hpp` / `channel_owner.cpp` | Channel 所有者 |
| `programming/bigworld/lib/network/machine_guard.hpp` / `machine_guard.cpp` | bwmachined 协议 |
| `programming/bigworld/lib/network/misc.hpp` | SeqNum/Reason 等基础类型 |
| `programming/bigworld/lib/network/basictypes.hpp` / `basictypes.ipp` | Address 等基础类型 |
| `programming/bigworld/lib/network/portmap.hpp` | 端口约定 |
| `programming/bigworld/lib/network/netmask.hpp` / `netmask.cpp` | 网络掩码 |
| `programming/bigworld/lib/network/circular_array.hpp` | 滑动窗口环形数组 |
| `programming/bigworld/lib/network/unacked_packet.hpp` / `unacked_packet.cpp` | 未确认包 |
| `programming/bigworld/lib/network/reliable_order.hpp` | 可靠消息分段记录 |
| `programming/bigworld/lib/network/packet_receiver.hpp` / `packet_receiver.cpp` | 接收器 |
| `programming/bigworld/lib/network/packet_sender.hpp` / `packet_sender.cpp` | 发送器 |
| `programming/bigworld/lib/network/packet_filter.hpp` / `packet_filter.ipp` | 包过滤器 |

---

## 二、Mercury 概述与设计哲学

### 2.1 Mercury 命名由来

Mercury(墨丘利)是罗马神话中的信使之神(Greek 对应 Hermes),负责在神祇与凡人之间传递信息,其形象通常头戴羽翼帽、脚踏飞鞋,象征着**快速、可靠、无处不在的通信**。BigWorld 把它的网络层命名为 Mercury,正是寓意这套系统承担着游戏世界中所有进程间消息的"信使"角色:

- **快速**:基于 UDP,无 TCP 三次握手开销,无队头阻塞。
- **可靠**:在 UDP 之上自建 ACK 与重传,关键消息不丢。
- **无处不在**:从 CellApp 内部到客户端的 BaseApp 代理,从 bwmachined 守护到 Web 监控接口,所有通信都走 Mercury。

整个网络库的命名空间就叫做 `Mercury`,所有相关类如 `Mercury::Address`、`Mercury::Channel`、`Mercury::Bundle`、`Mercury::EventDispatcher`、`Mercury::Reason` 等都位于这个命名空间下。

### 2.2 为什么不用 TCP

TCP 在通用网络场景中表现出色,但在 MMOG 服务器内部通信中存在根本性的不匹配:

#### 2.2.1 队头阻塞(Head-of-Line Blocking)

TCP 保证字节流的严格有序,任何一个数据段丢失,后续到达的数据段都必须缓冲在接收端内核队列里,等待丢失段重传到位后才能交付给应用。在游戏场景下,这意味着:

- 一个 RPC 调用丢包,后面紧跟的实时位置更新全部被阻塞
- 一个 Chunk 加载请求丢包,后面所有玩家事件被阻塞
- 队头阻塞会让延迟从 1ms 跳到 200ms+,玩家感知明显"卡顿"

Mercury 的做法是:同一个 Channel 上既有可靠消息也有不可靠消息,不可靠消息丢失不会触发重传,后续可靠消息可以继续推进;甚至可以通过 Piggyback 机制把丢失的可靠消息"搭车"在后续的 outgoing bundle 里,完全规避队头阻塞。

#### 2.2.2 拥塞控制对游戏不友好

TCP 的拥塞控制算法(CUBIC、Reno、NewReno)是为公平共享互联网带宽设计的:丢包即视为拥塞,立即 cwnd 减半。但在 BigWorld 集群内部:

- 局域网丢包率极低(< 0.01%),大多是 buffer 溢出
- 服务器之间往往通过专用网络或 VPN
- 一次 cwnd 减半会让吞吐量从 1Gbps 跌到 100Mbps,严重影响同步效率

Mercury 默认在内部通道(INTERNAL)上不实现传统 TCP 拥塞控制,而是采用基于 RTT 的简单重传策略:`resendPeriod = max(roundTripTime_ * 2, minInactivityResendDelay_)`(见 `udp_channel.cpp:1080-1081`),避免被拥塞算法过度抑制。

#### 2.2.3 连接管理开销

TCP 是面向连接的,每个 (src, dst) 对都需要一个独立 socket,握手 3 个包、挥手 4 个包。BigWorld 集群中:

- 一个 CellApp 同时与 N 个 BaseApp 通信
- 一个 BaseApp 同时与 M 个 CellApp 通信
- 还要和 CellAppMgr、BaseAppMgr、DBMgr、Logger 通信

如果用 TCP,socket 数量爆炸。Mercury 设计成 **单 socket 多路复用**:一个进程只需要一个 UDP socket,所有 Channel 共用,通过 Mercury::Address 区分对端。

#### 2.2.4 缺乏广播

bwmachined 的服务发现依赖广播(`BROADCAST = 0xFFFFFFFF`,见 `basictypes.hpp:55`),TCP 完全不支持广播。Mercury 的 Endpoint 直接支持 `setbroadcast(true)`(见 `endpoint.ipp:153-159`)。

### 2.3 可靠 UDP 的设计目标

Mercury 在设计可靠 UDP 时,确立了以下核心目标:

1. **可靠等级可定制**:每个消息可以单独指定 `RELIABLE_NO`、`RELIABLE_DRIVER`、`RELIABLE_PASSENGER`、`RELIABLE_CRITICAL` 四种等级(见 `bundle.hpp:34-40`)。
2. **多路复用**:一个 UDP socket 上承载多个逻辑 Channel,通过 `Mercury::Address` 区分。
3. **请求-响应**:内置 Request/Reply 模式,无需应用层实现超时与回调。
4. **分片重组**:大 Bundle 自动分片到多个 Packet,接收端自动重组。
5. **流式写入**:Bundle 派生自 `BinaryOStream`,可用 `<<` 操作符流式写入,语法直观。
6. **接口驱动**:通过 `InterfaceElement` 描述消息元数据(长度风格、长度参数),自动处理长度编解码。
7. **可观测**:内置 Watcher 体系,所有统计可监控。
8. **跨平台**:支持 Linux/Windows/macOS/PS3/Xbox360/Android/Emscripten,IO 模型自动适配 select/poll/epoll。

### 2.4 与 QUIC/ENet/RakNet 的对比

| 特性 | Mercury | QUIC | ENet | RakNet |
|------|---------|------|------|--------|
| 传输层 | UDP | UDP | UDP | UDP |
| 可靠等级 | 4 种(NO/DRIVER/PASSENGER/CRITICAL) | 单一可靠流 | RELIABLE/UNRELIABLE/UNSEQUENCED | 多种 |
| 多路复用 | Channel(每对地址一个) | Stream(多流) | Peer | Connection |
| 请求-响应 | 内置 Request/Reply | 无 | 无 | 无 |
| 拥塞控制 | 简单 RTT-based | Cubic/BBR 等 | 可选 | 自定义 |
| 加密 | 可插拔 EncryptionFilter | TLS 1.3 内置 | 无 | 无 |
| 序列号位宽 | 28 位 | 32 位 | 16 位 | 32 位 |
| 接口元数据 | InterfaceElement + FourCC | 无 | 无 | 无 |
| 应用场景 | 游戏服务器集群 | Web/HTTP3 | 通用游戏 | 通用游戏 |
| 设计年代 | 2002-2014 | 2012-至今 | 2002-至今 | 2003-至今 |

详细对比见 [第二十章](#二十与其他引擎对比)。

---

## 三、Endpoint 网络端点深度剖析

### 3.1 Endpoint 的角色

`Endpoint`(`endpoint.hpp:85`)是 Mercury 对 socket 的封装抽象。它是一个**值类型**类(没有继承层次),直接包装底层 socket 描述符,屏蔽平台差异。所有 Mercury 的发送和接收最终都会落到一个 `Endpoint` 上。

```cpp
// endpoint.hpp:85-204
class Endpoint
{
public:
    Endpoint();
    ~Endpoint();

    static const socket_t NO_SOCKET = static_cast<socket_t>(-1);

    int fileno() const;
    void setFileDescriptor(socket_t fd);
    bool good() const;

    void socket( int type );
    int setnonblocking( bool nonblocking );
    int setbroadcast( bool broadcast );
    int setreuseaddr( bool reuseaddr );
    int bind( u_int16_t networkPort = 0, u_int32_t networkAddr = INADDR_ANY );
    INLINE int close();
    INLINE int detach();
    // ... sendto / recvfrom / connect / accept ...
private:
    socket_t socket_;
};
```

### 3.2 平台差异处理

`Endpoint` 通过宏和 typedef 屏蔽平台差异。在头文件顶部可以看到不同平台的条件编译:

```cpp
// endpoint.hpp:10-76
#if defined( __unix__ ) || defined( PLAYSTATION3 ) || defined( __APPLE__ ) || \
        defined( __ANDROID__ ) || defined( EMSCRIPTEN )
    #include <sys/time.h>
    #include <sys/socket.h>
    #include <netinet/in.h>
    #include <arpa/inet.h>
    #include <netdb.h>
    #include <unistd.h>
#elif defined(_XBOX)
    #include <xtl.h>
    #include <winsockx.h>
#else
    #include <Winsock2.h>
#endif
```

不同平台的 socket 描述符类型也不同:

```cpp
// endpoint.hpp:51-76
#ifdef PLAYSTATION3
    typedef int socket_t;
#else // Windows
    typedef int socklen_t;
    typedef u_short u_int16_t;
    typedef u_long u_int32_t;
    typedef SOCKET socket_t;
#endif
// Linux/macOS/Android
    typedef int socket_t;
```

这种设计让上层代码可以无差别使用 `socket_t`、`socklen_t`、`u_int16_t` 等类型,无需关心底层是 `int` 还是 `SOCKET`。

### 3.3 socket 创建

`Endpoint` 默认构造时不创建 socket,socket_ 被设为 `NO_SOCKET`(-1):

```cpp
// endpoint.ipp:25-28
INLINE Endpoint::Endpoint() : socket_( NO_SOCKET )
{
    BW_GUARD;
}
```

调用 `socket(int type)` 才真正创建:

```cpp
// endpoint.ipp:76-90
INLINE void Endpoint::socket(int type)
{
    BW_GUARD;
    this->setFileDescriptor( int(::socket( AF_INET, type, 0 )) );
#if defined( _WIN32 )
    if ((socket_ == INVALID_SOCKET) && (WSAGetLastError() == WSANOTINITIALISED))
    {
        initNetwork();  // 懒初始化 Winsock
        this->setFileDescriptor( int(::socket( AF_INET, type, 0 )) );
    }
#endif
}
```

注意 Windows 上有个有趣的细节:首次调用 socket 可能失败(WSANOTINITIALISED),这时会触发 `initNetwork()` 进行 WSAStartup,然后再试一次。这是典型的"懒初始化"模式,避免在静态初始化阶段就要求 Winsock 已就绪。

`initNetwork()` 内部会做:

```cpp
// endpoint.cpp:699-748
void initNetwork()
{
    if (s_networkInitted) return;
    s_networkInitted = true;

#if defined(_WIN32) && defined( USE_OPENSSL )
    // 设置 OpenSSL 内存钩子,把分配重定向到 bw_malloc/bw_free
    BWOpenSSL::CRYPTO_set_mem_functions(OpenSSLMemHooks::malloc, ...);
#endif

#ifdef _WIN32
    WSAData wsdata;
    WSAStartup( 0x202, &wsdata );  // Winsock 2.2
#endif
}
```

`finiNetwork()` 对应清理:

```cpp
// endpoint.cpp:750-773
void finiNetwork()
{
    if (!s_networkInitted) return;
#if defined(_WIN32) && defined( USE_OPENSSL )
    BWOpenSSL::EVP_cleanup();
    BWOpenSSL::ERR_free_strings();
    // ... OpenSSL 清理 ...
#endif
#ifdef _WIN32
    WSACleanup();
#endif
}
```

### 3.4 非阻塞模式

`setnonblocking` 是 Mercury 性能的关键,因为 Mercury 是单线程事件驱动模型,所有 socket 都必须非阻塞。各平台实现:

```cpp
// endpoint.ipp:99-113
INLINE int Endpoint::setnonblocking(bool nonblocking)
{
    BW_GUARD;
#if defined( __unix__ ) || defined( __APPLE__ ) || defined( __ANDROID__ ) || \
            defined( EMSCRIPTEN )
    int val = nonblocking ? O_NONBLOCK : 0;
    return ::fcntl(socket_,F_SETFL,val);            // POSIX fcntl
#elif defined( PLAYSTATION3 )
    int val = nonblocking ? 1 : 0;
    return setsockopt( socket_, SOL_SOCKET, SO_NBIO, &val, sizeof(int) );  // PS3
#else
    u_long val = nonblocking ? 1 : 0;
    return ::ioctlsocket(socket_,FIONBIO,&val);      // Windows ioctlsocket
#endif
}
```

三个分支三种 API:`fcntl(F_SETFL)` 是 POSIX 标准,PS3 用 `SO_NBIO` 选项,Windows 用 `ioctlsocket(FIONBIO)`。

### 3.5 bind 与地址绑定

`bind` 接受网络字节序的端口和地址:

```cpp
// endpoint.ipp:202-210
INLINE int Endpoint::bind( u_int16_t networkPort, u_int32_t networkAddr )
{
    BW_GUARD;
    sockaddr_in sin;
    sin.sin_family = AF_INET;
    sin.sin_port = networkPort;
    sin.sin_addr.s_addr = networkAddr;
    return ::bind( socket_, (struct sockaddr*)&sin, sizeof(sin) );
}
```

`networkPort` 和 `networkAddr` 已经是网络字节序,直接赋给 `sin_port` 和 `s_addr`,不需要 `htons/htonl`。这是一个微妙的设计:Mercury 内部一律使用网络字节序存储地址,只在显示时才转换。

### 3.6 sendto/recvfrom

UDP 发送和接收的核心调用。`sendto` 有三个重载,最终都汇聚到 `sockaddr_in` 版本:

```cpp
// endpoint.ipp:373-404
INLINE int Endpoint::sendto( void * gramData, int gramSize,
    u_int16_t networkPort, u_int32_t networkAddr ) const
{
    BW_GUARD;
    sockaddr_in sin;
    sin.sin_family = AF_INET;
    sin.sin_port = networkPort;
    sin.sin_addr.s_addr = networkAddr;
    return this->sendto( gramData, gramSize, sin );
}

INLINE int Endpoint::sendto( void * gramData, int gramSize,
    const struct sockaddr_in & sin ) const
{
    BW_GUARD;
    int flags = 0;
#ifdef __linux__
    flags = MSG_NOSIGNAL;  // 避免对端关闭时产生 SIGPIPE
#endif
    return ::sendto( socket_, (char*)gramData, gramSize,
        flags, (sockaddr*)&sin, sizeof(sin) );
}
```

注意 Linux 上加了 `MSG_NOSIGNAL` 标志,这是为了避免在连接被对端关闭时内核发送 SIGPIPE 信号导致进程崩溃。服务器进程通常都忽略 SIGPIPE,这里也是双保险:

```cpp
// endpoint.cpp:776-796 (MF_SERVER 编译)
class StaticIniter
{
public:
    StaticIniter()
    {
        struct sigaction ignore;
        memset(&ignore, 0, sizeof(ignore));
        ignore.sa_handler = SIG_IGN;
        sigaction( SIGPIPE, &ignore, NULL );  // 全局忽略 SIGPIPE
    }
};
StaticIniter g_staticIniter;
```

`recvfrom` 类似,有三个重载:

```cpp
// endpoint.ipp:434-507
INLINE int Endpoint::recvfrom( void * gramData, int gramSize,
    u_int16_t * networkPort, u_int32_t * networkAddr ) const
{
    BW_GUARD;
    sockaddr_in sin;
    if (networkPort != NULL) *networkPort = 0;
    if (networkAddr != NULL) *networkAddr = 0;
    int result = this->recvfrom( gramData, gramSize, sin );
    if (result >= 0) {
        if (networkPort != NULL) *networkPort = sin.sin_port;
        if (networkAddr != NULL) *networkAddr = sin.sin_addr.s_addr;
    }
    return result;
}

INLINE int Endpoint::recvfrom( void * gramData, int gramSize,
    struct sockaddr_in & sin ) const
{
    BW_GUARD;
    socklen_t sinLen = sizeof(sin);
    int ret = ::recvfrom( socket_, (char*)gramData, gramSize,
        0, (sockaddr*)&sin, &sinLen );
    return ret;
}
```

`Mercury::Address` 版本最常用:

```cpp
// endpoint.ipp:500-507
INLINE int Endpoint::recvfrom( void * gramData, int gramSize,
    Mercury::Address & addr ) const
{
    BW_GUARD;
    return this->recvfrom( gramData, gramSize,
        reinterpret_cast< u_int16_t * >(&addr.port),
        reinterpret_cast< u_int32_t * >(&addr.ip) );
}
```

`Mercury::Address` 的 `ip` 和 `port` 字段直接被 `recvfrom` 填充,因为 `Address` 在内存布局上和 `(ip, port)` 元组兼容(见 `basictypes.hpp:271-304`):

```cpp
// basictypes.hpp:271-304
class Address
{
public:
    Address();
    Address( uint32 ipArg, uint16 portArg );

    uint32  ip;     ///< IP 地址(网络字节序)
    uint16  port;   ///< 端口(网络字节序)
    uint16  salt;   ///< 每次不同(用于 EntityMailBoxRef 编码 component+type)
    // ...
};
```

注意 `Address` 还有一个 `salt` 字段,但 `recvfrom` 不填充它,因为它只用于 EntityMailBoxRef 的紧凑编码。

### 3.7 connect 与 TCP 支持

虽然 Mercury 主推 UDP,但 `Endpoint` 也支持 TCP(`SOCK_STREAM`):

```cpp
// endpoint.ipp:513-564
INLINE int Endpoint::listen( int backlog ) {
    BW_GUARD;
    return ::listen( socket_, backlog );
}

INLINE int Endpoint::connect( u_int16_t networkPort, u_int32_t networkAddr )
{
    BW_GUARD;
    sockaddr_in sin;
    sin.sin_family = AF_INET;
    sin.sin_port = networkPort;
    sin.sin_addr.s_addr = networkAddr;
    return ::connect( socket_, (sockaddr*)&sin, sizeof(sin) );
}

INLINE Endpoint * Endpoint::accept( u_int16_t * networkPort, u_int32_t * networkAddr )
{
    BW_GUARD;
    sockaddr_in sin;
    socklen_t sinLen = sizeof(sin);
    int ret = int(::accept( socket_, (sockaddr*)&sin, &sinLen));
#if defined( __unix__ ) || ...
    if (ret < 0) {
        ERROR_MSG( "Endpoint::accept: accept failed (%s) for socket %d\n",
            strerror( errno ), socket_ );
        return NULL;
    }
#else
    if (ret == INVALID_SOCKET) return NULL;
#endif
    Endpoint * pNew = new Endpoint();
    pNew->setFileDescriptor( ret );
    if (networkPort != NULL) *networkPort = sin.sin_port;
    if (networkAddr != NULL) *networkAddr = sin.sin_addr.s_addr;
    return pNew;
}
```

`TCPChannel`(`tcp_channel.hpp`)就是基于 `connect`/`accept` 实现的,用于客户端 WebSocket 接入、Watcher TCP 通道等场景。

### 3.8 网络接口查询

`Endpoint` 还提供查询本机网络接口的能力,主要用于 bwmachined 发现和绑定特定接口:

```cpp
// endpoint.hpp:166-175
typedef BW::map< u_int32_t, BW::string > InterfaceMap;
int getInterfaceFlags( char * name, int & flags );
int getInterfaceAddress( const char * name, u_int32_t & address );
bool getInterfaces( InterfaceMap & interfaces, const char * netmaskStr = NULL );
int findDefaultInterface( char * name );
int findIndicatedInterface( const char * spec, char * name );
static int convertAddress( const char * string, u_int32_t & address );
```

`getInterfaces` 在 Linux 上用 `ioctl(SIOCGIFCONF)`:

```cpp
// endpoint.cpp:233-284
bool Endpoint::getInterfaces( InterfaceMap & interfaces, const char * netmaskStr )
{
#ifdef _WIN32
    CRITICAL_MSG( "Endpoint::getInterfaces: Not implemented for Windows.\n" );
    return false;
#else
    struct ifconf ifc;
    char buf[ 1024 ];
    ifc.ifc_len = sizeof( buf );
    ifc.ifc_buf = buf;
    if (ioctl( socket_, SIOCGIFCONF, &ifc ) < 0) {
        ERROR_MSG( "Endpoint::getInterfaces: ioctl(SIOCGIFCONF) failed.\n" );
        return false;
    }
    NetMask netmask;
    if (netmaskStr) {
        if (!netmask.parse( netmaskStr )) {
            WARNING_MSG( "Endpoint::getInterfaces: failed to parse netmask '%s'\n",
                netmaskStr );
        }
    }
    struct ifreq * ifr = ifc.ifc_req;
    int nInterfaces = ifc.ifc_len / sizeof( struct ifreq );
    for (int i = 0; i < nInterfaces; i++) {
        struct ifreq *item = &ifr[i];
        struct sockaddr_in * s = (struct sockaddr_in *) &(item->ifr_addr);
        if (!netmask.contains_address( s->sin_addr.s_addr ))
            continue;
        interfaces[ s->sin_addr.s_addr ] = item->ifr_name;
    }
    return true;
#endif
}
```

`findDefaultInterface` 找第一个非 loopback 的 UP+RUNNING 接口;`findIndicatedInterface` 支持三种格式:接口名(eth0)、IP 地址(10.0.0.1)、网段(10.0.0.0/24)。

### 3.9 错误队列(Linux ICMP)

Linux 上一个高级特性是 IP_RECVERR 错误队列,可以读取 ICMP 错误信息:

```cpp
// endpoint.cpp:113-222
void Endpoint::enableErrorQueue( bool shouldEnable )
{
#if defined( __unix__ )
    int enableValue = shouldEnable ? 1 : 0;
    ::setsockopt( socket_, SOL_IP, IP_RECVERR, &enableValue, sizeof(int) );
#else
    // No-op for other OS's.
#endif
}

bool Endpoint::readFromErrorQueue( int & queuedErrNo,
        Mercury::Address & offenderAddress, uint32 & info )
{
#if defined( __linux__ ) && !defined( EMSCRIPTEN )
    struct sockaddr_in offender;
    // ... 设置 msghdr ...
    int errMsgErr = recvmsg( this->fileno(), &errHeader, MSG_ERRQUEUE );
    if (errMsgErr < 0) return false;
    // 遍历控制消息找 IP_RECVERR
    for (ctlHeader = CMSG_FIRSTHDR( &errHeader ); ...) {
        if ((ctlHeader->cmsg_level == SOL_IP) &&
                (ctlHeader->cmsg_type == IP_RECVERR)) break;
    }
    if (ctlHeader != NULL) {
        struct sock_extended_err * extError =
            (struct sock_extended_err*)CMSG_DATA( ctlHeader );
        queuedErrNo = extError->ee_errno;
        // ... 处理 offender 地址 ...
        offenderAddress.ip = offender.sin_addr.s_addr;
        offenderAddress.port = offender.sin_port;
        info = extError->ee_info;
        isResultSet = true;
    }
#endif
    return isResultSet;
}
```

`PacketReceiver` 用这个机制处理两种 ICMP 错误:

- `ECONNREFUSED`:对端端口未开放(`onConnectionRefusedTo`)
- `EMSGSIZE`:包超过 MTU(`onMTUExceeded`)

这让 Mercury 能即时感知网络层错误,而不必等待应用层超时。

### 3.10 缓冲区与队列大小

`Endpoint` 提供 socket 缓冲区大小调节:

```cpp
// endpoint.cpp:550-595
int Endpoint::getBufferSize( int optname ) const
{
#ifdef __unix__
    MF_ASSERT( optname == SO_SNDBUF || optname == SO_RCVBUF );
    int recvbuf = -1;
    socklen_t rbargsize = sizeof( int );
    int rberr = getsockopt( socket_, SOL_SOCKET, optname,
        (char*)&recvbuf, &rbargsize );
    if (rberr == 0 && rbargsize == sizeof( int )) return recvbuf;
    else { /* error */ return -1; }
#else
    return -1;
#endif
}

bool Endpoint::setBufferSize( int optname, int size )
{
#ifdef __unix__
    setsockopt( socket_, SOL_SOCKET, optname, (const char*)&size, sizeof( size ) );
#endif
    return this->getBufferSize( optname ) >= size;
}
```

Mercury 推荐的最低缓冲区大小(`basictypes.hpp:78-79`):

```cpp
const int MIN_SND_SKT_BUF_SIZE = 1048576;   // 1MB
const int MIN_RCV_SKT_BUF_SIZE = 16777216;  // 16MB
```

`transmitQueueSize` 和 `receiveQueueSize` 在 Linux 上通过 `TIOCOUTQ`/`FIONREAD` ioctl 实现:

```cpp
// endpoint.cpp:524-542
#ifdef __unix__
int Endpoint::getQueueSizes( int & tx, int & rx ) const
{
    if (NetworkStats::getQueueSizes( *this, tx, rx )) return 0;
    return -1;
}
#else
int Endpoint::getQueueSizes( int &, int & ) const { return -1; }
#endif
```

`numBytesAvailableForReading` 用 `FIONREAD`:

```cpp
// endpoint.ipp:122-145
INLINE int Endpoint::numBytesAvailableForReading() const
{
#if (defined( __unix__ ) || defined( __APPLE__ )) || defined( EMSCRIPTEN )
    int numBytes = 0;
    int error = ioctl( socket_, FIONREAD, &numBytes);
    if (error != 0) return -1;
    return numBytes;
#elif defined( _WIN32 )
    u_long numBytes = 0;
    int error = ::ioctlsocket( socket_, FIONREAD, &numBytes );
    if (error != 0) return -1;
    return numBytes;
#else
    return -1;
#endif
}
```

这是 `PacketReceiver::handleInputNotification` 用来判断"还有多少包要读"的关键。

### 3.11 Socket 选项模板

`getSocketOption`/`setSocketOption` 是模板方法,屏蔽 Windows 与 POSIX 的 `getsockopt/setsockopt` 签名差异:

```cpp
// endpoint.hpp:215-272
template< typename T >
inline int Endpoint::getSocketOption( int level, int optname, T & optval )
{
#if defined( _WIN32 )
    char * optvalCast = reinterpret_cast< char * >( &optval );
    int optlenCast = sizeof(T);
#else
    void * optvalCast = &optval;
    socklen_t optlenCast = sizeof(T);
#endif
    return ::getsockopt( socket_, level, optname, optvalCast, &optlenCast );
}

template< typename T >
inline int Endpoint::setSocketOption( int level, int optname, const T & optval )
{
#if defined( _WIN32 )
    const char * optvalCast = reinterpret_cast< const char * >( &optval );
#else
    const void * optvalCast = &optval;
#endif
    return ::setsockopt( socket_, level, optname, optvalCast, sizeof(T) );
}

// bool 特化
template<>
inline int Endpoint::setSocketOption( int level, int optname, const bool & optval )
{
    int intVal = optval ? 1 : 0;
    return this->setSocketOption( level, optname, intVal );
}
```

Windows 的 `setsockopt` 接受 `const char*`,而 POSIX 接受 `const void*`,这里通过 `reinterpret_cast` 屏蔽差异。`bool` 特化让上层可以直接传 `true/false`,无需关心 socket 选项实际是 int 类型。

---

## 四、Packet 数据包格式深度剖析

### 4.1 Packet 在 Mercury 中的位置

`Packet`(`packet.hpp:50`)是 Mercury 在网络上传输的最小数据单元。一个 Bundle 可以包含多个 Packet(分片),但一个 Packet 永远不会跨多个 UDP datagram。也就是说,**一个 Packet 对应一个 UDP `sendto`/`recvfrom` 调用**。

### 4.2 Packet 的最大尺寸

```cpp
// packet.hpp:9
#define PACKET_MAX_SIZE 1472
```

1472 字节是怎么来的?以太网 MTU 通常是 1500 字节,减去 IP 头(20 字节)和 UDP 头(8 字节)就是 1472。这就是经典的 MTU 1500 - 28 = 1472 推导,`UDP_OVERHEAD = 28` 在 `basictypes.hpp:34` 也确认了这点:

```cpp
// basictypes.hpp:34
const int UDP_OVERHEAD = 28;
```

`Packet::MAX_SIZE` 在 cpp 中定义为 `PACKET_MAX_SIZE`:

```cpp
// packet.cpp:48
const int Packet::MAX_SIZE = PACKET_MAX_SIZE;
```

这个值的注释很关键:

> "The default max size for a packet is the MTU of an ethernet frame, minus the overhead of IP and UDP headers. If you have special requirements for packet sizes (e.g. your client/server connection is running over VPN) you can edit this to whatever you need."

也就是说,如果你的网络环境 MTU 小于 1500(如 VPN 的 1400),可以调小这个值避免 IP 分片。

### 4.3 Packet 的内存布局

`Packet` 类的关键成员:

```cpp
// packet.hpp:50-360
class Packet : public ReferenceCount
{
public:
    typedef uint16 Flags;
    enum {
        FLAG_HAS_REQUESTS            = 0x0001,
        FLAG_HAS_PIGGYBACKS          = 0x0002,
        FLAG_HAS_ACKS                = 0x0004,
        FLAG_ON_CHANNEL              = 0x0008,
        FLAG_IS_RELIABLE             = 0x0010,
        FLAG_IS_FRAGMENT             = 0x0020,
        FLAG_HAS_SEQUENCE_NUMBER     = 0x0040,
        FLAG_INDEXED_CHANNEL         = 0x0080,
        FLAG_HAS_CHECKSUM            = 0x0100,
        FLAG_CREATE_CHANNEL          = 0x0200,
        FLAG_HAS_CUMULATIVE_ACK      = 0x0400,
        KNOWN_FLAGS                  = 0x07FF
    };
    typedef uint8 AckCount;
    typedef uint16 Offset;
    typedef uint32 Checksum;
    static const int HEADER_SIZE = sizeof( Flags );  // 2 字节
    static const int RESERVED_FOOTER_SIZE = ...;      // 27 字节
private:
    PacketPtr next_;            // 链表下一个(分片链)
    int msgEndOffset_;         // 消息数据结束偏移
    int footerSize_;           // footer 总大小
    int extraFilterSize_;      // PacketFilter 预留
    Offset firstRequestOffset_;// 第一个请求偏移
    Offset* pLastRequestOffset_;// 上一个请求的 next 链
    AckCount nAcks_;           // ACK 数量
    Field piggyFooters_;      // 搭车 footer
    SeqNum seq_;              // 序列号
    ChannelID channelID_;     // 索引通道 ID
    ChannelVersion channelVersion_;  // 通道版本
    SeqNum fragBegin_;        // 分片起始 seq
    SeqNum fragEnd_;          // 分片结束 seq
    bool isPiggyback_;
    Checksum checksum_;
    char data_[PACKET_MAX_SIZE];  // 实际数据
};
```

注意 `data_` 是固定大小数组,**Packet 对象总大小 = sizeof(Packet 头部) + 1472**。这种设计让 Packet 可以直接 `new Packet()` 分配,无需二次分配 buffer,适合 `SmartPointer<Packet>` 引用计数管理。

### 4.4 Header 与 Footer 布局

一个 Packet 在网络上的实际字节布局如下:

```
+----------------+--------------------+-----------------+-------------+
| Flags (2 bytes)| Message Data (变长)| Filter Footer  | Footers     |
+----------------+--------------------+-----------------+-------------+
^                                    ^                                ^
data_                                msgEndOffset_                     +totalSize
                                     (临时)
```

其中:
- **Flags**:2 字节,头部标志位(网络字节序)
- **Message Data**:消息流,从 `HEADER_SIZE` 开始,到 `msgEndOffset_` 结束
- **Footers**:从消息数据末尾向后追加,各种 footer 如 seq、ack、channel、checksum 等

#### 4.4.1 HEADER_SIZE

```cpp
// packet.hpp:94
static const int HEADER_SIZE = sizeof( Flags );  // = 2
```

只有 2 字节的 Flags,非常精简。所有其他元数据都通过 footer 携带。

#### 4.4.2 RESERVED_FOOTER_SIZE

```cpp
// packet.hpp:104-110
static const int RESERVED_FOOTER_SIZE =
    sizeof( Offset ) +              // 2   FLAG_HAS_REQUESTS
    sizeof( AckCount ) +            // 1   FLAG_HAS_ACKS
    sizeof( SeqNum ) +              // 4   FLAG_HAS_SEQUENCE_NUMBER
    sizeof( SeqNum ) * 2 +          // 8   FLAG_IS_FRAGMENT
    sizeof( ChannelID ) + sizeof( ChannelVersion ) + // 4+4 FLAG_INDEXED_CHANNEL
    sizeof( Checksum );             // 4   FLAG_HAS_CHECKSUM
```

总共 2+1+4+8+8+4 = **27 字节**。这是预留的最大 footer 大小,确保 Bundle 在写入消息时不需要考虑 footer 是否能放下。注释明确说明这一点:

> "The amount of space that is reserved for fixed-length footers on a packet. This is done so that the bundle logic can always assume that these footers will fit and not have to worry about pre-allocating them. This is currently 27 bytes, roughly 1.5% of the capacity of a packet, so there's not too much wastage."

27 / 1472 ≈ 1.83%,确实是很小的浪费。

#### 4.4.3 最大可用 payload

```cpp
// packet.hpp:297-300
static int maxCapacity()
{
    return MAX_SIZE - HEADER_SIZE - RESERVED_FOOTER_SIZE;
    // = 1472 - 2 - 27 = 1443 字节
}
```

每个 Packet 最多可携带 1443 字节的用户消息数据。

### 4.5 标志位详解

| 标志位 | 值 | 含义 |
|--------|-----|------|
| `FLAG_HAS_REQUESTS` | 0x0001 | 包含请求消息,需要 ReplyID 处理 |
| `FLAG_HAS_PIGGYBACKS` | 0x0002 | 包含 piggyback 包(丢失的可靠消息搭车) |
| `FLAG_HAS_ACKS` | 0x0004 | 包含 ACK 信息 |
| `FLAG_ON_CHANNEL` | 0x0008 | 这个包属于一个 Channel(非 once-off) |
| `FLAG_IS_RELIABLE` | 0x0010 | 这是可靠包,需要 ACK |
| `FLAG_IS_FRAGMENT` | 0x0020 | 这是分片 Bundle 的一部分 |
| `FLAG_HAS_SEQUENCE_NUMBER` | 0x0040 | 包含序列号 |
| `FLAG_INDEXED_CHANNEL` | 0x0080 | 这是索引通道(多路复用) |
| `FLAG_HAS_CHECKSUM` | 0x0100 | 包含校验和 |
| `FLAG_CREATE_CHANNEL` | 0x0200 | 接收端应创建匿名通道 |
| `FLAG_HAS_CUMULATIVE_ACK` | 0x0400 | 包含累积 ACK |
| `KNOWN_FLAGS` | 0x07FF | 已知标志位掩码 |

标志位的访问方法:

```cpp
// packet.hpp:126-130
Flags flags() const { return BW_NTOHS( *(Flags*)data_ ); }
bool hasFlags( Flags flags ) const { return (this->flags() & flags) == flags; }
void setFlags( Flags flags ) { *(Flags*)data_ = BW_HTONS( flags ); }
void enableFlags( Flags flags ) { *(Flags*)data_ |= BW_HTONS( flags ); }
void disableFlags( Flags flags ) { *(Flags*)data_ &= ~BW_HTONS( flags ); }
```

注意所有读写都通过 `BW_HTONS`/`BW_NTOHS` 转换字节序,确保网络字节序在 wire 上的一致性。

### 4.6 Footer 写入与剥离

`Packet` 用 `packFooter`/`stripFooter` 模板方法处理 footer。**Footer 是从消息末尾向后(高地址)写入,但读取时从后向前剥离**。

#### 4.6.1 packFooter(写入)

```cpp
// packet.hpp:245-265
template <class TYPE>
void packFooter( TYPE value )
{
    msgEndOffset_ -= sizeof( TYPE );  // 向前移动 msgEndOffset
    switch( sizeof( TYPE ) ) {
        case sizeof( uint8 ):
            *(TYPE*)this->back() = value; break;
        case sizeof( uint16 ):
            *(TYPE*)this->back() = BW_HTONS( value ); break;
        case sizeof( uint32 ):
            *(TYPE*)this->back() = BW_HTONL( value ); break;
        default:
            CRITICAL_MSG( "Footers of size %" PRIzu " aren't supported",
                sizeof( TYPE ) );
    }
}
```

注意:**`packFooter` 实际上是把 `msgEndOffset_` 向前移动**,然后在腾出的位置写入值。这与直觉相反——footer 在物理上是写在消息数据之后的,但代码通过"借用"消息末尾空间来实现。

#### 4.6.2 stripFooter(剥离)

```cpp
// packet.hpp:208-236
template <class TYPE>
bool stripFooter( TYPE & value )
{
    if (this->bodySize() < int( sizeof( TYPE ) )) return false;
    msgEndOffset_ -= sizeof( TYPE );   // 向前移动
    footerSize_ += sizeof( TYPE );    // footerSize 增加
    switch( sizeof( TYPE ) ) {
        case sizeof( uint8 ):
            value = TYPE( *(TYPE*)this->back() ); break;
        case sizeof( uint16 ):
            value = TYPE( BW_NTOHS( *(TYPE*)this->back() ) ); break;
        case sizeof( uint32 ):
            value = Type( BW_NTOHL( *(TYPE*)this->back() ) ); break;
        default:
            CRITICAL_MSG( ... );
    }
    return true;
}
```

`stripFooter` 在接收时使用:把 `msgEndOffset_` 向前移,让 `back()` 指向 footer 起始,然后读出值。

### 4.7 Checksum 校验和

`Packet` 支持可选的 XOR 校验和:

```cpp
// packet.cpp:277-320
bool Packet::validateChecksum()
{
    if (this->hasFlags( Packet::FLAG_HAS_CHECKSUM )) {
        if (!this->stripFooter( checksum_ )) {
            WARNING_MSG( "Packet::validateChecksum: Packet too short ...\n" );
            return false;
        }
        // 把 checksum 字段清零,以便重新计算
        *(Packet::Checksum*)this->back() = 0;
        // XOR 所有 4 字节字
        Packet::Checksum sum = 0;
        for (const Packet::Checksum * pData = (Packet::Checksum*)this->data();
                pData < (Packet::Checksum*)this->back(); pData++) {
            sum ^= BW_NTOHL( *pData );
        }
        // 还原 checksum(以便转发)
        *(Packet::Checksum*)this->back() = BW_HTONL( checksum_ );
        if (sum != checksum_) {
            ERROR_MSG( "Packet::validateChecksum: Packet failed checksum "
                "(wanted %08x, got %08x)\n", sum, checksum_ );
            return false;
        }
    }
    return true;
}
```

这是一个非常简单的 32 位 XOR 校验,不是密码学哈希。它的作用是检测传输中的位翻转,**不能防恶意篡改**(防篡改由 `EncryptionFilter` 完成)。

`writeChecksum` 在发送时计算:

```cpp
// packet.cpp:432-456
void Packet::writeChecksum( Checksum * pChecksum )
{
    if (pChecksum == NULL) return;
    MF_ASSERT( (char *)pChecksum - data_ < PACKET_MAX_SIZE );
    MF_ASSERT( this->hasFlags( Packet::FLAG_HAS_CHECKSUM ) );
    *pChecksum = 0;  // 先清零
    Packet::Checksum sum = 0;
    for (Packet::Checksum * pData = (Packet::Checksum *)this->data();
            pData < pChecksum; pData++) {
        sum ^= BW_NTOHL( *pData );
    }
    *pChecksum = BW_HTONL( sum );
}
```

`shouldUseChecksums` 默认关闭,可在配置中开启。

### 4.8 Piggyback 搭车机制

`FLAG_HAS_PIGGYBACKS` 是 Mercury 的一个特色:**丢失的可靠消息可以"搭车"在下一个 outgoing bundle 上**。

`processPiggybackPackets` 在接收端剥离 piggyback 包:

```cpp
// packet.cpp:327-382
bool Packet::processPiggybackPackets( PacketVisitor & visitor )
{
    if (!this->hasFlags( FLAG_HAS_PIGGYBACKS )) return true;
    bool done = false;
    while (!done) {
        int16 len;
        if (!this->stripFooter( len )) {
            WARNING_MSG( "Packet::processPiggybackPackets: Not enough data ...\n" );
            return false;
        }
        // 最后一个 piggyback 的长度为负数(取反)
        if (len < 0) { len = ~len; done = true; }
        if (this->bodySize() < len) {
            WARNING_MSG( "Packet::processPiggybackPackets: Packet too small ...\n" );
            return false;
        }
        // 创建 piggyback 子包
        this->shrink( len );
        PacketPtr pPiggybackPacket = new Packet();
        memcpy( pPiggybackPacket->data(), this->back(), len );
        pPiggybackPacket->msgEndOffset( len );
        pPiggybackPacket->isPiggyback( true );
        if (!visitor.onPacket( pPiggybackPacket )) return false;
    }
    return true;
}
```

这种设计避免了为丢失的可靠消息单独发包,把重传开销分摊到正常流量上。详见 [第六章 Piggyback 一节](#611-piggyback-机制)。

### 4.9 Fragment 分片信息

当 Bundle 跨多个 Packet 时,每个 Packet 都会被设置 `FLAG_IS_FRAGMENT`,并携带 `fragBegin_` 和 `fragEnd_` 两个 SeqNum,标识这个 Bundle 的 seq 范围:

```cpp
// packet.cpp:129-167
bool Packet::stripFragInfo()
{
    if (this->bodySize() < int( sizeof( SeqNum ) * 2 )) {
        WARNING_MSG( "Packet::stripFragInfo: Not enough footers ...\n" );
        return false;
    }
    this->stripFooter( fragEnd_ );
    this->stripFooter( fragBegin_ );
    const int numFragmentsInBundle = fragEnd_ - fragBegin_ + 1;
    if (numFragmentsInBundle < 2) {
        WARNING_MSG( "Packet::stripFragInfo: Illegal fragment count (%d)\n",
            numFragmentsInBundle );
        return false;
    }
    if (seq_ < fragBegin_ || seq_ > fragEnd_) {
        WARNING_MSG( "Packet::stripFragInfo: Fragment range [#%u,#%u] does not "
                "include packet's sequence #%u\n", fragBegin_, fragEnd_, seq_ );
        return false;
    }
    return true;
}
```

校验逻辑:分片数至少 2(否则不该有分片标志),且当前 packet 的 seq 必须在 [fragBegin, fragEnd] 范围内。

### 4.10 Packet 链表

`Packet` 通过 `next_` 字段形成单向链表:

```cpp
// packet.hpp:120-124
Packet * next() { return next_.get(); }
const Packet * next() const { return next_.get(); }
void chain( Packet * pPacket ) { next_ = pPacket; }
int chainLength() const;
```

`chainLength` 计算链长度:

```cpp
// packet.cpp:89-99
int Packet::chainLength() const
{
    int count = 1;
    for (const Packet * p = this->next(); p != NULL; p = p->next()) ++count;
    return count;
}
```

Bundle 的多个分片就通过这个链表组织;接收端重组时也用链表。

### 4.11 Packet 序列化(用于通道迁移)

当 entity 在 CellApp 之间 offload 时,其 Channel 状态(包括 unacked packets、buffered receives)需要序列化传输。`addToStream`/`createFromStream` 完成这个工作:

```cpp
// packet.cpp:195-228
void Packet::addToStream( BinaryOStream & data, const Packet * pPacket, int state )
{
    data << uint8( pPacket != NULL );
    if (pPacket) {
        if (state == UNACKED_SEND) {
            // 完整保存
            data.appendString( pPacket->data(), pPacket->totalSize() );
            data << int32( pPacket->footerSize() );
        } else {
            // 只保存未处理部分
            data.appendString( pPacket->data(), pPacket->msgEndOffset() );
            data << int32( 0 );
        }
        data << pPacket->seq() << pPacket->channelID();
        if (state == CHAINED_FRAGMENT) {
            data << pPacket->fragBegin() << pPacket->fragEnd() <<
                pPacket->firstRequestOffset();
        }
    }
}
```

`UNACKED_SEND` 状态需要完整保存(因为可能还要重传),`BUFFERED_RECEIVE` 和 `CHAINED_FRAGMENT` 只保存未处理部分。

### 4.12 Packet 引用计数

`Packet` 继承自 `ReferenceCount`,通过 `SmartPointer<Packet>`(`PacketPtr`)管理生命周期:

```cpp
// packet.hpp:30-31
class Packet;
typedef SmartPointer< Packet > PacketPtr;
```

引用计数让 Packet 可以同时被多个所有者持有(如 unacked 列表 + 即将发送的链表),自动在最后一个引用释放时销毁。

---

## 五、Channel 逻辑通道架构

### 5.1 Channel 抽象基类

`Channel`(`channel.hpp:35`)是 Mercury 通道的抽象基类。它派生自 `ReferenceCount`(支持 SmartPointer)和可选的 `WatcherProvider`(支持监控):

```cpp
// channel.hpp:35-40
class Channel :
#if ENABLE_WATCHERS
    public WatcherProvider,
#endif // ENABLE_WATCHERS
    public ReferenceCount
{
public:
    virtual WatcherPtr getWatcher() = 0;
    virtual Bundle * newBundle() = 0;
    virtual const char * c_str() const = 0;
    virtual bool hasUnsentData() const = 0;
    virtual bool isExternal() const = 0;
    virtual bool isConnected() const { return !this->isDestroyed(); }
    virtual void shutDown() { this->destroy(); }
    virtual void onChannelInactivityTimeout() { this->destroy(); }
    virtual bool isTCP() const = 0;
    virtual void setEncryption( Mercury::BlockCipherPtr pBlockCipher ) = 0;
    virtual double roundTripTimeInSeconds() const = 0;
    // ...
};
```

`Channel` 抽象了三个核心维度:
- **数据收发**:`newBundle`、`send`、`bundle`
- **状态查询**:`isExternal`、`isConnected`、`isDestroyed`、`roundTripTimeInSeconds`
- **生命周期**:`shutDown`、`destroy`、`onChannelInactivityTimeout`

### 5.2 两种实现:UDPChannel 与 TCPChannel

Mercury 提供两种 Channel 实现:

| 实现 | 文件 | 用途 |
|------|------|------|
| `UDPChannel` | `udp_channel.hpp` / `udp_channel.cpp` | 服务器间通信,可靠 UDP |
| `TCPChannel` | `tcp_channel.hpp` / `tcp_channel.cpp` | 客户端接入,WebSocket,Watcher |

`UDPChannel` 是 Mercury 的核心,承担了 99% 的内部通信。本专题主要剖析 `UDPChannel`,`TCPChannel` 在 [第十七章](#十七跨平台支持与-io-模型) 简述。

### 5.3 Channel 的核心数据成员

`Channel` 基类持有的成员(`channel.hpp:283-304`):

```cpp
// channel.hpp:283-304
protected:
    Address             addr_;              // 对端地址
    Bundle *            pBundle_;           // 当前 bundle
    BundlePrimer *      pBundlePrimer_;     // bundle 预填充器
    MessageFilterPtr    pMessageFilter_;    // 消息过滤器
    NetworkInterface *  pNetworkInterface_; // 所属接口
    bool                isDestroyed_;        // 是否已销毁
    TimerHandle         inactivityTimerHandle_;  // 不活跃定时器
    uint64              lastReceivedTime_;  // 上次收到数据时间
    ChannelListener *   pListener_;         // 监听器
    void *              userData_;          // 应用数据
    // 统计
    uint32 numDataUnitsSent_;
    uint32 numDataUnitsReceived_;
    uint32 numBytesSent_;
    uint32 numBytesReceived_;
```

注意 `pBundle_` 是裸指针,但由 Channel 自己管理(`clearBundle` 创建,析构销毁)。

### 5.4 send 与 finalise 流程

`Channel::send` 是发送的统一入口:

```cpp
// channel.cpp:149-187
void Channel::send( Bundle * pBundle /* = NULL */ )
{
    ChannelPtr pChannel( this );  // 防止自身在回调中被销毁
    if (!this->isConnected()) {
        ERROR_MSG( "Channel::send( %s ): Channel is not connected\n", this->c_str() );
        return;
    }
    if (pBundle == NULL) pBundle = pBundle_;
    this->doPreFinaliseBundle( *pBundle );   // 子类钩子
    pBundle->finalise();                     // 最终化
    this->networkInterface().addReplyOrdersTo( *pBundle, this );  // 注册请求
    this->doSend( *pBundle );                // 子类实现实际发送
    if (pBundle == pBundle_) {
        this->clearBundle();                 // 清空 bundle
    } else {
        pBundle->clear();
    }
    if (pListener_) pListener_->onChannelSend( *this );  // 监听回调
}
```

发送流程的关键步骤:
1. **`doPreFinaliseBundle`**:子类钩子,UDPChannel 在这里写 channel 标志
2. **`finalise`**:Bundle 完成消息打包,不能再写入
3. **`addReplyOrdersTo`**:把 Bundle 中的 Request 注册到 RequestManager
4. **`doSend`**:子类实际发送(UDPChannel 走 PacketSender)
5. **`clearBundle`**:清空 bundle,准备下次使用

`doPreFinaliseBundle` 和 `doSend` 都是 `protected virtual`,由子类重写:

```cpp
// channel.hpp:261-268
protected:
    virtual void doPreFinaliseBundle( Bundle & bundle ) {}
    virtual void doSend( Bundle & bundle ) = 0;
```

### 5.5 不活跃检测

`Channel` 内置不活跃检测机制:

```cpp
// channel.cpp:260-271
void Channel::startInactivityDetection( float period, float checkPeriod )
{
    inactivityTimerHandle_.cancel();
    uint64 inactivityExceptionPeriod = uint64( period * stampsPerSecond() );
    lastReceivedTime_ = timestamp();
    inactivityTimerHandle_ = this->dispatcher().addTimer(
            int( checkPeriod * 1000000 ),
            new InactivityTimeoutChecker( *this, inactivityExceptionPeriod ),
            0, "ChannelInactivity" );
}
```

`InactivityTimeoutChecker` 是匿名命名空间内的辅助类(`channel.cpp:28-76`),每 `checkPeriod` 秒检查一次:

```cpp
// channel.cpp:53-60
virtual void handleTimeout( TimerHandle handle, void * pUser )
{
    if ((timestamp() - channel_.lastReceivedTime()) > inactivityExceptionPeriod_) {
        channel_.onChannelInactivityTimeout();
    }
}
```

`onChannelInactivityTimeout` 默认行为是 `destroy()`,但子类可重写(如 BaseApp 的 Proxy 通道会触发客户端断线检测)。

### 5.6 destroy 流程

`Channel::destroy` 是非虚的,但调用虚方法 `doDestroy`:

```cpp
// channel.cpp:217-237
void Channel::destroy()
{
    IF_NOT_MF_ASSERT_DEV( !isDestroyed_ ) { return; }
    inactivityTimerHandle_.cancel();
    this->doDestroy();
    isDestroyed_ = true;
    pNetworkInterface_->onChannelGone( this );
    if (this->pChannelListener()) {
        this->pChannelListener()->onChannelGone( *this );
    }
    this->decRef();  // 对应构造时的 incRef
}
```

注意 `decRef` 在最后调用——这对应构造函数中的 `incRef`(`channel.cpp:110`):

```cpp
// channel.cpp:88-111
Channel::Channel( NetworkInterface & networkInterface, const Address & addr ):
    // ...
    isDestroyed_( false ),
    // ...
{
    this->incRef();  // 对应 destroy 中的 decRef
}
```

这种设计确保 Channel 在 `destroy()` 调用后,只要还有 `ChannelPtr` 持有引用就不会真正析构,直到最后一个引用释放。

### 5.7 ChannelListener 监听器

`ChannelListener`(`channel_listener.hpp`)是观察 Channel 生命周期的回调接口:

```cpp
class ChannelListener
{
public:
    virtual ~ChannelListener() {}
    virtual void onChannelSend( Channel & channel ) {}
    virtual void onChannelGone( Channel & channel ) {}
};
```

应用层可继承它来监听 send 和销毁事件。例如 BaseApp 用它来监控外部 channel 的 sendWindow,超过阈值时触发客户端断线。

---

## 六、UDPChannel 可靠传输实现

### 6.1 UDPChannel 的设计目标

`UDPChannel`(`udp_channel.hpp:54`)是 Mercury 的核心,实现了一个面向连接的可靠 UDP 通道。它的设计目标:

- **可靠传输**:通过序列号、ACK、重传保证可靠消息不丢
- **有序交付**:同一 Channel 上的消息按发送顺序交付
- **多路复用**:索引通道允许同一对地址上多个独立通道
- **流控**:滑动窗口控制未确认包数量
- **高效**:重传只重传可靠消息,不可靠消息可丢弃

### 6.2 Traits:内部 vs 外部通道

`UDPChannel` 区分两种 Traits:

```cpp
// udp_channel.hpp:67-74
enum Traits
{
    INTERNAL = 0,  // 服务器到服务器:低延迟、高带宽、低丢失
    EXTERNAL = 1,  // 客户端到服务器:高延迟、低带宽、高丢失
};
```

二者差异:
- **INTERNAL**:带宽充足,只重传可靠消息;不可靠消息也重传(因为丢失很少)
- **EXTERNAL**:带宽稀缺,只重传可靠消息;不可靠消息丢弃就丢弃

构造函数中根据 Traits 设置初始 RTT:

```cpp
// udp_channel.cpp:100-101
roundTripTime_( (traits == INTERNAL) ?
    stampsPerSecond() / 10 : stampsPerSecond() ),
```

INTERNAL 通道初始 RTT 假设 100ms,EXTERNAL 假设 1s,反映不同网络环境的预期。

### 6.3 窗口大小

不同 Traits 的窗口大小:

```cpp
// udp_channel.cpp:27-29
const int EXTERNAL_CHANNEL_SIZE = 256;
const int INTERNAL_CHANNEL_SIZE = 4096;
const int INDEXED_CHANNEL_SIZE = 512;
```

构造函数中:

```cpp
// udp_channel.cpp:92-94
windowSize_( (traits != INTERNAL)    ? EXTERNAL_CHANNEL_SIZE :
             (id == CHANNEL_ID_NULL) ? INTERNAL_CHANNEL_SIZE :
                                       INDEXED_CHANNEL_SIZE ),
```

- **EXTERNAL**:256(客户端场景,流量小)
- **INTERNAL 普通**:4096(服务器间,流量大)
- **INTERNAL 索引**:512(实体级通道,数量多)

最大 overflow 包数:

```cpp
// udp_channel.cpp:34-38
uint UDPChannel::s_maxOverflowPackets_[] =
    { 1024, // External channel.
      8192, // Internal channel
      4096  // Indexed channel (ie: entity channel).
    };
```

最大窗口 = `windowSize + maxOverflowPackets`:

```cpp
// udp_channel.hpp:433-436
uint maxWindowSize() const
{
    return windowSize_ + this->getMaxOverflowPackets();
}
```

### 6.4 序列号分配

序列号类型和常量(`misc.hpp:25-47`):

```cpp
// misc.hpp:25-47
typedef uint32 SeqNum;
const SeqNum SEQ_SIZE = 0x10000000U;   // 2^28
const SeqNum SEQ_MASK = SEQ_SIZE-1;     // 0x0FFFFFFF
const SeqNum SEQ_NULL = SEQ_SIZE;       // 0x10000000,无效值

inline SeqNum seqMask( SeqNum x ) { return x & SEQ_MASK; }

inline bool seqLessThan( SeqNum a, SeqNum b )
{
    return seqMask( a - b ) > SEQ_SIZE/2;
}
```

**关键设计:序列号只有 28 位**,而不是 32 位。这是因为 `seqLessThan` 用了"差值高位为 1 即认为小于"的经典回绕算法:

```
seqLessThan(a, b) := (a - b) mod 2^28 > 2^27
```

28 位让"一半"恰好是 2^27,差值大于 2^27 说明 a 在 b 之前(已回绕)。这种算法避免了显式处理回绕,但要求**任何时刻未确认的序列号范围不能超过 2^27 = 134M**,这对游戏场景绰绰有余。

`SeqNumAllocator` 是序列号分配器:

```cpp
// misc.hpp:53-84
class SeqNumAllocator
{
public:
    SeqNumAllocator( SeqNum firstSeqNum ) : nextNum_( firstSeqNum ) {}
    SeqNum getNext()
    {
        SeqNum retVal = nextNum_;
        nextNum_ = seqMask( nextNum_ + 1 );  // 自动回绕
        return retVal;
    }
    operator SeqNum() const { return nextNum_; }
private:
    SeqNum nextNum_;
};
```

`UDPChannel` 持有两个序列号:

```cpp
// udp_channel.hpp:386-390
SeqNum smallOutSeqAt_;     // 不包括 overflow 的下一 seq
SeqNumAllocator largeOutSeqAt_;  // 包括 overflow 的下一 seq
```

`smallOutSeqAt_` 是发送窗口可推进的"水线",`largeOutSeqAt_` 是已分配的序列号(包括 overflow 中尚未进入窗口的)。

### 6.5 发送窗口与 UnackedPacket

发送窗口由 `CircularArray<UnackedPacket*> unackedPackets_` 实现:

```cpp
// udp_channel.hpp:415
CircularArray< UnackedPacket * > unackedPackets_;
```

`CircularArray`(`circular_array.hpp:18-77`)是模板环形数组,**要求 size 是 2 的幂**:

```cpp
// circular_array.hpp:18-77
template <class T> class CircularArray
{
public:
    CircularArray( uint size ) : data_( new T[size] ), mask_( size-1 )
    {
        memset( data_, 0, sizeof(T) * this->size() );
    }
    uint size() const { return mask_+1; }
    const T & operator[]( uint n ) const { return data_[n&mask]; }
    T & operator[]( uint n ) { return data_[n&mask]; }
    void inflateToAtLeast( size_t newSize ) { /* 双倍扩容 */ }
    void doubleSize( uint32 startIndex ) { /* 复制旧数据到新数组 */ }
private:
    T * data_;
    uint mask_;
};
```

`mask_ = size - 1` 让 `n & mask` 自动模 size,这是经典的 2 的幂优化。

`UnackedPacket`(`unacked_packet.hpp:16-43`):

```cpp
// unacked_packet.hpp:16-43
class UDPChannel::UnackedPacket
{
public:
    UnackedPacket( Packet * pPacket = NULL );
    SeqNum seq() const { return pPacket_->seq(); }
    PacketPtr pPacket_;             // 包本身
    SeqNum lastSentAtOutSeq_;        // 上次发送时的 outSeq
    uint64 lastSentTime_;            // 上次发送时间戳
    bool wasResent_;                 // 是否重传过(影响 RTT 计算)
    ReliableVector reliableOrders_;  // 可靠消息分段记录
    // ...
};
```

`reliableOrders_` 记录这个 Packet 中可靠消息的偏移,用于 piggyback 时提取可靠部分。

### 6.6 addResendTimer:加入发送窗口

`addResendTimer`(`udp_channel.cpp:817-890`)在每次发送可靠包后调用,把包加入未确认队列:

```cpp
// udp_channel.cpp:817-890
bool UDPChannel::addResendTimer( SeqNum seq, Packet * p,
        const ReliableOrder * roBeg, const ReliableOrder * roEnd )
{
    MF_ASSERT( (oldestUnackedSeq_ == SEQ_NULL) ||
            unackedPackets_[ oldestUnackedSeq_ ] );
    MF_ASSERT( seq == p->seq() );

    UnackedPacket * pUnackedPacket = new UnackedPacket( p );

    // 如果没有未确认包,记录这个为最旧的
    if (oldestUnackedSeq_ == SEQ_NULL) {
        oldestUnackedSeq_ = seq;
    }

    pUnackedPacket->lastSentAtOutSeq_ = seq;
    uint64 now = timestamp();
    pUnackedPacket->lastSentTime_ = now;
    lastReliableSendTime_ = now;
    pUnackedPacket->wasResent_ = false;

    if (roBeg != roEnd) {
        pUnackedPacket->reliableOrders_.assign( roBeg, roEnd );
    }

    // 必要时扩容
    if (seqMask( seq - oldestUnackedSeq_ + 1 ) > unackedPackets_.size()) {
        unackedPackets_.doubleSize( oldestUnackedSeq_ );
    }
    MF_ASSERT( unackedPackets_[ seq ] == NULL );
    unackedPackets_[ seq ] = pUnackedPacket;

    // 检查窗口是否满
    if (seqMask( largeOutSeqAt_ - oldestUnackedSeq_ ) >= windowSize_) {
        // 窗口满,但偶发地还是发一点,避免饿死
        UnackedPacket * pPrevUnackedPacket =
            unackedPackets_[ seqMask( smallOutSeqAt_ - 1 ) ];
        if ((pPrevUnackedPacket == NULL) ||
            (now - pPrevUnackedPacket->lastSentTime_ > minInactivityResendDelay_)) {
            this->sendUnacked( *unackedPackets_[ smallOutSeqAt_ ] );
            smallOutSeqAt_ = seqMask( smallOutSeqAt_ + 1 );
        }
        this->checkOverflowErrors();
        return false;  // 不应该立即发送
    } else {
        smallOutSeqAt_ = largeOutSeqAt_;
        return true;  // 可以立即发送
    }
}
```

关键点:
- **窗口满**:`seqMask(largeOutSeqAt_ - oldestUnackedSeq_) >= windowSize_`,此时新包进入 overflow 区
- **避免饿死**:即使窗口满,如果上次发送超过 `minInactivityResendDelay_`,也会强制发一个包
- **overflow 检测**:后续 `checkOverflowErrors` 会警告或断言

### 6.7 handleAck:处理单个 ACK

`handleAck`(`udp_channel.cpp:964-1048`)处理收到的单个 ACK:

```cpp
// udp_channel.cpp:964-1048
bool UDPChannel::handleAck( SeqNum seq )
{
    MF_ASSERT( (oldestUnackedSeq_ == SEQ_NULL) ||
            unackedPackets_[ oldestUnackedSeq_ ] );

    // 校验序列号
    if (seqMask( seq ) != seq) {
        ERROR_MSG( "..." );
        return false;
    }
    if (!this->isInSentWindow( seq )) return true;

    UnackedPacket * pUnackedPacket = unackedPackets_[ seq ];
    if (pUnackedPacket == NULL) return true;

    // 更新 RTT 估计(只在未重传时)
    if (!pUnackedPacket->wasResent_) {
        const uint64 RTT_AVERAGE_DENOM = 10;
        roundTripTime_ = ((roundTripTime_ * (RTT_AVERAGE_DENOM - 1)) +
            (timestamp() - pUnackedPacket->lastSentTime_)) / RTT_AVERAGE_DENOM;
    }

    // 清除 critical 状态
    if (unackedCriticalSeq_ == seq) unackedCriticalSeq_ = SEQ_NULL;

    // 推进 oldestUnackedSeq_
    if (seq == oldestUnackedSeq_) {
        oldestUnackedSeq_ = SEQ_NULL;
        for (uint i = seqMask( seq+1);
                i != largeOutSeqAt_;
                i = seqMask( i+1 )) {
            if (unackedPackets_[ i ]) {
                oldestUnackedSeq_ = i;
                break;
            }
        }
    }

    // 更新最高 ACK
    if (seqLessThan( highestAck_, seq )) highestAck_ = seq;

    // 释放 unacked
    bw_safe_delete( pUnackedPacket );
    unackedPackets_[ seq ] = NULL;

    // 推进发送窗口
    while (seqMask(smallOutSeqAt_ - oldestUnackedSeq_) < windowSize_ &&
           unackedPackets_[ smallOutSeqAt_ ]) {
        this->sendUnacked( *unackedPackets_[ smallOutSeqAt_ ] );
        smallOutSeqAt_ = seqMask( smallOutSeqAt_ + 1 );
    }
    return true;
}
```

**RTT 估计算法**(`udp_channel.cpp:996-1002`):

```cpp
const uint64 RTT_AVERAGE_DENOM = 10;
roundTripTime_ = ((roundTripTime_ * (RTT_AVERAGE_DENOM - 1)) +
    (timestamp() - pUnackedPacket->lastSentTime_)) / RTT_AVERAGE_DENOM;
```

这是一个**指数加权移动平均(EWMA)**:`RTT_new = 0.9 * RTT_old + 0.1 * sample`。重要细节:**只有未重传的包才更新 RTT**。这是 Karn 算法——重传过的包无法确定 ACK 是对原包还是对重传包的,索性不计入。

### 6.8 handleCumulativeAck:处理累积 ACK

`handleCumulativeAck`(`udp_channel.cpp:899-954`)处理"到此 seq 之前的所有包都已收到":

```cpp
// udp_channel.cpp:899-954
bool UDPChannel::handleCumulativeAck( SeqNum endSeq )
{
    // 校验
    if (seqMask( endSeq ) != endSeq) {
        ERROR_MSG( "..." );
        return false;
    }
    if (!this->hasUnackedPackets()) return true;

    // 校验:不能 ACK 未发送的包
    if (seqLessThan( smallOutSeqAt_, endSeq )) {
        if (this->isExternal()) {
            ERROR_MSG( "..." );
        } else {
            CRITICAL_MSG( "..." );
        }
        return false;
    }

    SeqNum seq = oldestUnackedSeq_;
    // 注意:不包含 endSeq
    while (seqLessThan( seq, endSeq )) {
        this->handleAck( seq );
        seq = seqMask( seq + 1 );
    }
    return true;
}
```

累积 ACK 是一种带宽优化:**一个 ACK 值可以确认多个包**。Mercury 既支持单个 ACK(`FLAG_HAS_ACKS` + 多个 SeqNum)也支持累积 ACK(`FLAG_HAS_CUMULATIVE_ACK` + 一个 SeqNum)。

### 6.9 checkResendTimers:重传检查

`checkResendTimers`(`udp_channel.cpp:1055-1148`)在每次发送 bundle 前调用,检查是否需要重传:

```cpp
// udp_channel.cpp:1055-1148
void UDPChannel::checkResendTimers( UDPBundle & bundle )
{
    if (oldestUnackedSeq_ == SEQ_NULL) return;  // 没有 unacked
    if (hasRemoteFailed_) return;               // 远端已失败

    uint64 now = timestamp();
    uint64 resendPeriod = std::max( roundTripTime_*2, minInactivityResendDelay_ );
    uint64 lastReliableSendTime = this->lastReliableSendOrResendTime();

    const bool isIrregular = !this->isRemoteRegular();
    const SeqNum endSeq = isIrregular ? smallOutSeqAt_ : highestAck_;
    const bool isDebugVerbose = this->networkInterface().isDebugVerbose();

    int numResends = 0;
    const int MAX_RESENDS = windowSize_/8;  // 限制单次重传量

    for (SeqNum seq = oldestUnackedSeq_;
        seqLessThan( seq, endSeq ) && numResends < MAX_RESENDS;
        seq = seqMask( seq + 1 )) {
        UnackedPacket * pUnacked = unackedPackets_[ seq ];
        if (pUnacked != NULL) {
            // 满足任一条件则重传:
            //   1) 已有更新的 ACK(说明这个包丢了)
            //   2) 不 regular 且超过 resendPeriod
            const bool hasNewerAck =
                seqLessThan( pUnacked->lastSentAtOutSeq_, highestAck_);
            const bool shouldResend = hasNewerAck ||
                (isIrregular && (now - pUnacked->lastSentTime_ > resendPeriod));
            if (shouldResend) {
                bool piggybacked = this->resend( seq, bundle );
                ++numResends;
                // ... debug 输出 ...
            }
        }
    }
}
```

**两种重传触发条件**:
1. **NACK 风格**(`hasNewerAck`):收到了更后面包的 ACK,说明这个包丢了——这是 fast retransmit 思想
2. **超时风格**(`isIrregular && expired`):非 regular 通道(不常发送)的包超时

`resendPeriod = max(RTT * 2, minInactivityResendDelay_)`,至少是 RTT 的两倍,且不低于 `minInactivityResendDelay_`(默认 1 秒)。

### 6.10 resend:实际重传

`resend`(`udp_channel.cpp:1156-1181`)选择最佳重传方式:

```cpp
// udp_channel.cpp:1156-1181
bool UDPChannel::resend( SeqNum seq, UDPBundle & bundle )
{
    ++numPacketsResent_;
    UnackedPacket & unacked = *unackedPackets_[ seq ];

    // 优先 piggyback
    if (this->isExternal() &&
        !unacked.pPacket_->hasFlags( Packet::FLAG_IS_FRAGMENT ) &&
        (unackedPackets_[ smallOutSeqAt_ ] == NULL)) {  // 不会溢出
        if (bundle.piggyback(
                seq, unacked.reliableOrders_, unacked.pPacket_.get() )) {
            unacked.wasResent_ = true;
            this->handleAck( seq );  // piggyback 后视同 ACK
            return true;
        }
    }

    // 否则直接重发
    this->sendUnacked( unacked );
    return false;
}
```

`sendUnacked`(`udp_channel.cpp:1187-1200`)直接重发整个包:

```cpp
// udp_channel.cpp:1187-1200
void UDPChannel::sendUnacked( UnackedPacket & unacked )
{
    unacked.pPacket_->updateChannelVersion( version_, id_ );
    pNetworkInterface_->sendPacket( addr_, unacked.pPacket_.get(), this,
        /* isResend: */ true );
    unacked.lastSentAtOutSeq_ = smallOutSeqAt_;
    unacked.wasResent_ = true;
    uint64 now = timestamp();
    unacked.lastSentTime_ = now;
    lastReliableResendTime_ = now;
}
```

### 6.11 Piggyback 机制

`UDPBundle::piggyback`(`udp_bundle.cpp`)是 Mercury 的特色实现:**把丢失包的可靠消息"搭车"到下一个 outgoing bundle**。

接收端的 `Packet::processPiggybackPackets`(`packet.cpp:327-382`)负责剥离 piggyback。piggyback 的本质是:

1. 发送方重传包 P(seq=5),发现 outgoing bundle 还在手上
2. 从 P 中提取所有可靠消息段(`reliableOrders_`)
3. 把这些消息段追加到 outgoing bundle 的 footer 区域,作为 piggyback 子包
4. 在接收端,先处理 piggyback 子包(按 seq 顺序处理),再处理主包
5. 这样即使原包 P 永远没收到,可靠消息也通过 piggyback 到达

好处:节省一次独立 UDP 发送,把重传开销分摊到正常流量。

### 6.12 接收窗口:addToReceiveWindow

`addToReceiveWindow`(`udp_channel.cpp:1208-1388`)是接收端的核心:

```cpp
// udp_channel.cpp:1208-1298 (节选)
UDPChannel::AddToReceiveWindowResult UDPChannel::addToReceiveWindow(
        Packet * p, const Address & srcAddr, PacketReceiverStats & stats )
{
    const SeqNum seq = p->seq();
    // ... 校验 seq、地址、自动切换 ...

    // 加入 acksToSend_ 集合
    if (!p->isPiggyback()) {
        acksToSend_.insert( seq );
    }

    // 如果超过 pushUnsentAcksThreshold_,立即发送
    if (pushUnsentAcksThreshold_ &&
        (acksToSend_.size() >= pushUnsentAcksThreshold_)) {
        this->send();
    }

    // 好情况:正好是期望的下一个 seq
    if (seq == inSeqAt_) {
        inSeqAt_ = seqMask( inSeqAt_ + 1 );
        // 尝试连接后续已缓存的包
        Packet * pPrev = p;
        Packet * pBufferedPacket = bufferedReceives_[ inSeqAt_ ].get();
        while (pBufferedPacket != NULL) {
            pPrev->chain( pBufferedPacket );
            bufferedReceives_[ inSeqAt_ ] = NULL;
            --numBufferedReceives_;
            pPrev = pBufferedPacket;
            inSeqAt_ = seqMask( inSeqAt_ + 1 );
            pBufferedPacket = bufferedReceives_[ inSeqAt_ ].get();
        }
        return PACKET_IS_NEXT_IN_WINDOW;
    }
    // ... 处理乱序、重复、超出窗口 ...
}
```

接收窗口的核心字段:

```cpp
// udp_channel.hpp:441-445
SeqNum inSeqAt_;                         // 期望的下一个 seq
CircularArray< PacketPtr > bufferedReceives_;  // 缓存的乱序包
uint32 numBufferedReceives_;
```

`inSeqAt_` 是接收窗口的"水线",收到 `inSeqAt_` 的包就推进,并尝试连接后续已缓存的包。`bufferedReceives_` 也是 `CircularArray`,按 seq 直接索引。

返回值是枚举(`udp_channel.hpp:161-168`):

```cpp
// udp_channel.hpp:161-168
enum AddToReceiveWindowResult
{
    PACKET_IS_NEXT_IN_WINDOW,    // 正好是下一个,可立即处理
    PACKET_IS_BUFFERED_IN_WINDOW,// 缓存到 buffer 中
    PACKET_IS_DUPLICATE,         // 重复包,丢弃
    PACKET_IS_OUT_OF_WINDOW,     // 超出窗口,丢弃
    PACKET_IS_CORRUPT,           // 损坏
};
```

### 6.13 重复包检测

```cpp
// udp_channel.cpp:1300-1313
if (seqLessThan( seq, inSeqAt_ )) {
    if (isDebugVerbose) {
        DEBUG_MSG( "UDPChannel::addToReceiveWindow( %s ): "
                "Discarding already-seen packet #%u below inSeqAt #%u\n",
            this->c_str(), seq, inSeqAt_ );
    }
    stats.incDuplicatePackets();
    return PACKET_IS_DUPLICATE;
}
```

`seqLessThan(seq, inSeqAt_)` 表示 seq 在 inSeqAt 之前(已处理过),直接丢弃并计数。

### 6.14 乱序包缓存

```cpp
// udp_channel.cpp:1315-1388
uint32 requiredWindowSize = seqMask(seq - inSeqAt_);

// 检查是否在窗口内
if ((requiredWindowSize > 2 * bufferedReceives_.size()) ||
        (requiredWindowSize > this->maxWindowSize())) {
    WARNING_MSG( "UDPChannel::addToReceiveWindow( %s ): "
            "Sequence number #%u is way out of window #%u!\n",
        this->c_str(), seq, inSeqAt_ );
    return PACKET_IS_OUT_OF_WINDOW;
} else if (requiredWindowSize > bufferedReceives_.size()) {
    // 双倍扩容
    bufferedReceives_.doubleSize( inSeqAt_ + 1 );
}

// 缓存到对应位置
PacketPtr & rpBufferedPacket = bufferedReceives_[ seq ];
if (rpBufferedPacket != NULL) {
    if (rpBufferedPacket->seq() == seq) {
        // 重复
        stats.incDuplicatePackets();
    } else {
        CRITICAL_MSG( "..." );
    }
} else {
    rpBufferedPacket = p;
    ++numBufferedReceives_;
}
return PACKET_IS_BUFFERED_IN_WINDOW;
```

**两个边界检查**:
- 超过 2 倍 buffer 大小:严重越界
- 超过 maxWindowSize:逻辑上不可能,丢弃

否则缓存到 `bufferedReceives_[seq]`,等 `inSeqAt_` 推进到时自动连接。

### 6.15 索引通道

普通 Channel 通过 `Address` 区分,但当同一对地址需要多个独立通道时(如 cell-base 实体通信),就需要**索引通道**:

```cpp
// udp_channel.hpp:364-379
/// An indexed channel is basically a way of multiplexing multiple
/// channels between a pair of addresses.  Regular channels distinguish
/// traffic solely on the basis of address, so in situations where you need
/// multiple channels between a pair of addresses (i.e. channels between
/// base and cell entities) you use indexed channels to keep the streams
/// separate.
ChannelID id_;

/// Indexed channels have a 'version' number which basically tracks how
/// many times they have been offloaded.  This allows us to correctly
/// determine which incoming packets are out-of-date and also helps
/// identify the most up-to-date information about lost entities in a
/// restore situation.
ChannelVersion version_;
ChannelVersion creationVersion_;
```

`id_` 是 32 位整数,`version_` 用于 offload 后识别过期包。索引通道在包头携带 `FLAG_INDEXED_CHANNEL` + `ChannelID` + `ChannelVersion`。

### 6.16 Condemn(标记待删除)

`condemn`(`udp_channel.cpp:380-413`)是优雅关闭通道的方式:

```cpp
// udp_channel.cpp:380-413
void UDPChannel::condemn()
{
    if (this->isCondemned()) {
        WARNING_MSG( "UDPChannel::condemn( %s ): Already condemned.\n", this->c_str() );
        return;
    }

    // 先把待发数据发出去
    if (this->hasUnsentData()) {
        if (this->isEstablished()) {
            this->send();
        } else {
            WARNING_MSG( "UDPChannel::condemn( %s ): Unsent data was lost ...\n",
                this->c_str() );
        }
    }

    // 标记为非 regular
    this->isLocalRegular( false );
    this->isRemoteRegular( false );
    isCondemned_ = true;

    // 加入 CondemnedChannels,等所有包 ACK 后删除
    pNetworkInterface_->condemnedChannels().add( this );
}
```

注意 `condemn` 不直接销毁通道,而是加入 `CondemnedChannels`,等所有 unacked 包都被 ACK 后才真正销毁。这避免了"还有未确认包就销毁"的问题。

---

## 七、Bundle 消息序列化机制(特色实现)

### 7.1 Bundle 是什么

`Bundle`(`bundle.hpp:74`)是 Mercury 的消息序列化容器。一个 Bundle 可以包含**多个消息**和**多个请求**,在网络上作为一个逻辑单元传输。

```cpp
// bundle.hpp:74-175
class Bundle : public BinaryOStream
{
public:
    virtual void startMessage( const InterfaceElement & ie,
        ReliableType reliable = RELIABLE_DRIVER ) = 0;
    virtual void startRequest( const InterfaceElement & ie,
        ReplyMessageHandler * handler,
        void * arg = NULL,
        int timeout = DEFAULT_REQUEST_TIMEOUT,
        ReliableType reliable = RELIABLE_DRIVER ) = 0;
    virtual void startReply( ReplyID id,
        ReliableType reliable = RELIABLE_DRIVER ) = 0;
    // ...
    int numMessages() const { return numMessages_; }
protected:
    Bundle( Channel * pChannel = NULL );
    Channel * pChannel_;
    bool isFinalised_;
    uint numMessages_;
    typedef BW::vector< ReplyOrder > ReplyOrders;
    ReplyOrders replyOrders_;
};
```

Bundle 派生自 `BinaryOStream`,所以可以直接用 `<<` 操作符流式写入任意类型:

```cpp
bundle.startMessage( SomeInterface::someMethod );
bundle << int32Value;
bundle << stringValue;
bundle << vector3Value;
```

### 7.2 可靠等级

Bundle 支持四种可靠等级(`bundle.hpp:34-40`):

```cpp
// bundle.hpp:34-40
enum ReliableTypeEnum
{
    RELIABLE_NO = 0,         // 不可靠,丢了就丢了
    RELIABLE_DRIVER = 1,    // 可靠驱动,会驱动整个 bundle 可靠
    RELIABLE_PASSENGER = 2, // 可靠乘客,只有 DRIVER 在场才可靠
    RELIABLE_CRITICAL = 3   // 可靠关键,标记 bundle 为 critical
};
```

`ReliableType` 包装类(`bundle.hpp:46-61`):

```cpp
// bundle.hpp:46-61
class ReliableType
{
public:
    ReliableType( ReliableTypeEnum e ) : e_( e ) { }
    bool isReliable() const { return e_ != RELIABLE_NO; }
    bool isDriver() const { return e_ & RELIABLE_DRIVER; }  // 复用 0x1 位
    // ...
};
```

**关键设计:DRIVER 和 CRITICAL 共享 0x1 位**(`isDriver` 检测 0x1),所以两者都会"驱动"bundle 可靠。区别在于 CRITICAL 还会设置 `isCritical_`,影响 Channel 的 critical 标记。

### 7.3 默认请求超时

```cpp
// bundle.hpp:25
const int DEFAULT_REQUEST_TIMEOUT = 5000000;  // 5 秒(微秒)
```

5 秒是默认请求超时,可通过 `startRequest` 的 `timeout` 参数覆盖。

### 7.4 UDPBundle 实现

`UDPBundle`(`udp_bundle.hpp:42`)是 Bundle 的 UDP 实现:

```cpp
// udp_bundle.hpp:42-175
class UDPBundle : public Bundle
{
public:
    UDPBundle( uint8 spareSize = 0, UDPChannel * pChannel = NULL );
    UDPBundle( Packet * p );

    virtual void startMessage( const InterfaceElement & ie,
        ReliableType reliable = RELIABLE_DRIVER );
    virtual void startRequest( const InterfaceElement & ie,
        ReplyMessageHandler * handler, void * arg = NULL,
        int timeout = DEFAULT_REQUEST_TIMEOUT,
        ReliableType reliable = RELIABLE_DRIVER );
    virtual void startReply( ReplyID id,
        ReliableType reliable = RELIABLE_DRIVER );
    virtual void doFinalise();
    // ...
private:
    PacketPtr pFirstPacket_;     // 第一个包
    Packet * pCurrentPacket_;   // 当前包
    bool hasEndedMsgEarly_;
    bool reliableDriver_;       // 是否有 driver 消息
    uint8 extraSize_;           // 过滤器预留
    ReliableVector reliableOrders_;
    int reliableOrdersExtracted_;
    bool isCritical_;
    BundlePiggybacks piggybacks_;
    SeqNum ack_;                // 离通道 ACK
    // 当前消息状态
    InterfaceElement curIE_;
    int msgLen_;
    int msgExtra_;
    uint8 * msgBeg_;
    uint16 msgChunkOffset_;
    bool msgIsReliable_;
    bool msgIsRequest_;
    uint numReliableMessages_;
};
```

### 7.5 startMessage:开始消息

`startMessage`(`udp_bundle.cpp:229-244`):

```cpp
// udp_bundle.cpp:229-244
void UDPBundle::startMessage( const InterfaceElement & ie, ReliableType reliable )
{
    MF_ASSERT( !pCurrentPacket_->hasFlags( Packet::FLAG_HAS_PIGGYBACKS ) );
    MF_ASSERT( ie.name() );

    this->endMessage();                  // 结束上一个消息
    curIE_ = ie;
    msgIsReliable_ = reliable.isReliable();
    msgIsRequest_ = false;
    isCritical_ = (reliable == RELIABLE_CRITICAL);
    this->newMessage();                 // 开始新消息

    reliableDriver_ |= reliable.isDriver();
}
```

每次 startMessage 都先 endMessage 旧消息,再 newMessage 新消息。

### 7.6 newMessage:分配消息头

`newMessage`(`udp_bundle.cpp:754-788`):

```cpp
// udp_bundle.cpp:754-788
char * UDPBundle::newMessage( int extra )
{
    int headerLen = curIE_.headerSize();
    if (headerLen == -1) {
        CRITICAL_MSG( "Mercury::UDPBundle::newMessage: "
            "tried to add a message with an unknown length format %d\n",
            (int)curIE_.lengthStyle() );
    }

    ++numMessages_;
    if (msgIsReliable_) ++numReliableMessages_;

    // 预留头部 + extra 字节
    MessageID * pHeader = (MessageID *)this->qreserve( headerLen + extra );

    msgBeg_ = (uint8*)pHeader;
    msgChunkOffset_ = Packet::Offset( pCurrentPacket_->msgEndOffset() );

    // 写入消息 ID
    *(MessageID*)pHeader = curIE_.id();

    msgLen_ = 0;
    msgExtra_ = extra;

    return (char *)(pHeader + headerLen);  // 返回 extra 区域指针
}
```

`qreserve` 是关键函数,在当前 packet 不够时分配新 packet:

```cpp
// udp_bundle.ipp (内联)
INLINE void * UDPBundle::qreserve( int nBytes )
{
    // 如果当前 packet 放不下,用 sreserve 分配新 packet
    if (pCurrentPacket_->freeSpace() < nBytes) {
        return this->sreserve( nBytes );
    }
    void * writePosition = pCurrentPacket_->back();
    pCurrentPacket_->grow( nBytes );
    return writePosition;
}
```

`sreserve`(`udp_bundle.cpp:352-362`)分配新 packet:

```cpp
// udp_bundle.cpp:352-362
void * UDPBundle::sreserve( int nBytes )
{
    this->endPacket( /* isExtending */ true );  // 结束当前 packet
    this->startPacket( new Packet() );          // 新建并链接

    void * writePosition = pCurrentPacket_->back();
    pCurrentPacket_->grow( nBytes );
    MF_ASSERT( pCurrentPacket_->freeSpace() >= 0 );
    return writePosition;
}
```

### 7.7 endMessage:结束消息

`endMessage`(`udp_bundle.cpp:711-744`):

```cpp
// udp_bundle.cpp:711-744
void UDPBundle::endMessage( bool isEarlyCall /* = false */ )
{
    if (msgBeg_ == NULL) {  // 没有正在写的消息
        MF_ASSERT( pCurrentPacket_->msgEndOffset() == Packet::HEADER_SIZE ||
            hasEndedMsgEarly_ );
        return;
    }

    // 累计消息长度
    msgLen_ += pCurrentPacket_->msgEndOffset() - msgChunkOffset_;

    // 写入长度字段到消息头
    curIE_.compressLength( msgBeg_, msgLen_, this, msgIsRequest_ );

    // 如果是可靠消息,记录 ReliableOrder
    if (msgIsReliable_) {
        if (this->isOnExternalChannel()) {
            this->addReliableOrder();
        }
        msgIsReliable_ = false;
    }

    msgChunkOffset_ = Packet::Offset( pCurrentPacket_->msgEndOffset() );
    msgBeg_ = NULL;
    msgIsRequest_ = false;
    hasEndedMsgEarly_ = isEarlyCall;
}
```

`compressLength` 是 InterfaceElement 的方法,根据 lengthStyle 把 msgLen_ 编码到消息头。

### 7.8 startRequest:开始请求

`startRequest`(`udp_bundle.cpp:259-308`)比 startMessage 复杂,因为要预留 reply ID 和 next request link:

```cpp
// udp_bundle.cpp:259-308
void UDPBundle::startRequest( const InterfaceElement & ie,
    ReplyMessageHandler * handler, void * arg, int timeout, ReliableType reliable )
{
    MF_ASSERT( handler );

    if (pChannel_ && timeout != DEFAULT_REQUEST_TIMEOUT) {
        WARNING_MSG( "UDPBundle::startRequest(%s): "
                "Non-default timeout set on a channel bundle\n",
            pChannel_->c_str() );
    }

    this->endMessage();
    curIE_ = ie;
    msgIsReliable_ = reliable.isReliable();
    msgIsRequest_ = true;
    isCritical_ = (reliable == RELIABLE_CRITICAL);

    // 预留 ReplyID + Offset
    ReplyID * pReplyID = (ReplyID *)this->newMessage(
        sizeof( ReplyID ) + sizeof( Packet::Offset ) );

    Packet::Offset messageStart =
        Packet::Offset( pCurrentPacket_->msgEndOffset() -
            (ie.headerSize() +
                sizeof( ReplyID ) +
                sizeof( Packet::Offset )));
    Packet::Offset nextRequestLink =
            Packet::Offset( pCurrentPacket_->msgEndOffset() -
                sizeof( Packet::Offset ) );

    // 在 packet 中注册 request 链
    pCurrentPacket_->addRequest( messageStart, nextRequestLink );

    // 创建 ReplyOrder
    ReplyOrder ro = {handler, arg, timeout, pReplyID};
    replyOrders_.push_back(ro);

    pCurrentPacket_->enableFlags( Packet::FLAG_HAS_REQUESTS );
    reliableDriver_ |= reliable.isDriver();
}
```

**请求链表机制**:`Packet` 中所有 request 通过 `nextRequestLink` 形成链表,接收端按链遍历处理。`addRequest`(`packet.cpp:107-123`)维护这个链表:

```cpp
// packet.cpp:107-123
void Packet::addRequest( Offset messageStart, Offset nextRequestLink )
{
    if (firstRequestOffset_ == 0) {
        firstRequestOffset_ = messageStart;
    } else {
        *pLastRequestOffset_ = BW_HTONS( messageStart );
    }
    pLastRequestOffset_ = (Offset*)(data_ + nextRequestLink);
    *pLastRequestOffset_ = 0;  // 标记为最后一个
}
```

### 7.9 startReply:开始回复

`startReply`(`udp_bundle.cpp:318-331`):

```cpp
// udp_bundle.cpp:318-331
void UDPBundle::startReply( ReplyID id, ReliableType reliable )
{
    this->endMessage();
    curIE_ = InterfaceElement::REPLY;  // 特殊的 REPLY 接口元素
    msgIsReliable_ = reliable.isReliable();
    msgIsRequest_ = false;
    isCritical_ = (reliable == RELIABLE_CRITICAL);
    this->newMessage();
    reliableDriver_ |= reliable.isDriver();

    // 流式写入 reply ID
    (*this) << id;
}
```

`InterfaceElement::REPLY` 是预定义的常量,标识"这是一个回复消息"。接收端看到这个 ID 就知道要把消息路由到 RequestManager。

### 7.10 doFinalise:最终化

`doFinalise`(`udp_bundle.cpp:368-387`):

```cpp
// udp_bundle.cpp:368-387
void UDPBundle::doFinalise()
{
    // 校验:不能有"游离"数据(没有消息头)
    if (msgBeg_ == NULL && pCurrentPacket_->msgEndOffset() != msgChunkOffset_) {
        CRITICAL_MSG( "UDPBundle::finalise: "
            "data not part of message found at end of bundle!\n");
    }
    this->endMessage();
    this->endPacket( /* isExtending */ false );

    // 如果没有 driver,所有 passenger 都没意义,清除
    if (!reliableDriver_ && this->isOnExternalChannel()) {
        reliableOrders_.clear();
    }
}
```

**关键设计:passenger 必须有 driver 才生效**。在 EXTERNAL 通道上,如果没有 driver 消息,所有 reliable passenger 都会被清除——因为 passenger 只在"有 driver 触发整个 bundle 可靠"时才有意义。

### 7.11 preparePackets:准备发送

`preparePackets`(`udp_bundle.cpp:398-614`)是发送前的最后一道工序,负责写所有 footer:

```cpp
// udp_bundle.cpp:398-614 (节选)
Packet * UDPBundle::preparePackets( UDPChannel * pChannel,
        SeqNumAllocator & seqNumAllocator,
        SendingStats & sendingStats,
        bool shouldUseChecksums )
{
    Packet * pFirstOverflowPacket = NULL;
    int numPackets = this->numDataUnits();
    SeqNum firstSeq = 0;
    SeqNum lastSeq = 0;

    // 遍历每个 packet,写 footer
    for (Packet * pPacket = this->pFirstPacket();
            pPacket;
            pPacket = pPacket->next()) {
        // 1. 校验和
        if (shouldUseChecksums) {
            pPacket->reserveFooter( sizeof( Packet::Checksum ) );
            pPacket->enableFlags( Packet::FLAG_HAS_CHECKSUM );
        }

        // 2. 写 bundle 标志
        this->writeFlags( pPacket );

        // 3. 写 channel 标志
        if (pChannel) pChannel->writeFlags( pPacket );

        // 4. 序列号
        if ((pChannel && pChannel->isExternal()) ||
            pPacket->hasFlags( Packet::FLAG_IS_RELIABLE ) ||
            pPacket->hasFlags( Packet::FLAG_IS_FRAGMENT )) {
            pPacket->reserveFooter( sizeof( SeqNum ) );
            pPacket->enableFlags( Packet::FLAG_HAS_SEQUENCE_NUMBER );
        }

        // 5. 把 msgEndOffset 推进到 footer 末尾
        const int msgEndOffset = pPacket->msgEndOffset();
        pPacket->grow( pPacket->footerSize() );

        // 6. 写 checksum(占位 0)
        Packet::Checksum * pChecksum = NULL;
        if (pPacket->hasFlags( Packet::FLAG_HAS_CHECKSUM )) {
            pPacket->packFooter( Packet::Checksum( 0 ) );
            pChecksum = (Packet::Checksum*)pPacket->back();
        }

        // 7. 写 piggybacks(只最后一个 packet)
        if (pPacket->hasFlags( Packet::FLAG_HAS_PIGGYBACKS )) {
            MF_ASSERT( pPacket->next() == NULL );
            // ... 详见 udp_bundle.cpp:461-535 ...
        }

        // 8. 写分片信息
        if (this->hasMultipleDataUnits()) {
            // ... 写 fragBegin, fragEnd ...
        }

        // 9. 写序列号
        if (pPacket->hasFlags( Packet::FLAG_HAS_SEQUENCE_NUMBER )) {
            SeqNum seq = seqNumAllocator.getNext();
            pPacket->packFooter( seq );
            pPacket->seq( seq );
            if (numPackets > 1) {
                if (pPacket == this->pFirstPacket()) firstSeq = seq;
                lastSeq = seq;
            }
            // 调用 channel 的 addResendTimer
            if (pChannel) {
                if (pPacket->hasFlags( Packet::FLAG_IS_RELIABLE )) {
                    // 取出 reliable orders
                    const ReliableOrder * roBeg, * roEnd;
                    this->reliableOrders( pPacket, roBeg, roEnd );
                    // 加入重传窗口
                    if (!pChannel->addResendTimer( seq, pPacket, roBeg, roEnd )) {
                        if (pFirstOverflowPacket == NULL) pFirstOverflowPacket = pPacket;
                    }
                }
            }
        }

        // 10. 计算并写 checksum
        if (pChecksum) pPacket->writeChecksum( pChecksum );
    }
    return pFirstOverflowPacket;
}
```

10 步流程,从最里层 footer 到最外层依次写入。注意 footer 写入顺序与剥离顺序相反——发送时按 [checksum, seq, frag, piggyback, ...] 写入,接收时从外到内剥离。

### 7.12 writeFlags:写 Packet 标志

`writeFlags`(`udp_bundle.cpp:620-648`)设置 Packet 的标志位并预留 footer 空间:

```cpp
// udp_bundle.cpp:620-648
void UDPBundle::writeFlags( Packet * p ) const
{
    if (reliableOrders_.size() || msgIsReliable_ || numReliableMessages_ > 0) {
        p->enableFlags( Packet::FLAG_IS_RELIABLE );
    }
    if (p->hasFlags( Packet::FLAG_HAS_REQUESTS )) {
        p->reserveFooter( sizeof( Packet::Offset ) );
    }
    if (this->hasMultipleDataUnits()) {
        p->enableFlags( Packet::FLAG_IS_FRAGMENT );
        p->reserveFooter( sizeof( SeqNum ) * 2 );
    }
    if (ack_ != SEQ_NULL) {
        p->enableFlags( Packet::FLAG_HAS_ACKS );
        p->reserveFooter( sizeof( Packet::AckCount ) + sizeof( SeqNum ) );
    }
}
```

### 7.13 ReliableOrder 记录

`addReliableOrder`(`udp_bundle.cpp:794-`)记录一条可靠消息的偏移:

```cpp
// udp_bundle.cpp:794-
void UDPBundle::addReliableOrder()
{
    MF_ASSERT( this->isOnExternalChannel() );
    uint8 * begInCur = (uint8*)pCurrentPacket_->data() + msgChunkOffset_;
    uint8 * begInCurWithHeader = begInCur - msgExtra_ - curIE_.headerSize();
    // ... 构造 ReliableOrder,记录 [segBegin, segLength, segPartOfRequest] ...
}
```

`ReliableOrder`(`reliable_order.hpp:24-30`):

```cpp
// reliable_order.hpp:24-30
class ReliableOrder
{
public:
    uint8 * segBegin;            // 段起始
    uint16  segLength;           // 段长度
    uint16  segPartOfRequest;    // 是否是请求的一部分
};
```

这些记录用于 piggyback:重传时按 ReliableOrder 提取可靠消息段,而不是整个 packet。

### 7.14 流式写入(<< 操作符)

Bundle 派生自 `BinaryOStream`,所以可以用 `<<` 写入任意支持流式操作符的类型:

```cpp
bundle.startMessage( SomeInterface::method );
bundle << entityId;
bundle << position;
bundle << direction;
```

`BinaryOStream` 的 `<<` 通过模板实现,会自动调用类型的 `operator<<` 重载。BigWorld 为常见类型(int32, float, Vector3, string)都提供了重载。

### 7.15 sendMessage/sendRequest 模板快捷方法

`Bundle` 提供了模板方法简化消息发送:

```cpp
// bundle.hpp:126-144
template<typename ArgsType>
void sendMessage( const ArgsType & args,
    ReliableType reliable = RELIABLE_DRIVER )
{
    this->startMessage( ArgsType::interfaceElement(), reliable );
    static_cast<BinaryOStream&>(*this) << args;
}

template<typename ArgsType>
void sendRequest( const ArgsType & args,
    ReplyMessageHandler * handler,
    void * arg = NULL,
    int timeout = DEFAULT_REQUEST_TIMEOUT,
    ReliableType reliable = RELIABLE_DRIVER )
{
    this->startRequest( ArgsType::interfaceElement(),
        handler, arg, timeout, reliable );
    static_cast<BinaryOStream&>(*this) << args;
}
```

调用方可以这样使用:

```cpp
SomeInterface::someMethodArgs args = { ... };
channel.bundle().sendMessage( args );
```

`ArgsType::interfaceElement()` 是 `MERCURY_STRUCT_GOODIES` 宏自动生成的静态方法,返回对应的 `InterfaceElement` 引用。

---

## 八、可靠 UDP 算法详解

### 8.1 序列号机制详解

Mercury 的序列号是 28 位(`misc.hpp:25-29`):

```cpp
typedef uint32 SeqNum;
const SeqNum SEQ_SIZE = 0x10000000U;   // 2^28 = 268,435,456
const SeqNum SEQ_MASK = SEQ_SIZE-1;    // 0x0FFFFFFF
const SeqNum SEQ_NULL = SEQ_SIZE;      // 0x10000000,无效值
```

#### 8.1.1 为什么是 28 位

TCP 序列号是 32 位,Mercury 选择 28 位的原因可能是:

1. **节省 wire 字节**:28 位 = 3.5 字节,实际存储用 4 字节 uint32_t。但 Mercury 还在某些 footer 中用了更紧凑的格式。
2. **简化回绕判断**:`seqLessThan(a, b) = (a - b) mod 2^28 > 2^27`,28 位让"一半"恰好是 2^27,容易识别。
3. **预留标志位**:理论上 32 位中的高 4 位可用于其他用途,但代码中没看到这种用法。

#### 8.1.2 回绕处理

`seqLessThan` 是回绕安全的小于比较:

```cpp
// misc.hpp:44-47
inline bool seqLessThan( SeqNum a, SeqNum b )
{
    return seqMask( a - b ) > SEQ_SIZE/2;
}
```

数学含义:`a - b mod 2^28` 如果大于 `2^27`(一半),说明 `a` 在 `b` 之前(已回绕)。这等价于 `signed_diff(a - b) < 0`,但避免了显式处理有符号。

`seqMask(x)` 把任何 32 位值截断到 28 位:

```cpp
// misc.hpp:34-37
inline SeqNum seqMask( SeqNum x )
{
    return x & SEQ_MASK;
}
```

#### 8.1.3 序列号分配

`SeqNumAllocator`(`misc.hpp:53-84`)分配连续序列号:

```cpp
class SeqNumAllocator
{
public:
    SeqNumAllocator( SeqNum firstSeqNum ) : nextNum_( firstSeqNum ) {}
    SeqNum getNext()
    {
        SeqNum retVal = nextNum_;
        nextNum_ = seqMask( nextNum_ + 1 );  // 自动回绕
        return retVal;
    }
    operator SeqNum() const { return nextNum_; }
private:
    SeqNum nextNum_;
};
```

`getNext` 返回当前值并自增,自动回绕。UDPChannel 持有一个 `largeOutSeqAt_` 用于 off-channel 发送(无 channel 场景)。

### 8.2 ACK 确认机制

Mercury 支持三种 ACK 形式:

#### 8.2.1 单个 ACK

每个收到的包都会加入 `acksToSend_` 集合:

```cpp
// udp_channel.hpp:174
typedef BW::set< SeqNum > Acks;
Acks acksToSend_;
```

`addToReceiveWindow` 中插入:

```cpp
// udp_channel.cpp:1258-1259
if (!p->isPiggyback()) {
    acksToSend_.insert( seq );
}
```

发送时 ACK 被写入 packet footer(FLAG_HAS_ACKS)。每个 ACK 是一个 SeqNum(4 字节)+ AckCount(1 字节)。

#### 8.2.2 累积 ACK

`FLAG_HAS_CUMULATIVE_ACK` 表示"到此 seq 之前的所有包都已收到"。`handleCumulativeAck` 一次确认多个包,适合批量场景。

#### 8.2.3 隐式 ACK(Piggyback)

Piggyback 子包被主包的 ACK 隐式确认:

```cpp
// udp_channel.cpp:1251-1259
if (!p->isPiggyback())
{
    // No need to ACK piggybacks as they are implicitly ACKed by the
    // containing packet's ACK.
    acksToSend_.insert( seq );
}
```

这避免了"piggyback 的 ACK 又触发 piggyback"的死循环。

### 8.3 RTO(重传超时)计算

Mercury 的 RTO 算法非常简单,没有 TCP 的 SRTT/RTTVAR 复杂计算:

```cpp
// udp_channel.cpp:1080-1081
uint64 resendPeriod =
    std::max( roundTripTime_*2, minInactivityResendDelay_ );
```

**RTO = max(RTT * 2, minInactivityResendDelay_)**。

`roundTripTime_` 通过 EWMA 更新(`udp_channel.cpp:996-1002`):

```cpp
const uint64 RTT_AVERAGE_DENOM = 10;
roundTripTime_ = ((roundTripTime_ * (RTT_AVERAGE_DENOM - 1)) +
    (timestamp() - pUnackedPacket->lastSentTime_)) / RTT_AVERAGE_DENOM;
```

即 `RTT_new = 0.9 * RTT_old + 0.1 * sample`,平滑系数 0.1。

`minInactivityResendDelay_` 是下限,默认 1 秒(`udp_channel.hpp:22`):

```cpp
const float DEFAULT_INACTIVITY_RESEND_DELAY = 1.f;
```

**Karn 算法**:重传过的包不更新 RTT(`udp_channel.cpp:996`):

```cpp
if (!pUnackedPacket->wasResent_) {
    // 只有未重传的包才更新 RTT
    roundTripTime_ = ...;
}
```

这是为了避免"重传包的 ACK 是对原包还是重传包"的二义性。

### 8.4 滑动窗口

发送窗口由 `unackedPackets_` 实现,大小 `windowSize_`:

```
发送窗口示意(windowSize=8):

seq:    0  1  2  3  4  5  6  7  8  9 10 11 12 ...
状态:  A  A  U  U  U  U  U  U  .  .  .  .  .
        ^           ^                    ^
        |           |                    |
   oldestUnacked  smallOutSeqAt_     largeOutSeqAt_
        |___________|
         已发送未 ACK
                     |_________________|
                       Overflow(等待进入窗口)
```

- `oldestUnackedSeq_`:最旧的未 ACK 包
- `smallOutSeqAt_`:窗口可推进到的位置
- `largeOutSeqAt_`:已分配序列号(包括 overflow)

`sendWindowUsage`(`udp_channel.hpp:237-241`):

```cpp
int sendWindowUsage() const
{
    return this->hasUnackedPackets() ?
        seqMask( largeOutSeqAt_ - oldestUnackedSeq_ ) : 0;
}
```

### 8.5 快速重传

Mercury 的"快速重传"实现(`udp_channel.cpp:1105-1109`):

```cpp
const bool hasNewerAck =
    seqLessThan( pUnacked->lastSentAtOutSeq_, highestAck_);
const bool shouldResend = hasNewerAck ||
    (isIrregular && (now - pUnacked->lastSentTime_ > resendPeriod));
```

**触发条件 1**:`hasNewerAck`——收到了更后面包的 ACK,说明这个包可能丢了。这等价于 TCP 的"3 个 dup ack"机制,但 Mercury 用一个 ACK 就触发,因为 Mercury 的 ACK 是显式的。

**触发条件 2**:超时(`isIrregular` 通道)。

### 8.6 与 TCP 拥塞控制对比

| 方面 | TCP | Mercury |
|------|-----|---------|
| 拥塞窗口 | cwnd,动态调整 | 无,固定 windowSize_ |
| 慢启动 | cwnd 从 1 指数增长 | 无 |
| 拥塞避免 | cwnd 线性增长 | 无 |
| 快速重传 | 3 dup ack | 1 ack |
| 快速恢复 | cwnd 减半 | 无 |
| 超时重传 | RTO = SRTT + 4*RTTVAR | RTO = max(2*RTT, 1s) |
| 拥塞判定 | 丢包 = 拥塞 | 不显式判定拥塞 |

Mercury 假设"丢包不是拥塞",这是合理的,因为游戏服务器内部网络通常是低丢包率的 LAN。如果用 TCP 拥塞控制,一次偶发丢包会让吞吐量减半,严重影响同步效率。

### 8.7 算法步骤总结

发送流程:

```
1. bundle.startMessage( ie, reliable )
2. bundle << args... (可多次)
3. (可重复 1-2 多次,放多个消息到 bundle)
4. channel.send()  // 或 networkInterface.send( addr, bundle )
5. Channel::send:
   a. doPreFinaliseBundle( bundle )  // UDPChannel 写 channel 标志
   b. bundle.finalise()  // doFinalise: endMessage, endPacket, 清除 passenger
   c. addReplyOrdersTo( bundle, this )  // 注册 request
   d. doSend( bundle )  // UDPChannel::doSend -> PacketSender::send
6. PacketSender::send:
   a. bundle.preparePackets( channel, seqAlloc, stats, useChecksum )
      // 写所有 footer,分配 seq,加入 unacked 列表
   b. 对每个 packet 调用 sendPacket
   c. sendPacket -> Endpoint::sendto
```

接收流程:

```
1. Endpoint::recvfrom -> Packet 数据
2. PacketReceiver::handleInputNotification
3. PacketReceiver::processSocket
4. PacketReceiver::processPacket
   a. validateChecksum  // 校验
   b. processPiggybackPackets  // 先处理 piggyback
   c. processFilteredPacket
5. processFilteredPacket -> processOrderedPacket
6. processOrderedPacket:
   a. 找 channel (findChannel)
   b. channel->addToReceiveWindow( packet )
   c. 如果是 PACKET_IS_NEXT_IN_WINDOW,处理 packet 链
   d. 解析消息,分发到 handler
7. 消息处理:
   a. 普通 message -> pHandler->handleMessage
   b. request -> RequestManager::addReplyOrder
   c. reply -> RequestManager::handleReply
```

---

## 九、流量控制与背压

### 9.1 通道带宽限制

`UDPChannel` 没有显式的"带宽限制"参数,但通过几个机制间接实现:

#### 9.1.1 窗口大小限制

```cpp
// udp_channel.cpp:27-29
const int EXTERNAL_CHANNEL_SIZE = 256;
const int INTERNAL_CHANNEL_SIZE = 4096;
const int INDEXED_CHANNEL_SIZE = 512;
```

EXTERNAL 通道窗口只有 256,限制了"在飞"的包数量,间接限制了带宽。

#### 9.1.2 Overflow 上限

```cpp
// udp_channel.cpp:34-38
uint UDPChannel::s_maxOverflowPackets_[] =
    { 1024, // External
      8192, // Internal
      4096  // Indexed
    };
```

`checkOverflowErrors`(`udp_channel.cpp:421-456`)在超过 maxOverflow 时警告或断言:

```cpp
// udp_channel.cpp:421-456
void UDPChannel::checkOverflowErrors()
{
    const uint maxOverflowPackets = this->getMaxOverflowPackets();
    const SeqNum numOverflowPackets =
        seqMask( largeOutSeqAt_ - smallOutSeqAt_ );
    if (maxOverflowPackets != 0) {
        MF_ASSERT( s_allowInteractiveDebugging ||
                    !s_assertOnMaxOverflowPackets ||
                    (numOverflowPackets < maxOverflowPackets) );
        if (numOverflowPackets > (maxOverflowPackets / 2)) {
            if (!hasSeenOverflowWarning_) {
                WARNING_MSG( "..." );
                hasSeenOverflowWarning_ = true;
            }
        }
        // ...
    }
}
```

### 9.2 优先级消息

Mercury 没有"显式优先级"概念,但通过 `RELIABLE_CRITICAL` 提供了类似机制:

```cpp
// bundle.hpp:34-40
RELIABLE_NO = 0,         // 不可靠
RELIABLE_DRIVER = 1,      // 可靠
RELIABLE_PASSENGER = 2,   // 可靠乘客
RELIABLE_CRITICAL = 3     // 可靠关键
```

`RELIABLE_CRITICAL` 设置 `isCritical_`(`udp_bundle.cpp:240`):

```cpp
isCritical_ = (reliable == RELIABLE_CRITICAL);
```

`isCritical_` 影响 `unackedCriticalSeq_`,后者用于 `resendCriticals`(`udp_channel.cpp:1422-1443`):

```cpp
void UDPChannel::resendCriticals()
{
    if (unackedCriticalSeq_ == SEQ_NULL) {
        WARNING_MSG( "..." );
        return;
    }
    for (SeqNum seq = oldestUnackedSeq_;
         seq != seqMask( unackedCriticalSeq_ + 1 );
         seq = seqMask( seq + 1 )) {
        if (unackedPackets_[ seq ]) {
            this->resend( seq, this->udpBundle() );
        }
    }
}
```

`resendCriticals` 立即重传所有未 ACK 的 critical 包,不等下一次发送时机。这是"加速重传"机制,适合关键消息(如登录响应)。

### 9.3 紧急消息(立即发送)

`sendIfIdle`(`udp_channel.cpp:795-808`):

```cpp
void UDPChannel::sendIfIdle()
{
    if (this->isEstablished()) {
        if (timestamp() - this->lastReliableSendOrResendTime() >
                minInactivityResendDelay_/2) {
            this->send();
        }
    }
}
```

如果通道空闲超过 `minInactivityResendDelay_/2`,立即发送。这用于"心跳"场景——通道空闲时也会偶发发送,触发 ACK 交换。

`delayedSend`(`udp_channel.cpp` 标记 channel 为"延迟发送",由 NetworkInterface 在下个 tick 统一发送,避免高频小消息各自发包。

### 9.4 背压(Backpressure)

Mercury 的背压通过 `REASON_WINDOW_OVERFLOW` 实现:

```cpp
// misc.hpp:145
REASON_WINDOW_OVERFLOW = -6,    // 通道发送窗口溢出
```

当 `addResendTimer` 返回 false(窗口满),会触发 `WINDOW_OVERFLOW` 异常:

```cpp
// udp_bundle.cpp:600-604
if (pFirstOverflowPacket == NULL) {
    pFirstOverflowPacket = pPacket;
}
// return REASON_WINDOW_OVERFLOW;
```

调用方(通常在 `PacketSender`)会检查并通知 RequestManager 取消相关请求。这就是 Mercury 的"背压"机制:**当发送窗口溢出时,新包被丢弃,相关请求失败,应用层感知并降速**。

### 9.5 限流策略

`NetworkInterface` 提供 per-IP 限流:

```cpp
// network_interface.hpp:241-262
float rateLimitPeriod() const { return rateLimitPeriod_; }
uint perIPAddressRateLimit() const { return rateLimitPerIPAddress_; }
uint perIPAddressPortRateLimit() const { return rateLimitPerIPAddressPort_; }
bool incrementAndCheckRateLimit( const Address & addr );
```

`incrementAndCheckRateLimit` 在每次收到包时调用,统计每个 IP 或 (IP, port) 的包数,超过限制则丢弃后续包。这是防 DDoS 和洪水攻击的关键。

```cpp
// network_interface.hpp:297-304
typedef BW::map< Mercury::Address, uint > RateLimitedAddresses;
uint rateLimitPerIPAddress_;
RateLimitedAddresses rateLimitedIPAddresses_;
AccumulatingEMA<uint> ipAddressRateLimitAverage_;

uint rateLimitPerIPAddressPort_;
RateLimitedAddresses rateLimitedIPAddressPorts_;
AccumulatingEMA<uint> ipAddressPortRateLimitAverage_;
```

`AccumulatingEMA` 是指数加权平均,用于平滑统计,避免瞬时尖峰误判。

---

## 十、消息类型与 InterfaceElement

### 10.1 InterfaceElement 概述

`InterfaceElement`(`interface_element.hpp:87`)是 Mercury 描述消息元数据的核心。它定义了一个消息的:
- **ID**:`MessageID`(uint8,0-255,0xFF 保留给 REPLY)
- **name**:消息名(用于调试)
- **lengthStyle**:长度风格(固定/变长/回调)
- **lengthParam**:长度参数(固定长度字节数 / 变长长度字段字节数)
- **pHandler**:消息处理器

```cpp
// interface_element.hpp:87-188
class InterfaceElement
{
public:
    InterfaceElement( const char * name = "", MessageID id = 0,
            int8 lengthStyle = INVALID_MESSAGE, int lengthParam = 0,
            InputMessageHandler * pHandler = NULL );
    // ...
private:
    MessageID           id_;            // 消息 ID
    int8                lengthStyle_;   // 长度风格
    int32               lengthParam_;  // 长度参数
    const char *        name_;          // 名称
    InputMessageHandler * pHandler_;   // 处理器
    mutable bool        shouldProcessEarly_;
};
```

### 10.2 长度风格

三种长度风格(`interface_element.hpp:36-55`):

```cpp
const char FIXED_LENGTH_MESSAGE = 0;       // 固定长度
const char VARIABLE_LENGTH_MESSAGE = 1;    // 变长(头中带长度字段)
const char CALLBACK_LENGTH_MESSAGE = 2;    // 回调决定长度
const char INVALID_MESSAGE = 3;            // 未初始化
```

- **FIXED_LENGTH**:`lengthParam` = 字节数,所有消息都这么多字节
- **VARIABLE_LENGTH**:`lengthParam` = 长度字段字节数(1, 2, 或 4)
- **CALLBACK_LENGTH**:长度由回调函数决定(用于复杂场景)

### 10.3 MessageID 类型

```cpp
// misc.hpp:90
typedef uint8 MessageID;
```

8 位消息 ID,理论最多 256 种消息。`0xFF` 保留给 REPLY:

```cpp
// interface_element.hpp:342
const unsigned char REPLY_MESSAGE_IDENTIFIER = 0xFF;
```

所以实际可用 255 种。如果接口需要更多消息,会用"扩展 ID"机制(2 字节 ID),但 Mercury 本身只支持单字节。

### 10.4 接口定义宏

`interface_macros.hpp` 提供了一系列宏简化接口定义:

```cpp
// interface_macros.hpp:11-22
#define MERCURY_FIXED_MESSAGE( NAME, PARAM, HANDLER )   \
    MERCURY_MESSAGE( NAME, FIXED_LENGTH_MESSAGE, PARAM, HANDLER )

#define MERCURY_VARIABLE_MESSAGE( NAME, PARAM, HANDLER )  \
    MERCURY_MESSAGE( NAME, VARIABLE_LENGTH_MESSAGE, PARAM, HANDLER )

#define MERCURY_CALLBACK_MESSAGE( NAME, HANDLER )       \
    MERCURY_MESSAGE( NAME, CALLBACK_LENGTH_MESSAGE, 0, HANDLER )

#define MERCURY_EMPTY_MESSAGE( NAME, HANDLER )           \
    MERCURY_MESSAGE( NAME, FIXED_LENGTH_MESSAGE, 0, HANDLER )
```

完整的接口定义通过 `BEGIN_MERCURY_INTERFACE` / `END_MERCURY_INTERFACE`(`interface_macros.hpp:189-214`):

```cpp
// interface_macros.hpp:189-214
#define BEGIN_MERCURY_INTERFACE( INAME )                                \
    namespace INAME {                                                   \
        Mercury::InterfaceMinder gMinder( #INAME );                     \
        void registerWithInterface(                                     \
                Mercury::NetworkInterface & networkInterface )         \
        {                                                               \
            gMinder.registerWithInterface( networkInterface );         \
        }                                                               \
        // ...

#define MERCURY_MESSAGE( NAME, STYLE, PARAM, HANDLER )                  \
        const Mercury::InterfaceElement & NAME =                       \
            gMinder.add( #NAME, Mercury::STYLE, PARAM,                 \
                        NULL_IF_NOT_SERVER( HANDLER ) );

#define END_MERCURY_INTERFACE()                                         \
    }
```

实际接口定义示例(类似 `cellapp_interface.hpp`):

```cpp
BEGIN_MERCURY_INTERFACE( CellAppInterface )
    MERCURY_VARIABLE_MESSAGE( entityMessage, 1, CellAppInterface::entityMessage )
    MERCURY_FIXED_MESSAGE( createEntity, sizeof(CreateEntityArgs), ... )
    // ...
END_MERCURY_INTERFACE()
```

这会生成:
- `CellAppInterface::gMinder`(InterfaceMinder)
- `CellAppInterface::registerWithInterface(...)` 函数
- 每个消息对应的 `const InterfaceElement & NAME` 全局变量

### 10.5 Struct Message 与流操作符

`MERCURY_STRUCT_MESSAGE`(`interface_macros.hpp:221-233`)定义结构化消息:

```cpp
#define MERCURY_STRUCT_MESSAGE( NAME, HANDLER )                         \
    MERCURY_MESSAGE( NAME, FIXED_LENGTH_MESSAGE, sizeof(struct NAME##Args), HANDLER ) \
    Mercury::Bundle & operator<<( Mercury::Bundle & b,                  \
        const struct NAME##Args &s )                                    \
    {                                                                   \
        b.startMessage( NAME );                                         \
        (*(BinaryOStream*)( &b )) << s;                                 \
        return b;                                                       \
    }                                                                   \
    struct __Garbage__##NAME##Args
```

配套的 `MERCURY_ISTREAM`/`MERCURY_OSTREAM`(`interface_macros.hpp:285-295`)定义流操作符:

```cpp
#define MERCURY_ISTREAM( NAME, XSTREAM )                                \
BinaryIStream& operator>>( BinaryIStream &is, NAME##Args &x )           \
{                                                                       \
    return is >> XSTREAM;                                               \
}

#define MERCURY_OSTREAM( NAME, XSTREAM )                                \
BinaryOStream& operator<<( BinaryOStream &os, const NAME##Args &x )     \
{                                                                       \
    return os << XSTREAM;                                               \
}
```

实际用法:

```cpp
// 定义消息结构
BEGIN_STRUCT_MESSAGE( controlEntity, CellAppInterface::controlEntity )
    EntityID    id;
    bool        on;
END_STRUCT_MESSAGE()
MERCURY_ISTREAM( controlEntity, x.id >> x.on )
MERCURY_OSTREAM( controlEntity, x.id << x.on )
```

`x.id`、`x.on` 这种"显式列举字段"的方式确保跨字节序兼容——BigWorld 不允许直接 memcpy struct,因为不同平台字节序可能不同。

### 10.6 InterfaceMinder

`InterfaceMinder`(`interface_minder.hpp:22-46`)管理一个接口的所有元素:

```cpp
class InterfaceMinder
{
public:
    InterfaceMinder( const char * name );
    InterfaceElement & add( const char * name, int8 lengthStyle,
            int lengthParam, InputMessageHandler * pHandler = NULL );
    MessageID addRange( const InterfaceElement & ie, int rangePortion );
    InputMessageHandler * handler( int index );
    void handler( int index, InputMessageHandler * pHandler );
    const InterfaceElement & interfaceElement( uint8 id ) const;
    void registerWithInterface( NetworkInterface & networkInterface );
    Reason registerWithMachined( const Address & addr, int id ) const;
    // ...
private:
    InterfaceElements elements_;
    const char * name_;
};
```

`add` 创建 InterfaceElement 并分配 ID(自增),返回引用。这就是为什么 .interface 文件中消息按声明顺序分配 ID。

### 10.7 InterfaceTable

`InterfaceTable`(`interface_table.hpp:16-70`)是 NetworkInterface 持有的消息表:

```cpp
class InterfaceTable : public TimerHandler
{
public:
    InterfaceTable( EventDispatcher & dispatcher );
    void serve( const InterfaceElement & ie, InputMessageHandler * pHandler );
    void onBundleStarted( Channel * pChannel );
    void onBundleFinished( Channel * pChannel );
    INLINE const char * msgName( MessageID msgID ) const;
    InterfaceElementWithStats & operator[]( int id );
    // ...
private:
    Table table_;  // vector<InterfaceElementWithStats>
};
```

`serve` 注册一个 handler:

```cpp
void InterfaceTable::serve( const InterfaceElement & ie, InputMessageHandler * pHandler )
{
    // 扩展 table_ 到 ie.id() + 1
    if (int(table_.size()) <= ie.id()) {
        table_.resize( ie.id() + 1 );
    }
    table_[ ie.id() ] = ie;
    table_[ ie.id() ].pHandler( pHandler );
}
```

### 10.8 InterfaceElementWithStats

带统计的 InterfaceElement(`interface_element.hpp:194-332`):

```cpp
class InterfaceElementWithStats : public InterfaceElement
{
public:
    InterfaceElementWithStats();
    void tick();  // 每秒调用,更新 EMA
    uint maxBytesReceived() const;
    uint numBytesReceived() const;
    uint numMessagesReceived() const;
    float avgMessagesReceivedPerSecond() const;
    float avgBytesReceivedPerSecond() const;
    float avgMessageLength() const;
    void startProfile();
    void stopProfile( uint32 msgLen );
private:
    uint maxBytesReceived_;
    uint numBytesReceived_;
    uint numMessagesReceived_;
    AccumulatingEMA< uint > avgBytesReceivedPerSecond_;
    AccumulatingEMA< uint > avgMessagesReceivedPerSecond_;
    ProfileVal profile_;
};
```

每个消息类型都有独立的统计:接收次数、字节数、EMA 平均、最大值、profile。可通过 Watcher 监控。

### 10.9 UnpackedMessageHeader

`UnpackedMessageHeader`(`unpacked_message_header.hpp:20-52`)是接收端解包后的消息头:

```cpp
class UnpackedMessageHeader
{
public:
    static const ReplyID NO_REPLY = REPLY_ID_NONE;
    MessageID       identifier;       // 消息 ID
    ReplyID         replyID;          // 回复 ID(请求才有)
    int             length;           // 消息体长度
    bool *          pBreakLoop;       // 中断 bundle 处理
    const InterfaceElement * pInterfaceElement;
    ChannelPtr      pChannel;
    NetworkInterface * pInterface;
    // ...
};
```

`pBreakLoop` 是个特殊设计:handler 可以通过 `breakBundleLoop()` 中断当前 bundle 的处理,用于"消息处理过程中触发了 channel 销毁"等场景。

### 10.10 消息分发流程

接收端的分发流程(简化):

```
1. PacketReceiver::processOrderedPacket
2. 解析 packet 中的消息流
3. 对每个消息:
   a. 读取 MessageID
   b. 查 InterfaceTable::table_[ id ]
   c. 读取长度(根据 lengthStyle)
   d. 构造 UnpackedMessageHeader
   e. 调用 pHandler->handleMessage( source, header, data )
4. handler 内部:
   a. 反序列化 args
   b. 执行业务逻辑
   c. 可能调用 bundle << replyArgs + startReply
```

`InputMessageHandler` 是抽象基类,应用层继承实现具体处理。

---

## 十一、Request 请求-响应模式

### 11.1 Request 概述

`Request`(`request.hpp:24-64`)是 Mercury 内置的请求-响应模式。发送方发出请求时,Mercury 自动管理 reply ID、超时、回调;接收方处理请求后通过 `startReply` 回复。

```cpp
// request.hpp:24-64
class Request : public TimerHandler
{
public:
    Request( int replyID, const ReplyOrder & replyOrder,
            Channel * pChannel, RequestManager * pRequestManager,
            EventDispatcher & dispatcher );
    virtual ~Request();
    virtual void handleTimeout( TimerHandle handle, void * arg );
    virtual void onRelease( TimerHandle handle, void * pUser );
    void handleMessage( const Address & source,
        UnpackedMessageHeader & header, BinaryIStream & data );
    void handleFailure( Reason reason );
    bool matches( Channel * pChannel ) const;
    bool matches( ReplyMessageHandler * pHandler ) const;
    bool isValidSource( const Address & source ) const;
    int replyID() const { return replyID_; }
private:
    void finish();
    int replyID_;
    TimerHandle timerHandle_;
    ReplyMessageHandler * pHandler_;
    void * arg_;
    Channel * pChannel_;
};
```

### 11.2 ReplyID 与 RequestManager

`ReplyID` 类型(`misc.hpp:110-112`):

```cpp
typedef int32 ReplyID;
const ReplyID REPLY_ID_NONE = -1;
const ReplyID REPLY_ID_MAX = 1000000;
```

最大 100 万,这是单个进程能同时存在的最大请求数。`RequestManager` 管理 ReplyID 到 Request 的映射:

```cpp
// request_manager.hpp
class RequestManager
{
public:
    ReplyID addReplyOrder( const ReplyOrder & ro, Channel * pChannel );
    void addReplyOrder( const ReplyOrder & ro, ReplyID id, Channel * pChannel );
    void cancelRequestsFor( Channel * pChannel );
    void cancelRequestsFor( ReplyMessageHandler * pHandler, Reason reason );
    bool handleReply( const Address & source, ReplyID replyID,
        UnpackedMessageHeader & header, BinaryIStream & data );
    void failRequest( Request & request, Reason reason );
    // ...
};
```

### 11.3 ReplyOrder

`ReplyOrder`(`reply_order.hpp`)是请求注册时的简化结构:

```cpp
struct ReplyOrder
{
    ReplyMessageHandler * handler;  // 回调对象
    void * arg;                     // 用户参数
    int microseconds;               // 超时(微秒)
    ReplyID * pReplyID;             // 指向 bundle 中的 reply ID 位置
};
```

`pReplyID` 是关键:它指向 bundle 中的 reply ID 字段,这样 RequestManager 分配 reply ID 后,可以直接写到 bundle 里(延迟绑定)。

### 11.4 请求超时

`Request` 构造时设置定时器(`request.cpp:17-32`):

```cpp
Request::Request( int replyID,
            const ReplyOrder & replyOrder, Channel * pChannel,
            RequestManager * pRequestManager, EventDispatcher & dispatcher ) :
        replyID_( replyID ),
        timerHandle_(),
        pHandler_( replyOrder.handler ),
        arg_( replyOrder.arg ),
        pChannel_( pChannel )
{
    if (!pChannel) {
        MF_ASSERT( replyOrder.microseconds > 0 );
        timerHandle_ = dispatcher.addOnceOffTimer(
                            replyOrder.microseconds, this, pRequestManager );
    }
}
```

**重要细节**:**channel-bound request 不设置定时器**(`if (!pChannel)`)。channel-bound request 由 channel 的不活跃检测负责超时,不重复设置定时器。这避免了"channel 已死但 request 还在等待"的浪费。

### 11.5 超时处理

`handleTimeout`(`request.cpp:58-62`):

```cpp
void Request::handleTimeout( TimerHandle /*handle*/, void * arg )
{
    static_cast< RequestManager * >( arg )->failRequest( *this,
            REASON_TIMER_EXPIRED );
}
```

`failRequest` 调用 `Request::handleFailure`:

```cpp
// request.cpp:82-97
void Request::handleFailure( Reason reason )
{
    NubException e( reason );
    if (reason != REASON_SHUTTING_DOWN) {
        pHandler_->handleException( e, arg_ );
    } else {
        pHandler_->handleShuttingDown( e, arg_ );
    }

    this->finish();
}
```

**关键细节**:
- **REASON_SHUTTING_DOWN 走特殊回调**:`handleShuttingDown` 而不是 `handleException`,允许应用区分"网络故障"和"主动关闭"两种场景。Reviver 在停止进程时会用此机制。
- **`finish()` 总是被调用**:无论成功/失败,Request 都要释放资源。
- **failRequest 的另一个调用路径**:`RequestManager::cancelRequestsFor(Channel*)` 在 channel 销毁时,会批量 fail 该 channel 上的所有未决请求,reason 通常是 `REASON_CHANNEL_LOST`。

### 11.6 handleMessage(正常响应)

当收到对应 reply ID 的响应消息时,`RequestManager::handleReply` 路由到 `Request::handleMessage`(`request.cpp:68-75`):

```cpp
void Request::handleMessage( const Address & source,
    UnpackedMessageHeader & header,
    BinaryIStream & data )
{
    pHandler_->handleMessage( source, header, data, arg_ );

    this->finish();
}
```

**source 校验**:`isValidSource` 检查响应来源是否合法。对于 channel-bound request,只有 channel 的对端地址能回复;对于 off-channel request(无 channel),任何地址都可回复。

```cpp
bool Request::isValidSource( const Address & source ) const
{
    return (pChannel_ == NULL) || (source == pChannel_->addr());
}
```

这是一个**安全防御**:防止恶意进程伪造 reply ID 注入响应。Mercury 假设内部网络可信,但仍做这一层校验。

### 11.7 finish() 与 onRelease()

`finish` 负责清理定时器并最终 delete self(`request.cpp:103-114`):

```cpp
void Request::finish()
{
    if (timerHandle_.isSet())
    {
        // Cancelling the timer will call onRelease which will delete this.
        timerHandle_.cancel();
    }
    else
    {
        delete this;
    }
}

void Request::onRelease( TimerHandle handle, void * pUser )
{
    // and finally delete ourselves
    delete this;
}
```

**为什么这样设计?**:`timerHandle_.cancel()` 会触发 `onRelease` 回调(由 EventDispatcher 调度),而 `onRelease` 中再次 `delete this`。所以 `finish` 不能直接 `delete this`,而是依赖 `onRelease`。这避免了"在 cancelTimer 调用栈中销毁 timer 自身"的 use-after-free。

### 11.8 ReplyMessageHandler 接口

应用层继承 `ReplyMessageHandler`(`reply_message_handler.hpp`)实现 3 个回调:

```cpp
class ReplyMessageHandler
{
public:
    virtual void handleMessage( const Address & source,
        UnpackedMessageHeader & header,
        BinaryIStream & data, void * arg ) = 0;

    virtual void handleException( const NubException & ne,
        void * arg ) = 0;

    virtual void handleShuttingDown( const NubException & ne,
        void * arg ) = 0;
};
```

3 个回调对应 3 种终结路径:

| 路径 | 触发条件 | 回调 |
|------|----------|------|
| 正常响应 | 收到匹配 reply ID 的消息 | `handleMessage` |
| 网络故障 | 超时/channel 销毁/channel lost | `handleException` |
| 主动关闭 | 应用调用 `prepareForShutdown` | `handleShuttingDown` |

**`arg` 参数**:`arg` 是注册时由调用方传入的 `void *`,常用于"用户上下文"(如 ServerConnection 指针)。这让一个 handler 类可以服务多个请求,通过 `arg` 区分。

### 11.9 RequestManager 请求管理

`RequestManager` 维护 ReplyID 到 Request 的映射,核心方法:

```cpp
ReplyID addReplyOrder( const ReplyOrder & ro, Channel * pChannel );
// 分配新 reply ID,创建 Request,加入 map

void addReplyOrder( const ReplyOrder & ro, ReplyID id, Channel * pChannel );
// 用指定 reply ID(用于 bundle 中的 reply ID 已固定场景)

bool handleReply( const Address & source, ReplyID replyID,
    UnpackedMessageHeader & header, BinaryIStream & data );
// 收到响应时调用,路由到对应 Request::handleMessage

void cancelRequestsFor( Channel * pChannel );
// channel 销毁时,批量 fail 该 channel 上所有请求

void failRequest( Request & request, Reason reason );
// 调用 request.handleFailure(reason),然后从 map 移除并释放
```

**ReplyID 分配策略**:从 0 开始递增,达到 `REPLY_ID_MAX`(100 万)后回到 0。这是一个环形分配,跳过仍在使用的 ID。

**channel-bound request 的 replyID 写入时机**:bundle finalize 时,reply ID 字段先写入 `REPLY_ID_NONE`,然后 `addReplyOrder` 分配实际 ID,通过 `ReplyOrder::pReplyID` 直接写回 bundle 内存(延迟绑定)。

### 11.10 取消请求场景

`cancelRequestsFor` 有 3 个重载:

1. **`cancelRequestsFor(Channel*)`**:channel 销毁时,所有绑定该 channel 的 request 用 `REASON_CHANNEL_LOST` 失败。
2. **`cancelRequestsFor(ReplyMessageHandler*, Reason)`**:某个 handler 不再使用,所有该 handler 的 request 用指定 reason 失败。常用于"ServerConnection 析构"。
3. **`cancelRequestsFor(Bundle&, Reason)`**:bundle 中的所有 reply ID,用指定 reason 失败。用于"bundle 即将被回收但还没发出去"。

第 3 种重载通过解析 bundle 中的 reply ID 列表实现,需要在 bundle 序列化时记录所有 reply ID 位置。

### 11.11 Mercury 请求-响应的局限

Mercury 的请求-响应模式有以下局限:

1. **单点请求**:不支持 fan-out(一个 request 发给多个对端,等任一响应或所有响应)。BigWorld 上层(BaseAppMgr)通过自己循环 sendAndRecv 实现伪 fan-out。
2. **无取消语义**:`cancelRequestsFor` 只是 fail,不能"安静地"取消(request 已发出,对端可能仍回复)。
3. **无 priority**:所有 request 共享同一 reply ID 空间,没有优先级区分。
4. **ReplyID 全局**:单个 NetworkInterface 共享一个 RequestManager,reply ID 是全局的,不像 channel 那样独立。
5. **回调同步**:`handleMessage` 在 dispatcher 线程中同步调用,handler 不能阻塞,否则阻塞整个网络线程。

---

## 十二、NetworkInterface 顶层接口

### 12.1 概述

`NetworkInterface`(`network_interface.hpp:51-341`)是 Mercury 暴露给上层的顶层接口。一个进程通常有 1-2 个 NetworkInterface:

- **Internal**:进程间通信(CellApp ↔ BaseApp ↔ BaseAppMgr 等),使用内部端口范围
- **External**:与客户端通信(LoginApp 的 client 接口、BaseApp 的 client 接口),通常开启加密

### 12.2 构造与析构

```cpp
// network_interface.cpp
NetworkInterface::NetworkInterface( EventDispatcher * pMainDispatcher,
    NetworkInterfaceType interfaceType,
    uint16 listeningPort, const char * listeningInterface ) :
    udpSocket_(),
    address_(),
    isExternal_( interfaceType == NETWORK_INTERFACE_EXTERNAL ),
    verbosityLevel_( VERBOSITY_LEVEL_NORMAL ),
    pDispatcher_( NULL ),
    pMainDispatcher_( pMainDispatcher ),
    pExtensionData_( NULL )
{
    // 1. 创建 socket
    udpSocket_.socket( SOCK_DGRAM, IPPROTO_UDP );
    // 2. 设置 SO_REUSEADDR
    udpSocket_.setbroadcast( true );
    // 3. bind 到 listeningPort
    udpSocket_.bind( listeningPort, listeningInterface );
    // 4. 设置收发缓冲区
    udpSocket_.setBufferSize( recvBufferSize_, sendBufferSize_ );
    // 5. 创建 PacketReceiver / PacketSender / RequestManager / InterfaceTable
    // 6. attach 到 dispatcher
    this->attach( *pMainDispatcher );
}
```

**关键成员**:
- `udpSocket_`:Endpoint,实际 UDP socket
- `pPacketReceiver_`:接收器,注册到 dispatcher 的输入事件
- `pPacketSender_`:发送器
- `pRequestManager_`:请求-响应管理
- `pInterfaceTable_`:消息表
- `pChannelMap_`:channel 字典(addr → UDPChannel*)
- `pCondemnedChannels_`:已被标记 condemn 的 channel(等收完最后 ACK 后销毁)
- `pIrregularChannels_`:不活跃的 channel(长时间无通信)
- `pKeepAliveChannels_`:keep-alive 通道(需要定期 ping)
- `pDelayedChannels_`:延迟发送的 channel
- `pOffChannelFilter_`:off-channel 包过滤器(防恶意包)
- `pRecentlyDeadChannels_`:最近死亡的 channel 列表(防止快速重连伪装)

### 12.3 事件循环集成

`NetworkInterface::attach` 把 socket 注册到 EventDispatcher:

```cpp
void NetworkInterface::attach( EventDispatcher & mainDispatcher )
{
    pDispatcher_ = &mainDispatcher;
    pDispatcher_->registerFileDescriptor( udpSocket_.fileno(),
        pPacketReceiver_, "NetworkInterfaceSocket" );
    // ... 添加各种定时器(irregular channel resend、keep-alive ping 等)
}
```

EventDispatcher 内部使用 EventPoller(select/poll/epoll/IOCP)监听 socket 可读事件,触发 `PacketReceiver::handleInputNotification`。

### 12.4 registerChannel / deregisterChannel

```cpp
bool NetworkInterface::registerChannel( UDPChannel & channel );
bool NetworkInterface::deregisterChannel( UDPChannel & channel );
```

- `registerChannel`:把 channel 加入 `pChannelMap_`,以 addr 为 key。后续 `findChannel(addr)` 可找到。
- `deregisterChannel`:从 map 移除。channel 进入 CondemnedChannels(等所有未 ACK 包被 ACK 或超时)。

**findOrCreateChannel**:

```cpp
INLINE UDPChannel & NetworkInterface::findOrCreateChannel( const Address & addr )
{
    UDPChannel * pChannel = this->findChannel( addr, /*createAnonymous=*/true );
    MF_ASSERT( pChannel != NULL );
    return *pChannel;
}
```

第一次收到某 addr 的包时,`findChannel(addr, true)` 创建匿名 channel(单向,只发不收 ACK)。后续对方正式握手后转为双向 channel。

### 12.5 processPacket 流程

`PacketReceiver::processPacket` 是接收主入口:

```cpp
Reason PacketReceiver::processPacket( const Address & addr, Packet * p,
   ProcessSocketStatsHelper * pStatsHelper )
{
    // 1. 速率限制检查
    if (networkInterface_.incrementAndCheckRateLimit( addr )) {
        return REASON_GENERAL_NETWORK;
    }

    // 2. 查找 channel
    UDPChannel * pChannel = networkInterface_.findChannel( addr, ... );

    if (pChannel != NULL) {
        // 3. 更新接收统计
        pChannel->onPacketReceived( p->totalSize() );

        // 4. 调用 channel 的 filter(如果有,如加密)
        if (pChannel->pFilter() && !pChannel->hasRemoteFailed()) {
            return pChannel->pFilter()->recv( *this, addr, p, pStatsHelper );
        }
    }
    // 5. 最近死亡 channel 检查
    else if (networkInterface_.isExternal() && networkInterface_.isDead( addr )) {
        return REASON_SUCCESS;  // 静默丢弃
    }
    // 6. off-channel filter(防恶意包)
    else if (networkInterface_.pOffChannelFilter()) {
        return networkInterface_.pOffChannelFilter()->recv( *this, addr, p, pStatsHelper );
    }

    // 7. 实际处理
    return this->processFilteredPacket( addr, p, pStatsHelper );
}
```

**processFilteredPacket** 进一步解析:
1. 校验 checksum(如果 FLAG_HAS_CHECKSUM)
2. 处理 indexed channel(FLAG_HAS_INDEX)
3. 处理 request/reply
4. 分发消息到 handler

### 12.6 send 与 sendPacket

NetworkInterface 提供多个发送 API:

```cpp
void send( const Address & address, UDPBundle & bundle, UDPChannel * pChannel = NULL );
void sendOnExistingChannel( const Address & address, UDPBundle & bundle );
void sendPacket( const Address & address, Packet * pPacket,
                 UDPChannel * pChannel, bool isResend );
```

- `send`:发送 bundle,如果有 channel 走 channel send,否则走 once-off send
- `sendOnExistingChannel`:强制走已有 channel(若不存在则失败)
- `sendPacket`:底层发送 packet,经 PacketSender

**once-off send**:`OnceOffSender`(`once_off_sender.hpp`)负责无 channel 的可靠发送。机制是:
1. 发送 packet
2. 启动定时器,周期 200ms(`DEFAULT_ONCEOFF_RESEND_PERIOD`)
3. 收到 ACK 则停止;否则最多重发 50 次(`DEFAULT_ONCEOFF_MAX_RESENDS`),共 10 秒
4. 超时则 fail 对应 request(REASON_TIMER_EXPIRED)

### 12.7 速率限制(rate limit)

```cpp
float rateLimitPeriod_;            // 限流周期(秒),通常 1.0
uint rateLimitPerIPAddress_;       // 每 IP 每周期最多包数
uint rateLimitPerIPAddressPort_;    // 每 IP:port 每周期最多包数
RateLimitedAddresses rateLimitedIPAddresses_;
RateLimitedAddresses rateLimitPerIPAddressPort_;
```

`incrementAndCheckRateLimit(addr)`:每次收到包时计数,超过阈值则丢弃。这是**反 DDoS 机制**,主要保护 External 接口免受 flood 攻击。

### 12.8 收尾流程(prepareForShutdown)

```cpp
void NetworkInterface::prepareForShutdown()
{
    // 通知所有 request 用 REASON_SHUTTING_DOWN 失败
    pRequestManager_->cancelRequestsFor( NULL, REASON_SHUTTING_DOWN );
    // 停止接收新包(可以从 dispatcher 注销 socket)
    // 让所有 channel 完成最后的 send
}
```

应用进程退出时调用,确保:
- 所有未决 request 用 SHUTTING_DOWN 通知(应用可区分于网络故障)
- channel 不再收新消息
- 仍可发送最后的 goodbye 消息

### 12.9 processUntilChannelsEmpty

```cpp
void NetworkInterface::processUntilChannelsEmpty( float timeout = 10.f );
```

这是**阻塞式事件循环**,直到所有 channel 都销毁或超时。常用于:
- 服务进程的退出阶段:确保所有 client 收到 goodbye
- 测试代码:同步等待通信完成

内部循环:
1. `dispatcher_.processContinuously()`
2. 检查 `pChannelMap_` 是否为空
3. 检查是否超时

---

## 十三、FragmentedBundle 分片重组

### 13.1 概述

`FragmentedBundle`(`fragmented_bundle.hpp:22-82`)负责重组跨多个 packet 的大 bundle。当一次要发送的数据超过一个 packet 容量(约 1400 字节),UDPBundle 自动分片成多个 packet,接收端用 FragmentedBundle 重组。

### 13.2 数据结构

```cpp
class FragmentedBundle : public SafeReferenceCount
{
public:
    static const uint64 MAX_AGE = 10;  // 10 秒后过期丢弃

    FragmentedBundle( Packet * pFirstPacket );

    bool addPacket( Packet * p, bool isExternal, const char * sourceStr );

    double age() const { return (timestamp() - touched_) / stampsPerSecondD(); }
    bool isOld() const { return timestamp() - touched_ > stampsPerSecond() * MAX_AGE; }
    bool isReliable() const { return pChain_->hasFlags( Packet::FLAG_IS_RELIABLE ); }
    bool isComplete() const { return (remaining_ == 0); }

    int chainLength() const { return pChain_->chainLength(); }
    PacketPtr pChain() const { return pChain_; }
    SeqNum lastFragment() const { return lastFragment_; }

    static void addToStream( FragmentedBundlePtr pFragments, BinaryOStream & data );
    static FragmentedBundlePtr createFromStream( BinaryIStream & data );

private:
    SeqNum      lastFragment_;
    int         remaining_;
    uint64      touched_;
    PacketPtr   pChain_;

public:
    class Key
    {
    public:
        Key( const Address & addr, SeqNum firstFragment ) :
            addr_( addr ), firstFragment_( firstFragment ) {}
        Address addr_;
        SeqNum  firstFragment_;
    };
};
```

### 13.3 Key 标识

`FragmentedBundle::Key` 用 `(源地址, 首片 seq)` 标识一个分片流。同一个发送方的多个分片流可以并存(不同的 firstFragment)。

`operator<` 实现 map 排序:

```cpp
inline bool operator<( const FragmentedBundle::Key & a, const FragmentedBundle::Key & b )
{
    return (a.firstFragment_ < b.firstFragment_) ||
        (a.firstFragment_ == b.firstFragment_ && a.addr_ < b.addr_);
}
```

### 13.4 重组流程

1. **接收第一片**:create FragmentedBundle,记录 `lastFragment_`(从第一片的 footer 中读取总片数),`remaining_ = lastFragment_ - firstFragment + 1 - 1`(减去已收到的第一片)
2. **接收中间片**:`addPacket` 把 packet 插入 chain(按 seq 排序),`remaining_--`
3. **接收最后片**:`remaining_ == 0`,触发 `isComplete()`,触发 bundle 处理
4. **过期清理**:每周期检查所有 FragmentedBundle,`isOld()` 则丢弃(MAX_AGE=10 秒)

### 13.5 addPacket 算法

```cpp
bool FragmentedBundle::addPacket( Packet * p, bool isExternal, const char * sourceStr )
{
    touched_ = timestamp();

    // 检查 seq 是否在 [firstFragment, lastFragment] 范围
    SeqNum seq = p->seq();
    if (seqLessThan(seq, lastFragment_) || seqLessThan(lastFragment_, seq)) {
        // 超出范围,可能重复或乱序
        // ... 处理
    }

    // 找到正确位置插入(按 seq 排序)
    Packet * pCur = pChain_.get();
    while (pCur->pNext() && seqLessThan(pCur->seq(), seq)) {
        pCur = pCur->pNext();
    }

    // 插入 packet
    p->chain(pCur->pNext());
    pCur->chain(p);

    --remaining_;

    return isComplete();
}
```

**chain 排序**:`Packet::pNext` 形成单向链表,按 seq 升序排列。这样最后 `processOrderedPacket` 可以顺序读取所有消息。

### 13.6 MAX_AGE = 10 秒

10 秒是分片重组的最大等待时间。如果一个分片流在 10 秒内没集齐,认为是网络故障导致部分片丢失,丢弃整个分片流。

**为什么是 10 秒**:
- 比 RTO(200ms)和 channel 超时(常见 30s)短
- 比正常 RTT(几十 ms)长得多,允许重传
- 防止内存累积(攻击者发送伪造的第一片但不发后续片)

### 13.7 addToStream / createFromStream

```cpp
static void addToStream( FragmentedBundlePtr pFragments, BinaryOStream & data );
static FragmentedBundlePtr createFromStream( BinaryIStream & data );
```

**用途**:把未完成的 FragmentedBundle 序列化到流,稍后从流恢复。这用于 **channel 迁移**:当一个 BaseApp 接管另一个 BaseApp 的实体时,可以把对方的 FragmentedBundle 状态迁移过来,避免分片流中断。

序列化内容:
- `lastFragment_`
- `remaining_`
- 每个 packet 的 seq + 数据

### 13.8 与 Packet 分片的关系

`Packet::FLAG_IS_FRAGMENT` 标记一个 packet 是分片的一部分。UDPBundle 在 `preparePackets` 时,如果 bundle 数据超过 packet 容量,会:
1. 第一个 packet:FLAG_IS_FRAGMENT | FLAG_HAS_MORE_FRAGMENTS,seq = firstFragment
2. 中间 packet:FLAG_IS_FRAGMENT | FLAG_HAS_MORE_FRAGMENTS,seq 递增
3. 最后 packet:FLAG_IS_FRAGMENT(没有 HAS_MORE_FRAGMENTS),seq = lastFragment

接收端看到 FLAG_IS_FRAGMENT,就查 FragmentedBundle map,没有则创建。

---

## 十四、ChannelOwner 通道所有者

### 14.1 概述

`ChannelOwner`(`channel_owner.hpp:14-48`)是一个**RAII 包装类**,让上层对象方便地持有 channel 的所有权:

```cpp
class ChannelOwner
{
public:
    ChannelOwner( NetworkInterface & networkInterface,
            const Address & address = Address::NONE,
            UDPChannel::Traits traits = UDPChannel::INTERNAL ) :
        pChannel_( traits == UDPChannel::INTERNAL ?
            UDPChannel::get( networkInterface, address ) :
            new UDPChannel( networkInterface, address, traits ) )
    {
    }

    ~ChannelOwner()
    {
        pChannel_->condemn();
        pChannel_ = NULL;
    }

    Bundle & bundle() { return pChannel_->bundle(); }
    const Address & addr() const { return pChannel_->addr(); }
    const char * c_str() const { return pChannel_->c_str(); }
    void send( Bundle * pBundle = NULL ) { pChannel_->send( pBundle ); }

    UDPChannel & channel() { return *pChannel_; }
    const UDPChannel & channel() const { return *pChannel_; }

    void addr( const Address & addr );

private:
    UDPChannel * pChannel_;
};
```

### 14.2 设计意图

**RAII 模式**:构造时获取 channel,析构时 condemn。这避免了:
- 忘记 condemn 导致 channel 泄漏
- 提前 condemn 导致 use-after-free

**常见用法**:BaseApp 的 Base 类继承 ChannelOwner,这样 Base 自然拥有一个 channel。Base 析构时,channel 自动 condemn。

### 14.3 Internal vs External

构造函数根据 traits 选择不同的 channel 创建方式:

```cpp
pChannel_( traits == UDPChannel::INTERNAL ?
    UDPChannel::get( networkInterface, address ) :
    new UDPChannel( networkInterface, address, traits ) )
```

- **INTERNAL**:`UDPChannel::get` 走 channel 池,可能复用已有 channel
- **EXTERNAL**(其他 traits):`new UDPChannel` 直接创建

### 14.4 condemn 语义

`~ChannelOwner` 调用 `pChannel_->condemn()`:

```cpp
~ChannelOwner()
{
    pChannel_->condemn();
    pChannel_ = NULL;
}
```

**condemn 不是立即销毁**!condemn 只是标记 channel 为"待销毁",channel 会:
1. 停止接收新消息
2. 把 inBundle 中的消息处理完
3. 把 outBundle 中的最后消息发出去
4. 等所有 unacked 包被 ACK
5. 真正销毁

这个过程可能持续几秒到几十秒,在 CondemnedChannels 中管理。

### 14.5 addr 修改

```cpp
void addr( const Address & addr );
```

修改 channel 的目标地址。这用于"Base 迁移"场景:Base 从一个 BaseApp 迁到另一个,channel 的 addr 改变。内部实现是:
1. condemn 旧 channel
2. 创建新 channel(新 addr)
3. 把 inBundle/outBuffer 转移到新 channel

### 14.6 pWatcher

```cpp
#if ENABLE_WATCHERS
static WatcherPtr pWatcher();
#endif
```

提供 Watcher 接口,可以通过 bwwatcher 工具查看所有 ChannelOwner 的状态。这对调试很有用。

---

## 十五、特殊机制:PortMap/NetMask/Misc

### 15.1 PortMap 端口约定

`portmap.hpp` 定义了 BigWorld 集群中各进程的固定端口:

```cpp
#define PORT_LOGIN                  20013
#define PORT_MACHINED_OLD           20014
#define PORT_MACHINED               20018
#define PORT_BROADCAST_DISCOVERY    20019
#define PORT_PYTHON_BASEAPP         40000  // + BaseApp id (TCP)
#define PORT_PYTHON_CELLAPP         50000  // + CellApp id (TCP)
#define PORT_PYTHON_SERVICEAPP      60000  // + ServiceApp id (TCP)
```

**设计原则**:
- **固定端口**:bwmachined 必须固定端口(20018),否则其他进程找不到它
- **发现端口**:20019 用于广播发现(新进程启动时广播"我在哪")
- **Python 调试端口**:BaseApp/CellApp 暴露 Python 调试服务(TCP),端口从 40000/50000 起递增

**PORT_MACHINED_OLD**:旧的 bwmachined 1.x 端口,新版用 20018,旧版兼容性保留。

### 15.2 NetMask 网络掩码

`NetMask`(`netmask.hpp`)用于判断 IP 是否属于某个子网:

```cpp
class NetMask
{
public:
    NetMask( uint32 addr, uint32 mask ) : addr_( addr & mask ), mask_( mask ) {}
    bool contains( uint32 addr ) const { return (addr & mask_) == addr_; }
private:
    uint32 addr_;
    uint32 mask_;
};
```

**用途**:配置文件中可以指定"内部网络 = 10.0.0.0/8",NetworkInterface 检查收到的包是否来自内部网络,内部包走 internal 接口,外部包走 external 接口。

### 15.3 Misc 杂项

`misc.hpp` 包含 Mercury 的基础类型:

- **`SeqNum`**(uint32):28 位序列号
- **`seqLessThan`**:回绕安全的小于比较
- **`SeqNumAllocator`**:序列号分配器
- **`MessageID`**(uint8):消息 ID,8 位,最多 256 种消息
- **`ChannelID`**(int32):indexed channel ID
- **`ChannelVersion`**:channel 版本号(用 SeqNum 类型,复用回绕逻辑)
- **`ReplyID`**(int32):请求-响应的回复 ID
- **`Reason`**:错误码枚举(详见附录 C)
- **`reasonToString`**:Reason 转字符串

### 15.4 默认重发参数

```cpp
const int DEFAULT_ONCEOFF_RESEND_PERIOD = 200 * 1000; /* 200 ms */
const int DEFAULT_ONCEOFF_MAX_RESENDS = 50;
```

**OnceOffSender** 的默认重发参数:
- 周期 200ms
- 最多重发 50 次
- 总超时 10 秒

这些参数可以通过 `OnceOffResender::onceOffResendPeriod` 和 `onceOffMaxResends` 在运行时修改。

### 15.5 net_360.hpp Xbox 360 支持

`net_360.hpp` 包含 Xbox 360 平台的特殊处理:
- Winsock 的某些常量在 Xbox 360 上不存在,需要定义
- `WSAGetLastError()` 的某些错误码不同
- `sendto`/`recvfrom` 的行为略有差异

这是 BigWorld 跨平台支持的体现,但实际游戏中 Xbox 360 版本较少使用 Mercury(更多用 Xbox Live 的网络层)。

---

## 十六、MachineGuard 协议

### 16.1 概述

`MachineGuard` 是 **bwmachined 与集群中其他进程的通信协议**。它独立于 Mercury 主协议,有自己的 packet 格式和消息体系。

- **用途**:进程注册、查询、创建、信号、标签管理
- **传输**:UDP,端口 20018(PORT_MACHINED)
- **特点**:支持广播(BROADCAST addr),用于发现网络中所有 bwmachined

### 16.2 MGMPacket 数据包

```cpp
class MGMPacket
{
public:
    static const int MAX_SIZE = 32768;
    enum Flags {
        PACKET_STAGGER_REPLIES = 0x1
    };

    typedef BW::vector< MachineGuardMessage* > MGMs;

    uint8   flags_;
    uint32  buddy_;
    MGMs    messages_;

protected:
    BW::vector< bool > delInfo_;
    bool    dontDeleteMessages_;
    bool    hasError_;

public:
    MGMPacket() : flags_( 0 ), buddy_( 0 ), dontDeleteMessages_( false ), hasError_( false ) {}
    MGMPacket( MemoryIStream &is ) { this->read( is ); }

    bool shouldStaggerReply() const;
    ~MGMPacket();

    void read( MemoryIStream &is );
    bool write( MemoryOStream &os ) const;

    void append( MachineGuardMessage &mgm, bool shouldDelete=false );
    inline void stealMessages() { dontDeleteMessages_ = true; }

    static void setBuddy( uint32 addr );
    static uint32 s_buddy_;
};
```

**buddy 字段**:用于 bwmachined 的环状拓扑。每个 bwmachined 有一个"buddy"(下一跳),消息沿环传播。

**PACKET_STAGGER_REPLIES**:回复时交错发送,避免多个 bwmachined 同时回复造成 burst。

### 16.3 MachineGuardMessage 体系

`MachineGuardMessage` 是基类,15 种消息类型(`machine_guard.hpp:124-145`):

| 类型 | ID | 用途 |
|------|----|----|
| WHOLE_MACHINE_MESSAGE | 1 | 查询整机信息(CPU、内存、网络) |
| PROCESS_MESSAGE | 2 | 进程注册/查询 |
| PROCESS_STATS_MESSAGE | 3 | 进程统计(CPU、内存) |
| LISTENER_MESSAGE | 4 | 注册 birth/death 监听 |
| CREATE_MESSAGE | 5 | 创建进程 |
| SIGNAL_MESSAGE | 6 | 发送信号(SIGINT/SIGQUIT) |
| TAGS_MESSAGE | 7 | 查询机器标签 |
| USER_MESSAGE | 8 | 用户信息查询 |
| PID_MESSAGE | 9 | PID 查询 |
| RESET_MESSAGE | 10 | 重置 bwmachined |
| ERROR_MESSAGE | 11 | 错误报告 |
| QUERY_INTERFACE_MESSAGE | 12 | 接口查询 |
| CREATE_WITH_ARGS_MESSAGE | 13 | 带参数创建进程 |
| HIGH_PRECISION_MACHINE_MESSAGE | 14 | 高精度机器信息 |
| MACHINE_PLATFORM_MESSAGE | 15 | 平台信息(OS 版本) |
| MACHINED_ANNOUNCE_MESSAGE | 64 | bwmachined 之间宣告 |

### 16.4 消息格式

```cpp
class MachineGuardMessage
{
public:
    uint8   message_;  // REGISTER_MESSAGE, STATS_MESSAGE 等
    uint8   flags_;     // MESSAGE_DIRECTION_OUTGOING, MESSAGE_NOT_UNDERSTOOD
    typedef uint16 UserId;

private:
    uint16  seq_;       // 序列号(发送方设置)

public:
    MachineGuardMessage( uint8 message, uint8 flags = 0, uint16 seq = 0 );

    void read( BinaryIStream &is ) { this->readImpl( is ); this->readExtra( is ); }
    void write( BinaryOStream &os ) { this->writeImpl( os ); this->writeExtra( os ); }

    static MachineGuardMessage *create( BinaryIStream &is );
    static MachineGuardMessage *create( void *buf, int length );

    bool sendto( Endpoint &ep, uint16 port, uint32 addr = BROADCAST, uint8 packFlags = 0 );
    Mercury::Reason sendAndRecv( Endpoint &ep, uint32 destaddr, ReplyHandler *pHandler = NULL );
};
```

**消息头**:3 字节(message + flags + seq),比 Mercury 的 packet header 简单。

### 16.5 CreateMessage 创建进程

`CreateMessage` 是 bwmachined 最核心的消息之一,命令远端机器启动一个进程:

```cpp
class CreateMessage : public MachineGuardMessage
{
public:
    BW::string  name_;      // 可执行文件名(cellapp, baseapp 等)
    BW::string  config_;    // 配置(Hybrid, Debug)
    UserId      uid_;       // 以哪个用户身份启动
    uint8       recover_;   // 是否带 -recover 参数
    uint32      fwdIp_;     // stdout 转发 IP
    uint16      fwdPort_;   // stdout 转发端口
};
```

bwmachined 收到后,以对应用户身份执行 `cellapp -recover=N -machined=... -forward=...`。

### 16.6 SignalMessage 信号

```cpp
class SignalMessage : public ProcessMessage
{
public:
    uint8 signal_;

    void setControlledShutdown() { signal_ = SIGUSR1; }
    void setKill() { signal_ = SIGINT; }
    void setHardKill() { signal_ = SIGQUIT; }
};
```

3 种信号:
- **SIGUSR1**:受控关闭,进程优雅退出(保存状态、通知其他进程)
- **SIGINT**:普通 kill,触发正常 shutdown 流程
- **SIGQUIT**:硬 kill,立即终止(用于进程卡死时)

### 16.7 TagsMessage 标签

```cpp
typedef BW::vector< BW::string > Tags;

class TagsMessage : public MachineGuardMessage
{
public:
    Tags    tags_;
    uint8   exists_;  // 标签类别是否存在
};
```

机器标签(bwmachined.conf 中定义)用于**进程调度**:CellAppMgr 创建新 CellApp 时,根据标签选择合适的机器(如"高 CPU"、"低延迟"标签)。

### 16.8 MachinedAnnounceMessage 环状拓扑

```cpp
class MachinedAnnounceMessage : public MachineGuardMessage
{
public:
    enum Type
    {
        ANNOUNCE_BIRTH = 0,
        ANNOUNCE_DEATH = 1,
        ANNOUNCE_EXISTS = 2
    };

    uint8 type_;
    union {
        uint32 count_;  // Birth replies 用,告知网络规模
        uint32 addr_;   // Death/exists 用,告知机器地址
    };
};
```

**bwmachined 环状拓扑**:每个 bwmachined 启动时广播 ANNOUNCE_BIRTH,所有收到该消息的 bwmachined 把新机器加入"环"。环的作用是**消息传播**:一条 MGM 消息可以在环上转发,直到回到原点。

### 16.9 与 Mercury 主协议的关系

MachineGuard 是**独立协议**,不依赖 Mercury 的 Channel/Bundle/ACK 机制:
- 用裸 UDP sendto/recvfrom
- 自己的序列号(16 位)
- 自己的消息格式

**原因**:
- bwmachined 是基础设施,不能依赖应用层 Mercury
- 需要支持广播,Mercury 的 channel 是点对点
- 协议要简单稳定,不能因 Mercury bug 影响 bwmachined

但 MachineGuardMessage 复用了 Endpoint 抽象,共享 socket 层。

### 16.10 ReplyHandler 回调体系

```cpp
class MachineGuardMessage::ReplyHandler
{
public:
    virtual bool onWholeMachineMessage( WholeMachineMessage &wmm, uint32 addr );
    virtual bool onProcessMessage( ProcessMessage &pm, uint32 addr );
    virtual bool onCreateMessage( CreateMessage &cm, uint32 addr );
    // ... 14 个虚函数,每个消息类型一个

    virtual bool onUnhandledMsg( MachineGuardMessage &mgm, uint32 addr );
};
```

应用层继承 ReplyHandler,重写感兴趣的方法。`sendAndRecv` 发送消息后阻塞接收响应,把每条响应消息路由到对应回调。返回 `true` 继续接收,`false` 提前终止。

---

## 十七、跨平台支持与 IO 模型

### 17.1 平台差异

Mercury 支持多平台:
- **Windows**:Winsock2(基于 BSD socket 但有差异)
- **Linux**:BSD socket + epoll
- **macOS**:BSD socket + kqueue(实际用 poll)
- **PlayStation 3**:自有 socket 实现
- **Xbox 360**:Winsock 变体
- **Emscripten**:浏览器环境

### 17.2 Endpoint 跨平台

`endpoint.cpp` 用条件编译处理差异:

```cpp
#if defined( _WIN32 )
    // Windows: 用 WSAStartup 初始化, closesocket 关闭
    static WSADATA s_wsaData;
    WSAStartup( MAKEWORD(2,2), &s_wsaData );
#elif defined( __unix__ ) || defined( __APPLE__ ) || defined( __ANDROID__ )
    // Unix: 不需要显式初始化, close 关闭
#endif
```

**关键差异**:
| 项 | Windows | Linux |
|----|---------|-------|
| 错误码 | WSAGetLastError() | errno |
| socket 关闭 | closesocket | close |
| EWOULDBLOCK | WSAEWOULDBLOCK | EAGAIN |
| 连接拒绝 | WSAECONNRESET | ECONNREFUSED |
| 错误队列 | 不支持 | IP_RECVERR |

### 17.3 错误队列(Linux 专有)

Linux 支持 `IP_RECVERR` socket 选项,启用后 ICMP 错误(如"端口不可达")会被放入错误队列,而不是直接返回给下次 sendto。

```cpp
// endpoint.cpp
#if defined( __linux__ ) && !defined( EMSCRIPTEN )
    bool Endpoint::readFromErrorQueue( int & errNo, Address & addr, uint32 & info )
    {
        struct sockaddr_in sin;
        struct msghdr msg;
        char ctrl[1024];
        // ... recvmsg with MSG_ERRQUEUE
        // 解析 ICMP 错误,获取原始目标地址
    }
#endif
```

**为什么用错误队列**:UDP 是无连接的,sendto 不会等对方响应。但如果对方端口没开,ICMP "port unreachable" 错误会异步返回。错误队列让 Mercury 能知道"上次发送失败了"。

### 17.4 EventPoller 多路复用

`event_poller.cpp` 提供 3 种实现:

```cpp
class EventPoller { /* 抽象基类 */ };
class SelectPoller : public EventPoller { /* select() */ };
class PollPoller  : public EventPoller { /* poll() */ };
class EPoller     : public EventPoller { /* epoll (Linux) */ };
```

**create() 工厂**:

```cpp
EventPoller * EventPoller::create()
{
#if defined( __linux__ ) && !defined( EMSCRIPTEN )
    return new EPoller();      // Linux: epoll
#elif defined( _WIN32 )
    return new SelectPoller();  // Windows: select
#else
    return new PollPoller();   // 其他: poll
#endif
}
```

**性能对比**:
| 模型 | 时间复杂度 | 适合场景 |
|------|-----------|---------|
| select | O(n) | fd 数 < 64(Windows) |
| poll | O(n) | fd 数中等 |
| epoll | O(1) | fd 数大(>1000) |

BigWorld 一个进程通常只有 1-2 个 socket(socket 数量很少),所以 select 也够用。但 Linux 默认用 epoll 是为未来扩展(如 IOCP 集成)。

### 17.5 TCPChannel

`TCPChannel`(`tcp_channel.hpp`)是 TCP 版本的 channel,用于需要严格有序、流式传输的场景:

```cpp
class TCPChannel : public Channel
{
public:
    TCPChannel( NetworkInterface & networkInterface,
        const Address & address, Endpoint * pSocket = NULL,
        Traits traits = INTERNAL );
    ~TCPChannel();

    virtual void send( Bundle * pBundle );
    virtual bool hasUnackedPackets() const { return !unacked_.empty(); }

private:
    Endpoint * pSocket_;
    BW::list< PacketPtr > unacked_;
};
```

**特点**:
- 每个 TCPChannel 一个独立 TCP 连接(不像 UDPChannel 共享 socket)
- 利用 TCP 自己的可靠传输,不实现 ACK/重传
- `send` 直接把 bundle 数据写入 socket

**用途**:
- 大块数据传输(如 chunk 加载)
- 客户端 ↔ LoginApp 的初始通信(避免 UDP NAT 问题)

**为什么不全部用 TCP**:参见第二章 2.3 节,TCP 的队头阻塞、慢启动、连接管理开销不适合游戏实时消息。

### 17.6 EventDispatcher

`EventDispatcher`(`event_dispatcher.hpp`)是 Mercury 的事件中心:

```cpp
class EventDispatcher
{
public:
    void processContinuously();
    bool processOnce();

    int addFileDescriptor( int fd, InputNotificationHandler * handler );
    bool deregisterFileDescriptor( int fd );

    TimerHandle addTimer( int64 microseconds, TimerHandler * handler,
        void * pUser, const char * name );
    void cancelTimer( TimerHandle handle );

    TimerHandle addOnceOffTimer( int64 microseconds, TimerHandler * handler,
        void * pUser );

    // ...
};
```

**核心功能**:
- **文件描述符事件**:注册 fd,可读时回调
- **定时器**:周期性或一次性,微秒精度
- **任务队列**:可在下个 tick 执行任务

**processContinuously** 是主事件循环,进程的主线程通常跑在这里:

```cpp
while (running) {
    dispatcher.processOnce();
}
```

---

## 十八、性能分析

### 18.1 UDP vs TCP 性能对比

| 维度 | UDP(Mercury) | TCP |
|------|--------------|-----|
| 队头阻塞 | 无(可独立丢消息) | 严重 |
| 连接建立 | 无 | 3 次握手 |
| 可靠性开销 | 应用层 ACK/重传 | 内核 |
| 流量控制 | 简单窗口 | 复杂拥塞控制 |
| 多路复用 | 一个 socket 多 channel | 一个连接 |
| 内核缓冲区 | 共享 | 独立 |
| MTU 利用 | 1472 字节 | 1460 字节(MSS) |

**Mercury 的优势**:适合小消息密集、需要不可靠消息的场景。

### 18.2 Bundle 批量优化

Bundle 的**核心优化**是批量发送:
1. 多个小消息打包到一个 Bundle
2. 一个 Bundle 可能跨多个 Packet
3. 一次 sendto 发送一个 Packet

**收益**:
- 减少 sendto 系统调用次数(每次 ~1μs)
- 减少 packet header 开销(每 packet 16 字节 header)
- 增加 ACK 密度(每个 packet ACK 一次,但一个 packet 含多个消息)

**典型场景**:CellApp 一帧要发送 100 个位置更新,如果每条单独 sendto 是 100 次系统调用 + 100 个 packet header。用 Bundle 打包后可能只有 5-10 个 packet,5-10 次 sendto。

### 18.3 Channel 多路复用开销

一个 socket 承载 N 个 channel,每个 channel 独立维护:
- 滑动窗口状态
- 重传队列
- ACK 队列
- 序列号

**内存开销**:每 channel ~1KB 状态。1000 个 channel = 1MB,可接受。

**CPU 开销**:每 packet 路由到 channel 是 O(1) hash 查找。重传检查是 O(1) per channel,如果总 channel 数 N,则 O(N)。BigWorld 一个进程通常 < 100 channel,所以 O(N) 不是问题。

### 18.4 网络延迟分析

**典型 RTT**:
- 局域网:0.3-1ms
- 同城:5-20ms
- 跨国:100-300ms

**Mercury 的延迟优化**:
- **小 RTO**:初始 RTO 200ms,远小于 TCP 的 1 秒
- **快速重传**:不在窗口最前的包丢失,通过下次 ACK 触发重传
- **Piggyback**:减少 ACK 包数量,降低带宽和延迟

### 18.5 优化策略

1. **合并消息**:用 Bundle 打包多个小消息
2. **用 PASSENGER**:可靠消息搭车不可靠消息,省一次 ACK
3. **调整窗口**:大窗口提高吞吐,小窗口降低延迟
4. **关闭 checksum**:内部可信网络可禁用 checksum
5. **禁用 Nagle**:Mercury 默认就禁用类似 Nagle 的算法,立即发送
6. **buffer 大小**:增大 socket 收发缓冲区,避免 packet drop

---

## 十九、边界情况与故障处理

### 19.1 网络中断

**现象**:TCP 连接断开 / UDP 包持续丢失

**Mercury 处理**:
- Channel 持续收不到包,触发 inactivity timeout(默认 30 秒)
- 调用 `ChannelListener::onChannelInactivityTimeout`
- 标记 channel 为 dead,所有未决 request fail(REASON_INACTIVITY)
- 通知应用层(Base 析构、client 断开)

### 19.2 包丢失

**单包丢失**:RTO 触发重传,业务无感知(仅 RTT 升高)
**连续丢失**:窗口前移缓慢,吞吐下降,但不会死锁
**全丢失**:inactivity timeout,channel dead

### 19.3 包乱序

UDP 不保证顺序,Mercury 用 seq + 接收窗口重组:
- 收到 seq=5,但 expected seq=3,缓存 seq=5
- 收到 seq=3、4,处理 3、4、5
- 收到 seq=7、8 但缺 6,缓存 7、8,等 6

**`CircularArray`** 实现接收窗口,2 的幂大小,索引用 `seq & (size-1)`。

### 19.4 重复包

可能因 ACK 丢失导致对端重传,产生重复包。Mercury 用 `seqMask` 判断:
- `seqLessThan(seq, lastProcessed_)` 表示是旧包,丢弃
- 在 lastProcessed 之后的,加入 receive window

### 19.5 包损坏

**Checksum 校验**:`FLAG_HAS_CHECKSUM` 时,packet 含 16 位 checksum。损坏则 `REASON_CORRUPTED_PACKET`,丢弃整个 packet。

**为什么不是每包都校验**:UDP header 已有 checksum(16 位),但应用层 checksum 提供额外保障(防止 UDP checksum 在某些 NIC 上 offload 错误)。BigWorld 内部网络可关闭以省 CPU。

### 19.6 拥塞崩溃

**问题**:如果所有 channel 同时大量发送,导致 packet drop,所有 channel 都重传,进一步加剧拥塞,最终吞吐崩塌。

**Mercury 的应对**:
- **窗口大小固定**:不像 TCP 动态调整,但靠 inactivity timeout 防止单 channel 占用过多
- **RELIABLE_CRITICAL**:关键消息 bypass 拥塞控制,确保控制信令可达
- **rate limit**:外部接口限流,防 DDoS

**局限**:Mercury 没有 TCP 那种精细的拥塞控制,假设网络不会过载。在 100Mbps 局域网这是合理的,但跨广域网时需要注意。

### 19.7 进程崩溃

**发送方崩溃**:接收方 channel 检测 inactivity,30 秒后 fail
**接收方崩溃**:发送方持续重传,直到 RTO 超时,channel fail

**Reviver 接管**:Reviver 检测到进程崩溃,启动新进程,新进程从 DBApp 加载状态,通知其他进程"我接管了 channel X"。

### 19.8 序列号回绕

28 位序列号,以 1000 packet/s 速度,约 30 小时回绕一次。回绕时:
- 旧连接的 stale packet 可能在新连接中看似"未来"包
- `seqLessThan` 仍能正确判断
- 但跨 channel 重启(新 channel 复用旧地址)时,可能误判

**channel version 机制**:每个 channel 有 `ChannelVersion`,握手时交换,用于区分"同地址的新 channel"和"旧 channel 的 stale packet"。

---

## 二十、与其他引擎对比

### 20.1 vs TCP

| 特性 | Mercury | TCP |
|------|---------|-----|
| 可靠性 | 应用层实现 | 内核实现 |
| 顺序 | 可选(channel 内有序) | 严格有序 |
| 队头阻塞 | 无 | 有 |
| 拥塞控制 | 简单(固定窗口) | 复杂(cubic, BBR) |
| 多路复用 | 一个 socket 多 channel | 一个连接 |
| 连接管理 | 无连接 | 三次握手 + 状态机 |
| 适用场景 | 游戏实时通信 | 文件传输、Web |

**Mercury 优势**:游戏场景的低延迟、不可靠消息支持、多 channel 复用
**TCP 优势**:内核优化、广泛兼容、强拥塞控制

### 20.2 vs QUIC

QUIC(Google 设计,HTTP/3 基础)是现代化的 UDP-based 协议:

| 特性 | Mercury | QUIC |
|------|---------|------|
| 年代 | 2000s | 2010s |
| 加密 | 应用层(可选) | TLS 1.3 强制 |
| 多路复用 | Channel | Stream |
| 0-RTT | 无 | 有 |
| 拥塞控制 | 简单 | CUBIC/BBR |
| 连接迁移 | 有限(channel version) | 完整(connection ID) |
| 标准化 | BigWorld 私有 | IETF 标准 |

**Mercury 局限**:无现代加密、无 0-RTT、无标准拥塞控制
**Mercury 优势**:简单、轻量、专为游戏优化

### 20.3 vs ENet

ENet 是另一个游戏向 UDP 库:

| 特性 | Mercury | ENet |
|------|---------|------|
| 可靠等级 | 4 种(NO/DRIVER/PASSENGER/CRITICAL) | 3 种(unreliable/reliable/unsequenced) |
| 通道 | Channel(任意数量) | Channel(最多 255) |
| 请求-响应 | 内置 | 无 |
| 接口定义 | InterfaceElement + 宏 | 无(用户自定义) |
| 跨平台 | Windows/Linux/PS3/X360 | 多平台 |

**Mercury 优势**:请求-响应模式、InterfaceElement 接口定义、与 BigWorld 紧密集成
**ENet 优势**:更轻量、社区维护活跃

### 20.4 vs RakNet

RakNet 是另一个游戏向网络库(已被 Oculus 收购并开源):

| 特性 | Mercury | RakNet |
|------|---------|--------|
| 语言 | C++ | C++ |
| 拓扑 | 点对点 + bwmachined | 客户端-服务器 + P2P |
| RPC | InterfaceElement | RPC 宏 |
| 加密 | 可选 | 内置 |
| NAT 穿透 | 无 | 完整 |
| 文件传输 | 无 | 内置 |
| 适用场景 | MMO 服务器集群 | 游戏客户端-服务器 |

**Mercury 优势**:专为 MMO 集群设计、与 bwmachined 配合
**RakNet 优势**:功能更全(NAT、文件传输)、客户端友好

### 20.5 vs Photon

Photon 是商业游戏网络引擎:

| 特性 | Mercury | Photon |
|------|---------|--------|
| 开源 | 是 | 否 |
| 语言 | C++ | C# / C++ |
| 部署 | 自建 | 云服务 |
| 收费 | 免费 | 按用户数 |
| 性能 | 高(集群) | 中(云端) |

**Mercury 优势**:开源、自部署、性能可控
**Photon 优势**:开箱即用、无需运维

### 20.6 综合对比

| 引擎 | 设计年代 | 主要场景 | 强项 | 弱项 |
|------|---------|---------|------|------|
| Mercury | 2000s | MMO 服务器集群 | 游戏向、轻量、集群优化 | 无现代加密、无标准拥塞控制 |
| TCP | 1970s | 通用 | 标准化、内核优化 | 队头阻塞、连接开销 |
| QUIC | 2010s | Web | 0-RTT、加密、多路复用 | 复杂、依赖 TLS |
| ENet | 2000s | 游戏客户端 | 轻量、跨平台 | 功能少 |
| RakNet | 2000s | 游戏客户端-服务器 | 功能全、NAT 穿透 | 复杂、Oculus 后维护减弱 |
| Photon | 2010s | 云游戏 | 开箱即用 | 闭源、按量付费 |

---

## 二十一、总结与最佳实践

### 21.1 Mercury 的核心价值

Mercury 是 **BigWorld 集群的血管系统**,其核心价值:
1. **游戏向优化**:小消息密集、低延迟、不可靠消息支持
2. **集群友好**:多 channel 复用、bwmachined 集成
3. **请求-响应**:内置 RPC 模式,简化应用层
4. **可定制可靠等级**:4 种等级适配不同消息类型
5. **跨平台**:Windows/Linux/PS3/X360

### 21.2 最佳实践

#### 发送消息
```cpp
// 1. 普通(不可靠)消息
bundle.startMessage( interface.ele.onTick );
bundle << position;
channel.send();

// 2. 可靠消息
bundle.startMessage( interface.ele.teleport, RELIABLE_DRIVER );
bundle << destPos;
channel.send();

// 3. 请求-响应
bundle.startRequest( interface.ele.queryStats, this, 5 /*seconds*/ );
bundle << entityId;
channel.send();
// 实现 onReplyMessage 回调
```

#### channel 管理
- **复用 channel**:UDPChannel::get 走池,避免重复创建
- **及时 condemn**:不用的 channel 立即 condemn,释放资源
- **监听 inactivity**:继承 ChannelListener,处理超时
- **不依赖包顺序**:跨 channel 不保证顺序,业务要幂等

#### 性能优化
- **用 Bundle 批量**:一帧的消息打包
- **PASSENGER 模式**:可靠消息搭不可靠车
- **调整 buffer**:增大 socket buffer,避免 drop
- **关闭 checksum**:内部可信网络

### 21.3 常见陷阱

1. **ReplyID 泄漏**:Request 没正确 finish,reply ID 永不回收
2. **channel 泄漏**:忘记 condemn,channel 永远不销毁
3. **piggyback 滥用**:大数据搭车导致 packet 过大,被分片
4. **inactivity timeout 太短**:正常网络波动被误判为 dead
5. **Bundle 中途 startMessage**:多消息混合,但顺序错误导致解析失败
6. **跨平台字节序**:struct 直接 memcpy,大端小端不兼容

### 21.4 调试技巧

- **VERBOSE 模式**:`verbosityLevel(VERBOSITY_LEVEL_DEBUG)` 输出详细日志
- **Watcher**:通过 bwwatcher 工具查看 channel 状态、消息统计
- **PacketMonitor**:注入自定义监控,捕获每个 packet
- **PacketLossParameters**:模拟丢包,测试可靠性
- **setLatency**:模拟延迟,测试 RTT 算法

### 21.5 与 BigWorld 整体的关系

Mercury 是 BigWorld 的网络基石:
- **Mailbox 通信**(专题5)基于 Mercury channel
- **Ghost 同步**(专题1)用 Mercury 发送 haunt 消息
- **AOI 更新**(专题6)用 Mercury 发送位置和事件
- **Reviver 守护**(专题12)用 MachineGuard 协议
- **JIT 编译**(专题8)的命名管道是另一回事,但 process 控制走 Mercury

理解 Mercury 是理解 BigWorld 整体架构的关键,本专题为后续专题的网络层基础。

---

## 附录 A:关键文件索引

| 路径 | 行数(约) | 说明 |
|------|----------|------|
| `programming/bigworld/lib/network/endpoint.hpp` | 250 | Endpoint 类声明 |
| `programming/bigworld/lib/network/endpoint.cpp` | 600 | Endpoint 实现(平台差异) |
| `programming/bigworld/lib/network/endpoint.ipp` | 50 | Inline 实现 |
| `programming/bigworld/lib/network/packet.hpp` | 300 | Packet 类声明 |
| `programming/bigworld/lib/network/packet.cpp` | 700 | Packet 实现 |
| `programming/bigworld/lib/network/channel.hpp` | 200 | Channel 抽象基类 |
| `programming/bigworld/lib/network/channel.cpp` | 250 | Channel 实现 |
| `programming/bigworld/lib/network/udp_channel.hpp` | 350 | UDPChannel 声明 |
| `programming/bigworld/lib/network/udp_channel.cpp` | 1500 | UDPChannel 实现(核心) |
| `programming/bigworld/lib/network/tcp_channel.hpp` | 100 | TCPChannel 声明 |
| `programming/bigworld/lib/network/tcp_channel.cpp` | 200 | TCPChannel 实现 |
| `programming/bigworld/lib/network/bundle.hpp` | 250 | Bundle 抽象基类 |
| `programming/bigworld/lib/network/bundle.cpp` | 400 | Bundle 实现 |
| `programming/bigworld/lib/network/udp_bundle.hpp` | 150 | UDPBundle 声明 |
| `programming/bigworld/lib/network/udp_bundle.cpp` | 800 | UDPBundle 实现 |
| `programming/bigworld/lib/network/basictypes.hpp` | 150 | Address 等基础类型 |
| `programming/bigworld/lib/network/misc.hpp` | 200 | SeqNum/Reason 等 |
| `programming/bigworld/lib/network/msgtypes.hpp` | 100 | PackedYaw 等紧凑类型 |
| `programming/bigworld/lib/network/interface_element.hpp` | 350 | InterfaceElement |
| `programming/bigworld/lib/network/interface_macros.hpp` | 200 | 接口定义宏 |
| `programming/bigworld/lib/network/interface_minder.hpp` | 100 | InterfaceMinder |
| `programming/bigworld/lib/network/interface_table.hpp` | 100 | InterfaceTable |
| `programming/bigworld/lib/network/network_interface.hpp` | 350 | NetworkInterface 声明 |
| `programming/bigworld/lib/network/network_interface.cpp` | 1200 | NetworkInterface 实现 |
| `programming/bigworld/lib/network/event_dispatcher.hpp` | 300 | EventDispatcher |
| `programming/bigworld/lib/network/event_poller.hpp` | 100 | EventPoller 抽象 |
| `programming/bigworld/lib/network/event_poller.cpp` | 400 | SelectPoller/PollPoller/EPoller |
| `programming/bigworld/lib/network/request.hpp` | 70 | Request 声明 |
| `programming/bigworld/lib/network/request.cpp` | 130 | Request 实现 |
| `programming/bigworld/lib/network/fragmented_bundle.hpp` | 120 | FragmentedBundle 声明 |
| `programming/bigworld/lib/network/fragmented_bundle.cpp` | 200 | FragmentedBundle 实现 |
| `programming/bigworld/lib/network/channel_owner.hpp` | 55 | ChannelOwner |
| `programming/bigworld/lib/network/machine_guard.hpp` | 980 | MachineGuard 完整体系 |
| `programming/bigworld/lib/network/machine_guard.cpp` | 1200 | MachineGuard 实现 |
| `programming/bigworld/lib/network/portmap.hpp` | 35 | 端口定义 |
| `programming/bigworld/lib/network/netmask.hpp` | 50 | NetMask |
| `programming/bigworld/lib/network/netmask.cpp` | 80 | NetMask 实现 |
| `programming/bigworld/lib/network/circular_array.hpp` | 200 | CircularArray 模板 |
| `programming/bigworld/lib/network/unacked_packet.hpp` | 80 | UnackedPacket |
| `programming/bigworld/lib/network/reliable_order.hpp` | 100 | ReliableOrder |
| `programming/bigworld/lib/network/unpacked_message_header.hpp` | 80 | UnpackedMessageHeader |
| `programming/bigworld/lib/network/packet_receiver.hpp` | 100 | PacketReceiver 声明 |
| `programming/bigworld/lib/network/packet_receiver.cpp` | 600 | PacketReceiver 实现 |
| `programming/bigworld/lib/network/packet_sender.hpp` | 60 | PacketSender 声明 |
| `programming/bigworld/lib/network/packet_filter.hpp` | 70 | PacketFilter |
| `programming/bigworld/lib/network/address_resolver.hpp` | 25 | AddressResolver |
| `programming/bigworld/lib/network/net_360.hpp` | 50 | Xbox 360 支持 |

---

## 附录 B:Packet 标志位一览

`Packet::Flags`(`packet.hpp`):

| 标志 | 值 | 含义 |
|------|---|------|
| FLAG_HAS_CHECKSUM | 0x01 | 包含 16 位 checksum |
| FLAG_HAS_RELIABLE | 0x02 | 包含可靠消息(有序) |
| FLAG_HAS_ACKS | 0x04 | 包含 ACK 列表 |
| FLAG_IS_PIGGYBACK | 0x08 | 是 piggyback 子包 |
| FLAG_HAS_CUMULATIVE_ACK | 0x10 | 包含累积 ACK |
| FLAG_IS_FRAGMENT | 0x20 | 是分片 bundle 的一部分 |
| FLAG_HAS_MORE_FRAGMENTS | 0x40 | 后续还有分片 |
| FLAG_HAS_INDEX | 0x80 | 使用 indexed channel |

**组合语义**:
- `0x00`:普通不可靠消息包
- `0x02`:可靠消息包(单 channel)
- `0x06`:可靠消息 + ACK 捎带
- `0x20`:分片包(首片或中间)
- `0x60`:分片包(非最后一片)
- `0xA0`:分片包(最后一片,FLAG_HAS_MORE_FRAGMENTS 清零)
- `0x28`:piggyback 子包(可靠)

---

## 附录 C:Reason 错误码一览

`Mercury::Reason`(`misc.hpp:137-153`):

| 错误码 | 值 | 含义 | 触发场景 |
|--------|---|------|----------|
| REASON_SUCCESS | 0 | 成功 | 正常路径 |
| REASON_TIMER_EXPIRED | -1 | 定时器超时 | Request 超时、OnceOff 重发耗尽 |
| REASON_NO_SUCH_PORT | -2 | 目标端口未开 | sendto 后收到 ICMP port unreachable |
| REASON_GENERAL_NETWORK | -3 | 网络故障 | recvfrom 错误、unknown WSA error |
| REASON_CORRUPTED_PACKET | -4 | 包损坏 | checksum 校验失败 |
| REASON_NONEXISTENT_ENTRY | -5 | 调用空函数 | InterfaceTable 没注册对应 handler |
| REASON_WINDOW_OVERFLOW | -6 | 窗口溢出 | 发送窗口满,新包无法入队 |
| REASON_INACTIVITY | -7 | 不活跃超时 | channel 长时间无通信 |
| REASON_RESOURCE_UNAVAILABLE | -8 | 资源不可用 | EAGAIN(socket buffer 满) |
| REASON_CLIENT_DISCONNECTED | -9 | 客户端主动断开 | 收到 goodbye 消息 |
| REASON_TRANSMIT_QUEUE_FULL | -10 | 发送队列满 | ENOBUFS |
| REASON_CHANNEL_LOST | -11 | channel 丢失 | channel 销毁时未决 request |
| REASON_SHUTTING_DOWN | -12 | 应用关闭 | prepareForShutdown |
| REASON_MESSAGE_TOO_LONG | -13 | 消息过长 | EMSGSIZE(超 MTU) |

**`reasonToString`** 转字符串,用于日志和调试。

---

## 附录 D:术语表

| 术语 | 英文 | 含义 |
|------|------|------|
| 端点 | Endpoint | socket 抽象层 |
| 数据包 | Packet | UDP 数据报,Mercury 的传输单元 |
| 通道 | Channel | 逻辑连接,承载有序消息 |
| UDP 通道 | UDPChannel | 基于 UDP 的可靠通道 |
| TCP 通道 | TCPChannel | 基于 TCP 的通道 |
| 包裹 | Bundle | 消息序列化容器 |
| UDP 包裹 | UDPBundle | UDP 上的 Bundle 实现 |
| 序列号 | SeqNum | 28 位,标识 packet 顺序 |
| 回复 ID | ReplyID | 请求-响应配对标识 |
| 通道 ID | ChannelID | indexed channel 标识 |
| 通道版本 | ChannelVersion | 区分同地址的不同 channel 实例 |
| 确认 | ACK | 已收到的 packet 确认 |
| 累积确认 | Cumulative ACK | "到此 seq 之前的都收到" |
| 捎带 | Piggyback | 把小包附在大包上发 |
| 重传超时 | RTO | 重传等待时间 |
| 往返时间 | RTT | 一次发送到收到 ACK 的时间 |
| 滑动窗口 | Sliding Window | 限制在途 packet 数量 |
| 不活跃超时 | Inactivity Timeout | channel 长时间无通信的超时 |
| 接口元素 | InterfaceElement | 消息元数据 |
| 接口管理器 | InterfaceMinder | 管理一组 InterfaceElement |
| 接口表 | InterfaceTable | NetworkInterface 持有的消息表 |
| 网络接口 | NetworkInterface | 顶层网络接口 |
| 事件分发器 | EventDispatcher | 事件循环 |
| 事件轮询器 | EventPoller | IO 多路复用 |
| 请求 | Request | 请求-响应模式 |
| 请求管理器 | RequestManager | 管理 ReplyID 到 Request 映射 |
| 分片包裹 | FragmentedBundle | 跨多 packet 的大 bundle 重组 |
| 通道所有者 | ChannelOwner | RAII 包装的 channel 持有者 |
| 机器守护 | MachineGuard | bwmachined 协议 |
| 包接收器 | PacketReceiver | 接收 packet 并分发 |
| 包发送器 | PacketSender | 发送 packet |
| 包过滤器 | PacketFilter | packet 过滤(如加密) |
| 网络掩码 | NetMask | 子网判断 |
| 端口映射 | PortMap | 固定端口定义 |
| 通道监听器 | ChannelListener | channel 事件回调 |
| 不活跃通道 | Irregular Channel | 长时间无通信的 channel |
| 已谴责通道 | Condemned Channel | 待销毁的 channel |
| 保活通道 | KeepAlive Channel | 需要 ping 维持的 channel |
| 已死亡通道 | Recently Dead Channel | 最近死亡的 channel(防重连伪装) |
| 延迟通道 | Delayed Channel | 推迟发送的 channel |
| 通道查找器 | ChannelFinder | indexed channel 查找策略 |
| 速率限制 | Rate Limit | 防 DDoS 的包速率限制 |
| 一次性发送器 | OnceOffSender | 无 channel 的可靠发送 |

---

> **专题结语**:Mercury 是 BigWorld 集群通信的核心,其设计反映了 2000 年代游戏服务器架构的特点:轻量、游戏向优化、跨平台。理解 Mercury 的可靠 UDP 算法、Bundle 序列化、Channel 多路复用、Request 请求-响应等机制,是理解 BigWorld 整体架构的关键。本专题为后续的 Ghost 同步、Mailbox 通信、AOI 系统等专题提供了网络层基础。

> **参考资料**:
> - BigWorld Engine 14.4.1 源码 `programming/bigworld/lib/network/`
> - BigWorld 启动流程分析 `docs/BigWorld启动流程分析.md`
> - 配套专题:专题1 Ghost 同步、专题5 Mailbox 通信、专题6 AOI 系统、专题12 Reviver 守护

---

*专题版本:1.0*
*更新日期:2026-07-05*
*引擎版本:BigWorld Engine 14.4.1 Open-Source Edition*