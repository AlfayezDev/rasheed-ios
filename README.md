# Rasheed Support for iOS

Native SwiftUI Home, Messages and chat, backed by the shared Rust/UniFFI core.
Swift owns presentation, picking, media playback, previews and export. The core
owns the official SpacetimeDB connection, identity, inbox reads and writes, and
credential-bearing file requests. No web widget or separate Swift transport.

## Install

iOS 18+ and Xcode with Swift 6.2. Add this package and link `Rasheed`:

```swift
.package(url: "https://github.com/AlfayezDev/rasheed-ios", exact: "1.0.0-rc.2")
```

For rich OS images, link `RasheedNotificationService` only to your notification
service extension. It depends on a narrow shared parser/image helper, not
`Rasheed`, CoreFFI, Firebase or customer credentials.

## Retain one client

```swift
import Rasheed

let client = try RasheedClient(
    workspaceId: "workspace-id",
    platformURL: URL(string: "https://support.example.com")!
)
try await client.connect()
try await client.join(language: .en)
try await client.identify(signedIdentity)
```

Use the workspace ID, not a slug. Language is explicit English or Arabic.
`SignedIdentity` contains `payload`, `signature` and `expiresAt` from your
trusted backend. Signing keys never enter the app. See the
[identity-signing protocol](https://www.npmjs.com/package/@qarnos/rasheed).

Observe `client.$snapshot`, `client.$inbox` and `client.$push`, or use `@ObservedObject`.
All observables use the same owned connection. Cached rows are for display
only and never authorize commands. Inbox timestamps are Unix microseconds;
the presentation model converts them to milliseconds for its date formatters.
Relative times ("2 min. ago") count from the server's clock: the core estimates
its offset from the platform's `Date` header, so a device clock that is off
doesn't age them.

A dropped connection comes back by itself, as on the web: the client retries
after 0.5, 1 and 2 s, then every 3 s, each counted from the previous attempt's
start, and at once when the app returns to the foreground or the network path
changes (`NWPathMonitor`). While support is open,
the core asks a connection that has been quiet for 25 s for one round trip and
reconnects if no answer comes within 5 s; the inbox rests while the app is in the
background, so this check does too. Meanwhile the snapshot reads `connecting` or `error` with
`Disconnected`. Refusals, failed actions and unconfirmed identities still wait
for `retry`. The support screens keep their content and the composer its text
and focus. For the first 3 s of an outage they show nothing; then one quiet
"Reconnecting…" under the header's title ("Connecting to support…" before the
first connection), and "Support is unavailable right now." from 30 s. VoiceOver
hears the drop once and "Connected to support" once it is back; a drop within
30 s of the last return stays on screen only.

## Present

```swift
RasheedSupportView(
    client: client,
    locale: .en,
    theme: .system,
    refreshIdentity: { try await hostAccount.freshSupportIdentity() }
)
```

Embed the view or present it. On iPhone support fills the screen, as the web widget does on phones; on iPad it is
a sheet. `RasheedSupportWidget(client:locale:open:)` provides a launcher, badged with the unread replies, and
presents this way; to present `RasheedSupportView` yourself, use `.rasheedSupportPresentation(isPresented:)`.
Either way VoiceOver's escape gesture closes support like the header's close button, Reduce Motion presents and
dismisses it without sliding, and `onDismiss` runs once support has left the screen. The React Native Fabric
widget uses this same native Home/Messages/transcript navigation automatically.

The screens follow the web widget's design. Every screen has one header with
the workspace's logo and name (versioned logo cache; an assigned thread shows
its assignee instead), the language toggle and close. Home's Start a
conversation joins as a guest and opens an empty local draft; Home also has
identity retry and the open conversation. Messages includes the paged
conversation list with who replied and when, unread replies, transcript, older
history, jump to latest, context-menu reply and quote reveal. A thread
marks its replies read while its latest messages are on screen with the app
active; a failure is not retried until the next visit or reply. Its More button
opens support settings: the profile, the web's Sound switch (on by default,
kept per workspace on the device) and the confirmed end-session action.

While support is open, replies play the web's chime (`Sounds/rasheed-chime.wav`,
rendered from the web's cue) by the web's rules: a new
staff or system row in the thread on screen once it has loaded, else a rise in
the other conversations' unread total. After a reconnect it plays once if the
resync brings staff or system replies that weren't shown or counted before the
drop. The customer's own sends, loads, older pages and a cold start never sound,
and the chime plays at most every 600 ms. It
uses the ambient audio session, so it mixes with other audio and respects the
ringer switch; a host that set its own audio category keeps it. Meanwhile an
in-app notification banner for another conversation shows without its sound.
`client.replySound` is the host's mute for every sound the SDK plays.
Background notifications keep iOS Settings. The SDK bundles IBM Plex Sans Arabic under the OFL and registers it for
the app's process only.

The composer keeps local text per conversation while the retained client lives.
Photos and files are copied from security-scoped picker URLs to protected private
files before selection in the core. Attachments show as file rows with Preview
and Download (the share sheet); an image up to 5 MB shows its thumbnail once near
view. Image zoom, lightbox paging, audio/video playback and Quick Look remain
native.

Assignee avatar file IDs download through the same authenticated core command,
not through public Swift HTTP. Actual external HTTP(S) image URLs keep the native
public image loader. Private avatar leases are scoped by credential generation,
conversation target and image ID. Retiring an owner invalidates display leases;
files stay retained until the last lease releases them. Failed deletions retain
their paths for `retryLocalFileCleanup()`, including after the original client
is released. The unleased avatar cache retains at most 16 current entries.

Closing a view does not dispose the client, cancel a frozen send, or forget the
device. Credential generation changes clear sensitive composer, picker, media
and navigation state. The host owns the client's lifetime:

```swift
try await client.leave() // Retire this device's session; not the host app's login.
client.dispose()        // Disconnect only, preserving stored credentials.
```

End the support session before changing identified accounts. Local retirement
does not wait for the independent remote acknowledgement task.

## Inbox commands

The client forwards the core's `setInboxActive`, `setActiveConversation`,
`startConversation`, `loadConversations`, `loadOlderMessages`, `jumpToLatest`,
`revealMessage`, `markRead`, `selectFiles`, `removeFile`, `sendMessage`,
`retrySend`, `cancelSend`, `discardFailed` and `downloadAttachment` methods.

Conversation commands use an `InboxTarget` containing the conversation ID and
credential generation. `startConversation()` creates a local draft; the real
send transaction creates the server conversation, including attachment-first
messages. Selecting files never creates an empty conversation.

There is at most one frozen pending send, not a replay queue. Retry uses that
send's original ID, destination, body, files and quote, never the current
composer. Canceled and uncertain outcomes remain visible. Reconnection does
not resend them automatically. Retry availability comes from the core snapshot.
Edit message returns a failed send's text, quote and files to the composer:
the files' private copies stay leased while the send is discarded, then are
staged again. A send with an unknown outcome offers Check for sent messages,
which reads the thread again and never sends it again.

Native staging files stay retained while draft attachments, a pending send or
an in-progress native selection references them. An unknown identity does not
release files: cleanup waits for a confirmed read or generation retirement.
One process-wide private-file pool also tracks live preview and avatar leases.
A local preview acquires its source lease before starting its detached copy;
confirmation, discard and retirement cannot unlink that source while the copy
is running. Cancellation releases the lease after the copy worker stops.
Failed staging, preview and avatar deletions retain their paths in this pool,
independently of the client that created them. New clients observe unresolved
failures through `client.localFileError`; `retryLocalFileCleanup()` retries
unleased files without replaying any network or domain operation.
Callers of the low-level `selectFiles` API own any files they supply themselves.

## Optional UIKit facade

```swift
RasheedSupport.initialize(
    client: client,
    configuration: RasheedSupportConfiguration(language: .en)
)
RasheedSupport.present()
RasheedSupport.present(.messages, conversationId: conversationId)
RasheedSupport.hide()
```

The facade wraps the supplied client; it does not create another session. Its
`presentation` defaults to `.automatic`: full screen on iPhone and a sheet on
iPad, as the widget presents; `.sheet` and `.fullScreen` choose one everywhere.
With Reduce Motion it presents without sliding.
`RasheedSupport.current` exposes the native presentation model and its incoming
message callback. `handleDeepLink(_:)` accepts
`rasheedchat://conversation/<id>` and
`https://<platform>/<workspaceId>/widget?conversation=<id>`.
The HTTP form must match the configured platform origin and workspace ID.
It is a native interception hook: the host handles it before opening a browser.
The SDK does not serve this path as a web page or widget endpoint.
Both forms only request selection through the Rust core; URL parsing never
authorizes access to a conversation.

Notifications use the additive `initialNotificationTarget: RasheedNotificationTarget? = nil`
initializer argument on both `RasheedSupportWidget` and `RasheedSupportView`
(including the model-based view initializer). Pass the whole typed target,
not its ID via `initialConversationID`. The latter remains for ordinary native
navigation and URL interception. For an already-mounted presentation, call
`await model.openNotification(target)`; it returns whether the scoped request
was accepted. Scope is retained across latest-reply reads, core selection,
backend redirects and the final SwiftUI state change. There is one ephemeral
notification navigation, not a persisted domain queue.

## Storage

Device credentials keep the existing validated platform/database/workspace
Keychain scopes. Profile, branding and inbox display caches use protected
versioned storage. The inbox journal uses protected application support storage,
scoped by validated account and token hash, and contains one frozen send.
End-session cleanup includes the journal and reports local storage failures.
The seventh store key, `PushState`, is an opaque Rust-serialized blob of at most
24 KiB in the same hashed scope's protected Application Support directory.
It is not a display cache. Rust validates its account/device hash, allocates
sequences and owns frozen dispatches. Scope clearing includes it; write and
delete failures reach the observable core error/retry state.

## Push registration and instance hooks

```swift
try await client.registerPushToken(platform: .ios, token: fcmToken)
try await client.unregisterPush() // nil token; not a claim of remote completion
try await client.retryPushRegistration() // explicit retry of the frozen operation
```

`PushPlatform`, `PushStatus`, `PushScope` and `PushSnapshot` alias the generated
Core types. `setPushToken(_:) async throws -> Bool` remains an iOS convenience;
its Boolean reflects Core's registered status, not dispatch. `client.push`
publishes status, error and `canRetry`, never tokens. FCM token callbacks
pass exact bytes; same-value callbacks do not explicitly retry an uncertain
operation. Registration before joining stays pending and never implicitly joins.
Swift does not duplicate registration persistence, fencing, retries or receipts.
The facade and presentation model expose the same FCM conveniences.

Hosts own permission, APNs/FCM acquisition and delegates. Use these main-actor
instance hooks with the retained client, not a global facade for RN:

```swift
func currentPushScope(for userInfo: [AnyHashable: Any]) -> PushScope?
func isPushScopeCurrent(_ scope: PushScope) -> Bool
func isConversationVisible(scope: PushScope, conversationId: String?) -> Bool
func handlePushNotification(
    _ userInfo: [AnyHashable: Any],
    onAccepted: (@MainActor () -> Void)? = nil,
    onOpen: @escaping @MainActor (RasheedNotificationTarget) -> Void
) -> Bool
func notificationTarget(for userInfo: [AnyHashable: Any]) async -> RasheedNotificationTarget?
func handleForegroundNotification(
    _ notification: UNNotification, trustedImageHosts: Set<String> = []
) async -> UNNotificationPresentationOptions?
```

`RasheedNotificationTarget` carries `scope` and optional `conversationId`. The
tap hook invokes only its supplied callback. For a launch from a notification,
`notificationTarget(for:)` connects, waits while push registration is pending or
registering, then matches the notification to the current session; cancel its
task to stop waiting. An RN host must target its Fabric
lease and recheck `isPushScopeCurrent(target.scope)` immediately before opening,
and again after any host await. A conversation-less push reads the authorized
list for the latest reply, falling back to the list. Provider message-ID dedupe
is bounded to 256 entries and includes all scope fields and local generation.
`onAccepted` runs synchronously on the main actor for a fresh, current-scope
notification, before routing or a latest-reply lookup. Rotate a host presentation
authority there, not from the Boolean return value: a duplicate returns `true`
without calling `onAccepted` or routing again. Rejected payloads return `false`
without acceptance. The UIKit facade forwards the same optional callback.

Payloads require string `rasheed: "true"`, `workspaceId`, `contactId`,
`pushEpoch` and canonical decimal-u64 `pushSequence`. Parsing alone proves
nothing. App handlers compare the exact live Core scope and recheck it after
every await. Missing, stale or uncertain scope cannot route, enrich or present
a private foreground alert. Delegate wrappers must also recheck after their
await, and must not turn a rejected Rasheed alert into a default banner.
Visibility requires a foreground window, attached/unhidden native UI, the
matching displayed thread and generation, and a confirmed inbox. Home, a list,
offscreen embedded views and retained selection alone do not suppress alerts.

Provider acquisition has its own cancellable host consent lease: client
instance, consent nonce and live `currentCredentialGeneration`. Capture it
before permission/provider awaits and before queuing provider delegate work.
The example observes generation changes and the client's
`pushTokenAcquisitionInvalidated` notification. SDK leave/beginLeave, forget,
dispose and explicit disable invalidate acquisition immediately, including
commands from an embedded view. Late results and later provider callbacks
cannot restore cleared consent. Rust alone decides whether an already-stored
intent carries through explicit identification; the host never reaffirms it
from an old Boolean.

### Direct APNs

When your workspace is configured for direct APNs, enable the Push Notifications
capability for the host target and use its native device token. The SDK uses the
host app's bundle identifier as the APNs topic; it must match the workspace
configuration. The SDK reads `aps-environment` in the embedded provisioning
profile: `development` is sandbox and `production` is production. On iOS
devices, App Store and TestFlight installs without an embedded profile use
production. Debug and Release settings do not select an environment.

If signing can’t be determined, registering a token returns
`APNS_ENVIRONMENT_UNKNOWN`. This includes simulator builds without an override.
If you know the correct environment for that build, pass `environment: .sandbox`
or `environment: .production` explicitly. This does not enable push for an app
signed without the required entitlement.

Your app decides when to request notification permission; the SDK never prompts.
After checking host consent and notification permission, call
`UIApplication.shared.registerForRemoteNotifications()`. Forward the token from
your main-actor AppDelegate. The retained `client` and consent/error helpers in
this example belong to the host:

```swift
func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
) {
    guard let consent = currentPushConsent else { return }
    Task { @MainActor in
        guard isCurrentPushConsent(consent) else { return }
        do {
            try await client.registerAPNsDeviceToken(deviceToken)
        } catch {
            if isCurrentPushConsent(consent) { reportPushRegistrationFailure() }
        }
    }
}
```

On disable, clear the host consent lease and call
`try await client.registerAPNsDeviceToken(nil)`. Revoking a token doesn’t require
an environment.
Pass APNs `userInfo` to the same instance hooks for foreground notifications and
taps. Existing Firebase hosts keep using `.ios` with the FCM token. Do not
register both paths for the same customer session.

#### Send a test push

Allow notifications and register the device for direct APNs. In **Developers →
Notifications**, choose **Test push** and review the audience before confirming.
This can reach customer devices, including App Store and TestFlight builds.
Look for the alert to verify delivery; Apple’s acceptance alone does not confirm
it appeared. The alert has no inbox link. Your app controls foreground display.

## Rich OS alerts and the extension boundary

The selected policy is **Rich background alerts**. Backend current-recipient
checks happen before provider dispatch. Alerts already accepted or queued by
the provider cannot be recalled after logout or an account change.
Neither app-side checks nor the NSE can promise to prevent that OS fallback.

Subclass `RasheedNotificationServiceExtension`; configure its public
`workspaceID` and explicit `trustedImageHosts`. The credential-free NSE may
enrich an already-accepted OS alert after payload-shape/workspace checks. It
cannot establish a live current customer while the parent is absent. No App
Group authorization cache or parent credentials are used.

Images require an allowlisted HTTPS host, no URL userinfo or redirects, a
5-MiB streamed bound, an independent eight-second whole-pipeline deadline and supported image
MIME. Provider `fcm_options.image` goes through this same loader; do not add
Firebase's automatic image helper. Failed or disallowed images leave the
accepted title/body intact. Foreground enrichment uses the same policy with
live scope checks before and after awaits. Once a replacement local alert has
been accepted by iOS, it has the same OS non-recallability boundary.
The deadline runs independently of synchronous ImageIO inspection, file writes
and attachment construction. Timeout, cancellation and NSE expiry have one
terminal result. Unconsumed/late attachment leases remove their private files;
only images passed to the OS release that cleanup ownership.

The example app uses the existing trusted backend for app sign-in.
No Firebase configuration, credentials or services are bundled.
