# LifeOS macOS relay

This is an opt-in loopback transport seam for the LifeOS sync protocol. It
binds to `127.0.0.1` by default and refuses non-loopback binding unless an
operator supplies the explicit unsafe override. The relay does not hold trust
keys, enroll peers, or infer identity from local process names.

The caller must inject a handler that verifies the signed LifeOS request and
returns a signed response. Until that handler exists, authenticated routes
return a content-free `503 handlerUnavailable`. Health is the only unsigned
route. Windows administration and administrative blob operations are always
denied by this relay.

`install.sh --print-template` prints a LaunchAgent template for review. It does
not write files, call `launchctl`, start the relay, or modify Tailscale Serve.
Before any installation, snapshot the current Serve configuration and merge
only the owned route; Windows deployment remains a separate reviewed step.

The default test command is:

```text
python3 -m unittest -v services/mac-relay/test_relay.py
```
