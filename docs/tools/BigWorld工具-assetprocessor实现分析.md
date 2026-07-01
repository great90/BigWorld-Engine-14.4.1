# BigWorld 工具 assetprocessor 实现分析

> 本文档详细分析 BigWorld Engine 14.4.1 中 assetprocessor 模块的架构与实现。assetprocessor 是一个 Windows DLL,以 Python 扩展模块 `_AssetProcessor` 的形式存在,封装了需要在 D3D 渲染设备上完成的资产升级/编译操作,主要包括 BSP2 升级、Shader 编译、顶点格式升级等。它是连接 Python 资产处理脚本与底层 Moo 渲染层/物理层的桥梁。

---

## 目录

- [一、概述与定位](#一概述与定位)
- [二、整体架构](#二整体架构)
- [三、目录结构](#三目录结构)
- [四、入口点与启动流程](#四入口点与启动流程)
  - [4.1 DLL 入口点 DllMain](#41-dll-入口点-dllmain)
  - [4.2 Python 模块入口 init_AssetProcessor](#42-python-模块入口-init_assetprocessor)
  - [4.3 init 初始化序列](#43-init-初始化序列)
- [五、核心类与模块组织](#五核心类与模块组织)
  - [5.1 AssetProcessorScript 命名空间](#51-assetprocessorscript-命名空间)
  - [5.2 与 Moo/Renderer 的耦合](#52-与-moo-renderer-的耦合)
  - [5.3 渲染窗口与 WndProc](#53-渲染窗口与-wndproc)
- [六、关键算法与功能](#六关键算法与功能)
  - [6.1 generateBSP2 —— 生成 BSP2 数据](#61-generatebsp2--生成-bsp2-数据)
  - [6.2 replaceBSPData —— 写回 .primitives](#62-replacebspdata--写回-primitives)
  - [6.3 updateBSPVersion —— BSP 版本升级主流程](#63-updatebspversion--bsp-版本升级主流程)
  - [6.4 upgradeHardskinnedVertices —— 顶点格式升级](#64-upgradehardskinnedvertices--顶点格式升级)
  - [6.5 compileShader —— Shader 编译](#65-compileshader--shader-编译)
  - [6.6 getShaderMacros / shaderNeedsRecompile](#66-getshadermacros--shaderneedsrecompile)
  - [6.7 outsideChunkIdentifier / getGuid / convertBase64DataSection](#67-outsidechunkidentifier--getguid--convertbase64datasection)
- [七、Python 模块导出表](#七python-模块导出表)
- [八、配置项与依赖](#八配置项与依赖)
- [九、与其他模块的依赖关系](#九与其他模块的依赖关系)
- [十、关键代码片段](#十关键代码片段)
- [十一、设计亮点与注意事项](#十一设计亮点与注意事项)

---

## 一、概述与定位

`assetprocessor` 是 BigWorld Engine 工具链中**唯一需要 D3D 渲染设备的资产处理模块**。其定位是:

> "把那些必须依赖 D3D 设备才能完成的资产操作封装起来,供 Python 脚本按需调用。"

与 `asset_pipeline` 不同,asset_pipeline 处理的是"声明式依赖 + 纯文件转换",而 assetprocessor 处理的是**那些必须运行时加载 visual/primitives、调用 D3D 编译 shader 的"重度"操作**。典型场景包括:

1. **BSP2 升级**:把旧版本 `.visual`/`.primitives` 中的 BSP 数据升级到 BSP2 格式,涉及读取几何、构建 BSP 树、写回二进制。
2. **Shader 编译**:通过 `Moo::EffectCompiler` 把 `.fx` 文件按指定宏组合编译为可执行的 effect。
3. **顶点格式升级**:把硬皮(hardskinned)顶点升级为软皮(softskinned)顶点,以适配新版 shader pipeline。
4. **辅助工具**:`outsideChunkIdentifier`(根据坐标查 chunk)、`getGuid`(生成 GUID)、`convertBase64DataSection`(把 base64 字符串 section 转为 UTF-8)。

它以 **DLL**(`assetprocessor.dll`)形态发布,通过 Python 的 `import _AssetProcessor` 加载,所有功能以 `AssetProcessor.<func>(...)` 形式调用。这使 BigWorld 的资产处理脚本(通常在 `tools/assets/war/asset_processor.py` 之类位置)能在不直接编译 C++ 的前提下,获得渲染层能力。

assetprocessor 代码量约 1250 行,核心实现在 `asset_processor_script.cpp`(1119 行),其余为 DLL 框架与 PCH。

---

## 二、整体架构

assetprocessor 是一个**薄薄的 C++/Python 桥接层**,其架构非常简单——所有逻辑都在 `AssetProcessorScript` 命名空间内,通过 `PY_AUTO_MODULE_FUNCTION` 宏导出为 Python 函数:

```
┌──────────────────────────────────────────────────────────────────┐
│              Python 脚本(资产升级脚本)                          │
│   import _AssetProcessor                                         │
│   _AssetProcessor.updateBSPVersion("objects/foo.visual")         │
│   _AssetProcessor.compileShader("shaders/foo.fx", macros, True)  │
└──────────────────────────────────────────────────────────────────┘
                              │ ctypes / PyCFunction
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│                  assetprocessor.dll                              │
│  ┌─────────────────────────────┐  ┌────────────────────────────┐ │
│  │ assetprocessor.cpp          │  │ asset_processor_script.cpp │ │
│  │  - DllMain                  │  │  - init() / fini()         │ │
│  │  - init_AssetProcessor()    │─▶│  - generateBSP2()          │ │
│  │  (Python 模块注册入口)      │  │  - replaceBSPData()        │ │
│  └─────────────────────────────┘  │  - updateBSPVersion()      │ │
│                                   │  - upgradeHardskinnedVertices() │
│                                   │  - compileShader()         │ │
│                                   │  - getShaderMacros()       │ │
│                                   │  - outsideChunkIdentifier()│ │
│                                   │  - convertBase64DataSection()│ │
│                                   └────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────┘
                              │ 调用
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Moo 渲染层 (lib/moo)                                            │
│   - Moo::init / Moo::rc().createDevice                           │
│   - Moo::Visual / Moo::VisualLoader                              │
│   - Moo::VerticesManager / Moo::PrimitiveManager                 │
│   - Moo::EffectCompiler / Moo::EffectMacroSetting                │
│   - Moo::BSPProxy / Moo::BSPMaterialIDs                          │
│  Physics2 (lib/physics2)                                         │
│   - BSPTreeTool::buildBSP / saveBSPInMemory                      │
│   - MaterialKinds                                                │
│  ResMgr (lib/resmgr)                                             │
│   - BWResource / DataSection / XMLSection                        │
│  PyScript (lib/pyscript)                                         │
│   - Script::init / PyDataSection                                 │
│  EntityDef (lib/entitydef)                                       │
│   - EntityDef::Constants::entitiesClientPath()                   │
└──────────────────────────────────────────────────────────────────┘
```

assetprocessor **没有自己的状态机或调度器**,所有操作都是无状态的一次性调用——Python 调一次,D3D 处理一次,返回结果。这与 `asset_pipeline` 的复杂状态机形成鲜明对比。

---

## 三、目录结构

assetprocessor 源码位于 `programming/bigworld/tools/assetprocessor/`,目录结构非常简洁:

```
assetprocessor/
├── pch.hpp                 # 预编译头(包含 BW 标准头)
├── pch.cpp                 # PCH 实现
├── assetprocessor.hpp      # DLL 导出宏 + init_AssetProcessor 声明
├── assetprocessor.cpp      # DllMain + init_AssetProcessor(53 行)
├── asset_processor_script.hpp  # AssetProcessorScript 命名空间声明
└── asset_processor_script.cpp  # 全部业务逻辑(1119 行)
```

构建产物为 `assetprocessor.dll`,运行时由 Python 通过 `import _AssetProcessor` 触发加载(模块名带下划线前缀是 Python C 扩展的命名约定)。

---

## 四、入口点与启动流程

assetprocessor 有两个层次的入口:DLL 入口(`DllMain`)与 Python 模块入口(`init_AssetProcessor`)。

### 4.1 DLL 入口点 DllMain

`assetprocessor.cpp:31-51` 定义了标准 Windows DLL 入口:

```cpp
31→BOOL __stdcall DllMain( HANDLE hModule, DWORD Reason, LPVOID Reserved )
32→{
34→	// The lpvReserved parameter to DllMain is NULL if the DLL is being
35→	// unloaded because of a call to FreeLibrary, it?s non NULL if the
36→	// DLL is being unloaded due to process termination.
42→	// This check is here as a fail-safe, but you should call
43→	// _AssetProcessor.fini explicitly from script instead of relying
44→	// on the OS/display driver cleaning up everything for us.
46→	if (Reason == DLL_PROCESS_DETACH && Reserved == 0)
47→	{
48→		AssetProcessorScript::fini();
49→	}
50→	return TRUE;
51→}
```

关键点:
- L46 的 `Reserved == 0` 判断很关键——只有显式 `FreeLibrary` 才会调用 `fini()`,进程终止时(`Reserved != 0`)不调用。这是因为 D3D DLL 卸载顺序不可控,进程终止时调用 `fini` 可能访问已释放的 D3D 资源导致崩溃。
- 注释明确建议**从 Python 脚本显式调用 `_AssetProcessor.fini()`,不要依赖 OS 清理**。这是个非常典型的 D3D + DLL 卸载顺序问题。

### 4.2 Python 模块入口 init_AssetProcessor

`assetprocessor.cpp:21-28` 是 Python C 扩展的标准入口(模块名 `init_<modulename>`):

```cpp
21→ASSETPROCESSOR_API void init_AssetProcessor()
22→{
23→	AssetProcessorScript::init();
24→	PyErr_Clear();
27→	return;
28→}
```

Python 解释器执行 `import _AssetProcessor` 时会查找符号 `init_AssetProcessor` 并调用一次,完成所有初始化。`PyErr_Clear()` 用于吞掉初始化过程中的非致命 Python 错误。

`assetprocessor.hpp:16-21` 用 `extern "C"` 暴露这个符号,确保 C 链接不被 C++ name mangling 破坏:

```cpp
16→extern "C"
17→{
19→	extern ASSETPROCESSOR_API void init_AssetProcessor();
21→}
```

`ASSETPROCESSOR_API` 宏根据 `ASSETPROCESSOR_EXPORTS`/`ASSETPROCESSOR_IMPORTS` 决定是 `__declspec(dllexport)` 还是 `dllimport`,编译 DLL 时定义 `ASSETPROCESSOR_EXPORTS`。

### 4.3 init 初始化序列

`AssetProcessorScript::init`(`asset_processor_script.cpp:87-156`)是 assetprocessor 的核心初始化逻辑:

```cpp
87→void init()
88→{
89→    if (g_inited) return;                          // 防止重复初始化
94→    int argc = 0;
95→    if (!BWResource::init( argc, NULL )) return;   // 初始化资源管理器
100→    volatile int tokens = PyLogging_token | ResMgr_token;  // 触发静态 token 注册
102→    PyImportPaths paths;
103→    paths.addResPath( EntityDef::Constants::entitiesClientPath() );
105→    if (!Script::init( paths, "assetprocessor" )) return;  // 初始化 Python 解释器
110→    if (!MaterialKinds::init())                    // 物理材质表
113→        return;
117→    AutoConfig::configureAllFrom( "resources.xml" ); // shader include 路径配置
121→    Moo::init( true, true );                       // Moo 渲染层初始化
125→    HINSTANCE hInst = ::GetModuleHandle(NULL);
127→    WNDCLASS wc = { CS_HREDRAW | CS_VREDRAW, WndProc, 0, 0, hInst, NULL, cursor, NULL, NULL, APP_NAME };
128→    if( !RegisterClass( &wc ) ) return;
130→    HWND hWnd = CreateWindow( APP_NAME, APP_NAME, WS_OVERLAPPED, 0, 0, 256, 256, NULL, NULL, hInst, NULL );
132→    s_pRenderer.reset( new Renderer );
133→    s_pRenderer->init( true, true );               // 创建渲染器
135→    Moo::rc().createDevice( hWnd );                // 在 hWnd 上创建 D3D 设备
137→    DataSectionPtr ptr = BWResource::instance().openSection("shaders/formats");
138→    if (ptr)
139→    {
140→        DataSectionIterator it = ptr->begin();
141→        DataSectionIterator end = ptr->end();
142→        while (it != end)
143→        {
144→            BW::string format = (*it)->sectionName();
145→            size_t off = format.find_first_of( "." );
146→            format = format.substr( 0, off );
147→            Moo::VertexDeclaration::get( format ); // 预创建顶点声明
148→            it++;
149→        }
150→    }
152→    PyObject * pRMModule = PyImport_AddModule( "_AssetProcessor" );  // 注册 Python 模块
154→    g_inited = true;
155→}
```

初始化的关键步骤:

| 步骤 | 代码位置 | 作用 |
|---|---|---|
| 1. 防重入 | L89 | `g_inited` 标志位 |
| 2. BWResource::init | L95 | 资源路径初始化(此时已通过 Python 进程的 sys.path 配置) |
| 3. Script::init | L105 | 启动 Python 解释器(如果尚未启动) |
| 4. MaterialKinds::init | L110 | 加载 material_kinds.xml,物理碰撞用 |
| 5. AutoConfig | L117 | 读 resources.xml,自动配置 shader include 等路径 |
| 6. Moo::init | L121 | Moo 静态初始化 |
| 7. RegisterClass + CreateWindow | L127-130 | 创建一个 256×256 的隐藏窗口作为 D3D 设备载体 |
| 8. Renderer::init | L132-133 | 创建 Renderer 对象并初始化 |
| 9. Moo::rc().createDevice | L135 | 在窗口上创建 D3D 设备 |
| 10. 预创建顶点声明 | L137-150 | 遍历 `shaders/formats/*`,提前注册所有顶点格式 |
| 11. 注册 Python 模块 | L153 | `PyImport_AddModule("_AssetProcessor")` |

注意 L130 创建的窗口是**WS_OVERLAPPED 但不 ShowWindow**——它只是 D3D 设备的载体,不会显示给用户。这种"隐藏窗口 + D3D 设备"模式是离屏 D3D 处理的标准做法。

`fini()`(`asset_processor_script.cpp:159+`)执行相反操作:`Moo::rc().releaseDevice()`、`Renderer::fini`、`Script::fini` 等。

---

## 五、核心类与模块组织

### 5.1 AssetProcessorScript 命名空间

assetprocessor 的全部业务都在 `AssetProcessorScript` 命名空间内,这是一个**纯函数集合**,没有类层次。`asset_processor_script.hpp:17-35` 声明了对外可见的 4 个函数:

```cpp
17→namespace AssetProcessorScript
18→{
19→	void init();
20→	void fini();
21→
22→	int populateWorldTriangles( Moo::Visual::Geometry& geometry,
23→							RealWTriangleSet & ws,
24→							const Matrix & m,
25→							BW::vector<BW::string>& materialIDs );
26→
27→	BW::string generateBSP2( const BW::string& resourceID,
28→								Moo::BSPProxyPtr& ret,
29·								BW::vector<BW::string>& retMaterialIDs,
30→								uint32& nVisualTris,
31→								uint32& nDegenerateTris );
32→	BW::string replaceBSPData( const BW::string& visualName,
33·								Moo::BSPProxyPtr pGeneratedBSP,
34·								BW::vector<BW::string>& bspMaterialIDs );
35→};
```

其余函数(`updateBSPVersion`、`upgradeHardskinnedVertices`、`compileShader` 等)是 `static` 函数,只通过 `PY_AUTO_MODULE_FUNCTION` 导出给 Python,C++ 内部不可见。这种设计避免了全局命名空间污染。

### 5.2 与 Moo/Renderer 的耦合

assetprocessor 的核心依赖是 `Moo` 渲染层。`asset_processor_script.cpp:13-26` 包含的 Moo 头文件揭示了它的能力范围:

```cpp
13→#include "moo/init.hpp"
14→#include "moo/managed_effect.hpp"
15→#include "moo/effect_macro_setting.hpp"
16→#include "moo/effect_compiler.hpp"
17→#include "moo/node.hpp"
18→#include "moo/primitive_file_structs.hpp"
19→#include "moo/primitive_manager.hpp"
20→#include "moo/render_context.hpp"
21→#include "moo/texture_manager.hpp"
22→#include "moo/vertices_manager.hpp"
23→#include "moo/visual.hpp"
24→#include "moo/visual_common.hpp"
25→#include "moo/visual_manager.hpp"
26→#include "moo/renderer.hpp"
```

具体来说:

- **`Moo::Visual` + `Moo::VisualLoader`**:加载 `.visual` 文件,提取 renderSet/geometry/primitiveGroup。
- **`Moo::VerticesManager` + `Moo::PrimitiveManager`**:管理 `.primitives` 文件中的顶点缓冲与索引缓冲。
- **`Moo::Node`**:骨骼节点树,用于蒙皮几何的变换。
- **`Moo::EffectCompiler` + `Moo::EffectMacroSetting`**:编译 `.fx` effect 文件。
- **`Moo::BSPProxy` + `Moo::BSPMaterialIDs`**:BSP 树代理与材质 ID 列表。
- **`Moo::VertexDeclaration::get`**:预创建顶点声明,D3D InputLayout 缓存。
- **`Moo::rc()`**:RenderContext,通过 `createDevice` 持有 D3D 设备。

`Renderer` 类(`moo/renderer.hpp`)是更高层的渲染器抽象,在 assetprocessor 中只用到其 `init/fini`,不调用实际渲染方法——assetprocessor 不需要绘制,只需要 D3D 设备的"副作用"(编译 shader、加载资源)。

### 5.3 渲染窗口与 WndProc

assetprocessor 必须维护一个 Windows 窗口作为 D3D 设备的容器,`asset_processor_script.cpp:60-77` 实现了窗口过程:

```cpp
60→LRESULT CALLBACK WndProc( HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam )
61→{
62→    switch (msg) {
64→    case WM_SYSCOMMAND:
65→        if ((wParam & 0xFFF0) == SC_CLOSE)
66→            PostQuitMessage(0);   // 关闭请求 → 退出消息循环
68→        break;
71→    case WM_DESTROY:
72→        PostQuitMessage(0);
73→        break;
75→    }
77→    return DefWindowProc( hWnd, msg, wParam, lParam );
78→}
```

由于 assetprocessor 不运行消息循环(它只是被 Python 同步调用),`WndProc` 实际上只处理关闭/销毁消息。但它的存在是必要的——D3D 设备创建需要一个有效的 HWND。

---

## 六、关键算法与功能

### 6.1 generateBSP2 —— 生成 BSP2 数据

`generateBSP2`(`asset_processor_script.cpp:383-577`)是 assetprocessor 最复杂的函数,负责从一个 `.visual` 资源重建 BSP2 数据。BSP2 是 BigWorld 用于碰撞检测与空间划分的二叉树结构。

函数签名(出参全是引用,返回错误字符串):

```cpp
383→BW::string generateBSP2( const BW::string& resourceID,
384→                         Moo::BSPProxyPtr& pBSP,             // 输出:生成的 BSP 代理
385→                         BW::vector<BW::string>& materialIDs, // 输出:每个 primitiveGroup 的材质 ID
386→                         uint32& nVisualTris,                 // 输出:visual 总三角形数
387→                         uint32& nDegenerateTris )            // 输出:退化三角形数
```

核心流程:

1. **打开资源**:`BWResource::instance().rootSection()->openSection( resourceID )`,失败返回错误字符串。
2. **加载节点树**:`root->openSection("node")` → `Moo::Node::loadRecursive`,没有则创建名为 "root" 的空节点。
3. **遍历 renderSets**:对每个 renderSet,读取其关联的节点列表 `nodes`。如果没指定节点,强制使用 rootNode。
4. **计算 firstNodeStaticWorldTransform**:从主节点向上遍历到 root,累乘变换矩阵(用于把几何变换到世界空间)。
5. **遍历 geometries**:对每个 geometry:
   - 通过 `Moo::VerticesManager::instance()->get(verticesName)` 加载顶点。
   - 通过 `Moo::PrimitiveManager::instance()->get(indicesName)` 加载索引。
   - 遍历 `primitiveGroup` 子节点,提取材质 ID(`getMaterialIdentifier`),创建 `Moo::ComplexEffectMaterial`(只设置 ID,不真正加载材质)。
   - 累计 `nVisualTris += geometry.nTriangles()`。
   - 调用 `populateWorldTriangles` 把几何三角形变换到世界空间,加入 `tris` 集合,同时统计退化三角形数 `nDegenerateTris`。
6. **构建 BSP**:`pBSP = new Moo::BSPProxy( BSPTreeTool::buildBSP( tris ) )`。

关键代码片段(`asset_processor_script.cpp:439-466`):

```cpp
439→    BW::vector< DataSectionPtr >::iterator rsit = renderSets.begin();
441→    while (rsit != rsend)
442→    {
443→        DataSectionPtr renderSetSection = *rsit;
444→        ++rsit;
445→        Moo::Visual::RenderSet renderSet;
448→        renderSet.treatAsWorldSpaceObject_ = renderSetSection->readBool( "treatAsWorldSpaceObject" );
450→        BW::vector< BW::string > nodes;
452→        renderSetSection->readStrings( "node", nodes );
455→        if (nodes.size())
457→        {
459→            BW::vector< BW::string >::iterator it = nodes.begin();
461→            while (it != end)
462→            {
463→                Moo::NodePtr node = rootNode_->find( *it );
464→                if (!node)
465→                {
466→                    ret = "Couldn't find node " + (*it) + " in " + resourceID;
467→                    return ret;
468→                }
471→                renderSet.transformNodes_.push_back( node );
473→                ++it;
474→            }
475→        }
478→        else
479→            renderSet.transformNodes_.push_back( rootNode_ );
```

L483-491 的变换矩阵计算值得注意:

```cpp
483→        Moo::NodePtr pMainNode = renderSet.transformNodes_.front();
484→        renderSet.firstNodeStaticWorldTransform_ = pMainNode->transform();
486→        while (pMainNode != rootNode_)
487→        {
488→            pMainNode = pMainNode->parent();
489→            renderSet.firstNodeStaticWorldTransform_.postMultiply(
490→                pMainNode->transform() );
491→        }
```

这是**静态世界变换**的计算——从主节点向上累乘父节点变换,得到该 renderSet 在世界空间的变换矩阵。注意这忽略了动画(因为 BSP 是静态碰撞用),只取绑定姿势。

L569-574 的 BSP 构建判断也很关键:

```cpp
569→    if (!tris.empty())
570→    {
571→        pBSP = new Moo::BSPProxy( BSPTreeTool::buildBSP( tris ) );
572→    }
573→    //else no BSP for you.  this means the vertices are skinned and should
574→    //not have a BSP.  this is fine.
```

注释明确:**蒙皮几何不生成 BSP**——因为蒙皮顶点会随动画变化,静态 BSP 没有意义。

### 6.2 replaceBSPData —— 写回 .primitives

`replaceBSPData`(`asset_processor_script.cpp:583-648`)把 `generateBSP2` 生成的 BSP 数据写回到 `.primitives` 文件:

```cpp
583→BW::string replaceBSPData( const BW::string& visualName,
584·                            Moo::BSPProxyPtr pGeneratedBSP,
585·                            BW::vector<BW::string>& bspMaterialIDs )
586→{
588·    BWResource::instance().purgeAll();                  // 清缓存,确保读到最新文件
591→    BW::string primResName = BWResource::removeExtension( visualName ) + ".primitives";
593→    const BW::string tempBSPName( "\\temp.bsp" );
596→    BinaryPtr bp = BSPTreeTool::saveBSPInMemory( pGeneratedBSP->pTree() );
598→    if (bp)
599→    {
600→        // ... 用 BinaryBlock 写入 .primitives 文件,替换原有 bsp section
648→}
```

注意 L588 的 `BWResource::instance().purgeAll()`——assetprocessor 必须在写回前清空资源缓存,否则可能写到旧文件句柄上。

### 6.3 updateBSPVersion —— BSP 版本升级主流程

`updateBSPVersion`(`asset_processor_script.cpp:650-779`)是对外暴露的 Python 函数,封装了完整的 BSP 升级流程:

```cpp
650→static BW::string updateBSPVersion( const BW::string& visualName )
651→{
654→    bool wasNewVersion = false;
656→    bool wasBrokenBSP2 = false;
657→    Moo::VisualLoader< Moo::Visual > loader( baseName( visualName ) );
660→    Moo::BSPMaterialIDs     bspMaterialIDs;
661→    Moo::Visual::BSPTreePtr pFoundBSP;
662→    bool bspRequiresMapping = loader.loadBSPTree( pFoundBSP, bspMaterialIDs );
664→    wasNewVersion = bspRequiresMapping;
666→    if (wasNewVersion)
667→    {
668→        if (bspMaterialIDs.empty())
670→            wasBrokenBSP2 = true;   // 新版但 material IDs 空 → 损坏
672→        else
674→            return "";              // 已是新版本,无需升级
675→    }
679→    bool originalFileHadBSP = (pFoundBSP != NULL);
680→    int nFoundBSPTriangles = 0;
681→    if (originalFileHadBSP)
683→        nFoundBSPTriangles = pFoundBSP->pTree()->numTriangles();
691→    Moo::BSPProxyPtr pGeneratedBSP = NULL;
693→    uint32 nVisualTris = 0;
694→    uint32 nDegenerateTris = 0;
694→    ret = AssetProcessorScript::generateBSP2(
695→        visualName, pGeneratedBSP, bspMaterialIDs, nVisualTris, nDegenerateTris );
701→    if (!ret.empty()) return ret;   // 生成失败
707→    if (pGeneratedBSP)
708→    {
716→        int nGeneratedBSPTriangles = pGeneratedBSP->pTree()->numTriangles();
717→        bool triCountEqual = ( nGeneratedBSPTriangles == nFoundBSPTriangles &&
718·            (nFoundBSPTriangles + nDegenerateTris) == nVisualTris );
720·        if ( triCountEqual || (nFoundBSPTriangles == 0) )
721·        {
723·            AssetProcessorScript::replaceBSPData( visualName, pGeneratedBSP, bspMaterialIDs );
724·            ret = "";
725·        }
726·        else
728·            ret = visualName + " has a custom BSP.  Please re-export this visual manually.";
730→    }
```

这个函数的关键判断逻辑:

| 场景 | 判断条件 | 处理 |
|---|---|---|
| 已是新版本且完好 | `wasNewVersion && !bspMaterialIDs.empty()` | 直接返回 "" |
| 新版本但损坏 | `wasNewVersion && bspMaterialIDs.empty()` | `wasBrokenBSP2 = true`,继续重建 |
| 旧版本有 BSP | `originalFileHadBSP` | 重建后比较三角形数 |
| 三角形数匹配 | `nGeneratedBSPTriangles == nFoundBSPTriangles && nFoundBSPTriangles + nDegenerateTris == nVisualTris` | 写回新 BSP |
| 三角形数不匹配 | 上面的否定 | 视为 custom BSP,要求手动重导出 |
| 无 BSP(蒙皮) | `pGeneratedBSP == NULL && !originalFileHadBSP` | 返回 ""(正常) |
| 无 BSP 但原来有 | `pGeneratedBSP == NULL && originalFileHadBSP` | 错误,要求手动检查 |

L709-718 的三角形数校验非常巧妙——它**同时检查生成 BSP 的三角形数与原 BSP 是否一致,以及 `原 BSP + 退化 = visual` 是否一致**。这种双重校验能有效识别 custom BSP(美术手动编辑过的 BSP),避免误覆盖。

### 6.4 upgradeHardskinnedVertices —— 顶点格式升级

`upgradeHardskinnedVertices`(`asset_processor_script.cpp:797-878`)把硬皮顶点升级为软皮顶点。这是 BigWorld 在某个版本移除硬皮 shader 后的资产升级工具:

```cpp
797→static bool upgradeHardskinnedVertices( const BW::string& resourceID, BW::string& ret )
798→{
800→    DataSectionPtr root = BWResource::instance().rootSection()->openSection( resourceID );
808→    BW::string baseNameStr = baseName( resourceID );
809→    BW::string primitivesFileName = baseNameStr + ".primitives/";
812→    BW::vector< DataSectionPtr > renderSets;
813→    root->openSections( "renderSet", renderSets );
822→    ret = "";
823→    bool changed = false;
828→    while (rsit != rsend)
829→    {
832→        Moo::Visual::RenderSet renderSet;
835→        BW::vector< DataSectionPtr > geometries;
836→        renderSetSection->openSections( "geometry", geometries );
847→        while (geit != geend)
849→        {
853→            BW::string verticesName = geometrySection->readString( "vertices" );
854·            if (verticesName.find_first_of( '/' ) >= verticesName.size())
855·                verticesName = primitivesFileName + verticesName;
856→            Moo::VerticesManager::instance()->get( verticesName );
858→            // ... 检测顶点格式,如果是 hardskinned 则升级并写回
878→}
```

实际升级逻辑(读取顶点流、判断格式、写回)由 `Moo::VerticesManager` 完成,assetprocessor 只是迭代 visual 文件结构并触发升级。返回 `changed` 标志表示是否实际修改了文件。

注意 L854-855 的路径处理:如果 `verticesName` 不含 `/`,则拼接到 `primitivesFileName` 下——这是 BigWorld 资源路径的相对路径约定。

### 6.5 compileShader —— Shader 编译

`compileShader`(`asset_processor_script.cpp:940-984`)是 assetprocessor 的另一核心功能,编译 `.fx` 文件:

```cpp
940→static PyObject* compileShader( const BW::string& resourceID,
941→                                PyObjectPtr macroCombination, bool force )
942→{
944→    using namespace Moo;
946→    EffectMacroSetting::MacroSettingVector macroSettings;
947→    EffectMacroSetting::getMacroSettings( macroSettings );
950→    if (! PyTuple_Check(macroCombination.get()) )
951·    {
952·        PyErr_SetString( PyExc_TypeError, "compileShader arg must be a tuple of integers.");
953·        Py_RETURN_NONE;
954·    }
956→    size_t comboLen = PyTuple_Size( macroCombination.get() );
957·    if ( comboLen != macroSettings.size() )
958·    {
959·        PyErr_SetString( PyExc_TypeError, "compileShader macroCombination tuple is the wrong length. Must be len(getShaderMacros).");
960·        Py_RETURN_NONE;
961·    }
964→    for (size_t i = 0; i < comboLen; i++)
965·    {
966·        EffectMacroSetting::EffectMacroSettingPtr setting = macroSettings[i];
967·        long settingIdx = PyInt_AsLong (PyTuple_GetItem( macroCombination.get(), i ));
969→        setting->selectOption( settingIdx, true );    // 选择宏选项
970→    }
972→    EffectMacroSetting::updateManagerInfix();         // 更新 effect manager infix
977→    Moo::EffectCompiler compiler( true );
978·    int success = 0;
979·    if (force || compiler.checkModified( resourceID ))
980·    {
981·        success = compiler.compile( resourceID, &compileResult ) ? 1 : 0;
982·    }
983→    return Py_BuildValue( "(is)", success, compileResult.c_str() );
984→}
```

关键设计:

1. **宏组合作为整数 tuple 传入**:Python 调用方通过 `getShaderMacros()` 获取宏列表(每个宏有 N 个选项),然后用一个 `tuple(int, int, ...)` 指定每个宏的选项索引。这样比传字符串字典高效,且避免拼写错误。
2. **类型检查严格**:tuple 长度必须等于宏数量,否则抛 `TypeError`。
3. **force + checkModified 双重判断**:`force=true` 强制重编;否则通过 `EffectCompiler::checkModified` 检查 `.fx` 文件是否被修改过,只在必要时编译。
4. **返回值是 `(int, str)` 元组**:`success` 为 0/1,`compileResult` 是编译输出/错误信息。

典型的 Python 调用方式:

```python
import _AssetProcessor
macros = _AssetProcessor.getShaderMacros()
# macros = [("SKIN", 4), ("LIGHTING", 3), ...]
combo = (1, 2, 0, ...)  # 每个 macro 选哪个 option
success, msg = _AssetProcessor.compileShader("shaders/foo.fx", combo, False)
```

### 6.6 getShaderMacros / shaderNeedsRecompile

`getShaderMacros`(`asset_processor_script.cpp:989-1006`)返回当前所有 effect 宏及其选项数:

```cpp
989→static PyObject * getShaderMacros()
990→{
994→    EffectMacroSetting::getMacroSettings( macroSettings );
996→    PyObject* ret = PyList_New( macroSettings.size() );
998→    for (size_t i = 0; i < macroSettings.size(); i++)
999·    {
1000·        EffectMacroSetting::EffectMacroSettingPtr setting = macroSettings[i];
1001·        PyObject* tuple = Py_BuildValue( "(si)", setting->macroName().c_str(), setting->numMacroOptions() );
1002·        PyList_SetItem( ret, i, tuple );
1003·    }
1005→    return ret;
1006→}
```

`shaderNeedsRecompile`(`asset_processor_script.cpp:1010-1053`)检查指定宏组合的 shader 是否需要重编:

```cpp
1044→    Moo::EffectCompiler compiler( true );
1045→    if (compiler.checkModified( resourceID ))
1046·        Py_RETURN_TRUE;
1048·    else
1049·        Py_RETURN_FALSE;
```

两者配合 Python 端可以实现"遍历所有宏组合,只编译过期的"高效批处理:

```python
macros = _AssetProcessor.getShaderMacros()
# 笛卡尔积生成所有组合
for combo in itertools.product(*[range(m[1]) for m in macros]):
    if _AssetProcessor.shaderNeedsRecompile("foo.fx", combo):
        _AssetProcessor.compileShader("foo.fx", combo, False)
```

### 6.7 outsideChunkIdentifier / getGuid / convertBase64DataSection

辅助函数:

**`outsideChunkIdentifier`**(`asset_processor_script.cpp:920-938`):根据世界坐标查询该位置所在的 chunk 名:

```cpp
938→PY_AUTO_MODULE_FUNCTION( RETDATA, outsideChunkIdentifier,
939·                          ARG( Vector3, OPTARG( float, DEFAULT_GRID_RESOLUTION, END )),
940·                          _AssetProcessor )
```

返回字符串如 `o01o01`,BigWorld chunk 命名规则是 `c/ccrr` 形式(中心 chunk)或 `o/ccrr`(外 chunk)。

**`getGuid`**(`asset_processor_script.cpp:890-892`):生成唯一 GUID:

```cpp
892→PY_AUTO_MODULE_FUNCTION( RETDATA, getGuid, END, _AssetProcessor )
```

底层调用 `UniqueID::generate()`(`cstdmf/unique_id.hpp`),用于给资产生成稳定 ID。

**`convertBase64DataSection`**(`asset_processor_script.cpp:1096-1110`):把一个字符串 section 的内容从 base64 解码为 UTF-8:

```cpp
1096→bool convertBase64DataSection( PyObjectPtr pyObj )
1098→{
1099→    if ( PyDataSection::Check(pyObj.get()) )
1100·    {
1101·        DataSectionPtr pSection = static_cast<PyDataSection*>(pyObj.get())->pSection();
1102·        BW::wstring val = decodeWideString( pSection->asString() );
1103·        if (val != L"error")
1104·        {
1105·            pSection->setWideString(val);
1106·            return true;
1107·        }
1108·    }
1109→    return false;
1110→}
```

`decodeWideString`(`asset_processor_script.cpp:1066-1089`)支持两种格式:
- 以 `!` 开头:直接 ANSI→Unicode 转换(便于手编辑)。
- 否则:base64 解码为 wide string。

这个函数用于把旧版资产中的 base64 编码字符串(如 NPC 对话文本)升级为 UTF-8 直接存储,便于本地化工具处理。

---

## 七、Python 模块导出表

assetprocessor 通过 `PY_AUTO_MODULE_FUNCTION` 宏导出函数到 `_AssetProcessor` 模块,完整清单:

| Python 函数 | C++ 实现 | 签名 | 用途 |
|---|---|---|---|
| `init()` | `AssetProcessorScript::init` | `() -> None` | 初始化(自动调) |
| `fini()` | `AssetProcessorScript::fini` | `() -> None` | 清理(脚本应显式调) |
| `updateBSPVersion(visualName)` | `updateBSPVersion` | `(str) -> str` | BSP2 升级,返回错误字符串(""=成功) |
| `upgradeHardskinnedVertices(resourceID, ret)` | `upgradeHardskinnedVertices` | `(str, str) -> bool` | 硬皮→软皮顶点升级 |
| `getGuid()` | (anonymous) | `() -> str` | 生成 GUID |
| `outsideChunkIdentifier(pos, gridRes?)` | (anonymous) | `(Vector3, float=DEFAULT_GRID_RESOLUTION) -> str` | 坐标查 chunk |
| `compileShader(resourceID, macroCombination, force)` | `compileShader` | `(str, tuple, bool) -> (int, str)` | 编译 shader,返回 (success, msg) |
| `getShaderMacros()` | `getShaderMacros` | `() -> list[(str, int)]` | 获取所有宏及选项数 |
| `shaderNeedsRecompile(resourceID, macroCombination)` | `shaderNeedsRecompile` | `(str, tuple) -> bool` | 检查是否需重编 |
| `convertVisual(visualFile, colladaFile?)` | `convertVisual` | `(str, str="") -> bool` | 已废弃,抛 `NotImplementedError` |
| `convertBase64DataSection(pyObj)` | `convertBase64DataSection` | `(PyDataSection) -> bool` | base64 → UTF-8 |

`PY_AUTO_MODULE_FUNCTION` 宏(来自 `pyscript/script.hpp`)会自动:
1. 解析 Python 参数(根据 `ARG/OPTARG/END` 描述)。
2. 转换为 C++ 类型。
3. 调用 C++ 函数。
4. 把返回值转换为 Python 对象(根据 `RETDATA/RETOWN/RETVOID`)。

这极大简化了 Python C 扩展的样板代码——一个函数从声明到导出只需一行宏。

`convertVisual` 是一个有趣的"反例":

```cpp
1058→static bool convertVisual( const BW::string& visualFile, const BW::string& colladaFile )
1059→{
1060·    PyErr_SetString( PyExc_NotImplementedError, " Collada is no longer a supported format.");
1061·    return false;
1062→}
1064→PY_AUTO_MODULE_FUNCTION( RETDATA, convertVisual, ARG( BW::string, OPTARG( BW::string, BW::string(), END)), _AssetProcessor )
```

BigWorld 早期支持 Collada 格式导入,后来废弃,但保留函数签名以兼容旧脚本,运行时抛 `NotImplementedError`。这是 Python 友好的 API 演进策略。

---

## 八、配置项与依赖

assetprocessor 没有命令行参数(它是 DLL,不是可执行程序),其行为由以下配置决定:

| 配置 | 来源 | 作用 |
|---|---|---|
| `resources.xml` | `AutoConfig::configureAllFrom` | shader include 路径、texture 路径等 |
| `shaders/formats/*` | `BWResource::openSection` | 预创建的顶点声明列表 |
| `material_kinds.xml` | `MaterialKinds::init` | 物理材质表(BSP 碰撞用) |
| `entitiesClientPath` | `EntityDef::Constants` | 客户端 entity 定义路径(给 Script::init) |
| Python 路径 | `PyImportPaths::addResPath` | 添加 entity client 路径到 Python import paths |

assetprocessor 的运行需要以下环境:
1. Python 解释器已启动(或由 `Script::init` 启动)。
2. BigWorld 资源路径已配置(通常由宿主进程通过 `BWResource::init` 完成)。
3. D3D9 runtime 可用(用于 `Moo::rc().createDevice`)。
4. `resources.xml`、`material_kinds.xml` 等配置文件在资源路径中可访问。

---

## 九、与其他模块的依赖关系

```
┌──────────────────────────────────────────────────────────────────┐
│ assetprocessor.dll                                               │
└──┬───────────────────────────────────────────────────────────────┘
   │ 依赖(BigWorld 标准库)
   ├─ cstdmf/        : base64, unique_id, debug
   ├─ resmgr/        : BWResource, DataSection, XMLSection, AutoConfig
   ├─ pyscript/      : Script, PyDataSection, pyobject_plus
   ├─ moo/           : init, Renderer, render_context, Visual, VisualLoader,
   │                   VerticesManager, PrimitiveManager, Node, EffectCompiler,
   │                   EffectMacroSetting, ManagedEffect, VertexDeclaration,
   │                   BSPProxy, BSPMaterialIDs, TextureManager
   ├─ physics2/      : BSP, BSPTreeTool, MaterialKinds
   ├─ entitydef/     : Constants(entitiesClientPath)
   └─ chunk/         : chunk_grid_size(DEFAULT_GRID_RESOLUTION)

   │ 被依赖(谁会调用 assetprocessor)
   ├─→ Python 资产升级脚本(如 asset_processor.py)
   ├─→ batch_compiler(通过 Python 脚本间接调用,例如 effect_converter
   │                   可能 import _AssetProcessor 编译 shader)
   └─→ jit_compiler(同上,运行时 shader 重编译)
```

assetprocessor 与 asset_pipeline 是**互补关系**而非替代关系:

| 维度 | asset_pipeline | assetprocessor |
|---|---|---|
| 形态 | 静态库 | DLL(Python 扩展) |
| 调用方 | batch_compiler/jit_compiler(C++ 链接) | Python 脚本 |
| 状态 | 复杂状态机 | 无状态 |
| D3D 设备 | 不需要 | 必须 |
| 主要操作 | 依赖发现 + 文件转换 | BSP 重建、shader 编译、顶点升级 |
| 触发时机 | 每次构建 | 资产升级/迁移时 |

典型协作场景:`asset_pipeline` 的 `effect_converter` 在 `convert()` 中可能 `import _AssetProcessor` 调用 `compileShader` 完成实际的 shader 编译。这种"asset_pipeline 调度 + assetprocessor 执行"的分工让两者各司其职。

---

## 十、关键代码片段

### 10.1 顶点声明预创建

`asset_processor_script.cpp:137-150`,assetprocessor 在初始化时预创建所有顶点声明,避免后续 `compileShader`/`generateBSP2` 时 D3D InputLayout 创建卡顿:

```cpp
137→    DataSectionPtr ptr = BWResource::instance().openSection("shaders/formats");
138→    if (ptr)
139→    {
140·        DataSectionIterator it = ptr->begin();
141·        DataSectionIterator end = ptr->end();
142·        while (it != end)
143·        {
144·            BW::string format = (*it)->sectionName();
145·            size_t off = format.find_first_of( "." );
146·            format = format.substr( 0, off );              // 去扩展名
147·            Moo::VertexDeclaration::get( format );         // 触发创建并缓存
148·            it++;
149·        }
150→    }
```

`Moo::VertexDeclaration::get` 内部会查询 D3D 设备创建 InputLayout 并缓存,后续相同 format 调用直接返回缓存。预创建让首次编译 shader 时不必再创建 InputLayout。

### 10.2 baseName 路径工具

`asset_processor_script.cpp:47-54`,简单但被多处使用的工具函数:

```cpp
47→BW::string baseName( const BW::string& resourceID )
48→{
49→    BW::string baseName = resourceID.substr(
50·        0, resourceID.find_last_of( '.' ) );     // 去扩展名
51·    for (uint ni = 0; ni < baseName.size(); ni++)
52·        if (baseName[ni] == '\\') baseName[ni]='/';  // 反斜杠 → 正斜杠
53→    return baseName;
54→}
```

注意 L51-52 的反斜杠转换——BigWorld 资源路径统一用正斜杠,但 Windows 文件系统可能返回反斜杠,这里强制归一化。这种细节贯穿整个 assetprocessor。

### 10.3 getMaterialIdentifier 调用

在 `generateBSP2` 中,L543 提取每个 primitiveGroup 的材质 ID:

```cpp
543→                materialIDs.push_back( getMaterialIdentifier(primitiveGroupSection) );
545·                Moo::ComplexEffectMaterial * pMat = new Moo::ComplexEffectMaterial();
546·                primitiveGroup.material_ = pMat;
548·                // No need to load the material at this point.
549·                // all we need is the identifier
550·                //pMat->load( primitiveGroupSection->openSection( "material" ) );
551·                pMat->identifier( materialIDs[materialIDs.size()-1] );
```

注释明确:**只取 ID,不加载材质**。assetprocessor 只关心 BSP(几何),材质渲染交给运行时。这是个性能优化——避免在 BSP 升级时加载所有 shader/texture。

### 10.4 populateWorldTriangles

虽然 `populateWorldTriangles` 的实现不在 `asset_processor_script.cpp` 中(它在 `asset_processor_script.hpp` 声明),但其作用是把 geometry 的三角形变换到世界空间并加入 `RealWTriangleSet`:

```cpp
22→int populateWorldTriangles( Moo::Visual::Geometry& geometry,
23·                        RealWTriangleSet & ws,
24·                        const Matrix & m,
25·                        BW::vector<BW::string>& materialIDs );
```

返回值是退化三角形数(用于 L559 的统计)。这个函数实际定义在 assetprocessor 的其他 cpp(可能被合并到 script.cpp 编译)中,核心是遍历 `geometry.primitiveGroups_`,对每个 triangle 应用变换 `m`,加入 `ws`。

### 10.5 自定义 BSP 检测

`asset_processor_script.cpp:716-730` 的双重三角形数校验是 assetprocessor 的精华:

```cpp
716→        int nGeneratedBSPTriangles = pGeneratedBSP->pTree()->numTriangles();
717→        bool triCountEqual = ( nGeneratedBSPTriangles == nFoundBSPTriangles &&
718·            (nFoundBSPTriangles + nDegenerateTris) == nVisualTris );
720·        if ( triCountEqual || (nFoundBSPTriangles == 0) )
721·        {
723·            AssetProcessorScript::replaceBSPData( visualName, pGeneratedBSP, bspMaterialIDs );
724·            ret = "";
725·        }
726·        else
727·        {
728·            ret = visualName;
729·            ret += " has a custom BSP.  Please re-export this visual manually.";
730·        }
```

两个条件:
1. `nGeneratedBSPTriangles == nFoundBSPTriangles`:新生成的 BSP 与原 BSP 三角形数相同(没遗漏)。
2. `nFoundBSPTriangles + nDegenerateTris == nVisualTris`:原 BSP + 退化三角形 = visual 总三角形数(说明原 BSP 是从同一 visual 生成的,不是手动编辑的)。

只有两者同时满足,才认为是"非 custom BSP",可以安全覆盖。否则警告美术手动重导出——这种保守策略避免了破坏美术精心编辑的碰撞体。

---

## 十一、设计亮点与注意事项

### 11.1 设计亮点

1. **薄 C++/Python 桥接**:assetprocessor 把所有复杂性留在 C++(Moo/Physics2),Python 端只暴露极简 API,符合"把性能敏感/设备相关的代码下沉到 C++"的最佳实践。
2. **隐藏窗口 + D3D 设备**:用一个 256×256 的 `WS_OVERLAPPED` 窗口承载 D3D 设备,既满足 D3D 创建设备的 HWND 需求,又不打扰用户。
3. **PY_AUTO_MODULE_FUNCTION 宏**:声明式导出 Python 函数,自动处理类型转换与错误,大幅减少样板代码。
4. **三角形数双重校验**:`updateBSPVersion` 中通过 `nGenerated == nFound && nFound + nDegenerate == nVisual` 双重判断识别 custom BSP,保护美术手动编辑的碰撞数据。
5. **退化三角形统计**:BSP 构建会自然剔除退化三角形(零面积),assetprocessor 同时统计并返回这个数,让上层能正确判断三角形数差异是否正常。
6. **API 演进友好**:`convertVisual` 保留签名但抛 `NotImplementedError`,旧脚本不会因签名变化崩溃,而是得到清晰的错误提示。
7. **预创建顶点声明**:init 时遍历 `shaders/formats/*` 提前创建 InputLayout,避免后续编译 shader 时的 JIT 创建卡顿。
8. **路径归一化**:`baseName` 强制反斜杠→正斜杠,与 BigWorld 资源路径约定一致,避免 Windows/Linux 路径差异问题。
9. **显式 fini 推荐**:`DllMain` 注释明确建议脚本显式调 `fini()`,避免 D3D DLL 卸载顺序问题——这是个很贴心的工程提示。
10. **static 函数封装**:`updateBSPVersion` 等内部函数声明为 `static`,只通过 `PY_AUTO_MODULE_FUNCTION` 导出,不污染全局符号。

### 11.2 注意事项与潜在坑

1. **D3D 设备是必需的**:assetprocessor 无法在无 D3D 的环境(如纯服务端、headless CI)运行。批处理脚本若调用 `compileShader`,必须在装有 D3D9 的 Windows 上跑。
2. **重复 init 防护**:`g_inited` 标志位防止重复初始化,但若 `init()` 中途失败(如 `BWResource::init` 失败),`g_inited` 不会被设为 true,下次调用会重试。需注意部分初始化的状态(如已注册窗口类但未创建设备)。
3. **Moo::rc().createDevice 失败处理缺失**:L135 创建设备后没有错误检查,若 D3D 设备创建失败,后续所有操作都会崩溃。这是个潜在的健壮性问题。
4. **资源 purge 时机**:`replaceBSPData` 调用 `BWResource::instance().purgeAll()` 清缓存,但这会**清掉所有已加载资源**,如果在批量处理脚本中频繁调用,会有性能问题。建议批量处理时手动管理 purge 时机。
5. **Python 元组类型严格**:`compileShader` 要求 `macroCombination` 必须是 `tuple`,不接受 `list`。Python 调用方需注意 `*args` 解包语法。
6. **DLL 卸载顺序**:进程终止时 D3D DLL 可能先于 assetprocessor 卸载,因此 `DllMain` 中 `Reserved != 0` 时不调 `fini`。但若脚本忘记显式调 `fini()`,D3D 资源可能泄漏直到进程结束。
7. **Windows-only**:依赖 D3D9、Win32 API(`CreateWindow`、`RegisterClass`),无法移植到非 Windows。
8. **shader 编译错误返回字符串**:`compileShader` 返回 `(success, msg)` 而非抛异常,Python 调用方需主动检查 `success`,不能依赖 try/except。
9. **material ID 不加载材质**:`generateBSP2` 中只读 material ID 不加载 `ComplexEffectMaterial`,这意味着 BSP 升级不会发现材质本身的错误(如 shader 缺失),需运行时才会暴露。
10. **无并发支持**:assetprocessor 完全无锁,D3D 设备本身也是单线程对象。多线程调用 `_AssetProcessor` 函数会崩溃,Python GIL 保证了 C++ 函数不会真并发,但若 C++ 内部释放 GIL(本模块未释放)则有风险。

### 11.3 与 asset_pipeline 的协作

assetprocessor 与 asset_pipeline 没有直接的 C++ 调用关系,它们通过 **Python 脚本**间接协作:

```
batch_compiler (C++)
    │
    │ 调用 asset_pipeline 的 Converter::convert()
    ▼
effect_converter (C++ Converter)
    │
    │ 在 convert() 内部通过 Python API 调用
    ▼
Python 脚本(asset_processor.py)
    │
    │ import _AssetProcessor
    │ _AssetProcessor.compileShader(...)
    ▼
assetprocessor.dll (C++)
    │
    │ 调用 Moo::EffectCompiler
    ▼
D3D Shader Compiler
```

这种"通过 Python 桥接"的设计让 shader 编译逻辑可以由 Python 脚本灵活配置(如宏组合策略、缓存命名规则),而无需重新编译 C++。

---

## 附录:核心文件清单

| 文件 | 行数 | 职责 |
|---|---|---|
| `assetprocessor.hpp` | 23 | DLL 导出宏 + `init_AssetProcessor` 声明 |
| `assetprocessor.cpp` | 53 | `DllMain` + `init_AssetProcessor` 入口 |
| `asset_processor_script.hpp` | 39 | `AssetProcessorScript` 命名空间声明 |
| `asset_processor_script.cpp` | 1119 | 全部业务逻辑(init/fini/BSP/shader/...) |
| `pch.hpp` | - | 预编译头 |

---

## 附录:Python 调用示例

### BSP2 升级

```python
import _AssetProcessor

# 升级单个 visual
err = _AssetProcessor.updateBSPVersion("objects/hero/body.visual")
if err:
    print("ERROR:", err)
else:
    print("OK")

# 批量升级
import BWResource
for visual in BWResource.findAll("*.visual"):
    err = _AssetProcessor.updateBSPVersion(visual)
    if err:
        print(visual, ":", err)
```

### Shader 批量编译

```python
import _AssetProcessor
import itertools

macros = _AssetProcessor.getShaderMacros()
# macros = [("SKIN", 4), ("LIGHTING", 3), ("FOG", 2)]

shader = "shaders/standard.fx"
for combo in itertools.product(*[range(n) for _, n in macros]):
    if _AssetProcessor.shaderNeedsRecompile(shader, combo):
        success, msg = _AssetProcessor.compileShader(shader, combo, False)
        if not success:
            print("FAIL:", combo, msg)
        else:
            print("OK:", combo)
```

### 顶点格式升级

```python
import _AssetProcessor

ret = ""
changed = _AssetProcessor.upgradeHardskinnedVertices("objects/hero/body.visual", ret)
print("changed:", changed, "msg:", ret)
```

---

> **文档版本**:BigWorld Engine 14.4.1
> **分析对象**:`programming/bigworld/tools/assetprocessor/`
> **行号引用**:本文中所有 `文件:行号` 均基于 14.4.1 源码原始行号。
