#!/bin/zsh
# 建一张本机自用的代码签名证书（自签名，只在你这台 Mac 上有效），放进登录钥匙串。
# 有了它，scripts/build-app.sh 签出来的身份就固定了：重新构建后钥匙串和辅助功能的授权不会失效。
# 用法：scripts/make-cert.sh ["证书名"]   默认名「Reach Local Signing」，建好后把 scripts/repo.env 里的 SIGN_IDENTITY 改成它
set -euo pipefail
NAME="${1:-Reach Local Signing}"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then echo "已经有「$NAME」了"; exit 0; fi
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cat > $tmp/cfg <<CFG
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CFG
openssl req -x509 -newkey rsa:2048 -nodes -keyout $tmp/key.pem -out $tmp/cert.pem -days 3650 -config $tmp/cfg -extensions ext 2>/dev/null
pass=$(openssl rand -hex 12)
openssl pkcs12 -export -inkey $tmp/key.pem -in $tmp/cert.pem -name "$NAME" -out $tmp/id.p12 -passout pass:$pass -legacy 2>/dev/null \
  || openssl pkcs12 -export -inkey $tmp/key.pem -in $tmp/cert.pem -name "$NAME" -out $tmp/id.p12 -passout pass:$pass
security import $tmp/id.p12 -k ~/Library/Keychains/login.keychain-db -P $pass -T /usr/bin/codesign
echo "✓ 已建好「$NAME」。把 scripts/repo.env 里的 SIGN_IDENTITY 改成它（或运行时 SIGN_IDENTITY=\"$NAME\" scripts/build-app.sh）"
