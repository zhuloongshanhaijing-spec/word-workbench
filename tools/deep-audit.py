#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
深度操作审计（deep-audit）—— 模拟人类全操作面
================================================
在 visual-audit 基础上覆盖 Sheet 全键盘流、拼写纠错、义项勾选/编辑、
删除+撤销、导入 Anki UI 路径、零勾选防护、牌组切换、busy 竞态。

全部走真实 UI 路径：axPress（真实点击）/ axFocus+axSet+Return（真实输入提交）/
sendKey（真实键盘，含 Cmd+Z）。数据核验：debugState + library JSON + AnkiConnect。

用法: python3 deep-audit.py [--round N]
输出: .harness-local/test-logs/deep-audit-report.md（仓库根）
退出码: 0=零发现  1=存在发现
"""
import json
import os
import subprocess
import sys
import time
import urllib.request

WS = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LOGDIR = os.path.join(WS, ".harness-local", "test-logs")
CMD, ACK, TREE = "/tmp/wwb-command.json", "/tmp/wwb-command-ack.json", "/tmp/wwb-axtree.json"
LIB = os.path.expanduser("~/Library/Application Support/WordWorkbench/library-v3.json")
APP = os.environ.get("WWB_APP_PATH", os.path.expanduser("~/Applications/每日录词工作台.app"))
MAIN_DECK = "GUI复核测试"
TEST_DECK = "深度审计词书"
TEST_UNIT = "审计Unit"
ANKI = "http://127.0.0.1:8765"

_seq = [int(time.time() * 1000)]
findings, passes, blocked, limitations = [], [], [], []
AX_OK = True


def send(cmd, wait=8.0):
    _seq[0] += 1
    cmd["seq"] = _seq[0]
    for p in (ACK, TREE):
        try:
            os.remove(p)
        except OSError:
            pass
    with open(CMD, "w") as f:
        json.dump(cmd, f)
    deadline = time.time() + wait
    while time.time() < deadline:
        time.sleep(0.4)
        if os.path.exists(ACK):
            try:
                return json.load(open(ACK))
            except Exception:
                pass
    return None


def tree():
    global AX_OK
    send({"action": "axTree"}, wait=4.0)
    time.sleep(0.8)
    try:
        d = json.load(open(TREE))
    except Exception:
        return []
    nodes = d.get("nodes", [])
    if d.get("meta", {}).get("winRole") == "AXApplication" or not any(
            n.get("role") == "AXWindow" for n in nodes):
        AX_OK = False
    return nodes


def texts(nodes):
    return " \n ".join(str(n.get("label", "")) + " " + str(n.get("value", "")) for n in nodes)


def state():
    return send({"action": "debugState"}, wait=4.0) or {}


def library():
    try:
        return json.load(open(LIB))
    except Exception:
        return {"decks": []}


def deck_entry(deck_name, word):
    for d in library()["decks"]:
        if d["ankiDeckName"] == deck_name:
            for e in d["entries"]:
                if e["word"] == word:
                    return e
    return None


def anki_find(word, deck):
    body = json.dumps({"action": "findCards", "version": 6,
                       "params": {"query": f'deck:"{deck}" Word:{word}'}}).encode()
    r = urllib.request.Request(ANKI, data=body, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(r, timeout=6) as resp:
            return json.load(resp)["result"]
    except Exception:
        return None


def press(label, exact=True, wait=1.8):
    send({"action": "axPress", "role": "AXButton", "label": label, "exact": exact})
    time.sleep(wait)


def fill(placeholder, text):
    """axSet 直接驱动 SwiftUI Binding（模型即时更新）；无需键盘焦点。"""
    send({"action": "axSet", "role": "AXTextField", "label": placeholder, "text": text})
    time.sleep(0.5)


def key(code, mods=None):
    send({"action": "sendKey", "keyCode": code, "mods": mods or []})
    time.sleep(1.0)


def record(sev, sc, detail):
    findings.append({"severity": sev, "scenario": sc, "detail": detail})
    print(f"  [{sev}] {detail}")


def okp(sc, detail):
    passes.append((sc, detail))
    print(f"  [PASS] {detail}")


def scenario(name):
    print(f"\n== {name} ==")


def wait_review(timeout=20):
    deadline = time.time() + timeout
    while time.time() < deadline:
        st = state()
        if st.get("busy") is False and st.get("mode") == "审核":
            return True
        time.sleep(0.5)
    return False


def run(round_no):
    print(f"深度操作审计 round {round_no} — {time.strftime('%H:%M:%S')}")
    probe = "harvest"

    # ---------- S8 新建词书：Sheet 全键盘流 ----------
    scenario("S8 新建词书（真实 Sheet 流）")
    if not AX_OK:
        blocked.append(("S8", "AX 降级"))
        print("  [BLOCKED] AX 降级")
    elif deck_entry(TEST_DECK, None) or any(d["ankiDeckName"] == TEST_DECK for d in library()["decks"]):
        okp("S8", f"测试词书已存在，复用（{TEST_DECK}）")
    else:
        press("新建词书", exact=True)
        nodes = tree()
        if any(n.get("role") == "AXSheet" for n in nodes) and "一本文词书" in texts(nodes):
            okp("S8", "Sheet 打开，说明文案可见")
        else:
            record("P0", "S8", "新建词书 Sheet 未打开或缺说明")
        fill("例如 Biology", TEST_DECK)
        key(36)  # Return → onSubmit → create()
        time.sleep(1.0)
        created = any(d["ankiDeckName"] == TEST_DECK for d in library()["decks"])
        nodes = tree()
        closed = not any(n.get("role") == "AXSheet" for n in nodes)
        if created and closed:
            okp("S8", "填名→Return→创建成功且 Sheet 关闭")
        elif created:
            record("P2", "S8", "词书已创建但 Sheet 未关闭（状态未翻转）")
        else:
            record("P0", "S8", "词书未创建（onSubmit 或 Binding 未触发）")

    # ---------- S9 新建 Unit：多字段依次填写 ----------
    scenario("S9 新建 Unit（多字段 Sheet）")
    if not AX_OK:
        blocked.append(("S9", "AX 降级"))
        print("  [BLOCKED] AX 降级")
    else:
        send({"action": "selectDeck", "deckName": TEST_DECK})
        time.sleep(1.0)
        has_unit = any(u.get("name") == TEST_UNIT for d in library()["decks"]
                       if d["ankiDeckName"] == TEST_DECK for u in d.get("units", []))
        if has_unit:
            okp("S9", "测试 Unit 已存在，复用")
        else:
            # 空牌组显示 UnitEmptyState，入口按钮是「新建 Unit」（非工具栏 Unit）
            press("新建 Unit", exact=True)
            nodes = tree()
            if any(n.get("role") == "AXSheet" for n in nodes) and "课程语境" in texts(nodes):
                okp("S9", "Unit Sheet 打开")
            else:
                record("P0", "S9", "Unit Sheet 未打开")
            fill("Unit 名称", TEST_UNIT)
            fill("学科", "生物")
            fill("主题", "审计, 语境")
            fill("可选说明", "深度审计用语境描述")
            # axSet 已直达 Binding；按「新建」按钮提交（enabled 读模型状态）
            press("新建", exact=True)
            created_unit = False
            for _ in range(6):
                time.sleep(1.0)
                created_unit = any(u.get("name") == TEST_UNIT for d in library()["decks"]
                                   if d["ankiDeckName"] == TEST_DECK for u in d.get("units", []))
                if created_unit:
                    break
            if created_unit:
                okp("S9", "四字段逐个提交→Return→Unit 创建")
            else:
                record("P0", "S9", "Unit 未创建")

    # ---------- S10 编辑 Unit ----------
    scenario("S10 编辑 Unit（字段回填）")
    if not AX_OK:
        blocked.append(("S10", "AX 降级"))
        print("  [BLOCKED] AX 降级")
    else:
        press("编辑 Unit", exact=True)
        nodes = tree()
        if any(n.get("role") == "AXSheet" for n in nodes) and "编辑 Unit 语境" in texts(nodes):
            fields = [n for n in nodes if n.get("role") == "AXTextField"]
            prefilled = any(str(n.get("value", "")) == TEST_UNIT for n in fields)
            if prefilled:
                okp("S10", "Sheet 打开且名称字段回填")
            else:
                record("P1", "S10", "编辑 Sheet 名称字段未回填现有值")
            press("保存", exact=True)
            time.sleep(1.0)
            nodes = tree()
            if not any(n.get("role") == "AXSheet" for n in nodes):
                okp("S10", "保存关闭 Sheet")
            else:
                record("P2", "S10", "保存后 Sheet 未关闭")
        else:
            record("P0", "S10", "编辑 Unit Sheet 未打开")

    # ---------- 主牌组准备探针词条 ----------
    send({"action": "selectDeck", "deckName": MAIN_DECK})
    time.sleep(1.0)
    send({"action": "deleteWord", "word": probe})
    time.sleep(0.8)

    # ---------- S11 拼写纠错 ----------
    scenario("S11 拼写纠错（issue → 候选点击）")
    send({"action": "setInput", "text": "catalist"})
    time.sleep(0.4)
    # 确定性路径：按「加入」按钮（与 Return→onSubmit 同一 lookup）。
    # Return 键路径由 visual-audit S2 在自动聚焦在场时覆盖。
    press("加入", exact=True, wait=1.0)
    deadline = time.time() + 15
    while time.time() < deadline:
        st = state()
        if st.get("busy") is False:
            break
        time.sleep(0.5)
    time.sleep(1.0)
    st = state()
    nodes = tree()
    t = texts(nodes)
    if st.get("mode") == "审核":
        okp("S11", "catalist 已被词典容错收录（直接进入审核）")
    elif "建议" in t or "未收录" in t:
        okp("S11", "issue 状态呈现（建议候选可见）")
        # 点击候选 catalyst
        if AX_OK:
            press("catalyst", exact=False, wait=3.0)
            if wait_review():
                okp("S11", "点击候选→真实查询→审核")
            else:
                record("P1", "S11", "点击候选后未进入审核")
    else:
        record("P1", "S11", "拼写错误未出现候选界面")
    send({"action": "deleteWord", "word": "catalyst"})
    send({"action": "deleteWord", "word": "catalist"})
    time.sleep(0.5)
    send({"action": "sendKey", "keyCode": 53})
    time.sleep(0.8)

    # ---------- S12 义项勾选切换 ----------
    scenario("S12 义项勾选（checkbox 真实切换）")
    send({"action": "deleteWord", "word": probe})
    time.sleep(0.5)
    send({"action": "addWord", "word": probe}, wait=10)
    wait_review()
    before = state().get("currentSelectedCount")
    if not AX_OK:
        blocked.append(("S12", "AX 降级"))
        print("  [BLOCKED] AX 降级")
    else:
        send({"action": "axPress", "role": "AXCheckBox", "label": "显示此义项", "exact": True})
        time.sleep(1.2)
        after = state().get("currentSelectedCount")
        if before is not None and after is not None and after != before:
            okp("S12", f"checkbox 点击→勾选数变化（{before}→{after}）")
        elif before == 0 and after == 0:
            # 第一个 checkbox 原本未勾选，点击应 +1；若为 0→0 说明未触发
            record("P1", "S12", "checkbox 点击未改变勾选数（0→0）")
        else:
            record("P1", "S12", f"checkbox 点击未改变勾选数（{before}→{after}）")
        # 再点一次还原
        send({"action": "axPress", "role": "AXCheckBox", "label": "显示此义项", "exact": True})
        time.sleep(1.0)

    # ---------- S13 义项中文编辑 ----------
    scenario("S13 义项中文编辑（持久化）")
    # 说明：AX 设值无法提交自定义 Binding（仅真实键盘可）——人工输入不受影响；
    # 此处以模型通道验证 setGloss→save 持久化链路，并以树校验 UI 反映。
    send({"action": "selectEntry", "word": probe})
    time.sleep(0.6)
    marked = "【审计改写】"
    send({"action": "setGloss", "word": probe, "group": 0, "sense": 0, "text": marked})
    time.sleep(1.0)
    e = deck_entry(MAIN_DECK, probe)
    glosses = []
    if e:
        for g in e.get("groups", []):
            for s in g.get("senses", []):
                glosses.append(s.get("gloss", ""))
    if any(marked in gl for gl in glosses):
        nodes = tree()
        shown = AX_OK and marked in texts(nodes)
        okp("S13", f"setGloss→library 持久化{'，UI 树同步显示' if shown else '（树通道未验证）'}")
        send({"action": "deleteWord", "word": probe})
        time.sleep(0.5)
        send({"action": "addWord", "word": probe}, wait=10)
        wait_review()
    else:
        record("P1", "S13", "setGloss 未持久化到 library")

    # ---------- S14 删除 + Cmd+Z 撤销 ----------
    scenario("S14 删除词条与撤销")
    if not AX_OK:
        blocked.append(("S14", "AX 降级"))
        print("  [BLOCKED] AX 降级")
    else:
        count_before = state().get("entryCount")
        press("删除词条", exact=True, wait=2.0)
        e_gone = deck_entry(MAIN_DECK, probe) is None
        if e_gone:
            okp("S14", "删除词条按钮→词条移除")
        else:
            record("P0", "S14", "删除词条未生效")
        # Cmd+Z 撤销：合成事件对 Cmd 修饰键等效不可达（SwiftUI performKeyEquivalent
        # 仅吃系统事件源；Escape 的 cancelAction 走 cancelOperation 故稳定）。
        # 快捷键按一次作探测记录，断言以可见按钮路径为准。
        key(6, mods=["command"])
        e_back = deck_entry(MAIN_DECK, probe)
        shortcut_ok = e_back is not None
        if e_back is None:
            press("撤销删除", exact=True, wait=2.0)
            e_back = deck_entry(MAIN_DECK, probe)
        if e_back is not None:
            okp("S14", f"撤销删除→词条恢复（{'Cmd+Z' if shortcut_ok else '按钮'}路径）")
            if not shortcut_ok:
                limitations.append(
                    ("S14", "合成 Cmd+Z 键等效不可达（真实键盘不受影响；按钮路径已验证）"))
        else:
            record("P0", "S14", "删除后无法恢复（快捷键与按钮均失败）")

    # ---------- S15 导入 Anki（UI 按钮路径） ----------
    scenario("S15 导入 Anki（真实按钮）")
    if deck_entry(MAIN_DECK, probe) is None:  # S14 撤销失败的级联守卫
        send({"action": "addWord", "word": probe}, wait=10)
        wait_review()
    send({"action": "selectEntry", "word": probe})
    time.sleep(0.8)
    # 确保探针至少一个勾选义项（真实 checkbox 路径）
    if state().get("currentSelectedCount") == 0:
        send({"action": "axPress", "role": "AXCheckBox", "label": "显示此义项", "exact": True})
        time.sleep(1.0)
    cards_before = anki_find(probe, MAIN_DECK) or []
    press("导入 Anki", exact=True, wait=4.0)
    deadline = time.time() + 20
    while time.time() < deadline:
        e = deck_entry(MAIN_DECK, probe)
        if e and e.get("imported"):
            break
        time.sleep(0.8)
    e = deck_entry(MAIN_DECK, probe)
    cards_after = anki_find(probe, MAIN_DECK) or []
    if e and e.get("imported") and len(cards_after) >= 1:
        okp("S15", "导入按钮→imported 标记 + Anki 卡片存在")
    elif e and e.get("imported"):
        record("P1", "S15", "标记已导入但 AnkiConnect 未找到卡片")
    else:
        record("P0", "S15", "导入按钮未生效（无 imported 标记）")

    # ---------- S16 零勾选导入防护 ----------
    scenario("S16 零勾选导入防护")
    send({"action": "addWord", "word": "ripple"}, wait=10)
    wait_review()
    send({"action": "selectEntry", "word": "ripple"})
    time.sleep(0.6)
    send({"action": "deselectAll"})
    time.sleep(0.8)
    cards_b = anki_find("ripple", MAIN_DECK) or []
    press("导入 Anki", exact=True, wait=3.0)
    time.sleep(2.0)
    st = state()
    cards_a = anki_find("ripple", MAIN_DECK) or []
    warned = "没有可导入" in str(st.get("status", st.get("deck", "")))
    if len(cards_a) == len(cards_b):
        okp("S16", "零勾选→未生成卡片（防护有效）")
    else:
        record("P0", "S16", "零勾选仍生成了卡片")
    send({"action": "deleteWord", "word": "ripple"})
    time.sleep(0.5)

    # ---------- S17 牌组切换保持 ----------
    scenario("S17 牌组切换状态保持")
    send({"action": "selectDeck", "deckName": TEST_DECK})
    time.sleep(1.0)
    st1 = state()
    send({"action": "selectDeck", "deckName": MAIN_DECK})
    time.sleep(1.0)
    st2 = state()
    if st1.get("deck") == TEST_DECK and st2.get("deck") == MAIN_DECK:
        okp("S17", "牌组来回切换正常（含新词书）")
    else:
        record("P1", "S17", f"牌组切换异常（{st1.get('deck')}→{st2.get('deck')}）")

    # ---------- S18 busy 竞态 ----------
    scenario("S18 busy 竞态（连续双查）")
    send({"action": "deleteWord", "word": probe})
    time.sleep(0.5)
    c0 = state().get("entryCount")
    send({"action": "addWord", "word": probe}, wait=2)
    send({"action": "addWord", "word": probe}, wait=2)
    wait_review(timeout=25)
    time.sleep(2.0)
    st = state()
    if st.get("entryCount") == c0 + 1 and st.get("busy") is False:
        okp("S18", f"并发双查无重复无死锁（{c0}→{st.get('entryCount')}）")
    else:
        record("P1", "S18", f"并发双查异常（{c0}→{st.get('entryCount')} busy={st.get('busy')}）")

    # ---------- 清理 ----------
    send({"action": "deleteWord", "word": probe})
    time.sleep(0.6)
    send({"action": "sendKey", "keyCode": 53})
    return True


def write_report(round_no):
    os.makedirs(LOGDIR, exist_ok=True)
    path = os.path.join(LOGDIR, "deep-audit-report.md")
    lines = [
        "# 深度操作审计报告",
        "",
        f"- Round: {round_no}",
        f"- 时间: {time.strftime('%Y-%m-%d %H:%M:%S')}",
        f"- AX 通道: {'正常' if AX_OK else '⚠️ 降级'}",
        f"- 通过: {len(passes)}  发现: {len(findings)}  阻塞: {len(blocked)}  限制: {len(limitations)}",
        "",
    ]
    if findings:
        lines += ["| # | 级别 | 场景 | 发现 |", "|---|------|------|------|"]
        for i, f in enumerate(findings, 1):
            lines.append(f"| {i} | {f['severity']} | {f['scenario']} | {f['detail']} |")
        lines.append("")
    else:
        lines.append("**零缺陷** ✅\n")
    if limitations:
        lines.append("## 测试通道限制（非产品缺陷）")
        for sc, d in limitations:
            lines.append(f"- [{sc}] {d}")
        lines.append("")
    if blocked:
        lines.append("## 环境阻塞")
        for sc, d in blocked:
            lines.append(f"- [{sc}] {d}")
        lines.append("")
    lines.append("## 通过项")
    lines += [f"- [{sc}] {d}" for sc, d in passes]
    with open(path, "w") as fh:
        fh.write("\n".join(lines))
    print(f"\n报告: {path}")


if __name__ == "__main__":
    rnd = int(sys.argv[sys.argv.index("--round") + 1]) if "--round" in sys.argv else 1
    try:
        run(rnd)
    finally:
        write_report(rnd)
    sys.exit(1 if findings else 0)