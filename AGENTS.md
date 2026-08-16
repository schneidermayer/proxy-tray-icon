# Repo Workflow

- Keep the base/current release version in `VERSION` (for example, `1.1`).
- Track every release with an annotated Git tag whose name exactly matches the release version in `VERSION` (for example, `1.1`, without a `v` prefix), and push the tag.
- After every code change, complete all of the following unless the user explicitly says not to:
  1. Commit only the scoped change before building so the new commit is included in the version count.
  2. Find the latest reachable release tag and count the commits after it. Build with the version `<current-version>-<commits-since-last-release>` (for example, `1.1-15`):
     ```sh
     CURRENT_VERSION="$(awk 'NF { print $1; exit }' VERSION)"
     RELEASE_TAG="$(git describe --tags --abbrev=0 --match '[0-9]*')"
     COMMITS_SINCE_RELEASE="$(git rev-list --count "${RELEASE_TAG}..HEAD")"
     APP_VERSION="${CURRENT_VERSION}-${COMMITS_SINCE_RELEASE}" ./Scripts/build-app.sh
     ```
  3. Terminate any running instance, relaunch the newly built installed app, and verify that it is running:
     ```sh
     pkill -x ProxyTray 2>/dev/null || true
     open -na /Applications/ProxyTray.app
     pgrep -x ProxyTray >/dev/null
     ```
  4. Push the current branch.
