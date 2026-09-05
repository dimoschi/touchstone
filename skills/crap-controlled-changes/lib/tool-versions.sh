# Pinned mutator versions, in one place because two things read them: the runner
# that invokes the tool, and the ledger fingerprint that decides whether an
# earlier measurement still counts. A drift between those two would trust a
# record measured by a version no longer in use.
MUTAGO_VERSION_DEFAULT=v2.8.1
GOCRAP_VERSION_DEFAULT=v0.5.0
