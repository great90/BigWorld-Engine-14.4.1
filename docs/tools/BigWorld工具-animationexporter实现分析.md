# BigWorld Engine animationexporter(3ds Max 动画导出器)实现深度分析

> 本文档详细分析 BigWorld Engine 14.4.1 中 `tools/animationexporter/` 模块的完整实现。该模块以 3ds Max 插件(DLL)形式存在,负责将 3ds Max 场景中的骨骼层级与关键帧动画导出为 BigWorld 运行时使用的 `.animation` 二进制文件。本文涵盖插件入口、节点预处理、动画通道采样、MFX 二进制格式、骨骼最近距离分配算法、Cue 轨道、引用层级重组等核心机制。

---

## 目录

- [一、整体架构概览](#一整体架构概览)
- [二、源码目录结构](#二源码目录结构)
- [三、插件入口与启动流程](#三插件入口与启动流程)
- [四、核心类与继承关系](#四核心类与继承关系)
- [五、DoExport 导出主流程](#五doexport-导出主流程)
- [六、节点预处理 preProcess](#六节点预处理-preprocess)
- [七、MFXNode 动画节点树](#七mfxnode-动画节点树)
- [八、MFX 二进制格式与 ChunkID](#八mfx-二进制格式与-chunkid)
- [九、动画通道采样与压缩](#九动画通道采样与压缩)
- [十、骨骼最近距离分配算法](#十骨骼最近距离分配算法)
- [十一、Cue 事件轨道](#十一cue-事件轨道)
- [十二、引用层级重组](#十二引用层级重组)
- [十三、ExportSettings 配置项](#十三exportsettings-配置项)
- [十四、MaxScript 集成](#十四maxscript-集成)
- [十五、与其他模块的依赖关系](#十五与其他模块的依赖关系)
- [十六、关键代码片段](#十六关键代码片段)
- [十七、设计亮点与注意事项](#十七设计亮点与注意事项)

---

## 一、整体架构概览

### 1.1 模块定位

`animationexporter` 是 BigWorld DCC 工具链中的**动画导出器**,以 3ds Max 场景导出插件(`SceneExport`)形式注册到 3ds Max。它的核心职责是:

1. 遍历 3ds Max 场景节点树,构建内部 `MFXNode` 层级镜像
2. 识别蒙皮节点(`Physique` / `Skin` 修改器),收集到 `envelopeNodes_`
3. 按帧采样每个被包含节点的相对变换矩阵,分解为 Scale/Position/Rotation 三路关键帧
4. 写入 `.animation` 二进制文件(可选附带 Cue 事件轨道)
5. 支持通过引用层级文件(`.visual`)重组节点父子关系,保证动画与可视化模型骨骼一致

### 1.2 导出管线数据流

```
┌──────────────┐    DllMain/ClassDesc     ┌─────────────────────┐
│  3ds Max     │ ───────────────────────▶ │  MFXExport 插件     │
│  宿主进程    │  LibClassDesc(0)         │  (SceneExport 派生) │
└──────────────┘                          └──────────┬──────────┘
                                                     │ DoExport
                                                     ▼
        ┌────────────────────────────────────────────────────────┐
        │ 1. 路径校验 (BWResource::dissolveFilename)             │
        │ 2. 读取配置 (.cfg / .animationsettings / pSettingsOverride)│
        │ 3. preProcess(根节点) → 构建 MFXNode 树 + 节点分类      │
        │ 4. exportMeshes + exportEnvelopes (收集静态/蒙皮网格)    │
        │ 5. loadReferenceNodes → 引用层级重组                    │
        │ 6. 根子节点排序 (numChildDescending)                   │
        │ 7. mungeIncluded → 祖先 include 传递                   │
        │ 8. validateAnimationIDs (重名检测)                     │
        │ 9. mfxRoot_->exportAnimation → BinaryFile 写入         │
        │10. CueTrack::writeFile (可选)                          │
        └────────────────────────────────────────────────────────┘
                                                     │
                                                     ▼
                                          ┌─────────────────────┐
                                          │  *.animation        │
                                          │  (BinaryFile 二进制) │
                                          └─────────────────────┘
```

### 1.3 关键设计原则

| 原则 | 说明 |
|------|------|
| **单例配置** | `ExportSettings` 为进程级单例,通过 `instance()` 访问,配置来源分三层(cfg / settings / MaxScript override) |
| **节点镜像** | `MFXNode` 树是 3ds Max `INode` 树的精简镜像,只保留动画所需信息(identifier / transform / include 标记) |
| **RAII 资源清理** | `DoExport` 入口构造 `DataSectionCachePurger`,作用域结束自动清空 DataSection 缓存,避免插件常驻导致缓存膨胀 |
| **Debug/Release 隔离** | ClassID 与 MaxScript 支持按 `BW_EXPORTER_DEBUG` 宏区分,Debug 版不链接 MaxScript 库 |
| **坐标系转换** | 3ds Max 使用 Z-up 右手系,BigWorld 使用 Y-up,通过 `rearrangeMatrix` / `writeMFXPoint` 的 Y/Z 交换完成 |

---

## 二、源码目录结构

`animationexporter` 模块位于 `programming/bigworld/tools/animationexporter/`,文件组织如下:

| 文件 | 行数级别 | 职责 |
|------|----------|------|
| `expmain.cpp` | ~200 | DLL 入口 `DllMain`、3ds Max 库接口(`LibDescription` 等)、`MFXExpClassDesc` 类描述符 |
| `mfxexp.hpp` / `mfxexp.cpp` | ~870 | 核心导出类 `MFXExport`(继承 `SceneExport`)、`DoExport` 主流程、`preProcess`、`validateAnimationIDs` |
| `mfxnode.hpp` / `mfxnode.cpp` / `mfxnode.ipp` | ~360 | 动画节点树 `MFXNode`、`CompressionInfo`、`exportTree` / `exportAnimation` |
| `mfxfile.hpp` / `mfxfile.cpp` / `mfxfile.ipp` | 中 | MFX 二进制文件读写封装 |
| `expsets.hpp` / `expsets.cpp` / `expsetsio.cpp` | ~200/300 | `ExportSettings` 单例配置(读写 XML、对话框) |
| `visual_mesh.hpp` / `visual_mesh.cpp` / `visual_mesh.ipp` | 大 | 静态网格导出(本模块中用于收集,不写主输出) |
| `visual_envelope.hpp` / `visual_envelope.cpp` / `visual_envelope.ipp` | 大 | 蒙皮网格(Envelope)导出 |
| `cuetrack.hpp` / `cuetrack.cpp` | 中 | 事件 Cue 轨道(单例) |
| `vertcont.hpp` / `vertcont.cpp` / `vertcont.ipp` | 中 | 顶点容器(去重) |
| `polycont.hpp` / `polycont.cpp` / `polycont.ipp` | 中 | 多边形容器 |
| `chunkids.hpp` | ~63 | MFX 二进制 chunk ID 常量定义 |
| `export.cpp` | ~900+ | 旧版导出实现(`MFExp` 类),含 `writeMFXPoint`、`getDistanceToBone`、`mfxAnimationNodeEnum` |
| `utility.hpp` / `utility.cpp` | 中 | 工具函数(`rearrangeMatrix`、`normaliseMatrix`、`isMirrored` 等) |
| `aboutbox.hpp` / `aboutbox.cpp` | 小 | About 对话框 |
| `animout.cpp` | 中 | 动画输出辅助 |
| `pch.hpp` / `pch.cpp` | 小 | 预编译头 |

---

## 三、插件入口与启动流程

### 3.1 DllMain 入口

3ds Max 通过加载 DLL 并调用约定的导出函数来识别插件。`expmain.cpp` 的 `DllMain`(L25)完成一次性初始化:

- 记录 `hInstance`
- 初始化自定义控件(`InitCustomControls` / `InitCommonControls`)
- 从 DLL 路径推算 `toolsPath`,校验**必须从 `bigworld/tools/exporter/` 运行**而非 3ds Max 插件目录(L72);若误放则弹窗报错并返回 `FALSE`
- 调用 `BWResource::init` 初始化资源管理器(L99),检查全局 `g_exporterErrorMsg`
- 设置 `XMLSection::shouldWriteXMLAttributes(false)`,保持与旧版 BW 的 XML 兼容性(L117)

### 3.2 3ds Max 插件接口

3ds Max 要求 DLL 导出 4 个标准函数,见 `expmain.cpp` L125-158:

| 函数 | 行号 | 作用 |
|------|------|------|
| `LibDescription` | L125 | 返回库描述字符串(从字符串表 `IDS_BWAE_LIBDESCRIPTION`) |
| `LibNumberClasses` | L133 | 返回类数量(固定为 1) |
| `LibClassDesc` | L141 | 按索引返回 `ClassDesc*`,索引 0 返回 `GetMFXExpDesc()` |
| `LibVersion` | L155 | 返回 `VERSION_3DSMAX`,声明编译所用的 Max SDK 版本 |

### 3.3 类描述符 MFXExpClassDesc

`expmain.cpp` L165-173 定义 `MFXExpClassDesc`(继承 `ClassDesc`),3ds Max 据此实例化导出器:

- `IsPublic()` 返回 1(公开插件)
- `Create()` 返回 `new MFXExport`(L168)
- `SuperClassID()` 返回 `SCENE_EXPORT_CLASS_ID`(场景导出器类别)
- `ClassID()` 返回 `MFEXP_CLASS_ID`
- 静态实例 `MFXExpDesc`(L178)由 `GetMFXExpDesc()`(L183)返回

### 3.4 ClassID(Debug/Release 区分)

`mfxexp.hpp` L40-44 定义 ClassID,Debug 与 Release 使用不同 ID 以便同时加载两个版本进行调试:

```cpp
//mfxexp.hpp L40-44
#if defined BW_EXPORTER_DEBUG
#define MFEXP_CLASS_ID	Class_ID(0x23472c6, 0x552c1156)
#else
#define MFEXP_CLASS_ID	Class_ID(0x25810e56, 0x61a93faa)
#endif
```

配置文件名固定为 `"animationexporter.cfg"`(L47)。

---

## 四、核心类与继承关系

### 4.1 类继承图

```
SceneExport (3ds Max SDK)
    │
    └── MFXExport            (mfxexp.hpp L149)
            │  Ext(0) → "animation"
            │  DoExport() 主流程
            │
            ├── 持有 MFXNode* mfxRoot_      (动画节点树根)
            ├── 持有 MFXFile mfx_           (二进制文件封装)
            ├── 持有 MaterialList materials_
            ├── 持有 INodeVector {portalNodes_, envelopeNodes_, meshNodes_, touchedNodes_}
            ├── 持有 vector<VisualMeshPtr> visualMeshes_
            └── 持有 vector<VisualEnvelopePtr> visualEnvelopes_

MFXNode (mfxnode.hpp L27)  ── 镜像 INode 层级
    │  identifier_ / transform_ / include_ / contentFlag_
    │  exportTree()       → 写 visual 节点层级 XML
    │  exportAnimation()  → 写 .animation 二进制通道
    │
    └── 持有 vector<MFXNode*> children_

ExportSettings (expsets.hpp L17) ── 单例 (instance())
    │  allowScale_ / exportNodeAnimation_ / exportCueTrack_
    │  useLegacyOrientation_ / nodeFilter_ / referenceNodesFile_
    │  frameFirst_ / frameLast_ / staticFrame_

CueTrack (cuetrack.hpp) ── 单例
    │  addCue() / hasCues() / writeFile() / clear()
```

### 4.2 MFXExport 类要点

`MFXExport`(mfxexp.hpp L149-226)是导出主控类,关键成员:

- `ip_`:3ds Max `Interface*`,用于访问场景
- `mfxRoot_`:动画节点树根(对应场景根节点)
- `nodeParents_`:`StringHashMap<BW::string>`,记录引用层级中 child→parent 映射,用于层级重组
- `mfxEnvelopeNodes_`:参与动画的蒙皮骨骼节点
- 静态工具方法:`findPhysiqueModifier` / `findSkinMod` / `findMorphModifier` / `getTriObject`

辅助结构 `Bone` / `BoneList`(L83-140)用于旧版骨骼-顶点索引映射;`MultiSubMaterial`(L142-147)记录多维子材质的子材质名。

---

## 五、DoExport 导出主流程

`DoExport`(mfxexp.cpp L236)是 3ds Max 调用的导出入口,完整流程如下:

### 5.1 流程步骤

```
DoExport(nameFromMax, ei, i, suppressPrompts, options)   [mfxexp.cpp:236]
│
├─[1] DataSectionCachePurger dscp;                         // RAII 清理缓存
├─[2] 文件名归一化 → 强制 .animation 扩展名                 // L242-248
├─[3] 路径校验 BWResolver::dissolveFilename                // L260-286
│       不在 game path 则报错返回 0
├─[4] 设置帧范围 / 读取配置                                 // L288-298
│       ExportSettings.readSettings(cfgFilename)
│       ExportSettings.readSettings(settingsFilename)
│       ExportSettings.readSettings(pSettingsOverride)    // MaxScript 覆盖
├─[5] 显示设置对话框(非 suppressPrompts 时)                 // L300-311
├─[6] 设置 nodeFilter (SCENE_EXPORT_SELECTED → SELECTED)   // L314-321
├─[7] 清理旧 CueTrack (exportCueTrack 时)                  // L326-327
├─[8] preProcess(ip_->GetRootNode())                       // L329 构建 MFXNode 树
├─[9] exportMeshes() + exportEnvelopes()                   // L331-332
├─[10] loadReferenceNodes (若设置了 referenceNodesFile)     // L334-367 引用层级重组
├─[11] 根子节点排序 (numChildDescending)                    // L369-388
├─[12] mungeIncluded(mfxRoot_)                             // L390 祖先 include 传递
├─[13] validateAnimationIDs(errorMsg)                      // L393-409 重名检测
├─[14] 计算通道数 nChannels                                 // L424-429
│        = nIncludedNodes (exportNodeAnimation) + (CueTrack?1:0)
├─[15] 读取旧文件压缩参数 CompressionInfo                   // L433-469
├─[16] BinaryFile 写入 .animation                          // L472-492
│        header: float(帧数) + animName + animName + nChannels
│        mfxRoot_->exportAnimation(animation, ci)
│        CueTrack::writeFile(animation) (可选)
└─[17] 写 .animationsettings                               // L499
```

### 5.2 文件名处理

3ds Max 传入的 `nameFromMax` 带原始扩展名,导出器强制改写为 `.animation`:

```cpp
//mfxexp.cpp L248
filename = filename.substr(0, filename.size() - 10) + ".animation";
```

### 5.3 通道数计算

只有当 `exportNodeAnimation` 为真且树中存在被包含节点时才写节点通道;Cue 轨道单独占用 1 个通道:

```cpp
//mfxexp.cpp L424-429
int nChannels = 0;
if (mfxRoot_ && ExportSettings::instance().exportNodeAnimation() )
    nChannels += mfxRoot_->nIncludedNodes();
if( ExportSettings::instance().exportCueTrack() && CueTrack::hasCues() )
    nChannels += 1;
```

---

## 六、节点预处理 preProcess

`preProcess`(mfxexp.cpp L540)递归遍历 3ds Max 节点树,完成节点分类与 `MFXNode` 镜像构建。

### 6.1 节点过滤逻辑

根据 `nodeFilter` 决定是否包含节点(L546-559):

| nodeFilter | 包含条件 |
|------------|----------|
| `ALL` | 全部包含(或根节点 `mfxParent==NULL`) |
| `SELECTED` | `node->Selected()` 为真 |
| `VISIBLE` | `!node->IsHidden()` |

随后排除特定对象类型(L565-580):
- `TARGET_CLASS_ID`(目标对象)
- 粒子视图对象 `Class_ID(0x74f93b07, 0x1eb34300)`
- `CAMERA_CLASS_ID` / `LIGHT_CLASS_ID` / `SHAPE_CLASS_ID`

### 6.2 节点分类

通过修改器探测将节点分为三类(L583-597):

```cpp
//mfxexp.cpp L585-596
Modifier *mod = findPhysiqueModifier( node );
Modifier *mod2 = findSkinMod( node );
if( mod || mod2 )
{
    envelopeNodes_.push_back( node );   // 蒙皮节点
    includeNode = false;
}
else
{
    meshNodes_.push_back( node );       // 普通网格节点
}
```

### 6.3 MFXNode 树构建

为每个访问节点创建 `MFXNode`,设置 `include` 标记并挂到父节点下;根节点赋给 `mfxRoot_`(L599-609):

```cpp
//mfxexp.cpp L601-606
thisNode = new MFXNode( node );
thisNode->include( includeNode );
if (mfxParent)
    mfxParent->addChild( thisNode );
else
    mfxRoot_ = thisNode;
```

---

## 七、MFXNode 动画节点树

`MFXNode`(mfxnode.hpp L27-96)是动画层级的核心数据结构。

### 7.1 CompressionInfo 压缩容差

`mfxnode.hpp` L19-25 定义压缩误差容差结构:

```cpp
//mfxnode.hpp L19-25
struct CompressionInfo
{
    bool specifyAmounts_;
    float scaleCompressionError_;
    float positionCompressionError_;
    float rotationCompressionError_;
};
```

`specifyAmounts_` 为真时,通道头写入类型 4 并附带三个误差容差(供运行时压缩使用);否则写类型 1。

### 7.2 变换矩阵获取

`getTransform`(mfxnode.cpp L64)按优先级返回世界变换:
1. 若有 `node_`(Max 节点),返回 `node_->GetNodeTM(t)`(可选 `normaliseMatrix`)
2. 否则若有 `parent_`,返回 `parent_->getTransform(t) * transform_`
3. 否则返回 `transform_`

`getRelativeTransform`(mfxnode.cpp L101)计算相对父节点(或理想父节点 `idealParent`)的变换:

```cpp
//mfxnode.cpp L114-115
return getTransform( t, normalise ) *
       Inverse( idealParent->getTransform( t, normalise ) );
```

`idealParent` 参数用于引用层级重组场景,允许节点按引用文件的父级计算相对变换。

### 7.3 includeAncestors 祖先传递

`includeAncestors`(mfxnode.cpp L91)沿父链向上将所有祖先标记为 include,保证动画层级完整:

```cpp
//mfxnode.cpp L91-99
void MFXNode::includeAncestors()
{
    MFXNode* parent = parent_;
    while (parent)
    {
        parent->include(true);
        parent = parent->getParent();
    }
}
```

`mungeIncluded`(mfxexp.cpp L218)对整树递归调用此逻辑,确保任何被包含节点的祖先也被包含。

---

## 八、MFX 二进制格式与 ChunkID

### 8.1 ChunkID 定义

`chunkids.hpp` 定义 MFX(Micro Forte eXchange)二进制格式的 chunk 标识,均用 FourCC 字面量:

```cpp
//chunkids.hpp L16-47
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

### 8.2 固定尺寸常量

| 常量 | 值 | 说明 |
|------|----|------|
| `MFX_FLOAT_SIZE` | 4 | 单浮点字节 |
| `MFX_INT_SIZE` | 4 | 整数字节 |
| `MFX_POINT_SIZE` | 12 | 三维点 |
| `MFX_MATRIX_SIZE` | 48 | 4×3 矩阵 |
| `MFX_UV_SIZE` | 8 | UV 坐标 |
| `MFX_COLOUR_SIZE` | 12 | RGB 颜色 |
| `MFX_TRIANGLE_SIZE` | 12 | 三角形(3 索引) |
| `MFX_BONEVERTEX_SIZE` | 16 | 骨骼顶点(点+索引) |
| `MFX_TRIANGLE2_SIZE` | 16 | 三角形2(3 索引+材质) |

### 8.3 坐标系转换 writeMFXPoint

`export.cpp` L20-25 的 `writeMFXPoint` 实现 3ds Max(Z-up)到 BigWorld(Y-up)的 Y/Z 交换:

```cpp
//export.cpp L20-25
void writeMFXPoint( Point3 &p, FILE *stream )
{
    fwrite( &p.x, 4, 1, stream );
    fwrite( &p.z, 4, 1, stream );   // Z 写到第二位
    fwrite( &p.y, 4, 1, stream );   // Y 写到第三位
}
```

`writeMFXMatrix`(L33-43)对矩阵四行同样做行 1/2 交换,保证整个变换在 Y-up 系下正确。`writeMFXChunkHeader`(L45-50)写入 12 字节 chunk 头(identifier + totalSize + size)。

### 8.4 .animation 文件结构

新版的 `.animation` 不再使用 chunk 格式,而是通过 `BinaryFile` 顺序写入:

```
┌─────────────────────────────────────────────┐
│ float        : 帧数 (lastFrame - firstFrame) │
│ string       : animName                       │
│ string       : animName (重复,标识符)         │
│ int          : nChannels (通道总数)           │
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
│ [若 exportCueTrack] CueTrack 数据             │
└─────────────────────────────────────────────┘
```

---

## 九、动画通道采样与压缩

### 9.1 exportAnimation 主循环

`MFXNode::exportAnimation`(mfxnode.cpp L192-287)是动画写入的核心。对每个被包含节点:

1. 校验节点名无前后空白(L207-217),非法名弹窗警告
2. 遍历 `firstFrame..lastFrame`,逐帧采样相对变换:
   - `getRelativeTransform(i * GetTicksPerFrame(), normalise, idealParent)`(L230)
   - `rearrangeMatrix` 完成 Y/Z 转换(L231)
   - 构造 `Matrix` 并用 `BlendTransform` 分解为 Scale/Position/Rotation(L238)
   - `bt.normaliseRotation()` 归一化旋转四元数(L241)
3. 平移乘以 `unitScale`(L254),统一单位
4. 写入通道头(类型 1 或 4)(L261-273)
5. 写入三路关键帧序列与三份 `boundTable`(L275-280)
6. 递归子节点,传递 `nextParent`(L283-286)

### 9.2 关键帧类型

```cpp
//mfxnode.cpp L196-198
typedef std::pair<float, Vector3> ScaleKey;
typedef std::pair<float, Vector3> PositionKey;
typedef std::pair<float, Quaternion> RotationKey;
```

`boundTable` 记录每帧在压缩后的绑定索引,初始为 `i - firstFrame + 1`(L252),供运行时关键帧压缩算法使用。

### 9.3 normalise 与 allowScale

`normalise` 标志由 `!ExportSettings::instance().allowScale()` 决定(L222)。当禁止缩放时,对变换矩阵做正交化(`normaliseMatrix`),消除缩放分量,保证骨骼层级纯刚体。

### 9.4 旧版 mfxAnimationNodeEnum

`export.cpp` 的 `MFExp::mfxAnimationNodeEnum`(L879)是旧版 chunk 格式的动画通道写入,逐帧写入 `CHUNKID_KEYFRAMEMATRIX34`(4×3 矩阵):

```cpp
//export.cpp L887-898
int size = CHUNK_HEADER_SIZE;
size += getMFXStrLen( name );
size += 4;
writeMFXChunkHeader( CHUNKID_ANIMATIONCHANNEL, size, size, pStream );
fwrite( &time, 4, 1, pStream );
writeMFXStr( name, pStream );
size = 4 * 3 *4; //sizeof matrix34
size += 4; // size of int
size *= time;
```

新版 `exportAnimation` 取代了该实现,但 `export.cpp` 仍保留作为历史代码与 `getDistanceToBone` 等算法载体。

---

## 十、骨骼最近距离分配算法

`MFExp::getDistanceToBone`(export.cpp L759-850)是旧版蒙皮分配中的几何算法,计算空间一点到骨骼(由三角形面集表示)的最近距离。

### 10.1 算法思路

骨骼被离散为一组三角形面(`BoneFace`,含三条边的法线/距离与平面方程)。对查询点 `p`:

1. 初始距离取到第一个面的第一个顶点(L761)
2. 遍历每个三角形面,先判断点是否在三角形三条边的内侧(L766):
   ```
   DotProd(l1N, p) < l1D && DotProd(l2N, p) < l2D && DotProd(l3N, p) < l3D
   ```
   - 若在内侧,点投影落在三角形内部,取到平面距离 `|DotProd(p, peqN) - peqD|`(L768)
3. 否则,对三角形三条边分别计算点到线段的距离:
   - 投影参数 `t = DotProd(v, v2) / DotProd(v, v)`(L780)
   - 若 `t ∈ [0,1]`,点到线段距离 `Length(v2 - v*t)`(L783)
   - 否则取到对应端点距离
4. 取所有面/边/点的最小距离作为返回值

### 10.2 用途

该算法用于旧版自动骨骼分配:当一个顶点落在多个骨骼影响范围内时,选择最近骨骼作为主影响骨骼。现代版本通过 `VisualEnvelope` 直接读取 `Physique`/`Skin` 修改器的权重数据,此算法保留用于兼容与回退。

---

## 十一、Cue 事件轨道

### 11.1 CueTrack 单例

`CueTrack`(cuetrack.hpp/cpp)是进程级单例,因 3ds Max 插件常驻,需在导出前 `clear()`(mfxexp.cpp L327)避免上次导出残留。

### 11.2 NoteTrack 采集

`MFXNode` 构造函数(mfxnode.cpp L44-61)在 `exportCueTrack` 开启时,从 Max 节点的 `NoteTrack` 提取关键帧注释作为 Cue:

```cpp
//mfxnode.cpp L47-57
for( int i = 0; i < node->NumNoteTracks(); ++i )
{
    DefNoteTrack* note = (DefNoteTrack*) node->GetNoteTrack( i );
    for( int j = 0; j < note->keys.Count(); ++j )
    {
        CueTrack::addCue( note->keys[j]->time, note->keys[j]->note );
    }
}
```

### 11.3 写入流程

`DoExport` 在节点通道写完后调用 `CueTrack::writeFile(animation)`(mfxexp.cpp L489),Cue 轨道占用 1 个通道(计入 `nChannels`)。

---

## 十二、引用层级重组

### 12.1 动机

动画的骨骼层级必须与对应 `.visual` 模型的节点层级一致,否则运行时蒙皮错位。但美术在 Max 中搭建的层级可能与目标 visual 不完全相同。`referenceNodesFile` 选项允许指定一个 visual 文件作为**引用层级**,导出时据此重组 `MFXNode` 树。

### 12.2 loadReferenceNodes

`loadReferenceNodes`(mfxexp.cpp L522-533)打开引用 visual 的 `node` 段,调用 `readReferenceHierarchy`(L505-517)递归读取 identifier→parent 映射到 `nodeParents_`。

### 12.3 重组逻辑

`DoExport` L337-366 遍历 `nodeParents_`,对每个 (child, parent) 对:

1. 在当前树中查找 child 与 parent 节点(L345-346)
2. 若二者当前父子关系与引用不一致,先检测是否存在环(child 的祖先链中是否包含 parent)(L351-354)
3. 有环则先断开 `parent` 与 `child` 的旧父子关系(L357-358)
4. 将 child 从原父节点移除,挂到引用指定的 parent 下(L361-364)

```cpp
//mfxexp.cpp L361-364
MFXNode* op = c->getParent();
if (op)
    op->removeChild( c );
p->addChild( c );
```

### 12.4 根子节点排序

重组后,对 `mfxRoot_` 的直接子节点按子树规模降序排序(L369-388),使骨骼最多的子树排在前面,便于运行时遍历优化。排序比较函数 `numChildDescending`(mfxnode.cpp L346)比较 `getNChildren()`。

---

## 十三、ExportSettings 配置项

`ExportSettings`(expsets.hpp L17-87)为单例,配置项如下:

| 配置项 | 类型 | 说明 |
|--------|------|------|
| `allowScale_` | bool | 是否允许骨骼缩放(否则正交化) |
| `exportNodeAnimation_` | bool | 是否导出节点动画通道 |
| `exportCueTrack_` | bool | 是否导出 Cue 事件轨道 |
| `useLegacyOrientation_` | bool | 使用旧版朝向约定 |
| `nodeFilter_` | NodeFilter | 节点过滤(ALL/SELECTED/VISIBLE) |
| `frameFirst_` / `frameLast_` | int | 导出帧范围(取自 Max 动画范围) |
| `staticFrame_` | int | 静态帧(网格导出用) |
| `referenceNodesFile_` | string | 引用层级 visual 文件路径 |

### 13.1 配置加载优先级

`DoExport` 按以下顺序读取,后者覆盖前者(L294-296):

1. `cfgFilename`(`animationexporter.cfg`,插件配置目录)
2. `settingsFilename`(`<name>.animationsettings`,与输出同目录)
3. `pSettingsOverride`(MaxScript `BWAnimationSetting` 命令设置的内存覆盖)

### 13.2 NodeFilter 枚举

```cpp
//expsets.hpp L30-35
enum NodeFilter
{
    ALL = 0,
    SELECTED,
    VISIBLE
};
```

---

## 十四、MaxScript 集成

### 14.1 BWAnimationSetting 命令

Release 版(非 `BW_EXPORTER_DEBUG`)注册 MaxScript 命令 `BWAnimationSetting`(mfxexp.cpp L57),供脚本批量导出时覆盖配置:

```cpp
//mfxexp.cpp L57
def_visible_primitive(BWAnimationSetting, "BWAnimationSetting");
```

### 14.2 支持的设置键

`BWAnimationSetting_cf`(L59-112)解析键值对,写入 `pSettingsOverride` XML 段:

| MaxScript 键 | XML 字段 | 说明 |
|---------------|----------|------|
| `allow_scale` | `allowScale` | 允许缩放 |
| `node` | `exportNodeAnimation` | 导出节点动画 |
| `cue_track` | `exportCueTrack` | 导出 Cue 轨道 |
| `opposite_facing` | `useLegacyOrientation` | 旧版朝向 |
| `reference_hierarchy` | `referenceNodesFile` | 引用层级文件 |
| `reset` | — | 清除覆盖 |

Debug 版不链接 MaxScript 库(会崩溃),因此该命令仅 Release 可用(L56 注释)。

### 14.3 pSettingsOverride 生命周期

`pSettingsOverride` 是文件作用域静态变量(mfxexp.cpp L51),`BWAnimationSetting` 命令首次调用时创建 XML 段,后续命令追加/覆盖键值。`DoExport` 读取后(L296)立即置 `NULL`(L312),保证下次导出不残留旧覆盖。`reset` 键(L102-106)也清除覆盖,供脚本中途重置。

---

## 十四之补、辅助数据结构与工具函数

### A.1 MaterialList 材质去重

`MaterialList`(mfxexp.hpp L51-81)维护导出场景涉及的材质列表,`addMaterial` 用 `std::find` 去重,保证同一 `Mtl*` 只记录一次:

```cpp
//mfxexp.hpp L58-68
void addMaterial( Mtl * mtl )
{
    if( mtl )
    {
        BW::vector< Mtl* >::iterator it = std::find(
            materials_.begin(), materials_.end(), mtl );
        if( it == materials_.end() )
            materials_.push_back( mtl );
    }
}
```

材质列表用于导出时将 3ds Max 材质映射为 BigWorld `.mfm` 材质引用。

### A.2 BoneList 骨骼-顶点映射

`BoneList`(mfxexp.hpp L89-140)是旧版骨骼分配的辅助结构,记录每个骨骼节点影响的顶点索引:

```cpp
//mfxexp.hpp L83-87
typedef struct
{
    INode *node;
    BW::vector< int > vertexIndices;
} Bone;
```

`addBone(node, index)` 查找已有骨骼,找到则追加顶点索引,否则新建条目(L115-129)。该结构配合 `getDistanceToBone` 实现旧版自动骨骼分配。

### A.3 MultiSubMaterial 多维子材质

`MultiSubMaterial`(mfxexp.hpp L142-147)记录多维子材质及其子材质名,供导出时处理 3ds Max 的 Multi/Sub-Object 材质:

```cpp
//mfxexp.hpp L142-147
typedef struct
{
    Mtl *mtl_;
    BW::vector< BW::string > children_;
} MultiSubMaterial;
```

`findMultiSubMaterial`(mfxexp.hpp L194)按 `Mtl*` 查找已记录的多维子材质,避免重复解析。

### A.4 utility 工具函数

`utility.hpp/.cpp` 提供坐标系与矩阵变换工具:

| 函数 | 作用 |
|------|------|
| `rearrangeMatrix` | 3ds Max(Z-up)→ BigWorld(Y-up)矩阵行列交换 |
| `normaliseMatrix` | 正交化矩阵,消除缩放分量(`allowScale=false` 时用) |
| `isMirrored` | 检测矩阵是否镜像(行列式为负),用于 Portal 顶点顺序反转 |
| `trailingLeadingWhitespaces` | 检测字符串前后空白,校验节点名合法性 |
| `toLower` | 字符串转小写,用于 `_bsp` 等命名约定匹配 |

### A.5 vertcont / polycont 容器

- `vertcont.hpp/.cpp/.ipp`(`VertexContainer` / `UniqueVertices`):顶点去重容器,按位置+UV 哈希合并相同顶点,减少 `.primitives` 顶点数
- `polycont.hpp/.cpp/.ipp`(`PolyContainer`):多边形容器,处理 3ds Max 多边形(可能四边形/多边形)到三角形的扇形拆分

### A.6 visual_mesh / visual_envelope 在本模块的角色

虽然 `animationexporter` 主输出是 `.animation`,但 `DoExport` 仍调用 `exportMeshes` + `exportEnvelopes`(L331-332)收集网格与蒙皮信息。这些数据用于:
- 识别哪些节点是骨骼(蒙皮影响对象),确保其 include 标记正确
- 收集骨骼初始变换,供动画通道的 `idealParent` 计算
- 验证蒙皮骨骼层级与动画层级一致

网格本身不写入 `.animation`,但参与节点树构建与校验。

---

## 十五、与其他模块的依赖关系

### 15.1 依赖图

```
animationexporter
    │
    ├──► cstdmf          (BinaryFile, SmartPointer, StringHashMap, dprintf, log_msg, guard)
    ├──► resmgr          (BWResource, XMLSection, DataSection, DataResource, MultiFileSystem)
    ├──► math            (Matrix, Vector3, Quaternion, BlendTransform, boundbox)
    ├──► moo             (Node, NodeCatalogue — 间接)
    ├──► exporter_common (DataSectionCachePurger)
    ├──► 3ds Max SDK     (Max.h, istdplug.h, stdmat.h, decomp.h, shape.h, interpik.h,
    │                    modstack.h, phyexp.h, iparamm2.h, iskin.h, maxscript/*, NoteTrck.h)
    └── (旧版) wm3.h / MorpherClassID.h (Morpher 修改器)
```

### 15.2 与 DCC SDK 集成要点

- **插件注册**:通过 `ClassDesc` + `SCENE_EXPORT_CLASS_ID` 注册为场景导出器
- **修改器探测**:`findPhysiqueModifier` / `findSkinMod` 遍历节点 `Object` 的修改器栈,按 `Class_ID` 识别 Physique(Discreet 旧版蒙皮)与 Skin(标准蒙皮)
- **NoteTrack 访问**:通过 `DefNoteTrack` 读取关键帧注释,需 `NoteTrck.h`
- **MaxScript**:Release 版通过 `def_visible_primitive` 注册命令,需 `maxscript.h` / `define_instantiation_functions.h`(Max 2012+)或 `maxscrpt.h`(旧版)
- **版本兼容**:`MAX_RELEASE_R14` 宏区分 Max 2012 前后 include 路径变化

### 15.3 与其他导出器的关系

`animationexporter` 与 `visualexporter` 共享大量同名文件(`mfxexp`、`mfxnode`、`visual_mesh`、`visual_envelope`、`expsets`),但代码独立维护而非共享库。`visualexporter` 的 `MFXNode` 仅保留 `exportTree`(无 `exportAnimation`),且 `ExportSettings` 字段更多。两者通过 `.visual` 文件的 `node` 段共享骨骼层级约定。

---

## 十六、关键代码片段

### 16.1 压缩参数从旧文件继承

`DoExport` 在覆写文件前先读取旧 `.animation` 的首通道压缩参数,实现"保留上次压缩设置"(mfxexp.cpp L437-466):

```cpp
//mfxexp.cpp L437-466 (节选)
FILE* file = _wfopen( bw_utf8tow( filename ).c_str(), L"rb" );
if (file)
{
    BinaryFile animation( file );
    float f; BW::string s; int numChannels; int channelType;
    animation >> f >> s >> s >> numChannels;
    if (numChannels > 0)
    {
        animation >> channelType;
        if (channelType == 4)
        {
            animation >> s;
            ci.specifyAmounts_ = true;
            animation >> ci.scaleCompressionError_;
            animation >> ci.positionCompressionError_;
            animation >> ci.rotationCompressionError_;
        }
    }
    fclose(file);
}
```

### 16.2 exportTree 写节点层级 XML

`MFXNode::exportTree`(mfxnode.cpp L163-190)将被包含节点序列化为 XML,供 `.visual` 使用:

```cpp
//mfxnode.cpp L172-180
pThisSection->writeString( "identifier", this->getIdentifier() );
Matrix3 m = rearrangeMatrix(getRelativeTransform( 0,
    !ExportSettings::instance().allowScale(), idealParent ));
m.SetRow( 3, m.GetRow(3) * ExportSettings::instance().unitScale() );
pThisSection->writeVector3( "transform/row0", reinterpret_cast<Vector3&>(m.GetRow(0)) );
pThisSection->writeVector3( "transform/row1", reinterpret_cast<Vector3&>(m.GetRow(1)) );
pThisSection->writeVector3( "transform/row2", reinterpret_cast<Vector3&>(m.GetRow(2)) );
pThisSection->writeVector3( "transform/row3", reinterpret_cast<Vector3&>(m.GetRow(3)) );
```

### 16.3 validateAnimationIDs 重名检测

`validateAnimationIDs`(mfxexp.cpp L835-861)通过 `checkDuplicateNodeNames` 收集重复节点名并生成错误消息:

```cpp
//mfxexp.cpp L843-858
if (ExportSettings::instance().exportNodeAnimation())
{
    checkDuplicateNodeNames( mfxRoot_, nodeNames, duplicateNodeNames );
}
if (duplicateNodeNames.size())
{
    res = false;
    BW::set<BW::string>::iterator it = duplicateNodeNames.begin();
    for (; it != duplicateNodeNames.end(); it++)
    {
        errorMsg.append( BW::string( "Duplicate node name " ) + *it + BW::string("\n") );
    }
}
```

### 16.4 旧版动画通道矩阵写入

`mfxAnimationNodeEnum`(export.cpp L879-898)展示旧版 chunk 化写入:

```cpp
//export.cpp L887-893
int size = CHUNK_HEADER_SIZE;
size += getMFXStrLen( name );
size += 4;
writeMFXChunkHeader( CHUNKID_ANIMATIONCHANNEL, size, size, pStream );
fwrite( &time, 4, 1, pStream );
writeMFXStr( name, pStream );
```

---

## 十七、设计亮点与注意事项

### 17.1 设计亮点

1. **三层配置覆盖机制**:cfg(全局默认)→ settings(单文件)→ MaxScript(脚本临时覆盖),兼顾美术习惯与自动化批处理需求。`pSettingsOverride` 用完后置 `NULL`(L312)避免跨导出泄漏。

2. **引用层级重组的环检测**:重组父子关系时主动检测并打破环(L351-359),避免出现循环层级导致递归栈溢出。

3. **RAII 缓存清理**:`DataSectionCachePurger` 在 `DoExport` 作用域结束自动清空 `DataSection` 缓存,解决 3ds Max 插件常驻导致的内存累积问题。

4. **压缩参数继承**:覆写 `.animation` 前先读回旧文件的 `CompressionInfo`,使美术手动调整的压缩容差不因重新导出丢失。

5. **Debug/Release ClassID 隔离**:允许两个版本插件共存于同一 Max 安装,便于开发调试。

6. **祖先 include 传播**:`mungeIncluded` + `includeAncestors` 保证动画层级的完整性——任何被引用的骨骼节点其祖先必被导出,运行时才能正确重建世界变换。

7. **BlendTransform 矩阵分解**:采样后用 `BlendTransform`(math 库)将 4×4 矩阵分解为 Scale/Position/Rotation 三元组,并 `normaliseRotation` 归一化四元数,保证旋转插值在运行时平滑无翻转。

8. **idealParent 解耦层级与变换**:`getRelativeTransform` 的 `idealParent` 参数允许节点相对"引用父级"而非"实际父级"计算变换,这是引用层级重组后保证动画通道正确的关键——即使节点树结构变了,变换仍按引用层级计算。

### 17.2 注意事项

1. **必须从 bigworld/tools/exporter 运行**:`DllMain` 主动检测运行目录,禁止从 3ds Max 插件目录直接加载(L72-86),否则弹窗报错并拒绝加载。这是因为资源路径解析依赖工作目录。

2. **Debug 版无 MaxScript**:`BW_EXPORTER_DEBUG` 编译时不链接 MaxScript 库,`BWAnimationSetting` 命令不可用(L56 注释),自动化导出需用 Release 版。

3. **坐标系约定**:3ds Max 为 Z-up 右手系,BigWorld 为 Y-up。所有变换经 `rearrangeMatrix` / `writeMFXPoint` 的 Y/Z 交换完成转换,自定义扩展必须沿用此约定。

4. **CueTrack 单例清理**:插件常驻导致 `CueTrack` 跨导出残留,`DoExport` 必须在导出前 `CueTrack::clear()`(L327)。

5. **节点名合法性**:`exportAnimation` 校验节点名前后无空白(L207),非法名会导致运行时动画匹配失败,导出时弹窗警告但不中断。

6. **与 visualexporter 的骨骼层级一致性**:若动画与模型分属不同 Max 文件,必须使用 `reference_hierarchy` 指定同一 visual 引用,否则层级不一致会导致蒙皮错位。

7. **`export.cpp` 旧版代码**:`MFExp` 类与 `getDistanceToBone` 等属历史实现,现代流程走 `MFXExport` + `VisualEnvelope`,旧代码保留用于算法参考与回退,新功能不应在其上扩展。

8. **unitScale 应用点**:平移分量在采样时乘以 `unitScale`(mfxnode.cpp L254),缩放/旋转不乘,确保单位转换只影响位置而不扭曲动画姿态。

9. **nIncludedNodes 通道计数**:`nChannels` 通过 `mfxRoot_->nIncludedNodes()`(mfxnode.cpp L289)递归统计被包含节点数,只有 `include_=true` 的节点计入。若 `nChannels==0` 则跳过整个 `.animation` 写入(L431),避免产生空动画文件。

10. **root 节点重命名**:写入前将 `mfxRoot_` 的 `setMaxNode(NULL)` + `setIdentifier("Scene Root")`(mfxexp.cpp L483-484),使动画根节点固定为 "Scene Root",与运行时模型根节点约定一致,保证动画与模型正确绑定。

11. **animName 提取**:从文件路径提取不含目录与扩展名的纯名作为 `animName`(mfxexp.cpp L411-422),写入 `.animation` 头部两处,运行时据此标识动画资源。

12. **boundTable 三路写入**:`exportAnimation` 写入三份相同的 `boundTable`(mfxnode.cpp L278-280),分别对应 scale/position/rotation 三路关键帧的绑定索引,运行时压缩算法据此对每路独立压缩。

---

> **参考文件路径**:
> - `programming/bigworld/tools/animationexporter/expmain.cpp`
> - `programming/bigworld/tools/animationexporter/mfxexp.hpp`
> - `programming/bigworld/tools/animationexporter/mfxexp.cpp`
> - `programming/bigworld/tools/animationexporter/mfxnode.hpp` / `mfxnode.cpp`
> - `programming/bigworld/tools/animationexporter/export.cpp`
> - `programming/bigworld/tools/animationexporter/chunkids.hpp`
> - `programming/bigworld/tools/animationexporter/expsets.hpp`
