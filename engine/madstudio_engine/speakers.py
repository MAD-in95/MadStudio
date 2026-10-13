"""Who speaks when: splits the transcript between speakers.

Speech is cut into short pieces at pauses (we already know exact word times), each piece
gets a "voice print" from an ECAPA speaker model, and similar voice prints are grouped.
The number of speakers is found automatically (1…6).
"""

import re

import numpy as np

GAP_SPLIT = 0.3     # a pause this long may be a change of speaker
MAX_UNIT = 4.0      # longer speech is cut into pieces of about this length
MIN_UNIT = 0.8      # shorter pieces are too short for a reliable voice print...
MIN_HEARD = 0.3     # ...but from this length they are still compared to the found voices
MAX_SPEAKERS = 6
SAME_VOICE = 0.08   # below this silhouette score everything is one speaker
MERGE_SIM = 0.45    # voice centres more alike than this are the same person (measured:
                    # one person's groups 0.4–0.87, two different people 0.18–0.27)
UNSURE = 0.12       # a piece about as similar to two voices as this (e.g. 0.36 vs 0.39)
                    # is decided by who speaks around it


def units(tokens: list[dict]) -> list[tuple[int, int]]:
    """Runs of speech (words and unrecognised speech) between pauses: (first, last) token."""
    out, first = [], None
    prev_word = None
    for i, t in enumerate(tokens):
        speech = t["kind"] in ("word", "speech")
        long_pause = t["kind"] == "pause" and t["end"] - t["start"] >= GAP_SPLIT
        if speech:
            # people often answer right after a question: a sentence end is a possible change too
            sentence_end = prev_word is not None and re.search(r"[.?!…]$", prev_word["text"])
            too_long = first is not None and t["end"] - tokens[first]["start"] > MAX_UNIT
            if first is not None and t["kind"] == "word" and (too_long or sentence_end):
                out.append((first, i - 1))
                first = None
            if t["kind"] == "word":
                prev_word = t
            if first is None:
                first = i
        elif long_pause and first is not None:
            out.append((first, i - 1))
            first = None
    if first is not None:
        out.append((first, len(tokens) - 1))
    # trailing non-speech tokens don't belong to the piece
    trimmed = []
    for a, b in out:
        while b > a and tokens[b]["kind"] not in ("word", "speech"):
            b -= 1
        trimmed.append((a, b))
    return trimmed


def _kmeans(x: np.ndarray, k: int, weights: np.ndarray, seed: int) -> tuple[np.ndarray, np.ndarray]:
    """Spherical k-means (cosine) with k-means++ start."""
    rng = np.random.default_rng(seed)
    centers = [x[rng.choice(len(x), p=weights / weights.sum())]]
    for _ in range(1, k):
        d = 1 - np.max(x @ np.array(centers).T, axis=1)
        p = np.maximum(d, 0) * weights
        centers.append(x[rng.choice(len(x), p=p / p.sum())] if p.sum() > 0 else x[rng.integers(len(x))])
    c = np.array(centers)
    for _ in range(30):
        labels = np.argmax(x @ c.T, axis=1)
        new = np.array([(x[labels == j] * weights[labels == j, None]).sum(0) if np.any(labels == j) else c[j]
                        for j in range(k)])
        new /= np.linalg.norm(new, axis=1, keepdims=True) + 1e-9
        if np.allclose(new, c):
            break
        c = new
    return np.argmax(x @ c.T, axis=1), c


def _silhouette(sim: np.ndarray, labels: np.ndarray) -> float:
    dist = 1 - sim
    ks = np.unique(labels)
    if len(ks) < 2:
        return -1.0
    a = np.zeros(len(labels))
    b = np.full(len(labels), np.inf)
    for k in ks:
        mask = labels == k
        mean_d = dist[:, mask].sum(1) / np.maximum(mask.sum() - mask.astype(int), 1)
        a[mask] = mean_d[mask]
        b[~mask] = np.minimum(b[~mask], dist[~mask][:, mask].mean(1))
    s = (b - a) / np.maximum(np.maximum(a, b), 1e-9)
    return float(np.mean(s))


def cluster(embeddings: np.ndarray, weights: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Groups voice prints; returns labels and the voice centre of every speaker."""
    x = embeddings / (np.linalg.norm(embeddings, axis=1, keepdims=True) + 1e-9)
    if len(x) < 4:
        return np.zeros(len(x), dtype=int), x.mean(0, keepdims=True)
    sim = x @ x.T
    best = (SAME_VOICE, np.zeros(len(x), dtype=int), None)
    for k in range(2, min(MAX_SPEAKERS, len(x) - 1) + 1):
        for seed in range(3):
            labels, centers = _kmeans(x, k, weights, seed)
            score = _silhouette(sim, labels)
            if score > best[0]:
                best = (score, labels, centers)
    labels, centers = best[1], best[2]
    if centers is None:
        centers = x.mean(0, keepdims=True)
        centers /= np.linalg.norm(centers)
        return labels, centers
    return _merge_same_voices(x, weights, labels)


def _merge_same_voices(x, weights, labels):
    """k-means splits one person's voice by mood or loudness; join groups that sound alike."""
    groups = [np.flatnonzero(labels == k) for k in np.unique(labels)]

    def centre(idx):
        c = (x[idx] * weights[idx, None]).sum(0)
        return c / (np.linalg.norm(c) + 1e-9)

    while len(groups) > 1:
        cs = np.array([centre(g) for g in groups])
        sim = cs @ cs.T
        np.fill_diagonal(sim, -1)
        a, b = np.unravel_index(np.argmax(sim), sim.shape)
        if sim[a, b] <= MERGE_SIM:
            break
        groups[a] = np.concatenate([groups[a], groups[b]])
        groups.pop(b)
    merged = np.zeros(len(x), dtype=int)
    for k, g in enumerate(groups):
        merged[g] = k
    return merged, np.array([centre(g) for g in groups])


class SpeakerModel:
    def __init__(self, model_dir: str):
        from speechbrain.inference.speaker import EncoderClassifier
        from speechbrain.utils.fetching import LocalStrategy

        self.model = EncoderClassifier.from_hparams(
            source=model_dir, savedir=model_dir, run_opts={"device": "cpu"},
            local_strategy=LocalStrategy.NO_LINK)

    def embed(self, audio: np.ndarray) -> np.ndarray:
        import torch

        with torch.inference_mode():
            return self.model.encode_batch(torch.from_numpy(audio)[None]).squeeze().numpy()


def assign(tokens: list[dict], audio: np.ndarray, sr: int, model: SpeakerModel, on_progress=None) -> dict:
    """Adds "speaker" (0, 1, …) to tokens, in order of first appearance, and starts a
    paragraph wherever the speaker changes."""
    pieces = units(tokens)
    spans = [(tokens[a]["start"], tokens[b]["end"]) for a, b in pieces]
    heard = [i for i, (s, e) in enumerate(spans) if e - s >= MIN_HEARD]
    embeddings = {}
    for n, i in enumerate(heard):
        s, e = spans[i]
        embeddings[i] = model.embed(audio[int(s * sr):int(e * sr)])
        if on_progress and n % 20 == 0:
            on_progress(n / max(len(heard), 1))

    reliable = [i for i in heard if spans[i][1] - spans[i][0] >= MIN_UNIT]
    if not reliable:
        reliable = heard
    if not reliable:
        return {"count": 0}
    e = np.array([embeddings[i] for i in reliable])
    w = np.array([spans[i][1] - spans[i][0] for i in reliable])
    labels, centers = cluster(e, w)

    # every heard piece goes to the closest voice; note how sure that is
    label_of, unsure = {}, set()
    for i in heard:
        v = embeddings[i] / (np.linalg.norm(embeddings[i]) + 1e-9)
        sims = centers @ v
        order = np.argsort(sims)[::-1]
        label_of[i] = int(order[0])
        if len(sims) > 1 and sims[order[0]] - sims[order[1]] < UNSURE:
            unsure.add(i)
    # unsure pieces between two pieces of the same speaker belong to that speaker
    sure = [i for i in sorted(label_of) if i not in unsure]
    for i in unsure:
        before = next((label_of[j] for j in reversed(sure) if j < i), None)
        after = next((label_of[j] for j in sure if j > i), None)
        if before is not None and before == after:
            label_of[i] = before

    # renumber by first appearance, fill pieces too short to hear from their neighbours
    order, piece_label = {}, []
    last = None
    for i in range(len(pieces)):
        lab = label_of.get(i, last)
        if lab is None:
            lab = next((label_of[j] for j in range(i, len(pieces)) if j in label_of), 0)
        last = lab
        piece_label.append(order.setdefault(int(lab), len(order)))

    for t in tokens:
        t.pop("speaker", None)
    for (a, b), lab in zip(pieces, piece_label):
        for k in range(a, b + 1):
            tokens[k]["speaker"] = lab
    current = piece_label[0] if piece_label else 0
    for t in tokens:  # pauses and sounds belong to whoever spoke last
        if "speaker" in t:
            current = t["speaker"]
        else:
            t["speaker"] = current

    prev = None
    for t in tokens:
        if t["kind"] != "word":
            continue
        if prev is not None and t["speaker"] != prev:
            t["para"] = True
        prev = t["speaker"]

    seconds = {}
    for (s, e), lab in zip(spans, piece_label):
        seconds[lab] = seconds.get(lab, 0) + (e - s)
    return {"count": len(order), "seconds": {str(k): round(v, 1) for k, v in sorted(seconds.items())}}
