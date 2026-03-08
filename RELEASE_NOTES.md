# 🚀 Delivery Note: Social Scribe Updates

Thank you for reviewing the **Social Scribe** repository. Below is a summary of the latest features, architectural improvements, and critical bug fixes included in this release.

---

## ✨ New Features & Integrations

* **Unified CRM Architecture:** Implemented a scalable `SocialScribe.CRM` behavior to standardize how the application interacts with external CRMs. This allowed us to build a single, shared UI modal for contact search and AI updates that seamlessly supports multiple providers.
* **Salesforce Integration:** Added Salesforce OAuth support, including secure handling of dynamic instance URLs and SOQL-based contact querying and patching.

---

## 📈 Architectural & UX Improvements

* **OAuth Failure Resilience:** Improved the `AuthController` to handle OAuth failures gracefully. If a user rejects permissions or a platform throws an error during the connection phase, the app now securely redirects the user back to `/dashboard/settings` with a clean flash message.
* **Dependency Auditing & Documentation:** Expanded the `README.md` to clearly document the reasoning behind custom OAuth implementations and provided testing credentials/strategies to bypass temporary platform restrictions (e.g., Meta's "Live Mode" identity checks).

---

## 🐛 Critical Bug Fixes

* **Google OAuth Refresh Tokens:** Fixed a critical issue where Google was failing to return refresh tokens. Explicitly added `access_type="offline"` and `prompt="consent"` as default parameters to ensure persistent API access.
* **Facebook Token Longevity:** Implemented support for **long-lived access tokens** in the Facebook authentication strategy, preventing unexpected session expirations for users managing Pages.
* **CRM Modal UX:** Replaced inline, easy-to-miss errors in the CRM modal with global flash notifications for better user feedback and accessibility.
* **LinkedIn OIDC Integration:** Implemented a custom LinkedIn authentication strategy using OpenID Connect (OIDC). This replaces the standard `ueberauth_linkedin` library to resolve a critical security flaw where secrets were leaked in GET request query strings, which previously caused authentication to be blocked by modern firewalls.
* **CRM Multi-Contact Resolution:** Significantly improved the AI CRM suggestion logic. The system now utilizes contact context to correctly handle and route updates when multiple distinct contacts are discussed in a single meeting transcript (eliminates conflicts when multiple contacts are mentioned in transcript).
* **Bot Poller Synchronization:** Fixed a concurrency bug by synchronizing the bot poller status updates, ensuring accurate database states when polling multiple **Recall.ai** bots simultaneously.
* **Terminal Bot State Handling:** Added defensive handling for terminal API errors (e.g., `:no_recordings`). The system now explicitly transitions failing bots to an error state, resolving a severe bug that caused infinite polling loops.


## 🐛 Limitations

* **Facebook account connection:** Since the facebook app is in development mode, the user needs to be added as a developer to the facebook app to connect their facebook account.