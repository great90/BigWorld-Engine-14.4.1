# 第5章 网络通信层 - network

> 网络是 MMOG 的"血脉":一个CellApp 上成千上万的实体要每秒几十次地与 BaseApp、其他 CellApp、客户端交换状态,登录请求要跨越公网,服务器集群要在 bwmachined 的监控下协同重启。BigWorld 把这一切归拢到一个独立的库 `lib/network/` 中,并以 `Endpoint → Packet → Bundle → Channel` 的四层抽象,在裸 UDP 之上实现了一套可定制、可靠、有序、有流控的消息系统,代号 **Mercury**(希腊神话中的信使之神)。
>
> 本章面向熟悉 C++/Python 但初次接触 BigWorld 的开发者,从 UDP 与可靠传输的基本概念讲起,逐层剖析 Mercury 的实现细节,直到你能独立读懂、调试和扩展它。

---

## 目录

- [5.1 network 库概述](#51-network-库概述)
- [5.2 核心抽象三件套:Endpoint / Packet / Channel](#52-核心抽象三件套endpoint--packet--channel)
- [5.3 Bundle 消息序列化](#53-bundle-消息序列化)
- [5.4 消息类型与接口系统](#54-消息类型与接口系统)
- [5.5 可靠 UDP 实现细节](#55-可靠-udp-实现细节)
- [5.6 流量控制与背压](#56-流量控制与背压)
- [5.7 请求-响应模式与特殊机制](#57-请求-响应模式与特殊机制)
- [5.8 跨平台与 IO 模型](#58-跨平台与-io-模型)
- [5.9 网络层在引擎中的应用](#59-网络层在引擎中的应用)
- [5.10 特色实现深度剖析](#510-特色实现深度剖析)
- [5.11 本章小结](#511-本章小结)

---

## 5.1 network 库概述

### 5.1.1 位置与职责

`network` 库位于 `programming/bigworld/lib/network/`,是 BigWorld 引擎中所有进程间通信(IPC)与客户端通信的统一基础。无论是:

- CellApp ↔ CellAppMgr ↔ BaseAppMgr ↔ DBApp 之间的服务器内部通信;
- 客户端 ↔ BaseApp 之间跨越公网的实体同步;
- LoginApp 处理登录认证流量;
- bwmachined 监控各进程的心跳与控制指令;

最终都会落到这个库上。

它的职责可以概括为四点:

1. **进程间通信**——在任意两个网络地址之间建立逻辑通道,支持双向消息收发;
2. **客户端连接**——支持高延迟、高丢包、低带宽的公网环境,与服务器集群低延迟、高带宽环境使用同一套抽象但不同策略;
3. **可靠消息传输**——在不可靠的 UDP 之上实现可靠、有序、有流控的消息流;
4. **消息序列化**——把多条消息打包成一个或多个 UDP 报文,在减少 syscall 的同时支持分片与重组。

### 5.1.2 设计理念

Mercury 在设计上有四条贯穿始终的原则:

| 原则 | 含义 | 体现 |
|---|---|---|
| **UDP 优先** | 公网游戞性能要求 P99 延迟低于 100ms,TCP 的重传阻塞会拖垮整条流 | 自研可靠 UDP,序号 + ACK + 重传,而非 `SOCK_STREAM` |
| **批量优先** | 每个 syscall 都昂贵,UDP 包大小固定 1472 字节,能塞多少消息塞多少 | `Bundle` 把多消息打包,`Channel` 自动分片 |
| **抽象分层** | 同一套接口既跑 UDP 也跑 TCP,既跑内部也跑外部 | `Channel` 抽象基类,`UDPChannel`/`TCPChannel` 两个具体子类 |
| **零拷贝倾向** | 数据写入位置就是网络发送缓冲,避免反复 memcpy | `Packet::data_` 是定长字符数组,`Bundle::reserve` 直接返回写入指针 |

### 5.1.3 为什么不用 TCP

这是新手最常问的问题。BigWorld 选择 UDP + 自研可靠层,主要基于以下考量:

1. **TCP 的队头阻塞(Head-of-Line Blocking)**:TCP 保证字节流有序,一个包丢了,后续到达的包都会被卡在内核缓冲里直到重传完成。游戏中一个丢包可能阻塞后续 30 帧的位置更新,这是不可接受的。
2. **TCP 的拥塞控制过于激进**:TCP 默认 Reno/CUBIC 拥塞控制会因偶尔丢包大幅降窗,而游戏流量是周期性、可预测的,不需要也不应使用通用 Web 流量的拥塞策略。
3. **TCP 不能丢弃过时数据**:游戏中"上一次"位置更新如果迟到,直接丢弃比按时序到达更合理。UDP 让上层自己决定,而 TCP 强制按字节交付。
4. **TCP 不能多路复用**:一个 TCP 连接一条流,无法把多个逻辑通道复用到一个 socket 上(虽然有 SO_REUSEPORT,但语义不同)。Mercury 的 indexed channel 机制允许在同一 UDP socket 上跑无数条独立逻辑流。

**例外**:对于必须保证字节流有序的场景(例如 Python 调试通道、WebSocket 客户端、跨集群的 BaseApp↔BaseApp 重连),Mercury 也提供了 `TCPChannel`(见 `tcp_channel.hpp`)。在 1.4 版之后,客户端到 BaseApp 也支持 TCP/WebSocket 回退。

### 5.1.4 文件清单速览

`lib/network/` 目录下大约 150 个文件,可以按功能归类如下(仅列关键文件):

```
lib/network/
├── endpoint.hpp / .cpp / .ipp            # socket 包装层
├── packet.hpp / .cpp                     # 单个 UDP 数据包
├── channel.hpp / .cpp / .ipp              # 逻辑通道抽象基类
├── udp_channel.hpp / .cpp / .ipp          # UDP 可靠通道实现
├── tcp_channel.hpp / .cpp                 # TCP 通道实现
├── bundle.hpp / .cpp / .ipp               # 消息序列化容器(抽象)
├── udp_bundle.hpp / .cpp / .ipp           # UDP 版 Bundle
├── tcp_bundle.hpp / .cpp                  # TCP 版 Bundle
├── msgtypes.hpp / .ipp                    # 消息相关类型与位压缩
├── interface_element.hpp / .cpp          # 单个消息描述(长度/ID/处理器)
├── interface_table.hpp / .cpp             # 消息表(ID → InterfaceElement)
├── interface_macros.hpp                   # 消息定义宏
├── interface_minder.hpp / .ipp            # 接口注册器
├── request.hpp / .cpp                    # 请求-响应封装
├── request_manager.hpp / .cpp            # 请求管理器
├── network_interface.hpp / .cpp / .ipp    # 顶层网络接口(一个进程通常一个)
├── event_dispatcher.hpp / .ipp            # 事件循环(主循环核心)
├── event_poller.hpp / .cpp                # IO 多路复用封装(select/epoll)
├── packet_receiver.hpp / .ipp / .cpp      # 收包器
├── packet_sender.hpp / .cpp               # 发包器
├── portmap.hpp                            # 端口分配常量
├── netmask.hpp / .cpp                    # 网络掩码
├── misc.hpp                              # SeqNum/Reason/MessageID 等杂项
├── machine_guard.hpp / .cpp              # 与 bwmachined 通信协议
├── net_360.hpp / .cpp                    # Xbox 360 历史遗留
├── block_cipher.hpp / .ipp               # 加密接口
├── encryption_filter.hpp / .cpp          # 加密过滤器
├── websocket_stream_filter.hpp / .cpp    # WebSocket 支持
└── unit_test/                            # 单元测试(非常完整)
```

读者可以通过 `LS lib/network/` 看到完整列表。本章会按"由内向外"的顺序展开:先讲 socket 包装(`Endpoint`),再讲数据格式(`Packet`),然后是消息容器(`Bundle`)、逻辑通道(`Channel`),最后是组装它们的 `NetworkInterface` 和上层应用。

---

## 5.2 核心抽象三件套:Endpoint / Packet / Channel

### 5.2.1 Endpoint:socket 的薄封装

`Endpoint`(见 `endpoint.hpp` / `endpoint.cpp` / `endpoint.ipp`)是最底层的类,它把一个 BSD socket 句柄封装成 C++ 对象。所有跨平台差异在这一层被吸收。

**核心成员**(见 `endpoint.hpp:85-204`):

```cpp
class Endpoint
{
public:
    Endpoint();
    ~Endpoint();

    static const socket_t NO_SOCKET = static_cast<socket_t>(-1);

    int fileno() const;
    void setFileDescriptor(socket_t fd);
    bool good() const;

    void socket( int type );          // SOCK_STREAM 或 SOCK_DGRAM
    int setnonblocking( bool nonblocking );
    int setbroadcast( bool broadcast );
    int setreuseaddr( bool reuseaddr );
    int bind( u_int16_t networkPort = 0, u_int32_t networkAddr = INADDR_ANY );
    INLINE int close();
    INLINE int detach();

    // 连接无关(UDP)
    INLINE int sendto( void * gramData, int gramSize,
        u_int16_t networkPort, u_int32_t networkAddr = BROADCAST) const;
    INLINE int sendto( void * gramData, int gramSize,
        const Mercury::Address & addr ) const;
    INLINE int recvfrom( void * gramData, int gramSize,
        u_int16_t * networkPort, u_int32_t * networkAddr ) const;
    INLINE int recvfrom( void * gramData, int gramSize,
        Mercury::Address & addr ) const;

    // 连接导向(TCP)
    int listen( int backlog = 5 );
    int connect( u_int16_t networkPort, u_int32_t networkAddr = BROADCAST );
    Endpoint * accept(...);
    INLINE int send( const void * gramData, int gramSize ) const;
    int recv( void * gramData, int gramSize ) const;

private:
    socket_t socket_;
};
```

**跨平台要点**:

1. **socket 类型别名**:Windows 上 `SOCKET` 是无符号指针,Unix 上是 `int`。`endpoint.hpp:48-76` 用条件编译统一为 `socket_t`:

```cpp
#ifdef PLAYSTATION3
    typedef int socket_t;
#else // Windows
    typedef int socklen_t;
    typedef u_short u_int16_t;
    typedef u_long u_int32_t;
    typedef SOCKET socket_t;
#else // Unix/Apple/Android
    typedef int socket_t;
#endif
```

2. **非阻塞设置**:`setnonblocking` 在 Unix 用 `fcntl(F_SETFL, O_NONBLOCK)`,Windows 用 `ioctlsocket(FIONBIO)`,PS3 用 `setsockopt(SO_NBIO)`(见 `endpoint.ipp:99-113`)。

3. **关闭 socket**:`close()` 在 Unix 调 `::close`,Windows 调 `::closesocket`,PS3 调 `::socketclose`(见 `endpoint.ipp:216-237`)。

4. **Winsock 初始化**:Windows 上 socket 创建可能因为 WSA 未初始化而失败,`Endpoint::socket` 会自动检测 `WSANOTINITIALISED` 并调用 `initNetwork()` 重试(`endpoint.ipp:76-90`)。这个 `initNetwork()` 在 `endpoint.hpp:206` 声明,负责 `WSAStartup`。

5. **网络字节序**:`Address` 内部存的 `ip`/`port` 都是网络字节序,所以 `sendto` 直接 `memcpy` 到 `sockaddr_in`,不需要 `htonl/htons` 再转一次。

**Mercury::Address 类**:`basictypes.hpp:271-304` 定义了 Mercury 的地址类:

```cpp
class Address
{
public:
    Address();
    Address( uint32 ipArg, uint16 portArg );

    uint32  ip;     ///< IP 地址(网络字节序)
    uint16  port;   ///< 端口(网络字节序)
    uint16  salt;   ///< 每次重连都不同的随机值

    static const Address NONE;
};
```

注意 `salt` 字段——这是 Mercury 用来识别"同一次会话"的机制。如果客户端断线重连,salt 变化,服务器可以判断这是新连接而非旧连接的延迟包。`EntityMailBoxRef` 进一步利用 `salt` 的高 3 位编码"组件类型"(CELL/BASE/CLIENT/...),低 13 位编码实体类型,这是 Mailbox 系统的网络基础(见 `basictypes.hpp:328-356`)。

### 5.2.2 Packet:单个 UDP 数据包

`Packet`(见 `packet.hpp:50-360`)是网络上一个 UDP 报文在内存中的表示。BigWorld 把 UDP 包大小固定为 1472 字节:

```cpp
#define PACKET_MAX_SIZE 1472  // packet.hpp:9
```

这个值是 **MTU 1500 - IP 头 20 - UDP 头 8 = 1472**,确保在以太网上不会分片。

**内存布局**:`Packet` 是一个固定大小的对象,数据区是嵌入式数组:

```cpp
class Packet : public ReferenceCount
{
private:
    PacketPtr  next_;                // 链表下一个包(分片用)
    int        msgEndOffset_;        // 消息数据结束偏移
    int        footerSize_;          // 已写入的尾部大小
    int        extraFilterSize_;     // 过滤器预留
    Offset     firstRequestOffset_;  // 第一个请求位置
    Offset *   pLastRequestOffset_;  // 最后请求的 next 链
    AckCount   nAcks_;               // 携带的 ACK 数
    Field      piggyFooters_;        // 搭载(piggyback)的尾部
    SeqNum     seq_;                 // 包序号
    ChannelID  channelID_;           // 索引通道 ID
    ChannelVersion channelVersion_;  // 通道版本号
    SeqNum     fragBegin_;           // 分片起始序号
    SeqNum     fragEnd_;             // 分片结束序号
    bool       isPiggyback_;
    Checksum   checksum_;
    char       data_[PACKET_MAX_SIZE]; // 实际网络数据
};
```

**Header**:包头只有 2 字节,即一个 `Flags` 字段(`packet.hpp:58`)。每个 bit 对应一个 footer 是否存在:

```cpp
enum
{
    FLAG_HAS_REQUESTS         = 0x0001,  // 包内有请求(带 replyID)
    FLAG_HAS_PIGGYBACKS       = 0x0002,  // 搭载了别通道的包
    FLAG_HAS_ACKS             = 0x0004,  // 尾部有 ACK 列表
    FLAG_ON_CHANNEL           = 0x0008,  // 属于某条 channel
    FLAG_IS_RELIABLE          = 0x0010,  // 需要可靠传输
    FLAG_IS_FRAGMENT          = 0x0020,  // 这是一个分片
    FLAG_HAS_SEQUENCE_NUMBER  = 0x0040,  // 带序号(可靠包都带)
    FLAG_INDEXED_CHANNEL      = 0x0080,  // 索引通道(多路复用)
    FLAG_HAS_CHECKSUM         = 0x0100,  // 带校验和
    FLAG_CREATE_CHANNEL       = 0x0200,  // 创建匿名通道
    FLAG_HAS_CUMULATIVE_ACK   = 0x0400,  // 累积 ACK(单个 SeqNum)
    KNOWN_FLAGS                = 0x07FF
};
```

**Footer 机制**:Mercury 的 Packet 是"头固定 + 体可变 + 尾反方向生长"的结构。消息体从 `HEADER_SIZE` 向后写,footers 从 `PACKET_MAX_SIZE` 向前写。`RESERVED_FOOTER_SIZE`(27 字节)预先为所有可能的 footer 预留空间,这样 bundle 写消息时不会因为 footer 装不下而需要重新分配(`packet.hpp:104-110`):

```cpp
static const int RESERVED_FOOTER_SIZE =
    sizeof( Offset ) +          // FLAG_HAS_REQUESTS: 第一个请求偏移
    sizeof( AckCount ) +        // FLAG_HAS_ACKS: ACK 数量
    sizeof( SeqNum ) +           // FLAG_HAS_SEQUENCE_NUMBER: 序号
    sizeof( SeqNum ) * 2 +       // FLAG_IS_FRAGMENT: fragBegin/fragEnd
    sizeof( ChannelID ) + sizeof( ChannelVersion ) + // FLAG_INDEXED_CHANNEL
    sizeof( Checksum );         // FLAG_HAS_CHECKSUM
```

**写入 footer**:用 `packFooter<T>` 从尾部向前写,自动处理字节序(`packet.hpp:246-265`):

```cpp
template <class TYPE>
void Packet::packFooter( TYPE value )
{
    msgEndOffset_ -= sizeof( TYPE );
    switch( sizeof( TYPE ) )
    {
        case sizeof( uint8 ):  *(TYPE*)this->back() = value; break;
        case sizeof( uint16 ): *(TYPE*)this->back() = BW_HTONS( value ); break;
        case sizeof( uint32 ): *(TYPE*)this->back() = BW_HTONL( value ); break;
    }
}
```

**读取 footer**:接收端用 `stripFooter<T>` 从尾部向前剥,同样处理字节序(`packet.hpp:208-236`)。这种"反向增长"的设计让 footer 可以按任意顺序添加,互不影响。

**容量计算**:`maxCapacity()` 返回最大消息体大小(`packet.hpp:297-300`):

```cpp
static int maxCapacity()
{
    return MAX_SIZE - HEADER_SIZE - RESERVED_FOOTER_SIZE;
}
// = 1472 - 2 - 27 = 1443 字节
```

也就是说一个 UDP 包实际能装 1443 字节的应用消息数据。

**链表**:`next_` 字段让多个 `Packet` 可以串成链表,用于 Bundle 跨包时的分片重组(`packet.hpp:120-123`)。

### 5.2.3 Channel:逻辑通道

`Channel`(见 `channel.hpp:35-305`)是 Mercury 的核心抽象,表示两个地址之间的一条双向消息流。它是一个抽象基类,具体实现有 `UDPChannel` 和 `TCPChannel` 两种。

**抽象接口**(见 `channel.hpp:35-305`):

```cpp
class Channel : public ReferenceCount
{
public:
    virtual Bundle * newBundle() = 0;
    virtual const char * c_str() const = 0;
    virtual bool hasUnsentData() const = 0;
    virtual bool isExternal() const = 0;       // 服务器-客户端通道
    virtual bool isConnected() const;
    virtual void shutDown();
    virtual void onChannelInactivityTimeout();
    virtual bool isTCP() const = 0;
    virtual void setEncryption( Mercury::BlockCipherPtr pBlockCipher ) = 0;
    virtual double roundTripTimeInSeconds() const = 0;

    const Address & addr() const       { return addr_; }
    Bundle & bundle()                  { return *pBundle_; }
    NetworkInterface & networkInterface() { return *pNetworkInterface_; }

    void send( Bundle * pBundle = NULL );
    void clearBundle();
    void destroy();

    void pChannelListener( ChannelListener * pListener );
    ChannelListener * pChannelListener();

    void userData( void * userData );
    void * userData();

    uint32 numDataUnitsSent() const;
    uint32 numDataUnitsReceived() const;
    uint32 numBytesSent() const;
    uint32 numBytesReceived() const;

protected:
    Channel( NetworkInterface & networkInterface, const Address & addr );
    virtual void doPreFinaliseBundle( Bundle & bundle ) {}
    virtual void doSend( Bundle & bundle ) = 0;
    virtual void doDestroy() {}
};
```

**几个关键设计**:

1. **引用计数**:`Channel` 继承自 `ReferenceCount`,通过 `SmartPointer<Channel>` 即 `ChannelPtr` 管理(`channel.hpp:307`)。Channel 不会被直接 `delete`,而是 `destroy()` 后由引用计数归零自动释放。

2. **每个 Channel 自带一个 Bundle**:`pBundle_` 字段是 channel 默认的"挂载"bundle。上层调用 `channel.bundle()` 拿到这个 bundle,往里塞消息,然后 `channel.send()` 一次性发出。

3. **send 流程**(`channel.cpp:149-187`):

```cpp
void Channel::send( Bundle * pBundle )
{
    if (!this->isConnected()) { /* 报错 */ return; }
    if (pBundle == NULL) pBundle = pBundle_;
    this->doPreFinaliseBundle( *pBundle );  // 子类钩子
    pBundle->finalise();                     // 收尾(写 footer)
    this->networkInterface().addReplyOrdersTo( *pBundle, this );
    this->doSend( *pBundle );                // 子类实际发送
    if (pBundle == pBundle_) this->clearBundle();
    else                     pBundle->clear();
    if (pListener_) pListener_->onChannelSend( *this );
}
```

注意 `doSend` 是纯虚函数——UDP 和 TCP 各有实现。

4. **生命周期**:Channel 有几种"半死不活"的状态。`isDestroyed_` 表示已被销毁但引用还没归零;`isCondemned_`(在 `UDPChannel` 中)表示已被"判死刑",等待未 ACK 包都被 ACK 后才能真死;`recentlyDeadChannels` 则记录刚死的通道,避免同一地址立即重建时收到旧包。

5. **inactivityTimerHandle_**:`channel.hpp:194` 暴露了 `startInactivityDetection` 方法,允许设置"X 秒没收到包就自杀"的定时器。BaseApp 用这个机制探测掉线的客户端,见 `channel.cpp:251-280`。

### 5.2.4 UDPChannel:可靠 UDP 实现

`UDPChannel`(见 `udp_channel.hpp:54-531`)是 Mercury 的主力实现,绝大多数游戏流量都走它。

**Traits(通道性质)**:`udp_channel.hpp:67-74` 定义了两种通道性质:

```cpp
enum Traits
{
    INTERNAL = 0,  // 服务器-服务器:低延迟、高带宽、低丢包
    EXTERNAL = 1,  // 客户端-服务器:高延迟、低带宽、高丢包
};
```

两者的核心区别在 **重传策略**:

- **INTERNAL**:不丢任何数据,无论可靠与否都重传;
- **EXTERNAL**:带宽稀缺,只重传可靠数据;不可靠数据从丢包里直接剔除丢弃。

`udp_channel.hpp:62-66` 的注释解释得很清楚:

> Since bandwidth is scarce on client/server channels, only reliable data is resent on these channels. Unreliable data is stripped from dropped packets and discarded.

**关键成员**(见 `udp_channel.hpp:362-530`):

```cpp
Traits        traits_;
ChannelID     id_;                       // 索引通道 ID
ChannelVersion version_;                 // 通道版本(offload 计数)
PacketFilterPtr pFilter_;                // 包过滤器(加密/压缩)
uint32        windowSize_;               // 发送窗口大小
SeqNum        smallOutSeqAt_;            // 不含溢出包的下一个序号
SeqNumAllocator largeOutSeqAt_;         // 含溢出包的下一个序号
SeqNum        oldestUnackedSeq_;         // 最旧的未 ACK 序号
uint64        lastReliableSendTime_;     // 上次首次发可靠包的时间
uint64        lastReliableResendTime_;    // 上次重传时间
uint64        roundTripTime_;            // 平均往返时延
uint64        minInactivityResendDelay_;  // 最小重传间隔
SeqNum        unreliableInSeqAt_;       // 不可靠流上的序号

CircularArray< UnackedPacket * > unackedPackets_;  // 发送窗口
SeqNum        inSeqAt_;                  // 期望接收的下一个序号
CircularArray< PacketPtr > bufferedReceives_;      // 接收缓冲(乱序暂存)
FragmentedBundlePtr pFragments_;        // 分片重组缓冲
uint32        highestAck_;              // 收到的最大累积 ACK
```

**Indexed Channel(索引通道)**:`udp_channel.hpp:364-379` 的注释解释得很到位:

> An indexed channel is basically a way of multiplexing multiple channels between a pair of addresses. Regular channels distinguish traffic solely on the basis of address, so in situations where you need multiple channels between a pair of addresses (i.e. channels between base and cell entities) you use indexed channels to keep the streams separate.

也就是说,一对地址之间默认只有一条 channel。但有些场景下需要在同一对地址间跑多条独立流(例如同一个 BaseApp 上有多个实体,每个实体的 cell 实体都需要独立通信),这时用 `ChannelID` 区分。这就是**单 socket 多路复用**:一个 socket 上跑 N 条逻辑流,每条流有自己的序号空间和重传状态。

**ChannelVersion**:`udp_channel.hpp:371-379` 解释,索引通道的版本号追踪"被 offload 了多少次"。这用来识别过时的包:当一个实体从 CellApp A 迁移到 CellApp B,版本号变化,A 上残留的延迟包到达 B 时会被忽略。

**send 窗口**:`unackedPackets_` 是一个 `CircularArray`,保存所有已发送但未 ACK 的包。`windowSize_` 是软上限,超过会触发警告;`maxWindowSize()` 是硬上限,再超过会丢包或断开。`udp_channel.hpp:421-431` 显示不同通道类型有不同的溢出包上限:

```cpp
static uint s_maxOverflowPackets_[3];
// [0] = 外部(客户端)
// [1] = 内部(服务器,非索引)
// [2] = 内部(服务器,索引)
```

可通过 `setExternalMaxOverflowPackets` 等接口在运行时调整。

---

## 5.3 Bundle 消息序列化

### 5.3.1 Bundle 是什么

`Bundle`(见 `bundle.hpp:74-175`)是一个**消息序列化容器**,把若干条消息串成一段二进制流。它继承自 `BinaryOStream`,所以你可以用流操作符 `<<` 往里写数据:

```cpp
Bundle & bundle = channel.bundle();
bundle.startMessage( someInterfaceElement, RELIABLE_DRIVER );
bundle << someInt << someString;
channel.send();
```

这是 Mercury 最有特色的设计。**一个 Bundle 可以装多条消息,自动分片到多个 Packet**,在发送时通过一次或几次 `sendto` 出去,极大降低 syscall 次数。

### 5.3.2 写入流程

写入 Bundle 的标准流程是 **startMessage → 写参数 → (可选)再 startMessage → ... → send**:

```cpp
// 示例:发一条登录请求 + 一条附带的状态消息
Mercury::UDPBundle & b = static_cast<Mercury::UDPBundle&>( channel.bundle() );

b.startRequest( LoginInterface::logOn, myReplyHandler, /*arg=*/NULL,
                /*timeout=*/5000000 /* 5s */, RELIABLE_DRIVER );
b << username << password << clientVersion;

b.startMessage( StatusInterface::clientStatus, RELIABLE_PASSENGER );
b << fpsValue << latencyMs;

channel.send();
```

**startMessage 内部**(`udp_bundle.cpp:229-244`):

```cpp
void UDPBundle::startMessage( const InterfaceElement & ie, ReliableType reliable )
{
    MF_ASSERT( !pCurrentPacket_->hasFlags( Packet::FLAG_HAS_PIGGYBACKS ) );
    MF_ASSERT( ie.name() );

    this->endMessage();            // 收尾上一条消息
    curIE_ = ie;                  // 记下当前消息描述
    msgIsReliable_ = reliable.isReliable();
    msgIsRequest_ = false;
    isCritical_ = (reliable == RELIABLE_CRITICAL);
    this->newMessage();            // 在 packet 里腾位置

    reliableDriver_ |= reliable.isDriver();  // 标记本 bundle 有 driver
}
```

`newMessage()` 会在当前 Packet 的 body 区写入消息头(消息 ID + 长度字段),并返回写入指针。如果当前 Packet 装不下,会自动开新 Packet(`sreserve` 见 `udp_bundle.cpp:352-362`)。

### 5.3.3 可靠性等级

`bundle.hpp:34-61` 定义了四种可靠性:

```cpp
enum ReliableTypeEnum
{
    RELIABLE_NO = 0,         // 不可靠:丢了就丢了
    RELIABLE_DRIVER = 1,    // 可靠"驱动":必须有它,PASSENGER 才会被发送
    RELIABLE_PASSENGER = 2, // 可靠"乘客":只在有 DRIVER 同包时才被可靠发送
    RELIABLE_CRITICAL = 3   // 可靠关键:DRIVER + 标记包为 critical
};
```

**DRIVER/PASSENGER 设计**:

- 一个 Bundle 里可能有大量小消息,如果都做可靠重传,代价很大。
- Mercury 规定:**只有当 Bundle 内至少有一条 RELIABLE_DRIVER 消息时,这个 Bundle 才会进入可靠重传流程**;否则即使包含 RELIABLE_PASSENGER 消息,这些 passenger 也只是"搭便车",Bundle 丢了就丢了。
- 这种设计减少了"为了发一条不可靠的状态广播而创建独立 Bundle"的开销,可以批量合并。
- 对外部通道(客户端)更严格:`doFinalise` 里会清除没有 driver 的 passenger(`udp_bundle.cpp:380-387`):

```cpp
void UDPBundle::doFinalise()
{
    this->endMessage();
    this->endPacket( /* isExtending */ false );

    if (!reliableDriver_ && this->isOnExternalChannel())
    {
        reliableOrders_.clear();   // 客户端通道:没 driver 就不要 passenger
    }
}
```

**RELIABLE_CRITICAL**:除了标记可靠,还会设 `isCritical_` 标志。critical 包在 `unackedCriticalSeq_` 里追踪,如果迟迟未 ACK,会主动触发重传(`resendCriticals`)。这用于"必须尽快到达"的消息,例如登录响应、实体创建确认。

### 5.3.4 流式写入接口

`Bundle` 继承 `BinaryOStream`,所以任何重载了 `operator<<` 的类型都能直接写入。`bundle.hpp:126-144` 提供了模板便捷方法:

```cpp
template<typename ArgsType>
void sendMessage( const ArgsType & args, ReliableType reliable = RELIABLE_DRIVER )
{
    this->startMessage( ArgsType::interfaceElement(), reliable );
    static_cast<BinaryOStream&>(*this) << args;
}

template<typename ArgsType>
void sendRequest( const ArgsType & args,
    ReplyMessageHandler * handler, void * arg = NULL,
    int timeout = DEFAULT_REQUEST_TIMEOUT, ReliableType reliable = RELIABLE_DRIVER )
{
    this->startRequest( ArgsType::interfaceElement(), handler, arg, timeout, reliable );
    static_cast<BinaryOStream&>(*this) << args;
}
```

这就是为什么 BigWorld 的接口定义(.def 文件)能自动生成代码:工具生成的 `ArgsType` 自带 `interfaceElement()` 静态方法和 `operator<<` 重载,调用方一行 `bundle.sendMessage(myArgs)` 就完成发送。

`bundle.ipp:18-35` 还提供 `startStructMessage`/`startStructRequest`,直接返回固定大小消息的内存指针,避免额外的 `<<` 调用:

```cpp
INLINE void * Bundle::startStructMessage( const InterfaceElement & ie, ReliableType reliable )
{
    this->startMessage( ie, reliable );
    return this->reserve( ie.lengthParam() );  // 预留定长空间
}
```

### 5.3.5 与 Channel 的关系

Bundle 与 Channel 是"内容物"与"运输车"的关系:

1. **每个 Channel 默认持有一个 Bundle**(`channel.hpp:285` 的 `pBundle_`),通过 `channel.bundle()` 取得。
2. **Bundle 自动分片到 Packet**:`UDPBundle` 内部维护 `pFirstPacket_` 和 `pCurrentPacket_`,当当前 Packet 装不下新消息时,自动开新 Packet 并链接成链表。
3. **发送时由 Channel 接管**:`channel.send()` 调用 `doSend(bundle)`,UDP 实现里会:
   - 调用 `UDPBundle::preparePackets` 给每个 Packet 分配序号;
   - 写入 channel footer(序号、ACK、channelID、version 等);
   - 通过 `Endpoint::sendto` 发出每个 Packet;
   - 把每个可靠 Packet 加入 `unackedPackets_` 等待 ACK。

### 5.3.6 读取流程

接收端的处理在 `PacketReceiver`(见 `packet_receiver.hpp`)中,大致流程:

1. `Endpoint::recvfrom` 收到一个 UDP 报文;
2. `Packet::recvFromEndpoint` 把数据装入 `Packet` 对象;
3. `Packet` 的 footer 被逐个 `stripFooter` 剥离,提取序号、ACK、channelID 等;
4. `UDPChannel::addToReceiveWindow` 按 序号把包放入接收窗口,处理乱序;
5. 如果是分片,交给 `FragmentedBundle` 重组;
6. 重组完成后,`processOrderedPacket` 遍历 Packet 中的消息,根据消息 ID 查 `InterfaceTable` 找到对应的 `InterfaceElement` 和 `InputMessageHandler`,调用处理器。

**消息分发的关键**:`InterfaceElement::expandLength` 从包头解析消息长度,然后交给 `InputMessageHandler::handleMessage` 处理。每个进程在启动时通过 `InterfaceTable::registerWithInterface` 注册自己的消息处理器,详见 §5.4。

---

## 5.4 消息类型与接口系统

### 5.4.1 msgtypes.hpp:位压缩与坐标系消息

`msgtypes.hpp` 不是"消息 ID 定义"的地方(那在 `.def` 文件里),而是**消息体中常用数据类型的位压缩工具**。主要用于客户端与服务器的实体状态同步,把浮点位置/朝向压缩成尽可能少的字节。

**核心类**:

- `PackedYaw<>`:压缩一个 yaw 角度,默认 8 bit(`YAW_YAWBITS`);
- `PackedYawPitch<>`:压缩 yaw + pitch,各 8 bit;
- `PackedYawPitchRoll<>`:压缩 yaw/pitch/roll,各 8 bit;
- `PackedGroundPos<>`:压缩地面 XZ 坐标(无 Y),用指数 + 尾数编码,默认 3+8+1=12 bit 每轴,共 24 bit = 3 字节;
- `PackedFullPos<>`:压缩 XYZ,前两轴用 XZ 编码,Y 用更大范围,共 41 bit ≈ 6 字节。

**配置宏**(`msgtypes.hpp:26-72`):

```cpp
#define VOLATILE_POSITIONS_ARE_ABSOLUTE 0    // 0=相对参考点,1=绝对
#define EXPONENTBITS_XZ 3                    // 指数位
#define XZ_MANTISSABITS_XZ 8                 // 尾数位
#define XYZ_EXPONENTBITS_Y 4
#define XYZ_MANTISSABITS_Y 11
```

每个宏都有 `#error` 检查位宽合法性,例如必须满足 `(总位数 % 8) == 0` 避免字节对齐问题(`msgtypes.hpp:85-87`)。

**参考位置**:`msgtypes.hpp:423-427` 的 `calculateReferencePosition` 把浮点坐标取整,作为相对编码的基准。注释解释了原因:

> if the reference position changes by less than the least accurate offset from this position, entities that are meant to be stationary will move as the reference position moves.

也就是说,如果参考点抖动不到一个最低精度位,会让"应该静止"的实体看起来在抖动,所以要四舍五入到整数。

### 5.4.2 InterfaceElement:单个消息的描述

`InterfaceElement`(`interface_element.hpp:87-188`)描述一条消息的元信息:

```cpp
class InterfaceElement
{
public:
    InterfaceElement( const char * name = "", MessageID id = 0,
        int8 lengthStyle = INVALID_MESSAGE, int lengthParam = 0,
        InputMessageHandler * pHandler = NULL );

    int headerSize() const;
    int nominalBodySize() const;
    int compressLength( void * header, int length, UDPBundle * pBundle, bool isRequest ) const;
    int expandLength( void * header, Packet * pPacket, bool isRequest ) const;

    MessageID id() const          { return id_; }
    int8 lengthStyle() const     { return lengthStyle_; }
    int lengthParam() const       { return lengthParam_; }
    const char * name() const     { return name_; }
    InputMessageHandler * pHandler() const;

private:
    MessageID           id_;             // 消息 ID(0-254)
    int8                lengthStyle_;     // FIXED/VARIABLE/CALLBACK
    int32               lengthParam_;     // 固定长度 / 变长头字节数
    const char *        name_;           // 消息名
    InputMessageHandler * pHandler_;     // 处理器
};
```

**长度风格**(`interface_element.hpp:36-61`):

```cpp
const char FIXED_LENGTH_MESSAGE = 0;     // 定长:lengthParam 是字节数
const char VARIABLE_LENGTH_MESSAGE = 1;  // 变长:lengthParam 是长度字段字节数
const char CALLBACK_LENGTH_MESSAGE = 2;  // 回调决定长度
const char INVALID_MESSAGE = 3;
```

**消息 ID 取值范围**:`MessageID` 是 `uint8`(`misc.hpp:90`),取值 0-255。其中 0xFF 保留给 reply(`interface_element.hpp:342`):

```cpp
const unsigned char REPLY_MESSAGE_IDENTIFIER = 0xFF;
```

注释里提到历史上还有 `REPLY_PIGGY_BACK_IDENTIFIER`,后来改成 footer 实现后就不用了,但 entitydef 仍按"2 个保留 ID"处理,所以一个接口最多 62 个方法/属性(`interface_element.hpp:345-355`)。这也是为什么 BigWorld 实体的 exposed 方法/属性数量有上限——超过就自动用 2 字节 ID。

### 5.4.3 InterfaceTable:消息表

`InterfaceTable`(见 `interface_table.hpp`)是消息 ID 到 `InterfaceElement` 的查找表。每个 `NetworkInterface` 持有一个 `InterfaceTable`,在进程启动时由各模块注册:

```cpp
// 伪代码示例
interfaceTable->registerHandler( LoginInterface::logOn.id(),
    new LoginOnHandler() );
interfaceTable->registerHandler( LoginInterface::logOnSuccess.id(),
    new LogOnSuccessHandler() );
```

接收包时,根据包头里的 MessageID 查表,拿到对应的 `InterfaceElement` 和 `InputMessageHandler`,然后调用处理器。

### 5.4.4 interface_macros.hpp:消息定义宏

`interface_macros.hpp` 提供了一组宏让接口定义更简洁:

```cpp
#define MERCURY_FIXED_MESSAGE( NAME, PARAM, HANDLER )
#define MERCURY_VARIABLE_MESSAGE( NAME, PARAM, HANDLER )
#define MERCURY_CALLBACK_MESSAGE( NAME, HANDLER )
#define MERCURY_EMPTY_MESSAGE( NAME, HANDLER )

#define BEGIN_STRUCT_MESSAGE( NAME, HANDLER )  ...
#define END_STRUCT_MESSAGE()                   ...
```

这些宏会被 `.def` 文件生成的代码使用。例如一个 `LoginInterface::logOn` 消息定义最终会展开为:

```cpp
// 大致展开(简化)
static const InterfaceElement & logOn_interfaceElement() {
    static InterfaceElement ie( "logOn", /*id=*/5,
        VARIABLE_LENGTH_MESSAGE, /*lenParam=*/2,
        &logOn_handler );
    return ie;
}
```

调用方写 `bundle.startMessage(LoginInterface::logOn)` 实际上是 `bundle.startMessage(LoginInterface::logOn_interfaceElement())`。

### 5.4.5 Mercury 命名与 FourCC

**Mercury 命名**:整个消息系统的命名空间是 `Mercury`(见 `basictypes.hpp:264`、`bundle.hpp:13`、`channel.hpp:20` 等)。Mercury 是罗马神话中的信使之神(Mercurius),掌管信息、旅行、商业。BigWorld 借这个名字表达"在各方之间传递消息"的语义。

**FourCC 标识符**:Mercury 用 4 字节 ASCII 字符串标识接口类型,例如 `BaseAppInterface`、`CellAppInterface` 等。通过 `bwmachined` 的 `findInterface` 查找时,就是用 FourCC 字符串作为 key(见 `BigWorld启动流程分析.md` 第 837 行):

```cpp
Mercury::MachineDaemon::findInterface("BaseAppMgrInterface", 0, baseAppMgrAddr);
```

FourCC 的好处是 4 字节即 32 位,可以直接作为 `uint32` 比较,效率高;同时人眼可读,便于调试。

---

## 5.5 可靠 UDP 实现细节

### 5.5.1 序列号

`misc.hpp:25-28` 定义了序号类型和范围:

```cpp
typedef uint32 SeqNum;
const SeqNum SEQ_SIZE = 0x10000000U;   // 2^28 = 268M
const SeqNum SEQ_MASK = SEQ_SIZE-1;    // 低 28 位
const SeqNum SEQ_NULL = SEQ_SIZE;       // 无效值
```

**为什么是 28 位?** 这是个权衡:

- 太小(如 16 位)→ 高吞吐通道上几秒就回绕,需要复杂的回绕检测;
- 太大(如 32 位)→ footer 浪费空间;
- 28 位 = 256M,即使每秒 1 万包也能跑 7 小时才回绕,足够安全;
- 同时 `uint32` 装得下,比较运算简单。

**回绕处理**:`misc.hpp:34-47` 的 `seqMask` 和 `seqLessThan` 巧妙处理回绕:

```cpp
inline SeqNum seqMask( SeqNum x ) { return x & SEQ_MASK; }

inline bool seqLessThan( SeqNum a, SeqNum b )
{
    return seqMask( a - b ) > SEQ_SIZE/2;
}
```

原理是:把差值映射到 `[0, SEQ_SIZE)`,如果差值落在后半段 `[SEQ_SIZE/2, SEQ_SIZE)`,说明 a 在 b "之前"(回绕了一次)。

**SeqNumAllocator**:`misc.hpp:53-84` 是个简单的序号分发器:

```cpp
class SeqNumAllocator
{
public:
    SeqNumAllocator( SeqNum firstSeqNum ) : nextNum_( firstSeqNum ) {}
    SeqNum getNext()
    {
        SeqNum retVal = nextNum_;
        nextNum_ = seqMask( nextNum_ + 1 );
        return retVal;
    }
    operator SeqNum() const { return nextNum_; }
private:
    SeqNum nextNum_;
};
```

每个 `NetworkInterface` 持有一个 `SeqNumAllocator`,所有 outgoing 包共享一个序号空间(不论哪个 channel)。这样接收端可以基于序号判断包的顺序(虽然不同 channel 间不要求有序,但同一 channel 内的包序号是单调递增的)。

### 5.5.2 ACK 机制

Mercury 的 ACK 有两种形式:

1. **单 ACK**(`FLAG_HAS_ACKS`):携带一个 SeqNum 列表,明确告诉对方"这些包收到了"。`AckCount` 是 `uint8`,所以单个 Packet 最多携带 255 个 ACK(`packet.hpp:97`)。
2. **累积 ACK**(`FLAG_HAS_CUMULATIVE_ACK`):只携带一个 SeqNum,表示"这个序号及之前的所有包都收到了"。这是更高效的方式,适合连续 ACK。

**何时发送 ACK**:`UDPChannel` 维护 `acksToSend_` 集合(`udp_channel.hpp:174`)。每收到一个包就把它的序号加入集合。下次发包时,如果集合非空,就把 ACK 写入 footer。**关键优化**:`pushUnsentAcksThreshold_`(`udp_channel.hpp:494`)定义了 ACK 阈值,超过这个数量就立即发包(即使 channel 是 regular 的、本不该主动发包)。

**handleAck / handleCumulativeAck**:`udp_channel.hpp:153-154`:

```cpp
bool handleCumulativeAck( SeqNum seq );  // 累积 ACK:seq 及之前的全 ACK
bool handleAck( SeqNum seq );             // 单 ACK:只 ACK seq 这一个
```

处理时:

1. 从 `unackedPackets_` 中移除被 ACK 的包;
2. 更新 `oldestUnackedSeq_`;
3. 如果有更多发送窗口空间,唤醒等待发送的代码;
4. 更新 RTT 估计(`roundTripTime_`)。

### 5.5.3 重传(RTO)

**重传触发**:`UDPChannel` 不用单一 RTO,而是基于**事件**触发重传:

1. **收到 NACK**:收到对端的 ACK 时,如果发现某个序号被跳过(累积 ACK 序号比预期低),说明中间包丢了,立即重传。
2. **inactivity 重传**:对 regular channel,如果一段时间没有收到任何包,检查 `unackedPackets_` 中最早的包,如果距上次发送超过 `minInactivityResendDelay_`,重传。这就是 `IrregularChannels` 的工作——它周期性地检查所有非 regular channel。
3. **critical 重传**:`RELIABLE_CRITICAL` 消息会更积极地重传。`resendCriticals()` 专门处理。
4. **首次发送**:`lastReliableSendTime_` 记录最后一次首次发送可靠包的时间,作为 RTT 估计的起点。

**RTT 估计**:`roundTripTime_` 是平滑后的 RTT。`udp_channel.hpp:157-159`:

```cpp
uint64 roundTripTime() const { return roundTripTime_; }
virtual double roundTripTimeInSeconds() const
    { return roundTripTime_/stampsPerSecondD(); }
```

RTT 用于:

- 决定下次重传的等待时间(避免过早重传造成拥塞);
- 判断 channel 是否还活着(超过若干倍 RTT 没收到包就视为断开)。

### 5.5.4 滑动窗口

**发送窗口**(`udp_channel.hpp:237-241`):

```cpp
int sendWindowUsage() const
{
    return this->hasUnackedPackets() ?
        seqMask( largeOutSeqAt_ - oldestUnackedSeq_ ) : 0;
}
```

即"已分配序号 - 最旧未 ACK 序号"。这个值不能超过 `maxWindowSize() = windowSize_ + getMaxOverflowPackets()`。

**两个序号**:

- `smallOutSeqAt_`:下一个要分配的序号(不含溢出包);
- `largeOutSeqAt_`:包含溢出包的序号分配器。

为什么要两个?因为 overflow 包是"超出软窗口但还没拒绝"的过渡状态。`smallOutSeqAt_` 用于正常发送,`largeOutSeqAt_` 用于统计窗口占用。当 `smallOutSeqAt_` 落后 `oldestUnackedSeq_` 超过 `windowSize_`,新消息要进入 overflow 队列等待;如果再超过 `maxWindowSize_`,就触发 `REASON_WINDOW_OVERFLOW` 错误。

**接收窗口**:`inSeqAt_` 是期望接收的下一个序号,`bufferedReceives_` 是乱序暂存的包。`addToReceiveWindow`(`udp_channel.hpp:170-171`)的返回值枚举说明了所有情况:

```cpp
enum AddToReceiveWindowResult
{
    PACKET_IS_NEXT_IN_WINDOW,    // 正是预期的下一个包,立即处理
    PACKET_IS_BUFFERED_IN_WINDOW, // 在窗口内但乱序,暂存
    PACKET_IS_DUPLICATE,          // 已收过,丢弃
    PACKET_IS_OUT_OF_WINDOW,      // 超出窗口(可能是过时包或攻击)
    PACKET_IS_CORRUPT,           // 校验失败
};
```

### 5.5.5 与 TCP 的对比

| 维度 | TCP | Mercury UDP |
|---|---|---|
| 可靠性 | 字节流有序 | 消息级可靠(整条消息要么完整到达要么不到达) |
| 队头阻塞 | 严重:一个包丢失阻塞整个流 | 轻微:只有同一 channel 的同一 reliable 流才阻塞 |
| 拥塞控制 | Reno/CUBIC(为 Web 优化) | 自定义(基于窗口 + RTT,可关闭) |
| 流量控制 | 滑动窗口 | 滑动窗口 + 优先级 + critical |
| 多路复用 | 一连接一流 | indexed channel:一 socket 多流 |
| 不可靠数据 | 不支持 | 支持(RELIABLE_NO) |
| 过时数据丢弃 | 不支持 | 支持(可让上层决定丢弃旧包) |
| 握手 | 三次握手 + TIME_WAIT | 无连接,首包即数据(配合 salt) |
| 跨防火墙 | 友好 | 不友好(NAT 穿透难)—— 这是 TCP 的优势 |

**实际选择**:内部服务器之间一律 UDP;客户端到 BaseApp 默认 UDP,但 1.4 后支持 TCP/WebSocket 回退,用于穿透严格的 NAT/防火墙。

### 5.5.6 拥塞控制

Mercury 的"拥塞控制"比较朴素:

1. **静态窗口**:不像 TCP 那样动态调整 `cwnd`,Mercury 的 `windowSize_` 是配置值(`Config::sendWindow*`),运行时基本不变。
2. **溢出包**:窗口满时允许少量 overflow 包,超过上限才报错。这给突发流量留了缓冲。
3. **背压**:`REASON_WINDOW_OVERFLOW` 错误传到上层后,BaseApp 会判定客户端"卡住",可能踢掉它(见 `BigWorld启动流程分析.md` 第 610 行)。
4. **RTT 自适应**:重传等待时间随 RTT 变化,避免在高延迟链路上过早重传。

这种设计的核心思想是:**MMOG 的流量是可预测的(实体状态更新),不需要通用拥塞控制;一旦出现拥塞,宁可丢客户端也不能拖垮整个集群**。

---

## 5.6 流量控制与背压

### 5.6.1 通道带宽限制

每个 channel 有几个隐式的带宽约束:

1. **窗口大小**:`windowSize_` 决定了同时在路上的最大字节数(窗口 × 包大小)。
2. **`pushUnsentAcksThreshold_`**:`udp_channel.hpp:247-252`,ACK 数量超过这个值就强制发包,避免 ACK 积压。
3. **`maxSocketProcessingTime`**:`NetworkInterface` 限制单次 socket 处理的最大时间,防止某个高流量 channel 把整个事件循环饿死(`network_interface.hpp:200-201`)。
4. **`rateLimitPeriod_`**:`network_interface.hpp:242-262`,按 IP / IP:Port 限速,防止恶意洪泛。`incrementAndCheckRateLimit` 在每个 incoming 包上检查。

### 5.6.2 优先级消息

Mercury 没有显式的"优先级"字段,但通过几种机制实现类似效果:

1. **RELIABLE_CRITICAL**:被标记为 critical 的包会触发 `resendCriticals()`,在重传检查时优先处理。
2. **Piggyback(搭载)**:`FLAG_HAS_PIGGYBACKS` 允许把一个 channel 的小包"搭载"到另一个 channel 的 outgoing 包上,减少单独发包的开销。`bundle_piggyback.hpp` 实现了这个机制。
3. **Off-channel 发送**:`NetworkInterface::createOffChannelBundle`(`network_interface.hpp:215`)允许发一次性消息而不建立 channel,适合心跳、广播等。

### 5.6.3 紧急消息(立即发送)

默认情况下,channel 的 bundle 不会立即发出——它会等到:

- bundle 写满一个 Packet;
- 显式调用 `channel.send()`;
- channel 的定期发送定时器触发(`KeepAliveChannels`);
- ACK 阈值触发。

但有些场景需要"写完立即发",Mercury 提供 `sendIfIdle()`(`udp_channel.hpp:119`):

```cpp
void sendIfIdle();
```

如果 channel 当前空闲(没在等 ACK),立即把 bundle 推出去。BaseApp 在 client overflow 时会用这个机制紧急发送控制消息。

### 5.6.4 背压(backpressure)

背压是 Mercury 的核心安全机制。当某条 channel 来不及处理流量时,背压向上传播:

1. **`unackedPackets_` 增长** → `sendWindowUsage()` 接近 `maxWindowSize()`;
2. **`checkOverflowErrors()`** 触发警告日志;
3. **继续增长** → 返回 `REASON_WINDOW_OVERFLOW`;
4. **上层处理**:BaseApp 检测到 client channel 窗口超限,1 秒后回调 `onClientDeath(CLIENT_DISCONNECT_TIMEOUT)`,断开客户端。

服务器之间的 channel 类似,但通常 windowSize 设得很大(几 MB),不会轻易触发。一旦触发,通常意味着对端进程卡死,需要 bwmachined 介入重启。

`udp_channel.hpp:510-515` 的 `s_sendWindowWarnThresholds_` 是动态警告阈值,每次超过就翻倍,直到触发 assert:

```cpp
static int s_sendWindowWarnThresholds_[2];  // [0]=普通内部, [1]=索引
int & sendWindowWarnThreshold()
{
    return s_sendWindowWarnThresholds_[ this->isIndexed() ];
}
```

这种"渐进警告"设计让运维能提前发现拥塞趋势,而不是直接崩。

---

## 5.7 请求-响应模式与特殊机制

### 5.7.1 Request:请求-响应封装

`request.hpp:24-64` 定义了 `Request` 类,封装"请求-响应"模式:

```cpp
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
    int                     replyID_;
    TimerHandle             timerHandle_;
    ReplyMessageHandler *   pHandler_;
    void *                  arg_;
    Channel *               pChannel_;
};
```

**工作流程**(`request.cpp` + `udp_bundle.cpp`):

1. **发起请求**:调用 `bundle.startRequest(ie, handler, arg, timeout, reliable)`。`UDPBundle::startRequest`(`udp_bundle.cpp:259-308`):
   - 在消息头里预留 `ReplyID` 和 `nextRequestOffset` 字段;
   - 把 `handler`、`arg`、`timeout` 封装成 `ReplyOrder` 加入 `replyOrders_`;
   - 在 Packet 上设置 `FLAG_HAS_REQUESTS`。

2. **Bundle finalize 时**:`addReplyOrdersTo` 把所有 `ReplyOrder` 转交给 `RequestManager`,后者为每个请求创建 `Request` 对象并启动定时器(`request.cpp:17-32`):

```cpp
Request::Request( int replyID, const ReplyOrder & replyOrder, Channel * pChannel,
        RequestManager * pRequestManager, EventDispatcher & dispatcher ) :
    replyID_( replyID ),
    pHandler_( replyOrder.handler ),
    arg_( replyOrder.arg ),
    pChannel_( pChannel )
{
    if (!pChannel)
    {
        timerHandle_ = dispatcher.addOnceOffTimer(
                            replyOrder.microseconds, this, pRequestManager );
    }
}
```

注意:**有 channel 的请求不设定时器**!注释解释(`udp_bundle.cpp:267-273`)——channel 上的请求"永不过期",由 channel 自身的存活性决定。这是为了避免在正常的长连接上误触发超时。

3. **回复到达**:对端发回 `startReply(replyID, reliable)`,Mercury 根据 replyID 找到对应的 `Request` 对象,调用 `handleMessage`(`request.cpp:68-75`):

```cpp
void Request::handleMessage( const Address & source,
    UnpackedMessageHeader & header, BinaryIStream & data )
{
    pHandler_->handleMessage( source, header, data, arg_ );
    this->finish();
}
```

4. **超时或失败**:`handleTimeout`(`request.cpp:58-62`)调用 `RequestManager::failRequest`,进而 `Request::handleFailure`(`request.cpp:82-97`):

```cpp
void Request::handleFailure( Reason reason )
{
    NubException e( reason );
    if (reason != REASON_SHUTTING_DOWN)
        pHandler_->handleException( e, arg_ );
    else
        pHandler_->handleShuttingDown( e, arg_ );
    this->finish();
}
```

5. **清理**:`finish()` 取消定时器,`onRelease` 删除自己(`request.cpp:103-124`)。

### 5.7.2 ReplyID 分配

`ReplyID` 是 `int32`(`misc.hpp:110`),取值范围 `-1`(无)到 `1000000`(`REPLY_ID_MAX`)。`RequestManager` 维护一个全局递增的 replyID 分配器,每个进程内不重复。发送时把 replyID 写入 Packet 的 footer,接收方回复时原样带回。

### 5.7.3 Bundle 内联实现(bundle.ipp)

`bundle.ipp` 是 Bundle 的内联实现,只有两个方法(`bundle.ipp:18-35`):

```cpp
INLINE void * Bundle::startStructMessage( const InterfaceElement & ie, ReliableType reliable )
{
    this->startMessage( ie, reliable );
    return this->reserve( ie.lengthParam() );
}

INLINE void * Bundle::startStructRequest( const InterfaceElement & ie,
    ReplyMessageHandler * handler, void * arg, int timeout, ReliableType reliable)
{
    this->startRequest( ie, handler, arg, timeout, reliable );
    return this->reserve( ie.lengthParam() );
}
```

之所以内联,是因为它们在每条消息发送时都被调用,函数调用开销不可忽视。`CODE_INLINE` 宏控制是否真的内联,默认在 Release 构建中是内联的。

### 5.7.4 portmap.hpp:端口映射

`portmap.hpp` 是个非常简单的常量头,定义了 BigWorld 使用的固定端口:

```cpp
#define PORT_LOGIN              20013  // 登录服务器
#define PORT_MACHINED_OLD       20014  // 旧版 machined
#define PORT_MACHINED           20018  // machined 进程
#define PORT_BROADCAST_DISCOVERY 20019 // machined 发现
#define PORT_PYTHON_BASEAPP     40000  // BaseApp Python 调试端口基址
#define PORT_PYTHON_CELLAPP     50000  // CellApp Python 调试端口基址
#define PORT_PYTHON_SERVICEAPP 60000  // ServiceApp Python 调试端口基址
```

**关键设计**:LoginApp、bwmachined 用固定端口,因为客户端和运维工具需要"众所周知"的入口。其他服务进程的端口由 bwmachined 动态分配,通过 `findInterface` 查询。Python 调试端口按进程 ID 偏移,例如 CellApp #3 的 Python 端口是 50003。

### 5.7.5 netmask.hpp:网络掩码

`NetMask`(`netmask.hpp:11-24`)是个简单工具类,用于判断某 IP 是否在指定网段内:

```cpp
class NetMask
{
public:
    NetMask();
    bool parse( const char* str );          // 解析 "192.168.1.0/24" 或 "10.0.0.0/8"
    bool containsAddress( uint32 addr ) const;
    void clear();
private:
    uint32 mask_;
    int bits_;
};
```

主要用于服务器配置中的访问控制,例如"只允许内网 IP 连 BaseAppMgr"。

### 5.7.6 misc.hpp:杂项工具

`misc.hpp` 集中了一些跨文件的常量和工具:

- **SeqNum 相关**(§5.5.1 已述);
- **MessageID**:`uint8`,消息 ID 类型;
- **ChannelID**:`int32`,索引通道 ID,`CHANNEL_ID_NULL = 0`;
- **ChannelVersion**:`typedef SeqNum ChannelVersion`,复用序号的回绕逻辑;
- **ReplyID**:`int32`,请求回复 ID;
- **Reason** 枚举(`misc.hpp:137-153`):所有 Mercury 错误码,如 `REASON_TIMER_EXPIRED`、`REASON_NO_SUCH_PORT`、`REASON_CORRUPTED_PACKET`、`REASON_WINDOW_OVERFLOW`、`REASON_INACTIVITY`、`REASON_CLIENT_DISCONNECTED` 等;
- **`reasonToString`**(`misc.hpp:159-188`):把 Reason 转成可读字符串;
- **`DEFAULT_ONCEOFF_RESEND_PERIOD`**:`200 * 1000` 微秒 = 200ms,一次性可靠包的默认重传间隔;
- **`DEFAULT_ONCEOFF_MAX_RESENDS`**:50 次,超过就放弃。

### 5.7.7 net_360.hpp:历史遗留

`net_360.hpp` / `net_360.cpp` 是 Xbox 360 平台的网络兼容代码。BigWorld 1.x 时代支持 Xbox 360、PS3 等主机平台,这些平台的 socket API 与标准 BSD socket 有差异。1.4.x 之后大部分被废弃但仍保留。新项目可以忽略这一层(`basictypes.hpp:4-6` 在 `_XBOX360` 宏下 include)。

---

## 5.8 跨平台与 IO 模型

### 5.8.1 平台差异隔离

Mercury 在 `endpoint.hpp` 和 `endpoint.ipp` 中用条件编译隔离了所有平台差异,主要差异点:

| 差异 | Windows | Unix/Linux | PS3 | Xbox |
|---|---|---|---|---|
| socket 类型 | `SOCKET`(unsigned) | `int` | `int` | `SOCKET` |
| 非阻塞 | `ioctlsocket(FIONBIO)` | `fcntl(F_SETFL, O_NONBLOCK)` | `setsockopt(SO_NBIO)` | `ioctlsocket` |
| 关闭 | `closesocket` | `close` | `socketclose` | `closesocket` |
| 错误码 | `WSAGetLastError` | `errno` | `errno` | `WSAGetLastError` |
| 初始化 | `WSAStartup`(自动) | 无需 | 无需 | `WSAStartup` |
| 接口查询 | `gethostbyname` | `ioctl(SIOCGIFADDR)` | `cellNetCtlGetInfo` | `XNetGetTitleXnAddr` |

所有这些差异都在 `endpoint.ipp` 的内联函数里处理,上层代码看到的都是统一的 `Endpoint` 接口。

### 5.8.2 IO 多路复用:EventPoller

`EventPoller`(`event_poller.hpp:95-158`)是 IO 多路复用的抽象基类:

```cpp
class EventPoller : public InputNotificationHandler
{
public:
    virtual int processPendingEvents( double maxWait ) = 0;
    bool registerForRead( int fd, InputNotificationHandler * handler, const char * name );
    bool registerForWrite( int fd, InputNotificationHandler * handler, const char * name );
    bool deregisterForRead( int fd );
    bool deregisterForWrite( int fd );
    static EventPoller * create();
};
```

`create()` 是工厂方法,根据平台返回不同实现:

- **Linux**:优先 epoll(`EpollEventPoller`),回退 select;
- **Windows/macOS/BSD**:select;
- **理论上支持 IOCP**,但 BigWorld 1.4 在 Windows 服务器上仍用 select(因为 Windows 主要做客户端,服务器一般跑 Linux)。

**为什么服务器用 epoll?** select 的复杂度是 O(n)(遍历所有 fd),epoll 是 O(1)(只返回就绪的 fd)。BigWorld 服务器一个进程可能监听上千个 channel 的 socket(虽然主要用一个 UDP socket),加上文件监听、定时器等,select 的开销会随 fd 数增长而线性上升。

**EventPoller 的统计**:`InputHandlerEntry`(`event_poller.hpp:19-90`)记录每个 fd 的触发次数和错误次数,每 10 万次打印一次 INFO 日志,便于排查"哪个 fd 频繁触发"。

### 5.8.3 EventDispatcher:事件循环

`EventDispatcher`(`event_dispatcher.hpp`)是 Mercury 的"主循环"。每个服务器进程的主线程都跑一个 EventDispatcher,它聚合了:

- 一个 `EventPoller`(IO 多路复用);
- 一组定时器(`TimerHandle`);
- 一组频繁任务(`FrequentTasks`)。

主循环大致是:

```cpp
while (running) {
    dispatcher.processPendingEvents(maxWait);  // 处理 IO
    dispatcher.processTimers();                // 处理定时器
    dispatcher.processFrequentTasks();         // 处理频繁任务
}
```

`NetworkInterface` 把自己的 UDP socket 通过 `EventPoller::registerForRead` 注册到 dispatcher,当 socket 可读时,dispatcher 调用 `PacketReceiver::handleInputNotification`,后者 `recvfrom` 一个包并处理。

这就是为什么 Mercury 是**单线程 Reactor 模型**:所有网络 IO 在主线程完成,通过事件分发到各处理器。好处是无需锁,坏处是处理器必须快——这就是 `maxSocketProcessingTime` 限制的原因。

### 5.8.4 PacketReceiver 与 PacketSender

`PacketReceiver`(`packet_receiver.hpp`)负责收包:

1. `Endpoint::recvfrom` 收到一个 UDP 报文;
2. 装入 `Packet` 对象;
3. 校验 checksum(如果 `FLAG_HAS_CHECKSUM`);
4. 解析 footer,确定 channel(根据 `FLAG_INDEXED_CHANNEL` + `channelID_`,或根据源地址);
5. 交给对应 channel 的 `addToReceiveWindow`;
6. 处理 ACK(`handleAck` / `handleCumulativeAck`);
7. 如果是分片,交给 `FragmentedBundle`;
8. 重组完成后,按顺序处理消息,通过 `InterfaceTable` 分发。

`PacketSender`(`packet_sender.hpp`)负责发包,但实际逻辑大部分在 `UDPChannel::doSend` 和 `NetworkInterface::send` 中。

---

## 5.9 网络层在引擎中的应用

### 5.9.1 服务器间通信

BigWorld 服务器集群由多个进程组成(详见第 7 章和 `BigWorld启动流程分析.md`):

- **CellAppMgr**:管理所有 CellApp;
- **BaseAppMgr**:管理所有 BaseApp;
- **DBAppMgr + DBApp Alpha**:数据库访问;
- **CellApp**:跑实体 cell 部分;
- **BaseApp**:跑实体 base 部分 + 客户端代理;
- **LoginApp**:登录入口;
- **bwmachined**:进程监控。

它们之间都通过 Mercury 通信。每对进程之间通常建立一条 `INTERNAL` 性质的 `UDPChannel`,用 `ChannelOwner`(`channel_owner.hpp`)封装。

**示例**:`CellApp` 持有到 CellAppMgr 的 channel(`cellapp.hpp`):

```cpp
// cellapp.hpp(节选)
typedef Mercury::ChannelOwner DBApp;
class CellApp {
    // ...
    static Mercury::UDPChannel & getChannel( const Mercury::Address & addr );
    const Mercury::Address & baseAppAddr() const { return baseAppAddr_; }
    // ...
    Mercury::Address baseAppAddr_;
};
```

`BaseApp` 同时持有内部和外部两个 NetworkInterface(`baseapp.hpp`):

```cpp
// baseapp.hpp(节选)
Mercury::NetworkInterface & intInterface() { return interface_; }
Mercury::NetworkInterface & extInterface() { return extInterface_; }
Mercury::NetworkInterface extInterface_;
```

外部接口用 `EXTERNAL` 性质 channel,重传策略更保守(只重可靠数据)。

### 5.9.2 客户端 ↔ BaseApp 通信

客户端通过 `ServerConnection`(客户端库)连接 BaseApp。流程:

1. **登录**:客户端先连 LoginApp,LoginApp 通过 DBApp 验证后,BaseAppMgr 分配一个 BaseApp 给客户端;
2. **建立 channel**:BaseApp 主动向客户端发起 `createEntity` 消息(带 `FLAG_CREATE_CHANNEL`),客户端收到后建立 channel;
3. **实体同步**:客户端的实体 client 部分与 BaseApp 的实体 base 部分通过这条 channel 双向通信,跑业务消息(移动、状态、RPC)。

**外部 channel 的特点**:

- `traits_ == EXTERNAL`;
- 不可靠数据(位置 volatile 更新)丢了就丢;
- 可靠数据(实体创建、属性变更)必须重传;
- 有 inactivity timeout,超时判定客户端掉线;
- 支持 TCP/WebSocket 回退(1.4+),通过 `TCPChannel` + `StreamFilter` 实现。

### 5.9.3 LoginApp 登录通信

LoginApp 同时是服务器(接客户端)和客户端(连 DBApp Alpha、BaseAppMgr)。典型流程是 request-response 模式:发请求到 DBApp(`dbBundle.startRequest(DBAppInterface::logOn, pDBHandler)`),等 `DatabaseReplyHandler` 回调。整个登录流程横跨 LoginApp → DBApp → BaseAppMgr → BaseApp,每跳都是 Mercury 消息。详见 `BigWorld启动流程分析.md` 第 1126-1134 行。

### 5.9.4 bwmachined 控制通信

bwmachined 是 BigWorld 的进程管理器(详见第 8 章),它通过固定端口 20018 与所有进程通信。协议是 `machine_guard.hpp` 定义的,基于 UDP 广播 + 单播。

**关键消息**:

- `HEARTBEAT`:进程定期上报状态;
- `CREATE_ENTITY` / `DESTROY_ENTITY`:进程创建/销毁实体时通知;
- `TELL_INTERFACE`:bwmachined 告诉某进程"另一个进程的接口地址在哪";
- `BIRTH_LISTENER` / `DEATH_LISTENER`:订阅某接口的诞生/死亡事件。

`Mercury::MachineDaemon::findInterface`(`BigWorld启动流程分析.md` 第 837-838、1763 行)是核心方法:进程启动时通过 bwmachined 查找其他进程的地址,然后建立 Mercury channel。

---

## 5.10 特色实现深度剖析

### 5.10.1 Bundle 设计的精妙之处

Bundle 的设计是 Mercury 最值得称道的部分。它解决了几个看似矛盾的需求:

**矛盾一:批量发送 vs 消息边界**

UDP 是无连接的,每个 `sendto` 是一个独立报文。如果每条消息一个 `sendto`,系统调用开销巨大(每次 ~1μs,1 万消息/秒就是 10ms 纯 syscall)。

Bundle 的解决方案:**多条消息共享一个 Packet,Packet 满了才发送**。`UDPBundle` 内部维护 `pFirstPacket_` 和 `pCurrentPacket_` 链表,自动分片:

```
[Bundle] ──┬── Packet #1 [msg1|msg2|msg3...]
           ├── Packet #2 [msg3(续)|msg4|msg5]
           └── Packet #3 [msg5(续)]
```

发送时遍历链表,每个 Packet 一次 `sendto`。如果一个 Bundle 有 20 条小消息,可能只需要 1 次 syscall。

**矛盾二:消息边界 vs 流式写入**

TCP 的字节流没有消息边界,需要应用层自己定边界。Mercury 的方案:**每条消息有 ID + 长度头**,接收端按 `InterfaceElement` 解析。同时,`Bundle` 继承 `BinaryOStream`,支持流式写入:

```cpp
bundle.startMessage( ie, RELIABLE_DRIVER );
bundle << a << b << c;  // 流式写
```

但 `startMessage` 已经预留了消息头位置,`<<` 写入的数据自动算入消息长度。这种"流式 + 边界"的融合很优雅。

**矛盾三:可靠 vs 不可靠混传**

一条 Bundle 里可能既有可靠消息也有不可靠消息。如果整包丢了,可靠部分要重传,不可靠部分要丢弃。

Mercury 的方案:**`ReliableOrder` 记录每条可靠消息在 Packet 中的位置和长度**(`reliable_order.hpp`)。重传时,从原 Packet 中提取可靠消息,组装成新的 Bundle 发出;不可靠部分直接丢弃。这就是 `udp_bundle.cpp:380-387` 中"没有 driver 就清空 reliableOrders"的原因——passenger 失去 driver 后,即使原包丢了也不会重传。

### 5.10.2 Channel 多路复用

**单 socket 多逻辑通道** 是 Mercury 的另一个亮点。

**问题**:BaseApp 上有 1000 个客户端,每个客户端一条 channel。如果每条 channel 一个 socket,1000 个 fd 会撑爆 select,而且 NAT 穿透几乎不可能。

**Mercury 的方案**:

1. **一个 NetworkInterface 一个 UDP socket**(通常);
2. **所有 channel 共享这个 socket**;
3. **channel 通过源地址 + (可选)ChannelID 区分**:
   - 普通 channel:源地址(IP+port+salt)唯一标识;
   - 索引 channel:源地址 + ChannelID 共同标识,允许同一对地址间跑多条独立流。
4. **接收端**:从 `recvfrom` 拿到源地址,查 `ChannelMap` 找到对应 channel,交给它处理。

**索引通道的应用**:同一个 BaseApp 上的多个实体,每个实体有独立的 base↔cell channel 对(实体的 base 在 BaseApp,cell 在 CellApp)。如果不用索引通道,就要为每对实体开一个 socket,不可行。用索引通道后,所有这些 channel 共享同一个 BaseApp↔CellApp socket,通过 ChannelID 区分。

**ChannelVersion 的作用**:实体迁移时,旧 CellApp 上的延迟包可能误送到新 CellApp。`ChannelVersion` 让接收端识别"这是旧版本的包",直接丢弃(`udp_channel.hpp:371-379`)。

### 5.10.3 Mercury 命名空间

`Mercury` 命名空间贯穿整个网络库。这个名字源自罗马神话中的信使之神 Mercurius,掌管信息、商业、旅行、盗窃(呵呵)。BigWorld 选这个名字很贴切:

- **信使**:Mercury 的核心职责就是在进程之间传递消息;
- **快速**:Mercury(水星)是太阳系中公转最快的行星,暗示这个网络库追求低延迟;
- **旅行**:网络包跨越物理距离,从一台机器"旅行"到另一台。

代码中到处可见 Mercury 的影子:`Mercury::Address`、`Mercury::Channel`、`Mercury::Bundle`、`Mercury::EventDispatcher` 等。实体邮箱(`EntityMailBoxRef`)也包含 `Mercury::Address` 作为底层地址。

### 5.10.4 与 EntityDef 的协作

BigWorld 的实体定义系统(`lib/entitydef/`)自动为每个 entity 类生成接口代码,这些代码与 Mercury 无缝协作:

1. **接口定义**:`.def` 文件声明实体方法/属性:
   ```
   # Player.def(简化)
   <Properties>
       <position> <Type> VECTOR3 </Type> <Flags> BASE_CELL_CLIENT </Flags> </position>
       <health>   <Type> int     </Type> <Flags> BASE_CLIENT </Flags> </health>
   </Properties>
   <ClientMethods>
       <onHealthChange> <Arg>int</Arg> </onHealthChange>
   </ClientMethods>
   <BaseMethods>
       <teleport> <Arg>VECTOR3</Arg> </teleport>
   </BaseMethods>
   ```

2. **代码生成**:工具生成 `PlayerInterface` 类,包含每个方法对应的 `InterfaceElement`(`static const InterfaceElement & onHealthChange();` 等)。

3. **运行时使用**:`Mercury::Bundle & b = clientProxy.bundle(); b.startMessage( PlayerInterface::onHealthChange(), RELIABLE_DRIVER ); b << newHealth; clientProxy.send();`

整个流程对上层完全透明,开发者只写业务逻辑,不用关心 Packet footer、序号、ACK 这些细节。这是 Mercury 设计的最终价值——**把复杂的网络细节封装在干净的抽象之下**。

### 5.10.5 Mailbox 的网络基础

`EntityMailBoxRef`(`basictypes.hpp:322-364`)是实体的"邮箱引用",即"如何找到另一个进程上的实体"。它的核心字段就是 `Mercury::Address`:

```cpp
class EntityMailBoxRef
{
public:
    EntityID            id;     // 实体 ID
    Mercury::Address    addr;   // 实体所在进程的地址

    enum Component { CELL, BASE, CLIENT, BASE_VIA_CELL, CLIENT_VIA_CELL, ... };

    Component component() const  { return (Component)(addr.salt >> 13); }
    EntityTypeID type() const    { return addr.salt & 0x1FFF; }
};
```

**salt 的双重用途**:

- **会话标识**:每次重连 salt 变化,避免旧连接的延迟包干扰;
- **类型编码**:高 3 位编码"组件类型"(CELL/BASE/CLIENT/...),低 13 位编码实体类型。

这种位打包让 `EntityMailBoxRef` 只占 `4(ID) + 8(Address) = 12` 字节,在数据库存储、网络传输中都很紧凑。Mailbox 系统建立在 Mercury 之上:`MailBox` 持有一个 `Channel`,通过 Mercury channel 发送消息。这部分会在后续章节详解。

### 5.10.6 CondemnedChannels 与优雅关闭

`UDPChannel` 不允许直接销毁——必须先 `condemn()`(判死刑)。这是因为:

1. channel 可能有未 ACK 的可靠包,直接销毁会让对端永远等不到 ACK;
2. 对端可能还有 in-flight 的包,需要 channel 还存在才能正确处理。

**流程**:

1. `channel.condemn()` 设 `isCondemned_ = true`,channel 移入 `CondemnedChannels` 列表;
2. channel 不再接收新消息,但继续处理 incoming ACK;
3. 当所有可靠包都被 ACK(`unackedPackets_` 空),channel 真正销毁;
4. `RecentlyDeadChannels` 记录刚死的 channel,一段时间内(默认 10s)拒绝同地址的包,避免旧连接的延迟包污染新连接。

`channel.hpp:148` 的 `destroy()` 是显式销毁,通常用于"对端明确断开"的场景;`condemn()` 是"等待收尾"的优雅关闭,用于主动断开。

### 5.10.7 加密与过滤器

Mercury 通过 `PacketFilter`(`packet_filter.hpp`)和 `StreamFilter`(`stream_filter.hpp`)支持可插拔的加密/压缩:

- **BlockCipher**(`block_cipher.hpp`):块加密接口,如 AES;
- **EncryptionFilter**(`encryption_filter.hpp`):对 Packet 加解密;
- **CompressionStream**(`compression_stream.hpp`):zlib 压缩;
- **WebSocketStreamFilter**(`websocket_stream_filter.hpp`):WebSocket 帧封装;
- **EllipticCurveChecksumScheme**(`elliptic_curve_checksum_scheme.hpp`):ECDSA 签名,用于 packet 校验。

`UDPChannel::setEncryption`(`udp_channel.hpp:111`)设置通道级加密。客户端到 BaseApp 的连接通常启用加密,服务器之间不加密(性能优先)。`shouldUseChecksums`(`network_interface.hpp:224-225`)控制是否对每个包做 checksum,公网链路建议开启,内网可关闭省 CPU。TCP 通道则通过 `StreamFilter` 在字节流层处理,适合 WebSocket 等需要帧封装的场景。

---

## 5.11 本章小结

本章从最底层的 socket 包装讲到最上层的应用集成,涵盖了 Mercury 网络库的核心:

1. **Endpoint** 是 socket 的跨平台封装,吸收 Windows/Unix/PS3/Xbox 的所有差异。
2. **Packet** 是单个 UDP 报文的内存表示,固定 1472 字节,header + body + footer 三段式布局,支持链表分片。
3. **Bundle** 是消息序列化容器,继承 `BinaryOStream`,支持流式写入,自动分片到多个 Packet,极大降低 syscall 次数。可靠性分四级(NO/DRIVER/PASSENGER/CRITICAL)。
4. **Channel** 是逻辑通道,UDPChannel 实现可靠 UDP:序号 + ACK + 重传 + 滑动窗口。支持 indexed channel 多路复用,ChannelVersion 防止跨迁移的包污染。
5. **NetworkInterface** 是顶层管理器,一个进程通常一个,聚合 socket、channel map、interface table、request manager。
6. **EventDispatcher + EventPoller** 是单线程 Reactor 模型,Linux 用 epoll,Windows 用 select。
7. **请求-响应** 通过 `Request` + `RequestManager` 实现,支持超时和 channel 失败回调。
8. **应用层**:服务器间用 INTERNAL channel(全重传),客户端到 BaseApp 用 EXTERNAL channel(只重可靠),LoginApp/bwmachined 用固定端口。
9. **特色**:Bundle 批量、Channel 多路复用、salt 双重编码、condemned 优雅关闭、可插拔加密/压缩。

读完本章,你应该能:

- 理解 Mercury 的四层抽象和它们之间的关系;
- 独立阅读 `endpoint.hpp`、`packet.hpp`、`bundle.hpp`、`channel.hpp` 的代码;
- 在调试网络问题时,知道该看哪些 watcher(channel 的 `sendWindowUsage`、`roundTripTime`、`numPacketsResent` 等);
- 添加新消息时,知道走 `.def` → 代码生成 → `InterfaceElement` → `bundle.startMessage` 的完整链路;
- 理解为什么 BigWorld 不用 TCP,以及自研可靠 UDP 的代价和收益。

下一章将进入更具体的服务器实现,讲解 BaseApp 如何在 Mercury 之上构建实体代理、客户端连接管理、负载均衡等机制。Mercury 是骨架,BaseApp 是血肉。

---

## 进一步阅读

- **第7章 服务器集群架构总览** / **第8章 进程管理与 bwmachined**:理解各进程如何通过 Mercury 协作;
- **`docs/BigWorld启动流程分析.md`**:查看各服务器进程启动时如何建立 Mercury channel;
- **`lib/network/unit_test/`**:非常完整的单元测试,是最好的学习样例;
- **`lib/network/network_lib.hpp`**:统一的 include 入口。

## 关键源码索引

| 主题 | 文件 |
|---|---|
| socket 包装 | `lib/network/endpoint.hpp` / `.ipp` |
| UDP 包 | `lib/network/packet.hpp` |
| 通道基类 | `lib/network/channel.hpp` / `.cpp` |
| UDP 可靠通道 | `lib/network/udp_channel.hpp` |
| TCP 通道 | `lib/network/tcp_channel.hpp` |
| Bundle 抽象 | `lib/network/bundle.hpp` / `.ipp` |
| UDP Bundle | `lib/network/udp_bundle.hpp` / `.cpp` |
| 消息描述 | `lib/network/interface_element.hpp` |
| 消息表 | `lib/network/interface_table.hpp` |
| 请求-响应 | `lib/network/request.hpp` / `.cpp` |
| 序号/Reason | `lib/network/misc.hpp` |
| 地址/类型 | `lib/network/basictypes.hpp` |
| 网络接口 | `lib/network/network_interface.hpp` |
| 事件循环 | `lib/network/event_dispatcher.hpp` |
| IO 多路复用 | `lib/network/event_poller.hpp` |
| 端口常量 | `lib/network/portmap.hpp` |
| bwmachined 协议 | `lib/network/machine_guard.hpp` |
| ChannelOwner | `lib/network/channel_owner.hpp` |
| 分片重组 | `lib/network/fragmented_bundle.hpp` |
| 位压缩工具 | `lib/network/msgtypes.hpp` / `.ipp` |
