# ProxyTray (Swift menu bar agent)

A small Swift 5 menu bar agent that starts an SSH dynamic tunnel with public-key authentication, exposes it as a system SOCKS proxy on `127.0.0.1:1080`, and switches the macOS proxy settings between a whitelist-driven PAC file or a route-all mode. The status-bar icon dims when inactive and is fully opaque when active.

## Build & run
1. Make sure Xcode command line tools are installed.
2. From this folder run: `swift run ProxyTray`
   - The app stays attached to the terminal session; keep the window open while running.
3. Make sure your SSH public key is authorized on the server.
4. A new tray icon will appear. Open **Update SSH Settings**, enter the server details, choose the private key to import, and then enable the proxy.

### Build a standalone app bundle
If you want a double-clickable `.app` without manual steps:
1. Set the release number in `VERSION` (current: `1.1`).
2. Run `./Scripts/build-app.sh`
3. Launch `.build/ProxyTray.app`

The script reads the version from `VERSION` by default and writes it into the app bundle metadata used by Finder and the tray tooltip. For a one-off build without editing the file, use `APP_VERSION=1.0 ./Scripts/build-app.sh`. An `.icns` from `Scripts/icon512.icns` is bundled and set as the Finder icon; replace that file if you want a different icon. The tray glyph itself is still drawn in code. If you want a stable launcher, symlink it: `ln -sfn "$(pwd)/.build/ProxyTray.app" /Applications/ProxyTray.app`.

## Menu actions
- **Enable Proxy**: starts `ssh -N -D 1080 -i <private-key> -p <port> <user>@<host>` in public-key-only mode, then applies proxy settings.
- **Disable Proxy**: stops the tunnel and turns off proxy settings.
- **Restart Proxy**: stops the current tunnel, clears the proxy settings, and reconnects immediately.
- **Route All Traffic**: toggles between “all traffic via proxy” (direct SOCKS config) and “whitelist only” (PAC file).
- **Open Whitelist File**: opens `~/.proxy-tray/whitelist.txt` for editing.
- **Update SSH Settings**: set SSH host, username, port, and imported private key.
- **Quit**: stops proxy/tunnel and exits.

## Whitelist format
Plain-text file at `~/.proxy-tray/whitelist.txt`, one entry per line. Lines starting with `#` are ignored. Allowed entries:
- Single IPv4 address, e.g. `203.0.113.42`
- IPv4 CIDR, e.g. `10.0.0.0/8` or `192.168.1.0/24`

Wildcards (`*`) are **not** supported. All hosts **not** matching these CIDRs go DIRECT. When “Route All Traffic” is ON, the whitelist is ignored and everything goes through the proxy.

## SSH key authentication
- SSH only attempts public-key authentication and never falls back to a server password or keyboard-interactive login.
- **Update SSH Settings** provides a file picker for importing a private key. The key is copied to `~/.proxy-tray/keys/identity`; the original file is left untouched.
- The imported key and its containing directory use `0600` and `0700` permissions respectively. SSH receives the key explicitly and uses `IdentitiesOnly=yes`.
- A passphrase-protected key is added through macOS OpenSSH and stored in the user's Keychain. The passphrase is used only by the local SSH client and is never sent to the server.
- If no key is imported, OpenSSH continues to discover keys in its standard locations and configuration, including `~/.ssh/id_*`, per-host `IdentityFile` settings, and `ssh-agent`.
- SSH settings (host/username/port/identity file) are stored in `~/.proxy-tray/ssh.json`. Defaults: `user@example.com:22`.
- Older releases may have created `~/.proxy-tray/password.enc` and a `ProxyTrayKey` Keychain item. The current app does not read either; they can be removed once rollback to a password-based release is no longer needed.

## Files the app manages
- `~/.proxy-tray/whitelist.txt` (editable)
- `~/.proxy-tray/proxy.pac` (generated from your whitelist)
- `~/.proxy-tray/ssh.json` (editable via menu)
- `~/.proxy-tray/keys/identity` (imported SSH private key, when configured)

## Notes
- If the SSH server listens on a different host or port, update it from the tray menu via **Update SSH Settings**.
- The app calls `/usr/sbin/networksetup` for every active network service to flip between PAC and SOCKS modes; no global reset of unrelated settings is performed.
- If the managed `ssh` process exits unexpectedly, ProxyTray disables the system proxy automatically so macOS is not left pointing at a dead local SOCKS listener.
- On launch, stale PAC/SOCKS settings from an earlier crashed session are cleared if no tunnel is listening on port `1080`.
