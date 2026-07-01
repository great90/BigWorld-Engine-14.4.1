# BigWorld 工具 particle_editor 实现深度分析

> 本文档详细分析 BigWorld Engine 14.4.1 中 ParticleEditor(粒子编辑器)的完整实现。ParticleEditor 是一个**单体应用**(约 100 文件),与 `modeleditor` 的壳/核分离不同,它将启动壳与业务逻辑合并在一个项目中。其核心特色包括:**C++/Python 双模式更新**(`c_useScripting` 标志)、**PE_PLAYING/PE_PAUSED/PE_STOPPED 三态状态机**、**MetaNode/PSNode/ActionNode 三层粒子系统树**、**16 种 PSA(Particle System Action)属性对话框**、**帧率限制 OnIdle 主循环**。本文档涵盖架构定位、目录组织、启动流程、状态机、粒子系统三层树、16 种 PSA、Python 集成、资源管理等核心机制。

---

## 目录

- [一、整体架构概览](#一整体架构概览)
- [二、源码目录结构](#二源码目录结构)
- [三、入口点与启动流程](#三入口点与启动流程)
- [四、核心类与继承关系](#四核心类与继承关系)
- [五、关键算法与数据结构](#五关键算法与数据结构)
- [六、GUI 框架与 16 种 PSA 属性对话框](#六gui-框架与-16-种-psa-属性对话框)
- [七、Python 脚本集成](#七python-脚本集成)
- [八、资源管理](#八资源管理)
- [九、配置项与命令行参数](#九配置项与命令行参数)
- [十、与其他模块的依赖关系](#十与其他模块的依赖关系)
- [十一、关键代码片段](#十一关键代码片段)
- [十二、设计亮点与注意事项](#十二设计亮点与注意事项)

---

## 一、整体架构概览

### 1.1 particle_editor 在工具链中的定位

`particle_editor` 是 BigWorld 工具链中**粒子编辑器**的可执行入口,位于 `programming/bigworld/tools/particle_editor/`,由 `CMakeLists.txt` 组织为**单一可执行文件**(通过 `BW_ADD_TOOL_EXE`)。它承担以下职责:

1. **粒子系统编辑**:创建/加载/保存 `MetaParticleSystem`(`.psv` 文件)
2. **粒子系统目录浏览**:浏览粒子系统目录,树形展示
3. **三层粒子系统树**:MetaNode→PSNode→ActionNode 层次结构
4. **16 种 PSA 编辑**:Barrier/Collide/Empty/Flare/Force/Jitter/Magnet/MatrixSwarm/NodeClamp/Orbitor/Scaler/Sink/Source/Splat/Stream/TintShader
5. **渲染属性编辑**:PS 属性、Meta PS 属性、渲染器属性
6. **状态机**:PE_PLAYING/PE_PAUSED/PE_STOPPED 三态切换
7. **C++/Python 双模式**:`c_useScripting` 标志切换更新模式
8. **撤销/重做**:`UndoRedoOp`(DataSection 快照)
9. **Python 暴露**:`ParticleEditor` Python 模块
10. **辅助模型**:加载 helper model(硬点定位)
11. **Gizmo**:粒子系统 Gizmo 渲染
12. **背景色/网格/相机视角**:Free/X/Y/Z/Orbit 视角切换

### 1.2 整体架构拓扑

```
┌──────────────────────────────────────────────────────────────────────┐
│              particle_editor 进程 (MFC SDI, ~100 文件单体应用)       │
│                                                                      │
│  ┌──────────────────┐   ┌──────────────────┐   ┌────────────────┐    │
│  │ParticleEditorApp │   │   MainFrame       │   │ PanelManager   │    │
│  │(CWinApp +        │──▶│(BaseMainFrame +   │──▶│(多组 ActionMaker│    │
│  │ OptionMap +      │   │ IMainFrame)       │   │ +多组 Updater- │    │
│  │ IEditorApp)      │   │                   │   │  Maker + Base- │    │
│  │                  │   │ SelectPS/         │   │  PanelManager) │    │
│  │ 状态机:         │   │ IsMetaPS/         │   │                │    │
│  │ PE_PLAYING/      │   │ GetMetaPS/        │   │ (比 modeleditor│    │
│  │ PE_PAUSED/       │   │ PotentiallyDirty/ │   │  多语言/UAL/   │    │
│  │ PE_STOPPED       │   │ SaveUndoState/    │   │  Messages 面板)│    │
│  │                  │   │ OnUndo/OnRedo/    │   │                │    │
│  │ c_useScripting   │   │ appendOneWayPS/   │   │                │    │
│  │ (C++/Py 双模式)  │   │ ForceSave/        │   │                │    │
│  └────────┬─────────┘   │ PromptSave/       │   └────────────────┘    │
│           │             │ InitialiseMeta-   │                          │
│           │             │  SystemRegister   │                          │
│           │             └────────┬──────────┘                          │
│           │ new App              │ ParticleEditorView (3D 视口)        │
│           │ new PeShell          │                                      │
│           │ new PeApp            │                                      │
│           ▼                      ▼                                      │
│  ┌──────────────────────────────────────────────────────────────┐     │
│  │              三层运行时(App / Shell / Module)              │     │
│  │                                                              │     │
│  │  App (appmgr)        → 通用应用管理(计时/输入/模块调度)     │     │
│  │      │                                                       │     │
│  │      ▼                                                       │     │
│  │  PeShell             → 图形/脚本/控制台/ROMP/相机/声音/      │     │
│  │      │                  Floor/ChunkSpace/FontManager/        │     │
│  │      │                  TextureFeeds/Terrain::Manager/       │     │
│  │      │                  PostProcessing::Manager/             │     │
│  │      │                  LensEffectManager/AssetClient         │     │
│  │      ▼                                                       │     │
│  │  PeModule            → 渲染模块(updateState/render/          │     │
│  │      │                  renderChunks/renderTerrain/           │     │
│  │      │                  renderScale/renderParticles/          │     │
│  │      │                  renderGizmo/renderAndUpdateBound/     │     │
│  │      │                  helperModel/hardPointNames)           │     │
│  │      ▼                                                       │     │
│  │  PeApp               → 轻量应用包装                           │     │
│  └──────────────────────────────────────────────────────────────┘     │
│           │                                                            │
│           ▼                                                            │
│  ┌──────────────────────────────────────────────────────────────┐     │
│  │              GUI 层(粒子系统树 + 16 种 PSA 对话框)         │     │
│  │                                                              │     │
│  │  ┌──────────────────────────────────────────────────────┐   │     │
│  │  │         三层粒子系统树(TreeControl)                 │   │     │
│  │  │                                                       │   │     │
│  │  │  MetaNode (MetaParticleSystemPtr)                     │   │     │
│  │  │    └─ PSNode (ParticleSystemPtr)                      │   │     │
│  │  │         ├─ ActionNode (AT_SYS_PROP, 系统属性)         │   │     │
│  │  │         ├─ ActionNode (AT_REND_PROP, 渲染属性)        │   │     │
│  │  │         └─ ActionNode (AT_ACTION, PSA 动作)           │   │     │
│  │  │              ├─ Source / Sink / Force / Jitter        │   │     │
│  │  │              ├─ Magnet / Orbitor / Scaler / Splat     │   │     │
│  │  │              ├─ Stream / Barrier / Collide / Flare    │   │     │
│  │  │              ├─ MatrixSwarm / NodeClamp / TintShader  │   │     │
│  │  │              └─ Empty                                 │   │     │
│  │  └──────────────────────────────────────────────────────┘   │     │
│  │                                                              │     │
│  │  ActionSelection  PsTree  GuiUtilities                      │     │
│  │  VectorGeneratorProxies  VectorGeneratorCustodian           │     │
│  │  Controls: TreeControl/DropTarget/DragListbox/              │     │
│  │           ColorPicker/ColorPickerDialog/ColorDialog         │     │
│  │  Dialogs: SplashDialog/SaveParticleSystemDialog/DirDialog   │     │
│  └──────────────────────────────────────────────────────────────┘     │
└──────────────────────────────────────────────────────────────────────┘
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
      ┌──────────────┐ ┌─────────────┐ ┌──────────────┐
      │ AssetClient  │ │ BgTaskMgr   │ │ Python 脚本  │
      │ (资产管线)   │ │ (后台线程)  │ │ (双模式)     │
      └──────────────┘ └─────────────┘ └──────────────┘
```

### 1.3 关键设计原则

| 原则 | 说明 |
|------|------|
| **单体应用** | 与 `modeleditor` 壳/核分离不同,ParticleEditor 将所有代码集中于一个项目(~100 文件) |
| **C++/Python 双模式** | `c_useScripting` 标志(默认 false)切换更新模式,C++ 模式调用 `mfApp_->updateFrame`,Python 模式调用 `pe_shell.update` |
| **三态状态机** | `PE_PLAYING`/`PE_PAUSED`/`PE_STOPPED` 管理粒子系统播放状态 |
| **三层粒子系统树** | MetaNode→PSNode→ActionNode,对应 MetaParticleSystem→ParticleSystem→PSA |
| **16 种 PSA 对话框** | 每种 ParticleSystemAction 有专属属性对话框,继承 `PsaProperties` |
| **DataSection 撤销快照** | `UndoRedoOp` 保存 DataSection 快照,`XmlSectionsAreEq` 比较等价性 |
| **帧率限制 OnIdle** | `m_desiredFrameRate`(默认 60fps)+ `Sleep` 补偿,避免 CPU 占用过高 |
| **MFC SDI 框架** | `CWinApp` + `CSingleDocTemplate` + 文档/视图/主框架三件套 |
| **GUITABS 撕离标签** | `particleeditor.layout` 定义面板布局,支持撕离 |
| **辅助模型硬点** | `PeModule` 支持加载 helper model,定位 hard points |

### 1.4 规模与组成

`particle_editor` 源码约 100 文件,按目录分组:

| 目录 | 文件数(估) | 职责 |
|------|------------|------|
| 根目录 | ~10 | `particle_editor`/`pe_app`/`main_frame`/`particle_editor_doc`/`particle_editor_view`/`undoredo_op`/`about_dlg`/`pch`/`fwd`/`CMakeLists` |
| `shell/` | ~6 | `PeShell`/`PeModule`/`PeScripter` |
| `gui/` | ~10 | `PanelManager`/`ActionSelection`/`PsNode`/`PsTree`/`GuiUtilities`/`VectorGeneratorProxies`/`VectorGeneratorCustodian` |
| `gui/controls/` | ~6 | `TreeControl`/`DropTarget`/`DragListbox`/`ColorPicker`/`ColorPickerDialog`/`ColorDialog` |
| `gui/dialogs/` | ~3 | `SplashDialog`/`SaveParticleSystemDialog`/`DirDialog` |
| `gui/propdlgs/` | ~19 | 16 种 PSA 属性对话框 + `PsaProperties` + `PsProperties` + `PsRendererProperties` + `MpsProperties` |
| `bigbang/` | ~1 | `GridCoord` |

---

## 二、源码目录结构

```
programming/bigworld/tools/particle_editor/
├── CMakeLists.txt                  # 构建脚本(BW_ADD_TOOL_EXE)
├── pch.hpp                         # 预编译头
├── fwd.hpp                         # 前向声明
│
├── particle_editor.hpp / .cpp      # ParticleEditorApp(CWinApp+OptionMap+IEditorApp)
├── pe_app.hpp / .cpp               # PeApp(轻量应用包装)
├── main_frame.hpp / .cpp           # MainFrame(BaseMainFrame+IMainFrame)
├── particle_editor_doc.hpp / .cpp  # ParticleEditorDoc(MFC 文档)
├── particle_editor_view.hpp / .cpp # ParticleEditorView(MFC 视图)
├── undoredo_op.hpp / .cpp          # UndoRedoOp(UndoRedo::Operation)
├── about_dlg.hpp                   # AboutDlg 关于对话框
│
├── shell/                          # Shell 层
│   ├── pe_shell.hpp / .cpp         # PeShell(图形/脚本/控制台/ROMP/相机/声音)
│   ├── pe_module.hpp / .cpp        # PeModule(FrameworkModule,渲染)
│   └── pe_scripter.hpp / .cpp      # Scripter 脚本初始化
│
├── gui/                            # GUI 层
│   ├── panel_manager.hpp / .cpp    # PanelManager(多组 ActionMaker+UpdaterMaker)
│   ├── action_selection.hpp / .cpp # ActionSelection 动作选择面板
│   ├── ps_node.hpp / .cpp          # MetaNode/PSNode/ActionNode 三层树节点
│   ├── ps_tree.hpp / .cpp          # PsTree 粒子系统树
│   ├── gui_utilities.hpp / .cpp    # GuiUtilities 工具函数
│   ├── vector_generator_proxies.hpp / .cpp      # VectorGenerator 代理
│   ├── vector_generator_custodian.hpp / .cpp    # VectorGenerator 管理者
│   │
│   ├── controls/                   # 控件
│   │   ├── tree_control.hpp / .cpp          # TreeControl 树控件
│   │   ├── drop_target.hpp / .cpp           # DropTarget 拖放目标
│   │   ├── drag_listbox.hpp / .cpp          # DragListbox 拖拽列表
│   │   ├── color_picker.hpp / .cpp          # ColorPicker 颜色选择器
│   │   ├── color_picker_dialog.hpp / .cpp   # ColorPickerDialog 颜色对话框
│   │   └── color_dialog.hpp / .cpp          # ColorDialog 颜色对话框
│   │
│   ├── dialogs/                    # 对话框
│   │   ├── splash_dialog.hpp / .cpp          # SplashDialog 闪屏
│   │   ├── save_particle_system_dialog.hpp / .cpp  # 保存粒子系统对话框
│   │   └── dir_dialog.hpp / .cpp             # DirDialog 目录对话框
│   │
│   └── propdlgs/                   # 属性对话框(16 种 PSA + 3 种 PS 属性)
│       ├── psa_properties.hpp / .cpp              # PsaProperties 基类
│       ├── psa_barrier_properties.hpp / .cpp      # Barrier 障碍
│       ├── psa_collide_properties.hpp / .cpp      # Collide 碰撞
│       ├── psa_empty_properties.hpp / .cpp        # Empty 空(占位)
│       ├── psa_flare_properties.hpp / .cpp        # Flare 光晕
│       ├── psa_force_properties.hpp / .cpp        # Force 力
│       ├── psa_jitter_properties.hpp / .cpp       # Jitter 抖动
│       ├── psa_magnet_properties.hpp / .cpp       # Magnet 磁力
│       ├── psa_matrixswarm_properties.hpp / .cpp  # MatrixSwarm 矩阵群
│       ├── psa_nodeclamp_properties.hpp / .cpp    # NodeClamp 节点夹紧
│       ├── psa_orbitor_properties.hpp / .cpp      # Orbitor 轨道
│       ├── psa_scaler_properties.hpp / .cpp       # Scaler 缩放
│       ├── psa_sink_properties.hpp / .cpp         # Sink 吸收
│       ├── psa_source_properties.hpp / .cpp       # Source 源
│       ├── psa_splat_properties.hpp / .cpp        # Splat 飞溅
│       ├── psa_stream_properties.hpp / .cpp       # Stream 流
│       ├── psa_tint_shader_properties.hpp / .cpp  # TintShader 着色
│       ├── ps_properties.hpp / .cpp               # PsProperties PS 属性
│       ├── ps_renderer_properties.hpp / .cpp      # PsRendererProperties 渲染器属性
│       └── mps_properties.hpp / .cpp              # MpsProperties Meta PS 属性
│
└── bigbang/
    └── grid_coord.hpp              # GridCoord 网格坐标
```

---

## 三、入口点与启动流程

### 3.1 入口点与全局实例

`particle_editor` 的入口点是 MFC `CWinApp` 全局实例,定义于 `particle_editor.cpp` 第 147 行:

```cpp
// particle_editor.cpp L147
ParticleEditorApp theApp;
```

`ParticleEditorApp` 构造函数(L154-167)完成早期初始化:

```cpp
// particle_editor.cpp L154-167
ParticleEditorApp::ParticleEditorApp() :
	m_appShell(NULL),
	m_peApp(NULL),
	mfApp_( NULL ),
	m_desiredFrameRate(60.0f),
	m_state(PE_PLAYING)
{
	BW_GUARD;
    ASSERT(s_instance == NULL);
    s_instance = this;
	MsgHandler::instance();  // Init messages early
}
```

注意:构造函数设置 `m_state(PE_PLAYING)`,默认状态为播放;`m_desiredFrameRate(60.0f)` 默认 60fps。

### 3.2 InitInstance 启动流程

`InitInstance`(L215-236)通过 `CallWithExceptionFilter` 包裹 `InternalInitInstance`:

```cpp
// particle_editor.cpp L215-236
BOOL ParticleEditorApp::InitInstance()
{
	BW::Allocator::setSystemStage( BW::Allocator::SS_MAIN );
	BOOL result = CallWithExceptionFilter( this, &ParticleEditorApp::InternalInitInstance );
	if (!result)
	{
		ERROR_MSG( "ParticleEditor failed to initialise itself correctly\n" );
		if (!CStdMf::checkUnattended())
		{
			MessageBox( NULL,
				L"ParticleEditor failed to initialise itself correctly.\n\
Please check the debug log for detailed information.",
				 L"ParticleEditor", MB_OK );
		}
	}
	return result;
}
```

### 3.3 InternalInitInstance 完整启动序列

`InternalInitInstance`(L254-481)是启动流程核心,执行序列如下:

```
Name::init()                              L258  名称系统初始化
waitForRestarting()                       L260  等待重启
InitCommonControls()                      L265  通用控件初始化
CWinApp::InitInstance()                   L267  MFC 基类初始化
s_lpCmdLine = copy(m_lpCmdLine)           L269-270  保存命令行副本
AfxOleInit()                              L276  OLE 初始化
SetRegistryKey(...)                       L289  设置注册表键
LoadStdProfileSettings(4)                 L290  加载标准 INI 设置(MRU)
CSingleDocTemplate(SDI)                   L302-308  注册文档模板
  ├─ IDR_MAINFRAME
  ├─ RUNTIME_CLASS(ParticleEditorDoc)
  ├─ RUNTIME_CLASS(MainFrame)
  └─ RUNTIME_CLASS(ParticleEditorView)
InitialiseMF(openFile)                    L317  初始化 MF(命令行+资源+选项)
  ├─ 解析 -o/-O 参数
  ├─ BWResource::init
  └─ Options::init("particleeditor.options")
StringProvider::load(语言文件)           L321-337  加载多语言资源
setLanguage(currentLanguage, currentCountry)  L339-344
WindowTextNotifier::instance()            L346
ParseCommandLine(cmdInfo)                 L350  解析 MFC 命令行
ProcessShellCommand(cmdInfo)              L354  分发命令(创建主窗口)
m_pMainWnd->ShowWindow(SW_SHOWMAXIMIZED)  L361  显示主窗口
mainFrame->UpdateTitle()                  L369  更新标题
mfApp_ = new App                          L373  创建应用管理器
m_appShell = new PeShell                  L376  创建 Shell
mfApp_->init(hInst, mainFrame, mainView,  L382-394  App 初始化
            NULL, PeShell::initApp)
  └─ PeShell::initApp → PeShell::init
     ├─ initGraphics (Renderer/Moo)
     ├─ initScripts (Python)
     ├─ initConsoles
     ├─ initRomp (RompHarness/TimeOfDay)
     ├─ initCamera (ToolsCamera)
     ├─ initSound
     └─ (Floor/ChunkSpace)
m_peApp = new PeApp()                     L396  创建 PeApp
CooperativeMoo::init()                    L398  Moo 协作式初始化
GUI::Manager::init()                      L400  GUI 管理器初始化
GUI::Manager::pythonFunctor()             L403  设置 Python 默认模块
  .defaultModule("MenuUIAdapter")
GUI::Manager::optionFunctor().setOption(this)  L404  绑定选项 Functor
GUI::Manager::add(gui.xml 子项)           L405-407  加载 GUI 项
menuHelper_ = new GUI::MenuHelper          L409  菜单助手
GUI::Manager::add(new GUI::Menu("MainMenu"))  L411-414  主菜单
updateLanguageList()                       L416  更新语言列表
AfxGetMainWnd()->DrawMenuBar()             L418
mainFrame->createToolbars("AppToolbars")   L421  创建工具栏
PanelManager::init(mainFrame, mainView,    L424  面板管理器初始化
    L"particleeditor.layout")
BgTaskManager::init()                      L427  后台任务管理器
BgTaskManager::initWatchers("ParticleEditor")  L428
BgTaskManager::startThreads(1)             L429
FileIOTaskManager::init()                  L431
FileIOTaskManager::initWatchers("FileIO")  L432
FileIOTaskManager::startThreads(1)         L433
UMBRA 强制禁用                              L441-448  render/useUmbra=0
若 !c_useScripting:                       L453-457
  ├─ MainFrame::InitialiseMetaSystemRegister()  初始化粒子系统注册
  └─ MainFrame::UpdateGUI()
若 openFile 非空:                         L464-476
  ├─ openDirectory(getFilePath(openFile))
  ├─ update()
  └─ SelectParticleSystem(getFilename(openFile))
Automation::parseCommandLine(m_lpCmdLine)  L478  自动化命令行解析
return TRUE                                L480
```

### 3.4 启动流程架构图

```
┌─────────────────────────────────────────────────────────────────┐
│                  ParticleEditorApp::InitInstance                │
│                          (L215-236)                             │
│  CallWithExceptionFilter → InternalInitInstance                 │
└────────────────────────────┬────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│  1. 早期初始化                                                  │
│     Name::init / waitForRestarting / InitCommonControls         │
│     CWinApp::InitInstance / AfxOleInit                          │
│     SetRegistryKey / LoadStdProfileSettings(4)                  │
│     CSingleDocTemplate(SDI)                                     │
├─────────────────────────────────────────────────────────────────┤
│  2. 命令行与配置(InitialiseMF)                                 │
│     解析 -o/-O 参数 → openFile                                  │
│     BWResource::init(argc, argv)                                │
│     Options::init(argc, argv, "particleeditor.options")         │
├─────────────────────────────────────────────────────────────────┤
│  3. 多语言                                                      │
│     StringProvider::load(language files)                        │
│     setLanguage(currentLanguage, currentCountry)                │
├─────────────────────────────────────────────────────────────────┤
│  4. 主窗口创建                                                  │
│     ParseCommandLine / ProcessShellCommand(创建主窗口)          │
│     ShowWindow(SW_SHOWMAXIMIZED) / UpdateTitle                  │
├─────────────────────────────────────────────────────────────────┤
│  5. 三层运行时装配                                              │
│     new App → new PeShell → mfApp_->init(PeShell::initApp)      │
│     new PeApp                                                   │
├─────────────────────────────────────────────────────────────────┤
│  6. GUI 装配                                                    │
│     CooperativeMoo::init / GUI::Manager::init                   │
│     pythonFunctor.defaultModule("MenuUIAdapter")                │
│     optionFunctor.setOption(this)                               │
│     加载 gui.xml → GUI::Item                                    │
│     MenuHelper + MainMenu + 语言列表                            │
│     createToolbars("AppToolbars")                               │
│     PanelManager::init("particleeditor.layout")                 │
├─────────────────────────────────────────────────────────────────┤
│  7. 后台线程                                                    │
│     BgTaskManager::startThreads(1)                              │
│     FileIOTaskManager::startThreads(1)                          │
├─────────────────────────────────────────────────────────────────┤
│  8. Umbra 强制禁用                                              │
│     render/useUmbra=0                                           │
├─────────────────────────────────────────────────────────────────┤
│  9. 粒子系统初始化(C++ 模式)                                  │
│     若 !c_useScripting:                                         │
│       MainFrame::InitialiseMetaSystemRegister()                 │
│       MainFrame::UpdateGUI()                                    │
├─────────────────────────────────────────────────────────────────┤
│  10. 命令行文件加载                                             │
│      若 openFile 非空:                                          │
│        openDirectory(getFilePath(openFile))                     │
│        update()                                                 │
│        SelectParticleSystem(getFilename(openFile))              │
├─────────────────────────────────────────────────────────────────┤
│  11. 收尾                                                       │
│      Automation::parseCommandLine                               │
└─────────────────────────────────────────────────────────────────┘
```

### 3.5 InitialiseMF 命令行解析

`InitialiseMF`(L183-212)解析命令行,初始化资源与选项系统:

```cpp
// particle_editor.cpp L183-212
bool ParticleEditorApp::InitialiseMF( BW::string &openFile )
{
	BW_GUARD;
	const int MAX_ARGS = 20;
	char * argv[ MAX_ARGS ];
	int argc = 0;
	char cmdline [32768];
	bw_wtoutf8( s_lpCmdLine, wcslen( s_lpCmdLine ), cmdline, ARRAY_SIZE( cmdline ) );
	char * str = cmdline;
	while (char * token = StringUtils::retrieveCmdTokenT( str ))
	{
		if (argc >= MAX_ARGS)
		{
			ERROR_MSG( "ParticleEditor::InitialiseMF: Too many arguments!!\n" );
			return FALSE;
		}
		if (argc && (!strcmp( argv[ argc-1 ], "-o" ) || !strcmp( argv[ argc-1 ], "-O" )))
		{
			openFile = BW::string( token );
		}
		argv[argc++] = token;
	}
	return BWResource::init( argc, (const char **)argv ) &&
		Options::init( argc, argv, L"particleeditor.options" );
}
```

---

## 四、核心类与继承关系

### 4.1 ParticleEditorApp 类声明

`ParticleEditorApp`(声明于 `particle_editor.hpp` L18-104)继承 `CWinApp` + `GUI::OptionMap` + `IEditorApp`:

```cpp
// particle_editor.hpp L18-22
class ParticleEditorApp
	: public CWinApp
	, public GUI::OptionMap
	, public IEditorApp
{
```

### 4.2 继承关系图

```
                          ┌─────────────┐
                          │   CWinApp   │  (MFC 应用程序基类)
                          └──────┬──────┘
                                 │
                          ┌──────┴──────┐
                          │ GUI::OptionMap│ (GUI 选项 Functor)
                          └──────┬──────┘
                                 │
                          ┌──────┴──────┐
                          │ IEditorApp  │  (editor_shared 抽象接口)
                          └──────┬──────┘
                                 │
                          ┌──────┴──────┐
                          │ParticleEditorApp│
                          └─────────────┘
```

注意:ParticleEditorApp 继承 `IEditorApp` 而非 `IModelEditorApp`(因为它是单体应用,无壳/核分离需求)。

### 4.3 三重继承职责

| 基类 | 头文件 | 职责 |
|------|--------|------|
| `CWinApp` | MFC | MFC 应用程序框架:`InitInstance`/`OnIdle`/`ExitInstance`/`Run`/消息映射 |
| `GUI::OptionMap` | `guimanager/gui_functor_option.hpp` | GUI 选项 Functor:`get`/`set`/`exist` 委托给 `Options` |
| `IEditorApp` | `editor_shared/app/i_editor_app.hpp` | 编辑器抽象接口 |

### 4.4 关键成员变量

```cpp
// particle_editor.hpp L94-103(私有成员)
private:
    PeShell                     *m_appShell;        // Shell(图形/脚本/控制台/ROMP)
    PeApp                       *m_peApp;            // 轻量应用包装
    App                         *mfApp_;             // 应用管理器(appmgr)
    float                       m_desiredFrameRate;  // 帧率限制(默认 60fps)
    State                       m_state;             // 状态机(PE_PLAYING/PE_PAUSED/PE_STOPPED)
    static ParticleEditorApp    *s_instance;         // 单例
	std::auto_ptr< GUI::MenuHelper > menuHelper_;    // 菜单助手
```

### 4.5 MainFrame 类声明

`MainFrame`(声明于 `main_frame.hpp` L14-15)是主框架,继承 `BaseMainFrame` + `IMainFrame`:

```cpp
// main_frame.hpp L14-15
class MainFrame : public BaseMainFrame, public IMainFrame
{
```

`MainFrame` 是 ParticleEditor 的**业务核心**,承担粒子系统选择、撤销重做、状态管理、视角切换、背景色、辅助 PS 等职责。

### 4.6 MainFrame 关键方法

```cpp
// main_frame.hpp L28-134(节选)
    bool SelectParticleSystem(BW::string const &name);           // 选择粒子系统
    bool IsMetaParticleSystem();                                  // 是否为 Meta PS
    MetaParticleSystemPtr GetMetaParticleSystem();                // 获取 Meta PS
    bool IsCurrentParticleSystem();                               // 是否为当前 PS
    ParticleSystemPtr GetCurrentParticleSystem();                 // 获取当前 PS
    void ChangeToActionPropertyWindow(int index, ParticleSystemActionPtr action);  // 切换属性窗口
    void PotentiallyDirty(bool option, UndoRedoOp::ActionKind actionKind, ...);     // 标记脏
    void SaveUndoState( int actionKind, const BW::string& changeDesc, bool addBarrier );  // 保存撤销状态
    void OnUndo() / bool CanUndo() const;                         // 撤销
    void OnRedo() / bool CanRedo() const;                         // 重做
    void OnButtonViewFree() / OnButtonViewX() / OnButtonViewY()   // 视角切换
         / OnButtonViewZ() / OnButtonViewOrbit();
    void OnBackgroundColor();                                     // 背景色
    void ForceSave();                                             // 强制保存
    int PromptSave(UINT type, bool clearUndoStack);               // 提示保存
    void appendOneWayPS();                                        // 追加一次性 PS
    void clearAppendedPS();                                       // 清空追加 PS
    size_t numberAppendPS() const;                                // 追加 PS 数量
    MetaParticleSystem &getAppendedPS(size_t idx);                // 获取追加 PS
    void InitialiseMetaSystemRegister();                          // 初始化 Meta 系统注册
    CString ParticlesDirectory() { return particleDirectory_; }   // 粒子目录
    Moo::Colour BgColour() { return bgColour_; }                  // 背景色
```

### 4.7 UndoRedoOp 撤销操作

`UndoRedoOp`(声明于 `undoredo_op.hpp` L9-72)继承 `UndoRedo::Operation`,保存 DataSection 快照:

```cpp
// undoredo_op.hpp L9-16
class UndoRedoOp : public UndoRedo::Operation
{
public:
    enum ActionKind
    {
        AK_PARAMETER,      // 单参数修改
        AK_NPARAMETER      // 多参数修改
    };
```

**关键方法**:
- `UndoRedoOp(actionKind, data)`(L24-28):构造,保存 DataSection 快照
- `undo()`(L38):恢复快照
- `iseq(other)`(L46):比较两个操作是否相同
- `data()`(L53):获取快照
- `XmlSectionsAreEq(one, two)`(L64-68):比较两个 DataSection 是否逐位相等

### 4.8 PeShell 类声明

`PeShell`(声明于 `shell/pe_shell.hpp` L57-159)是图形/脚本/控制台/ROMP 外壳,持有所有运行时子系统:

```cpp
// pe_shell.hpp L57-90(节选)
class PeShell
{
public:
    PeShell();
    ~PeShell();
    static PeShell & instance();
    static bool hasInstance();
    static bool initApp( HINSTANCE hInstance, HWND hWndApp, HWND hWndGraphics );
    bool init( HINSTANCE hInstance, HWND hWndApp, HWND hWndGraphics );
    void fini();
    HINSTANCE & hInstance();
    HWND &hWndApp();
    HWND &hWndGraphics();
    RompHarness &romp();
    ToolsCamera &camera();
    Floor &floor();
    POINT currentCursorPosition() const;
```

### 4.9 PeShell 持有的子系统

```cpp
// pe_shell.hpp L131-158(私有成员)
private:
    static PeShell      *s_instance_;       // 单例
    bool                inited_;
    HINSTANCE           hInstance_;         // 应用实例
    HWND                hWndApp_;           // 应用窗口
    HWND                hWndGraphics_;      // 3D 窗口
    RompHarness         *romp_;             // ROMP 环境(天气/时间)
    ToolsCameraPtr      camera_;            // 工具相机
    Floor*              floor_;             // 地面
    ChunkSpacePtr       space_;             // 区块空间

    std::auto_ptr<Renderer> m_renderer;     // 渲染器
    std::auto_ptr< AssetClient > pAssetClient_;            // 资产管线客户端
    FontManagerPtr pFontManager_;                          // 字体管理器
    TextureFeedsPtr pTextureFeeds_;                        // 纹理 feed
    TerrainManagerPtr pTerrainManager_;                    // 地形管理器
    PostProcessingManagerPtr pPostProcessingManager_;      // 后处理管理器
    LensEffectManagerPtr pLensEffectManager_;              // 镜头特效管理器
```

注意:与 `MeShell` 相比,`PeShell` 额外持有 `Floor` 与 `ChunkSpacePtr`(直接成员,而非聚合在 `MeApp` 中)。

### 4.10 PeModule 类声明

`PeModule`(声明于 `shell/pe_module.hpp` L15-98)继承 `FrameworkModule`,是渲染模块:

```cpp
// pe_module.hpp L15-29
class PeModule : public FrameworkModule
{
public:
	PeModule();
	~PeModule();
	virtual bool init(DataSectionPtr pSection);
	virtual void onStart();
	virtual int  onStop();
	virtual bool updateState(float dTime);
	virtual void updateAnimations();
	virtual void render( float dTime );
	virtual bool handleKeyEvent(const KeyEvent &event);
	virtual bool handleMouseEvent(const MouseEvent &event);
	virtual void setApp( App * app ) {};
	virtual void setMainFrame( IMainFrame * mainFrame ) {};
	static PeModule& instance() { ASSERT(s_instance_); return *s_instance_; }
	ParticleSystem * activeParticleSystem() const { return particleSystem_; }
	float lastTimeStep() const { return lastTimeStep_; }
	float averageFPS() const { return averageFps_; }
```

### 4.11 PeModule 关键方法与成员

```cpp
// pe_module.hpp L46-98
	const BW::string &helperModelName() const;                    // 辅助模型名
	bool helperModelName( const BW::string &name );               // 设置辅助模型
	BW::vector<BW::string> &getHelperModelHardPointNames();       // 硬点名称列表
	void helperModelCenterOnHardPoint(uint idx);                  // 居中到硬点
	uint helperModelCenterOnHardPoint() const;
	void drawHelperModel(bool draw);                              // 绘制辅助模型
	bool drawHelperModel() const { return drawHelperModel_; }
protected:
	void beginRender();
	void endRender();
	void renderChunks( Moo::DrawContext& drawContext );
	void renderTerrain(float dTime);
    void renderScale();                                           // 绘制比例尺
	void renderParticles( Moo::DrawContext& drawContext );        // 渲染粒子
	void renderGizmo( Moo::DrawContext& drawContext );            // 渲染 Gizmo
	void renderAndUpdateBound();                                  // 渲染并更新边界
private:
	bool loadHelperModel( const BW::string &name );               // 加载辅助模型
	// ...
	ParticleSystem              *particleSystem_;                 // 活跃粒子系统
	bool						drawHelperModel_;                 // 是否绘制辅助模型
	BW::string					helperModelName_;                 // 辅助模型名
	ModelPtr					helperModel_;                     // 辅助模型
	BW::vector<BW::string>		helperModelHardPointNames_;       // 硬点名称
	BW::vector<Matrix>			helperModelHardPointTransforms_;  // 硬点变换
```

---

## 五、关键算法与数据结构

### 5.1 状态机算法

`ParticleEditorApp` 实现三态状态机(PE_PLAYING/PE_PAUSED/PE_STOPPED),`setState`(L740-784)是核心:

```cpp
// particle_editor.cpp L740-784
void ParticleEditorApp::setState(State state)
{
	BW_GUARD;
    MainFrame *mainFrame = MainFrame::instance();
    switch (state)
    {
    case PE_PLAYING:
		mfApp_->pause( false );
		{
			bool restart = m_state != PE_PAUSED;
			if (m_state == PE_PLAYING)
			{
				// try and spawn an additional ps
				size_t numAppendPS = mainFrame->numberAppendPS();
				mainFrame->appendOneWayPS();
				restart = numAppendPS == mainFrame->numberAppendPS();
			}
			if (restart)
			{
				if (mainFrame->IsMetaParticleSystem())
				{
					mainFrame->GetMetaParticleSystem()->clear(); 
					mainFrame->GetMetaParticleSystem()->spawn(); 
				}
			}
		}
        break;
    case PE_STOPPED:
        mfApp_->pause( true );
        if (mainFrame->IsMetaParticleSystem())
		{
			mainFrame->GetMetaParticleSystem()->clear();
			mainFrame->GetMetaParticleSystem()->setFirstUpdate();
			// remove flares when stopping particle editor
			LensEffectManager::instance().clear();
			mainFrame->clearAppendedPS();
		}
        break;
    case PE_PAUSED:
        mfApp_->pause( true );
        break;
    }
    m_state = state;
}
```

**状态机逻辑**:

| 状态 | 行为 |
|------|------|
| `PE_PLAYING` | `mfApp_->pause(false)` 取消暂停;若从 `PE_PAUSED` 转入则 `restart=true`;若已是 `PE_PLAYING` 则尝试追加一次性 PS;若 `restart` 则 `clear()` + `spawn()` 重启粒子系统 |
| `PE_STOPPED` | `mfApp_->pause(true)` 暂停;`clear()` 清空粒子;`setFirstUpdate()` 重置首次更新;`LensEffectManager::clear()` 清除光晕;`clearAppendedPS()` 清空追加 PS |
| `PE_PAUSED` | `mfApp_->pause(true)` 暂停(保留粒子状态) |

### 5.2 状态转换图

```
              setState(PE_PLAYING)
    ┌─────────────────────────────────┐
    │                                 │
    │                                 ▼
┌───┴──────┐  setState(PE_PAUSED)  ┌────────────┐
│PE_PLAYING│─────────────────────▶│ PE_PAUSED  │
│          │                       │            │
│ (播放中) │◀─────────────────────│ (暂停)     │
└────┬─────┘  setState(PE_PLAYING) └─────┬──────┘
     │                                   │
     │ setState(PE_STOPPED)              │ setState(PE_STOPPED)
     │                                   │
     ▼                                   ▼
┌─────────────────────────────────────────────────┐
│                 PE_STOPPED                       │
│                  (停止)                          │
│ clear() / setFirstUpdate() / clearAppendedPS()   │
└─────────────────────────────────────────────────┘
```

### 5.3 OnIdle 帧率限制算法

`OnIdle`(L565-619)实现帧率限制,与 `modeleditor` 不同:

```cpp
// particle_editor.cpp L565-619
BOOL ParticleEditorApp::OnIdle(LONG lCount)
{
	BW_GUARD;
	if ( CWinApp::OnIdle( lCount ) )
		return TRUE;

    HWND foreWindow = GetForegroundWindow();
    CWnd *mainFrame = MainFrame::instance();
	bool isWindowActive =
		foreWindow == mainFrame->m_hWnd || GetParent( foreWindow ) == mainFrame->m_hWnd;

	// Window is inactive - pause
	if ( !CooperativeMoo::canUseMoo( this, isWindowActive ) || !isWindowActive )
    {
		mfApp_->calculateFrameTime(); // Do this to effectively freeze time
    }
	// Window is active - update
    else
    {
		uint64 beforeTime = timestamp();
		update();
		uint64 afterTime = timestamp();
		float lastUpdateMilliseconds = (float) (((int64)(afterTime - beforeTime)) / stampsPerSecondD()) * 1000.f;

        if (m_desiredFrameRate > 0)
        {
            const float desiredFrameTime = 1000.f/m_desiredFrameRate;
            float lastFrameTime = PeModule::instance().lastTimeStep();
            if (desiredFrameTime > lastUpdateMilliseconds)
            {
                float compensation = desiredFrameTime - lastUpdateMilliseconds;
                compensation = std::min(compensation, 2000.f);
                Sleep((int)compensation);
            }
            MainFrame::instance()->UpdateGUI();
        }
    }
    return TRUE;
}
```

**算法逻辑**:
1. 优先处理 MFC GUI 空闲任务
2. 若窗口不活动或 `canUseMoo` 返回 false:仅 `calculateFrameTime()` 冻结时间
3. 否则:
   - 测量 `update()` 耗时(`beforeTime`/`afterTime`)
   - 若 `m_desiredFrameRate > 0`:
     - 计算 `desiredFrameTime = 1000/desiredFrameRate`
     - 若 `update` 耗时 < `desiredFrameTime`:`Sleep(差值)` 补偿(上限 2000ms)
   - `MainFrame::UpdateGUI()` 更新 GUI
4. 返回 `TRUE` 持续循环

**与 modeleditor 的区别**:
- modeleditor 无帧率限制(依赖 CooperativeMoo 协作)
- particle_editor 有显式帧率限制(`m_desiredFrameRate` + `Sleep`)

### 5.4 update() 双模式算法

`update`(L622-652)根据 `c_useScripting` 标志切换 C++/Python 模式:

```cpp
// particle_editor.cpp L622-652
void ParticleEditorApp::update()
{
	BW_GUARD;
    if (!c_useScripting)
    {
        mfApp_->updateFrame();        
    }
    else
    {
        PyObject *pScript     = PyImport_ImportModule("pe_shell");
        PyObject *pScriptDict = PyModule_GetDict(pScript);
        PyObject *pUpdate     = PyDict_GetItemString(pScriptDict, "update");
        if (pUpdate != NULL)
        {
            PyObject * pResult = PyObject_CallFunction(pUpdate, "");
            if (pResult != NULL)
            {
                Py_DECREF( pResult );
            }
            else
            {
                PyErr_Print();
            }
        }
        else
        {
            PyErr_Print();
        }
    }
}
```

**双模式逻辑**:
- `c_useScripting = false`(默认,L144):C++ 模式,调用 `mfApp_->updateFrame()`
- `c_useScripting = true`:Python 模式,导入 `pe_shell` 模块,调用 `update()` 函数

Python 模式允许通过脚本自定义更新逻辑,便于实验与原型开发。

### 5.5 三层粒子系统树

ParticleEditor 使用三层树结构组织粒子系统(声明于 `gui/ps_node.hpp`):

```
MetaNode (MetaParticleSystemPtr)
  │  对应 .psv 文件中的 MetaParticleSystem
  │  仅支持 DROPEFFECT_COPY(CanDragDrop L55)
  │  可编辑标签(SetLabel L40,会重命名底层文件)
  │  
  └─ PSNode (ParticleSystemPtr)
       │  对应 MetaParticleSystem 中的一个 ParticleSystem
       │  仅支持 DROPEFFECT_COPY(CanDragDrop L245)
       │  
       └─ ActionNode (ParticleSystemActionPtr)
            │  对应 ParticleSystem 中的一个 Action 或属性组
            │  
            ├─ ActionType::AT_ACTION      实际动作(PSA)
            ├─ ActionType::AT_SYS_PROP    系统属性
            ├─ ActionType::AT_REND_PROP   渲染属性
            ├─ ActionType::AT_META_PS     Meta PS 属性
            └─ ActionType::AT_PS          PS 属性
```

### 5.6 ActionNode ActionType 枚举

```cpp
// ps_node.hpp L276-283
enum ActionType
{
    AT_ACTION,              // This represents an actual action.
    AT_SYS_PROP,            // This represents system properties.
    AT_REND_PROP,           // This represents render properties.
	AT_META_PS,				// This represents meta particle system.
	AT_PS					// This represents particle system.
};
```

### 5.7 MetaNode 关键方法

`MetaNode`(声明于 `ps_node.hpp` L17-218)是树的根节点:

```cpp
// ps_node.hpp L17-45(节选)
class MetaNode : public TreeNode
{
public:
    MetaNode(BW::string const &dir, BW::string const &filename);
    /*virtual*/ void SetLabel(BW::string const &label);   // 重命名(底层文件重命名)
    /*virtual*/ bool CanEditLabel() const;                 // 可编辑标签
    /*virtual*/ DROPEFFECT CanDragDrop() const;            // 仅 DROPEFFECT_COPY
    MetaParticleSystemPtr GetMetaParticleSystem() const;   // 获取 Meta PS
    void SetMetaParticleSystem(MetaParticleSystemPtr system);
    void SetReadOnly(bool readOnly);                       // 只读
    bool IsReadOnly() const;
    void EnsureLoaded() const;                             // 确保已加载
    BW::string GetFilename() const;                        // 文件名
    BW::string const &GetDirectory() const;                // 目录
    BW::string GetFullpath() const;                        // 完整路径
    bool DeleteFile();                                     // 删除文件
    void FlagChildrenReady();                              // 标记子节点已就绪
    void onSave();                                         // 保存回调
    void onNotSave();                                      // 未保存回调
    void onRename();                                       // 重命名回调
    /*virtual*/ void OnExpand();                           // 展开时加载子节点
    static bool IsMetaParticleFile(BW::StringRef const &filename);  // 是否为 Meta PS 文件
```

### 5.8 PSNode 与 ActionNode

`PSNode`(声明于 `ps_node.hpp` L223-268)是中间层:

```cpp
// ps_node.hpp L223-268(节选)
class PSNode : public TreeNode
{
public:
    explicit PSNode(ParticleSystemPtr ps);
    /*virtual*/ void SetLabel(BW::string const &label);   // 设置 PS 名称
    /*virtual*/ DROPEFFECT CanDragDrop() const;            // DROPEFFECT_COPY
    void addChildren();                                    // 添加子节点(属性+动作)
    ParticleSystemPtr getParticleSystem() const;           // 获取 PS
```

`ActionNode`(声明于 `ps_node.hpp` L273-327)是叶子节点:

```cpp
// ps_node.hpp L273-327(节选)
class ActionNode : public TreeNode
{
public:
    ActionNode(ParticleSystemActionPtr action, BW::string const &name,
        ActionType actionType = AT_ACTION);
    /*virtual*/ DROPEFFECT CanDragDrop() const;            // DROPEFFECT_COPY
    ParticleSystemActionPtr getAction();                   // 获取动作
    ActionType getActionType();                            // 动作类型
    /*virtual*/ bool CanEditLabel() const;                 // false(不可编辑)
```

### 5.9 PotentiallyDirty 脏标志算法

`MainFrame::PotentiallyDirty`(声明于 `main_frame.hpp` L46-54)管理脏状态与撤销:

```cpp
// main_frame.hpp L46-54
void 
PotentiallyDirty
(
    bool                    option,
    UndoRedoOp::ActionKind  actionKind          = UndoRedoOp::AK_PARAMETER,
    BW::string             const &changeDesc   = "?",
    bool                    waitForLButtonUp    = false,
    bool                    addBarrier			= true
);
```

**算法逻辑**:
- `option`:是否标记为脏
- `actionKind`:`AK_PARAMETER`(单参数)或 `AK_NPARAMETER`(多参数)
- `changeDesc`:变更描述(用于撤销菜单显示)
- `waitForLButtonUp`:是否等待鼠标左键释放(拖拽场景)
- `addBarrier`:是否添加撤销屏障

调用 `SaveUndoState` 保存 DataSection 快照到撤销栈。

### 5.10 XmlSectionsAreEq 等价比较

`UndoRedoOp::XmlSectionsAreEq`(声明于 `undoredo_op.hpp` L64-68)比较两个 DataSection 是否逐位相等:

```cpp
// undoredo_op.hpp L64-68
bool XmlSectionsAreEq
(
    DataSectionPtr      const &one, 
    DataSectionPtr      const &two 
) const;
```

用于 `iseq` 判断两个撤销操作是否相同,避免重复入栈。

---

## 六、GUI 框架与 16 种 PSA 属性对话框

### 6.1 PanelManager 面板管理器

`PanelManager`(声明于 `gui/panel_manager.hpp` L18-27)继承多组 `ActionMaker`/`UpdaterMaker` + `BasePanelManager`:

```cpp
// panel_manager.hpp L18-27
class PanelManager :
	public Singleton<PanelManager>,
	public GUI::ActionMaker<PanelManager>  ,	// show panels
	public GUI::ActionMaker<PanelManager,1>,	// hide panels
	public GUI::ActionMaker<PanelManager, 2>,		// Language selection
	public GUI::UpdaterMaker<PanelManager>,		// update show/hide side panel
	public GUI::UpdaterMaker<PanelManager, 1>,	// update show/hide ual panel
	public GUI::UpdaterMaker<PanelManager, 2>,	// update show/hide messages panel
	public GUI::UpdaterMaker<PanelManager, 3>,		// Language selection
	public BasePanelManager
{
```

**与 modeleditor PanelManager 的区别**:
- 多组 `ActionMaker`(show/hide/Language 三组)
- 多组 `UpdaterMaker`(side/ual/messages/Language 四组)
- 支持语言选择面板
- 支持 UAL 面板
- 支持 Messages 面板

### 6.2 PanelManager 关键方法

```cpp
// panel_manager.hpp L36-50
    bool ready();
    void showPanel(BW::wstring const &pyID, int show);
    bool isPanelVisible(BW::wstring const &pyID);
    bool showSidePanel(GUI::ItemPtr item);
    bool hideSidePanel(GUI::ItemPtr item);
    bool setLanguage(GUI::ItemPtr item);                    // 语言选择
    unsigned int updateSidePanel(GUI::ItemPtr item);
	unsigned int updateUalPanel(GUI::ItemPtr item);          // UAL 面板更新
	unsigned int updateMsgsPanel(GUI::ItemPtr item);         // Messages 面板更新
	unsigned int updateLanguage(GUI::ItemPtr item);          // 语言更新
    void updateControls();
    void onClose();
    void ualAddItemToHistory(BW::string filePath);
	bool loadDefaultPanels(GUI::ItemPtr item);
	bool loadLastPanels(GUI::ItemPtr item, const wchar_t* defaultLayoutFilename );
```

### 6.3 16 种 PSA 属性对话框

`gui/propdlgs/` 目录包含 16 种 PSA(Particle System Action)属性对话框,每种 PSA 有专属对话框:

| PSA | 文件 | 功能 |
|-----|------|------|
| `Barrier` | `psa_barrier_properties.hpp/.cpp` | 障碍平面,粒子碰撞反弹 |
| `Collide` | `psa_collide_properties.hpp/.cpp` | 碰撞检测,与场景几何体碰撞 |
| `Empty` | `psa_empty_properties.hpp/.cpp` | 空动作(占位/无操作) |
| `Flare` | `psa_flare_properties.hpp/.cpp` | 光晕效果,镜头光斑 |
| `Force` | `psa_force_properties.hpp/.cpp` | 力场,施加方向力 |
| `Jitter` | `psa_jitter_properties.hpp/.cpp` | 抖动,随机扰动位置 |
| `Magnet` | `psa_magnet_properties.hpp/.cpp` | 磁力,吸引到目标点 |
| `MatrixSwarm` | `psa_matrixswarm_properties.hpp/.cpp` | 矩阵群,矩阵位置生成 |
| `NodeClamp` | `psa_nodeclamp_properties.hpp/.cpp` | 节点夹紧,限制到节点 |
| `Orbitor` | `psa_orbitor_properties.hpp/.cpp` | 轨道,绕中心旋转 |
| `Scaler` | `psa_scaler_properties.hpp/.cpp` | 缩放,改变粒子大小 |
| `Sink` | `psa_sink_properties.hpp/.cpp` | 吸收,移除粒子 |
| `Source` | `psa_source_properties.hpp/.cpp` | 源,生成粒子 |
| `Splat` | `psa_splat_properties.hpp/.cpp` | 飞溅,碰撞后展开 |
| `Stream` | `psa_stream_properties.hpp/.cpp` | 流,连续生成 |
| `TintShader` | `psa_tint_shader_properties.hpp/.cpp` | 着色,改变粒子颜色 |

### 6.4 额外属性对话框

除了 16 种 PSA,还有 3 种粒子系统属性对话框:

| 对话框 | 文件 | 功能 |
|--------|------|------|
| `PsaProperties` | `psa_properties.hpp/.cpp` | PSA 属性基类 |
| `PsProperties` | `ps_properties.hpp/.cpp` | 粒子系统属性(系统级) |
| `PsRendererProperties` | `ps_renderer_properties.hpp/.cpp` | 渲染器属性(渲染方式) |
| `MpsProperties` | `mps_properties.hpp/.cpp` | Meta PS 属性(Meta 系统级) |

### 6.5 控件层

`gui/controls/` 目录包含 6 个自定义控件:

| 控件 | 文件 | 功能 |
|------|------|------|
| `TreeControl` | `tree_control.hpp/.cpp` | 树控件(扩展 MFC CTreeCtrl,支持拖放) |
| `DropTarget` | `drop_target.hpp/.cpp` | 拖放目标(OLE 拖放) |
| `DragListbox` | `drag_listbox.hpp/.cpp` | 可拖拽列表框 |
| `ColorPicker` | `color_picker.hpp/.cpp` | 颜色选择器(自定义控件) |
| `ColorPickerDialog` | `color_picker_dialog.hpp/.cpp` | 颜色选择对话框(线程化) |
| `ColorDialog` | `color_dialog.hpp/.cpp` | 颜色对话框 |

### 6.6 对话框层

`gui/dialogs/` 目录包含 3 个对话框:

| 对话框 | 文件 | 功能 |
|--------|------|------|
| `SplashDialog` | `splash_dialog.hpp/.cpp` | 启动闪屏 |
| `SaveParticleSystemDialog` | `save_particle_system_dialog.hpp/.cpp` | 保存粒子系统对话框 |
| `DirDialog` | `dir_dialog.hpp/.cpp` | 目录浏览对话框 |

### 6.7 ActionSelection 动作选择面板

`ActionSelection`(声明于 `gui/action_selection.hpp`)是粒子系统动作选择面板,显示当前 PS 的所有动作,支持选择/编辑/添加/删除动作。

### 6.8 VectorGenerator 代理

`gui/vector_generator_proxies.hpp` 与 `vector_generator_custodian.hpp` 实现 VectorGenerator(向量生成器)的代理与管理:

- `VectorGeneratorProxies`:为不同类型的 VectorGenerator 提供属性编辑代理
- `VectorGeneratorCustodian`:管理 VectorGenerator 的创建/销毁/选择

VectorGenerator 用于定义粒子初始速度、位置等向量参数(如点、线、球、立方体、圆锥等)。

---

## 七、Python 脚本集成

### 7.1 ParticleEditor Python 模块

`particle_editor.cpp` 通过 `PY_MODULE_FUNCTION` 注册 `ParticleEditor` Python 模块(L899-1583),暴露以下函数:

| Python 函数 | 功能 | C++ 入口 |
|-------------|------|----------|
| `openFile` | 打开粒子系统文件 | `OnDirectoryOpen()` |
| `savePS` | 保存粒子系统 | `OnFileSaveParticleSystem()` |
| `reloadTextures` | 重载纹理 | - |
| `exit` | 退出 | - |
| `showToolbar` / `hideToolbar` | 显示/隐藏工具栏 | - |
| `showStatusbar` | 显示状态栏 | - |
| `toggleShowPanels` | 切换面板显示 | - |
| `loadDefaultPanels` | 加载默认面板 | `loadDefaultPanels()` |
| `zoomToExtents` | 缩放到范围 | - |
| `doViewFree` / `doViewX` / `doViewY` / `doViewZ` / `doViewOrbit` | 视角切换 | `OnButtonViewFree/X/Y/Z/Orbit()` |
| `cameraMode` | 相机模式 | - |
| `doSetBkClr` | 设置背景色 | `OnBackgroundColor()` |
| `showGrid` | 显示网格 | - |
| `undo` / `canUndo` | 撤销 | `OnUndo()` / `CanUndo()` |
| `redo` / `canRedo` | 重做 | `OnRedo()` / `CanRedo()` |
| `doSpawn` | 生成粒子 | `setState(PE_PLAYING)` + spawn |
| `doRestart` | 重启 | - |
| `doPlay` | 播放 | `setState(PE_PLAYING)` |
| `doStop` | 停止 | `setState(PE_STOPPED)` |
| `doPause` | 暂停 | `setState(PE_PAUSED)` |
| `getState` | 获取状态 | `getState()` |
| `update` | 更新 | `py_update()` |
| `particleSystem` | 获取当前 PS | `py_particleSystem()` |
| `aboutApp` | 关于 | `OnAppAbout()` |
| `doShortcuts` | 快捷键 | `OnAppShortcuts()` |

### 7.2 py_update 静态方法

`py_update`(L659-671)是 Python 调用 C++ 更新的入口:

```cpp
// particle_editor.cpp L659-671
PY_MODULE_STATIC_METHOD( ParticleEditorApp, update, ParticleEditor )

PyObject * ParticleEditorApp::py_update( PyObject * args )
{
	BW_GUARD;
	if (ParticleEditorApp::instance().mfApp())
    {
        // update all of the modules
        ParticleEditorApp::instance().mfApp()->updateFrame();
    }
    Py_RETURN_NONE;
}
```

### 7.3 py_particleSystem 静态方法

`py_particleSystem`(L680-689)返回当前选中的 MetaParticleSystem:

```cpp
// particle_editor.cpp L680-689
PY_MODULE_STATIC_METHOD(ParticleEditorApp, particleSystem, ParticleEditor)

PyObject *ParticleEditorApp::py_particleSystem(PyObject * args)
{
	BW_GUARD;
    if (MainFrame::instance()->IsMetaParticleSystem())
	{
        return Script::getData( new PyMetaParticleSystem(MainFrame::instance()->GetMetaParticleSystem()));
	}
```

### 7.4 GUI Python Functor

`GUI::Manager::instance().pythonFunctor().defaultModule("MenuUIAdapter")`(L403)设置 GUI Python 回调的默认模块为 `MenuUIAdapter`,允许 UI 适配层用 Python 实现。

### 7.5 C++/Python 双模式

`c_useScripting`(L144,静态常量,默认 `false`)控制更新模式:

```cpp
// particle_editor.cpp L144
static const bool c_useScripting = false;
```

- `false`(默认):C++ 模式,`update()` 调用 `mfApp_->updateFrame()`
- `true`:Python 模式,`update()` 导入 `pe_shell` 模块调用 `update()` 函数

Python 模式主要用于实验与原型开发,生产环境使用 C++ 模式。

### 7.6 强制链接 token

`particle_editor.cpp` L140-141 通过 `extern int` 强制链接 `PyModel_token`,确保 Python 模型模块被链接:

```cpp
// particle_editor.cpp L140-141
extern int PyModel_token;
static int s_particleEditorchunkTokenSet = PyModel_token;
```

类似地,`PeModule` 在 L52-65 通过 `extern int ChunkXxx_token` 强制链接 chunk 相关模块(确保静态库的 token 被引用,避免被链接器优化掉)。

---

## 八、资源管理

### 8.1 BWResource 资源系统

`particle_editor` 通过 `BWResource::init(argc, argv)`(L210)初始化资源系统,加载 `bigworld.xml` 配置的资源路径。

### 8.2 选项系统

`Options::init(argc, argv, L"particleeditor.options")`(L211)加载 `particleeditor.options` 配置文件。

### 8.3 面板布局

`PanelManager::init(mainFrame, mainView, L"particleeditor.layout")`(L424)加载 `particleeditor.layout` 面板布局文件,定义默认面板布局。

### 8.4 后台任务管理器

`particle_editor` 初始化两个后台任务管理器(L427-433):

```cpp
// particle_editor.cpp L427-433
BgTaskManager::instance().init();
BgTaskManager::instance().initWatchers( "ParticleEditor" );
BgTaskManager::instance().startThreads( 1 );

FileIOTaskManager::instance().init();
FileIOTaskManager::instance().initWatchers( "FileIO" );
FileIOTaskManager::instance().startThreads( 1 );
```

注意:与 modeleditor 相比,particle_editor 额外调用 `BgTaskManager::init()` 与 `FileIOTaskManager::init()`。

### 8.5 AssetClient 资产管线

`PeShell` 持有 `AssetClient`(pe_shell.hpp L144):

```cpp
// pe_shell.hpp L144
std::auto_ptr< AssetClient > pAssetClient_;
```

启用资产管线(`ENABLE_ASSET_PIPE`),支持后台资产编译。

### 8.6 粒子系统加载

`MainFrame::InitialiseMetaSystemRegister()`(L840)初始化粒子系统注册,扫描粒子目录加载所有 `.psv` 文件:

```cpp
// particle_editor.cpp L840
MainFrame::instance()->InitialiseMetaSystemRegister();
```

`openDirectory`(L811-842)打开粒子目录,刷新树:

```cpp
// particle_editor.cpp L811-842(节选)
void ParticleEditorApp::openDirectory(BW::string const &dir_, bool forceRefresh)
{
	BW_GUARD;
    BW::string dir = BWResource::formatPath(dir_);
    BW::string relativeDirectory = BWResource::dissolveFilename(dir);
    if (MainFrame::instance()->ParticlesDirectory() != CString(relativeDirectory.c_str()) || forceRefresh)
    {
        MainFrame::instance()->PromptSave(MB_YESNO, true);
        MainFrame::instance()->ParticlesDirectory(bw_utf8tow( relativeDirectory ).c_str());
        ParticleEditorDoc::instance().SetTitle(bw_utf8tow( relativeDirectory ).c_str());
        MainFrame::instance()->PotentiallyDirty( false );       
        MainFrame::instance()->InitialiseMetaSystemRegister();
    }
}
```

### 8.7 辅助模型加载

`PeModule::loadHelperModel(name)`(声明于 pe_module.hpp L75)加载辅助模型,用于硬点定位:

```cpp
// pe_module.hpp L93-97(成员)
bool						drawHelperModel_;                 // 是否绘制
BW::string					helperModelName_;                 // 模型名
ModelPtr					helperModel_;                     // 模型对象
BW::vector<BW::string>		helperModelHardPointNames_;       // 硬点名称
BW::vector<Matrix>			helperModelHardPointTransforms_;  // 硬点变换
```

`helperModelCenterOnHardPoint(idx)`(L49)将相机居中到指定硬点。

### 8.8 退出清理

`InternalExitInstance`(L484-529)按逆序销毁:

```
ShortcutsDlg::cleanup()                  清理快捷键对话框
GizmoManager::removeAllGizmo()          移除所有 Gizmo
ToolManager::popTool()(循环)            弹出所有工具
MsgHandler::fini()                      销毁消息处理器
PanelManager::fini()                    销毁面板管理器
mfApp_->fini() + delete mfApp_          销毁 App
delete m_peApp                          销毁 PeApp
m_appShell->fini() + delete m_appShell  销毁 Shell
GUI::Manager::fini()                    销毁 GUI 管理器
WindowTextNotifier::fini()             销毁窗口文本通知器
Options::fini()                         保存并销毁选项
Name::fini()                            销毁名称系统
BWResource::fini()                      销毁资源系统
DataSectionCensus::fini()               销毁 DataSection 普查
delete [] s_lpCmdLine                   释放命令行副本
```

---

## 九、配置项与命令行参数

### 9.1 命令行参数

| 参数 | 说明 |
|------|------|
| `-o <粒子文件>` | 启动时加载指定粒子系统文件 |
| `-O <粒子文件>` | 同 `-o`(大写变体) |
| `/RegServer` `/Register` `/Unregserver` `/Unregister` | MFC 标准注册命令 |

命令行解析在 `InitialiseMF`(L183-212)中完成,`-o` 参数存入 `openFile`,启动后调用 `openDirectory` + `SelectParticleSystem` 加载。

### 9.2 配置项(particleeditor.options)

| 配置键 | 类型 | 说明 |
|--------|------|------|
| `currentLanguage` | string | 当前语言 ISO 代码 |
| `currentCountry` | string | 当前国家 ISO 代码 |
| `language` | 多值 | 多语言文件列表 |
| `render/useUmbra` | int | Umbra 开关(强制禁用) |
| `help/shortcutsHtml` | string | 快捷键帮助 HTML |

### 9.3 面板布局(particleeditor.layout)

`particleeditor.layout` 文件定义默认面板布局,包含:
- 侧边面板(ActionSelection)
- UAL 面板
- Messages 面板
- 各面板的位置/尺寸/可见性

`PanelManager::loadDefaultPanels` 加载此布局。

### 9.4 帧率配置

`m_desiredFrameRate`(L100,默认 60.0f)控制帧率限制:

```cpp
// particle_editor.hpp L41
void setFrameRate(float rate) { m_desiredFrameRate = rate; }    // No more frame limiting (Bug 4834)
```

注释提到 "Bug 4834",说明帧率限制曾有问题。`setFrameRate` 允许动态调整,设为 0 则禁用限制。

---

## 十、与其他模块的依赖关系

### 10.1 依赖库列表

`particle_editor` 通过 `CMakeLists.txt` 链接以下库:

| 依赖库 | 用途 |
|--------|------|
| `appmgr` | `App`/`Options`/`Module`/`FrameworkModule` 应用管理 |
| `chunk` | `ChunkManager`/`ChunkSpace`/`ChunkLoader`/`ChunkUmbra` 区块管理 |
| `chunk_scene_adapter` | 区块场景适配 |
| `controls` | `TreeControl`/`ColorPicker` 等控件 |
| `cstdmf` | `BgTaskManager`/`FileIOTaskManager`/`Debug`/`BWResource` 基础设施 |
| `gizmo` | `GizmoManager`/`ToolManager`/`UndoRedo` Gizmo 与撤销管理 |
| `guimanager` | `GUI::Manager`/`GUI::ActionMaker`/`GUI::UpdaterMaker`/`GUI::OptionMap` GUI 框架 |
| `moo` | `Moo::rc`/`Renderer`/`EffectMaterial`/`DrawContext` 渲染核心 |
| `particle` | `ParticleSystem`/`MetaParticleSystem`/`ParticleSystemAction`/`PyMetaParticleSystem` 粒子系统 |
| `post_processing` | `PostProcessing::Manager` 后处理 |
| `romp` | `RompHarness`/`TimeOfDay`/`LensEffectManager` 环境 |
| `tools_common` | `Floor`/`ToolsCamera`/`BaseMainFrame`/`BasePanelManager`/`RompHarness`/`Utilities` 工具公共 |
| `ual` | `UalManager`/`UalDialog` 统一资产定位器 |
| `fmodsound` | 声音(可选) |

### 10.2 不依赖的库(与 modeleditor 对比)

| 库 | modeleditor | particle_editor | 原因 |
|----|-------------|-----------------|------|
| `modeleditor_core` | ✅ | ❌ | ParticleEditor 是单体应用,无壳/核分离 |
| `pyscript` | ✅ | ❌(直接用 Python.h) | ParticleEditor 直接使用 `pyscript` 头文件但通过 `PY_MODULE_FUNCTION` |
| `terrain` | ✅ | ❌ | ParticleEditor 不编辑地形(但 `PeShell` 持有 `Terrain::Manager`) |
| `physics2` | ✅ | ❌ | ParticleEditor 不需要物理(BSP) |
| `nvmeshmender` | ✅ | ❌ | ParticleEditor 不需要网格处理 |
| `resmgr` | ✅ | ✅ | 两者都用 `BWResource` |
| `input` | ✅ | ✅(通过 FrameworkModule) | 两者都处理输入 |

注意:虽然 `PeShell` 持有 `Terrain::Manager`,但 `particle_editor` 不直接依赖 `terrain` 库(通过 `tools_common` 间接引用)。

### 10.3 依赖关系图

```
                ┌──────────────────────┐
                │  particle_editor     │ (单体应用, ~100 文件)
                └──────────┬───────────┘
                           │
       ┌───────────────────┼───────────────────┐
       │                   │                   │
       ▼                   ▼                   ▼
┌────────────┐    ┌──────────────┐    ┌──────────────┐
│ particle   │    │ editor_shared│    │ tools_common │
│(Particle-  │    │(IEditorApp/  │    │(Floor/Tools- │
│ System/    │    │ BaseMain-    │    │  Camera/     │
│ MetaPS/    │    │  Frame/Base- │    │  RompHarness)│
│ PSA)       │    │  PanelMgr)   │    └──────┬───────┘
└──────┬─────┘    └──────────────┘           │
       │                                     │
       ▼                                     ▼
┌────────────┐    ┌──────────────┐    ┌──────────────┐
│ moo        │    │ guimanager   │    │ appmgr       │
│(Renderer/  │    │(GUI::Manager)│    │(App/Options) │
│ DrawContext)│   └──────────────┘    └──────────────┘
└──────┬─────┘
       │
       ▼
┌────────────────────────────────────────┐
│ chunk(ChunkManager/ChunkSpace)         │
│ chunk_scene_adapter                    │
│ controls(TreeControl/ColorPicker)      │
│ gizmo(GizmoManager/UndoRedo)           │
│ romp(RompHarness/LensEffectManager)    │
│ post_processing(PostProcessing::Mgr)   │
│ ual(UalManager)                        │
│ cstdmf(BgTaskMgr/Debug)                │
│ resmgr(BWResource)                     │
│ fmodsound(可选)                        │
└────────────────────────────────────────┘
```

---

## 十一、关键代码片段

### 11.1 应用对象与双模式标志

```cpp
// particle_editor.cpp L140-147
extern int PyModel_token;
static int s_particleEditorchunkTokenSet = PyModel_token;

// Update via python script:
static const bool c_useScripting = false;

// The one and only ParticleEditorApp object:
ParticleEditorApp theApp;
```

### 11.2 状态枚举与构造函数

```cpp
// particle_editor.hpp L47-56
    enum State
    {
        PE_PLAYING,
        PE_PAUSED,
        PE_STOPPED
    };

    void setState(State state);
    State getState() const;
```

```cpp
// particle_editor.cpp L154-167
ParticleEditorApp::ParticleEditorApp() :
	m_appShell(NULL),
	m_peApp(NULL),
	mfApp_( NULL ),
	m_desiredFrameRate(60.0f),
	m_state(PE_PLAYING)
{
	BW_GUARD;
    ASSERT(s_instance == NULL);
    s_instance = this;
	MsgHandler::instance();
}
```

### 11.3 三层运行时装配

```cpp
// particle_editor.cpp L372-396
ASSERT(!mfApp_);
mfApp_ = new App;

ASSERT(!m_appShell);
m_appShell = new PeShell;    

HINSTANCE hInst = AfxGetInstanceHandle();
if 
(
    !mfApp_->init
    ( 
        hInst, 
        mainFrame->m_hWnd, 
        mainView->m_hWnd, 
		NULL,
        PeShell::initApp 
    )
)
{
    ERROR_MSG( "ParticleEditorApp::InitInstance - init failed\n" );
    return FALSE;
}

m_peApp = new PeApp();
```

### 11.4 GUI 装配与 Python Functor

```cpp
// particle_editor.cpp L398-424
CooperativeMoo::init();
GUI::Manager::init();

// Must do this after the panels are inited, they init GUI::Manager.
GUI::Manager::instance().pythonFunctor().defaultModule( "MenuUIAdapter" );
GUI::Manager::instance().optionFunctor().setOption(this);
DataSectionPtr section = BWResource::openSection("resources/data/gui.xml");
for (int i = 0; i < section->countChildren(); ++i)
	GUI::Manager::instance().add(new GUI::Item(section->openChild(i)));

menuHelper_.reset( new GUI::MenuHelper( mainFrame->GetSafeHwnd() ) );
GUI::Manager::instance().add(new GUI::Menu("MainMenu", menuHelper_.get() ));

updateLanguageList();
AfxGetMainWnd()->DrawMenuBar();
mainFrame->createToolbars( "AppToolbars" );
PanelManager::init(mainFrame, mainView, L"particleeditor.layout");		
```

### 11.5 状态机实现

```cpp
// particle_editor.cpp L740-784
void ParticleEditorApp::setState(State state)
{
	BW_GUARD;
    MainFrame *mainFrame = MainFrame::instance();
    switch (state)
    {
    case PE_PLAYING:
		mfApp_->pause( false );
		{
			bool restart = m_state != PE_PAUSED;
			if (m_state == PE_PLAYING)
			{
				size_t numAppendPS = mainFrame->numberAppendPS();
				mainFrame->appendOneWayPS();
				restart = numAppendPS == mainFrame->numberAppendPS();
			}
			if (restart)
			{
				if (mainFrame->IsMetaParticleSystem())
				{
					mainFrame->GetMetaParticleSystem()->clear(); 
					mainFrame->GetMetaParticleSystem()->spawn(); 
				}
			}
		}
        break;
    case PE_STOPPED:
        mfApp_->pause( true );
        if (mainFrame->IsMetaParticleSystem())
		{
			mainFrame->GetMetaParticleSystem()->clear();
			mainFrame->GetMetaParticleSystem()->setFirstUpdate();
			LensEffectManager::instance().clear();
			mainFrame->clearAppendedPS();
		}
        break;
    case PE_PAUSED:
        mfApp_->pause( true );
        break;
    }
    m_state = state;
}
```

### 11.6 OnIdle 帧率限制

```cpp
// particle_editor.cpp L565-619
BOOL ParticleEditorApp::OnIdle(LONG lCount)
{
	BW_GUARD;
	if ( CWinApp::OnIdle( lCount ) )
		return TRUE;

    HWND foreWindow = GetForegroundWindow();
    CWnd *mainFrame = MainFrame::instance();
	bool isWindowActive =
		foreWindow == mainFrame->m_hWnd || GetParent( foreWindow ) == mainFrame->m_hWnd;

	if ( !CooperativeMoo::canUseMoo( this, isWindowActive ) || !isWindowActive )
    {
		mfApp_->calculateFrameTime();
    }
    else
    {
		uint64 beforeTime = timestamp();
		update();
		uint64 afterTime = timestamp();
		float lastUpdateMilliseconds = (float) (((int64)(afterTime - beforeTime)) / stampsPerSecondD()) * 1000.f;

        if (m_desiredFrameRate > 0)
        {
            const float desiredFrameTime = 1000.f/m_desiredFrameRate;
            float lastFrameTime = PeModule::instance().lastTimeStep();
            if (desiredFrameTime > lastUpdateMilliseconds)
            {
                float compensation = desiredFrameTime - lastUpdateMilliseconds;
                compensation = std::min(compensation, 2000.f);
                Sleep((int)compensation);
            }
            MainFrame::instance()->UpdateGUI();
        }
    }
    return TRUE;
}
```

### 11.7 update() 双模式

```cpp
// particle_editor.cpp L622-652
void ParticleEditorApp::update()
{
	BW_GUARD;
    if (!c_useScripting)
    {
        mfApp_->updateFrame();        
    }
    else
    {
        PyObject *pScript     = PyImport_ImportModule("pe_shell");
        PyObject *pScriptDict = PyModule_GetDict(pScript);
        PyObject *pUpdate     = PyDict_GetItemString(pScriptDict, "update");
        if (pUpdate != NULL)
        {
            PyObject * pResult = PyObject_CallFunction(pUpdate, "");
            if (pResult != NULL)
            {
                Py_DECREF( pResult );
            }
            else
            {
                PyErr_Print();
            }
        }
        else
        {
            PyErr_Print();
        }
    }
}
```

### 11.8 UndoRedoOp 撤销操作

```cpp
// undoredo_op.hpp L9-72
class UndoRedoOp : public UndoRedo::Operation
{
public:
    enum ActionKind
    {
        AK_PARAMETER,
        AK_NPARAMETER
    };

	UndoRedoOp( ActionKind actionKind, DataSectionPtr data );
	~UndoRedoOp();

	/*virtual*/ void undo();
	/*virtual*/ bool iseq(Operation const &other) const;
	DataSectionPtr data() const;
protected:
	bool XmlSectionsAreEq( DataSectionPtr const &one, DataSectionPtr const &two ) const;
private:
	DataSectionPtr	        data_;
};
```

### 11.9 MetaNode 三层树根节点

```cpp
// ps_node.hpp L17-55
class MetaNode : public TreeNode
{
public:
    MetaNode(BW::string const &dir, BW::string const &filename);
    /*virtual*/ ~MetaNode();
    /*virtual*/ void SetLabel(BW::string const &label);
    /*virtual*/ bool CanEditLabel() const;
    /*virtual*/ DROPEFFECT CanDragDrop() const;        // 仅 DROPEFFECT_COPY
    MetaParticleSystemPtr GetMetaParticleSystem() const;
    void SetMetaParticleSystem(MetaParticleSystemPtr system);
    void SetReadOnly(bool readOnly);
    bool IsReadOnly() const;
    void EnsureLoaded() const;
    BW::string GetFilename() const;
    BW::string const &GetDirectory() const;
    BW::string GetFullpath() const;
    bool DeleteFile();
    void FlagChildrenReady();
    void onSave();
    void onNotSave();
    void onRename();
    /*virtual*/ void OnExpand();
```

### 11.10 ActionNode ActionType

```cpp
// ps_node.hpp L273-297
class ActionNode : public TreeNode
{
public:
    enum ActionType
    {
        AT_ACTION,              // 实际动作(PSA)
        AT_SYS_PROP,            // 系统属性
        AT_REND_PROP,           // 渲染属性
		AT_META_PS,				// Meta PS
		AT_PS					// PS
    };

    ActionNode( ParticleSystemActionPtr action, BW::string const &name,
        ActionType actionType = AT_ACTION);
    /*virtual*/ DROPEFFECT CanDragDrop() const;        // DROPEFFECT_COPY
    ParticleSystemActionPtr getAction();
    ActionType getActionType();
    /*virtual*/ bool CanEditLabel() const;             // false
```

### 11.11 PeShell 持有的子系统

```cpp
// pe_shell.hpp L131-158
private:    
    static PeShell      *s_instance_;
    bool                inited_;
    HINSTANCE           hInstance_;
    HWND                hWndApp_;
    HWND                hWndGraphics_;
    RompHarness         *romp_;
    ToolsCameraPtr      camera_;
    Floor*              floor_;
    ChunkSpacePtr       space_;
    std::auto_ptr<Renderer> m_renderer;
    std::auto_ptr< AssetClient > pAssetClient_;
    FontManagerPtr pFontManager_;
    TextureFeedsPtr pTextureFeeds_;
    TerrainManagerPtr pTerrainManager_;
    PostProcessingManagerPtr pPostProcessingManager_;
    LensEffectManagerPtr pLensEffectManager_;
```

### 11.12 PeModule 辅助模型

```cpp
// pe_module.hpp L46-53
	const BW::string &helperModelName() const;
	bool helperModelName( const BW::string &name );
	BW::vector<BW::string> &getHelperModelHardPointNames() { return helperModelHardPointNames_; }
	void helperModelCenterOnHardPoint(uint idx);
	uint helperModelCenterOnHardPoint() const;
	void drawHelperModel(bool draw);
	bool drawHelperModel() const { return drawHelperModel_; }
```

### 11.13 命令行文件加载

```cpp
// particle_editor.cpp L464-476
if ( !openFile.empty() )
{
	openDirectory( BWResource::getFilePath( openFile ) );
	update();
	BW::StringRef psName = BWResource::getFilename( openFile );
	psName = BWResource::removeExtension( psName );
    bool ok =
		((MainFrame*)AfxGetMainWnd())->SelectParticleSystem( psName.to_string() );
    if (!ok)
    {
        AfxMessageBox(Localise(L"RCS_IDS_COULDNTOPENFILE", openFile));
    }
}
```

---

## 十二、设计亮点与注意事项

### 12.1 设计亮点

| 亮点 | 说明 |
|------|------|
| **C++/Python 双模式** | `c_useScripting` 标志切换更新模式,Python 模式便于原型开发与实验 |
| **三态状态机** | `PE_PLAYING`/`PE_PAUSED`/`PE_STOPPED` 清晰管理粒子播放状态,支持追加一次性 PS |
| **三层粒子系统树** | MetaNode→PSNode→ActionNode 对应 MetaPS→PS→PSA,层次清晰 |
| **16 种 PSA 对话框** | 每种 PSA 有专属属性对话框,继承 `PsaProperties`,扩展性好 |
| **帧率限制 OnIdle** | `m_desiredFrameRate` + `Sleep` 补偿,避免 CPU 占用过高(对比 modeleditor 无限制) |
| **DataSection 撤销快照** | `UndoRedoOp` 保存 DataSection 快照,`XmlSectionsAreEq` 逐位比较,可靠 |
| **PotentiallyDirty 智能脏标志** | 区分 `AK_PARAMETER`/`AK_NPARAMETER`,支持 `waitForLButtonUp` 拖拽场景 |
| **辅助模型硬点** | `PeModule` 加载 helper model,定位 hard points,辅助粒子放置 |
| **多组 ActionMaker/UpdaterMaker** | PanelManager 多组继承,支持 show/hide/Language 三组动作与四组更新 |
| **强制链接 token** | `extern int Xxx_token` 确保 chunk/Python 模块被链接 |
| **GUITABS 布局持久化** | `particleeditor.layout` 保存面板布局,支持撕离 |

### 12.2 注意事项

| 注意点 | 说明 |
|--------|------|
| **c_useScripting 默认 false** | 生产环境使用 C++ 模式,Python 模式仅用于实验 |
| **m_desiredFrameRate 默认 60** | 帧率限制默认 60fps,可通过 `setFrameRate(0)` 禁用 |
| **Sleep 上限 2000ms** | 帧率补偿 `Sleep` 上限 2000ms,避免长时间休眠 |
| **CooperativeMoo 协作** | 窗口不活动时仅 `calculateFrameTime()` 冻结时间 |
| **Umbra 强制禁用** | 与 modeleditor 相同,强制 `render/useUmbra=0` 解决鼠标延迟 |
| **appendOneWayPS** | `PE_PLAYING` 状态下再次播放会追加一次性 PS,而非重启 |
| **LensEffectManager::clear** | `PE_STOPPED` 时清除光晕,避免残留 |
| **MainFrame 业务核心** | 与 modeleditor 不同,`MainFrame` 承担大量业务(选择/撤销/视角/背景色/追加 PS) |
| **PeShell 持有 Floor/ChunkSpace** | 与 `MeShell` 不同,`PeShell` 直接持有 `Floor`/`ChunkSpace`(而非聚合在 MeApp) |
| **无 IModelEditorApp 接口** | 单体应用,无壳/核分离,直接继承 `IEditorApp` |
| **pythonFunctor 默认模块** | `MenuUIAdapter` 是 UI 适配层 Python 模块 |
| **PeModule 强制链接 chunk token** | L52-65 通过 `extern int ChunkXxx_token` 强制链接 chunk 模块 |

### 12.3 与 modeleditor 的对比

| 维度 | particle_editor | modeleditor + modeleditor_core |
|------|-----------------|--------------------------------|
| 架构 | 单体应用(~100 文件) | 壳/核分离(6 + ~80 文件) |
| 核心对象 | `MainFrame` + `PeModule` | `Mutant`(7 文件拆分) |
| 数据模型 | `MetaParticleSystem`/`ParticleSystem` | `DataSection`(XML) |
| 状态机 | `PE_PLAYING`/`PE_PAUSED`/`PE_STOPPED` | 无(始终运行) |
| 更新模式 | C++/Python 双模式(`c_useScripting`) | 仅 C++(通过 MEPythonAdapter) |
| 帧率限制 | `m_desiredFrameRate` + `Sleep` | 无(依赖 CooperativeMoo) |
| 撤销重做 | `UndoRedoOp`(DataSection 快照) | `UndoRedo` + `UndoRedoOp`(DataSection 快照) |
| 属性编辑 | 16 种 PSA 对话框 + 3 种 PS 属性 | 7 个属性页面(PropertyTable) |
| Python 模块 | `ParticleEditor` | `ModelEditor` |
| 树结构 | MetaNode/PSNode/ActionNode 三层 | TreeRoot(动画/动作/材质) |
| 热重载 | 无 | `ReloadListener` |
| 辅助模型 | helper model + hard points | 无 |
| 接口 | `IEditorApp`(直接) | `IModelEditorApp`(壳/核解耦) |
| PanelManager | 多组 ActionMaker/UpdaterMaker(语言/UAL/Messages) | 单组 ActionMaker/UpdaterMaker |

### 12.4 状态机使用建议

| 场景 | 推荐状态 | 说明 |
|------|----------|------|
| 编辑粒子参数 | `PE_PLAYING` | 实时观察参数效果 |
| 调整相机视角 | `PE_PAUSED` | 暂停粒子,便于观察 |
| 重置粒子 | `PE_STOPPED` | 清空所有粒子,重新开始 |
| 预览一次性 PS | `PE_PLAYING` + 再次播放 | 追加一次性 PS |

### 12.5 PSA 扩展指南

若需添加新的 PSA(Particle System Action):

1. 在 `particle` 库实现 `ParticleSystemAction` 子类
2. 在 `gui/propdlgs/` 创建 `psa_<name>_properties.hpp/.cpp`,继承 `PsaProperties`
3. 在 `ActionNode::ActionType` 添加新类型(若需要)
4. 在 `ActionSelection` 注册新 PSA 的创建/选择
5. 在 `VectorGeneratorProxies` 添加向量生成器代理(若需要)
6. 更新 `gui.xml` 添加菜单项

---

## 总结

`particle_editor` 是 BigWorld 工具链中**粒子编辑器单体应用**,约 100 文件,承担粒子系统的创建、编辑、预览、保存等全部职责。其核心价值在于:

1. **C++/Python 双模式**:`c_useScripting` 标志切换更新模式,Python 模式便于原型开发。
2. **三态状态机**:`PE_PLAYING`/`PE_PAUSED`/`PE_STOPPED` 清晰管理播放状态,支持追加一次性 PS。
3. **三层粒子系统树**:MetaNode→PSNode→ActionNode 对应 MetaPS→PS→PSA,层次清晰,扩展性好。
4. **16 种 PSA 对话框**:每种粒子动作有专属属性对话框,覆盖全部粒子行为。
5. **帧率限制 OnIdle**:`m_desiredFrameRate` + `Sleep` 补偿,避免 CPU 占用过高。
6. **DataSection 撤销快照**:`UndoRedoOp` 保存快照,`XmlSectionsAreEq` 逐位比较,可靠。
7. **辅助模型硬点**:`PeModule` 加载 helper model,辅助粒子放置。

与 `modeleditor` 的壳/核分离不同,`particle_editor` 采用单体架构,`MainFrame` 承担大量业务逻辑,适合规模较小、无需复用的场景。

---

**参考源文件**:
- `programming/bigworld/tools/particle_editor/particle_editor.hpp`(L1-110)
- `programming/bigworld/tools/particle_editor/particle_editor.cpp`(L1-1583+)
- `programming/bigworld/tools/particle_editor/main_frame.hpp`(L1-213)
- `programming/bigworld/tools/particle_editor/undoredo_op.hpp`(L1-76)
- `programming/bigworld/tools/particle_editor/shell/pe_shell.hpp`(L1-163)
- `programming/bigworld/tools/particle_editor/shell/pe_module.hpp`(L1-102)
- `programming/bigworld/tools/particle_editor/gui/ps_node.hpp`(L1-331)
- `programming/bigworld/tools/particle_editor/gui/panel_manager.hpp`(L1-82)
