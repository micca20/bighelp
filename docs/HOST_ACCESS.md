# Reaching Hermes behind a proxy or Cloudflare Access

Many people put Hermes behind something that checks requests before Hermes
sees them: Cloudflare Access, a reverse proxy with a password, or a proxy such
as Pangolin that checks its own headers. bighelp can get past each of these,
then signs in to Hermes as usual.

Everything here is set per host, under **Advanced connection** when you add a
host, or later in **Settings › Hosts › (host) › Advanced connection details ›
Edit access**.

## How bighelp handles these values

- They're stored in the iPhone Keychain for that one host address, on this
  device only (not synced to iCloud).
- They're sent with every request and every live connection (WebSocket) to that
  exact address, and nowhere else.
- bighelp refuses redirects from the host, so a value can never follow a
  redirect to another site.
- Secrets are masked on screen and never written to logs or diagnostics.
- They go only to `https://` addresses, or to a private network address (home
  Wi‑Fi, VPN, Tailscale) where you turned on HTTP. They never go over plain HTTP
  on the open internet.

## Cloudflare Access (service token)

Use this when Hermes is published through a Cloudflare Tunnel and protected by
Cloudflare Access. The app has no browser session with Cloudflare Access, so
it proves itself with a service token instead.

1. In Cloudflare Zero Trust, open **Access › Service credentials › Service
   Tokens** and choose **Create Service Token**. Copy the
   **Client ID** and **Client Secret**; the secret is shown only once.
2. Open the Access application that protects your Hermes hostname and add a
   policy:
   - **Action:** Service Auth
   - **Include:** Service Token, then pick the token you created

   Keep your other policies (for example your email login) for browsers. A
   Service Auth policy lets the token through without a login page.
3. In bighelp, add the host with its `https://` address. Under **Advanced
   connection**, turn on **Cloudflare Access** and paste the Client ID and
   Client Secret.

bighelp sends them as `CF-Access-Client-Id` and `CF-Access-Client-Secret`.
Cloudflare Access needs an `https://` address.

**If Cloudflare Access refuses the token**, bighelp says "Cloudflare Access didn't let
bighelp through." Check the Client ID and Secret, that the token hasn't
expired or been revoked, and that the application has the Service Auth policy
above. If the address sends bighelp to a Cloudflare Access login page
instead, no token was sent: turn on Cloudflare Access for the host.

**Browser sign-in:** Hermes's browser sign-in option opens Safari, which
doesn't carry the service token, so Cloudflare Access shows its own login
there. Sign in to Cloudflare Access in that browser too, or use a Hermes
access token or username and password sign-in instead.

## Username and password on a proxy (basic auth)

For nginx, Caddy, Traefik and similar proxies set up with a username and
password (HTTP basic auth). Turn on **Username and password** under Advanced
connection. If you forget, bighelp notices the proxy asking and opens these
fields for you.

A host uses either a Cloudflare Access service token or a proxy username
and password, not both.

## Custom headers

For a reverse proxy that checks its own headers, such as Pangolin or an nginx
rule like `if ($http_x_access_secret != "…") { return 403; }`. Under Advanced
connection, choose **Add header** and enter each name and value, for example
`X-Access-Id` and `X-Access-Secret`. They can be combined with a
Cloudflare Access service token or a proxy password.

- Up to 16 headers. Names are letters, numbers and dashes; values can't contain
  line breaks.
- Some names are set by bighelp itself and can't be used: `Authorization`,
  `Cookie`, `Host`, `Content-Type` and other standard request headers,
  `Sec-*` (WebSocket), `X-Hermes-*`, `X-Loopdy-*` and `CF-Access-*` (use the
  Cloudflare Access option for those).
