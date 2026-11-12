#!/usr/bin/env bash
# 不用 Gradle 的极简 APK 构建脚本。
# 依赖（都由 _toolchain 提供）：JDK 17、Android cmdline-tools（aapt2/d8/zipalign/apksigner）、platform android-34。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TC="$ROOT/_toolchain"

JDK="$TC/jdk17"
SDK="$TC/android-sdk"
BT="$SDK/build-tools/34.0.0"
PLATFORM="$SDK/platforms/android-34"
AJAR="$PLATFORM/android.jar"

JAVA="$JDK/bin/java.exe"
JAVAC="$JDK/bin/javac.exe"
KEYTOOL="$JDK/bin/keytool.exe"
AAPT2="$BT/aapt2.exe"
D8="$BT/d8.bat"
ZIPALIGN="$BT/zipalign.exe"
APKSIGNER="$BT/apksigner.bat"

APP="$HERE/app/src/main"
OUT="$HERE/build"
KS="$TC/wechataway.jks"
KSPASS="wechataway"
KSALIAS="wechataway"

for f in "$JAVA" "$AAPT2" "$AJAR"; do
  if [ ! -e "$f" ]; then echo "缺少工具：$f" >&2; exit 1; fi
done

rm -rf "$OUT"
mkdir -p "$OUT/compiled" "$OUT/gen" "$OUT/classes" "$OUT/dex"

echo '[1/6] 编译资源'
"$AAPT2" compile --dir "$APP/res" -o "$OUT/compiled/"

echo '[2/6] 链接资源'
"$AAPT2" link \
  -o "$OUT/base-unsigned.apk" \
  -I "$AJAR" \
  --manifest "$APP/AndroidManifest.xml" \
  --java "$OUT/gen" \
  --min-sdk-version 24 \
  --target-sdk-version 34 \
  --auto-add-overlay \
  "$OUT/compiled/"*.flat

echo '[3/6] 编译 Java'
find "$APP/java" "$OUT/gen" -name '*.java' > "$OUT/sources.txt"
"$JAVAC" -source 8 -target 8 -encoding UTF-8 -bootclasspath "$AJAR" \
  -d "$OUT/classes" @"$OUT/sources.txt" 2>&1 | grep -v 'bootstrap class path' || true

echo '[4/6] 转成 dex'
find "$OUT/classes" -name '*.class' > "$OUT/classlist.txt"
"$D8" --lib "$AJAR" --min-api 24 --output "$OUT/dex" @"$OUT/classlist.txt" >/dev/null

echo '[5/6] 打包 + 对齐'
cp "$OUT/base-unsigned.apk" "$OUT/app.apk"
( cd "$OUT/dex" && zip -q -X "$OUT/app.apk" classes.dex )
"$ZIPALIGN" -f 4 "$OUT/app.apk" "$OUT/app-aligned.apk"

echo '[6/6] 签名'
if [ ! -e "$KS" ]; then
  "$KEYTOOL" -genkeypair -keystore "$KS" -storepass "$KSPASS" -keypass "$KSPASS" \
    -alias "$KSALIAS" -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=WeChat Away, OU=DSH, O=YveYin, L=, ST=, C=CN" >/dev/null 2>&1
fi
"$APKSIGNER" sign --ks "$KS" --ks-pass "pass:$KSPASS" --key-pass "pass:$KSPASS" \
  --ks-key-alias "$KSALIAS" --out "$OUT/wechat-away.apk" "$OUT/app-aligned.apk"

"$APKSIGNER" verify "$OUT/wechat-away.apk" >/dev/null && echo "签名校验通过"

ls -lh "$OUT/wechat-away.apk"
echo "APK=$OUT/wechat-away.apk"
