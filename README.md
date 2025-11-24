# ProxyTray (Swift menu bar agent)

A small Swift 5 menu bar agent that starts an SSH dynamic tunnel, exposes it as a system SOCKS proxy on `127.0.0.1:1080`, and switches the macOS proxy settings between a whitelist-driven PAC file or a route-all mode. Passwords are encrypted locally; the status-bar icon dims when inactive and is fully opaque when active.

## Build & run
1. Make sure Xcode command line tools are installed.
2. From this folder run: `swift run ProxyTray`
   - The app stays attached to the terminal session; keep the window open while running.
3. A new tray icon will appear. Use the menu to set the SSH password first, then enable the proxy.

## Menu actions
- **Enable Proxy**: decrypts the stored SSH password, starts `ssh -N -D 1080 -p <port> <user>@<host>` using SSH_ASKPASS, then applies proxy settings.
- **Disable Proxy**: stops the tunnel and turns off proxy settings.
- **Route All Traffic**: toggles between “all traffic via proxy” (direct SOCKS config) and “whitelist only” (PAC file).
- **Open Whitelist File**: opens `~/.proxy-tray/whitelist.txt` for editing.
- **Update SSH Settings**: set SSH host, username, and port (stored in `~/.proxy-tray/ssh.json`).
- **Update SSH Password**: securely re-encrypts and stores the password.
- **Cleanup (stop proxy)**: manually tears down proxy + tunnel (only clickable when inactive).
- **Quit**: stops proxy/tunnel and exits.

## Whitelist format
Plain-text file at `~/.proxy-tray/whitelist.txt`, one entry per line. Lines starting with `#` are ignored. Allowed entries:
- Single IPv4 address, e.g. `203.0.113.42`
- IPv4 CIDR, e.g. `10.0.0.0/8` or `192.168.1.0/24`

Wildcards (`*`) are **not** supported. All hosts **not** matching these CIDRs go DIRECT. When “Route All Traffic” is ON, the whitelist is ignored and everything goes through the proxy.

## Password storage
- Your password is encrypted with AES-GCM.
- A random 256-bit key is generated once and stored in the macOS Keychain (service `ProxyTrayKey`).
- The encrypted password is stored at `~/.proxy-tray/password.enc`.
- SSH settings (host/username/port) are stored in `~/.proxy-tray/ssh.json`. Defaults: `user@example.com:22`.

## Files the app manages
- `~/.proxy-tray/whitelist.txt` (editable)
- `~/.proxy-tray/proxy.pac` (generated from your whitelist)
- `~/.proxy-tray/password.enc` (encrypted password)
- `~/.proxy-tray/ssh.json` (editable via menu)

## Notes
- If the SSH server listens on a different host or port, update it from the tray menu via **Update SSH Settings**.
- The app calls `/usr/sbin/networksetup` for every active network service to flip between PAC and SOCKS modes; no global reset of unrelated settings is performed.
- Cleanup ensures the SOCKS proxy is off and the ssh process on port 1080 is terminated so the port is free again.
