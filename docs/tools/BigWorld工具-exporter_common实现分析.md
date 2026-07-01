# BigWorld Engine exporter_common(导出器公共库)实现深度分析

> 本文档详细分析 BigWorld Engine 14.4.1 中 `tools/exporter_common/` 模块的完整实现。该模块是三个 DCC 导出器(animationexporter / mayavisualexporter / visualexporter)共享的公共静态库,提供 BSP 生成、蒙皮拆分、节点目录管理、DataSection 缓存清理等横切功能。本文涵盖 BSP 生成管线、SkinSplitter 贪心拆分算法、NodeCatalogueHolder / DataSectionCachePurger RAII 守卫、模板化设计、以及与三个导出器的集成关系。

---

## 目录

- [一、整体架构概览](#一整体架构概览)
- [二、源码目录结构](#二源码目录结构)
- [三、模块定位与设计理念](#三模块定位与设计理念)
- [四、bsp_generator BSP 生成](#四bsp_generator-bsp-生成)
- [五、populateWorldTriangles 三角形收集](#五populateworldtriangles-三角形收集)
- [六、skin_splitter 蒙皮拆分](#六skin_splitter-蒙皮拆分)
- [七、SkinSplitter 贪心算法详解](#七skinsplitter-贪心算法详解)
- [八、node_catalogue_holder 节点目录守卫](#八node_catalogue_holder-节点目录守卫)
- [九、data_section_cache_purger 缓存清理守卫](#九data_section_cache_purger-缓存清理守卫)
- [十、vertex_formats 顶点格式](#十vertex_formats-顶点格式)
- [十一、模板化设计分析](#十一模板化设计分析)
- [十二、与三个导出器的集成关系](#十二与三个导出器的集成关系)
- [十三、关键代码片段](#十三关键代码片段)
- [十四、设计亮点与注意事项](#十四设计亮点与注意事项)

---

## 一、整体架构概览

### 1.1 模块定位

`exporter_common` 是 BigWorld DCC 工具链的**公共静态库**,被三个导出器链接:

```
┌──────────────────┐  ┌──────────────────────┐  ┌──────────────────┐
│ animationexporter│  │ mayavisualexporter   │  │ visualexporter   │
│  (3ds Max 动画)  │  │  (Maya 可视化)       │  │ (3ds Max 可视化) │
└────────┬─────────┘  └──────────┬───────────┘  └────────┬─────────┘
         │                       │                       │
         │  DataSectionCachePurger│ generateBSP           │ generateBSP
         │                       │ SkinSplitter          │ SkinSplitter
         │                       │ DataSectionCachePurger│ NodeCatalogueHolder
         │                       │                       │ DataSectionCachePurger
         ▼                       ▼                       ▼
       ┌─────────────────────────────────────────────────────────┐
       │                  exporter_common (静态库)                │
       │  ┌──────────────┐ ┌──────────────┐ ┌──────────────────┐│
       │  │ bsp_generator│ │ skin_splitter│ │ node_catalogue_  ││
       │  │   .hpp/.cpp  │ │ .hpp/.cpp/.ipp│ │ holder .hpp/.cpp││
       │  └──────────────┘ └──────────────┘ └──────────────────┘│
       │  ┌────────────────────────────┐ ┌─────────────────────┐│
       │  │ data_section_cache_purger  │ │  vertex_formats.hpp ││
       │  │      .hpp/.cpp             │ │   (空占位)          ││
       │  └────────────────────────────┘ └─────────────────────┘│
       └─────────────────────────────────────────────────────────┘
```

### 1.2 核心职责

| 组件 | 职责 | 被谁使用 |
|------|------|----------|
| `bsp_generator` | 从 `.visual` + `.primitives` 生成 BSP | visualexporter, mayavisualexporter |
| `skin_splitter` | 按最大骨骼数拆分蒙皮三角形 | VisualEnvelope(三导出器共用) |
| `node_catalogue_holder` | RAII 初始化/销毁 `Moo::NodeCatalogue` | 仅 visualexporter |
| `data_section_cache_purger` | RAII 清理 `DataSection` 缓存 | 全部三个导出器 |
| `vertex_formats` | 顶点格式占位(实际用 `moo/vertex_formats.hpp`) | 间接 |

### 1.3 关键设计原则

| 原则 | 说明 |
|------|------|
| **DCC 无关** | 公共库不依赖任何 DCC SDK(3ds Max / Maya),仅依赖 BigWorld 核心库(cstdmf/resmgr/moo/math/physics2) |
| **模板化** | `SkinSplitter` 用模板适配不同导出器的顶点/三角形类型,实现一次编写多处复用 |
| **RAII 资源管理** | `NodeCatalogueHolder` / `DataSectionCachePurger` 用构造/析构管理生命周期,防泄漏 |
| **静态库链接** | 编译为静态库(.lib),被各导出器链接,代码不重复编译 |

---

## 二、源码目录结构

`exporter_common` 模块位于 `programming/bigworld/tools/exporter_common/`,文件精简:

| 文件 | 行数级别 | 职责 |
|------|----------|------|
| `bsp_generator.hpp` | ~25 | `generateBSP` 函数声明 |
| `bsp_generator.cpp` | ~560 | BSP 生成实现:`generateBSP`、`populateWorldTriangles`、`getMaterialIdentifier` |
| `skin_splitter.hpp` | ~68 | `SkinSplitter` 类声明(模板化) |
| `skin_splitter.cpp` | ~120 | `createList`、`findAppropriateRelationship`、`findRelationship` 非模板实现 |
| `skin_splitter.ipp` | ~187 | `SkinSplitter` 模板方法内联实现(构造、`checkIndex`、`splitTriangles`、`addRelationship`) |
| `node_catalogue_holder.hpp` | ~20 | `NodeCatalogueHolder` RAII 类声明 |
| `node_catalogue_holder.cpp` | 小 | 构造/析构实现 |
| `data_section_cache_purger.hpp` | ~21 | `DataSectionCachePurger` RAII 类声明 |
| `data_section_cache_purger.cpp` | 小 | 构造/析构实现 |
| `vertex_formats.hpp` | 极小 | 空占位(注释说明实际用 `moo/vertex_formats.hpp`) |

---

## 三、模块定位与设计理念

### 3.1 为何需要公共库

三个导出器存在大量共性需求:
- **BSP 生成**:visualexporter 与 mayavisualexporter 都需从 visual 生成 BSP,逻辑完全相同
- **蒙皮拆分**:三个导出器的 `VisualEnvelope` 都需按骨骼数拆分,算法一致但顶点类型不同
- **缓存清理**:DCC 插件常驻,DataSection 缓存会跨导出累积,需统一清理
- **节点目录**:visualexporter 写 visual 时需 `Moo::NodeCatalogue` 查找骨骼

抽取公共库避免代码重复,保证行为一致性。

### 3.2 DCC 无关性

`exporter_common` 不 include 任何 3ds Max 或 Maya 头文件,仅依赖:
- `cstdmf`(bw_vector, bw_string, guard, log_msg)
- `resmgr`(BWResource, DataSection)
- `moo`(Node, Vertices, Primitive, PrimitiveHelper, NodeCatalogue)
- `math`(Matrix)
- `physics2`(BSPTreeTool, WorldTriangle, WorldTriangle::Flags)

这使其能被任意 DCC 导出器链接而不引入 SDK 冲突。

### 3.3 模板化的必要性

各导出器的 `VisualMesh::Triangle` / `BloatVertex` / `BoneVertex` 类型定义不同(3ds Max 版与 Maya 版字段布局略有差异),但拆分算法逻辑相同。`SkinSplitter` 用三个模板参数(`TriangleVector` / `BloatVertexVector` / `BoneVertexVector`)适配,配合 `getWeights` / `getIndices` 自由函数适配不同 `BoneVertex` 类型,实现算法与数据解耦。

---

## 四、bsp_generator BSP 生成

`bsp_generator` 是 exporter_common 最复杂的组件,负责从 `.visual` + `.primitives` 提取三角形并构建 BSP 树。

### 4.1 generateBSP 接口

```cpp
//bsp_generator.hpp L18-20
bool generateBSP( const BW::string & visualName,
        const BW::string & bspName,
        BW::vector< BW::string > & materialIDs );
```

| 参数 | 方向 | 说明 |
|------|------|------|
| `visualName` | 输入 | `.visual` 资源名(相对路径) |
| `bspName` | 输出 | `.bsp` 文件名 |
| `materialIDs` | 输出 | 返回的材质 ID 列表(按 primitiveGroup 顺序) |
| 返回值 | — | 成功/失败 |

### 4.2 generateBSP 主流程

`generateBSP`(bsp_generator.cpp L400-555)流程:

```
generateBSP(visualName, bspName, materialIDs)              [bsp_generator.cpp:400]
│
├─[1] 计算 primitivesName (visualName → .primitives)        // L404-407
├─[2] purge visualName / primitivesName 缓存                 // L410-411
├─[3] 打开 visual 根 DataSection                             // L415-424
├─[4] 加载 rootNode (Moo::Node::loadRecursive)              // L426-437
├─[5] 遍历 renderSet 段:                                    // L442-547
│       ├─ 收集 transformNodes (node 子段 → rootNode.find)   // L446-468
│       ├─ 计算 firstNodeTransform (累乘父链变换)            // L470-477
│       └─ 遍历 geometry 段:                                // L479-543
│            ├─ 读 verticesName → Vertices::load             // L489-499
│            ├─ 读 indicesName → Primitive::load             // L502-512
│            ├─ 遍历 primitiveGroup 段:                      // L514-536
│            │    ├─ getMaterialIdentifier (material 段)      // L529
│            │    ├─ materialFlags = materialIDs.size() - 1   // L531
│            │    └─ primitiveGroups.push_back(...)           // L532
│            └─ populateWorldTriangles(tris, firstNodeTransform,
│                   vertices, primitive, primitiveGroups)    // L538-539
├─[6] BSPTreeTool::buildBSP(tris)                            // L549
├─[7] BSPTreeTool::saveBSPInFile(pTree, bspName)             // L550
└─[8] bw_safe_delete(pTree)                                  // L552
```

### 4.3 primitivesName 推算

BSP 需要顶点与索引数据,这些存储在 `.primitives` 文件中,通过 visual 名推算:

```cpp
//bsp_generator.cpp L404-407
BW::string primitivesName =
    visualName.substr( 0, visualName.find_last_of( '.' ) ) +
        ".primitives";
std::replace( primitivesName.begin(), primitivesName.end(), '\\', '/' );
```

### 4.4 rootNode 加载

visual 的 `node` 段描述骨骼层级,`generateBSP` 加载它以解析 renderSet 中 node 引用的变换:

```cpp
//bsp_generator.cpp L426-437
Moo::NodePtr pRootNode = new Moo::Node;
Moo::Node & rootNode = *pRootNode;
DataSectionPtr pNodeSection = pRoot->openSection( "node" );
if (pNodeSection)
{
    rootNode.loadRecursive( pNodeSection );
}
else
{
    rootNode.identifier( "root" );
}
```

### 4.5 transformNodes 与 firstNodeTransform

renderSet 的 `node` 子段引用骨骼节点名,通过 `rootNode.find` 解析为 `Moo::NodePtr`(L446-468)。首个节点的世界变换 `firstNodeTransform` 通过累乘父链变换得到(L470-477):

```cpp
//bsp_generator.cpp L470-477
Moo::NodePtr pMainNode = transformNodes.front();
Matrix firstNodeTransform = pMainNode->transform();
while (pMainNode != &rootNode)
{
    pMainNode = pMainNode->parent();
    firstNodeTransform.postMultiply( pMainNode->transform() );
}
```

### 4.6 vertices / indices 加载

geometry 段的 `vertices` 与 `primitive` 字段引用 `.primitives` 内的子资源,若不含 `/` 则拼接 primitivesName 前缀(L489-504):

```cpp
//bsp_generator.cpp L489-494
BW::string verticesName = pGeomSection->readString( "vertices" );
if (verticesName.find_first_of( '/' ) >= verticesName.size())
    verticesName = primitivesName + '/' + verticesName;
Vertices vertices;
if (!vertices.load( verticesName )) { /* 报错 */ }
```

### 4.7 primitiveGroup 与 materialIDs

每个 primitiveGroup 的材质标识通过 `getMaterialIdentifier`(L380-389)读取 `material/identifier`,默认 "empty"。`materialFlags` 存储为 materialIDs 列表索引(L531),运行时据此查表得到材质名:

```cpp
//bsp_generator.cpp L529-532
materialIDs.push_back( getMaterialIdentifier(primitiveGroupSection) );
primitiveGroup.materialFlags_ = (WorldTriangle::Flags)(materialIDs.size() - 1);
primitiveGroups.push_back( primitiveGroup );
```

### 4.8 BSP 构建与保存

收集所有世界空间三角形后,`BSPTreeTool::buildBSP` 构建 BSP 树,`saveBSPInFile` 持久化:

```cpp
//bsp_generator.cpp L549-552
BSPTree * pTree = BSPTreeTool::buildBSP( tris );
bool bRes = BSPTreeTool::saveBSPInFile( pTree, bspName.c_str() );
bw_safe_delete( pTree );
```

`BSPTreeTool` 来自 `physics2` 库,BSP 用于运行时碰撞检测与可见性剔除。

---

## 五、populateWorldTriangles 三角形收集

`populateWorldTriangles`(bsp_generator.cpp L316-367)将 primitiveGroup 的三角形变换到世界空间并加入三角形集合。

### 5.1 流程

```cpp
//bsp_generator.cpp L316-318
void populateWorldTriangles( RealWTriangleSet & ws, const Matrix & m,
        const Vertices & vertices, const Primitive & primitives,
        const PrimitiveGroups & primitiveGroups )
```

1. 校验 `primitives.primType() == PT_TRIANGLE_LIST`(L322-326),非三角形列表报错返回
2. 遍历 primitiveGroups(L332-358):
   - 跳过 `flags == -1` 的组(标记为不加入 BSP,L342)
   - 取 `Moo::PrimitiveGroup`(`primitives.primitiveGroup(groupIndex_)`)
   - 构造 `WorldTriDegenerateCuller` 适配器(L347),变换顶点并剔除退化三角形
   - `PrimitiveHelper::generateTrianglesFromIndices` 按索引展开三角形,通过 culler 回调加入 `ws`(L349-352)
3. 若有三角形被剔除(`bspTriangleCulled_`),输出 INFO 提示建议简化 BSP(L360-365)

### 5.2 WorldTriDegenerateCuller

`WorldTriDegenerateCuller` 是适配器,接收 `PrimitiveHelper` 生成的三角形,应用变换矩阵 `m`,剔除面积退化的三角形(零面积或共线顶点),将有效三角形以 `WorldTriangle` 形式加入 `ws`。`WorldTriangle::Flags` 携带 materialFlags,供运行时材质判定。

### 5.3 getMaterialIdentifier

```cpp
//bsp_generator.cpp L380-389
BW::string getMaterialIdentifier( DataSectionPtr primitiveGroupSection )
{
    DataSectionPtr pMat = primitiveGroupSection->openSection( "material" );
    if (pMat)
    {
        return pMat->readString( "identifier", "empty" );
    }
    return "empty";
}
```

无材质时返回 "empty",与导出器默认材质名一致,保证 BSP 材质映射连续性。

---

## 六、skin_splitter 蒙皮拆分

`SkinSplitter` 是 exporter_common 的模板化组件,解决"单 draw call 骨骼数上限"问题:GPU 硬件蒙皮通常限制单次 draw call 影响骨骼数(如 32/64/80),超出需拆分网格为多个子网格。

### 6.1 SkinSplitter 类声明

```cpp
//skin_splitter.hpp L6-63
typedef BW::vector<uint32> BoneRelationship;

class SkinSplitter
{
public:
    template<typename TriangleVector, typename BloatVertexVector, typename BoneVertexVector>
    SkinSplitter( const TriangleVector& triangles,
        const BloatVertexVector& vertices,
        const BoneVertexVector& boneVertices );

    bool createList( uint32 nodeLimit, BW::vector<uint32>& nodeList );

    template <typename BoneVertex>
    static bool checkIndex( const BoneVertex& v,
        const BW::vector<bool>& indexUsed );

    template<typename TriangleVector, typename BloatVertexVector, typename BoneVertexVector>
    static void splitTriangles( TriangleVector& triangles,
        TriangleVector& splitTriangles,
        const BW::vector<uint32>& boneIndices,
        const BloatVertexVector& vertices,
        const BoneVertexVector& boneVertices, size_t numBones );

    uint size() { return static_cast<uint>(relationships_.size()); }

private:
    int findAppropriateRelationship( uint32 nodeLimit,
        const BW::vector<uint32>& nodeList) const;
    template <typename BoneVertex>
    void addRelationship( const BoneVertex& v1, const BoneVertex& v2,
        const BoneVertex& v3 );
    int findRelationship( const BoneRelationship& relationship,
        bool perfectMatch = true );
    template <typename BoneVertex>
    void addRelationship( BoneRelationship& relationship, const BoneVertex& v );

    BW::vector<BoneRelationship> relationships_;
};
```

### 6.2 核心数据结构

- `BoneRelationship`:`vector<uint32>`,一组骨骼索引(一个三角形涉及的骨骼集合)
- `relationships_`:所有三角形涉及的骨骼关系列表(去重后)

### 6.3 三个模板参数

| 参数 | 含义 | 各导出器对应 |
|------|------|--------------|
| `TriangleVector` | 三角形容器 | `VisualMesh::TriangleVector` |
| `BloatVertexVector` | 膨胀顶点容器(含 vertexIndex) | `VisualMesh::BloatVertexVector` |
| `BoneVertexVector` | 骨骼顶点容器(含骨骼索引/权重) | `VisualEnvelope::BoneVVector` |

通过 `getWeights(v, weights)` / `getIndices(v, indices)` 自由函数(各导出器自定义)适配不同 `BoneVertex` 类型的字段访问。

---

## 七、SkinSplitter 贪心算法详解

### 7.1 构造:建立骨骼关系列表

构造函数(skin_splitter.ipp L13-45)遍历每个三角形,收集其三顶点涉及的骨骼索引为 `BoneRelationship`,去重后存入 `relationships_`:

```cpp
//skin_splitter.ipp L22-29
for (size_t i = 0; i < triangles.size(); ++i)
{
    const VisualMesh::Triangle& tri = triangles[i];
    addRelationship(
        boneVertices[vertices[tri.index[0]].vertexIndex],
        boneVertices[vertices[tri.index[1]].vertexIndex],
        boneVertices[vertices[tri.index[2]].vertexIndex] );
}
```

随后移除被其他关系完全包含的冗余关系(L35-44),减少拆分次数:

```cpp
//skin_splitter.ipp L35-44
size_t relationshipCount = relationships_.size();
for (size_t i = 0; i < relationshipCount; i++)
{
    BoneRelationship br = relationships_.front();
    relationships_.erase( relationships_.begin() );
    if (findRelationship( br, false ) == -1)   // false=非精确匹配,子集也算
    {
        relationships_.push_back( br );
    }
}
```

### 7.2 addRelationship:三角形骨骼集合

`addRelationship`(skin_splitter.ipp L134-153)对三角形三顶点调用重载 `addRelationship(relationship, v)`,合并三顶点的有效骨骼(权重>0)索引到单一 `BoneRelationship`,跳过重复索引。

`addRelationship(relationship, v)`(L161-185)通过 `getWeights` / `getIndices` 取顶点的 3 骨骼权重与索引,权重>0 的索引加入关系:

```cpp
//skin_splitter.ipp L168-184
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

### 7.3 createList:贪心合并关系到上限

`createList`(skin_splitter.cpp L17-43)贪心选择关系合并,直到达到 `nodeLimit`:

```cpp
//skin_splitter.cpp L17-43
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

算法:
1. 取最后一个关系作为初始 `nodeList`
2. 若初始关系骨骼数已超 `nodeLimit`,返回 false(无法拆分)
3. 循环调用 `findAppropriateRelationship` 找"合并后增量最小"的关系
4. 合并该关系的新骨骼到 `nodeList`,移除该关系
5. 直到无合适关系可合并

### 7.4 findAppropriateRelationship:最小增量选择

`findAppropriateRelationship`(skin_splitter.cpp L54-81)寻找合并后使 `nodeList` 增量最小的关系:

```cpp
//skin_splitter.cpp L54-81
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

这是**贪心算法**:每次选择使骨骼列表增长最少的关系,最大化每个子网格覆盖的三角形数,最小化拆分子网格数。`diff` 初始为 `nodeLimit - nodeList.size() + 1`(剩余容量+1),保证只选不超限的关系。

### 7.5 splitTriangles:按骨骼集拆分三角形

`splitTriangles`(skin_splitter.ipp L91-125)将可被当前骨骼集覆盖的三角形从原列表移到拆分列表:

```cpp
//skin_splitter.ipp L91-125
template <...>
void SkinSplitter::splitTriangles(
    TriangleVector& triangles, TriangleVector& splitTriangles,
    const BW::vector<uint32>& boneIndices,
    const BloatVertexVector& vertices,
    const BoneVertexVector& boneVertices, size_t numBones )
{
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
}
```

### 7.6 checkIndex:顶点骨骼集校验

`checkIndex`(skin_splitter.ipp L57-74)检查顶点的所有有效骨骼(权重>0)是否都在当前骨骼集中:

```cpp
//skin_splitter.ipp L57-74
template <typename BoneVertex>
bool SkinSplitter::checkIndex( const BoneVertex& v,
    const BW::vector<bool>& indexUsed )
{
    float weights[3] = { 0.f, 0.f, 0.f };
    int indices[3] = { 0, 0, 0 };
    getWeights( v, weights );
    getIndices( v, indices );
    for (size_t i = 0; i < 3; ++i)
    {
        if (weights[i] > 0.f && !indexUsed[indices[i]])
            return false;                              // 有骨骼不在集内
    }
    return true;
}
```

### 7.7 完整拆分流程(调用方)

`VisualEnvelope::split` 的典型调用模式:

```
SkinSplitter splitter(triangles, vertices, boneVertices);   // 建关系表
while (splitter.size() > 0)
{
    BW::vector<uint32> nodeList;
    if (!splitter.createList(boneCount, nodeList))           // 贪心取骨骼集
    {
        // 失败:骨骼过多
        return false;
    }
    TriangleVector splitTriangles;
    SkinSplitter::splitTriangles(triangles, splitTriangles,  // 拆出三角形
        nodeList, vertices, boneVertices, numBones);
    // 用 splitTriangles + nodeList 构造子 VisualEnvelope
}
```

---

## 八、node_catalogue_holder 节点目录守卫

`NodeCatalogueHolder`(node_catalogue_holder.hpp L12-17)是 RAII 类,管理 `Moo::NodeCatalogue` 生命周期。

### 8.1 声明

```cpp
//node_catalogue_holder.hpp L7-17
#include "moo/node_catalogue.hpp"

BW_BEGIN_NAMESPACE

class NodeCatalogueHolder
{
public:
    NodeCatalogueHolder();
    ~NodeCatalogueHolder();
};

BW_END_NAMESPACE
```

### 8.2 行为

- **构造**:初始化 `Moo::NodeCatalogue`(骨骼节点全局目录)
- **析构**:销毁 `Moo::NodeCatalogue`

`Moo::NodeCatalogue` 提供骨骼节点的全局查找表,visualexporter 写 visual 时通过它解析 renderSet 中 node 引用。

### 8.3 仅 visualexporter 使用

只有 `visualexporter` 的 `DoExport` 构造 `NodeCatalogueHolder`(mfxexp.cpp L397):

```cpp
//visualexporter/mfxexp.cpp L393-397
DataSectionCachePurger dscp;
NodeCatalogueHolder nch;
```

`mayavisualexporter` 与 `animationexporter` 不使用——前者通过 `Hierarchy` 管理节点,后者不导出 visual。

---

## 九、data_section_cache_purger 缓存清理守卫

`DataSectionCachePurger`(data_section_cache_purger.hpp L12-17)是 RAII 类,清理 `DataSection` 缓存。

### 9.1 声明

```cpp
//data_section_cache_purger.hpp L5-17
#include "cstdmf/bw_namespace.hpp"

BW_BEGIN_NAMESPACE

class DataSectionCachePurger
{
public:
    DataSectionCachePurger();
    ~DataSectionCachePurger();
};

BW_END_NAMESPACE
```

### 9.2 行为

- **构造**:通常无操作(或记录状态)
- **析构**:清空 `DataSection` 缓存(`BWResource::purge` 或类似)

### 9.3 全部导出器使用

三个导出器入口均构造 `DataSectionCachePurger`,解决 DCC 插件常驻导致的缓存膨胀:

| 导出器 | 使用位置 |
|--------|----------|
| animationexporter | `mfxexp.cpp` L239 `DoExport` 入口 |
| mayavisualexporter | `writer` 入口(经 `AutoCleanup` 间接) |
| visualexporter | `mfxexp.cpp` L394 `DoExport` 入口 |

每次导出后自动清空缓存,避免上次导出的 DataSection 残留占用内存,也避免读取到过期缓存。

---

## 十、vertex_formats 顶点格式

`vertex_formats.hpp` 是**空占位文件**,仅包含注释说明实际顶点格式定义在 `moo/vertex_formats.hpp`。

### 10.1 设计原因

历史上 exporter_common 可能曾自定义顶点格式,后统一使用 `moo` 库的版本。保留空文件避免破坏 include 路径,实际代码应 include `moo/vertex_formats.hpp`:

```cpp
//vertex_formats.hpp (空占位)
// 实际顶点格式见 moo/vertex_formats.hpp
```

### 10.2 实际顶点格式(moo 库)

BigWorld 运行时顶点格式定义在 `programming/bigworld/lib/moo/vertex_formats.hpp`,常见格式:
- `VertexXYZNUV`:位置/法线/UV
- `VertexXYZNUVIIIWW`:位置/法线/UV/3骨骼索引/2权重(蒙皮)
- `VertexXYZNUVIIIWWTB`:加切线/副法线(bump)
- `VertexXYZNUV2`:双 UV

各导出器的 `VisualEnvelope` 内部定义与上述格式对应的 POD 结构(如 `VertexXYZNUVIIIWW`),保证二进制兼容。

---

## 十一、模板化设计分析

### 11.1 SkinSplitter 模板参数

`SkinSplitter` 的模板化是其核心设计,使同一算法适配三个导出器的不同类型:

```cpp
//skin_splitter.hpp L15-22
template
    <typename TriangleVector,
    typename BloatVertexVector,
    typename BoneVertexVector>
SkinSplitter(
    const TriangleVector& triangles,
    const BloatVertexVector& vertices,
    const BoneVertexVector& boneVertices );
```

### 11.2 类型适配机制

不同导出器的类型差异通过以下机制适配:

| 适配点 | 机制 | 示例 |
|--------|------|------|
| 三角形索引访问 | `tri.index[0/1/2]` 约定 | 各导出器 `Triangle` 结构统一 |
| 顶点 vertexIndex 访问 | `vertices[tri.index[i]].vertexIndex` | 各导出器 `BloatVertex` 结构统一 |
| 骨骼权重/索引访问 | `getWeights(v, w)` / `getIndices(v, idx)` 自由函数 | 各导出器自定义重载 |

### 11.3 模板实例化

模板方法在 `skin_splitter.ipp` 中实现,通过 `#include "skin_splitter.ipp"`(skin_splitter.hpp L67)在头文件末尾包含,使调用方编译时实例化。非模板方法(`createList` / `findAppropriateRelationship` / `findRelationship`)在 `skin_splitter.cpp` 实现,只编译一次。

### 11.4 设计权衡

| 优势 | 代价 |
|------|------|
| 算法一次编写,多处复用 | 模板错误信息复杂 |
| 编译期类型安全,无虚函数开销 | 每个导出器实例化一份代码,二进制体积增大 |
| 适配不同字段布局无需修改算法 | 新增顶点类型需提供 `getWeights`/`getIndices` 重载 |

---

## 十二、与三个导出器的集成关系

### 12.1 集成矩阵

| 组件 | animationexporter | mayavisualexporter | visualexporter |
|------|:-----------------:|:------------------:|:--------------:|
| `generateBSP` | ✗ | ✓ | ✓ |
| `SkinSplitter` | ✓(VisualEnvelope) | ✓(VisualEnvelope) | ✓(VisualEnvelope) |
| `NodeCatalogueHolder` | ✗ | ✗ | ✓ |
| `DataSectionCachePurger` | ✓ | ✓(间接) | ✓ |
| `vertex_formats` | 间接 | 间接 | 间接 |

### 12.2 generateBSP 调用点

- **visualexporter**:mfxexp.cpp L1175(`_bsp` 节点)+ L1197(主 visual)
- **mayavisualexporter**:visualfiletranslator.cpp L1339(`_bsp` 节点)+ L1353(主 visual)

两处调用模式一致:生成 `.bsp` → 合并到 `.primitives`。

### 12.3 SkinSplitter 调用点

三个导出器的 `VisualEnvelope::split` 均构造 `SkinSplitter` 并循环 `createList` + `splitTriangles`。调用差异仅在 `boneCount` 来源:
- 3ds Max 版:`settings_.boneCount()`(visualexporter mfxexp.cpp L1776)
- Maya 版:`ExportSettings::instance().maxBones()`(mayavisualexporter)

### 12.4 DataSectionCachePurger 调用点

- animationexporter:mfxexp.cpp L239
- visualexporter:mfxexp.cpp L394
- mayavisualexporter:经 `AutoCleanup` 间接(visualfiletranslator.cpp L1655)

### 12.5 NodeCatalogueHolder 调用点

仅 visualexporter:mfxexp.cpp L397。因 visualexporter 写 visual 时需 `Moo::NodeCatalogue` 解析骨骼引用,其他导出器不涉及 visual 节点目录查找。

---

## 十三、关键代码片段

### 13.1 generateBSP 主循环

```cpp
//bsp_generator.cpp L442-547 (节选)
while (iter != pRoot->end())
{
    if ((*iter)->sectionName() == "renderSet")
    {
        BW::vector< Moo::NodePtr > transformNodes;
        DataSectionPtr pRenderSetSection = *iter;
        // ... 收集 transformNodes,计算 firstNodeTransform ...

        DataSection::iterator geomIter = pRenderSetSection->begin();
        while (geomIter != pRenderSetSection->end())
        {
            DataSectionPtr pGeomSection = *geomIter;
            if (pGeomSection->sectionName() == "geometry")
            {
                PrimitiveGroups primitiveGroups;
                // ... 加载 vertices / primitive,收集 primitiveGroups ...
                populateWorldTriangles( tris, firstNodeTransform,
                        vertices, primitive, primitiveGroups );
            }
            geomIter++;
        }
    }
    iter++;
}
BSPTree * pTree = BSPTreeTool::buildBSP( tris );
bool bRes = BSPTreeTool::saveBSPInFile( pTree, bspName.c_str() );
```

### 13.2 populateWorldTriangles 退化剔除

```cpp
//bsp_generator.cpp L344-354
const Moo::PrimitiveGroup& pg = primitives.primitiveGroup( iter->groupIndex_ );
WorldTriDegenerateCuller culler( ws, m, vertices, flags );
Moo::PrimitiveHelper::generateTrianglesFromIndices(
    primitives.pIndices(), pg.startIndex_, pg.nPrimitives_,
    Moo::PrimitiveHelper::TRIANGLE_LIST, culler,
    primitives.nIndices() );
bspTriangleCulled |= culler.bspTriangleCulled_;
```

### 13.3 SkinSplitter 构造(关系建立)

```cpp
//skin_splitter.ipp L22-29
for (size_t i = 0; i < triangles.size(); ++i)
{
    const VisualMesh::Triangle& tri = triangles[i];
    addRelationship(
        boneVertices[vertices[tri.index[0]].vertexIndex],
        boneVertices[vertices[tri.index[1]].vertexIndex],
        boneVertices[vertices[tri.index[2]].vertexIndex] );
}
```

### 13.4 createList 贪心合并

```cpp
//skin_splitter.cpp L20-42
nodeList = relationships_.back();
if (nodeList.size() > nodeLimit )
    return false;
relationships_.pop_back();

int index = 0;
while((index = findAppropriateRelationship(nodeLimit, nodeList)) != -1)
{
    const BoneRelationship& r = relationships_[index];
    for (uint i = 0; i < r.size(); i++)
    {
        if(std::find(nodeList.begin(), nodeList.end(), r[i]) == nodeList.end())
            nodeList.push_back( r[i] );
    }
    relationships_.erase( relationships_.begin() + index );
}
return true;
```

### 13.5 findAppropriateRelationship 最小增量

```cpp
//skin_splitter.cpp L62-80
uint diff = static_cast<uint>(nodeLimit - nodeList.size() + 1);
for (uint i = 0; i < relationships_.size(); i++)
{
    uint curDiff = 0;
    const BoneRelationship& br = relationships_[i];
    for (uint32 j = 0; j < br.size(); j++)
    {
        if( std::find( b, e, br[j] ) == e )
            curDiff++;
    }
    if (curDiff < diff)
    {
        diff = curDiff;
        index = int(i);
    }
}
```

### 13.6 splitTriangles 三角形迁移

```cpp
//skin_splitter.ipp L101-124
BW::vector<bool> indexUsed( numBones, false );
for (uint32 i = 0; i < boneIndices.size(); i++)
    indexUsed[boneIndices[i]] = true;

VisualMesh::TriangleVector::const_iterator triIt = triangles.begin();
while (triIt != triangles.end())
{
    if (checkIndex(boneVertices[vertices[triIt->index[0]].vertexIndex], indexUsed) &&
        checkIndex(boneVertices[vertices[triIt->index[1]].vertexIndex], indexUsed) &&
        checkIndex(boneVertices[vertices[triIt->index[2]].vertexIndex], indexUsed))
    {
        splitTriangles.push_back( *triIt );
        triIt = triangles.erase( triIt );
    }
    else
    {
        triIt++;
    }
}
```

### 13.7 RAII 守卫使用

```cpp
//visualexporter/mfxexp.cpp L391-397
int MFXExport::DoExport(...)
{
    DataSectionCachePurger dscp;     // 析构时清缓存
    NodeCatalogueHolder nch;         // 析构时销毁 NodeCatalogue
    ip_ = maxInterface;
    // ... 导出逻辑 ...
}   // 作用域结束,逆序析构:nch → dscp
```

---

## 十四、设计亮点与注意事项

### 14.1 设计亮点

1. **DCC 无关抽象**:`exporter_common` 不依赖任何 DCC SDK,被 3ds Max 与 Maya 导出器共同链接,真正实现"算法一次编写,DCC 多处复用"。这是 BigWorld 工具链架构的关键解耦点。

2. **SkinSplitter 贪心算法**:`findAppropriateRelationship` 每次选最小增量关系合并,在 `nodeLimit` 约束下最大化子网格覆盖,最小化 draw call 数。虽然贪心非全局最优,但对游戏网格(骨骼局部聚集)实践中接近最优,且复杂度可控。

3. **关系冗余消除**:构造时移除被其他关系包含的子集关系(L35-44),减少 `createList` 迭代次数,提升拆分效率。

4. **模板化 + 自由函数适配**:`SkinSplitter` 用模板参数适配容器类型,用 `getWeights`/`getIndices` 自由函数适配字段访问,实现算法与数据布局彻底解耦,新增顶点格式只需提供重载。

5. **RAII 资源管理**:`NodeCatalogueHolder` / `DataSectionCachePurger` 用构造/析构管理生命周期,作用域结束自动清理,即使导出中途异常也能释放资源,防泄漏。

6. **BSP 退化三角形剔除**:`WorldTriDegenerateCuller` 在 BSP 生成时剔除零面积/共线三角形,避免 BSP 树退化,并输出 INFO 提示美术简化模型。

7. **materialFlags 索引化**:BSP 的 `WorldTriangle::Flags` 存储 materialIDs 列表索引而非字符串,运行时查表得材质名,节省内存与比较开销。

8. **purge 缓存前置**:`generateBSP` 开头 `purge(visualName/primitivesName)`(L410-411),强制重新读取最新文件,避免读到导出前的旧缓存。

### 14.2 注意事项

1. **`vertex_formats.hpp` 空占位**:不要在此文件添加内容,实际顶点格式在 `moo/vertex_formats.hpp`,扩展应修改后者。

2. **SkinSplitter 失败处理**:`createList` 返回 false 表示单个关系骨骼数已超 `nodeLimit`,即一个三角形涉及骨骼过多无法拆分,调用方应报错提示美术减骨骼。

3. **贪心非全局最优**:SkinSplitter 贪心算法在最坏情况(骨骼均匀分布)可能产生多余拆分,但对典型角色网格(骨骼局部聚集于四肢/头)效果良好。若需更优解需用图着色等 NP 算法,性能代价大。

4. **`findRelationship` perfectMatch 语义**:构造时去重用 `perfectMatch=false`(子集也算匹配),`findRelationship` 此时即使关系 size 不同也会比较元素,语义需注意。

5. **NodeCatalogueHolder 仅 visualexporter**:误在 animationexporter / mayavisualexporter 中使用会引入不必要的 `Moo::NodeCatalogue` 依赖,且可能因未配置而行为异常。

6. **BSP 需 valid visual + primitives**:`generateBSP` 要求 visual 与 primitives 文件都已生成,因此调用点必须在网格导出之后(visualexporter / mayavisualexporter 均如此)。

7. **triangles.erase 性能**:`splitTriangles` 用 `vector::erase` 逐个删除,三角形多时有 O(n²) 风险。对超大网格可考虑改用 swap-and-pop 或 partition,但游戏网格规模通常可接受。

8. **materialFlags 与运行时材质映射**:`materialFlags` 存储 materialIDs 索引,运行时 BSP 碰撞需通过索引查表得材质名再查材质属性,链路较长,修改 materialIDs 顺序会影响运行时行为。

9. **WorldTriDegenerateCuller 的 INFO 提示**:剔除退化三角形时输出 INFO"Creating a simplified BSP would fix the problem",这是建议而非错误,美术可忽略,但简化模型能提升 BSP 质量与性能。

10. **静态库链接顺序**:exporter_common 作为静态库,需在导出器链接命令中正确排序(通常库在前,导出器在后),否则可能因符号未解析链接失败。

---

> **参考文件路径**:
> - `programming/bigworld/tools/exporter_common/bsp_generator.hpp` / `.cpp`
> - `programming/bigworld/tools/exporter_common/skin_splitter.hpp` / `.cpp` / `.ipp`
> - `programming/bigworld/tools/exporter_common/node_catalogue_holder.hpp` / `.cpp`
> - `programming/bigworld/tools/exporter_common/data_section_cache_purger.hpp` / `.cpp`
> - `programming/bigworld/tools/exporter_common/vertex_formats.hpp`
> - `programming/bigworld/lib/moo/vertex_formats.hpp`(实际顶点格式)
> - `programming/bigworld/lib/physics2/bsp.hpp`(BSPTreeTool)
