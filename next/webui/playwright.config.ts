import { defineConfig } from '@playwright/test';
export default defineConfig({
  testDir:'./tests', testMatch:'*.spec.ts', fullyParallel:false, workers:1, retries:0,
  reporter:[['list'],['json',{outputFile:'test-results/report.json'}]],
  use:{browserName:'chromium', headless:true,
    launchOptions:process.env.PLAYWRIGHT_EXECUTABLE_PATH ? {executablePath:process.env.PLAYWRIGHT_EXECUTABLE_PATH,args:['--no-sandbox']} : {},
    trace:'retain-on-failure', screenshot:'only-on-failure'},
});
