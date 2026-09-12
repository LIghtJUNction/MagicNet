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
  const help = {
    en: 'Edit existing URLs or add one per line (up to 5). Later keeps your current settings.',
    zh: '可替换已有链接，或换行新增；每行一个，最多 5 个。“稍后”保留原设置。',
    'zh-TW': '可替換既有連結，或換行新增；每行一個，最多 5 個。「稍後」保留原設定。',
    ru: 'Измените ссылки или добавьте по одной в строке (до 5). «Позже» сохранит настройки.',
    ja: '既存の URL を編集するか、1行に1件追加できます（最大5件）。「後で」は設定を保持します。',
    ko: '기존 링크를 수정하거나 한 줄에 하나씩 추가하세요(최대 5개). 나중에는 기존 설정을 유지합니다.'
  };
  const conflict = {
    en: 'Subscriptions changed while this page was open. Reopen setup to review them.',
    zh: '页面打开后订阅已被其他操作修改，请重新打开设置确认。',
    'zh-TW': '頁面開啟後訂閱已被其他操作修改，請重新開啟設定確認。',
    ru: 'Подписки изменились. Откройте настройку заново.',
    ja: '購読が変更されました。設定を開き直してください。',
    ko: '구독이 변경되었습니다. 설정을 다시 여세요.'
  };
  Object.keys(translations).forEach((key) => {
    translations[key].help = help[key];
    translations[key].existing = conflict[key];
    translations[key].title = { en: 'Manage subscriptions', zh: '设置订阅', 'zh-TW': '設定訂閱', ru: 'Настройка подписок', ja: '購読の設定', ko: '구독 설정' }[key];
  });
  const byId = (id) => document.getElementById(id);
  const receiptText = {
    en: ['Stop installation', 'Installation stopped', 'Return to the installer.', 'Installer confirmed: all ready.', 'Open the source repository?', 'Check installer receipt again', 'Keep saved subscriptions', 'One URL per line, up to 5. With no subscription, add one or stop installation.'],
    zh: ['停止安装', '安装已停止', '请返回安装器。', '安装器已确认：一切就绪。', '是否跳转至源代码仓库？', '重新查询安装回执', '保留已有订阅并继续', '每行一个链接，最多 5 个。没有订阅时，请填写后重试，或停止安装。'],
    'zh-TW': ['停止安裝', '安裝已停止', '請返回安裝程式。', '安裝程式已確認：一切就緒。', '是否前往原始碼儲存庫？', '重新查詢安裝回執', '保留既有訂閱並繼續', '每行一個連結，最多 5 個。沒有訂閱時，請填寫後重試，或停止安裝。'],
    ru: ['Остановить установку', 'Установка остановлена', 'Вернитесь в установщик.', 'Установщик подтвердил: всё готово.', 'Открыть репозиторий исходного кода?', 'Проверить подтверждение снова', 'Продолжить с сохранёнными подписками', 'Одна ссылка в строке, до 5. Добавьте подписку или остановите установку.'],
    ja: ['インストールを中止', 'インストールを中止しました', 'インストーラーに戻ってください。', 'インストーラーが準備完了を確認しました。', 'ソースコードのリポジトリを開きますか？', '確認結果を再取得', '保存済みの購読で続ける', '1行に1件、最大5件。購読を入力して再試行するか、インストールを中止してください。'],
    ko: ['설치 중단', '설치가 중단되었습니다', '설치 프로그램으로 돌아가세요.', '설치 프로그램에서 준비 완료를 확인했습니다.', '소스 코드 저장소로 이동할까요?', '설치 확인 다시 요청', '기존 구독으로 계속', '한 줄에 하나씩 최대 5개입니다. 구독을 입력하고 다시 시도하거나 설치를 중단하세요.']
  };
  Object.keys(receiptText).forEach((key) => {
    const t = translations[key], text = receiptText[key];
    [t.cancel, t.cancelled_title, t.cancelled_note, t.saved_note, t.repository_prompt, t.retry_receipt, t.skip, t.help] = text;
    t.skipped_note = t.saved_note;
    t.skipped_title = t.saved_title;
  });
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
  let waitingReceipt = false;
  let receiptAttempts = 0;
  let submittedAction = 'saved';
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
  function lock(value) { input.disabled = value; byId('save').disabled = value; byId('skip').disabled = value; byId('cancel').disabled = value; }
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
    if (action !== 'cancelled' && window.confirm(translations[language].repository_prompt)) {
      location.assign('https://github.com/LIghtJUNction/MagicNet');
    }
  }
  function pollReceipt() {
    if (++receiptAttempts > 8) { byId('retry-receipt').hidden = false; byId('cancel').disabled = false; show('network', true); return; }
    request('status', '');
  }
  function request(action, value) {
    if (pending || result) return;
    pending = true;
    document.body.dataset.pending = 'true';
    lock(true);
    const reading = ['health', 'subscriptions', 'status'].includes(action);
    show(reading ? 'checking' : 'submitting', false);
    const xhr = new XMLHttpRequest();
    xhr.open(reading ? 'GET' : 'POST', '/cgi-bin/setup/' + action, true);
    xhr.timeout = 10000;
    xhr.setRequestHeader('X-Setup-Token', token);
    if (!reading) xhr.setRequestHeader('Content-Type', 'text/plain;charset=UTF-8');
    function settled() { pending = false; document.body.dataset.pending = 'false'; }
    xhr.onload = function () {
      settled();
      if (xhr.status === 200 && action === 'subscriptions') {
        input.value = xhr.responseText.split(/\r?\n/).map((line) => line.trim()).filter((line) => line && !line.startsWith('#')).join('\n');
        lock(false); show('', false); return;
      }
      let code = 'network';
      try { code = JSON.parse(xhr.responseText).code; } catch (_) { /* Never report unconfirmed success. */ }
      if (xhr.status === 200 && action === 'health' && code === 'ready') { request('subscriptions', ''); return; }
      if (xhr.status === 200 && action === 'status') {
        if (code === 'ready') { done(submittedAction === 'cancelled' ? 'saved' : submittedAction); return; }
        if (code === 'cancelled') { done('cancelled'); return; }
        if (code === 'pending') { byId('cancel').disabled = false; setTimeout(pollReceipt, 500); return; }
      }
      if (xhr.status === 200 && ((action === 'save' && code === 'saved') || (action === 'skip' && code === 'skipped') || (action === 'cancel' && code === 'cancelled'))) {
        submittedAction = code; waitingReceipt = true; pollReceipt(); return;
      }
      lock(reading || ['forbidden', 'finished', 'existing', 'unsafe_path'].includes(code));
      if (code === 'existing' || code === 'unsafe_path') byId('cancel').disabled = false;
      show(Object.prototype.hasOwnProperty.call(translations[language], code) ? code : 'network', true);
    };
    xhr.onerror = xhr.ontimeout = function () {
      settled(); lock(reading || waitingReceipt); show('network', true);
      if (action === 'status' || !reading) {
        waitingReceipt = true;
        submittedAction = action === 'cancel' ? 'cancelled' : submittedAction;
        byId('retry-receipt').hidden = false;
        byId('cancel').disabled = false;
      }
    };
    xhr.send(reading ? null : value);
  }
  select.addEventListener('change', function () { language = supported(select.value) ? select.value : 'en'; render(); });
  byId('setup-form').addEventListener('submit', function (event) {
    event.preventDefault();
    const value = input.value.trim();
    try {
      const values = value.split(/\r?\n/).map((line) => line.trim());
      if (values.length > 5) throw new Error('invalid');
      for (const value of values) {
      const parsed = new URL(value);
      if (!value.startsWith('https://') || parsed.protocol !== 'https:' || !parsed.hostname || /[\x00-\x20\x7f@#\\]/.test(value)) throw new Error('invalid');
      }
      if (new TextEncoder().encode(value).length > 8192) { show('too_long', true); return; }
    } catch (_) { show('invalid', true); input.focus(); return; }
    request('save', value.split(/\r?\n/).map((line) => line.trim()).join('\n'));
  });
  byId('skip').addEventListener('click', function () { request('skip', ''); });
  byId('cancel').addEventListener('click', function () { request('cancel', ''); });
  byId('retry-receipt').addEventListener('click', function () { byId('retry-receipt').hidden = true; receiptAttempts = 0; pollReceipt(); });
  const stars = new XMLHttpRequest();
  stars.open('GET', 'https://api.github.com/repos/LIghtJUNction/MagicNet', true);
  stars.timeout = 5000;
  stars.onload = function () {
    try {
      const count = JSON.parse(stars.responseText).stargazers_count;
      if (stars.status === 200 && Number.isSafeInteger(count) && count >= 0) {
        document.querySelectorAll('[data-star-count]').forEach(element => { element.textContent = count.toLocaleString(); });
      }
    } catch (_) { /* Unavailable stays unknown, never displayed as zero. */ }
  };
  stars.send();
  render();
  if (!/^[0-9a-f]{48}$/.test(token)) { lock(true); show('missing_token', true); return; }
  request('health', '');
})();
