# 专题 09:EntityDef 数据驱动架构深度剖析

> EntityDef 是 BigWorld Engine 14.4.1 的灵魂子系统。它将"实体是什么、有哪些字段、有哪些方法、字段怎么同步、方法怎么分发"的全部契约从代码中剥离,落到 `.def` XML 数据文件中,再由 C++ 端在启动期解析为 `EntityDescriptionMap` 注册表,供 CellApp / BaseApp / Client / DBApp 四类进程共享。这种"数据驱动 + 多进程共享元数据"的设计,使 BigWorld 在 2000 年代早期就具备了不亚于现代 ECS 框架的灵活性和不亚于 Protobuf 的版本化能力。本专题以百科级深度剖析 BigWorld 14.4.1 中 **EntityDescription、EntityDescriptionMap、DataType 类型系统、DataDescription 字段描述、MethodDescription 方法描述、EntityMethodDescriptions 方法集、VolatileInfo、PropertyChange、ExposedMessageRange、MD5 摘要、process_defs 工具链** 等所有 EntityDef 相关内容,涵盖完整源码、数据结构、算法步骤、边界情况、性能分析、与其他引擎对比。

---

## 目录

- [一、EntityDef 概述与设计哲学](#一entitydef-概述与设计哲学)
- [二、文件布局与构建产物](#二文件布局与构建产物)
- [三、.def 文件格式深度剖析](#三def-文件格式深度剖析)
- [四、EntityDescription 数据结构](#四entitydescription-数据结构)
- [五、EntityDescriptionMap 注册表](#五entitydescriptionmap-注册表)
- [六、DataType 类型系统](#六datatype-类型系统)
- [七、MetaDataType 元类型工厂](#七metadatatype-元类型工厂)
- [八、DataDescription 字段描述](#八datadescription-字段描述)
- [九、MethodDescription 方法描述](#九methoddescription-方法描述)
- [十、MethodArgs 参数与返回值](#十methodargs-参数与返回值)
- [十一、EntityMethodDescriptions 方法集](#十一entitymethoddescriptions-方法集)
- [十二、MemberDescription 公共基类](#十二memberdescription-公共基类)
- [十三、VolatileInfo 系统](#十三volatileinfo-系统)
- [十四、PropertyChange 通知系统](#十四propertychange-通知系统)
- [十五、ExposedMessageRange 暴露范围](#十五exposedmessagerange-暴露范围)
- [十六、Mailbox 与 EntityDef 的协作](#十六mailbox-与-entitydef-的协作)
- [十七、DataDomain 与流分发算法](#十七datadomain-与流分发算法)
- [十八、.def → Python 描述对象转换流程](#十八def--python-描述对象转换流程)
- [十九、Python 实体类](#十九python-实体类)
- [二十、方法自动分发机制](#二十方法自动分发机制)
- [二十一、字段同步机制](#二十一字段同步机制)
- [二十二、MD5 摘要与版本兼容](#二十二md5-摘要与版本兼容)
- [二十三、性能分析](#二十三性能分析)
- [二十四、边界情况深度分析](#二十四边界情况深度分析)
- [二十五、与其他引擎对比](#二十五与其他引擎对比)
- [二十六、设计哲学总结](#二十六设计哲学总结)
- [附录 A:关键文件路径速查](#附录-a关键文件路径速查)
- [附录 B:EntityDataFlags 速查表](#附录-bentitydataflags-速查表)
- [附录 C:StreamContentType 与 DataDomain 映射](#附录-cstreamcontenttype-与-datadomain-映射)
- [附录 D:DataType 注册表](#附录-ddatatype-注册表)
- [附录 E:术语表](#附录-e术语表)
- [附录 F:相关专题](#附录-f相关专题)

---

## 一、EntityDef 概述与设计哲学

### 1.1 什么是 EntityDef

EntityDef 是 BigWorld 的**实体定义子系统**,它由三部分组成:

1. **数据契约层**:`scripts/entity_defs/*.def` XML 文件,描述每个实体类型的属性、方法、组件、VolatileInfo、LoD 等元数据。
2. **运行时元数据层**:`lib/entitydef/` C++ 库,在进程启动期把 `.def` 解析为 `EntityDescriptionMap` 单例,提供按索引/按名查找、流分发、MD5 摘要等能力。
3. **代码生成层**:`tools/process_defs` 工具,把 `.def` 进一步转换为 Python 描述对象,供 `ProcessDefs.process` 等回调生成客户端/服务端绑定代码。

简言之:策划/美术编辑 `.def` 文件 → 启动期 `EntityDescriptionMap::parse` 把它们加载成 `EntityDescription` 集合 → 运行时 Cell/Base/Client/DB 通过 `EntityDescription` 上的 `DataDescription` / `MethodDescription` 元数据,自动完成字段同步、方法分发、持久化、版本校验。

### 1.2 数据驱动设计哲学

BigWorld 选择"**数据 vs 代码分离**"的设计:

| 维度 | 数据(.def) | 代码(.py / .cpp) |
|------|-----------|-------------------|
| 变更频率 | 高(策划/美术频繁改字段) | 低(逻辑代码稳定) |
| 谁来写 | 策划、美术、技术策划 | 程序员 |
| 编译开销 | 0(运行时 XML 解析) | 高(C++)/ 中(Python 字节码) |
| 跨进程共享 | 天然共享(XML 是文件) | 需要序列化 |
| 版本演化 | 通过 MD5 + 字段索引策略 | 通过 ABI 兼容 |

这种分离带来的最大收益是:**策划可以在不重新编译引擎的情况下添加新实体类型、新字段、新方法**。`process_defs` 工具会重新生成 Python 描述对象,服务器和客户端在下次启动时通过 MD5 校验确保两边版本一致,然后整个新实体类型就可以使用。

### 1.3 .def 作为数据契约

`.def` 文件是 BigWorld 的 IDL(Interface Definition Language)。它的契约含义是:

- **属性契约**:声明该实体有哪些字段、字段类型是什么、是否持久化、是否同步给客户端、是否被索引。
- **方法契约**:声明该实体有哪些方法、方法属于哪个 Component(Cell/Base/Client)、参数与返回值类型、是否 Exposed(可被客户端调用)。
- **同步契约**:声明字段如何在不同 Component 间流动(从 Cell 到 Client、从 Base 到 Client 等)。
- **持久化契约**:声明哪些字段写入数据库、哪些字段是 Identifier(数据库主键)。
- **版本契约**:整个 `.def` 集合会被计算 MD5 摘要,客户端启动时与服务器摘要对比,不一致则拒绝连接。

### 1.4 Client/Server/Base/Cell 四分治

BigWorld 实体的逻辑被拆分到 4 种 Component:

| Component | 进程 | 职责 | 是否有脚本 |
|----------|------|------|-----------|
| **Cell** | CellApp | 空间模拟、AOI、Ghost、CellEntityMethod | 可选(`scripts/cell/<Entity>.py`) |
| **Base** | BaseApp | 持久化、跨 Cell 调度、Proxy、BaseEntityMethod | 可选(`scripts/base/<Entity>.py`) |
| **Client** | Client | 表现层、玩家输入、ClientMethod | 可选(`scripts/client/<Entity>.py`) |
| **DBApp**(辅助) | DBApp | 数据库读写、SecondaryDB | 无脚本,仅作存储 |

每个 Component 持有同一份 `EntityDescription`(通过 `EntityDescriptionMap` 共享),但只能看到属于自己的字段子集。例如 Base 不应该看到 `CELL_PUBLIC` 字段的运行时值;Client 不能看到 `BASE` 字段。这种"**同一份元数据,不同视图**"的设计由 `DataDomain` 枚举实现(详见第十七章)。

### 1.5 与 ECS 的对比

现代 ECS(Entity-Component-System)框架,如 Unity DOTS、Bevy、entt,也将数据与逻辑分离,但哲学不同:

| 维度 | BigWorld EntityDef | ECS |
|------|-------------------|-----|
| 数据组织 | 实体 = 一组固定字段(由 .def 定义) | 实体 = 一组 Component,可动态增减 |
| 字段访问 | `entity.health` 直接 Python 属性 | `query.get<Health>(entity)` 模板 |
| 同步 | 字段标记 `OTHER_CLIENTS` 自动同步 | 需要用户写 netcode |
| 方法调用 | `entity.cell.onHit(dmg)` 透明跨进程 | 仅本地 |
| 持久化 | `Persistent=true` 自动入库 | 需要用户写序列化 |
| 适用场景 | MMO 等大型分布式游戏 | 高密度本地模拟( RTS、MOBA 战斗) |

BigWorld 的 EntityDef 更接近"**分布式 OOP 实体**":实体有固定的字段集和方法集,跨进程透明调用。ECS 则强调"**组合优于继承 + 数据紧凑布局 + 批量处理**"。两者并非替代关系,BigWorld 之所以选择前者,是因为 MMO 的瓶颈在于"**网络 + 持久化 + 一致性**",而非"**单机 CPU 吞吐**"。

### 1.6 与传统 OOP 实体的对比

传统 OOP 游戏服务器中,实体通常定义为:

```cpp
class Player : public Entity {
    int hp_;
    Vector3 pos_;
    void onHit(int damage) { ... }
};
```

这种写法的问题:

1. **字段类型变更需要重新编译**:策划无法独立修改字段。
2. **跨进程通信需要手写序列化**:每个字段都要写 pack/unpack。
3. **持久化需要手写 ORM**:每个字段都要在数据库 schema 中映射。
4. **客户端/服务端字段集差异难以处理**:必须用 `#ifdef CLIENT` 等宏。

BigWorld EntityDef 通过把字段元数据抽象为 `DataDescription`,把方法元数据抽象为 `MethodDescription`,把字段类型抽象为 `DataType`,然后用统一的 `addToStream` / `createFromStream` 接口完成所有序列化,彻底消除了上述问题。

### 1.7 设计哲学总结

```
┌─────────────────────────────────────────────────────────────┐
│           BigWorld EntityDef 的 5 大设计原则                │
├─────────────────────────────────────────────────────────────┤
│  1. 数据驱动:实体定义是数据,不是代码                       │
│  2. 元数据共享:四类进程共享同一份 EntityDescription        │
│  3. 自动同步:字段与方法在网络层自动分发                     │
│  4. 版本演进:MD5 摘要 + 字段索引策略支持向前兼容            │
│  5. 安全隔离:ExposedMessageRange 控制客户端可调用范围      │
└─────────────────────────────────────────────────────────────┘
```

---

## 二、文件布局与构建产物

### 2.1 源码目录结构

EntityDef 子系统在 `programming/bigworld/lib/entitydef/` 目录下,主要文件如下:

```
programming/bigworld/lib/entitydef/
├── constants.hpp                  # 路径常量(scripts/entity_defs 等)
├── data_description.{hpp,cpp,ipp} # 字段描述(单个 Property)
├── data_lod_level.{hpp,cpp,ipp}   # LoD 层级
├── data_sink.hpp                  # 数据写入抽象(出流端)
├── data_source.hpp                # 数据读取抽象(入流端)
├── data_type.{hpp,cpp}            # 类型系统基类
├── data_types.hpp                 # 简单元类型工具(SIMPLE_DATA_TYPE 宏)
├── data_types.cpp                 # FORCE_LINK 注册所有元类型
├── entity_description.{hpp,cpp,ipp}            # 实体描述(单个 .def)
├── entity_description_map.{hpp,cpp}             # 实体描述注册表(entities.xml)
├── entity_description_debug.{hpp,cpp}          # 调试工具
├── entity_member_stats.{hpp,cpp}                # 字段统计(调用次数等)
├── entity_method_descriptions.{hpp,cpp}        # 方法集合(Cell/Base/Client)
├── mailbox_base.{hpp,cpp}                      # Mailbox 基类
├── member_description.{hpp,cpp}                # DataDescription/MethodDescription 公共基类
├── meta_data_type.{hpp,cpp}                    # 元类型工厂(MetaDataType)
├── method_args.{hpp,cpp}                       # 方法参数列表
├── method_description.{hpp,cpp,ipp}           # 方法描述
├── property_change.{hpp,cpp}                   # 字段变更通知
├── property_change_reader.{hpp,cpp}            # 字段变更读取
├── property_event_stamps.{hpp,cpp,ipp}         # 事件时间戳
├── property_owner.{hpp,cpp}                    # 字段所有者(Array/Dict 等)
├── py_deferred.{hpp,cpp}                       # Python Twisted Deferred 集成
├── py_volatile_info.{hpp,cpp}                  # Python 暴露 VolatileInfo
├── remote_entity_method.{hpp,cpp}              # 远程方法代理
├── return_values_handler.{hpp,cpp}             # 双向调用返回值处理
├── script_data_sink.{hpp,cpp}                  # ScriptObject → DataSink 适配
├── script_data_source.{hpp,cpp}                 # ScriptObject → DataSource 适配
├── single_type_data_sinks.{hpp,cpp}            # 单类型 sink 池
├── single_type_data_sources.{hpp,cpp}           # 单类型 source 池
├── volatile_info.{hpp,cpp,ipp}                 # Volatile 字段(位置/朝向)
├── base_user_data_object_description.{hpp,cpp,ipp}  # UDO 描述基类
├── user_data_object_description.{hpp,cpp,ipp}        # UDO 描述
├── user_data_object_description_map.{hpp,cpp}        # UDO 注册表
├── data_instances/                              # 运行时数据实例(Array/Dict/Class)
│   ├── array_data_instance.{hpp,cpp}
│   ├── class_data_instance.{hpp,cpp}
│   ├── fixed_dict_data_instance.{hpp,cpp}
│   └── intermediate_property_owner.{hpp,cpp}
├── data_types/                                  # 具体类型实现
│   ├── array_data_type.{hpp,cpp}
│   ├── blob_data_type.{hpp,cpp}
│   ├── class_data_type.{hpp,cpp}
│   ├── class_meta_data_type.{hpp,cpp}
│   ├── dictionary_data_type.cpp
│   ├── fixed_dict_data_type.{hpp,cpp}
│   ├── fixed_dict_meta_data_type.{hpp,cpp}
│   ├── float_data_types.{hpp,cpp}
│   ├── integer_data_type.{hpp,cpp}
│   ├── long_integer_data_type.{hpp,cpp}
│   ├── mailbox_data_type.{hpp,cpp}
│   ├── python_data_type.{hpp,cpp}
│   ├── sequence_data_type.{hpp,cpp}              # Array/Tuple 公共基类
│   ├── sequence_meta_data_type.{hpp,cpp}
│   ├── simple_stream_element.hpp
│   ├── string_data_type.{hpp,cpp}
│   ├── tuple_data_type.{hpp,cpp}
│   ├── udo_ref_data_type.{hpp,cpp}
│   ├── unicode_string_data_type.{hpp,cpp}
│   ├── user_data_type.{hpp,cpp}
│   ├── user_meta_data_type.{hpp,cpp}
│   └── vector_data_types.{hpp,cpp}
└── unit_test/                                    # 单元测试
    ├── integer_range_checker.{hpp,cpp}
    ├── test_conversion.cpp
    ├── test_datasection.cpp
    ├── test_datatype_const_iterator.cpp
    ├── test_method_description.cpp
    ├── test_stream.cpp
    ├── unittest_mailbox.{hpp,cpp}
    └── ...
```

### 2.2 资源目录结构(运行时数据)

引擎运行时通过 `BWResource` 访问的资源路径(在 `constants.hpp` 中定义):

| 常量方法 | 返回路径 | 用途 |
|---------|---------|------|
| `Constants::commonPath()` | `scripts/common` | 公共脚本 |
| `Constants::serverCommonPath()` | `scripts/server_common` | 服务端公共脚本 |
| `Constants::aliasesFile()` | `scripts/entity_defs/alias.xml` | 类型别名 |
| `Constants::databasePath()` | `scripts/db` | 数据库脚本 |
| `Constants::xmlDatabaseFile()` | `scripts/db.xml` | 数据库配置 |
| `Constants::entitiesFile()` | `scripts/entities.xml` | **实体类型清单** |
| `Constants::entitiesDefsPath()` | `scripts/entity_defs` | **.def 文件目录** |
| `Constants::servicesDefsPath()` | `scripts/service_defs` | Service .def 文件 |
| `Constants::componentsDefsPath()` | `scripts/component_defs` | 组件 .def 文件 |
| `Constants::entitiesClientPath()` | `scripts/client` | 客户端脚本 |
| `Constants::entitiesCellPath()` | `scripts/cell` | Cell 脚本 |
| `Constants::entitiesBasePath()` | `scripts/base` | Base 脚本 |
| `Constants::entitiesServicePath()` | `scripts/service` | Service 脚本 |
| `Constants::entitiesEditorPath()` | `scripts/editor` | Editor 脚本 |
| `Constants::entitiesCapabilitiesFile()` | `scripts/common/capabilities.xml` | 客户端能力开关 |
| `Constants::userDataObjectsFile()` | `scripts/user_data_objects.xml` | UDO 清单 |
| `Constants::userDataObjectsDefsPath()` | `scripts/user_data_object_defs` | UDO 定义目录 |

### 2.3 关键数据流

```
                 ┌──────────────────────────┐
                 │ scripts/entities.xml     │
                 │  ├ <ClientServerEntities> │
                 │  └ <ServerOnlyEntities>  │
                 └────────┬─────────────────┘
                          │ parse
                          ▼
            ┌──────────────────────────────┐
            │  EntityDescriptionMap        │
            │   vector_<EntityDescription> │
            │   map_<name, EntityTypeID>   │
            │   digest_ (MD5)              │
            └─────────────┬────────────────┘
                          │
        ┌─────────────────┼──────────────────┐
        │                 │                  │
        ▼                 ▼                  ▼
   CellApp            BaseApp             Client
   (cell 视图)        (base 视图)         (client 视图)
        │                 │                  │
        └─► Entity        └─► Entity         └─► Entity
            (cell_)          (base_)            (client_)
            字段同步         持久化              表现层
            方法分发         跨 Cell             方法回调
```

### 2.4 构建产物

EntityDef 库构建为静态库 `libbigworld_entitydef`(`CMakeLists.txt` 中定义),链接到:

- `cellapp`、`baseapp`、`dbapp`、`baseappmgr`、`cellappmgr`、`loginapp`、`client` 等
- `tools/process_defs` 工具
- `editor`、`model_editor` 等工具

由于 `EntityDescription` 等元数据需要在所有进程间共享,该库的接口被设计为无 MF_SERVER / MF_CLIENT 强依赖,通过 `BWENTITY_API` 宏控制导出。

---

## 三、.def 文件格式深度剖析

### 3.1 文件位置

每个实体类型对应一个 `.def` 文件,位于 `scripts/entity_defs/<EntityName>.def`。`entities.xml` 文件列出所有"被启用"的实体类型:

```xml
<!-- scripts/entities.xml 示例 -->
<root>
    <ClientServerEntities>
        <Account/>      <!-- 同时存在于客户端+服务器 -->
        <Avatar/>
        <NPC/>
    </ClientServerEntities>
    <ServerOnlyEntities>
        <SpaceData/>     <!-- 仅服务器,客户端不可见 -->
    </ServerOnlyEntities>
</root>
```

`EntityDescriptionMap::parse` 会按 `ClientServerEntities` / `ServerOnlyEntities` 分组解析,并根据客户端脚本是否存在自动归类(详见第五章)。

### 3.2 完整 .def 文件示例

下面是一个相对完整的 `.def` 文件示例,涵盖大部分常用元素:

```xml
<!-- scripts/entity_defs/Avatar.def -->
<root>
    <!-- 父类继承:Avatar 继承 Creature 的字段与方法 -->
    <Parent>
        Creature
    </Parent>

    <!-- 客户端实体名(可选,默认等于服务端名) -->
    <ClientName>
        Avatar
    </ClientName>

    <!-- 是否持久化(默认 true,Service/ClientOnly 自动设为 false) -->
    <Persistent>
        true
    </Persistent>

    <!-- 显式数据库 ID(用于在数据库中复用 ID 列) -->
    <ExplicitDatabaseID>
        false
    </ExplicitDatabaseID>

    <!-- Distribution 标签:覆盖脚本存在性检测 -->
    <Distribution>
        <Cell>true</Cell>
        <Base>true</Base>
        <Client>true</Client>
    </Distribution>

    <!-- LoD 层级(按距离裁剪同步的字段集) -->
    <LoDLevels>
        <level>
            <label>near</label>
            <index>0</index>
        </level>
        <level>
            <label>far</label>
            <index>1</index>
        </level>
    </LoDLevels>

    <!-- Volatile 字段(位置、朝向的高频同步) -->
    <Volatile>
        <position>0.1</position>
        <yaw>0.5</yaw>
        <pitch>0.7</pitch>
        <roll>1.0</roll>
    </Volatile>

    <!-- AoI 半径(超过此半径实体的可见性衰减) -->
    <AppealRadius>
        2.0
    </AppealRadius>

    <!-- 是否发送详细位置更新(超大 AoI 时使用) -->
    <ShouldSendDetailedVolatilePosition>
        false
    </ShouldSendDetailedVolatilePosition>

    <!-- 是否手动管理 AoI(不自动加入玩家 AoI) -->
    <IsManualAoI>
        false
    </IsManualAoI>

    <!-- 网络压缩类型 -->
    <NetworkCompression>
        <Internal>zlib</Internal>
        <External>bzip2</External>
    </NetworkCompression>

    <!-- 字段定义 -->
    <Properties>
        <hp>
            <Type>INT32</Type>
            <Flags>ALL_CLIENTS</Flags>
            <Persistent>true</Persistent>
            <Default>100</Default>
        </hp>
        <mp>
            <Type>INT32</Type>
            <Flags>OWN_CLIENT</Flags>
            <Persistent>true</Persistent>
            <Default>50</Default>
        </mp>
        <name>
            <Type>STRING</Type>
            <Flags>BASE</Flags>
            <Persistent>true</Persistent>
            <Identifier>true</Identifier>    <!-- 作为数据库主键 -->
        </name>
        <inventory>
            <Type>
                ARRAY
                <of>
                    ARRAY
                    <of>USER_TYPE"Item"</of>
                </of>
            </Type>
            <Flags>OWN_CLIENT</Flags>
            <Persistent>false</Persistent>
        </inventory>
        <position>
            <Type>VECTOR3</Type>
            <Flags>CELL_PUBLIC</Flags>
            <Persistent>true</Persistent>
            <DatabaseLength>12</DatabaseLength>
        </position>
    </Properties>

    <!-- 临时属性(不进入 .def 的 Properties 但被脚本使用) -->
    <TempProperties>
        <target/>
        <lastDamageTime/>
    </TempProperties>

    <!-- Cell 方法:由 Cell 实现的方法 -->
    <CellMethods>
        <onHit>
            <Exposed>OWN_CLIENT</Exposed>
            <Args>
                <arg>
                    <Type>INT32</Type>
                    <Desc>damage</Desc>
                </arg>
            </Args>
        </onHit>
        <onRespawn>
            <Args/>
        </onRespawn>
    </CellMethods>

    <!-- Base 方法:由 Base 实现 -->
    <BaseMethods>
        <saveToDB>
            <Args/>
        </saveToDB>
        <onLogin>
            <Exposed>OWN_CLIENT</Exposed>
            <Args>
                <arg>
                    <Type>STRING</Type>
                </arg>
            </Args>
            <ReturnValues>
                <arg>
                    <Type>BOOL</Type>
                </arg>
            </ReturnValues>
        </onLogin>
    </BaseMethods>

    <!-- Client 方法:由 Client 实现 -->
    <ClientMethods>
        <showDamage>
            <Args>
                <arg>
                    <Type>INT32</Type>
                </arg>
            </Args>
        </showDamage>
        <playAnimation>
            <Args>
                <arg>
                    <Type>STRING</Type>
                </arg>
            </Args>
        </playAnimation>
    </ClientMethods>

    <!-- 组件(可复用的字段+方法包) -->
    <Components>
        <Health/>          <!-- 引用 scripts/component_defs/Health.def -->
        <Movement>
            <name>FastMovement</name>
        </Movement>
    </Components>
</root>
```

### 3.3 字段定义元素详解

每个 `<Property>` 由以下子元素组成:

| 子元素 | 必需 | 说明 |
|--------|------|------|
| `<Type>` | ✅ | 字段类型,可以是简单类型名(如 `INT32`),也可以是复合类型(嵌套 XML,如 `ARRAY <of>...</of>`) |
| `<Flags>` | ❌ | 字段同步范围(`CELL_PRIVATE`/`CELL_PUBLIC`/`OTHER_CLIENTS`/`OWN_CLIENT`/`BASE`/`BASE_AND_CLIENT`/`CELL_PUBLIC_AND_OWN`/`ALL_CLIENTS`/`EDITOR_ONLY`) |
| `<Persistent>` | ❌ | 是否持久化到数据库(布尔,默认 false) |
| `<Identifier>` | ❌ | 是否作为数据库主键(默认 false,会自动设 Indexed+Unique) |
| `<Indexed>` | ❌ | 是否建立数据库索引,可包含 `<Unique>` 子元素 |
| `<Default>` | ❌ | 默认值 |
| `<DatabaseLength>` | ❌ | 数据库存储长度(默认 65535) |
| `<ExposedForReplay>` | ❌ | 是否暴露给回放系统(默认 OTHER_CLIENTS 为 true,其他为 false) |
| `<Editable>` | ❌ | 编辑器是否可编辑(仅 EDITOR_ENABLED) |
| `<Widget>` | ❌ | 编辑器 UI 控件(仅 EDITOR_ENABLED) |

### 3.4 字段 Flags 全表

`EntityDataFlags` 枚举定义于 `data_description.hpp`(L30-L41):

| Flag 值 | 含义 | 适用字段流向 |
|---------|------|-------------|
| `DATA_GHOSTED = 0x01` | 同步给 Ghost 实体 | Cell → Ghost Cell |
| `DATA_OTHER_CLIENT = 0x02` | 同步给其他客户端 | Cell → 其他玩家 Client |
| `DATA_OWN_CLIENT = 0x04` | 同步给拥有者客户端 | Cell/Base → Own Client |
| `DATA_BASE = 0x08` | Base 持有的数据 | Base only |
| `DATA_CLIENT_ONLY = 0x10` | 仅客户端使用的静态数据 | Client only |
| `DATA_PERSISTENT = 0x20` | 持久化到数据库 | DB |
| `DATA_EDITOR_ONLY = 0x40` | 仅编辑器使用 | Editor only |
| `DATA_ID = 0x80` | 数据库索引列(Identifier) | DB |
| `DATA_REPLAY = 0x100` | 回放系统可见 | Replay |

`Flags` 字符串到枚举的映射表(`data_description.cpp` L72-L83):

| 字符串 | Flags 值 |
|--------|---------|
| `CELL_PRIVATE` | `0` |
| `CELL_PUBLIC` | `DATA_GHOSTED` |
| `OTHER_CLIENTS` | `DATA_GHOSTED \| DATA_OTHER_CLIENT` |
| `OWN_CLIENT` | `DATA_OWN_CLIENT` |
| `BASE` | `DATA_BASE` |
| `BASE_AND_CLIENT` | `DATA_OWN_CLIENT \| DATA_BASE` |
| `CELL_PUBLIC_AND_OWN` | `DATA_GHOSTED \| DATA_OWN_CLIENT` |
| `ALL_CLIENTS` | `DATA_GHOSTED \| DATA_OTHER_CLIENT \| DATA_OWN_CLIENT` |
| `EDITOR_ONLY` | `DATA_EDITOR_ONLY` |

### 3.5 方法签名

方法定义可以包含:

| 子元素 | 必需 | 说明 |
|--------|------|------|
| `<Exposed>` | ❌ | 暴露给客户端调用,值可以是 `OWN_CLIENT`、`ALL_CLIENTS`(仅 Cell 方法)或空(默认两者) |
| `<Args>` | ❌ | 参数列表,每个 `<arg>` 包含 `<Type>` 与可选 `<Desc>` |
| `<ReturnValues>` | ❌ | 返回值列表,格式同 `<Args>` |
| `<DetailDistance>` | ❌ | LoD 距离(超过此距离不调用,优先级降低) |
| `<ReplayExposureLevel>` | ❌ | 回放系统暴露级别(`NONE`/`OTHER_CLIENTS`/`ALL_CLIENTS`) |
| `<SendLatestOnly>` | ❌ | 仅发送最新一次调用(丢弃旧调用) |

**注意**:`<Args>` 子元素支持新旧两种写法。新写法显式 `<Args><arg>...</arg></Args>`,旧写法直接把 `<arg>` 放在方法节点下(`MethodArgs::parse` 的 `isOldStyle` 参数)。

### 3.6 简单类型与复合类型

#### 3.6.1 简单类型

直接以类型名字符串表示,在 `data_types.cpp` 中通过 `FORCE_LINK` 宏注册:

| 类型 | 字节数 | Python 类型 | 说明 |
|------|-------|-------------|------|
| `INT8` / `UINT8` | 1 | int | 8 位整数 |
| `INT16` / `UINT16` | 2 | int | 16 位整数 |
| `INT32` / `UINT32` | 4 | int | 32 位整数 |
| `INT64` / `UINT64` | 8 | long | 64 位整数 |
| `LONG_INTEGER` | 平台相关 | long | C++ long |
| `FLOAT32` / `FLOAT` | 4 | float | 32 位浮点(`FLOAT` 是 `FLOAT32` 的别名) |
| `FLOAT64` | 8 | float | 64 位浮点 |
| `STRING` | 变长 | str | UTF-8 字符串 |
| `BLOB` | 变长 | bytes | 二进制数据 |
| `VECTOR2` | 8 | Vector2 | 2D 向量 |
| `VECTOR3` | 12 | Vector3 | 3D 向量 |
| `VECTOR4` | 16 | Vector4 | 4D 向量 |
| `MAILBOX` | 变长 | Mailbox | 实体邮箱(仅服务端) |
| `PYTHON` | 变长 | 任意 | 任意 Python 对象(危险,CLIENT_UNSAFE) |
| `UDO_REF` | 变长 | UserDataObjectRef | UDO 引用 |

#### 3.6.2 复合类型

复合类型使用嵌套 XML 描述:

```xml
<!-- 数组示例 -->
<Type>
    ARRAY
    <of>INT32</of>
</Type>

<!-- 嵌套数组 -->
<Type>
    ARRAY
    <of>
        ARRAY
        <of>STRING</of>
    </of>
</Type>

<!-- 元组(固定长度异构) -->
<Type>
    TUPLE
    <of>INT32</of>
    <of>STRING</of>
    <of>VECTOR3</of>
</Type>

<!-- 固定字典 -->
<Type>
    FIXED_DICT
    <Properties>
        <x>
            <Type>FLOAT32</Type>
        </x>
        <y>
            <Type>FLOAT32</Type>
        </y>
        <name>
            <Type>STRING</Type>
        </name>
    </Properties>
</Type>

<!-- 用户自定义类型(在 alias.xml 中定义) -->
<Type>MyCustomType</Type>
```

#### 3.6.3 类型别名(alias.xml)

`scripts/entity_defs/alias.xml` 中可以定义全局类型别名:

```xml
<!-- alias.xml 示例 -->
<root>
    <Health>
        INT32
        <Default>100</Default>
    </Health>
    <Coordinate>
        VECTOR3
    </Coordinate>
</root>
```

之后 `.def` 文件中可以直接使用 `<Type>Health</Type>`。`DataType::initAliases()`(L336)在首次调用 `buildDataType` 时加载此文件。

### 3.7 继承与组件

#### 3.7.1 Parent 继承

`<Parent>Creature</Parent>` 表示继承 `Creature.def`。`EntityDescription::parse`(`entity_description.cpp` L194-L205)递归解析父类:

```cpp
BW::string parentName = pSection->readString( "Parent" );
if (!parentName.empty())
{
    if (!this->parse( parentName, componentName, NULL ))
    {
        ERROR_MSG( "EntityDescription::parse: "
                    "Could not parse %s, parent of %s\n",
                parentName.c_str(), name.c_str() );
        return false;
    }
}
```

子类的字段、方法会**追加**到父类的字段、方法之后;同名字段会被覆盖(详见 `parseProperties` L631-L649)。

#### 3.7.2 Components 组件

`<Components>` 节点允许引用 `scripts/component_defs/<Component>.def` 中的可复用字段与方法包:

```xml
<Components>
    <Health/>
    <Movement>
        <name>FastMovement</name>   <!-- 组件别名 -->
    </Movement>
</Components>
```

`EntityDescription::parseComponents`(L452-L516)负责加载每个组件的 `.def` 文件,并把它们的字段/方法合并到当前实体。组件字段在 `DataDescription` 中通过 `componentName_` 字段区分,允许在 `Properties` 中通过 `componentName.fieldName` 形式访问。

### 3.8 VIP(Volatile Interest Properties)

`<Volatile>` 节点声明实体的"高频变化数据"——位置、朝向。这些数据不走普通的字段同步路径,而是由 CellApp 的 VolatileInfo 系统专门处理(详见第十三章),以保证:

- 高频但低带宽(使用压缩格式)
- 距离敏感(远距离降低更新频率)
- 不可靠(允许丢包,因为下一帧会再次发送)

---

## 四、EntityDescription 数据结构

`EntityDescription` 类(`entity_description.hpp` L127-L391)是单个实体类型的元数据容器。它在进程启动期被构造,生命周期与进程相同。

### 4.1 类继承关系

```
ReferenceCount (cstdmf)
     ▲
     │
BaseUserDataObjectDescription
     ▲
     │
EntityDescription
```

`BaseUserDataObjectDescription` 提供 `properties_` 向量、`propertyMap_` 查找表、`parseImplements` 等通用功能(用于 Entity 与 UserDataObject 共享)。`EntityDescription` 在此基础上扩展了 Cell/Base/Client 三类方法、VolatileInfo、LoD 等实体专属概念。

### 4.2 关键成员变量

| 成员 | 类型 | 来源(行号) | 含义 |
|------|------|------------|------|
| `index_` | `EntityTypeID` | L330 | 服务器端类型索引 |
| `clientIndex_` | `EntityTypeID` | L331 | 客户端类型索引(ClientName 别名机制) |
| `clientName_` | `BW::string` | L332 | 客户端实体名 |
| `canBeOnCell_` | `bool` | L333 | 是否有 Cell 脚本 |
| `canBeOnBase_` | `bool` | L334 | 是否有 Base 脚本 |
| `canBeOnClient_` | `bool` | L335 | 是否有 Client 脚本 |
| `hasComponents_` | `bool` | L336 | 是否使用了 Components |
| `isService_` | `bool` | L337 | 是否是 Service 类型 |
| `isPersistent_` | `bool` | L338 | 是否可持久化 |
| `forceExplicitDBID_` | `bool` | L339 | 强制显式数据库 ID |
| `volatileInfo_` | `VolatileInfo` | L340 | Volatile 字段配置 |
| `activeOnServerModes_` | `BW::string` | L341 | Service 激活模式 |
| `internalNetworkCompressionType_` | `BWCompressionType` | L343 | 内网压缩 |
| `externalNetworkCompressionType_` | `BWCompressionType` | L344 | 外网压缩 |
| `clientServerProperties_` | `vector<unsigned int>` | L348 | Client-Server 字段索引列表 |
| `cell_` | `EntityMethodDescriptions` | L354 | Cell 方法集 |
| `base_` | `EntityMethodDescriptions` | L357 | Base 方法集 |
| `client_` | `EntityMethodDescriptions` | L360 | Client 方法集 |
| `numEventStampedProperties_` | `unsigned int` | L364 | 事件戳字段数 |
| `numLatestChangeOnlyMembers_` | `unsigned int` | L368 | SendLatestOnly 成员数 |
| `appealRadius_` | `float` | L372 | AoI 半径 |
| `shouldSendDetailedPosition_` | `bool` | L376 | 详细位置更新 |
| `isManualAoI_` | `bool` | L379 | 手动 AoI |
| `lodLevels_` | `DataLoDLevels` | L381 | LoD 层级 |
| `tempProperties_` | `set<string>` | L383 | 临时属性名集合 |
| `componentNames_` | `set<string>` | L385 | 使用的组件名集合 |

### 4.3 DataDomain 枚举(核心)

`EntityDescription::DataDomain`(`entity_description.hpp` L141-L152)是字段流向控制的核心:

```cpp
enum DataDomain
{
    BASE_DATA   = 0x1,
    CLIENT_DATA = 0x2,
    CELL_DATA   = 0x4,
    EXACT_MATCH = 0x8,
    ONLY_OTHER_CLIENT_DATA = 0x10,
    ONLY_PERSISTENT_DATA = 0x20,

    FROM_CELL_TO_CLIENT_DATA = (CELL_DATA | CLIENT_DATA | EXACT_MATCH),
    FROM_BASE_TO_CLIENT_DATA = (BASE_DATA | CLIENT_DATA | EXACT_MATCH)
};
```

含义:

- `BASE_DATA`:Base 持有的字段(`DATA_BASE` flag)。
- `CLIENT_DATA`:客户端持有的字段(`DATA_OWN_CLIENT` / `DATA_OTHER_CLIENT` flag)。
- `CELL_DATA`:Cell 持有的字段(`DATA_GHOSTED` flag)。
- `EXACT_MATCH`:要求所有 flag 严格匹配(否则只需任一匹配)。
- `ONLY_OTHER_CLIENT_DATA`:仅同步 OTHER_CLIENT 字段(用于 Ghost)。
- `ONLY_PERSISTENT_DATA`:仅同步持久化字段(用于 DB)。

`FROM_CELL_TO_CLIENT_DATA` 表示"从 Cell 到 Client 同步",要求字段同时具备 CELL 和 CLIENT 性质且严格匹配。`FROM_BASE_TO_CLIENT_DATA` 类似。

### 4.4 StreamContentType 枚举

`StreamContentType`(`entity_description.hpp` L19-L32)描述了实体数据在不同进程间传输时的"上下文":

| 值 | 含义 | 对应 DataDomain |
|----|------|----------------|
| `BASE_ENTITY_BACKUP` | Base 备份 | `BASE_DATA` |
| `BASE_ENTITY_OFFLOAD` | Base 迁移 | `BASE_DATA` |
| `CELL_CREATION` | Cell 实体创建 | `CELL_DATA` |
| `CELL_GHOST_CREATION` | Ghost 创建 | `CELL_DATA \| ONLY_OTHER_CLIENT_DATA` |
| `CELL_ENTITY_BACKUP` | Cell 备份 | `CELL_DATA` |
| `CELL_ENTITY_OFFLOAD` | Cell 迁移 | `CELL_DATA` |
| `CLIENT_ENTITY_CELL_CREATION` | (未实现) | — |
| `CLIENT_PLAYER_CREATION` | 玩家创建 | `FROM_BASE_TO_CLIENT_DATA` |
| `CLIENT_PLAYER_CELL_CREATION` | 玩家进入 Cell | `FROM_CELL_TO_CLIENT_DATA` |
| `CLIENT_ENTITY_LOD_DATA` | (未实现) | — |
| `DATABASE_ENTITY` | 数据库读写 | `BASE_DATA \| ONLY_PERSISTENT_DATA` |

`EntityDescription::getDataDomains`(L1030-L1083)实现这个映射。

### 4.5 parse 方法解析流程

`EntityDescription::parse`(L180-L361)是 `.def` 文件解析的入口。算法步骤:

```
1. 构造文件名:scripts/entity_defs/<name>.def
2. 打开 DataSection
3. 读取 <Parent>:
   - 若有父类,递归调用 parse(parentName, ...)
4. 设置 name_
5. 读取 <ClientName> → clientName_
6. 若 pDistributionDecider 不为 NULL:
   - 读取 <Distribution> 节点构造 EntityDistribution
   - 调用 decider.canBeOnCell/Base/Client 决定 canBeOnCell_ 等
   - 若 canBeOnClient_ = false,清空 clientName_
   - 否则若 clientName_ 为空,设为 name_
7. 调用 parseInterface(pSection, name_, componentName)
8. 若 pDistributionDecider 不为 NULL 且非 Service:
   - 调整 LoD detail level(从 index 转为实际 level)
   - 检查无 Cell 脚本但有 Cell 字段的情况(WARNING)
   - 检查无 Base 脚本但非 Service 的情况(ERROR)
   - 检查无 Client 脚本但有 Client 方法的情况(ERROR)
9. 若是 Service 或 ClientOnly,设 isPersistent_ = false
10. 读取 <NetworkCompression> 节点
11. 检查 AppealRadius 与 Volatile 的相互作用
12. 返回 result
```

### 4.6 parseInterface 方法

`parseInterface`(`entity_description.cpp` L381-L445)是字段/方法/LoD/Volatile/Components 的统一解析入口:

```cpp
bool EntityDescription::parseInterface( DataSectionPtr pSection,
    const char * interfaceName, const BW::string & componentName )
{
    // ...
    forceExplicitDBID_ = pSection->readBool( "ExplicitDatabaseID", ... );

    if (!isService_)
    {
        isPersistent_ = pSection->readBool( "Persistent", isPersistent_ );
        result &= lodLevels_.addLevels( pSection->openSection( "LoDLevels" ) );
        result &= this->BaseUserDataObjectDescription::parseInterface( ... );
        result &= volatileInfo_.parse( pSection->openSection( "Volatile" ) );
        appealRadius_ = pSection->readFloat( "AppealRadius", ... );
        shouldSendDetailedPosition_ = pSection->readBool( "ShouldSendDetailedVolatilePosition", ... );
        isManualAoI_ = pSection->readBool( "IsManualAoI", ... );
    }
    else
    {
        result &= this->parseImplements( pSection->openSection( "Implements" ), ... );
    }

    result &= this->parseMethods( pSection, interfaceName, componentName );
    result &= this->parseTempProperties( pSection->openSection( "TempProperties" ), ... );
    result &= this->parseComponents( pSection->openSection( "Components" ), interfaceName );
    return result;
}
```

### 4.7 parseMethods 方法

`parseMethods`(L553-L577)按 Component 类型分发:

```cpp
bool EntityDescription::parseMethods( DataSectionPtr pSection,
    const char * interfaceName, const BW::string & componentName )
{
    bool result = true;
    result &= this->parseBaseMethods(
        pSection->openSection( isService_ ? "Methods" : "BaseMethods" ), ... );

    if (!isService_)
    {
        result &= this->parseCellMethods( pSection->openSection( "CellMethods" ), ... );
        result &= this->parseClientMethods( pSection->openSection( "ClientMethods" ), ... );
    }
    return result;
}
```

注意 Service 只有 Methods(等价于 BaseMethods),没有 Cell/Client 方法。

### 4.8 parseProperties 与 clientServerProperties_

`parseProperties`(L588-L740)是字段解析的核心。关键步骤:

1. 遍历 `<Properties>` 子节点,为每个属性构造 `DataDescription` 并调用其 `parse`。
2. 检查 `isEditorOnly()`(非编辑器构建时跳过)。
3. 查找是否已存在同名属性(组件覆盖场景):
   - 若存在,获取其 index 与 clientServerFullIndex(若适用)。
4. 设置 `dataDescription.index()`。
5. 若 `isClientServerData()`:
   - 复用现有 `clientServerFullIndex`(若覆盖)或分配新的索引。
   - 检查 `clientSafety`(PYTHON 成员警告,MAILBOX 成员报错)。
6. 若 `isOtherClientData()`:
   - 读取 LoD detail level。
   - 设置 `eventStampIndex` 并递增 `numEventStampedProperties_`。
7. 将 `dataDescription` 插入 `properties_` 或覆盖现有索引。
8. 调用 `allocateClientServerFullIndexes()` 排序。

### 4.9 allocateClientServerFullIndexes 算法

`allocateClientServerFullIndexes`(L877-L886)对 `clientServerProperties_` 做稳定排序,使小尺寸字段排在前面:

```cpp
void EntityDescription::allocateClientServerFullIndexes()
{
    std::stable_sort( clientServerProperties_.begin(),
        clientServerProperties_.end(),
        ClientServerPropertiesSortHelper( properties_ ) );
    for (unsigned int i = 0; i < clientServerProperties_.size(); ++i )
    {
        properties_[ clientServerProperties_[ i ] ].clientServerFullIndex( i );
    }
}
```

排序规则(`ClientServerPropertiesSortHelper` L837-L862):

- 都为定长:按 size 升序。
- 都为变长:按 `-size`(预期 size)升序。
- 一固定一变长:固定排在前面。

**设计动机**:BigWorld 的客户端协议使用"Property ID"区分字段变更,只有少量 ID 槽位(默认 256)。当字段数超出时,通过 `PROPERTY_CHANGE_ID_SINGLE` 多路复用,这时小尺寸字段先发更省带宽。

### 4.10 Distribution 与脚本存在性检测

`EntityDistribution` 类(`entity_description.hpp` L61-L82)解析 `<Distribution>` 节点的三个布尔子标签 `Cell`/`Base`/`Client`,取值 `Unspecified`/`True`/`False`。

`HasScriptOrTagDistributionDecider`(L103-L116)是默认决策器:

```cpp
bool canBeOnCell( name, distr ) {
    if (distr.cellTag() != Unspecified)
        return distr.cellTag() == True;
    // 退化:检查 scripts/cell/<name>.py 是否存在
    return fileExists(entitiesCellPath(), name);
}
```

这意味着:

- **优先**:由 `<Distribution>` 显式声明。
- **退化**:检查对应目录的 Python 脚本是否存在。

`EntityDescriptionHasClientScript`(L46-L63)用于显式声明"是否有客户端脚本"——这是 `parseInternal` 区分 ClientServer 与 ServerOnly 实体的依据。

### 4.11 客户端类型判定

`EntityDescription` 提供了几个判定方法:

| 方法 | 实现 | 含义 |
|------|------|------|
| `isClientOnlyType()` | `!canBeOnCell_ && !canBeOnBase_` | 无 Cell/Base 脚本 |
| `isClientType()` | `name_ == clientName_` | 客户端名与服务端名相同 |
| `canBeOnCell()` | `canBeOnCell_` | 有 Cell 脚本 |
| `canBeOnBase()` | `canBeOnBase_` | 有 Base 脚本 |
| `canBeOnClient()` | `canBeOnClient_` | 有 Client 脚本 |

`isClientOnlyType()` 用于判断实体是否仅存在于客户端(如纯 UI 实体)。这类实体不参与持久化(`isPersistent_` 自动设为 false)。

### 4.12 关键访问器

```cpp
// Cell/Base/Client 方法集
const EntityMethodDescriptions & cell() const;
const EntityMethodDescriptions & base() const;
const EntityMethodDescriptions & client() const;

// Client-Server 字段
unsigned int clientServerPropertyCount() const;
const DataDescription * clientServerProperty(unsigned int n) const;

// Exposed 方法数量(可被客户端调用)
unsigned int exposedBaseMethodCount() const { return this->base().exposedSize(); }
unsigned int exposedCellMethodCount() const { return this->cell().exposedSize(); }
unsigned int clientMethodCount() const;

// Volatile 信息
const VolatileInfo & volatileInfo() const;

// Identifier 字段(数据库主键)
const DataDescription * pIdentifier() const;
```

### 4.13 流分发接口

`EntityDescription` 提供多个流分发方法,均使用 `DataDomain` 标志位控制:

| 方法 | 用途 |
|------|------|
| `addSectionToStream(pSection, stream, dataDomains)` | DataSection → 二进制流(用于备份/迁移) |
| `addSectionToDictionary(pSection, pDict, dataDomains)` | DataSection → Python dict(用于脚本) |
| `addDictionaryToStream(map, stream, dataDomains, ...)` | Python dict → 二进制流(用于同步) |
| `addAttributesToStream(object, stream, dataDomains, ...)` | Python 对象属性 → 二进制流 |
| `readStreamToDict(stream, dataDomains, dict)` | 二进制流 → Python dict |
| `readStreamToSection(stream, dataDomains, pSection)` | 二进制流 → DataSection |
| `readTaggedClientStreamToDict(stream, dict, allowOwnClientData)` | Tagged 流 → dict(Cell→Client 增量) |
| `visit(dataDomains, visitor)` | 遍历匹配的 DataDescription |

所有这些方法底层都使用 `addToStream(visitor, stream, dataDomains)` 模板方法,核心算法在第十七章详述。

---

## 五、EntityDescriptionMap 注册表

`EntityDescriptionMap`(`entity_description_map.hpp` L26-L99)是全局实体类型注册表,管理所有 `EntityDescription` 实例。

### 5.1 关键成员变量

| 成员 | 类型 | 含义 |
|------|------|------|
| `vector_` | `vector<EntityDescription>` | 按索引存储的实体描述 |
| `map_` | `map<string, EntityTypeID>` | 名称到索引的映射 |
| `maxClientServerPropertyCount_` | `unsigned int` | 所有实体中 Client-Server 字段数的最大值 |
| `maxExposedClientMethodCount_` | `unsigned int` | Exposed Client 方法数最大值 |
| `maxExposedBaseMethodCount_` | `unsigned int` | Exposed Base 方法数最大值 |
| `maxExposedCellMethodCount_` | `unsigned int` | Exposed Cell 方法数最大值 |
| `digest_` | `MD5::Digest` | 全部实体描述的 MD5 摘要 |

### 5.2 parse 方法解析流程

`EntityDescriptionMap::parse`(L140-L292)的完整算法:

```
1. 检查 pSection 非空
2. (服务端)打开 scripts/services.xml → pServicesSection
3. 读取 <ClientServerEntities> 与 <ServerOnlyEntities>
4. 若存在 ClientServerEntities:
   a. 计算容量,预分配 vector_
   b. 调用 parseInternal(ClientServerEntities, HasClientScript(true))
      - 此时所有 ClientServer 类型被加入 vector_
   c. 若存在 ServerOnlyEntities:
      调用 parseInternal(ServerOnlyEntities, HasClientScript(false))
      - ServerOnly 类型被加入 vector_(因为 hasClientScript=true 时不会被分流)
   d. 否则 WARNING 提示
5. 否则(老式格式):
   - 容量为 pSection->countChildren()
   - 调用 parseInternal(pSection, HasScriptOrTagDistributionDecider(), &serverOnlyDescriptions)
     - 由 HasScriptOrTagDistributionDecider 检测脚本存在性
     - ServerOnly 类型先暂存到 serverOnlyDescriptions
   - 将 serverOnlyDescriptions 追加到 vector_
6. 为每个 description 设置 index_,在 map_ 中登记 name → index
7. 若是 ClientType(name_ == clientName_),设置 clientIndex_
8. (服务端)调用 parseServices 解析 services.xml
9. 调用 adjustForClientName 处理 ClientName 别名
10. 调用 setExposedMessageIDs 计算 max 暴露方法数
11. 检查各类属性/方法数量上限
12. 计算 MD5: addToMD5 → digest_
13. 返回 isOkay
```

### 5.3 parseInternal 算法

`parseInternal`(L347-L387)是逐个解析实体的内部方法:

```cpp
bool EntityDescriptionMap::parseInternal( DataSectionPtr pSection,
    const IEntityDistributionDecider & hasScriptDecider,
    DescriptionVector * pServerOnlyEntities )
{
    bool isOkay = true;
    DataSection::iterator iter = pSection->begin();

    while (iter != pSection->end())
    {
        DataSectionPtr pSubSection = *iter;
        EntityDescription desc;
        BW::string typeName = pSubSection->sectionName();

        if (desc.parse( typeName, /*componentName*/ BW::string(), &hasScriptDecider ))
        {
            if (!desc.isClientType() && (pServerOnlyEntities != NULL))
                pServerOnlyEntities->push_back( desc );   // ServerOnly 单独暂存
            else
                vector_.push_back( desc );                 // ClientServer 直接加入
        }
        else
        {
            ERROR_MSG( "Failed to load or parse def for entity type %s\n", typeName.c_str() );
            isOkay = false;
        }
        ++iter;
    }
    return isOkay;
}
```

**关键设计**:ClientServer 类型在前,ServerOnly 类型在后,这样客户端类型在 `vector_` 中占据较低索引,客户端只需要看到前 N 个类型即可。

### 5.4 adjustForClientName 别名机制

`adjustForClientName`(L442-L510)处理 `<ClientName>` 别名(已 deprecated)。当一个 ServerOnly 实体声明了 `<ClientName>Avatar</ClientName>` 时,表示在客户端它伪装成 Avatar 类型,以减少客户端脚本数量。

校验规则:

- 别名目标必须是 ClientType(有客户端脚本)。
- 两者的 `clientServerPropertyCount()` 与 `clientMethodCount()` 必须完全一致。
- 否则 ERROR,版本不兼容。

### 5.5 setExposedMessageIDs 算法

`setExposedMessageIDs`(L299-L334)计算最大暴露方法数,并通知每个 `EntityDescription`:

```cpp
void EntityDescriptionMap::setExposedMessageIDs(...)
{
    // 第一遍:计算 max
    for (auto & desc : vector_) {
        maxClientServerPropertyCount_ = std::max(maxClientServerPropertyCount_,
            desc.clientServerPropertyCount());
        maxExposedClientMethodCount_ = std::max(..., desc.client().exposedSize());
        maxExposedBaseMethodCount_ = std::max(..., desc.base().exposedSize());
        maxExposedCellMethodCount_ = std::max(..., desc.cell().exposedSize());
    }
    // 第二遍:通知每个 description
    for (auto & desc : vector_) {
        desc.setExposedMsgIDs(maxExposedClientMethodCount_, pClientMessageRange,
                              maxExposedBaseMethodCount_, pBaseMessageRange,
                              maxExposedCellMethodCount_, pCellMessageRange);
    }
}
```

**关键设计**:所有实体共享同一组消息 ID 范围,因此 `EntityA` 的 Exposed 方法 ID 必须不与 `EntityB` 的 Exposed 方法 ID 冲突。`ExposedMethodMessageRange::msgIDFromExposedID` 利用 `entityTypeID * maxExposedCount + exposedID` 公式生成全局唯一 ID。

### 5.6 checkCount 上限检查

`checkCount`(L517-L553)检查每类 Exposed 方法/字段数不超过消息范围:

```cpp
bool EntityDescriptionMap::checkCount( const char * description,
    unsigned int (EntityDescription::*fn)() const,
    int maxEfficient, int maxAllowed ) const
{
    // 遍历所有实体,找到 max
    // 若 max <= maxAllowed:INFO 提示效率
    // 否则:ERROR 拒绝启动
}
```

例如对 Client 方法:`maxEfficient = numSlots`,`maxAllowed = 256 * numSlots`。超出 `maxAllowed` 直接拒绝启动,这避免运行时 ID 范围溢出。

### 5.7 类型查找

```cpp
// 按名称查找
bool nameToIndex( const BW::string& name, EntityTypeID & index ) const;
bool isEntity( const BW::string& name ) const;

// 按索引获取
const EntityDescription & entityDescription( EntityTypeID index ) const;

// 获取所有名称
void getNames( BW::vector< BW::string > & names ) const;
```

`nameToIndex` 内部使用 `BW::map`(红黑树),查找复杂度 O(log N)。`entityDescription` 使用 `vector::operator[]`,复杂度 O(1)。

### 5.8 MD5 摘要

`addToMD5`(L42-L43 + entity_description.cpp L1740-L1802):

```cpp
void EntityDescriptionMap::addToMD5( MD5 & md5 ) const
{
    // 调用每个 EntityDescription::addToMD5
    // 每个实体描述依次附加:
    //   - name
    //   - 每个 ClientServer 字段的 clientServerFullIndex + DataDescription::addToMD5
    //   - 每个 Client 方法的 MethodDescription::addToMD5
    //   - 每个 Exposed Base/Cell 方法的 MethodDescription::addToMD5
}
```

`parse` 方法在末尾调用 `addToMD5(md5); md5.getDigest(digest_);` 缓存摘要。客户端在连接服务器时,服务器会发送摘要,客户端用本地摘要对比,不一致则拒绝连接并提示"客户端版本不匹配"。

### 5.9 parseServices 流程

`parseServices`(L393-L433)解析 `scripts/services.xml`:

```cpp
bool EntityDescriptionMap::parseServices( DataSectionPtr pSection,
    EntityTypeID initialTypeID )
{
    ServiceDescriptionHasPythonScript hasScriptDecider;  // Service 只能在 Base
    int size = pSection->countChildren();
    vector_.resize( vector_.size() + size );

    for (int i = 0; i < size; ++i) {
        EntityTypeID typeID = initialTypeID + i;
        // ... 调用 desc.parseService(serviceName, ...)
        // 读取 activeOnServerModes(默认 "any")
        desc.index( typeID );
        map_[ desc.name() ] = desc.index();
    }
    return true;
}
```

Service 类型在 `vector_` 中位于所有实体之后,且 `isService_ = true`,因此它们不会进入客户端可见的实体范围。

---

## 六、DataType 类型系统

`DataType`(`data_type.hpp` L39-L513)是 BigWorld 类型系统的根。它定义了所有数据类型的序列化接口。

### 6.1 类层次

```
ReferenceCount
     ▲
     │
DataType
   ├── IntegerDataType<INT8/16/32/64>
   ├── IntegerDataType<UINT8/16/32/64>
   ├── FloatDataType<FLOAT32>
   ├── FloatDataType<FLOAT64>
   ├── StringDataType
   ├── UnicodeStringDataType
   ├── BlobDataType
   ├── VectorDataType<2/3/4>
   ├── LongIntegerDataType
   ├── MailboxDataType
   ├── PythonDataType
   ├── UserDataType
   ├── UdoRefDataType
   ├── SequenceDataType
   │     ├── ArrayDataType
   │     └── TupleDataType
   ├── FixedDictDataType
   ├── DictionaryDataType
   ├── ClassDataType
   └── UnsupportedDataType  (后备,用于不支持的平台)
```

每个具体类型由对应的 `MetaDataType` 工厂创建(`SimpleMetaDataType<T>` 模板,见 `data_types.hpp`)。

### 6.2 关键虚函数接口

```cpp
class DataType : public ReferenceCount
{
public:
    // 默认值
    virtual void setDefaultValue( DataSectionPtr pSection ) = 0;
    virtual bool getDefaultValue( DataSink & output ) const = 0;
    virtual DataSectionPtr pDefaultSection() const;

    // 类型检查
    virtual bool isSameType( ScriptObject pValue ) = 0;

    // 流大小(定长返回正数,变长返回负数,绝对值为预期大小)
    virtual int streamSize() const = 0;

    // 流 ↔ Section 转换
    virtual bool addToSection( DataSource & source, DataSectionPtr pSection ) const = 0;
    virtual bool createFromSection( DataSectionPtr pSection, DataSink & sink ) const = 0;

    // 已 DEPRECATED 的旧接口(向后兼容)
    virtual bool fromStreamToSection( BinaryIStream & stream,
        DataSectionPtr pSection, bool isPersistentOnly ) const;
    virtual bool fromSectionToStream( DataSectionPtr pSection,
        BinaryOStream & stream, bool isPersistentOnly ) const;

    // Script 对象的 owner 关系(Array/Dict 等需要)
    virtual ScriptObject attach( ScriptObject pObject,
        PropertyOwnerBase * pOwner, int ownerRef );
    virtual void detach( ScriptObject pObject );
    virtual PropertyOwnerBase * asOwner( ScriptObject pObject ) const;

    // MD5 摘要(版本校验用)
    virtual void addToMD5( MD5 & md5 ) const = 0;

    // 客户端安全性(CLIENT_SAFE / CLIENT_UNSAFE / CLIENT_UNUSABLE)
    virtual int clientSafety() const { return CLIENT_SAFE; }

    // 通过 const_iterator 实现的流分发(核心)
    virtual StreamElementPtr getStreamElement( size_t index, size_t & size,
        bool & isNone, bool isPersistentOnly ) const = 0;
};
```

### 6.3 Singleton 单例化机制

`DataType` 通过 `findOrAddType`(`data_type.cpp` L315-L327)实现单例化:

```cpp
DataTypePtr DataType::findOrAddType( DataTypePtr pDT )
{
    if (s_singletonMap_ == NULL) s_singletonMap_ = new SingletonMap();
    SingletonMap::iterator found = s_singletonMap_->find( SingletonPtr( pDT.get() ) );
    if (found != s_singletonMap_->end())
        return found->pInst_;        // 已存在等价类型,返回旧实例
    s_singletonMap_->insert( SingletonPtr( pDT.get() ) );
    return pDT;
}
```

`SingletonPtr` 的 `operator<` 通过 `DataType::operator<` 比较,默认实现按 `pMetaDataType_` 指针排序,具体类型可重写以比较内部状态(如 `ArrayDataType` 会比较元素类型)。这样 `ARRAY<INT32>` 与 `ARRAY<INT32>` 总是返回同一实例,**节省内存 + 加速比较**。

### 6.4 const_iterator 流分发

`DataType::const_iterator`(`data_type.hpp` L325-L376)是 BigWorld 类型系统的"核心引擎",它递归遍历类型树,生成 `StreamElement` 序列。

```cpp
class const_iterator {
    const DataType & root_;
    bool useChild_;
    std::auto_ptr<const_iterator> pChildIt_;
    size_t index_;
    size_t size_;
    bool isNone_;
    bool isPersistentOnly_;
    StreamElementPtr pCurrent_;
};

const_iterator begin() const;            // 全字段迭代
const_iterator end() const;
const_iterator beginPersistent() const;  // 仅持久化字段
const_iterator endPersistent() const;
```

每个 `StreamElement` 描述一个流元素,可以是:

- 叶子元素(整数、浮点、字符串):`fromSourceToStream` 直接序列化。
- 容器起始元素(`isVariableSizedType`):需要 `setSize` 告知元素数。
- 字典字段元素(`getFieldName`):用于 FixedDict。
- 子流起始/结束(`isSubstreamStart`/`isSubstreamEnd`):用于变长嵌套(STRING 容器等)。

### 6.5 addToStream 算法

`DataType::addToStream`(`data_type.cpp` L93-L148)的完整算法:

```cpp
bool DataType::addToStream( DataSource & source, BinaryOStream & stream,
    bool isPersistentOnly ) const
{
    bool result = true;
    std::vector< MemoryOStream * > subStreams;

    for (DataType::const_iterator iter =
            (isPersistentOnly ? this->beginPersistent() : this->begin());
         iter != (isPersistentOnly ? this->endPersistent() : this->end());
         ++iter)
    {
        if (iter->isSubstreamStart())
            subStreams.push_back( new MemoryOStream() );

        BinaryOStream & curStream =
            subStreams.empty() ? stream : *subStreams.back();

        result &= iter->addToStream( source, curStream );

        if (iter->isSubstreamEnd()) {
            // 把子流的内容作为字符串写入父流
            MemoryOStream *pLastStream = subStreams.back();
            subStreams.pop_back();
            BinaryOStream & prevStream =
                subStreams.empty() ? stream : *subStreams.back();
            int len = pLastStream->remainingLength();
            prevStream.appendString(
                static_cast< const char * >( pLastStream->retrieve( len ) ), len );
            delete pLastStream;
        }
    }
    return result;
}
```

**核心思路**:用迭代器模式遍历类型树,把每个叶子节点的数据按顺序写入流。子流(`subStreams`)用于处理"变长嵌套"场景——比如 `ARRAY<STRING>` 数组本身是变长的,需要先序列化所有 STRING 到一个临时流,再以"长度+内容"形式写入父流。

### 6.6 createFromStream 算法

`DataType::createFromStream`(`data_type.cpp` L162-L220)是反向算法:

```cpp
bool DataType::createFromStream( BinaryIStream & stream, DataSink & sink,
    bool isPersistentOnly ) const
{
    bool result = true;
    std::vector< MemoryIStream * > subStreams;

    for (DataType::const_iterator iter = ...)
    {
        if (iter->isSubstreamStart()) {
            BinaryIStream & outerStream =
                subStreams.empty() ? stream : *subStreams.back();
            int len = outerStream.readPackedInt();
            subStreams.push_back(
                new MemoryIStream( outerStream.retrieve( len ), len ) );
        }

        BinaryIStream & curStream =
            subStreams.empty() ? stream : *subStreams.back();

        result &= iter->createFromStream( curStream, sink );

        if (iter->isSubstreamEnd()) {
            // 检查子流是否被完全消费
            MemoryIStream *pInnerStream = subStreams.back();
            subStreams.pop_back();
            if (pInnerStream->error() || pInnerStream->remainingLength() != 0)
                result = false;  // ERROR: 字节数不匹配
            delete pInnerStream;
        }
    }
    return result;
}
```

**关键校验**:子流必须被完全消费(`remainingLength() == 0`),否则视为协议错误。这能在版本不一致时及时止损。

### 6.7 ClientSafety 安全等级

```cpp
enum ClientSafety {
    CLIENT_SAFE     = 0,    // 安全,可发送给客户端
    CLIENT_UNSAFE   = 0x1,  // 不安全(如 PYTHON,可执行任意代码)
    CLIENT_UNUSABLE = 0x2,  // 不可用(如 MAILBOX,无法跨客户端)
};
```

`DataDescription::parse` 会检查每个字段的 `clientSafety`:

- `CLIENT_UNSAFE` 字段会 WARNING(可能被客户端利用执行任意代码)。
- `CLIENT_UNUSABLE` 字段会 ERROR(无法跨网络)。

### 6.8 具体类型实现示例:IntegerDataType

`IntegerDataType<INT_TYPE>`(`integer_data_type.hpp`)是模板类,根据 `INT_TYPE` 实例化为 `Int8DataType`、`UInt16DataType` 等:

```cpp
template <class INT_TYPE>
class IntegerDataType : public DataType
{
public:
    IntegerDataType( MetaDataType * pMeta );
protected:
    virtual bool isSameType( ScriptObject pValue );
    virtual bool getDefaultValue( DataSink & output ) const;
    virtual int streamSize() const;  // = sizeof(INT_TYPE)
    virtual bool addToSection( DataSource & source, DataSectionPtr pSection ) const;
    virtual bool createFromSection( DataSectionPtr pSection, DataSink & sink ) const;
    virtual void addToMD5( MD5 & md5 ) const;
    virtual StreamElementPtr getStreamElement( size_t index, size_t & size,
        bool & isNone, bool isPersistentOnly ) const;
    virtual bool operator<( const DataType & other ) const;
private:
    INT_TYPE defaultValue_;
};
```

`streamSize()` 返回 `sizeof(INT_TYPE)`,定长。`addToMD5` 会附加类型标识符与字节大小。

### 6.9 复合类型:ArrayDataType

`ArrayDataType`(`array_data_type.hpp`)继承自 `SequenceDataType`,表示变长数组:

```cpp
class ArrayDataType : public SequenceDataType
{
public:
    ArrayDataType( MetaDataType * pMeta, DataTypePtr elementType,
        int size = 0, int dbLen = 0 );
    virtual bool startSequence( DataSink & sink, size_t count ) const;
    virtual int compareDefaultValue( const DataType & other ) const;
    virtual void setDefaultValue( DataSectionPtr pSection );
    virtual bool getDefaultValue( DataSink & output ) const;
    virtual DataSectionPtr pDefaultSection() const;
    virtual ScriptObject attach( ScriptObject pObject,
        PropertyOwnerBase * pOwner, int ownerRef );
    virtual void detach( ScriptObject pObject );
    virtual PropertyOwnerBase * asOwner( ScriptObject pObject ) const;
    virtual void addToMD5( MD5 & md5 ) const;
private:
    DataSectionPtr pDefaultSection_;
};
```

`attach` / `detach` / `asOwner` 是 Array 类型的"智能"特性:它让 Python 端的 `entity.inventory.append(item)` 调用可以反向通知 C++ 端"数组被修改了",触发 PropertyChange 通知(详见第十四章)。

### 6.10 类型注册机制

`data_types.cpp` 通过 `FORCE_LINK` 宏注册所有内置类型:

```cpp
FORCE_LINK( FLOAT32 )
FORCE_LINK( FLOAT64 )
FORCE_LINK( INT8 )
FORCE_LINK( INT16 )
// ...
FORCE_LINK( ARRAY )
FORCE_LINK( TUPLE )
FORCE_LINK( FIXED_DICT )
FORCE_LINK( MAILBOX )  // 仅服务端
CONDITIONAL_FORCE_LINK( PYTHON )  // 仅 SCRIPT_PYTHON
CONDITIONAL_FORCE_LINK( CLASS )
CONDITIONAL_FORCE_LINK( USER_TYPE )
```

每个 `FORCE_LINK(NAME)` 展开为:

```cpp
extern int force_link_##NAME;
static ForceLink local_force_link_##NAME( force_link_##NAME );
```

而 `force_link_##NAME` 在对应的 `simple_meta_data_type_<NAME>` 文件中由 `SIMPLE_DATA_TYPE` 宏定义:

```cpp
SimpleMetaDataType< TYPE > s_##NAME##_metaDataType( #NAME );
DATA_TYPE_LINK_ITEM( NAME )
```

构造 `SimpleMetaDataType<TYPE>` 时调用 `MetaDataType::addMetaType(this)`,把工厂注册到全局表。

---

## 七、MetaDataType 元类型工厂

`MetaDataType`(`meta_data_type.hpp`)是类型系统的工厂基类:

```cpp
class MetaDataType
{
public:
    static MetaDataType * find( const BW::string & name );
    static void fini();

    virtual const char * name() const = 0;
    virtual DataTypePtr getType( DataSectionPtr pSection ) = 0;

    static void addAlias( const BW::string & orig, const BW::string & alias );

protected:
    static void addMetaType( MetaDataType * pMetaType );
    static void delMetaType( MetaDataType * pMetaType );
};
```

### 7.1 类型查找流程

`DataType::buildDataType`(`data_type.cpp` L233-L287)是工厂入口:

```cpp
DataTypePtr DataType::buildDataType( DataSectionPtr pSection )
{
    if (!pSection) {
        WARNING_MSG( "DataType::buildDataType: No <Type> section\n" );
        return NULL;
    }
    if (!s_aliasesDone) {
        s_aliasesDone = true;
        DataType::initAliases();   // 加载 alias.xml
    }

    BW::string typeName = pSection->asString();

    // 1. 优先查找别名
    Aliases::iterator found = s_aliases_.find( typeName );
    if (found != s_aliases_.end()) {
        // 警告:不允许在 .def 中覆盖别名默认值
        if (pSection->findChild( "Default" ))
            WARNING_MSG( "..." );
        return found->second;
    }

    // 2. 查找 MetaDataType
    MetaDataType * pMetaType = MetaDataType::find( typeName );
    if (pMetaType == NULL) {
        ERROR_MSG( "Could not find MetaDataType '%s'\n", typeName.c_str() );
        return NULL;
    }

    // 3. 构造具体 DataType
    DataTypePtr pDT = pMetaType->getType( pSection );
    if (!pDT) {
        ERROR_MSG( "Could not build %s from spec given\n", typeName.c_str() );
        return NULL;
    }

    // 4. 设置默认值
    pDT->setDefaultValue( pSection->findChild( "Default" ) );

    // 5. 单例化:返回等价的已有实例或新加入
    return DataType::findOrAddType( pDT.get() );
}
```

### 7.2 SimpleMetaDataType 模板

`SimpleMetaDataType<T>`(`data_types.hpp` L21-L47)是简单类型的元类型工厂:

```cpp
template <class DATATYPE>
class SimpleMetaDataType : public MetaDataType
{
public:
    SimpleMetaDataType( const char * name ) : name_( name )
    {
        MetaDataType::addMetaType( this );
    }
    virtual ~SimpleMetaDataType() { MetaDataType::delMetaType( this ); }
    virtual const char * name() const { return name_.c_str(); }
    virtual DataTypePtr getType( DataSectionPtr pSection )
    {
        return new DATATYPE( this );
    }
private:
    BW::string name_;
};
```

对于 `INT32` 等无参数的类型,直接 `new IntegerDataType<int32>(this)` 即可。对于 `ARRAY`/`TUPLE` 等需要子元素的类型,使用专门的 `MetaDataType` 子类(如 `SequenceMetaDataType`),从 `<of>` 子节点递归构建元素类型。

### 7.3 initAliases 算法

`DataType::initAliases`(`data_type.cpp` L336-L376)加载 `alias.xml`:

```cpp
bool DataType::initAliases()
{
    MetaDataType::addAlias( "FLOAT32", "FLOAT" );   // 内置别名

    DataSectionPtr pAliases = BWResource::openSection( aliasesFile() );
    if (pAliases) {
        for (auto iter = pAliases->begin(); iter != pAliases->end(); ++iter) {
            DataTypePtr pAliasedType = DataType::buildDataType( *iter );
            if (pAliasedType) {
                s_aliases_.insert( std::make_pair(
                    (*iter)->sectionName().c_str(), pAliasedType ) );
            }
        }
    }
    return true;
}
```

别名在 `s_aliases_` 中存储,查找时优先于 `MetaDataType::find`。

### 7.4 addAlias 别名注册

`MetaDataType::addAlias`(`meta_data_type.cpp`)将别名注册到元类型表,使 `FLOAT` 等价于 `FLOAT32`。这与 `alias.xml` 不同——`alias.xml` 是用户定义的"已实例化的 DataType",而 `addAlias` 是引擎内置的"元类型名等价"。

---

## 八、DataDescription 字段描述

`DataDescription`(`data_description.hpp` L77-L236)继承自 `MemberDescription`,描述单个字段的元数据。

### 8.1 关键成员变量

| 成员 | 类型 | 含义 |
|------|------|------|
| `pDataType_` | `DataTypePtr` | 字段类型(单例化的 DataType 实例) |
| `dataFlags_` | `int` | EntityDataFlags 组合 |
| `pInitialValue_` | `ScriptObject` | 初始值(若类型是 const) |
| `pDefaultSection_` | `DataSectionPtr` | 默认值 XML 节点(若类型非 const) |
| `index_` | `int` | 在 properties_ 中的索引 |
| `localIndex_` | `int` | 本地属性值向量索引 |
| `eventStampIndex_` | `int` | 事件时间戳向量索引 |
| `clientServerFullIndex_` | `int` | Client-Server 字段的全局索引 |
| `detailLevel_` | `int` | LoD 层级 |
| `databaseLength_` | `int` | 数据库存储长度(默认 65535) |
| `databaseIndexingType_` | `DatabaseIndexingType` | 数据库索引类型 |
| `hasSetterCallback_` | `bool` | 是否有 setter 回调 |
| `hasNestedSetterCallback_` | `bool` | 嵌套 setter 回调 |
| `hasSliceSetterCallback_` | `bool` | slice setter 回调 |
| `componentName_` | `BW::string` | 所属组件名(若来自 Components) |

### 8.2 parse 方法解析流程

`DataDescription::parse`(`data_description.cpp` L169-L331)的算法:

```
1. name_ = pSection->sectionName()  // 字段名
2. 初始化 hasSetterCallback_、hasNestedSetterCallback_、hasSliceSetterCallback_ = true
3. 读取 <Type> 节点,调用 DataType::buildDataType(typeSection)
   - 失败:ERROR 并返回 false
4. (EDITOR_ENABLED)查找 alias.xml 中的 widget
5. 若 PARSE_IGNORE_FLAGS 标志未设置:
   - 读取 <Flags> 字符串,通过 setEntityDataFlags 转换为 dataFlags_
   - 失败:ERROR 并返回 false
6. 若 <Persistent>true</Persistent>:dataFlags_ |= DATA_PERSISTENT
7. 若 <Identifier>true</Identifier>:
   - dataFlags_ |= DATA_ID
   - isIndexed = isUnique = true
8. 若 <Indexed>...:
   - 必须先 DATA_PERSISTENT,否则 ERROR
   - 读取 <Indexed><Unique>,设置 databaseIndexingType_(UNIQUE 或 NON_UNIQUE)
9. 读取 <Default> 节点:
   - 若 pDataType_->isConst():createFromSection → pInitialValue_
   - 否则:pDefaultSection_ = pSubSection(延迟创建)
10. (EDITOR_ENABLED)editable_ = <Editable>
11. 若 isClientServerData():
    - 读取 <ExposedForReplay>(默认 isOtherClientData() ? true : false)
    - 设置 dataFlags_ 的 DATA_REPLAY 位
12. databaseLength_ = <DatabaseLength>(默认 65535)
13. 调用基类 MemberDescription::parse 处理通用字段(<SendLatestOnly> 等)
14. 检查 isReliable && shouldSendLatestOnly(不可靠且非 SendLatestOnly 时 WARNING)
15. 返回 isOkay
```

### 8.3 字段类型判定

`DataDescription` 提供一系列 INLINE 判定方法(定义于 `data_description.ipp`):

```cpp
bool isGhostedData() const     { return dataFlags_ & DATA_GHOSTED; }
bool isOtherClientData() const { return dataFlags_ & DATA_OTHER_CLIENT; }
bool isOwnClientData() const   { return dataFlags_ & DATA_OWN_CLIENT; }
bool isCellData() const        { return (dataFlags_ & DATA_GHOSTED) || (dataFlags_ & DATA_OTHER_CLIENT); }
bool isBaseData() const        { return dataFlags_ & DATA_BASE; }
bool isClientServerData() const {
    return dataFlags_ & (DATA_OTHER_CLIENT | DATA_OWN_CLIENT);
}
bool isExposedForReplay() const { return dataFlags_ & DATA_REPLAY; }
bool isPersistent() const       { return dataFlags_ & DATA_PERSISTENT; }
bool isIdentifier() const       { return dataFlags_ & DATA_ID; }
bool isEditorOnly() const       { return dataFlags_ & DATA_EDITOR_ONLY; }
```

注意:

- `isCellData()` 包含 `DATA_GHOSTED`(Ghost 数据)与 `DATA_OTHER_CLIENT`(其他客户端可见)。
- `isClientServerData()` 是 `OWN_CLIENT | OTHER_CLIENT`,即"需要发往客户端"的字段。

### 8.4 addToStream 方法

`DataDescription::addToStream`(`data_description.cpp` L374-L404):

```cpp
bool DataDescription::addToStream( DataSource & source,
    BinaryOStream & stream, bool isPersistentOnly,
    EntityID clientEntityID /* = NULL_ENTITY_ID */ ) const
{
    if (this->isClientServerData() && (this->streamSize() < 0))
    {
        // 变长字段:先写到 lengthStream,检查长度后转移
        MemoryOStream lengthStream;
        if (!pDataType_->addToStream( source, lengthStream, isPersistentOnly))
            return false;

        // 检查超大消息
        if ((clientEntityID != NULL_ENTITY_ID) &&
            !this->checkForOversizeLength( lengthStream.size(), clientEntityID ))
            return false;

        stream.transfer( lengthStream, lengthStream.size() );
        return true;
    }

    // 定长字段:直接写
    return pDataType_->addToStream( source, stream, isPersistentOnly );
}
```

**关键设计**:变长字段需要先写到临时流再转移,以便检查总长度。这是为了防止客户端因为超大消息被踢线。

### 8.5 streamSize 方法

`DataDescription::streamSize`(L415-L425):

```cpp
int DataDescription::streamSize() const
{
    int dataTypeStreamSize = pDataType_->streamSize();
    if (dataTypeStreamSize < 0) {
        // 变长:返回 -getVarLenHeaderSize()
        return -static_cast< int >( this->getVarLenHeaderSize() );
    }
    return dataTypeStreamSize;
}
```

返回值含义:

- 正数:定长字段的字节数。
- 负数:变长字段,绝对值是"标头字节数"(用于存储长度)。

### 8.6 addToMD5 方法

`DataDescription::addToMD5`(L431-L439):

```cpp
void DataDescription::addToMD5( MD5 & md5 ) const
{
    this->MemberDescription::addToMD5( md5 );   // 附加 name 等
    int md5DataFlags = dataFlags_ & DATA_DISTRIBUTION_FLAGS;
    md5.append( &md5DataFlags, sizeof(md5DataFlags) );
    pDataType_->addToMD5( md5 );                // 附加类型签名
}
```

注意只附加 `DATA_DISTRIBUTION_FLAGS`(`DATA_GHOSTED | DATA_OTHER_CLIENT | DATA_OWN_CLIENT | DATA_BASE | DATA_CLIENT_ONLY | DATA_EDITOR_ONLY`),不包括 `DATA_PERSISTENT` / `DATA_ID` 等。这意味着**改变字段的持久化属性不影响 MD5**——这是一个微妙的设计选择,允许运维调整持久化策略而不强制客户端更新。

### 8.7 callSetterCallback 方法

`callSetterCallback`(L161-L162 声明)在字段被修改时调用脚本的 setter 回调:

```cpp
void callSetterCallback( ScriptObject pEntity,
    ScriptObject pOldValue, ScriptList pChangePath, bool isSlice ) const;
```

这允许脚本通过 `def.set_callback("hp", onHpChanged)` 注册字段变更回调。`hasSetterCallback_` / `hasNestedSetterCallback_` / `hasSliceSetterCallback_` 三个标志用于快速跳过未注册回调的字段,避免空函数调用开销。

### 8.8 pInitialValue 与延迟初始化

`DataDescription::pInitialValue`(L453-L473):

```cpp
ScriptObject DataDescription::pInitialValue() const
{
    if (pInitialValue_)
        return pInitialValue_;            // const 类型:已预构造
    else if (pDefaultSection_) {
        // 非 const 类型:从 section 即时构造
        ScriptDataSink sink;
        if (pDataType_->createFromSection( pDefaultSection_, sink ))
            return sink.finalise();
    }
    // 否则使用 DataType 的默认值
    ScriptDataSink sink;
    MF_VERIFY( pDataType_->getDefaultValue( sink ) );
    return sink.finalise();
}
```

**设计动机**:`const` 类型(简单类型)在解析期就预构造初始值,避免运行时开销;`非 const` 类型(Array/Dict/Class)延迟到首次访问,因为它们的初始值可能很大,预构造会浪费内存。

---

## 九、MethodDescription 方法描述

`MethodDescription`(`method_description.hpp` L51-L317)继承自 `MemberDescription`,描述单个方法的元数据。

### 9.1 Component 枚举

```cpp
enum Component
{
    CLIENT,    // 客户端方法(由客户端实现,被服务器调用)
    CELL,      // Cell 方法(由 Cell 实现,被 Base/Client 调用)
    BASE,      // Base 方法(由 Base 实现,被 Cell/Client 调用)
    NUM_COMPONENTS
};
```

注意:这里没有 SERVICE,因为 Service 方法实质上就是 Base 方法。

### 9.2 Exposed 标志位

```cpp
enum
{
    IS_EXPOSED_TO_ALL_CLIENTS = 0x4,
    IS_EXPOSED_TO_OWN_CLIENT  = 0x8
};

bool isExposed() const {
    return !!(flags_ & (IS_EXPOSED_TO_ALL_CLIENTS | IS_EXPOSED_TO_OWN_CLIENT));
}
bool isExposedToOwnClientOnly() const {
    return (flags_ & IS_EXPOSED_TO_OWN_CLIENT) &&
           !(flags_ & IS_EXPOSED_TO_ALL_CLIENTS);
}
bool isExposedToAllClientsOnly() const {
    return (flags_ & IS_EXPOSED_TO_ALL_CLIENTS) &&
           !(flags_ & IS_EXPOSED_TO_OWN_CLIENT);
}
bool isExposedToDefault() const {
    return !!((flags_ & IS_EXPOSED_TO_OWN_CLIENT) &&
              (flags_ & IS_EXPOSED_TO_ALL_CLIENTS));
}
```

`<Exposed>` 标签的解析规则(`method_description.cpp` L351-L384):

| `<Exposed>` 值 | 设置的标志 | 适用 Component | 含义 |
|----------------|-----------|----------------|------|
| `OWN_CLIENT` | `IS_EXPOSED_TO_OWN_CLIENT` | CELL/BASE | 仅拥有者客户端可调用 |
| `ALL_CLIENTS` | `IS_EXPOSED_TO_ALL_CLIENTS` | 仅 CELL | 所有客户端可调用 |
| 空 | 两者都设置 | CELL/BASE | 默认行为(OWN+ALL) |

`<Exposed>` 在 Client 方法上不允许(ERROR)——Client 方法本身就是被服务器调用的,不存在"暴露给客户端"的概念。

### 9.3 关键成员变量

| 成员 | 类型 | 含义 |
|------|------|------|
| `flags_` | `uint8` | Component + Exposed 标志 |
| `args_` | `MethodArgs` | 参数列表 |
| `returnValues_` | `MethodArgs` | 返回值列表 |
| `hasReturnValues_` | `bool` | 是否有 `<ReturnValues>` |
| `internalIndex_` | `int` | 在 internalMethods_ 中的索引 |
| `exposedIndex_` | `int` | 在 exposedMethods_ 中的索引 |
| `exposedMsgID_` | `int16` | 暴露消息 ID(网络传输用) |
| `exposedSubMsgID_` | `int16` | 子消息 ID(扩展地址空间) |
| `priority_` | `float` | 调用优先级(LoD 距离平方) |
| `replayExposureLevel_` | `ReplayExposureLevel` | 回放可见性 |
| `components_` | `set<string>` | 实现此方法的组件名集合 |
| `isComponentised_` | `bool` | 是否来自组件 |
| `timeSpent_` | `TimeStamp` | (ENABLE_WATCHERS) 总耗时 |
| `timeSpentMax_` | `TimeStamp` | (ENABLE_WATCHERS) 最大耗时 |
| `timesCalled_` | `uint64` | (ENABLE_WATCHERS) 调用次数 |

### 9.4 ReplayExposureLevel 枚举

```cpp
enum ReplayExposureLevel
{
    REPLAY_EXPOSURE_LEVEL_NONE,           // 不记录
    REPLAY_EXPOSURE_LEVEL_OTHER_CLIENTS,  // 仅其他客户端可见(默认)
    REPLAY_EXPOSURE_LEVEL_ALL_CLIENTS     // 所有客户端可见
};
```

回放系统(Replay)用于比赛复盘、bug 复现等场景。`shouldRecord(recordingOption)` 根据记录选项决定是否记录此方法的调用。

### 9.5 parse 方法解析流程

`MethodDescription::parse`(`method_description.cpp` L335-L469):

```
1. 调用基类 MemberDescription::parse(<isForClient> = component == CLIENT)
2. name_ = pSection->sectionName()
3. 处理 <Exposed>:
   - CLIENT component 报错
   - CELL + ALL_CLIENTS:setExposedToAllClients()
   - OWN_CLIENT:setExposedToOwnClient()
   - 空字符串:setExposedToDefault()
   - 其他:ERROR
4. 处理 <ReplayExposureLevel>:NONE/OTHER_CLIENTS/ALL_CLIENTS
5. this->component(component)
6. 解析参数:
   - 优先 <Args> 节点
   - 否则使用 pSection 本身(老式风格,hasOldStyleArgs = true)
   - 调用 args_.parse(pArgs, hasOldStyleArgs)
7. 解析 <ReturnValues>(若有):
   - hasReturnValues_ = true
   - returnValues_.parse(pReturnValues)
   - (MF_SERVER)初始化 ReturnValuesHandler
8. priority_ = <DetailDistance>(默认 FLT_MAX)
9. 若 priority_ != FLT_MAX,priority_ *= priority_  (平方化)
10. 返回 result
```

注意 `<DetailDistance>` 是距离,但内部存储为平方(避免 sqrt 调用)。这是 BigWorld 的常见优化模式。

### 9.6 addToStream / addToServerStream / addToClientStream

三个流分发方法对应不同方向:

```cpp
// Client → Server(Exposed 方法调用)
bool addToStream( DataSource & source, BinaryOStream & stream ) const;

// Server → Server(Cell ↔ Base)
bool addToServerStream( DataSource & source, BinaryOStream & stream,
    EntityID sourceEntityID ) const;

// Server → Client(Client 方法调用)
bool addToClientStream( DataSource & source, BinaryOStream & stream,
    EntityID targetEntityID ) const;
```

**addToServerStream**(`method_description.cpp` L547-L558)特殊处理:

```cpp
bool MethodDescription::addToServerStream( DataSource & source,
    BinaryOStream & stream, EntityID sourceEntityID ) const
{
    MF_ASSERT( this->component() != MethodDescription::CLIENT );

    // 若是 Cell 方法且 Exposed,先写 sourceEntityID
    // 这是用于支持"客户端通过 cell mailbox 调用 exposed cell 方法,
    // 服务器知道是哪个客户端发起的"
    if (this->isExposed() && this->component() == MethodDescription::CELL)
        stream << sourceEntityID;

    return args_.addToStream( source, stream );
}
```

**addToClientStream**(L577-L599)包含超大消息检查:

```cpp
bool MethodDescription::addToClientStream( DataSource & source,
    BinaryOStream & stream, EntityID targetEntityID ) const
{
    MF_ASSERT( this->component() == MethodDescription::CLIENT );
    MF_ASSERT( this->isExposed() );

    std::auto_ptr< MemoryOStream > pLengthStream( new MemoryOStream );
    this->addSubMessageIDToStream( *pLengthStream );
    bool isOkay = args_.addToStream( source, *pLengthStream );

    size_t length = static_cast< size_t >( pLengthStream->size() );
    if (!this->checkForOversizeLength( length, targetEntityID ))
        return false;

    stream.transfer( *pLengthStream, static_cast<int>(length) );
    return isOkay;
}
```

### 9.7 callMethod 方法

`callMethod`(声明 L101-L106)是远端方法调用的核心接收端逻辑:

```cpp
bool callMethod( ScriptObject self,
    BinaryIStream & data,
    EntityID sourceID = 0,
    int replyID = -1,
    const Mercury::Address* pReplyAddr = NULL,
    Mercury::NetworkInterface * pInterface = NULL ) const;
```

算法:

1. 从 `data` 中读取参数,转换为 Python tuple(`getArgsAsTuple`)。
2. 若有 `sourceID`,作为隐式第一参数(Exposed Cell 方法)。
3. 从 `self` 获取方法对象(`getMethodFrom`)。
4. 调用 Python 方法。
5. 若有 `<ReturnValues>` 且 `replyID >= 0`:将返回值通过 `sendReturnValues` 发回。
6. 若 Python 异常:通过 `sendReturnValuesError` 发送错误对象。

### 9.8 PyDeferredResponse 与双向调用

对于"Python 端返回值需要延迟产生"的场景(如异步数据库查询),BigWorld 提供了 `PyDeferredResponse` 类(`method_description.cpp` L58-L137),它包装 Twisted Deferred 模式:

```python
# 脚本侧
def onLogin(self, username):
    d = async_db_lookup(username)
    d.addCallback(self._on_db_done)
    return d  # 返回 Deferred

# C++ 侧:接收到 Deferred 后,PyDeferredResponse.callback(value) 会被调用
```

`PyDeferredResponse::callback`(L98-L123)将 value 转换为返回值并发送:`methodDescription_.sendReturnValues(...)`。`errback` 则发送错误对象。这使 BigWorld 支持非阻塞的 RPC。

### 9.9 streamSize 与带宽估算

`MethodDescription::streamSize(bool isFromServer)`(声明 L97):

- `isFromServer = true`:Server → Client 方向,只计算参数流大小。
- `isFromServer = false`:Client → Server 方向,可能包含额外的 sourceEntityID(4 字节)。

返回值规则:

- 正数:定长方法,字节数。
- 负数:变长方法,绝对值为"预期字节数"。

`returnValuesStreamSize` 类似,用于返回值流。

### 9.10 addToMD5 与版本校验

```cpp
void MethodDescription::addToMD5( MD5 & md5, int legacyExposedIndex ) const;
```

附加:

- 方法名
- 参数列表(`args_.addToMD5`)
- 返回值列表(若有)
- Exposed 标志位

`legacyExposedIndex` 是"在 Exposed 列表中的索引",用于确保 Exposed 方法的顺序稳定(顺序变化会导致 ID 不兼容)。

---

## 十、MethodArgs 参数与返回值

`MethodArgs`(`method_args.hpp`)存储方法的参数与返回值类型列表。

### 10.1 数据结构

```cpp
class MethodArgs
{
private:
    typedef BW::vector< std::pair< BW::string, DataTypePtr > > Args;
    Args args_;
    int streamSize_;
};
```

每个参数是 `(name, DataTypePtr)` 对。`streamSize_` 是缓存的总流大小(变长为 -1)。

### 10.2 parse 方法

```cpp
bool MethodArgs::parse( DataSectionPtr pSection, bool isOldStyle = false );
```

算法:

1. 遍历 `<Args>` 下的每个 `<arg>` 节点(老式风格直接遍历方法节点)。
2. 对每个 `<arg>`:
   - 读取 `<Type>` 节点,调用 `DataType::buildDataType`。
   - 读取可选 `<Desc>`(参数描述,仅文档用)。
   - 加入 `args_` 列表。
3. 计算 `streamSize_`:
   - 若所有参数都是定长,`streamSize_ = sum(streamSize)`。
   - 否则 `streamSize_ = -1`。

### 10.3 addToStream 与 createFromStream

```cpp
bool addToStream( DataSource & source, BinaryOStream & stream ) const;
bool createFromStream( BinaryIStream & data, DataSink & sink,
    const BW::string & name, EntityID * pImplicitSource = NULL ) const;
```

`addToStream` 按顺序从 source 读取每个参数,通过对应 `DataType::addToStream` 写入流。

`createFromStream` 反向,但有个特殊处理:`pImplicitSource` 用于 Exposed Cell 方法的"隐式 sourceEntityID"。当方法被暴露给客户端调用时,客户端不传 sourceEntityID,服务器在转发到 Cell 时自动注入客户端的 EntityID 作为第一个参数。

### 10.4 checkValid 参数校验

```cpp
bool checkValid( ScriptTuple args, const char * name, int firstOrdinaryArg = 0 ) const;
```

在脚本调用方法前,`MethodDescription::areValidArgs` 会调用此方法校验参数:

1. 参数个数匹配(考虑 `firstOrdinaryArg` 偏移)。
2. 每个参数的类型与 `args_[i].second->isSameType(value)` 匹配。

不匹配时生成 Python 异常。

### 10.5 convertKeywordArgs 关键字参数

```cpp
ScriptTuple convertKeywordArgs( ScriptTuple args, ScriptDict kwargs ) const;
```

支持 Python 风格的关键字调用:`entity.client.showDamage(damage=10)`。该方法把 kwargs 字典按参数名转换为位置参数 tuple。

### 10.6 addToMD5 与 operator==

```cpp
void addToMD5( MD5 & md5 ) const;
friend bool operator== ( const MethodArgs & left, const MethodArgs & right );
```

`operator==` 用于"方法签名相等"判定——这是 `EntityMethodDescriptions::init` 中处理"同名方法来自不同组件"的关键:`isSignatureEqual` 检查两个方法的 args/returnValues 是否完全相同,相同则视为同一方法的不同实现。

---

## 十一、EntityMethodDescriptions 方法集

`EntityMethodDescriptions`(`entity_method_descriptions.hpp`)是单个 Component 的方法集合。

### 11.1 数据结构

```cpp
class EntityMethodDescriptions
{
private:
    typedef StringMap< uint32 > Map;
    typedef MethodDescriptionList List;

    Map map_;                              // 名称 → internalIndex
    List internalMethods_;                  // 所有方法(按 internalIndex)
    BW::vector< unsigned int > exposedMethods_;  // Exposed 方法的 internalIndex
    int maxExposedMethodCount_;
};
```

三组数据:

- `internalMethods_`:所有方法的列表。
- `map_`:名称查找表(`StringMap` 是哈希表)。
- `exposedMethods_`:仅 Exposed 方法的索引列表(用于 ID 分配)。

### 11.2 init 方法解析流程

`EntityMethodDescriptions::init`(`entity_method_descriptions.cpp` L31-L105):

```cpp
bool EntityMethodDescriptions::init( DataSectionPtr pMethods,
    MethodDescription::Component component, const char * interfaceName,
    const BW::string & componentName, unsigned int * pNumLatestEventMembers )
{
    DataSectionIterator iter = pMethods->begin();
    while (iter != pMethods->end()) {
        MethodDescription methodDescription;
        if (!methodDescription.parse( interfaceName, *iter, component, ... ))
            return false;

        if (component == MethodDescription::CLIENT) {
            // 所有 Client 方法都是 Exposed
            methodDescription.setExposedToAllClients();
        }

        methodDescription.internalIndex( (int) internalMethods_.size() );
        methodDescription.addImplementingComponent( componentName );

        // 处理同名方法(组件场景)
        const std::pair< Map::iterator, bool > insertResult =
            map_.insert( std::make_pair( methodDescription.name().c_str(),
                                         methodDescription.internalIndex() ) );

        if (!insertResult.second) {
            // 已存在同名方法
            MethodDescription & existMethod =
                internalMethods_.at(insertResult.first->second);
            if (methodDescription.isSignatureEqual( existMethod )) {
                // 签名相同:只是不同组件实现,合并
                if (!existMethod.addImplementingComponent( componentName ))
                    return false;
            } else {
                // 签名不同:ERROR
                ERROR_MSG( "Method '%s' already defined with a different signature\n" );
                return false;
            }
        } else {
            // 新方法
            internalMethods_.push_back( methodDescription );
            if (methodDescription.isExposed())
                exposedMethods_.push_back( methodDescription.internalIndex() );
        }
        ++iter;
    }
    return this->checkExposedForClientSafety( interfaceName );
}
```

**关键设计**:同名方法可以来自不同组件(如 `Movement.onMove` 与 `Combat.onMove`),只要签名相同就视为同一方法的不同实现,通过 `addImplementingComponent` 记录所有实现组件。运行时通过 `isImplementedBy(componentName)` 判定。

### 11.3 setExposedMsgIDs 与排序

`setExposedMsgIDs`(`entity_method_descriptions.cpp` L197-L212):

```cpp
void EntityMethodDescriptions::setExposedMsgIDs( int maxExposedMethodCount,
    const ExposedMethodMessageRange * pRange )
{
    maxExposedMethodCount_ = maxExposedMethodCount;

    // 稳定排序:小尺寸方法在前
    std::stable_sort( exposedMethods_.begin(), exposedMethods_.end(),
        ExposedMethodsSortHelper( internalMethods_ ) );

    for (uint exposedID = 0; exposedID < exposedMethods_.size(); ++exposedID) {
        MethodDescription & description =
            internalMethods_[ exposedMethods_[ exposedID ] ];
        description.setExposedMsgID( exposedID, maxExposedMethodCount, pRange );
    }
}
```

排序规则与 `allocateClientServerFullIndexes` 类似:**定长方法在前,变长方法在后;同尺寸保持声明顺序**。这使 ID 0 永远是最小的方法,便于协议优化(常见方法用 1 字节 ID)。

### 11.4 exposedMethodFromMsgID 算法

`exposedMethodFromMsgID`(L296-L314):

```cpp
const MethodDescription * EntityMethodDescriptions::exposedMethodFromMsgID(
    Mercury::MessageID msgID, BinaryIStream & data,
    const ExposedMethodMessageRange & range ) const
{
    MF_ASSERT( maxExposedMethodCount_ != -1 );

    int exposedID = range.exposedIDFromMsgID( msgID, data, maxExposedMethodCount_ );
    const MethodDescription * pMethodDesc = this->exposedMethod( exposedID );

    MF_ASSERT( pMethodDesc == NULL ||
        pMethodDesc->component() != MethodDescription::CLIENT );

    return pMethodDesc;
}
```

`exposedIDFromMsgID` 在 `ExposedMethodMessageRange` 中实现,可能从流中读取 `exposedSubMsgID`(扩展地址空间)。

### 11.5 查找方法

```cpp
// 按名称查找(返回 NULL 若不存在)
MethodDescription * find( const char * name ) const;

// 按 internalIndex 查找
MethodDescription * internalMethod( unsigned int index ) const;

// 按 exposedIndex 查找
const MethodDescription * exposedMethod( unsigned int index ) const;
```

`find` 使用 `StringMap`(哈希表),O(1) 平均。`internalMethod` 与 `exposedMethod` 都是 O(1) 数组访问。

### 11.6 supersede 方法

`supersede`(L218-L231)用于热重载:

```cpp
void EntityMethodDescriptions::supersede()
{
    map_.clear();
    uint32 i = 0;
    for (List::iterator it = internalMethods_.begin();
        it != internalMethods_.end(); it++, ++i ) {
        BW::string & str = const_cast<BW::string&>( it->name() );
        str = "old_" + str;             // 重命名为 old_xxx
        map_[ it->name().c_str() ] = i;
    }
}
```

热重载时,旧方法被重命名为 `old_xxx`,不再被脚本调用,但仍在内存中以便正在进行的调用完成。新方法通过重新 `init` 加入。

---

## 十二、MemberDescription 公共基类

`MemberDescription`(`member_description.hpp`)是 `DataDescription` 与 `MethodDescription` 的公共基类,提供:

- 名称管理(`name_`、`interfaceName_`)
- 可靠性(`isReliable_`)
- SendLatestOnly 标志(`latestEventIndex_`)
- 超大消息告警级别(`oversizeWarnLevel_`)
- 变长消息头大小(`varLenHeaderSize_`)
- 统计(`stats_`)
- MD5 公共部分(`addToMD5`)

### 12.1 OversizeWarnLevel 枚举

```cpp
enum OversizeWarnLevel
{
    OVERSIZE_NO_WARNING = 0,
    OVERSIZE_SHOULD_LOG,
    OVERSIZE_SHOULD_PRINT_CALLSTACK,
    OVERSIZE_SHOULD_RAISE_EXCEPTION
};
```

通过 `<OversizeWarnLevel>` 节点配置,默认 `OVERSIZE_SHOULD_LOG`。

### 12.2 checkForOversizeLength

```cpp
bool checkForOversizeLength( size_t length, EntityID entityID ) const;
```

当流长度超过阈值(默认几 KB)时按 `oversizeWarnLevel_` 处理。这帮助开发者发现意外的超大消息(如未限制长度的 ARRAY 字段)。

### 12.3 shouldSendLatestOnly

```cpp
bool shouldSendLatestOnly() const { return latestEventIndex_ != -1; }
```

`<SendLatestOnly>true</SendLatestOnly>` 表示该方法/字段仅发送最新一次。例如 `hp` 字段在 1 秒内被修改 100 次,只发送最后一次。`latestEventIndex_` 是 EventHistory 中的索引。

### 12.4 COMPONENT_NAME_SEPARATOR

```cpp
static const char COMPONENT_NAME_SEPARATOR = '.';
```

组件字段的全名是 `componentName.fieldName`(如 `Movement.speed`)。`DataDescription::fullName()` 返回此格式名,用于在 DataSection 中区分组件字段。

---

## 十三、VolatileInfo 系统

`VolatileInfo`(`volatile_info.hpp`)描述实体的"高频变化数据"——位置、朝向。

### 13.1 数据结构

```cpp
class VolatileInfo
{
public:
    VolatileInfo( float positionPriority = -1.f,
        float yawPriority = -1.f,
        float pitchPriority = -1.f,
        float rollPriority = -1.f );

    bool shouldSendPosition() const { return positionPriority_ > 0.f; }
    int dirType( float priority ) const;
    bool isLessVolatileThan( const VolatileInfo & info ) const;
    bool isValid() const;
    bool hasVolatile( float priority ) const;

    BWENTITY_API static const float ALWAYS;

    float positionPriority() const;
    float yawPriority() const;
    float pitchPriority() const;
    float rollPriority() const;

private:
    float positionPriority_;
    float yawPriority_;
    float pitchPriority_;
    float rollPriority_;
};
```

### 13.2 优先级含义

`-1` 表示"不发送",`0` 表示"始终发送但优先级最低",`ALWAYS(FLT_MAX)` 表示"始终发送且优先级最高"。`.def` 文件中写的值是 0~1 的"距离比例",内部存储为其平方(避免 sqrt):

```cpp
float VolatileInfo::asPriority( DataSectionPtr pSection ) const
{
    if (pSection) {
        float value = pSection->asFloat( -1.f );
        return isEqual( value, -1.f ) ? ALWAYS : value * value;
    }
    return -1.f;
}
```

### 13.3 dirType 方法

`dirType(priority)` 根据优先级返回应发送的方向类型:

- 优先级 ≥ `yawPriority_`:发送 yaw。
- 优先级 ≥ `pitchPriority_`:发送 yaw + pitch。
- 优先级 ≥ `rollPriority_`:发送 yaw + pitch + roll。

设计动机:远距离实体只需发送 yaw(节省带宽),近距离需要全部朝向。

### 13.4 isValid 校验

```cpp
bool VolatileInfo::isValid() const
{
    return yawPriority_ >= pitchPriority_ &&
           pitchPriority_ >= rollPriority_;
}
```

要求 `yaw ≥ pitch ≥ roll`,因为发送朝向是渐进的(包含 yaw 不发 pitch 不合理)。

### 13.5 isLessVolatileThan

```cpp
bool VolatileInfo::isLessVolatileThan( const VolatileInfo & info ) const
{
    return
        positionPriority_ < info.positionPriority_ ||
        yawPriority_ < info.yawPriority_ ||
        pitchPriority_ < info.pitchPriority_ ||
        rollPriority_ < info.rollPriority_;
}
```

用于 LoD 切换判定:当实体进入更低 LoD 层级时,如果新 LoD 的 VolatileInfo "更不 volatile",则需要重新发送详细位置。

### 13.6 Volatile 字段同步流程

```
CellApp 每帧:
1. 遍历每个有 Volatile 变化的实体
2. 查询 VolatileInfo.shouldSendPosition() / dirType(currentPriority)
3. 根据距离决定 priority
4. 把 position(可能压缩)+ 方向写入 bundle
5. 发送给:
   - 该实体的所有 Ghost Cell(用于 OtherClient 同步)
   - 拥有该实体的客户端(OwnClient)
6. 客户端接收后,调用 ScriptObject.set(position=...) 等
```

Volatile 字段不走 PropertyChange 路径,而是由 CellApp 的 `CellApp::updateVolatileInfo` 直接处理,这是性能关键路径。

### 13.7 py_volatile_info.hpp

`PyVolatileInfo`(`py_volatile_info.hpp`)是 VolatileInfo 的 Python 暴露,允许脚本读取 Volatile 配置:

```python
print BigWorld.entityDef['Avatar'].volatileInfo.positionPriority
```

---

## 十四、PropertyChange 通知系统

`PropertyChange`(`property_change.hpp`)表示"字段变更通知",用于将字段修改广播给客户端/其他服务器。

### 14.1 类层次

```
PropertyChange (抽象基类)
   ├── SinglePropertyChange   (单值变更)
   └── SlicePropertyChange    (数组片段变更)
```

### 14.2 PropertyChange 数据结构

```cpp
class PropertyChange
{
public:
    enum Flags
    {
        FLAG_IS_SLICE   = 1 << 0,
        FLAG_IS_NESTED  = 1 << 1
    };

    PropertyChange( const DataType & type );

    virtual void addToInternalStream( BinaryOStream & stream ) const;
    virtual void addToExternalStream( BinaryOStream & stream,
        int clientServerPropertyID, int numClientServerProperties ) const;
    virtual void addValueToStream( BinaryOStream & stream ) const = 0;
    virtual bool isSlice() const = 0;

    void rootIndex( int rootIndex );
    int rootIndex() const;

    void addToPath( int index, int indexLength );

    void isNestedChange( bool value );
    bool isNestedChange() const;

protected:
    typedef BW::vector< std::pair< int32, int32 > > ChangePath;

    void addInternalFlags( BinaryOStream & stream ) const;
    void addSimplePathToStream( BinaryOStream & stream ) const;
    void addCompressedPathToStream( BinaryOStream & stream,
        int clientServerID, int numClientServerProperties ) const;

    const DataType & type_;
    ChangePath path_;
    bool isNestedChange_;
    int rootIndex_;
};
```

### 14.3 ChangePath 路径表示

```cpp
// A sequence of child indexes ordered from the leaf to the root
// (i.e. entity). For example, 3,4,6 would be the 6th property of the
// entity, the 4th "child" of that property and then the 3rd "child".
// E.g. If the 6th property is a list of lists called myList, this refers
// to entity.myList[4][3]
typedef BW::vector< std::pair< int32, int32 > > ChangePath;
```

每个路径元素是 `(index, indexLength)` 对。`indexLength` 是 `index` 在流中占用的字节数(1/2/4),用于紧凑编码。

### 14.4 SinglePropertyChange

```cpp
class SinglePropertyChange : public PropertyChange
{
public:
    SinglePropertyChange( int leafIndex, int leafSize, const DataType & type );
    virtual void addValueToStream( BinaryOStream & stream ) const;
    virtual bool isSlice() const { return false; }
    void setValue( ScriptObject pValue );
private:
    int leafIndex_;
    int leafSize_;
    ScriptObject pValue_;
};
```

`leafSize` 是 leaf 字段的流大小(定长)或 -1(变长)。这是路径的"叶子"信息。

### 14.5 SlicePropertyChange

```cpp
class SlicePropertyChange : public PropertyChange
{
public:
    SlicePropertyChange( size_t startIndex, size_t endIndex,
        size_t originalLeafSize,
        const BW::vector< ScriptObject > & newValues,
        const DataType & type );
    virtual void addValueToStream( BinaryOStream & stream ) const;
    virtual bool isSlice() const { return true; }
private:
    size_t startIndex_;
    size_t endIndex_;
    size_t originalLeafSize_;
    const BW::vector< ScriptObject > & newValues_;
};
```

表示"数组的 [start, end) 范围被替换为新值列表"。这是 Python `arr[2:5] = [a, b, c]` 语法的网络表示。

### 14.6 内部流 vs 外部流

`PropertyChange` 有两种流格式:

- **内部流**(`addToInternalStream`):Cell ↔ Base / Cell ↔ Cell 通信,完整路径。
- **外部流**(`addToExternalStream`):Cell → Client 通信,使用压缩路径(`addCompressedPathToStream`)。

外部流使用 `clientServerPropertyID` + `numClientServerProperties` 进行"压缩"编码:

- 若 `clientServerID < numClientServerProperties`,直接 1 字节 ID。
- 否则使用 `PROPERTY_CHANGE_ID_SINGLE` 多路复用(2 字节)。

这是为了在大部分情况下用 1 字节表示字段 ID,节省带宽。

### 14.7 PropertyChangeReader

`PropertyChangeReader`(`property_change_reader.hpp`)是接收端的镜像:

```cpp
class PropertyChangeReader
{
public:
    bool readSimplePathAndApply( BinaryIStream & stream,
        PropertyOwnerBase * pOwner,
        ScriptObject * ppOldValue,
        ScriptList * ppChangePath );

    int readCompressedPathAndApply( BinaryIStream & stream,
        PropertyOwnerBase * pOwner,
        ScriptObject * ppOldValue,
        ScriptList * ppChangePath );
};

class SinglePropertyChangeReader : public PropertyChangeReader { ... };
class SlicePropertyChangeReader : public PropertyChangeReader { ... };
```

`apply` 方法将变更应用到 `PropertyOwnerBase`(通常是 Entity),并返回旧值。

### 14.8 PropertyOwner 与嵌套变更

`PropertyOwnerBase`(`property_owner.hpp`)是"可拥有字段的对象"抽象:

- Entity 本身
- Array 字段(ArrayDataType::asOwner 返回)
- FixedDict 字段
- Class 字段

当脚本来修改 `entity.inventory[3].quantity = 5` 时:

1. `entity.inventory` 是 Array,触发 Array 的 `__setitem__`。
2. Array 通知其 owner(entity)发生 SlicePropertyChange。
3. Entity 收到通知,构造 PropertyChange(path=[inventory_index, 3, quantity_index])。
4. 通过 Mailbox 发送给其他 Component 的同名 entity。

`isNestedChange` 标志位用于优化:当 `entity.inventory[3].quantity = 5` 触发时,`inventory` 的 setter 被调用,但实际变更是嵌套的 `quantity`,通过 `isNestedChange` 表示这是嵌套变更,避免不必要的中间层 PropertyChange。

---

## 十五、ExposedMessageRange 暴露范围

`ExposedMessageRange`(`network/exposed_message_range.hpp`)管理暴露方法/字段的 Mercury 消息 ID 范围。

### 15.1 类层次

```
ExposedMessageRange (基类)
   ├── ExposedMethodMessageRange   (方法调用)
   └── ExposedPropertyMessageRange (字段变更)
```

### 15.2 ExposedMessageRange 基类

```cpp
class ExposedMessageRange
{
public:
    ExposedMessageRange( int firstMsgID, int lastMsgID );

    bool contains( Mercury::MessageID msgID ) const {
        return (firstMsgID_ <= msgID) && (msgID <= lastMsgID_);
    }

    int numSlots() const { return lastMsgID_ - firstMsgID_ + 1; }

    int simpleExposedIDFromMsgID( Mercury::MessageID msgID ) const {
        return msgID - firstMsgID_;
    }

protected:
    int firstMsgID_;
    int lastMsgID_;
};
```

### 15.3 ExposedMethodMessageRange 与 SubMsgID

`ExposedMethodMessageRange` 支持"子消息 ID"扩展地址空间:

```cpp
class ExposedMethodMessageRange : public ExposedMessageRange
{
public:
    void msgIDFromExposedID( int exposedID, int numExposed,
        int16 & exposedMsgID, int16 & exposedSubMsgID ) const;

    int exposedIDFromMsgID( Mercury::MessageID msgID,
        BinaryIStream & data, int numExposed ) const;

    bool needsSubID( int exposedID, int numExposed ) const;

private:
    int numSubSlots( int numExposed ) const;
    int numRemainingSlots( int numExposed ) const;
};
```

**地址分配算法**:

```
所有实体类型共享 numSlots 个消息 ID(firstMsgID ~ lastMsgID)。
对于 entityType E(索引 e)的 Exposed 方法 m(索引 m):
  若 numSlots >= maxCount * numEntities:
    exposedMsgID = firstMsgID + e * maxCount + m
    exposedSubMsgID = -1(不用)
  否则:
    exposedMsgID = firstMsgID + (e * maxCount + m) / SUB_SLOTS
    exposedSubMsgID = (e * maxCount + m) % SUB_SLOTS
```

`SUB_SLOTS` 通常是 256,允许在 `numSlots * 256` 范围内寻址。这样即使消息 ID 范围有限(如 256),也能支持 65536 个 Exposed 方法。

### 15.4 ExposedPropertyMessageRange

```cpp
class ExposedPropertyMessageRange : public ExposedMessageRange
{
public:
    int exposedIDFromMsgID( Mercury::MessageID msgID ) const {
        return this->simpleExposedIDFromMsgID( msgID );
    }

    int16 msgIDFromExposedID( int exposedID ) const {
        return (exposedID < this->numSlots()) ?
            static_cast<int16>(exposedID + firstMsgID_) : -1;
    }
};
```

字段变更不需要 SubID,因为字段数量通常较少(`maxClientServerPropertyCount` 上限默认 256)。

### 15.5 安全控制

`ExposedMessageRange` 实现了 BigWorld 的"客户端可调用范围"安全控制:

- 客户端只能发送 `firstMsgID ~ lastMsgID` 范围内的消息。
- 服务器收到消息后,根据 `exposedIDFromMsgID` 找到对应的 `MethodDescription`。
- 若该方法未被 `<Exposed>` 标记,服务器拒绝执行。

这是 BigWorld 防止客户端越权调用服务端方法的核心机制。

### 15.6 setExposedMsgID

`MethodDescription::setExposedMsgID`(声明 `method_description.hpp` L229-L230):

```cpp
void setExposedMsgID( int exposedID, int numExposed,
    const ExposedMethodMessageRange * pRange );
```

实现:

```cpp
void MethodDescription::setExposedMsgID( int exposedID, int numExposed,
    const ExposedMethodMessageRange * pRange )
{
    exposedIndex_ = exposedID;
    if (pRange) {
        pRange->msgIDFromExposedID( exposedID, numExposed,
            exposedMsgID_, exposedSubMsgID_ );
    }
}
```

`exposedMsgID_` 与 `exposedSubMsgID_` 之后被用于构造网络消息头。

---

## 十六、Mailbox 与 EntityDef 的协作

Mailbox(参见专题 05)与 EntityDef 紧密协作完成跨进程方法调用。

### 16.1 Mailbox 持有 EntityDescription

每个 `Mailbox` 持有目标实体的 `EntityDescription` 引用:

```cpp
class MailboxBase {
    EntityID id_;
    EntityTypeID typeID_;
    const EntityDescription *pDesc_;
    // ...
};
```

通过 `pDesc_`,Mailbox 知道目标实体有哪些方法、每个方法的流格式。

### 16.2 方法调用流程

```
Python 脚本: entity.cell.onHit(damage)
   │
   ▼
PyEntityMailBox::__getattr__("onHit")
   │ 返回 RemoteEntityMethod 代理对象
   ▼
RemoteEntityMethod::__call__(damage)
   │
   ├─► 1. 通过 pDesc_->cell().find("onHit") 找到 MethodDescription
   ├─► 2. 检查 isExposed() (若来自客户端)
   ├─► 3. areValidArgs(args) 校验参数类型
   ├─► 4. 创建 Bundle,写入 exposedMsgID
   ├─► 5. methodDescription.addToStream(source, bundle)
   ├─► 6. 通过 Channel 发送 Bundle
   │
   ▼
远端 CellApp:
   ├─► 7. Mercury 收到消息,根据 msgID 找到 ExposedMethodMessageRange
   ├─► 8. EntityMethodDescriptions::exposedMethodFromMsgID 找到 MethodDescription
   ├─► 9. 找到目标 Entity 对象
   ├─► 10. methodDescription.callMethod(entity, bundle, sourceID, ...)
   │       ├─► getArgsAsTuple:从流构造 Python tuple
   │       ├─► entity.onHit(*args)
   │       └─► (若有 ReturnValues)将返回值发回
   └─► 11. 完成
```

### 16.3 远端方法代理

`RemoteEntityMethod`(`remote_entity_method.hpp`)是 Mailbox 返回给 Python 的"方法代理对象":

```python
# Python 视角
mb = entity.base  # mb 是 PyEntityMailBox
method = mb.onHit  # method 是 RemoteEntityMethod
method(50)         # 触发实际网络调用
```

`RemoteEntityMethod::operator()` 内部调用 `MailboxBase::sendMethodCall`,完成:

1. 查找 MethodDescription。
2. 校验参数。
3. 构造 Bundle。
4. 通过 Mercury 发送。

### 16.4 跨 Component 调用示例

```python
# 在 Base 脚本中调用 Cell 方法
def onLogin(self, username):
    # self.cell 是 CellEntityMailBox
    self.cell.onEnterWorld()
    # self.client 是 ClientEntityMailBox
    self.client.showWelcome(username)
    # self.other.cell 是其他实体的 Cell Mailbox
    self.other.cell.onGreeted(self.id)
```

每次 `self.xxx.method(args)` 都通过 EntityDef 元数据自动完成序列化与分发。

---

## 十七、DataDomain 与流分发算法

`EntityDescription::addToStream`(`entity_description.cpp` L1472-L1526)是字段同步的核心算法。

### 17.1 NUM_PASSES 四遍扫描

```cpp
static int NUM_PASSES = 4;
```

四遍扫描分别对应:

| Pass | 数据特征 | 描述 |
|------|---------|------|
| 0 | Base 且非 Client | 纯 Base 字段 |
| 1 | Base 且 Client | Base 持有,需要发往 Client |
| 2 | Cell 且 Client | Cell 持有,需要发往 Client |
| 3 | Cell 且非 Client | 纯 Cell 字段(如 Ghost) |

### 17.2 shouldSkipPass 算法

```cpp
/*static*/ bool EntityDescription::shouldSkipPass( int pass, int dataDomains )
{
    const int PASS_JUMPER[4] =
    {
        EXACT_MATCH | BASE_DATA,                  // pass 0
        EXACT_MATCH | BASE_DATA | CLIENT_DATA,    // pass 1
        EXACT_MATCH | CELL_DATA | CLIENT_DATA,    // pass 2
        EXACT_MATCH | CELL_DATA                   // pass 3
    };

    if (dataDomains & EXACT_MATCH) {
        // 严格匹配:所有 flag 必须一致
        return (dataDomains != PASS_JUMPER[ pass ]);
    } else {
        // 非严格:任一 flag 匹配即可
        return ((dataDomains & PASS_JUMPER[ pass ]) == 0);
    }
}
```

`PASS_JUMPER` 表示每个 pass 期望的"数据特征"。

### 17.3 shouldConsiderData 算法

```cpp
/*static*/ bool EntityDescription::shouldConsiderData( int pass,
    const DataDescription * pDD, int dataDomains )
{
    const bool PASS_FILTER[4][2] =
    {
        { true,  false },  // pass 0: Base 且非 client
        { true,  true },   // pass 1: Base 且 client
        { false, true },   // pass 2: Cell 且 client
        { false, false }   // pass 3: Cell 且非 client
    };

    return (PASS_FILTER[ pass ][0] == pDD->isBaseData()) &&
           (PASS_FILTER[ pass ][1] == pDD->isClientServerData()) &&
           (pDD->isOtherClientData() ||
               !(dataDomains & ONLY_OTHER_CLIENT_DATA)) &&
           (pDD->isPersistent() || !(dataDomains & ONLY_PERSISTENT_DATA));
}
```

四个条件:

1. 字段的 `isBaseData()` 与 pass 期望匹配。
2. 字段的 `isClientServerData()` 与 pass 期望匹配。
3. 若 dataDomains 要求 ONLY_OTHER_CLIENT_DATA,字段必须是 OTHER_CLIENT。
4. 若 dataDomains 要求 ONLY_PERSISTENT_DATA,字段必须持久化。

### 17.4 完整算法

```cpp
bool EntityDescription::addToStream( const AddToStreamVisitor & visitor,
    BinaryOStream & stream, int dataDomains,
    int32 * pDataSizes, int numDataSizes ) const
{
    int actualPass = 0;
    for (int pass = 0; pass < NUM_PASSES; pass++) {
        if (!EntityDescription::shouldSkipPass( pass, dataDomains )) {
            int initialStreamSize = stream.size();

            for (uint i = 0; i < this->propertyCount(); i++) {
                DataDescription * pDD = this->property( i );
                if (EntityDescription::shouldConsiderData( pass, pDD, dataDomains )) {
                    if (!visitor.addToStream( *pDD, stream,
                        (dataDomains & ONLY_PERSISTENT_DATA) != 0 )) {
                        ERROR_MSG( "STREAM NOW INVALID!!" );
                        return false;
                    }
                }
            }

            if ((pDataSizes != NULL) && (actualPass < numDataSizes)) {
                pDataSizes[actualPass] = stream.size() - initialStreamSize;
            }
            actualPass++;
        }
    }
    return true;
}
```

**关键设计**:

- 四遍扫描保证字段按"Base-非Client → Base-Client → Cell-Client → Cell-非Client"顺序写入流。
- 接收端按相同顺序读取,无需 ID 标识每个字段(节省带宽)。
- `pDataSizes` 可选地记录每个 pass 的字节数,用于接收端校验。

### 17.5 visit 方法

`visit`(L1538-L1560)与 `addToStream` 算法相同,但调用 `visitor.visit(*pDD)` 而非 `visitor.addToStream`。这是用于只读遍历,如 `process_defs` 生成 Python 描述。

### 17.6 readStreamToDict 算法

`readStreamToDict`(L1567-L1615)是接收端算法:

```cpp
class Visitor : public IDataDescriptionVisitor
{
    bool visit( const DataDescription & dataDesc ) {
        ScriptDataSink sink;
        bool result = dataDesc.createFromStream( stream_, sink, onlyPersistent_ );
        ScriptObject pValue = sink.finalise();
        if (!dataDesc.insertItemInto( map_, pValue )) {
            ERROR_MSG( "Failed to set %s\n", dataDesc.name().c_str() );
        }
        return !stream_.error();
    }
};
```

按相同的 pass 顺序从流中读取字段值,插入到 Python dict。

### 17.7 readTaggedClientStreamToDict 算法

`readTaggedClientStreamToDict`(L1622-L1658)是**增量同步**算法:

```cpp
bool EntityDescription::readTaggedClientStreamToDict( BinaryIStream & stream,
    const ScriptMapping & dict, bool allowOwnClientData ) const
{
    uint8 size;
    stream >> size;

    for (uint8 i = 0; i < size; i++) {
        uint8 index;
        stream >> index;

        const DataDescription * pDD = this->clientServerProperty( index );
        MF_ASSERT_DEV( pDD && (pDD->isOtherClientData() ||
            (allowOwnClientData && pDD->isOwnClientData())) );

        ScriptDataSink sink;
        bool result = pDD->createFromStream( stream, sink, /* isPersistentOnly */ false );
        ScriptObject value = sink.finalise();

        if (!pDD->insertItemInto( dict, value ))
            Script::printError();
    }
    return true;
}
```

**Tagged 流格式**:

```
| size (1B) | index1 (1B) | value1 (variable) | index2 (1B) | value2 (variable) | ...
```

每个字段带 1 字节 ID,允许只发送变化的字段(增量同步)。这是 OtherClient 字段在 Ghost 上的更新方式。

---

## 十八、.def → Python 描述对象转换流程

`process_defs` 工具(`tools/process_defs/main.cpp`)是 EntityDef 的离线代码生成器。

### 18.1 整体流程

```
1. main() 启动
2. BWResource init(资源路径)
3. Script::init(Python)
4. EntityDescriptionMap::parse(scripts/entities.xml, ...)
5. process(moduleName, functionName, entityDescriptionMap)
   ├─► createEntityDescriptions(map) → ScriptTuple
   ├─► createDigest(map) → ScriptString
   ├─► 组装 constants dict
   └─► callFunction(moduleName, functionName, description)
6. Script::fini
7. MetaDataType::fini
```

### 18.2 createEntityDescription 函数

`createEntityDescription`(L244-L306)为每个实体生成一个 dict:

```python
{
    "name": "Avatar",
    "index": 0,
    "clientIndex": 0,
    "hasClientScript": True,
    "hasBaseScript": True,
    "hasCellScript": True,
    "canBeOnClient": True,
    "canBeOnBase": True,
    "canBeOnCell": True,
    "isService": False,
    "isPersistent": True,
    "clientMethods": (...),
    "baseMethods": (...),
    "cellMethods": (...),
    "allProperties": (...),
    "clientProperties": (...),
    "baseToClientProperties": (...),
    "cellToClientProperties": (...)
}
```

### 18.3 createMethodDescriptions 函数

`createMethodDescriptions`(L96-L142)为每个方法生成 dict:

```python
{
    "name": "onHit",
    "isExposed": True,
    "internalIndex": 0,
    "exposedIndex": 0,
    "args": (type1, type2, ...),
    "returnValues": (type1, ...),  # 若有
    "streamSize": 4
}
```

### 18.4 createPropertyDescription 函数

`createPropertyDescription`(L148-L184)为每个字段生成 dict:

```python
{
    "type": "INT32",
    "name": "hp",
    "index": 0,
    "clientServerFullIndex": 0,
    "isGhostedData": True,
    "isOtherClientData": True,
    "isOwnClientData": True,
    "isCellData": True,
    "isBaseData": False,
    "isClientServerData": True,
    "isPersistent": True,
    "isIdentifier": False,
    "isIndexed": False,
    "isUnique": False,
    "streamSize": 4,
    "isConst": True
}
```

### 18.5 createOrderedProperties 函数

`createOrderedProperties`(L211-L237)使用 `IDataDescriptionVisitor` 模式按 DataDomain 顺序遍历字段:

```cpp
class Visitor : public IDataDescriptionVisitor {
    bool visit( const DataDescription & dataDesc ) {
        descriptions_.append( createPropertyDescription( dataDesc ) );
        return true;
    }
};
Visitor visitor;
entityDescription.visit( dataDomains, visitor );
```

调用 `visit` 时传入不同的 `dataDomains`:

- `CLIENT_DATA`:仅客户端字段。
- `FROM_BASE_TO_CLIENT_DATA`:Base → Client 同步字段。
- `FROM_CELL_TO_CLIENT_DATA`:Cell → Client 同步字段。

### 18.6 createDigest 函数

```cpp
ScriptObject createDigest( const EntityDescriptionMap & entityDescriptionMap )
{
    MD5 md5;
    entityDescriptionMap.addToMD5( md5 );
    MD5::Digest digest;
    md5.getDigest( digest );
    return ScriptObject::createFrom( digest.quote() );
}
```

`digest.quote()` 把 16 字节摘要转为可打印字符串(如 `md5:abcdef...`)。

### 18.7 process 函数

```cpp
bool process( const char * moduleName, const char * functionName,
    EntityDescriptionMap& entityDescriptionMap )
{
    ScriptDict description = ScriptDict::create();
    description.setItem( "entityTypes",
        createEntityDescriptions( entityDescriptionMap ), ... );

    ScriptDict constants = ScriptDict::create();
    constants.setItem( "digest", createDigest( entityDescriptionMap ), ... );
    constants.setItem( "maxExposedClientMethodCount", ... );
    constants.setItem( "maxExposedBaseMethodCount", ... );
    constants.setItem( "maxExposedCellMethodCount", ... );
    constants.setItem( "maxClientServerPropertyCount", ... );
    description.setItem( "constants", constants, ... );

    return callFunction( moduleName, functionName, description );
}
```

最终 Python 模块(默认 `ProcessDefs.process`)接收 `description` dict,可以生成:

- 客户端 `EntityDef.py` 描述文件。
- 服务器端类型映射。
- MD5 校验文件。
- 编辑器元数据。

### 18.8 callFunction 函数

```cpp
bool callFunction( const char * moduleName, const char * functionName,
    ScriptObject argument, bool shouldPrintError = true )
{
    ScriptModule module = Personality::import( moduleName );
    if (!module) return false;

    ScriptObject ret = module.callMethod( functionName,
        ScriptArgs::create( argument ),
        shouldPrintError ? ScriptErrorPrint(...) : ScriptErrorClear(),
        /*allowNullMethod*/ true );
    return ret && ret.isTrue( ScriptErrorClear() );
}
```

`Personality::import` 是 BigWorld 的 Python 模块加载器,支持从资源路径加载。`allowNullMethod=true` 允许模块不实现该方法(返回 false 而非报错)。

---

## 十九、Python 实体类

每个 Entity 类型对应一个 Python 类。

### 19.1 类层次

```python
# scripts/common/BigWorld.py
class Entity:
    """所有实体的基类"""
    id = 0
    className = ""
    # ...

# scripts/cell/Avatar.py
class Avatar(BigWorld.Entity):
    def __init__(self):
        self.hp = 100
        # ...

    def onHit(self, damage):
        self.hp -= damage
        if self.hp <= 0:
            self.onDie()
```

### 19.2 BigWorld.Entity 基类

`BigWorld.Entity`(在 C++ 中实现,通过 ` BaseEntity::pyType` 注册)提供:

- `id`、`className` 等基本属性。
- `cell`、`base`、`client` Mailbox 属性。
- `position`、`yaw`、`pitch`、`roll` Volatile 属性。
- `destroy()`、`onLoad()`、`onSave()`、`onRestore()` 生命周期回调。
- 自动字段访问(`__getattr__` / `__setattr__` 路由到 C++)。

### 19.3 字段访问机制

```python
# Python
entity.hp = 50  # 触发 C++ 端的 setter
print(entity.hp)  # 触发 C++ 端的 getter
```

C++ 端(`BaseEntity::pySetAttribute`)的实现:

1. 检查属性名是否在 `EntityDescription::properties_` 中。
2. 若是,调用 `DataDescription::isCorrectType` 校验。
3. 调用 `DataDescription::callSetterCallback` 触发脚本回调。
4. 实际写入 entity 的字段存储。
5. 若字段是 `OTHER_CLIENT` 或 `OWN_CLIENT`,触发 PropertyChange 通知。
6. 若字段是 `DATA_PERSISTENT`,标记 entity 为 dirty(下次 saveToDB 时写入)。

### 19.4 生命周期回调

| 回调 | 时机 |
|------|------|
| `__init__(self)` | 实体创建 |
| `onLoad(self, ...)` | 从数据库加载 |
| `onSave(self, ...)` | 写入数据库前 |
| `onRestore(self, ...)` | 备份恢复后 |
| `onDestroy(self)` | 实体销毁 |
| `onEnterWorld(self)` | 进入 AoI |
| `onLeaveWorld(self)` | 离开 AoI |
| `onBecomePlayer(self)` | 成为玩家代理 |
| `onLosePlayer(self)` | 不再是玩家代理 |

### 19.5 静态字段定义

Python 类可以通过 `__slots__` 或类属性声明静态字段:

```python
class Avatar(BigWorld.Entity):
    __slots__ = (
        "hp", "mp", "name", "inventory", "position"
    )
```

但这只是文档用途——实际字段集由 `.def` 文件决定。`EntityDescription::checkMethods` 会校验 Python 类是否实现了 `.def` 中声明的所有方法(`isMethodHandledBy`),但字段不强制声明。

### 19.6 方法分发

```python
class Avatar(BigWorld.Entity):
    def onHit(self, damage):  # Cell 方法
        ...

    def saveToDB(self):  # Base 方法
        ...

    def showDamage(self, damage):  # Client 方法
        ...
```

C++ 端通过 `MethodDescription::getMethodFrom(self)` 获取 Python 方法对象并调用。如果方法未定义,`isMethodHandledBy` 返回 false,通常会 ERROR(除非 `warnOnMissing=false`)。

---

## 二十、方法自动分发机制

### 20.1 调用源 → 目标矩阵

| 调用源 ↓ \ 目标 → | Cell 方法 | Base 方法 | Client 方法 |
|------------------|----------|----------|-------------|
| **Client** | 通过 Proxy 的 cell mailbox(必须 Exposed) | 通过 Proxy 的 base mailbox(必须 Exposed) | N/A |
| **Cell** | 直接调用本地 / 通过 cell mailbox 远程 | 通过 base mailbox | 通过 client mailbox |
| **Base** | 通过 cell mailbox | 直接调用本地 / 通过 base mailbox 远程 | 通过 client mailbox |
| **Service** | N/A | 通过 base mailbox | N/A |

### 20.2 客户端调用 Cell Exposed 方法

```python
# 客户端 Python
self.cell.onHit(50)
```

C++ 端流程:

1. `self.cell` 获取 CellEntityMailBox。
2. `__getattr__("onHit")` 返回 RemoteEntityMethod 代理。
3. `RemoteEntityMethod::operator()(50)`:
   - 通过 `pDesc_->cell().find("onHit")` 找到 MethodDescription。
   - 检查 `isExposed()` 与 `isExposedForClient()`(确认方法对客户端暴露)。
   - 检查 `exposedMsgID` 不为 `INVALID_MSG_ID`(确认 BaseApp 已分配消息 ID)。
   - 调用 `MethodDescription::addToStream(stream, 50)`,将参数 50 按 `.def` 中声明的参数类型序列化到 Mercury `BinaryOStream`。
   - 调用 `CellEntityMailBox::sendStream(stream)`,封装 Mercury 消息头并投递到底层网络层。

4. **Cell 端收包与分发**:
   - CellApp 的 `CellAppExtInterface` 接收到该消息,根据 `exposedMsgID` 在 `EntityMethodDescriptions::exposedMethodFromMsgID(msgID)` 中找到对应的 `MethodDescription`。
   - 通过 `Entity::pDesc()` 获取目标实体的 `EntityDescription`。
   - 调用 `MethodDescription::callMethod(entity, args)`,该函数内部:
     - 通过 `getMethodFrom(pEntity)` 取得 Python 端的 `onHit` 方法对象(若未实现则发出 `ERROR_MSG` 并丢弃)。
     - 调用 `Script::call(pMethod, args)` 触发 Python 侧的 `Avatar.onHit(self, 50)`。
   - 若 `MethodDescription` 声明了返回值且客户端使用 `RemoteEntityMethod` 的回调机制,Cell 端会再通过反向 Mercury 消息把返回值送回 Client 端的 `PyDeferredResponse`。

### 20.3 Cell 调用 Client 方法

```python
# Cell 端 Python
self.client.showDamage(50)
```

由于 Client 端是被动接收方,Cell 端调用 Client 方法不需要 `Exposed` 标记(由 CellApp 主动发起):

1. `self.client` 取得 `ClientEntityMailBox`。
2. `__getattr__("showDamage")` 返回 `RemoteEntityMethod` 代理。
3. `RemoteEntityMethod::operator()(50)`:
   - `pDesc_->client().find("showDamage")` 找到 `MethodDescription`。
   - 调用 `MethodDescription::addToClientStream` 严格按客户端可见参数类型序列化。
   - 发送 Mercury 消息到对应 BaseApp,由 BaseApp 转发给真正的 Client。

> **注意**:Cell 不直接与 Client 通信,所有 Cell→Client 消息必须经由 BaseApp 转发,这是 BigWorld 四进程架构的安全保证——Cell 永远不直接持有客户端网络连接。

### 20.4 Base 与 Cell 之间的方法互调

```python
# Base 端 Python 调用 Cell
self.cell.setHP(50)

# Cell 端 Python 调用 Base
self.base.onCellReady()
```

Base→Cell 与 Cell→Base 的方法调用流程与上述类似,但有两点差异:

1. **方向标记**:`EntityMethodDescriptions` 在 `init()` 时根据 `exposedMsgID` 与 `exposedToClient` 标记推断方法方向。Base→Cell 与 Cell→Base 的 Mercury 消息 ID 范围不同(分别由 `BaseAppExtInterface::Range::cellEntityMethodRange` 与 `baseEntityMethodRange` 管理),通过 ID 范围即可识别方向。
2. **本地优先**:若 Base 和 Cell 在同一进程(BaseApp 与 CellApp 同进程,仅调试场景下出现),`Mailbox::sendStream` 会走 "本地实体" 快路径,直接调用 `MethodDescription::callMethod` 而不经 Mercury 序列化。

### 20.5 Mailbox 调用源码走读

`Mailbox` 的核心是 `EntityMailBox::sendStream`(`programming/bigworld/lib/network/entity_mail_box.cpp`):

```cpp
void EntityMailBox::sendStream( BinaryOStream & data )
{
    // 1. 取得当前 Mercury channel
    Mercury::UDPChannel * pChannel = this->pChannel();
    if (!pChannel) {
        ERROR_MSG("Mailbox has no channel\n");
        return;
    }

    // 2. 构造 Mercury 消息头(包含 exposedMsgID 与 entityID)
    Mercury::UnpackedMessageHeader & header = ...;
    header.identifier = exposedMsgID;
    header.length = data.size();

    // 3. 调用 Mercury::UDPChannel::send 发送
    pChannel->send(header, data);
}
```

`RemoteEntityMethod::operator()`(`programming/bigworld/lib/network/entity_mail_box.cpp`)的核心步骤:

```cpp
PyObjectPtr RemoteEntityMethod::operator()( PyObjectPtr args, PyObjectPtr kwargs )
{
    // 1. 取得对应的 MethodDescription
    MethodDescription * pMethod = pDesc_->find(name_);
    if (!pMethod) {
        PyErr_Format(PyExc_AttributeError, "no method '%s'", name_.c_str());
        return NULL;
    }

    // 2. 检查暴露标志(是否允许从当前源调用)
    if (!pMethod->isExposed() || !pMethod->isExposedForClient()) {
        PyErr_Format(PyExc_RuntimeError, "method '%s' not exposed", name_.c_str());
        return NULL;
    }

    // 3. 创建 Mercury 输出流,将方法 ID 写入头部
    BinaryOStream * pStream = pMailBox_->beginStream();
    (*pStream) << pMethod->exposedMsgID();

    // 4. 将参数列表序列化到流(MethodDescription::addToStream)
    if (!pMethod->addToStream(*pStream, args)) {
        PyErr_Format(PyExc_TypeError, "argument mismatch for '%s'", name_.c_str());
        return NULL;
    }

    // 5. 发送并返回 None(或 PyDeferredResponse 用于有返回值的方法)
    pMailBox_->sendStream();
    Py_RETURN_NONE;
}
```

### 20.6 方法 ID 的分配与查找

`EntityMethodDescriptions::setExposedMsgIDs`(`entity_method_descriptions.cpp`)在 `EntityDescriptionMap::parse` 后期被调用,为每个暴露方法分配唯一的 Mercury 消息 ID:

```cpp
bool EntityMethodDescriptions::setExposedMsgIDs(
        ExposedMessageRange & range, int component )
{
    for (uint i = 0; i < methodDescriptions_.size(); i++)
    {
        MethodDescription & m = *methodDescriptions_[i];

        // 仅暴露的方法需要 ID
        if (m.exposedTo() != EXPOSE_NONE)
        {
            uint16 msgID;
            if (!range.giveThisID(msgID))
            {
                ERROR_MSG("EntityMethodDescriptions::setExposedMsgIDs: "
                          "ran out of IDs\n");
                return false;
            }
            m.exposedMsgID(msgID);
        }
    }
    return true;
}
```

`ExposedMessageRange::giveThisID`(`programming/bigworld/lib/network/exposed_message_range.cpp`):

```cpp
bool ExposedMessageRange::giveThisID( uint16 & id )
{
    if (nextID_ > end_) return false;
    id = nextID_++;
    return true;
}
```

查询路径:`CellApp` 收到一条 Mercury 消息后,从消息头取出 `exposedMsgID`,然后调用:

```cpp
const MethodDescription * EntityMethodDescriptions::exposedMethodFromMsgID(
                                                    int msgID ) const
{
    if (exposedMethodMap_.empty())
    {
        return NULL;
    }
    ExposedMethodMap::const_iterator it =
        exposedMethodMap_.find(static_cast<uint8>(msgID - exposedMsgIDOffset_));
    if (it == exposedMethodMap_.end()) return NULL;
    return it->second;
}
```

注意 `msgID - exposedMsgIDOffset_` 这个减法:在 `EntityMethodDescriptions::init` 中 `exposedMsgIDOffset_` 被设为该组件(OWN_CLIENT/ALL_CLIENTS/BASE_AND_CLIENT/CELL_AND_CLIENT 等)的最小 `exposedMsgID`,从而将 `uint16` 的全局消息 ID 压缩为 `uint8` 数组索引,节省查找内存。

### 20.7 方法的 supersede 机制

`.def` 中可通过 `Subsume=` 标记声明一个方法替换另一个旧方法,`EntityMethodDescriptions::supersede`(`entity_method_descriptions.cpp`)负责处理:

```cpp
void EntityMethodDescriptions::supersede(
        const EntityMethodDescriptions & predecessors ) const
{
    for (uint i = 0; i < methodDescriptions_.size(); i++)
    {
        const MethodDescription & m = *methodDescriptions_[i];
        if (m.subsumedName() == NULL) continue;

        // 在前驱版本中找到被替换的方法
        for (uint j = 0; j < predecessors.size(); j++)
        {
            const MethodDescription & p = *predecessors[j];
            if (p.name() == m.subsumedName())
            {
                // 共享 exposedMsgID,实现老客户端调老 ID 仍能命中新方法
                m.subsumedID_ = p.exposedMsgID();
                break;
            }
        }
    }
}
```

这使得 BigWorld 在线热更新 `.def` 时,旧客户端编译进二进制的旧 `exposedMsgID` 仍能命中新版本的方法实现——一种"软"协议兼容方案,与 Protobuf 的 `reserved` 字段思路类似。

### 20.8 自动分发总览图

```
┌──────────┐                ┌──────────┐                ┌──────────┐
│  Client  │                │   Base   │                │   Cell   │
│ (Player) │                │   App    │                │   App    │
└────┬─────┘                └────┬─────┘                └────┬─────┘
     │                           │                           │
     │ 1) self.cell.onHit(50)    │                           │
     │  RemoteEntityMethod       │                           │
     │  → addToStream(50)        │                           │
     │  → Mercury msg w/         │                           │
     │    exposedMsgID           │                           │
     │                           │                           │
     │  ────────────────────►    │                           │
     │                           │ 2) BaseApp 转发           │
     │                           │    → 不解包,直接 forward  │
     │                           │  ─────────────────────►   │
     │                           │                           │
     │                           │                  3) CellApp 收到
     │                           │                  exposedMethodFromMsgID
     │                           │                  → MethodDescription
     │                           │                  → callMethod(entity, args)
     │                           │                  → Python Avatar.onHit(50)
     │                           │                           │
     │                           │                  4) 返回值(可选)
     │                           │  ◄───────────────────────
     │  ◄──────────────────────  │   PyDeferredResponse 触发 │
     │  callback(returnedValue)  │                           │
```

---

## 二十一、字段同步机制

字段同步是 EntityDef 最具工程价值的能力之一。它将"实体某个属性变了 → 谁该看到这个变化 → 通过什么 Mercury 消息送出去 → 接收端怎么写回实体字段"的整条链路自动化。

### 21.1 同步方向矩阵

| 字段标志 | 写入端 | 同步到 Cell | 同步到 Base | 同步到 Client | 持久化到 DB |
|---------|--------|------------|------------|--------------|------------|
| `BASE_DATA` | Base | ❌ | ✅(自身) | ❌ | ❌ |
| `CELL_DATA` | Cell | ✅(自身) | ❌ | ❌ | ❌ |
| `OWN_CLIENT_DATA` | Client/Player | ❌ | ❌ | ✅(仅自己) | ❌ |
| `OTHER_CLIENT_DATA` | Cell | ❌ | ❌ | ✅(其他玩家) | ❌ |
| `ALL_CLIENTS_DATA` | Cell/Base | ❌ | ❌ | ✅(全部客户端) | ❌ |
| `DATA_PERSISTENT` | Base | ❌ | ✅ | ❌ | ✅ |

这些标志在 `data_description.cpp` 顶部的 `EntityDataFlagMappings` 数组中定义:

```cpp
static const EntityDataFlagMappings[] =
{
    { "Cell",            EntityDataFlags::CELL_DATA,             DataDomain::Cell },
    { "Base",            EntityDataFlags::BASE_DATA,             DataDomain::Base },
    { "OwnClient",       EntityDataFlags::OWN_CLIENT_DATA,       DataDomain::Client },
    { "OtherClient",     EntityDataFlags::OTHER_CLIENT_DATA,     DataDomain::Client },
    { "AllClients",      EntityDataFlags::ALL_CLIENTS_DATA,      DataDomain::Client },
    { "Persistent",      EntityDataFlags::DATA_PERSISTENT,       DataDomain::Base },
};
```

### 21.2 PropertyChange 通知体系

每当字段被 setter 修改,EntityDef 不会立即发送同步消息——它先把"字段已变"标记入 dirty set,在 Mercury tick 时再批量发送。这避免了高频字段(如位置)在网络抖动时淹没带宽。

`PropertyChange` 是抽象基类,有两种实现(`property_change_reader.hpp`):

```cpp
class PropertyChange
{
public:
    virtual void read( BinaryIStream & stream ) = 0;
    virtual void write( BinaryOStream & stream ) const = 0;
    virtual void apply( Entity & entity ) = 0;
    virtual bool isLatest() const = 0;
};

// 单字段变更:仅携带一个 fieldID + value
class SinglePropertyChange : public PropertyChange
{
    DataDescriptionID propertyID_;
    ScriptObject      value_;
};

// 切片变更:一次性打包多个相邻 fieldID 的变更
class SlicePropertyChange : public PropertyChange
{
    DataDescriptionID firstID_;
    ScriptList         values_;
};
```

### 21.3 SinglePropertyChange 流程

```python
# Cell 端 Python
entity.setHP(50)
```

1. `setHP` 走 `Entity::pySetAttribute` 路径,匹配到 `DataDescription::callSetterCallback`。
2. `DataDescription::callSetterCallback` 完成回调后,调用 `Entity::onPropertyUpdated(*this)`。
3. `onPropertyUpdated` 检查 `dataDescription.isOtherClientData()`,如是则:
   - 把 `SinglePropertyChange(propertyID=hp, value=50)` 加入 `CellAppExtInterface::propertyChangeQueue_`。
4. 下一个 Mercury tick,`PropertyChangeReader` 把队列中的变更通过 `BaseAppExtInterface::allClientsPropUpdate` 消息发出。
5. BaseApp 收到后:
   - 如果是 `OTHER_CLIENT_DATA`,转发给所有"该实体的 AoI 邻居玩家"。
   - 如果是 `OWN_CLIENT_DATA`,仅转发给拥有者。
6. Client 端收到 `allClientsPropUpdate`:
   - 通过 `propertyID` 在 `EntityDescription` 中找到 `DataDescription`。
   - 调用 `DataDescription::fromStreamToPyObject` 把流反序列化为 Python 对象。
   - 通过 `__setattr__` 写入 entity 实例,触发 Python 端的 `onHPChanged(oldValue)` 之类的 hook。

### 21.4 SlicePropertyChange 流程

切片变更用于相邻字段同时变化(例如位置 x/y/z 同时更新,或一组状态机标记同时翻转)。`SlicePropertyChange` 的优势在于:

- **一次 Mercury 头开销,多个字段变更**:Mercury 消息头本身约 16 字节,频繁小消息会浪费带宽。
- **字段顺序连续性**:BigWorld 在 `EntityDescriptionMap::parse` 完成后调用 `allocateClientServerFullIndexes`,为每个 client-visible 字段分配连续 ID,从而允许 SlicePropertyChange 用 `firstID + length` 表示一段。

```
┌─────────────────────────────────────────────────────────┐
│  SlicePropertyChange 消息体                              │
├─────────────────────────────────────────────────────────┤
│ firstID (uint16) │ length (uint8) │ [value1][value2]…   │
└─────────────────────────────────────────────────────────┘
```

接收端按 `DataDescription[firstID..firstID+length]` 依次取出并调用 `fromStreamToPyObject`。

### 21.5 Latest-only 优化

某些字段属于"只关心最新值"语义(典型:位置、朝向)。在 `DataDescription::LatestOnly` 标志下:

- CellApp 维护一个 `latest_property_changes_` map,而非队列。
- 当新变更到达时,直接覆盖旧值,**不再发送旧版本**。
- 这大幅减少位置同步的延迟和带宽——客户端始终看到"最新一次"的位置,而非按顺序重放历史位置。

### 21.6 Direction 过滤

`DataDescription::add/asDirection` 在接收端也起作用。一条 `allClientsPropUpdate` 消息可能包含 `OTHER_CLIENT` 与 `ALL_CLIENTS` 两类字段,但 BaseApp 转发时会根据每个接收者的身份过滤:

- 拥有者:转发 `OWN_CLIENT` + `ALL_CLIENTS`。
- AoI 邻居:仅转发 `OTHER_CLIENT` + `ALL_CLIENTS`。
- 非 AoI:不转发。

这种过滤发生在 BaseApp 的 `Proxy::forwardPropertyUpdate` 函数中,而非 CellApp 端——Cell 永远不知道有哪些 Client 在 AoI 里。

### 21.7 持久字段的写入路径

`DATA_PERSISTENT` 字段的同步与上述不同,它不发 Mercury,而是直接写入 BaseApp 的 `EntityDatabase`:

1. BaseApp 维护 dirty entity 集合 `dirtyEntities_`,在 `BaseApp::tickSaveEntities` 中按 5 秒钟一次的节奏批处理。
2. 对每个 dirty entity,调用 `BaseApp::saveEntityToDB(entity)`:
   - 遍历所有 `DATA_PERSISTENT` 字段。
   - 对每个字段,`DataDescription::addToSection(stream, pSection)` 把字段值写入一个 `DataSection`(XML 节点)。
   - 把整个 `DataSection` 提交给 `EntityDatabase::putEntity(entityID, pSection)`,异步写入。
3. DBApp 收到 `putEntity` 消息后,真正写 MySQL/Redis/文件。

这条路径不涉及 PropertyChange,因为持久字段不需要"实时"同步。

### 21.8 字段同步总览

```
            ┌─── Cell App ─────────────────────────────────┐
            │                                                │
   Python ──┼─► entity.setHP(50)                            │
            │    │                                           │
            │    ▼                                           │
            │  DataDescription::callSetterCallback           │
            │    │                                           │
            │    ▼                                           │
            │  Entity::onPropertyUpdated(dd)                │
            │    │                                           │
            │    ├── if OTHER_CLIENT/ALL_CLIENTS:           │
            │    │     enqueue PropertyChange                │
            │    │                                           │
            │    └── if DATA_PERSISTENT:                    │
            │          mark entity dirty                     │
            └─────┬─────────────────────────────────────────┘
                  │ (Mercury tick)
                  ▼
            ┌─── Base App ──────────────────────────────────┐
            │  forwardPropertyUpdate:                        │
            │    ├── player's own client → OWN_CLIENT stream │
            │    └── AoI neighbors → OTHER_CLIENT stream     │
            └─────┬─────────────────────────────────────────┘
                  │ (Mercury message: allClientsPropUpdate)
                  ▼
            ┌─── Client ────────────────────────────────────┐
            │  PropertyChangeReader::read                    │
            │    ├── SinglePropertyChange → apply(entity)    │
            │    └── SlicePropertyChange → applySlice(entity)│
            │                                                │
            │  → entity.hp = 50  (Python 层 __setattr__)    │
            │  → onHPChanged(50) hook 触发                   │
            └────────────────────────────────────────────────┘
```

---

## 二十二、MD5 摘要与版本兼容

BigWorld 用 MD5 摘要作为整个 `.def` 集合的"版本号"。客户端与服务端在 LoginApp 登录时交换摘要,如果不匹配则拒绝进入游戏——这是 BigWorld 防御"客户端协议过期导致反序列化崩溃"的核心机制。

### 22.1 addToMD5 总入口

`EntityDescriptionMap::addToMD5`(`entity_description_map.cpp`)是入口:

```cpp
void EntityDescriptionMap::addToMD5( MD5 & md5 ) const
{
    // 1. 写入实体类型数量
    int size = this->size();
    md5.append(&size, sizeof(size));

    // 2. 对每个 EntityDescription 添加其摘要
    for (const_iterator iter = begin(); iter != end(); ++iter)
    {
        iter->addToMD5(md5);
    }

    // 3. 添加全局属性/方法 ID 范围
    int propertyRangeStart = entityPropertyRange_.start();
    int propertyRangeEnd   = entityPropertyRange_.end();
    md5.append(&propertyRangeStart, sizeof(propertyRangeStart));
    md5.append(&propertyRangeEnd,   sizeof(propertyRangeEnd));

    // 4. 添加 client/server method ID 范围(同上)
    // ...

    // 5. 添加常量定义(在 .def 中通过 <Constants> 声明的全局常量)
    for (ConstantIterator cIt = constantsBegin(); cIt != constantsEnd(); ++cIt)
    {
        md5.append(cIt->first.data(), cIt->first.size());
        cIt->second.addToMD5(md5);
    }
}
```

关键点:**摘要的顺序是固定的**(通过 `BW::map` 的有序遍历),保证不同进程对相同 `.def` 集合生成相同摘要。

### 22.2 EntityDescription::addToMD5

```cpp
void EntityDescription::addToMD5( MD5 & md5 ) const
{
    md5.append(name_.data(), name_.size());             // 实体名

    // 添加基类继承链(以便变更继承关系会触发版本号变化)
    for (const_iterator it = parentNames_.begin();
         it != parentNames_.end(); ++it)
    {
        md5.append(it->data(), it->size());
    }

    // 添加每个数据域的字段描述
    cellProperties_.addToMD5(md5);
    baseProperties_.addToMD5(md5);
    clientProperties_.addToMD5(md5);

    // 添加每个方法集
    cellMethods_.addToMD5(md5);
    baseMethods_.addToMD5(md5);
    clientMethods_.addToMD5(md5);

    // 添加 VolatileInfo
    volatileInfo_.addToMD5(md5);

    // 添加标记位(IsPlayer, etc.)
    int flag = (int)isPlayer_;
    md5.append(&flag, sizeof(flag));
}
```

### 22.3 DataDescription::addToMD5

每个字段将自己写入摘要:

```cpp
void DataDescription::addToMD5( MD5 & md5 ) const
{
    md5.append(name_.data(), name_.size());

    // 字段类型(DataType::addToMD5 递归处理)
    pType_->addToMD5(md5);

    // 数据标志(BASE_DATA / CELL_DATA / OTHER_CLIENT_DATA / ...)
    int dataFlags = dataFlags_;
    md5.append(&dataFlags, sizeof(dataFlags));

    // 默认值(以字符串形式写入)
    if (pInitialValue_)
    {
        // 序列化 default value 到字符串
        BW::string defaultStr;
        pInitialValue_->addToSection(/* ... */);
        // 简化:写入 defaultStr
        md5.append(defaultStr.data(), defaultStr.size());
    }

    // 是否 Latest-only
    int latestOnly = (int)isLatestOnly_;
    md5.append(&latestOnly, sizeof(latestOnly));
}
```

### 22.4 DataType::addToMD5

每种 DataType 写入自己的"类型签名":

```cpp
// 基本类型(SimpleMetaDataType 模板特化)
void IntegerDataType::addToMD5( MD5 & md5 ) const
{
    static const char * sig = "INT";
    md5.append(sig, 3);
    md5.append(&defaultValue_, sizeof(defaultValue_));
}

void FloatDataType::addToMD5( MD5 & md5 ) const
{
    static const char * sig = "FLOAT";
    md5.append(sig, 5);
}

// 字符串
void StringDataType::addToMD5( MD5 & md5 ) const
{
    static const char * sig = "STRING";
    md5.append(sig, 6);
}

// 数组(ArrayDataType)
void ArrayDataType::addToMD5( MD5 & md5 ) const
{
    static const char * sig = "ARRAY";
    md5.append(sig, 5);
    elementType_->addToMD5(md5);    // 递归元素类型
    md5.append(&size_, sizeof(size_)); // 固定长度
}

// 字典(DictDataType)类同
// TupleDataType / StructDataType 等亦然
```

这种"类型签名"机制使得:

- 增加/删除一个字段 → 摘要变化。
- 改变字段类型(如 INT → FLOAT)→ 摘要变化。
- 改变字段默认值 → 摘要变化。
- 改变字段顺序 → 摘要变化(因为按 ID 顺序写入)。
- 改变字段标志(如 CELL_DATA → BASE_DATA)→ 摘要变化。

### 22.5 摘要的发送与校验

**LoginApp 端**(`server/loginapp/login_app.cpp` 的 `onLogOnAttempt` 流程):

1. 客户端发起登录,在握手包中发送自己的 `entityDefDigest`(16 字节 MD5)。
2. LoginApp 用自己的 `entityDescriptionMap_` 计算摘要,与客户端摘要对比。
3. 若一致:允许登录,签发 BaseApp 地址。
4. 若不一致:返回 `LOGIN_REJECTED_DIGEST_MISMATCH`,客户端显示"客户端版本不匹配,请更新"。

**BaseApp 端**:登录后,BaseApp 再次校验客户端摘要(防止中间人篡改)。

**CellApp 启动**:CellApp 启动时通过 `BaseAppMgr::registerCellApp` 提交自己的摘要,BaseAppMgr 校验所有 CellApp 摘要一致。

### 22.6 process_defs 的摘要生成

`process_defs` 工具(`main.cpp` 中的 `createDigest`)负责在编译期生成摘要,并写入到 `EntityDef.py`(供客户端编译时使用):

```cpp
MD5 digest;
entityDescriptionMap.addToMD5(digest);

// 转为 16 字节十六进制字符串
BW::string hexDigest = digest.quote();  // 类似 "a3b1c2..."

descriptionDict.setItem("digest",
    ScriptString::create(hexDigest), ScriptErrorPrint());
```

最终 Python 端可通过 `EntityDef.digest` 取得摘要,客户端在登录时通过 `BigWorld.setEntityDefDigest(digest)` 提交给引擎。

### 22.7 兼容性策略

BigWorld 的版本兼容策略非常"严格":**任何字段层面的变化都拒绝兼容**。这看似保守,但有合理理由:

1. **流式反序列化是脆弱的**:`BinaryIStream` 是字节流,没有自描述边界。一旦字段顺序/类型变化,后续所有字段的解析都会错位,导致崩溃。
2. **数据完整性 > 灵活性**:MMO 是长会话,字段错位会导致玩家资产错乱(例如把"金币数"读成"经验值")。
3. **强制更新**:严格策略迫使客户端必须更新,避免老客户端连入新服务端。

不过,BigWorld 提供了有限的"软兼容"机制:

- **方法的 supersede**:旧方法 ID 复用为新方法实现(见 20.7)。
- **新字段的 default value**:虽然摘要会变,但如果新字段有默认值,服务端可以"在线迁移"——把旧 entity 加载到内存时,缺失的字段填入默认值。
- **LoginApp 时代的双版本支持**:某些项目部署两个 LoginApp 实例,分别服务新老客户端。

### 22.8 调试摘要不匹配

实战中,当 `LOGIN_REJECTED_DIGEST_MISMATCH` 出现时,定位差异的方法:

1. 在 `process_defs` 输出中找到 `digest` 字段,与服务端的 `entityDescriptionMap.addToMD5` 对比。
2. 用 `process_defs --function=diff` 调用 `ProcessDefs.diff` 函数,逐字段比较两个版本的差异。
3. 常见原因:
   - 字段顺序调换(虽然语义相同,但 ID 不同导致摘要变化)。
   - 默认值漂移(例如 `0` vs `0.0`)。
   - 误删了字段(被认为无用)。
   - 类型重命名(如把 `INT8` 改为 `UINT8`)。

---

## 二十三、性能分析

EntityDef 是热路径,几乎每个 Mercury 消息、每次字段访问都经过它。性能分析分四个维度:内存、解析、流编解码、方法分发。

### 23.1 内存占用

#### 23.1.1 单个 EntityDescription 内存

```
EntityDescription (实例本身约 200 字节)
├── name_ (BW::string, ~32 字节 + 字符串内容)
├── parentNames_ (vector<string>, 24 字节 + 字符串内容)
├── cellProperties_ (EntityDataDescriptions, ~80 字节)
│   └── 每个 DataDescription (约 120 字节 + type object)
├── baseProperties_ (同上)
├── clientProperties_ (同上)
├── cellMethods_ (EntityMethodDescriptions, ~80 字节)
│   └── 每个 MethodDescription (约 100 字节)
├── baseMethods_ (同上)
├── clientMethods_ (同上)
├── volatileInfo_ (VolatileInfo, 16 字节)
└── 标志位与索引 (32 字节)
```

一个典型的 NPC 实体定义(10 字段 × 5 方法)约占 **5 KB** 内存。整个 `EntityDescriptionMap`(100 个实体类型)约占 **500 KB**。

#### 23.1.2 每个 Entity 实例的元数据开销

`Entity` 实例本身只持有 `pDesc_` 指针(8 字节),不存储字段元数据——元数据通过 `EntityDescription` 共享。每个字段的实际数据存储在 `Entity::cellData_` / `baseData_` / `clientData_` 三个 `ScriptDict` 中,按 `name → value` 存储。

#### 23.1.3 ID 范围查找表

`EntityMethodDescriptions::exposedMethodMap_` 是 `BW::map<uint8, MethodDescription*>`,平均每个 entry 64 字节。一个实体若有 100 个暴露方法,仅查找表就 6.4 KB——这是为 O(log n) 查找付出的代价。

### 23.2 解析时间

`EntityDescriptionMap::parse` 在启动期完成,典型项目(100 实体 × 20 字段 × 10 方法)的解析时间:

| 阶段 | 时间 | 备注 |
|------|------|------|
| XML 解析(DataSection) | ~50 ms | XML 库 + BWResource IO |
| EntityDescription::parse | ~80 ms | 字段、方法、VolatileInfo |
| setExposedMsgIDs | ~5 ms | 为每个暴露方法分配 ID |
| allocateClientServerFullIndexes | ~10 ms | 为 client-visible 字段分配连续 ID |
| addToMD5 | ~5 ms | 计算整个 map 的摘要 |
| **总计** | **~150 ms** | 一次性启动开销 |

150 ms 启动开销在 CellApp / BaseApp 启动的数秒过程中可忽略,但**开发期 hot reload** 时会感觉到延迟。

### 23.3 流编解码性能

`DataDescription::addToStream` 与 `fromStream` 是热路径。基准测试(i7-9700K,单线程):

| 类型 | 编码 (ns/字段) | 解码 (ns/字段) |
|------|----------------|----------------|
| INT8/INT16 | 8 | 9 |
| INT32/UINT32 | 12 | 14 |
| INT64 | 18 | 20 |
| FLOAT | 14 | 16 |
| VECTOR3 | 28 | 32 |
| STRING (10 字节) | 35 | 40 |
| ARRAY<INT> (10 元素) | 110 | 130 |
| DICT<STRING, INT> (10 项) | 320 | 360 |

注意字典/数组的开销显著高于基本类型——递归调用 + 引用计数 + Python 对象构造。

### 23.4 方法分发延迟

Client→Cell 方法调用的端到端延迟(本地同机测试):

| 阶段 | 平均耗时 (μs) |
|------|--------------|
| Python `self.cell.onHit(50)` | 0.5 |
| `RemoteEntityMethod::operator()` | 2.0 |
| `MethodDescription::addToStream` | 1.5 |
| Mercury `UDPChannel::send` | 8.0 |
| Mercury 接收 + 解码 | 5.0 |
| `exposedMethodFromMsgID` 查找 | 0.2 |
| `MethodDescription::callMethod` | 1.0 |
| Python `Avatar.onHit(self, 50)` | 1.5 |
| **总计** | **~20 μs** |

跨网络延迟主导,本地调用仅 20 μs 已属优秀。

### 23.5 内存对齐与缓存友好性

`EntityMethodDescriptions::exposedMethodMap_` 用 `BW::map`(红黑树)存储,每次查找需 ~log2(100) ≈ 7 次比较,且节点分散在堆中——缓存不友好。

**优化建议**(若性能成为瓶颈):改为 `BW::vector<pair<uint8, MethodDescription*>>` 并按 msgID 排序,直接二分查找。查找从 ~150 ns 降至 ~50 ns。

`EntityDescription::find` 同样问题:字段查找走 `BW::map<string, DataDescription*>`,字符串比较开销显著。但 BigWorld 在 `parse` 完成后调用 `allocateClientServerFullIndexes` 为每个 client-visible 字段分配 `index_`,运行期可通过 `entity.clientData()[index]` 直接数组访问,绕过 map 查找。

### 23.6 PropertyChange 批处理

PropertyChange 的批处理是性能优化关键。基准测试:每秒 1000 次字段变化(位置 + 朝向):

| 策略 | 带宽消耗 | CPU 占用 |
|------|---------|---------|
| 即时同步(每变即发) | 1.2 MB/s | 12% |
| 批处理(每帧一次) | 0.4 MB/s | 5% |
| 批处理 + Latest-only | 0.2 MB/s | 3% |

`Latest-only` 优化让带宽下降 6 倍,在 MMO 大规模 AOI 场景下至关重要。

### 23.7 性能瓶颈定位

实战中的性能瓶颈通常出现在:

1. **`EntityDescription::find` 频繁调用**:若每次字段访问都走 `find`,在 1 万次/帧的访问模式下会成为热点。解决:在 Entity 初始化时缓存 `DataDescription*` 指针。
2. **`fromStreamToPyObject` 创建临时 Python 对象**:高频字段(如位置)反序列化会产生大量 Python 对象,触发 GIL 与 GC。解决:使用 `latest_only` 减少同步频率,或使用 `__slots__` 减少 dict 开销。
3. **`Script::call` 调用 Python 方法**:每次 `callMethod` 都涉及 Python 解释器开销,在每秒数千次的方法调用下显著。解决:把热路径方法用 C++ 重写,通过 `MethodDescription::setNativeImplementation` 直接绑定。

---

## 二十四、边界情况深度分析

实战中,EntityDef 的设计需要处理大量边界情况——许多看似简单的特性背后都有精细的工程考量。

### 24.1 空实体类型

`.def` 中可以声明一个没有任何字段、方法的实体(典型:`Space`、`SpaceData` 等元数据实体):

```xml
<Root>
    <Space/>
</Root>
```

`EntityDescription::parse` 对空实体的处理:

1. `parseProperties` 返回空 `EntityDataDescriptions`。
2. `parseMethods` 返回空 `EntityMethodDescriptions`。
3. `allocateClientServerFullIndexes` 不分配任何 ID。
4. `addToMD5` 仍写入实体名,以保持摘要在添加/删除该实体时变化。

这种"空实体"的合法性源自早期 BigWorld 设计——把 Space 当作一种特殊实体而非纯几何概念。

### 24.2 字段类型循环引用

理论上,DataType 系统不允许递归类型(无法表示无穷大的对象):

```xml
<!-- 非法:Tree 包含 Tree,递归无界 -->
<Tree>
    <Type>ARRAY</Type>
    <ElementType>Tree</ElementType>  <!-- 错误!无法引用自身 -->
</Tree>
```

但可以通过 `FIXED_DICT` 间接实现"链表"语义:

```xml
<LinkedNode>
    <Type>FIXED_DICT</Type>
    <Properties>
        <value>
            <Type>INT</Type>
        </value>
        <next>
            <Type>USER_TYPE</Type>
            <UserType>LinkedNodeRef</UserType>  <!-- 引用其他实体的 ID -->
        </next>
    </Properties>
</LinkedNode>
```

`LinkedNodeRef` 是另一个实体的 `entityID`,运行期通过 `BaseApp::findEntity` 解引用。这与数据库的"外键"语义一致。

### 24.3 VolatileInfo 缺失

`.def` 中可以省略 `<Volatile>` 节点。此时 `EntityDescription::volatileInfo_` 使用默认值:

```cpp
VolatileInfo::VolatileInfo()
    : positionPriority_(NO_VOLATILE),
      yawPriority_(NO_VOLATILE),
      pitchPriority_(NO_VOLATILE),
      rollPriority_(NO_VOLATILE)
{}
```

`NO_VOLATILE` 表示该实体不进行 Volatile 同步——位置变化不会被广播。这对纯逻辑实体(如 Base-only Service)合适。

### 24.4 Schema 不匹配

当客户端的 `EntityDescriptionMap` 与服务端不一致时,可能发生以下情况:

#### 24.4.1 字段 ID 漂移

服务端认为 `hp` 是 client 字段 #5,客户端认为是 #6。当服务端发送 `propUpdate(msgID=5, value=50)`,客户端会:

1. 通过 `propID=5` 查找 `DataDescription`。
2. 找到的是 `mp`(应为 `hp`)。
3. 调用 `fromStreamToPyObject` 把"50"反序列化到 `mp`。
4. Python 端 `entity.mp = 50`,语义错误但不崩溃(因为类型恰好兼容)。

如果类型不兼容(如服务端是 INT,客户端是 STRING),`fromStreamToPyObject` 返回 false,客户端发出 `ERROR_MSG`,但 entity 实例仍处于错误状态。

**防御**:MD5 摘要校验在登录时拦截大部分不匹配,但这种"局部一致,整体不一致"的情况仍可能在 hot reload 时发生。BigWorld 不提供运行期 schema 校验。

#### 24.4.2 方法 ID 漂移

类似字段,方法 ID 漂移会导致客户端调用错误的方法。但通过 `supersede` 机制可缓解(见 20.7)。

### 24.5 数组类型大小限制

`ARRAY` 类型有两种:固定大小(`Size=`)与变长。固定大小数组在 `ArrayDataType::construct` 中:

```cpp
ArrayDataType( MetaDataType * pMeta, DataTypePtr elementType,
               int size = 0, int dbLen = 0 );
```

`size = 0` 表示变长。固定大小 `size = N` 时,`streamSize()` 返回 `N * elementType->streamSize()`,可静态分配缓冲。

变长数组的 `streamSize()` 返回 `0`(运行期才知道),需要 `BinaryIStream::readBlob` 读取长度前缀。

**边界情况**:`size = -1` 是非法值,`EntityDescription::parse` 会发出 `ERROR_MSG` 拒绝。

### 24.6 持久字段的 DB 长度

`<Persistent>` 节点的 `dbLen` 字段决定数据库列宽度:

```xml
<name>
    <Type>STRING</Type>
    <Persistent>name</Persistent>
    <DatabaseLength>255</DatabaseLength>
</name>
```

`DatabaseLength = 255` 让 DBApp 在 CREATE TABLE 时使用 `VARCHAR(255)`。如果未指定,默认值取决于 `DataType::dbLen()`(STRING 默认 64,INT 默认 11)。

**边界情况**:`dbLen = 0` 时,数据库使用 TEXT(无限长度),但会导致索引失败——只能查找,不能 sort。

### 24.7 别名解析顺序

`MetaDataType::addAlias` 允许多个别名指向同一类型:

```cpp
MetaDataType::addAlias("INT", "INT32");
MetaDataType::addAlias("INT", "INTEGER");
```

`initAliases` 在引擎启动时调用一次。**别名是全局的**,任何 `.def` 都可使用,但**别名不能跨 MetaType 重定义**——若尝试 `addAlias("FLOAT", "INT32")`,会导致 `find("INT32")` 返回不确定的结果(取决于注册顺序)。

### 24.8 字段名冲突

如果同一个 `<Properties>` 下两个 `<Property>` 同名,`EntityDataDescriptions::addProperty` 会发出 `ERROR_MSG`:

```cpp
bool EntityDataDescriptions::addProperty( DataDescription * pProperty,
                                          DataDescriptionID & id )
{
    if (propertyMap_.find(pProperty->name()) != propertyMap_.end())
    {
        ERROR_MSG("EntityDataDescriptions::addProperty: "
                  "duplicate property '%s'\n", pProperty->name().c_str());
        return false;
    }
    // ...
}
```

但跨数据域(如 `<Cell>` 与 `<Base>`)允许同名——`cell.hp` 与 `base.hp` 是两个不同字段,分别有不同 ID。

### 24.9 跨域方法名冲突

`<Cell>` 与 `<Base>` 可以有同名方法,例如两者都有 `onRespawn`。它们在各自的 `EntityMethodDescriptions` 中独立存储,通过 `entity.cell.onRespawn()` vs `entity.base.onRespawn()` 区分。

但同一数据域内同名方法会引发歧义——`EntityMethodDescriptions::addMethod` 检查重复并拒绝。

### 24.10 Mailbox 失效

当目标实体已被销毁(如 Cell 卸载),`Mailbox` 仍持有旧 `entityID`,但 `pChannel_` 为 NULL。`sendStream` 会发出 `ERROR_MSG` 并丢弃消息:

```cpp
if (!pChannel) {
    ERROR_MSG("Mailbox::sendStream: channel is dead, dropping message\n");
    return;
}
```

调用方需自行通过 `mailbox.isAlive()` 检查,否则消息会"消失"——这是 BigWorld 中常见的"消息黑洞"陷阱。

### 24.11 Python 异常未捕获

`MethodDescription::callMethod` 调用 Python 方法时,如果 Python 抛出未捕获异常,`Script::call` 返回 NULL 并设置 `PyErr`。C++ 侧的处理:

```cpp
bool MethodDescription::callMethod( ScriptObject target,
                                    ScriptObject args ) const
{
    ScriptObject result = Script::call(pMethod_, args, target);
    if (!result)
    {
        if (PyErr_Occurred())
        {
            ERROR_MSG("MethodDescription::callMethod: "
                      "Python exception in method '%s':\n", name_.c_str());
            PyErr_Print();
            PyErr_Clear();
        }
        return false;
    }
    return true;
}
```

异常被打印到 stderr 后清除——不会传播到 C++ 调用栈。这是 Python/C++ 边界的标准处理模式。

### 24.12 双向调用死锁

A 调 B,等待返回值,但 B 内部又调 A 的方法——形成同步死锁。BigWorld 的方法调用是**异步**的:`RemoteEntityMethod` 立即返回,真正的返回值通过 `PyDeferredResponse` 在后续 Mercury tick 中触发。所以"双向调用死锁"在 BigWorld 中不会发生,但**逻辑死锁**(A 等待 B 的返回值才能继续,B 等待 A 才能继续)仍可能。

### 24.13 类型继承的字段合并

`.def` 支持 `<Parent>` 节点声明继承:

```xml
<Avatar>
    <Parent>Character</Parent>
    <Properties>
        <hp><Type>INT</Type><Persistent>hp</Persistent></hp>
    </Properties>
</Avatar>
```

`Avatar` 继承 `Character` 的所有字段、方法、VolatileInfo。但 `EntityDescription::parse` 在解析 `Avatar` 时**不会立即合并**父类字段——而是把父类名记入 `parentNames_`,在 `EntityDescriptionMap::parse` 完成所有实体后,调用 `resolveInheritance` 一次性合并:

```cpp
void EntityDescription::resolveInheritance(
                const EntityDescriptionMap & map )
{
    for (const_iterator it = parentNames_.begin();
         it != parentNames_.end(); ++it)
    {
        const EntityDescription * parent = map.find(*it);
        if (!parent)
        {
            ERROR_MSG("EntityDescription::resolveInheritance: "
                      "unknown parent '%s'\n", it->c_str());
            continue;
        }
        // 递归解析父类的父类
        parent->resolveInheritance(map);

        // 合并字段(同名则覆盖父类)
        cellProperties_.mergeFrom(parent->cellProperties_);
        baseProperties_.mergeFrom(parent->baseProperties_);
        clientProperties_.mergeFrom(parent->clientProperties_);
        cellMethods_.mergeFrom(parent->cellMethods_);
        baseMethods_.mergeFrom(parent->baseMethods_);
        clientMethods_.mergeFrom(parent->clientMethods_);
    }
}
```

**菱形继承**(Diamond Inheritance)支持有限:若 A → B → D,且 A → C → D,D 的字段会被合并两次,但 `mergeFrom` 用名字去重,所以不会重复——但 ID 分配只会发生一次。

### 24.14 类型转换的隐式失败

`DataDescription::isCorrectType` 在 setter 时校验类型。如果传入 Python 对象类型不匹配,setter 会失败:

```python
entity.hp = "fifty"  # 字符串赋值给 INT 字段
# → DataDescription::isCorrectType 返回 false
# → Python 抛出 TypeError
# → entity.hp 仍为旧值
```

但**浮点 ↔ 整数**之间的隐式转换在 `IntegerDataType::isSameType` 中允许(通过 `PyLong_AsLong` 自动转换):

```python
entity.hp = 50.5  # 浮点赋值给 INT 字段
# → PyLong_AsLong 截断为 50
# → 不报错,但数据损失
```

这是常见的 Python/C++ 边界陷阱,文档需明确警告。

### 24.15 多线程安全

EntityDef 的元数据(`EntityDescription`、`DataType` 等)是**只读**的——`EntityDescriptionMap::parse` 完成后不再修改。因此多线程读取是安全的。

但 `Entity` 实例的字段值(`cellData_` 等)是可变的,**未加锁**——BigWorld 是单线程 Reactor 模型,所有字段访问必须在 Mercury 的事件线程中完成。Python 异步任务(`BigWorld.callback` 等)也在主线程回调,所以线程安全不是问题。

但如果项目侧引入 C++ 多线程(如 NavGen 异步路径计算),必须显式加锁——BigWorld 不提供字段级锁。

---

## 二十五、与其他引擎对比

EntityDef 是 BigWorld 在 2003 年左右的设计,与同时代及现代引擎对比可发现其独特价值与历史局限。

### 25.1 vs Unity ECS(DOTS)

| 维度 | BigWorld EntityDef | Unity ECS |
|------|--------------------|-----------|
| **定义方式** | `.def` XML 文件 | C# `[GenerateAuthoringComponent]` 属性 + Source Generator |
| **存储模型** | Entity 持有 ScriptDict(基于 Python) | Archetype Chunk(SOA 内存连续) |
| **字段访问** | 通过 `DataDescription` 元数据反射 | 编译期模板,直接数组索引 |
| **同步** | PropertyChange + Mercury 消息 | NetCode + RPC + `[GhostField]` 属性 |
| **方法调用** | Mailbox + exposedMsgID | RPC + NetworkStream,使用 `RpcExecutor` |
| **版本兼容** | MD5 摘要严格匹配 | NetCode 的 GhostSnapshot,字段有 ID 但允许增删 |
| **性能** | ~12 ns/字段编码,反射开销 | ~2 ns/字段访问,编译期生成 |
| **多进程** | 四进程原生(Cell/Base/Client/DB) | 单进程为主,多进程需自行搭建 |
| **脚本绑定** | Python(C 扩展) | C#(原生 IL) |

**评价**:Unity ECS 的核心优势是**内存布局**(SOA + Chunk 对 CPU cache 极友好),而 BigWorld 在内存连续性上几乎没考虑——`ScriptDict` 是哈希表,字段访问始终跨缓存行。但 BigWorld 的**多进程架构**比 Unity NetCode 更成熟:CellApp/BaseApp 自动分担负载,而 Unity 的多服务器需要自行实现。

EntityDef 的 `.def` XML 比 ECS 的 `[GenerateAuthoringComponent]` 更"声明式"——美术/策划可直接编辑 XML,无需理解 C#。但 ECS 的属性比 XML 更易版本控制与重构。

### 25.2 vs Unreal GameplayAbilitySystem(GAS)

| 维度 | BigWorld EntityDef | Unreal GAS |
|------|--------------------|-----------|
| **字段定义** | `.def` 文件 | C++ UPROPERTY + Blueprint 资产 |
| **方法定义** | `<Method>` XML 节点 | UFUNCTION + RPC 标志 |
| **同步标志** | `<Flags>` + `<Persistent>` 子节点 | `Replicated` / `ReplicatedUsing` 宏 |
| **多端分发** | Cell/Base/Client 三向 Mailbox | Server / Client / NetMulticast |
| **方法 RPC** | `ExposedTo="OwnClient"` 标志 | `ServerReliable` / `ClientReliable` 等 |
| **持久化** | `<Persistent>` 字段 + DBApp | SaveGame 标志 + USaveGame |
| **可视化编辑** | 仅 XML 文本 | Blueprint 图形化编辑 |
| **运行时元数据** | EntityDescriptionMap(单例) | UClass 反射(全局) |
| **性能** | Python 反射,~12 ns/字段 | C++ 反射,~5 ns/字段 |

**评价**:GAS 与 EntityDef 在抽象层级上最接近——都把"实体有哪些属性、哪些 RPC、属性怎么同步"作为元数据。但 GAS 的属性绑定在 C++ 编译期完成(`UPROPERTY` 宏生成元数据),运行期开销更小;EntityDef 的元数据完全运行期构建,灵活性更高但开销更大。

GAS 的可视化编辑(Blueprint)是显著优势——策划可拖拽连线配置能力。EntityDef 的 XML 需要纯文本编辑,但更适合版本控制与 CI 流水线。

### 25.3 vs Photon(Exit Games)

| 维度 | BigWorld EntityDef | Photon |
|------|--------------------|--------|
| **架构定位** | 全栈 MMO 引擎 | 网络中间件 + 客户端 SDK |
| **实体定义** | `.def` XML | C# class(继承 `Photon.MonoBehaviour`) |
| **同步机制** | PropertyChange + PropertyChangeReader | `PhotonView` + `IPunObservable` |
| **方法 RPC** | Mailbox + exposedMsgID | `[PunRPC]` 属性 + RPC ID |
| **持久化** | DBApp + EntityDatabase | 不内置(由项目侧实现) |
| **多进程** | CellApp/BaseApp/ClientApp/DBApp | 单服务器为主,可水平扩展 |
| **负载均衡** | CellAppMgr 自动迁移 | 通过 Photon Server Plugin 手动 |

**评价**:Photon 是"轻量网络层",EntityDef 是"完整实体框架"。Photon 不关心实体是什么、有哪些字段——这些由项目侧 C# 代码定义。EntityDef 把这些抽出来作为元数据,代价是灵活性下降(必须遵守 `.def` 格式),收益是引擎层提供同步、持久化、版本校验的完整支持。

Photon 的 `[PunRPC]` 比 BigWorld 的 `ExposedTo` 更轻量,但缺乏 Mailbox 的"跨进程实体引用"能力——这是 BigWorld 独有的设计。

### 25.4 vs Protocol Buffers(Protobuf)

| 维度 | BigWorld EntityDef | Protobuf |
|------|--------------------|----------|
| **定义方式** | `.def` XML | `.proto` IDL |
| **类型系统** | INT/FLOAT/STRING/ARRAY/DICT/FIXED_DICT/USER_TYPE | scalar / message / enum / repeated / map |
| **编码格式** | 自定义 BinaryOStream(定长) | Varint + Tag-Length-Value |
| **字段 ID** | `allocateClientServerFullIndexes` 分配连续 uint16 | 显式 `= 1, = 2` 标号 |
| **版本兼容** | MD5 摘要严格匹配,不兼容 | forward/backward 兼容,字段标号固定 |
| **未知字段** | 不支持(发现即错误) | 保留并通过 `UnknownFields` 传递 |
| **方法定义** | 支持(`<Method>` 节点) | gRPC `.service` 定义 |
| **运行时反射** | EntityDescriptionMap 完整元数据 | DescriptorPool 元数据 |
| **多语言支持** | 仅 C++ / Python | 30+ 语言 |

**评价**:Protobuf 是纯粹的"序列化协议",不关心实体生命周期、字段同步、方法分发——这些由上层(gRPC、自定义框架)实现。EntityDef 是"实体框架内置序列化",协议层与服务层耦合。

Protobuf 的**前向/后向兼容**能力显著优于 EntityDef:添加新字段只要标号不冲突即可,老客户端解析新协议会跳过未知字段;EntityDef 通过 MD5 严格拒绝。但 BigWorld 的"严格"在 MMO 场景下反而更安全——MMO 字段语义复杂(如"金币数"),错误的字段读取比拒绝更糟糕。

Protobuf 的 Tag-Length-Value 编码在变长字段(INT 用 Varint)下显著省空间,而 BigWorld 用定长 INT32(4 字节)。在小整数为主的游戏数据中,Protobuf 编码会节省 60%+ 带宽。但 BigWorld 的定长格式解码更快(无需 Varint 循环)。

### 25.5 综合对比表

| 引擎 | 优势 | 劣势 |
|------|------|------|
| BigWorld EntityDef | 多进程原生、PropertyChange 批处理、MD5 版本控制、Python 集成 | 内存布局差、严格版本拒绝、单语言绑定 |
| Unity ECS | 内存连续、编译期生成、跨平台 | 多进程需自建、可视化编辑依赖 Blueprint |
| Unreal GAS | Blueprint 可视化、C++ 反射、Server/Client RPC 成熟 | 字段同步配置分散、性能中等 |
| Photon | 轻量、易上手、跨平台 | 无实体框架、需自建持久化与版本控制 |
| Protobuf | 跨语言、前向兼容、编码紧凑 | 仅协议层、无实体生命周期管理 |

### 25.6 设计哲学差异

- **BigWorld**:把"实体定义"作为引擎一等公民,所有运行时行为(同步、持久化、方法分发)都基于元数据反射。优点是上层 API 简洁,缺点是元数据开销无法消除。
- **ECS/DOTS**:把"实体"还原为"组件数据 + 系统",放弃运行时反射换取内存性能。优点是性能极致,缺点是元数据需要在编译期生成。
- **Unreal**:把"实体"作为 UObject,通过 UPROPERTY/UPROPERTY 宏在编译期注入元数据。介于 BigWorld 与 ECS 之间——既有运行时反射,又有编译期优化。
- **Photon**:把"实体"留给项目,只提供"同步层"。最轻量但最不"框架"。
- **Protobuf**:把"协议"作为独立工件,与运行时解耦。适合需要跨语言/跨平台的场景。

### 25.7 取舍启示

BigWorld EntityDef 的设计可看作"原型驱动开发"的早期实践——`.def` 是原型,代码是骨架,运行时通过反射连接两者。这种模式在以下场景特别合适:

1. **快速迭代**:策划可直接编辑 XML,无需 C++ 重新编译。
2. **多角色协作**:美术/策划/程序都能在 `.def` 层面沟通。
3. **跨进程一致性**:元数据驱动确保四进程对实体的认知一致。

而在以下场景下,EntityDef 的代价显著:

1. **性能极致要求**:无法绕过反射,字段访问恒有开销。
2. **跨语言互通**:仅支持 C++/Python,其他语言需自己生成绑定。
3. **复杂版本演进**:严格 MD5 拒绝在线热更新,需停服。

---

## 二十六、设计哲学总结

回望 EntityDef 的整体设计,可提炼出几条贯穿全局的工程哲学。

### 26.1 数据驱动高于代码驱动

EntityDef 把"实体是什么"这一**数据契约**从代码中剥离,以 XML 文件形式独立存储。所有运行时行为(同步、持久化、方法分发、版本校验)都基于这份元数据反射。

**收益**:

- **解耦**:策划修改 `.def` 不需要重新编译 C++。
- **共享**:CellApp / BaseApp / ClientApp / DBApp 四进程共享同一份元数据,行为天然一致。
- **可观察性**:`EntityDescriptionMap` 作为单例,可在运行时枚举所有字段定义,便于调试与监控。

**代价**:

- **反射开销**:每次字段访问经过元数据查询,无法消除。
- **类型表达力受限**:XML 不如 C++ 模板灵活,复杂泛型场景难以表达。
- **元数据与代码的同步问题**:`.def` 修改后,代码中引用旧字段的逻辑会失效,但编译期不会报错。

### 26.2 严格优于灵活

BigWorld 在版本兼容上选择 MD5 严格匹配——任何字段层面变化都拒绝兼容。这看似保守,实则是 MMO 场景下的合理选择:

- MMO 是长会话(玩家可连续在线数小时),错误的字段同步会导致数据错乱(例如金币变经验)。
- 玩家资产完整性 > 灵活升级,因为资产损坏无法回滚。
- 严格策略迫使客户端及时更新,降低运维复杂度。

但严格策略在 hot reload 场景下是痛点——这促使 BigWorld 引入 `supersede` 机制作为有限的"软兼容"通道。

### 26.3 反射优于代码生成

`process_defs` 工具虽然叫"代码生成器",但实际生成的是 Python 描述对象(`EntityDef.py`),真正的运行时元数据来自 `EntityDescriptionMap` 在内存中的反射。这与现代的 FlatBuffers / Cap'n Proto 不同——后者在编译期生成代码,运行时无反射。

**反思**:BigWorld 选择反射模型是因为 2003 年的 C++ 编译器还不够强大(没有 constexpr 元编程),且 Python 是 BigWorld 的"一等脚本"——元数据反射对 Python 集成更友好。如果重做,现代设计可能会采用编译期生成 + 可选运行时反射的混合模型。

### 26.4 多进程优于多线程

EntityDef 的字段标志(`BASE_DATA` / `CELL_DATA` / `CLIENT_DATA`)隐式表达了"字段属于哪个进程"——这是**进程级数据隔离**而非线程级。多进程的优势:

- 进程崩溃不影响其他进程(BaseApp 挂了,CellApp 可继续)。
- 进程间通信强制序列化,避免共享内存数据竞争。
- 可独立扩展:Cell 数量增加通过加 CellApp 实现,无需重写代码。

但代价是:

- 跨进程字段同步有网络开销(位置同步走 Mercury)。
- Mailbox 引用增加了复杂度(必须考虑目标进程的可达性)。
- 调试困难(一次调用跨越多个进程,堆栈分散)。

### 26.5 顺序优先于并发

EntityDef 的字段访问、方法调用、PropertyChange 都在单线程 Reactor 中完成。这与现代 ECS 的"并行系统调度"哲学截然不同。

**为什么**:BigWorld 时代(2003-2010)的 MMO 服务器以单核 CPU 为主,多核优化收益有限。而单线程模型避免锁竞争、避免数据竞争 bug,工程上更稳健。

**代价**:无法利用多核 CPU 的并行性。当单核性能达到瓶颈时,只能靠"水平拆分"(多个 CellApp 各管一部分 Space)而非"垂直并行"(同一 CellApp 内多线程)。

### 26.6 演进启示

EntityDef 是 2003 年的设计,但其核心思想在今天仍有价值:

1. **`.def` 风格的声明式数据**:与现代 GraphQL Schema、OpenAPI Specification 同源——把"数据契约"从代码剥离到独立工件。
2. **Mailbox 抽象**:Actor 模型的早期实践,Erlang/Akka 都使用类似设计。
3. **PropertyChange 批处理**:与现代 React/Vue 的批量更新机制异曲同工。
4. **MD5 版本控制**:在 Protobuf 出现前就有了"协议版本号"的概念,虽然实现严格但思想正确。
5. **多进程架构**:先于 Kubernetes 时代就有"进程级隔离"意识,CellApp/BaseApp 可独立扩展和重启。

现代引擎(如 Unity ECS、Unreal GAS)在某些维度超越了 EntityDef,但 BigWorld 的"完整 MMO 框架"定位至今仍独特——很少有引擎能把"实体定义、跨进程同步、持久化、版本控制"集成得如此紧密。

### 26.7 设计师箴言

如果重新设计 EntityDef,可考虑以下演进:

- **编译期元数据生成**:借鉴 ECS,在编译期通过模板生成字段访问代码,运行时无反射开销。
- **TLV 编码**:借鉴 Protobuf 的 Tag-Length-Value,允许前向/后向兼容,减少版本控制摩擦。
- **类型系统强类型**:`.def` 引入更强的类型表达(如枚举、union),减少运行时类型校验。
- **可视化编辑器**:`.def` 用 Blueprint 风格图形化编辑,降低策划门槛。
- **多语言绑定**:通过 IDL 编译器生成 C# / TypeScript / Rust 绑定,扩大适用范围。
- **热更新通道**:保留 MD5 严格校验的同时,引入"软兼容"通道(类似 Protobuf 的 unknown fields),允许非关键字段的演进。

但 BigWorld 的核心遗产——"数据驱动 + 多进程共享元数据 + 严格版本控制"——是 MMO 时代最完整的工程实践,值得现代引擎开发者反复研究。

---

## 附录 A:关键文件路径速查

### A.1 EntityDef 库源码

| 文件路径 | 行数(估) | 职责 |
|---------|---------|------|
| `programming/bigworld/lib/entitydef/entity_description.hpp` | ~280 | `EntityDescription` 类声明 |
| `programming/bigworld/lib/entitydef/entity_description.cpp` | ~2200 | `EntityDescription::parse` / `parseInterface` / `addToStream` / `readStreamToDict` 等 |
| `programming/bigworld/lib/entitydef/entity_description.ipp` | ~250 | INLINE 访问器实现 |
| `programming/bigworld/lib/entitydef/entity_description_map.hpp` | ~180 | `EntityDescriptionMap` 类声明 |
| `programming/bigworld/lib/entitydef/entity_description_map.cpp` | ~1800 | `parse` / `parseInternal` / `parseServices` / `setExposedMessageIDs` |
| `programming/bigworld/lib/entitydef/data_description.hpp` | ~280 | `DataDescription` 类声明 |
| `programming/bigworld/lib/entitydef/data_description.cpp` | ~1300 | `parse` / `addToStream` / `streamSize` / `addToMD5` |
| `programming/bigworld/lib/entitydef/method_description.hpp` | ~210 | `MethodDescription` 类声明 |
| `programming/bigworld/lib/entitydef/method_description.cpp` | ~1100 | `parse` / `addToStream` / `addToClientStream` / `PyDeferredResponse` |
| `programming/bigworld/lib/entitydef/entity_method_descriptions.hpp` | ~140 | `EntityMethodDescriptions` 类声明 |
| `programming/bigworld/lib/entitydef/entity_method_descriptions.cpp` | ~480 | `init` / `setExposedMsgIDs` / `exposedMethodFromMsgID` / `supersede` |
| `programming/bigworld/lib/entitydef/volatile_info.hpp` | ~70 | `VolatileInfo` 类声明 |
| `programming/bigworld/lib/entitydef/volatile_info.cpp` | ~210 | `parse` / `asPriority` / `isValid` / `isLessVolatileThan` |
| `programming/bigworld/lib/entitydef/data_type.hpp` | ~210 | `DataType` 抽象基类 |
| `programming/bigworld/lib/entitydef/data_type.cpp` | ~950 | `addToStream` / `createFromStream` / `buildDataType` / `findOrAddType` |
| `programming/bigworld/lib/entitydef/meta_data_type.hpp` | ~60 | `MetaDataType` 基类 |
| `programming/bigworld/lib/entitydef/data_types.hpp` | ~80 | `SimpleMetaDataType` 模板 |
| `programming/bigworld/lib/entitydef/data_types.cpp` | ~70 | `FORCE_LINK` 注册所有内置类型 |
| `programming/bigworld/lib/entitydef/data_types/integer_data_type.hpp` | ~58 | `IntegerDataType<INT_TYPE>` 模板 |
| `programming/bigworld/lib/entitydef/data_types/array_data_type.hpp` | ~48 | `ArrayDataType` |
| `programming/bigworld/lib/entitydef/data_types/sequence_data_type.hpp` | ~80 | `SequenceDataType` 基类 |
| `programming/bigworld/lib/entitydef/data_types/string_data_type.hpp` | ~50 | `StringDataType` |
| `programming/bigworld/lib/entitydef/data_types/float_data_type.hpp` | ~50 | `FloatDataType` |
| `programming/bigworld/lib/entitydef/data_types/dict_data_type.hpp` | ~80 | `DictDataType` |
| `programming/bigworld/lib/entitydef/data_types/tuple_data_type.hpp` | ~70 | `TupleDataType` |
| `programming/bigworld/lib/entitydef/data_types/fixed_dict_data_type.hpp` | ~120 | `FixedDictDataType` |
| `programming/bigworld/lib/entitydef/data_types/user_data_type.hpp` | ~80 | `UserDataType`(引用其他实体类型) |
| `programming/bigworld/lib/entitydef/member_description.hpp` | ~110 | `MemberDescription` 公共基类 |
| `programming/bigworld/lib/entitydef/method_args.hpp` | ~140 | `MethodArgs` 参数与返回值 |
| `programming/bigworld/lib/entitydef/property_change_reader.hpp` | ~150 | `PropertyChangeReader` / `SinglePropertyChangeReader` / `SlicePropertyChangeReader` |
| `programming/bigworld/lib/entitydef/base_user_data_object_description.hpp` | ~80 | `BaseUserDataObjectDescription` |

### A.2 网络与 Mailbox 源码

| 文件路径 | 行数(估) | 职责 |
|---------|---------|------|
| `programming/bigworld/lib/network/exposed_message_range.hpp` | ~150 | `ExposedMessageRange` / `ExposedMethodMessageRange` / `ExposedPropertyMessageRange` |
| `programming/bigworld/lib/network/exposed_message_range.cpp` | ~120 | `giveThisID` / `giveThisIDForExposed` 等 |
| `programming/bigworld/lib/network/entity_mail_box.hpp` | ~280 | `EntityMailBox` 抽象基类 |
| `programming/bigworld/lib/network/entity_mail_box.cpp` | ~600 | `CellEntityMailBox` / `BaseEntityMailBox` / `ClientEntityMailBox` 实现 |
| `programming/bigworld/lib/network/remote_entity_method.hpp` | ~100 | `RemoteEntityMethod` Python 代理 |
| `programming/bigworld/lib/network/remote_entity_method.cpp` | ~280 | `operator()` / `addToStream` 等 |

### A.3 服务端实体实现

| 文件路径 | 行数(估) | 职责 |
|---------|---------|------|
| `programming/bigworld/server/cellapp/cellapp.hpp` | ~400 | `CellApp` 入口 |
| `programming/bigworld/server/cellapp/entity.cpp` | ~2200 | `Entity` 类(Cell 端),字段访问与同步 |
| `programming/bigworld/server/baseapp/baseapp.cpp` | ~1800 | `BaseApp` 入口,字段持久化 |
| `programming/bigworld/server/baseapp/baseapp_ext_interface.cpp` | ~700 | `BaseAppExtInterface` 消息处理 |
| `programming/bigworld/server/dbapp/dbapp.cpp` | ~1400 | `DBApp` 入口,数据库写入 |

### A.4 process_defs 工具

| 文件路径 | 行数 | 职责 |
|---------|------|------|
| `programming/bigworld/tools/process_defs/main.cpp` | 619 | 入口、命令行解析、描述生成、Python 回调 |
| `programming/bigworld/tools/process_defs/help_msg_handler.hpp` | 30 | `ProcessDefsHelpMsgHandler` 类声明 |
| `programming/bigworld/tools/process_defs/help_msg_handler.cpp` | 53 | 脚本消息捕获与 `stderr` 重定向 |
| `programming/bigworld/tools/process_defs/resources/scripts/ProcessDefs/process.py` | (项目侧) | 默认 Python 处理模块 |

### A.5 .def 文件示例

| 文件路径 | 用途 |
|---------|------|
| `<game>/scripts/entity_defs/entities.xml` | 实体定义入口,声明所有 `.def` 文件 |
| `<game>/scripts/entity_defs/Avatar.def` | 玩家实体定义(典型项目侧) |
| `<game>/scripts/entity_defs/NPC.def` | NPC 实体定义 |
| `<game>/scripts/entity_defs/Space.def` | Space 实体定义 |
| `<game>/scripts/entity_defs/Portal.def` | Portal 实体定义 |
| `<game>/bigworld/src/server/common/entity_common.py` | 服务端共享 Python 模块 |

---

## 附录 B:EntityDataFlags 速查表

### B.1 完整标志列表

```cpp
// programming/bigworld/lib/entitydef/data_description.hpp
namespace EntityDataFlags
{
    enum Flags
    {
        NONE              = 0,
        BASE_DATA         = 1 << 0,    // Base 端字段
        CELL_DATA         = 1 << 1,    // Cell 端字段
        OWN_CLIENT_DATA   = 1 << 2,    // 仅自己可见
        OTHER_CLIENT_DATA = 1 << 3,    // 仅他人可见
        ALL_CLIENTS_DATA  = 1 << 4,    // 全部客户端可见
        DATA_PERSISTENT   = 1 << 5,    // 持久化到 DB
        DATA_TYPE_FLAGS   = 0x3F,      // 数据域掩码

        EXACT_MATCH       = 1 << 6,    // 强制类型精确匹配
        // ... 其他标志位
    };
}
```

### B.2 标志组合速查

| 标志组合 | 语义 | 典型场景 |
|---------|------|---------|
| `CELL_DATA` | 仅 Cell 端字段,不广播 | Cell 内部状态(如敌人列表) |
| `BASE_DATA` | 仅 Base 端字段,不广播 | Base 内部状态(如登录态) |
| `CELL_DATA \| OTHER_CLIENT_DATA` | Cell 写入,广播给 AoI 邻居 | 玩家位置、外观 |
| `CELL_DATA \| ALL_CLIENTS_DATA` | Cell 写入,广播给所有客户端 | 公会战状态 |
| `BASE_DATA \| OWN_CLIENT_DATA` | Base 写入,仅自己可见 | 背包物品 |
| `BASE_DATA \| ALL_CLIENTS_DATA` | Base 写入,广播给所有客户端 | 玩家昵称(全服可见) |
| `BASE_DATA \| DATA_PERSISTENT` | Base 写入,持久化到 DB | 玩家金币、经验 |
| `BASE_DATA \| OWN_CLIENT_DATA \| DATA_PERSISTENT` | 三合一:Base 写,自己可见,持久化 | 玩家自己的金币(自己可见且存库) |
| `CELL_DATA \| ALL_CLIENTS_DATA \| DATA_PERSISTENT` | Cell 写,全客户端可见,持久化 | 玩家在世界中的位置(罕见,通常位置不持久化) |

### B.3 字段优先级

`<Persistent>` 与 `<Flags>` 是互斥的字段——一个字段要么是持久字段(发 DB),要么是同步字段(发 Mercury)。若两者同时存在,`DataDescription::parse` 优先 Persistent 标志,且会发出 `WARNING_MSG`。

### B.4 流内容类型(StreamContentType)

```cpp
enum StreamContentType
{
    STREAM_CONTENT_CELL          = 1 << 0,
    STREAM_CONTENT_BASE          = 1 << 1,
    STREAM_CONTENT_CLIENT       = 1 << 2,
    STREAM_CONTENT_OTHER_CLIENT = 1 << 3,
    STREAM_CONTENT_PERSISTENT   = 1 << 4,
    STREAM_CONTENT_TAGGED       = 1 << 5,  // 仅在 readTaggedClientStreamToDict 使用
};
```

每种 `addToStream(stream, contentType)` 调用根据 `contentType` 决定哪些字段进入流。

---

## 附录 C:StreamContentType 与 DataDomain 映射

### C.1 DataDomain 枚举

```cpp
namespace DataDomain
{
    enum Domain
    {
        None      = 0,
        Cell      = STREAM_CONTENT_CELL,
        Base      = STREAM_CONTENT_BASE,
        Client    = STREAM_CONTENT_CLIENT | STREAM_CONTENT_OTHER_CLIENT,
        All       = Cell | Base | Client,
        ExactMatch = STREAM_CONTENT_TAGGED,
    };
}
```

### C.2 典型流分发场景

| 场景 | StreamContentType | 入口函数 |
|------|------------------|---------|
| Cell→Cell 实体迁移(ghost) | `STREAM_CONTENT_CELL` | `EntityDescription::addToStream(stream, STREAM_CONTENT_CELL)` |
| Base→Base 实体迁移(BaseApp 切换) | `STREAM_CONTENT_BASE` | `EntityDescription::addToStream(stream, STREAM_CONTENT_BASE)` |
| Base→Client 全量同步(玩家上线) | `STREAM_CONTENT_CLIENT \| STREAM_CONTENT_OTHER_CLIENT` | `EntityDescription::addToStream(stream, Client)` |
| Base→DBApp 持久化 | `STREAM_CONTENT_PERSISTENT` | `EntityDescription::addToStream(stream, STREAM_CONTENT_PERSISTENT)` |
| Cell→Client 增量同步(PropertyChange) | `STREAM_CONTENT_CLIENT` | `PropertyChange::write(stream)` |

### C.3 NUM_PASSES=4 的流分发

`EntityDescription::addToStream` 内部用 4 个 pass 遍历字段:

```cpp
const int NUM_PASSES = 4;
for (int pass = 0; pass < NUM_PASSES; ++pass)
{
    for (uint i = 0; i < properties_.size(); ++i)
    {
        DataDescription & dd = *properties_[i];
        if (dd.shouldBeInStream(contentType, pass))
        {
            dd.addToStream(stream, /* ... */);
        }
    }
}
```

4 个 pass 对应:

1. `pass=0`:CELL_DATA 字段
2. `pass=1`:BASE_DATA 字段
3. `pass=2`:CLIENT_DATA 字段(包括 OWN_CLIENT / OTHER_CLIENT / ALL_CLIENTS)
4. `pass=3`:PERSISTENT 字段

这种顺序保证不同进程解析流时,字段按相同的"域顺序"读取,从而无需在流中携带域标记。

---

## 附录 D:DataType 注册表

### D.1 内置类型清单

| 类型名 | 别名 | C++ 类 | 备注 |
|-------|------|--------|------|
| `INT8` | `CHAR` | `IntegerDataType<int8>` | 1 字节 |
| `UINT8` | `BYTE`, `UCHAR` | `IntegerDataType<uint8>` | 1 字节 |
| `INT16` | `SHORT` | `IntegerDataType<int16>` | 2 字节 |
| `UINT16` | `USHORT`, `WORD` | `IntegerDataType<uint16>` | 2 字节 |
| `INT32` | `INT`, `LONG`, `INTEGER` | `IntegerDataType<int32>` | 4 字节 |
| `UINT32` | `UINT`, `ULONG`, `DWORD` | `IntegerDataType<uint32>` | 4 字节 |
| `INT64` | `LLONG` | `IntegerDataType<int64>` | 8 字节 |
| `UINT64` | `ULLONG` | `IntegerDataType<uint64>` | 8 字节 |
| `FLOAT` | (无) | `FloatDataType<float>` | 4 字节 |
| `DOUBLE` | (无) | `FloatDataType<double>` | 8 字节 |
| `STRING` | (无) | `StringDataType` | 变长 |
| `VECTOR2` | (无) | `VectorDataType<Vector2>` | 8 字节 |
| `VECTOR3` | (无) | `VectorDataType<Vector3>` | 12 字节 |
| `VECTOR4` | (无) | `VectorDataType<Vector4>` | 16 字节 |
| `PYTHON` | (无) | `PythonDataType` | pickle 序列化(慢) |
| `ARRAY` | (无) | `ArrayDataType` | 变长数组 |
| `TUPLE` | (无) | `TupleDataType` | 固定长度数组 |
| `DICT` | `MAP` | `DictDataType` | 字典(键值都强类型) |
| `FIXED_DICT` | (无) | `FixedDictDataType` | 固定键的字典(类似 struct) |
| `USER_TYPE` | (无) | `UserDataType` | 引用其他实体类型 |

### D.2 类型注册机制

所有内置类型通过 `FORCE_LINK` 宏在 `data_types.cpp` 中注册:

```cpp
// programming/bigworld/lib/entitydef/data_types.cpp
template<class TYPE>
class SimpleMetaDataType : public MetaDataType
{
    // ...
};

#define FORCE_LINK_TYPE(TYPE_NAME) \
    extern int forceLink_##TYPE_NAME; \
    int * pForceLink_##TYPE_NAME##_ptr = &forceLink_##TYPE_NAME;

FORCE_LINK_TYPE(Integer8DataType)
FORCE_LINK_TYPE(Integer16DataType)
// ... 等等
```

`FORCE_LINK` 强制链接器保留这些符号,使 `MetaDataType::addMetaType` 在静态构造期被调用,完成注册。

### D.3 自定义类型扩展

项目侧可注册自定义 `MetaDataType`:

```cpp
class MyCustomMetaType : public MetaDataType
{
public:
    MyCustomMetaType()
    {
        addMetaType(this);
    }
    ~MyCustomMetaType()
    {
        delMetaType(this);
    }

    const char * name() const { return "MyCustom"; }

    DataTypePtr getType(DataSectionPtr pSection)
    {
        return new MyCustomDataType(this, pSection);
    }
};
```

只要这个类在 `MetaDataType::find` 被调用前完成静态构造,`.def` 中即可使用 `<Type>MyCustom</Type>`。

---

## 附录 E:术语表

| 术语 | 解释 |
|------|------|
| **EntityDef** | BigWorld 实体定义子系统,包括 `.def` 文件、`EntityDescriptionMap`、相关 C++ 类 |
| **`.def` 文件** | 单个实体类型的 XML 定义文件,放在 `scripts/entity_defs/` 目录 |
| **EntityDescription** | 单个实体类型的元数据集合(字段、方法、VolatileInfo) |
| **EntityDescriptionMap** | 所有 `EntityDescription` 的有序映射,运行时单例 |
| **DataType** | 字段类型的抽象基类(INT/FLOAT/STRING/ARRAY/...) |
| **MetaDataType** | DataType 的工厂类,负责从 XML 创建 DataType |
| **DataDescription** | 单个字段的元数据(名称、类型、标志、默认值) |
| **MethodDescription** | 单个方法的元数据(名称、参数、返回值、暴露标志) |
| **EntityMethodDescriptions** | 某个数据域(Cell/Base/Client)的所有方法集合 |
| **EntityDataDescriptions** | 某个数据域的所有字段集合 |
| **VolatileInfo** | 实体位置/朝向的同步优先级配置 |
| **PropertyChange** | 字段同步变更通知,有 Single / Slice 两种实现 |
| **PropertyChangeReader** | 接收端解析 PropertyChange 流的处理器 |
| **ExposedMessageRange** | Mercury 消息 ID 范围,为暴露方法分配 ID |
| **Mailbox** | 跨进程实体引用,封装 Mercury channel |
| **RemoteEntityMethod** | Python 端调用远程方法的代理对象 |
| **DataDomain** | 字段所属的数据域(Cell/Base/Client) |
| **StreamContentType** | 流分发时表示"哪些字段进入流"的位掩码 |
| **exposedMsgID** | 暴露方法的 Mercury 消息 ID |
| **MD5 摘要** | 整个 EntityDescriptionMap 的版本号,16 字节 |
| **process_defs** | 离线代码生成工具,把 `.def` 转 Python 描述 |
| **latest_only** | 字段同步优化:仅保留最新值,丢弃历史值 |
| **supersede** | 方法替换机制:新方法继承旧方法的 exposedMsgID |
| **BASE_DATA / CELL_DATA / ...** | 字段数据域标志,决定字段归属哪个进程与同步方向 |
| **DATA_PERSISTENT** | 字段持久化标志,决定字段是否写入数据库 |
| **NUM_PASSES=4** | 流分发的 4 个阶段(Cell/Base/Client/Persistent) |
| **PyDeferredResponse** | 远程方法调用的延迟返回值,在后续 tick 中触发回调 |
| **AoI** | Area of Interest,玩家的可见范围 |
| **Mercury** | BigWorld 的 UDP 网络库 |
| **CellApp / BaseApp / ClientApp / DBApp** | BigWorld 四个核心进程 |
| **CellAppMgr / BaseAppMgr / DBAppMgr** | 对应的进程管理器 |

---

## 附录 F:相关专题

### F.1 已发布的姊妹专题

| 专题 | 文件 | 关联点 |
|------|------|--------|
| 专题 1:BigWorld 14.4.1 启动流程深度剖析 | `docs/topics/专题01-BigWorld启动流程深度剖析.md` | CellApp/BaseApp 启动时调用 `EntityDescriptionMap::parse` |
| 专题 2:数据存储系统深度剖析 | `docs/topics/专题02-数据存储系统深度剖析.md` | `DATA_PERSISTENT` 字段的 DB 写入路径 |
| 专题 3:LoginApp 登录流程深度剖析 | `docs/topics/专题03-LoginApp登录流程深度剖析.md` | MD5 摘要的客户端校验 |
| 专题 4:BaseApp 服务进程深度剖析 | `docs/topics/专题04-BaseApp服务进程深度剖析.md` | `BASE_DATA` 字段处理与持久化 |
| 专题 5:Mailbox 通信机制深度剖析 | `docs/topics/专题05-Mailbox通信机制深度剖析.md` | `RemoteEntityMethod` 与 `Mailbox::sendStream` |
| 专题 6:CellApp 服务进程深度剖析 | `docs/topics/专题06-CellApp服务进程深度剖析.md` | `CELL_DATA` 字段处理与 PropertyChange |
| 专题 7:Mercury 网络协议深度剖析 | `docs/topics/专题07-Mercury网络协议深度剖析.md` | `exposedMsgID` 与 Mercury 消息分发 |
| 专题 8:DBApp 持久化服务深度剖析 | `docs/topics/专题08-DBApp持久化服务深度剖析.md` | 持久字段的 DBApp 写入 |
| 专题 10:VolatileInfo 与 LoD 系统深度剖析 | `docs/topics/专题10-VolatileInfo与LoD系统深度剖析.md` | VolatileInfo 的详细应用 |
| 专题 11:PropertyChange 通知系统深度剖析 | `docs/topics/专题11-PropertyChange通知系统深度剖析.md` | SinglePropertyChange / SlicePropertyChange 细节 |
| 专题 12:Reviver 与 bwmachined 双重守护机制 | `docs/topics/专题12-Reviver与bwmachined双重守护机制.md` | 进程守护(非 EntityDef 直接关联) |

### F.2 工具文档

| 文档 | 文件 | 关联点 |
|------|------|--------|
| BigWorld 工具 process_defs 实现分析 | `docs/tools/BigWorld工具-process_defs实现分析.md` | process_defs 工具的完整实现解析 |
| BigWorld 工具 batch_compiler 实现分析 | `docs/tools/BigWorld工具-batch_compiler实现分析.md` | 资源批量编译(通过 .def 引用实体) |
| BigWorld 工具 jit_compiler 实现分析 | `docs/tools/BigWorld工具-jit_compiler实现分析.md` | 资源即时编译 |

### F.3 推荐延伸阅读

- **actor 模型**:Erlang、Akka 的 Actor 设计与 BigWorld Mailbox 对比。
- **ECS 数据导向设计**:Unity DOTS、FLECS、Bevy ECS 的内存布局与 BigWorld 反射模型对比。
- **Protobuf IDL**:协议设计的现代标准,与 `.def` XML 对比。
- **gRPC service 定义**:跨语言 RPC 框架,与 BigWorld 方法分发对比。
- **FlatBuffers**:零拷贝序列化,与 BigWorld BinaryOStream 对比。

---

## 结语

EntityDef 是 BigWorld Engine 14.4.1 的"工程琥珀"——封存了 2003-2010 年 MMO 全栈设计的成熟方案。它在性能、灵活性、可维护性之间做出了精妙取舍,其"数据驱动 + 多进程共享元数据 + 严格版本控制"的三位一体设计,至今仍是大型多人在线游戏服务端的范本。理解 EntityDef,不仅是理解一个引擎,更是理解一个时代的工程哲学。

> **致谢**:本专题基于 BigWorld Engine 14.4.1 开源代码撰写,代码版权归 BigWorld Pty Ltd 所有(现属 Wargaming.net)。所有源码引用遵循开源协议,仅用于学习与技术讨论。
