# BigWorld 工具 worldeditor 实现深度分析

> 本文档详细分析 BigWorld Engine 14.4.1 中 WorldEditor(世界编辑器)的完整实现,涵盖架构定位、目录组织、MFC 启动流程、WorldManager 上帝对象、GUI 绑定机制、bwlockd 多人协作锁、AssetClient 资产管线接入、Python 脚本暴露、Chunk 编辑缓存、链接器管理器等核心机制。WorldEditor 是 BigWorld 工具链中规模最大、复杂度最高的工具,承担场景空间的创建、地形编辑、物体放置、链接关系维护与提交等全部可视化编辑职责。

---

## 目录

- [一、整体架构概览](#一整体架构概览)
- [二、源码目录结构](#二源码目录结构)
- [三、入口点与启动流程](#三入口点与启动流程)
- [四、核心类与继承关系](#四核心类与继承关系)
- [五、关键算法与数据结构](#五关键算法与数据结构)
- [六、配置项与命令行参数](#六配置项与命令行参数)
- [七、与其他模块的依赖关系](#七与其他模块的依赖关系)
- [八、关键代码片段](#八关键代码片段)
- [九、设计亮点与注意事项](#九设计亮点与注意事项)

---

## 一、整体架构概览

### 1.1 WorldEditor 在工具链中的定位

WorldEditor 是 BigWorld 工具链中的**核心可视化编辑器**,承担以下职责:

1. 创建、编辑、扩展场景空间(Space)
2. 编辑地形高度图、纹理层、洞口、过滤器
3. 放置与管理场景物体(模型、灯光、粒子、水位、围栏、传送点等)
4. 维护物体之间的链接关系(Entity Link、Station Link、UserDataObject Link、VLO)
5. 后处理链(PostProcessing)可视化编排
6. 通过 bwlockd 实现多人协作锁定与提交
7. 接入 AssetClient 资产管线进行资源编译
8. 通过 Python 脚本暴露全部编辑能力,支持自动化与 UI 适配

### 1.2 整体架构拓扑

```
┌────────────────────────────────────────────────────────────────┐
│                      WorldEditor 进程 (MFC SDI)                │
│                                                                │
│  ┌──────────────┐   ┌──────────────────┐   ┌────────────────┐  │
│  │ WorldEditorApp│   │   MainFrame      │   │ PanelManager   │  │
│  │ (CWinApp +   │──▶│ (BaseMainFrame + │──▶│ (GUI 页面/工具栏)│  │
│  │  IEditorApp) │   │   IMainFrame)    │   │                │  │
│  └──────┬───────┘   └────────┬─────────┘   └────────────────┘  │
│         │                    │                                  │
│         │ s_mfApp->init      │ WorldEditorView (3D 视口)         │
│         ▼                    │                                  │
│  ┌──────────────────────────▼────────────────────────────────┐  │
│  │              Initialisation::initApp                       │  │
│  │  AssetClient → Input → Graphics → Scripts → Consoles →     │  │
│  │  BgTaskManager → FileIOTaskManager → Sound →               │  │
│  │  WorldManager::init                                        │  │
│  └──────────────────────────┬────────────────────────────────┘  │
│                             │                                   │
│                             ▼                                   │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │              WorldManager (上帝对象, 9 重继承)            │   │
│  │  Singleton + SnapProvider + CoordModeProvider +           │   │
│  │  ReferenceCount + SlowTaskHandler + ActionMaker +         │   │
│  │  OptionMap + UpdaterMaker + ChunkProcessorManager +       │   │
│  │  SpaceEditor                                               │   │
│  │                                                            │   │
│  │  ┌─────────────┐  ┌──────────────┐  ┌──────────────────┐  │   │
│  │  │ BWLockDConn │  │ RompHarness  │  │ ChunkProcessor   │  │   │
│  │  │ (多人协作)  │  │ (环境/天气)  │  │ Manager (后台线程)│  │   │
│  │  └──────┬──────┘  └──────────────┘  └──────────────────┘  │   │
│  │         │                                                  │   │
│  │  ┌──────▼──────┐  ┌──────────────┐  ┌──────────────────┐  │   │
│  │  │ SceneBrowser│  │ EditorChunk- │  │ EditorChunkItem- │  │   │
│  │  │ (场景浏览)  │  │ Cache        │  │ LinkerManager    │  │   │
│  │  └─────────────┘  └──────────────┘  └──────────────────┘  │   │
│  └──────────────────────────┬───────────────────────────────┘   │
└─────────────────────────────┼───────────────────────────────────┘
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
      ┌──────────────┐ ┌─────────────┐ ┌──────────────┐
      │   bwlockd    │ │ AssetClient │ │  Python 脚本 │
      │ (锁定服务器) │ │ (资产管线)  │ │ (UIAdapter)  │
      └──────────────┘ └─────────────┘ └──────────────┘
```

### 1.3 关键设计原则

| 原则 | 说明 |
|------|------|
| **上帝对象模式** | `WorldManager` 单例聚合 9 重继承,集中管理几乎所有编辑器状态,代码量约 6714 行(world_manager.cpp) |
| **MFC SDI 框架** | 基于 `CWinApp` + `CSingleDocTemplate`,文档/视图/主框架三件套,深度集成 Win32 |
| **GUI 数据驱动** | 通过 `gui.xml` 描述菜单/工具栏,`GUI::ActionMaker`/`GUI::OptionMap`/`GUI::UpdaterMaker` 将 XML 项绑定到 C++ 方法 |
| **Python 全暴露** | `world_editor_script.cpp` 将 WorldManager 能力暴露为 `BigWorld` 模块静态方法,UI 适配层全部用 Python 实现 |
| **多线程分时** | `ChunkProcessorManager` + `BgTaskManager` + `FileIOTaskManager` 三套后台线程,主线程分时 yield |
| **协作锁前置** | 编辑前通过 bwlockd 锁定 chunk 网格,`GS_WRITABLE_BY_ME` 状态才允许写入 |
| **RAII 资源管理** | `WaitCursor`、`FolderGuard`、`ScopedDeferSelectionReplacement` 等 RAII 守卫广泛使用 |

### 1.4 规模与组成

WorldEditor 源码位于 `programming/bigworld/tools/worldeditor/`,由 `CMakeLists.txt` 组织,**单一可执行文件** `worldeditor`(通过 `BW_ADD_TOOL_EXE`),源文件分组如下:

| 分组 | 说明 |
|------|------|
| Framework | MFC 应用框架(App/Doc/View/MainFrame/Initialisation) |
| World | WorldManager 及 Chunk 缓存/链接/管理 |
| World/Items | 各类 EditorChunkItem 实现(模型/灯光/粒子/水位等) |
| Editor | 物体放置/链接/属性/gizmo 编辑器 |
| Terrain | 地形编辑 functor/tool_view/overlay |
| GUI/Dialogs | 各类模态对话框 |
| GUI/Pages | 属性页与 PanelManager |
| GUI/Controls | 自定义 MFC 控件 |
| GUI/SceneBrowser | 场景浏览器(分组/列/搜索/选择) |
| GUI/PostProcessing | 后处理链可视化节点编辑器 |
| Project | ProjectModule、SpaceMap、LockMap、ChunkPhotographer |
| Scripting | Python 暴露与 WEPythonAdapter |
| UndoRedo | 各类 Operation 实现 |
| Import | 地形高度/纹理导入编解码 |
| Collisions | 编辑器专用碰撞回调 |
| Height | HeightMap/HeightModule |
| Graph | 通用图节点/边视图 |
| Misc | 相机/CVS/选项/选择过滤器等 |

---

## 二、源码目录结构

### 2.1 顶层目录

```
tools/worldeditor/
├── CMakeLists.txt          # 构建定义, BW_ADD_TOOL_EXE(worldeditor)
├── config.hpp              # 模块配置宏
├── forward.hpp             # 前置声明
├── pch.hpp / pch.cpp       # 预编译头
├── resource.h              # 资源 ID
├── framework/              # MFC 应用框架
├── world/                  # WorldManager 与 Chunk 系统
├── editor/                 # 编辑器交互(放置/链接/gizmo)
├── terrain/                # 地形编辑
├── gui/                    # 图形界面
├── project/                # 项目/空间管理模块
├── scripting/              # Python 暴露
├── undo_redo/              # 撤销/重做 Operation
├── import/                 # 数据导入
├── collisions/             # 碰撞回调
├── height/                 # 高度图
├── graph/                  # 图视图
├── misc/                   # 杂项工具
└── res/                    # 资源文件(图标/位图/光标)
```

### 2.2 framework/ 目录详解

| 文件 | 作用 |
|------|------|
| `world_editor_app.hpp/.cpp` | `WorldEditorApp` 主应用类,继承 `CWinApp` 与 `IEditorApp`,MFC 入口 |
| `initialisation.hpp/.cpp/.ipp` | `Initialisation` 静态类,封装 `initApp`/`finiApp` 全局资源初始化 |
| `mainframe.hpp/.cpp` | `MainFrame` 主框架窗口,继承 `BaseMainFrame` 与 `IMainFrame` |
| `world_editor_doc.hpp/.cpp` | `WorldEditorDoc` MFC 文档类 |
| `world_editor_view.hpp/.cpp` | `WorldEditorView` 3D 视口视图 |

### 2.3 world/ 目录详解

| 文件 | 作用 |
|------|------|
| `world_manager.hpp/.cpp` | **核心上帝对象** `WorldManager`,6714 行实现 |
| `editor_chunk_cache.hpp/.cpp` | `EditorChunkCache` 编辑器 chunk 扩展缓存 |
| `editor_chunk_item_linker.hpp/.cpp` | 可链接物体接口 |
| `editor_chunk_item_linker_manager.hpp/.cpp` | 链接关系管理器(81864 字符) |
| `editor_chunk_link_manager.hpp/.cpp` | chunk 链接管理 |
| `editor_chunk_navmesh_cache.hpp/.cpp` | 导航网格缓存 |
| `editor_chunk_overlapper.hpp/.cpp` | chunk 重叠器 |
| `editor_chunk_thumbnail_cache.hpp/.cpp` | chunk 缩略图缓存 |
| `editor_chunk_lock_visualizer.hpp/.cpp` | 锁定可视化 |
| `vlo_manager.hpp/.cpp` | VLO(Very Large Object)管理 |
| `item_info_db.hpp/.cpp` | 物体信息数据库 |
| `world_editor_romp_harness.hpp/.cpp` | 编辑器专用 RompHarness |
| `we_chunk_saver.hpp/.cpp` | chunk 保存器 |

### 2.4 world/items/ 目录(场景物体类型)

| 物体类型 | 文件 |
|---------|------|
| 模型 | `editor_chunk_model.hpp/.cpp` |
| 实体 | `editor_chunk_entity.hpp/.cpp` |
| 灯光 | `editor_chunk_light.hpp/.cpp` |
| 粒子系统 | `editor_chunk_particle_system.hpp/.cpp` |
| 水位 | `editor_chunk_water.hpp/.cpp` |
| 传送点 | `editor_chunk_station.hpp/.cpp` |
| 树木 | `editor_chunk_tree.hpp/.cpp` |
| 标记 | `editor_chunk_marker.hpp/.cpp` |
| 链接 | `editor_chunk_link.hpp/.cpp`、`editor_chunk_point_link.hpp/.cpp` |
| 门户 | `editor_chunk_portal.hpp/.cpp` |
| VLO | `editor_chunk_vlo.hpp/.cpp`、`editor_chunk_model_vlo.hpp/.cpp` |
| 用户数据对象 | `editor_chunk_user_data_object.hpp/.cpp` |
| 延迟贴花 | `editor_chunk_deferred_decal.hpp/.cpp` |
| Flare | `editor_chunk_flare.hpp/.cpp` |
| 绑定 | `editor_chunk_binding.hpp/.cpp` |
| 元数据 | `editor_chunk_meta_data.hpp/.cpp` |

---

## 三、入口点与启动流程

### 3.1 MFC 入口点

WorldEditor 是标准 MFC SDI 应用,入口由 `CWinApp` 机制驱动。全局 `theApp` 对象在 `world_editor_app.cpp:59` 声明:

```cpp
// world_editor_app.cpp:59
WorldEditorApp theApp; // The one and only WorldEditorApp object
```

MFC 框架在 `WinMain` 中依次调用 `InitInstance` → `Run` → `ExitInstance`。WorldEditor 通过 `CallWithExceptionFilter` 包装这三个方法,以接入自定义异常过滤:

```cpp
// world_editor_app.cpp:347-369
BOOL WorldEditorApp::InitInstance()
{
    BW::Allocator::setSystemStage( BW::Allocator::SS_MAIN );
    BOOL result = CallWithExceptionFilter( this, &WorldEditorApp::InternalInitInstance );
    if (!result)
    {
        if (pWorldManager_.get() != NULL &&
            pWorldManager_->wasExitRequested())
        {
            return false;   // 退出请求,静默退出
        }
        MessageBox( NULL,
            L"WorldEditor failed to initailise itself correctly, ...",
            L"WorldEditor", MB_OK );
    }
    return result;
}
```

### 3.2 InternalInitInstance 启动序列

`InternalInitInstance`(`world_editor_app.cpp:383`)是真正的启动逻辑,流程如下:

```
InternalInitInstance
  │
  ├── 1. Name::init()                          # 命名系统
  ├── 2. waitForRestarting()                   # 等待重启完成
  ├── 3. InitCommonControls / AfxInitRichEdit2 # MFC 通用控件
  ├── 4. CWinApp::InitInstance / AfxOleInit    # MFC + OLE
  ├── 5. SetRegistryKey("BigWorld-WorldEditor")# 注册表键
  ├── 6. LoadStdProfileSettings(4)             # INI + MRU
  ├── 7. CSingleDocTemplate(Doc/MainFrame/View)# 文档模板
  ├── 8. new BWResource()                      # 资源系统
  ├── 9. parseCommandLineMF()                  # 命令行解析
  ├── 10. StringProvider::load(语言文件)       # 本地化
  ├── 11. GUI::Manager::init()                 # GUI 管理器
  ├── 12. 加载 gui.xml → GUI::Item             # GUI 数据驱动
  ├── 13. ProcessShellCommand(cmdInfo)         # 创建主窗口(关键!)
  ├── 14. m_pMainWnd->ShowWindow(SW_SHOWMAXIMIZED)
  ├── 15. new WEApp (App 派生)                 # 应用回调
  ├── 16. new WorldManager                     # 上帝对象构造
  ├── 17. s_mfApp->init(..., Initialisation::initApp)  # ★核心初始化
  ├── 18. TextureStreamingManager 配置
  ├── 19. CooperativeMoo::init()               # 协作 MOO
  ├── 20. new WEPythonAdapter()                # Python 适配器
  ├── 21. new TextureMaskCache()               # 纹理遮罩缓存
  ├── 22. new GUI::MenuHelper(mainFrame)       # 菜单助手
  ├── 23. GUI::Manager::add(new GUI::Menu("MainMenu", menuHelper))
  ├── 24. mainFrame->createToolbars("AppToolbars")  # 工具栏
  ├── 25. PanelManager::init(mainFrame, view)  # 面板管理器
  ├── 26. CreateMailslot("WorldEditorUpdate")  # 更新邮件槽
  └── 27. Automation::parseCommandLine()       # 自动化命令
```

关键代码(`world_editor_app.cpp:539-547`):

```cpp
pWorldManager_ = WorldManagerPtr( new WorldManager );

if (!s_mfApp->init( hInst, m_pMainWnd->m_hWnd,
    mainFrame->GetActiveView()->m_hWnd,
    NULL,
    Initialisation::initApp ))   // 回调注入
{
    return FALSE;
}
```

注意 `App::init` 的最后一个参数是 `Initialisation::initApp` 函数指针,作为初始化回调注入,实现框架与初始化逻辑的解耦。

### 3.3 Initialisation::initApp 全局资源初始化

`initApp`(`initialisation.cpp:78-150`)负责初始化全局资源,顺序严格:

```cpp
// initialisation.cpp:78-150
bool Initialisation::initApp( HINSTANCE hInstance, HWND hWndApp, HWND hWndGraphics )
{
    inited_ = false;
    s_hInstance = hInstance;
    s_hWndApp = hWndApp;
    s_hWndGraphics = hWndGraphics;
    s_pAssetClient_.reset( new AssetClient() );
    s_pAssetClient_->waitForConnection();      // 阻塞等待资产管线

    initErrorHandling();
    initTiming();

    InputDevices * pInputDevices = new InputDevices();
    if (!InputDevices::instance().init( hInstance, hWndGraphics )) { ... }

    if (!Initialisation::initGraphics(hInstance, hWndGraphics)) { ... }

#ifndef BIGWORLD_CLIENT_ONLY
    initNetwork();                             // Winsock
#endif

    if (!Initialisation::initScripts()) { ... } // Python

    s_pLensEffectManager = LensEffectManagerPtr( new LensEffectManager() );

    if (!MaterialKinds::init()) { ... }

    if (!Initialisation::initConsoles()) { ... }

    BgTaskManager::init();
    BgTaskManager::instance().startThreads( "Init App Thread", 1 );

    FileIOTaskManager::init();
    FileIOTaskManager::instance().startThreads("File IO Thread", 1);

    Initialisation::initSound();

    if ( !WorldManager::instance().init( s_hInstance, s_hWndApp, s_hWndGraphics ) )
    { return false; }

    inited_ = true;
    return true;
}
```

初始化阶段汇总:

| 阶段 | 调用 | 说明 |
|------|------|------|
| 资产管线 | `AssetClient::waitForConnection` | 阻塞等待资产管线连接 |
| 错误处理 | `initErrorHandling` | 错误回调注册 |
| 时间 | `initTiming` | 时间戳初始化 |
| 输入 | `InputDevices::init` | 键鼠输入设备 |
| 图形 | `initGraphics` | D3D 设备初始化 |
| 网络 | `initNetwork` | Winsock(非 CLIENT_ONLY) |
| 脚本 | `initScripts` | Python 解释器 |
| 镜头特效 | `new LensEffectManager` | 必须在脚本后(PyTextureProvider) |
| 材质 | `MaterialKinds::init` | 物理材质种类 |
| 控制台 | `initConsoles` | 调试控制台 |
| 后台任务 | `BgTaskManager::startThreads` | 1 个通用后台线程 |
| 文件 IO | `FileIOTaskManager::startThreads` | 1 个文件 IO 线程 |
| 声音 | `initSound` | FMOD |
| 世界管理器 | `WorldManager::init` | ★编辑器核心初始化 |

### 3.4 WorldManager::init 编辑器核心初始化

`WorldManager::init`(`world_manager.cpp:2131-2351`)是编辑器自身的初始化,流程:

```
WorldManager::init
  │
  ├── MatrixProxy::setMatrixProxyCreator(WEMatrixProxyCreator)
  ├── Tool::setChunkFinder(WEChunkFinder)
  ├── new WEPreloader / new SceneBrowser
  ├── CVSWrapper::init()                       # CVS 集成
  ├── PyImport_AddModule("WorldEditor"/"BigWorld")
  ├── Personality::import(...)                 # 脚本人格
  ├── new DXEnum / new ChunkPhotographer / new AmortiseChunkItemDelete
  ├── EditorEntityType::startup / EditorUserDataObjectType::startup
  │
  ├── ★ bwlockd 初始化 (L2184-2197)
  │     if Options::getOptionBool("bwlockd/use", true):
  │         host = Options::getOptionString("bwlockd/host")
  │         username = Options::getOptionString("bwlockd/username")
  │         若空则 GetUserName 取系统用户名
  │         conn_.init(host, username, 0, 0)
  │
  ├── GUI::Manager::optionFunctor().setOption(this)  # GUI 选项绑定
  ├── updateLanguageList()
  ├── new Terrain::Manager / MaterialKinds::init
  ├── EditorChunkTerrainProjector::init
  ├── SpaceManager::init / ClientChunkSpaceAdapter::init / ChunkManager::init
  ├── new HeightMap
  ├── ResourceLoader::precompileEffects(SVCs)  # 预编译特效
  ├── new SpaceNameManager(MRUProvider)
  │
  ├── ★ changeSpace(默认空间) 或弹框选择空间 (L2252-2283)
  │     若无空间:MsgBox(打开/创建/退出)
  │
  ├── initRomp()                               # 环境管理器
  ├── new WorldEditorCamera()
  ├── 注册 Watcher(farPlane/drawPortals 等)
  ├── SnapProvider::instance(this) / CoordModeProvider::ins(this)
  ├── ResourceCache::init
  ├── ★ startNumThreads(NUM_BACKGROUND_CHUNK_PROCESSING_THREADS)  # L2333
  ├── EditorChunkNavmeshCacheBase::s_doWaitBeforeCalculate = true
  ├── new FencesToolView
  ├── new Moo::DrawContext(COLOR) / DrawContext(SHADOWS)
  ├── new SelectionOverrideBlock
  └── inited_ = true
```

### 3.5 关停流程

`WorldManager::fini`(`world_manager.cpp:737-835`)严格逆序释放:

1. `allowChunkProcessorThreadsToRun(true)` + `BgTaskManager::stopAll` + `ChunkProcessorManager::stopAll` + `FileIOTaskManager::stopAll`
2. `clearUnsavedData()`(必须在 Moo 存活时释放渲染资源)
3. 释放 DrawContext / SelectionOverrideBlock
4. `Script::clearTimers` + `GlobalEmbodiments::fini` + `stopBackgroundCalculation`
5. 清空选择与 `UndoRedo::instance().clear()`
6. `SpaceMap::deleteInstance` + `forcedLodMap_.clearLODData`
7. `romp_->enviroMinder().deactivate()`
8. `ToolList::clearAll()`(必须在 ChunkManager fini 前,因工具持有引用)
9. `ChunkManager::fini` + `SpaceManager::fini`
10. `EditorChunkTerrainProjector::fini` + `MaterialKinds::fini`
11. 释放 `romp_`(从 Python 模块删除属性)
12. 弹出残留 Tool 并 `popTool`
13. `EditorUserDataObjectType::shutdown` + `EditorEntityType::shutdown`
14. `ChunkItemTreeNode::nodeCache().fini`
15. 删除单例:`AmortiseChunkItemDelete` / `ChunkPhotographer` / `DXEnum`
16. `PropManager::fini` + `BWResource::purgeAll`

---

## 四、核心类与继承关系

### 4.1 WorldManager 上帝对象(9 重继承)

`WorldManager` 是 WorldEditor 的中枢,定义在 `world_manager.hpp:84-95`,采用**9 重继承**聚合多重职责:

```cpp
// world_manager.hpp:84-95
class WorldManager :
    public Singleton< WorldManager >,
    public SnapProvider,
    public CoordModeProvider,
    public ReferenceCount,
    SlowTaskHandler,
    GUI::ActionMaker<WorldManager>,
    GUI::OptionMap,
    GUI::UpdaterMaker<WorldManager>,
    public ChunkProcessorManager,
    public SpaceEditor
{
```

各基类职责:

| 基类 | 来源 | 职责 |
|------|------|------|
| `Singleton<WorldManager>` | cstdmf | 全局单例访问 `WorldManager::instance()` |
| `SnapProvider` | gizmo | 提供位置/角度吸附(snapPosition/snapAngles) |
| `CoordModeProvider` | gizmo | 提供坐标系模式(世界/本地/视图) |
| `ReferenceCount` | cstdmf | 引用计数,允许智能指针管理 |
| `SlowTaskHandler` | cstdmf | 慢任务处理(进度条/可取消任务) |
| `GUI::ActionMaker<WorldManager>` | guimanager | 将 GUI 动作字符串绑定到 `handleGUIAction` |
| `GUI::OptionMap` | guimanager | 提供 GUI 选项读写接口 |
| `GUI::UpdaterMaker<WorldManager>` | guimanager | 将 GUI 更新器绑定到 `handleGUIUpdate` |
| `ChunkProcessorManager` | chunk | chunk 后台处理器管理(多线程) |
| `SpaceEditor` | common | 空间编辑回调(changedChunk/isChunkWritable) |

### 4.2 GUI 动作绑定机制

构造函数中(`world_manager.cpp:668-672`)通过 `ActionMaker`/`UpdaterMaker` 将字符串动作名绑定到方法:

```cpp
// world_manager.cpp:668-672
, GUI::ActionMaker<WorldManager>(
    "changeSpace|newSpace|editSpace|recreateSpace|recentSpace|clearUndoRedoHistory|doExternalEditor|"
    "doReloadAllTextures|doReloadAllChunks|doExit|setLanguage|recalcCurrentChunk",
    &WorldManager::handleGUIAction )
, GUI::UpdaterMaker<WorldManager>( "updateRecreateSpace|updateUndo|updateRedo|updateExternalEditor|updateLanguage",
    &WorldManager::handleGUIUpdate )
```

`|` 分隔的动作名对应 `gui.xml` 中声明的项,GUI 框架派发时调用 `handleGUIAction`/`handleGUIUpdate`,内部按字符串分发到具体实现。这是典型的**命令模式 + 数据驱动 UI**。

### 4.3 WorldEditorApp 类层次

```cpp
// world_editor_app.hpp:21-24
class WorldEditorApp
    : public CWinApp
    , public IEditorApp
{
```

`WorldEditorApp` 同时继承 MFC `CWinApp` 与抽象接口 `IEditorApp`(来自 editor_shared),使编辑器共享层能通过抽象接口查询最小化状态:

```cpp
// world_editor_app.hpp:34-41
virtual BOOL InitInstance();
virtual int ExitInstance();
virtual int Run();
virtual BOOL OnIdle(LONG lCount);
virtual BOOL OnCmdMsg(UINT nID, int nCode, void* pExtra, AFX_CMDHANDLERINFO* pHandlerInfo);
virtual BOOL PreTranslateMessage(MSG* pMsg);
```

成员包括 `WorldManager` 智能指针、`WEPythonAdapter`、`GUI::MenuHelper` 等。

### 4.4 MainFrame 类层次

`MainFrame`(`mainframe.hpp:14-28`)继承链更复杂,体现 GUI 多重角色:

```cpp
// mainframe.hpp:14-28
class MainFrame
    : public BaseMainFrame
    , public IMainFrame
    , GUI::ActionMaker<MainFrame>,           // save prefab
    GUI::ActionMaker<MainFrame, 1>,          // show toolbar
    GUI::ActionMaker<MainFrame, 2>,          // hide toolbar
    GUI::ActionMaker<MainFrame, 3>,          // show status bar
    GUI::ActionMaker<MainFrame, 4>,          // hide status bar
    GUI::ActionMaker<MainFrame, 5>,          // show player preview
    GUI::ActionMaker<MainFrame, 6>,          // hide player preview
    GUI::UpdaterMaker<MainFrame>,            // update show toolbar
    GUI::UpdaterMaker<MainFrame, 1>,         // update show status bar
    GUI::UpdaterMaker<MainFrame, 2>,         // update player preview
    GUI::UpdaterMaker<MainFrame, 3>          // update tool mode
{
```

`IMainFrame` 接口(editor_shared)实现为内联空实现(`mainframe.hpp:60-67`),因为 WorldEditor 的视口逻辑主要在 `WorldEditorView` 中:

```cpp
// mainframe.hpp:60-67
void setMessageText( const wchar_t * pText );
void setStatusText( UINT id, const wchar_t * text );
bool cursorOverGraphicsWnd() const { return false; }
void updateGUI( bool force = false ) {}
Vector2 currentCursorPosition() const { return Vector2::ZERO; }
Vector3 getWorldRay(int x, int y) const { return Vector3::ZERO; }
void grabFocus() { SetFocus(); }
```

### 4.5 ProjectModule 类

`ProjectModule`(`project_module.hpp:20`)继承 `FrameworkModule`,是空间锁定/提交的入口模块:

```cpp
class ProjectModule : public FrameworkModule
{
public:
    virtual bool init( DataSectionPtr pSection );
    virtual void onStart();
    virtual int  onStop();
    virtual bool updateState( float dTime );
    virtual void render( float dTime );
    virtual bool handleKeyEvent( const KeyEvent & event );
    virtual bool handleMouseEvent( const MouseEvent & event );

    bool isReadyToLock() const;
    bool isReadyToCommitOrDiscard() const;
    bool lockSelection( const BW::string& description );
    bool discardLocks( const BW::string& description );
    void commitDone();
    void updateLockData();
```

`ProjectModule` 持有 `LockMap`、`GridCoord` 转换、相机位置,负责"项目视图"——俯视整个空间,框选网格锁定,提交到 bwlockd。

### 4.6 EditorChunkItemLinkableManager

`EditorChunkItemLinkableManager`(`editor_chunk_item_linker_manager.hpp:31`)管理可链接物体的关系,实现文件达 81864 字符,是 WorldManager 之外最大的单文件:

```cpp
// editor_chunk_item_linker_manager.hpp:31-45
class EditorChunkItemLinkableManager
{
public:
    typedef BW::map< UniqueID, UniqueID > GuidToGuidMap;

    EditorChunkItemLinkableManager();
    void tick();
    void updateLink(
        EditorChunkItemLinkable* pLinkable1, EditorChunkItemLinkable* pLinkable2 );
```

负责 GUID 映射、链接重建、加载/保存时的关系恢复。

---

## 五、关键算法与数据结构

### 5.1 GUI 数据驱动机制

WorldEditor 的菜单/工具栏完全由 `resources/data/gui.xml` 描述,启动时加载:

```cpp
// world_editor_app.cpp:497-500
DataSectionPtr guiRoot = BWResource::openSection( "resources/data/gui.xml" );
if( guiRoot )
    for( int i = 0; i < guiRoot->countChildren(); ++i )
        GUI::Manager::instance().add( new GUI::Item( guiRoot->openChild( i ) ) );
```

GUI 项通过 `ActionMaker` 字符串匹配派发,`UpdaterMaker` 负责启用/禁用/勾选状态。这种设计使 UI 布局与 C++ 逻辑解耦,UI 调整无需重新编译。

### 5.2 bwlockd 多人协作锁机制

bwlockd 是独立的锁定守护进程,WorldEditor 通过 `BWLockDConnection`(common 库)连接。`WorldManager::init` 中初始化:

```cpp
// world_manager.cpp:2184-2197
if ( Options::getOptionBool( "bwlockd/use", true ))
{
    BW::string host = Options::getOptionString( "bwlockd/host" );
    BW::string username = Options::getOptionString( "bwlockd/username" );
    if( username.empty() )
    {
        wchar_t name[1024];
        DWORD size = ARRAY_SIZE( name );
        GetUserName( name, &size );
        bw_wtoutf8( name, username );
    }
    BW::string hostname = host.substr( 0, host.find( ':' ) );
    conn_.init( host, username, 0, 0 );
}
```

锁定状态以网格(Grid)为单位,共 4 种状态(`bwlockd_connection.hpp:24-36`):

| 状态 | 含义 | 可编辑 |
|------|------|--------|
| `GS_NOT_LOCKED` | 无人锁定 | 否 |
| `GS_LOCKED_BY_ME` | 我锁定但不可编辑 | 否 |
| `GS_LOCKED_BY_OTHERS` | 他人锁定 | 否 |
| `GS_WRITABLE_BY_ME` | 我锁定且可编辑 | **是** |

`ProjectModule::lockSelection` 框选区域后向 bwlockd 申请锁,`commitDone` 提交,`discardLocks` 放弃。`WorldManager::isChunkWritable` 查询 chunk 是否可写。

### 5.3 ChunkProcessorManager 多线程分时

`WorldManager` 继承 `ChunkProcessorManager`,管理 chunk 的后台处理(光照、导航网格、地形阴影等)。构造函数注册线程阻塞回调:

```cpp
// world_manager.cpp:715-716
ChunkProcessorManager::setThreadBlockCallback( &checkThreadNeedsToBeBlocked );
WorldManager::allowChunkProcessorThreadsToRun( false );
```

`init` 末尾启动后台线程:

```cpp
// world_manager.cpp:2333
startNumThreads( NUM_BACKGROUND_CHUNK_PROCESSING_THREADS );
```

`allowChunkProcessorThreadsToRun` 控制线程运行/暂停,`WEApp::presenting` 回调在渲染呈现时控制:

```cpp
// world_editor_app.cpp:519-530
class WEApp : public App
{
    virtual void presenting( bool isPresenting )
    {
        static DogWatch s_watchThreadControl( "chunkProcessorThreads" );
        ScopedDogWatch scopedWatchThreadControl( s_watchThreadControl );
        if (!WorldManager::instance().uiBlocked())
        {
            WorldManager::allowChunkProcessorThreadsToRun( isPresenting );
        }
    }
};
```

Watcher 暴露分时参数(`world_manager.cpp:699-707`):

```cpp
MF_WATCH( "Chunk Processor/Time Slice", s_minimumAllowTimeSliceMS_, ... );
MF_WATCH( "Chunk Processor/Wait Warn Threshold", s_timeSlicePauseWarnThresholdMS_, ... );
```

### 5.4 AssetClient 资产管线接入

`Initialisation::initApp` 中创建 `AssetClient` 并阻塞等待连接:

```cpp
// initialisation.cpp:87-88
s_pAssetClient_.reset( new AssetClient() );
s_pAssetClient_->waitForConnection();
```

AssetClient 连接资产管线(asset_pipeline),用于触发资源编译、查询编译状态。`ResourceLoader::precompileEffects` 在 `WorldManager::init` 中预编译特效:

```cpp
// world_manager.cpp:2224-2232
if ( Options::getOptionInt( "precompileEffects", 1 ) )
{
    BW::vector<ISplashVisibilityControl*> SVCs;
    if ( CSplashDlg::getSVC() ) SVCs.push_back(CSplashDlg::getSVC());
    if (WaitDlg::getSVC()) SVCs.push_back(WaitDlg::getSVC());
    ResourceLoader::instance().precompileEffects( SVCs );
}
```

### 5.5 Python 脚本暴露

`world_editor_script.cpp`(56047 字符)将 WorldManager 能力暴露为 `BigWorld` 模块静态方法。`WorldManager` 头文件声明了丰富的 Python 接口(`world_manager.hpp:449-474`):

```cpp
// world_manager.hpp:449-471
PY_MODULE_STATIC_METHOD_DECLARE( py_worldRay )
PY_MODULE_STATIC_METHOD_DECLARE( py_repairTerrain )
PY_MODULE_STATIC_METHOD_DECLARE( py_farPlane )
PY_MODULE_STATIC_METHOD_DECLARE( py_save )
PY_MODULE_STATIC_METHOD_DECLARE( py_quickSave )
PY_MODULE_STATIC_METHOD_DECLARE( py_update )
PY_MODULE_STATIC_METHOD_DECLARE( py_render )
PY_MODULE_STATIC_METHOD_DECLARE( py_pause )
PY_MODULE_STATIC_METHOD_DECLARE( py_showEditorRenderables )
PY_MODULE_STATIC_METHOD_DECLARE( py_showUDOLinks )
PY_MODULE_STATIC_METHOD_DECLARE( py_revealSelection )
PY_MODULE_STATIC_METHOD_DECLARE( py_isChunkSelected )
PY_MODULE_STATIC_METHOD_DECLARE( py_selectAll )
PY_MODULE_STATIC_METHOD_DECLARE( py_isSceneBrowserFocused )
PY_MODULE_STATIC_METHOD_DECLARE( py_cursorOverGraphicsWnd )
PY_MODULE_STATIC_METHOD_DECLARE( py_importDataGUI )
PY_MODULE_STATIC_METHOD_DECLARE( py_exportDataGUI )
PY_MODULE_STATIC_METHOD_DECLARE( py_rightClick )
```

UI 适配层(`resources/scripts/UIAdapter.py`、`WorldEditorDirector.py` 等)全部用 Python 实现,通过这些静态方法驱动 C++ 编辑器。这是 WorldEditor 灵活性的核心来源——UI 行为可由脚本定制而无需重编译。

### 5.6 EditorChunkCache 缓存体系

`EditorChunkCache`(`world/editor_chunk_cache.cpp`,43144 字符)是 chunk 的编辑器扩展缓存,特化 `ChunkCache::Instance`:

```cpp
// common/editor_chunk_cache_base.hpp:17-18
template <>
EditorChunkCacheBase & ChunkCache::Instance<EditorChunkCacheBase>::operator()( Chunk & chunk ) const;
```

为每个 chunk 缓存 DataSection(`pChunkSection_`)、CData,提供 `edSave`/`edSaveCData` 保存接口。配套 `ChunkSaver`/`CdataSaver` 注册到 `UnsavedChunks` 系统统一保存。

### 5.7 选择与撤销/重做

`WorldManager` 维护 `selectedItems_` 列表,`setSelection` 设置选择。`ScopedDeferSelectionReplacement`(`world_manager.hpp:349-360`)是 RAII 守卫,延迟选择替换以避免在批量操作中频繁刷新:

```cpp
// world_manager.hpp:349-360
class ScopedDeferSelectionReplacement
{
public:
    ScopedDeferSelectionReplacement();
    ~ScopedDeferSelectionReplacement();
private:
    static int s_count_;
    static SimpleMutex s_mutex_;
    friend class WorldManager;
};
```

撤销/重做使用 common 库的 `UndoRedo` 单例,`undo_redo/` 目录下实现各类 `Operation`:地形高度、地形洞口、地形纹理、实体链接、站点链接、图合并、工具切换等。

---

## 六、配置项与命令行参数

### 6.1 Options 配置项

WorldEditor 通过 `Options`(appmgr)读写 `options.xml`,关键配置项:

| 配置项 | 类型 | 默认值 | 说明 |
|--------|------|--------|------|
| `bwlockd/use` | bool | true | 是否启用 bwlockd 协作锁 |
| `bwlockd/host` | string | - | bwlockd 服务器地址(host:port) |
| `bwlockd/username` | string | - | 用户名(空则取系统用户) |
| `precompileEffects` | int | 1 | 是否预编译特效 |
| `graphics/farclip` | float | 500 | 远裁剪面 |
| `render/chunk/vizMode` | int | 0 | chunk 可视化模式 |
| `terrain2/blendsBuildInterval` | int | - | 地形混合构建间隔 |
| `personality` | string | "Personality" | 脚本人格模块 |
| `system/language` | string | - | 语言文件 |
| `system/engineConfigXML` | string | - | 引擎配置 XML |
| `currentLanguage` | string | - | 当前语言 |
| `currentCountry` | string | - | 当前国家 |
| `messages/errorMsgs` | int | - | 错误消息显示开关 |

### 6.2 命令行参数

`parseCommandLineMF`(`world_editor_app.cpp:598-`)解析命令行,支持:

| 参数 | 说明 |
|------|------|
| `-UID` / `-uid` | 用户 ID(bwlockd 用户名覆盖) |
| `-r` / `--res` / `--options` | 资源/选项路径 |

`Automation::parseCommandLine`(`world_editor_app.cpp:592`)处理 Python 自动化命令行。

### 6.3 资源路径

| 路径 | 说明 |
|------|------|
| `resources/data/gui.xml` | GUI 布局定义 |
| `resources/data/filters.xml` | 过滤器定义 |
| `resources/data/modules.xml` | 模块定义 |
| `resources/data/options_page.xml` | 选项页定义 |
| `resources/data/placement.xml` | 放置预设 |
| `resources/scripts/*.py` | UI 适配脚本 |
| `helpers/languages/*.xml` | 语言文件 |

---

## 七、与其他模块的依赖关系

### 7.1 链接库依赖

`CMakeLists.txt:912-934` 声明链接库:

```cmake
BW_TARGET_LINK_LIBRARIES( worldeditor
    appmgr
    chunk
    chunk_scene_adapter
    controls
    cstdmf
    editor_shared          # GUI 后端抽象
    gizmo
    guimanager
    math
    moo
    particle
    post_processing
    pyscript
    resmgr
    romp
    space
    terrain
    tools_common          # 工具公共库
    ual                   # 统一资产浏览器
    libpython_tools       # Python 运行时
)
```

可选链接:`fmodsound`(当 `BW_FMOD_SUPPORT` 开启)。

### 7.2 模块依赖关系图

```
                    ┌─────────────────┐
                    │   worldeditor   │
                    └────────┬────────┘
        ┌───────────┬────────┼────────┬────────┬─────────┐
        ▼           ▼        ▼        ▼        ▼         ▼
   ┌─────────┐ ┌─────────┐ ┌──────┐ ┌──────┐ ┌──────┐ ┌────────┐
   │appmgr   │ │gizmo    │ │moo   │ │chunk │ │romp  │ │terrain │
   │(App/    │ │(Tool/   │ │(D3D) │ │      │ │(环境)│ │        │
   │ Module) │ │ Gizmo)  │ │      │ │      │ │      │ │        │
   └─────────┘ └─────────┘ └──────┘ └──────┘ └──────┘ └────────┘
        │           │        │        │        │        │
        ▼           ▼        ▼        ▼        ▼        ▼
   ┌─────────┐ ┌─────────┐ ┌──────┐ ┌──────┐ ┌──────┐ ┌────────┐
   │editor_  │ │tools_   │ │pyscript││space │ │post_ │ │particle│
   │shared   │ │common   │ │      │ │      │ │processing│ │      │
   │(GUI抽象)│ │(公共库) │ │      │ │      │ │      │ │        │
   └─────────┘ └─────────┘ └──────┘ └──────┘ └──────┘ └────────┘
                      │
                      ▼
               ┌─────────────┐
               │cstdmf/math  │
               │resmgr/controls│
               └─────────────┘
```

### 7.3 外部进程依赖

| 进程/服务 | 通信方式 | 用途 |
|-----------|---------|------|
| bwlockd | TCP(`BWLockDConnection`) | 多人协作锁定 |
| AssetClient | 进程内 + 管道 | 资产管线编译 |
| bwmachined | - | 机器守护(间接) |
| 邮件槽 `\\.\mailslot\WorldEditorUpdate` | Win32 Mailslot | 外部更新通知 |

### 7.4 与 common/editor_shared 的关系

WorldEditor 直接引用 common 库的:
- `BWLockDConnection`(bwlockd 协作)
- `SpaceEditor`(空间编辑回调注入)
- `EditorChunkCacheBase`(chunk 缓存基类)
- `UndoRedo`(撤销/重做单例)
- `RompHarness`(环境管理)

引用 editor_shared 库的:
- `IEditorApp`(应用抽象,`isMinimized`/`onIdle`)
- `IMainFrame`(主框架抽象)
- `MenuHelper`(MFC 菜单操作)
- `WaitCursor`/`Cursor`(光标 RAII)
- `BWFileDialog`/`FolderGuard`(文件对话框/目录守卫)

---

## 八、关键代码片段

### 8.1 WorldManager 构造函数(GUI 绑定与单例注入)

```cpp
// world_manager.cpp:668-717
, GUI::ActionMaker<WorldManager>(
    "changeSpace|newSpace|editSpace|recreateSpace|recentSpace|clearUndoRedoHistory|doExternalEditor|"
    "doReloadAllTextures|doReloadAllChunks|doExit|setLanguage|recalcCurrentChunk",
    &WorldManager::handleGUIAction )
, GUI::UpdaterMaker<WorldManager>( "updateRecreateSpace|updateUndo|updateRedo|updateExternalEditor|updateLanguage",
    &WorldManager::handleGUIUpdate )
, lastModifyTime_( 0 )
, cursor_( NULL )
, waitCursor_( true )
, warningOnLowMemory_( true )
, insideQuickSave_(false)
, chunkWatcher_ (new ChunkWatcher() )
// ...
{
    BW_GUARD;
    MF_WATCH( "Chunk Processor/Time Slice", s_minimumAllowTimeSliceMS_, ... );
    MF_WATCH( "Chunk Processor/Wait Warn Threshold", s_timeSlicePauseWarnThresholdMS_, ... );

    SpaceEditor::instance( this );              // 注入 SpaceEditor 单例
    SlowTaskHandler::handler( this );
    MaterialProperties::runtimeInitMaterialProperties();
    setPlayerPreviewMode( false );
    resetCursor();
    ChunkProcessorManager::setThreadBlockCallback( &checkThreadNeedsToBeBlocked );
    WorldManager::allowChunkProcessorThreadsToRun( false );
}
```

### 8.2 InternalInitInstance 核心段(窗口创建与初始化回调)

```cpp
// world_editor_app.cpp:505-547
if (!ProcessShellCommand(cmdInfo))   // 创建所有 GUI 窗口
{
    return FALSE;
}
m_pMainWnd->ShowWindow(SW_SHOWMAXIMIZED);
m_pMainWnd->UpdateWindow();

ASSERT( !s_mfApp );
class WEApp : public App
{
    virtual void presenting( bool isPresenting )
    {
        static DogWatch s_watchThreadControl( "chunkProcessorThreads" );
        ScopedDogWatch scopedWatchThreadControl( s_watchThreadControl );
        if (!WorldManager::instance().uiBlocked())
        {
            WorldManager::allowChunkProcessorThreadsToRun( isPresenting );
        }
    }
};
s_mfApp = new WEApp;

HINSTANCE hInst = AfxGetInstanceHandle();
MainFrame * mainFrame = (MainFrame *)(m_pMainWnd);

WaitDlg::show( LocaliseUTF8(L"WORLDEDITOR/INITIALISING_WORLDEDITOR_MSG") );

pWorldManager_ = WorldManagerPtr( new WorldManager );

if (!s_mfApp->init( hInst, m_pMainWnd->m_hWnd,
    mainFrame->GetActiveView()->m_hWnd,
    NULL,
    Initialisation::initApp ))   // 初始化回调
{
    return FALSE;
}
```

### 8.3 WorldManager::init 空间加载与失败清理

```cpp
// world_manager.cpp:2249-2283
InitFailureCleanup failureCleaner( inited_, *this );

if( !spaceManager_->num() || !changeSpace( spaceManager_->entry( 0 ), false ) )
{
    CSplashDlg::HideSplashScreen();
    if (WaitDlg::isValid())
        WaitDlg::getSVC()->setSplashVisible( false );
    for(;;)
    {
        MainFrame* mainFrame = (MainFrame *)WorldEditorApp::instance().mainWnd();
        MsgBox mb( Localise(L"WORLDEDITOR/WORLDEDITOR/BIGBANG/BIG_BANG/OPEN_SPACE_TITLE"),
            Localise(L"WORLDEDITOR/WORLDEDITOR/BIGBANG/BIG_BANG/OPEN_SPACE_TEXT"),
            Localise(L"WORLDEDITOR/WORLDEDITOR/BIGBANG/BIG_BANG/OPEN_SPACE_OPEN"),
            Localise(L"WORLDEDITOR/WORLDEDITOR/BIGBANG/BIG_BANG/OPEN_SPACE_CREATE"),
            Localise(L"WORLDEDITOR/WORLDEDITOR/BIGBANG/BIG_BANG/OPEN_SPACE_EXIT") );
        int result = mb.doModal( mainFrame->m_hWnd );
        if( result == 0 )
        {
            if( changeSpace( GUI::ItemPtr() ) ) break;
        }
        else if( result == 1 )
        {
            if( newSpace( GUI::ItemPtr() ) ) break;
        }
        else
        {
            exitRequested_ = true;
            return false;
        }
    }
}
```

### 8.4 WorldManager::fini 严格逆序释放

```cpp
// world_manager.cpp:737-790
void WorldManager::fini()
{
    BW_GUARD;
    if (!inited_) return;

    WorldManager::allowChunkProcessorThreadsToRun( true );
    BgTaskManager::instance().stopAll();
    ChunkProcessorManager::stopAll();
    FileIOTaskManager::instance().stopAll();
    ChunkProcessorManager::tick();

    // 清理未保存数据(必须在 Moo 存活时释放渲染资源)
    this->clearUnsavedData();

    if( inited_ )
    {
        bw_safe_delete( colourDrawContext_ );
        bw_safe_delete( shadowDrawContext_ );
        bw_safe_delete( selectionOverride_ );
        // ...
        Script::clearTimers();
        GlobalEmbodiments::fini();
        stopBackgroundCalculation();

        BW::vector<ChunkItemPtr> emptySelection;
        setSelection(emptySelection);
        UndoRedo::instance().clear();
        // ...
        SpaceMap::deleteInstance();
        forcedLodMap_.clearLODData();
        ResourceCache::instance().fini();
        // ...
        ToolList::clearAll();   // 必须在 ChunkManager fini 前
        ChunkManager::instance().fini();
        SpaceManager::instance().fini();
        // ...
    }
}
```

### 8.5 GUI 菜单/工具栏初始化

```cpp
// world_editor_app.cpp:566-579
menuHelper_.reset( new GUI::MenuHelper( mainFrame->GetSafeHwnd() ) );

// toolbar / menu initialisation
// IMPORTANT: The order of this call is important, leave it here!
GUI::Manager::instance().add( new GUI::Menu( "MainMenu", menuHelper_.get() ) );
AfxGetMainWnd()->DrawMenuBar();

// create Toolbars through the BaseMainFrame createToolbars method
mainFrame->createToolbars( "AppToolbars" );

// GUITABS Tearoff tabs system init and setup
PanelManager::init( mainFrame, mainFrame->GetActiveView() );
```

注释 `IMPORTANT: The order of this call is important` 强调初始化顺序敏感性——菜单、工具栏、面板必须按序创建,因 PanelManager 依赖工具栏已注册的项。

### 8.6 ProjectModule 锁定接口

```cpp
// project_module.hpp:44-71
bool isReadyToLock() const;
bool isReadyToCommitOrDiscard() const;

BW::set<BW::string> lockedChunksFromSelection( bool insideOnly );
BW::set<BW::string> graphFilesFromSelection();
BW::set<BW::string> vloFilesFromSelection();

bool lockSelection( const BW::string& description );
bool discardLocks( const BW::string& description );
void commitDone();
void updateLockData();
```

---

## 九、设计亮点与注意事项

### 9.1 设计亮点

#### 9.1.1 数据驱动 GUI 与命令模式

`gui.xml` 描述 UI,`ActionMaker`/`UpdaterMaker`/`OptionMap` 三件套通过字符串绑定 C++ 方法。优点:
- UI 布局调整无需重编译
- 新增动作只需 XML 加项 + C++ 加分支
- 状态更新(启用/禁用/勾选)集中到 `handleGUIUpdate`

代价:`handleGUIAction`/`handleGUIUpdate` 内部是字符串分发,大字符串匹配效率较低,且字符串拼写错误只能在运行时暴露。

#### 9.1.2 WorldManager 上帝对象的取舍

`WorldManager` 9 重继承 + 6714 行实现,是典型的上帝对象。优点:
- 集中管理,跨子系统协调简单(如选择改变触发 chunk dirty + 缩略图刷新 + 撤销栈)
- 单例访问减少传参
- 多重继承使各能力(Snap/Coord/SlowTask/SpaceEditor)自然组合

代价:
- 职责过载,难以测试
- fini 顺序敏感,注释频繁出现 "must be called before/after"
- 修改一处易引发连锁反应

#### 9.1.3 多线程分时与呈现同步

`WEApp::presenting` 回调在 D3D Present 前后控制 chunk 处理线程运行,`uiBlocked` 防止模态操作期间线程干扰,`ChunkProcessorManager::setThreadBlockCallback` 提供细粒度阻塞。这套机制平衡了后台处理吞吐与主线程渲染流畅性。

#### 9.1.4 Python 全暴露与 UI 适配

WorldManager 能力通过 `PY_MODULE_STATIC_METHOD_DECLARE` 暴露为 `BigWorld` 模块静态方法,UI 适配层(UIAdapter.py、WorldEditorDirector.py 等)用 Python 实现。这使:
- 工具栏/页面行为可脚本定制
- 自动化测试可通过 Python 驱动
- 第三方扩展无需改动 C++

#### 9.1.5 bwlockd 网格级协作

锁定粒度为 chunk 网格而非整个空间,支持多人同时编辑不同区域。4 种 GridStatus 精确区分"我锁但不可写"(如只读查看)与"我锁且可写"。`linkPoint` 机制支持跨锁定区域的链接点对齐。

#### 9.1.6 InitFailureCleanup RAII

`WorldManager::init` 使用 `InitFailureCleanup` 局部对象,在任意 `return false` 提前退出时自动清理已初始化的资源,避免泄漏。

### 9.2 注意事项

#### 9.2.1 初始化顺序敏感

`InternalInitInstance` 与 `WorldManager::init` 中大量注释强调顺序:
- `LensEffectManager` 必须在 `initScripts` 后(创建 PyTextureProvider)
- `clearUnsavedData` 必须在 Moo 存活时(BWT-22072)
- `ToolList::clearAll` 必须在 `ChunkManager::fini` 前(工具持有引用)
- 菜单 → 工具栏 → PanelManager 必须按序

调整顺序需极其谨慎。

#### 9.2.2 BIGWORLD_CLIENT_ONLY 条件编译

bwlockd、网络相关代码受 `BIGWORLD_CLIENT_ONLY` 宏控制:

```cpp
// world_manager.hpp:296-298
#ifndef BIGWORLD_CLIENT_ONLY
    BWLock::BWLockDConnection& connection();
#endif
```

CLIENT_ONLY 构建下无协作锁能力。

#### 9.2.3 MFC 内存分配器切换

`InternalInitInstance` 中创建 `CSingleDocTemplate` 前后临时切换内存分配器(`world_editor_app.cpp:421-442`),避免 MFC 在退出时因自定义分配器困惑。这是 MFC 与自定义内存系统集成的典型套路。

#### 9.2.4 单一可执行文件

WorldEditor 是单一 `BW_ADD_TOOL_EXE`,**不生成独立库**。所有源文件通过 `BW_BLOB_SOURCES` 打包进可执行文件,导致:
- 编译时间长
- 无法被其他工具复用代码(复用靠 common/editor_shared 库)

#### 9.2.5 world_manager.cpp 规模

`world_manager.cpp` 达 6714 行(约 25 万字符),是单个最复杂的文件。维护时建议:
- 优先按方法名定位而非通读
- 善用 `MF_WATCH` 暴露的 Watcher 调试运行时状态
- 关注 fini 顺序注释

#### 9.2.6 CVSWrapper 遗留

`CVSWrapper::init`(`world_manager.cpp:2151`)是版本控制集成遗留,现代构建中通常无实际 CVS 仓库,但初始化仍会执行,失败则 `return false`。

#### 9.2.7 Mailslot 更新通知

`CreateMailslot(L"\\\\.\\mailslot\\WorldEditorUpdate")`(`world_editor_app.cpp:581`)创建邮件槽,供外部进程通知 WorldEditor 刷新。这是 Win32 单机进程间通信,跨机器不可用。

### 9.3 关键文件速查

| 文件 | 行数/规模 | 作用 |
|------|----------|------|
| `framework/world_editor_app.cpp` | ~22869 字符 | MFC 应用入口 |
| `framework/initialisation.cpp` | ~13660 字符 | 全局资源初始化 |
| `world/world_manager.hpp` | 9 重继承声明 | WorldManager 接口 |
| `world/world_manager.cpp` | 6714 行 | WorldManager 实现 |
| `world/editor_chunk_item_linker_manager.cpp` | ~81864 字符 | 链接关系管理 |
| `world/editor_chunk_cache.cpp` | ~43144 字符 | chunk 编辑缓存 |
| `scripting/world_editor_script.cpp` | ~56047 字符 | Python 暴露 |
| `project/project_module.cpp` | ~58295 字符 | 项目/锁定模块 |
| `framework/mainframe.hpp` | 主框架声明 | GUI 多重继承 |
| `CMakeLists.txt` | 构建定义 | 单一可执行文件 |

### 9.4 启动流程时序总结

```
WinMain
  └─ WorldEditorApp::InitInstance (L347)
       └─ CallWithExceptionFilter → InternalInitInstance (L383)
            ├─ MFC/OLE/注册表/文档模板
            ├─ parseCommandLineMF
            ├─ GUI::Manager::init + 加载 gui.xml
            ├─ ProcessShellCommand → 创建 MainFrame/View
            ├─ new WorldManager
            ├─ s_mfApp->init(..., Initialisation::initApp)
            │    └─ Initialisation::initApp (initialisation.cpp:78)
            │         ├─ AssetClient::waitForConnection
            │         ├─ Input/Graphics/Network/Scripts/Consoles
            │         ├─ BgTaskManager + FileIOTaskManager
            │         └─ WorldManager::init (world_manager.cpp:2131)
            │              ├─ bwlockd 初始化
            │              ├─ changeSpace(默认空间)
            │              ├─ initRomp
            │              └─ startNumThreads(后台 chunk 处理)
            ├─ CooperativeMoo::init
            ├─ new WEPythonAdapter
            ├─ GUI::Menu + createToolbars + PanelManager::init
            └─ Automation::parseCommandLine
  └─ WorldEditorApp::Run → InternalRun (消息循环 + OnIdle)
  └─ WorldEditorApp::ExitInstance → InternalExitInstance
       └─ WorldManager::fini (逆序释放)
```

---

## 附录:与其他工具的差异

| 特性 | WorldEditor | ModelEditor | AssetProcessor |
|------|------------|-------------|----------------|
| 类型 | MFC SDI 可执行 | MFC 可执行 | 控制台可执行 |
| 规模 | ~100+ cpp,6714 行单文件 | 中等 | 中等 |
| 上帝对象 | WorldManager(9 重继承) | MEApp/Mutant | AssetProcessor |
| Python 暴露 | 全量(BigWorld 模块) | 部分 | 部分 |
| bwlockd | 是 | 否 | 否 |
| 多线程 | ChunkProcessor + BgTask + FileIO | 有限 | 有限 |
| GUI 数据驱动 | gui.xml + ActionMaker | 部分 | 无 |

WorldEditor 是工具链中复杂度最高的工具,其设计充分体现了 BigWorld 在"编辑器即小型游戏引擎"上的工程积累,也为理解 common/editor_shared 抽象层提供了最佳参照。
