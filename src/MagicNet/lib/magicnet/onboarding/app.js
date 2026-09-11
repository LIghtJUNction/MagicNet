(function () {
  'use strict';
  const translations = {
    en: {
      language: 'Language', eyebrow: 'A NEW CONNECTION', title: 'Your network.', accent: 'Your rules.',
      subtitle: 'Add a subscription. Make yourself at home.', label: 'Subscription URL', save: 'Save & continue', skip: 'Set up later',
      privacy: 'Stored on your device. Loaded on the next start.', explore: 'Keep exploring', star: 'Star on GitHub', docs: 'Guide', community: 'Community', local: 'PRIVATE, BY DESIGN',
      submitting: 'Saving…', checking: 'Connecting to the installer…', invalid: 'Use a complete HTTPS URL without spaces, a fragment or credentials.',
      too_long: 'The URL must be no longer than 8192 bytes.', forbidden: 'This setup link is invalid. Open the complete link from the installer.',
      missing_token: 'Open the complete setup link from the installer, including the part after #.',
      network: 'Could not confirm the result. Return to the installer to check; this temporary page may have closed.',
      busy: 'Another request is being processed. Please try again.', existing: 'A subscription is already configured. It has not been overwritten.',
      finished: 'This setup session has ended. Return to the installer.', unsafe_path: 'The configuration path is unsafe. Use the module WebUI after installation.',
      save_failed: 'Could not save. Return to the installer; no success has been confirmed.', format: 'Unsupported request format.', method: 'Unsupported request method.', missing: 'Setup endpoint not found.',
      saved_title: 'You’re all set.', saved_note: 'The link is saved. Return to the installer and finish installing. MagicNet will load the subscription on its next start.',
      skipped_title: 'At your own pace.', skipped_note: 'Return to the installer. You can add a subscription in the module WebUI later.'
    },
    zh: {
      language: '语言', eyebrow: '新的连接，从这里开始', title: '你的网络。', accent: '由你定义。',
      subtitle: '添加订阅，开始使用 MagicNet。', label: '订阅链接', save: '保存并继续', skip: '稍后设置',
      privacy: '保存在本机，下次启动时加载。', explore: '不止于此', star: '在 GitHub 点亮 Star', docs: '使用指南', community: '加入社区', local: '留在本机，保持私密',
      submitting: '正在保存…', checking: '正在连接安装器…', invalid: '请填写完整的 HTTPS 链接，不含空格、# 片段或账号密码。',
      too_long: '链接不能超过 8192 字节。', forbidden: '本次入口无效，请打开安装器显示的完整地址。',
      missing_token: '请打开安装器显示的完整地址，包括 # 后面的部分。',
      network: '无法确认结果，请返回安装器查看；临时页面可能已关闭。',
      busy: '另一个请求正在处理，请重试。', existing: '已有订阅配置，没有覆盖。', finished: '本次配置已经结束，请返回安装器。',
      unsafe_path: '配置路径不安全，请安装后通过模块 WebUI 设置。', save_failed: '未能确认保存成功，请返回安装器查看。', format: '请求格式不支持。', method: '请求方式不支持。', missing: '配置接口不存在。',
      saved_title: '链接已收好。', saved_note: '返回安装器完成安装。MagicNet 下次启动时会加载订阅。',
      skipped_title: '稍后再出发。', skipped_note: '返回安装器继续安装，之后可在模块 WebUI 添加订阅。'
    },
    ru: {
      language: 'Язык', eyebrow: 'НОВОЕ ПОДКЛЮЧЕНИЕ', title: 'Ваша сеть.', accent: 'Ваши правила.',
      subtitle: 'Добавьте подписку и начните пользоваться MagicNet.', label: 'Ссылка на подписку', save: 'Сохранить', skip: 'Настроить позже',
      privacy: 'Хранится на устройстве. Загрузится при следующем запуске.', explore: 'Узнать больше', star: 'Звезда на GitHub', docs: 'Руководство', community: 'Сообщество', local: 'ПРИВАТНО ПО УМОЛЧАНИЮ',
      submitting: 'Сохранение…', checking: 'Подключение к установщику…', invalid: 'Введите полный HTTPS URL без пробелов, фрагмента # и учётных данных.',
      too_long: 'Ссылка не должна превышать 8192 байта.', forbidden: 'Ссылка настройки недействительна. Откройте полную ссылку из установщика.',
      missing_token: 'Откройте полную ссылку из установщика, включая часть после #.',
      network: 'Результат не подтверждён. Проверьте установщик; временная страница могла закрыться.',
      busy: 'Другой запрос обрабатывается. Повторите попытку.', existing: 'Подписка уже настроена и не была перезаписана.', finished: 'Сеанс завершён. Вернитесь в установщик.',
      unsafe_path: 'Небезопасный путь конфигурации. Используйте WebUI после установки.', save_failed: 'Сохранение не подтверждено. Проверьте установщик.', format: 'Неподдерживаемый формат.', method: 'Неподдерживаемый метод.', missing: 'Интерфейс настройки не найден.',
      saved_title: 'Ссылка сохранена.', saved_note: 'Вернитесь в установщик и завершите установку. MagicNet загрузит подписку при следующем запуске.',
      skipped_title: 'Можно и позже.', skipped_note: 'Вернитесь в установщик. Подписку можно добавить в WebUI модуля позже.'
    },
    ja: {
      language: '言語', eyebrow: '新しいつながり', title: 'あなたのネット。', accent: 'あなたのルール。',
      subtitle: '購読を追加して、MagicNet を始めましょう。', label: '購読 URL', save: '保存して続ける', skip: '後で設定',
      privacy: '端末内に保存し、次回起動時に読み込みます。', explore: 'さらに詳しく', star: 'GitHub で Star', docs: 'ガイド', community: 'コミュニティ', local: 'プライバシーを大切に',
      submitting: '保存しています…', checking: 'インストーラーに接続しています…', invalid: '空白、# フラグメント、認証情報を含まない完全な HTTPS URL を入力してください。',
      too_long: 'URL は8192バイト以内にしてください。', forbidden: '無効な設定リンクです。インストーラーのリンク全体を開いてください。',
      missing_token: 'インストーラーのリンクを、# 以降も含めて開いてください。',
      network: '結果を確認できません。インストーラーに戻って確認してください。一時ページが閉じた可能性があります。',
      busy: '別のリクエストを処理中です。再試行してください。', existing: '購読は既に設定されています。上書きしていません。', finished: '設定を終了しました。インストーラーに戻ってください。',
      unsafe_path: '安全でない設定パスです。インストール後に WebUI を使用してください。', save_failed: '保存を確認できません。インストーラーを確認してください。', format: '未対応の形式です。', method: '未対応のメソッドです。', missing: '設定インターフェースが見つかりません。',
      saved_title: 'リンクを保存しました。', saved_note: 'インストーラーに戻ってインストールを完了してください。次回起動時に購読を読み込みます。',
      skipped_title: 'また後で。', skipped_note: 'インストーラーに戻ってください。購読は後から WebUI で追加できます。'
    },
    ko: {
      language: '언어', eyebrow: '새로운 연결', title: '당신의 네트워크.', accent: '당신의 규칙.',
      subtitle: '구독을 추가하고 MagicNet을 시작하세요.', label: '구독 링크', save: '저장하고 계속', skip: '나중에 설정',
      privacy: '기기에 저장하고 다음 시작 때 불러옵니다.', explore: '더 알아보기', star: 'GitHub에 Star', docs: '사용 안내', community: '커뮤니티', local: '개인정보를 소중하게',
      submitting: '저장 중…', checking: '설치 프로그램에 연결 중…', invalid: '공백, # 조각, 인증 정보가 없는 완전한 HTTPS 링크를 입력하세요.',
      too_long: '링크는 8192바이트 이하여야 합니다.', forbidden: '유효하지 않은 설정 링크입니다. 설치 프로그램의 전체 링크를 여세요.',
      missing_token: '설치 프로그램의 링크를 # 뒤의 부분까지 모두 여세요.',
      network: '결과를 확인하지 못했습니다. 설치 프로그램으로 돌아가 확인하세요. 임시 페이지가 닫혔을 수 있습니다.',
      busy: '다른 요청을 처리 중입니다. 다시 시도하세요.', existing: '이미 구독이 설정되어 있습니다. 덮어쓰지 않았습니다.', finished: '설정이 종료되었습니다. 설치 프로그램으로 돌아가세요.',
      unsafe_path: '설정 경로가 안전하지 않습니다. 설치 후 WebUI를 사용하세요.', save_failed: '저장을 확인하지 못했습니다. 설치 프로그램을 확인하세요.', format: '지원하지 않는 형식입니다.', method: '지원하지 않는 방식입니다.', missing: '설정 인터페이스를 찾을 수 없습니다.',
      saved_title: '링크를 저장했어요.', saved_note: '설치 프로그램으로 돌아가 설치를 완료하세요. 다음 시작 때 구독을 불러옵니다.',
      skipped_title: '나중에 해도 돼요.', skipped_note: '설치 프로그램으로 돌아가세요. 나중에 모듈 WebUI에서 구독을 추가할 수 있습니다.'
    }
  };
  const byId = (id) => document.getElementById(id);
  const input = byId('subscription');
  const status = byId('status');
  const select = byId('language');
  const supported = (value) => Object.prototype.hasOwnProperty.call(translations, value);
  const normalize = (value) => String(value || '').toLowerCase().split(/[-_]/)[0];
  const requested = normalize(new URLSearchParams(location.search).get('lang'));
  const candidates = (navigator.languages || [navigator.language]).map(normalize);
  let language = supported(requested) ? requested : candidates.find(supported) || 'en';
  let token = location.hash.slice(1);
  let message = '';
  let error = false;
  let result = '';
  function render() {
    const t = translations[language];
    document.documentElement.lang = language;
    document.title = 'MagicNet · ' + t.label;
    select.value = language;
    document.querySelectorAll('[data-i18n]').forEach((element) => {
      element.textContent = t[element.dataset.i18n];
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
    byId('completion').hidden = false;
    lock(true);
    show('', false);
  }
  function request(action, value) {
    lock(true);
    show(action === 'health' ? 'checking' : 'submitting', false);
    const xhr = new XMLHttpRequest();
    xhr.open(action === 'health' ? 'GET' : 'POST', '/cgi-bin/setup/' + action, true);
    xhr.timeout = 10000;
    xhr.setRequestHeader('X-Setup-Token', token);
    if (action !== 'health') xhr.setRequestHeader('Content-Type', 'text/plain;charset=UTF-8');
    xhr.onload = function () {
      let code = 'network';
      try { code = JSON.parse(xhr.responseText).code; } catch (_) { /* Report an unconfirmed result, not a false success. */ }
      if (xhr.status === 200 && action === 'health' && code === 'ready') { lock(false); show('', false); return; }
      if (xhr.status === 200 && ((action === 'save' && code === 'saved') || (action === 'skip' && code === 'skipped'))) { done(code); return; }
      lock(['forbidden', 'finished', 'existing', 'unsafe_path'].includes(code));
      show(supported(language) && Object.prototype.hasOwnProperty.call(translations[language], code) ? code : 'network', true);
    };
    xhr.onerror = xhr.ontimeout = function () { lock(false); show('network', true); };
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
