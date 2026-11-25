
## 构建记录（本机实测）

- 环境：Flutter 3.47.9（`D:/build-env-dl/flutter`）、Dart 3.13.7、JDK 21、Android SDK `platforms;android-37.0` + `build-tools;37.0.0`、NDK 28.2.13676358、雷电模拟器（x86_64）用于冒烟验证。
- 依赖：`flutter pub get --enforce-lockfile`（官方 pub.dev；`PUB_HOSTED_URL` 指向国内镜像会把 `pubspec.lock` 里的下载地址改写，导致锁文件漂移，故镜像只用于 Flutter 本体下载）。
- 本机踩到并已在仓库内解决的四件事：
  1. `git` 未开长路径 → pub 缓存里 `flutter_inappwebview_android` 等包的文件被静默截断（编译报 `ContentBlockerTriggerResourceType` 找不到）。修复：`git config core.longpaths true` 并对 `%LOCALAPPDATA%/Pub/Cache/git/*` 执行 `git reset --hard`。仓库新增 `tool/apply_android_framework_patches.sh`，只做“应用补丁或不应用”，不 reset、不删缓存。
  2. `bin/flutter.bat` 的 PowerShell 引导在本机会挂起 → 用同一份 SDK 的 `dart.exe + flutter_tools.snapshot` 直接调用（Gradle 内部的 `flutter.bat` 调用同理）。
  3. 文件沙箱只允许本会话工作区内写入 → 工程必须放在工作区目录内编译（放在 `D:` 盘时 clang/CMake 报 `unable to make temporary file: Permission denied`）。
  4. `jni` 等插件的 CMake 默认把 `.cxx` 写进 pub 缓存目录（只读）→ 在 `android/build.gradle.kts` 里把 `buildStagingDirectory` 重定向到 `build/cxx/<module>`。
- 产物：
  - `dist/PiliPlus-dafeiyu-arm64-release.apk`（37.5 MB，arm64，应用名“PiliPlus 净评”，包名 `com.example.piliplus.dafeiyu`）
  - `dist/PiliPlus-dafeiyu-x86_64-debug.apk`（调试包，模拟器用）
  - `dist/SHA256SUMS.txt`
- 签名：仓库没有 `key.properties`，release 包用 Android **debug 证书**签名（上游 CI 的默认回退）。这适合自用，但不适合发布；换签名后无法覆盖安装，需先卸载。

## 验证记录

- 自动化：63 项测试全部通过（`test/dafeiyu_{judge,core,runner,widgets}_test.dart`），覆盖规则四档/简繁/邮箱与回复前缀、置顶与子树豁免、三种楼中楼策略、计数去重与容量上限、账号隔离、账本写盘失败、50 人分批与去重、非本人稿件拒绝、过期会话、`-509` 退避、`-352`/`-401`/`-403` 立即停止、模糊网络结果不重发、并发互斥、确认前零请求。
- 静态分析：无 error/warning（仅少量风格 info）。
- 模拟器冒烟（雷电，x86_64）：安装启动 → 我的 → 设置 → 评论设置 → **大肥鱼评论屏蔽** → 开启并加自定义词 `666` → 打开视频“评论”页 → 横幅显示 **“已屏蔽 1 条（主 1 / 子 0）”** 且该评论已不在列表；`评论详情` 浮层同样显示横幅。截图见 `.tmp/app5.png`、`.tmp/app10.png`。
- 未执行：任何真实账号的删评/拉黑写请求（测试后端全部为假实现）。

## 已知限制

- 评论区搜索（`searchItem`）结果未接过滤。
- 从深链直接进入楼中楼详情时，主列表的即时移除依赖控制器监听；没有主列表实例时只能靠下次刷新。
- 切换账号/登出会作废所有会话与在途任务；“已屏蔽 N 条”归零属预期。
- 批量删评只开放给能确认归属的普通视频（type=1）；动态、专栏、番剧评论区需要后续适配。

## 发布流程（PiliPlus EE）

仓库：<https://github.com/umeabc/PiliPlus>，分支 `ee`，`upstream` 指向上游 `bggRGjQaUbCoE/PiliPlus`。

```bash
# 1) 同步上游
git fetch upstream main && git checkout ee && git merge upstream/main

# 2) 版本号：versionName = 上游版本 + "-e<N>"，versionCode 每次发布 +1
flutter build apk --release --target-platform android-arm64 \
  --build-name=2.2.1-e1 --build-number=1 --no-pub

# 3) 归档与校验
cp build/app/outputs/flutter-apk/app-release.apk dist/PiliPlus-EE-<版本>-arm64.apk
sha256sum dist/*.apk > dist/SHA256SUMS.txt

# 4) 打 tag 并发布（凭据从 Git Credential Manager 读取）
git tag -f v<版本> -m "PiliPlus EE <版本>" && git push origin v<版本>
bash tool/publish_release.sh
```

- 签名密钥：`android/app/key.jks`（别名 `piliplus-ee`，RSA 4096，有效期 100 年），口令在 `android/key.properties`；两者都被 `.gitignore` 排除。备份放在仓库外的 `.keystore-backup/`。
- **密钥或口令丢失就无法再覆盖升级已装版本**，请离线备份两份。
- 应用标识固定为 `com.umeabc.piliplus`（debug 为 `.debug`），不要随意修改，否则用户侧会变成“新应用”并丢失本地设置与账本。
- 已发布：<https://github.com/umeabc/PiliPlus/releases/tag/v2.2.1-e1>

## 多客户端（与上游同步）

本 fork 与上游共用同一份 Dart 代码，功能天然覆盖 Android / Windows / Linux / macOS / iOS；差异只在平台壳层。

- 上游 `2.2.1` 发布矩阵：Android（arm64 / armeabi-v7a / x86_64）、iOS `.ipa`、Linux（AppImage / deb / rpm / tar.gz）、macOS `.dmg`、Windows（portable zip / setup exe）。
- 同步状态：`ee` 与 `main` 已对齐上游 `217fb54`（0 提交落后）；`upstream` 远端指向 `bggRGjQaUbCoE/PiliPlus`。
- 平台显示名已统一为 **PiliPlus EE**：Android `app_name`、Windows 窗口标题与 `Runner.rc`、Linux GTK 标题、macOS `PRODUCT_NAME`、iOS `CFBundleDisplayName`。
  - 二进制名（`piliplus.exe`）与 Linux `APPLICATION_ID` 保持上游值，避免破坏打包脚本与 `.desktop` 关联。
- 构建途径：GitHub Actions（fork 的 `main` 分支已注册 5 个 workflow）。本机只能产出 Android；Windows/Linux 在 GitHub 云端 runner 构建，macOS 需 macOS runner，iOS 需 Apple 签名证书（未配置）。
- 触发方式：Actions → 选择 workflow → Run workflow（分支 `main`）→ 运行结束后下载 artifact。

### 各平台产物（v2.2.1-e1）

| 平台 | 文件 | 说明 |
|---|---|---|
| Android | `PiliPlus-EE-2.2.1-e1-arm64.apk` | 本地构建，专属签名 |
| Windows | `PiliPlus_EE_2.2.1-e1_windows_x64_portable.zip` / `_setup.exe` | GitHub Actions `win_x64.yml` |
| Linux | `_linux_amd64.AppImage` / `.deb` / `.rpm` / `.tar.gz` | GitHub Actions `linux_x64.yml` |
| macOS | `PiliPlus_macos_2.2.1-e1.dmg` | GitHub Actions `mac.yml`（未签名） |
| iOS | 无 | 需要 Apple 开发者证书与描述文件，未配置 |

CI 产物的版本号字符串沿用上游脚本（`2.2.1+<提交数>`），归档时统一改名为 `2.2.1-e1`；`SHA256SUMS.txt` 覆盖全部资产。

桌面端与移动端共用同一份 Dart 业务代码，功能一致；Android 独有的是 `resValue` 应用名与专属签名。
