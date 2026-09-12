# Statelet Companion

Open **Companion…** in the menu-bar menu (Command-J while that menu is active),
click the pet's chat button, or launch Statelet with `--companion`.
The floating native panel puts quick chat, agent activity and character controls
next to the desktop pet. It supports macOS 13 and later.

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
  and dictation. Pet dialogue still uses the existing local voice library.

Quick Chat uses the signed installed Codex CLI and its existing sign-in. It is
text-only: tools, hooks, plugins, shell snapshots and project instruction loading
are disabled, with a read-only sandbox. A clean temporary working directory
avoids accidental project context. No separate API key is collected. Advanced
work stays in the user's Codex or Grok app.

Statelet reuses only the root model setting and an optional credential-free
loopback `openai_base_url` from the local Codex config. It does not load the rest
of the config or forward arbitrary endpoint/environment overrides.

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
and the installed CLI's `codex exec --help`. Quick Chat requires the flags above;
an older incompatible CLI reports a recoverable error rather than relaxing them.

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
synthetic CLI streaming and process timeout/cancellation. Existing activity,
settings and pet interaction suites cover integration regressions. On-device
recognition requires manual verification on a Mac with permission and a
supported microphone/language; automated tests never request those permissions.
