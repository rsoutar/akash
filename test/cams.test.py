#!/usr/bin/env python3
"""Offline checks for cams.py: the parts that must hold without the network.

The live WMS is exercised by hand (init, probe, legend); these pin the logic
that a rename or a corrupt cache would otherwise break silently. Run with:

    python3 test/cams.test.py
"""

from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

TEST_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(TEST_ROOT.parent))

spec = importlib.util.spec_from_file_location("cams", TEST_ROOT.parent / "cams.py")
cams = importlib.util.module_from_spec(spec)
sys.modules["cams"] = spec.loader.exec_module(cams) or cams


class CacheStaleness(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["AKASH_CONFIG_DIR"] = self.tmp.name
        importlib.reload(cams)

    def tearDown(self):
        del os.environ["AKASH_CONFIG_DIR"]
        self.tmp.cleanup()

    def write_cache(self, payload):
        cams.atomic_write(cams.caps_path(), payload)

    def test_fresh_current_version_cache_is_kept(self):
        self.write_cache({"version": cams.CAPS_CACHE_VERSION,
                          "generatedAt": int(time.time())})
        self.assertFalse(cams.cache_is_stale())

    def test_expired_cache_is_rebuilt(self):
        self.write_cache({"version": cams.CAPS_CACHE_VERSION,
                          "generatedAt": int(time.time() - cams.CACHE_MAX_AGE - 1)})
        self.assertTrue(cams.cache_is_stale())

    def test_previous_layout_cache_is_rebuilt(self):
        # A cache from before the version field existed, or from an older
        # layout: not a cache for this code, whatever its age.
        self.write_cache({"generatedAt": int(time.time())})
        self.assertTrue(cams.cache_is_stale())

    def test_corrupt_cache_is_rebuilt(self):
        cams.caps_path().write_text("not json")
        self.assertTrue(cams.cache_is_stale())

    def test_state_filters_unknown_keys(self):
        cams.atomic_write(cams.state_path(), {"layer": "composition_o3", "bogus": 1})
        state = cams.current_state()
        self.assertEqual(state["layer"], "composition_o3")
        self.assertNotIn("bogus", state)


class LayerClassification(unittest.TestCase):
    def test_europe_air_quality(self):
        tags = cams.classify("composition_europe_pm2p5_forecast_surface")
        self.assertEqual(tags["category"], "air-quality")
        self.assertEqual(tags["region"], "europe")
        self.assertEqual(tags["short"], "PM2.5")

    def test_global_air_quality(self):
        tags = cams.classify("composition_pm2p5")
        self.assertEqual(tags["category"], "air-quality")
        self.assertEqual(tags["region"], "global")

    def test_pollen_index_and_concentration(self):
        index = cams.classify("composition_europe_pol_birch_forecast_surface_eea")
        conc = cams.classify("composition_europe_pol_birch_forecast_surface")
        self.assertEqual(index["variant"], "index")
        self.assertEqual(conc["variant"], "concentration")

    def test_unknown_species_falls_back_gracefully(self):
        # CAMS can add a species without telling anyone. It surfaces in the
        # allergens tab under a title-cased name rather than disappearing.
        tags = cams.classify("composition_europe_pol_pine_forecast_surface")
        self.assertEqual(tags["category"], "allergens")
        self.assertEqual(tags["short"], "Pine")

    def test_renamed_pollutant_lands_in_advanced_tail(self):
        # A renamed air-quality layer is no longer curated, but it stays
        # reachable through the ⚙ search rather than vanishing.
        tags = cams.classify("composition_europe_xno9_forecast_surface")
        self.assertEqual(tags["tier"], "advanced")

    def test_advanced_tail_keeps_unknown_technical_layers(self):
        tags = cams.classify("composition_fire")
        self.assertEqual(tags["tier"], "advanced")

    def test_parse_capabilities_tolerates_renames(self):
        # A well-formed document whose layers have all been renamed classifies
        # them into the advanced tail instead of raising or dropping them.
        xml = """<WMS_Capabilities>
          <Layer><Name>composition_something_new</Name>
            <Title>New thing</Title>
            <Dimension name="time" default="2026-01-01T00:00:00Z">2026-01-01T00:00:00Z</Dimension>
          </Layer>
        </WMS_Capabilities>"""
        layers = cams.parse_capabilities(xml)
        self.assertEqual(len(layers), 1)
        self.assertEqual(layers[0]["tier"], "advanced")

    def test_parse_capabilities_keeps_named_layers(self):
        xml = """<WMS_Capabilities>
          <Layer><Name>composition_europe_pm2p5_forecast_surface</Name>
            <Title>Particulate matter &lt; 2.5 um</Title>
            <Dimension name="time" default="2026-01-01T00:00:00Z">2026-01-01T00:00:00Z/2026-01-02T00:00:00Z</Dimension>
            <Style><Name>default</Name></Style>
          </Layer>
        </WMS_Capabilities>"""
        layers = cams.parse_capabilities(xml)
        self.assertEqual(len(layers), 1)
        self.assertEqual(layers[0]["short"], "PM2.5")
        self.assertEqual(layers[0]["styles"], ["default"])


class ProbeResponse(unittest.TestCase):
    def test_service_exception_reads_as_no_value(self):
        # A renamed layer, or a time outside the forecast, comes back as an
        # XML ServiceException — which must read as "no value", not as a crash
        # and not as a number.
        import re
        text = "<?xml version='1.0'?><ServiceExceptionReport><ServiceException>LayerNotDefined</ServiceException></ServiceExceptionReport>"
        self.assertNotIn("Value:", text)
        self.assertIsNone(re.search(r"Value:\s*([-\d.eE]+)\s*(\S+)?", text))


class _FakeResponse:
    """An urlopen stand-in delivering fixed chunks, so the ceiling is tested
    against what a host could actually send."""

    def __init__(self, chunks):
        self._chunks = list(chunks)

    def read(self, size):
        if not self._chunks:
            return b""
        return self._chunks.pop(0)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class FetchCeilings(unittest.TestCase):
    # The ceilings this helper reads under, with the numbers they were set
    # against. A ceiling under what the service really sends is an outage
    # nobody would think to look for, so the measured sizes are pinned here.
    def test_ceiling_constants_leave_measured_room(self):
        # Measured live: capabilities 604,251 B; GetFeatureInfo 758 B; legend
        # PNG 1,610 B. The probe's success bodies are tiny, but a
        # ServiceException XML answer runs bigger — hence 4 KiB, not 1 KiB.
        self.assertGreaterEqual(cams.CAPABILITIES_MAX_BYTES, 906_376)
        self.assertGreaterEqual(cams.PROBE_MAX_BYTES, 4 * 1024)
        self.assertGreaterEqual(cams.LEGEND_MAX_BYTES, 64 * 1024)

    def test_one_way_to_read_the_network(self):
        # The QML-side stream inventory holds cams.py to a single urlopen,
        # behind fetch_bytes's per-chunk budget. If a second read appears
        # here, it appeared without a ceiling.
        source = (TEST_ROOT.parent / "cams.py").read_text(encoding="utf-8")
        self.assertEqual(source.count("urlopen("), 1)

    def test_fetch_bytes_passes_small_responses_through(self):
        with mock.patch.object(cams.urllib.request, "urlopen",
                               return_value=_FakeResponse([b"Value: 6.4 ug/m3"])):
            self.assertEqual(cams.fetch_bytes("https://example.invalid/x", 1,
                                              cams.PROBE_MAX_BYTES),
                             b"Value: 6.4 ug/m3")

    def test_fetch_bytes_rejects_over_the_ceiling(self):
        # One chunk under the ceiling plus any more at all is over it: the
        # budget is checked as chunks arrive, not after assembly.
        under = b"x" * (cams.PROBE_MAX_BYTES - 1)
        with mock.patch.object(cams.urllib.request, "urlopen",
                               return_value=_FakeResponse([under, b"tail"])):
            with self.assertRaises(ValueError):
                cams.fetch_bytes("https://example.invalid/x", 1, cams.PROBE_MAX_BYTES)

    def test_probe_degrades_to_no_value_when_the_answer_overflows(self):
        # An overflowing body is a bad answer, not a crash: the panel shows
        # "…" and the next probe retries, like any other network failure.
        with mock.patch.object(cams.urllib.request, "urlopen",
                               return_value=_FakeResponse([b"y" * 9_000])):
            reading = cams.probe_value("composition_europe_pm2p5_forecast_surface",
                                       "", 51.5, -0.1, "2026-01-01T00:00:00Z")
        self.assertEqual(reading, {"value": None, "unit": ""})


if __name__ == "__main__":
    unittest.main(verbosity=2)
