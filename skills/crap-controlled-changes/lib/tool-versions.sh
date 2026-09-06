# Pinned tool versions, in one place.
#
# Two of these are read twice over: by the runner that invokes the tool, and by
# the ledger fingerprint that decides whether an earlier measurement still
# counts. A drift between those two would trust a record measured by a version
# no longer in use.
#
# deadcode has no ledger and so no fingerprint, but it is pinned for the other
# reason: `go run pkg@latest` re-resolves on every run, so an upstream release
# can flip this gate from green to red with no change to the code under it. A
# gate whose verdict moves on its own is not a measurement. Bumping is a
# deliberate, visible act; x/tools tracks the Go toolchain, so expect to bump it
# when the toolchain moves.
MUTAGO_VERSION_DEFAULT=v2.8.1
GOCRAP_VERSION_DEFAULT=v0.5.0
DEADCODE_VERSION_DEFAULT=v0.49.0
