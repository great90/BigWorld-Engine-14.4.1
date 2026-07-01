# BigWorld 工具 resourcechecker 实现深度分析

> 本文档详细分析 BigWorld Engine 14.4.1 中 `resourcechecker` 工具的完整实现。`resourcechecker` 不是一个独立可执行文件,而是一个**规则引擎库**,核心类 `VisualChecker` 通过 `visual_rules.xml` 配置驱动的规则匹配,对 BigWorld `.visual` 资源文件进行多维度校验:包围盒尺寸、三角形数量、节点层级深度、Portal 几何正确性、硬点完整性、纹理命名规范等。该库被 `visualexporter`、`mayavisualexporter`、`animationexporter` 等导出器调用,在美术资源导出阶段拦截低质量资源。本文档涵盖规则匹配算法、几何检查实现、配置文件格式、错误收集机制的全部细节。

---

## 目录

- [一、概述与定位](#一概述与定位)
- [二、整体架构](#二整体架构)
- [三、目录结构](#三目录结构)
- [四、VisualChecker 类设计](#四visualchecker-类设计)
- [五、规则匹配算法](#五规则匹配算法)
- [六、规则继承与递归读取](#六规则继承与递归读取)
- [七、check 方法几何检查](#七check-方法几何检查)
- [八、Portal 几何校验](#八portal-几何校验)
- [九、硬点校验机制](#九硬点校验机制)
- [十、三角形计数检查](#十三角形计数检查)
- [十一、visual_rules.xml 配置格式](#十一visual_rulesxml-配置格式)
- [十二、与其他模块的依赖关系](#十二与其他模块的依赖关系)
- [十三、关键代码片段(带行号)](#十三关键代码片段带行号)
- [十四、设计亮点与注意事项](#十四设计亮点与注意事项)
- [附录 A:常见问题澄清](#附录-a常见问题澄清)

---

## 一、概述与定位

### 1.1 工具定位

`resourcechecker` 是 BigWorld 资源管线的**质量门禁库**。它的核心使命是:

1. 读取 `visual_rules.xml` 规则配置文件;
2. 根据 `.visual` 文件路径匹配最适用的规则(支持目录前缀 + 文件名通配符);
3. 对 `.visual` 文件执行多维度几何与逻辑检查;
4. 收集所有错误,以多行字符串返回给调用方(导出器)。

该库**不是独立 exe**,而是被以下导出器链接调用:

- `visualexporter`(3ds Max 导出器)
- `mayavisualexporter`(Maya 导出器)
- `animationexporter`(动画导出器)

导出器在资源导出前/后调用 `VisualChecker::check`,若返回 `false`,导出失败并显示错误信息,从而拦截低质量资源进入游戏资源库。

### 1.2 核心特性

| 特性 | 实现方式 | 说明 |
|------|---------|------|
| 规则配置 | `visual_rules.xml` | XML 配置驱动,无需重编译 |
| 路径匹配 | 目录前缀 + 文件名通配符 | 支持按目录分级规则 |
| 规则继承 | `parent` 字段 + 递归读取 | 类似 CSS 继承,避免重复配置 |
| 几何检查 | 包围盒/三角形/Portal/硬点 | 多维度校验 |
| 错误收集 | `BW::vector<BW::string> errors_` | 多行错误信息 |
| 类型识别 | `identifier` 字段 | 资源类型(如 `static`、`character`) |
| 导出建议 | `exportAs` 字段 | 推荐 static/static with nodes/normal |

### 1.3 工具规模

- **总代码规模**: 约 900 行 C++ 代码
- **核心文件**: `visual_checker.cpp`(834 行)
- **头文件**: `visual_checker.hpp`(62 行)
- **配置文件**: `visual_rules.xml`(在资源树中,不在工具源码内)

### 1.4 校验维度一览

`VisualChecker::check` 方法执行以下校验:

| 校验项 | 检查内容 | 失败错误示例 |
|--------|---------|-------------|
| 包围盒最小尺寸 | `boundingBox` 不小于 `minSize` | "Too small, must be at least 1, 1, 1" |
| 包围盒最大尺寸 | `boundingBox` 不大于 `maxSize` | "Too big, must be no bigger than 100, 100, 100" |
| 三角形数量上限 | 三角形数 ≤ `maxTriangles` | "Too many triangles (5000), must be less than 2000" |
| 三角形数量下限 | 三角形数 ≥ `minTriangles` | "Too few triangles (10), must be at least 50" |
| 节点层级深度 | `maxNodeDepth` ≤ `maxHierarchyDepth` | "Node hierarchy too deep, depth must be 5 nodes or less" |
| Portal 存在性 | `portals_=true` 时必须有 portal | "Must have one or more portals" |
| Portal 不存在性 | `portals_=false` 时不能有 portal | "Must not have any portals" |
| Portal 共面性 | Portal 顶点必须共面 | "Portal is non planar" |
| Portal 朝向 | Portal 法线必须朝内 | "Portal is facing outwards" |
| Portal 吸附 | Portal 包围盒必须吸附到 `portalSnap` | "Portals must reside on multiples of 0.5, 0.5, 0.5" |
| Portal 距离 | Portal 距原点必须是 `portalDistance` 的倍数 | "Portal must be a multiple of 1.0 away from the origin" |
| Portal 偏移 | Portal 中心在平面上的偏移 | "Centre of portal must be a multiple of 0.5 on the portals plane" |
| 节点名重复 | 节点名必须唯一 | "Duplicate node name Bone01" |
| 硬点完整性 | 必须包含所有 `hardPoint` 配置 | "Missing hard point HP_Head" |
| 硬点合法性 | `checkUnknownHardPoints` 时禁止未知硬点 | "Unknown hard point HP_Foo" |
| 纹理命名 | 纹理名不能含空格 | "Illegal texture name 'my texture.dds', no spaces in name or path allowed" |

---

## 二、整体架构

### 2.1 模块组成图

```
┌────────────────────────────────────────────────────────────────────┐
│              resourcechecker (静态库 .lib)                         │
│                                                                    │
│   ┌──────────────────────────────────────────────────────────┐    │
│   │              VisualChecker 类                             │    │
│   │              visual_checker.cpp                           │    │
│   │                                                          │    │
│   │   ┌─────────────────────┐                                │    │
│   │   │  构造函数 (L187)    │ 读 visual_rules.xml            │    │
│   │   │  - 加载规则          │ → 匹配适用规则                  │    │
│   │   │  - 路径匹配          │ → 递归读取规则属性              │    │
│   │   │  - 文件名通配符      │                                │    │
│   │   └──────────┬──────────┘                                │    │
│   │              │                                            │    │
│   │              ▼                                            │    │
│   │   ┌─────────────────────┐                                │    │
│   │   │  check (L437)       │ 执行几何检查                    │    │
│   │   │  - 包围盒检查        │                                │    │
│   │   │  - 三角形计数        │                                │    │
│   │   │  - 节点深度          │                                │    │
│   │   │  - Portal 校验       │                                │    │
│   │   │  - 节点重名          │                                │    │
│   │   │  - 硬点校验          │                                │    │
│   │   │  - 纹理命名          │                                │    │
│   │   └──────────┬──────────┘                                │    │
│   │              │                                            │    │
│   │              ▼                                            │    │
│   │   ┌─────────────────────┐                                │    │
│   │   │  errors_ 收集        │ → errorText() 多行返回         │    │
│   │   └─────────────────────┘                                │    │
│   └──────────────────────────────────────────────────────────┘    │
└────────────────────────────────────────────────────────────────────┘
                            ▲
                            │ 调用
        ┌───────────────────┼───────────────────┐
        │                   │                   │
┌───────────────┐   ┌───────────────┐   ┌───────────────┐
│visualexporter │   │mayavisual     │   │animation      │
│(3ds Max)      │   │exporter(Maya) │   │exporter       │
└───────────────┘   └───────────────┘   └───────────────┘
                            │
                            ▼
┌────────────────────────────────────────────────────────────────────┐
│                      依赖的引擎模块                                │
│   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────┐ │
│   │ resmgr      │  │ math        │  │ moo         │  │ cstdmf  │ │
│   │ - DataSection│ │ - Vector3   │  │ - VertexFmt │  │ - LogMsg│ │
│   │ - BWResource│  │ - BoundingBox│ │ - Primitive │  │         │ │
│   │ - Primitive │  │ - PlaneEq   │  │   FileStruct│  │         │ │
│   └─────────────┘  └─────────────┘  └─────────────┘  └─────────┘ │
└────────────────────────────────────────────────────────────────────┘
```

### 2.2 调用流程图

```
导出器 (如 visualexporter)
    │
    │  VisualChecker checker( visualName, cacheRules=true, snapVertices=true );
    ▼
构造函数 (L187)
    │
    ├── 跳过 _bsp. 文件(碰撞 visual, L203)
    │
    ├── 加载 visual_rules.xml (L211)
    │   ├── cacheRules=true: BWResource::openSection (始终加载)
    │   └── cacheRules=false: BWResource::fileExists 后加载
    │
    ├── 收集所有匹配规则 (L240-246)
    │   - visualPath.find(rulePath) != npos
    │
    ├── 按 path 长度降序稳定排序 (L248, L63-72)
    │
    ├── 遍历匹配规则,找首个 filespec 匹配 (L252-272)
    │   ├── PathMatchSpec (Windows 通配符)
    │   └── 空 filespec 匹配所有
    │
    └── 递归读取规则属性 (L287-317)
        ├── recursiveReadString (exportAs)
        ├── recursiveReadVector3 (minSize, maxSize, portalSnap)
        ├── recursiveReadInt (minTriangles, maxTriangles, ...)
        ├── recursiveReadFloat (portalDistance, portalOffset)
        ├── recursiveReadBool (portals, checkUnknownHardPoints)
        └── recursiveReadStrings (hardPoint 列表)
    │
    │  checker.check( visualSection, primResName );
    ▼
check 方法 (L437)
    │
    ├── 包围盒检查 (L456-476)
    ├── 三角形计数 checkTriangleCount (L479, L772)
    ├── 节点层级深度 maxNodeDepth (L485)
    ├── Portal 收集与校验 (L496-662)
    │   ├── Portal 共面性 (L558-576)
    │   ├── Portal 朝向 (L578-584)
    │   ├── Portal 吸附 (L603-624)
    │   ├── Portal 距离 (L627-636)
    │   └── Portal 偏移 (L638-659)
    ├── 节点重名检查 checkDuplicateNodeNames (L667-672)
    ├── 硬点完整性校验 (L679-686)
    ├── 硬点合法性校验 (L689-712)
    └── 纹理命名检查 (L714-737)
    │
    │  errorText = checker.errorText();
    ▼
返回所有错误(多行字符串)
```

---

## 三、目录结构

`resourcechecker` 工具源码位于 `programming/bigworld/tools/resourcechecker/` 目录:

```
programming/bigworld/tools/resourcechecker/
├── visual_checker.cpp     # VisualChecker 类完整实现 (834 行)
├── visual_checker.hpp     # VisualChecker 类声明 (62 行)
└── pch.hpp                # 预编译头
```

### 3.1 文件规模一览

| 文件 | 行数 | 职责 |
|------|------|------|
| `visual_checker.cpp` | 834 | 完整实现:构造、规则匹配、几何检查、错误收集 |
| `visual_checker.hpp` | 62 | 类声明与成员变量定义 |
| `pch.hpp` | (短) | 预编译头 |

### 3.2 visual_checker.hpp 类声明

`visual_checker.hpp` L16-58 完整声明了 `VisualChecker` 类:

```cpp
class VisualChecker
{
private:
    Vector3 minSize_;
    Vector3 maxSize_;
    uint32 maxTriangles_;
    uint32 minTriangles_;
    uint32 maxHierarchyDepth_;
    bool snapVertices_;
    bool portals_;
    Vector3 portalSnap_;
    float portalDistance_;
    float portalOffset_;
    bool checkHardPoints_;
    BW::set<BW::string> hardPoints_;

    BW::string typeName_;
    BW::string exportAs_;

    BW::vector<BW::string> errors_;

    bool checkTriangleCount( DataSectionPtr spPrims );
    void addError( const char * format, ... );

public:
    VisualChecker( const BW::string& visualName, bool cacheRules = true,
                   bool snapVertices = true );
    bool check( DataSectionPtr visualSection, const BW::string& primResName );
    BW::string errorText();
    BW::string typeName() const { return typeName_; }
    BW::string exportAs() const { return exportAs_; }
    void snapVertices( bool snapVertices ) { snapVertices_ = snapVertices; }
};
```

#### 成员变量分类

| 类别 | 成员 | 用途 |
|------|------|------|
| 包围盒 | `minSize_`, `maxSize_` | 包围盒尺寸上下限 |
| 三角形 | `maxTriangles_`, `minTriangles_` | 三角形数量上下限 |
| 节点 | `maxHierarchyDepth_` | 节点树最大深度 |
| 顶点吸附 | `snapVertices_` | 是否启用顶点吸附(构造参数,实际未在 check 中使用) |
| Portal | `portals_`, `portalSnap_`, `portalDistance_`, `portalOffset_` | Portal 校验参数 |
| 硬点 | `checkHardPoints_`, `hardPoints_` | 硬点校验参数与白名单 |
| 元信息 | `typeName_`, `exportAs_` | 资源类型与导出建议 |
| 错误 | `errors_` | 错误信息收集 |

---

## 四、VisualChecker 类设计

### 4.1 构造函数签名

```cpp
VisualChecker( const BW::string& visualName, bool cacheRules = true,
               bool snapVertices = true );
```

| 参数 | 默认值 | 含义 |
|------|--------|------|
| `visualName` | (必填) | `.visual` 资源路径,用于规则匹配 |
| `cacheRules` | `true` | 是否始终加载 `visual_rules.xml`(`true` 始终加载,`false` 仅当文件存在时加载) |
| `snapVertices` | `true` | 是否启用顶点吸附(存储为 `snapVertices_`,但 `check` 中未实际使用) |

### 4.2 构造函数核心逻辑

`visual_checker.cpp` L187-318 的构造函数完成"规则匹配与属性读取":

#### 步骤 1:跳过碰撞 visual(L203-206)

```cpp
if (visualName.find( "_bsp." ) != BW::string::npos)
{
    return;
}
```

文件名含 `_bsp.` 的 visual 是碰撞几何(`_bsp` = Binary Space Partitioning),无需校验,直接返回(所有成员保持默认值)。

#### 步骤 2:加载规则文件(L208-231)

```cpp
DataSectionPtr rulesSection;
if (cacheRules)
{
    rulesSection = BWResource::openSection( "visual_rules.xml" );
}
else
{
    if (BWResource::fileExists( "visual_rules.xml" ) )
        rulesSection = BWResource::openSection( "visual_rules.xml" );
}

if (!rulesSection)
{
    if ( ! LogMsg::automatedTest() )
    {
        MessageBox( GetForegroundWindow(),
            TEXT("VisualChecker::VisualChecker - Unable to find visual_rules.xml file.\n")
            TEXT("VisualChecker will be disabled temporarily\n"),
            TEXT("Visual Exporter"), MB_OK | MB_ICONEXCLAMATION );
    }
    addError("VisualChecker::VisualChecker - Unable to find visual_rules.xml file.");
    return;
}
```

`cacheRules` 参数的微妙差异:

- `cacheRules = true`:`openSection` 始终尝试加载(若文件不存在返回空,但 `BWResource` 内部可能缓存);
- `cacheRules = false`:先 `fileExists` 检查,避免触发缓存。

实际使用中,`cacheRules = true` 是默认值,适用于导出器场景(规则文件常驻)。

#### 步骤 3:收集匹配规则(L233-246)

```cpp
BW::string visualPath = BWResource::getFilePath( visualName );
BW::string visualFilename = BWResource::getFilename( visualName ).to_string();

BW::vector<DataSectionPtr> matchingRules;
BW::vector<DataSectionPtr> rules;
rulesSection->openSections( "rule", rules );
for (BW::vector<DataSectionPtr>::iterator i = rules.begin(); i != rules.end(); ++i)
{
    BW::string rulePath = toLower( (*i)->readString( "path" ) );

    if ( visualPath.find( rulePath ) != BW::string::npos )
        matchingRules.push_back( *i );
}
```

匹配条件:`visualPath` 包含 `rulePath` 作为子串(大小写不敏感)。例如:

- `visualPath = "objects/characters/heroes/"`
- `rulePath = "characters/"` → 匹配
- `rulePath = "monsters/"` → 不匹配

#### 步骤 4:稳定排序(L248)

```cpp
std::stable_sort( matchingRules.begin(), matchingRules.end(), ruleSectionCompare );
```

`ruleSectionCompare`(`visual_checker.cpp` L63-72)按 `path` 长度降序排序:

```cpp
bool ruleSectionCompare(const DataSectionPtr a, DataSectionPtr b)
{
    size_t aPathSize = a->readString( "path" ).size();
    size_t bPathSize = b->readString( "path" ).size();

    if (aPathSize == bPathSize)
        return a->readString( "filespec" ).size() > b->readString( "filespec" ).size();
    else
        return aPathSize > bPathSize;
}
```

排序规则:**path 长度长的优先,path 相同时 filespec 长度长的优先**。这确保更具体的规则(如 `objects/characters/heroes/`)优先于更通用的规则(如 `objects/`)。

#### 步骤 5:查找首个 filespec 匹配(L252-272)

```cpp
DataSectionPtr ruleSection;
for (BW::vector<DataSectionPtr>::iterator i = matchingRules.begin();
     i != matchingRules.end(); ++i)
{
    BW::string filePattern = toLower( (*i)->readString( "filespec" ) );

    if (filePattern.empty())
    {
        ruleSection = (*i);
        break;
    }

    if ( ::PathMatchSpec( visualFilename.c_str(), filePattern.c_str() ) )
    {
        ruleSection = (*i);
        break;
    }
}
```

`PathMatchSpec` 是 Windows Shell API(`shlwapi.h`),支持 `*` 和 `?` 通配符。例如:

- `filespec = "*.static"` 匹配所有 `.static` 结尾的文件;
- `filespec = "hero_*"` 匹配 `hero_avatar`、`hero_warrior` 等;
- `filespec = ""`(空)匹配所有文件(通配规则)。

首个匹配的规则即为适用规则,后续规则不再考虑。

---

## 五、规则匹配算法

### 5.1 匹配优先级总结

`VisualChecker` 的规则匹配优先级如下(从高到低):

1. **path 长度长的优先**:`objects/characters/heroes/` > `objects/characters/` > `objects/`;
2. **path 相同时 filespec 长度长的优先**:`hero_*.static` > `hero_*` > `*`(空);
3. **稳定排序**:同优先级的规则按 `visual_rules.xml` 中的出现顺序保留。

### 5.2 匹配示例

假设 `visual_rules.xml` 包含以下规则:

```xml
<root>
    <rule>
        <path>objects/</path>
        <filespec></filespec>
        <identifier>default</identifier>
        <maxTriangles>5000</maxTriangles>
    </rule>
    <rule>
        <path>objects/characters/</path>
        <filespec></filespec>
        <identifier>character</identifier>
        <maxTriangles>3000</maxTriangles>
    </rule>
    <rule>
        <path>objects/characters/heroes/</path>
        <filespec>hero_*</filespec>
        <identifier>hero</identifier>
        <maxTriangles>2000</maxTriangles>
    </rule>
    <rule>
        <path>objects/characters/heroes/</path>
        <filespec>hero_boss*</filespec>
        <identifier>boss</identifier>
        <maxTriangles>5000</maxTriangles>
    </rule>
</root>
```

对于 `objects/characters/heroes/hero_avatar.static`:

| 规则 | path 匹配 | filespec 匹配 | 优先级 |
|------|----------|--------------|--------|
| default | ✓ (`objects/` 是子串) | ✓ (空,通配) | path 长度 8,最低 |
| character | ✓ (`objects/characters/` 是子串) | ✓ (空,通配) | path 长度 18,中 |
| hero | ✓ (`objects/characters/heroes/` 是子串) | ✓ (`hero_*` 匹配) | path 长度 25,filespec 长度 6,高 |
| boss | ✓ | ✗ (`hero_boss*` 不匹配 `hero_avatar`) | 不适用 |

排序后顺序:`hero` > `boss`(filespec 长度比较) > `character` > `default`。但 `boss` 因 filespec 不匹配被跳过,最终选择 `hero` 规则,`maxTriangles = 2000`。

对于 `objects/characters/heroes/hero_boss_big.static`:

- `hero` 规则:`hero_*` 匹配,优先;
- `boss` 规则:`hero_boss*` 也匹配,但 filespec 长度 10 > 6,排序后 `boss` 在前。

最终选择 `boss` 规则,`maxTriangles = 5000`(允许 boss 模型有更多三角形)。

### 5.3 PathMatchSpec 平台依赖

`PathMatchSpec` 是 Windows Shell API,在 `visual_checker.cpp` L17 显式链接:

```cpp
#include "shlwapi.h"
#pragma comment( lib, "Shlwapi.lib" )
```

Unicode 模式下需要宽字符转换(L263-267):

```cpp
#ifdef UNICODE
    if ( ::PathMatchSpec( bw_utf8tow( visualFilename ).c_str(),
                          bw_utf8tow( filePattern ).c_str() ) )
#else
    if ( ::PathMatchSpec( visualFilename.c_str(), filePattern.c_str() ) )
#endif
```

这使得 `resourcechecker` 在非 Windows 平台不可直接编译(需替换为其他通配符库,如 Boost.Filesystem 或 POSIX `fnmatch`)。

---

## 六、规则继承与递归读取

### 6.1 parent 机制

`visual_rules.xml` 中的规则可通过 `parent` 字段继承其他规则:

```xml
<rule>
    <identifier>character</identifier>
    <path>objects/characters/</path>
    <maxTriangles>3000</maxTriangles>
    <portals>false</portals>
</rule>
<rule>
    <identifier>hero</identifier>
    <path>objects/characters/heroes/</path>
    <filespec>hero_*</filespec>
    <parent>character</parent>  <!-- 继承 character 规则 -->
    <maxTriangles>2000</maxTriangles>  <!-- 覆盖 -->
    <!-- portals 继承自 character: false -->
</rule>
```

### 6.2 rulesById 映射

构造函数 L279-285 构建 `identifier → rule` 映射:

```cpp
BW::map<BW::string, DataSectionPtr> rulesById;
for (BW::vector<DataSectionPtr>::iterator i = rules.begin(); i != rules.end(); ++i)
{
    BW::string id = (*i)->readString( "identifier" );
    if (!id.empty())
        rulesById[id] = *i;
}
```

此映射用于 `recursiveRead*` 系列函数查找父规则。

### 6.3 recursiveReadString 实现

`recursiveReadString`(`visual_checker.cpp` L92-108)是递归读取的典型实现:

```cpp
BW::string recursiveReadString(const BW::string& key,
        const BW::map<BW::string, DataSectionPtr>& sections,
        DataSectionPtr curSection,
        const BW::string& def)
{
    DataSectionPtr ds = curSection->openSection( key );
    if (ds)
        return ds->asString();

    BW::string parent = curSection->readString( "parent" );

    BW::map<BW::string, DataSectionPtr>::const_iterator i = sections.find( parent );
    if (i != sections.end())
        return recursiveReadString( key, sections, i->second, def );

    return def;
}
```

递归逻辑:

1. 在当前 section 查找 `key`,若存在则返回;
2. 否则读取当前 section 的 `parent` 字段;
3. 在 `sections` 映射中查找父规则;
4. 若找到父规则,递归查找;
5. 若无父规则或父规则不存在,返回默认值 `def`。

### 6.4 递归读取函数家族

`visual_checker.cpp` 实现了 6 个递归读取函数,覆盖所有数据类型:

| 函数 | 行号 | 返回类型 | 用途 |
|------|------|---------|------|
| `recursiveReadVector3` | L74-90 | `Vector3` | 向量(如 `minSize`, `portalSnap`) |
| `recursiveReadString` | L92-108 | `BW::string` | 字符串(如 `exportAs`) |
| `recursiveReadInt` | L110-126 | `int` | 整数(如 `maxTriangles`) |
| `recursiveReadFloat` | L128-144 | `float` | 浮点(如 `portalDistance`) |
| `recursiveReadBool` | L146-162 | `bool` | 布尔(如 `portals`) |
| `recursiveReadStrings` | L164-179 | `BW::set<BW::string>` | 字符串集合(如 `hardPoint` 列表) |

注意 `recursiveReadStrings` 的特殊行为(L170-172):

```cpp
BW::vector<BW::string> strs;
curSection->readStrings( key, strs );
results.insert( strs.begin(), strs.end() );
```

它**累加**当前 section 与所有父规则的字符串,而非覆盖。这允许在父规则定义基础硬点(如 `HP_Head`),子规则添加额外硬点(如 `HP_Weapon`)。

### 6.5 递归读取的应用

构造函数 L287-317 应用递归读取填充所有成员:

```cpp
typeName_ = ruleSection->readString( "identifier" );
exportAs_ = recursiveReadString( "exportAs", rulesById, ruleSection, exportAs_ );
if (!(exportAs_ == "normal" || exportAs_ == "static" || exportAs_ == "static with nodes"))
{
    char s[1024];
    bw_snprintf( s, sizeof(s), "Unknown value for exportAs [%s]\n", exportAs_.c_str() );
    ...
    addError(s);
    exportAs_ = "normal";
}

minSize_ = recursiveReadVector3( "minSize", rulesById, ruleSection, minSize_ );
maxSize_ = recursiveReadVector3( "maxSize", rulesById, ruleSection, maxSize_ );
minTriangles_ = recursiveReadInt( "minTriangles", rulesById, ruleSection, minTriangles_ );
maxTriangles_ = recursiveReadInt( "maxTriangles", rulesById, ruleSection, maxTriangles_ );
maxHierarchyDepth_ = recursiveReadInt( "maxHierarchyDepth", rulesById, ruleSection, maxHierarchyDepth_ );
portals_ = recursiveReadBool( "portals", rulesById, ruleSection, portals_ );
portalSnap_ = recursiveReadVector3( "portalSnap", rulesById, ruleSection, portalSnap_ );
portalDistance_ = recursiveReadFloat( "portalDistance", rulesById, ruleSection, portalDistance_ );
portalOffset_ = recursiveReadFloat( "portalOffset", rulesById, ruleSection, portalOffset_ );
checkHardPoints_ = recursiveReadBool( "checkUnknownHardPoints", rulesById, ruleSection, checkHardPoints_ );

recursiveReadStrings( "hardPoint", rulesById, ruleSection, hardPoints_ );
```

注意 `exportAs_` 的额外校验(L289-304):若值不在 `{"normal", "static", "static with nodes"}` 中,记录错误并重置为 `"normal"`。

---

## 七、check 方法几何检查

### 7.1 check 方法签名

```cpp
bool check( DataSectionPtr visualSection, const BW::string& primResName );
```

| 参数 | 含义 |
|------|------|
| `visualSection` | `.visual` 文件的 `DataSection`(XML 或 Packed Section) |
| `primResName` | 关联的 `.primitives` 文件资源名(用于三角形计数) |

返回值:`true` 表示通过所有检查,`false` 表示有错误(错误细节通过 `errorText()` 获取)。

### 7.2 check 方法整体结构

`visual_checker.cpp` L437-740 的 `check` 方法结构:

```cpp
bool VisualChecker::check( DataSectionPtr visualSection, const BW::string& primResName )
{
    errors_.clear();  // 清空之前的错误

    bool good = true;

    if (!visualSection) { addError(...); return false; }

    DataSectionPtr spPrims = PrimitiveFile::get( primResName );
    if (!spPrims) { addError(...); return false; }

    // 1. 包围盒检查 (L456-476)
    Vector3 bbMin = visualSection->readVector3( "boundingBox/min" );
    Vector3 bbMax = visualSection->readVector3( "boundingBox/max" );
    Vector3 size = bbMax - bbMin;
    // 检查 minSize / maxSize

    // 2. 三角形计数检查 (L479)
    if ( !checkTriangleCount( spPrims ) ) { good = false; }

    // 3. 节点层级深度检查 (L485-492)
    uint32 hierarchyDepth = maxNodeDepth( visualSection->openSection( "node" ) );
    // 检查 maxHierarchyDepth_

    // 4. Portal 校验 (L496-662)
    // 详见第八节

    // 5. 节点重名检查 (L664-672)
    checkDuplicateNodeNames( ... );

    // 6. 硬点校验 (L674-712)
    // 详见第九节

    // 7. 纹理命名检查 (L714-737)
    // 检查纹理名是否含空格

    return good;
}
```

### 7.3 包围盒检查

L456-476 实现包围盒尺寸上下限检查:

```cpp
Vector3 bbMin = visualSection->readVector3( "boundingBox/min" );
Vector3 bbMax = visualSection->readVector3( "boundingBox/max" );
Vector3 size = bbMax - bbMin;

// Check it's bigger than min size
if ((minSize_.x > 0.f && minSize_.x > size.x) ||
    (minSize_.y > 0.f && minSize_.y > size.y) ||
    (minSize_.z > 0.f && minSize_.z > size.z))
{
    good = false;
    addError( "Too small, must be at least %f, %f, %f", minSize_.x, minSize_.y, minSize_.z );
}

// Check it's smaller than max size
if ((maxSize_.x > 0.f && maxSize_.x < size.x) ||
    (maxSize_.y > 0.f && maxSize_.y < size.y) ||
    (maxSize_.z > 0.f && maxSize_.z < size.z))
{
    good = false;
    addError( "Too big, must be no bigger than %f, %f, %f", maxSize_.x, maxSize_.y, maxSize_.z );
}
```

注意 `minSize_.x > 0.f` 条件:`0` 表示"不检查该维度"。例如 `minSize = (0, 0, 0.1)` 仅检查 Z 轴最小值。

### 7.4 节点层级深度检查

L485-492 检查节点树深度:

```cpp
uint32 hierarchyDepth = maxNodeDepth( visualSection->openSection( "node" ) );

if (maxHierarchyDepth_ != 0 &&
    hierarchyDepth > maxHierarchyDepth_ )
{
    good = false;
    addError( "Node hierarchy too deep, depth must be %d nodes or less", maxHierarchyDepth_ );
}
```

`maxNodeDepth`(`visual_checker.cpp` L422-434)递归计算节点树最大深度:

```cpp
uint32 maxNodeDepth( DataSectionPtr nodeSection )
{
    uint32 maxDepth = 0;

    BW::vector<DataSectionPtr> nodes;
    nodeSection->openSections( "node", nodes );
    for (BW::vector<DataSectionPtr>::iterator i = nodes.begin(); i != nodes.end(); ++i)
    {
        maxDepth = max( maxDepth, maxNodeDepth( *i ) );
    }

    return maxDepth + 1;
}
```

递归逻辑:每个节点的深度 = max(子节点深度) + 1。叶子节点深度 = 1。

### 7.5 纹理命名检查

L714-737 检查纹理名是否含空格:

```cpp
typedef BW::vector<DataSectionPtr> DSVec;
DSVec renderSets;
visualSection->openSections( "renderSet", renderSets );
for (uint32 rs = 0; rs < renderSets.size(); rs++)
{
    DSVec geometries;
    renderSets[rs]->openSections( "geometry", geometries );
    for (uint32 g = 0; g < geometries.size(); g++)
    {
        DSVec pgs;
        geometries[g]->openSections( "primitiveGroup", pgs );
        for (uint32 pg = 0; pg < pgs.size(); pg++)
        {
            BW::string textureName = pgs[pg]->readString( "material/textureormfm" );
            BW::string::size_type pos = textureName.find_last_of( " " );
            if (pos != BW::string::npos)
            {
                good = false;
                addError( "Illegal texture name \"%s\", no spaces in name or path allowed\n",
                          textureName.c_str() );
            }
        }
    }
}
```

遍历 `renderSet > geometry > primitiveGroup > material/textureormfm`,检查纹理路径是否含空格。空格在文件路径中可能导致引擎加载失败(取决于文件系统实现),因此禁止。

### 7.6 节点重名检查

L664-672 检查节点名重复:

```cpp
BW::set<BW::string> visualNodes;
BW::set<BW::string> nodeDuplicates;

checkDuplicateNodeNames( visualSection->openSection( "node" ), visualNodes, nodeDuplicates );
for( BW::set<BW::string>::iterator it = nodeDuplicates.begin();
     it != nodeDuplicates.end(); ++it )
{
    good = false;
    addError( "Duplicate node name %s", (*it).c_str() );
}
```

`checkDuplicateNodeNames`(`visual_checker.cpp` L374-395)递归遍历节点树,用 `BW::set` 检测重复:

```cpp
void checkDuplicateNodeNames( DataSectionPtr nodeSection, BW::set<BW::string>& nodeNames,
                              BW::set<BW::string>& duplicates )
{
    if (!nodeSection)
        return;

    BW::string id = nodeSection->readString( "identifier" );
    if (std::find( nodeNames.begin(), nodeNames.end(), id ) == nodeNames.end())
    {
        nodeNames.insert( id );
    }
    else
    {
        duplicates.insert( id );
    }

    BW::vector<DataSectionPtr> nodes;
    nodeSection->openSections( "node", nodes );
    for (BW::vector<DataSectionPtr>::iterator i = nodes.begin(); i != nodes.end(); ++i)
    {
        checkDuplicateNodeNames( *i, nodeNames, duplicates );
    }
}
```

重复的节点名会导致动画绑定混乱(动画按节点名查找),因此必须唯一。

---

## 八、Portal 几何校验

Portal 是 BigWorld 室内场景的核心概念,连接不同的 chunk(空间分区)。Portal 校验是 `VisualChecker` 最复杂的部分。

### 8.1 Portal 收集

L496-507 收集所有 boundary 下的 portal:

```cpp
BW::vector<DataSectionPtr> boundaries;
visualSection->openSections( "boundary", boundaries );
BW::vector< std::pair<DataSectionPtr,DataSectionPtr> > portals;
for ( uint32 i=0; i<boundaries.size(); i++ )
{
    BW::vector<DataSectionPtr> portalSections;
    boundaries[i]->openSections( "portal", portalSections );
    for ( uint32 j=0; j<portalSections.size(); j++ )
    {
        portals.push_back( std::make_pair(boundaries[i],portalSections[j]) );
    }
}
```

每个 portal 关联其所属 boundary(用于读取法线等),存储为 `pair<boundary, portal>`。

### 8.2 Portal 存在性校验

L509-518 校验 portal 存在性:

```cpp
if (portals_ && portals.empty())
{
    good = false;
    addError( "Must have one or more portals" );
}
if (!portals_ && !portals.empty())
{
    good = false;
    addError( "Must not have any portals" );
}
```

`portals_ = true` 表示该 visual 必须有 portal(室内场景);`portals_ = false` 表示不能有 portal(户外物体)。

### 8.3 Portal 顶点坐标变换

L529-543 将 portal 顶点从平面空间变换到对象空间:

```cpp
BW::vector<Vector3> points;
portal->readVector3s( "point", points );

Matrix basis;
basis[0] = portal->readVector3( "uAxis" );
basis[2] = boundary->readVector3( "normal" );
basis[1] = basis[2].crossProduct( basis[0] );
basis.translation( boundary->readVector3("normal") * boundary->readFloat("d") );
for (uint32 j=0; j<points.size(); j++)
{
    Vector3& pt = points[j];
    pt = basis.applyPoint(pt);
}
```

变换逻辑:

- `basis[0]` = portal 的 U 轴;
- `basis[2]` = boundary 的法线(W 轴);
- `basis[1]` = 法线 × U 轴(V 轴);
- 平移 = 法线 × `d`(boundary 到原点的距离)。

变换后,`points` 是对象空间的 portal 顶点。

### 8.4 Portal 共面性校验

L546-576 校验 portal 顶点共面:

```cpp
if (points.size() < 3)
{
    good = false;
    addError( "Not enough points in a portal" );
    continue;
}

Vector3 portalCentre(0.f, 0.f, 0.f);
for (uint j = 0; j < points.size(); j++)
    portalCentre += points[j];
portalCentre *= 1.f / points.size();

PlaneEq p;
bool hasPlaneEq = false;
for (uint j = 0; j < (points.size() - 2); j++)
{
    p.init( points[ j + 2 ], points[ j + 1 ], points[ j ] );

    if (!((p.normal()[0] == 0) && (p.normal()[1] == 0) && (p.normal()[2] == 0)))
    {
        hasPlaneEq = true;
        break;
    }
}

if (!hasPlaneEq)
{
    good = false;
    addError( "Portal is non planar" );
    continue;
}
```

校验逻辑:

1. 至少 3 个顶点;
2. 计算质心(后续偏移检查用);
3. 尝试用三个连续顶点构造平面方程;
4. 若所有三元组都产生零法线(共线),则 portal 非平面。

`PlaneEq::init` 用三点叉积计算法线,若三点共线,叉积为零向量。

### 8.5 Portal 朝向校验

L578-584 校验 portal 朝向:

```cpp
BoundingBox bb(bbMin, bbMax);
if (p.d() - bb.centre().dotProduct(p.normal()) > 0.f)
{
    good = false;
    addError( "Portal is facing outwards" );
    continue;
}
```

校验逻辑:portal 平面方程 `p.d() - bb.centre()·p.normal() > 0` 表示 portal 法线朝外(远离包围盒中心)。室内 portal 应朝向包围盒内部(法线朝内)。

### 8.6 Portal 吸附校验

L603-624 校验 portal 包围盒是否吸附到 `portalSnap` 网格:

```cpp
BoundingBox portalBB = BoundingBox::s_insideOut_;
for (uint i = 0; i < points.size(); ++i)
{
    portalBB.addBounds( points[i] );
}

Vector3 minDiff = snapVector3( portalBB.minBounds(), portalSnap_ ) - portalBB.minBounds();
Vector3 maxDiff = snapVector3( portalBB.maxBounds(), portalSnap_ ) - portalBB.maxBounds();

static const float ERROR_EPSILON = 1.0f / 2196.f;
if ((fabsf(minDiff.x) > ERROR_EPSILON) ||
    (fabsf(minDiff.y) > ERROR_EPSILON) ||
    (fabsf(minDiff.z) > ERROR_EPSILON) ||
    (fabsf(maxDiff.x) > ERROR_EPSILON) ||
    (fabsf(maxDiff.y) > ERROR_EPSILON) ||
    (fabsf(maxDiff.z) > ERROR_EPSILON))
{
    good = false;
    addError( "Portals must reside on multiples of %f, %f, %f",
              portalSnap_.x, portalSnap_.y, portalSnap_.z );
}
```

`snapVector3`(`visual_checker.cpp` L345-357)将向量吸附到网格:

```cpp
Vector3 snapVector3( const Vector3& vec, const Vector3& snaps )
{
    Vector3 v = vec;
    if (snaps.x != 0.f) snapValue( v.x, snaps.x );
    if (snaps.y != 0.f) snapValue( v.y, snaps.y );
    if (snaps.z != 0.f) snapValue( v.z, snaps.z );
    return v;
}
```

吸附确保 portal 边界对齐到网格(如 0.5 米),使相邻 chunk 的 portal 能精确对接。

### 8.7 Portal 距离与偏移校验

L627-659 校验 portal 平面到原点的距离与平面偏移:

```cpp
if (portalDistance_ > 0.f)
{
    if (!isMultipleOf( p.d(), portalDistance_, 1.0f / 1024.f ))
    {
        good = false;
        addError( "Portal must be a multiple of %f away from the origin (it's %f away)",
                  portalDistance_, p.d() );
    }
}

float offset = 0.f;
if (close( fabsf( p.normal().x ), 1.f ))
{
    offset = portalCentre.z;
}
if (close( fabsf( p.normal().z ), 1.f ))
{
    offset = portalCentre.x;
}

if (offset != 0.f && portalOffset_ != 0.f)
{
    if (!isMultipleOf( offset, portalOffset_ ))
    {
        good = false;
        addError( "Centre of portal must be a multiple of %f on the portals plane (it's %f away)",
                  portalOffset_, offset );
    }
}
```

`portalDistance_`:portal 平面到原点的距离必须是此值的倍数(如 1.0 米,确保 portal 在 chunk 边界)。

`portalOffset_`:portal 中心在平面上的偏移必须是此值的倍数(用于网格对齐)。

`isMultipleOf`(`visual_checker.cpp` L359-364)用浮点模运算判断:

```cpp
bool isMultipleOf( float v, float m, const float epsilon = (1.0f / 8192.f) )
{
    float diff = fabsf( fmodf( v, m ) );
    return (diff < epsilon || diff - m > -epsilon);
}
```

考虑浮点误差(`epsilon`),避免精度问题导致的误报。

---

## 九、硬点校验机制

### 9.1 硬点概念

硬点(Hard Point)是 BigWorld 模型上预定义的"挂载点",用于挂载武器、特效、UI 元素等。硬点以节点形式存在,命名约定 `HP_*`(如 `HP_Head`、`HP_Weapon_Right`)。

### 9.2 硬点提取

`extractHardPoints`(`visual_checker.cpp` L400-417)递归提取模型中的所有硬点:

```cpp
void extractHardPoints( DataSectionPtr nodeSection, BW::set<BW::string>& hardPoints )
{
    if (!nodeSection)
        return;

    BW::string id = nodeSection->readString( "identifier" );
    if (id.length() > 3 && id.substr( 0, 3 ) == "HP_")
    {
        hardPoints.insert( id );
    }

    BW::vector<DataSectionPtr> nodes;
    nodeSection->openSections( "node", nodes );
    for (BW::vector<DataSectionPtr>::iterator i = nodes.begin(); i != nodes.end(); ++i)
    {
        extractHardPoints( *i, hardPoints );
    }
}
```

判定条件:节点名以 `HP_` 开头(长度 > 3)即视为硬点。

### 9.3 硬点完整性校验

L674-686 校验模型是否包含所有必需硬点:

```cpp
BW::set<BW::string> visualHardPoints;
extractHardPoints( visualSection->openSection( "node" ), visualHardPoints );

for (BW::set<BW::string>::iterator i = hardPoints_.begin(); i != hardPoints_.end(); ++i)
{
    if (!visualHardPoints.count(*i))
    {
        good = false;
        addError( "Missing hard point %s", (*i).c_str() );
    }
}
```

`hardPoints_` 是规则配置中定义的必需硬点集合(通过 `recursiveReadStrings` 累加自父规则)。若模型缺少任何必需硬点,报错。

### 9.4 硬点合法性校验

L689-712 校验模型是否含未知硬点(仅在 `checkHardPoints_ = true` 时):

```cpp
if (checkHardPoints_)
{
    for (BW::set<BW::string>::iterator i = visualHardPoints.begin();
         i != visualHardPoints.end(); ++i)
    {
        if (!hardPoints_.count(*i))
        {
            // Check for a well formed flash HP
            if ((*i).length() == 10 && (*i).substr(0, 8) == "HP_flash"
                && isdigit((*i)[8]) && isdigit((*i)[9]))
            {
                continue;
            }

            if ((*i) == "HP_flash")
                continue;

            good = false;
            addError( "Unknown hard point %s", (*i).c_str() );
        }
    }
}
```

校验逻辑:

1. 遍历模型中的所有硬点;
2. 若硬点不在 `hardPoints_` 白名单中,报错;
3. **例外**:`HP_flashXX`(XX 为两位数字)和 `HP_flash` 始终合法(Flash 动画硬点采用动态命名)。

`HP_flash01`、`HP_flash02` 等用于挂载 Flash UI 元素,数量不固定,因此无法预先在白名单中列出,采用模式匹配豁免。

---

## 十、三角形计数检查

### 10.1 checkTriangleCount 实现

`checkTriangleCount`(`visual_checker.cpp` L772-802)从 `.primitives` 文件统计三角形数量:

```cpp
bool VisualChecker::checkTriangleCount( DataSectionPtr spPrims )
{
    uint32 count = 0;

    DataSectionIterator it = spPrims->begin();
    while ( it != spPrims->end() )
    {
        DataSectionPtr pSection = *it++;

        if ( endsWith( pSection->sectionName(), "indices" ) )
        {
            Moo::IndexHeader* ih = (Moo::IndexHeader*)pSection->asBinary()->data();
            count += ih->nIndices_ / 3;
        }
    }

    if ( count > maxTriangles_ && maxTriangles_ != 0 )
    {
        addError( "Too many triangles (%d), must be less than %d", count, maxTriangles_ );
        return false;
    }

    if ( count < minTriangles_ )
    {
        addError( "Too few triangles (%d), must be at least %d", count, minTriangles_ );
        return false;
    }

    return true;
}
```

### 10.2 三角形统计逻辑

1. 遍历 `.primitives` 文件的所有 section;
2. 找到名为 `*indices` 的 section(如 `indices`、`indices3` 等);
3. 读取 `Moo::IndexHeader` 结构,获取索引数量;
4. 三角形数 = 索引数 / 3(每三角形 3 个顶点索引)。

`Moo::IndexHeader` 是 BigWorld 图形库(`moo`)定义的索引缓冲区头,包含 `nIndices_` 字段。

### 10.3 顶点格式识别

`visual_checker.cpp` L748-768 的 `vertexSize` 函数(虽未在 `check` 中直接调用)展示了顶点格式识别:

```cpp
typedef BW::map<BW::string, int> VertexSizes;
int vertexSize( const BW::string& format )
{
    static VertexSizes vs;
    if (vs.size() == 0)
    {
        vs["xyznuv"] = sizeof( Moo::VertexXYZNUV );
        vs["xyznduv"] = sizeof( Moo::VertexXYZNDUV );
        vs["xyznuvtb"] = sizeof( Moo::VertexXYZNUV );
        vs["xyznuvi"] = sizeof( Moo::VertexXYZNUVI );
        vs["xyznuvitb"] = sizeof( Moo::VertexXYZNUVITB );
        vs["xyznuviiiww"] = sizeof( Moo::VertexXYZNUVIIIWW );
        vs["xyznuviiiwwtb"] = sizeof( Moo::VertexXYZNUVIIIWWTB );
    }
    VertexSizes::iterator it = vs.find( format );
    if (it != vs.end())
    {
        return it->second;
    }

    return -1;
}
```

格式命名约定:

| 格式 | 含义 |
|------|------|
| `xyznuv` | 位置 + 法线 + 纹理坐标 |
| `xyznduv` | 位置 + 法线 + 颜色 + 纹理坐标 |
| `xyznuvtb` | + 切线 + 副切线(法线贴图) |
| `xyznuvi` | + 索引(骨骼动画) |
| `xyznuvitb` | + 索引 + 切线 + 副切线 |
| `xyznuviiiww` | + 3 索引 + 3 权重(多骨骼动画) |
| `xyznuviiiwwtb` | + 3 索引 + 3 权重 + 切线 + 副切线 |

此函数可能是历史遗留(早期版本可能有顶点大小检查),当前 `check` 方法未使用。

---

## 十一、visual_rules.xml 配置格式

### 11.1 完整示例

```xml
<root>
    <!-- 默认规则 -->
    <rule>
        <identifier>default</identifier>
        <path></path>
        <filespec></filespec>
        <exportAs>normal</exportAs>
        <minSize>0.1 0.1 0.1</minSize>
        <maxSize>100 100 100</maxSize>
        <minTriangles>0</minTriangles>
        <maxTriangles>5000</maxTriangles>
        <maxHierarchyDepth>10</maxHierarchyDepth>
        <portals>false</portals>
        <checkUnknownHardPoints>false</checkUnknownHardPoints>
    </rule>

    <!-- 角色规则 -->
    <rule>
        <identifier>character</identifier>
        <path>objects/characters/</path>
        <filespec></filespec>
        <parent>default</parent>
        <maxTriangles>3000</maxTriangles>
        <maxHierarchyDepth>15</maxHierarchyDepth>
        <checkUnknownHardPoints>true</checkUnknownHardPoints>
        <hardPoint>HP_Head</hardPoint>
        <hardPoint>HP_Body</hardPoint>
    </rule>

    <!-- 英雄规则 -->
    <rule>
        <identifier>hero</identifier>
        <path>objects/characters/heroes/</path>
        <filespec>hero_*</filespec>
        <parent>character</parent>
        <maxTriangles>2000</maxTriangles>
        <hardPoint>HP_Weapon_Right</hardPoint>
        <hardPoint>HP_Weapon_Left</hardPoint>
    </rule>

    <!-- 室内场景规则 -->
    <rule>
        <identifier>indoor</identifier>
        <path>scenes/indoor/</path>
        <filespec></filespec>
        <parent>default</parent>
        <portals>true</portals>
        <portalSnap>0.5 0.5 0.5</portalSnap>
        <portalDistance>1.0</portalDistance>
        <portalOffset>0.5</portalOffset>
        <maxTriangles>10000</maxTriangles>
    </rule>
</root>
```

### 11.2 字段说明

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `identifier` | string | (无) | 规则标识,用于 `parent` 引用 |
| `path` | string | (无) | 目录前缀,匹配条件 |
| `filespec` | string | (空) | 文件名通配符,空表示匹配所有 |
| `parent` | string | (无) | 父规则 identifier,用于继承 |
| `exportAs` | string | `normal` | 导出建议:normal/static/static with nodes |
| `minSize` | Vector3 | (0,0,0) | 包围盒最小尺寸(0 表示不检查) |
| `maxSize` | Vector3 | (0,0,0) | 包围盒最大尺寸(0 表示不检查) |
| `minTriangles` | int | 0 | 最小三角形数 |
| `maxTriangles` | int | 0 | 最大三角形数(0 表示不检查) |
| `maxHierarchyDepth` | int | 0 | 节点树最大深度(0 表示不检查) |
| `portals` | bool | false | 是否必须有 portal |
| `portalSnap` | Vector3 | (0,0,0) | Portal 吸附网格 |
| `portalDistance` | float | 0 | Portal 到原点距离的倍数 |
| `portalOffset` | float | 0 | Portal 中心偏移的倍数 |
| `checkUnknownHardPoints` | bool | false | 是否禁止未知硬点 |
| `hardPoint` | string (多个) | (无) | 必需硬点列表(可重复) |

### 11.3 规则继承示例

`hero` 规则继承 `character`,`character` 继承 `default`。最终 `hero` 规则的属性:

| 属性 | 来源 | 值 |
|------|------|-----|
| `minSize` | default | (0.1, 0.1, 0.1) |
| `maxSize` | default | (100, 100, 100) |
| `minTriangles` | default | 0 |
| `maxTriangles` | hero(覆盖) | 2000 |
| `maxHierarchyDepth` | character(覆盖) | 15 |
| `portals` | default | false |
| `checkUnknownHardPoints` | character(覆盖) | true |
| `hardPoint` | character + hero(累加) | HP_Head, HP_Body, HP_Weapon_Right, HP_Weapon_Left |

---

## 十二、与其他模块的依赖关系

### 12.1 依赖关系图

```
                ┌──────────────────────────┐
                │   resourcechecker.lib    │
                └────────────┬─────────────┘
                             │
        ┌────────────────────┼────────────────────────┐
        │                    │                        │
        ▼                    ▼                        ▼
┌───────────────┐   ┌────────────────┐    ┌────────────────────┐
│   resmgr      │   │   math         │    │    moo             │
│ - DataSection │   │ - Vector3      │    │ - VertexFormats    │
│ - BWResource  │   │ - BoundingBox  │    │ - PrimitiveFile    │
│ - Primitive   │   │ - PlaneEq      │    │ - IndexHeader      │
│   File        │   │ - Matrix       │    │                    │
└───────────────┘   └────────────────┘    └────────────────────┘
        │                    │                        │
        │                    │                        │
        ▼                    ▼                        ▼
┌───────────────┐   ┌────────────────┐    ┌────────────────────┐
│   cstdmf      │   │  shlwapi       │    │  Windows API       │
│ - LogMsg      │   │ - PathMatchSpec│    │ - MessageBox       │
│ - bw_string   │   │                │    │ - GetForeground    │
│ - bw_set      │   │                │    │   Window           │
└───────────────┘   └────────────────┘    └────────────────────┘
        ▲
        │ 调用
┌─────────────────────────────────────────────────────────────────┐
│                      导出器(调用方)                            │
│   ┌───────────────┐  ┌───────────────┐  ┌───────────────┐     │
│   │visualexporter │  │mayavisual     │  │animation      │     │
│   │(3ds Max)      │  │exporter(Maya) │  │exporter       │     │
│   └───────────────┘  └───────────────┘  └───────────────┘     │
└─────────────────────────────────────────────────────────────────┘
```

### 12.2 依赖的引擎模块

| 模块 | 用途 | 关键类/函数 |
|------|------|------------|
| `resmgr` | 资源管理 | `BWResource`, `DataSection`, `PrimitiveFile` |
| `math` | 数学运算 | `Vector3`, `BoundingBox`, `PlaneEq`, `Matrix` |
| `moo` | 图形数据结构 | `Moo::IndexHeader`, `Moo::VertexXYZNUV` 等顶点格式 |
| `cstdmf` | 基础工具 | `BW::string`, `BW::set`, `BW::vector`, `LogMsg` |

### 12.3 依赖的 Windows API

| API | 用途 |
|-----|------|
| `PathMatchSpec` | 文件名通配符匹配(`shlwapi.h`) |
| `MessageBox` | 规则文件缺失提示 |
| `GetForegroundWindow` | 获取 MessageBox 父窗口 |

### 12.4 被调用方(导出器)的典型用法

```cpp
// 导出器中的典型调用模式
VisualChecker checker( visualName );  // 构造时加载规则
if ( !checker.check( visualSection, primResName ) )
{
    BW::string errors = checker.errorText();
    // 显示错误给美术
    MessageBox( NULL, errors.c_str(), "Visual Export Errors", MB_ICONERROR );
    return false;  // 导出失败
}

// 检查 typeName 和 exportAs 决定导出方式
BW::string typeName = checker.typeName();
BW::string exportAs = checker.exportAs();
if ( exportAs == "static" )
{
    exportAsStatic( visualSection );
}
else if ( exportAs == "static with nodes" )
{
    exportAsStaticWithNodes( visualSection );
}
else
{
    exportAsNormal( visualSection );
}
```

---

## 十三、关键代码片段(带行号)

### 13.1 构造函数:规则加载与匹配(visual_checker.cpp L187-318)

```cpp
// visual_checker.cpp L187
VisualChecker::VisualChecker( const BW::string& visualName, bool cacheRules,
                              bool snapVertices )
    : minSize_( Vector3::zero() )
    , maxSize_( Vector3::zero() )
    , minTriangles_( 0 )
    , maxTriangles_( 0 )
    , maxHierarchyDepth_( 0 )
    , snapVertices_(snapVertices)
    , portals_( false )
    , portalSnap_( Vector3::zero() )
    , portalDistance_( 0.f )
    , portalOffset_( 0.f )
    , checkHardPoints_( false )
    , typeName_( UNKNOWN_TYPE_NAME )
    , exportAs_( "normal" )
{
    // 跳过碰撞 visual (L203)
    if (visualName.find( "_bsp." ) != BW::string::npos)
    {
        return;
    }

    DataSectionPtr rulesSection;  // L208
    if (cacheRules)
    {
        rulesSection = BWResource::openSection( "visual_rules.xml" );
    }
    else
    {
        if (BWResource::fileExists( "visual_rules.xml" ) )
            rulesSection = BWResource::openSection( "visual_rules.xml" );
    }

    if (!rulesSection)  // L220
    {
        if ( ! LogMsg::automatedTest() )
        {
            MessageBox( GetForegroundWindow(), ... );
        }
        addError("VisualChecker::VisualChecker - Unable to find visual_rules.xml file.");
        return;
    }

    BW::string visualPath = BWResource::getFilePath( visualName );  // L234
    BW::string visualFilename = BWResource::getFilename( visualName ).to_string();

    BW::vector<DataSectionPtr> matchingRules;  // L237
    BW::vector<DataSectionPtr> rules;
    rulesSection->openSections( "rule", rules );
    for (BW::vector<DataSectionPtr>::iterator i = rules.begin(); i != rules.end(); ++i)
    {
        BW::string rulePath = toLower( (*i)->readString( "path" ) );
        if ( visualPath.find( rulePath ) != BW::string::npos )
            matchingRules.push_back( *i );
    }

    std::stable_sort( matchingRules.begin(), matchingRules.end(), ruleSectionCompare );  // L248

    DataSectionPtr ruleSection;  // L251
    for (BW::vector<DataSectionPtr>::iterator i = matchingRules.begin();
         i != matchingRules.end(); ++i)
    {
        BW::string filePattern = toLower( (*i)->readString( "filespec" ) );
        if (filePattern.empty())  // L257
        {
            ruleSection = (*i);
            break;
        }
        if ( ::PathMatchSpec( visualFilename.c_str(), filePattern.c_str() ) )  // L266
        {
            ruleSection = (*i);
            break;
        }
    }

    if (!ruleSection)  // L275
        return;

    BW::map<BW::string, DataSectionPtr> rulesById;  // L279
    for (BW::vector<DataSectionPtr>::iterator i = rules.begin(); i != rules.end(); ++i)
    {
        BW::string id = (*i)->readString( "identifier" );
        if (!id.empty())
            rulesById[id] = *i;
    }

    typeName_ = ruleSection->readString( "identifier" );  // L287
    exportAs_ = recursiveReadString( "exportAs", rulesById, ruleSection, exportAs_ );
    ...

    minSize_ = recursiveReadVector3( "minSize", rulesById, ruleSection, minSize_ );  // L306
    maxSize_ = recursiveReadVector3( "maxSize", rulesById, ruleSection, maxSize_ );
    minTriangles_ = recursiveReadInt( "minTriangles", rulesById, ruleSection, minTriangles_ );
    maxTriangles_ = recursiveReadInt( "maxTriangles", rulesById, ruleSection, maxTriangles_ );
    maxHierarchyDepth_ = recursiveReadInt( "maxHierarchyDepth", rulesById, ruleSection, maxHierarchyDepth_ );
    portals_ = recursiveReadBool( "portals", rulesById, ruleSection, portals_ );
    portalSnap_ = recursiveReadVector3( "portalSnap", rulesById, ruleSection, portalSnap_ );
    portalDistance_ = recursiveReadFloat( "portalDistance", rulesById, ruleSection, portalDistance_ );
    portalOffset_ = recursiveReadFloat( "portalOffset", rulesById, ruleSection, portalOffset_ );
    checkHardPoints_ = recursiveReadBool( "checkUnknownHardPoints", rulesById, ruleSection, checkHardPoints_ );

    recursiveReadStrings( "hardPoint", rulesById, ruleSection, hardPoints_ );  // L317
}
```

### 13.2 规则排序比较函数(visual_checker.cpp L63-72)

```cpp
// visual_checker.cpp L63
bool ruleSectionCompare(const DataSectionPtr a, DataSectionPtr b)
{
    size_t aPathSize = a->readString( "path" ).size();
    size_t bPathSize = b->readString( "path" ).size();

    if (aPathSize == bPathSize)
        return a->readString( "filespec" ).size() > b->readString( "filespec" ).size();
    else
        return aPathSize > bPathSize;
}
```

### 13.3 递归读取函数示例(visual_checker.cpp L92-108)

```cpp
// visual_checker.cpp L92
BW::string recursiveReadString(const BW::string& key,
        const BW::map<BW::string, DataSectionPtr>& sections,
        DataSectionPtr curSection,
        const BW::string& def)
{
    DataSectionPtr ds = curSection->openSection( key );
    if (ds)
        return ds->asString();

    BW::string parent = curSection->readString( "parent" );

    BW::map<BW::string, DataSectionPtr>::const_iterator i = sections.find( parent );
    if (i != sections.end())
        return recursiveReadString( key, sections, i->second, def );

    return def;
}
```

### 13.4 check 方法主体(visual_checker.cpp L437-740)

```cpp
// visual_checker.cpp L437
bool VisualChecker::check( DataSectionPtr visualSection, const BW::string& primResName )
{
    errors_.clear();
    bool good = true;

    if (!visualSection)  // L443
    {
        addError( "Invalid visual, null DataSection" );
        return false;
    }

    DataSectionPtr spPrims = PrimitiveFile::get( primResName );  // L449
    if (!spPrims)
    {
        addError( "Invalid primitive file, file not found" );
        return false;
    }

    Vector3 bbMin = visualSection->readVector3( "boundingBox/min" );  // L456
    Vector3 bbMax = visualSection->readVector3( "boundingBox/max" );
    Vector3 size = bbMax - bbMin;

    if ((minSize_.x > 0.f && minSize_.x > size.x) ||  // L461
        (minSize_.y > 0.f && minSize_.y > size.y) ||
        (minSize_.z > 0.f && minSize_.z > size.z))
    {
        good = false;
        addError( "Too small, must be at least %f, %f, %f", minSize_.x, minSize_.y, minSize_.z );
    }

    if ((maxSize_.x > 0.f && maxSize_.x < size.x) ||  // L470
        ...
    {
        good = false;
        addError( "Too big, must be no bigger than %f, %f, %f", maxSize_.x, maxSize_.y, maxSize_.z );
    }

    if ( !checkTriangleCount( spPrims ) )  // L479
    {
        good = false;
    }

    uint32 hierarchyDepth = maxNodeDepth( visualSection->openSection( "node" ) );  // L485
    if (maxHierarchyDepth_ != 0 && hierarchyDepth > maxHierarchyDepth_ )
    {
        good = false;
        addError( "Node hierarchy too deep, depth must be %d nodes or less", maxHierarchyDepth_ );
    }

    // Portal 校验 (L496-662,详见第八节)
    ...

    // 节点重名检查 (L664-672)
    BW::set<BW::string> visualNodes;
    BW::set<BW::string> nodeDuplicates;
    checkDuplicateNodeNames( visualSection->openSection( "node" ), visualNodes, nodeDuplicates );
    for( BW::set<BW::string>::iterator it = nodeDuplicates.begin();
         it != nodeDuplicates.end(); ++it )
    {
        good = false;
        addError( "Duplicate node name %s", (*it).c_str() );
    }

    // 硬点校验 (L674-712,详见第九节)
    BW::set<BW::string> visualHardPoints;
    extractHardPoints( visualSection->openSection( "node" ), visualHardPoints );
    ...

    // 纹理命名检查 (L714-737)
    typedef BW::vector<DataSectionPtr> DSVec;
    DSVec renderSets;
    visualSection->openSections( "renderSet", renderSets );
    for (uint32 rs = 0; rs < renderSets.size(); rs++)
    {
        DSVec geometries;
        renderSets[rs]->openSections( "geometry", geometries );
        for (uint32 g = 0; g < geometries.size(); g++)
        {
            DSVec pgs;
            geometries[g]->openSections( "primitiveGroup", pgs );
            for (uint32 pg = 0; pg < pgs.size(); pg++)
            {
                BW::string textureName = pgs[pg]->readString( "material/textureormfm" );
                BW::string::size_type pos = textureName.find_last_of( " " );
                if (pos != BW::string::npos)
                {
                    good = false;
                    addError( "Illegal texture name \"%s\", no spaces in name or path allowed\n",
                              textureName.c_str() );
                }
            }
        }
    }

    return good;
}
```

### 13.5 Portal 共面性与朝向校验(visual_checker.cpp L558-584)

```cpp
// visual_checker.cpp L558
PlaneEq p;
bool hasPlaneEq = false;
for (uint j = 0; j < (points.size() - 2); j++)
{
    p.init( points[ j + 2 ], points[ j + 1 ], points[ j ] );

    if (!((p.normal()[0] == 0) && (p.normal()[1] == 0) && (p.normal()[2] == 0)))
    {
        hasPlaneEq = true;
        break;
    }
}

if (!hasPlaneEq)
{
    good = false;
    addError( "Portal is non planar" );
    continue;
}

BoundingBox bb(bbMin, bbMax);  // L578
if (p.d() - bb.centre().dotProduct(p.normal()) > 0.f)
{
    good = false;
    addError( "Portal is facing outwards" );
    continue;
}
```

### 13.6 硬点合法性校验(visual_checker.cpp L689-712)

```cpp
// visual_checker.cpp L689
if (checkHardPoints_)
{
    for (BW::set<BW::string>::iterator i = visualHardPoints.begin();
         i != visualHardPoints.end(); ++i)
    {
        if (!hardPoints_.count(*i))
        {
            // Check for a well formed flash HP
            if ((*i).length() == 10 && (*i).substr(0, 8) == "HP_flash"
                && isdigit((*i)[8]) && isdigit((*i)[9]))
            {
                continue;
            }

            if ((*i) == "HP_flash")
                continue;

            good = false;
            addError( "Unknown hard point %s", (*i).c_str() );
        }
    }
}
```

### 13.7 addError 与 errorText(visual_checker.cpp L805-832)

```cpp
// visual_checker.cpp L805
void VisualChecker::addError( const char * format, ... )
{
    va_list argPtr;
    va_start( argPtr, format );

    char buf[4096];
    _vsnprintf( buf, sizeof(buf), format, argPtr );
    buf[sizeof( buf ) - 1] = '\0';

    errors_.push_back( BW::string( buf ) );

    va_end(argPtr);
}

BW::string VisualChecker::errorText()
{
    BW::string s;
    BW::vector<BW::string>::iterator i = errors_.begin();
    for (; i != errors_.end(); ++i)
    {
        if (i != errors_.begin())
            s += '\n';

        s += *i;
    }

    return s;
}
```

`addError` 使用 `va_list` 支持变参格式化(类似 `printf`),缓冲区 4096 字节,确保溢出时截断而非崩溃。`errorText` 用换行符连接所有错误,便于导出器一次性显示。

---

## 十四、设计亮点与注意事项

### 14.1 设计亮点

#### 14.1.1 配置驱动的规则引擎

`VisualChecker` 的核心价值在于"**配置驱动**":所有校验规则通过 `visual_rules.xml` 定义,无需修改代码或重编译。美术团队可自行调整规则(如放宽三角形上限),工具链自动适应。这是 BigWorld "数据驱动"哲学在工具链中的体现。

#### 14.1.2 规则继承与累加

`parent` 字段 + `recursiveRead*` 函数家族实现了类似 CSS 的规则继承:

- **标量属性覆盖**:子规则的 `maxTriangles` 覆盖父规则;
- **集合属性累加**:`hardPoint` 列表在继承链上累加(`recursiveReadStrings` 的特殊行为)。

这避免了在子规则中重复配置父规则的全部硬点,提高可维护性。

#### 14.1.3 多级优先级匹配

规则匹配采用"**目录长度优先 + 文件名通配符长度优先**"的双级优先级(`ruleSectionCompare`),配合稳定排序,确保:

1. 更具体的目录规则优先(如 `objects/characters/heroes/` > `objects/`);
2. 同目录下更具体的文件名规则优先(如 `hero_boss*` > `hero_*`);
3. 同优先级时 XML 中的顺序决定。

这种匹配机制类似于 HTTP 路由的最长前缀匹配,语义清晰。

#### 14.1.4 浮点安全的倍数检查

`isMultipleOf`(`visual_checker.cpp` L359-364)使用 `epsilon` 容差判断浮点倍数:

```cpp
float diff = fabsf( fmodf( v, m ) );
return (diff < epsilon || diff - m > -epsilon);
```

`fmodf` 的结果在 `[0, m)` 区间,但浮点误差可能使其接近 `m`(如 `0.999999`)。`diff - m > -epsilon` 等价于 `diff > m - epsilon`,捕获此情况。这是浮点比较的标准技巧。

#### 14.1.5 自动化测试感知

构造函数中 `LogMsg::automatedTest()` 检查(`visual_checker.cpp` L222):

```cpp
if ( ! LogMsg::automatedTest() )
{
    MessageBox( ... );
}
```

自动化测试模式下不弹窗(避免阻塞测试),仅记录错误。这是 BigWorld 工具链对 CI/CD 友好的设计。

#### 14.1.6 HP_flash 模式豁免

硬点合法性校验中,`HP_flashXX`(两位数字)和 `HP_flash` 被豁免(`visual_checker.cpp` L697-705):

```cpp
if ((*i).length() == 10 && (*i).substr(0, 8) == "HP_flash"
    && isdigit((*i)[8]) && isdigit((*i)[9]))
{
    continue;
}
if ((*i) == "HP_flash")
    continue;
```

Flash UI 元素的硬点采用动态命名(因数量不固定),无法预先在白名单中列出。模式豁免平衡了严格性与灵活性。

### 14.2 注意事项

#### 14.2.1 平台依赖:PathMatchSpec

`PathMatchSpec` 是 Windows Shell API(`shlwapi.h`),非跨平台。在 Linux/macOS 上编译 `resourcechecker` 需替换为 `fnmatch`(POSIX)或 `boost::filesystem::path` 等。

#### 14.2.2 MessageBox 阻塞

构造函数中规则文件缺失时调用 `MessageBox`(`visual_checker.cpp` L224-227),会阻塞当前线程直到用户点击。在批量导出场景(如构建脚本)中,这可能导致构建挂起。建议在 CI 环境中使用 `LogMsg::automatedTest()` 模式。

#### 14.2.3 snapVertices_ 未实际使用

构造参数 `snapVertices` 存储为 `snapVertices_`(`visual_checker.cpp` L193),但 `check` 方法中未实际使用。这可能是个未完成的功能(原计划用于顶点吸附校验,但 Portal 吸附已通过 `portalSnap_` 独立实现),保留为接口兼容。

#### 14.2.4 toLower 的简单实现

`toLower`(`visual_checker.cpp` L27-39)是手动实现的 ASCII 小写转换:

```cpp
BW::string toLower( const BW::string &s )
{
    BW::string newString = s;
    for( uint32 i = 0; i < newString.length(); i++ )
    {
        if( newString[ i ] >= 'A' && newString[ i ] <= 'Z' )
        {
            newString[ i ] = newString[ i ] + 'a' - 'A';
        }
    }
    return newString;
}
```

仅处理 ASCII 字母,不支持 Unicode。对于非 ASCII 路径(如中文目录)的大小写不敏感匹配会失效。但 BigWorld 资源路径通常为 ASCII,问题不显现。

#### 14.2.5 ERROR_EPSILON 的奇怪值

Portal 吸附校验使用 `ERROR_EPSILON = 1.0f / 2196.f`(`visual_checker.cpp` L613),而 `isMultipleOf` 使用 `1.0f / 8192.f`。`2196` 不是 2 的幂,可能是历史笔误(应为 `2048` 或 `4096`)。但该值已用于生产环境,改动可能导致误报。

#### 14.2.6 错误缓冲区 4096 字节

`addError`(`visual_checker.cpp` L810)使用 4096 字节栈缓冲区:

```cpp
char buf[4096];
_vsnprintf( buf, sizeof(buf), format, argPtr );
buf[sizeof( buf ) - 1] = '\0';
```

`_vsnprintf` 在缓冲区不足时返回 -1,但不写入超过 `sizeof(buf)` 的数据。最后一行 `buf[sizeof(buf) - 1] = '\0'` 确保 null 终止。对于超长错误消息(如包含长纹理路径),会被截断。

#### 14.2.7 maxNodeDepth 的空指针风险

`maxNodeDepth`(`visual_checker.cpp` L422-434)未检查 `nodeSection` 是否为空:

```cpp
uint32 maxNodeDepth( DataSectionPtr nodeSection )
{
    uint32 maxDepth = 0;

    BW::vector<DataSectionPtr> nodes;
    nodeSection->openSections( "node", nodes );  // 若 nodeSection 为空,崩溃
    ...
}
```

但调用方 `check` 中 `visualSection->openSection( "node" )` 可能返回空(visual 无节点)。`DataSectionPtr` 是智能指针,`openSections` 在空指针上可能崩溃。实际使用中,`maxHierarchyDepth_ != 0` 的检查(L487)在规则未配置时跳过,降低了风险。

#### 14.2.8 checkDuplicateNodeNames 的低效查找

`checkDuplicateNodeNames`(`visual_checker.cpp` L380)使用 `std::find` 在 `BW::set` 中线性查找:

```cpp
if (std::find( nodeNames.begin(), nodeNames.end(), id ) == nodeNames.end())
{
    nodeNames.insert( id );
}
else
{
    duplicates.insert( id );
}
```

`std::set::find` 是 O(log n),但 `std::find` 是 O(n)。这里应使用 `nodeNames.find(id)`(成员函数,利用二叉搜索树)。当前实现是 O(n²) 复杂度,对于节点众多的模型(如带数千骨骼的角色)可能性能问题。

### 14.3 与导出器的协作

`VisualChecker` 不直接决定导出是否继续,而是返回 `bool` 和错误文本,由导出器决定:

| 导出器 | 典型行为 |
|--------|---------|
| `visualexporter` | 显示错误对话框,导出失败 |
| `mayavisualexporter` | 在 Maya 状态栏显示错误,导出失败 |
| `animationexporter` | 仅警告,继续导出(动画可独立于 visual) |

`VisualChecker` 还提供 `typeName()` 和 `exportAs()`,导出器据此选择导出方式:

- `exportAs = "static"`:导出为静态网格(无骨骼动画);
- `exportAs = "static with nodes"`:静态网格但保留节点树(用于挂载);
- `exportAs = "normal"`:完整导出(含动画)。

### 14.4 扩展性

添加新的校验维度需:

1. 在 `visual_rules.xml` 添加新字段(如 `<maxBones>50</maxBones>`);
2. 在 `VisualChecker` 类添加成员变量(如 `uint32 maxBones_`);
3. 在构造函数添加 `recursiveReadInt( "maxBones", ... )`;
4. 在 `check` 方法添加校验逻辑;
5. 重新编译导出器。

由于 `VisualChecker` 是库而非脚本,扩展需重新编译。这是与 `process_defs`(Python 侧扩展)的主要差异。

---

## 附录 A:常见问题澄清

### A.1 resourcechecker 是独立工具吗?

**不是**。`resourcechecker` 是一个静态库(`.lib`),被 `visualexporter`、`mayavisualexporter`、`animationexporter` 等导出器链接。无独立 `main` 入口,不能单独运行。

### A.2 visual_rules.xml 应该放在哪里?

放在 `BWResource` 的搜索路径根目录下。典型位置:

- `<资源根>/visual_rules.xml`
- 工程的 `res/` 目录

`BWResource::openSection( "visual_rules.xml" )` 会在所有搜索路径中查找。

### A.3 如何为新资源类型添加规则?

1. 在 `visual_rules.xml` 添加 `<rule>` 元素;
2. 设置 `path` 为资源目录前缀;
3. 设置 `filespec` 为文件名通配符;
4. 配置所需的校验字段;
5. 可选:设置 `parent` 继承其他规则。

无需修改代码,规则立即生效。

### A.4 为什么 _bsp. 文件不校验?

`_bsp.` 文件是碰撞几何(BSP = Binary Space Partitioning),仅用于物理碰撞,不渲染。它们通常由 `.visual` 自动生成,无需美术校验。构造函数 L203-206 直接跳过。

### A.5 checkHardPoints_ 与 hardPoints_ 的关系?

- `hardPoints_`:**必需硬点白名单**(规则配置的 `<hardPoint>` 列表);
- `checkHardPoints_`:**是否启用未知硬点检查**(规则配置的 `<checkUnknownHardPoints>` 布尔)。

校验逻辑:

1. **完整性**:模型必须包含 `hardPoints_` 中的所有硬点(始终启用);
2. **合法性**:若 `checkHardPoints_ = true`,模型不能有 `hardPoints_` 之外的硬点(除 `HP_flash*` 豁免)。

### A.6 Portal 校验为何如此复杂?

Portal 是 BigWorld 室内场景的核心,连接不同的 chunk。Portal 错误会导致:

- 玩家穿墙(碰撞失效);
- 渲染漏洞(看到场景外);
- 流式加载失败(chunk 切换异常)。

因此 Portal 校验涵盖共面性、朝向、吸附、距离、偏移五个维度,确保 portal 几何精确对齐。

### A.7 如何调试 VisualChecker?

1. 在导出器中添加 `printf( "%s", checker.errorText().c_str() );` 输出所有错误;
2. 临时修改 `visual_rules.xml` 放宽规则,逐步定位问题;
3. 检查 `typeName()` 和 `exportAs()` 是否符合预期(确认规则匹配正确);
4. 使用 `LogMsg::automatedTest()` 模式避免 MessageBox 阻塞。

### A.8 VisualChecker 与 VisualExporter 的关系?

`VisualChecker` 是校验库,`VisualExporter` 是导出器(调用方)。导出器在导出前/后调用 `VisualChecker::check`:

- **导出前**:校验源模型(如 3ds Max 场景),拦截低质量资源;
- **导出后**:校验导出的 `.visual` 文件,确保导出过程无误。

### A.9 exportAs 的三个值有何区别?

| 值 | 含义 | 适用场景 |
|----|------|---------|
| `normal` | 完整 visual(含动画、骨骼) | 角色、动态物体 |
| `static` | 静态网格(无节点树) | 简单静态物体(石头、道具) |
| `static with nodes` | 静态网格但保留节点树 | 需要挂载点的静态物体(灯柱、旗帜) |

`static` 体积最小、加载最快;`static with nodes` 允许挂载硬点但无动画;`normal` 支持完整动画。

### A.10 能否跳过 VisualChecker?

理论上可在导出器中注释掉 `VisualChecker::check` 调用,但不建议。这会导致低质量资源进入游戏,引发渲染异常、性能问题、碰撞错误等。正确做法是调整 `visual_rules.xml` 规则,而非跳过校验。

---

## 文档信息

- **文档版本**: 1.0
- **分析对象**: BigWorld Engine 14.4.1 `resourcechecker` 工具
- **源码路径**: `programming/bigworld/tools/resourcechecker/`
- **总代码行数**: ~900 行
- **最后更新**: 2026-06-30
