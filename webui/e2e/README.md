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

覆盖 320 / 360 / 390 / 430px、横屏、桌面，13 个页面的浅深主题，以及展开项、菜单、确认弹层、焦点恢复、键盘避让、原生编辑器和草稿保留。键盘测试通过缩小可视区域模拟；不能代替 Android 真机验收。

页面截图按「页面 × 主题 × 尺寸」独立运行，每个用例使用新的浏览器上下文并直接打开对应页面，避免前序页面的缓存和状态影响截图。跨页切换、草稿保留仍由独立的交互回归覆盖。截图超时为 20 秒，不以重试掩盖失败。

展示数据及原生命令响应由测试注入，不会执行真实设备命令。截图、失败追踪保存在已忽略的 `test-results/` 中；测试不重试，失败须查明原因。自定义输出目录应放在源码目录之外，避免追踪文件触发 Vite 自动刷新。
