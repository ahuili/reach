# 把各个界面状态截成图（真实的手边界面，测试模式 + 演示数据）
import rc, sys, time, os
S = sys.argv[1]; OUT = sys.argv[2]; os.makedirs(OUT, exist_ok=True)
reset = {"query": "", "tab": "recent", "options": False, "edit": False, "basket": [], "folders": False, "target": "com.apple.Terminal", "targetName": "终端"}
def ui(**kw): return rc.call(S, {"cmd": "debug.ui", **kw})
def snap(name, *steps):
    ui(**reset); time.sleep(0.25)
    for st in steps: ui(**st); time.sleep(0.35)
    time.sleep(0.5)
    print(name, rc.call(S, {"cmd": "debug.snapshot", "path": f"{OUT}/{name}.png"}))
for i in range(5): snap(f"recent-{i}", {"selectIndex": i})
snap("recent-img-opts", {"selectIndex": 0}, {"options": True})
snap("pick-1", {"basket": []}, {"pick": 1})
snap("pick-2", {"pick": 2})
snap("pick-3", {"pick": 3})
snap("kept-0", {"tab": "kept"}, {"selectIndex": 0})
for i in range(1, 4): snap(f"kept-{i}", {"tab": "kept"}, {"selectIndex": i})
snap("search", {"tab": "kept", "query": "后台"}, {"selectIndex": 0})
snap("search-opts", {"tab": "kept", "query": "后台"}, {"selectIndex": 0}, {"options": True})
snap("folders", {"tab": "kept"}, {"folders": True})
snap("new", {"tab": "kept"}, {"new": True})
