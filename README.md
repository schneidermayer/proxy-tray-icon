# ProxyTray (Swift menu bar agent)

A small Swift 5 menu bar agent that starts an SSH dynamic tunnel with public-key authentication, exposes it as a system SOCKS proxy on `127.0.0.1:1080`, and switches the macOS proxy settings between a whitelist-driven PAC file or a route-all mode. The status-bar icon dims when inactive and is fully opaque when active.

## Build & run
1. Make sure Xcode command line tools and a valid Developer ID Application signing identity are installed. The build script selects an available identity; set `CODE_SIGN_IDENTITY` to its full name or SHA-1 hash to choose explicitly.
2. Build and install the app using the steps below.
3. Make sure your SSH public key is authorized on the server and its host key is trusted (see SSH authentication below).
4. Launch `/Applications/ProxyTray.app`. Open **Update SSH Settings**, enter the server details, choose the private key to import, and then enable the proxy.

### Build a standalone app bundle
If you want a double-clickable `.app` without manual steps:
1. Keep the base release number in `VERSION` (current: `1.3`) and commit the scoped changes before building.
2. Build with the number of commits since the latest release tag:

   ```sh
   CURRENT_VERSION="$(awk 'NF { print $1; exit }' VERSION)"
   RELEASE_TAG="$(git describe --tags --abbrev=0 --match '[0-9]*')"
   COMMITS_SINCE_RELEASE="$(git rev-list --count "${RELEASE_TAG}..HEAD")"
   APP_VERSION="${CURRENT_VERSION}-${COMMITS_SINCE_RELEASE}" ./Scripts/build-app.sh
   ```

3. The script installs the bundle at `/Applications/ProxyTray.app`. Quit the old instance, then run `open -na /Applications/ProxyTray.app`.
4. Push the branch. For a new base release, create and push an annotated tag matching `VERSION` exactly, without a `v` prefix.

The script writes `APP_VERSION` into the bundle metadata used by Finder and the tray tooltip. An `.icns` from `Scripts/icon512.icns` is bundled as the Finder icon. The tray glyph is drawn in code. Always launch the installed copy in `/Applications`.

## Menu actions
- **Enable Proxy**: starts SSH in public-key-only mode, waits for the authenticated tunnel to own its SOCKS listener at `127.0.0.1:1080`, then applies proxy settings. While connecting, this action becomes **Cancel Connection**.
- **Disable Proxy**: stops the managed tunnel and restores the previous proxy settings.
- **Restart Proxy**: stops the managed tunnel, restores the previous settings, and reconnects.
- **Route All Traffic**: toggles between “all traffic via proxy” (direct SOCKS config) and “whitelist only” (PAC file).
- **Open Whitelist File**: opens `~/.proxy-tray/whitelist.txt` for editing.
- **Update SSH Settings**: set SSH host, username, port, and imported private key.
- **Proxy Access…** (macOS 13+): check or grant persistent permission to change proxy settings.
- **Quit**: stops proxy/tunnel and exits.

## Whitelist format
Plain-text file at `~/.proxy-tray/whitelist.txt`, one entry per line. Lines starting with `#` are ignored. Allowed entries:
- Single IPv4 address, e.g. `203.0.113.42`
- IPv4 CIDR, e.g. `10.0.0.0/8` or `192.168.1.0/24`

Wildcards (`*`) are **not** supported. All hosts **not** matching these CIDRs go DIRECT. When “Route All Traffic” is ON, the whitelist is ignored and everything goes through the proxy.

## SSH key authentication
- SSH only attempts public-key authentication and never falls back to a server password or keyboard-interactive login.
- SSH uses `StrictHostKeyChecking=yes` and the normal SSH known-hosts files. Unknown or changed host keys are rejected. Before connecting to a new server, verify its host-key fingerprint with its administrator and use `ssh -o StrictHostKeyChecking=ask -p <port> <user>@<host>` in Terminal to establish trust. Changed keys require verification and an intentional update to the stored host key.
- **Update SSH Settings** provides a file picker for importing a private key. A candidate is copied into `~/.proxy-tray/keys/identity-<UUID>`, validated, and unlocked before settings are saved atomically. A failed import, wrong passphrase, or save failure leaves the working key and settings intact. The source file is left untouched; legacy `keys/identity` remains supported.
- The imported key and its containing directory use `0600` and `0700` permissions respectively. SSH receives the key explicitly and uses `IdentitiesOnly=yes`.
- A passphrase-protected key is added through macOS OpenSSH and stored in the user's Keychain. The passphrase is used only by the local SSH client and is never sent to the server.
- If no key is imported, OpenSSH continues to discover keys in its standard locations and configuration, including `~/.ssh/id_*`, per-host `IdentityFile` settings, and `ssh-agent`.
- SSH settings (host/username/port/identity file) are stored in `~/.proxy-tray/ssh.json`. Defaults: `user@example.com:22`.
- Older releases may have created `~/.proxy-tray/password.enc` and a `ProxyTrayKey` Keychain item. The current app does not read either; they can be removed once rollback to a password-based release is no longer needed.

## Files the app manages
- `~/.proxy-tray/whitelist.txt` (editable)
- `~/.proxy-tray/proxy.pac` (generated from your whitelist)
- `~/.proxy-tray/ssh.json` (editable via menu)
- `~/.proxy-tray/keys/identity-<UUID>` (imported SSH private key, when configured; legacy `keys/identity` also supported)
- `~/.proxy-tray/network-state.json` (previous proxy settings and ownership journal)
- `~/.proxy-tray/run/ssh.sock` (private control socket identifying ProxyTray's SSH tunnel)

## Persistent proxy permission

On macOS 13 and later, ProxyTray registers a signed network helper with macOS. On first launch, open **Proxy Access…**, choose **Open System Settings**, and enable ProxyTray under **General → Login Items & Extensions → App Background Activity** (called **Allow in the Background** on older systems). Approve the macOS prompt, then enable the proxy from the tray menu. Approval survives app restarts and reboots; normal proxy starts and stops do not request Touch ID. You can revoke it from the same System Settings panel.

The helper accepts only signed ProxyTray clients from the same Developer ID team and can update only the six PAC/SOCKS fields already managed by the app. SSH and private keys remain in the user process. ProxyTray keeps the existing ownership journal and restores previous settings as before. New helper builds are re-registered; ordinary app launches leave the registration alone. macOS 12 retains the previous per-session authorization flow.

The installed bundle supports read-only diagnostics:

```sh
/Applications/ProxyTray.app/Contents/MacOS/ProxyTray --proxy-helper-status
/Applications/ProxyTray.app/Contents/MacOS/ProxyTray --check-proxy-helper
```

`--prepare-proxy-helper` registers the bundled helper without changing any proxy settings. Administrator approval must still be granted through macOS. For distribution to other Macs, notarize the signed bundle; a successful local build is not distribution qualification.

## Notes
- If the SSH server listens on a different host or port, update it from the tray menu via **Update SSH Settings**.
- ProxyTray records the previous PAC/SOCKS settings before changing them through macOS SystemConfiguration. It restores only settings it owns, preserves unrelated proxy fields, and leaves later external changes alone. An inactive app with no recorded changes does not modify network settings on quit. On macOS 13+, network authorization is granted once through the helper setup above.
- Only the SSH process launched by ProxyTray or reached through its private control socket is managed. Other processes using port `1080` are left running; a port conflict causes a connection error.
- If the managed `ssh` process exits unexpectedly, ProxyTray restores its recorded network changes so macOS is not left pointing at its dead SOCKS listener.
- A lost connection shows an **SSH connection lost** popup with SSH's error output and exit status or signal. **Copy Details** copies the diagnostic text. Any failure to restore previous proxy settings is included in the same report. Intentional disconnects, restarts, and quitting do not show this popup.
- Connection-loss errors are also written to the macOS unified log (subsystem `net.hsch.proxytray`, category `Connection`). In Console, filter for ProxyTray, or run `log show --last 1h --style compact --predicate 'subsystem == "net.hsch.proxytray" AND category == "Connection"'`. These diagnostics can include server addresses, usernames, and key file paths reported by SSH; private keys and passphrases are not logged by ProxyTray.
- SSH keepalives detect an unresponsive server after approximately 90 seconds. A tunnel inherited from an earlier app instance is checked every two seconds; its original SSH error output is unavailable, so the popup explains that limitation.
- On launch, recorded network changes from an earlier crashed session are restored if the managed tunnel is no longer available. Settings with no ownership journal are left untouched. When upgrading from a version without an ownership journal, disable its active proxy before replacing the app.
