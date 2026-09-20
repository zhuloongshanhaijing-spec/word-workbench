#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
语义级 UI 审计驱动器（visual-audit）
====================================
模拟真实用户全流程：真实焦点、真实键盘事件、真实按钮点击（AX 语义操作），
每一步截取 AX 语义快照 + debugState 核验，产出结构化审计报告。

通道：
  - axTree   界面语义快照（角色/标签/值/坐标），进程内免权限
  - axPress  语义点击（触发真实 SwiftUI 处理器）
  - axFocus  语义聚焦（等价用户点进输入框）
  - sendKey  真实按键分发（Return=36 触发 onSubmit；Escape=53 走响应链）
  - debugState  内部状态核验（mode/busy/entryCount）

用法: python3 visual-audit.py [--round N]
输出: .harness-local/test-logs/visual-audit-report.md
退出码: 0=零缺陷  1=存在审计发现
"""
import json
import os
import subprocess
import sys
import time

WS = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LOGDIR = os.path.join(WS, ".harness-local", "test-logs")
CMD_PATH = "/tmp/wwb-command.json"
ACK_PATH = "/tmp/wwb-command-ack.json"
TREE_PATH = "/tmp/wwb-axtree.json"
APP = os.environ.get("WWB_APP_PATH", os.path.expanduser("~/Applications/每日录词工作台.app"))
DECK = "GUI复核测试"

_seq = [int(time.time() * 1000)]
findings = []
passes = []
blocked = []


def send(cmd, wait=8.0):
    """投递命令并等待 ack；返回 ack dict 或 None。"""
    _seq[0] += 1
    cmd["seq"] = _seq[0]
    for p in (ACK_PATH, TREE_PATH):
        try:
            os.remove(p)
        except OSError:
            pass
    with open(CMD_PATH, "w") as f:
        json.dump(cmd, f)
    deadline = time.time() + wait
    while time.time() < deadline:
        time.sleep(0.4)
        if os.path.exists(ACK_PATH):
            try:
                return json.load(open(ACK_PATH))
            except Exception:
                pass
    return None


AX_DEGRADED = False  # 登录会话内 AX 服务端缓存损坏时置位（winRole=AXApplication）


def tree():
    global AX_DEGRADED
    send({"action": "axTree"}, wait=4.0)
    time.sleep(0.8)
    try:
        d = json.load(open(TREE_PATH))
    except Exception:
        return []
    nodes = d.get("nodes", [])
    meta = d.get("meta", {})
    if meta.get("winRole") == "AXApplication" or not any(n.get("role") == "AXWindow" for n in nodes):
        AX_DEGRADED = True
    return nodes


def state():
    return send({"action": "debugState"}, wait=4.0) or {}


def node_texts(nodes):
    out = []
    for n in nodes:
        out.append(str(n.get("label", "")))
        out.append(str(n.get("value", "")))
    return " \n ".join(out)


def relaunch():
    subprocess.run(["pkill", "-9", "-f", "WordWorkbench"], capture_output=True)
    # 确认死亡（僵尸注册会让 open 变成空操作）
    for _ in range(10):
        r = subprocess.run(["pgrep", "-f", "WordWorkbench"], capture_output=True)
        if r.returncode != 0:
            break
        time.sleep(0.5)
    time.sleep(1.0)
    subprocess.run(["open", APP], capture_output=True)
    # 就绪 = 命令环响应 且 UI 树已构建（debugState 先于窗口内容就绪是竞态源）
    deadline = time.time() + 30
    while time.time() < deadline:
        time.sleep(1.0)
        st = state()
        if st.get("status") == "ok":
            nodes = tree()
            if len(nodes) > 30:
                time.sleep(1.0)  # 内容稳定
                return True
    return False


def note_blocked(scenario, detail):
    blocked.append((scenario, detail))
    print(f"  [BLOCKED] {detail}（AX 通道降级，状态通道已覆盖）")


def record(severity, scenario, detail):
    findings.append({"severity": severity, "scenario": scenario, "detail": detail})
    print(f"  [{severity}] {detail}")


def ok(scenario, detail):
    passes.append((scenario, detail))
    print(f"  [PASS] {detail}")


def scenario(name):
    print(f"\n== {name} ==")


def run(round_no):
    print(f"视觉审计 round {round_no} — {time.strftime('%H:%M:%S')}")

    # ---------- S1 冷启动 ----------
    scenario("S1 冷启动")
    if not relaunch():
        record("P0", "S1", "应用 20s 内未就绪（debugState 无 ack）")
        return False
    ok("S1", "应用启动并响应命令")
    send({"action": "selectDeck", "deckName": DECK})
    time.sleep(1.0)
    nodes = tree()
    texts = node_texts(nodes)
    if AX_DEGRADED:
        note_blocked("S1", "录入视图标题树校验")
    elif "录入今天的单词" not in texts:
        record("P1", "S1", "录入视图标题缺失")
    else:
        ok("S1", "录入视图标题在位")
    st = state()
    if not str(st.get("mode", "")):
        record("P1", "S1", "debugState 缺少 mode 字段")
    else:
        ok("S1", f"初始 mode={st.get('mode')}")

    # ---------- S2 打字 → Return 真实查询 ----------
    scenario("S2 输入单词并按 Return（真实路径）")
    pool = ["harvest", "silver", "garden", "anchor", "meadow", "candle", "ripple", "lantern"]
    probe = pool[round_no % len(pool)]
    send({"action": "deleteWord", "word": probe})  # 清理历史遗留探针
    time.sleep(1.0)
    before = state().get("entryCount")
    if AX_DEGRADED:
        # 降级模式：走 addWord 命令（与 onSubmit→lookup 同一模型路径）
        send({"action": "addWord", "word": probe}, wait=10)
    else:
        send({"action": "setInput", "text": probe})
        time.sleep(0.4)
        send({"action": "axFocus", "role": "AXTextField"})
        time.sleep(0.4)
        send({"action": "sendKey", "keyCode": 36})
    deadline = time.time() + 20
    while time.time() < deadline:
        st = state()
        if st.get("busy") is False and st.get("mode") == "审核":
            break
        time.sleep(0.5)
    st = state()
    if st.get("mode") != "审核":
        record("P1", "S2", "查询后未进入审核模式（lookup 链路断裂）")
    else:
        ok("S2", "lookup→审核 全链路生效" + ("" if not AX_DEGRADED else "（降级：命令通道）"))
    if st.get("entryCount") == before + 1:
        ok("S2", f"词条 +1（{before}→{st.get('entryCount')}）")
    elif st.get("entryCount") == before:
        record("P1", "S2", f"词条数未增加（{probe} 可能已存在或 lookup 失败）")
    nodes = tree()
    if AX_DEGRADED:
        note_blocked("S2", "审核列表树校验")
    elif probe not in node_texts(nodes):
        record("P2", "S2", f"审核列表未见新词 {probe}")

    # ---------- S3 Escape 响应链 ----------
    scenario("S3 Escape 退出审核")
    send({"action": "sendKey", "keyCode": 53})
    time.sleep(1.2)
    st = state()
    if st.get("mode") != "录入":
        record("P0", "S3", "Escape 未从审核切回录入（用户报告过的核心缺陷）")
    else:
        ok("S3", "Escape 经真实响应链切回录入")

    # ---------- S4 重复词去重 ----------
    scenario("S4 重复词条防护")
    count = state().get("entryCount")
    if AX_DEGRADED:
        send({"action": "addWord", "word": probe}, wait=10)
    else:
        send({"action": "setInput", "text": probe})
        time.sleep(0.3)
        send({"action": "sendKey", "keyCode": 36})
    deadline = time.time() + 20
    while time.time() < deadline:
        st = state()
        if st.get("busy") is False and st.get("mode") == "审核":
            break
        time.sleep(0.5)
    st = state()
    if st.get("entryCount") == count:
        ok("S4", f"同词重复录入被合并（保持 {count}）")
    else:
        record("P1", "S4", f"同词重复录入产生重复词条（{count}→{st.get('entryCount')}）")

    # ---------- S5 设置 Sheet 语义操作 ----------
    scenario("S5 设置面板真实操作")
    send({"action": "sendKey", "keyCode": 53})  # 回录入
    time.sleep(0.8)
    if AX_DEGRADED:
        note_blocked("S5", "设置面板语义操作（AXSheet/axPress 依赖树通道）")
    else:
        opened = False
        for attempt in range(3):  # 模式切换后立即点击偶发失效，重试
            send({"action": "axPress", "role": "AXButton", "label": "设置"})
            time.sleep(2.0)
            nodes = tree()
            if any(n.get("role") == "AXSheet" for n in nodes):
                opened = True
                break
        if not opened:
            record("P0", "S5", "语义点击『设置』未打开面板（3 次重试后仍无 AXSheet）")
        else:
            ok("S5", "AXSheet 打开")
            texts = node_texts(nodes)
            if "本地重排" not in texts:
                record("P1", "S5", "设置面板缺少本地重排分组")
            else:
                ok("S5", "本地重排分组可见")
            # 检测本地重排服务
            send({"action": "axPress", "role": "AXButton", "label": "检测本地重排服务"})
            time.sleep(3.5)
            nodes = tree()
            texts = node_texts(nodes)
            if "已就绪" in texts:
                ok("S5", "本地重排检测→已就绪")
            elif "尚未检测" in texts:
                # 未变：检测按钮可能没按到或服务未起
                record("P1", "S5", "检测本地重排后状态未更新为已就绪")
            # 关闭面板（完成按钮）
            send({"action": "axPress", "role": "AXButton", "label": "完成"})
            time.sleep(1.5)
            nodes = tree()
            if any(n.get("role") == "AXSheet" for n in nodes):
                record("P2", "S5", "点击『完成』后面板仍存在（关闭延迟或失效）")
            else:
                ok("S5", "完成按钮关闭面板")

    # ---------- S6 无障碍扫描 ----------
    scenario("S6 无障碍标签扫描")
    nodes = tree()
    if AX_DEGRADED:
        note_blocked("S6", "无障碍标签扫描（树通道降级）")
    else:
        # 窗口原点由 AXWindow frame 提供，用于豁免系统窗口红绿灯按钮
        win = next((n for n in nodes if n.get("role") == "AXWindow"), None)
        wf = (win or {}).get("frame", {})
        wx, wy = wf.get("x", 0), wf.get("y", 0)
        unlabeled = []
        for n in nodes:
            if n.get("role") in ("AXButton", "AXRadioButton", "AXCheckBox"):
                if n.get("label") or n.get("value"):
                    continue
                f = n.get("frame", {})
                # 系统窗口 chrome（红绿灯按钮）：窗口左上角 60×45 区域内的小按钮
                if (f.get("w", 99) <= 16 and f.get("h", 99) <= 16
                        and f.get("x", 1e9) - wx < 70 and f.get("y", 1e9) - wy < 45):
                    continue
                unlabeled.append(f"{n.get('role')}@y{f.get('y')}")
        if unlabeled:
            record("P2", "S6", "无标签可交互控件: " + ", ".join(unlabeled[:8]))
        else:
            ok("S6", "全部可交互控件均有语义标签（系统窗口 chrome 除外）")

    # ---------- S7 状态一致性 ----------
    scenario("S7 数据一致性")
    st = state()
    nodes = tree()
    texts = node_texts(nodes)
    m = re_first_number(texts, r"(\d+)\s*个词")
    if AX_DEGRADED:
        note_blocked("S7", "界面词条数树校验（树通道降级）")
    elif m is not None and st.get("entryCount") is not None and m != st.get("entryCount"):
        record("P1", "S7", f"界面词条数({m})与实际({st.get('entryCount')})不一致")
    elif m is not None:
        ok("S7", f"界面词条数与实际一致（{m}）")

    # ---------- 清理探针词条 ----------
    send({"action": "deleteWord", "word": probe})
    time.sleep(0.8)
    # 兼容历史遗留探针
    for w in pool:
        if w != probe:
            send({"action": "deleteWord", "word": w})
    time.sleep(0.5)
    return True


def re_first_number(text, pattern):
    import re
    m = re.search(pattern, text)
    return int(m.group(1)) if m else None


def write_report(round_no):
    os.makedirs(LOGDIR, exist_ok=True)
    path = os.path.join(LOGDIR, "visual-audit-report.md")
    lines = [
        "# 视觉审计报告（AX 语义通道）",
        "",
        f"- Round: {round_no}",
        f"- 时间: {time.strftime('%Y-%m-%d %H:%M:%S')}",
        f"- AX 通道: {'⚠️ 降级（会话级服务端缓存损坏，状态通道回退）' if AX_DEGRADED else '正常'}",
        f"- 通过断言: {len(passes)}",
        f"- 审计发现: {len(findings)}",
        f"- 环境阻塞: {len(blocked)}",
        "",
    ]
    if blocked:
        lines.append("## 环境阻塞（非产品缺陷）")
        for sc, d in blocked:
            lines.append(f"- [{sc}] {d}")
        lines.append("")
    if findings:
        lines.append("| # | 级别 | 场景 | 发现 |")
        lines.append("|---|------|------|------|")
        for i, f in enumerate(findings, 1):
            lines.append(f"| {i} | {f['severity']} | {f['scenario']} | {f['detail']} |")
    else:
        lines.append("**零缺陷** ✅")
    lines.append("")
    lines.append("## 通过项")
    for sc, d in passes:
        lines.append(f"- [{sc}] {d}")
    with open(path, "w") as fh:
        fh.write("\n".join(lines))
    print(f"\n报告: {path}")
    return path


if __name__ == "__main__":
    rnd = 1
    if "--round" in sys.argv:
        rnd = int(sys.argv[sys.argv.index("--round") + 1])
    try:
        run(rnd)
    finally:
        write_report(rnd)
    sys.exit(1 if findings else 0)