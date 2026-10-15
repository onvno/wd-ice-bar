# wd-ice-bar

轻量的 macOS 菜单栏管理工具：隐藏不常用的图标，通过虚拟菜单打开原生应用菜单，也可访问菜单栏放不下的溢出项。

![使用演示](docs/bar-wd.gif)

## 使用

- 左键顶部控制图标：打开虚拟菜单；点击其中的图标打开对应应用菜单。
- 右键虚拟图标：打开原生右键菜单，或从虚拟菜单移除该项目。
- 右键顶部控制图标 → **调整菜单显隐**：拖动图标跨过蓝线，左侧显示、右侧隐藏。
- 顶部右键菜单还可刷新应用、恢复已移除项目、设置开机启动和切换图标。

点击时只临时显示目标图标；用户结束交互后再收回。Macshot 的菜单首次打开仍可能立即关闭，此时真实图标会保留，可直接再点一次。

## 权限

在系统设置中允许：

- **屏幕录制**：获取真实图标图像。
- **辅助功能**：点击和移动原生菜单栏图标。
- **菜单栏 → 允许在菜单栏中显示 → wd-ice-bar**：保持主程序控制项可用。

图标无法显示、顶部入口找不到等问题，见[操作与兼容性说明](docs/interaction.md)。

## 构建与运行

需要 macOS 14+、Swift 6 和可用的 Apple Development 签名证书。

```bash
./scripts/build-app.sh
open build/wd-ice-bar.app
```

可通过 `WD_ICE_BAR_SIGNING_IDENTITY` 指定签名证书。测试命令：

```bash
swift test --disable-sandbox
```

## 更多说明

- [操作、兼容性与验证](docs/interaction.md)
- [溢出验证记录](docs/overflow-feasibility.md)
- [与 Ice 的实现对照](docs/ice-comparison.md)
- [项目背景](docs/desc.md)

参考实现：[Ice](https://github.com/jordanbaird/Ice)。项目依赖私有 WindowServer 接口，兼容性可能随 macOS 版本变化。
