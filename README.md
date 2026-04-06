# BlueStacks 同步器说明文档

## 0. 更新后重新授权

如果你替换了 `/Applications/BlueStacks Synchronizer.app`，macOS 可能会把它当成一份“新的 App 身份”。这时即使你之前已经勾选过：

- `辅助功能`
- `输入监控`

运行时也仍然可能提示缺权限，或者反复请求权限。

最稳的处理方式是：每次更新 App 后，都重新对安装版 App 签名，并重置一次权限记录，然后再重新授权。

### 0.1
```bash
pkill -f BlueStacksSynchronizer
pkill -f 'BlueStacks Synchronizer.app'
```

### 0.2 重新签名

```bash
codesign --force --deep --sign - "/Applications/BlueStacks Synchronizer.app"
```

### 0.3 重置权限记录

```bash
tccutil reset Accessibility local.codex.bluestacks-synchronizer
tccutil reset ListenEvent local.codex.bluestacks-synchronizer
```

### 0.4 重新授权步骤

1. 完全退出 `/Applications/BlueStacks Synchronizer.app`
2. 运行上面的签名和重置命令
3. 打开 `系统设置 -> 隐私与安全性`
4. 重新给 `BlueStacks Synchronizer.app` 开启：
   - `辅助功能`
   - `输入监控`
5. 再重新打开 `/Applications/BlueStacks Synchronizer.app`

### 0.5 为什么要这样做

这个问题通常不是“权限没开”，而是：

- App 被重新编译或替换过
- 安装版 App 的签名状态和之前不同
- TCC 里旧的授权记录没有正确绑定到当前这份二进制

所以修复重点不是反复点授权，而是：

- 先在保证输入监听安全的情况下，让 `/Applications` 里的安装版 App 重新获得稳定签名
- 再让 macOS 重新建立这份 App 的权限记录

建议以后每次更新安装版 App 后，都执行一次这一节里的流程。

## 1. 文档目的

这份文档同时承担两部分内容：

- 使用说明
- 技术说明

目标是让你既能直接使用这个 App，也能在后续需要时快速理解它的实现结构、关键逻辑和维护入口。

## 2. 项目位置

- GUI 入口：[main.swift](/Users/xenadia/Documents/Playground/tools/SynchronizerApp/Sources/main.swift)
- GUI 包定义：[Package.swift](/Users/xenadia/Documents/Playground/tools/SynchronizerApp/Package.swift)
- App 文件：[BlueStacks Synchronizer.app](/Users/xenadia/Documents/Playground/tools/SynchronizerApp/AppBundle/BlueStacks%20Synchronizer.app)
- 同步核心脚本：[window_sync.swift](/Users/xenadia/Documents/Playground/tools/Synchronizer/window_sync.swift)

## 3. 这是什么

这个 App 是 `BlueStacks` 双开同步器的图形界面版本。

它本身不直接重写同步逻辑，而是作为一个窗口控制层，负责：

- 扫描当前运行中的 `BlueStacks` 实例
- 展示源实例和目标实例供用户选择
- 启动底层同步脚本
- 停止底层同步脚本
- 在窗口里显示运行日志

真正负责输入同步的是：

- [window_sync.swift](/Users/xenadia/Documents/Playground/tools/Synchronizer/window_sync.swift)

## 4. 使用说明

### 4.1 安装与位置

工作区中的 App 文件位于：

- [BlueStacks Synchronizer.app](/Users/xenadia/Documents/Playground/tools/SynchronizerApp/AppBundle/BlueStacks%20Synchronizer.app)

如果已经复制到系统应用目录，可以直接从这里打开：

- `/Applications/BlueStacks Synchronizer.app`

### 4.2 启动前准备

使用前请确认：

- 已安装 `BlueStacks`
- 至少已经打开两个独立的 `BlueStacks` 实例
- 系统中已经给运行环境授予：
  - `辅助功能`
  - `输入监控`

如果权限没开，窗口发现、输入监听、同步转发都可能失效。

### 4.3 启动方式

最推荐的方式：

1. 打开 `访达`
2. 进入 `Applications`
3. 双击 `/Applications/BlueStacks Synchronizer.app`

如果第一次被系统拦截：

1. 打开 `系统设置 -> 隐私与安全性`
2. 找到被拦截的应用
3. 点击允许打开

### 4.4 标准使用流程

1. 打开两个 `BlueStacks` 实例
2. 启动 `BlueStacks Synchronizer.app`
3. 点击 `刷新实例`
4. 在 `源实例` 中选择你实际操作的窗口
5. 在 `目标实例` 中选择需要接收同步的窗口
6. 按需决定是否开启 `详细日志`
7. 点击 `开始同步`
8. 在源实例中进行键盘或鼠标操作
9. 观察目标实例行为和窗口日志
10. 结束时点击 `停止`

### 4.5 当前界面功能

窗口中当前包含以下功能区：

- `源实例`
  选择你正在操作的 BlueStacks 窗口

- `目标实例`
  选择接收同步操作的 BlueStacks 窗口

- `详细日志`
  控制是否输出更详细的底层同步日志

- `刷新实例`
  重新扫描当前运行中的 BlueStacks 进程

- `开始同步`
  启动底层同步脚本

- `停止`
  停止当前同步脚本

- `运行日志`
  实时显示脚本输出的日志

### 4.6 当前已验证的能力

当前已经验证过的同步路径包括：

- 根据目标实例前台 app 自动匹配对应的 BlueStacks 键位配置
- 解析 BlueStacks cfg 中的 `Tap` 类型键位
- 通过 ADB 在目标实例执行点击
- 左键点击通过 Android 触控路径同步
- GUI 选择源/目标实例并启动同步核心

### 4.7 常见问题

#### 4.7.1 App 打开后立刻消失

如果出现这种情况，通常是旧版本包装器导致。

当前应该使用的是独立编译后的 App：

- `/Applications/BlueStacks Synchronizer.app`

#### 4.7.2 打开后看不到实例

请检查：

- `BlueStacks` 是否已经运行
- 是否是独立窗口
- 是否点击过 `刷新实例`
- 是否已经授权 `辅助功能`

#### 4.7.3 开始同步后没有效果

请先看日志，重点确认：

- 源和目标 PID 是否正确
- ADB serial 是否识别成功
- 是否识别到了前台包名
- 是否读取到了正确的 cfg

#### 4.7.4 键盘有效，鼠标没效果

这通常不是 GUI 层问题，而是目标 BlueStacks 对宿主鼠标事件或当前同步路径的接受方式不同，需要继续看底层同步脚本日志和实现。

## 5. 技术说明

### 5.1 整体架构

当前结构是“两层分离”：

1. GUI 层  
   用 `SwiftUI` 提供窗口、实例选择、按钮、状态和日志显示。

2. 同步核心层  
   由 [window_sync.swift](/Users/xenadia/Documents/Playground/tools/Synchronizer/window_sync.swift) 提供，负责：
   - 监听键盘事件
   - 监听鼠标事件
   - 识别 BlueStacks 实例
   - 自动连接目标 ADB
   - 读取 BlueStacks 键位配置
   - 将输入转换为目标实例可接受的 ADB 触控或事件

GUI 不直接把同步实现写在窗口里，而是通过子进程调用同步脚本。这么做的好处是：

- 保留已经验证成功的同步逻辑
- 降低 GUI 改动对同步核心的影响
- 方便定位问题是在 GUI 层还是同步层

### 5.2 GUI 代码结构

GUI 主程序位于：

- [main.swift](/Users/xenadia/Documents/Playground/tools/SynchronizerApp/Sources/main.swift)

主要由三部分组成：

#### `ProcessCandidate`

作用：

- 表示一个可选择的 BlueStacks 实例
- 保存 `pid`、应用名、Bundle ID、窗口标题

用途：

- 提供给源/目标下拉选择器使用

#### `AppModel`

作用：

- GUI 的状态中心
- 管理窗口中的候选实例、当前选择、运行状态和日志文本
- 管理同步脚本子进程

主要状态包括：

- `candidates`
- `sourcePID`
- `targetPID`
- `verbose`
- `isRunning`
- `statusText`
- `logText`

主要方法包括：

- `refreshProcesses()`
- `start()`
- `stop()`

#### `ContentView`

作用：

- 负责渲染窗口界面
- 绑定源实例和目标实例选择器
- 提供刷新、开始、停止按钮
- 展示日志文本框

### 5.3 进程发现逻辑

GUI 通过 `discoverCandidates()` 扫描进程。

扫描逻辑基于：

- `NSWorkspace.shared.runningApplications`

筛选规则包括：

- 只保留图形应用
- 排除当前 GUI 进程自身
- 排除 `BlueStacksMIM`
- 通过应用名、Bundle ID、窗口标题匹配 `BlueStacks`

窗口标题读取通过辅助功能接口完成，使用到：

- `AXUIElementCreateApplication`
- `kAXFocusedWindowAttribute`
- `kAXMainWindowAttribute`
- `kAXTitleAttribute`

这也是为什么 GUI 本身同样依赖 `辅助功能` 权限。

### 5.4 GUI 如何启动同步核心

当用户点击 `开始同步` 时，GUI 会创建一个 `Process`，执行：

```text
swift /Users/xenadia/Documents/Playground/tools/Synchronizer/window_sync.swift --source-pid <pid> --target-pid <pid> --verbose
```

这部分逻辑位于：

- [main.swift](/Users/xenadia/Documents/Playground/tools/SynchronizerApp/Sources/main.swift)

另外 GUI 还会为这个子进程设置：

- `SWIFT_MODULECACHE_PATH=/tmp/swift-module-cache`
- `CLANG_MODULE_CACHE_PATH=/tmp/clang-module-cache`

目的是减少 Swift 运行时在缓存目录上的权限问题。

### 5.5 日志管线

GUI 使用两个 `Pipe` 接收子进程输出：

- `standardOutput`
- `standardError`

然后通过 `NSFileHandleDataAvailable` 监听数据，并把文本追加到界面中的日志框。

当前日志策略是：

- 标准输出原样显示
- 标准错误加前缀 `[stderr] `

这能帮助快速区分脚本正常输出和异常信息。

### 5.6 同步核心的工作方式

同步核心位于：

- [window_sync.swift](/Users/xenadia/Documents/Playground/tools/Synchronizer/window_sync.swift)

它当前的关键逻辑包括：

- 读取 BlueStacks 配置文件中的实例信息
- 动态识别实例对应的 ADB 端口
- 必要时自动执行 `hd-adb connect`
- 根据目标实例前台 app 自动选择对应 cfg
- 解析 BlueStacks 键位映射中的 `Tap` 控件
- 把按键转换成 Android 层的 `tap`
- 把部分鼠标行为转换成 Android 层的触控动作

### 5.7 App 打包方式

当前 App 文件位于：

- [BlueStacks Synchronizer.app](/Users/xenadia/Documents/Playground/tools/SynchronizerApp/AppBundle/BlueStacks%20Synchronizer.app)

之前尝试过用 `.app` 内部直接执行 `swift run` 的方式启动 GUI，但 Finder 双击启动时会遇到 SwiftPM 的缓存和沙箱问题，导致 App 启动后立即退出。

当前方案已经调整为：

- 先将 GUI 代码编译为独立可执行文件
- 再把可执行文件放入 `.app/Contents/MacOS/`

因此现在双击 `.app` 时，不再依赖 `swift run`。

### 5.8 维护入口

如果要改同步逻辑，优先看：

- [window_sync.swift](/Users/xenadia/Documents/Playground/tools/Synchronizer/window_sync.swift)

如果要改窗口界面、选择流程、日志展示或按钮行为，优先看：

- [main.swift](/Users/xenadia/Documents/Playground/tools/SynchronizerApp/Sources/main.swift)

如果要重新打包 App，关注：

- [BlueStacks Synchronizer.app](/Users/xenadia/Documents/Playground/tools/SynchronizerApp/AppBundle/BlueStacks%20Synchronizer.app)

### 5.9 当前限制

当前仍有这些限制：

- GUI 只是同步器的图形控制层，不是完整重写版同步内核
- 暂无暂停/恢复按钮
- 暂无配置文件选择界面
- 暂无热键设置界面
- 日志当前只保存在内存中，没有单独落盘

## 6. 后续建议

如果继续迭代，推荐顺序是：

1. 增加暂停/恢复功能
2. 在 GUI 中显示当前目标包名、ADB serial、cfg 文件路径
3. 增加日志落盘
4. 增加高级设置入口
5. 逐步把同步核心抽成可复用模块，而不是完全依赖脚本子进程
