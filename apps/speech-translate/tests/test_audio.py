import unittest

from speech_translate.audio import FRAME_BYTES, Segmenter
from speech_translate.config import Settings

VOICE = b"\x10\x20" * (FRAME_BYTES // 2)
SILENCE = bytes(FRAME_BYTES)


def segmenter(**kwargs):
    return Segmenter(lambda frame: frame.startswith(b"\x10\x20"), **kwargs)


class SegmenterTests(unittest.TestCase):
    def test_packet_boundaries_do_not_change_audio(self):
        pcm = SILENCE * 20 + VOICE * 20 + SILENCE * 20
        expected = segmenter().feed(pcm)
        split = segmenter()
        actual = []
        for offset in range(0, len(pcm), 142):
            actual.extend(split.feed(pcm[offset:offset + 142]))
        self.assertEqual(actual, expected)
        self.assertEqual(len(actual), 1)
        self.assertEqual(actual[0].start, 0.3)
        self.assertEqual(actual[0].end, 1.8)

    def test_silence_and_short_clicks_are_discarded(self):
        stream = segmenter()
        self.assertEqual(stream.feed(SILENCE * 100 + VOICE * 3 + SILENCE * 50), [])
        self.assertEqual(stream.flush(), [])

    def test_long_speech_is_bounded_and_not_duplicated(self):
        stream = segmenter(max_utterance_ms=1500)
        output = stream.feed(VOICE * 120)
        output += stream.flush()
        self.assertEqual(len(output), 3)
        self.assertEqual(b"".join(item.pcm for item in output), VOICE * 120)
        self.assertTrue(all(item.end - item.start <= 1.5 for item in output))

    def test_flush_preserves_final_partial_frame_and_is_idempotent(self):
        stream = segmenter()
        pcm = VOICE * 10 + VOICE[:100]
        self.assertEqual(stream.feed(pcm), [])
        output = stream.flush()
        self.assertEqual(len(output), 1)
        self.assertEqual(output[0].pcm, pcm)
        self.assertEqual(output[0].end, len(pcm) / 32000)
        self.assertEqual(stream.flush(), [])

    def test_reject_half_sample(self):
        with self.assertRaises(ValueError):
            segmenter().feed(b"\x01")

    def test_config_rejects_untranslated_models_and_missing_auth(self):
        for model in ("turbo", "large-v3-turbo", "small.en", "distil-large-v3"):
            with self.assertRaises(ValueError):
                Settings(token="x" * 32, model=model)
        with self.assertRaises(ValueError):
            Settings(token="")
        self.assertNotIn("x" * 32, repr(Settings(token="x" * 32)))
