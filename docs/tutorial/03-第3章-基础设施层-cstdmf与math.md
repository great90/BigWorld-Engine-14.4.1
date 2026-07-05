# 第3章 基础设施层 - cstdmf 与 math

> 任何上层模块都要踩在两块"地基"之上:一块负责"管内存、管容器、管调试、管时间"——这就是 `cstdmf`;另一块负责"算向量、算矩阵、算包围盒"——这就是 `math`。本章将带领读者从这两个最底层的库入手,理解 BigWorld Engine 14.4.1 的基础设施是如何设计与实现的。读完本章,你应当能够独立阅读 `lib/cstdmf/` 与 `lib/math/` 下的源码,并理解其中两类特色设施——Watcher 运行时观察器与 Singleton 模板——的设计意图与实现细节。

---

## 目录

- [3.1 cstdmf 库概述](#31-cstdmf-库概述)
- [3.2 容器适配器 bw_*.hpp 系列](#32-容器适配器-bw_hpp-系列)
- [3.3 内存管理](#33-内存管理)
- [3.4 调试与诊断](#34-调试与诊断)
- [3.5 并发与同步](#35-并发与同步)
- [3.6 工具类](#36-工具类)
- [3.7 Watcher 系统深入](#37-watcher-系统深入)
- [3.8 Singleton 模板深入](#38-singleton-模板深入)
- [3.9 math 库概述](#39-math-库概述)
- [3.10 数学库设计要点](#310-数学库设计要点)
- [3.11 本章小结](#311-本章小结)

---

## 3.1 cstdmf 库概述

### 3.1.1 位置与职责

`cstdmf` 库位于 `programming/bigworld/lib/cstdmf/`,目录名源自 "C++ Standard Math/ Misc Foundation"(标准数学与杂项基础),但事实上它早已超出"杂项"范畴,演化为整个引擎的"标准库替代品"。它承担了五项核心职责:

1. **容器适配器**:对 STL 容器做薄封装,植入自定义分配器,统一命名空间 `BW::`。
2. **内存管理**:统一的 `bw_new` / `bw_delete` / `bw_malloc` 接口、跨平台分配器、内存泄漏检测、智能指针。
3. **调试与诊断**:日志消息、调用栈、性能计时器(DogWatch)、Profiler、Watcher 运行时观察器。
4. **并发与同步**:原子操作、互斥锁、事件、信号量、线程安全单例。
5. **工具类**:时间戳、唯一标识、MD5、Base64、四字符码、版本号、字符串映射、配置加载等。

可以把 `cstdmf` 视作"BigWorld 自带的 mini-Boost":它填补了 C++03 时代标准库的不足,并为上层模块提供了统一的跨平台抽象层。

### 3.1.2 设计理念

阅读 `cstdmf` 源码时,请记住三条贯穿全局的设计理念:

1. **薄封装 STL**:`BW::vector`、`BW::map` 等都直接 `public` 继承自 `std::vector`、`std::map`,而不是聚合(aggregation)。这样做的好处是接口零学习成本,坏处是可能被切片。但 `cstdmf` 选择"性能优先 + 易用优先",认为薄封装的开销几乎为零,而聚合会带来一长串转发样板代码。
2. **平台无关**:`timestamp()`、`bw_atomic32_t`、`CpuInfo` 等接口在 Windows、Linux、macOS、PS3、Xbox360 上一致,平台差异被锁在 `.cpp` 文件里(如 `bw_util_windows.cpp`、`bw_util_linux.cpp`、`callstack_windows.cpp`)。
3. **可条件编译**:`config.hpp` 集中管理数十个 `ENABLE_*` 宏(`ENABLE_WATCHERS`、`ENABLE_PROFILER`、`ENABLE_MEMORY_DEBUG`、`ENABLE_DOG_WATCHERS`……),允许通过编译开关动态启停特性,从而在生产环境(关闭以提速)与开发环境(开启以排错)之间无缝切换。

### 3.1.3 命名空间与导出宏

所有 `cstdmf` 内容都位于 `BW` 命名空间下,通过 `BW_BEGIN_NAMESPACE` / `BW_END_NAMESPACE` 这两个宏包裹(见 `bw_namespace.hpp`),这样在 DLL/静态库切换时可以统一调整。跨 DLL 边界导出的函数用 `CSTDMF_DLL` 宏修饰(类似 `__declspec(dllexport)`),`i_allocator.hpp`、`watcher.hpp` 等都大量使用了它。

`stdmf.hpp` 是聚合头文件,引入它即可一次性获得 `cstdmf` 中绝大部分常用工具;`stdmf_minimal.hpp` 则是更轻量的版本,只包含不依赖其他系统头文件的最小集合,被 `bw_vector.hpp` 等使用,以避免头文件循环依赖。

---

## 3.2 容器适配器 bw_*.hpp 系列

### 3.2.1 为什么不直接用 STL

理论上,`std::vector<int>` 完全可以满足需求,那为什么 BigWorld 还要包一层 `BW::vector<int>`?原因有四:

1. **统一的内存追踪**:所有 `BW::` 容器默认使用 `BW::StlAllocator<T>` 作为分配器,该分配器最终会把请求路由到 `BW::Allocator::allocate()`(见 `allocator.hpp`),从而让内存调试器(`memory_debug.cpp`)能够统计、追踪、检测泄漏。直接用 `std::vector` 则绕开了这条链路。
2. **预留钩子**:用 `typedef` 把分配器设为模板参数,后续如需替换为对齐分配器、栈分配器、固定大小池分配器,只需替换第二个模板参数,无需改动业务代码。
3. **DLL 一致性**:Windows 下 STL 容器跨 DLL 边界传递时若 CRT 版本不同会崩溃。`BW::vector` 强制使用统一的 `StlAllocator`,在跨 DLL 时使用相同的堆,规避了这一问题。
4. **序列化兼容**:`BW::string`、`BW::vector` 等可以通过 `BinaryOStream` / `BinaryIStream` 直接序列化(见 `binary_stream.hpp`),这是网络协议与持久化层的基础。

### 3.2.2 bw_vector / bw_map / bw_set / bw_list / bw_deque

我们以 `bw_vector.hpp` 为例剖析其结构(`programming/bigworld/lib/cstdmf/bw_vector.hpp`):

```cpp
namespace BW
{
template < class T, class Allocator = StlAllocator< T > >
class vector : public std::vector< T, Allocator >
{
    typedef std::vector< T, Allocator > vector_base;
public:
    typedef typename vector_base::size_type size_type;

    vector() : vector_base() {}
    explicit vector( const Allocator& alloc ) : vector_base( alloc ) {}
    explicit vector( size_type count ) : vector_base( count ) {}
    // ... 其余构造函数
};
}
```

注意三点:

- **public 继承**而非聚合,这是 BigWorld 的明确选择,以避免转发 `push_back`、`begin`、`end` 等几十个函数。
- **默认分配器是 `StlAllocator<T>`**,而不是 `std::allocator<T>`。这一点至关重要,所有的内存追踪都依赖于此。
- **提供与 C++11 move 语义兼容的构造函数**,通过 `__cplusplus >= 201103L || _MSC_VER >= 1700` 守卫,既兼容 VS2010,也兼容 GCC 4.7+。

`bw_map.hpp`、`bw_set.hpp`、`bw_list.hpp`、`bw_deque.hpp` 的结构几乎完全相同,只是把基类换成了对应的 `std::` 容器。`bw_map.hpp` 同时定义了 `BW::map` 与 `BW::multimap`,这种"双产出"模式在所有关联容器适配器中保持一致。

### 3.2.3 bw_string 与字符串流

`bw_string.hpp` 稍有不同:它不只是 `typedef std::basic_string<char, ..., BW::char_allocator>`,还显式地在 `std` 命名空间里实例化了模板(通过 `CSTDMF_EXPORTED_TEMPLATE_CLASS` 宏),这是为了在 MSVC 2010 以前版本下能正确跨 DLL 导出 STL 模板类。

```cpp
namespace BW
{
typedef std::basic_string< char, std::char_traits< char >,
    char_allocator > string;
typedef std::basic_ostringstream< char, std::char_traits< char >,
    char_allocator > ostringstream;
// ...
}
```

同时还为 `BW::string` 与 `BW::wstring` 特化了 `std::hash`(或 `std::tr1::hash`,见 `bw_hash.hpp`),使得它们能作为 `BW::unordered_map` / `BW::unordered_set` 的键。

### 3.2.4 bw_hash.hpp / bw_hash64.hpp:哈希函数

`bw_hash.hpp` 解决了 STL 时代哈希的两大痛点:平台差异与组合哈希。

```cpp
namespace BW
{
    CSTDMF_DLL std::size_t hash_string( const void* ptr, std::size_t size );
    CSTDMF_DLL std::size_t hash_string( const char* str );

    template<typename T>
    void hash_combine( std::size_t & seed, const T & value )
    {
        BW::hash<T> hasher;
        seed ^= hasher( value ) +
            0xBC6EF372 +            // 一个魔数,用于打散
            (seed << 5) + (seed >> 3);
    }
}
```

`hash_combine` 是来自 Boost 的经典实现,用于把多个字段组合成一个哈希值——典型场景是对 `std::pair` 哈希:

```cpp
template<typename S, typename T>
struct hash< std::pair< S, T > > // ...
{
    std::size_t operator()( const std::pair< S, T > & v ) const
    {
        std::size_t seed = 0;
        BW::hash_combine( seed, v.first );
        BW::hash_combine( seed, v.second );
        return seed;
    }
};
```

`bw_hash64.hpp` 则提供 64 位哈希,用于更大的键空间(如 UniqueID)。

### 3.2.5 safe_fifo.hpp:线程安全 FIFO

`SafeFifo<T>` 是一个最小化的线程安全队列,实现简洁到只有 30 行:

```cpp
template <class T>
class SafeFifo
{
public:
    void push(T& t)
    {
        SimpleMutexHolder smh(mutex_);
        data_.push_back(t);
    }
    T pop()
    {
        SimpleMutexHolder smh(mutex_);
        T returned = *data_.begin();
        data_.pop_front();
        return returned;
    }
    uint count()
    {
        SimpleMutexHolder smh(mutex_);
        return data_.size();
    }
private:
    mutable SimpleMutex mutex_;
    BW::list<T> data_;
};
```

它使用 `SimpleMutexHolder`(RAII 锁)保护内部 `BW::list`。注意它**不**是阻塞队列——`pop()` 在队列为空时的行为是未定义(实际是从空 list 上取一个无效迭代器),调用者必须自行检查 `count()`。这种设计是有意为之,因为 BigWorld 的网络层有自己的事件循环,不需要阻塞式同步。

### 3.2.6 list_node.hpp:侵入式链表节点

`ListNode` 是一个经典的侵入式链表节点(intrusive list node)。"侵入式"的含义是:节点本身被嵌入到使用它的对象内部,而不是像 `std::list` 那样在外部分配节点。这种方式有两个优势:

- **零额外内存分配**:不需要 `new` 节点。
- **缓存友好**:对象与链表指针在内存中相邻。

```cpp
class ListNode
{
private:
    ListNode* next_;
    ListNode* prev_;
public:
    void setAsRoot();           // 把自己变成"环"
    void addThisAfter( ListNode* prev );
    void addThisBefore( ListNode* next );
    void remove();
    ListNode* getNext() const;
    ListNode* getPrev() const;
};
```

配合宏 `CAST_NODE( NODE, CLASS, FIELD )`(底层用 `bw_container_of` 宏),可以从 `ListNode*` 反向取出宿主对象的指针——这与 Linux 内核的 `list_head` / `container_of` 设计如出一辙。在 `cstdmf` 内部,`Cache<>` 模板就使用 `ListNode` 风格的双向链表来维护 LRU 顺序(虽然 `Cache<>` 内部用的是自实现的 `CacheNode`,但思路相同)。

---

## 3.3 内存管理

### 3.3.1 三层内存架构

BigWorld 的内存管理是一个三层结构:

| 层级 | 入口 | 职责 |
|------|------|------|
| 顶层 | `bw_new` / `bw_malloc` | 对外暴露的统一接口,处理 `new_handler` 与异常 |
| 中层 | `BW::Allocator::allocate` | 调试钩子入口,可绕过固定池 |
| 底层 | `BW::Allocator::heapAllocate` / `FixedSizedAllocator` | 真正向 OS 申请内存,或从对象池取 |

顶层接口在 `bw_memory.hpp` 中声明,只有 12 个函数:

```cpp
void * bw_new( size_t size );
void * bw_new_array( size_t size );
void   bw_delete( void * ptr ) throw();
void   bw_delete_array( void * ptr ) throw();
void * bw_malloc( size_t size );
void   bw_free( void * ptr );
void * bw_malloc_aligned( size_t size, size_t alignment );
void   bw_free_aligned( void * ptr );
void * bw_realloc( void * ptr, size_t size );
char * bw_strdup( const char * s );
wchar_t * bw_wcsdup( const wchar_t * s );
size_t bw_memsize( void * p );
```

注意它们都是 `CSTDMF_DLL` 导出的——也就是说,跨 DLL 边界申请/释放内存时,**两侧必须使用同一套 `bw_*` 接口**,否则会因为 CRT 堆不同而崩溃。这是 BigWorld 项目"统一堆"原则的源头。

### 3.3.2 bw_memory.cpp 的实现

`bw_memory.cpp` 实现非常直白,以 `bw_new` 为例:

```cpp
void * bw_new( size_t size )
{
    if (size == 0) size = 1;
    while (true)
    {
        if (void * p = BW::Allocator::allocate( size ))
            return p;
        if (std::new_handler handler = globalNewHandler())
            (*handler)();        // 给上层一个清理内存的机会
        else
            throw std::bad_alloc();
    }
}
```

注意它正确实现了 C++ 标准要求的"申请失败→调用 `new_handler`→重试"循环,这是许多游戏引擎会偷懒省略的部分。`globalNewHandler()` 内部用 `SimpleMutex` 保护 `set_new_handler`,以兼容 C++03。

### 3.3.3 Allocator 命名空间:统一入口

`BW::Allocator`(`allocator.hpp`)是所有内存分配的"中央集线器",它对外提供:

- `allocate(size)` / `deallocate(ptr)` / `reallocate(ptr, size)`:走调试钩子的分配接口。
- `heapAllocate(size, flags)` / `heapAllocateAligned(size, alignment)`:直接从堆分配,绕过固定池,常用于第三方库。
- `setSystemStage(SS_PRE_MAIN / SS_MAIN / SS_POST_MAIN)`:声明系统初始化阶段,内存调试器据此判断"此刻的分配算不算泄漏"——例如,静态全局对象的分配发生在 `SS_PRE_MAIN`,不应该被记为泄漏。
- `ScopedSystemStage`:RAII 包装,进入作用域时切换 stage,离开时还原。
- `readAllocationStats(stats)`:读取当前分配数、字节数(需 `ENABLE_MEMORY_DEBUG`)。
- `trackSmartPointerAssignment(ptr, obj)`:智能指针赋值追踪(需 `ENABLE_SMARTPOINTER_TRACKING`)。

```cpp
namespace Allocator
{
    enum SystemStage { SS_PRE_MAIN, SS_MAIN, SS_POST_MAIN };
    enum InfoFlags   { IF_POOL_ALLOC = 1, IF_NOTRACK_ALLOC = 2,
                       IF_INTERNAL_ALLOC = 4, IF_DEBUG_ALLOC = 8 };

    static const int CleanLandFill  = 0xCD;  // 已分配但未初始化
    static const int DeadLandFill   = 0xDD;  // 已释放
    static const int NoMansLandFill = 0xFE;  // 边界哨兵
    static const int AlignLandFill  = 0xFD;  // 对齐填充
}
```

这几个填充字节是经典的 VC++ CRT 调试模式:刚分配的内存填 `0xCD`,释放后填 `0xDD`,这样调试器能立刻识别出"使用未初始化内存"或"使用已释放内存"的错误。

### 3.3.4 StlAllocator:把 STL 接入 BigWorld

`StlAllocator<T>`(`stl_fixed_sized_allocator.hpp`)是连接 STL 容器与 `BW::Allocator` 的桥梁,它实现了 STL 标准要求的 `allocate` / `deallocate` / `construct` / `destroy` 接口:

```cpp
template < typename T >
class StlAllocator : public Detail::StlAllocatorBase< T >
{
public:
    typedef typename base_type::value_type value_type;
    // ... pointer, reference, size_type, difference_type, rebind

    template <typename Other>
    struct rebind { typedef StlAllocator< Other > other; };

    StlAllocator() {}
    template <typename Other>
    StlAllocator( const StlAllocator< Other > & otherAllocator );

    pointer allocate( size_type count, const void * hint = NULL );
    void deallocate( pointer p, size_type count );
    // ...
};
```

注意 `rebind` 模板——这是 STL 分配器协议的核心机制,允许 `std::list<T>` 在内部把 `StlAllocator<T>` 转换为 `StlAllocator<ListNode<T>>`。`rebind` 在 C++17 后被废弃,但在 BigWorld 支持的 C++03 时代是必需的。

### 3.3.5 固定大小分配器与对象池

`cstdmf` 还提供了两类专用分配器:

- `FixedSizedAllocator`(`fixed_sized_allocator.hpp`):一次性向 OS 申请大块内存,切分为固定大小的"槽位",`allocate` / `deallocate` 都是 O(1) 且无碎片,适合频繁创建/销毁的固定大小对象。
- `ObjectPool<T>`(`object_pool.hpp`):基于 `FixedSizedAllocator` 的对象池,自动调用构造/析构。

这两个组件是性能关键路径(如网络包、实体移动消息)的基石。读者现在只需知道它们存在,在第 5 章网络层会看到具体使用。

### 3.3.6 cache.hpp:LRU 缓存模板

`Cache<Key, Value>` 是一个简洁的 LRU(Least Recently Used)缓存,实现仅 130 行:

```cpp
template<class Key, class Value> class Cache
{
private:
    struct CacheNode
    {
        Key key_;  Value value_;
        CacheNode* pNext_;  CacheNode* pPrev_;
    };
    typedef BW::map<Key, CacheNode*> CacheMap;
public:
    Cache(unsigned int maxSize = 100);
    void insert(Key key, const Value& value);
    Value* find(Key key);     // 命中后移到链表头
    void erase(Key key);
private:
    CacheMap cacheMap_;       // 用于 O(log n) 查找
    CacheNode cacheChain_;    // 双向链表头(自环)
    unsigned int maxSize_;
};
```

数据结构是经典的 "哈希表 + 双向链表":`BW::map` 负责查找,链表负责维护 LRU 顺序。`find()` 命中后会把节点移到链表头,淘汰时从链表尾取——这一思路与操作系统页面置换算法完全一致。

### 3.3.7 bwrandom.hpp:梅森旋转随机数

`BWRandom` 是基于梅森旋转(Mersenne Twister,MT19937)的伪随机数生成器,状态向量 `mt[624]`。相比 `rand()`,它有更长的周期(2^19937−1)、更好的随机性、可实例化(每个对象独立状态):

```cpp
class BWRandom
{
public:
    BWRandom();
    explicit BWRandom(uint32 seed);
    uint32 operator()();
    int operator()(int min, int max);
    float operator()(float min, float max);
    static BWRandom& instance();  // 单例,可供静态初始化使用
private:
    uint32 mt[624];  int mti;
};
#define bw_random (BWRandom::instance())
```

`bw_random` 宏提供全局访问点。`mathdef.hpp` 中的 `unitRand()` 与 `randInRange()` 都基于它实现。

### 3.3.8 memhook/:内存钩子

`memhook/` 子目录(本教程不深入展开)提供了对 `new` / `delete` / `malloc` / `free` 的全局替换钩子,在 `ENABLE_MEMORY_DEBUG` 开启时,所有内存操作都会被记录到 `memory_debug.cpp` 维护的全局表中,以便在程序退出时打印泄漏报告。这部分实现高度平台相关,涉及链接器技巧,初学者了解其存在即可。

---

## 3.4 调试与诊断

### 3.4.1 debug.hpp:消息优先级与分类

`debug.hpp` 是整个调试系统的统一入口,它定义了一组消息宏,按优先级从低到高排列:

| 宏 | 优先级 | 用途 |
|----|--------|------|
| `TRACE_MSG` | TRACE | 极度详细的执行轨迹,默认不输出 |
| `DEBUG_MSG` | DEBUG | 调试期诊断信息 |
| `INFO_MSG` | INFO | 正常运行信息 |
| `NOTICE_MSG` | NOTICE | 值得注意但不重要 |
| `WARNING_MSG` | WARNING | 警告,可能有问题 |
| `ERROR_MSG` | ERROR | 错误,但程序可继续 |
| `HACK_MSG` | HACK | 临时方案,需要后续清理 |
| `CRITICAL_MSG` | CRITICAL | 致命错误,程序将退出 |
| `ASSET_MSG` | ASSET | 资源加载问题 |

每个宏最终都调用 `LogMsg::write(format, ...)`,接受 `printf` 风格的可变参数,并通过 `__attribute__((format(printf, 2, 3)))`(GCC/Clang)做编译期格式串检查。

每个使用调试宏的 `.cpp` 文件应当先 `DECLARE_DEBUG_COMPONENT2("Category", priority)` 声明分类与阈值,这样运行时可以按分类过滤——例如只看 "Network" 分类的消息。

### 3.4.2 log_msg.hpp / log_msg.cpp:日志消息系统

`LogMsg` 是消息系统的核心类,它支持:

- **分类(category)**:每条消息附带分类字符串,如 "Network"、"Math"。
- **来源(source)**:`DEBUG_MESSAGE_SOURCE` 枚举区分客户端、服务器、工具等来源。
- **元数据(meta data)**:可附加任意键值对,用于结构化日志分析。例如 `LogMsg(...).meta("entityId", id).write("...")`。
- **回溯(backtrace)**:`writeBackTrace()` 会自动附带当前调用栈。
- **多种输出**:可同时输出到控制台、文件、syslog、Windows 事件日志。

```cpp
class LogMsg
{
public:
    LogMsg( DebugMessagePriority priority, const char * pCategory = NULL );
    LogMsg & category( const char * pCategory );
    LogMsg & operator[]( const char * pCategory );  // 等价于 category()
    LogMsg & source( DebugMessageSource source );
    template< class VALUE_TYPE >
    LogMsg & meta( const char * pKey, const VALUE_TYPE & value );
    void write( const char * pFormat, ... ) BW_FORMAT_ATTRIBUTE;
    void operator()( const char * pFormat, ... ) BW_FORMAT_ATTRIBUTE;
    void writeBackTrace();
    // ...
};
```

`TraceMsg`、`DebugMsg` 等是 `LogMsg` 的子类,只是预设了优先级,使用上更便捷。

### 3.4.3 dprintf.hpp:最底层打印

`dprintf` 是比 `LogMsg` 更底层的打印函数,它**不**经过任何过滤、不格式化分类、不写日志文件,直接写 `stderr` 或 `OutputDebugString`。它的存在是为了在内存系统、日志系统本身出问题时仍能输出信息。`ENABLE_DPRINTF` 关闭时,`dprintf` 会被编译为空函数,零开销。

### 3.4.4 callstack.hpp:调用栈追踪

`callstack.hpp` 提供跨平台的调用栈采集与符号解析:

```cpp
int stacktrace( CallstackAddressType * trace, size_t maxDepth,
    size_t skipFrames = 0 );
int stacktraceAccurate( CallstackAddressType * trace, size_t maxDepth,
    size_t skipFrames = 0, int threadID = 0 );
bool convertAddressToFunction( CallstackAddressType address,
    char * nameBuf, size_t nameBufSize,
    char * fileBuf, size_t fileBufSize, int * line );
```

`stacktrace` 是快但可能不全的实现(基于帧指针回溯),`stacktraceAccurate` 是慢但完整的实现(基于 DWARF/PDB 调试信息)。`convertAddressToFunction` 把地址转换为函数名 + 文件名 + 行号,在崩溃报告与泄漏定位时至关重要。

仅在 `BW_ENABLE_STACKTRACE`(由 `ENABLE_MEMORY_DEBUG` 控制)开启时编译,因为它依赖平台相关的调试符号库。

### 3.4.5 dogwatch.hpp / dogwatch.ipp:狗看式计时器

`DogWatch` 是 BigWorld 独特的命名——"狗看式"计时器,典故是"哈狗看着骨头,一直盯着它"——意指持续累积时间的精细计时器。它专用于测量一帧内各阶段的耗时(如"渲染"、"网络"、"脚本"、"AI"),并保留最近 120 帧(`NUM_SLICES`)的历史:

```cpp
class DogWatch
{
public:
    DogWatch( const char * title );
    void start();
    void stop();
    uint64 slice() const;       // 当前 slice 累计的时间戳数
    const BW::string & title() const;
private:
    uint64 started_;
    uint64 *pSlice_;
    int id_;
    BW::string title_;
};

class ScopedDogWatch
{
public:
    ScopedDogWatch( DogWatch & dogWatch ) : dogWatch_( dogWatch )
    {   this->dogWatch_.start(); }
    ~ScopedDogWatch()
    {   this->dogWatch_.stop(); }
private:
    DogWatch & dogWatch_;
};

#define BW_SCOPED_DOG_WATCHER(name)  \
    static DogWatch hidden_dog_watcher(name);  \
    ScopedDogWatch scoped_hidden_dog_watcher(hidden_dog_watcher);
```

使用方式:

```cpp
void renderFrame()
{
    BW_SCOPED_DOG_WATCHER("Render");  // 进入作用域开始计时,离开自动停止
    // ... 实际渲染代码
}
```

`DogWatchManager` 维护一个 "manifestation cache"——它根据当前调用栈的层次组织计时器,使得"AI 内部又调用了 Physics"这样的嵌套关系能被正确记录。`dogwatch.ipp` 中 `start()` 与 `stop()` 的实现都是 inline 的,在 `NO_DOG_WATCHES` 宏生效时进一步退化为空操作,保证生产环境的零开销。

### 3.4.6 profile.hpp / profiler.hpp / profiler.ipp:性能分析器

`Profiler` 是比 `DogWatch` 更重量级的性能分析器,支持:

- **分层(hierarchical)统计**:不只记录函数耗时,还记录调用层次。
- **多线程隔离**:每个线程有独立的 entry 栈,最多支持 96 个线程。
- **多模式**:层次模式、按时间排序、按调用次数排序、按名字排序、CPU/GPU 模式、图形模式、按核心模式。
- **Chrome Trace JSON 导出**:`jsonDump()` 把数据导出为 `chrome://tracing` 可视化的格式。
- ** hitch detection(卡顿检测)**:`HitchDetector` 监测帧时间是否超过阈值,超阈值时自动冻结并 dump 当前 profile。

使用方式:

```cpp
PROFILER_SCOPED(MyFunction);   // 在函数开头加这一行
```

宏展开为:

```cpp
ScopedProfiler prof_MyFunction("MyFunction");
```

`ScopedProfiler` 在构造时调用 `g_profiler.addEntry(name, EVENT_START, 0)`,析构时 `addEntry(name, EVENT_END, 0)`,中间的所有事件被记录到双缓冲 entry buffer 中。每帧结束时 `Profiler::tick()` 交换缓冲并处理上一帧的数据。`ENABLE_PROFILER` 关闭时,所有 `PROFILER_*` 宏退化为空。

### 3.4.7 watcher.hpp / watcher.cpp:运行时变量观察器

这是 `cstdmf` 最具特色的设施之一,值得单独成节,详见 [3.7 Watcher 系统深入](#37-watcher-系统深入)。

### 3.4.8 cpuinfo.hpp:CPU 信息

`CpuInfo` 包装了 `GetLogicalProcessorInformation` / `GetCurrentProcessorNumber` 等 Windows API,提供:

```cpp
class CpuInfo
{
public:
    int32 numberOfSystemCores();      // 物理核数
    int32 numberOfLogicalCores();     // 逻辑核数(含超线程)
    int32 getPhysicalCore(int32 coreID);
    bool isLogical(int32 coreID);
    static int32 getCurrentProcessorNumber();  // 当前线程在哪个核
};
```

它在 `ENABLE_PER_CORE_PROFILER` 时被 `Profiler` 用来按 CPU 核心分组展示事件。

---

## 3.5 并发与同步

### 3.5.1 concurrency.hpp:原子操作与互斥锁

`concurrency.hpp` 是 `cstdmf` 的并发基础,提供跨平台的原子操作宏与同步原语:

```cpp
#ifdef WIN32
    typedef LONG volatile bw_atomic32_t;
    #define BW_ATOMIC32_COMPARE_AND_SWAP( dest, newval, oldval ) \
        InterlockedCompareExchange( (dest), (newval), (oldval) )
    #define BW_ATOMIC32_INC_AND_FETCH( dest ) InterlockedIncrement( (dest) )
#elif defined(__GNUC__)
    typedef int bw_atomic32_t;
    #define BW_ATOMIC32_COMPARE_AND_SWAP( dest, newval, oldval ) \
        __sync_val_compare_and_swap( (dest), (oldval), (newval) )
    // ...
#endif
```

Debug 模式下(`ENABLE_ATOMIC32_ALIGNMENT_CHECK`)还会检查地址是否 4 字节对齐——这是 Windows 上 `Interlocked*` 系列函数的隐式要求,违反会导致莫名其妙的崩溃。

此外还提供 `SimpleMutex`、`SimpleMutexHolder`(RAII 锁)、`ReadWriteLock`、`SimpleSemaphore`、`BWThread` 等。这些类的接口与 STL 线程库(以及后来的 `std::thread`)高度相似,但**在 C++03 时代就已存在**,因此 BigWorld 内部代码大多使用它们而非 `std::thread`。

### 3.5.2 event.hpp:事件多播

`Event<Sender, EventArgs>` 是一个简洁的多播事件模板——一个事件可以注册多个成员函数作为处理者,触发时全部调用。其核心是 `EventDelegate`,通过 "stub method" 模式避免 `std::function` 的堆分配:

```cpp
class EventDelegate
{
public:
    template < class TargetType,
        typename TargetTraits<TargetType>::MemberFunctionPtr MethodPtr>
    static EventDelegate fromMethod( TargetType * pTarget )
    {
        EventDelegate d;
        d.pTarget_ = pTarget;
        d.pStubMethod_ = &stub_method< TargetType, MethodPtr >::stub;
        return d;
    }
    void operator()( Sender * pSender, EventArgs args ) const
    {   return (*pStubMethod_)( pTarget_, pSender, args ); }
private:
    void * pTarget_;
    StubMethodType pStubMethod_;   // 函数指针,指向 stub
    template < class TargetType, ... >
    struct stub_method {
        static void stub( void * pVoidTarget, Sender * pSender, EventArgs args ) {
            TargetType * pTarget = static_cast< TargetType * >(pVoidTarget);
            return (pTarget->*MethodPtr)( pSender, args );
        }
    };
};
```

这种"成员函数指针 + 编译期模板参数"的技巧源自 [CodeProject 上的 Fast C++ Delegate](http://www.codeproject.com/Articles/13287/Fast-C-Delegate),在 C++11 之前是实现零开销委托的经典手法。其优势是:

- 无堆分配(相比 `std::function`)
- 支持相等比较(可在 `remove` 时使用)
- 调用开销小(一次间接跳转)

注意注释明确指出:`invoke` 期间不允许修改 delegate 列表,这是用 `isIterating_` 标志位 + `MF_ASSERT` 强制的。

### 3.5.3 fini_job.hpp:静态析构排序

C++ 的静态析构顺序是反向构造顺序,但跨翻译单元的顺序无法保证。`FiniJob` 提供了一种"显式提前析构"机制:

```cpp
class FiniJob
{
public:
    FiniJob();
    virtual ~FiniJob() {};
    static bool runAll();   // 在 main 返回前调用,依次执行所有 fini()
protected:
    virtual bool fini() = 0;
};
```

需要"在所有静态对象析构前先收尾"的对象(如 `MemTracker`)继承 `FiniJob`,实现 `fini()`,然后由 `main` 在适当时机调用 `FiniJob::runAll()`。这样保证了"内存调试器必须在所有对象析构前先关闭"的语义。

### 3.5.4 singleton.hpp:线程安全单例模板

详见 [3.8 Singleton 模板深入](#38-singleton-模板深入)。

### 3.5.5 slow_task.hpp:慢任务通知

`SlowTask` 是一个 RAII 守卫,用来通知 UI"现在正在执行慢任务,请显示忙碌光标":

```cpp
class SlowTaskHandler {
public:
    virtual void startSlowTask() = 0;
    virtual void stopSlowTask() = 0;
    static SlowTaskHandler*& handler();  // 全局指针
};
class SlowTask {
public:
    SlowTask()  { if (SlowTaskHandler::handler()) SlowTaskHandler::handler()->startSlowTask(); }
    ~SlowTask() { if (SlowTaskHandler::handler()) SlowTaskHandler::handler()->stopSlowTask(); }
};
```

设计极简——全局只有一个 `SlowTaskHandler*`,由 UI 层在启动时设置。这种"全局处理者指针 + RAII"的模式在 BigWorld 中很常见,`MessageHandler`、`CriticalErrorHandler` 等都采用类似设计。

---

## 3.6 工具类

### 3.6.1 guard.hpp:作用域守卫

`BW_GUARD` 是 `cstdmf` 中最重要的宏之一,但它**不是** `std::lock_guard`,而是一个"作用域追踪器":

```cpp
#if ENABLE_STACK_TRACKER
    #define BW_GUARD  ScopedStackTrack _BW_GUARD(__FUNCTION__, __FILE__, __LINE__)
    #define BW_GUARD_BEGIN  StackTracker::push(__FUNCTION__, __FILE__, __LINE__)
    #define BW_GUARD_END    StackTracker::pop()
#else
    #define BW_GUARD
    #define BW_GUARD_BEGIN
    #define BW_GUARD_END
#endif
```

它的作用是把"当前在哪个函数、哪个文件、第几行"压入 `StackTracker` 维护的线程局部栈。这样当 `DogWatch`、`Profiler`、`LogMsg` 在记录事件时,能附带调用栈信息。在 `ENABLE_STACK_TRACKER` 关闭时,`BW_GUARD` 退化为空,零开销。

变体宏:

- `BW_GUARD_PROFILER(id)`:同时启动 profiler 计时。
- `BW_GUARD_MEMTRACKER(id)`:同时启动内存追踪。
- `BW_GUARD_ANNOTATE(str)`:在栈上添加注释字符串,便于调试器显示。
- `BW_GUARD_PROFILER_MEMTRACKER(id)`:同时启动 profiler 与 memtracker。

理论上 BigWorld 期望每个非平凡函数的第一行都是 `BW_GUARD`,这与 `ASSERT` / `LOG` 类似,是项目的代码规范要求。

### 3.6.2 unique_id.hpp:128 位唯一标识

`UniqueID` 是一个 128 位的 GUID,内部存储为 4 个 `uint`:

```cpp
class UniqueID
{
private:
    uint a_, b_, c_, d_;
public:
    UniqueID();
    UniqueID( const BW::string & s );
    UniqueID( uint a, uint b, uint c, uint d );
    BW::string toString() const;       // 形如 "81A9D1BF.4B8B622E.6F7081B3.0698330E"
    operator BW::string() const;
    bool operator==( const UniqueID& rhs ) const;
    bool operator<( const UniqueID& rhs ) const;
#ifdef _WIN32
    static UniqueID generate();        // 调用 Windows CoCreateGuid
#endif
    static const UniqueID& zero();
    static bool isUniqueID( const BW::string& s );
};
```

字符串格式是 8 位十六进制 + 点分隔,而非标准的 `{xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx}`——这是 BigWorld 自有的紧凑格式。注释明确指出"结构必须与 Microsoft 的 GUID 兼容,因为我们在某个函数里直接 cast 到 GUID",这意味着内存布局是 `uint[4]`,与 Windows GUID 的 `Data1/Data2/Data3/Data4` 布局实际不同,但 BigWorld 通过显式转换函数处理。

`UniqueID` 在引擎中用于实体 ID、节点 ID、资源 ID 等场景。

### 3.6.3 timestamp.hpp:时间戳

`timestamp()` 是 BigWorld 时间系统的最底层入口,返回 `uint64` 类型的高精度时间戳。其实现因平台而异:

- **Windows + BW_USE_RDTSC**:直接 `rdtsc` 指令,返回 CPU 时钟周期。最快但与 CPU 频率耦合,在 SpeedStep 等动态调频场景下不稳定。
- **Windows + 默认**:`QueryPerformanceCounter`,系统级高精度计数器。
- **Linux**:`clock_gettime(CLOCK_MONOTONIC)`(默认),或 `gettimeofday`,或 `rdtsc`。运行时通过 `g_timingMethod` 选择。
- **macOS / Android**:`gettimeofday`。
- **PS3**:`SYS_TIMEBASE_GET`。

`stampsPerSecond()` 返回每秒时间戳数,`stampsToSeconds(stamps)` 把时间戳转换为秒。这两者配合,可以在不同平台获得统一的时间测量。

`TimeStamp` 类是 `uint64` 的轻量包装,提供 `inSeconds()` / `setInSeconds()` / `ageInSeconds()` 等便捷方法。它还特化了 `watcherValueToStream` / `watcherStringToValue`,使其能直接被 Watcher 系统使用(见 3.7)。

### 3.6.4 md5.hpp / base64.h:加密编码

`MD5` 类实现了标准的 MD5 哈希算法,支持流式更新:

```cpp
class MD5
{
public:
    struct Digest {
        static const size_t NUM_BYTES = 16;
        unsigned char bytes[NUM_BYTES];
        BW::string quote() const;        // 转十六进制字符串
        bool unquote( const BW::string & quotedDigest );
    };
    MD5();
    void append( const void * data, int numBytes );
    void getDigest( Digest & digest );
};
```

`base64.h` 是经典的 Base64 编解码器(注释显示源自 Bob Withners 1999 年的代码),用于把二进制数据编码为 ASCII 字符串,常见于 HTTP 基本认证、邮件附件等场景。

### 3.6.5 fourcc.hpp:四字符码

`FourCC` 是 4 字节的紧凑标识符,常用于资源类型标签、文件魔数:

```cpp
struct FourCC
{
    FourCC() : value_(0) {}
    FourCC( char a, char b, char c, char d );
    union {
        uint32 value_;
        char fourcc_[4];
    };
    bool operator==(const FourCC& other) const { return value_ == other.value_; }
};

#define DECLARE_FOURCC(ch0, ch1, ch2, ch3) \
    ((uint32)(uint8)(ch0) | ((uint32)(uint8)(ch1) << 8) | \
     ((uint32)(uint8)(ch2) << 16) | ((uint32)(uint8)(ch3) << 24))
```

`union` 让 `FourCC` 既可以当 `uint32` 比较,又可以逐字节访问字符。`DECLARE_FOURCC` 宏支持编译期构造,可用作 `switch case` 标签——这是 BigWorld 在解析资源文件头时常用的优化技巧。

### 3.6.6 config.hpp:配置开关

`config.hpp` 集中管理所有 `ENABLE_*` 编译开关,部分关键开关:

| 宏 | 默认 | 用途 |
|----|------|------|
| `ENABLE_WATCHERS` | 开发构建开 | 启用 Watcher 运行时观察系统 |
| `ENABLE_DOG_WATCHERS` | 开发构建开 | 启用 DogWatch 计时器 |
| `ENABLE_PROFILER` | 开发构建开 | 启用 Profiler |
| `ENABLE_HITCH_DETECTION` | 开发构建开 | 启用卡顿检测 |
| `ENABLE_MEMORY_DEBUG` | 开发构建开 | 启用内存调试 |
| `ENABLE_MSG_LOGGING` | 静态客户端开 | 启用日志消息 |
| `ENABLE_DPRINTF` | 静态客户端开 | 启用 dprintf |
| `ENABLE_STACK_TRACKER` | 开发构建开 | 启用 BW_GUARD 栈追踪 |
| `CONSUMER_CLIENT_BUILD` | 公开客户端为 1 | 公开客户端剥离开发特性 |

`FORCE_ENABLE_*` 系列宏允许在 `CONSUMER_CLIENT_BUILD=1` 时强制开启某个特性。这种"默认关闭 + 显式强制开启"的策略是为了减小公开客户端体积并避免泄露调试接口。

### 3.6.7 bwversion.hpp:版本信息

```cpp
#define BW_VERSION_MAJOR 14
#define BW_VERSION_MINOR 4
#define BW_VERSION_PATCH 1
#define BW_COPYRIGHT_NOTICE "(c) 1999 - 2014, BigWorld Pty. Ltd. All Rights Reserved"
```

`BWVersion` 命名空间提供运行时访问接口,且这些值通过 `MF_WATCH` 注册到 Watcher 系统中,可远程查询:

```cpp
MF_WATCH( "version/major", g_majorNumber, Watcher::WT_READ_ONLY );
MF_WATCH( "version/minor", g_minorNumber, Watcher::WT_READ_ONLY );
MF_WATCH( "version/patch", g_patchNumber, Watcher::WT_READ_ONLY );
MF_WATCH( "version/string", g_versionString, Watcher::WT_READ_ONLY );
```

这意味着运维人员可以通过 bwmachined 远程查询任意一台服务器运行的引擎版本——这是 Watcher 系统在运维场景下的典型应用。

### 3.6.8 stringmap.hpp:字符串映射

`StringHashMap<T>` 继承自 `BW::unordered_map<BW::string, T>`,提供 O(1) 平均查找的字符串→对象映射。此外还提供 `StringSet`(字符串集合)、`WStringHashMap`、`StringRefUnorderedMap`(基于 `BW::StringRef` 的映射,避免字符串拷贝)。

文件中定义了多种"策略"类:`ConstPolicy`(不拷贝字符串)、`StrdupPolicy`(用 `bw_strdup` 复制)、`FreePolicy`(用 `bw_free` 释放)、`DeletePolicy`(用 `delete` 释放)。这种"策略类"设计允许在不修改 `StringMap` 本体的前提下灵活切换字符串所有权策略——这是 C++ 模板元编程的典型应用。

### 3.6.9 progress.hpp / restart.hpp / locale.hpp / ftp.hpp

这些是较小的工具类:

- `Progress`:抽象进度接口,UI 工具实现子类来显示进度条。
- `restart`:`waitForRestarting()` / `startNewInstance()` 用于服务重启。
- `Locale`:`standardC()` 返回标准 "C" locale,避免 locale 引起的字符串比较差异。
- `ftp`:简化 FTP 客户端封装(legacy)。

---

## 3.7 Watcher 系统深入

### 3.7.1 为什么需要 Watcher

游戏服务器在运行时是黑盒——你无法 attach 调试器(会卡住所有玩家)、不能频繁重启(影响在线用户)、但又需要观察"当前实体数"、"网络吞吐量"、"某条 AI 决策结果"等运行时状态,甚至需要在不停服的情况下调整某个阈值。

`Watcher` 系统就是为了解决这一问题而设计的。它本质上是一棵"路径→值"的树,允许:

1. **查看**(GET):读取任意已注册变量的当前值。
2. **修改**(SET):在运行时修改变量(需变量声明为 `WT_READ_WRITE`)。
3. **调用**(CALL):触发注册的回调函数,实现远程 RPC。
4. **遍历**(LIST):列出某路径下的所有子项。

它与 bwmachined 守护进程集成,通过 HTML 接口(`watcher_html`)或网络协议暴露给运维工具。

### 3.7.2 Watcher 类层次

`watcher.hpp` 定义了一个完整的类层次:

```
Watcher (抽象基类, SafeReferenceCount)
├── DirectoryWatcher        # 目录节点,可包含子 Watcher
├── DataWatcher<T>           # 监听一个变量
├── FunctionWatcher<R>       # 监听一个函数的返回值
├── MemberWatcher<R, T>      # 监听对象成员(通过 get/set 方法)
├── ReadOnlyMemberWatcher<R, T>
├── SequenceWatcher<Seq>     # 监听序列(vector/list)
├── MapWatcher<Map>          # 监听映射(map/unordered_map)
├── CallableWatcher          # 可调用(触发函数)
│   ├── NoArgCallableWatcher
│   │   └── NoArgFuncCallableWatcher
│   └── SimpleCallableWatcher
├── SafeWatcher               # 加锁包装器(线程安全)
├── ReadWriteLockWatcher      # 读写锁包装器
├── DereferenceWatcher        # 解引用包装器
│   ├── BaseDereferenceWatcher
│   ├── SmartPointerDereferenceWatcher
│   └── ContainerBounceWatcher
├── AbsoluteWatcher           # 绝对地址包装器
└── FreezeWatcher<T>          # 冻结值包装器
```

所有 Watcher 都继承自 `Watcher`,它定义了核心接口:

```cpp
class Watcher : public SafeReferenceCount
{
public:
    enum Mode {
        WT_INVALID, WT_READ_ONLY, WT_READ_WRITE, WT_DIRECTORY, WT_CALLABLE
    };

    virtual bool getAsString( const void * base, const char * path,
        BW::string & result, BW::string & desc, Mode & mode ) const = 0;
    virtual bool setFromString( void * base, const char * path,
        const char * valueStr ) = 0;
    virtual bool setFromStream( void * base, const char * path,
        WatcherPathRequestV2 & pathRequest ) = 0;
    virtual bool getAsStream( const void * base, const char * path,
        WatcherPathRequestV2 & pathRequest ) const = 0;
    virtual bool visitChildren( const void * base, const char *path,
        WatcherPathRequest & pathRequest ) { return false; }
    virtual bool addChild( const char * path, WatcherPtr pChild,
        void * withBase = NULL ) { return false; }
    // ...
};
```

关键概念:

- **`base`**:基址指针。Watcher 通过 `base + 偏移` 寻址变量,这样同一个 Watcher 可以为多个对象服务——例如 `MemberWatcher` 持有成员函数指针,通过 `base` 切换不同对象。
- **`path`**:相对路径。空字符串表示"当前 Watcher 自己";非空字符串以 `/` 分隔,递归向下查找。
- **`Mode`**:声明此 Watcher 是只读、读写、目录还是可调用。

### 3.7.3 Watcher 路径系统

所有 Watcher 都注册在全局根 Watcher 下,路径用 `/` 分隔,形如 Unix 文件系统:

```
"network/entities/numEntities"
"network/bandwidthIn"
"components/cellApp1/foo/bar"
"version/string"
```

`WATCHER_SEPARATOR = '/'` 定义了分隔符。`DirectoryWatcher::tail(path)` 返回路径中第一个 `/` 之后的部分,用于递归下降查找。

`partitionPath(path, name, dir)` 把 `"a/b/c"` 切分为尾名 `"c"` 与目录 `"a/b"`,用于注册新 Watcher 时找到父节点。

### 3.7.4 五种 Watcher 模式

#### 数据监听(DataWatcher)

最简单的形式,直接监听一个变量:

```cpp
static int g_maxConnections = 1000;
MF_WATCH( "network/maxConnections", g_maxConnections, Watcher::WT_READ_WRITE );
```

`MF_WATCH` 宏等价于 `BW::addWatcher`,内部会创建 `DataWatcher<int>` 并注册到根 Watcher。`WT_READ_WRITE` 表示可读可写;若想只读,改为 `WT_READ_ONLY`。`addWatcher` 还接受可选注释参数,通过 Watcher 接口可见。

#### 成员监听(MemberWatcher)

监听对象的成员函数(典型为 getter/setter 对):

```cpp
class ServerConnection {
public:
    uint32 bandwidthFromServer() const;
    void   bandwidthFromServer( uint32 val );
};
ServerConnection g_server;

MF_WATCH( "Comms/Desired in", g_server,
    MF_ACCESSORS( uint32, ServerConnection, bandwidthFromServer ) );
```

`MF_ACCESSORS(TYPE, CLASS, METHOD)` 宏展开为两个 `static_cast`,从重载的 `bandwidthFromServer` 中分别取出 const 与非 const 版本,然后 `MemberWatcher` 通过成员函数指针调用它们。`MF_ACCESSORS_EX(TYPE, CLASS, GET_METHOD, SET_METHOD)` 用于 getter/setter 名字不同的情况。

#### 函数监听(FunctionWatcher)

监听全局函数的返回值:

```cpp
uint32 getCurrentFps();
MF_WATCH( "render/fps", getCurrentFps );
```

#### 序列监听(SequenceWatcher)

监听整个序列:

```cpp
BW::vector<Entity*> g_entities;
MF_WATCH( "entities", g_entities, ... );  // 伪代码,实际需用 SequenceWatcher
```

`SequenceWatcher<SEQ>` 通过 `SEQ::iterator` 遍历序列,允许通过 `"entities/0"`、`"entities/1"` 这样的索引路径访问单个元素,也支持用标签(`labels_`)或自定义索引转换器(`indexToString_` / `stringToIndex_`)。

#### 映射监听(MapWatcher)

类似 `SequenceWatcher`,但针对 `BW::map` / `BW::unordered_map`,通过 key 而非索引访问:`"players/Player1234/health"`。

#### 可调用(CallableWatcher)

允许远程触发函数:

```cpp
class MyComponent {
    bool reloadConfig( BW::string & output, BW::string & value );
};
NoArgFuncCallableWatcher w( &MyComponent::reloadConfig, CallableWatcher::LOCAL_ONLY,
                            "Reload configuration from disk" );
```

`CallableWatcher` 支持参数描述(`addArg(type, desc)`),可用于生成 RPC 接口文档。`ExposeHint` 控制调用范围:

- `LOCAL_ONLY`:仅本机可调
- `WITH_ENTITY`:在指定 entity 上调
- `WITH_SPACE`:在指定 space 上调
- `ALL`:广播到所有进程
- `LEAST_LOADED`:挑负载最低的进程调

### 3.7.5 装饰器(Decorator)Watcher

`SafeWatcher`、`ReadWriteLockWatcher`、`DereferenceWatcher`、`AbsoluteWatcher`、`FreezeWatcher` 都是"装饰器"——它们包装另一个 Watcher,添加额外行为(加锁、解引用、绝对地址、冻结值)。这是经典的装饰器模式(Decorator Pattern),允许在不修改原 Watcher 的前提下组合出新的行为。

例如 `SafeWatcher` 在每次调用前后获取/释放 `SimpleMutex`,保证线程安全:

```cpp
class SafeWatcher : public Watcher
{
public:
    SafeWatcher( WatcherPtr watcher, SimpleMutex & mutex );
    // 重写所有方法,内部加锁后转发给 pWatcher_
private:
    WatcherPtr pWatcher_;
    SimpleMutex & mutex_;
    mutable int grabCount_;
};
```

### 3.7.6 流协议(v2)

`getAsString` / `setFromString` 是早期协议(协议 v1),只支持字符串。协议 v2 通过 `getAsStream` / `setFromStream` 使用二进制流,效率更高且支持更多类型:

```cpp
enum WatcherDataType {
    WATCHER_TYPE_UNKNOWN = 0,
    WATCHER_TYPE_INT, WATCHER_TYPE_UINT, WATCHER_TYPE_FLOAT,
    WATCHER_TYPE_BOOL, WATCHER_TYPE_STRING, WATCHER_TYPE_TUPLE, WATCHER_TYPE_TYPE
};
```

`watcherValueToStream<T>(stream, value, mode)` 是模板函数,针对 `int`、`float`、`bool`、`BW::string` 等特化,把 `[类型][模式][长度][值]` 写入流。这样接收端能正确解析,且能检测类型不匹配。

### 3.7.7 与 bwmachined / watcher_html 集成

bwmachined 是 BigWorld 的服务器守护进程(详见第 8 章),它监听一个固定端口,接受来自 watcher_html(Web 控制台)或 bwtool(命令行工具)的查询请求。请求格式:

```
GET /watcher/network/maxConnections
SET /network/maxConnections 2000
LIST /entities/
```

bwmachined 把请求路由到对应进程,该进程内的 `Watcher::rootWatcher()` 递归查找路径,返回值或调用函数。这意味着运维只需一台浏览器即可管理整个集群——这正是 Watcher 系统设计的核心价值。

### 3.7.8 使用示例

下面是一个完整的示例,展示几种典型用法:

```cpp
// 1. 监听全局变量
static int g_numEntities = 0;
MF_WATCH( "entities/numTotal", g_numEntities, Watcher::WT_READ_ONLY );

// 2. 监听对象的成员函数(只读)
class CellApp : public Singleton<CellApp> {
public:
    uint32 numCells() const;
    float  avgLoad() const;
};
MF_WATCH( "cells/numCells", CellApp::instance(),
    MF_ACCESSORS( uint32, CellApp, numCells ) );
MF_WATCH( "cells/avgLoad", CellApp::instance(),
    MF_ACCESSORS( float, CellApp, avgLoad ) );

// 3. 可调用的远程命令
bool reloadConfig( BW::string & output, BW::string & value ) {
    // 重新加载配置文件
    output = "Config reloaded";
    return true;
}
new NoArgFuncCallableWatcher( &reloadConfig,
    CallableWatcher::LOCAL_ONLY, "Reload configuration" );

// 4. 监听序列(BW::vector)
class Entity { public: int id; float health; };
BW::vector<Entity*> g_entities;
// 在 init 时:
WatcherPtr pSeqWatcher = new SequenceWatcher< BW::vector<Entity*> >( g_entities );
pSeqWatcher->addChild( "id", makeWatcher( &Entity::id ) );  // 子项
pSeqWatcher->addChild( "health", makeWatcher( &Entity::health ) );
Watcher::rootWatcher().addChild( "entities/list", pSeqWatcher );
```

注意 `ENABLE_WATCHERS` 关闭时,`MF_WATCH` 退化为空宏,上述代码在编译期完全消失,生产环境零开销:

```cpp
#else // ENABLE_WATCHERS
    #define MF_WATCH( ... )
    #define MF_WATCH_REF( ... )
#endif
```

---

## 3.8 Singleton 模板深入

### 3.8.1 实现剖析

`Singleton<T>`(`singleton.hpp`)是 BigWorld 用的单例基类,实现极简但有几个微妙之处:

```cpp
template <class T>
class Singleton
{
protected:
    static T * s_pInstance;
public:
    Singleton()
    {
        MF_ASSERT( NULL == s_pInstance );   // 防止重复构造
        s_pInstance = static_cast< T * >( this );
        REGISTER_SINGLETON_FUNC( T, &T::pInstance );
    }
    ~Singleton()
    {
        MF_ASSERT( this == s_pInstance );  // 防止误析构
        s_pInstance = NULL;
    }
    static T & instance()
    {
        T * instanceP = pInstance();
        MF_ASSERT( instanceP );
        return *instanceP;
    }
    static T * pInstance()
    {
        SINGLETON_MANAGER_WRAPPER_FUNC( T, &T::pInstance )
        return s_pInstance;
    }
};
```

使用方式:

```cpp
// MyApp.hpp
class MyApp : public Singleton< MyApp >
{
    // ...
};

// MyApp.cpp
BW_SINGLETON_STORAGE( MyApp )   // 必须在 .cpp 中,定义静态成员

// 使用
MyApp app;                       // 实例化,自动注册为单例
MyApp * pApp = MyApp::pInstance();
MyApp & app = MyApp::instance();
```

`BW_SINGLETON_STORAGE(TYPE)` 宏展开为静态成员 `s_pInstance` 的定义,这是模板静态成员必须显式定义的标准做法(Intel Compiler 用不同的语法,因此有 `__INTEL_COMPILER` 分支)。

### 3.8.2 与 Meyers Singleton 的区别

C++11 起,局部静态变量的初始化是线程安全的("Meyers Singleton"):

```cpp
static T & instance() {
    static T s_instance;
    return s_instance;
}
```

但 BigWorld 选择 CRTP(Curiously Recurring Template Pattern)+ 显式构造的方案,理由有三:

1. **生命周期可控**:Meyers Singleton 的析构发生在 `atexit` 阶段,顺序是构造的逆序,跨翻译单元时不可预测。BigWorld 方案要求显式构造(如全局变量或 main 中局部变量),析构顺序由 C++ 对象语义保证。
2. **可注入依赖**:测试时可以构造一个 mock 子类,把它设为单例——Meyers Singleton 做不到这点。
3. **历史原因**:BigWorld 早于 C++11,而 CRTP 方案在 C++03 也工作。

### 3.8.3 线程安全性

注意 `Singleton` 本身**不**保证线程安全:

- 构造函数不是原子的(写入 `s_pInstance` + 调用 `REGISTER_SINGLETON_FUNC`)。
- `pInstance()` 直接读 `s_pInstance`,没有内存屏障。

因此 BigWorld 的约定是:**单例必须在单线程的初始化阶段构造**。典型做法是把单例对象作为 `ServerApp` 等进程级对象的成员,在 main 函数中构造。这样所有后续线程访问时,`s_pInstance` 早已稳定。

如果单例必须延迟初始化,需要额外的双重检查锁定(`DCLP`)或 `pthread_once`——`cstdmf` 没有提供这样的辅助类,因为 BigWorld 倾向于"启动时构造"风格。

### 3.8.4 SingletonManager:跨 DLL 单例寻址

`SINGLETON_MANAGER_WRAPPER_FUNC` 宏在 `singleton_manager.hpp` 中:

```cpp
#define SINGLETON_MANAGER_WRAPPER_FUNC( Type, Func )\
    SingletonManager::InstanceFunc pFunc;\
    if (SingletonManager::instance().isRegisteredFunc< Type >( pFunc, Func ) == false)\
    {\
        return SingletonManager::instance().executeFunc( pFunc, Func, Func );\
    }
```

它的作用是:当一个进程内多个 DLL 都定义了 `MyApp::instance()`(因为它们各自链接了 `cstdmf`),`SingletonManager` 会确保所有调用都路由到"最先注册"的那个 `instance` 函数。这避免了"每个 DLL 看到的 `MyApp` 单例都不一样"的灾难。

`SingletonManager` 通过 `typeid(T).name()` 作为 key 在 `unordered_map` 中查找已注册的 `instance` 函数指针。当 `ENABLE_SINGLETON_MANAGER` 关闭时,这些宏退化为空,`pInstance()` 直接返回 `s_pInstance`,性能零损耗。

### 3.8.5 在 BigWorld 中的应用

`Singleton<T>` 在引擎中有广泛应用,几乎每个进程级组件都继承自它:

- 客户端:`InputDevices`、`AnimationManager`、`EffectManager`、`Renderer`、`SoundManager`、`NodeCatalogue`、`LensEffectManager`、`BWResource`
- 服务器:`BaseApp`、`BaseAppMgr`、`CellAppMgr`、`DBAppMgr`、`TransferDB`、`Reviver`、`LoginApp`
- 工具:`UalManager`、`gizmo::Environment`、`guitabs::Manager`

以 `Reviver` 为例(`server/reviver/reviver.hpp`):

```cpp
class Reviver : public ServerApp, public TimerHandler,
    public Singleton< Reviver >
{
    // ...
};
```

它同时继承 `ServerApp`(进程抽象)、`TimerHandler`(定时器回调)、`Singleton<Reviver>`,然后通过 `Reviver::instance()` 在任意位置访问。这是 BigWorld 标准的服务器进程骨架。

---

## 3.9 math 库概述

### 3.9.1 位置与职责

`math` 库位于 `programming/bigworld/lib/math/`,提供游戏开发所需的基础数学类型:

- 向量:`Vector2`、`Vector3`、`Vector4`
- 矩阵:`Matrix`(4×4)
- 四元数:`Quaternion`
- 包围盒:`AABB`、`BoundingBox`、`OrientedBBox`
- 几何体:`PlaneEq`(平面)、`Sphere`(球体)、`Polygon`(多边形)、`Polyhedron`(多面体)
- 辅助:`Angle`(角度)、`Colour`(颜色)、`RectT`(矩形)、`Range1DT`(1D 范围)、`LineEq`(直线)、`LineEq3`(3D 直线)、`Portal2D`(2D 入口)
- 工具:`LinearLUT`(线性查找表)、`EMA`(指数移动平均)、`SMA`(简单移动平均)、`LooseOctree`(松散八叉树)、`PerlinNoise`/`SimplexNoise`(噪声)
- 杂项:`mathdef.hpp`(常量与工具函数)、`xp_math.hpp`(跨平台基础)、`math_lib.hpp`(聚合头)

### 3.9.2 核心类型一览

#### Vector3

`Vector3` 继承自 `Vector3Base`(`D3DXVECTOR3` 在 Windows 上,自定义结构在非 Windows):

```cpp
class BWENTITY_API Vector3 : public Vector3Base
{
public:
    Vector3();
    Vector3( float a, float b, float c );
    explicit Vector3( const Vector3Base & v );
#ifdef _WIN32
    Vector3( __m128 v4 );   // 从 SSE 寄存器构造
#endif

    void setZero();
    void set( float a, float b, float c );
    void setPitchYaw( float pitchInRadians, float yawInRadians );

    float dotProduct( const Vector3& v ) const;
    void crossProduct( const Vector3& v1, const Vector3& v2 );
    Vector3 crossProduct( const Vector3 & v ) const;
    void lerp( const Vector3 & a, const Vector3 & b, float t );

    INLINE float length() const;
    INLINE float lengthSquared() const;
    INLINE void normalise();
    INLINE Vector3 unitVector() const;

    float yaw() const;
    float pitch() const;

    static const Vector3 ZERO;  // (0,0,0)
    static const Vector3 I;     // (1,0,0)
    static const Vector3 J;     // (0,1,0)
    static const Vector3 K;     // (0,0,1)
};
```

注意几点:

- **默认构造函数不初始化**——这是性能考量,因为大量 `Vector3` 作为局部变量使用,初始化为零会浪费 CPU。需要零向量请用 `Vector3::zero()` 或 `setZero()`。
- **`__m128` 构造函数**:Windows 下支持从 SSE 寄存器构造,允许 SIMD 优化的代码直接传递向量。
- **`operator float*`**:虽然注释明确说"这是为了 workaround d3dx9 的 bug",但仍提供了 `float*` 隐式转换,以便与遗留 API 兼容。
- **`INLINE` 宏**:不是 `inline` 关键字,而是由 `CODE_INLINE` 控制的宏——在 `vector3.ipp` 顶部展开为 `inline` 或空,决定函数是真正 inline 还是只在 `.cpp` 中定义一次。

#### Matrix

`Matrix` 是 4×4 矩阵,继承自 `MatrixBase`(同样在 Windows 上是 `D3DXMATRIX`):

```cpp
class Matrix : public MatrixBase
{
public:
    Matrix();
    void setZero();
    void setIdentity();
    void setScale( const Vector3 & scale );
    void setTranslate( const Vector3 & pos );
    void setRotateX( const float angle );
    void setRotate( const Quaternion & q );
    void multiply( const Matrix& m1, const Matrix& m2 );
    void invertOrthonormal( const Matrix& m );   // 正交矩阵快速求逆
    bool invert( const Matrix& m );               // 通用求逆
    void transpose( const Matrix & m );
    void lookAt( const Vector3& position, const Vector3& direction, const Vector3& up );
    Vector3 applyPoint( const Vector3& v2 ) const;
    Vector3 applyVector( const Vector3& v2 ) const;
    void perspectiveProjection( float fov, float aspectRatio, float nearPlane, float farPlane );
    // ...
};
```

`typedef Matrix Matrix34; typedef Matrix Matrix44;` 显示虽然内部是 4×4,但 BigWorld 把它同时用作 3×4(仿射)和 4×4(投影)。`applyPoint` 与 `applyVector` 的区别就在于前者考虑平移(w=1),后者不考虑(w=0)。

#### Quaternion

`Quaternion` 用于表示无万向锁的三维旋转,内部存储为 `x, y, z, w`:

```cpp
class Quaternion : public QuaternionBase
{
public:
    Quaternion();
    Quaternion( const Matrix &m );       // 从矩阵构造
    Quaternion( float x, float y, float z, float w );
    Quaternion( const Vector3 &v, float w );
    void fromAngleAxis( float angle, const Vector3 &axis );
    void fromMatrix( const Matrix &m );
    void normalise();
    void invert();
    void minimise();                     // 取双覆盖中的较小者
    void slerp( const Quaternion& qStart, const Quaternion &qEnd, float t );
    void multiply( const Quaternion& q1, const Quaternion& q2 );
    // ...
};
```

`slerp`(球面线性插值)是动画系统的核心——骨骼动画在两帧之间用 `slerp` 插值。`minimise` 处理四元数的"双覆盖"问题:`q` 与 `-q` 表示同一旋转,但 `slerp` 时若两端符号相反会绕远路,`minimise` 把当前四元数翻转到与参考最接近的版本。

#### AABB / BoundingBox

`AABB`(Axis-Aligned Bounding Box,轴对齐包围盒)是空间分割、碰撞检测的基础:

```cpp
class AABB
{
public:
    AABB();
    AABB( const Vector3 & min, const Vector3 & max );
    const Vector3 & minBounds() const;
    const Vector3 & maxBounds() const;
    void setBounds( const Vector3 & min, const Vector3 & max );
    void addBounds( const Vector3 & v );          // 扩展以包含点
    void addBounds( const AABB & bb );            // 扩展以包含另一 AABB
    void transformBy( const Matrix & transform ); // 变换后重新计算包围
    bool intersects( const AABB & box ) const;
    bool intersects( const Vector3 & v ) const;
    bool intersectsRay( const Vector3 & origin, const Vector3 & dir ) const;
    enum RayIntersectionType { NO_INTERSECTION, ORIGIN_INSIDE, INTERSECTION };
    RayIntersectionType intersectsRay( const Vector3 & origin,
        const Vector3 & dir, Vector3 & coord ) const;
    bool clip( Vector3 & start, Vector3 & extent, float bloat = 0.f ) const;
    float distance( const Vector3& point ) const;
    Vector3 centre() const;
    bool insideOut() const;
protected:
    Vector3 min_, max_;
};

class BoundingBox : public AABB
{
    // 额外的 Outcode 用于裁剪
};
```

`BoundingBox` 继承自 `AABB`,添加了 `Outcode`(裁剪码,见 `mathdef.hpp` 中的 `OUTCODE_LEFT` 等)用于视锥裁剪加速。`s_insideOut_` 是一个特殊实例,表示"反向"包围盒(min > max),常作为"无效"标志。

#### PlaneEq

`PlaneEq` 用法向量 + 距离表示平面(`n·p + d = 0`):

```cpp
class PlaneEq
{
public:
    enum ShouldNormalise { SHOULD_NORMALISE, SHOULD_NOT_NORMALISE };
    PlaneEq( const Vector3 & v0, const Vector3 & v1, const Vector3 & v2,
        ShouldNormalise normalise = SHOULD_NORMALISE );
    float distanceTo( const Vector3 & point ) const;
    bool isInFrontOf( const Vector3 & point ) const;
    Vector3 intersectRay( const Vector3 & source, const Vector3 & dir ) const;
    LineEq intersect( const PlaneEq & slice ) const;  // 两平面交线
    void basis( Vector3 & xdir, Vector3 & ydir ) const;
    Vector2 project( const Vector3 & point ) const;
    // ...
private:
    Vector3 normal_;
    float d_;
};
```

注意构造函数接受三个点构造平面,顺序决定法向量方向;`SHOULD_NORMALISE` 控制是否单位化法向量(单位化后 `distanceTo` 才是真正的欧氏距离)。

### 3.9.3 辅助几何类型

#### Sphere

```cpp
class Sphere
{
public:
    Sphere();
    Sphere( const Vector3& center, float radius );
    explicit Sphere( const AABB& bb );   // 包围 AABB 的最小球
    bool intersect( const Vector3& origin, const Vector3& travel ) const;
private:
    Vector3 center_;
    float radius_;
};
```

#### Polygon / Polyhedron

`Polygon<PointType>` 是模板,通常 `PointType = Vector2`。提供 `intersects(otherPolygon)`,使用分离轴定理(SAT)检测两凸多边形相交。

`Polyhedron` 是 3D 多面体,由一组平面定义,可用于凸体碰撞、视锥裁剪。`ConvexHull`(凸包)与 `FrustumHull`(视锥凸包)是其变体。

#### Portal2D

`Portal2D` 表示 2D 入口,用于室内场景(portal-based rendering)中房间之间的可见性传递。

#### LooseOctree

`LooseOctree` 是松散八叉树——一种允许对象跨越多个子节点边界的空间划分结构,避免对象在边界附近频繁迁移。它广泛用于实体的空间查询。

### 3.9.4 辅助数学工具

#### angle.hpp

`Angle` 类自动归一化到 `[-π, π]`,避免角度累加导致的精度问题:

```cpp
class Angle
{
public:
    Angle( float valueInRadians );
    operator float () const;
    static float normalise( float value );
    static float decay( float src, float dst, float halfLife, float dTime );
    static float sameSignAngle( float angle, float closest );
    static float turnRange( Angle from, Angle to );
};
```

`sameSignAngle` 把 `angle` 调整为与 `closest` 同号(用于插值),`turnRange` 计算从 `from` 到 `to` 的最小旋转范围。

#### colour.hpp

`Colour` 是 RGBA 颜色,提供与 `uint32` 的相互转换、HSV/RGB 转换等。

#### rectt.hpp

`RectT<T>` 是矩形模板,常用于 `RectT<int>`(像素矩形)与 `RectT<float>`(UV 矩形)。

#### range1dt.hpp

`Range1DT<Coordinate>` 是 1D 范围模板,提供 `intersects`、`contains`、`distTo` 等方法,常用于时间区间、参数区间等。

#### lineeq.hpp / lineeq3.hpp

`LineEq` 是 2D 直线(用点 + 方向表示),`LineEq3` 是 3D 直线。

#### linear_lut.hpp

`LinearLUT`(Linear Look-Up Table)是带边界条件的可插值查找表:

```cpp
class LinearLUT
{
public:
    enum BoundaryCondition {
        BC_ZERO,                // 范围外返回 0
        BC_CONSTANT_EXTEND,    // 范围外取端点值
        BC_WRAP,               // 范围外环绕
        BC_LINEAR_EXTEND       // 范围外线性外推
    };
    float operator()(float x) const;     // 线性插值查询
    void data(BW::vector<Vector2> const &d);
    // ...
private:
    BW::vector<Vector2> data_;
    BoundaryCondition lowerBC_, upperBC_;
    mutable size_t cachedPos_;          // 缓存上次查询位置,加速顺序访问
};
```

`cachedPos_` 是经典优化:由于 LUT 通常被顺序访问,缓存上次位置能跳过二分查找。

#### ema.hpp

`EMA`(Exponential Moving Average,指数移动平均)用一行公式更新:

```cpp
void sample( float value )
{
    average_ = (1.f - bias_) * value + bias_ * average_;
}
```

`bias` 越接近 1,新样本权重越低,平滑度越高但响应越慢。`highWaterSample` 是变体:仅在样本超过当前平均时直接重置,否则正常 EMA——常用于"峰值追踪"。

`AccumulatingEMA<T>` 是累积版:累积一段时间后再采样到 EMA,适合"每秒采样一次 IO 字节数"这类需求。

#### sma.hpp

`SMA<T>`(Simple Moving Average,简单移动平均)维护一个滑动窗口:

```cpp
template<class T> class SMA
{
public:
    SMA(int period);
    void append(T value);
    T average() const;
    T min() const;
    T max() const;
private:
    int period_;
    T* samples_;
    T total_;        // 当前窗口总和,O(1) 求平均
    int count_;
    int pos_;
};
```

`total_` 维护窗口内所有样本的和,`append` 时减去离开窗口的样本、加上新样本,使 `average()` 是 O(1)——这是滑动窗口求平均的经典优化。

### 3.9.5 xp_math.hpp:跨平台数学适配

`xp_math.hpp` 是 math 库的"平台适配层"。在 Windows 客户端(`_WIN32 && !BWENTITY_DLL`),它直接 typedef `D3DXMATRIX`、`D3DXVECTOR3` 等为基础类型,并定义了一组 `XP*` 宏(`XPVec3Length`、`XPMatrixMultiply` 等)映射到 D3DX 函数。在非 Windows 平台,它定义自己的基础结构:

```cpp
struct BWENTITY_API Vector3Base
{
    Vector3Base() {};
    Vector3Base( float _x, float _y, float _z ) : x( _x ), y( _y ), z( _z ) {}
    operator float *()             { return (float *)&x; }
    operator const float *() const  { return (float *)&x; }
    float x, y, z;
};
```

并提供等价的 `XP*` 宏映射到 `Vector3::length()` 等成员函数。这种"宏统一接口"的设计使得上层代码可以用 `XPVec3Length(&v)` 在所有平台工作,而底层实现自动切换。

`USE_XG_MATH` 是 Xbox 360 的特殊路径,使用 `XGMath` 库(微软为 Xbox 提供的数学库)。

---

## 3.10 数学库设计要点

### 3.10.1 为什么不用 DirectXMath

DirectXMath(及其前身 D3DXMath)是 Windows 平台优秀的 SIMD 数学库,但 BigWorld 选择**只在 Windows 客户端使用 D3DX**,在 Linux 服务器、macOS 工具等平台使用自定义实现。原因有三:

1. **跨平台需求**:BigWorld 服务器运行在 Linux,工具运行在 macOS,这些平台没有 D3DX。`xp_math.hpp` 的非 Windows 分支保证代码一致。
2. **历史包袱**:`math` 库比 DirectXMath 早很多年,D3DX 是后来的适配。
3. **服务器性能要求不同**:服务器不需要 SIMD 优化的矩阵运算(没有渲染),简单实现就足够。

但 BigWorld 仍然**在客户端使用 D3DX** 是为了利用其 SSE 优化——`Vector3(__m128)` 构造函数就是为此预留的。

### 3.10.2 模板与内联的实现选择

`math` 库大量使用模板与内联,关键设计如下:

- **CRTP 而非虚函数**:`Vector3` 没有 virtual 函数,所有方法都是 inline 的。这避免了虚表开销,使得 `v1.dotProduct(v2)` 编译为几条 SSE 指令。
- **`INLINE` 宏**:`vector3.ipp` 等内联实现文件顶部定义:
  ```cpp
  #ifdef CODE_INLINE
      #define INLINE inline
  #else
      #define INLINE
  #endif
  ```
  `CODE_INLINE` 由构建系统控制。开启时所有函数 inline,关闭时函数只在 `.cpp` 中定义一次(非 inline),便于调试器单步执行。
- **`.ipp` 文件**:内联实现的分离文件。`vector3.hpp` 在末尾 `#ifdef CODE_INLINE #include "vector3.ipp" #endif`,`vector3.cpp` 在 `#ifndef CODE_INLINE #include "vector3.ipp" #endif`。这种双路包含保证无论是否 inline,函数都只被定义一次。

### 3.10.3 .ipp 文件的作用

`.ipp` 文件是 BigWorld 处理"模板与内联函数实现分离"的统一约定:

- **`.hpp`**:声明接口,被外部代码包含。
- **`.ipp`**:内联实现,可能被 `.hpp` 包含(若 `CODE_INLINE`)或被 `.cpp` 包含(否则)。
- **`.cpp`**:非内联实现,以及静态成员定义。

好处:

- 头文件保持简洁,只读声明。
- 实现可被多个翻译单元共享。
- 通过 `CODE_INLINE` 开关可在 "inline 全开" 与 "便于调试" 间切换。

这种模式在 math 库中尤为常见:`vector3.ipp`、`matrix.ipp`、`quat.ipp`、`boundbox.ipp`、`planeeq.ipp`、`angle.ipp`、`lineeq.ipp`、`portal2d.ipp`、`range1dt.ipp`、`loose_octree.ipp`、`stat_with_rates_of_change.ipp` 等都遵循此约定。

### 3.10.4 与渲染库 moo 的协作

`moo`(`lib/moo/`,第 6 章会详述)是 BigWorld 的渲染库,它直接消费 `math` 库的类型:

- `Moo::VertexXYZ` 等顶点结构直接使用 `Vector3`。
- `Moo::Effect` 的 shader 参数设置接受 `Matrix`、`Vector4`。
- `Moo::Camera` 用 `Matrix` 表示视图/投影矩阵。
- `Moo::Texture` 的 UV 用 `RectT<float>`(即 `Rectf`)。

由于 `Vector3` 在 Windows 上**就是** `D3DXVECTOR3`(通过 `Vector3Base`),它可以零成本传递给 D3D9 API。这种"既是 BigWorld 类型又是 D3D 类型"的双重身份,是 math 库与 moo 库紧密协作的基石。

但在非 Windows 平台,`Vector3Base` 是自定义结构,虽然有 `operator float*` 转换,但不能直接传给 D3D9——好在非 Windows 平台也没有 D3D9,使用 OpenGL/Vulkan 时通过 `float*` 转换传递即可。

### 3.10.5 math_lib.hpp:聚合头

`math_lib.hpp` 是 math 库的聚合头,引入核心类型:

```cpp
#include "math/boundbox.hpp"
#include "math/mathdef.hpp"
#include "math/matrix.hpp"
#include "math/planeeq.hpp"
#include "math/vector2.hpp"
#include "math/vector3.hpp"
#include "math/vector4.hpp"
```

业务代码通常 `#include "math/math_lib.hpp"` 一次性获得所有核心类型。`Quaternion` 没有被聚合,因为它的依赖较重(`Matrix`),只在需要时引入。

### 3.10.6 噪声与八叉树

`math` 库还提供两类高级设施:

- **`PerlinNoise` / `SimplexNoise`**:用于地形、纹理、动画的程序化噪声。Perlin 是经典实现,Simplex 是改进版(更快、维度无关)。
- **`LooseOctree`**:松散八叉树,允许对象跨越边界,常用于实体空间管理。

### 3.10.7 移动平均的应用场景

`EMA` 与 `SMA` 在引擎中应用广泛:

- **网络**:RTT 估计用 EMA,过滤抖动。
- **帧率**:`FPS` 用 SMA,稳定显示。
- **负载均衡**:服务器负载用 EMA,平滑波动。
- **流量控制**:带宽估计用 EMA。

`AccumulatingEMA` 特别适合"每帧累积、每秒采样"模式——比如统计每秒收到的网络包数。

---

## 3.11 本章小结

本章深入剖析了 BigWorld Engine 14.4.1 的两个基础设施库:

### cstdmf 关键点

1. **容器适配器**(`bw_*.hpp`):薄封装 STL,植入 `StlAllocator`,统一接入 `BW::Allocator`,使内存追踪成为可能。
2. **内存管理**(`bw_memory` + `Allocator` + `StlAllocator`):三层架构,顶层接口 + 中层调度 + 底层实现,支持调试钩子、固定池、对齐分配。
3. **调试诊断**:`LogMsg` 分级消息、`DogWatch` 帧内计时、`Profiler` 性能分析、`callstack` 调用栈——四大工具链通过 `ENABLE_*` 宏动态启停。
4. **Watcher 系统**:BigWorld 独有的运行时观察/修改/RPC 系统,通过路径树 + 多种 Watcher 子类(`DataWatcher`、`MemberWatcher`、`FunctionWatcher`、`SequenceWatcher`、`MapWatcher`、`CallableWatcher`)与装饰器(`SafeWatcher`、`DereferenceWatcher`)实现灵活的远程 introspection。
5. **Singleton 模板**:CRTP + 显式构造 + `SingletonManager` 跨 DLL 路由,避免 Meyers Singleton 的析构顺序问题,同时支持测试时注入 mock。
6. **作用域守卫**(`BW_GUARD`):不仅是锁,更是栈追踪标记,与 `StackTracker`、`Profiler`、`MemTracker` 协同工作。

### math 关键点

1. **核心类型**:`Vector3`、`Matrix`、`Quaternion`、`AABB`、`PlaneEq` 是五大基础类型,服务于渲染、物理、动画、空间管理。
2. **跨平台适配**(`xp_math.hpp`):Windows 用 D3DX,其他平台用自定义结构,通过 `XP*` 宏统一接口。
3. **模板与内联**:CRTP 避免虚函数,`INLINE` 宏 + `.ipp` 文件实现 inline/非 inline 切换,既性能优先又便于调试。
4. **辅助工具**:`EMA`/`SMA` 移动平均、`LinearLUT` 插值查找表、`Angle` 自动归一化角度、`LooseOctree` 松散八叉树——这些是上层模块频繁使用的实用工具。
5. **与 moo 协作**:Windows 下 `Vector3` 即 `D3DXVECTOR3`,可零成本传递给 D3D9,这是 math 与渲染库紧密耦合的根源。

### 阅读建议

- **第一遍**:先读 `cstdmf/singleton.hpp`、`cstdmf/watcher.hpp` 的注释和顶部文档,理解两大特色设施的设计意图。
- **第二遍**:阅读 `bw_vector.hpp`、`bw_memory.hpp`、`allocator.hpp`,建立内存从顶到底的链路认知。
- **第三遍**:阅读 `math/vector3.hpp` + `vector3.ipp` + `vector3.cpp`,理解 `.hpp/.ipp/.cpp` 三段式约定。
- **进阶**:阅读 `watcher.cpp`、`profiler.cpp` 的实现,体会"调试系统本身如何被调试"。

理解了 `cstdmf` 与 `math`,你就掌握了 BigWorld Engine 的"字母表"——后续章节涉及的任何模块,无论是 `resmgr`、`moo`、`network`,还是 `server/` 下的进程,都会反复使用本章介绍的类型、宏、模板。建议读者在阅读后续章节时,遇到不熟悉的 `BW::` 类型或 `MF_*` 宏,回过头来查阅本章相应小节。

下一章我们将进入 `lib/resmgr/`,看看资源管理系统是如何在 `cstdmf` 提供的 `BW::string`、`BW::vector`、`SmartPointer`、`Watcher` 之上构建出一套路径透明、格式无关、懒加载、可缓存的资源抽象的。
