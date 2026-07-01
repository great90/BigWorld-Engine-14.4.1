# BigWorld 工具 navgen 导航网格生成器实现深度分析

> 本文档详细分析 BigWorld Engine 14.4.1 中 navgen(导航网格生成工具)的完整实现,涵盖启动流程、核心类与继承关系、洪水填充采样算法、BSP 空间分割与多边形生成、集群分片、配置与命令行、菜单交互模式、依赖关系以及关键代码片段。navgen 是 BigWorld 工具链中最复杂的离线工具之一,主文件 `navgen.cpp` 约 5233 行,负责为游戏空间中的每一个 chunk 生成可供寻路系统使用的导航网格(navmesh / waypointSet / navPolySet)数据,并写入 chunk 的 `.cdata` 二进制文件。

---

## 目录

- [一、概述与整体架构](#一概述与整体架构)
- [二、目录结构与文件清单](#二目录结构与文件清单)
- [三、入口点与启动流程](#三入口点与启动流程)
- [四、核心类与继承关系](#四核心类与继承关系)
- [五、核心数据结构](#五核心数据结构)
- [六、导航网格生成算法总览](#六导航网格生成算法总览)
- [七、洪水填充采样:ChunkFlooder 与 WaypointFlood](#七洪水填充采样chunkflooder-与-waypointflood)
- [八、BSP 分割与多边形生成:WaypointGenerator](#八bsp-分割与多边形生成waypointgenerator)
- [九、邻接、注解与集合归属](#九邻接注解与集合归属)
- [十、输出与脏标志](#十输出与脏标志)
- [十一、doGenerate 单 chunk 生成流程](#十一dogenerate-单-chunk-生成流程)
- [十二、doGenerateAll 全空间批量生成](#十二dogenerateall-全空间批量生成)
- [十三、集群分片机制](#十三集群分片机制)
- [十四、配置项与命令行参数](#十四配置项与命令行参数)
- [十五、菜单与交互模式](#十五菜单与交互模式)
- [十六、依赖关系](#十六依赖关系)
- [十七、关键代码片段](#十七关键代码片段)
- [十八、设计亮点与注意事项](#十八设计亮点与注意事项)
- [附录 A:全局变量速查](#附录-a全局变量速查)
- [附录 B:菜单资源 ID 速查](#附录-b菜单资源-id-速查)

---

## 一、概述与整体架构

### 1.1 工具定位

`navgen` 是 BigWorld Technology SDK 中的离线导航网格生成工具,以 Windows 原生 Win32 应用程序形式存在(可执行文件 `navgen.exe` / `navgen_d.exe`)。它的核心职责是:

1. **加载一个游戏空间(Space)**,遍历其中所有的 chunk(地形格子 + 室内 chunk)。
2. 对每个 chunk,**洪水填充采样**碰撞场景,得到一张"哪些格子点可通行、邻接关系如何"的位图。
3. 用 **BSP 树递归分割**把可通行区域切成凸多边形(navPoly),并计算多边形之间的邻接关系。
4. 用 **WaypointAnnotator** 给边标注可见性、动作(如跳跃、攀爬)等元数据。
5. 把生成的 waypointSet / navPolySet **二进制序列化**到 chunk 的 `.cdata` 文件中。
6. 维护 **navmeshDirty** 标志,供编辑器(World Editor)判断是否需要重新生成。

这些导航数据最终被客户端 / 服务端的寻路系统(navmesh)读取,用于实体 AI 寻路与碰撞规避。

### 1.2 两种运行模式

navgen 支持两种运行模式,通过命令行参数 `/s` 区分:

| 模式 | 触发方式 | 用途 | UI |
|------|---------|------|----|
| **交互模式** | 不带 `/s` 启动 | 美术 / 关卡设计师手动查看、调试单个 chunk 的导航网格 | 完整窗口 + 菜单 + 3D 渲染窗口 |
| **命令行模式** | `navgen /s <space> [/g <file>] [/overwrite]` | 自动化流水线 / CI 批量生成 | 无主循环,执行完即退出 |

### 1.3 整体架构图

```
┌────────────────────────────────────────────────────────────────────┐
│                      navgen.exe (wWinMain)                          │
│   CallWithExceptionFilter → bwWinMain (navgen.cpp L4720)            │
└──────────────────────────────┬─────────────────────────────────────┘
                               │
            ┌──────────────────┼──────────────────┐
            ▼                  ▼                  ▼
   ┌─────────────────┐  ┌──────────────┐  ┌────────────────┐
   │ 资源/引擎初始化 │  │ setupChunking│  │  模式分流       │
   │ BWResource      │  │ (L3516)      │  │ /s → 命令行    │
   │ Moo::init       │  │ Script/MatKnd│  │ 否  → 交互循环 │
   │ navgen_settings │  │ Terrain/Water│  │                │
   └─────────────────┘  │ ChunkManager │  └────────────────┘
                        └──────┬───────┘
                               │ changeSpace
                               ▼
   ┌────────────────────────────────────────────────────────────┐
   │                  导航网格生成流水线                          │
   │                                                            │
   │  for each chunk in space (ChunkSpaceTraverser):            │
   │    ┌──────────────────────────────────────────────────┐    │
   │    │ ChunkWaypointGenerator (chunk_waypoint_generator)│    │
   │    │   ├── ChunkFlooder    (洪水填充)                  │    │
   │    │   ├── WaypointGenerator (BSP 分割+多边形)         │    │
   │    │   └── entityPts_ (WPEntity+NavGenUDO 种子点)      │    │
   │    └──────────────────────────────────────────────────┘    │
   │           │                  │                  │           │
   │           ▼                  ▼                  ▼           │
   │       flood()          generate()           output()        │
   │   (采样碰撞场景)    (BSP→多边形→邻接      (saveOut 写入     │
   │                     →注解→集合归属)        .cdata)          │
   └────────────────────────────────────────────────────────────┘
                               │
                               ▼
   ┌────────────────────────────────────────────────────────────┐
   │  依赖库 (lib/waypoint_generator)                            │
   │  waypoint_generator.hpp / waypoint_flood.hpp /             │
   │  waypoint_view.hpp / chunk_view.hpp                        │
   └────────────────────────────────────────────────────────────┘
```

### 1.4 与外部系统的关系

```
                  ┌────────────────┐
                  │  World Editor  │
                  │ (设置 navmeshDirty)│
                  └───────┬────────┘
                          │ 标记脏 chunk
                          ▼
                  ┌────────────────┐    bwlockd    ┌──────────────┐
                  │    navgen      │◄────锁机制───►│  bwlockd     │
                  │ (生成 navmesh) │               │ (并发锁服务) │
                  └───────┬────────┘               └──────────────┘
                          │ 写入 .cdata
                          ▼
                  ┌────────────────┐
                  │  chunk.cdata   │
                  │ waypointSet    │
                  │ navPolySet     │
                  │ auxData/       │
                  │   worldNavmesh │
                  └───────┬────────┘
                          │ 运行时读取
                          ▼
              ┌───────────────────────┐
              │ 客户端 / 服务端寻路系统 │
              │ (navmesh / waypoint)  │
              └───────────────────────┘
```

---

## 二、目录结构与文件清单

### 2.1 navgen 工具目录

navgen 工具源码位于 `programming/bigworld/tools/navgen/`,目录结构如下:

```
programming/bigworld/tools/navgen/
├── CMakeLists.txt              # CMake 构建定义
├── pch.hpp / pch.cpp           # 预编译头
├── navgen.cpp                  # 主文件 (~5233 行,含 wWinMain/bwWinMain/算法调度)
├── navgen.rc                   # Windows 资源文件 (菜单/对话框/图标)
├── navgen.ico                  # 应用程序图标
├── resource.h                  # 资源 ID 定义 (菜单/控件 ID)
├── chunk_waypoint_generator.hpp # ChunkWaypointGenerator 类声明
├── chunk_waypoint_generator.cpp # ChunkWaypointGenerator 类实现
├── navgen_udo.hpp              # NavGenUDO (航点种子 UDO) 声明
├── navgen_udo.cpp              # NavGenUDO / NavGenUDOCache 实现
├── wpentity.hpp                # WPEntity (实体障碍) 声明
├── wpentity.cpp                # WPEntity / WPEntityCache 实现
├── asyn_msg.hpp                # AsyncMessage 异步消息/日志接口
├── asyn_msg.cpp                # AsyncMessage 实现 (独立线程 + 日志对话框)
├── dlg_modeless_info.hpp       # ModelessInfoDialog 无模式对话框
└── dlg_modeless_info.cpp       # ModelessInfoDialog 实现
```

### 2.2 文件职责一览

| 文件 | 行数(约) | 主要职责 |
|------|----------|---------|
| `navgen.cpp` | 5233 | 程序入口、窗口/菜单、生成调度、视图绘制、集群分片 |
| `chunk_waypoint_generator.cpp` | 354 | 组合 ChunkFlooder + WaypointGenerator 的 facade |
| `navgen_udo.cpp` | 178 | WayPointSeed 类型 UDO 的加载与缓存 |
| `wpentity.cpp` | 239 | entity chunk item 的加载、SuperModel 障碍注入 |
| `asyn_msg.cpp` | 199 | 独立线程的日志对话框与 .log 文件 |
| `dlg_modeless_info.cpp` | 短 | "Please Wait" 无模式对话框 |

### 2.3 依赖的 common 模块

`CMakeLists.txt` 显式将 `../common/` 下的多个文件编入 navgen:

```
../common/bwlockd_connection.{cpp,hpp}    # bwlockd 锁连接
../common/chop_poly.{cpp,hpp}             # 多边形裁剪
../common/chunk_flooder.{cpp,hpp}         # chunk 洪水填充器
../common/collision_advance.{cpp,hpp}     # 碰撞前进器
../common/format.{cpp,hpp}                # 字符串格式化
../common/girth.{cpp,hpp}                 # Girth 规格
../common/grid_coord.{cpp,hpp}            # 网格坐标转换
../common/physics_handler.{cpp,hpp}       # 物理处理器(IPhysics 实现)
../common/utilities.{cpp,hpp}             # 通用工具
../common/waypoint_annotator.{cpp,hpp}    # 航点注解器
```

### 2.4 依赖的 lib 库

核心算法位于 `programming/bigworld/lib/waypoint_generator/`:

```
lib/waypoint_generator/
├── waypoint_generator.hpp / .cpp   # WaypointGenerator (BSP+多边形)
├── waypoint_flood.hpp / .cpp       # WaypointFlood (洪水填充)
├── waypoint_view.hpp / .cpp        # IWaypointView 查询接口
└── chunk_view.hpp / .cpp           # ChunkView (chunk 级视图)
```

---

## 三、入口点与启动流程

### 3.1 程序入口

navgen 是一个 Win32 GUI 应用,入口在 `navgen.cpp` 末尾:

```cpp
// navgen.cpp L5230-5232
int WINAPI wWinMain(HINSTANCE hInstance, HINSTANCE hPrev, LPWSTR commandLine, int cmdShow)
{
    return CallWithExceptionFilter( bwWinMain, hInstance, hPrev, commandLine, cmdShow );
}
```

`CallWithExceptionFilter` 是 `cstdmf/debug_exception_filter.hpp` 提供的包装器,它把 `bwWinMain` 包裹在 `__try / __except(ExceptionFilter(...))` 中,以便在崩溃时生成带堆栈信息的崩溃转储(仅在 `ENABLE_STACK_TRACKER && !_DEBUG` 时启用,见 `asyn_msg.cpp` L50-75 的类似用法)。

### 3.2 bwWinMain 启动序列

`bwWinMain` 定义在 `navgen.cpp` L4720-5142,是整个工具的初始化与生命周期管理核心。其执行序列可分为以下阶段:

#### 阶段 1:基础初始化(L4725-4739)

```cpp
// navgen.cpp L4725-4739
CStdMf cstdMf;                                    // cstdmf 初始化 (计时器/线程/内存)
BW::string cmdLine = bw_wtoutf8( commandLine );   // 命令行转 UTF-8
int argc = 0;
char** argv = NULL;
INITCOMMONCONTROLSEX initControls;
initControls.dwSize = sizeof( initControls );
initControls.dwICC = 0x8ffff;                      // 启用所有通用控件类
InitCommonControlsEx( &initControls );
parseCommandLineMF( cmdLine.c_str(), argc, argv ); // 解析为 argc/argv
```

- `CStdMf` 是 RAII 守卫,构造时初始化 cstdmf 子系统(时间戳、观察者、内存跟踪),析构时清理。
- `parseCommandLineMF` 把命令行字符串拆分成传统的 `argc/argv`,供 `BWResource::init` 解析 `-res` 等资源路径参数。

#### 阶段 2:资源系统初始化(L4741-4767)

```cpp
// navgen.cpp L4743-4767
BWResource bwResourceHolder;                                  // RAII 持有 BWResource
BWResource::init( argc, (const char **)argv );                // 初始化资源系统
if (!AutoConfig::configureAllFrom("resources.xml"))           // 加载 resources.xml 自动配置
{
    CRITICAL_MSG( "Failed to load resources.xml. " );
    return false;
}
DataSectionPtr configRoot = BWResource::instance().openSection( s_engineConfigXML.value() );
// ... 读取 engine_config.xml 的 shouldReadXMLAttributes / shouldWriteXMLAttributes
```

- `BWResource bwResourceHolder` 是局部变量,作用域结束时自动 `BWResource::fini`,保证异常安全。
- `AutoConfig::configureAllFrom("resources.xml")` 读取 `resources.xml` 中预定义的 `AutoConfigString`(如 `system/language`、`system/engineConfigXML`,见 L129-130)。

#### 阶段 3:navgen_settings.xml 加载(L4769-4788)

```cpp
// navgen.cpp L4770-4788
BW::string settingsFilename = BWResource::appDirectory() + "navgen_settings.xml";
for (int i = 0; i < argc - 1; i++)
{
    if (strcmp( "--settings", argv[i] ) == 0)
        settingsFilename = argv[ i+1 ];                        // --settings 命令行覆盖
}
if( !BWResource::fileAbsolutelyExists( settingsFilename ) )
    CRITICAL_MSG( "Cannot find NavGen setting file : navgen_settings.xml\n" );
g_navgenSettings = new DataResource( settingsFilename );      // 全局设置对象
```

`navgen_settings.xml` 是 navgen 的核心配置文件,通过 `DataResource` 加载后可被全局访问。`--settings` 参数允许流水线指定自定义配置路径。

#### 阶段 4:国际化与字符串提供者(L4790-4815)

```cpp
// navgen.cpp L4790-4815
g_annotate = g_navgenSettings->getRootSection()->readBool( "annotate", false );
if( !s_LanguageFile.value().empty() )
    StringProvider::instance().load( BWResource::openSection( s_LanguageFile ) );
BW::vector<DataSectionPtr> languages;
g_navgenSettings->getRootSection()->openSections( "language", languages );
// ... 加载 language 列表,默认 helpers/languages/navgen_rc_en.xml + files_en.xml
// ... 设置 currentLanguage / currentCountry
```

`StringProvider` 是 BigWorld 的 i18n 框架,菜单文本、对话框文案均可通过键查找本地化字符串。

#### 阶段 5:窗口类注册与创建(L4822-4884)

```cpp
// navgen.cpp L4835-4884
wc.style = CS_DBLCLKS | CS_OWNDC;
wc.lpfnWndProc = wndProc;
wc.lpszClassName = L"navgen";
RegisterClass(&wc);                                  // 主窗口类 "navgen"

wc.lpfnWndProc = wndProcMoo;
wc.lpszClassName = L"navgenMoo";
RegisterClass(&wc);                                  // 3D 渲染窗口类 "navgenMoo"

g_hWindow = CreateWindow(L"navgen", L"NavPoly Generator", ...);   // 主窗口(含菜单)
g_statusWindow.create( g_hWindow );                                // 状态栏(6 段)
g_hMooWindow = CreateWindow( L"navgenMoo", L"NavPoly Renderer", ...); // 3D 渲染窗口
g_hInfoDialog = CreateDialog(hInstance, MAKEINTRESOURCE(IDD_WAYPOINT_INFO), ...); // 信息对话框
```

navgen 维护三个关键窗口句柄:

| 句柄 | 类 | 用途 |
|------|----|----|
| `g_hWindow` | navgen | 主窗口,承载菜单、状态栏、2D 俯视导航网格视图 |
| `g_hMooWindow` | navgenMoo | Moo 渲染窗口,3D 场景渲染(碰撞场景、地形) |
| `g_hInfoDialog` | IDD_WAYPOINT_INFO | 无模式对话框,显示选中多边形信息 |

#### 阶段 6:OpenGL 与 Moo 初始化(L4891-4902)

```cpp
// navgen.cpp L4891-4902
if(!setupGL())        return 0;    // 主窗口 OpenGL 上下文(用于 2D 视图绘制)
if(!Moo::init())      return 0;    // Moo 渲染引擎初始化

g_hMenu = GetMenu(g_hWindow);
g_viewAdjacencies  = (GetMenuState(...) & MF_CHECKED) != 0;   // 读取菜单初始勾选状态
g_viewBSPNodes     = ...;
g_viewPolygonArea  = ...;
g_viewPolygonBorders = ...;
```

`setupGL()`(L3315-3357)在 `g_hWindow` 上创建传统 OpenGL 上下文(`PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER`,16 位色深),用于绘制 2D 俯视的导航网格图。`Moo::init()` 初始化 BigWorld 的渲染抽象层,服务于 `g_hMooWindow`。

#### 阶段 7:设置项读取(L4904-4916)

```cpp
// navgen.cpp L4904-4916
g_processor  = g_navgenSettings->getRootSection()->readInt("processor", 1);
g_writeTGAs  = g_navgenSettings->getRootSection()->readBool("writeTGAs", true);
g_reannotation = g_navgenSettings->getRootSection()->readBool( "reannotation", false );
DataSectionPtr graphicsPreferences = g_navgenSettings->getRootSection()->openSection("graphicsPreferences");
if(graphicsPreferences.get())
    Moo::GraphicsSetting::init(graphicsPreferences);
if (!g_reannotation)
    DeleteMenu( g_hMenu, ID_CHUNK_REANNOTATE, MF_BYCOMMAND );   // 不启用重注解则移除菜单项
g_chunkLoadDistance = g_navgenSettings->getRootSection()->readFloat("loadDistance", g_chunkLoadDistance);
```

#### 阶段 8:后台任务与输入(L4917-4924)

```cpp
// navgen.cpp L4917-4924
BgTaskManager::init();
BgTaskManager::instance().startThreads( "Chunk Loading Thread", 1 );   // chunk 后台加载线程
FileIOTaskManager::init();
FileIOTaskManager::instance().startThreads("File IO Thread", 1);        // 文件 IO 线程
InputDevices inputDevices;
InputDevices::instance().init( hInstance, g_hWindow );                  // 输入设备
```

#### 阶段 9:模式分流(L4926-5014)

这是启动流程中最重要的分叉点:

```cpp
// navgen.cpp L4926-5014 (节选)
bool workInCommandLine = false;
if (strstr( cmdLine.c_str(), "/s" ))
{
    workInCommandLine = true;
    BW::string space;
    getParam( &cmdLine, "/s", &space );                      // 解析空间路径
    if( !BWResource::openSection( space + "/space.settings" ) ) // 校验空间存在
        return 3;

    if (const char* p = strstr( cmdLine.c_str(), "/g" ))     // /g <chunk 列表文件>
    {
        BW::string file;
        getParam( &cmdLine, "/g", &file );
        std::ifstream ifs( file.c_str() );
        BW::string chunkName;
        while( std::getline( ifs, chunkName ) )              // 逐行读取 chunk 名
            g_chunkSet.insert( chunkName );                  // 加入待处理集合
    }
    setupChunking( space );                                  // 初始化 chunk 系统
}
else
{
    setupChunking( "" );                                     // 交互模式,空 space
}
```

`/s` 命令行模式的核心语义:

- `/s <space>`:指定要处理的空间路径(必填)。
- `/g <file>`:可选,只处理文件中列出的 chunk(每行一个 chunk 标识符,存入 `g_chunkSet`)。若未指定则处理整个空间。
- `/overwrite`:可选,先清除所有旧导航数据再生成(传给 `doGenerateAll(true)`)。

#### 阶段 10:主循环或一次性执行(L5036-5084)

```cpp
// navgen.cpp L5036-5084
if (workInCommandLine)
{
    updateMoo( 0.f );
    doGenerateAll( !!strstr( cmdLine.c_str(), "/overwrite" ) );   // 命令行模式:一次性生成
}
else
{
    Automation::parseCommandLine( commandLine );
    uint64 timeLast = timestamp();
    while(1)                                                       // 交互模式:消息循环
    {
        if (g_pleaseShutdown) break;
        // 处理 Windows 消息
        while (PeekMessage( &msg, NULL, 0, 0, PM_NOREMOVE )) { ... }
        // 计算 dTime,推进 Script::tick,更新与绘制场景
        incrementTotalTime( dTime );
        Script::tick( getTotalTime() );
        updateMoo( dTime );
        if (IsWindowVisible( g_hMooWindow ))
            drawMoo( dTime );
    }
}
```

#### 阶段 11:清理(L5086-5141)

```cpp
// navgen.cpp L5086-5141
doClearAll();                              // 清除所有 chunk
MainLoopTasks::finiAll();
BgTaskManager::instance().stopAll();
FileIOTaskManager::instance().stopAll();
Moo::rc().releaseDevice();
if(g_glrc) { wglMakeCurrent(NULL, NULL); wglDeleteContext(g_glrc); }
if (ChunkManager::instance().cameraSpace().exists())
    ChunkManager::instance().cameraSpace()->enviro().deactivate();
g_navgenSettings = NULL;
delete g_spaceManager;
Script::fini();
// ... Waters / ChunkManager / SpaceManager / FootPrintRenderer / EnviroMinder / TextureFeeds / Terrain / MaterialKinds
s_pLensEffectManager.reset();
s_pFontManager.reset();
Moo::VertexDeclaration::fini();
g_pRenderer.reset();
Moo::fini();
BWResource::fini();
WindowTextNotifier::fini();
BgTaskManager::fini();
FileIOTaskManager::fini();
DataSectionCensus::fini();
```

清理严格按依赖逆序进行,确保 EnviroMinder、Waters 等依赖 Terrain/Chunk 的子系统先于底层销毁。

### 3.3 setupChunking 引擎子系统装配

`setupChunking`(L3516-3748)是 navgen 把"引擎运行时"装配起来的关键函数,无论交互模式还是命令行模式都会调用。它完成:

```
setupChunking(space):
  1. Water::backgroundLoad(false)              # 关闭水面后台加载(避免干扰采样)
  2. Script::init(paths, "navgen")             # Python 初始化(加载 entitiesEditorPath)
  3. MaterialKinds::init()                     # 材质种类(用于碰撞音效/足迹)
  4. 读取 bwlockd/host, bwlockd/username       # 锁服务配置
  5. g_pRenderer = new Renderer; init          # Moo 渲染器
  6. Moo::rc().createDevice(g_hMooWindow)      # 创建渲染设备
  7. FontManager / TextureFeeds / LensEffectManager
  8. SpaceManager::init() + ClientChunkSpaceAdapter::init()
  9. ChunkManager::init()
  10. SpaceNameManager (NavGenMRUProvider)     # 最近打开空间管理
  11. Waters::init() / EnviroMinder::init()
  12. changeSpace(space)                       # 切换到目标空间
  13. FootPrintRenderer::init()
  14. 设置雾参数
  15. Girths 加载 → g_girthSpecs / g_girthsAlwaysGenerate / g_girthsViewable
  16. 校验 girth=0.5 必须存在
  17. ChunkManager::autoSetPathConstraints(loadDistance)
  18. ChunkManager::maxUnloadChunks(100)
```

其中 Girth 加载段(L3718-3738)值得注意:

```cpp
// navgen.cpp L3718-3738
Girths girths;
for (uint i=0; i < girths.size(); ++i)
{
    const Girth& girth = girths[ i ];
    g_girthSpecs.insert( std::make_pair( girth.girth(), girth ) );
    if (girth.always())
        g_girthsAlwaysGenerate.push_back( girth.girth() );   // always=true 的 girth 总是生成
    g_girthsViewable.push_back( girth.girth() );             // 所有 girth 都可在视图中切换
}
if (g_girthSpecs.find( 0.5f ) == g_girthSpecs.end())
    CRITICAL_MSG( "Girth = 0.5 specification not found.\n" );
```

`girth=0.5` 是硬性要求,因为它是客户端默认寻路实体(半径 0.5m)的规格。

---

## 四、核心类与继承关系

### 4.1 类继承关系图

```
ChunkItem (chunk/chunk_item.hpp)
   ├── NavGenUDO          (navgen_udo.hpp L22)   # WayPointSeed UDO,提供种子点+girth 范围
   └── WPEntity           (wpentity.hpp L14)     # entity 障碍,加载 SuperModel 注入碰撞场景

ChunkCache (chunk/chunk_cache.hpp)
   ├── NavGenUDOCache     (navgen_udo.hpp L56)   # 缓存 chunk 内所有 NavGenUDO
   └── WPEntityCache      (wpentity.hpp L49)     # 缓存 chunk 内所有 WPEntity

IWaypointView (waypoint_view.hpp)
   └── WaypointGenerator  (waypoint_generator.hpp L25)  # BSP 分割+多边形生成核心

(无继承)
   ├── ChunkFlooder       (common/chunk_flooder.hpp L20)  # chunk 级洪水填充 facade
   ├── WaypointFlood      (waypoint_flood.hpp L83)        # 底层洪水填充算法
   ├── ChunkWaypointGenerator (chunk_waypoint_generator.hpp L17)  # 组合 facade
   ├── PhysicsHandler     (common/physics_handler.hpp)    # IPhysics 实现
   ├── WaypointAnnotator  (common/waypoint_annotator.hpp) # 边注解
   ├── AsyncMessage       (asyn_msg.hpp L7)               # 日志/错误对话框
   └── NavgenStatusWindow (navgen.cpp L159)               # 状态栏
```

### 4.2 ChunkWaypointGenerator:核心 facade

`ChunkWaypointGenerator`(`chunk_waypoint_generator.hpp` L17-43)是单 chunk 生成流程的统一入口,它组合了洪水填充器与航点生成器:

```cpp
// chunk_waypoint_generator.hpp L17-43
class ChunkWaypointGenerator
{
public:
    ChunkWaypointGenerator( Chunk * pChunk, const BW::string& floodResultPath );
    virtual ~ChunkWaypointGenerator();
    bool modified() const   { return modified_; }
    bool ready() const;
    int maxFloodPoints() const;
    void flood( bool (*progressCallback)( int npoints ), Girth gSpec, bool writeTGAs );
    void generate( bool annotate, Girth gSpec );
    void output( float girth, bool firstGirth );
    void outputDirtyFlag( bool dirty = false );
    Chunk *chunk() const { return pChunk_; }
    static bool canProcess(Chunk *chunk);
private:
    Chunk * pChunk_;
    ChunkFlooder        flooder_;        # 洪水填充器
    WaypointGenerator   gener_;          # 航点生成器
    BW::vector<Vector3> entityPts_;      # 种子点(来自 WPEntity + NavGenUDO)
    bool                modified_;
};
```

它的构造函数(`chunk_waypoint_generator.cpp` L78-108)做三件事:

```cpp
// chunk_waypoint_generator.cpp L78-108
ChunkWaypointGenerator::ChunkWaypointGenerator( Chunk * pChunk, const BW::string& floodResultPath ) :
    pChunk_( pChunk ),
    flooder_( pChunk, floodResultPath ),
    modified_( true )
{
    getEntityPts( pChunk, entityPts_ );                    # 收集种子点

    DataSectionPtr chunkBinSection = BWResource::openSection( pChunk_->binFileName() );
    if (chunkBinSection)
    {
        # 读取 navmeshDirty 标志(与 EditorChunkNavmeshCacheBase::load 对齐)
        DataSectionPtr navmeshDirtySection = chunkBinSection->findChild( s_navmeshDirtyStr );
        if (navmeshDirtySection)
        {
            BinaryPtr bp = navmeshDirtySection->asBinary();
            if (bp->len() == sizeof(bool))
                modified_ = *((bool *)bp->cdata());
        }
        if (!modified_ && !chunkBinSection->findChild( "worldNavmesh" ))
            modified_ = true;                              # 没有 worldNavmesh 也视为脏
    }
    g_oldCam = g_camMatrix;
    g_camMatrix.translation( pChunk->centre() );           # 相机移到 chunk 中心
}
```

注意 `s_navmeshDirtyStr = "navmeshDirty"`(`chunk_waypoint_generator.cpp` L30),这个二进制 bool 标志是 navgen 与 World Editor 之间的契约:编辑器修改地形/障碍后写 `navmeshDirty=true`,navgen 生成完毕写 `false`。

### 4.3 NavGenUDO:航点种子 UDO

`NavGenUDO`(`navgen_udo.hpp` L22-46)是 `ChunkItem` 的子类,代表场景中放置的 "WayPointSeed" 类型 UserDataObject:

```cpp
// navgen_udo.hpp L11-46
struct GirthSeed
{
    Vector3 position;
    float   girth;
    float   generateRange;
};

class NavGenUDO : public ChunkItem
{
    DECLARE_CHUNK_ITEM( NavGenUDO )
public:
    NavGenUDO();
    bool load( DataSectionPtr pSection );
    virtual void toss( Chunk * pChunk );
    const Vector3 & position() const { return transform_.applyToOrigin(); }
    typedef BW::map<NavGenUDO*,GirthSeed> GirthSeeds;
    static  GirthSeeds s_girthSeeds;     # 全局种子表(按 UDO 指针索引)
private:
    DataSectionPtr pProps_;
    Matrix         transform_;
};
```

工厂函数 `NavGenUDO::create`(`navgen_udo.cpp` L98-123)只接受 `type == "WayPointSeed"` 的 UserDataObject:

```cpp
// navgen_udo.cpp L98-123
ChunkItemFactory::Result NavGenUDO::create( Chunk * pChunk, DataSectionPtr pSection )
{
    if (pSection->readString("type") != "WayPointSeed")
        return ChunkItemFactory::SucceededWithoutItem();    # 非 WayPointSeed 跳过
    NavGenUDO * pItem = new NavGenUDO();
    if (pItem->load(pSection))
    {
        if (!pChunk->addStaticItem( pItem )) { ... }
        return ChunkItemFactory::Result( pItem );
    }
    ...
}
```

`toss`(`navgen_udo.cpp` L60-94)在 chunk 绑定/解绑时维护 `s_girthSeeds` 全局表:

```cpp
// navgen_udo.cpp L60-94
void NavGenUDO::toss( Chunk * pChunk )
{
    if (pChunk == pChunk_) return;
    if (pChunk_ != NULL)
        NavGenUDOCache::instance( *pChunk_ ).del( this );
    this->ChunkItem::toss( pChunk );
    if (pChunk_ != NULL)
    {
        NavGenUDOCache::instance( *pChunk_ ).add( this );
        GirthSeed girthSeed;
        girthSeed.position = pChunk->transform().applyPoint( this->position() );
        girthSeed.girth = pProps_->readFloat( "girth", -1.f );
        girthSeed.generateRange = pProps_->readFloat( "generateRange", 0.f );
        if (girthSeed.girth > 0.f )
            s_girthSeeds[this] = girthSeed;        # 注册种子
    }
    else
    {
        # 从全局表移除
    }
}
```

`GirthSeed.girth` 指定该种子点要求生成哪种 girth 的导航网格,`generateRange` 指定影响范围(世界坐标)。`compileGirthsList`(见 §五)会用它决定某个 chunk 需要生成哪些额外 girth。

### 4.4 WPEntity:实体障碍

`WPEntity`(`wpentity.hpp` L14-39)代表场景中的 entity,它把 entity 的模型作为障碍注入碰撞场景:

```cpp
// wpentity.hpp L14-39
class WPEntity : public ChunkItem
{
    DECLARE_CHUNK_ITEM( WPEntity )
public:
    bool load( DataSectionPtr pSection );
    virtual void toss( Chunk * pChunk );
    virtual void draw( Moo::DrawContext& drawContext );
    const Vector3 & position() const { return transform_.applyToOrigin(); }
private:
    BW::string  typeName_;
    DataSectionPtr pProps_;
    Matrix      transform_;
    class SuperModel * pSuperModel_;     # 延迟加载的障碍模型
};
```

`finishLoad`(`wpentity.cpp` L66-128)通过 Python 调用 entity 类的 `getObstacleModel` 方法获取障碍模型名:

```cpp
// wpentity.cpp L66-128 (节选)
void WPEntity::finishLoad()
{
    PyObject * pModule = PyImport_ImportModule( const_cast<char*>(typeName_.c_str()) );
    if (pModule != NULL)
    {
        PyObject * pClass = PyObject_GetAttrString( pModule, const_cast<char*>(typeName_.c_str()) );
        PyObject * pEntityInst = PyObject_CallObject( pClass, PyTuple_New(0) );
        PyObject * pTuple = PyTuple_New(1);
        PyTuple_SetItem( pTuple, 0, new PyDataSection( pProps_ ) );
        PyObject * pResult = Script::ask(
            PyObject_GetAttrString( pEntityInst, "getObstacleModel" ), pTuple, ... );
        BW::string obstModelName;
        if (Script::setAnswer( pResult, obstModelName ))
        {
            BW::vector<BW::string> modelNames( 1, obstModelName );
            pSuperModel_ = new SuperModel( modelNames );
        }
    }
}
```

`toss`(`wpentity.cpp` L133-165)在 chunk 绑定时把模型作为 `ChunkModelObstacle` 注入,这样洪水填充阶段的碰撞测试就能感知到 entity 障碍:

```cpp
// wpentity.cpp L133-165 (节选)
void WPEntity::toss( Chunk * pChunk )
{
    ...
    if (pSuperModel_ != NULL)
    {
        Matrix world( pChunk_->transform() );
        world.preMultiply( this->transform_ );
        for (int i = 0; i < this->pSuperModel_->nModels(); i++)
            ChunkModelObstacle::instance( *pChunk_ ).addModel(
                this->pSuperModel_->topModel( i ), world, this );
    }
}
```

`IMPLEMENT_CHUNK_ITEM( WPEntity, entity, 0 )`(L189)注册工厂,匹配 chunk 中 `entity` 类型的条目。

### 4.5 ChunkCache 子类

`NavGenUDOCache` 与 `WPEntityCache` 都继承自 `ChunkCache`,通过 `Instance<...>` 模板实现每 chunk 单例:

```cpp
// navgen_udo.hpp L56-72
class NavGenUDOCache : public ChunkCache
{
public:
    NavGenUDOCache( Chunk & chunk );
    NavGenUDOs::iterator begin() { return udos_.begin(); }
    NavGenUDOs::iterator end()   { return udos_.end(); }
    void add( NavGenUDOPtr e );
    void del( NavGenUDOPtr e );
    static Instance<NavGenUDOCache> instance;
private:
    NavGenUDOs udos_;
};
```

`getEntityPts`(`chunk_waypoint_generator.cpp` L39-71)遍历这两个 cache 收集种子点:

```cpp
// chunk_waypoint_generator.cpp L39-71
void getEntityPts( Chunk* pChunk, BW::vector<Vector3>& entityPts )
{
    entityPts.clear();
    int seedPointCount = 0;
    Vector3 seedPt;

    # WPEntity 种子点
    WPEntityCache & wec = WPEntityCache::instance( *pChunk );
    for ( WPEntities::iterator it = wec.begin(); it != wec.end(); ++it )
    {
        seedPt = pChunk->transform().applyPoint(
            (*it)->position() + Vector3( 0, 1.f, 0 ) );      # +1 米抬高,避免埋地
        ++seedPointCount;
        entityPts.push_back( seedPt );
    }

    # NavGenUDO 种子点
    NavGenUDOCache & udoc = NavGenUDOCache::instance( *pChunk );
    for ( NavGenUDOs::iterator it = udoc.begin(); it != udoc.end(); ++it )
    {
        seedPt = pChunk->transform().applyPoint(
            (*it)->position() + Vector3( 0, 1.f, 0 ) );
        ++seedPointCount;
        entityPts.push_back( seedPt );
    }
}
```

种子点是洪水填充的起点(`flashFlood` 从种子点扩散),确保生成结果覆盖实体所在位置。

---

## 五、核心数据结构

### 5.1 Girth 规格定义

`Girth`(`tools/common/girth.hpp` L13-35)描述一种寻路实体的物理规格,是导航网格生成的关键参数:

```cpp
// tools/common/girth.hpp L13-35
class Girth
{
public:
    Girth( DataSectionPtr ds );
    float girth()    const { return girth_; }       # 标识值(如 0.5)
    float width()    const { return width_; }       # 实体宽度
    float height()   const { return height_; }      # 实体高度(决定能通过的洞穴)
    float depth()    const { return depth_; }       # 实体深度
    float radius()   const { return std::min<float>( width_, depth_ ) * 0.5f; }
    float maxSlope() const { return maxSlope_; }    # 最大可通行坡度
    float maxClimb() const { return maxClimb_; }    # 最大可攀爬高度
    bool  always()   const { return always_; }      # 是否所有 chunk 都生成
private:
    float girth_, width_, height_, depth_, maxSlope_, maxClimb_;
    bool  always_;
};
```

`girth` 字段是规格的唯一键(浮点数,通常是 `0.5`、`2.0` 等),`width/height/depth` 决定洪水填充时碰撞体的尺寸,`maxSlope/maxClimb` 决定可通行性判定,`always` 决定是否对空间内所有 chunk 都生成此 girth 的导航网格。

### 5.2 WaypointFlood 的 AdjGridElt

`AdjGridElt`(`waypoint_flood.hpp` L15-37)是洪水填充的核心存储单元,用 4 位 × 8 方向的紧凑位图记录每个网格点在每个高度的 8 邻接方向是否可通行:

```cpp
// waypoint_flood.hpp L15-37
union AdjGridElt
{
    # 取方向 a (0..7) 的邻接信息
    uint32 angle( uint a )
        { return (all >> (a<<2)) & 15; }
    # 设置方向 a 的邻接信息
    void angle( uint a, uint32 adj )
        { all = (all & ~(15 << (a<<2))) | adj << (a<<2); }

    uint32 all;
    struct
    {
        uint32  u:4;    # 0  上
        uint32  ur:4;   # 1  右上
        uint32  r:4;    # 2  右
        uint32  dr:4;   # 3  右下
        uint32  d:4;    # 4  下
        uint32  dl:4;   # 5  左下
        uint32  l:4;    # 6  左
        uint32  ul:4;   # 7  左上
    } each;
};
```

每个 `AdjGridElt` 占 4 字节(32 位),8 个方向各 4 位(可编码 0-15 的邻接状态)。`WaypointFlood` 为每个网格点存储 `MAX_HEIGHTS = 16` 层高度的 `AdjGridElt` 与对应高度值:

```cpp
// waypoint_flood.hpp L117-129
static const uint MAX_HEIGHTS = 16;
...
float*        hgtGrids_[MAX_HEIGHTS];   # 每层高度图(每点实际 Y 高度)
AdjGridElt *  adjGrids_[MAX_HEIGHTS];   # 每层邻接图(8 方向可通行性)
```

`MAX_HEIGHTS=16` 意味着一个网格点上最多记录 16 个不同的可站立高度(用于桥、多层平台等场景)。

### 5.3 WaypointGenerator 的 BSPNode

`BSPNode`(`waypoint_generator.hpp` L84-108)是 BSP 树节点,记录一个矩形区域的分割信息:

```cpp
// waypoint_generator.hpp L84-108
struct BSPNode
{
    float   borderOffset[8];     # 8 方向的边界偏移
    float   splitOffset;         # 分割线偏移
    int     splitNormal;         # 分割法向(0=X 轴, 1=Z 轴)
    int     parent;              # 父节点索引
    int     front;               # 前子节点索引
    int     back;                # 后子节点索引
    bool    waypoint;            # 是否为叶子(可生成航点多边形)
    int     waypointIndex;       # 对应多边形索引
    Vector2 centre;              # 节点中心
    float   minHeight;           # 最小高度
    float   maxHeight;           # 最大高度

    mutable int  baseX, baseZ, width;
    mutable BW::vector<BOOL> pointInNodeFlags;
    ...
};
```

BSP 分割把可通行区域递归切成凸的叶子节点,每个叶子节点最终成为一个 `PolygonDef`(多边形)。

### 5.4 PolygonDef / VertexDef / EdgeDef

```cpp
// waypoint_generator.hpp L135-166
struct VertexDef
{
    VertexDef() : pos( Vector2::ZERO ), adjNavPoly( 0 ), adjToAnotherChunk(), angles( 0 ) {}
    Vector2  pos;                  # 顶点位置
    int      adjNavPoly;           # 邻接的 navPoly 索引
    bool     adjToAnotherChunk;    # 是否邻接另一个 chunk
    int      angles;               # 角度信息(凸/凹判断)
};

struct PolygonDef
{
    BW::vector<VertexDef>  vertices;
    float                  minHeight;
    float                  maxHeight;
    int                    set;            # 所属集合(种子点归属)
    bool ptNearEnough( const Vector3 & pt ) const;
};

struct EdgeDef
{
    Vector2  from, to;
    int      id;
    bool operator<(const EdgeDef& v) const;
    bool operator==(const EdgeDef& v) const;
};
```

### 5.5 WaypointGenerator 主结构

```cpp
// waypoint_generator.hpp L184-197
AdjGridElt *            adjGrids_[WaypointFlood::MAX_HEIGHTS];
float *                 hgtGrids_[WaypointFlood::MAX_HEIGHTS];
unsigned int            gridX_, gridZ_;
Vector3                 gridMin_;
float                   gridResolution_;
IProgress*              pProgress_;

BW::vector<BSPNode>     bsp_;           # BSP 树
BW::vector<PolygonDef>  polygons_;      # 生成的多边形
BW::set<PointDef>       points_;        # 唯一顶点集
BW::set<EdgeDef>        edges_;         # 唯一边集
int                     sets_;          # 集合数
BW::string              identifier_;
```

### 5.6 数据结构关系图

```
   洪水填充阶段                          BSP 生成阶段
   ┌───────────────────┐                ┌────────────────────┐
   │ WaypointFlood     │                │ WaypointGenerator  │
   │  hgtGrids_[16]    │ ──memcpy───►   │  hgtGrids_[16]     │
   │  adjGrids_[16]    │ ──memcpy───►   │  adjGrids_[16]     │
   │  (每点 8 方向 4 位)│                │  bsp_ (BSPNode 树) │
   └───────────────────┘                │  polygons_         │
                                        │  points_ (唯一点)   │
                                        │  edges_ (唯一边)    │
                                        └────────────────────┘
                                                 │
                                                 ▼ 输出
                                        ┌────────────────────┐
                                        │  chunk.cdata       │
                                        │   waypointSet      │
                                        │   navPolySet       │
                                        └────────────────────┘
```

---

## 六、导航网格生成算法总览

### 6.1 三阶段流水线

整个生成过程分为三大阶段,由 `ChunkWaypointGenerator` 的三个方法串联:

```
┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│   flood()    │ ─► │  generate()  │ ─► │  output()    │
│  洪水填充采样 │    │ BSP+多边形+  │    │ 写入 .cdata  │
│  碰撞场景     │    │ 邻接+注解    │    │              │
└──────────────┘    └──────────────┘    └──────────────┘
     │                    │                    │
     ▼                    ▼                    ▼
  AdjGridElt[16]     BSPNode 树            waypointSet
  hgtGrids[16]       polygons_             navPolySet
                     (含邻接+注解)
```

### 6.2 流水线数据流

```cpp
// chunk_waypoint_generator.cpp L139-195 (核心流水线)
void ChunkWaypointGenerator::flood( ..., Girth gSpec, bool writeTGAs )
{
    flooder_.flood( gSpec, entityPts_, progressCallback, 0, writeTGAs );   # ① 洪水填充
}

void ChunkWaypointGenerator::generate( bool annotate, Girth gSpec )
{
    int w = flooder_.width(), h = flooder_.height();
    gener_.init( w, h, flooder_.minBounds(), flooder_.resolution() );

    # 把洪水填充结果拷贝到生成器
    for ( int g = 0; g < 16; ++g )
    {
        memcpy( gener_.adjGrids()[g], flooder_.adjGrids()[g], w*h*4 );
        memcpy( gener_.hgtGrids()[g], flooder_.hgtGrids()[g], w*h*4 );
    }

    gener_.generate();                                              # ② BSP 分割+多边形

    # 计算与邻接 chunk 的边连接
    PhysicsHandler phand( pChunk_->space(), gSpec );
    gener_.determineEdgesAdjacentToOtherChunks( pChunk_, &phand );

    # 多边形精简
    gener_.streamline();

    # 边注解(可见性、动作)
    if( annotate )
    {
        WaypointAnnotator wanno( &gener_, pChunk_->space() );
        wanno.annotate();
    }

    # 扩展穿过未绑定 portal
    gener_.extendThroughUnboundPortals( pChunk_ );

    # 计算集合归属(种子点 → 多边形)
    gener_.calculateSetMembership( entityPts_, pChunk_->identifier() );
}

void ChunkWaypointGenerator::output( float girth, bool firstGirth )
{
    gener_.saveOut( pChunk_, girth, /*removeAllOld:*/firstGirth );   # ③ 写入 .cdata
}
```

### 6.3 算法阶段详解表

| 阶段 | 函数 | 输入 | 输出 | 关键算法 |
|------|------|------|------|---------|
| 洪水填充 | `ChunkFlooder::flood` | chunk + Girth + 种子点 | `adjGrids_[16]` + `hgtGrids_[16]` | 从种子点 BFS 扩散,碰撞测试决定可通行性 |
| BSP 分割 | `WaypointGenerator::generate` | 邻接图 + 高度图 | `bsp_` (BSPNode 树) | 递归二分,选最优分割线 |
| 多边形生成 | `generatePoints/generatePolygons` | BSP 叶子 | `polygons_` | 从叶子边界提取顶点与多边形 |
| 邻接计算 | `generateAdjacencies/joinPolygons` | 多边形 | 邻接关系 | 共享顶点/边的多边形互连 |
| 跨 chunk 边 | `determineEdgesAdjacentToOtherChunks` | 多边形 + PhysicsHandler | `adjToAnotherChunk` 标志 | 物理测试判断边是否通向邻 chunk |
| 精简 | `streamline` | 多边形 | 合并后的多边形 | 合并可合并的相邻多边形 |
| 注解 | `WaypointAnnotator::annotate` | 多边形 + 边 | 边注解 | 视线测试、动作判定 |
| portal 扩展 | `extendThroughUnboundPortals` | 多边形 + chunk | 扩展多边形 | 穿过未绑定 portal 延伸 |
| 集合归属 | `calculateSetMembership` | 多边形 + 种子点 | `set` 字段 | 种子点落在哪个多边形 |
| 输出 | `saveOut` | 多边形 | `.cdata` 二进制 | 序列化 |

---

## 七、洪水填充采样:ChunkFlooder 与 WaypointFlood

### 7.1 ChunkFlooder facade

`ChunkFlooder`(`tools/common/chunk_flooder.hpp` L20-54)是 chunk 级洪水填充的门面,内部持有 `WaypointFlood`:

```cpp
// tools/common/chunk_flooder.hpp L20-54
class ChunkFlooder
{
public:
    ChunkFlooder( Chunk * pChunk, const BW::string& floodResultPath );
    bool flood( Girth gSpec, const BW::vector<Vector3>& entityPts,
                bool (*progressCallback)( int npoints ) = NULL,
                int nshrink = 0, bool writeTGAs = true );
    Vector3 minBounds() const;
    Vector3 maxBounds() const;
    float   resolution() const;
    int     width() const;
    int     height() const;
    AdjGridElt ** adjGrids() const;
    float **     hgtGrids() const;
private:
    Chunk *          pChunk_;
    WaypointFlood *  pWF_;
    BW::string       floodResultPath_;
};
```

`floodResultPath` 允许把洪水填充中间结果(邻接位图)缓存到磁盘,便于重注解(`reannotation`)时跳过耗时的物理采样。

### 7.2 WaypointFlood 洪水填充算法

`WaypointFlood`(`lib/waypoint_generator/waypoint_flood.hpp` L83-141)是底层洪水填充引擎:

```cpp
// waypoint_flood.hpp L83-141 (节选)
class WaypointFlood
{
public:
    bool setArea(const Vector3& min, const Vector3& max, float resolution);
    void setPhysics(IPhysics* pPhysicsInterface);
    void setChunk( Chunk * pChunk );
    int  fill(const Vector3& seedPoint, IProgress * pProgress = NULL, bool debug = false );
    void flashFlood( float height );
    void postfilteradd();
    void postfilterremove();
    void shrink();
    bool writeTGA(const char* filename) const;
    static const uint MAX_HEIGHTS = 16;
private:
    Vector3  min_, max_;
    float    resolution_;
    int      xsize_, zsize_, size_;
    float*         hgtGrids_[MAX_HEIGHTS];
    AdjGridElt *   adjGrids_[MAX_HEIGHTS];
    IPhysics*      pPhysics_;
    Chunk *        pChunk_;
    BW::set<std::pair<int, int> > boundarySet_;
    int            smallestHeight_;
};
```

洪水填充的核心思路:

1. **设置区域**(`setArea`):根据 chunk 包围盒与采样分辨率(通常 0.1m 或 0.2m)建立网格。
2. **设置物理接口**(`setPhysics`):`PhysicsHandler` 实现 `IPhysics`,提供 `findDropPoint`(下落测试)、`isUnblocked`(通行测试)、`adjustMove`(移动调整)。
3. **从种子点扩散**(`fill` / `flashFlood`):BFS 式扩散,对每个网格点的 8 方向邻居做碰撞测试,记录到 `AdjGridElt` 的对应 4 位字段。
4. **多层高度**:一个网格点可能有多个可站立高度(如桥上桥下),最多 16 层。
5. **后处理**(`postfilteradd/postfilterremove/shrink`):滤除孤岛、收缩边缘(按 girth 半径)。

`IPhysics` 接口(`waypoint_flood.hpp` L41-77)定义了物理查询契约:

```cpp
// waypoint_flood.hpp L41-77
struct IPhysics
{
    virtual Vector3 getGirth() const = 0;                          # 实体尺寸
    virtual float   getScrambleHeight() const = 0;                 # 攀爬高度
    virtual bool    findDropPoint(const Vector3& pos, float& y) = 0; # 下落测试
    virtual bool    isUnblocked(const Vector3& src, const float anotherY) { ... }
    virtual void    adjustMove(const Vector3& src, const Vector3& dst, Vector3& dst2) = 0;
};
```

`isUnblocked` 的默认实现利用 `findDropPoint` 判断两点之间是否可无障碍通行(高度差在 `DROP_FUDGE = 0.1f` 内视为同高)。

### 7.3 邻接方向编码

`g_dx` / `g_dz`(`navgen.cpp` L361-362)定义了 8 方向的偏移,与 `AdjGridElt.each` 的字段顺序一致:

```cpp
// navgen.cpp L361-362
int g_dx[8] = {0, 1, 1, 1, 0, -1, -1, -1};
int g_dz[8] = {1, 1, 0, -1, -1, -1, 0, 1};
```

| 索引 | 字段 | dx | dz | 方向 |
|------|------|----|----|------|
| 0 | u | 0 | 1 | +Z(上) |
| 1 | ur | 1 | 1 | +X+Z(右上) |
| 2 | r | 1 | 0 | +X(右) |
| 3 | dr | 1 | -1 | +X-Z(右下) |
| 4 | d | 0 | -1 | -Z(下) |
| 5 | dl | -1 | -1 | -X-Z(左下) |
| 6 | l | -1 | 0 | -X(左) |
| 7 | ul | -1 | 1 | -X+Z(左上) |

### 7.4 writeTGAs 调试输出

`g_writeTGAs`(默认 `true`)控制是否把每层邻接位图输出为 TGA 图像,便于美术 / 程序可视化检查洪水填充结果。`WaypointFlood::writeTGA` 把 `adjGrids_[g]` 的 8 方向位编码成像素颜色。

---

## 八、BSP 分割与多边形生成:WaypointGenerator

### 8.1 generate 总流程

`WaypointGenerator::generate`(声明于 `waypoint_generator.hpp` L49)是 BSP 阶段的入口,其内部调用链(由私有方法签名 L203-222 推断)为:

```
generate():
  initBSP()                        # 初始化根 BSPNode(覆盖整个网格)
  processNode(indexStack)          # 递归处理节点栈
    ├─ findDispoints(frontNode)    # 查找分割点
    ├─ calcSplitValue(node, split) # 计算最优分割
    ├─ doBestHorizontalSplit()     # 尝试水平分割
    ├─ splitNode(index, split)     # 执行分割,生成 front/back 子节点
    └─ processNode(indexStack)     # 递归
  generatePoints()                 # 从 BSP 叶子提取唯一顶点
  generatePolygons()               # 由顶点构造多边形
  generateAdjacencies()            # 计算多边形邻接
  joinPolygons()                   # 合并相邻可合并多边形
```

### 8.2 BSPNode 分割策略

`calcSplitValue` 与 `doBestHorizontalSplit` 是分割质量的关键。分割目标是把一个节点切成两个"尽量均匀且凸"的子节点。`SplitDef`(`waypoint_generator.hpp` L110-120)描述一次分割:

```cpp
// waypoint_generator.hpp L110-120
struct SplitDef
{
    static const int VERTICAL_SPLIT = 8;
    int      normal;       # 分割法向(0/1 为垂直于 X/Z 轴,8 为水平高度分割)
    float    value;        # 分割线位置
    union
    {
        float position[2]; # 垂直分割时的边界
        float heights[2];  # 水平分割时的高低分界
    };
};
```

水平分割(`doBestHorizontalSplit`)用于处理一个节点内有高度差的情况(如台阶),把高区与低区分开,避免一个多边形跨越大高度差。

### 8.3 顶点与多边形生成

`generatePoints`(L213)从 BSP 叶子节点的边界提取候选顶点,去重后存入 `points_`(`BW::set<PointDef>`)。`PointDef`(L122-133):

```cpp
// waypoint_generator.hpp L122-133
struct PointDef
{
    int     angle;        # 角度(方向索引)
    float   offset;       # 偏移
    float   t;            # 参数
    float   minHeight;
    float   maxHeight;
    bool operator<(const PointDef& v) const;
    bool operator==(const PointDef& v) const;
    bool nearlySame(const PointDef& v) const;
};
```

`generatePolygons`(L214)把每个 BSP 叶子的顶点按顺序连成凸多边形(`PolygonDef`)。`generateAdjacencies`(L215)通过共享顶点 / 边建立多边形间的邻接关系,`joinPolygons`(L221)进一步合并可合并的相邻多边形以减少多边形数量。

### 8.4 isConvexJoint 凸性判断

`isConvexJoint`(L218)判断三个顶点形成的关节是否为凸,用于决定多边形能否在合并时保持凸性。寻路系统要求 navPoly 必须是凸多边形,这是 BSP + 合并算法的根本约束。

---

## 九、邻接、注解与集合归属

### 9.1 跨 chunk 邻接边

`determineEdgesAdjacentToOtherChunks`(`chunk_waypoint_generator.cpp` L169-170)用 `PhysicsHandler` 做物理测试,判断多边形的哪些边通向相邻 chunk:

```cpp
// chunk_waypoint_generator.cpp L169-170
PhysicsHandler phand( pChunk_->space(), gSpec );
gener_.determineEdgesAdjacentToOtherChunks( pChunk_, &phand );
```

被标记为 `adjToAnotherChunk` 的边(`VertexDef::adjToAnotherChunk`)在运行时寻路系统会尝试跨越 chunk 边界连接到邻 chunk 的对应多边形。

### 9.2 streamline 多边形精简

`gener_.streamline()`(`chunk_waypoint_generator.cpp` L174)合并相邻且合并后仍为凸的多边形,减少 navPoly 数量,降低寻路图规模。

### 9.3 WaypointAnnotator 边注解

当 `g_annotate` 为真时,`WaypointAnnotator`(`tools/common/waypoint_annotator.hpp`)给边标注:

- **可见性**:从该边能否看到目标(用于 AI 决策)。
- **动作**:跳跃、攀爬、下落等特殊动作标签。

```cpp
// chunk_waypoint_generator.cpp L182-187
if( annotate )
{
    WaypointAnnotator wanno( &gener_, pChunk_->space() );
    wanno.annotate();
}
```

### 9.4 extendThroughUnboundPortals

`gener_.extendThroughUnboundPortals( pChunk_ )`(L190)把多边形扩展穿过 chunk 的未绑定 portal,确保导航网格在 chunk 边界处的连续性。

### 9.5 calculateSetMembership 集合归属

`gener_.calculateSetMembership( entityPts_, pChunk_->identifier() )`(L194)根据种子点(`entityPts_`)决定每个多边形属于哪个"集合"。集合用于把一个 chunk 内的多边形分组,运行时寻路可以按集合过滤。

---

## 十、输出与脏标志

### 10.1 output 写入 .cdata

`output`(`chunk_waypoint_generator.cpp` L242-273)调用 `WaypointGenerator::saveOut` 把多边形写入 chunk 的 `.cdata` 文件:

```cpp
// chunk_waypoint_generator.cpp L242-273
void ChunkWaypointGenerator::output( float girth, bool firstGirth )
{
#if 0
    # 旧路径:直接操作 chunk 的 XML section(已注释)
    ...
#else
    gener_.saveOut( pChunk_, girth, /*removeAllOld:*/firstGirth );
#endif
}
```

`firstGirth` 参数控制是否清除所有旧数据:第一个 girth 生成时清除所有旧的 `waypointSet` / `navPolySet`,后续 girth 只追加自己的集合。

### 10.2 outputDirtyFlag 脏标志

`outputDirtyFlag`(`chunk_waypoint_generator.cpp` L201-236)把 `navmeshDirty` 标志写回 `.cdata`:

```cpp
// chunk_waypoint_generator.cpp L201-236 (节选)
void ChunkWaypointGenerator::outputDirtyFlag( bool dirty /*= false*/ )
{
    DataSectionPtr chunkBinSection = BWResource::openSection( pChunk_->binFileName() );
    if (chunkBinSection)
    {
        DataSectionPtr navmeshDirtySection = chunkBinSection->openSection( s_navmeshDirtyStr, true );
        if (navmeshDirtySection)
        {
            navmeshDirtySection->setBinary
            (
                new BinaryBlock( &dirty, sizeof(dirty), "BinaryBlock/ChunkWaypointGenerator" )
            );
            navmeshDirtySection->setParent( chunkBinSection );
            navmeshDirtySection->save();
            ...
        }
    }
    chunkBinSection->save();
}
```

生成完毕后 `doGenerate` / `doGenerateAll` 都会调用 `cwg.outputDirtyFlag( false )`,清除脏标志。

### 10.3 .cdata 文件结构

生成的 `.cdata` 二进制 section 结构(由 `saveOut` 与读取代码推断):

```
chunk.cdata (ZipSection)
├── navmeshDirty           # bool,是否需要重新生成
├── auxData/
│   └── worldNavmesh       # 完整世界导航网格(增量生成检查用)
├── waypointSet (legacy)   # 旧格式
│   └── girth
└── navPolySet             # 新格式(每个 girth 一个)
    └── girth
    └── (多边形 + 顶点 + 邻接 + 注解 二进制数据)
```

`doGenerateAll` 中的增量检查(`navgen.cpp` L2375-2390)读取 `auxData/worldNavmesh` 判断是否已有数据:

```cpp
// navgen.cpp L2375-2390
bool modified = true;
DataSectionPtr chunkBinSection = BWResource::openSection( g_currentChunk->binFileName() );
if (chunkBinSection)
    modified = !chunkBinSection->openSection( "auxData/worldNavmesh" );
if (!modified)        # 已有 worldNavmesh,跳过
{
    g_calcChunksDone.insert( g_currentChunk );
    g_calcChunksNotDirty.insert( g_currentChunk );
    g_statusWindow.skip();
    continue;
}
```

---

## 十一、doGenerate 单 chunk 生成流程

`doGenerate`(`navgen.cpp` L1819-1911)处理单个 chunk 的完整生成,通常由菜单 `CHUNK_GENERATE` 触发:

```cpp
// navgen.cpp L1819-1911
void doGenerate( Chunk * pChunk )
{
    if (!checkAllowGenerate()) return;                # 检查 navmeshGenerator 配置
    NavGenGenerating generating;                      # RAII:关屏保,设 g_generating
    NavgenScopedMenuDisabler md;                      # RAII:禁用菜单

    if (!isChunkLocked( pChunk ))                     # 必须 bwlockd 锁定
    {
        MessageBox( ... L"Chunk not locked" ... );
        return;
    }
    if (!waitChunkLoaded( pChunk, true ))             # 等待 chunk 及邻居加载
    {
        MessageBox( ... L"Cannot load chunk and its neighbour" ... );
        return;
    }

    ModelessInfoDialog dlg( g_hWindow, L"Please Wait", L"...Please wait..." );  # 进度对话框

    ChunkWaypointGenerator cwg( pChunk, g_floodResultPath );
    BW::vector<float> girthsToCalculate = compileGirthsList( pChunk );   # 计算需要的 girth 列表

    DataSectionPtr pChunkSect = BWResource::openSection( pChunk->resourceID() );
    # 清除旧 waypointSet/navPolySet
    for ( int i = 0; i < pChunkSect->countChildren(); ++i )
    {
        DataSectionPtr ds = pChunkSect->openChild( i );
        if ( !((ds->sectionName() == "waypointSet") ||
            (ds->sectionName() == "navPolySet")) ) continue;
        pChunkSect->delChild( ds );
        --i;
    }

    # 对每个 girth 生成
    for ( uint gi = 0; gi < girthsToCalculate.size(); ++gi )
    {
        if ( g_pleaseShutdown ) return;
        Girth gSpec = g_girthSpecs.find( girthsToCalculate[gi] )->second;
        cwg.flood( generateOneProgress, gSpec, g_writeTGAs );    # ① 洪水填充
        if ( g_pleaseShutdown ) return;
        cwg.generate( g_annotate, gSpec );                       # ② 生成
        cwg.output( girthsToCalculate[gi], gi == 0 );            # ③ 输出
    }
    cwg.outputDirtyFlag( false );                                # 清除脏标志
}
```

### 11.1 checkAllowGenerate

`checkAllowGenerate`(`navgen.cpp` L518-533)检查空间的 `navmeshGenerator` 配置是否为 `"navgen"`,否则只读:

```cpp
// navgen.cpp L512-533
bool isCorrectNavmeshGenerator()
{
    return g_currentNavmeshGenerator.empty() ||
        g_currentNavmeshGenerator == "navgen";
}
bool checkAllowGenerate()
{
    if (!isCorrectNavmeshGenerator())
    {
        MsgBox mb( L"NavGen",
            bw_utf8tow( "NavGen is in Read Only mode as this space is"
                " not configured to be generated using NavGen." ), L"OK" );
        mb.doModal( g_hWindow );
        return false;
    }
    return true;
}
```

### 11.2 isChunkLocked

`isChunkLocked`(`navgen.cpp` L1561-1599)通过 `bwlockd` 服务检查当前用户是否锁定了该 chunk 对应的网格:

```cpp
// navgen.cpp L1561-1599 (节选)
bool isChunkLocked( Chunk * chunk )
{
    if( !g_chunkSet.empty() )                          # /g 模式:只处理列表中的 chunk
    {
        if( g_chunkSet.find( chunk->identifier() ) == g_chunkSet.end() )
            return false;
    }
    if (!g_conn.enabled()) return true;                # 未启用锁服务,视为已锁
    if (!g_conn.connected()) return false;
    Vector3 centre = chunk->boundingBox().centre();
    ChunkSpace * space = chunk->space();
    float gridSize = space->gridSize();
    int gridX = worldToGridCoord( centre.x, gridSize );
    int gridY = worldToGridCoord( centre.z, gridSize );
    ...
    return g_conn.isLockedByMe( gridX, gridY );
}
```

### 11.3 waitChunkLoaded

`waitChunkLoaded`(`navgen.cpp` L1944-1992)同步等待 chunk 及其邻居加载完成,因为洪水填充需要碰撞场景(包括邻居 chunk 的障碍)就绪:

```cpp
// navgen.cpp L1944-1992 (节选)
bool waitChunkLoaded(Chunk *chunk, bool neighbourhood)
{
    if (!chunk->loaded())
    {
        ChunkManager::instance().loadChunkNow( chunk->identifier(), g_mapping );
        ChunkManager::instance().checkLoadingChunks();
    }
    MF_ASSERT( chunk->loaded() );
    MF_ASSERT( chunk->isBound() );
    g_camMatrix.translation( chunk->centre() );        # 相机移到 chunk 中心(触发加载)
    g_currentChunk = chunk;
    if (neighbourhood)
    {
        DWORD start = GetTickCount();
        while (!ChunkWaypointGenerator::canProcess(chunk))   # 检查邻居是否就绪
        {
            if ( g_pleaseShutdown ) return false;
            processHarmlessMessages();
            drawGenerateAllProgress();
            Sleep( s_chunkLoadSleep );
        }
        if (GetTickCount() - start >= s_chunkLoadRetryTicks)  # 超时
            return false;
    }
    ChunkManager::instance().camera( g_camMatrix, ChunkManager::instance().cameraSpace() );
    return true;
}
```

### 11.4 compileGirthsList

`compileGirthsList`(`navgen.cpp` L1601-1655)决定 chunk 需要生成哪些 girth:

```cpp
// navgen.cpp L1601-1655 (节选)
BW::vector<float> compileGirthsList( Chunk * pChunk )
{
    BW::vector<float> girthsReturn = g_girthsAlwaysGenerate;   # 起点:所有 always=true 的 girth
    BoundingBox cbb = pChunk->boundingBox();
    # 检查每个 NavGenUDO 种子是否影响此 chunk
    NavGenUDO::GirthSeeds::iterator it = NavGenUDO::s_girthSeeds.begin();
    while (it != NavGenUDO::s_girthSeeds.end())
    {
        float girth = it->second.girth;
        float range = it->second.generateRange;
        const Vector3 & point = it->second.position;
        # 计算种子影响范围 AABB
        BoundingBox npBB( Vector3( x1, y1, z1 ), Vector3( x2, y2, z2 ) );
        # 与 chunk 包围盒求交
        if ( npBB.intersects( pChunk->boundingBox() ) )
        {
            # 不在列表则加入
            if (k == girthsReturn.size() )
                girthsReturn.push_back(girth);
        }
        ++it;
    }
    return girthsReturn;
}
```

即:每个 chunk 至少生成 `always=true` 的 girth(通常是 0.5),如果 chunk 落在某个 `WayPointSeed` UDO 的影响范围内,则额外生成该 UDO 指定 girth 的导航网格。

### 11.5 NavGenGenerating RAII

`NavGenGenerating`(`navgen.cpp` L422-438+)是生成期间的守卫,它:

- 保存并设置 `g_generating = true`。
- 关闭屏保 / 省电超时(`SystemParametersInfo`),防止生成中途系统休眠。
- 析构时恢复原值。

```cpp
// navgen.cpp L422-438 (节选)
class NavGenGenerating
{
public:
    NavGenGenerating()
    {
        oldGenerating_ = g_generating;
        g_generating = true;
        for (size_t i = 0; i < s_scrnSaverListSz; ++i)
        {
            SystemParametersInfo(s_scrnSaverList[i].first , 0, &scrnParams_[i], 0);
            SystemParametersInfo(s_scrnSaverList[i].second, 0, NULL           , 0);   # 关闭
        }
    }
    ...
};
```

---

## 十二、doGenerateAll 全空间批量生成

`doGenerateAll`(`navgen.cpp` L2257-2530)是命令行模式与"Generate All"菜单的核心,遍历空间所有 chunk 生成导航网格。

### 12.1 总体流程

```cpp
// navgen.cpp L2257-2530 (结构化节选)
void doGenerateAll( bool overwrite = false )
{
    if (!checkAllowGenerate()) return;
    if (overwrite) doClearAll();                       # /overwrite:先清除所有
    unloadAllChunks();                                 # 卸载绘图用的 chunk

    # RAII:临时把加载距离设为 0 + 同步地形加载(最小化加载量)
    GenerateAllEnvironmentSetter generateAllEnvironmentSetter;

    g_statusWindow.begin( L"Generating" );
    NavGenGenerating generating;
    ScopedSetReady scopedSetReady;
    NavgenScopedMenuDisabler md;

    # 遍历空间所有 chunk
    for (ChunkSpaceTraverser cst; !cst.done(); cst.next())
    {
        processHarmlessMessages();                     # 保持 UI 响应
        Moo::rc().preloadDeviceResources( 1000 );
        if (g_pleaseShutdown) return;

        g_currentChunk = cst.chunk();

        # ① 集群分片过滤
        if( hash( g_currentChunk->identifier().c_str() ) % g_totalComputers != g_myIndex )
            continue;                                  # 不属于本机,跳过

        # ② 锁检查(室外 chunk 加载前检查)
        if (g_currentChunk->isOutsideChunk() && !isChunkLocked( g_currentChunk ))
            continue;

        # ③ 增量检查:已有 worldNavmesh 则跳过
        if (g_currentChunk->isOutsideChunk())
        {
            bool modified = true;
            DataSectionPtr chunkBinSection = BWResource::openSection( g_currentChunk->binFileName() );
            if (chunkBinSection)
                modified = !chunkBinSection->openSection( "auxData/worldNavmesh" );
            if (!modified) continue;
        }

        # ④ 加载 chunk 及邻居
        bool loaded = waitChunkLoaded( g_currentChunk, true );
        if( !loaded ) { errors = true; continue; }

        # ⑤ 室内 chunk 锁检查(加载后)
        if (!g_currentChunk->isOutsideChunk() && !isChunkLocked( g_currentChunk ))
            continue;

        ChunkWaypointGenerator cwg( g_currentChunk, g_floodResultPath );
        if (!cwg.modified()) continue;                 # 未修改,跳过

        # ⑥ 对每个 girth 生成
        BW::vector<float> girthsToCalculate = compileGirthsList( g_currentChunk );
        for ( uint gi = 0; gi < girthsToCalculate.size(); ++gi )
        {
            if ( g_pleaseShutdown ) return;
            Girth gSpec = g_girthSpecs.find( girthsToCalculate[gi] )->second;
            cwg.flood( floodProgressCallback, gSpec, g_writeTGAs );
            if ( g_pleaseShutdown ) return;
            cwg.generate(g_annotate, gSpec);
            cwg.output( girthsToCalculate[gi], gi == 0 );
        }
        cwg.outputDirtyFlag( false );

        updateMoo( 0.1f, false );                      # 推进 Moo(资源回收)
        DataSectionCache::instance()->clear();         # 清缓存
        DataSectionCensus::clear();
    }

    unloadAllChunks();
    # 错误汇总与重绘
}
```

### 12.2 GenerateAllEnvironmentSetter

`GenerateAllEnvironmentSetter`(`navgen.cpp` L2277-2297)是 RAII,在批量生成期间临时调整环境以最小化加载:

```cpp
// navgen.cpp L2277-2297
class GenerateAllEnvironmentSetter
{
    bool showingMoo_;
public:
    GenerateAllEnvironmentSetter()
    {
        ChunkManager::instance().autoSetPathConstraints( 0 );        # 加载距离设为 0
        ChunkManager::instance().switchToSyncTerrainLoad( true );    # 同步地形加载
    }
    ~GenerateAllEnvironmentSetter()
    {
        ChunkManager::instance().autoSetPathConstraints( g_chunkLoadDistance );  # 恢复
        ChunkManager::instance().switchToSyncTerrainLoad( false );
    }
}
generateAllEnvironmentSetter;
```

把加载距离设为 0 是因为 `waitChunkLoaded` 仍会显式加载需要的 chunk 与邻居,而背景的自动加载反而会拖慢生成。

### 12.3 doClearAll 清除

`doClearAll`(`navgen.cpp` L2039-2255)遍历空间所有 chunk,删除其 `waypointSet` / `navPolySet` / `waypoint` / `navPoly` section。它也用集群分片过滤(`hash % g_totalComputers`),确保只清除本机负责的 chunk。在 `overwrite=true` 时由 `doGenerateAll` 调用。

### 12.4 ChunkSpaceTraverser

`ChunkSpaceTraverser`(`navgen.cpp` L1123 附近声明)遍历 `ChunkSpace` 中所有已知的 chunk(包括室外网格 chunk 与室内 chunk)。`cst.chunk()` 返回当前 chunk,`cst.next()` 前进,`cst.done()` 判断结束。

### 12.5 进度回调

`floodProgressCallback`(在 `doGenerateAll` 中使用,与 `generateOneProgress` L1804-1815 类似)在洪水填充每个点后调用,处理 Windows 消息并检查 `g_pleaseShutdown`,允许用户中途取消:

```cpp
// navgen.cpp L1804-1815
bool generateOneProgress( int npoints )
{
    processHarmlessMessages();
    if ( g_pleaseShutdown )
        return true;          # 返回 true 中断 flood 循环
    return false;
}
```

---

## 十三、集群分片机制

### 13.1 多机并行生成

navgen 支持把一个空间的导航网格生成任务分发到多台机器并行执行,通过菜单 `FILE_CLUSTERGENERATE` 或命令行参数配置。核心是 `g_totalComputers` / `g_myIndex` 两个全局变量与 `hash` 函数。

### 13.2 hash 函数(RC4 风格)

`hash`(`navgen.cpp` L1913-1941)是一个 RC4 风格的字符串哈希,把 chunk 标识符映射到 0-255:

```cpp
// navgen.cpp L1913-1941
unsigned int hash( const char* str )
{
    static unsigned char hash[ 256 ];
    static bool inithash = true;
    if( inithash )
    {
        inithash = false;
        for( int i = 0; i < 256; ++i )
            hash[ i ] = i;                              # 初始化置换表
        int k = 7;
        for( int j = 0; j < 4; ++j )                   # 4 轮洗牌
            for( int i = 0; i < 256; ++i )
            {
                unsigned char s = hash[ i ];
                k = ( k + s ) % 256;
                hash[ i ] = hash[ k ];
                hash[ k ] = s;
            }
    }
    unsigned char result = ( 123 + strlen( str ) ) % 256;
    for( unsigned int i = 0; i < strlen( str ); ++i )
    {
        result = ( result + str[ i ] ) % 256;
        result = hash[ result ];                       # 查表置换
    }
    return result;
}
```

这是一种类似 RC4 KSA(Key Scheduling Algorithm)的置换,目的是让 chunk 名到 0-255 的分布尽量均匀,避免相邻 chunk 集中在同一台机器。

### 13.3 分片判定

在 `doGenerateAll` / `doClearAll` 中,每个 chunk 用如下判定决定是否由本机处理:

```cpp
// navgen.cpp L2354-2360
if( hash( g_currentChunk->identifier().c_str() ) % g_totalComputers != g_myIndex )
{
    INFO_MSG( "Skip chunk %s because hash failed\n", g_currentChunk->identifier().c_str() );
    g_statusWindow.skip();
    continue;
}
```

- `g_totalComputers`:总机器数(默认 1)。
- `g_myIndex`:本机索引(0-based,默认 0)。

当 `g_totalComputers == 1` 时,`hash % 1 == 0 == g_myIndex`,所有 chunk 都由本机处理。

### 13.4 集群生成对话框

`clusterDialogProc`(`navgen.cpp` L5145-5201)是集群配置对话框,允许用户选择总机器数(2-49)与本机索引:

```cpp
// navgen.cpp L5151-5168 (节选)
case WM_INITDIALOG:
    for( int i = 2; i < 50; ++i )                     # 总机器数 2..49
        SendDlgItemMessage( hwnd, IDC_TOTALCOMPUTER, CB_ADDSTRING, ... );
    for( int i = 0; i < 2; ++i )                      # 初始本机索引 0..1
        SendDlgItemMessage( hwnd, IDC_MYINDEX, CB_ADDSTRING, ... );
    g_totalComputers = 2;
    g_myIndex = 0;
```

选择后调用 `doGenerateAll( false )`(不覆盖,只生成属于本机的 chunk),完成后恢复 `g_totalComputers = 1; g_myIndex = 0;`。

---

## 十四、配置项与命令行参数

### 14.1 命令行参数

| 参数 | 说明 | 解析位置 |
|------|------|---------|
| `/s <space>` | 命令行模式,指定空间路径 | L4928-4950 |
| `/g <file>` | chunk 列表文件(每行一个 chunk 名) | L4953-4995 |
| `/overwrite` | 覆盖生成(先清除) | L5039 |
| `--settings <file>` | 自定义 navgen_settings.xml 路径 | L4771-4777 |
| `-res <path>` | BWResource 资源路径(标准 BW 参数) | BWResource::init |

### 14.2 navgen_settings.xml 配置项

| 配置键 | 类型 | 默认值 | 说明 | 读取位置 |
|--------|------|--------|------|---------|
| `annotate` | bool | false | 是否进行边注解 | L4790 |
| `processor` | int | 1 | 处理器(未实际使用,保留) | L4904 |
| `writeTGAs` | bool | true | 是否输出洪水填充 TGA 调试图 | L4905 |
| `reannotation` | bool | false | 是否启用重注解菜单 | L4906, L4911-4914 |
| `loadDistance` | float | 500.0 | chunk 加载距离 | L4916 |
| `graphicsPreferences` | section | - | Moo 图形设置 | L4907-4910 |
| `space/mru0` | string | - | 最近打开的空间(MRU) | L3546 |
| `bwlockd/host` | string | - | bwlockd 服务地址 | L3549 |
| `bwlockd/username` | string | - | bwlockd 用户名(空则取系统用户名) | L3550, L3558-3564 |
| `bigbangd/host` | string | - | 旧名,兼容 | L3554 |
| `bigbangd/username` | string | - | 旧名,兼容 | L3555 |
| `floodResultPath` | string | - | 洪水填充结果缓存路径 | L3566 |
| `language` | string list | - | 国际化语言文件列表 | L4796-4802 |
| `currentLanguage` | string | - | 当前语言 | L4810 |
| `currentCountry` | string | - | 当前国家 | L4811 |

### 14.3 engine_config.xml

| 配置键 | 说明 | 读取位置 |
|--------|------|---------|
| `shouldReadXMLAttributes` | XML 属性读取模式 | L4764-4765 |
| `shouldWriteXMLAttributes` | XML 属性写入模式 | L4766-4767 |

### 14.4 resources.xml

通过 `AutoConfig::configureAllFrom("resources.xml")` 加载,定义:

- `system/language`:默认语言文件(`s_LanguageFile`,L129)
- `system/engineConfigXML`:engine_config.xml 路径(`s_engineConfigXML`,L130)

### 14.5 Girth 配置

Girth 规格在 `Girths` 构造时从资源加载(通常 `helpers/girths.xml` 或类似),每个 Girth 包含 `girth/width/height/depth/maxSlope/maxClimb/always` 字段。`girth=0.5` 是强制要求(L3735-3738)。

---

## 十五、菜单与交互模式

### 15.1 菜单结构

navgen 主菜单(`IDR_MENU1`)在 `resource.h` 中定义,主要命令:

#### File 菜单

| 命令 ID | 名称 | 处理函数 | 说明 |
|---------|------|---------|------|
| `ID_FILE_OPENSPACE` (116) | Open Space | `changeSpace` | 打开空间(浏览) |
| `ID_FILE_OPEN1` (40006) | Open | `doFileOpen` | 打开 chunk 文件 |
| `ID_FILE_GENERATE_ALL` (105) | Generate All | `doGenerateAll()` | 生成所有 chunk |
| `ID_FILE_GENERATE_ALL_OVERWRITE` (112) | Generate All (Overwrite) | `doGenerateAll(true)` | 覆盖生成 |
| `ID_FILE_CLUSTERGENERATE` (118) | Cluster Generate | `doGenerateAll(false)` | 集群生成 |
| `ID_FILE_CLEAR_ALL` (40013) | Clear All | `doClearAll()` | 清除所有导航数据 |
| `ID_FILE_EXIT` (40005) | Exit | `DestroyWindow` | 退出 |

#### Chunk 菜单

| 命令 ID | 名称 | 处理 | 说明 |
|---------|------|------|------|
| `ID_CHUNK_GENERATE` (107) | Generate | `chunkOp(CO_GENERATE)` | 生成当前 chunk |
| `ID_CHUNK_REANNOTATE` (109) | Reannotate | `chunkOp(CO_REANNOTATE)` | 重新注解(仅 `reannotation=true`) |
| `ID_CHUNK_DISPLAY` (110) | Display | `chunkOp(CO_DISPLAY)` | 显示当前 chunk |

#### View 菜单

| 命令 ID | 名称 | 切换变量 | 说明 |
|---------|------|---------|------|
| `ID_VIEW_BSPNODES` (111) | BSP Nodes | `g_viewBSPNodes` | 显示 BSP 节点 |
| `ID_VIEW_ADJACENCIES` (40001) | Adjacencies | `g_viewAdjacencies` | 显示邻接关系 |
| `ID_VIEW_POLYGONAREA` (40003) | Polygon Area | `g_viewPolygonArea` | 显示多边形区域 |
| `ID_VIEW_POLYGONBORDERS` (40002) | Polygon Borders | `g_viewPolygonBorders` | 显示多边形边界 |
| `ID_VIEW_STATISTICS` (40007) | Statistics | `StatsProc` 对话框 | 统计信息 |
| `ID_VIEW_WAYPOINTINFO` (40011) | Waypoint Info | `g_hInfoDialog` | 航点信息 |
| `ID_VIEW_RENDEREDSCENE` (40012) | Rendered Scene | `g_hMooWindow` | 3D 渲染场景 |
| `ID_VIEW_ERRORLOG` (115) | Error Log | `AsyncMessage` | 错误日志 |
| `ID_VIEW_SET` (40016) | Set | - | 集合过滤 |
| `ID_VIEW_SET_ALL` (40017) | Set All | `updateViewSetMenu(true)` | 显示所有集合 |
| `ID_VIEW_SET_NONE` (40018) | Set None | `updateViewSetMenu(false)` | 隐藏所有集合 |

#### Zoom

| `ID_ZOOM_IN` (40008) | `zoom(1/ZOOM_FACTOR)` | 放大 |
| `ID_ZOOM_OUT` (40009) | `zoom(ZOOM_FACTOR)` | 缩小 |

`ZOOM_FACTOR = 1.5f`(L144)。

### 15.2 wndProc 主窗口过程

`wndProc`(`navgen.cpp` L2996+)处理主窗口消息。`WM_COMMAND` 分发菜单命令(L3160-3303):

```cpp
// navgen.cpp L3164-3208 (节选)
case ID_FILE_OPENSPACE:
    { BW::string space = g_spaceManager->browseForSpaces( g_hWindow ); ... }
    break;
case ID_FILE_CLEAR_ALL:
    if( ::MessageBox( ..., L"Confirm Clearing...", MB_YESNO ) == IDNO ) break;
    doClearAll();
    break;
case ID_FILE_GENERATE_ALL:
    doGenerateAll();
    break;
case ID_FILE_GENERATE_ALL_OVERWRITE:
    if( ::MessageBox( ..., L"Confirm Overwriting...", MB_YESNO ) == IDNO ) break;
    doGenerateAll( true );
    break;
case ID_FILE_CLUSTERGENERATE:
    if( DialogBox( ..., IDD_CLUSTERGENDIALOG, ..., clusterDialogProc ) == IDOK )
        doGenerateAll( false );
    g_totalComputers = 1; g_myIndex = 0;
    break;
```

### 15.3 状态栏 NavgenStatusWindow

`NavgenStatusWindow`(`navgen.cpp` L159-...)是 6 段状态栏,显示生成进度:

```cpp
// navgen.cpp L169-185
bool create( HWND parent )
{
    hwnd_ = CreateStatusWindow( WS_CHILD | WS_VISIBLE, L"", parent, 0);
    int partWidth[] = {
        150,  # action: clearing/generating/...
        320,  # processed
        420,  # skip
        540,  # elapsed time
        640,  # average time
        -1 }; # 其余
    SendMessage( hwnd_, SB_SETPARTS, ARRAY_SIZE( partWidth ), (LPARAM)partWidth );
    return !!hwnd_;
}
```

`begin(action)` 记录开始时间,`process(chunk)` 增加已处理计数,`skip()` 增加跳过计数,`end()` 结束。

### 15.4 交互模式主循环

交互模式主循环(L5045-5083)是典型的 Win32 消息循环 + 游戏帧:

```cpp
// navgen.cpp L5045-5083
uint64 timeLast = timestamp();
while(1)
{
    if (g_pleaseShutdown) break;
    # 处理 Windows 消息
    while (PeekMessage( &msg, NULL, 0, 0, PM_NOREMOVE ))
    {
        if (!GetMessage(&msg, NULL, 0, 0)) break;
        if (TranslateAccelerator(g_hWindow, g_accelerators, &msg)) continue;
        if (!IsDialogMessage(g_hInfoDialog, &msg))
        {
            TranslateMessage(&msg);
            DispatchMessage(&msg);
        }
    }
    # 计算 dTime
    uint64 timeNow = timestamp();
    float dTime = float( double(timeNow-timeLast) / stampsPerSecondD() );
    timeLast = timeNow;
    MF_ASSERT( MainThreadTracker::isCurrentThreadMain() );
    # 推进 Script 与场景
    incrementTotalTime( dTime );
    Script::tick( getTotalTime() );
    updateMoo( dTime );
    if (IsWindowVisible( g_hMooWindow ))
        drawMoo( dTime );
}
```

`Script::tick` 推进 Python 脚本回调(如 `BigWorld.callback`),`updateMoo` 推进 Moo 渲染与 chunk 加载,`drawMoo` 绘制 3D 场景。

### 15.5 AsyncMessage 日志系统

`AsyncMessage`(`asyn_msg.hpp` L7-21 / `asyn_msg.cpp`)是独立线程的日志与错误对话框:

```cpp
// asyn_msg.hpp L7-21
class AsyncMessage
{
public:
    void reportMessage( const wchar_t* msg, bool severity );   # severity=true 弹窗, false 仅日志
    void show();
    void hide();
    bool isShow() const;
    HWND handle();
    const wchar_t* getLogFileName() const;
    void printMsg( const wchar_t * msg ) const;
private:
    BW::wstring dateMsg( const wchar_t * msg ) const;
    void writeToLog( const wchar_t * msg ) const;
};
```

`asyn_msg.cpp` 末尾的 `ThreadCreator` 全局对象在程序启动时 `_beginthread( AsyncMessageThread, ... )` 创建日志线程,并自旋等待对话框 `hwnd` 就绪:

```cpp
// asyn_msg.cpp L178-196
struct ThreadCreator
{
    ThreadCreator()
    {
        BW_GUARD;
        _beginthread( AsyncMessageThread, 0, NULL );
        while( !hwnd ) Sleep( 1 );            # 等待日志线程就绪
    }
    ~ThreadCreator()
    {
        EndDialog( hwnd, 0 );                 # 程序退出时关闭对话框
    }
}
ThreadCreator;                                # 全局对象,main 前构造
```

`AsyncMessageThread`(L48-76)创建 `.log` 文件(与 exe 同名,扩展名 `.log`)与 `IDD_MESSAGEDIALOG` 对话框。`ErrorLogHandler`(`navgen.cpp` L547+)同时继承 `AsyncMessage` 与 `DebugMessageCallback`,把 BigWorld 的 `DEBUG_MSG/ERROR_MSG` 转发到日志对话框。

---

## 十六、依赖关系

### 16.1 库依赖

`CMakeLists.txt` L83-99 声明的链接库:

| 库 | 用途 |
|----|------|
| `chunk` | chunk 系统(Chunk/ChunkManager/ChunkSpace/ChunkCache/ChunkItem) |
| `cstdmf` | 基础设施(计时器/线程/内存/调试/守卫) |
| `chunk_scene_adapter` | ClientChunkSpaceAdapter(空间适配) |
| `duplo` | FootPrintRenderer(足迹渲染) |
| `input` | InputDevices(输入设备) |
| `math` | 向量/矩阵/平面/包围盒 |
| `particle` | 粒子系统(WPEntity 依赖) |
| `physics2` | MaterialKinds(材质种类) |
| `pyscript` | Script/Python 集成(WPEntity 加载) |
| `resmgr` | BWResource/DataSection/XMLSection/ZipSection |
| `romp` | Font/FontManager/LensEffectManager/TextureFeeds/Water/EnviroMinder/TimeOfDay |
| `terrain` | Terrain::Manager/terrain2(地形高度图) |
| `waypoint_generator` | WaypointGenerator/WaypointFlood/WaypointView/ChunkView |
| `opengl32` | OpenGL(2D 视图绘制) |
| `speedtree`(可选) | SpeedTreeRenderer(BW_SPEEDTREE_SUPPORT 时) |

### 16.2 头文件依赖(关键 include)

`navgen.cpp` 顶部(L1-96)引入的头文件揭示了 navgen 的子系统装配:

- **chunk 系统**:`chunk/chunk.hpp`, `chunk_manager.hpp`, `chunk_overlapper.hpp`, `chunk_space.hpp`, `chunk_terrain.hpp`, `geometry_mapping.hpp`
- **空间**:`space/client_space.hpp`, `space/space_manager.hpp`, `space/deprecated_space_helpers.hpp`
- **common**:`common/format.hpp`, `common/space_mgr.hpp`, `common/utilities.hpp`, `common/bwlockd_connection.hpp`
- **cstdmf**:`allocator.hpp`, `bgtask_manager.hpp`, `cstdmf_init.hpp`, `debug_exception_filter.hpp`, `log_meta_data.hpp`, `log_msg.hpp`, `main_loop_task.hpp`, `message_box.hpp`, `stack_tracker.hpp`, `timestamp.hpp`
- **Moo**:`init.hpp`, `render_context.hpp`, `mrt_support.hpp`, `texture_manager.hpp`, `renderer.hpp`, `draw_context.hpp`
- **资源**:`auto_config.hpp`, `bwresource.hpp`, `data_section_cache.hpp`, `data_section_census.hpp`, `string_provider.hpp`, `xml_section.hpp`
- **romp**:`font.hpp`, `font_manager.hpp`, `lens_effect_manager.hpp`, `texture_feeds.hpp`, `time_of_day.hpp`, `water.hpp`
- **terrain**:`manager.hpp`, `terrain2/terrain_block2.hpp`, `terrain2/terrain_height_map2.hpp`
- **Windows**:`<GL/gl.h>`, `<commctrl.h>`, `<commdlg.h>`, `<windows.h>`

### 16.3 依赖关系图

```
                          ┌──────────────────────────┐
                          │         navgen.exe        │
                          └────────────┬─────────────┘
                                       │
        ┌──────────────┬───────────────┼───────────────┬──────────────┐
        ▼              ▼               ▼               ▼              ▼
   ┌─────────┐   ┌───────────┐   ┌───────────┐   ┌───────────┐  ┌─────────┐
   │  chunk  │   │ waypoint_ │   │  cstdmf   │   │  resmgr   │  │  math   │
   │         │   │ generator │   │           │   │           │  │         │
   └────┬────┘   └─────┬─────┘   └─────┬─────┘   └─────┬─────┘  └─────────┘
        │              │               │               │
        │         ┌────┴────┐          │               │
        │         ▼         ▼          │               │
        │   waypoint_   waypoint_      │               │
        │   flood       generator      │               │
        │                              │               │
        ▼                              ▼               ▼
   ┌───────────┐                 ┌───────────┐   ┌───────────┐
   │  common/  │                 │ BgTaskMgr │   │XMLSection │
   │ chunk_    │                 │ FileIO    │   │ ZipSection│
   │ flooder   │                 │           │   │           │
   │ girth     │                 └───────────┘   └───────────┘
   │ physics_  │
   │ handler   │        ┌──────────────────────────────┐
   │ waypoint_ │        │   Moo (渲染) + romp + terrain │
   │ annotator │        │   (3D 场景与地形加载)         │
   └───────────┘        └──────────────────────────────┘
```

---

## 十七、关键代码片段

### 17.1 bwWinMain 入口与异常过滤

```cpp
// navgen.cpp L5230-5232
int WINAPI wWinMain(HINSTANCE hInstance, HINSTANCE hPrev, LPWSTR commandLine, int cmdShow)
{
    return CallWithExceptionFilter( bwWinMain, hInstance, hPrev, commandLine, cmdShow );
}
```

```cpp
// navgen.cpp L4720-4724
int bwWinMain(HINSTANCE hInstance, HINSTANCE, LPWSTR commandLine, int)
{
    BW_GUARD;
    BW_SYSTEMSTAGE_MAIN();
    CStdMf cstdMf;
    ...
```

### 17.2 命令行模式分流

```cpp
// navgen.cpp L4926-5014 (节选)
bool workInCommandLine = false;
if (strstr( cmdLine.c_str(), "/s" ))
{
    workInCommandLine = true;
    BW::string space;
    if (!getParam( &cmdLine, "/s", &space )) { ... return 3; }
    if( !BWResource::openSection( space + "/space.settings" ) ) { ... return 3; }

    if (const char* p = strstr( cmdLine.c_str(), "/g" ))
    {
        BW::string file;
        if (!getParam( &cmdLine, "/g", &file )) { ... return 3; }
        std::ifstream ifs( file.c_str() );
        BW::string chunkName;
        while( std::getline( ifs, chunkName ) )
        {
            # 去除首尾空白
            while( !chunkName.empty() && isspace( *chunkName.begin() ) ) chunkName.erase( chunkName.begin() );
            while( !chunkName.empty() && isspace( *chunkName.rbegin() ) ) chunkName.resize( chunkName.size() - 1 );
            if( !chunkName.empty() )
                g_chunkSet.insert( chunkName );
        }
    }
    if (!setupChunking( space )) return 3;
}
```

### 17.3 ChunkWaypointGenerator 三阶段调用

```cpp
// chunk_waypoint_generator.cpp L139-195 (核心三阶段)
void ChunkWaypointGenerator::flood( bool (*progressCallback)( int npoints ),
    Girth gSpec, bool writeTGAs )
{
    flooder_.flood( gSpec, entityPts_, progressCallback, 0, writeTGAs );
}

void ChunkWaypointGenerator::generate( bool annotate, Girth gSpec )
{
    int w = flooder_.width(), h = flooder_.height();
    gener_.init( w, h, flooder_.minBounds(), flooder_.resolution() );

    for ( int g = 0; g < 16; ++g )
    {
        memcpy( gener_.adjGrids()[g], flooder_.adjGrids()[g], w*h*4 );
        memcpy( gener_.hgtGrids()[g], flooder_.hgtGrids()[g], w*h*4 );
    }

    gener_.generate();

    PhysicsHandler phand( pChunk_->space(), gSpec );
    gener_.determineEdgesAdjacentToOtherChunks( pChunk_, &phand );
    gener_.streamline();

    if( annotate )
    {
        WaypointAnnotator wanno( &gener_, pChunk_->space() );
        wanno.annotate();
    }

    gener_.extendThroughUnboundPortals( pChunk_ );
    gener_.calculateSetMembership( entityPts_, pChunk_->identifier() );
}

void ChunkWaypointGenerator::output( float girth, bool firstGirth )
{
    gener_.saveOut( pChunk_, girth, /*removeAllOld:*/firstGirth );
}
```

### 17.4 hash 集群分片函数

```cpp
// navgen.cpp L1913-1941
unsigned int hash( const char* str )
{
    static unsigned char hash[ 256 ];
    static bool inithash = true;
    if( inithash )
    {
        inithash = false;
        for( int i = 0; i < 256; ++i ) hash[ i ] = i;
        int k = 7;
        for( int j = 0; j < 4; ++j )
            for( int i = 0; i < 256; ++i )
            {
                unsigned char s = hash[ i ];
                k = ( k + s ) % 256;
                hash[ i ] = hash[ k ];
                hash[ k ] = s;
            }
    }
    unsigned char result = ( 123 + strlen( str ) ) % 256;
    for( unsigned int i = 0; i < strlen( str ); ++i )
    {
        result = ( result + str[ i ] ) % 256;
        result = hash[ result ];
    }
    return result;
}
```

### 17.5 doGenerateAll 集群分片与增量检查

```cpp
// navgen.cpp L2354-2390
if( hash( g_currentChunk->identifier().c_str() ) % g_totalComputers != g_myIndex )
{
    INFO_MSG( "Skip chunk %s because hash failed\n", g_currentChunk->identifier().c_str() );
    g_statusWindow.skip();
    drawGenerateAllProgress();
    continue;
}

if (g_currentChunk->isOutsideChunk() && !isChunkLocked( g_currentChunk ))
{
    INFO_MSG( "Skip chunk %s because it is not locked\n", g_currentChunk->identifier().c_str() );
    g_statusWindow.skip();
    continue;
}

if (g_currentChunk->isOutsideChunk())
{
    bool modified = true;
    DataSectionPtr chunkBinSection = BWResource::openSection( g_currentChunk->binFileName() );
    if (chunkBinSection)
        modified = !chunkBinSection->openSection( "auxData/worldNavmesh" );
    if (!modified)
    {
        g_calcChunksDone.insert( g_currentChunk );
        g_calcChunksNotDirty.insert( g_currentChunk );
        g_statusWindow.skip();
        continue;
    }
}
```

### 17.6 canProcess 邻居就绪检查

```cpp
// chunk_waypoint_generator.cpp L276-353 (节选)
/*static*/ bool ChunkWaypointGenerator::canProcess(Chunk *chunk)
{
    ScopedSyncMode scopedSyncMode;
    updateMoo( 0.05f, false );
    if (IsWindowVisible( g_hMooWindow )) drawMoo();

    if (!chunk->isOutsideChunk())
    {
        # 室内 chunk:检查其所属室外 chunk 是否绑定
        BW::string outsideChunkName = chunk->mapping()->outsideChunkIdentifier( ... );
        if (outsideChunkName.empty()) return chunk->isBound();
        Chunk* outside = ChunkManager::instance().findChunkByName( outsideChunkName, chunk->mapping() );
        return canProcess( outside );     # 递归检查室外 chunk
    }

    # 室外 chunk:检查 3x3 邻域及其 overlapper
    Vector3 centre = chunk->boundingBox().centre();
    float gridSize = chunk->space()->gridSize();
    for (int x = -1; x < 2; ++x)
    {
        for (int z = -1; z < 2; ++z)
        {
            Vector3 pos( centre.x + x * gridSize, centre.y, centre.z + z * gridSize );
            BW::string chunkName = chunk->mapping()->outsideChunkIdentifier( pos );
            if (!chunkName.empty())
            {
                Chunk* outside = ChunkManager::instance().findChunkByName( chunkName, chunk->mapping() );
                if (!outside->isBound())
                {
                    if (!outside->loading())
                    {
                        ChunkManager::instance().loadChunkExplicitly( chunkName, chunk->mapping() );
                        ChunkManager::instance().checkLoadingChunks();
                    }
                    return false;          # 邻居未就绪
                }
                # 检查 overlapper(跨 chunk 边界的大模型)
                ChunkOverlappers& co = ChunkOverlappers::instance( *outside );
                ChunkOverlappers::Overlappers coo = co.overlappers();
                for (...) { if (!(*it)->pOverlapper()->isBound()) return false; }
            }
        }
    }
    return true;
}
```

`canProcess` 是 navgen 确保洪水填充碰撞场景完整的关键:它检查当前 chunk 的 3×3 邻域及所有 overlapper(跨 chunk 边界的模型)是否都已绑定,否则触发加载并返回 `false` 让调用者重试。

### 17.7 NavGenUDO toss 维护全局种子表

```cpp
// navgen_udo.cpp L60-94
void NavGenUDO::toss( Chunk * pChunk )
{
    if (pChunk == pChunk_) return;
    if (pChunk_ != NULL)
        NavGenUDOCache::instance( *pChunk_ ).del( this );
    this->ChunkItem::toss( pChunk );
    if (pChunk_ != NULL)
    {
        NavGenUDOCache::instance( *pChunk_ ).add( this );
        GirthSeed girthSeed;
        girthSeed.position = pChunk->transform().applyPoint( this->position() );
        girthSeed.girth = pProps_->readFloat( "girth", -1.f );
        girthSeed.generateRange = pProps_->readFloat( "generateRange", 0.f );
        if (girthSeed.girth > 0.f )
            s_girthSeeds[this] = girthSeed;
    }
    else
    {
        GirthSeeds::iterator it = s_girthSeeds.find( this );
        if (it != s_girthSeeds.end()) s_girthSeeds.erase( it );
    }
}
```

### 17.8 GenerateAllEnvironmentSetter RAII

```cpp
// navgen.cpp L2277-2297
class GenerateAllEnvironmentSetter
{
    bool showingMoo_;
public:
    GenerateAllEnvironmentSetter()
    {
        ChunkManager::instance().autoSetPathConstraints( 0 );        # 加载距离 0
        ChunkManager::instance().switchToSyncTerrainLoad( true );    # 同步地形
    }
    ~GenerateAllEnvironmentSetter()
    {
        ChunkManager::instance().autoSetPathConstraints( g_chunkLoadDistance );
        ChunkManager::instance().switchToSyncTerrainLoad( false );
    }
}
generateAllEnvironmentSetter;
```

### 17.9 setupChunking 中 Girth 加载与校验

```cpp
// navgen.cpp L3718-3738
Girths girths;
for (uint i=0; i < girths.size(); ++i)
{
    const Girth& girth = girths[ i ];
    g_girthSpecs.insert( std::make_pair( girth.girth(), girth ) );
    if (girth.always())
        g_girthsAlwaysGenerate.push_back( girth.girth() );
    g_girthsViewable.push_back( girth.girth() );
}
if (g_girthSpecs.find( 0.5f ) == g_girthSpecs.end())
    CRITICAL_MSG( "Girth = 0.5 specification not found.\n" );
```

---

## 十八、设计亮点与注意事项

### 18.1 设计亮点

1. **三层 facade 架构**:`ChunkWaypointGenerator` → `ChunkFlooder` + `WaypointGenerator` → `WaypointFlood`,职责清晰,每层可独立测试。

2. **紧凑的邻接编码**:`AdjGridElt` 用 4 位 × 8 方向 = 32 位(4 字节)存储一个网格点的全部邻接信息,16 层高度仅 64 字节/点,适合大空间采样。

3. **BSP + 凸多边形约束**:寻路要求 navPoly 凸,`isConvexJoint` 在合并阶段保证凸性,避免运行时凸分解开销。

4. **集群分片**:RC4 风格哈希把 chunk 均匀分散到多台机器,支持大规模空间并行生成,无需中心调度。

5. **增量生成**:通过 `auxData/worldNavmesh` 存在性检查与 `navmeshDirty` 标志,跳过未修改 chunk,大幅缩短 CI 流水线时间。

6. **RAII 守卫**:多处 RAII(`NavGenGenerating` / `GenerateAllEnvironmentSetter` / `NavgenScopedMenuDisabler` / `ScopedSyncMode` / `ScopedSetReady` / `BWResource bwResourceHolder` / `CStdMf`)保证异常安全与状态恢复。

7. **双模式**:同一可执行文件支持交互调试(查看 BSP、邻接、多边形)与命令行 CI 批量生成,降低维护成本。

8. **bwlockd 集成**:`isChunkLocked` 通过 bwlockd 服务协调多人编辑,避免覆盖他人修改。

9. **种子点驱动**:`WayPointSeed` UDO + `WPEntity` 让美术精确控制哪些区域需要特殊 girth(如大型 NPC 需要更宽通道),而非一刀切。

10. **崩溃转储**:`CallWithExceptionFilter` + `ENABLE_STACK_TRACKER` 在崩溃时生成带堆栈的转储,便于流水线诊断。

### 18.2 注意事项与陷阱

1. **`girth=0.5` 硬性要求**:若 `girths.xml` 缺少 0.5 规格,启动直接 `CRITICAL_MSG` 退出(L3737)。

2. **`reannotation=false` 移除菜单**:`ID_CHUNK_REANNOTATE` 在 `reannotation=false` 时被 `DeleteMenu` 移除(L4913),菜单处理中仍做 `g_reannotation` 二次检查(L3294)。

3. **`processCommandLine` 是空函数**:L3509-3512 的 `processCommandLine` 函数体为空,保留是为兼容 BWResource 期望的接口约定。

4. **`BigWorldClientScript::callNextFrame` 桩**:L5208-5212 提供空实现,因为 duplo 在 `EDITOR_ENABLED` 未定义时依赖此符号,navgen 不定义 EDITOR_ENABLED,必须手动补桩。

5. **`hash` 函数命名遮蔽**:局部 `static unsigned char hash[256]` 与函数同名,虽合法但易混淆,实际是查表用的置换数组。

6. **`canProcess` 递归**:室内 chunk 会递归检查其所属室外 chunk 的 3×3 邻域,深层室内嵌套可能栈消耗较大。

7. **`floodResultPath` 缓存**:重注解模式可复用洪水填充结果跳过物理采样,但缓存失效策略需用户自行管理(改动地形后需删除缓存)。

8. **`/overwrite` 会先 `doClearAll`**:`doGenerateAll(true)` 先清除所有导航数据再生成,中途取消会导致部分 chunk 无导航数据,需谨慎。

9. **加载距离 0 的副作用**:`GenerateAllEnvironmentSetter` 把加载距离设为 0,期间交互视图无法看到周围 chunk,仅在生成结束时恢复。

10. **`Moo::rc().preloadDeviceResources( 1000 )`**:在 `doGenerateAll` 循环中每 chunk 调用,预加载 GPU 资源防止显存膨胀崩溃。

### 18.3 与编辑器的契约

navgen 与 World Editor 通过 `.cdata` 中的几个 section 协作:

| Section | 写入方 | 读取方 | 含义 |
|---------|--------|--------|------|
| `navmeshDirty` | 编辑器(改地形后写 true)/ navgen(生成后写 false) | navgen / 编辑器 | 是否需重新生成 |
| `auxData/worldNavmesh` | navgen | navgen | 增量生成检查 |
| `navPolySet` | navgen | 客户端/服务端寻路 | 多边形数据 |
| `waypointSet` | navgen(旧) | 旧版寻路 | 旧格式航点 |

注释 L90 指出 `navmeshDirty` 读取逻辑"designed to match EditorChunkNavmeshCacheBase::load",`outputDirtyFlag` L205 注释"designed to match EditorChunkNavmeshCacheBase::saveCData",双方必须保持二进制格式一致。

---

## 附录 A:全局变量速查

| 变量 | 类型 | 说明 | 定义位置 |
|------|------|------|---------|
| `g_hWindow` | HWND | 主窗口 | navgen.cpp |
| `g_hMooWindow` | HWND | Moo 3D 渲染窗口 | navgen.cpp |
| `g_hInfoDialog` | HWND | 航点信息对话框 | navgen.cpp |
| `g_hMenu` | HMENU | 主菜单 | navgen.cpp |
| `g_statusWindow` | NavgenStatusWindow | 状态栏 | navgen.cpp |
| `g_camMatrix` | Matrix | 相机矩阵 | navgen.cpp L404 |
| `g_mapping` | GeometryMapping* | 当前空间映射 | navgen.cpp L392 |
| `g_navgenSettings` | DataResource* | 设置对象 | navgen.cpp |
| `g_spaceManager` | SpaceNameManager* | 空间名管理 | navgen.cpp |
| `g_girthSpecs` | map<float,Girth> | girth 规格 | navgen.cpp L380 |
| `g_girthsAlwaysGenerate` | vector<float> | 必生成 girth | navgen.cpp L383 |
| `g_girthsViewable` | vector<float> | 可视图 girth | navgen.cpp L384 |
| `g_conn` | BWLockDConnection | bwlockd 连接 | navgen.cpp L386 |
| `g_chunkSet` | set<string> | /g 列表 | navgen.cpp L377 |
| `g_totalComputers` | int | 集群总机器数 | navgen.cpp |
| `g_myIndex` | int | 本机索引 | navgen.cpp |
| `g_processor` | int | 处理器(保留) | navgen.cpp L397 |
| `g_writeTGAs` | bool | 输出 TGA | navgen.cpp L399 |
| `g_reannotation` | bool | 重注解开关 | navgen.cpp L400 |
| `g_annotate` | bool | 注解开关 | navgen.cpp |
| `g_chunkLoadDistance` | float | 加载距离(500.0) | navgen.cpp L402 |
| `g_generating` | bool | 生成中标志 | navgen.cpp L390 |
| `g_pleaseShutdown` | bool | 请求退出 | navgen.cpp |
| `g_currentChunk` | Chunk* | 当前处理 chunk | navgen.cpp |
| `g_floodResultPath` | string | 洪水缓存路径 | navgen.cpp |
| `g_pView` | WaypointView* | 当前视图 | navgen.cpp |
| `g_dx[8]` / `g_dz[8]` | int[8] | 8 方向偏移 | navgen.cpp L361-362 |
| `g_oldCam` | Matrix | 相机备份 | chunk_waypoint_generator.cpp L24 |

---

## 附录 B:菜单资源 ID 速查

| 资源 ID | 值 | 说明 |
|---------|----|----|
| `IDR_MENU1` | 101 | 主菜单 |
| `IDR_ACCELERATORS` | 123 | 加速键 |
| `IDD_STATISTICS` | 103 | 统计对话框 |
| `IDD_WAYPOINT_INFO` | 104 | 航点信息对话框 |
| `IDD_MODELESS_INFO` | 112 | 无模式信息对话框 |
| `IDD_MESSAGEDIALOG` | 114 | 错误日志对话框 |
| `IDD_CLUSTERGENDIALOG` | 117 | 集群生成对话框 |
| `IDD_HELP` | 122 | 帮助对话框 |
| `ID_FILE_OPENSPACE` | 116 | 打开空间 |
| `ID_FILE_GENERATE_ALL` | 105 | 生成全部 |
| `ID_FILE_GENERATE_ALL_OVERWRITE` | 112 | 覆盖生成全部 |
| `ID_FILE_CLUSTERGENERATE` | 118 | 集群生成 |
| `ID_FILE_CLEAR_ALL` | 40013 | 清除全部 |
| `ID_FILE_OPEN1` | 40006 | 打开 chunk |
| `ID_FILE_EXIT` | 40005 | 退出 |
| `ID_CHUNK_GENERATE` | 107 | 生成 chunk |
| `ID_CHUNK_REANNOTATE` | 109 | 重注解 |
| `ID_CHUNK_DISPLAY` | 110 | 显示 chunk |
| `ID_VIEW_BSPNODES` | 111 | BSP 节点视图 |
| `ID_VIEW_ADJACENCIES` | 40001 | 邻接视图 |
| `ID_VIEW_POLYGONAREA` | 40003 | 多边形区域 |
| `ID_VIEW_POLYGONBORDERS` | 40002 | 多边形边界 |
| `ID_VIEW_STATISTICS` | 40007 | 统计 |
| `ID_VIEW_WAYPOINTINFO` | 40011 | 航点信息 |
| `ID_VIEW_RENDEREDSCENE` | 40012 | 渲染场景 |
| `ID_VIEW_ERRORLOG` | 115 | 错误日志 |
| `ID_VIEW_SET` | 40016 | 集合设置 |
| `ID_VIEW_SET_ALL` | 40017 | 显示所有集合 |
| `ID_VIEW_SET_NONE` | 40018 | 隐藏所有集合 |
| `ID_ZOOM_IN` | 40008 | 放大 |
| `ID_ZOOM_OUT` | 40009 | 缩小 |
| `ID_HELP_HELP` | 40015 | 帮助 |
| `IDC_TOTALCOMPUTER` | 1012 | 集群总机器数控件 |
| `IDC_MYINDEX` | 1013 | 本机索引控件 |
| `IDC_BSP_NODES` | 1004 | BSP 节点数(统计) |
| `IDC_WAYPOINT_POLYGONS` | 1006 | 多边形数 |
| `IDC_WAYPOINT_VERTICES` | 1007 | 顶点数 |
| `IDC_WAYPOINT_ADJACENCIES` | 1008 | 邻接数 |
| `IDC_BINARY_FILE_SIZE` | 1005 | 二进制大小 |
| `IDC_MESSAGELIST` | 1010 | 消息列表 |

---

> 本文档基于 BigWorld Engine 14.4.1 源码分析整理,主要参考 `programming/bigworld/tools/navgen/` 下的源文件及 `programming/bigworld/lib/waypoint_generator/`、`programming/bigworld/tools/common/` 中的依赖。行号引用基于源文件实际位置,便于对照查阅。
