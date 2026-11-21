# 介绍视频用：造一个和 Paste 同样结构的库（Core Data SQLite），内容全是虚构的，用来演示「从 Paste 搬家」
import sqlite3, plistlib, sys, datetime
db = sqlite3.connect(sys.argv[1])
db.executescript("""
CREATE TABLE ZAPPLICATIONENTITY(Z_PK INTEGER PRIMARY KEY, ZNAME VARCHAR, ZBUNDLEIDENTIFIER VARCHAR);
CREATE TABLE ZLISTENTITY(Z_PK INTEGER PRIMARY KEY, ZNAME VARCHAR, ZRAWTYPE INTEGER);
CREATE TABLE ZITEMDATAENTITY(Z_PK INTEGER PRIMARY KEY, ZRAWPASTEBOARDITEMS BLOB);
CREATE TABLE ZITEMENTITY(Z_PK INTEGER PRIMARY KEY, ZDATA INTEGER, ZSOURCEAPPLICATION INTEGER, ZLIST INTEGER, ZTITLE VARCHAR, ZCREATEDAT TIMESTAMP, ZTIMESTAMP TIMESTAMP);
""")
apps = [("Safari", "com.apple.Safari"), ("微信", "com.tencent.xinWeChat"), ("Terminal", "com.apple.Terminal"), ("Notion", "notion.id"), ("飞书", "com.bytedance.lark")]
db.executemany("INSERT INTO ZAPPLICATIONENTITY VALUES(?,?,?)", [(i + 1, n, b) for i, (n, b) in enumerate(apps)])
db.execute("INSERT INTO ZLISTENTITY VALUES(1, '常用回复', 2)")
# Core Data 的时间是从 2001-01-01 UTC 起的秒数；这里的时刻按本机时区理解
def ts(d, h, m): return datetime.datetime(2026, 11, d, h, m).astimezone().timestamp() - 978307200
items = [
 (18, 10, 5, 1, None, "https://developer.apple.com/documentation/appkit/nspasteboard"),
 (18, 10, 7, 4, None, "## 发布清单\n- 打 tag\n- 更新 brew\n- 写更新说明"),
 (18, 15, 40, 2, None, "明天上午 10 点评审，会议室 4B"),
 (19, 9, 12, 3, None, "git log --oneline -20"),
 (19, 9, 15, 3, None, "brew upgrade --cask reach"),
 (19, 14, 2, 5, None, "设计稿链接：https://figma.example.com/file/demo"),
 (20, 11, 30, 1, None, "https://news.ycombinator.com/item?id=4242"),
 (20, 11, 33, 2, None, "好的，收到，我今天下班前给你"),
 (20, 16, 8, 3, None, "pnpm test --filter web"),
 (20, 16, 20, 4, None, "Q4 目标：活跃用户 +20%，留存 +5%"),
 (20, 17, 1, 2, 1, "收到，我看一下马上回复你"),
 (20, 17, 2, 2, 1, "辛苦了，周末愉快！"),
]
for i, (d, h, m, app, lst, text) in enumerate(items, 1):
    blob = b"\x01" + plistlib.dumps([{"types": ["public.utf8-plain-text"], "dataByType": {"public.utf8-plain-text": text.encode()}}], fmt=plistlib.FMT_BINARY)
    db.execute("INSERT INTO ZITEMDATAENTITY VALUES(?,?)", (i, blob))
    db.execute("INSERT INTO ZITEMENTITY VALUES(?,?,?,?,?,?,?)", (i, i, app, lst, None, ts(d, h, m), ts(d, h, m)))
db.commit()
print(len(items))
