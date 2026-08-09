#!/bin/bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

required_variables=(
    ANDROID_HOME
    SCRIBE_ANDROID_KEYSTORE_PATH
    SCRIBE_ANDROID_KEYSTORE_PASSWORD
    SCRIBE_ANDROID_KEY_ALIAS
    SCRIBE_ANDROID_KEY_PASSWORD
)
missing_variables=()
for variable_name in "${required_variables[@]}"; do
    [[ -n "${!variable_name:-}" ]] || missing_variables+=("$variable_name")
done

if (( ${#missing_variables[@]} > 0 )); then
    echo "Android release signing is not configured. Missing: ${missing_variables[*]}" >&2
    exit 2
fi

case "$SCRIBE_ANDROID_KEYSTORE_PATH" in
    /*) ;;
    *)
        echo "SCRIBE_ANDROID_KEYSTORE_PATH must be an absolute path." >&2
        exit 2
        ;;
esac

[[ -f "$SCRIBE_ANDROID_KEYSTORE_PATH" ]] || {
    echo "Android release keystore does not exist: $SCRIBE_ANDROID_KEYSTORE_PATH" >&2
    exit 2
}

AAPT="$ANDROID_HOME/build-tools/36.0.0/aapt"
APKSIGNER="$ANDROID_HOME/build-tools/36.0.0/apksigner"
[[ -x "$AAPT" && -x "$APKSIGNER" ]] || {
    echo "Android SDK Build Tools 36.0.0 are required under ANDROID_HOME." >&2
    exit 2
}

./gradlew :androidApp:assembleRelease :androidApp:bundleRelease

APK="$ROOT/androidApp/build/outputs/apk/release/androidApp-release.apk"
AAB="$ROOT/androidApp/build/outputs/bundle/release/androidApp-release.aab"
[[ -f "$APK" && -f "$AAB" ]] || {
    echo "Gradle did not produce both release artifacts." >&2
    exit 1
}

apk_certificate=$(
    "$APKSIGNER" verify --print-certs "$APK" |
        awk -F': ' '/Signer #1 certificate SHA-256 digest/ { print tolower($2); exit }'
)
aab_certificate=$(
    keytool -printcert -jarfile "$AAB" |
        awk -F': ' '/SHA256:/ { value = tolower($2); gsub(":", "", value); print value; exit }'
)
keystore_certificate=$(
    keytool -list -v \
        -keystore "$SCRIBE_ANDROID_KEYSTORE_PATH" \
        -storepass:env SCRIBE_ANDROID_KEYSTORE_PASSWORD \
        -keypass:env SCRIBE_ANDROID_KEY_PASSWORD \
        -alias "$SCRIBE_ANDROID_KEY_ALIAS" |
        awk -F': ' '/SHA256:/ { value = tolower($2); gsub(":", "", value); print value; exit }'
)

[[ -n "$apk_certificate" && "$apk_certificate" == "$keystore_certificate" ]] || {
    echo "The release APK is not signed by the configured upload key." >&2
    exit 1
}
[[ -n "$aab_certificate" && "$aab_certificate" == "$keystore_certificate" ]] || {
    echo "The release AAB is not signed by the configured upload key." >&2
    exit 1
}

certificate_dn=$("$APKSIGNER" verify --print-certs "$APK" | awk -F': ' '/Signer #1 certificate DN/ { print $2; exit }')
case "$certificate_dn" in
    *"CN=Android Debug"*)
        echo "Refusing an Android release signed by the debug certificate." >&2
        exit 1
        ;;
esac

permissions=$($AAPT dump permissions "$APK")
if [[ "$permissions" == *"android.permission.INTERNET"* ]]; then
    echo "Refusing an Android release that requests INTERNET permission." >&2
    exit 1
fi

jarsigner -verify "$AAB" >/dev/null
package_line=$($AAPT dump badging "$APK" | awk '/^package:/ { print; exit }')

echo "Verified production-style Android release artifacts."
echo "$package_line"
echo "Signer: $certificate_dn"
echo "Signer SHA-256: $keystore_certificate"
shasum -a 256 "$APK" "$AAB"
