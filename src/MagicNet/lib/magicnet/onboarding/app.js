(function () {
  'use strict';
  const translations = {
    "en": {"language": "Language", "title": "Add a subscription", "label": "Subscription URL", "save": "Save & continue", "skip": "Later", "star": "GitHub Star", "docs": "Guide", "releases": "Releases", "feedback": "Report an issue", "author": "Meet the author", "submitting": "Saving…", "checking": "Connecting…", "invalid": "Enter a valid HTTPS subscription URL.", "too_long": "URL exceeds 8192 bytes.", "forbidden": "Link expired. Reopen it from the installer.", "missing_token": "Open the complete installer link, including #.", "network": "Result unconfirmed. Check the installer.", "busy": "Please try again.", "existing": "Already configured. Nothing overwritten.", "finished": "Session ended. Return to the installer.", "unsafe_path": "Unsafe path. Use WebUI after installation.", "save_failed": "Save unconfirmed. Check the installer.", "format": "Unsupported format.", "method": "Unsupported request.", "missing": "Setup unavailable.", "saved_title": "You’re all set.", "saved_note": "Return to the installer.", "skipped_title": "Set up later", "skipped_note": "Return to the installer.", "telegram": "Join Telegram", "discord": "Join Discord", "links": "Project links"},
    "zh": {"language": "语言", "title": "添加订阅", "label": "订阅链接", "save": "保存并继续", "skip": "稍后", "star": "GitHub Star", "docs": "使用指南", "releases": "版本更新", "feedback": "问题反馈", "author": "认识作者", "submitting": "保存中…", "checking": "连接中…", "invalid": "请输入有效的 HTTPS 订阅链接。", "too_long": "链接不能超过 8192 字节。", "forbidden": "入口已失效，请从安装器重新打开。", "missing_token": "请打开安装器中的完整链接，包括 #。", "network": "无法确认结果，请返回安装器查看。", "busy": "请稍后重试。", "existing": "已有订阅，未覆盖。", "finished": "设置已结束，请返回安装器。", "unsafe_path": "路径异常，请安装后通过 WebUI 设置。", "save_failed": "保存未确认，请返回安装器查看。", "format": "格式不支持。", "method": "请求不支持。", "missing": "设置入口不可用。", "saved_title": "链接已收好。", "saved_note": "返回安装器继续。", "skipped_title": "稍后设置", "skipped_note": "返回安装器继续。", "telegram": "加入 Telegram 群", "discord": "加入 Discord 群", "links": "项目入口"},
    "zh-TW": {"language": "語言", "title": "新增訂閱", "label": "訂閱連結", "save": "儲存並繼續", "skip": "稍後", "star": "GitHub Star", "docs": "使用指南", "releases": "版本更新", "feedback": "問題回報", "author": "認識作者", "submitting": "儲存中…", "checking": "連線中…", "invalid": "請輸入有效的 HTTPS 訂閱連結。", "too_long": "連結不能超過 8192 位元組。", "forbidden": "入口已失效，請從安裝程式重新開啟。", "missing_token": "請開啟安裝程式中的完整連結，包括 #。", "network": "無法確認結果，請返回安裝程式查看。", "busy": "請稍後重試。", "existing": "已有訂閱，未覆寫。", "finished": "設定已結束，請返回安裝程式。", "unsafe_path": "路徑異常，請安裝後透過 WebUI 設定。", "save_failed": "儲存未確認，請返回安裝程式查看。", "format": "不支援此格式。", "method": "不支援此請求。", "missing": "設定入口無法使用。", "saved_title": "連結已收好。", "saved_note": "返回安裝程式繼續。", "skipped_title": "稍後設定", "skipped_note": "返回安裝程式繼續。", "telegram": "加入 Telegram 群組", "discord": "加入 Discord 群組", "links": "專案入口"},
    "ru": {"language": "Язык", "title": "Добавить подписку", "label": "Ссылка на подписку", "save": "Сохранить", "skip": "Позже", "star": "GitHub Star", "docs": "Руководство", "releases": "Новые версии", "feedback": "Сообщить об ошибке", "author": "Об авторе", "submitting": "Сохранение…", "checking": "Подключение…", "invalid": "Введите корректную HTTPS-ссылку подписки.", "too_long": "Ссылка превышает 8192 байта.", "forbidden": "Ссылка истекла. Откройте её из установщика.", "missing_token": "Откройте полную ссылку установщика, включая #.", "network": "Результат не подтверждён. Проверьте установщик.", "busy": "Повторите попытку.", "existing": "Уже настроено. Ничего не перезаписано.", "finished": "Сеанс завершён. Вернитесь в установщик.", "unsafe_path": "Небезопасный путь. Настройте позже в WebUI.", "save_failed": "Сохранение не подтверждено. Проверьте установщик.", "format": "Формат не поддерживается.", "method": "Запрос не поддерживается.", "missing": "Настройка недоступна.", "saved_title": "Ссылка сохранена.", "saved_note": "Вернитесь в установщик.", "skipped_title": "Настроить позже", "skipped_note": "Вернитесь в установщик.", "telegram": "Вступить в Telegram", "discord": "Вступить в Discord", "links": "Ссылки проекта"},
    "ja": {"language": "言語", "title": "購読を追加", "label": "購読 URL", "save": "保存して続ける", "skip": "後で", "star": "GitHub Star", "docs": "ガイド", "releases": "リリース", "feedback": "問題を報告", "author": "作者について", "submitting": "保存中…", "checking": "接続中…", "invalid": "有効な HTTPS 購読 URL を入力してください。", "too_long": "URL は8192バイト以内にしてください。", "forbidden": "期限切れです。インストーラーから開き直してください。", "missing_token": "インストーラーのリンクを # 以降も含めて開いてください。", "network": "結果を確認できません。インストーラーを確認してください。", "busy": "もう一度お試しください。", "existing": "設定済みです。上書きしていません。", "finished": "設定終了。インストーラーに戻ってください。", "unsafe_path": "安全でないパスです。後で WebUI から設定してください。", "save_failed": "保存未確認。インストーラーを確認してください。", "format": "未対応の形式です。", "method": "未対応のリクエストです。", "missing": "設定を利用できません。", "saved_title": "リンクを保存しました。", "saved_note": "インストーラーに戻ってください。", "skipped_title": "後で設定", "skipped_note": "インストーラーに戻ってください。", "telegram": "Telegram に参加", "discord": "Discord に参加", "links": "プロジェクトのリンク"},
    "ko": {"language": "언어", "title": "구독 추가", "label": "구독 링크", "save": "저장하고 계속", "skip": "나중에", "star": "GitHub Star", "docs": "사용 안내", "releases": "새 버전", "feedback": "문제 신고", "author": "개발자 소개", "submitting": "저장 중…", "checking": "연결 중…", "invalid": "올바른 HTTPS 구독 링크를 입력하세요.", "too_long": "링크는 8192바이트 이하여야 합니다.", "forbidden": "만료된 링크입니다. 설치 프로그램에서 다시 여세요.", "missing_token": "설치 프로그램의 전체 링크를 # 뒤까지 여세요.", "network": "결과를 확인하지 못했습니다. 설치 프로그램을 확인하세요.", "busy": "다시 시도하세요.", "existing": "이미 설정되어 있습니다. 덮어쓰지 않았습니다.", "finished": "설정이 끝났습니다. 설치 프로그램으로 돌아가세요.", "unsafe_path": "안전하지 않은 경로입니다. 나중에 WebUI에서 설정하세요.", "save_failed": "저장을 확인하지 못했습니다. 설치 프로그램을 확인하세요.", "format": "지원하지 않는 형식입니다.", "method": "지원하지 않는 요청입니다.", "missing": "설정을 사용할 수 없습니다.", "saved_title": "링크를 저장했어요.", "saved_note": "설치 프로그램으로 돌아가세요.", "skipped_title": "나중에 설정", "skipped_note": "설치 프로그램으로 돌아가세요.", "telegram": "Telegram 참여", "discord": "Discord 참여", "links": "프로젝트 링크"}
  };
  const byId = (id) => document.getElementById(id);
  const input = byId('subscription');
  const status = byId('status');
  const select = byId('language');
  const supported = (value) => Object.prototype.hasOwnProperty.call(translations, value);
  const normalize = (value) => {
    const locale = String(value || '').toLowerCase().replace(/_/g, '-');
    if (/^zh-(hant|tw|hk|mo)(-|$)/.test(locale)) return 'zh-TW';
    return locale.split('-')[0];
  };
  const requested = normalize(new URLSearchParams(location.search).get('lang'));
  const candidates = (navigator.languages || [navigator.language]).map(normalize);
  let language = supported(requested) ? requested : candidates.find(supported) || 'en';
  let token = location.hash.slice(1);
  let message = '';
  let error = false;
  let result = '';
  let pending = false;
  function render() {
    const t = translations[language];
    document.documentElement.lang = language;
    document.title = 'MagicNet · ' + t.label;
    select.value = language;
    document.querySelectorAll('[data-i18n]').forEach((element) => {
      element.textContent = t[element.dataset.i18n];
    });
    document.querySelectorAll('[data-i18n-label]').forEach((element) => {
      const label = t[element.dataset.i18nLabel];
      element.setAttribute('aria-label', label);
      element.setAttribute('title', label);
    });
    status.textContent = message ? t[message] || t.network : '';
    status.dataset.error = String(error);
    if (result) {
      byId('completion-title').textContent = t[result + '_title'];
      byId('completion-note').textContent = t[result + '_note'];
    }
  }
  function show(key, isError) { message = key; error = Boolean(isError); render(); }
  function lock(value) { input.disabled = value; byId('save').disabled = value; byId('skip').disabled = value; }
  function done(action) {
    result = action;
    input.value = '';
    token = '';
    history.replaceState(null, '', location.pathname + location.search);
    byId('setup-form').hidden = true;
    byId('title').hidden = true;
    byId('completion').hidden = false;
    lock(true);
    show('', false);
    byId('completion-title').focus();
  }
  function request(action, value) {
    if (pending || result) return;
    pending = true;
    document.body.dataset.pending = 'true';
    lock(true);
    show(action === 'health' ? 'checking' : 'submitting', false);
    const xhr = new XMLHttpRequest();
    xhr.open(action === 'health' ? 'GET' : 'POST', '/cgi-bin/setup/' + action, true);
    xhr.timeout = 10000;
    xhr.setRequestHeader('X-Setup-Token', token);
    if (action !== 'health') xhr.setRequestHeader('Content-Type', 'text/plain;charset=UTF-8');
    function settled() { pending = false; document.body.dataset.pending = 'false'; }
    xhr.onload = function () {
      settled();
      let code = 'network';
      try { code = JSON.parse(xhr.responseText).code; } catch (_) { /* Never report unconfirmed success. */ }
      if (xhr.status === 200 && action === 'health' && code === 'ready') { lock(false); show('', false); return; }
      if (xhr.status === 200 && ((action === 'save' && code === 'saved') || (action === 'skip' && code === 'skipped'))) { done(code); return; }
      lock(['forbidden', 'finished', 'existing', 'unsafe_path'].includes(code));
      show(Object.prototype.hasOwnProperty.call(translations[language], code) ? code : 'network', true);
    };
    xhr.onerror = xhr.ontimeout = function () { settled(); lock(false); show('network', true); };
    xhr.send(action === 'health' ? null : value);
  }
  select.addEventListener('change', function () { language = supported(select.value) ? select.value : 'en'; render(); });
  byId('setup-form').addEventListener('submit', function (event) {
    event.preventDefault();
    const value = input.value.trim();
    try {
      const parsed = new URL(value);
      if (!value.startsWith('https://') || parsed.protocol !== 'https:' || !parsed.hostname || /[\x00-\x20\x7f@#\\]/.test(value)) throw new Error('invalid');
      if (new TextEncoder().encode(value).length > 8192) { show('too_long', true); return; }
    } catch (_) { show('invalid', true); return; }
    request('save', value);
  });
  byId('skip').addEventListener('click', function () { request('skip', ''); });
  render();
  if (!/^[0-9a-f]{48}$/.test(token)) { lock(true); show('missing_token', true); return; }
  request('health', '');
})();
