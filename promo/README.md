# 介绍视频

`assets/Reach-intro.mp4`（带旁白）和 README 里的 `assets/demo.gif` 都由这里生成。

- 侧栏、长按 ⌘V 的候选条、截图翻译和「看懂」卡片、从 Paste 搬家后的侧栏，都是**真实的手边界面**：测试模式启动（数据在临时目录，不碰真实的库、剪贴板和快捷键），灌入虚构的演示数据，再把各个状态截下来。
- 桌面、终端、聊天窗口、网页、菜单是示意，不含任何真实屏幕内容。`src/shot-ja.html` 是虚构的日文文档页，`src/fake-paste.py` 造一个和 Paste 同样结构的演示库。
- 旁白在 `vo/`：`script.tsv` 是稿子（一行一段，场景名 + 文字），用 edge-tts 的 `zh-CN-YunxiNeural` 生成 mp3。`index.html` 里的 `VO_LEN` 是每段的时长，场景长短跟着旁白走。
- `index.html` 把画面写成时间的函数，`render.mjs` 用本机 Chrome 逐帧截图，ffmpeg 合成，再把旁白按时间点混进去（响度 -16 LUFS）。

```bash
# 0. 构建（TMPDIR 带中文时 SwiftPM 会崩，换一个）
TMPDIR=/tmp/ swift build                       # 在仓库根目录

# 1. 演示数据和侧栏截图
REACH_HOME=/tmp/reach-promo REACH_KEYFILE=1 .build/debug/Reach &
SOCK=$(ls -t /tmp/reach-501-*.sock | head -1)  # 测试模式的连接口（路径太长时落在 /tmp）
cd promo
python3 src/seed.py $SOCK $PWD/shots/error-shot.png
python3 src/snaps.py $SOCK $PWD/shots
#    候选条：debug.inline（show=chat/password，index=第几个高亮，path=存图）
#    按顺序贴：再复制「李明」「138 0013 8000」和地址，debug.ui pick 1..3 → shots/seq-*.png
#    截图翻译：Chrome 把 src/shot-ja.html 截成 shots/ja-screen.png（1512×982，2 倍），
#              debug.shot fake + select → translate / explain → snap（要先在 debug.ui 里配好 AI）
#    搬家：python3 src/fake-paste.py /tmp/fake/db.sqlite，另起一个空的测试实例 debug.importPaste → shots/paste-imported.png

# 2. 旁白（改了稿子才需要；要联网）
python3 -m venv /tmp/tts && /tmp/tts/bin/pip install edge-tts
while IFS=$'\t' read -r k t; do /tmp/tts/bin/edge-tts --voice zh-CN-YunxiNeural --rate=+6% --text "$t" --write-media vo/$k.mp3; done < vo/script.tsv
for f in vo/*.mp3; do echo $f $(ffprobe -v error -show_entries format=duration -of csv=p=0 $f); done   # 时长抄进 index.html 的 VO_LEN

# 3. 渲染
node render.mjs --stills 24.5,39.2,47          # 先看静帧
node render.mjs                                # → dist/Reach-介绍.mp4、assets/Reach-intro.mp4、assets/demo.gif
```
