# BigWorld Engine visualexporter(3ds Max 可视化导出器)实现深度分析

> 本文档详细分析 BigWorld Engine 14.4.1 中 `tools/visualexporter/` 模块的完整实现。该模块以 3ds Max 场景导出插件形式存在,负责将 3ds Max 场景导出为 BigWorld 运行时使用的 `.visual` / `.primitives` / `.bsp` / `.model` 资源文件。与 `animationexporter` 共享大量同名文件结构,但 `MFXNode` 仅保留 `exportTree`(无动画导出),并新增 Portal / Hull / BSP / Morpher 支持。本文涵盖插件入口、DoExport 主流程、preProcess 节点识别、网格/蒙皮/Portal 导出、visual 文件写入、BSP 生成、shell hull 生成、VisualChecker 校验等核心机制。

---

## 目录

- [一、整体架构概览](#一整体架构概览)
- [二、源码目录结构](#二源码目录结构)
- [三、插件入口与启动流程](#三插件入口与启动流程)
- [四、核心类与继承关系](#四核心类与继承关系)
- [五、DoExport 导出主流程](#五doexport-导出主流程)
- [六、preProcess 节点识别](#六preprocess-节点识别)
- [七、MFXNode 节点树(visual 版)](#七mfxnode-节点树visual-版)
- [八、网格导出 exportMeshes](#八网格导出-exportmeshes)
- [九、蒙皮导出 exportEnvelopes](#九蒙皮导出-exportenvelopes)
- [十、Portal 导出](#十portal-导出)
- [十一、visual 文件写入](#十一visual-文件写入)
- [十二、Hull 与 Shell 生成](#十二hull-与-shell-生成)
- [十三、BSP 生成](#十三bsp-生成)
- [十四、ExportSettings 配置项](#十四exportsettings-配置项)
- [十五、MaxScript 集成 BWVisualSetting](#十五maxscript-集成-bwvisualsetting)
- [十六、单位缩放 applyUnitScale](#十六单位缩放-applyunitscale)
- [十七、NodeCatalogueHolder 与缓存清理](#十七nodecatalogueholder-与缓存清理)
- [十八、与其他模块的依赖关系](#十八与其他模块的依赖关系)
- [十九、关键代码片段](#十九关键代码片段)
- [二十、设计亮点与注意事项](#二十设计亮点与注意事项)

---

## 一、整体架构概览

### 1.1 模块定位

`visualexporter` 是 BigWorld DCC 工具链中的**3ds Max 可视化导出器**,与 `animationexporter` 同属 3ds Max 插件体系,但职责不同:

- `animationexporter`:导出 `.animation`(骨骼动画)
- `visualexporter`:导出 `.visual` / `.primitives` / `.bsp` / `.model`(模型可视化资源)

核心职责:

1. 遍历 3ds Max 场景,按命名约定识别 `_bsp` / `portal` / `HP_` 节点与 `Physique`/`Skin` 蒙皮节点
2. 导出静态网格(`VisualMesh`,含 DX 材质、bump、tangent/binormal)
3. 导出蒙皮网格(`VisualEnvelope`,支持 3 骨骼/顶点,按 `boneCount` 拆分)
4. 导出 Portal(`VisualPortal`,`createConvexHull`)
5. 写 `.visual`(节点层级 + renderSet/geometry)
6. 生成 shell 的 hull + portal 边界
7. 生成 BSP(委托 `exporter_common::generateBSP`)
8. 通过 `VisualChecker` 校验资源命名

### 1.2 导出管线数据流

```
┌──────────────┐  DllMain/ClassDesc       ┌─────────────────────┐
│  3ds Max     │ ───────────────────────▶ │  MFXExport 插件     │
│  宿主进程    │  LibClassDesc(0)         │  (SceneExport 派生) │
└──────────────┘                          └──────────┬──────────┘
                                                     │ DoExport
                                                     ▼
        ┌────────────────────────────────────────────────────────┐
        │ RAII: DataSectionCachePurger + NodeCatalogueHolder      │
        │ 1. AutoConfig::configureAllFrom("resources.xml")        │
        │ 2. 路径校验 + VisualChecker                              │
        │ 3. 读取配置 (cfg / visualsettings / pSettingsOverride)  │
        │ 4. preProcess(根节点) → 识别 _bsp/portal/Physique/Skin/HP_│
        │ 5. exportMeshes(snapVertices)                           │
        │ 6. exportEnvelopes (split by boneCount)                 │
        │ 7. exportPortals                                        │
        │ 8. 写 visual (mfxRoot_->exportTree + save + 包围盒 +    │
        │    shell hull + portal 边界)                            │
        │ 9. VisualChecker 校验 → rename                           │
        │10. 写 .model                                            │
        │11. 导出 BSP (generateBSP)                                │
        └────────────────────────────────────────────────────────┘
                                                     │
                                                     ▼
        ┌──────────┬──────────┬──────────┬──────────┐
        │ .visual  │.primitives│  .bsp    │  .model  │
        └──────────┴──────────┴──────────┴──────────┘
```

### 1.3 关键设计原则

| 原则 | 说明 |
|------|------|
| **双重 RAII 守卫** | `DataSectionCachePurger` + `NodeCatalogueHolder` 在 DoExport 作用域管理资源,前者清缓存后者初始化节点目录 |
| **AutoConfig 资源配置** | 通过 `resources.xml` 自动配置路径,失败则报错退出 |
| **VisualChecker 双校验** | 导出前推断类型,导出后校验合规,通过才 rename |
| **命名约定识别** | `_bsp` / `HP_` 前缀 + `portal` 用户属性 + 修改器探测三重识别 |
| **静态/动态模式分支** | `NORMAL` 走蒙皮,`STATIC`/`STATIC_WITH_NODES` 走网格 + 节点裁剪 |
| **临时名保留字保护** | 检测 `exporter_*_temp.visual` 保留名,拒绝导出(L501-521) |

---

## 二、源码目录结构

`visualexporter` 模块位于 `programming/bigworld/tools/visualexporter/`,文件组织与 `animationexporter` 高度相似:

| 文件 | 职责 |
|------|------|
| `expmain.cpp` | DLL 入口、3ds Max 库接口、`MFXExpClassDesc`(字符串改为 "Visual Exporter") |
| `mfxexp.hpp` / `mfxexp.cpp` / `mfxexp.ipp` | 核心导出类 `MFXExport`、`DoExport` 主流程、`preProcess`、`exportMeshes`/`exportEnvelopes`/`exportPortals`、写 visual、BSP 导出 |
| `mfxnode.hpp` / `mfxnode.cpp` / `mfxnode.ipp` | `MFXNode`(仅 `exportTree`,无 `exportAnimation`) |
| `expsets.hpp` / `expsets.cpp` / `expsetsio.cpp` | `ExportSettings`(与 Maya 版功能对齐) |
| `visual_mesh.hpp` / `visual_mesh.cpp` / `visual_envelope.ipp` | 网格(含 DX 材质、bump、tangent/binormal) |
| `visual_envelope.hpp` / `visual_envelope.cpp` / `visual_envelope.ipp` | 蒙皮(支持 3 骨骼/顶点) |
| `visual_portal.hpp` / `visual_portal.cpp` | Portal,`createConvexHull` |
| `hull_mesh.hpp` / `hull_mesh.cpp` | Hull 网格 |
| `morpher_holder.hpp` | Morpher 持有器 |
| `utility.hpp` / `utility.cpp` | 工具函数 |
| `aboutbox.hpp` / `aboutbox.cpp` | About 对话框 |
| `pch.hpp` / `pch.cpp` | 预编译头 |

---

## 三、插件入口与启动流程

### 3.1 DllMain 与库接口

`expmain.cpp` 与 `animationexporter` 结构一致,差异仅在字符串资源:

- `DllMain`:校验运行目录、初始化 `BWResource`、设置 XML 兼容性
- `LibDescription` / `LibNumberClasses` / `LibClassDesc` / `LibVersion`:标准 3ds Max 库接口
- `MFXExpClassDesc`:类描述符,`Create()` 返回 `new MFXExport`

### 3.2 ClassID

`mfxexp.hpp` L44-48 定义 ClassID,与 `animationexporter` 不同,使两个插件可同时加载:

```cpp
//mfxexp.hpp L44-48
#if defined BW_EXPORTER_DEBUG
#define MFEXP_CLASS_ID	Class_ID(0x73d06c76, 0xf143737)
#else
#define MFEXP_CLASS_ID	Class_ID(0x793130d, 0x6601416c)
#endif
```

配置文件名固定为 `"visualexporter.cfg"`(L52)。

### 3.3 扩展名

`Ext(0)` 返回 `"visual"`(对应 `.visual` 输出),`ExtCount()` 返回 1。

---

## 四、核心类与继承关系

### 4.1 类继承图

```
SceneExport (3ds Max SDK)
    │
    └── MFXExport            (mfxexp.hpp L154)
            │  Ext(0) → "visual"
            │  DoExport() 主流程
            │
            ├── 持有 ExportSettings& settings_      (引用单例)
            ├── 持有 MFXNode* mfxRoot_              (节点树根,仅 exportTree)
            ├── 持有 MaterialList materials_
            ├── 持有 INodeVector {portalNodes_, envelopeNodes_, meshNodes_}
            ├── 持有 vector<VisualMeshPtr> visualMeshes_ / bspMeshes_
            ├── 持有 vector<VisualPortalPtr> visualPortals_
            ├── 持有 vector<HullMeshPtr> hullMeshes_
            └── 静态: findPhysiqueModifier / findSkinMod / findMorphModifier
                       findEditNormalsMod / getTriObject / applyUnitScale

MFXNode (mfxnode.hpp)  ── 镜像 INode 层级 (仅 exportTree)
    │  无 exportAnimation
    │  exportTree(pParentSection, idealParent, hasInvalidTransforms)

VisualMesh ── 静态网格 (DX 材质 / bump / tangent)
    │
    └── VisualEnvelope ── 蒙皮 (3 骨骼/顶点, split by boneCount)

VisualPortal ── Portal (createConvexHull)
HullMesh     ── Hull (shell 边界)

ExportSettings (单例) ── 与 Maya 版功能对齐
NodeCatalogueHolder ── RAII (Moo::NodeCatalogue 初始化)
DataSectionCachePurger ── RAII (DataSection 缓存清理)
```

### 4.2 MFXExport 类要点

`MFXExport`(mfxexp.hpp L154-242)相对 `animationexporter` 版的差异:

- 新增 `BoneCountMap` 类型别名(L157-158),记录骨骼计数
- 新增 `exportPortals` / `exportPortal` / `generateHull` / `exportHull`(L193-197)
- 新增 `planeFromBoundarySection` / `portalOnBoundary` / `exportPortalsToBoundaries`(L209-212)
- 新增 `isShell`(L206)
- 新增 `applyUnitScale` 静态方法(Point3 / Matrix3 重载,L214-215)
- 新增 `findEditNormalsMod`(L179)
- `settings_` 为引用成员(非 animationexporter 的单例直接访问),需在构造函数初始化列表初始化

---

## 五、DoExport 导出主流程

`DoExport`(mfxexp.cpp L391)是 3ds Max 调用的导出入口,完整流程如下:

### 5.1 流程步骤

```
DoExport(nameFromMax, ei, maxInterface, suppressPrompts, options)  [mfxexp.cpp:391]
│
├─[1] RAII: DataSectionCachePurger dscp + NodeCatalogueHolder nch   // L394-397
├─[2] 文件名归一化 → .visual 扩展名                                  // L414
├─[3] AutoConfig::configureAllFrom("resources.xml")                // L417
│       失败则报错返回 0
├─[4] 清理旧状态 (mfxRoot_ / 各 nodes / meshes 容器)                // L442-450
├─[5] ip_->SetCommandPanelTaskMode(TASK_MODE_MODIFY)               // L454 (edit normals 需要)
├─[6] 读取 cfg 配置 + 设置 staticFrame                              // L464-465
├─[7] 路径校验 validResource (两次:resName + resNameCamelCase)     // L468-496
├─[8] 保留名检测 (exporter_*_temp.visual)                          // L498-522
├─[9] VisualChecker vc(resNameCamelCase) 推断类型 + exportMode      // L524-534
├─[10] 读取 visualsettings + pSettingsOverride                     // L536-540
├─[11] 显示设置对话框 (非 suppressPrompts)                          // L542-553
├─[12] 更新 vc.snapVertices + nodeFilter                           // L559-568
├─[13] 写 cfg 配置                                                 // L570
├─[14] preProcess(ip_->GetRootNode())                              // L572
├─[15] exportMeshes(snapVertices)                                  // L575-579
├─[16] exportEnvelopes(errorModels)                                // 
├─[17] exportPortals()                                             // 
├─[18] 写 visual 文件 (mfxRoot_->exportTree + save + 包围盒 +      // L761+
│       shell hull + portal 边界)
├─[19] VisualChecker 校验 → rename                                 // 
├─[20] 写 .model                                                   // 
└─[21] 导出 BSP (generateBSP)                                      // L1175 / L1197
```

### 5.2 RAII 双守卫

visualexporter 独有 `NodeCatalogueHolder`(L397),初始化 `Moo::NodeCatalogue`(骨骼节点目录),供 visual 写入时查找节点。配合 `DataSectionCachePurger` 保证每次导出后缓存清空:

```cpp
//mfxexp.cpp L393-397
DataSectionCachePurger dscp;
NodeCatalogueHolder nch;
```

### 5.3 文件名处理

强制改写为 `.visual` 扩展名:

```cpp
//mfxexp.cpp L414
fileName = fileName.substr(0, fileName.size() - 7) + ".visual";
```

### 5.4 保留名保护

检测 `exporter_*_temp.visual` 保留名,拒绝导出避免与临时文件冲突(L498-521):

```cpp
//mfxexp.cpp L501-502
if (filename.substr( 0, 9 ) == "exporter_"
    && filename.substr( filename.size() - 12, 12 ) == "_temp.visual")
{
    errors_ = true;
    // ... 报错返回 0
}
```

---

## 六、preProcess 节点识别

`preProcess`(mfxexp.cpp L1502)递归遍历 3ds Max 节点树,按命名约定与修改器探测分类节点。

### 6.1 节点过滤

根据 `nodeFilter` 决定包含(L1508-1517):

| nodeFilter | 包含条件 |
|------------|----------|
| `SELECTED` | `node->Selected() && !node->IsHidden()` |
| `VISIBLE` | `!node->IsHidden()` |

### 6.2 _bsp 节点识别

节点名含 `_bsp`(不区分大小写)且未隐藏的节点,直接加入 `meshNodes_`(L1520-1540),作为 BSP 专用网格:

```cpp
//mfxexp.cpp L1520-1525
if (toLower(node->GetName()).find("_bsp") != BW::string::npos &&
    !node->IsHidden())
{
    meshNodes_.push_back( node );
    return;
}
```

### 6.3 不可导出类过滤

通过 `s_nonExportableClass` / `s_nonExportableSuperClass` 数组排除摄像机、灯光、目标等(L1546-1557)。

### 6.4 节点分类

对可渲染节点,按用户属性与修改器探测分类(L1568-1604):

| 条件 | 分类 | 说明 |
|------|------|------|
| `portal` 用户属性为真 | `portalNodes_` | Portal 节点 |
| 有 Physique/Skin 修改器且 `NORMAL` 模式 | `envelopeNodes_` | 蒙皮节点 |
| 节点名前缀非 `hp_` | `meshNodes_` | 普通网格节点 |
| 节点名前缀 `hp_` | (跳过) | Hit Point,不导出 |

```cpp
//mfxexp.cpp L1577-1603
Modifier *pPhyMod = findPhysiqueModifier( node );
Modifier* pSkinMod = findSkinMod( node );
BW::string nodePrefix = toLower(nodeName.substr( 0, 3 ));

if (isPortal)
{
    portalNodes_.push_back( node );
    includeNode = false;
}
else if( (pPhyMod || pSkinMod) && settings_.exportMode() == ExportSettings::NORMAL )
{
    envelopeNodes_.push_back( node );
    includeNode = false;
}
else if (nodePrefix != "hp_")
{
    meshNodes_.push_back( node );
}
```

### 6.5 MFXNode 树构建

为每个节点创建 `MFXNode`,若 `includeNode` 则调用 `includeAncestors()` 传播包含标记(L1606-1616):

```cpp
//mfxexp.cpp L1615-1616
if (includeNode)
    thisNode->includeAncestors();
```

并校验节点名无前后空白(L1618+)。

---

## 七、MFXNode 节点树(visual 版)

visualexporter 的 `MFXNode` 与 animationexporter 同名但**精简**:仅保留 `exportTree`(写 visual 节点层级 XML),**无 `exportAnimation`**。

### 7.1 exportTree 签名差异

visualexporter 版 `exportTree` 增加 `hasInvalidTransforms` 输出参数,检测骨骼缩放导致的非法变换:

```cpp
//mfxexp.cpp L784
mfxRoot_->exportTree( pVisualSection, 0, &hasInvalidTransforms );
```

若 `hasInvalidTransforms` 为真,弹窗警告"骨骼变换非法(可能因骨骼缩放),可能引入动画伪影"(L785-805)。

### 7.2 静态模式节点裁剪

`STATIC` / `MESH_PARTICLES` 模式下,删除 `mfxRoot_` 的所有子节点,只保留根(L777-781),因静态模型不需要骨骼层级:

```cpp
//mfxexp.cpp L777-781
if (settings_.exportMode() == ExportSettings::STATIC
    || settings_.exportMode() == ExportSettings::MESH_PARTICLES)
{
    mfxRoot_->delChildren();
}
```

---

## 八、网格导出 exportMeshes

`exportMeshes`(mfxexp.cpp L1659)遍历 `meshNodes_`,对每个节点调用 `exportMesh`。

### 8.1 snapVertices 传递

`snapVertices` 参数根据导出模式决定(L575-576):静态模式且开启 `snapVertices` 时为真,使顶点 snapping 到网格以优化静态模型:

```cpp
//mfxexp.cpp L575-576
if (!this->exportMeshes( settings_.exportMode() != ExportSettings::NORMAL &&
                settings_.snapVertices() ))
{
    errors_ = true;
    return 0;
}
```

### 8.2 exportMesh 流程

`exportMesh`(L1719)对单个 INode:
1. `getTriObject` 获取三角化几何
2. 构造 `VisualMesh`,`init(node)` 提取几何与材质
3. 加入 `visualMeshes_` 集合

### 8.3 VisualMesh 特性

visualexporter 版 `VisualMesh` 支持:
- DX 材质(Direct3D 材质格式)
- bump mapping(切线/副法线生成)
- `checkNodeHasUVs`(L166)校验 UV 存在性

---

## 九、蒙皮导出 exportEnvelopes

`exportEnvelopes`(mfxexp.cpp L1765)遍历 `envelopeNodes_`,对每个蒙皮节点创建 `VisualEnvelope` 并按 `boneCount` 拆分。

### 9.1 流程

```cpp
//mfxexp.cpp L1765-1790
bool MFXExport::exportEnvelopes( BW::vector<BW::string>& errorModels )
{
    BW::vector<VisualEnvelopePtr> splitEnvelopes;
    bool res = true;
    for (size_t i = 0; i < envelopeNodes_.size(); ++i)
    {
        VisualEnvelopePtr spVisualEnvelope = new VisualEnvelope;
        if (spVisualEnvelope->init( envelopeNodes_[i], mfxRoot_ ))
        {
            if (!spVisualEnvelope->split( settings_.boneCount(), splitEnvelopes ))
            {
                errorModels.push_back( spVisualEnvelope->getIdentifier() );
                res = false;
            }
        }
    }
    for (size_t i = 0; i < splitEnvelopes.size(); ++i)
    {
        visualMeshes_.push_back( splitEnvelopes[i].get() );
    }
    return res;
}
```

### 9.2 拆分后合并

拆分出的子 `VisualEnvelope` 全部加入 `visualMeshes_`(L1784-1787),后续与普通网格统一写 `.visual`。拆分失败(骨骼过多)的模型名记入 `errorModels` 返回。

### 9.3 3 骨骼/顶点

visualexporter 版 `VisualEnvelope` 支持每顶点 3 骨骼影响(`VertexXYZNUVIIIWW` 格式:3 索引 + 2 权重,第 3 权重 = 255 - w1 - w2),通过 `SkinSplitter` 保证单 draw call 骨骼数不超过 `boneCount`。

---

## 十、Portal 导出

`exportPortals`(mfxexp.cpp L1793)遍历 `portalNodes_`,对每个 portal 节点调用 `exportPortal`。

### 10.1 exportPortal 流程

`exportPortal`(L1801)对单个 portal 节点:
1. `getTriObject` 获取三角化几何
2. 检测 `isMirrored(portalMatrix)` 判断法线翻转(L1822)
3. 用 `UniqueVertices` 去重顶点,镜像时反转顶点顺序(L1826-1833)
4. 构造 `VisualPortal`,调用 `createConvexHull` 生成凸包

```cpp
//mfxexp.cpp L1828-1833
if( inverted )
{
    verts.addVertex( VertexContainer( mesh->faces[ i ].v[ 2 ], 0 ) );
    verts.addVertex( VertexContainer( mesh->faces[ i ].v[ 1 ], 0 ) );
    verts.addVertex( VertexContainer( mesh->faces[ i ].v[ 0 ], 0 ) );
}
```

### 10.2 createConvexHull

`VisualPortal::createConvexHull` 将 portal 多边形顶点构造成凸包,用于运行时 chunk 间可见性判定。

### 10.3 portalOnBoundary

`portalOnBoundary`(mfxexp.cpp L1339)校验 portal 平面是否落在 chunk 边界平面上,保证 portal 正确连接相邻 chunk。`exportPortalsToBoundaries`(L1362)将 portal 关联到对应边界。

---

## 十一、visual 文件写入

visual 文件写入是 visualexporter 的核心输出,位于 mfxexp.cpp L761-983。

### 11.1 写入流程

```
写 visual 文件                                                [mfxexp.cpp:761+]
│
├─[1] 创建 DataResource visualFile(临时名, XML)               // L761
├─[2] pVisualSection->delChildren()                           // L772 清空
├─[3] mfxRoot_->exportTree(pVisualSection, 0, &hasInvalid)    // L784 写节点层级
│       STATIC/MESH_PARTICLES 模式先 delChildren
├─[4] 写 materialKind                                         // L808
├─[5] 各 VisualMesh->save(pVisualSection, existingVisual,     // L823+
│       tempPrimFileName, useIdentifier)
├─[6] 计算包围盒 BoundingBox                                  // 
├─[7] shell 模式: generateHull + exportHull +                 // L1290+
│       exportPortalsToBoundaries
├─[8] visualFile.save()                                       // 
├─[9] VisualChecker 校验临时文件                              // 
└─[10] rename 临时文件为正式名                                // 
```

### 11.2 节点层级写入

`mfxRoot_->exportTree`(L784)递归写 `node` XML 段,STATIC 模式裁剪子节点:

```cpp
//mfxexp.cpp L773-784
if (mfxRoot_)
{
    mfxRoot_->setMaxNode( NULL );
    mfxRoot_->setIdentifier( "Scene Root" );
    if (settings_.exportMode() == ExportSettings::STATIC
        || settings_.exportMode() == ExportSettings::MESH_PARTICLES)
    {
        mfxRoot_->delChildren();
    }
    bool hasInvalidTransforms = false;
    mfxRoot_->exportTree( pVisualSection, 0, &hasInvalidTransforms );
}
```

### 11.3 非法变换警告

`hasInvalidTransforms` 检测骨骼缩放导致的非法变换,弹窗警告可能引入动画伪影(L785-805)。

---

## 十二、Hull 与 Shell 生成

### 12.1 isShell 判定

`isShell`(mfxexp.cpp L1254)根据资源名判断是否为 shell(chunk 外壳)模型,决定是否生成 hull + portal 边界。

### 12.2 generateHull

`generateHull`(mfxexp.cpp L1290)根据包围盒 `BoundingBox` 生成 shell 的 hull 几何:

```cpp
//mfxexp.cpp L1290
void MFXExport::generateHull( DataSectionPtr pVisualSection, const BoundingBox& bb )
```

### 12.3 exportHull

`exportHull`(L1268)将 hull 网格写入 visual 的 boundary 段。

### 12.4 exportPortalsToBoundaries

`exportPortalsToBoundaries`(L1362)将 portal 关联到 chunk 边界平面,需 `planeFromBoundarySection`(L1325)解析边界平面方程,`portalOnBoundary`(L1339)校验 portal 落在边界上。

### 12.5 planeFromBoundarySection

`planeFromBoundarySection`(L1325)从 XML boundary 段读取平面方程(`PlaneEq`),供 portal-boundary 匹配使用。

---

## 十三、BSP 生成

visualexporter 通过 `exporter_common::generateBSP` 生成 BSP,有两处调用:

### 13.1 _bsp 节点的 BSP

带 `_bsp` 命名的节点导出为独立 BSP(mfxexp.cpp L1175):

```cpp
//mfxexp.cpp L1175
generateBSP( bspResName, BWResource::removeExtension( bspResName ) + ".bsp", bspMaterialIDs );
```

### 13.2 主 visual 的 BSP

主 visual 的 BSP 由 `generateBSP(resName, visualBspResName, bspMaterialIDs)` 生成(L1197),随后合并到 `.primitives`。

`generateBSP` 实现详见 exporter_common 文档:遍历 renderSet→geometry,加载 vertices/primitive,`populateWorldTriangles` 收集三角形(经 `WorldTriDegenerateCuller` 剔除退化三角形),`BSPTreeTool::buildBSP` 构建树,`saveBSPInFile` 持久化。

---

## 十四、ExportSettings 配置项

visualexporter 版 `ExportSettings` 与 Maya 版功能对齐,支持:

| 配置项 | 说明 |
|--------|------|
| `exportMode` | NORMAL / STATIC / STATIC_WITH_NODES / MESH_PARTICLES |
| `boneCount` | 单 draw call 最大骨骼数 |
| `transformToOrigin` | 原点变换 |
| `bumpMapped` | bump mapping |
| `snapVertices` | 顶点 snapping |
| `allowScale` | 允许骨骼缩放 |
| `useLegacyScaling` / `useLegacyOrientation` | 旧版约定 |
| `nodeFilter` | ALL / SELECTED / VISIBLE |
| `staticFrame` | 静态帧 |
| `visualTypeIdentifier` | VisualChecker 类型标识 |
| `disableVisualChecker` | 禁用校验 |
| `referenceNodesFile` | 引用层级文件 |

### 14.1 配置加载优先级

`DoExport` 按以下顺序读取(L464-540):

1. `getCfgFilename()`(`visualexporter.cfg`,插件配置目录)
2. `VisualChecker` 推断类型与 exportMode
3. `settingsFilename`(`<name>.visualsettings`)
4. `pSettingsOverride`(MaxScript `BWVisualSetting` 覆盖)
5. 显示对话框(可修改)
6. 写回 cfg

---

## 十五、MaxScript 集成 BWVisualSetting

visualexporter 注册 MaxScript 命令 `BWVisualSetting`(mfxexp.cpp L73),供脚本批量导出覆盖配置。与 `animationexporter` 的 `BWAnimationSetting` 机制相同,但支持更多设置键(对应 `ExportSettings` 全字段)。

### 15.1 注册

```cpp
//mfxexp.cpp L73
def_visible_primitive(BWVisualSetting, "BWVisualSetting");
```

### 15.2 Debug 版限制

`BW_EXPORTER_DEBUG` 编译时不链接 MaxScript 库,命令不可用,与 animationexporter 一致。

---

## 十六、单位缩放 applyUnitScale

`applyUnitScale`(mfxexp.hpp L214-215)提供 Point3 与 Matrix3 重载,将 3ds Max 单位转换为 BigWorld 单位:

```cpp
//mfxexp.hpp L214-215
static Point3   applyUnitScale( const Point3& p );
static Matrix3  applyUnitScale( const Matrix3& m );
```

`unitScale` 来自 `ExportSettings`,通常为 0.01(3ds Max 1 unit = 1 cm,BigWorld 1 unit = 1 m)。所有几何导出前应用此缩放,保证运行时尺度一致。

### 16.1 checkNodeHasUVs

`checkNodeHasUVs`(mfxexp.cpp L166)校验网格节点是否有 UV,无 UV 的网格会导致纹理错误。该校验在 preProcess 阶段执行,发现无 UV 节点会输出警告,提示美术补全 UV 通道。

### 16.2 unitScale 与 applyUnitScale 协作

`unitScale` 取自 `ExportSettings`,导出器在两处应用:(1)`applyUnitScale` 对 Point3/Matrix3 缩放几何;(2) `MFXNode::exportTree` 对变换矩阵平移分量乘 `unitScale`(mfxnode.cpp L175)。两者必须一致,否则网格与骨骼尺度不匹配会导致蒙皮错位。3ds Max 默认 1 unit = 1 cm,BigWorld 1 unit = 1 m,故 `unitScale` 通常为 0.01。

---

## 十七、NodeCatalogueHolder 与缓存清理

### 17.1 NodeCatalogueHolder

`NodeCatalogueHolder`(exporter_common/node_catalogue_holder.hpp L12)是 visualexporter 独有的 RAII 守卫:

- 构造:初始化 `Moo::NodeCatalogue`(骨骼节点目录)
- 析构:销毁 `NodeCatalogue`

`Moo::NodeCatalogue` 提供骨骼节点的全局查找,visual 写入时通过它解析骨骼引用。**仅 visualexporter 使用**(Maya 版与 animationexporter 不需要)。

### 17.2 DataSectionCachePurger

`DataSectionCachePurger`(exporter_common/data_section_cache_purger.hpp L12)RAII 守卫:

- 析构:清空 `DataSection` 缓存

所有三个导出器入口均使用,解决 3ds Max/Maya 插件常驻导致的缓存膨胀。

### 17.3 双守卫协作

DoExport 同时构造二者(L394-397),`NodeCatalogueHolder` 先初始化目录,`DataSectionCachePurger` 后清理缓存,作用域结束按构造逆序析构:

```cpp
//mfxexp.cpp L393-397
DataSectionCachePurger dscp;
NodeCatalogueHolder nch;
```

---

## 十八、与其他模块的依赖关系

### 18.1 依赖图

```
visualexporter
    │
    ├──► cstdmf          (BinaryFile, SmartPointer, StringHashMap, guard, log_msg)
    ├──► resmgr          (BWResource, XMLSection, DataSection, DataResource, AutoConfig, NativeFileSystem)
    ├──► math            (Matrix, Vector3, Quaternion, boundbox, planeeq)
    ├──► moo             (Node, NodeCatalogue, VertexFormats, Primitive, Vertices)
    ├──► exporter_common (generateBSP, SkinSplitter, NodeCatalogueHolder, DataSectionCachePurger)
    ├──► physics2        (BSPTreeTool, WorldTriangle — 经 exporter_common 间接)
    └── 3ds Max SDK      (Max.h, istdplug.h, stdmat.h, decomp.h, shape.h, interpik.h,
                          modstack.h, phyexp.h, iparamm2.h, iskin.h, maxscript/*, IEditNormalsMod)
```

### 18.2 与 DCC SDK 集成要点

- **插件注册**:同 animationexporter,`ClassDesc` + `SCENE_EXPORT_CLASS_ID`
- **修改器探测**:`findPhysiqueModifier` / `findSkinMod` / `findMorphModifier` / `findEditNormalsMod`(后者为 visualexporter 独有,识别 EditNormals 修改器以正确导出法线)
- **用户属性**:`node->GetUserPropBool("portal", isPortal)` 读取 portal 标记(L1572-1575)
- **命令面板模式**:`ip_->SetCommandPanelTaskMode(TASK_MODE_MODIFY)`(L454),EditNormals 修改器需要此模式才能正确工作

### 18.3 与 animationexporter 的关系

| 维度 | visualexporter | animationexporter |
|------|----------------|-------------------|
| 输出 | `.visual` / `.primitives` / `.bsp` / `.model` | `.animation` |
| MFXNode | 仅 `exportTree` | `exportTree` + `exportAnimation` |
| ClassID | `0x793130d, 0x6601416c` | `0x25810e56, 0x61a93faa` |
| CFG | `visualexporter.cfg` | `animationexporter.cfg` |
| NodeCatalogueHolder | 使用 | 不使用 |
| Portal/Hull/BSP | 支持 | 不支持 |
| Morpher | 支持(`morpher_holder.hpp`) | 不支持 |
| EditNormals | 支持(`findEditNormalsMod`) | 不支持 |

### 18.4 与 mayavisualexporter 的关系

功能对应,差异在 DCC SDK 与节点识别方式。详见 mayavisualexporter 文档第 18.4 节对照表。

---

## 十九、关键代码片段

### 19.1 DoExport RAII 双守卫

```cpp
//mfxexp.cpp L391-397
int MFXExport::DoExport(const TCHAR *nameFromMax,ExpInterface *ei,Interface *maxInterface, BOOL suppressPrompts, DWORD options)
{
    DataSectionCachePurger dscp;
    NodeCatalogueHolder nch;
    ip_ = maxInterface;
    // ...
}
```

### 19.2 preProcess _bsp 节点识别

```cpp
//mfxexp.cpp L1520-1540
if (toLower(node->GetName()).find("_bsp") != BW::string::npos &&
    !node->IsHidden())
{
    if (settings_.nodeFilter() == ExportSettings::SELECTED )
    {
        if (node->Selected())
        {
            meshNodes_.push_back( node );
            return;
        }
    }
    else
    {
        meshNodes_.push_back( node );
        return;
    }
}
```

### 19.3 preProcess 节点分类

```cpp
//mfxexp.cpp L1577-1603
Modifier *pPhyMod = findPhysiqueModifier( node );
Modifier* pSkinMod = findSkinMod( node );
BW::string nodePrefix = toLower(nodeName.substr( 0, 3 ));

if (isPortal)
{
    portalNodes_.push_back( node );
    includeNode = false;
}
else if( (pPhyMod || pSkinMod) && settings_.exportMode() == ExportSettings::NORMAL )
{
    envelopeNodes_.push_back( node );
    includeNode = false;
}
else if (nodePrefix != "hp_")
{
    meshNodes_.push_back( node );
}
```

### 19.4 exportEnvelopes 拆分

```cpp
//mfxexp.cpp L1773-1781
VisualEnvelopePtr spVisualEnvelope = new VisualEnvelope;
if (spVisualEnvelope->init( envelopeNodes_[i], mfxRoot_ ))
{
    if (!spVisualEnvelope->split( settings_.boneCount(), splitEnvelopes ))
    {
        errorModels.push_back( spVisualEnvelope->getIdentifier() );
        res = false;
    }
}
```

### 19.5 exportPortal 镜像处理

```cpp
//mfxexp.cpp L1820-1833
Matrix3 portalMatrix = node->GetObjectTM( staticFrame() );
bool inverted = isMirrored( portalMatrix );
UniqueVertices verts;
for( int i = 0; i < mesh->getNumFaces(); i++ )
{
    if( inverted )
    {
        verts.addVertex( VertexContainer( mesh->faces[ i ].v[ 2 ], 0 ) );
        verts.addVertex( VertexContainer( mesh->faces[ i ].v[ 1 ], 0 ) );
        verts.addVertex( VertexContainer( mesh->faces[ i ].v[ 0 ], 0 ) );
    }
    else
    {
        // 正序添加
    }
}
```

### 19.6 visual 节点层级写入(静态裁剪)

```cpp
//mfxexp.cpp L773-784
if (mfxRoot_)
{
    mfxRoot_->setMaxNode( NULL );
    mfxRoot_->setIdentifier( "Scene Root" );
    if (settings_.exportMode() == ExportSettings::STATIC
        || settings_.exportMode() == ExportSettings::MESH_PARTICLES)
    {
        mfxRoot_->delChildren();
    }
    bool hasInvalidTransforms = false;
    mfxRoot_->exportTree( pVisualSection, 0, &hasInvalidTransforms );
}
```

### 19.7 保留名保护

```cpp
//mfxexp.cpp L498-522
BW::StringRef filename = BWResource::getFilename( resName );
if (filename.length() >= 12)
{
    if (filename.substr( 0, 9 ) == "exporter_"
        && filename.substr( filename.size() - 12, 12 ) == "_temp.visual")
    {
        errors_ = true;
        BW::string msg = filename + " is a reserved name, not exporting.";
        // ... 报错返回 0
    }
}
```

---

## 二十、设计亮点与注意事项

### 20.1 设计亮点

1. **双重 RAII 守卫**:`DataSectionCachePurger` + `NodeCatalogueHolder` 协作,前者保证缓存不膨胀,后者保证节点目录可用,作用域结束自动清理,无需手动管理。

2. **三重节点识别**:`_bsp` 命名 + `portal` 用户属性 + Physique/Skin 修改器探测,覆盖不同美术工作流,使导出器适应多种场景组织方式。

3. **静态模式节点裁剪**:`STATIC`/`MESH_PARTICLES` 模式 `delChildren()` 移除骨骼层级,减小 visual 体积,运行时无需加载无用节点。

4. **非法变换检测**:`exportTree` 的 `hasInvalidTransforms` 输出主动检测骨骼缩放导致的非法变换,提前警告美术,避免运行时蒙皮伪影难以排查。

5. **保留名保护**:`exporter_*_temp.visual` 保留名检测,避免导出器与自身临时文件命名冲突导致死循环。

6. **Portal 镜像处理**:`isMirrored` 检测 portal 法线翻转,镜像时反转顶点顺序,保证 portal 朝向正确。

7. **EditNormals 修改器支持**:`findEditNormalsMod` 识别 EditNormals 修改器,正确导出美术手动调整的法线,需 `TASK_MODE_MODIFY` 命令面板模式配合。

8. **shell hull + portal 边界联动**:`isShell` 判定后自动生成 hull 并关联 portal 到边界,保证 chunk 外壳完整。

### 20.2 注意事项

1. **必须从 bigworld/tools/exporter 运行**:`DllMain` 校验运行目录,禁止从 3ds Max 插件目录加载,否则资源路径解析失败。

2. **resources.xml 依赖**:`AutoConfig::configureAllFrom("resources.xml")` 失败则导出中止(L417-441),需保证 `paths.xml` 正确配置。

3. **TASK_MODE_MODIFY 副作用**:`ip_->SetCommandPanelTask_MODE_MODIFY`(L454)会切换 3ds Max 命令面板,可能影响美术操作,导出后需手动恢复。

4. **NORMAL 模式才导出蒙皮**:`exportMode == NORMAL` 才将 Physique/Skin 节点归入 `envelopeNodes_`(L1595),STATIC 模式下蒙皮节点按普通网格处理,可能丢失骨骼。

5. **boneCount 与拆分失败**:`split` 失败表示骨骼过多无法在 `boneCount` 限制内拆分,模型名记入 `errorModels`,需美术减少骨骼或增大 `boneCount`。

6. **NodeCatalogueHolder 仅 visualexporter 使用**:Maya 版与 animationexporter 不初始化 `Moo::NodeCatalogue`,若共享代码误用会崩溃。

7. **VisualChecker 命名规范**:资源名必须符合 camelCase 与路径层级,否则 `validResource` 失败。两次校验(resName + resNameCamelCase)确保大小写规范。

8. **坐标系约定**:3ds Max 为 Z-up,BigWorld 为 Y-up,所有变换经 `rearrangeMatrix` 转换。`applyUnitScale` 处理单位,扩展时需同时考虑。

9. **Morpher 支持**:`morpher_holder.hpp` 持有 Morpher 修改器数据,用于表情动画,需 `MorpherClassID.h`(Max 2012+)或 `wm3.h`(旧版)。

10. **HP_ 节点不导出**:`hp_` 前缀节点(Hit Point)被跳过(L1600),用于美术标记游戏逻辑点,不进入 visual。

11. **与 animationexporter 的 ClassID 区分**:两插件 ClassID 不同,可同时加载,但同名文件(`mfxexp` 等)独立维护,修改一处不影响另一处。

---

> **参考文件路径**:
> - `programming/bigworld/tools/visualexporter/expmain.cpp`
> - `programming/bigworld/tools/visualexporter/mfxexp.hpp` / `mfxexp.cpp`
> - `programming/bigworld/tools/visualexporter/mfxnode.hpp` / `mfxnode.cpp`
> - `programming/bigworld/tools/visualexporter/visual_mesh.hpp`
> - `programming/bigworld/tools/visualexporter/visual_envelope.hpp`
> - `programming/bigworld/tools/visualexporter/visual_portal.hpp`
> - `programming/bigworld/tools/visualexporter/hull_mesh.hpp`
> - `programming/bigworld/tools/visualexporter/morpher_holder.hpp`
> - `programming/bigworld/tools/visualexporter/expsets.hpp`
