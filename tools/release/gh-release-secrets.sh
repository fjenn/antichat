#!/bin/bash
# tools/release/gh-release-secrets.sh — THE OWNER RUNS THIS, in their own Terminal. Agents never do.
#
# One-time setup so GitHub can build, sign and notarize AntiChat (.github/workflows/release.yml):
#   1. turns GitHub Actions on for the public repository (asks first);
#   2. creates the `release` environment (asks first), limited to `v*` tags and the main branch;
#   3. stores the seven secrets of that environment: DEVID_P12_BASE64, DEVID_P12_PASSWORD, KEYCHAIN_PASSWORD,
#      NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD, SPARKLE_PRIVATE_KEY.
#
# Nothing secret is shown on screen, written to a file in the repository, or put into your shell history: what you
# type is hidden, and every value goes to `gh secret set` through a pipe. GitHub stores secrets write-only: nobody
# (you included) can read them back, only replace them. Safe to run again: each step shows what is already there and
# asks before changing it. Leave any question with Ctrl-C; nothing half-done is left behind.
#
# Usage: tools/release/gh-release-secrets.sh        (REPO=owner/name for another repository)
set -euo pipefail
set +x
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
REPO="${REPO:-$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["githubRepo"])' "$ROOT/Config/Hosting.json")}"
ENVIRONMENT=release
CERT_NAME="Developer ID Application: Finn Jennen (446XT9839S)"
TEAM_ID=446XT9839S
SECRETS="DEVID_P12_BASE64 DEVID_P12_PASSWORD KEYCHAIN_PASSWORD NOTARY_APPLE_ID NOTARY_TEAM_ID NOTARY_PASSWORD SPARKLE_PRIVATE_KEY"

[[ -t 0 && -t 1 ]] || { echo "This script asks questions: run it yourself in Terminal." >&2; exit 2; }
umask 077
work=""
cleanup() { [[ -z "$work" ]] || rm -rf "$work"; }
trap cleanup EXIT
trap 'echo; echo "Stopped. Run the script again to continue."; exit 130' INT

say() { printf '%s\n' "$*"; }
head1() { printf '\n== %s\n' "$*"; }
confirm() {   # confirm "question" [default y|n]
    local answer hint="[y/N]"; [[ "${2:-n}" == y ]] && hint="[Y/n]"
    read -r -p "$1 $hint " answer
    answer="${answer:-${2:-n}}"
    [[ "$answer" == y || "$answer" == Y || "$answer" == yes ]]
}
hidden() {    # hidden VAR "prompt": what is typed is not shown
    local value
    read -r -s -p "$2: " value; echo
    printf -v "$1" '%s' "$value"
}
secret_date() { gh secret list --env "$ENVIRONMENT" -R "$REPO" --json name,updatedAt -q ".[] | select(.name == \"$1\") | .updatedAt" 2>/dev/null || true; }
put() {       # put NAME: the value comes on stdin, never as an argument
    gh secret set "$1" --env "$ENVIRONMENT" -R "$REPO" >/dev/null
    say "   stored: $1"
}
want() {      # want NAME: true when the secret should be (re)written
    local d; d="$(secret_date "$1")"
    [[ -z "$d" ]] && return 0
    confirm "   $1 is already set (since ${d%%T*}). Replace it?" n
}

say "AntiChat release setup for https://github.com/$REPO"
say "Seven secrets, about ten minutes. Have ready: your Mac login password, your Apple ID, and the USB stick with the Sparkle key."

# ---- 0. GitHub CLI ---------------------------------------------------------------------------------------------
head1 "GitHub login"
command -v gh >/dev/null || { say "The GitHub CLI is missing. Install it with: brew install gh"; exit 1; }
gh auth status >/dev/null 2>&1 || { say "Not logged in to GitHub. Run: gh auth login   (then start this script again)"; exit 1; }
[[ "$(gh api "repos/$REPO" --jq .permissions.admin 2>/dev/null || true)" == true ]] \
    || { say "Your GitHub login has no admin rights on $REPO (or the repository does not exist)."; exit 1; }
say "   logged in as $(gh api user --jq .login), admin of $REPO"

# ---- 1. Actions ------------------------------------------------------------------------------------------------
head1 "GitHub Actions"
if [[ "$(gh api "repos/$REPO/actions/permissions" --jq .enabled)" == true ]]; then
    say "   already on"
else
    say "   GitHub Actions is off for $REPO. The release workflow cannot run without it."
    say "   Turning it on allows only GitHub's own actions (actions/checkout and friends), with read-only access by default."
    if confirm "   Turn GitHub Actions on?" y; then
        gh api -X PUT "repos/$REPO/actions/permissions" --input - >/dev/null <<< '{"enabled": true, "allowed_actions": "selected"}'
        gh api -X PUT "repos/$REPO/actions/permissions/selected-actions" --input - >/dev/null \
            <<< '{"github_owned_allowed": true, "verified_allowed": false, "patterns_allowed": []}'
        gh api -X PUT "repos/$REPO/actions/permissions/workflow" --input - >/dev/null \
            <<< '{"default_workflow_permissions": "read", "can_approve_pull_request_reviews": false}'
        say "   on"
    else
        say "   left off. You can still store the secrets now; the workflow will not start until Actions is on."
    fi
fi
# ci.yml targets a self-hosted runner that the public repository does not have: its jobs would wait forever.
if gh workflow list -R "$REPO" --all --json path,state -q '.[] | select(.path == ".github/workflows/ci.yml") | .state' 2>/dev/null | grep -qx active; then
    say "   The workflow ci.yml needs a private build machine and would only queue here."
    if confirm "   Switch ci.yml off in the public repository?" y; then
        gh workflow disable ci.yml -R "$REPO" >/dev/null && say "   ci.yml is off"
    fi
fi

# ---- 2. environment --------------------------------------------------------------------------------------------
head1 "The \"$ENVIRONMENT\" environment (the vault the secrets live in)"
policy() {    # only v* tags and the main branch may use the environment
    local have
    have="$(gh api "repos/$REPO/environments/$ENVIRONMENT/deployment-branch-policies" --jq '.branch_policies[] | "\(.type // "branch"):\(.name)"' 2>/dev/null || true)"
    grep -qx 'tag:v\*' <<< "$have" || gh api -X POST "repos/$REPO/environments/$ENVIRONMENT/deployment-branch-policies" -f name='v*' -f type=tag >/dev/null
    grep -qx 'branch:main' <<< "$have" || gh api -X POST "repos/$REPO/environments/$ENVIRONMENT/deployment-branch-policies" -f name=main -f type=branch >/dev/null
}
if gh api "repos/$REPO/environments/$ENVIRONMENT" >/dev/null 2>&1; then
    say "   already there (its settings are left as they are)"
else
    say "   Only release runs started from a v* tag or from the main branch will be able to use the secrets."
    if confirm "   Create the environment?" y; then
        body='{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}'
        say "   Optional extra lock: every release run waits until you click Approve on GitHub."
        if confirm "   Ask for your approval before each run?" y; then
            uid="$(gh api user --jq .id)"
            body="{\"reviewers\": [{\"type\": \"User\", \"id\": $uid}], \"deployment_branch_policy\": {\"protected_branches\": false, \"custom_branch_policies\": true}}"
        fi
        gh api -X PUT "repos/$REPO/environments/$ENVIRONMENT" --input - >/dev/null <<< "$body"
        policy
        say "   created"
    else
        say "Without the environment there is nowhere to store the secrets. Stopping."; exit 1
    fi
fi

# ---- 3. signing certificate -----------------------------------------------------------------------------------
head1 "1 of 4: the signing certificate (DEVID_P12_BASE64, DEVID_P12_PASSWORD)"
say "   GitHub needs a copy of \"$CERT_NAME\" with its private key, packed in a password-protected .p12 file."
check_p12() {  # check_p12 FILE PASSWORD: 0 when it opens and holds exactly our Developer ID certificate
    local subjects n
    subjects="$(printf '%s\n' "$2" | /usr/bin/openssl pkcs12 -in "$1" -nokeys -passin stdin 2>/dev/null | grep -E '^subject=' || true)"
    [[ -n "$subjects" ]] || { say "   The file does not open with that password."; return 1; }
    n="$(grep -c 'Developer ID Application:' <<< "$subjects" || true)"
    if [[ "$n" != 1 ]] || ! grep -q "$TEAM_ID" <<< "$subjects"; then
        say "   The file holds $n Developer ID Application certificate(s); it must hold exactly one, for team $TEAM_ID."
        return 1
    fi
}
if want DEVID_P12_BASE64; then
    say
    say "   How do you want to make the .p12?"
    say "     1  I export it in Keychain Access (recommended: it contains this one certificate only)"
    say "     2  Let this script export it (quicker, but the file then holds EVERY signing identity of your login keychain)"
    say "     3  Skip for now"
    read -r -p "   Choice [1]: " how; how="${how:-1}"
    p12="" p12_password="" made_here=0
    case "$how" in
        1)
            say
            say "   a. Open Keychain Access (Spotlight: \"Keychain Access\"). Left: \"login\". Top: \"My Certificates\"."
            say "   b. Find \"$CERT_NAME\". Click it once (the row with the small arrow; the key sits under it)."
            say "   c. Menu File > Export Items…  Format: Personal Information Exchange (.p12)."
            say "      Save it on the Desktop as  antichat-devid.p12"
            say "   d. It asks for a NEW password to protect the file: invent one (you type it here once, then never again)."
            say "   e. macOS then asks for your Mac login password to allow the export."
            say
            read -r -e -p "   Path of the exported file [~/Desktop/antichat-devid.p12]: " p12
            p12="${p12:-$HOME/Desktop/antichat-devid.p12}"; p12="${p12/#\~/$HOME}"
            [[ -f "$p12" ]] || { say "   $p12 does not exist. Run the script again when the file is there."; exit 1; }
            hidden p12_password "   The password you gave the .p12 file (hidden)"
            ;;
        2)
            work="$(mktemp -d "${TMPDIR:-/tmp}/antichat-secrets.XXXXXX")"; p12="$work/devid.p12"; made_here=1
            say
            say "   macOS will now show its own windows: first for a NEW password that protects the export"
            say "   (invent one; type it twice there, then once more here), then for your Mac login password."
            security export -k "$HOME/Library/Keychains/login.keychain-db" -t identities -f pkcs12 -o "$p12" \
                || { say "   The export did not happen (cancelled?)."; exit 1; }
            hidden p12_password "   The export password you just chose (hidden)"
            ;;
        *) say "   skipped" ;;
    esac
    if [[ -n "$p12" ]]; then
        if check_p12 "$p12" "$p12_password" || confirm "   Store it anyway? (only if you are sure the file is right)" n; then
            base64 -i "$p12" | tr -d '\n' | put DEVID_P12_BASE64
            printf '%s' "$p12_password" | put DEVID_P12_PASSWORD
        else
            say "   not stored"
        fi
        p12_password=""
        if ((made_here)); then
            rm -rf "$work"; work=""; say "   temporary export deleted"
        elif confirm "   Delete $p12 now? (GitHub has its copy; the certificate stays in your keychain)" y; then
            rm -f "$p12"; say "   deleted"
        fi
    fi
fi

# ---- 4. keychain password (invented here, never shown) ---------------------------------------------------------
head1 "2 of 4: a password for the throw-away keychain on GitHub's machine (KEYCHAIN_PASSWORD)"
if [[ -z "$(secret_date KEYCHAIN_PASSWORD)" ]]; then
    /usr/bin/openssl rand -base64 32 | tr -d '\n' | put KEYCHAIN_PASSWORD
    say "   a random one was generated; you never need to know it"
else
    say "   already set (nothing to do)"
fi

# ---- 5. notarization ------------------------------------------------------------------------------------------
head1 "3 of 4: Apple notarization (NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD)"
say "   Apple checks every release before Macs open it without a warning. GitHub signs in for that with your Apple ID"
say "   and an app-specific password. The one stored on this Mac cannot be read back, so make a new one"
say "   (the old one keeps working):"
say "   a. Open https://account.apple.com and sign in."
say "   b. Sign-In and Security > App-Specific Passwords > the + button."
say "   c. Name it  AntiChat GitHub  and copy the password it shows (four groups of four letters)."
if want NOTARY_PASSWORD; then
    read -r -p "   Your Apple ID (the e-mail of the developer account): " apple_id
    read -r -p "   Team ID [$TEAM_ID]: " team; team="${team:-$TEAM_ID}"
    hidden notary_password "   The app-specific password (hidden; paste it)"
    if [[ -z "$apple_id" || -z "$notary_password" ]]; then
        say "   nothing entered; skipped"
    else
        [[ "$notary_password" =~ ^[a-z]{4}(-[a-z]{4}){3}$ ]] \
            || say "   note: this does not look like an app-specific password (four groups of four letters with dashes). Storing it as typed."
        printf '%s' "$apple_id" | put NOTARY_APPLE_ID
        printf '%s' "$team" | put NOTARY_TEAM_ID
        printf '%s' "$notary_password" | put NOTARY_PASSWORD
        say "   The first workflow run checks these three with Apple before it builds anything."
    fi
    notary_password=""
fi

# ---- 6. Sparkle update key ------------------------------------------------------------------------------------
head1 "4 of 4: the update-signing key (SPARKLE_PRIVATE_KEY)"
say "   Installed copies of AntiChat only accept updates signed with this key. It lives on your encrypted USB stick"
say "   (the key ceremony wrote it as antichat-keys/sparkle-primary.priv). Plug the stick in and unlock it."
say "   The file is read straight from the stick; no copy is made on this Mac. Never use sparkle-backup.priv here."
if want SPARKLE_PRIVATE_KEY; then
    read -r -e -p "   Path of sparkle-primary.priv (drag the file into this window): " key
    key="${key%\"}"; key="${key#\"}"; key="${key%\'}"; key="${key#\'}"; key="${key//\\ / }"; key="${key% }"; key="${key/#\~/$HOME}"
    if [[ ! -f "$key" ]]; then
        say "   $key does not exist; skipped. Run the script again with the stick plugged in."
    else
        pinned="$(python3 -I "$ROOT/tools/release/gen-keys-swift.py" --sparkle-key release)"
        derived="$(swift "$ROOT/tools/release/sparkle-pubkey.swift" "$key" 2>/dev/null || true)"
        if [[ -n "$derived" && "$derived" == "$pinned" ]]; then
            say "   it is the key the app trusts (public half matches Config/Keys.release.plist)"
            put SPARKLE_PRIVATE_KEY < "$key"
        elif [[ -n "$derived" ]]; then
            say "   This is NOT the key the app trusts (wrong file? the backup key?). Not stored."
        elif confirm "   Could not check the key against the app (is Xcode installed?). Store it unchecked?" n; then
            put SPARKLE_PRIVATE_KEY < "$key"
        else
            say "   not stored"
        fi
    fi
fi

# ---- 7. result ------------------------------------------------------------------------------------------------
head1 "Result"
missing=0
for s in $SECRETS; do
    d="$(secret_date "$s")"
    if [[ -n "$d" ]]; then say "   ok       $s (set ${d%%T*})"; else say "   MISSING  $s"; missing=$((missing + 1)); fi
done
if ((missing > 0)); then
    say; say "$missing secret(s) still missing. Run this script again to add them."
    exit 1
fi
say
say "All seven are stored. You can eject the USB stick."
say "Next: tools/release/CHECKLIST.md, \"Pipeline\" — export the public snapshot, push it, push the tag v<version>."
