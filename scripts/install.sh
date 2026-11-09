#!/bin/zsh
# Builds Kvačica from source and installs it to /Applications (or ~/Applications).
#
#   ./scripts/install.sh               # build, install, open
#   ./scripts/install.sh --signed      # sign with your "Apple Development" certificate: adds the widgets
#   ./scripts/install.sh --no-open     # install, don't open
#   ./scripts/install.sh --build-only  # build and sign into build/, don't install
#   ./scripts/install.sh --mcp         # also install the MCP server for Claude Desktop (scripts/install-mcp.sh)
#
# Needs Xcode 26 or later and XcodeGen (installed with Homebrew if missing). No Apple developer
# account is needed: by default the app is signed to run locally (ad-hoc). Widgets need an app
# group, which macOS only grants to apps signed by a team, so they come with --signed (a free
# Apple ID added in Xcode → Settings → Accounts gives you such a certificate).
set -euo pipefail
cd "$(dirname "$0")/.."

SIGNED=false; OPEN=true; INSTALL=true; MCP=false
for arg in "$@"; do
  case $arg in
    --signed) SIGNED=true ;;
    --no-open) OPEN=false ;;
    --build-only) INSTALL=false; OPEN=false ;;
    --mcp) MCP=true ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option $arg (see --help)" >&2; exit 1 ;;
  esac
done

step() { print -P "%B==> $1%b"; }
fail() { print -u2 "error: $1"; exit 1; }

# --- Requirements -------------------------------------------------------------------------
[[ $(uname) == Darwin ]] || fail "Kvačica is a macOS app."
macos=$(sw_vers -productVersion)
(( ${macos%%.*} >= 14 )) || fail "macOS 14 Sonoma or later is needed to run Kvačica (this Mac has $macos)."

if ! xcodebuild -version >/dev/null 2>&1; then
  fail "Xcode is not set up. Install Xcode 26 or later from the App Store, open it once, then run:
  sudo xcode-select -s /Applications/Xcode.app"
fi
xcode=$(xcodebuild -version | awk 'NR==1 {print $2}')
(( ${xcode%%.*} >= 26 )) || fail "Xcode 26 or later is needed (found $xcode)."

if ! command -v xcodegen >/dev/null; then
  command -v brew >/dev/null || fail "XcodeGen is missing. Install Homebrew (https://brew.sh), then: brew install xcodegen"
  step "Installing XcodeGen with Homebrew"
  brew install xcodegen
fi

IDENTITY=""; TEAM=""
if $SIGNED; then
  IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/"Apple Development: / {print $2; exit}')
  [[ -n $IDENTITY ]] || fail "No \"Apple Development\" certificate in the keychain. Add your Apple ID in
  Xcode → Settings → Accounts, select it, Manage Certificates… → + → Apple Development. Or drop --signed."
  # The team is the certificate's OU, not the id in brackets in its name.
  TEAM=$(security find-certificate -c "$IDENTITY" -p | openssl x509 -noout -subject -nameopt multiline \
    | awk -F' = ' '/organizationalUnitName/ {print $2; exit}')
  [[ -n $TEAM ]] || fail "Couldn't read the team of \"$IDENTITY\"."
fi

# --- Build --------------------------------------------------------------------------------
step "Generating the Xcode project"
xcodegen generate --quiet

step "Building (the first build fetches swift-fsrs and takes a few minutes)"
xcodebuild -project Srpski.xcodeproj -scheme Srpski -configuration Release \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build -quiet

# č spelled c + combining caron (NFD), the way file URLs spell it: with č as one character the
# widget never reaches the gallery (chronod looks it up by its file URL).
NAME="Kvac$(printf '\xcc\x8c')ica.app"
STAGED="build/$NAME"
rm -rf "$STAGED"
cp -R build/DerivedData/Build/Products/Release/Srpski.app "$STAGED"
WIDGET="$STAGED/Contents/PlugIns/SrpskiWidget.appex"

step "Signing"
APP_ENTITLEMENTS=build/app.entitlements
WIDGET_ENTITLEMENTS=build/widget.entitlements
cp App/Srpski.entitlements "$APP_ENTITLEMENTS"
cp Widget/SrpskiWidget.entitlements "$WIDGET_ENTITLEMENTS"
if $SIGNED; then
  GROUP="$TEAM.com.georgiiegoshin.srpski"
  for file in "$APP_ENTITLEMENTS" "$WIDGET_ENTITLEMENTS"; do
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.application-groups array" \
      -c "Add :com.apple.security.application-groups:0 string $GROUP" "$file"
  done
  for plist in "$STAGED/Contents/Info.plist" "$WIDGET/Contents/Info.plist"; do
    /usr/libexec/PlistBuddy -c "Delete :SrpskiAppGroup" "$plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :SrpskiAppGroup string $GROUP" "$plist"
  done
  codesign --force --sign "$IDENTITY" --entitlements "$WIDGET_ENTITLEMENTS" "$WIDGET"
  codesign --force --sign "$IDENTITY" --entitlements "$APP_ENTITLEMENTS" "$STAGED"
else
  # No team, no app group: the widgets would have nothing to show, so they're left out.
  rm -rf "$WIDGET"
  codesign --force --sign - --entitlements "$APP_ENTITLEMENTS" "$STAGED"
fi
codesign --verify --deep --strict "$STAGED"

if ! $INSTALL; then
  echo "Built $PWD/$STAGED"
  exit 0
fi

# --- Install ------------------------------------------------------------------------------
DIR=/Applications
[[ -w $DIR ]] || { DIR="$HOME/Applications"; mkdir -p "$DIR"; }
APP="$DIR/$NAME"
step "Installing to $APP"
# The executable inside the bundle is named Srpski.
pkill -x Srpski 2>/dev/null && sleep 0.5 || true
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[[ -d $APP ]] && "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
rm -rf "$APP"
cp -R "$STAGED" "$APP"
"$LSREGISTER" -f "$APP"
if $SIGNED; then
  pluginkit -a "$APP/Contents/PlugIns/SrpskiWidget.appex" >/dev/null 2>&1 || true
  pluginkit -e use -i com.georgiiegoshin.srpski.widgets >/dev/null 2>&1 || true
fi

$MCP && ./scripts/install-mcp.sh

echo "Installed $APP"
$OPEN && open "$APP" || true
