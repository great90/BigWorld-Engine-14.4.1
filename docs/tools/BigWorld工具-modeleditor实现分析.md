# BigWorld 工具 modeleditor 实现深度分析

> 本文档详细分析 BigWorld Engine 14.4.1 中 ModelEditor(模型编辑器启动壳)的完整实现。ModelEditor 是一个**极薄启动壳**(仅 6 个文件),它本身不承载任何模型编辑业务逻辑,所有职责都委托给 `modeleditor_core` 核心库。它的核心使命是:完成 MFC SDI 应用程序初始化、解析命令行、装配 App/Shell/Module 三层运行时、注册 GUI/UAL/PanelManager、驱动 OnIdle 主循环,以及完成崩溃恢复与最近模型加载。本文档涵盖架构定位、目录组织、启动流程、命令行与配置、OnIdle 主循环、崩溃恢复机制、依赖关系等内容。

---

## 目录

- [一、整体架构概览](#一整体架构概览)
- [二、源码目录结构](#二源码目录结构)
- [三、入口点与启动流程](#三入口点与启动流程)
- [四、核心类与继承关系](#四核心类与继承关系)
- [五、关键算法与数据结构](#五关键算法与数据结构)
- [六、GUI 框架集成](#六gui-框架集成)
- [七、Python 脚本集成](#七python-脚本集成)
- [八、资源管理](#八资源管理)
- [九、配置项与命令行参数](#九配置项与命令行参数)
- [十、与其他模块的依赖关系](#十与其他模块的依赖关系)
- [十一、关键代码片段](#十一关键代码片段)
- [十二、设计亮点与注意事项](#十二设计亮点与注意事项)

---

## 一、整体架构概览

### 1.1 modeleditor 在工具链中的定位

`modeleditor` 是 BigWorld 工具链中**模型编辑器**的可执行入口,位于 `programming/bigworld/tools/modeleditor/`。它是一个**极薄启动壳(Thin Shell)**,代码量极小(6 个文件),其设计哲学是:

1. **壳/核分离**:启动壳只负责 MFC 应用框架装配与主循环驱动,所有模型编辑业务(模型加载、动画/动作/LOD/材质编辑、渲染、验证、Python 暴露)全部下沉到 `modeleditor_core` 静态库。
2. **接口反向依赖**:壳通过 `IModelEditorApp` 抽象接口持有核心库,核心库通过接口回调壳(例如 `modelToLoad()`、`updateRecentList()`),避免核心库反向依赖壳。
3. **三层运行时**:启动壳装配 `App`(应用管理)+ `MeShell`(图形/脚本/控制台/ROMP 外壳)+ `MeModule`(渲染模块)三层结构,与 WorldEditor/ParticleEditor 保持一致的工具架构。
4. **MFC SDI 框架**:基于 `CWinApp` + `CSingleDocTemplate`,文档/视图/主框架三件套,深度集成 Win32。
5. **崩溃恢复**:通过 `startup/lastLoadOK` 标志位检测上次加载是否崩溃,自动从 MRU 列表移除崩溃模型并提示用户。

### 1.2 整体架构拓扑

```
┌────────────────────────────────────────────────────────────────────┐
│                  modeleditor 进程 (MFC SDI, 6 文件极薄壳)          │
│                                                                    │
│  ┌──────────────────┐   ┌──────────────────┐   ┌────────────────┐  │
│  │ CModelEditorApp  │   │   CMainFrame      │   │ PanelManager   │  │
│  │ (CWinApp +       │──▶│ (BaseMainFrame +  │──▶│ (GUI 面板/工具栏)│  │
│  │  OptionMap +     │   │   IMainFrame +    │   │                │  │
│  │  IModelEditorApp)│   │   ActionMaker +   │   │                │  │
│  │                  │   │   UpdaterMaker)   │   │                │  │
│  └────────┬─────────┘   └────────┬──────────┘   └────────────────┘  │
│           │                      │                                   │
│           │ new App              │ CModelEditorView (3D 视口)         │
│           │ new MeShell          │                                   │
│           │ new MeApp            │                                   │
│           │ new MEPythonAdapter  │                                   │
│           ▼                      ▼                                   │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │              三层运行时(App / Shell / Module)              │   │
│  │                                                              │   │
│  │  App (appmgr)        → 通用应用管理(计时/输入/模块调度)     │   │
│  │      │                                                       │   │
│  │      ▼                                                       │   │
│  │  MeShell             → 图形/脚本/控制台/ROMP/相机/声音/      │   │
│  │      │                  FontManager/TextureFeeds/            │   │
│  │      │                  Terrain::Manager/PostProcessing/     │   │
│  │      │                  LensEffectManager/AssetClient         │   │
│  │      ▼                                                       │   │
│  │  MeModule            → 渲染模块(render/renderThumbnail/      │   │
│  │                          renderChunks/renderTerrain/          │   │
│  │                          renderOpaque/renderFixedFunction/    │   │
│  │                          updateModel/setLights)               │   │
│  │      │                                                       │   │
│  │      ▼                                                       │   │
│  │  MeApp               → 聚合 Floor/Mutant/Lights/             │   │
│  │                          ToolsCamera/blackLight/whiteLight    │   │
│  └──────────────────────────────────────────────────────────────┘   │
│           │                                                          │
│           │ 委托                                                    │
│           ▼                                                          │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │           modeleditor_core 静态库(~80 文件)                │   │
│  │  Mutant(模型/动画/动作/LOD/材质/渲染/验证,7文件拆分)        │   │
│  │  Pages(7 个属性页面) + GUI + App 层 + Python 集成            │   │
│  └──────────────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────────────┘
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
      ┌──────────────┐ ┌─────────────┐ ┌──────────────┐
      │ AssetClient  │ │ BgTaskMgr   │ │ Python 脚本  │
      │ (资产管线)   │ │ (后台线程)  │ │ (MEPython-   │
      │              │ │             │ │  Adapter)    │
      └──────────────┘ └─────────────┘ └──────────────┘
```

### 1.3 关键设计原则

| 原则 | 说明 |
|------|------|
| **极薄壳模式** | 启动壳仅 6 文件,所有业务委托 `modeleditor_core`,实现壳/核解耦 |
| **接口反转** | 通过 `IModelEditorApp` 抽象接口,核心库不反向依赖壳,支持单元测试与复用 |
| **三层运行时** | `App`/`MeShell`/`MeModule`/`MeApp` 分层装配,与 WorldEditor/ParticleEditor 保持架构一致性 |
| **MFC SDI 框架** | `CWinApp` + `CSingleDocTemplate` + 文档/视图/主框架三件套 |
| **OnIdle 主循环** | 复用 MFC `OnIdle` 驱动渲染与模型加载,通过 `CooperativeMoo::canUseMoo` 协作式占用 GPU |
| **崩溃恢复** | `startup/lastLoadOK` 标志位 + MRU 列表自动移除崩溃模型 |
| **异常过滤器** | `CallWithExceptionFilter` 包裹 `InitInstance`/`Run`/`ExitInstance`,捕获崩溃并生成 dump |
| **Umbra 强制禁用** | 启动时强制 `render/useUmbra=0`,解决鼠标延迟(GPU 停滞问题) |

### 1.4 规模与组成

`modeleditor` 源码位于 `programming/bigworld/tools/modeleditor/`,由 `CMakeLists.txt` 组织,**单一可执行文件** `modeleditor`(通过 `BW_ADD_TOOL_EXE`),文件清单如下:

| 文件 | 行数(估) | 职责 |
|------|-----------|------|
| `GUI/model_editor.h` | ~104 | `CModelEditorApp` 类声明,继承 `CWinApp` + `GUI::OptionMap` + `IModelEditorApp` |
| `GUI/model_editor.cpp` | ~916 | 启动壳主体:`InitInstance`/`OnIdle`/`ExitInstance`/命令行解析/菜单回调 |
| `pch.hpp` / `pch.cpp` | - | 预编译头 |
| `modeleditor.rc` | - | MFC 资源文件(菜单/图标/字符串表) |
| `CMakeLists.txt` | - | 构建脚本,链接 `modeleditor_core` 等依赖库 |

**核心文件 `model_editor.cpp` 约 916 行**,承担全部启动壳职责。

---

## 二、源码目录结构

```
programming/bigworld/tools/modeleditor/
├── CMakeLists.txt              # 构建脚本(BW_ADD_TOOL_EXE)
├── pch.hpp                     # 预编译头
├── pch.cpp                     # 预编译头实现
├── modeleditor.rc              # MFC 资源(菜单/图标/字符串表/对话框)
└── GUI/
    ├── model_editor.h          # CModelEditorApp 类声明(L31-101)
    └── model_editor.cpp        # 启动壳主体(L1-916)
```

启动壳仅 6 个文件,极致精简。所有模型编辑能力(模型加载/动画/动作/LOD/材质/渲染/验证/Python 暴露)由 `modeleditor_core` 静态库提供,启动壳通过 `IModelEditorApp` 接口持有核心库。

---

## 三、入口点与启动流程

### 3.1 入口点与全局实例

启动壳的入口点是 MFC 标准的 `CWinApp` 全局实例。在 `model_editor.cpp` 第 99 行定义了唯一的应用程序对象:

```cpp
// model_editor.cpp L99
CModelEditorApp theApp;
```

`CModelEditorApp` 构造函数(L134-145)完成两项早期初始化:

```cpp
// model_editor.cpp L134-145
CModelEditorApp::CModelEditorApp():
	mfApp_(NULL),
	initDone_( false ),
	pPythonAdapter_(NULL)
{
	BW_GUARD;
	EnableHtmlHelp();
	//Instanciate the Message handler to catch BigWorld messages
	MsgHandler::instance();
}
```

### 3.2 InitInstance 启动流程

`InitInstance`(L175-191)是 MFC 应用程序的主入口,它通过 `CallWithExceptionFilter` 包裹 `InternalInitInstance`,确保崩溃时生成 dump:

```cpp
// model_editor.cpp L175-191
BOOL CModelEditorApp::InitInstance()
{
	BW::Allocator::setSystemStage( BW::Allocator::SS_MAIN );
	BOOL result = CallWithExceptionFilter( this, &CModelEditorApp::InternalInitInstance );
	if (!result)
	{
		MessageBox( NULL,
			L"ModelEditor failed to initailise itself correctly, please check the debug log for detailed information.",
			L"ModelEditor", MB_OK );
	}
	return result;
}
```

### 3.3 InternalInitInstance 完整启动序列

`InternalInitInstance`(L206-452)是启动流程的核心,执行序列如下:

```
Name::init()                              L210  名称系统初始化
waitForRestarting()                       L212  等待重启(崩溃后自动重启)
SetCursor(IDC_WAIT)                       L215  设置等待光标
CWinApp::InitInstance()                   L217  MFC 基类初始化
s_pCmdLine = copy(m_lpCmdLine)            L219-222  保存命令行副本
AfxOleInit()                              L225  OLE 初始化(拖放支持)
CSingleDocTemplate(SDI)                   L242-248  注册文档模板
  ├─ IDR_MAINFRAME
  ├─ RUNTIME_CLASS(CModelEditorDoc)
  ├─ RUNTIME_CLASS(CMainFrame)
  └─ RUNTIME_CLASS(CModelEditorView)
parseCommandLineMF()                      L265  解析命令行(-o/-O 模型路径)
  ├─ BWResource::init
  └─ Options::init(modeleditor.options)
StringProvider::load(语言文件)           L268-292  加载多语言资源
WindowTextNotifier::instance()            L294
CooperativeMoo::init()                    L296  Moo 协作式初始化
GUI::Manager::init()                      L298  GUI 管理器初始化
ProcessShellCommand(cmdInfo)              L303  分发命令行命令(创建主窗口)
m_pMainWnd->ShowWindow(SW_SHOWMAXIMIZED)  L311  显示主窗口
mfApp_ = new App                          L316  创建应用管理器
meShell_ = new MeShell                    L319  创建 Shell
mfApp_->init(hInst, hWnd, mainView,       L323-329  App 初始化
            mainFrame, MeShell::initApp)
  └─ MeShell::initApp → MeShell::init
     ├─ initGraphics (Renderer/Moo)
     ├─ initScripts (Python)
     ├─ initConsoles
     ├─ initRomp (RompHarness/TimeOfDay)
     ├─ initCamera (ToolsCamera)
     └─ initSound
meApp_ = new MeApp(mainFrame, this)       L339  创建 MeApp(聚合 Mutant)
meApp_->mutant()->setAssetClient(         L340  绑定 AssetClient
    meShell_->assetClient())
pPythonAdapter_ = new MEPythonAdapter()   L343  创建 Python 适配器
GUI::Manager::optionFunctor().setOption(this)  L346  绑定选项 Functor
GUI::Manager::add(gui.xml 子项)           L348-350  加载 GUI 项
menuHelper_ = new GUI::MenuHelper          L352  菜单助手
GUI::Manager::add(new GUI::Menu("MainMenu"))  L355-356  主菜单
updateLanguageList()                       L358  更新语言列表
mainFrame->DrawMenuBar()                   L360
mainFrame->createToolbars("AppToolbars")   L363  创建工具栏
PanelManager::init(mainFrame, mainView,    L366  面板管理器初始化
                  this, mainFrame)
UalManager::dropManager().add(...)         L369-379  注册 UAL 拖放
  ├─ model 拖放 → loadFile
  ├─ mvl 拖放 → loadFile
  └─ 空类型拖放 → loadFile
BgTaskManager::initWatchers("ModelEditor") L381  后台任务管理器
FileIOTaskManager::initWatchers("FileIO")  L382
BgTaskManager::startThreads(1)             L384  启动后台线程
FileIOTaskManager::startThreads(1)         L385
崩溃恢复检查                                L387-409  检测上次加载是否崩溃
initDone_ = true                           L420
Options::optionsFileExisted() 检查         L422-426  检查 options.xml 是否存在
UMBRA 强制禁用                              L440-447  render/useUmbra=0
Automation::parseCommandLine(m_lpCmdLine)  L449  自动化命令行解析
return TRUE                                L451
```

### 3.4 启动流程架构图

```
┌─────────────────────────────────────────────────────────────────┐
│                    CModelEditorApp::InitInstance                │
│                          (L175-191)                             │
│  CallWithExceptionFilter → InternalInitInstance                 │
└────────────────────────────┬────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│  1. 早期初始化                                                  │
│     Name::init / waitForRestarting / CWinApp::InitInstance      │
│     AfxOleInit / CSingleDocTemplate(SDI)                        │
├─────────────────────────────────────────────────────────────────┤
│  2. 命令行与配置                                                │
│     parseCommandLineMF                                          │
│       ├─ BWResource::init(argc, argv)                           │
│       └─ Options::init(argc, argv, "modeleditor.options")       │
├─────────────────────────────────────────────────────────────────┤
│  3. 多语言                                                      │
│     StringProvider::load(language files)                        │
│     setLanguage(currentLanguage, currentCountry)                │
├─────────────────────────────────────────────────────────────────┤
│  4. Moo 与 GUI                                                  │
│     CooperativeMoo::init / GUI::Manager::init                   │
│     ProcessShellCommand(创建主窗口与视图)                       │
├─────────────────────────────────────────────────────────────────┤
│  5. 三层运行时装配                                              │
│     new App → new MeShell → mfApp_->init(MeShell::initApp)      │
│     new MeApp → mutant->setAssetClient                          │
│     new MEPythonAdapter                                         │
├─────────────────────────────────────────────────────────────────┤
│  6. GUI 装配                                                    │
│     GUI::Manager optionFunctor/setOption                        │
│     加载 gui.xml → GUI::Item                                    │
│     MenuHelper + MainMenu + 语言列表                            │
│     createToolbars("AppToolbars")                               │
│     PanelManager::init(GUITABS 撕离标签)                        │
│     UalManager drop functors(model/mvl/空)                      │
├─────────────────────────────────────────────────────────────────┤
│  7. 后台线程                                                    │
│     BgTaskManager::startThreads(1)                              │
│     FileIOTaskManager::startThreads(1)                          │
├─────────────────────────────────────────────────────────────────┤
│  8. 崩溃恢复与模型加载                                          │
│     检查 startup/lastLoadOK                                     │
│     若崩溃:从 MRU 移除 + 弹错误对话框                           │
│     若未崩溃:加载 startup/loadLastModel / models/file0          │
├─────────────────────────────────────────────────────────────────┤
│  9. 收尾                                                        │
│     initDone_ = true                                            │
│     检查 options.xml 存在性                                     │
│     强制禁用 Umbra(render/useUmbra=0)                          │
│     Automation::parseCommandLine                                │
└─────────────────────────────────────────────────────────────────┘
```

---

## 四、核心类与继承关系

### 4.1 CModelEditorApp 类声明

`CModelEditorApp` 是启动壳的唯一核心类,声明于 `model_editor.h` 第 31-101 行,采用**多重继承**整合 MFC、GUI 框架与核心库接口:

```cpp
// model_editor.h L31-35
class CModelEditorApp
	: public CWinApp
	, GUI::OptionMap
	, public IModelEditorApp
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
                          │IModelEditorApp│(modeleditor_core 接口)
                          └──────┬──────┘
                                 │
                          ┌──────┴──────┐
                          │CModelEditorApp│
                          └─────────────┘
```

### 4.3 三重继承职责

| 基类 | 头文件 | 职责 |
|------|--------|------|
| `CWinApp` | MFC | MFC 应用程序框架:`InitInstance`/`OnIdle`/`ExitInstance`/`Run`/消息映射 |
| `GUI::OptionMap` | `guimanager/gui_functor_option.hpp` | GUI 选项 Functor:实现 `get`/`set`/`exist` 三个虚函数,将 GUI 选项读写委托给 `Options` 单例 |
| `IModelEditorApp` | `tools/modeleditor_core/i_model_editor_app.hpp` | 核心库反向接口:暴露 `initDone`/`mfApp`/`mainWnd`/`modelToLoad`/`updateRecentList`/`pythonAdapter`/`OnFileRegenBoundingBox`/`loadLights`/`OnAppPrefs`/`OnFileAdd`/`exit` 给核心库调用 |

### 4.4 IModelEditorApp 接口

`IModelEditorApp`(声明于 `modeleditor_core/i_model_editor_app.hpp` L13-42)是**壳/核解耦的关键**。核心库通过此接口回调壳,避免反向依赖:

```cpp
// i_model_editor_app.hpp L13-42
class IModelEditorApp
	: public IEditorApp
{
public:
	IModelEditorApp();
	virtual bool initDone() = 0;
	virtual App * mfApp() = 0;
	virtual CWnd * mainWnd() = 0;
	virtual const BW::string & modelToLoad() = 0;
	virtual void modelToLoad( const BW::string & modelName ) = 0;
	virtual void updateRecentList( const BW::string& kind ) = 0;
	virtual MEPythonAdapter* pythonAdapter() const = 0;
	virtual void OnFileRegenBoundingBox() = 0;

	//Interface for python calls
	void loadModel( const char* modelName );
	void addModel( const char* modelName );
	void OnFileReloadTextures();
	virtual void loadLights( const char* lightName ) = 0;
	virtual void OnAppPrefs() = 0;
	void OnFileOpen();
	virtual void OnFileAdd() = 0;
	virtual void exit( bool ignoreChanges = false ) = 0;

protected:
	BW::string modelToLoad_;
	BW::string modelToAdd_;
};
```

### 4.5 关键成员变量

```cpp
// model_editor.h L75-98(私有成员)
private:
	App* mfApp_;                              // 应用管理器(appmgr)
	bool initDone_;                           // 初始化完成标志
	MeShell*	meShell_;                       // Shell(图形/脚本/控制台/ROMP)
	MeApp*		meApp_;                         // MeApp(聚合 Mutant)
	PageLights* lightPage_;                   // 灯光页面
	MEPythonAdapter* pPythonAdapter_;         // Python 适配器
	std::auto_ptr< GUI::MenuHelper > menuHelper_;  // 菜单助手
	BOOL parseCommandLineMF();                // 命令行解析
	virtual BW::string get( const BW::string& key ) const;   // OptionMap
	virtual bool exist( const BW::string& key ) const;       // OptionMap
	virtual void set( const BW::string& key, const BW::string& value );  // OptionMap
	BOOL InternalInitInstance();
	int InternalExitInstance();
	int InternalRun();
	IMainFrame * getMainFrame();
```

### 4.6 OptionMap 实现

`CModelEditorApp` 实现 `GUI::OptionMap` 的三个虚函数,将 GUI 选项读写委托给 `Options` 单例(基于 `modeleditor.options` XML 配置):

```cpp
// model_editor.cpp L789-808
BW::string CModelEditorApp::get( const BW::string& key ) const
{
	BW_GUARD;
	return Options::getOptionString( key );
}

bool CModelEditorApp::exist( const BW::string& key ) const
{
	BW_GUARD;
	return Options::optionExists( key );
}

void CModelEditorApp::set( const BW::string& key, const BW::string& value )
{
	BW_GUARD;
	Options::setOptionString( key, value );
}
```

---

## 五、关键算法与数据结构

### 5.1 命令行解析算法

`parseCommandLineMF`(L454-482)负责解析命令行参数,识别 `-o`/`-O` 选项指定待加载模型,并初始化资源系统与选项系统:

```cpp
// model_editor.cpp L454-482
BOOL CModelEditorApp::parseCommandLineMF()
{
	BW_GUARD;
	const int MAX_ARGS = 20;
	char * argv[ MAX_ARGS ];
	int argc = 0;
	char cmdline [32768];
	bw_wtoutf8( s_pCmdLine, wcslen( s_pCmdLine ), cmdline, ARRAY_SIZE( cmdline ) );
	char * str = cmdline;
	while (char * token = StringUtils::retrieveCmdTokenT( str ))
	{
		if (argc >= MAX_ARGS)
		{
			ERROR_MSG( "ModelEditor::parseCommandLineMF: Too many arguments!!\n" );
			return FALSE;
		}
		if (argc && (!strcmp( argv[ argc-1 ], "-o" ) || !strcmp( argv[ argc-1 ], "-O" )))
		{
			modelToLoad_ = token;
		}
		argv[argc++] = token;
	}
	return BWResource::init( argc, (const char **)argv ) &&
		Options::init( argc, argv, L"modeleditor.options" );
}
```

**算法要点**:
- 使用 `StringUtils::retrieveCmdTokenT` 进行令牌化(支持引号转义)
- 检测前一个参数是否为 `-o`/`-O`,若是则将当前 token 作为模型路径存入 `modelToLoad_`
- 最终调用 `BWResource::init`(初始化资源路径)与 `Options::init`(加载 `modeleditor.options`)

### 5.2 OnIdle 主循环算法

`OnIdle`(L551-733)是启动壳的**主循环核心**,承担模型加载、包围盒重算、MRU 更新、帧更新、纹理内存显示等职责。其算法流程如下:

```
OnIdle(lCount)
│
├─ CWinApp::OnIdle(lCount)  →  优先处理 Windows GUI 空闲任务
│
├─ 若光标在图形窗口上 → SetFocus(hWndGraphics)
│
├─ 若 s_justLoaded:
│  ├─ Options::setOptionBool("startup/lastLoadOK", true)
│  └─ Options::save()
│
├─ 若 modelToLoad_ != "":
│  ├─ SetCursor(IDC_WAIT)
│  ├─ 计算 modelName / numAnim / needsBBCalc
│  ├─ 若 numAnim > 4:创建 CLoadingDialog + AnimLoadFunctor
│  ├─ Options::setOptionBool("startup/lastLoadOK", false) + save
│  ├─ mutant->loadModel(modelToLoad_)
│  │   ├─ 成功:
│  │   │   ├─ s_justLoaded = true
│  │   │   ├─ 若 needsBBCalc:
│  │   │   │   ├─ mutant->updateModelAnimations(-1.f)
│  │   │   │   ├─ mutant->recreateModelVisibilityBox(callback, false)
│  │   │   │   └─ UndoRedo::instance().forceSave()
│  │   │   ├─ MRU::instance().update("models", modelToLoad_, true)
│  │   │   ├─ updateRecentList("models")
│  │   │   ├─ MeModule::materialPreviewMode(false)
│  │   │   ├─ camera->boundingBox(mutant->zoomBoundingBox())
│  │   │   ├─ 若 zoomOnLoad: camera->zoomToExtents(false)
│  │   │   ├─ camera->render(0.f)
│  │   │   ├─ PanelManager::ualAddItemToHistory(modelToLoad_)
│  │   │   └─ getMainFrame()->updateGUI(true)
│  │   └─ 失败:
│  │       ├─ ERROR_MSG
│  │       ├─ MRU::instance().update("models", modelToLoad_, false)
│  │       └─ updateRecentList("models")
│  ├─ SetCursor(IDC_ARROW)
│  ├─ modelToLoad_ = ""
│  └─ 删除 CLoadingDialog
│
├─ 否则若 modelToAdd_ != "":
│  ├─ mutant->addModel(modelToAdd_)
│  │   ├─ 成功:MRU 更新 + camera 重置 + ualAddItemToHistory
│  │   └─ 失败:WARNING_MSG
│  └─ modelToAdd_ = ""
│
├─ 检查窗口激活状态(isWindowActive)
│
├─ 若 !CooperativeMoo::canUseMoo(this, isWindowActive):
│  └─ mfApp_->calculateFrameTime()  (冻结时间,稍后重试)
│
└─ 否则:
   ├─ 若 mutant->texMemUpdate():
   │   └─ setStatusText(TEXTURE_MEM, memorySizeToStr(texMem))
   ├─ mfApp_->updateFrame()  (帧更新)
   └─ mainFrame->updateGUI()  (s_updateWatch 计时)

return TRUE  (持续 OnIdle 循环)
```

### 5.3 CooperativeMoo 协作式 GPU 占用

`OnIdle` 通过 `CooperativeMoo::canUseMoo(this, isWindowActive)`(L690)实现**协作式 GPU 占用**:

- 当应用最小化、显存不足恢复失败、或后台有其他需要协作的 BigWorld 工具运行时,`canUseMoo` 返回 `false`
- 此时仅调用 `mfApp_->calculateFrameTime()` 冻结时间,不渲染,避免与其他工具争抢 GPU
- 这解决了多个 BigWorld 工具同时运行时的 GPU 资源冲突问题

### 5.4 崩溃恢复算法

崩溃恢复机制(L387-409)通过 `startup/lastLoadOK` 标志位检测上次加载是否崩溃:

```cpp
// model_editor.cpp L387-409
if (modelToLoad_ != "")
{
	modelToLoad_ = BWResource::dissolveFilename( modelToLoad_ );
}
else if (Options::getOptionInt( "startup/loadLastModel", 1 ))
{
	modelToLoad_ = Options::getOptionString( "models/file0", "" );
	
	if (!Options::getOptionBool( "startup/lastLoadOK", true ))
	{
		static char modelName[256];
		strcpy( modelName, modelToLoad_.c_str() );
		AfxBeginThread( &CModelEditorApp::loadErrorMsg, modelName );

		//Remove this model from the MRU models list
		MRU::instance().update( "models", modelToLoad_, false );

		Options::setOptionBool( "startup/lastLoadOK", true );
		Options::save();

		modelToLoad_ = "";
	}
}
```

**算法逻辑**:
1. 启动时若命令行未指定模型(`modelToLoad_` 为空),检查 `startup/loadLastModel` 选项
2. 若启用,读取 `models/file0`(最近一次加载的模型)作为待加载模型
3. 检查 `startup/lastLoadOK` 标志:
   - `OnIdle` 加载模型前会设置 `lastLoadOK=false` 并保存(L598-599)
   - 加载成功后会设置 `lastLoadOK=true` 并保存(L570-572,通过 `s_justLoaded`)
   - 若启动时发现 `lastLoadOK=false`,说明上次加载崩溃,弹出错误对话框,从 MRU 移除该模型,并清空 `modelToLoad_`
4. 错误对话框通过 `AfxBeginThread` 异步显示,避免阻塞主线程

### 5.5 AnimLoadFunctor 动画加载回调

`AnimLoadFunctor`(L110-131)是一个模板类,用于在动画加载时回调 `CLoadingDialog` 更新进度条:

```cpp
// model_editor.cpp L110-131
template< class C >
class AnimLoadFunctor: public AnimLoadCallback
{
public:
	typedef void (C::*Method)();
	AnimLoadFunctor( C* instance, Method method ):
		instance_(instance), method_(method)
	{}
	void execute()
	{
		BW_GUARD;
		if ((instance_) && (method_))
			(instance_->*method_)();
	}
private:
	C* instance_;
	Method method_;
};
```

当模型动画数超过 4 个时(L588),创建 `CLoadingDialog` 并绑定 `AnimLoadFunctor`,每加载一个动画触发一次 `CLoadingDialog::step` 更新进度。

---

## 六、GUI 框架集成

### 6.1 MFC SDI 文档模板

启动壳使用 MFC SDI(Single Document Interface)框架,通过 `CSingleDocTemplate` 注册文档/视图/主框架三件套(L242-248):

```cpp
// model_editor.cpp L242-248
CSingleDocTemplate* pDocTemplate;
pDocTemplate = new CSingleDocTemplate(
	IDR_MAINFRAME,
	RUNTIME_CLASS(CModelEditorDoc),    // 文档(来自 modeleditor_core)
	RUNTIME_CLASS(CMainFrame),          // 主 SDI 框架窗口(来自 modeleditor_core)
	RUNTIME_CLASS(CModelEditorView));   // 视图(来自 modeleditor_core)
AddDocTemplate(pDocTemplate);
```

注意:`CMainFrame`、`CModelEditorDoc`、`CModelEditorView` 都由 `modeleditor_core` 提供,启动壳仅负责注册。

### 6.2 GUI::Manager 数据驱动菜单

启动壳通过 `GUI::Manager` 实现**数据驱动菜单/工具栏**,从 `resources/data/gui.xml` 加载 GUI 项(L348-350):

```cpp
// model_editor.cpp L348-350
DataSectionPtr section = BWResource::openSection( "resources/data/gui.xml" );
for( int i = 0; i < section->countChildren(); ++i )
	GUI::Manager::instance().add( new GUI::Item( section->openChild( i ) ) );
```

随后添加主菜单(L355-356):

```cpp
// model_editor.cpp L355-356
GUI::Manager::instance().add(
	new GUI::Menu( "MainMenu", menuHelper_.get() ));
```

### 6.3 MRU 最近文件列表更新

`updateRecentList`(L484-511)负责更新 GUI 菜单中的最近文件列表,通过 `MRU` 单例读取最近文件,动态构造 GUI::Item:

```cpp
// model_editor.cpp L484-511
void CModelEditorApp::updateRecentList( const BW::string& kind )
{
	BW_GUARD;
	GUI::ItemPtr recentFiles = GUI::Manager::instance()( "/MainMenu/File/Recent_" + kind );
	if( recentFiles )
	{
		while( recentFiles->num() )
			recentFiles->remove( 0 );
		BW::vector<BW::string> files;
		MRU::instance().read(kind, files);
		for( unsigned i=0; i < files.size(); i++ )
		{
			BW::stringstream name, displayName;
			name << kind << i;
			if (i <= 9)
				displayName << '&' << i << "  " << files[i];
			else
				displayName << "    " << files[i];
			GUI::ItemPtr item = new GUI::Item( "ACTION", name.str(), displayName.str(),
				"",	"", "", "recent_"+kind, "", "" );
			item->set( "fileName", files[i] );
			recentFiles->add( item );
		}
	}
}
```

启动时更新 `models` 与 `lights` 两类最近列表(L414, L418)。

### 6.4 UAL 拖放注册

启动壳向 UAL(Unified Asset Locator)注册三种拖放 Functor(L369-379),支持从资源浏览器拖放模型到 3D 视口:

```cpp
// model_editor.cpp L369-379
UalManager::instance().dropManager().add(
	new UalDropFunctor< CModelEditorApp >( mainView, "model", this, &CModelEditorApp::loadFile, true ),
	false );

UalManager::instance().dropManager().add(
	new UalDropFunctor< CModelEditorApp >( mainView, "mvl", this, &CModelEditorApp::loadFile ),
	false  );

UalManager::instance().dropManager().add(
	new UalDropFunctor< CModelEditorApp >( mainView, "", this, &CModelEditorApp::loadFile ),
	false  );
```

`loadFile`(L810-816)通过 Python 适配器调用 `openFile`:

```cpp
// model_editor.cpp L810-816
bool CModelEditorApp::loadFile( UalItemInfo* ii )
{
	BW_GUARD;
	return pPythonAdapter_->callString( "openFile", 
		BWResource::dissolveFilename( bw_wtoutf8( ii->longText() ) ) );
}
```

### 6.5 多语言列表更新

`updateLanguageList`(L513-538)从 `StringProvider` 读取已加载语言,动态构造语言切换菜单:

```cpp
// model_editor.cpp L513-538(节选)
GUI::ItemPtr languageList = GUI::Manager::instance()( "/MainMenu/Languages/LanguageList" );
if( languageList )
{
	while( languageList->num() )
		languageList->remove( 0 );
	for( unsigned int i = 0; i < StringProvider::instance().languageNum(); ++i )
	{
		LanguagePtr l = StringProvider::instance().getLanguage( i );
		// ... 构造 GUI::Item 并添加 ...
		item->set( "LanguageName", l->getIsoLangNameUTF8() );
		item->set( "CountryName", l->getIsoCountryNameUTF8() );
		languageList->add( item );
	}
}
```

---

## 七、Python 脚本集成

### 7.1 MEPythonAdapter 适配器

启动壳创建 `MEPythonAdapter`(L343)作为 Python 集成桥梁。`MEPythonAdapter`(声明于 `modeleditor_core/App/me_python_adapter.hpp` L9-14)继承自 `PythonAdapter`,是核心库提供的轻量适配器:

```cpp
// me_python_adapter.hpp L9-14(核心库提供)
class MEPythonAdapter : public PythonAdapter
{
    // 继承 PythonAdapter 的能力
};
```

### 7.2 Python 调用入口

`pythonAdapter()` 方法(L540-549)返回 Python 适配器,核心库的 Python 模块(`ModelEditor` 模块)通过此适配器调用壳的能力:

```cpp
// model_editor.cpp L540-549
MEPythonAdapter * CModelEditorApp::pythonAdapter() const
{
	BW_GUARD;
	if (!pPythonAdapter_->hasScriptObject())
	{
		return NULL;
	}
	return pPythonAdapter_;
}
```

### 7.3 Python 模块委托

`modeleditor_core` 通过 `PY_MODULE_FUNCTION` 注册 `ModelEditor` Python 模块,暴露以下函数(由核心库实现,不在启动壳内):

| Python 函数 | 功能 |
|-------------|------|
| `isModelLoaded` | 查询模型是否已加载 |
| `isModelDirty` | 查询模型是否有未保存修改 |
| `revertModel` | 还原模型到磁盘状态 |
| `saveModel` | 保存模型 |
| `saveModelAs` | 另存为模型 |
| `zoomToExtents` | 缩放到模型范围 |
| `addCommentaryMsg` | 添加注释消息 |
| `undo` / `redo` | 撤销/重做 |
| `addUndoBarrier` | 添加撤销屏障 |
| `saveOptions` | 保存选项 |
| `showPanel` / `isPanelVisible` | 显示/查询面板 |
| `addItemToHistory` | 添加项到 UAL 历史 |
| `makeThumbnail` | 生成缩略图 |
| `capturePanel` | 捕获面板 |

启动壳的 `loadFile` 方法通过 `pPythonAdapter_->callString("openFile", ...)` 调用 Python 端的 `openFile` 函数,实现 C++ 与 Python 的双向交互。

---

## 八、资源管理

### 8.1 资源初始化

启动壳在 `parseCommandLineMF` 中调用 `BWResource::init(argc, argv)`(L480)初始化资源系统,解析 `bigworld.xml` 配置的资源路径。

### 8.2 选项系统初始化

`Options::init(argc, argv, L"modeleditor.options")`(L481)加载 `modeleditor.options` XML 配置文件,该文件存储所有用户偏好与最近文件列表。

### 8.3 后台任务管理器

启动壳初始化两个后台任务管理器(L381-385):

```cpp
// model_editor.cpp L381-385
BgTaskManager::instance().initWatchers( "ModelEditor" );
FileIOTaskManager::instance().initWatchers( "FileIO" );
BgTaskManager::instance().startThreads( 1 );
FileIOTaskManager::instance().startThreads( 1 );
```

- `BgTaskManager`:通用后台任务(资产编译、模型处理等)
- `FileIOTaskManager`:文件 I/O 后台任务(避免阻塞主线程)

### 8.4 AssetClient 资产管线

启动壳将 `MeShell::assetClient()` 绑定到 `Mutant`(L340),启用资产管线(`ENABLE_ASSET_PIPE`):

```cpp
// model_editor.cpp L340
meApp_->mutant()->setAssetClient( meShell_->assetClient() );
```

### 8.5 Umbra 强制禁用

启动壳强制禁用 Umbra(L440-447),解决鼠标延迟问题:

```cpp
// model_editor.cpp L440-447
#if UMBRA_ENABLE
if (Options::getOptionInt( "render/useUmbra", 1) == 1 )
{
	WARNING_MSG( "Umbra is enabled in ModelEditor, It will now be disabled\n" );
}
Options::setOptionInt( "render/useUmbra", 0 );
ChunkManager::instance().umbra()->umbraEnabled( false );
#endif
```

**原因注释**(L434-438):Umbra 导致 present 线程让 CPU 领先 GPU 几帧后停滞,引起鼠标延迟。此代码在 ParticleEditor 中有相同实现。

### 8.6 退出清理

`InternalExitInstance`(L735-782)按逆序销毁所有资源:

```
BgTaskManager::stopAll()                停止后台线程
GizmoManager::removeAllGizmo()          移除所有 Gizmo
ToolManager::popTool()(循环)            弹出所有工具
delete pPythonAdapter_                  销毁 Python 适配器
mfApp_->fini() + delete mfApp_          销毁 App
meShell_->fini() + delete meShell_      销毁 Shell
MsgHandler::fini()                      销毁消息处理器
PanelManager::fini()                    销毁面板管理器
GUI::Manager::fini()                    销毁 GUI 管理器
DogWatchManager::fini()                 销毁性能监控
WindowTextNotifier::fini()             销毁窗口文本通知器
Options::fini()                         保存并销毁选项
Name::fini()                            销毁名称系统
BWResource::fini()                      销毁资源系统
DataSectionCensus::fini()               销毁 DataSection 普查
delete [] s_pCmdLine                    释放命令行副本
```

---

## 九、配置项与命令行参数

### 9.1 命令行参数

| 参数 | 说明 |
|------|------|
| `-o <模型路径>` | 启动时加载指定模型文件 |
| `-O <模型路径>` | 同 `-o`(大写变体) |
| `/RegServer` `/Register` `/Unregserver` `/Unregister` | MFC 标准注册命令(由 `ProcessShellCommand` 处理) |
| `<文件路径>` | 通过 `ProcessShellCommand` 的 shell 命令分发,触发文档打开 |

命令行解析在 `parseCommandLineMF`(L454-482)与 `ParseCommandLine(cmdInfo)`(L262)中完成。

### 9.2 配置项(modeleditor.options)

`modeleditor.options` XML 文件存储所有配置,启动壳读取的关键配置项如下:

| 配置键 | 类型 | 默认值 | 说明 |
|--------|------|--------|------|
| `startup/loadLastModel` | int | 1 | 启动时是否加载上次模型 |
| `startup/lastLoadOK` | bool | true | 上次加载是否成功(崩溃恢复标志) |
| `models/file0` | string | "" | 最近加载的模型路径(MRU 首项) |
| `settings/regenBBOnLoad` | int | 1 | 加载时是否重算包围盒(若无 visibility box) |
| `settings/zoomOnLoad` | int | 1 | 加载时是否缩放到模型范围 |
| `render/useUmbra` | int | 0 | 是否启用 Umbra(强制禁用) |
| `messages/errorMsgs` | int | 0 | 是否显示错误消息(若无 options.xml 则设为 1) |
| `currentLanguage` | string | "" | 当前语言 ISO 代码 |
| `currentCountry` | string | "" | 当前国家 ISO 代码 |
| `language` | 多值 | - | 多语言文件列表 |
| `help/shortcutsHtml` | string | "resources/html/shortcuts.html" | 快捷键帮助 HTML |

### 9.3 配置读写示例

启动壳通过 `Options` 单例读写配置,例如崩溃恢复逻辑:

```cpp
// 读取配置
Options::getOptionInt( "startup/loadLastModel", 1 )
Options::getOptionString( "models/file0", "" )
Options::getOptionBool( "startup/lastLoadOK", true )
Options::getOptionInt( "settings/regenBBOnLoad", 1 )
Options::getOptionInt( "settings/zoomOnLoad", 1 )

// 写入配置
Options::setOptionBool( "startup/lastLoadOK", true )
Options::setOptionInt( "render/useUmbra", 0 )
Options::save()  // 保存到 modeleditor.options
```

### 9.4 options.xml 缺失检查

启动壳检查 `options.xml` 是否存在(L422-426),若不存在则启用错误消息显示并报警:

```cpp
// model_editor.cpp L422-426
if (!Options::optionsFileExisted())
{
	Options::setOptionInt("messages/errorMsgs", 1); // turn on showing of error messages
	ERROR_MSG("options.xml is missing\n");
}
```

---

## 十、与其他模块的依赖关系

### 10.1 依赖库列表

启动壳通过 `CMakeLists.txt` 链接以下库(按 `BW_ADD_TOOL_EXE` 声明):

| 依赖库 | 用途 |
|--------|------|
| `appmgr` | `App` 应用管理器、`Options` 选项系统、`Module`/`FrameworkModule` 模块基类 |
| `chunk` | `ChunkManager`/`ChunkSpace`/`ChunkLoader`/`ChunkUmbra` 区块管理 |
| `cstdmf` | `BgTaskManager`/`FileIOTaskManager`/`DebugExceptionFilter`/`Name`/`BWResource` 基础设施 |
| `editor_shared` | `IEditorApp`/`BaseMainFrame`/`BasePanelManager`/`IMainFrame`/`PythonAdapter`/`MenuHelper` 编辑器共享层 |
| `gizmo` | `GizmoManager`/`ToolManager` Gizmo 与工具管理 |
| `guimanager` | `GUI::Manager`/`GUI::Menu`/`GUI::Item`/`GUI::MenuHelper`/`GUI::OptionMap`/`ActionMaker`/`UpdaterMaker` GUI 框架 |
| `modeleditor_core` | **核心库**:`MeShell`/`MeApp`/`MeModule`/`MEPythonAdapter`/`Mutant`/`CMainFrame`/`CModelEditorDoc`/`CModelEditorView`/`PanelManager`/页面 |
| `pyscript` | `Automation` Python 自动化 |
| `terrain` | `TerrainSettings` 地形设置 |
| `ual` | `UalManager`/`UalDropFunctor` 统一资产定位器 |
| `moo` | `Moo::rc`/`reload` 渲染上下文与热重载 |
| `resmgr` | `BWResource`/`StringProvider`/`AutoConfig` 资源与字符串管理 |

### 10.2 依赖关系图

```
                    ┌──────────────┐
                    │  modeleditor │ (启动壳, 6 文件)
                    └──────┬───────┘
                           │
        ┌──────────────────┼──────────────────┐
        │                  │                  │
        ▼                  ▼                  ▼
┌───────────────┐  ┌──────────────┐  ┌──────────────┐
│modeleditor_   │  │ editor_shared│  │ appmgr       │
│    core       │  │ (BaseMain-   │  │ (App/Options)│
│ (~80 文件)    │  │  Frame/IEditorApp)│  └──────┬───────┘
│ MeShell/MeApp/│  └──────────────┘          │
│ MeModule/     │                            │
│ Mutant/Pages/ │                            ▼
│ PanelManager  │  ┌──────────────┐  ┌──────────────┐
└───────┬───────┘  │ guimanager   │  │ cstdmf       │
        │          │ (GUI::Manager)│  │(BgTaskMgr/  │
        │          └──────────────┘  │ DebugFilter) │
        │                            └──────────────┘
        ▼
┌───────────────┐  ┌──────────────┐  ┌──────────────┐
│ moo/romp/     │  │ ual          │  │ chunk/terrain│
│ post_processing│  │(UalManager)  │  │(ChunkManager)│
│ (渲染核心)    │  └──────────────┘  └──────────────┘
└───────────────┘
```

### 10.3 反向接口依赖

启动壳通过 `IModelEditorApp` 接口被核心库反向调用,实现**依赖反转**:

| 核心库调用 | 接口方法 | 实现位置 |
|-----------|----------|----------|
| 查询初始化状态 | `initDone()` | L46 |
| 获取 App | `mfApp()` | L45 |
| 获取主窗口 | `mainWnd()` | L44 |
| 获取/设置待加载模型 | `modelToLoad()` / `modelToLoad(name)` | L50-51 |
| 更新最近列表 | `updateRecentList(kind)` | L63 |
| 获取 Python 适配器 | `pythonAdapter()` | L67 |
| 重算包围盒 | `OnFileRegenBoundingBox()` | L59 |
| 加载灯光 | `loadLights(lightsName)` | L53 |
| 偏好设置 | `OnAppPrefs()` | L60 |
| 添加模型 | `OnFileAdd()` | L57 |
| 退出 | `exit(ignoreChanges)` | L61 |

---

## 十一、关键代码片段

### 11.1 应用对象与异常过滤器

```cpp
// model_editor.cpp L99-104
CModelEditorApp theApp;

BEGIN_MESSAGE_MAP(CModelEditorApp, CWinApp)
END_MESSAGE_MAP()
```

```cpp
// model_editor.cpp L200-203(Run 也通过异常过滤器包裹)
int CModelEditorApp::Run()
{
	return CallWithExceptionFilter( this, &CModelEditorApp::InternalRun );
}
```

### 11.2 三层运行时装配

```cpp
// model_editor.cpp L316-340
ASSERT( !mfApp_ );
mfApp_ = new App;

ASSERT( !meShell_ );
meShell_ = new MeShell;

HINSTANCE hInst = AfxGetInstanceHandle();

if (!mfApp_->init(
	hInst, m_pMainWnd->GetSafeHwnd(), mainView->GetSafeHwnd(),
	mainFrame, MeShell::initApp ))
{
	ERROR_MSG( "CModelEditorApp::InitInstance - init failed\n" );
	return FALSE;
}

//give a warning if there is no terrain info or space
ChunkSpacePtr pSpace = ChunkManager::instance().cameraSpace();
if (!pSpace || (pSpace && !pSpace->terrainSettings().exists()))
{
	ERROR_MSG( "Could not open the default space. Terrain and Game Lighting preview will be disabled.\n");
}

ASSERT( !meApp_ );
meApp_ = new MeApp( mainFrame, this );
meApp_->mutant()->setAssetClient( meShell_->assetClient() );

// need to load the adapter before the load thread begins, but after the modules
pPythonAdapter_ = new MEPythonAdapter();
```

### 11.3 OnIdle 模型加载核心

```cpp
// model_editor.cpp L575-655(节选)
if (modelToLoad_ != "")
{
	SetCursor( ::LoadCursor( NULL, IDC_WAIT ));
	BW::string::size_type first = modelToLoad_.rfind("/") + 1;
	BW::string::size_type last = modelToLoad_.rfind(".");
	BW::string modelName = modelToLoad_.substr( first, last-first );

	int numAnim = MeApp::instance().mutant()->animCount( modelToLoad_ );
	bool needsBBCalc = Options::getOptionInt( "settings/regenBBOnLoad", 1 ) &&
		(!MeApp::instance().mutant()->hasVisibilityBox( modelToLoad_ ));
	
	CLoadingDialog* load = NULL;
	if (numAnim > 4)
	{
		load = new CLoadingDialog( Localise(L"MODELEDITOR/GUI/MODEL_EDITOR/LOADING", modelName ) );
		load->setRange( needsBBCalc ? 2*numAnim + 1 : numAnim + 1 );
		Model::setAnimLoadCallback(
			new AnimLoadFunctor< CLoadingDialog >(load, &CLoadingDialog::step) );
	}
		
	ME_INFO_MSGW( Localise(L"MODELEDITOR/GUI/MODEL_EDITOR/LOADING_MODEL", modelToLoad_ ) );

	Options::setOptionBool( "startup/lastLoadOK", false );
	Options::save();

	if (MeApp::instance().mutant()->loadModel( modelToLoad_ ))
	{
		s_justLoaded = true;
		if (needsBBCalc)
		{
			MeApp::instance().mutant()->updateModelAnimations( -1.f );
			MeApp::instance().mutant()->recreateModelVisibilityBox(
				new AnimLoadFunctor< CLoadingDialog >(load, &CLoadingDialog::step), false );
			ME_WARNING_MSGW( Localise(L"MODELEDITOR/GUI/MODEL_EDITOR/VIS_BOX_AUTO_CALC") );
			UndoRedo::instance().forceSave();
		}
		MRU::instance().update( "models", modelToLoad_, true );
		updateRecentList( "models" );
		MeModule::instance().materialPreviewMode( false );
		MeApp::instance().camera()->boundingBox(
			MeApp::instance().mutant()->zoomBoundingBox() );
		if (!!Options::getOptionInt( "settings/zoomOnLoad", 1 ))
		{
			MeApp::instance().camera()->zoomToExtents( false );
		}
		MeApp::instance().camera()->render( 0.f );
		PanelManager::instance().ualAddItemToHistory( modelToLoad_ );
		getMainFrame()->updateGUI( true );
	}
	// ... 失败处理 ...
	modelToLoad_ = "";
}
```

### 11.4 纹理内存显示

```cpp
// model_editor.cpp L704-708
if ( MeApp::instance().mutant()->texMemUpdate() )
{
	mainFrame->setStatusText( ID_INDICATOR_TETXURE_MEM, 
		Localise(L"MODELEDITOR/GUI/MODEL_EDITOR/TEXTURE_MEM", 
		Utilities::memorySizeToStr( MeApp::instance().mutant()->texMem() )) );
}
```

### 11.5 OnFileRegenBoundingBox 菜单回调

```cpp
// model_editor.cpp L862-886
void CModelEditorApp::OnFileRegenBoundingBox()
{
	BW_GUARD;
	CWaitCursor wait;
	int animCount = MeApp::instance().mutant()->animCount();
	CLoadingDialog* load = NULL;
	if (animCount > 4)
	{
		load = new CLoadingDialog( Localise(L"MODELEDITOR/GUI/MODEL_EDITOR/REGENERATING_VIS_BOX") );
		load->setRange( animCount );
	}
	MeApp::instance().mutant()->recreateModelVisibilityBox(
		new AnimLoadFunctor< CLoadingDialog >(load, &CLoadingDialog::step), true );
	ME_INFO_MSGW( Localise(L"MODELEDITOR/GUI/MODEL_EDITOR/REGENERATED_VIS_BOX") );
	MeApp::instance().camera()->boundingBox(
		MeApp::instance().mutant()->zoomBoundingBox() );
	if (load) delete load;
}
```

### 11.6 退出方法

```cpp
// model_editor.cpp L903-913
void CModelEditorApp::exit( bool ignoreChanges /*= false*/)
{
	BW_GUARD;
	if (ignoreChanges)
	{
		MeApp::instance().forceClean();
	}
	AfxGetApp()->GetMainWnd()->PostMessage( WM_COMMAND, ID_APP_EXIT );
}
```

`exit` 通过 `PostMessage(WM_COMMAND, ID_APP_EXIT)` 触发 MFC 标准退出流程,确保消息循环正确清理。`ignoreChanges=true` 时先调用 `MeApp::forceClean()` 丢弃未保存修改。

---

## 十二、设计亮点与注意事项

### 12.1 设计亮点

| 亮点 | 说明 |
|------|------|
| **极薄壳架构** | 启动壳仅 6 文件、916 行,所有业务下沉核心库,实现极致的壳/核分离,便于核心库复用与测试 |
| **接口反转解耦** | `IModelEditorApp` 抽象接口让核心库不反向依赖壳,符合依赖倒置原则(DIP) |
| **三层运行时一致性** | `App`/`Shell`/`Module` 三层结构与 WorldEditor/ParticleEditor 保持一致,降低工具间学习成本 |
| **崩溃恢复机制** | `lastLoadOK` 标志位 + MRU 自动移除 + 异步错误对话框,提升用户体验 |
| **协作式 GPU 占用** | `CooperativeMoo::canUseMoo` 解决多工具同时运行的 GPU 争抢问题 |
| **异常过滤器全覆盖** | `InitInstance`/`Run`/`ExitInstance` 全部通过 `CallWithExceptionFilter` 包裹,崩溃时自动生成 dump |
| **数据驱动 GUI** | `gui.xml` 描述菜单/工具栏,`GUI::Manager` 动态加载,支持热更新 |
| **Umbra 强制禁用** | 主动规避 Umbra 导致的鼠标延迟问题,并注释提示 ParticleEditor 有相同代码 |
| **AnimLoadFunctor 模板** | 泛型回调模板,支持任意类的成员函数作为动画加载回调,实现进度条更新 |
| **MRU 动态菜单** | `updateRecentList` 动态构造 GUI::Item,支持 `&0`-`&9` 快捷键前缀 |

### 12.2 注意事项

| 注意点 | 说明 |
|--------|------|
| **OnIdle 返回 TRUE** | `OnIdle` 始终返回 `TRUE`(L732),意味着 MFC 会持续触发空闲处理,实现"持续渲染"。这会占用 CPU,但通过 `CooperativeMoo` 协作避免阻塞 |
| **s_justLoaded 静态变量** | L555 使用静态局部变量 `s_justLoaded` 跟踪加载状态,跨 OnIdle 调用保持 |
| **loadErrorMsg 静态缓冲区** | L397 使用 `static char modelName[256]` 缓冲区传递给 `AfxBeginThread`,存在潜在的线程安全问题(若多次崩溃恢复可能覆盖) |
| **Memhook 与 MFC 冲突** | L232-253 在创建文档模板前临时禁用自定义内存分配器,避免 MFC 退出时删除文档模板类产生冲突 |
| **命令行副本** | L219-222 复制 `m_lpCmdLine` 到 `s_pCmdLine`,因为 `parseCommandLineMF` 在 `ProcessShellCommand` 之后调用,而 MFC 可能修改原命令行 |
| **lastLoadOK 持久化** | `lastLoadOK` 在 `OnIdle` 加载前设为 `false` 并保存(L598-599),加载成功后设为 `true` 并保存(L570-572)。若进程在加载中崩溃,下次启动时检测到 `false` 触发恢复 |
| **依赖 modeleditor_core** | 启动壳强依赖 `modeleditor_core` 提供的 `CMainFrame`/`CModelEditorDoc`/`CModelEditorView`/`MeShell`/`MeApp`/`MeModule`/`MEPythonAdapter`/`PanelManager` 等类,无法独立编译运行 |
| **terrain 缺失降级** | L331-336 检查默认 space 是否存在,若不存在则禁用地形与游戏光照预览,仅报错不退出 |
| **Automation::parseCommandLine** | L449 在最后调用 `Automation::parseCommandLine`,处理 Python 自动化测试命令行参数 |

### 12.3 与 ParticleEditor 的对比

| 维度 | modeleditor | particle_editor |
|------|-------------|-----------------|
| 文件数 | 6(极薄壳) | ~100(单体应用) |
| 核心库 | 委托 `modeleditor_core`(~80 文件) | 自包含,无独立核心库 |
| 启动壳/核分离 | 是(IModelEditorApp 接口) | 否(Shell/Module 在本体内) |
| OnIdle 帧率限制 | 无(依赖 CooperativeMoo) | 有(`m_desiredFrameRate` + Sleep) |
| 状态机 | 无(始终运行) | 有(PE_PLAYING/PE_PAUSED/PE_STOPPED) |
| Python 模式 | 仅 C++(通过 MEPythonAdapter) | C++/Python 双模式(`c_useScripting`) |
| 面板管理器 | `PanelManager`(基础) | `PanelManager`(多语言/UAL/Messages 面板) |

### 12.4 与 modeleditor_core 的职责边界

| 职责 | modeleditor(壳) | modeleditor_core(核心库) |
|------|------------------|--------------------------|
| MFC 应用框架 | ✅ `CModelEditorApp` | ❌ |
| 启动流程编排 | ✅ `InternalInitInstance` | ❌(提供 `MeShell::initApp` 回调) |
| OnIdle 主循环 | ✅ `OnIdle` | ❌(提供 `Mutant`/`MeModule` 能力) |
| 命令行解析 | ✅ `parseCommandLineMF` | ❌ |
| 崩溃恢复 | ✅ `lastLoadOK` 机制 | ❌ |
| GUI 菜单/工具栏装配 | ✅ `GUI::Manager` | ❌(提供 `PanelManager`/页面) |
| UAL 拖放注册 | ✅ `UalDropFunctor` | ❌ |
| 多语言列表 | ✅ `updateLanguageList` | ❌ |
| 模型加载/编辑 | ❌ | ✅ `Mutant`(7 文件拆分) |
| 渲染 | ❌ | ✅ `MeModule`/`Mutant::render` |
| 动画/动作/LOD/材质 | ❌ | ✅ `Mutant` 子模块 |
| Python 模块 | ❌ | ✅ `ModelEditor` 模块 |
| 属性页面 | ❌ | ✅ 7 个 Page |
| 主框架/文档/视图 | ❌ | ✅ `CMainFrame`/`CModelEditorDoc`/`CModelEditorView` |

---

## 总结

`modeleditor` 是 BigWorld 工具链中**架构最纯粹的启动壳**,仅 6 个文件即完成 MFC 应用装配、三层运行时编排、命令行解析、崩溃恢复、OnIdle 主循环驱动等职责。其核心价值在于:

1. **壳/核分离**:通过 `IModelEditorApp` 接口实现依赖反转,核心库 `modeleditor_core` 可独立复用与测试。
2. **架构一致性**:与 WorldEditor/ParticleEditor 保持 `App`/`Shell`/`Module` 三层结构,降低维护成本。
3. **稳定性**:异常过滤器全覆盖 + 崩溃恢复机制,确保工具崩溃后能自动恢复并提示用户。
4. **协作性**:`CooperativeMoo` 协作式 GPU 占用,支持多 BigWorld 工具同时运行。

所有模型编辑业务能力(模型加载、动画/动作/LOD/材质编辑、渲染、验证、Python 暴露)由 `modeleditor_core` 静态库提供,详见《BigWorld 工具 modeleditor_core 实现分析》。

---

**参考源文件**:
- `programming/bigworld/tools/modeleditor/GUI/model_editor.h`(L1-104)
- `programming/bigworld/tools/modeleditor/GUI/model_editor.cpp`(L1-916)
- `programming/bigworld/tools/modeleditor_core/i_model_editor_app.hpp`(L1-46)
- `programming/bigworld/tools/modeleditor_core/App/me_app.hpp`(L1-60)
- `programming/bigworld/tools/modeleditor_core/App/me_shell.hpp`(L1-150)
- `programming/bigworld/tools/modeleditor_core/App/me_module.hpp`(L1-137)
