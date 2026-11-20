# GalBox

GalBox 是 Apple Silicon Mac 上的 Windows 视觉小说启动器。把整个 ZIP、RAR、7z 压缩包或游戏文件夹拖进窗口，GalBox 会复制或解压资源，识别主程序，并用 Wine 启动游戏。遇到多个候选程序时，可以手动选择。

## 从源码开始

准备一台 Apple Silicon Mac，安装 Apple Command Line Tools（`xcode-select --install`）并确保 Rosetta 2 可用。应用的构建目标为 macOS 13，实际运行也取决于所用 Wine 和图形组件对系统版本的要求。请把项目放在自己可以写入且空间充足的位置。

在项目根目录执行：

```sh
zsh Source/prepare-runtime.sh
zsh Source/build.sh
open GalBox.app
```

准备脚本会下载并校验固定版本的依赖。应用、运行环境、游戏库都在项目目录内。如果要搬家，请先退出游戏和 GalBox，再移动整个目录。

## 导入与存档

1. 拖入完整资源包。有密码时先填写密码。分卷压缩包要放在同一目录，只拖第一卷。
2. 在游戏详情页确认主程序。日文原版默认使用日语环境，部分汉化版需要切为简体中文后重新启动。
3. Direct3D 10/11 游戏可尝试增强模式（DXVK 和 MoltenVK），较老游戏可尝试兼容模式。对于安装版，可先运行安装程序，再将安装完成的游戏目录复制到 GalBox 管理目录之外，以文件夹方式导入。

导入可能直接启动 Windows 程序，请使用可信且有权运行的游戏。Wine 进程以当前用户权限运行。

| 位置 | 用途 |
| --- | --- |
| `Games/<编号>/Files` | 完整游戏资源，以及保存在游戏目录的存档 |
| `Games/<编号>/Prefix`、`Prefix-Graphics` | 两种图形模式各自的 Windows 环境，游戏也可能将存档写在这里 |
| `library.json` | 游戏列表、主程序及设置 |
| `Logs/` | 导入、初始化和运行日志 |

备份时同时复制 `Games/` 和 `library.json`。切换图形模式后，两个 Windows 环境中的存档可能分别更新。游戏中请先保存再退出。

## 验证

```sh
GalBox.app/Contents/MacOS/GalBox --self-test
GalBox.app/Contents/MacOS/GalBox --runtime-test
```

第一项检查压缩包导入、日文路径和主程序识别。第二项需在可正常使用 Wine 的 Mac 登录会话中运行，检查 32 位和 64 位 Windows 程序。也可以使用应用的 Help 菜单检查运行环境。具体游戏的图形、音频和视频兼容性取决于其引擎。

## 开源与依赖

GalBox 原创代码及图标的授权见 [LICENSE](LICENSE)。依赖由准备脚本从上游获取，各组件沿用自己的许可证。项目仅分发启动器源码与图标。

- [Wine 与 macOS 构建](https://github.com/Gcenx/macOS_Wine_builds) 提供 Windows 运行环境，其构建包含 [MoltenVK](https://github.com/KhronosGroup/MoltenVK)。
- [7-Zip](https://github.com/ip7z/7zip) 用于读取压缩包。
- [DXVK-macOS](https://github.com/Gcenx/DXVK-macOS) 提供增强图形模式。
- [GStreamer](https://gstreamer.freedesktop.org/) 提供媒体解码组件。
