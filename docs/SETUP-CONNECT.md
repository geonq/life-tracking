# Connecting your data — the actual steps (geonq)

Plain-English version of what *you* physically do to light up each data source. Honest about
effort: one of these is a single tap; the rest need a one-time setup because the providers
(banks, AI vendors, Google) legally/technically can't be connected from a phone alone.

## 1. Fitness / Health — EASY, one tap ✅
The code is already built. You do:
1. Install the signed LifeOS build on your iPhone (from Xcode, "georg" device).
2. Open LifeOS → Fitness → **Connect Health** → tap **Allow** on the Apple Health sheet.
Done. Your Apple Health / Helio / Whoop data flows in. No accounts, no keys, no PC.

## 2. AI usage (your Codex/Claude numbers) — needs a tiny background helper on your machines
There is no "log in on your phone" for *usage* stats — they live in the CLI files on the
machine you code on. So:
1. On your **Windows PC**, the LifeOS gateway must be running (Codex's server; the `lifeos-server`
   repo — not this one).
2. Turn on **BitLocker** on the Windows C: and D: drives (hard requirement before any credential
   touches the PC).
3. A small forwarder reads `~/.codex` / Claude usage and pushes it to the gateway.
Then LifeOS shows real usage. Your part: turn on BitLocker + run the gateway. The rest is built.

## 3. Bank (spending / balances) — needs a GoCardless account (one-time)
Open-Banking law requires a licensed aggregator; you can't connect a bank from the app directly.
1. Create a free **GoCardless Bank Account Data** account, register an app, get the API key.
2. Put that key on the **Windows gateway** (never in the app / this repo).
3. In LifeOS → Settings → **Connect bank** → pick Sparkasse / Revolut → you'll be sent to your
   bank's real consent screen → approve. Balances/transactions flow in.
Your part: the GoCardless signup + dropping the key on the PC. The consent tap is in-app.

## 4. Revolut Business — official Revolut API app (one-time), same pattern as #3.

## 5. Food photos (Gemini) — a Google Cloud key (one-time)
1. Create a Google Cloud project, enable the Gemini API, make a **dedicated restricted key**.
2. Put it on the **Windows gateway** only.
Then the food-photo estimate works. Your part: the key; it never leaves the PC.

---
### The short version
- **Today, zero setup:** Health (tap Allow).
- **Needs BitLocker + the gateway running:** AI usage.
- **Needs a free provider signup + a key on the PC:** bank, Revolut Business, Gemini.

I'm building every in-app "Connect" flow + state so that the moment you do the above, it lights
up — no fake buttons, honest "not connected" until then.
