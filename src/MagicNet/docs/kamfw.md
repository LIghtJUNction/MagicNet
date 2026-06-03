# example

# Usage: ask "QUESTION" "opt1_text" "opt1_cmd" "opt2_text" "opt2_cmd" ... [default_index]

set_i18n "SET_UI_REDIRECT"  \
    "zh" "设置 WebUI 跳转" \
    "en" "Set WebUI redirect" \
    "ja" "WebUI リダイレクト設定" \
    "ko" "WebUI 리디렉션 설정"
set_i18n "USE_DEFAULT"      \
    "zh" "使用本地默认"   \
    "en" "Use local default"      \
    "ja" "ローカルのデフォルトを使用" \
    "ko" "로컬 기본 사용"
set_i18n "USE_YACD"  \
    "zh" "使用 Yacd 前端"  \
    "en" "Use Yacd frontend"      \
    "ja" "Yacd フロントエンドを使用"     \
    "ko" "Yacd 프론트엔드 사용"  
      
ask_webui() { 
    # Ask the user to choose between using the local default UI or the Yacd frontend.
    # Question key:    SET_UI_REDIRECT
    # Option keys:     USE_DEFAULT -> runs set_default
    #                  USE_YACD     -> runs set_yacd
    ask "SET_UI_REDIRECT" \
        "USE_DEFAULT" \
            'set_default' \
        "USE_YACD" \
            'set_yacd' \
        0
}
<
# confirm - Simple confirmation dialog with customizable default
# Usage: confirm "QUESTION_KEY" [default] && do_something
# default: 0 for yes, 1 for no (default: 1)
# Returns: 0 if yes, 1 if no
confirm() {
    _question="${1:-CONFIRM_ACTION}"
    _default="${2:-1}"

    # 使用ask函数实现确认对话框
    ask "$_question" \
        "YES" \
            'return 0' \
        "NO" \
            'return 1' \
        "$_default"
    
    unset _question _default
}