# 介绍视频

`assets/Reach-intro.mp4` 和 README 里的 `assets/demo.gif` 都由这里生成。

- 侧栏画面是**真实的手边界面**：测试模式启动（数据在临时目录，不碰真实的库、剪贴板和快捷键），灌入 `src/seed.py` 里的虚构演示数据，再用 `src/snaps.py` 把各个状态截下来。
- 桌面、终端、聊天窗口是示意，不含任何真实屏幕内容。
- `index.html` 把画面写成时间的函数，`render.mjs` 用本机 Chrome 逐帧截图，ffmpeg 合成。

```bash
swift build                                   # 在仓库根目录
REACH_HOME=/tmp/reach-promo REACH_KEYFILE=1 .build/debug/Reach &
SOCK=$(ls -t /tmp/reach-501-*.sock | head -1)  # 测试模式的连接口（路径太长时落在 /tmp）
cd promo
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --force-device-scale-factor=2 \
  --window-size=880,560 --hide-scrollbars --screenshot=$PWD/shots/error-shot.png file://$PWD/src/shot.html
python3 src/seed.py $SOCK $PWD/shots/error-shot.png
python3 src/snaps.py $SOCK $PWD/shots          # 审批卡片那张（shots/approve.png）要先发一个 env.write 请求再截
node render.mjs --stills 6.8,20.8,50.6         # 先看静帧
node render.mjs                                # → dist/Reach-介绍.mp4、assets/demo.gif
```
