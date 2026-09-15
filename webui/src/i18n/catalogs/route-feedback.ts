export default {
  "路由反馈": ["Routing feedback", "Отзыв о маршрутизации"],
  "推荐": ["Recommended", "Рекомендуется"],
  "推荐：提交最近应用和网站实际命中的路由，帮助持续改进规则。": [
    "Recommended: share the routes recently used by apps and websites to help improve routing rules.",
    "Рекомендуется: отправьте маршруты, недавно использованные приложениями и сайтами, чтобы улучшать правила маршрутизации.",
  ],
  "附带近期应用包名、目标域名、命中规则、路由链和相关错误；IP、节点名、凭据和 URL 路径会被过滤。": [
    "Includes recent app package names, destination domains, matched rules, route chains, and related errors; IPs, node names, credentials, and URL paths are filtered.",
    "Включает недавние имена пакетов приложений, домены назначения, сработавшие правила, цепочки маршрутов и связанные ошибки; IP-адреса, имена узлов, учётные данные и пути URL фильтруются.",
  ],
  "路由反馈会公开包含最近活动连接中的应用包名和目标域名，以及命中规则、路由链和相关错误；不会上传 IP、连接 ID、流量大小、订阅节点名、凭据或 URL 路径。": [
    "Routing feedback is public and includes app package names and destination domains from recent active connections, plus matched rules, route chains, and related errors. It does not upload IPs, connection IDs, traffic sizes, subscription node names, credentials, or URL paths.",
    "Отзыв о маршрутизации публикуется открыто и включает имена пакетов приложений и домены назначения из недавних активных соединений, а также сработавшие правила, цепочки маршрутов и связанные ошибки. IP-адреса, ID соединений, объём трафика, имена узлов подписки, учётные данные и пути URL не отправляются.",
  ],
  "补充说明（可选）": ["Additional note (optional)", "Дополнительное описание (необязательно)"],
  "不填写也可以直接提交；MagicNet 会自动采集最近的路由样本和错误上下文。": [
    "You can submit without writing anything; MagicNet automatically collects recent routing samples and error context.",
    "Можно отправить без дополнительного текста: MagicNet автоматически соберёт недавние примеры маршрутизации и контекст ошибок.",
  ],
  "例如：Gmail 打不开，但浏览器访问 Google 正常。": [
    "For example: Gmail does not open, but Google works in the browser.",
    "Например: Gmail не открывается, но Google нормально работает в браузере.",
  ],
  "路由反馈仅保留规则迭代需要的应用包名和域名；其余敏感字段继续脱敏。": [
    "Routing feedback keeps only the app package names and domains needed to improve rules; other sensitive fields remain redacted.",
    "В отзыве сохраняются только имена пакетов приложений и домены, нужные для улучшения правил; остальные чувствительные поля остаются скрытыми.",
  ],
  "收集路由并创建": ["Collect routes and create", "Собрать маршруты и создать"],
  "正在收集路由反馈": ["Collecting routing feedback", "Сбор данных о маршрутизации"],
  "自动路由反馈：最近应用 / 网站路由样本": [
    "Automatic routing feedback: recent app / website route samples",
    "Автоматический отзыв о маршрутизации: недавние маршруты приложений / сайтов",
  ],
} as const;
