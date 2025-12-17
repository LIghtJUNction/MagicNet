# KAM Utils 模块系统

## 模块结构

### 内部模块（非公开API）
- `_base.sh` - 基础内部函数
- `_detect.sh` - 系统检测内部实现
- `_ui.sh` - 用户交互内部实现

**注意：** 所有以下划线 `_` 开头的文件都是内部实现，不是公开API，可能会随时更改。请不要在项目中直接调用这些内部函数。

### 公开模块（API）
- `base.sh` - 基础工具函数：msg、err、rmrf等
- `detect.sh` - 系统检测：架构、Root类型、启动模式等
- `ui.sh` - 用户交互：ask、choice、confirm等
- `wait.sh` - 系统等待：wait_boot、wait_unlock等
- 以及其他 .sh 文件

### 自定义拓展模块
您可以在 kam_utils 目录中添加自己的 .sh 文件作为拓展模块。这些模块会被自动发现并可以通过 `kam_load` 加载。

示例：
```bash
# 加载基础工具
kam_load base

# 加载用户交互
kam_load ui

# 加载自定义模块（例如：my_tools.sh）
kam_load my_tools
```

## 使用方法

```bash
# 加载单个模块
kam_load module_name

# 加载多个模块
kam_load base ui detect

# 列出所有可用模块
list_modules

# 列出已加载模块
list_loaded_modules
```