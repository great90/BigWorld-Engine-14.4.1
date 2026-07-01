# BigWorld Engine mayavisualexporter(Maya 可视化导出器)实现深度分析

> 本文档详细分析 BigWorld Engine 14.4.1 中 `tools/mayavisualexporter/` 模块的完整实现。该模块以 Maya 插件(.mll/DLL)形式存在,通过 `MPxFileTranslator` 注册为 "BigWorldAsset" 文件翻译器,负责将 Maya 场景导出为 BigWorld 运行时使用的 `.visual` / `.primitives` / `.bsp` / `.model` / `.animation` 等资源文件。本文涵盖插件入口、writer 主流程、网格/蒙皮/Portal/Hull/BSP 导出、OriginTransformer 原点变换、VisualChecker 校验、BlendShape、骨骼集拆分、配置选项解析等核心机制。

---

## 目录

- [一、整体架构概览](#一整体架构概览)
- [二、源码目录结构](#二源码目录结构)
- [三、插件入口与启动流程](#三插件入口与启动流程)
- [四、核心类与继承关系](#四核心类与继承关系)
- [五、writer 导出主流程](#五writer-导出主流程)
- [六、exportMesh 单网格导出](#六exportmesh-单网格导出)
- [七、OriginTransformer 原点变换](#七origintransformer-原点变换)
- [八、VisualMesh 与 VisualEnvelope](#八visualmesh-与-visualenvelope)
- [九、蒙皮拆分 SkinSplitter](#九蒙皮拆分-skinsplitter)
- [十、骨骼权重归一化](#十骨骼权重归一化)
- [十一、Portal 与 Hull 导出](#十一portal-与-hull-导出)
- [十二、BSP 生成](#十二bsp-生成)
- [十三、.model 文件导出](#十三model-文件导出)
- [十四、Hierarchy 节点层级](#十四hierarchy-节点层级)
- [十五、ExportSettings 配置项](#十五exportsettings-配置项)
- [十六、parseOptionsString 选项解析](#十六parseoptionsstring-选项解析)
- [十七、VisualChecker 校验机制](#十七visualchecker-校验机制)
- [十八、与其他模块的依赖关系](#十八与其他模块的依赖关系)
- [十九、关键代码片段](#十九关键代码片段)
- [二十、设计亮点与注意事项](#二十设计亮点与注意事项)

---

## 一、整体架构概览

### 1.1 模块定位

`mayavisualexporter` 是 BigWorld DCC 工具链中**功能最完整的可视化导出器**,以 Maya 文件翻译器插件形式注册。与 3ds Max 版 `visualexporter` 相比,Maya 版支持的导出模式更多(`NORMAL`/`STATIC`/`STATIC_WITH_NODES`/`MESH_PARTICLES`),配置项也更丰富。核心职责:

1. 遍历 Maya DAG,识别 `_bsp` / `_hull` / `HP_` / portal 节点
2. 导出静态网格(`VisualMesh`)与蒙皮网格(`VisualEnvelope`,支持按 `maxBones` 拆分)
3. 导出 Portal(凸包边界)与 Hull(shell 边界)
4. 生成 BSP(委托 `exporter_common::generateBSP`)
5. 写 `.visual` / `.primitives` / `.bsp` / `.model`
6. 可选导出动画(`.animation`)
7. 通过 `VisualChecker` 校验资源命名规范

### 1.2 导出管线数据流

```
┌──────────────┐  initializePlugin        ┌────────────────────────┐
│  Maya 宿主   │ ───────────────────────▶ │ VisualFileTranslator   │
│              │  registerFileTranslator  │ (MPxFileTranslator派生)│
└──────────────┘  "BigWorldAsset"         └───────────┬────────────┘
                                                     │ writer()
                                                     ▼
        ┌──────────────────────────────────────────────────────────┐
        │ 1. 解析 optionsString (noPrompt/automatedTest)           │
        │ 2. 资源名校验 validResource + VisualChecker               │
        │ 3. 读取配置 (backup visual / visualsettings)             │
        │ 4. 显示对话框 (非 noPrompt)                              │
        │ 5. parseOptionsString 覆盖设置                           │
        │ 6. OriginTransformer 原点平移 (transformToOrigin)        │
        │ 7. 遍历 DAG → 分类 (mesh/envelope/portal/hull/bsp)       │
        │ 8. 对每个网格 exportMesh:                                │
        │      临时文件 → exportTree → save → VisualChecker        │
        │      → rename → 生成 BSP → 合并到 .primitives            │
        │ 9. 导出 BSP (generateBSP)                                │
        │10. 导出 .model (nodefullVisual/nodelessVisual)          │
        │11. 导出 .animation (exportAnim)                         │
        └──────────────────────────────────────────────────────────┘
                                                     │
                                                     ▼
        ┌──────────┬──────────┬──────────┬──────────┬──────────┐
        │ .visual  │.primitives│  .bsp    │  .model  │.animation│
        └──────────┴──────────┴──────────┴──────────┴──────────┘
```

### 1.3 关键设计原则

| 原则 | 说明 |
|------|------|
| **临时文件 + 重命名** | 先导出到 `exporter_NNN_temp.visual` 临时文件,通过 `VisualChecker` 校验后再 rename 为正式名,保证失败不污染正式资源 |
| **原点变换可逆** | `OriginTransformer` RAII 对象在构造时平移根节点,析构时还原,导出过程不破坏美术场景 |
| **backup visual 配置继承** | 读取已有 `.visual` 的设置作为默认,实现"重新导出保留上次配置" |
| **资源名校验** | `validResource` + `VisualChecker` 强制资源命名符合 BigWorld 规范(camelCase / 路径层级) |
| **MELError 作用域守卫** | `ScopedMELErrorVariableHandler` 在 writer 作用域内捕获 Maya 错误变量 |

---

## 二、源码目录结构

`mayavisualexporter` 模块位于 `programming/bigworld/tools/mayavisualexporter/`,文件组织如下:

| 文件 | 职责 |
|------|------|
| `visualmain.cpp` | 插件入口 `initializePlugin` / `uninitializePlugin` / `DllMain` |
| `visualfiletranslator.hpp` / `.cpp` | 核心翻译器类 `VisualFileTranslator`(继承 `MPxFileTranslator`)、`writer` 主流程、`parseOptionsString`、`OriginTransformer`、`exportMesh`、`exportTree` |
| `expsets.hpp` / `.cpp` / `.ipp` / `expsetsio.cpp` | `ExportSettings` 单例(字段最全版本) |
| `visual_mesh.hpp` / `.cpp` / `.ipp` | `VisualMesh`(继承 `ReferenceCount`)静态网格 |
| `visual_envelope.hpp` / `.cpp` / `.ipp` | `VisualEnvelope`(继承 `VisualMesh`)蒙皮网格,`split` 拆分 |
| `visual_portal.hpp` / `.cpp` | Portal 导出 |
| `hull_mesh.hpp` / `.cpp` | Hull 网格(shell 边界) |
| `hierarchy.hpp` / `.cpp` | `Hierarchy` 节点层级树(封装 `MDagPath`) |
| `mesh.hpp` / `.cpp` | Maya 网格封装 |
| `skin.hpp` / `.cpp` | Maya skinCluster 封装 |
| `portal.hpp` / `.cpp` | Maya portal 封装 |
| `blendshapes.hpp` / `.cpp` | BlendShape 导出 |
| `boneset.hpp` / `.cpp` + `bonevertex.hpp` / `.cpp` | 骨骼集 / 顶点权重 |
| `material.hpp` / `.cpp` | 材质导出 |
| `face.hpp` / `.cpp` + `vertex.hpp` / `.cpp` | 面 / 顶点基础结构 |
| `matrix.hpp` / `.cpp` + `matrix3.hpp` + `matrix4.hpp` | 矩阵数学 |
| `vector2.hpp` + `vector3.hpp` | 向量数学 |
| `constraints.hpp` / `.cpp` | 约束导出 |
| `utility.hpp` / `.cpp` | 工具函数 |
| `exportiterator.h` | `ExportIterator` Maya DAG 遍历器 |
| `exporter.xml` | 默认设置文件 |
| `exporter.cpp` | 导出辅助 |
| `pch.hpp` / `pch.cpp` | 预编译头 |

---

## 三、插件入口与启动流程

### 3.1 initializePlugin

`visualmain.cpp` L38 的 `initializePlugin`(Maya 插件加载入口)完成:

1. 创建 `MFnPlugin`(L45),声明作者 "Micro Forte"、版本 "2.0"
2. 调用 `plugin.registerFileTranslator` 注册 "BigWorldAsset" 翻译器(L52-56),`creator` 指向 `VisualFileTranslator::creator`
3. 从插件加载路径推算 `toolsPath`,校验**不能从 maya 目录运行**(L85-92)
4. `BWResource::init` 初始化资源管理器(L99)
5. 添加 `NativeFileSystem` 基础文件系统(L108)
6. `AutoConfig::configureAllFrom("resources.xml")` 自动配置资源(L110),失败则报错
7. 设置 `ExportSettings` 的设置文件名为插件目录下 `exporter.xml` 并读取(L117-118)
8. `XMLSection::shouldWriteXMLAttributes(false)` 保持 XML 兼容性(L124)

### 3.2 uninitializePlugin

`visualmain.cpp` L131 的 `uninitializePlugin` 调用 `plugin.deregisterFileTranslator("BigWorldAsset")` 注销翻译器(L146)。

### 3.3 DllMain

Win32 下 `DllMain`(L158)仅记录 `hInstance`。Maya 插件的实际初始化在 `initializePlugin` 完成。

---

## 四、核心类与继承关系

### 4.1 类继承图

```
MPxFileTranslator (Maya SDK)
    │
    └── VisualFileTranslator        (visualfiletranslator.hpp L16)
            │  writer()      → 导出主流程
            │  exportMesh()  → 单网格导出
            │  haveWriteMethod() → true
            │  defaultExtension() → "visual"
            │
            ├── 持有 vector<VisualMeshPtr> visualMeshes
            ├── 持有 vector<HullMeshPtr> hullMeshes
            ├── 持有 vector<VisualMeshPtr> bspMeshes
            ├── 持有 vector<VisualPortalPtr> visualPortals
            └── 持有 StringHashMap<BW::string> nodeParents_  (引用层级)

ReferenceCount (cstdmf)
    │
    └── VisualMesh                  (visual_mesh.hpp L36)
            │  init() / save() / resources()
            │  Triangle / BloatVertex / VertexContainer
            │
            └── VisualEnvelope      (visual_envelope.hpp L20)
                    │  init(Skin&, Mesh&)
                    │  split(boneCount, splitEnvelopes)
                    │  normaliseBoneWeights()
                    │  VertexXYZNUVIIIWW / VertexXYZNUVIIIWWTB

Hierarchy                          (hierarchy.hpp L9)
    │  封装 MDagPath 节点树
    │  getSkeleton() / getMeshes() / transform()
    └── map<string, Hierarchy*> _children

ExportSettings (单例)              (expsets.hpp L22)
    │  字段最全版本(见十五节)
```

### 4.2 VisualFileTranslator 要点

`VisualFileTranslator`(visualfiletranslator.hpp L16-70)关键成员:

- `visualMeshes` / `hullMeshes` / `bspMeshes` / `visualPortals`:四类导出对象集合
- `meshNames_` / `duplicateMeshNames_`:网格名去重与重名记录
- `nodeParents_`:引用层级 child→parent 映射
- 私有内嵌类 `AutoCleanup`(L51):RAII 在 writer 作用域结束调用 `cleanup()`

---

## 五、writer 导出主流程

`writer`(visualfiletranslator.cpp L1653)是 Maya 调用的导出入口,完整流程如下:

### 5.1 流程步骤

```
writer(file, optionsString, mode)                          [visualfiletranslator.cpp:1653]
│
├─[1] AutoCleanup cleaner + ScopedMELErrorVariableHandler  // RAII
├─[2] 解析 optionsString 顶层 (automatedTest/noPrompt)     // L1664-1688
├─[3] 计算 output/visual/visualsettings/model 文件名       // L1690-1704
├─[4] validResource 校验 visual_filename                   // L1707-1711
├─[5] VisualChecker vc(resNameCamelCase) 获取类型          // L1713-1732
│       设置 exportMode (NORMAL/STATIC/STATIC_WITH_NODES)
├─[6] 读取配置 (backup visual → visualsettings)            // L1737-1740
├─[7] 显示 VisualExporterDialog (非 noPrompt)              // L1742-1747
├─[8] nodeFilter (kExportActiveAccessMode → SELECTED)      // L1749-1754
├─[9] parseOptionsString 覆盖设置                          // L1757
├─[10] BlendShapes blendShapes 初始化                      // L1759
├─[11] OriginTransformer (transformToOrigin 时)            // 原点平移
├─[12] 遍历 DAG,识别 _bsp/_hull/HP_/portal,分类收集        // L1759+
├─[13] 对每个 mesh 调用 exportMesh:                        // L1759+
│        临时文件 → exportTree → save → VisualChecker
│        → rename → generateBSP → 合并 .primitives
├─[14] 导出 BSP (_bsp 节点 / 主 visual)                    // L1281-1377
├─[15] 导出 .model (nodefullVisual/nodelessVisual)         // L2089-2119
└─[16] 导出 .animation (exportAnim 时)                     // L2122+
```

### 5.2 文件名计算

writer 计算多个相关文件名(L1690-1704):

```cpp
//visualfiletranslator.cpp L1691-1701
const BW::string output_filename = BWResource::removeExtension(
    bw_acptoutf8( file.fullName().asChar() ) ).to_string();
const BW::string visual_filename =
    BWResource::removeExtension( output_filename ) + ".visual";
const BW::string visualsettings_filename =
    BWResource::removeExtension( output_filename ) + ".visualsettings";
const BW::string model_filename =
    BWResource::removeExtension( output_filename ) + ".model";
const BW::string model_backupFileName = lookupBackupFilename( model_filename );
```

### 5.3 导出模式选择

根据 `VisualChecker::exportAs()` 自动选择默认导出模式(L1719-1730):

| vc.exportAs() | exportMode |
|---------------|------------|
| `"normal"` | `NORMAL` |
| `"static"` | `STATIC` |
| `"static with nodes"` | `STATIC_WITH_NODES` |

若 `vc.typeName() == UNKNOWN_TYPE_NAME` 则禁用 VisualChecker(L1731-1732)。

---

## 六、exportMesh 单网格导出

`exportMesh`(visualfiletranslator.cpp L906)导出单个网格到 `.visual` + `.primitives`,采用**临时文件 + 校验 + 重命名**策略。

### 6.1 流程

```
exportMesh(fileName)                                       [visualfiletranslator.cpp:906]
│
├─[1] 校验 validResource + isShell 判定                    // L917-923
├─[2] 生成临时文件名 exporter_NNN_temp.visual              // L927-929
├─[3] 校验所有 VisualMesh 引用资源合法性                    // L944-960
├─[4] 构造 DataResource visualFile(临时名, XML)            // 
├─[5] exportTree(pVisualSection, hierarchy, ...)           // L1027 写节点层级
├─[6] 各 VisualMesh->save(pVisualSection, ..., tempPrim)   // L1068 写网格
├─[7] accMesh->save (accumulator 网格)                     // L1169
├─[8] VisualChecker vc(tempFileName) 校验临时文件          // L1242
├─[9] 校验通过 → rename 临时文件为正式名                   // L1265
├─[10] 导出 BSP:                                          // L1281-1377
│        _bsp 节点 → exportTree + save → generateBSP
│        主 visual → generateBSP(resName, visualBspResName)
│        合并 .bsp 到 .primitives
└─[11] 清理临时 .bsp
```

### 6.2 临时文件命名

为支持多次导出不冲突,使用自增计数器生成唯一临时名:

```cpp
//visualfiletranslator.cpp L927-929
static int exportCount = 0;
char buf[256];
bw_snprintf( buf, sizeof(buf), "exporter_%03d_temp.visual", exportCount++ );
BW::string tempFileName = BWResource::getFilePath( fileName ) + buf;
```

### 6.3 exportTree 节点层级写入

`exportTree`(visualfiletranslator.cpp L244)递归将 `Hierarchy` 树序列化为 `.visual` 的 `node` XML 段:

```cpp
//visualfiletranslator.cpp L316
exportTree( pThisSection, hierarchy.child( hierarchy.children()[i] ), ... );
```

---

## 七、OriginTransformer 原点变换

`OriginTransformer`(visualfiletranslator.cpp L122-173)是 writer 内嵌的 RAII 类,实现"导出时平移到原点,导出后还原"。

### 7.1 构造:计算偏移并应用

构造时(L130-152):
1. 取所有根 transform 的 `rotatePivot` 世界坐标平均值作为 `originOffset_`(L130-135)
2. 解锁所有根 transform 的锁定属性(记录到 `lockedPlugs_`)(L141-150)
3. 对每个根 transform 执行 `translateBy(-originOffset_, kWorld)`(L151)

```cpp
//visualfiletranslator.cpp L130-135
for ( uint32 i = 0; i < rootTransforms_.length(); ++i )
{
    MFnTransform rootTransform( rootTransforms_[i] );
    originOffset_ += rootTransform.rotatePivot( MSpace::kWorld ) /
        rootTransforms_.length();
}
```

### 7.2 析构:还原

析构时(L155-168)反向平移 `originOffset_` 并恢复属性锁定状态,保证美术场景不被修改。

### 7.3 触发条件

仅当 `ExportSettings::instance().transformToOrigin()` 为真时构造 `OriginTransformer`,使模型局部原点对齐世界原点,便于运行时摆放。

---

## 八、VisualMesh 与 VisualEnvelope

### 8.1 VisualMesh

`VisualMesh`(visual_mesh.hpp L36)继承 `ReferenceCount`,封装一个 Maya 网格的导出数据:

- 顶点列表(`BloatVertex`,含位置/法线/UV/切线/副法线)
- 三角形列表(`Triangle`,3 索引)
- 材质映射
- `init(Mesh&)`:从 Maya `MMesh` 提取几何
- `save(DataSectionPtr, DataSectionPtr existingVisual, primitiveFile, useIdentifier)`:写 `.visual` 的 renderSet/geometry 段 + `.primitives` 顶点/索引
- `resources()`:收集依赖资源(纹理等)供校验

### 8.2 VisualEnvelope

`VisualEnvelope`(visual_envelope.hpp L20)继承 `VisualMesh`,扩展蒙皮:

- `init(Skin&, Mesh&)`:从 Maya skinCluster 提取骨骼权重
- `split(boneCount, splitEnvelopes)`:按最大骨骼数拆分(委托 `SkinSplitter`)
- `boneNodes_`:骨骼节点名列表
- `boneVertices_`:`BoneVertex` 列表(每顶点 3 骨骼索引 + 3 权重)
- `initialTransforms_`:骨骼初始变换矩阵
- 顶点格式:`VertexXYZNUVIIIWW`(位置/法线/UV/3索引/2权重)与 `VertexXYZNUVIIIWWTB`(加切线/副法线)

### 8.3 顶点格式定义

```cpp
//visual_envelope.hpp L51-75
struct VertexXYZNUVIIIWW
{
    float pos[3];
    uint32 normal;
    float uv[2];
    uint8  index;    // 骨骼1索引 (×3 后存储)
    uint8  index2;   // 骨骼2索引
    uint8  index3;   // 骨骼3索引
    uint8  weight;   // 骨骼1权重 (0..255)
    uint8  weight2;  // 骨骼2权重
};

struct VertexXYZNUVIIIWWTB  // bump mapped 版本,加 tangent/binormal
{
    /* 同上 */
    uint32 tangent;
    uint32 binormal;
};
```

注意 `index` 在 `normaliseBoneWeights` 末尾乘以 3(visual_envelope.hpp L351-353),这是因为运行时骨骼矩阵按 3×4 存储,索引以矩阵行为单位。

---

## 九、蒙皮拆分 SkinSplitter

`VisualEnvelope::split` 委托 `exporter_common::SkinSplitter` 完成按骨骼数拆分。详见 exporter_common 文档,此处简述 Maya 版调用:

```cpp
//visualexporter 中同类调用 (mfxexp.cpp L1776)
if (!spVisualEnvelope->split( settings_.boneCount(), splitEnvelopes ))
{
    errorModels.push_back( spVisualEnvelope->getIdentifier() );
}
```

`SkinSplitter` 构造时为每个三角形建立骨骼关系(`BoneRelationship`),移除被包含的冗余关系;`createList` 贪心合并关系到 `nodeLimit` 上限;`splitTriangles` 将可被当前骨骼集覆盖的三角形移入拆分子集。Maya 版通过 `maxBones` 设置控制单次 draw call 的骨骼上限。

---

## 十、骨骼权重归一化

`VisualEnvelope::normaliseBoneWeights`(visual_envelope.hpp L112-354)将浮点权重转为 `uint8`(0..255),并保证三权重之和精确为 255。

### 10.1 算法步骤

1. **越界骨骼处理**(L127-172):若某骨骼索引超出 `boneNodes_.size()`,置该索引为 0(根骨骼)并归零权重,重新归一化剩余权重
2. **全零兜底**(L178-183):若三骨骼均越界,强制 `weight1=1.0`
3. **余数计算**(L187-192):计算每个权重 `255*w` 的小数余数 `weightNRem`
4. **四舍五入补偿**(L196-349):根据三余数之和(0/1/2/3 四种情况)决定哪些权重进位:
   - 和 < 0.1:全部截断
   - 和 < 1.1:最大余数进位
   - 和 < 2.1:最小余数截断,其余进位
   - 和 < 3.1:全部进位(实为情况1的舍入误差)
5. **断言校验**(L213-217 等):`MF_ASSERT` 验证 `weight + weight2 + weight3 == 255`
6. **索引×3**(L351-353):骨骼索引乘 3,对齐运行时矩阵行存储

### 10.2 设计意义

`uint8` 权重使 GPU 顶点格式紧凑(2 字节存 2 权重,第 3 权重 = 255 - w1 - w2),且保证三权重和恒为 255,避免运行时插值误差累积。

---

## 十一、Portal 与 Hull 导出

### 11.1 Portal 识别与导出

Portal 是 BigWorld chunk 间的可见性通道。Maya 版通过节点命名约定识别:

- `portal` 关键字节点 → `visualPortals` 集合
- `VisualPortal`(visual_portal.hpp)提取多边形顶点,构建凸包边界

`VisualPortal::save`(visualfiletranslator.cpp L678)将 portal 写入 `.visual` 的 boundary 段:

```cpp
//visualfiletranslator.cpp L678
portals[i]->save( boundarySections[b] );
```

### 11.2 portalOnBoundary 校验

`portalOnBoundary`(visualfiletranslator.cpp L614)校验 portal 平面是否落在 chunk 边界平面上,保证 portal 正确连接相邻 chunk。

### 11.3 Hull 导出

Hull 是 shell(chunk 外壳)的边界网格。`HullMesh`(hull_mesh.hpp)导出 `_hull` 命名节点,用于运行时碰撞与遮挡。

### 11.4 checkHierarchy 层级校验

`checkHierarchy`(visualfiletranslator.cpp L739)校验 Maya DAG 层级符合 BigWorld 约定(如 portal 必须挂在正确父级下)。

---

## 十二、BSP 生成

BSP(Binary Space Partitioning)用于运行时碰撞与可见性。Maya 版通过两条路径生成:

### 12.1 _bsp 节点导出

带 `_bsp` 命名的节点导出为独立 BSP 网格(visualfiletranslator.cpp L1281-1306):

```cpp
//visualfiletranslator.cpp L1290-1339 (节选)
BW::string bspBspFileName = BWResource::removeExtension( fileName ) + "_bsp.bsp";
// ... exportTree + accMesh->save ...
generateBSP( bspResName, BWResource::removeExtension( bspResName ) + ".bsp", bspMaterialIDs );
```

### 12.2 主 visual BSP

主 visual 的 BSP 由 `generateBSP(resName, visualBspResName, bspMaterialIDs)` 生成(L1353),随后合并到 `.primitives`:

```cpp
//visualfiletranslator.cpp L1353
generateBSP( resName, visualBspResName, bspMaterialIDs );
// L1372 合并 .bsp 到 .primitives
p->save( primResName );
```

`generateBSP` 实现详见 exporter_common 文档:遍历 renderSet→geometry,加载 vertices/primitive,`populateWorldTriangles` 收集三角形,`BSPTreeTool::buildBSP` 构建树,`saveBSPInFile` 持久化。

---

## 十三、.model 文件导出

`.model` 是 BigWorld 模型描述文件,引用对应的 `.visual`。导出逻辑在 visualfiletranslator.cpp L2089-2119:

```cpp
//visualfiletranslator.cpp L2089-2119
if( ExportSettings::instance().exportMode() != ExportSettings::MESH_PARTICLES &&
    !settings.exportAnim() )
{
    DataResource modelFile( model_backupFileName, RESOURCE_TYPE_XML );
    DataSectionPtr pModelSection = modelFile.getRootSection();
    if (pModelSection)
    {
        MetaData::updateCreationInfo( pModelSection );
        pModelSection->deleteSections( "nodefullVisual" );
        pModelSection->deleteSections( "nodelessVisual" );
        BW::string filename = BWResource::removeExtension( resName ).to_string();
        if (exportMode == NORMAL || exportMode == STATIC_WITH_NODES)
            pModelSection->writeString( "nodefullVisual", filename );
        else if (exportMode == STATIC)
            pModelSection->writeString( "nodelessVisual", filename );
        // 元数据:sourceFile / computer
        pModelSection->writeString( "metaData/sourceFile", MFileIO::currentFile().asChar() );
        pModelSection->writeString( "metaData/computer", computerName );
    }
    modelFile.save( model_filename );
}
```

### 13.1 nodefullVisual vs nodelessVisual

| exportMode | 写入字段 | 含义 |
|------------|----------|------|
| `NORMAL` / `STATIC_WITH_NODES` | `nodefullVisual` | 带骨骼节点,可挂动画 |
| `STATIC` | `nodelessVisual` | 纯静态,无节点 |
| `MESH_PARTICLES` | 不写 .model | 粒子网格专用 |

### 13.2 元数据

记录源 Maya 文件路径与导出机器名,便于追溯(`metaData/sourceFile` / `metaData/computer`)。

---

## 十四、Hierarchy 节点层级

`Hierarchy`(hierarchy.hpp L9-62)封装 Maya `MDagPath` 节点树,是 exportTree 的数据源。

### 14.1 关键成员

- `_name` / `_customPath`:节点名与自定义路径(用于 fixup 节点)
- `_relativeTransform` / `_worldTransform`:手动添加节点的变换
- `_path`:`MDagPath`,Maya DAG 路径
- `_children`:`map<string, Hierarchy*>` 子节点映射
- `parent_`:父节点

### 14.2 关键方法

| 方法 | 作用 |
|------|------|
| `getSkeleton(Skin&)` | 从 skinCluster 提取骨骼层级 |
| `getMeshes(Mesh&)` | 收集网格数据 |
| `addNode(path, dag, accumulatedPath)` | 按 DAG 路径添加节点 |
| `addNode(path, worldTransform)` | 添加 fixup 节点(手动变换) |
| `recursiveFind(name)` | 递归查找节点 |
| `transform(frame, relative)` | 取某帧变换(相对/世界) |
| `count()` | 节点总数(不含根) |

### 14.3 numChildDescending

`numChildDescending`(hierarchy.hpp L64)按子节点数降序排序,与 3ds Max 版 `MFXNode` 排序逻辑一致,使骨骼最多的子树优先。

---

## 十五、ExportSettings 配置项

`ExportSettings`(expsets.hpp L22-207)是 mayavisualexporter 版单例,字段为四个导出器中最全。

### 15.1 导出模式

```cpp
//expsets.hpp L79-86
enum ExportMode
{
    NORMAL = 0,
    STATIC,
    STATIC_WITH_NODES,
    MESH_PARTICLES,
    EXPORTMODE_END
};
```

### 15.2 完整配置项表

| 配置项 | 类型 | 说明 |
|--------|------|------|
| `exportMode_` | ExportMode | 导出模式 |
| `maxBones_` | int | 单 draw call 最大骨骼数(蒙皮拆分阈值) |
| `transformToOrigin_` | bool | 导出时平移到原点 |
| `bumpMapped_` | bool | 生成切线/副法线(bump mapping) |
| `fixCylindrical_` | bool | 修复圆柱体 UV |
| `keepExistingMaterials_` | bool | 保留已有材质 |
| `snapVertices_` | bool | 顶点 snapping(静态模式) |
| `stripRefPrefix_` | bool | 去除引用前缀 |
| `referenceNode_` | bool | 使用引用节点 |
| `disableVisualChecker_` | bool | 禁用 VisualChecker |
| `useLegacyScaling_` | bool | 旧版缩放约定 |
| `useLegacyOrientation_` | bool | 旧版朝向约定 |
| `sceneRootAdded_` | bool | 已添加场景根 |
| `copyExternalTextures_` | bool | 拷贝外部纹理 |
| `copyTexturesTo_` | string | 纹理拷贝目标 |
| `unitScale_` | float | 单位缩放 |
| `localHierarchy_` | bool | 本地层级 |
| `allowScale_` | bool | 允许骨骼缩放 |
| `nodeFilter_` | NodeFilter | ALL/SELECTED/VISIBLE |
| `includeMeshes_` / `includeEnvelopesAndBones_` / `includeNodes_` / `includeMaterials_` / `includeAnimations_` / `includePortals_` | bool | 各类内容包含开关 |
| `useCharacterMode_` | bool | 角色模式 |
| `worldSpaceOrigin_` | bool | 世界空间原点 |
| `resolvePaths_` | bool | 解析路径 |
| `exportAnim_` | bool | 导出动画 |
| `animationName_` | string | 动画名 |
| `referenceNodesFileAbs_` | string | 引用层级文件(绝对路径) |
| `visualTypeIdentifier_` | string | VisualChecker 类型标识 |

### 15.3 NodeFilter 枚举

```cpp
//expsets.hpp L94-100
enum NodeFilter
{
    ALL = 0,
    SELECTED,
    VISIBLE,
    NODEFILTER_END
};
```

---

## 十六、parseOptionsString 选项解析

`parseOptionsString`(visualfiletranslator.cpp L1501-1648)解析 Maya 选项字符串(格式 `key1=value1;key2=value2;...`)并覆盖 `ExportSettings`。

### 16.1 支持的选项(30+)

| 选项键 | 设置方法 | 说明 |
|--------|----------|------|
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
| `useLegacyOrientation` | `useLegacyOrientation` | 旧版朝向 |
| `sceneRootAdded` | `sceneRootAdded` | 场景根 |
| `includeMeshes` | `setExportMeshes` | 包含网格 |
| `includeEnvelopesAndBones` | `setExportEnvelopesAndBones` | 包含蒙皮骨骼 |
| `includeNodes` | `setExportNodes` | 包含节点 |
| `includeMaterials` | `setExportMaterials` | 包含材质 |
| `includeAnimations` | `setExportAnimations` | 包含动画 |
| `useCharacterMode` | `setUseCharacterMode` | 角色模式 |
| `animationName` | `setAnimationName` | 动画名 |
| `includePortals` | `setIncludePortals` | 包含 portal |

### 16.2 解析逻辑

```cpp
//visualfiletranslator.cpp L1501-1514
void parseOptionsString( const MString& optionsString, ExportSettings& settings)
{
    MStringArray optionList;
    optionsString.split(';', optionList);    // 拆分选项
    for( unsigned int i = 0; i < optionList.length(); ++i )
    {
        MStringArray theOption;
        optionList[i].split( '=', theOption );   // 拆分键值
        if( theOption.length() > 1 ) { /* 按键分发 */ }
    }
}
```

布尔值通过 `parseMStringBool` 转换,导出模式通过 `parseMStringExportMode` 转换为 `ExportMode` 枚举。

---

## 十七、VisualChecker 校验机制

### 17.1 校验流程

writer 在导出前后两次使用 `VisualChecker`(visualfiletranslator.cpp L1713 / L1242):

1. **导出前**(L1713):`VisualChecker vc(resNameCamelCase, false, settings.snapVertices())`,根据资源名推断 visual 类型,决定默认 `exportMode`
2. **导出后**(L1242):`VisualChecker vc(tempFileName, false, snapVertices())`,校验临时文件合规性

### 17.2 校验内容

- 资源命名规范(camelCase、路径层级)
- 顶点 snapping 一致性
- `typeName()`:返回 visual 类型标识(写入 `visualTypeIdentifier_`)
- `exportAs()`:返回建议导出方式("normal"/"static"/"static with nodes")
- `errorText()`:返回错误信息(加入 `melErrorMessages`)

### 17.3 禁用条件

当 `vc.typeName() == UNKNOWN_TYPE_NAME` 时,设置 `disableVisualChecker(true)`(L1731-1732),跳过该校验。

---

## 十八、与其他模块的依赖关系

### 18.1 依赖图

```
mayavisualexporter
    │
    ├──► cstdmf          (BinaryFile, SmartPointer, ReferenceCount, StringHashMap, guard, log_msg)
    ├──► resmgr          (BWResource, XMLSection, DataSection, DataResource, AutoConfig, MultiFileSystem, NativeFileSystem)
    ├──► math            (matrix4, vector3, boundbox)
    ├──► moo             (VertexFormats, Node, Primitive, Vertices, PrimitiveHelper)
    ├──► exporter_common (generateBSP, SkinSplitter, DataSectionCachePurger)
    ├──► physics2        (BSPTreeTool, WorldTriangle — 经 exporter_common 间接)
    └── Maya SDK         (MPxFileTranslator, MFnPlugin, MDagPath, MFnTransform, MPlug,
                          MObject, MStatus, MFileObject, MString, MMesh, MSkinCluster,
                          MFileIO, MDistance 等)
```

### 18.2 与 DCC SDK 集成要点

- **插件注册**:`MFnPlugin::registerFileTranslator` 注册文件翻译器,`creator` 工厂方法返回 `new VisualFileTranslator`
- **DAG 遍历**:通过 `MDagPath` 与 `ExportIterator`(exportiterator.h)遍历场景
- **skinCluster 访问**:`Skin`(skin.hpp)封装 Maya skinCluster,提取权重与影响骨骼
- **属性锁定处理**:`OriginTransformer` 解锁/恢复 `MPlug` 锁定状态,避免修改失败
- **错误变量**:`ScopedMELErrorVariableHandler` 管理 `melErrorMessages` 作用域

### 18.3 与 exporter_common 的关系

- `generateBSP`:BSP 生成完全委托 exporter_common
- `SkinSplitter`:蒙皮拆分共用 exporter_common 的模板化实现
- `DataSectionCachePurger`:RAII 清理(虽 writer 未显式使用,但 exporter_common 链接入工程)

### 18.4 与 visualexporter 的对应关系

| 维度 | mayavisualexporter | visualexporter |
|------|--------------------|----------------|
| DCC | Maya | 3ds Max |
| 入口 | `MPxFileTranslator::writer` | `SceneExport::DoExport` |
| 主类 | `VisualFileTranslator` | `MFXExport` |
| 节点树 | `Hierarchy` | `MFXNode` |
| 网格 | `VisualMesh`(ReferenceCount) | `VisualMesh` |
| 蒙皮 | `VisualEnvelope` + `Skin` + `SkinSplitter` | `VisualEnvelope` + `SkinSplitter` |
| 导出模式 | 4 种(含 MESH_PARTICLES) | 3 种 |
| 配置 | `exporter.xml` + optionsString | `.cfg` + `.visualsettings` + MaxScript |

---

## 十九、关键代码片段

### 19.1 writer 顶层选项解析

```cpp
//visualfiletranslator.cpp L1664-1688
if (optionsString.length() > 0)
{
    MStringArray optionList;
    MStringArray theOption;
    optionsString.split(';', optionList);
    for( unsigned int i = 0; i < optionList.length(); ++i )
    {
        theOption.clear();
        optionList[i].split( '=', theOption );
        if( theOption.length() > 1 )
        {
            if ( theOption[0] == "automatedTest" )
                automatedTest = ( theOption[1].asInt() != 0 );
            if ( theOption[0] == "noPrompt" )
                noPrompt = ( theOption[1].asInt() != 0 );
        }
    }
}
```

### 19.2 配置继承(backup visual)

writer 优先从已有 `.visual`(backup)读取配置,失败再读 `.visualsettings`:

```cpp
//visualfiletranslator.cpp L1737-1740
if (!settings.readSettings( lookupBackupFilename( visual_filename ), false ))
{
    settings.readSettings( visualsettings_filename );
}
```

### 19.3 OriginTransformer 原点平移

```cpp
//visualfiletranslator.cpp L138-151
for ( uint32 i = 0; i < rootTransforms_.length(); ++i )
{
    MFnTransform rootTransform( rootTransforms_[i] );
    for ( uint32 j = 0; j < rootTransform.attributeCount(); ++j)
    {
        MFnAttribute attribute( rootTransform.attribute( j ) );
        MPlug plug( rootTransform.object(), attribute.object() );
        if (plug.isLocked())
        {
            plug.setLocked( false );
            lockedPlugs_.append( plug );
        }
    }
    rootTransform.translateBy( -originOffset_, MSpace::kWorld );
}
```

### 19.4 .model 导出

```cpp
//visualfiletranslator.cpp L2100-2107
pModelSection->deleteSections( "nodefullVisual" );
pModelSection->deleteSections( "nodelessVisual" );
BW::string filename = BWResource::removeExtension( resName ).to_string();
if (exportMode == NORMAL || exportMode == STATIC_WITH_NODES)
    pModelSection->writeString( "nodefullVisual", filename );
else if (exportMode == STATIC)
    pModelSection->writeString( "nodelessVisual", filename );
```

### 19.5 checkAnyRowHasZeroScale

`checkAnyRowHasZeroScale`(visualfiletranslator.cpp L225)检测变换矩阵是否存在零缩放行,避免产生退化几何。

### 19.6 getBoneCounts 骨骼统计

`getBoneCounts`(visualfiletranslator.cpp L876)统计每个骨骼影响顶点数,返回 `BoneCountMap`(string→count)。用于导出前评估蒙皮复杂度,辅助决定 `maxBones` 拆分阈值:

```cpp
//visualfiletranslator.hpp L19-20
typedef BW::map<BW::string, size_t> BoneCountMap;
typedef BoneCountMap::iterator      BoneCountMapIt;
```

### 19.7 AutoCleanup RAII

`AutoCleanup`(visualfiletranslator.hpp L51)是 writer 内嵌的私有 RAII 类,构造时绑定 `VisualFileTranslator` 引用,析构时调用 `cleanup()`(L2354)清空本次导出的临时状态(`visualMeshes`/`hullMeshes`/`bspMeshes`/`visualPortals`/`meshNames_` 等):

```cpp
//visualfiletranslator.cpp L1655
AutoCleanup cleaner(*this);
```

保证即使 writer 中途 return 也能释放资源,避免跨导出状态污染。

### 19.8 BlendShapes 表情动画

`BlendShapes`(visualfiletranslator.cpp L1759)在 writer 中初始化,处理 Maya blendShape deformer,导出表情变形目标。blendShape 目标作为 morph target 写入 `.visual`,运行时按权重插值顶点位置。

### 19.9 lookupBackupFilename 备份查找

`lookupBackupFilename`(visualfiletranslator.cpp L2440)查找已存在的备份文件名,用于配置继承——读取 backup visual 的设置作为默认,实现"重新导出保留上次配置"。

---

## 二十、设计亮点与注意事项

### 20.1 设计亮点

1. **临时文件 + 校验 + 重命名**:exportMesh 先写 `exporter_NNN_temp.visual`,经 VisualChecker 校验通过才 rename,保证导出失败不破坏正式资源,支持原子性更新。

2. **OriginTransformer 可逆原点变换**:RAII 对象构造时平移根节点、析构时还原,并处理属性锁定,使"导出到原点"不污染美术场景,这是 Maya 版相对 3ds Max 版的独有能力。

3. **backup visual 配置继承**:`lookupBackupFilename` + `readSettings(backup, false)` 实现重新导出时自动沿用上次配置,减少美术重复设置。

4. **权重归一化的余数补偿**:`normaliseBoneWeights` 精确处理 255 量化余数,保证三权重和恒为 255,避免 GPU 插值误差,是 BigWorld 蒙皮稳健性的关键。

5. **骨骼索引×3 存储**:运行时骨骼矩阵按 3×4 行主序存储,索引乘 3 直接定位行,减少 GPU 寻址计算。

6. **多导出模式 + nodefull/nodeless**:`NORMAL`/`STATIC`/`STATIC_WITH_NODES`/`MESH_PARTICLES` 四模式覆盖角色、静态物、粒子等场景,`.model` 据此选择 `nodefullVisual` 或 `nodelessVisual`。

7. **MELError 作用域守卫**:`ScopedMELErrorVariableHandler` 隔离每次导出的 Maya 错误变量,避免跨导出污染。

### 20.2 注意事项

1. **必须从 bigworld/tools/exporter 运行**:`initializePlugin` 校验运行目录(L85-92),禁止从 Maya 插件目录加载,否则资源路径解析失败。

2. **resources.xml 依赖**:`AutoConfig::configureAllFrom("resources.xml")` 失败则插件加载失败(L110-115),需保证 `paths.xml` 正确配置。

3. **optionsString 优先级**:`parseOptionsString` 在对话框之后调用(L1757),会覆盖美术在 UI 中的设置,自动化批处理时需注意。

4. **transformToOrigin 与动画冲突**:原点变换会平移所有根节点,若同时导出动画,动画通道会包含该平移。通常动画导出应关闭 `transformToOrigin`,或单独导出。

5. **maxBones 与硬件限制**:`maxBones` 决定蒙皮拆分粒度,值过小导致拆分过多 draw call,过大超出 GPU 常量寄存器上限。需根据目标硬件平衡。

6. **VisualChecker 命名规范**:资源名必须符合 camelCase 与路径层级约定,否则 `validResource` 失败。`UNKNOWN_TYPE_NAME` 会自动禁用校验,但可能掩盖问题。

7. **临时文件计数器**:`exportCount` 为静态变量,跨多次导出递增,仅用于生成唯一名,不重置。

8. **bumpMapped 与切线空间**:`bumpMapped` 开启时生成 `VertexXYZNUVIIIWWTB`(含 tangent/binormal),顶点格式变大,需确保 shader 配套。

9. **MESH_PARTICLES 不导出 .model**:粒子网格模式跳过 `.model` 写入(L2090),因粒子网格由粒子系统直接引用,无需模型描述。

10. **stripRefPrefix 与引用层级**:去除引用前缀可能影响 `referenceNodesFile` 匹配,需保证引用层级文件中的节点名与 strip 后一致。

11. **exporter.xml 默认配置**:插件目录下 `exporter.xml` 是 `ExportSettings` 的默认配置源,在 `initializePlugin` 中加载(visualmain.cpp L117-118)。修改此文件可调整所有导出的默认行为,但单个资源配置优先级更高。

12. **kExportActiveAccessMode 与 SELECTED**:Maya 的 `kExportActiveAccessMode`(导出选中)映射为 `nodeFilter=SELECTED`(L1750-1753),仅导出选中对象;其他模式用 `ALL`,因 Maya 的可见性过滤由节点本身属性决定。

13. **AutoCleanup 与单例清理**:Maya 插件常驻导致 `ExportSettings` 单例跨导出保留,`AutoCleanup` 清理容器状态但不清单例,因此 `parseOptionsString` 每次显式覆盖关键字段,避免上次设置残留。

14. **model_backupFileName 配置继承**:`.model` 文件先以 backup 名打开(L2094),读取已有 `nodefullVisual`/`nodelessVisual` 后删除并重写,保证 `.model` 的其他字段(如 dyes、tints)不丢失。

---

> **参考文件路径**:
> - `programming/bigworld/tools/mayavisualexporter/visualmain.cpp`
> - `programming/bigworld/tools/mayavisualexporter/visualfiletranslator.hpp` / `.cpp`
> - `programming/bigworld/tools/mayavisualexporter/expsets.hpp`
> - `programming/bigworld/tools/mayavisualexporter/visual_mesh.hpp`
> - `programming/bigworld/tools/mayavisualexporter/visual_envelope.hpp`
> - `programming/bigworld/tools/mayavisualexporter/hierarchy.hpp`
> - `programming/bigworld/tools/mayavisualexporter/exporter.xml`
