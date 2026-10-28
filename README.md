# AlipayFullscreenFix（rootless）

支付宝全屏黑边修复，逻辑移植自 `QQFullscreenFix 2.0.1`（Hook 点与判定条件逐条对齐）。
本机是 Windows，无法直接编译 iOS 插件；本仓库配好了 **GitHub Actions 云编译**，
推送上去就能在 Actions 里下载编译好的 `.deb`。

产出目标：**rootless**（`/var/jb`，Dopamine / palera1n 等 iOS 15+ 越狱）。

---

## 一、三步拿到 deb（不需要 git 命令行）

1. **新建 GitHub 仓库**：打开 https://github.com/new
   - Repository name：`AlipayFullscreenFix`
   - 选 **Public**（重要：公共仓库的 macOS 运行时间免费；私有仓库的 macOS 分钟按 10 倍计费）
   - 不要勾 "Add a README file"，保持空仓库
   - 点 Create repository

2. **上传这 6 个文件**（在空仓库页点 "uploading an existing file" 或者直接把文件拖进去）
   ```
   .github/workflows/build.yml
   Makefile
   Tweak.xm
   control
   AlipayFullscreenFix.plist
   .gitignore
   ```
   目录结构必须保持原样：`.github/workflows/build.yml` 在二级目录里。
   底部 Commit changes 提交。

3. **跑编译**：进仓库 → Actions 标签页 → 左侧 `Build AlipayFullscreenFix` →
   右侧 `Run workflow` → branch 选 `main`，scheme 选 `rootless` → 绿色 Run workflow。
   约 3–5 分钟跑完，点进这次 run，页面最下方 **Artifacts** 里下载
   `AlipayFullscreenFix-rootless-deb`，解压得到 `.deb`。

> 你也可以用 `git tag v1.0.0 && git push --tags`，会自动发布到 Releases 页面。

---

## 二、安装（rootless）

任选一种：

- **Filza / Sileo / Zebra**：把 deb 传到设备里，直接用 Filza 打开安装；Sileo 里用 "离线安装"。
- **SSH（最稳）**：
  ```bash
  scp com.karma.alipayfullscreenfix_1.0.0_iphoneos-arm64.deb root@<设备IP>:/var/mobile/
  ssh root@<设备IP>
  dpkg -i /var/mobile/com.karma.alipayfullscreenfix_1.0.0_iphoneos-arm64.deb
  killall AlipayWallet        # 让插件生效
  ```

装完确认文件落位：
```bash
ls /var/jb/Library/MobileSubstrate/DynamicLibraries/AlipayFullscreenFix.*
```

---

## 三、排障

**1. 完全没反应 —— 先确认插件有没有被注入**
插件启动时会打一行日志：
```
[AlipayFullscreenFix] loaded into com.alipay.iphoneclient ({{0, 0}, {390, 844}})
```
用控制台（或 `log stream --predicate 'eventMessage CONTAINS "AlipayFullscreenFix"'`）看。
**看不到这行**，说明是注入层的问题，和本插件逻辑无关，先检查：
- Filter 里的 Bundle ID 是否匹配你装的支付宝（`com.alipay.iphoneclient`）
- 你的注入方案是否支持第三方 App

**2. 注入了但黑边还在**
本插件有一个前置开关：**只有 `[UIScreen mainScreen].bounds` 已经等于 `nativeBounds/scale` 时才动手**
（原作者的前提是「你已经有别的注入改过屏幕尺寸了」）。上面那行日志里会打印 bounds，
拿它和设备的真实全屏尺寸对比一下，不一致就是前置条件不满足。

**3. 想看详细修正过程**
把 `Tweak.xm` 里 `AI_VERBOSE_LOG` 改成 `1`，重新跑一次 Actions，日志会打印每个被修正的 view。
这是定位「为什么某个容器没被修」最快的办法。

---

## 四、可调位置（全在 Tweak.xm 顶部）

| 位置 | 作用 |
|---|---|
| `kIgnoreKeywords` | 16 个类名关键字黑名单，被改坏的类名加到这 |
| `kAppContainerClasses` | 支付宝私有容器类候选名单；`objc_getClass` 返回 NULL 会自动跳过，命中不到零副作用 |
| `AIWatchdog` | 0.5 秒心跳；只在启动/转屏时复现的话改成 1~2 秒省开销 |
| `AI_VERBOSE_LOG` | 调试日志开关 |

---

## 五、本地有 Mac 时

```bash
export THEOS=~/theos
brew install make dpkg ldid
git clone --recursive https://github.com/theos/theos $THEOS

make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
```

> rootful 和 rootless 之间切换前必须 `make clean`，否则会残留错误的目标文件。
