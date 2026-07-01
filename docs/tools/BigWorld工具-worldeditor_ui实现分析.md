# BigWorld 工具 worldeditor_ui 实现分析

> 本文档分析 BigWorld Engine 14.4.1 中 `worldeditor_ui` 目录的现状。**重要发现:该目录为空占位目录**,不含任何源码实现,实际 UI 逻辑全部位于 `worldeditor/gui/` 下。本文档说明该占位目录的成因、实际 UI 代码的分布,并简要介绍 `worldeditor/gui/` 的结构以供参考。

---

## 目录

- [一、目录现状与定位](#一目录现状与定位)
- [二、占位目录成因分析](#二占位目录成因分析)
- [三、实际 UI 代码分布(worldeditor/gui/)](#三实际-ui-代码分布worldeditorgui)
- [四、worldeditor_ui 的设计意图推测](#四worldeditor_ui-的设计意图推测)
- [五、worldeditor/gui/ 子模块概览](#五worldeditorgui-子模块概览)
- [六、与 common/editor_shared 的 UI 抽象关系](#六与-commoneditor_shared-的-ui-抽象关系)
- [七、注意事项](#七注意事项)

---

## 一、目录现状与定位

### 1.1 目录内容

`worldeditor_ui` 位于 `programming/bigworld/tools/worldeditor_ui/`,目录树如下:

```
tools/worldeditor_ui/
├── dir_keeper.txt          # 占位符文件(空)
├── binding/
│   └── dir_keeper.txt      # 占位符文件(空)
└── models/
    └── dir_keeper.txt      # 占位符文件(空)
```

**该目录仅含 3 个 `dir_keeper.txt` 占位文件,无任何 `.cpp`/`.hpp`/`.py` 源码。** `dir_keeper.txt` 是 BigWorld 仓库用于在版本控制中保留空目录的标准做法(因 Git 不跟踪空目录),文件内容为空。

### 1.2 目录定位

`worldeditor_ui` 在工具链中**不参与构建**,无 `CMakeLists.txt`,不被任何 `CMakeLists.txt` 引用。它是一个**规划中但未落地**的目录,实际 UI 逻辑全部内嵌于 `worldeditor/gui/`。

### 1.3 与 worldeditor 的关系

| 维度 | worldeditor_ui | worldeditor |
|------|----------------|-------------|
| 源码 | 无 | 100+ cpp 文件 |
| 构建 | 不参与 | `BW_ADD_TOOL_EXE(worldeditor)` |
| UI 逻辑 | 无 | `gui/` 子目录承载全部 UI |
| 占位文件 | 3 个 dir_keeper.txt | 无 |
| CMakeLists | 无 | 有 |

---

## 二、占位目录成因分析

### 2.1 设计意图推测

`worldeditor_ui` 目录下有两个子目录:`binding/` 与 `models/`。从命名推测,该目录可能规划用于:

| 子目录 | 推测用途 |
|--------|---------|
| `binding/` | UI 数据绑定层(如 ViewModel/View 绑定声明) |
| `models/` | UI 数据模型层(如 MVVM 的 Model) |

这暗示 BigWorld 团队曾规划将 WorldEditor 的 UI 逻辑从 `worldeditor/gui/`(深度耦合 MFC)中抽出,形成独立的、可复用的 UI 层(可能是为 QT 移植或数据驱动 UI 做准备)。但该规划**未实施**,目录保留为占位。

### 2.2 为何未落地

结合 `editor_shared` 的 `CMakeLists.qt.txt`(QT 移植不完整)与 `worldeditor/gui/` 的深度 MFC 耦合,可推断:

1. **MFC 耦合过深**:`worldeditor/gui/` 下的对话框、控件、属性页直接继承 MFC 类(`CDialog`/`CWnd`/`CPropertyPage`),抽取成本高
2. **QT 移植未完成**:`editor_shared` 的 QT 后端仅实现 `menu_helper`,其余对话框/光标/文件对话框均无 QT 版本
3. **优先级下降**:14.4.1 版本中 UI 抽象工作停滞,`worldeditor_ui` 作为未完成规划的残留

### 2.3 结论

`worldeditor_ui` 是一个**未完成的架构重构残留**,代表"将 UI 逻辑独立化"的设想。当前版本中应忽略该目录,所有 UI 分析应指向 `worldeditor/gui/`。

---

## 三、实际 UI 代码分布(worldeditor/gui/)

WorldEditor 的全部 UI 逻辑位于 `programming/bigworld/tools/worldeditor/gui/`,目录结构:

```
worldeditor/gui/
├── controls/           # 自定义 MFC 控件
├── dialogs/            # 模态对话框
├── pages/              # 属性页与 PanelManager
├── post_processing/    # 后处理链可视化编辑器
└── scene_browser/      # 场景浏览器
```

### 3.1 规模概览

| 子目录 | 文件数(对) | 主要职责 |
|--------|-----------|---------|
| `controls/` | ~11 | chunk 监视、目录浏览、文件图像列表、限位滑块、统计控件、地形纹理控件、天气设置表 |
| `dialogs/` | ~18 | CVS 信息、空间编辑/扩展/重建/新建、进度对话框、低内存、放置控件、RAW 导入、调整尺寸、闪屏、字符串输入、chunk 拍照、撤销警告、等待 |
| `pages/` | ~28 | chunk 纹理/监视、贴花、围栏、植被、消息、面板、物体、环境/通用/HDR/直方图/导航/天气选项、后处理、项目、属性、地形(基础/过滤/高度/导入/网格/标尺/纹理)、PanelManager、后处理链/属性/标题栏 |
| `post_processing/` | ~22 | 后处理节点/边/视图、链编辑器、属性编辑器、UAL 提供者、预览、撤销、视图皮肤 |
| `scene_browser/` | ~16 | 场景浏览器主体、复选框助手、列菜单、分组项、列/分组/搜索/选择状态、列表、对话框、工具、单项属性编辑 |

### 3.2 GUI 入口:PanelManager

`gui/pages/panel_manager.hpp/.cpp` 是 UI 的组织中枢,在 `InternalInitInstance` 末尾初始化:

```cpp
// world_editor_app.cpp:579
PanelManager::init( mainFrame, mainFrame->GetActiveView() );
```

`PanelManager` 管理 GUI 页面(GUITABS 撕离标签系统)的注册、布局与切换。

---

## 四、worldeditor_ui 的设计意图推测

### 4.1 MVVM 抽象设想

若 `worldeditor_ui` 落地,按 `binding/` + `models/` 结构推测,可能采用 MVVM(Model-View-ViewModel)模式:

```
worldeditor_ui/              (规划中)
├── models/                  # UI 数据模型(纯数据,无 UI 依赖)
│   ├── space_model          # 空间元数据
│   ├── chunk_model          # chunk 状态模型
│   └── selection_model      # 选择集模型
└── binding/                 # 模型与视图的绑定声明
    ├── python_binding       # Python 适配绑定
    └── mfc_binding          # MFC 控件绑定
```

这与现有 `worldeditor/gui/`(View 直接操作 Model)的紧耦合形成对比。

### 4.2 与 editor_shared 的呼应

`editor_shared` 已抽象出 `IMainFrame`/`IEditorApp`/`MenuHelper` 等 GUI 后端接口,意图支持 MFC/QT 双后端。`worldeditor_ui` 可能是配套的"UI 逻辑层独立化"尝试——将 UI 逻辑从 MFC View 中抽出,放到独立目录,便于切换后端。

但该尝试未推进,`worldeditor/gui/` 仍直接使用 MFC 类:

```cpp
// 示例:gui/dialogs/new_space_dlg.hpp(典型)
class NewSpaceDlg : public CDialog  // 直接继承 MFC
{
    ...
};
```

---

## 五、worldeditor/gui/ 子模块概览

### 5.1 controls/ 自定义控件

| 控件 | 文件 | 作用 |
|------|------|------|
| `chunk_watch_control` | chunk_watch_control.hpp/.cpp | chunk 状态监视控件 |
| `directory_browser` | directory_browser.hpp/.cpp | 目录浏览器 |
| `file_image_list` | file_image_list.hpp/.cpp | 文件图标列表 |
| `limit_slider` | limit_slider.hpp/.cpp | 带限位的滑块 |
| `statistics_control` | statistics_control.hpp/.cpp | 统计信息显示 |
| `terrain_textures_control` | terrain_textures_control.hpp/.cpp | 地形纹理列表 |
| `terrain_texture_lod_control` | terrain_texture_lod_control.hpp/.cpp | 地形纹理 LOD 控件 |
| `weather_settings_table` | weather_settings_table.hpp/.cpp | 天气设置表 |

### 5.2 dialogs/ 模态对话框

| 对话框 | 作用 |
|--------|------|
| `new_space_dlg` | 新建空间 |
| `edit_space_dlg` | 编辑空间元数据 |
| `expand_space_dlg` | 扩展空间边界 |
| `recreate_space_dlg` | 重建空间 |
| `resize_maps_dlg` | 调整地图尺寸 |
| `raw_import_dlg` | RAW 高度图导入 |
| `noise_setup_dlg` | 噪声设置 |
| `placement_ctrls_dlg` | 放置控件 |
| `new_placement_dlg` | 新建放置预设 |
| `string_input_dlg` | 字符串输入 |
| `take_chunk_photo_dlg` | chunk 截图 |
| `undo_warn_dlg` | 撤销警告 |
| `low_memory_dlg` | 低内存警告 |
| `cvs_info_dialog` | CVS 信息(遗留) |
| `splash_dialog` | 启动闪屏 |
| `wait_dialog` | 等待进度 |
| `labelled_progress_dlg` | 带标签进度 |
| `labelled_multitask_progress_dlg` | 多任务进度 |

### 5.3 pages/ 属性页

属性页通过 GUITABS 系统组织成可撕离标签。关键页面:

| 页面 | 作用 |
|------|------|
| `page_terrain_height` | 地形高度编辑 |
| `page_terrain_texture` | 地形纹理绘制 |
| `page_terrain_filter` | 地形过滤器 |
| `page_terrain_mesh` | 地形网格 |
| `page_terrain_import` | 地形导入 |
| `page_terrain_ruler` | 地形标尺 |
| `page_chunk_texture` | chunk 纹理 |
| `page_objects` | 物体放置 |
| `page_properties` | 属性编辑 |
| `page_project` | 项目管理 |
| `page_options_general` | 通用选项 |
| `page_options_environment` | 环境选项 |
| `page_options_weather` | 天气选项 |
| `page_options_hdr_lighting` | HDR 光照 |
| `page_options_histogram` | 直方图 |
| `page_options_navigation` | 导航选项 |
| `page_post_processing` | 后处理链 |
| `page_decals` | 贴花 |
| `page_fences` | 围栏 |
| `page_flora_setting` | 植被设置 |
| `page_chunk_watcher` / `chunk_watcher` | chunk 监视 |
| `page_my_panel` | 自定义面板 |
| `page_message_impl` | 消息页 |
| `panel_manager` | **面板管理中枢** |
| `post_processing_chains` | 后处理链编辑 |
| `post_processing_properties` | 后处理属性 |
| `post_proc_caption_bar` | 后处理标题栏 |

### 5.4 post_processing/ 后处理可视化编辑器

这是一个**节点图编辑器**,用于可视化编排后处理链:

| 组件 | 作用 |
|------|------|
| `base_post_processing_node` | 节点基类 |
| `effect_node` / `phase_node` | 特效节点 / 阶段节点 |
| `effect_edge` / `phase_edge` | 连接边 |
| `effect_node_view` / `phase_node_view` / `effect_edge_view` / `phase_edge_view` | 节点/边视图 |
| `chain_editors` | 链编辑器 |
| `post_proc_property_editor` | 属性编辑 |
| `post_proc_undo` | 后处理撤销 |
| `pp_preview` | 预览 |
| `ual_effect_provider` / `ual_phase_provider` / `ual_render_target_provider` | UAL 资产提供者 |
| `view_draw_utils` / `view_skin` | 绘制工具/皮肤 |
| `node_resource_holder` / `node_callback` | 资源持有/回调 |
| `popup_drag_target` | 拖拽目标 |

### 5.5 scene_browser/ 场景浏览器

场景浏览器是按属性分组浏览/筛选/选择场景物体的列表控件:

| 组件 | 作用 |
|------|------|
| `scene_browser` | 浏览器主体(单例) |
| `scene_browser_dlg` | 对话框容器 |
| `scene_browser_list` | 列表控件 |
| `list_column` / `list_column_states` | 列定义与状态 |
| `list_group_states` | 分组状态 |
| `list_search_filters` | 搜索过滤器 |
| `list_selection` | 选择管理 |
| `group_item` / `column_menu_item` | 分组项/列菜单项 |
| `checkbox_helper` | 复选框助手 |
| `single_property_editor` | 单属性编辑 |
| `setup_items_task` | 项设置后台任务 |
| `scene_browser_utils` | 工具函数 |

---

## 六、与 common/editor_shared 的 UI 抽象关系

`worldeditor/gui/` 通过 `editor_shared` 的抽象接口与 GUI 后端解耦:

```
┌─────────────────────────────────────────┐
│         worldeditor/gui/                │
│  (dialogs/pages/controls/...)           │
│  直接使用 MFC: CDialog/CWnd/...         │
└──────────────┬──────────────────────────┘
               │ 继承/使用
               ▼
┌─────────────────────────────────────────┐
│         editor_shared (抽象层)           │
│  IMainFrame / IEditorApp / MenuHelper   │
│  WaitCursor / BWFileDialog / FolderGuard│
└──────────────┬──────────────────────────┘
               │ 实现
               ▼
┌─────────────────────────────────────────┐
│    editor_shared/mfc/ (MFC 实现)        │
│    menu_helper.cpp / wait_cursor.cpp    │
│    file_dialog.cpp / message_box.cpp    │
└─────────────────────────────────────────┘
```

`MainFrame` 同时实现 `BaseMainFrame`(common)与 `IMainFrame`(editor_shared):

```cpp
// framework/mainframe.hpp:14-16
class MainFrame
    : public BaseMainFrame
    , public IMainFrame
    , GUI::ActionMaker<MainFrame>, ...
```

注意 `IMainFrame` 的多数方法在 `MainFrame` 中是**空实现**(因视口逻辑在 `WorldEditorView`),详见 worldeditor 文档 4.4 节。

---

## 七、注意事项

### 7.1 忽略 worldeditor_ui 目录

进行 WorldEditor UI 分析或修改时,**应完全忽略 `worldeditor_ui` 目录**,所有工作针对 `worldeditor/gui/`。

### 7.2 占位目录的清理建议

`worldeditor_ui` 目录可安全删除(仅含空 `dir_keeper.txt`),但建议保留以记录架构演进历史。若清理,需确认无文档/构建脚本引用该路径。

### 7.3 实际 UI 修改入口

修改 WorldEditor UI 的正确入口:

| 需求 | 入口 |
|------|------|
| 新增/修改对话框 | `worldeditor/gui/dialogs/` |
| 新增/修改属性页 | `worldeditor/gui/pages/` |
| 新增/修改自定义控件 | `worldeditor/gui/controls/` |
| 修改菜单/工具栏 | `resources/data/gui.xml` + `ActionMaker` 绑定 |
| 修改后处理编辑器 | `worldeditor/gui/post_processing/` |
| 修改场景浏览器 | `worldeditor/gui/scene_browser/` |
| 修改面板布局 | `worldeditor/gui/pages/panel_manager.cpp` |

### 7.4 GUI 数据驱动机制

UI 布局由 `resources/data/gui.xml` 描述,`GUI::ActionMaker`/`GUI::UpdaterMaker`/`GUI::OptionMap` 将 XML 项绑定到 C++ 方法(详见 worldeditor 文档 5.1 节)。这是理解 WorldEditor UI 的关键——**XML 定义"有什么",C++ 定义"做什么"**。

### 7.5 关键文件速查

| 文件 | 作用 |
|------|------|
| `worldeditor/gui/pages/panel_manager.cpp` | 面板管理中枢 |
| `worldeditor/gui/scene_browser/scene_browser.cpp` | 场景浏览器 |
| `worldeditor/gui/post_processing/chain_editors.cpp` | 后处理链编辑 |
| `worldeditor/gui/dialogs/new_space_dlg.cpp` | 新建空间对话框 |
| `worldeditor/gui/controls/chunk_watch_control.cpp` | chunk 监视控件 |
| `resources/data/gui.xml` | GUI 布局定义 |
| `resources/scripts/UIAdapter.py` | UI 适配脚本 |

### 7.6 总结

`worldeditor_ui` 是 BigWorld 工具链中一个**空占位目录**,代表未落地的 UI 层独立化规划。实际 UI 逻辑全部位于 `worldeditor/gui/`,该目录下按 `controls/`/`dialogs/`/`pages/`/`post_processing/`/`scene_browser/` 五个子模块组织,深度耦合 MFC。理解 WorldEditor UI 应直接阅读 `worldeditor/gui/` 与 `resources/data/gui.xml`,并参照 `editor_shared` 的抽象接口。

---

## 附录:目录文件清单

```
worldeditor_ui/
├── dir_keeper.txt          (0 字节,空)
├── binding/
│   └── dir_keeper.txt      (0 字节,空)
└── models/
    └── dir_keeper.txt      (0 字节,空)

总计:3 个文件,0 字节内容,0 行代码
```

**本目录不参与构建,无实现代码,分析 WorldEditor UI 请转至 `worldeditor/gui/`。**
