(function () {
  'use strict';
  var messages = {
    en: {
      title: 'Connect · MagicNet', eyebrow: 'YOUR NETWORK. YOUR SPACE.',
      heading: 'A little link.\nA new beginning.', lede: 'Your subscription. The rest is MagicNet.',
      setup: 'SETUP', local: 'ON THIS DEVICE', form_title: 'Make the connection.',
      label: 'Subscription link', save: 'Save & continue', skip: 'Set up later',
      note: 'Stored locally. No account needed.', star: 'Star on GitHub',
      community: 'Community', guide: 'Guide', feedback: 'Feedback', api: 'Creator’s AI service',
      language: 'Language', navigation: 'Community and projects', submitting: 'Saving…',
      saved: 'Saved. Return to the installer, then reboot when installation finishes.',
      skipped: 'You can add a subscription later in the module WebUI.',
      complete_heading: 'Ready when\nyou are.', saved_title: 'Connection saved.', skipped_title: 'No rush.',
      invalid: 'Enter a public HTTPS subscription link without credentials or a fragment.',
      too_long: 'This link is too long. The limit is 8 KB.',
      forbidden: 'Open the complete setup link from the installer.',
      expired: 'This setup has expired. Return to the installer; configure later in the module WebUI.',
      busy: 'Another request is being processed. Try again.',
      changed: 'Your subscription changed elsewhere. Nothing was overwritten. Return to the installer.',
      finished: 'This setup has already ended. Return to the installer.',
      unconfirmed: 'Could not confirm saving. Check the installer before trying again.',
      save_failed: 'Could not save. Return to the installer and configure later.',
      format: 'Invalid request format. Reload the setup page.',
      method: 'Use the buttons on this page.', missing: 'Setup is unavailable. Return to the installer.'
    },
    'zh-CN': {
      title: '开始连接 · MagicNet', eyebrow: '你的网络，你来定义。',
      heading: '连接，\n从这里开始。', lede: '一个订阅，余下交给 MagicNet。',
      setup: '初次设置', local: '本机配置', form_title: '只差一个链接。',
      label: '订阅链接', save: '保存并继续', skip: '稍后配置',
      note: '保存在本机，无需注册。', star: '给 MagicNet 点个 Star',
      community: '加入社区', guide: '使用指南', feedback: '反馈问题', api: '作者的 AI 服务',
      language: '语言', navigation: '社区与其他项目', submitting: '正在保存…',
      saved: '已保存。返回安装器，安装完成后重启设备。',
      skipped: '之后可以在模块 WebUI 中添加订阅。',
      complete_heading: '准备好了，\n下一站见。', saved_title: '连接已就绪。', skipped_title: '不急，稍后再来。',
      invalid: '请填写公网 HTTPS 订阅链接，不要包含账号密码或 # 片段。',
      too_long: '链接过长，最多 8 KB。', forbidden: '请从安装器打开完整的临时配置链接。',
      expired: '本次配置已超时。请返回安装器，之后在模块 WebUI 中配置。',
      busy: '另一个请求正在处理，请重试。',
      changed: '订阅已在其他地方修改，本次未覆盖。请返回安装器。',
      finished: '本次配置已结束，请返回安装器。',
      unconfirmed: '无法确认是否保存成功，请先返回安装器查看结果。',
      save_failed: '未能保存，请返回安装器并稍后配置。',
      format: '请求格式错误，请重新打开配置页面。', method: '请使用页面上的按钮。', missing: '配置服务不可用，请返回安装器。'
    },
    'zh-TW': {
      title: '開始連線 · MagicNet', eyebrow: '你的網路，由你定義。',
      heading: '連線，\n從這裡開始。', lede: '一個訂閱，其餘交給 MagicNet。',
      setup: '初次設定', local: '本機設定', form_title: '只差一個連結。',
      label: '訂閱連結', save: '儲存並繼續', skip: '稍後設定',
      note: '儲存在本機，無需註冊。', star: '給 MagicNet 一個 Star',
      community: '加入社群', guide: '使用指南', feedback: '回報問題', api: '作者的 AI 服務',
      language: '語言', navigation: '社群與其他專案', submitting: '正在儲存…',
      saved: '已儲存。返回安裝程式，安裝完成後重新啟動裝置。',
      skipped: '之後可以在模組 WebUI 中新增訂閱。',
      complete_heading: '準備好了，\n下一站見。', saved_title: '連線已就緒。', skipped_title: '不急，稍後再來。',
      invalid: '請填寫公開 HTTPS 訂閱連結，不要包含帳號密碼或 # 片段。',
      too_long: '連結過長，最多 8 KB。', forbidden: '請從安裝程式開啟完整的暫時設定連結。',
      expired: '本次設定已逾時。請返回安裝程式，之後在模組 WebUI 中設定。',
      busy: '另一個請求正在處理，請重試。',
      changed: '訂閱已在其他地方變更，本次未覆寫。請返回安裝程式。',
      finished: '本次設定已結束，請返回安裝程式。',
      unconfirmed: '無法確認是否儲存成功，請先返回安裝程式查看結果。',
      save_failed: '無法儲存，請返回安裝程式並稍後設定。',
      format: '請求格式錯誤，請重新開啟設定頁面。', method: '請使用頁面上的按鈕。', missing: '設定服務無法使用，請返回安裝程式。'
    },
    ru: {
      title: 'Подключение · MagicNet', eyebrow: 'ВАША СЕТЬ. ВАШЕ ПРОСТРАНСТВО.',
      heading: 'Одна ссылка.\nНовое начало.', lede: 'Ваша подписка. Остальное — MagicNet.',
      setup: 'НАСТРОЙКА', local: 'НА УСТРОЙСТВЕ', form_title: 'Начнём со ссылки.',
      label: 'Ссылка на подписку', save: 'Сохранить и продолжить', skip: 'Настроить позже',
      note: 'Локальное хранение. Без регистрации.', star: 'Звезда на GitHub',
      community: 'Сообщество', guide: 'Руководство', feedback: 'Обратная связь', api: 'ИИ-сервис автора',
      language: 'Язык', navigation: 'Сообщество и проекты', submitting: 'Сохранение…',
      saved: 'Сохранено. Вернитесь в установщик и перезагрузите устройство после установки.',
      skipped: 'Подписку можно добавить позже в WebUI модуля.',
      complete_heading: 'Всё готово.\nДо встречи.', saved_title: 'Ссылка сохранена.', skipped_title: 'Можно позже.',
      invalid: 'Введите публичную HTTPS-ссылку без логина, пароля и фрагмента #.',
      too_long: 'Ссылка слишком длинная. Максимум — 8 КБ.', forbidden: 'Откройте полную ссылку настройки из установщика.',
      expired: 'Время истекло. Вернитесь в установщик; настройка доступна в WebUI модуля.',
      busy: 'Другой запрос обрабатывается. Повторите попытку.',
      changed: 'Подписка изменена в другом месте. Ничего не перезаписано. Вернитесь в установщик.',
      finished: 'Настройка уже завершена. Вернитесь в установщик.',
      unconfirmed: 'Не удалось подтвердить сохранение. Сначала проверьте результат в установщике.',
      save_failed: 'Не удалось сохранить. Вернитесь в установщик и настройте позже.',
      format: 'Неверный формат запроса. Откройте страницу заново.', method: 'Используйте кнопки на странице.', missing: 'Настройка недоступна. Вернитесь в установщик.'
    },
    ja: {
      title: '接続をはじめる · MagicNet', eyebrow: 'あなたのネットワークを、あなたらしく。',
      heading: 'ひとつのリンク。\n新しいはじまり。', lede: '購読をひとつ。あとは MagicNet に。',
      setup: '初期設定', local: 'このデバイスで', form_title: 'まずは、リンクから。',
      label: '購読リンク', save: '保存して続ける', skip: '後で設定する',
      note: '端末に保存。アカウントは不要です。', star: 'GitHub で Star',
      community: 'コミュニティ', guide: 'ガイド', feedback: '問題を報告', api: '作者の AI サービス',
      language: '言語', navigation: 'コミュニティとプロジェクト', submitting: '保存しています…',
      saved: '保存しました。インストーラーに戻り、インストール後に再起動してください。',
      skipped: '後でモジュールの WebUI から購読を追加できます。',
      complete_heading: '準備完了。\nまた会いましょう。', saved_title: 'リンクを保存しました。', skipped_title: '設定は、また後で。',
      invalid: '公開 HTTPS 購読リンクを入力してください。認証情報や # は使えません。',
      too_long: 'リンクが長すぎます。上限は 8 KB です。', forbidden: 'インストーラーから完全な設定リンクを開いてください。',
      expired: '設定の有効期限が切れました。インストーラーに戻り、後で WebUI から設定してください。',
      busy: '別のリクエストを処理中です。再度お試しください。',
      changed: '購読が別の場所で変更されたため上書きしませんでした。インストーラーに戻ってください。',
      finished: 'この設定は終了しています。インストーラーに戻ってください。',
      unconfirmed: '保存を確認できませんでした。まずインストーラーで結果を確認してください。',
      save_failed: '保存できませんでした。インストーラーに戻り、後で設定してください。',
      format: 'リクエスト形式が無効です。設定ページを開き直してください。', method: 'ページのボタンを使ってください。', missing: '設定を利用できません。インストーラーに戻ってください。'
    },
    ko: {
      title: '연결 시작 · MagicNet', eyebrow: '당신의 네트워크, 당신의 공간.',
      heading: '하나의 링크.\n새로운 시작.', lede: '구독 하나면, 나머지는 MagicNet.',
      setup: '초기 설정', local: '이 기기에서', form_title: '링크부터 시작하세요.',
      label: '구독 링크', save: '저장하고 계속', skip: '나중에 설정',
      note: '기기에 저장합니다. 가입은 필요 없습니다.', star: 'GitHub에서 Star',
      community: '커뮤니티', guide: '사용 안내', feedback: '문제 신고', api: '제작자의 AI 서비스',
      language: '언어', navigation: '커뮤니티 및 프로젝트', submitting: '저장 중…',
      saved: '저장했습니다. 설치 화면으로 돌아가 설치 완료 후 재부팅하세요.',
      skipped: '나중에 모듈 WebUI에서 구독을 추가할 수 있습니다.',
      complete_heading: '준비됐어요.\n다음에 만나요.', saved_title: '링크를 저장했습니다.', skipped_title: '나중에 해도 괜찮아요.',
      invalid: '계정 정보와 # 부분이 없는 공개 HTTPS 구독 링크를 입력하세요.',
      too_long: '링크가 너무 깁니다. 최대 8 KB입니다.', forbidden: '설치 화면의 전체 설정 링크를 열어 주세요.',
      expired: '설정 시간이 만료됐습니다. 설치 화면으로 돌아가 나중에 모듈 WebUI에서 설정하세요.',
      busy: '다른 요청을 처리 중입니다. 다시 시도하세요.',
      changed: '다른 곳에서 구독이 변경되어 덮어쓰지 않았습니다. 설치 화면으로 돌아가세요.',
      finished: '이번 설정은 이미 종료됐습니다. 설치 화면으로 돌아가세요.',
      unconfirmed: '저장 여부를 확인하지 못했습니다. 먼저 설치 화면에서 결과를 확인하세요.',
      save_failed: '저장하지 못했습니다. 설치 화면으로 돌아가 나중에 설정하세요.',
      format: '요청 형식이 잘못됐습니다. 설정 페이지를 다시 여세요.', method: '페이지의 버튼을 사용하세요.', missing: '설정할 수 없습니다. 설치 화면으로 돌아가세요.'
    }
  };
  var language = document.getElementById('language');
  var input = document.getElementById('subscription');
  var save = document.getElementById('save');
  var skip = document.getElementById('skip');
  var status = document.getElementById('status');
  var token = location.hash.slice(1);
  var state = 'idle', statusKey = '', isError = false;
  function languageKey(value) {
    if (/^zh/i.test(value)) return /TW|HK|MO|Hant/i.test(value) ? 'zh-TW' : 'zh-CN';
    var short = value.split('-')[0].toLowerCase();
    return Object.prototype.hasOwnProperty.call(messages, short) ? short : '';
  }
  var preferred = navigator.languages || [navigator.language || 'en'];
  language.value = 'en';
  for (var i = 0; i < preferred.length; i++) {
    var key = languageKey(preferred[i]);
    if (key) { language.value = key; break; }
  }
  function text(key) { return messages[language.value][key] || messages.en[key] || messages.en.missing; }
  function render() {
    document.documentElement.lang = language.value;
    document.title = text('title');
    document.querySelectorAll('[data-i18n]').forEach(function (element) {
      element.textContent = text(element.getAttribute('data-i18n'));
    });
    language.setAttribute('aria-label', text('language'));
    document.getElementById('links').setAttribute('aria-label', text('navigation'));
    status.textContent = statusKey ? text(statusKey) : '';
    status.classList.toggle('error', isError);
    save.disabled = skip.disabled = input.disabled = state !== 'idle';
    if (state === 'saved' || state === 'skipped') {
      document.getElementById('heading').textContent = text('complete_heading');
      document.getElementById('form-title').textContent = text(state === 'saved' ? 'saved_title' : 'skipped_title');
    }
  }
  function notice(key, error) { statusKey = key; isError = error; render(); }
  language.addEventListener('change', render);
  render();
  if (!/^[0-9a-f]{48}$/.test(token)) { state = 'ended'; notice('forbidden', true); }
  var ttlMatch = location.search.match(/[?&]ttl=(\d{1,4})(?:&|$)/);
  var ttl = ttlMatch ? Math.max(5, Math.min(1800, Number(ttlMatch[1]))) : 180;
  var deadline = Date.now() + ttl * 1000;
  var interval = setInterval(function () {
    var left = Math.max(0, Math.ceil((deadline - Date.now()) / 1000));
    document.getElementById('timer').textContent = Math.floor(left / 60) + ':' + ('0' + left % 60).slice(-2);
    if (left === 0 && state === 'idle') { state = 'ended'; notice('expired', true); }
    if (state === 'saved' || state === 'skipped' || state === 'ended') clearInterval(interval);
  }, 1000);
  function send(action, value) {
    if (state !== 'idle') return;
    state = 'submitting'; input.removeAttribute('aria-invalid'); notice('submitting', false);
    var xhr = new XMLHttpRequest();
    xhr.open('POST', '/cgi-bin/api/' + action, true);
    xhr.timeout = 10000;
    xhr.setRequestHeader('Content-Type', 'text/plain;charset=UTF-8');
    xhr.setRequestHeader('X-Setup-Token', token);
    xhr.onload = function () {
      var key = xhr.responseText.trim();
      if (xhr.status === 200 && key === (action === 'save' ? 'saved' : 'skipped')) {
        state = key; input.value = ''; token = ''; document.body.classList.add('complete');
        history.replaceState(null, '', location.pathname);
        notice(key, false);
        var heading = document.getElementById('form-title');
        heading.setAttribute('tabindex', '-1'); heading.focus();
      } else {
        state = /^(changed|finished|forbidden)$/.test(key) ? 'ended' : 'idle';
        if (key === 'invalid') input.setAttribute('aria-invalid', 'true');
        notice(Object.prototype.hasOwnProperty.call(messages.en, key) ? key : 'save_failed', true);
      }
    };
    xhr.onerror = xhr.ontimeout = function () { state = 'idle'; notice('unconfirmed', true); };
    xhr.send(value);
  }
  document.getElementById('form').addEventListener('submit', function (event) {
    event.preventDefault();
    if (state !== 'idle') return;
    var value = input.value.trim().replace(/^https:\/\//i, 'https://');
    try {
      var url = new URL(value);
      if (url.protocol !== 'https:' || !url.hostname || url.username || url.password || url.hash || /[\s\x00-\x20\x7f\\]/.test(value)) throw new Error('invalid');
    } catch (_) { input.setAttribute('aria-invalid', 'true'); notice('invalid', true); input.focus(); return; }
    if (new Blob([value]).size > 8192) { notice('too_long', true); return; }
    send('save', value);
  });
  skip.addEventListener('click', function () { send('skip', ''); });
})();
