# Repository Guidelines

## 项目结构与模块组织

SSCOM 是面向 Windows 10/11 x64 的 Flutter 串口与网络调试工具。

- `lib/app/`：启动、依赖组装、路由、主题和主工作区。
- `lib/core/`：共享传输接口、缓冲、编解码与 ISP 协议。
- `lib/features/`：按功能组织，沿用 `application/`、`domain/`、`infrastructure/`、`presentation/` 分层。
- `test/`：单元与 Widget 测试；`test/support/` 提供替身，`test/fixtures/` 保存协议、迁移及固件夹具。
- `assets/`：图片与图标；`windows/`：原生入口和 CMake 配置；`.github/workflows/`：Windows 构建发布流程。

## 构建、测试与开发命令

使用 Flutter 3.47.9 stable、Dart 3.13.7 和 Windows C++ 构建工具链。在仓库根目录执行：

| 命令 | 用途 |
| --- | --- |
| `flutter pub get` | 安装依赖 |
| `flutter run -d windows` | 启动桌面应用，默认使用真实串口后端 |
| `flutter analyze --no-pub lib test` | 执行静态分析 |
| `flutter test --no-pub` | 运行全部测试 |
| `flutter build windows --release --no-pub` | 构建 Windows 发布版本 |

无硬件开发时使用 `flutter run -d windows --dart-define=SSCOM_SERIAL_BACKEND=simulated`，启用回环模拟串口。

## 编码风格与命名

采用两空格缩进，运行 `dart format lib test`，遵循 `analysis_options.yaml` 配置的 `flutter_lints`。文件使用 `snake_case.dart`，类型使用 `UpperCamelCase`，成员使用 `lowerCamelCase`。文档注释使用中文 `///`，说明职责、生命周期与边界。

复用 Signals、GetIt、go_router 和现有传输接口；在 `lib/app/bootstrap.dart` 组装依赖，保持 Widget 与设备访问分离。异步任务、订阅和端口必须有明确的释放路径。

## 测试规范

使用 `flutter_test`，文件命名为 `*_test.dart`，按功能放入对应测试目录。修复缺陷时增加回归用例，覆盖输入边界、失败和资源释放；优先复用 `test/support/`，避免依赖真实设备。

单独运行示例：`flutter test --no-pub test/features/serial_backend_factory_test.dart`。当前未配置覆盖率门槛。兼容性修改需核对 `test/fixtures/legacy/`；夹具不能替代真实硬件验收。

## 提交与 Pull Request

现有历史采用中文 Conventional Commits，例如 `chore(repo): 初始化 SSCOM Flutter 项目`。沿用 `<type>(scope): 中文说明`，主题不超过 50 字符；破坏性变更注明迁移方式。

PR 应说明问题、改动范围、验证命令与结果，并关联相关 issue；UI 改动附截图，通信改动注明模拟或硬件验证范围。保持提交原子化，保留无关变更；代理仅在明确授权后提交、推送或发布。

## 访问与配置边界

代理不得读取、搜索或手工修改任意层级的 `.dart_tool/`、`build/`、`node_modules/`、`dist/`、`.git/`、`pubspec.lock` 或 `.env`；可使用只读 Git 命令。临时验证产物统一放入已忽略的 `/.cache/`，不得提交。不得将密钥、原始用户 INI、设备通信记录写入源码或夹具。
