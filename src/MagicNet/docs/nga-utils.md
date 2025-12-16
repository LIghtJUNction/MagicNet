# nga-utils
[docs](https://app.niggergo.work/docs/nga/shell)


| 函数名                | 示范用法                                                                 |
| :-------------------- | :----------------------------------------------------------------------- |
| run2null              | `run2null ls /nonexistent`  # 执行命令并屏蔽所有输出（stdout/stderr）     |
| run22null             | `run22null grep "keyword" file.txt`  # 执行命令仅屏蔽 stderr 输出        |
| until_key             | `key=$(until_key)`  # 监听按键输入（返回 up/down/power 等）               |
| until_key_any         | `until_key_any`  # 等待任意有效按键输入后继续执行                         |
| until_key_up_down     | `choice=$(until_key_up_down)`  # 仅监听音量加/减键输入                    |
| until_key_up_down_power | `action=$(until_key_up_down_power)`  # 监听音量加/减/电源键输入          |
| until_key_up          | `until_key_up`  # 等待音量加键按下后继续                                 |
| until_key_down        | `until_key_down`  # 等待音量减键按下后继续                               |
| until_key_power       | `until_key_power`  # 等待电源键按下后继续                                 |
| goto_url              | `goto_url "https://github.com"`  # 调用系统浏览器打开链接                |
| goto_app              | `goto_app "com.android.settings"`  # 启动指定包名的应用                  |
| str_eq                | `str_eq "apple" "banana" "apple" && echo "匹配"`  # 判断字符串是否在目标列表中 |
| pure_print            | `pure_print "模块安装中..."`  # 适配 Magisk ui_print 和普通终端输出       |
| nga_abort             | `[ ! -f "config.conf" ] && nga_abort "配置文件缺失"`  # 报错并终止脚本    |
| nga_print             | `nga_print "开始校验文件"`  # 带前缀的格式化输出                          |
| newline               | `newline 2`  # 输出 2 个空行（默认 1 个）                                |
| print_lines           | `print_lines "行1" "行2" "行3"`  # 批量打印多行文本                      |
| get_work_dir          | `dir=$(get_work_dir "/data/adb/script.sh")`  # 获取文件所在目录的绝对路径 |
| set_dir_perm          | `set_dir_perm "/data/adb/modules"`  # 批量设置目录权限为 755              |
| set_system_file       | `set_system_file "/system/vendor/bin"`  # 设置 SELinux 上下文为 system_file |
| pre_bin               | `pre_bin "/data/adb/mybin"`  # 给文件添加可执行权限                      |
| pre_bins              | `pre_bins "bin1" "bin2" "bin3"`  # 批量给文件添加可执行权限              |
| run_bin               | `run_bin "/data/adb/mybin" "--verbose"`  # 执行带参数的可执行文件        |
| nohup_bin             | `nohup_bin "/data/adb/daemon"`  # 后台运行可执行文件（忽略挂起信号）      |
| get_arch              | `arch=$(get_arch)`  # 获取设备 CPU 架构（如 arm64/x86）                   |
| get_app_lib           | `lib_path=$(get_app_lib "com.example.app" "core")`  # 获取应用的指定 so 库路径 |
| until_boot            | `until_boot 5`  # 等待系统启动完成（可选延迟 5 秒）                      |
| until_unlock          | `until_unlock 3`  # 等待设备解锁后继续（可选延迟 3 秒）                  |
| is_ssu                | `is_ssu && echo "当前是 ShiroSU 环境"`  # 判断是否为 ShiroSU 环境         |
| is_shirosu            | `is_shirosu && echo "当前是 ShiroSU 环境"`  # 同 is_ssu                  |
| is_ksu                | `is_ksu && echo "当前是 KernelSU 环境"`  # 判断是否为 KernelSU 环境       |
| is_kernelsu           | `is_kernelsu && echo "当前是 KernelSU 环境"`  # 同 is_ksu                |
| is_ap                 | `is_ap && echo "当前是 APatch 环境"`  # 判断是否为 APatch 环境             |
| is_apatch             | `is_apatch && echo "当前是 APatch 环境"`  # 同 is_ap                    |
| not_magisk            | `not_magisk && echo "非 Magisk 环境"`  # 判断是否为非 Magisk 环境         |
| is_magisk             | `is_magisk && echo "当前是 Magisk 环境"`  # 判断是否为 Magisk 环境        |
| nga_install_module    | `nga_install_module "/sdcard/module.zip"`  # 跨环境安装模块 zip 包        |
| nga_install_modules   | `nga_install_modules "zip1.zip" "zip2.zip"`  # 批量安装模块 zip 包        |
| magisk_run_completed  | `magisk_run_completed "$MODPATH"`  # Magisk 环境下执行开机完成脚本        |
| get_target_bin        | `get_target_bin "myexec"`  # 复制对应架构的可执行文件到 MODPATH          |
| get_target_bins       | `get_target_bins "exec1" "exec2"`  # 批量复制对应架构的可执行文件        |
| run_install_list      | `run_install_list "func" 2`  # 交互式批量选择安装功能（需定义 func 系列函数） |
| nga_install_init      | `nga_install_init official`  # 初始化模块安装（校验文件完整性）           |
| nga_install_done      | `nga_install_done`  # 模块安装完成后清理冗余文件/适配环境                |
