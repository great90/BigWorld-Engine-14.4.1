# 第16章 WorldEditor 编辑器

> 前面几章我们走完了引擎的运行时侧——从资源管理、网络通信到服务器集群的各个进程。但一个 MMOG 世界并不是凭空产生的:地形怎么堆高?怪物刷新点怎么放?两座城之间的传送门怎么连?这些"造世界"的工作,都要靠一个工具来完成,它就是 **WorldEditor**(世界编辑器)。它是 BigWorld 工具链中规模最大、复杂度最高的程序,100+ 个 .cpp 文件,把可视化编辑、地形雕刻、物体放置、链接关系、多人协作、撤销重做全部塞进了一个进程里。本章将带你走进关卡设计师每天打交道的这个庞然大物,看清它的架构骨架与几个最值得品味的特色实现。

---

## 目录

- [第一部分:WorldEditor 概述与架构](#第一部分worldeditor-概述与架构)
  - [16.1 WorldEditor 是什么](#161-worldeditor-是什么)
  - [16.2 在工具链中的定位](#162-在工具链中的定位)
  - [16.3 整体架构拓扑](#163-整体架构拓扑)
  - [16.4 源码目录结构](#164-源码目录结构)
- [第二部分:GUI 框架与启动流程](#第二部分gui-框架与启动流程)
  - [16.5 MFC SDI 框架](#165-mfc-sdi-框架)
  - [16.6 WorldEditorApp 入口](#166-worldeditorapp-入口)
  - [16.7 启动流程详解](#167-启动流程详解)
  - [16.8 GUI 数据驱动机制](#168-gui-数据驱动机制)
- [第三部分:WorldManager "上帝对象"](#第三部分worldmanager-上帝对象)
  - [16.9 9 重继承的来历](#169-9-重继承的来历)
  - [16.10 集中管理的职责](#1610-集中管理的职责)
  - [16.11 God Object 的设计权衡](#1611-god-object-的设计权衡)
- [第四部分:Chunk 编辑集成](#第四部分chunk-编辑集成)
  - [16.12 EditorChunkCache 缓存体系](#1612-editorchunkcache-缓存体系)
  - [16.13 EditorChunkItem 基类](#1613-editorchunkitem-基类)
  - [16.14 各种 EditorChunkItem 子类](#1614-各种-editorchunkitem-子类)
- [第五部分:UndoRedo 撤销/重做系统](#第五部分undoredo-撤销重做系统)
  - [16.15 Operation 多态基类](#1615-operation-多态基类)
  - [16.16 Barrier 批量操作](#1616-barrier-批量操作)
  - [16.17 各种 Operation 实现](#1617-各种-operation-实现)
- [第六部分:bwlockd 多人协作](#第六部分bwlockd-多人协作)
  - [16.18 BWLockDConnection 连接](#1618-bwlockdconnection-连接)
  - [16.19 锁粒度与四种状态](#1619-锁粒度与四种状态)
  - [16.20 协作编辑流程](#1620-协作编辑流程)
- [第七部分:AssetClient 资源管线集成](#第七部分assetclient-资源管线集成)
  - [16.21 资源管线接入](#1621-资源管线接入)
  - [16.22 实时编译通知](#1622-实时编译通知)
- [第八部分:编辑器工具集](#第八部分编辑器工具集)
  - [16.23 Tool 框架](#1623-tool-框架)
  - [16.24 各种特化工具](#1624-各种特化工具)
- [第九部分:common 与 editor_shared 库](#第九部分common-与-editor_shared-库)
  - [16.25 tools_common 公共库](#1625-tools_common-公共库)
  - [16.26 editor_shared GUI 抽象层](#1626-editor_shared-gui-抽象层)
- [第十部分:特色实现深度剖析](#第十部分特色实现深度剖析)
  - [16.27 WorldManager God Object 设计权衡](#1627-worldmanager-god-object-设计权衡)
  - [16.28 UndoRedo 命令模式剖析](#1628-undoredo-命令模式剖析)
  - [16.29 bwlockd 多人协作剖析](#1629-bwlockd-多人协作剖析)
  - [16.30 AssetClient 实时编译剖析](#1630-assetclient-实时编译剖析)
  - [16.31 本章小结](#1631-本章小结)

---

## 第一部分:WorldEditor 概述与架构

### 16.1 WorldEditor 是什么

#### 16.1.1 关卡设计师的核心工具

如果你问一个 MMOG 团队里"谁负责把世界造出来",答案一定是关卡设计师(Level Designer)。他们每天打开的软件,就是 WorldEditor。在这个程序里,设计师能做这些事:

- **创建空间(Space)**:开辟一块新的游戏世界,设定大小、地形格式
- **雕刻地形**:用笔刷抬升/降低高度图、画纹理层、挖洞、做水面
- **放置物体**:模型、灯光、粒子、水位、传送点、围栏、树木……
- **建立链接**:把两个传送点连起来,把实体和用户数据对象绑起来
- **后处理编排**:用节点编辑器拼装后期特效链
- **多人协作**:几个人同时编辑同一个大世界,互不踩脚
- **提交资源**:把改动喂给资产管线,触发重新编译

简单说,客户端最终跑起来的那个"世界",在它还是一片空白之前,就是 WorldEditor 一笔一笔画出来的。

#### 16.1.2 规模与组成

WorldEditor 的源码位于 `programming/bigworld/tools/worldeditor/`,是一个由 100+ 个 .cpp 文件组成的**单一可执行文件**(通过 `BW_ADD_TOOL_EXE(worldeditor)` 构建)。它不是一个小工具——`world_manager.cpp` 一个文件就有 251830 个字符(约 6700 行),`editor_chunk_item_linker_manager.cpp` 也有 81864 字符。整个项目按功能分成 16 个分组,我们稍后会逐一看到。

### 16.2 在工具链中的定位

WorldEditor 不是孤岛,它要和工具链的其它部分协作。下图展示了它在工具链中的位置:

```
┌─────────────────────────────────────────────────────────────┐
│                      WorldEditor 进程                       │
│                                                             │
│  ┌──────────┐  ┌────────────┐  ┌────────────────────────┐  │
│  │ WorldEditor│  │ MainFrame  │  │ PanelManager           │  │
│  │ App(MFC) │─▶│ (主框架)   │─▶│ (属性页/工具栏)        │  │
│  └─────┬────┘  └─────┬──────┘  └────────────────────────┘  │
│        │             │                                       │
│        ▼             ▼                                       │
│  ┌──────────────────────────────────────────────────────┐    │
│  │      WorldManager (上帝对象, 9 重继承)             │    │
│  │  场景 / 选择 / 编辑 / 历史 / 视图 / 多线程 / 锁     │    │
│  └─────┬───────────────┬───────────────┬────────────────┘    │
│        │               │               │                    │
└────────┼───────────────┼───────────────┼────────────────────┘
         │               │               │
         ▼               ▼               ▼
   ┌──────────┐    ┌──────────┐    ┌──────────────┐
   │ bwlockd  │    │AssetClient│   │ Python 脚本   │
   │ (锁定服务)│   │ (资产管线)│   │ (UIAdapter)   │
   └──────────┘    └─────┬────┘    └──────────────┘
                         │
                         ▼
                   ┌──────────┐
                   │jit_compiler│
                   │ (编译守护)│
                   └──────────┘
```

它对外有三条关键通道:

1. **bwlockd**:多人协作时的锁定服务器,防止两个人同时改同一个 chunk
2. **AssetClient**:连到 jit_compiler,资源改动后自动触发重新编译
3. **Python 脚本**:把 WorldManager 的能力全暴露出去,UI 适配层完全用 Python 写

### 16.3 整体架构拓扑

WorldEditor 内部分层清晰,从外到里是:

```
应用层    WorldEditorApp (MFC CWinApp)
          ├─ MainFrame (主框架窗口)
          ├─ WorldEditorDoc (MFC 文档)
          └─ WorldEditorView (3D 视口)
                │
框架层    Initialisation::initApp (全局资源初始化)
          ├─ AssetClient (资产管线)
          ├─ InputDevices (输入)
          ├─ Graphics (D3D)
          ├─ Scripts (Python)
          └─ BgTaskManager / FileIOTaskManager (后台线程)
                │
核心层    WorldManager (上帝对象)
          ├─ BWLockDConnection (协作锁)
          ├─ RompHarness (环境/天气)
          ├─ ChunkProcessorManager (后台 chunk 处理)
          ├─ EditorChunkCache (chunk 缓存)
          ├─ EditorChunkItemLinkerManager (链接关系)
          └─ SceneBrowser (场景浏览器)
                │
数据层    lib/chunk (chunk 系统)
          ├─ Chunk / ChunkItem / ChunkSpace
          └─ UnsavedChunks (统一保存)
```

#### 16.3.1 关键设计原则

| 原则 | 说明 |
|------|------|
| **上帝对象模式** | `WorldManager` 单例聚合 9 重继承,集中管理几乎所有编辑器状态 |
| **MFC SDI 框架** | 基于 `CWinApp` + `CSingleDocTemplate`,文档/视图/主框架三件套 |
| **GUI 数据驱动** | 菜单/工具栏由 `gui.xml` 描述,C++ 通过字符串动作名派发 |
| **Python 全暴露** | WorldManager 能力暴露为 `BigWorld` 模块静态方法 |
| **多线程分时** | `ChunkProcessorManager` + `BgTaskManager` 三套后台线程 |
| **协作锁前置** | 编辑前通过 bwlockd 锁定 chunk 网格 |
| **RAII 资源管理** | `WaitCursor`/`FolderGuard`/`ScopedDeferSelectionReplacement` 等守卫 |

### 16.4 源码目录结构

WorldEditor 源码组织成 16 个分组:

```
programming/bigworld/tools/worldeditor/
├── CMakeLists.txt          # BW_ADD_TOOL_EXE(worldeditor)
├── config.hpp              # 模块配置宏
├── forward.hpp             # 前置声明
├── pch.hpp / pch.cpp       # 预编译头
├── resource.h              # 资源 ID
│
├── framework/              # ① MFC 应用框架
│   ├── world_editor_app.*  #    WorldEditorApp (CWinApp + IEditorApp)
│   ├── initialisation.*    #    Initialisation::initApp/finiApp
│   ├── mainframe.*         #    MainFrame (主框架窗口)
│   ├── world_editor_doc.*  #    WorldEditorDoc (MFC 文档)
│   └── world_editor_view.* #    WorldEditorView (3D 视口)
│
├── world/                  # ② WorldManager 与 Chunk 系统
│   ├── world_manager.*     #    ★核心上帝对象 (6700+ 行)
│   ├── editor_chunk_cache.*#    EditorChunkCache (chunk 编辑扩展)
│   ├── editor_chunk_item_linker_manager.*  # 链接管理 (81864 字符)
│   ├── editor_chunk_link_manager.*
│   ├── editor_chunk_navmesh_cache.*
│   ├── editor_chunk_overlapper.*
│   ├── editor_chunk_thumbnail_cache.*
│   ├── editor_chunk_lock_visualizer.*
│   ├── vlo_manager.*       #    Very Large Object 管理
│   ├── item_info_db.*
│   ├── world_editor_romp_harness.*
│   ├── we_chunk_saver.*
│   └── items/              # ③ 各类 EditorChunkItem
│       ├── editor_chunk_model.*      # 模型
│       ├── editor_chunk_entity.*     # 实体
│       ├── editor_chunk_light.*      # 灯光
│       ├── editor_chunk_particle_system.* # 粒子系统
│       ├── editor_chunk_water.*      # 水位
│       ├── editor_chunk_station.*    # 传送点
│       ├── editor_chunk_tree.*       # 树木
│       ├── editor_chunk_marker.*    # 标记
│       ├── editor_chunk_link.*      # 链接
│       ├── editor_chunk_portal.*    # 门户
│       ├── editor_chunk_vlo.*       # VLO
│       └── ...                      # 共 20+ 种物体
│
├── editor/                 # ④ 编辑器交互
│   ├── chunk_editor.*      #    物体编辑对话框
│   ├── chunk_item_placer.* #    物体放置器
│   ├── chunk_placer.*
│   ├── item_editor.*       #    物体编辑器
│   ├── item_locator.*     #    物体定位器
│   ├── item_properties.*   #    物体属性
│   ├── link_gizmo.*        #    链接 gizmo
│   ├── link_property.*
│   └── snaps.*            #    吸附
│
├── terrain/                # ⑤ 地形编辑
│   └── editor_chunk_terrain.*
│
├── gui/                    # ⑥ 图形界面
│   ├── controls/           #    自定义 MFC 控件
│   ├── dialogs/            #    模态对话框
│   ├── pages/              #    属性页 + PanelManager
│   ├── post_processing/    #    后处理链节点编辑器
│   └── scene_browser/      #    场景浏览器
│
├── project/                # ⑦ 项目/空间管理
│   ├── project_module.*    #    ProjectModule (锁定/提交入口)
│   ├── space_map.*         #    空间俯视图
│   ├── lock_map.*          #    锁定地图
│   ├── chunk_photographer.*#    chunk 缩略图拍照
│   └── nearby_chunk_loader.*
│
├── scripting/              # ⑧ Python 暴露
│   ├── world_editor_script.* #  (56047 字符)
│   └── we_python_adapter.*
│
├── undo_redo/              # ⑨ 撤销/重做 Operation
│   ├── terrain_height_map_undo.*
│   ├── terrain_hole_map_undo.*
│   ├── terrain_texture_layer_undo.*
│   ├── entity_array_undo.*
│   ├── station_link_operation.*
│   ├── user_data_object_link_operation.*
│   ├── linker_operations.*
│   ├── merge_graphs_operation.*
│   └── tool_change_operation.*
│
├── import/                 # ⑩ 地形导入
├── collisions/             # ⑪ 编辑器专用碰撞回调
├── height/                 # ⑫ 高度图
├── graph/                  # ⑬ 通用图视图
├── misc/                   # ⑭ 相机/选项/选择过滤器
└── res/                    # ⑮ 资源文件(图标/位图/光标)
```

这就是 WorldEditor 的全貌。下面我们逐层深入。

---

## 第二部分:GUI 框架与启动流程

### 16.5 MFC SDI 框架

WorldEditor 是一个标准的 **MFC SDI(Single Document Interface)应用**。如果你做过 Windows 桌面开发,对这套结构不会陌生:

- **Application**:继承 `CWinApp`,管理进程生命周期
- **Document Template**:用 `CSingleDocTemplate` 把文档、主框架、视图绑在一起
- **MainFrame**:主窗口,承载工具栏、菜单、状态栏
- **Document**:数据载体(虽然 WorldEditor 的"数据"其实是 chunk 文件)
- **View**:3D 视口,处理鼠标键盘、调用 Moo 渲染

这套结构在 `world_editor_app.cpp:431-437` 注册:

```cpp
// programming/bigworld/tools/worldeditor/framework/world_editor_app.cpp  L431-437
CSingleDocTemplate* pDocTemplate;
pDocTemplate = new CSingleDocTemplate(
    IDR_MAINFRAME,
    RUNTIME_CLASS(WorldEditorDoc),
    RUNTIME_CLASS(MainFrame),       // main SDI frame window
    RUNTIME_CLASS(WorldEditorView));
AddDocTemplate(pDocTemplate);
```

> **新手提示**:MFC 的 `RUNTIME_CLASS` 宏配合 `DECLARE_DYNCREATE`/`IMPLEMENT_DYNCREATE` 实现 RTTI,让框架能在运行时按需创建文档/视图/框架对象。这是 MFC 的"动态创建"机制。

### 16.6 WorldEditorApp 入口

#### 16.6.1 全局 theApp 对象

MFC 应用的入口是一个全局 `CWinApp` 派生对象。WorldEditor 在 `world_editor_app.cpp:59` 声明:

```cpp
// programming/bigworld/tools/worldeditor/framework/world_editor_app.cpp  L59
WorldEditorApp theApp; // The one and only WorldEditorApp object
```

MFC 框架在 `WinMain` 中依次调用 `InitInstance` → `Run` → `ExitInstance`。WorldEditor 通过 `CallWithExceptionFilter` 包装这三个方法,接入自定义异常过滤:

```cpp
// programming/bigworld/tools/worldeditor/framework/world_editor_app.cpp  L347-369
BOOL WorldEditorApp::InitInstance()
{
    BW::Allocator::setSystemStage( BW::Allocator::SS_MAIN );
    BOOL result = CallWithExceptionFilter( this, &WorldEditorApp::InternalInitInstance );
    if (!result)
    {
        // 失败时弹出错误提示
        MessageBox( NULL,
            L"WorldEditor failed to initailise itself correctly, ...",
            L"WorldEditor", MB_OK );
    }
    return result;
}
```

#### 16.6.2 WorldEditorApp 类层次

`WorldEditorApp` 同时继承 MFC `CWinApp` 与抽象接口 `IEditorApp`(来自 editor_shared):

```cpp
// programming/bigworld/tools/worldeditor/framework/world_editor_app.hpp  L21-24
class WorldEditorApp
    : public CWinApp
    , public IEditorApp
```

`IEditorApp` 是 editor_shared 库定义的抽象接口,只有两个方法:

```cpp
// programming/bigworld/tools/editor_shared/app/i_editor_app.hpp  L8-14
class IEditorApp
{
public:
    virtual bool isMinimized();
    virtual void onIdle() {};
};
```

这种"工具逻辑通过抽象接口查询 MFC 应用状态"的设计,让 editor_shared 库不必依赖 MFC,为未来切换到 Qt 后端留了门(虽然 Qt 后端目前还不完整)。

### 16.7 启动流程详解

`InternalInitInstance`(`world_editor_app.cpp:383`)是真正的启动逻辑,流程长达 27 步。我们抓主干看:

```
InternalInitInstance
  │
  ├── 1. Name::init()                          # 命名系统
  ├── 2. InitCommonControls / AfxInitRichEdit2 # MFC 通用控件
  ├── 3. CWinApp::InitInstance / AfxOleInit    # MFC + OLE
  ├── 4. SetRegistryKey("BigWorld-WorldEditor")# 注册表键
  ├── 5. CSingleDocTemplate(Doc/MainFrame/View)# 文档模板
  ├── 6. new BWResource()                      # 资源系统
  ├── 7. parseCommandLineMF()                   # 命令行解析
  ├── 8. StringProvider::load(语言文件)         # 本地化
  ├── 9. GUI::Manager::init()                   # GUI 管理器
  ├── 10. 加载 gui.xml → GUI::Item              # GUI 数据驱动
  ├── 11. ProcessShellCommand(cmdInfo)           # ★创建主窗口
  ├── 12. m_pMainWnd->ShowWindow(SW_SHOWMAXIMIZED)
  ├── 13. new WEApp (App 派生,含 presenting 回调)
  ├── 14. new WorldManager                       # ★上帝对象构造
  ├── 15. s_mfApp->init(..., Initialisation::initApp)  # ★核心初始化
  ├── 16. CooperativeMoo::init()                # 协作 MOO
  ├── 17. new WEPythonAdapter()                 # Python 适配器
  ├── 18. new GUI::MenuHelper(mainFrame)        # 菜单助手
  ├── 19. GUI::Manager::add(new GUI::Menu(...)) # 菜单
  ├── 20. mainFrame->createToolbars("AppToolbars")  # 工具栏
  └── 21. PanelManager::init(mainFrame, view)   # 面板管理器
```

关键代码在 `world_editor_app.cpp:539-547`:

```cpp
// programming/bigworld/tools/worldeditor/framework/world_editor_app.cpp  L539-547
pWorldManager_ = WorldManagerPtr( new WorldManager );

if (!s_mfApp->init( hInst, m_pMainWnd->m_hWnd,
    mainFrame->GetActiveView()->m_hWnd,
    NULL,
    Initialisation::initApp ))   // 回调注入
{
    return FALSE;
}
```

注意 `App::init` 的最后一个参数是 `Initialisation::initApp` **函数指针**。这是一种"控制反转":框架层(`App`)不知道具体要初始化什么,由调用方(WorldEditor)注入回调。这让 `App` 类能被 ModelEditor 等其它工具复用。

#### 16.7.1 Initialisation::initApp 全局资源初始化

`initApp`(`initialisation.cpp:78-150`)负责初始化全局资源,顺序严格:

```cpp
// programming/bigworld/tools/worldeditor/framework/initialisation.cpp  L78-150
bool Initialisation::initApp( HINSTANCE hInstance, HWND hWndApp, HWND hWndGraphics )
{
    s_pAssetClient_.reset( new AssetClient() );
    s_pAssetClient_->waitForConnection();      // 阻塞等待资产管线

    initErrorHandling();
    initTiming();

    InputDevices * pInputDevices = new InputDevices();
    InputDevices::instance().init( hInstance, hWndGraphics );

    Initialisation::initGraphics(hInstance, hWndGraphics);  // D3D 设备

    initNetwork();                            // Winsock

    Initialisation::initScripts();           // Python 解释器

    s_pLensEffectManager = LensEffectManagerPtr( new LensEffectManager() );
    MaterialKinds::init();

    Initialisation::initConsoles();

    BgTaskManager::init();
    BgTaskManager::instance().startThreads( "Init App Thread", 1 );

    FileIOTaskManager::init();
    FileIOTaskManager::instance().startThreads("File IO Thread", 1);

    Initialisation::initSound();

    WorldManager::instance().init( s_hInstance, s_hWndApp, s_hWndGraphics );

    return true;
}
```

初始化阶段汇总:

| 阶段 | 调用 | 说明 |
|------|------|------|
| 资产管线 | `AssetClient::waitForConnection` | 阻塞等待资产管线连接 |
| 输入 | `InputDevices::init` | 键鼠输入设备 |
| 图形 | `initGraphics` | D3D 设备初始化 |
| 网络 | `initNetwork` | Winsock |
| 脚本 | `initScripts` | Python 解释器 |
| 镜头特效 | `new LensEffectManager` | 必须在脚本后(PyTextureProvider) |
| 材质 | `MaterialKinds::init` | 物理材质种类 |
| 后台任务 | `BgTaskManager::startThreads` | 1 个通用后台线程 |
| 文件 IO | `FileIOTaskManager::startThreads` | 1 个文件 IO 线程 |
| 声音 | `initSound` | FMOD |
| 世界管理器 | `WorldManager::init` | ★编辑器核心初始化 |

### 16.8 GUI 数据驱动机制

WorldEditor 的菜单和工具栏**完全由 XML 描述**,启动时加载:

```cpp
// programming/bigworld/tools/worldeditor/framework/world_editor_app.cpp  L497-500
DataSectionPtr guiRoot = BWResource::openSection( "resources/data/gui.xml" );
if( guiRoot )
    for( int i = 0; i < guiRoot->countChildren(); ++i )
        GUI::Manager::instance().add( new GUI::Item( guiRoot->openChild( i ) ) );
```

`gui.xml` 里每一项都有一个字符串动作名(如 `"doSave"`、`"changeSpace"`),C++ 通过 `GUI::ActionMaker` 把字符串绑定到方法:

```cpp
// programming/bigworld/tools/worldeditor/world/world_manager.cpp  L668-672
, GUI::ActionMaker<WorldManager>(
    "changeSpace|newSpace|editSpace|recreateSpace|recentSpace|clearUndoRedoHistory|doExternalEditor|"
    "doReloadAllTextures|doReloadAllChunks|doExit|setLanguage|recalcCurrentChunk",
    &WorldManager::handleGUIAction )
```

`|` 分隔的动作名对应 `gui.xml` 中声明的项,GUI 框架派发时调用 `handleGUIAction`,内部按字符串分发到具体实现。这是典型的**命令模式 + 数据驱动 UI**:

- **优点**:UI 布局改了不用重编译 C++,设计师可以自己调 XML
- **缺点**:字符串匹配较脆弱,typo 不会在编译期报错

`UpdaterMaker` 负责菜单项的启用/禁用/勾选状态,机制类似。

---

## 第三部分:WorldManager "上帝对象"

### 16.9 9 重继承的来历

`WorldManager` 是 WorldEditor 的中枢。它定义在 `world_manager.hpp:84-95`,采用 **9 重继承**聚合多重职责:

```cpp
// programming/bigworld/tools/worldeditor/world/world_manager.hpp  L84-95
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
| `SnapProvider` | gizmo | 提供位置/角度吸附(`snapPosition`/`snapAngles`) |
| `CoordModeProvider` | gizmo | 提供坐标系模式(世界/本地/视图) |
| `ReferenceCount` | cstdmf | 引用计数,允许智能指针管理 |
| `SlowTaskHandler` | cstdmf | 慢任务处理(进度条/可取消任务) |
| `GUI::ActionMaker<WorldManager>` | guimanager | 将 GUI 动作字符串绑定到 `handleGUIAction` |
| `GUI::OptionMap` | guimanager | 提供 GUI 选项读写接口 |
| `GUI::UpdaterMaker<WorldManager>` | guimanager | 将 GUI 更新器绑定到 `handleGUIUpdate` |
| `ChunkProcessorManager` | chunk | chunk 后台处理器管理(多线程) |
| `SpaceEditor` | common | 空间编辑回调(`changedChunk`/`isChunkWritable`) |

> **新手疑问**:为什么要 9 重继承?能不能拆开?
>
> 理论上可以,但实际上这些职责高度耦合:GUI 动作要操作选择,选择要触发 UndoRedo,UndoRedo 要改 chunk,chunk 改了要通知资产管线……拆成 9 个独立对象后,它们之间还得互相持有指针,代码并不会更清晰。BigWorld 选择把它们捏成一个对象,用单例访问,换取了调用上的便利。这就是典型的 God Object 权衡。

### 16.10 集中管理的职责

`WorldManager` 集中管理以下子系统:

#### 16.10.1 场景管理

- `geometryMapping()` / `getCurrentSpace()`:获取当前空间
- `getChunk(chunkID, forceIntoMemory)`:加载指定 chunk
- `changedChunk(pChunk, flags)`:标记 chunk 已修改(触发缩略图重算、LOD 重建等)
- `reloadAllChunks()`:重载所有 chunk
- `markChunks()` / `unloadChunks()`:批量标记/卸载

#### 16.10.2 选择管理

```cpp
// programming/bigworld/tools/worldeditor/world/world_manager.hpp  L369-380
void setSelection( const BW::vector<ChunkItemPtr>& items, bool updateSelection = true );
void getSelection();
const BW::vector<ChunkItemPtr>& selectedItems() const { return selectedItems_; }
bool isItemSelected( ChunkItemPtr item ) const;
bool isChunkSelected( Chunk * pChunk ) const;
void replaceSelection( const ChunkItemPtr & itemToRemove, 
    const ChunkItemPtr & itemToAdd );
```

`selectedItems_` 是当前选中的物体列表。`ScopedDeferSelectionReplacement` 是一个 RAII 守卫,在批量操作时延迟选择刷新,避免频繁重绘。

#### 16.10.3 渲染管理

`WorldManager` 把渲染拆成多个阶段,允许"分时"渲染:

```cpp
// programming/bigworld/tools/worldeditor/world/world_manager.hpp  L219-236
void beginRender();
void renderRompPreScene();
void renderChunksInUpdate();
void renderChunks();
void renderTerrain();
void renderEditorGizmos( Moo::DrawContext& drawContext );
void tickEditorTickables();
void renderEditorRenderables();
void renderDebugGizmos();
void renderRompScene();
void renderRompPostScene( Moo::DrawContext& drawContext );
void endRender();
```

#### 16.10.4 保存管理

- `save()`:完整保存(交互式,可能弹对话框)
- `quickSave()`:快速保存
- `tickSavingChunks()`:每帧推进后台保存
- `checkForReadOnly()`:检查只读文件

#### 16.10.5 工具管理

- `snapsEnabled()` / `movementSnaps()` / `angleSnaps()`:吸附设置
- `snapMode()` / `getCoordMode()`:坐标系模式
- `setEscapableProcess()` / `escapePressed()`:可取消任务

#### 16.10.6 Python 接口

`WorldManager` 头文件声明了丰富的 Python 接口:

```cpp
// programming/bigworld/tools/worldeditor/world/world_manager.hpp  L449-471
PY_MODULE_STATIC_METHOD_DECLARE( py_worldRay )
PY_MODULE_STATIC_METHOD_DECLARE( py_repairTerrain )
PY_MODULE_STATIC_METHOD_DECLARE( py_farPlane )
PY_MODULE_STATIC_METHOD_DECLARE( py_save )
PY_MODULE_STATIC_METHOD_DECLARE( py_quickSave )
PY_MODULE_STATIC_METHOD_DECLARE( py_update )
PY_MODULE_STATIC_METHOD_DECLARE( py_render )
PY_MODULE_STATIC_METHOD_DECLARE( py_pause )
PY_MODULE_STATIC_METHOD_DECLARE( py_revealSelection )
PY_MODULE_STATIC_METHOD_DECLARE( py_isChunkSelected )
PY_MODULE_STATIC_METHOD_DECLARE( py_selectAll )
PY_MODULE_STATIC_METHOD_DECLARE( py_rightClick )
// ... 共 20+ 个
```

这些静态方法在 `world_editor_script.cpp`(56047 字符)里注册到 Python 的 `BigWorld` 模块。UI 适配层(`resources/scripts/UIAdapter.py`、`WorldEditorDirector.py` 等)全部用 Python 实现,通过这些静态方法驱动 C++ 编辑器。这是 WorldEditor 灵活性的核心来源——UI 行为可由脚本定制而无需重编译。

### 16.11 God Object 的设计权衡

#### 16.11.1 反模式?还是务实选择?

从纯 OOP 角度看,`WorldManager` 是教科书级的 **God Object 反模式**:

- **职责过多**:一个类管场景、选择、渲染、保存、工具、Python、锁、多线程……
- **状态过多**:成员变量几十个,相互依赖
- **方法过多**:公开方法上百个
- **测试困难**:无法单独测试某一职责
- **修改风险大**:改一处可能影响其它职责

但在编辑器这个特定场景下,它也有明显的好处:

1. **调用便利**:任何代码都能通过 `WorldManager::instance().xxx()` 访问任意状态,不必传一堆指针
2. **避免循环依赖**:把相关职责放一起,模块间不会形成环
3. **状态一致**:所有状态在一个对象里,易于维护不变量
4. **历史原因**:WorldEditor 是从早期版本演进来的,拆分成本太高

#### 16.11.2 缓解措施

BigWorld 并没有放任 God Object 膨胀,而是采取了几种缓解措施:

1. **EditorChunkItemLinkerManager 分离**:链接关系管理虽然属于 WorldManager 范畴,但被拆成独立类(81864 字符)
2. **SpaceEditor 抽象基类**:把"空间编辑回调"抽成接口,WorldManager 继承并注入,让 common 库不依赖具体实现
3. **ScopedDeferSelectionReplacement 等 RAII 守卫**:把状态管理封装在小类里
4. **ChunkProcessorManager 多线程分时**:把后台处理委托给独立的线程池

> **新手提示**:God Object 不是"错",而是一种"权衡"。在工具型软件(尤其是 IDE/编辑器)里很常见。理解它的代价,比一味批判它更重要。

---

## 第四部分:Chunk 编辑集成

WorldEditor 的核心数据是 chunk。chunk 是 BigWorld 空间分割的基本单元(详见第 9 章 CellApp 与空间管理)。WorldEditor 在 lib/chunk 的基础上,叠加了一层"编辑器扩展"。

### 16.12 EditorChunkCache 缓存体系

#### 16.12.1 ChunkCache 机制回顾

lib/chunk 提供了 `ChunkCache` 机制:每个 chunk 可以挂载多个缓存,随 chunk 一起加载/卸载。这是"装饰器"模式——chunk 本身只管空间数据和物体列表,具体用途(渲染、碰撞、导航网格、编辑器扩展)由各自的 cache 负责。

#### 16.12.2 EditorChunkCacheBase

`tools/common/editor_chunk_cache_base.hpp` 定义了编辑器 chunk 缓存的基类:

```cpp
// programming/bigworld/tools/common/editor_chunk_cache_base.hpp  L32-60
class EditorChunkCacheBase : public EditorChunkProcessorCache
{
public:
    EditorChunkCacheBase( Chunk & chunk );

    virtual bool load( DataSectionPtr pSec, DataSectionPtr pCdata );

    bool edSave();
    bool edSaveCData();

    DataSectionPtr pChunkSection();
    DataSectionPtr pCDataSection();

    static Instance<EditorChunkCacheBase> instance;

protected:
    virtual bool saveCDataInternal( DataSectionPtr ds,  
                                    const BW::string& filename );

    Chunk & chunk_;
    DataSectionPtr pChunkSection_;   // chunk 的 DataSection 缓存
};
```

它特化了 `ChunkCache::Instance<EditorChunkCacheBase>`,让任何代码都能通过 `EditorChunkCacheBase::instance(chunk)` 拿到该 chunk 的编辑器缓存。

> **关键注释**(来自源码):
> ```
> Things that want to fiddle with datasections in a chunk should
> either keep the one they were loaded with (if they're an item) or use
> the root datasection stored in this cache, as it may be the only correct
> version of it. i.e. you cannot go back and get stuff from the .chunk
> file through BWResource as the cache will likely be well stuffed, and
> the file may not even be there (if the scene was saved with that chunk
> deleted and it's since been undone).
> ```
>
> 意思是:不要用 `BWResource` 重新读 .chunk 文件,因为缓存里的版本才是"正确"的——文件可能已被删除(但还在 UndoRedo 栈里)。这是编辑器的典型陷阱。

#### 16.12.3 EditorChunkCache 派生类

`tools/worldeditor/world/editor_chunk_cache.hpp` 定义了 WorldEditor 专用的派生类:

```cpp
// programming/bigworld/tools/worldeditor/world/editor_chunk_cache.hpp  L65-100
class EditorChunkCache : public EditorChunkCacheBase
{
public:
    EditorChunkCache( Chunk & chunk );

    virtual void draw();
    virtual bool load( DataSectionPtr pSec, DataSectionPtr pCdata );
    virtual void bind( bool isUnbind );

    bool edSave();
    bool edSaveCData();

    bool edTransform( const Matrix & m, bool transient = false );
    bool edTransformClone( const Matrix & m );

    void edArrive( bool fromNowhere = false );
    void edDepart();

    void edEdit( class ChunkEditor & editor );
    bool edReadOnly() const;

    bool edCanDelete() const;
    void edPostUndelete();
    void edPreDelete();
    bool edIsDeleted() const { return deleted_; }

    void edPostClone(bool keepLinks = false);
    bool edIsLocked() const;
    bool edIsWriteable( bool bCheckSurroundings = true,
        ChunkNotWritableReason* retReason = NULL ) const; 

    EditorChunkModelPtr getShellModel() const;
    BW::vector<ChunkItemPtr> staticItems() const;
    void allItems( BW::vector<ChunkItemPtr> & items ) const;

    static Instance<EditorChunkCache> instance;
};
```

它额外提供了:

- **变换**:`edTransform` 改 chunk 的世界变换矩阵
- **生命周期**:`edArrive`/`edDepart`/`edPreDelete`/`edPostUndelete`/`edPostClone`
- **权限**:`edIsLocked`(bwlockd 锁)/`edIsWriteable`(可写性综合判断)
- **查询**:`getShellModel`(外壳模型)/`staticItems`(静态物体)/`allItems`(所有物体)

#### 16.12.4 ChunkSaver 与 CdataSaver

为了统一保存,common 库提供了两个保存器:

```cpp
// programming/bigworld/tools/common/editor_chunk_cache_base.hpp  L63-86
class ChunkSaver : public UnsavedChunks::IChunkSaver
{
    virtual bool save( Chunk* chunk )
    {
        return EditorChunkCacheBase::instance( *chunk ).edSave();
    }
    bool isDeleted( Chunk& chunk ) const { return false; }
};

class CdataSaver : public UnsavedChunks::IChunkSaver
{
    virtual bool save( Chunk* chunk )
    {
        return EditorChunkCacheBase::instance( *chunk ).edSaveCData();
    }
    bool isDeleted( Chunk& chunk ) const { return false; }
};
```

它们注册到 `UnsavedChunks` 系统,WorldManager 调用 `save()` 时,所有"脏" chunk 会按统一流程走保存。

### 16.13 EditorChunkItem 基类

#### 16.13.1 编辑器对 ChunkItem 的扩展要求

lib/chunk 的 `ChunkItemBase` 是场景物体的基类,但它只有运行时需要的接口(绘制、碰撞、toss)。编辑器还需要更多:**保存**、**变换**、**编辑属性**、**可锁定**、**可链接**……

`EditorChunkItem`(`lib/chunk/editor_chunk_item.hpp`)就是这层扩展:

```cpp
// programming/bigworld/lib/chunk/editor_chunk_item.hpp  L31-141
class EditorChunkItem : public ChunkItemBase, public EditorChunkCommonLoadSave
{
public:
    explicit EditorChunkItem( WantFlags wantFlags = WANTS_NOTHING );

    virtual void edMainThreadLoad() {}
    void edChunkBind();

    virtual bool edCommonSave( DataSectionPtr pSection );
    virtual bool edCommonLoad( DataSectionPtr pSection );
    virtual bool edCommonEdit( GeneralEditor& editor );
    virtual void edCommonChanged();

    virtual bool edSave( DataSectionPtr pSection ) { return false; }
    virtual void edChunkSave() {}
    virtual void edChunkSaveCData(DataSectionPtr cData) {}

    virtual const Matrix & edTransform() { return Matrix::identity; }
    virtual bool edTransform( const Matrix & m, bool transient = false );

    void edMove( Chunk* pOldChunk, Chunk* pNewChunk );
    virtual bool edIsTransient() { return transient_; }
    virtual bool edIsVLO() const { return false; }

    virtual void edBounds( BoundingBox & bbRet ) const { }
    virtual void edWorldBounds( BoundingBox & bbRet );

    virtual bool edIsEditable() const;          // 受 bwlockd 控制
    virtual bool edIsTooDistant();

    virtual Name edClassName();
    virtual Name edDescription();

    virtual bool edEdit( class GeneralEditor & editor );

    // ... 还有 edCommand / edExecuteCommand / edCalcDropChunk 等
};
```

> **命名约定**:BigWorld 编辑器代码里,所有"编辑器扩展"方法都以 `ed` 前缀开头(`edSave`/`edTransform`/`edBounds`/`edEdit`...)。这是和运行时方法(如 `draw`/`toss`/`tick`)区分的约定。

#### 16.13.2 关键方法解读

| 方法 | 作用 |
|------|------|
| `edMainThreadLoad()` | 在主线程加载(用于不能在后台线程做的事,如创建 D3D 资源) |
| `edChunkBind()` | chunk 绑定时调用,内部转调 `edMainThreadLoad` |
| `edSave(pSection)` | 保存到指定 DataSection |
| `edChunkSave()` | chunk 保存时调用,保存外部资源(如静态光照) |
| `edTransform(m, transient)` | 设置变换矩阵,`transient=true` 表示拖拽中(不入 UndoRedo) |
| `edMove(oldChunk, newChunk)` | 跨 chunk 移动 |
| `edBounds(bbRet)` | 本地包围盒 |
| `edWorldBounds(bbRet)` | 世界包围盒 |
| `edIsEditable()` | 是否可编辑(受 bwlockd 锁控制) |
| `edEdit(editor)` | 把属性加入 `GeneralEditor` 供属性页编辑 |

### 16.14 各种 EditorChunkItem 子类

`world/items/` 目录下有 20 多种 EditorChunkItem 子类,每种对应一类场景物体:

| 子类 | 文件 | 说明 |
|------|------|------|
| `EditorChunkModel` | `editor_chunk_model.*` | 静态模型(建筑、植被) |
| `EditorChunkEntity` | `editor_chunk_entity.*` | 实体(NPC、触发器) |
| `EditorChunkLight` | `editor_chunk_light.*` | 灯光(点光/聚光) |
| `EditorChunkParticleSystem` | `editor_chunk_particle_system.*` | 粒子系统 |
| `EditorChunkWater` | `editor_chunk_water.*` | 水位 |
| `EditorChunkStation` | `editor_chunk_station.*` | 传送点/站点 |
| `EditorChunkTree` | `editor_chunk_tree.*` | SpeedTree 树木 |
| `EditorChunkMarker` | `editor_chunk_marker.*` | 标记点 |
| `EditorChunkLink` | `editor_chunk_link.*` | 链接关系 |
| `EditorChunkPointLink` | `editor_chunk_point_link.*` | 点对点链接 |
| `EditorChunkPortal` | `editor_chunk_portal.*` | 门户 |
| `EditorChunkVLO` | `editor_chunk_vlo.*` | Very Large Object |
| `EditorChunkModelVLO` | `editor_chunk_model_vlo.*` | 模型 VLO |
| `EditorChunkUserDataObject` | `editor_chunk_user_data_object.*` | 用户数据对象 |
| `EditorChunkUserDataObjectLink` | `editor_chunk_user_data_object_link.*` | UDO 链接 |
| `EditorChunkDeferredDecal` | `editor_chunk_deferred_decal.*` | 延迟贴花 |
| `EditorChunkFlare` | `editor_chunk_flare.*` | 光晕 |
| `EditorChunkBinding` | `editor_chunk_binding.*` | 绑定 |
| `EditorChunkMetaData` | `editor_chunk_meta_data.*` | 元数据 |
| `EditorChunkMarkerCluster` | `editor_chunk_marker_cluster.*` | 标记簇 |

每种物体都继承 `EditorChunkItem`,实现自己的 `edSave`/`edTransform`/`edEdit`/`edBounds` 等。例如 `EditorChunkModel` 还额外处理静态光照烘焙,`EditorChunkLight` 处理光照影响范围。

---

## 第五部分:UndoRedo 撤销/重做系统

撤销/重做是编辑器的"灵魂功能"。设计师按 Ctrl+Z 的时候,世界必须精确地回到上一步状态。BigWorld 的 UndoRedo 系统在 `tools/common/undoredo.hpp`,采用经典的**命令模式**。

### 16.15 Operation 多态基类

`UndoRedo::Operation` 是所有可撤销操作的抽象基类:

```cpp
// programming/bigworld/tools/common/undoredo.hpp  L27-50
class Operation
{
public:
    Operation( int kind ) : kind_( kind ) { }
    virtual ~Operation() { }

    virtual void undo() = 0;

    bool operator==( const Operation & oth ) const
    {
        if (kind_ != oth.kind_ || !kind_) return false;
        return this->iseq( oth );
    };

    bool operator!=( const Operation & oth ) const
    {
        return !( *this == oth );
    }

    virtual bool iseq( const Operation & oth ) const = 0;

protected:
    int kind_;
};
```

关键设计点:

1. **`undo()` 是纯虚函数**:每个子类必须实现"如何撤销"
2. **`kind_` 是类型标识**:用 `int(typeid(*this).name())` 计算,用于判断两个 Operation 是否"同类"
3. **`iseq()` 判断"同一对象"**:同类且作用在同一数据上时返回 true,用于去重
4. **没有 `redo()`**:巧妙之处——redo 通过"反向 undo"实现(稍后详解)

#### 16.15.1 undo 没有 redo 的玄机

注意 `Operation` 只有 `undo()`,没有 `redo()`。这看起来很奇怪——怎么重做?

答案在 `UndoRedo::add()`:

```cpp
// programming/bigworld/tools/common/undoredo.hpp  L60-66
void add( Operation * op )
{
    if (!undoing_)
        this->addUndo( op );
    else
        this->addRedo( op );
}
```

`UndoRedo` 内部有个 `undoing_` 标志。正常编辑时 `undoing_=false`,`add` 把 Operation 加到 undo 栈。执行 `undo()` 时 `undoing_=true`,此时 `Operation::undo()` 内部若再调用 `add`,就会把"反向操作"加到 redo 栈。

也就是说:**undo 操作本身也会产生 undo 操作,只是它被加到了 redo 栈**。这样就不必为每种 Operation 写两份代码(undo + redo),一份 undo 就够了。

### 16.16 Barrier 批量操作

#### 16.16.1 Barrier 的概念

单个用户动作往往涉及多个 Operation。比如"移动一个物体"会改变它的变换矩阵、可能跨 chunk、还要更新链接关系——这些都要入 UndoRedo。但用户按 Ctrl+Z 时,希望**一次性**全部回退,而不是按 Operation 逐个回退。

`Barrier` 就是这个"批量单位":

```cpp
// programming/bigworld/tools/common/undoredo.hpp  L95-105
class Barrier : public ReferenceCount
{
public:
    ~Barrier();

    BW::string  what_;   // 描述(显示在 Undo 菜单)
    Operations  ops_;    // 该 barrier 内的所有 Operation
};

typedef SmartPointer<Barrier> BarrierPtr;
typedef BW::vector<BarrierPtr> Barriers;
```

`UndoRedo` 维护两个栈:

```cpp
// programming/bigworld/tools/common/undoredo.hpp  L107-110
Barriers    undoList_;  // back 是当前正在累积的 barrier
Barriers    redoList_;  // back 是下一次要 redo 的 barrier
bool        undoing_;
```

#### 16.16.2 barrier 方法

```cpp
// programming/bigworld/tools/common/undoredo.hpp  L71
void barrier( const BW::string & what, bool skipIfNoChange );
```

调用 `barrier("移动物体", false)` 表示"这一组操作结束了"。源码实现:

```cpp
// programming/bigworld/tools/common/undoredo.cpp  L169-185
void UndoRedo::barrier( const BW::string & what, bool skipIfNoChange )
{
    MF_ASSERT( !undoing_ );

    // 关闭 barrier 意味着继续前进,丢弃所有 redo
    this->clearRedos();

    if (undoList_.back()->ops_.empty())
    {
        if (skipIfNoChange) return;   // 没改动就跳过

        WARNING_MSG( "UndoRedo::barrier: Barrier closed for '%s'"
            "' but no intermediate operations added!\n", what.c_str() );
    }

    this->barrierInternal( what );
}
```

#### 16.16.3 典型使用模式

```cpp
// 1. 开始一组操作(隐式:UndoRedo 构造时已有一个空 barrier)

// 2. 在操作过程中,每个改动都 add 一个 Operation
UndoRedo::instance().add( new ChunkMatrixOperation(pChunk, oldMatrix) );
UndoRedo::instance().add( new ChunkExistenceOperation(pChunk, true) );
// ... 还可能有更多

// 3. 结束这一组
UndoRedo::instance().barrier( "Move Object", false );
```

之后用户按 Ctrl+Z,`UndoRedo::undo()` 会把这组 Operation **逆序**执行:

```cpp
// programming/bigworld/tools/common/undoredo.cpp  L97-130
void UndoRedo::undo()
{
    MF_ASSERT( !undoing_ );
    MF_ASSERT( undoList_.back()->ops_.empty() );  // 当前 barrier 已关闭

    if (undoList_.size() == 1) return;   // 只剩空 barrier,无可撤销

    undoing_ = true;

    // 弹出最后一个 barrier
    undoList_.pop_back();

    // 在 redo 栈上开一个新 barrier
    redoList_.push_back( new Barrier() );
    redoList_.back()->what_ = undoList_.back()->what_;

    // 逆序执行所有 Operation
    Operations & ops = undoList_.back()->ops_;
    for (Operations::reverse_iterator rit = ops.rbegin(); rit != ops.rend(); rit++)
    {
        (*rit)->undo();   // 内部的 add 会把反向操作加到 redo 栈
    }

    // 清空这个 barrier
    undoList_.back() = new Barrier();

    undoing_ = false;
}
```

> **新手提示**:`reverse_iterator` 是关键——一组操作是 A→B→C,撤销时要 C→B→A,否则会破坏不变量。

### 16.17 各种 Operation 实现

`tools/worldeditor/undo_redo/` 目录下有十几种 Operation 实现:

| Operation | 文件 | 用途 |
|-----------|------|------|
| `ChunkMatrixOperation` | `world/editor_chunk_cache.hpp` | chunk 变换矩阵 |
| `ChunkExistenceOperation` | `world/editor_chunk_cache.hpp` | chunk 存在性(创建/删除) |
| `TerrainHeightMapUndo` | `undo_redo/terrain_height_map_undo.*` | 地形高度图 |
| `TerrainHoleMapUndo` | `undo_redo/terrain_hole_map_undo.*` | 地形洞口图 |
| `TerrainTextureLayerUndo` | `undo_redo/terrain_texture_layer_undo.*` | 地形纹理层 |
| `TerrainTexProjUndo` | `undo_redo/terrain_tex_proj_undo.*` | 地形纹理投影 |
| `ElevationUndo` | `undo_redo/elevation_undo.*` | 高程导入 |
| `EntityArrayUndo` | `undo_redo/entity_array_undo.*` | 实体数组 |
| `StationLinkOperation` | `undo_redo/station_link_operation.*` | 站点链接 |
| `StationEntityLinkOperation` | `undo_redo/station_entity_link_operation.*` | 站点-实体链接 |
| `UserDataObjectLinkOperation` | `undo_redo/user_data_object_link_operation.*` | UDO 链接 |
| `EntityUserDataObjectLinkOperation` | `undo_redo/entity_user_data_object_link_operation.*` | 实体-UDO 链接 |
| `LinkerOperations` | `undo_redo/linker_operations.*` | 链接器通用操作 |
| `MergeGraphsOperation` | `undo_redo/merge_graphs_operation.*` | 图合并 |
| `ToolChangeOperation` | `undo_redo/tool_change_operation.*` | 工具切换 |
| `SelectionOperation` | `world/world_manager.cpp:620` | 选择变化 |

举两个典型例子:

#### 16.17.1 TerrainHeightMapUndo

地形高度图的撤销,保存压缩后的高度数据:

```cpp
// programming/bigworld/tools/worldeditor/undo_redo/terrain_height_map_undo.hpp  L18-31
class TerrainHeightMapUndo : public UndoRedo::Operation
{
public:
    TerrainHeightMapUndo(Terrain::EditorBaseTerrainBlockPtr block, ChunkPtr chunk);

    virtual void undo();
    virtual bool iseq( const UndoRedo::Operation & oth ) const;

private:
    Terrain::EditorBaseTerrainBlockPtr  block_;
    ChunkPtr                            chunk_;
    BinaryPtr                           heightsCompressed_;   // 压缩的高度数据
};
```

`undo()` 时把 `heightsCompressed_` 解压回 `block_`。压缩是为了节省内存——一张高度图可能上百 KB,而 UndoRedo 栈可能保留几十步。

#### 16.17.2 ChunkExistenceOperation

chunk 创建/删除的撤销:

```cpp
// programming/bigworld/tools/worldeditor/world/editor_chunk_cache.hpp  L197-215
class ChunkExistenceOperation : public UndoRedo::Operation
{
public:
    ChunkExistenceOperation( Chunk * pChunk, bool create ) :
        UndoRedo::Operation( 0 ),
        pChunk_( pChunk ),
        create_( create )
    {
        addChunk( pChunk );
    }

private:
    virtual void undo();
    virtual bool iseq( const UndoRedo::Operation & oth ) const;

    Chunk *  pChunk_;
    bool     create_;
};
```

注意 `kind_` 传的是 `0`——这会让 `operator==` 直接返回 false,意味着这类操作不去重(每次创建/删除都入栈)。

---

## 第六部分:bwlockd 多人协作

### 16.18 BWLockDConnection 连接

bwlockd 是 BigWorld 的**锁定守护进程**。多人协作编辑同一个空间时,它负责分配"谁可以改哪些 chunk",防止冲突。

WorldEditor 通过 `BWLock::BWLockDConnection`(common 库)连接 bwlockd:

```cpp
// programming/bigworld/tools/common/bwlockd_connection.hpp  L109-193
class BWLockDConnection
{
public:
    class Notification
    {
    public:
        virtual ~Notification(){}
        virtual void changed() = 0;
    };

    BWLockDConnection();

    void registerNotification( Notification* n );

    bool init( const BW::string& hoststr, const BW::string& username,
               int xExtent, int zExtent );
    bool connect();
    bool changeSpace( BW::string newSpace );
    void disconnect();

    bool lock( const GridRect& rect, const BW::string description );
    void unlock( Rect rect, const BW::string description );

    bool isWritableByMe( int16 x, int16 z ) const;
    bool isLockedByMe( int16 x, int16 z ) const;
    bool isLockedByOthers( int16 x, int16 z ) const;
    bool isSameLock( int16 x1, int16 z1, int16 x2, int16 z2 ) const;

    GridInfo getGridInformation( int16 x, int16 z ) const;
    BW::set<Rect> getLockRects( int16 x, int16 z ) const;

    bool tick();   // 轮询,返回 true 表示锁状态有更新

    BW::vector<unsigned char> getLockData( int minX, int minY,
        unsigned int gridWidth, unsigned int gridHeight );
    BW::string host() const;
    // ...
};
```

#### 16.18.1 初始化

`WorldManager::init` 中初始化 bwlockd 连接:

```cpp
// programming/bigworld/tools/worldeditor/world/world_manager.cpp  L2184-2197
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

如果用户没配置 `bwlockd/username`,就用 Windows 系统当前登录用户名兜底。

#### 16.18.2 协议

bwlockd 用简单的 TCP 协议,定义在 `bwlockd_connection.cpp:25-31`:

```cpp
// programming/bigworld/tools/common/bwlockd_connection.cpp  L25-31
const unsigned char BWLOCKCOMMAND_INVALID = 0;
const unsigned char BWLOCKCOMMAND_CONNECT = 'C';
const unsigned char BWLOCKCOMMAND_SETUSER = 'A';
const unsigned char BWLOCKCOMMAND_SETSPACE = 'S';
const unsigned char BWLOCKCOMMAND_LOCK = 'L';
const unsigned char BWLOCKCOMMAND_UNLOCK = 'U';
const unsigned char BWLOCKCOMMAND_GETSTATUS = 'G';
```

每个命令是定长头 + 变长体的二进制结构,例如锁命令:

```cpp
// programming/bigworld/tools/common/bwlockd_connection.cpp  L82-99
struct LockCommand : public Command
{
    short left_;
    short top_;
    short right_;
    short bottom_;
    char desc_[ BWLOCK_MAX_DESCRIPTION_LENGTH + 1 ];
    LockCommand( short left, short top, short right, short bottom, const BW::string& desc )
        : Command( BWLOCKCOMMAND_LOCK ), left_( left ), top_( top ),
          right_( right ), bottom_( bottom )
    { /* strncpy desc_ ... */ }
};
```

`#pragma pack(push, 1)` 保证结构紧凑无填充,跨机器二进制兼容。

### 16.19 锁粒度与四种状态

#### 16.19.1 网格级锁

bwlockd 的锁粒度是**网格(Grid)**,不是单个 chunk。一个网格通常对应一个 chunk,但锁可以一次覆盖多个网格(矩形):

```cpp
// programming/bigworld/tools/common/bwlockd_connection.hpp  L38-83
struct Rect
{
    short left_;
    short top_;
    short right_;
    short bottom_;
    // ... in() / intersect() / operator< 等
};

struct Lock
{
    Rect rect_;
    BW::string username_;
    BW::string desc_;
    float time_;
};

struct Computer
{
    BW::string name_;
    BW::vector<Lock> locks_;
};
```

`Computer` 表示一台电脑持有的所有锁。bwlockd 服务端维护所有电脑的锁列表,客户端通过 `tick()` 轮询更新本地缓存。

#### 16.19.2 四种状态

每个网格有四种状态(`bwlockd_connection.hpp:24-36`):

```cpp
// programming/bigworld/tools/common/bwlockd_connection.hpp  L24-36
enum GridStatus
{
    GS_NOT_LOCKED = 0,        // 无人锁定
    GS_LOCKED_BY_ME,          // 我锁定但不可编辑
    GS_LOCKED_BY_OTHERS,      // 他人锁定
    GS_WRITABLE_BY_ME,        // 我锁定且可编辑
    GS_MAX
};
```

| 状态 | 含义 | 可编辑 |
|------|------|--------|
| `GS_NOT_LOCKED` | 无人锁定 | 否 |
| `GS_LOCKED_BY_ME` | 我锁定但不可编辑(过渡态) | 否 |
| `GS_LOCKED_BY_OTHERS` | 他人锁定 | 否 |
| `GS_WRITABLE_BY_ME` | 我锁定且可编辑 | **是** |

只有 `GS_WRITABLE_BY_ME` 才允许写入。`GS_LOCKED_BY_ME` 是"我申请了锁但还没拿到可写权"的过渡态。

#### 16.19.3 状态查询

```cpp
bool isWritableByMe( int16 x, int16 z ) const;       // 是否我可写
bool isLockedByMe( int16 x, int16 z ) const;          // 是否我锁的(含不可写)
bool isLockedByOthers( int16 x, int16 z ) const;      // 是否他人锁的
bool isSameLock( int16 x1, int16 z1, int16 x2, int16 z2 ) const;  // 两个网格是否同一把锁
```

`WorldManager::isChunkWritable` 最终转调到 `BWLockDConnection::isWritableByMe`:

```cpp
// programming/bigworld/tools/worldeditor/world/world_manager.hpp  L133-134
bool isChunkWritable( Chunk* chunk ) const;
bool isChunkEditable( Chunk* pChunk ) const;
```

### 16.20 协作编辑流程

协作编辑的完整流程由 `ProjectModule`(`project/project_module.*`)驱动:

```
┌──────────────┐
│ 设计师 A      │
│ 打开 Space   │
└──────┬───────┘
       │ changeSpace(space)
       ▼
┌──────────────────────────────────┐
│ bwlockd 服务端                   │
│ - 记录 A 进入 space              │
│ - 返回当前所有锁状态             │
└──────────────────────────────────┘
       │ A 框选区域 → lockSelection
       ▼
┌──────────────────────────────────┐
│ A 申请锁 [x1,z1]-[x2,z2]        │
│ bwlockd 检查无冲突 → 批准        │
│ 该区域变为 GS_WRITABLE_BY_ME     │
└──────────────────────────────────┘
       │ A 编辑 → 保存
       ▼
┌──────────────────────────────────┐
│ A: commitDone()                  │
│ - 提交锁内 chunk 到源码控制      │
│ - unlock 释放锁                  │
└──────────────────────────────────┘

┌──────────────┐
│ 设计师 B      │
│ 同时打开 Space│
└──────┬───────┘
       │ tick() 轮询
       ▼
   发现 A 锁的区域 → 在 B 视图里标红
   B 无法编辑该区域(isWritableByMe=false)
```

#### 16.20.1 ProjectModule 的角色

`ProjectModule`(`project/project_module.hpp:20`)继承 `FrameworkModule`,是空间锁定/提交的入口模块:

```cpp
// programming/bigworld/tools/worldeditor/project/project_module.hpp  L20
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
};
```

它提供俯视视角,设计师在地图上框选区域,然后 `lockSelection` 申请锁。提交时调 `commitDone` 放弃锁。

#### 16.20.2 锁可视化

`EditorChunkLockVisualizer`(`world/editor_chunk_lock_visualizer.*`)负责把锁状态画到 3D 视口里——他人锁的区域用红色边框,自己锁的用绿色,让设计师一眼看清边界。

---

## 第七部分:AssetClient 资源管线集成

### 16.21 资源管线接入

WorldEditor 编辑的物体(模型、纹理、特效)最终要被客户端使用,中间需要经过**资产管线**编译(模型压缩、纹理转换、LOD 生成等)。BigWorld 的资产管线由 `asset_pipeline` 库 + `jit_compiler` 守护进程组成(详见第 15 章)。

WorldEditor 通过 `AssetClient` 接入资产管线。初始化时:

```cpp
// programming/bigworld/tools/worldeditor/framework/initialisation.cpp  L87-88
s_pAssetClient_.reset( new AssetClient() );
s_pAssetClient_->waitForConnection();   // 阻塞等待连接
```

`waitForConnection` 是阻塞调用——如果连不上 jit_compiler,WorldEditor 就不启动。这保证了后续编辑过程中,任何资源改动都能被资产管线感知。

#### 16.21.1 为什么必须等连接?

如果允许"离线编辑",设计师改了模型,但 jit_compiler 没在跑,这个改动就不会被编译。等设计师保存并尝试预览时,看到的还是旧资源,会非常困惑。所以 BigWorld 选择**强制要求**资产管线在线,从根上避免这种问题。

### 16.22 实时编译通知

#### 16.22.1 changedChunk 触发重新编译

当 chunk 被修改后,`WorldManager::changedChunk` 会被调用:

```cpp
// programming/bigworld/tools/worldeditor/world/world_manager.hpp  L138-153
virtual void changedChunk( Chunk* pPrimaryChunk,
                    InvalidateFlags flags = InvalidateFlags::FLAG_THUMBNAIL );
virtual void changedChunks( BW::set<Chunk*>& primaryChunks,
                    InvalidateFlags flags = InvalidateFlags::FLAG_THUMBNAIL );

virtual void changedChunk( Chunk* pPrimaryChunk,
                    EditorChunkItem& changedItem );
```

`InvalidateFlags` 控制要刷新哪些派生数据:

- `FLAG_THUMBNAIL`:重算缩略图
- `FLAG_LOD`:重建 LOD
- `FLAG_SHADOW`:重算阴影
- `FLAG_NAVMESH`:重建导航网格
- `FLAG_TERRAIN`:地形相关

这些派生数据的重算会通过 `ChunkProcessorManager` 派发到后台线程,部分任务最终会触发 AssetClient 通知 jit_compiler 重新编译关联资源。

#### 16.22.2 ResourceLoader 预编译特效

启动时还有一步特效预编译:

```cpp
// programming/bigworld/tools/worldeditor/world/world_manager.cpp  L2224-2232
if ( Options::getOptionInt( "precompileEffects", 1 ) )
{
    BW::vector<ISplashVisibilityControl*> SVCs;
    if ( CSplashDlg::getSVC() ) SVCs.push_back(CSplashDlg::getSVC());
    if (WaitDlg::getSVC()) SVCs.push_back(WaitDlg::getSVC());
    ResourceLoader::instance().precompileEffects( SVCs );
}
```

这会在启动画面下编译所有 shader,避免编辑时第一次使用某个 shader 卡顿。

---

## 第八部分:编辑器工具集

### 16.23 Tool 框架

WorldEditor 的"工具"(选择、移动、旋转、缩放、画地形……)都基于 `Tool` 基类(`lib/gizmo/tool.hpp`):

```cpp
// programming/bigworld/lib/gizmo/tool.hpp  L72-164
class Tool : public InputHandler, public PyObjectPlus
{
    Py_Header( Tool, PyObjectPlus )

public:
    Tool( ToolLocatorPtr locator,
        ToolViewPtr view,
        ToolFunctorPtr functor,
        PyTypeObject * pType = &s_type_ );

    virtual void onPush();
    virtual void onPop();
    virtual void onBeginUsing();
    virtual void onEndUsing();

    virtual void size( float s );
    virtual float size() const;
    virtual void strength( float s );
    virtual float strength() const;

    virtual const ToolLocatorPtr locator() const;
    virtual void locator( ToolLocatorPtr spl );

    virtual const ToolViewPtrs& view() const;
    virtual ToolFunctorPtr functor() const;

    virtual ChunkPtrVector& relevantChunks();
    virtual ChunkPtr& currentChunk();

    virtual void calculatePosition( const Vector3& worldRay );
    virtual void update( float dTime );
    virtual void render( Moo::DrawContext& drawContext );
    virtual bool handleKeyEvent( const KeyEvent & event );
    virtual bool handleMouseEvent( const MouseEvent & event );
    // ...
};
```

#### 16.23.1 三大组件

`Tool` 是三个组件的组合:

1. **ToolLocator**:计算"鼠标在世界哪里"——比如投射射线到地形/物体,得到 3D 位置
2. **ToolView**:画工具的视觉表现——比如移动工具的三色箭头
3. **ToolFunctor**:处理"工具应用时做什么"——比如移动工具拖动时改变换矩阵

这是**策略模式**:同一个 Tool 框架,换不同 Locator/View/Functor 组合,就能得到完全不同的工具。

#### 16.23.2 ToolList 析构顺序

```cpp
// programming/bigworld/lib/gizmo/tool.hpp  L48-63
class ToolList
{
public:
    static void clearAll();
private:
    friend class Tool;
    static void add( Tool* tool );
    static void remove( Tool* tool );
    static BW::vector<Tool*> s_toolList_;
};
```

源码注释解释了这个类存在的原因:

> This was originally created to solve a problem with order of destruction in WorldEditor. Because a Tool holds references to external objects it was delaying the destruction of these objects until scripting was destroyed. These objects had rendering resources associated with them and need to be destroyed before ChunkManager is destroyed.

也就是说,Tool 持有外部对象的引用,会拖延析构。`ToolList::clearAll()` 在 `WorldManager::fini` 中提前调用,强制释放所有 Tool 的引用。

### 16.24 各种特化工具

WorldEditor 的工具在 `resources/data/gui.xml` 和 Python 脚本里声明,通过 `ToolManager` 切换。常见工具有:

| 工具 | Locator | View | Functor | 用途 |
|------|---------|------|--------|------|
| **SelectionTool** | 射线投射 | 高亮框 | 选择物体 | 点选/框选 |
| **MoveTool** | 当前选中 | 三色箭头 | 改 transform 的 translation | 移动物体 |
| **RotateTool** | 当前选中 | 三色圆环 | 改 transform 的 rotation | 旋转物体 |
| **ScaleTool** | 当前选中 | 缩放手柄 | 改 transform 的 scale | 缩放物体 |
| **ChunkPlacer** | 网格对齐 | 虚影预览 | 放置 chunk | 放 shell 模型 |
| **ChunkItemPlacer** | 物体表面 | 物体虚影 | 放置 chunk item | 放物体 |
| **TerrainHeightTool** | 地形表面 | 笔刷圆圈 | 抬升/降低高度 | 雕刻地形 |
| **TerrainTextureTool** | 地形表面 | 笔刷圆圈 | 画纹理层 | 画地表纹理 |
| **TerrainHoleTool** | 地形表面 | 笔刷圆圈 | 挖洞 | 做洞穴 |
| **LinkGizmo** | 物体表面 | 连接线 | 建立链接 | 连传送点等 |

每种工具都通过 Python 脚本组合 Locator/View/Functor,不必写 C++。这是 BigWorld 工具链"脚本化"的体现。

> **新手提示**:工具切换本身也是可撤销的——`ToolChangeOperation`(`undo_redo/tool_change_operation.*`)记录切换前的工具,撤销时切回去。

---

## 第九部分:common 与 editor_shared 库

WorldEditor 不只是 `tools/worldeditor/` 一个目录,它还依赖两个公共库:`tools/common` 和 `tools/editor_shared`。

### 16.25 tools_common 公共库

`tools/common/` 构建为 `tools_common` 静态库,是 WorldEditor、ModelEditor 等工具的**公共基础库**。约 80 个源文件,主要分组:

| 分组 | 代表文件 | 说明 |
|------|---------|------|
| 撤销/重做 | `undoredo.hpp/.cpp/.ipp`、`undo.h` | 新旧两套系统 |
| 协作锁 | `bwlockd_connection.hpp/.cpp` | bwlockd TCP 连接 |
| Chunk 缓存 | `editor_chunk_cache_base.hpp/.cpp`、`editor_chunk_processor_cache.hpp/.cpp` | 编辑器 chunk 扩展 |
| 空间编辑 | `space_editor.hpp` | 回调接口 |
| 环境管理 | `romp_harness.hpp/.cpp` | RompHarness |
| 相机 | `base_camera.hpp/.ipp`、`orbit_camera.hpp`、`mouse_look_camera.hpp`、`orthographic_camera.hpp`、`tools_camera.hpp` | 各类相机 |
| 材质 | `material_*.hpp/.cpp` | 材质编辑 |
| 属性 | `*_properties_helper.hpp/.cpp`、`property_list.hpp`、`property_table.hpp` | 属性表 |
| 导航 | `navmesh_processor.hpp/.cpp`、`recast_processor.hpp/.cpp` | 导航网格 |
| 地形 | `editor_chunk_terrain_*.hpp/.cpp`、`terrain_shadow_processor.hpp/.cpp` | 地形处理 |

#### 16.25.1 SpaceEditor 单例注入

`SpaceEditor` 是个抽象基类,提供 chunk 变更的回调:

```cpp
// programming/bigworld/tools/common/space_editor.hpp  L18-60
class SpaceEditor
{
public:
    virtual ~SpaceEditor() {}

    virtual void changedChunk( Chunk* pPrimaryChunk, 
        InvalidateFlags flags = InvalidateFlags::FLAG_THUMBNAIL ) {}
    virtual void changedChunks( BW::set<Chunk*>& primaryChunks,
        InvalidateFlags flags = InvalidateFlags::FLAG_THUMBNAIL ) {}

    virtual void changedChunk( Chunk* pPrimaryChunk, 
        EditorChunkItem& changedItem ) {}
    // ... 还有几个重载

    virtual void addError( Chunk* chunk, ChunkItem* item, const char * format, ... ) {};
    virtual void onDeleteVLO( const BW::string& id ) {};
    virtual bool isChunkWritable( Chunk* chunk ) const { return true; };

    static SpaceEditor& instance( SpaceEditor* editor = NULL )
    {
        static SpaceEditor* s_editor = NULL;
        if (editor)
        {
            // Used in WE passed with WorldManager instance
            s_editor = editor;
        }
        MF_ASSERT( s_editor );
        return *s_editor;
    }
};
```

这是"单例注入"模式:`WorldManager` 构造时调 `SpaceEditor::instance(this)` 把自己注入,之后 common 库的代码通过 `SpaceEditor::instance()` 拿到 WorldManager 的实现,但不必依赖 WorldManager 这个具体类。

#### 16.25.2 新旧 Undo 系统并存

`tools/common/` 里有**两套**撤销系统:

- **新式**:`undoredo.hpp/.cpp`,即本章第五部分讲的 Operation/Barrier
- **旧式**:`undo.h`(141 行),C 风格 AnsiString + TAction 模板

旧式是历史遗留,部分老代码还在用。BigWorld 没有彻底替换,而是让两套并存——这是大型项目演进中常见的折中。

### 16.26 editor_shared GUI 抽象层

`tools/editor_shared/` 是**GUI 后端抽象层**,通过抽象接口隔离工具逻辑与具体 GUI 后端(MFC/Qt)。

#### 16.26.1 抽象接口

```cpp
// programming/bigworld/tools/editor_shared/app/i_editor_app.hpp  L8-14
class IEditorApp
{
public:
    virtual bool isMinimized();
    virtual void onIdle() {};
};
```

```cpp
// programming/bigworld/tools/editor_shared/gui/i_main_frame.hpp  L17-35
class IMainFrame
{
public:
    virtual ~IMainFrame() {}

    virtual GLView * getEditorView() { return NULL; }
    virtual GUI::IMenuHelper * getMenuHelper() { return NULL;}

    virtual void setMessageText( const wchar_t * pText ) = 0;
    virtual void setStatusText( UINT id, const wchar_t * text ) = 0;
    virtual bool cursorOverGraphicsWnd() const = 0;
    virtual void updateGUI( bool force = false ) = 0;
    virtual Vector2 currentCursorPosition() const = 0;
    virtual Vector3 getWorldRay(int x, int y) const = 0;
    virtual void grabFocus() = 0;

    virtual void * getNativePointer() { return NULL; }
};
```

#### 16.26.2 双后端架构

```
┌──────────────────── 抽象层(头文件,后端无关) ──────────────┐
│  app/i_editor_app.hpp      (IEditorApp)                    │
│  gui/i_main_frame.hpp      (IMainFrame)                    │
│  cursor/cursor.hpp         (Cursor)                        │
│  cursor/wait_cursor.hpp    (WaitCursor)                    │
│  dialogs/file_dialog.hpp   (BWFileDialog)                  │
│  dialogs/folder_guard.hpp  (FolderSetter/FolderGuard)      │
│  dialogs/message_box.hpp   (MessageBox)                    │
└────────────────────────────────────────────────────────────┘
                              │
              ┌───────────────┴───────────────┐
              │  BW_IS_QT_TOOLS CMake 选项    │
              └───────────────┬───────────────┘
       ┌──────────────────────┴──────────────────────┐
       ▼                                             ▼
  ┌────────────────────────┐         ┌────────────────────────┐
  │  MFC 后端实现(完整)   │         │  QT 后端实现(不完整) │
  │  mfc/app/i_editor_app  │         │  仅 menu_helper 复用   │
  │  mfc/cursor/*          │         │  其余缺失              │
  │  mfc/dialogs/*         │         │                        │
  │  mfc/menu_helper.*     │         │                        │
  └────────────────────────┘         └────────────────────────┘
```

`CMakeLists.txt` 根据 `BW_IS_QT_TOOLS` 选项选择后端:

```cmake
# programming/bigworld/tools/editor_shared/CMakeLists.txt  L16-20
IF( BW_IS_QT_TOOLS )
    INCLUDE( "CMakeLists.qt.txt" )
ELSE()
    INCLUDE( "CMakeLists.mfc.txt" )
ENDIF()
```

实际生产用的是 MFC 后端,Qt 后端只有 `menu_helper` 一个文件,远未完成。

#### 16.26.3 RAII 工具类

editor_shared 提供了几个 RAII 守卫,值得学习:

- **`WaitCursor`**:`ScopeGuard` 风格,构造时设置等待光标,析构时恢复
- **`FolderGuard`**:文件对话框内嵌,确保对话框不污染调用方当前目录
- **`FolderSetter`**:显式设置/恢复当前目录

这些小工具虽然简单,但极大降低了资源管理的出错概率。

---

## 第十部分:特色实现深度剖析

### 16.27 WorldManager God Object 设计权衡

#### 16.27.1 反模式的代价

我们已经看到 `WorldManager` 是 9 重继承的 God Object。现在来诚实评估它的代价:

| 代价 | 具体表现 |
|------|---------|
| **认知负担** | 新人要理解整个类才能改一处,6700 行的 .cpp 不是闹着玩的 |
| **测试困难** | 无法单独测试"选择"逻辑,因为它和渲染、保存、UndoRedo 纠缠在一起 |
| **修改风险** | 改一个成员变量可能影响多个职责,回归测试范围大 |
| **编译时间** | 改 world_manager.hpp 几乎触发整个项目重编译 |
| **多人冲突** | 多人同时改 WorldManager 时 git 合并冲突频繁 |

#### 16.27.2 务实的好处

但 BigWorld 选择这条路,也有充分的理由:

| 好处 | 说明 |
|------|------|
| **调用便利** | `WorldManager::instance().xxx()` 一行搞定,不用传 5 个指针 |
| **避免循环依赖** | 把相关职责放一起,模块间不会形成环 |
| **状态一致** | 所有状态在一个对象,不变量维护集中 |
| **演进成本低** | 加新功能时,直接在 WorldManager 加方法即可,不必设计新接口 |
| **历史包袱** | 从早期版本演进,拆分成本远超收益 |

#### 16.27.3 缓解措施

BigWorld 采取了几个措施缓解 God Object 的副作用:

1. **拆分部分职责**:`EditorChunkItemLinkerManager`(81864 字符)、`VloManager`、`ItemInfoDB` 等被拆成独立类
2. **抽象基类**:`SpaceEditor` 抽象出"空间编辑回调"接口,让 common 库不依赖具体实现
3. **RAII 守卫**:`ScopedDeferSelectionReplacement`、`ScopedSelectionFilter` 等把状态管理封装
4. **多线程分时**:`ChunkProcessorManager` 把后台处理委托给线程池
5. **Python 暴露**:UI 行为通过 Python 脚本定制,减少 C++ 改动

> **新手启示**:在阅读大型遗留代码时,不要急于批判"反模式"。理解它**为什么**这样设计,往往比抽象的"最佳实践"更有价值。God Object 在编辑器领域很常见(Photoshop、Maya 的核心类都是巨型对象),它不是"错",而是一种工程权衡。

### 16.28 UndoRedo 命令模式剖析

#### 16.28.1 经典命令模式

BigWorld 的 UndoRedo 是教科书级的**命令模式(Command Pattern)**:

- **Command** = `UndoRedo::Operation`
- **Invoker** = `UndoRedo` 单例
- **Receiver** = chunk/item/terrain 等被编辑的对象
- **Client** = 编辑器代码(创建 Operation 并 `add`)

每个用户动作封装成一个 Operation 对象,记录"如何撤销"。这样:

1. **撤销/重做逻辑局部化**:每种 Operation 自己知道怎么 undo,不污染被编辑对象
2. **可组合**:多个 Operation 组成一个 Barrier,对应一个用户动作
3. **可序列化**(理论上):虽然 BigWorld 没做,但 Operation 可以扩展为支持序列化,实现跨会话撤销

#### 16.28.2 "undo 产生 undo" 的精妙

最精妙的设计是:**Operation 只有 `undo()`,没有 `redo()`**。

正常编辑时,Operation 进入 undo 栈。执行 `UndoRedo::undo()` 时,`undoing_=true`,此时 `Operation::undo()` 内部若再调用 `add`,会进入 redo 栈。这个"再调用 add"是怎么发生的?

看一个典型 Operation 的 undo 实现(伪代码):

```cpp
void ChunkMatrixOperation::undo()
{
    // 1. 记录当前矩阵,作为 redo 的依据
    Matrix current = pChunk_->transform();
    UndoRedo::instance().add( new ChunkMatrixOperation(pChunk_, current) );
    
    // 2. 恢复到 oldPose_
    pChunk_->transform( oldPose_ );
}
```

关键在于第 1 步:**undo 自己也会 add 一个新的 Operation**(记录当前状态,以便 redo 时恢复)。由于 `undoing_=true`,这个 add 进入 redo 栈。

这样:

- 用户做 A → undo 栈:[A]
- 用户 undo → redo 栈:[A'],A' 记录了 undo 前的状态
- 用户 redo → 执行 A'.undo(),又 add 一个 A'' 到 undo 栈 → undo 栈:[A'']

每个 Operation 只需实现"如何撤销",redo 自动由"undo 的 undo"完成。**省了一半代码**。

#### 16.28.3 去重优化

`addUndo` 里有去重逻辑:

```cpp
// programming/bigworld/tools/common/undoredo.cpp  L55-77
void UndoRedo::addUndo( Operation * op )
{
    Operations & ops = undoList_.back()->ops_;
    for (Operations::iterator it = ops.begin(); it != ops.end(); it++)
    {
        if (*op == **it)
        {
            // 已有同类操作作用在同一对象,保留原始的(它记录了最初的值)
            delete op;
            return;
        }
    }
    ops.push_back( op );
}
```

比如连续拖动一个物体,每帧都 add 一个 `ChunkMatrixOperation`,但只有**第一个**会被保留——它记录的是拖动前的位置,后续的都是中间状态,没必要全留。这避免了 UndoRedo 栈被高频操作撑爆。

> 注释里诚实地承认了潜在问题:
> ```
> I acknowledge a possible problem here when we undo
> if ops between **it and *op depend on the changes made by *op ...
> but this can be avoided by not mixing different kinds of operations
> (when they don't compound) within the same set.
> ```
> 也就是:别在同一 Barrier 里混用不同类型的不可叠加操作。

### 16.29 bwlockd 多人协作剖析

#### 16.29.1 为什么需要锁服务器?

考虑这个场景:

```
设计师 A 在 (10, 5) 放了一个房子,保存
设计师 B 同时在 (10, 5) 删了那个房子,保存
→ 冲突!最后一次保存的覆盖前一次
```

源码控制(如 git)能合并文本文件,但 chunk 是二进制/复杂 XML,无法自动合并。所以 BigWorld 选择**悲观锁**:编辑前必须先锁定,锁住的区域别人不能改。

#### 16.29.2 协议设计

bwlockd 的协议很简单,6 个命令:

| 命令 | 字符 | 用途 |
|------|------|------|
| `CONNECT` | 'C' | 建立连接 |
| `SETUSER` | 'A' | 设置用户名 |
| `SETSPACE` | 'S' | 切换空间 |
| `LOCK` | 'L' | 锁定矩形区域 |
| `UNLOCK` | 'U' | 解锁矩形区域 |
| `GETSTATUS` | 'G' | 查询全状态 |

所有命令共用一个头:

```cpp
// programming/bigworld/tools/common/bwlockd_connection.cpp  L42-49
struct Command
{
    unsigned int size_;
    unsigned char id_;
    unsigned char flag_;
    Command( unsigned char id ) : id_( id ), flag_( 0 ), size_( 0xffffffff )
    {}
};
```

`#pragma pack(push, 1)` 保证紧凑。这种"定长头 + 变长体"的二进制协议,比 JSON/protobuf 轻量得多,适合高频调用。

#### 16.29.3 客户端缓存

`BWLockDConnection` 不每次查询都走网络,而是维护本地缓存:

```cpp
// programming/bigworld/tools/common/bwlockd_connection.hpp  L192
BW::vector<GridStatus> gridStatus_;   // 每个网格的状态
BW::vector<Computer> computers_;      // 所有电脑的锁
```

`tick()` 方法轮询 bwlockd,有更新就刷新本地缓存。之后 `isWritableByMe` 等查询都走本地,响应即时。

#### 16.29.4 锁的"链接"机制

`linkPoint` 方法是个有意思的设计:

```cpp
// programming/bigworld/tools/common/bwlockd_connection.hpp  L135
void linkPoint( int16 oldLeft, int16 oldTop, int16 newLeft, int16 newTop );
```

它记录"旧坐标 → 新坐标"的映射。当空间被扩展( Expand Space)后,原有 chunk 的网格坐标会偏移,锁也要跟着偏移。`linkPoint` 让 bwlockd 知道这种偏移关系,迁移已有锁到新坐标。

### 16.30 AssetClient 实时编译剖析

#### 16.30.1 编译即编辑

传统工具链是"编辑 → 手动编译 → 看效果",反馈周期长。BigWorld 通过 AssetClient + jit_compiler 实现"编辑即编译":

```
设计师移动物体 → WorldManager::changedChunk
   → ChunkProcessorManager 派发后台任务
   → AssetClient 通知 jit_compiler
   → jit_compiler 重新编译关联资源
   → 编译完成通知 WorldEditor
   → 视口刷新,显示新资源
```

整个过程设计师无需手动触发编译,只需保存即可。

#### 16.30.2 三套后台线程

WorldEditor 有三套后台线程,各司其职:

| 线程池 | 启动 | 用途 |
|--------|------|------|
| `BgTaskManager` | `initApp` 启动 1 个 | 通用后台任务(编译、IO 等) |
| `FileIOTaskManager` | `initApp` 启动 1 个 | 文件 IO 专用(避免阻塞主线程) |
| `ChunkProcessorManager` | `WorldManager::init` 启动 N 个 | chunk 后台处理(光照、导航、LOD) |

#### 16.30.3 分时控制

后台线程不能"抢"主线程的 CPU——否则视口会卡。WorldEditor 用 `allowChunkProcessorThreadsToRun` 控制开关:

```cpp
// programming/bigworld/tools/worldeditor/framework/world_editor_app.cpp  L519-530
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

`presenting` 是渲染呈现的回调。**在呈现(渲染)期间,后台线程允许运行;不在呈现时,它们被暂停**。这样后台线程"借"主线程的空闲时间,不影响帧率。

Watcher 暴露分时参数:

```cpp
// programming/bigworld/tools/worldeditor/world/world_manager.cpp  L699-707
MF_WATCH( "Chunk Processor/Time Slice", s_minimumAllowTimeSliceMS_, ...,
    "Minimum amount of time per frame to dedicate to the chunk processors. "
    "A value of 0 means no dedicated time." );

MF_WATCH( "Chunk Processor/Wait Warn Threshold", s_timeSlicePauseWarnThresholdMS_, ...,
    "Threshold for warning about chunk processors taking too long to yield. "
    "A value of 0 disables the warning." );
```

运行时可以通过 Watcher 调整这两个参数,找到 CPU 占用的平衡点。

### 16.31 本章小结

这一章我们走过了 WorldEditor 这个 BigWorld 工具链中规模最大的程序。回顾几个核心要点:

1. **架构骨架**:WorldEditor 是 MFC SDI 应用,`WorldEditorApp` 是入口,`Initialisation::initApp` 初始化全局资源,`WorldManager` 是核心。

2. **WorldManager God Object**:9 重继承,集中管理场景、选择、渲染、保存、工具、Python、锁、多线程。虽是反模式,但在编辑器领域务实有效,且 BigWorld 采取了拆分子类、抽象基类、RAII 守卫等缓解措施。

3. **Chunk 编辑集成**:基于 lib/chunk 的 `ChunkCache` 机制,叠加 `EditorChunkCache`/`EditorChunkCacheBase`,提供编辑器专用的保存、变换、生命周期、权限查询。`EditorChunkItem` 基类用 `ed` 前缀方法扩展运行时 `ChunkItem`。

4. **UndoRedo 命令模式**:`Operation` 多态基类 + `Barrier` 批量分组。最精妙的是"undo 产生 undo"——Operation 只有 `undo()`,redo 自动由"undo 的 undo"完成,省了一半代码。还有同类去重优化,避免高频操作撑爆栈。

5. **bwlockd 多人协作**:网格级悲观锁,四种状态(`GS_NOT_LOCKED`/`GS_LOCKED_BY_ME`/`GS_LOCKED_BY_OTHERS`/`GS_WRITABLE_BY_ME`),只有 `GS_WRITABLE_BY_ME` 可写。`ProjectModule` 驱动锁定/提交流程,`EditorChunkLockVisualizer` 可视化锁边界。

6. **AssetClient 实时编译**:`WorldManager::changedChunk` → `ChunkProcessorManager` → `AssetClient` → `jit_compiler`,设计师无需手动编译。三套后台线程 + 分时控制,保证编辑流畅。

7. **Tool 框架**:`Tool` = `ToolLocator` + `ToolView` + `ToolFunctor`,策略模式组合出选择/移动/旋转/缩放/地形雕刻等各种工具,且工具切换可撤销。

8. **common 与 editor_shared**:`tools_common` 提供 UndoRedo/BWLockDConnection/EditorChunkCacheBase/SpaceEditor/RompHarness 等公共能力;`editor_shared` 通过 `IEditorApp`/`IMainFrame` 抽象接口隔离 MFC/Qt 后端(虽然 Qt 后端尚未完成)。

WorldEditor 是 BigWorld 引擎"造世界"的核心。理解了它的架构,你就能看懂任何一款商用 MMOG 编辑器的骨架。下一章我们将继续工具链的旅程,看看 ModelEditor(模型编辑器)是如何处理单个美术资源的。

---

> **延伸阅读**
>
> - `docs/tools/BigWorld工具-worldeditor实现分析.md`:更详细的 WorldEditor 实现分析
> - `docs/tools/BigWorld工具-common实现分析.md`:tools_common 库深度文档
> - `docs/tools/BigWorld工具-editor_shared实现分析.md`:editor_shared 双后端架构
> - `docs/tools/BigWorld工具-asset_pipeline实现分析.md`:资产管线全貌
> - `docs/tools/BigWorld工具-jit_compiler实现分析.md`:编译守护进程
>
> **实操建议**
>
> 1. 用 WorldEditor 打开一个示例 space,观察锁定/解锁时 `EditorChunkLockVisualizer` 的边框颜色变化
> 2. 在 Watcher 面板里调 `Chunk Processor/Time Slice`,观察帧率变化
> 3. 改一个物体后保存,用 `OutputDebugString` 或日志观察 AssetClient 的编译通知流程
> 4. 在 `UndoRedo::barrier` 加日志,统计一次"移动物体"操作涉及多少个 Operation
