<p align="center">
  <img src="assets/icon-1024.png" width="128" alt="手边 Reach">
</p>

<h1 align="center">手边 Reach</h1>

<p align="center">
  <b>复制过的、留着备用的、账号密钥，都贴在屏幕边上，伸手就拿。</b><br>
  macOS 侧栏：剪贴板历史 + 随手笔记 + 本机加密的密钥库，看着目标窗口贴；命令行 Agent 也能来查（要你点头）。
</p>

<p align="center">
  <a href="https://github.com/ahuili/reach/releases/latest"><img src="https://img.shields.io/github/v/release/ahuili/reach?label=%E4%B8%8B%E8%BD%BD&color=f2b83d" alt="release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Apple%20%E8%8A%AF%E7%89%87%20%2B%20Intel-%E9%80%9A%E7%94%A8-555" alt="universal">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="MIT"></a>
</p>

<p align="center">
  <img src="assets/demo.gif" width="860" alt="手边 Reach 演示">
  <br>
  <a href="https://github.com/ahuili/reach/raw/main/assets/Reach-intro.mp4">▶ 看完整介绍视频（1 分钟）</a>
</p>

<p align="center">
  <img src="assets/screens.png" width="860" alt="最近复制、抽屉、只贴一部分">
</p>

---

## 它解决什么

- **剪贴板管理器只管"复制过什么"**，笔记 App 只管"留着什么"，账号密码又在第三个地方。要用的时候得想"它在哪"。手边把三样放在同一条侧栏里，一个搜索框搜全部。
- **从 AI 那里复制的东西带着 `**` `##`**，贴进微信一团乱；贴进终端多了个 `$`。手边贴之前先看你要贴给谁，自动换成合适的样子。
- **截图贴不进终端里的 Claude Code、Codex**。手边把截图存成文件、贴路径，Agent 直接能读。
- **截图里带着 Key、密码就发出去了**。手边截完先认字，密钥所在的位置自动打码。
- **看不懂的外文、报错，要另装翻译软件、再开一个 AI 窗口**。手边截完按 `Y` 原位翻译，按 `K` 让 AI 说清图里是什么，还能接着问。
- **Agent 要 API Key 时你只能把密钥贴进对话**。手边让它来申请，你在侧栏点一下，值直接写进项目的 `.env`，不经过对话。

## 功能

**最近复制**
- 自动记下复制的文字、链接、图片、文件，默认留 30 天；按天分段，连着复制的几样自动收成一组。
- 自动认出命令、报错、链接、账号、密钥等类型；截图自动识别文字，可以搜。
- 贴过三次以上的进"常用"，不会过期。

**抽屉**
- 任意一条按 `⌘S` 放进抽屉：存成新的一条，或接到抽屉里已有的一条后面；多选的几条也能一起放（合成一条或各放一条）。`⌘N` 直接写一条，`⌘E` 编辑。按文件夹放，顶上一排文件夹标签点一下就筛；点最右边的 `⋯` 新建、改名、排序、删除文件夹（删文件夹不删里面的内容）。
- 一键从 SideNotes 搬家（原件不动，重复搬不会多出一份）。
- 抽屉里写 `{内容}`、`{正式/随意}` 这样的空位，贴的时候先填。

**贴**
- `↩` 贴进你刚才在用的窗口，按目标调整格式：微信、企业微信等聊天窗口去掉 Markdown 记号；邮件、Word 带上标题、加粗、表格；终端去掉行首 `$`，截图变成文件路径。
- `→` 只贴一部分：只贴网址 / 账号 / 密码，纯文本，只贴代码块，合成一行，JSON 排整齐……`⌥↩` 一次填好登录框（账号 ⇥ 密码）。
- **多选**：鼠标移到卡片左边的小方块点一下，或选中后按空格；`⇧` 点击连选，`⌘A` 全选。选好按 `⌘↩` 合成一段贴出去，每段带出处。

**截图**（`⌃⌥A`，可在设置里换；或侧栏底部的取景框按钮）
- 冻住屏幕再框选，点一下选整个窗口，回车截整块屏；框完拖边角能改大小，在选区外重新拖就重新框。直接在选区上标注：框、箭头、画笔、文字、序号、打码、荧光笔（按 `R` `A` `P` `T` `N` `M` `H` 切换）。
- **密钥自动打码**：截完先在本机认字，Key、密码、Token、带密码的连接串所在的位置直接打上马赛克，工具栏显示"已遮住 N 处"，点一下可以取消。
- **图里的东西一键拿走**：认出的报错、命令、网址、邮箱、电话列成一排，点一下复制那段字（带密钥的不给），还有"复制全部文字"。
- `↩` 复制；`⌘↩` **贴回截图前的窗口**（终端里贴图片文件路径，Agent 能读；聊天窗口里贴图）；空格**放进篮子**，接着截下一张，最后一张 `⌘↩` 连同篮子一起贴；📌 **钉在屏幕上**对着看（滚轮缩放，双击关）。
- **原位翻译**（`Y`）：图里认出的每一行，用原来的底色盖上译文，像换了一张中文截图；外文译成中文，中文译成英文。复制、贴回、钉住的都是译好的图，再按一次 `Y` 看原文。
- **看懂**（`K`）：选区旁边出一张卡片，按图里是什么来回答——外文给通顺译文和难词解释，报错给原因和下一步命令（代码块一键复制），代码说在干什么，图表说结论，界面说能做什么。下面能**接着问**（"第二句什么意思""这个按钮在哪"），回答能复制或连同图里的字放进抽屉。
- 翻译和看懂要在 设置 › AI 里配一个模型（装了 Magpie 可以直接选）。发出去的是认出的字，密钥先抹掉；选了"能看图"的模型才发图，而且只发打过码的图，没遮住的密钥在就不发。
- 截图进复制历史，按图里的字能搜；历史里的图片按 `→` 还能"标注一下""钉在屏幕上"。
- 需要「屏幕录制」权限（系统设置 › 隐私与安全性 › 屏幕与系统录音）。

**链接分流**（设置 › 链接分流，默认关）
- 点了 Slack、微信、邮件里的链接，自动开到对的浏览器、对的账号、对的窗口：Claude 用个人账号、X 用另一个账号、公司文档进公司账号。
- **窗口组**：在 Chrome 的「窗口 › 命名窗口」里给窗口起名，名字第一个词就是组名（「公司」「公司 客户A」都算「公司」组），链接去组里最近用的那个窗口。
- 不用先写规则：链接是某个账号的公司域名，或者这个网站一直只在某个账号里开，就直接开过去；拿不准时在鼠标旁边弹一个小面板，按数字键选。同一个网站连续两次选了同一个地方，以后就不再问。
- 开完右上角提示「已开在 … 换 / 记住」，开错了点「换」，刚才那个标签自动关掉，并记住新的选择。
- 按住 `⌥` 点链接一定会问；同一个网址已经开着就切过去；Slack、Google、Outlook、知乎的跳转链接按里面的真实网址判断。
- **点过的链接能搜到**：搜网页标题或网址，结果里有「点过的链接」一栏，显示从哪来、开到了哪；回车按原来的去处再开。留 30 天，网址里的 token、key 先擦掉，设置里能关。
- 打开时手边成为默认浏览器（系统会问一次），关掉时还给原来那个；菜单里可以临时暂停。浏览历史只在本机数每个网站的访问次数，不读页面、不存。Safari 分不到个人资料这一层。

**密钥**
- 密码、Key、Token 在本机用规则识别，不经过任何模型；显示时打码，`⌘R` 临时显示；一条里有好几个时，按上下文起名字（「OpenAI」API Key、「生产」密码），`→` 里分得清，`⌘C` 只复制其中一个；认错了右键"这不是密钥"。
- 整个库逐行加密（AES-GCM）。数据库密钥放在数据目录的 `db.key`，只有你的账号能读：单独拷走数据库文件读不出内容。（不放钥匙串，是因为自签名的 App 每次升级都会让钥匙串再要一次密码；旧版放在钥匙串里的密钥第一次启动时自动搬过来。）
- 复制到的单独密钥 1 小时后从历史清除，夹着密钥的一段文字留一天；贴出去的密钥 30 秒后从剪贴板清除。
- 要把密钥贴进聊天窗口或 AI 对话框时先拦一下，再按一次回车才贴。

**Agent 来查你的库**（命令行 `reach`，或 MCP）

```bash
reach search staging                 # 搜，密钥打码
reach read <id>                      # 读全文，密钥位置是占位
reach recent 5                       # 最近复制的
reach env match DASHSCOPE_API_KEY JINA_API_KEY --project .
reach env write DASHSCOPE_API_KEY JINA_API_KEY --project .   # 你批准后，值直接写进 .env
reach run --env DB_PASS="staging 数据库" -- make migrate      # 你批准后，带着密钥跑一条命令
echo "新账号…" | reach save --title "测试库只读账号" --folder "公司 A"
reach import sidenotes               # 把 SideNotes 的笔记搬进抽屉
reach status                         # 数量和各项开关（不含内容）
```

凡是会交出密钥、写文件、往库里存东西的，都会在侧栏弹一张卡片等你点。菜单栏图标里可以安装命令行、复制一段给 Agent 的使用说明（贴进 AGENTS.md 就能用，不依赖 MCP）。想用 MCP 的，自己注册一下（Reach.app 装在别处的换成对应路径）：

```bash
claude mcp add --scope user reach -- /Applications/Reach.app/Contents/MacOS/reachctl mcp    # Claude Code
codex mcp add reach -- /Applications/Reach.app/Contents/MacOS/reachctl mcp                  # Codex
```

**AI（可选）**：设置里填一个 OpenAI 兼容的接口（Ollama 本机模型也行）；装了 Magpie 的话直接从它的模型列表里选，不用填地址和 Key，能看图的模型会标出来。用来截图翻译和看懂、给一组复制起名、放进抽屉时自动归文件夹、翻译和精简。发出去之前先在本机把密钥抹掉。不配不影响其他功能。

## 安装

需要 macOS 14 (Sonoma) 或更新，Apple 芯片和 Intel 都支持。

### 方式一：Homebrew（推荐）

```bash
brew install --cask ahuili/tap/reach
```

会顺带把命令行 `reach` 装进 PATH。以后升级：点菜单栏图标 › 检查更新（下载后核对校验和与签名，自动重新打开），或者 `brew upgrade --cask reach`

### 方式二：一行脚本

```bash
curl -fsSL https://raw.githubusercontent.com/ahuili/reach/main/scripts/install.sh | bash
```

### 方式三：手动下载

在 [Releases](https://github.com/ahuili/reach/releases/latest) 下载 `Reach-版本号.dmg`，拖进「应用程序」。还没有 Apple 公证，第一次打开如果被拦，在终端运行：

```bash
xattr -dr com.apple.quarantine /Applications/Reach.app
```

### 方式四：从源码构建

```bash
git clone https://github.com/ahuili/reach.git && cd reach
scripts/make-cert.sh                      # 建一张本机签名证书（只需一次）
SIGN_IDENTITY="Reach Local Signing" scripts/build-app.sh --install
```

不建证书也能构建，但会用临时签名：每次重新构建后系统都会再问一次辅助功能和屏幕录制。离线自测：`swift build --product ReachSelfTest && .build/debug/ReachSelfTest`。

## 第一次打开

1. 菜单栏出现一个侧栏图标；屏幕右边缘有一个小把手。按 `⇧⌘V`（被占用时 `⌃⌥V`）、鼠标滑到把手上、或甩到屏幕右边缘，侧栏就出来了。快捷键在 设置 › 快捷键 里可以换成自己的。
2. **允许自动粘贴**：系统设置 › 隐私与安全性 › 辅助功能，打开「手边」。没打开时回车只把内容放上剪贴板，要自己按 `⌘V`。
3. **截图**：第一次按 `⌃⌥A` 时手边会带你去 系统设置 › 隐私与安全性 › 屏幕与系统录音，打开「手边」（列表里没有就点「+」选 Reach.app），然后点「重启手边」。
4. 默认开机自动打开，菜单里可以关。
5. 从 0.2 及更早的版本升级：第一次启动系统会最后问一次钥匙串（把旧密钥搬到数据目录），之后不再问。

## 键盘

| 键 | 作用 |
|---|---|
| 直接打字 | 搜索（最近复制和抽屉一起搜） |
| `↑` `↓` | 选 |
| `↩` | 整条贴进刚才的窗口 |
| `⇧↩` | 原样纯文本 |
| `→` | 只贴一部分（网址、账号、密码…） |
| `⌥↩` | 填登录：账号 → Tab → 密码 |
| `Tab` / `⌘1` `⌘2` | 最近复制 ⇄ 抽屉 |
| 空格 / `⌘A` | 多选 / 全选，`⌘↩` 合成一段贴 |
| `⌘S` `⌘N` `⌘E` `⌘⌫` | 放进抽屉 / 新建 / 编辑 / 删除 |
| `⌘R` `⌘C` | 显示密钥 / 只复制不贴 |
| `⌃⌥A` | 截图（截图时 `↩` 复制，`⌘↩` 贴回，`Y` 原位翻译，`K` 看懂，空格放进篮子，`⌘Z` 撤销，Esc 重新框选） |
| `Esc` | 一层层退出 |

## 隐私

- 所有数据只在本机，`~/Library/Application Support/Reach/`，逐行加密。
- 不联网，除非你在设置里配了 AI 接口；发给 AI 的内容先在本机抹掉密钥。
- 密码管理器（1Password 等）标记为"不要记录"的复制，手边不记。
- 截图贴进终端时会在 `~/Library/Caches/Reach/shots/` 存一份临时 PNG（只有你能读，一天后删）。

## 边界和已知问题

- **密钥交给 Agent 之后它就读得到。** 写进 `.env` 的值、`reach run` 注入的环境变量，Agent 都有办法读出来。手边管的是：没你允许拿不到、给了谁有记录可查的入口、默认不出现在对话文字里。
- **"普通 ⌘V 也按目标窗口调整格式"默认关**：它会在你切到聊天窗口时改写剪贴板。从手边里贴不受影响。
- 还没有 iCloud 同步、手机端，没有 Apple 公证。

## 结构

```
Sources/ReachCore     加密存储、密钥识别、内容分类、Markdown 转换、配置匹配、截图翻译与看懂的提示词、Magpie 接入、进程间通信、SideNotes 导入
Sources/Reach         App：剪贴板监听、粘贴、侧栏界面、屏幕边把手、截图与标注（Shot*.swift）、批准流程、自动整理、设置
Sources/reachctl      命令行和 MCP 服务（打包在 Reach.app/Contents/MacOS/reachctl，装到 PATH 时叫 reach）
Sources/ReachSelfTest 自测（CommandLineTools 没有 XCTest）
promo/                介绍视频：真实的侧栏截图（测试模式 + 演示数据）+ 示意桌面，逐帧渲染
scripts/              build-app.sh 构建，release.sh 打包发布，install.sh 一行安装，make-cert.sh 建签名证书，make-icon.swift 画图标
```

测试时设 `REACH_HOME=<目录> REACH_KEYFILE=1` 可以让它用临时目录和文件密钥，不碰真实数据、剪贴板和快捷键。

原名「页边 Margin」，从旧版升级会自动把数据搬过来。

## 许可

MIT
