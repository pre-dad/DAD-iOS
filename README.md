# DAD iOS

SwiftUI donor and partner app backed by DAD-Main's Go API. Separate native apps
were selected on 18 October 2026, superseding the earlier cross-platform plan.
The shared R1 product contract governs functionality; provider and device acceptance
boundaries are listed below.

## Build and test

Requires Xcode 27+, its iOS Simulator runtime, Swift 6.2+, and Node 24. No Apple team,
production certificate, or signing key is required for simulator builds.

```sh
node scripts/prepare-client.mjs
open DAD.xcodeproj
```

Select the shared DAD scheme and an iPhone simulator. A Debug build with no `DAD_API_ORIGIN` uses a clearly
labeled synthetic account through the same session API as a configured deployment. Release
builds compile out every preview double and ignore `--preview-*` launch arguments; an
unconfigured Release build shows the unavailable state instead of sample data.
Run `bash scripts/check-ios.sh` for contract verification, Swift unit tests, and simulator
journeys. `DAD_SIMULATOR_ID`, `DAD_SWIFT_BUILD`, and `DAD_XCODE_BUILD` override the simulator
and disposable build paths. Unit tests alone: `swift test --scratch-path ~/.cache/dad-ios-swift` (add `--disable-sandbox`
when running inside a tool that already sandboxes processes).

CI executes that same script. The pinned Apple generator plugin is trusted explicitly
with `-skipPackagePluginValidation`; compilation and tests remain enabled. Xcode's benign
AppIntents metadata-extraction diagnostic is not suppressed; this app defines no intents.

## Shared contract and native boundaries

`foundation.lock.json` pins mobile foundation 2.11.0 and its manifest digest. The vendored
release is verified before generation. `prepare-client.mjs` copies the Swift generator input, null-only Codable adapter, tokens,
and link policy into ignored generator inputs. Apple's pinned Swift generator produces
types and a client during the build, scoped to profile, claim, refresh, and logout.
Generated files are not hand-edited or separately maintained. Dependency revisions are
locked in `Package.resolved` and the Xcode workspace's SwiftPM lock.

`AccountSession` owns one shared refresh operation, atomic credential replacement,
revocation, bounded read retry, and logout/account-switch race protection. Keychain uses
non-synchronizing `WhenUnlockedThisDeviceOnly` items. Tokens and proofs are redacted from
value descriptions; they are never logged. URLSession rejects redirects, sends no
browser cookies or Origin, limits responses to 1 MiB, and has request/resource timeouts.
Canceling a read does not cancel another caller's shared refresh. An in-flight refresh
can finish after local logout so remote logout uses the newest known access token;
its result cannot restore local credentials. Offline remote logout can fail after local
cleanup; errors propagate rather than claiming a confirmed remote revocation.

Set Xcode build settings `DAD_API_ORIGIN` and `DAD_PUBLIC_ORIGIN` to the direct HTTPS API
origin and public website origin for a real environment, and `DAD_ASSOCIATED_DOMAIN` to the public origin's host
(also the passkey relying party): `App/DAD.entitlements` declares it as the `applinks:` and `webcredentials:` associated
domain, which DAD-Main's `/.well-known/apple-app-site-association` answers for. No production hostname or secret
is compiled by default. A Release build with no API origin shows an unavailable state and sign-in fails
with a clear message; it never serves synthetic data. Wired against the API: donor phone + SMS sign-in
(`beginPhoneSignIn`/`finishPhoneSignIn`, existing accounts only), claim-link sign-in, profile read,
settings load/save, refresh, logout and account deletion. All authenticated calls go through
`AccountSession.authorized` (single-flight refresh, one bounded 401 retry, epoch-guarded). Also wired
(P1b): new-donor email signup (`postDonorSignup`; the emailed link is claimed in-app, tapped or pasted),
email + password sign-in (`postDonorPasswordSignIn`) and set/change password in Settings
(`postDonorMePassword`). Built and tested but **switched off until configured**: Sign in with Apple, Google
and passkeys (see below). Also wired (P2, donor home reads): the dashboard (`dashboard`: streak card with
30-day bar and next milestone, rank line, total given, network, referral totals; `preparing` and the
null/unknown figures are shown as such, never as zero), today's initiative (`todayInitiative`, 404 = nothing
in rotation), paged gift history (`gifts`, 50 a page, capped at 500 rows in memory) with a per-gift record
(`receipt`) and the calendar-year total (`annualSummary`). Engagement is wired too (see Engagement). The
partner portal is wired: an approved partner user signs in with an emailed link (`partnerRequestSignIn`, then
`partnerAcceptInvite` from the tapped or pasted `/partner/accept` link), and the 12-hour partner session is kept
in its own Keychain item. The portal reads the overview, initiatives, spend, our-people rollup and teams;
admins edit the organization profile, workforce size and logo, invite and remove users, share the company
code and export or re-download PDF reports. Partner calls use the native bearer path (`X-DAD-Client: native`, `Authorization: Bearer`; DAD-Main's
`partnerSession` accepts it on every partner route), and every status maps the same way: 401 ends the 12-hour session, 403 is a
role refusal, 404, 409, 422 and 429 (including the ingress limiter's body-less 429) each have their own message. Role, initiative
status, metric unit and application status are open strings, so a value added later cannot fail a portal read (an unknown role is a
viewer). A new partner applies from partner sign-in (`applyWithReceipt`, contract 2.11; the website's `<public origin>/apply` stays
linked): the app generates the 43-character receipt, keeps it in its own Keychain item before sending, and repeats the same
`Idempotency-Key` and receipt when an attempt is unconfirmed (a 503, a lost connection or a 429, whose `Retry-After` is shown). A
422, 409 or 403 forgets the receipt and unlocks the form. The status card above sign-in reads `applicationStatus` with the receipt
as bearer, and the receipt is forgotten once an approval or rejection has been shown, or when the server answers 401. Analytics and push are described below. Native entry hooks
handle cold/foreground URLs through the origin/path policy. Profile destinations can
wait for sign-in. Email-change, referral, and other unimplemented destinations use the
website in Safari, without sending bearer credentials. Claim links with supported dashboard or payment-method return destinations are
claimed in-app and open the requested native screen.

### Switching on Apple, Google and passkeys

These methods are implemented (Wire conformers, models, UI states, stub-transport tests) but show
"Not available yet" because the build carries none of the account-held configuration. Nothing here is
invented or committed; supply, per method:

- **Sign in with Apple:** a signing team, the "Sign in with Apple" capability
  (`com.apple.developer.applesignin` entitlement) on the app ID, then build setting
  `DAD_APPLE_SIGNIN_ENABLED=YES`. DAD-Main must also have Apple configured (`oidcSignIn` is 503 otherwise).
- **Passkeys:** the Associated Domains capability on the app ID with `DAD_ASSOCIATED_DOMAIN=<domain>` (the
  entitlement's `webcredentials:` entry), an `apple-app-site-association` file for that domain listing the final
  bundle ID, and build setting `DAD_PASSKEY_RP_ID=<domain>` (bare hostname, the relying-party ID DAD-Main uses).
- **Google:** build setting `DAD_GOOGLE_CLIENT_ID=<id>.apps.googleusercontent.com` **and** a Google id_token
  provider. The official SDK is a new dependency, so none is linked; Google stays off (a client ID alone
  does not enable it) until that decision is made and the provider replaces `UnavailableIDTokenProvider`.

Passkey list/delete are wired and tested in `WirePasswordSettings`; their Settings UI and passkey
registration (`beginDonorPasskeyRegister`/`finishDonorPasskeyRegister`) follow with the entitlement.

System universal links/passkeys require a final bundle ID, signing team, the Associated
Domains capability (the app declares `applinks:` and `webcredentials:` for `DAD_ASSOCIATED_DOMAIN` in
`App/DAD.entitlements`), and DAD-Main's association file naming the app (`DONOR_IOS_APP_ID`).
The app ships under `org.dad.foundation` (Release) and `org.dad.foundation.debug` (Debug); see
"Bundle identifier" below. Neither is registered with a signing team or Associated Domains yet.
Notification permission is asked only from Settings ("Turn on notifications"), never at launch. The camera is
requested only when a donor opens the check-in scanner (see Events). A reachable staging API
and real-device/provider acceptance remain separate from synthetic tests.

The version 2 Swift input preserves nullable dashboard, recurring, and event values
without the generator's standalone-null omissions. The canonical API schemas remain
in the release unchanged. Apps expanding into payment updates must add the
`DADLiteralNull: DADNullValue` generator type override, as the DAD-Main probe does;
the bundled Codable adapter rejects any non-null completed-payment URL. Keep response
compatibility tests when adding operations. Go continues to compute account figures.

## Contract updates

Download an explicit `mobile-foundation-vX.Y.Z` release from `pre-dad/DAD-Main`, review
its source and changes, then replace the vendored snapshot and lock together. Never
fetch a moving branch during builds. `node scripts/check-foundation.mjs` verifies every
file hash, source revision, and version; its tests demonstrate tamper detection.

## Giving (recurring gift, payment method)

The donor home shows a "Your monthly gift" card; "Manage gift" opens the gift screen, bound to the real
`WireGiving` (`recurring`, `amountOptions`, `changeAmount`, `cancelRecurring`, `paymentMethod`,
`beginPaymentUpdate`) through the same authorized session as every other read.

- **Card data never enters the app.** Starting a gift and updating the card both open a page hosted outside
  the app in the system's secure Safari view (`SFSafariViewController`). When it closes (Done or swipe down)
  the app re-reads the server a bounded number of times until it reflects the outcome, then says what it found.
  No callback URL, custom scheme or Associated Domain is needed for this, so nothing extra is required from you.
- **Commands are idempotent.** Each command carries a version 4 `Idempotency-Key`; a retry after a timeout,
  429 or 503 reuses the key, and a success or a definitive refusal (403/409/422) retires it. Buttons are
  disabled while a request is in flight.
- **Starting a gift is native** (contract 2.6.0). The donor picks a daily amount ($1-$30) and "Start a monthly gift"
  calls `startRecurringCheckout` (`POST /donor/me/recurring/checkout`, bearer plus the native client header,
  body `{amount_minor}` = the chosen amount, with an `Idempotency-Key` under the same reuse/retire rules as the other
  commands). The returned Stripe-hosted `url` opens in the same in-app Safari view. Closing it starts the bounded
  re-read of `GET /donor/me/recurring`; the return page does not prove payment, only the server's state does.
  409 (gift already active, checkout still open, or key reused for another amount) re-reads and tells the donor;
  503 with `PAYMENTS_UNCONFIGURED` shows "Giving isn't available right now". There is no `/donate` website fallback.
- **Return-to-app link (optional).** Checkout returns to `<DONOR_NATIVE_RETURN_ORIGIN>/app/return`. For that link to
  reopen the app you need Associated Domains (`applinks:<return host>`) and `/app/return` in the
  apple-app-site-association `components` (see DAD-Main `docs/operations.md`). Without it the donor closes the
  Safari view and the re-read picks the gift up.
- **`Subscription.status` is an open set.** The contract enumerates six values but Stripe can also send `paused`,
  `trialing`, ...; `prepare-client.mjs` strips that enum (like `Problem.code`) so an unknown value decodes as a string.
- **Account deletion and gifts.** A deletion refused with 409 ("monthly gift still renews / checkout open")
  now offers "Cancel my monthly gift", which opens the real cancel flow; deleting again then goes through.
- Not covered: pause/resume (not in the contract), Apple Pay in-app (gated on the nonprofit decision), and the
  real Stripe pages (device/staging acceptance).

## Events (P4)

Real `WireEvents` over the generated client, behind `EventsService`: the list (`donorEvents` merged with
`inviteOnlyEvents`, de-duplicated, soonest first), detail (`donorEventDetail`), reserve / join waitlist
(`reserveEvent`), cancel (`cancelEvent`), check-in (`checkInEvent`) and the authenticated `.ics`
(`donorEventCalendar`). The donor home has an Events card; the list opens an in-place detail.

- **Statuses.** 401 refreshes once then signs out; 403 reads "not eligible" (reserve / cancel / check-in);
  404 "no longer available" (also what the server answers for an invite-only event the donor has not
  unlocked); 409 (full, started, booking not open, reservation changed) refreshes the list and says so;
  422 on check-in explains the three real causes; 429 with or without a body is "too many attempts".
  A failed command never changes what is on screen, and a second tap while one is running is ignored.
- **Idempotency.** The contract defines no `Idempotency-Key` for these commands, so none is sent.
- **Booking rules.** Cancel is offered until the event starts (E-9); a started event offers no new
  reservation; `early_booking` lets a Team Captain reserve before it opens to everyone (B-3); capacity 0
  is "open to everyone". Times use the event's `time_zone`, with the zone abbreviation and the donor's locale.
- **Check-in.** Only a held seat, only between the event's start and end (the contract's window, not an
  assumed early grace). Outside it the panel says when it opens or that it closed. A typed code always
  works; "Scan QR code" opens the camera scanner (AVFoundation, QR only). The camera is requested at that
  moment through `CameraPermission`; denied or no camera falls back to the typed code. Needs
  `NSCameraUsageDescription` (set); no entitlement. **The live camera capture itself needs a device to
  verify**: the simulator has no camera, so CI covers the typed-code path and the permission states only.
- **Add to calendar.** The `.ics` is fetched with the donor's bearer, written to a temporary file and
  offered through the system share sheet, where the donor picks Calendar. The app never reads or writes the
  calendar, so there is no calendar permission or entitlement.
- **Report an issue.** The event's `report_issue_url` (mailto) opens the mail composer.
- **Elsewhere.** Reminder pushes (E-7) are sent by the server to the registered device (see Analytics and push);
  E-1 volunteer opt-in is a settings preference and is not part of this screen.
- **Test stub.** `--stub-backend --stub-signed-in` serves five scripted events (`--stub-events-ungated`
  hides the invite-only one, `--stub-events-fail-first` fails the first list read).

## Engagement (P5)

Real `WireEngagement` behind `EngagementService`, opened from the donor home ("See your impact"):
lifetime impact and rank from `dashboard`, the 24-badge grid (`donorBadges`; earned / locked and the perk are
stated in text, perk gating follows the server catalog codes F / 1K / TC), the referral network
(`donorNetwork`: invitees by first name and last initial, anonymous count, next milestone), the invite
(`sharing` + `conversions`) and the rankings choice (`profile` + `savePreferences`, explicit
`rankings_opted_out`; the card flips at once and reverts with an inline notice if the save fails). Today's
initiative card opens the spend drill-in (`initiativeSpend`, A-3).

- **Unknown is not zero.** Each section the server did not give shows "can't be shown right now" (or "—"); an
  unreadable section never becomes an empty grid, a zero or "not ranked".
- **Rank label.** `national_percentile` is already the top bucket, so 2 reads "Top 2% nationally".
- **Invite links** are `<DAD_PUBLIC_ORIGIN>/r/<code>` (the route the web app and the router serve), the QR adds
  `?via=irl` and is drawn locally with CoreImage. With no configured public origin there is no link, never an
  invented one. A donor with no public name gets a prompt to choose one (`saveSharing`).
- **Not covered.** The `referralCode` SVG op is unused (the QR is local). Contract enum `Conversion.kind` is
  generated as an open string (`prepare-client.mjs` fails if it is not found).
- **Test stub.** `--stub-backend --stub-signed-in` serves badges, network, sharing, conversions and a spend
  (`--stub-rankings-fail-toggle`, `--stub-no-public-name`, `--stub-badges-down`).

## Real backend acceptance

From the matching DAD-Main checkout, run `make test-native-clients` with
`TEST_DATABASE_URL` naming its migrated synthetic `donor_go` database. Override
`DAD_IOS_DIR` and `DAD_ANDROID_DIR` when the checkouts are elsewhere. This opt-in
suite exercises the actual generated client and session store against a loopback
HTTPS Go API: claim/profile, expired-access refresh and credential replacement,
revocation cleanup, and logout. Test-only transports trust the temporary server's
certificate; production TLS settings are unchanged. No provider credentials are used.
The test runner removes the private proof fixtures after either success or failure.

## Release readiness (App Store)

**In-app account deletion (required).** The settings screen offers in-app account deletion
(§6.12) behind a typed-word confirmation, and the flow wipes the local session through
`AccountSession`. In a configured build the confirmed deletion calls `POST /donor/me/delete`, and only on
success wipes the local session and attribution state and returns to sign-in; a 409 (an active monthly gift or
open checkout) is surfaced as a recoverable error and nothing local is wiped. Disclose in the App Store "Account Deletion"
question that personal data is deleted while aggregate/receipt records required by law are
retained.

**Privacy disclosure (App Store Privacy "nutrition label").** The app collects: email and phone
(account), approximate location via ZIP (streak day boundary, nearby events), and gift history.
No third-party analytics SDK is embedded — analytics events go only to the first-party DAD-Main
ingest endpoint, and only after the donor allows them. No tracking across apps/sites; no IDFA. Declare Contact Info,
Coarse Location, and Financial Info as "used for app functionality", and Product Interaction as "analytics",
none of them used for third-party advertising (matching `App/PrivacyInfo.xcprivacy`).

**Entitlements / capabilities** required before submission (not needed for simulator builds):
Push Notifications (APNs) for §6.11 categories, Associated Domains (`applinks:` +
`webcredentials:`) for universal links and passkeys, and — if in-app giving ships rather than the
Stripe web handoff — the Apple Pay / In-App Purchase entitlement per the final §10 decision.

**Bundle identifier.** The app ships under the production identity `org.dad.foundation` (Release),
with `org.dad.foundation.debug` for Debug builds so a dev build installs alongside a release build
(the mirror of DAD-Android's `.debug` suffix). The keychain service is derived from the running
bundle id, so the two variants never share a credential store. The UITest targets follow the host
app (`org.dad.foundation.uitests` / `.debug.uitests`).

### Device-gated hardening (manual, pre-submission — not CI-automatable)

These Phase H items require a real device / Instruments and are tracked as a manual pre-submission
checklist; they cannot run on the CI simulator:

- [ ] Instruments Leaks/Allocations pass over signup → gift, events, and the partner dashboard.
- [ ] VoiceOver walk, Dynamic Type XXL, and contrast audit on device.
- [ ] Performance on a throttled network: dashboards < 2s, checkout < 60s (PRD §10).
- [ ] Real-device APNs delivery; Apple Pay or the Stripe web handoff end-to-end.
- [ ] Universal-link + deferred-attribution acceptance on a clean install.
- [ ] Offline and flaky-network walk (airplane mode mid-checkout, mid-sign-in, mid-reservation) on device.
- [ ] Certificate handling: the app relies on system trust with ATS defaults (no exceptions, HTTPS-only origin
      check); decide before launch whether DAD wants pinning, which is an operational burden on cert rotation.
- [ ] Confirm `App/PrivacyInfo.xcprivacy` (collected data types, UserDefaults reason `CA92.1`) matches the
      final App Store privacy answers before submission; counsel owns the disclosure wording.

### Signing (manual, account-held — not committed, not CI-verified)

Code signing needs an Apple Developer account's team, certificate, and provisioning profile,
which are yours and are never committed. CI builds with `CODE_SIGNING_ALLOWED=NO`, so signing is
exercised only at archive/submission time. Pre-submission:

- [ ] Set `DEVELOPMENT_TEAM` for the archive build (an xcconfig or the archive command, kept out
      of the repo), and confirm `CODE_SIGN_STYLE` matches your provisioning (Automatic, or Manual
      with an explicit profile).
- [ ] Register the `org.dad.foundation` App ID in the developer portal with the Push Notifications
      and Associated Domains capabilities enabled.
- [ ] Produce an `ExportOptions.plist` for `xcodebuild -exportArchive` (method `app-store`, your
      team id) — gitignored, not committed.
- [ ] Verify the archived build is signed with the distribution certificate before upload.

## Scale (50,000 users now, 1,000,000 within a year)

- **Nothing polls.** Screens read on open and on explicit refresh; there are no timers hitting the API. The one
  bounded re-read loop runs after the hosted checkout sheet closes. A cold launch costs a profile read, the
  dashboard and today's initiative reads, and one push-device registration; steady state is a handful of requests
  per user per day.
- **Retries cannot storm.** Authenticated reads retry at most once after a 401 (single-flight refresh, so N
  concurrent calls make one refresh request). Idempotent commands reuse their key on a retry and honor
  `Retry-After`. Analytics back off exponentially and are capped at 500 buffered events.
- **Payloads are bounded.** Responses are capped at 1 MiB, gift history pages at 50 rows (500 in memory), analytics
  batches at 100 events.
- **Server-side pressure to plan for.** A push-driven open (an event reminder to all attendees) arrives within
  seconds, so the dashboard, initiative and registration endpoints need headroom for a launch-minute burst; the
  push sender should jitter or batch sends. Client requests carry no jitter on launch; add server-side
  rate limiting and cache the public initiative read at the edge.

## Analytics and push (contract 2.9.0)

**Analytics are opt-in**, worded and counted as on the website. The start screen asks once ("Allow usage
analytics?") and Settings has a "Usage analytics" switch; until the donor allows it nothing is recorded. Events go
only to DAD-Main's `ingestAnalytics` (first party, `X-DAD-Platform: IOS`, attributed to the donor when signed in)
through `AnalyticsRecorder`, in batches of up to 100 with a stable id each so a retried batch is not double-counted;
declining drops anything still buffered. Offline, at most 500 events are kept (oldest dropped), and after a failed
upload new events do not retry until an exponential backoff (30 s doubling to 15 min) has passed. The app emits `app_opened`, `role_selected`, `invite_shared`
(`share_sheet` / `copy`), `irl_code_shown` and `push_opened`; every other event is derived from the successful API
call it stands for by the same rules as the website's `observeAPI` (`ObservingTransport`), e.g. `signup_started`
for `POST /donor/signup`.

**Push** registers the donor (`registerPushDevice`, at every launch and sign-in; the server drops the token when the
session ends) and the partner (`partnerRegisterPushDevice`, unregistered on sign-out), with the APNs environment of
the build (Debug `SANDBOX`, Release `PRODUCTION`). A tapped notification's `category` is counted as `push_opened`
and its `path` opens the matching screen (`/account/gifts` gift history, `/account/payment-method` the gift sheet,
`/account/profile` Settings), after sign-in if need be. **Owner dependency:** APNs issues a device token only to an
app with the Push Notifications capability (`aps-environment` entitlement) under the signing team, and DAD-Main
needs its APNs key; until then the permission can be granted but no token is registered. `--stub-push-tap-gifts`
replays a tap in UI tests.

**Referral and company-code links (contract 2.10).** An invite (`/r/<code>`, `?via=irl` in person) or company
(`/c/<code>`) link that opens the app is recorded with DAD-Main (`captureReferral` / `captureCompany`), and the visitor
token it returns is kept where the website keeps its cookie (`LinkAttribution`, `UserDefaults`; the latest link wins,
and a visit that keeps nothing discards it). The referral token goes with the first monthly gift
(`startRecurringCheckout`'s `referral_token`, part of the command's idempotency fingerprint), so the referrer is credited
as on the web; the company token is bound once the donor is signed in (`bindCompanyTouch`). Before sign-in an invite
names the referrer on the start screen. Account deletion forgets both. `--stub-open-invite` replays an invite link in
UI tests.
