(function () {
  'use strict';
  // Deliberately independent of the manager WebView bridge and all remote assets.
  var messages = {
    en: {
      language: 'Language', eyebrow: 'YOUR DEVICE. YOUR CONNECTION.', title: 'A quieter way\nto connect.',
      intro: 'One subscription link. You’re ready.', label: 'Subscription link', save: 'Save & continue', skip: 'Set up later',
      privacy: 'Saved on this device. Imported after reboot.', star: 'Star on GitHub', star_note: 'A small star. A little more momentum.',
      docs: 'Guide', releases: 'Releases', feedback: 'Feedback', author: 'Meet the maker', optional: 'Optional service ↗', links: 'Project links',
      sending: 'Saving…', invalid: 'Enter a complete HTTPS link, without spaces or sign-in credentials.', too_long: 'The link must be no longer than 8192 bytes.',
      forbidden: 'Open the complete setup address from the installer, including the part after #.', uncertain: 'Could not confirm the save. Check the installer before trying again.',
      storage: 'Could not save. Return to the installer to check the result.', busy: 'Another request is being saved. Try again.', finished: 'This setup session has ended. Return to the installer.',
      saved_title: 'Your link is saved.', saved_intro: 'Return to the manager. Finish installing, then reboot.',
      skipped_title: 'Another time, then.', skipped_intro: 'Installation will continue. Add a subscription in the module WebUI later.',
      existing_title: 'Your link stays.', existing_intro: 'An existing subscription was preserved. Return to the installer.'
    },
    zh: {
      language: '语言', eyebrow: '你的设备，你的连接。', title: '连接，\n从这里开始。',
      intro: '只差一个订阅链接。', label: '订阅链接', save: '保存并继续', skip: '稍后配置',
      privacy: '仅保存到本机，重启后导入。', star: '去 GitHub 点个 Star', star_note: '一颗星，让这个小项目走得更远。',
      docs: '使用指南', releases: '版本更新', feedback: '反馈问题', author: '作者主页', optional: '可选服务 ↗', links: '项目链接',
      sending: '正在保存…', invalid: '请填写完整的 HTTPS 链接，不要包含空格或登录账号密码。', too_long: '链接不能超过 8192 字节。',
      forbidden: '请打开安装器中的完整地址，包括 # 后的部分。', uncertain: '无法确认保存结果，请回到安装器查看后再试。',
      storage: '保存未完成，请回到安装器查看。', busy: '另一条请求正在保存，请重试。', finished: '本次配置已结束，请回到安装器。',
      saved_title: '链接已保存。', saved_intro: '回到管理器，完成安装后重启。',
      skipped_title: '下次再连接。', skipped_intro: '安装将继续，稍后可在模块 WebUI 添加订阅。',
      existing_title: '原订阅已保留。', existing_intro: '检测到已有订阅，请回到安装器继续。'
    },
    ru: {
      language: 'Язык', eyebrow: 'ВАШЕ УСТРОЙСТВО. ВАШЕ ПОДКЛЮЧЕНИЕ.', title: 'Подключение\nбез лишнего.',
      intro: 'Осталось добавить ссылку на подписку.', label: 'Ссылка на подписку', save: 'Сохранить и продолжить', skip: 'Настроить позже',
      privacy: 'Сохраняется на устройстве. Импорт после перезагрузки.', star: 'Звезда на GitHub', star_note: 'Ваша звезда помогает проекту расти.',
      docs: 'Руководство', releases: 'Версии', feedback: 'Обратная связь', author: 'Об авторе', optional: 'Необязательный сервис ↗', links: 'Ссылки проекта',
      sending: 'Сохранение…', invalid: 'Введите полную ссылку HTTPS без пробелов, логина и пароля.', too_long: 'Ссылка должна быть не длиннее 8192 байт.',
      forbidden: 'Откройте полный адрес из установщика, включая часть после #.', uncertain: 'Не удалось подтвердить сохранение. Проверьте результат в установщике.',
      storage: 'Не удалось сохранить. Вернитесь в установщик.', busy: 'Сохраняется другой запрос. Повторите попытку.', finished: 'Сеанс настройки завершён. Вернитесь в установщик.',
      saved_title: 'Ссылка сохранена.', saved_intro: 'Вернитесь в менеджер. Завершите установку и перезагрузите устройство.',
      skipped_title: 'Настроим позже.', skipped_intro: 'Установка продолжится. Добавьте подписку в WebUI модуля позже.',
      existing_title: 'Подписка сохранена.', existing_intro: 'Существующая подписка не изменена. Вернитесь в установщик.'
    },
    ja: {
      language: '言語', eyebrow: 'あなたの端末。あなたの接続。', title: 'つながりは、\nここから。',
      intro: 'あとは購読リンクをひとつ。', label: '購読リンク', save: '保存して続ける', skip: 'あとで設定',
      privacy: '端末内に保存し、再起動後に取り込みます。', star: 'GitHub で Star', star_note: 'ひとつの Star が、開発の支えに。',
      docs: '使い方', releases: '更新情報', feedback: '問題を報告', author: '作者について', optional: '任意のサービス ↗', links: 'プロジェクトのリンク',
      sending: '保存しています…', invalid: '空白やユーザー名・パスワードを含まない HTTPS リンクを入力してください。', too_long: 'リンクは 8192 バイト以内にしてください。',
      forbidden: 'インストーラーの完全な URL（# 以降も含む）を開いてください。', uncertain: '保存を確認できませんでした。インストーラーで結果を確認してください。',
      storage: '保存できませんでした。インストーラーに戻ってください。', busy: '別のリクエストを保存中です。もう一度お試しください。', finished: '設定セッションが終了しました。インストーラーに戻ってください。',
      saved_title: 'リンクを保存しました。', saved_intro: '管理アプリに戻り、インストールを完了して再起動してください。',
      skipped_title: '設定は、またあとで。', skipped_intro: 'インストールを続行します。あとでモジュールの WebUI から購読を追加できます。',
      existing_title: '購読を保持しました。', existing_intro: '既存の購読は変更していません。インストーラーに戻ってください。'
    },
    ko: {
      language: '언어', eyebrow: '내 기기. 나만의 연결.', title: '연결의 시작,\n여기에서.',
      intro: '구독 링크 하나면 됩니다.', label: '구독 링크', save: '저장하고 계속', skip: '나중에 설정',
      privacy: '기기에 저장하고 재부팅 후 가져옵니다.', star: 'GitHub에 Star 남기기', star_note: '작은 별 하나가 프로젝트에 힘이 됩니다.',
      docs: '사용 안내', releases: '업데이트', feedback: '문제 신고', author: '개발자 소개', optional: '선택 서비스 ↗', links: '프로젝트 링크',
      sending: '저장 중…', invalid: '공백이나 로그인 정보가 없는 완전한 HTTPS 링크를 입력하세요.', too_long: '링크는 8192바이트 이하여야 합니다.',
      forbidden: '# 뒤의 내용을 포함한 설치 프로그램의 전체 주소를 여세요.', uncertain: '저장 결과를 확인할 수 없습니다. 설치 프로그램에서 확인하세요.',
      storage: '저장하지 못했습니다. 설치 프로그램으로 돌아가세요.', busy: '다른 요청을 저장 중입니다. 다시 시도하세요.', finished: '설정 세션이 종료되었습니다. 설치 프로그램으로 돌아가세요.',
      saved_title: '링크를 저장했습니다.', saved_intro: '관리자로 돌아가 설치를 마친 후 재부팅하세요.',
      skipped_title: '설정은 다음에.', skipped_intro: '설치를 계속합니다. 나중에 모듈 WebUI에서 구독을 추가하세요.',
      existing_title: '기존 구독을 유지합니다.', existing_intro: '기존 구독을 변경하지 않았습니다. 설치 프로그램으로 돌아가세요.'
    }
  };
  var select = document.getElementById('language');
  var input = document.getElementById('url');
  var save = document.getElementById('save');
  var skip = document.getElementById('skip');
  var status = document.getElementById('status');
  var form = document.getElementById('form');
  var token = location.hash.slice(1);
  var language = 'en', result = '', statusKey = '', statusError = false;
  var preferred = navigator.languages || [navigator.language || 'en'];
  for (var i = 0; i < preferred.length; i++) {
    var candidate = preferred[i].toLowerCase().split(/[-_]/)[0];
    if (messages[candidate]) { language = candidate; break; }
  }
  function text(key) { return messages[language][key] || messages.en[key] || messages.en.storage; }
  function render() {
    document.documentElement.lang = language === 'zh' ? 'zh-CN' : language;
    document.title = 'MagicNet · ' + text('label');
    select.value = language;
    select.setAttribute('aria-label', text('language'));
    document.getElementById('links').setAttribute('aria-label', text('links'));
    document.querySelectorAll('[data-i18n]').forEach(function (node) { node.textContent = text(node.getAttribute('data-i18n')); });
    if (result) {
      document.getElementById('title').textContent = text(result + '_title');
      document.getElementById('intro').textContent = text(result + '_intro');
    }
    status.textContent = statusKey ? text(statusKey) : '';
    status.dataset.error = String(statusError);
  }
  function tell(key, error) { statusKey = key; statusError = !!error; render(); }
  function lock(value) { save.disabled = value; skip.disabled = value; input.disabled = value; }
  function complete(value) {
    result = value;
    input.value = '';
    form.hidden = true;
    document.getElementById('finish').hidden = false;
    document.querySelector('.privacy').hidden = true;
    tell('', false);
  }
  select.addEventListener('change', function () { language = select.value; render(); });
  render();
  if (!/^[0-9a-f]{48}$/.test(token) || window.self !== window.top) {
    tell('forbidden', true); lock(true); return;
  }
  function send(action, value) {
    lock(true); tell('sending', false);
    var xhr = new XMLHttpRequest();
    xhr.open('POST', '/cgi-bin/api/' + action, true);
    xhr.timeout = 12000;
    xhr.setRequestHeader('Content-Type', 'text/plain;charset=UTF-8');
    xhr.setRequestHeader('X-Setup-Token', token);
    xhr.onload = function () {
      var code = xhr.responseText.trim();
      if (xhr.status === 200 && (code === 'saved' || code === 'skipped')) { complete(code); return; }
      if (code === 'existing') { complete('existing'); return; }
      if (xhr.status === 403 || code === 'finished') { tell(code === 'finished' ? 'finished' : 'forbidden', true); return; }
      tell(['invalid', 'too_long', 'busy', 'storage'].indexOf(code) >= 0 ? code : 'storage', true);
      lock(false);
    };
    xhr.onerror = xhr.ontimeout = function () { tell('uncertain', true); lock(false); };
    xhr.send(value);
  }
  form.addEventListener('submit', function (event) {
    event.preventDefault();
    var value = input.value.trim();
    try {
      var url = new URL(value);
      if (!/^https:\/\//.test(value) || url.protocol !== 'https:' || !url.hostname || url.username || url.password || /[\x00-\x20\x7f\\@]/.test(value)) throw new Error('invalid');
    } catch (_) { tell('invalid', true); return; }
    if (new Blob([value]).size > 8192) { tell('too_long', true); return; }
    send('save', value);
  });
  skip.addEventListener('click', function () { send('skip', ''); });
})();
