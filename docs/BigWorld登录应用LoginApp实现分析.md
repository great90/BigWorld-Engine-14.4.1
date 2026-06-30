# BigWorld Engine LoginApp 实现深度分析

> 本文档详细分析 BigWorld Engine 14.4.1 中 LoginApp 进程的完整实现,涵盖架构定位、启动流程、登录认证机制、安全加密、过载保护、进程交互、关停流程等核心机制。LoginApp 是 BigWorld 服务器集群的客户端登录入口,职责单一但设计精巧。

---

## 目录

- [一、整体架构概览](#一整体架构概览)
- [二、源码目录与类结构](#二源码目录与类结构)
- [三、启动流程详解](#三启动流程详解)
- [四、登录流程详解](#四登录流程详解)
- [五、登录挑战机制](#五登录挑战机制)
- [六、认证与转发机制](#六认证与转发机制)
- [七、会话管理](#七会话管理)
- [八、安全机制](#八安全机制)
- [九、过载保护与限流](#九过载保护与限流)
- [十、网络监听](#十网络监听)
- [十一、与其他进程交互](#十一与其他进程交互)
- [十二、关停流程](#十二关停流程)
- [十三、配置项速查](#十三配置项速查)
- [十四、关键文件路径速查](#十四关键文件路径速查)
- [十五、设计亮点与注意事项](#十五设计亮点与注意事项)

---

## 一、整体架构概览

### 1.1 LoginApp 在集群中的定位

LoginApp 是 BigWorld 服务器集群的**入口进程**,承担以下核心职责:

1. 接收客户端登录请求(外部 UDP/TCP/WebSocket 接口)
2. 通过 RSA 解密客户端登录参数
3. 可选地发起登录挑战(防暴力破解)
4. 将认证请求转发给 DBApp Alpha
5. 将 DBApp 返回的 BaseApp 地址 + sessionKey 缓存并返回给客户端

### 1.2 进程拓扑

```
                            ┌─────────────────────┐
                            │   bwmachined        │
                            │ (机器守护进程)      │
                            └──────────┬──────────┘
                                       │ fork/exec + 注册
                                       ▼
┌──────────────┐   addLoginApp   ┌─────────────────┐
│              │ ◀────────────── │                 │
│  DBAppMgr    │ ──────────────▶ │   LoginApp      │
│ (单例管理)   │  回复ID+Alpha   │ (可多实例)      │
│              │                 │                 │
│  loginApps_  │ notifyDBAppAlpha│ extInterface_   │
│  集合管理    │ ──────────────▶ │ (客户端 UDP)    │
└──────┬───────┘                 │ tcpServer_      │       ┌──────────┐
       │                         │ (客户端 TCP)    │ ◀────▶ │ 客户端   │
       │                         └────────┬────────┘       │ (登录)   │
       │                                  │                └──────────┘
       ▼                                  │ logOn 请求
┌──────────────┐                          ▼
│  DBApp Alpha │                 ┌─────────────────┐
│ (实体认证)   │ ◀────────────── │  DatabaseReply  │
│              │  logOn+LogOnParams│  Handler      │
│  计费系统    │ ──────────────▶ │ (异步回复处理)  │
│  实体加载    │  LoginReplyRecord│                │
└──────┬───────┘                 └─────────────────┘
       │ createEntity
       ▼
┌──────────────┐
│  BaseAppMgr  │ ── createBaseWithCellData ──▶ BaseApp(Proxy)
│ (负载选择)   │ ◀────────────────────────── (sessionKey + proxyAddr)
└──────────────┘
```

### 1.3 关键设计原则

| 原则 | 说明 |
|------|------|
| **无状态网关** | 除登录请求缓存(用于重发)外,不持久化业务状态。实体数据在 DBApp,会话状态在 BaseApp |
| **单一管理进程** | 仅依赖 DBAppMgr 一个管理进程(不连接 BaseAppMgr/CellAppMgr) |
| **DBApp Alpha 单点** | 只与 DBApp Alpha 通信,Alpha 切换由 DBAppMgr 通知 |
| **单线程事件驱动** | 所有逻辑在主线程的 EventDispatcher 中执行,无独立网络线程 |
| **多层 DDoS 防御** | 失败回复限流 + 不可靠回复 + IP 封禁 + 速率限制 + 协议校验 |
| **加密分层** | RSA(非对称,加密登录参数)+ Blowfish(对称,加密成功回复)+ MD5(defs 摘要) |

### 1.4 与其他进程的关键差异

| 特性 | LoginApp | BaseApp/CellApp/DBApp |
|------|----------|----------------------|
| 管理进程数量 | 1 个(DBAppMgr) | 2-3 个 |
| `init*` 子方法 | **无**(单一 `init()`) | 有(initNetwork/initEntityDefs/initScript 等) |
| 异步初始化回调 | 单一 `finishInit()` | 多阶段回调 |
| 脚本/实体定义 | **不加载** | 加载 |
| Python 运行时 | **无** | 有 |
| 基类继承 | `ServerApp` 直接继承 | `ServerApp`(`ManagerApp` 仅 BaseAppMgr/CellAppMgr) |
| 外部接口 | 有(面向客户端) | 无(BaseApp 也面向客户端但通过 BaseAppMgr 分配) |
| 持久化状态 | **无** | 有 |

---

## 二、源码目录与类结构

### 2.1 源码目录结构

LoginApp 源码位于 `programming/bigworld/server/loginapp/`,共包含以下源文件:

#### 核心应用文件

| 文件 | 作用 |
|------|------|
| `main.cpp` | 程序入口,通过 `BIGWORLD_MAIN` 宏 + `bwMainT<LoginApp>` 模板启动(仅 10 行) |
| `loginapp.hpp` / `loginapp.cpp` | LoginApp 主类定义与实现 |
| `loginapp_config.hpp` / `loginapp_config.cpp` | LoginAppConfig 配置类 |
| `message_handlers.cpp` | Mercury 消息处理器注册 |

#### 登录请求与回复处理

| 文件 | 作用 |
|------|------|
| `client_login_request.hpp` / `client_login_request.cpp` | `ClientLoginRequest` 类,缓存单个客户端登录请求状态 |
| `database_reply_handler.hpp` / `database_reply_handler.cpp` | `DatabaseReplyHandler` 类,处理从 DBApp Alpha 返回的登录回复 |

#### 接口定义

| 文件 | 作用 |
|------|------|
| `login_int_interface.hpp` / `login_int_interface.cpp` | **内部接口** `LoginIntInterface` 定义 |

#### 辅助工具与配置

| 文件 | 作用 |
|------|------|
| `add_to_dbappmgr_helper.hpp` | `AddToDBAppMgrHelper` 类,向 DBAppMgr 发送 `addLoginApp` 请求 |
| `bw_config_login_challenge_config.hpp` / `.cpp` | `BWConfigLoginChallengeConfig` 适配器 |
| `login_stream_filter_factory.hpp` | `LoginStreamFilterFactory`,为 TCP 通道创建 WebSocket 流过滤器 |
| `status_check_watcher.hpp` / `status_check_watcher.cpp` | `StatusCheckWatcher`,通过 DBApp Alpha 检查系统健康状态 |

### 2.2 类继承关系

```cpp
// loginapp.hpp:48-49
class LoginApp : public ServerApp, public TimerHandler,
    public Singleton< LoginApp >
```

- **`ServerApp`**(`lib/server/server_app.hpp:54`):所有 BigWorld 服务端进程的基类,提供 `EventDispatcher`、`NetworkInterface`(内部接口)、信号处理、`Updatables` 注册、文件描述符限制、端口绑定等通用能力。**LoginApp 直接继承 ServerApp,不经过 ManagerApp**(ManagerApp 仅供 BaseAppMgr/CellAppMgr 使用)。
- **`TimerHandler`**:实现 `handleTimeout()`,用于周期性 tick 驱动 `advanceTime()`。
- **`Singleton<LoginApp>`**:全局单例,通过 `BW_SINGLETON_STORAGE(LoginApp)` 实现存储。

### 2.3 关键宏与类型别名

```cpp
// loginapp.hpp:42
typedef Mercury::ChannelOwner DBApp;   // DBApp Alpha 在 LoginApp 中以 ChannelOwner 形式持有

// loginapp.hpp:52
SERVER_APP_HEADER(LoginApp, loginApp)  // 声明 appName()="LoginApp", configPath()="loginApp"

// loginapp.hpp:54
typedef LoginAppConfig Config;
```

### 2.4 关键成员变量

| 成员 | 类型 | 行号 | 作用 |
|------|------|------|------|
| `pLogOnParamsEncoder_` | `std::auto_ptr<StreamEncoder>` | 171 | RSA 私钥编码器,用于解密客户端登录参数 |
| `extInterface_` | `Mercury::NetworkInterface` | 172 | **外部网络接口**(面向客户端),绑定到 `NETWORK_INTERFACE_EXTERNAL` |
| `pStreamFilterFactory_` | `std::auto_ptr<Mercury::StreamFilterFactory>` | 173-174 | WebSocket 流过滤器工厂 |
| `tcpServer_` | `Mercury::TCPServer` | 175 | TCP 服务器,与 `extInterface_` 共享端口 |
| `systemOverloaded_` / `systemOverloadedTime_` | `uint8` / `uint64` | 177-178 | 系统过载状态及时间戳 |
| `loginRequests_` | `map<Address, ClientLoginRequest>` | 180-181 | 当前进行中/最近完成的登录请求映射 |
| `challengeFactories_` | `LoginChallengeFactories` | 183 | 登录挑战工厂集合 |
| `dbAppAlpha_` | `DBApp`(即 `ChannelOwner`) | 185 | 与 DBApp Alpha 的通道 |
| `dbAppMgr_` | `AnonymousChannelClient` | 187 | 与 DBAppMgr 的匿名通道客户端 |
| `repliedFailsCounterResetTime_` / `numFailRepliesLeft_` | `uint64` / `uint` | 190-192 | 失败回复限流计数器 |
| `lastRateLimitCheckTime_` / `numAllowedLoginsLeft_` | `uint64` / `uint` | 197-199 | 登录速率限制状态 |
| `ipAddressBanMap_` | `map<uint32, uint64>` | 202-203 | IP 封禁表(ip → 封禁结束时间戳) |
| `nextIPAddressBanMapCleanupTime_` | `uint64` | 204 | 下次 IP 封禁表清理时间 |
| `id_` | `LoginAppID` | 206 | 由 DBAppMgr 分配的 LoginApp ID,初始 -1 |
| `loginStats_` | `LoginStats`(内嵌类) | 381 | 登录统计(EMA 平均值) |
| `statsTimer_` / `tickTimer_` | `TimerHandle` | 382/389 | 统计更新定时器(1 秒)/ tick 定时器 |

### 2.5 内嵌类 LoginStats

`LoginStats`(`loginapp.hpp:212-379`)继承自 `TimerHandler`,聚合多个 `AccumulatingEMA<uint32>`(fails/rateLimited/pending/successes/all/failedByIPAddressBan/attemptsWithPassword)与两个 `EMA`(calculationTime/verificationTime)。

- EMA 偏置 `COUNT_BIAS = 2/(5+1)`(最近 5 个样本占 86% 权重)
- `TIME_BIAS` 基于 100 个样本
- 每 1 秒更新一次(`UPDATE_STATS_PERIOD = 1000000` 微秒,`loginapp.cpp:51`)

### 2.6 关键方法签名

#### 公有方法

```cpp
LoginApp( Mercury::EventDispatcher & mainDispatcher,
        Mercury::NetworkInterface & interface );
~LoginApp();

bool finishInit( LoginAppID appID,
    const Mercury::Address & dbAppAlphaAddress );

void handleTimeout( TimerHandle handle, void * arg );  // TimerHandler override

// 外部消息处理
void login( const Mercury::Address & source,
    Mercury::UnpackedMessageHeader & header, BinaryIStream & data );
void probe( const Mercury::Address & source,
    Mercury::UnpackedMessageHeader & header, BinaryIStream & data );
void challengeResponse( const Mercury::Address & source,
    Mercury::UnpackedMessageHeader & header, BinaryIStream & data );

// 内部消息处理
void controlledShutDown( const Mercury::Address & source,
    Mercury::UnpackedMessageHeader & header, BinaryIStream & data );
void handleDBAppMgrBirth( const LoginIntInterface::handleDBAppMgrBirthArgs & args );
void notifyDBAppAlpha( const LoginIntInterface::notifyDBAppAlphaArgs & args );

// 登录流程辅助
void handleFailure( const Mercury::Address & addr,
    Mercury::Channel * pChannel, Mercury::ReplyID replyID, int status,
    const char * msg = NULL, LogOnParamsPtr pParams = NULL );
void sendAndCacheSuccess( const Mercury::Address & addr,
    Mercury::Channel * pChannel, Mercury::ReplyID replyID,
    const LoginReplyRecord & replyRecord,
    const BW::string & serverMsg, LogOnParamsPtr pParams );
void handleBanIP( const Mercury::Address & addr,
    Mercury::Channel * pChannel, Mercury::ReplyID replyID,
    LogOnParamsPtr pParams, ::time_t banDuration );

// 状态访问
Mercury::NetworkInterface & intInterface();
Mercury::NetworkInterface & extInterface();
DBApp & dbAppAlpha();
Mercury::ChannelOwner & dbAppMgr();
bool isDBReady() const;          // dbAppAlpha_.channel().isEstablished()
bool isDBAppMgrReady() const;    // dbAppMgr().channel().isEstablished()
```

#### 私有方法

```cpp
bool init( int argc, char * argv ) /* override */;
void onRunComplete() /* override */;
void onSignalled( int sigNum ) /* override */;

bool initLogOnParamsEncoder();
bool handleResentPendingAttempt( const Mercury::Address & addr, Mercury::ReplyID replyID );
bool handleResentCachedAttempt( const Mercury::Address & addr, LogOnParamsPtr pParams, Mercury::ReplyID replyID );
bool processForLoginChallenge( const Mercury::Address & addr,
    Mercury::Channel * pChannel, Mercury::ReplyID replyID, BinaryIStream & data );
void sendSuccess( ... );
void sendChallengeReply( ... );
void sendRawReply( ... );
```

---

## 三、启动流程详解

### 3.1 启动框架(bwMainT 模板)

启动入口在 `main.cpp:7-10`:

```cpp
int BIGWORLD_MAIN( int argc, char * argv[] )
{
    return bwMainT< LoginApp >( argc, argv );
}
```

`BIGWORLD_MAIN` 宏展开为 `main()`,依次执行:`BWResource::init` → `BWConfig::init` → `bwParseCommandLine` → `bwMain`。

`bwMainT<LoginApp>`(`lib/server/bwservice.hpp:97-138`)的执行顺序:

1. 创建 `Mercury::EventDispatcher dispatcher`(主线程事件分发器)
2. 向 bwmachined 查询内部接口 IP,存入 `ServerApp::discoveredInternalIP`
3. 读取 `internalInterface` 配置,创建 `Mercury::NetworkInterface interface`(内部接口,端口 0)
4. 创建 `SignalProcessor signalProcessor(dispatcher)`(信号处理器)
5. `START_MSG("LoginApp")` 输出启动 banner(版本/构建时间/UID/PID/资源路径)
6. `ServerAppConfig::init(LoginAppConfig::postInit)`:初始化所有 `ServerAppOption`,然后调用 `LoginAppConfig::postInit()`
7. 构造 `LoginApp serverApp(dispatcher, interface)`(此时 `extInterface_`、`tcpServer_` 已在构造函数中创建并尝试绑定端口)
8. `serverApp.runApp(argc, argv)`:调用 `init()` → `run()` → `fini()` → `interface_.prepareForShutdown()`

### 3.2 构造函数阶段(`loginapp.cpp:117-170`)

构造函数在 `bwMainT` 中通过 `SERVER_APP serverApp(...)` 创建,先于 `init()` 执行:

| 步骤 | 行号 | 作用 |
|------|------|------|
| 1 | 117-119 | 调用基类 `ServerApp(mainDispatcher, intInterface)` 构造:初始化 `time_`、`mainDispatcher_`、`interface_`、`startTime_`,设置 profiler,注册基础 watcher |
| 2 | 121-124 | 初始化 `extInterface_`:类型 `NETWORK_INTERFACE_EXTERNAL`,端口来自 `getExternalPort()`(默认 `PORT_LOGIN`,可按 UID 偏移) |
| 3 | 125-126 | 创建 `LoginStreamFilterFactory`(若 `shouldUseWebSockets` 默认 true) |
| 4 | 127 | 创建 `tcpServer_(extInterface_, Config::tcpServerBacklog())` |
| 5 | 148-164 | 调用 `bindToPrescribedPort` 尝试绑定 `loginApp/externalPorts/port` 列表中的端口(UDP+TCP 同端口号);失败则 `bindToRandomPort` 绑定随机端口(最多重试 20 次) |
| 6 | 167-168 | 设置 `extInterface_.pExtensionData(this)` |
| 7 | 169-170 | 配置 `dbAppAlpha_.channel()` 为非本地/非远程 regular(避免不必要的 keepalive) |

### 3.3 init() 方法详解(`loginapp.cpp:187-361`)

**关键澄清**:LoginApp 的 `init()` **没有** initNetwork/initEntityDefs/initScript 等子方法(这些是 BaseApp/CellApp/DBApp 的特性)。LoginApp 不加载实体定义、不运行 Python 脚本、不连接 BaseAppMgr/CellAppMgr。初始化全部集中在单个 `init()` 方法中:

| 步骤 | 行号 | 作用 |
|------|------|------|
| 1 | 189-192 | 调用 `ServerApp::init(argc, argv)`:创建 `SignalHandler`、启用 `SIGINT` 处理、提升文件描述符限制 |
| 2 | 194-199 | 检查 `extInterface_.isGood()`,失败则报错返回 false |
| 3 | 201-205 | 检查 `tcpServer_.isGood()`,失败则报错返回 false |
| 4 | 207 | 将 `pStreamFilterFactory_` 安装到 `tcpServer_` |
| 5 | 209-210 | 输出服务器协议版本(`ClientServerProtocolVersion::currentVersion()`) |
| 6 | 212-215 | 调用 `initLogOnParamsEncoder()`:从 `Config::privateKey()`(默认 `server/loginapp.privkey`)加载 RSA 私钥 |
| 7 | 217-221 | 检查 `intInterface().isGood()` |
| 8 | 223-229 | 检查外部/内部接口 IP 不为 0(避免端口被占) |
| 9 | 231 | 调用 `NATConfig::postInit()` 初始化 NAT 配置 |
| 10 | 236-252 | 验证内部/外部接口 IP 与 `NATConfig::isInternalIP` 一致性 |
| 11 | 254-259 | 校验 `maxRepliesOnFailPerSecond >= 2` |
| 12 | 261-266 | 注册 watcher:`numLogins`/`numLoginFailures`/`numLoginAttempts`/`clientServerProtocol`/`numBannedIPAddresses` |
| 13 | 270 | `ReviverSubject::instance().init(&intInterface(), "loginApp")`:注册到 Reviver 心跳系统 |
| 14 | 282-285 | 输出外部/内部地址 |
| 15 | 287-294 | **`BW_INIT_ANONYMOUS_CHANNEL_CLIENT`** 宏初始化 `dbAppMgr_`(`AnonymousChannelClient`),连接到 DBAppMgr 接口,重试次数 `Config::numStartupRetries()`(默认 60)。**找不到 DBAppMgr 则致命失败** |
| 16 | 296 | `LoginInterface::registerWithInterface(extInterface_)`:在**外部接口**上注册 `login`/`probe`/`challengeResponse` 消息 |
| 17 | 297 | `LoginIntInterface::registerWithInterface(intInterface())`:在**内部接口**上注册 `controlledShutDown`/`handleDBAppMgrBirth`/`notifyDBAppAlpha` 等消息 |
| 18 | 299 | 注册 `systemOverloaded` watcher |
| 19 | 301-306 | 若处于生产模式且 `allowProbe` 开启,输出配置错误警告 |
| 20 | 309-311 | 配置外部接口的人为延迟/丢包(`externalLatencyMin/Max`、`externalLossRatio`) |
| 21 | 319-320 | 设置外部接口 socket 最大处理时间(`maxExternalSocketProcessingTime`) |
| 22 | 323-335 | 配置速率限制:`rateLimitDuration`、`loginRateLimit`、`ipAddressRateLimit`、`ipAddressPortRateLimit` |
| 23 | **338** | **`new AddToDBAppMgrHelper(*this)`**:创建并向 DBAppMgr 发送 `addLoginApp` 请求。这是**异步初始化的触发点** |
| 24 | 340-344 | 配置登录挑战工厂(`challengeFactories_.configureFactories`) |
| 25 | 346-354 | 校验 `challengeType` 配置的工厂存在 |
| 26 | 356-358 | 注册 `challengeType` 读写 watcher |
| 27 | 返回 true | `init()` 完成,但真正的"完成初始化"需等待 `finishInit()` 回调 |

### 3.4 异步初始化机制

LoginApp **没有** 多阶段异步初始化回调,只依赖 **DBAppMgr** 一个管理进程,异步初始化通过单一的 `finishInit()` 回调完成:

```
LoginApp::init() 第 338 行
    └─> new AddToDBAppMgrHelper(*this)               [add_to_dbappmgr_helper.hpp:27-33]
            └─> AddToManagerHelper::send()           [在构造函数中自动调用]
                    └─> AddToDBAppMgrHelper::doSend()  [add_to_dbappmgr_helper.hpp:47-52]
                            └─> bundle.startRequest(DBAppMgrInterface::addLoginApp, this)
                            └─> dbAppMgr().send()
            [等待 DBAppMgr 回复,期间通过 resendTimerHandle_ 定时重发,
             fatalTimerHandle_ 倒计时致命超时]
                    
DBAppMgr 收到 addLoginApp 后回复 (携带 LoginAppID + DBApp Alpha 地址)
    └─> AddToManagerHelper::handleMessage()
            └─> AddToDBAppMgrHelper::finishInit(data)  [add_to_dbappmgr_helper.hpp:56-62]
                    └─> data >> appID >> dbAppAlphaAddr
                    └─> LoginApp::finishInit(appID, dbAppAlphaAddr)
```

### 3.5 finishInit() 详解(`loginapp.cpp:390-500`)

`finishInit()` 是 LoginApp 真正的"完成初始化"回调,在 DBAppMgr 分配 ID 并告知 DBApp Alpha 地址后调用:

| 步骤 | 行号 | 作用 |
|------|------|------|
| 1 | 393-394 | DEBUG 输出分配的 ID 与 DBApp Alpha 地址 |
| 2 | 396 | 保存 `id_ = appID` |
| 3 | 397 | 设置 `dbAppAlpha_.addr(dbAppAlphaAddress)`,建立与 DBApp Alpha 的通道 |
| 4 | 399-407 | `LoginIntInterface::registerWithMachined(intInterface(), id_)`:向 bwmachined 注册内部接口(失败则返回 false) |
| 5 | 409-412 | 若 `Config::registerExternalInterface()` 为 true,则向 bwmachined 注册外部接口 |
| 6 | 414 | `LoggerMessageForwarder::pInstance()->registerAppID(id_)`:将日志转发器与 appID 关联 |
| 7 | 416-417 | `MachineDaemon::registerBirthListener(interface_.address(), LoginIntInterface::handleDBAppMgrBirth, "DBAppMgrInterface")`:注册 DBAppMgr 重启监听器 |
| 8 | 420 | `enableSignalHandler(SIGUSR1)`:启用 SIGUSR1 信号处理(用于受控关停) |
| 9 | 423-424 | `BW_REGISTER_WATCHER(0, "loginapp", "loginApp", mainDispatcher_, intInterface().address())`:注册 watcher 系统 |
| 10 | 426-483 | 添加各类 watcher:`ServerApp::addWatchers`、`nubExternal`、`command/statusCheck`、`command/shutDownServer`、`command/clearIPAddressBans`、`dbAppMgr`、`averages`、`challenges/config`、`challenges/stats`、`dbAppAlpha`、`id` |
| 11 | 485-487 | 启动 `statsTimer_`(周期 `UPDATE_STATS_PERIOD = 1000000` 微秒 = 1 秒),回调 `loginStats_` 更新统计 |
| 12 | 489-492 | 启动 `tickTimer_`(周期 `1000000/Config::updateHertz()` 微秒),回调 `LoginApp::handleTimeout` 触发 `TIMEOUT_TICK` → `advanceTime()` |
| 13 | 494-497 | 若 `isDBReady()` 为 false(DBApp Alpha 通道未建立),输出提示 |
| 14 | 返回 true | 异步初始化完成,LoginApp 进入正常服务状态 |

### 3.6 单线程事件驱动模型

LoginApp 采用 **单线程事件驱动** 模型,核心是 `Mercury::EventDispatcher`:

- **主线程**:即运行 `bwMainT` 的线程,持有 `EventDispatcher dispatcher`。整个 `init()` → `run()` → `processUntilBreak()` 都在主线程执行。所有 LoginApp 业务逻辑都在主线程的事件循环中执行。
- **网络接口**:`intInterface_`(内部)与 `extInterface_`(外部)都绑定到同一个 `mainDispatcher_`。Mercury 的 `NetworkInterface` 在单线程模式下通过 dispatcher 的 `processPendingEvents()`/`processNetwork()` 收发数据,**没有独立的网络线程**。
- **TCP 服务器**:`tcpServer_` 与 `extInterface_` 共享端口,WebSocket/TCP 连接由 dispatcher 在主线程轮询处理。
- **定时器**:`statsTimer_`、`tickTimer_`、`AddToManagerHelper` 的重发/致命超时定时器,都注册在 `mainDispatcher_` 上。

### 3.7 时间推进

`tickTimer_` 触发 `handleTimeout()`(`loginapp.cpp:1111-1121`)→ `advanceTime()`(`server_app.cpp:311-335`):

1. 计算 tick 周期,调用 `onTickPeriod()`(检测 hitch)
2. `onEndOfTick()` → `++time_` → `onStartOfTick()` → `callUpdatables()` → `onTickProcessingComplete()`

---

## 四、登录流程详解

### 4.1 登录流程入口:LoginApp::login()

LoginApp 通过外部 Mercury 接口(`extInterface_`)接收客户端登录请求,入口方法为 `LoginApp::login()`(`loginapp.cpp:693-1026`)。完整流程按顺序执行的多层过滤:

#### 步骤 1:速率限制窗口刷新(第 700-707 行)

若距上次检查时间超过 `rateLimitDuration`,重置 `numAllowedLoginsLeft_` 为 `loginRateLimit`。

#### 步骤 2:allowLogin 开关(第 709-723 行)

若 `Config::allowLogin()` 为 false,返回 `LOGIN_REJECTED_LOGINS_NOT_ALLOWED`。

#### 步骤 3:IP 黑名单检查(第 725-748 行)

查询 `ipAddressBanMap_`,若仍在封禁期内,返回 `LOGIN_REJECTED_IP_ADDRESS_BAN`,并调用 `loginStats_.incFailedByIPAddressBan()`。

#### 步骤 4:IP 黑名单定期清理(第 751-765 行)

每隔 `ipBanListCleanupInterval` 秒清理过期封禁。

#### 步骤 5:空 IP 拦截(第 766-776 行)

`source.ip == 0` 视为伪造 web 客户端,直接丢弃。

#### 步骤 6:重复尝试标记(第 778-782 行)

`loginRequests_` 中已存在该地址则为 Re-attempt。

#### 步骤 7:协议版本读取(第 784-821 行)

从流中读取 `ClientServerProtocolVersion`,通过 `serverProtocol.supports(clientProtocol)` 检查兼容性,不兼容返回 `LOGIN_BAD_PROTOCOL_VERSION`。

#### 步骤 8:重发的 pending 请求处理(第 825-831 行)

`handleResentPendingAttempt()` 若返回 true,表示该地址已有进行中的登录,丢弃本次并统计 `incPending()`。

#### 步骤 9:速率限制硬拦截(第 833-848 行)

`numAllowedLoginsLeft_ == 0` 时返回 `LOGIN_REJECTED_RATE_LIMITED`。

#### 步骤 10:DB 就绪检查(第 850-861 行)

`!isDBReady()`(即 DBApp Alpha 通道未建立)时返回 `LOGIN_REJECTED_DB_NOT_READY`。

#### 步骤 11:系统过载检查(第 863-882 行)

`systemOverloaded_` 非零且未超时,返回对应的过载状态(`LOGIN_REJECTED_BASEAPP_OVERLOAD`/`CELLAPP_OVERLOAD`/`DBAPP_OVERLOAD`)。

#### 步骤 12:登录挑战处理(第 884-888 行)

调用 `processForLoginChallenge()`,若返回 true 则流程结束(详见第五章)。

#### 步骤 13:读取并解密 LogOnParams(第 890-959 行)

1. 检查 `dataLength > Config::maxLoginMessageSize()` → 返回 `LOGIN_MALFORMED_REQUEST`
2. **解密重试循环**:先尝试用 `pLogOnParamsEncoder_`(RSA 私钥解码器)调用 `pParams->readFromStream()`;若失败且 `Config::allowUnencryptedLogins()` 为 true,则不加密再试一次;否则返回 `LOGIN_MALFORMED_REQUEST`
3. 用户名/密码长度检查:超过 `maxUsernameLength`/`maxPasswordLength` 返回 `LOGIN_MALFORMED_REQUEST`

#### 步骤 14:缓存命中检查(第 961-967 行)

`handleResentCachedAttempt()`:若 `loginRequests_` 中存在同地址且 `*request.pParams() == *pParams` 且未过期(`!isTooOld()`),则重发上次成功回复,流程结束。

#### 步骤 15:最终参数校验(第 969-1003 行)

1. 速率限制计数递减 `--numAllowedLoginsLeft_`(在解密成功后才计数,避免被恶意请求耗尽)
2. **加密密钥强制要求**:`encryptionKey` 为空且不允许未加密登录 → 返回 `LOGIN_MALFORMED_REQUEST`
3. **passwordlessLoginsOnly 模式**:若启用且客户端传了密码,返回 `LOGIN_REJECTED_INVALID_PASSWORD`

#### 步骤 16:转发到 DBApp(第 1005-1025 行)

```cpp
ClientLoginRequest & loginRequest = loginRequests_[ source ];
loginRequest.reset();
loginRequest.pChannel( pChannel );
loginRequest.pParams( pParams );

DatabaseReplyHandler * pDBHandler =
    new DatabaseReplyHandler( *this, source, pChannel,
        header.replyID, pParams );

Mercury::Bundle & dbBundle = this->dbAppAlpha().bundle();
dbBundle.startRequest( DBAppInterface::logOn, pDBHandler );
dbBundle << source << *pParams;
this->dbAppAlpha().send();
```

- 在 `loginRequests_` map 中插入/重置 `ClientLoginRequest` 记录,标记为 pending
- 创建 `DatabaseReplyHandler` 作为 `ReplyMessageHandler`
- 通过 `dbAppAlpha_` 通道发送 `DBAppInterface::logOn` 请求,流中包含客户端 `source` 地址和 `LogOnParams`

### 4.2 登录流程图

```
客户端                     LoginApp                       DBApp Alpha                BaseAppMgr                BaseApp(Proxy)
  |                           |                               |                          |                          |
  |--- login(UDP/TCP) ------>|                               |                          |                          |
  |   (version+LogOnParams   |                               |                          |                          |
  |    RSA加密)              |                               |                          |                          |
  |                           |--- 前置检查(限流/IP封禁/    |                          |                          |
  |                           |    协议/DB就绪/过载)         |                          |                          |
  |                           |--- processForLoginChallenge  |                          |                          |
  |                           |    (若配置挑战,下发挑战)    |                          |                          |
  |<-- LOGIN_CHALLENGE_ISSUED|                               |                          |                          |
  |--- challengeResponse --->|                               |                          |                          |
  |                           |--- 解密 LogOnParams          |                          |                          |
  |                           |--- handleResentCachedAttempt |                          |                          |
  |                           |    (缓存命中则重发成功回复)  |                          |                          |
  |                           |--- DBAppInterface::logOn --->|                          |                          |
  |                           |    (addrForProxy+LogOnParams)|                          |                          |
  |                           |    DatabaseReplyHandler等    |                          |                          |
  |                           |    待回复                    |--- digest校验            |                          |
  |                           |                               |--- 状态/过载检查         |                          |
  |                           |                               |--- pBillingSystem        |                          |
  |                           |                               |    ->getEntityKeyForAccount                         |
  |                           |                               |    (异步,计费系统回调)   |                          |
  |                           |                               |--- getEntity/loadEntity  |                          |
  |                           |                               |--- checkOutEntity        |                          |
  |                           |                               |    (未checkout)          |                          |
  |                           |                               |--- createEntity -------->|                          |
  |                           |                               |                          |--- 选 BaseApp,创建 ---->|
  |                           |                               |                          |    Proxy                |
  |                           |                               |                          |<------------ 回复 ------|
  |                           |                               |<--- 回复(proxyAddr+     |                          |
  |                           |                               |     baseRef+sessionKey)  |                          |
  |                           |                               |--- 写 LOGGED_ON+         |                          |
  |                           |                               |    LoginReplyRecord      |                          |
  |                           |<-- 回复 ---------------------|                          |                          |
  |                           |--- DatabaseReplyHandler      |                          |                          |
  |                           |    ::handleMessage           |                          |                          |
  |                           |--- NAT转换(外网客户端)     |                          |                          |
  |                           |--- sendAndCacheSuccess       |                          |                          |
  |                           |    (缓存入 loginRequests_)   |                          |                          |
  |<-- LOGGED_ON+LoginReply --|                               |                          |                          |
  |    Record+serverMsg       |                               |                          |                          |
  |    (encryptionKey加密)    |                               |                          |                          |
  |                           |                               |                          |                          |
  |   (后续连接 BaseApp,用 sessionKey 建立加密通道) -------->|                          |                          |
```

### 4.3 DatabaseReplyHandler 处理 DBApp 回复

`DatabaseReplyHandler::handleMessage()`(`database_reply_handler.cpp:36-166`)处理 DBApp 回复:

#### 失败分支(第 45-109 行)

- `LOGIN_REJECTED_IP_ADDRESS_BAN`:解析 ban 超时字符串,调用 `handleBanIP()` 加入 `ipAddressBanMap_`
- 其他失败:读取错误描述,调用 `handleFailure()`
- **过载状态记录**:若 `BASEAPP_OVERLOAD`/`CELLAPP_OVERLOAD`/`DBAPP_OVERLOAD`,设置 `app.systemOverloaded(status)`,后续登录会被快速拒绝

#### 成功分支(第 112-166 行)

1. 校验 `data.remainingLength() >= sizeof(LoginReplyRecord)`,不足则返回 `LOGIN_CUSTOM_DEFINED_ERROR` 或 `LOGIN_REJECTED_DB_GENERAL_FAILURE`
2. 读取 `LoginReplyRecord lrr`(含 `serverAddr` + `sessionKey`)和 `serverMsg`
3. **NAT 转换**(第 154-160 行):若客户端是外网 IP,将 `lrr.serverAddr.ip` 替换为 NAT 外部地址(`NATConfig::externalIPFor`),把客户端重定向到防火墙
4. 调用 `loginApp_.sendAndCacheSuccess()`

#### 异常分支

`handleException()` 返回 `LOGIN_REJECTED_DBAPP_OVERLOAD`("No reply from DBApp")。

### 4.4 sendAndCacheSuccess 与 sendSuccess

#### sendAndCacheSuccess(`loginapp.cpp:1250-1280`)

1. 在 `loginRequests_` 中找到对应地址的 `ClientLoginRequest`
2. 调用 `request.setData(replyRecord, serverMsg)` 缓存成功结果
3. 当 `loginRequests_.size() > 100` 时遍历删除 `isTooOld()` 的项(防止内存无限增长)
4. 调用 `sendSuccess()`

#### sendSuccess(`loginapp.cpp:1287-1317`)

```cpp
Mercury::EncryptionFilterPtr pFilter =
    Mercury::EncryptionFilter::create(
        Mercury::SymmetricBlockCipher::create( encryptionKey ) );
MemoryOStream clearText;
request.writeSuccessResultToStream( clearText );
pFilter->encryptStream( clearText, data );
```

- 用客户端的 `encryptionKey` 创建 `SymmetricBlockCipher`(底层 Blowfish)→ `EncryptionFilter`
- 将 `LoginReplyRecord + serverMsg` 加密后写入流
- 调用 `sendRawReply()` 通过 `extInterface_` 或客户端 channel 发送

### 4.5 handleFailure(`loginapp.cpp:592-670`)

失败回复的速率限制:

- 每 0.5 秒重置 `numFailRepliesLeft_ = maxRepliesOnFailPerSecond / 2`
- 仅当 `numFailRepliesLeft_ > 0` 时才发送失败回复
- 失败回复用 `Mercury::RELIABLE_NO`(不可靠),避免被 DoS
- `pParams` 非空时 `loginRequests_.erase(addr)` 清理缓存

---

## 五、登录挑战机制

### 5.1 LoginChallenge 抽象接口

`LoginChallenge`(`lib/connection/login_challenge.hpp:25-66`)是登录挑战的抽象基类:

```cpp
class LoginChallenge : public SafeReferenceCount
{
public:
    virtual bool writeChallengeToStream( BinaryOStream & data ) = 0;   // 服务端→客户端
    virtual bool readChallengeFromStream( BinaryIStream & data ) = 0;  // 客户端读取
    virtual bool writeResponseToStream( BinaryOStream & data ) = 0;    // 客户端→服务端
    virtual bool readResponseFromStream( BinaryIStream & data ) = 0;   // 服务端验证
};
```

### 5.2 工厂模式

`LoginChallengeFactory`(`lib/connection/login_challenge_factory.hpp:70-117`)通过名称注册到 `LoginChallengeFactories` 容器(第 124-148 行)。

配置路径:`bw_config_login_challenge_config.cpp:10` `CHALLENGE_ROOT_PATH = "loginApp/loginChallenge"`,从 `bw.xml` 的该路径加载挑战配置。

### 5.3 挑战类型配置

- `Config::challengeType()`(`loginapp_config.hpp:51`):`bw.xml` 中的 `loginApp/challengeType`,默认空字符串(不启用)
- `challengeFactories_`(`loginapp.hpp:183`):`LoginChallengeFactories` 容器,在 `init()` 第 340-344 行通过 `configureFactories` 配置
- 运行时可通过 watcher 修改 `challengeType`(`loginapp.cpp:1504-1543`),修改后清空 `loginRequests_`(第 1511 行)避免状态不一致

### 5.4 挑战处理流程

#### processForLoginChallenge(`loginapp.cpp:1035-1105`)

1. **已有挑战记录**(`loginRequests_` 中存在该地址):
   - `didFailChallenge_` → 返回 `LOGIN_REJECTED_CHALLENGE_ERROR`
   - `pLoginChallenge_` 仍存在(等待响应)→ **重发同一挑战** `sendChallengeReply()`
   - 否则(挑战已验证)→ 返回 false,继续登录流程
2. **新请求**:`challengeType` 为空则跳过
3. 创建挑战实例 `challengeFactories_.createChallenge(challengeType)`,失败返回 `LOGIN_REJECTED_CHALLENGE_ERROR`
4. 存入 `loginRequests_[source]`,调用 `setLoginChallenge()`
5. `sendChallengeReply()` 发送 `(uint8)LOGIN_CHALLENGE_ISSUED + challengeType + challengeData`

#### challengeResponse(`loginapp.cpp:1181-1242`)

1. 查找 `loginRequests_`,无则 `*(header.pBreakLoop) = true` 终止处理
2. 若 `pLoginChallenge_` 已为 NULL,说明已验证过,丢弃重发
3. 读取 `float calculationDuration`(客户端计算耗时)
4. `pLoginChallenge()->readResponseFromStream(data)` 验证响应:
   - 失败:`didFailChallenge_ = true`,`clearChallenge()`,让后续 login 消息返回错误
   - 成功:`clearChallenge()`,记录耗时样本
5. 计算/验证时间统计:`challengeCalculationTimeSample`、`challengeVerificationTimeSample`

### 5.5 ClientLoginRequest 状态机

`ClientLoginRequest`(`client_login_request.hpp:70-79`)通过 `creationTime_`、`pLoginChallenge_`、`pParams_` 三个字段的组合表达状态:

| 状态 | 判定条件 | 来源方法 |
|------|----------|----------|
| **PENDING_CHALLENGE**(挑战进行中) | `pLoginChallenge_ != NULL` | `setLoginChallenge()` |
| **PENDING_AUTHENTICATION**(等待 DBApp 回复) | `!pLoginChallenge_ && pParams_ && creationTime_ == 0` | `login()` 中 `reset()` + `pParams()` |
| **CACHED_SUCCESS**(已成功,缓存以备重发) | `creationTime_ != 0` | `sendAndCacheSuccess()` 调用 `setData()` |
| **CHALLENGE_FAILED** | `didFailChallenge_ == true` | `challengeResponse()` 验证失败时设置 |
| **TOO_OLD**(过期清理) | `!isPendingAuthentication() && (timestamp() - creationTime_ > MAX_LOGIN_DELAY)` | `isTooOld()` |

---

## 六、认证与转发机制

### 6.1 认证不在 LoginApp 侧

LoginApp 不存在 `authenticate_helper` 文件,`DBAppInterface::authenticateAccount` 消息定义在 `lib/db/dbapp_interface.hpp:63-64`,但 **LoginApp 不调用它**(LoginApp 只调用 `DBAppInterface::logOn`)。`authenticateAccount` 供其他场景(如 BaseApp 上的认证)使用。

### 6.2 DBApp::logOn 入口(`dbapp.cpp:1997-2016`)

```cpp
void DBApp::logOn( const Mercury::Address & srcAddr,
        const Mercury::UnpackedMessageHeader & header,
        BinaryIStream & data )
{
    Mercury::Address addrForProxy;
    LogOnParamsPtr pParams = new LogOnParams();
    data >> addrForProxy >> *pParams;

    if (pParams->digest() != this->getEntityDefs().getDigest())
    {
        // 返回 LOGIN_REJECTED_BAD_DIGEST
    }
    this->logOn( srcAddr, header.replyID, pParams, addrForProxy );
}
```

- 从流中读取 `addrForProxy`(客户端地址,即 LoginApp 转发过来的 `source`)和 `LogOnParams`
- **Defs digest 校验**:客户端 entity defs 的 MD5 摘要必须与 DBApp 一致,否则返回 `LOGIN_REJECTED_BAD_DIGEST`

### 6.3 DBApp::logOn 内层重载(`dbapp.cpp:2022-2088`)

按顺序检查:

1. `status_.status() != DBStatus::RUNNING` → `LOGIN_REJECTED_SERVER_NOT_READY`
2. `!pBillingSystem_`(计费系统未注册) → `LOGIN_REJECTED_SERVER_NOT_READY`
3. **DBApp 过载**:`curLoad_ > maxLoad` → `LOGIN_REJECTED_DBAPP_OVERLOAD`
4. **CellApp 过载**:`hasOverloadedCellApps_` → `LOGIN_REJECTED_CELLAPP_OVERLOAD`
5. 创建 `LoginHandler` 并调用 `pHandler->login()`

### 6.4 LoginHandler 计费系统交互(`dbapp/login_handler.cpp`)

`LoginHandler::login()`(第 59-66 行):

```cpp
DBApp::instance().pBillingSystem()->getEntityKeyForAccount(
    pParams_->username(), pParams_->password(), clientAddr_, *this );
```

通过 `IBillingSystem::getEntityKeyForAccount()` 异步查询账号对应的实体键。回调接口 `IGetEntityKeyForAccountHandler` 有四种结果:

| 回调 | 含义 |
|------|------|
| `onGetEntityKeyForAccountSuccess(ekey, ...)` | 账号验证成功,加载现有实体 |
| `onGetEntityKeyForAccountCreateNew(typeID, ...)` | 账号验证成功,但需创建新实体 |
| `onGetEntityKeyForAccountLoadFromUsername(...)` | 账号验证成功,按用户名加载 |
| `onGetEntityKeyForAccountFailure(status, errorMsg)` | 账号验证失败,返回对应 `LogOnStatus` |

失败状态映射(`login_handler.cpp:180-200`):

| 状态 | 错误描述 |
|------|----------|
| `LOGIN_REJECTED_NO_SUCH_USER` | "Unknown user." |
| `LOGIN_REJECTED_INVALID_PASSWORD` | "Invalid password." |
| `LOGIN_REJECTED_BAN` | "User is banned." |
| `LOGIN_REJECTED_DB_GENERAL_FAILURE` | "Unexpected database failure." |

### 6.5 实体加载与 checkout

`LoginHandler::checkOutEntity()`(第 276-297 行):

- 若实体未 checkout:`onStartEntityCheckout()` 成功 → `setBaseEntityLocation()` 占位,回调 `onReservedBaseMailbox()`
- 若实体已 checkout(已在线):调用 `onLogOnLoggedOnUser()`,触发 **relogon 流程**

### 6.6 完整转发链路

```
LoginApp → DBApp Alpha → BaseAppMgr → BaseApp(Proxy)
```

1. **LoginApp → DBApp Alpha**:`dbAppAlpha_.bundle().startRequest(DBAppInterface::logOn, pDBHandler)`,流中 `<< source << *pParams`
2. **DBApp → BaseAppMgr**:`LoginHandler::sendCreateEntityMsg()` 发送 `BaseAppMgrInterface::createEntity` 消息
3. **BaseAppMgr → BaseApp**:BaseAppMgr 选择负载最低的 BaseApp(`baseappmgr.cpp:929`),向其发送 `BaseAppIntInterface::createBaseWithCellData`
4. **BaseApp 创建 Proxy 实体**:生成 sessionKey(`proxy.cpp:562-571` `Proxy::regenerateSessionKey`,使用 `uint32( timestamp() )`)
5. **DBApp 回复 LoginApp**:`LoginHandler::handleMessage` 把 `proxyAddr` + `sessionKey` 装入 `LoginReplyRecord` 回复给 LoginApp
6. **LoginApp 解析并返回客户端**:`DatabaseReplyHandler::handleMessage` 解析 `LoginReplyRecord`,调用 `sendAndCacheSuccess`

### 6.7 重登录(relogon)机制

**LoginApp 不参与 relogon 流程**(LoginApp 目录下无 relogon 相关代码)。Relogon 在 **DBApp 侧**触发:

`LoginHandler::checkOutEntity()` 发现实体已 checkout 时,创建 `RelogonAttemptHandler`(`dbapp/relogon_attempt_handler.cpp`),向已登录实体所在的 BaseApp 发起"接管"请求。

三种结果:

| 结果常量 | 处理 |
|----------|------|
| `LOG_ON_ATTEMPT_TOOK_CONTROL` | 已接管成功,回复 LoginApp `LOGGED_ON` |
| `LOG_ON_ATTEMPT_REJECTED` | 重登录被拒,回复 `LOGIN_REJECTED_ALREADY_LOGGED_IN` |
| `LOG_ON_ATTEMPT_WAIT_FOR_DESTROY` | 等待旧实体销毁,启动 5 秒定时器 |

LoginApp 在整个 relogon 流程中只是被动等待 DBApp 的回复,无特殊代码路径。

---

## 七、会话管理

### 7.1 LoginApp 端的会话缓存

LoginApp 的会话状态保存在 `loginRequests_` 成员中(`loginapp.hpp:180-181`):

```cpp
typedef BW::map< Mercury::Address, ClientLoginRequest > ClientLoginRequests;
ClientLoginRequests loginRequests_;
```

`ClientLoginRequest` 类(`client_login_request.hpp:29-79`)封装每个客户端地址对应的登录状态:

| 成员 | 类型 | 作用 |
|------|------|------|
| `creationTime_` | `uint64` | 创建时间戳,0 表示 pending |
| `pParams_` | `LogOnParamsPtr` | 客户端登录参数 |
| `pChannel_` | `Mercury::Channel *` | Mercury 通道 |
| `challengeType_` / `pLoginChallenge_` / `didFailChallenge_` | — | 挑战相关 |
| `replyRecord_` + `serverMsg_` | `LoginReplyRecord` + `BW::string` | 成功登录后缓存 |

**关键方法**:

- `isPendingAuthentication()`:返回 `!pLoginChallenge_ && pParams_ && (creationTime_ == 0)`,表示等待 DBApp 回复
- `isTooOld()`:超过 `LoginAppConfig::maxLoginDelayInStamps()`(默认 10 秒)则过期
- `setData()`:缓存成功回复

**重发处理**:

- `handleResentPendingAttempt`:处理进行中的重复请求,重新发送挑战或忽略
- `handleResentCachedAttempt`:处理已成功的重复请求,重发缓存的成功回复
- `sendAndCacheSuccess`:缓存成功结果并在 map 大小 > 100 时清理过期项

### 7.2 loginAppID 的生成和管理

`LoginAppID` 类型定义在 `lib/network/basictypes.hpp:159`:

```cpp
typedef ServerAppInstanceID LoginAppID;
```

**生成**:在 DBAppMgr 端 `dbappmgr.cpp:769` `bundle << ++lastLoginAppID_`,由 DBAppMgr 单调递增分配。`lastLoginAppID_` 初始为 0(`dbappmgr.cpp:95`),恢复时取 `args.id` 的最大值(第 787-790 行)。

**使用**:LoginApp 保存到 `id_`(`loginapp.hpp:206`),用于:

- `registerWithMachined`(`loginapp.cpp:400`)— 在 bwmachined 注册进程 ID
- `LoggerMessageForwarder::registerAppID`(第 414 行)— 日志系统标识
- watcher 暴露(第 483 行 `MF_WATCH( "id", id_ )`)

### 7.3 sessionKey 的生成和管理

`SessionKey` 类型定义在 `basictypes.hpp:171`:`typedef uint32 SessionKey`。

**关键**:LoginApp **不生成** sessionKey,它只是中转。sessionKey 由 BaseApp 的 Proxy 生成:

```cpp
// baseapp/proxy.cpp:562-571
void Proxy::regenerateSessionKey()
{
    do {
        sessionKey_ = uint32( timestamp() );
    } while (sessionKey_ == 0);
}
```

sessionKey 通过 `LoginReplyRecord` 结构传递(`lib/connection/login_reply_record.hpp:14-18`):

```cpp
struct LoginReplyRecord {
    Mercury::Address serverAddr;   // BaseApp 地址
    uint32 sessionKey;             // 会话密钥
};
```

DBApp 把 BaseAppMgr 的回复组装成 `LoginReplyRecord`(`login_handler.cpp:533-544`),LoginApp 通过 `DatabaseReplyHandler::handleMessage` 解析(`database_reply_handler.cpp:141-142` `data >> lrr`)。

### 7.4 LogOnParams 序列化格式

`LogOnParams`(`lib/connection/log_on_params.hpp:84-89`)类成员:

```cpp
Flags            flags_;          // uint8,控制可选字段
BW::string       username_;       // 用户名
BW::string       password_;       // 密码
BW::string       encryptionKey_;  // 加密密钥(用于后续通信)
uint32           nonce_;          // 随机数(防重放)
MD5::Digest      digest_;         // entity defs 的 MD5 摘要
```

**明文流格式**:

```
+---------------------+
| uint8  flags        |   控制后续字段
+---------------------+
| BW::string username |
+---------------------+
| BW::string password |
+---------------------+
| BW::string encryptionKey |
+---------------------+
| MD5::Digest digest  |   仅当 (flags & HAS_DIGEST) != 0 时存在
+---------------------+
| uint32  nonce       |
+---------------------+
```

`BW::string` 的流格式为:4 字节长度前缀 + 字符串内容。`MD5::Digest` 为 16 字节定长。

**加密格式**:客户端用 LoginApp 的 RSA 公钥加密 `LogOnParams`,LoginApp 用私钥解密。

**相等比较**(`log_on_params.hpp:71-77`):比较 `username`/`password`/`encryptionKey`/`nonce`,**不比较 digest**,用于 `handleResentCachedAttempt()` 判断是否为同一登录的重发。

---

## 八、安全机制

### 8.1 RSA 非对称加密(登录参数加密)

**LoginApp 私钥加载**(`loginapp.cpp:519-559` `initLogOnParamsEncoder`):

1. 从配置 `Config::privateKey()` 读取私钥路径,默认 `"server/loginapp.privkey"`(`loginapp_config.cpp:22`)
2. 通过 `BWResource::openSection` 加载私钥文件
3. 创建 `RSAStreamEncoder( /* keyIsPrivate: */ true )`
4. `pEncoder->initFromKeyString( keyString )` 初始化

**RSAStreamEncoder**(`lib/connection/rsa_stream_encoder.hpp`):

- 构造时创建 `Mercury::PublicKeyCipher::create( keyIsPrivate )`
- `decrypt` 调用 `pKey_->privateDecrypt`(LoginApp 用私钥解密客户端用公钥加密的数据)

**PublicKeyCipher 实现**(`lib/network/public_key_cipher.cpp`):

- 使用 OpenSSL RSA,`RSA_PKCS1_OAEP_PADDING` 填充模式,padding 大小 41 字节
- 通过 `PEM_read_bio_RSAPrivateKey` / `PEM_read_bio_RSA_PUBKEY` 加载 PEM 格式密钥
- `encrypt` 使用 `RSA_public_encrypt` 或 `RSA_private_encrypt`
- `decrypt` 使用 `RSA_private_decrypt` 或 `RSA_public_decrypt`

**加密流程**:

1. 客户端用 LoginApp 的 RSA 公钥加密 `LogOnParams`(用户名、密码、加密密钥、nonce、digest)
2. LoginApp 收到后用私钥解密(`loginapp.cpp:909-959` `do-while` 循环)
3. 若 `Config::allowUnencryptedLogins()` 为真且解密失败,则尝试不加密解析(第 939-943 行)

### 8.2 Blowfish 对称加密(会话密钥)

`SymmetricBlockCipher`(`lib/network/symmetric_block_cipher.cpp:29`)`#include "openssl/blowfish.h"`,第 106 行初始化 Blowfish 密钥。

**用途**:LoginApp 在 `sendSuccess`(`loginapp.cpp:1287-1317`)使用客户端 `LogOnParams.encryptionKey` 加密成功回复:

```cpp
Mercury::EncryptionFilterPtr pFilter =
    Mercury::EncryptionFilter::create(
        Mercury::SymmetricBlockCipher::create( encryptionKey ) );
MemoryOStream clearText;
request.writeSuccessResultToStream( clearText );
pFilter->encryptStream( clearText, data );
```

因为成功回复包含 sessionKey,必须加密保护。

### 8.3 MD5 摘要

`MD5::Digest` 在 `lib/cstdmf/md5.hpp` 和 `.cpp` 实现。

LoginApp 不验证 digest,但 DBApp 会验证(`dbapp.cpp:2006-2013`):

```cpp
if (pParams->digest() != this->getEntityDefs().getDigest())
{
    ERROR_MSG( "DBApp::logOn: Incorrect digest\n" );
    this->sendFailure( header.replyID, srcAddr,
        LogOnStatus::LOGIN_REJECTED_BAD_DIGEST, "Defs digest mismatch." );
    return;
}
```

这防止客户端与服务器 entity defs 不匹配导致登录异常。

### 8.4 IP 封禁机制

`loginapp.hpp:202-204`:

```cpp
typedef BW::map< uint32, uint64 > IPAddressBanMap;
IPAddressBanMap ipAddressBanMap_;
uint64 nextIPAddressBanMapCleanupTime_;
```

**封禁触发**:DBApp 通过 `LOGIN_REJECTED_IP_ADDRESS_BAN` 状态码和封禁时长通知 LoginApp。`database_reply_handler.cpp:47-80` 解析时长,调用 `loginApp_.handleBanIP(clientAddr_, pChannel_.get(), replyID_, pParams_, timeout)`。

`loginapp.cpp:676-687` `handleBanIP`:计算 `banEndTimestamp`,存入 `ipAddressBanMap_[addr.ip]`。

**封禁检查**:`loginapp.cpp:725-748`,登录时检查 IP 是否在封禁列表,若已过期则移除。

**定期清理**:第 751-765 行,每 `Config::ipBanListCleanupInterval()`(默认 10 秒)清理过期封禁。

**手动清除**:通过 watcher 命令 `command/clearIPAddressBans`(`loginapp.cpp:1479-1484` `clearIPAddressBans`)。

### 8.5 passwordlessLoginsOnly 模式

`loginapp.cpp:990-1003`:若配置 `Config::passwordlessLoginsOnly()` 为真且客户端发送了密码,则拒绝登录(`LOGIN_REJECTED_INVALID_PASSWORD`),统计 `incAttemptsWithPassword`。

### 8.6 LogOnStatus 枚举

**文件**:`lib/connection/log_on_status.hpp:15-79`

#### 客户端状态值(0-63)

| 值 | 枚举名 | 含义 |
|---|---|---|
| 0 | `NOT_SET` | 未设置(默认) |
| 1 | `LOGGED_ON` | 登录成功 |
| 2 | `LOGGED_ON_OFFLINE` | 离线登录成功 |
| 3 | `CONNECTION_FAILED` | 连接失败 |
| 4 | `DNS_LOOKUP_FAILED` | DNS 解析失败 |
| 5 | `UNKNOWN_ERROR` | 未知错误 |
| 6 | `CANCELLED` | 已取消 |
| 7 | `ALREADY_ONLINE_LOCALLY` | 本地已在线 |
| 8 | `PUBLIC_KEY_LOOKUP_FAILED` | 公钥查找失败 |
| 63 | `LAST_CLIENT_SIDE_VALUE` | 客户端状态值上限标记 |

#### 服务端状态值(64 起)

| 枚举名 | 含义 |
|---|---|
| `LOGIN_MALFORMED_REQUEST` | 请求格式错误 |
| `LOGIN_BAD_PROTOCOL_VERSION` | 协议版本不匹配 |
| `LOGIN_CHALLENGE_ISSUED` | 已下发挑战(非错误,中间状态) |
| `LOGIN_REJECTED_NO_SUCH_USER` | 用户不存在 |
| `LOGIN_REJECTED_INVALID_PASSWORD` | 密码错误 |
| `LOGIN_REJECTED_ALREADY_LOGGED_IN` | 已登录(重登录被拒) |
| `LOGIN_REJECTED_BAD_DIGEST` | defs 摘要不匹配 |
| `LOGIN_REJECTED_DB_GENERAL_FAILURE` | 数据库通用错误 |
| `LOGIN_REJECTED_DB_NOT_READY` | DB 未就绪 |
| `LOGIN_REJECTED_ILLEGAL_CHARACTERS` | 非法字符 |
| `LOGIN_REJECTED_SERVER_NOT_READY` | 服务器未就绪 |
| `LOGIN_REJECTED_NO_BASEAPPS` | 无可用 BaseApp |
| `LOGIN_REJECTED_BASEAPP_OVERLOAD` | BaseApp 过载 |
| `LOGIN_REJECTED_CELLAPP_OVERLOAD` | CellApp 过载 |
| `LOGIN_REJECTED_BASEAPP_TIMEOUT` | BaseApp 超时 |
| `LOGIN_REJECTED_BASEAPPMGR_TIMEOUT` | BaseAppMgr 超时 |
| `LOGIN_REJECTED_DBAPP_OVERLOAD` | DBApp 过载 |
| `LOGIN_REJECTED_LOGINS_NOT_ALLOWED` | 不允许登录(allowLogin=false) |
| `LOGIN_REJECTED_RATE_LIMITED` | 被速率限制 |
| `LOGIN_REJECTED_BAN` | 用户被封禁 |
| `LOGIN_REJECTED_CHALLENGE_ERROR` | 挑战错误 |
| `LOGIN_REJECTED_AUTH_SERVICE_NO_SUCH_ACCOUNT` | 认证服务:账号不存在 |
| `LOGIN_REJECTED_AUTH_SERVICE_LOGIN_DISALLOWED` | 认证服务:不允许登录 |
| `LOGIN_REJECTED_AUTH_SERVICE_UNREACHABLE` | 认证服务不可达 |
| `LOGIN_REJECTED_AUTH_SERVICE_INVALID_RESPONSE` | 认证服务响应无效 |
| `LOGIN_REJECTED_AUTH_SERVICE_GENERAL_FAILURE` | 认证服务通用错误 |

#### 显式赋值的高位状态值

| 值 | 枚举名 | 含义 |
|---|---|---|
| 244 | `LOGIN_REJECTED_IP_ADDRESS_BAN` | IP 被封禁(至指定时间) |
| 245 | `LOGIN_REJECTED_INACCESSIBLE_REALM` | realm 不可访问 |
| 246 | `LOGIN_REJECTED_REGISTRATION_NOT_ALLOWED` | 不允许注册 |
| 247 | `LOGIN_REJECTED_REGISTRATION_NOT_CONFIRMED` | 邮箱未确认 |
| 248 | `LOGIN_REJECTED_NOT_REGISTERED` | 账号未注册 |
| 249 | `LOGIN_REJECTED_ACTIVATING` | 注册未完成 |
| 250 | `LOGIN_REJECTED_UNABLE_TO_PARSE_JSON` | JSON 解析失败 |
| 251 | `LOGIN_REJECTED_USERS_LIMIT` | 在线用户数达上限 |
| 252 | `LOGIN_REJECTED_LOGIN_QUEUE` | 用户在登录队列中 |
| 254 | `LOGIN_CUSTOM_DEFINED_ERROR` | 自定义错误 |
| 255 | `LAST_SERVER_SIDE_VALUE` | 服务端状态值上限标记 |

---

## 九、过载保护与限流

### 9.1 多层限流机制

LoginApp 实现了四层过载保护:

#### 1. 全局登录速率限制(`loginapp.hpp:196-199`)

```cpp
uint64 lastRateLimitCheckTime_;     // 当前时间块起始
uint numAllowedLoginsLeft_;          // 剩余登录数
```

- 配置:`Config::rateLimitDuration()`(默认 0)、`Config::loginRateLimit()`(默认 0)
- 检查:`loginapp.cpp:700-707`(重置计数)和第 833-848 行(`isRateLimited`)
- 状态码:`LOGIN_REJECTED_RATE_LIMITED`
- **计数扣减在第 969-974 行,只有解密成功后才扣减**,避免恶意请求消耗配额

#### 2. 失败回复限流(`loginapp.hpp:189-192`)

```cpp
uint64 repliedFailsCounterResetTime_;
uint numFailRepliesLeft_;
```

- 配置:`Config::maxRepliesOnFailPerSecond()`(默认 100),强制要求 ≥ 2
- 实现:`handleFailure`(第 608-613 行)每 0.5 秒重置计数器为 `maxRepliesOnFailPerSecond() / 2`
- 第 615-617 行:`numFailRepliesLeft_ > 0` 才发送失败回复,**防止 DDoS 攻击**
- 第 638 行:失败回复使用 `Mercury::RELIABLE_NO`(不可靠),避免 DDoS 放大

#### 3. 每 IP 地址速率限制

- 配置:`Config::ipAddressRateLimit()`、`Config::ipAddressPortRateLimit()`(默认 0 = 禁用)
- 应用:`loginapp.cpp:333-335` `extInterface_.perIPAddressRateLimit(...)` 和 `perIPAddressPortRateLimit(...)`

#### 4. 系统过载状态(`loginapp.hpp:177-178`)

```cpp
uint8 systemOverloaded_;
uint64 systemOverloadedTime_;
```

- 设置:`systemOverloaded( status )` 同时记录时间戳(第 129-133 行)
- 触发:`database_reply_handler.cpp:98-107`,当 DBApp 返回 `LOGIN_REJECTED_BASEAPP_OVERLOAD`、`LOGIN_REJECTED_CELLAPP_OVERLOAD`、`LOGIN_REJECTED_DBAPP_OVERLOAD` 时设置
- 检查:`loginapp.cpp:863-882`,登录时检查过载状态,超过 1 秒自动清除

### 9.2 数据库未就绪保护

`loginapp.cpp:850-861`:若 `!this->isDBReady()`(DBAppAlpha 通道未建立),拒绝登录 `LOGIN_REJECTED_DB_NOT_READY`。

### 9.3 协议版本检查

`loginapp.cpp:784-821`:解析客户端协议版本,若服务器不支持则拒绝 `LOGIN_BAD_PROTOCOL_VERSION`。

### 9.4 凭证长度限制

- `Config::maxLoginMessageSize()`(默认 `PACKET_MAX_SIZE`)
- `Config::maxUsernameLength()` / `Config::maxPasswordLength()`(默认 256)

### 9.5 统计监控

`LoginStats` 内嵌类(`loginapp.hpp:212-379`)跟踪:

- `incRateLimited` / `incFails` / `incPending` / `incSuccesses` / `incFailedByIPAddressBan` / `incAttemptsWithPassword`
- `challengeCalculationTimeSample` / `challengeVerificationTimeSample`
- 通过 EMA(指数移动平均)平滑,每 1 秒更新一次

---

## 十、网络监听

### 10.1 双协议支持(UDP + TCP)

`loginapp.hpp:172-175`:

```cpp
Mercury::NetworkInterface    extInterface_;                    // UDP 外部接口
std::auto_ptr< Mercury::StreamFilterFactory > pStreamFilterFactory_;
Mercury::TCPServer           tcpServer_;                       // TCP 服务器
```

**初始化**(`loginapp.cpp:117-170`):

- 第 121-124 行:`extInterface_( &mainDispatcher, Mercury::NETWORK_INTERFACE_EXTERNAL, getExternalPort(), Config::externalInterface().c_str() )` — 创建外部 UDP 接口
- 第 125-126 行:若 `BWConfig::get( "shouldUseWebSockets", true )`,创建 `LoginStreamFilterFactory`(支持 WebSocket)
- 第 127 行:`tcpServer_( extInterface_, Config::tcpServerBacklog() )` — 创建 TCP 服务器

**端口绑定**(第 148-164 行):

- 读取 `bw.xml` 的 `loginApp/externalPorts/port` 配置(可多个端口)
- 调用 `bindToPrescribedPort` 尝试绑定指定端口
- 若失败且配置允许(`Config::shouldShutDownIfPortUsed()` 为 false),调用 `bindToRandomPort` 绑定随机端口

### 10.2 外部端口配置

`loginapp.cpp:95-105` `getExternalPort()`:

```cpp
int port = BWConfig::get( "loginApp/externalPorts/port", PORT_LOGIN );
if (LoginAppConfig::shouldOffsetExternalPortByUID()) {
    port += getUserId();
}
return htons(static_cast< uint16 >(port));
```

- 默认端口 `PORT_LOGIN`(在 `lib/network/portmap.hpp` 中定义)
- `shouldOffsetExternalPortByUID()`(默认 false)允许按 UID 偏移端口,支持同机多实例

### 10.3 接口注册

`loginapp.cpp:296-297`:

```cpp
LoginInterface::registerWithInterface( extInterface_ );           // 外部接口(客户端)
LoginIntInterface::registerWithInterface( this->intInterface() ); // 内部接口(服务器进程间)
```

**外部接口消息**(`lib/connection/login_interface.hpp:49-61`):

| 消息 | 类型 | 处理器 | 用途 |
|------|------|--------|------|
| `login` | `MERCURY_VARIABLE_MESSAGE(login, 2, ...)` | `gLoginHandler` → `LoginApp::login()` | 客户端登录请求 |
| `probe` | `MERCURY_EMPTY_MESSAGE(probe, ...)` | `gProbeHandler` → `LoginApp::probe()` | 探测服务器(返回 hostName/ownerName/usersCount) |
| `challengeResponse` | `MERCURY_VARIABLE_MESSAGE(challengeResponse, 2, ...)` | `gChallengeResponseHandler` → `LoginApp::challengeResponse()` | 客户端提交 login challenge 响应 |

**内部接口消息**(`server/loginapp/login_int_interface.hpp:31-47`):

| 消息 | 类型 | 处理器 | 用途 |
|------|------|--------|------|
| `controlledShutDown` | `MERCURY_EMPTY_MESSAGE` | `gShutDownHandler` | 受控关闭 |
| `handleDBAppMgrBirth` | `BW_BEGIN_STRUCT_MSG`(含 `Mercury::Address addr`) | 自动生成 | DBAppMgr birth 通知 |
| `notifyDBAppAlpha` | `BW_BEGIN_STRUCT_MSG`(含 `Mercury::Address addr`) | 自动生成 | 通知 DBApp Alpha 地址变更 |
| `BW_ANONYMOUS_CHANNEL_CLIENT_MSG(DBAppMgrInterface)` | 宏展开 | — | 匿名通道客户端消息(对接 DBAppMgr) |
| `MF_REVIVER_PING_MSG()` | 宏展开 | — | Reviver 心跳 |

### 10.4 TCP 与 WebSocket 支持

`LoginStreamFilterFactory`(`login_stream_filter_factory.hpp`):

- 第 38-44 行:`createFor` 为每个 TCP 通道创建 `WebSocketStreamFilter`,底层用 `TCPChannelStreamAdaptor`
- 第 48-57 行:`shouldAcceptHandshake` 接受所有握手,并调整 Emscripten 子协议

TCP 服务器设置在 `loginapp.cpp:207`:`tcpServer_.pStreamFilterFactory( pStreamFilterFactory_.get() )`。

### 10.5 外部接口模拟损耗(用于测试)

`loginapp.cpp:308-317`:

```cpp
extInterface_.setLatency( Config::externalLatencyMin(), Config::externalLatencyMax() );
extInterface_.setLossRatio( Config::externalLossRatio() );
```

### 10.6 Socket 处理时间限制

`loginapp.cpp:319-320`:`extInterface_.maxSocketProcessingTime( Config::maxExternalSocketProcessingTime() )`,默认 1.0 秒,防止单次 socket 处理占用过久。

### 10.7 NAT 配置

`loginapp.cpp:231-252`:`NATConfig::postInit()` 初始化后检查内部/外部 IP 是否匹配本地子网,否则报错退出。

`database_reply_handler.cpp:154-160`:若客户端来自外部 IP,将服务器地址替换为防火墙地址 `NATConfig::externalIPFor( lrr.serverAddr.ip )`。

---

## 十一、与其他进程交互

### 11.1 与 DBAppMgr 的交互

#### 接口定义

接口定义在 `lib/db/dbappmgr_interface.hpp`,关键消息:

- 第 59 行:`BW_STREAM_MSG_EX( DBAppMgr, addLoginApp )` — LoginApp 首次注册
- 第 61-63 行:`BW_BEGIN_STRUCT_MSG_EX( DBAppMgr, recoverLoginApp )` 含 `LoginAppID id` — 恢复注册
- 第 32-34 行:`BW_BEGIN_STRUCT_MSG( DBAppMgr, handleLoginAppDeath )` 含 `Mercury::Address addr` — 通知 LoginApp 死亡

#### 注册流程(addLoginApp)

1. **LoginApp 启动时初始化匿名通道客户端**:`loginapp.cpp:289-294`,调用 `BW_INIT_ANONYMOUS_CHANNEL_CLIENT( dbAppMgr_, ...)`,让 `dbAppMgr_`(`AnonymousChannelClient`)通过 bwmachined 找到 DBAppMgr
2. **发送 addLoginApp 请求**:`loginapp.cpp:338` `new AddToDBAppMgrHelper( *this )`,该 helper 在构造时自动 send
3. **DBAppMgr 处理 addLoginApp**(`dbappmgr.cpp:741-770`):
   - 第 758-762 行:如果 `!shouldAcceptLoginApps_ || dbApps_.empty()`,返回空回复让 LoginApp 稍后重试
   - 第 764 行:`loginApps_.insert( srcAddr )` 把 LoginApp 加入 `loginApps_` 集合
   - 第 766-767 行:计算 `dbAppAlphaAddress`
   - 第 769 行:`bundle << ++lastLoginAppID_ << dbAppAlphaAddress` — 回复分配的 LoginAppID 和 DBApp Alpha 地址
4. **LoginApp 收到回复完成 finishInit**:`add_to_dbappmgr_helper.hpp:56-62` 从流中读取 `LoginAppID` 和 `dbAppAlphaAddr`,调用 `app_.finishInit( appID, dbAppAlphaAddr )`

#### 恢复流程(recoverLoginApp)

当 DBAppMgr 重启时,已运行的 LoginApp 通过 `handleDBAppMgrBirth` 通知 DBAppMgr 自己存在(`loginapp.cpp:367-381`):

```cpp
void LoginApp::handleDBAppMgrBirth( ... )
{
    MF_ASSERT( id_ != -1 );
    Mercury::Bundle & bundle = this->dbAppMgr().bundle();
    DBAppMgrInterface::recoverLoginAppArgs & notifyArgs =
        DBAppMgrInterface::recoverLoginAppArgs::start( bundle );
    notifyArgs.id = id_;
    this->dbAppMgr().send();
}
```

DBAppMgr 的 `recoverLoginApp` 处理在 `dbappmgr.cpp:781-791`:把 srcAddr 加入 `loginApps_` 集合,并更新 `lastLoginAppID_`。

DBAppMgr 启动恢复时(`dbappmgr.cpp:192-198`)会启动 2 秒定时器 `gatherLoginAppsTimer_`,期间 `shouldAcceptLoginApps_ = false`,2 秒后才接受 LoginApp 注册(第 877-881 行 `TIMEOUT_GATHER_LOGIN_APPS` 处理)。

#### DBApp Alpha 通知(notifyDBAppAlpha)

当 DBApp Alpha 变更时(DBApp 死亡导致 Alpha 切换),DBAppMgr 通知所有 LoginApp。`dbappmgr.cpp:643-703` `sendDBAppHashUpdate`:

- 第 675-699 行:如果 `haveNewAlpha` 为真,遍历所有 `loginApps_`,发送 `LoginIntInterface::notifyDBAppAlphaArgs` 消息(第 692-695 行),含新 Alpha 地址

LoginApp 端处理在 `loginapp.cpp:506-511`:

```cpp
void LoginApp::notifyDBAppAlpha( ... )
{
    INFO_MSG( "LoginApp::notifyDBAppAlpha: %s\n", args.addr.c_str() );
    dbAppAlpha_.addr( args.addr );
}
```

#### DBApp 哈希更新

**重要**:LoginApp **不**接收 `updateDBAppHash` 消息。`dbappmgr.cpp:643-703` 的 `sendDBAppHashUpdate` 只向三类对象发送:

- BaseAppMgr(`sendDBAppHashUpdateToBaseAppMgr`)
- CellAppMgr(`sendDBAppHashUpdateToCellAppMgr`,发送 `setDBAppAlpha`)
- 各 DBApp(调用 `pDBApp->updateDBAppHash(...)`)

LoginApp 只需要知道 DBApp Alpha 的单点地址用于转发登录请求,不需要哈希分布信息。

#### LoginApp 死亡通知

`dbappmgr.cpp:322-326`:DBAppMgr 通过 bwmachined 的死亡监听器收到 `handleLoginAppDeath`,从 `loginApps_` 集合中移除该地址。

### 11.2 与 BaseAppMgr 的交互

**结论:LoginApp 与 BaseAppMgr 没有直接交互**。

对 `server/loginapp` 目录执行 grep `baseAppMgr|BaseAppMgr|cellAppMgr|CellAppMgr`,无任何匹配。

登录转发通过 DBApp 间接完成:LoginApp → DBAppAlpha → BaseAppMgr → BaseApp。LoginApp 看到的只有最终的 BaseApp 地址。

**BaseApp 死亡通知**:LoginApp 不直接接收 BaseApp 死亡通知。BaseApp 死亡时,DBAppMgr 通过 bwmachined 收到 `handleBaseAppDeath`,转发给所有 DBApp 用于重映射 mailbox。LoginApp 端通过 DBApp 返回的过载状态码 `LOGIN_REJECTED_BASEAPP_OVERLOAD` 间接感知 BaseApp 过载。

### 11.3 与 CellAppMgr 的交互

**结论:LoginApp 与 CellAppMgr 完全没有直接或间接交互**。

CellAppMgr 与 LoginApp 同样无任何代码关联。CellApp 数据由 DBApp 在 `createBaseWithCellData` 流程中通过 BaseAppMgr 间接获取。LoginApp 看到的只有最终的 BaseApp 地址。

CellAppMgr 过载信息通过 `DBApp::logOn` 检查(`dbapp.cpp:2071-2082` `hasOverloadedCellApps_`)传回 LoginApp,状态码 `LOGIN_REJECTED_CELLAPP_OVERLOAD`。

### 11.4 与 LoginAppMgr 的交互

**结论:BigWorld Engine 14.4.1 中不存在 LoginAppMgr 进程**。

验证:

- Glob 模式 `**/loginappmgr*` 无匹配
- Grep `LoginAppMgr|loginAppMgr` 在整个 `programming/bigworld` 目录无匹配

LoginApp 直接由 DBAppMgr 管理(DBAppMgr 的 `loginApps_` 集合,`dbappmgr.hpp:149-150`)。这与 BaseAppMgr 管理 BaseApps、CellAppMgr 管理 CellApps 的模式不同 — LoginApp 是 DBAppMgr 域内的子组件。

### 11.5 与 bwmachined 的交互

#### LoginApp 作为 bwmachined 子进程的启动

bwmachined 通过 `handleCreateMessage` 处理 `CREATE_MESSAGE` / `CREATE_WITH_ARGS_MESSAGE`(`server/tools/bwmachined/bwmachined.cpp:1446-1448` 和第 1725 行起):

1. 第 1738 行:通过 `users_.fetch( cm.uid_ )` 获取用户信息
2. 第 1767-1775 行:验证配置是 `Hybrid` 或 `Debug`
3. 第 1779-1789 行:禁止路径中包含 `..`(安全检查)
4. 第 1800-1808 行:禁止运行 `commands/_helpers` 下的程序(setuid root 进程)
5. 第 1813-1849 行:构造 argv,第一个参数为 `-machined`,可选 `-recover`、`-forward`
6. 调用 `startProcess` 通过 `fork/exec` 启动子进程

`-machined` 参数通过 `bwParseCommandLine`(`lib/server/bwservice.cpp:11-17`)处理,关闭控制台输出。

#### LoginApp 向 bwmachined 注册

**内部接口注册**(`loginapp.cpp:399-407`):

```cpp
Mercury::Reason reason =
    LoginIntInterface::registerWithMachined( this->intInterface(), id_ );
```

`registerWithMachined` 在 `lib/network/machined_utils.cpp:50-85` 实现:

- 构造 `ProcessMessage`,设置 `REGISTER` 标志、`SERVER_COMPONENT` 类别、端口、名称、ID、版本号
- 发送到 `LOCALHOST` 的 bwmachined 并等待回复

**外部接口注册**(`loginapp.cpp:409-412`):若 `Config::registerExternalInterface()`(默认 false),注册 `LoginInterface` 到 bwmachined,让其他进程能通过 bwmachined 找到外部接口。

#### 出生/死亡监听器

**注册 DBAppMgr 出生监听**(`loginapp.cpp:416-417`):

```cpp
Mercury::MachineDaemon::registerBirthListener( interface_.address(),
    LoginIntInterface::handleDBAppMgrBirth, "DBAppMgrInterface" );
```

`registerBirthListener` 在 `machined_utils.cpp:144-148` / `173-183` 实现:通过 `ListenerMessage` 向 bwmachined 注册。

bwmachined 端的监听器管理(`server/tools/bwmachined/listeners.cpp`):

- `handleNotify`(第 21-56 行):当进程出生/死亡时,遍历 `members_`,匹配 category/uid/name 后发送通知
- `checkListeners`(第 62-73 行):清理已死亡的监听器

#### 通过 bwmachined 查找接口

DBAppMgr 启动时通过 `MachineDaemon::findInterface` 查找其他 manager(`dbappmgr.cpp:141-167`):

- 查找 `CellAppMgrInterface`
- 查找 `BaseAppMgrInterface`

`findInterface` 在 `machined_utils.cpp:339-410`:广播 `ProcessStatsMessage`,匹配 name/uid/id,最多重试 `retries` 次。

### 11.6 客户端发现 LoginApp(probe 机制)

`loginapp.cpp:1131-1174` `probe`:

- 第 1140 行:若 `!Config::allowProbe() || header.length != 0` 则忽略
- 第 1148-1171 行:返回主机名、所有者、用户数等信息(使用 `PROBE_KEY_HOST_NAME` 等键,定义在 `login_interface.hpp:23-25`)
- 第 1144 行:回复使用 `Mercury::RELIABLE_NO`(不可靠,避免放大)

生产模式警告(第 301-306 行):若 `Config::allowProbe() && Config::isProduction()`,输出配置错误警告。

### 11.7 集群与负载均衡

#### 多 LoginApp 协同

DBAppMgr 通过 `loginApps_` 集合管理所有 LoginApp(`dbappmgr.hpp:149-150`):

```cpp
typedef BW::set< Mercury::Address > LoginApps;
LoginApps loginApps_;
```

**加入**:`addLoginApp`(`dbappmgr.cpp:764`)或 `recoverLoginApp`(第 785 行)
**移除**:`handleLoginAppDeath`(第 322-326 行)

**LoginApp 之间不直接通信**,每个 LoginApp 独立工作。客户端通过 bwmachined 探测(probe)机制发现可用的 LoginApp。

#### 负载均衡

LoginApp **不参与负载均衡决策**。负载均衡在两层:

1. **DBApp 层**:DBAppMgr 通过 Rendezvous 哈希分配实体到 DBApp
2. **BaseApp 层**:BaseAppMgr 的 `baseApps_.findLeastLoadedApp()` 选择负载最低的 BaseApp

LoginApp 只是把所有登录请求都转发给 DBAppAlpha。

#### DBApp Alpha 切换时的 LoginApp 行为

当 DBApp Alpha 死亡,DBAppMgr 通知所有 LoginApp 新的 Alpha 地址。LoginApp 在 `notifyDBAppAlpha` 中更新 `dbAppAlpha_.addr`,后续登录请求自动转向新 Alpha。期间登录请求会因 `!isDBReady()` 失败(`loginapp.cpp:850-861`)。

---

## 十二、关停流程

### 12.1 关停触发方式

LoginApp 有三种关停触发方式:

#### (1) SIGUSR1 信号(`loginapp.cpp:1490-1498`)

```cpp
void LoginApp::onSignalled( int sigNum )
{
    this->ServerApp::onSignalled( sigNum );
    if (sigNum == SIGUSR1)
    {
        this->controlledShutDown();
    }
}
```

`SIGUSR1` 在 `finishInit()` 第 420 行通过 `enableSignalHandler(SIGUSR1)` 启用。信号由 `SignalProcessor` 转发到 `ServerAppSignalHandler::handleSignal` → `LoginApp::onSignalled`。

#### (2) 内部 controlledShutDown 消息(`loginapp.cpp:1462-1470`)

通过 `LoginIntInterface::controlledShutDown` 消息(由其他服务端进程发送),最终调用无参 `controlledShutDown()`。

#### (3) watcher 命令 command/shutDownServer(`loginapp.cpp:70-78`、`432-435`)

通过 watcher 调用 `commandStopServer()` → `controlledShutDown()`。

### 12.2 controlledShutDown()(`loginapp.cpp:1473-1476`)

```cpp
void LoginApp::controlledShutDown()
{
    mainDispatcher_.breakProcessing();
}
```

**核心动作仅一行**:打破主 dispatcher 的事件循环。这会导致 `ServerApp::run()` 中的 `mainDispatcher_.processUntilBreak()` 返回,进而触发 `onRunComplete()`。

### 12.3 onRunComplete()(`loginapp.cpp:565-585`)

```cpp
void LoginApp::onRunComplete()
{
    INFO_MSG( "LoginApp::run: Terminating normally.\n" );
    this->ServerApp::onRunComplete();      // 基类空实现
    bool sent = false;
    if (this->isDBAppMgrReady())
    {
        Mercury::Bundle & dbMgrBundle = dbAppMgr_.pChannelOwner()->bundle();
        DBAppMgrInterface::controlledShutDownArgs args;
        args.stage = SHUTDOWN_REQUEST;
        dbMgrBundle << args;
        dbAppMgr_.pChannelOwner()->send();
        sent = true;
    }
    if (sent)
    {
        this->intInterface().processUntilChannelsEmpty();
    }
}
```

关停收尾逻辑:

1. 若 DBAppMgr 通道已建立,发送 `DBAppMgrInterface::controlledShutDown` 消息,`stage = SHUTDOWN_REQUEST`,通知 DBAppMgr 自己正在关停
2. 调用 `intInterface().processUntilChannelsEmpty()`:继续处理内部接口消息直到所有通道清空(确保关停通知可靠送达)

### 12.4 runApp 收尾(`server_app.cpp:253-279`)

`onRunComplete()` 返回后,`runApp()` 继续:

1. `this->fini()`(LoginApp 未覆盖,基类默认空实现)
2. `interface_.prepareForShutdown()`:内部接口准备关停
3. profiler `fini()`
4. 返回结果码

### 12.5 析构(`loginapp.cpp:176-181`)

```cpp
LoginApp::~LoginApp()
{
    this->extInterface().prepareForShutdown();
    statsTimer_.cancel();
    tickTimer_.cancel();
}
```

外部接口准备关停,取消统计/tick 定时器。

### 12.6 关于 startSystemControlledShutdown

**澄清**:LoginApp 中**没有** `startSystemControlledShutdown` 方法,也没有 `shutDown()` 的覆盖实现。`ServerApp::shutDown()`(`server_app.cpp:521-525`)的默认实现是 `mainDispatcher_.breakProcessing()`,与 `controlledShutDown()` 等效,但 LoginApp 未直接调用 `shutDown()`。LoginApp 的关停完全通过 `controlledShutDown()` → `breakProcessing()` → `onRunComplete()` 链路完成。

### 12.7 关停阶段枚举(基类定义)

`ShutDownStage`(`server_app.cpp:452-471` 定义了转换函数)包含:`SHUTDOWN_NONE`/`SHUTDOWN_REQUEST`/`SHUTDOWN_INFORM`/`SHUTDOWN_DISCONNECT_PROXIES`/`SHUTDOWN_PERFORM`/`SHUTDOWN_TRIGGER`。LoginApp 仅使用 `SHUTDOWN_REQUEST` 通知 DBAppMgr。

---

## 十三、配置项速查

### 13.1 LoginAppConfig 配置类

**文件**:`server/loginapp/loginapp_config.hpp:9-65`

```cpp
class LoginAppConfig :
    public ServerAppConfig,
    public ExternalAppConfig
```

LoginAppConfig 多重继承自:

- **`ServerAppConfig`**(`lib/server/server_app_config.hpp`):通用服务端配置
- **`ExternalAppConfig`**(`lib/server/external_app_config.hpp`):外部接口配置

### 13.2 配置项及默认值(`loginapp_config.cpp:17-55`)

所有配置项通过 `BW_OPTION` / `BW_OPTION_RO` 宏声明,前缀 `loginApp/`。`_RO` 后缀表示只读(运行时不可通过 watcher 修改)。

| 配置项 | 类型 | 默认值 | 可写 | 说明 |
|--------|------|--------|------|------|
| `shouldShutDownIfPortUsed` | bool | `true` | RO | 端口被占时是否直接关停 |
| `verboseExternalInterface` | bool | `false` | RO | 外部接口是否输出详细日志 |
| `maxExternalSocketProcessingTime` | float | `1.0f` | RO | 外部 socket 单次处理最大时间(秒) |
| `maxLoginDelay` | float | `10.f` | RW | 登录请求缓存最大保留时间(秒),用于 `isTooOld()` 判断 |
| `privateKey` | BW::string | `"server/loginapp.privkey"` | RO | RSA 私钥文件路径,用于解密登录参数 |
| `allowLogin` | bool | `false` | RW | 是否允许登录(默认关闭,需显式开启) |
| `allowProbe` | bool | `false` | RW | 是否允许 probe 探测消息 |
| `logProbes` | bool | `true` | RW | 是否记录 probe 日志 |
| `registerExternalInterface` | bool | `false` | RO | 是否向 bwmachined 注册外部接口 |
| `allowUnencryptedLogins` | bool | `false` | RW | 是否允许未加密登录 |
| `maxRepliesOnFailPerSecond` | int | `100` | RW | 每秒失败回复上限(防 DOS) |
| `verboseLoginFailures` | bool | `false` | RW | 是否输出详细登录失败日志 |
| `loginRateLimit` | int | `0` | RW | 每个时间块允许的登录数(0=不限) |
| `rateLimitDuration` | int | `0` | RW | 速率限制时间块长度(秒,0=禁用) |
| `ipAddressRateLimit` | uint | `0` | RO | 每 IP 速率限制 |
| `ipAddressPortRateLimit` | uint | `0` | RO | 每 IP:端口 速率限制 |
| `maxUsernameLength` | uint | `256` | RW | 用户名最大长度 |
| `maxPasswordLength` | uint | `256` | RW | 密码最大长度 |
| `maxLoginMessageSize` | int | `PACKET_MAX_SIZE` | RW | 登录消息最大尺寸 |
| `shouldOffsetExternalPortByUID` | bool | `false` | RO | 是否按 UID 偏移外部端口 |
| `passwordlessLoginsOnly` | bool | `false` | RW | 是否仅允许无密码登录 |
| `ipBanListCleanupInterval` | uint | `10` | RW | IP 封禁表清理间隔(秒) |
| `challengeType` | BW::string | `""` | RW | 登录挑战类型(空=不启用挑战) |
| `numStartupRetries` | int | `60` | — | 启动重试次数 |

### 13.3 继承的配置项

**来自 `ServerAppConfig`**(`server_app_config.cpp:28-58`):

- `updateHertz` = `DEFAULT_GAME_UPDATE_HERTZ`(只读)
- `personality` = `DEFAULT_PERSONALITY_NAME`(只读)
- `serverMode` = `"standalone"`(只读,可选 `"center"`/`"periphery"`)
- `isProduction` = `true`(只读)
- `timeSyncPeriod` = `60.f`(只读)
- `useDefaultSpace` = `false`(只读)
- `maxOpenFileDescriptors` = `-1`(只读,-1 表示不调整)
- `channelTimeoutPeriod`(可读写)
- `allowInteractiveDebugging`(可读写)
- `maxSharedDataValueSize` = `10240`(只读)
- `maxMgrRegisterStagger` = `0.0f`
- `numStartupRetries` = `60`

**来自 `ExternalAppConfig`**(`external_app_config.cpp:15-21`):

- `externalLatencyMin` = `0.f`(只读)
- `externalLatencyMax` = `0.f`(只读)
- `externalLossRatio` = `0.f`(只读)
- `externalInterface` = `""`(只读)
- `tcpServerBacklog` = `511`(只读)

### 13.4 辅助静态方法

- `maxLoginDelayInStamps()`(`loginapp_config.hpp:19-22`):`maxLoginDelay` 转换为时间戳
- `rateLimitDurationInStamps()`(`loginapp_config.hpp:54-57`):`rateLimitDuration` 转换为时间戳
- `rateLimitEnabled()`(`loginapp_config.hpp:59-62`):`rateLimitDuration > 0`
- `postInit()`(`loginapp_config.cpp:64-79`):调用两个基类的 `postInit`,并强制更新 `externalLatencyMin/Max`、`externalLossRatio`、`externalInterface` 的 BWConfig 引用

---

## 十四、关键文件路径速查

### 14.1 LoginApp 应用层

| 文件 | 关键内容 |
|------|----------|
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\loginapp\loginapp.hpp` | LoginApp 主类声明(成员变量、方法签名) |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\loginapp\loginapp.cpp` | LoginApp 主类实现(init/finishInit/login/challengeResponse/关停) |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\loginapp\main.cpp` | 程序入口 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\loginapp\loginapp_config.hpp` | LoginAppConfig 配置类声明 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\loginapp\loginapp_config.cpp` | LoginAppConfig 配置项定义 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\loginapp\message_handlers.cpp` | Mercury 消息处理器注册 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\loginapp\login_int_interface.hpp` | 内部接口 LoginIntInterface 定义 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\loginapp\login_int_interface.cpp` | LoginIntInterface 实现 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\loginapp\add_to_dbappmgr_helper.hpp` | AddToDBAppMgrHelper(向 DBAppMgr 注册辅助类) |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\loginapp\client_login_request.hpp` | ClientLoginRequest 类声明 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\loginapp\client_login_request.cpp` | ClientLoginRequest 实现 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\loginapp\database_reply_handler.hpp` | DatabaseReplyHandler 类声明 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\loginapp\database_reply_handler.cpp` | DatabaseReplyHandler 实现 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\loginapp\bw_config_login_challenge_config.hpp` | BWConfigLoginChallengeConfig 适配器 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\loginapp\bw_config_login_challenge_config.cpp` | 挑战配置适配器实现 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\loginapp\login_stream_filter_factory.hpp` | LoginStreamFilterFactory(WebSocket 流过滤器工厂) |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\loginapp\status_check_watcher.hpp` | StatusCheckWatcher 声明 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\loginapp\status_check_watcher.cpp` | StatusCheckWatcher 实现 |

### 14.2 接口定义层

| 文件 | 关键内容 |
|------|----------|
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\connection\login_interface.hpp` | 外部接口 LoginInterface(login/probe/challengeResponse) |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\connection\login_interface.cpp` | LoginInterface 实现 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db\dbappmgr_interface.hpp` | DBAppMgrInterface(addLoginApp/recoverLoginApp/handleLoginAppDeath) |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db\dbappmgr_interface.cpp` | DBAppMgrInterface 实现 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db\dbapp_interface.hpp` | DBAppInterface(logOn/authenticateAccount) |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\db\dbapp_interface.cpp` | DBAppInterface 实现 |

### 14.3 通用基础设施层

| 文件 | 关键内容 |
|------|----------|
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\server\server_app.hpp` | ServerApp 基类 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\server\server_app.cpp` | ServerApp 实现(runApp/advanceTime/bindToPrescribedPort) |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\server\server_app_config.hpp` | ServerAppConfig |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\server\external_app_config.hpp` | ExternalAppConfig |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\server\manager_app.hpp` | ManagerApp(BaseAppMgr/CellAppMgr 基类,LoginApp 不继承) |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\server\add_to_manager_helper.hpp` | AddToManagerHelper 基类 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\server\bwservice.hpp` | bwMainT 启动框架模板 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\server\anonymous_channel_client.hpp` | AnonymousChannelClient |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\server\child_process.hpp` | ChildProcess(fork/exec 子进程管理) |

### 14.4 网络与加密层

| 文件 | 关键内容 |
|------|----------|
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\network\network_interface.hpp` | NetworkInterface |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\network\tcp_server.hpp` | TCPServer |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\network\channel_owner.hpp` | ChannelOwner |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\network\event_dispatcher.hpp` | EventDispatcher |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\network\public_key_cipher.hpp` | PublicKeyCipher(RSA 实现) |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\network\public_key_cipher.cpp` | PublicKeyCipher 实现(OpenSSL RSA) |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\network\symmetric_block_cipher.cpp` | SymmetricBlockCipher(Blowfish 实现) |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\network\encryption_filter.hpp` | EncryptionFilter |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\network\machined_utils.hpp` | machined_utils(registerWithMachined/findInterface/registerBirthListener) |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\network\machined_utils.cpp` | machined_utils 实现 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\network\basictypes.hpp` | LoginAppID/SessionKey 类型定义(第 159、171 行) |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\network\portmap.hpp` | PORT_LOGIN 默认端口 |

### 14.5 连接层(LogOnParams/LoginChallenge)

| 文件 | 关键内容 |
|------|----------|
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\connection\log_on_status.hpp` | LogOnStatus 枚举(完整状态列表) |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\connection\log_on_params.hpp` | LogOnParams 类声明 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\connection\log_on_params.cpp` | LogOnParams 序列化实现 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\connection\login_reply_record.hpp` | LoginReplyRecord 结构(BaseApp 地址 + sessionKey) |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\connection\login_challenge.hpp` | LoginChallenge 抽象基类 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\connection\login_challenge_factory.hpp` | LoginChallengeFactory 工厂 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\connection\login_challenge_factory.cpp` | LoginChallengeFactories 实现 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\connection\rsa_stream_encoder.hpp` | RSAStreamEncoder(RSA 流编码器) |

### 14.6 DBApp 侧(认证与 relogon,参考)

| 文件 | 关键内容 |
|------|----------|
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\dbapp\dbapp.cpp` | DBApp::logOn(第 1997-2088 行) |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\dbapp\login_handler.hpp` | LoginHandler 声明 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\dbapp\login_handler.cpp` | LoginHandler 实现(计费系统交互) |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\dbapp\relogon_attempt_handler.hpp` | RelogonAttemptHandler 声明 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\dbapp\relogon_attempt_handler.cpp` | RelogonAttemptHandler 实现 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\dbapp\log_on_records_cache.hpp` | DBApp 端登录记录缓存 |

### 14.7 DBAppMgr 侧(管理 LoginApp)

| 文件 | 关键内容 |
|------|----------|
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\dbappmgr\dbappmgr.hpp` | DBAppMgr 类声明(loginApps_ 集合) |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\dbappmgr\dbappmgr.cpp` | DBAppMgr 实现(addLoginApp/recoverLoginApp/sendDBAppHashUpdate) |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\dbappmgr\dbapp.hpp` | DBApp 视图类(DBAppMgr 内部) |

### 14.8 bwmachined 侧

| 文件 | 关键内容 |
|------|----------|
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\tools\bwmachined\bwmachined.hpp` | bwmachined 主类 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\tools\bwmachined\bwmachined.cpp` | bwmachined 实现(handleCreateMessage) |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\tools\bwmachined\listeners.hpp` | Listeners(出生/死亡监听器管理) |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\tools\bwmachined\listeners.cpp` | Listeners 实现 |
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\tools\bwmachined\cluster.hpp` | Cluster(集群管理) |

### 14.9 BaseApp 侧(sessionKey 生成,参考)

| 文件 | 关键内容 |
|------|----------|
| `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\baseapp\proxy.cpp` | Proxy::regenerateSessionKey(第 562-571 行) |

---

## 十五、设计亮点与注意事项

### 15.1 设计亮点

#### 架构层面

1. **无状态网关设计**:除登录请求缓存(用于重发)外,LoginApp 不持久化任何业务状态。所有实体数据在 DBApp,所有会话状态在 BaseApp。这使得 LoginApp 可以水平扩展、随时重启而不影响业务
2. **单一管理进程依赖**:仅依赖 DBAppMgr,不连接 BaseAppMgr/CellAppMgr,极大简化了依赖关系
3. **DBApp Alpha 单点转发**:LoginApp 只与 DBApp Alpha 通信,无需了解 DBApp 哈希分布,Alpha 切换由 DBAppMgr 通知
4. **不存在 LoginAppMgr**:LoginApp 是 DBAppMgr 域内的子组件,避免引入额外管理进程

#### 启动流程层面

5. **极简初始化**:相比 BaseApp/CellApp/DBApp 的多阶段 init* 子方法,LoginApp 的初始化集中在单个 `init()` 方法中,通过单一 `finishInit()` 回调完成异步初始化
6. **不加载脚本/实体定义**:LoginApp 不运行 Python,不加载 entity defs,启动开销小
7. **构造函数中即尝试绑定端口**:端口绑定失败可在 `init()` 早期返回,避免无效初始化
8. **AddToDBAppMgrHelper 自删除对象**:构造即发送,完成即自删除,无内存泄漏风险

#### 安全机制层面

9. **加密分层**:RSA(非对称,加密登录参数)+ Blowfish(对称,加密成功回复含 sessionKey)+ MD5(defs 摘要校验),各司其职
10. **多层 DDoS 防御**:失败回复限流(`maxRepliesOnFailPerSecond`)+ 不可靠回复(`RELIABLE_NO`)+ IP 封禁 + 速率限制 + IP 地址限流 + 协议版本检查 + 空 IP 拦截 + 凭证长度限制
11. **速率限制计数延后扣减**:`numAllowedLoginsLeft_` 在解密成功后才扣减,避免恶意请求消耗配额
12. **挑战-响应可插拔**:通过 `LoginChallengeFactories` 工厂模式支持运行时切换挑战类型,watcher 修改 `challengeType` 时清空缓存避免状态不一致
13. **IP 封禁由 DBApp 决定**:LoginApp 不主动封禁 IP,由 DBApp 通过 `LOGIN_REJECTED_IP_ADDRESS_BAN` 状态码通知,避免误判
14. **NAT 转换**:外网客户端的 `LoginReplyRecord.serverAddr.ip` 替换为 NAT 外部地址,自动重定向到防火墙

#### 会话管理层面

15. **重发去重机制**:`handleResentPendingAttempt`(进行中)+ `handleResentCachedAttempt`(已成功),保证客户端因网络问题重发时获得一致结果
16. **loginRequests_ 自动清理**:`sendAndCacheSuccess` 在 map 大小 > 100 时遍历删除 `isTooOld()` 的项,防止内存无限增长
17. **sessionKey 由 BaseApp 生成**:LoginApp 只是中转,避免 LoginApp 与 BaseApp 的 sessionKey 同步问题

#### 网络监听层面

18. **UDP + TCP + WebSocket 三协议支持**:`extInterface_`(UDP)+ `tcpServer_`(TCP)+ `LoginStreamFilterFactory`(WebSocket),支持 Emscripten/Web 客户端
19. **shouldOffsetExternalPortByUID**:支持同机多实例,按 UID 偏移端口
20. **外部接口模拟损耗**:测试环境可配置 `externalLatencyMin/Max`、`externalLossRatio` 模拟网络延迟和丢包

### 15.2 注意事项

#### 架构层面

1. **DBApp Alpha 单点风险**:LoginApp 只与 DBApp Alpha 通信,Alpha 死亡期间所有登录失败(`LOGIN_REJECTED_DB_NOT_READY`),直到 DBAppMgr 通知新 Alpha 地址
2. **登录转发链路较长**:Client → LoginApp → DBAppAlpha → BaseAppMgr → BaseApp,任一环节故障都会导致登录失败
3. **无 LoginAppMgr**:LoginApp 数量管理、负载信息汇总都依赖 DBAppMgr 单进程,DBAppMgr 故障时 LoginApp 通过 `handleDBAppMgrBirth` 恢复,但期间无法接受新 LoginApp 注册

#### 启动流程层面

4. **找不到 DBAppMgr 则致命失败**:`init()` 第 287-294 行 `BW_INIT_ANONYMOUS_CHANNEL_CLIENT` 找不到 DBAppMgr 会终止进程,需确保 DBAppMgr 先于 LoginApp 启动
5. **DBAppMgr 启动恢复期 2 秒**:DBAppMgr 重启后 `shouldAcceptLoginApps_ = false` 持续 2 秒,期间 LoginApp 的 `addLoginApp` 请求会收到空回复,需重试
6. **RSA 私钥加载失败处理**:若 `allowUnencryptedLogins` 为 true 则允许继续运行,但存在安全风险

#### 安全机制层面

7. **`allowLogin` 默认 false**:需显式开启才能接受登录,防止误部署
8. **`allowProbe` 生产环境警告**:生产模式开启 probe 会暴露服务器信息(hostName/ownerName/usersCount)
9. **`allowUnencryptedLogins` 安全风险**:允许未加密登录时,LogOnParams 明文传输用户名密码
10. **`passwordlessLoginsOnly` 模式**:启用后客户端发送密码会被拒绝,需确保客户端配合
11. **IP 封禁表无持久化**:LoginApp 重启后 `ipAddressBanMap_` 清空,封禁状态丢失
12. **挑战类型运行时修改会清空缓存**:`onChallengeTypeModified` 调用 `loginRequests_.clear()`,进行中的登录请求会丢失

#### 会话管理层面

13. **`maxLoginDelay` 默认 10 秒**:客户端重发需在 10 秒内,否则缓存过期
14. **`loginRequests_` 上限 100**:超过后清理过期项,但若短时间内大量不同 IP 登录可能影响性能
15. **sessionKey 用 `timestamp()` 生成**:理论上存在碰撞可能(同一 tick 内多次生成),`do-while` 循环保证不为 0 但不保证唯一
16. **DBApp 端 LogOnRecordsCache 不是 LoginApp 的会话缓存**:`log_on_records_cache.hpp/.cpp` 位于 dbapp 目录,是 DBApp 内部的实体 mailbox 缓存

#### 网络监听层面

17. **`shouldShutDownIfPortUsed` 默认 true**:端口被占时直接关停,需确保端口可用
18. **`maxExternalSocketProcessingTime` 默认 1 秒**:单次 socket 处理超过 1 秒可能影响其他连接
19. **WebSocket 默认启用**:`BWConfig::get("shouldUseWebSockets", true)` 默认 true,需确保客户端兼容
20. **NAT 配置错误会报错退出**:`init()` 第 236-252 行检查内部/外部 IP 与 NAT 配置一致性,不匹配则失败

#### 性能层面

21. **单线程模型限制**:所有逻辑在主线程执行,大量登录请求时可能成为瓶颈
22. **失败回复限流可能丢弃合法用户**:`maxRepliesOnFailPerSecond` 默认 100,高并发场景下合法用户的失败回复可能被丢弃

---

*本文档基于 BigWorld Engine 14.4.1 源码分析生成,涵盖 LoginApp 进程的架构定位、启动流程、登录认证机制、安全加密、过载保护、进程交互、关停流程等完整实现细节。所有行号引用均基于实际源码,可作为深入研究的索引基础。*
