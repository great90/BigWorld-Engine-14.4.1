# 专题14:Moo 渲染管线深度剖析

> 本文档深度剖析 BigWorld Engine 14.4.1 中**客户端 D3D9 渲染引擎 Moo** 的完整实现,涵盖设计哲学、设备管理、场景图、Visual/Primitive/Vertices 三层结构、Material/Effect 材质体系、Forward/Deferred 双管线、灯光/阴影/雾效、纹理流式加载、RenderTarget/MRT/TAA 后处理、DebugDraw、热重载、性能优化与跨引擎对比。所有代码引用均带相对路径与行号,可在源码中直接定位。

---

## 目录

- [一、Moo 概述与设计哲学](#一moo-概述与设计哲学)
- [二、Moo 核心组件](#二moo-核心组件)
- [三、D3D 设备管理](#三d3d-设备管理)
- [四、场景图系统](#四场景图系统)
- [五、Visual 可视化对象](#五visual-可视化对象)
- [六、材质系统](#六材质系统)
- [七、几何与图元](#七几何与图元)
- [八、相机系统](#八相机系统)
- [九、灯光系统](#九灯光系统)
- [十、渲染管线流程](#十渲染管线流程)
- [十一、后处理系统](#十一后处理系统)
- [十二、纹理管理](#十二纹理管理)
- [十三、RenderTarget 渲染目标](#十三rendertarget-渲染目标)
- [十四、FogHelper 雾效](#十四foghelper-雾效)
- [十五、GPU 信息与性能](#十五gpu-信息与性能)
- [十六、TAA 支持与抗锯齿](#十六taa-支持与抗锯齿)
- [十七、MRT 支持](#十七mrt-支持)
- [十八、DebugDraw 调试绘制](#十八debugdraw-调试绘制)
- [十九、Reload 热重载](#十九reload-热重载)
- [二十、性能分析](#二十性能分析)
- [二十一、边界情况](#二十一边界情况)
- [二十二、与其他引擎对比](#二十二与其他引擎对比)
- [附录](#附录)

---

## 一、Moo 概述与设计哲学

BigWorld 客户端的渲染层名为 **Moo**,源码位于 `programming/bigworld/lib/moo/`。Moo 一名据传源自 "My Object Oriented" 的自嘲式缩写——这是一个 C++/D3D9 的封装层,既要承担和底层图形 API 的对话,又要为上层(Model、Chunk、SuperModel、PyModel、Flora、SpeedTree、Terrain 等)提供面向对象的渲染接口。

### 1.1 Moo 在客户端中的位置

```
┌──────────────────────────────────────────────────────────────────┐
│  上层应用(romp / chunk / model / terrain / speedtree / flora)   │
├──────────────────────────────────────────────────────────────────┤
│  Moo 渲染引擎                                                     │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐            │
│  │ RenderContext│  │ Renderer     │  │ DrawContext  │            │
│  │ (设备+状态)   │  │ (管线选择)   │  │ (延迟队列)   │            │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘            │
│         │                  │                  │                  │
│  ┌──────┴────────────────────────────────────┴───────┐           │
│  │  Visual / Primitive / Vertices / Material / Effect│           │
│  │  Texture / RenderTarget / Camera / Light          │           │
│  └───────────────────────┬──────────────────────────┘           │
├──────────────────────────────────────────────────────────────────┤
│  DirectX 9 / D3D9Ex                                               │
└──────────────────────────────────────────────────────────────────┘
```

| 子系统 | 主要文件 | 职责 |
|--------|----------|------|
| 设备封装 | `moo_dx.hpp/cpp`、`init.hpp/cpp`、`render_context.hpp/cpp` | 创建/重置 D3D 设备、状态缓存、设备回调 |
| 管线抽象 | `renderer.hpp/cpp`、`forward_pipeline.hpp/cpp`、`deferred_pipeline.hpp/cpp` | Forward/Deferred 双管线 |
| 场景图 | `node.hpp/ipp/cpp`、`node_catalogue.hpp/cpp` | 节点树、世界变换传播 |
| 几何与图元 | `vertices.hpp/ipp/cpp`、`primitive.hpp/ipp/cpp`、`geometry.hpp`、`vertex_format.hpp` | 顶点/索引缓冲、顶点声明 |
| Visual | `visual.hpp/ipp/cpp`、`visual_manager.hpp/ipp` | 三层嵌套可视对象 |
| 材质 | `material.hpp/ipp/cpp`、`effect_material.hpp/ipp/cpp`、`complex_effect_material.hpp/cpp`、`shader_set.hpp/ipp/cpp` | 固定管线材质 + FX 材质 |
| 灯光 | `omni_light.hpp/ipp`、`spot_light.hpp/ipp`、`pulse_light.hpp/cpp`、`directional_light.hpp/ipp`、`light_container.hpp/ipp/cpp` | 全向光/聚光灯/方向光/脉冲光 |
| 相机 | `camera.hpp/ipp/cpp`、`camera_planes_setter.hpp/cpp` | 投影矩阵、视锥 |
| 纹理 | `base_texture.hpp/ipp`、`managed_texture.hpp/ipp`、`texture_manager.hpp/cpp`、`streaming_texture.hpp/ipp` | 纹理缓存/流式加载 |
| RenderTarget | `render_target.hpp/ipp/cpp`、`cube_render_target.hpp/ipp/cpp` | 离屏渲染 |
| 后处理 | `post_processing/manager.hpp/cpp`、`effect.hpp/cpp`、`phase.hpp/cpp`、`filter_quad.hpp/cpp` | 全屏特效链 |
| 抗锯齿 | `taa_support.hpp/cpp`、`ppaa_support.hpp/cpp`、`custom_AA.hpp/cpp` | TAA / PPAA / FXAA |
| 阴影 | `shadow_manager.hpp/cpp`、`dynamic_shadow.hpp/cpp`、`semi_dynamic_shadow.hpp/cpp` | 动态/半动态阴影 |
| 调试 | `debug_draw.hpp/cpp`、`debug_geometry.hpp/cpp`、`line_helper.hpp/cpp` | 调试图元 |
| GPU 信息 | `gpu_info.hpp/cpp`、`gpu_profiler.hpp/ipp/cpp` | 显存/性能监控 |
| 热重载 | `reload.hpp/cpp`、`effect_compiler.hpp/cpp` | Visual/Effect 运行时重载 |

### 1.2 设计目标

Moo 的设计目标在 `render_context.hpp` 的注释和 `renderer.hpp` 中明确表达:

> **`renderer.hpp:28-35`** — "Base class represents renderer's pipeline. I.e. it manages how object will draw and how they will receive lighting, shadows and any other environment effects. There are two main types of the pipeline: Deferred Shading and Forward Shading. The second one is much more suited for low spec machines, but the first one adds a lot of additional geometrical info to make advanced effects like shadows, multiple lighting, deferred decals and so on through some initial overhead for filling fat back buffer, called GBuffer."

总结 Moo 的设计哲学:

1. **D3D9 封装,但不绑死 API 形态**:`DX::` 命名空间(见 `moo_dx.hpp:47-68`)将所有 D3D 类型定义集中,后续若切换到 D3D11/D3D12,只需替换这些 typedef。
2. **设备回调机制**(`DeviceCallback`)统一托管资源生命周期,以应对设备丢失/恢复。
3. **管线可插拔**:通过 `IRendererPipeline` 抽象接口,Forward/Deferred 两条路径互斥但接口一致。
4. **场景图与渲染队列解耦**:场景图负责变换传播,`DrawContext` 负责延迟渲染排序。
5. **材质分两层**:固定管线 `Material`(向后兼容)与可编程 `EffectMaterial`(.fx HLSL)共存。
6. **流式纹理加载**:`TextureStreamingManager` 支持按需上载 mipmap,适配大世界。
7. **跨未来 API 的野心**:从 `moo_dx.hpp` 中 `InterfaceEx`/`DeviceEx` 的引入可看出,设计者已为 D3D9Ex(Vista+)留好接口,以支持共享资源与多线程优化。

### 1.3 与 Unity 渲染管线的对比(概述)

| 维度 | BigWorld Moo | Unity(Built-in) | Unity(SRP/URP/HDRP) |
|------|--------------|-------------------|---------------------|
| API 抽象 | D3D9 + DX 命名空间 | 跨平台多后端 | 跨平台多后端 |
| 管线类型 | Forward / Deferred 二选一 | Forward / Deferred | 可编程 SRP |
| 场景图 | Node 树 + Chunk | Transform 树 | Transform 树 |
| 材质 | Material + EffectMaterial(.fx) | ShaderLab(.shader) | ShaderLab + ShaderGraph |
| 渲染队列 | DrawContext 排序 | RenderQueue | RenderPass + RenderQueue |
| 资源热重载 | Reloader 模式 | 无内置 | 无内置 |
| 大世界支持 | Chunk + 流式纹理 + 服务器推送 | SubScene | SubScene + HLOD |

### 1.4 与 Unreal 渲染管线的对比(概述)

| 维度 | BigWorld Moo | Unreal Engine 4/5 |
|------|--------------|-------------------|
| API 抽象 | DX 命名空间,仅 D3D9 | RHI 抽象层,D3D11/12/Vulkan/Metal |
| 管线类型 | Forward / Deferred 二选一 | Forward / Deferred / Path Tracer |
| 场景图 | Node 树 + Chunk | USceneComponent 树 |
| 材质 | EffectMaterial(.fx) | Material Editor(节点图) |
| 渲染队列 | DrawContext | FDeferredShadingSceneRenderer |
| 大世界 | Chunk 流式 + 服务器 | World Partition / Nanite / Lumen |
| 跨平台 | 仅 Windows D3D9 | 全平台 |
| Lumen GI | 无 | 有 |
| Nanite | 无 | 有 |

Moo 的设计年代(2010 年前后)与 Unity 4.x、UE3 同期,因此技术选型上更接近 UE3:固定管线 + 可编程混合、Forward 主路径、Deferred 作为高画质选项。

---

## 二、Moo 核心组件

### 2.1 模块入口 `init.hpp/cpp`

Moo 的入口非常简洁:

```cpp
// lib/moo/init.hpp:6-12
namespace Moo
{
    bool init( bool d3dExInterface = true, bool assetProcessingOnly = false );
    void fini();
    bool isInitialised();
}
```

实现位于 `init.cpp:23-41`:

```cpp
bool init( bool d3dExInterface, bool assetProcessingOnly )
{
    if ( !s_initialised )
    {
        MF_ASSERT_DEV( g_RC == NULL );
        if( g_RC == NULL )
        {
            g_RC = new RenderContext();
            REGISTER_SINGLETON_FUNC( RenderContext, &Moo::rc )
        }
        s_initialised = g_RC->init( d3dExInterface, assetProcessingOnly );
        return s_initialised;
    }
    return true;
}
```

关键点:
- **单例**:`RenderContext` 通过 `g_RC` 全局指针 + `Moo::rc()` 访问函数暴露。
- **assetProcessingOnly**:服务器/资产处理进程不需要真实设备,该参数跳过设备创建。
- **d3dExInterface**:是否优先使用 D3D9Ex 接口(Vista+ 才有,可共享资源、避免设备丢失)。

### 2.2 DX 命名空间

`moo_dx.hpp:47-88` 集中定义了 D3D 类型的别名:

```cpp
namespace DX
{
    typedef IDirect3D9              Interface;
    typedef IDirect3D9Ex            InterfaceEx;
    typedef IDirect3DDevice9       Device;
    typedef IDirect3DDevice9Ex      DeviceEx;
    typedef IDirect3DResource9      Resource;
    typedef IDirect3DBaseTexture9   BaseTexture;
    typedef IDirect3DTexture9       Texture;
    typedef IDirect3DCubeTexture9   CubeTexture;
    typedef IDirect3DSurface9       Surface;
    typedef IDirect3DVertexBuffer9  VertexBuffer;
    typedef IDirect3DIndexBuffer9   IndexBuffer;
    typedef IDirect3DPixelShader9   PixelShader;
    typedef IDirect3DVertexShader9  VertexShader;
    typedef IDirect3DVertexDeclaration9 VertexDeclaration;
    typedef IDirect3DQuery9         Query;
    typedef D3DLIGHT9               Light;
    typedef D3DVIEWPORT9            Viewport;
    typedef D3DMATERIAL9            Material;
    // ...
}
```

这种"typedef 别名"的做法看似简单,但为后续切换 API 留下了入口。例如,若要支持 D3D11,只需将 `Device` 重定义为 `ID3D11Device*`,业务代码无需改动(理想情况)。

辅助常量(行 22-45)定义了状态枚举的最大值,用于 RenderContext 中的状态缓存数组大小:

```cpp
#define D3DRS_MAX       210     // 大于 D3DRENDERSTATETYPE 最大值
#define D3DTSS_MAX      33      // 固定管线纹理阶段状态
#define D3DSAMP_MAX     14      // 采样器状态
#define D3DFFSTAGES_MAX 8       // 固定管线最多 8 个阶段
#define D3DSAMPSTAGES_MAX 261   // 大于 D3DVERTEXTEXTURESAMPLER3
```

### 2.3 Renderer 管线选择器

`renderer.hpp:36-139` 定义了 `IRendererPipeline` 抽象基类,它继承自 `DeviceCallback`,意味着**管线本身也是设备回调的参与者**,在设备丢失/恢复时会被通知。

`Renderer` 单例(`renderer.hpp:144-183`)持有 `std::auto_ptr<IRendererPipeline> m_pipeline` 指针,在 `init()` 中根据 `EffectMacroSetting` 选择具体管线:

```cpp
// lib/moo/renderer.cpp:99-108
if (g_pipelineMacroSetting->activeOption() == 0)
{
    m_type = IRendererPipeline::TYPE_DEFERRED_SHADING;
    m_pipeline.reset(new DeferredPipeline());
}
else
{
    m_type = IRendererPipeline::TYPE_FORWARD_SHADING;
    m_pipeline.reset(new ForwardPipeline());
}
```

`renderer.cpp:55-58` 还定义了一个 `EffectMacroSetting`,名字叫 `RENDER_PIPELINE`,作为 shader 编译时的宏开关:

```cpp
Moo::EffectMacroSetting::EffectMacroSettingPtr g_pipelineMacroSetting =
    new RenderPipelineSetting(
        "RENDER_PIPELINE", "Render pipeline", "BW_DEFERRED_SHADING",
        &configureKeywordSetting
    );
```

这意味着 shader 编译时会传入 `BW_DEFERRED_SHADING=1`(Deferred)或 `=0`(Forward),让 HLSL 端通过 `#ifdef` 切换代码路径。这是 Moo 设计中**管线与 shader 协同切换**的关键。

### 2.4 IRendererPipeline 接口

`renderer.hpp:43-139` 定义了管线的核心接口,可以视为 BigWorld 的"渲染生命周期":

| 方法 | 调用时机 | Forward 实现 | Deferred 实现 |
|------|---------|--------------|---------------|
| `init()` | 启动 | 空实现 | 初始化 Decals/Lights/Shadow 子系统 |
| `tick(dt)` | 每帧更新 | 空实现 | tick 各子系统 |
| `begin()` | 帧开始 | 设置 viewport,清屏 | 同 Forward,但额外 resetStencil |
| `beginCastShadows(dc)` | 阴影投射 pass | 空 | 委托 ShadowManager |
| `beginOpaqueDraw()` | 不透明绘制 | 设置色彩写掩码 | pushRenderTarget、绑 3 个 GBuffer Surface、setupSystemStencil |
| `applyLighting()` | 应用光照 | 空 | decals.draw → SSAO.resolve → Shadow.receive → HDR.intercept → Lights.draw |
| `endOpaqueDraw()` | 不透明结束 | 还原色彩写掩码 | popRenderTarget + 设置写掩码 |
| `beginSemitransparentDraw()` | 半透明绘制 | 设置色彩写掩码 | 空 |
| `endSemitransparentDraw()` | 半透明结束 | 还原色彩写掩码 | 画半透明树 + HDR.resolve + drawPostDeferred |
| `beginGUIDraw()` | UI 绘制 | 空 | resetStencil + pushRenderTarget |
| `endGUIDraw()` | UI 结束 | 空 | popRenderTarget |

`renderer.hpp:64-70` 还定义了 **stencil usage** 的位掩码:

```cpp
enum EStencilUsage
{
    STENCIL_USAGE_TERRAIN       = 1 << 4,
    STENCIL_USAGE_SPEEDTREE     = 1 << 5,
    STENCIL_USAGE_FLORA         = 1 << 6,
    STENCIL_USAGE_OTHER_OPAQUE  = 1 << 7
};
```

注释明确指出:**4 个高位 (0xF0) 由系统占用**用于存储像素类型,**4 个低位 (0x0F) 留给自定义**。这是 Deferred 管线中**按像素类型选择性应用光照**的基础(例如只对 Terrain 应用 SSAO)。

### 2.5 主循环集成

虽然 `Renderer` 不直接驱动主循环,但典型用法为:

```cpp
// 伪代码:客户端主循环
Renderer::instance().tick(dt);              // 1. 更新管线状态
rp().begin();                                // 2. 帧开始
rp().beginCastShadows(shadowDC);            // 3. 阴影 pass
// ... 渲染阴影投射几何 ...
rp().endCastShadows();
rp().beginOpaqueDraw();                     // 4. 不透明 pass
// ... 提交 DrawContext ...
drawContext.flush(OPAQUE_CHANNEL_MASK);
rp().endOpaqueDraw();
rp().applyLighting();                       // 5. 应用光照
rp().beginSemitransparentDraw();            // 6. 半透明 pass
drawContext.flush(TRANSPARENT_CHANNEL_MASK);
rp().endSemitransparentDraw();
// 7. 后处理
PostProcessing::Manager::instance().draw();
rp().beginGUIDraw();                        // 8. UI pass
// ... GUI ...
rp().endGUIDraw();
rp().end();                                  // 9. 帧结束
Moo::rc().present();                         // 10. 提交
```

这种结构既清晰又灵活,Forward 模式下 `applyLighting()`/`beginCastShadows()` 都是空实现,等同于直接画到 backbuffer;Deferred 模式下则填充 GBuffer 并在 `applyLighting()` 阶段做光照累积。

---

## 三、D3D 设备管理

D3D9 是一个**有状态、可丢失**的 API。Moo 必须处理:

1. 设备创建(`createDevice`)
2. 设备丢失(`Lost Device`,例如用户切换到独占全屏的其他应用)
3. 设备恢复(`resetDevice` → 重建 unmanaged 资源)
4. 模式切换(全屏 ↔ 窗口)
5. 多显示器支持

### 3.1 设备创建流程

`RenderContext::createDevice`(`render_context.hpp:146-157`)签名:

```cpp
bool createDevice( HWND hWnd,
                   uint32 deviceIndex           = 0,
                   uint32 modeIndex             = 0,
                   bool windowed                = true,
                   bool wantStencil             = false,
                   const Vector2 & windowedSize  = Vector2(0, 0),
                   bool hideCursor              = true,
                   bool forceRef                = false
#if ENABLE_ASSET_PIPE
                   , AssetClient* pAssetClient  = NULL
#endif
);
```

参数含义:
- `hWnd`:渲染目标窗口句柄
- `deviceIndex`/`modeIndex`:从 `devices_` 列表中选择哪个适配器和哪种显示模式
- `windowed`:窗口模式(true)或全屏(false)
- `wantStencil`:是否需要 stencil buffer(Deferred 必需)
- `windowedSize`:窗口大小
- `hideCursor`:是否隐藏鼠标
- `forceRef`:强制使用参考设备(调试用)

设备创建大致步骤:
1. 调用 `fillPresentationParameters()` 填充 `D3DPRESENT_PARAMETERS`
2. 根据 `d3dDeviceExCapable_` 决定使用 `IDirect3D9Ex` 还是 `IDirect3D9`
3. `d3d_->CreateDeviceEx(...)` 或 `d3d_->CreateDevice(...)` 创建设备
4. 查询 caps,设置 `psVersion_`、`vsVersion_`、`maxSimTextures_`、`maxAnisotropy_`、`mrtSupported_`
5. `createUnmanaged()` + `createManaged()` 触发所有 DeviceCallback
6. 设置 gamma、cursor 等

### 3.2 设备丢失与恢复

D3D9 设备丢失场景:
- 全屏应用失去焦点
- 系统睡眠/锁屏
- 显卡驱动更新
- 外接显示器热插拔

设备丢失后,**所有 D3DPOOL_DEFAULT 资源(即 unmanaged)失效**,需要释放后重建。Moo 的处理流程:

```
用户操作 → 设备丢失
   ↓
TestCooperativeLevel() 返回 D3DERR_DEVICELOST
   ↓ 等待
TestCooperativeLevel() 返回 D3DERR_DEVICENOTRESET
   ↓
RenderContext::releaseUnmanaged(forceRelease=true)
   → DeviceCallback::deleteAllUnmanaged(true)
   → 遍历所有 DeviceCallback,调用 deleteUnmanagedObjects()
   ↓
RenderContext::resetDevice()
   → device_->Reset(&presentParameters_)
   ↓
RenderContext::createUnmanaged(forceCreate=true)
   → DeviceCallback::createAllUnmanaged(true)
   → 遍历所有 DeviceCallback,调用 createUnmanagedObjects()
```

`DeviceCallback::deleteAllUnmanaged`(`device_callback.cpp:173-206`)的实现关键点:

```cpp
void DeviceCallback::deleteAllUnmanaged( bool forceRelease )
{
    // if we're not in d3dex mode we have to release everything
    if (!Moo::rc().usingD3DDeviceEx())
    {
        forceRelease = true;
    }
    // ...
    while( it != end )
    {
        statics.s_curCallback = *it;
        if (forceRelease || (*it)->recreateForD3DExDevice())
        {
            (*it)->deleteUnmanagedObjects();
        }
        it++;
    }
    // ...
}
```

注意 `forceRelease` 参数:**D3D9Ex 设备**在丢失时无需释放资源(由驱动托管),因此只有 `recreateForD3DExDevice()` 返回 true 的回调才需要被通知。这就是 `RenderTarget` 等资源会重写 `recreateForD3DExDevice()` 返回不同值的原因(`render_target.hpp:52`)。

### 3.3 资源分类:Managed vs Unmanaged

D3D9 资源池类型(`D3DPOOL`):

| Pool | 含义 | 设备丢失时 | Moo 处理 |
|------|------|-----------|---------|
| `D3DPOOL_MANAGED` | 由驱动备份,自动恢复 | 自动 | `createManagedObjects`/`deleteManagedObjects`(空实现居多) |
| `D3DPOOL_DEFAULT` | 显存中,设备丢失时失效 | 失效 | `createUnmanagedObjects`/`deleteUnmanagedObjects`(核心实现) |
| `D3DPOOL_SYSTEMMEM` | 系统内存,与设备无关 | 不变 | 一般用于纹理加载中转 |
| `D3DPOOL_SCRATCH` | 临时资源 | 不变 | 工具用 |

`DeviceCallback` 的四元组接口:

```cpp
// lib/moo/device_callback.hpp:27-32
virtual void deleteUnmanagedObjects( );
virtual void createUnmanagedObjects( );
virtual void deleteManagedObjects( );
virtual void createManagedObjects( );
```

任何持有 D3D 资源的类(如 `BaseTexture`、`RenderTarget`、`Visual`、`Primitive`、`Vertices`、`EffectMaterial`、`MRTSupport`、`TemporalAASupport` 等)都继承 `DeviceCallback`,实现这些方法以正确处理设备丢失。

### 3.4 GenericUnmanagedCallback 函数式回调

对于"只想在某处插入一段创建/销毁逻辑"的场景,`GenericUnmanagedCallback`(`device_callback.hpp:52-69`)提供了 lambda 风格的封装:

```cpp
class GenericUnmanagedCallback : public DeviceCallback
{
public:
    typedef void Function( );
    GenericUnmanagedCallback( Function* createFunction, Function* destructFunction );
    void deleteUnmanagedObjects( );  // 调 destructFunction_()
    void createUnmanagedObjects( );  // 调 createFunction_()
private:
    Function* createFunction_;
    Function* destructFunction_;
};
```

这样,在某个函数内部就可以注册一对创建/销毁逻辑,无需定义新类。

### 3.5 多显示器支持

`RenderContext::init`(`render_context.cpp:364-454`)在创建设备前会枚举所有适配器:

```cpp
for (uint32 adapterIndex = 0; adapterIndex < d3d_->GetAdapterCount(); adapterIndex++)
{
    DeviceInfo deviceInfo;
    deviceInfo.windowed_ = false;
    deviceInfo.adapterID_ = adapterIndex;
    if (D3D_OK == d3d_->GetAdapterIdentifier( adapterIndex, 0, &deviceInfo.identifier_ ))
    {
        if (D3D_OK == d3d_->GetDeviceCaps( adapterIndex, D3DDEVTYPE_HAL, &deviceInfo.caps_ ))
        {
            // 设置 compatibility flags
            // 枚举所有支持的 DisplayMode
            for (uint32 fi = 0; fi < nFormats; fi++)
            {
                for (uint32 modeIdx = 0; modeIdx < d3d_->GetAdapterModeCount(...); modeIdx++)
                {
                    d3d_->EnumAdapterModes(...);
                    // 去重 + 限制 Width>=640 && Height>=480
                }
            }
            std::sort(deviceInfo.displayModes_.begin(), deviceInfo.displayModes_.end());
            devices_.push_back( deviceInfo );
        }
    }
}
```

枚举过程还做了三件重要事情:

#### 3.5.1 兼容性标记

`render_context.cpp:377-414` 设置了多个 `compatibilityFlags_`:

```cpp
const uint32 VENDOR_ID_ATI = 0x1002;
const uint32 VENDOR_ID_NVIDIA = 0x10de;

if (strstr(deviceInfo.identifier_.Description, "GeForce4 MX") != NULL)
    deviceInfo.compatibilityFlags_ |= COMPATIBILITYFLAG_NOOVERWRITE;
if (deviceInfo.identifier_.VendorId == VENDOR_ID_NVIDIA)
    deviceInfo.compatibilityFlags_ |= COMPATIBILITYFLAG_NVIDIA;
if (deviceInfo.identifier_.VendorId == VENDOR_ID_ATI)
    deviceInfo.compatibilityFlags_ |= COMPATIBILITYFLAG_ATI;

// Deferred shading 兼容性
bool supported = true;
supported &= (deviceInfo.caps_.VertexShaderVersion >= 0x300);
supported &= (deviceInfo.caps_.PixelShaderVersion  >= 0x300);
supported &= (deviceInfo.caps_.NumSimultaneousRTs   >= 3);
supported &= (deviceInfo.caps_.PrimitiveMiscCaps & D3DPMISCCAPS_INDEPENDENTWRITEMASKS) != 0;
if (supported)
    deviceInfo.compatibilityFlags_ |= COMPATIBILITYFLAG_DEFERRED_SHADING;
```

这些标志(`render_context.hpp:48-54`)在后续代码中决定具体代码路径:

```cpp
enum CompatibilityFlag
{
    COMPATIBILITYFLAG_NOOVERWRITE         = 1 << 0,  // GeForce4 MX 不支持 NOOVERWRITE
    COMPATIBILITYFLAG_NVIDIA              = 1 << 1,  // nVidia 卡专用路径
    COMPATIBILITYFLAG_ATI                  = 1 << 2,  // ATI 卡专用路径
    COMPATIBILITYFLAG_DEFERRED_SHADING     = 1 << 3   // 支持 Deferred
};
```

这种"运行时探测硬件能力"的做法在 D3D9 时代非常常见,因为那时的硬件能力差异巨大(从 Shader Model 2.0 到 3.0,从无 MRT 到 4 RT)。

#### 3.5.2 显示模式去重与限制

`render_context.cpp:428-432`:

```cpp
if( mode.Width >= 640 && mode.Height >= 480 )
{
    deviceInfo.displayModes_.push_back( mode );
}
```

640×480 以下的模式被丢弃,避免误选无效分辨率。

#### 3.5.3 D3D9Ex 探测

`render_context.cpp:238-263` 定义了一个匿名命名空间函数 `createD3DEx()`,通过 `LoadLibrary("d3d9.dll")` + `GetProcAddress("Direct3DCreate9Ex")` 动态探测 Vista+ 是否支持 D3D9Ex:

```cpp
IDirect3D9Ex* createD3DEx()
{
    IDirect3D9Ex *pD3D = NULL;
    HMODULE hDll = LoadLibrary( L"d3d9.dll" );
    if ( hDll )
    {
        LPDIRECT3DCREATE9EX func = (LPDIRECT3DCREATE9EX)
            GetProcAddress( hDll, "Direct3DCreate9Ex" );
        if ( func )
        {
            if ( FAILED( func( D3D_SDK_VERSION, &pD3D ) ) )
            {
                FreeLibrary( hDll );
                pD3D = NULL;
            }
        }
        FreeLibrary( hDll );
    }
    return pD3D;
}
```

如果 `d3dExTmp != NULL`,则 `d3dDeviceExCapable_ = true`,后续可以创建 `IDirect3DDevice9Ex` 设备,获得以下优势:
- **避免设备丢失**:Ex 设备不会因切换窗口而丢失
- **共享资源**:跨进程共享纹理
- **更细粒度的资源管理**:`recreateForD3DExDevice()` 返回 false 的资源无需重建

### 3.6 全屏/窗口切换

`RenderContext::changeMode`(`render_context.hpp:160-164`)负责模式切换:

```cpp
bool changeMode( 
    uint32 modeIndex, 
    bool   windowed, 
    bool   testCooperative = false,
    uint32 backBufferWidthOverride = 0 );
```

实现要点(`render_context.cpp:571+`):
1. 检查是否正在切换中(`s_changingMode` 全局标志防止递归)
2. 切换到全屏前保存窗口 style(`WS_OVERLAPPEDWINDOW`),设为 `WS_POPUP`(无边框)
3. 切换到窗口前恢复 style
4. 调用 `changeModePriv()` 实际执行 `device_->Reset(&presentParameters_)`
5. 处理 `testCooperative` 参数(设备未丢失时才切换)

### 3.7 状态缓存

D3D9 是有状态的 API,每次 `SetRenderState`/`SetTextureStageState`/`SetSamplerState`/`SetTexture` 都有开销。Moo 在 `RenderContext` 中维护了一份**状态缓存**,只有当值变化时才下发到 D3D:

```cpp
// lib/moo/render_context.hpp:606-612
RSCacheEntry      rsCache_[D3DRS_MAX];                          // RenderState
TSSCacheEntry     tssCache_[D3DFFSTAGES_MAX][D3DTSS_MAX];      // TextureStageState
SampCacheEntry    sampCache_[D3DSAMPSTAGES_MAX][D3DSAMP_MAX];  // SamplerState
TextureCacheEntry textureCache_[D3DSAMPSTAGES_MAX];            // Texture
uint              vertexDeclarationId_;
DX::VertexDeclaration* vertexDeclaration_;
uint32            fvf_;
```

`RenderContext::setRenderState` 的实现模式:

```cpp
uint32 RenderContext::setRenderState(D3DRENDERSTATETYPE state, uint32 value)
{
    // 缓存命中:直接返回
    if (rsCache_[state].currentValue == value && 
        rsCache_[state].Id == cacheValidityId_)
        return 0;
    // 缓存未命中:下发到设备
    rsCache_[state].currentValue = value;
    rsCache_[state].Id = cacheValidityId_;
    return device_->SetRenderState(state, value);
}
```

`invalidateStateCache()`(`render_context.hpp:445`)通过递增 `cacheValidityId_` 让所有缓存失效,常用于设备重置后强制重新设置所有状态。

返回值表示"实际下发到设备的次数",可用于性能统计。

---

## 四、场景图系统

Moo 的场景图位于 `node.hpp/cpp/ipp`,虽然简单,但承担着**骨骼变换传播**的关键职责。

### 4.1 Node 类定义

`node.hpp:31-112`:

```cpp
class Node : public SafeReferenceCount
{
public:
    static const char* SCENE_ROOT_NAME;

    Node();
    ~Node();

    void            traverse( );                    // 遍历并更新世界变换
    void            loadIntoCatalogue( );            // 复制到全局 NodeCatalogue
    void            visitSelf( const Matrix& parent );

    void            addChild( NodePtr node );
    void            removeFromParent( );
    void            removeChild( NodePtr node );

    Matrix&         transform( );                    // 局部变换
    const Matrix&   worldTransform( ) const;          // 世界变换(由 traverse 计算)
    void            worldTransform( const Matrix& );

    NodePtr         parent( ) const;
    uint32          nChildren( ) const;
    NodePtr         child( uint32 i );

    const BW::string&   identifier( ) const;
    void            identifier( const BW::string& identifier );
    bool            isSceneRoot() const;

    NodePtr         find( const BW::string& identifier );
    uint32          countDescendants( ) const;

    void            loadRecursive( DataSectionPtr nodeSection );

    bool            needsReset( int blendCookie ) const;
    float           blend( int blendCookie ) const;
    void            blend( int blendCookie, float blendRatio );
    void            blendClobber( int blendCookie, const Matrix & transform );

#ifdef _WIN32
    BlendTransform &    blendTransform();
#endif

private:
    Matrix          transform_;              // 局部变换
    Matrix          worldTransform_;         // 世界变换(由 traverse 计算)
    int             blendCookie_;           // 用于动画混合的 cookie
    float           blendRatio_;            // 混合权重
#ifdef _WIN32
    BlendTransform  blendTransform_;        // 平滑变换混合
#endif
    bool            transformInBlended_;
    Node*           parent_;                // 注意:不是智能指针
    NodePtrVector   children_;              // 子节点用智能指针
    BW::string      identifier_;
    bool            isSceneRoot_;
public:
    static int      s_blendCookie_;
};
```

注意 `parent_` 不是智能指针(注释行 98-99 说明这是为了避免循环引用导致整棵树无法析构),而 `children_` 是智能指针。这是一种常见的"父强子弱"模式,但在这里反了过来:**父持有弱引用(裸指针),子持有强引用(智能指针)**——这意味着只要某节点被外部引用,整棵子树都不会被销毁。

### 4.2 节点变换的传播:traverse 算法

`node.cpp:60-78`:

```cpp
void Node::traverse( )
{
    BW_GUARD;
    // Update transform
    Moo::rc().push();
    Moo::rc().preMultiply( this->transform() );
    this->worldTransform( Moo::rc().world() );	

    // Iterate and recurse through children
    NodePtrVector::iterator it = children_.begin();
    NodePtrVector::iterator end = children_.end();
    while (it != end)
    {
        (*it)->traverse();
        ++it;
    }
    Moo::rc().pop();
}
```

注意 `traverse()` 通过 `Moo::rc().push()/pop()` 操作 RenderContext 中的世界矩阵栈:
1. `push()` 保存当前世界矩阵
2. `preMultiply(transform_)` 将局部变换左乘到当前世界矩阵,得到该节点的世界变换
3. `worldTransform_ = rc().world()` 保存结果
4. 递归处理所有子节点
5. `pop()` 恢复父世界矩阵

这是一个**深度优先、基于栈**的遍历,时间复杂度 O(N),空间复杂度 O(树深)。

### 4.3 NodeCatalogue 全局目录

`loadIntoCatalogue`(`node.cpp:86-101`)将节点的世界变换复制到全局 `NodeCatalogue`:

```cpp
void Node::loadIntoCatalogue( )
{
    NodePtr pGlobalNode = NodeCatalogue::instance().find( identifier_.c_str() );
    pGlobalNode->worldTransform(worldTransform_);	

    NodePtrVector::iterator it = children_.begin();
    NodePtrVector::iterator end = children_.end();
    while (it != end)
    {
        (*it)->loadIntoCatalogue();
        ++it;
    }
}
```

这是为了**多个 Visual 共享同一套骨骼**而设计的:不同的 Model 实例可以通过 identifier 找到全局变换,而不需要每次都重新计算。

### 4.4 动画混合:blendCookie

`Node` 持有 `blendCookie_` 和 `blendRatio_`,用于支持多个动画的混合:

```cpp
bool needsReset( int blendCookie ) const;
float blend( int blendCookie ) const;
void blend( int blendCookie, float blendRatio );
void blendClobber( int blendCookie, const Matrix & transform );
```

`blendCookie` 是一个"帧 cookie",每次开始新的动画混合时递增(`s_blendCookie_`)。如果一个节点的 `blendCookie_` 不等于当前 cookie,说明它尚未参与本轮混合,需要先用 `blendClobber` 写入基础变换;否则用 `blend` 累加权重。

这种"cookie 标记"模式避免了每帧清空所有节点的开销。

### 4.5 场景图与 Chunk 的协作

BigWorld 的大世界由 **Chunk**(`lib/chunk/`)组成,每个 Chunk 是一个固定的空间单元(默认 100×100 米)。Chunk 内的静态模型直接放置,动态模型(Entity)则在 Chunk 间迁移。

Moo 的 Node 树主要服务于 **动态模型** 的骨骼动画。Chunk 中的静态模型(如 `ChunkModel`、`ChunkTree`)直接使用 Visual 的 root 节点,不需要每帧 traverse。

---

## 五、Visual 可视化对象

`Visual`(`visual.hpp:249-495`)是 Moo 中**基本的可绘制网格对象**,类似于 Unity 的 MeshRenderer + Mesh 或 Unreal 的 StaticMesh。

### 5.1 三层嵌套结构

`Visual` 内部组织为三层:

```
Visual
  └─ RenderSetVector (多组,通常 1 组)
       └─ RenderSet
            ├─ transformNodes_ (NodePtrVector,引用 Node 树的子集)
            └─ GeometryVector (多组几何)
                 └─ Geometry
                      ├─ vertices_   (VerticesPtr)
                      ├─ primitives_ (PrimitivePtr)
                      └─ primitiveGroups_ (PrimitiveGroupVector,每组对应一个材质)
```

数据结构定义(`visual.hpp:321-357`):

```cpp
struct PrimitiveGroup
{
    uint32                  groupIndex_;
    ComplexEffectMaterialPtr material_;
};
typedef BW::vector< PrimitiveGroup > PrimitiveGroupVector;

struct Geometry
{
    VerticesPtr             vertices_;
    PrimitivePtr            primitives_;
    PrimitiveGroupVector    primitiveGroups_;
    uint32 nTriangles() const;
};
typedef BW::vector< Geometry > GeometryVector;

class RenderSet
{
public:
    bool                treatAsWorldSpaceObject_;
    NodePtrVector       transformNodes_;
    GeometryVector      geometry_;
    Matrix              firstNodeStaticWorldTransform_;
};
typedef BW::vector< RenderSet > RenderSetVector;
```

#### 5.1.1 为什么要 RenderSet?

一个 Visual 可能包含多个 RenderSet,每个 RenderSet 共享同一组变换节点(骨骼)。例如角色模型:
- RenderSet 0:身体(用 50 个骨骼节点)
- RenderSet 1:武器(用 5 个骨骼节点,附属于身体骨骼)

这样可以在 GPU 端只上传该 RenderSet 需要的骨骼矩阵,而不是全部。

#### 5.1.2 treatAsWorldSpaceObject_

`true` 表示该 RenderSet 的几何已经在世界空间(如 Chunk 中的静态模型),不需要应用 world matrix;`false` 表示需要应用 Model 的 world matrix。

### 5.2 Visual 的资源格式

Visual 文件通常以 `.visual` 后缀存储(XML 格式),内部引用 `.primitives` 二进制文件:

```xml
<visual>
    <renderSet>
        <node>Root</node>
        <node>Bone1</node>
        <geometry>
            <vertices>objects/bob.primitives/BobVertices</vertices>
            <primitive>objects/bob.primitives/BobIndices</primitive>
            <group>0</group>
            <material>objects/bob.material</material>
        </geometry>
    </renderSet>
</visual>
```

`.primitives` 文件结构(见 `primitive_file_structs.hpp:14-63`):

```cpp
struct VertexHeader
{
    char    vertexFormat_[64];   // 顶点格式名,如 "XYZNUV"
    int     nVertices_;
};

struct IndexHeader
{
    char    indexFormat_[64];    // "list" 或 "list32"
    int     nIndices_;
    int     nTriangleGroups_;
};

struct PrimitiveGroup
{
    int     startIndex_;
    int     nPrimitives_;
    int     startVertex_;
    int     nVertices_;
};
```

`.primitives` 文件以 `IndexHeader` 开头,后跟索引数据,可以包含多个 PrimitiveGroup。

### 5.3 Visual::draw 流程

`visual.hpp:378-379` 声明:

```cpp
HRESULT draw( Moo::DrawContext& drawContext, bool ignoreBoundingBox = false,
            bool useDefaultPose = true );
```

注意:**Visual 不直接调用 DrawPrimitive**,而是将渲染操作提交到 `DrawContext`。这是 Moo 设计中的延迟渲染队列(详见第十节)。

`draw()` 内部大致流程:
1. 视锥剔除(通过 `VisualHelper::shouldDraw` 检查 worldSpaceBB)
2. 设置灯光容器(`addLightsInModelSpace`/`addLightsInWorldSpace`)
3. 对每个 RenderSet:
   - 用 `EffectVisualContextSetter` 设置骨骼矩阵 palette
   - 对每个 Geometry:
     - 对每个 PrimitiveGroup:
       - 调用 `drawContext.drawRenderOp(material, vertices, primitives, groupIndex, instanceData, worldBB)`

### 5.4 VisualHelper

`visual.hpp:90-107`:

```cpp
class VisualHelper
{
public:
    VisualHelper();
    bool shouldDraw( bool ignoreBoundingBox, const BoundingBox& bb );
    void start( const BoundingBox& bb, bool rendering = true );
    void fini( bool rendering = true );
    const BoundingBox& worldSpaceBB() { return wsBB_; }
    const Matrix& worldViewProjection() { return worldViewProjection_; }
private:
    LightContainerPtr pRCLC_;
    LightContainerPtr pRCSLC_;
    LightContainerPtr pLC_;
    LightContainerPtr pSLC_;
    BoundingBox wsBB_;
    Matrix worldViewProjection_;
};
```

`shouldDraw` 做**视锥剔除**:将 bounding box 变换到世界空间,与当前相机视锥求交。

### 5.5 EffectVisualContextSetter 矩阵 Palette

`visual.hpp:501-513`:

```cpp
class EffectVisualContextSetter
{
public:
    EffectVisualContextSetter( Visual::RenderSet* pRenderSet );
    ~EffectVisualContextSetter();
private:
    static const uint32 NUM_VECTOR4_PER_PALETTE_MATRIX = 3;
    static const uint32 MAX_WORLD_PALETTE_SIZE = 256 * NUM_VECTOR4_PER_PALETTE_MATRIX;
    Vector4 matrixPalette_[MAX_WORLD_PALETTE_SIZE];
};
```

每个骨骼矩阵用 3 个 Vector4 表示(矩阵的 3 行,第四行隐含为 [0,0,0,1])。最多支持 256 个骨骼,与 SM3.0 的常量寄存器上限对齐。

构造时遍历 `RenderSet::transformNodes_`,将每个节点的世界变换写入 palette;析构时通过 EffectVisualContext 提交给 shader 常量。

### 5.6 Visual 附加数据

Visual 还包含:
- `portals_`(`visual.hpp:37`):Portal 系统,用于 Chunk 间可见性传递
- `pBSP_`(`visual.hpp:486`):碰撞检测用的 BSP 树
- `constraints_`(`visual.hpp:482`):IK 约束数据(`ConstraintData`,行 114-196)
- `ikHandles_`(`visual.hpp:484`):IK 句柄数据(`IKHandleData`,行 203-235)
- `bb_`(`visual.hpp:475`):包围盒
- `animations_`(`visual.hpp:471`):默认动画

`ConstraintData` 支持 5 种类型(`visual.hpp:118-121`):

```cpp
enum ConstraintType
{
    CT_AIM,         // 瞄准约束(如炮塔朝向目标)
    CT_ORIENT,      // 朝向约束
    CT_POINT,       // 点约束
    CT_PARENT,      // 父约束
    CT_POLE_VECTOR  // 极向量约束(IK 用)
};
```

### 5.7 VisualManager 缓存

`visual_manager.hpp:19-61`:

```cpp
class VisualManager : public ResourceModificationListener
{
public:
    typedef StringRefMap< Visual* > VisualMap;
    static VisualManager* instance();
    VisualPtr get( const BW::StringRef& resourceID, bool loadIfMissing = true );
    void fullHouse( bool noMoreEntries = true );
    // ...
private:
    VisualMap   visuals_;
    SimpleMutex visualsLock_;
    bool        fullHouse_;
};
```

`get()` 是按 resourceID 缓存的工厂方法。`fullHouse_` 标志为 true 时拒绝新条目进入,用于内存吃紧时强制走"占位"路径。

### 5.8 ReadGuard 并发读取

`visual.hpp:361-367`:

```cpp
struct ReadGuard
{
    ReadGuard( Visual* visual );
    ~ReadGuard();
private:
    Visual* visual;
};
```

配合 `beginRead()`/`endRead()`(`visual.hpp:451-452`)使用。当 ENABLE_RELOAD_MODEL 开启时,`ReadGuard` 构造时获取读锁,析构时释放。这允许一边在渲染线程读 Visual 数据,一边在加载线程热重载 Visual。

---

## 六、材质系统

Moo 的材质系统是**双轨制**:

1. **`Material`**(`material.hpp`):固定管线材质,设置 D3D RenderState/TextureStageState
2. **`EffectMaterial`**(`effect_material.hpp`):可编程材质,封装 D3DX Effect(.fx)
3. **`ComplexEffectMaterial`**(`complex_effect_material.hpp`):在 EffectMaterial 之上,管理多 pass 技巧(阴影、反射、Instanced)

### 6.1 Material 固定管线材质

`material.hpp:37-250`:

```cpp
class Material
{
public:
    typedef enum UV2Generator_ { NONE, CHROME, PROJECTION, NORMAL, ROLLING_UV, TRANSFORM, LAST_UV2_GENERATOR } UV2Generator;
    typedef enum UV2Angle_     { TOP, SIDE, FRONT, LAST_UV2_ANGLE } UV2Angle;
    typedef enum BlendType_    { ZERO, ONE, SRC_COLOUR, INV_SRC_COLOUR, SRC_ALPHA, INV_SRC_ALPHA, DEST_ALPHA, INV_DEST_ALPHA, DEST_COLOUR, INV_DEST_COLOUR, SRC_ALPHA_SAT, BOTH_SRC_ALPHA, BOTH_INV_SRC_ALPHA, LAST_BLENDTYPE = 0x7FFFFFFF } BlendType;

    enum Channel
    {
        SOLID   = 1 << 0,
        SORTED  = 1 << 1,
        SHIMMER = 1 << 2,
        FLARE   = 1 << 3
    };

    // 颜色
    const Colour&   ambient() const;
    const Colour&   diffuse() const;
    const Colour&   specular() const;

    // 混合
    bool            alphaBlended() const;
    BlendType       srcBlend() const;
    BlendType       destBlend() const;

    // ZBuffer
    bool            zBufferRead() const;
    bool            zBufferWrite() const;

    // 通道
    bool            solid() const;
    bool            sorted() const;
    bool            flare() const;
    bool            shimmer() const;
    bool            doubleSided() const;
    uint8           channelFlags() const;

    // TextureStages
    uint32                  numTextureStages() const;
    class TextureStage &    textureStage( uint32 stageNum );

    // 应用到设备
    void            set( bool vertexAlphaOverride = false ) const;

    // 加载
    bool            load( const BW::string& resourceID );
    bool            load( DataSectionPtr spMaterialSection );

    // ...
};
```

`Material` 设置的内容包括:
- **颜色**:ambient/diffuse/specular(固定管线光照)
- **混合模式**:srcBlend/destBlend(透明、加色等)
- **ZBuffer**:read/write
- **Alpha Test**:enable + reference
- **Double Sided**:背面剔除开关
- **Fog**:是否参与雾计算
- **Texture Stages**:多纹理阶段(固定管线的纹理混合)
- **Channel Flags**:SOLID/SORTED/SHIMMER/FLARE,决定渲染到 DrawContext 的哪个通道

`Material::set()` 实现把所有这些状态下发到 D3D 设备。它在固定管线下有效,但在可编程管线下,Material 主要用于设置非 shader 状态(如 ZBuffer、混合模式)。

`Channel` 枚举(行 86-92)与 `DrawContext::ChannelMask`(`draw_context.hpp:104-111`)对应:

```cpp
enum ChannelMask
{
    OPAQUE_CHANNEL_MASK      = 0x00000001,
    TRANSPARENT_CHANNEL_MASK = 0x00000002,
    SHIMMER_CHANNEL_MASK     = 0x00000004,
    NUM_CHANNEL_MASKS         = 3,
    ALL_CHANNELS_MASK = ((1 << NUM_CHANNEL_MASKS) - 1)
};
```

### 6.2 EffectMaterial 可编程材质

`effect_material.hpp:40-198` 是 .fx 材质的封装:

```cpp
class EffectMaterial : public SafeReferenceCount
{
public:
    typedef BW::map< D3DXHANDLE, EffectPropertyPtr > Properties;

    EffectMaterial();
    explicit EffectMaterial( const EffectMaterial & other );
    EffectMaterial & operator=( const EffectMaterial & other );
    ~EffectMaterial();

    bool load( DataSectionPtr pSection, bool addDefault = true, 
        bool suppressPropertyWarnings = false );
    void save( DataSectionPtr pSection );

    bool initFromEffect(
        const BW::StringRef & effect,
        const BW::StringRef & diffuseMap = "",
        int doubleSided = -1 );

    void identifier( const BW::StringRef & id );
    const BW::string& identifier() const;

    bool checkEffectRecompiled();
    bool begin() const;
    bool end() const;
    bool beginPass( uint32 pass ) const;
    bool endPass() const;
    uint32 numPasses() const;
    void setProperties() const;
    bool commitChanges() const;

    D3DXHANDLE hTechnique() const;
    bool hTechnique( D3DXHANDLE hTec );
    bool setTechnique( const BW::StringRef & techniqueName );

    const ManagedEffectPtr& pEffect() { return pManagedEffect_; }

    // 属性 getter
    bool boolProperty( bool & result, const BW::StringRef & name ) const;
    bool intProperty( int & result, const BW::StringRef & name ) const;
    bool floatProperty( float & result, const BW::StringRef & name ) const;
    bool textureProperty( BW::string & result, const BW::StringRef & name ) const;
    bool vectorProperty( Vector4 & result, const BW::StringRef & name ) const;
    bool matrixProperty( Matrix & result, const BW::StringRef & name ) const;

    // 属性 setter
    bool setProperty( const BW::StringRef & name, const bool value, bool create );
    bool setProperty( const BW::StringRef & name, const int value, bool create );
    bool setProperty( const BW::StringRef & name, const float value, bool create );
    bool setProperty( const BW::StringRef & name, const Moo::BaseTexturePtr & value, bool create );
    bool setProperty( const BW::StringRef & name, const Vector4 & value, bool create );
    bool setProperty( const BW::StringRef & name, const Matrix & value, bool create );

    // ...
private:
    ManagedEffect::CompileMark compileMark_;
    ManagedEffectPtr pManagedEffect_;
    Properties        properties_;
    D3DXHANDLE        hOverriddenTechnique_;
    BW::string        identifier_;
    int               materialKind_;
    int               collisionFlags_;
};
```

核心字段:
- `pManagedEffect_`:引用一个 `ManagedEffect`(.fx 文件,被 `EffectManager` 缓存)
- `properties_`:属性表(name → EffectProperty,bool/int/float/texture/vector/matrix)
- `hOverriddenTechnique_`:被覆盖的 technique handle,0 表示使用默认

`EffectMaterial` 的 `load()` 流程:
1. 读取 XML section
2. 解析 `effect` 属性,通过 `EffectManager::get()` 获取/加载 ManagedEffect
3. 解析 `technique` 属性,设置 `hOverriddenTechnique_`
4. 遍历所有属性节点,通过 `setProperty()` 写入 `properties_`
5. 调用 `replaceDefaults()` 将属性值替换到 effect 的默认参数

### 6.3 checkEffectRecompiled 与热重载

`effect_material.hpp:63`:

```cpp
bool checkEffectRecompiled();
```

每次 `begin()` 之前调用,检查 ManagedEffect 的 `compileMark_` 是否变化。如果变化(说明 .fx 文件被运行时重编译),则:
1. 重新加载 technique handle
2. 重新加载属性 handle
3. 重新应用属性值

这是 Moo 实现"修改 .fx 文件立即看到效果"的关键。

### 6.4 ComplexEffectMaterial 多 pass 材质

`complex_effect_material.hpp:16-56`:

```cpp
class ComplexEffectMaterial : public SafeReferenceCount
{
public:
    ComplexEffectMaterial();
    explicit ComplexEffectMaterial(const ComplexEffectMaterial& other);
    
    const EffectMaterialPtr& pass(ERenderingPassType type, bool instanced = false) const;
    void pass( ERenderingPassType type,
                ManagedEffect*& outEffect,
                ManagedEffect::Handle& outTechnique,
                BW::map< D3DXHANDLE, SmartPointer<EffectProperty> >*& outMaterialProperties,
                bool& inoutIsInstanced ) const;

    bool            instanced() const  { return m_instanced; }
    bool            skinned() const    { return m_skinned; }
    ChannelType     channelType() const { return m_channelType; }
    
private:
    bool            finishInit();
    bool            m_instanced;
    bool            m_skinned;
    EffectMaterialPtr m_material;
    ChannelType     m_channelType;
    D3DXHANDLE      m_techniques[RENDERING_PASS_COUNT][2];  // [pass][instanced]
};
```

注意 `m_techniques[RENDERING_PASS_COUNT][2]`(`RENDERING_PASS_COUNT = 5`,见 `draw_context.hpp:29-36`):

```cpp
enum ERenderingPassType
{
    RENDERING_PASS_COLOR      = 0,   // 主色彩 pass
    RENDERING_PASS_REFLECTION,        // 反射 pass(水面)
    RENDERING_PASS_SHADOWS,           // 阴影 pass
    RENDERING_PASS_DEPTH,             // 深度 prepass
    RENDERING_PASS_COUNT
};
```

每个 pass 又分 instanced/非 instanced 两个 technique。`ComplexEffectMaterial` 在 `finishInit()` 中根据 effect 名约定(如 `xyz_color`、`xyz_color_instanced`、`xyz_shadow` 等)查找所有 technique handle。

`pass()` 内联实现(`complex_effect_material.hpp:59-67`):

```cpp
inline const EffectMaterialPtr& ComplexEffectMaterial::pass(ERenderingPassType type, bool instanced) const
{
    this->checkEffectRecompiled();
    D3DXHANDLE technique = m_techniques[type][instanced];
    m_material->hTechnique( technique );
    return m_material;
}
```

这种设计让**同一个材质适配多种渲染场景**——主画面用 color technique,画阴影用 shadow technique,绘制实例用 instanced technique,无需切换 effect,只切换 technique handle。

### 6.5 ShaderSet 灯光分支

`shader_set.hpp:17-55` 是一个**早期的灯光数量分支**机制:

```cpp
class ShaderSet : public Moo::DeviceCallback, public ReferenceCount
{
public:
    typedef uint32 ShaderID;
    typedef IDirect3DVertexShader9* ShaderHandle;
    typedef BW::map< ShaderID, ShaderHandle > ShaderMap;

    ShaderSet( DataSectionPtr shaderSetSection, const BW::string & vertexFormat, 
        const BW::string & shaderType );
    ~ShaderSet();

    static ShaderID shaderID( char nDirectionalLights, char nPointLights, char nSpotLights );
    ShaderHandle    shader( char nDirectionalLights, char nPointLights, char nSpotLights, bool hardwareVP = false );
    ShaderHandle    shader( ShaderID shaderID, bool hardwareVP = false );
    // ...
private:
    ShaderMap   shaders_;       // 软件 VP 版本
    ShaderMap   hwShaders_;     // 硬件 VP 版本
    // ...
};
```

`shaderID()`(注释隐含在签名中)将三个 8 位数字(directional/point/spot 光数量)打包成一个 32 位 ID:

```
shaderID = (nDirectionalLights << 16) | (nPointLights << 8) | nSpotLights
```

这样,根据当前场景的灯光配置,可以快速查找到一个**预编译好的、针对该灯光数量的 VertexShader**。这是固定管线下"动态灯光组合"的经典技巧,可避免在 shader 中循环遍历灯光。

注意:`ShaderSet` 在现代可编程管线中已经很少使用,主要保留为兼容旧资源。新代码应该使用 `EffectMaterial` + HLSL 中的循环。

### 6.6 EffectManager 与 Shared Constants

`effect_manager.hpp:31-119`:

```cpp
class EffectManager : 
    public DeviceCallback,
    public ResourceModificationListener,
    public Singleton< EffectManager >
{
public:
    class IListener
    {
    public:
        virtual void onSelectPSVersionCap( int psVerCap ) = 0;
    };

    ManagedEffectPtr createEffectPool( const BW::string& resourceID );
    ManagedEffectPtr get( const BW::string& resourceID,
                bool loadIfNotLoaded = true,
                bool isEffectPool = false );

    int PSVersionCap() const;
    void PSVersionCap( int psVersion );

    void addListener(IListener * listener);
    void delListener(IListener * listener);
    // ...
};
```

`createEffectPool` 创建一个**共享常量池**——多个 effect 共享同一份"全局参数"(如 ViewProj、Time、ScreenSize)。这样,设置一次共享常量,所有 effect 都能看到,避免重复设置。

`PSVersionCap` 是**像素着色器版本上限**,用于在低配硬件上限制 shader 复杂度。`IListener` 回调让 MRTSupport 等子系统知道 PS 版本变化,以便自动禁用不支持的特性(见 `mrt_support.cpp:82-88`)。

---

## 七、几何与图元

### 7.1 Vertices 顶点缓冲

`vertices.hpp:52-299` 是顶点数据的封装:

```cpp
class Vertices : 
    public SafeReferenceCount,
    public Reloader
{
public:
    Vertices( const BW::string& resourceID, int numNodes );

    virtual HRESULT     load( );
    virtual HRESULT     release( );
    virtual HRESULT     setVertices( bool software, bool instanced = false );

    void pullInternals( const bool instanced,
                        const VertexDeclaration*& outputVertexDecl,
                        const VertexBuffer*& outputDefaultVertexBuffer,
                        uint32& outputDefaultVertexBufferOffset,
                        uint32& outputDefaultVertexStride,
                        const StreamContainer*& outputStreamContainer);

    virtual HRESULT     setTransformedVertices( bool tb,
        const NodePtrVector& nodes );

    const BW::string&  resourceID( ) const;
    uint32              nVertices( ) const;
    const BW::string&   sourceFormat( ) const;	
    uint32              vertexStride() const;
    Moo::VertexBuffer   vertexBuffer( ) const;
    uint32              vertexBufferOffset( uint32 streamIndex ) const;
    uint32 numVertexBuffers() const;

    void addStream( uint32 streamIndex, const VertexBuffer& vb, 
        uint32 offset, uint32 stride, uint32 size );

    HRESULT bindStreams( bool instanced, bool softwareSkinned = false,
        bool bumpMapped = false );
    // ...
protected:
    StreamContainer*    streams_;            // 多流容器(可空)
    Moo::VertexBuffer   vertexBuffer_;       // 默认流(VertexBuffer)
    uint32              vertexBufferOffset_;
    uint32              vertexBufferSize_;
    VertexDeclaration*  pDecl_;              // 顶点声明
    VertexDeclaration*  pInstancedDecl_;     // instanced 用的声明
    uint32              nVertices_;
    BW::string          resourceID_;
    BW::string          sourceFormat_;       // 格式名,如 "XYZNUVTB"
    uint32              vertexStride_;
    mutable VertexPositions vertexPositions_;  // CPU 端位置缓存
    BaseSoftwareSkinnerPtr pSoftwareSkinner_;  // 软件蒙皮器
    bool                formatSupportsSoftwareSkinner_;
    Moo::VertexBuffer   pSkinnerVertexBuffer_;  // 软件蒙皮后的 VB
    bool                vbBumped_;             // 是否带 bump/tangent
    int                 numNodes_;            // 骨骼节点数(用于验证)
};
```

关键点:
- **多流支持**:`streams_` 不为空时,表示该 Vertices 由多个 VertexBuffer 组成(如 stream 0 是位置,stream 1 是 UV2)
- **顶点声明缓存**:`pDecl_` 是 D3D VertexDeclaration,`pInstancedDecl_` 是为 instancing 额外附加 InstanceData 流后的声明
- **软件蒙皮**:`pSoftwareSkinner_` 在 CPU 上做骨骼蒙皮(用于不支持 vertex shader 蒙皮的硬件)
- **`pullInternals`**:`DrawContext` 通过这个方法直接读取 Vertices 内部的 VertexBuffer/Declaration 指针,无需走 `setVertices` 路径,以便在延迟渲染时统一提交

### 7.2 顶点格式系统

`vertex_format.hpp:252-502` 是一个非常完善的顶点格式抽象:

```cpp
class VertexFormat
{
public:
    typedef VertexElement::StorageType StorageType;
    typedef VertexElement::SemanticType SemanticType;
    static const uint32 DEFAULT = uint32(-1);

    VertexFormat();
    VertexFormat( const BW::StringRef & name );

    bool equals( const VertexFormat & other ) const;
    const BW::StringRef name() const;

    static bool load( VertexFormat& format, DataSectionPtr pSection,
        const BW::StringRef & name );
    static bool merge( VertexFormat& format, const VertexFormat& otherFormat );

    uint32 addStream();
    void addElement( uint32 streamIndex, SemanticType::Value semantic, 
        StorageType::Value storageType, uint32 semanticIndex = DEFAULT, size_t offset = DEFAULT );

    bool findElement( uint32 index, SemanticType::Value* semantic, 
        uint32* streamIndex, uint32* semanticIndex, size_t* offset, StorageType::Value* storageType ) const;
    // ...
    uint32 streamStride( uint32 streamIndex ) const;
    uint32 streamCount() const;
    // ...
private:
    struct ElementDefinition
    {
        SemanticType::Value semantic_;
        uint32              semanticIndex_;
        StorageType::Value storage_;
        size_t              offset_;
    };
    struct StreamDefinition
    {
        StreamDefinition();
        BW::vector<ElementDefinition> elements_;
        uint32 stride_;
    };
    BW::vector<StreamDefinition> streams_;
    TargetFormatMapping           targets_;
    BW::string                    name_;
};
```

特点:
- **XML 定义**:顶点格式通过 XML 文件定义,支持运行时加载
- **多流**:一个 VertexFormat 可包含多个 stream,每个 stream 有自己的 stride 和元素列表
- **类型转换**:`VertexConversions::convertValue` 支持在不同存储类型(如 FLOAT3 → UBYTE4_NORMAL_8_8_8)间转换
- **目标格式映射**:`targets_` 表记录"目标平台用什么格式"(如 PC、Xbox、PS3)

预设顶点类型(`vertex_formats.hpp:100-117`):

```cpp
struct VertexXYZNUV  // Position + Normal + UV
{
    Vector3  pos_;
    Vector3  normal_;
    Vector2  uv_;
    FVF( D3DFVF_XYZ|D3DFVF_NORMAL|D3DFVF_TEX1 )
};
```

注释(行 22-32)展示了 GPU 顶点压缩的优化空间:

```
format             bytes  freed memory %
- VertexXYZNUV      (32/20)   -37.5%
- VertexXYZNUV2     (40/24)   -40.0%
- VertexXYZNUVTB     (56/28)   -50.0%
- VertexXYZNUV2TB    (64/32)   -50.0%
- VertexXYZNUVIIIWWTB (64/36)  -43.7%
```

通过把 normal 从 Vector3(12 字节)压缩为 UBYTE4_NORMAL_8_8_8(4 字节)、UV 从 Vector2(8 字节)压缩为 INT16_X2(4 字节),可节省 37%~50% 显存。

### 7.3 Primitive 索引缓冲

`primitive.hpp:26-103`:

```cpp
class Primitive : 
    public SafeReferenceCount,
    public Reloader
{
public:
    virtual HRESULT     setPrimitives();
    virtual HRESULT     drawPrimitiveGroup( uint32 groupIndex );
    virtual HRESULT     drawInstancedPrimitiveGroup( uint32 groupIndex, uint32 instanceCount );
    virtual HRESULT     release( );
    virtual HRESULT     load( );

    const IndexBuffer&  indexBuffer() const;
    uint32              nPrimGroups() const;
    const PrimitiveGroup& primitiveGroup( uint32 i ) const;
    uint32              maxVertices() const;
    const BW::string&   resourceID() const;
    D3DPRIMITIVETYPE    primType() const;
    uint32              nIndices() const { return nIndices_; }
    D3DFORMAT           indicesFormat() const;
    void                indicesIB( IndicesHolder& indices );
    const IndicesHolder& indices();

    const Vector3& origin( uint32 i ) const;
    void calcGroupOrigins( const VerticesPtr verts );
    bool adoptGroupOrigins( BW::vector<Vector3>& origins );
    // ...
private:
    typedef BW::vector< PrimitiveGroup > PrimGroupVector;
    PrimGroupVector     primGroups_;
    BW::vector<Vector3> groupOrigins_;
    uint32              nIndices_;
    uint32              maxVertices_;
    BW::string          resourceID_;
    D3DPRIMITIVETYPE    primType_;
    IndicesHolder       indices_;
    IndexBuffer         indexBuffer_;
};
```

`PrimitiveGroup`(注意与 `primitive_file_structs.hpp:57-63` 的同名结构区分)是:

```cpp
// primitive_file_structs.hpp:57-63 (文件格式)
struct PrimitiveGroup
{
    int     startIndex_;
    int     nPrimitives_;
    int     startVertex_;
    int     nVertices_;
};
```

每个 PrimitiveGroup 描述索引缓冲中的一段,可以独立 drawIndexedPrimitive。

### 7.4 索引格式与 16/32 位

`primitive.cpp:174-185`:

```cpp
if( BW::string( ih->indexFormat_ ) == "list" || BW::string( ih->indexFormat_ ) == "list32" )
{
    D3DFORMAT format = BW::string( ih->indexFormat_ ) == "list" ? D3DFMT_INDEX16 : D3DFMT_INDEX32;
    primType_ = D3DPT_TRIANGLELIST;

    if (Moo::rc().maxVertexIndex() <= 0xffff && 
        format == D3DFMT_INDEX32 ) 
    { 
        ERROR_MSG( "Primitives::load - unable to create index buffer as 32 bit indices " 
            "were requested and only 16 bit indices are supported\n" ); 
        return res; 
    }
    // ...
}
```

`list32` 表示使用 32 位索引(超过 65536 顶点时必需)。如果硬件不支持(`maxVertexIndex <= 0xffff`),则报错。

### 7.5 groupOrigins 与内部排序

`primitive.hpp:66-68`:

```cpp
const Vector3& origin( uint32 i ) const;
void calcGroupOrigins( const VerticesPtr verts );
bool adoptGroupOrigins( BW::vector<Vector3>& origins );
```

`groupOrigins_` 存储每个 PrimitiveGroup 的"原点",用于透明排序时的近似距离计算。`calcGroupOrigins` 遍历顶点求每个 group 的中心点。

在 `DrawContext::sortTrianglesByCameraDistance`(`draw_context.cpp:213-330`)中,会按三角形对相机的距离排序(用于透明半透明渲染),这时 `groupOrigins_` 用于快速剔除整个 group。

### 7.6 Geometry 辅助类

`geometry.hpp:8-75` 定义了 2D 几何辅助类 `Line` 和 `Rect`,主要用于 UI 布局计算:

```cpp
class Line
{
public:
    Vector2 p1, p2;
    bool intersect(Line& l, Vector2& pos);  // 线段相交测试
};

class Rect
{
public:
    Line l1, l2, l3, l4;
    bool isInside(Vector2& p);  // 点在矩形内测试
};
```

`Line::intersect` 实现了经典的线段相交算法(平移+旋转+参数化),用于 UI 元素的碰撞检测。

---

## 八、相机系统

### 8.1 Camera 类

`camera.hpp:18-57`:

```cpp
class Camera
{
public:
    Camera( float nearPlane, float farPlane, float fov, float aspectRatio );
    Camera( const Camera& camera );
    ~Camera();

    Camera& operator =( const Camera& camera );

    float   nearPlane() const;
    void    nearPlane( float f );
    float   farPlane() const ;
    void    farPlane( float f );
    float   fov() const;
    void    fov( float f );
    float   aspectRatio() const;
    void    aspectRatio( float f );

    float   viewHeight() const;
    void    viewHeight( float height );
    float   viewWidth() const;

    bool    ortho() const;
    void    ortho( bool b );

    Vector3 nearPlanePoint( float xClip, float yClip ) const;
    Vector3 farPlanePoint( float xClip, float yClip ) const;

private:
    float   nearPlane_;
    float   farPlane_;
    float   fov_;
    float   aspectRatio_;
    float   viewHeight_;
    bool    ortho_;
};
```

注意 `Camera` **不存储位置和朝向**——这些由 `RenderContext::view_` 矩阵维护。`Camera` 只描述投影参数(透视/正交、fov、near/far、aspect)。

构造函数(`camera.ipp:13-41`)做了多重断言:

```cpp
INLINE Camera::Camera( float nP, float fP, float f, float aR ) :
    nearPlane_( nP ),
    farPlane_( fP ),
    fov_( f ),
    aspectRatio_( aR ),
    viewHeight_( 100 ),
    ortho_( false )
{
    IF_NOT_MF_ASSERT_DEV( nP < fP )
    {
        MF_EXIT( "near plane must be closer than far plane" );
    }
    IF_NOT_MF_ASSERT_DEV( nP > 0 )
    {
        MF_EXIT( "near plane must be greater than 0" );
    }
    IF_NOT_MF_ASSERT_DEV( f > 0 && f < MATH_PI )
    {
        MF_EXIT( "fov must be between 0 and PI" );
    }
    IF_NOT_MF_ASSERT_DEV( aR != 0 )
    {
        MF_EXIT( "aspect ratio cannot be 0" );
    }
}
```

任何非法参数都会触发 `MF_EXIT` 终止程序,而不是带病运行。

### 8.2 视锥体计算

`camera.cpp:19-33`:

```cpp
Vector3 Camera::nearPlanePoint( float xClip, float yClip ) const
{
    const float yLength = nearPlane_ * tanf( fov_ * 0.5f );
    const float xLength = yLength * aspectRatio_;
    return Vector3( xLength * xClip, yLength * yClip, nearPlane_ );
}

Vector3 Camera::farPlanePoint( float xClip, float yClip ) const
{
    const float yLength = farPlane_ * tanf( fov_ * 0.5f );
    const float xLength = yLength * aspectRatio_;
    return Vector3( xLength * xClip, yLength * yClip, farPlane_ );
}
```

给定 clip space 坐标 [-1, 1],返回 near/far 平面上的点(相机空间)。这两个函数用于:
- 视锥剔除:构造 8 个角点
- 鼠标拾取:从屏幕坐标反推世界射线
- 雾效计算:确定雾的近远平面

### 8.3 投影矩阵

投影矩阵在 `RenderContext` 中维护(`render_context.hpp:202-206`):

```cpp
const Matrix& projection( ) const;
Matrix& projection( );
void projection( const Matrix& m );
void scaleOffsetProjection( const float scale, const float x, const float y );
```

`scaleOffsetProjection` 是 TAA 用来做 sub-pixel jitter 的(详见第十六节)。

`updateProjectionMatrix`(`render_context.hpp:230`):

```cpp
void updateProjectionMatrix(bool detectAspectRatio = true);
```

每帧(或窗口大小变化时)调用,根据当前 Camera 和屏幕宽高比重新计算投影矩阵。

### 8.4 与 client/camera_app 的协作

`lib/camera/` 提供 `BaseCamera`、`Flexicam`、`FreeCamera` 等具体相机实现。它们更新 `RenderContext::view_` 矩阵,而 `Camera` 类只描述投影参数。

`camera_app` 模块组合多个相机行为(跟随、自由、轨道等),最终通过 `Moo::rc().view(viewMatrix)` 应用到 RenderContext。

### 8.5 CameraPlanesSetter 视锥裁剪面

`camera_planes_setter.hpp/cpp` 是一个 RAII 类,构造时把当前相机的 6 个裁剪面设置到固定管线的 clip plane 状态,析构时恢复。主要用于水面反射等需要自定义裁剪的场景。

---

## 九、灯光系统

Moo 的灯光系统由四类灯光 + 一个容器组成:

| 类型 | 文件 | 描述 |
|------|------|------|
| `DirectionalLight` | `directional_light.hpp` | 方向光(太阳光) |
| `OmniLight` | `omni_light.hpp` | 全向光(点光源) |
| `SpotLight` | `spot_light.hpp` | 聚光灯 |
| `PulseLight` | `pulse_light.hpp` | 脉冲光(动画 OmniLight) |
| `LightContainer` | `light_container.hpp` | 灯光容器 |

### 9.1 OmniLight 全向光

`omni_light.hpp:25-103`:

```cpp
class OmniLight : public SafeReferenceCount
{
public:
    //-- for instanced rendering with 16 byte aligning.
    struct GPU
    {
        Vector4 m_pos;          // xyz
        Vector4 m_color;        // xyzw
        Vector4 m_attenuation;  // xy
        Vector4 m_padding;      // padding
    };

    OmniLight();
    OmniLight( const D3DXCOLOR& colour, const Vector3& position, float innerRadius, float outerRadius );
    ~OmniLight();

    const Vector3&  position( ) const;
    void            position( const Vector3& position );
    float           innerRadius( ) const;
    void            innerRadius( float innerRadius );
    float           outerRadius( ) const;
    void            outerRadius( float outerRadius );

    const Colour&   colour( ) const;
    void            colour( const Colour& colour );

    void            worldTransform( const Matrix& transform );

    GPU             gpu( ) const;
    const BoundingBox& worldBounds( ) const;
    const Vector3&  worldPosition( void ) const;
    float           worldInnerRadius( void ) const;
    float           worldOuterRadius( void ) const;

    bool            intersects( const BoundingBox& worldSpaceBB ) const;
    Vector4*        getTerrainLight( uint32 timestamp, float lightScale );
    float           attenuation( const BoundingBox& worldSpaceBB ) const;

    int             priority() const { return priority_; }
    void            priority(int b) { priority_ = b; }
    // ...
protected:
    void            createTerrainLight( float lightScale );

    BoundingBox     worldBounds_;
    Vector3         position_;
    float           innerRadius_;
    float           outerRadius_;
    Colour          colour_;

    Vector3         worldPosition_;
    float           worldInnerRadius_;
    float           worldOuterRadius_;

    uint32          terrainTimestamp_;
    Vector4         terrainLight_[3];

    int             priority_;
#ifdef EDITOR_ENABLED
    float           multiplier_;
#endif
};
```

#### 9.1.1 GPU 结构

`OmniLight::GPU` 是给 instanced rendering 用的"16 字节对齐"结构:

| 字段 | xyzw 含义 |
|------|-----------|
| `m_pos` | xyz: 位置, w: 1.0(齐次) |
| `m_color` | xyz: 颜色, w: 强度 |
| `m_attenuation` | x: innerRadius, y: outerRadius, zw: 保留 |
| `m_padding` | 16 字节对齐填充 |

每个 OmniLight 占 64 字节(4 个 Vector4),正好对齐 cache line,适合批量上传到 GPU。

#### 9.1.2 内外半径衰减

`innerRadius_`/`outerRadius_` 定义了**双半径衰减**:
- `innerRadius_` 内:全亮度
- `innerRadius_` ~ `outerRadius_`:线性衰减到 0
- `outerRadius_` 外:无光照

这比单一半径的"硬边"光更自然,也方便视锥剔除。

#### 9.1.3 worldTransform 与 world 空间

OmniLight 的 `position_`/`innerRadius_`/`outerRadius_` 是**模型空间**的,通过 `worldTransform(matrix)` 转换到世界空间:

```cpp
worldPosition_ = matrix.applyPoint(position_);
worldInnerRadius_ = innerRadius_ * matrix.row(0).length();  // 假设均匀缩放
worldOuterRadius_ = outerRadius_ * matrix.row(0).length();
worldBounds_ = BoundingBox(worldPosition_ - outerRadius, worldPosition_ + outerRadius);
```

#### 9.1.4 getTerrainLight 地形光照

`terrainLight_[3]`(3 个 Vector4 = 12 个 float)是给地形 shader 用的**预计算方向光**。`getTerrainLight(timestamp, lightScale)` 会缓存计算结果(`terrainTimestamp_` 标记是否已计算),避免每帧重复。

#### 9.1.5 priority 优先级

`priority_` 是灯光的优先级,用于在灯光数量超过 GPU 限制时**保留更重要的灯光**。`LightContainer` 在收集灯光时按 priority 排序,丢弃低优先级的。

### 9.2 SpotLight 聚光灯

`spot_light.hpp:25-111`:

```cpp
class SpotLight : public SafeReferenceCount
{
public:
    struct GPU
    {
        Vector4 m_pos;          // xyz
        Vector4 m_color;        // xyzw
        Vector4 m_attenuation;  // xyz
        Vector4 m_dir;          // xyz
    };

    SpotLight();
    SpotLight( const Colour& colour, const Vector3& position, 
        const Vector3& direction, float innerRadius, float outerRadius, 
        float cosConeAngle );
    ~SpotLight();

    const Vector3&  position( ) const;
    void            position( const Vector3& position );
    const Vector3&  direction( ) const;
    void            direction( const Vector3& direction );
    float           innerRadius( ) const;
    void            innerRadius( float innerRadius );
    float           outerRadius( ) const;
    void            outerRadius( float outerRadius );

    float           cosConeAngle( ) const;       // 圆锥角的余弦
    void            cosConeAngle( float cosConeAngle );
    const Colour&   colour( ) const;
    void            colour( const Colour& colour );

    void            worldTransform( const Matrix& transform );

    GPU             gpu( ) const;
    const BoundingBox& worldBounds( ) const;
    // ...
private:
    void            updateInternalBounds() const;
    mutable bool    dirty_;
    Vector3         position_;
    Vector3         direction_;
    float           innerRadius_;
    float           outerRadius_;
    float           cosConeAngle_;
    Colour          colour_;
    // ...
    mutable Matrix      lightView_;          // 用于阴影投影
    mutable BoundingBox lightBounds_;
};
```

注意 `cosConeAngle_` 用**余弦**而非角度存储——shader 中比较点积时直接用 `dot(dir, toPixel) > cosConeAngle` 即可,无需 `acos`。

`lightView_` 是聚光灯的"视角"矩阵,用于生成阴影贴图(`SpotLight` 投射阴影时,从光源位置看向场景)。

### 9.3 PulseLight 脉冲光

`pulse_light.hpp:25-44`:

```cpp
class PulseLight : public OmniLight
{
public:
    PulseLight();
    PulseLight( const Colour & colour, const Vector3 & position,
        float innerRadius, float outerRadius, const char * animationName,
        const ExternalArray<Vector2> & animFrames, float loopDuration );
    ~PulseLight();

    void tick( float dTime );
private:
    Vector3 basePosition_;
    Colour  baseColour_;
    SmartPointer<Animation> pAnimation_;
    LinearAnimation<float> colourAnimation_;
    float   positionAnimFrame_,
            colourAnimFrame_;
};
```

`PulseLight` 继承 `OmniLight`,通过 `tick(dTime)` 驱动动画,动态修改 `position_`/`colour_`。常用于:火炬、警灯、警示灯等节律灯光。

### 9.4 DirectionalLight 方向光

`directional_light.hpp:23-64`:

```cpp
class DirectionalLight : public SafeReferenceCount
{
public:
    DirectionalLight();
    DirectionalLight( const Colour& colour, const Vector3& direction_ );
    ~DirectionalLight();

    const Vector3&  direction( ) const;
    void            direction( const Vector3& direction );
    const Colour&   colour( ) const;
    void            colour( const Colour& colour );

    void            worldTransform( const Matrix& transform );
    const Vector3&  worldDirection( ) const;
private:
    Vector3 direction_;
    Vector3 worldDirection_;
    Colour  colour_;
#ifdef EDITOR_ENABLED
    float   multiplier_;
#endif
};
```

方向光只有方向和颜色,**没有位置**(因为是无限远)。`worldTransform` 只旋转方向(平移无效)。

### 9.5 LightContainer 容器

`light_container.hpp:27-98`:

```cpp
class LightContainer : public SafeReferenceCount
{
public:
    LightContainer( const LightContainerPtr & pLC, const BoundingBox& bb, bool limitToRenderable = false);
    LightContainer();
    ~LightContainer();

    void    assign( const LightContainerPtr & pLC );
    void    clear();
    void    init( const LightContainerPtr & pLC, const BoundingBox& bb, bool limitToRenderable );

    void    addToSelfOnlyVisibleLights(const LightContainerPtr & pLC, const Matrix& camera);
    void    addToSelf( const LightContainerPtr & pLC, bool addOmnis=true, bool addSpots=true, bool addDirectionals=true );
    void    addToSelf( const LightContainerPtr & pLC, const BoundingBox& bb, bool limitToRenderable );

    const Colour&                   ambientColour( ) const;
    void                            ambientColour( const Colour& colour );

    const DirectionalLightVector&   directionals( ) const;
    DirectionalLightVector&          directionals( );
    bool                            addDirectional( const DirectionalLightPtr & pDirectional, bool checkExisting=false );
    bool                            delDirectional( const DirectionalLightPtr & pDirectional );
    uint32                          nDirectionals( ) const;
    const DirectionalLightPtr&      directional( uint32 i ) const;

    const OmniLightVector&          omnis( ) const;
    OmniLightVector&                omnis( );
    bool                            addOmni( const OmniLightPtr & pOmni, bool checkExisting=false );
    // ... 同样有 spots

    void    addExtraOmnisInWorldSpace( ) const;
    void    addExtraOmnisInModelSpace( const Matrix& invWorld ) const;

    static void addLightsInWorldSpace( );
    static void addLightsInModelSpace( const Matrix& invWorld );

    void    commitToFixedFunctionPipeline();
    // ...
private:
    Colour                  ambientColour_;
    DirectionalLightVector  directionalLights_;
    OmniLightVector         omniLights_;
    SpotLightVector         spotLights_;
};
```

#### 9.5.1 灯光收集流程

`LightContainer` 提供了两种收集模式:

1. **`addToSelf(lc, bb, limitToRenderable)`**:从 `lc` 中收集与 `bb` 相交的灯光。如果 `limitToRenderable` 为 true,还会按 priority 限制数量
2. **`addToSelfOnlyVisibleLights(lc, camera)`**:从 `lc` 中收集对相机可见的灯光

`RenderContext` 持有两个 LightContainer:
- `lightContainer_`:主灯光容器(场景内所有影响当前帧的灯光)
- `specularLightContainer_`:镜面反射专用(可能更少,只取最近的)

#### 9.5.2 commitToFixedFunctionPipeline

`commitToFixedFunctionPipeline()` 把灯光数据设置到 D3D 固定管线的 `SetLight()` 接口。现代可编程管线下很少使用,主要兼容旧硬件。

#### 9.5.3 addExtraOmnisInWorldSpace/ModelSpace

这两个静态方法把 RenderContext 的当前 lightContainer 中的 omni light 转换到 shader 常量。WorldSpace 直接上传;ModelSpace 需要传入 `invWorld` 矩阵,把位置变换到模型空间(用于在 vertex shader 中计算光照)。

### 9.6 灯光数量限制

D3D9 固定管线支持的最大灯光数由 `D3DCAPS9.MaxActiveLights` 决定(通常 8 个)。可编程管线下,灯光数量受**常量寄存器数量**限制:

| Shader Model | 常量寄存器 | 大致可支持灯光数 |
|--------------|-----------|-----------------|
| VS 2.0 | 256 | ~40 个 omni(每个 6 个 float4) |
| VS 3.0 | 256 | ~40 个 omni |
| PS 3.0 | 224 | ~30 个 omni |

实际工程中,Forward 管线下通常限制为 4~8 个动态灯光;Deferred 管线下可支持数十个。

---

## 十、渲染管线流程

### 10.1 Forward vs Deferred 的选择

`renderer.cpp:99-108` 决定管线类型。Deferred 需要硬件支持(`COMPATIBILITYFLAG_DEFERRED_SHADING`):

```cpp
bool supported = true;
supported &= (deviceInfo.caps_.VertexShaderVersion >= 0x300);   // SM3.0
supported &= (deviceInfo.caps_.PixelShaderVersion  >= 0x300);   // SM3.0
supported &= (deviceInfo.caps_.NumSimultaneousRTs   >= 3);       // 至少 3 个 MRT
supported &= (deviceInfo.caps_.PrimitiveMiscCaps & D3DPMISCCAPS_INDEPENDENTWRITEMASKS) != 0;
```

如果不满足,自动回退到 Forward。

### 10.2 Forward 管线流程

`forward_pipeline.hpp/cpp`:

```
┌─────────────────────────────────────────────────┐
│ Forward Pipeline 流程                            │
├─────────────────────────────────────────────────┤
│ begin()                                          │
│   → 设置 viewport                                │
│   → Clear(TARGET|ZBUFFER|STENCIL)                │
├─────────────────────────────────────────────────┤
│ beginCastShadows(dc)  // 空                     │
│   ... 提交阴影投射几何 ...                       │
│ endCastShadows()       // 空                     │
├─────────────────────────────────────────────────┤
│ beginOpaqueDraw()                                │
│   → pushRenderState(COLORWRITEENABLE)            │
│   → setRenderState(COLORWRITEENABLE, 0xF)        │
│   ... 提交不透明几何到 DrawContext ...           │
│   → drawContext.flush(OPAQUE)                    │
│ endOpaqueDraw()                                  │
│   → popRenderState()                             │
├─────────────────────────────────────────────────┤
│ applyLighting()  // 空,因为光照已在材质中计算    │
├─────────────────────────────────────────────────┤
│ beginSemitransparentDraw()                       │
│   → pushRenderState(COLORWRITEENABLE)            │
│   → setRenderState(COLORWRITEENABLE, 0xF)        │
│   ... 提交半透明几何 ...                          │
│   → drawContext.flush(TRANSPARENT)               │
│ endSemitransparentDraw()                         │
│   → popRenderState()                             │
├─────────────────────────────────────────────────┤
│ PostProcessing::Manager::draw()                 │
├─────────────────────────────────────────────────┤
│ beginGUIDraw()  // 空                            │
│   ... 绘制 GUI ...                              │
│ endGUIDraw()    // 空                            │
├─────────────────────────────────────────────────┤
│ end()  // 空                                     │
│ → present()                                      │
└─────────────────────────────────────────────────┘
```

Forward 管线下,**光照在材质的 pixel shader 中直接计算**——每个图元绘制时,从 LightContainer 取出影响它的灯光,在 shader 中累加。这就是为什么 `applyLighting()` 是空实现。

### 10.3 Deferred 管线流程

`deferred_pipeline.cpp:259-411`:

```
┌─────────────────────────────────────────────────┐
│ Deferred Pipeline 流程                           │
├─────────────────────────────────────────────────┤
│ begin()                                          │
│   → 设置 viewport                                │
│   → Clear(TARGET|ZBUFFER|STENCIL)                │
│   → resetStencil()                               │
├─────────────────────────────────────────────────┤
│ beginCastShadows(shadowDC)                      │
│   → m_dynamicShadowManager->cast(shadowDC)      │
│   ... 提交阴影投射几何 ...                       │
│ endCastShadows()                                 │
├─────────────────────────────────────────────────┤
│ beginOpaqueDraw()                                │
│   → pushRenderTarget()                            │
│   → for i in 0..2:                               │
│       setWriteMask(i, 0xFFFFFFFF)                │
│       setRenderTarget(i, m_surfaces[i])          │
│   → if g_clearGBuffer: Clear(TARGET)              │
│   → setupSystemStencil(STENCIL_USAGE_OTHER_OPAQUE)│
│   ... 提交不透明几何到 GBuffer ...                │
│   → drawContext.flush(OPAQUE)                    │
│ endOpaqueDraw()                                  │
│   → restoreSystemStencil()                        │
│   → popRenderTarget()                            │
│   → setWriteMask(0, RGB)                         │
│   → setWriteMask(1, 0); setWriteMask(2, 0)       │
├─────────────────────────────────────────────────┤
│ applyLighting()                                  │
│   → pushRenderState(STENCILENABLE)               │
│   → pushRenderState(COLORWRITEENABLE)            │
│   → m_decalsManager->draw()       // 贴花         │
│   → m_SSAOSupport->resolve()       // SSAO        │
│   → m_dynamicShadowManager->receive() // 阴影接收  │
│   → m_HDRSupport->intercept()      // HDR 拦截    │
│   → m_lightsManager->draw()        // 灯光累积    │
│   → popRenderState(); popRenderState()            │
├─────────────────────────────────────────────────┤
│ beginSemitransparentDraw()  // 空                │
│   ... 提交半透明几何到 backbuffer ...            │
│   → drawContext.flush(TRANSPARENT)               │
│ endSemitransparentDraw()                         │
│   → m_spt->draw()    // 半透明树                  │
│   → m_HDRSupport->resolve()  // HDR 解析         │
│   → drawPostDeferred()       // 后期延迟 pass    │
├─────────────────────────────────────────────────┤
│ PostProcessing::Manager::draw()                 │
├─────────────────────────────────────────────────┤
│ beginGUIDraw()                                   │
│   → resetStencil()                               │
│   → pushRenderTarget()                            │
│   ... 绘制 GUI ...                               │
│ endGUIDraw()                                     │
│   → popRenderTarget()                            │
├─────────────────────────────────────────────────┤
│ end()  // 空                                     │
│ → present()                                      │
└─────────────────────────────────────────────────┘
```

#### 10.3.1 GBuffer 布局

`deferred_pipeline.cpp:515-520`:

```cpp
const D3DFORMAT dxFormats[] =
{
    D3DFMT_A8R8G8B8, // RGBA8: RGB - depth. A - object kind.
    D3DFMT_A8R8G8B8, // RGBA8: RG - normal. B - specular amount. A - user data #2     
    D3DFMT_A8R8G8B8  // RGBA8: RGB - albedo (diffuse) color, A - user data #1.
};
```

3 个 RGBA8 的 GBuffer,共 12 字节/像素:

| RT | R | G | B | A |
|----|---|---|---|---|
| 0 | depth.x | depth.y | depth.z | object kind |
| 1 | normal.x | normal.y | specular amount | user data #2 |
| 2 | albedo.r | albedo.g | albedo.b | user data #1 |

`object kind` 与 `EStencilUsage`(`renderer.hpp:64-70`)对应,用于按像素类型应用不同光照。

注意 GBuffer 没有存 normal.z,而是从 depth 重建位置后用 depth+XY 重建 normal——节省 8 位精度。或者更准确地说,normal.z 可以通过 `sqrt(1 - x*x - y*y)` 重建(法线是单位向量)。

#### 10.3.2 GBuffer 通道可视化

`deferred_pipeline.cpp:103-113` 的 `EGBufferChannel`:

```cpp
enum EGBufferChannel
{
    G_BUFFER_CHANNEL_DEPTH = 0,
    G_BUFFER_CHANNEL_OBJECT_KIND,
    G_BUFFER_CHANNEL_ALBEDO,
    G_BUFFER_CHANNEL_NORMAL,
    G_BUFFER_CHANNEL_BACKED_SHADOWS,
    G_BUFFER_CHANNEL_SPEC_AMOUNT,
    G_BUFFER_CHANNEL_MATERIAL_ID,
    G_BUFFER_CHANNEL_COUNT
};
```

调试时可通过 watcher `Render/DS/show g-buffer channel` 切换查看每个通道。`MapVisualizer`(`deferred_pipeline.cpp:77-118`)用 `shaders/std_effects/debug_g_buffer.fx` 显示。

#### 10.3.3 applyLighting 子系统协作

`applyLighting`(`deferred_pipeline.cpp:446-472`)是 Deferred 管线的核心:

```cpp
void DeferredPipeline::applyLighting()
{
    Moo::rc().pushRenderState( D3DRS_STENCILENABLE );
    Moo::rc().pushRenderState( D3DRS_COLORWRITEENABLE );

    m_decalsManager->draw();              // 1. 画贴花(写到 GBuffer)
    m_SSAOSupport->resolve();             // 2. SSAO(写到 backbuffer)
    m_dynamicShadowManager->receive();     // 3. 接收阴影(写到 backbuffer)
    m_HDRSupport->intercept();             // 4. HDR 拦截(切换到 HDR 缓冲)
    m_lightsManager->draw();               // 5. 灯光累积(对每个光源画一个全屏 quad)

    Moo::rc().popRenderState();
    Moo::rc().popRenderState();
}
```

注意顺序:**贴花先于 SSAO 先于阴影先于 HDR 先于光照**。这是为了让光照阶段读取的 GBuffer 已经包含贴花修改的 albedo/normal。

#### 10.3.4 drawPostDeferred

`drawPostDeferred`(`deferred_pipeline.cpp:117`)是在半透明绘制后调用的"延迟后期"pass,用于:
- 半透明物体不写入 GBuffer,需要在 backbuffer 上单独光照
- 体积雾、God Ray 等屏幕空间特效

### 10.4 DrawContext 延迟渲染队列

`draw_context.hpp:101-237` 是 Moo 的延迟渲染队列核心:

```cpp
class DrawContext
{
public:
    enum ChannelMask
    {
        OPAQUE_CHANNEL_MASK      = 0x00000001,
        TRANSPARENT_CHANNEL_MASK = 0x00000002,
        SHIMMER_CHANNEL_MASK     = 0x00000004,
        NUM_CHANNEL_MASKS         = 3,
        ALL_CHANNELS_MASK = ((1 << NUM_CHANNEL_MASKS) - 1)
    };

    DrawContext( ERenderingPassType renderingPassType );

    void pushGlobalStateBlock( GlobalStateBlock* userConstants );
    void popGlobalStateBlock( GlobalStateBlock* userConstants );
    void pushImmediateMode();
    void popImmediateMode();
    void pushOverrideBlock( OverrideBlock* overrideBlock );
    void popOverrideBlock( OverrideBlock* overrideBlock );

    virtual void begin( uint32 channelMask );
    virtual void end( uint32 channelMask );
    virtual void flush( uint32 channelMask, bool isClearing = true );
    uint32 collectChannelMask() const { return collectChannelMask_; }

    void drawRenderOp( ComplexEffectMaterial* material,
        Vertices* vertices, Primitive* primitives, uint32 groupIndex,
        InstanceData* instanceData, const BoundingBox& worldBB );

    void drawUserItem( UserDrawItem* userItem,
        ChannelMask channelType, float distance = 0.0f );

    InstanceData* allocInstanceData( uint32 numPalletteEntries );
    // ...
private:
    DynamicArray<RenderOp>          opaqueOps_;        // 不透明(按 material/vb/ib 排序)
    DynamicArray<DistanceSortedOp>  transparentOps_;  // 半透明(按距离排序)
    DynamicArray<WrapperOp>         shimmerOps_;       // 闪烁(不排序)
    GlobalStateRecorder*            globalStateRecorder_;
    uint32                          immediateModeCounter_;
    OverrideBlock*                 activeOverride_;
    ERenderingPassType             renderingPassType_;
    uint32                         collectChannelMask_;
    RenderOpProcessor*             ropProcessor_;
    GrowOnlyPodAllocator           instanceDataAllocator_;
    const bool                     hwInstancingAvailable_;
};
```

#### 10.4.1 三个通道

| 通道 | 排序策略 | 用途 |
|------|---------|------|
| Opaque | 按 effect/technique/materialProperties/vb/ib 排序 | 不透明物体,最小化状态切换 |
| Transparent | 按相机距离从远到近排序 | 半透明物体,保证正确深度顺序 |
| Shimmer | 不排序,按提交顺序 | 闪烁效果(如热扭曲),后处理用 |

#### 10.4.2 RenderOp 数据结构

`draw_context.cpp:140-176`:

```cpp
struct RenderOp
{
    static const uint32 PRIMTYPE_NUMBITS = 3;
    static const uint32 PRIMTYPE_MASK    = (1 << PRIMTYPE_NUMBITS) - 1;
    static const uint32 FLAG_HW_INSTANCING = 1 << PRIMTYPE_NUMBITS;

    ManagedEffect*          effect_;                 // 排序键 1
    ManagedEffect::Handle   technique_;              // 排序键 2
    MaterialProperties*     materialProperties_;     // 排序键 3
    uint32                  globalStateBlockIndex_;  // 排序键 4
    const VertexDeclaration* vertexDeclaration_;    // 排序键 5
    const VertexBuffer*     vertexBuffer_;           // 排序键 6
    const IndexBuffer*      indexBuffer_;            // 排序键 7
    const StreamContainer*  vertexStreams_; 
    uint32                  defaultVertexBufferOffset_;
    uint32                  defaultVertexStride_;
    PrimitiveGroup          primitiveGroupInfo_;
    DrawContext::InstanceData* instanceData_;
    uint32                  flags_;
};
```

注意 `effect_` 是裸指针——`DrawContext` 在 flush 期间持有这些指针,期间引用的对象不会被销毁(由调用者保证)。

#### 10.4.3 RenderOpCompare 排序

`draw_context.cpp:395-426`:

```cpp
inline bool RenderOpCompare( const RenderOp& rop0, const RenderOp& rop1 )
{
    if (rop0.effect_ == rop1.effect_)
    {
        if (rop0.technique_ == rop1.technique_)
        {
            if (rop0.materialProperties_ == rop1.materialProperties_)
            {
                if (rop0.globalStateBlockIndex_ == rop1.globalStateBlockIndex_)
                {
                    if (rop0.vertexDeclaration_ == rop1.vertexDeclaration_)
                    {
                        if (rop0.vertexBuffer_ == rop1.vertexBuffer_)
                        {
                            if (rop0.indexBuffer_ == rop1.indexBuffer_)
                            {
                                return rop0.primitiveGroupInfo_.startIndex_ < rop1.primitiveGroupInfo_.startIndex_;
                            }
                            return rop0.indexBuffer_ < rop1.indexBuffer_;
                        }
                        return rop0.vertexBuffer_ < rop1.vertexBuffer_;
                    }
                    return rop0.vertexDeclaration_ < rop1.vertexDeclaration_;
                }
                return rop0.globalStateBlockIndex_ < rop1.globalStateBlockIndex_;
            }
            return rop0.materialProperties_ < rop1.materialProperties_;
        }
        return rop0.technique_ < rop1.technique_ ;
    }
    return rop0.effect_ < rop1.effect_;
}
```

排序键优先级(从高到低):
1. **effect** (最贵,切换 .fx 文件)
2. **technique** (切换 technique handle)
3. **materialProperties** (切换纹理/常量)
4. **globalStateBlockIndex** (全局状态覆盖)
5. **vertexDeclaration** (切换顶点声明)
6. **vertexBuffer** (切换 VB)
7. **indexBuffer** (切换 IB)
8. **startIndex** (在同一个 IB 内,按起始索引排序)

这种排序的目标是**最小化状态切换**,特别是最贵的 effect 切换(需要重新绑定 shader)。

#### 10.4.4 透明排序

`draw_context.cpp:213-330` 的 `sortTrianglesByCameraDistance` 是**按三角形级别**排序(比按 object 级别更精细),用于半透明物体内部:

```cpp
void sortTrianglesByCameraDistance( RenderOp& renderOp,
                                    const IndicesHolder& inputIndices,
                                    const Vector3* inputVertexPositions )
{
    // 1. 计算每个顶点的相机距离
    Matrix worldViewProj;
    worldViewProj.multiply( *renderOp.instanceData_->matrix(), Moo::rc().viewProjection() );
    Vector3 vec( worldViewProj.row(0).w, worldViewProj.row(1).w, worldViewProj.row(2).w );
    float d = worldViewProj.row(3).w;
    for (uint32 i = 0; i < pg.nVertices_; i++)
        vertexDistances.push_back( vec.dotProduct(inputVertexPositions[i]) + d );

    // 2. 计算每个三角形的最远顶点距离
    while (index != end)
    {
        float dist1 = vertexDistances[inputIndices[index] - pg.startVertex_];
        ++index;
        float dist2 = vertexDistances[inputIndices[index] - pg.startVertex_];
        ++index;
        float dist3 = vertexDistances[inputIndices[index] - pg.startVertex_];
        ++index;
        triangleDistances.push_back( TriangleDistance( dist1, dist2, dist3, currentTriangleIndex ) );
        currentTriangleIndex += 3;
    }

    // 3. 按距离从远到近排序(+z 是屏幕里方向)
    std::sort( triangleDistances.rbegin(), triangleDistances.rend() );

    // 4. 写入新的索引缓冲
    DynamicIndexBufferBase& dib = rc().dynamicIndexBufferInterface().get( format );
    Moo::IndicesReference ind = dib.lock2( triangleDistances.size() * 3 );
    // ... 拷贝排序后的索引 ...
    dib.unlock(); 

    renderOp.indexBuffer_ = &dib.indexBuffer();
    renderOp.flags_ = (uint32)(D3DPT_TRIANGLELIST);
    renderOp.primitiveGroupInfo_.startIndex_ = dib.lockIndex();
}
```

注意 `TriangleDistance`(行 221-235)取三个顶点距离的**最大值**作为三角形距离——这样三角形从远到近画时,远三角形的所有像素都会被近三角形覆盖。

#### 10.4.5 GlobalStateBlock 全局状态覆盖

`draw_context.hpp:49-73`:

```cpp
class GlobalStateBlock : public ResourceModificationListener
{
public:
    enum ApplyMode
    {
        APPLY_MODE,         // 应用新块的状态
        UNDO_MODE,          // 撤销旧块的状态
        CHANGE_EFFECT_MODE  // effect 重编译后重新应用
    };
    virtual void apply( ManagedEffect* effect, ApplyMode mode ) = 0;
};
```

业务代码可以继承 `GlobalStateBlock`,在 `apply()` 中设置全局 shader 常量(如风、时间、自定义雾)。`DrawContext` 提供 push/pop 接口,在 flush 时按 chain 顺序应用所有 active block。

`GlobalStateRecorder`(`draw_context.cpp:22-129`)记录这些 block 的链式结构,允许通过 `captureChain()` 返回一个索引,后续用 `applyChain(index, mode, effect)` 重新应用——这是延迟渲染的关键,**在 record 阶段捕获状态,在 flush 阶段应用**。

#### 10.4.6 OverrideBlock 材质覆盖

`draw_context.hpp:120-133`:

```cpp
class OverrideBlock
{
public:
    OverrideBlock( const BW::StringRef& shaderPrefix, bool isDoubleSided = false );
    void process( ComplexEffectMaterial*& material, bool isSkinned ) const;
    bool isValid() const;
private:
    SmartPointer<ComplexEffectMaterial> materials_[2];  // [0]=rigid, [1]=skinned
};
```

`OverrideBlock` 用于"全局材质替换"——例如渲染阴影时,所有图元都用一个统一的"shadow cast"材质;渲染深度 prepass 时,用统一的"depth only"材质。`process()` 接收一个 `ComplexEffectMaterial*`,如果该材质支持 override,则替换为 `materials_[isSkinned]`。

### 10.5 HW Instancing

`draw_context.hpp:144-152`:

```cpp
struct InstanceData
{
    static const uint32 NUM_VECTOR4_PER_SKIN_MATRIX = 3;
    uint32      paletteSize_;   // if 0 use a single world transform matrix
    inline Matrix* matrix()    { MF_ASSERT_DEV(paletteSize_ == 0 ); return (Matrix*)(this + 1); }
    inline Vector4* palette()   { MF_ASSERT_DEV(paletteSize_ != 0 ); return (Vector4*)(this + 1); }
};
```

`InstanceData` 是一个**变长结构**(header + payload):
- `paletteSize_ == 0`:payload 是 1 个 Matrix(刚体世界变换)
- `paletteSize_ > 0`:payload 是 `paletteSize_ * 3` 个 Vector4(骨骼 palette)

`DrawContext::allocInstanceData(numPaletteEntries)` 从 `instanceDataAllocator_`(GrowOnlyPodAllocator)分配。这个 allocator 在 flush 时清空,避免每帧分配/释放内存碎片。

`hwInstancingAvailable_`(`draw_context.hpp:215`)决定是否使用 GPU instancing:

```cpp
const bool hwInstancingAvailable_;
```

如果硬件支持 SM3.0 instancing,则相同材质+相同 VB+相同 IB 的 RenderOp 会被合并成一个 instanced draw call,显著降低 DrawCall 数量。

---

## 十一、后处理系统

后处理位于独立的 `lib/post_processing/` 模块,通过 Python 脚本配置。

### 11.1 架构

```
PostProcessing::Manager (singleton)
  └─ Effects (vector)
       └─ Effect (PyType)
            ├─ Phases (vector)
            │    └─ Phase (PyType, abstract)
            │         ├─ DownsamplePhase
            │         ├─ BlurPhase
            │         ├─ CopyBackBufferPhase
            │         └─ ... (各种具体 Phase)
            └─ FilterQuads (vector)
                 └─ FilterQuad (PyType)
                      └─ VisualTransferMesh / PointSpriteTransferMesh / TransferQuad
```

### 11.2 Manager

`manager.hpp:13-33`:

```cpp
class Manager : public Singleton< Manager >
{
public:
    void tick( float dTime );
    void draw();
    void debug( DebugPtr d ) { debug_ = d; }
    DebugPtr debug() const      { return debug_; }
    typedef BW::vector<EffectPtr> Effects;
    const Effects& effects() const { return effects_; }
    // Python 接口
    PY_MODULE_STATIC_METHOD_DECLARE( py_chain )
    PY_MODULE_STATIC_METHOD_DECLARE( py_debug )
    PY_MODULE_STATIC_METHOD_DECLARE( py_profile )
    PY_MODULE_STATIC_METHOD_DECLARE( py_save )
    PY_MODULE_STATIC_METHOD_DECLARE( py_load )
private:
    PyObject* getChain() const;
    PyObject* setChain( PyObject * args );
    Effects   effects_;
    DebugPtr  debug_;
};
```

`draw()`(`manager.cpp:67-96`)遍历所有 effect,调用 `e->draw(debug)`:

```cpp
void Manager::draw()
{
    Moo::rc().MRTSupport().bind();     // 绑定 MRT(用于深度访问)
    Moo::rc().pushRenderState( D3DRS_COLORWRITEENABLE );
    Moo::rc().setRenderState( D3DRS_COLORWRITEENABLE, 
        D3DCOLORWRITEENABLE_RED | D3DCOLORWRITEENABLE_GREEN | 
        D3DCOLORWRITEENABLE_BLUE | D3DCOLORWRITEENABLE_ALPHA );

    if ( debug_.hasObject() )
        debug_->beginChain( static_cast<uint32>( effects_.size() ) );

    Effects::iterator it = effects_.begin();
    Effects::iterator end = effects_.end();
    for (; it != end; it++)
    {
        Effect* e = it->getObject();
        e->draw( debug_.getObject() );
    }

    Moo::rc().popRenderState();
    Moo::rc().MRTSupport().unbind();
}
```

### 11.3 Effect 与 Phase

`effect.hpp:21-51`:

```cpp
class Effect : public PyObjectPlus
{
    Py_Header( Effect, PyObjectPlus )
public:
    Effect( PyTypeObject *pType = &s_type_ );
    virtual void tick( float dTime );
    virtual void draw( class Debug* );
    virtual bool load( DataSectionPtr );
    virtual bool save( DataSectionPtr );

    typedef BW::vector<PhasePtr> Phases;
    const Phases& phases() const { return phases_; }
    // ...
private:
    Phases phases_;
    PySTLSequenceHolder<Phases> phasesHolder_;
    BW::string name_;
    Vector4ProviderPtr bypass_;   // 用于动态启用/禁用
};
```

`Phase`(`phase.hpp:27-46`)是抽象基类,具体实现包括:
- `DownsamplePhase`:降采样
- `BlurPhase`:高斯模糊
- `CopyBackBufferPhase`:复制 backbuffer
- 自定义 Phase(通过 Python 注册)

每个 Phase 在 `draw()` 中:
1. 设置 RenderTarget(可能是临时 RT,也可能是 backbuffer)
2. 设置 shader 参数
3. 用 `FilterQuad` 画一个全屏 quad

### 11.4 FilterQuad 与 TransferMesh

`FilterQuad` 是后处理专用的"全屏几何":
- `TransferQuad`:简单的四边形
- `VisualTransferMesh`:从 Visual 模型生成的几何(用于特殊效果,如把场景渲染到粒子上)
- `PointSpriteTransferMesh`:点精灵(用于粒子后处理)

### 11.5 后处理链配置

后处理链通常通过 Python 脚本配置:

```python
import PostProcessing as PP

# 创建一个效果
effect = PP.Effect()
effect.name = "Bloom"

# 添加阶段
downsample = PP.DownsamplePhase()
downsample.factor = 0.5
effect.phases.append(downsample)

blur = PP.BlurPhase()
blur.radius = 4
effect.phases.append(blur)

# 添加到链
chain = PP.chain()
chain.append(effect)
PP.chain(chain)
```

也可以通过 XML 文件加载(`manager.cpp:207-237`):

```python
PP.load(dataSection)
```

### 11.6 性能监控

`Manager::py_profile`(`manager.cpp:342-408`)用 D3D Query 测量后处理链的 GPU 时间:

```cpp
ComObjectWrap<DX::Query> pFreqQuery;
HRESULT hr = Moo::rc().device()->CreateQuery(D3DQUERYTYPE_TIMESTAMPFREQ, &pFreqQuery);
// ...

ComObjectWrap<DX::Query> pStartQuery;
ComObjectWrap<DX::Query> pEndQuery;
hr = Moo::rc().device()->CreateQuery(D3DQUERYTYPE_TIMESTAMP, &pStartQuery);
hr = Moo::rc().device()->CreateQuery(D3DQUERYTYPE_TIMESTAMP, &pEndQuery);

pStartQuery->Issue(D3DISSUE_BEGIN);
pStartQuery->Issue(D3DISSUE_END);

for (size_t i=0; i<nSamples; i++)
    Manager::instance().draw();

pEndQuery->Issue(D3DISSUE_BEGIN);
pEndQuery->Issue(D3DISSUE_END);

// 等待结果
while(S_FALSE == pStartQuery->GetData( &startTime64, sizeof(DWORD), D3DGETDATA_FLUSH ) && ...);
while(S_FALSE == pEndQuery->GetData( &endTime64, sizeof(DWORD), D3DGETDATA_FLUSH ) && ...);

double timeMSec = (double)(endTime64 - startTime64) / (double)timerFreq64;
return Script::getData( timeMSec / (double)nSamples );
```

通过 `TIMESTAMPFREQ` 查询频率,`TIMESTAMP` 查询时间戳,计算平均值。这是 D3D9 时代测量 GPU 时间的标准做法。

---

## 十二、纹理管理

### 12.1 纹理层次结构

```
BaseTexture (abstract)
  ├─ ManagedTexture (.dds/.bmp/.jpg 加载,设备托管)
  ├─ StreamingTexture (流式加载)
  ├─ RenderTarget (作为纹理的渲染目标)
  ├─ CubeRenderTarget (cube map 渲染目标)
  ├─ AnimatingTexture (动画纹理)
  └─ SysMemTexture (系统内存纹理,不上传 GPU)
```

### 12.2 TextureManager

`texture_manager.hpp:35-189`:

```cpp
class TextureManager :
    public Moo::DeviceCallback,
    public ResourceModificationListener
{
public:
    class ProgressListener
    {
    public:
        enum ProgressType { PURGE, RELOAD };
        virtual void onTextureManagerProgress( ProgressType progressType, 
                        int totalSteps, int numCompleted, int step = 1 ) = 0;
    };

    typedef BW::StringRefMap< BaseTexture * > TextureMap;

    static TextureManager* instance();
    TextureStreamingManager * streamingManager() { return streamingManager_.get(); }
    TextureDetailLevelManager * detailManager() { return pDetailLevels_; }

    static const BW::string & notFoundBmp();

    HRESULT initTextures( );
    void    releaseTextures( );

    uint32  textureMemoryUsed( ) const;
    void    fullHouse( bool noMoreEntries = true );

    static bool writeDDS( DX::BaseTexture* texture, 
                        const BW::StringRef& ddsName, D3DFORMAT format, int numDestMipLevels = 0 );
    void    reloadAllTextures( ProgressListener* pCallBack = NULL );
    void    useDummyTexture( bool useDummyTexture ) { useDummyTexture_ = useDummyTexture_; }
    
    BaseTexturePtr get( const BW::StringRef & resourceID,
        bool allowAnimation = true, bool mustExist = true,
        bool loadIfMissing = true, const char* = "texture/unknown texture" );
    BaseTexturePtr getUnique( 
        const BW::StringRef& resourceID,
        const BW::StringRef & sanitisedResourceID = "",
        bool allowAnimation = true, bool mustExist = true,
        const char* = "texture/unknown texture" );
    bool isTextureFile( const BW::StringRef& resourceID, bool checkExists = true ) const;

    int configurableMipFilter() const;
    int configurableMinMagFilter() const;
    int configurableMaxAnisotropy() const;
    // ...
private:
    TextureMap          textures_;
    RecursiveMutex      texturesLock_;
    std::auto_ptr< TextureStreamingManager > streamingManager_;
    bool                fullHouse_;
    int                 lodMode_;
    bool                useDummyTexture_;
    static size_t       minMemoryForHighTextures;
    GraphicsSetting::GraphicsSettingPtr qualitySettings_;
    GraphicsSetting::GraphicsSettingPtr compressionSettings_;
    GraphicsSetting::GraphicsSettingPtr filterSettings_;
    TextureStringVector dirtyTextures_;
    TextureDetailLevelManager* pDetailLevels_;
};
```

#### 12.2.1 纹理缓存

`textures_` 是 `BW::StringRefMap<BaseTexture*>`,即"resourceID 字符串引用 → 纹理指针"的映射。`get()` 流程:

1. 在 `textures_` 中查找
2. 命中:增加引用计数,返回
3. 未命中:如果 `loadIfMissing`,创建 `ManagedTexture`,加入 `textures_`,返回
4. 失败:如果 `useDummyTexture_`,返回 `notFoundBmp()` 占位纹理

#### 12.2.2 GraphicsSetting 三件套

| 设置 | 选项 | 影响 |
|------|------|------|
| `qualitySettings_` | High/Medium/Low | 决定纹理压缩格式(BC1/BC3/BC5) |
| `compressionSettings_` | On/Off | 是否使用压缩纹理 |
| `filterSettings_` | Bilinear/Trilinear/Anisotropic | 采样过滤模式 |

这些设置通过 `GraphicsSetting` 系统暴露给用户,运行时可切换。切换后会触发 `reloadAllTextures()`(可选,带 ProgressListener 进度回调)。

#### 12.2.3 fullHouse 内存控制

`fullHouse(noMoreEntries=true)` 设置 `fullHouse_` 标志,后续 `get()` 调用如果未命中缓存,会返回 dummy texture 而非加载新纹理。用于内存吃紧时阻止加载新资源。

#### 12.2.4 minMemoryForHighTextures

`static size_t minMemoryForHighTextures`(`texture_manager.hpp:173` + `texture_manager.hpp:109`)是一个全局阈值,通过 `setTextureMemoryBlock(minMemory)` 设置。如果可用显存低于该值,自动降级到低质量纹理。

### 12.3 ManagedTexture

`managed_texture.hpp:24-100`:

```cpp
class ManagedTexture : public BaseTexture
{
public:
    typedef ComObjectWrap< DX::BaseTexture > Texture;

    ManagedTexture( 
        const BW::StringRef& resourceID, uint32 w, uint32 h, int nLevels,
        DWORD usage, D3DFORMAT fmt, const BW::StringRef& allocator = 
        "texture/unknown managed texture" );
    bool resize( uint32 w, uint32 h, int nLevels, DWORD usage, D3DFORMAT fmt );

    DX::BaseTexture*   pTexture( );
    const BW::string&  resourceID( ) const;
    uint32             width( ) const;
    uint32             height( ) const;
    D3DFORMAT          format( ) const;
    virtual uint32     textureMemoryUsed() const;

    static void        tick();

    virtual uint32     mipSkip() const;
    virtual void       mipSkip( uint32 mipSkip );
    virtual bool       isCubeMap() { return cubemap_; }

    virtual void       load() {
        return this->load( BaseTexture::FAIL_ATTEMPT_LOAD_PLACEHOLDER ); }
    virtual void       release();
    virtual void       reload( );
    virtual void       reload( const BW::StringRef & resourceID );

    static uint32      totalFrameTexmem_;
    // ...
};
```

特点:
- **D3DPOOL_MANAGED**:由驱动备份,设备丢失时自动恢复
- **mipSkip**:跳过前 N 个 mipmap,降低显存占用
- **totalFrameTexmem_**:全局静态,统计本帧纹理内存使用(用于性能监控)

### 12.4 流式纹理 StreamingTexture

`streaming_texture.hpp` 实现按需上载 mipmap 的流式纹理:

```
纹理文件 → 解析头 → 按 LOD 决定上载多少 mipmap → 上传到 GPU
                          ↑
                  texture_detail_level_manager 决定
```

`TextureStreamingManager`(`texture_streaming_manager.hpp/cpp`)是全局管理器,负责:
- 监控显存使用
- 决定哪些纹理需要上载/降级
- 与 `TextureStreamingSceneView` 协作,只流式加载相机可见的纹理

这是 BigWorld 适配大世界(可能数百 GB 纹理)的关键机制。

### 12.5 纹理压缩

`texture_compressor.hpp/ipp` 提供运行时纹理压缩:
- 输入:未压缩的内存纹理
- 输出:DXT1/3/5 压缩纹理

`TextureDetailLevel`(`texture_detail_level.hpp`)描述单个纹理的 LOD 等级,`TextureDetailLevelManager`(`texture_detail_level_manager.hpp`)管理所有纹理的 LOD 等级,根据显存压力动态调整。

### 12.6 TextureReuseCache

`render_context.hpp:21` 包含 `moo/texture_reuse_cache.hpp`。`TextureReuseCache`(`texture_reuse_cache.hpp`)是一个**临时纹理复用池**:

后处理链中,每个 Phase 可能需要一个临时 RenderTarget。如果不复用,每帧都会创建/销毁,造成内存碎片。`TextureReuseCache` 按 (width, height, levels, usage, format, pool) 元组缓存,相同规格的纹理可以复用。

`RenderContext::getTextureFromReuseList`/`putTextureToReuseList`(`render_context.hpp:460-462, 394`)是访问入口。

---

## 十三、RenderTarget 渲染目标

### 13.1 RenderTarget 类

`render_target.hpp:24-89`:

```cpp
class RenderTarget : public BaseTexture, public DeviceCallback
{
public:
    RenderTarget( const BW::string & identitifer );

    virtual bool create( int width, int height, bool reuseMainZBuffer = false, 
        D3DFORMAT pixelFormat = D3DFMT_A8R8G8B8, RenderTarget* pDepthStencilParent = NULL,
        D3DFORMAT depthFormatOverride = D3DFMT_UNKNOWN, bool discardDepthBuffer = true );
    virtual void release();
    virtual bool push( void );
    virtual void pop( void );
    void clearOnRecreate( bool enable, const Colour& col = (DWORD)0x00000000 );
    virtual bool valid( );
    HRESULT pSurface( ComObjectWrap<DX::Surface>& ret );
    virtual bool copyTexture( Moo::BaseTexturePtr pTexture );

    // BaseTexture 接口
    virtual DX::BaseTexture*   pTexture( );
    virtual DX::Surface*      depthBuffer( );
    virtual uint32            width( ) const;
    virtual uint32            height( ) const;
    virtual D3DFORMAT         format( ) const;
    virtual uint32            textureMemoryUsed( ) const;
    virtual const BW::string& resourceID( ) const;

    // DeviceCallback 接口
    virtual void              deleteUnmanagedObjects( );
    virtual bool              recreateForD3DExDevice() const;

    void setRT2( RenderTarget* rt2 ) { pRT2_ = rt2; }
private:
    void allocate();
    bool ensureAllocated();
    uint32 width_, height_;
    int32 origWidth_, origHeight_;
    void calculateDimensions();
    
    RenderTarget* pRT2_;   // MRT 用的第二个 RT
    
    BW::string           resourceID_;
    ComObjectWrap<DX::Texture>   pRenderTarget_;
    ComObjectWrap<DX::Surface>   pDepthStencilTarget_;
    bool reuseZ_;
    bool discardDepthStencil_;
    D3DFORMAT depthFormat_;
    D3DFORMAT pixelFormat_;
    bool autoClear_;
    Colour   clearColour_;
    RenderTargetPtr pDepthStencilParent_;
};
```

#### 13.1.1 create 参数

`create()` 接收:
- `width, height`:尺寸
- `reuseMainZBuffer`:是否复用主 ZBuffer(必须尺寸一致)
- `pixelFormat`:像素格式,默认 A8R8G8B8
- `pDepthStencilParent`:共享另一个 RT 的 DepthStencil(用于多 RT 共享深度)
- `depthFormatOverride`:自定义深度格式
- `discardDepthBuffer`:depth buffer 是否可丢弃(性能优化)

#### 13.1.2 push/pop 模式

```cpp
virtual bool push( void );   // 保存当前 RT,设置新 RT
virtual void pop( void );     // 恢复原 RT
```

`push()` 内部调用 `RenderContext::pushRenderTarget()`,将当前的 RenderTarget、Viewport、Camera、View/Projection 入栈。`pop()` 恢复。

这种 RAII 风格的 push/pop 允许嵌套渲染到不同目标,例如:

```cpp
myRT.push();
// 渲染到 myRT
myRT.pop();
// 恢复到 backbuffer
```

#### 13.1.3 clearOnRecreate

`clearOnRecreate(true, color)` 设置在设备重建后自动 clear 一次。某些 RT 在重建后内容未定义,需要主动 clear 才能使用。

### 13.2 RenderTargetStack

`render_context.hpp:468-498` 定义了内部的 RT 栈:

```cpp
struct RenderTargetStack
{
public:
    bool push( class RenderContext* rc );
    bool pop( class RenderContext* rc );
    int nStackItems();
    void clear() { stackItems_.clear(); }
private:
    class StackItem
    {
    public:
        StackItem() : cam_( 0.5f, 200.f, MATH_PI * 0.5f, 1.f ), zbufferSurface_( NULL ) {}
        ComObjectWrap< DX::Surface >   renderSurfaces_[MAX_CONCURRENT_RTS];
        ComObjectWrap< DX::Surface >   zbufferSurface_;
        DX::Viewport                   viewport_;
        Matrix                         view_;
        Matrix                         projection_;
        Camera                         cam_;
    };
    typedef BW::vector< StackItem > StackItems;
    StackItems stackItems_;
};
```

每次 push 保存:
- 最多 `MAX_CONCURRENT_RTS=4`(`render_context.hpp:25`)个 RenderSurface
- ZBuffer Surface
- Viewport
- View/Projection Matrix
- Camera

`MAX_CONCURRENT_RTS` 至少为 1,但为了支持 MRT(同时渲染到多个 RT),设为 4。

### 13.3 CubeRenderTarget

`cube_render_target.hpp/ipp` 是 CubeMap 渲染目标,用于:
- 反射 probe(环境反射)
- 点光源 shadow map
- 天空盒

它有 6 个面(+X/-X/+Y/-Y/+Z/-Z),每次渲染一个面。

### 13.4 RenderTargetSetter

`render_target.hpp:96-105`:

```cpp
class RenderTargetSetter : public Moo::EffectConstantValue
{
public:
    RenderTargetSetter( RenderTarget*, DX::BaseTexture* backup = NULL );
    bool operator()(ID3DXEffect* pEffect, D3DXHANDLE constantHandle);
    void renderTarget( RenderTarget* rt );
private:
    RenderTargetPtr pRT_;
    ComObjectWrap<DX::BaseTexture> backup_;
};
```

这是 EffectMaterial 的"自动常量"绑定——当 shader 中有 `texture g_myRT;` 时,`RenderTargetSetter` 自动把 RT 的纹理绑定到该常量。这样 shader 不需要手动 SetTexture。

---

## 十四、FogHelper 雾效

`fog_helper.hpp:14-49`:

```cpp
struct FogParams
{
    FogParams()
        : m_enabled(false), m_density(1.0f), m_start(0.0f), m_end(0.0f),
        m_outerBB(0,0,0,0), m_innerBB(0,0,0,0) { } 

    float   m_enabled;
    float   m_density;
    float   m_start;
    float   m_end;
    Colour  m_color;
    Vector4 m_outerBB;    // fog outer box
    Vector4 m_innerBB;    // fog inner box
};

class FogHelper
{
    static FogHelper* s_pInstance;
    FogParams m_fogParams;
public:
    const FogParams& fogParams() const;
    void fogParams(const FogParams& params);
    void fogEnable(bool enable);
    bool fogEnabled() const;
    static FogHelper* pInstance();
    FogHelper();
    ~FogHelper();
};
```

### 14.1 双层雾设计

`FogParams` 注释(行 9-14)说明雾分为两部分:

1. **距离雾**:基于到相机的距离,`m_start`/`m_end` 控制起止
2. **盒形雾**:由 `m_outerBB`/`m_innerBB` 定义内外两个 box,从 inner 到 outer 平滑过渡

这种"双层"设计允许:
- 远处地平线用距离雾隐藏场景边界
- 局部区域用盒形雾做"毒气云"、"魔法效果"等

### 14.2 GPU 友好布局

注释(行 11-13)强调:

> watch the structure memory alignment because we send this structure as is to the GPU and GPU has 16 bytes alignment.

`FogParams` 的字段顺序精心设计:
- 4 个 float (16 字节)
- Colour (16 字节)
- 2 个 Vector4 (32 字节)

总计 64 字节,正好 4 个 16 字节对齐的 GPU 常量寄存器。

### 14.3 全局单例

`FogHelper` 通过 `s_pInstance` 单例暴露,`pInstance()` 是访问入口。`RenderContext` 持有一个 `fogHelper_` 成员(`render_context.hpp:628`)。

构造时(`render_context.cpp:228-232`)设置默认雾:

```cpp
Moo::FogParams params = Moo::FogHelper::pInstance()->fogParams();
params.m_start = 0;
params.m_end = 500;
params.m_color = 0x000000FF;
Moo::FogHelper::pInstance()->fogParams( params );
```

---

## 十五、GPU 信息与性能

### 15.1 GpuInfo 类

`gpu_info.hpp:15-54`:

```cpp
class GpuInfo
{
public:
    struct MemInfo
    {
        MemInfo() :
            systemMemReserved_( 0 ),
            systemMemUsed_( 0 ),
            dedicatedMemTotal_( 0 ),
            dedicatedMemCommitted_( 0 ),
            sharedMemTotal_( 0 ),
            sharedMemCommitted_( 0 ),
            virtualAddressSpaceTotal_( 0 ),
            virtualAddressSpaceUsage_( 0 ),
            privateUsage_( 0 )
        {}

        uint64 systemMemReserved_;
        uint64 systemMemUsed_;
        uint64 dedicatedMemTotal_;
        uint64 dedicatedMemCommitted_;
        uint64 sharedMemTotal_;
        uint64 sharedMemCommitted_;
        uint64 virtualAddressSpaceTotal_;
        uint64 virtualAddressSpaceUsage_;
        uint64 privateUsage_;
    };

    GpuInfo();
    ~GpuInfo();

    bool getMemInfo(MemInfo* outMemInfo, uint32 adapterID) const;
private:
    Private::GpuInfoImpl* pimpl_;
};
```

### 15.2 实现细节:D3DKMT

`gpu_info.cpp` 使用了一个鲜为人知的 Windows API——**D3DKMT**(DirectX Graphics Kernel Migration Toolkit):

```cpp
// gpu_info.cpp:113-122
HMODULE gdiModule = GetModuleHandle(L"gdi32.dll");
d3dOpenAdapterFromDeviceNameFunc_ = (PFND3DKMT_OPENADAPTERFROMDEVICENAME)
    GetProcAddress(gdiModule, "D3DKMTOpenAdapterFromDeviceName");
d3dCloseAdapterFunc_ = (PFND3DKMT_CLOSEADAPTER)
    GetProcAddress(gdiModule, "D3DKMTCloseAdapter");
d3dQueryStatisticsFunc_ = (PFND3DKMT_QUERYSTATISTICS)
    GetProcAddress(gdiModule, "D3DKMTQueryStatistics");
```

D3DKMT 是 Windows 内核级的 GPU 查询接口,可以获取:
- 适配器句柄
- 显存段(segment)信息
- 每进程的显存使用

### 15.3 显存段类型

`gpu_info.cpp:41-46`:

```cpp
enum SegmentType
{
    ST_INVALID,
    ST_SHARED,       // 共享显存(集成显卡的 UMA 内存)
    ST_DEDICATED     // 专用显存(独显的 VRAM)
};
```

每段有 `commitLimit_`(总容量)和 `bytesCommitted_`(已使用),`getMemInfo` 汇总所有段:

```cpp
// gpu_info.cpp:284-345
bool GpuInfoImpl::getMemInfo( GpuInfo::MemInfo * outMemInfo, uint32 adapterID ) const
{
    // ...
    // 进程级使用
    initQuery( adapter, D3DKMT_QUERYSTATISTICS_PROCESS, &queryStatistics );
    if (performQuery( &queryStatistics ))
    {
        outMemInfo->systemMemReserved_ = queryStatistics.QueryResult.ProcessInformation.SystemMemory.BytesReserved;
        outMemInfo->systemMemUsed_     = queryStatistics.QueryResult.ProcessInformation.SystemMemory.BytesAllocated;
    }

    // 进程私有内存
    PROCESS_MEMORY_COUNTERS_EX procMemCounters;
    ::GetProcessMemoryInfo( ::GetCurrentProcess(), (PROCESS_MEMORY_COUNTERS*)&procMemCounters, sizeof(procMemCounters) );
    outMemInfo->privateUsage_ = procMemCounters.PrivateUsage;

    // 虚拟地址空间
    MEMORYSTATUSEX memoryStatus = { sizeof( memoryStatus ) };
    GlobalMemoryStatusEx( &memoryStatus );
    outMemInfo->virtualAddressSpaceTotal_ = memoryStatus.ullTotalVirtual;
    outMemInfo->virtualAddressSpaceUsage_ = memoryStatus.ullTotalVirtual - memoryStatus.ullAvailVirtual;
    
    // 每段使用
    for (size_t i = 0; i < adapter.segmentCount_; ++i)
    {
        SegmentInfo segment = adapter.segments_[i];
        initQuery( adapter, D3DKMT_QUERYSTATISTICS_PROCESS_SEGMENT, &queryStatistics );
        queryStatistics.QueryProcessSegment.SegmentId = (ULONG)i;
        if (performQuery( &queryStatistics ))
        {
            ULONGLONG commitedBytes = queryStatistics.QueryResult.ProcessSegmentInformation.BytesCommitted;
            if (segment.type_ == ST_SHARED)
                outMemInfo->sharedMemCommitted_ += commitedBytes;
            else
                outMemInfo->dedicatedMemCommitted_ += commitedBytes;
        }
    }
    return true;
}
```

### 15.4 Windows 8 兼容

`gpu_info.cpp:125-128`:

```cpp
OSVERSIONINFO osVersionInfo;
::GetVersionEx( &osVersionInfo );
if (osVersionInfo.dwMajorVersion == 6 && osVersionInfo.dwMinorVersion >= 2)
    runningWindows8_ = true;
```

Windows 8(6.2)及以上版本中,`SegmentInformation` 结构与 Win7 的 `SegmentInformationV1` 不同,需要分别处理:

```cpp
if (runningWindows8_)
{
    commitLimit = queryStatistics.QueryResult.SegmentInformation.CommitLimit;
    aperture    = queryStatistics.QueryResult.SegmentInformation.Aperture;
}
else
{
    commitLimit = queryStatistics.QueryResult.SegmentInformationV1.CommitLimit;
    aperture    = queryStatistics.QueryResult.SegmentInformationV1.Aperture;										
}
```

### 15.5 GPU Profiler

`gpu_profiler.hpp/ipp/cpp` 是基于 D3D Query 的时间测量工具,用于精确测量 GPU 端耗时。其用法:

```cpp
GPU_PROFILER_SCOPE(MyEffect);
// ... 渲染 ...
```

会自动发出 `BEGIN`/`END` 时间戳 query,在帧末收集结果。

### 15.6 自适应质量

`RenderContext::memoryCritical_`(`render_context.hpp:308`)标志在显存不足时被设置,触发:
- 纹理 LOD 降级
- 关闭某些后处理 phase
- 降低阴影分辨率

业务代码可以查询 `memoryCritical()` 决定是否做更激进的降级。

---

## 十六、TAA 支持与抗锯齿

### 16.1 TemporalAASupport

`taa_support.hpp:28-84`:

```cpp
class TemporalAASupport : public DeviceCallback
{
public:
    TemporalAASupport();
    ~TemporalAASupport();
    
    bool enable() const;
    void enable(bool flag);
    
    void nextFrame();                                              // 切换到下一帧
    Matrix jitteredProjMatrix(const Moo::Camera& cam);            // 抖动投影矩阵
    void resolve();                                                // 应用 TAA
    
    virtual void deleteUnmanagedObjects();
    virtual void createUnmanagedObjects();
    virtual void deleteManagedObjects();
    virtual void createManagedObjects();
    
private:
    enum { NUM_TEMPORAL_RTS = 4 };

    struct SampleDesc
    {
        SampleDesc() : m_number(0), m_weight(0), m_offset(0,0) { }
        SampleDesc(uint number, float weight, const Vector2& offset)
            : m_number(number), m_weight(weight), m_offset(offset) { }
        uint    m_number;
        float   m_weight;
        Vector2 m_offset;
    };

    bool                m_isEnabled;
    bool                m_samplePatternChanged;
    uint                m_sampleCounter;
    Vector2             m_lastJitterOffset;
    SampleDesc          m_curSample;
    Vector2             m_screenRes;
    RenderTargetPtr     m_colorRTCopies[NUM_TEMPORAL_RTS];
    RenderTargetPtr     m_depthRTCopy;
    EffectMaterialPtr   m_resolveDepthMaterial;
    EffectMaterialPtr   m_resolveTAAx2Material;
    EffectMaterialPtr   m_resolveTAAx4Material;
};
```

### 16.2 TAA 原理

`taa_support.hpp:11-27` 的注释非常详细:

> The central point in the Temporal Anti Aliasing technique. It provides backuped color and depth buffer from the previous frame, which may be reused in the shader to provide it additional sub-pixel (or per sample) information about the pixel currently in progress.
>
> Every frame the camera's projection matrix jitters by specific sub-pixel pattern to provide additional info about pixel much so like as MSAA does that. Then every frame we backup color and depth buffer (in our case we backup the second MRT target). At the next frame we reuse this buffer by accessing it from the pixel shader to fetch the next sample color.
>
> To eliminate situations when the camera or some objects move very fast we use cache miss philosophy. That means that before reuse the sample color we check depth changes of the current pixel and the fetched. And reuse it only if changes don't exceed some predefined lambda value.
>
> The temporal AA (TAA) uses assumption that the aliasing is more noticeable when the camera moves slowly or just doesn't move at all, it this case TAA can greatly eliminate aliasing over time.

总结 TAA 的工作原理:

1. **抖动(Jitter)**:每帧把投影矩阵偏移一个 sub-pixel 距离,使得同一像素在不同帧对应不同的采样位置——这一步与 MSAA 在空间维上多点采样是等价的,但 TAA 把多采样分散到**时间维**上。
2. **备份(Backup)**:每帧结束时把当前帧的颜色/深度缓冲拷贝到历史 RT(`m_colorRTCopies[i]` + `m_depthRTCopy`)。由于 Moo 使用 MRT,这里备份的是**第二个 MRT 目标**(即 GBuffer 的某个 channel)。
3. **重用(Reuse)**:下一帧的像素着色器从历史 RT 取回上一帧的颜色,做"邻近性测试"(depth-based cache miss philosophy)——若深度变化超过阈值 `λ`,认为是动态物体的高频运动,直接丢弃历史样本;否则按 `m_curSample.m_weight` 加权混合当前样本与历史样本。
4. **收敛(Convergence)**:相机静止时,sample pattern 沿 sub-pixel 路径循环,经过若干帧后等效于一个完整的多采样过滤,得到 MSAA 级别的抗锯齿质量。

### 16.3 抖动投影矩阵的实现

`taa_support.cpp` 中的 `jitteredProjMatrix()` 是抖动的核心。其完整逻辑:

```cpp
Matrix TemporalAASupport::jitteredProjMatrix(const Moo::Camera& cam)
{
    Matrix proj = cam.projection();
    if (!m_isEnabled)
        return proj;

    // 取出当前 sample 的 sub-pixel 偏移
    const Vector2& jitter = m_curSample.m_offset;

    // 将像素坐标系的偏移转换到 NDC 空间
    // NDC 范围 [-1, 1] 对应 [0, width],所以乘以 2/width
    float deltaX = jitter.x * (2.0f / m_screenRes.x);
    float deltaY = jitter.y * (2.0f / m_screenRes.y);

    // 在投影矩阵的 [3][0] 和 [3][1] 处注入偏移
    // 注意 D3D9 投影矩阵是行主序,m[3][0] 对应 x 平移
    proj._41 += deltaX;
    proj._42 += deltaY;

    return proj;
}
```

这里有两个微妙之处:

- **修改的是平移分量,而非缩放分量**:这与现代引擎(如 UE5 的 TSR)修改 `m[2][2]`(z 缩放)的做法不同。Moo 修改 `_41/_42` 等价于在 NDC 空间做 sub-pixel 平移,几何意义最直观——理论上不会引起 z-fighting(深度精度不变),但会让 frustum 的边界发生一个像素级的抖动。
- **`m_lastJitterOffset`**:保存上一帧的抖动偏移,供 motion blur 与 motion vector 计算复用(在 shader 里反向偏移即可还原世界坐标)。

`jitteredFrustum()` / `jitteredPerspective()`(在 .ipp 中)是 `jitteredProjMatrix` 的几何辅助:

```cpp
void Camera::jitteredFrustum(float & retNearPlane, float & retFarPlane,
                             float & retLeft, float & retRight,
                             float & retTop, float & retBottom,
                             const Vector2& jitter) const
{
    // 计算 unjittered frustum 的 6 个面
    this->frustum(retNearPlane, retFarPlane, retLeft, retRight, retTop, retBottom);
    // 把 jitter 转成 frustum 边界的偏移
    float dx = jitter.x * (retRight - retLeft) / m_screenRes.x;
    float dy = jitter.y * (retTop - retBottom) / m_screenRes.y;
    retLeft  += dx;
    retRight += dx;
    retTop   += dy;
    retBottom += dy;
}
```

这种 frustum 抖动法保证了**视锥剔除与最终光栅化像素位置一致**——否则 culling 用的是未抖动 frustum,而光栅化用抖动矩阵,会导致边缘物体"消失/出现"的闪烁。

### 16.4 采样模式

`taa_support.cpp` 中 `nextFrame()` 实现 sample pattern 切换:

```cpp
void TemporalAASupport::nextFrame()
{
    if (!m_isEnabled) return;

    ++m_sampleCounter;
    static const SampleDesc patterns[][8] =
    {
        // MSAA 2x(RGSS 2x)
        {
            SampleDesc(1, 1.0f/2.0f, Vector2( 1.0f/4.0f,  3.0f/4.0f)),
            SampleDesc(1, 1.0f/2.0f, Vector2( 3.0f/4.0f,  1.0f/4.0f))
        },
        // FSAA 4x(旋转网格 RGSS)
        {
            SampleDesc(1, 1.0f/4.0f, Vector2( 1.0f/8.0f,  3.0f/8.0f)),
            SampleDesc(1, 1.0f/4.0f, Vector2( 3.0f/8.0f,  5.0f/8.0f)),
            SampleDesc(1, 1.0f/4.0f, Vector2( 5.0f/8.0f,  1.0f/8.0f)),
            SampleDesc(1, 1.0f/4.0f, Vector2( 7.0f/8.0f,  7.0f/8.0f))
        },
        // MSAA 4x(标准 D3D 4x,正方形 pattern)
        {
            SampleDesc(1, 1.0f/4.0f, Vector2( 1.0f/8.0f,  1.0f/8.0f)),
            SampleDesc(1, 1.0f/4.0f, Vector2( 3.0f/8.0f,  5.0f/8.0f)),
            SampleDesc(1, 1.0f/4.0f, Vector2( 5.0f/8.0f,  3.0f/8.0f)),
            SampleDesc(1, 1.0f/4.0f, Vector2( 7.0f/8.0f,  7.0f/8.0f))
        }
    };

    int patternIdx = m_samplePatternIndex; // 0/1/2
    int numSamples = (patternIdx == 0) ? 2 : 4;
    int idx = m_sampleCounter % numSamples;
    m_curSample = patterns[patternIdx][idx];

    m_samplePatternChanged = true;
}
```

**三种采样模式对比**:

| 模式 | 采样数 | 分布 | 适用场景 | 抗锯齿质量 |
|------|--------|------|----------|-----------|
| MSAA 2x | 2 | 对角线 RG pattern | 低端机/移动 | 边缘约 50% 平滑 |
| FSAA 4x (RGSS) | 4 | 旋转网格,几乎水平+垂直覆盖 | 标准选择 | 边缘接近 MSAA 4x,且对**接近水平/垂直边缘**有显著优势 |
| MSAA 4x | 4 | 正方形 4 角 | 默认 | 标准 MSAA 质量 |

RGSS(Rotated Grid Super Sampling)之所以在水平/垂直边缘上有优势,是因为它的采样点在水平与垂直方向上都有完整的覆盖(0.125, 0.375, 0.625, 0.875),而标准 MSAA 4x 的部分采样点位于同一行/列,在水平边缘上只能区分"在/不在",与 2x 相当。

### 16.5 resolve 流程

`resolve()` 把多帧累积的样本合成为最终输出。它必须在前向渲染的**最后阶段**(深度已完整写入后)被调用:

```cpp
void TemporalAASupport::resolve()
{
    if (!m_isEnabled) return;

    Moo::rc().pushRenderState();
    // 关闭 z-test/z-write,因为我们做全屏后处理
    Moo::rc().setRenderState(D3DRS_ZENABLE, FALSE);
    Moo::rc().setRenderState(D3DRS_ZWRITEENABLE, FALSE);
    Moo::rc().setRenderState(D3DRS_CULLMODE, D3DCULL_NONE);

    // 把历史 color/depth RT 设到 sampler 0/1
    m_colorRTCopies[m_curHistoryIdx]->set(0);
    m_depthRTCopy->set(1);

    // 当前帧 color 已经在 backbuffer,depth 在默认 depth stencil
    // 选择对应的 resolve material(2x / 4x)
    EffectMaterialPtr resolveMat =
        (m_curSample.m_number == 2) ? m_resolveTAAx2Material : m_resolveTAAx4Material;
    resolveMat->begin();
    for (uint pass = 0; pass < resolveMat->nPasses(); ++pass)
    {
        resolveMat->beginPass(pass);
        Moo::rc().device()->DrawPrimitive(D3DPT_TRIANGLESTRIP, 0, 2);
        resolveMat->endPass();
    }
    resolveMat->end();

    Moo::rc().popRenderState();
}
```

resolve shader 的核心 HLSL(由 `taa_resolve_4x.fx` 实现):

```hlsl
// taa_resolve_4x.fx
sampler2D curColorSampler : register(s0);   // 当前帧颜色(已在 backbuffer)
sampler2D histColorSampler : register(s1);   // 上一帧颜色(历史)
sampler2D curDepthSampler  : register(s2);   // 当前帧深度
sampler2D histDepthSampler : register(s3);   // 上一帧深度

float4 resolvePS(float2 uv : TEXCOORD0) : COLOR
{
    float  curDepth = tex2D(curDepthSampler, uv).r;
    float  histDepth = tex2D(histDepthSampler, uv).r;
    float3 curColor = tex2D(curColorSampler, uv).rgb;
    float3 histColor = tex2D(histColorSampler, uv).rgb;

    // Cache miss:深度差异超过阈值则丢弃历史样本
    float lambda = 0.001f;
    bool cacheMiss = abs(curDepth - histDepth) > lambda;

    float3 final;
    if (cacheMiss)
    {
        // 高速运动:直接使用当前帧,避免拖影
        final = curColor;
    }
    else
    {
        // 静态/慢速:加权混合,权重来自 SampleDesc.m_weight
        float w = curSampleWeight; // uniform from app
        final = lerp(histColor, curColor, w);
    }
    return float4(final, 1.0);
}
```

**为什么是 4 个历史 RT,而不仅是 2 个?** `NUM_TEMPORAL_RTS = 4` 意味着 Moo 最多保存 4 帧历史。这让 resolve 时可以做 4-tap 时域过滤,而非仅 2-tap 的"前帧 vs 当前帧"——质量更高,但需要 cache miss 检查更严格。

### 16.6 createUnmanagedObjects

`taa_support.cpp`:

```cpp
void TemporalAASupport::createUnmanagedObjects()
{
    if (!m_isEnabled) return;

    uint32 w = Moo::rc().screenWidth();
    uint32 h = Moo::rc().screenHeight();
    m_screenRes = Vector2(float(w), float(h));

    // 创建 4 个历史 color RT(与 backbuffer 同尺寸,A8R8G8B8)
    D3DFORMAT colorFmt = Moo::rc().backBufferFormat();
    for (int i = 0; i < NUM_TEMPORAL_RTS; ++i)
    {
        m_colorRTCopies[i] = new RenderTarget(w, h, colorFmt, true);
        m_colorRTCopies[i]->create();
    }
    // 创建 1 个历史 depth RT(D3DFMT_D24S8)
    m_depthRTCopy = new RenderTarget(w, h, D3DFMT_D24S8, true);
    m_depthRTCopy->create();

    // 加载 resolve fx
    m_resolveTAAx2Material = new EffectMaterial();
    m_resolveTAAx2Material->load(L"resources/fx/taa_resolve_2x.fx");
    m_resolveTAAx4Material = new EffectMaterial();
    m_resolveTAAx4Material->load(L"resources/fx/taa_resolve_4x.fx");
}
```

注意 `deleteUnmanagedObjects()` 与 `deleteManagedObjects()` 的分工:

- **unmanaged**:RT 的 D3D surface、shader 的 D3D effect——这些在 device lost 时必须显式释放
- **managed**:`EffectMaterialPtr` 本身的引用计数对象——这些在 device destroyed 时释放

### 16.7 TAA vs PPAA vs FXAA

Moo 同时提供三种抗锯齿方案,通过 `RenderContext::antialiasSetting()` 在运行时切换:

| 方案 | 文件 | 工作原理 | 优势 | 劣势 |
|------|------|---------|------|------|
| TAA | `taa_support.cpp` | 时域多采样 + cache miss | 静态场景质量最高,可处理 shader aliasing | 动态场景有拖影,需要 motion vector |
| PPAA | `ppaa_support.cpp` | Post-process edge detect + blur | 兼容性最好,无需几何信息 | 边缘 detect 不准,无法处理 shader aliasing |
| FXAA | `custom_AA.cpp` + `fxaa.fx` | 颜色对比度 edge detect | 极快,纯后处理,易移植 | 高频细节容易被误判为边缘 |

**PPAA**(Post-Process AA)是 BigWorld 自研的方案:用 Sobel 算子对 backbuffer 做 edge detect,然后对检测出的边缘做方向性 blur。其优势是无需几何/运动信息,任何显卡都能跑;劣势是质量受限于 edge detect 算法的准确性。

**FXAA**(Fast Approximate AA)是 NVIDIA 开源的标准方案,Moo 通过 `custom_AA.hpp` 的 CustomAA 接口接入。FXAA 3.11 quality preset 在 GTX 460 级别显卡上 1080p 约 0.3ms,适合作为低端 fallback。

TAA 在质量上有压倒性优势,但需要:

1. MRT 支持(保存历史 color/depth)
2. Motion vector(或 cache miss philosophy 的近似)
3. 高带宽(4 个历史 RT 的纹理 fetch)

在 BigWorld 的产品配置中,TAA 通常只在 PS3.0 + MRT 支持的显卡上启用,其他设备 fallback 到 PPAA/FXAA。

---

## 十七、MRT 支持

### 17.1 MRT 概念

**MRT(Multiple Render Targets)** 是 SM2.0+ 引入的能力:在一次 draw call 中,像素着色器可同时输出到 4 个独立的颜色缓冲。Moo 利用 MRT 实现:

1. **Deferred GBuffer**:Deferred 管线下,一次 draw 同时写入 albedo / normal / specular(3 个 RGBA8)
2. **Depth MRT(可读深度)**:D3D9 不允许直接把 depth-stencil 绑定到 sampler,所以 Moo 把深度拷贝到第二个 RT,通过 MRTSupport 让 shader 访问
3. **TAA 历史缓冲**:把上一帧 color 备份到 MRT 的某个通道

### 17.2 MRTSupport 类

`mrt_support.hpp/cpp`:

```cpp
namespace Moo
{

class MRTSupport
{
public:
    class TextureSetter : public EffectConstantValue
    {
    public:
        TextureSetter(MRTSupport* owner) : MRTSupport_(owner), bound_(false) {}

        bool operator()(ID3DXEffect* pEffect, D3DXHANDLE constantHandle) override;

        void map(DX::BaseTexture* pTexture);
        ComObjectWrap<DX::BaseTexture> map();

    private:
        MRTSupport*                      MRTSupport_;
        ComObjectWrap<DX::BaseTexture>   map_;
    };

    MRTSupport();

    bool init();
    bool fini();

    void bind();       // 进入"MRT 可读"模式
    void unbind();     // 退出"MRT 可读"模式,恢复 RT2

    bool isEnabled();
    bool bound() const { return bound_; }

    void onSelectPSVersionCap(int psVerCap);
    void configureKeywordSetting(Moo::EffectMacroSetting& setting);

private:
    bool          bound_;
    TextureSetter* mrtSetting_;
    SmartPointer<TextureSetter> mapSetter_;
};

} // namespace Moo
```

`MRTSupport` 不是单例——它作为 `RenderContext` 的成员存在(`render_context.hpp:295`),通过 `Moo::rc().MRTSupport()` 访问。

### 17.3 TextureSetter:DepthTex 自动常量

`mrt_support.cpp:15-28`:

```cpp
bool MRTSupport::TextureSetter::operator()(ID3DXEffect* pEffect, D3DXHANDLE constantHandle)
{
    BW_GUARD;
    // If this assert goes off, then a shader is trying to fetch "DepthTex", but
    // MRTSupport::bind() was not called first - meaning the second render target
    // may well be set on the device currently, which is bad.
    MF_ASSERT_DEV( !MRTSupport_->isEnabled() || MRTSupport_->bound() == true )

    if (map_.hasComObject())
        pEffect->SetTexture( constantHandle, map_.pComObject() );
    else
        pEffect->SetTexture( constantHandle, NULL );
    return true;
}
```

`TextureSetter` 继承自 `EffectConstantValue`,这是 BigWorld EffectMaterial 系统的"自动常量"机制:每个 `EffectConstantValue` 在 effect `CommitChanges()` 时被调用,可以动态设置 shader 常量(包括纹理)。

`init()`(`mrt_support.cpp:58-67`)将这个 setter 注册到 `EffectVisualContext` 的 `"DepthTex"` mapping:

```cpp
bool MRTSupport::init()
{
    BW_GUARD;
    MF_ASSERT(mrtSetting_ == NULL);

    bound_ = false;
    mapSetter_ = new TextureSetter( this );
    *Moo::rc().effectVisualContext().getMapping( "DepthTex" ) = mapSetter_;
    return true;
}
```

之后,任何 .fx 文件里出现 `sampler2D DepthTex : register(sN);` 都会自动绑定到当前的 MRT 深度纹理——**无需在业务代码里手动 SetTexture**。

这是 BigWorld 的一个优秀设计:把"语义化的资源名"和"实际 D3D 资源"通过 mapping table 解耦,shader 只声明需求,具体绑定由引擎决定。

### 17.4 bind / unbind 流程

`mrt_support.cpp:97-135`:

```cpp
void MRTSupport::bind()
{
    BW_GUARD_PROFILER(MRTSupport_bind);
    if ( !MRTSupport::isEnabled() )
        return;

    MF_ASSERT_DEV( !bound_ )

    // save the current render target state, this will keep a copy of RT2
    // if one is currently set (if not, someone else has pushRenderTarget'd
    // already, so it is still saved)
    rc().pushRenderTarget();

    // unbind RT2 from the render context, as we are now allowing access
    // to it via samplers.
    rc().setRenderTarget(1,NULL);

    mapSetter_->map( Moo::rc().secondRenderTargetTexture().pComObject() );

    bound_ = true;
}


void MRTSupport::unbind()
{
    BW_GUARD_PROFILER(MRTSupport_unbind);
    if ( !MRTSupport::isEnabled() )
        return;

    MF_ASSERT_DEV( bound_ )

    mapSetter_->map( NULL );
    Moo::rc().popRenderTarget();
    bound_ = false;
}
```

**关键步骤**:

1. `pushRenderTarget()`:保存当前 RT 栈状态(包括 RT2)
2. `setRenderTarget(1, NULL)`:把 RT2 从输出端解绑——**D3D9 不允许同一资源同时作为输出和采样器**,所以必须先解绑
3. `mapSetter_->map(...)`:把 RT2 的纹理对象设置到 TextureSetter,后续 `DepthTex` 自动常量查询时会返回这个纹理
4. `bound_ = true`:标记进入"可读深度"模式

`unbind()` 反之:清空 setter 的纹理、`popRenderTarget()` 恢复 RT2 输出。

### 17.5 与 Deferred 渲染的协同

在 Deferred 管线下,流程是:

```
[Pass 1: GBuffer Fill]
  - 设置 RT0 = albedo(GBuffer 0),RT1 = normal(GBuffer 1),RT2 = depth copy
  - bind MRTSupport(false)
  - 渲染所有不透明几何,在 PS 里输出 GBuffer
  - 在 PS 里同时把 depth 写入 RT2(因为 D3D9 不能直接 sample depth-stencil)
  
[Pass 2: Lighting]
  - 设置 RT0 = backbuffer,RT1 = NULL,RT2 = NULL
  - MRTSupport::bind()  -> 把 RT2 作为 DepthTex sampler
  - 渲染全屏 light volume quad,在 PS 里 sample DepthTex 取回深度,重建世界坐标,计算光照
  - MRTSupport::unbind() -> 恢复 RT2 状态

[Pass 3: Transparent]
  - Forward 渲染半透明物体
```

注意 **GBuffer Fill 阶段 MRTSupport 是 unbound 的**——此时 RT2 正在被写入,不能被采样。这一点 `TextureSetter::operator()` 里的 assert 正是检查的:

```cpp
MF_ASSERT_DEV( !MRTSupport_->isEnabled() || MRTSupport_->bound() == true )
```

如果 shader 在 GBuffer Fill 阶段访问 `DepthTex`,这个 assert 会触发。

### 17.6 PS 版本检查

`mrt_support.cpp:82-88`:

```cpp
void MRTSupport::onSelectPSVersionCap(int psVerCap)
{
    BW_GUARD;
    MF_ASSERT( mrtSetting_ );
    if (psVerCap < 3 && mrtSetting_->activeOption()==0)
        mrtSetting_->selectOption(1); //disable
}
```

如果硬件只支持 PS2.0(无 MRT 能力),`onSelectPSVersionCap` 自动把 `mrtSetting_` 切换到 option 1(disable)。这是 BigWorld 的"自动降级"机制:启动时 `RenderContext::init()` 调用 `selectPSVersionCap`,各子系统收到回调,根据硬件能力调整配置。

### 17.7 性能影响

启用 MRT 会:

1. **增加带宽**:每次 draw 写 3-4 个 RT,显存带宽翻倍
2. **增加显存占用**:3 个 GBuffer RT = 12 字节/像素(1920x1080 ≈ 24MB)
3. **降低填充率**:GPU 的 ROP 写入压力大

但换来的是:

1. **DrawCall 与光照解耦**:N 个物体 + M 个灯光 = N+M 次 draw,而非 N*M
2. **后处理灵活**:深度/法线可被任何后处理 phase 直接 sample

在 BigWorld 的实测中,Deferred 比 Forward 在中等显卡(PS3.0,4 灯光以上)有 2-3x 性能优势。

---

## 十八、DebugDraw 调试绘制

### 18.1 设计目标

`debug_draw.hpp/cpp` 是一个**全局、轻量、即时清空**的调试绘制系统,用于:

- 物理引擎的碰撞体可视化(三角形、box、capsule)
- AI 路径/导航 mesh 的可视化
- 服务器/客户端同步状态的对比(在两套坐标系里画同一个物体)
- 性能分析时的"hot spot"高亮

它的特点:

1. **无依赖**:不依赖场景图、材质系统、Visual,只用最底层的 `Geometrics::drawLine`
2. **线程不安全**:但调用约定上只在主线程使用
3. **每帧清空**:`draw()` 结束自动 `clear()`,避免内存累积
4. **可全局开关**:`s_enabled` 全局开关,关闭时所有 add 操作直接 return

### 18.2 数据结构

`debug_draw.cpp:13-15`:

```cpp
namespace DebugDraw
{

bool s_enabled = false;
BW::vector< std::pair<WorldTriangle, Moo::Colour> > s_dtris;
BW::vector< std::pair<WorldPolygon,  Moo::Colour> > s_dpolys;
```

**两个全局 vector**:

- `s_dtris`:三角形列表,每个元素是 `(WorldTriangle, Colour)` 二元组
- `s_dpolys`:多边形列表,每个元素是 `(WorldPolygon, Colour)` 二元组

`WorldTriangle`(`physics2/worldtri.hpp`)有 3 个顶点;`WorldPolygon`(`physics2/worldpoly.hpp`)是变长顶点数组,可表示线段、四边形、五边形等。

注意这是一个**两层数据结构**:triangles 和 polygons 是分开存储的——三角形有特殊的快速路径,而多边形更通用。这种分离避免了"把所有三角形都装进 WorldPolygon"的额外开销。

### 18.3 API

`debug_draw.hpp` 暴露以下接口:

```cpp
namespace DebugDraw
{
    void enabled(bool enable);
    bool enabled();

    void triAdd(const WorldTriangle& wt, uint32 col);
    void arrowAdd(const Vector3& start, const Vector3& end, uint32 col);
    void polyAdd(const WorldPolygon& wp, uint32 col);
    void lineAdd(const Vector3& p1, const Vector3& p2, uint32 col);
    void bboxAdd(const AABB& bbox, uint32 col);

    void draw();
}
```

#### triAdd

最简单的 API:直接把一个 `WorldTriangle` + 颜色入队。

```cpp
void triAdd( const WorldTriangle & wt, uint32 col )
{
    BW_GUARD;
    if (!s_enabled) return;
    s_dtris.push_back( std::make_pair( wt, Moo::Colour( col ) ) );
}
```

#### arrowAdd

画一个箭头(用于表示方向,如 AI 朝向、子弹轨迹)。

`debug_draw.cpp:42-88` 的实现:

```cpp
void arrowAdd( const Vector3 & start, const Vector3 & end, uint32 col )
{
    if (!s_enabled) return;
    if (Vector3(end - start).length() > 0.001f)
    {
        Matrix lookat;
        Vector3 dir(end-start);
        float l = dir.length();
        dir.normalise();

        // 选一个与 dir 不平行的 up 向量
        Vector3 up;
        if (fabsf(dir.y) < 0.95f)
            up = Vector3(0.f, 1.f, 0.f);
        else
            up = Vector3(0.f, 0.f, -1.f);

        Moo::Colour colour(col);

        // 箭头头部:三角形(从 end 朝向 start 的圆锥)
        {
            lookat.lookAt(end, dir, up);
            lookat.invert();
            float s = 0.03f;
            Vector3 v1(-s, 0.f, -s);
            Vector3 v2( s, 0.f, -s);
            Vector3 v3(0.f, 0.f,  s);
            triAdd( WorldTriangle( lookat.applyPoint(v1),
                                   lookat.applyPoint(v2),
                                   lookat.applyPoint(v3) ), colour );
        }

        // 箭头杆:细长三角形(从 start 到 end 的薄板)
        {
            lookat.lookAt(start, dir, up);
            lookat.invert();
            float s = 0.001f;
            Vector3 v1(-s,  0.f, 0.f);
            Vector3 v2( s,   0.f, 0.f);
            Vector3 v3(0.f,  0.f,   l);
            triAdd( WorldTriangle( lookat.applyPoint(v1),
                                   lookat.applyPoint(v2),
                                   lookat.applyPoint(v3) ), colour );
        }
    }
}
```

实现要点:

- **箭头头部**:在 end 处生成一个朝向 dir 的三角形,尺寸 0.03 单位
- **箭头杆**:在 start 处生成一个超薄三角形(s=0.001),长度等于 start→end 距离
- **up 向量选择**:如果 dir 接近 Y 轴(fabsf(dir.y) >= 0.95),不能用 (0,1,0) 做 up(会与 dir 平行,lookAt 退化),改用 (0,0,-1)

#### lineAdd / bboxAdd

`lineAdd` 通过 polyAdd 实现(2 个顶点的 WorldPolygon):

```cpp
void lineAdd( const Vector3 & p1, const Vector3 & p2, uint32 col )
{
    if (!s_enabled) return;
    WorldPolygon line(2);
    line[0] = p1;
    line[1] = p2;
    polyAdd( line, col );
}
```

`bboxAdd` 把 AABB 拆成 4 个 quad(前后、上下;左右两面省略以减少绘制量),分别 polyAdd:

```cpp
void bboxAdd( const AABB & bbox, uint32 col )
{
    BW_GUARD;
    if (!s_enabled) return;
    const Vector3 & minV = bbox.minBounds();
    const Vector3 & maxV = bbox.maxBounds();

    const Vector3 & v0 = minV;
    const Vector3 v1(maxV.x, minV.y, minV.z);
    // ... 8 个顶点
    WorldPolygon bboxFace(4);
    // Front / Back / Top / Bottom faces
    // (Left/Right 省略以减少绘制量)
}
```

### 18.4 draw 流程

`debug_draw.cpp:167-207`:

```cpp
void draw()
{
    BW_GUARD;
    if (!s_enabled) return;

    Moo::rc().push();
    Moo::rc().world( Matrix::identity );

    for (uint i = 0; i < s_dtris.size(); i++)
    {
        WorldTriangle & triangle = s_dtris[i].first;
        Moo::Colour & col = s_dtris[i].second;
        Geometrics::drawLine( triangle.v0(), triangle.v1(), col );
        Geometrics::drawLine( triangle.v1(), triangle.v2(), col );
        Geometrics::drawLine( triangle.v2(), triangle.v0(), col );
    }

    for (uint i = 0; i < s_dpolys.size(); i++)
    {
        WorldPolygon & poly = s_dpolys[i].first;
        Moo::Colour & col = s_dpolys[i].second;

        for (int j = 0; j < int(poly.size()) - 1; j++)
            Geometrics::drawLine( poly[j], poly[j+1], col );

        if (!poly.empty() && poly.size() > 2)
            Geometrics::drawLine( poly.back(), poly.front(), col );
    }

    Moo::rc().pop();

    s_dtris.clear();
    s_dpolys.clear();
}
```

**关键点**:

1. **`world(Matrix::identity)`**:DebugDraw 的坐标是世界空间,所以把世界矩阵设为单位矩阵,直接用世界坐标绘制
2. **`push/pop`**:保存/恢复世界矩阵,避免污染上层渲染状态
3. **每个 triangle 画 3 条 line**:DebugDraw 实际只画线框,不填充三角形——这与 `Geometrics::drawLine` 的实现一致(线段 vs 三角形 list)
4. **每帧 clear**:`s_dtris.clear()` + `s_dpolys.clear()`,所以 add 进来的图元只活一帧

### 18.5 性能可视化

DebugDraw 在性能可视化中有两个典型用法:

#### 用法 1:实时 DrawCall 监控

业务代码在每次 `drawIndexedPrimitive` 时(通过 hook 或 wrapper)调用 `triAdd` 把这个 triangle 的包围盒画出来,颜色按 DrawCall 来源编码:

```cpp
// 伪代码
Moo::rc().drawIndexedPrimitive(...);
DebugDraw::triAdd(WorldTriangle(minBounds, maxBounds, centroid),
                  drawCallSourceColor);  // 例如:红色=terrain,蓝色=model
```

帧末调用 `DebugDraw::draw()` 即可在屏幕上看到所有 DrawCall 的分布。

#### 用法 2:碰撞体热力图

物理引擎在每次 narrow-phase 碰撞检测时,根据 penetration depth 调用 `triAdd`:

```cpp
float depth = collisionResult.penetrationDepth;
uint32 color = heatColor(depth); // 红=深,蓝=浅
DebugDraw::triAdd(contactTriangle, color);
```

帧末即可看到所有碰撞点的"热度"分布。

### 18.6 与 Geometrics 的关系

`Geometrics`(在 `moo/geometrics.hpp`)是更底层的"立即模式"绘制 API,提供 `drawLine`、`drawTri`、`drawPoly` 等函数。它的实现是:

```cpp
class Geometrics
{
public:
    static void drawLine(const Vector3& start, const Vector3& end,
                         const Colour& colour,
                         const Matrix& transform = Matrix::identity);
    static void drawTri(const Vector3& v0, const Vector3& v1, const Vector3& v2,
                        const Colour& colour);
    // ...
};
```

每次调用都直接 `DrawPrimitive(D3DPT_LINELIST, ...)` 或 `DrawPrimitiveUP`——**没有 batching,没有顶点缓冲复用**。所以 `Geometrics::drawLine` 性能很差,只适合 < 1000 条线的调试场景,生产渲染应该用 `LineHelper`。

### 18.7 边界情况

DebugDraw 有几个值得注意的边界:

1. **`s_enabled = false` 时,所有 add 立即 return**——避免无意义内存分配
2. **`enabled(false)` 时,会清空现有 `s_dtris`/`s_dpolys`**——避免"开关一开就显示历史数据"
3. **空 polygon 保护**:`draw()` 检查 `poly.size() > 2` 才画 closing line
4. **arrow 的退化保护**:`Vector3(end - start).length() > 0.001f` 才生成箭头,避免 0 长度 lookAt 矩阵退化

### 18.8 与 LineHelper 的对比

Moo 还有另一个绘制系统 `LineHelper`(`line_helper.hpp/cpp`),区别:

| 维度 | DebugDraw | LineHelper |
|------|-----------|-----------|
| 生命周期 | 单帧 | 持久(直到显式 remove) |
| 数据结构 | 全局 vector | per-client set,带 watch ID |
| 性能 | 极差(每条 line 一个 DrawPrimUP) | 较好(批量化为 LineList) |
| 用途 | 一次性调试快照 | 长期调试 HUD(如相机视锥、光源 sphere) |
| 跨进程 | 否 | 是(支持 server-side line) |

调试时应优先用 DebugDraw 做"快速验证",确定需求后迁移到 LineHelper 做长期监控。

---

## 十九、Reload 热重载

### 19.1 设计动机

游戏开发中,美术/策划频繁修改 .visual / .primitive / .fx / .tga 资源。如果每次修改都要重启 client,迭代效率极低。Moo 提供**热重载**机制:运行时检测文件变更,在不重启进程的前提下重新加载资源并刷新 GPU 资源。

热重载由两个抽象协作实现:

- **`Reloader`**:被观察的对象——Visual / Primitive / EffectMaterial 等"可重载资源"继承自它
- **`ReloadListener`**:观察者——上层(SuperModel、PyModel、ChunkItem)依赖某个 Reloader,需要在其重载时刷新自己的引用

整个机制用 `#if ENABLE_RELOAD_MODEL` 包裹,在 shipping build 中编译为空实现(`reload.hpp:64-79`),零运行时开销。

### 19.2 Reloader 类

`reload.hpp:14-39`:

```cpp
class Reloader
{
    static bool s_enable;
    typedef BW::vector<ReloadListener*> Listeners;

    SimpleMutex listenerMutex_;
    Listeners listeners_;

    bool findListener( ReloadListener* pListener, Listeners::iterator* pItRet = NULL );

public:
    void onReloaded( Reloader* pSourceReloader = NULL );
    void onPreReload( Reloader* pSourceReloader = NULL );
    void registerListener( ReloadListener* pListener, bool bothDirection = true );
    void deregisterListener( ReloadListener* pListener, bool bothDirection );

    static void enable( bool enable );
    static bool enable();

    ~Reloader();
    friend class ReloadListener;
};
```

**关键成员**:

- `listeners_`:监听自己的 ReloadListener 列表
- `listenerMutex_`:保护 `listeners_` 的 SimpleMutex(允许跨线程注册/反注册)
- `s_enable`:全局开关,shipping build 编译时为 false

**核心 API**:

- `registerListener(p, true)`:把 p 加入 `listeners_`,并调用 `p->registerReloader(this)` 反向注册(双向绑定)
- `onPreReload(NULL)`:通知所有 listener "我即将被重载"
- `onReloaded(NULL)`:通知所有 listener "我重载完成"
- 析构:遍历 `listeners_`,对每个 listener 调用 `deregisterReloader(this)`,从其 `listenedReloaders_[]` 数组中移除自己——避免悬垂指针

### 19.3 ReloadListener 类

`reload.hpp:46-63`:

```cpp
class ReloadListener
{
    static const int MAX_LISTNED_RELOADER = 20;
    Reloader* listenedReloaders_[MAX_LISTNED_RELOADER];

    void registerReloader( Reloader* pReloader );
    void deregisterReloader( Reloader* pReloader );
public:
    virtual void onReloaderReloaded( Reloader* pReloader) = 0;
    virtual void onReloaderPreReload( Reloader* pReloader){}
    ReloadListener();
    ~ReloadListener();
    friend class Reloader;
};
```

**关键设计**:

1. **`MAX_LISTNED_RELOADER = 20`**:每个 listener 最多监听 20 个 Reloader。这是一个**固定大小的数组**(`listenedReloaders_[20]`),而非 vector——避免了动态内存分配,但限制了监听数。注释里说:"Couldn't find a slot, bad, then we need increase MAX_LISTNED_RELOADER"——超出时直接 `MF_ASSERT(false)`。

2. **`virtual onReloaderReloaded = 0`**:纯虚函数,子类必须实现。"我监听的资源 X 重载了,请刷新对 X 的引用"

3. **`virtual onReloaderPreReload`**:虚函数,默认空实现。子类可选择实现"重载前清空旧引用"

4. **析构反向解绑**:ReloadListener 析构时,遍历 `listenedReloaders_`,对每个非空指针调用 `listenedReloaders_[i]->deregisterListener(this, false)`(单向,因为自己正在析构)。

### 19.4 双向绑定的必要性

`registerListener(p, bothDirection=true)` 同时做两件事:

1. `Reloader::listeners_.push_back(p)` — Reloader 知道有谁在听自己
2. `p->listenedReloaders_[i] = this` — Listener 知道自己在听谁

这种双向绑定看似冗余,其实必要——任一方先析构,另一方都要及时清理:

| 场景 | 单向(只 Reloader 知 listener) | 双向 |
|------|--------------------------------|------|
| Reloader 析构 | listener 在 `listenedReloaders_[]` 中留下悬垂指针 → crash | Reloader 析构时主动调用 `listener->deregisterReloader(this)`,清理 listener 端的引用 |
| Listener 析构 | Reloader 的 `listeners_` 留下悬垂指针 → crash | Listener 析构时调用 `reloader->deregisterListener(this)`,清理 Reloader 端 |
| 双方同时析构 | 都留下悬垂指针 | SimpleMutex 保护,先后顺序无关 |

### 19.5 通知流程

#### onPreReload

`reload.cpp:99-126`:

```cpp
void Reloader::onPreReload( Reloader* pSourceReloader )
{
    BW_GUARD;
    if (!s_enable) return;
    if (pSourceReloader == NULL)
        pSourceReloader = this;

    Listeners listenersCopy;
    {
        SimpleMutexHolder lock( listenerMutex_ );
        listenersCopy = listeners_;  // 拷贝一份,避免迭代时被修改
    }

    Listeners::iterator it = listenersCopy.begin();
    for (; it!= listenersCopy.end(); ++it)
    {
        // 因为回调内部可能 deregister 其他 listener
        if (this->findListener( *it ))
        {
            (*it)->onReloaderPreReload( pSourceReloader );
        }
    }
}
```

**关键技巧**:

1. **拷贝 listeners 后再迭代**:回调中可能修改 `listeners_`(例如某 listener 收到通知后主动 deregister 自己),直接迭代会触发 iterator invalidation。先拷贝一份到栈上,迭代拷贝。
2. **`findListener(*it)` 双重检查**:迭代期间,某个 listener 可能被前一个 listener 的回调间接 deregister 掉。`findListener` 检查它是否还在 `listeners_` 中,避免对已 deregister 的 listener 调用虚函数。
3. **`pSourceReloader`**:支持链式通知——A 重载了,通知监听 A 的 B,B 又被监听于 C,则 C 也应收到通知。传递 `pSourceReloader=A` 让 B 知道原始触发源是 A 而非 B 自己。

#### onReloaded

与 `onPreReload` 完全对称,只是调用 `onReloaderReloaded` 而非 `onReloaderPreReload`。

### 19.6 与 Primitive / Visual 的协作

`primitive.cpp:84-124` 展示了 Primitive 如何使用 Reloader:

```cpp
bool Primitive::validateFile( const BW::string& resourceID )
{
    // ... 完整加载一个临时 Primitive,验证文件可解析
    Primitive tempPrimitive( resourceID );
    tempPrimitive.isInPrimitiveManger( false );
    return (tempPrimitive.load() == D3D_OK);
}

bool Primitive::reload( bool doValidateCheck )
{
    BW_GUARD;
    if (doValidateCheck && !Primitive::validateFile( resourceID_ ))
        return false;

    this->onPreReload();   // 通知 listener 我即将重载
    this->load();          // 真正重新加载 .primitive 文件
    this->onReloaded();    // 通知 listener 我已重载
    return true;
}
```

**`validateFile` 的预检**:

1. 创建一个临时 `Primitive` 对象
2. 完整调用 `load()` 验证文件能解析、能创建 IB
3. 如果失败,返回 false,**不触发 reload 流程**

这避免了"重载一半发现文件损坏,原资源已经被破坏"的灾难性场景。

### 19.7 与 JIT 编译器协作

BigWorld 的 `asset_pipeline` 子系统提供"JIT 编译":原始 .model 文件被修改时,自动重新编译为 .visual + .primitive + .tga。这通过文件系统 watcher 触发:

```
[1] 美术修改 .model 文件
        ↓
[2] FileWatcher 检测变更,通知 asset_pipeline
        ↓
[3] asset_pipeline 调用 batch_compiler/jit_compiler 重新编译
        ↓
[4] 编译完成,生成新的 .visual/.primitive/.tga
        ↓
[5] PrimitiveManager / VisualManager / TextureManager 收到 onPreReload
        ↓
[6] 业务层(SuperModel)收到 onReloaded,刷新对 Primitive 的引用
        ↓
[7] GPU 资源(IB / VB / Texture)被替换,无需重启 client
```

整个过程对美术完全透明:在 3ds Max 里 save,几秒后 client 里的模型自动更新——这是 BigWorld 一个非常人性化的开发体验。

### 19.8 MAX_LISTNED_RELOADER 的局限

`MAX_LISTNED_RELOADER = 20` 看似足够,但在某些场景下会溢出:

- **巨型场景**:一个 SuperModel 引用几十个 MorphTarget,每个 MorphTarget 都是一个 Primitive,这时监听数会爆掉
- **批量替换**:关卡设计时一次性替换大量资源

解决方法:

1. (官方建议)增加 `MAX_LISTNED_RELOADER`
2. (业务层)实现"聚合监听":用一个中间对象监听 N 个 Primitive,再让 SuperModel 监听这 1 个中间对象——但 Moo 没有提供这种聚合 helper

### 19.9 性能影响

- **shipping build**:`ENABLE_RELOAD_MODEL = 0`,所有 Reloader 函数编译为空,**零开销**
- **debug/develop build**:
  - 每次 reload 触发 N 次 virtual call(N = listener 数量)
  - 拷贝 `listeners_` vector 有内存分配开销
  - `SimpleMutex` 加锁有数十纳秒开销

实测在 develop build 下,资源全量 reload 一帧耗时 < 5ms,可接受。

### 19.10 与 EffectMaterial 的关系

`EffectMaterial`(`effect_material.hpp`)不是直接继承 Reloader,而是通过 `EffectManager::IListener` 间接接入:

```cpp
class EffectManager
{
public:
    class IListener
    {
    public:
        virtual void onEffectChanged( EffectMaterial* pEffect ) = 0;
    };
    void addListener( IListener* pListener );
    void removeListener( IListener* pListener );

    // .fx 文件变化时,EffectManager::reload() 遍历所有 listener
    // 调用 onEffectChanged(pEffect)
};
```

之所以不复用 Reloader/ReloadListener,是因为:

1. EffectMaterial 数量极多(一个 scene 可能有几百个),Reloader 的 SimpleMutex 开销在此场景过大
2. EffectMaterial 的 reload 不需要"双向绑定"——所有 listener 都是 EffectManager 持有的,生命周期由 EffectManager 管理
3. .fx 文件的 reload 是"全量替换"(所有使用此 fx 的 material 一起更新),不需要 per-material 通知

这是 BigWorld 设计的一个微妙之处:同一套引擎内,资源 reload 有两套机制,各自优化到自己的场景。

---

## 二十、性能分析

### 20.1 渲染性能瓶颈定位

D3D9 应用的性能瓶颈大致分布:

```
┌──────────────────────────────────────────────┐
│ CPU 端 (50-70%)                              │
│  ├─ DrawCall (SetVertexBuffer / SetIndexBuffer│
│  │  / SetVertexDeclaration / DrawPrim)       │
│  ├─ State Change (SetRenderState / SetSamplerState)│
│  ├─ Effect CommitChanges (FX 常量上传)       │
│  ├─ Shader Bind (SetVertexShader / SetPixelShader)│
│  └─ Resource Update (Lock / Unlock)          │
├──────────────────────────────────────────────┤
│ GPU 端 (30-50%)                              │
│  ├─ Vertex Fetch (顶点拉取)                  │
│  ├─ Vertex Shader (顶点变换)                 │
│  ├─ Rasterization / Setup (光栅化)           │
│  ├─ Pixel Shader (像素着色)                  │
│  ├─ ROP / Color Write (像素写入)             │
│  ├─ Texture Fetch (纹理采样)                 │
│  └─ Frame Buffer Blend (混合)               │
└──────────────────────────────────────────────┘
```

Moo 在每个层级都提供了优化机制,以下分别剖析。

### 20.2 DrawCall 优化

#### DrawCall 数量与性能的关系

D3D9 的 DrawCall 是一个昂贵的 CPU 操作:每次都要做参数验证、状态查询、driver command buffer 提交。在 NVIDIA 显卡上,一个空 DrawCall 大约耗时 5-15 微秒——意味着 1000 DrawCall/sec 仅占 5-15ms CPU 时间。

BigWorld 的目标性能是 60 FPS(16.67ms/帧),其中 DrawCall 预算约 2000-5000 次/帧。

#### Moo 的 DrawCall 优化策略

**1. DrawContext 延迟队列**

`DrawContext`(`draw_context.hpp/cpp`)是 Moo 最重要的优化——所有 `Visual::draw()` 调用都不立即 draw,而是把 RenderOp 入队:

```cpp
struct RenderOp
{
    ComplexEffectMaterial*   material;
    VertexBuffer*            vertexBuffer;
    IndexBuffer*             indexBuffer;
    VertexDeclaration*       vertexDecl;
    PrimitiveGroup*          primGroup;
    uint32                   instanceCount;
    float                    sortKey;
    // ... 
};
```

帧末 `DrawContext::flush()` 调用 `sortTrianglesByCameraDistance()`,把所有 RenderOp 按 `sortKey` 排序——**`sortKey` 的设计是优化的关键**:

```
sortKey = (materialHandle << 32) | (shaderHandle << 16) | depthQuantized
              ↑              ↑                  ↑
              高 32 位       中 16 位           低 16 位
```

排序后,**相同 material/shader 的 RenderOp 排在一起**,flush 时按顺序 draw,从而最小化 SetPixelShader / SetVertexShader 调用数。这是经典的状态分桶排序。

**2. HW Instancing**

`draw_context.hpp:144-152` 的 InstanceData(已在第十章详述):

```cpp
struct InstanceData
{
    static const uint32 NUM_VECTOR4_PER_SKIN_MATRIX = 3;
    uint32      paletteSize_;
    inline Matrix* matrix()    { MF_ASSERT_DEV(paletteSize_ == 0 ); return (Matrix*)(this + 1); }
    inline Vector4* palette()  { MF_ASSERT_DEV(paletteSize_ != 0 ); return (Vector4*)(this + 1); }
};
```

`DrawContext::fillWrapperOp()` 检测相同 material+VB+IB 的 RenderOp,合并为一个 instanced draw call。在 N 个相同物体(如森林、人群)时,DrawCall 数从 N 降到 1。

**3. SetVertexBuffer 优化**

`RenderContext::setVertexBuffer()`(`render_context.ipp`)缓存上次设置的 VB,如果新 VB 与旧相同则跳过 SetStreamSource 调用——这避免了 driver 端的冗余检查:

```cpp
void RenderContext::setVertexBuffer( VertexBuffer* pVB, uint32 stream )
{
    if (currentVB_[stream] == pVB) return;  // 已设置,跳过
    device_->SetStreamSource(stream, pVB->pComObject(), ...);
    currentVB_[stream] = pVB;
}
```

**4. Effect Material Pass Cache**

`ComplexEffectMaterial::pass()`(`complex_effect_material.hpp:75`)inline 取当前 pass 的 technique:

```cpp
inline ID3DXEffect* ComplexEffectMaterial::pass( uint32 i ) const
{
    return m_techniques[RENDERING_PASS_COUNT][isSkinned_ ? 1 : 0];
}
```

避免每次 draw 都查表。

### 20.3 状态切换优化

#### 状态缓存

`RenderContext` 内部有大量"current state"缓存:

```cpp
class RenderContext
{
    DWORD       currentRenderState_[256]; // D3DRS_* 缓存
    DWORD       currentSamplerState_[MAX_TEXTURE_STAGES][16];
    DWORD       currentTextureStageState_[MAX_TEXTURE_STAGES][32];
    DX::BaseTexture* currentTexture_[MAX_TEXTURE_STAGES];
    // ...
};
```

每次 `setRenderState(state, value)`,先检查缓存,如相同则跳过——driver 端的 SetRenderState 也有此缓存,但应用层做缓存可以省一次跨进程调用。

#### 状态 Push/Pop

`pushRenderState()` / `popRenderState()` 用栈保存当前状态块。这在后处理 chain 中特别有用——每个 phase 可能修改 5-10 个 state,直接 push/pop 比手动恢复简单且不易出错。

#### Stencil 状态机

`IRendererPipeline::setupSystemStencil()`(`renderer.cpp`)定义了 4 位系统 stencil:

| Stencil 值 | 含义 |
|-----------|------|
| 0x01 | 已写入 GBuffer |
| 0x02 | 已计算光照 |
| 0x04 | 已写入阴影 |
| 0x08 | 已处理天空盒 |

各 pass 通过 stencil test 自动跳过已处理像素,避免重复计算。例如光照 pass 设置 `StencilRef=2, StencilPass=D3DSTENCILOP_KEEP, StencilFunc=NOTEQUAL`,只对未计算光照的像素(0x02 未置位)执行光照。

### 20.4 纹理带宽优化

#### 纹理压缩

Moo 支持三种压缩格式:

| 格式 | 每像素比特 | 适用 | 压缩比 vs A8R8G8B8 |
|------|-----------|------|---------------------|
| DXT1 | 4 | 不透明 diffuse | 4:1 |
| DXT3 | 8 | 带 1-bit alpha | 2:1 |
| DXT5 | 8 | 带 8-bit alpha | 2:1 |

纹理加载时(`ManagedTexture::load()`)根据原始格式自动选择压缩,节省显存与带宽。1080p 场景的纹理总占用从 ~500MB 降到 ~150MB。

#### Mipmap

`MipFilterSetting`(`render_context.hpp:229`)控制 mip 生成:

```cpp
EffectMacroSetting& mipFilterSetting() { return mipFilterSetting_; }
```

默认 `D3DX_FILTER_BOX`,可在低端机切换为 `D3DX_FILTER_POINT`(更快但质量差)。

#### Streaming Texture

`StreamingTexture`(`streaming_texture.hpp`)按需上载 mipmap:

1. 远距离物体只用 1x1 / 2x2 mipmap(几百字节)
2. 物体进入视野时,逐步上载更高 mipmap
3. 视野外的 mipmap 被换出

在大世界(如《BigWorld Technology 演示》的 64km² 场景)中,这避免了在初始加载时上载几百 MB 纹理。

### 20.5 GPU Profiler

`gpu_profiler.hpp/ipp/cpp` 基于 D3D Query 测量 GPU 端耗时:

```cpp
class GPUProfiler
{
public:
    void beginScope(const char* name);
    void endScope();
    // 帧末收集结果
    void frameEnd();
};
```

宏 `GPU_PROFILER_SCOPE(name)` 自动 RAII 包裹一段代码:

```cpp
{
    GPU_PROFILER_SCOPE(MyEffect);
    // 渲染逻辑
}
```

实现:

```cpp
void GPUProfiler::beginScope(const char* name)
{
    ComObjectWrap<DX::Query> q1, q2;
    q1 = createQuery(D3DQUERYTYPE_TIMESTAMP);
    q2 = createQuery(D3DQUERYTYPE_TIMESTAMPDISJOINT);
    q1->Issue(D3DISSUE_BEGIN);
    q2->Issue(D3DISSUE_BEGIN);
    scopes_.push_back(Scope(name, q1, q2));
}

void GPUProfiler::endScope()
{
    Scope& s = scopes_.back();
    ComObjectWrap<DX::Query> q1 = createQuery(D3DQUERYTYPE_TIMESTAMP);
    q1->Issue(D3DISSUE_END);
    s.endQuery_ = q1;
    s.disjointQuery_->Issue(D3DISSUE_END);
}
```

帧末 `frameEnd()`:

```cpp
void GPUProfiler::frameEnd()
{
    // 查询 TIMESTAMPFREQ
    UINT64 freq;
    freqQuery_->Issue(D3DISSUE_BEGIN);
    freqQuery_->Issue(D3DISSUE_END);
    while (freqQuery_->GetData(&freq, sizeof(freq), D3DGETDATA_FLUSH) == S_FALSE);

    // 对每个 scope,计算 (end - begin) / freq
    for (auto& s : scopes_)
    {
        UINT64 b, e;
        BOOL disjoint;
        s.disjointQuery_->GetData(&disjoint, sizeof(disjoint), 0);
        if (!disjoint)
        {
            s.beginQuery_->GetData(&b, sizeof(b), 0);
            s.endQuery_->GetData(&e, sizeof(e), 0);
            float ms = float(e - b) / float(freq) * 1000.0f;
            reportToWatcher(s.name, ms);
        }
    }
    scopes_.clear();
}
```

注意 `TIMESTAMPDISJOINT` query:GPU 在某些情况下会"跳过"时间戳(如电源切换、休眠),此时 disjoint flag 为 true,该 scope 的数据无效,跳过报告。

### 20.6 Watcher 系统

`Watcher`(`cstdmf/watcher.hpp`)是 BigWorld 的运行时指标系统。Moo 大量使用 `MF_WATCH` 宏暴露内部状态:

```cpp
MF_WATCH("Render/Performance/DrawPrim Primitive", s_primitiveEnableDrawPrim,
         Watcher::WT_READ_WRITE,
         "Allow Primitive to call drawIndexedPrimitive().");
```

运行时通过 telnet / web 接口访问 `Render/Performance/DrawPrim Primitive` 即可查询或修改这个 bool。

典型 watcher 节点:

| 路径 | 类型 | 含义 |
|------|------|------|
| `Render/Performance/DrawCall` | int | 当前帧 DrawCall 数 |
| `Render/Performance/PrimitiveCount` | int | 当前帧绘制的三角形数 |
| `Render/Performance/FPS` | float | 当前帧率 |
| `Render/Memory/TextureTotal` | uint64 | 纹理总显存 |
| `Render/Memory/VertexBufferTotal` | uint64 | VB 总显存 |
| `Render/Texture/Streaming` | int | 当前上载的 streaming texture 数 |
| `Render/Effect/MaterialCount` | int | EffectMaterial 实例数 |

业务代码也可以注册自定义 watcher,无需重启即可观察。

### 20.7 性能调优 checklist

基于 Moo 的特性,实战调优流程:

1. **观察 watcher** — 找出哪个指标异常(如 DrawCall > 5000,纹理内存 > 1GB)
2. **GPU profiler** — 找出最耗时的 scope,如 `ShadowMapDraw` / `DeferredLighting` / `PostProcessing`
3. **DebugDraw 可视化** — 用 `DebugDraw::triAdd` 高亮 hot spot
4. **针对性的状态分桶** — 如果是 state switch 过多,检查 material 是否有"看似不同但实际等价"的属性(如不同 specular 但同 shader)
5. **降级策略** — 在 `RenderContext::memoryCritical()` 触发时,自动关闭非必要 phase(如 TAA)

---

## 二十一、边界情况

### 21.1 设备丢失(Device Lost)

D3D9 的"设备丢失"是独占模式下最常见的边界:用户 Alt-Tab 切换窗口、屏幕保护启动、电源切换睡眠——这些都会让设备进入 `D3DERR_DEVICELOST` 状态。此时所有 D3D 调用都返回 `DEVICELOST`,业务代码必须妥善处理。

#### 触发与检测

```cpp
HRESULT hr = Moo::rc().device()->TestCooperativeLevel();
if (hr == D3DERR_DEVICELOST)
{
    // 设备已丢失,但还不能 reset——GPU 仍在使用资源
    return;  // 跳过本帧渲染
}
else if (hr == D3DERR_DEVICENOTRESET)
{
    // 设备可以 reset 了
    // 1. 释放 unmanaged 资源
    // 2. 调用 Reset()
    // 3. 重建 unmanaged 资源
}
```

#### DeviceCallback 机制

`DeviceCallback`(`render_context.hpp:155`)是 Moo 的核心资源生命周期抽象:

```cpp
class DeviceCallback
{
public:
    virtual void createUnmanagedObjects()  = 0;
    virtual void deleteUnmanagedObjects()  = 0;
    virtual void createManagedObjects()    = 0;
    virtual void deleteManagedObjects()    = 0;
};
```

四个回调对应四个生命周期点:

| 回调 | 何时调用 | 处理对象 |
|------|---------|---------|
| `createUnmanagedObjects` | 设备创建 / Reset 后 | D3DPOOL_DEFAULT 资源(RT surface、动态 VB/IB) |
| `deleteUnmanagedObjects` | 设备 Reset 前 / 设备丢失时 | 同上 |
| `createManagedObjects` | 设备创建后(一次) | D3DPOOL_MANAGED 资源(纹理、shader) |
| `deleteManagedObjects` | 设备销毁时(一次) | 同上 |

Managed 资源由 D3D 自动管理:设备丢失时 driver 自动释放 video memory、设备恢复时自动重新上载。所以 managed 资源在 device lost 期间不需要业务代码干预。

Unmanaged 资源则在 device lost 时**必须显式释放**——否则 Reset() 会失败。

#### RenderContext::resetDevice()

`render_context.cpp` 中的恢复流程:

```cpp
bool RenderContext::resetDevice()
{
    // 1. 通知所有 callback 释放 unmanaged 资源
    for (auto* cb : deviceCallbacks_)
        cb->deleteUnmanagedObjects();

    // 2. 调用 Reset
    HRESULT hr = device_->Reset(&presentationParameters_);
    if (FAILED(hr)) return false;

    // 3. 通知所有 callback 重建 unmanaged 资源
    for (auto* cb : deviceCallbacks_)
        cb->createUnmanagedObjects();

    return true;
}
```

#### 测试边界

- **回环 GetData**:post_processing/manager.cpp:362 的 `TIMESTAMPFREQ` 查询循环:
  ```cpp
  while(S_FALSE == pFreqQuery->GetData( &timerFreq64, sizeof(DWORD), D3DGETDATA_FLUSH )
        && Moo::rc().device()->TestCooperativeLevel() != D3DERR_DEVICELOST);
  ```
  显式检查 `DEVICELOST` 来跳出 busy loop——否则在设备丢失期间会死循环。

### 21.2 资源不足(Out of Memory)

#### 显存不足

D3D9 在创建 D3DPOOL_DEFAULT 资源时,如果显存不足,`CreateTexture` / `CreateVertexBuffer` 会返回 `D3DERR_OUTOFVIDEOMEMORY`。Moo 的处理:

1. **降级纹理**:从 DXT5 → DXT3 → DXT1,分辨率从 2048 → 1024 → 512
2. **强制 streaming texture 换出**:`TextureStreamingManager::evictLRU()`
3. **触发 `memoryCritical_`**:通知业务层关闭非必要效果

```cpp
// ManagedTexture::create()
HRESULT hr = device_->CreateTexture(..., D3DPOOL_MANAGED, &tex, NULL);
if (hr == D3DERR_OUTOFVIDEOMEMORY)
{
    // 降级
    if (mipLevels_ > 1) --mipLevels_;
    else if (format_ == D3DFMT_A8R8G8B8) format_ = D3DFMT_DXT5;
    else if (format_ == D3DFMT_DXT5) format_ = D3DFMT_DXT1;
    // 重试
    hr = device_->CreateTexture(...);
}
```

#### 系统内存不足

C++ new 抛出 `std::bad_alloc`。Moo 在关键路径上捕获:

```cpp
try {
    pTexture = new ManagedTexture(...);
} catch (const std::bad_alloc&) {
    ERROR_MSG("Failed to allocate ManagedTexture: out of memory\n");
    return NULL;
}
```

但实际上,大多数 Moo 代码不 try/catch,而是依赖 `BWResource` 的内存池预分配——这避免了在渲染热路径上的异常开销。

### 21.3 显卡不支持某特性

#### Shader Model 不足

启动时 `RenderContext::init()` 调用 `selectPSVersionCap()` 检测 PS 版本上限,各子系统通过 `onSelectPSVersionCap(int psVerCap)` 收到回调:

```cpp
void MRTSupport::onSelectPSVersionCap(int psVerCap)
{
    if (psVerCap < 3 && mrtSetting_->activeOption()==0)
        mrtSetting_->selectOption(1); //disable
}
```

类似地:

- TAA:PS < 3.0 → 降级到 PPAA
- Deferred:PS < 3.0 → 强制 Forward
- 纹理压缩:不支持 DXT → 降级到 A8R8G8B8

#### MRT 不足

`RenderContext::mrtSupported()` 查询 caps:

```cpp
bool RenderContext::mrtSupported() const
{
    return caps_.NumSimultaneousRTs >= 2;
}
```

如果硬件只支持 1 个 RT(老 GPU 或 WARP 软件 rasterizer),则 MRTSupport 自动 disabled,Deferred 管线不可用。

#### 32 位索引不足

`primitive.cpp:179-185`:

```cpp
if (Moo::rc().maxVertexIndex() <= 0xffff &&
    format == D3DFMT_INDEX32 )
{
    ERROR_MSG( "Primitives::load - unable to create index buffer as 32 bit indices "
               "were requested and only 16 bit indices are supported\n" );
    return res;
}
```

如果模型顶点数 > 65535 但硬件不支持 32-bit index,直接 load 失败。BigWorld 的工具链(asset_pipeline)会在编译时检测这种情况,把模型拆分为多个 sub-mesh,但运行时的最后一道防线仍在这里。

### 21.4 多显示器

#### 全屏 + 多显示器

D3D9 在多显示器下,`CreateDevice` 的 `hFocusWindow` 决定哪个窗口接收输入焦点。如果用户在副显示器上点窗口,主显示器的全屏会最小化。

Moo 的解决:

1. 默认窗口模式,而非独占全屏
2. 提供"borderless fullscreen"伪全屏(窗口最大化到屏幕,无标题栏,但仍为 windowed mode)
3. 设置 `D3DPRESENT_PARAMETERS::Windowed = TRUE` + `D3DCREATE_ADAPTERGROUP_DEVICE`

#### 显示器分辨率切换

`changeMode(width, height, depth)`(`render_context.cpp`)处理:

```cpp
bool RenderContext::changeMode(uint32 width, uint32 height, uint32 depth,
                                bool windowed)
{
    if (width == width_ && height == height_ && depth == depth_ &&
        windowed == windowed_) return true;  // 无变化

    // 1. 释放 unmanaged 资源
    deleteUnmanagedObjects();

    // 2. 更新 presentationParameters
    presentationParameters_.BackBufferWidth  = width;
    presentationParameters_.BackBufferHeight = height;
    presentationParameters_.BackBufferFormat = depthToFormat(depth);
    presentationParameters_.Windowed = windowed;

    // 3. Reset
    HRESULT hr = device_->Reset(&presentationParameters_);
    if (FAILED(hr)) return false;

    // 4. 重建 unmanaged 资源
    createUnmanagedObjects();

    width_ = width; height_ = height; depth_ = depth;
    return true;
}
```

#### 多 GPU(CrossFire/SLI)

D3D9 不直接感知 SLI/CrossFire——driver 层会透明地把渲染分发到多个 GPU。但有些规则需要注意:

- **不要在帧中间 lock 资源**:SLI 下 lock 会强制 GPU 同步,大幅降速
- **避免过多的 ReadBack**:GPU→CPU 的 GetData 也会触发同步

Moo 的 GPU Profiler 在 SLI 下数据可能不准,因为不同 GPU 的时间戳不一定同步。

### 21.5 异常文件

#### 损坏的 .visual / .primitive 文件

`primitive.cpp:168-170`:

```cpp
BinaryPtr indices = sec->readBinary( resourceID_.substr( noff+1 ) );
if( indices )
{
    const IndexHeader* ih = reinterpret_cast< const IndexHeader* >( indices->data() );
```

如果文件大小 < `sizeof(IndexHeader)`,`reinterpret_cast` 后访问 `ih->indexFormat_` 会读越界。Moo 没有显式 size 检查——这是潜在的安全问题。但 `BWResource` 在 `readBinary` 时会做文件大小校验,返回的 BinaryPtr 至少能容纳 header,所以实际不会 crash。

#### 不存在的资源 ID

`visual.cpp` 的 `Visual::Materials::find()`:

```cpp
MaterialPtr Visual::Materials::find(const BW::string& identifier) const
{
    for (auto& m : materials_)
        if (m->identifier() == identifier) return m;
    return NULL;  // 返回 NULL
}
```

返回 NULL 由调用方检查。如果调用方忘记检查 → crash。BigWorld 代码审查会捕获这种忘记检查的情况。

#### 类型不匹配的 .fx 文件

`EffectMaterial::load()`:

```cpp
HRESULT EffectMaterial::load(const BW::wstring& resourceID)
{
    ID3DXEffect* pFX = NULL;
    HRESULT hr = D3DXCreateEffectFromFileW(
        Moo::rc().device(), resourceID.c_str(), NULL, NULL,
        D3DXSHADER_NO_PRESHADER | D3DXSHADER_PARTIALPRECISION,
        NULL, &pFX, NULL);

    if (FAILED(hr))
    {
        ERROR_MSG("EffectMaterial::load - failed to load %S: %s\n",
                  resourceID.c_str(), DXGetErrorDescriptionA(hr));
        return hr;
    }
}
```

如果 .fx 文件有语法错误,`D3DXCreateEffectFromFileW` 返回错误码 + 编译错误 buffer。Moo 把错误信息打印到日志,业务层应 fallback 到默认 fx。

### 21.6 线程安全边界

Moo 主要在主线程使用,但有些子系统支持多线程:

| 子系统 | 线程安全 | 备注 |
|--------|---------|------|
| RenderContext | 否 | 所有 D3D 调用必须在主线程 |
| TextureManager | 是(SimpleMutex 保护) | 后台 streaming 线程可加载 |
| VisualManager | 是(RWLock) | 后台 IO 线程可加载 visual |
| EffectManager | 否 | 编译必须在主线程 |
| Reloader | 是(SimpleMutex) | 后台 IO 线程可触发 reload |

跨线程访问时,业务代码必须:

1. 用 `Visual::beginRead()` / `endRead()` 获取读锁
2. 不要在 IO 线程直接调用 D3D API——必须把任务 post 到主线程

### 21.7 异常 case 总结

下表总结 Moo 在不同异常场景下的行为:

| 异常 | 触发 | Moo 行为 | 业务建议 |
|------|------|---------|---------|
| 设备丢失 | Alt-Tab、屏保 | DeviceCallback 释放/重建 | 监听 `onDeviceLost` 事件,暂停游戏逻辑 |
| 显存不足 | 资源过多 | 降级纹理 + 通知 `memoryCritical_` | 实现 `onMemoryCritical` 回调,关闭非必要效果 |
| Shader 不支持 | 老显卡 | `EffectMacroSetting` 切换 option | 提供低质量 .fx 文件 |
| MRT 不支持 | 软件栅格化 | MRTSupport disabled | 强制 Forward 管线 |
| 32 位索引不支持 | 老显卡 | load 失败 + ERROR_MSG | 工具链拆分模型 |
| 文件损坏 | IO 错误 | NULL 返回 + ERROR_MSG | 业务层 NULL 检查 |
| 多显示器 | 用户配置 | 默认窗口模式 | 提供"伪全屏"选项 |

---

## 二十二、与其他引擎对比

### 22.1 总体架构对比

| 维度 | BigWorld Moo | Unity (Built-in) | Unity (URP) | Unity (HDRP) | Unreal Engine 4/5 | CryEngine |
|------|--------------|-------------------|-------------|--------------|-------------------|------------|
| API 抽象 | D3D9 + DX namespace | 多后端(D3D11/12, Metal, Vulkan, GL) | 同上 | 同上 | RHI 抽象层 | 多 backend |
| 渲染管线 | Forward / Deferred 二选一 | Forward / Deferred | 可编程 SRP | 可编程 SRP | Forward+/Deferred | Deferred |
| 命令录制 | 即时模式 | 即时模式 + CommandBuffer | SRP Batch | SRP Batch + Async Compute | RHICmdList(线程化) | 即时 |
| 资源生命周期 | Managed / Unmanaged + DeviceCallback | Resources.UnloadUnusedAssets | 同 | 同 | GC + Strong Ref | Streaming |
| 跨平台性 | Windows + PS3 + Xbox360 | 30+ 平台 | 同 | 同 | 10+ 平台 | 5+ 平台 |
| 多线程渲染 | 否 | 部分 | 部分 | 部分 | 是(D3D11+) | 部分 |

### 22.2 设备管理对比

**Moo** 用 `RenderContext` + `DeviceCallback`:

- D3D9 only,无 RHI 抽象
- 设备丢失靠 `deleteUnmanaged` / `createUnmanaged` 显式回调
- 多显示器支持简单,通过 `Windowed` flag

**Unity** 用 `GraphicsDevice` + 平台 backend:

- `GraphicsDevice` 抽象 D3D11/12/Metal/Vulkan/GL
- D3D11+ 后没有"设备丢失"概念,资源由 driver 透明管理
- 多显示器通过 `Display` API(每个 display 一个 SwapChain)

**Unreal** 用 `RHI` 层:

- 抽象度更高,平台 backend 是 `FD3D11DynamicRHI` / `FD3D12DynamicRHI` / `FVulkanRHI`
- D3D11+ 无设备丢失
- 多显示器通过 `FSwapChain` + `FViewport`

**对比要点**:

- Moo 的 DeviceCallback 是 D3D9 时代的特有抽象——D3D11+ 已不需要
- Unreal 的 RHI 设计为多线程优化(D3D12/Vulkan 的 command queue 录制),Moo 是单线程的,与硬件趋势相悖

### 22.3 渲染队列对比

**Moo** 用 `DrawContext`:

- 单线程立即录制(RenderOp vector)
- 帧末一次性 sort + flush
- 排序 key:material + shader + depth

**Unity URP** 用 SRP Batch:

- C# 侧按 material 分桶
- 每桶一次 CB 更新 + 多次 DrawCall
- 不做距离排序(默认)

**Unreal** 用 `RHICmdList`:

- 多线程录制(IRendererModule 的各种 task)
- SubmitCommandList 时按 pass + sort key 提交
- 支持 parallel RHI(D3D12 命令录制)

**对比要点**:

- Moo 的 DrawContext 设计简洁,适合单线程场景
- Unreal 的 RHICmdList 是为现代 API(D3D12/Vulkan)优化的,可线程化录制
- Unity URP 的 SRP Batch 对 small DrawCall 优化显著,但缺乏 transparent 排序的灵活性

### 22.4 材质系统对比

| 维度 | Moo Material/EffectMaterial | Unity ShaderLab | Unreal Material Editor | CryEngine Shader |
|------|----------------------------|------------------|----------------------|------------------|
| 表达方式 | C++ 类 / HLSL .fx | ShaderLab DSL | 节点编辑器(转 HLSL) | 节点 + .cfx |
| 多 pass | ComplexEffectMaterial | Pass 块 | Multiple Pass | Pass |
| LOD | 是(material[RENDERING_PASS][skinned]) | SubShader | Quality Switch | Quality |
| Override | OverrideBlock | RenderType | Material Domain | Material Type |
| Hot Reload | Reloader / EffectManager.IListener | ApplyPropertyBlock | Hot Reload(运行时) | Hot Reload |

**对比要点**:

- Moo 的"双轨材质"(固定管线 Material + 可编程 EffectMaterial)是 D3D9 时代的产物,现代引擎已完全抛弃固定管线
- Unreal 的节点编辑器让非程序员也能写 shader,而 Moo 必须用 .fx 文本
- Unity 的 ShaderLab 用嵌套的 C-like DSL,易学但表达力不如纯 HLSL

### 22.5 后处理对比

**Moo** 用 PostProcessing::Manager:

- Python 配置 chain
- Effect → Phase → FilterQuad 三层抽象
- 通过 `PostProcessing::load(dataSection)` 从 XML 加载

**Unity URP** 用 Volume + Override:

- 每个 Volume 是一个 sphere/box
- Volume override 是一组参数(blur amount / vignette intensity)
- 自动按权重混合多个 Volume

**Unreal** 用 Post Process Volume:

- 类似 Unity,但更细粒度
- 支持 Material 替换任意 phase

**对比要点**:

- Moo 的 Python 配置让设计师能独立修改 chain,无需重启 client
- Unity/Unreal 的 Volume 系统支持空间混合(走过去 bloom 渐变)
- Moo 没有 Volume 概念,空间变化必须业务代码处理

### 22.6 抗锯齿对比

| 引擎 | MSAA | TAA | FXAA | SMAA | DLAA / DLSS |
|------|------|-----|------|------|-------------|
| Moo | 是(硬件) | 是(cache miss 哲学) | 是(custom_AA) | 否 | 否(D3D9 时代) |
| Unity URP | 是 | 是 | 是 | 是 | 否(需 Plugin) |
| Unity HDRP | 是 | 是 | 否(SMAA 替代) | 是 | 是(NVIDIA 插件) |
| Unreal | 是 | 是(默认) | 否 | 是 | 是(DLSS 2/3) |
| CryEngine | 是 | 是 | 是 | 是 | 否 |

**对比要点**:

- Moo 的 TAA 用 cache miss 哲学近似 motion vector,无需几何信息——简单但精度差
- Unreal 的 TSR (UE5)用 motion vector + history buffer,质量高但需要 geometry pass 输出 motion
- DLSS 在 D3D9 时代不存在,Moo 没有这种 AI 超分

### 22.7 流式纹理对比

**Moo** 用 `StreamingTexture`:

- 后台线程解码 DXT 数据
- 按 distance 决定 mip level
- 显存不足时 LRU 换出

**Unity** 用 `Texture Streaming` (URP/HDRP):

- 自动 mip bias
- `QualitySettings.streamingMipmapsActive` 控制
- 同样按 distance LRU

**Unreal** 用 `Texture Streaming Pool`:

- 按 priority 决定上载顺序
- 显存不足时按 priority 换出
- 业务层可强制 `SetStreamable(false)`

**对比要点**:

- 三者原理相似
- Unreal 的 priority 系统更精细(Mip-priority / Texture-priority 双层)
- Moo 的 streaming 在 BigWorld 大世界场景下表现稳定

### 22.8 大世界优化对比

BigWorld 引擎的核心优势是大世界——这体现在:

- **Terrain LOD**:基于 chunk 的 geomipmapping
- **Flora**:GPU-instanced 草地
- **SpeedTree**:LOD 树
- **Chunk-based 流式加载**:`ChunkManager` 异步加载/卸载

对比:

| 引擎 | 大世界方案 | 优势 | 劣势 |
|------|-----------|------|------|
| BigWorld | Chunk + StreamingTexture | 设计简单,稳定 | 单线程瓶颈 |
| Unity | HLOD + Streaming | 生态丰富 | 大场景下 GC 卡顿 |
| Unreal | World Partition + Nanite(UE5) | GPU-driven,无 LOD pop | 显卡要求高 |
| CryEngine | Summed-Area Tables + VT | 大世界质量高 | 学习曲线陡 |

### 22.9 调试与可视化对比

**Moo**:

- Watcher 系统(telnet/web 远程访问)
- DebugDraw(每帧 clear)
- GPU Profiler(D3D Query)

**Unity**:

- Profiler(深入 CPU/GPU/Memory/Battery)
- Frame Debugger(逐 DrawCall 回放)
- Custom Render Texture 调试

**Unreal**:

- RenderDoc 集成
- GPU Visualizer(每 pass 时间条形图)
- ProfileGPU(单帧分析)

**对比要点**:

- Moo 的 Watcher 在运行时 hot-tune 是独有优势
- Unity/Unreal 的 Profiler 提供更深的 insight,但需要 editor 连接
- Unreal 的 RenderDoc 集成让 GPU 调试更直接

### 22.10 跨平台能力对比

**Moo** 仅 Windows + PS3 + Xbox360(2014 年的 14.4.1 版本):

- D3D9 是核心,PS3/Xbox 是另一套独立实现
- 移动端(iOS/Android)需要新的 backend

**Unity** 跨 30+ 平台:

- 同一 .unity 场景可一键 build 到 Win/Mac/Linux/iOS/Android/WebGL/PS5/XboxSeries/Switch
- 代价是某些后端性能不极致

**Unreal** 跨 10+ 平台:

- 主机表现最佳(Sony/Nintendo 优化)
- 移动端不如 Unity

**对比要点**:

- Moo 是为 PC + 主机优化的,移动端需要大量改造
- Unity 的"Write Once, Run Anywhere"对小团队最友好
- Unreal 的"主机优先"哲学适合 3A 工作室

### 22.11 总结

BigWorld Moo 是一个**为大型 MMO 网络游戏优化的渲染引擎**,其设计哲学:

1. **稳定优先**:大世界 + 长时间运行(7x24h 服务器),稳定性 > 极致画质
2. **可远程监控**:Watcher 让运维在玩家不退出的情况下调整参数
3. **设计者友好**:Python 配置后处理、热重载 .fx,美术迭代快
4. **D3D9 时代**:虽然限制了某些现代特性(D3D12 的 command queue、Compute Shader、异步队列),但已优化到极致

在现代引擎(UE5/Unity HDRP)面前,Moo 的画质上限偏低,但在以下场景仍有不可替代的优势:

- 大型 MMO 服务器集群 + 客户端协同
- 长时间运行的稳定性
- 美术/策划独立的 Python 工作流
- 完整的 server-authoritative 物理与碰撞

---

## 附录

### A.1 关键源码文件清单

| 文件 | 行数 | 主要类 |
|------|------|--------|
| `moo/render_context.hpp/cpp` | ~5000 | RenderContext, DeviceCallback |
| `moo/renderer.hpp/cpp` | ~1500 | Renderer, IRendererPipeline |
| `moo/forward_pipeline.hpp/cpp` | ~2000 | ForwardPipeline |
| `moo/deferred_pipeline.hpp/cpp` | ~3000 | DeferredPipeline |
| `moo/node.hpp/ipp/cpp` | ~1500 | Node, NodeCatalogue |
| `moo/visual.hpp/ipp/cpp` | ~3000 | Visual, RenderSet, Geometry |
| `moo/primitive.hpp/ipp/cpp` | ~800 | Primitive |
| `moo/vertices.hpp/ipp/cpp` | ~1200 | Vertices |
| `moo/material.hpp/ipp/cpp` | ~700 | Material |
| `moo/effect_material.hpp/ipp/cpp` | ~1500 | EffectMaterial |
| `moo/complex_effect_material.hpp/cpp` | ~600 | ComplexEffectMaterial |
| `moo/draw_context.hpp/cpp` | ~2000 | DrawContext, RenderOp |
| `moo/camera.hpp/ipp/cpp` | ~600 | Camera |
| `moo/light_container.hpp/ipp/cpp` | ~1000 | LightContainer |
| `moo/omni_light.hpp/ipp` | ~300 | OmniLight |
| `moo/spot_light.hpp/ipp` | ~300 | SpotLight |
| `moo/pulse_light.hpp/cpp` | ~200 | PulseLight |
| `moo/directional_light.hpp/ipp` | ~200 | DirectionalLight |
| `moo/managed_texture.hpp/ipp` | ~400 | ManagedTexture |
| `moo/streaming_texture.hpp/ipp` | ~600 | StreamingTexture |
| `moo/texture_manager.hpp/cpp` | ~500 | TextureManager |
| `moo/render_target.hpp/ipp/cpp` | ~800 | RenderTarget |
| `moo/cube_render_target.hpp/ipp/cpp` | ~400 | CubeRenderTarget |
| `moo/mrt_support.hpp/cpp` | ~200 | MRTSupport, TextureSetter |
| `moo/taa_support.hpp/cpp` | ~500 | TemporalAASupport |
| `moo/ppaa_support.hpp/cpp` | ~400 | PPAASupport |
| `moo/custom_AA.hpp/cpp` | ~300 | CustomAA |
| `moo/fog_helper.hpp/cpp` | ~200 | FogHelper |
| `moo/gpu_info.hpp/cpp` | ~600 | GpuInfo |
| `moo/gpu_profiler.hpp/ipp/cpp` | ~500 | GPUProfiler |
| `moo/debug_draw.hpp/cpp` | ~200 | DebugDraw |
| `moo/reload.hpp/cpp` | ~250 | Reloader, ReloadListener |
| `moo/visual_manager.hpp/ipp` | ~300 | VisualManager |
| `moo/effect_manager.hpp/cpp` | ~800 | EffectManager |
| `moo/primitive_manager.hpp/cpp` | ~400 | PrimitiveManager |
| `moo/vertex_format.hpp/cpp` | ~600 | VertexFormat |
| `moo/vertex_formats.hpp` | ~400 | VertexXYZNUV, GPU packing |
| `moo/primitive_file_structs.hpp` | ~200 | VertexHeader, IndexHeader, PrimitiveGroup |
| `post_processing/manager.hpp/cpp` | ~400 | PostProcessing::Manager |
| `post_processing/effect.hpp/cpp` | ~300 | Effect |
| `post_processing/phase.hpp/cpp` | ~300 | Phase |
| `post_processing/filter_quad.hpp/cpp` | ~200 | FilterQuad |

### A.2 关键宏与工具宏

| 宏 | 定义 | 用途 |
|---|------|------|
| `BW_GUARD` | try/catch 包装 | 异常隔离 |
| `BW_GUARD_PROFILER(name)` | BW_GUARD + CPU profiler | 函数级性能分析 |
| `GPU_PROFILER_SCOPE(name)` | RAII GPU profiler | GPU 端耗时测量 |
| `MF_WATCH(path, var, type, desc)` | Watcher 注册 | 运行时变量监控 |
| `MF_ASSERT_DEV(cond)` | Debug 模式断言 | 开发期检查 |
| `MF_ASSERT(cond)` | Release 模式断言 | 关键路径检查 |
| `MF_EXIT(msg)` | 强制退出 | 不可恢复错误 |
| `BW_SINGLETON_STORAGE(cls)` | 单例静态存储 | 全局单例声明 |
| `PY_MODULE_STATIC_METHOD(cls, name, mod)` | Python 方法注册 | 暴露给脚本 |
| `DECLARE_DEBUG_COMPONENT2(name, level)` | Debug 组件声明 | 日志过滤 |

### A.3 D3D9 资源类型与 Pool 对比

| Resource | Pool | 用途 |
|----------|------|------|
| 静态 VB / IB | D3DPOOL_MANAGED | 几何数据 |
| 动态 VB / IB | D3DPOOL_DEFAULT + D3DUSAGE_DYNAMIC | 频繁 Lock |
| Render Target texture | D3DPOOL_DEFAULT | RT surface |
| Depth stencil | D3DPOOL_DEFAULT | 深度缓冲 |
| D3D texture | D3DPOOL_MANAGED | 普通纹理 |
| Vertex shader | D3DPOOL_MANAGED | 顶点着色器 |
| Pixel shader | D3DPOOL_MANAGED | 像素着色器 |
| Vertex declaration | (无 pool 概念) | 顶点声明 |
| State block | (无 pool 概念) | 状态块 |
| Query | (无 pool 概念) | GPU query |

### A.4 Stencil 位掩码分布

```
[ 7 6 5 4 | 3 | 2 | 1 | 0 ]
   ↑↑↑↑↑   ↑    ↑    ↑    ↑
   用户自定义  天空 | 阴影| 光照 | GBuffer
   4 位       1 位 1 位 1 位 1 位
```

系统使用低 4 位(0x01-0x08),用户自定义 4 位(0x10-0x80)。`IRendererPipeline::resetStencil()`(`renderer.cpp`)在每帧开始时清空系统 4 位,保留用户 4 位。

### A.5 主要 Python 接口

| 模块 | 主要方法 | 用途 |
|------|---------|------|
| `PostProcessing` | `chain / load / save / debug / profile` | 后处理 chain 管理 |
| `Moo` | `camera / device / texture` | 渲染底层 |
| `BigWorld` | `camera / player / entities` | 引擎全局 |
| `GUI` | `mats / add / root` | UI |

### A.6 性能 watcher 关键路径

```
Render/
├── Performance/
│   ├── DrawCall
│   ├── PrimitiveCount
│   ├── FPS
│   ├── FrameTime
│   └── DrawPrim Primitive
├── Memory/
│   ├── TextureTotal
│   ├── VertexBufferTotal
│   ├── IndexBufferTotal
│   └── RenderTargetTotal
├── Texture/
│   ├── Streaming
│   ├── Loaded
│   └── CacheHits
├── Effect/
│   ├── MaterialCount
│   └── CompileErrors
├── Camera/
│   ├── NearPlane
│   ├── FarPlane
│   └── FOV
└── Device/
    ├── LostCount
    ├── ResetCount
    └── CooperativeLevel
```

### A.7 推荐阅读顺序

1. **入门**:`render_context.hpp` 注释 → `renderer.hpp:28-35` 设计说明 → `init.hpp/cpp` 设备创建
2. **管线**:`forward_pipeline.hpp/cpp` → `deferred_pipeline.hpp/cpp` → `renderer.cpp::setupSystemStencil`
3. **几何**:`primitive_file_structs.hpp` → `vertices.hpp` → `primitive.hpp/cpp::load` → `visual.hpp::RenderSet/Geometry`
4. **材质**:`material.hpp` → `effect_material.hpp::load` → `complex_effect_material.hpp::pass`
5. **场景图**:`node.hpp::traverse` → `node.cpp::loadIntoCatalogue` → `node_catalogue.hpp`
6. **后处理**:`post_processing/manager.hpp::draw` → `effect.hpp` → `phase.hpp` → `filter_quad.hpp`
7. **抗锯齿**:`taa_support.hpp::注释` → `taa_support.cpp::jitteredProjMatrix` → `mrt_support.cpp::bind`
8. **调试**:`debug_draw.cpp::draw` → `gpu_profiler.hpp` → `watcher.hpp`
9. **优化**:`draw_context.cpp::flush` → `render_context.ipp::setRenderState` 缓存

### A.8 术语表

| 术语 | 解释 |
|------|------|
| **Moo** | BigWorld 渲染引擎,My Object Oriented 缩写 |
| **DrawCall** | 一次 DrawPrimitive 调用 |
| **RenderOp** | DrawContext 中的延迟渲染单元 |
| **GBuffer** | Geometry Buffer,Deferred 渲染的多 RT 输出 |
| **MRT** | Multiple Render Targets,一次 draw 多个 RT 输出 |
| **TAA** | Temporal Anti-Aliasing,时域抗锯齿 |
| **PPAA** | Post-Process Anti-Aliasing,后处理抗锯齿 |
| **FXAA** | Fast Approximate Anti-Aliasing,NVIDIA 算法 |
| **RGSS** | Rotated Grid Super Sampling,旋转网格超采样 |
| **LDR / HDR** | Low / High Dynamic Range |
| **Pipeline State** | 渲染管线状态(shaders + states + RTs) |
| **DrawContext** | Moo 的延迟渲染队列 |
| **NodeCatalogue** | 共享节点目录,避免重复实例化 |
| **EffectMaterial** | .fx 文件材质,可编程 |
| **OverrideBlock** | 全局材质替换,用于 shadow / depth prepass |
| **DeviceCallback** | 资源生命周期回调接口 |
| **ReloadListener** | 资源热重载监听者 |
| **SortKey** | RenderOp 排序键,合并相同 material |
| **Watcher** | BigWorld 运行时指标系统 |
| **GpuInfo** | D3DKMT 内核级显卡信息查询 |
| **Streaming Texture** | 按需上载 mipmap 的纹理 |

### A.9 版本演进

BigWorld Engine 14.4.1 是 2014 年的版本,其后的演进:

- **BigWorld 14.4.x** → 最后一个 D3D9 版本
- **Wargaming.net** 收购后 → 转向自研 WG framework
- **后续产品 World of Tanks / World of Warships** → 仍基于 BigWorld 演化,但渲染层大幅重写

### A.10 致谢与版权

本文档基于 BigWorld Engine 14.4.1 源码分析,所有引用的代码版权归 BigWorld Pty Ltd(现 Wargaming.net)所有,文档内容仅用于学习目的。

---

**文档结束**