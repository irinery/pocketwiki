import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { chromium } from '@playwright/test';

const dir = await mkdtemp(path.join(os.tmpdir(), 'nh00-chromium-page-'));
const pagePath = path.join(dir, 'smoke.html');
await writeFile(pagePath, '<!doctype html><meta charset="utf-8"><main data-testid="nh00-marker">pocketwiki-nh00-local-smoke</main>');
let browser;
try {
  browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();
  await page.goto(pathToFileURL(pagePath).href, { waitUntil: 'load' });
  assert.equal(await page.getByTestId('nh00-marker').textContent(), 'pocketwiki-nh00-local-smoke');
  console.log(`Chromium ${browser.version()} headless local page passed; no sleeps or external requests`);
} finally {
  await browser?.close();
  await rm(dir, { recursive: true, force: true });
}
