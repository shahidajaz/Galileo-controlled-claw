#!/usr/bin/env node
// One-time Webex OAuth setup for a user's OWN integration (BYO).
// Usage:
//   node oauth-setup.mjs url            -> prints the authorize URL to open in a browser
//   node oauth-setup.mjs exchange <code> -> exchanges the ?code=... for tokens, stores refresh token
//   node oauth-setup.mjs verify          -> confirms the stored token works (GET /people/me)
// Credentials (clientId/clientSecret/redirectUri) must already be in the settings
// file (WEBEX_SETTINGS, default ~/.openclaw/webex.json) - each user sets their own.
import { buildAuthorizeUrl, exchangeCode, webex, isConfigured, loadSettings } from "./webex-client.mjs";

const [cmd, arg] = process.argv.slice(2);

try {
  if (cmd === "url") {
    const s = loadSettings();
    if (!s.clientId || !s.redirectUri) {
      console.error("Set clientId + clientSecret + redirectUri in your webex settings first.");
      process.exit(1);
    }
    console.log("\nOpen this in a browser, log in, and approve:\n");
    console.log(buildAuthorizeUrl());
    console.log("\nWebex will redirect to your redirectUri with ?code=...  Then run:");
    console.log("  node oauth-setup.mjs exchange <code>\n");
  } else if (cmd === "exchange") {
    if (!arg) { console.error("usage: node oauth-setup.mjs exchange <code>"); process.exit(1); }
    const j = await exchangeCode(arg);
    console.log(`Stored refresh token (valid ${Math.round((j.refresh_token_expires_in || 0) / 86400)}d, resets on use).`);
    console.log("Verifying...");
    const me = await webex.me();
    console.log(`OK, authorized as: ${me.displayName} <${(me.emails || [])[0]}>`);
  } else if (cmd === "verify") {
    if (!isConfigured()) { console.error("Not configured (need creds + refresh token)."); process.exit(1); }
    const me = await webex.me();
    console.log(`OK, authorized as: ${me.displayName} <${(me.emails || [])[0]}>`);
  } else {
    console.log("usage: node oauth-setup.mjs {url | exchange <code> | verify}");
  }
} catch (e) {
  console.error("ERROR:", e.message);
  process.exit(1);
}
