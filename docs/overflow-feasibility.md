# 菜单栏溢出获取验证

本文保留 2026-10-14 的阶段验证记录。当前交互、收回规则及已知兼容性见[操作与兼容性说明](interaction.md)。

2026-10-14，在本机 macOS 上运行 `scripts/probe-menu-bar-overflow.swift`：创建 40 个宽 80 点的测试项，将它们放到菜单栏靠右的可见分组，等待 1.5 秒后读取 WindowServer；结束自动移除测试项。判断“自然溢出”同时要求坐标位于屏幕左侧之外，且仍在 wd-ice-bar 分隔项的可见侧，避免把主动隐藏误当成容量溢出。

实际输出：

```text
PROBE created=40 enumerated=40 offscreen=24 offscreenImageAvailable=0 naturallyOverflowedOnVisibleSide=24 permission=true
```

结论：此环境下容量溢出并未导致窗口 ID 丢失；但当前 CGWindowListCreateImage 接口无法获得这些测试项的屏幕外图像。此测试证明枚举能力，不证明所有第三方应用的截图或点击能力。测试项不是所有第三方状态项的完整代表。

## 已实现

- 虚拟条候选包含分隔项隐藏侧，以及当前显示器可见区域之外的溢出项；刘海屏使用刘海右侧区域判断。
- 有原始截图时展示截图；失败时先保留该窗口的历史图像，再使用已确认应用的图标；仍不可用时保留真实项目并明确标记，避免单屏状态下丢项。
- 未识别的条目不生成进程首字母占位图；原有移除和恢复机制继续适用。

## 单屏点击与项目保留修复

2026-10-14 再次测试，单屏的 WindowServer 列表不再提供之前用于恢复第三方应用身份的后台副本。真实 Item-0 窗口仍在，但身份与截图可能都不可用；原代码因此丢弃真实项目。现在按窗口 ID、宿主 PID、标题校验后保留历史身份与图像；没有图像也保留真实候选并明确标记。不用相同 Item-0 标题跨窗口共享图像。

点击流程已改为记录原邻接项、将目标单独临时移入有空间的可见区、确认位置、发送带 WindowID/PID 的原生事件并恢复原位置。移动失败时也尝试还原；普通菜单在外部点击或 Escape 后恢复，退出应用前也尝试恢复。

可复现脚本：`./scripts/verify-menu-bar-overflow.sh`。本机单屏真实结果：

```text
PRESERVATION baseline=9 missingAfterFill=0
CLICK temporarilyMoved=true routed=true nativeReceipts=1
RESTORE 已移动
```

此结果验证一个由临时测试应用托管的真实 NSStatusItem 的完整事件链，以及同场景下九个原有应用项目未丢失；不能代替所有第三方应用和多显示器的完整验证。

## 尚待验证和实现

- 新增应用和显示器变化的自动同步、应用菜单遮挡区域检测，仍需完善；虚拟条已支持横向滚动。
- 第三方菜单生命周期、多显示器切换和未能恢复图像的项目仍需实测。

参考：[Ice 的临时显示与恢复实现](https://github.com/jordanbaird/Ice/blob/main/Ice/MenuBar/MenuBarItems/MenuBarItemManager.swift)、[Ice 图像缓存](https://github.com/jordanbaird/Ice/blob/main/Ice/MenuBar/MenuBarItems/MenuBarItemImageCache.swift)。


## 真实图像与指针保护优化

增加 ScreenCaptureKit：截图实际显示器顶部菜单栏，再按窗口矩形裁切；只缓存截图前后窗口 ID、宿主 PID、标题和矩形都一致的结果，避免位置变化导致图像串项。屏幕外表面仍不能直接取得原图时，可临时移入可见区补采，再恢复原位置。启动时预采可见项目，首次打开缺图项时补采一次，显式刷新可以重试。

模拟事件确实会改变系统指针位置，原实现未还原。现在注入期间隐藏指针、等待原生拖拽位置确认、点击后等待宿主处理、再恢复到最近真实鼠标输入的位置；不把鼠标锁在整个菜单打开之前的旧位置。持续真实输入时先等待空闲，不强抢拖拽。

真实验证：

```text
PRESERVATION baseline=9 missingAfterFill=0
IMAGE capturedVisible=6 targetHasRealImage=true
CLICK temporarilyMoved=true routed=true nativeReceipts=1
RESTORE 已移动
CURSOR gestures=7 maxRestoreError=0.94
CURSOR displacementAfterRoundTrip=0.94 hardwareMoves=0
```

偏移单位为 CoreGraphics 全局坐标点。曾出现较大整体位移，但同时记录到 143 次真实硬件移动，因此不能将用户主动移动误当成系统漂移。最终上面的静止输入测试单独验证了恢复误差。

原生图标在临时移位时仍可能短暂出现，这与指针漂移是两件事；当前方案需要真实位置来打开原生菜单，不能承诺完全消除顶部位置变化。


## 原生菜单跟踪与点击后指针恢复的修复

普通应用下拉菜单打开后，将指针立即还原到已关闭的虚拟面板会触发部分应用的菜单关闭行为。点击成功时现在只解除指针隐藏，不回跳原位置；拖拽、图像补采、点击失败以及无菜单的测试回执继续保护/恢复指针。真正结束菜单操作后再恢复图标位置。

本机真实 NSMenu 回归验证：`./scripts/verify-menu-bar-overflow.sh --native-menu`：

```text
NATIVE_MENU opens=1 closesBeforeDismiss=0
RESTORE 已移动
```

菜单在点击后 750 毫秒内保持打开，之后由测试程序主动关闭。此模式的整体鼠标位移是有意留在原生菜单位置，不能套用无菜单回执模式的“回到起点”判定。
