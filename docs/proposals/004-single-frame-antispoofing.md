# 004 — Single-frame anti-spoofing: can a model fill the still-face hole?

Status: research survey. No code written, nothing measured on this machine.
Date: 2026-09-16.

Every claim below is tagged **VERIFIED** (I read the license file, the source, the
model card, or queried the GitHub/HF API in this session) or **UNVERIFIED** (I am
reporting what a paper or a README says, or reasoning from priors). Accuracy
figures quoted anywhere in this document are the authors' numbers on the authors'
test sets. None of them apply to this MacBook, this webcam, this room or this
printer until we measure them here.

---

## 0. Why we are looking at this at all

The existing liveness cues are all passive geometry. They read a rolling window and
measure parallax the user has to supply:

- `flatVs3D` (homography planarity) and `depthPose` (nose offset vs yaw) both gate
  on `minYawRangeDegrees`. Balanced uses `mediumMinYawRangeDegrees = 6`; Minimal and
  Strict use 12. Below the gate the cue returns `confidence == 0` — an abstention,
  not a weak reading. **VERIFIED** — `glance/Liveness/LivenessCues.swift:185-203`,
  `LivenessCues.readings(window:geometry:minYawRangeDegrees:)`.
- `blink` is the only confirm cue that does not need rotation, and it needs the user
  to blink inside the scan window.

So a user sitting dead still at zero yaw has exactly one path to confirmation: blink.
Balanced's summed-evidence trick recovers a lot of margin at small rotations, but it
cannot manufacture evidence out of an abstention. At 0 degrees of yaw the confirm
side of the ledger is empty in every mode.

A single-frame PAD model is the one thing that fills that hole: it reads one face
crop, needs no motion, no rotation, no blink, and returns a scalar.

**Where it would plug in.** `LivenessFeatureExtractor.extract(from:frame:faceCrop:timestamp:)`
already receives the *full* camera frame as a `CGImage` plus `face.boundingBox`, and
already produces a native-resolution face crop for the glare cue. That is precisely the
input a PAD model wants, and the docstring already explains why the full frame rather
than `result.alignedImage` is passed. **VERIFIED** — `glance/Liveness/LivenessFeatures.swift:12-23`.

---

## 1. Candidate comparison table

| Model | Arch | Params / file size | Input | License (checked) | Weights downloadable? | Last meaningful update |
|---|---|---|---|---|---|---|
| **MiniFASNetV2** (`2.7_80x80`, minivision Silent-Face) | depthwise-separable CNN | 0.435M params, 0.081 GFLOPs; `.pth` 1,849,453 B | 80×80 BGR, /255, NCHW; crop = bbox expanded 2.7× | **Apache-2.0** (LICENSE file read) | **Yes**, committed in-repo | repo pushed 2023-10-03 |
| MiniFASNetV1SE (`4_0_0_80x80`, the ensemble partner) | same family + SE | 0.414M params; `.pth` 1,856,130 B | 80×80, crop scale 4.0 | Apache-2.0 | Yes, in-repo | same |
| MiniFASNetV2 — ONNX port (`garciafido`) | — | `minifasnet_v2.onnx` 1,744,116 B, opset 11 | 80×80 BGR /255 | Apache-2.0 (declared, inherits upstream) | Yes | 2026-05-04, 0 downloads |
| MiniFASNetV2 — ONNX port (`QingHeYang`) | — | not measured | 80×80 | Apache-2.0 (GitHub API) | Yes | 2025-10-13, 15 stars |
| MiniFASNetV2 — TFLite (`litert-community`) | — | `silentface.tflite` 1,850,744 B | 80×80 NCHW BGR /255 | Apache-2.0 | Yes | 2026-09-08, 227 downloads |
| `nguyenkhoa/dinov2_Liveness_detection_v2.2.3` | DINOv2-small classifier head | 22.1M params, `model.safetensors` 88,257,824 B | not stated on card | **No license declared** | Yes | 2025-01-24, 43 downloads |
| `jdp8/dinov2_Liveness_detection_v2.2.3` (ONNX port of the above) | — | ONNX / transformers.js | — | **No license declared** | Yes | 2025-05-05, 143 downloads |
| `nguyenkhoa/vit_Liveness_detection_v1.0` | ViT-base-patch16-224 | ~86M | 224×224 | apache-2.0 declared | Yes | 2025-01-08, 60 downloads |
| `nguyenkhoa/mobilevitv2_Liveness_detection_v1.0` | MobileViTv2-1.0 | ~4.9M | 256×256 | **`license: other`** (Apple ML research terms on the base model) | Yes | 2025-01-08, 36 downloads |
| `biometric-ai-lab/Antispoofing` | undisclosed | `antispoofing_full.pth` 50.8 MB **+ bundled `yolov8s-face` 44.7 MB** | — | repo says apache-2.0 — but YOLOv8 weights are Ultralytics **AGPL-3.0** | Yes | 2025-12-25, 7 downloads |
| **DeepPixBiS** (Idiap, ICB 2019) | DenseNet161 trunk, 14×14 pixel-wise binary map + score | ~28M trunk | 3×224×224 | **GPL-3.0** (LICENSE read) | **No — the published tarball URL 404s** | repo last pushed 2020-09-03 |
| **CDCN / CDCN++** (ZitongYu) | central-difference conv, depth-map regression | ~2.3M (CDCN) | 256×256 | **NOASSERTION — no license** | training code yes; released weights unclear | last pushed 2023-03-27 |
| `vinaybr-0718/Temporal-Face-Liveness-Detection-INT8` | LSTM + multimodal, TFLite | — | video | not checked in detail | yes | 55 downloads |

**VERIFIED** for every row: sizes and dates came from the GitHub API
(`api.github.com/repos/...`) and the HF API (`huggingface.co/api/models/...`) in this
session; the minivision Apache-2.0 text was fetched raw from
`raw.githubusercontent.com/minivision-ai/Silent-Face-Anti-Spoofing/master/LICENSE`;
the DeepPixBiS GPL-3.0 text likewise; the DeepPixBiS tarball 404 came from a
`curl -I` on the URL the Idiap docs give.

**There is no face-PAD model published in CoreML form.** I searched HF for
`coreml` + face and for `coreml spoof`, and GitHub for `coreml face anti-spoofing`.
Nothing relevant. **VERIFIED as an absence**, with the caveat that an absence from
two search indexes is weaker evidence than a presence. ONNX ports exist, so the
conversion route is the one available, and `tools/convert_arcface.py` is already the
template for it.

### Things that look like candidates and are not

- **Silent-Face-Anti-Spoofing's own training data is not disclosed.** The README lists
  architecture, FLOPs and an APK accuracy claim but never names a dataset.
  **VERIFIED** (absence, README_EN.md). This matters twice: we cannot reason about
  what domain it covers, and we cannot rule out that it was trained on data with
  non-commercial terms — Apache-2.0 on the *code repo* is a statement about the code,
  and minivision chose to ship the weights inside that repo, which is the strongest
  signal available that they intend the weights to be covered, but it is a signal, not
  a warranty. **UNVERIFIED** that the weights are legally unencumbered.
- **The `nguyenkhoa` family is almost certainly CelebA-Spoof-derived.** The same
  account publishes `nguyenkhoa/celeba-spoof-for-face-antispoofing-test` and a
  494,405-image `nguyenkhoa/antispoofing` train set (~46 GB, labels `live`/`spoof`),
  and the model cards say "unknown dataset". CelebA-Spoof's own agreement is
  **non-commercial research and educational purposes only**, no redistribution.
  **VERIFIED** for the dataset terms (README of `ZhangYuanhan-AI/CelebA-Spoof`, which
  has no LICENSE file at all); **UNVERIFIED** that these specific checkpoints were
  trained on it. Combined with "no license declared" on the strongest of them
  (`dinov2_v2.2.3`, the one with 143 downloads on its ONNX port), this family is not
  shippable in a signed, distributed app. No declared license means no grant — the
  default is all rights reserved, not "probably fine".
- **DeepPixBiS is GPL-3.0 and the weights are gone.** GPL-3.0 alone would force the
  whole app open under most readings; the 404 settles it.
- **CDCN has no license at all.** Same problem as the HF models: absence of a license
  is not permission. Its architecture (central-difference convolution) is worth
  reading if we ever train our own, but the repo is not a shipping path.

---

## 2. Datasets — what is actually obtainable

| Dataset | Obtainable without an institutional agreement? | Terms |
|---|---|---|
| **CelebA-Spoof** (625,537 images, 10,177 subjects) | Effectively yes — multiple unofficial HF mirrors exist (`Ar4ikov/celebA_spoof` 5,694 downloads, `UniqueData/celeba-spoof-dataset`, `namkuner/...`) | **Non-commercial research only; redistribution prohibited.** The mirrors are themselves violations of that clause. **VERIFIED** — official README "Dataset Agreement". |
| **CASIA-SURF** | No | Requires a signed licensing agreement emailed to the maintainer; separate commercial licence contact. **VERIFIED** via the CVPR challenge page. |
| **OULU-NPU**, **SiW**, **Replay-Attack** | No | All are EULA-gated academic releases requiring a signed institutional agreement. **UNVERIFIED in detail** — I did not obtain the individual EULA texts this session; this is the consistent report across the survey literature. |
| Assorted HF "anti-spoofing" sets (`AxonData/face-anti-spoofing-dataset`, `UniDataPro/...`, `UniqueData/web-camera-face-liveness-detection`) | Yes, downloadable | **None declare a license.** Several are vendor sample sets advertising a paid full dataset. Fine for a private sanity check, not for training something we ship. |

**Practical conclusion.** There is no large PAD dataset this project can legitimately
train on for a distributed product. That is a hard constraint and it shapes the whole
recommendation: we are consumers of a pretrained model, not trainers of one, unless
we collect our own data. Which, for evaluation purposes, is exactly what we should do
(§8) — a hundred frames of the user's own face and his own printed photo is a
perfectly legitimate, perfectly private dataset, and it is the only one whose domain
actually matches the deployment.

---

## 3. The generalisation problem — the honest version

This is the part that decides whether any of this is worth doing, so it gets the most
care.

**What the literature reports.** The standard benchmark is leave-one-out across four
datasets — MSU-MFSD (M), CASIA-FASD (C), Replay-Attack (I), OULU-NPU (O) — training on
three and testing on the fourth. Numbers from CCPE (arXiv 2504.04470), Table I,
**VERIFIED** by fetching the paper:

| Method | OCI→M | OMI→C | OCM→I | ICM→O | Avg HTER |
|---|---|---|---|---|---|
| DiVT-M | 2.86% | 8.67% | 3.71% | 13.06% | 7.08% |
| ViT-C&FA&CS | 4.62% | 7.28% | 10.89% | 6.77% | 7.39% |
| S-Adapter | 2.90% | 7.37% | 8.54% | 8.20% | 6.75% |
| CCPE (2025, proposed) | 3.10% | 1.33% | 6.08% | 5.57% | 4.02% |

Read that table carefully, because it is much worse news than it looks.

1. These are **half total error rates of 4–13% on unseen domains**, from methods whose
   *entire research contribution* is cross-domain generalisation, published in 2024–25,
   using ViT and CLIP backbones two orders of magnitude larger than MiniFASNet.
2. Every one of those "unseen" domains is still an academic PAD dataset: a posed
   subject, a known printer, a known screen, a research capture rig. None of them is a
   MacBook FaceTime camera in a bedroom at night.
3. MiniFASNetV2 is **not** a domain-generalisation method. It is a 0.435M-parameter
   CNN from 2020 trained on undisclosed data. Nothing in the DG literature applies to
   it as an upper bound; it is a lower bound at best.

**So how much can a pretrained PAD model be trusted on an unseen MacBook webcam and
an unseen printer?** Plainly: **not as a sole authority, and not with a number
attached.** The realistic expectation is that it is *informative* — a printed photo
and a live face do look different to a texture model even out of domain, because the
print introduces halftone dot structure, paper texture, a narrower colour gamut and a
different noise floor that no amount of domain shift removes. But the *calibration*
will be wrong. The score distribution on this webcam will not match the score
distribution the threshold was tuned for, and it will move with lighting.

That is the argument for the architectural decision in §7: **deny cue, not confirm
cue.** A deny cue's job is to fire on strong evidence of a spoof. A miscalibrated
deny cue that is set conservatively fails safe — it misses some spoofs, which leaves
us exactly where we are now, but it never locks out the legitimate user.

**Could we fine-tune on this user's own hardware?** Mechanically yes and it is not
even hard: MiniFASNet is 0.435M parameters, and fine-tuning a last-layer or
few-layer adaptation on a few thousand crops is minutes of work on an Apple Silicon
GPU via MPS. The problem is not compute, it is **data diversity**. One person, one
face, one printer, one room gives a training set with a sample size of one in every
dimension that matters. A model fine-tuned on that will learn "this exact print on
this exact paper under this exact lamp" and will almost certainly do worse than the
stock model against a print made on a different printer — the classic case of
narrowing the domain rather than generalising it. **Recommendation: do not fine-tune.
Use the user's own data for threshold calibration and for evaluation, which is what
one person with one laptop can legitimately produce.** Calibrating a decision
threshold against a locally-measured score distribution is a sound use of a tiny
sample in a way that gradient descent on it is not.

### Exposure and white-balance sensitivity — the new constraint

A sibling investigation established that the built-in Mac camera exposes **no**
exposure controls: `isExposureModeSupported` is false for every mode, and ISO,
exposure duration and exposure bias are `API_UNAVAILABLE(macos)`. We cannot lock
exposure, cannot lock gain, cannot bias. **Reported to me as established by that
agent — I did not re-verify it here; treat as VERIFIED-by-sibling.**

This is a genuine problem for a texture-based PAD model and it deserves to be stated
rather than waved at:

- MiniFASNet takes a raw `/255` BGR crop with **no per-image normalisation** — no mean
  subtraction, no contrast normalisation, nothing. **VERIFIED** from the LiteRT card
  and the ONNX card, both of which describe preprocessing as divide-by-255 only. That
  means absolute brightness and colour cast go straight into the network as signal.
- Auto-exposure on a dark room will raise gain, which raises sensor noise. Sensor noise
  is *exactly* the kind of high-frequency texture these models key on. A noisy live
  frame can look print-like; a well-lit print can look clean.
- Auto white balance drift shifts the colour cast, and print-vs-skin colour gamut is
  one of the cues the model plausibly uses.

Two mitigations, both cheap:

1. **Gate the cue on image quality.** We already compute `cropPixelWidth` and discount
   the glare cue below 50 px. Do the same here: compute mean luma and a crude noise
   estimate on the crop, and **abstain** (`confidence = 0`) when the frame is too dark
   or too noisy for the model's opinion to be worth anything. This is exactly what the
   cue architecture's confidence channel is for, and it means the dark-room case
   degrades to "no new information" rather than "wrong information".
2. **Never let it be the only thing that decided.** Deny-cue-only placement (§7) plus
   a multi-frame firing threshold (`frames(for:)`, like the existing deny cues' 3) means
   a single exposure-transient frame cannot convict.

---

## 4. Monocular depth — Depth Pro, Depth Anything V2, MiDaS

**Verdict: a trap in the obvious form, with one narrow defensible variant that I still
would not build first.**

The reasoning, and where it is verified versus inferred:

**The obvious form is "run a depth estimator on the frame, check the face has
relief".** This fails on a first-principles argument that the PAD literature itself
demonstrates by what it does *not* do. Monocular depth estimators are trained to
recover the geometry of *the scene the image depicts*. A photograph of a face depicts
a face. A model that output "flat plane" for every photograph of a 3D scene would be
useless at its actual job, because every input it has ever seen is a photograph of a
3D scene. The model has no way to distinguish "photograph of a face" from "photograph
of a photograph of a face" — that distinction is the PAD problem, not the depth
problem, and asking a depth model to solve it is asking it to fail at its own task.
**UNVERIFIED as a measured result** — I found no published evaluation of Depth Pro or
Depth Anything V2 used directly as a PAD gate. That absence is itself weak evidence:
it is an obvious thing to try, and nobody reports it working.

**What the PAD literature actually does with depth is different and is easy to
confuse with the above.** CDCN, DSGTD and that whole family use *pseudo-depth as
auxiliary supervision*: during training, live faces get a depth map generated by 3D
face alignment, and spoof faces get a depth map that is **set to all zeros by
definition**. **VERIFIED** — this is described consistently across the survey
literature I read (e.g. arXiv 2003.08061, arXiv 2010.04145). The network is being
taught the discriminative rule directly through the depth channel; it is not measuring
depth and then reasoning about it. Such a network's "depth head" is a PAD classifier
wearing a depth costume. Using an off-the-shelf general depth model in its place
removes the one thing that made it work.

**The one genuinely defensible variant** — and credit where due, it is the right
instinct — is to stop asking about the face and ask about **the scene around it**. A
real head sits in a room: there is a depth gradient from face to shoulders to wall,
and the face is a local minimum in a continuous field. A print held at arm's length is
a rigid plane at one distance with a depth discontinuity at its border, and everything
depicted *inside* that border is geometrically inconsistent with everything outside it.
So the signal is not "is the face flat" but **"is the face's estimated depth continuous
with its surroundings, or is there a step edge tracing a rectangle around it"**. That
is a real, physically-grounded signal.

Three reasons not to build it first:

1. It is **the `deviceDetected` cue again**, arrived at from a different direction — it
   fires on the presence of a discernible border around the presentation. The existing
   cue already detects device-shaped rectangles. The user's successful attack was a
   print with its **edges out of frame**, which defeats border-finding whether you find
   the border in RGB or in a depth map.
2. Cost. Depth Pro is ~950M parameters, multi-hundred-MB. Depth Anything V2-Small is
   the only cheap option, and it is the weakest.
3. Licensing kills the good ones anyway. **VERIFIED via HF API:** `apple/DepthPro` is
   `apple-amlr` (Apple's own ML research licence, not an open licence);
   `depth-anything/Depth-Anything-V2-Large` and `-Base` are **CC-BY-NC-4.0** —
   non-commercial. Only `Depth-Anything-V2-Small` is `apache-2.0` (19,371 downloads).
   The GitHub repo `DepthAnything/Depth-Anything-V2` is Apache-2.0 (code), which is a
   separate thing from the Base/Large weights.

There is also a documented failure mode pointing the same way: Depth Pro and
Depth Anything both flatten highly abstract artwork into planes, which tells you these
models are reading *semantic and pictorial* cues, not measuring geometry. A
photorealistic print is the case where those cues are maximally misleading.
**UNVERIFIED** — reported in a comparison paper surfaced in search (arXiv 2606.12368),
not independently confirmed.

**Reject.** Revisit only if the ring-light work in 001 makes an active-illumination
depth cue viable, which is a different mechanism entirely.

---

## 5. rPPG

**Verdict: correct in principle, unusable here.**

The physics is sound and a print genuinely has no pulse. The engineering does not fit:

- **Window length.** The literature is consistent that rPPG needs a long observation.
  A dedicated "fast" rPPG anti-spoofing paper (Liu et al., WACV 2020, "Temporal
  Similarity Analysis of Remote Photoplethysmography for Fast 3D Mask Face
  Presentation Attack Detection") exists *specifically because* prior rPPG PAD work
  used **10–12 second** input videos, which the authors themselves describe as
  impractical. At 1–3 seconds the heartbeat peak is not distinguishable from the noise
  floor in the spectrum. **VERIFIED as a reported finding**, from the WACV paper and
  the low-illumination reliability literature.
  An unlock should feel instant. Even the "fast" variants are an order of magnitude
  slower than the budget.
- **Low light is the worst case, and it is our target case.** rPPG recovers a signal on
  the order of a fraction of one percent of pixel intensity. In a dark room, sensor
  noise swamps it, and with no exposure control we cannot even hold gain steady while
  measuring — auto-exposure hunting injects a global intensity oscillation directly
  into the band the algorithm is looking at. This app's headline dark-room use case
  is the single worst environment for rPPG.
- **Open source exists** (`shicaiwei123/anti-spoofing-of-rppg`, plus the broader
  pyVHR/rPPG-Toolbox ecosystem), so availability is not the blocker.
- **It also solves the wrong problem.** rPPG's canonical application is **3D mask**
  detection, where texture models struggle. The user's threat model is a colour print,
  which texture models handle far better and far faster.

**Reject for the unlock path.** The only place it would make sense is a deliberately
slow, opt-in "high assurance" mode, and that is not a thing this app has or needs.

---

## 6. On-device feasibility of the recommendation

**Conversion.** MiniFASNetV2 → CoreML is a low-risk conversion and the repo already has
the pattern. `tools/convert_arcface.py` does ONNX → torch → CoreML for the embedder;
this is the same shape with a smaller model. `coremltools` is at 9.0 (**VERIFIED**,
PyPI API). Two routes:

- Convert the `.pth` directly: load `MiniFASNetV2` from `src/model_lib/MiniFASNet.py`,
  `torch.jit.trace` at 1×3×80×80, `ct.convert(..., minimum_deployment_target=ct.target.macOS15)`.
- Or convert `garciafido/minifasnet-v2-anti-spoofing-onnx` (opset 11). Note that
  `coremltools` has deprecated the direct ONNX front end; the reliable path today is
  ONNX → PyTorch → trace → CoreML, or just skipping ONNX and using the `.pth`. **Prefer
  the `.pth`** — it is the authoritative artifact, it is 1.85 MB, it is in the Apache-2.0
  repo, and it avoids inheriting a third party's conversion bugs (see the class-order
  warning below).

**Operators.** MiniFASNet is `Conv2d` / depthwise `Conv2d` / `BatchNorm2d` / `PReLU` /
`Linear` / `AdaptiveAvgPool`-style reductions. Every one of those has a native CoreML
mapping. The only thing I would actually watch is **`PReLU` with per-channel weights**,
which converts but is the operator most likely to produce a shape complaint, and any
`AdaptiveAvgPool2d` with a non-1 output size, which traces cleanly at a fixed input
resolution and badly at a dynamic one — irrelevant here because the input is a fixed
80×80. **UNVERIFIED** — I read the architecture description, not every line of
`MiniFASNet.py`, and I did not run the conversion.

**Cost.** 0.081 GFLOPs at 80×80 (**VERIFIED**, README_EN). For scale, the ArcFace
embedder this app already runs every frame is vastly larger. The LiteRT card reports
~5 ms on mobile-class hardware (**VERIFIED as a card claim**); on an Apple Silicon ANE
this is sub-millisecond territory, and the honest statement is that **inference cost is
not the constraint — it disappears into the noise next to the CoreML request overhead
and the existing Vision pipeline.**

**Run it every frame or sample it?** Every frame, for a reason that is about decision
quality rather than cost: the existing deny cues use a multi-frame firing threshold
(`glossFrames = 3`, `deviceFrames = 3`) precisely so a single bad frame cannot convict.
We want the same protection here, and we want it over a short wall-clock window, so we
want every frame.

**Preprocessing fidelity is where this will actually break.** The model is extremely
specific and there is nothing forgiving about it:

- Crop = the face bounding box expanded by **2.7×** about its centre, then resized to
  80×80. That is what the filename `2.7_80x80_MiniFASNetV2.pth` encodes; the scale is
  parsed out of the filename at runtime by `parse_model_name`. **VERIFIED** — read
  `test.py` and the crop parameterisation.
- **BGR**, not RGB. Divide by 255. No mean/std normalisation.
- Upstream `test.py` calls `check_image()` and **refuses any image whose width/height
  is not exactly 3/4**, with the comment that this matches the Android capture stream.
  **VERIFIED** — read the source. That is a strong hint the model is sensitive to the
  aspect ratio of the pre-crop frame, and the Mac camera is 16:9. Worth testing both
  ways; the crop is taken from the full frame so the frame aspect does affect what
  2.7× of the bounding box contains.
- Upstream **ensembles two models** (`2.7_80x80_MiniFASNetV2` + `4_0_0_80x80_MiniFASNetV1SE`),
  sums the raw predictions and divides the score by 2. **VERIFIED** — `test.py`. Both are
  ~1.85 MB. Shipping both costs 3.7 MB and reproduces the configuration the accuracy
  claim was made about. Ship both.
- **Class order: `argmax == 1` means REAL.** Classes 0 and 2 are the two spoof types.
  **VERIFIED** by reading upstream `test.py` directly. ⚠️ The `garciafido` ONNX model
  card states the output is `[live, print, replay]` and computes liveness as
  `1 - (p[print] + p[replay])`, which is **inconsistent with upstream's index-1-is-live
  convention**. One of the two is wrong. This is exactly the kind of silent error that
  produces a model that "works" at 33% and is the first thing to verify empirically with
  a known-live and a known-spoof image.

---

## 7. Recommendation

**Try `2.7_80x80_MiniFASNetV2` from `minivision-ai/Silent-Face-Anti-Spoofing` first,
ensembled with `4_0_0_80x80_MiniFASNetV1SE`, converted to CoreML, wired in as a
`deny` cue.**

License: **Apache-2.0**, LICENSE file read directly from the repo. Permissive,
commercial use allowed, requires attribution and a copy of the licence — the same
obligation shape the fork already carries for MIT upstream, so it costs one more
paragraph in the acknowledgements. The unresolved residue is that minivision never
disclosed the training data (§1), so the weights carry the same species of uncertainty
the ArcFace weights already do. That is not a new category of risk for this project;
it is the existing one, and it only becomes sharp if the app is sold.

Why this one over everything else:

- It is the **only** serious candidate with a real permissive licence AND downloadable
  weights AND a working format-conversion path. Every other option fails at least one:
  DeepPixBiS is GPL with dead weights, CDCN has no licence, the DINOv2/ViT liveness
  models have no licence or a CelebA-Spoof provenance problem, the `biometric-ai-lab`
  bundle smuggles AGPL YOLOv8 weights into an "apache-2.0" repo.
- **1.85 MB × 2.** This is a face-unlock utility, not a research demo. A 3.7 MB addition
  is nothing; an 88 MB DINOv2 is a meaningful fraction of the app.
- It needs **one frame and zero motion**, which is the entire point of the exercise.
- Its cost is negligible enough to run every frame, which lets us use the multi-frame
  latching the cue architecture already implements.

### It should be a deny cue. Not a confirm cue. Not both.

This is the load-bearing design claim in this document, so here is the argument in full.

**Why deny.** The cue architecture already encodes the right asymmetry:
`currentDecision()` evaluates deny cues first and unconditionally, before any mode
logic, and a fired deny cue overrides confirmation that has already been reached
(`LivenessCues.swift:364-372`, **VERIFIED**). A deny cue that is miscalibrated
conservatively is *safe*: it stays quiet and we are no worse off than today. A confirm
cue that is miscalibrated in the permissive direction **unlocks the Mac** — and worse,
in Balanced mode it would contribute to `confirmEvidenceTotal` and could push a spoof
over `mediumConfirmScore` on its own, without any geometric cue agreeing. Given §3's
conclusion that we cannot trust this model's calibration on an unseen webcam, letting
it *grant* access is precisely the thing not to do.

**Why not also confirm.** The seductive argument is: a still user has no confirm
evidence, so let a confident "real" reading from the model count. Resist it. The
failure mode is that the PAD score is high for *every* well-lit frontal face, live or
photographed, once the domain shifts far enough from the model's training distribution
— and a high-quality print in good light is exactly the shift most likely to do that.
If it is a confirm cue, that failure silently re-opens the hole it was hired to close,
and it closes it in a way that *looks* like it is working, because the still-user case
now passes. A deny cue that misses is visibly a non-event; a confirm cue that
false-positives is an invisible bypass.

**Honest cost of that choice.** A deny cue does **not** fix the still-user stall. A
user sitting perfectly still still cannot be *confirmed* — the model can only fail to
object. So this proposal makes the app **harder to spoof**, not **easier to use**. The
usability half of the still-face problem belongs to 001 (active illumination), which
can produce a genuine confirm signal because *we* supply the change rather than waiting
for the user to. These two proposals are complements, and it is worth being explicit
that this one alone does not close the gap the brief described — it closes the
security half of it.

**Concrete shape.**

```swift
case .modelPAD   // added to LivenessCue
// role: .deny
// level:      1 - p(live)  — from the summed two-model ensemble, softmaxed
// confidence: 0 when the crop is below a pixel-width floor, below a mean-luma
//             floor, or above a noise ceiling; ramped otherwise, mirroring
//             glossGlare's cropPixelWidth ramp (LivenessCues.swift:425-434)
// tuning:     padLevel  (start high/conservative — calibrate per §8)
//             padFrames = 3, matching the other deny cues
```

`neutralLevel(for:)` returns 0 for it, like the other deny cues, and it contributes
nothing to `confirmEvidenceTotal` because that sum filters on `role == .confirm`
(`LivenessCues.swift:391-395`) — so adding it requires no change to Balanced's scoring
maths at all. That is a genuinely clean fit; the architecture was built for this.

---

## 8. How to evaluate it on this user's hardware

The whole point is that nobody's published number tells us whether this stops *his*
print on *his* MacBook. Here is the procedure that does.

**Step 0 — sanity-check the conversion before believing anything.**
Take the two sample images shipped in `images/sample/` in the minivision repo (one
known real, one known fake) and run them through the converted CoreML model. If the
Swift path does not reproduce the Python path's class probabilities to ~1e-3, stop:
you have a preprocessing bug (BGR vs RGB, crop scale, or the class-order discrepancy
flagged in §6). Fixing it later, after you have collected data, wastes the data.

**Step 1 — build the two stimuli.**
- *Live:* the user, sitting at the Mac, as he normally would.
- *Attack:* **the same printed photo that already defeated Minimal mode**, on the same
  paper, from the same printer. This is the only attack in this document that has been
  physically confirmed to work against this app on this hardware, which makes it the
  only one whose result means anything.

**Step 2 — collect across the conditions that actually vary.**
For each of {live, print}, collect ~50 frames in each of these, via Face Lab
(Settings → About → click the app icon 5×):

| Condition | Why |
|---|---|
| Normal room light, facing camera | the baseline |
| Bright — window or lamp behind the Mac | tests the bright end of AE |
| Dim — overheads off, screen dim | **the important one**: max sensor gain, max noise, and the case we cannot control exposure for |
| Dark room, screen the only light | the Night Boost / ring-light target case |
| Glasses on | the biggest appearance change the user routinely makes |
| Print held at 3 distances / slight tilts | prints held flat and square are the easy case; a casually-held print is the real one |

Log, per frame: `p(live)`, all three class probabilities, mean luma of the crop,
`cropPixelWidth`, and the existing cues' readings. Dump to CSV. This is the same
instrumentation Face Lab already does for the other cues, and the existing
`tools/liveness_selftest.swift` is the precedent for driving the decision logic
offline from recorded frames.

**Step 3 — look at the two distributions before choosing any threshold.**
Plot `p(live)` for live frames and for print frames. The question is not "what is the
accuracy" — it is **"is there daylight between the two histograms, and how much does
each one move between the bright and the dark condition?"**

Three possible outcomes and what each means:

- **Clean separation that holds across lighting** → set `padLevel` conservatively
  (well inside the gap, biased toward the live side so live frames never trip it) and
  ship it. Record the measured separation in the commit message. This is the good case
  and it is plausible: print-vs-skin is the single easiest PAD discrimination there is.
- **Separation in good light, collapse in the dark** → the most likely outcome given
  §3's exposure analysis. Ship it with the luma/noise gate set at whatever illumination
  level the separation survives to, and let it **abstain** below that. A cue that helps
  in daylight and honestly says nothing at night is a real improvement and an honest one.
- **No separation anywhere, or the print scores higher than the face** → do not ship it.
  Write down the measurement, note that the class-order question in §6 was checked in
  Step 0, and reallocate the effort to 001. A negative result measured on real hardware
  is worth more than an unmeasured feature, and this project's standing rule is that
  unmeasured means unmeasured.

**Step 4 — re-test the physical attack end to end.**
Whatever the histograms say, the acceptance test is the same one the user already ran:
hold the print up, in Balanced mode, and see whether the Mac unlocks. Then hold up his
actual face in a dim room and confirm it still does.

---

## 9. Adversarial honesty — how you beat this model

Concretely, assuming MiniFASNetV2 ships as a deny cue.

**What it plausibly stops.** A consumer colour print on plain office paper — the exact
attack the user reproduced. Inkjet and laser prints on uncoated stock carry halftone
dot structure, visible paper fibre, a compressed colour gamut (no skin subsurface
scattering, no specular micro-highlights on the nose and cheekbones) and a flat noise
profile. These are the features every texture-based PAD model is built on, and this is
the attack class such models handle best. **UNVERIFIED that it stops this specific
print on this specific webcam** — that is what §8 exists to find out, and I decline to
predict it.

**What beats it.**

1. **A better print.** Photo-quality paper, high DPI, correct colour profile, printed
   large enough that the halftone screen is below the camera's resolving power at
   normal sitting distance. This is the direct counter to a texture model and it is
   available at any print shop. Cost: a few dollars.
2. **Distance and resolution.** Every cue in this app degrades as the face shrinks in
   frame, and this one worst of all — it sees an 80×80 crop. Hold the print further
   back, or use a physically larger print further back, and the paper texture the model
   depends on falls below the sensor's resolution. The `minimumProminentFaceWidth = 0.18`
   floor bounds how far this can go, but 18% of frame width is still a small crop.
3. **A high-resolution screen.** A Retina display at typical distance has no visible
   pixel grid. This is partly covered by the existing `glossGlare` and `deviceDetected`
   deny cues — which is the strongest argument for keeping the model as an *additional*
   deny cue rather than a replacement for them, since the two cue types fail on
   different attacks. Note the direct tension with 001: a screen-lit face is exactly
   what `glossGlare` is built to reject, and anything that softens `glossGlare` to
   permit a ring light softens it for replay attacks too.
4. **Print behind glass, or a laminated / glossy print.** Adds a specular layer that
   makes it look more like skin's shine to a texture model — though it should push the
   glare cue the *other* way, toward denial. This one attacks the model and helps the
   existing cues, which is the ensemble working as intended.
5. **Anything 3D.** A paper mask, a curved print, a latex or silicone mask. Texture PAD
   on a good 3D mask is weak — that is the documented gap rPPG was invented for (§5).
   Out of scope for this threat model but worth naming so nobody claims coverage.
6. **Adversarial perturbation.** A print carrying a computed perturbation targeting
   MiniFASNet specifically. The model is small, public, and its exact weights are in a
   public repo, so a white-box attack is entirely feasible for a motivated attacker.
   Irrelevant to the user's stated threat model; relevant if the app is ever popular.

**What it does not stop, stated plainly:** anything that is not a cheap print. And it
does not, by itself, let a motionless user unlock — it only stops a motionless spoof.

---

## 10. What remains unknown

1. **Whether MiniFASNetV2 separates this user's print from this user's face on this
   webcam.** Unmeasured. Everything in this proposal is contingent on §8 Step 3.
2. **What minivision trained on.** Undisclosed. Bears on both generalisation and, if
   the app is ever sold, licensing.
3. **The class-order contradiction.** Upstream `test.py` says index 1 = live; the
   `garciafido` ONNX card says `[live, print, replay]`. One is wrong. Resolvable in
   ten minutes with the two sample images (§8 Step 0).
4. **Whether the 3:4 aspect-ratio assertion in upstream `test.py` reflects a real
   sensitivity** or is just defensive coding for the Android demo. The Mac camera is
   16:9. Testable.
5. **Whether the two-model ensemble is worth 1.85 MB over the single model** on this
   hardware. Measure both in §8; ship one if the second adds nothing.
6. **How far the score moves under auto-exposure hunting** — not just between static
   lighting conditions but *during* the AE settle after the lock screen appears or a
   ring light ramps. The per-frame score trace from §8 will show this directly, and it
   is the number that sets `padFrames`.
7. **What the interaction with 001 is.** If a ring light ships, every frame's
   illumination becomes something we partly control, which changes this model's input
   distribution in a way none of the §8 measurements would cover. Re-measure after 001,
   not before.
8. Whether any of the EULA-gated datasets (OULU-NPU, SiW, Replay-Attack) are in fact
   obtainable by an individual without an institutional affiliation. I did not obtain
   the individual EULA texts and am reporting the consensus of the survey literature.

---

## Sources

Verified by direct API query or raw file fetch in this session:

- https://github.com/minivision-ai/Silent-Face-Anti-Spoofing — Apache-2.0 LICENSE, weights, `test.py`
- https://github.com/minivision-ai/Silent-Face-Anti-Spoofing/blob/master/README_EN.md — params, FLOPs, accuracy claim
- https://huggingface.co/litert-community/Silent-Face-Anti-Spoofing-LiteRT
- https://huggingface.co/garciafido/minifasnet-v2-anti-spoofing-onnx
- https://github.com/QingHeYang/Silent-Face-Anti-Spoofing-onnx
- https://huggingface.co/nguyenkhoa/dinov2_Liveness_detection_v2.2.3 · https://huggingface.co/jdp8/dinov2_Liveness_detection_v2.2.3
- https://huggingface.co/nguyenkhoa/vit_Liveness_detection_v1.0 · https://huggingface.co/nguyenkhoa/mobilevitv2_Liveness_detection_v1.0
- https://huggingface.co/biometric-ai-lab/Antispoofing
- https://github.com/anjith2006/bob.paper.deep_pix_bis_pad.icb2019 — GPL-3.0; https://www.idiap.ch/software/bob/data/bob/bob.paper.deep_pix_bis_pad.icb2019/master/ — tarball 404
- https://github.com/ZitongYu/CDCN — NOASSERTION
- https://github.com/ZhangYuanhan-AI/CelebA-Spoof — non-commercial dataset agreement
- https://huggingface.co/depth-anything/Depth-Anything-V2-Small (apache-2.0) · `-Base`/`-Large` (cc-by-nc-4.0) · https://huggingface.co/apple/DepthPro (apple-amlr)

Reported, not independently verified:

- https://arxiv.org/html/2504.04470v1 — CCPE, cross-dataset HTER table
- https://openaccess.thecvf.com/content_WACV_2020/papers/Liu_Temporal_Similarity_Analysis_of_Remote_Photoplethysmography_for_Fast_3D_Mask_WACV_2020_paper.pdf — rPPG window length
- https://arxiv.org/pdf/2010.04145 — RGB consumer-camera anti-spoofing survey
- https://arxiv.org/pdf/2003.08061 — pseudo-depth supervision (spoof depth set to zero)
- https://arxiv.org/pdf/2003.04092 — CDCN
- https://sites.google.com/view/face-anti-spoofing-challenge/dataset-download/casia-surf-cefacvpr2020 — CASIA-SURF licensing agreement
- https://github.com/shicaiwei123/anti-spoofing-of-rppg — open-source rPPG PAD
