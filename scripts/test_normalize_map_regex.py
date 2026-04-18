"""Pins down the map-normalisation regex used by MGEMod's fallback search.

The plugin compiles the same pattern via SourceMod's `Regex` (PCRE) and
strips the matched suffix from the current map name. Running it through
Python's PCRE-compatible `re` module keeps the expectations in one place;
if someone edits the pattern in mge/spawn_download.sp without updating
these cases they have to also update the test, which forces thought about
real map names.

Note: the regex is relatively greedy — it can strip more than a strict
"version suffix" when there are no intervening underscores. That's fine
as long as the fallback search uses "prefix match, first hit wins":
the stripped form only needs to be a prefix of *some* config filename.
"""

from __future__ import annotations

import re

import pytest

PATTERN = r"(_((a|b|beta|u|r|v|rc|f|final|comptf|ugc)?[0-9]*[a-z]?)*$)|([0-9]+[a-z]?$)"
RX = re.compile(PATTERN)


def normalise(name: str) -> str:
    """Return the prefix the plugin would search for after suffix stripping."""
    m = RX.search(name)
    if not m or not m.group(0):
        return name
    # Plugin does ReplaceString(cleanMap, match, "") — remove first occurrence.
    return name.replace(m.group(0), "", 1)


# For each real MGE map name, the stripped form must still be a prefix of
# a *sibling* version in the shipped set. That's the invariant the
# fallback search actually depends on.
SIBLINGS = {
    "mge_oihguv_sucks_b5": "mge_oihguv_sucks_b3",
    "mge_oihguv_sucks_a12": "mge_oihguv_sucks_b1",
    "mge_rework_a4": "mge_rework_v1",
    "mge_training_v9": "mge_training_v7",
    # Note: deeply chained suffixes like "mge_triumph_beta8_rc1" only strip
    # the trailing "_rc1", because the inner alternation does not match "_".
    # The fallback scan would fail in that case — acceptable for v1.
    "mge_chillypunch_a9": "mge_chillypunch_a8",
    "am_variety_test11": "am_variety_test10",
}


@pytest.mark.parametrize("raw,sibling", list(SIBLINGS.items()))
def test_normalised_prefix_matches_sibling(raw: str, sibling: str):
    prefix = normalise(raw)
    assert prefix  # non-empty
    assert sibling.startswith(prefix), (
        f"stripped '{raw}' -> '{prefix}', which is not a prefix of '{sibling}'"
    )


def test_regex_matches_something_on_every_real_map():
    """The pattern should not silently fail to match any map we ship."""
    names = [
        "mge_training_v7",
        "mge_rework_a4",
        "mge_chillypunch_final4_fix2",
        "mge_oihguv_sucks_b3_fix2",
        "mge_16badlands",
        "am_variety_test10",
    ]
    for name in names:
        assert RX.search(name), f"regex did not match {name!r}"


def test_suffixless_plain_name_does_not_crash():
    # "mge_process" has no digit suffix — the regex may or may not
    # match an empty/short tail. What matters is that the resulting
    # prefix is non-empty so the scan has *something* to search for.
    out = normalise("mge_process")
    assert out  # non-empty — plugin's GetFallbackConfigPath guards on this.
