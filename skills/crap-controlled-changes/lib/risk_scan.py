"""Running a per-language analysis over the head revision of a range."""

import tempfile

from risk_core import NO_SOURCE_CHANGED, combine_any, language_name, measured, unmeasured
from risk_tools import unpack


def handler_part(handlers, what, lang, head_root, paths, added):
    handler = handlers.get(lang)
    if handler is None:
        return unmeasured(f'no {what} supports {language_name(lang)} files (e.g. {paths[0]})')
    return handler(head_root, paths, added)


def scan_head(handlers, what, repo, head, groups, added):
    """`groups` is risk_core.by_language over the changed paths, `added` is
    risk_core.added_lines over the range, and each handler is
    `(head_root, paths, added) -> entry` for one language; `what` names the kind
    of tool a language without a handler lacks."""
    if not groups:
        return measured(False, NO_SOURCE_CHANGED)
    with tempfile.TemporaryDirectory() as tmp:
        head_root = unpack(repo, head, tmp)
        parts = [handler_part(handlers, what, lang, head_root, paths, added)
                 for lang, paths in sorted(groups.items())]
    return combine_any(parts)
