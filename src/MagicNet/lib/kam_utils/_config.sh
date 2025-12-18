# shellcheck shell=ash
# =============================================================================
# Internal config helpers - 更新配置文件中的订阅 URL（优先使用 yq，回退为文本替换）
# =============================================================================
#
# 提供函数：
#   _config_set_subscription_url <config_file> <url>
#     - 尝试将 `proxy-providers.myclash.url` 写入指定的 YAML 配置文件
#     - 优先使用 `yq`（若可用），否则使用文本替换（awk -> sed -> append）
#
# 设计目标：
#   - 简洁、可重用：把复杂性放到库里，调用方尽量保持简单（如 subscribe.sh）
#   - 在无法精确修改嵌套 YAML 时采用保守回退（替换第一个 url: 行 / 追加结构）
# =============================================================================

# Minimal dev-phase setter: prefer yq (YAML/JSON) or jq (JSON).
# 不做复杂的文本回退或格式推断（开发阶段无需兼容性）。
# 用法: _config_set_value <config_file> <dot.path> <value>
_config_set_value() {
    cfg="${1:-}"
    path="${2:-}"
    value="${3:-}"

    [ -n "$cfg" ] || return 1
    [ -n "$path" ] || return 1

    msg "[DEBUG] _config_set_value: file='$cfg' path='$path' value='$value'"

    # 1) 尝试使用 yq（处理 YAML 与 JSON）
    if command -v yq >/dev/null 2>&1; then
        yq_path="$path"
        case "$yq_path" in
            .* ) ;;    # already dotted
            *  ) yq_path=".$yq_path" ;;
        esac
        if yq e "${yq_path} = \"${value}\"" -i "$cfg" >/dev/null 2>&1; then
            msg "[DEBUG] _config_set_value: written by yq"
            return 0
        fi
        msg "[ERROR] _config_set_value: yq failed to write"
        return 1
    fi

    # 2) 若为 JSON 且 jq 可用，则使用 jq 设置路径
    # 简单检测 JSON（扩展名或首字符）
    is_json=0
    case "$cfg" in
        *.json) is_json=1 ;;
        *) first_nonblank=$(sed -n '1p' "$cfg" | sed 's/^[[:space:]]*//'); case "$first_nonblank" in '{'|'[') is_json=1 ;; esac ;;
    esac

    if [ "$is_json" -eq 1 ] && command -v jq >/dev/null 2>&1; then
        path_no_dot=$(printf '%s' "$path" | sed 's/^\.//')
        OLDIFS=$IFS; IFS='.'; set -- $path_no_dot; IFS=$OLDIFS
        arr=''
        for k in "$@"; do
            esc_k=$(printf '%s' "$k" | sed 's/\"/\\\"/g')
            arr="${arr}\"${esc_k}\","
        done
        arr="[${arr%,}]"
        tmpj=$(mktemp "${TMPDIR:-/tmp}/jq.XXXXXX" 2>/dev/null || printf '%s' "$cfg.tmp.jq.$$")
        if jq --arg v "$value" "setpath(${arr}; \$v)" "$cfg" >"$tmpj" 2>/dev/null; then
            mv "$tmpj" "$cfg" 2>/dev/null || { rm -f "$tmpj" 2>/dev/null || true; return 1; }
            msg "[DEBUG] _config_set_value: written by jq"
            return 0
        else
            rm -f "$tmpj" 2>/dev/null || true
            msg "[ERROR] _config_set_value: jq failed to write"
            return 1
        fi
    fi

    msg "[ERROR] _config_set_value: need yq (for YAML/JSON) or jq (for JSON); aborting"
    return 1
}


# 更新订阅 URL 的内部实现（带文本回退）
# 用法: _config_set_subscription_url <config_file> <url>
_config_set_subscription_url() {
    cfg="${1:-}"
    url="${2:-}"

    [ -n "$cfg" ] || return 1
    [ -n "$url" ] || return 1

    msg "[DEBUG] _config_set_subscription_url: file='$cfg' url='$url'"

    # 首先尝试使用通用 setter（yq / jq）
    if _config_set_value "$cfg" ".proxy-providers.myclash.url" "$url" >/dev/null 2>&1; then
        msg "[DEBUG] _config_set_subscription_url: written by _config_set_value"
        return 0
    fi

    msg "[WARN] _config_set_subscription_url: _config_set_value failed, falling back to text replacement"

    tmp="$(mktemp "${TMPDIR:-/tmp}/mkcfg.XXXXXX" 2>/dev/null || printf '%s' "$cfg.tmp.$$")"

    # 尝试替换默认占位符（首个出现的 url: https://example.com/api）
    if awk -v url="$url" '
    BEGIN{replaced=0}
    {
        if (!replaced && $0 ~ /^[[:space:]]*url:[[:space:]]*https?:\/\/example\.com\/api/) {
            sub(/url[[:space:]]*: .*/, "url: " url)
            replaced=1
        }
        print
    }
    END{exit(!replaced)}
    ' "$cfg" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$cfg" 2>/dev/null || { rm -f "$tmp" 2>/dev/null || true; return 1; }
        msg "[DEBUG] _config_set_subscription_url: replaced default url"
        return 0
    fi

    rm -f "$tmp" 2>/dev/null || true

    # 若未替换到默认占位符，则追加 provider 结构到文件末尾（尽量保守）
    cat >> "$cfg" <<EOF

proxy-providers:
  myclash:
    type: http
    path: ./myclash.yaml
    url: $url
    interval: 3600
    health-check:
      enable: true
      url: http://www.gstatic.com/generate_204
      interval: 3600
EOF

    msg "[WARN] _config_set_subscription_url: appended provider block to $cfg"
    return 0
}

# 公开的轻量包装（兼容调用习惯）
# 用法:
#   config_set_subscription_url <config_file> <url>
#   config_set_subscription_url <url>  # 使用默认 $MODDIR/mihomo/config.yaml
config_set_subscription_url() {
    case "$#" in
        1)
            cfg="${MODDIR}/mihomo/config.yaml"
            url="$1"
            ;;
        2)
            cfg="$1"
            url="$2"
            ;;
        *)
            printf '%s\n' "Usage: config_set_subscription_url <config_file> <url>  OR  config_set_subscription_url <url>" >&2
            return 2
            ;;
    esac

    _config_set_subscription_url "$cfg" "$url"
}

# EOF
