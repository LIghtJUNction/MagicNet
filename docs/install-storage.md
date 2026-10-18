# 安装文件的归属与历史清理

组件和安装状态归 MagicNet 模块管理。发布包不再把组件 ZIP、日志或升级备份长期放在模块目录外。标准位置为 `/data/adb/modules/MagicNet`；管理器暂存升级时使用 `/data/adb/modules_update/MagicNet`。

## 新版本的文件生命周期

以下路径均相对本次安装的模块目录。

| 路径 | 用途 | 清理时机 |
| --- | --- | --- |
| `bin/`、`webroot/`、`.config/sing-box/rules/` | 当前实际使用的组件 | 更新器按已安装清单替换或移除过时文件；卸载由管理器删除模块。 |
| `.components-install/` | 本次下载、校验及组件替换记录 | 成功或普通失败后删除；中断后下次安装先恢复，再清理。 |
| `.components-install/.downloads/` | 下载中的 ZIP 和部分文件 | 解压校验后删除；错误清理覆盖剩余下载。 |
| `.install-backup.<PID>/` | 当前升级的私有用户配置备份 | 正常结束或失败时删除；下次安装清理持有精确标记且进程已退出的备份。 |
| `.log/kam.log` | 安装及框架日志 | 留在模块内供检查；卸载随模块删除。 |
| `.config/sing-box/config.json.pre-upgrade` | 一份可恢复的旧配置 | 后续成功升级替换同一个文件，不按版本堆积。 |

组件更新器对模块目录加锁，安装进程退出或被强杀时由系统释放。修改前先记录替换计划；旧文件在完成前保留于私有工作目录。失败恢复可重复执行。恢复失败时保留这一份目录并返回错误，不能为了清理空间删除唯一恢复副本。

默认不保存组件 ZIP 缓存。连续升级直接复用校验通过的已安装文件。`--cache-dir` 只用于显式提供现成的离线 ZIP，文件名仍为 `<sha256>.zip`；程序只读取这个来源，不向它写入或删除文件。

安装日志优先使用空闲文件句柄，不覆盖管理器的输出通道。保持打开的日志在管理器删除失败安装的暂存目录后仍可写入；全部候选句柄被占用时使用普通模块内日志路径。两种情况均不创建外部缓存。

卸载时的可选告别页需要短暂独立于模块存活。其公开页面和运行文件放在 RAM 中的 `/dev/.magicnet-farewell.XXXXXX`；正常退出会删除，重启也会清除。该页面不保存配置或订阅。

## 临时的旧版本迁移

`installer/components/legacy_cleanup.go` 只负责 **v1.6.2 及以前版本**遗留的布局。发布包在组件、配置和订阅引导均成功后，通过 `--cleanup-legacy` 调用。正式卸载也尝试调用。它不是开机任务，没有后台循环。

入口先检查模块路径、路径中的符号链接以及唯一的 `id=MagicNet`。删除范围如下：

| 旧位置 | 必须满足的条件 |
| --- | --- |
| `/data/adb/magicnet-components/<sha256>.zip`、`.download-<数字>` | 缓存目录及文件不是符号链接；持有旧 `install.lock` 的独占锁。只删除这些已知普通文件。目录仅剩锁文件时才移除锁及空目录。 |
| `/data/adb/cache/MagicNet/kam.log`、`kam.log.1` | 物理目录内的普通文件。其他文件存在时保留目录。 |
| `modules/MagicNet.install-backup.<PID>`、`modules_update/MagicNet.install-backup.<PID>` | 进程已不存在；目录与标记不是符号链接；标记内容严格等于 `magicnet-install-backup-v1` 加一个换行。 |
| `/data/adb/.magicnet-farewell.XXXXXX` | 至少十分钟前创建，没有使用该路径的进程；worker、HTTP 配置、令牌及页面特征匹配；没有未知文件或符号链接。 |

旧缓存仍被使用、文件无法删除等情况会显示错误，并在下次安装或卸载重试。一个位置失败不会阻止其余位置的清理，也不会把成功的新配置回滚成旧配置。

不根据相似名称猜测所有权。未知文件、符号链接目标、无标记的旧备份，以及可能包含唯一旧组件的 `.magicnet-components-*` 恢复目录不会被递归删除。用户订阅、用户配置、网络恢复记录和导出文件保留。

### 必须移除的条件

**首个停止支持从 v1.6.2 及更早版本直接升级的版本，必须删除此迁移。** 该版本的升级说明应要求旧用户先安装包含本次迁移的过渡版本。不能在已经不支持旧布局后继续保留全局历史扫描。

同时移除：

1. `installer/components/legacy_cleanup.go` 和 `legacy_cleanup_test.go`。
2. `main.go` 中的 `--cleanup-legacy` 参数及分支。
3. `scripts/package-components.py` 中成功安装后的迁移调用。
4. `lib/magicnet/uninstall.sh` 中的迁移调用。
5. `lib/magicnet/i18n.sh` 中仅用于该迁移的 `MN_INSTALL_LEGACY_CLEANUP_FAILED`。

`.components-install/` 的正常清理、组件替换恢复、模块内备份清理属于长期生命周期，必须保留。移除的是对旧模块外路径的兼容代码。

## 验证

组件测试覆盖多版本下载后不积累 ZIP、重复安装复用、下载进程强杀、各个替换点中断、失败恢复、并发锁，以及历史清理对无关文件和符号链接的保护。真实打包回归运行核心包、完整包和安装器别名的首次安装与升级，覆盖 `sh` 和 BusyBox ash。

主机测试没有证明所有 Android 管理器、SELinux 策略和断电后的存储行为。设备验收应继续观察安装后首次重启、旧组件替换和卸载后的实际网络状态。
