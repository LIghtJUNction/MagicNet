import { defineConfig } from "@playwright/test";

const port = Number(process.env.MAGICNET_WEBUI_PORT || 4174);
const baseURL = `http://127.0.0.1:${port}`;

export default defineConfig({
  testDir: "./e2e",
  timeout: 60_000,
  expect: { timeout: 5_000 },
  fullyParallel: true,
  forbidOnly: Boolean(process.env.CI),
  retries: 0,
  workers: process.env.CI ? 4 : 2,
  reporter: "list",
  use: {
    baseURL,
    actionTimeout: 5_000,
    reducedMotion: "reduce",
    colorScheme: "light",
    locale: "zh-CN",
    screenshot: "only-on-failure",
    trace: "retain-on-failure",
    launchOptions: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH
      ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH }
      : undefined,
  },
  projects: [
    {
      name: "narrow-320",
      use: { viewport: { width: 320, height: 740 }, hasTouch: true },
    },
    {
      name: "phone-360",
      use: { viewport: { width: 360, height: 800 }, hasTouch: true },
    },
    {
      name: "phone-390",
      use: { viewport: { width: 390, height: 844 }, hasTouch: true },
    },
    {
      name: "phone-430",
      use: { viewport: { width: 430, height: 932 }, hasTouch: true },
    },
    {
      name: "landscape",
      use: { viewport: { width: 844, height: 390 }, hasTouch: true },
    },
    { name: "desktop", use: { viewport: { width: 1280, height: 900 } } },
  ],
  webServer: {
    command: `npm run dev -- --port ${port} --strictPort`,
    url: baseURL,
    // Another checkout can own the same port. Reuse only when explicitly requested.
    reuseExistingServer: !process.env.CI && process.env.MAGICNET_WEBUI_REUSE_SERVER === "1",
    timeout: 30_000,
  },
});
