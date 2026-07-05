# 第4章 资源管理系统 - resmgr

> 资源管理是任何游戏引擎的"中枢神经":模型、纹理、配置、Chunk、脚本……几乎所有上层模块都要通过它来读写数据。BigWorld 把这一职责集中到一个独立的库 `lib/resmgr/` 中,并以 `DataSection` 抽象 + 多文件系统组合 + 缓存监控 的三层架构,把"路径透明、格式无关、懒加载、可缓存"做到了极致。本章将从最基础的概念入手,逐层剖析 resmgr 的设计,直到你能独立读、写、扩展它。

---

## 目录

- [4.1 resmgr 库概述](#41-resmgr-库概述)
- [4.2 DataSection 抽象](#42-datasection-抽象)
- [4.3 多种 Section 实现详解](#43-多种-section-实现详解)
- [4.4 BWResource 单例](#44-bwresource-单例)
- [4.5 MultiFileSystem 多文件系统](#45-multifilesystem-多文件系统)
- [4.6 资源缓存与监控](#46-资源缓存与监控)
- [4.7 高级特性](#47-高级特性)
- [4.8 DataSection 使用示例](#48-datasection-使用示例)
- [4.9 资源系统在引擎中的作用](#49-资源系统在引擎中的作用)
- [4.10 特色实现深度剖析](#410-特色实现深度剖析)
- [4.11 本章小结](#411-本章小结)

---

## 4.1 resmgr 库概述

### 4.1.1 位置与职责

`resmgr` 库位于 `programming/bigworld/lib/resmgr/`,它是 BigWorld 引擎中所有资源访问的统一入口。无论是客户端加载模型、纹理、Chunk,还是服务器读取实体定义、配置文件,亦或是工具链上的资源管线处理,最终都会通过这一层完成。

具体职责可以概括为四点:

1. **统一的资源访问接口**——上层代码不需要关心底层是 XML 文件、二进制文件、目录,还是 zip 压缩包,只需要拿到一个 `DataSectionPtr` 就能读写。
2. **支持多种文件格式**——XML / 二进制 / 打包 / Zip / 目录 五种主要格式,各有适用场景。
3. **虚拟文件系统**——把多个真实目录/zip 文件"叠加"成一个虚拟根,用户只用相对路径访问。
4. **缓存与监控**——LRU 缓存、引用计数普查、文件修改监听,保证性能和正确性。

### 4.1.2 设计理念

resmgr 在设计上有四条贯穿始终的原则:

| 原则 | 含义 | 体现 |
|---|---|---|
| 路径透明 | 用户只写 `res/spaces/fantasydemo/test.model` 这样的相对路径 | `BWResource::openSection` 自动遍历 `BW_RES_PATH` |
| 格式无关 | 同一个 `openSection` 调用,既可打开 XML 也可打开 Zip | `DataSection` 抽象基类 + `DirSection::findChild` 分发 |
| 懒加载 | 不一次性把整个文件读入内存,需要时才解析 | `ZipSection` 只在访问子节点时才读取 zip 内部 |
| 缓存 | 同一个路径反复打开只解析一次 | `DataSectionCache` + `DataSectionCensus` |

### 4.1.3 文件清单

`lib/resmgr/` 目录下大约 60 个文件,可以按功能归类如下(仅列关键文件,完整列表见 `LS lib/resmgr/`):

```
lib/resmgr/
├── datasection.hpp / .cpp          # DataSection 抽象基类(核心)
├── xml_section.hpp / .cpp          # XML 实现
├── bin_section.hpp / .cpp          # 二进制实现
├── dir_section.hpp / .cpp          # 目录实现
├── packed_section.hpp / .cpp       # 打包格式实现
├── zip_section.hpp / .cpp          # Zip 内嵌实现
├── bwresource.hpp / .cpp / .ipp    # BWResource 单例
├── multi_file_system.hpp / .cpp    # 多文件系统组合
├── file_system.hpp                 # IFileSystem 抽象基类
├── unix_file_system.hpp / .cpp     # Unix 平台实现
├── win_file_system.hpp / .cpp      # Windows 平台实现
├── zip_file_system.hpp / .cpp      # Zip 虚拟文件系统
├── primitive_file.hpp / .cpp       # 原始文件访问
├── file_handle_streamer.hpp / .cpp # 文件流式加载
├── file_streamer.hpp               # IFileStreamer 抽象
├── binary_block.hpp / .cpp         # 二进制数据块
├── data_section_cache.hpp / .cpp   # DataSection LRU 缓存
├── data_section_census.hpp / .cpp  # DataSection 普查
├── resource_cache.hpp             # 通用资源缓存模板
├── access_monitor.hpp / .ipp / .cpp # 访问监控
├── resource_modification_listener.hpp / .cpp # 修改监听
├── bundiff.hpp / .cpp / bdiff.hpp / .cpp     # 二进制差分
├── auto_config.hpp / .cpp          # 自动配置
├── hierarchical_config.hpp / .cpp # 层次化配置
├── string_provider.hpp / .cpp     # 字符串本地化
├── xml_special_chars.hpp / .cpp   # XML 特殊字符
├── filename_case_checker.hpp / .cpp # 大小写检查
├── sanitise_helper.hpp / .cpp     # 路径清理
├── quick_file_writer.hpp           # 快速文件写入
├── resource_file_path.hpp / .cpp  # 资源路径解析
├── dataresource.hpp / .cpp        # DataResource 数据资源
├── resmgr_lib.hpp                  # 库统一头文件
├── forward_declarations.hpp        # 前向声明
└── unit_test/                      # 单元测试
```

后面的章节会按"由内到外"的顺序剖析这些文件:先讲 `DataSection` 抽象,再讲它的多个实现,然后是组合它们的 `BWResource` 与 `MultiFileSystem`,最后是各种辅助工具。

---

## 4.2 DataSection 抽象

`DataSection` 是 resmgr 库的灵魂,定义在 `datasection.hpp`。理解了它,就理解了 BigWorld 资源系统的"形态"。

### 4.2.1 设计意图

`DataSection` 的注释(`datasection.hpp:151-171`)写得非常清楚:

> A class that encapsulates a document into hierarchical sections. This is an interface that client code can use to read documents that have a hierarchical structure. The actual implementation of the class is handled by derived classes specialised for each type of document format.

翻译过来就是:`DataSection` 把"文档"抽象成层次化的节点。文档可以是 XML、二进制、目录、Zip 等任何格式,只要子类实现这些虚函数,上层代码就能透明地访问它们。

这本质上是 **策略模式(Strategy Pattern)** + **模板方法模式(Template Method)** 的组合:

- **策略模式**:不同格式的具体行为(怎么读、怎么写、怎么遍历子节点)由子类决定。
- **模板方法**:`DataSection` 提供一批非虚的便利方法(`openSection`、`readBool`、`writeString` 等),它们调用纯虚函数完成通用流程。

### 4.2.2 类继承关系

`DataSection` 自身继承自 `SafeReferenceCount`(支持线程安全的引用计数),并被智能指针 `DataSectionPtr` 包装。子类有五个:

```
SafeReferenceCount
└── DataSection (datasection.hpp)
    ├── XMLSection      (xml_section.hpp)      XML 文本格式
    ├── BinSection     (bin_section.hpp)      二进制格式
    ├── DirSection     (dir_section.hpp)      目录形式
    ├── PackedSection  (packed_section.hpp)   打包二进制格式
    └── ZipSection     (zip_section.hpp)       Zip 压缩包
```

智能指针类型定义在 `datasection.hpp:36-39`:

```cpp
class DataSection;
typedef SmartPointer<DataSection> DataSectionPtr;
```

### 4.2.3 接口分组

`DataSection` 暴露的接口非常多,但可以按职责清晰地分组:

#### (1) 子节点访问(纯虚函数,由子类实现)

```cpp
virtual int countChildren() = 0;
virtual DataSectionPtr openChild( int index ) = 0;
virtual BW::string childSectionName( int index );
virtual DataSectionPtr newSection( const BW::StringRef &tag,
    DataSectionCreator* creator=NULL ) = 0;
virtual DataSectionPtr findChild( const BW::StringRef &tag,
    DataSectionCreator* creator=NULL ) = 0;
virtual void delChild(const BW::StringRef &tag ) = 0;
virtual void delChild(DataSectionPtr pSection) = 0;
virtual void delChildren() = 0;
```

这些是子类**必须**实现的接口。注意 `findChild`(按名字查找)与 `openChild`(按下标查找)是分离的——后者用于线性遍历,前者用于路径解析。

#### (2) 路径式访问(非虚,由模板方法实现)

```cpp
DataSectionPtr openSection( const BW::StringRef &tagPath,
                            bool makeNewSection = false,
                            DataSectionCreator* creator = NULL);
DataSectionPtr openFirstSection( void );
void openSections( const BW::StringRef &tagPath,
    BW::vector<DataSectionPtr> &dest,
    DataSectionCreator* creator = NULL);
bool deleteSection( const BW::StringRef &tagPath );
void deleteSections( const BW::StringRef &tagPath );
```

这一组方法接受 **路径表达式**——形如 `"A/B/C"` 的字符串。实现见 `datasection.cpp:185-233`,核心逻辑是:

```cpp
DataSectionPtr DataSection::openSection( const BW::StringRef & tagPath,
                                bool makeNewSection,
                                DataSectionCreator* creator )
{
    if (tagPath.empty()) return this;
    BW::string::size_type pos = tagPath.find_first_of("/");

    if( pos != BW::string::npos )
    {
        // 递归:先打开路径前缀,再交给子节点
        pChild = this->findChild( tagPath.substr( 0, pos ) );
        if (!pChild && makeNewSection)
            pChild = this->newSection( tagPath.substr( 0, pos ) );
        ...
        return pChild->openSection( tagPath.substr( pastslash ),
            makeNewSection, creator);
    }

    // 最末端:直接 findChild
    pChild = this->findChild(tagPath, creator);
    if(!pChild && makeNewSection)
        pChild = this->newSection(tagPath, creator);
    return pChild;
}
```

这种递归把 `"A/B/C"` 拆成三次 `findChild` 调用,对用户极其方便。`makeNewSection=true` 时,路径上不存在的节点会被自动创建——这是写配置的常用手法。

#### (3) 值的读 / 写(虚 + 模板)

读:

```cpp
virtual bool asBool( bool defaultVal = ... );
virtual int  asInt( int defaultVal = ... );
virtual float asFloat( float defaultVal = ... );
virtual BW::string asString( const BW::StringRef &defaultVal = ..., int flags = ... );
virtual Vector3 asVector3( const Vector3 &defaultVal = ... );
virtual Matrix asMatrix34( const Matrix &defaultVal = ... );
virtual BinaryPtr asBinary();
virtual BW::string asBlob( ... );
// ... 等
```

写:

```cpp
virtual bool setBool( bool value );
virtual bool setInt( int value );
virtual bool setString( const BW::StringRef &value );
virtual bool setVector3( const Vector3 &value );
virtual bool setBinary( BinaryPtr pData );
// ... 等
```

**注意所有 read/as 都提供默认值**——这避免了抛异常,简化了上层代码。`Datatype::DefaultValue<C>::val()`(`datasection.hpp:52-73`)针对每种内建类型提供了"零值",例如 `Vector3::zero()`、`Matrix::identity`(通过模板特化)。

#### (4) 路径式读写(模板方法,内部调用 openSection + as*/be*)

```cpp
bool readBool( const BW::StringRef &tagPath, bool defaultVal = ... );
int  readInt( const BW::StringRef &tagPath, int defaultVal = ... );
BW::string readString( const BW::StringRef &tagPath, ... );
Vector3 readVector3( const BW::StringRef &tag, ... );
// ...

bool writeBool( const BW::StringRef &tagPath, bool value );
bool writeInt( const BW::StringRef &tagPath, int value );
bool writeString( const BW::StringRef &tagPath, const BW::StringRef &value );
// ...
```

这组方法是日常用得最多的。例如:

```cpp
DataSectionPtr pConfig = BWResource::openSection( "scripts/entity.xml" );
int maxHP = pConfig->readInt( "Stats/MaxHP", 100 );
Vector3 spawn = pConfig->readVector3( "SpawnPoint", Vector3(0,0,0) );
```

模板版本(`datasection.hpp:531-546`)进一步把所有类型统一到 `read<C>(path)` / `be<C>(value)`,代码更紧凑:

```cpp
template <class C> C read( const BW::StringRef & tagPath )
{
    DataSectionPtr pSection = this->openSection( tagPath, false );
    if (!pSection) return Datatype::DefaultValue<C>::val();
    return pSection->as<C>();
}
```

#### (5) 数组读写

`readSeq/writeSeq` 模板可以读取/写入同名子节点序列,例如:

```cpp
BW::vector<int> ids;
pConfig->readInts( "Items/id", ids );  // 读取所有 <id> 子节点
```

实现(`datasection.cpp` 中的 `readSeq` 模板)会先 `splitTagPath` 把路径"父-子"切开,然后遍历父节点的所有子节点,挑出名字匹配的子节点取出值。

#### (6) 迭代器

```cpp
typedef DataSectionIterator iterator;
DataSectionIterator begin();
DataSectionIterator end();
```

`DataSectionIterator`(`datasection.hpp:78-99`)的行为与 STL 迭代器一致,内部只是 `(DataSectionPtr, int index)` 的组合。`operator*()` 调用 `openChild(index)`,所以遍历等价于:

```cpp
for (DataSectionIterator it = pSection->begin(); it != pSection->end(); ++it) {
    DataSectionPtr pChild = *it;
    BW::string name = it.tag();  // 等价于 pChild->sectionName()
    ...
}
```

此外还有 `SearchIterator`(`datasection.hpp:197-264`)和 `beginSearch/endOfSearch`,专门用于遍历同名子节点(避免重复 open 全部子节点再过滤)。

### 4.2.4 SmartPointer 与 SafeReferenceCount

`DataSection` 继承自 `SafeReferenceCount`(`cstdmf/smartpointer.hpp`),通过 `SmartPointer<DataSection>`(`DataSectionPtr`)实现引用计数。当引用计数降为 0 时,不会直接 `delete`,而是调用 `DataSection::destroy()`(`datasection.cpp:134-139`):

```cpp
void DataSection::destroy() const
{
    // this will delete this object if it's safe to do so
    DataSectionCensus::tryDestroy( this );
}
```

`DataSectionCensus::tryDestroy` 会先到全局普查表里查一下,如果该 section 是被 census 登记的"命名"section,但 census 中还有别的弱引用持有者,就**不能立即销毁**,而是保留对象。这是 resmgr 处理缓存与外部共享引用的精妙之处——见 4.6 节。

### 4.2.5 DataSectionCreator 工厂

`DataSectionCreator`(`datasection.hpp:140-149`)是一个小抽象,用于显式指定"创建子节点时用哪种格式":

```cpp
class DataSectionCreator
{
public:
    virtual DataSectionPtr create(DataSectionPtr pSection,
                                    const BW::StringRef& tag) = 0;
    virtual DataSectionPtr load(DataSectionPtr pSection,
                                    const BW::StringRef& tag,
                                    BinaryPtr pBinary = NULL) = 0;
};
```

每个具体子类都提供一个静态 `creator()` 方法,例如 `ZipSection::creator()`、`BinSection::creator()`、`XMLSection::creator()`。`openSection`、`newSection` 都接受一个可选的 `creator` 参数,默认为 `NULL` 表示让 `DirSection` 根据文件后缀自动判断。

注释(`datasection.hpp:120-138`)给出了两个典型用法:

```cpp
// 显式以 Zip 格式创建新文件
DataSectionPtr pDS = BWResource::openSection( "new_file.zip", true,
                                            ZipSection::creator() );

// 把一个 XML 文件按二进制格式加载(用于查看原始字节)
DataSectionPtr pDS = BWResource::openSection( "existing_file.xml", false,
                                            BinSection::creator() );
```

### 4.2.6 与 Python 的桥接

`DataSection` 通过 `lib/pyscript/py_data_section.hpp` 暴露到 Python。`PyDataSection`(`py_data_section.hpp:13-117`)继承自 `PyObjectPlus`,内部持有 `DataSectionPtr pSection_`,把所有 `read*` / `write*` / `as*` / `set*` 方法都暴露成 Python 方法:

```cpp
class PyDataSection : public PyObjectPlus
{
    DataSectionPtr pSection() const;
    PY_METHOD_DECLARE( py_readString )
    PY_METHOD_DECLARE( py_readInt )
    PY_METHOD_DECLARE( py_writeString )
    // ... 几十个方法
    PY_RW_ACCESSOR_ATTRIBUTE_DECLARE( BW::string, asString, asString )
    PY_RO_ATTRIBUTE_DECLARE( pSection_->sectionName(), name )
};
```

Python 端的典型用法:

```python
section = BigWorld.ResMgr.openSection( "scripts/entity.xml" )
hp = section.readInt( "Stats/MaxHP", 100 )
name = section.asString
for child in section.keys():
    print(child, section[child].asString)
```

这种"Python 直接持有 C++ 智能指针"的桥接方式,让脚本层和原生层共享同一份缓存和引用计数,避免了重复解析。

---

## 4.3 多种 Section 实现详解

`DataSection` 有五个主要子类,各自对应不同的存储格式。它们各有优劣与适用场景。

### 4.3.1 XMLSection - XML 文本格式

**文件**:`xml_section.hpp` / `xml_section.cpp`

**特点**:
- 可读性极好,适合人手编辑的配置文件。
- 底层使用 tinyxml 解析(参见 `xml_section.cpp` 中的 `WrapperStream` 与 process 系列)。
- 支持属性(attribute)与子节点两种写法,可通过 `shouldReadXMLAttributes()` / `shouldWriteXMLAttributes()` 全局开关切换。
- 名字需经过 `sanitise` 处理,把空格等非法字符替换成 `_xHH_` 之类的转义(`xml_section.hpp:73-79`)。
- 支持宽字符串:`encodeWideString` / `decodeWideString`(`xml_section.hpp:82-84`)把 wstring 编码为 UTF-8 写入 XML。
- 支持 XML 转义序列,可通过 `noXMLEscapeSequence` 关闭(`xml_section.hpp:105-108`),用于嵌入 HTML/CDATA 等。

**典型场景**:
- `scripts/*.xml`(实体定义、技能配置)
- `paths.xml`(资源搜索路径)
- `spaces/<space>/space.settings`(空间设置)
- 任何需要策划/美术手编的配置

**创建方式**:
```cpp
// 从文件创建
XMLSectionPtr pRoot = XMLSection::createFromFile( "config.xml" );
// 从字符串流创建
XMLSectionPtr pRoot = XMLSection::createFromStream( "root", sstream );
// 从二进制块创建
XMLSectionPtr pRoot = XMLSection::createFromBinary( "root", pBin );
```

### 4.3.2 BinSection - 二进制格式

**文件**:`bin_section.hpp` / `bin_section.cpp`

**特点**:
- 单个 `BinaryPtr` 包装一段原始字节,无内部结构。
- 子节点由"内省(introspect)"机制从字节流中懒解析(`bin_section.cpp` 中的 `introspect()`)——但大多数情况下 BinSection 是叶节点,只通过 `asBinary()` / `setBinary()` 读写整块字节。
- 性能极高,无解析开销。
- `canPack() == false`——意味着 BinSection 不会被 `PackedSection::convert` 转换。

**典型场景**:
- 模型几何数据(`.visual/vertices`、`.visual/indices`)
- 纹理像素数据
- 地形高度图(`.cdata/terrain2/heights`)
- 任何体积大、纯二进制的数据

BinSection 经常作为 ZipSection 或 PackedSection 的子节点出现,把"结构 + 原始数据"组合在一起。

### 4.3.3 DirSection - 目录形式

**文件**:`dir_section.hpp` / `dir_section.cpp`

**特点**:
- 每个目录是一个 DirSection 节点。
- 目录的每个文件/子目录是一个子节点。
- `findChild` 时会先查缓存,再查 census,最后调用 `pFileSystem_->getFileTypeEx()` 判断类型,根据类型分发:
  - `FT_DIRECTORY` → 创建子 DirSection
  - `FT_ARCHIVE` → 创建 ZipSection
  - `FT_FILE` → 读入二进制,用 `DataSection::createAppropriateSection` 自动判断 XML/Bin/Packed

**实现关键**(`dir_section.cpp:172-317`):
```cpp
IFileSystem::FileType ft = pFileSystem_->getFileTypeEx( fullName );
switch( ft )
{
    case FT_DIRECTORY: pSection = new DirSection( fullName, pFileSystem_); break;
    case FT_ARCHIVE:   pSection = new ZipSection( fullName, pFileSystem_); break;
    case FT_FILE:
        pBinary = pFileSystem_->readFile( fullName );
        pSection = DataSection::createAppropriateSection( tag, pBinary, true, creator );
        break;
    case FT_NOT_FOUND: break;
}
```

**典型场景**:
- BWResource 的 **rootSection** 就是一个空路径的 DirSection(`bwresource.cpp:403`)。
- 任何"目录 + 文件"混合的工程:`spaces/`、`scripts/`、`shaders/` 等。

DirSection 是资源树最常用的"入口节点",承担了"按路径查文件并加载成 DataSection"的核心职责。

### 4.3.4 PackedSection - 打包二进制格式

**文件**:`packed_section.hpp` / `packed_section.cpp`

**特点**:
- BigWorld 私有的紧凑二进制格式,以"字符串表 + 子节点记录表 + 数据块"三段式组织(`packed_section.hpp:43-79`)。
- 每个子节点是一个 `ChildRecord`(`packed_section.hpp:147-180`),通过 `dataPos_` 高 4 位标识类型(`TYPE_DATA_SECTION` / `TYPE_STRING` / `TYPE_INT` / `TYPE_FLOAT` / `TYPE_BOOL` / `TYPE_BLOB` 等)。
- 字符串(节点名)在文件内只存一份,通过 `StringTable` + `KeyPosType` 索引,体积小。
- 加载时只解析头表,数据块按需读取,**性能介于 XML 和 Zip 之间**。
- 不可写:`save()` 只支持把整个文件转换写出;`newSection`、`delChild` 等修改操作返回失败或未实现。
- 通过 `PackedSection::convert()` 把一个 XML 文件转换为 Packed 格式(`packed_section.hpp:95-99`)。

**典型场景**:
- 已发布客户端的资源(转换后的 `.xml` → Packed 二进制),减小体积并加速加载。
- Asset Pipeline 的"成品"资源。

**适用判断**:
- 需要"读多写少 + 体积敏感" → PackedSection 合适。
- 需要"运行时修改" → 改用 XMLSection 或 ZipSection。

### 4.3.5 ZipSection - Zip 压缩格式

**文件**:`zip_section.hpp` / `zip_section.cpp`

**特点**:
- 把一个 zip 文件当成"虚拟目录",通过 `ZipFileSystem` 读取内部条目。
- 支持 **嵌套 zip**:`x/y.zip/z/a.zip/b/c` 这样的路径完全合法(`zip_file_system.hpp:301-311` 注释)。
- 修改操作支持良好:`newSection` / `delChild` / `save` 都会反映到 zip 文件。
- **懒加载**:打开 ZipSection 不会立即解压整个 zip,只在访问子节点时才读对应条目。
- 支持空文件夹(`FT_ARCHIVE` 内的"目录条目")。

**典型场景**:
- `res.zip`:整个 res 目录的打包发布版,客户端启动时通过 `BWResource::init(paths)` 加载。
- `.cdata` 文件:Chunk 数据档案,本质是 zip,内部存储 `terrain2/heights`、`normals` 等 BinSection。
- 嵌套 zip:发布时把多个 zip 合并到一个总包里。

**创建方式**:
```cpp
DataSectionPtr pZip = BWResource::openSection( "test.zip", true,
                                              ZipSection::creator() );
// 添加子节点(注意 creator 决定子节点格式)
DataSectionPtr pChild = pZip->openSection( "child", true, BinSection::creator() );
pChild->setBinary( pBin );
pZip->save();  // 写回 zip 文件
```

### 4.3.6 各格式对比与选型

| 格式 | 可读性 | 性能 | 体积 | 可写 | 嵌套支持 | 典型用途 |
|---|---|---|---|---|---|---|
| XMLSection | ★★★★★ | ★★ | 大 | ✓ | ✗ | 手编配置 |
| BinSection | ✗ | ★★★★★ | 取决于内容 | ✓ | ✗ | 原始二进制数据 |
| DirSection | ★★★ | ★★★ | 取决于文件 | ✓ | ✗ | 工程根目录 |
| PackedSection | ✗ | ★★★★ | 小 | ✗ | ✗ | 发布版资源 |
| ZipSection | ✗ | ★★★(懒) | 小(压缩) | ✓ | ✓ | 资源打包分发 |

**选型经验**:
- **开发期**:DirSection + XMLSection(可读、可改、可 diff)
- **发布期**:把整个 `res/` 打成 `res.zip`,客户端用 ZipSection 直接读
- **超大体积二进制**:用 BinSection 嵌入 ZipSection,既压缩又有结构
- **需要"分发完整资源"**:嵌套 zip,把多个资源 zip 套进一个总 zip

---

## 4.4 BWResource 单例

`BWResource`(`bwresource.hpp:40-244`)是 resmgr 的对外入口,以单例形式存在(`Singleton<BWResource>`)。它的核心职责是:**接收一个相对资源路径,返回对应的 `DataSectionPtr`**。

### 4.4.1 初始化

`BWResource::init()` 有三个重载(`bwresource.hpp:47-50`):

```cpp
static bool init( int & argc, const char * argv[], bool removeArgs = false );
static bool init( const BW::string& fullPath, bool addAsPath = true );
static bool init( const BW::vector< BW::string > & paths );
```

`init` 内部最终调用 `BWResourceImpl::postAddPaths()`(`bwresource.cpp:296-409`),核心步骤:

1. 创建 `MultiFileSystem`(`fileSystem_ = new MultiFileSystem()`)。
2. 遍历每条路径(`BW_RES_PATH` 用 `;`(Windows)或 `:`(Unix)分隔):
   - 如果路径本身是 `.zip` 文件 → 创建 `ZipFileSystem` 作为 base FS。
   - 如果路径目录下存在 `res.zip` → 也用 `ZipFileSystem`。
   - 否则用 `NativeFileSystem::create(path)`(在 Windows 上是 `WinFileSystem`,Unix 上是 `UnixFileSystem`)。
3. 把每个 base FS 通过 `MultiFileSystem::addBaseFileSystem` 加入。
4. 设置 `DataSectionCache` 大小(默认 100KB,可用环境变量 `BW_CACHE_SIZE` 覆盖)。
5. 创建根节点:`rootSection_ = new DirSection( "", fileSystem_.getObject() )`。

完成之后,引擎其他模块通过 `BWResource::instance().rootSection()` 拿到根,然后通过 `openSection(path)` 任意访问子节点。

### 4.4.2 openSection 的查找流程

最常用的接口是静态方法 `BWResource::openSection`(`bwresource.hpp:71-73`):

```cpp
static DataSectionPtr openSection( const BW::StringRef & resourceID,
                                    bool makeNewSection = false,
                                    DataSectionCreator* creator = NULL );
```

实现(`bwresource.cpp:614-627`):

```cpp
DataSectionPtr BWResource::openSection( const BW::StringRef & resourceID,
                                        bool makeNewSection,
                                        DataSectionCreator* creator )
{
    PROFILER_SCOPED( BWResource_openSection );

    // 1. 先查 census(普查表)
    DataSectionPtr pExisting = DataSectionCensus::find( resourceID );
    if (pExisting) return pExisting;

    // 2. 交给根 section(它是 DirSection)
    return instance().rootSection()->openSection( resourceID,
                                        makeNewSection, creator );
}
```

**完整流程**:

1. **查 census**——`DataSectionCensus::find` 是一次 hashmap 查询,如果该路径之前加载过且对象还活着,直接返回。这是"跨多次访问共享同一对象"的关键。
2. **查 DataSectionCache**——`DirSection::findChild`(`dir_section.cpp:189`)先查 LRU 缓存。
3. **若 census 也没有**——再查 `DataSectionCensus::find` 一次(防止 cache 漏掉但 census 还有弱引用)。
4. **文件系统层查找**——调用 `MultiFileSystem::getFileTypeEx(fullName)`,MultiFileSystem 会遍历所有 base FS 找第一个返回非 `FT_NOT_FOUND` 的(`multi_file_system.cpp`)。
5. **按类型创建对应 Section**——见 4.3.3 中的 switch。
6. **缓存 + census 登记**——新创建的 section 同时加入 cache 和 census。

### 4.4.3 资源路径解析

`BWResource` 还提供一批路径工具函数(`bwresource.hpp:96-146`),它们都是 `static`,无需 init 即可使用:

```cpp
static BW::StringRef getExtension( const BW::StringRef& file );
static BW::StringRef removeExtension( const BW::StringRef& file );
static BW::string    changeExtension( const BW::StringRef& file,
                                      const BW::StringRef& newExtension );
static BW::string    getFilePath( const BW::StringRef& file );
static BW::string    formatPath( const BW::StringRef& path );
static bool          isFile( const BW::StringRef& file );
static bool          isDir( const BW::StringRef& file );
static bool          fileExists( const BW::StringRef& file );
static bool          pathIsRelative( const BW::StringRef& path );
static bool          ensurePathExists( const BW::StringRef& path );
static BW::string    dissolveFilename( const BW::StringRef& file );
static BW::string    resolveFilename( const BW::StringRef& file );  // 仅 EDITOR_ENABLED
```

部分模板实现(在头文件中):

- `findExtensionPos`(`bwresource.hpp:307-329`):找到路径中最后一个 `.` 的位置,但要求 `.` 在最后一段路径分隔符之后。
- `pathIsRelativeT`(`bwresource.hpp:291-297`):无盘符 + 不是 `/` 或 `\` 开头。
- `hasDriveInPathT`(`bwresource.hpp:277-283`):包含 `:` 或以 `\`、`/` 开头。

这些工具函数不仅给 resmgr 自身用,也被很多上层工具调用——例如 Asset Pipeline 解析依赖路径时。

### 4.4.4 资源树(path resource)

`BWResource` 维护的资源"树"是一棵 **隐式树**——根 DirSection 之下,每次 `openSection("a/b/c")` 都会逐级创建 DirSection 节点,但每个节点只有在被访问时才"展开"。

`BWResource::openSectionInTree`(`bwresource.cpp:2343-2382`)提供了"沿路径向上搜索"的能力:从给定 path 开始,逐级向上查找名为 `desiredSection` 的文件。它的典型用途是查找 `space.settings`——一个空间可能在多级子目录里都有自己的 `space.settings`,引擎需要找到最具体的那一份。

```cpp
// 在 resource/ 下逐级查找 space.settings
DataSectionPtr ds = BWResource::openSectionInTree(
    "spaces/fantasydemo/foo/bar", "space.settings" );
```

### 4.4.5 file_handle_streamer - 文件流式加载

**文件**:`file_handle_streamer.hpp` / `file_streamer.hpp`

`IFileStreamer`(`file_streamer.hpp`)是 resmgr 的"流式读取"抽象,允许上层在不一次性 `readFile` 整个文件的情况下,按需读字节。接口:

```cpp
class IFileStreamer
{
    virtual size_t read( size_t nBytes, void* buffer ) = 0;
    virtual bool   skip( int nBytes ) = 0;
    virtual bool   setOffset( size_t offset ) = 0;
    virtual size_t getOffset() const = 0;
    virtual void*  memoryMap( size_t offset, size_t length, bool writable ) = 0;
    virtual void   memoryUnmap( void * p ) = 0;
};
```

`FileHandleStreamer`(`file_handle_streamer.hpp`)是基于 `FILE*` 的实现,封装了 `fread`、`fseek`、`ftell`、`mmap`(Windows 上用 `CreateFileMapping`)。

`IFileSystem::streamFile(path)` 返回一个 `FileStreamerPtr`,让上层按需读取大文件——例如视频纹理、流式音频。这是 resmgr 在"懒加载"之外,对超大体量文件提供的补充机制。

---

## 4.5 MultiFileSystem 多文件系统

`MultiFileSystem`(`multi_file_system.hpp:13-100`)是 BigWorld 实现"虚拟文件系统"的核心——它把多个 `IFileSystem` 叠加在一起,对上层表现为一个统一的根。

### 4.5.1 IFileSystem 抽象基类

**文件**:`file_system.hpp`

```cpp
class IFileSystem : public SafeReferenceCount
{
public:
    enum FileType { FT_NOT_FOUND, FT_DIRECTORY, FT_FILE, FT_ARCHIVE };

    struct FileInfo
    {
        uint64 size;
        uint64 created;
        uint64 modified;
        uint64 accessed;
    };

    virtual FileType getFileType( const BW::StringRef & path,
                                    FileInfo * pFI = NULL ) = 0;
    virtual bool     readDirectory( Directory& dir, const BW::StringRef & path ) = 0;
    virtual BinaryPtr readFile( const BW::StringRef & path ) = 0;
    virtual BinaryPtr readFile( const BW::StringRef & dirPath, uint index ) = 0;
    virtual bool     makeDirectory( const BW::StringRef & path ) = 0;
    virtual bool     writeFile( const BW::StringRef & path,
                                BinaryPtr pData, bool binary ) = 0;
    virtual bool     eraseFileOrDirectory( const BW::StringRef & path ) = 0;
    virtual bool     moveFileOrDirectory( const BW::StringRef & oldPath,
                                            const BW::StringRef & newPath ) = 0;
    virtual FILE *   posixFileOpen( const BW::StringRef & path, const char * mode );
    virtual bool     locateFileData( const BW::StringRef & path,
                                       FileDataLocation * pLocationData ) = 0;
    virtual FileStreamerPtr streamFile( const BW::StringRef& path ) = 0;
    virtual BW::string getAbsolutePath( const BW::StringRef& path ) const = 0;
    // ...
};
```

`IFileSystem` 也是 resmgr 的"修改监听"承载点:

```cpp
virtual void enableModificationMonitor( bool enable ) = 0;
virtual void flushModificationMonitor(
        const ModificationListeners& listeners ) = 0;
virtual bool hasPendingModification( const BW::string& fileName ) = 0;
```

### 4.5.2 MultiFileSystem 的组合逻辑

`MultiFileSystem` 内部维护一个 `BW::vector<FileSystemPtr> baseFileSystems_`(`multi_file_system.hpp:85`),所有操作都按顺序遍历 base FS,直到找到第一个能处理该路径的。

例如 `readFile`(`multi_file_system.cpp:254-269`):

```cpp
BinaryPtr MultiFileSystem::readFile(const BW::StringRef& path)
{
    ReadWriteLock::ReadGuard bfsGuard ( baseFileSystemsLock_ );
    for (FileSystemVector::iterator it = baseFileSystems_.begin();
        it != baseFileSystems_.end();
        ++it)
    {
        BinaryPtr pBinary = (*it)->readFile( path );
        if  (pBinary)
            return pBinary;
    }
    return NULL;
}
```

这种"叠加层"设计有几个直接收益:

1. **覆盖**:把一个开发期目录 `D:/project/res/` 放在前面,把发布期 `res.zip` 放在后面,新文件覆盖旧文件。
2. **多游戏**:在多游戏共用一份引擎二进制时,可以把每个游戏的 res 路径都加入,引擎代码完全无差别。
3. **跨平台路径混合**:Windows 工具期绝对路径 + Unix 服务器相对路径可以共存(在 `EDITOR_ENABLED` 下还会自动追加一个空根 NativeFileSystem)。

### 4.5.3 平台实现

#### UnixFileSystem

**文件**:`unix_file_system.hpp` / `unix_file_system.cpp`

- 基于 POSIX `<dirent.h>`、`stat`、`fopen`、`mkdir`、`rename`、`unlink` 等。
- 文件名比较大小写敏感(对 Linux 服务器是必须的)。
- 修改监听未实现(`enableModificationMonitor` 是空函数)——Linux 服务器不支持热重载。
- `getFileType` 用 `stat` 区分文件/目录。

#### WinFileSystem

**文件**:`win_file_system.hpp` / `win_file_system.cpp`

- 基于 Windows API `FindFirstFile`、`CreateFile`、`GetFileAttributesEx` 等。
- 文件名比较大小写不敏感(`bw_stricmp`)。
- 实现了 `FindFirstChangeNotification` 机制的修改监听——这是 Windows 工具能"热重载资源"的基础。
- 实现了 `copyFileOrDirectory`(`IFileSystem` 中 `#if defined(_WIN32)` 的接口)。

#### ZipFileSystem

**文件**:`zip_file_system.hpp` / `zip_file_system.cpp`

- 把 zip 文件当成虚拟文件系统,支持 zip 内目录、文件、嵌套 zip。
- 数据结构:
  - `LocalHeader`(`zip_file_system.hpp:121-134`):每个文件前的本地头。
  - `DirEntry`(`zip_file_system.hpp:140-159`):zip 末尾的中央目录条目。
  - `LocalFile`(`zip_file_system.hpp:164-242`):一个 zip 内文件的封装,可写、可读。
  - `CentralDir`(`zip_file_system.hpp:294`):所有 `LocalFile` 的 vector。
- **嵌套 zip 实现**:`parentZip_`(`zip_file_system.hpp:320`)指向父 ZipFileSystem,`offset_` 是当前 zip 在父 zip 中的字节偏移。`tag` 方法递归更新 `path_`,使路径形如 `x/y.zip/z/a.zip/b/c`。
- 修改监听未实现——zip 内容改动需手动 `BWResource::instance().purgeAll()` 清缓存。
- 最大支持 2GB(`MAX_ZIP_FILE_KBYTES = 2 * 1024 * 1024`,`zip_file_system.hpp:50`)。
- 重复文件名支持(`duplicates_`):同名文件会被编码为 `name(2)`、`name(3)` 等(`encodeDuplicate`/`decodeDuplicate`)。

### 4.5.4 PrimitiveFile - 原始文件访问

**文件**:`primitive_file.hpp` / `primitive_file.cpp`

`PrimitiveFile` 是一个简化的"原始二进制数据"访问器。从注释看:

> This class provides access to a file that contains binary data for a number of primitive resources. At some stage this kind of functionality will be integrated into the resource manager (using either a file system or a data section or some strange hybrid - zip file reform will happen then too), but for now it serves only primitive data

历史遗留——它的功能大部分已经被 `BinSection` 取代,但保留用于向后兼容。`#if 0` 部分(`primitive_file.hpp:35-69`)标注了已废弃的接口。新代码应该用 `BinSection` 替代。

---

## 4.6 资源缓存与监控

### 4.6.1 DataSectionCache - LRU 缓存

**文件**:`data_section_cache.hpp` / `data_section_cache.cpp`

`DataSectionCache` 是一个 **LRU(Least Recently Used)缓存**,用"双向链表 + hashmap"实现,以路径为 key,`DataSectionPtr` 为 value:

```cpp
class DataSectionCache
{
    struct CacheNode
    {
        BW::string      path_;
        DataSectionPtr   dataSection_;
        int             bytes_;
        CacheNode*      prev_;
        CacheNode*      next_;
    };

    typedef BW::map<BW::string, CacheNode*> DataSectionMap;

    DataSectionMap   map_;
    static int        s_maxBytes_;      // 默认 100KB
    static int        s_currentBytes_;
    CacheNode*        cacheHead_;       // MRU 端
    CacheNode*        cacheTail_;       // LRU 端
    static int        s_hits_;
    static int        s_misses_;
    SimpleMutex       accessControl_;   // 线程安全
};
```

接口:

```cpp
void          add( const BW::string & name, DataSectionPtr dataSection );
DataSectionPtr find( const BW::string & name );
void          remove( const BW::string & name );
void          clear();
DataSectionCache* setSize( int maxBytes );
void          dumpCacheState();   // 调试用
```

工作流程:
- `add` 时若超容量,从 `cacheTail_` 开始逐个 `purgeLRU`,直到 `s_currentBytes_ <= s_maxBytes_`。
- `find` 命中时把节点移到链表头(`moveToHead`),保持 LRU 顺序。
- `remove` 把节点从链表和 map 中删除(`unlinkNode`)。

**与 DirSection 的协作**:每次 `DirSection::findChild` 找到节点后都会调用 `DataSectionCache::instance()->add(fullName, pSection)`(`dir_section.cpp:309-314`)登记到缓存;下次再访问同一路径就直接命中。

注意:cache 持有的是 **强引用**(`DataSectionPtr`),只要 cache 没被淘汰,该 section 就不会被销毁。

### 4.6.2 DataSectionCensus - 普查(检测泄漏)

**文件**:`data_section_census.hpp` / `data_section_census.cpp`

`DataSectionCensus` 是一个 **弱引用** 登记表,以"命名 DataSection"为粒度:

```cpp
namespace DataSectionCensus
{
    DataSectionPtr find( const BW::StringRef & id );
    DataSectionPtr add( const BW::StringRef & id, const DataSectionPtr & pSect );
    void del( const DataSection * pSect );
    void tryDestroy( const DataSection * pSect );
    void clear();
    void init();
    void fini();
};
```

设计意图(`data_section_census.hpp:11-20`):
> This maintains a 'census' of all named DataSections that are currently alive. This allows quick lookup of named sections which are alive (but not necessarily in the cache anymore). It does not hold onto a strong reference to the DataSections. DataSections are not automatically added to the census (because not all DataSections have a name), but they are automatically removed from the census when they die.

也就是说,census 维护的是"**还活着的命名 section**"的弱引用表:
- `find(id)` 返回 `DataSectionPtr`,若对象已死则返回 NULL。
- `add(id, pSect)` 登记一个新对象,但不会增加引用计数。
- 当 section 被销毁时,自动从 census 移除(通过 `DataSection::destroy` 调用 `tryDestroy`)。

**与 cache 的关系**:
- 当 LRU cache 把一个 section 淘汰时,该 section **可能** 还活着(因为上层代码可能还持有引用),所以 `BWResource::purge` 会同时调用 `DataSectionCache::remove` 和 `DataSectionCensus::del`(`bwresource.cpp:567-575`)。
- 但 `BWResource::openSection` 第一步总是查 census——即使 cache 淘汰了,只要 census 中还活着,就复用,避免重新解析。

**泄漏检测**:`DataSectionCensus::fini()` 在引擎关闭时调用,如果还有未销毁的命名 section,会在调试输出中报告。这是排查"资源没释放"的重要工具。

### 4.6.3 ResourceCache - 通用资源缓存模板

**文件**:`resource_cache.hpp`

`ResourceCache` 是一个 **通用对象缓存**,不限于 DataSection,可以缓存任何继承自 `CachedResource` 的对象:

```cpp
class CachedResource
{
    void* key_;
public:
    CachedResource( void* key = NULL );
    virtual void init(){};
    virtual void fini(){};
    virtual ~CachedResource();
};

class ResourceCache
{
    BW::map<void*,CachedResourcePtr> resources_;
public:
    static ResourceCache& instance();
    void registerResource( void* key, CachedResourcePtr resource );
    void unregisterResource( void* key );
    template<typename SP> void addResource( SP sp );
    void init();
    void fini();
};
```

模板特化 `SmartPointerCache<SP>`(`resource_cache.hpp:25-36`)允许直接缓存任何智能指针类型(Moo::Visual、ParticleSystem 等)。

设计巧妙之处:`CachedResource` 的构造函数自动调用 `ResourceCache::instance().registerResource`(`resource_cache.hpp:107-113`),析构函数自动 `unregisterResource`(`resource_cache.hpp:115-118`)。所以**任何继承自 `CachedResource` 的对象一旦构造,就会被自动登记到全局 cache**,无需手动管理。

### 4.6.4 AccessMonitor - 访问监控

**文件**:`access_monitor.hpp` / `access_monitor.ipp` / `access_monitor.cpp`

`AccessMonitor` 是一个 **单例**(`access_monitor.hpp:21-40`),用来记录资源访问:

```cpp
class AccessMonitor
{
public:
    void record( const BW::string &fileName );
    void active( bool flag );
    static AccessMonitor &instance();
private:
    bool active_;
};
```

**默认不激活**——只有显式调用 `active(true)` 后,`record` 才会真正输出。被 `DirSection::findChild` 调用(`dir_section.cpp:256`),用于排查"加载了哪些文件"。

典型用法:启动游戏到某个时刻,把 `AccessMonitor` 打开,然后再触发一遍场景,记录下来的文件列表就是该场景需要的全部资源——这是优化启动时间的关键工具。

### 4.6.5 ResourceModificationListener - 修改监听

**文件**:`resource_modification_listener.hpp` / `resource_modification_listener.cpp`

`ResourceModificationListener` 是 **资源热重载的核心抽象**:

```cpp
class ResourceModificationListener
{
public:
    enum Action
    {
        ACTION_ADDED,
        ACTION_DELETED,
        ACTION_MODIFIED,
        ACTION_MODIFIED_DELETED
    };

    virtual void onResourceModified(
        const BW::StringRef& basePath,
        const BW::StringRef& resourceID,
        Action modType ) = 0;
    // ...
};
```

监听器通过 `BWResource::addModificationListener` 注册(`bwresource.hpp:76-77`),由 `WinFileSystem` 在后台轮询文件变化时触发。

**ReloadTask 机制**(`resource_modification_listener.hpp:30-52`):每个监听器可以发起"重载任务",由 `TaskManager` 在后台线程执行(`doBackgroundTask`),完成后切回主线程执行(`doMainThreadTask`)。这是 BigWorld 实现"编辑器中改了资源 → 后台编译 → 主线程替换"的基础。

子类典型实现:
- `AssetCompiler`(Asset Pipeline):监听源资源变化,触发增量编译。
- `WorldEditor`:监听 cdata/Chunk 变化,自动重载场景。
- `Moo::TextureManager`:监听纹理变化,自动重新上传到 GPU。

`BWResource::ignoreFileModification`(`bwresource.hpp:81-83`)用于"自己写文件时不要触发监听"——避免自己改自己又收到通知形成循环。`flushModificationMonitor`(`bwresource.hpp:80`)用于主动 flush 累积的修改事件。

---

## 4.7 高级特性

### 4.7.1 BinaryBlock - 二进制数据块

**文件**:`binary_block.hpp` / `binary_block.cpp`

`BinaryBlock` 是 resmgr 中"原始字节流"的统一封装(`binary_block.hpp:22-82`):

```cpp
class BinaryBlock : public SafeReferenceCount
{
public:
    BinaryBlock( const void* data, size_t len, const char * allocator,
                  BinaryPtr pOwner = 0 );
    BinaryBlock( std::istream& stream, std::streamsize len,
                  const char * allocator );

    const void * data() const;
    int          len() const;
    BinaryPtr    pOwner();

    // 压缩 / 解压
    BinaryPtr compress(int level = DEFAULT_COMPRESSION) const;
    BinaryPtr decompress() const;
    bool      isCompressed() const;

    static const int RAW_COMPRESSION      = 0;
    static const int DEFAULT_COMPRESSION = 6;
    static const int BEST_COMPRESSION     = 10;
};
```

**设计要点**:

1. **引用计数**:`BinaryPtr` 是 `SmartPointer<BinaryBlock>`,多个 section 可共享同一块内存。
2. **可选 owner**:`pOwner` 参数允许"一块内存属于另一个 BinaryBlock"——这是 zip 嵌套的核心:外层 zip 解压出的整个内层 zip 字节流,作为内层 zip 的 `BinaryBlock` 的 owner,只要内层 zip 还在用,外层字节流就不会被释放。
3. **压缩支持**:`compress` / `decompress` 使用 zlib,直接生成压缩后的 BinaryBlock。
4. **外部持有**:`externallyOwned_` 标志位表明数据指针是外部的(可能是栈上或别的容器),此时析构不 free。
5. **流式构造**:从 `std::istream` 直接读 len 字节构造,适合从网络/磁盘流式加载。

`BinaryInputBuffer`(`binary_block.hpp:87-100`)继承自 `std::streambuf`,把 BinaryBlock 包装成可读流——这让 resmgr 可以把"内存中的二进制块"当成"流"传给需要 stream 的解析器(如 tinyxml)。

### 4.7.2 BinSection 与 BinaryBlock 的协作

BinSection(`bin_section.hpp:20-78`)就是 `BinaryBlock` + `DataSection` 接口的组合:

```cpp
class BinSection : public DataSection
{
    BW::string  tag_;
    BinaryPtr    binaryData_;
    Children     children_;
    DataSectionPtr parent_;
};
```

`asBinary()` 直接返回内部 `binaryData_`,`setBinary(BinaryPtr)` 直接替换。`countChildren`、`openChild` 等通过 `introspect()` 把字节流解析成子 BinSection——但这个解析非常少见,通常 BinSection 是叶节点。

### 4.7.3 bundiff 与 bdiff - 二进制差分

**文件**:`bundiff.hpp` / `bundiff.cpp`、`bdiff.hpp` / `bdiff.cpp`

这两个文件提供 **二进制差分(diff/patch)** 功能:

```cpp
// bdiff.hpp
bool performDiff( const BW::vector<unsigned char>& first,
                  const BW::vector<unsigned char>& second,
                  FILE * diff );

// bundiff.hpp
bool performUndiff( FILE * pDiff, FILE * pSrc, FILE * pDest );
```

- `performDiff` 计算两个二进制块的差异,写到 `diff` 文件。
- `performUndiff` 把 `diff` 应用到 `pSrc`,生成 `pDest`。

**用途**:BigWorld 的资源管线在某些场景下,只下发"差分"而不是完整文件——例如服务器向客户端推送资源更新,或 Asset Pipeline 增量编译产物。这种"差分 + 补丁"的思路与 Git 的 packfile、rsync 的 delta-transfer 类似。

### 4.7.4 auto_config - 自动配置

**文件**:`auto_config.hpp` / `auto_config.cpp`

`AutoConfig`(`auto_config.hpp:14-34`)是一个 **声明式自动配置机制**:声明一个全局变量,启动时自动从 XML 配置文件读取值。

```cpp
class AutoConfig
{
public:
    virtual void configureSelf( DataSectionPtr pConfigSection ) = 0;
    static void configureAllFrom( DataSectionPtr pConfigSection );
    static bool configureAllFrom( BW::vector<DataSectionPtr>& pConfigSections );
    static bool configureAllFrom( const BW::string& xmlResourceName );
};
```

模板子类 `BasicAutoConfig<T>`(`auto_config.hpp:41-63`)把任意类型 T 包装成 AutoConfig:

```cpp
// 全局变量声明
static BasicAutoConfig<int>   s_maxParticles( "graphics/maxParticles", 1000 );
static BasicAutoConfig<float> s_cameraFov( "graphics/cameraFov", 75.0f );
static AutoConfigString       s_defaultLanguage( "i18n/defaultLanguage", "en" );

// 启动时一次性配置全部
AutoConfig::configureAllFrom( "scripts/config.xml" );
```

`AutoConfig` 内部维护一个静态 vector `s_all`,所有 `BasicAutoConfig` 在构造时自动登记,`configureAllFrom` 时遍历并调用每个的 `configureSelf`。这种"全局变量 + 自动配置"的模式在 BigWorld 大量模块中都有使用,例如 `Moo::Material::s_materials`、`Effect::s_effectManager` 等。

### 4.7.5 hierarchical_config - 层次化配置

**文件**:`hierarchical_config.hpp` / `hierarchical_config.cpp`

`HierarchicalConfig` 把"分散在目录树中的同名配置文件"合并成一个层次化的配置:

```cpp
class HierarchicalConfig
{
public:
    HierarchicalConfig( const StringRef & filename,
                        const StringRef & rootDirectory );
    DataSectionPtr get( const StringRef & path ) const;
    DataSectionPtr getRoot() const;
};
```

典型用法:在每个空间目录下都放一个 `space.settings`,引擎递归搜索并合并所有 `space.settings`,子级覆盖父级——这样设计时可以"全局默认配置 + 空间特定配置"叠加。

实现(`hierarchical_config.cpp`)核心方法:
- `populateRule`:把一个 override section 的所有子节点递归合并到一个 rule section。
- `populateChildren`:递归遍历目录,找到所有同名文件,合并成层次树。
- `populateConfiguration`:对给定 path,从根到叶逐级应用 rule,得到最终配置。

### 4.7.6 string_provider - 字符串提供器(本地化)

**文件**:`string_provider.hpp` / `string_provider.cpp`

`StringProvider` 是 BigWorld 的 **本地化(i18n)系统**,以单例形式存在:

```cpp
class StringProvider
{
public:
    static StringProvider& instance();
    void   load( DataSectionPtr file );
    void   setLanguage();
    const wchar_t* str( const wchar_t* id, DefResult def = ... ) const;
    void   formatString( const wchar_t* formatID, BW::wstring & o_OutputString, ... );
};
```

`Language`(`string_provider.hpp:172-196`)是语言抽象,通过 `load(DataSectionPtr)` 从 XML 加载字符串表。`Formatter`(`string_provider.hpp:25-113`)是格式化辅助,支持 `%0`-`%7` 占位符(注意不是 `%s`/`%d`,而是 `%0`-`%7` 引用第 N 个参数)。

本地化字符串通过 `Localise(L"key")` 或 `LocaliseUTF8("key")` 获取:

```cpp
// Python 风格的格式化
BW::wstring msg;
formatLocalisedString( L"welcome_message", msg,
    Formatter(playerName), Formatter(level) );
// 对应 XML: <welcome_message>Welcome %0 (level %1)!</welcome_message>
```

`WindowTextNotifier`(`string_provider.hpp:428-461`,Windows 专用)进一步把本地化集成到 Win32 控件——切换语言时,所有登记过的 HWND 自动更新文本。

### 4.7.7 xml_special_chars - XML 特殊字符

**文件**:`xml_special_chars.hpp` / `xml_special_chars.cpp`

```cpp
class XmlSpecialChars
{
public:
    static void        reduce( char* buf );      // &lt; → <
    static BW::string  expand( const char* buf ); // < → &lt;
};
```

把 `<`、`>`、`&`、`"`、`'` 在 XML 文本内容和转义序列之间互转。`XMLSection` 在写文件时调用 `expand`,读文件时调用 `reduce`(除非 `noXMLEscapeSequence` 关闭)。

### 4.7.8 filename_case_checker - 文件名大小写检查

**文件**:`filename_case_checker.hpp` / `filename_case_checker.cpp`(仅 Windows)

```cpp
class FilenameCaseChecker
{
public:
    bool check( BW::StringRef const & path,
                bool warnIfNotCorrect = true, bool warnIfNotFound = false );
    void filenameOnDisk(BW::StringRef const &path, BW::string& out);
    static bool caseCorrectFilenameOnDisk( const BW::StringRef & path,
                                            BW::string & out,
                                            bool * isCorrectCase );
};
```

**为什么需要这个**:Windows 文件系统大小写不敏感(`Foo.txt` 和 `foo.txt` 是同一个文件),但 Linux 服务器大小写敏感。如果开发者在 Windows 上写了 `Load("Foo.txt")` 而磁盘上文件是 `foo.txt`,在 Windows 上能跑,部署到 Linux 服务器就崩溃。`FilenameCaseChecker` 在 Windows 上额外检查"代码中引用的大小写"是否和"磁盘上的实际大小写"一致,如果不一致就警告。

这是 BigWorld "**Windows 开发 + Linux 部署**"工程范式的关键防线。启用方式:`BWResource::checkCaseOfPaths(true)`(`bwresource.hpp:196-198`,需编译时 `ENABLE_FILE_CASE_CHECKING`)。

### 4.7.9 其他辅助文件

#### sanitise_helper

**文件**:`sanitise_helper.hpp` / `.cpp`

提供路径清理工具——把 Windows 反斜杠 `\` 替换为正斜杠 `/`、合并多个连续分隔符、移除末尾分隔符等。`BWResource::formatPath` 内部使用。

#### quick_file_writer

**文件**:`quick_file_writer.hpp`

```cpp
class QuickFileWriter
{
public:
    template <class T> QuickFileWriter & operator <<( const T & t );
    QuickFileWriter& write( const void* buffer, size_t size );
    BinaryPtr output();
};
```

把内存数据快速写入 `BinaryBlock` 的辅助类。基于 `BW::string data_` 累积,`output()` 时一次性构造 `BinaryBlock`。大量用于序列化代码中。

#### resource_file_path

**文件**:`resource_file_path.hpp` / `.cpp`

`ResourceFilePath` 继承自 `BackgroundFilePath`,用于"后台线程写文件"时把资源路径解析推迟到后台线程——避免主线程阻塞在 `BWResource::resolveToAbsolutePath` 上。

#### forward_declarations

**文件**:`forward_declarations.hpp`

只包含 `BinaryBlock`、`DataSection` 的前向声明和智能指针 typedef,供其他头文件需要最小依赖时使用。

---

## 4.8 DataSection 使用示例

### 4.8.1 读取 XML 配置

假设 `scripts/config.xml`:

```xml
<root>
    <graphics>
        <resolution>1920x1080</resolution>
        <fullscreen>true</fullscreen>
        <maxFPS>60</maxFPS>
    </graphics>
    <spawn>
        <position>10.0 20.0 30.0</position>
    </spawn>
</root>
```

C++ 代码:

```cpp
#include "resmgr/bwresource.hpp"

void loadConfig()
{
    DataSectionPtr pConfig = BWResource::openSection( "scripts/config.xml" );
    if (!pConfig) return;

    // 路径式读取(推荐)
    BW::string res   = pConfig->readString( "graphics/resolution", "1280x720" );
    bool       fs    = pConfig->readBool  ( "graphics/fullscreen", false );
    int        fps   = pConfig->readInt   ( "graphics/maxFPS", 30 );
    Vector3    spawn = pConfig->readVector3( "spawn/position", Vector3(0,0,0) );

    // 也可以分两步:openSection + as*
    DataSectionPtr pGfx = pConfig->openSection( "graphics" );
    if (pGfx) {
        fs = pGfx->readBool( "fullscreen", false );
    }
}
```

### 4.8.2 写入二进制数据到 zip

```cpp
#include "resmgr/bwresource.hpp"
#include "resmgr/zip_section.hpp"
#include "resmgr/bin_section.hpp"
#include "resmgr/binary_block.hpp"

void saveChunkData()
{
    // 创建/打开一个 .cdata(zip 格式)
    DataSectionPtr pCData = BWResource::openSection(
        "spaces/fantasydemo/chunk1.cdata", true, ZipSection::creator() );
    if (!pCData) return;

    // 在其下创建一个 bin 子节点
    DataSectionPtr pHeights = pCData->openSection(
        "terrain2/heights", true, BinSection::creator() );

    // 准备一段二进制数据
    std::vector<float> heightmap(256 * 256, 0.0f);
    BinaryPtr pBin = new BinaryBlock(
        heightmap.data(), heightmap.size() * sizeof(float),
        "BinaryBlock/heights" );

    pHeights->setBinary( pBin );
    pCData->save();   // 写回 zip 文件
}
```

### 4.8.3 遍历子节点

```cpp
void listEntities()
{
    DataSectionPtr pEntities = BWResource::openSection( "scripts/entities" );
    if (!pEntities) return;

    // 方式 1:迭代器
    DataSectionIterator it = pEntities->begin();
    while (it != pEntities->end()) {
        BW::string name = it.tag();
        DataSectionPtr pChild = *it;
        BW::string kind = pChild->readString( "kind", "unknown" );
        // ...
        ++it;
    }

    // 方式 2:索引
    for (int i = 0; i < pEntities->countChildren(); ++i) {
        DataSectionPtr pChild = pEntities->openChild(i);
        BW::string name = pEntities->childSectionName(i);
        // ...
    }

    // 方式 3:读取所有同名子节点(readStrings 模板)
    BW::vector<BW::string> entityNames;
    pEntities->readStrings( "Entity/name", entityNames );
}
```

### 4.8.4 Python 中使用

```python
import BigWorld

section = BigWorld.ResMgr.openSection( "scripts/config.xml" )
if section is not None:
    res = section.readString( "graphics/resolution", "1280x720" )
    fs  = section.readBool  ( "graphics/fullscreen", False )
    fps = section.readInt   ( "graphics/maxFPS", 30 )

    # 遍历子节点
    for name in section.keys():
        child = section[name]
        print(name, child.asString)

    # 修改并保存
    section.writeInt( "graphics/maxFPS", 120 )
    section.save()
```

### 4.8.5 嵌套 zip 的访问

假设资源结构是 `outer.zip/inner.zip/data.xml`,你可以一次性写:

```cpp
DataSectionPtr pXml = BWResource::openSection(
    "outer.zip/inner.zip/data.xml" );
```

`BWResource` 会自动:
1. 用 `ZipSection` 打开 `outer.zip`。
2. `ZipSection::openChild("inner.zip")` 创建一个嵌套 `ZipFileSystem`,把 inner.zip 当成 ZipSection 返回。
3. 在该 ZipSection 上再 `openChild("data.xml")`,返回 XMLSection。

完整测试用例见 `unit_test/test_zip_section.cpp:824-899`(`ZipSection_TestNestedDirectory`),它验证了:

```cpp
// 写入:多层嵌套 zip
DataSectionPtr zipSection = BWResource::openSection(
    "test_path/test_dir.zip" );
DataSectionPtr zipChild = zipSection->openSection( "zipChild" );

// ... 在 zipChild 下放 10 个 nestedBin ...

DataSectionPtr nestedXMLChild = zipSection->openSection(
    "zipChild/xmlChild", true, XMLSection::creator() );
nestedXMLChild->writeString( "testString", "hello" );
zipSection->save( saveAsFilename );

// 读出:验证嵌套路径
DataSectionPtr loaded = BWResource::openSection( saveAsFilename );
DataSectionPtr xml = loaded->openSection( "zipChild/xmlChild" );
CHECK( xml->readString("testString", "") == "hello" );
```

---

## 4.9 资源系统在引擎中的作用

### 4.9.1 客户端

- **模型加载**:`Moo::Visual::load( resourceID )` 内部调用 `BWResource::openSection` 拿到 BinSection(对于 `.visual`)或 XMLSection(对于 `.model`),解析几何/材质/动画。
- **纹理加载**:`Moo::Texture::load()` 调用 `BWResource::openSection` 得到 BinaryPtr,再上传到 GPU。
- **Chunk 加载**:`ChunkManager` 通过 `BWResource::openSection("spaces/<space>/<chunk>.cdata")` 加载,`cdata` 是 zip,内部包含 `terrain2`、`entities`、`lights` 等子 section。
- **UI 资源**:`GUI::Manager` 加载 `.gui` 文件(XML),配置控件树。

### 4.9.2 服务器

- **实体定义**:`EntityType::load( "scripts/entities/<entity>.def" )` 通过 `BWResource::openSection` 读取 `.def`(XML)和 `*.def.bin`(Packed),构建 Method/Property 表。
- **服务器配置**:`cellappmgr.xml`、`baseappmgr.xml`、`dbapp.xml` 等都是 `BWResource::openSection` 加载的 XMLSection。
- **空间配置**:`spaces/<space>/space.settings`(XML)包含地形、客户端/服务器边界等。

### 4.9.3 工具

- **Asset Pipeline**:编译器读取源 XML,写出 PackedSection / ZipSection,中间过程通过 `BWResource::openSection` 访问源文件,通过 `convert` / `save` 写出。
- **WorldEditor**:编辑场景时,所有 `cdata` 修改都通过 `BWResource::save` 写回 zip,触发 `ResourceModificationListener` 通知其他子系统重载。
- **ModelEditor**:模型预览时,通过 `BWResource::purge` 主动清缓存,确保读到最新版本。

### 4.9.4 跨进程共享

BigWorld 的多进程架构要求"配置一致性":CellApp、BaseApp、DBApp 必须读到同一份 `*.def` 文件。`BWResource` 通过:
1. **资源路径统一**:所有进程都通过 `BW_RES_PATH` 环境变量指定同一组路径。
2. **DataSectionCensus 跨进程共享**:census 是进程内的,但只要进程读的是同一份文件(从同一 zip 或同一目录),解析结果就一致。
3. **修改监听单进程触发**:Windows 工具(如 WorldEditor)修改文件后,只有它自己的进程会收到通知;服务器进程(Linux)需要 bwmachined 通过 MachineGuard 协议通知重载。

---

## 4.10 特色实现深度剖析

### 4.10.1 多态 DataSection 的设计模式

`DataSection` 的设计是 **策略模式** 与 **模板方法模式** 的组合,关键在于:

- **接口与实现分离**:`DataSection` 是抽象类,只定义"做什么",不定义"怎么做"。
- **模板方法**:`openSection(path)`、`readInt(path)`、`readVector3(path)` 等都是非虚函数,内部调用纯虚 `findChild` / `asInt` / `asVector3`。
- **策略模式**:`XMLSection`、`BinSection`、`ZipSection` 等是不同策略,通过虚函数分派。
- **工厂方法**:`DataSectionCreator` 抽象了"如何创建子节点",`createAppropriateSection`(`datasection.cpp`)是默认的"按内容判断"工厂。
- **智能指针 + 引用计数**:`SafeReferenceCount` 提供线程安全引用计数,`DataSectionPtr` 是侵入式智能指针——既避免循环引用,又能安全传递。

这种分层设计的直接收益:

1. **上层代码无感知**:把一个 XML 配置改成 zip,上层代码一行不用改。
2. **可扩展**:新增格式只需继承 `DataSection` 并实现虚函数。
3. **可测试**:可单独构造一个 `BinSection` 直接 `setBinary`,不依赖文件系统。

### 4.10.2 资源修改监听与 JIT 编译的协作

BigWorld 的 **JIT(Just-In-Time)资源编译** 是一大特色。流程:

```
美术修改源资源 → WinFileSystem 检测到变化 → 触发 ResourceModificationListener
→ AssetCompiler 收到通知,派 ReloadTask 到后台线程 → 后台编译
→ 编译完成,TaskManager 切回主线程 → 主线程替换 Moo::Visual / Moo::Texture
```

关键点:

1. **后台编译**:`ReloadTask`(`resource_modification_listener.hpp:30-51`)继承 `BackgroundTask`,在 `TaskManager` 中排队执行,不阻塞渲染线程。
2. **主线程替换**:`doMainThreadTask` 在主线程执行,确保 GPU 资源的安全替换。
3. **避免循环**:`ignoreFileModification` 让 AssetCompiler 自己写文件时不触发监听。
4. **依赖追踪**:Asset Pipeline 维护依赖图,改一个源文件,所有依赖它的目标都会被标记为"需重编"。

这部分会在第 15 章(Asset Pipeline)和第 16 章(WorldEditor)深入详解。

### 4.10.3 文件名大小写检查的跨平台价值

BigWorld 的工程范式是 **"Windows 开发 + Linux 服务器"**:

- Windows 文件系统 NTFS 大小写不敏感(默认),`Foo.txt` 和 `foo.txt` 是同一文件。
- Linux 文件系统 ext4 大小写敏感,`Foo.txt` 和 `foo.txt` 是不同文件。

后果:开发者如果在 Windows 上写 `BWResource::openSection("Scripts/Entity.xml")`,而磁盘上文件名是 `scripts/entity.xml`,在 Windows 上能跑,部署到 Linux 服务器就崩溃——而且崩溃发生在运行时,不是编译时,排查困难。

`FilenameCaseChecker`(`filename_case_checker.hpp`)就是在 Windows 上模拟 Linux 行为的工具:

- `caseCorrectFilenameOnDisk`(`filename_case_checker.hpp:26-27`):给定一个路径,返回磁盘上实际的大小写形式,通过 `FindFirstFile` 查询。
- `check`(`filename_case_checker.hpp:18-19`):比较"代码引用的大小写"和"磁盘大小写"是否一致,不一致就警告。
- 缓存机制(`FileNameCacheEntry`):同一路径只查一次磁盘,避免性能问题。

启用方式:在 `bwresource.cpp` 中如果 `ENABLE_FILE_CASE_CHECKING` 宏打开,初始化时调用 `fileSystem_->checkCaseOfPaths(true)`。这是开发期严格、发布期宽松的典型策略。

### 4.10.4 嵌套 Zip 支持的工程意义

`ZipFileSystem` 支持任意层级的嵌套 zip(`zip_file_system.hpp:301-311` 的注释很清楚):

```
x/y.zip/z/a.zip/b/c
└─y.zip─┘ └a.zip┘ └c┘
   |       |     |
   |       |     └── 文件 c
   |       └──────── zip 内的 zip
   └──────────────── 顶层 zip
```

实现关键:

1. **`parentZip_`**(`zip_file_system.hpp:320`):指向父 ZipFileSystem,形成链表。
2. **`offset_`**(`zip_file_system.hpp:325`):当前 zip 在父 zip 中的字节偏移。读取时,父 zip 用 `fseek` 跳到 `offset_` 开始读。
3. **`tag_` vs `path_`**:`tag_` 是相对于直接父的名字(如 `c`),`path_` 是从根到当前的完整路径(如 `x/y.zip/z/a.zip/b/c`)。
4. **`BinaryPtr pOwner`**(`binary_block.hpp:46`):嵌套 zip 解压出的内层 zip 字节,作为 `BinaryBlock` 时持有外层 zip 的 `BinaryPtr` 作为 owner,只要内层 zip 还在使用,外层字节流就不会被释放。

**工程意义**:

- **资源打包分发**:发布版客户端可以把整个 `res/` 目录打成一个 `res.zip`,内部某些子目录(如 `spaces/`)再单独打成 `spaces.zip` 嵌套在 `res.zip` 里,既能整体压缩又能按需加载。
- **DLC 与补丁**:把 DLC 资源打成 zip,放到主 zip 里,通过修改主 zip 即可"挂载"DLC。
- **跨平台一致**:同一份资源 zip 文件在 Windows 和 Linux 上行为一致(都是字节流),不依赖文件系统差异。

测试用例 `ZipSection_TestZipInZip`(`unit_test/test_zip_section.cpp:1176-1208`,虽然因 BWT-22538 暂时禁用,但逻辑存在)验证了:

```cpp
BW::string saveAsFilename = "zip_in_zip.zip";
ZipFileSystemPtr fileSystem = new ZipFileSystem( saveAsFilename );

// 在 zip 里再创建一个"文件夹"
DirSection* pDirSection = new DirSection( "folder1", fileSystem.getObject() );
pDirSection->tag( "folder1" );
pDirSection->save();

// 嵌套打开 zip 中的 zip
fileSystem = new ZipFileSystem( fileSystem, "folder1/folder1_1/a_zip_file.zip" );
CHECK( fileSystem->getFileTypeEx("not_empty_folder") == IFileSystem::FT_DIRECTORY );
```

---

## 4.11 本章小结

### 4.11.1 关键概念回顾

1. **DataSection** 是 resmgr 的核心抽象,把"文档"统一为层次化节点。五个子类分别对应 XML、二进制、目录、打包、Zip 五种格式。
2. **BWResource** 是单例入口,通过 `BWResource::openSection(path)` 拿到 `DataSectionPtr`。
3. **MultiFileSystem** 把多个真实/虚拟文件系统叠加成一个虚拟根,实现"路径透明 + 多路径覆盖"。
4. **DataSectionCache**(LRU 强引用) + **DataSectionCensus**(弱引用普查)共同提供缓存与对象共享。
5. **ResourceModificationListener** + **WinFileSystem** 实现"文件变化 → 监听器 → 后台编译 → 主线程替换"的热重载闭环。
6. **FilenameCaseChecker** 在 Windows 上模拟 Linux 大小写敏感,避免部署期才暴露的路径问题。
7. **嵌套 Zip** 通过 `parentZip_` + `offset_` + `BinaryPtr pOwner` 实现,支持任意层级的 zip 套 zip。

### 4.11.2 主要源文件索引

| 文件 | 作用 |
|---|---|
| `lib/resmgr/datasection.hpp/.cpp` | DataSection 抽象基类 |
| `lib/resmgr/xml_section.hpp/.cpp` | XML 实现 |
| `lib/resmgr/bin_section.hpp/.cpp` | 二进制实现 |
| `lib/resmgr/dir_section.hpp/.cpp` | 目录实现 |
| `lib/resmgr/packed_section.hpp/.cpp` | 打包格式实现 |
| `lib/resmgr/zip_section.hpp/.cpp` | Zip 嵌套 Section |
| `lib/resmgr/bwresource.hpp/.cpp/.ipp` | BWResource 单例 |
| `lib/resmgr/multi_file_system.hpp/.cpp` | 多文件系统组合 |
| `lib/resmgr/file_system.hpp` | IFileSystem 抽象 |
| `lib/resmgr/unix_file_system.hpp/.cpp` | Unix 平台 |
| `lib/resmgr/win_file_system.hpp/.cpp` | Windows 平台 + 修改监听 |
| `lib/resmgr/zip_file_system.hpp/.cpp` | Zip 虚拟文件系统 |
| `lib/resmgr/binary_block.hpp/.cpp` | 二进制数据块 |
| `lib/resmgr/data_section_cache.hpp/.cpp` | LRU 缓存 |
| `lib/resmgr/data_section_census.hpp/.cpp` | 弱引用普查 |
| `lib/resmgr/resource_cache.hpp` | 通用资源缓存模板 |
| `lib/resmgr/access_monitor.hpp/.ipp/.cpp` | 访问监控 |
| `lib/resmgr/resource_modification_listener.hpp/.cpp` | 修改监听 + ReloadTask |
| `lib/resmgr/file_handle_streamer.hpp/.cpp` | 文件流式加载 |
| `lib/resmgr/file_streamer.hpp` | IFileStreamer 抽象 |
| `lib/resmgr/primitive_file.hpp/.cpp` | 原始文件(遗留) |
| `lib/resmgr/bundiff.hpp/.cpp` / `bdiff.hpp/.cpp` | 二进制差分 |
| `lib/resmgr/auto_config.hpp/.cpp` | 自动配置 |
| `lib/resmgr/hierarchical_config.hpp/.cpp` | 层次化配置 |
| `lib/resmgr/string_provider.hpp/.cpp` | 字符串本地化 |
| `lib/resmgr/xml_special_chars.hpp/.cpp` | XML 特殊字符 |
| `lib/resmgr/filename_case_checker.hpp/.cpp` | 大小写检查 |
| `lib/resmgr/sanitise_helper.hpp/.cpp` | 路径清理 |
| `lib/resmgr/quick_file_writer.hpp` | 快速文件写入 |
| `lib/resmgr/resource_file_path.hpp/.cpp` | 后台文件路径解析 |
| `lib/resmgr/forward_declarations.hpp` | 前向声明 |
| `lib/pyscript/py_data_section.hpp/.cpp/.ipp` | Python 桥接 |
| `lib/resmgr/unit_test/` | 单元测试 |

### 4.11.3 推荐继续阅读

- 第 5 章 网络通信层 - network:`BWResource` 同样被 network 库用来加载 `.def` 文件、消息描述。
- 第 6 章 脚本系统与实体定义:`PyDataSection` 在 Python 端如何使用,以及 `.def` 解析如何依赖 DataSection。
- 第 14 章 Chunk 空间加载系统:`.cdata` 是 ZipSection 的典型用例,深入看 Chunk 加载流程。
- 第 15 章 资源管线与 AssetPipeline:`PackedSection::convert`、`ResourceModificationListener` 的真实使用。
- 第 16 章 WorldEditor 编辑器:`ignoreFileModification`、`flushModificationMonitor` 在编辑器中的应用。

---

> **实践建议**:读完本章后,建议在本地拷贝一份 `lib/resmgr/unit_test/` 下的测试用例,直接编译运行。`test_xml_section.cpp`、`test_zip_section.cpp`、`test_packed_section.cpp` 提供了几乎所有 DataSection 用法的最小可运行示例——比任何文档都直观。修改一下测试数据,观察 cache / census 的行为,你将对 resmgr 的内部机制有更扎实的理解。
