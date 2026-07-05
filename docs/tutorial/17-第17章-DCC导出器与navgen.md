# 第17章 DCC 导出器与 navgen

> 前几章我们看完了 WorldEditor 的编辑能力与 AssetPipeline 的资源编译管线。但美术手里的"源头资产"——3ds Max 的 `.max` 文件、Maya 的 `.ma/.mb` 文件——是怎么变成引擎能识别的 `.visual`/`.primitives`/`.bsp`/`.animation` 的?编辑器摆出来的 chunk,又是怎么生成让 NPC 能"自己找路"的导航网格的?本章就把这两条"美术→引擎"的关键链路一次性讲透:DCC 导出器把 DCC 工具场景转译为引擎资产,navgen 把 chunk 几何转译为寻路数据。它们一个是"翻译官",一个是"丈量员",共同构成 BigWorld 工具链的离线侧。

---

## 目录

- [第一部分:DCC 导出器](#第一部分dcc-导出器)
  - [17.1 DCC 导出器概述](#171-dcc-导出器概述)
  - [17.2 visualexporter:3ds Max 视觉导出](#172-visualexporter3ds-max-视觉导出)
  - [17.3 animationexporter:3ds Max 动画导出](#173-animationexporter3ds-max-动画导出)
  - [17.4 mayavisualexporter:Maya 视觉导出](#174-mayavisualexportermaya-视觉导出)
  - [17.5 exporter_common:公共静态库](#175-exporter_common公共静态库)
  - [17.6 MFX 二进制文件格式](#176-mfx-二进制文件格式)
- [第二部分:navgen 导航网格生成](#第二部分navgen-导航网格生成)
  - [17.7 navgen 概述](#177-navgen-概述)
  - [17.8 三阶段生成流水线](#178-三阶段生成流水线)
  - [17.9 洪水填充算法](#179-洪水填充算法)
  - [17.10 BSP 分割与多边形生成](#1710-bsp-分割与多边形生成)
  - [17.11 核心类与 facade 模式](#1711-核心类与-facade-模式)
  - [17.12 lib/waypoint_generator 库](#1712-libwaypoint_generator-库)
  - [17.13 集群分片与增量生成](#1713-集群分片与增量生成)
  - [17.14 配置与运行模式](#1714-配置与运行模式)
- [第三部分:特色实现深度剖析](#第三部分特色实现深度剖析)
  - [17.15 Y/Z 轴交换:DCC 坐标系到引擎坐标系](#1715-yz-轴交换dcc-坐标系到引擎坐标系)
  - [17.16 skin_splitter 贪心算法](#1716-skin_splitter-贪心算法)
  - [17.17 洪水填充 + BSP 组合导航算法](#1717-洪水填充--bsp-组合导航算法)
  - [17.18 RC4 风格哈希集群分片](#1718-rc4-风格哈希集群分片)
  - [17.19 本章小结](#1719-本章小结)

---

## 第一部分:DCC 导出器

### 17.1 DCC 导出器概述

#### 17.1.1 什么是 DCC

**DCC** 是 Digital Content Creation(数字内容创作)的缩写,指 3ds Max、Maya、Blender 这类三维建模与动画软件。MMOG 美术在 DCC 工具里搭场景、绑骨骼、K 动画,但 DCC 自己的文件格式(`.max`/`.ma`)是闭源且面向编辑的——引擎运行时绝不会去解析它们。因此需要"导出器"把 DCC 场景转译成引擎认识的二进制格式。

BigWorld 14.4.1 提供**三个** DCC 导出器:

| 导出器 | DCC | 输出 | 目录 |
|---|---|---|---|
| `visualexporter` | 3ds Max | `.visual` / `.primitives` / `.bsp` / `.model` | `tools/visualexporter/` |
| `animationexporter` | 3ds Max | `.animation` | `tools/animationexporter/` |
| `mayavisualexporter` | Maya | `.visual` / `.primitives` / `.bsp` / `.model` / `.animation` | `tools/mayavisualexporter/` |

它们通过插件机制嵌入 DCC 进程:3ds Max 加载 `.dle` 文件作为 `SceneExport` 派生类,Maya 加载 `.mll` 文件作为 `MPxFileTranslator` 派生类。从美术"File → Export"那一刻起,控制权就交到导出器手里。

#### 17.1.2 共享库 exporter_common

三个导出器有大量共性需求——生成 BSP、按骨骼数拆分蒙皮、清理 DataSection 缓存。这些被抽到公共静态库 **`exporter_common`**(`tools/exporter_common/`),被三者链接复用。这个库的关键设计是**完全 DCC 无关**:不 include 任何 3ds Max 或 Maya 头文件,只依赖 `cstdmf`/`resmgr`/`moo`/`math`/`physics2`。这样它就能被任意 DCC 导出器链接而不引入 SDK 冲突。

```
┌──────────────────┐  ┌──────────────────────┐  ┌──────────────────┐
│ animationexporter│  │ mayavisualexporter  │  │ visualexporter   │
│  (3ds Max 动画)  │  │  (Maya 可视化)      │  │ (3ds Max 可视化) │
└────────┬─────────┘  └──────────┬───────────┘  └────────┬─────────┘
         │                       │                       │
         │  DataSectionCachePurger│ generateBSP           │ generateBSP
         │                       │ SkinSplitter          │ SkinSplitter
         │                       │                       │ NodeCatalogueHolder
         ▼                       ▼                       ▼
       ┌─────────────────────────────────────────────────────────┐
       │                  exporter_common (静态库)                │
       │  bsp_generator / skin_splitter / node_catalogue_holder  │
       │  data_section_cache_purger / vertex_formats             │
       └─────────────────────────────────────────────────────────┘
```

#### 17.1.3 导出管线的共同骨架

虽然三个导出器的 DCC SDK 不同,但主流程高度相似:RAII 守卫(清缓存 + 可选初始化节点目录)→ 资源名校验(VisualChecker)→ 配置三层覆盖(cfg → settings → 脚本)→ 节点分类(命名约定 + 修改器探测)→ 网格/蒙皮导出(委托 SkinSplitter 拆分)→ 写 visual → 生成 BSP(委托 exporter_common)→ 校验 + 重命名。下面三节分别看每个导出器的特色。

---

### 17.2 visualexporter:3ds Max 视觉导出

#### 17.2.1 插件入口与 SceneExport

visualexporter 编译为 `.dle` 文件,3ds Max 加载后通过 `ClassDesc` 体系实例化 `MFXExport`(继承 `SceneExport`)。`MFXExport` 重写 `DoExport` —— 这是 3ds Max 调用的导出主入口。配置文件名固定为 `"visualexporter.cfg"`,扩展名 `Ext(0)` 返回 `"visual"`。ClassID 与 animationexporter 不同,使两个插件可同时加载:

```cpp
// tools/visualexporter/mfxexp.hpp L44-48
#if defined BW_EXPORTER_DEBUG
#define MFEXP_CLASS_ID  Class_ID(0x73d06c76, 0xf143737)
#else
#define MFEXP_CLASS_ID  Class_ID(0x793130d, 0x6601416c)
#endif
```

Debug 与 Release 用不同 ClassID,便于同时安装两个版本调试。

#### 17.2.2 DoExport 流程与 RAII 双保险

`DoExport`(`mfxexp.cpp` L391)入口先构造两个 RAII 守卫,这是 visualexporter 相对其他导出器的特色——**双保险**:

```cpp
// tools/visualexporter/mfxexp.cpp L393-397
int MFXExport::DoExport(const TCHAR *nameFromMax, ExpInterface *ei,
    Interface *maxInterface, BOOL suppressPrompts, DWORD options)
{
    DataSectionCachePurger dscp;     // 析构时清 DataSection 缓存
    NodeCatalogueHolder nch;         // 析构时销毁 Moo::NodeCatalogue
    ip_ = maxInterface;
    // ... 后续 21 步流程 ...
}
```

- `DataSectionCachePurger`:3ds Max 插件常驻进程,DataSection 缓存会跨导出累积(上次导出的 `.visual` 解析结果还留在内存),既费内存又可能让下次导出读到过期数据。这个守卫在作用域结束时自动清空。
- `NodeCatalogueHolder`:**仅 visualexporter 使用**(Maya 版与 animationexporter 不需要),构造时初始化 `Moo::NodeCatalogue`(骨骼节点的全局查找表),写 `.visual` 时用它解析 renderSet 中的 node 引用。

二者在作用域结束按构造逆序析构(`nch` 先析构,`dscp` 后),保证"先销毁目录,再清缓存"的正确顺序。

#### 17.2.3 DoExport 的 21 步流程

完整的 `DoExport` 流程如下(行号对应 `mfxexp.cpp`):

```
DoExport(nameFromMax, ei, maxInterface, suppressPrompts, options)   [mfxexp.cpp:391]
│
├─[1]  RAII 守卫:DataSectionCachePurger + NodeCatalogueHolder        // L394-397
├─[2]  文件名归一化 → .visual 扩展名                                  // L414
├─[3]  AutoConfig::configureAllFrom("resources.xml")                // L417
├─[4]  清理旧状态(mfxRoot_ / nodes / meshes 容器)                  // L442-450
├─[5]  SetCommandPanelTaskMode(TASK_MODE_MODIFY)  // EditNormals 需要 // L454
├─[6]  读取 cfg + 设置 staticFrame                                   // L464-465
├─[7]  路径校验 validResource(两次:resName + camelCase)          // L468-496
├─[8]  保留名检测(exporter_*_temp.visual)                          // L498-522
├─[9]  VisualChecker 推断类型 + exportMode                          // L524-534
├─[10] 读 visualsettings + pSettingsOverride                        // L536-540
├─[11] 显示设置对话框(非 suppressPrompts)                          // L542-553
├─[12] 更新 vc.snapVertices + nodeFilter                             // L559-568
├─[13] 写回 cfg                                                     // L570
├─[14] preProcess(根节点) // 分类 _bsp/portal/Physique/Skin/HP_     // L572
├─[15] exportMeshes(snapVertices)                                   // L575-579
├─[16] exportEnvelopes(errorModels) // 按 boneCount 拆分            //
├─[17] exportPortals()                                              //
├─[18] 写 .visual(mfxRoot_->exportTree + save + 包围盒 + shell hull)// L761+
├─[19] VisualChecker 校验临时文件 → rename                           //
├─[20] 写 .model                                                    //
└─[21] generateBSP(_bsp 节点 + 主 visual)                            // L1175 / L1197
```

第 8 步的"保留名保护"是 visualexporter 的特色:`exporter_*_temp.visual` 是导出过程中 VisualChecker 用的临时文件名,如果美术不小心把模型命名为这个,会导致导出器与自己的临时文件冲突死循环。导出器主动检测并拒绝。

#### 17.2.4 preProcess 节点识别

`preProcess`(`mfxexp.cpp` L1502)递归遍历 3ds Max 节点树,用**三重识别**分类节点:

| 识别方式 | 命中条件 | 分类 |
|---|---|---|
| 命名约定 | 节点名含 `_bsp`(不区分大小写)| `meshNodes_`(BSP 专用网格)|
| 用户属性 | `node->GetUserPropBool("portal", isPortal)` 为真 | `portalNodes_` |
| 修改器探测 | 有 Physique 或 Skin 修改器且 `NORMAL` 模式 | `envelopeNodes_` |
| 命名前缀 | 节点名前缀 `hp_` | (跳过,Hit Point 不导出)|
| 其他可渲染 | 非上述 | `meshNodes_` |

```cpp
// tools/visualexporter/mfxexp.cpp L1577-1603(节选)
Modifier *pPhyMod = findPhysiqueModifier( node );
Modifier* pSkinMod = findSkinMod( node );
BW::string nodePrefix = toLower(nodeName.substr( 0, 3 ));

if (isPortal) {
    portalNodes_.push_back( node );
    includeNode = false;
}
else if( (pPhyMod || pSkinMod) && settings_.exportMode() == ExportSettings::NORMAL ) {
    envelopeNodes_.push_back( node );
    includeNode = false;
}
else if (nodePrefix != "hp_") {
    meshNodes_.push_back( node );
}
```

被分到任何一类后,节点对应的 `MFXNode` 调用 `includeAncestors()` 把包含标记沿父链向上传播,保证任何被导出节点的祖先(骨骼层级)也会被导出,这是蒙皮动画正确性的前提。

#### 17.2.5 MFXNode.exportTree

`MFXNode` 是 3ds Max `INode` 树的精简镜像,visualexporter 版**只保留 `exportTree`**(写 visual 节点层级 XML),没有 `exportAnimation`。`exportTree` 增加了一个 `hasInvalidTransforms` 输出参数,检测骨骼缩放导致的非法变换,若为真则弹窗警告美术"骨骼变换非法,可能引入动画伪影"。

`STATIC` / `MESH_PARTICLES` 模式下会先 `delChildren()` 删除根节点之外的所有子节点——静态模型不需要骨骼层级,这样能减小 `.visual` 体积、提升运行时加载速度:

```cpp
// tools/visualexporter/mfxexp.cpp L777-781
if (settings_.exportMode() == ExportSettings::STATIC
    || settings_.exportMode() == ExportSettings::MESH_PARTICLES)
{
    mfxRoot_->delChildren();
}
```

---

### 17.3 animationexporter:3ds Max 动画导出

#### 17.3.1 MFXExport 类与职责差异

animationexporter 与 visualexporter 同为 3ds Max 插件(`.dle`),主类都叫 `MFXExport`,但职责不同:

| 维度 | animationexporter | visualexporter |
|---|---|---|
| 输出 | `.animation` | `.visual` / `.primitives` / `.bsp` / `.model` |
| MFXNode | `exportTree` + `exportAnimation` | 仅 `exportTree` |
| ClassID | `0x25810e56, 0x61a93faa` | `0x793130d, 0x6601416c` |
| CFG | `animationexporter.cfg` | `visualexporter.cfg` |
| NodeCatalogueHolder | 不使用 | 使用 |
| Portal/Hull/BSP | 不支持 | 支持 |

两者 ClassID 不同,可同时加载到同一 3ds Max 安装中。`animationexporter` 的 `Ext(0)` 返回 `"animation"`,配置文件名固定为 `"animationexporter.cfg"`。

#### 17.3.2 DoExport 流程

`DoExport`(`tools/animationexporter/mfxexp.cpp` L236)只构造一个 RAII 守卫 `DataSectionCachePurger`(不需要 NodeCatalogueHolder,因为不写 visual),流程简化为 17 步:

```
DoExport(nameFromMax, ei, i, suppressPrompts, options)  [mfxexp.cpp:236]
│
├─[1]  DataSectionCachePurger dscp                                  // RAII
├─[2]  文件名归一化 → .animation 扩展名                              // L242-248
├─[3]  路径校验 BWResolver::dissolveFilename(不在 game path 报错)  // L260-286
├─[4]  设置帧范围 + 读配置(cfg → settings → MaxScript override)   // L288-298
├─[5]  显示设置对话框(非 suppressPrompts)                         // L300-311
├─[6]  nodeFilter(SCENE_EXPORT_SELECTED → SELECTED)                // L314-321
├─[7]  CueTrack::clear()  // 单例,跨导出残留清理                    // L326-327
├─[8]  preProcess(根节点) // 构建 MFXNode 树 + 节点分类             // L329
├─[9]  exportMeshes() + exportEnvelopes()  // 收集骨骼信息(不写主输出)// L331-332
├─[10] loadReferenceNodes // 若设置了 referenceNodesFile 引用层级   // L334-367
├─[11] 根子节点排序(numChildDescending)                            // L369-388
├─[12] mungeIncluded(mfxRoot_) // 祖先 include 传递                 // L390
├─[13] validateAnimationIDs(errorMsg) // 重名检测                  // L393-409
├─[14] 计算 nChannels(节点通道 + 可选 CueTrack 1 个)               // L424-429
├─[15] 读取旧文件压缩参数 CompressionInfo                          // L433-469
├─[16] BinaryFile 写入 .animation(header + mfxRoot_->exportAnimation)// L472-492
└─[17] 写 .animationsettings                                       // L499
```

第 9 步看起来奇怪:动画导出器为什么还要 `exportMeshes` + `exportEnvelopes`?其实收集的网格本身**不写入** `.animation`,这一步的目的是:识别哪些节点是骨骼(蒙皮影响对象)、收集骨骼初始变换,确保 `include` 标记正确——动画通道的 `idealParent` 计算需要骨骼层级信息。

#### 17.3.3 CompressionInfo 压缩容差

`CompressionInfo`(`tools/animationexporter/mfxnode.hpp` L19-25)描述动画压缩的误差容差:

```cpp
struct CompressionInfo
{
    bool specifyAmounts_;
    float scaleCompressionError_;
    float positionCompressionError_;
    float rotationCompressionError_;
};
```

`specifyAmounts_` 为真时,通道头写入类型 4 并附带三个误差容差(供运行时压缩使用);否则写类型 1,用默认容差。

**压缩参数继承**是 animationexporter 的特色:覆写 `.animation` 前先读回旧文件首通道的 `CompressionInfo`(`mfxexp.cpp` L437-466),使美术手动调整的压缩容差不因重新导出丢失。

#### 17.3.4 引用层级重组

动画的骨骼层级必须与对应 `.visual` 模型的节点层级一致,否则运行时蒙皮错位。但美术在 3ds Max 中搭建的层级可能与目标 visual 不完全相同。`referenceNodesFile` 选项允许指定一个 `.visual` 文件作为**引用层级**,导出时据此重组 `MFXNode` 树。

`loadReferenceNodes` 打开引用 visual 的 `node` 段,递归读取 identifier→parent 映射到 `nodeParents_`。然后 `DoExport` 遍历 `nodeParents_`,对每个 (child, parent) 对:

1. 在当前树中查找 child 与 parent 节点
2. 若二者当前父子关系与引用不一致,先检测是否存在环(child 的祖先链中是否包含 parent)
3. 有环则先断开旧父子关系
4. 将 child 从原父节点移除,挂到引用指定的 parent 下

环检测是关键——如果不检测,可能出现循环层级导致递归栈溢出。重组完成后,对 `mfxRoot_` 的直接子节点按子树规模降序排序(`numChildDescending`),使骨骼最多的子树排在前面,便于运行时遍历优化。

#### 17.3.5 Cue 事件轨道

`CueTrack`(`tools/animationexporter/cuetrack.hpp`)是进程级单例,用于在动画时间轴上标记事件(如"第 30 帧播放脚步声")。因为 3ds Max 插件常驻进程,`CueTrack` 跨导出会残留,所以 `DoExport` 必须在导出前 `CueTrack::clear()`。

`MFXNode` 构造函数在 `exportCueTrack` 开启时,从 Max 节点的 `NoteTrack` 提取关键帧注释作为 Cue:

```cpp
// tools/animationexporter/mfxnode.cpp L47-57
for( int i = 0; i < node->NumNoteTracks(); ++i )
{
    DefNoteTrack* note = (DefNoteTrack*) node->GetNoteTrack( i );
    for( int j = 0; j < note->keys.Count(); ++j )
    {
        CueTrack::addCue( note->keys[j]->time, note->keys[j]->note );
    }
}
```

`DoExport` 在节点通道写完后调用 `CueTrack::writeFile(animation)`,Cue 轨道占用 1 个通道(计入 `nChannels`)。

---

### 17.4 mayavisualexporter:Maya 视觉导出

#### 17.4.1 MPxFileTranslator 入口

mayavisualexporter 编译为 `.mll` 文件,Maya 加载后通过 `MFnPlugin::registerFileTranslator` 注册为 "BigWorldAsset" 翻译器:

```cpp
// tools/mayavisualexporter/visualmain.cpp L52-56
plugin.registerFileTranslator(
    "BigWorldAsset",                 // 翻译器名
    "",                              // 图标
    VisualFileTranslator::creator    // 工厂方法
);
```

`VisualFileTranslator` 继承 `MPxFileTranslator`,重写 `writer` —— 这是 Maya 调用的导出主入口。`defaultExtension()` 返回 `"visual"`,`haveWriteMethod()` 返回 `true`。

#### 17.4.2 writer 流程

`writer`(`tools/mayavisualexporter/visualfiletranslator.cpp` L1653)入口先构造两个 RAII 对象:

- `AutoCleanup cleaner(*this)`:writer 内嵌私有 RAII 类,析构时调用 `cleanup()` 清空本次导出的临时状态(`visualMeshes`/`hullMeshes`/`bspMeshes`/`visualPortals`/`meshNames_` 等)。
- `ScopedMELErrorVariableHandler`:隔离每次导出的 Maya 错误变量,避免跨导出污染。

完整流程:

```
writer(file, optionsString, mode)                  [visualfiletranslator.cpp:1653]
│
├─[1]  AutoCleanup + ScopedMELErrorVariableHandler                  // RAII
├─[2]  解析 optionsString 顶层(automatedTest/noPrompt)            // L1664-1688
├─[3]  计算 output/visual/visualsettings/model 文件名              // L1690-1704
├─[4]  validResource 校验                                          // L1707-1711
├─[5]  VisualChecker 推断类型 → exportMode(NORMAL/STATIC/...)    // L1713-1732
├─[6]  读配置(backup visual → visualsettings)                    // L1737-1740
├─[7]  显示 VisualExporterDialog(非 noPrompt)                     // L1742-1747
├─[8]  nodeFilter(kExportActiveAccessMode → SELECTED)             // L1749-1754
├─[9]  parseOptionsString 覆盖设置(30+ 选项)                    // L1757
├─[10] BlendShapes 初始化                                          // L1759
├─[11] OriginTransformer(若 transformToOrigin) // 原点平移         //
├─[12] 遍历 DAG,识别 _bsp/_hull/HP_/portal,分类收集                // L1759+
├─[13] 对每个 mesh 调用 exportMesh:
│       临时文件 → exportTree → save → VisualChecker
│       → rename → generateBSP → 合并 .primitives
├─[14] 导出 BSP(_bsp 节点 / 主 visual)                           // L1281-1377
├─[15] 导出 .model(nodefullVisual/nodelessVisual)                 // L2089-2119
└─[16] 导出 .animation(若 exportAnim)                             // L2122+
```

#### 17.4.3 OriginTransformer 原点变换

`OriginTransformer`(`visualfiletranslator.cpp` L122-173)是 Maya 版相对 3ds Max 版的**独有能力**——一个 RAII 对象,构造时把所有根 transform 平移到原点,析构时还原,导出过程不破坏美术场景。

构造时取所有根 transform 的 `rotatePivot` 世界坐标平均值作为 `originOffset_`,解锁所有根 transform 的锁定属性(记录到 `lockedPlugs_`),对每个根 transform 执行 `translateBy(-originOffset_, MSpace::kWorld)`:

```cpp
// tools/mayavisualexporter/visualfiletranslator.cpp L130-135
for ( uint32 i = 0; i < rootTransforms_.length(); ++i )
{
    MFnTransform rootTransform( rootTransforms_[i] );
    originOffset_ += rootTransform.rotatePivot( MSpace::kWorld ) /
        rootTransforms_.length();
}
```

析构时反向平移 `originOffset_` 并恢复属性锁定状态。这种"可逆原点变换"使模型局部原点对齐世界原点,便于运行时摆放,而美术场景不会被修改——这对 Maya 工作流特别重要,因为美术经常在远离原点的位置建模。

#### 17.4.4 30+ 选项的 parseOptionsString

Maya 的选项字符串格式为 `key1=value1;key2=value2;...`,`parseOptionsString`(`visualfiletranslator.cpp` L1501-1648)解析它并覆盖 `ExportSettings`。这是 Maya 版相对 3ds Max 版的另一个优势——**自动化批处理能力更强**,可通过脚本传入完整配置而不弹对话框。支持的 30+ 选项包括:

| 选项键 | 设置方法 | 说明 |
|---|---|---|
| `exportAnimation` | `exportAnim` | 导出动画 |
| `exportMode` | `exportMode` | 导出模式 |
| `boneCount` | `maxBones` | 最大骨骼数 |
| `transformToOrigin` | `transformToOrigin` | 原点变换 |
| `allowScale` | `allowScale` | 允许缩放 |
| `bumpMapped` | `bumpMapped` | bump mapping |
| `keepExistingMaterials` | `keepExistingMaterials` | 保留材质 |
| `snapVertices` | `snapVertices` | 顶点 snapping |
| `stripRefPrefix` | `stripRefPrefix` | 去引用前缀 |
| `useReferenceNode` | `referenceNode` | 引用节点 |
| `disableVisualChecker` | `disableVisualChecker` | 禁用校验 |
| `useLegacyScaling` | `useLegacyScaling` | 旧版缩放 |
| `fixCylindrical` | `fixCylindrical` | 圆柱 UV 修复 |
| `includeMeshes` | `setExportMeshes` | 包含网格 |
| `includeEnvelopesAndBones` | `setExportEnvelopesAndBones` | 包含蒙皮骨骼 |
| `includeNodes` | `setExportNodes` | 包含节点 |
| `includePortals` | `setIncludePortals` | 包含 portal |
| ... | ... | ... |

#### 17.4.5 临时文件 + 校验 + 重命名

mayavisualexporter 的 `exportMesh` 采用**临时文件 + 校验 + 重命名**策略,保证导出失败不破坏正式资源:

1. 生成唯一临时文件名 `exporter_NNN_temp.visual`(NNN 是自增计数器)
2. 把网格写到临时文件
3. 用 `VisualChecker` 校验临时文件合规性
4. 校验通过才 `rename` 为正式名
5. 失败则保留临时文件供排查

```cpp
// tools/mayavisualexporter/visualfiletranslator.cpp L927-929
static int exportCount = 0;
char buf[256];
bw_snprintf( buf, sizeof(buf), "exporter_%03d_temp.visual", exportCount++ );
BW::string tempFileName = BWResource::getFilePath( fileName ) + buf;
```

这是 Maya 版相对 3ds Max 版的又一个稳健性优势——3ds Max 版直接写正式文件,失败会留下半成品。配合 **backup visual 配置继承**(`lookupBackupFilename` + `readSettings(backup, false)`),实现了"重新导出保留上次配置"——美术第一次导出时设的 boneCount、exportMode 等会写入 `.visual`,下次重新导出时自动沿用,减少重复设置。

---

### 17.5 exporter_common:公共静态库

#### 17.5.1 bsp_generator:从 visual 生成 BSP

`generateBSP`(`tools/exporter_common/bsp_generator.hpp` L18-20)是 exporter_common 最复杂的组件,从 `.visual` + `.primitives` 提取三角形并构建 BSP 树:

```cpp
bool generateBSP( const BW::string & visualName,
        const BW::string & bspName,
        BW::vector< BW::string > & materialIDs );
```

主流程(`bsp_generator.cpp` L400-555):

```
generateBSP(visualName, bspName, materialIDs)              [bsp_generator.cpp:400]
│
├─[1] 计算 primitivesName(visualName → .primitives)         // L404-407
├─[2] purge visualName / primitivesName 缓存                 // L410-411
├─[3] 打开 visual 根 DataSection                             // L415-424
├─[4] 加载 rootNode(Moo::Node::loadRecursive)              // L426-437
├─[5] 遍历 renderSet 段:                                    // L442-547
│       ├─ 收集 transformNodes(node 子段 → rootNode.find)
│       ├─ 计算 firstNodeTransform(累乘父链变换)
│       └─ 遍历 geometry 段:
│            ├─ 读 verticesName → Vertices::load
│            ├─ 读 indicesName → Primitive::load
│            ├─ 遍历 primitiveGroup 段:
│            │    ├─ getMaterialIdentifier(material 段)
│            │    ├─ materialFlags = materialIDs.size() - 1
│            │    └─ primitiveGroups.push_back(...)
│            └─ populateWorldTriangles(tris, firstNodeTransform,
│                   vertices, primitive, primitiveGroups)
├─[6] BSPTreeTool::buildBSP(tris)                            // L549
├─[7] BSPTreeTool::saveBSPInFile(pTree, bspName)             // L550
└─[8] bw_safe_delete(pTree)                                  // L552
```

第 2 步的 `purge` 是关键——`generateBSP` 开头主动清掉 `visualName`/`primitivesName` 的 DataSection 缓存,强制重新读取最新文件,避免读到导出前的旧缓存。

#### 17.5.2 populateWorldTriangles 与退化剔除

`populateWorldTriangles`(`bsp_generator.cpp` L316-367)把 primitiveGroup 的三角形变换到世界空间并加入三角形集合。这里有个 `WorldTriDegenerateCuller` 适配器——它接收 `PrimitiveHelper` 生成的三角形,应用变换矩阵,剔除面积退化的三角形(零面积或共线顶点),将有效三角形以 `WorldTriangle` 形式加入集合:

```cpp
// tools/exporter_common/bsp_generator.cpp L344-354
const Moo::PrimitiveGroup& pg = primitives.primitiveGroup( iter->groupIndex_ );
WorldTriDegenerateCuller culler( ws, m, vertices, flags );
Moo::PrimitiveHelper::generateTrianglesFromIndices(
    primitives.pIndices(), pg.startIndex_, pg.nPrimitives_,
    Moo::PrimitiveHelper::TRIANGLE_LIST, culler,
    primitives.nIndices() );
bspTriangleCulled |= culler.bspTriangleCulled_;
```

剔除退化三角形是为了避免 BSP 树退化(零面积三角形会让 BSP 分割平面失效)。若有剔除发生,输出 INFO 提示美术"简化 BSP 会更好"。

#### 17.5.3 skin_splitter:按骨骼数拆分蒙皮

`SkinSplitter`(`tools/exporter_common/skin_splitter.hpp`)解决"单 draw call 骨骼数上限"问题——GPU 硬件蒙皮通常限制单次 draw call 影响骨骼数(如 32/64/80),超出需拆分网格为多个子网格。

它的核心数据结构是 `BoneRelationship`(`vector<uint32>`),即一个三角形涉及的所有骨骼索引集合。类声明(模板化适配不同导出器的顶点类型):

```cpp
// tools/exporter_common/skin_splitter.hpp L10-63(节选)
typedef BW::vector<uint32> BoneRelationship;

class SkinSplitter
{
public:
    template<typename TriangleVector, typename BloatVertexVector,
             typename BoneVertexVector>
    SkinSplitter( const TriangleVector& triangles,
        const BloatVertexVector& vertices,
        const BoneVertexVector& boneVertices );

    bool createList( uint32 nodeLimit, BW::vector<uint32>& nodeList );

    template <typename BoneVertex>
    static bool checkIndex( const BoneVertex& v,
        const BW::vector<bool>& indexUsed );

    template<typename TriangleVector, typename BloatVertexVector,
             typename BoneVertexVector>
    static void splitTriangles( TriangleVector& triangles,
        TriangleVector& splitTriangles,
        const BW::vector<uint32>& boneIndices,
        const BloatVertexVector& vertices,
        const BoneVertexVector& boneVertices, size_t numBones );
    // ...
private:
    BW::vector<BoneRelationship> relationships_;
};
```

三个模板参数(`TriangleVector` / `BloatVertexVector` / `BoneVertexVector`)适配三个导出器的不同顶点类型。骨骼权重/索引访问通过自由函数 `getWeights(v, w)` / `getIndices(v, idx)` 适配,各导出器自定义重载。

详细算法在 17.16 节深入剖析。

#### 17.5.4 RAII 辅助类

exporter_common 还提供两个 RAII 守卫:

**`NodeCatalogueHolder`**(`tools/exporter_common/node_catalogue_holder.hpp` L12-17)管理 `Moo::NodeCatalogue` 生命周期——构造时初始化(骨骼节点全局目录),析构时销毁。**仅 visualexporter 使用**(mfxexp.cpp L397),因为只有 visualexporter 写 visual 时需要 `Moo::NodeCatalogue` 解析骨骼引用。误在 animationexporter / mayavisualexporter 中使用会引入不必要的依赖。

**`DataSectionCachePurger`**(`tools/exporter_common/data_section_cache_purger.hpp` L12-17)清空 `DataSection` 缓存——三个导出器入口均使用,解决 DCC 插件常驻导致的缓存膨胀:

| 导出器 | 使用位置 |
|---|---|
| animationexporter | `mfxexp.cpp` L239 `DoExport` 入口 |
| mayavisualexporter | 经 `AutoCleanup` 间接(`visualfiletranslator.cpp` L1655)|
| visualexporter | `mfxexp.cpp` L394 `DoExport` 入口 |

---

### 17.6 MFX 二进制文件格式

#### 17.6.1 ChunkID 定义

MFX(Micro Forte eXchange)是 BigWorld 早期的二进制格式,用 FourCC 字面量标识 chunk。`chunkids.hpp`(`tools/animationexporter/chunkids.hpp` L16-47)定义了所有 chunk 标识:

```cpp
const unsigned int CHUNK_HEADER_SIZE = 12;
typedef unsigned int ChunkID;

const ChunkID CHUNKID_MFX = 'MFX!';
const ChunkID CHUNKID_MATERIALREFERENCELIST = 'MRFL';
const ChunkID CHUNKID_MATERIAL = 'MTRL';
const ChunkID CHUNKID_TEXTURE = 'TXTR';
const ChunkID CHUNKID_MESH = 'MESH';
const ChunkID CHUNKID_MESH2 = 'MES2';
const ChunkID CHUNKID_ENVELOPE = 'ENVL';
const ChunkID CHUNKID_ENVELOPE2 = 'ENV2';
const ChunkID CHUNKID_BONE = 'BONE';
const ChunkID CHUNKID_BONE2 = 'BON2';
const ChunkID CHUNKID_NODE = 'NODE';
const ChunkID CHUNKID_ANIMATION = 'ANIM';
const ChunkID CHUNKID_ANIMATIONCHANNEL = 'ANCH';
const ChunkID CHUNKID_KEYFRAMEMATRIX34 = 'KF34';
const ChunkID CHUNKID_TRIANGLELIST = 'TRIS';
const ChunkID CHUNKID_VERTEXLIST = 'VRTS';
const ChunkID CHUNKID_TEXCOORDLIST = 'TCRS';
const ChunkID CHUNKID_TRIANGLELIST2 = 'TRI2';
const ChunkID CHUNKID_BONEVERTEXLIST = 'BNVL';
const ChunkID CHUNKID_PORTAL = 'PRTL';
```

每个 chunk 头部固定 12 字节,通过 `writeMFXChunkHeader` 写入(identifier + totalSize + size)。

#### 17.6.2 固定尺寸常量

MFX 格式预定义了各种元素的固定字节数:

| 常量 | 值 | 说明 |
|---|---|---|
| `MFX_FLOAT_SIZE` | 4 | 单浮点字节 |
| `MFX_INT_SIZE` | 4 | 整数字节 |
| `MFX_POINT_SIZE` | 12 | 三维点 |
| `MFX_MATRIX_SIZE` | 48 | 4×3 矩阵 |
| `MFX_UV_SIZE` | 8 | UV 坐标 |
| `MFX_COLOUR_SIZE` | 12 | RGB 颜色 |
| `MFX_TRIANGLE_SIZE` | 12 | 三角形(3 索引)|
| `MFX_BONEVERTEX_SIZE` | 16 | 骨骼顶点(点+索引)|
| `MFX_TRIANGLE2_SIZE` | 16 | 三角形2(3 索引+材质)|

#### 17.6.3 writeMFXPoint 的 Y/Z 交换

`writeMFXPoint`(`tools/animationexporter/export.cpp` L20-25)实现 3ds Max(Z-up)到 BigWorld(Y-up)的 Y/Z 交换:

```cpp
void writeMFXPoint( Point3 &p, FILE *stream )
{
    fwrite( &p.x, 4, 1, stream );
    fwrite( &p.z, 4, 1, stream );   // Z 写到第二位
    fwrite( &p.y, 4, 1, stream );   // Y 写到第三位
}
```

`writeMFXMatrix`(L33-43)对矩阵四行同样做行 1/2 交换,保证整个变换在 Y-up 系下正确。这是 DCC 导出最关键的坐标转换,17.15 节会详细讨论。

#### 17.6.4 .animation 文件结构

新版 `.animation` 不再使用 chunk 格式,而是通过 `BinaryFile` 顺序写入:

```
┌─────────────────────────────────────────────┐
│ float        : 帧数 (lastFrame - firstFrame) │
│ string       : animName                       │
│ string       : animName (重复,标识符)        │
│ int          : nChannels (通道总数)          │
├─────────────────────────────────────────────┤
│ Channel[0..n-1] (由 exportAnimation 写入)    │
│   ├─ int channelType (1=普通, 4=带压缩容差)  │
│   ├─ string identifier                        │
│   ├─ [若 type==4] float scaleErr/posErr/rotErr│
│   ├─ sequence<ScaleKey>     (time, Vector3)   │
│   ├─ sequence<PositionKey>  (time, Vector3)   │
│   ├─ sequence<RotationKey>  (time, Quaternion)│
│   ├─ sequence<int> boundTable (scale)         │
│   ├─ sequence<int> boundTable (position)      │
│   └─ sequence<int> boundTable (rotation)      │
├─────────────────────────────────────────────┤
│ [若 exportCueTrack] CueTrack 数据            │
└─────────────────────────────────────────────┘
```

`exportAnimation`(`mfxnode.cpp` L192-287)对每个被包含节点:校验节点名 → 遍历帧采样相对变换 → `rearrangeMatrix` 完成 Y/Z 转换 → `BlendTransform` 分解为 Scale/Position/Rotation 三路关键帧 → `normaliseRotation` 归一化四元数(防止运行时插值翻转)→ 平移乘 `unitScale`(统一单位,但旋转/缩放不乘)→ 写入通道头 → 写入三路关键帧与三份 `boundTable`。

#### 17.6.5 getDistanceToBone 旧版骨骼分配

`MFExp::getDistanceToBone`(`tools/animationexporter/export.cpp` L759-850)是旧版蒙皮分配的几何算法,计算空间一点到骨骼(由三角形面集表示)的最近距离。算法:

1. 初始距离取到第一个面的第一个顶点
2. 遍历每个三角形面,先判断点是否在三角形三条边的内侧
3. 若在内侧,点投影落在三角形内部,取到平面距离
4. 否则对三条边分别计算点到线段距离(投影参数 `t = DotProd(v, v2) / DotProd(v, v)`)
5. 取所有面/边/点的最小距离作为返回值

现代版本通过 `VisualEnvelope` 直接读取 `Physique`/`Skin` 修改器的权重数据,此算法保留用于兼容与回退。

---

## 第二部分:navgen 导航网格生成

### 17.7 navgen 概述

#### 17.7.1 工具定位

`navgen` 是 BigWorld Technology SDK 中的**离线导航网格生成工具**,以 Windows 原生 Win32 应用程序形式存在(可执行文件 `navgen.exe` / `navgen_d.exe`)。它的核心职责是为游戏空间中的每一个 chunk 生成可供寻路系统使用的导航网格(navmesh / waypointSet / navPolySet)数据,并写入 chunk 的 `.cdata` 二进制文件。

源码位于 `programming/bigworld/tools/navgen/`,主文件 `navgen.cpp` 约 **5233 行**,是 BigWorld 工具链中最复杂的离线工具之一。核心职责概括为六点:

| 职责 | 描述 |
|---|---|
| 加载空间 | 加载一个游戏 Space,遍历其中所有 chunk(地形格子 + 室内 chunk)|
| 洪水填充采样 | 对每个 chunk,洪水填充采样碰撞场景,得到一张"哪些格子点可通行、邻接关系如何"的位图 |
| BSP 分割 | 用 BSP 树递归分割把可通行区域切成凸多边形(navPoly)|
| 注解 | 用 WaypointAnnotator 给边标注可见性、动作(跳跃、攀爬)等元数据 |
| 序列化 | 把生成的 waypointSet / navPolySet 二进制序列化到 chunk 的 `.cdata` 文件 |
| 维护脏标志 | 维护 navmeshDirty 标志,供 World Editor 判断是否需要重新生成 |

这些导航数据最终被客户端/服务端的寻路系统读取,用于实体 AI 寻路与碰撞规避。

#### 17.7.2 两种运行模式

navgen 支持两种运行模式,通过命令行参数 `/s` 区分:

| 模式 | 触发方式 | 用途 | UI |
|---|---|---|---|
| **交互模式** | 不带 `/s` 启动 | 美术/关卡设计师手动查看、调试单个 chunk 的导航网格 | 完整窗口 + 菜单 + 3D 渲染窗口 |
| **命令行模式** | `navgen /s <space> [/g <file>] [/overwrite]` | 自动化流水线 / CI 批量生成 | 无主循环,执行完即退出 |

双模式共用同一可执行文件,降低维护成本——交互模式可用来排查"为什么这个 chunk 的导航网格生成得不对",命令行模式则用于 CI 流水线批量生成。

#### 17.7.3 整体架构图

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
   │  for each chunk in space (ChunkSpaceTraverser):            │
   │    ┌──────────────────────────────────────────────────┐    │
   │    │ ChunkWaypointGenerator (chunk_waypoint_generator)│    │
   │    │   ├── ChunkFlooder    (洪水填充)                 │    │
   │    │   ├── WaypointGenerator (BSP 分割+多边形)        │    │
   │    │   └── entityPts_ (WPEntity+NavGenUDO 种子点)     │    │
   │    └──────────────────────────────────────────────────┘    │
   │           │                  │                  │          │
   │           ▼                  ▼                  ▼          │
   │       flood()          generate()           output()       │
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

#### 17.7.4 程序入口

navgen 是 Win32 GUI 应用,入口在 `navgen.cpp` 末尾:

```cpp
// tools/navgen/navgen.cpp L5230-5232
int WINAPI wWinMain(HINSTANCE hInstance, HINSTANCE hPrev,
                    LPWSTR commandLine, int cmdShow)
{
    return CallWithExceptionFilter( bwWinMain,
        hInstance, hPrev, commandLine, cmdShow );
}
```

`CallWithExceptionFilter` 是 `cstdmf/debug_exception_filter.hpp` 提供的包装器,把 `bwWinMain` 包裹在 `__try / __except(ExceptionFilter(...))` 中,以便崩溃时生成带堆栈信息的崩溃转储(仅在 `ENABLE_STACK_TRACKER && !_DEBUG` 时启用)。

`bwWinMain`(`navgen.cpp` L4720-5142)的执行可分为 11 个阶段:基础初始化(CStdMf)、资源系统(BWResource)、navgen_settings.xml 加载、国际化、窗口类注册与创建、OpenGL/Moo 初始化、设置项读取、后台任务线程、模式分流(`/s` 命令行 vs 交互)、主循环或一次性执行、清理。其中第 9 阶段是分叉点:

```cpp
// tools/navgen/navgen.cpp L4926-5014(节选)
bool workInCommandLine = false;
if (strstr( cmdLine.c_str(), "/s" ))
{
    workInCommandLine = true;
    BW::string space;
    getParam( &cmdLine, "/s", &space );                      // 解析空间路径
    if( !BWResource::openSection( space + "/space.settings" ) ) // 校验
        return 3;

    if (const char* p = strstr( cmdLine.c_str(), "/g" ))     // /g <chunk 列表文件>
    {
        BW::string file;
        getParam( &cmdLine, "/g", &file );
        std::ifstream ifs( file.c_str() );
        BW::string chunkName;
        while( std::getline( ifs, chunkName ) )              // 逐行读取
            g_chunkSet.insert( chunkName );                 // 加入待处理集合
    }
    setupChunking( space );                                  // 初始化 chunk 系统
}
```

---

### 17.8 三阶段生成流水线

#### 17.8.1 三阶段总览

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

#### 17.8.2 流水线数据流

`ChunkWaypointGenerator`(`tools/navgen/chunk_waypoint_generator.cpp` L139-195)是核心 facade,组合了洪水填充器与航点生成器:

```cpp
// tools/navgen/chunk_waypoint_generator.cpp L139-195(核心三阶段)
void ChunkWaypointGenerator::flood( bool (*progressCallback)( int npoints ),
    Girth gSpec, bool writeTGAs )
{
    flooder_.flood( gSpec, entityPts_, progressCallback, 0, writeTGAs );   // ① 洪水填充
}

void ChunkWaypointGenerator::generate( bool annotate, Girth gSpec )
{
    int w = flooder_.width(), h = flooder_.height();
    gener_.init( w, h, flooder_.minBounds(), flooder_.resolution() );

    // 把洪水填充结果拷贝到生成器
    for ( int g = 0; g < 16; ++g )
    {
        memcpy( gener_.adjGrids()[g], flooder_.adjGrids()[g], w*h*4 );
        memcpy( gener_.hgtGrids()[g], flooder_.hgtGrids()[g], w*h*4 );
    }

    gener_.generate();                                              // ② BSP 分割+多边形

    PhysicsHandler phand( pChunk_->space(), gSpec );
    gener_.determineEdgesAdjacentToOtherChunks( pChunk_, &phand ); // 跨 chunk 边
    gener_.streamline();                                            // 多边形精简

    if( annotate )                                                 // 边注解
    {
        WaypointAnnotator wanno( &gener_, pChunk_->space() );
        wanno.annotate();
    }

    gener_.extendThroughUnboundPortals( pChunk_ );                 // portal 扩展
    gener_.calculateSetMembership( entityPts_, pChunk_->identifier() );  // 集合归属
}

void ChunkWaypointGenerator::output( float girth, bool firstGirth )
{
    gener_.saveOut( pChunk_, girth, /*removeAllOld:*/firstGirth );  // ③ 写入 .cdata
}
```

#### 17.8.3 算法阶段详解

| 阶段 | 函数 | 输入 | 输出 | 关键算法 |
|---|---|---|---|---|
| 洪水填充 | `ChunkFlooder::flood` | chunk + Girth + 种子点 | `adjGrids_[16]` + `hgtGrids_[16]` | 从种子点 BFS 扩散,碰撞测试决定可通行性 |
| BSP 分割 | `WaypointGenerator::generate` | 邻接图 + 高度图 | `bsp_` (BSPNode 树) | 递归二分,选最优分割线 |
| 多边形生成 | `generatePoints`/`generatePolygons` | BSP 叶子 | `polygons_` | 从叶子边界提取顶点与多边形 |
| 邻接计算 | `generateAdjacencies`/`joinPolygons` | 多边形 | 邻接关系 | 共享顶点/边的多边形互连 |
| 跨 chunk 边 | `determineEdgesAdjacentToOtherChunks` | 多边形 + PhysicsHandler | `adjToAnotherChunk` 标志 | 物理测试判断边是否通向邻 chunk |
| 精简 | `streamline` | 多边形 | 合并后的多边形 | 合并可合并的相邻多边形 |
| 注解 | `WaypointAnnotator::annotate` | 多边形 + 边 | 边注解 | 视线测试、动作判定 |
| portal 扩展 | `extendThroughUnboundPortals` | 多边形 + chunk | 扩展多边形 | 穿过未绑定 portal 延伸 |
| 集合归属 | `calculateSetMembership` | 多边形 + 种子点 | `set` 字段 | 种子点落在哪个多边形 |
| 输出 | `saveOut` | 多边形 | `.cdata` 二进制 | 序列化 |

---

### 17.9 洪水填充算法

#### 17.9.1 什么是洪水填充

**洪水填充**(Flood Fill)是计算机图形学的经典算法——从种子点开始,向相邻位置扩散,直到填满整个连通区域(像水从一点溢出蔓延整个平面)。在 navgen 中,洪水填充用来"探测可通行区域":从已知的可达点(如实体位置)出发,向 8 个方向扩散,碰撞测试决定邻居是否可通行,最终得到一张"哪些格子点可站立、相邻点之间能否走过去"的位图。

#### 17.9.2 ChunkFlooder facade

`ChunkFlooder`(`tools/common/chunk_flooder.hpp` L20-54)是 chunk 级洪水填充的门面(facade),内部持有 `WaypointFlood`:

```cpp
// tools/common/chunk_flooder.hpp L20-54
class ChunkFlooder
{
public:
    ChunkFlooder( Chunk * pChunk, const BW::string& floodResultPath );
    bool flood( Girth gSpec, const BW::vector<Vector3>& entityPts,
                bool (*progressCallback)( int npoints ) = NULL,
                int nshrink = 0, bool writeTGAs = true );
    // minBounds/maxBounds/resolution/width/height/adjGrids/hgtGrids ...
private:
    Chunk *          pChunk_;
    WaypointFlood *  pWF_;
    BW::string       floodResultPath_;
};
```

`floodResultPath` 允许把洪水填充中间结果(邻接位图)缓存到磁盘,便于重注解(`reannotation`)时跳过耗时的物理采样——这是 navgen 的一个性能优化。

#### 17.9.3 AdjGridElt 紧凑位图

`AdjGridElt`(`lib/waypoint_generator/waypoint_flood.hpp` L15-37)是洪水填充的核心存储单元——用 **4 位 × 8 方向**的紧凑位图记录每个网格点在每个高度的 8 邻接方向是否可通行:

```cpp
// lib/waypoint_generator/waypoint_flood.hpp L15-37
union AdjGridElt
{
    // 取方向 a (0..7) 的邻接信息
    uint32 angle( uint a )
        { return (all >> (a<<2)) & 15; }
    // 设置方向 a 的邻接信息
    void angle( uint a, uint32 adj )
        { all = (all & ~(15 << (a<<2))) | adj << (a<<2); }

    uint32 all;
    struct
    {
        uint32  u:4;    // 0  上
        uint32  ur:4;   // 1  右上
        uint32  r:4;    // 2  右
        uint32  dr:4;   // 3  右下
        uint32  d:4;    // 4  下
        uint32  dl:4;   // 5  左下
        uint32  l:4;    // 6  左
        uint32  ul:4;   // 7  左上
    } each;
};
```

每个 `AdjGridElt` 占 4 字节(32 位),8 个方向各 4 位(可编码 0-15 的邻接状态)。`WaypointFlood` 为每个网格点存储 `MAX_HEIGHTS = 16` 层高度的 `AdjGridElt` 与对应高度值:

```cpp
// lib/waypoint_generator/waypoint_flood.hpp L117-129
static const uint MAX_HEIGHTS = 16;
...
float*        hgtGrids_[MAX_HEIGHTS];   // 每层高度图(每点实际 Y 高度)
AdjGridElt *  adjGrids_[MAX_HEIGHTS];   // 每层邻接图(8 方向可通行性)
```

`MAX_HEIGHTS=16` 意味着一个网格点上最多记录 16 个不同的可站立高度——用于桥、多层平台、楼板等场景(同一 XZ 位置上方可能有多个可站立平面)。

#### 17.9.4 WaypointFlood 洪水填充引擎

`WaypointFlood`(`lib/waypoint_generator/waypoint_flood.hpp` L83-141)是底层洪水填充引擎。洪水填充的核心思路:

1. **设置区域**(`setArea`):根据 chunk 包围盒与采样分辨率(通常 0.1m 或 0.2m)建立网格
2. **设置物理接口**(`setPhysics`):`PhysicsHandler` 实现 `IPhysics`,提供 `findDropPoint`(下落测试)、`isUnblocked`(通行测试)、`adjustMove`(移动调整)
3. **从种子点扩散**(`fill` / `flashFlood`):BFS 式扩散,对每个网格点的 8 方向邻居做碰撞测试,记录到 `AdjGridElt` 的对应 4 位字段
4. **多层高度**:一个网格点可能有多个可站立高度(如桥上桥下),最多 16 层
5. **后处理**(`postfilteradd`/`postfilterremove`/`shrink`):滤除孤岛、收缩边缘(按 girth 半径)

#### 17.9.5 IPhysics 物理查询契约

`IPhysics` 接口(`waypoint_flood.hpp` L41-77)定义了物理查询契约:

```cpp
struct IPhysics
{
    virtual Vector3 getGirth() const = 0;                          // 实体尺寸
    virtual float   getScrambleHeight() const = 0;                 // 攀爬高度
    virtual bool    findDropPoint(const Vector3& pos, float& y) = 0; // 下落测试
    virtual bool    isUnblocked(const Vector3& src, const float anotherY) { ... }
    virtual void    adjustMove(const Vector3& src, const Vector3& dst,
        Vector3& dst2) = 0;
};
```

`isUnblocked` 的默认实现利用 `findDropPoint` 判断两点之间是否可无障碍通行(高度差在 `DROP_FUDGE = 0.1f` 内视为同高)。`DROP_FUDGE = 0.1f` 是个容差——10 厘米以内的高度差视为同一平面,避免数值精度问题导致本来可通行的相邻格子被判为不通。

#### 17.9.6 邻接方向编码

`g_dx` / `g_dz`(`navgen.cpp` L361-362)定义了 8 方向的偏移,与 `AdjGridElt.each` 的字段顺序一致:

```cpp
// tools/navgen/navgen.cpp L361-362
int g_dx[8] = {0, 1, 1, 1, 0, -1, -1, -1};
int g_dz[8] = {1, 1, 0, -1, -1, -1, 0, 1};
```

| 索引 | 字段 | dx | dz | 方向 |
|---|---|---|---|---|
| 0 | u | 0 | 1 | +Z(上)|
| 1 | ur | 1 | 1 | +X+Z(右上)|
| 2 | r | 1 | 0 | +X(右)|
| 3 | dr | 1 | -1 | +X-Z(右下)|
| 4 | d | 0 | -1 | -Z(下)|
| 5 | dl | -1 | -1 | -X-Z(左下)|
| 6 | l | -1 | 0 | -X(左)|
| 7 | ul | -1 | 1 | -X+Z(左上)|

---

### 17.10 BSP 分割与多边形生成

#### 17.10.1 什么是 BSP

**BSP**(Binary Space Partitioning,二叉空间分割)是把空间递归二分的树结构——每次用一个平面把当前区域切成两半,递归下去直到每个叶子满足某个条件(如面积够小、足够凸)。BSP 在游戏开发中用途广泛:碰撞检测、可见性剔除、PVS 计算。在 navgen 中,BSP 用来把洪水填充得到的"可通行位图"切成**凸多边形**(navPoly),因为寻路系统要求 navPoly 必须是凸的(凸多边形内任意两点可直线移动而不出界)。

#### 17.10.2 generate 总流程

`WaypointGenerator::generate` 是 BSP 阶段的入口,内部调用链:

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

#### 17.10.3 BSPNode 结构

`BSPNode`(`lib/waypoint_generator/waypoint_generator.hpp` L84-108)是 BSP 树节点,记录一个矩形区域的分割信息:

```cpp
struct BSPNode
{
    float   borderOffset[8];     // 8 方向的边界偏移
    float   splitOffset;         // 分割线偏移
    int     splitNormal;         // 分割法向(0=X 轴, 1=Z 轴)
    int     parent;              // 父节点索引
    int     front;               // 前子节点索引
    int     back;                // 后子节点索引
    bool    waypoint;            // 是否为叶子(可生成航点多边形)
    int     waypointIndex;       // 对应多边形索引
    Vector2 centre;              // 节点中心
    float   minHeight;           // 最小高度
    float   maxHeight;           // 最大高度
    // ...
};
```

BSP 分割把可通行区域递归切成凸的叶子节点,每个叶子节点最终成为一个 `PolygonDef`(多边形)。

#### 17.10.4 SplitDef 分割定义

`SplitDef`(`waypoint_generator.hpp` L110-120)描述一次分割:

```cpp
struct SplitDef
{
    static const int VERTICAL_SPLIT = 8;
    int     normal;       // 分割法向(0/1 为垂直于 X/Z 轴,8 为水平高度分割)
    float   value;        // 分割线位置
    union
    {
        float position[2]; // 垂直分割时的边界
        float heights[2];  // 水平分割时的高低分界
    };
};
```

`calcSplitValue` 与 `doBestHorizontalSplit` 是分割质量的关键。分割目标是把一个节点切成两个"尽量均匀且凸"的子节点。**水平分割**(`doBestHorizontalSplit`,`SplitDef::VERTICAL_SPLIT`)用于处理一个节点内有高度差的情况(如台阶),把高区与低区分开,避免一个多边形跨越大高度差。

#### 17.10.5 顶点与多边形生成

`generatePoints` 从 BSP 叶子节点的边界提取候选顶点,去重后存入 `points_`(`BW::set<PointDef>`)。`generatePolygons` 把每个 BSP 叶子的顶点按顺序连成凸多边形(`PolygonDef`)。`generateAdjacencies` 通过共享顶点/边建立多边形间的邻接关系,`joinPolygons` 进一步合并可合并的相邻多边形以减少多边形数量。

```cpp
// lib/waypoint_generator/waypoint_generator.hpp L135-166
struct VertexDef
{
    VertexDef() : pos( Vector2::ZERO ), adjNavPoly( 0 ),
        adjToAnotherChunk(), angles( 0 ) {}
    Vector2  pos;                  // 顶点位置
    int      adjNavPoly;           // 邻接的 navPoly 索引
    bool     adjToAnotherChunk;    // 是否邻接另一个 chunk
    int      angles;               // 角度信息(凸/凹判断)
};

struct PolygonDef
{
    BW::vector<VertexDef>  vertices;
    float                  minHeight;
    float                  maxHeight;
    int                    set;            // 所属集合(种子点归属)
    bool ptNearEnough( const Vector3 & pt ) const;
};
```

#### 17.10.6 streamline 多边形精简

`gener_.streamline()` 合并相邻且合并后仍为凸的多边形,减少 navPoly 数量,降低寻路图规模。寻路系统要求 navPoly 必须是凸多边形,所以合并时必须用 `isConvexJoint` 验证三个顶点形成的关节是否为凸——只有凸合并才被允许。这是 BSP + 合并算法的根本约束。

#### 17.10.7 WaypointAnnotator 边注解

当 `g_annotate` 为真时,`WaypointAnnotator`(`tools/common/waypoint_annotator.hpp`)给边标注:

- **可见性**:从该边能否看到目标(用于 AI 决策)
- **动作**:跳跃、攀爬、下落等特殊动作标签

```cpp
// tools/navgen/chunk_waypoint_generator.cpp L182-187
if( annotate )
{
    WaypointAnnotator wanno( &gener_, pChunk_->space() );
    wanno.annotate();
}
```

---

### 17.11 核心类与 facade 模式

#### 17.11.1 ChunkWaypointGenerator:核心 facade

`ChunkWaypointGenerator`(`tools/navgen/chunk_waypoint_generator.hpp` L17-43)是单 chunk 生成流程的统一入口,组合了洪水填充器与航点生成器:

```cpp
// tools/navgen/chunk_waypoint_generator.hpp L17-43
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
    ChunkFlooder        flooder_;        // 洪水填充器
    WaypointGenerator   gener_;          // 航点生成器
    BW::vector<Vector3> entityPts_;     // 种子点(来自 WPEntity + NavGenUDO)
    bool                modified_;
};
```

这是**三层 facade 架构**的中间层:

```
ChunkWaypointGenerator (facade)
    ├── ChunkFlooder      (chunk 级洪水填充 facade)
    │       └── WaypointFlood (底层洪水填充算法)
    └── WaypointGenerator (BSP 分割 + 多边形生成)
            ├── bsp_ (BSPNode 树)
            ├── polygons_ (PolygonDef 列表)
            ├── points_ (唯一点集)
            └── edges_ (唯一边集)
```

每层职责清晰、可独立测试,这是 navgen 设计的一大亮点。

#### 17.11.2 NavGenUDO:航点种子 UDO

`NavGenUDO`(`tools/navgen/navgen_udo.hpp` L22-46)是 `ChunkItem` 的子类,代表场景中放置的 "WayPointSeed" 类型 UserDataObject:

```cpp
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
    static  GirthSeeds s_girthSeeds;     // 全局种子表(按 UDO 指针索引)
private:
    DataSectionPtr pProps_;
    Matrix         transform_;
};
```

`GirthSeed.girth` 指定该种子点要求生成哪种 girth 的导航网格,`generateRange` 指定影响范围(世界坐标)。`toss`(`navgen_udo.cpp` L60-94)在 chunk 绑定/解绑时维护全局种子表 `s_girthSeeds`:

```cpp
// tools/navgen/navgen_udo.cpp L60-94(节选)
void NavGenUDO::toss( Chunk * pChunk )
{
    // ...
    if (pChunk_ != NULL)
    {
        NavGenUDOCache::instance( *pChunk_ ).add( this );
        GirthSeed girthSeed;
        girthSeed.position = pChunk->transform().applyPoint( this->position() );
        girthSeed.girth = pProps_->readFloat( "girth", -1.f );
        girthSeed.generateRange = pProps_->readFloat( "generateRange", 0.f );
        if (girthSeed.girth > 0.f )
            s_girthSeeds[this] = girthSeed;        // 注册种子
    }
}
```

种子点是洪水填充的起点(`flashFlood` 从种子点扩散),确保生成结果覆盖实体所在位置。`compileGirthsList` 用它决定某个 chunk 需要生成哪些额外 girth。

#### 17.11.3 WPEntity:实体障碍

`WPEntity`(`tools/navgen/wpentity.hpp` L14-39)代表场景中的 entity,它把 entity 的模型作为障碍注入碰撞场景——这样洪水填充阶段的碰撞测试就能感知到 entity 障碍:

```cpp
// tools/navgen/wpentity.hpp L14-39
class WPEntity : public ChunkItem
{
    DECLARE_CHUNK_ITEM( WPEntity )
public:
    bool load( DataSectionPtr pSection );
    virtual void toss( Chunk * pChunk );
    // ...
private:
    BW::string  typeName_;
    DataSectionPtr pProps_;
    Matrix      transform_;
    class SuperModel * pSuperModel_;     // 延迟加载的障碍模型
};
```

`finishLoad`(`wpentity.cpp` L66-128)通过 Python 调用 entity 类的 `getObstacleModel` 方法获取障碍模型名,然后构造 `SuperModel`。`toss` 在 chunk 绑定时把模型作为 `ChunkModelObstacle` 注入。

种子点收集(`getEntityPts`,`chunk_waypoint_generator.cpp` L39-71)遍历 `NavGenUDOCache` 与 `WPEntityCache` 收集种子点,注意 +1 米抬高——避免种子点恰好埋在地表下方导致洪水填充无法扩散。

---

### 17.12 lib/waypoint_generator 库

#### 17.12.1 库结构

核心算法位于 `programming/bigworld/lib/waypoint_generator/`:

```
lib/waypoint_generator/
├── waypoint_generator.hpp / .cpp   # WaypointGenerator (BSP+多边形)
├── waypoint_flood.hpp / .cpp       # WaypointFlood (洪水填充)
├── waypoint_view.hpp / .cpp        # IWaypointView 查询接口
└── chunk_view.hpp / .cpp           # ChunkView (chunk 级视图)
```

#### 17.12.2 WaypointGenerator 主结构

`WaypointGenerator`(`waypoint_generator.hpp` L25)继承 `IWaypointView`,持有 BSP 树与多边形集合:

```cpp
// lib/waypoint_generator/waypoint_generator.hpp L184-197
AdjGridElt *            adjGrids_[WaypointFlood::MAX_HEIGHTS];
float *                 hgtGrids_[WaypointFlood::MAX_HEIGHTS];
unsigned int            gridX_, gridZ_;
Vector3                 gridMin_;
float                   gridResolution_;
IProgress*              pProgress_;

BW::vector<BSPNode>     bsp_;           // BSP 树
BW::vector<PolygonDef>  polygons_;      // 生成的多边形
BW::set<PointDef>       points_;        // 唯一顶点集
BW::set<EdgeDef>        edges_;         // 唯一边集
int                     sets_;          // 集合数
BW::string              identifier_;
```

注意 `adjGrids_` 与 `hgtGrids_` 是从 `WaypointFlood` memcpy 过来的——`generate()` 开头会把洪水填充结果整体拷贝到生成器(`chunk_waypoint_generator.cpp` L148-152)。

#### 17.12.3 数据结构关系图

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

#### 17.12.4 Girth 规格定义

`Girth`(`tools/common/girth.hpp` L13-35)描述一种寻路实体的物理规格,是导航网格生成的关键参数:

```cpp
class Girth
{
public:
    Girth( DataSectionPtr ds );
    float girth()    const { return girth_; }       // 标识值(如 0.5)
    float width()    const { return width_; }       // 实体宽度
    float height()   const { return height_; }      // 实体高度(决定能通过的洞穴)
    float depth()    const { return depth_; }       // 实体深度
    float radius()   const { return std::min<float>( width_, depth_ ) * 0.5f; }
    float maxSlope() const { return maxSlope_; }    // 最大可通行坡度
    float maxClimb() const { return maxClimb_; }    // 最大可攀爬高度
    bool  always()   const { return always_; }      // 是否所有 chunk 都生成
private:
    float girth_, width_, height_, depth_, maxSlope_, maxClimb_;
    bool  always_;
};
```

`girth` 字段是规格的唯一键(浮点数,通常是 `0.5`、`2.0` 等),`width/height/depth` 决定洪水填充时碰撞体的尺寸,`maxSlope/maxClimb` 决定可通行性判定,`always` 决定是否对空间内所有 chunk 都生成此 girth 的导航网格。

`girth=0.5` 是**硬性要求**——因为它是客户端默认寻路实体(半径 0.5m)的规格。若 `girths.xml` 缺少 0.5 规格,启动直接 `CRITICAL_MSG` 退出:

```cpp
// tools/navgen/navgen.cpp L3735-3738
if (g_girthSpecs.find( 0.5f ) == g_girthSpecs.end())
    CRITICAL_MSG( "Girth = 0.5 specification not found.\n" );
```

---

### 17.13 集群分片与增量生成

#### 17.13.1 doGenerateAll 全空间批量生成

`doGenerateAll`(`navgen.cpp` L2257-2530)是命令行模式与"Generate All"菜单的核心,遍历空间所有 chunk 生成导航网格。核心循环:

```cpp
// tools/navgen/navgen.cpp L2257-2530(结构化节选)
void doGenerateAll( bool overwrite = false )
{
    if (!checkAllowGenerate()) return;
    if (overwrite) doClearAll();                       // /overwrite:先清除所有
    unloadAllChunks();                                 // 卸载绘图用的 chunk

    GenerateAllEnvironmentSetter generateAllEnvironmentSetter;  // RAII

    for (ChunkSpaceTraverser cst; !cst.done(); cst.next())
    {
        processHarmlessMessages();                     // 保持 UI 响应
        g_currentChunk = cst.chunk();

        // ① 集群分片过滤
        if( hash( g_currentChunk->identifier().c_str() ) % g_totalComputers != g_myIndex )
            continue;                                  // 不属于本机,跳过

        // ② 锁检查(室外 chunk 加载前检查)
        if (g_currentChunk->isOutsideChunk() && !isChunkLocked( g_currentChunk ))
            continue;

        // ③ 增量检查:已有 worldNavmesh 则跳过
        if (g_currentChunk->isOutsideChunk())
        {
            bool modified = true;
            DataSectionPtr chunkBinSection = BWResource::openSection(
                g_currentChunk->binFileName() );
            if (chunkBinSection)
                modified = !chunkBinSection->openSection( "auxData/worldNavmesh" );
            if (!modified) continue;
        }

        // ④ 加载 chunk 及邻居
        bool loaded = waitChunkLoaded( g_currentChunk, true );
        if( !loaded ) { errors = true; continue; }

        ChunkWaypointGenerator cwg( g_currentChunk, g_floodResultPath );
        if (!cwg.modified()) continue;                 // 未修改,跳过

        // ⑤ 对每个 girth 生成
        BW::vector<float> girthsToCalculate = compileGirthsList( g_currentChunk );
        for ( uint gi = 0; gi < girthsToCalculate.size(); ++gi )
        {
            Girth gSpec = g_girthSpecs.find( girthsToCalculate[gi] )->second;
            cwg.flood( floodProgressCallback, gSpec, g_writeTGAs );
            cwg.generate(g_annotate, gSpec);
            cwg.output( girthsToCalculate[gi], gi == 0 );
        }
        cwg.outputDirtyFlag( false );

        updateMoo( 0.1f, false );                      // 推进 Moo(资源回收)
        DataSectionCache::instance()->clear();
        DataSectionCensus::clear();
    }
}
```

#### 17.13.2 GenerateAllEnvironmentSetter RAII

`GenerateAllEnvironmentSetter`(`navgen.cpp` L2277-2297)是 RAII,在批量生成期间临时调整环境以最小化加载:

```cpp
// tools/navgen/navgen.cpp L2277-2297
class GenerateAllEnvironmentSetter
{
public:
    GenerateAllEnvironmentSetter()
    {
        ChunkManager::instance().autoSetPathConstraints( 0 );        // 加载距离设为 0
        ChunkManager::instance().switchToSyncTerrainLoad( true );    // 同步地形加载
    }
    ~GenerateAllEnvironmentSetter()
    {
        ChunkManager::instance().autoSetPathConstraints( g_chunkLoadDistance );  // 恢复
        ChunkManager::instance().switchToSyncTerrainLoad( false );
    }
}
generateAllEnvironmentSetter;
```

把加载距离设为 0 是因为 `waitChunkLoaded` 仍会显式加载需要的 chunk 与邻居,而背景的自动加载反而会拖慢生成。

#### 17.13.3 增量生成与 navmeshDirty 脏标志

navgen 与 World Editor 通过 `.cdata` 中的 `navmeshDirty` 二进制 bool 标志协作:

| Section | 写入方 | 读取方 | 含义 |
|---|---|---|---|
| `navmeshDirty` | 编辑器(改地形后写 true)/ navgen(生成后写 false)| navgen / 编辑器 | 是否需重新生成 |
| `auxData/worldNavmesh` | navgen | navgen | 增量生成检查 |
| `navPolySet` | navgen | 客户端/服务端寻路 | 多边形数据 |
| `waypointSet` | navgen(旧)| 旧版寻路 | 旧格式航点 |

`outputDirtyFlag`(`chunk_waypoint_generator.cpp` L201-236)把脏标志写回 `.cdata`,生成完毕后调用 `cwg.outputDirtyFlag(false)` 清除脏标志。

#### 17.13.4 bwlockd 集成

`isChunkLocked`(`navgen.cpp` L1561-1599)通过 `bwlockd` 服务检查当前用户是否锁定了该 chunk 对应的网格——这协调多人编辑,避免覆盖他人修改:

```cpp
// tools/navgen/navgen.cpp L1561-1599(节选)
bool isChunkLocked( Chunk * chunk )
{
    if( !g_chunkSet.empty() )                          // /g 模式:只处理列表中的 chunk
    {
        if( g_chunkSet.find( chunk->identifier() ) == g_chunkSet.end() )
            return false;
    }
    if (!g_conn.enabled()) return true;                // 未启用锁服务,视为已锁
    if (!g_conn.connected()) return false;
    Vector3 centre = chunk->boundingBox().centre();
    // ... 计算 gridX/gridY 并查询 g_conn.isLockedByMe
    return g_conn.isLockedByMe( gridX, gridY );
}
```

#### 17.13.5 compileGirthsList

`compileGirthsList`(`navgen.cpp` L1601-1655)决定 chunk 需要生成哪些 girth:每个 chunk 至少生成 `always=true` 的 girth(通常是 0.5),如果 chunk 落在某个 `WayPointSeed` UDO 的影响范围内,则额外生成该 UDO 指定 girth 的导航网格。即种子点驱动——`WayPointSeed` UDO + `WPEntity` 让美术精确控制哪些区域需要特殊 girth(如大型 NPC 需要更宽通道),而非一刀切。

---

### 17.14 配置与运行模式

#### 17.14.1 命令行参数与 navgen_settings.xml

| 命令行参数 | 说明 |
|---|---|
| `/s <space>` | 命令行模式,指定空间路径 |
| `/g <file>` | chunk 列表文件(每行一个 chunk 名)|
| `/overwrite` | 覆盖生成(先清除)|
| `--settings <file>` | 自定义 navgen_settings.xml 路径 |
| `-res <path>` | BWResource 资源路径(标准 BW 参数)|

| navgen_settings.xml 配置键 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `annotate` | bool | false | 是否进行边注解 |
| `processor` | int | 1 | 处理器(保留未实际使用)|
| `writeTGAs` | bool | true | 是否输出洪水填充 TGA 调试图 |
| `reannotation` | bool | false | 是否启用重注解菜单 |
| `loadDistance` | float | 500.0 | chunk 加载距离 |
| `bwlockd/host` | string | - | bwlockd 服务地址 |
| `bwlockd/username` | string | - | bwlockd 用户名 |
| `floodResultPath` | string | - | 洪水填充结果缓存路径 |

#### 17.14.2 canProcess 邻居就绪检查

`canProcess`(`chunk_waypoint_generator.cpp` L276-353)是 navgen 确保洪水填充碰撞场景完整的关键——它检查当前 chunk 的 3×3 邻域及所有 overlapper(跨 chunk 边界的模型)是否都已绑定,否则触发加载并返回 `false` 让调用者重试:

```cpp
// tools/navgen/chunk_waypoint_generator.cpp L276-353(节选)
/*static*/ bool ChunkWaypointGenerator::canProcess(Chunk *chunk)
{
    ScopedSyncMode scopedSyncMode;
    updateMoo( 0.05f, false );

    if (!chunk->isOutsideChunk())
    {
        // 室内 chunk:递归检查其所属室外 chunk 是否绑定
        BW::string outsideChunkName = chunk->mapping()->outsideChunkIdentifier( ... );
        if (outsideChunkName.empty()) return chunk->isBound();
        Chunk* outside = ChunkManager::instance().findChunkByName( outsideChunkName, chunk->mapping() );
        return canProcess( outside );     // 递归检查室外 chunk
    }

    // 室外 chunk:检查 3x3 邻域及其 overlapper
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
                        ChunkManager::instance().loadChunkExplicitly( chunkName, chunk->mapping() );
                    return false;          // 邻居未就绪
                }
            }
        }
    }
    return true;
}
```

为什么要检查 3×3 邻域?因为洪水填充的碰撞测试需要查询 chunk 边界外的几何(实体可能跨 chunk 边界),如果邻居没加载,边界处的可通行性判断就会出错。

---

## 第三部分:特色实现深度剖析

### 17.15 Y/Z 轴交换:DCC 坐标系到引擎坐标系

#### 17.15.1 为什么要交换坐标轴

3ds Max 使用 **Z-up 右手系**——Z 轴朝上,X 轴朝右,Y 轴朝里(屏幕方向)。而 BigWorld 引擎运行时使用 **Y-up 右手系**——Y 轴朝上,X 轴朝右,Z 轴朝前(屏幕外)。

```
3ds Max 坐标系           BigWorld 坐标系
      Z                            Y
      │                            │
      │                            │
      └──── X                    └──── X
     /                           /
    Y                           Z
```

如果不做坐标转换,3ds Max 里"向上"的模型在 BigWorld 里会"向前倒下"。因此导出时必须把 Z-up 转为 Y-up——具体做法是**交换 Y 和 Z 分量**。

#### 17.15.2 writeMFXPoint 顶点交换

`writeMFXPoint`(`tools/animationexporter/export.cpp` L20-25)对顶点做 Y/Z 交换:

```cpp
void writeMFXPoint( Point3 &p, FILE *stream )
{
    fwrite( &p.x, 4, 1, stream );     // X 不变
    fwrite( &p.z, 4, 1, stream );     // Z 写到第二位(原 Y 位置)
    fwrite( &p.y, 4, 1, stream );     // Y 写到第三位(原 Z 位置)
}
```

这样写到文件的就是 (X, Z, Y),读取方按 (X, Y, Z) 解释,正好完成 Z-up → Y-up 的转换。`writeMFXMatrix`(L33-43)对矩阵四行做同样的行 1/2 交换,保证整个变换在 Y-up 系下正确。

#### 17.15.3 rearrangeMatrix 高层封装

`utility.hpp` 提供 `rearrangeMatrix` 函数,把 3ds Max 的 `Matrix3` 转换为 BigWorld 的 `Matrix`。`MFXNode::exportTree` 与 `exportAnimation` 都调用它:

```cpp
// tools/animationexporter/mfxnode.cpp L172-180
pThisSection->writeString( "identifier", this->getIdentifier() );
Matrix3 m = rearrangeMatrix(getRelativeTransform( 0,
    !ExportSettings::instance().allowScale(), idealParent ));
m.SetRow( 3, m.GetRow(3) * ExportSettings::instance().unitScale() );
pThisSection->writeVector3( "transform/row0", reinterpret_cast<Vector3&>(m.GetRow(0)) );
pThisSection->writeVector3( "transform/row1", reinterpret_cast<Vector3&>(m.GetRow(1)) );
pThisSection->writeVector3( "transform/row2", reinterpret_cast<Vector3&>(m.GetRow(2)) );
pThisSection->writeVector3( "transform/row3", reinterpret_cast<Vector3&>(m.GetRow(3)) );
```

#### 17.15.4 unitScale 单位缩放

除了轴向,还有单位差异——3ds Max 默认 1 unit = 1 cm,BigWorld 1 unit = 1 m。所以平移分量要乘以 `unitScale`(通常 0.01):

```cpp
// tools/animationexporter/mfxnode.cpp L254
// 平移分量乘以 unitScale
```

但**旋转/缩放不乘**——旋转是相对的,缩放本身是无量纲比值,只有平移分量受单位影响。如果在旋转上也乘 unitScale,会导致动画姿态扭曲。

visualexporter 的 `applyUnitScale`(mfxexp.hpp L214-215)提供 Point3 与 Matrix3 重载,与 `unitScale` 协作完成单位转换。

#### 17.15.5 mayavisualexporter 的处理

Maya 默认就是 Y-up,所以 mayavisualexporter 不需要 Y/Z 交换,但仍需处理单位(`unitScale`)与可选的世界原点对齐(`OriginTransformer`)。这正是不同 DCC 导出器在坐标转换上的差异——**算法与 DCC 强相关**。

---

### 17.16 skin_splitter 贪心算法

#### 17.16.1 问题背景

GPU 硬件蒙皮通常限制单次 draw call 影响骨骼数(如 32/64/80,取决于常量寄存器数量)。如果一个蒙皮网格涉及 100 个骨骼,无法在单次 draw call 完成,必须拆分为多个子网格,每个子网格涉及的骨骼数不超过上限。

这是个 NP-hard 问题(类似集合覆盖),最优解需要图着色等高复杂度算法。BigWorld 用**贪心算法**实现,虽然非全局最优,但对游戏网格(骨骼局部聚集于四肢、头)实践中接近最优,且复杂度可控。

#### 17.16.2 算法分三步

**第 1 步:建立骨骼关系列表**——`SkinSplitter` 构造函数(`skin_splitter.ipp` L13-45)遍历每个三角形,收集其三顶点涉及的骨骼索引为 `BoneRelationship`,去重后存入 `relationships_`。`addRelationship` 对三角形三顶点调用重载,合并三顶点的有效骨骼(权重>0)索引到单一 `BoneRelationship`,跳过重复索引:

```cpp
// tools/exporter_common/skin_splitter.ipp L168-184
float weights[3] = { 0.f, 0.f, 0.f };
int indices[3] = { 0, 0, 0 };
getWeights( v, weights );
getIndices( v, indices );
for (size_t i = 0; i < 3; ++i)
{
    if (weights[i] > 0.f)
    {
        if( std::find( relationship.begin(), relationship.end(),
            indices[i]) == relationship.end() )
        {
            relationship.push_back( indices[i] );
        }
    }
}
```

随后移除被其他关系完全包含的冗余关系(L35-44),减少拆分次数。

**第 2 步:贪心合并关系到上限**——`createList`(`skin_splitter.cpp` L17-43)贪心选择关系合并,直到达到 `nodeLimit`:

```cpp
// tools/exporter_common/skin_splitter.cpp L17-43
bool SkinSplitter::createList(uint32 nodeLimit, BW::vector<uint32>& nodeList)
{
    nodeList = relationships_.back();               // 取首个关系
    if (nodeList.size() > nodeLimit )               // 超限则失败
        return false;
    relationships_.pop_back();

    int index = 0;
    while((index = findAppropriateRelationship(nodeLimit, nodeList)) != -1)
    {
        const BoneRelationship& r = relationships_[index];
        for (uint i = 0; i < r.size(); i++)
        {
            if(std::find(nodeList.begin(), nodeList.end(), r[i]) == nodeList.end())
                nodeList.push_back( r[i] );         // 合并新骨骼
        }
        relationships_.erase( relationships_.begin() + index );
    }
    return true;
}
```

`findAppropriateRelationship`(`skin_splitter.cpp` L54-81)寻找合并后使 `nodeList` 增量最小的关系:

```cpp
// tools/exporter_common/skin_splitter.cpp L54-81
int SkinSplitter::findAppropriateRelationship(
    uint32 nodeLimit, const BW::vector<uint32>& nodeList) const
{
    int index = -1;
    uint diff = static_cast<uint>(nodeLimit - nodeList.size() + 1);
    for (uint i = 0; i < relationships_.size(); i++)
    {
        uint curDiff = 0;
        const BoneRelationship& br = relationships_[i];
        for (uint32 j = 0; j < br.size(); j++)
        {
            if( std::find( nodeList.begin(), nodeList.end(), br[j]) == nodeList.end() )
                curDiff++;                          // 增量 = 新骨骼数
        }
        if (curDiff < diff)                        // 找更小的增量
        {
            diff = curDiff;
            index = int(i);
        }
    }
    return index;
}
```

`diff` 初始为 `nodeLimit - nodeList.size() + 1`(剩余容量+1),保证只选不超限的关系。这是**贪心选择**:每次选最小增量的关系合并,最大化每个子网格覆盖的三角形数,最小化拆分子网格数。

**第 3 步:按骨骼集拆分三角形**——`splitTriangles`(`skin_splitter.ipp` L91-125)将可被当前骨骼集覆盖的三角形从原列表移到拆分列表:

```cpp
// tools/exporter_common/skin_splitter.ipp L91-125
BW::vector<bool> indexUsed( numBones, false );     // 骨骼是否在当前集
for (uint32 i = 0; i < boneIndices.size(); i++)
    indexUsed[boneIndices[i]] = true;

VisualMesh::TriangleVector::const_iterator triIt = triangles.begin();
while (triIt != triangles.end())
{
    if (checkIndex(boneVertices[vertices[triIt->index[0]].vertexIndex], indexUsed) &&
        checkIndex(boneVertices[vertices[triIt->index[1]].vertexIndex], indexUsed) &&
        checkIndex(boneVertices[vertices[triIt->index[2]].vertexIndex], indexUsed))
    {
        splitTriangles.push_back( *triIt );        // 三顶点都在集内 → 移走
        triIt = triangles.erase( triIt );
    }
    else
    {
        triIt++;
    }
}
```

`checkIndex`(`skin_splitter.ipp` L57-74)检查顶点的所有有效骨骼(权重>0)是否都在当前骨骼集中。完整调用模式:

```cpp
SkinSplitter splitter(triangles, vertices, boneVertices);   // 建关系表
while (splitter.size() > 0)
{
    BW::vector<uint32> nodeList;
    if (!splitter.createList(boneCount, nodeList))           // 贪心取骨骼集
        return false;                                         // 骨骼过多无法拆分
    TriangleVector splitTriangles;
    SkinSplitter::splitTriangles(triangles, splitTriangles,  // 拆出三角形
        nodeList, vertices, boneVertices, numBones);
    // 用 splitTriangles + nodeList 构造子 VisualEnvelope
}
```

#### 17.16.3 算法特性分析

| 特性 | 说明 |
|---|---|
| 贪心非全局最优 | 在最坏情况(骨骼均匀分布)可能产生多余拆分,但对典型角色网格(骨骼局部聚集)效果良好 |
| 失败处理 | `createList` 返回 false 表示单个三角形骨骼数已超 `nodeLimit`,需美术减骨骼或增大上限 |
| 模板化设计 | 三个模板参数适配不同导出器的顶点类型,`getWeights`/`getIndices` 自由函数适配字段访问,实现算法与数据布局彻底解耦 |
| `vector::erase` 性能 | `splitTriangles` 用 `vector::erase` 逐个删除,O(n²) 风险,但游戏网格规模可接受 |

---

### 17.17 洪水填充 + BSP 组合导航算法

#### 17.17.1 为什么需要两种算法组合

单纯用洪水填充只能得到一张"格子点是否可通行"的位图,而寻路系统需要的是**多边形**——因为多边形可以用更少的节点表示大区域,且凸多边形内任意两点可直线移动。所以 BigWorld 用**两阶段组合**:

1. **洪水填充**:从种子点 BFS 扩散,采样碰撞场景,得到可通行位图(`AdjGridElt` 紧凑编码)
2. **BSP 分割**:把可通行位图递归二分,生成凸多边形(navPoly),并合并相邻可合并的多边形

这种组合兼具洪水填充的精确性(每 0.1m 采样一次)和 BSP 的紧凑性(多边形表示)。

#### 17.17.2 洪水填充的紧凑编码

`AdjGridElt` 的紧凑编码是这个算法的精髓——**4 位 × 8 方向 = 32 位(4 字节)**存储一个网格点的全部邻接信息,16 层高度仅 64 字节/点。对于一个 100m × 100m 的 chunk,以 0.1m 分辨率采样:

- 网格点数:1000 × 1000 = 1,000,000
- 每点存储:64 字节(16 层 × 4 字节)
- 总内存:64 MB

这是可接受的,但如果用更松散的表示(如每方向 1 字节),内存翻倍。`MAX_HEIGHTS=16` 的多层高度支持也是关键——同一 XZ 位置上方可能有多个可站立平面(桥上桥下),如果只支持单层会丢失重要拓扑信息。

#### 17.17.3 BSP 分割的凸性约束

BSP 分割把可通行区域递归切成凸的叶子节点,每个叶子节点最终成为一个 `PolygonDef`。寻路系统要求 navPoly 必须是凸多边形——凸多边形内任意两点可直线移动而不出界。这是 BSP + 合并算法的根本约束:

- `splitNode`:递归二分,选最优分割线
- `doBestHorizontalSplit`:水平分割(高度差大的情况,如台阶)
- `isConvexJoint`:判断三顶点关节是否为凸
- `joinPolygons` / `streamline`:合并相邻凸多边形,但合并后必须仍为凸

`streamline` 合并可减少 navPoly 数量,降低寻路图规模。但每次合并都要 `isConvexJoint` 验证——只有凸合并才被允许。

#### 17.17.4 集合归属与跨 chunk 邻接

生成的多边形还需要几个后处理:

**集合归属**(`calculateSetMembership`):根据种子点(`entityPts_`)决定每个多边形属于哪个"集合"。集合用于把一个 chunk 内的多边形分组,运行时寻路可以按集合过滤。

**跨 chunk 邻接边**(`determineEdgesAdjacentToOtherChunks`):用 `PhysicsHandler` 做物理测试,判断多边形的哪些边通向相邻 chunk。被标记为 `adjToAnotherChunk` 的边在运行时寻路系统会尝试跨越 chunk 边界连接到邻 chunk 的对应多边形。

**portal 扩展**(`extendThroughUnboundPortals`):把多边形扩展穿过 chunk 的未绑定 portal,确保导航网格在 chunk 边界处的连续性。

---

### 17.18 RC4 风格哈希集群分片

#### 17.18.1 多机并行生成

navgen 支持把一个空间的导航网格生成任务分发到多台机器并行执行。大型游戏空间可能有数万 chunk,单机生成需要数十小时,而 10 台机器并行可缩短到几小时。核心是 `g_totalComputers` / `g_myIndex` 两个全局变量与 `hash` 函数。

#### 17.18.2 hash 函数:RC4 风格

`hash`(`navgen.cpp` L1913-1941)是一个 RC4 风格的字符串哈希,把 chunk 标识符映射到 0-255:

```cpp
// tools/navgen/navgen.cpp L1913-1941
unsigned int hash( const char* str )
{
    static unsigned char hash[ 256 ];
    static bool inithash = true;
    if( inithash )
    {
        inithash = false;
        for( int i = 0; i < 256; ++i )
            hash[ i ] = i;                              // 初始化置换表
        int k = 7;
        for( int j = 0; j < 4; ++j )                   // 4 轮洗牌
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
        result = hash[ result ];                       // 查表置换
    }
    return result;
}
```

这是一种类似 **RC4 KSA**(Key Scheduling Algorithm)的置换:

1. 初始化 256 字节置换表 `hash[i] = i`
2. 4 轮洗牌(标准 RC4 是 1 轮,这里用 4 轮增强混淆)
3. 把字符串(长度 + 每个字符)累加并查表置换,得到 0-255 的结果

#### 17.18.3 为什么要用 RC4 风格

为什么不直接用普通字符串哈希(如 BKDR / djb2)?因为 chunk 名有强相关性——空间 chunk 通常按 `ddddeeee` 格式命名(网格坐标),相邻 chunk 名只差几个字符。简单哈希会让相邻 chunk 集中映射到同一台机器(因为哈希值相近),违背"均匀分片"的目标。

RC4 KSA 风格的置换表设计让相邻输入产生**雪崩效应**——输入差一个字符,输出完全不同。这样相邻 chunk 会均匀分散到不同机器,实现真正的并行加速。

#### 17.18.4 分片判定与集群生成对话框

在 `doGenerateAll` / `doClearAll` 中,每个 chunk 用如下判定决定是否由本机处理:

```cpp
// tools/navgen/navgen.cpp L2354-2360
if( hash( g_currentChunk->identifier().c_str() ) % g_totalComputers != g_myIndex )
{
    INFO_MSG( "Skip chunk %s because hash failed\n", g_currentChunk->identifier().c_str() );
    g_statusWindow.skip();
    continue;
}
```

- `g_totalComputers`:总机器数(默认 1)
- `g_myIndex`:本机索引(0-based,默认 0)

当 `g_totalComputers == 1` 时,`hash % 1 == 0 == g_myIndex`,所有 chunk 都由本机处理。`clusterDialogProc`(`navgen.cpp` L5145-5201)是集群配置对话框,允许用户选择总机器数(2-49)与本机索引,选择后调用 `doGenerateAll(false)`(不覆盖,只生成属于本机的 chunk)。

#### 17.18.5 实际使用场景

在 CI/CD 流水线中,典型用法是:

```bash
# 10 台机器并行生成同一空间
# 每台机器通过环境变量或参数指定 g_myIndex
# 实际通过 clusterDialog 或修改 settings 实现
navgen /s spaces/game_world /g chunk_list.txt
```

由于每台机器只处理 `hash(chunk) % 10 == myIndex` 的 chunk,10 台机器合起来覆盖整个空间,且无重复——**无需中心调度器协调,完全去中心化**。这是 navgen 集群分片的最大设计亮点。

---

### 17.19 本章小结

本章我们走了 BigWorld 工具链的离线侧两条关键链路:

**DCC 导出器**把 3ds Max/Maya 场景转译为引擎二进制资产:

1. **三个导出器**各有侧重——visualexporter 出 `.visual`,animationexporter 出 `.animation`,mayavisualexporter 全功能(出 `.visual` + `.animation`)。它们共享 `exporter_common` 公共库,后者提供 BSP 生成、蒙皮拆分、缓存清理三大横切能力。
2. **RAII 双保险**是 visualexporter 的特色——`DataSectionCachePurger` 清缓存 + `NodeCatalogueHolder` 初始化骨骼目录,作用域结束自动清理,即使异常也能释放资源。
3. **Y/Z 轴交换**是 DCC 导出的核心坐标转换——3ds Max 是 Z-up,BigWorld 是 Y-up,`writeMFXPoint`/`rearrangeMatrix` 把 Y/Z 交换完成转译,配合 `unitScale` 处理单位差异。
4. **skin_splitter 贪心算法**解决硬件蒙皮的骨骼数上限问题——建立三角形-骨骼关系表,贪心合并到 `nodeLimit` 上限,最大化子网格覆盖。模板化设计适配三个导出器的不同顶点类型。
5. **临时文件 + 校验 + 重命名**是 mayavisualexporter 的稳健性优势——失败不污染正式资源,配合 `OriginTransformer` 可逆原点变换,Maya 工作流不被破坏。

**navgen** 把 chunk 几何转译为寻路数据:

1. **三阶段流水线**清晰分层:`flood()` 洪水填充采样碰撞场景 → `generate()` BSP 分割生成凸多边形 + 邻接 + 注解 → `output()` 序列化到 `.cdata`。
2. **三层 facade 架构**:`ChunkWaypointGenerator` → `ChunkFlooder` + `WaypointGenerator` → `WaypointFlood`,职责清晰,每层可独立测试。
3. **AdjGridElt 紧凑编码**:4 位 × 8 方向 = 4 字节存储一个网格点的全部邻接信息,16 层高度仅 64 字节/点,适合大空间采样。
4. **洪水填充 + BSP 组合**:洪水填充保证精度(每 0.1m 采样),BSP 保证紧凑性(凸多边形),二者结合兼具精确与高效。
5. **RC4 风格哈希集群分片**:用类似 RC4 KSA 的置换把 chunk 名均匀分散到多台机器,雪崩效应避免相邻 chunk 集中,支持去中心化的多机并行生成。
6. **增量生成**:通过 `auxData/worldNavmesh` 存在性检查与 `navmeshDirty` 标志跳过未修改 chunk,大幅缩短 CI 流水线时间。
7. **bwlockd 集成**:`isChunkLocked` 通过 bwlockd 服务协调多人编辑,避免覆盖他人修改。

至此,BigWorld 工具链的核心环节——资源管线(第 15 章)、WorldEditor(第 16 章)、DCC 导出器与 navgen(本章)——我们都走完了。下一章我们将进入高级主题,探讨实体通信与 AOI 兴趣区域系统的实现。

---

> **参考源码路径**:
> - `programming/bigworld/tools/visualexporter/`(visualexporter)
> - `programming/bigworld/tools/animationexporter/`(animationexporter)
> - `programming/bigworld/tools/mayavisualexporter/`(mayavisualexporter)
> - `programming/bigworld/tools/exporter_common/`(公共库)
> - `programming/bigworld/tools/navgen/`(navgen)
> - `programming/bigworld/lib/waypoint_generator/`(导航生成算法库)
> - `programming/bigworld/lib/waypoint/`(寻路运行时库)
> - `programming/bigworld/tools/common/`(navgen 共享代码:chunk_flooder、girth、physics_handler、waypoint_annotator 等)
