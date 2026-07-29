// committedConfig — guards the repo's committed configuration:
// no private Tailnet (CGNAT) addresses, no credential-shaped strings, and the
// platform config keys iOS support depends on.

import * as fs from 'fs';
import * as path from 'path';

const ROOT = path.resolve(__dirname, '..', '..');

function walk(dir: string, out: string[] = []): string[] {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    // __tests__ excluded: fixtures may use example CGNAT IPs (e.g. locality
    // classification tests). The guard targets shipped source and config.
    if (entry.name === 'node_modules' || entry.name === '__tests__' || entry.name.startsWith('.')) continue;
    const p = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(p, out);
    else if (/\.(ts|tsx|js|json)$/.test(entry.name)) out.push(p);
  }
  return out;
}

// The Tailscale/CGNAT range: 100.64/10.
const TAILNET_RE = /\b100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}\b/;

// Common credential shapes. EXPO_PUBLIC_* values are public; nothing
// credential-shaped may appear anywhere in committed source or config.
const SECRET_RES = [
  /sk-ant-[A-Za-z0-9_-]{8,}/, // Anthropic
  /sk-[A-Za-z0-9]{20,}/,      // OpenAI-style
  /ghp_[A-Za-z0-9]{20,}/,     // GitHub PAT
  /xox[baprs]-[A-Za-z0-9-]{10,}/, // Slack
  /AKIA[0-9A-Z]{16}/,         // AWS
  /tskey-[A-Za-z0-9-]{10,}/,  // Tailscale key
  /-----BEGIN [A-Z ]*PRIVATE KEY-----/,
];

const scanTargets = [
  ...walk(path.join(ROOT, 'src')),
  path.join(ROOT, 'app.json'),
  path.join(ROOT, 'eas.json'),
  path.join(ROOT, '.env.example'),
  path.join(ROOT, 'App.tsx'),
];

describe('committed configuration hygiene', () => {
  it.each(scanTargets.map((f) => [path.relative(ROOT, f), f]))(
    '%s contains no private Tailnet address or credential-shaped string',
    (_rel, file) => {
      const text = fs.readFileSync(file, 'utf8');
      expect(text).not.toMatch(TAILNET_RE);
      for (const re of SECRET_RES) {
        expect(text).not.toMatch(re);
      }
    },
  );
});

describe('platform configuration (app.json)', () => {
  const app = JSON.parse(fs.readFileSync(path.join(ROOT, 'app.json'), 'utf8')).expo;

  it('keeps the Android package identifier unchanged', () => {
    expect(app.android.package).toBe('com.aurascoper.neuralcompose');
    expect(app.android.permissions).toContain('RECORD_AUDIO');
  });

  it('declares the iOS bundle identifier and build number', () => {
    expect(app.ios.bundleIdentifier).toBe('com.aurascoper.neuralcomposeclient');
    expect(app.ios.buildNumber).toBeTruthy();
    expect(app.android.versionCode).toBeGreaterThanOrEqual(1);
  });

  it('has microphone usage text because recording exists', () => {
    expect(app.ios.infoPlist.NSMicrophoneUsageDescription).toMatch(/voice|record/i);
  });

  it('never disables App Transport Security broadly', () => {
    const raw = JSON.stringify(app);
    expect(raw).not.toContain('NSAllowsArbitraryLoads');
    expect(raw).not.toContain('NSExceptionDomains');
  });

  it('has a stable URL scheme', () => {
    expect(app.scheme).toBe('neuralcompose');
  });
});
