# BIM8F4K2Q6 — Bokki Plan feature artwork

Completed on 2026-10-08 (Asia/Seoul).

Two finished English portrait feature images are ready for website/design review. These are **illustrative feature artwork drafts, not app screenshots**. Both images visibly state “Illustrative feature artwork” and “Fictional day · Not app UI”. Real, privacy-safe device UI must be added or used to replace the illustration before treating either image as an App Store screenshot.

## Deliverables

| Image | Master | Web copies | Editable layout |
| --- | --- | --- | --- |
| Everyday movement and replay | output/bokki-plan-01-movement-1206x2622.png | output/bokki-plan-01-movement-603x1311.jpg and .webp | source/bokki-plan-01-movement.svg |
| Apple Health context and notes | output/bokki-plan-02-context-notes-1206x2622.png | output/bokki-plan-02-context-notes-603x1311.jpg and .webp | source/bokki-plan-02-context-notes.svg |

All masters are 1206×2622 PNG, opaque, 3-channel sRGB. Web copies are 603×1311, opaque sRGB. output/preview-pair.jpg presents the pair side by side at 1266×1351. Exact dimensions, byte sizes and SHA-256 hashes are in export-manifest.json.

The SVGs are self-contained: live editable text and separate embedded original raster illustration/icon layers. The copy is also separately editable in source/copy.json. The artwork layers are raster illustrations, not vector art. Arial is the layout font; fonts are not bundled. Use Arial when editing to preserve line lengths.

## Exact English copy

### 01 — Movement

Bokki Plan\
BY BOKKIYAW

EVERYDAY MOVEMENT

See where\
your day went.

Follow everyday routes.\
Replay the moments between.

Walks. Stops. The way home.\
A day you can look back on.

### 02 — Health context and notes

Bokki Plan\
BY BOKKIYAW

HEALTH CONTEXT & NOTES

More than\
a route.

Apple Health context.\
Notes tied to time and place.

Steps. Workouts. Sleep.\
Keep a note of what mattered.

### Shared footer

PLANNED RELEASE IN 2026\
IPHONE

Illustrative feature artwork\
Fictional day · Not app UI

## Feature evidence and build

The copy is based on current TaptionPlan code corresponding to the internally distributed 1.0(174) working tree. It is not a claim of public App Store availability. The approved public-facing product name is Bokki Plan.

- Daily location/motion records: TaptionPlan/Core/AppleIntegrations.swift. Collection depends on permissions and execution allowed by iOS; no always-on guarantee is made.
- Day navigation and route playback: TaptionPlan/UI/MapHomeView.swift, playback controls around lines 4410–4460.
- Place and time-linked notes: MapHomeView.swift, addMapMemo around line 2849 and the “Add memo to map” control around line 6276.
- Read-only Apple Health context, including steps/workouts/sleep: Packages/TaptionPlanCore/Sources/TaptionPlanCore/HealthReadScope.swift and AppleIntegrations.swift around line 637. Availability depends on authorization and data in Apple Health. No medical/diagnostic claim is made.
- The current root is MapHomeView; legacy planning UI is disabled in TaptionPlan/UI/AppShellView.swift. No inactive planning features are advertised.

All 146 release input hashes match artifacts/validation/REL1007B01.json and the pre-work snapshot. The exact icon copy matches the official app icon SHA-256. See source-verification.json. This asset-only task did not change app code, build numbers, signing or distribution, and did not run app builds/tests. Existing device-function and backup-regression limitations remain separate.

## Asset provenance and privacy

- Official icon: exact copy of TaptionPlan/Assets.xcassets/AppIcon.appiconset/AppIcon.png. It is placed as its own layer, without regenerating its artwork.
- route-hero.png: original AI-generated illustration, made from a generic fictional neighborhood prompt. No actual routes, coordinates, place names, people or private data were supplied.
- context-hero.png: original AI-generated still life, then refined to use plain unbranded shoes. The book is blank and there are no health values or personal notes.
- Initial context-hero-v1.png is retained only as an unselected iteration; it is not used by the final layouts.
- Public visual reference: https://bokkiyaw.com/ viewed on 2026-10-08 KST, for white/deep-green/mint design direction only. source/bokkiyaw-reference.png is a reference capture, not a reusable product asset. No Encoder screenshots, site artwork or old product names were incorporated.
- source/generation-prompts.json and source/refinement-prompt.txt preserve the illustration prompts.
- No real app/device screenshots, location/health records, accounts, tester contacts, credentials, or App Store Connect management screens appear in the deliverables.
- This task did not publish, upload, commit, push, or send files to another chat.

## Regeneration

Edit source/copy.json and/or render.mjs, then run `node render.mjs` in an environment with Node.js and Sharp available. The script writes both SVG layouts and all raster exports, and checks dimensions, color channels and transparency.
The local run used the bundled Node.js/Sharp runtime without adding dependencies. Editing the SVG directly is also supported; re-export a flattened sRGB PNG at exactly 1206×2622.
