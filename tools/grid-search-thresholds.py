#!/usr/bin/env python3
"""
Threshold grid search for SemanticSelectionPolicy against the heldout set.

1. Calls Ollama bge-m3 to embed unit context + each candidate text
2. Computes cosine similarity → calibrated probability via (score+1)/2
3. Grid-searches min_confidence (0.70-0.95) and min_margin (0.0-0.15)
4. Reports top-k combinations by accuracy

Usage:
    python3 tools/grid-search-thresholds.py \
        --heldout .harness-local/heldout/heldout_cases.json \
        --output .harness-local/grid-search-results.json \
        --ollama http://127.0.0.1:11434
"""

import argparse
import json
import math
import time
import urllib.request
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Optional, List, Tuple

OLLAMA_EMBED_URL = "http://127.0.0.1:11434/api/embeddings"
MODEL = "bge-m3:latest"

# ------------------------------------------------------------
# Ollama embedding API
# ------------------------------------------------------------

def ollama_embed(text: str, timeout: int = 60) -> Optional[List[float]]:
    """Return bge-m3 embedding vector for text, or None on failure."""
    payload = json.dumps({"model": MODEL, "prompt": text}).encode("utf-8")
    req = urllib.request.Request(OLLAMA_EMBED_URL, data=payload,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read())
            return data.get("embedding")
    except Exception as e:
        print(f"  ! embed error: {e}", file=sys.stderr)
        return None


def cosine_similarity(a: list[float], b: list[float]) -> float:
    dot = sum(x * y for x, y in zip(a, b))
    norm_a = math.sqrt(sum(x * x for x in a))
    norm_b = math.sqrt(sum(x * x for x in b))
    if norm_a == 0 or norm_b == 0:
        return 0.0
    return dot / (norm_a * norm_b)


# ------------------------------------------------------------
# Calibration (mirrors SemanticScoreCalibration.ollamaEmbedding)
# ------------------------------------------------------------
def calibrate(raw_cosine: float) -> float:
    """Map cosine [-1, 1] → probability [0, 1]."""
    return min(1.0, max(0.0, (raw_cosine + 1.0) / 2.0))


# ------------------------------------------------------------
# Selection policy (mirrors SemanticSelectionPolicy.selectedSourceIDs)
# ------------------------------------------------------------
def select_top(
    scores: List[Tuple[str, float]],  # [(sourceSenseID, calibrated_prob), ...] sorted desc
    min_confidence: float,
    min_margin: float,
    unit_has_context: bool = True,
) -> set:
    """Return the set of selected sourceSenseIDs under the policy."""
    if not unit_has_context or not scores:
        return set()
    top_id, top_prob = scores[0]
    if top_prob < min_confidence:
        return set()
    if len(scores) > 1:
        runner_up_prob = scores[1][1]
        if top_prob - runner_up_prob < min_margin:
            return set()
    elif min_margin > 0 and top_prob < min_confidence + min_margin:
        return set()
    return {top_id}


# ------------------------------------------------------------
# Case evaluation
# ------------------------------------------------------------
def evaluate_case(case: dict, unit_embedding: List[float],
                  min_conf: float, min_margin: float) -> Tuple[bool, str]:
    """
    Returns (correct, detail_string) for this case under the given thresholds.
    """
    # Score each candidate
    scored = []
    for cand in case["candidates"]:
        cid = cand["sourceSenseID"]
        text = cand["text"]
        emb = ollama_embed(text)
        if emb is None:
            return False, f"embed_fail:{cid}"
        raw = cosine_similarity(unit_embedding, emb)
        cal = calibrate(raw)
        scored.append((cid, cal))

    # Sort descending by calibrated probability
    scored.sort(key=lambda x: x[1], reverse=True)

    # Apply policy
    unit_has_context = bool(case["unit"].get("subject") or case["unit"].get("context"))
    selected = select_top(scored, min_conf, min_margin, unit_has_context)

    # Check against ground truth
    expect_abstain = case.get("expected_abstain", False)
    expect_top = case.get("expected_top_id")

    if expect_abstain:
        correct = len(selected) == 0
        detail = f"abstain:selected={len(selected)}"
    else:
        correct = selected == {expect_top}
        detail = f"expected={expect_top} got={selected} top_score={scored[0][1]:.4f}" if scored else "no_scores"

    return correct, detail


# ------------------------------------------------------------
# Grid search
# ------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--heldout", required=True, help="heldout_cases.json path")
    parser.add_argument("--output", default="/tmp/grid-search-results.json")
    parser.add_argument("--ollama", default="http://127.0.0.1:11434")
    parser.add_argument("--precompute", default="/tmp/heldout-scores.json",
                        help="cache path for pre-computed scores (skip Ollama if exists)")
    args = parser.parse_args()

    global OLLAMA_EMBED_URL
    OLLAMA_EMBED_URL = args.ollama.rstrip("/") + "/api/embeddings"

    with open(args.heldout) as f:
        dataset = json.load(f)

    cases = dataset["cases"]
    print(f"Dataset: {len(cases)} cases, kind={dataset.get('kind','?')}")

    # Pre-compute: embed each unit context AND all candidate texts
    # Use cache if available
    precomputed = {}
    if args.precompute:
        try:
            with open(args.precompute) as f:
                precomputed = json.load(f)
            if precomputed.get("case_count") == len(cases):
                print(f"Loaded pre-computed scores from {args.precompute}")
            else:
                precomputed = {}
        except (FileNotFoundError, json.JSONDecodeError):
            pass

    if not precomputed:
        print("Computing embeddings (this will take a while)...")
        precomputed = {"case_count": len(cases), "cases": {}}

        for i, case in enumerate(cases):
            cid = case["id"]
            print(f"  [{i+1}/{len(cases)}] {cid} ({case['word']})", end=" ", flush=True)

            # Embed unit context
            unit = case["unit"]
            unit_text = f"学科：{unit.get('subject','')}。主题：{', '.join(unit.get('topics',[]))}。语境：{unit.get('context','')}"
            unit_emb = ollama_embed(unit_text)
            if unit_emb is None:
                print("UNIT EMBED FAIL")
                continue

            # Embed each candidate
            cand_scores = []
            for cand in case["candidates"]:
                c_emb = ollama_embed(cand["text"])
                if c_emb is None:
                    print(f"  CANDIDATE EMBED FAIL: {cand['sourceSenseID']}")
                    continue
                raw = cosine_similarity(unit_emb, c_emb)
                cal = calibrate(raw)
                cand_scores.append({
                    "sourceSenseID": cand["sourceSenseID"],
                    "raw": round(raw, 6),
                    "calibrated": round(cal, 6),
                })

            # Sort and store
            cand_scores.sort(key=lambda x: x["calibrated"], reverse=True)
            precomputed["cases"][cid] = {
                "unit_embedding": unit_emb,
                "candidate_scores": cand_scores,
            }
            print(f"ok ({len(cand_scores)} scores)")

        # Save cache
        if args.precompute:
            with open(args.precompute, "w") as f:
                json.dump(precomputed, f, indent=2)
            print(f"Saved pre-computed scores to {args.precompute}")

    # Grid search
    print("\nGrid searching thresholds...")
    results = []

    conf_range = [round(x / 100, 3) for x in range(70, 96, 1)]  # 0.70 to 0.95 step 0.01
    margin_range = [round(x / 100, 3) for x in range(0, 16, 1)]  # 0.00 to 0.15 step 0.01

    total = len(conf_range) * len(margin_range)
    for i, min_conf in enumerate(conf_range):
        for j, min_margin in enumerate(margin_range):
            correct = 0
            total_cases = 0
            failures = []

            for case in cases:
                cid = case["id"]
                if cid not in precomputed.get("cases", {}):
                    continue
                pc = precomputed["cases"][cid]
                scores = [(s["sourceSenseID"], s["calibrated"]) for s in pc["candidate_scores"]]

                expect_abstain = case.get("expected_abstain", False)
                expect_top = case.get("expected_top_id")
                unit_has_context = bool(case["unit"].get("subject") or case["unit"].get("context"))

                selected = select_top(scores, min_conf, min_margin, unit_has_context)

                if expect_abstain:
                    ok = len(selected) == 0
                else:
                    ok = selected == {expect_top}

                if ok:
                    correct += 1
                else:
                    failures.append({
                        "case_id": cid,
                        "word": case["word"],
                        "expected_abstain": expect_abstain,
                        "expected_top": expect_top,
                        "selected": list(selected),
                        "top_score": scores[0][1] if scores else 0,
                    })

                total_cases += 1

            accuracy = correct / max(total_cases, 1)
            results.append({
                "min_confidence": min_conf,
                "min_margin": min_margin,
                "accuracy": round(accuracy, 4),
                "correct": correct,
                "total": total_cases,
                "failures": failures,
            })

    # Sort by accuracy descending, then by margin ascending (prefer simpler)
    results.sort(key=lambda r: (-r["accuracy"], r["min_margin"]))

    print(f"\nTop 10 threshold combinations:")
    print(f"{'Rank':<6}{'min_conf':<12}{'min_margin':<12}{'accuracy':<10}{'correct/total'}")
    print("-" * 56)
    for rank, r in enumerate(results[:10], 1):
        print(f"{rank:<6}{r['min_confidence']:<12.3f}{r['min_margin']:<12.3f}{r['accuracy']:<10.4f}{r['correct']}/{r['total']}")

    # Current baseline
    current_conf = 0.79
    current_margin = 0.0
    current = next((r for r in results if abs(r['min_confidence'] - current_conf) < 0.001 and abs(r['min_margin'] - current_margin) < 0.001), None)
    if current:
        print(f"\nCurrent (conf={current_conf}, margin={current_margin}): accuracy={current['accuracy']:.4f} ({current['correct']}/{current['total']})")
        print(f"  Failures: {[f['case_id'] for f in current['failures']]}")

    # Save full results
    output = {
        "dataset": args.heldout,
        "model": MODEL,
        "current_thresholds": {"min_confidence": current_conf, "min_margin": current_margin},
        "current_accuracy": current["accuracy"] if current else None,
        "top_results": results[:20],
        "all_results": results,
    }
    with open(args.output, "w") as f:
        json.dump(output, f, indent=2, ensure_ascii=False)
    print(f"\nFull results saved to {args.output}")

    # Summary for auto-continuation
    best = results[0]
    print(f"\nBEST: conf={best['min_confidence']:.3f} margin={best['min_margin']:.3f} accuracy={best['accuracy']:.4f}")


if __name__ == "__main__":
    main()