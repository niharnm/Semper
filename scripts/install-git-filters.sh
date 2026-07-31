#!/usr/bin/env bash
# Configures a local git clean filter that strips the user-specific
# DEVELOPMENT_TEAM[sdk=macosx*] value from Semper.xcodeproj/project.pbxproj
# before staging. Xcode rewrites this line on every build with the active
# signing team; without the filter every build makes the pbxproj "dirty".
#
# Run this once per clone: `./scripts/install-git-filters.sh`
set -euo pipefail

cd "$(dirname "$0")/.."

git config filter.scrub-dev-team.clean 'sed -E "s/(\"DEVELOPMENT_TEAM\[sdk=macosx\*\]\" = )[A-Z0-9]+;/\1\"\";/g"'
git config filter.scrub-dev-team.smudge cat
git config filter.scrub-dev-team.required true

echo "Installed scrub-dev-team filter."
echo "Re-normalizing the pbxproj so the filter applies immediately..."
git add --renormalize Semper.xcodeproj/project.pbxproj >/dev/null 2>&1 || true
git restore --staged Semper.xcodeproj/project.pbxproj >/dev/null 2>&1 || true
echo "Done. Xcode writes to DEVELOPMENT_TEAM[sdk=macosx*] will now be stripped on git add."
