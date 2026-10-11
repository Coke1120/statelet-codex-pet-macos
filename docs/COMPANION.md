# Statelet Companion

Open **Companion…** in the menu-bar menu (Command-J while that menu is active),
click the pet's chat button, or launch Statelet with `--companion`.
The floating native panel puts quick chat, agent activity and character controls
next to the desktop pet. It supports macOS 13 and later.

## Global shortcut

Press **Control–Option–Command–J** to open Companion and focus its chat composer.
If it is already open behind another app, the shortcut brings it forward and
focuses the composer. Press again while Companion is focused to hide it;
**Escape** also closes it. Drafts, attachments and Mini mode remain in memory.
Closing Companion stops dictation and speech, while an in-flight text reply can
still finish for the next time you open it.

Change the combination in **Settings → General → Companion Shortcut**. Choose
a letter or Space and at least two of Control, Option and Command, then click
**Apply Shortcut**. **Reset Shortcut** restores the default; **Disable Shortcut**
removes its global registration. A detected collision with a system or another
registered shortcut keeps the previous combination and preference. The current
status indicates whether a shortcut is active or unavailable. The default avoids
the official app's Option–Space shortcut and common system Space combinations.

Companion uses current visible screen boundaries when opening or resizing and
after displays change. A pet spanning displays uses the display with the most
overlap; a removed display falls back to the nearest remaining one. The panel
shrinks to fit small displays. No global input monitor or clipboard capture is
used. Letter choices refer to US keyboard positions; other layouts can display
different letters. Apps using other keyboard interception mechanisms may have
conflicts that registration cannot detect. Real keyboard delivery, layout,
Spaces/fullscreen focus and multiple monitors still require installed testing.

## Compatibility health

Open **Settings → Diagnostics & Repair** and choose **Refresh**, then optionally
**Copy Diagnostics**. The report adds CLI installation/signature, parsed numeric
version, exact Quick Chat flag parsing and recognized disabled features. These
are offline checks without a model request. `0.159.2` is the validated baseline;
an older or unfamiliar version gets an update/refresh recommendation without
claiming an established earliest compatible release or weakening safety flags.

The report checks the effective Codex hooks feature and the installed Statelet
user hooks through the read-only `hooks/list` catalog. It distinguishes absent
or incomplete registration, missing runtime, disabled hooks, definitions needing
trust review, modified definitions and enabled/trusted readiness. Missing hooks
suggest rerunning the Statelet installer; trust-related states direct you to
Codex **`/hooks`** to review the exact definitions yourself. Inconclusive checks
stay unverified. Statelet never enables a feature, trusts a hook or bypasses hook
trust for you. A configured/trusted result does not verify live event delivery,
project overrides, sign-in or authenticated Quick Chat.

Only fixed categories, recommendations, a strictly parsed numeric version and
bounded counts leave the check. Prompts, credentials, commands, hook keys/hashes,
source paths, warnings and raw errors are discarded. Probes have bounded output
and an eight-second total deadline; refreshing again or quitting cancels them.
CLI syntax/features use a private scratch home. User-hook checks use the active
Codex home in a scratch working directory and disable apps/plugins and telemetry
only for that diagnostic invocation. No thread is started and no security/trust
configuration is written.

## Chat

- Send with **Command-Return**. Follow-ups include this conversation's previous
  messages; **New chat** clears the in-memory conversation and attachments.
- Attach up to two UTF-8 text files, each at most 16 KiB. The attachment chip
  makes the selected context visible and removable before sending.
- **Stop** cancels only Statelet's current reply. A failed or interrupted reply
  can be retried without duplicating the user message. Late results from a
  cancelled request cannot replace a newer conversation.
- **Dictate** requests microphone and speech-recognition permissions only when
  clicked. Recognition requires on-device support for the current language;
  no cloud-recognition fallback is used. Review the draft before sending.
- **Read replies aloud** uses the macOS system voice. Each reply also has a
  Read aloud action; Stop audio stops playback. Closing the panel stops audio
  and dictation, including automatic speech from a reply that finishes while
  the panel is closed. The text reply remains available when reopened.
  Pet dialogue still uses the existing local voice library.

Quick Chat uses the signed installed Codex CLI and its existing sign-in. Its
interface accepts text only. Shell execution, image reading/generation,
browser/computer use, web search, apps, plugins, multi-agent work, hooks,
shell snapshots and project instruction loading are disabled. User/project
execution rules are ignored, and a read-only sandbox remains mandatory.
A clean temporary working directory
avoids accidental project context. No separate API key is collected. Advanced
work stays in the user's Codex or Grok app.

The public CLI does not expose a zero-tool allowlist. A model can still receive
some built-in tools, including `apply_patch`; the read-only sandbox and disabled
approvals constrain them. The text-only prompt is guidance, not a tool security
boundary. Do not treat Quick Chat as proof that the upstream CLI advertises no
tools. Statelet discards tool output from its chat interface.

Statelet reuses only the root model setting and an optional credential-free
loopback `openai_base_url` from the local Codex config. It does not load the rest
of the config or forward arbitrary endpoint/environment overrides. Its bounded
parser accepts single-line quoted routing values with optional trailing comments.
Root assignment keys must use bare ASCII letters, digits, underscores or hyphens.
If the root section contains unsupported syntax such as multiline strings,
arrays, inline tables, quoted keys or dotted keys, it omits routing overrides
rather than mistake their contents for root settings;
the CLI then uses its default model/endpoint. Table contents are never copied.
The optional config read accepts only a regular UTF-8 file of at most 1 MiB.
Symlinks to regular config files remain supported. FIFOs and other special files,
including symlinks to them, are skipped without blocking.

Statelet sends the conversation and explicitly attached text through that Codex connection only
when Send or Retry is chosen. This is a new user-initiated cloud-backed feature;
lifecycle aggregation and local media/voice processing remain local. The CLI
runs with `--ephemeral` and no persisted conversation history. Statelet does not
write chat text, audio, attachments, tool output or errors to lifecycle files,
preferences, logs or diagnostics. Prompts use stdin instead of command arguments.
OpenAI account usage and service-side data handling still apply.

The service bounds prompts to 64 KiB, output to 2 MiB and runs to two minutes.
Only assistant messages and fixed status categories reach the panel. Raw
protocol errors, reasoning and tool output are discarded. Binary and running
process identity must pass the existing OpenAI signature policy. The process
and pipe readers are cancelled and reaped when the run ends.

Implementation references: [Codex non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode)
and the installed CLI's `codex exec --help`. Flags and feature names were checked
offline against Codex CLI **0.159.2**, with the corresponding
[official tool registration](https://github.com/openai/codex/blob/ff6aec96948b70d94983af2641a6b67c94faeff5/codex-rs/core/src/tools/spec_plan.rs)
and [extension-only tool allowlist](https://github.com/openai/codex/blob/ff6aec96948b70d94983af2641a6b67c94faeff5/codex-rs/ext/extension-api/src/tool_policy.rs).
Quick Chat requires the flags above; an older incompatible CLI reports a
recoverable error rather than relaxing them. This offline check does not verify
authentication, a live model response or the signed macOS executable.

## Activity

The Activity tab shows active, waiting and completed-unread sessions from the
existing privacy-safe lifecycle sidecar. Filter to **Needs you** or **Completed**,
open a verified Codex task, acknowledge one completion, or clear completed-unread
items. Titles remain ephemeral and follow the existing title-hydration policy.
Unavailable targets stay visible with a manual-open explanation.

Open tasks in the owning agent app to reply, approve a request or stop their
work. Statelet does not pretend a separate CLI process can control a running
desktop-owned turn. ChatGPT's internal realtime voice-session controls and its
private pet installation format are not third-party Statelet integrations.

## Pet and Mini

The Pet tab switches characters through the existing character library, creates
an empty named profile, imports verified `.statelet-character` bundles and opens
the animation editor. It adjusts pet size while preserving its aspect ratio,
shows/hides the desktop pet for the current app session, toggles automatic pet
dialogue and opens Voice settings. Existing character verification and media
storage are unchanged.

Mini collapses the companion to a compact chat bar without losing an unsent
draft. Hiding the desktop pet leaves the companion available; the menu-bar
entry can always reopen it. Chat, Activity and Pet remain separate destinations,
with keyboard focus, selectable replies, descriptive controls and native colors
that follow the system appearance. No second animation decoder is used.

## Verification

`CompanionTests` covers bounded text/context handling, event filtering,
conversation continuity, retry, late-result cancellation, compact sizing,
late speech suppression, FIFO attachment/config rejection, conservative routing parsing,
synthetic CLI streaming and process timeout/cancellation. Existing activity,
settings and pet interaction suites cover integration regressions. On-device
recognition requires manual verification on a Mac with permission and a
supported microphone/language; automated tests never request those permissions.
