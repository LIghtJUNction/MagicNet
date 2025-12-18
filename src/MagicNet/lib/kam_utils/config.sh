# shellcheck shell=ash
# =============================================================================
# Config 模块 - 公开 wrapper（将复杂性放到内部实现）
# =============================================================================
#
# 公开函数：
#   config_set_subscription_url <config_file> <url>
#     - 直接把订阅 URL 写入指定配置文件
#   config_set_subscription_url <url>
#     - 使用模块约定的默认路径：$MODDIR/mihomo/config.yaml
#
# 设计原则：公开接口尽量简洁，复杂的写入/回退逻辑由内部实现负责（_config.sh）
# =============================================================================
MODDIR=${MODDIR:-${0%/*}}
# shellcheck source=_config.sh
kam_source_impl config || { echo "错误: 无法加载内部实现: _config.sh" >&2; return 1; }

# 用法（通用）:
#   config_set <yaml_path> <value>                     # 使用默认文件 $MODDIR/mihomo/config.yaml
#   config_set <config_file> <yaml_path> <value>       # 指定文件
config_set() {
    case "$#" in
        2)
            path="$1"
            value="$2"
            case "$path" in
                .* ) _path="$path" ;;
                *  ) _path=".$path" ;;
            esac
            _config_set_value "${MODDIR}/mihomo/config.yaml" "$_path" "$value"
            ;;
        3)
            cfg="$1"
            path="$2"
            value="$3"
            case "$path" in
                .* ) _path="$path" ;;
                *  ) _path=".$path" ;;
            esac
            _config_set_value "$cfg" "$_path" "$value"
            ;;
        *)
            printf '%s\n' "Usage: config_set <yaml_path> <value>  OR  config_set <config_file> <yaml_path> <value>" >&2
            return 2
            ;;
    esac
}
