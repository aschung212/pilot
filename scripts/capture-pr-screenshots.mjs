// Captures PR screenshots via Playwright against a running dev server.
// Invoked by capture-pr-screenshots.sh — not a standalone tool.
//
// Args (env vars):
//   BASE_URL     — dev server URL (e.g. http://localhost:5173)
//   OUTPUT_DIR   — where to save screenshots
//   ROUTES       — newline-separated list of routes (e.g. "/\n/workout\n/settings/themes")
//   REPO_DIR     — path to the target repo (used to resolve @playwright/test from its node_modules)
//   PR_TITLE     — PR title (for INDEX.md)
//   PR_URL       — PR URL (for INDEX.md)
//   ISSUE_ID     — issue identifier (for INDEX.md)

import { mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'

// Playwright lives in the target repo's node_modules, not pilot's. Resolve it from there.
const require = createRequire(`${process.env.REPO_DIR}/package.json`)
const playwrightPath = require.resolve('@playwright/test')
const { chromium } = await import(pathToFileURL(playwrightPath).href)

const BASE_URL = process.env.BASE_URL
const OUTPUT_DIR = process.env.OUTPUT_DIR
const ROUTES = (process.env.ROUTES || '').split('\n').map(r => r.trim()).filter(Boolean)
const PR_TITLE = process.env.PR_TITLE || ''
const PR_URL = process.env.PR_URL || ''
const ISSUE_ID = process.env.ISSUE_ID || ''

if (!BASE_URL || !OUTPUT_DIR) {
  console.error('BASE_URL and OUTPUT_DIR are required')
  process.exit(1)
}

if (ROUTES.length === 0) {
  console.error('No routes provided — nothing to capture')
  process.exit(0)
}

mkdirSync(OUTPUT_DIR, { recursive: true })

const slugify = (s) => s.replace(/^\/+|\/+$/g, '').replace(/\//g, '-').replace(/[^a-z0-9-]/gi, '_') || 'home'

const browser = await chromium.launch({ headless: true })
const context = await browser.newContext({
  viewport: { width: 390, height: 844 },
})
const page = await context.newPage()

// Sign in once via the dev button (vite dev only — production builds hide it).
await page.addInitScript(() => {
  localStorage.setItem('onboarding-complete', 'true')
  localStorage.setItem('rest-timer', 'off')
})

let signedIn = false
try {
  await page.goto(BASE_URL, { waitUntil: 'networkidle', timeout: 15000 })
  const devBtn = page.locator('.authDevBtn')
  if (await devBtn.isVisible({ timeout: 5000 }).catch(() => false)) {
    await devBtn.click()
    await page.waitForLoadState('networkidle', { timeout: 10000 }).catch(() => {})
    signedIn = true
    console.log('  ✓ Signed in via dev button')
  } else {
    console.log('  ⚠️  Dev sign-in button not visible — auth-protected routes will show the auth screen')
  }
} catch (e) {
  console.error(`  ⚠️  Initial navigation failed: ${e.message}`)
}

const results = []
let i = 0
for (const route of ROUTES) {
  i++
  const num = String(i).padStart(2, '0')
  const filename = `${num}-${slugify(route)}.png`
  const filepath = join(OUTPUT_DIR, filename)
  try {
    await page.goto(`${BASE_URL}${route}`, { waitUntil: 'networkidle', timeout: 15000 })
    await page.waitForTimeout(500) // let any animations settle
    await page.screenshot({ path: filepath, fullPage: true })
    console.log(`  📸 ${filename}  ←  ${route}`)
    results.push({ route, filename, ok: true })
  } catch (e) {
    console.error(`  ❌ ${route}: ${e.message}`)
    results.push({ route, filename, ok: false, error: e.message })
  }
}

await browser.close()

const indexLines = [
  `# PR Screenshots${PR_TITLE ? ` — ${PR_TITLE}` : ''}`,
  '',
  ISSUE_ID ? `**Issue:** ${ISSUE_ID}` : '',
  PR_URL ? `**PR:** ${PR_URL}` : '',
  `**Captured:** ${new Date().toISOString()}`,
  `**Auth:** ${signedIn ? 'signed in via dev button' : 'NOT signed in — only auth screen visible'}`,
  '',
  '## Routes',
  '',
  ...results.map(r => r.ok ? `- ![${r.route}](./${r.filename}) \`${r.route}\`` : `- ❌ \`${r.route}\` — ${r.error}`),
].filter(l => l !== '')

writeFileSync(join(OUTPUT_DIR, 'INDEX.md'), indexLines.join('\n') + '\n')
console.log(`  ✓ INDEX.md written`)
