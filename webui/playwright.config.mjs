import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./e2e",
  timeout: 60_000,
  expect: { timeout: 5_000 },
  fullyParallel: true,
  forbidOnly: Boolean(process.env.CI),
  retries: 0,
  workers: 2,
  reporter: "list",
  use: {
    baseURL: "http://127.0.0.1:4174",
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
    command: "npm run dev -- --port 4174 --strictPort",
    url: "http://127.0.0.1:4174",
    reuseExistingServer: !process.env.CI,
    timeout: 30_000,
  },
});
