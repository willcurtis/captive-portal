function escapeHtml(value: string): string {
  return value.replace(/[&<>'"]/g, (character) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;'
  })[character] ?? character);
}

function layout(title: string, body: string): string {
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="theme-color" content="#07110e"><title>${escapeHtml(title)} · The Tech Shed</title>
<link rel="stylesheet" href="/assets/styles.css"></head>
<body><main class="shell"><section class="card">
<div class="site-brand"><img src="/assets/tts-logo.png" width="512" height="512" alt="The Tech Shed"></div>
${body}</section></main></body></html>`;
}

export function welcomeView(ssid: string, csrf: string): string {
  return layout('Guest WiFi', `<p class="eyebrow">${escapeHtml(ssid)}</p><h1>Welcome to guest WiFi</h1>
<p>Connect securely to the internet. Access is provided subject to our acceptable-use and privacy terms.</p>
<form method="post" action="/authorize">
<input type="hidden" name="csrf" value="${escapeHtml(csrf)}">
<label class="terms"><input name="acceptTerms" type="checkbox" value="yes" required> <span>I accept the <a href="/terms" target="_blank">Terms of Use</a> and <a href="/privacy" target="_blank">Privacy Notice</a>.</span></label>
<button type="submit">Connect to WiFi</button></form>`);
}

export function resultView(success: boolean, redirectUrl?: string): string {
  return layout(success ? 'Connected' : 'Unable to connect', success
    ? `<div class="status success" aria-hidden="true">✓</div><h1>You're connected</h1><p>You can close this window and continue browsing.</p>${redirectUrl ? `<a class="button" href="${escapeHtml(redirectUrl)}">Continue</a>` : ''}`
    : '<div class="status error" aria-hidden="true">!</div><h1>We could not connect you</h1><p>Your session may have expired. Disconnect and reconnect to the guest WiFi, then try again.</p>');
}

export function policyView(kind: 'terms' | 'privacy'): string {
  return layout(kind === 'terms' ? 'Terms of Use' : 'Privacy Notice', kind === 'terms'
    ? '<h1>Terms of Use</h1><p>Use this network lawfully and responsibly. Do not interfere with the network, other users, or connected systems.</p><p class="note">Replace this placeholder with terms approved for your organisation before launch.</p>'
    : '<h1>Privacy Notice</h1><p>The portal processes device and connection information to provide and protect guest network access.</p><p class="note">Replace this placeholder with a privacy notice approved for your organisation before launch.</p>');
}
