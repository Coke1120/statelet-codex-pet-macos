---
name: craft-video-generation-prompts
description: Create, review, condense, or edit prompts for text-to-video and image-to-video generators, especially Statelet character animation. Use for Gemini, Veo, or other video-generation prompts when motion, character consistency, looping, camera, chroma background, or negative constraints must be expressed clearly without instruction overload. Do not use for media conversion, import, or runtime playback verification.
---

# Craft Video Generation Prompts

Produce a prompt that is easy for the target video model to follow, preserves the
user's creative intent, and makes technical limitations explicit.

## Establish the generation contract

Identify the target model and version, text-to-video versus image-to-video mode,
reference inputs, duration, aspect ratio, output purpose, audio preference, and
whether a separate negative-prompt field is available. Infer these from the
request and nearby project context when safe; ask only when a missing choice would
materially change the result.

Model capabilities drift. Before asserting current prompt limits, supported
durations or languages, reference-image behavior, first/last-frame controls, or
negative-prompt support, verify the target model's official documentation. Keep
model-specific limits out of reusable prompt prose unless the user needs them.

## Edit by priority

Separate the user's requirements into:

1. Hard invariants: subject identity, framing, duration, background, delivery
   format, and prohibited content.
2. Primary motion: the single scene or action the clip must perform.
3. Preferences: mood, movement pool, expressions, secondary motion, and variation.
4. Failure prevention: a short, deduplicated list of observable defects.

Resolve contradictions instead of preserving them silently. Explain any tradeoff
that changes the intended result. For short clips, keep one scene and a small
number of complete movement phrases; do not encode every possible action or a
frame-by-frame timeline unless the user explicitly needs fixed choreography.

## Write the positive prompt

Order information so the model encounters the most important constraints first:

- reference input and stable subject identity;
- shot, primary action, energy, and timing;
- motion continuity and physically plausible follow-through;
- loop closure or ending state;
- camera and composition;
- background and delivery constraints.

For image-to-video, treat the source image as the authority for appearance. Refer
to the subject generally and prompt mainly for motion, temporal behavior, and
camera behavior. State identity preservation once; do not repeatedly redescribe
features already visible in the reference.

Use concrete visual language and complete sentences. Prefer one requirement over
several synonyms. A useful default for a short clip is approximately 150–400
English words, but clarity and model limits take precedence over a word target.
Preserve another language when requested or supported; otherwise recommend a
supported prompt language without implying that unsupported input can never work.

When variation is desired, provide a small movement pool and tell the model to
choose a bounded subset in no fixed order. Do not combine random choreography
with an over-specified mandatory sequence.

## Handle negative constraints

Put negative constraints in the generator's dedicated negative-prompt field when
one exists. Otherwise add one compact `Avoid` or `Negative prompt` section after
the positive prompt. Group related failures and remove duplicates. Describe the
unwanted result rather than writing dozens of variations of `no`, `never`, or
`forbidden`.

Do not place desired actions in the negative prompt. Avoid negative phrasing that
directly conflicts with the positive action, such as prohibiting all orientation
changes while requesting a turn.

## Distinguish prompting from deterministic finishing

Treat exact pixel values, perfectly unchanged backgrounds, identical first and
last frames, exact choreography timing, and guaranteed anatomy as generation
targets rather than guarantees. Retain them when required, but tell the user when
first/last-frame conditioning, chroma validation, editing, or post-processing is
needed for deterministic delivery.

For Statelet delivery, this skill ends at prompt authoring. Use
`$author-statelet-animation` for source-media constraints, conversion, reports,
import, and runtime playback verification.

## Deliver and verify

Preserve the original prompt unless the user asks to overwrite it. When creating
a revision, use a descriptive neighboring filename and make it directly usable.
If the generator exposes a separate negative field, label the positive and
negative text clearly.

Review the finished prompt for:

- one unambiguous subject and scene;
- compatible action, camera, composition, and loop instructions;
- no repeated or conflicting constraints;
- a duration and action count the selected model can support;
- clear separation between generation goals and deterministic validation;
- substantially lower word and byte counts when the task is condensation.

Do not generate media, alter source artwork, import assets, or change runtime
configuration unless the user separately requests those actions.
