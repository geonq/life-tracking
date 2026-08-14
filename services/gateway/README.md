# LifeOS gateway

This directory is the tracked gateway source of truth. The Python module is
loopback-only and is authenticated by the exact Tailscale login header; it is
not a deployment bundle.

If a remote Windows gateway has drifted, replace that remote source only after
the isolated gateway test suite and Python compile check pass against this
tracked copy. Do not deploy from this note or as part of source review.
