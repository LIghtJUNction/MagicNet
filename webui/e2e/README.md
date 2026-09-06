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

覆盖 320 / 360 / 390 / 430px、横屏、桌面，11 个页面的浅深主题，以及展开项、菜单、确认弹层、键盘避让、原生编辑器和草稿保留。键盘测试通过缩小可视区域模拟；不能代替 Android 真机验收。

展示数据由测试注入，没有 KernelSU bridge，不会执行设备命令。截图、失败追踪保存在已忽略的 `test-results/` 中；测试不重试，失败须查明原因。
