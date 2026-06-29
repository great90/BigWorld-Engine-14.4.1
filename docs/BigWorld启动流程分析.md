# BigWorld Engine 各进程启动流程深度分析报告

> 本文档详细分析 BigWorld Engine 14.4.1 中各个进程的启动流程,涵盖服务端全部 8 类进程及客户端的完整启动链路。

---

## 目录

- [一、整体进程拓扑](#一整体进程拓扑)
- [二、统一启动框架(服务端)](#二统一启动框架服务端)
- [三、各进程启动流程详解](#三各进程启动流程详解)
  - [3.1 bwmachined(机器守护进程)](#31-bwmachined机器守护进程)
  - [3.2 CellApp(空间实体模拟)](#32-cellapp空间实体模拟)
  - [3.3 BaseApp(实体持久化)](#33-baseapp实体持久化)
  - [3.4 CellAppMgr / BaseAppMgr(管理器)](#34-cellappmgr--baseappmgr管理器)
  - [3.5 DBApp / DBAppMgr(数据库)](#35-dbapp--dbappmgr数据库)
  - [3.6 LoginApp(登录)](#36-loginapp登录)
  - [3.7 Reviver(进程复活器)](#37-reviver进程复活器)
  - [3.8 Client(客户端)](#38-client客户端)
- [四、跨进程协同总结](#四跨进程协同总结)
- [五、设计亮点总结](#五设计亮点总结)
- [六、关键差异对比表](#六关键差异对比表)

---

## 一、整体进程拓扑

BigWorld Engine 是一个**分布式多进程游戏服务器架构**,由 9 类核心进程协同工作:

```
bwmachined (机器守护进程, 每台机器一个)
    │
    ├─ DBAppMgr     (数据库管理器, 单例)
    │    └─ DBApp    (数据库应用, 可多个, 第一个为 Alpha)
    │
    ├─ CellAppMgr   (空间管理器, 单例)
    ├─ BaseAppMgr   (基础应用管理器, 单例)
    │    ├─ BaseApp    (基础实体应用, 可多个)
    │    └─ ServiceApp (服务应用, 实为BaseApp的isServiceApp模式)
    │
    ├─ CellApp      (空间实体模拟, 可多个)
    ├─ LoginApp     (登录应用, 可多个)
    ├─ Reviver      (进程复活器, 可多个, 单次复活后自杀)
    │
    └─ Client       (客户端, 独立启动)
```

---

## 二、统一启动框架(服务端)

### 2.1 类继承层次

所有服务端进程(除 bwmachined)都使用同一套基类骨架:

```
ServerApp  (lib/server/server_app.cpp)         网络/事件/信号/时间/Updatables
   ├─ ScriptApp                                 Python脚本支持
   │    └─ EntityApp                            CellApp/BaseApp 共用基类
   └─ ManagerApp                                CellAppMgr/BaseAppMgr 共用基类(几乎空壳)
```

具体子类(CellApp、BaseApp、ServiceApp、CellAppMgr、BaseAppMgr、DBApp、DBAppMgr、LoginApp、Reviver…)通过 `SERVER_APP_HEADER` 宏提供 `appName()` 与 `configPath()` 静态方法。

### 2.2 通用入口链路

每个进程的 `main.cpp` 极简,通过 `BIGWORLD_MAIN` 宏 + `bwMainT<T>` 模板:

```cpp
// 例如 server/cellapp/main.cpp:8-11
int BIGWORLD_MAIN( int argc, char * argv[] ) {
    return bwMainT< CellApp >( argc, argv );
}
```

`BIGWORLD_MAIN` 宏(`bwservice.hpp:143-154`)展开后顺序执行:
1. `BW_SYSTEMSTAGE_MAIN()` 设置系统阶段标识
2. `BWResource::init(argc, argv)` 初始化资源管理器(查找 respaths)
3. `BWConfig::init(argc, argv)` 加载并解析 `bw.xml` 配置链
4. `bwParseCommandLine(argc, argv)` 处理 `-machined` 之类通用命令行参数
5. 调用用户实现的 `bwMain(argc, argv)`,即 `bwMainT< CellApp >(argc, argv)`

`bwMainT<SERVER_APP>` 模板(`bwservice.hpp:97-138`)统一执行:

| 顺序 | 代码位置 | 操作 |
|---|---|---|
| 1 | `bwservice.hpp:100` | 创建 `Mercury::EventDispatcher dispatcher`(事件循环引擎) |
| 2 | `bwservice.hpp:103-108` | `MachineDaemon::queryForInternalInterface` 向 bwmachined 查询内网 IP |
| 3 | `bwservice.hpp:110-115` | 构造 `Mercury::NetworkInterface`(端口 0) |
| 4 | `bwservice.hpp:117` | 安装 `SignalProcessor`(作为 FrequentTask 挂载到 dispatcher) |
| 5 | `bwservice.hpp:119-120` | 创建日志转发器 `BW_MESSAGE_FORWARDER3` |
| 6 | `bwservice.hpp:122` | `START_MSG(appName)` 打印启动横幅 |
| 7 | `bwservice.hpp:83` | `ServerAppConfig::init(postInit)` 加载所有 BW_OPTION 配置 |
| 8 | `bwservice.hpp:90` | 栈上构造 App 实例 `SERVER_APP serverApp(dispatcher, interface)` |
| 9 | `bwservice.hpp:93` | 调用 `serverApp.runApp(argc, argv)` |

### 2.3 runApp 生命周期

`ServerApp::runApp`(`server_app.cpp:253-279`)定义统一生命周期:

```cpp
bool ServerApp::runApp( int argc, char * argv[] ) {
    stampsPerSecond();                  // 时钟校准
    if (this->init( argc, argv )) {     // 虚函数 init
        result = this->run();           // 虚函数 run, 进入主循环
    }
    this->fini();                       // 虚函数 fini
    interface_.prepareForShutdown();
    return result;
}
```

`ServerApp::run` 主循环(`server_app.cpp:240-247`)就是 `mainDispatcher_.processUntilBreak()`,由 `breakProcessing()` 退出。

### 2.4 tick 机制核心

`ServerApp::advanceTime`(`server_app.cpp:311-335`)定义每 tick 回调顺序:

```
onTickPeriod → onEndOfTick → ++time_ → onStartOfTick → callUpdatables → onTickProcessingComplete
```

- `onTickPeriod`:卡顿告警/hitch 检测
- `onEndOfTick`:tick 收尾(时间还没+1)
- `++time_`:游戏时间+1
- `onStartOfTick`:tick 开始(时间已+1)
- `callUpdatables`:按 level 调用所有 `Updatable::update()`
- `onTickProcessingComplete`:EntityApp 在此调用 `callTimers()` 处理 Python 脚本定时器

### 2.5 ServerApp::init 基类初始化

`ServerApp::init`(`server_app.cpp:197-233`)做的事:
1. 扫描 argv 中是否有 `-machined` 参数,记录 `runFromMachined` 标志
2. `createSignalHandler()` 工厂方法创建信号处理器
3. `enableSignalHandler(SIGINT)` 注册 SIGINT 信号处理
4. `raiseFileDescriptorLimit()` 提升文件描述符上限
5. 根据 `isProduction()` 设置网络接口日志详尽级别

注释明确说明:**子类 override 的 init() 必须调用 `ServerApp::init()`**。

### 2.6 信号处理两阶段设计

`SignalProcessor`(`signal_processor.cpp`)采用两阶段设计:

**阶段一:内核信号实际到达时**(`signalHandler()`)
- 只在预分配的 `Signal::Set` 中设置对应位(**无内存分配,异步信号安全**)
- SIGQUIT 特殊处理:直接调用 handler(因为 SIGQUIT 表示进程已卡死)

**阶段二:dispatcher 频繁触发时**(`dispatch()`)
- 临时阻塞所有信号
- 遍历所有信号位,逐个调用 listener 的 `handleSignal(sigNum)`
- **此处安全分配内存**

### 2.7 配置加载

`BWConfig::init`(`bwconfig.cpp:176-241`)流程:
1. 基础文件名为 `"server/bw.xml"`
2. 优先尝试用户级配置 `server/bw_<username>.xml`
3. 沿 `parentFile` 链追溯加载(子配置覆盖父配置)
4. 命令行 `+key value` 形式参数会写入最前面的配置 section

---

## 三、各进程启动流程详解

### 3.1 bwmachined(机器守护进程)

#### 入口与特殊性

**入口**:`server/tools/bwmachined/main.cpp` 使用 `BIGWORLD_MAIN_NO_RESMGR` 宏(不依赖 ResourceManager,是独立可执行进程)。

#### 启动序列

1. **命令行参数解析**(`main.cpp:31-76`):
   - `-f` / `--foreground`:前台运行,不 daemonize
   - `-p` / `--pid <path>`:设置 PID 文件路径
   - `-v` / `--version`:打印协议版本号后退出
   - `--help`:打印 usage

2. **启动顺序**(`main.cpp:78-127`):
   1. `openlog` 打开 syslog
   2. **daemonize 前构造 BWMachined 实例**(让 init.d 脚本快速看到 bind 错误)
   3. 设置 PID 路径
   4. `initProcessState(daemon)` → `daemon(0,0)` fork+setsid
   5. `srand` 随机种子
   6. 解除 RLIMIT_CORE 限制
   7. `checkSocketBufferSizes` 校验内核 socket 缓冲区
   8. `raiseFileDescriptorHardLimit(16384)` 提升文件描述符硬限制
   9. `machined.run()` 进入主循环

#### Daemonize 过程

`initProcessState`(`linux_machine_guard.cpp:58-71`):
- 调用 libc 的 `daemon(0, 0)`:fork 后父进程退出、子进程 `setsid` 成为会话 leader
- daemonize 之后立即注册 `SIGCHLD` 处理器 `sigChildHandler`,非阻塞回收僵尸进程

注意:构造函数在 daemonize 之前已经创建并绑定了 socket,daemon fork 之后子进程继承这些已 bind 的 fd。

#### UDP/TCP 端口监听

**三个 UDP Endpoint**(`bwmachined.hpp:97-103`):
- `ep_`:主端点,绑定 `broadcastAddr_:PORT_MACHINED`
- `epLocal_`:绑定 `127.0.0.1:PORT_MACHINED`
- `epBroadcast_`:绑定 `255.255.255.255:PORT_MACHINED`

全部是 `SOCK_DGRAM` (UDP),**只监听 UDP**,所有外部通信都走 UDP。

#### 广播接口自动发现

`findBroadcastInterface`(`bwmachined.cpp:237-334`):
1. 创建临时 endpoint 绑定到 `PORT_BROADCAST_DISCOVERY`
2. 枚举本机所有网卡
3. 发送 `QueryInterfaceMessage` 广播到 `255.255.255.255`
4. `select` 等待 1 秒,把收到的源 IP 与本机 interface 列表比对
5. 第一个匹配的本机接口地址即设为 `broadcastAddr_`

#### 子进程心跳 / 状态监控

bwmachined **不**主动向子进程发起心跳,而是被动接收:

**(a) 子进程主动注册**(PROCESS_MESSAGE / REGISTER,`bwmachined.cpp:1291-1358`):
- 检测重复 PID/端口
- `updateProcessStats(pi)` 通过 `/proc/<pid>/stat` 获取进程信息
- `broadcastToListeners(pm, NOTIFY_BIRTH)` 通知集群内其它 machined
- 回 ack 给注册者

**(b) 周期性轮询存活**(`BWMachined::update`,`bwmachined.cpp:1026-1049`):
- 每 1000ms 由 `UpdateHandler` 触发
- 通过读取 `/proc/<pid>/stat` 检查存活
- starttime 校验机制防止 PID 复用

**(c) 死亡通知**(`bwmachined.cpp:1073-1088`):
- 发送 `NOTIFY_DEATH` 广播给所有 birth/death listener
- 从 `procs_` 中删除

#### 集群发现与加入(Cluster)

**Birth 流程**(`cluster.cpp:272-326`):
1. 构造 `MachinedAnnounceMessage`,type=`ANNOUNCE_BIRTH`
2. 广播到 `255.255.255.255:PORT_MACHINED`,标记 `PACKET_STAGGER_REPLIES`
3. 其它 machined 收到后,把自己加入 `machines_`,回复集群大小
4. 比对 `machines_.size()` 与 `toldSize_`,相等则 bootstrap 完成

**Buddy 选举**(`cluster.cpp:29-55`):
- 环形拓扑:每台机器选 IP 地址比自身大且最小的机器作为后继
- 若没有比自身大的,则取整个集合中最小的(环绕)

**周期性 Flood 探测**(`cluster.cpp:95-119`):
- `FloodTriggerHandler` 周期触发
- 创建 `FloodReplyHandler` 发送 `WHOLE_MACHINE_MESSAGE` 广播
- 比对 `replied_` 与 `machines_`:有新机器加入、有机器消失则发 `ANNOUNCE_DEATH`/`ANNOUNCE_EXISTS`

#### 子进程 Spawn 机制

**入口:CREATE_MESSAGE**(`bwmachined.cpp:1725-1929`):
1. 获取用户信息(`users_.fetch(cm.uid_)`)
2. 获取环境(`users_.getEnv(*pUm)`)
3. 配置合法性检查(只允许 `hybrid`/`debug`,禁止 `..` 路径)
4. 查找二进制目录(`findUserBinaryDirForConfig`)
5. 调用 `startProcess()`

**`startProcess` 实现**(`linux_machine_guard.cpp:328-470`)— fork+exec 核心:

使用**状态管道**机制异步检测 exec 是否成功:
```cpp
int statusPipe[2];
pipe( statusPipe );                     // 创建管道
pid_t childpid = fork();                // fork
```

子进程分支:
1. 关闭读端
2. **关键**:把写端设为 `FD_CLOEXEC` — 如果 exec 成功,内核自动关闭管道写端;如果 exec 失败,写端仍然开着,可写入 errno
3. `setgid(gid)` 切换组
4. `setuid(uid)` 切换用户
5. 拼接可执行路径,`chdir` 到该目录
6. 关闭继承自父 machined 的端点
7. `execv(path, argv)` — 若返回 -1 说明 exec 失败,写 errno 到管道并 exit

父进程分支:
1. 关闭写端
2. 把读端与待发送的 PidMessage 存入全局 `s_pendingProcesses` map
3. 返回 false 表示"由 machine guard 负责发送 pPmwd"

**状态管道处理**(`linux_machine_guard.cpp:94-159`):
- `readlen == 0`:管道被 exec 关闭 → exec 成功
- `readlen == -1`:读错误 → exec 失败
- `readlen > 0`:子进程写入了 errno → exec 失败
- 调用 `pPmwd->sendToTarget()` 把结果 UDP 回给请求方

#### 通信协议

所有通信走 UDP,端口 `PORT_MACHINED`。包格式为 `MGMPacket`,内含若干 `MachineGuardMessage`。

如果包带 `PACKET_STAGGER_REPLIES` 标志(广播包防风暴),则延迟 0~maxPacketDelayMillisec_ 毫秒后处理。

主要消息类型:
| 消息类型 | 作用 |
|---------|------|
| `LISTENER_MESSAGE` | 注册 birth/death listener |
| `WHOLE_MACHINE_MESSAGE` | 周期机器统计查询/响应(flood) |
| `PROCESS_MESSAGE` | REGISTER/DEREGISTER/NOTIFY_BIRTH/NOTIFY_DEATH |
| `PROCESS_STATS_MESSAGE` | 查询某进程的 CPU/内存 |
| `CREATE_MESSAGE` | 启动子进程 |
| `SIGNAL_MESSAGE` | 向匹配进程发信号(kill) |
| `TAGS_MESSAGE` | 查询配置文件中的 tag |
| `USER_MESSAGE` | 查询/添加用户映射 |
| `MACHINED_ANNOUNCE_MESSAGE` | birth/death/exists 集群通告 |
| `QUERY_INTERFACE_MESSAGE` | 查询本机内部接口地址 |

#### 主循环与事件处理

`BWMachined::run()`(`bwmachined.cpp:761-879`):

```cpp
while (g_serverRunning)
{
    TimeQueue64::TimeStamp tickTime = this->timeStamp();
    callbacks_.process( tickTime );                  // 处理到期定时器

    TimeQueue64::TimeStamp ttn = callbacks_.nextExp( tickTime );
    timeStampToTV( ttn, tv );                        // 距下次定时器的时间

    FD_ZERO( &fds );
    FD_SET( ep_.fileno(), &fds );
    FD_SET( epBroadcast_.fileno(), &fds );
    FD_SET( epLocal_.fileno(), &fds );

    int osmaxfd = getInterestingFds( &fds, NULL, NULL );   // 加入待检测子进程管道

    int selgot = select( std::max( maxfd+1, osmaxfd+1 ), &fds, NULL, NULL, &tv );

    // 处理三个端点的包
    if (FD_ISSET( ep_.fileno(), &fds ))            this->readPacket( ep_, tickTime );
    if (FD_ISSET( epLocal_.fileno(), &fds ))       this->readPacket( epLocal_, tickTime );
    if (FD_ISSET( epBroadcast_.fileno(), &fds ))   this->readPacket( epBroadcast_, tickTime );

    handleInterestingFds( &fds, NULL, NULL );        // 处理子进程状态管道
}
```

设计要点:
- **单线程**事件循环
- **`TimeQueue64 callbacks_`** 统一管理所有定时任务
- **`select` 超时**设为距下一个定时器到期的时间
- **`EINTR` 处理**:select 被信号中断时不退出,仅 `continue`

#### 信号处理与用户权限

**SIGCHLD**:`sigChildHandler` 调用 `waitpid(-1, NULL, WNOHANG)` 非阻塞回收僵尸

**SIGTERM**(`bwmachined.cpp:46-54`):
```cpp
static void sigterm( int sig )
{
    if (BWMachined::pInstance())
        BWMachined::pInstance()->save();      // 保存进程表到 STATE_FILE
    g_serverRunning = false;                  // 让主循环退出
}
```

`save()` 把 `procs_` 序列化到 `/var/run/bwmachined.state`,SIGTERM 后重启能恢复进程表。

**UserMap 用户权限切换**:
- `flush()` 遍历 `getpwent()` 所有用户,读 `~/.bwmachined.conf` 配置
- 在 `startProcess` 的子进程分支中,**先 `setgid` 再 `setuid`** 降到目标用户

---

### 3.2 CellApp(空间实体模拟)

#### 类继承

```
ServerApp → ScriptApp → EntityApp → CellApp
```

#### main.cpp 入口

`server/cellapp/main.cpp:8-11`:
```cpp
int BIGWORLD_MAIN( int argc, char * argv[] )
{
    return bwMainT< CellApp >( argc, argv );
}
```

#### 构造函数

`cellapp.cpp:325-376`:
- `EntityApp` 基类子对象被构造,`bgTaskManager_` / `timeQueue_` 就位
- 注册 `EntityChannelFinder`(把 entity id 解析为实体 channel)
- `dbAppAlpha_.channel().isLocalRegular(false); isRemoteRegular(false)`:DBApp 信道在拿到 Alpha 地址前不发常规心跳

#### CellApp::init

`cellapp.cpp:489-654`,按调用顺序:

1. **基类 init**:`EntityApp::init` → `ScriptApp::init` → `ServerApp::init`(解析参数、信号、FD、watcher)。EntityApp 额外 `enableSignalHandler(SIGQUIT)`
2. **校验内部网卡**:`interface_.isGood()`
3. **配置合规性检查**:`shouldResolveMailboxes`、`demo` 模式告警
4. **计算保留 tick 时间**:`reservedTickTime_`
5. **实体静态初始化**:`Entity::s_init()`
6. **加载 resources.xml**:`AutoConfig::configureAllFrom("resources.xml")`
7. **查找 CellAppMgr**:`cellAppMgr_.init("CellAppMgrInterface", numStartupRetries, maxMgrRegisterStagger)`
8. **注册内部接口**:`CellAppInterface::registerWithInterface(interface_)`
9. **启动 CellViewerServer**:给 watcher 工具用的查询端口
10. **加载扩展插件 DLL**:`initExtensions()`
11. **初始化 IGameDelegate**
12. **启动后台线程**:`fileIOTaskManager_.startThreads("FileIO", 1)`、`bgTaskManager_.startThreads("BGTask Manager", 1)`
13. **注册 watcher**:`addWatchers()`
14. **初始化脚本系统** `initScript()`(`cellapp.cpp:3385-3529`):
    - 创建 15 个脚本事件(onAppReady / onCellAppReady / onSpaceGeometryLoaded 等)
    - `ScriptApp::initScript("cell", entitiesCellPath)` 创建 Python 解释器、`BigWorld` 模块
    - 加载 `entities.xml`
    - 向 `BigWorld` 模块注入 `entities`、`services`、`VOLATILE_ALWAYS/NEVER`、`SPACE_DATA_*` 等
    - 创建 `SharedData` 两份:`pCellAppData_`(CELL_APP)和 `pGlobalData_`(GLOBAL)
    - `initPersonality()` 加载并执行 personality 脚本的 `onInit`
15. **CellProfileGroup::init**
16. **EntityType::init / UserDataObjectType::init**:加载实体定义(.def)与 UDO 类型
17. **Terrain::Manager**
18. **注册定时器**:
    - `trimHistoryTimer_`:4 分钟周期
    - `loadingTimer_`:基于 `chunkLoadingPeriod`(默认 0.02s),**在 game tick 启动前就开始跑**
19. **CellAppChannels**:用于 cell 之间 ghost 信道
20. **向 CellAppMgr 注册**:`new AddToCellAppMgrHelper(*this, pViewerServer_->port())`,构造时即 `send()`:
    - 向 CellAppMgr 发 `add` 请求
    - CellAppMgr 回复时,helper 的 `finishInit(BinaryIStream&)` 被触发,调 `app_.finishInit(initData)`
    - 若超时未回,`handleFatalTimeout` 调 `mainDispatcher().breakProcessing()` 终止进程

#### CellApp::finishInit(CellAppMgr 回复后)

`cellapp.cpp:661-732`:

1. `BWResource::watchAccessFromCallingThread(true)`:禁止主线程直接读盘
2. 检查 `initData.id`,若 -1 表示 CellAppMgr 拒绝加入
3. 落地关键数据:`id_`、`setStartTime(initData.time)`、`baseAppAddr_`、`dbAppAlpha_.addr(initData.dbAppAlphaAddr)`、`isReadyToStart_`
4. **初始化 IDClient**:`idClient_.init(&dbAppAlpha(), DBAppInterface::getIDs, putIDs, ...)`,从 DBApp Alpha 批量获取实体 ID 段
5. `LoggerMessageForwarder::registerAppID(id_)`
6. **启动游戏时间**:若 `isReadyToStart_` 为真,调 `startGameTime()`;否则置 `isReadyToStart_=true`,等 `startup` 消息再启动
7. `CellAppInterface::registerWithMachined(interface, id_)`:把自己注册到 bwmachined 的接口表
8. **注册 birth listener**:`MachineDaemon::registerBirthListener(... "CellAppMgrInterface")`,监听 CellAppMgr 重生事件
9. **注册 watcher**:`BW_REGISTER_WATCHER(id_, "cellappNN", "cellApp", ...)`
10. **启动 PythonServer**:`startPythonServer(pythonPort, id_)`,端口默认 `PORT_PYTHON_CELLAPP + id_`

#### CellApp::startGameTime(进入"已启动"状态)

`cellapp.cpp:798-823`:
```cpp
gameTimer_ = mainDispatcher().addTimer(
    1000000/Config::updateHertz(), this,
    reinterpret_cast<void*>(TIMEOUT_GAME_TICK), "GameTick");

pTimeKeeper_ = new TimeKeeper( interface_, gameTimer_, time_,
    Config::updateHertz(), cellAppMgr_.addr(),
    &CellAppMgrInterface::gameTimeReading,
    id_, Config::maxTickStagger() );

cellAppMgr_.isRegular( true );   // 开始定期上报 load
```

`hasStarted()` 判定就是 `gameTimer_.isSet()`。

#### 接收 addCell / startup 消息

- `CellApp::addCell`(`cellapp.cpp:1513-1596`):CellAppMgr 告知"为 space X 创建一个 cell"
- `CellApp::onGetFirstCell`(`cellapp.cpp:923-927`):触发脚本事件 `onAppReady` / `onCellAppReady`,这是脚本层"启动完成"的标志
- `CellApp::startup`(`cellapp.cpp:1617-1632`):CellAppMgr 通知正式开始

#### 主循环 tick 阶段

`CellApp::handleTimeout`(`cellapp.cpp:942-974`)分发三类定时器:
- `TIMEOUT_GAME_TICK` → `handleGameTickTimeSlice()`
- `TIMEOUT_TRIM_HISTORIES` → `handleTrimHistoriesTimeSlice()`
- `TIMEOUT_LOADING_TICK` → 推进 bgTaskManager / fileIOTaskManager / preloadedSpaces / pSpaces 的 chunk tick

`handleGameTickTimeSlice`(`cellapp.cpp:1302-1340`)顺序:
1. `updateLoad()`:计算 persistent/transient/total load、throttle
2. `cellAppMgr_.informOfLoad(persistentLoad_)`:上报 load 给 CellAppMgr
3. `updateBoundary()`:把本 CellApp 的 cells 边界矩形发给 CellAppMgr
4. `advanceTime()`:`onTickPeriod` → `onEndOfTick()` → `++time_` → `callUpdatables()` → `onTickProcessingComplete()`
5. `tickBackup()`:按 `backupPeriodInTicks` 轮转备份部分实体到 BaseApp
6. `checkSendWindowOverflows()`:对溢出 channel 调实体 `onWindowOverflow` 脚本
7. `checkOffloads()`:周期性检查实体是否需要 offload 到其他 cell 或创建/销毁 ghost
8. `pSpaces_->deleteOldSpaces()`
9. `syncTime()`:周期性与 CellAppMgr 同步时钟
10. `tickStats()`:EntityMemberStats 滑动平均
11. `bufferedEntityMessages().playBufferedMessages(*this)`:回放在 finishInit 之前缓冲的实体消息
12. `bufferedInputMessages().playBufferedMessages(*this)`
13. `cells_.tickRecordings()`

---

### 3.3 BaseApp(实体持久化)

#### 类继承

```
ServerApp → ScriptApp → EntityApp → BaseApp (+ ChannelListener)
```

#### 与 CellApp 的关键差异

- **双接口架构**:`interface_`(内部 UDP)+ `extInterface_`(外部 UDP)+ `tcpServer_`(外部 TCP)
- 外部接口支持 WebSocket、限流、延迟/丢包模拟
- **客户端连接处理**:`baseAppLogin` → `LoginHandler` → `authenticate` 校验 session key
- **两级容错备份**:`backup()` 哈希到备份 BaseApp(秒级)+ `archive()` 写 DBApp/SQLite(分钟级)
- **状态机**:`waitingFor_` 位掩码跟踪就绪状态,归零后 `hasStarted()` 为真

#### 构造函数

`baseapp.cpp:135-249`,相比 CellApp 多了外部接口与 TCP 服务器:
- `extInterface_` 绑定外部端口(默认 `PORT_LOGIN`)
- `tcpServer_` 监听外部 TCP
- 根据 `shouldUseWebSockets` 决定是否创建 `ClientStreamFilterFactory`
- 端口绑定:`bindToPrescribedPort` 尝试配置端口,失败则 `bindToRandomPort`
- `new WorkerThread()`:BaseApp 专用工作线程(用于 DB 写等)
- `new BackupSender / new Archiver`

#### BaseApp::init

`baseapp.cpp:352-521`,顺序:

1. `EntityApp::init`
2. 校验三个接口:`intInterface().isGood()`、`extInterface_.isGood()`、`tcpServer_.isGood()`
3. `tcpServer_.pStreamFilterFactory(...)`
4. **PingManager::init**:初始化客户端 ping 管理器
5. 校验 `bytesPerPacketToClient` 在合法区间
6. **findOtherProcesses**:同时查找 BaseAppMgr 与 CellAppMgr
   - `baseAppMgr_.init("BaseAppMgrInterface", ...)`
   - `MachineDaemon::findInterface("CellAppMgrInterface", 0, cellAppMgr_, ...)`:BaseApp 只需要 CellAppMgr 地址(用于 TimeKeeper)
7. **serveInterfaces**:
   - `BaseAppIntInterface::registerWithInterface(intInterface())`
   - `BaseAppExtInterface::registerWithInterface(extInterface_)`:外部接口注册客户端消息处理器
8. **加载扩展插件**
9. **IGameDelegate 初始化**
10. `bgTaskManager_.initWatchers(getAppName())` + `startThreads`
11. **initScript**(`baseapp.cpp:1232-1340`):
    - 创建脚本事件 `onAppReady`/`onAppShutDown`/`onBaseAppData`/`onBaseAppDeath`/`onCellAppDeath`/`onServiceAppDeath`/`onDelBaseAppData`/`onDelGlobalData`/`onGlobalData`/`onAppShuttingDown` 等
    - `ScriptApp::initScript("base"/"service", entitiesBasePath[, entitiesServicePath])`
    - 注入 `BigWorld.isServiceApp`
    - `new Pickler`、`new GlobalBases`(挂到 `BigWorld.globalBases`)、`new PyServicesMap`(挂到 `BigWorld.services`)
    - `SharedDataManager::create(pPickler_)`:统一管理 baseAppData / globalData / cellAppData 共享数据
12. `addWatchers()`
13. `bwtracer_.init(extInterface_)`
14. 配置外部接口延迟/丢包模拟
15. 设置 sendWindow 溢出回调
16. `UserDataObject::createRefType()`:创建 UDO_REF 类型
17. 若 `isServiceApp_`:`new ServiceStarter` + `init`
18. **向 BaseAppMgr 注册**:`new AddToBaseAppMgrHelper(*this)`

#### BaseApp::finishInit

`baseapp.cpp:702-805`:

1. `BWResource::watchAccessFromCallingThread(true)`
2. `id_ = initData.id`
3. `LoggerMessageForwarder::registerAppID(id_)`
4. **updateDBAppHash(stream)**:从流中更新 DBApp 哈希表,若 Alpha 变化则切换 `dbAppAlpha_.addr()`。这是**与 DBApp 集群的首次交互点**
5. **initSecondaryDB**:若 `DBConfig::secondaryDB.enable()` 且 Archiver 启用,通过 `SecondaryDBIniter` 阻塞请求 DBApp 获取 SQLite 文件名与目录,创建 `SqliteDatabase`
6. **创建 EntityCreator**:`EntityCreator::create(dbApp(), intInterface())`,内部含 IDClient,负责实体 ID 分配与 createBase 流程
7. **注册到 machined**:ServiceApp 注册为 `"ServiceAppInterface"`,否则 `BaseAppIntInterface::registerWithMachined(intInterface, id_)`
8. `baseAppMgr_.finishedInit()`
9. `timeoutPeriod_ = initData.timeoutPeriod`
10. ServiceStarter::finishInit
11. `setStartTime(initData.time)`
12. **若 BaseAppMgr 已 ready**:`startGameTickTimer()`
13. `startServiceFragments()`
14. **注册 birth listener**:同时监听 `BaseAppMgrInterface` 与 `CellAppMgrInterface` 重生
15. **注册 watcher**:`BW_REGISTER_WATCHER(id_, "baseappNN"/"serviceappNN", "baseApp", ...)`
16. `startPythonServer(pythonPort, id_)`
17. **若 BaseAppMgr 已 ready**:`ready(READY_BASE_APP_MGR)` + `registerSecondaryDB()`

#### BaseApp::startup 与 ready

- `startup(args)`(`baseapp.cpp:1988-2010`):BaseAppMgr 在系统就绪时下发,带 `bootstrap` 与 `didAutoLoadEntitiesFromDB` 标志。流程:`ready(READY_BASE_APP_MGR)` → 打印起始时间 → `registerSecondaryDB()`
- `ready(component)`(`baseapp.cpp:2037-2063`):当 `component == waitingFor_` 时(即等待的最后一个组件就绪),启动 game timer、创建 `TimeKeeper`(master 是 `cellAppMgr_` 地址),并触发 `onAppReady`/`onBaseAppReady`/`onServiceAppReady` 脚本事件

**auto-load 机制**:DBApp 从数据库 `_BigWorldInfo/AutoLoad` 段读出需要自动加载的实体,会通过 `createBaseFromDB` 消息把这些实体恢复为 base。`didAutoLoadEntitiesFromDB_` 标志会传给 `onAppReady` 脚本。

#### 主循环 tick 阶段

`BaseApp::tickGameTime`(`baseapp.cpp:1504-1623`)顺序:

1. `checkTickNotLate()`:测算上一 tick 实际耗时,>200% 告警
2. `tickProfilers`:每个 base 的 profiler tick + EntityType profiler tick
3. 超时检查:`lastTickPeriod > timeoutPeriod_` 且非交互调试模式 → CRITICAL_MSG 终止
4. `advanceTime()`:触发 `onStartOfTick`(调 `IGameDelegate::update()`)→ `onEndOfTick` → `++time_` → Updatables → `onTickProcessingComplete`(基类 `EntityApp::onTickProcessingComplete` 调 `callTimers`)
5. 时间戳合法性检查
6. **load 计算**:`load_ = (1-bias)*load_ + bias*clamp(0, 1-spareFraction, 1)`
7. `pLoginHandler_->tick()`:处理登录队列超时
8. **backup()**:`pBackupSender_->tick(bases_, intInterface())`,把一部分 base 实体备份到哈希到的备份 BaseApp(第一级容错)
9. **archive()**:`pArchiver_->tick(dbApp(), baseAppMgr(), bases_, pSqliteDB_)`,把一部分 base 归档到 DBApp/SQLite(第二级容错)
10. 周期性 `pTimeKeeper_->synchroniseWithMaster()`,master 是 CellAppMgr
11. **上报 load 给 BaseAppMgr**:`BaseAppMgrInterface::informOfLoad(load, numBases, numProxies)`
12. `TickedWorkerJob::tickJobs()`
13. `tickRateLimitFilters()`:每个 proxy 的限流过滤器 tick
14. `checkSendWindowOverflows()`
15. `sendIdleProxyChannels()`:对空闲的 proxy channel 调 `sendIfIdle()`,保证 ACK 等能发出
16. **retirement 检查**:若正在 retire 且 bases/services/offloadedBackups 都空且不备份他人,或超过 60s 等待,则 `shutDown()`
17. `tickStats()`
18. `pDeadCellApps_->tick(bases_, intInterface())`:处理已死 CellApp 的实体恢复

#### 客户端连接处理(baseapp 特有)

- `BaseApp::baseAppLogin`:客户端首包,转发 `pLoginHandler_->login(...)`
- `BaseApp::authenticate`:客户端后续包,通过 channel 地址找 proxy,校验 session key,成功后 `setBaseForCall(&proxy, isExternalCall=true)`
- `BaseApp::acceptClient`:处理 acceptClient 请求(来自 LoginApp/DBApp 链路),把客户端接入指定 proxy
- `BaseApp::logOnAttempt`:DBApp 通知玩家重登录,调用 proxy 脚本 `onLogOnAttempt`
- `BaseApp::onChannelSend`:监控外部 UDP channel sendWindow,超 `clientOverflowLimit` 则 1s 后回调 `onClientDeath(CLIENT_DISCONNECT_TIMEOUT)`
- `BaseApp::onChannelGone`:channel 消失时让对应 proxy 死亡

---

### 3.4 CellAppMgr / BaseAppMgr(管理器)

#### 类继承

```
ServerApp → ManagerApp(几乎空壳)→ CellAppMgr / BaseAppMgr
```

`ManagerApp`(`manager_app.cpp`)仅 27 行,只是 `ServerApp::addWatchers` 的转发。`MANAGER_APP_HEADER` 等价于 `SERVER_APP_HEADER`。

#### CellAppMgr(空间/Cell 管理器)

##### 构造

`cellappmgr.cpp:79-111`,持有:
- `cellApps_`(`CellApps`,以 updateHertz 构造)
- `baseAppMgr_`、`dbAppMgr_`、`dbAppAlpha_`(均为 `Mercury::ChannelOwner`),设为非 regular
- 状态字段 `waitingFor_ = READY_ALL`(即 `READY_CELL_APP|READY_BASE_APP_MGR|READY_BASE_APP`)、`hasStarted_=false`、`isRecovering_=false`

##### init 流程

`cellappmgr.cpp:155-285`,按顺序:

1. **`ManagerApp::init`**:进入 `ServerApp::init`,完成信号/FD/verbosity 设置
2. **接口校验**:`interface_.isGood()`
3. **命令行解析**:`-recover` 进入恢复模式;`-machined` 表示由 bwmachined 拉起
4. **`ReviverSubject::instance().init(&interface_, "cellAppMgr")`**:把自己注册为 reviver 的监控对象
5. **创建负载均衡定时器**:
   - `loadBalanceTimer_`,参数 `Config::loadBalancePeriod()`(默认 1s)
   - `metaLoadBalanceTimer_`(仅当 `metaLoadBalancePeriod>0`,默认 3s)
   - `overloadCheckTimer_`,固定 1s
6. **启动 viewer server**:`CellAppMgrViewerServer`
7. **注册 watcher**:`BW_REGISTER_WATCHER` + `addWatchers()`(注册 `spaces`、`cellApps`、各种 `loadBalancing/*`、`cellAppLoad/*` 等)
8. **向 machined 注册 birth/death 监听**:
   - 监听 `BaseAppMgrInterface` birth(`handleBaseAppMgrBirth`)
   - 监听 `DBAppMgrInterface` birth(`handleDBAppMgrBirth`)
   - 监听 `CellAppMgrInterface` birth(`handleCellAppMgrBirth`,用于检测新 CellAppMgr 出现,若发现不是自己则 shutdown)
   - 监听 `CellAppInterface` death(`handleCellAppDeath`)
   - 调用 `MachineDaemon::findInterface("DBAppMgrInterface", ...)` 找到 DBAppMgr
9. **`CellAppMgrInterface::registerWithInterface` + `registerWithMachined`**:向 machined 注册自己的接口
10. **查找 BaseAppMgr**:`findInterface("BaseAppMgrInterface", ...)`,成功则 `baseAppMgr_.addr(...)` 并 `ready(READY_BASE_APP_MGR)`
11. **`-recover` 时启动恢复**:`startRecovery()` 设置 2 秒一次的 `recoveryTimer_`,2 秒后触发 `endRecovery()`

注意:**此时还没有 gameTimer**。`gameTimer_` 在 `startTimer()` 中创建,而 `startTimer()` 在 `startup()` 或 `ready(READY_ALL)` 时才调用。

##### ready 与 startup

- `ready(component)`(`cellappmgr.cpp:1730-1749`):用位掩码 `waitingFor_` 跟踪是否已就绪。当 `component == waitingFor_`(即最后一个就绪的组件到来)时,若不在 recovery 则记录日志,在 recovery 则调用 `startTimer()`
- `startup(...)`(`cellappmgr.cpp:1755-1768`):由 DBApp 经 BaseAppMgr 转发的 `startup` 消息触发。调用 `startTimer()`、强制创建默认 space(`findSpace(1)`)、`cellApps_.startAll(baseAppAddr_)` 通知所有 cellapp 启动
- `startTimer()`(`cellappmgr.cpp:1774-1784`):创建 `gameTimer_`(频率 `1000000/Config::updateHertz()`)和 `TimeKeeper`。`hasStarted_=true`

##### 主循环 handleTimeout

`cellappmgr.cpp:2297-2418`,`arg` 转换为枚举后分支:

- **`TIMEOUT_LOAD_BALANCE`**:非 recovering 且已 started 时调用 `loadBalance()`——遍历所有 space 调 `space->loadBalance()`,然后 `cellApps_.sendToAll()` 聚合发送
- **`TIMEOUT_META_LOAD_BALANCE`**:若 `shouldMetaLoadBalance_` 且已 started,调用 `metaLoadBalance()`——通过 `CellAppGroups` 识别可均衡分组,`checkForOverloaded` 合并、`checkLoadingSpaces` 为加载中 space 增加 cell、`checkForUnderloaded` 退役负载低的 cell
- **`TIMEOUT_OVERLOAD_CHECK`**:`overloadCheck()`——计算 avg/max 负载超限时长,把状态上报给 DBApp Alpha
- **`TIMEOUT_GAME_TICK`**:
  - `advanceTime()` → `ServerApp::advanceTime` 增加 `time_`,触发 `onEndOfTick/onStartOfTick/callUpdatables`
  - 按 `archivePeriodInTicks` 周期写 space 与 gameTime 到 DB
  - `cellApps_.updateCellAppTimeout()`
  - `checkForDeadCellApps()`
  - 推进所有 `CellAppDeathHandler::tick()`
  - 清理 `spacesShuttingDown_` 中的 space
  - 处理 `pendingApps_`:为每个还没有 cell 的 space 在新加入的 cellapp 上 addCell
  - `cellApps_.sendCellAppMgrInfo(maxCellAppLoad())`
- **`TIMEOUT_END_OF_RECOVERY`**:`endRecovery()`

##### CellApp 管理

- **`addApp`**(`cellappmgr.cpp:1245-1384`):CellApp 启动后向 CellAppMgr 注册。前置条件:必须已有 BaseApp(`baseAppAddr_ != NONE`)和 DBApp Alpha,且不能在 recovering/更新中。分配 `++lastCellAppID_`、构造 `CellAppInitData`(含 id/time/baseAppAddr/dbAppAlphaAddr/isReady/timeoutPeriod)、`cellApps_.add(...)`、加入 `pendingApps_`,回写 init data + 共享数据 + servicesMap
- **`recoverCellApp`**(`cellappmgr.cpp:1390-1540`):恢复模式下 CellApp 上报自身状态:地址、id、time、共享数据、所有 space 的描述
- **`handleCellAppDeath`**(`cellappmgr.cpp:1806-1906`):意外死亡处理:
  - 经 machined `sendSignalViaMachined(addr, SIGQUIT)` 确保进程真的退出
  - 通知其它 CellApp 上的 `CellAppDeathHandler::clearWaiting`
  - 新建 `CellAppDeathHandler` 等待所有 CellApp ack(超时 `2*cellAppTimeout`)
  - `pDeadApp->handleUnexpectedDeath(...)` 写出该 app 上实体信息
  - 若 `cellApps_.empty() && shutDownServerOnBadState()` 或 `shutDownServerOnCellAppDeath()`,触发 `triggerControlledShutDown()`
- **`checkForDeadCellApps`**(`cellappmgr.cpp:2425-2438`):每 tick 调用 `cellApps_.checkForDeadCellApps(cellAppTimeoutInStamps)`,发现超时则 `handleCellAppDeath`

##### Space 分配与负载均衡

- **`findSpace`**(`cellappmgr.cpp:1168-1203`):若 spaces 为空且请求 id=1 且非 recovering,按 `Config::useDefaultSpace()` 创建默认 space
- **`generateSpaceID`**(`cellappmgr.cpp:2230-2244`):递增分配或校验外部 ID
- **`createEntityInNewSpace`** / **`createEntity`** → `createEntityCommon`:按位置 `pSpace->findCell(pos.x, pos.z)` 找到目标 cell,把创建请求转发给该 cell 的 CellApp
- **`checkLoadingSpaces`**(`cellappmgr.cpp:849-888`):为正在加载几何的 space 增加更多 loading cell(上限 `Config::maxLoadingCells()`,下限面积 `Config::minLoadingArea()`)
- **`metaLoadBalance`**(`cellappmgr.cpp:768-789`):基于 `CellAppGroups`(见 `cell_app_groups.hpp`)做跨分组均衡,`mergeThreshold = avgLoad + metaLoadBalanceTolerance`

##### 配置项

`cellappmgr_config.cpp`,`BW_CONFIG_PREFIX "cellAppMgr/"`:
- `maxLoadingCells=4`、`minLoadingArea=1000000.f`
- `cellAppTimeout=3.f`,派生 `cellAppTimeoutInStamps`
- `archivePeriod=0.f`、`shouldArchiveSpaceData=true`
- `loadBalancePeriod=1.f`、`metaLoadBalancePeriod=3.f`、`metaLoadBalanceTolerance=0.05f`
- `metaLoadBalanceScheme=SCHEME_HYBRID`
- `postInit`:校验 `cellAppTimeout <= channelTimeoutPeriod`、转换 `archivePeriodInTicks`、校验 `metaLoadBalanceScheme` ∈ {SMALLEST, LARGEST, HYBRID}

#### BaseAppMgr(Base/Proxy 管理器)

##### 构造

`baseappmgr.cpp:255-290`,重点字段:
- `cellAppMgr_`、`dbAppAlpha_`、`dbApps_`(`DBAppsGateway`)
- `baseAndServiceApps_`(`BaseApps`,**所有 BaseApp+ServiceApp 的统一容器**)
- `baseApps_`(`BaseAppSubSet`)与 `serviceApps_`(`ServiceAppSubSet`):**两个子集共享同一个 `baseAndServiceApps_` 容器**(构造时 `const_cast` 传入),分别用 `iterator()` 中的谓词(`!isServiceApp` / `isServiceApp`)过滤
- `pBackupHashChain_`:新式备份哈希链
- `globalBases_`:全局 base 邮箱注册表
- `sharedBaseAppData_` / `sharedGlobalData_`

##### init 流程

`baseappmgr.cpp:352-437`:

1. **`ManagerApp::init`**
2. **`ReviverSubject::init(&interface_, "baseAppMgr")`**
3. **`-recover` 解析**
4. **向 machined 注册 death listener**:监听 `BaseAppIntInterface` 与 `ServiceAppInterface` 的死亡(即 BaseApp/ServiceApp 崩溃)
5. **`BaseAppMgrInterface::registerWithInterface` + `registerWithMachined`**
6. **查找 CellAppMgr**:`registerBirthListener("CellAppMgrInterface")` + `findInterface`,成功则 `cellAppMgr_.addr(...)`,失败但 `REASON_TIMER_EXPIRED` 仅警告。再注册 `BaseAppMgrInterface` birth listener,用于检测重复启动(若发现新的 BaseAppMgr 不是自己,就 `shutDown(false)`)
7. **注册 watcher**

注意:BaseAppMgr 的 init 不创建 gameTimer。`startTimer()`(`baseappmgr.cpp:2460-2473`)在 `startup()` 或 `recoverBaseApp()` 中调用,创建 `gameTimer_` 与 `TimeKeeper`(以 `cellAppMgr_.addr()` 为时间 master)。

##### startup 与启动顺序

`baseappmgr.cpp:2378-2426`,由 DBApp 触发(经 `BaseAppMgr::startup` 消息):

1. 读取 `didAutoLoadEntitiesFromDB`
2. `startTimer()`
3. **通知 CellAppMgr 启动**:向 `cellAppMgr_` 发 `CellAppMgrInterface::startup` 消息。**这是 CellAppMgr 进入运行状态的触发点**
4. **通知所有 BaseApp 启动**:遍历 `baseAndServiceApps_` 与 `pendingApps_`,调用 `startupBaseApp()`,**第一个非 ServiceApp 收到 `args.bootstrap=true`**——这是"引导 BaseApp",负责加载持久化实体等

##### 主循环 handleTimeout

`baseappmgr.cpp:801-830`,只有一个超时类型 `TIMEOUT_GAME_TICK`:

- `advanceTime()`
- 每 `timeSyncPeriodInTicks` 调 `pTimeKeeper_->synchroniseWithMaster()`,与 CellAppMgr 对时
- `checkForDeadBaseApps()`
- 每 `updateCreateBaseInfoPeriodInTicks` 调 `baseApps_.updateCreateBaseInfo()`(默认 5s)
- 每 tick 调 `baseApps_.updateBestBaseApp()`

##### BaseApp 管理(ManagedAppSubSet 模式)

`baseappmgr.hpp:61-133` 定义了抽象基类 `ManagedAppSubSet`,承载 BaseApp 与 ServiceApp 共用逻辑:

- **`add` 消息处理**(`baseappmgr.cpp:992-1043`):BaseApp 启动后向 BaseAppMgr 注册。前置:`cellAppMgr_` 已建立、`hasInitData_`(DBApp 已下发初始化数据)、`dbApps_` 非空,否则返回空 reply 让 BaseApp 重试。分配 `getNextAppID()`(`lastAppID_ = (lastAppID_+1) & 0x0FFFFFFF`),new `BaseApp`,加入 `pendingApps_`,回写 `BaseAppInitData` + `dbApps_`(DBApp 哈希)
- **`finishedInit`**(`baseappmgr.cpp:1351-1385`):BaseApp 完成自身初始化后调用。从 `pendingApps_` 移到对应子集(`baseApps_.addApp` 或 `serviceApps_.addApp`),调 `synchronize()` 同步 globalBases/共享数据/已有 BaseApp 通告,`adjustBackupLocations(..., ADJUST_BACKUP_LOCATIONS_OP_ADD)` 重新计算备份拓扑
- **`synchronize`**(`baseappmgr.cpp:1393-1438`):把 `globalBases_`、`sharedBaseAppData_`、`sharedGlobalData_` 流式发给新 BaseApp;并相互通告已存在 BaseApp 与新 BaseApp(`BaseAppIntInterface::handleBaseAppBirth`)
- **`onBaseAppDeath`**(`baseappmgr.cpp:1603-1671`):`killApp` 经 machined 发 SIGQUIT;检查 `shutDownOnAppDeath()`、备份是否就绪、剩余 App 数是否低于 `minimumRequiredApps()`(BaseApp 子集要求 1,ServiceApp 取决于 `isBadStateWithNoServiceApps`);决定是否触发 `controlledShutDownServer()`;否则 `adjustBackupLocations(OP_CRASH)` + `updateCreateBaseInfo` + `stopBackupsTo`
- **`checkForDeadBaseApps`**(`baseappmgr.cpp:837-891`):每个 tick 检查 `pApp->hasTimedOut(currTime, baseAppTimeoutInStamps)`;若 `shutDownServerOnBadState` 且剩余数仍大于 `minimumRequiredApps`,才真正清理

##### 客户端登录分配

`baseappmgr.cpp:923-985`,DBApp 处理登录时调用 BaseAppMgr 的 `createEntity`:

1. `baseApps_.findLeastLoadedApp()`(跳过 `isRetiring()` 的 App)
2. 无人则返回 `CREATE_ENTITY_ERROR_NO_BASEAPPS`
3. `calculateOverloaded(areBaseAppsOverloaded)`:超载时长超阈值或 `loginsSinceOverload_` 超 `overloadLogins`,返回 `CREATE_ENTITY_ERROR_BASEAPPS_OVERLOADED`
4. 通过后,`pBest->bundle().startRequest(BaseAppIntInterface::createBaseWithCellData, new CreateBaseReplyHandler(...))`,把客户端数据转发给选中的 BaseApp
5. `pBest->addEntity()` 更新本地负载估计

##### 备份哈希链

- `adjustBackupLocations`:每次 BaseApp 增减时,让所有其它 BaseApp 重新计算其 backup hash。当前策略是"每个 BaseApp 备份到所有其它 BaseApp"
- `useNewBackupHash`:BaseApp 完成切换到新哈希后通知 BaseAppMgr
- `redirectGlobalBases`:死亡 BaseApp 上的全局 base 邮箱通过 `baseApp.backupHash().addressFor(mailbox.id)` 重定向到对应备份

##### 配置项

`baseappmgr_config.cpp`,`BW_CONFIG_PREFIX "baseAppMgr/"`:
- `maxDestinationsInCreateBaseInfo=250`
- `updateCreateBaseInfoPeriod=5.f`
- `baseAppTimeout=5.f`
- `postInit`:校验 `baseAppTimeout <= channelTimeoutPeriod`,转换 ticks

---

### 3.5 DBApp / DBAppMgr(数据库)

#### DBApp

##### 类继承

```
ServerApp → ScriptApp → DBApp (+ TimerHandler + IDatabase::IGetBaseAppMgrInitDataHandler + IDatabase::IUpdateSecondaryDBshandler + Singleton<DBApp>)
```

##### 构造函数

`dbapp.cpp:129-158`:
- `ScriptApp(mainDispatcher, interface)`
- `dbAppMgr_(interface_)`、`baseAppMgr_(interface_)`
- `mainDispatcher_.maxWait(0.02)`:事件循环最长阻塞 20ms
- `baseAppMgr_.channel().isLocalRegular(false)/isRemoteRegular(false)`

##### init 主流程(两段式)

`dbapp.cpp:191-208`,`init` 只做"前半段"(同步部分):
```cpp
return this->initNetwork() &&            // 1
       this->initBaseAppMgr() &&          // 2
       this->initScript(argc, argv) &&    // 3
       this->initEntityDefs() &&          // 4
       this->initExtensions() &&          // 5
       this->initDatabaseCreation() &&    // 6
       this->initDBAppMgrAsync();         // 7 (异步,回调中继续后半段)
```

注释明确写到:"DBAppMgr registration is asynchronous. We will complete initialisation in onDBAppMgrRegistrationCompleted."

##### 各 init 步骤详解

**1. `initNetwork`**(`dbapp.cpp:216-236`):
- 校验 `interface_.isGood()`
- `DBAppInterface::registerWithInterface(interface_)`:在内部接口上注册 DBAppInterface 的所有消息处理器
- 置 `INIT_STATE_NETWORK` 位

**2. `initBaseAppMgr`**(`dbapp.cpp:245-284`):
- `status_.set(STARTING, "Looking for BaseAppMgr")`
- `Mercury::MachineDaemon::registerBirthListener(..., DBAppInterface::handleBaseAppMgrBirth, "BaseAppMgrInterface")`:订阅 BaseAppMgr 诞生
- `Mercury::MachineDaemon::findInterface("BaseAppMgrInterface", 0, baseAppMgrAddr)`:**不重试**,找不到也 OK(后续靠 birth listener)

**3. `initScript`**(`dbapp.cpp:295-341`):
- 调用 `ScriptApp::init`(基类,启动 Python)
- `ScriptApp::initScript("database", EntityDef::Constants::databasePath())`:加载 `scripts/db/database.py` 等
- 创建脚本事件 `onAppReady`、`onDBAppReady`
- `initPersonality` + `triggerOnInit`:触发 `BWPersonality.onInit`

**4. `initEntityDefs`**(`dbapp.cpp:349-372`):
- `new EntityDefs()`,`pEntityDefs_->init(BWResource::openSection(EntityDef::Constants::entitiesFile()))`:加载 `entities.xml` 实体定义
- 打印预期 digest

**5. `initExtensions`**(`dbapp.cpp:380-396`):
- `PluginLibrary::loadAllFromDirRelativeToApp(true, "-extensions")`:从可执行文件同目录加载 `*-extensions` 共享库插件
- 置 `INIT_STATE_EXTENSIONS` 位

**6. `initDatabaseCreation`**(`dbapp.cpp:404-442`)— **数据库引擎创建核心**:
- `DBConfig::get().isGood()` 校验 `<db>` 配置
- 读 `DBConfig::get().type()`(配置中 `<db type="mysql"/>` 或 `"xml"`)
- 构造 `DatabaseEngineData(interface, mainDispatcher, DBAppConfig::isProduction())`
- `pDatabase_ = DatabaseEngineCreator::createInstance(databaseType, dbEngineData)`:工厂模式创建

**工厂模式实现**(`lib/db_storage/db_engine_creator.hpp:51-81`):
- `DatabaseEngineCreator` 继承 `IntrusiveObject<DatabaseEngineCreator>`,构造时用 `typeName` 注册到全局链表
- `createInstance(type, data)` 在链表里按 `typeName` 查找,调用对应 `createImpl` 纯虚方法

**MySQL 引擎**(`mysql_engine_creator.cpp:13-41`):
- `MySqlEngineCreator` 构造时注册 `"mysql"` 类型
- `createImpl` 调用 `createMySqlDatabase(interface, dispatcher)`
- 文件末尾匿名命名空间 `MySqlEngineCreator staticInitialiser;` 是链接期注册的关键

**XML 引擎**(`xml_engine_creator.cpp:13-52`):
- `XMLEngineCreator` 注册 `"xml"` 类型
- `createImpl` 直接 `new XMLDatabase()`
- 若 `DBAppConfig::isProduction()` 为 true,打印警告:"XML 数据库仅用于演示和评估"
- 同样有 `XMLEngineCreator staticInitialiser;` 链接期注册

**7. `initDBAppMgrAsync`**(`dbapp.cpp:454-478`)— 异步注册 DBAppMgr:
- `status_.set(STARTING, "Waiting for DBAppMgr to start")`
- `dbAppMgr_.init("DBAppMgrInterface", Config::numStartupRetries(), Config::maxMgrRegisterStagger())`
  - `DBAppMgrGateway` 继承 `ManagerAppGateway`,`init` 实现:`Mercury::MachineDaemon::findInterface(interfaceName, 0, addr, numRetries)` 带重试查找,可选 `maxMgrRegisterStagger` 引入随机延迟避免启动峰值
- `new AddToDBAppMgrHelper(*this)`:构造时自动 `send()`,调用 `dbApp_.dbAppMgr().addDBApp(this)`,向 DBAppMgr 发 `DBAppMgrInterface::addDBApp` 请求
- 收到回复时 `AddToDBAppMgrHelper::finishInit` 调用 `dbApp_.onDBAppMgrRegistrationCompleted(data)`

##### onDBAppMgrRegistrationCompleted() — 后半段初始化

`dbapp.cpp:488-561`,收到 DBAppMgr 回复(含 `id_`、`shouldAlphaResetGameServerState`、DBApp 哈希):

1. `data >> id_ >> shouldAlphaResetGameServerState`
2. `dbApps_.updateFromStream(data)`:更新本进程的 DBApp 哈希表
3. 判断是否为 Alpha(`this->isAlpha()` = `id_ == dbApps_.alpha().id()`)
4. **执行非 Alpha 通用初始化**:
   - `initAppIDRegistration`:
     - `LoggerMessageForwarder::registerAppID(id_)`
     - `DBAppInterface::registerWithMachined(interface_, id_)`:向 bwmachined 注册
     - `startPythonServer(pythonPort, id_)`:启动 Python 远程调试服务
   - `initDatabaseStartup`:
     - 非 Alpha 时校验 `pDatabase_->supportsMultipleDBApps()`
     - `pDatabase_->startup(*pEntityDefs_, mainDispatcher_, DBAppConfig::numDBLockRetries())`:启动数据库(锁/同步)
   - `initBirthDeathListeners`:注册 DBAppMgr 的 birth/death listener
   - `initWatchers`:`BW_REGISTER_WATCHER(id_, "dbappXX", "dbApp", ...)`
   - `initConfig`:设置 `shouldCacheLogOnRecords_`
   - `initReviver`:`ReviverSubject::instance().init(&interface_, "dbApp")`
   - `initGameSpecific`
5. **分支:Alpha 路径**:`initDBAppAlpha()`
6. **分支:非 Alpha 路径**:`initTimers()` + `initScriptAppReady()` + `onInitCompleted()`

##### Alpha 专属初始化

**`initDBAppAlpha`**(`dbapp.cpp:810-839`):
1. `initAcquireDBLock`:`pDatabase_->lockDB()` 加 DB 锁,防止 `consolidate_dbs --clear` 等独占操作
2. `initBillingSystem`:`BillingSystemCreator::createFromConfig(*pEntityDefs_, *this)`
3. 若 `shouldAlphaResetGameServerState_` 为 true(首次启动):
   - `initResetGameServerState` → `initSecondaryDBsAsync`
     - XML 类型直接跳到 `onSecondaryDBsInitCompleted`
     - 否则 `initSecondaryDBPrefix`(生成形如 `user_YYYYMMDD_HHMMSS` 的 run ID 前缀)
     - 若 `pDatabase_->shouldConsolidate()` 为 true,`consolidateData()`(异步启动 `Consolidator`)
4. 否则直接 `initWaitForAppsToBecomeReadyAsync`

**`onSecondaryDBsInitCompleted`**(`dbapp.cpp:996-1010`)继续:
- `initBaseAppMgrInitData`:`sendBaseAppMgrInitData()` → `pDatabase_->getBaseAppMgrInitData(*this)`,异步回调 `onGetBaseAppMgrInitDataComplete`,向 BaseAppMgr 发 `initData` 消息
- `initDatabaseResetGameServerState`:`pDatabase_->resetGameServerState()`
- `initWaitForAppsToBecomeReadyAsync`:`status_.set(WAITING_FOR_APPS, ...)`,然后 `initTimers()`

##### initTimers 与等待其他 App

**`initTimers`**(`dbapp.cpp:1275-1292`):
- `statusCheckTimer_`:1 秒周期,`TIMEOUT_STATUS_CHECK`
- `gameTimer_`:`1000000/Config::updateHertz()` 周期,`TIMEOUT_GAME_TICK`

**`checkStatus`**(`dbapp.cpp:1663-1704`)— 每秒执行:
- 若处于 `WAITING_FOR_APPS` 且 BaseAppMgr 通道已建立:向 BaseAppMgr 发 `checkStatus` 请求,回调 `CheckStatusReplyHandler` → `handleStatusCheck`
- `handleStatusCheck` 中检查 `numBaseApps`/`numCellApps`/`numServiceApps` 是否满足 `Config::desiredBaseApps()` 等,满足则调 `onAppsReady()`
- 更新 `curLoad_`(1 - spareTime/totalTime)
- 检查 `mailboxRemapCheckCount_`,到 0 时 `endMailboxRemapping()`
- `checkPendingLoginAttempts`:清理超时的重登录
- 检查 `pDatabase_->hasUnrecoverableError()`,有则 `startSystemControlledShutdown()`

**`onAppsReady`**(`dbapp.cpp:1078-1103`):
- `initScriptAppReady`:触发脚本事件 `onAppReady`、`onDBAppReady`
- 若 Alpha 且需重置:`initSendSpaceData`(从 DB 读 space 数据发给 BaseAppMgr)+ `initEntityAutoLoadingAsync`(`new EntityAutoLoader`,`pDatabase_->autoLoadEntities(*pAutoLoader)`)
- 完成后 `onEntitiesAutoLoadCompleted` → `initNotifyServerStartup`:向 BaseAppMgr 发 `BaseAppMgrInterface::startup` 消息,`dbAppMgr_.notifyServerStartupComplete()` 通知 DBAppMgr
- `onInitCompleted`:`status_.set(DBStatus::RUNNING, "Running")`

##### 主循环与定时器

`handleTimeout`(`dbapp.cpp:1645-1657`):
```cpp
case TIMEOUT_GAME_TICK:
    this->advanceTime();          // ServerApp::advanceTime
case TIMEOUT_STATUS_CHECK:
    this->checkStatus();
```

##### logOn 处理(来自 LoginApp 的登录请求)

**`DBApp::logOn`**(`dbapp.cpp:2022-2088`):
1. `status_.status() != DBStatus::RUNNING` → 拒绝
2. `!pBillingSystem_` → 拒绝(Alpha 初始化未完成)
3. `calculateOverloaded`:`curLoad_ > LoginConditionsConfig::maxLoad()` 且持续超 `overloadTolerancePeriod` → 拒绝
4. `hasOverloadedCellApps_` → 拒绝
5. `new LoginHandler(pParams, addrForProxy, srcAddr, replyID); pHandler->login()`:转交 LoginHandler 处理,最终通过 BaseAppMgr 创建 Base 实体,把 BaseApp 地址回给 LoginApp

##### 配置项

`dbapp_config.cpp`:
- 顶层选项:`desiredBaseApps`、`desiredCellApps`、`desiredServiceApps`(默认 1)
- `<dbApp>/` 选项:`dumpEntityDescription`、`maxConcurrentEntityLoaders`、`numDBLockRetries`、`shouldCacheLogOnRecords`、`shouldDelayLookUpSend`

#### DBAppMgr

##### 类继承

```
ServerApp → ManagerApp → DBAppMgr (+ TimerHandler + Singleton<DBAppMgr>)
```

##### 构造

`dbappmgr.cpp:81-103`:
- `baseAppMgr_`/`cellAppMgr_` 通道设为非常规
- `shouldAcceptLoginApps_(true)`、`startupState_(NOT_STARTED)`

##### init 流程

`dbappmgr.cpp:121-249`:

1. `this->ManagerApp::init(argc, argv)`(即 `ServerApp::init`)
2. `interface().isGood()` 校验
3. `DBAppMgrInterface::registerWithInterface(interface_)`:注册内部接口
4. **找 CellAppMgr**:`Mercury::MachineDaemon::findInterface("CellAppMgrInterface", 0, cellAppMgrAddress, Config::numStartupRetries())`,失败则退出
5. **找 BaseAppMgr**:同上
6. **同步询问 BaseAppMgr 是否已启动**:
   - `BaseAppMgrInterface::requestHasStarted` + `BlockingReplyHandlerWithResult<bool>`
   - `waitForReply(&baseAppMgr_.channel())` 阻塞等回复
   - 若 `hasStarted == true`(恢复模式):
     - 记录 `dbAppAddStartWaitTime_ = BW::timestamp()`
     - 启动 2 秒一次的 `gatherLoginAppsTimer_`(`TIMEOUT_GATHER_LOGIN_APPS`)收集所有 LoginApp 和 DBApp
     - `shouldAcceptLoginApps_ = false`
     - `startupState_ = STARTED`
   - 否则 `startupState_ = NOT_STARTED`
7. **向 bwmachined 注册**:`DBAppMgrInterface::registerWithMachined(interface_, 0)`(ID 固定为 0)
8. **注册 birth/death listener**:
   - birth:`DBAppMgrInterface::handleDBAppMgrBirth`(监听 DBAppMgr 重启,若是别人则自己 shutDown)、`handleBaseAppMgrBirth`、`handleCellAppMgrBirth`
   - death:`handleDBAppDeath`(监听 DBApp 死亡)、`handleLoginAppDeath`(监听 LoginApp 死亡)
9. `ReviverSubject::instance().init(&interface_, "dbAppMgr")`
10. **启动 tick 定时器**:`1000000/Config::updateHertz()` 周期,`TIMEOUT_TICK`
11. **注册 Watcher**:`BW_REGISTER_WATCHER(0, "dbappmgr", "dbAppMgr", ...)`,挂 `numDBApps`、`dbApps`(MapWatcher)、`alphaAppID`

##### 多 DBApp 管理

**添加 DBApp:`addDBApp`**(`dbappmgr.cpp:480-526`):
1. 若 `startupState_ == INDETERMINATE`(Alpha 还没完成首次启动):直接回空包让 DBApp 重试
2. `++lastDBAppID_`,创建 `DBAppPtr pDBApp = new DBApp(interface_, srcAddr, lastDBAppID_, header.replyID)`
3. 插入 `dbApps_` 哈希表和 `addressMap_`
4. **若是第一个 DBApp(将成为 Alpha)**:`sendDBAppHashUpdate(true)` 立即通知所有相关方
5. **否则**:`dbAppAddStartWaitTime_ = BW::timestamp()`,等 `onStartOfTick` 中累积 1 秒后批量回复

**哈希更新广播:`sendDBAppHashUpdate`**(`dbappmgr.cpp:643-703`):
1. `sendDBAppHashUpdateToBaseAppMgr`:向 BaseAppMgr 发 `updateDBAppHash` 消息
2. 遍历每个 DBApp 调 `pDBApp->updateDBAppHash(dbApps_, shouldAlphaResetGameServerState)`:
   - 若该 DBApp 有 pending 回复(`addDBApp` 的 replyID),用 `startReply` 回复,带上 `id_`
   - 否则发 `DBAppInterface::updateDBAppHash` 消息
   - 数据含 `uint8 shouldAlphaResetGameServerState` 和哈希表
   - **Alpha 且 `startupState_ == NOT_STARTED`** 时该标志为 true,并设置 `startupState_ = INDETERMINATE`,等待 Alpha 通知启动完成
3. 若 `haveNewAlpha`:
   - `sendDBAppHashUpdateToCellAppMgr`:`CellAppMgrInterface::setDBAppAlpha` 消息
   - 遍历所有 `loginApps_`,发 `LoginIntInterface::notifyDBAppAlpha` 消息,通知新 Alpha 地址

**DBApp 死亡:`handleDBAppDeath`**(`dbappmgr.cpp:562-633`):
1. 从 `addressMap_`/`dbApps_` 删除
2. 若 Alpha 死亡且 `startupState_ == INDETERMINATE`:异步向 BaseAppMgr 发 `requestHasStarted`,回调 `HasStartedRequestHandler` → `onBaseAppMgrStartStatusReceived` → `serverHasStarted(hasStarted)`,更新状态并重新 `sendDBAppHashUpdate(true)`
3. 否则 `sendDBAppHashUpdate(wasAlpha)` 通知所有相关方

**LoginApp 管理:`addLoginApp`**(`dbappmgr.cpp:741-770`):
1. 若 `!shouldAcceptLoginApps_ || dbApps_.empty()`:回空包让 LoginApp 重试
2. 否则 `loginApps_.insert(srcAddr)`,回复 `++lastLoginAppID_` 和当前 DBApp Alpha 地址

**启动完成通知:`serverHasStarted`**(`dbappmgr.cpp:798-841`):由 DBApp Alpha 调 `dbAppMgr_.notifyServerStartupComplete()` 发 `DBAppMgrInterface::serverHasStarted` 空消息触发。把 `startupState_` 从 `INDETERMINATE` 改为 `STARTED`(或 `NOT_STARTED` 如果失败)。

---

### 3.6 LoginApp(登录)

#### 类继承

```
ServerApp → LoginApp (+ TimerHandler + Singleton<LoginApp>)
```

**注意**:LoginApp **不经过 ScriptApp**,**无 Python 脚本**。

#### 构造函数

`loginapp.cpp:117-170`,构造时已完成关键资源创建:
- `extInterface_`(`NETWORK_INTERFACE_EXTERNAL` 类型)绑定外部端口(默认 `PORT_LOGIN`)
- `tcpServer_` 监听外部 TCP
- 根据 `BWConfig::get("shouldUseWebSockets", true)` 决定是否创建 `LoginStreamFilterFactory`
- 调用 `bindToPrescribedPort` 绑定配置端口,失败则 `bindToRandomPort`
- `dbAppAlpha_.channel().isLocalRegular(false)/isRemoteRegular(false)`:DBAppAlpha 通道设为非常规

#### init() 流程

`loginapp.cpp:187-361`,`LoginApp::init` 在 `ServerApp::init` 基础上追加:

1. **外部接口校验**:`extInterface_.isGood()`、`tcpServer_.isGood()`
2. **TCP 流过滤器**:`tcpServer_.pStreamFilterFactory(pStreamFilterFactory_.get())`
3. **协议版本号打印**
4. **初始化 LogOnParams 编码器**:`initLogOnParamsEncoder()`,从 `Config::privateKey()`(默认 `server/loginapp.privkey`)加载 RSA 私钥,构造 `RSAStreamEncoder`
5. **内部接口校验**:确保 UDP 端口已打开
6. **NAT 配置初始化**:`NATConfig::postInit()`,检查内外网 IP
7. **配置项校验**:`maxRepliesOnFailPerSecond >= 2`
8. **注册 Watcher**:`numLogins`、`numLoginFailures`、`numLoginAttempts`、`clientServerProtocol`、`numBannedIPAddresses`
9. **ReviverSubject 初始化**:`ReviverSubject::instance().init(&this->intInterface(), "loginApp")`
10. **找 DBAppMgr**:`BW_INIT_ANONYMOUS_CHANNEL_CLIENT(dbAppMgr_, this->intInterface(), LoginIntInterface, DBAppMgrInterface, numStartupRetries)`
11. **注册消息接口**:
    - `LoginInterface::registerWithInterface(extInterface_)`:外部接口(客户端登录)
    - `LoginIntInterface::registerWithInterface(this->intInterface())`:内部接口
12. **设置外部接口延迟/丢包模拟**
13. **限流配置**:`maxExternalSocketProcessingTime`、`loginRateLimit`、`ipAddressRateLimit`、`ipAddressPortRateLimit`
14. **触发 DBAppMgr 注册**:`new AddToDBAppMgrHelper(*this)`,向 DBAppMgr 发 `DBAppMgrInterface::addLoginApp` 请求
15. **登录挑战(Challenge)工厂配置**

#### finishInit() — DBAppMgr 应答后

`loginapp.cpp:390-500`,由 `AddToDBAppMgrHelper::finishInit` 在收到 DBAppMgr 回复时调用。回复数据流含 `LoginAppID` + `Mercury::Address dbAppAlphaAddr`。

完成步骤:
1. 保存 `id_` 和 `dbAppAlpha_.addr()`
2. `LoginIntInterface::registerWithMachined(this->intInterface(), id_)` 向 bwmachined 注册
3. 若 `Config::registerExternalInterface()`,`LoginInterface::registerWithMachined(extInterface_, id_)`
4. `LoggerMessageForwarder::pInstance()->registerAppID(id_)`
5. `Mercury::MachineDaemon::registerBirthListener(..., LoginIntInterface::handleDBAppMgrBirth, "DBAppMgrInterface")`:监听 DBAppMgr 重启
6. `enableSignalHandler(SIGUSR1)`:用于触发受控关停
7. **注册 Watcher 系统**:`BW_REGISTER_WATCHER(0, "loginapp", "loginApp", ...)`,挂上 `nubExternal`、`command/statusCheck`、`command/shutDownServer`、`command/clearIPAddressBans`、`dbAppMgr`、`averages`、`challenges/config|stats`、`dbAppAlpha`、`id`
8. **启动定时器**:
   - `statsTimer_`:周期 `UPDATE_STATS_PERIOD=1000000`us(1 秒),回调 `loginStats_`
   - `tickTimer_`:周期 `1000000/Config::updateHertz()`,回调 `this`(`TIMEOUT_TICK`)

#### 客户端登录请求处理

**`LoginApp::login`**(`loginapp.cpp:693-1026`)是核心登录处理函数,被 `LoginInterface::login` 消息调用。

完整流程:
1. **限流检查**:每个 `rateLimitDuration` 时间块重置 `numAllowedLoginsLeft_`
2. **allowLogin 检查**:`Config::allowLogin()` 为 false 直接拒绝
3. **IP 封禁检查**:查 `ipAddressBanMap_`,过期则清除
4. **IP 封禁表周期清理**
5. **空 IP 拒绝**:防伪造 web 客户端
6. **重复登录检查**
7. **协议版本读取与校验**:读 `clientProtocol`,与 `ClientServerProtocolVersion::currentVersion()` 比较
8. **重复 pending 登录处理**:`handleResentPendingAttempt`
9. **限流拒绝**
10. **DB 就绪检查**:`isDBReady()`(即 `dbAppAlpha_.channel().isEstablished()`)
11. **系统过载检查**
12. **登录挑战处理**:`processForLoginChallenge`。如果配置了 `challengeType` 且客户端尚未响应,会发 `LOGIN_CHALLENGE_ISSUED` 让客户端解题
13. **解密 LogOnParams**:
    - 校验 `maxLoginMessageSize`
    - 用 `pLogOnParamsEncoder_`(RSA)解密,失败时若 `allowUnencryptedLogins` 则重试无加密
    - 校验 `maxUsernameLength`/`maxPasswordLength`
14. **重复缓存登录处理**:`handleResentCachedAttempt`,成功登录的回包缓存一段时间,防止丢包重发
15. **限流计数递减**
16. **加密密钥检查**
17. **passwordlessLoginsOnly 检查**
18. **构造 ClientLoginRequest 缓存**:`loginRequests_[source]`
19. **构造 DatabaseReplyHandler 并向 DBApp Alpha 发 `DBAppInterface::logOn` 请求**:
    ```cpp
    DatabaseReplyHandler * pDBHandler = new DatabaseReplyHandler(*this, source, pChannel, header.replyID, pParams);
    Mercury::Bundle & dbBundle = this->dbAppAlpha().bundle();
    dbBundle.startRequest(DBAppInterface::logOn, pDBHandler);
    dbBundle << source << *pParams;
    this->dbAppAlpha().send();
    ```

#### 与 baseapp/dbapp 协同

- **与 DBApp Alpha**:通过 `dbAppAlpha_`(`ChannelOwner`)发 `logOn` 请求,异步等回复。DBApp 处理后回调 `DatabaseReplyHandler`,最终走 `sendAndCacheSuccess`/`sendSuccess` 回客户端。成功回复中包含 BaseAppMgr 分配的 BaseApp 地址(由 DBApp Alpha 通过 BaseAppMgr 创建实体得到)
- **与 DBAppMgr**:`handleDBAppMgrBirth` 处理 DBAppMgr 重启;`notifyDBAppAlpha` 接收 DBAppMgr 通知的新 DBApp Alpha 地址

#### 配置项

`loginapp_config.cpp`:
- `shouldShutDownIfPortUsed`、`verboseExternalInterface`、`maxExternalSocketProcessingTime`、`maxLoginDelay`
- `privateKey`(默认 `server/loginapp.privkey`)
- `allowLogin`、`allowProbe`、`logProbes`、`registerExternalInterface`、`allowUnencryptedLogins`
- `maxRepliesOnFailPerSecond`、`verboseLoginFailures`、`loginRateLimit`、`rateLimitDuration`
- `ipAddressRateLimit`、`ipAddressPortRateLimit`
- `maxUsernameLength`、`maxPasswordLength`、`maxLoginMessageSize`
- `shouldOffsetExternalPortByUID`、`passwordlessLoginsOnly`、`ipBanListCleanupInterval`
- `numStartupRetries`(复用通用配置)
- `challengeType`(特意不通过宏注册 watcher,改在 init 中手动注册,以支持运行时修改)

---

### 3.7 Reviver(进程复活器)

#### 类继承

```
ServerApp → Reviver (+ TimerHandler + Singleton<Reviver>)
```

**注意**:Reviver **直接继承 ServerApp,不经过 ManagerApp**,因为它不"管理"下游 App,而是监控/重启。

#### 设计精髓

- **自杀式复活**:`shutDownOnRevive=true`,每次复活一个进程后自身退出,由 bwmachined 再次拉起,实现"无状态监控"
- **ComponentReviver 抽象**:通过 `IntrusiveObject` 自动注册到全局链表,5 种特化(CellAppMgr/BaseAppMgr/DBAppMgr/DBApp/LoginApp)

#### 构造

`reviver.cpp:37-43`,仅继承 `ServerApp`,初始化 `shuttingDown_=false`、`isDirty_=true`。`components_` 在 `init` 中填充。

#### init 流程

`reviver.cpp:59-222`:

1. **`ServerApp::init`**
2. **`ReviverInterface::registerWithInterface` + `registerWithMachined`**:失败则返回
3. **取全局组件 reviver 列表**:`g_pComponentRevivers` 是 `component_reviver.cpp` 中通过 `IntrusiveObject` 自动注册的全局链表
4. **`queryMachinedSettings()`**:向本机 bwmachined 发 `TagsMessage` 查询 "Components" 标签,根据返回的 tags 决定本机可复活哪些组件(`TagsHandler::onTagsMessage`)。匹配 `component.createName()` 或 `configName()` 的组件设为 enabled,否则 disabled
5. **注册 watcher**
6. **解析 `--add` / `--del` 命令行**:首次 `--add` 会先把所有 reviver 禁用,再启用指定项;`--add` 与 `--del` 不能混用
7. **初始化每个 enabled 的 ComponentReviver**:调用 `(*iter)->init(mainDispatcher_, interface_)`
8. **激活**:按顺序分配 `priority=1,2,...` 并调用 `activate(priority)`
9. **创建两个定时器**:
   - `timerHandle_`:周期 `Config::reattachPeriod()`(默认 10s),arg=`TIMEOUT_REATTACH`
   - `tickTimer_`:周期 `1000000/Config::updateHertz()`,arg=`TIMEOUT_TICK`,名为 `"TickTimer"`

#### ComponentReviver 单组件监控

`component_reviver.cpp`,`ComponentReviver` 是抽象基类,通过 `IntrusiveObject< ComponentReviver >( g_pComponentRevivers )` 自动登记到全局列表。

**构造**:保存 `configName_`、`name_`、`interfaceName_`、`createParam_`、默认 `maxPingsToMiss_=3`、`isEnabled_=true`。

**`init`**:
- 从 `BWConfig` 读 `reviver/<configName>/pingPeriod`(默认 `ReviverConfig::pingPeriod()`)、`subjectTimeout`、`timeoutInPings`
- `initInterfaceElements()`(子类实现,绑定 birth/death/ping 消息 ID)
- `Mercury::MachineDaemon::findInterface(interfaceName_, 0, addr_, 4)` 找到当前进程,4 次重试
- 注册 birth/death listener

**`activate(priority)`**:若 `addr_.ip != 0` 且未设过 timer,设 `pingsToMiss_=maxPingsToMiss_`、`timerHandle_=pDispatcher_->addTimer(pingPeriod_, this, NULL, "ComponentReviver")`、记录 `priority_`。

**`handleTimeout` 内部周期**:
```cpp
if (pingsToMiss_ > 0) {
    --pingsToMiss_;
    bundle.startRequest(*pPingMessage_, this);  // 发 reviverPing 请求
    bundle << priority_;
    pInterface_->send(addr_, bundle);
} else {
    this->revive();   // 失联太久,重启
}
```

**ping 应答 `handleMessage(..., returnCode)`**:`REVIVER_PING_YES` 时重置 `pingsToMiss_=maxPingsToMiss_`,若尚未 attached 则标记 attached 并 `Reviver::markAsDirty()`;否则 `deactivate()`。

**birth/death `handleMessage`**:birth 时更新 `addr_`;death 时若死亡地址等于 `addr_` 则 `revive()`,否则打 ERROR。

**`revive`**:若之前是 attached 的,先 `deactivate()`,清空 `addr_`,然后 `Reviver::pInstance()->revive(createParam_)`。

**`Reviver::revive(createComponent)`**(`reviver.cpp:440-474`):
```cpp
CreateMessage cm;
cm.uid_ = getUserId();
cm.recover_ = 1;
cm.name_ = createComponent;
cm.config_ = BW_COMPILE_TIME_CONFIG;
cm.sendAndRecv( srcaddr, htonl(0x7f000001U) );   // 发给本机 machined
if (Config::shutDownOnRevive()) {
    this->shutDown();      // 默认 true,reviver 复活一个进程后就退出
}
```

即:通过 `CreateMessage` 让本机 bwmachined 用 `machined.conf` 中对应名称的命令行启动一个新进程,并带 `-recover` 参数(`recover_=1`)。`shutDownOnRevive=true` 意味着 reviver 一次只复活一个进程后自身退出,由 bwmachined 再次拉起一个 reviver 来负责下一轮监控——这是为了避免 reviver 自身状态污染。

#### 各组件 Reviver 的特化

`component_reviver.cpp:298-323`,通过宏 `MF_REVIVER_HANDLER` 批量生成:

```cpp
MF_REVIVER_HANDLER( cellAppMgr, CellAppMgr, "cellappmgr" )
MF_REVIVER_HANDLER( baseAppMgr, BaseAppMgr, "baseappmgr" )
MF_REVIVER_HANDLER( dbAppMgr,   DBAppMgr,   "dbappmgr" )
MF_REVIVER_HANDLER( dbApp,      DBApp,      "dbapp" )
MF_REVIVER_HANDLER2( loginApp,   Login, LoginInt, "loginapp" )
```

每个特化类(`CellAppMgrReviver` 等)在构造时通过 `IntrusiveObject` 注册到 `g_pComponentRevivers`,并在 `initInterfaceElements()` 中绑定:
- `pBirthMessage_ = &ReviverInterface::handleXXXBirth`
- `pDeathMessage_ = &ReviverInterface::handleXXXDeath`
- `pPingMessage_ = &XXXInterface::reviverPing`

#### 主循环 handleTimeout

`reviver.cpp:297-394`:

- **`TIMEOUT_REATTACH`**:每 10s 一次"重新连接"流程:
  1. 从 `g_pComponentRevivers` 重新拷贝 `components_`——支持运行时新增的 reviver 类型
  2. 把 enabled 且 `priority>0` 的放入 `activeSet`,`priority==0` 的放入 `deactive`
  3. 压缩 activeSet 的优先级,并对 deactive 列表 `random_shuffle` 后依次 `activate(++priority)`——随机化避免多台机器同时抢同一个角色
  4. `isDirty_` 时打印一份 attached 组件摘要
- **`TIMEOUT_TICK`**:`advanceTime()`,推进 game time

#### 配置项

`reviver_config.cpp`,`BW_CONFIG_PREFIX "reviver/"`:
- `reattachPeriod=10.f`
- `pingPeriod=REVIVER_DEFAULT_PING_PERIOD`
- `subjectTimeout=REVIVER_DEFAULT_SUBJECT_TIMEOUT`
- `shutDownOnRevive=true`
- `timeout=3.0`、`timeoutInPings=0`(派生为 `timeout/pingPeriod`)
- `postInit`:若 `timeoutInPings==0` 则按 `timeout/pingPeriod` 计算;校验 `pingPeriod <= subjectTimeout`

---

### 3.8 Client(客户端)

#### 整体启动架构概览

BigWorld Engine 客户端启动采用分层架构,从 Windows 入口点逐层深入到引擎核心。整体调用链为:

```
wWinMain (winmain.cpp)
  └─ CallWithExceptionFilter
       └─ BWWinMain (bw_winmain.cpp)
            ├─ parseCommandLine      (命令行解析)
            ├─ App 构造函数           (配置加载)
            ├─ Moo::init             (渲染基础初始化)
            ├─ CreateWindow          (创建主窗口)
            ├─ App::init             (子系统初始化)
            │    └─ MainLoopTasks::root().init()  (按序初始化所有子系统App)
            └─ 主消息循环             (PeekMessage + updateFrame)
```

**与服务器端的根本差异**:
- 不使用 `bwMainT<T>` 模板,不依赖 bwmachined
- 使用 `MainLoopTasks`(依赖驱动)而非 `EventDispatcher`
- 子系统通过**单例 + 构造函数自注册**模式加入 MainLoopTasks
- 主循环是 Windows `PeekMessage` 轮询

#### WinMain 入口函数

文件:`client/winmain.cpp`

**两种构建模式**:

**1) 独立可执行模式**:
```cpp
int PASCAL wWinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance,
                    LPWSTR lpCmdLine, int nCmdShow )
```
- 注册窗口类 `WNDCLASS wc`(类名 `s_className = L"App"`,使用 `CS_HREDRAW | CS_VREDRAW` 风格)
- **关键调用** `CallWithExceptionFilter(BWWinMain, ...)`,通过异常过滤器包装 `BWWinMain`,实现崩溃转储
- `UnregisterClass` 清理

**2) Python 模块模式**(`_WINDLL` 定义时):
- `DllMain` 在 `DLL_PROCESS_ATTACH` 时注册窗口类
- 导出 `run(path, commandLine)` 函数供外部调用
- 导出 Python 模块方法 `py_bwclient_run`,使客户端可作为 Python 模块嵌入运行

#### BWWinMain - 核心启动逻辑

文件:`bw_winmain.cpp:78-299`

**启动序列**:

1. `BW_SYSTEMSTAGE_MAIN()` 标记进入主阶段
2. `BWResource bwresource` - 在栈上创建资源管理器(避免静态析构)
3. `parseCommandLine(lpCmdLine)` - 命令行解析
4. `ExternalProfiler::initialize()` - 外部性能分析器初始化
5. `timeBeginPeriod(1)` - 设置系统计时器精度为 1ms
6. **关键** `App app(configFilename, compileTimeString)` - 实例化客户端 App
7. 加载偏好设置(preferences.xml):
   - 通过 `PathedFilename` 解析 preferences 文件路径(基于 EXE 路径)
   - 加载 preferences DataSection
   - 从 `graphicsPreferences` 中提前读取 `DEVICE_EX` 设置(`exInterface`),用于决定是否使用 D3D Ex 设备
8. **`Moo::init((exInterface == 0))`** - **初始化 Moo 渲染引擎**(根据 exInterface 决定是否强制禁用 Ex 设备)。失败则直接返回
9. 从配置读取窗口位置/尺寸:
   - 从 `rootSection` 读取 `clientWindow/x|y|width|height`(默认 1024x768)
   - 读取 `appTitle` 覆盖窗口标题
   - 窗口标题追加 `BUILD_CONFIGURATION`
   - 宽度加边框*2,高度加标题栏
10. `CreateWindow` 创建主窗口(WS_OVERLAPPEDWINDOW 风格),失败用 `CRITICAL_MSG` 报错
11. `ShowWindow` + `UpdateWindow` 显示窗口
12. `WTSRegisterSessionNotification` 注册会话通知(用于检测锁屏)
13. **关键** `app.init(hInstance, hWnd)` - 初始化应用子系统。失败则 `setQuiting(true)`
14. `Automation::parseCommandLine(lpCmdLine)` - 解析自动化测试脚本命令行并启动

#### 命令行解析

`bw_winmain.cpp:703-813` `parseCommandLine` 函数

**支持的参数**:
- `--res` / `-r` / `--options`:在其他地方处理
- `--config` / `-c`:指定配置文件名 → `configFilename`
- `--script-arg` / `-sa`:Python 脚本参数 → `Script::g_scriptArgv`
- `--username` / `-u`:登录用户名 → `BigWorldClientScript::setUsername`
- `--password` / `-p`:登录密码 → `BigWorldClientScript::setPassword`
- `--noexdevice`:强制禁用 Ex 设备 → `Moo::RenderContext::forceNoExDevice()`
- OpenAutomate 参数:自动化测试支持,设置 `LogMsg::automatedTest(true)`

`BWResource::init(argc, argv)` - **初始化 BW 资源系统**(解析 paths.xml、BW_RES_PATH 等)

#### 主消息循环

`bw_winmain.cpp:234-266`:

```cpp
bool running = !app.isQuiting();
while(running)
{
    if( PeekMessage( &msg, NULL, 0, 0, PM_REMOVE ) )
    {
        if( msg.message == WM_QUIT ) running = false;
        // SCALEFORM_IME 处理 IME 消息
        TranslateMessage( &msg );
        DispatchMessage( &msg );
    }
    else
    {
        // 没有Windows消息时,运行游戏帧
        if (!app.updateFrame(g_bActive))
        {
            app.quit(false);
        }
    }
}
```

**特点**:经典的 PeekMessage 轮询循环。无 Windows 消息时调用 `app.updateFrame(g_bActive)` 推进游戏逻辑。`g_bActive` 表示窗口是否活跃(非最小化、非锁屏)。

#### ClientApp(App 类)实例化过程

文件:`client/app.cpp` 和 `app.hpp`

App 类继承自 `InputHandler`(处理键盘/鼠标/轴事件)和 `DebugMessageCallback`(处理调试消息),是客户端最高层单例类。

**App 构造函数**(`app.cpp:433-629`):

1. `CStdMf::checkUnattended()` - 检查无人值守运行
2. `frameTimerSetup()` + 记录 `appStartRenderTime_`(计时器初始化)
3. `Script::setTotalGameTimeFn(getGameTotalTime)` - **注册 Python 脚本获取游戏时间的回调**
4. `MF_ASSERT_DEV(pInstance_ == NULL)` + `pInstance_ = this` - **设置单例**(保证只有一个 App 实例)
5. **`AutoConfig::configureAllFrom(AutoConfig::s_resourcesXML)`** - 从 resources.xml 加载所有自动配置项。失败则 `criticalInitError` 并抛出 `InitError` 异常
6. **加载引擎配置文件**:
   - 读取 `s_engineConfigXML.value()`(默认 engine_config.xml)
   - 如果命令行指定了 `configFilename`,优先使用
   - `BWResource::instance().openSection(filename)` 打开配置
   - **`AppConfig::instance().init(configRoot)`** - 初始化 AppConfig 单例(保存配置根 DataSection)
7. (ENABLE_PROFILER)`g_profiler.init(profilerMemorySize)` - 初始化性能分析器(默认 12MB 缓冲区)
8. 设置 XML 属性读取/写入策略
9. 初始化 `DebugFilter` 类别抑制(从 `logging/suppress/categories` 读取)
10. **读取调试按键组合**(从 `debugKeys` 节),默认为反引号键 `KEY_GRAVE`
11. 读取 `renderer/maxFrameRate`(默认 0=不限),计算 `minFrameTime_`
12. 读取 `debug/framesCount`(用于自动退出测试)
13. (ENABLE_HITCH_DETECTION)初始化卡顿检测器
14. `AccessMonitor::instance().active(...)` - 初始化资源访问监控(多线程调试用)
15. (ENABLE_FILE_CASE_CHECKING)文件名大小写检查
16. **CPU 核心数检测** - 单核时 `sleepTime_ = 1`(每帧 sleep 1ms 让 chunk 加载),多核时 `sleepTime_ = 0`
17. 初始化 `drawContexts_` 数组为 NULL

#### App::init - 子系统初始化

`app.cpp:1074-1188`

1. 状态检查 `MF_ASSERT(currentState_ == STATE_UNINITIALISED)`,置为 `STATE_INITIALISED`
2. 保存窗口句柄,并传递给 DeviceApp:
   ```cpp
   hWnd_ = hWnd;
   DeviceApp::s_hInstance_ = hInstance;
   DeviceApp::s_hWnd_ = hWnd;
   DeviceApp::instance.pInputHandler_ = this;  // App作为输入处理器
   ```
3. 读取 `debug/enableLoggingAssetMsg`,若启用则注册 App 为 Debug 消息回调
4. (ENABLE_CONSOLES)`ConsoleManager::createInstance()` - 创建控制台管理器
5. 创建 AssetClient(ENABLE_ASSET_PIPE 时),并设置到 DeviceApp 和 WorldApp
6. `Moo::InterpolatedAnimationChannel::inhibitCompression(false)` - 启用动画压缩
7. `pCameraApp_ = CameraAppPtr(new CameraApp())` - 创建摄像机 App

#### MainLoopTask 组与依赖关系(核心)

`app.cpp:1112-1125`,**这是子系统初始化顺序的核心定义**:

```cpp
MainLoopTasks::root().add( NULL, "Device", NULL );           // 1. 设备组
MainLoopTasks::root().add( NULL, "VOIP",   ">Device", NULL );  // 2. VOIP(在Device后)
MainLoopTasks::root().add( NULL, "Web",   ">VOIP", NULL );     // 3. Web
MainLoopTasks::root().add( NULL, "Script", ">Web",   NULL );   // 4. 脚本
MainLoopTasks::root().add( NULL, "Camera", ">Script", NULL );  // 5. 摄像机
MainLoopTasks::root().add( NULL, "Canvas", ">Camera", NULL );  // 6. 画布
MainLoopTasks::root().add( NULL, "World",  ">Canvas", NULL );  // 7. 世界
MainLoopTasks::root().add( NULL, "Flora",  ">World",  NULL );  // 8. 植被
MainLoopTasks::root().add( NULL, "Facade", ">Flora",  NULL );  // 9. 外观
MainLoopTasks::root().add( NULL, "Lens",   ">Facade", NULL );  // 10. 镜头光效
MainLoopTasks::root().add( NULL, "GUI",    ">Lens",   NULL );  // 11. GUI
MainLoopTasks::root().add( NULL, "Debug",  ">GUI",    NULL );  // 12. 调试
MainLoopTasks::root().add( NULL, "Finale", ">Debug",  NULL );  // 13. 收尾(呈现)
```

`">XXX"` 表示"在 XXX 之后执行"。这些是**组(Group)**,各子系统 App 在自身构造函数中通过 `MainLoopTasks::root().add(this, "XXX/App", NULL)` 注册到对应组下。

**注意**:这里的顺序既决定 init 顺序,也决定每帧的 tick/draw 顺序。

#### 子系统 App 的注册模式

每个子系统 App 采用**单例 + 构造函数自注册**模式。例如:

- `device_app.cpp` 第 70 行:`MainLoopTasks::root().add( this, "Device/App", NULL );`(在 DeviceApp 构造函数中)
- `script_app.cpp` 第 44 行:`MainLoopTasks::root().add( this, "Script/App", NULL );`
- `world_app.cpp` 第 79 行:`MainLoopTasks::root().add( this, "World/App", NULL );`
- `camera_app.cpp` 第 42 行:`MainLoopTasks::root().add( this, "Camera/App", NULL );`
- `finale_app.cpp` 第 43 行:`MainLoopTasks::root().add( this, "Finale/App", NULL );`

这些子系统 App 的实例通常是静态单例(如 `ScriptApp ScriptApp::instance;`)。

#### MainLoopTasks 初始化机制

文件:`lib/cstdmf/main_loop_task.cpp`

**`MainLoopTasks::init()`**(第 44-85 行):
- 先复制待初始化任务列表(防止初始化过程中列表变化)
- **按 order_ 顺序依次调用每个 task 的 init()**。重要:即使某个 init 失败也会继续初始化其他任务(注释说明:这样 fini() 才能正确清理)

**`MainLoopTasks::fini()`**(第 90-96 行):**逆序 fini**,符合 RAII 反向析构原则。

**回到 App::init**:

- `MainLoopTasks::root().init()` - **触发所有子系统 App 按序初始化**。失败则返回 false
- `initLoggers()` - 初始化文件日志器(从 `logging/file` 配置读取)
- `RecreateDeviceCallback::createInstance()` - 注册 D3D 设备重建回调(会调用 Personality 脚本的 `onRecreateDevice`)
- 注册 Watcher(调试按键开关、活动控制台、Sleep 时间)
- 如果 Personality 脚本未设置光标,默认使用 `DirectionCursor`
- `freeLoadingScreen()` - 卸载加载屏幕资源
- `Moo::rc().effectVisualContext().initConstants()` - 初始化 Effect 视觉上下文常量
- `frameStartRenderTime_ = frameTimerValue()` - 重置帧计时(避免首帧 dTime 过大)
- 根据 OS 版本(Vista+)启用文件修改监控
- (ENABLE_GPU_PROFILER)`Moo::GPUProfiler::instance().init()`
- 创建绘制上下文:
  ```cpp
  drawContexts_[COLOUR_DRAW_CONTEXT] = new Moo::DrawContext( Moo::RENDERING_PASS_COLOR );
  drawContexts_[SHADOW_DRAW_CONTEXT] = new Moo::DrawContext( Moo::RENDERING_PASS_SHADOWS );
  ```

#### 各子系统 App 初始化详解

##### DeviceApp(设备子系统 - 最先初始化)

文件:`client/device_app.cpp:81-429`

`DeviceApp::init()` 初始化顺序:

1. `BgTaskManager::init()` + `FileIOTaskManager::init()` - 后台任务管理器
2. 初始化 preferences 文件路径
3. `stampsPerSecondD()` - 初始化时间戳(可能耗时 1 秒)
4. **输入**:`InputDevices::instance().init(s_hInstance_, s_hWnd_)` - **初始化输入设备**(键盘、鼠标、手柄)
5. **网络**:
   - `initNetwork()` - 初始化网络栈
   - `pConnectionControl_ = new ConnectionControl()` - 创建连接控制器
6. **图形**:
   - 遍历显示模式找最大分辨率
   - 从 preferences 读取图形设置(windowed, waitVSync, tripleBuffering, aspectRatio, 分辨率),`Moo::GraphicsSetting::init(graphicsPreferences)` 初始化图形质量设置
   - 应用命令行屏幕设置覆盖
   - 搜索合适的视频模式(支持 fallback)
   - 设置窗口大小、宽高比、VSync、三缓冲
   - `renderer_.reset(new Renderer())` + `renderer_->init(...)` - **初始化渲染器管线**(前向渲染/延迟渲染选择)
   - **`Moo::rc().createDevice(...)`** - **创建 Direct3D 设备**(关键)
7. (SCALEFORM_SUPPORT)创建 Scaleform 管理器,初始化 IME
8. 预加载 shader 格式对应的顶点声明
9. `setupTextureFeedPropertyProcessors()` - 注册材质属性处理器
10. **音频**(FMOD_SUPPORT):`SoundManager::instance().initialise(dsp)` - 初始化 FMOD 音频系统

##### ScriptApp(Python 脚本系统)

文件:`client/script_app.cpp:55-126`

`ScriptApp::init()`:
1. **`BigWorldClientScript::init(AppConfig::instance().pRoot())`** - 核心脚本初始化
2. `EntityManager::instance()` - 创建实体管理器单例
3. `SimpleGUI::init(pConfigSection)` - 初始化 GUI 系统
4. 创建进度条显示:
   - `DeviceApp::s_pGUIProgress_ = new GUIProgressDisplay(loadingScreenGUI, BWProcessOutstandingMessages)` - GUI 进度条
   - `DeviceApp::s_pProgress_ = DeviceApp::s_pGUIProgress_` - 设置为全局进度显示
   - 若无 GUI 进度条,回退到传统 `ProgressDisplay`
5. 添加构建信息到进度条
6. 创建启动进度任务 `ProgressTask`

##### BigWorldClientScript::init(Python 初始化核心)

文件:`client/script_bigworld.cpp:944-1057`

1. `ParticleSystemManager::init()` - 粒子系统初始化
2. **`Script::init(paths, "client")`** - **初始化 Python 解释器**:
   - `paths` 添加实体定义客户端路径和 UDO 路径
   - 这是 Python 脚本系统的入口
3. `MaterialKinds::init()` - 材质类型初始化
4. `Pickler::init()` - 序列化系统
5. 配置 `BigWorld` Python 模块:
   - 设置 `protocolVersion` 属性
   - 设置 `Entity`、`UserDataObject` 类
6. 覆盖 Python 异常钩子为 `_BWExceptHook`
7. 插入物理常量(DUMMY_PHYSICS, STANDARD_PHYSICS 等)
8. 插入 ConnectionControl 阶段常量(STAGE_INITIAL, STAGE_LOGIN 等)
9. **`EntityType::init()`** + **`UserDataObjectType::init()`** - 加载所有实体类型脚本
10. `PyRun_SimpleString("import BigWorld, GUI, Math, Pixie, Keys")` - 预导入常用模块

##### WorldApp(世界系统)

文件:`client/world_app.cpp:90-176`

`WorldApp::init()`:
1. `terrainManager_ = new Terrain::Manager()` - 地形管理器
2. 启动后台任务线程:
   - `BgTaskManager::startThreads("WorldApp", 1)` - WorldApp 后台线程
   - `FileIOTaskManager::startThreads("FileIO", 1)` - 文件 IO 线程
3. **空间和 Chunk 系统初始化**:
   - `SpaceManager::instance().init()` - 空间管理器
   - `CompiledSpace::CompiledSpace::init(...)` - 编译空间
   - `ClientChunkSpaceAdapter::init()` - 客户端 Chunk 空间适配器
   - `ChunkManager::instance().init(configSection)` - Chunk 管理器
4. 注册大量渲染相关 Watcher(线框模式、调试三角形、portals、骨架等)
5. `ForwardDecalsManager::init()` - 前向贴花管理器

##### 其他子系统 App

- **CameraApp**:摄像机系统初始化
- **CanvasApp**:天空盒、环境渲染画布
- **FloraApp**:植被渲染
- **FacadeApp**:外观(建筑立面)
- **LensApp**:镜头光效
- **GUIApp**:Ashes GUI 系统
- **DebugApp**:调试信息、版本信息、统计
- **ProfilerApp**:性能分析
- **FinaleApp**:**最后初始化**,负责场景结束和 present
- **WebApp**:Web 集成
- **VOIPApp**:语音通话

#### 配置加载与 AppConfig

**AppConfig 单例**(`client/app_config.cpp`):
```cpp
class AppConfig {
    DataSectionPtr pRoot_;  // 配置根节点
    static AppConfig & instance();  // 单例
    bool init( DataSectionPtr configSection );  // 保存配置根
};
```

**配置加载流程**:
1. App 构造函数:先 `AutoConfig::configureAllFrom(resources.xml)` 加载资源映射
2. 然后从 `s_engineConfigXML`(默认 engine_config.xml)或命令行指定的 config 文件加载
3. `AppConfig::instance().init(configRoot)` 保存配置
4. 后续所有子系统通过 `AppConfig::instance().pRoot()` 访问配置

#### 主循环和帧更新机制

**客户端 App::updateFrame**(`client/app.cpp:1406-1496`):

```cpp
bool App::updateFrame(bool active)
{
    // 1. 性能分析器tick
    g_profiler.tick();

    // 2. 计算帧时间
    this->calculateFrameTime();

    // 3. 鼠标裁剪更新
    MouseCursor::updateMouseClipping();

    // 4. 资源监控刷新
    BWResource::instance().flushModificationMonitor();

    // 5. 仅当有渲染时间流逝时
    if (dRenderTime_ > 0.f)
    {
        if (active)
        {
            // 5a. Tick阶段
            MainLoopTasks::root().tick( dGameTime_, dRenderTime_ );

            if (Moo::rc().checkDevice())
            {
                // 5b. 动画更新
                MainLoopTasks::root().updateAnimations( dGameTime_ );
                // 5c. 绘制
                MainLoopTasks::root().draw();
            }
        }
        else
        {
            // 5d. 非活跃tick(最小化时)
            MainLoopTasks::root().inactiveTick( dGameTime_, dRenderTime_ );
        }

        // 6. 帧率限制sleep
        if ( sleepTime ) ::Sleep( sleepTime );

        // 7. 帧计数器(测试用)
    }
    return true;
}
```

**calculateFrameTime - 帧时间计算**(`client/app.cpp:2751-2820`):
- 获取当前时间戳
- 计算 `dRenderTime_`(墙钟时间)
- 获取各种连接(ServerConnection, NullConnection, ReplayConnection)
- `dGameTime_ = dRenderTime_` 默认相等
- **连接服务器时直接返回**(游戏时间由服务器控制)
- **回放模式**:应用速度缩放,暂停时设为极小值 `NONZERO_PAUSE_TIME_DIFFERENCE`(0.00001f)
- **离线模式**:应用 `DebugApp::instance.slowTime_` 慢动作缩放
- 应用累积的时间跳变(seek)

**每帧执行顺序**(按依赖关系):

**Tick 顺序**:Device → VOIP → Web → Script → Camera → Canvas → World → Flora → Facade → Lens → GUI → Debug → Finale

关键 tick:
- **DeviceApp::tick**:`InputDevices::processEvents`(输入)、`ConnectionControl::instance().tick`(网络)、`DirectionCursor::tick`、`TextureManager::streamingManager()->tick`、`Moo::rc().nextFrame()`
- **ScriptApp::tick**:`BigWorldClientScript::tick`、`ProviderStore::tick`、`Script::tick`(Python 定时器)、`Physics::tickAll`、`EntityManager::tick`、`pConnection->updateServer()`

**Draw 顺序**(同上):Device → ... → Finale

- **DeviceApp::draw**:`Moo::rc().beginScene()`、`Renderer::pipeline()->begin()`、设置 viewport
- **FinaleApp::draw**:`Renderer::pipeline()->end()`、`Moo::rc().endScene()`、**`Moo::rc().present()`**(最终呈现到屏幕)

#### 登录流程(ConnectionControl)

`connection_control.hpp:113-119`,登录阶段枚举:
```cpp
enum LogOnStage {
    STAGE_INITIAL     = 0,  // 初始
    STAGE_LOGIN       = 1,  // 登录中
    STAGE_DATA        = 2,  // 数据加载
    STAGE_DISCONNECTED = 6  // 已断开
};
```

`ConnectionControl::connect` 由 Personality 脚本调用,传入服务器地址、登录参数、进度回调。登录结果通过 `callConnectionCallback` 回调脚本,参数为 `(stage, status, message)`。

`ConnectionControl::tick` 在每帧由 `DeviceApp::tick` 调用,处理网络消息、推进登录状态机。

#### 渲染、输入、音频子系统启动总结

**渲染系统启动顺序**:
1. `bw_winmain.cpp`:`Moo::init()` - Moo 基础初始化(D3D9 接口)
2. `App` 构造函数:加载图形配置
3. `DeviceApp::init`:
   - `Moo::GraphicsSetting::init` - 图形质量设置
   - `Renderer::init` - 渲染管线(前向/延迟)
   - `Moo::rc().createDevice` - **创建 D3D 设备**
   - Scaleform 初始化
   - 顶点声明预加载
4. `App::init`:
   - `Moo::rc().effectVisualContext().initConstants()` - Effect 常量
   - `Moo::GPUProfiler::init()` - GPU 性能分析
   - 创建 `Moo::DrawContext`(颜色/阴影)
5. `WorldApp::init`:`Terrain::Manager`、`ChunkManager` - 世界渲染数据
6. 每帧:`DeviceApp::draw`(beginScene) → 各绘制 task → `FinaleApp::draw`(endScene + present)

**输入系统启动**:
1. `DeviceApp::init`:`InputDevices::instance().init(s_hInstance_, s_hWnd_)` - 初始化 DirectInput
2. `App::init`:`DeviceApp::instance.pInputHandler_ = this` - App 作为输入处理器
3. `BWWndProc`:所有 Windows 消息转发到 `InputDevices::handleWindowsMessage`
4. 每帧 `DeviceApp::tick`:`InputDevices::processEvents(*pInputHandler_)` - 处理输入事件
5. `App` 实现 InputHandler 接口:`handleKeyEvent`/`handleMouseEvent`/`handleAxisEvent`,按优先级路由到:Debug 键 → 控制台 → 脚本钩子 → Personality 脚本 → App → 玩家实体脚本

**音频系统启动**:
`DeviceApp::init`(FMOD_SUPPORT):
- 读取 `soundMgr/enabled` 配置
- 从 `soundMgr` 节读取音频配置
- `SoundManager::instance().initialise(dsp)` - 初始化 FMOD

---

## 四、跨进程协同总结

### 4.1 启动顺序(典型)

```
1. bwmachined 启动(daemonize, 绑定 UDP 端口)
2. DBAppMgr 启动(init 中查找 CellAppMgr + BaseAppMgr)
3. DBApp Alpha 启动(向 DBAppMgr 注册得到 ID)
4. BaseAppMgr 启动(init 中查找 CellAppMgr,允许尚未就绪)
5. CellAppMgr 启动(init 中查找 BaseAppMgr + DBAppMgr)
6. DBApp 给 BaseAppMgr 发 initData + spaceData
7. DBApp 给 BaseAppMgr 发 startup
   → BaseAppMgr 启动 timer,通知 CellAppMgr startup,通知所有 BaseApp startup
   → 第一个非 ServiceApp BaseApp 收到 bootstrap=true
8. CellApp 在 BaseApp + DBApp Alpha 就绪后才能加入
9. BaseApp 在 CellAppMgr + DBApp 就绪后才能加入
10. LoginApp 随时可启动(等 DBAppMgr 注册得到 ID 和 Alpha 地址)
11. Reviver 启动后监控所有管理进程
```

### 4.2 注册到 bwmachined 的三种方式

1. **`XXXInterface::registerWithMachined(interface, id)`**:把进程的接口地址注册到 bwmachined 的 portmap,让其他进程能通过 `findInterface` 找到
   - `LoginApp::finishInit`(`LoginIntInterface`)
   - `DBApp::initAppIDRegistration`(`DBAppInterface`)
   - `DBAppMgr::init`(`DBAppMgrInterface`,ID=0)
   - `CellAppMgr::init`(`CellAppMgrInterface`)
   - `BaseAppMgr::init`(`BaseAppMgrInterface`)

2. **`Mercury::MachineDaemon::findInterface("XXXInterface", 0, addr, retries)`**:主动查找其他进程(支持重试)
   - `LoginApp::init`(通过 `BW_INIT_ANONYMOUS_CHANNEL_CLIENT`)
   - `DBApp::initBaseAppMgr`(不重试)
   - `DBApp::initDBAppMgrAsync`(经 `DBAppMgrGateway::init`)
   - `DBAppMgr::init`(找 CellAppMgr/BaseAppMgr)

3. **`Mercury::MachineDaemon::registerBirthListener/registerDeathListener`**:订阅其他进程的 birth/death 事件
   - `LoginApp::finishInit`(订阅 DBAppMgr birth)
   - `DBApp::initBaseAppMgr`(订阅 BaseAppMgr birth)
   - `DBApp::initBirthDeathListeners`(订阅 DBAppMgr birth/death)
   - `DBAppMgr::init`(订阅 DBAppMgr/BaseAppMgr/CellAppMgr birth,DBApp/LoginApp death)

### 4.3 主循环共性

所有服务端进程主循环都是 `Mercury::EventDispatcher::processUntilBreak()`(由 `ServerApp::run` 提供),驱动:
- 网络接口收包 → 触发已注册的 `InputMessageHandler`
- 定时器 → 触发 `TimerHandler::handleTimeout`
- Updatables(`ServerApp::callUpdatables`,每 tick 调用)

每个 App 通过 `mainDispatcher_.addTimer` 注册自己的定时器,在 `handleTimeout` 里处理周期任务。

### 4.4 关停共性

- SIGUSR1 / SIGINT → `onSignalled` → `controlledShutDown` 或直接 `shutDown`(`mainDispatcher_.breakProcessing()`)
- 受控关停分阶段:`SHUTDOWN_TRIGGER` → `SHUTDOWN_REQUEST` → `SHUTDOWN_INFORM` → `SHUTDOWN_DISCONNECT_PROXIES` → `SHUTDOWN_PERFORM`
- `onRunComplete` 在 `processUntilBreak` 退出后被调用,做通道排空、DB 关闭等收尾

### 4.5 管理进程之间的相互关系

启动顺序(典型):
1. bwmachined 启动
2. DBAppMgr → DBApp Alpha 启动
3. BaseAppMgr 启动(init 中查找 CellAppMgr,但 CellAppMgr 可能尚未起,所以允许 `REASON_TIMER_EXPIRED`)
4. CellAppMgr 启动(init 中查找 BaseAppMgr、DBAppMgr)
5. DBApp 把 `initData`、`spaceDataRestore` 发给 BaseAppMgr,BaseAppMgr 转发 space 数据给 CellAppMgr
6. DBApp 给 BaseAppMgr 发 `startup` → BaseAppMgr 启动 timer、通知 CellAppMgr `startup`、通知所有 BaseApp `startup`(第一个非 ServiceApp 是 bootstrap)
7. CellApp 在 BaseApp/DBApp Alpha 就绪后才能加入,BaseApp 在 CellAppMgr+DBApp 就绪后才能加入

运行期相互通信:
- **CellAppMgr ↔ BaseAppMgr**:
  - BaseAppMgr → CellAppMgr:`setBaseApp`、`handleBaseAppDeath`、`controlledShutDown`、`checkStatus`、`startup`、`setSharedData`/`delSharedData`
  - CellAppMgr → BaseAppMgr:`controlledShutDown`、`handleCellAppDeath`(经 `CellAppDeathHandler`)、`setSharedData`/`delSharedData`、`ackBaseAppsShutDown`(经 ShutDownHandler)
- **CellAppMgr ↔ DBApp/DBAppMgr**:`writeSpacesToDB`、`writeGameTimeToDB`、`cellAppOverloadStatus`、`handleDBAppMgrBirth`、`setDBAppAlpha`、`handleBaseAppDeath` 转发 DBAppMgr
- **BaseAppMgr ↔ DBApp/DBAppMgr**:`initData`、`spaceDataRestore`、`startup`、`updateDBAppHash`、`updateSecondaryDBs`、`controlledShutDown`

---

## 五、设计亮点总结

| 进程 | 核心设计亮点 |
|------|------------|
| **bwmachined** | daemonize 前构造(早期失败可见)、状态管道检测 exec 成败、PACKET_STAGGER_REPLIES 防风暴、环形 buddy 拓扑、STATE_FILE 持久化防 PID 复用、/proc 重度使用零开销 |
| **CellApp/BaseApp** | 两阶段异步初始化、配置先于构造、TimeKeeper 主从对时、load 上报驱动负载均衡、双接口架构(baseapp)、两级容错备份(baseapp)、chunk 加载与 game tick 解耦(cellapp)、缓冲消息机制(cellapp) |
| **DBApp** | 数据库引擎工厂模式(链接期注册)、Alpha/非 Alpha 分支初始化、IDClient 批量获取实体 ID 段、auto-load 持久化实体恢复 |
| **DBAppMgr** | 批量回复累积 DBApp 添加请求、Alpha 死亡时异步询问 BaseAppMgr 决定恢复策略 |
| **CellAppMgr/BaseAppMgr** | 位掩码跟踪就绪状态、子集模式统一管理 BaseApp+ServiceApp、多阶段受控关停、`CellAppDeathHandler` 等待所有 CellApp ack |
| **LoginApp** | 多层限流、IP 封禁周期清理、登录挑战、重复登录缓存防丢包、RSA 加密登录参数 |
| **Reviver** | **自杀式复活**(每次复活一个就退出,由 machined 再次拉起,实现无状态监控)、ComponentReviver 抽象 + IntrusiveObject 自动注册、随机化避免多机冲突 |
| **Client** | MainLoopTasks 依赖驱动(单例+自注册)、PeekMessage 轮询、三层配置(resources.xml/engine_config.xml/preferences.xml)、连接服务器时游戏时间由服务器控制 |

---

## 六、关键差异对比表

| 维度 | bwmachined | 服务端 App | Client |
|------|-----------|----------|--------|
| 入口宏 | `BIGWORLD_MAIN_NO_RESMGR` | `BIGWORLD_MAIN` + `bwMainT<T>` | `wWinMain` |
| 主循环 | `select` + `TimeQueue64` | `EventDispatcher::processUntilBreak` | `PeekMessage` 轮询 |
| 子系统组织 | 单类内聚 | 继承链(ServerApp→ScriptApp→EntityApp) | MainLoopTasks 依赖驱动 |
| 配置加载 | `/etc/bwmachined.conf` | `bw.xml` + parentFile 链 | resources.xml + engine_config.xml + preferences.xml |
| 进程模型 | 单线程 + fork/exec 子进程 | 单线程事件循环 | 单线程 + 后台 IO 线程 |
| 网络通信 | 裸 UDP + MGMPacket | Mercury 消息接口 | ConnectionControl + ServerConnection |
| 是否依赖 bwmachined | 自身就是 | 是(查询内网 IP、注册接口、birth/death listener) | 否 |
| 是否有 Python 脚本 | 否 | 是(ScriptApp 派生类,LoginApp/DBAppMgr/Reviver/CellAppMgr/BaseAppMgr 除外) | 是(ScriptApp + Personality) |

---

## 附录:关键文件路径速查

### 公共基础设施
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\server\bwservice.hpp` — `BIGWORLD_MAIN`/`bwMainT`/`doBWMainT` 模板
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\server\server_app.hpp` / `.cpp` — ServerApp 基类
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\server\script_app.hpp` / `.cpp` — ScriptApp(Python 脚本层)
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\server\entity_app.hpp` / `.cpp` — EntityApp(CellApp/BaseApp 共用)
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\server\manager_app.hpp` / `.cpp` — ManagerApp(CellAppMgr/BaseAppMgr 共用)
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\server\bwconfig.cpp` — `BWConfig::init` XML 配置加载
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\server\server_app_config.cpp` — `ServerAppConfig::init` 配置选项批量读取
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\server\signal_processor.hpp` / `.cpp` — 信号处理两阶段架构
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\server\time_keeper.hpp` / `.cpp` — 主从时间同步
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\server\child_process.cpp` — fork/exec 子进程管理
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\server\manager_app_gateway.cpp` — 与 Manager 通信的网关

### bwmachined
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\tools\bwmachined\main.cpp` — 入口
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\tools\bwmachined\bwmachined.cpp` / `.hpp` / `.ipp` — 核心实现
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\tools\bwmachined\cluster.cpp` — 集群发现
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\tools\bwmachined\listeners.cpp` — birth/death listener
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\tools\bwmachined\incoming_packet.cpp` — 延迟处理广播包
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\tools\bwmachined\server_platform.cpp` / `server_platform_linux.cpp` — 平台抽象
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\tools\bwmachined\linux_machine_guard.cpp` — daemonize/startProcess/进程状态
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\tools\bwmachined\usermap.cpp` — 用户配置加载

### cellapp
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\cellapp\main.cpp` — 入口
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\cellapp\cellapp.cpp` / `.hpp` / `.ipp` — 实现
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\cellapp\cellapp_config.cpp` — 配置项

### baseapp
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\baseapp\main.cpp` — 入口
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\baseapp\baseapp.cpp` / `.hpp` / `.ipp` — 实现
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\baseapp\baseapp_config.cpp` — 配置项

### cellappmgr
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\cellappmgr\main.cpp` — 入口
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\cellappmgr\cellappmgr.cpp` / `.hpp` / `.ipp` — 实现
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\cellappmgr\cellappmgr_config.cpp` — 配置项

### baseappmgr
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\baseappmgr\main.cpp` — 入口
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\baseappmgr\baseappmgr.cpp` / `.hpp` / `.ipp` — 实现
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\baseappmgr\baseappmgr_config.cpp` — 配置项

### dbapp
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\dbapp\main.cpp` / `main_indie.cpp` — 入口
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\dbapp\dbapp.cpp` / `.hpp` / `.ipp` — 实现
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\dbapp\dbapp_config.cpp` — 配置项
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\dbapp\mysql_engine_creator.cpp` — MySQL 工厂
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\dbapp\xml_engine_creator.cpp` — XML 工厂

### dbappmgr
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\dbappmgr\main.cpp` — 入口
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\dbappmgr\dbappmgr.cpp` / `.hpp` — 实现
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\dbappmgr\dbappmgr_config.cpp` — 配置项

### loginapp
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\loginapp\main.cpp` — 入口
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\loginapp\loginapp.cpp` / `.hpp` — 实现
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\loginapp\loginapp_config.cpp` — 配置项

### reviver
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\reviver\main.cpp` — 入口
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\reviver\reviver.cpp` / `.hpp` — 实现
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\reviver\reviver_config.cpp` — 配置项
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\reviver\component_reviver.cpp` — 单组件监控

### client
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\client\winmain.cpp` — Windows 入口点
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\client\bw_winmain.cpp` — BWWinMain 核心逻辑
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\client\app.cpp` / `.hpp` / `.ipp` — 客户端 App 类
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\client\app_config.cpp` / `.hpp` — AppConfig 单例
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\client\device_app.cpp` — DeviceApp(设备子系统)
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\client\script_app.cpp` — ScriptApp(Python 脚本系统)
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\client\script_bigworld.cpp` — BigWorldClientScript::init
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\client\world_app.cpp` — WorldApp(世界系统)
- `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\cstdmf\main_loop_task.cpp` — MainLoopTasks 实现

---

*本文档基于 BigWorld Engine 14.4.1 源码分析生成,涵盖所有 9 类进程的完整启动流程。*
