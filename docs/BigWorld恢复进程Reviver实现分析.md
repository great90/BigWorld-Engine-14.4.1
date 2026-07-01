# BigWorld Engine 恢复进程 Reviver 实现深度分析

> 本文档详细分析 BigWorld Engine 14.4.1 中 **Reviver(恢复进程)** 的完整实现,涵盖进程看门狗机制、双死亡检测、birth/death 监听、ping 心跳、ReviverSubject 优先级仲裁、与 bwmachined 的交互、CreateMessage 进程重启、5 个特化 ComponentReviver、配置项体系、消息接口、被监控进程的注册方式、主备切换等所有关键机制。

---

## 目录

- [一、整体架构概览](#一整体架构概览)
- [二、文件结构](#二文件结构)
- [三、Reviver 主类](#三reviver-主类)
- [四、ComponentReviver:组件恢复器](#四componentreviver组件恢复器)
- [五、双死亡检测机制](#五双死亡检测机制)
- [六、ReviverSubject 优先级仲裁](#六reviversubject-优先级仲裁)
- [七、与 bwmachined 的交互](#七与-bwmachined-的交互)
- [八、配置项详解](#八配置项详解)
- [九、消息接口](#九消息接口)
- [十、被监控进程的注册方式](#十被监控进程的注册方式)
- [十一、主备切换 shutDownOnRevive](#十一主备切换-shutdownonrevive)
- [十二、REATTACH 状态处理与优先级重排](#十二reattach-状态处理与优先级重排)
- [十三、设计亮点与注意事项](#十三设计亮点与注意事项)
- [附录 A:关键文件路径速查](#附录-a关键文件路径速查)
- [附录 B:常见误区澄清](#附录-b常见误区澄清)

---

## 一、整体架构概览

BigWorld 服务器集群由多个分工不同的进程组成(CellAppMgr、BaseAppMgr、DBAppMgr、DBApp、LoginApp、CellApp、BaseApp 等)。其中部分关键进程一旦崩溃将导致整个集群不可用,因此需要"看门狗"进程在崩溃后自动拉起新实例。**Reviver** 就是承担这一职责的守护进程。

### 1.1 进程定位

Reviver 是 BigWorld 服务器侧的 **看门狗(watchdog)进程**,职责单一:

- 监控指定的关键服务器进程(CellAppMgr / BaseAppMgr / DBAppMgr / DBApp / LoginApp)
- 在这些进程意外退出时,**通过本机 `bwmachined` 守护进程拉起新实例**(带 `-recover` 启动参数)
- 通过 **birth/death 监听 + ping 心跳** 双重机制判定进程是否死亡,避免误判
- 通过 **ReviverSubject 优先级仲裁** 支持多 Reviver 主备热备
- **不参与任何游戏逻辑**,不持有实体、不维护空间,纯控制平面旁路进程

```
┌──────────────────────────────────────────────────────────────────────┐
│  控制平面 / 旁路                                                       │
│   ┌──────────────────────────────────────────────────┐                │
│   │  Reviver (可多实例,主备)                          │                │
│   │  - 监控 5 类关键进程                              │                │
│   │  - birth/death listener(被动监听)                │                │
│   │  - ping 心跳(主动探测)                           │                │
│   │  - 优先级仲裁(ReviverSubject 端)                │                │
│   │  - 通过 CreateMessage 委托 bwmachined 重启进程   │                │
│   └──────────────────────────────────────────────────┘                │
└──────────────────────────────────────────────────────────────────────┘
        │                                       │
        │ ① 注册 birth/death listener           │ ③ 发送 CreateMessage
        │ ② 周期性 ping                         │ (recover_=1, name=进程名)
        ▼                                       ▼
┌──────────────────┐               ┌────────────────────────────────┐
│   bwmachined     │◄──────────────│  被监控进程                     │
│  (本机守护进程)  │ birth/death   │  CellAppMgr / BaseAppMgr /     │
│  - 进程生死通知  │ 事件广播      │  DBAppMgr / DBApp / LoginApp   │
│  - 接收创建命令  │               │  - 持有 ReviverSubject 单例    │
│  - 实际 fork     │               │  - 处理 reviverPing 并回 YES/NO│
│  - 带 -recover   │               │  - 仲裁哪个 Reviver 是主       │
└──────────────────┘               └────────────────────────────────┘
        │
        │ fork + exec(带 -recover 参数)
        ▼
┌──────────────────────────────────────────────────────────────────────┐
│  新进程实例(替换崩溃实例)                                            │
└──────────────────────────────────────────────────────────────────────┘
```

### 1.2 与其他进程的关系

```
                         ┌─────────────────┐
                         │   bwmachined    │  本机守护进程
                         │ (MachineGuard)  │  实际进程管理
                         └────────┬────────┘
                                  │  birth/death 广播
            ┌─────────────────────┼─────────────────────┐
            ▼                     ▼                     ▼
   ┌────────────────┐    ┌────────────────┐    ┌────────────────┐
   │    Reviver     │    │  其他监听者    │    │  其他监听者    │
   │ (主,优先级 1)  │    │ (BaseAppMgr 等)│    │ (DBAppMgr 等)  │
   └────────┬───────┘    └────────────────┘    └────────────────┘
            │
            │ ping(携带 priority)
            ▼
   ┌────────────────────────────────────────────────────────────┐
   │              ReviverSubject (每个被监控进程内)              │
   │  - 仲裁:priority 更小者为主,或当前主超时则切换           │
   │  - 回复 REVIVER_PING_YES / REVIVER_PING_NO                 │
   └────────────────────────────────────────────────────────────┘
            │
            │ 一旦判定死亡
            ▼
   ┌────────────────────────────────────────────────────────────┐
   │  Reviver::revive()                                         │
   │  - 构造 CreateMessage(uid, recover_=1, name, config)       │
   │  - sendAndRecv 到 127.0.0.1                                │
   │  - bwmachined 实际 fork 新进程(带 -recover)              │
   └────────────────────────────────────────────────────────────┘
```

### 1.3 核心抽象

| 概念 | 定义 | 所在文件 |
|------|------|---------|
| **Reviver** | 看门狗进程主类,单例 | `server/reviver/reviver.hpp` |
| **ComponentReviver** | 单个被监控组件的恢复器基类 | `server/reviver/component_reviver.hpp` |
| **CellAppMgrReviver** 等 | 5 个特化的 ComponentReviver | `server/reviver/component_reviver.cpp` |
| **ReviverSubject** | 被监控进程侧的"被恢复主体",处理 ping | `lib/server/reviver_subject.hpp` |
| **ReviverPriority** | uint8 类型的优先级,值小者优先 | `lib/server/reviver_common.hpp` |
| **ReviverConfig** | Reviver 的配置类,继承 ServerAppConfig | `server/reviver/reviver_config.hpp` |
| **ReviverInterface** | Reviver 暴露的 birth/death 消息接口 | `server/reviver/reviver_interface.hpp` |
| **CreateMessage** | 发往 bwmachined 的进程创建命令 | `lib/network/machine_guard.hpp` |
| **TagsMessage** | 查询/设置 bwmachined 的 tags | `lib/network/machine_guard.hpp` |
| **MF_REVIVER_HANDLER** | 声明特化 ComponentReviver 的宏 | `server/reviver/component_reviver.cpp` |

### 1.4 关键设计要点

- **被动 + 主动双重死亡检测**:既监听 bwmachined 的 death 广播,又主动 ping 被监控进程,任一渠道判定死亡都会触发恢复,避免单点漏报。
- **优先级仲裁实现主备**:多个 Reviver 同时运行时,通过 ReviverSubject 端的 priority 仲裁,只有"主 Reviver"能收到 `REVIVER_PING_YES`,从而握住监控权;主 Reviver 故障后,备 Reviver 因 ping 超时被自动接管。
- **委托 bwmachined 实际拉起**:Reviver 自身不 fork 进程,而是发 `CreateMessage` 给本机 `bwmachined`,由后者实际执行 fork+exec,这样 Reviver 不需要 root 权限或复杂的环境继承。
- **`-recover` 启动参数**:被恢复的进程会带 `-recover` 启动,使其进入"恢复模式"(例如 CellAppMgr 会跳过新建 Space 而是从 DB 恢复)。
- **Components tags 过滤**:bwmachined 通过 `Components` tag 声明本机可运行哪些组件,Reviver 启动时查询该 tag 自动启用/禁用对应的 ComponentReviver,实现"按机器能力部署"。

---

## 二、文件结构

Reviver 子系统涉及 3 个目录:`server/reviver/`(进程主体)、`lib/server/`(被监控进程共用的 ReviverSubject)、`lib/network/`(与 bwmachined 通信的 MachineGuard 消息)。

### 2.1 server/reviver/ 目录

| 文件 | 行数 | 职责 |
|------|------|------|
| `server/reviver/main.cpp` | 46 | 进程入口,`BIGWORLD_MAIN` → `bwMainT<Reviver>` |
| `server/reviver/reviver.hpp` | 88 | Reviver 类声明,三重继承 + TagsHandler 内部类 |
| `server/reviver/reviver.cpp` | 499 | Reviver 核心实现(init/run/revive/handleTimeout/queryMachinedSettings) |
| `server/reviver/component_reviver.hpp` | 104 | ComponentReviver 基类声明 |
| `server/reviver/component_reviver.cpp` | 340 | ComponentReviver 实现 + MF_REVIVER_HANDLER 宏 + 5 个特化类 |
| `server/reviver/reviver_config.hpp` | 21 | ReviverConfig 配置类声明(6 个 ServerAppOption) |
| `server/reviver/reviver_config.cpp` | 64 | ReviverConfig 配置项默认值与 postInit 计算 |
| `server/reviver/reviver_interface.hpp` | 48 | ReviverInterface 消息定义(BW_REVIVER_MSGS 宏,10 条消息) |
| `server/reviver/CMakeLists.txt` | - | 构建脚本 |
| `server/reviver/unit_test/` | - | 单元测试 |

### 2.2 lib/server/ 目录(被监控进程共用)

| 文件 | 行数 | 职责 |
|------|------|------|
| `lib/server/reviver_subject.hpp` | 44 | ReviverSubject 单例声明 + MF_REVIVER_PING_MSG 宏 |
| `lib/server/reviver_subject.cpp` | 158 | ReviverSubject 实现(handleMessage 仲裁逻辑) |
| `lib/server/reviver_common.hpp` | 20 | ReviverPriority 类型定义 + 默认常量 + PING_YES/NO |

### 2.3 lib/network/ 目录(相关部分)

| 文件 | 相关内容 | 职责 |
|------|---------|------|
| `lib/network/machine_guard.hpp` | L638-662 CreateMessage | 发往 bwmachined 的进程创建命令 |
| `lib/network/machine_guard.hpp` | TagsMessage | 查询/设置 bwmachined tags |
| `lib/network/machined_utils.hpp` | registerBirthListener/registerDeathListener/findInterface/registerWithMachined | 与 bwmachined 交互的工具函数 |

---

## 三、Reviver 主类

`Reviver` 是看门狗进程的核心类,通过三重继承获得"服务器应用 + 定时器 + 单例"三项能力。

### 3.1 类继承关系

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

类声明中还使用宏 `SERVER_APP_HEADER( Reviver, reviver )` 展开为 ServerApp 框架所需的静态成员与工厂方法,并 `typedef ReviverConfig Config` 将配置类绑定到框架。

### 3.2 关键成员

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

	TimerHandle            timerHandle_;    // REATTACH 定时器
	TimerHandle            tickTimer_;      // 主 tick 定时器

	ComponentRevivers      components_;     // 所有 ComponentReviver 列表

	bool                   shuttingDown_;   // 是否正在关闭
	bool                   isDirty_;        // 输出脏标记,用于日志节流
```

- `components_`:从全局 `g_pComponentRevivers` 拷贝而来的 ComponentReviver 列表(5 个特化类通过 `IntrusiveObject` 自动注册到全局链表)。
- `isDirty_`:当组件附着/脱离状态变化时置 true,REATTACH 定时器据此决定是否打印 summary,避免每个周期都刷屏。

### 3.3 内部类 TagsHandler

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

`TagsHandler` 用于处理 `queryMachinedSettings()` 发出的 `TagsMessage` 异步回复,根据 bwmachined 返回的 `Components` tag 启用/禁用对应的 ComponentReviver。

### 3.4 构造与析构

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

构造非常简单,仅初始化基类与两个 bool 标记。`isDirty_` 初始为 true,保证首次 REATTACH 周期会打印一次 summary。

```cpp
// server/reviver/reviver.cpp  L49-53
Reviver::~Reviver()
{
	timerHandle_.cancel();
	tickTimer_.cancel();
}
```

析构时取消两个定时器,防止回调到已销毁对象。

### 3.5 init() 启动流程(12 步)

`init()` 是 Reviver 启动的核心,完成接口注册、配置查询、组件过滤、定时器安装等工作。整个流程可拆分为 12 个步骤:

```cpp
// server/reviver/reviver.cpp  L59-222
bool Reviver::init( int argc, char * argv[] )
{
	// 步骤 1:调用基类 ServerApp::init
	if (!this->ServerApp::init( argc, argv ))  // L61
	{
		return false;
	}

	// 步骤 2:断言尚未初始化
	MF_ASSERT( components_.empty() );  // L67

	// 步骤 3:打印内部地址
	PROC_IP_INFO_MSG( "Internal address = %s\n", interface_.address().c_str() );  // L69

	// 步骤 4:向 interface 注册本进程的消息处理器
	ReviverInterface::registerWithInterface( interface_ );  // L71

	// 步骤 5:向 bwmachined 注册本 Reviver 接口
	if (ReviverInterface::registerWithMachined( interface_, 0 ) !=  // L73
			Mercury::REASON_SUCCESS)
	{
		NETWORK_WARNING_MSG( "Reviver::init: Unable to register interface\n" );
		return false;
	}

	// 步骤 6:校验全局 ComponentReviver 链表非空
	if (g_pComponentRevivers == NULL)  // L81
	{
		ERROR_MSG( "Reviver::init: No component revivers\n" );
		return false;
	}

	// 步骤 7:拷贝全局 ComponentReviver 到本进程
	components_ = *g_pComponentRevivers;  // L87

	// 步骤 8:查询 bwmachined 的 Components tags
	if (!this->queryMachinedSettings())  // L89
	{
		return false;
	}

	// 步骤 9:注册 watcher
	this->ServerApp::addWatchers( Watcher::rootWatcher() );  // L94
	BW_REGISTER_WATCHER( 0, "reviver", "reviver",
		mainDispatcher_, interface_.address() );  // L96

	// 步骤 10:解析 --add / --del 命令行参数,过滤启用的组件
	for (int i = 1; i < argc - 1; ++i)  // L104
	{
		const bool isAdd = (strcmp( argv[i], "--add" ) == 0);
		const bool isDel = (strcmp( argv[i], "--del" ) == 0);
		// ... 见下文详述
	}

	// 步骤 11:初始化所有启用的 ComponentReviver
	{
		ComponentRevivers::iterator iter = components_.begin();  // L162
		while (iter != endIter)
		{
			if ((*iter)->isEnabled())
			{
				(*iter)->init( mainDispatcher_, interface_ );
			}
			++iter;
		}
	}

	// 步骤 11b:打印启用的组件信息(周期/超时)
	{
		CONFIG_INFO_MSG( "Monitoring the following component types:\n" );  // L177
		// ...
	}

	// 步骤 12:激活启用的 ComponentReviver,赋予递增优先级
	{
		ReviverPriority priority = 0;  // L197
		ComponentRevivers::iterator iter = components_.begin();
		while (iter != endIter)
		{
			if ((*iter)->isEnabled())
			{
				(*iter)->activate( ++priority );  // 优先级从 1 开始递增
			}
			++iter;
		}
	}

	// 步骤 13:安装两个定时器
	timerHandle_ = mainDispatcher_.addTimer(
					int(Config::reattachPeriod() * 1000000),
					this, (void *)TIMEOUT_REATTACH );  // L212

	tickTimer_ = mainDispatcher_.addTimer(
					1000000/Config::updateHertz(),
					this, (void *)TIMEOUT_TICK,
					"TickTimer" );  // L216

	return true;
}
```

#### 3.5.1 步骤详解

| 步骤 | 行号 | 动作 | 失败后果 |
|------|------|------|---------|
| 1 | L61 | `ServerApp::init` 初始化基类 | 返回 false 退出 |
| 2 | L67 | 断言 `components_` 为空(防止重复 init) | 断言失败 |
| 3 | L69 | 打印内部接口地址 | 仅日志 |
| 4 | L71 | `ReviverInterface::registerWithInterface` 注册本进程消息 | - |
| 5 | L73 | `registerWithMachined` 向 bwmachined 登记 Reviver 存在 | 返回 false 退出 |
| 6 | L81 | 校验全局 `g_pComponentRevivers` 非空 | 返回 false 退出 |
| 7 | L87 | 拷贝全局 ComponentReviver 链表到 `components_` | - |
| 8 | L89 | `queryMachinedSettings` 查询 Components tags | 返回 false 退出 |
| 9 | L94-97 | 注册 watcher(BW_REGISTER_WATCHER) | - |
| 10 | L104-158 | 解析 `--add` / `--del` 命令行,过滤启用组件 | 无效参数返回 false |
| 11 | L162-173 | 对启用组件调用 `ComponentReviver::init` | - |
| 11b | L177-193 | 打印监控组件类型与周期/超时 | 仅日志 |
| 12 | L197-210 | 对启用组件调用 `activate(++priority)`,赋予递增优先级 | - |
| 13 | L212-219 | 安装 REATTACH 与 TICK 两个定时器 | - |

#### 3.5.2 --add / --del 命令行过滤机制

```cpp
// server/reviver/reviver.cpp  L104-158
for (int i = 1; i < argc - 1; ++i)
{
	const bool isAdd = (strcmp( argv[i], "--add" ) == 0);
	const bool isDel = (strcmp( argv[i], "--del" ) == 0);

	if (isAdd || isDel)
	{
		++i;

		// 首次遇到 --add 时,先把所有组件设为禁用,再启用指定的
		if (isAdd && isFirstAdd)
		{
			isFirstAdd = false;
			ComponentRevivers::iterator iter = components_.begin();
			while (iter != endIter)
			{
				(*iter)->isEnabled( false );  // 全部禁用
				++iter;
			}
		}

		// 查找匹配的组件(支持 configName 或 createName 两种写法)
		{
			bool found = false;
			ComponentRevivers::iterator iter = components_.begin();
			while (iter != endIter)
			{
				if (((*iter)->configName() == argv[i]) ||
						strcmp( (*iter)->createName(), argv[i] ) == 0)
				{
					found = true;
					(*iter)->isEnabled( isAdd );  // --add 设 true,--del 设 false
				}
				++iter;
			}

			if (!found)
			{
				ERROR_MSG( "Reviver::init: Invalid command line. "
						"No such component %s\n", argv[i] );
				return false;
			}
		}
	}
}

// 不允许 --add 与 --del 混用
if (!isFirstAdd && !isFirstDel)
{
	ERROR_MSG( "Reviver::init: "
				"Cannot mix --add and --del command line options\n" );
	return false;
}
```

**语义说明**:
- **无 `--add`/`--del` 参数**:全部 5 个 ComponentReviver 默认启用(构造函数 `isEnabled_( true )`,见 `component_reviver.cpp` L45),再由 `queryMachinedSettings()` 根据 bwmachined 的 Components tags 收紧。
- **`--add X`**:首次 `--add` 会先把所有组件禁用,然后启用 X。语义是"只监控 X"。后续 `--add Y` 会追加启用 Y。
- **`--del X`**:不清空,只是把 X 单独禁用。语义是"除了 X 都监控"。
- **混用禁止**:`--add` 与 `--del` 不能同时出现。

`main.cpp` 中 `printHelp` 也展示了用法:

```cpp
// server/reviver/main.cpp  L21-22
"  --add {baseAppMgr|cellAppMgr|dbApp|loginApp}\n"
"  --del {baseAppMgr|cellAppMgr|dbApp|loginApp}\n"
```

> 注意:帮助文本里只列了 4 个,实际 `dbApp` 也是支持的(见 `component_reviver.cpp` L322)。

### 3.6 queryMachinedSettings()

```cpp
// server/reviver/reviver.cpp  L273-291
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

通过 `TagsMessage` 向本机 bwmachined(`LOCALHOST`)查询名为 `Components` 的 tag 集合。`sendAndRecv` 是同步调用,回复由 `TagsHandler::onTagsMessage` 处理:

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

			// 若 bwmachined 的 Components tag 中包含该组件的 createName 或 configName,则启用
			if (std::find( tags.begin(), tags.end(), component.createName() )
				!= tags.end() ||
				std::find( tags.begin(), tags.end(), component.configName() )
				!= tags.end())
			{
				component.isEnabled( true );
			}
			else
			{
				CONFIG_INFO_MSG( "\t%s disabled via bwmachined's "
							"Components tags\n",
						component.name().c_str() );
				component.isEnabled( false );
			}
			++iter;
		}
	}
	else
	{
		CONFIG_ERROR_MSG( "Reviver::init: "
			"BWMachined has no Components tags\n" );
	}

	return false;  // 返回 false 表示处理完毕,不再要更多回复
}
```

**作用**:让"本机能力"决定"本 Reviver 监控哪些组件"。例如某台机器的 `bwmachined.conf` 中 `Components` tag 没有声明 `dbapp`,则该机器上的 Reviver 不会监控 DBApp。这使得部署可以按机器角色定制,而无需修改 Reviver 启动参数。

> **注意**:这里与 `--add`/`--del` 是叠加生效的。命令行参数先生效,queryMachinedSettings 再生效。但实际查看代码顺序:步骤 7 拷贝全局链表后,步骤 8 立即调用 queryMachinedSettings,步骤 10 才解析命令行。所以实际顺序是 **tags 先收紧,命令行再覆盖**。若 `--add` 首次出现会重置全部为 disabled,因此 `--add` 的优先级实际高于 tags。

### 3.7 revive() 恢复流程

```cpp
// server/reviver/reviver.cpp  L440-474
void Reviver::revive( const char * createComponent )
{
	if (shuttingDown_)
	{
		INFO_MSG( "Reviver::revive: "
			"Trying to revive a process while shutting down.\n" );
		return;
	}

	CreateMessage cm;
	cm.uid_ = getUserId();
	cm.recover_ = 1;                       // 关键:带 -recover 启动
	cm.name_ = createComponent;            // 进程名,如 "cellappmgr"
	cm.config_ = BW_COMPILE_TIME_CONFIG;   // Hybrid/Debug 等

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
1. **构造 `CreateMessage`**:设置 `uid_`(当前用户 ID,让 bwmachined 以该用户身份启动)、`recover_=1`(让新进程带 `-recover` 启动参数)、`name_`(进程可执行名,如 `cellappmgr`)、`config_`(编译配置,如 `Hybrid`)。
2. **发送到 127.0.0.1**:`sendAndRecv` 同步发送到本机 bwmachined。`srcaddr=0` 表示由 bwmachined 自行决定回复地址。
3. **shutDownOnRevive 判定**:若配置 `reviver/shutDownOnRevive=true`(默认),则本 Reviver 在发出一次恢复命令后立即自我关闭,让其他 Reviver 接管后续监控。这是主备切换的关键(详见第十一章)。

### 3.8 run() 与 shutDown()

```cpp
// server/reviver/reviver.cpp  L404-413
bool Reviver::run()
{
	if (!this->hasEnabledComponents())
	{
		INFO_MSG( "Reviver::run:"
				"No components enabled to revive. Shutting down.\n" );
	}
	return this->ServerApp::run();
}
```

`run()` 检查是否有启用的组件,若无则打印提示(但仍然进入主循环,由 ServerApp::run 驱动)。最终通过 `ServerApp::run` 进入事件循环。

```cpp
// server/reviver/reviver.cpp  L419-434
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

`shutDown()` 设置关闭标记、打破事件循环、逐个 deactivate ComponentReviver。`shuttingDown_` 标记会被 `revive()` 检查,防止关闭过程中再发恢复命令。

### 3.9 hasEnabledComponents()

```cpp
// server/reviver/reviver.cpp  L480-495
bool Reviver::hasEnabledComponents() const
{
	ComponentRevivers::const_iterator iter = components_.begin();
	ComponentRevivers::const_iterator endIter = components_.end();

	while (iter != endIter)
	{
		if ((*iter)->isEnabled())
		{
			return true;
		}
		iter++;
	}
	return false;
}
```

简单遍历,只要有一个 ComponentReviver 启用就返回 true。

---

## 四、ComponentReviver:组件恢复器

`ComponentReviver` 是单个被监控组件的恢复器,每个被监控的组件类型(CellAppMgr / BaseAppMgr / DBAppMgr / DBApp / LoginApp)对应一个 `ComponentReviver` 子类实例。

### 4.1 基类设计

```cpp
// server/reviver/component_reviver.hpp  L22-25
class ComponentReviver : public Mercury::ShutdownSafeReplyMessageHandler,
	public TimerHandler,
	public Mercury::InputMessageHandler,
	public IntrusiveObject< ComponentReviver >
```

四重继承:

| 基类 | 作用 |
|------|------|
| `ShutdownSafeReplyMessageHandler` | 处理 ping 的回复(回复中带 REVIVER_PING_YES/NO),且在关闭过程中安全 |
| `TimerHandler` | 定时 ping 被监控进程 |
| `InputMessageHandler` | 处理 birth/death 消息(由 bwmachined 触发) |
| `IntrusiveObject<ComponentReviver>` | 自动注册到全局链表 `g_pComponentRevivers`,Reviver::init 时一并取出 |

> **`IntrusiveObject` 的精妙**:5 个特化类(`g_reviverOfCellAppMgr` 等)在 `component_reviver.cpp` 中作为全局变量声明,构造时自动通过 `IntrusiveObject` 把自己加入 `g_pComponentRevivers` 链表。`Reviver::init` 无需手动 new,直接 `components_ = *g_pComponentRevivers` 即可获得全部 5 个恢复器。这是一种"自注册"模式。

### 4.2 关键成员

```cpp
// server/reviver/component_reviver.hpp  L72-99
protected:
	virtual void initInterfaceElements() = 0;  // 子类必须实现:绑定 birth/death/ping 消息

	const Mercury::InterfaceElement * pBirthMessage_;  // birth 消息元素
	const Mercury::InterfaceElement * pDeathMessage_;  // death 消息元素
	const Mercury::InterfaceElement * pPingMessage_;   // ping 消息元素(发往被监控进程)

private:
	Mercury::EventDispatcher * pDispatcher_;
	Mercury::NetworkInterface * pInterface_;
	Mercury::Address addr_;                  // 被监控进程当前地址

	BW::string configName_;                  // 如 "cellAppMgr"(用于 BWConfig 路径)
	BW::string name_;                        // 如 "CellAppMgr"(用于日志)
	BW::string interfaceName_;               // 如 "CellAppMgrInterface"(用于 findInterface)
	const char * createParam_;               // 如 "cellappmgr"(传给 CreateMessage)

	ReviverPriority priority_;               // 当前优先级,0 表示未激活

	TimerHandle timerHandle_;                // ping 定时器
	int pingsToMiss_;                        // 剩余可丢失的 ping 数
	int maxPingsToMiss_;                     // 最大可丢失 ping 数(默认 3)
	int pingPeriod_;                         // ping 周期(微秒)

	bool isAttached_;                        // 是否已收到过 PING_YES(已附着)
	bool isEnabled_;                         // 是否启用
```

构造函数初始化这些成员:

```cpp
// server/reviver/component_reviver.cpp  L28-47
ComponentReviver::ComponentReviver( const char * configName, const char * name,
		const char * interfaceName, const char * createParam ) :
	IntrusiveObject< ComponentReviver >( g_pComponentRevivers ),
	pBirthMessage_( NULL ),
	pDeathMessage_( NULL ),
	pPingMessage_( NULL ),
	pDispatcher_( NULL ),
	addr_( 0, 0 ),
	configName_( configName ),
	name_( name ),
	interfaceName_( interfaceName ),
	createParam_( createParam ),
	priority_( 0 ),
	timerHandle_(),
	pingsToMiss_( 0 ),
	maxPingsToMiss_( 3 ),     // 默认最多丢失 3 次 ping
	isAttached_( false ),
	isEnabled_( true )        // 默认启用
{
}
```

### 4.3 init() 方法

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

	// 1) 读取 pingPeriod,可被 reviver/<configName>/pingPeriod 覆盖
	float pingPeriodInSeconds =
		BWConfig::get( (prefix + configName_ + "/pingPeriod").c_str(), 
			ReviverConfig::pingPeriod() );

	// 2) 校验 pingPeriod 必须小于 subjectTimeout(否则被监控进程永远超时)
	if (pingPeriodInSeconds > 
			BWConfig::get( (prefix + configName_ + "/subjectTimeout").c_str(),
				ReviverConfig::subjectTimeout() ))
	{
		CRITICAL_MSG( "ComponentReviver::init: "
			"The revier/subjectTimeout must be larger than "
			"reviver/pingPeriod." );
	}

	pingPeriod_ = int( pingPeriodInSeconds * 1000000 );

	// 3) 读取 timeoutInPings,可被 reviver/<configName>/timeoutInPings 覆盖
	maxPingsToMiss_ =
		BWConfig::get( (prefix + configName_ + "/timeoutInPings").c_str(),
							ReviverConfig::timeoutInPings() );

	// 4) 子类实现:绑定 birth/death/ping 三个 InterfaceElement
	this->initInterfaceElements();

	// 5) 通过 bwmachined 查找当前已存在的同名 interface(可能已在运行)
	if (Mercury::MachineDaemon::findInterface( interfaceName_.c_str(), 0,
					addr_, 4 ) != Mercury::REASON_SUCCESS)
	{
		ERROR_MSG( "ComponentReviver::init: "
			"failed to find %s\n", interfaceName_.c_str() );
		isOkay = false;
	}

	// 6) 向 bwmachined 注册 birth/death 监听器
	Mercury::MachineDaemon::registerBirthListener( interface.address(),
			*pBirthMessage_, const_cast<char *>( interfaceName_.c_str() ) );
	Mercury::MachineDaemon::registerDeathListener( interface.address(),
			*pDeathMessage_, const_cast<char *>( interfaceName_.c_str() ) );

	return isOkay;
}
```

**关键点**:
- **每个组件可独立覆盖配置**:`reviver/cellAppMgr/pingPeriod` 等路径优先于全局 `reviver/pingPeriod`。
- **`initInterfaceElements` 是纯虚函数**:由子类通过 `MF_REVIVER_HANDLER` 宏实现,把 `pBirthMessage_`/`pDeathMessage_`/`pPingMessage_` 绑定到具体消息。
- **`findInterface` 启动时探测**:Reviver 启动时若被监控进程已在运行,直接拿到其地址;若未运行,`addr_.ip` 保持为 0,后续靠 birth 监听补全。
- **注册 birth/death 监听**:让 bwmachined 在该 interface 对应进程出生/死亡时,向 Reviver 的 `interface.address()` 发送对应消息。

### 4.4 activate() / deactivate()

```cpp
// server/reviver/component_reviver.cpp  L136-150
bool ComponentReviver::activate( ReviverPriority priority )
{
	isAttached_ = false;

	// 仅当尚未启动定时器 且 已知被监控进程地址时,才启动 ping 定时器
	if (!timerHandle_.isSet() && (addr_.ip != 0))
	{
		pingsToMiss_ = maxPingsToMiss_;   // 初始允许连续丢失 maxPingsToMiss 次
		timerHandle_ = pDispatcher_->addTimer( pingPeriod_, this, 
			NULL, "ComponentReviver" );
		priority_ = priority;
		return true;
	}

	return false;
}
```

`activate` 由 `Reviver::init` 与 REATTACH 周期调用,赋予一个递增的 `priority`。仅当已知被监控进程地址(`addr_.ip != 0`)且尚未启动定时器时才真正启动。

```cpp
// server/reviver/component_reviver.cpp  L156-174
bool ComponentReviver::deactivate()
{
	if (isAttached_)
	{
		Reviver::pInstance()->markAsDirty();
		INFO_MSG( "ComponentReviver: %s (%s) has detached\n",
			addr_.c_str(), name_.c_str() );
		isAttached_ = false;
	}

	if (timerHandle_.isSet())
	{
		timerHandle_.cancel();
		priority_ = 0;       // 优先级清零表示未激活
		return true;
	}

	return false;
}
```

`deactivate` 取消定时器、清零优先级、打印 detach 日志并标记 Reviver 输出脏。

### 4.5 revive() 单组件恢复

```cpp
// server/reviver/component_reviver.cpp  L117-130
void ComponentReviver::revive()
{
	bool wasAttached = isAttached_;

	this->deactivate();          // 先停自己的 ping 定时器
	addr_.ip = 0;                // 清空地址,等 birth 通知
	addr_.port = 0;

	if (wasAttached)             // 仅当之前确实附着过才真正恢复
	{
		INFO_MSG( "Reviving %s\n", name_.c_str() );
		Reviver::pInstance()->revive( createParam_ );  // 委托 Reviver 发 CreateMessage
	}
}
```

**关键点**:
- **仅当 `wasAttached` 为 true 才恢复**:防止"启动时被监控进程未运行"被误判为崩溃而反复重启。只有曾经附着(收到过 PING_YES)再脱离,才视为崩溃。
- **清空地址 + deactivate**:等待 bwmachined 的 birth 通知重新补全地址,避免对老地址继续 ping。
- **委托 Reviver**:`Reviver::pInstance()->revive(createParam_)` 把"发 CreateMessage"的职责交给主类,主类统一处理 `shutDownOnRevive` 等策略。

### 4.6 消息处理:birth/death

```cpp
// server/reviver/component_reviver.cpp  L180-217
void ComponentReviver::handleMessage( const Mercury::Address & source,
	Mercury::UnpackedMessageHeader & header,
	BinaryIStream & data )
{
	MF_ASSERT( (header.identifier == pBirthMessage_->id()) ||
				(header.identifier == pDeathMessage_->id()) );

	Mercury::Address addr;
	data >> addr;                // 消息体就是死/生进程的地址

	if (header.identifier == pBirthMessage_->id())
	{
		addr_ = addr;            // 记录新地址
		INFO_MSG( "ComponentReviver::handleMessage: "
				"%s at %s has started.\n",
			name_.c_str(), addr.c_str() );
		return;
	}

	// death 消息
	INFO_MSG( "ComponentReviver::handleMessage: %s at %s has died.\n",
		name_.c_str(), addr.c_str() );

	if (addr == addr_)           // 死的正是当前监控的进程
	{
		this->revive();          // 触发恢复
	}
	else if (isAttached_)
	{
		// 死的是别的实例(可能是同一 interface 的另一进程),打印警告
		BW::string currAddrStr = addr_.c_str();
		ERROR_MSG( "ComponentReviver::handleMessage: "
				"%s component died at %s. Expected %s\n",
			name_.c_str(), addr.c_str(), currAddrStr.c_str() );
	}
}
```

**双死亡检测之一:broadcast death**。bwmachined 在进程退出时会向所有注册了 death listener 的进程广播 death 消息(消息体为死亡进程地址)。ComponentReviver 收到后:
- 若死的地址正是当前监控的 `addr_`,立即调用 `revive()`。
- 若死的地址与 `addr_` 不符,说明可能是同 interface 名的别的实例(理论上不应发生,因为这些都是单例进程),仅打印错误日志。

### 4.7 消息处理:ping 回复

```cpp
// server/reviver/component_reviver.cpp  L223-246
void ComponentReviver::handleMessage( const Mercury::Address & source,
	Mercury::UnpackedMessageHeader & header,
	BinaryIStream & data,
	void * arg )
{
	uint8 returnCode;
	data >> returnCode;
	if (returnCode == REVIVER_PING_YES)
	{
		pingsToMiss_ = maxPingsToMiss_;   // 重置可丢失计数

		if (!isAttached_)
		{
			Reviver::pInstance()->markAsDirty();
			INFO_MSG( "ComponentReviver: %s (%s) has attached.\n",
				addr_.c_str(), name_.c_str() );
			isAttached_ = true;            // 首次 YES 标记为已附着
		}
	}
	else
	{
		// 收到 PING_NO:被监控进程认为本 Reviver 不是主,主动脱离
		this->deactivate();
	}
}
```

**关键点**:
- **PING_YES 重置丢失计数**:每收到一次 YES,`pingsToMiss_` 重置为 `maxPingsToMiss_`,相当于"看门狗喂狗"。
- **首次 YES 标记 attached**:`isAttached_` 仅在首次收到 YES 时置 true,后续 YES 不重复打印日志。
- **PING_NO 触发脱离**:被监控进程(ReviverSubject)如果判定本 Reviver 不是主(优先级更高者存在),会回 NO,本 Reviver 立即 deactivate,让出监控权。这是主备切换的核心(详见第六、十一章)。

### 4.8 ping 超时检测

```cpp
// server/reviver/component_reviver.cpp  L252-267
void ComponentReviver::handleTimeout( TimerHandle /*handle*/, void * /*arg*/ )
{
	if (pingsToMiss_ > 0)
	{
		--pingsToMiss_;
		Mercury::UDPBundle bundle;
		bundle.startRequest( *pPingMessage_, this );  // 作为请求发送,期待回复
		bundle << priority_;                           // 携带本 Reviver 优先级
		pInterface_->send( addr_, bundle );
	}
	else
	{
		// 连续 maxPingsToMiss_+1 次未收到 YES,判定死亡
		INFO_MSG( "ComponentReviver::handleTimeout: Missed too many\n" );
		this->revive();
	}
}
```

**双死亡检测之二:主动 ping**。每个 ping 周期:
- 若 `pingsToMiss_ > 0`:递减并发送 ping 请求(携带本 Reviver 的 `priority_`)。被监控进程的 ReviverSubject 会回复 YES/NO。
- 若 `pingsToMiss_ == 0`:连续丢失过多,判定被监控进程死亡,调用 `revive()`。

**为什么需要 ping 而不仅靠 death 广播**?
1. **death 广播可能丢失**:UDP 不可靠,bwmachined 发出的 death 通知可能丢包。
2. **进程假死**:进程可能未退出(无 death 事件)但卡死不响应,ping 能检测出这种情况。
3. **网络分区**:Reviver 与 bwmachined 之间网络故障时,death 广播到不了,但 ping 也到不了被监控进程,同样会触发恢复(虽然此时恢复可能无意义,但至少有信号)。

### 4.9 handleException

```cpp
// server/reviver/component_reviver.cpp  L269-280
void ComponentReviver::handleException( const Mercury::NubException & ne,
	void * /*arg*/ )
{
	if (isAttached_)
	{
		ERROR_MSG( "ReviverReplyHandler::handleMessage: "
									"%s got an exception (%s).\n",
				name_.c_str(),
				Mercury::reasonToString( ne.reason() ) );
	}
}
```

ping 请求作为 `startRequest` 发送,若发生网络异常(如对端不可达),会回调 `handleException`。这里仅打印警告,**不直接触发 revive**,因为下一周期的 ping 超时会处理。

### 4.10 MF_REVIVER_HANDLER 宏与 5 个特化类

```cpp
// server/reviver/component_reviver.cpp  L298-323
#define MF_REVIVER_HANDLER( CONFIG, COMPONENT, CREATE_WHAT )				\
	MF_REVIVER_HANDLER2( CONFIG, COMPONENT, COMPONENT, CREATE_WHAT )

#define MF_REVIVER_HANDLER2( CONFIG, COMPONENT, COMPONENT2, CREATE_WHAT )	\
/** @internal */															\
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

### 4.11 5 个特化类对比

| 特化类 | CONFIG | COMPONENT | COMPONENT2 | CREATE_WHAT | interfaceName | ping 消息来源 |
|--------|--------|-----------|------------|-------------|---------------|--------------|
| `CellAppMgrReviver` | `cellAppMgr` | `CellAppMgr` | `CellAppMgr` | `"cellappmgr"` | `CellAppMgrInterface` | `CellAppMgrInterface::reviverPing` |
| `BaseAppMgrReviver` | `baseAppMgr` | `BaseAppMgr` | `BaseAppMgr` | `"baseappmgr"` | `BaseAppMgrInterface` | `BaseAppMgrInterface::reviverPing` |
| `DBAppMgrReviver` | `dbAppMgr` | `DBAppMgr` | `DBAppMgr` | `"dbappmgr"` | `DBAppMgrInterface` | `DBAppMgrInterface::reviverPing` |
| `DBAppReviver` | `dbApp` | `DBApp` | `DBApp` | `"dbapp"` | `DBAppInterface` | `DBAppInterface::reviverPing` |
| `LoginReviver` | `loginApp` | `Login` | `LoginInt` | `"loginapp"` | `LoginIntInterface` | `LoginIntInterface::reviverPing` |

**注意 LoginApp 的特殊性**:由于 `LoginApp` 类名与 interface 名 `LoginInt` 不一致(避免与外部 LoginInterface 混淆),使用 `MF_REVIVER_HANDLER2` 宏单独处理。其类名为 `LoginReviver`(而非 `LoginAppReviver`),但 `name_` 仍为 `"Login"`,`configName_` 为 `"loginApp"`,`createParam_` 为 `"loginapp"`。

### 4.12 全局实例自注册

5 个 `g_reviverOfXxx` 都是全局变量,程序启动时(进入 `main` 之前)构造。每个构造函数通过 `IntrusiveObject<ComponentReviver>( g_pComponentRevivers )` 把自己加入全局链表:

```cpp
// component_reviver.cpp  L23
ComponentRevivers * g_pComponentRevivers;
```

`g_pComponentRevivers` 是全局指针,初始为 NULL。`IntrusiveObject` 模板在首次使用时会 new 一个 `ComponentRevivers`(vector)并让 `g_pComponentRevivers` 指向它,后续构造的特化类都 push_back 进去。`Reviver::init` 中:

```cpp
// reviver.cpp  L81-87
if (g_pComponentRevivers == NULL)
{
	ERROR_MSG( "Reviver::init: No component revivers\n" );
	return false;
}
components_ = *g_pComponentRevivers;
```

直接拷贝整个 vector 到 `components_`,完成"收集所有特化类"。

> 这种"全局对象自注册 + 主类启动时收集"模式避免了在 `Reviver::init` 中显式 `new` 5 个恢复器,新增组件类型时只需新增一行 `MF_REVIVER_HANDLER` 即可,扩展性好。

---

## 五、双死亡检测机制

Reviver 对每个被监控进程使用 **birth/death 广播 + ping 心跳** 双重检测,任一渠道判定死亡都会触发恢复。

### 5.1 检测流程图

```
被监控进程启动
      │
      ▼
┌──────────────────────────────────────────────────────────┐
│ bwmachined 探测到新进程,广播 birth 事件                 │
│ (向所有 registerBirthListener 的进程发 birth 消息)      │
└──────────────────────────────────────────────────────────┘
      │
      ▼
┌──────────────────────────────────────────────────────────┐
│ ComponentReviver::handleMessage (birth 分支)             │
│  - addr_ = 新地址                                        │
│  - 打印 "has started"                                    │
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
                                    │
                                    ▼
                    ┌────────────────────────────────────┐
                    │ ReviverSubject::handleMessage      │
                    │  仲裁:本 Reviver 是否为主?       │
                    │  YES → 回 REVIVER_PING_YES         │
                    │  NO  → 回 REVIVER_PING_NO          │
                    └────────────────────────────────────┘
                                    │
                                    ▼
┌──────────────────────────────────────────────────────────┐
│ ComponentReviver::handleMessage (reply 分支)             │
│  if YES:                                                 │
│      pingsToMiss_ = maxPingsToMiss_;  (喂狗)            │
│      isAttached_ = true;  (首次)                        │
│  if NO:                                                  │
│      deactivate();  (让出监控权)                       │
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
│  else:                                                   │
│      打印警告(死的是别的实例)                         │
└──────────────────────────────────────────────────────────┘
```

### 5.2 两种检测的互补性

| 检测方式 | 触发条件 | 优点 | 缺点 |
|---------|---------|------|------|
| **death 广播** | bwmachined 探测到进程退出 | 响应快(进程一退出立即触发);不依赖 Reviver 与被监控进程的网络 | UDP 可能丢包;进程假死(未退出)无法检测 |
| **ping 心跳** | 连续 `maxPingsToMiss_+1` 次未收到 YES | 可靠(逐周期递减);能检测假死 | 响应慢(需等 `maxPingsToMiss_ * pingPeriod`);依赖 Reviver 与被监控进程的网络 |

两者结合,既能在进程正常崩溃时快速恢复,又能在 death 通知丢失或进程假死时兜底。

### 5.3 防误判机制

`ComponentReviver::revive()` 中有重要保护:

```cpp
// component_reviver.cpp  L117-130
void ComponentReviver::revive()
{
	bool wasAttached = isAttached_;
	this->deactivate();
	addr_.ip = 0;
	addr_.port = 0;
	if (wasAttached)   // 只有曾经附着过才恢复
	{
		INFO_MSG( "Reviving %s\n", name_.c_str() );
		Reviver::pInstance()->revive( createParam_ );
	}
}
```

**`wasAttached` 守门**:只有曾经收到过 `REVIVER_PING_YES`(即 `isAttached_==true`)的进程,其死亡才触发恢复。这避免了:
- Reviver 启动时被监控进程尚未运行 → 不应反复重启。
- 被监控进程启动中、尚未响应第一个 ping → 不应误判为死亡。
- 主备 Reviver 切换时,备 Reviver 从未附着 → 不应触发恢复。

### 5.4 maxPingsToMiss_ 的初始值与喂狗

```cpp
// component_reviver.cpp  L42-44
pingsToMiss_( 0 ),
maxPingsToMiss_( 3 ),
```

构造时 `pingsToMiss_=0`、`maxPingsToMiss_=3`。`activate` 时把 `pingsToMiss_` 设为 `maxPingsToMiss_`(3):

```cpp
// component_reviver.cpp  L142
pingsToMiss_ = maxPingsToMiss_;
```

每个 ping 周期 `handleTimeout`:
- `pingsToMiss_ > 0`:递减并发 ping。即第 1、2、3 次周期发 ping,期间若收到 YES 则重置回 3。
- `pingsToMiss_ == 0`(即第 4 次周期):判定死亡。

所以实际超时时间 ≈ `(maxPingsToMiss_ + 1) * pingPeriod_`。`postInit` 中保证 `timeoutInPings >= 1`,且 `timeout = timeoutInPings * pingPeriod` 至少 1 个周期。

### 5.5 death 消息的精确匹配

```cpp
// component_reviver.cpp  L204-216
if (addr == addr_)
{
	this->revive();
}
else if (isAttached_)
{
	BW::string currAddrStr = addr_.c_str();
	ERROR_MSG( "ComponentReviver::handleMessage: "
			"%s component died at %s. Expected %s\n",
		name_.c_str(), addr.c_str(), currAddrStr.c_str() );
}
```

death 消息携带的地址必须与 `addr_` 完全相等才触发 revive。这避免了"同 interface 名的别的实例死亡"误触发(虽然这些单例进程理论上不会出现多实例,但代码仍做了防护)。

---

## 六、ReviverSubject 优先级仲裁

`ReviverSubject` 是被监控进程侧的"被恢复主体",每个被监控进程(CellAppMgr / BaseAppMgr / DBAppMgr / DBApp / LoginApp)内都有一个全局单例 `ReviverSubject::instance_`。它负责处理 Reviver 发来的 ping,并仲裁哪个 Reviver 是"主"。

### 6.1 单例设计

```cpp
// lib/server/reviver_subject.hpp  L14-37
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

	Mercury::NetworkInterface *		pInterface_;
	Mercury::Address	reviverAddr_;      // 当前主 Reviver 的地址
	uint64				lastPingTime_;     // 当前主 Reviver 上次 ping 时间
	ReviverPriority		priority_;         // 当前主 Reviver 的优先级

	int					msTimeout_;        // 主 Reviver 超时阈值(毫秒)

	static ReviverSubject instance_;
};

#define MF_REVIVER_PING_MSG()	\
		MERCURY_VARIABLE_MESSAGE( reviverPing, 2, &ReviverSubject::instance() )
```

```cpp
// lib/server/reviver_subject.cpp  L18
ReviverSubject ReviverSubject::instance_;
```

`ReviverSubject` 是进程内静态单例。`MF_REVIVER_PING_MSG` 宏在被监控进程的 Interface 中声明 `reviverPing` 消息,处理者就是该单例。

### 6.2 init() 初始化

```cpp
// lib/server/reviver_subject.cpp  L44-65
void ReviverSubject::init( Mercury::NetworkInterface * pInterface,
								const char * componentName )
{
	pInterface_ = pInterface;
	char buf[128];
	bw_snprintf( buf, sizeof(buf), "reviver/%s/subjectTimeout", componentName );

	// 读取 subjectTimeout,可被 reviver/<component>/subjectTimeout 覆盖
	msTimeout_ = int( BWConfig::get( buf,
				BWConfig::get( "reviver/subjectTimeout", 
					REVIVER_DEFAULT_SUBJECT_TIMEOUT ) ) * 1000 );
	INFO_MSG( "ReviverSubject::init: msTimeout_ = %d\n", msTimeout_ );

	// 校验 pingPeriod < subjectTimeout
	bw_snprintf( buf, sizeof(buf), "reviver/%s/pingPeriod", componentName );
	if (int( BWConfig::get( buf,
			BWConfig::get( "reviver/pingPeriod",
				REVIVER_DEFAULT_PING_PERIOD ) ) * 1000 ) > msTimeout_)
	{
		CRITICAL_MSG( "ReviverSubject::init: "
			"The revier/subjectTimeout must be larger than "
			"reviver/pingPeriod." );
	}
}
```

**关键点**:
- `msTimeout_` 是主 Reviver 的"超时阈值":若当前主 Reviver 超过该时长未 ping,则视为它已死,允许备 Reviver 接管。
- 配置路径 `reviver/<component>/subjectTimeout` 优先于全局 `reviver/subjectTimeout`,默认 0.2s。
- 校验 `pingPeriod < subjectTimeout`:否则 Reviver 永远无法在 subjectTimeout 内 ping 到,导致每次 ping 都被判超时切换。

### 6.3 handleMessage 仲裁逻辑

```cpp
// lib/server/reviver_subject.cpp  L84-154
void ReviverSubject::handleMessage( const Mercury::Address & srcAddr,
		Mercury::UnpackedMessageHeader & header,
		BinaryIStream & data )
{
	if (pInterface_ == NULL)
	{
		ERROR_MSG( "ReviverSubject::handleMessage: "
						"ReviverSubject not initialised\n" );
		return;
	}

	uint64 currentPingTime = timestamp();

	ReviverPriority priority;
	data >> priority;                 // 取出 Reviver 携带的优先级

	bool accept = (reviverAddr_ == srcAddr);  // 是当前主 Reviver?

	if (!accept)
	{
		// 不是当前主,检查是否能抢占
		if (priority < priority_)    // 优先级更高(数值更小)
		{
			if (priority_ == 0xff)   // 0xff 是初始值,表示尚未有主
			{
				INFO_MSG( "ReviverSubject::handleMessage: "
							"Reviver is %s (Priority %d)\n",
						srcAddr.c_str(), priority );
			}
			else
			{
				INFO_MSG( "ReviverSubject::handleMessage: "
							"%s has a better priority (%d)\n",
						srcAddr.c_str(), priority );
			}
			accept = true;           // 抢占成功
		}
		else
		{
			// 优先级不更高,检查当前主是否超时
			uint64 delta = (currentPingTime - lastPingTime_) * uint64(1000);
			delta /= stampsPerSecond();
			int msBetweenPings = int(delta);

			if (msBetweenPings > msTimeout_)   // 当前主超时
			{
				BW::string oldAddr = reviverAddr_.c_str();
				INFO_MSG( "ReviverSubject::handleMessage: "
								"%s timed out (%d ms). Now using %s\n",
							oldAddr.c_str(), msBetweenPings, srcAddr.c_str() );
				accept = true;       // 主超时,接管
			}
		}
	}

	Mercury::UDPBundle bundle;
	bundle.startReply( header.replyID );

	if (accept)
	{
		reviverAddr_ = srcAddr;       // 记录新主
		lastPingTime_ = currentPingTime;
		priority_ = priority;
		bundle << REVIVER_PING_YES;   // 回 YES
	}
	else
	{
		bundle << REVIVER_PING_NO;    // 回 NO
	}

	pInterface_->send( srcAddr, bundle );
}
```

### 6.4 仲裁规则总结

被监控进程收到一个 ping 时,决定回 YES 还是 NO 的规则:

| 条件 | 结果 | 说明 |
|------|------|------|
| `srcAddr == reviverAddr_`(当前主) | YES | 主 Reviver 的正常 ping |
| `priority < priority_`(优先级更高,数值更小) | YES | 抢占:更高优先级 Reviver 取代当前主 |
| `priority_ == 0xff`(尚未有主) | YES | 首次 ping,接受任意 Reviver 为主 |
| 当前主超时(`msBetweenPings > msTimeout_`) | YES | 主超时,接受新 Reviver 接管 |
| 其他 | NO | 当前主正常且优先级更高,拒绝 |

**优先级数值越小越高**:`priority < priority_` 表示新来的 Reviver 优先级更高。`Reviver::init` 中 `activate(++priority)` 从 1 开始递增赋值,所以 **启用顺序越靠前的 ComponentReviver 优先级越高**。但实际上不同 Reviver 进程之间的优先级比较取决于各自 `components_` 的顺序,该顺序由 `g_pComponentRevivers` 中特化类的构造顺序决定(即 `component_reviver.cpp` 中 `MF_REVIVER_HANDLER` 宏的书写顺序:CellAppMgr → BaseAppMgr → DBAppMgr → DBApp → Login)。

### 6.5 优先级仲裁的意义

仲裁机制实现了 **多 Reviver 主备热备**:
- 多个 Reviver 同时运行,各自 ping 同一个被监控进程。
- 被监控进程的 ReviverSubject 只向"主 Reviver"回 YES,向其他回 NO。
- 收到 NO 的备 Reviver 调用 `deactivate()`,停止 ping 定时器(节省资源)。
- 主 Reviver 故障后,其 ping 停止,`msTimeout_` 后被监控进程接受下一个 ping 的 Reviver 为新主。
- 新主开始收到 YES,`isAttached_=true`,接管监控职责。

> 注意:不同被监控进程的"主 Reviver"可能不同。每个 ReviverSubject 独立仲裁,因此 CellAppMgr 的主可能是 Reviver A,而 BaseAppMgr 的主可能是 Reviver B。这是"按组件分散主备"的细粒度策略。

---

## 七、与 bwmachined 的交互

Reviver 自身不 fork 进程,所有进程管理都委托给本机的 `bwmachined` 守护进程。交互通过 MachineGuard 消息(UDP)进行。

### 7.1 CreateMessage:进程创建命令

```cpp
// lib/network/machine_guard.hpp  L634-662
/**
 *  @internal
 *  A CreateMessage is sent to bwmachined to command it to spawn a new process.
 */
class CreateMessage : public MachineGuardMessage
{
public:
	BW::string		name_;		//!< Name of executable to start
	BW::string		config_;	//!< Hybrid, Debug etc
	UserId			uid_;		//!< UserID to start the process as
	uint8			recover_;	//!< Set to true to start with -recover
	uint32			fwdIp_;		//!< IP to forward output to
	uint16			fwdPort_;	//!< Port to forward output to

	CreateMessage( Message messageType = CREATE_MESSAGE ) :
					MachineGuardMessage( messageType )
	{
	}

	virtual ~CreateMessage() {}

	virtual const char *c_str() const;
	const char * c_str_name( const char * className ) const;

protected:
	virtual void writeImpl( BinaryOStream &os );
	virtual void readImpl( BinaryIStream &is );
};
```

字段说明:

| 字段 | 类型 | 含义 | Reviver 中的设置 |
|------|------|------|----------------|
| `name_` | `BW::string` | 可执行文件名(如 `cellappmgr`) | `createComponent` 参数(如 `"cellappmgr"`) |
| `config_` | `BW::string` | 编译配置(Hybrid/Debug) | `BW_COMPILE_TIME_CONFIG` 宏 |
| `uid_` | `UserId` | 以哪个用户身份启动 | `getUserId()`(当前用户) |
| `recover_` | `uint8` | 是否带 `-recover` 启动参数 | 固定为 `1` |
| `fwdIp_` | `uint32` | 输出转发 IP | 未设置(默认 0) |
| `fwdPort_` | `uint16` | 输出转发端口 | 未设置(默认 0) |

### 7.2 Reviver::revive 中的发送

```cpp
// server/reviver/reviver.cpp  L450-467
CreateMessage cm;
cm.uid_ = getUserId();
cm.recover_ = 1;
cm.name_ = createComponent;
cm.config_ = BW_COMPILE_TIME_CONFIG;

uint32 srcaddr = 0, destaddr = htonl( 0x7f000001U );  // 127.0.0.1
if (cm.sendAndRecv( srcaddr, destaddr ) != Mercury::REASON_SUCCESS)
{
	ERROR_MSG( "ComponentReviver::revive: Could not send request.\n" );
```

- `destaddr = 127.0.0.1`:本机 bwmachined。
- `srcaddr = 0`:由 bwmachined 自行决定回复地址。
- `sendAndRecv`:同步发送并等待回复。

### 7.3 bwmachined 的处理

bwmachined 收到 `CreateMessage` 后:
1. 根据 `name_` 和 `config_` 在 `bwmachined.conf` 中查找可执行路径。
2. 以 `uid_` 指定的用户身份 fork+exec 新进程。
3. 若 `recover_==1`,在新进程命令行追加 `-recover`。
4. 新进程启动后,bwmachined 探测其 interface 并广播 birth 事件。

### 7.4 `-recover` 参数的意义

被恢复的进程会带 `-recover` 启动,使其进入"恢复模式"。例如 CellAppMgr:

```cpp
// server/cellappmgr/cellappmgr.cpp  L170-181
for (int i = 0; i < argc; ++i)
{
	if (strcmp( argv[i], "-recover" ) == 0)
	{
		isRecovery = true;
	}
	else if (strcmp( argv[i], "-machined" ) == 0)
	{
		CONFIG_INFO_MSG( "CellAppMgr::init: Started from machined\n" );
	}
}
```

BaseAppMgr:

```cpp
// server/baseappmgr/baseappmgr.cpp  L367-374
for (int i = 0; i < argc; ++i)
{
	if (strcmp( argv[i], "-recover" ) == 0)
	{
		isRecovery_ = true;
		break;
	}
}
```

恢复模式下,进程会从 DB 重新加载状态而非新建空状态,保证服务连续性。

### 7.5 TagsMessage:查询 bwmachined 能力

```cpp
// server/reviver/reviver.cpp  L273-291
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

`TagsMessage` 用于查询 bwmachined 的 tags。这里查询名为 `Components` 的 tag 集合,该 tag 声明了本机可运行哪些组件(在 `bwmachined.conf` 中配置)。回复由 `TagsHandler::onTagsMessage` 处理,据此启用/禁用 ComponentReviver。

### 7.6 registerWithMachined:声明 Reviver 存在

```cpp
// server/reviver/reviver.cpp  L73-78
if (ReviverInterface::registerWithMachined( interface_, 0 ) !=
		Mercury::REASON_SUCCESS)
{
	NETWORK_WARNING_MSG( "Reviver::init: Unable to register interface\n" );
	return false;
}
```

`registerWithMachined` 让 bwmachined 知道 Reviver 的存在及其 interface 地址。这是注册 birth/death listener 的前置条件。

### 7.7 registerBirthListener / registerDeathListener

```cpp
// server/reviver/component_reviver.cpp  L105-108
Mercury::MachineDaemon::registerBirthListener( interface.address(),
		*pBirthMessage_, const_cast<char *>( interfaceName_.c_str() ) );
Mercury::MachineDaemon::registerDeathListener( interface.address(),
		*pDeathMessage_, const_cast<char *>( interfaceName_.c_str() ) );
```

```cpp
// lib/network/machined_utils.hpp  L56-66
Reason registerBirthListener( const Address & srcAddr,
		UDPBundle & bundle, int addrStart, const char * ifname );

Reason registerDeathListener( const Address & srcAddr,
		UDPBundle & bundle, int addrStart, const char * ifname );

Reason registerBirthListener( const Address & srcAddr,
		const InterfaceElement & ie, const char * ifname );

Reason registerDeathListener( const Address & srcAddr,
		const InterfaceElement & ie, const char * ifname );
```

`registerBirthListener` 让 bwmachined 在名为 `ifname` 的 interface 进程启动时,向 `srcAddr` 发送 `ie` 消息(消息体为新进程地址)。`registerDeathListener` 同理,针对进程退出。

实现:

```cpp
// lib/network/machined_utils.cpp  L173-183
Reason registerBirthListener( const Address & srcAddr,
		const InterfaceElement & ie, const char * ifname )
{
	Mercury::UDPBundle bundle;
	bundle.startMessage( ie, RELIABLE_NO );
	int startOfAddress = bundle.size();
	bundle << Mercury::Address::NONE;
	return registerBirthListener( srcAddr, bundle, startOfAddress, ifname );
}
```

bundle 中预留了一个 `Address::NONE` 占位,bwmachined 在触发时会填入实际的新进程地址再发送。

### 7.8 findInterface:启动时探测

```cpp
// server/reviver/component_reviver.cpp  L97-103
if (Mercury::MachineDaemon::findInterface( interfaceName_.c_str(), 0,
				addr_, 4 ) != Mercury::REASON_SUCCESS)
{
	ERROR_MSG( "ComponentReviver::init: "
		"failed to find %s\n", interfaceName_.c_str() );
	isOkay = false;
}
```

`findInterface(name, id, addr, retries=4)` 通过 bwmachined 查询当前名为 `name` 的 interface(进程)地址,最多重试 4 次。Reviver 启动时若被监控进程已在运行,这里能拿到其地址;若未运行,返回失败但不阻止 init 继续(只是 `isOkay=false`),后续靠 birth 监听补全地址。

---

## 八、配置项详解

Reviver 的配置通过 `ReviverConfig` 类管理,继承自 `ServerAppConfig`,使用 `BW_OPTION` 宏声明可被 `bwconfig.xml` 覆盖的配置项。

### 8.1 配置类声明

```cpp
// server/reviver/reviver_config.hpp  L6-17
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

### 8.2 配置项默认值

```cpp
// server/reviver/reviver_config.cpp  L15-20
BW_OPTION_RO( float, reattachPeriod, 10.f );                                    // 只读
BW_OPTION( float, pingPeriod, REVIVER_DEFAULT_PING_PERIOD );                    // 0.1s
BW_OPTION( float, subjectTimeout, REVIVER_DEFAULT_SUBJECT_TIMEOUT );            // 0.2s
BW_OPTION( bool, shutDownOnRevive, true );                                      // 默认 true
BW_OPTION( float, timeout, 3.0 );                                               // 3s
BW_OPTION( int, timeoutInPings, 0 );                                            // 0(由 timeout 推导)
```

```cpp
// lib/server/reviver_common.hpp  L15-16
const float REVIVER_DEFAULT_SUBJECT_TIMEOUT = 0.2f;
const float REVIVER_DEFAULT_PING_PERIOD = 0.1f;
```

### 8.3 配置项一览表

| 配置项 | 类型 | 默认值 | 含义 | 是否可覆盖 |
|--------|------|--------|------|-----------|
| `reviver/reattachPeriod` | float | 10.0s | REATTACH 周期:重新评估 ComponentReviver 状态、重排优先级、打印 summary | 否(RO) |
| `reviver/pingPeriod` | float | 0.1s | ping 心跳周期 | 是(`reviver/<component>/pingPeriod`) |
| `reviver/subjectTimeout` | float | 0.2s | 主 Reviver 超时阈值(被监控进程侧) | 是(`reviver/<component>/subjectTimeout`) |
| `reviver/shutDownOnRevive` | bool | true | 恢复后是否关闭本 Reviver(主备切换) | 否 |
| `reviver/timeout` | float | 3.0s | 恢复超时(用于推导 timeoutInPings) | 否 |
| `reviver/timeoutInPings` | int | 0 | 以 ping 次数计的超时(0 表示由 timeout 推导) | 是(`reviver/<component>/timeoutInPings`,已废弃) |

### 8.4 postInit:timeoutInPings 的推导

```cpp
// server/reviver/reviver_config.cpp  L26-60
bool ReviverConfig::postInit()
{
	bool result = ServerAppConfig::postInit();

	if (result)
	{
		if (ReviverConfig::timeoutInPings() == 0)
		{
			// 由 timeout / pingPeriod 推导
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
			// 用户显式设置了 timeoutInPings,提示已废弃
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

**推导逻辑**:
- 默认 `timeoutInPings=0`,触发推导:`timeoutInPings = round(timeout / pingPeriod)`。
- 默认 `timeout=3.0`、`pingPeriod=0.1`,推导得 `timeoutInPings=30`。
- 即默认情况下,连续 30 次 ping(约 3 秒)未收到 YES 才判定死亡。
- 若用户显式设置 `timeoutInPings`,则使用用户值并打印废弃警告(应改用 `timeout`)。
- 校验 `pingPeriod < subjectTimeout`,否则 CRITICAL_MSG 终止。

### 8.5 每组件覆盖配置

`ComponentReviver::init` 中读取每个组件独立的配置:

```cpp
// server/reviver/component_reviver.cpp  L71-90
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

pingPeriod_ = int( pingPeriodInSeconds * 1000000 );

maxPingsToMiss_ =
	BWConfig::get( (prefix + configName_ + "/timeoutInPings").c_str(),
						ReviverConfig::timeoutInPings() );
```

可被覆盖的配置路径:

| 配置路径 | 含义 |
|---------|------|
| `reviver/cellAppMgr/pingPeriod` | CellAppMgr 的 ping 周期 |
| `reviver/cellAppMgr/subjectTimeout` | CellAppMgr 的 subject 超时 |
| `reviver/cellAppMgr/timeoutInPings` | CellAppMgr 的 ping 超时次数(已废弃) |
| `reviver/baseAppMgr/...` | BaseAppMgr 同上 |
| `reviver/dbAppMgr/...` | DBAppMgr 同上 |
| `reviver/dbApp/...` | DBApp 同上 |
| `reviver/loginApp/...` | LoginApp 同上 |

> 注意:`configName_` 用于配置路径,其值见第四章 4.11 表格(如 `cellAppMgr`、`loginApp`)。

### 8.6 ReviverSubject 侧的同步配置

被监控进程的 ReviverSubject 也读取相同的配置路径,保证两端一致:

```cpp
// lib/server/reviver_subject.cpp  L48-64
bw_snprintf( buf, sizeof(buf), "reviver/%s/subjectTimeout", componentName );
msTimeout_ = int( BWConfig::get( buf,
			BWConfig::get( "reviver/subjectTimeout", 
				REVIVER_DEFAULT_SUBJECT_TIMEOUT ) ) * 1000 );

bw_snprintf( buf, sizeof(buf), "reviver/%s/pingPeriod", componentName );
if (int( BWConfig::get( buf,
		BWConfig::get( "reviver/pingPeriod",
			REVIVER_DEFAULT_PING_PERIOD ) ) * 1000 ) > msTimeout_)
{
	CRITICAL_MSG( "ReviverSubject::init: "
		"The revier/subjectTimeout must be larger than "
		"reviver/pingPeriod." );
}
```

两端读取同一份 `bwconfig.xml`,配置路径一致,因此能保证 Reviver 端的 `pingPeriod` 与被监控进程端的 `subjectTimeout` 协调。

### 8.7 配置约束总结

| 约束 | 校验位置 | 失败后果 |
|------|---------|---------|
| `pingPeriod < subjectTimeout` | `ReviverConfig::postInit`、`ComponentReviver::init`、`ReviverSubject::init` | CRITICAL_MSG 终止 |
| `timeout >= pingPeriod`(即 `timeoutInPings >= 1`) | `ReviverConfig::postInit` | ERROR_MSG 返回 false |
| `timeoutInPings == 0` 时由 `timeout/pingPeriod` 推导 | `ReviverConfig::postInit` | - |

---

## 九、消息接口

Reviver 涉及的消息分两类:Reviver 自己暴露的 birth/death 消息(10 条),以及被监控进程暴露的 reviverPing 消息(5 条)。

### 9.1 ReviverInterface:10 条 birth/death 消息

```cpp
// server/reviver/reviver_interface.hpp  L15-22
#define BW_REVIVER_MSGS( COMPONENT )										\
	MERCURY_FIXED_MESSAGE( handle##COMPONENT##Birth,						\
							sizeof( Mercury::Address ),						\
							&g_reviverOf##COMPONENT )						\
	MERCURY_FIXED_MESSAGE( handle##COMPONENT##Death,						\
							sizeof( Mercury::Address ),						\
							&g_reviverOf##COMPONENT )						\
```

```cpp
// server/reviver/reviver_interface.hpp  L30-40
BEGIN_MERCURY_INTERFACE( ReviverInterface )

	BW_REVIVER_MSGS( CellAppMgr )
	BW_REVIVER_MSGS( BaseAppMgr )
	BW_REVIVER_MSGS( DBAppMgr )
	BW_REVIVER_MSGS( DBApp )
	BW_REVIVER_MSGS( Login )

END_MERCURY_INTERFACE()
```

每个 `BW_REVIVER_MSGS(COMPONENT)` 展开为 2 条 `MERCURY_FIXED_MESSAGE`:
- `handle<COMPONENT>Birth`:消息体为 `Mercury::Address`(4+2=6 字节),处理者为 `g_reviverOf<COMPONENT>`。
- `handle<COMPONENT>Death`:同上。

5 个 COMPONENT 共 10 条消息。

### 9.2 完整消息列表

| 消息名 | 方向 | 消息体 | 处理者 | 触发时机 |
|--------|------|--------|--------|---------|
| `handleCellAppMgrBirth` | bwmachined → Reviver | `Address` | `g_reviverOfCellAppMgr` | CellAppMgr 进程启动 |
| `handleCellAppMgrDeath` | bwmachined → Reviver | `Address` | `g_reviverOfCellAppMgr` | CellAppMgr 进程退出 |
| `handleBaseAppMgrBirth` | bwmachined → Reviver | `Address` | `g_reviverOfBaseAppMgr` | BaseAppMgr 进程启动 |
| `handleBaseAppMgrDeath` | bwmachined → Reviver | `Address` | `g_reviverOfBaseAppMgr` | BaseAppMgr 进程退出 |
| `handleDBAppMgrBirth` | bwmachined → Reviver | `Address` | `g_reviverOfDBAppMgr` | DBAppMgr 进程启动 |
| `handleDBAppMgrDeath` | bwmachined → Reviver | `Address` | `g_reviverOfDBAppMgr` | DBAppMgr 进程退出 |
| `handleDBAppBirth` | bwmachined → Reviver | `Address` | `g_reviverOfDBApp` | DBApp 进程启动 |
| `handleDBAppDeath` | bwmachined → Reviver | `Address` | `g_reviverOfDBApp` | DBApp 进程退出 |
| `handleLoginBirth` | bwmachined → Reviver | `Address` | `g_reviverOfLogin` | LoginApp 进程启动 |
| `handleLoginDeath` | bwmachined → Reviver | `Address` | `g_reviverOfLogin` | LoginApp 进程退出 |

> 注意:消息名中的 COMPONENT 部分使用类名(`CellAppMgr`、`Login`),而不是 configName。这是宏展开 `handle##COMPONENT##Birth` 的结果。

### 9.3 reviverPing:被监控进程的 ping 消息

每个被监控进程的 Interface 中通过 `MF_REVIVER_PING_MSG` 宏声明 `reviverPing` 消息:

```cpp
// lib/server/reviver_subject.hpp  L39-40
#define MF_REVIVER_PING_MSG()	\
		MERCURY_VARIABLE_MESSAGE( reviverPing, 2, &ReviverSubject::instance() )
```

- `MERCURY_VARIABLE_MESSAGE`:变长消息(参数长度可变)。
- `2`:消息参数(stream 长度),即 `ReviverPriority`(uint8) + 隐含的回复头。
- 处理者:`ReviverSubject::instance()` 单例。

### 9.4 ping 消息的发送与回复

**Reviver 端发送**(ComponentReviver::handleTimeout):

```cpp
// server/reviver/component_reviver.cpp  L257-260
Mercury::UDPBundle bundle;
bundle.startRequest( *pPingMessage_, this );  // 作为请求(期待回复)
bundle << priority_;                          // 携带优先级
pInterface_->send( addr_, bundle );
```

`pPingMessage_` 指向被监控进程的 `reviverPing` InterfaceElement(如 `CellAppMgrInterface::reviverPing`)。`startRequest` 表示这是一个请求消息,期待回复;回复由 `ComponentReviver::handleMessage`(reply 重载)处理。

**被监控进程端处理**(ReviverSubject::handleMessage):

```cpp
// lib/server/reviver_subject.cpp  L97-98
ReviverPriority priority;
data >> priority;                 // 读取优先级
// ... 仲裁 ...
Mercury::UDPBundle bundle;
bundle.startReply( header.replyID );
if (accept)
{
	bundle << REVIVER_PING_YES;   // uint8 = 1
}
else
{
	bundle << REVIVER_PING_NO;    // uint8 = 0
}
pInterface_->send( srcAddr, bundle );
```

**Reviver 端处理回复**(ComponentReviver::handleMessage reply 重载):

```cpp
// server/reviver/component_reviver.cpp  L228-241
uint8 returnCode;
data >> returnCode;
if (returnCode == REVIVER_PING_YES)
{
	pingsToMiss_ = maxPingsToMiss_;
	if (!isAttached_)
	{
		// ... 标记 attached ...
		isAttached_ = true;
	}
}
else
{
	this->deactivate();
}
```

### 9.5 PING_YES / PING_NO 常量

```cpp
// lib/server/reviver_common.hpp  L13-14
const ReviverPriority REVIVER_PING_NO  = 0;
const ReviverPriority REVIVER_PING_YES = 1;
```

回复码使用 `ReviverPriority`(uint8)类型,值 0/1。这与优先级共用类型,但语义不同:回复码只有 0/1 两个值。

### 9.6 消息流总结

```
ComponentReviver                           ReviverSubject
     │                                           │
     │  reviverPing(priority)  [请求]            │
     │──────────────────────────────────────────►│
     │                                           │ 仲裁:accept?
     │                                           │
     │  reply(REVIVER_PING_YES/NO)               │
     │◄──────────────────────────────────────────│
     │                                           │
     │  if YES: pingsToMiss_=max; attached=true  │
     │  if NO:  deactivate()                     │
     ▼                                           ▼
```

---

## 十、被监控进程的注册方式

被监控进程(CellAppMgr / BaseAppMgr / DBAppMgr / DBApp / LoginApp)在自己的 `init` 中调用 `ReviverSubject::instance().init(...)`,完成"被恢复主体"的注册。

### 10.1 五个注册点

| 进程 | 文件 | 行号 | 调用 |
|------|------|------|------|
| CellAppMgr | `server/cellappmgr/cellappmgr.cpp` | 183 | `ReviverSubject::instance().init( &interface_, "cellAppMgr" );` |
| BaseAppMgr | `server/baseappmgr/baseappmgr.cpp` | 365 | `ReviverSubject::instance().init( &interface_, "baseAppMgr" );` |
| DBAppMgr | `server/dbappmgr/dbappmgr.cpp` | 236 | `ReviverSubject::instance().init( &(this->interface()), "dbAppMgr" );` |
| DBApp | `server/dbapp/dbapp.cpp` | 778 | `ReviverSubject::instance().init( &interface_, "dbApp" );` |
| LoginApp | `server/loginapp/loginapp.cpp` | 270 | `ReviverSubject::instance().init( &this->intInterface(), "loginApp" );` |

### 10.2 CellAppMgr 的注册上下文

```cpp
// server/cellappmgr/cellappmgr.cpp  L170-183
for (int i = 0; i < argc; ++i)
{
	if (strcmp( argv[i], "-recover" ) == 0)
	{
		isRecovery = true;
	}
	else if (strcmp( argv[i], "-machined" ) == 0)
	{
		CONFIG_INFO_MSG( "CellAppMgr::init: Started from machined\n" );
	}
}

ReviverSubject::instance().init( &interface_, "cellAppMgr" );
```

CellAppMgr 在解析 `-recover`/`-machined` 参数后立即注册 ReviverSubject。`-recover` 由 Reviver 通过 CreateMessage 设置,表示本次启动是崩溃恢复。

### 10.3 BaseAppMgr 的注册上下文

```cpp
// server/baseappmgr/baseappmgr.cpp  L359-374
if (!interface_.isGood())
{
	NETWORK_ERROR_MSG( "Failed to open internal interface.\n" );
	return false;
}

ReviverSubject::instance().init( &interface_, "baseAppMgr" );

for (int i = 0; i < argc; ++i)
{
	if (strcmp( argv[i], "-recover" ) == 0)
	{
		isRecovery_ = true;
		break;
	}
}
```

BaseAppMgr 在校验 interface 后注册 ReviverSubject,再解析 `-recover`。

### 10.4 DBAppMgr 的注册上下文

```cpp
// server/dbappmgr/dbappmgr.cpp  L226-236
Mercury::MachineDaemon::registerDeathListener( this->interface().address(),
	DBAppMgrInterface::handleLoginAppDeath, "LoginIntInterface" );

// Register revived manager app callbacks with machined
Mercury::MachineDaemon::registerBirthListener( this->interface().address(),
	DBAppMgrInterface::handleBaseAppMgrBirth, "BaseAppMgrInterface" );

Mercury::MachineDaemon::registerBirthListener( this->interface().address(),
	DBAppMgrInterface::handleCellAppMgrBirth, "CellAppMgrInterface" );

ReviverSubject::instance().init( &(this->interface()), "dbAppMgr" );
```

DBAppMgr 自身也注册了对 LoginApp/BaseAppMgr/CellAppMgr 的 birth/death 监听(用于业务联动),并注册 ReviverSubject 接受 Reviver 监控。

### 10.5 DBApp 的注册上下文

```cpp
// server/dbapp/dbapp.cpp  L771-783
bool DBApp::initReviver()
{
    MF_ASSERT( status_.status() == DBStatus::STARTING );
    MF_ASSERT( initState_ & INIT_STATE_NETWORK );

    DEBUG_MSG( "DBApp::initReviver\n" );

    ReviverSubject::instance().init( &interface_, "dbApp" );

    initState_ |= INIT_STATE_REVIVER;

    return true;
}
```

DBApp 把 ReviverSubject 的初始化单独封装在 `initReviver()` 方法中,并通过 `initState_` 状态机管理初始化进度。

### 10.6 LoginApp 的注册上下文

```cpp
// server/loginapp/loginapp.cpp  L268-270
// ---- What used to be in loginsvr.cpp

ReviverSubject::instance().init( &this->intInterface(), "loginApp" );
```

LoginApp 使用内部 interface(`intInterface_`)注册,而非外部 interface(面向客户端)。

### 10.7 注册时机总结

5 个被监控进程都在自己的 `init` 阶段(网络 interface 起来之后、主循环进入之前)调用 `ReviverSubject::init`。这样保证:
- Reviver 启动后通过 `findInterface` 能查到它们(若它们先于 Reviver 启动)。
- Reviver 发来的 ping 能被处理(ReviverSubject 已绑定 interface)。
- 若被监控进程后于 Reviver 启动,Reviver 会通过 birth 监听得知其地址,再开始 ping。

---

## 十一、主备切换 shutDownOnRevive

`shutDownOnRevive` 是 Reviver 实现主备切换的关键配置,默认 `true`。

### 11.1 配置与行为

```cpp
// server/reviver/reviver_config.cpp  L18
BW_OPTION( bool, shutDownOnRevive, true );
```

```cpp
// server/reviver/reviver.cpp  L469-473
if (Config::shutDownOnRevive())
{
	shuttingDown_ = true;
	this->shutDown();
}
```

当 `shutDownOnRevive=true` 时,Reviver 在发出一次 `CreateMessage`(恢复一个崩溃进程)后立即自我关闭。

### 11.2 为什么恢复后要关闭自己?

考虑以下场景:多 Reviver 主备部署,主 Reviver A 监控 CellAppMgr。
1. CellAppMgr 崩溃。
2. Reviver A 检测到死亡(通过 death 广播或 ping 超时)。
3. Reviver A 发送 CreateMessage 让 bwmachined 拉起新 CellAppMgr。
4. **Reviver A 自身关闭**。
5. 备 Reviver B 在 `subjectTimeout`(默认 0.2s)后,因 Reviver A 不再 ping,被 CellAppMgr 接受为新主。
6. Reviver B 继续监控新的 CellAppMgr。

**这样设计的原因**:
- **避免反复重启**:如果 Reviver A 不退出,它可能因为状态紊乱(如 `addr_` 已清空但定时器未取消干净)再次触发恢复。
- **强制主备切换**:让备 Reviver 接管,保证下次崩溃由健康的 Reviver 处理。
- **简化状态机**:Reviver 设计为"一次性看门狗",触发一次恢复后即退出,由外部(如 systemd 或 bwmachined 自身)重启 Reviver,保证下次以干净状态运行。

### 11.3 关闭流程

```cpp
// server/reviver/reviver.cpp  L419-434
void Reviver::shutDown()
{
	shuttingDown_ = true;
	mainDispatcher_.breakProcessing();  // 打破事件循环

	ComponentRevivers::iterator iter = components_.begin();
	while (iter != components_.end())
	{
		if ((*iter)->isEnabled())
		{
			(*iter)->deactivate();  // 取消所有 ping 定时器
		}
		++iter;
	}
}
```

`shutDown` 设置 `shuttingDown_` 标记、打破事件循环、deactivate 所有 ComponentReviver。`shuttingDown_` 会被 `revive()` 检查:

```cpp
// server/reviver/reviver.cpp  L442-447
if (shuttingDown_)
{
	INFO_MSG( "Reviver::revive: "
		"Trying to revive a process while shutting down.\n" );
	return;
}
```

防止关闭过程中其他 ComponentReviver 触发的恢复。

### 11.4 shutDownOnRevive=false 的场景

若设置 `shutDownOnRevive=false`,Reviver 在恢复一个进程后继续运行,继续监控(包括新启动的进程)。这种模式下:
- 单 Reviver 部署时更友好(不需要外部重启 Reviver)。
- 但丧失了"主备自动切换"能力,主 Reviver 故障后需要人工介入。
- 适合单机部署或成本敏感场景。

### 11.5 主备切换的完整时序

```
时间轴:

t0: Reviver A(主,priority=1) 与 Reviver B(备,priority=2) 同时运行
    CellAppMgr 的 ReviverSubject 记录: reviverAddr_=A, priority_=1

t1: CellAppMgr 崩溃
    bwmachined 广播 death → Reviver A 的 CellAppMgrReviver 收到
    Reviver A: revive("cellappmgr")
        ├─ CreateMessage → bwmachined → fork 新 CellAppMgr(带 -recover)
        └─ shutDownOnRevive=true → Reviver A 关闭

t2: Reviver A 停止 ping CellAppMgr
    CellAppMgr 的 ReviverSubject: lastPingTime_ 不再更新

t3: 新 CellAppMgr 启动,bwmachined 广播 birth
    Reviver A 已关闭,只有 Reviver B 的 CellAppMgrReviver 收到
    Reviver B: addr_ = 新地址, activate

t4: Reviver B 开始 ping 新 CellAppMgr(携带 priority=1)
    CellAppMgr 的 ReviverSubject:
        srcAddr=B, priority=1
        reviverAddr_=A(旧主), priority_=1
        accept = (srcAddr == reviverAddr_)? 否
        priority < priority_? 1<1 否
        当前主超时? (currentPingTime - lastPingTime_) > msTimeout_?
            是(A 已停止 ping 超过 0.2s)
        accept = true
        reviverAddr_ = B, priority_ = 1
        回 YES

t5: Reviver B 收到 YES,isAttached_=true,接管监控
```

> 注意:Reviver B 的 priority 可能与 Reviver A 相同(都是 1,因为 activate 时 `++priority` 从 1 开始)。仲裁关键在于"当前主超时"分支,而非优先级抢占。

---

## 十二、REATTACH 状态处理与优先级重排

`TIMEOUT_REATTACH` 是 Reviver 的周期性"重新评估"定时器,每 `reattachPeriod`(默认 10s)触发一次。

### 12.1 handleTimeout 整体结构

```cpp
// server/reviver/reviver.cpp  L297-394
void Reviver::handleTimeout( TimerHandle handle, void * arg )
{
	typedef BW::map< ReviverPriority, ComponentReviver * > Map;

	switch (uintptr(arg))
	{
		case TIMEOUT_REATTACH:
		{
			// ... 见 12.2 ...
		}
		break;

		case TIMEOUT_TICK:
		{
			this->advanceTime();
			break;
		}
	}
}
```

两个定时器:
- `TIMEOUT_REATTACH`:周期 `reattachPeriod`(默认 10s),处理 ComponentReviver 状态重排。
- `TIMEOUT_TICK`:周期 `1/updateHertz`(通常 10Hz,即 100ms),调用 `advanceTime()` 推进服务器时间。

### 12.2 REATTACH 处理流程

```cpp
// server/reviver/reviver.cpp  L303-386
case TIMEOUT_REATTACH:
{
	Map activeSet;          // 已激活的 ComponentReviver(按 priority 排序)
	ComponentRevivers deactive;  // 未激活的

	components_ = *g_pComponentRevivers;  // 重新拷贝全局链表
	ComponentRevivers::iterator iter = components_.begin();
	ComponentRevivers::iterator endIter = components_.end();

	// 1) 分类:已激活(priority>0)入 activeSet,未激活入 deactive
	while (iter != endIter)
	{
		if ((*iter)->isEnabled())
		{
			ReviverPriority priority = (*iter)->priority();

			if (priority > 0)
			{
				activeSet[ priority ] = (*iter);
			}
			else
			{
				deactive.push_back( *iter );
			}
		}
		++iter;
	}

	// 2) 调整优先级:让 activeSet 中的优先级连续从 1 开始
	{
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

		// 3) 随机打乱 deactive,追加到优先级队列末尾
		std::random_shuffle( deactive.begin(), deactive.end() );

		iter = deactive.begin();
		endIter = deactive.end();

		while (iter != endIter)
		{
			(*iter)->activate( ++priority );
			++iter;
		}
	}

	// 4) 若状态有变,打印 summary
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
		else
		{
			INFO_MSG( "No attached components\n" );
		}

		isDirty_ = false;
	}
}
```

### 12.3 优先级重排的意义

REATTACH 周期做的事情:
1. **重新拷贝全局链表**:理论上 `g_pComponentRevivers` 不会变(5 个特化类是全局变量),但这里仍然重新拷贝,保证一致性。
2. **分类**:已激活(`priority>0`)与未激活(`priority==0`)分开。
3. **紧凑化优先级**:让已激活的优先级连续从 1 开始。例如原本是 1,3,5(中间有脱离的),重排为 1,2,3。
4. **随机打乱未激活的并激活**:未激活的 ComponentReviver 随机排序后,追加到优先级队列末尾(从 `priority+1` 开始递增)。这给"未激活但已知地址"的组件一个被激活的机会。
5. **打印 summary**:`isDirty_` 为 true 时打印当前附着组件列表,然后清零。

### 12.4 优先级数值的语义

- `priority=0`:未激活(从未 activate,或已 deactivate)。
- `priority=1`:最高优先级(主 Reviver)。
- `priority=2,3,...`:递减优先级。

`ReviverSubject` 中 `priority < priority_` 判断抢占,所以数值越小优先级越高。`0xff`(255)是 `ReviverSubject` 构造时的初始值,表示"尚未有主":

```cpp
// lib/server/reviver_subject.cpp  L32
priority_( 0xff ),
```

### 12.5 isDirty_ 的作用

```cpp
// server/reviver/reviver.cpp  L51
void markAsDirty()			{ isDirty_ = true; }
```

`markAsDirty` 在以下场景被调用:
- `ComponentReviver::deactivate`(脱离时)
- `ComponentReviver::handleMessage`(首次附着时)

REATTACH 周期只在 `isDirty_` 为 true 时打印 summary,避免每 10s 都刷屏。状态稳定后只在变化时打印一次。

### 12.6 TIMEOUT_TICK 的作用

```cpp
// server/reviver/reviver.cpp  L388-392
case TIMEOUT_TICK:
{
	this->advanceTime();
	break;
}
```

`advanceTime()` 是 `ServerApp` 基类的方法,推进服务器游戏时间。Reviver 虽然不参与游戏逻辑,但仍需推进时间(用于 watcher、统计等)。tick 频率由 `Config::updateHertz()` 决定(通常 10Hz)。

---

## 十三、设计亮点与注意事项

### 13.1 设计亮点

#### 13.1.1 自注册的 ComponentReviver

5 个特化类通过 `IntrusiveObject` 自注册到全局链表 `g_pComponentRevivers`,`Reviver::init` 直接拷贝即可。新增被监控组件类型只需:
1. 在组件 Interface 中声明 `reviverPing` 消息(`MF_REVIVER_PING_MSG`)。
2. 在 `reviver_interface.hpp` 中添加 `BW_REVIVER_MSGS( NewComponent )`。
3. 在 `component_reviver.cpp` 中添加 `MF_REVIVER_HANDLER( newComp, NewComponent, "newcomp" )`。
4. 在被监控进程的 `init` 中调用 `ReviverSubject::instance().init( &interface_, "newComp" )`。

无需修改 `Reviver` 主类,扩展性极佳。

#### 13.1.2 双死亡检测的互补

birth/death 广播(快但不可靠)与 ping 心跳(慢但可靠)互补,既保证快速响应,又保证不漏报。`wasAttached` 守门避免误判。

#### 13.1.3 优先级仲裁实现细粒度主备

每个被监控进程的 ReviverSubject 独立仲裁,允许"按组件分散主备":CellAppMgr 的主可以是 Reviver A,BaseAppMgr 的主可以是 Reviver B。这比"全局主备"更灵活,负载更均衡。

#### 13.1.4 委托 bwmachined 实际拉起

Reviver 不直接 fork,而是发 CreateMessage 给 bwmachined。好处:
- Reviver 不需要 root 权限(bwmachined 才需要)。
- 进程环境(working dir、env、uid)由 bwmachined 统一管理,避免 Reviver 状态泄漏。
- bwmachined 负责实际的进程探测与 birth/death 广播,Reviver 只是消费者。

#### 13.1.5 Components tags 按机器能力部署

`queryMachinedSettings` 让本机 bwmachined 的 `Components` tag 决定 Reviver 监控哪些组件。这使得"在 DB 机器上只跑 DBApp 监控,在 App 机器上只跑 CellAppMgr/BaseAppMgr 监控"无需修改 Reviver 启动参数,纯配置驱动。

#### 13.1.6 shutDownOnRevive 强制健康度

恢复后立即关闭自身,强制主备切换,避免"带病运行"的 Reviver 反复触发错误恢复。这是"宁可切换不可疑"的保守策略。

#### 13.1.7 每组件独立配置覆盖

`reviver/<component>/pingPeriod` 等路径允许为不同组件设置不同的监控参数。例如 DBApp(状态重要、重启慢)可以用更长的 timeout,LoginApp(轻量)可以用更短的 pingPeriod。

### 13.2 注意事项

#### 13.2.1 pingPeriod 必须小于 subjectTimeout

三处校验(`ReviverConfig::postInit`、`ComponentReviver::init`、`ReviverSubject::init`)都要求 `pingPeriod < subjectTimeout`,否则 CRITICAL_MSG 终止。原因:Reviver 端每个 pingPeriod 发一次 ping,被监控进程端若 subjectTimeout < pingPeriod,则每次 ping 都会被判超时切换,导致主备震荡。

#### 13.2.2 timeoutInPings 已废弃

`reviver/timeoutInPings` 已废弃,应使用 `reviver/timeout`。`postInit` 中若 `timeoutInPings==0` 则由 `timeout/pingPeriod` 推导;若用户显式设置则打印废弃警告。

#### 13.2.3 recover_=1 固定带 -recover

`Reviver::revive` 中 `cm.recover_ = 1` 是硬编码,所有恢复的进程都带 `-recover` 启动。被监控进程必须正确处理 `-recover` 参数(进入恢复模式),否则可能以全新状态启动,丢失数据。

#### 13.2.4 shutDownOnRevive 默认 true 的运维影响

默认 `shutDownOnRevive=true` 意味着 Reviver 触发一次恢复后即退出。运维上需要:
- 通过 systemd / supervisor / bwmachined 自身重启 Reviver,保证 Reviver 持续可用。
- 否则一次崩溃后 Reviver 就消失了,后续崩溃无人监控。

若不希望 Reviver 退出,设置 `reviver/shutDownOnRevive=false`。

#### 13.2.5 多 Reviver 部署的优先级

多 Reviver 主备部署时,各 Reviver 的 `priority` 由 `Reviver::init` 中 `activate(++priority)` 决定,顺序由 `g_pComponentRevivers` 中特化类的构造顺序决定(即 `MF_REVIVER_HANDLER` 宏的书写顺序)。**不同 Reviver 进程之间的优先级比较是逐组件的**,且各 Reviver 进程的 priority 数值可能相同(都从 1 开始)。仲裁的关键在于"当前主超时"分支,而非优先级抢占。

若希望明确指定某 Reviver 为绝对主,需要修改代码(目前不支持配置优先级数值)。

#### 13.2.6 birth/death 消息的 UDP 不可靠

bwmachined 的 birth/death 广播基于 UDP,可能丢包。因此 ping 心跳作为兜底不可或缺。极端情况下,若 death 通知丢失且被监控进程假死(不响应 ping),需要等 `maxPingsToMiss * pingPeriod` 才能恢复(默认约 3s)。

#### 13.2.7 revive 中 wasAttached 的微妙

`ComponentReviver::revive` 中 `if (wasAttached)` 守门:只有曾经附着(收到过 YES)才真正恢复。这意味着:
- Reviver 启动时被监控进程未运行 → 不会主动拉起(等人工启动或 bwmachined 自启动)。
- 被监控进程启动中、尚未响应 ping 时崩溃 → 不会恢复(因为从未附着)。

这是保守策略,避免反复重启未就绪的进程。但也意味着"首次启动"必须由人工或部署系统保证。

#### 13.2.8 Reviver 自身不被监控

Reviver 本身没有 ReviverSubject(它不是被恢复主体),因此 Reviver 崩溃后只能靠外部(systemd / bwmachined)重启。这是合理的:看门狗不能看门自己(否则死循环)。

#### 13.2.9 LoginApp 的 interface 命名

LoginApp 使用 `LoginIntInterface`(内部)而非 `LoginInterface`(外部,面向客户端)。`MF_REVIVER_HANDLER2( loginApp, Login, LoginInt, "loginapp" )` 中 COMPONENT2 为 `LoginInt`,因此 `pPingMessage_ = &LoginIntInterface::reviverPing`。这是为了避免 ping 消息暴露到面向客户端的 interface 上。

#### 13.2.10 ComponentReviver 的 deactivate 不触发 revive

`deactivate` 仅取消定时器与清零优先级,不调用 `revive`。`revive` 仅由 death 消息或 ping 超时触发。deactivate 的触发场景:
- 收到 PING_NO(被监控进程拒绝本 Reviver)。
- `Reviver::shutDown` 关闭时。
- `ComponentReviver::revive` 内部(先 deactivate 再恢复)。

### 13.3 性能考量

| 维度 | 默认值 | 说明 |
|------|--------|------|
| ping 频率 | 10Hz(每 0.1s) | 每个 ComponentReviver 独立定时器,5 个组件共 50 ping/s |
| REATTACH 频率 | 0.1Hz(每 10s) | 全局一个定时器 |
| TICK 频率 | 10Hz(每 100ms) | 全局一个定时器 |
| 网络流量 | 极低 | ping 消息仅 priority(1 字节)+ UDP 头;回复仅 returnCode(1 字节) |
| CPU 占用 | 极低 | 主要在事件循环与定时器回调 |

5 个 ComponentReviver 各自一个 ping 定时器,默认每秒共 50 次 ping,对网络与 CPU 的压力可忽略。

### 13.4 与 CellApp/BaseApp 的关系

**注意**:Reviver **不监控 CellApp 和 BaseApp**(空间/实体承载进程)。这两类进程的容错由各自的管理器负责:
- CellApp 崩溃由 CellAppMgr 处理(通过 `handleCellAppDeath` 重新分配 Cell)。
- BaseApp 崩溃由 BaseAppMgr 处理(通过 BaseApp 备份机制恢复实体)。

Reviver 只监控"管理器/单例进程":CellAppMgr、BaseAppMgr、DBAppMgr、DBApp、LoginApp。这些进程数量少(通常各 1 个),但崩溃影响大,适合看门狗模式。

### 13.5 与 bwmachined 的依赖

Reviver 强依赖本机 bwmachined:
- `registerWithMachined` 注册自身。
- `registerBirthListener`/`registerDeathListener` 注册监听。
- `findInterface` 查询进程地址。
- `TagsMessage` 查询能力。
- `CreateMessage` 委托拉起。

bwmachined 不在则 Reviver 无法工作。因此 bwmachined 是更高优先级的守护进程,通常由 systemd/init 直接管理。

---

## 附录 A:关键文件路径速查

### A.1 Reviver 进程主体

| 文件 | 绝对路径 |
|------|---------|
| 入口 | `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\reviver\main.cpp` |
| Reviver 类声明 | `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\reviver\reviver.hpp` |
| Reviver 类实现 | `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\reviver\reviver.cpp` |
| ComponentReviver 声明 | `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\reviver\component_reviver.hpp` |
| ComponentReviver 实现 | `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\reviver\component_reviver.cpp` |
| ReviverConfig 声明 | `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\reviver\reviver_config.hpp` |
| ReviverConfig 实现 | `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\reviver\reviver_config.cpp` |
| ReviverInterface | `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\reviver\reviver_interface.hpp` |

### A.2 被监控进程共用

| 文件 | 绝对路径 |
|------|---------|
| ReviverSubject 声明 | `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\server\reviver_subject.hpp` |
| ReviverSubject 实现 | `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\server\reviver_subject.cpp` |
| ReviverCommon | `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\server\reviver_common.hpp` |

### A.3 bwmachined 交互

| 文件 | 绝对路径 |
|------|---------|
| MachineGuard 消息 | `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\network\machine_guard.hpp` |
| machined_utils 声明 | `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\network\machined_utils.hpp` |
| machined_utils 实现 | `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\lib\network\machined_utils.cpp` |

### A.4 被监控进程注册点

| 进程 | 绝对路径 | 行号 |
|------|---------|------|
| CellAppMgr | `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\cellappmgr\cellappmgr.cpp` | 183 |
| BaseAppMgr | `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\baseappmgr\baseappmgr.cpp` | 365 |
| DBAppMgr | `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\dbappmgr\dbappmgr.cpp` | 236 |
| DBApp | `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\dbapp\dbapp.cpp` | 778 |
| LoginApp | `j:\Work\BigWorld-Engine-14.4.1\programming\bigworld\server\loginapp\loginapp.cpp` | 270 |

---

## 附录 B:常见误区澄清

### B.1 "Reviver 监控所有服务器进程"

**错误**。Reviver 只监控 5 类:CellAppMgr、BaseAppMgr、DBAppMgr、DBApp、LoginApp。CellApp、BaseApp 等数据平面进程由各自管理器(CellAppMgr/BaseAppMgr)处理容错,不经过 Reviver。

### B.2 "Reviver 直接 fork 进程"

**错误**。Reviver 自身不 fork,而是发 `CreateMessage` 给本机 bwmachined,由后者实际 fork+exec。Reviver 仅是"决策者",bwmachined 是"执行者"。

### B.3 "death 广播就够了,为什么还要 ping"

**不完整**。death 广播基于 UDP 可能丢包,且无法检测进程假死(未退出但卡死)。ping 心跳作为兜底,保证可靠性。

### B.4 "优先级数值越大优先级越高"

**错误**。`ReviverPriority` 是 uint8,**数值越小优先级越高**。`ReviverSubject::handleMessage` 中 `priority < priority_` 判断抢占,即新来的优先级数值更小才抢占。

### B.5 "timeoutInPings 应该显式配置"

**过时**。`timeoutInPings` 已废弃,应使用 `timeout`(秒)。`postInit` 会自动推导 `timeoutInPings = round(timeout / pingPeriod)`。显式设置 `timeoutInPings` 会触发废弃警告。

### B.6 "Reviver 崩溃后会被自动恢复"

**错误**。Reviver 自身没有 ReviverSubject,不被任何 Reviver 监控。Reviver 崩溃后只能靠外部(systemd / bwmachined 自身 / 运维)重启。这是设计上的取舍:看门狗不能看门自己。

### B.7 "shutDownOnRevive=false 是推荐配置"

**视场景**。默认 `true` 强制主备切换,适合多 Reviver 主备部署。单 Reviver 部署时设 `false` 更友好(无需外部重启 Reviver),但丧失主备切换能力。

### B.8 "所有被监控进程的主 Reviver 必须相同"

**错误**。每个被监控进程的 ReviverSubject 独立仲裁,允许 CellAppMgr 的主是 Reviver A,BaseAppMgr 的主是 Reviver B。这是"按组件分散主备"的细粒度策略。

### B.9 "Reviver 启动时被监控进程必须已运行"

**错误**。`ComponentReviver::init` 中 `findInterface` 失败不阻止 init 继续(只是 `isOkay=false`)。Reviver 会注册 birth 监听,被监控进程后续启动时会收到 birth 通知,补全地址后再 activate。但 `revive` 中 `wasAttached` 守门意味着:首次启动必须由人工或部署系统保证,Reviver 不会主动拉起从未运行过的进程。

### B.10 "LoginApp 用 LoginInterface 接收 ping"

**错误**。LoginApp 使用 `LoginIntInterface`(内部 interface)接收 ping,而非 `LoginInterface`(外部,面向客户端)。这是为了避免 ping 消息暴露到公网。`MF_REVIVER_HANDLER2( loginApp, Login, LoginInt, "loginapp" )` 中 COMPONENT2 为 `LoginInt`。

### B.11 "MF_REVIVER_HANDLER 是函数"

**错误**。`MF_REVIVER_HANDLER` 是宏,展开为一个 `ComponentReviver` 子类定义加一个全局实例声明。5 个特化类(`CellAppMgrReviver` 等)在 `component_reviver.cpp` 中通过该宏生成,实例(`g_reviverOfCellAppMgr` 等)是全局变量,程序启动时自动构造并自注册。

### B.12 "Reviver 的 REATTACH 定时器用于检测死亡"

**错误**。REATTACH 定时器(周期 10s)用于"重新评估 ComponentReviver 状态、重排优先级、打印 summary",**不直接检测死亡**。死亡检测由 death 广播(被动)与 ComponentReviver 自己的 ping 定时器(主动,周期 0.1s)负责。

---

## 附录 C:配置项速查表

| 配置路径 | 类型 | 默认 | 说明 |
|---------|------|------|------|
| `reviver/reattachPeriod` | float | 10.0 | REATTACH 周期(秒) |
| `reviver/pingPeriod` | float | 0.1 | ping 周期(秒) |
| `reviver/subjectTimeout` | float | 0.2 | 主 Reviver 超时(秒) |
| `reviver/shutDownOnRevive` | bool | true | 恢复后是否关闭 Reviver |
| `reviver/timeout` | float | 3.0 | 恢复超时(秒) |
| `reviver/timeoutInPings` | int | 0 | ping 次数超时(已废弃,0 表示由 timeout 推导) |
| `reviver/<component>/pingPeriod` | float | 同上 | 特定组件的 ping 周期 |
| `reviver/<component>/subjectTimeout` | float | 同上 | 特定组件的 subject 超时 |
| `reviver/<component>/timeoutInPings` | int | 同上 | 特定组件的 ping 次数超时(已废弃) |

`<component>` 取值:`cellAppMgr`、`baseAppMgr`、`dbAppMgr`、`dbApp`、`loginApp`。

---

## 附录 D:消息处理表

### D.1 Reviver 接收的消息(10 条 birth/death)

| 消息 | 处理者 | 处理方法 | 触发动作 |
|------|--------|---------|---------|
| `handleCellAppMgrBirth` | `g_reviverOfCellAppMgr` | `ComponentReviver::handleMessage` (input) | 更新 `addr_`,打印日志 |
| `handleCellAppMgrDeath` | `g_reviverOfCellAppMgr` | `ComponentReviver::handleMessage` (input) | 若 `addr` 匹配则 `revive()` |
| `handleBaseAppMgrBirth` | `g_reviverOfBaseAppMgr` | 同上 | 同上 |
| `handleBaseAppMgrDeath` | `g_reviverOfBaseAppMgr` | 同上 | 同上 |
| `handleDBAppMgrBirth` | `g_reviverOfDBAppMgr` | 同上 | 同上 |
| `handleDBAppMgrDeath` | `g_reviverOfDBAppMgr` | 同上 | 同上 |
| `handleDBAppBirth` | `g_reviverOfDBApp` | 同上 | 同上 |
| `handleDBAppDeath` | `g_reviverOfDBApp` | 同上 | 同上 |
| `handleLoginBirth` | `g_reviverOfLogin` | 同上 | 同上 |
| `handleLoginDeath` | `g_reviverOfLogin` | 同上 | 同上 |

### D.2 Reviver 发送的消息

| 消息 | 目标 | 处理者 | 携带数据 |
|------|------|--------|---------|
| `reviverPing`(请求) | 被监控进程 | `ReviverSubject::handleMessage` | `ReviverPriority priority` |
| `CreateMessage` | bwmachined | bwmachined | name, config, uid, recover=1 |
| `TagsMessage` | bwmachined | bwmachined | 查询 "Components" tag |

### D.3 Reviver 接收的回复

| 回复 | 来源 | 处理方法 | 携带数据 | 处理动作 |
|------|------|---------|---------|---------|
| `reviverPing` 回复 | 被监控进程 | `ComponentReviver::handleMessage` (reply) | `uint8 returnCode` | YES: 重置 `pingsToMiss_`,设 `isAttached_`;NO: `deactivate()` |
| `TagsMessage` 回复 | bwmachined | `Reviver::TagsHandler::onTagsMessage` | tags 列表 | 启用/禁用 ComponentReviver |

---

## 附录 E:定时器一览

| 定时器 | 周期 | 触发方法 | 用途 |
|--------|------|---------|------|
| `timerHandle_` (REATTACH) | `reattachPeriod`(默认 10s) | `Reviver::handleTimeout` (TIMEOUT_REATTACH) | 重排优先级、打印 summary |
| `tickTimer_` (TICK) | `1/updateHertz`(通常 100ms) | `Reviver::handleTimeout` (TIMEOUT_TICK) | 推进服务器时间 |
| `ComponentReviver::timerHandle_` | `pingPeriod`(默认 0.1s) | `ComponentReviver::handleTimeout` | 发送 ping / 检测超时 |

---

## 附录 F:类继承关系图

```
ServerApp (server/server_app.hpp)
    │
    └──► Reviver (server/reviver/reviver.hpp)
              │  + TimerHandler
              │  + Singleton<Reviver>
              │
              └──► TagsHandler (内部类, MachineGuardMessage::ReplyHandler)


Mercury::ShutdownSafeReplyMessageHandler
    │
    └──► ComponentReviver (server/reviver/component_reviver.hpp)
              │  + TimerHandler
              │  + Mercury::InputMessageHandler
              │  + IntrusiveObject<ComponentReviver>
              │
              ├──► CellAppMgrReviver   (g_reviverOfCellAppMgr)
              ├──► BaseAppMgrReviver   (g_reviverOfBaseAppMgr)
              ├──► DBAppMgrReviver     (g_reviverOfDBAppMgr)
              ├──► DBAppReviver        (g_reviverOfDBApp)
              └──► LoginReviver        (g_reviverOfLogin)


Mercury::InputMessageHandler
    │
    └──► ReviverSubject (lib/server/reviver_subject.hpp, 单例)
              │
              └── 在每个被监控进程内:
                  ├── CellAppMgr::ReviverSubject::instance_
                  ├── BaseAppMgr::ReviverSubject::instance_
                  ├── DBAppMgr::ReviverSubject::instance_
                  ├── DBApp::ReviverSubject::instance_
                  └── LoginApp::ReviverSubject::instance_


MachineGuardMessage (lib/network/machine_guard.hpp)
    │
    ├──► CreateMessage        (Reviver → bwmachined, 创建进程)
    ├──► CreateWithArgsMessage(CreateMessage 子类)
    ├──► TagsMessage          (Reviver ↔ bwmachined, 查询 tags)
    ├──► ListenerMessage      (registerBirth/DeathListener 底层)
    ├──► ProcessMessage       (进程操作)
    ├──► ProcessStatsMessage  (进程统计)
    ├──► SignalMessage        (信号)
    └──► UserMessage          (用户)
```

---

## 附录 G:状态机

### G.1 ComponentReviver 状态机

```
                    ┌──────────────────┐
                    │  Uninitialised   │  构造后
                    │  isEnabled_=true │
                    │  isAttached_=false│
                    │  priority_=0     │
                    │  timerHandle_=null│
                    └────────┬─────────┘
                             │ init()
                             ▼
                    ┌──────────────────┐
                    │  Inited          │  findInterface 成功
                    │  addr_=已知/未知 │  birth/death listener 已注册
                    └────────┬─────────┘
                             │ activate(priority)
                             ▼
                    ┌──────────────────┐
        ┌──────────►│  Active          │  timerHandle_ 已启动
        │           │  pingsToMiss_=max│  priority_>0
        │           │                  │
        │           └────────┬─────────┘
        │                    │
        │       ┌────────────┼────────────┐
        │       │            │            │
        │       ▼            ▼            ▼
        │  收到 YES      收到 NO      ping 超时
        │  pingsToMiss_=max  │      (pingsToMiss_==0)
        │  isAttached_=true  │            │
        │       │            │            │
        │       └────────────┴────────────┘
        │                    │
        │                    ▼
        │           ┌──────────────────┐
        │           │  revive()        │
        │           │  deactivate()    │
        │           │  addr_=0:0       │
        │           │  if wasAttached: │
        │           │    Reviver::revive│
        │           └────────┬─────────┘
        │                    │
        │                    ▼
        │           ┌──────────────────┐
        │           │  Deactivated     │
        │           │  isAttached_=false│
        │           │  priority_=0     │
        │           │  timerHandle_=null│
        └───────────┘  (REATTACH 周期可重新 activate)
```

### G.2 ReviverSubject 仲裁状态机

```
                    ┌──────────────────┐
                    │  No Master       │  构造后
                    │  reviverAddr_=0:0│
                    │  priority_=0xff  │
                    │  lastPingTime_=0 │
                    └────────┬─────────┘
                             │ 收到 ping
                             ▼
                    ┌──────────────────┐
                    │  Has Master      │
        ┌──────────►│  reviverAddr_=A  │
        │           │  priority_=P_A   │
        │           │  lastPingTime_=t │
        │           └────────┬─────────┘
        │                    │
        │                    │ 收到新 ping(来自 B, priority=P_B)
        │                    ▼
        │           ┌──────────────────┐
        │           │  仲裁:          │
        │           │  srcAddr==A?     │──YES──► 回 YES,更新 lastPingTime
        │           └────────┬─────────┘
        │                    │ NO
        │                    ▼
        │           ┌──────────────────┐
        │           │  P_B < P_A?      │──YES──► 抢占:reviverAddr_=B,
        │           │                  │         priority_=P_B, 回 YES
        │           └────────┬─────────┘
        │                    │ NO
        │                    ▼
        │           ┌──────────────────┐
        │           │  (t-now) > msTimeout_?──YES──► 主超时:
        │           │                  │         reviverAddr_=B,
        │           │                  │         priority_=P_B, 回 YES
        │           └────────┬─────────┘
        │                    │ NO
        │                    ▼
        │           ┌──────────────────┐
        │           │  回 NO           │
        │           └──────────────────┘
        │
        └───────────►  (循环)
```

---

## 附录 H:启动时序

### H.1 Reviver 启动时序

```
t0: main() 调用
t1: bwMainT<Reviver>(argc, argv)
t2: Reviver 构造(ServerApp 基类 + shuttingDown_=false + isDirty_=true)
t3: Reviver::init(argc, argv)
    ├─ ServerApp::init
    ├─ ReviverInterface::registerWithInterface
    ├─ ReviverInterface::registerWithMachined
    ├─ components_ = *g_pComponentRevivers  (5 个特化类)
    ├─ queryMachinedSettings  (查询 Components tags)
    │   └─ TagsMessage → bwmachined → onTagsMessage
    │       └─ 据此启用/禁用 ComponentReviver
    ├─ addWatchers / BW_REGISTER_WATCHER
    ├─ 解析 --add / --del
    ├─ 对每个启用组件:ComponentReviver::init
    │   ├─ 读 pingPeriod/subjectTimeout/timeoutInPings
    │   ├─ initInterfaceElements  (绑定 birth/death/ping)
    │   ├─ findInterface  (查询当前已存在进程)
    │   └─ registerBirthListener / registerDeathListener
    ├─ 对每个启用组件:activate(++priority)
    │   └─ 启动 ping 定时器(若 addr_ 已知)
    ├─ 安装 REATTACH 定时器(10s)
    └─ 安装 TICK 定时器(100ms)
t4: Reviver::run
    ├─ hasEnabledComponents 检查
    └─ ServerApp::run  (进入事件循环)
```

### H.2 被监控进程启动时序(以 CellAppMgr 为例)

```
t0: bwmachined fork CellAppMgr(可能由 Reviver 通过 CreateMessage 触发,带 -recover)
t1: CellAppMgr::init
    ├─ ServerApp::init
    ├─ 解析 -recover / -machined
    ├─ ReviverSubject::init(&interface_, "cellAppMgr")
    │   ├─ 读 reviver/cellAppMgr/subjectTimeout
    │   ├─ 校验 pingPeriod < subjectTimeout
    │   └─ 设置 msTimeout_
    ├─ ... 其他初始化 ...
    └─ 进入主循环
t2: bwmachined 探测到 CellAppMgrInterface,广播 birth
    └─ Reviver 的 CellAppMgrReviver 收到 handleCellAppMgrBirth
        └─ addr_ = CellAppMgr 地址
t3: Reviver 的 CellAppMgrReviver activate(若尚未激活)
    └─ 启动 ping 定时器
t4: 第一个 ping 周期
    ├─ ComponentReviver::handleTimeout: --pingsToMiss_, send ping(priority=1)
    └─ CellAppMgr::ReviverSubject::handleMessage
        ├─ srcAddr==reviverAddr_? (首次:reviverAddr_=0:0,否)
        ├─ priority(1) < priority_(0xff)? 是 → accept=true
        ├─ reviverAddr_ = Reviver 地址, priority_ = 1
        └─ 回 REVIVER_PING_YES
t5: Reviver 收到 YES
    ├─ pingsToMiss_ = maxPingsToMiss_(30)
    ├─ isAttached_ = true(首次)
    └─ markAsDirty() → 下次 REATTACH 打印 summary
```

### H.3 进程崩溃恢复时序

```
t0: CellAppMgr 崩溃(进程退出)
t1: bwmachined 探测到进程退出,广播 death
    └─ Reviver 的 CellAppMgrReviver 收到 handleCellAppMgrDeath
        ├─ addr(死亡地址) == addr_? 是
        └─ revive()
            ├─ wasAttached = isAttached_(true)
            ├─ deactivate()(取消 ping 定时器,priority_=0)
            ├─ addr_ = 0:0
            └─ wasAttached? 是 → Reviver::revive("cellappmgr")
                ├─ CreateMessage(uid, recover_=1, name="cellappmgr", config)
                ├─ sendAndRecv → bwmachined(127.0.0.1)
                │   └─ bwmachined fork+exec 新 CellAppMgr(带 -recover)
                └─ shutDownOnRevive=true? 是 → Reviver::shutDown()
                    ├─ shuttingDown_ = true
                    ├─ breakProcessing()(打破事件循环)
                    └─ 对所有 ComponentReviver deactivate()
t2: Reviver 退出
t3: bwmachined 探测到新 CellAppMgr 启动,广播 birth
    └─ 备 Reviver(若有)收到 handleCellAppMgrBirth
        └─ addr_ = 新地址
t4: 备 Reviver activate 并 ping 新 CellAppMgr
    └─ 新 CellAppMgr 的 ReviverSubject:
        ├─ priority_(0xff,尚未有主)或旧主超时
        ├─ accept = true
        └─ 回 YES,备 Reviver 接管
```

### H.4 主备切换时序

```
t0: Reviver A(主) 与 Reviver B(备) 同时监控 CellAppMgr
    CellAppMgr.ReviverSubject: reviverAddr_=A, priority_=1
    Reviver A: isAttached_=true(收到 YES)
    Reviver B: isAttached_=false(收到 NO,已 deactivate)

t1: Reviver A 崩溃(或网络分区)
    CellAppMgr.ReviverSubject: lastPingTime_ 不再更新

t2: Reviver B 的 REATTACH 周期触发
    └─ CellAppMgrReviver activate(priority=1)
        └─ 启动 ping 定时器(若已停)

t3: Reviver B 发送 ping(priority=1)
    └─ CellAppMgr.ReviverSubject::handleMessage
        ├─ srcAddr(B) == reviverAddr_(A)? 否
        ├─ priority(1) < priority_(1)? 否
        ├─ (now - lastPingTime_) > msTimeout_(200ms)? 是
        ├─ accept = true
        ├─ reviverAddr_ = B, priority_ = 1
        └─ 回 YES

t4: Reviver B 收到 YES
    ├─ isAttached_ = true(首次)
    └─ 接管监控职责
```

---

## 附录 I:恢复场景汇总

| 场景 | 触发渠道 | wasAttached | 是否恢复 | 说明 |
|------|---------|-------------|---------|------|
| 进程正常运行时崩溃 | death 广播 | true | 是 | 典型场景,快速恢复 |
| 进程假死(不响应 ping) | ping 超时 | true | 是 | death 广播无法检测,靠 ping 兜底 |
| death 广播丢包 | ping 超时 | true | 是 | ping 兜底,延迟约 timeout |
| Reviver 启动时进程未运行 | - | false | 否 | wasAttached 守门,不主动拉起 |
| 进程启动中崩溃(未响应首个 ping) | death 广播 | false | 否 | wasAttached 守门,避免误判 |
| 备 Reviver 收到 NO | - | false | 否 | PING_NO 触发 deactivate,不恢复 |
| 主 Reviver 故障 | - | - | - | 备 Reviver 通过 subjectTimeout 接管,不恢复主 Reviver |

---

## 附录 J:与其他子系统的对比

| 维度 | Reviver | CellAppMgr/BaseAppMgr(管理器) | bwmachined |
|------|---------|-------------------------------|-----------|
| 职责 | 看门狗:拉起崩溃进程 | 业务管理:负载均衡、Cell 分配 | 系统守护:进程 fork、birth/death 广播 |
| 监控对象 | 5 类单例进程(CellAppMgr 等) | CellApp/BaseApp 等多实例进程 | 本机所有 BigWorld 进程 |
| 死亡检测 | death 广播 + ping 心跳 | death listener(被动) | 进程退出探测(内核信号) |
| 恢复方式 | CreateMessage 委托 bwmachined | 业务级恢复(重新分配 Cell/实体) | fork+exec |
| 主备支持 | 是(ReviverSubject 优先级仲裁) | 部分(CellAppMgr 单例,BaseAppMgr 单例) | 否(本机单例) |
| 配置位置 | `reviver/` 配置段 | 各管理器自己的配置段 | `bwmachined.conf` |

---

## 结语

Reviver 是 BigWorld 服务器集群的"看门狗",通过 **双死亡检测(birth/death 广播 + ping 心跳)**、**优先级仲裁(ReviverSubject)**、**委托 bwmachined 拉起(CreateMessage)** 三大机制,实现了对 5 类关键单例进程(CellAppMgr / BaseAppMgr / DBAppMgr / DBApp / LoginApp)的自动恢复与主备热备。

其设计亮点在于:
- **自注册的 ComponentReviver** 模式,扩展性极佳;
- **被动广播 + 主动 ping** 互补,既快又可靠;
- **wasAttached 守门** 避免误判与反复重启;
- **优先级仲裁** 实现细粒度主备,按组件分散;
- **委托 bwmachined** 拉起,Reviver 无需特权;
- **Components tags** 按机器能力部署,纯配置驱动;
- **shutDownOnRevive** 强制主备切换,保证健康度。

理解 Reviver 的实现有助于运维 BigWorld 集群时正确配置看门狗参数(尤其 `pingPeriod < subjectTimeout` 约束)、部署多 Reviver 主备、排查恢复失败问题(如 bwmachined 配置错误、`-recover` 参数未正确处理等)。

---

*本文档基于 BigWorld Engine 14.4.1 源码分析,所有代码引用均带行号,可在对应文件中直接定位。*

*文档结束*