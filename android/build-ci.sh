#!/usr/bin/env bash
# CI 版构建脚本：跑在 GitHub Actions 的 ubuntu runner 上，用 runner 自带的 Android SDK。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/app/src/main"
OUT="$HERE/build"

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}"
BT="$(ls -d "$SDK"/build-tools/* 2>/dev/null | sort -V | tail -1)"
PLATFORM="$SDK/platforms/android-34"

if [ -z "${BT:-}" ] || [ ! -e "$PLATFORM/android.jar" ]; then
  echo "SDK 不完整，尝试用 sdkmanager 安装…"
  yes | "$SDK/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$SDK" --licenses >/dev/null 2>&1 || true
  "$SDK/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$SDK" "build-tools;34.0.0" "platforms;android-34" >/dev/null
  BT="$(ls -d "$SDK"/build-tools/* | sort -V | tail -1)"
  PLATFORM="$SDK/platforms/android-34"
fi

AJAR="$PLATFORM/android.jar"
AAPT2="$BT/aapt2"
ZIPALIGN="$BT/zipalign"
APKSIGNER="$BT/apksigner"
KS="$HERE/ci.jks"

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
javac -source 8 -target 8 -encoding UTF-8 -bootclasspath "$AJAR" \
  -d "$OUT/classes" @"$OUT/sources.txt"

echo '[4/6] 转成 dex'
find "$OUT/classes" -name '*.class' > "$OUT/classlist.txt"
"$BT/d8" --lib "$AJAR" --min-api 24 --output "$OUT/dex" @"$OUT/classlist.txt" >/dev/null

echo '[5/6] 打包 + 对齐'
cp "$OUT/base-unsigned.apk" "$OUT/app.apk"
( cd "$OUT/dex" && zip -q -X "$OUT/app.apk" classes.dex )
"$ZIPALIGN" -f 4 "$OUT/app.apk" "$OUT/app-aligned.apk"

echo '[6/6] 签名'
if [ ! -e "$KS" ]; then
  keytool -genkeypair -keystore "$KS" -storepass wechataway -keypass wechataway \
    -alias wechataway -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=WeChat Away, OU=DSH, O=YveYin, C=CN" >/dev/null 2>&1
fi
"$APKSIGNER" sign --ks "$KS" --ks-pass pass:wechataway --key-pass pass:wechataway \
  --ks-key-alias wechataway --out "$OUT/wechat-away.apk" "$OUT/app-aligned.apk"

"$APKSIGNER" verify "$OUT/wechat-away.apk" >/dev/null && echo '签名校验通过'
ls -lh "$OUT/wechat-away.apk"
