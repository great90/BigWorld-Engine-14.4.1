# BigWorld 工具 modeleditor_core 实现深度分析

> 本文档详细分析 BigWorld Engine 14.4.1 中 `modeleditor_core`(模型编辑器核心库)的完整实现。该库是 `modeleditor` 启动壳的业务承载层,约 80 个文件,承担模型加载、动画/动作/LOD/材质编辑、渲染、验证、Python 暴露、属性页面等全部模型编辑职责。其核心是 `Mutant` 类——一个继承 `ReloadListener`(可选 `ChunkBspHolder`)的"上帝对象",按职责拆分为 7 个 cpp 文件(mutant_actions/animations/lod/materials/render/validation + 主文件)。本文档涵盖架构定位、目录组织、App/Shell/Module 三层运行时、Mutant 七文件拆分、模型/动画/LOD/材质系统、7 个属性页面、Python 集成、资源管理等核心机制。

---

## 目录

- [一、整体架构概览](#一整体架构概览)
- [二、源码目录结构](#二源码目录结构)
- [三、入口点与启动流程](#三入口点与启动流程)
- [四、核心类与继承关系](#四核心类与继承关系)
- [五、Mutant 七文件拆分详解](#五mutant-七文件拆分详解)
- [六、关键算法与数据结构](#六关键算法与数据结构)
- [七、GUI 框架与页面系统](#七gui-框架与页面系统)
- [八、Python 脚本集成](#八python-脚本集成)
- [九、资源管理](#九资源管理)
- [十、配置项与命令行参数](#十配置项与命令行参数)
- [十一、与其他模块的依赖关系](#十一与其他模块的依赖关系)
- [十二、关键代码片段](#十二关键代码片段)
- [十三、设计亮点与注意事项](#十三设计亮点与注意事项)

---

## 一、整体架构概览

### 1.1 modeleditor_core 在工具链中的定位

`modeleditor_core` 是 BigWorld 工具链中**模型编辑器核心库**,位于 `programming/bigworld/tools/modeleditor_core/`,由 `CMakeLists.txt` 组织为**静态库**(通过 `BW_ADD_TOOL_LIB`)。它被 `modeleditor` 启动壳链接,承担全部模型编辑业务:

1. **模型加载与管理**:加载 `.model` 文件,聚合 `SuperModel`、`visual`、`primitives`,支持多模型叠加
2. **动画编辑**:动画创建/删除/帧率/压缩(`backupChannels`/`restoreChannels`)
3. **动作(Action)编辑**:动作创建/匹配/blend time/flag/track
4. **LOD 编辑**:LOD extent/parent/visibility 算法
5. **材质编辑**:Matter/Tint/Dye/MFM 系统,支持 instantiate/overload/save MFM
6. **渲染**:模型/包围盒/骨架/portal/法线/hardpoints/custom hull/BSP 绘制
7. **验证**:模型有效性检查、文件定位、只读检测、格式弃用检查
8. **撤销/重做**:`UndoRedo` 单例 + `UndoRedoOp` 操作
9. **Python 暴露**:`ModelEditor` Python 模块
10. **属性页面**:7 个属性页面(Actions/Animations/Display/Lights/LOD/Materials/Object)
11. **GUI 框架**:`CMainFrame`/`CModelEditorDoc`/`CModelEditorView`/`PanelManager`
12. **资源管理**:`BWResource` + `ReloadListener` 热重载 + `AssetClient` 资产管线

### 1.2 整体架构拓扑

```
┌──────────────────────────────────────────────────────────────────────┐
│           modeleditor_core 静态库 (~80 文件)                         │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │                        App 层                                   │  │
│  │  IModelEditorApp(接口)  MeApp(聚合 Mutant)                      │  │
│  │  MeShell(图形/脚本/控制台/ROMP/相机/声音)                       │  │
│  │  MeModule(渲染模块)  MeScripter(ParticleSystemManager/Script)   │  │
│  │  MEPythonAdapter  UndoRedo  MRU  MaterialPreview  GridCoord     │  │
│  └────────────────────────────────────────────────────────────────┘  │
│                                │                                     │
│                                ▼                                     │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │                       Models 层(核心)                          │  │
│  │                                                                  │  │
│  │  ┌──────────────────────────────────────────────────────────┐   │  │
│  │  │              Mutant(上帝对象,继承 ReloadListener)        │   │  │
│  │  │                                                          │   │  │
│  │  │  ┌─────────┐ ┌──────────┐ ┌─────────┐ ┌──────────────┐ │   │  │
│  │  │  │mutant.  │ │mutant_   │ │mutant_  │ │mutant_       │ │   │  │
│  │  │  │hpp/cpp  │ │actions.  │ │anim-    │ │lod.cpp       │ │   │  │
│  │  │  │(核心)   │ │cpp       │ │ations.  │ │(LOD 算法)    │ │   │  │
│  │  │  └─────────┘ │(动作)    │ │cpp      │ └──────────────┘ │   │  │
│  │  │              └──────────┘ │(动画)   │                   │   │  │
│  │  │                           └─────────┘                   │   │  │
│  │  │  ┌─────────────┐ ┌──────────────┐ ┌──────────────────┐ │   │  │
│  │  │  │mutant_      │ │mutant_       │ │mutant_           │ │   │  │
│  │  │  │materials.   │ │render.cpp    │ │validation.cpp    │ │   │  │
│  │  │  │cpp          │ │(渲染)        │ │(验证)            │ │   │  │
│  │  │  │(材质/MFM)   │ │              │ │                  │ │   │  │
│  │  │  └─────────────┘ └──────────────┘ └──────────────────┘ │   │  │
│  │  └──────────────────────────────────────────────────────────┘   │  │
│  │                                                                  │  │
│  │  VisualBumper(可视碰撞器)  Lights(光照)                         │  │
│  └────────────────────────────────────────────────────────────────┘  │
│                                │                                     │
│                                ▼                                     │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │                       GUI 层                                     │  │
│  │  CMainFrame(BaseMainFrame+IMainFrame+ActionMaker+UpdaterMaker)  │  │
│  │  CModelEditorDoc  CModelEditorView  PanelManager                 │  │
│  │  GlView  LodBar  TreeList  LoadingDialog  SplashDialog           │  │
│  │  PrefsDialog  AboutBox  ChooseAnim  NewTint  TextureFeed         │  │
│  │  TriggerList  FolderSetter                                        │  │
│  └────────────────────────────────────────────────────────────────┘  │
│                                │                                     │
│                                ▼                                     │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │                     Pages 层(7 个属性页面)                     │  │
│  │  PageActions  PageAnimations(+comp+impl)  PageDisplay            │  │
│  │  PageLights  PageLOD  PageMaterials(PropertyTable+              │  │
│  │  MaterialPropertiesUser)  PageObject                             │  │
│  └────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
```

### 1.3 关键设计原则

| 原则 | 说明 |
|------|------|
| **上帝对象模式** | `Mutant` 单例聚合模型所有状态(模型/动画/动作/LOD/材质/渲染/验证),7 文件按职责拆分 |
| **ReloadListener 热重载** | `Mutant` 继承 `ReloadListener`,监听 `SuperModel` 重载事件,自动更新关联数据 |
| **DataSection 数据模型** | 所有模型数据以 `DataSectionPtr`(XML)形式存储与编辑,`UndoRedoOp` 快照 DataSection |
| **PropertyTable 属性编辑** | 7 个页面通过 `PropertyTable` + `GeneralEditor` 反射式编辑属性 |
| **GUITABS 撕离标签** | 页面通过 `IMPLEMENT_BASIC_CONTENT`/`IMPLEMENT_ROOT_CONTENT` 宏注册到 GUITABS,支持撕离 |
| **Python 全暴露** | `ModelEditor` Python 模块暴露 `isModelLoaded`/`saveModel`/`undo`/`showPanel` 等函数 |
| **三层运行时** | `MeShell`(外壳)/`MeModule`(渲染)/`MeApp`(聚合)分层,与启动壳协作 |
| **AssetClient 资产管线** | `ENABLE_ASSET_PIPE` 启用资产管线,支持后台资产编译 |

### 1.4 规模与组成

`modeleditor_core` 源码约 80 文件,按目录分组如下:

| 目录 | 文件数(估) | 职责 |
|------|------------|------|
| `App/` | ~15 | 应用层:`MeApp`/`MeShell`/`MeModule`/`MeScripter`/`MEPythonAdapter`/`UndoRedo`/`MRU`/`MaterialPreview`/`GridCoord`/`me_consts`/`me_error_macros`/`me_light_proxies`/`me_material_proxies` |
| `Models/` | ~10 | 模型核心:`Mutant`(7文件拆分)/`VisualBumper`/`Lights` |
| `GUI/` | ~15 | GUI 组件:`CMainFrame`/`CModelEditorDoc`/`CModelEditorView`/`PanelManager`/`GlView`/`LodBar`/`TreeList`/`LoadingDialog`/`SplashDialog`/`PrefsDialog`/`AboutBox`/`ChooseAnim`/`NewTint`/`TextureFeed`/`TriggerList`/`FolderSetter` |
| `Pages/` | ~14 | 7 个属性页面(每个 hpp+cpp,Animations 额外有 comp+impl) |
| 根目录 | ~3 | `i_model_editor_app.hpp`/`pch.hpp`/`CMakeLists.txt` |

---

## 二、源码目录结构

```
programming/bigworld/tools/modeleditor_core/
├── CMakeLists.txt                  # 构建脚本(BW_ADD_TOOL_LIB)
├── pch.hpp                         # 预编译头
├── i_model_editor_app.hpp          # IModelEditorApp 接口(L13-42)
│
├── App/                            # 应用层
│   ├── me_app.hpp / me_app.cpp     # MeApp 单例(聚合 Floor/Mutant/Lights/Camera)
│   ├── me_shell.hpp / me_shell.cpp # MeShell(图形/脚本/控制台/ROMP/相机/声音)
│   ├── me_module.hpp / me_module.cpp  # MeModule(FrameworkModule,渲染)
│   ├── me_scripter.hpp / me_scripter.cpp  # Scripter(ParticleSystemManager/Script/MaterialKinds/Personality)
│   ├── me_python_adapter.hpp / .cpp # MEPythonAdapter(继承 PythonAdapter)
│   ├── undo_redo.hpp / undo_redo.cpp  # UndoRedo 单例
│   ├── mru.hpp / mru.cpp           # MRU(Most Recently Used)最近文件
│   ├── material_preview.hpp / .cpp # MaterialPreview 材质预览
│   ├── grid_coord.hpp / grid_coord.cpp  # GridCoord 网格坐标
│   ├── me_consts.hpp               # 常量定义
│   ├── me_error_macros.hpp         # 错误宏
│   ├── me_light_proxies.hpp        # 灯光代理
│   └── me_material_proxies.hpp     # 材质代理
│
├── Models/                         # 模型核心层
│   ├── mutant.hpp / mutant.cpp     # Mutant 上帝对象(主文件,L207-686)
│   ├── mutant_actions.cpp          # 动作(Action)编辑
│   ├── mutant_animations.cpp       # 动画(Animation)编辑
│   ├── mutant_lod.cpp              # LOD 算法(L74-98)
│   ├── mutant_materials.cpp        # 材质/Matter/Tint/Dye/MFM
│   ├── mutant_render.cpp           # 渲染(drawModel/drawBB/drawSkeleton 等)
│   ├── mutant_validation.cpp       # 验证(clipToDiffRoot/fixTextures/ensureModelValid)
│   ├── visual_bumper.hpp / .cpp / .ipp  # 可视碰撞器
│   └── lights.hpp / lights.cpp     # 光照
│
├── GUI/                            # GUI 组件层
│   ├── main_frm.h / main_frm.cpp   # CMainFrame(BaseMainFrame+IMainFrame+ActionMaker+UpdaterMaker)
│   ├── model_editor_doc.h / .cpp   # CModelEditorDoc(MFC 文档)
│   ├── model_editor_view.h / .cpp  # CModelEditorView(MFC 视图,3D 视口)
│   ├── panel_manager.hpp / .cpp    # PanelManager(Singleton+ActionMaker+UpdaterMaker+BasePanelManager)
│   ├── gl_view.hpp / gl_view.cpp   # GLView OpenGL 视图
│   ├── lod_bar.hpp / lod_bar.cpp   # LodBar LOD 进度条
│   ├── tree_list.hpp / tree_list.cpp  # TreeList 树形列表
│   ├── tree_list_dlg.hpp           # TreeList 对话框
│   ├── loading_dialog.hpp / .cpp   # LoadingDialog 加载进度
│   ├── splash_dialog.hpp / .cpp    # SplashDialog 启动闪屏
│   ├── prefs_dialog.hpp / .cpp     # PrefsDialog 偏好设置
│   ├── about_box.hpp / about_box.cpp  # AboutBox 关于
│   ├── choose_anim.hpp / .cpp      # ChooseAnim 动画选择
│   ├── new_tint.hpp / .cpp         # NewTint 新建 Tint
│   ├── texture_feed.hpp / .cpp     # TextureFeed 纹理 feed
│   ├── trigger_list.hpp / .cpp     # TriggerList 触发器列表
│   └── foldersetter.hpp            # FolderSetter 文件夹设置
│
└── Pages/                          # 属性页面层(7 个)
    ├── page_actions.hpp / .cpp             # PageActions 动作页
    ├── page_animations.hpp / .cpp          # PageAnimations 动画页
    ├── page_animations_comp.cpp            # 动画压缩
    ├── page_animations_impl.hpp            # 动画实现
    ├── page_display.hpp / .cpp             # PageDisplay 显示页
    ├── page_lights.hpp / .cpp              # PageLights 灯光页
    ├── page_lod.hpp / .cpp                 # PageLOD LOD 页
    ├── page_materials.hpp / .cpp           # PageMaterials 材质页(PropertyTable+MaterialPropertiesUser)
    └── page_object.hpp / .cpp              # PageObject 对象页
```

---

## 三、入口点与启动流程

### 3.1 核心库无独立入口

`modeleditor_core` 是**静态库**,无独立入口点。其初始化由 `modeleditor` 启动壳在 `InternalInitInstance` 中通过创建核心对象触发:

```cpp
// 启动壳调用(详见 modeleditor 文档)
meShell_ = new MeShell;                          // 创建 Shell
mfApp_->init(..., MeShell::initApp);             // App 初始化,回调 MeShell::initApp
meApp_ = new MeApp( mainFrame, this );           // 创建 MeApp(内部创建 Mutant)
meApp_->mutant()->setAssetClient( meShell_->assetClient() );  // 绑定 AssetClient
pPythonAdapter_ = new MEPythonAdapter();         // 创建 Python 适配器
PanelManager::init( mainFrame, mainView, this, mainFrame );   // 面板管理器初始化
```

### 3.2 MeShell::initApp 启动回调

`MeShell::initApp`(声明于 `me_shell.hpp` L65)是 `App::init` 的回调函数,在 `App` 初始化完成后被调用,触发 `MeShell::init`:

```
MeShell::initApp(hInstance, hWndApp, hWndGraphics)
│
└─ MeShell::init
   ├─ initGraphics()     → Renderer / Moo 初始化
   ├─ initScripts()      → Python 脚本初始化
   ├─ initConsoles()     → 控制台初始化
   ├─ initErrorHandling()→ 错误处理初始化
   ├─ initRomp()         → RompHarness / TimeOfDay 环境初始化
   ├─ initCamera()       → ToolsCamera 相机初始化
   └─ initSound()        → 声音初始化
```

### 3.3 MeShell 持有的子系统

`MeShell`(声明于 `me_shell.hpp` L57-142)是**图形/脚本/控制台/ROMP 外壳**,持有以下子系统:

```cpp
// me_shell.hpp L113-141(私有成员)
MeShellDebugMessageCallback debugMessageCallback_;     // 消息回调
std::auto_ptr<Renderer> renderer_;                     // 渲染器
RompHarness *			romp_;                          // ROMP 环境(天气/时间)
std::auto_ptr< AssetClient > pAssetClient_;            // 资产管线客户端
FontManagerPtr pFontManager_;                          // 字体管理器
TextureFeedsPtr pTextureFeeds_;                        // 纹理 feed
TerrainManagerPtr pTerrainManager_;                    // 地形管理器
PostProcessingManagerPtr pPostProcessingManager_;      // 后处理管理器
LensEffectManagerPtr pLensEffectManager_;              // 镜头特效管理器
```

### 3.4 MeScripter 脚本初始化

`MeScripter::init`(声明于 `me_scripter.hpp` L11-20)完成脚本系统初始化:

```cpp
// me_scripter.hpp L9-20
class Scripter
{
public:
	static bool init( DataSectionPtr pDataSection );
	static void fini();
	static bool update();
private:
	static PyObject* s_stdout;
	static PyObject* s_stderr;
};
```

`Scripter::init` 内部完成:
1. `ParticleSystemManager::init` 粒子系统管理器初始化
2. `Script::init` Python 脚本引擎初始化
3. `MaterialKinds::init` 材质种类初始化
4. `Personality::import` 导入 Personality 脚本

### 3.5 MeApp 聚合初始化

`MeApp`(声明于 `me_app.hpp` L17-55)是**聚合单例**,聚合模型编辑的所有核心组件:

```cpp
// me_app.hpp L17-55
class MeApp
{
public:
	MeApp( IMainFrame * mainFrame, IModelEditorApp * editorApp );
	static MeApp & instance() { ... }
	Floor*	floor();
	Mutant*	mutant();        // 核心模型对象
	Lights*	lights();
	ToolsCameraPtr camera();
	Moo::LightContainerPtr blackLight() { return blackLight_; }
	Moo::LightContainerPtr whiteLight() { return whiteLight_; }
	void saveModel();
	void saveModelAs();
	bool canExit( bool quitting );
	void forceClean();
	bool isDirty() const;
private:
	static MeApp *		s_instance_;
	Floor*	floor_;
	Mutant*	mutant_;            // Mutant 上帝对象
	Lights*  lights_;
	Moo::LightContainerPtr blackLight_;
	Moo::LightContainerPtr whiteLight_;
	ToolsCameraPtr		camera_;
	IModelEditorApp *	editorApp_;
	IMainFrame *		mainFrame_;
};
```

---

## 四、核心类与继承关系

### 4.1 Mutant 继承关系

`Mutant`(声明于 `mutant.hpp` L207-686)是核心库的**上帝对象**,继承 `ReloadListener`(可选 `ChunkBspHolder`):

```cpp
// mutant.hpp L207-220
class Mutant:
    /*
    *   Note: ChunkModel is always listening if pSuperModel_ has 
    *   been reloaded, if you are pulling info out from the pSuperModel_
    *   then please update it again in onReloaderReloaded which is 
    *   called when pSuperModel_ is reloaded so that related data
    *   will need be update again.and you might want to do something
    *   in onReloaderPriorReloaded which happen right before the pSuperModel_ reloaded.
    */
    public ReloadListener
#if ENABLE_BSP_MODEL_RENDERING
    , public ChunkBspHolder
#endif // ENABLE_BSP_MODEL_RENDERING
{
```

### 4.2 继承关系图

```
                ┌──────────────────┐
                │  ReloadListener  │  (moo/reload.hpp,热重载监听)
                └────────┬─────────┘
                         │
          ┌──────────────┴──────────────┐
          │  (可选)ChunkBspHolder       │  (chunk/chunk_bsp_holder.hpp)
          └──────────────┬──────────────┘
                         │
                  ┌──────┴──────┐
                  │   Mutant    │  (mutant.hpp L207-686)
                  │  (上帝对象) │
                  └─────────────┘
                         │
        ┌────────────────┼────────────────┐
        │                │                │
        ▼                ▼                ▼
  ┌──────────┐    ┌────────────┐   ┌──────────────┐
  │mutant.   │    │mutant_     │   │mutant_       │
  │cpp(核心) │    │actions.cpp │   │animations.cpp│
  └──────────┘    └────────────┘   └──────────────┘
        │                │                │
        ▼                ▼                ▼
  ┌──────────┐    ┌────────────┐   ┌──────────────┐
  │mutant_   │    │mutant_     │   │mutant_       │
  │lod.cpp   │    │materials.  │   │render.cpp    │
  └──────────┘    │cpp         │   └──────────────┘
                  └────────────┘
                         │
                         ▼
                  ┌──────────────┐
                  │mutant_       │
                  │validation.cpp│
                  └──────────────┘
```

### 4.3 Mutant 核心数据成员

`Mutant` 持有大量状态(L571-685),按职责分组:

```cpp
// mutant.hpp L571-685(私有成员,节选)
private:
    // 模型标识
    BW::string modelName_;
    BW::string visualName_;
    BW::string primitivesName_;
    BW::string editorProxyName_;

    // 核心对象
    SuperModel* superModel_;                // 主 SuperModel
    SuperModel* editorProxySuperModel_;     // 编辑器代理 SuperModel
    ActionQueue actionQueue_;               // 动作队列
    MatrixLiaisonIdentity* matrixLI_;       // 矩阵联络

    // DataSection 数据(数据模型核心)
    DataSectionPtr currModel_;              // 当前 model XML
    DataSectionPtr currVisual_;             // 当前 visual XML
    BW::map < BW::string , DataSectionPtr > models_;       // 所有 model
    BW::map < DataSectionPtr , BW::string > dataFiles_;    // DataSection→文件名

    // 动画/动作
    BW::map < StringPair , AnimationInfo > animations_;    // 动画信息
    BW::map < StringPair , ActionInfo > actions_;          // 动作信息

    // 材质
    Dyes currDyes_;                         // 当前 Dyes
    BW::map< BW::string, MaterialInfo > materials_;        // 材质信息
    BW::map< BW::string, DataSectionPtr > dyes_;           // Dyes
    typedef BW::map< BW::string, BW::map < BW::string, TintInfo > > TintMap;
    TintMap tints_;                         // Tint 映射(Matter→TintName→TintInfo)

    // 列表(TreeRoot/LODList)
    TreeRoot animList_;                     // 动画树
    TreeRoot actList_;                      // 动作树
    LODList  lodList_;                      // LOD 列表
    TreeRoot materialList_;                 // 材质树

    // 当前播放状态
    bool animMode_;
    BW::map< size_t, StringPair > currAnims_;   // 当前动画(按 pageID)
    StringPair currAct_;                        // 当前动作
    bool playing_;
    bool looping_;
    float lastFrameRate_;

    // 包围盒
    BoundingBox modelBB_;                   // 模型包围盒
    BoundingBox visibilityBB_;              // 可见性包围盒
    bool visibilityBoxDirty_;

    // Fashion(装扮)
    MaterialFashionVector materialFashions_;
    TransformFashionVector transformFashions_;

    // 脏标志与只读
    BW::set< DataSectionPtr > dirty_;       // 脏 DataSection 集合
    bool isReadOnly_;
    bool isSkyBox_;

    // 元数据
    MetaData::MetaData metaData_;

    // 纹理内存
    bool texMemDirty_;
    uint32 texMem_;

    // AssetClient
#ifdef ENABLE_ASSET_PIPE
    AssetClient* assetClient_;
#endif
```

### 4.4 辅助数据结构

`Mutant` 使用多个辅助数据结构(声明于 `mutant.hpp` L46-175):

| 结构 | 行号 | 用途 |
|------|------|------|
| `MatrixLiaisonIdentity` | L39-44 | 单位矩阵联络器(用于无变换场景) |
| `ChannelsInfo` | L46-50 | 动画通道列表(`Moo::AnimationChannelPtr` 向量) |
| `AnimationInfo` | L52-82 | 动画信息(data/model/animation/boneWeights/frameRates/channels/isReadOnly) |
| `ActionInfo` | L84-95 | 动作信息(data/model) |
| `MaterialInfo` | L97-118 | 材质信息(name/nameData/effect/data/format/colours/dualUV) |
| `TintInfo` | L120-139 | Tint 信息(effect/data/dye/format/colours/dualUV) |
| `ModelChangeCallback` | L141-149 | 模型变更回调抽象基类 |
| `ModelChangeFunctor<C>` | L151-175 | 模型变更回调模板(成员函数) |

### 4.5 类型别名

```cpp
// mutant.hpp L21-37
typedef SmartPointer< class AnimLoadCallback > AnimLoadCallbackPtr;
typedef SmartPointer< class SuperModelAnimation > SuperModelAnimationPtr;
typedef SmartPointer< class SuperModelAction > SuperModelActionPtr;
typedef SmartPointer< class SuperModelDye > SuperModelDyePtr;
typedef SmartPointer< class Model > ModelPtr;
typedef SmartPointer< class XMLSection > XMLSectionPtr;

typedef std::pair < BW::string , BW::string > StringPair;          // 动画/动作 ID
typedef std::pair < StringPair , BW::string > TreeBranch;          // 树分支
typedef BW::vector < TreeBranch > TreeRoot;                        // 树根
typedef std::pair < StringPair , float > LODEntry;                 // LOD 条目
typedef BW::vector < LODEntry > LODList;                           // LOD 列表
typedef BW::map < BW::string, BW::string > Dyes;                   // Dyes 映射
typedef BW::set< Moo::ComplexEffectMaterialPtr > ComplexEffectMaterialSet;  // 材质集合
```

---

## 五、Mutant 七文件拆分详解

`Mutant` 类按职责拆分为 7 个 cpp 文件,每个文件负责一组相关功能:

### 5.1 文件拆分总览

| 文件 | 行数(估) | 职责 | 关键方法 |
|------|----------|------|----------|
| `mutant.hpp` / `mutant.cpp` | ~686 / ~1000 | 核心声明与基础功能 | `Mutant`/`~Mutant`/`loadModel`/`addModel`/`revertModel`/`reloadModel`/`save`/`saveAs`/`recreateFashions`/`recreateModelVisibilityBox`/`onReloaderReloaded` |
| `mutant_actions.cpp` | ~600 | 动作(Action)创建/编辑/匹配 | `createAct`/`removeAct`/`swapActions`/`setAct`/`setupActionMatch`/`actName`/`actAnim`/`actBlendTime`/`actFlag`/`actTrack`/`actMatchFloat`/`actMatchCaps`/`actMatchFlag` |
| `mutant_animations.cpp` | ~800 | 动画(Animation)创建/编辑/帧率/压缩 | `createAnim`/`changeAnim`/`removeAnim`/`getMooAnim`/`backupChannels`/`restoreChannels`/`uncompressAnim`/`restoreAnim`/`setAnim`/`animName`/`firstFrame`/`lastFrame`/`localFrameRate`/`frameNum`/`animBoneWeight` |
| `mutant_lod.cpp` | ~200 | LOD 算法 | `lodExtent`/`lodParents`/`hasParent`/`isHidden`/`lodParent`/`lodList`/`virtualDist` |
| `mutant_materials.cpp` | ~1200 | 材质/Matter/Tint/Dye/MFM | `setDye`/`getMaterial`/`setMaterialProperty`/`instantiateMFM`/`overloadMFM`/`saveMFM`/`newTint`/`deleteTint`/`ensureShaderCorrect`/`effectHasNormalMap`/`materialShader`/`materialMFM`/`tintFlag`/`materialFlag`/`recalcTextureMemUsage` |
| `mutant_render.cpp` | ~1000 | 渲染 | `updateModelAnimations`/`drawModel`/`drawOriginalModel`/`drawBoundingBoxes`/`drawSkeleton`/`drawPortals`/`drawNormals`/`drawHardPoints`/`calcCustomHull`/`drawCustomHull`/`reloadBSP`/`drawBspInternal`/`render`/`switchChannels` |
| `mutant_validation.cpp` | ~500 | 验证 | `clipToDiffRoot`/`fixTexAnim`/`fixTextures`/`locateFile`/`isFileReadOnly`/`testReadOnly`/`testReadOnlyAnim`/`ensureModelValid`/`isFormatDepreciated`/`clearFilesMissingList` |

### 5.2 mutant.cpp(核心基础)

`mutant.cpp` 实现 `Mutant` 的构造/析构、模型加载/保存、Fashion 重建、包围盒重算、热重载回调等基础功能。

**关键方法**:
- `Mutant(groundModel, centreModel)`(L222):构造函数,初始化地面/居中模式
- `~Mutant()`(L223):析构,清理资源
- `onReloaderReloaded(pReloader)`(L225):`ReloadListener` 回调,`SuperModel` 重载后更新关联数据
- `loadModel(name, reload, inParentOrders)`(L262):加载模型,核心入口
- `addModel(name, reload)`(L264):添加额外模型
- `revertModel()`(L260):还原模型到磁盘状态
- `reloadModel(inParentOrders)`(L261):重新加载模型
- `recreateFashions(dyesOnly)`(L286):重建 Fashion(材质/变换装扮)
- `recreateModelVisibilityBox(callback, undoable)`(L288-289):重算可见性包围盒
- `save()`(L318)/`saveAs(newName)`(L319):保存模型
- `registerModelChangeCallback(mcc)`(L227)/`unregisterModelChangeCallback(parent)`(L228):注册/注销模型变更回调

### 5.3 mutant_actions.cpp(动作编辑)

实现动作(Action)的创建、删除、交换、匹配等功能。动作是模型的高级抽象,封装动画 + 混合参数 + 匹配条件。

**关键方法**:
- `createAct(actID, animName, afterAct)`(L432):创建动作,插入到指定动作之后
- `removeAct(actID)`(L433):删除动作
- `swapActions(what, actID, act2ID, reload)`(L435):交换动作顺序
- `setAct(actID)`(L437)/`stopAct()`(L439):设置/停止当前动作
- `setupActionMatch(action)`(L441):设置动作匹配条件
- `actMatchFloat(actID, typeName, flagName, valSet)`(L460):获取匹配浮点值
- `actMatchVal(actID, typeName, flagName, empty, val, setUndo)`(L461):设置匹配值
- `actMatchCaps(actID, typeName, capsType)`(L463-464):获取/设置匹配容量
- `actMatchFlag(actID, flagName, flagVal)`(L466):设置匹配标志

### 5.4 mutant_animations.cpp(动画编辑)

实现动画(Animation)的创建、编辑、帧率、压缩等功能。支持动画通道的备份与恢复(用于压缩预览)。

**关键方法**:
- `createAnim(animID, animPath)`(L378):创建动画
- `changeAnim(animID, animPath)`(L379):修改动画路径
- `removeAnim(animID)`(L380):删除动画
- `cleanAnim(animID)`(L381):清理动画
- `getMooAnim(animID)`(L383):获取 `Moo::Animation`
- `backupChannels(animID)`(L385)/`restoreChannels(animID)`(L384):备份/恢复动画通道(压缩预览)
- `uncompressAnim(anim, oldChannels)`(L72)/`restoreAnim(anim, oldChannels)`(L73):解压/恢复动画
- `firstFrame`/`lastFrame`/`localFrameRate`/`frameRate`/`frameNum`/`numFrames`(L394-410):帧率与帧数控制
- `animBoneWeight(animID, boneName, val)`(L415):骨骼权重
- `removeAnimNode(animID, boneName)`(L418):移除动画节点

### 5.5 mutant_lod.cpp(LOD 算法)

实现 LOD(Level of Detail)算法,包括 extent、parent 链、hidden 状态判断。

**核心算法 - isHidden**(L74-98):

```cpp
// mutant_lod.cpp L74-98
bool Mutant::isHidden( const BW::string& modelFile )
{
	BW_GUARD;
	bool hidden = false;
	float extent = 0.f;
	for (size_t i=0; i<=lodList_.size(); i++)
	{
		if ((!isEqual( lodList_[i].second, Model::LOD_HIDDEN ) &&
			(lodList_[i].second <= extent)) ||
			isEqual( extent, Model::LOD_HIDDEN ))
		{
			hidden = true;
		}
		else
		{
			hidden = false;
			extent = lodList_[i].second;
		}
		if (lodList_[i].first.second == modelFile )
			break;
	}
	return hidden;
}
```

**算法逻辑**:遍历 LOD 列表,若当前 LOD 的 extent 小于等于前一个非隐藏 LOD 的 extent,则该 LOD 被隐藏。`Model::LOD_HIDDEN` 是特殊值表示强制隐藏。

**LOD extent 读写**(L21-52):

```cpp
// mutant_lod.cpp L21-32
float Mutant::lodExtent( const BW::string& modelFile )
{
	BW_GUARD;
	if (models_.find( modelFile ) == models_.end())
	{
		return Model::LOD_HIDDEN;
	}
	return models_[modelFile]->readFloat( "extent", Model::LOD_HIDDEN );
}
```

**LOD parent 链遍历**(L54-65):

```cpp
// mutant_lod.cpp L54-65
void Mutant::lodParents( BW::string modelName, BW::vector< BW::string >& parents )
{
	BW_GUARD;
	DataSectionPtr model = BWResource::openSection( modelName, false );
	while ( model )
	{
		parents.push_back( modelName );
		modelName = model->readString( "parent", "" ) + ".model";
		model = BWResource::openSection( modelName, false );
	}
}
```

沿 `parent` 字段链式遍历,收集所有父模型。

### 5.6 mutant_materials.cpp(材质/MFM 系统)

实现材质、Matter、Tint、Dye、MFM(Material File Manifest)系统。这是 `Mutant` 最复杂的子系统。

**关键概念**:
- **Material**:材质,对应 visual 中的一个 primitive group
- **Matter**:材质类别,可包含多个 Tint
- **Tint**:Matter 的一个变种(如不同颜色的衣服)
- **Dye**:运行时选择的 Tint,通过 Dye 系统切换
- **MFM**:Material File Manifest,材质文件清单,定义材质属性模板

**关键方法**:
- `setDye(matterName, tintName, material)`(L489):设置当前 Dye
- `getMaterial(materialName, material)`(L491):获取材质集合
- `setMaterialProperty(materialName, descName, uiName, propType, val)`(L495):设置材质属性
- `instantiateMFM(data)`(L497):实例化 MFM
- `overloadMFM(data, mfmData)`(L498):重载 MFM
- `saveMFM(materialName, matterName, tintName, mfmFile)`(L514):保存 MFM
- `newTint(materialName, matterName, oldTintName, newTintName, fxFile, mfmFile)`(L512):新建 Tint
- `deleteTint(matterName, tintName)`(L516):删除 Tint
- `ensureShaderCorrect(fxFile, format, dualUV)`(L518):确保 Shader 正确
- `effectHasNormalMap(effectFile)`(L520):检查效果是否有法线贴图
- `materialShader(materialName, matterName, tintName, fxFile, undoable)`(L527):获取/设置材质 Shader
- `materialMFM(materialName, matterName, tintName, mfmFile, fxFile)`(L530):获取/设置材质 MFM
- `recalcTextureMemUsage()`(L553):重算纹理内存占用

### 5.7 mutant_render.cpp(渲染)

实现模型渲染相关的所有功能。

**关键方法**:
- `updateModelAnimations(atDist)`(L32-...):每帧更新 LOD 与动画,核心渲染入口
- `drawModel(drawContext)`(L336):绘制模型
- `drawOriginalModel(drawContext)`(L337):绘制原始模型(未编辑)
- `drawBoundingBoxes()`(L338):绘制包围盒(model/visibility/shadow)
- `drawSkeleton()`(L339):绘制骨架
- `drawPortals()`(L340):绘制 portal
- `drawNormals(showNormals, showBinormals)`(L343):绘制法线/副法线
- `drawHardPoints(drawContext)`(L344):绘制 hard points
- `calcCustomHull()`(L345)/`drawCustomHull()`(L346):计算/绘制自定义凸包
- `reloadBSP()`(L341):重载 BSP
- `drawBspInternal()`(L342):绘制 BSP 内部
- `render(drawContext, dTime, renderStates)`(L347):主渲染入口
- `switchChannels(oldChannels, toCompressedChannel)`(L348):切换动画通道(压缩/解压)

**updateModelAnimations 算法**(L32-80):

```cpp
// mutant_render.cpp L32-78(节选)
void Mutant::updateModelAnimations( float atDist )
{
	BW_GUARD;
	if (!superModel_)
	{
		return;
	}
	Matrix world( Moo::rc().world() );
	world.preMultiply( this->transform( groundModel_, centreModel_ ) );

	TmpTransforms preTransformFashions;
	for (TransformFashionVector::const_iterator itr = transformFashions_.begin();
		itr != transformFashions_.end(); ++itr)
	{
		MF_ASSERT( (*itr).hasObject() );
		preTransformFashions.push_back( (*itr).get() );
	}

	// We want the latest fashion information from the action queue
	if (!animMode_)
	{
		this->recreateFashions( true );
		for (TransformFashionVector::const_iterator itr =
			actionQueue_.transformFashions().begin();
			itr != actionQueue_.transformFashions().end(); ++itr)
		{
			preTransformFashions.push_back( (*itr).get() );
		}
	}

	if (!isEqual( virtualDist_, Model::LOD_AUTO_CALCULATE ))
	{
		atDist = virtualDist_;
	}
	superModel_->updateAnimations( world, &preTransformFashions, NULL, atDist );
	// ...
}
```

### 5.8 mutant_validation.cpp(验证)

实现模型验证功能,确保模型文件有效且格式未弃用。

**关键方法**:
- `clipToDiffRoot(strA, strB)`(L352):裁剪到差异根节点
- `fixTexAnim(texRoot, oldRoot, newRoot)`(L354):修复纹理动画路径
- `fixTextures(mat, oldRoot, newRoot)`(L355):修复纹理路径
- `locateFile(fileName, modelName, ext, what, criticalMsg)`(L357-358):定位文件
- `isFileReadOnly(file)`(L360):检查文件只读
- `testReadOnly(modelName, visualName, primitivesName)`(L361):测试只读
- `testReadOnlyAnim(pData)`(L362):测试动画只读
- `ensureModelValid(name, what, model, visual, vName, pName, readOnly)`(L364-367):确保模型有效(核心验证入口)
- `isFormatDepreciated(visual, primitivesName)`(L369):检查格式是否弃用
- `clearFilesMissingList()`(L371,静态):清空缺失文件列表

---

## 六、关键算法与数据结构

### 6.1 模型加载算法

`Mutant::loadModel`(L262)是模型加载核心,算法流程:

```
loadModel(name, reload, inParentOrders)
│
├─ ensureModelValid(name, "model")        验证模型有效性
│  ├─ 打开 .model DataSection
│  ├─ 读取 visualName / primitivesName
│  ├─ ensureModelValid(visual, "visual")
│  └─ 检查只读状态
│
├─ 记录 modelName_ / visualName_ / primitivesName_
│
├─ 创建 SuperModel
│  ├─ new SuperModel(modelName_)
│  ├─ editorProxySuperModel_ = new SuperModel(editorProxyName)
│  └─ 设置 actionQueue_
│
├─ postLoad()                             后处理
│  ├─ reloadAllLists()                    重载所有列表
│  │  ├─ regenAnimLists()                 重建动画列表
│  │  ├─ regenMaterialsList()             重建材质列表
│  │  └─ 重建 LOD/动作列表
│  └─ recreateFashions()                  重建 Fashion
│
├─ updateModelAnimations(-1.f)            更新动画
├─ updateVisibilityBox()                  更新可见性包围盒
└─ triggerUpdate("modelLoaded")           触发更新通知
```

### 6.2 包围盒重算算法

`recreateModelVisibilityBox`(L288-289)重算可见性包围盒,遍历所有动画的每一帧:

```
recreateModelVisibilityBox(callback, undoable)
│
├─ 遍历所有动画
│  ├─ 对每个动画:
│  │  ├─ setAnim(animID)
│  │  ├─ 遍历每一帧:
│  │  │  ├─ updateModelAnimations(atDist)
│  │  │  ├─ 计算当前帧包围盒
│  │  │  └─ 合并到 visibilityBB_
│  │  └─ callback->execute()  (更新进度条)
│  └─ stopAnim()
│
├─ 写入 visibilityBB_ 到 model DataSection
├─ 若 undoable: UndoRedo::instance().add(...)
└─ visibilityBoxDirty_ = false
```

### 6.3 Fashion 重建算法

`recreateFashions(dyesOnly)`(L286)重建材质与变换装扮:

```
recreateFashions(dyesOnly)
│
├─ 清空 materialFashions_ / transformFashions_
│
├─ 若 !dyesOnly:
│  ├─ 从 superModel_ 收集 MaterialFashion
│  └─ 从 actionQueue_ 收集 TransformFashion
│
├─ 应用 currDyes_(当前选择的 Tint)
│  ├─ 遍历 currDyes_ 的每个 matter→tint 映射
│  ├─ 查找 tints_[matter][tint].dye
│  └─ 添加到 materialFashions_
│
└─ 应用 materialFashions_ / transformFashions_ 到 superModel_
```

### 6.4 热重载机制

`Mutant` 继承 `ReloadListener`,监听 `SuperModel` 重载事件:

```cpp
// mutant.hpp L225
virtual void onReloaderReloaded( Reloader* pReloader );
```

当 `SuperModel` 被热重载(例如外部修改了 `.model` 文件),`onReloaderReloaded` 被调用,执行:
1. 重新收集模型数据
2. 更新 `currModel_`/`currVisual_`
3. 重建 Fashion
4. 触发模型变更回调(`executeModelChangeCallbacks()`)

注释(L208-215)说明:`ChunkModel` 始终监听 `pSuperModel_` 重载,若从 `pSuperModel_` 提取信息,需在 `onReloaderReloaded` 中更新。

### 6.5 DataSection 数据模型

`Mutant` 的所有模型数据以 `DataSectionPtr`(XML)形式存储:

| 数据 | DataSection 来源 | 说明 |
|------|-----------------|------|
| `currModel_` | `BWResource::openSection(modelName_)` | 当前 `.model` 文件 |
| `currVisual_` | `BWResource::openSection(visualName_)` | 当前 `.visual` 文件 |
| `models_[modelPath]` | `BWResource::openSection(modelPath)` | 所有 model(含 LOD 父链) |
| `animations_[animID].data` | 动画 `.animation` 文件 | 动画数据 |
| `animations_[animID].model` | 所属 model DataSection | 动画所属模型 |
| `actions_[actID].data` | action 所在 model DataSection | 动作数据 |
| `actions_[actID].model` | 所属 model DataSection | 动作所属模型 |
| `materials_[name].data` | visual 中的材质节点 | 材质数据 |
| `tints_[matter][tint].data` | Tint DataSection | Tint 数据 |

### 6.6 UndoRedo 撤销重做

`UndoRedo`(单例)管理撤销重做栈,`UndoRedoOp` 是操作单元:

```cpp
// App/undo_redo.hpp(声明)
class UndoRedoOp : public UndoRedo::Operation
{
    // 保存 DataSection 快照
    // undo() 恢复快照
    // iseq() 比较两个操作是否相同
};
```

`Mutant` 在修改 DataSection 前调用 `UndoRedo::instance().add(new UndoRedoOp(...))` 保存快照。例如修改 LOD extent 时(`mutant_lod.cpp` L42):

```cpp
// mutant_lod.cpp L42
UndoRedo::instance().add( new UndoRedoOp( 0, models_[modelFile], models_[modelFile] ));
```

`MeApp::instance().mutant()->dirty()`(L315)查询是否有未保存修改,`forceClean()`(L314)强制清空脏状态。

---

## 七、GUI 框架与页面系统

### 7.1 CMainFrame 主框架

`CMainFrame`(声明于 `GUI/main_frm.h` L12-17)是 MFC SDI 主框架,继承 `BaseMainFrame` + `IMainFrame` + `GUI::ActionMaker` + `GUI::UpdaterMaker`:

```cpp
// main_frm.h L12-17
class CMainFrame
	: public BaseMainFrame
	, public IMainFrame
	, GUI::ActionMaker<CMainFrame>
	, GUI::UpdaterMaker<CMainFrame>
{
```

**职责**:
- MFC 主框架窗口管理
- `handleGUIAction` 处理 GUI 命令
- `showToolbar`/`hideToolbar`/`updateToolbar` 工具栏管理
- `currentCursorPosition`/`getWorldRay`/`cursorOverGraphicsWnd` 输入查询
- `updateGUI(force)` 更新 GUI
- `setStatusText(id, text)` 设置状态栏文本
- `grabFocus()` 抓取焦点

### 7.2 PanelManager 面板管理器

`PanelManager`(声明于 `GUI/panel_manager.hpp` L18-23)管理 GUITABS 撕离标签面板:

```cpp
// panel_manager.hpp L18-23
class PanelManager :
	public Singleton<PanelManager>,
	public GUI::ActionMaker<PanelManager>,	 // load default panels
	public GUI::UpdaterMaker<PanelManager>,	 // update show/hide panels
	public BasePanelManager
{
```

**职责**:
- `init(mainFrameWnd, mainView, editorApp, mainFrame)`:初始化面板
- `showPanel(pyID, show)`/`isPanelVisible(pyID)`:显示/查询面板
- `showSidePanel`/`hideSidePanel`/`updateSidePanel`:侧边面板控制
- `loadDefaultPanels`/`loadLastPanels`:加载默认/上次面板布局
- `ualAddItemToHistory(filePath)`:添加项到 UAL 历史
- `setLanguage`/`updateLanguage`:语言切换
- UAL 回调:`ualItemDblClick`/`ualStartDrag`/`ualUpdateDrag`/`ualEndDrag`/`ualStartPopupMenu`/`ualEndPopupMenu`

### 7.3 7 个属性页面

`modeleditor_core` 提供 7 个属性页面,均继承 `GuiTabContent`,通过 `IMPLEMENT_BASIC_CONTENT`/`IMPLEMENT_ROOT_CONTENT` 宏注册到 GUITABS:

| 页面 | 头文件 | 基类 | 职责 |
|------|--------|------|------|
| `PageActions` | `page_actions.hpp` | `GuiTabContent` | 动作(Action)编辑:创建/删除/匹配/blend time/flag/track |
| `PageAnimations` | `page_animations.hpp` + `page_animations_comp.cpp` + `page_animations_impl.hpp` | `GuiTabContent` | 动画编辑:创建/删除/帧率/压缩/帧数 |
| `PageDisplay` | `page_display.hpp` | `GuiTabContent` | 显示设置:网格/地面/骨架/法线/包围盒开关 |
| `PageLights` | `page_lights.hpp` | `GuiTabContent` | 灯光编辑:加载灯光文件/设置光源 |
| `PageLOD` | `page_lod.hpp` | `GuiTabContent` | LOD 编辑:extent/parent/virtualDist |
| `PageMaterials` | `page_materials.hpp` | `PropertyTable` + `MaterialPropertiesUser` + `GuiTabContent` | 材质编辑:Matter/Tint/Dye/MFM |
| `PageObject` | `page_object.hpp` | `GuiTabContent` | 对象属性:模型名称/只读/元数据 |

### 7.4 PageMaterials 材质页面

`PageMaterials`(声明于 `page_materials.hpp` L27-35)是最复杂的页面,继承三个基类:

```cpp
// page_materials.hpp L27-35
class PageMaterials
	: public PropertyTable
	, public MaterialPropertiesUser
	, public GuiTabContent
{
	IMPLEMENT_BASIC_CONTENT( 
		Localise(L"MODELEDITOR/PAGES/PAGE_MATERIALS/SHORT_NAME"), 
		Localise(L"MODELEDITOR/PAGES/PAGE_MATERIALS/LONG_NAME"), 
		285, 800, NULL )
	DECLARE_AUTO_TOOLTIP( PageMaterials, PropertyTable )
```

**关键方法**(L46-51):
- `tintNew()`:新建 Tint(Python: `newTint()`)
- `mfmLoad()`:加载 MFM(Python: `loadMFM()`)
- `mfmSave()`:保存 MFM(Python: `saveMFM()`)
- `tintDelete()`:删除 Tint(Python: `deleteTint()`)
- `canTintDelete()`:查询是否可删除 Tint(Python: `canDeleteTint()`)

### 7.5 GUITABS 注册宏

页面通过宏注册到 GUITABS 系统:

- `IMPLEMENT_BASIC_CONTENT(shortName, longName, width, height, icon)`:基础内容注册,提供短名/长名/尺寸
- `IMPLEMENT_ROOT_CONTENT(...)`:根内容注册
- `DECLARE_AUTO_TOOLTIP(ClassName, BaseClass)`:自动工具提示

这些宏生成 `contentID` 静态成员与 GUITABS 注册代码,使页面可被 `PanelManager` 动态加载与撕离。

---

## 八、Python 脚本集成

### 8.1 ModelEditor Python 模块

`modeleditor_core` 通过 `PY_MODULE_FUNCTION` 注册 `ModelEditor` Python 模块,暴露以下函数:

| Python 函数 | 功能 | 对应 C++ 方法 |
|-------------|------|--------------|
| `isModelLoaded` | 查询模型是否已加载 | `Mutant::hasModel()` |
| `isModelDirty` | 查询是否有未保存修改 | `MeApp::isDirty()` / `Mutant::dirty()` |
| `revertModel` | 还原模型 | `Mutant::revertModel()` |
| `saveModel` | 保存模型 | `MeApp::saveModel()` |
| `saveModelAs` | 另存为 | `MeApp::saveModelAs()` |
| `zoomToExtents` | 缩放到范围 | `ToolsCamera::zoomToExtents()` |
| `addCommentaryMsg` | 添加注释消息 | `MainFrame::setMessageText()` |
| `undo` | 撤销 | `UndoRedo::undo()` |
| `redo` | 重做 | `UndoRedo::redo()` |
| `addUndoBarrier` | 添加撤销屏障 | `UndoRedo::addBarrier()` |
| `saveOptions` | 保存选项 | `Options::save()` |
| `showPanel` | 显示面板 | `PanelManager::showPanel()` |
| `isPanelVisible` | 查询面板可见 | `PanelManager::isPanelVisible()` |
| `addItemToHistory` | 添加到 UAL 历史 | `PanelManager::ualAddItemToHistory()` |
| `makeThumbnail` | 生成缩略图 | `MeModule::renderThumbnail()` |
| `capturePanel` | 捕获面板 | 截图功能 |

### 8.2 MEPythonAdapter 适配器

`MEPythonAdapter`(声明于 `App/me_python_adapter.hpp` L9-14)继承 `PythonAdapter`,提供 C++ 调用 Python 的能力:

```cpp
// me_python_adapter.hpp L9-14
class MEPythonAdapter : public PythonAdapter
{
    // 继承 PythonAdapter:
    // - callString(funcName, args...)  调用 Python 函数返回字符串
    // - callVoid(funcName, args...)    调用 Python 函数无返回
    // - hasScriptObject()              查询脚本对象是否存在
};
```

启动壳的 `loadFile` 通过适配器调用 Python `openFile`:

```cpp
pPythonAdapter_->callString( "openFile", BWResource::dissolveFilename(...) );
```

### 8.3 MeModule Python 方法

`MeModule`(声明于 `me_module.hpp` L50-51)也暴露 Python 静态方法:

```cpp
// me_module.hpp L50-51
PY_MODULE_STATIC_METHOD_DECLARE( py_render )
PY_MODULE_STATIC_METHOD_DECLARE( py_onEditorReady )
```

- `MeModule.render`:触发渲染
- `MeModule.onEditorReady`:编辑器就绪回调

### 8.4 GUI Python Functor

`GUI::Manager` 的 `pythonFunctor` 允许 GUI 项的 action/update 委托给 Python 函数。`modeleditor_core` 通过 `gui.xml` 配置 Python 回调,实现 UI 适配层的 Python 化。

---

## 九、资源管理

### 9.1 BWResource 资源系统

`Mutant` 通过 `BWResource::openSection(path)` 加载所有模型资源:

```cpp
// 示例:加载 model
DataSectionPtr model = BWResource::openSection( modelName_, true );

// 示例:加载 visual
DataSectionPtr visual = BWResource::openSection( visualName_, false );

// 示例:沿 parent 链加载(mutant_lod.cpp L58-63)
DataSectionPtr model = BWResource::openSection( modelName, false );
while ( model )
{
    parents.push_back( modelName );
    modelName = model->readString( "parent", "" ) + ".model";
    model = BWResource::openSection( modelName, false );
}
```

### 9.2 ReloadListener 热重载

`Mutant` 继承 `ReloadListener`,监听 `SuperModel` 重载事件。当资源文件在外部被修改,`Moo::Reload` 系统触发重载,调用 `onReloaderReloaded`:

```cpp
// mutant.hpp L225
virtual void onReloaderReloaded( Reloader* pReloader );
```

这实现了**热重载**——用户在外部修改 `.model`/`.visual` 文件后,ModelEditor 自动刷新。

### 9.3 AssetClient 资产管线

`Mutant::assetClient_`(L684)持有 `AssetClient`,启用资产管线(`ENABLE_ASSET_PIPE`):

```cpp
// mutant.hpp L567-569
#ifdef ENABLE_ASSET_PIPE
    void setAssetClient( AssetClient* assetClient ) { assetClient_ = assetClient; }
#endif
```

启动壳绑定:`meApp_->mutant()->setAssetClient( meShell_->assetClient() );`

资产管线支持后台资产编译,编辑器可在资产编译完成后自动刷新。

### 9.4 纹理内存管理

`Mutant` 跟踪纹理内存占用:

```cpp
// mutant.hpp L249-256
bool texMemUpdate()
{
    bool val = texMemDirty_;
    texMemDirty_ = false;
    return val;
}
uint32 texMem() { return texMem_; }
```

- `texMemDirty_`:纹理内存脏标志,材质变化时设为 true
- `texMem_`:当前纹理内存占用(字节)
- `recalcTextureMemUsage()`(L553):重算纹理内存
- `materialSectionTextureMemUsage(data, texturesDone)`(L672):计算材质节点纹理内存

启动壳 `OnIdle` 通过 `texMemUpdate()` 检测变化并更新状态栏显示。

### 9.5 SuperModel 管理

`Mutant` 持有两个 `SuperModel`:

```cpp
// mutant.hpp L587-588
SuperModel* superModel_;                // 主 SuperModel(编辑目标)
SuperModel* editorProxySuperModel_;     // 编辑器代理 SuperModel(用于代理渲染)
```

`SuperModel` 是 BigWorld 模型系统的核心,聚合多个 `Model`、动画、动作、Dye。`Mutant` 通过 `SuperModel` 间接操作模型数据。

---

## 十、配置项与命令行参数

### 10.1 配置项

`modeleditor_core` 复用 `modeleditor.options` 配置文件(由启动壳加载),关键配置项:

| 配置键 | 用途 | 使用者 |
|--------|------|--------|
| `startup/loadLastModel` | 启动时加载上次模型 | 启动壳 |
| `startup/lastLoadOK` | 崩溃恢复标志 | 启动壳 |
| `models/file0` | 最近模型 | 启动壳 / MRU |
| `settings/regenBBOnLoad` | 加载时重算包围盒 | 启动壳 OnIdle |
| `settings/zoomOnLoad` | 加载时缩放 | 启动壳 OnIdle |
| `render/useUmbra` | Umbra 开关(强制禁用) | 启动壳 |
| `messages/errorMsgs` | 错误消息显示 | 启动壳 |
| `currentLanguage` / `currentCountry` | 当前语言 | PanelManager |
| `language` | 多语言文件列表 | 启动壳 |
| `help/shortcutsHtml` | 快捷键帮助 | - |

### 10.2 命令行参数

`modeleditor_core` 不直接处理命令行,由启动壳 `parseCommandLineMF` 解析 `-o`/`-O` 参数后,通过 `modelToLoad_` 传递给 `Mutant::loadModel`。

---

## 十一、与其他模块的依赖关系

### 11.1 依赖库列表

`modeleditor_core` 通过 `CMakeLists.txt` 链接以下库:

| 依赖库 | 用途 |
|--------|------|
| `appmgr` | `App`/`Options`/`Module`/`FrameworkModule` 应用管理 |
| `cstdmf` | `BWResource`/`DataSection`/`Singleton`/`Debug` 基础设施 |
| `chunk_scene_adapter` | `ChunkBspHolder` 区块 BSP 持有者(可选) |
| `editor_shared` | `IEditorApp`/`BaseMainFrame`/`BasePanelManager`/`IMainFrame`/`PythonAdapter`/`GuiTabContent`/`PropertyTable`/`MenuHelper` 编辑器共享层 |
| `guimanager` | `GUI::Manager`/`GUI::ActionMaker`/`GUI::UpdaterMaker`/`GUI::OptionMap` GUI 框架 |
| `input` | `KeyEvent`/`MouseEvent` 输入事件 |
| `moo` | `Moo::rc`/`SuperModel`/`EffectMaterial`/`Visual`/`ReloadListener`/`DrawContext` 渲染核心 |
| `physics2` | `BSP` 物理碰撞 |
| `post_processing` | `PostProcessing::Manager` 后处理 |
| `pyscript` | `Script`/`PyModule`/`PY_MODULE_FUNCTION` Python 集成 |
| `resmgr` | `BWResource`/`DataSection`/`XMLSection`/`StringProvider` 资源管理 |
| `romp` | `RompHarness`/`TimeOfDay`/`LensEffectManager` 环境 |
| `terrain` | `Terrain::Manager`/`TerrainSettings` 地形 |
| `tools_common` | `Floor`/`ToolsCamera`/`RompHarness`/`BaseMainFrame`/`BasePanelManager`/`Utilities` 工具公共 |
| `nvmeshmender` | 网格处理(可选) |
| `fmodsound` | 声音(可选) |

### 11.2 依赖关系图

```
                ┌──────────────────────┐
                │  modeleditor_core    │ (静态库, ~80 文件)
                └──────────┬───────────┘
                           │
       ┌───────────────────┼───────────────────┐
       │                   │                   │
       ▼                   ▼                   ▼
┌────────────┐    ┌──────────────┐    ┌──────────────┐
│ moo        │    │ editor_shared│    │ tools_common │
│(SuperModel/│    │(IEditorApp/  │    │(Floor/Tools- │
│ Visual/    │    │ BaseMain-    │    │  Camera/     │
│ Effect/    │    │  Frame/      │    │  RompHarness)│
│ Reload)    │    │  PropertyTable)│  └──────┬───────┘
└──────┬─────┘    └──────────────┘           │
       │                                     │
       ▼                                     ▼
┌────────────┐    ┌──────────────┐    ┌──────────────┐
│ physics2   │    │ guimanager   │    │ appmgr       │
│(BSP)       │    │(GUI::Manager)│    │(App/Options) │
└────────────┘    └──────────────┘    └──────────────┘
       │
       ▼
┌────────────────────────────────────────┐
│ resmgr(BWResource/DataSection)         │
│ cstdmf(Singleton/Debug)                │
│ pyscript(Script/PY_MODULE_FUNCTION)    │
│ romp(RompHarness/TimeOfDay)            │
│ terrain(Terrain::Manager)              │
│ post_processing(PostProcessing::Mgr)   │
│ input(KeyEvent/MouseEvent)             │
│ chunk_scene_adapter(ChunkBspHolder)    │
│ nvmeshmender(可选)                     │
└────────────────────────────────────────┘
```

### 11.3 被依赖关系

`modeleditor_core` 被 `modeleditor` 启动壳链接,提供:
- `MeShell`/`MeApp`/`MeModule`/`MEPythonAdapter` 三层运行时
- `CMainFrame`/`CModelEditorDoc`/`CModelEditorView`/`PanelManager` GUI 框架
- `Mutant` 模型编辑核心
- 7 个属性页面
- `ModelEditor` Python 模块

---

## 十二、关键代码片段

### 12.1 Mutant 类声明核心

```cpp
// mutant.hpp L207-220
class Mutant:
    public ReloadListener
#if ENABLE_BSP_MODEL_RENDERING
    , public ChunkBspHolder
#endif // ENABLE_BSP_MODEL_RENDERING
{
public:
    Mutant( bool groundModel, bool centreModel );
    ~Mutant();

    virtual void onReloaderReloaded( Reloader* pReloader );

    void registerModelChangeCallback( SmartPointer <ModelChangeCallback> mcc );
    void unregisterModelChangeCallback( void* parent );

    void groundModel( bool lock );
    void centreModel( bool lock );

    bool hasVisibilityBox( BW::string modelPath = "" );
    int animCount( BW::string modelPath = "" );
    bool nodefull( BW::string modelPath = "" );

    bool hasModel() const { return (superModel_ != NULL); }
    const BW::string& modelName() const { return modelName_; }
```

### 12.2 AnimationInfo 动画信息结构

```cpp
// mutant.hpp L52-82
class AnimationInfo
{
public:
    AnimationInfo();
    AnimationInfo(
        DataSectionPtr cData,
        DataSectionPtr cModel,
        SuperModelAnimationPtr cAnimation,
        BW::map< BW::string, float >& cBoneWeights,
        DataSectionPtr cFrameRates,
        ChannelsInfoPtr cChannels,
        float animTime,
        bool cIsReadOnly
    );
    ~AnimationInfo();

    Moo::AnimationPtr getAnim();
    Moo::AnimationPtr backupChannels();
    Moo::AnimationPtr restoreChannels();

    void uncompressAnim( Moo::AnimationPtr anim, BW::vector<Moo::AnimationChannelPtr>& oldChannels );
    void restoreAnim( Moo::AnimationPtr anim, BW::vector<Moo::AnimationChannelPtr>& oldChannels );

    DataSectionPtr data;
    DataSectionPtr model;
    SuperModelAnimationPtr animation;
    BW::map< BW::string, float > boneWeights;
    DataSectionPtr frameRates;
    ChannelsInfoPtr channels;
    bool isReadOnly;
};
```

### 12.3 LOD extent 读写(带 UndoRedo)

```cpp
// mutant_lod.cpp L34-52
void Mutant::lodExtent( const BW::string& modelFile, float extent )
{
	BW_GUARD;
	//First make sure the model exists
	if (models_.find(modelFile) == models_.end())
		return;

	UndoRedo::instance().add( new UndoRedoOp( 0, models_[modelFile], models_[modelFile] ));

	if (!isEqual( extent, Model::LOD_HIDDEN ))
	{
		models_[modelFile]->writeFloat( "extent", extent );
	}
	else
	{
		models_[modelFile]->delChild( "extent" );
	}
}
```

### 12.4 updateModelAnimations 渲染入口

```cpp
// mutant_render.cpp L32-78
void Mutant::updateModelAnimations( float atDist )
{
	BW_GUARD;
	if (!superModel_)
	{
		return;
	}

	Matrix world( Moo::rc().world() );
	world.preMultiply( this->transform( groundModel_, centreModel_ ) );

	TmpTransforms preTransformFashions;

	for (TransformFashionVector::const_iterator itr =
		transformFashions_.begin();
		itr != transformFashions_.end();
		++itr)
	{
		MF_ASSERT( (*itr).hasObject() );
		preTransformFashions.push_back( (*itr).get() );
	}

	if (!animMode_)
	{
		this->recreateFashions( true );
		for (TransformFashionVector::const_iterator itr =
			actionQueue_.transformFashions().begin();
			itr != actionQueue_.transformFashions().end();
			++itr)
		{
			MF_ASSERT( (*itr).hasObject() );
			preTransformFashions.push_back( (*itr).get() );
		}
	}

	if (!isEqual( virtualDist_, Model::LOD_AUTO_CALCULATE ))
	{
		atDist = virtualDist_;
	}

	superModel_->updateAnimations( world,
		&preTransformFashions,
		NULL,
		atDist );
}
```

### 12.5 IModelEditorApp 接口

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

### 12.6 MeApp 单例聚合

```cpp
// me_app.hpp L17-55
class MeApp
{
public:
	MeApp( IMainFrame * mainFrame, IModelEditorApp * editorApp );
	~MeApp();
	void initCamera();
	static MeApp & instance() { SINGLETON_MANAGER_WRAPPER( MeApp ) MF_ASSERT(s_instance_); return *s_instance_; }

	Floor*	floor();
	Mutant*	mutant();
	Lights*	lights();
	ToolsCameraPtr camera();

	Moo::LightContainerPtr blackLight() { return blackLight_; }
	Moo::LightContainerPtr whiteLight() { return whiteLight_; }

	void saveModel();
	void saveModelAs();
	bool canExit( bool quitting );
	void forceClean();
	bool isDirty() const;
private:
	static MeApp *		s_instance_;
	Floor*	floor_;
	Mutant*	mutant_;
	Lights*  lights_;
	Moo::LightContainerPtr blackLight_;
	Moo::LightContainerPtr whiteLight_;
	ToolsCameraPtr		camera_;
	IModelEditorApp *	editorApp_;
	IMainFrame *		mainFrame_;
};
```

### 12.7 MeModule 渲染模块

```cpp
// me_module.hpp L21-67
class MeModule : public FrameworkModule
{
public:
	MeModule();
	~MeModule();
	virtual bool init( DataSectionPtr pSection );
	virtual void onStart();
	virtual int  onStop();
	virtual bool updateState( float dTime );
	bool renderThumbnail( const BW::string& fileName );
	virtual void updateAnimations();
	virtual void render( float dTime );
	virtual bool handleKeyEvent( const KeyEvent & event );
	virtual bool handleMouseEvent( const MouseEvent & event );
	static MeModule& instance() { ... }
	float averageFPS() const { return averageFps_; }
	bool materialPreviewMode() const { return materialPreviewMode_; }
	void materialPreviewMode( bool on ) { materialPreviewMode_ = on; }
private:
	void beginRender();
	void endRender();
	void renderChunks( Moo::DrawContext& drawContext );
	void renderTerrain( float dTime = 0.f, bool shadowing = false );
	void renderOpaque( Moo::DrawContext& drawContext, float dTime);
	void renderFixedFunction( Moo::DrawContext& drawContext, float dTime );
    void updateModel( Moo::DrawContext& drawContext, float dTime );
	void setLights( bool checkForSparkles, bool useCustomLighting );
	// ...
};
```

### 12.8 PanelManager 面板管理

```cpp
// panel_manager.hpp L18-23
class PanelManager :
	public Singleton<PanelManager>,
	public GUI::ActionMaker<PanelManager>,
	public GUI::UpdaterMaker<PanelManager>,
	public BasePanelManager
{
public:
	~PanelManager();
	static bool init(
		CFrameWnd* mainFrameWnd, CWnd* mainView,
		IModelEditorApp * editorApp, IMainFrame * mainFrame );
	static void fini();
	bool ready();
	void showPanel( const BW::string& pyID, int show = 1 );
	int isPanelVisible( const BW::string& pyID );
	// ...
	GUITABS::Manager& panels() { return panels_; }
	IModelEditorApp * getEditorApp() const { return editorApp_; }
private:
	BW::map< BW::string, BW::wstring > contentID_;
	int currentTool_;
	GUITABS::Manager panels_;
	UalManager ualManager_;
	IModelEditorApp * editorApp_;
	// ...
};
```

---

## 十三、设计亮点与注意事项

### 13.1 设计亮点

| 亮点 | 说明 |
|------|------|
| **Mutant 七文件拆分** | 上帝对象按职责拆分为 7 个 cpp(actions/animations/lod/materials/render/validation + 核心),平衡了内聚与文件大小 |
| **ReloadListener 热重载** | `Mutant` 继承 `ReloadListener` 监听 `SuperModel` 重载,支持外部修改自动刷新 |
| **DataSection 数据模型** | 所有模型数据以 XML DataSection 存储,易于序列化与 UndoRedo 快照 |
| **UndoRedo 快照机制** | `UndoRedoOp` 保存 DataSection 快照,实现可靠的撤销重做 |
| **Fashion 装扮系统** | `MaterialFashion`/`TransformFashion` 解耦材质与变换装扮,支持动态 Dye 切换 |
| **PropertyTable 反射编辑** | `PageMaterials` 通过 `PropertyTable` + `MaterialPropertiesUser` 反射式编辑材质属性 |
| **GUITABS 撕离标签** | 页面通过 `IMPLEMENT_BASIC_CONTENT` 宏注册,支持撕离与自由布局 |
| **Python 全暴露** | `ModelEditor` 模块暴露所有能力,支持 UI 适配层 Python 化与自动化测试 |
| **AssetClient 资产管线** | `ENABLE_ASSET_PIPE` 支持后台资产编译,编辑器自动刷新 |
| **纹理内存跟踪** | `texMemUpdate`/`texMem`/`recalcTextureMemUsage` 实时跟踪纹理内存,辅助优化 |
| **接口反转** | `IModelEditorApp` 接口让核心库不反向依赖启动壳,支持独立复用 |

### 13.2 注意事项

| 注意点 | 说明 |
|--------|------|
| **Mutant 上帝对象** | `Mutant` 聚合所有状态,代码量大(mutant.cpp ~1000 行 + 6 个子文件),维护需谨慎 |
| **ENABLE_BSP_MODEL_RENDERING** | `Mutant` 可选继承 `ChunkBspHolder`,取决于 `ENABLE_BSP_MODEL_RENDERING` 宏 |
| **可选 ChunkBspHolder** | `#if ENABLE_BSP_MODEL_RENDERING` 条件编译,禁用时 `Mutant` 不继承 `ChunkBspHolder` |
| **ENABLE_ASSET_PIPE** | `AssetClient` 相关代码受 `ENABLE_ASSET_PIPE` 宏控制 |
| **SuperModel 生命周期** | `superModel_` 由 `Mutant` 管理,需在析构时正确释放 |
| **DataSection 引用** | `models_`/`animations_`/`actions_` 等映射持有 DataSection 引用,需注意 `DataSectionCensus` 的普查 |
| **UndoRedo 屏障** | 复杂操作需通过 `addUndoBarrier` 分组,避免撤销时破坏中间状态 |
| **onReloaderReloaded 同步** | `SuperModel` 重载后需在 `onReloaderReloaded` 中更新所有关联数据,否则数据不一致 |
| **材质系统复杂性** | Matter/Tint/Dye/MFM 四层抽象,理解曲线较陡 |
| **动画压缩预览** | `backupChannels`/`restoreChannels` 用于压缩预览,需成对调用 |
| **isSkyBox 标志** | `isSkyBox_` 标识天空盒模型,影响材质处理逻辑 |

### 13.3 Mutant 七文件拆分的优劣

| 优势 | 劣势 |
|------|------|
| 按职责分文件,便于定位 | 类仍是上帝对象,内聚性不足 |
| 单文件不过大(200-1200 行) | 跨文件共享私有成员,封装较弱 |
| 便于多人并行开发不同职责 | 修改核心数据结构需触及多文件 |
| 渲染/验证/材质可独立测试 | 文件间依赖隐式(通过 this 指针) |

### 13.4 与 ParticleEditor 的对比

| 维度 | modeleditor_core | particle_editor |
|------|------------------|-----------------|
| 核心对象 | `Mutant`(7 文件拆分) | `MainFrame` + `PeModule` |
| 数据模型 | `DataSection`(XML) | `MetaParticleSystem`/`ParticleSystem` |
| 撤销重做 | `UndoRedo` + `UndoRedoOp`(DataSection 快照) | `UndoRedo::Operation` + `UndoRedoOp`(DataSection 快照) |
| 属性页面 | 7 个(GuiTabContent) | 16+ PSA 属性对话框 |
| Python 模块 | `ModelEditor` | `ParticleEditor` |
| 状态机 | 无 | `PE_PLAYING`/`PE_PAUSED`/`PE_STOPPED` |
| 渲染模块 | `MeModule` | `PeModule` |
| 热重载 | `ReloadListener` | 无(粒子系统无热重载) |

---

## 总结

`modeleditor_core` 是 BigWorld 工具链中**模型编辑器的业务核心库**,约 80 文件,通过 `Mutant` 上帝对象(7 文件拆分)承载模型加载、动画/动作/LOD/材质编辑、渲染、验证等全部职责。其核心价值在于:

1. **上帝对象 + 职责拆分**:`Mutant` 集中管理所有模型状态,按职责拆分为 7 个 cpp,平衡内聚与可维护性。
2. **DataSection 数据模型**:所有数据以 XML 存储,支持可靠 UndoRedo 快照与序列化。
3. **ReloadListener 热重载**:`SuperModel` 重载自动刷新,提升编辑体验。
4. **Fashion 装扮系统**:`MaterialFashion`/`TransformFashion` 解耦材质与变换,支持动态 Dye。
5. **PropertyTable 反射编辑**:材质页面通过反射式编辑属性,减少重复代码。
6. **Python 全暴露**:`ModelEditor` 模块暴露所有能力,支持 UI 适配与自动化。
7. **接口反转**:`IModelEditorApp` 接口实现壳/核解耦,核心库可独立复用。

配合 `modeleditor` 启动壳(详见《BigWorld 工具 modeleditor 实现分析》),构成完整的模型编辑器。

---

**参考源文件**:
- `programming/bigworld/tools/modeleditor_core/i_model_editor_app.hpp`(L1-46)
- `programming/bigworld/tools/modeleditor_core/App/me_app.hpp`(L1-60)
- `programming/bigworld/tools/modeleditor_core/App/me_shell.hpp`(L1-150)
- `programming/bigworld/tools/modeleditor_core/App/me_module.hpp`(L1-137)
- `programming/bigworld/tools/modeleditor_core/App/me_scripter.hpp`(L1-26)
- `programming/bigworld/tools/modeleditor_core/Models/mutant.hpp`(L1-686)
- `programming/bigworld/tools/modeleditor_core/Models/mutant_lod.cpp`(L1-120+)
- `programming/bigworld/tools/modeleditor_core/Models/mutant_render.cpp`(L1-80+)
- `programming/bigworld/tools/modeleditor_core/GUI/main_frm.h`(L1-100)
- `programming/bigworld/tools/modeleditor_core/GUI/panel_manager.hpp`(L1-102)
- `programming/bigworld/tools/modeleditor_core/Pages/page_materials.hpp`(L1-60+)
