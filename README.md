# NoSleep

一个轻量的原生 macOS 菜单栏防休眠工具（类似 Amphetamine），采用 **Swift + SwiftUI (`MenuBarExtra`) + IOKit (`IOPMAssertionCreateWithName`)** 构建，支持 **macOS 13.0+**（Apple Silicon & Intel 通用二进制），兼容 App Sandbox，无任何第三方依赖或外部 `caffeinate` 子进程调用。

## 功能特性

- **纯菜单栏驻留**：通过 `LSUIElement = true` 隐藏 Dock 图标，使用原生 SwiftUI `MenuBarExtra(.window)` 呈现弹出面板。
- **双模式防休眠（原生 IOKit 电源断言）**：
  - **保持屏幕常亮**：`kIOPMAssertionTypeNoDisplaySleep`（阻止显示器与系统休眠）
  - **仅保持系统运行 / 允许息屏**：`kIOPMAssertionTypeNoIdleSleep`（允许显示器休眠，保持后台运行）
  - 切换模式或重启会话时原子释放旧 `IOPMAssertionID`，防止电源断言泄漏。
- **定时防休眠**：支持无限期（`⌘I`）、分钟预设（5 / 15 / 30 / 45 分钟）、小时预设（1 / 2 / 4 / 8 小时）以及自定义时长 / 直到指定时刻（`⌘O`），面板内实时显示 `HH:MM:SS` 倒计时并归零自动释放。
- **菜单栏状态反馈**：支持闪电（`bolt.fill` / `bolt.slash`）与咖啡杯（`cup.and.saucer.fill` / `cup.and.saucer`）两套 SF Symbols，可选在图标旁显示剩余倒计时。
- **生命周期兜底**：监听 `NSApplication.willTerminateNotification` 并在 `deinit` 中强制释放活动断言。

## 安装使用

### 方式一：直接下载 Release 压缩包

1. 前往 [GitHub Releases](https://github.com/Collapsar-Echo/NoSleep/releases) 下载最新版本的 `NoSleep-macOS.zip`。
2. 解压后将 `NoSleep.app` 拖入 `/Applications`（应用程序）目录。
3. 由于本项目为开源自签（未经过 Apple Developer 公证），首次打开如遇到 macOS Gatekeeper 提示「无法验证开发者」，可在终端执行以下命令后重新打开：

```bash
xattr -dr com.apple.quarantine /Applications/NoSleep.app
```

### 方式二：本地一键打包（无需完整 Xcode）

只需安装 Xcode Command Line Tools，即可在仓库根目录直接生成 Universal Binary（`arm64 + x86_64`）应用包与 Release 压缩包：

```bash
./scripts/build_app.sh
```

构建产物位于 `dist/` 目录：
- `dist/NoSleep.app`：可直接双击运行或拖入 `/Applications`
- `dist/NoSleep-macOS.zip`：可直接上传至 GitHub Releases

如需自定义 Bundle ID 或指定开发者签名证书，可通过环境变量传入：

```bash
BUNDLE_ID="com.example.NoSleep" SIGN_IDENTITY="Developer ID Application: Your Name" ./scripts/build_app.sh
```

## 项目结构

```text
NoSleep/
├── Package.swift
├── scripts/
│   └── build_app.sh                # 一键编译打包为 Universal .app 与 .zip
├── NoSleep/
│   ├── App.swift                   # SwiftUI @main 与 MenuBarExtra 入口
│   ├── SleepManager.swift          # 线程安全 IOKit 电源断言与定时状态机
│   ├── MenuBarView.swift           # 菜单栏弹出面板视图
│   ├── Info.plist                  # LSUIElement = true 等配置
│   └── NoSleep.entitlements        # App Sandbox 权限配置
└── Tests/
    └── NoSleepTests/
        └── SleepManagerTests.swift # SleepManager 单元测试
```
