# Server Build Guide（服务器构建指南）

## 目录

- 概述（第 3 页）
- 系统要求（第 4 页）
  - 硬件要求（第 4 页）
  - Linux 发行版要求（第 4 页）
  - 软件要求（第 4 页）
    - 安装所需软件（第 5 页）
- 检出 BigWorld Technology 安装包（第 6 页）
- 编译 BigWorld 服务器（第 7 页）
- 安装 BigWorld 服务器（第 8 页）
- BigWorld 服务器组件（第 9 页）
- 延伸阅读（第 12 页）

---


<!-- PAGE 1 -->

### Server Build Guide（服务器构建指南）
BigWorld Technology OSE。2014 年 12 月发布。
BigWorld Pty Ltd, Level 2, 1 Smail Street, Ultimo NSW 2007, Australia
www.bigworldtech.com
版权所有 © 2014 BigWorld Pty Ltd。保留所有权利。

<!-- PAGE 2 -->

概述 | 系统要求 | 检出 BigWorld Technology 安装包 | 编译 BigWorld 服务器 | 安装 BigWorld 服务器 | BigWorld 服务器组件 | 延伸阅读

<!-- PAGE 3 -->

# 概述

本文档描述了构建服务器及相关工具所需的构建环境配置方法，以及编译服务器和相关组件的流程。除非您要对 BigWorld 服务器进程进行特定修改，否则建议使用官方发布的二进制文件。

<!-- PAGE 4 -->

# 系统要求
## 硬件要求
## Linux 发行版要求
## 软件要求

BigWorld 服务器可以在大多数标准“桌面”PC 上编译。编译服务器所需的最低系统配置如下：

- 64 位 Intel / AMD CPU
- 512 MB 内存

BigWorld 支持在以下四种 Linux 发行版上编译并运行服务器。这些发行版包括：

- RedHat Enterprise Linux 5 和 7（http://www.redhat.com）
- CentOS 5 和 7（http://www.centos.org）

![image](images/server-build-guide_p4_1.png)

请注意，我们目前尚未测试且不支持 RHEL 6 / CentOS 6。有关如何安装 CentOS 的更多信息，请参阅《Server Installation Guide（服务器安装指南）》。除非另有说明，下列所有软件包均应使用 RedHat 或 CentOS 发行版的默认安装来源。除非明确说明，否则不支持来自第三方软件仓库的软件包。编译服务器需要以下软件包。请注意，您无需逐个安装这些软件包，可以直接安装 `bigworld-devel` 软件包——`bigworld-devel` 软件包包含了以下列出的所有软件包。

- GNU C / C++ 编译器（软件包：`gcc`、`gcc-c++`）
- GNU make（软件包：`make`）

<!-- PAGE 5 -->

### 安装所需软件

- 在 CentOS 5 上：MySQL 开发文件（`mysql-devel`）
- 在 CentOS 7 上：MariaDB 开发文件（`mariadb-devel`）
- Python 开发文件（软件包：`python-devel`）
- Python 库的支持库（软件包：`sqlite-devel`、`readline-devel`、`gdbm-devel`、`bzip2-devel`、`ncurses-devel`、`binutils-devel`）
- SDL 开发文件，用于 SDL 示例客户端（软件包：`SDL-devel`、`SDL_image-devel`）

![image](images/server-build-guide_p5_1.png)

`SDL_image-devel` 软件包目前在 CentOS 7 上不可用。如果您希望在 CentOS 7 上使用 SDL 客户端，则需要手动安装 SDL_image 软件包。此外还建议（但非必需）安装以下软件包：

- GNU 调试器（软件包：`gdb`）

所有必需的软件包都可以通过系统包管理程序 `yum` 直接安装。要使用 `yum` 安装软件包，可使用如下命令：

```
$ yum install <package_name>
```

例如，要安装 GNU C 和 C++ 编译器，您可以以 root 用户身份执行以下命令，并根据提示进行相应操作：

```
$ yum install gcc gcc-c++
```

<!-- PAGE 6 -->

# 检出 BigWorld Technology 安装包

### 检出 BigWorld Technology
### 安装包

您需要从官方 BigWorld 仓库检出 BigWorld Technology 安装包。我们建议您将源代码放在普通用户账户下（即不要使用 root / 特权用户账户）。检出的目录名称完全由您决定，不过我们建议以您的项目名称来命名。

<!-- PAGE 7 -->

# 编译 BigWorld 服务器

一旦安装好构建环境，编译服务器是一项简单的操作。

![image](images/server-build-guide_p7_1.png)

切勿以 `root` 用户身份编译服务器。切换到您的 BigWorld 检出目录，例如：

```
$ cd /home/builduser/bigworld_pristine
```

切换到 BigWorld 源代码目录：

```
$ cd programming/bigworld
```

运行 `make`：

```
$ make
```

BigWorld 服务器源代码位于 `programming/bigworld/server` 目录下，各个服务器组件位于其下的子目录中。

如需要，可以通过在某个组件的源代码目录中运行 `make` 来重新编译该组件。例如，要重新编译 DBAppMgr，可执行以下命令：

```
$ cd programming/bigworld/server/dbappmgr
$ make
```

<!-- PAGE 8 -->

# 安装 BigWorld 服务器

有关如何安装 BigWorld 服务器及相关组件的详细信息，请参阅《Server Installation Guide（服务器安装指南）》。

<!-- PAGE 9 -->

# BigWorld 服务器组件

| 目录 | 内容 | 描述 |
| --- | --- | --- |
| `programming/` | 顶层 BigWorld Technology 源代码目录。 |
| `bigworld/` | `examples/` | 小型客户端与服务器示例的源代码。 |
| | `cellapp_extension/` | 演示如何使用 C++ 扩展 cell 实体（EntityExtra / Controllers）的示例。 |
| | `examples/client_integration/` | 将其他客户端与 BigWorld 服务器集成的示例。 |
| | `examples/client_integration/c_plus_plus/` | 游戏逻辑使用 C++ 实现的示例客户端。 |
| | `examples/client_integration/python/` | 游戏逻辑使用 Python 实现的示例客户端。 |
| | `examples/client_integration/simple/` | 简单的 Python 客户端示例。 |
| `lib/` | 所有库代码的顶层目录。 |
| `server/` | 所有服务器专用源代码的容器目录。 |
| | `baseapp/` | BaseApp 服务器组件（标准安装包中不提供源代码）。 |
| | `baseappmgr/` | BaseAppMgr 服务器组件。 |
| | `cellapp/` | CellApp 服务器组件（标准安装包中不提供源代码）。 |

<!-- PAGE 10 -->

| 目录 | 内容 | 描述 |
| --- | --- | --- |
| `cellappmgr/` | CellAppMgr 服务器组件（标准安装包中不提供源代码）。 |
| `dbapp/` | DBApp 服务器组件（另请参阅 `lib/db_storage_*` 目录中针对不同数据库后端的具体实现）。 |
| `dbapp_extensions/` | DBApp 在运行时加载的数据库专用引擎驱动。 |
| `dbappmgr/` | DBAppMgr 服务器组件。 |
| `loginapp/` | LoginApp 服务器组件。 |
| `reviver/` | Reviver 服务器组件。 |
| `tools/` | 基于 C++ 的服务器工具的容器目录。 |
| `bots/` | Bots 服务器进程，用于模拟自动化的客户端连接。 |
| `bwmachined/` | BWMachined 守护进程，用于服务器进程通信与运行管理。 |
| `clear_auto_load/` | ClearAutoLoad 程序，用于在启动前从 Entity 数据库中移除所有自动加载的实体。 |
| `consolidate_dbs/` | ConsolidateDBs 进程，用于在 BigWorld 服务器启动或关闭时聚合集群中的辅助数据库。 |
| `message_logger/` | MessageLogger 服务器组件，用于接收来自服务器组件的日志消息并将其写入永久日志文件。 |
| `snapshot_helper/` | 快照助手程序，用于对数据库进行 LVM 快照。 |

<!-- PAGE 11 -->

| 目录 | 内容 | 描述 |
| --- | --- | --- |
| `sync_db/` | SyncDB 服务器进程，用于更新实体数据库结构，使其与当前实体定义状态保持一致。 |
| `transfer_db/` | TransferDB 服务器进程，用于对主数据库和辅助数据库进行快照并传输。 |

<!-- PAGE 12 -->

# 延伸阅读

有关 BigWorld 服务器的更多信息，请参阅以下文档：

- Server Overview（服务器概述）
- Server Installation Guide（服务器安装指南）
- Server Programming Guide（服务器编程指南）
- Server Operations Guide（服务器运维指南）
