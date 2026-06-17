#!/usr/bin/env bash
#
# Bump MacColi's version in MacColi.xcodeproj/project.pbxproj.
#
# Two numbers live there, each duplicated across the Debug and Release build
# configurations:
#   • MARKETING_VERSION       — the user-facing semver (e.g. 0.1.1), shown as
#                               CFBundleShortVersionString.
#   • CURRENT_PROJECT_VERSION — a monotonic build number (CFBundleVersion) that
#                               must strictly increase for every notarized
#                               upload, independent of the marketing version.
#
# This script computes the next marketing version (major/minor/patch bump or an
# explicit X.Y.Z), always increments the build number by one, and rewrites all
# occurrences so both configs stay in lockstep.
#
# ── Usage ────────────────────────────────────────────────────────────────────
#   scripts/bump-version.sh                # patch bump (default): 0.1.1 → 0.1.2
#   scripts/bump-version.sh patch          # same as above
#   scripts/bump-version.sh minor          # 0.1.1 → 0.2.0
#   scripts/bump-version.sh major          # 0.1.1 → 1.0.0
#   scripts/bump-version.sh 0.3.0          # set an explicit version
#   scripts/bump-version.sh --dry-run minor  # preview without writing
#
# Exits non-zero (touching nothing) if the project's existing versions are
# inconsistent or unparseable, so a bad bump can't slip through.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PBXPROJ="$REPO_ROOT/MacColi.xcodeproj/project.pbxproj"

DRY_RUN=0
SPEC="patch"
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        major|minor|patch) SPEC="$arg" ;;
        [0-9]*.[0-9]*.[0-9]*) SPEC="$arg" ;;
        -h|--help)
            sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; s/^#//'
            exit 0 ;;
        *) echo "error: unknown argument '$arg'" >&2
           echo "usage: bump-version.sh [--dry-run] [major|minor|patch|X.Y.Z]" >&2
           exit 2 ;;
    esac
done

[[ -f "$PBXPROJ" ]] || { echo "error: $PBXPROJ not found" >&2; exit 1; }

# ── Read and validate the current versions ───────────────────────────────────
# Every MARKETING_VERSION (and every CURRENT_PROJECT_VERSION) must agree across
# build configs; otherwise the "current" version is ambiguous and we refuse.
mapfile -t MV < <(grep -oE 'MARKETING_VERSION = [^;]+;' "$PBXPROJ" | sed -E 's/.*= *([^;]+);/\1/')
mapfile -t BV < <(grep -oE 'CURRENT_PROJECT_VERSION = [0-9]+;' "$PBXPROJ" | sed -E 's/.*= *([0-9]+);/\1/')

[[ ${#MV[@]} -gt 0 ]] || { echo "error: no MARKETING_VERSION found in project" >&2; exit 1; }
[[ ${#BV[@]} -gt 0 ]] || { echo "error: no CURRENT_PROJECT_VERSION found in project" >&2; exit 1; }

require_uniform() {
    local label="$1"; shift
    local first="$1"; shift
    for v in "$@"; do
        [[ "$v" == "$first" ]] || {
            echo "error: inconsistent $label across build configs ($first vs $v)." >&2
            echo "       Align them by hand, then re-run." >&2
            exit 1
        }
    done
}
require_uniform "MARKETING_VERSION" "${MV[@]}"
require_uniform "CURRENT_PROJECT_VERSION" "${BV[@]}"

CUR_VERSION="${MV[0]}"
CUR_BUILD="${BV[0]}"

[[ "$CUR_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "error: current MARKETING_VERSION '$CUR_VERSION' is not X.Y.Z" >&2; exit 1; }

# ── Compute the next marketing version ───────────────────────────────────────
IFS='.' read -r MAJOR MINOR PATCH <<< "$CUR_VERSION"
case "$SPEC" in
    major) NEW_VERSION="$((MAJOR + 1)).0.0" ;;
    minor) NEW_VERSION="${MAJOR}.$((MINOR + 1)).0" ;;
    patch) NEW_VERSION="${MAJOR}.${MINOR}.$((PATCH + 1))" ;;
    *)     NEW_VERSION="$SPEC" ;;   # explicit X.Y.Z (already shape-checked)
esac
NEW_BUILD="$((CUR_BUILD + 1))"

echo "MARKETING_VERSION       $CUR_VERSION → $NEW_VERSION"
echo "CURRENT_PROJECT_VERSION $CUR_BUILD → $NEW_BUILD"

if [[ "$DRY_RUN" == 1 ]]; then
    echo "(dry run — no changes written)"
    exit 0
fi

if [[ "$NEW_VERSION" == "$CUR_VERSION" ]]; then
    echo "error: new version equals current ($CUR_VERSION); nothing to bump" >&2
    exit 1
fi

# ── Rewrite every occurrence (BSD sed: -i needs an explicit '' backup arg) ────
sed -i '' -E "s/(MARKETING_VERSION = )[^;]+;/\1${NEW_VERSION};/g" "$PBXPROJ"
sed -i '' -E "s/(CURRENT_PROJECT_VERSION = )[0-9]+;/\1${NEW_BUILD};/g" "$PBXPROJ"

echo "Updated $(basename "$PBXPROJ"). Build the app to pick up the new version."
