"""Every Arabic dictionary key used by the v3 config/shared code is translated in locales/en.json or
queued in locales/pending/*.json (merged by the release step)."""
import json
import re
import unittest

from harness import RESOURCE, read

ARABIC = re.compile(r"'([^'\n]*[؀-ۿ][^'\n]*)'|\"([^\"\n]*[؀-ۿ][^\"\n]*)\"")


def known_keys():
    keys = set(json.loads(read(RESOURCE / 'locales' / 'en.json')))
    for path in sorted((RESOURCE / 'locales' / 'pending').glob('*.json')):
        keys |= set(json.loads(read(path)))
    return keys


class LocaleKeyTests(unittest.TestCase):
    def test_pending_files_are_flat_string_maps(self):
        for path in sorted((RESOURCE / 'locales' / 'pending').glob('*.json')):
            data = json.loads(read(path))
            self.assertTrue(all(isinstance(k, str) and isinstance(v, str) and v for k, v in data.items()), path.name)

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
