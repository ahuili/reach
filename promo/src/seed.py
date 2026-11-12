# 演示数据：全部是虚构的，不含任何真实账号
import rc, sys, time
S = sys.argv[1]; P = sys.argv[2]
clips = [
 ("上海市徐汇区漕溪北路 88 号 3 楼", "微信", "com.tencent.xinWeChat"),
 ("#F5B333", "Figma", "com.figma.Desktop"),
 ("postgres://app:Xk29fLq7pW@db.internal:5432/orders", "Terminal", "com.apple.Terminal"),
 ("## 本周进展\n- **订单页**改版上线\n- 修了 3 个支付回调的问题\n- 下周：接入新的发票接口", "Claude", "com.anthropic.claudefordesktop"),
 ("https://github.com/vercel/next.js/discussions/48110", "Google Chrome", "com.google.Chrome"),
 ("周五前把首页改版的稿子发我，顺便把埋点文档带上", "微信", "com.tencent.xinWeChat"),
 ("npm run dev -- --port 3001", "Terminal", "com.apple.Terminal"),
]
for t, a, b in clips:
    print(rc.call(S, {"cmd": "debug.ingest", "text": t, "app": a, "bundle": b})); time.sleep(0.05)
print(rc.call(S, {"cmd": "debug.ingest", "text": "", "app": "截屏", "bundle": "com.apple.screencaptureui", "image": P}))
kept = [
 ("后台 https://admin.example.com\n账号 ops@example.com\n密码 Wq8#kLm2zP", "公司 A 运营后台", "公司 A", 6),
 ("ssh deploy@10.0.3.21 -p 2222", "staging 跳板机", "公司 A", 3),
 ("OPENAI_API_KEY=sk-proj-" + "aB3dE6fG9h" * 4, "OpenAI Key", "密钥", 5),
 ("DASHSCOPE_API_KEY=sk-" + "a8f3k2m9x7" * 3, "百炼 API Key", "密钥", 2),
 ("您好，关于{事项}，我这边{结论}。有问题随时找我。", "回复客户模板", "常用话术", 9),
 ("名称：示例科技有限公司\n税号：91310000MA1EXAMPLE\n开户行：示例银行上海分行", "发票抬头", "常用话术", 4),
 ("本周完成：\n- \n下周计划：\n- \n需要协助：", "周报模板", "常用话术", 1),
]
for text, title, folder, uses in kept:
    print(rc.call(S, {"cmd": "debug.kept", "text": text, "title": title, "folder": folder, "uses": uses}))
