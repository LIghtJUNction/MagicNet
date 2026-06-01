# shellcheck shell=ash
#
# Import common Clash-style subscription nodes into the bundled sing-box config.

magicnet_json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

magicnet_yaml_value() {
    _key="$1"
    sed -n "s/^[[:space:]]*${_key}:[[:space:]]*//p" "$_node_file" | tail -n 1 |
        sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//; s/^'\''//; s/'\''$//'
}

magicnet_truthy() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
    esac
}

magicnet_singbox_subscription_url_file() {
    printf '%s\n' "${MODDIR}/.config/sing-box/subscription.url"
}

magicnet_singbox_subscription_source_file() {
    printf '%s\n' "${MODDIR}/.config/sing-box/subscription.yaml"
}

magicnet_singbox_subscription_config_file() {
    printf '%s\n' "${MODDIR}/.config/sing-box/config.json"
}

magicnet_singbox_fetch_subscription() {
    _url_file=$(magicnet_singbox_subscription_url_file)
    _source_file=$(magicnet_singbox_subscription_source_file)

    if [ ! -s "$_url_file" ]; then
        error "Missing subscription URL file: $_url_file"
        return 1
    fi

    _url=$(sed -n '1{s/^[[:space:]]*//;s/[[:space:]]*$//;p;}' "$_url_file")
    if [ -z "$_url" ]; then
        error "Subscription URL file is empty: $_url_file"
        return 1
    fi

    mkdir -p "${_source_file%/*}"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$_url" -o "$_source_file" || return 1
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$_source_file" "$_url" || return 1
    elif command -v sing-box >/dev/null 2>&1; then
        sing-box tools fetch "$_url" >"$_source_file" || return 1
    else
        error "No downloader found: curl, wget or sing-box tools fetch"
        return 1
    fi

    [ -s "$_source_file" ] || {
        error "Downloaded subscription is empty"
        return 1
    }
}

magicnet_singbox_extract_clash_nodes() {
    _source_file="$1"
    _nodes_dir="$2"
    mkdir -p "$_nodes_dir"

    awk -v outdir="$_nodes_dir" '
        BEGIN { in_proxies = 0; idx = 0; file = "" }
        /^[^[:space:]-][^:]*:/ {
            if ($0 ~ /^proxies:[[:space:]]*$/) {
                in_proxies = 1
                next
            }
            if (in_proxies) {
                in_proxies = 0
            }
        }
        in_proxies && /^[[:space:]]*-[[:space:]]+/ {
            idx++
            file = outdir "/node-" idx ".yaml"
            line = $0
            sub(/^[[:space:]]*-[[:space:]]*/, "", line)
            print line > file
            next
        }
        in_proxies && file != "" && /^[[:space:]]+[[:alnum:]_-]+:/ {
            print $0 >> file
        }
        END { print idx }
    ' "$_source_file"
}

magicnet_singbox_emit_node_json() {
    _node_file="$1"
    _name=$(magicnet_yaml_value name)
    _type=$(magicnet_yaml_value type)
    _server=$(magicnet_yaml_value server)
    _port=$(magicnet_yaml_value port)

    [ -n "$_name" ] || return 1
    [ -n "$_type" ] || return 1
    [ -n "$_server" ] || return 1
    [ -n "$_port" ] || return 1

    _name=$(magicnet_json_escape "$_name")
    _server=$(magicnet_json_escape "$_server")

    case "$_type" in
    ss | shadowsocks)
        _cipher=$(magicnet_json_escape "$(magicnet_yaml_value cipher)")
        _password=$(magicnet_json_escape "$(magicnet_yaml_value password)")
        [ -n "$_cipher" ] || return 1
        [ -n "$_password" ] || return 1
        printf '{"type":"shadowsocks","tag":"%s","server":"%s","server_port":%s,"method":"%s","password":"%s"}' \
            "$_name" "$_server" "$_port" "$_cipher" "$_password"
        ;;
    vmess)
        _uuid=$(magicnet_json_escape "$(magicnet_yaml_value uuid)")
        _alter_id=$(magicnet_yaml_value alterId)
        _network=$(magicnet_yaml_value network)
        _tls=$(magicnet_yaml_value tls)
        [ -n "$_uuid" ] || return 1
        [ -n "$_alter_id" ] || _alter_id=0
        [ -n "$_network" ] || _network=tcp
        printf '{"type":"vmess","tag":"%s","server":"%s","server_port":%s,"uuid":"%s","alter_id":%s,"transport":{"type":"%s"}' \
            "$_name" "$_server" "$_port" "$_uuid" "$_alter_id" "$_network"
        if magicnet_truthy "$_tls"; then
            _sni=$(magicnet_yaml_value servername)
            [ -n "$_sni" ] || _sni=$(magicnet_yaml_value sni)
            [ -n "$_sni" ] || _sni="$_server"
            _sni=$(magicnet_json_escape "$_sni")
            printf ',"tls":{"enabled":true,"server_name":"%s"}' "$_sni"
        fi
        printf '}'
        ;;
    vless)
        _uuid=$(magicnet_json_escape "$(magicnet_yaml_value uuid)")
        _flow=$(magicnet_json_escape "$(magicnet_yaml_value flow)")
        _network=$(magicnet_yaml_value network)
        _tls=$(magicnet_yaml_value tls)
        [ -n "$_uuid" ] || return 1
        [ -n "$_network" ] || _network=tcp
        printf '{"type":"vless","tag":"%s","server":"%s","server_port":%s,"uuid":"%s","transport":{"type":"%s"}' \
            "$_name" "$_server" "$_port" "$_uuid" "$_network"
        [ -n "$_flow" ] && printf ',"flow":"%s"' "$_flow"
        if magicnet_truthy "$_tls"; then
            _sni=$(magicnet_yaml_value servername)
            [ -n "$_sni" ] || _sni=$(magicnet_yaml_value sni)
            [ -n "$_sni" ] || _sni="$_server"
            _sni=$(magicnet_json_escape "$_sni")
            printf ',"tls":{"enabled":true,"server_name":"%s"}' "$_sni"
        fi
        printf '}'
        ;;
    trojan)
        _password=$(magicnet_json_escape "$(magicnet_yaml_value password)")
        [ -n "$_password" ] || return 1
        _sni=$(magicnet_yaml_value sni)
        [ -n "$_sni" ] || _sni=$(magicnet_yaml_value servername)
        [ -n "$_sni" ] || _sni="$_server"
        _sni=$(magicnet_json_escape "$_sni")
        printf '{"type":"trojan","tag":"%s","server":"%s","server_port":%s,"password":"%s","tls":{"enabled":true,"server_name":"%s"}}' \
            "$_name" "$_server" "$_port" "$_password" "$_sni"
        ;;
    hysteria2 | hy2)
        _password=$(magicnet_json_escape "$(magicnet_yaml_value password)")
        [ -n "$_password" ] || return 1
        _sni=$(magicnet_yaml_value sni)
        [ -n "$_sni" ] || _sni=$(magicnet_yaml_value servername)
        [ -n "$_sni" ] || _sni="$_server"
        _sni=$(magicnet_json_escape "$_sni")
        printf '{"type":"hysteria2","tag":"%s","server":"%s","server_port":%s,"password":"%s","tls":{"enabled":true,"server_name":"%s"}}' \
            "$_name" "$_server" "$_port" "$_password" "$_sni"
        ;;
    *)
        return 1
        ;;
    esac
}

magicnet_singbox_build_outbounds_file() {
    _nodes_dir="$1"
    _out_file="$2"
    _tags_file="$3"
    _first=1
    _imported=0
    _skipped=0

    : >"$_tags_file"
    printf '[' >"$_out_file"
    for _node_file in "$_nodes_dir"/node-*.yaml; do
        [ -f "$_node_file" ] || continue
        _json=$(magicnet_singbox_emit_node_json "$_node_file" 2>/dev/null)
        if [ -n "$_json" ]; then
            [ "$_first" -eq 1 ] || printf ',' >>"$_out_file"
            printf '%s' "$_json" >>"$_out_file"
            _tag=$(magicnet_yaml_value name)
            printf '%s\n' "$_tag" >>"$_tags_file"
            _first=0
            _imported=$((_imported + 1))
        else
            _skipped=$((_skipped + 1))
        fi
    done
    printf ']' >>"$_out_file"
    printf '%s %s\n' "$_imported" "$_skipped"
}

magicnet_singbox_update_config_with_nodes() {
    _config_file=$(magicnet_singbox_subscription_config_file)
    _outbounds_file="$1"
    _tags_file="$2"
    _tmp_file="${_config_file}.new"

    if ! command -v python3 >/dev/null 2>&1; then
        error "python3 is required to safely update sing-box config"
        return 1
    fi

    python3 - "$_config_file" "$_outbounds_file" "$_tags_file" "$_tmp_file" <<'PY'
import json
import sys

config_path, outbounds_path, tags_path, output_path = sys.argv[1:]
with open(config_path, "r", encoding="utf-8") as f:
    config = json.load(f)
with open(outbounds_path, "r", encoding="utf-8") as f:
    nodes = json.load(f)
with open(tags_path, "r", encoding="utf-8") as f:
    tags = [line.strip() for line in f if line.strip()]

base = [out for out in config.get("outbounds", []) if out.get("tag") in {"proxy", "select", "direct", "block"}]
by_tag = {out.get("tag"): out for out in base}

proxy = by_tag.get("proxy", {"type": "selector", "tag": "proxy"})
proxy["outbounds"] = tags + ["direct", "block"]
proxy["default"] = tags[0] if tags else "direct"

select = by_tag.get("select", {"type": "selector", "tag": "select"})
select["outbounds"] = ["proxy", "direct", "block"]
select["default"] = "proxy"

direct = by_tag.get("direct", {"type": "direct", "tag": "direct"})
block = by_tag.get("block", {"type": "block", "tag": "block"})

config["outbounds"] = [proxy, select, *nodes, direct, block]

with open(output_path, "w", encoding="utf-8") as f:
    json.dump(config, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY

    if command -v sing-box >/dev/null 2>&1; then
        sing-box check -c "$_tmp_file" -D "${_config_file%/*}" >/dev/null || {
            rm -f "$_tmp_file"
            error "Generated sing-box config failed validation"
            return 1
        }
    fi

    mv -f "$_tmp_file" "$_config_file"
}

magicnet_singbox_update_subscription() {
    _source_file=$(magicnet_singbox_subscription_source_file)
    _work_dir="${MODDIR}/.config/sing-box/.subscription-work"
    _nodes_dir="${_work_dir}/nodes"
    _outbounds_file="${_work_dir}/outbounds.json"
    _tags_file="${_work_dir}/tags.txt"

    rm -rf "$_work_dir"
    mkdir -p "$_nodes_dir"

    magicnet_singbox_fetch_subscription || return 1
    _node_count=$(magicnet_singbox_extract_clash_nodes "$_source_file" "$_nodes_dir")
    if [ "${_node_count:-0}" -le 0 ]; then
        error "No Clash proxies found in subscription"
        return 1
    fi

    set -- $(magicnet_singbox_build_outbounds_file "$_nodes_dir" "$_outbounds_file" "$_tags_file")
    _imported="$1"
    _skipped="$2"

    if [ "${_imported:-0}" -le 0 ]; then
        error "No supported nodes imported. Supported: ss, vmess, vless, trojan, hysteria2"
        return 1
    fi

    magicnet_singbox_update_config_with_nodes "$_outbounds_file" "$_tags_file" || return 1
    success "sing-box nodes updated: imported ${_imported}, skipped ${_skipped}"
}
