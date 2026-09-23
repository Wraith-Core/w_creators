"""Every Arabic dictionary key used by the v3 config/shared code is translated in locales/en.json
(the per-module locales/pending/*.json queues were merged by the release step and removed)."""
import json
import re
import unittest

from harness import RESOURCE, read

ARABIC = re.compile(r"'([^'\n]*[؀-ۿ][^'\n]*)'|\"([^\"\n]*[؀-ۿ][^\"\n]*)\"")


def known_keys():
    return set(json.loads(read(RESOURCE / 'locales' / 'en.json')))


class LocaleKeyTests(unittest.TestCase):
    def test_no_pending_queue_is_left(self):
        self.assertFalse((RESOURCE / 'locales' / 'pending').exists())

    def test_dictionaries_are_flat_string_maps(self):
        for name in ('en.json', 'ar.json'):
            data = json.loads(read(RESOURCE / 'locales' / name))
            self.assertTrue(all(isinstance(k, str) and isinstance(v, str) and v for k, v in data.items()), name)

    def test_config_and_shared_keys_are_translated(self):
        keys = known_keys()
        missing = []
        for d in ('config', 'shared'):
            for path in sorted((RESOURCE / d).rglob('*.lua')):
                code = re.sub(r'--[^\n]*', '', read(path))
                for m in ARABIC.finditer(code):
                    key = m.group(1) or m.group(2)
                    if key not in keys:
                        missing.append('%s: %s' % (path.relative_to(RESOURCE), key))
        self.assertEqual(missing, [])


if __name__ == '__main__':
    unittest.main()
