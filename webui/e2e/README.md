# 浏览器回归

在 `webui/` 下运行：

```sh
npm ci
npx playwright install chromium
npm run test:ui
```

已有 Chrome 时可指定可执行文件，跳过浏览器下载：

```sh
PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/google-chrome-stable npm run test:ui
```

如果默认端口 4174 已被其他工作区占用，可指定独立端口：

```sh
MAGICNET_WEBUI_PORT=4191 npm run test:ui
```

测试默认启动当前工作区的服务，端口占用时会报错。只有确定服务来自当前工作区时，才设置 `MAGICNET_WEBUI_REUSE_SERVER=1` 复用已有服务。

覆盖 320 / 360 / 390 / 430px、横屏、桌面，13 个页面的浅深主题，以及展开项、菜单、确认弹层、焦点恢复、键盘避让、原生编辑器和草稿保留。键盘测试通过缩小可视区域模拟；不能代替 Android 真机验收。

设置回归还覆盖保存期间继续编辑、读取失败后禁用写入、失败后重试、自动更新恢复、长页面切换后的滚动位置，以及 JSON 长行输入和格式化后的光标对齐。

展示数据由测试注入，原生回调由测试模拟，没有连接真实 KernelSU 设备，不会执行设备命令。截图、失败追踪保存在已忽略的 `test-results/` 中；测试不重试，失败须查明原因。自定义输出目录应放在源码目录之外，避免追踪文件触发 Vite 自动刷新。
