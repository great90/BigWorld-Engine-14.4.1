# BigWorld 工具 editor_shared 实现深度分析

> 本文档详细分析 BigWorld Engine 14.4.1 中 `tools/editor_shared` 目录的实现。该目录构建为 `editor_shared` 静态库,是 BigWorld 工具链的 **GUI 后端抽象层**,通过 `IEditorApp`/`IMainFrame`/`IMenuHelper` 等抽象接口隔离工具逻辑与具体 GUI 后端(MFC/QT),并提供 `MenuHelper`/`WaitCursor`/`Cursor`/`BWFileDialog`/`FolderGuard`/`MessageBox` 等通用 GUI 工具。本文档涵盖双后端架构、抽象接口设计、MFC 实现、QT 移植现状(不完整)、RAII 工具类、构建配置等核心机制。

---

## 目录

- [一、整体架构概览](#一整体架构概览)
- [二、源码目录结构](#二源码目录结构)
- [三、库的构建与被链接方式](#三库的构建与被链接方式)
- [四、核心类与继承关系](#四核心类与继承关系)
- [五、关键算法与数据结构](#五关键算法与数据结构)
- [六、配置项与命令行参数](#六配置项与命令行参数)
- [七、与其他模块的依赖关系](#七与其他模块的依赖关系)
- [八、关键代码片段](#八关键代码片段)
- [九、设计亮点与注意事项](#九设计亮点与注意事项)

---

## 一、整体架构概览

### 1.1 editor_shared 在工具链中的定位

`editor_shared` 是 BigWorld 工具链的 **GUI 后端抽象层**,职责:

1. 定义编辑器应用抽象接口(`IEditorApp`:isMinimized/onIdle)
2. 定义主框架抽象接口(`IMainFrame`:getEditorView/setMessageText/setStatusText/cursorOverGraphicsWnd/updateGUI/currentCursorPosition/getWorldRay/grabFocus)
3. 定义菜单操作抽象接口(`IMenuHelper`,通过 guimanager 库)
4. 提供 MFC 后端实现(`MenuHelper`/`WaitCursor`/`Cursor`/`BWFileDialog`/`MessageBox`)
5. 提供文件对话框(`BWFileDialog`,封装 MFC `CFileDialog` 并保持当前目录)
6. 提供 RAII 工具(`WaitCursor` 等待光标、`FolderGuard` 目录守卫)
7. 提供 GUI 标签页内容接口(`GuiTabContent`)
8. 支持 MFC/QT 双后端切换(通过 `BW_IS_QT_TOOLS` CMake 选项)

### 1.2 双后端架构拓扑

```
┌──────────────────────────────────────────────────────────────────┐
│                  editor_shared 静态库                            │
│                                                                  │
│  ┌──────────────────── 抽象层(头文件,后端无关) ──────────────┐ │
│  │  app/i_editor_app.hpp      (IEditorApp)                    │ │
│  │  gui/i_main_frame.hpp      (IMainFrame)                    │ │
│  │  cursor/cursor.hpp         (Cursor)                        │ │
│  │  cursor/wait_cursor.hpp    (WaitCursor)                    │ │
│  │  dialogs/file_dialog.hpp   (BWFileDialog)                  │ │
│  │  dialogs/folder_guard.hpp  (FolderSetter/FolderGuard)      │ │
│  │  dialogs/message_box.hpp   (MessageBox)                    │ │
│  │  pages/gui_tab_content.hpp (GuiTabContent)                 │ │
│  └────────────────────────────────────────────────────────────┘ │
│                              │                                   │
│              ┌───────────────┴───────────────┐                   │
│              │  BW_IS_QT_TOOLS CMake 选项    │                   │
│              └───────────────┬───────────────┘                   │
│       ┌──────────────────────┴──────────────────────┐            │
│       ▼                                             ▼            │
│  ┌────────────────────────┐         ┌────────────────────────┐  │
│  │  MFC 后端实现          │         │  QT 后端实现(不完整) │  │
│  │  CMakeLists.mfc.txt    │         │  CMakeLists.qt.txt     │  │
│  │                        │         │                        │  │
│  │  mfc/app/              │         │  (无 app 实现)         │  │
│  │    i_editor_app.cpp    │         │                        │  │
│  │  mfc/menu_helper.cpp   │         │  mfc/menu_helper.cpp   │  │
│  │  mfc/cursor/           │         │  (仅 menu_helper 复用) │  │
│  │    cursor.cpp          │         │                        │  │
│  │    wait_cursor.cpp     │         │  (无 cursor 实现)      │  │
│  │  mfc/dialogs/          │         │                        │  │
│  │    file_dialog.cpp     │         │  (无 dialogs 实现)     │  │
│  │    message_box.cpp     │         │                        │  │
│  └────────────────────────┘         └────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
              ▲                    ▲
              │链接                │链接
      ┌───────┴───────┐    ┌───────┴───────┐
      │  worldeditor  │    │ tools_common  │
      │  (实现接口)   │    │ (INTERFACE    │
      │               │    │  依赖)        │
      └───────────────┘    └───────────────┘
```

### 1.3 关键设计原则

| 原则 | 说明 |
|------|------|
| **接口与实现分离** | 抽象接口在 `app/`/`gui/`/`cursor/`/`dialogs/` 头文件,MFC 实现在 `mfc/` 子目录 |
| **双后端切换** | `CMakeLists.txt` 根据 `BW_IS_QT_TOOLS` 包含 `CMakeLists.mfc.txt` 或 `CMakeLists.qt.txt` |
| **依赖倒置** | 工具(worldeditor)依赖 `IEditorApp`/`IMainFrame` 抽象,不依赖具体 MFC 类 |
| **RAII 资源管理** | `WaitCursor`/`FolderGuard` 利用析构自动恢复状态 |
| **目录守卫** | `BWFileDialog` 内嵌 `FolderGuard`,确保文件对话框不污染调用方当前目录 |
| **头文件共享** | 抽象头文件在两个后端间共享,只有 .cpp 实现不同 |
| **QT 移植不完整** | QT 后端仅实现 `menu_helper`,其余仍缺,实际生产使用 MFC 后端 |

### 1.4 规模与组成

`editor_shared` 源码位于 `programming/bigworld/tools/editor_shared/`,规模较小(约 2000 行)。文件分组:

| 分组 | 文件 | 说明 |
|------|------|------|
| 抽象接口 | `app/i_editor_app.hpp`、`gui/i_main_frame.hpp`、`pages/gui_tab_content.hpp` | 后端无关 |
| Cursor | `cursor/cursor.hpp`、`cursor/wait_cursor.hpp` | 光标抽象 |
| Dialogs | `dialogs/file_dialog.hpp`、`dialogs/folder_guard.hpp`、`dialogs/message_box.hpp` | 对话框抽象 |
| MFC 实现 | `mfc/app/i_editor_app.cpp`、`mfc/menu_helper.hpp/.cpp`、`mfc/cursor/cursor.cpp`、`mfc/cursor/wait_cursor.cpp`、`mfc/dialogs/file_dialog.cpp`、`mfc/dialogs/message_box.cpp`、`mfc/dialogs/folder_guard.cpp` | MFC 后端 |
| 构建 | `CMakeLists.txt`、`CMakeLists.mfc.txt`、`CMakeLists.qt.txt` | 构建配置 |

---

## 二、源码目录结构

### 2.1 顶层目录

```
tools/editor_shared/
├── CMakeLists.txt              # 顶层构建,根据 BW_IS_QT_TOOLS 选择后端
├── CMakeLists.mfc.txt          # MFC 后端构建(8 个源文件)
├── CMakeLists.qt.txt           # QT 后端构建(仅 menu_helper,不完整)
├── app/
│   └── i_editor_app.hpp        # IEditorApp 抽象接口
├── gui/
│   └── i_main_frame.hpp        # IMainFrame 抽象接口
├── cursor/
│   ├── cursor.hpp              # Cursor 光标位置
│   ├── cursor.cpp              # Cursor 共享实现
│   └── wait_cursor.hpp         # WaitCursor RAII 声明
├── dialogs/
│   ├── file_dialog.hpp         # BWFileDialog 声明
│   ├── folder_guard.hpp        # FolderSetter/FolderGuard 声明
│   ├── folder_guard.cpp        # FolderSetter/FolderGuard 共享实现
│   └── message_box.hpp         # MessageBox 声明
├── pages/
│   └── gui_tab_content.hpp     # GuiTabContent 接口
└── mfc/                        # MFC 后端实现
    ├── app/
    │   └── i_editor_app.cpp    # IEditorApp::isMinimized MFC 实现
    ├── menu_helper.hpp         # MenuHelper 声明
    ├── menu_helper.cpp         # MenuHelper 实现
    ├── cursor/
    │   ├── cursor.cpp          # Cursor MFC 实现
    │   └── wait_cursor.cpp     # WaitCursor MFC 实现
    └── dialogs/
        ├── file_dialog.cpp     # BWFileDialog MFC 实现
        ├── message_box.cpp     # MessageBox MFC 实现
        └── folder_guard.cpp    # (folder_guard 共享实现已在上级)
```

### 2.2 文件规模

| 文件 | 行数 | 作用 |
|------|------|------|
| `app/i_editor_app.hpp` | 17 | IEditorApp 接口 |
| `gui/i_main_frame.hpp` | 39 | IMainFrame 接口 |
| `cursor/cursor.hpp` | 23 | Cursor 接口 |
| `cursor/wait_cursor.hpp` | 10 | WaitCursor RAII |
| `dialogs/file_dialog.hpp` | 45 | BWFileDialog |
| `dialogs/folder_guard.hpp` | 32 | FolderSetter/FolderGuard |
| `dialogs/message_box.hpp` | 19 | MessageBox |
| `pages/gui_tab_content.hpp` | - | GuiTabContent |
| `mfc/menu_helper.hpp` | 58 | MenuHelper 声明 |
| `mfc/app/i_editor_app.cpp` | 13 | isMinimized 实现 |

---

## 三、库的构建与被链接方式

### 3.1 顶层 CMakeLists.txt

`CMakeLists.txt` 定义共享源文件并根据 `BW_IS_QT_TOOLS` 选择后端:

```cmake
# CMakeLists.txt:1-20
CMAKE_MINIMUM_REQUIRED( VERSION 2.8 )

SET( SHARED_SOURCE_FILES_SRCS
    app/i_editor_app.hpp
    cursor/cursor.hpp
    cursor/cursor.cpp
    cursor/wait_cursor.hpp
    gui/i_main_frame.hpp
    pages/gui_tab_content.hpp
    dialogs/file_dialog.hpp
    dialogs/folder_guard.hpp
    dialogs/folder_guard.cpp
    dialogs/message_box.hpp
)
SOURCE_GROUP( "Shared_Source_Files" FILES ${SHARED_SOURCE_FILES_SRCS} )

IF( BW_IS_QT_TOOLS )
    INCLUDE( "CMakeLists.qt.txt" )
ELSE()
    INCLUDE( "CMakeLists.mfc.txt" )
ENDIF()
```

`SHARED_SOURCE_FILES_SRCS` 列出**后端无关**的源文件(主要是头文件 + `cursor.cpp` + `folder_guard.cpp`),两个后端都会包含。

### 3.2 MFC 后端构建(CMakeLists.mfc.txt)

```cmake
# CMakeLists.mfc.txt:1-26
CMAKE_MINIMUM_REQUIRED( VERSION 2.8 )
PROJECT( editor_shared )

INCLUDE( BWStandardProject )
INCLUDE( BWStandardMFCProject )
INCLUDE( BWStandardLibrary )

SET( SOURCE_FILES_SRCS
    mfc/app/i_editor_app.cpp
    mfc/menu_helper.hpp
    mfc/menu_helper.cpp
    mfc/cursor/wait_cursor.cpp
    mfc/cursor/cursor.cpp
    mfc/dialogs/file_dialog.cpp
    mfc/dialogs/message_box.cpp
)
SOURCE_GROUP( "Source_Files" FILES ${SOURCE_FILES_SRCS} )

BW_BLOB_SOURCES( BLOB_SRCS
    ${SOURCE_FILES_SRCS}
    ${SHARED_SOURCE_FILES_SRCS}
)
BW_ADD_LIBRARY( editor_shared ${BLOB_SRCS} )

BW_PROJECT_CATEGORY( editor_shared "Editor Shared" )
```

MFC 后端包含 `BWStandardMFCProject`(引入 MFC 依赖),共 7 个 .cpp 实现文件 + 共享源文件。

### 3.3 QT 后端构建(CMakeLists.qt.txt)

```cmake
# CMakeLists.qt.txt:1-25
CMAKE_MINIMUM_REQUIRED( VERSION 2.8 )
PROJECT( editor_shared )

INCLUDE( BWStandardProject )
INCLUDE( BWStandardLibrary )

SET( SHARED_SOURCE_FILES_SRCS
    gui/i_main_frame.hpp
    pages/gui_tab_content.hpp
)
SOURCE_GROUP( "Shared_Source_Files" FILES ${SHARED_SOURCE_FILES_SRCS} )

SET( SOURCE_FILES_SRCS
    mfc/menu_helper.hpp
    mfc/menu_helper.cpp
)
SOURCE_GROUP( "Source_Files" FILES ${SOURCE_FILES_SRCS} )

BW_ADD_LIBRARY( editor_shared
    ${SOURCE_FILES_SRCS}
    ${SHARED_SOURCE_FILES_SRCS}
)

BW_PROJECT_CATEGORY( editor_shared "Editor Shared" )
```

QT 后端**不完整**:
- 不包含 `BWStandardMFCProject`
- 仅编译 `mfc/menu_helper.hpp/.cpp`(注意:路径仍是 `mfc/`,QT 后端复用 MFC 的 menu_helper)
- 缺失:`i_editor_app.cpp`、`cursor.cpp`、`wait_cursor.cpp`、`file_dialog.cpp`、`message_box.cpp`、`folder_guard.cpp`
- `SHARED_SOURCE_FILES_SRCS` 仅保留 `i_main_frame.hpp` 与 `gui_tab_content.hpp`(纯头文件)

这意味着 **QT 后端实际不可用**——`IEditorApp::isMinimized`、`WaitCursor`、`BWFileDialog`、`MessageBox` 等均无实现。链接 `editor_shared` 的 QT 工具会触发链接错误。

### 3.4 被链接方式

`editor_shared` 被以下链接:

| 使用者 | CMakeLists 引用 |
|--------|----------------|
| worldeditor | `tools/worldeditor/CMakeLists.txt:918` |
| tools_common | `tools/common/CMakeLists.txt:116`(INTERFACE) |

以 worldeditor 为例:

```cmake
# worldeditor/CMakeLists.txt:912-918
BW_TARGET_LINK_LIBRARIES( worldeditor
    appmgr
    ...
    editor_shared          # GUI 后端抽象
    ...
)
```

`tools_common` 通过 INTERFACE 传递依赖:

```cmake
# common/CMakeLists.txt:114-119
BW_TARGET_LINK_LIBRARIES( tools_common INTERFACE
    cstdmf
    editor_shared
    ...
)
```

### 3.5 作为库无入口点

`editor_shared` 是**静态库,无入口点**。其类被使用者在自身初始化中实例化或实现:

- `WorldEditorApp` 继承 `IEditorApp`(实现 `isMinimized`/`onIdle`)
- `MainFrame` 继承 `IMainFrame`(实现各纯虚方法)
- `GUI::MenuHelper` 在 `InternalInitInstance` 中构造(`world_editor_app.cpp:566`)
- `WaitCursor`/`FolderGuard` 在需要时栈上构造
- `BWFileDialog` 在文件操作时构造

---

## 四、核心类与继承关系

### 4.1 IEditorApp 应用抽象接口

`IEditorApp`(`app/i_editor_app.hpp:8-13`)是编辑器应用的最小抽象:

```cpp
// app/i_editor_app.hpp:8-13
class IEditorApp
{
public:
    virtual bool isMinimized();
    virtual void onIdle() {};
};
```

仅两个方法:
- `isMinimized()`:查询应用窗口是否最小化(MFC 实现查 `AfxGetMainWnd()->IsIconic()`)
- `onIdle()`:空闲回调(默认空实现)

`WorldEditorApp` 继承此接口(`world_editor_app.hpp:21-24`):

```cpp
class WorldEditorApp
    : public CWinApp
    , public IEditorApp
{
```

MFC 后端实现(`mfc/app/i_editor_app.cpp:1-13`):

```cpp
// mfc/app/i_editor_app.cpp:8-11
bool IEditorApp::isMinimized()
{
    return AfxGetMainWnd()->IsIconic() == TRUE;
}
```

注意 `isMinimized` 非纯虚(MFC 实现直接定义在基类),`onIdle` 是空默认实现。这种设计使接口"开箱即用"——工具继承后即可获得 MFC 默认行为,无需重写。

### 4.2 IMainFrame 主框架抽象接口

`IMainFrame`(`gui/i_main_frame.hpp:17-35`)定义主框架窗口的 GUI 能力:

```cpp
// gui/i_main_frame.hpp:17-35
class IMainFrame
{
public:
    virtual ~IMainFrame() {}

    virtual GLView * getEditorView() { return NULL; }
    virtual GUI::IMenuHelper * getMenuHelper() { return NULL;}

    virtual void setMessageText( const wchar_t * pText ) = 0;
    virtual void setStatusText( UINT id, const wchar_t * text ) = 0;
    virtual bool cursorOverGraphicsWnd() const = 0;
    virtual void updateGUI( bool force = false ) = 0;
    virtual Vector2 currentCursorPosition() const = 0;
    virtual Vector3 getWorldRay(int x, int y) const = 0;
    virtual void grabFocus() = 0;

    virtual void * getNativePointer() { return NULL; }
};
```

#### 4.2.1 方法分类

| 方法 | 纯虚 | 默认实现 | 用途 |
|------|------|---------|------|
| `getEditorView` | 否 | NULL | 获取 GLView 视口 |
| `getMenuHelper` | 否 | NULL | 获取菜单助手 |
| `setMessageText` | **是** | - | 设置消息文本 |
| `setStatusText` | **是** | - | 设置状态栏文本 |
| `cursorOverGraphicsWnd` | **是** | - | 光标是否在图形窗口 |
| `updateGUI` | **是** | - | 强制刷新 GUI |
| `currentCursorPosition` | **是** | - | 当前光标位置 |
| `getWorldRay` | **是** | - | 屏幕坐标转世界射线 |
| `grabFocus` | **是** | - | 抢占焦点 |
| `getNativePointer` | 否 | NULL | 获取原生窗口指针(HWND) |

#### 4.2.2 WorldEditor 的实现

`MainFrame` 继承 `IMainFrame`(`mainframe.hpp:14-16`),但多数方法是**空/零实现**(`mainframe.hpp:60-67`):

```cpp
// mainframe.hpp:60-67
void setMessageText( const wchar_t * pText );
void setStatusText( UINT id, const wchar_t * text );
bool cursorOverGraphicsWnd() const { return false; }
void updateGUI( bool force = false ) {}
Vector2 currentCursorPosition() const { return Vector2::ZERO; }
Vector3 getWorldRay(int x, int y) const { return Vector3::ZERO; }
void grabFocus() { SetFocus(); }
```

这是因 WorldEditor 的视口逻辑主要在 `WorldEditorView`(CView 派生)中,`MainFrame` 仅作 MFC 框架容器。`IMainFrame` 的设计允许其他工具(如 ModelEditor)将视口逻辑放在 MainFrame 中。

### 4.3 MenuHelper 菜单操作(MFC 后端)

`MenuHelper`(`mfc/menu_helper.hpp:11-13`)实现 `GUI::IMenuHelper`(来自 guimanager 库),封装 Win32 HMENU 操作:

```cpp
// mfc/menu_helper.hpp:11-13
class MenuHelper
    : public IMenuHelper
{
public:
    MenuHelper( HWND hWnd );

    void * getMenu();
    int getMenuItemCount( void * menu );
    void deleteMenu( void * menu, int index );
    void setMenuInfo( void * menu, void * menuInfo );
    void destroyMenu( void * menu );
    GUI::Item * getMenuItemInfo( void * menu, unsigned int index, void * typeData );
    void setMenuItemInfo( void * menu, unsigned int index, void * info );
    void insertMenuItem( void * menu, unsigned int index, GUI::ItemPtr info );
    void modifyMenu( void * menu, unsigned int index, GUI::ItemPtr info, const wchar_t * string );
    void enableMenuItem( void * menu, unsigned int index, MenuState state );
    void checkMenuItem( void * menu, unsigned int index, MenuCheckState state );
    void setSeperator( void * menu, unsigned int index );
    void updateText( void * hMenu, unsigned index, const BW::wstring & newName );
    void * setSubMenu( void * hMenu, unsigned index );

private:
    HWND hWnd_;
};
```

`IMenuHelper` 使用 `void*` 抽象菜单句柄(MFC 后端为 `HMENU`),使 guimanager 库不直接依赖 Win32。`MenuHelper` 构造时传入 `HWND`(主框架窗口),`getMenu` 返回 `GetMenu(hWnd_)` 或 `CreatePopupMenu()`(`mfc/menu_helper.cpp:14-21`)。

**注意**:QT 后端也复用 `mfc/menu_helper.cpp`(`CMakeLists.qt.txt:13-16`),这是 QT 移植的权宜之计——菜单操作仍走 Win32,未真正抽象。

### 4.4 WaitCursor 等待光标 RAII

`WaitCursor`(`cursor/wait_cursor.hpp:4-9`)是极简 RAII 守卫:

```cpp
// cursor/wait_cursor.hpp:4-9
class WaitCursor
{
public:
    WaitCursor();
    ~WaitCursor();
};
```

MFC 实现(`mfc/cursor/wait_cursor.cpp:6-15`):

```cpp
// mfc/cursor/wait_cursor.cpp:6-15
WaitCursor::WaitCursor()
{
    AfxGetApp()->BeginWaitCursor();
}

WaitCursor::~WaitCursor()
{
    AfxGetApp()->EndWaitCursor();
}
```

构造时 `BeginWaitCursor`(显示沙漏),析构时 `EndWaitCursor`(恢复)。使用方式:

```cpp
{
    WaitCursor wc;   // 进入:沙漏
    // ... 耗时操作 ...
}                   // 退出:恢复
```

QT 后端无此实现(链接 QT 后端时 `WaitCursor` 未定义)。

### 4.5 Cursor 光标位置

`Cursor`(`cursor/cursor.hpp:9-19`)提供光标位置设置与监听:

```cpp
// cursor/cursor.hpp:9-19
class Cursor
{
public:
    typedef std::function< void ( int, int ) >  CursorExplicitlyChanged;

    static void setPosition( int x, int y );
    static void addPositionChangedListener( CursorExplicitlyChanged & listener );

private:
    static void emitCursorPosChanged( int x, int y );
};
```

使用 `std::function` 注册位置变化监听器。MFC 实现调用 `SetCursorPos` 并触发监听器。这是 C++11 风格的观察者,与 `BWLockDConnection::Notification` 的纯虚接口风格不同,反映不同时期的编码习惯。

### 4.6 BWFileDialog 文件对话框

`BWFileDialog`(`dialogs/file_dialog.hpp:15-42`)封装文件对话框,**关键特性是保持当前目录**:

```cpp
// dialogs/file_dialog.hpp:15-42
class BWFileDialog
{
public:
    enum FDFlags
    {
        FD_HIDEREADONLY     = 1,
        FD_OVERWRITEPROMPT  = 1 << 1,
        FD_FILEMUSTEXIST    = 1 << 2,
        FD_PATHMUSTEXIST    = 1 << 3,
        FD_ALLOWMULTISELECT = 1 << 4,
        FD_WRITABLE_AND_EXISTS = FD_HIDEREADONLY | FD_FILEMUSTEXIST,
        FD_FILE_PATH_MUST_EXIST = FD_FILEMUSTEXIST | FD_PATHMUSTEXIST
    };

    BWFileDialog(
         bool openFileDialog, const wchar_t * defaultExt,
         const wchar_t * initialFileName,
         FDFlags flags, const wchar_t * filter, void * parentWnd = 0 );
    ~BWFileDialog();

    bool showDialog();
    void initialDir( const wchar_t * initialDir );
    BW::wstring getFileName() const;
    BW::vector< BW::wstring > getFileNames() const;

private:
    FolderGuard             folderGuard_;
};
```

#### 4.6.1 内嵌 FolderGuard

`BWFileDialog` 内嵌 `FolderGuard folderGuard_` 成员(`dialogs/file_dialog.hpp:41`)。构造时 `FolderGuard` 进入(保存当前目录),析构时离开(恢复当前目录)。这确保文件对话框切换目录不影响调用方。

#### 4.6.2 FDFlags 标志位

标志位采用位移枚举,支持按位或组合:

| 标志 | 值 | 说明 |
|------|-----|------|
| `FD_HIDEREADONLY` | 1 | 隐藏只读复选框 |
| `FD_OVERWRITEPROMPT` | 2 | 覆盖提示 |
| `FD_FILEMUSTEXIST` | 4 | 文件必须存在 |
| `FD_PATHMUSTEXIST` | 8 | 路径必须存在 |
| `FD_ALLOWMULTISELECT` | 16 | 允许多选 |
| `FD_WRITABLE_AND_EXISTS` | 5 | 可写且存在(HIDEREADONLY\|FILEMUSTEXIST) |
| `FD_FILE_PATH_MUST_EXIST` | 12 | 文件路径必须存在(FILEMUSTEXIST\|PATHMUSTEXIST) |

### 4.7 FolderSetter/FolderGuard 目录守卫 RAII

`FolderSetter`/`FolderGuard`(`dialogs/folder_guard.hpp:8-28`)是目录切换守卫:

```cpp
// dialogs/folder_guard.hpp:8-28
class FolderSetter
{
private:
    static const int MAX_PATH_SIZE = 8192;
    wchar_t envFolder_[ MAX_PATH_SIZE ];
    wchar_t curFolder_[ MAX_PATH_SIZE ];

public:
    FolderSetter();
    void enter();
    void leave();
};


class FolderGuard
{
    FolderSetter setter_;
public:
    FolderGuard();
    ~FolderGuard();
};
```

#### 4.7.1 MAX_PATH_SIZE=8192

`MAX_PATH_SIZE = 8192`(`folder_guard.hpp:11`)远大于 Win32 `MAX_PATH`(260),支持长路径。两个缓冲区 `envFolder_`(进入时环境目录)与 `curFolder_`(目标目录)各 8192 wchar。

#### 4.7.2 实现

`folder_guard.cpp`(`dialogs/folder_guard.cpp`,共享实现):

```cpp
// dialogs/folder_guard.cpp:7-13
FolderSetter::FolderSetter()
{
    BW_GUARD;
    GetCurrentDirectory( ARRAY_SIZE( envFolder_ ), envFolder_ );
    GetCurrentDirectory( ARRAY_SIZE( curFolder_ ), curFolder_ );
}

// dialogs/folder_guard.cpp:17-23
void FolderSetter::enter()
{
    BW_GUARD;
    GetCurrentDirectory( ARRAY_SIZE( envFolder_ ), envFolder_ );
    SetCurrentDirectory( curFolder_ );
}

// dialogs/folder_guard.cpp:27-33
void FolderSetter::leave()
{
    BW_GUARD;
    GetCurrentDirectory( ARRAY_SIZE( curFolder_ ), curFolder_ );
    SetCurrentDirectory( envFolder_ );
}

// dialogs/folder_guard.cpp:37-42
FolderGuard::FolderGuard()
{
    BW_GUARD;
    setter_.enter();
}

// dialogs/folder_guard.cpp:46-51
FolderGuard::~FolderGuard()
{
    BW_GUARD;
    setter_.leave();
}
```

逻辑:
- `FolderSetter` 构造:记录当前目录到 `envFolder_` 与 `curFolder_`
- `enter()`:`envFolder_` ← 当前目录,然后切换到 `curFolder_`
- `leave()`:`curFolder_` ← 当前目录(保存目标),然后切回 `envFolder_`
- `FolderGuard`:构造调 `enter`,析构调 `leave`

注意 `folder_guard.cpp` 在 `SHARED_SOURCE_FILES_SRCS` 中(`CMakeLists.txt:12`),两个后端共享,因 `GetCurrentDirectory`/`SetCurrentDirectory` 是 Win32 API,MFC/QT 均可用。

### 4.8 MessageBox 消息框

`MessageBox`(`dialogs/message_box.hpp:8-17`)定义简化消息框:

```cpp
// dialogs/message_box.hpp:8-17
enum MessageBoxFlags
{
    BW_MB_OK            = 1,
    BW_MB_ICONWARNING   = 1 << 1,
};

int MessageBox( void * parent, const wchar_t * text, const wchar_t * caption,
                MessageBoxFlags flags );
```

`BW_MB_*` 前缀避免与 Win32 `MB_OK` 宏冲突。MFC 实现调用 Win32 `MessageBox`。QT 后端无实现。

### 4.9 GuiTabContent 标签页内容接口

`pages/gui_tab_content.hpp` 定义 GUITABS 系统的标签页内容接口,供属性页实现。worldeditor 的 `PanelManager` 管理这些标签页。

---

## 五、关键算法与数据结构

### 5.1 双后端切换算法

`editor_shared` 的双后端切换通过 CMake 选项 `BW_IS_QT_TOOLS` 实现:

```
BW_IS_QT_TOOLS?
├── 是 → CMakeLists.qt.txt(不完整)
│   ├── 仅编译 mfc/menu_helper
│   ├── 仅包含 i_main_frame.hpp / gui_tab_content.hpp
│   └── 缺失:cursor/dialogs/app 实现
└── 否 → CMakeLists.mfc.txt(完整)
    ├── 包含 BWStandardMFCProject
    ├── 编译 7 个 mfc/*.cpp
    └── 包含全部共享源文件
```

切换在配置阶段(CMake)完成,编译阶段无运行时开销。但因 QT 后端不完整,实际仅 MFC 后端可用。

### 5.2 FolderSetter 双缓冲目录保存

`FolderSetter` 用双缓冲(`envFolder_` + `curFolder_`)支持可重入:

```
初始:envFolder_ = curFolder_ = cwd
enter():
    envFolder_ = cwd          # 保存进入前环境
    SetCurrentDirectory(curFolder_)  # 切到目标
leave():
    curFolder_ = cwd          # 保存离开时目录(供下次 enter)
    SetCurrentDirectory(envFolder_)  # 恢复环境
```

这种设计使 `FolderSetter` 可多次 `enter`/`leave`,且 `FolderGuard` 构造析构成对调用时正确恢复。

### 5.3 MenuHelper void* 抽象

`IMenuHelper`(guimanager)使用 `void* menu` 抽象菜单句柄,`MenuHelper` 实现内部 `static_cast<HMENU>(menu)`。这种 `void*` 抽象是 C 风格的多态,避免 guimanager 依赖 Win32 头文件。代价是类型安全丧失——错误传入非 HMENU 指针会运行时崩溃。

### 5.4 BWFileDialog 目录保持

`BWFileDialog` 通过内嵌 `FolderGuard` 成员实现目录保持:

```
BWFileDialog 构造 → FolderGuard 构造 → enter(保存 cwd,切到目标)
    ... showDialog ...
BWFileDialog 析构 → FolderGuard 析构 → leave(恢复 cwd)
```

调用方代码无需关心目录状态:

```cpp
{
    BWFileDialog dlg(true, L".chunk", L"foo", BWFileDialog::FD_FILEMUSTEXIST, ...);
    if (dlg.showDialog()) { ... dlg.getFileName() ... }
}   // 当前目录自动恢复
```

### 5.5 Cursor 观察者(std::function)

`Cursor` 使用 `std::function<void(int,int)>` 注册监听器,比传统纯虚接口更轻量:

```cpp
CursorExplicitlyChanged listener = [](int x, int y){ ... };
Cursor::addPositionChangedListener(listener);
```

`setPosition` 调用 `emitCursorPosChanged` 遍历监听器。这种风格在 editor_shared 中较新(可能后期添加)。

---

## 六、配置项与命令行参数

`editor_shared` 作为库不读取配置,其行为由编译时选项决定:

| CMake 选项 | 取值 | 影响 |
|-----------|------|------|
| `BW_IS_QT_TOOLS` | OFF(默认) | 使用 MFC 后端(`CMakeLists.mfc.txt`) |
| `BW_IS_QT_TOOLS` | ON | 使用 QT 后端(`CMakeLists.qt.txt`,不完整) |

无运行时命令行参数。

---

## 七、与其他模块的依赖关系

### 7.1 链接依赖

`editor_shared` 依赖:

| 库 | 后端 | 用途 |
|----|------|------|
| `cstdmf` | 共享 | `bw_namespace.hpp`、`guard.hpp`、`bw_string.hpp` |
| `guimanager` | 共享 | `IMenuHelper`、`gui_item.hpp` |
| MFC | MFC 后端 | `CWinApp`、`CFileDialog`、`AfxGetApp` |
| Win32 | 共享 | `GetCurrentDirectory`、`SetCursorPos`、`HMENU` |

### 7.2 被依赖

| 使用者 | 方式 |
|--------|------|
| worldeditor | 直接链接 + 实现 IEditorApp/IMainFrame |
| tools_common | INTERFACE 链接(传递给 tools_common 的使用者) |

### 7.3 依赖关系图

```
                ┌─────────────────────┐
                │   editor_shared     │
                └──┬──────────┬───────┘
                   │          │
        ┌──────────▼──┐    ┌──▼──────────┐
        │ guimanager  │    │   cstdmf    │
        │ (IMenuHelper│    │ (namespace/ │
        │  gui_item)  │    │  string)    │
        └─────────────┘    └─────────────┘
                   │
                   ▼ (MFC 后端)
            ┌─────────────┐
            │   MFC/Win32 │
            │  (CWinApp/  │
            │   CFileDialog│
            │   HMENU)    │
            └─────────────┘
                   ▲
                   │ 实现
        ┌──────────┴──────────┐
        │                     │
┌───────┴───────┐    ┌────────┴────────┐
│  worldeditor  │    │  tools_common   │
│ (WorldEditorApp│    │ (INTERFACE      │
│  : IEditorApp)│    │  传递依赖)      │
│ (MainFrame:   │    └─────────────────┘
│  IMainFrame)  │
└───────────────┘
```

### 7.4 运行时依赖

| 运行时关系 | 说明 |
|-----------|------|
| `MenuHelper` → `GUI::Manager` | worldeditor 将 `MenuHelper` 注册为 `GUI::Menu` |
| `IEditorApp::isMinimized` → `AfxGetMainWnd` | MFC 后端依赖主窗口已创建 |
| `BWFileDialog` → MFC `CFileDialog` | MFC 后端封装 |
| `FolderGuard` → Win32 `GetCurrentDirectory` | 共享实现直接调 Win32 |

---

## 八、关键代码片段

### 8.1 IEditorApp 抽象接口

```cpp
// app/i_editor_app.hpp:8-13
class IEditorApp
{
public:
    virtual bool isMinimized();
    virtual void onIdle() {};
};
```

### 8.2 IEditorApp MFC 实现

```cpp
// mfc/app/i_editor_app.cpp:8-11
bool IEditorApp::isMinimized()
{
    return AfxGetMainWnd()->IsIconic() == TRUE;
}
```

### 8.3 IMainFrame 抽象接口

```cpp
// gui/i_main_frame.hpp:17-35
class IMainFrame
{
public:
    virtual ~IMainFrame() {}

    virtual GLView * getEditorView() { return NULL; }
    virtual GUI::IMenuHelper * getMenuHelper() { return NULL;}

    virtual void setMessageText( const wchar_t * pText ) = 0;
    virtual void setStatusText( UINT id, const wchar_t * text ) = 0;
    virtual bool cursorOverGraphicsWnd() const = 0;
    virtual void updateGUI( bool force = false ) = 0;
    virtual Vector2 currentCursorPosition() const = 0;
    virtual Vector3 getWorldRay(int x, int y) const = 0;
    virtual void grabFocus() = 0;

    virtual void * getNativePointer() { return NULL; }
};
```

### 8.4 MenuHelper 声明

```cpp
// mfc/menu_helper.hpp:11-13
class MenuHelper
    : public IMenuHelper
{
public:
    MenuHelper( HWND hWnd );

    void * getMenu();
    int getMenuItemCount( void * menu );
    void deleteMenu( void * menu, int index );
    // ...
private:
    HWND hWnd_;
};
```

### 8.5 MenuHelper getMenu 实现

```cpp
// mfc/menu_helper.cpp:14-21
void * MenuHelper::getMenu()
{
    if (hWnd_ != NULL)
    {
        return GetMenu( hWnd_ );
    }
    return CreatePopupMenu();
}
```

### 8.6 WaitCursor RAII 声明

```cpp
// cursor/wait_cursor.hpp:4-9
class WaitCursor
{
public:
    WaitCursor();
    ~WaitCursor();
};
```

### 8.7 WaitCursor MFC 实现

```cpp
// mfc/cursor/wait_cursor.cpp:6-15
WaitCursor::WaitCursor()
{
    AfxGetApp()->BeginWaitCursor();
}

WaitCursor::~WaitCursor()
{
    AfxGetApp()->EndWaitCursor();
}
```

### 8.8 FolderSetter/FolderGuard 声明

```cpp
// dialogs/folder_guard.hpp:8-28
class FolderSetter
{
private:
    static const int MAX_PATH_SIZE = 8192;
    wchar_t envFolder_[ MAX_PATH_SIZE ];
    wchar_t curFolder_[ MAX_PATH_SIZE ];

public:
    FolderSetter();
    void enter();
    void leave();
};


class FolderGuard
{
    FolderSetter setter_;
public:
    FolderGuard();
    ~FolderGuard();
};
```

### 8.9 FolderSetter 实现

```cpp
// dialogs/folder_guard.cpp:17-33
void FolderSetter::enter()
{
    BW_GUARD;
    GetCurrentDirectory( ARRAY_SIZE( envFolder_ ), envFolder_ );
    SetCurrentDirectory( curFolder_ );
}

void FolderSetter::leave()
{
    BW_GUARD;
    GetCurrentDirectory( ARRAY_SIZE( curFolder_ ), curFolder_ );
    SetCurrentDirectory( envFolder_ );
}
```

### 8.10 BWFileDialog 内嵌 FolderGuard

```cpp
// dialogs/file_dialog.hpp:15-42
class BWFileDialog
{
public:
    enum FDFlags
    {
        FD_HIDEREADONLY     = 1,
        FD_OVERWRITEPROMPT  = 1 << 1,
        FD_FILEMUSTEXIST    = 1 << 2,
        FD_PATHMUSTEXIST    = 1 << 3,
        FD_ALLOWMULTISELECT = 1 << 4,
        FD_WRITABLE_AND_EXISTS = FD_HIDEREADONLY | FD_FILEMUSTEXIST,
        FD_FILE_PATH_MUST_EXIST = FD_FILEMUSTEXIST | FD_PATHMUSTEXIST
    };

    BWFileDialog( ... );
    ~BWFileDialog();

    bool showDialog();
    void initialDir( const wchar_t * initialDir );
    BW::wstring getFileName() const;
    BW::vector< BW::wstring > getFileNames() const;

private:
    FolderGuard             folderGuard_;
};
```

### 8.11 Cursor 接口

```cpp
// cursor/cursor.hpp:9-19
class Cursor
{
public:
    typedef std::function< void ( int, int ) >  CursorExplicitlyChanged;

    static void setPosition( int x, int y );
    static void addPositionChangedListener( CursorExplicitlyChanged & listener );

private:
    static void emitCursorPosChanged( int x, int y );
};
```

### 8.12 MessageBox 声明

```cpp
// dialogs/message_box.hpp:8-17
enum MessageBoxFlags
{
    BW_MB_OK            = 1,
    BW_MB_ICONWARNING   = 1 << 1,
};

int MessageBox( void * parent, const wchar_t * text, const wchar_t * caption,
                MessageBoxFlags flags );
```

### 8.13 CMakeLists.txt 双后端选择

```cmake
# CMakeLists.txt:17-20
IF( BW_IS_QT_TOOLS )
    INCLUDE( "CMakeLists.qt.txt" )
ELSE()
    INCLUDE( "CMakeLists.mfc.txt" )
ENDIF()
```

---

## 九、设计亮点与注意事项

### 9.1 设计亮点

#### 9.1.1 抽象接口与依赖倒置

`IEditorApp`/`IMainFrame`/`IMenuHelper` 通过抽象接口隔离工具逻辑与 GUI 后端。工具(worldeditor)依赖接口而非 MFC 具体类,使:
- 工具核心逻辑可移植(理论上)
- 接口变更显式(需改所有实现)
- 后端切换在链接层完成

#### 9.1.2 RAII 广泛应用

`WaitCursor`(光标)、`FolderGuard`(目录)、`BWFileDialog`(内嵌 FolderGuard)利用 RAII 自动管理资源,调用方无需手动恢复。这是 C++ 资源管理的最佳实践,避免了忘记恢复导致的"目录漂移""光标卡沙漏"等 bug。

#### 9.1.3 FolderSetter 双缓冲可重入

`FolderSetter` 用 `envFolder_` + `curFolder_` 双缓冲,支持多次 enter/leave。`FolderGuard` 在构造析构成对调用时正确恢复,即使嵌套使用也无副作用。

#### 9.1.4 BWFileDialog 目录保持

文件对话框是改变当前目录的常见来源。`BWFileDialog` 内嵌 `FolderGuard` 从根源消除此问题,调用方代码无需关心目录状态。这种"内嵌守卫"模式值得推广。

#### 9.1.5 void* 抽象避免头文件污染

`IMenuHelper` 用 `void* menu` 抽象 HMENU,使 guimanager 库不包含 `<Windows.h>`。代价是类型安全,但换来 guimanager 的后端无关性。

#### 9.1.6 共享源文件减少重复

`CMakeLists.txt` 的 `SHARED_SOURCE_FILES_SRCS` 列出后端无关文件(头文件 + `folder_guard.cpp` + `cursor.cpp`),两个后端都包含,避免实现重复。

#### 9.1.7 MAX_PATH_SIZE=8192 长路径支持

`FolderSetter` 使用 8192 wchar 缓冲区,远超 Win32 `MAX_PATH`(260),支持长路径与现代 Windows 路径限制。这是对 Win32 历史限制的务实规避。

### 9.2 注意事项

#### 9.2.1 QT 后端不完整

`CMakeLists.qt.txt` 仅编译 `menu_helper`,缺失:
- `IEditorApp::isMinimized` 实现
- `WaitCursor` 实现
- `BWFileDialog` 实现
- `MessageBox` 实现
- `Cursor` 实现

启用 `BW_IS_QT_TOOLS` 会导致链接错误。**生产构建必须使用 MFC 后端**。QT 移植是未完成的工作。

#### 9.2.2 QT 后端复用 mfc/menu_helper

`CMakeLists.qt.txt` 路径仍是 `mfc/menu_helper`,即 QT 后端复用 MFC 的 `menu_helper.cpp`(调用 `GetMenu`/`HMENU`)。这并非真正的 QT 实现,只是权宜之计。

#### 9.2.3 IMainFrame 在 worldeditor 多为空实现

`MainFrame` 继承 `IMainFrame` 但多数方法返回 `false`/`ZERO`/空(`mainframe.hpp:60-67`)。这是因视口逻辑在 `WorldEditorView`。其他工具若将视口放在 MainFrame,需正确实现这些方法。

#### 9.2.4 MenuHelper void* 类型安全

`MenuHelper` 接受 `void* menu` 并 `static_cast<HMENU>`,传入错误类型指针会运行时崩溃。使用者必须确保传入的是 `GetMenu`/`CreatePopupMenu` 返回的 HMENU。

#### 9.2.5 folder_guard.cpp 共享但依赖 Win32

`folder_guard.cpp` 在 `SHARED_SOURCE_FILES_SRCS`(两后端共享),但调用 `GetCurrentDirectory`/`SetCurrentDirectory`(Win32)。QT 后端若在非 Windows 平台构建会失败。当前 QT 后端实际仅 Windows 可用(且不完整)。

#### 9.2.6 IEditorApp::isMinimized 非纯虚

`isMinimized` 在基类有 MFC 实现(`mfc/app/i_editor_app.cpp`),非纯虚。这使工具继承后"开箱即用",但也意味着 QT 后端缺实现时,链接器会报"未定义引用"(若工具调用 isMinimized)。

#### 9.2.7 BW_MB_* 前缀避免宏冲突

`MessageBoxFlags` 用 `BW_MB_OK`/`BW_MB_ICONWARNING` 前缀,避免与 Win32 `MB_OK`/`MB_ICONWARNING` 宏冲突。这是在 Windows 平台定义枚举的必要谨慎。

#### 9.2.8 Cursor 的 std::function 风格不一致

`Cursor` 使用 `std::function` 注册监听器,而 `BWLockDConnection::Notification`(common)使用纯虚接口。两者都是观察者模式但风格不同,反映 editor_shared 部分代码较新。维护时需注意风格统一。

#### 9.2.9 静态库无入口点

`editor_shared` 是静态库,无 `main`/`WinMain`。所有初始化由使用者在自身启动流程中完成。工具需:
- 继承 `IEditorApp`/`IMainFrame` 并实现接口
- 构造 `MenuHelper`(传入主窗口 HWND)
- 按需构造 `WaitCursor`/`FolderGuard`/`BWFileDialog`

### 9.3 关键文件速查

| 文件 | 作用 |
|------|------|
| `app/i_editor_app.hpp` | IEditorApp 抽象(isMinimized/onIdle) |
| `gui/i_main_frame.hpp` | IMainFrame 抽象(8 纯虚 + 3 默认) |
| `mfc/menu_helper.hpp/.cpp` | MenuHelper MFC 实现(Win32 HMENU) |
| `cursor/cursor.hpp` | Cursor 光标位置(std::function 观察者) |
| `cursor/wait_cursor.hpp` | WaitCursor RAII 声明 |
| `mfc/cursor/wait_cursor.cpp` | WaitCursor MFC 实现(BeginWaitCursor) |
| `dialogs/file_dialog.hpp` | BWFileDialog(内嵌 FolderGuard) |
| `dialogs/folder_guard.hpp` | FolderSetter/FolderGuard RAII |
| `dialogs/folder_guard.cpp` | FolderSetter 实现(共享,Win32) |
| `dialogs/message_box.hpp` | MessageBox 声明 |
| `pages/gui_tab_content.hpp` | GuiTabContent 标签页接口 |
| `CMakeLists.txt` | 双后端选择(BW_IS_QT_TOOLS) |
| `CMakeLists.mfc.txt` | MFC 后端(7 .cpp,完整) |
| `CMakeLists.qt.txt` | QT 后端(仅 menu_helper,不完整) |

### 9.4 类关系总览

```
IEditorApp (抽象, isMinimized 非纯虚)
└── WorldEditorApp (worldeditor, 继承 CWinApp + IEditorApp)

IMainFrame (抽象, 8 纯虚 + 3 默认)
└── MainFrame (worldeditor, 多数空实现)

IMenuHelper (guimanager 抽象, void* menu)
└── MenuHelper (editor_shared/mfc, HWND + HMENU)

WaitCursor (RAII, 构造 BeginWaitCursor / 析构 EndWaitCursor)
└── 使用:栈上构造,作用域结束自动恢复

Cursor (静态类, std::function 观察者)
├── setPosition(x, y)
└── addPositionChangedListener(listener)

FolderSetter (双缓冲目录, MAX_PATH_SIZE=8192)
└── FolderGuard (RAII, enter/leave)

BWFileDialog (内嵌 FolderGuard, FDFlags 标志位)
├── 构造:FolderGuard 进入(保存 cwd)
├── showDialog:显示文件对话框
└── 析构:FolderGuard 离开(恢复 cwd)

MessageBox (BW_MB_* 标志, void* parent)
```

### 9.5 与其他库的差异

| 特性 | editor_shared | tools_common | guimanager |
|------|--------------|-------------|------------|
| 类型 | 静态库 | 静态库 | 静态库 |
| 职责 | GUI 后端抽象 | 业务公共层 | GUI 框架 |
| MFC 依赖 | 双模式(MFC 完整/QT 不完整) | 是 | 否(靠 IMenuHelper 抽象) |
| 抽象接口 | IEditorApp/IMainFrame | SpaceEditor | IMenuHelper |
| RAII 工具 | WaitCursor/FolderGuard | 无 | 无 |
| Python 暴露 | 无 | RompHarness | 无 |
| 双后端 | 是(MFC/QT) | 否 | 否(靠 editor_shared) |

`editor_shared` 是工具链 GUI 层的"后端隔离带",`guimanager` 是"GUI 框架",`tools_common` 是"业务公共层"。三者协作:工具实现 `editor_shared` 接口 → `editor_shared` 通过 `guimanager` 抽象操作 GUI → `tools_common` 提供业务能力。

### 9.6 双后端移植现状总结

```
组件                 MFC 后端    QT 后端    状态
─────────────────────────────────────────────────
IEditorApp          ✓           ✗         QT 缺 isMinimized
IMainFrame          ✓(接口)    ✓(接口)   接口共享,实现靠工具
MenuHelper          ✓           ⚠(复用MFC) 权宜之计
Cursor              ✓           ✗         QT 缺实现
WaitCursor          ✓           ✗         QT 缺实现
BWFileDialog        ✓           ✗         QT 缺实现
FolderGuard         ✓(共享)    ⚠(Win32)  共享但依赖 Win32
MessageBox          ✓           ✗         QT 缺实现
GuiTabContent       ✓(接口)    ✓(接口)   接口共享
─────────────────────────────────────────────────
总体                完整可用    不可用     QT 移植未完成
```

**结论:`editor_shared` 的 QT 后端是未完成的架构尝试,生产环境必须使用 MFC 后端。** 该库的核心价值在于抽象接口的定义与 MFC 实现的复用,而非真正的跨平台能力。理解这一点对维护 BigWorld 工具链至关重要。
