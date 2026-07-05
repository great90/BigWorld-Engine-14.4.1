# 第1章 BigWorld 引擎概览

> 本章是整本教程的开篇。读完本章,你将了解 BigWorld 引擎的来龙去脉、它在 MMOG 领域的定位、它最核心的三大特性、它依赖的技术栈,以及它那独特的"多进程 + 跨进程实体"架构全貌。后续每一章都会在本章建立的认知地图上,深入到具体子系统。

---

## 目录

- [1.1 BigWorld 引擎的历史与定位](#11-bigworld-引擎的历史与定位)
- [1.2 核心特性概览](#12-核心特性概览)
- [1.3 技术栈与依赖](#13-技术栈与依赖)
- [1.4 整体架构总览](#14-整体架构总览)
- [1.5 进程职责速览](#15-进程职责速览)
- [1.6 特色实现方案预告](#16-特色实现方案预告)
- [1.7 本教程的学习路径建议](#17-本教程的学习路径建议)
- [1.8 小结](#18-小结)

---

## 1.1 BigWorld 引擎的历史与定位

### 1.1.1 公司背景与产品演进

BigWorld 引擎由澳大利亚 **BigWorld Pty Ltd** 公司开发,公司成立于 1999 年,长期专注于大规模多人在线游戏(MMOG)服务器与中间件技术。其旗舰产品 **BigWorld Technology Suite** 在 2000 年代曾是少数几家能撑起单服数万人同时在线的商业游戏引擎之一,与 Unreal、CryEngine 等通用引擎相比,它**从一开始就为 MMOG 而生**,而不是"通用引擎 + 网络扩展包"。

产品演进的几个关键节点:

| 时间 | 事件 |
|------|------|
| 1999 | BigWorld Pty Ltd 成立,开始研发 MMOG 中间件 |
| 2002-2010 | BigWorld Technology 作为商业产品被多家大型 MMOG 采用,以 **《坦克世界》(World of Tanks)** 为代表 |
| 2012 | Wargaming 收购 BigWorld Pty Ltd,引擎转为公司内部技术 |
| 2014 | BigWorld 决定将引擎 **Open-Source Edition(OSE)** 开源,版本定格在 14.4.1 |
| 2014 至今 | OSE 14.4.1 是当前开源版本,许可证为宽松的 BSD 风格(见根目录 `LICENSE`) |

`LICENSE` 文件第一行写着 `Copyright (c) 1999 - 2014 BigWorld Pty Ltd.`,随后是一段接近 BSD 的宽松条款,允许任意使用、修改、再分发甚至商业销售——这对学习者非常友好。

仓库根目录还有几个值得注意的文件:
- `MAINTAINTERS.md`:维护者名单与联系方式;
- `CONTRIBUTING.md`:贡献指南,鼓励通过 issue tracker 与 pull-request 参与改进;
- `THIRD-PARTY-NOTICES`:第三方组件许可证清单;
- `logo.png`:BigWorld logo;
- `bigworld-bwmachined-14.4.1.el7.x86_64.rpm`:bwmachined 守护进程的预编译 RPM(用于 EL7 即 CentOS 7);
- `bigworld-devel-14.4.1.el7.x86_64.rpm`:开发库 RPM。

### 1.1.2 在 MMOG 领域的定位

BigWorld 不像 Unity 那样"什么游戏都能做"。它的设计目标非常聚焦:

- **单服同时在线数千至数万人** 的持久化虚拟世界;
- **强空间相关性** 的玩法(玩家位置、视野、AOE、寻路、碰撞);
- **跨进程无缝世界**——玩家穿越不同服务器进程所管理的区域时,游戏逻辑不中断;
- **服务器侧权威**(authoritative server),客户端只做表现与输入上报,杜绝作弊;
- **强持久化需求**——玩家下线后状态必须可靠保存,服务器重启不丢数据。

正因为目标明确,它在 MMOG 领域有若干经典使用案例:

| 项目 | 说明 |
|------|------|
| **World of Tanks (WoT)** | Wargaming 旗舰作,单服同时在线峰值曾达数万人,是 BigWorld 最知名的案例 |
| **天下3(NetEase)** | 网易早期 MMOG,服务器端基于 BigWorld 改造,长期运营 |
| **风暴战区、Final Fire 等其它作品** | 多个亚洲 MMOG/FPS 混合产品采用 |
| **Fantasydemo** | 社区配套的 Server&Client 教学示例(README 中给出了 Google Drive 链接) |

这些案例的共同点:**世界巨大、玩家稠密、强空间交互**。BigWorld 通过"分布式 CellApp + Ghost 实体"解决了这类游戏的天然难题——本章后续会给出整体架构图,并在第 9、18、19 章深入到源码。

### 1.1.3 14.4.1 版本特点

本教程基于 **BigWorld Engine 14.4.1 Open-Source Edition**。相对于更早期的内部商业版,14.4.1 具备以下特点:

1. **完整开源**:服务器、客户端、工具链全量代码都在仓库内,无黑盒 SDK。整个 `programming/bigworld/` 目录包含所有源码,约数十万行。
2. **跨平台编译**:服务器端面向 CentOS 7,客户端与工具链面向 Windows(VS 2019-2022);构建系统使用 CMake 与 Makefile 并存(参见 `programming/bigworld/build/`)。
3. **Docker 化部署**:仓库根目录带有 `bigworld-bwmachined-14.4.1.el7.x86_64.rpm`、`bigworld-devel-14.4.1.el7.x86_64.rpm` 两个 RPM 包,以及 `programming/bigworld/build/docker/Dockerfile`,可直接以容器形式跑通开发环境。
4. **Vagrant 拉起 CentOS 虚机**:Windows 开发者通过 Vagrantfile 自动配置一台 CentOS 7,用以本地编译和运行服务端。
5. **配套 PDF 文档**:仓库 `docs/pdf/` 目录提供 *Server Build Guide*、*Server Installation Guide*、*BigWorld Technology Server Whitepaper* 三份官方白皮书,作为权威参考。
6. **稳定状态**:README 中 `Status: Stable`,本版本不会再有官方功能更新,因此作为学习对象非常合适——接口不会变动,文档与代码完全对应。
7. **源码与文档配套**:仓库 `docs/` 下已有 6 份中文实现分析文档(启动流程、CellApp、BaseApp、DBApp、LoginApp、Reviver),以及 `docs/tools/` 下 23 份工具分析文档,本教程正是基于这些分析精炼整合而成。

---

## 1.2 核心特性概览

打开仓库根目录的 `README.md`,你会看到它非常简洁地列出了 BigWorld OSE 的三大关键特性:

```
BigWorld OSE key features:

 - Load-Balancing
 - Scalability
 - Fault Tolerance
```

这三个词贯穿了整个引擎的设计哲学。本节先给出概览,后续第 19 章会专门深入到负载均衡与故障恢复的实现细节。

### 1.2.1 Load-Balancing(负载均衡)

**问题**:MMOG 同时在线人数随时间波动巨大(白天 vs 凌晨),且玩家在空间上分布不均(主城 vs 野外)。如果一台服务器固定承担一个区域,某区域玩家激增时该服务器就会过载。传统做法是"分区服"——把世界硬切成多个独立服务器,但这导致玩家无法跨区流动。

**BigWorld 的解决思路**:**两层负载均衡** ——
- **第一层(空间内)**:CellAppMgr 把一个 Space(空间)的矩形区域切成多个 Cell(分区),每个 Cell 由一台 CellApp 承担。当某个 Cell 负载过高,CellAppMgr 会**动态收缩该 Cell 的边界矩形**,把一部分区域交给相邻 Cell,从而把部分实体和负载迁移过去。这种调整每秒触发一次,粒度非常细。
- **第二层(跨 CellApp 组)**:CellAppMgr 通过洪水填充把所有 CellApp 划分成多个 `CellAppGroup`(元负载均衡组),组内 CellApp 互相之间通信开销低;当整组都过载时,把整组中的若干 Cell 迁移到另一组。这种调整每 3 秒触发一次,粒度较粗。

两层一起,既能在细粒度上平滑迁移,又能在粗粒度上整体调度。负载算法使用**指数加权移动平均(EWMA)** 平滑瞬时抖动,公式见 `server/cellappmgr/cellapp.cpp:72-90`。

> 关键源码入口:`server/cellappmgr/cellappmgr.cpp` 中的 `loadBalance()` 与 `metaLoadBalance()` 两个定时器回调。详见第 19 章。

### 1.2.2 Scalability(可扩展性)

**问题**:服务器集群要能水平扩展——增加机器就能提升承载,而不是为单台机器堆硬件(单机性能总有上限)。

**BigWorld 的解决思路**:**进程级水平扩展 + 控制平面/数据平面分离** ——
- 同一类进程(CellApp、BaseApp、LoginApp)可以**多实例并行运行**,新增机器只需启动新进程并向管理器注册即可;
- 每类进程都有一个 **Mgr**(CellAppMgr / BaseAppMgr / DBAppMgr)作为控制平面单例,负责调度;
- 实体本身可以**跨进程迁移**:Real 实体可以从一个 CellApp 迁到另一个,Ghost 实体则按需在被观察的 CellApp 上创建/销毁;
- 数据平面之间通过 `CellAppChannels`(基于 Mercury 网络层)互联,实例数无关协议;
- 单一 Space 也可以**跨越多个 CellApp**——这是 BigWorld 与传统"分服"引擎的最大区别。

> 这套架构让 BigWorld 可以做到"加机器即扩容",在 14.4.1 中,只要在 `bw.xml` 中调整进程数量,启动器(bwmachined)就会自动 fork 出对应数量的子进程。

### 1.2.3 Fault Tolerance(容错性)

**问题**:几十台服务器组成的集群,单台宕机几乎是常态——硬件故障、OOM、程序 Bug 都可能让进程崩溃。如何保证某进程崩掉时,玩家几乎无感知?

**BigWorld 的解决思路**:**主备 + Reviver + Ghost/Backup** ——
- **CellApp 崩溃**:它上面的 Real 实体丢失,但每个 Real 实体都有 **backup 在 BaseApp 上**(周期性轮转备份)。Reviver 检测到 CellApp 死亡后,通知 BaseApp 把对应 backup 升级为 Real,再由 CellAppMgr 重新分配这些实体到其他 CellApp。
- **BaseApp 崩溃**:BaseApp 是玩家代理进程,客户端连不上会断线;通过 **BaseApp 主备切换**(BaseAppMgr 管理)让备用 BaseApp 接管。
- **DBApp 崩溃**:DBAppMgr 维护 DBApp Alpha/Backup 模式,Alpha 挂掉时 Backup 升级。
- **Mgr 进程崩溃**:Reviver 监听所有进程的 birth/death,Mgr 重生后会被自动识别并恢复状态。
- **bwmachined 自身**:每台机器一个,通过 `save()` 把进程表写到 `/var/run/bwmachined.state`,自身 SIGTERM 重启后可恢复进程表。集群中其它 bwmachined 通过周期性 flood 探测发现它失踪,通告 `ANNOUNCE_DEATH`。

容错设计的关键在于"**备份粒度**":不是整个进程镜像备份,而是实体粒度轮转备份——每个 tick 备份一小批,负载均衡地分散到不同 BaseApp,这样崩溃时恢复压力不会集中在一台机器上。

> 容错细节请见第 12 章(Reviver)与第 19 章(主备切换)。

---

## 1.3 技术栈与依赖

### 1.3.1 编程语言与运行环境

| 维度 | 选型 | 说明 |
|------|------|------|
| **服务器主语言** | C++ | 性能敏感路径,如网络、空间分割、AOI |
| **服务器脚本语言** | Python 2.7 风格 | 游戏逻辑、定时器回调、Personality(人格脚本) |
| **客户端主语言** | C++ | 渲染、Chunk 加载、动画、特效 |
| **客户端脚本语言** | Python | UI 逻辑、Module 切换、Entity 表现 |
| **服务器目标 OS** | CentOS 7 | RPM 包名后缀 `.el7.x86_64` 即来源于此 |
| **客户端目标 OS** | Windows 10 | 客户端为 DirectX 渲染,主要支持 Windows |

> **关于 Python 2 的提醒**:BigWorld 14.4.1 开源版本使用的是 Python 2 系列 API(如 `PyString_*`、`PyInt_*`)。本教程不会展开 Python 2 与 3 的差异,但你在阅读 `lib/pyscript/script.cpp` 时会看到大量 Python 2 风格的 C 扩展 API。如果你打算迁移到 Python 3,需要修改整个 `lib/pyscript/` 模块。这也是为什么 README 中提到 "Status: Stable"——本版本不会有官方 Python 3 适配。

### 1.3.2 开发工具链

README 中列出的必备软件:

- **Windows 10 + WSL2 + Hyper-V**:Windows 主机作开发,WSL2 用于跑 Linux 工具链;
- **CentOS 7**:服务端运行环境(可在 WSL2 或 Vagrant/Docker 中提供);
- **Visual Studio 2019-2022**:客户端与工具链编译器(支持 C++17 之前的标准即可);
- **Vagrant**:Windows 上拉起一台 CentOS 7 虚机;
- **Docker**:更轻量的服务端运行容器,`programming/bigworld/build/docker/Dockerfile` 即为服务端构建镜像。

具体来说,本仓库的构建系统支持三种工作流:

1. **Windows + VS 工程**:打开 `programming/bigworld/build/bigworld_cmake.py` 生成的 `.sln` 编译客户端与工具;
2. **CentOS + Make**:在 CentOS 7(或 Vagrant 虚机)上用 `programming/bigworld/build/make/Makefile` 编译服务端;
3. **CentOS + Docker**:`docker build -f programming/bigworld/build/docker/Dockerfile .` 一键构建服务端镜像。

### 1.3.3 第三方库

虽然完整依赖清单需要看 *Server Build Guide*,但从代码目录与 PDF 文档可以归纳出主要第三方组件:

| 类别 | 第三方库 | 用途 | 代码位置 |
|------|---------|------|---------|
| **数据库** | MySQL、MongoDB | DBApp 双存储引擎:MySQL 存结构化实体表、MongoDB 存二级数据库 | `lib/db/`、`lib/db_storage/`、`server/dbapp/` |
| **音频** | FMOD(`lib/fmodsound/`)、VoIP(`lib/emptyvoip/`) | 客户端音频 | `lib/fmodsound/`、`lib/emptyvoip/` |
| **窗口/输入** | SDL | 跨平台窗口与事件(客户端) | 客户端封装 |
| **图形** | DirectX 11(`lib/moo/`) | 客户端渲染后端 | `lib/moo/` |
| **网络** | 自研 Mercury(`lib/network/`) | 可靠 UDP,详见第 5 章 | `lib/network/` |
| **Python 集成** | CPython C API | `lib/pyscript/` 包封装 | `lib/pyscript/` |
| **配置** | 自研 `BWConfig` + TinyXML | `bw.xml` 链式配置 | `lib/cstdmf/`(部分) |
| **数学** | 自研 `lib/math/` | Vector2/3/4、Matrix、Quaternion | `lib/math/` |
| **物理** | 自研 `lib/physics2/` + BSP | 客户端碰撞 | `lib/physics2/` |
| **构建** | CMake + Makefile + 自研 `bigworld_cmake.py` | 跨平台构建 | `programming/bigworld/build/` |

`THIRD-PARTY-NOTICES` 文件中可查看完整的第三方许可证清单。

### 1.3.4 关键自研库一览

BigWorld 几乎所有基础设施都是自研的,这使得代码风格高度统一。下表是 `programming/bigworld/lib/` 下的核心库:

| 库名 | 路径 | 职责 | 教程章节 |
|------|------|------|---------|
| cstdmf | `lib/cstdmf/` | 标准库适配、容器、调试、Watcher、Profiler、内存钩子 | 第 3 章 |
| math | `lib/math/` | 数学:向量、矩阵、四元数、包围盒、多面体 | 第 3 章 |
| network | `lib/network/` | Mercury 网络:Bundle/Channel/Endpoint、可靠 UDP | 第 5 章 |
| pyscript | `lib/pyscript/` | Python C API 封装、Script 对象、Pickler | 第 6 章 |
| entitydef | `lib/entitydef/` | .def 实体定义解析、EntityDefinition、Mailbox | 第 6 章 |
| resmgr | `lib/resmgr/` | 资源管理:DataSection、多文件系统、Zip/Packed | 第 4 章 |
| chunk | `lib/chunk/` | 客户端 Chunk 加载、ChunkItem、VLO | 第 14 章 |
| moo | `lib/moo/` | DX11 渲染:Visual/Material/Light/Camera/Shader | 第 13 章 |
| model | `lib/model/` | 模型:节点树、动画、染料(Tint)、时尚(Fashion) | 第 13 章 |
| physics2 | `lib/physics2/` | BSP 碰撞 | 第 13 章 |
| appmgr | `lib/appmgr/` | 客户端 App/Module/Options/Factory 框架 | 第 13 章 |
| camera | `lib/camera/` | 摄像机系统:Annal/Flexicam | 第 13 章 |
| input | `lib/input/` | 输入:键盘、鼠标、IME | 第 13 章 |
| gizmo | `lib/gizmo/` | 编辑器 Gizmo 工具 | 第 16 章 |
| duplo | `lib/duplo/` | 角色:PyModel/Motor/Servo/Tracker | 第 13 章 |
| guimanager | `lib/guimanager/` | GUI 管理 | 第 13 章 |
| server | `lib/server/` | 服务器共享:ServerApp/ManagerApp/EntityApp 等 | 第 7-12 章 |

每个库都有 `pch.hpp`(预编译头)与 `Makefile`,结构高度一致,后续章节会逐个深入。

---

## 1.4 整体架构总览

BigWorld 是一个**分布式多进程游戏服务器 + 单进程客户端 + 多工具链**的整体。理解架构图是后续阅读任何代码的先决条件。

### 1.4.1 服务器集群拓扑

下图展示了 BigWorld 服务器的进程拓扑(每个方框代表一个或多个独立 OS 进程):

```
                    ┌──────────────────────────────────────┐
                    │           集群管理层                  │
                    │   每台机器一个 bwmachined 守护进程     │
                    │   (UDP 端口 PORT_MACHINED 互通)      │
                    └──────────────┬───────────────────────┘
                                   │ birth/death 广播
        ┌──────────────────────────┼────────────────────────────┐
        ▼                          ▼                            ▼
┌────────────────┐         ┌────────────────┐         ┌──────────────────┐
│  控制平面       │         │  控制平面       │         │   控制平面        │
│  CellAppMgr    │◄───────►│  BaseAppMgr    │◄───────►│   DBAppMgr       │
│  (单例)        │         │  (单例)        │         │   (单例)         │
└───────┬────────┘         └───────┬────────┘         └────────┬─────────┘
        │                          │                           │
        │ addCell / startup        │ addBase                   │ setDBAppAlpha
        │ informOfLoad             │ informOfLoad              │ IDClient::pullIDs
        ▼                          ▼                           ▼
┌────────────────┐         ┌────────────────┐         ┌──────────────────┐
│  数据平面       │         │  数据平面       │         │   数据平面        │
│  CellApp #1..N │◄───────►│  BaseApp #1..N │◄───────►│   DBApp Alpha    │
│  (空间实体)     │backup   │  (玩家代理)     │persist  │   DBApp Backup   │
│                │Cell→Base│  + ServiceApp  │ entity  └──────────────────┘
└────────────────┘         └───────┬────────┘
        │                          │
        │ sendToClient             │ proxyClient / 转发到客户端
        ▼                          ▼
                  ┌────────────────────────┐
                  │     LoginApp #1..N     │   ← 客户端首先连接这里
                  │     (认证 + 选服)       │
                  └────────────┬───────────┘
                               │ baseAppLogin
                               ▼
                       ┌──────────────────┐
                       │      Client      │   ← Windows 客户端进程
                       │  (App/Module)    │
                       └──────────────────┘

        辅助进程(由 bwmachined 拉起):
        ┌────────────────┐   ┌────────────────┐
        │   Reviver #1..N │   │  bwmachined    │
        │  (故障恢复,    │   │  (每台机器一个)│
        │   单次复活自杀) │   │                │
        └────────────────┘   └────────────────┘
```

图例解读:

- **bwmachined** 是集群的"基础",每台物理机/虚机一个。所有其它进程都是它的子进程(通过 `fork+exec` 启动)。bwmachined 之间通过 UDP 广播互通,形成集群。
- **控制平面**(CellAppMgr / BaseAppMgr / DBAppMgr)是单例进程,负责调度。它们之间互相通信,但**不持有任何游戏实体**。
- **数据平面**(CellApp / BaseApp / DBApp)是多实例进程,持有真实游戏数据。它们向对应的 Mgr 注册,并接受调度。
- **LoginApp** 是接入层,客户端首先连接 LoginApp 做认证,LoginApp 把客户端引导到合适的 BaseApp。
- **Reviver** 是容错辅助进程,监听 birth/death,复活时启动一个替代进程。

> **进程总数典型例子**:一台开发机可能跑 1 个 bwmachined + 1 个 CellAppMgr + 1 个 BaseAppMgr + 1 个 DBAppMgr + 1 个 DBApp + 2 个 CellApp + 2 个 BaseApp + 1 个 LoginApp + 1 个 Reviver = 11 个进程。生产环境可能扩展到几十上百个 CellApp / BaseApp。

### 1.4.2 服务器统一启动框架

所有服务端进程(除 bwmachined)都使用同一套基类骨架:

```
ServerApp  (lib/server/server_app.cpp)         网络/事件/信号/时间/Updatables
   ├─ ScriptApp                                 Python脚本支持
   │    └─ EntityApp                            CellApp/BaseApp 共用基类
   └─ ManagerApp                                CellAppMgr/BaseAppMgr 共用基类(几乎空壳)
```

具体子类(CellApp、BaseApp、ServiceApp、CellAppMgr、BaseAppMgr、DBApp、DBAppMgr、LoginApp、Reviver…)通过 `SERVER_APP_HEADER` 宏提供 `appName()` 与 `configPath()` 静态方法。

每个进程的 `main.cpp` 极简,通过 `BIGWORLD_MAIN` 宏 + `bwMainT<T>` 模板:

```cpp
// 例如 server/cellapp/main.cpp:8-11
int BIGWORLD_MAIN( int argc, char * argv[] ) {
    return bwMainT< CellApp >( argc, argv );
}
```

`BIGWORLD_MAIN` 宏展开后顺序执行:
1. `BW_SYSTEMSTAGE_MAIN()` 设置系统阶段标识
2. `BWResource::init(argc, argv)` 初始化资源管理器(查找 respaths)
3. `BWConfig::init(argc, argv)` 加载并解析 `bw.xml` 配置链
4. `bwParseCommandLine(argc, argv)` 处理 `-machined` 之类通用命令行参数
5. 调用用户实现的 `bwMain(argc, argv)`,即 `bwMainT< CellApp >(argc, argv)`

`ServerApp::runApp` 定义统一生命周期:`init()` → `run()` → `fini()`,其中 `run()` 是主循环 `mainDispatcher_.processUntilBreak()`。

每个 tick 由 `ServerApp::advanceTime` 驱动:

```
onTickPeriod → onEndOfTick → ++time_ → onStartOfTick → callUpdatables → onTickProcessingComplete
```

- `onTickPeriod`:卡顿告警/hitch 检测
- `onEndOfTick`:tick 收尾(时间还没+1)
- `++time_`:游戏时间+1
- `onStartOfTick`:tick 开始(时间已+1)
- `callUpdatables`:按 level 调用所有 `Updatable::update()`
- `onTickProcessingComplete`:EntityApp 在此调用 `callTimers()` 处理 Python 脚本定时器

> 详见第 7 章。

### 1.4.3 客户端架构

客户端是单进程,位于 `programming/bigworld/client/`,但其内部依然分得很细:

```
                  ┌────────────────────────────┐
                  │       App / Module         │  ← 顶层应用框架
                  │  (lib/appmgr/)            │     Module 切换、状态机
                  └────────────┬───────────────┘
                               │
        ┌──────────────────────┼──────────────────────┐
        ▼                      ▼                      ▼
┌────────────────┐    ┌────────────────┐    ┌──────────────────┐
│   Moo 渲染     │    │  Chunk 系统    │    │  Entity /        │
│  (lib/moo/)    │    │  (lib/chunk/)  │    │  PyEntity        │
│  DX11 后端     │    │  分块流式加载  │    │  客户端实体       │
└────────────────┘    └────────────────┘    └──────────────────┘
        │                      │                      │
        ▼                      ▼                      ▼
┌────────────────┐    ┌────────────────┐    ┌──────────────────┐
│   Model/        │    │  Camera/Input  │    │  Connection      │
│   Particle/     │    │  (lib/camera/) │    │  (lib/connection)│
│   Duplo         │    │                │    │  ←→ BaseApp       │
└────────────────┘    └────────────────┘    └──────────────────┘
```

- **App/Module 框架**(`lib/appmgr/app.hpp`):游戏被组织为多个 Module(如登录界面、世界、角色编辑器等),通过 `App` 类驱动主循环;
- **Moo**(`lib/moo/`,意为 "Middleware Object Oriented"):BigWorld 自研的 DirectX 11 渲染抽象层,提供 Visual/Material/Light/Camera/Shader 等概念;
- **Chunk 系统**(`lib/chunk/`):空间被切成方块(Chunk),客户端按玩家位置**流式加载/卸载**周围 Chunk,实现"无缝大世界";
- **Connection**(`lib/connection/`):客户端与 BaseApp 之间的网络层,接收实体属性更新、AOI 实体增删;
- **Duplo**(`lib/duplo/`):角色与"_motor_系统",处理角色动画、运动、Fashion 装扮;
- **Model**(`lib/model/`):模型与节点树,带 Tint(染料)、Fashion(时尚)等换装机制;
- **Camera/Input**(`lib/camera/`、`lib/input/`):摄像机系统与输入系统,包含 IME 中文输入支持。

客户端主循环与服务器不同——服务器是固定 10Hz tick,客户端是 60Hz 渲染循环 + 网络事件驱动。

> 详见第 13、14 章。

### 1.4.4 工具链

BigWorld 的资源管线非常丰富,涉及美术(DCC)、关卡设计(WorldEditor)、运行时(JIT 编译)、导航(navgen)等多类工具。本节给出全景,后续第 15-17 章会专门讲解。

| 工具 | 路径 | 作用 |
|------|------|------|
| **asset_pipeline** | `tools/asset_pipeline/` | 资源管线总框架,把原始美术资源转换成运行时可加载的格式 |
| **assetprocessor** | `tools/asset_pipeline/assetprocessor/` | 后台资源处理器,监听文件变化触发编译 |
| **batch_compiler** | `tools/asset_pipeline/batch_compiler/` | 批量编译入口 |
| **jit_compiler** | `tools/asset_pipeline/jit_compiler/` | 运行时 JIT 编译,客户端启动时按需编译资源 |
| **res_packer** | `tools/asset_pipeline/res_packer/` | 资源打包,生成 zip 包用于分发 |
| **worldeditor** | `tools/worldeditor/` | 关卡编辑器,放置实体、Chunk 项、地形 |
| **modeleditor** | `tools/modeleditor/` | 模型预览与编辑 |
| **particle_editor** | `tools/particle_editor/` | 粒子特效编辑 |
| **bwlauncher** | `tools/bwlauncher/` | 启动器,带 GUI 选择服务器/客户端 |
| **navgen** | `tools/navgen/` | 导航网格生成,服务端寻路用 |
| **exporter_common / visualexporter** | `tools/exporter_common/`、`tools/visualexporter/` | DCC(Maya/3ds Max)导出器公共部分 |
| **resourcechecker** | `tools/resourcechecker/` | 资源合法性检查 |
| **plugin_system** | `tools/plugin_system/` | 编辑器插件系统 |
| **process_defs** | `tools/process_defs/` | 进程定义(对应 bw.xml) |
| **editor_shared** | `tools/editor_shared/` | 编辑器公共代码 |
| **common** | `tools/common/` | 工具公共代码 |

> 这套工具链不是孤立的:asset_pipeline 在编辑期编译资源,JIT_compiler 在运行期编译客户端尚未编译的资源,bwlauncher 启动整套服务端进程组。详见第 15-17 章。

### 1.4.5 典型部署架构图

下面是一个**典型的开发环境部署**示意,展示各进程在物理机上的分布:

```
┌─────────────────────────────────────────────────────────────────┐
│         开发机(Windows 10,主 IDE 与客户端)                  │
│                                                                 │
│   ┌──────────────────┐   ┌──────────────────┐                    │
│   │  Visual Studio   │   │  Client.exe      │ ← 客户端进程       │
│   │  (编译工具链)    │   │  App/Module      │                    │
│   └──────────────────┘   └────────┬─────────┘                    │
│                                   │ UDP                          │
│                                   ▼                              │
└───────────────────────────────────────────────────────────────────┘
                                    │
            ┌───────────────────────┼──────────────────┐
            │                       │                   │
┌───────────────────────┐  ┌──────────────────────┐  ┌──────────────────────┐
│  Vagrant VM (CentOS 7)│  │  Docker Container    │  │  远程生产集群         │
│                       │  │  (CentOS 7)         │  │                      │
│  bwmachined           │  │  bwmachined          │  │  多机 bwmachined     │
│  ├ CellAppMgr         │  │  ├ CellAppMgr        │  │  互联(buddy 环)     │
│  ├ BaseAppMgr         │  │  ├ BaseAppMgr        │  │  ├ 多个 CellApp      │
│  ├ DBAppMgr           │  │  ├ DBAppMgr          │  │  ├ 多个 BaseApp      │
│  ├ DBApp              │  │  ├ DBApp             │  │  ├ 多个 LoginApp     │
│  ├ CellApp x 2        │  │  ├ LoginApp          │  │  └ 多个 DBApp        │
│  ├ BaseApp x 2        │  │  └ Reviver           │  │                      │
│  └ Reviver            │  │                      │  │                      │
└───────────────────────┘  └──────────────────────┘  └──────────────────────┘
```

开发期一般用 Vagrant 或 Docker 跑全套服务端,客户端在 Windows 主机上直接跑;生产环境会把进程按负载分散到多台物理机,由各机器上的 bwmachined 互联组成集群。

### 1.4.6 一次客户端登录的完整流程

为了让你直观感受各进程如何协作,下面是一次客户端登录的完整时序:

```
Client                LoginApp           BaseAppMgr        BaseApp           CellApp
  │                     │                   │                │                 │
  │ 1. login(account)   │                   │                │                 │
  ├────────────────────►│                   │                │                 │
  │                     │ 2. 鉴权(对接外部)│                │                 │
  │                     │ 3. askBaseAppLogin│                │                 │
  │                     ├──────────────────►│                │                 │
  │                     │                   │ 4. 选最空闲BA   │                 │
  │                     │                   │   并预约 BaseID │                 │
  │                     │◄──────────────────┤                │                 │
  │ 5. 返回 BaseApp addr│                   │                │                 │
  │◄────────────────────┤                   │                │                 │
  │                     │                   │                │                 │
  │ 6. connect BaseApp  │                   │                │                 │
  ├─────────────────────────────────────────────────────────►│                 │
  │                     │                   │                │ 7. createEntity │
  │                     │                   │                │   on CellApp    │
  │                     │                   │                ├────────────────►│
  │                     │                   │                │ 8. Real 实体诞生│
  │                     │                   │                │ 9. base→client  │
  │                     │                   │                │   发送 AOI 实体 │
  │ 10. 收到实体创建/属性                  │                │                 │
  │◄─────────────────────────────────────────────────────────┤                 │
```

整个流程涉及 5 类进程协同:LoginApp 鉴权、BaseAppMgr 调度、BaseApp 代理、CellApp 实体模拟、Client 表现。

---

## 1.5 进程职责速览

本节只做简介,后续第 8-12 章会逐个深入。下表是 BigWorld 服务端 9 类进程的"一张图记忆":

| 进程 | 数量 | 主要职责 | 控制平面/数据平面 |
|------|------|---------|------------------|
| **bwmachined** | 每机 1 个 | 机器守护进程;集群发现、子进程 spawn、birth/death 通告、用户权限切换 | 集群管理 |
| **CellAppMgr** | 单例 | CellApp 生命周期、Space/Cell BSP 划分、两层负载均衡、游戏时间权威(TimeKeeper) | 控制平面 |
| **CellApp** | 多实例 | 持有 Cell 分区;Real/Ghost 实体模拟;AOI/Witness;玩家移动、技能、AI 等 | 数据平面 |
| **BaseAppMgr** | 单例 | BaseApp 生命周期、Base 负载均衡、Base 主备切换、登录分流 | 控制平面 |
| **BaseApp** | 多实例 | 玩家代理;Real Base 实体持久化代理;Mailbox 路由;客户端连接代理 | 数据平面 |
| **ServiceApp** | 多实例 | 实为 BaseApp 的 `isServiceApp` 模式,跑无空间位置的服务型实体(公会、聊天、匹配等) | 数据平面 |
| **DBAppMgr** | 单例 | DBApp 生命周期、DBApp Alpha/Backup 主备 | 控制平面 |
| **DBApp** | 多实例 | 实体持久化到 MySQL/MongoDB;批量 ID 分配(IDClient) | 数据平面 |
| **LoginApp** | 多实例 | 客户端认证、选服、把客户端引导到合适的 BaseApp | 接入层 |
| **Reviver** | 多实例 | 监听进程 birth/death;某进程意外死亡时启动一个替代进程并通知相关 Mgr 恢复(单次复活后自杀) | 容错辅助 |

### 1.5.1 bwmachined(机器守护进程)

每台物理机/虚机一个,是其它所有服务端进程的"父进程":
- 启动后通过 `daemon(0,0)` 守护化,绑定 UDP 端口 `PORT_MACHINED`(代码常量在 `lib/network/`);
- 接收 `CREATE_MESSAGE` 调用 `startProcess()`,**fork + exec** 启动子进程;使用状态管道(`pipe` + `FD_CLOEXEC`)异步检测 exec 是否成功;
- 维护 `procs_` 进程表,周期性读 `/proc/<pid>/stat` 检查存活;
- 通过 `ANNOUNCE_BIRTH`/`ANNOUNCE_DEATH` UDP 广播通告集群;
- 自身状态可序列化到 `/var/run/bwmachined.state`,重启后恢复;
- 启动时三个 UDP Endpoint:`ep_`(主)、`epLocal_`(127.0.0.1)、`epBroadcast_`(255.255.255.255);
- 集群 buddy 环形拓扑:每台机器选 IP 地址比自身大且最小的机器作为后继;
- 周期性 `FloodReplyHandler` 探测集群成员变化;
- 子进程权限切换:先 `setgid` 再 `setuid` 降权到目标用户。

> 入口:`server/tools/bwmachined/main.cpp`,使用 `BIGWORLD_MAIN_NO_RESMGR` 宏(不依赖资源管理器)。详见第 8 章。

### 1.5.2 CellApp / CellAppMgr(空间计算)

**CellApp**(空间实体模拟进程)是 BigWorld 最有特色的部分:
- 持有若干 **Cell**(Space 的矩形分区);
- 每个 Cell 上有 **Real 实体**(真实状态)和 **Ghost 实体**(Real 的属性快照,用于跨边界观察);
- 玩家观察世界的代理叫 **Witness**,基于 **AOI**(Area of Interest,兴趣区域)裁剪需要广播给客户端的实体;
- 每个 tick 末调用 `tickBackup()` 把 Real 实体状态轮转备份到 BaseApp;
- 通过 `CellAppChannels` 与其它 CellApp 通信(ghost 同步、跨 cell 调用);
- 启动时向 CellAppMgr 发 `add`,等待 `finishInit` 回复拿到 `CellAppID`、`BaseApp` 地址、`DBApp Alpha` 地址等关键信息。

**CellAppMgr** 不持有任何实体,只做调度:
- 接收 CellApp 的 `add` 注册,分配 `CellAppID`;
- 通过 BSP 树管理 Space/Cell 边界;
- 启动两个定时器:`loadBalanceTimer_`(1s,空间内 Cell 边界重分)、`metaLoadBalanceTimer_`(3s,跨 CellApp 组迁移);
- 启动 `gameTimer_`(10Hz)推进游戏时间;
- 通过 `TimeKeeper` 同步集群时钟;
- 维护就绪状态机:`READY_CELL_APP | READY_BASE_APP_MGR | READY_BASE_APP`,三者齐备才开始业务;
- 把 Space 状态持久化到 DB(`writeSpacesToDB`)。

> 详见第 9 章。

### 1.5.3 BaseApp / BaseAppMgr(玩家代理)

**BaseApp** 是玩家"在服务端的影子":
- 每个 Real Base 实体对应一个客户端连接;
- 接收客户端输入,转发给 CellApp(实体的 Real 部分);
- 接收 CellApp 的实体属性更新,转发给客户端;
- 维护 Real Base 实体的"持久化代理"——周期性把 Base 实体状态写到 DBApp;
- 接收来自 CellApp 的 backup,在 CellApp 崩溃时把 backup 升级为 Real;
- 也支持 `isServiceApp` 模式成为 ServiceApp,跑无空间位置的服务型实体。

**BaseAppMgr** 调度 BaseApp:
- 通过 `ManagedAppSubSet` 模式管理 BaseApp 集合;
- 维护 Base 负载信息,登录时选择最空闲的 BaseApp;
- 处理 BaseApp 主备切换;
- 通知 CellAppMgr BaseApp 的 birth/death(`handleBaseAppBirth` / `informBaseAppDeath`)。

> 详见第 10 章。

### 1.5.4 DBApp / DBAppMgr(数据持久化)

**DBApp** 提供实体的持久化服务:
- 双存储引擎:MySQL(结构化实体表)、MongoDB(二级数据库,存储非结构化数据);
- 批量 ID 分配:`IDClient` 一次向 DBApp Alpha 申请一段 ID 段,本地分发,减少跨进程调用;
- 周期性快照实体到数据库;
- 第一个 DBApp 为 Alpha,其它为 Backup。

**DBAppMgr** 管理 DBApp:
- 启动时选举第一个 DBApp 为 Alpha;
- Alpha 挂掉时让 Backup 升级;
- 维护 entityID 序列。

> 详见第 11 章。

### 1.5.5 LoginApp(登录)

**LoginApp** 是客户端接触 BigWorld 服务器的第一个进程:
- 接收客户端登录请求,做认证(对接外部认证后端);
- 询问 BaseAppMgr 选一个 BaseApp;
- 把选中的 BaseApp 地址返回给客户端,客户端再连到 BaseApp;
- 自己**不持有任何实体**,纯转发;
- 可多实例并行,通过 DNS 轮询或负载均衡器分流。

> 详见第 12 章。

### 1.5.6 Reviver(故障恢复)

**Reviver** 是 BigWorld 容错机制的关键一环:
- 启动时向 bwmachined 注册为 birth/death listener;
- 监听到某进程死亡时,启动一个替代进程(自身 fork 或请求 bwmachined spawn);
- 替代进程就绪后,通知对应的 Mgr(CellAppMgr / BaseAppMgr / DBAppMgr)进行状态恢复;
- **单次复活后自杀**——每次只处理一个死亡事件,完成后退出,再由 bwmachined 拉起一个新的 Reviver;
- 这样设计避免了 Reviver 自身成为单点。

> 详见第 12 章。

---

## 1.6 特色实现方案预告

BigWorld 在工程上有大量值得学习的设计,本教程后续章节会逐一深入。下面是十大特色方案的预告,作为"教程地图"帮你建立全局认知。

### 1.6.1 Cell / Ghost 跨进程实体(第 9、18 章)

**问题**:玩家从 CellApp A 走到 CellApp B 的区域,他的实体状态如何不中断?

**方案**:把一个实体分成两部分:
- **Real 实体**:持真实状态,只在一个 CellApp 上;
- **Ghost 实体**:Real 的属性快照,在被观察的其它 CellApp 上有副本;
- 当玩家跨边界时,Real 在源 CellApp 上 offload,在目标 CellApp 上变成 Real;Ghost 随之在两边创建/销毁;
- Ghost 通过 `pReal_` 指针引用真正的 Real(同进程或跨进程),跨进程时由 CellAppChannels 维护通信通道;
- 这种设计让"无缝大世界"成为可能,玩家根本感觉不到自己穿越了进程边界。

> 这是 BigWorld 之所以能做"无缝大世界"的根本。代码入口:`server/cellapp/entity.hpp`、`server/cellapp/real_entity.hpp`、`server/cellapp/ghost.cpp`(实为 Entity 的 ghost 模式)。

### 1.6.2 Mailbox 7 种类型(第 18 章)

BigWorld 的实体引用叫 **Mailbox**(邮箱),它有 7 种不同类型,对应不同的通信路径。每种类型决定了消息从哪里发出、经过哪些中间进程、最终到达哪个进程的实体上:

| 类型 | 含义 |
|------|------|
| CellEntityMailbox | 发给 CellApp 上的 Real/Ghost 实体 |
| BaseEntityMailbox | 发给 BaseApp 上的 Real Base 实体 |
| ClientEntityMailbox | 经 BaseApp 转发给客户端 |
| BaseEntityWithCellMailbox | Base 实体 + 它对应的 Cell 邮箱 |
| ClientEntityWithBaseMailbox | 客户端 + 它对应的 Base 邮箱 |
| CellEntityWithBaseMailbox | Cell 实体 + 它对应的 Base 邮箱(backup) |
| 其它 | 详见 .def 解析与 `lib/entitydef/` |

Mailbox 的"打包"由实体定义(.def)的 CLIENT/SERVER/BASE 方法分治决定,序列化形式非常紧凑——只编必要的"哪个进程+哪个实体+哪个方法",不传整个对象。

### 1.6.3 AOI / Witness 兴趣区域(第 9、18 章)

**Witness** 是玩家的"眼睛",挂在 Real 实体上,管理一个 **AOI**(Area of Interest)区域:
- 在 AOI 范围内的实体,服务端会自动给客户端发送"创建实体"消息;
- 出 AOI 范围则发送"销毁实体"消息;
- AOI 内实体的属性变化(volatile 属性,如位置、朝向)按不同频率上报——位置每 tick、朝向每几 tick、其它属性按需;
- 大幅降低网络与服务端计算压力;
- 客户端"看到的世界"是 AOI 内的实体集合,而非整个 Space。

这套机制让单台客户端不需要"看到"整个世界,只看到周围一公里,使能同时承载数万客户端成为可能。

### 1.6.4 两层负载均衡(第 19 章)

如 1.2.1 节所述,CellAppMgr 同时跑两个定时器:
- **loadBalanceTimer_**(1s):在 Space 内通过 BSP 调整 Cell 边界矩形;
- **metaLoadBalanceTimer_**(3s):在 CellAppGroup 之间整体迁移 Cell;

两层一起实现了"细粒度平滑迁移 + 粗粒度整组调度"的混合策略。负载算法使用 EWMA 平滑瞬时抖动,既避免抖动引起的频繁迁移,又能及时响应负载变化。

### 1.6.5 主备切换(第 19 章)

- **DBApp Alpha/Backup**:DBAppMgr 启动时第一个 DBApp 为 Alpha,挂掉时 Backup 升级;
- **BaseApp 主备**:BaseAppMgr 维护 BaseApp 主备关系,主挂掉时备用接管其客户端;
- **Mgr 进程**:Mgr 是单例,但 Reviver 监听其死亡,重生后会被重新识别;
- **bwmachined**:每台机器一个,自身挂掉时其它机器的 bwmachined 通过 flood 探测发现,通告 ANNOUNCE_DEATH,涉及该机器的进程被相关 Mgr 重新调度。

### 1.6.6 bwmachined 进程管理(第 8 章)

bwmachined 是 BigWorld 的"systemd":
- fork+exec+状态管道设计,异步检测 exec 失败;
- PID 复用防护(starttime 校验);
- 集群 buddy 环形拓扑;
- 用户权限切换(setgid/setuid 降权);
- 状态序列化到 `/var/run/bwmachined.state`;
- UserMap:每用户读 `~/.bwmachined.conf` 配置,做细粒度权限控制;
- 信号处理:SIGCHLD 用 `waitpid(WNOHANG)` 非阻塞回收僵尸;SIGTERM 触发 `save()` 后退出。

学习这个进程对理解 Linux 守护进程、信号、fork/exec 都很有帮助。

### 1.6.7 资源管线 JIT 编译(第 15 章)

**JIT(Just-In-Time)编译**是 BigWorld 资源管线的特色:
- 美术资源(DCC 导出的 .mfx、.visual、.chunk 等)可以在编辑期(asset_pipeline)编译;
- 但客户端启动时,**未编译的资源会由 jit_compiler 在运行时按需编译**;
- 这使得开发期"改资源 → 立刻看效果"成为可能,而生产环境则把已编译的资源打包分发;
- 资源管线由 batch_compiler(批量)、assetprocessor(后台监听)、jit_compiler(运行时)三种角色协作。

### 1.6.8 Chunk 流式加载(第 14 章)

客户端空间被切成方块叫 **Chunk**,每个 Chunk 是一个独立加载单元:
- 客户端按玩家位置预加载周围 Chunk;
- 出范围的 Chunk 自动卸载;
- Chunk 内的实体、地形、模型、粒子、灯光等统一在加载时绑定;
- 支持 VLO(Very Large Object,跨 Chunk 大物体)与 LOD(Level of Detail);
- 加载是异步的,通过 `fileIOTaskManager` 后台线程进行;
- 服务器 CellApp 也有对应的 Space 几何加载逻辑(`loadingTimer_` 周期推进)。

这是实现"无缝大世界"客户端侧的基石。

### 1.6.9 .def 实体定义(第 6 章)

**.def**(Entity Definition)是 BigWorld 的实体描述语言,XML 风格:

```xml
<EntityDef>
  <Properties>
    <health>
      <Type> INT </Type>
      <Flags> BASE </Flags>
    </health>
    <position>
      <Type> POSITION </Type>
      <Flags> CELL </Flags>
    </position>
  </Properties>
  <ClientMethods>
    <onHit>
      <Arg> INT </Arg>
    </onHit>
  </ClientMethods>
  <CellMethods>
    <jump>
      <Arg> VECTOR3 </Arg>
    </jump>
  </CellMethods>
  <BaseMethods>
    <onLogin/>
  </BaseMethods>
</EntityDef>
```

它声明了实体的属性、方法,以及这些成员属于 CLIENT/CELL/BASE 哪一域。BigWorld 工具会据此生成 C++ stub 与 Python 绑定,实现跨进程方法调用的强类型安全。`Flags` 还可以声明属性是否持久化、是否广播给客户端、是否 volatile 等。

### 1.6.10 Python 脚本深度集成(第 6 章)

BigWorld 不是简单"嵌入式 Python",而是把 Python 作为**第一公民**:
- 每个 ServerApp 都有 `ScriptApp` 基类,启动时初始化 Python 解释器;
- 每个 Entity 类都对应一个 Python 类,实体的方法可以是 Python 函数;
- `BigWorld` 模块在 C++ 中注册,Python 脚本通过 `BigWorld.player()`、`BigWorld.entities` 等访问引擎;
- 配置链 `bw.xml` 也会被 Python 读取;
- 还有一套 **Personality(人格)脚本**,定义游戏的整体行为风格(`initPersonality()`)。
- 脚本事件机制:onAppReady、onCellAppReady、onSpaceGeometryLoaded 等 15+ 个脚本事件,在 C++ 关键时刻触发 Python 回调;
- SharedData:跨进程共享数据,Python 脚本可读写;
- `py_server`、`py_entity`、`py_filter` 等大量 Python 绑定类。

> 这种"C++ 性能骨架 + Python 业务血肉"的设计是 BigWorld 区别于很多现代引擎的特点。

---

## 1.7 本教程的学习路径建议

本教程共 20 章,分为五大部分。下面给出建议的阅读路径。

### 1.7.1 各部分逻辑关系

| 部分 | 章节 | 核心内容 | 前置依赖 |
|------|------|---------|---------|
| **第一部分 入门与概览** | 1、2、7 | 引擎全貌、项目结构、服务器集群总览 | 无 |
| **第二部分 核心基础库** | 3-6 | cstdmf/math、resmgr、network、pyscript | 第 1 章 |
| **第三部分 服务器架构** | 7-12 | 集群架构、bwmachined、CellApp、BaseApp、DBApp、LoginApp/Reviver | 第二部分 |
| **第四部分 客户端与工具** | 13-17 | App/Moo、Chunk、AssetPipeline、WorldEditor、DCC/navgen | 第二部分 |
| **第五部分 高级主题** | 18-20 | Mailbox/AOI、负载均衡与容错、性能优化与特色总结 | 第三部分 |

### 1.7.2 推荐阅读顺序

**新手快速入门路径**(约一周):
1. 第 1 章(本章)—— 建立整体认知
2. 第 2 章 —— 项目结构与构建系统
3. 第 7 章 —— 服务器集群架构总览
4. 第 8 章 —— bwmachined 进程管理(理解所有进程怎么被拉起)
5. 第 13 章 —— 客户端 App/Moo 框架

**深入服务器实现路径**(约两周):
1. 第 5 章 —— network 通信层(理解 Bundle/Channel)
2. 第 6 章 —— pyscript 与 .def(理解脚本与实体定义)
3. 第 9 章 —— CellApp 与空间管理(Ghost/AOI 核心)
4. 第 10 章 —— BaseApp 与玩家代理
5. 第 11 章 —— DBApp 与持久化
6. 第 12 章 —— LoginApp 与 Reviver

**深入客户端与工具路径**(约一周):
1. 第 13 章 —— App/Moo
2. 第 14 章 —— Chunk 加载
3. 第 15 章 —— AssetPipeline
4. 第 16 章 —— WorldEditor
5. 第 17 章 —— DCC 导出器与 navgen

**高级专题路径**:
1. 第 18 章 —— Mailbox 7 种类型与 AOI 深入
2. 第 19 章 —— 负载均衡与故障恢复
3. 第 20 章 —— 性能优化与十大特色总结

### 1.7.3 按主题检索

| 你想了解 | 直接看 |
|---------|--------|
| 整体架构 | 第 1、7、13 章 |
| 网络通信 | 第 5、8、18 章 |
| 服务器实现细节 | 第 9-12、19 章 |
| 工具链 | 第 15-17 章 |
| 特色方案 | 第 6、9、18、20 章 |
| 性能调优 | 第 20 章 |
| 进程启动流程 | 第 7、8 章 |
| 容错机制 | 第 12、19 章 |
| 资源管线 | 第 4、15 章 |
| Python 集成 | 第 6 章 |

### 1.7.4 配套分析文档

本教程基于已有的 29 份 BigWorld 分析文档精炼整合而成。如果你想跳过教程直接看更详细的实现分析,可参考:

- `docs/BigWorld启动流程分析.md` —— 全部 9 类进程启动流程
- `docs/BigWorld空间应用CellApp实现分析.md` —— CellApp 与 CellAppMgr 深度分析
- `docs/BigWorld基础应用BaseApp实现分析.md` —— BaseApp 与 BaseAppMgr
- `docs/BigWorld数据存储实现分析.md` —— DBApp 与持久化
- `docs/BigWorld登录应用LoginApp实现分析.md` —— LoginApp 与认证
- `docs/BigWorld恢复进程Reviver实现分析.md` —— Reviver 与容错
- `docs/tools/` 目录下 23 个工具分析文档

### 1.7.5 阅读源码的技巧

BigWorld 代码量巨大,直接阅读容易迷失。建议:

1. **先看入口**:每个进程的 `main.cpp` 极简,通常只有一行 `bwMainT<T>`。从这里开始追。
2. **再看构造与 init**:构造函数往往只做成员初始化,真正的工作在 `init()` 里。`init()` 末尾通常有"向 Mgr 注册"的代码。
3. **追 tick 主循环**:`handleTimeout` 或 `advanceTime` 是每 tick 的入口,从这里能看清一个 tick 内做了什么。
4. **借助 watcher**:`BW_REGISTER_WATCHER` 暴露的运行时变量是观察进程内部状态的最佳窗口。
5. **借助 PDF 白皮书**:*BigWorld Technology Server Whitepaper* 给出了官方设计哲学,有助于理解"为什么这么设计"。
6. **借助配套分析文档**:本教程每章末尾会给出关键文件路径,直接对照分析文档阅读。
7. **运行 fantasydemo**:对照实际运行行为读代码,事半功倍。

---

## 1.8 小结

本章我们建立了对 BigWorld Engine 14.4.1 的整体认知:

1. **历史定位**:由 BigWorld Pty Ltd 开发,2014 年开源,以《坦克世界》《天下3》为代表案例,聚焦 MMOG 强空间、强服务器权威场景。BigWorld Pty Ltd 被 Wargaming 收购后,14.4.1 是 OSE 最终稳定版本。
2. **三大核心特性**:
   - Load-Balancing(两层负载均衡:Space 内 Cell 边界 + 跨 CellAppGroup 迁移)
   - Scalability(进程级水平扩展 + 控制平面/数据平面分离)
   - Fault Tolerance(主备 + Reviver + Backup/Ghost 多重容错)
3. **技术栈**:C++ + Python 2 + CentOS 7,客户端 Windows + DX11,VS 2019-2022 + Vagrant + Docker 工具链;第三方依赖包括 MySQL、MongoDB、SDL、FMOD 等。
4. **架构**:
   - 服务器 9 类进程,分控制平面(Mgr)与数据平面(App);
   - 客户端单进程,App/Module + Moo + Chunk;
   - 工具链丰富(asset_pipeline、WorldEditor、navgen 等);
   - 统一启动框架(ServerApp → ScriptApp → EntityApp / ManagerApp)与统一 tick 周期。
5. **特色方案**:Cell/Ghost 跨进程实体、Mailbox 7 种类型、AOI/Witness、两层负载均衡、主备切换、bwmachined 进程管理、JIT 资源编译、Chunk 流式加载、.def 实体定义、Python 深度集成。
6. **学习路径**:从第 2 章(项目结构)开始,先掌握代码组织,再进入第 3-6 章基础库,然后第 7-12 章服务器,最后第 13-17 章客户端工具与第 18-20 章高级主题。

下一章,我们会深入 `programming/bigworld/` 目录,梳理出每个子目录的职责、CMake 构建系统的整体结构、依赖关系,让你能自己把整个项目编译出来。
