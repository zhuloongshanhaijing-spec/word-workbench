#!/usr/bin/env python3
"""Generate the independent held-out evaluation set from the real local
Open Dictionary SQLite database.

Why this script exists
----------------------
The checked-in ``cases.json`` is a *synthetic contract fixture*: it validates the
protocol, the ID alignment, and the fallback chain, and it was also used to
calibrate the selection thresholds. It therefore cannot be used to decide whether
the local reranker should be promoted.

This script builds a second, independent set whose candidates are exported from
the actual local ``distribution.sqlite``. Thresholds are never tuned on it.

Ground-truth rule (mechanical and auditable)
--------------------------------------------
For each case the expected top sense is the one whose Open Dictionary
``labels``/``topics``/gloss correspond to the Unit's declared subject, or the
case is marked ``expected_abstain`` when no sense of the entry corresponds to
that subject. Each case carries a ``rationale`` quoting the dictionary evidence
so a reviewer can audit the expectation against the record. Expectations are
authored from real records; they are never taken from model output.

Candidate text is byte-identical in shape to what the app sends, i.e. the value
produced by ``SourceSense.semanticDocument(headword:)``:

    单词：<headword>
    词性：<part of speech>
    义项：<gloss>
    领域：<labels + topics>
    例句：<english> <chinese>

Usage
-----
    /usr/bin/python3 workspace/benchmarks/semantic-ranking/generate_heldout_cases.py \\
        --database workspace/.harness-local/open-dictionary/distribution.sqlite \\
        --output   workspace/.harness-local/heldout/heldout_cases.json

The generated file contains real dictionary text (CC BY-SA 4.0), so it is
written to the ignored ``.harness-local`` area and is NOT committed to this MIT
repository. This script and its case specification are committed instead, which
keeps the evaluation reproducible without redistributing the data.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sqlite3
import sys

PRIORITY_RANK = {"core": 10, "common": 20, "rare": 30}

# --------------------------------------------------------------------------
# Case specification. Every candidate is read from the real database at run
# time; only the word, the Unit, and the audited expectation live here.
# --------------------------------------------------------------------------
CASES = [
    # ---------------- biology ----------------
    dict(
        id="biology-medium", category="daily_professional_conflict", word="medium",
        unit=dict(name="Microbiology culture", subject="生物", topics=["培养基", "微生物"],
                  context="细胞培养与微生物生长所需的营养环境"),
        expected="od:noun|et1|s4", abstain=False,
        rationale="词典标签 biology,microbiology 的义项「细胞培养基」；与「传播媒介」等日常义冲突。"),
    dict(
        id="biology-invasive", category="domain_obvious", word="invasive",
        unit=dict(name="Invasive species", subject="生物", topics=["入侵物种", "生态"],
                  context="外来物种对本地生态系统的影响"),
        expected="od:adj|et1|s5", abstain=False,
        rationale="词典标签 biology 的义项「入侵性的（物种）」；领域明显。"),
    dict(
        id="biology-expression", category="daily_professional_conflict", word="expression",
        unit=dict(name="Gene expression", subject="生物", topics=["基因", "分子生物学"],
                  context="基因如何转录并翻译成蛋白质"),
        expected="od:noun|et1|s6", abstain=False,
        rationale="词典标签 biology 的义项「基因表达」；与「表情」「措辞」等日常义冲突。"),
    dict(
        id="biology-vector", category="daily_professional_conflict", word="vector",
        unit=dict(name="Disease vectors", subject="生物", topics=["流行病学", "传播媒介"],
                  context="病原体在宿主之间的传播途径"),
        expected="od:noun|et1|s5", abstain=False,
        rationale="词典标签 epidemiology,medicine 的义项「疾病传播媒介」；与更常见的数学「向量」义冲突。"),
    # ---------------- environment ----------------
    dict(
        id="environment-runoff", category="domain_obvious", word="runoff",
        unit=dict(name="Water cycle and pollution", subject="环境", topics=["地表径流", "水污染"],
                  context="降水形成的地表径流及其携带的污染"),
        expected="od:noun|et1|s1", abstain=False,
        rationale="义项「地表径流」直接对应环境单元；与「加赛」「选举第二轮」义冲突。"),
    dict(
        id="environment-erosion", category="daily_professional_conflict", word="erosion",
        unit=dict(name="Soil erosion", subject="环境", topics=["侵蚀", "土壤"],
                  context="水土流失的成因与治理"),
        expected="od:noun|et1|s1", abstain=False,
        rationale="义项「自然侵蚀的结果」对应土壤侵蚀；与比喻义「逐渐丧失」冲突。"),
    dict(
        id="environment-sink", category="daily_professional_conflict", word="sink",
        unit=dict(name="Carbon sinks", subject="环境", topics=["碳汇", "温室气体"],
                  context="吸收并储存二氧化碳的碳汇机制"),
        expected="od:noun|et1|s6", abstain=False,
        rationale="义项「资源或能量汇」对应碳汇；与更核心的「水槽」义冲突，属真实语义挑战。"),
    # ---------------- physics ----------------
    dict(
        id="physics-wave", category="daily_professional_conflict", word="wave",
        unit=dict(name="Wave mechanics", subject="物理", topics=["机械波", "频率"],
                  context="机械波的传播、频率与波长"),
        expected="od:noun|et2|s3", abstain=False,
        rationale="词典标签 physics 的义项「波；波动（物理）」；与日常「波浪」义冲突。"),
    dict(
        id="physics-power", category="daily_professional_conflict", word="power",
        unit=dict(name="Electric power", subject="物理", topics=["功率", "电路"],
                  context="电功率与能量转换"),
        expected="od:noun|et1|s7", abstain=False,
        rationale="义项「力量；能量」带 physical 标签，对应功率；与「能力」「权力」义冲突。"),
    dict(
        id="physics-charge", category="daily_professional_conflict", word="charge",
        unit=dict(name="Electric charge", subject="物理", topics=["电荷", "电场"],
                  context="电荷与静电现象"),
        expected="od:noun|et1|s5", abstain=False,
        rationale="词典标签 chemistry,electrical-engineering 的义项「电荷」；与「费用」「指控」「责任」义冲突，且同词另有动词组。"),
    dict(
        id="physics-spin", category="daily_professional_conflict", word="spin",
        unit=dict(name="Particle spin", subject="物理", topics=["自旋", "量子"],
                  context="粒子的自旋量子数"),
        expected="od:noun|et1|s3", abstain=False,
        rationale="义项「自旋」对应量子物理；与更核心的「旋转；打转」义冲突。"),
    dict(
        id="physics-work", category="part_of_speech_conflict", word="work",
        unit=dict(name="Work and energy", subject="物理", topics=["功", "能量"],
                  context="力学中力做功与能量守恒"),
        expected="od:noun|et1|s7", abstain=False,
        rationale="义项「有用功；做功能力」带 natural-sciences 标签，对应物理学「功」；与名词「工作」及动词组冲突。"),
    # ---------------- humanities ----------------
    dict(
        id="humanities-restoration", category="daily_professional_conflict", word="restoration",
        unit=dict(name="The English Restoration", subject="人文", topics=["历史", "复辟"],
                  context="1660年英国君主制复辟这一历史事件"),
        expected="od:name|et2|s1", abstain=False,
        rationale="词典标签 history 的专名义项「1660年王政复辟」；与名词「恢复；修复」义冲突。"),
    dict(
        id="humanities-enlightenment", category="daily_professional_conflict", word="enlightenment",
        unit=dict(name="The Enlightenment", subject="人文", topics=["启蒙", "欧洲思想史"],
                  context="18世纪欧洲的启蒙思想运动"),
        expected="od:name|et2|s1", abstain=False,
        rationale="词典标签 history 的专名义项「启蒙运动」；与名词「启发」「开悟」义冲突。"),
    dict(
        id="humanities-canon", category="daily_professional_conflict", word="canon",
        unit=dict(name="Literary canon", subject="人文", topics=["文学", "经典"],
                  context="文学经典作品的范围与形成"),
        expected="od:noun|et1|s2", abstain=False,
        rationale="义项「经典作品范围」对应文学经典；与「教会法规」「卡农曲」「虚构正史」义冲突。"),
    dict(
        id="humanities-movement", category="daily_professional_conflict", word="movement",
        unit=dict(name="Social movements", subject="人文", topics=["社会运动", "历史"],
                  context="社会变革运动的历史"),
        expected="od:noun|et1|s4", abstain=False,
        rationale="义项「社会运动；潮流」对应社会运动史；与更核心的「移动；运动」义冲突。"),
    dict(
        id="humanities-medium", category="same_word_other_unit", word="medium",
        unit=dict(name="Artistic media", subject="人文", topics=["艺术媒介", "表现手法"],
                  context="艺术创作中使用的媒介与材料"),
        expected="od:noun|et1|s9", abstain=False,
        rationale="义项「艺术表达媒介」对应艺术单元；同一个 medium 在生物单元应选另一个义项。"),
    # ---------------- psychology / emotion ----------------
    dict(
        id="psychology-repression", category="daily_professional_conflict", word="repression",
        unit=dict(name="Defence mechanisms", subject="情绪", topics=["压抑", "无意识"],
                  context="精神分析中的压抑机制"),
        expected="od:noun|et1|s2", abstain=False,
        rationale="词典标签 psychology 的义项「心理压抑；无意识排除」；与「压制；镇压」义冲突。"),
    dict(
        id="psychology-projection", category="daily_professional_conflict", word="projection",
        unit=dict(name="Defence mechanisms", subject="情绪", topics=["心理防御机制", "投射"],
                  context="心理防御机制中的投射"),
        expected="od:noun|et1|s6", abstain=False,
        rationale="词典标签 psychology 的义项「心理投射」；与「预测」「凸出物」「图像投影」义冲突。"),
    dict(
        id="psychology-trigger", category="part_of_speech_conflict", word="trigger",
        unit=dict(name="Trauma triggers", subject="情绪", topics=["创伤", "触发因素"],
                  context="引发创伤记忆的心理刺激"),
        expected="od:noun|et1|s5", abstain=False,
        rationale="词典标签 psychology 的义项「唤起创伤记忆的刺激」；与「枪的扳机」及动词组冲突。"),
    # ---------------- wrong input / abstain ----------------
    dict(
        id="abstain-kindly-wrong-input", category="abstain_wrong_input", word="kindly",
        unit=dict(name="Newtonian mechanics", subject="物理", topics=["力学", "运动"],
                  context="牛顿运动定律"),
        expected=None, abstain=True,
        rationale="kindly 只有形容词/副词义，与该物理单元无任何对应义项；不应强行推荐。"),
    dict(
        id="abstain-teaspoon-wrong-input", category="abstain_wrong_input", word="teaspoon",
        unit=dict(name="Data structures", subject="计算机", topics=["算法", "数据结构"],
                  context="编程与算法基础"),
        expected=None, abstain=True,
        rationale="teaspoon 为具体名词，与计算机单元无对应义项；拼写或选词错误时应弃权。"),
    dict(
        id="abstain-velvet-no-domain", category="abstain", word="velvet",
        unit=dict(name="Geometrical optics", subject="物理", topics=["光学", "折射"],
                  context="光的折射与反射"),
        expected=None, abstain=True,
        rationale="velvet 无光学义项；单元信息不足以支持任何义项，应全部默认关闭。"),
    dict(
        id="abstain-medium-no-context", category="abstain_insufficient_context", word="medium",
        unit=dict(name="", subject="", topics=[], context=""),
        expected=None, abstain=True,
        rationale="空 Unit 语境：策略要求默认不勾选任何义项，即使模型仍给出排序。"),
]


def semantic_document(headword: str, pos: str, gloss: str, hints: list[str], example: dict | None) -> str:
    """Mirror of SourceSense.semanticDocument(headword:)."""
    parts = [
        f"单词：{headword}",
        f"词性：{pos}",
        f"义项：{gloss}",
        f"领域：{'，'.join(hints)}",
    ]
    if example:
        parts.append(f"例句：{example.get('text', '')} {example.get('translation', '')}")
    return "\n".join(part for part in parts if not part.endswith("："))


def load_entry(connection: sqlite3.Connection, word: str) -> dict:
    row = connection.execute(
        "SELECT document_json FROM entries WHERE normalized_headword = ? LIMIT 1", (word,)
    ).fetchone()
    if row is None:
        raise SystemExit(f"word not found in local dictionary: {word}")
    return json.loads(row[0])


def build_case(connection: sqlite3.Connection, spec: dict) -> dict:
    document = load_entry(connection, spec["word"])
    headword = document["headword"]
    candidates = []
    for group in document.get("pos_groups", []):
        pos = group.get("pos", "")
        etymology = group.get("etymology_id")
        for meaning in group.get("meanings", []):
            raw_id = meaning.get("sense_id", "")
            stable_id = f"od:{pos}|{etymology}|{raw_id}" if etymology else raw_id
            gloss = (meaning.get("short_gloss") or "").strip() or meaning.get("learner_explanation", "")
            hints = list(meaning.get("labels") or []) + list(meaning.get("topics") or [])
            examples = meaning.get("examples") or []
            candidates.append({
                "sourceSenseID": stable_id,
                "pos": pos,
                "priority": meaning.get("priority"),
                "text": semantic_document(headword, pos, gloss, hints, examples[0] if examples else None),
                "domainHints": hints,
                "sourceRank": PRIORITY_RANK.get(meaning.get("priority", ""), 100),
            })
    ids = [candidate["sourceSenseID"] for candidate in candidates]
    if len(set(ids)) != len(ids):
        raise SystemExit(f"duplicate sourceSenseID for {spec['word']}")
    if spec["expected"] is not None and spec["expected"] not in ids:
        raise SystemExit(f"{spec['id']}: expected id {spec['expected']} not among real candidates")
    if spec["abstain"] and spec["expected"] is not None:
        raise SystemExit(f"{spec['id']}: abstain case must not declare an expected top id")
    return {
        "id": spec["id"],
        "category": spec["category"],
        "word": headword,
        "unit": spec["unit"],
        "candidates": candidates,
        "expected_top_id": spec["expected"],
        "expected_abstain": spec["abstain"],
        "rationale": spec["rationale"],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", required=True)
    parser.add_argument("--output", required=True)
    arguments = parser.parse_args()

    connection = sqlite3.connect(f"file:{arguments.database}?mode=ro", uri=True)
    try:
        cases = [build_case(connection, spec) for spec in CASES]
    finally:
        connection.close()

    subjects = sorted({case["unit"]["subject"] for case in cases if case["unit"]["subject"]})
    words = sorted({case["word"] for case in cases})
    categories = sorted({case["category"] for case in cases})
    payload = {
        "schema_version": 1,
        "name": "WordWorkbench independent held-out evaluation (real Open Dictionary records)",
        "kind": "heldout_evaluation",
        "provenance_notes": (
            "All candidates are exported from the real local Open Dictionary v2.0 "
            "distribution.sqlite by generate_heldout_cases.py; no text is synthetic. "
            "sourceSenseID follows the published contract identity (pos, etymology_id, sense_id). "
            "Expected top senses were audited by the implementer against the dictionary's own "
            "labels/topics/gloss and are quoted per case in `rationale`; they are never derived "
            "from model output. These cases were NOT used to calibrate the selection thresholds. "
            "Regenerate with: /usr/bin/python3 workspace/benchmarks/semantic-ranking/"
            "generate_heldout_cases.py --database workspace/.harness-local/open-dictionary/"
            "distribution.sqlite --output workspace/.harness-local/heldout/heldout_cases.json"
        ),
        "license_note": (
            "Candidate text is derived from Open Dictionary data (CC BY-SA 4.0). The generated "
            "file is written to the ignored .harness-local area and is not committed to the MIT "
            "source repository."
        ),
        "description_rule": "expected_top_id = the sense whose Open Dictionary labels/topics/gloss correspond to the Unit subject; expected_abstain = no sense of the entry corresponds.",
        "case_count": len(cases),
        "subject_count": len(subjects),
        "subjects": subjects,
        "word_count": len(words),
        "words": words,
        "categories": categories,
        "cases": cases,
    }

    with open(arguments.output, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2)
        handle.write("\n")

    digest = hashlib.sha256(json.dumps(payload, ensure_ascii=False, sort_keys=True).encode()).hexdigest()
    print(f"cases={len(cases)} words={len(words)} subjects={len(subjects)} categories={len(categories)}")
    print(f"subjects={subjects}")
    print(f"content_sha256={digest}")
    print(f"wrote={arguments.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
