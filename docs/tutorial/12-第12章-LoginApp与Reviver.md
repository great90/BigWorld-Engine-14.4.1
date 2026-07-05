# 第12章 LoginApp 与 Reviver

> 前几章我们走过了 BaseApp 的玩家代理、CellApp 的空间分割、DBApp 的数据持久化——这些都是"数据平面"上的关键进程。但一个完整的 MMOG 集群还需要两个守护性角色:一个负责把玩家"接进来",一个负责在进程崩溃时"救回来"。前者就是 **LoginApp**(登录应用),它是客户端进入游戏世界的第一道门;后者就是 **Reviver**(恢复进程),它是引擎的看门狗,默默守护着 5 类关键进程的存活。本章将带你走进这两个看似不起眼、实则承载着"入口"与"保障"双重职责的进程,看清它们的设计哲学与实现细节。

---

## 目录

- [第一部分:LoginApp 登录应用](#第一部分loginapp-登录应用)
  - [12.1 LoginApp 概述](#121-loginapp-概述)
  - [12.2 登录流程详解](#122-登录流程详解)
  - [12.3 核心组件](#123-核心组件)
  - [12.4 LoginInt 接口](#124-loginint-接口)
  - [12.5 认证机制](#125-认证机制)
  - [12.6 多 LoginApp 支持](#126-多-loginapp-支持)
- [第二部分:Reviver 故障恢复](#第二部分reviver-故障恢复)
  - [12.7 Reviver 概述](#127-reviver-概述)
  - [12.8 ComponentReviver 5 特化类](#128-componentreviver-5-特化类)
  - [12.9 双死亡检测机制](#129-双死亡检测机制)
  - [12.10 ReviverSubject 优先级仲裁](#1210-reviversubject-优先级仲裁)
  - [12.11 主备切换 shutDownOnRevive](#1211-主备切换-shutdownonrevive)
  - [12.12 与 bwmachined 的协作](#1212-与-bwmachined-的协作)
  - [12.13 配置项](#1213-配置项)
  - [12.14 特色实现深度剖析](#1214-特色实现深度剖析)
  - [12.15 本章小结](#1215-本章小结)

---

## 第一部分:LoginApp 登录应用

### 12.1 LoginApp 概述

#### 12.1.1 它是什么

当你打开 MMOG 客户端,输入账号密码,点击"登录"的那一刻,客户端发出的第一个网络包并不是直接飞向 BaseApp 或 CellApp,而是先打到一个叫 **LoginApp** 的进程上。它是 BigWorld 服务器集群的**入口进程**——所有玩家进入游戏世界前,都必须先经过它的"安检"。

LoginApp 的源码位于 `programming/bigworld/server/loginapp/`,在 `CMakeLists.txt` 中通过 `BW_ADD_EXECUTABLE( loginapp ... )` 生成独立可执行文件。它链接 `server`、`network`、`connection`、`db` 等库,但不链接任何与实体、空间、Python 脚本相关的库——这暗示了它的核心特征:**职责单一,不沾业务**。

#### 12.1.2 核心职责

LoginApp 的职责可以概括为五点:

| 职责 | 描述 | 关键源码 |
|---|---|---|
| 接收登录请求 | 通过外部 UDP/TCP/WebSocket 接口接收客户端登录包 | `loginapp.cpp::login` |
| 解密登录参数 | 用 RSA 私钥解密客户端加密的 LogOnParams | `loginapp.cpp::initLogOnParamsEncoder` |
| 转发认证 | 将解密后的账号信息转发给 DBApp Alpha 做认证 | `loginapp.cpp::login`(末段)|
| 缓存与重发 | 缓存成功回复,客户端重试时直接重发,避免重复 DB 查询 | `loginapp.cpp::sendAndCacheSuccess` |
| 多层防御 | 速率限制、IP 封禁、失败限流、协议校验,防 DDoS | `loginapp.cpp::handleFailure` |

#### 12.1.3 在集群中的定位

LoginApp 是一个**无状态网关**。除了登录请求缓存(用于重发)外,它不持久化任何业务状态——实体数据在 DBApp,会话状态在 BaseApp,空间状态在 CellApp。这意味着 LoginApp 可以随时重启而不影响在线玩家。

它只与**一个**管理进程通信:DBAppMgr。这与 BaseAppMgr、CellAppMgr 等管理多个进程的"枢纽"角色截然不同。下图展示了 LoginApp 在集群中的位置:

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
│              │ notifyDBAppAlpha│                 │
└──────┬───────┘                 │ extInterface_   │
       │                         │ (客户端 UDP/TCP)│       ┌──────────┐
       │                         └────────┬────────┘ ◀────▶ │ 客户端   │
       │                                  │                └──────────┘
       ▼                                  │ logOn 请求
┌──────────────┐                          ▼
│  DBApp Alpha │                 ┌─────────────────┐
│ (实体认证)   │ ◀────────────── │  DatabaseReply  │
│              │  logOn+LogOnParams│  Handler      │
└──────┬───────┘ ──────────────▶ │ (异步回复处理)  │
       │ createEntity            └─────────────────┘
       ▼
┌──────────────┐
│  BaseAppMgr  │ ── createBaseWithCellData ──▶ BaseApp(Proxy)
└──────────────┘
```

#### 12.1.4 类继承关系

LoginApp 主类定义在 `loginapp.hpp` 中,采用三重继承:

```cpp
// programming/bigworld/server/loginapp/loginapp.hpp  L48-49
class LoginApp : public ServerApp, public TimerHandler,
    public Singleton< LoginApp >
```

| 基类 | 作用 |
|------|------|
| `ServerApp` | 所有服务端进程的基类,提供 `EventDispatcher`、`NetworkInterface`、信号处理、`Updatables` 注册等通用能力 |
| `TimerHandler` | 实现周期性 tick,驱动 `advanceTime()` 与统计更新 |
| `Singleton<LoginApp>` | 全局单例,通过 `BW_SINGLETON_STORAGE(LoginApp)` 实现存储 |

注意 LoginApp 直接继承 `ServerApp`,**不经过 `ManagerApp`**(`ManagerApp` 仅供 BaseAppMgr/CellAppMgr 使用)。这是因为 LoginApp 不是管理进程,它只是个"门卫"。

#### 12.1.5 与其他进程的关键差异

下表对比 LoginApp 与 BaseApp/CellApp/DBApp 的差异,帮助你理解它的"轻量"定位:

| 特性 | LoginApp | BaseApp/CellApp/DBApp |
|------|----------|----------------------|
| 管理进程数量 | 1 个(DBAppMgr) | 2-3 个 |
| 加载实体定义 | **不加载** | 加载 |
| Python 运行时 | **无** | 有 |
| 持久化状态 | **无** | 有 |
| 外部接口 | 有(面向客户端) | 无 |
| `init*` 子方法 | **无**(单一 `init()`) | 有(initNetwork/initEntityDefs 等) |

---

### 12.2 登录流程详解

#### 12.2.1 整体流程

完整的登录流程涉及 5 个进程:客户端、LoginApp、DBApp Alpha、BaseAppMgr、BaseApp(Proxy)。流程如下:

```
客户端                     LoginApp                       DBApp Alpha                BaseAppMgr                BaseApp(Proxy)
  |                           |                               |                          |                          |
  |--- login(UDP/TCP) ------>|                               |                          |                          |
  |   (version+LogOnParams    |                               |                          |                          |
  |    RSA加密)               |                               |                          |                          |
  |                           |--- 前置检查(限流/IP封禁/     |                          |                          |
  |                           |    协议/DB就绪/过载)          |                          |                          |
  |                           |--- processForLoginChallenge   |                          |                          |
  |                           |    (若配置挑战,下发挑战)     |                          |                          |
  |<-- LOGIN_CHALLENGE_ISSUED |                               |                          |                          |
  |--- challengeResponse ---->|                               |                          |                          |
  |                           |--- DBAppInterface::logOn ---->|                          |                          |
  |                           |    (addrForProxy+LogOnParams) |                          |                          |
  |                           |    DatabaseReplyHandler 等   |                          |                          |
  |                           |    待回复                     |--- 认证+加载实体 -------->|                          |
  |                           |                               |--- createBaseWithCellData ─────────────────────────>  |
  |                           |                               |                          |--- 创建 Proxy ---------->|
  |                           |                               |<── 回复(proxyAddr+      |                          |
  |                           |                               |     baseRef+sessionKey) |                          |
  |                           |<── 回复(LOGGED_ON+           |                          |                          |
  |                           |     LoginReplyRecord)         |                          |                          |
  |<-- LOGGED_ON+LoginReply --|                               |                          |                          |
  |    Record+serverMsg       |                               |                          |                          |
  |    (encryptionKey加密)    |                               |                          |                          |
  |   (后续连接 BaseApp,用 sessionKey 建立加密通道)─────────>|                          |                          |
```

#### 12.2.2 LoginApp::login() 详解

入口方法是 `LoginApp::login()`(`loginapp.cpp:693-1026`),它执行一系列多层过滤,每层都可能拒绝请求或提前返回。我们把整个流程拆解为 16 个步骤:

**步骤 1:速率限制窗口刷新**(第 700-707 行)

若距上次检查时间超过 `rateLimitDuration`,重置 `numAllowedLoginsLeft_` 为 `loginRateLimit`。这是一个**滑动窗口**机制,确保单位时间内最多处理 N 个登录。

**步骤 2:allowLogin 开关**(第 709-723 行)

若 `Config::allowLogin()` 为 false,返回 `LOGIN_REJECTED_LOGINS_NOT_ALLOWED`。这是运维的"总闸",可以在维护期间关闭登录。

**步骤 3:IP 黑名单检查**(第 725-748 行)

查询 `ipAddressBanMap_`,若客户端 IP 仍在封禁期内,返回 `LOGIN_REJECTED_IP_ADDRESS_BAN`。封禁是 DBApp 在认证时通过 `LOGIN_REJECTED_IP_ADDRESS_BAN` 状态触发的(见 12.5 节)。

**步骤 4:IP 黑名单定期清理**(第 751-765 行)

每隔 `ipBanListCleanupInterval` 秒(默认 10 秒)遍历 `ipAddressBanMap_`,删除已过期的封禁项,防止 map 无限增长。

**步骤 5:空 IP 拦截**(第 766-776 行)

`source.ip == 0` 视为伪造的 web 客户端,直接丢弃。这是防御性编程——正常客户端的 IP 不会是 0。

**步骤 6:重复尝试标记**(第 778-782 行)

若 `loginRequests_` 中已存在该地址,标记为 Re-attempt(可能是客户端因 UDP 丢包而重发)。

**步骤 7:协议版本读取**(第 784-821 行)

从流中读取 `ClientServerProtocolVersion`,通过 `serverProtocol.supports(clientProtocol)` 检查兼容性。不兼容返回 `LOGIN_BAD_PROTOCOL_VERSION`——这避免了用旧客户端连接新服务器的混乱。

**步骤 8:重发的 pending 请求处理**(第 825-831 行)

调用 `handleResentPendingAttempt()`:若该地址已有进行中的登录,丢弃本次并统计 `incPending()`。这防止客户端因 UDP 丢包反复重发导致 DBApp 被重复查询。

**步骤 9:速率限制硬拦截**(第 833-848 行)

`numAllowedLoginsLeft_ == 0` 时返回 `LOGIN_REJECTED_RATE_LIMITED`。这是限流的"硬墙"。

**步骤 10:DB 就绪检查**(第 850-861 行)

`!isDBReady()`(即 DBApp Alpha 通道未建立)时返回 `LOGIN_REJECTED_DB_NOT_READY`。这避免了在数据库未就绪时盲目转发请求。

**步骤 11:系统过载检查**(第 863-882 行)

`systemOverloaded_` 非零且未超时,返回对应的过载状态(`LOGIN_REJECTED_BASEAPP_OVERLOAD`/`CELLAPP_OVERLOAD`/`DBAPP_OVERLOAD`)。过载状态由 DBApp 在认证回复中反馈,LoginApp 缓存 1 秒后自动清除。

**步骤 12:登录挑战处理**(第 884-888 行)

调用 `processForLoginChallenge()`:若配置了登录挑战(如验证码),下发挑战并等待客户端回应。详见 12.5 节。

**步骤 13:读取并解密 LogOnParams**(第 890-959 行)

这是核心步骤。LoginApp 用 `pLogOnParamsEncoder_`(RSA 私钥解码器)解密客户端的登录参数:

```cpp
// 简化的解密重试循环(loginapp.cpp:911-959)
do
{
    MemoryIStream attempt = MemoryIStream( pDataData, dataLength );
    if (pParams->readFromStream( attempt, pEncoder ))
    {
        // 解密成功,跳出循环
        break;
    }
    if (pEncoder && Config::allowUnencryptedLogins())
    {
        // 加密失败,尝试不加密
        pEncoder = NULL;
        continue;
    }
    // 都失败,返回 MALFORMED_REQUEST
    this->handleFailure( source, pChannel, header.replyID,
        LogOnStatus::LOGIN_MALFORMED_REQUEST );
    return;
}
while (false);
```

注意这里有个**降级机制**:若 RSA 解密失败且 `allowUnencryptedLogins` 为 true,会尝试不加密读取。这是为了开发环境方便调试,生产环境应关闭。

**步骤 14:缓存命中检查**(第 961-967 行)

`handleResentCachedAttempt()`:若 `loginRequests_` 中存在同地址且 `*request.pParams() == *pParams` 且未过期(`!isTooOld()`),直接重发上次成功回复,流程结束。这是 UDP 重传的关键优化——客户端丢包重发时不会重复查 DB。

**步骤 15:最终参数校验**(第 969-1003 行)

- 速率限制计数递减 `--numAllowedLoginsLeft_`(在解密成功后才计数,避免被恶意请求耗尽配额)
- **加密密钥强制要求**:`encryptionKey` 为空且不允许未加密登录 → 拒绝
- **passwordlessLoginsOnly 模式**:若启用且客户端传了密码,拒绝(用于无密码的快速登录场景)

**步骤 16:转发到 DBApp**(第 1005-1025 行)

最终,LoginApp 把认证请求转发给 DBApp Alpha:

```cpp
// loginapp.cpp:1011-1025
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

这里的关键设计:
- 在 `loginRequests_` map 中插入 `ClientLoginRequest` 记录,标记为 pending
- 创建 `DatabaseReplyHandler` 作为异步回复处理器
- 通过 `dbAppAlpha_` 通道发送 `DBAppInterface::logOn` 请求,流中包含客户端地址和 LogOnParams

#### 12.2.3 DBApp 回复处理

DBApp Alpha 收到 `logOn` 请求后,执行认证、加载实体、通过 BaseAppMgr 创建 Proxy,最后返回 `LoginReplyRecord`(含 BaseApp 地址 + sessionKey)。LoginApp 端的 `DatabaseReplyHandler::handleMessage()`(`database_reply_handler.cpp:36-166`)处理这个回复:

**失败分支**:解析状态码,若是 `LOGIN_REJECTED_IP_ADDRESS_BAN` 则解析 ban 超时并调用 `handleBanIP()` 加入 IP 封禁表;若是过载状态(`BASEAPP_OVERLOAD` 等),设置 `app.systemOverloaded(status)`,后续登录会被快速拒绝。

**成功分支**:

```cpp
// database_reply_handler.cpp:141-163(简化)
LoginReplyRecord lrr;
data >> lrr;

BW::string serverMsg;
if (data.remainingLength() > 0)
{
    data >> serverMsg;
}

// NAT 转换:外网客户端重定向到防火墙
if (NATConfig::isExternalIP( clientAddr_.ip ))
{
    lrr.serverAddr.ip = NATConfig::externalIPFor( lrr.serverAddr.ip );
}

loginApp_.sendAndCacheSuccess( clientAddr_, pChannel_.get(),
        replyID_, lrr, serverMsg, pParams_ );
```

注意 **NAT 转换**:若客户端是外网 IP,会把 `LoginReplyRecord.serverAddr.ip`(BaseApp 的内网地址)替换为 NAT 外部地址。这让 LoginApp 部署在内网时,仍能给外网客户端正确的连接地址。

#### 12.2.4 sendAndCacheSuccess 与缓存机制

`sendAndCacheSuccess()`(`loginapp.cpp:1250-1280`)把成功结果缓存到 `loginRequests_` map 中:

```cpp
// loginapp.cpp:1255-1256
ClientLoginRequest & request = loginRequests_[ addr ];
request.setData( replyRecord, serverMsg );
```

之后调用 `sendSuccess()`(`loginapp.cpp:1287-1317`)用客户端的 `encryptionKey`(Blowfish 对称密钥)加密 `LoginReplyRecord + serverMsg` 后发送。

为什么需要缓存?因为 UDP 是不可靠的——LoginApp 发给客户端的成功回复可能丢包,客户端会重发登录请求。此时 LoginApp 不需要再走一遍 DBApp 认证,直接从缓存中取出上次的结果重发即可。`handleResentCachedAttempt()` 就是干这事的(步骤 14)。

为防止内存无限增长,当 `loginRequests_.size() > 100` 时遍历删除 `isTooOld()` 的项(`loginapp.cpp:1265-1279`)。

---

### 12.3 核心组件

LoginApp 的源码组织如下:

```
server/loginapp/
├── main.cpp                    # 程序入口,BIGWORLD_MAIN + bwMainT<LoginApp>
├── loginapp.hpp / .cpp         # LoginApp 主类
├── loginapp_config.hpp / .cpp  # LoginAppConfig 配置类
├── client_login_request.hpp / .cpp  # ClientLoginRequest 类
├── database_reply_handler.hpp / .cpp # DatabaseReplyHandler 类
├── login_int_interface.hpp / .cpp    # 内部接口 LoginIntInterface
├── message_handlers.cpp        # Mercury 消息处理器注册
├── status_check_watcher.hpp / .cpp   # StatusCheckWatcher
├── add_to_dbappmgr_helper.hpp # AddToDBAppMgrHelper
├── bw_config_login_challenge_config.hpp / .cpp  # 挑战配置适配器
└── login_stream_filter_factory.hpp   # WebSocket 流过滤器工厂
```

#### 12.3.1 ClientLoginRequest

`ClientLoginRequest`(`client_login_request.hpp`)缓存单个客户端登录请求的完整状态:

```cpp
// client_login_request.hpp:29-79(关键成员)
class ClientLoginRequest
{
private:
    uint64               creationTime_;        // 创建时间戳(用于 isTooOld)
    LogOnParamsPtr       pParams_;             // 客户端登录参数
    Mercury::Channel *   pChannel_;            // 客户端 channel
    BW::string           challengeType_;       // 挑战类型
    bool                 didFailChallenge_;    // 是否挑战失败
    LoginChallengePtr    pLoginChallenge_;     // 当前挑战实例
    LoginReplyRecord     replyRecord_;         // 成功回复记录(缓存)
    BW::string           serverMsg_;           // 服务器消息(缓存)
};
```

它的核心方法:

| 方法 | 作用 |
|------|------|
| `setLoginChallenge()` | 设置挑战实例,标记为 pending |
| `hasPendingChallenge()` | 是否有未回应的挑战 |
| `isPendingAuthentication()` | 是否在等 DBApp 回复 |
| `setData()` | 缓存成功结果(replyRecord + serverMsg) |
| `isTooOld()` | 缓存是否过期(用于清理) |
| `writeSuccessResultToStream()` | 把缓存结果写入流(用于重发) |

这个类是 LoginApp "无状态网关"中**唯一的有状态部分**——它缓存的是"刚刚发生过的登录",用于应对 UDP 重传。

#### 12.3.2 DatabaseReplyHandler

`DatabaseReplyHandler`(`database_reply_handler.hpp`)继承自 `Mercury::ReplyMessageHandler`,处理从 DBApp Alpha 返回的异步回复。它的构造函数保存了客户端地址、channel、replyID 和 LogOnParams:

```cpp
// database_reply_handler.cpp:17-29
DatabaseReplyHandler::DatabaseReplyHandler(
        LoginApp & loginApp,
        const Mercury::Address & clientAddr,
        Mercury::Channel * pChannel,
        Mercury::ReplyID replyID,
        LogOnParamsPtr pParams ) :
    loginApp_( loginApp ),
    clientAddr_( clientAddr ),
    pChannel_( pChannel ),
    replyID_( replyID ),
    pParams_( pParams )
{
}
```

它有三个回调方法:
- `handleMessage()`:正常回复(成功或失败)
- `handleException()`:网络异常(如 DBApp 不可达),返回 `LOGIN_REJECTED_DBAPP_OVERLOAD`
- `handleShuttingDown()`:DBApp 正在关闭,忽略请求并 `delete this`

注意 `handleMessage()` 末尾都会 `delete this`——`DatabaseReplyHandler` 是一次性对象,处理完一条回复就自我销毁。

#### 12.3.3 message_handlers.cpp

这个文件负责把 LoginApp 的方法注册为 Mercury 消息处理器。它定义了两个模板类:

```cpp
// message_handlers.cpp:15-37(简化)
class LoginAppRawMessageHandler : public Mercury::InputMessageHandler
{
    typedef void (LoginApp::*Handler)(
        const Mercury::Address & srcAddr,
        Mercury::UnpackedMessageHeader & header,
        BinaryIStream & stream );
    // ...
    virtual void handleMessage( const Mercury::Address & srcAddr,
            Mercury::UnpackedMessageHeader & header,
            BinaryIStream & data )
    {
        (LoginApp::instance().*handler_)( srcAddr, header, data );
    }
    Handler handler_;
};
```

然后通过全局变量把 LoginApp 的成员方法绑定到具体消息:

```cpp
// message_handlers.cpp:71-77
LoginAppRawMessageHandler gLoginHandler( &LoginApp::login );
LoginAppRawMessageHandler gProbeHandler( &LoginApp::probe );
LoginAppRawMessageHandler gChallengeResponseHandler( &LoginApp::challengeResponse );
LoginAppRawMessageHandler gShutDownHandler( &LoginApp::controlledShutDown );
```

这种"成员函数指针 + 模板"的设计,让消息分发直接落到 LoginApp 单例的方法上,代码清晰。

#### 12.3.4 status_check_watcher.cpp

`StatusCheckWatcher` 是一个特殊的 watcher,它通过 DBApp Alpha 检查整个系统的健康状态。运维可以通过 watcher 系统触发它,获取一份"服务器是否正常"的报告:

```cpp
// status_check_watcher.cpp:124-127
Mercury::Bundle & bundle = app.dbAppAlpha().bundle();
bundle.startRequest( DBAppInterface::checkStatus,
       new ReplyHandler( *this, pathRequest ) );
app.dbAppAlpha().send();
```

它向 DBApp Alpha 发送 `checkStatus` 请求,DBApp 会汇总各 BaseApp/CellApp 的状态后返回。这是一种"集中式健康检查"——LoginApp 作为入口,自然承担了"探针"的角色。

#### 12.3.5 add_to_dbappmgr_helper.hpp

`AddToDBAppMgrHelper` 继承自 `AddToManagerHelper`,负责 LoginApp 启动时向 DBAppMgr 注册自己:

```cpp
// add_to_dbappmgr_helper.hpp:27-33
AddToDBAppMgrHelper( LoginApp & loginApp ) :
    AddToManagerHelper( loginApp.mainDispatcher() ),
    app_( loginApp )
{
    // Auto-send on construction.
    this->send();
}
```

构造时自动发送 `addLoginApp` 请求。这是 LoginApp **异步初始化**的触发点——`init()` 返回 true 后,真正完成初始化要等 DBAppMgr 回复并触发 `finishInit()` 回调。

---

### 12.4 LoginInt 接口

#### 12.4.1 为什么有两个接口

LoginApp 有**两套** Mercury 接口,这是它的一个特色:

| 接口名 | 类型 | 用途 | 注册位置 |
|--------|------|------|---------|
| `LoginInterface` | 外部接口 | 接收客户端的 login/probe/challengeResponse | `extInterface_` |
| `LoginIntInterface` | 内部接口 | 接收 DBAppMgr/ControlledShutdown 等内部消息 | `intInterface_` |

外部接口面向客户端,使用不可靠 UDP + RSA 加密;内部接口面向服务器进程,使用可靠 channel。这种隔离既保证了安全性(外部无法伪造内部消息),又简化了权限管理。

#### 12.4.2 LoginIntInterface 定义

`LoginIntInterface` 定义在 `login_int_interface.hpp`:

```cpp
// login_int_interface.hpp:31-47
BEGIN_MERCURY_INTERFACE( LoginIntInterface )

    BW_ANONYMOUS_CHANNEL_CLIENT_MSG( DBAppMgrInterface )

    MERCURY_EMPTY_MESSAGE( controlledShutDown, &gShutDownHandler )

    BW_BEGIN_STRUCT_MSG( LoginApp, handleDBAppMgrBirth )
        Mercury::Address addr;
    END_STRUCT_MESSAGE()

    BW_BEGIN_STRUCT_MSG( LoginApp, notifyDBAppAlpha )
        Mercury::Address addr;
    END_STRUCT_MESSAGE()

    MF_REVIVER_PING_MSG()

END_MERCURY_INTERFACE()
```

它包含 5 个消息:
- `controlledShutDown`:触发受控关停
- `handleDBAppMgrBirth`:DBAppMgr 重启通知
- `notifyDBAppAlpha`:DBApp Alpha 地址变更通知
- `reviverPing`:Reviver 心跳(由 `MF_REVIVER_PING_MSG()` 宏展开)

#### 12.4.3 Interface 名与类名不一致

注意一个有意思的细节:`LoginIntInterface` 中的 "LoginInt" 是接口名,但对应的类是 `LoginApp`。这种命名不一致在 BigWorld 中很罕见,原因是避免与外部 `LoginInterface` 重名。

这种不一致在 Reviver 的 `MF_REVIVER_HANDLER2` 宏中需要特殊处理(详见 12.8 节)。具体来说,`LoginApp` 的 ping 消息来自 `LoginIntInterface::reviverPing`(而不是 `LoginAppInterface::reviverPing`),所以 Reviver 中针对 LoginApp 的特化类必须用 `MF_REVIVER_HANDLER2` 而不是 `MF_REVIVER_HANDLER`。

#### 12.4.4 handleDBAppMgrBirth 与 notifyDBAppAlpha

这两个内部消息体现了 LoginApp 与 DBAppMgr 的协作:

`handleDBAppMgrBirth` 在 DBAppMgr 重启时被触发。LoginApp 收到后,重新向新的 DBAppMgr 发送 `recoverLoginApp` 通知自己的存在:

```cpp
// loginapp.cpp:367-381
void LoginApp::handleDBAppMgrBirth(
    const LoginIntInterface::handleDBAppMgrBirthArgs & args )
{
    MF_ASSERT( id_ != -1 );
    DEBUG_MSG( "LoginApp::handleDBAppMgrBirth: "
        "Already got an ID, just notify DBAppMgr of our existence\n" );
    Mercury::Bundle & bundle = this->dbAppMgr().bundle();
    DBAppMgrInterface::recoverLoginAppArgs & notifyArgs =
        DBAppMgrInterface::recoverLoginAppArgs::start( bundle );
    notifyArgs.id = id_;
    this->dbAppMgr().send();
}
```

`notifyDBAppAlpha` 在 DBApp Alpha 切换(主备切换)时被触发,LoginApp 更新 `dbAppAlpha_` 的地址:

```cpp
// loginapp.cpp:506-511
void LoginApp::notifyDBAppAlpha(
        const LoginIntInterface::notifyDBAppAlphaArgs & args )
{
    INFO_MSG( "LoginApp::notifyDBAppAlpha: %s\n", args.addr.c_str() );
    dbAppAlpha_.addr( args.addr );
}
```

这两个消息让 LoginApp 能在 DBAppMgr 重启或 DBApp Alpha 切换时**无缝衔接**,不需要重启自己。

---

### 12.5 认证机制

#### 12.5.1 账号密码认证

LoginApp 本身**不做**密码校验。它只是把客户端的 `LogOnParams`(含账号、密码、加密密钥等)转发给 DBApp Alpha,真正的认证由 DBApp 完成:

```
客户端 --[账号+密码(RSA加密)]--> LoginApp --[LogOnParams]--> DBApp Alpha
                                                              │
                                                              ├─ 查数据库比对密码
                                                              ├─ 加载实体
                                                              └─ 通过 BaseAppMgr 创建 Proxy
```

这种设计让 LoginApp 保持"轻量"——它不需要连接数据库,不需要知道密码哈希算法。所有敏感操作都集中在 DBApp,便于安全审计。

#### 12.5.2 计费系统集成

DBApp 在认证过程中会调用计费系统(`pBillingSystem->getEntityKeyForAccount`),这是异步的。计费系统可以:
- 拒绝登录(如账号封禁、欠费)
- 返回 entityKey 用于加载实体
- 触发 IP 封禁(返回 `LOGIN_REJECTED_IP_ADDRESS_BAN` + ban 超时)

LoginApp 收到 IP 封禁回复后,调用 `handleBanIP()` 把客户端 IP 加入 `ipAddressBanMap_`:

```cpp
// loginapp.cpp:676-687
void LoginApp::handleBanIP( const Mercury::Address & addr,
        Mercury::Channel * pChannel, Mercury::ReplyID replyID,
        LogOnParamsPtr pParams, ::time_t banDuration )
{
    uint64 banEndTimestamp = timestamp() + banDuration * stampsPerSecond();
    ipAddressBanMap_[addr.ip] = banEndTimestamp;

    this->handleFailure( addr, pChannel, replyID,
        LogOnStatus::LOGIN_REJECTED_IP_ADDRESS_BAN,
        "Logins from this IP address currently are not permitted",
        pParams );
}
```

之后该 IP 的登录请求会在步骤 3(IP 黑名单检查)被直接拒绝,无需再走 DBApp。

#### 12.5.3 登录条件配置

LoginApp 提供了多个配置项控制登录条件:

| 配置项 | 默认值 | 作用 |
|--------|--------|------|
| `loginApp/allowLogin` | false | 总闸,关闭后所有登录被拒绝 |
| `loginApp/allowUnencryptedLogins` | false | 是否允许不加密的登录(开发用) |
| `loginApp/passwordlessLoginsOnly` | false | 是否只允许无密码登录(快速登录场景) |
| `loginApp/maxUsernameLength` | 256 | 用户名最大长度 |
| `loginApp/maxPasswordLength` | 256 | 密码最大长度 |
| `loginApp/maxLoginMessageSize` | PACKET_MAX_SIZE | 登录消息最大尺寸 |

#### 12.5.4 登录挑战机制

为防止暴力破解,LoginApp 支持**登录挑战**(Login Challenge)机制。配置 `loginApp/challengeType` 后,登录流程会变成两阶段:

1. **下发挑战**:LoginApp 收到登录请求后,先生成一个挑战(如算术题、验证码),通过 `LOGIN_CHALLENGE_ISSUED` 状态发给客户端
2. **验证回应**:客户端计算挑战结果,通过 `challengeResponse` 消息回发,LoginApp 验证后才进入正常登录流程

`processForLoginChallenge()`(`loginapp.cpp:1035-1105`)处理这个逻辑:

```cpp
// loginapp.cpp:1070-1104(简化)
const BW::string challengeType = Config::challengeType();
if (challengeType.empty())
{
    return false;  // 未配置挑战,走正常流程
}

LoginChallengePtr pChallenge =
    challengeFactories_.createChallenge( challengeType );

ClientLoginRequest & loginRequest = loginRequests_[ source ];
loginRequest.pChannel( pChannel );
loginRequest.setLoginChallenge( challengeType, pChallenge );

this->sendChallengeReply( source, pChannel, replyID, challengeType,
    pChallenge );
```

挑战类型是可配置的,通过 `LoginChallengeFactories` 工厂模式管理。运行时还可以通过 watcher 修改 `challengeType` 动态切换挑战类型——`onChallengeTypeModified()` 会在切换时清空所有 pending 请求,确保状态一致。

---

### 12.6 多 LoginApp 支持

#### 12.6.1 为什么需要多个 LoginApp

单个 LoginApp 会成为瓶颈(单进程单线程),大流量下容易过载。BigWorld 支持**多个 LoginApp 实例**并行运行,通过 DNS 轮询或负载均衡器分发客户端请求。

每个 LoginApp 实例由 DBAppMgr 分配一个唯一的 `LoginAppID`:

```cpp
// loginapp.hpp:206
LoginAppID id_;
```

`finishInit()` 中保存 DBAppMgr 分配的 ID,并向 bwmachined 注册:

```cpp
// loginapp.cpp:396-400
id_ = appID;
dbAppAlpha_.addr( dbAppAlphaAddress );

Mercury::Reason reason =
    LoginIntInterface::registerWithMachined( this->intInterface(), id_ );
```

#### 12.6.2 负载均衡策略

LoginApp 的负载均衡主要靠**外部机制**:
- **DNS 轮询**:为域名配置多个 A 记录,客户端解析到不同 LoginApp
- **硬件负载均衡器**:如 F5、LVS,在 TCP 层分发连接
- **客户端探测**:客户端通过 `probe` 消息探测多个 LoginApp,选择响应最快的

`probe` 消息(`loginapp.cpp:1131-1174`)返回服务器信息(主机名、所有者、在线人数),让客户端可以选择负载最低的 LoginApp:

```cpp
// loginapp.cpp:1146-1171(简化)
char buf[256];
gethostname( buf, sizeof(buf) ); buf[sizeof(buf)-1]=0;
bundle << PROBE_KEY_HOST_NAME << buf;

bw_snprintf( buf, sizeof(buf), "%d", gNumLogins );
bundle << PROBE_KEY_USERS_COUNT << buf;
```

注意 `probe` 默认在**生产环境**关闭(`Config::isProduction()` 检查),因为它会暴露服务器信息,有安全风险。开发环境可通过 `loginApp/allowProbe` 开启。

#### 12.6.3 DBApp Alpha 单点

无论多少个 LoginApp,它们都连接到**同一个** DBApp Alpha。DBAppMgr 通过 `notifyDBAppAlpha` 消息通知所有 LoginApp 当前 Alpha 的地址。

```cpp
// loginapp.hpp:103-104
DBApp & dbAppAlpha()                        { return dbAppAlpha_; }
```

`dbAppAlpha_` 是 `Mercury::ChannelOwner` 类型,代表与 DBApp Alpha 的通道。`isDBReady()` 检查通道是否建立:

```cpp
// loginapp.hpp:112-115
bool isDBReady() const
{
    return dbAppAlpha_.channel().isEstablished();
}
```

DBApp Alpha 切换(主备切换)时,所有 LoginApp 会收到 `notifyDBAppAlpha` 并更新通道地址,实现无缝切换。

---

## 第二部分:Reviver 故障恢复

### 12.7 Reviver 概述

#### 12.7.1 它是什么

如果说 LoginApp 是"门卫",那 Reviver 就是**"看门狗"**(watchdog)。它不参与任何游戏逻辑,唯一的职责是:监控关键进程,一旦它们崩溃就自动拉起新实例。

Reviver 的源码位于 `programming/bigworld/server/reviver/`,在 `CMakeLists.txt` 中生成独立可执行文件。它链接 `server`、`network`、`cstdmf` 等库,但**不链接** `connection`、`db` 等业务库——这再次强调了它的"旁路"性质。

#### 12.7.2 监控对象

Reviver 只监控**关键的单点进程**,共 5 类:

| 进程 | 配置名 | 创建名 | 监控原因 |
|------|--------|--------|---------|
| CellAppMgr | `cellAppMgr` | `cellappmgr` | 空间管理单点 |
| BaseAppMgr | `baseAppMgr` | `baseappmgr` | Base 实体管理单点 |
| DBAppMgr | `dbAppMgr` | `dbappmgr` | 数据库管理单点 |
| DBApp | `dbApp` | `dbapp` | 数据库 Alpha 单点 |
| LoginApp | `loginApp` | `loginapp` | 登录入口(虽然可多实例,但 Reviver 仍监控) |

注意:**不监控 CellApp 和 BaseApp**。原因是它们有备份机制——CellApp 的实体有 ghost,BaseApp 的实体有备份,崩溃后由 BaseAppMgr/CellAppMgr 自动恢复。而上述 5 类进程是单点,崩溃后没有备份,只能靠 Reviver 重启。

#### 12.7.3 三重继承

Reviver 主类同样采用三重继承:

```cpp
// programming/bigworld/server/reviver/reviver.hpp  L28-29
class Reviver : public ServerApp, public TimerHandler,
    public Singleton< Reviver >
```

| 基类 | 作用 |
|------|------|
| `ServerApp` | 提供服务器应用框架(init/run/shutDown、watcher、network interface) |
| `TimerHandler` | 定时器回调,驱动 REATTACH 周期与 tick |
| `Singleton<Reviver>` | 全例,通过 `BW_SINGLETON_STORAGE(Reviver)` 实现 |

这个三重继承与 LoginApp 完全一致——这是 BigWorld 服务端进程的"标准范式":主类 + 定时器 + 单例。`ServerApp` 提供"我是服务器"的能力,`TimerHandler` 提供"我能周期性做事"的能力,`Singleton` 提供"全局唯一访问点"的能力。三者组合,就是一个完整的服务端进程骨架。

#### 12.7.4 关键成员

```cpp
// reviver.hpp:67-84
private:
    virtual bool init( int argc, char * argv[] );
    virtual bool run();

    enum TimeoutType
    {
        TIMEOUT_REATTACH,   // 重新附着周期触发
        TIMEOUT_TICK        // 主 tick 触发
    };

    TimerHandle            timerHandle_;    // REATTACH 定时器
    TimerHandle            tickTimer_;      // 主 tick 定时器

    ComponentRevivers      components_;     // 所有 ComponentReviver 列表

    bool                   shuttingDown_;   // 是否正在关闭
    bool                   isDirty_;        // 输出脏标记,用于日志节流
```

- `components_`:从全局 `g_pComponentRevivers` 拷贝而来的 ComponentReviver 列表(5 个特化类通过 `IntrusiveObject` 自动注册)
- `isDirty_`:当组件附着/脱离状态变化时置 true,REATTACH 定时器据此决定是否打印 summary,避免每个周期都刷屏

#### 12.7.5 内部类 TagsHandler

```cpp
// reviver.hpp:57-65
class TagsHandler : public MachineGuardMessage::ReplyHandler
{
public:
    TagsHandler( Reviver &reviver ) : reviver_( reviver ) {}
    virtual bool onTagsMessage( TagsMessage &tm, uint32 addr );
private:
    Reviver &reviver_;
};
```

`TagsHandler` 处理 `queryMachinedSettings()` 发出的 `TagsMessage` 异步回复。它根据 bwmachined 返回的 `Components` tag 决定本 Reviver 应该监控哪些组件——这让"机器能力"决定"监控范围",无需修改 Reviver 启动参数。

---

### 12.8 ComponentReviver 5 特化类

#### 12.8.1 ComponentReviver 基类

`ComponentReviver` 是单个被监控组件的恢复器基类,定义在 `component_reviver.hpp`:

```cpp
// programming/bigworld/server/reviver/component_reviver.hpp  L22-25
class ComponentReviver : public Mercury::ShutdownSafeReplyMessageHandler,
    public TimerHandler,
    public Mercury::InputMessageHandler,
    public IntrusiveObject< ComponentReviver >
```

这是**四重继承**,比 Reviver 主类还多一重:

| 基类 | 作用 |
|------|------|
| `ShutdownSafeReplyMessageHandler` | 处理 ping 的回复(YES/NO),且在关闭过程中安全 |
| `TimerHandler` | 定时 ping 被监控进程 |
| `InputMessageHandler` | 处理 birth/death 消息(由 bwmachined 触发) |
| `IntrusiveObject<ComponentReviver>` | 自动注册到全局链表 `g_pComponentRevivers` |

#### 12.8.2 MF_REVIVER_HANDLER 宏

5 个特化类通过 `MF_REVIVER_HANDLER` 宏声明,这是 BigWorld 中"宏驱动代码生成"的典型例子:

```cpp
// programming/bigworld/server/reviver/component_reviver.cpp  L298-323
#define MF_REVIVER_HANDLER( CONFIG, COMPONENT, CREATE_WHAT )				\
	MF_REVIVER_HANDLER2( CONFIG, COMPONENT, COMPONENT, CREATE_WHAT )

#define MF_REVIVER_HANDLER2( CONFIG, COMPONENT, COMPONENT2, CREATE_WHAT )	\
class COMPONENT##Reviver : public ComponentReviver							\
{																			\
public:																		\
	COMPONENT##Reviver() :													\
		ComponentReviver( #CONFIG, #COMPONENT, #COMPONENT2 "Interface",		\
				CREATE_WHAT )												\
	{}																		\
	virtual void initInterfaceElements()									\
	{																		\
		pBirthMessage_ = &ReviverInterface::handle##COMPONENT##Birth;		\
		pDeathMessage_ = &ReviverInterface::handle##COMPONENT##Death;		\
		pPingMessage_ = &COMPONENT2##Interface::reviverPing;				\
	}																		\
} g_reviverOf##COMPONENT;													\

MF_REVIVER_HANDLER( cellAppMgr, CellAppMgr, "cellappmgr" )
MF_REVIVER_HANDLER( baseAppMgr, BaseAppMgr, "baseappmgr" )
MF_REVIVER_HANDLER( dbAppMgr,   DBAppMgr,	"dbappmgr" )
MF_REVIVER_HANDLER( dbApp,      DBApp,		"dbapp" )
MF_REVIVER_HANDLER2( loginApp,   Login, LoginInt,   "loginapp" )
```

宏展开后,以 `MF_REVIVER_HANDLER( cellAppMgr, CellAppMgr, "cellappmgr" )` 为例,生成:

```cpp
class CellAppMgrReviver : public ComponentReviver
{
public:
    CellAppMgrReviver() :
        ComponentReviver( "cellAppMgr", "CellAppMgr", "CellAppMgrInterface",
                "cellappmgr" )
    {}
    virtual void initInterfaceElements()
    {
        pBirthMessage_ = &ReviverInterface::handleCellAppMgrBirth;
        pDeathMessage_ = &ReviverInterface::handleCellAppMgrDeath;
        pPingMessage_ = &CellAppMgrInterface::reviverPing;
    }
} g_reviverOfCellAppMgr;
```

这个宏做了三件事:
1. **定义类**:`CellAppMgrReviver` 继承 `ComponentReviver`
2. **绑定消息**:在 `initInterfaceElements()` 中把 birth/death/ping 三个 `InterfaceElement` 绑定到具体的 Mercury 消息
3. **声明全局实例**:`g_reviverOfCellAppMgr` 是全局变量,程序启动时自动构造

#### 12.8.3 5 个特化类对比

| 特化类 | CONFIG | COMPONENT | COMPONENT2 | CREATE_WHAT | interfaceName |
|--------|--------|-----------|------------|-------------|---------------|
| `CellAppMgrReviver` | `cellAppMgr` | `CellAppMgr` | `CellAppMgr` | `"cellappmgr"` | `CellAppMgrInterface` |
| `BaseAppMgrReviver` | `baseAppMgr` | `BaseAppMgr` | `BaseAppMgr` | `"baseappmgr"` | `BaseAppMgrInterface` |
| `DBAppMgrReviver` | `dbAppMgr` | `DBAppMgr` | `DBAppMgr` | `"dbappmgr"` | `DBAppMgrInterface` |
| `DBAppReviver` | `dbApp` | `DBApp` | `DBApp` | `"dbapp"` | `DBAppInterface` |
| `LoginReviver` | `loginApp` | `Login` | `LoginInt` | `"loginapp"` | `LoginIntInterface` |

#### 12.8.4 LoginApp 的特殊性

注意 `LoginReviver` 使用的是 `MF_REVIVER_HANDLER2`(而非 `MF_REVIVER_HANDLER`),且类名是 `LoginReviver`(而非 `LoginAppReviver`)。这是因为 `LoginApp` 的接口名是 `LoginIntInterface`(不是 `LoginAppInterface`),与类名不一致。

`MF_REVIVER_HANDLER2` 多了一个 `COMPONENT2` 参数,用于指定接口名的前缀。对于 LoginApp:
- `COMPONENT` = `Login`(类名前缀)
- `COMPONENT2` = `LoginInt`(接口名前缀)
- 因此 `pPingMessage_` 绑定到 `LoginIntInterface::reviverPing`

这种"宏 + 参数化"的设计,既保持了 5 个特化类的代码一致性,又处理了 LoginApp 的命名差异,是一种精妙的工程实践。

#### 12.8.5 IntrusiveObject 自注册

5 个 `g_reviverOfXxx` 都是全局变量,程序启动时(进入 `main` 之前)构造。每个构造函数通过 `IntrusiveObject<ComponentReviver>( g_pComponentRevivers )` 把自己加入全局链表:

```cpp
// component_reviver.cpp:23
ComponentRevivers * g_pComponentRevivers;
```

`Reviver::init` 中直接拷贝整个 vector:

```cpp
// reviver.cpp:81-87
if (g_pComponentRevivers == NULL)
{
    ERROR_MSG( "Reviver::init: No component revivers\n" );
    return false;
}
components_ = *g_pComponentRevivers;
```

这种"全局对象自注册 + 主类启动时收集"模式避免了在 `Reviver::init` 中显式 `new` 5 个恢复器。新增组件类型时只需新增一行 `MF_REVIVER_HANDLER` 即可,扩展性好。

---

### 12.9 双死亡检测机制

这是 Reviver 最具特色的设计之一。对每个被监控进程,Reviver 使用 **birth/death 广播 + ping 心跳** 双重检测,任一渠道判定死亡都会触发恢复。

#### 12.9.1 检测流程

```
被监控进程启动
      │
      ▼
┌──────────────────────────────────────────────────────────┐
│ bwmachined 探测到新进程,广播 birth 事件                │
│ (向所有 registerBirthListener 的进程发 birth 消息)      │
└──────────────────────────────────────────────────────────┘
      │
      ▼
┌──────────────────────────────────────────────────────────┐
│ ComponentReviver::handleMessage (birth 分支)             │
│  - addr_ = 新地址                                        │
│  - 等待 Reviver::init 或 REATTACH 调用 activate          │
└──────────────────────────────────────────────────────────┘
      │
      ▼ activate(priority)
┌──────────────────────────────────────────────────────────┐
│ 启动 ping 定时器(周期 pingPeriod_)                     │
│ pingsToMiss_ = maxPingsToMiss_                           │
└──────────────────────────────────────────────────────────┘
      │
      │  每个 ping 周期:
      ▼
┌──────────────────────────────────────────────────────────┐
│ handleTimeout:                                           │
│  if (pingsToMiss_ > 0):                                  │
│      --pingsToMiss_;                                     │
│      send ping(priority) ──────────► ReviverSubject      │
│  else:                                                   │
│      revive();  ◄── 主动 ping 超时判定死亡              │
└──────────────────────────────────────────────────────────┘

      ═══════════ 同时,被动监听 death 广播 ═══════════

被监控进程崩溃
      │
      ▼
┌──────────────────────────────────────────────────────────┐
│ bwmachined 探测到进程退出,广播 death 事件              │
└──────────────────────────────────────────────────────────┘
      │
      ▼
┌──────────────────────────────────────────────────────────┐
│ ComponentReviver::handleMessage (death 分支)             │
│  if (dead_addr == addr_):                                │
│      revive();  ◄── 被动 death 广播判定死亡             │
└──────────────────────────────────────────────────────────┘
```

#### 12.9.2 death 广播处理

`ComponentReviver::handleMessage()` 处理 birth/death 消息(`component_reviver.cpp:180-217`):

```cpp
// component_reviver.cpp:180-217(简化)
void ComponentReviver::handleMessage( const Mercury::Address & source,
    Mercury::UnpackedMessageHeader & header,
    BinaryIStream & data )
{
    Mercury::Address addr;
    data >> addr;

    if (header.identifier == pBirthMessage_->id())
    {
        addr_ = addr;  // 记录新地址
        INFO_MSG( "%s at %s has started.\n", name_.c_str(), addr.c_str() );
        return;
    }

    // death 消息
    INFO_MSG( "%s at %s has died.\n", name_.c_str(), addr.c_str() );

    if (addr == addr_)  // 死的正是当前监控的进程
    {
        this->revive();  // 触发恢复
    }
}
```

bwmachined 在进程退出时会向所有注册了 death listener 的进程广播 death 消息(消息体为死亡进程地址)。ComponentReviver 收到后,若死的地址正是当前监控的 `addr_`,立即调用 `revive()`。

#### 12.9.3 ping 心跳处理

每个 ping 周期,`handleTimeout()` 决定是否发 ping 或触发恢复:

```cpp
// component_reviver.cpp:252-267
void ComponentReviver::handleTimeout( TimerHandle /*handle*/, void * /*arg*/ )
{
    if (pingsToMiss_ > 0)
    {
        --pingsToMiss_;
        Mercury::UDPBundle bundle;
        bundle.startRequest( *pPingMessage_, this );
        bundle << priority_;  // 携带本 Reviver 优先级
        pInterface_->send( addr_, bundle );
    }
    else
    {
        INFO_MSG( "ComponentReviver::handleTimeout: Missed too many\n" );
        this->revive();
    }
}
```

ping 请求的回复由 `handleMessage(reply)` 处理:

```cpp
// component_reviver.cpp:223-246
void ComponentReviver::handleMessage( const Mercury::Address & source,
    Mercury::UnpackedMessageHeader & header,
    BinaryIStream & data,
    void * arg )
{
    uint8 returnCode;
    data >> returnCode;
    if (returnCode == REVIVER_PING_YES)
    {
        pingsToMiss_ = maxPingsToMiss_;  // 重置可丢失计数(喂狗)

        if (!isAttached_)
        {
            Reviver::pInstance()->markAsDirty();
            INFO_MSG( "ComponentReviver: %s (%s) has attached.\n",
                addr_.c_str(), name_.c_str() );
            isAttached_ = true;
        }
    }
    else
    {
        this->deactivate();  // 收到 NO,让出监控权
    }
}
```

这是经典的"看门狗喂狗"机制:每收到一次 YES,`pingsToMiss_` 重置为 `maxPingsToMiss_`;若连续 `maxPingsToMiss_+1` 次没收到 YES,判定死亡。

#### 12.9.4 两种检测的互补性

| 检测方式 | 触发条件 | 优点 | 缺点 |
|---------|---------|------|------|
| **death 广播** | bwmachined 探测到进程退出 | 响应快(进程一退出立即触发);不依赖 Reviver 与被监控进程的网络 | UDP 可能丢包;进程假死(未退出)无法检测 |
| **ping 心跳** | 连续 `maxPingsToMiss_+1` 次未收到 YES | 可靠(逐周期递减);能检测假死 | 响应慢(需等 `maxPingsToMiss_ * pingPeriod`);依赖 Reviver 与被监控进程的网络 |

两者结合,既能在进程正常崩溃时快速恢复,又能在 death 通知丢失或进程假死时兜底。

#### 12.9.5 防误判机制:wasAttached 守门

`ComponentReviver::revive()` 有一个重要的保护:

```cpp
// component_reviver.cpp:117-130
void ComponentReviver::revive()
{
    bool wasAttached = isAttached_;
    this->deactivate();
    addr_.ip = 0;
    addr_.port = 0;
    if (wasAttached)  // 只有曾经附着过才恢复
    {
        INFO_MSG( "Reviving %s\n", name_.c_str() );
        Reviver::pInstance()->revive( createParam_ );
    }
}
```

**`wasAttached` 守门**:只有曾经收到过 `REVIVER_PING_YES`(即 `isAttached_==true`)的进程,其死亡才触发恢复。这避免了:
- Reviver 启动时被监控进程尚未运行 → 不应反复重启
- 被监控进程启动中、尚未响应第一个 ping → 不应误判为死亡
- 主备 Reviver 切换时,备 Reviver 从未附着 → 不应触发恢复

---

### 12.10 ReviverSubject 优先级仲裁

#### 12.10.1 ReviverSubject 是什么

前面我们看到的都是 Reviver 端的逻辑。但被监控进程(BaseAppMgr、DBApp 等)也有配合的代码——这就是 `ReviverSubject`。

`ReviverSubject` 定义在 `lib/server/reviver_subject.hpp`,是被监控进程侧的"被恢复主体"。每个被监控进程(BaseAppMgr、CellAppMgr、DBAppMgr、DBApp、LoginApp)都持有一个 `ReviverSubject` 单例:

```cpp
// programming/bigworld/lib/server/reviver_subject.hpp  L14-37
class ReviverSubject : public Mercury::InputMessageHandler
{
public:
    ReviverSubject();
    void init( Mercury::NetworkInterface * pInterface,
                const char * componentName );
    void fini();

    static ReviverSubject & instance() { return instance_; }

private:
    virtual void handleMessage( const Mercury::Address & srcAddr,
            Mercury::UnpackedMessageHeader & header,
            BinaryIStream & data );

    Mercury::NetworkInterface *     pInterface_;
    Mercury::Address                reviverAddr_;
    uint64                          lastPingTime_;
    ReviverPriority                 priority_;
    int                             msTimeout_;

    static ReviverSubject instance_;
};
```

例如 LoginApp 在 `init()` 中初始化它:

```cpp
// loginapp.cpp:270
ReviverSubject::instance().init( &this->intInterface(), "loginApp" );
```

#### 12.10.2 仲裁逻辑

当多个 Reviver 同时 ping 同一个被监控进程时,`ReviverSubject::handleMessage()`(`reviver_subject.cpp:84-154`)仲裁哪个 Reviver 是"主":

```cpp
// reviver_subject.cpp:84-154(简化)
void ReviverSubject::handleMessage( const Mercury::Address & srcAddr,
        Mercury::UnpackedMessageHeader & header,
        BinaryIStream & data )
{
    uint64 currentPingTime = timestamp();

    ReviverPriority priority;
    data >> priority;

    bool accept = (reviverAddr_ == srcAddr);  // 当前主 Reviver 直接接受

    if (!accept)
    {
        if (priority < priority_)  // 优先级更高(数值更小)
        {
            accept = true;  // 抢占
        }
        else
        {
            uint64 delta = (currentPingTime - lastPingTime_) * uint64(1000);
            delta /= stampsPerSecond();
            int msBetweenPings = int(delta);

            if (msBetweenPings > msTimeout_)  // 当前主超时
            {
                accept = true;  // 接管
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
        bundle << REVIVER_PING_YES;  // 告诉 Reviver "你是主"
    }
    else
    {
        bundle << REVIVER_PING_NO;   // 告诉 Reviver "你不是主"
    }

    pInterface_->send( srcAddr, bundle );
}
```

仲裁规则:
1. **当前主直接接受**:如果 ping 来自 `reviverAddr_`(当前主 Reviver),直接回 YES
2. **优先级抢占**:如果 ping 来自其他 Reviver,但 priority 数值更小(优先级更高),回 YES 并切换主
3. **超时接管**:如果当前主超过 `subjectTimeout`(默认 0.2 秒)没 ping,回 YES 并切换主
4. **否则拒绝**:回 NO,告诉该 Reviver "你不是主"

#### 12.10.3 优先级的意义

`ReviverPriority` 是 `uint8` 类型,定义在 `reviver_common.hpp`:

```cpp
// programming/bigworld/lib/server/reviver_common.hpp  L12-16
typedef uint8 ReviverPriority;
const ReviverPriority REVIVER_PING_NO  = 0;
const ReviverPriority REVIVER_PING_YES = 1;
const float REVIVER_DEFAULT_SUBJECT_TIMEOUT = 0.2f;
const float REVIVER_DEFAULT_PING_PERIOD = 0.1f;
```

**值小者优先**。Reviver 在 `init()` 末尾为每个启用的 ComponentReviver 赋予递增优先级:

```cpp
// reviver.cpp:197-210
ReviverPriority priority = 0;
ComponentRevivers::iterator iter = components_.begin();
while (iter != endIter)
{
    if ((*iter)->isEnabled())
    {
        (*iter)->activate( ++priority );  // 优先级从 1 开始递增
    }
    ++iter;
}
```

这意味着**先激活的组件优先级更高**。在多 Reviver 部署时,不同 Reviver 的同一种 ComponentReviver 会竞争同一个被监控进程,优先级数值小的那个胜出。

#### 12.10.4 主备切换的触发

当主 Reviver 故障(崩溃或网络分区)时:
1. 主 Reviver 停止 ping
2. 被监控进程的 `ReviverSubject` 在 `subjectTimeout`(0.2 秒)后判定主超时
3. 下一个备 Reviver 的 ping 到达时,`ReviverSubject` 回 YES,切换主
4. 备 Reviver 收到 YES,标记 `isAttached_ = true`,接管监控权

这个过程完全自动,无需人工干预。`subjectTimeout` 必须**大于** `pingPeriod`(默认 0.1 秒),否则正常 ping 间隔会被误判为超时——这个约束在 `ComponentReviver::init()` 和 `ReviverConfig::postInit()` 中都有校验。

---

### 12.11 主备切换 shutDownOnRevive

#### 12.11.1 shutDownOnRevive 配置项

`Reviver::revive()` 末尾有一个关键判断:

```cpp
// reviver.cpp:469-473
if (Config::shutDownOnRevive())
{
    shuttingDown_ = true;
    this->shutDown();
}
```

`shutDownOnRevive` 默认为 `true`(`reviver_config.cpp:18`),意味着 Reviver 在发出一次恢复命令后**立即自我关闭**。

#### 12.11.2 为什么恢复后要关闭自己

这个设计看起来反直觉——看门狗救活别人后自己却退出了?原因在于**主备切换的语义**:

考虑两个 Reviver(主 R1、备 R2)同时监控同一个进程 P:
1. P 崩溃
2. R1(主)收到 death 通知或 ping 超时,触发 `revive()`
3. R1 发送 `CreateMessage` 给 bwmachined,让它拉起新的 P
4. **R1 自我关闭**(因为 `shutDownOnRevive=true`)
5. R2 在 `subjectTimeout` 后发现主 Reviver 不 ping 了,接管监控权
6. 新的 P 启动后,R2 ping 它,收到 YES,标记 attached
7. 运维人员重启 R1(或部署新的 Reviver),形成新的主备

这种"触发恢复者退出"的策略,确保了:
- **避免重复恢复**:R1 已经触发恢复,若继续运行可能在新 P 启动过程中再次判定死亡,重复发 CreateMessage
- **强制主备切换**:R1 退出后,R2 自然接管,形成清晰的主备轮换
- **简化状态管理**:不需要复杂的"我已恢复过,不要再恢复"标记

#### 12.11.3 关闭 false 的场景

若把 `shutDownOnRevive` 设为 `false`,Reviver 在恢复后会继续运行。这种场景适用于:
- **单 Reviver 部署**:没有备 Reviver,主退出后无人接管,必须继续运行
- **测试环境**:希望 Reviver 反复恢复进程,观察行为

但生产环境**强烈建议**保持默认 `true`,否则可能出现重复恢复、状态混乱等问题。

#### 12.11.4 shutDown() 流程

`shutDown()` 的实现:

```cpp
// reviver.cpp:419-434
void Reviver::shutDown()
{
    shuttingDown_ = true;
    mainDispatcher_.breakProcessing();  // 打破事件循环

    ComponentRevivers::iterator iter = components_.begin();
    while (iter != components_.end())
    {
        if ((*iter)->isEnabled())
        {
            (*iter)->deactivate();  // 取消每个 ComponentReviver 的定时器
        }
        ++iter;
    }
}
```

`shuttingDown_` 标记会被 `revive()` 检查,防止关闭过程中再发恢复命令:

```cpp
// reviver.cpp:442-447
if (shuttingDown_)
{
    INFO_MSG( "Reviver::revive: "
        "Trying to revive a process while shutting down.\n" );
    return;
}
```

---

### 12.12 与 bwmachined 的协作

#### 12.12.1 委托重启

Reviver 自己**不 fork 进程**。它通过 `CreateMessage` 委托本机 bwmachined 实际执行 fork+exec:

```cpp
// reviver.cpp:440-474
void Reviver::revive( const char * createComponent )
{
    if (shuttingDown_)
    {
        INFO_MSG( "Reviver::revive: "
            "Trying to revive a process while shutting down.\n" );
        return;
    }

    CreateMessage cm;
    cm.uid_ = getUserId();           // 当前用户 ID
    cm.recover_ = 1;                 // 关键:带 -recover 启动
    cm.name_ = createComponent;      // 进程名,如 "cellappmgr"
    cm.config_ = BW_COMPILE_TIME_CONFIG;  // Hybrid/Debug 等

    uint32 srcaddr = 0, destaddr = htonl( 0x7f000001U );  // 127.0.0.1
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

**核心动作**:
1. **构造 `CreateMessage`**:设置 `uid_`(让 bwmachined 以该用户身份启动)、`recover_=1`(让新进程带 `-recover` 启动参数)、`name_`(进程可执行名)、`config_`(编译配置)
2. **发送到 127.0.0.1**:`sendAndRecv` 同步发送到本机 bwmachined
3. **shutDownOnRevive 判定**:若配置为 true,自我关闭

#### 12.12.2 -recover 启动参数

`recover_=1` 让 bwmachined 启动新进程时带上 `-recover` 参数。被恢复的进程会进入"恢复模式",例如:
- CellAppMgr 会跳过新建 Space,从 DB 恢复空间状态
- BaseAppMgr 会从 DB 读取实体备份,重建 Proxy
- DBApp 会从最近一次快照恢复数据

这种"恢复模式"让新进程能继承崩溃进程的状态,而不是从零开始。

#### 12.12.3 为什么不自己 fork

Reviver 委托 bwmachined fork/exec 的原因:
1. **权限隔离**:bwmachined 通常以 root 运行,能以任意 uid 启动进程;Reviver 不需要 root 权限
2. **环境继承**:bwmachined 维护着完整的进程表和环境变量,能正确继承
3. **统一管理**:所有进程创建都经过 bwmachined,便于审计和监控
4. **避免重复**:bwmachined 知道哪些进程已在运行,避免重复创建

#### 12.12.4 birth/death listener 注册

除了恢复,Reviver 还通过 bwmachined 的 birth/death listener 机制被动接收进程生死通知:

```cpp
// component_reviver.cpp:105-108
Mercury::MachineDaemon::registerBirthListener( interface.address(),
        *pBirthMessage_, const_cast<char *>( interfaceName_.c_str() ) );
Mercury::MachineDaemon::registerDeathListener( interface.address(),
        *pDeathMessage_, const_cast<char *>( interfaceName_.c_str() ) );
```

这是双死亡检测的"被动检测"部分。bwmachined 在进程出生/死亡时,会向所有注册了对应 listener 的进程发消息。这种"两跳分发"(bwmachined 广播 → 各 bwmachined 转发 → 本机监听者)让监听者只需在本机注册一次,就能收到全集群的事件。

#### 12.12.5 queryMachinedSettings:查询机器能力

Reviver 启动时通过 `TagsMessage` 查询本机 bwmachined 的 `Components` tag:

```cpp
// reviver.cpp:273-291
bool Reviver::queryMachinedSettings()
{
    TagsMessage query;
    query.tags_.push_back( BW::string( "Components" ) );

    TagsHandler handler( *this );
    int reason;

    if ((reason = query.sendAndRecv( 0, LOCALHOST, &handler )) !=
            Mercury::REASON_SUCCESS)
    {
        NETWORK_ERROR_MSG( "Reviver::queryMachinedSettings: "
                "MGM query failed (%s)\n",
            Mercury::reasonToString( (Mercury::Reason&)reason ) );
        return false;
    }

    return true;
}
```

`TagsHandler::onTagsMessage` 根据返回的 tag 启用/禁用对应的 ComponentReviver:

```cpp
// reviver.cpp:228-265(简化)
if (tm.exists_)
{
    Tags &tags = tm.tags_;
    ComponentRevivers::iterator iter = reviver_.components_.begin();
    while (iter != reviver_.components_.end())
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
            component.isEnabled( false );
        }
        ++iter;
    }
}
```

这让"本机能力"决定"本 Reviver 监控哪些组件"。例如某台机器的 `bwmachined.conf` 中 `Components` tag 没有声明 `dbapp`,则该机器上的 Reviver 不会监控 DBApp。这使得部署可以按机器角色定制,无需修改 Reviver 启动参数。

---

### 12.13 配置项

#### 12.13.1 ReviverConfig 配置项

Reviver 的配置项定义在 `reviver_config.cpp`:

```cpp
// programming/bigworld/server/reviver/reviver_config.cpp  L15-20
BW_OPTION_RO( float, reattachPeriod, 10.f );
BW_OPTION( float, pingPeriod, REVIVER_DEFAULT_PING_PERIOD );
BW_OPTION( float, subjectTimeout, REVIVER_DEFAULT_SUBJECT_TIMEOUT );
BW_OPTION( bool, shutDownOnRevive, true );
BW_OPTION( float, timeout, 3.0 );
BW_OPTION( int, timeoutInPings, 0 );
```

| 配置项 | 类型 | 默认值 | 作用 |
|--------|------|--------|------|
| `reattachPeriod` | float | 10.0 秒 | REATTACH 周期,重新计算优先级、打印 summary |
| `pingPeriod` | float | 0.1 秒 | ping 心跳周期 |
| `subjectTimeout` | float | 0.2 秒 | 被监控进程侧的"主 Reviver 超时" |
| `shutDownOnRevive` | bool | true | 恢复后是否关闭自己 |
| `timeout` | float | 3.0 秒 | 判定死亡的总体超时 |
| `timeoutInPings` | int | 0(已废弃) | 用 ping 次数表示的超时 |

#### 12.13.2 timeoutInPings 已废弃

`timeoutInPings` 是旧版本用 ping 次数表示超时的方式,现在已废弃。`ReviverConfig::postInit()` 中:

```cpp
// reviver_config.cpp:32-49
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
```

默认 `timeoutInPings=0`,会从 `timeout` 和 `pingPeriod` 自动计算:`timeoutInPings = round(timeout / pingPeriod) = round(3.0 / 0.1) = 30`。这意味着连续 30 次 ping 没收到 YES 才判定死亡,约 3 秒。

#### 12.13.3 配置约束

`ReviverConfig::postInit()` 还校验了一个关键约束:

```cpp
// reviver_config.cpp:51-56
if (pingPeriod() > subjectTimeout())
{
    CRITICAL_MSG( "ReviverConfig::postInit: "
        "The revier/subjectTimeout must be larger than "
        "reviver/pingPeriod." );
}
```

**`subjectTimeout` 必须大于 `pingPeriod`**。否则正常 ping 间隔就会被 `ReviverSubject` 误判为主 Reviver 超时,导致主备频繁切换。

#### 12.13.4 每组件独立配置

每个 ComponentReviver 可以独立覆盖 `pingPeriod` 和 `subjectTimeout`:

```cpp
// component_reviver.cpp:73-90(简化)
BW::string prefix = "reviver/";
float pingPeriodInSeconds =
    BWConfig::get( (prefix + configName_ + "/pingPeriod").c_str(), 
        ReviverConfig::pingPeriod() );

if (pingPeriodInSeconds > 
        BWConfig::get( (prefix + configName_ + "/subjectTimeout").c_str(),
            ReviverConfig::subjectTimeout() ))
{
    CRITICAL_MSG( "ComponentReviver::init: "
        "The revier/subjectTimeout must be larger than "
        "reviver/pingPeriod." );
}
```

例如可以在 `bw.xml` 中这样配置:

```xml
<reviver>
    <pingPeriod> 0.1 </pingPeriod>
    <subjectTimeout> 0.2 </subjectTimeout>
    <timeout> 3.0 </timeout>
    <shutDownOnRevive> true </shutDownOnRevive>
    <cellAppMgr>
        <pingPeriod> 0.2 </pingPeriod>  <!-- CellAppMgr 用更长的 ping 周期 -->
        <subjectTimeout> 0.4 </subjectTimeout>
    </cellAppMgr>
</reviver>
```

#### 12.13.5 --add / --del 命令行过滤

Reviver 启动时支持 `--add` / `--del` 命令行参数过滤监控的组件:

```cpp
// reviver.cpp:104-158(简化)
for (int i = 1; i < argc - 1; ++i)
{
    const bool isAdd = (strcmp( argv[i], "--add" ) == 0);
    const bool isDel = (strcmp( argv[i], "--del" ) == 0);

    if (isAdd || isDel)
    {
        ++i;
        if (isAdd && isFirstAdd)
        {
            isFirstAdd = false;
            // 首次 --add 先把所有组件禁用
            ComponentRevivers::iterator iter = components_.begin();
            while (iter != endIter)
            {
                (*iter)->isEnabled( false );
                ++iter;
            }
        }
        // 查找匹配的组件并启用/禁用
        // ...
    }
}
```

**语义**:
- **无参数**:全部 5 个 ComponentReviver 默认启用,再由 `queryMachinedSettings()` 根据 bwmachined 的 Components tags 收紧
- **`--add X`**:首次 `--add` 先禁用全部,再启用 X。语义是"只监控 X"
- **`--del X`**:不清空,只禁用 X。语义是"除了 X 都监控"
- **混用禁止**:`--add` 与 `--del` 不能同时出现

---

### 12.14 特色实现深度剖析

#### 12.14.1 三重继承的设计哲学

Reviver(以及 LoginApp)的三重继承(`ServerApp` + `TimerHandler` + `Singleton`)是 BigWorld 服务端进程的"标准范式":

```
ServerApp          → 提供"我是服务器"的能力
  ├── EventDispatcher(事件循环)
  ├── NetworkInterface(内部网络接口)
  ├── SignalHandler(信号处理)
  ├── Watcher 系统(运维监控)
  └── Updatables(周期更新)

TimerHandler       → 提供"我能周期性做事"的能力
  └── handleTimeout(定时器回调)

Singleton<T>       → 提供"全局唯一访问点"的能力
  └── T::instance() / T::pInstance()
```

这三者正交组合,覆盖了服务端进程的三个核心需求:网络/事件、定时、全局访问。BigWorld 几乎所有服务端进程(BaseApp、CellApp、DBApp、CellAppMgr、BaseAppMgr、DBAppMgr、LoginApp、Reviver)都遵循这个范式。

#### 12.14.2 MF_REVIVER_HANDLER 宏的精妙

`MF_REVIVER_HANDLER` 宏做了三件事:

1. **定义类**:生成 `XxxReviver` 继承 `ComponentReviver`
2. **绑定消息**:在 `initInterfaceElements()` 中绑定 birth/death/ping 三个消息
3. **声明全局实例**:`g_reviverOfXxx` 自动构造并注册到 `g_pComponentRevivers`

这把"新增一个被监控组件类型"的工作量降到**一行代码**:

```cpp
MF_REVIVER_HANDLER( newComponent, NewComponent, "newcomponent" )
```

如果没有这个宏,需要手动:
1. 写一个 `NewComponentReviver` 类
2. 实现 `initInterfaceElements()`
3. 在 `ReviverInterface` 中添加 `handleNewComponentBirth`/`Death` 消息
4. 在 `NewComponentInterface` 中添加 `reviverPing` 消息
5. 在 `Reviver::init` 中手动 new 这个类

宏驱动代码生成是一种常见的工程实践,在 BigWorld 的 Mercury 接口定义(`BEGIN_MERCURY_INTERFACE`/`MERCURY_FIXED_MESSAGE`)、配置项定义(`BW_OPTION`)中也能看到。

#### 12.14.3 不监控 CellApp/BaseApp 的原因

Reviver 只监控 5 类"单点"进程,**不监控 CellApp 和 BaseApp**。原因是它们有**备份机制**:

| 进程 | 备份机制 | 崩溃后恢复方式 |
|------|---------|---------------|
| CellApp | Ghost + 实体迁移 | CellAppMgr 自动从其他 CellApp 恢复 |
| BaseApp | 实体备份 + Proxy 重连 | BaseAppMgr 自动从备份恢复 |
| CellAppMgr | 无 | Reviver 重启 |
| BaseAppMgr | 无 | Reviver 重启 |
| DBAppMgr | 无 | Reviver 重启 |
| DBApp | 快照(但 Alpha 切换由 DBAppMgr 处理) | Reviver 重启 + DBAppMgr 切换 Alpha |
| LoginApp | 无状态 | Reviver 重启(可选,因无状态) |

CellApp 和 BaseApp 的崩溃由各自的管理器(CellAppMgr/BaseAppMgr)自动处理,无需 Reviver 介入。这种"分工"避免了恢复逻辑的重复——Reviver 只管"单点",管理器管"多实例"。

#### 12.14.4 双死亡检测的容错性

双死亡检测的设计体现了** defense in depth**(纵深防御)思想:

1. **第一道防线:death 广播**——进程正常崩溃时,bwmachined 通过 `/proc` 检测到进程退出,广播 death 事件。这是最快的检测路径(毫秒级)。
2. **第二道防线:ping 心跳**——若 death 广播丢失(UDP 不可靠)或进程假死(未退出但不响应),ping 超时会兜底。这是慢但可靠的路径(秒级)。

两种机制的**触发条件互补**:
- death 广播需要进程**真正退出**(bwmachined 通过 waitpid 或 /proc 检测)
- ping 心跳需要进程**响应**(即使进程在运行,只要不响应就判定死亡)

这种设计让 Reviver 能应对:
- 进程崩溃退出(death 广播触发)
- 进程卡死不退出(ping 超时触发)
- death 通知丢包(ping 超时兜底)
- 网络分区(两者都可能触发,虽可能误判,但宁可信其有)

#### 12.14.5 REATTACH 周期与优先级重排

Reviver 有两个定时器:
- `tickTimer_`:周期 `1000000/Config::updateHertz()` 微秒,驱动 `advanceTime()`
- `timerHandle_`:周期 `reattachPeriod`(默认 10 秒),驱动 REATTACH 逻辑

REATTACH 周期(`reviver.cpp:303-385`)做两件事:

1. **重新计算优先级**:遍历所有 ComponentReviver,按当前 priority 排序,压缩成连续的 1,2,3...。这处理了某些 ComponentReviver 失活后留下的"空洞"。

2. **打印 summary**(若 `isDirty_`):输出当前附着的组件列表。`isDirty_` 在组件 attach/detach 时置 true,打印后置 false,避免每个周期都刷屏。

```cpp
// reviver.cpp:359-384(简化)
if (isDirty_)
{
    INFO_MSG( "---- Attached components summary ----\n" );
    if (!activeSet.empty())
    {
        Map::iterator mapIter = activeSet.begin();
        while (mapIter != activeSet.end())
        {
            INFO_MSG( "%d: (%s) %s\n",
                mapIter->second->priority(),
                mapIter->second->addr().c_str(),
                mapIter->second->name().c_str() );
            ++mapIter;
        }
    }
    isDirty_ = false;
}
```

---

### 12.15 本章小结

本章我们走了 BigWorld 集群的"入口"与"保障"两个进程:

**LoginApp** 是登录入口,核心要点:
1. **无状态网关**:除登录请求缓存外不持久化业务状态,可随时重启
2. **单一管理进程**:只依赖 DBAppMgr,不连接 BaseAppMgr/CellAppMgr
3. **16 步过滤登录**:从速率限制到协议校验,多层防御防 DDoS
4. **双接口设计**:`LoginInterface`(外部,客户端)+ `LoginIntInterface`(内部,服务器)
5. **RSA + Blowfish 加密分层**:RSA 加密登录参数,Blowfish 加密成功回复
6. **缓存与重发**:`loginRequests_` map 缓存最近登录,UDP 重传时直接重发
7. **DBApp Alpha 单点**:所有认证转发给 DBApp Alpha,Alpha 切换由 DBAppMgr 通知
8. **多实例支持**:可部署多个 LoginApp,通过 DNS 轮询/负载均衡分发

**Reviver** 是看门狗,核心要点:
1. **三重继承范式**:`ServerApp` + `TimerHandler` + `Singleton`,服务端进程标准骨架
2. **5 类监控对象**:CellAppMgr/BaseAppMgr/DBAppMgr/DBApp/LoginApp,不监控有备份的 CellApp/BaseApp
3. **双死亡检测**:death 广播(被动,快)+ ping 心跳(主动,可靠),互补
4. **MF_REVIVER_HANDLER 宏**:一行代码新增一个监控类型,自注册到全局链表
5. **ReviverSubject 优先级仲裁**:被监控进程侧仲裁哪个 Reviver 是主,值小者优先
6. **主备切换**:`shutDownOnRevive=true` 时,触发恢复后自我关闭,让备 Reviver 接管
7. **委托 bwmachined 重启**:发 `CreateMessage`(recover_=1)给本机 bwmachined,不自己 fork
8. **Components tags 过滤**:启动时查询 bwmachined 的 tags,按机器能力启用监控

这两个进程虽然职责不同,但都体现了 BigWorld 的设计哲学:**单一职责、委托协作、纵深防御**。LoginApp 只管登录,认证委托 DBApp;Reviver 只管检测,重启委托 bwmachined。这种分工让每个进程都保持简单,组合起来却能支撑大规模 MMOG 集群的高可用。

理解了 LoginApp 和 Reviver,你就理解了 BigWorld 集群的"入口"与"保障"——前者让玩家进得来,后者让进程活得久。下一章我们将转向客户端,看 BigWorld 的 App/Module 框架与 Moo 渲染引擎如何撑起玩家的视觉体验。

---

> **延伸阅读**:
> - `docs/BigWorld登录应用LoginApp实现分析.md` — LoginApp 的完整实现,含启动流程、加密分层、过载保护等
> - `docs/BigWorld恢复进程Reviver实现分析.md` — Reviver 的完整实现,含 birth/death 监听、主备切换等
> - `programming/bigworld/server/loginapp/loginapp.cpp` — LoginApp 主类实现
> - `programming/bigworld/server/reviver/reviver.cpp` — Reviver 主类实现
> - `programming/bigworld/server/reviver/component_reviver.cpp` — ComponentReviver 与 5 个特化类
> - `programming/bigworld/lib/server/reviver_subject.cpp` — ReviverSubject 仲裁逻辑
