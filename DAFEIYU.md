
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
