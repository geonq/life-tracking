# Connecting your data — the actual steps (geonq)

Plain-English version of what *you* physically do to light up each data source. Honest about
effort: one of these is a single tap; the rest need a one-time setup because the providers
(banks, AI vendors, Google) legally/technically can't be connected from a phone alone.

## 1. Fitness / Health — EASY, one tap ✅
The code is already built. You do:
1. Install the signed LifeOS build on your iPhone (from Xcode, "georg" device).
2. Open LifeOS → Fitness → **Connect Health** → tap **Allow** on the Apple Health sheet.
Done. Your Apple Health / Helio / Whoop data flows in. No accounts, no keys, no PC.

## 0. Point LifeOS at your gateway — the master switch (in-app, already built) ✅
Every gateway-fed source below (AI usage, bank summary, Clipper) lights up through ONE in-app
step, and it's already built:
1. In LifeOS → **Settings → Sync & storage**, paste your Windows gateway's `https://<host>.ts.net`
   URL into the server-URL field (it's validated: HTTPS, approved `.ts.net` host, no path/query).
2. Tap **Check secure connection** — it sends one read-only request and shows an honest result
   (reachable / configuration required / server unavailable / etc.).
Once this says reachable, usage + finance summary flow with no further app steps. The phone sends
no bearer/token; Tailscale Serve supplies the device identity to the loopback-only gateway.

## 2. AI usage (your Codex/Claude numbers) — needs a tiny background helper on your machines
There is no "log in on your phone" for *usage* stats — they live in the CLI files on the
machine you code on. So:
1. On your **Windows PC**, the LifeOS gateway must be running (Codex's server; the `lifeos-server`
   repo — not this one).
2. Turn on **BitLocker** on the Windows C: and D: drives (hard requirement before any credential
   touches the PC).
3. A small forwarder reads `~/.codex` / Claude usage and pushes it to the gateway.
4. Do the **Step 0** master-switch once. Then LifeOS shows real usage. Your part: BitLocker + run
   the gateway + paste the URL. The rest is built.

## 3. Bank (spending / balances) — Enable Banking (one-time)
Open-Banking law requires a regulated account-information provider; LifeOS does not connect to a
bank directly from the phone. The reviewed gateway owns the Enable Banking credentials and
consent lifecycle.
1. Register the production Enable Banking application and keep its app ID, private key, and
   public certificate on the BitLocker-protected **Windows gateway** only.
2. In LifeOS → **Settings → Bank connections**, choose **Sparkasse Leipzig** and tap **Connect**.
   Complete the bank-hosted login/2FA consent page, then return to LifeOS and re-check the status.
3. Repeat for **Revolut Personal** after the Sparkasse flow is linked.
4. Once a connection is linked, LifeOS reads `/finance/summary` (via Step 0) and shows only
   observed balances/transactions with source and freshness labels.

The consent initiation and status polling are already implemented. The remaining action is the
end-user bank login/consent itself; no bank password, access token, private key, or certificate
belongs in the app or this repository.

## 4. Revolut Business — official Revolut API app (one-time), same pattern as #3.

## 5. Food photos (Gemini) — a Google Cloud key (one-time)
1. Create a Google Cloud project, enable the Gemini API, make a **dedicated restricted key**.
2. Put it on the **Windows gateway** only.
Then the food-photo estimate works. Your part: the key; it never leaves the PC.

---
### The short version
- **Today, zero setup:** Health (tap Allow, on a real iPhone — not the simulator).
- **The master switch (in-app, built):** Settings → Sync & storage → paste `.ts.net` URL → Check
  secure connection. This alone lights up usage + finance summary once the gateway runs.
- **Needs BitLocker + the gateway running:** AI usage, finance summary.
- **Needs provider credentials on the PC:** Enable Banking, Revolut Business, Gemini.
- **Needs one-time user action:** complete Sparkasse Leipzig and Revolut Personal consent in
  Settings → Bank connections.

Every in-app Connect surface + honest state is already built (AI providers, bank catalog, health
grant, gateway config + connection check). No fake buttons; the app remains honestly unavailable
until the gateway and the selected consent flows exist.
