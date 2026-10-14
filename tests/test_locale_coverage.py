"""Locale coverage (ARCHITECTURE.md §0.7): every dictionary key the resource can show exists in both
locales/en.json (key -> English) and locales/ar.json (key -> key, the Arabic source).

Keys are the Arabic source text, so every Arabic string literal in config/, shared/, client/ and
server/ is a key: the locale(...) / L(...) arguments, the label / title / text / description fields,
the strings tables sent to the NUI (WCEditor.STRINGS, CARD_STRINGS, ...), notices and result
messages. The only Arabic literals that are not keys are the server's log texts (read by staff in
the logging resource, never translated): see LOG_ONLY below. Every locale(...) / L(...) call with a
literal argument must name a key whatever its script.

w_medic (when the repository is next to this one): every dotted key its Lua passes to
locale(...) or keeps in a key table exists in both of its dictionaries.
"""
import json
import re
import unittest

from lua_source import RESOURCE, code_only, lua_files, read, tokens

ARABIC = re.compile('[؀-ۿ]')
LOCALE_CALL = re.compile(r'\b(?:locale|L)\(\s*$')

# Server log texts (not player-visible, not translated): the literal follows one of these in the
# same statement. Each pattern is matched against the code just before the literal.
LOG_ONLY = (
    re.compile(r'\breason\s*=\s*(?:[^,{}()]*\b(?:and|or)\s*)?$'),        # log payload `reason = '...'`
    re.compile(r'\bdescription\s*=\s*$'),                                  # logger.RegisterLogType
    re.compile(r'\b(?:denied|logBucket)\([^()]*$'),                        # server log helpers
    re.compile(r'\blogBucket\([^()]*\b(?:and|or)\s*$'),
)
LOG_FILES = ('server/',)


def dictionaries():
    en = json.loads(read(RESOURCE / 'locales' / 'en.json'))
    ar = json.loads(read(RESOURCE / 'locales' / 'ar.json'))
    return en, ar


def used_keys():
    """{key: ['file:line', ...]} of every Arabic literal and every literal locale()/L() argument."""
    out = {}
    for path in lua_files():
        rel = path.relative_to(RESOURCE).as_posix()   # LOG_FILES is written with '/'
        src = read(path)
        blanked = code_only(src)
        for kind, value, line, start in tokens(src):
            if kind != 'string':
                continue
            before = blanked[max(0, start - 160):start]
            before_line = before.split('\n')[-1]
            is_call_arg = LOCALE_CALL.search(before_line) is not None
            if not ARABIC.search(value) and not is_call_arg:
                continue
            if not is_call_arg and rel.startswith(LOG_FILES) and any(p.search(before_line) for p in LOG_ONLY):
                continue
            out.setdefault(value, []).append('%s:%d' % (rel, line))
    return out


class LocaleCoverageTests(unittest.TestCase):
    def test_every_key_exists_in_both_dictionaries(self):
        en, ar = dictionaries()
        keys = used_keys()
        self.assertGreater(len(keys), 300)
        missing_en = sorted('%s  (%s)' % (k, v[0]) for k, v in keys.items() if k not in en)
        missing_ar = sorted('%s  (%s)' % (k, v[0]) for k, v in keys.items() if k not in ar)
        self.assertEqual(missing_en, [], 'keys missing from locales/en.json')
        self.assertEqual(missing_ar, [], 'keys missing from locales/ar.json')

    def test_dictionaries_have_the_same_keys(self):
        en, ar = dictionaries()
        self.assertEqual(sorted(set(en) ^ set(ar)), [])

    def test_ar_maps_every_key_to_itself(self):
        _, ar = dictionaries()
        self.assertEqual([k for k, v in ar.items() if k != v], [])

    def test_translations_are_non_empty_and_keep_placeholders(self):
        en, _ = dictionaries()
        spec = re.compile(r'%[-0-9.]*[sdif]')
        bad = [k for k, v in en.items()
               if not isinstance(v, str) or not v.strip() or spec.findall(k) != spec.findall(v)]
        self.assertEqual(bad, [])

    def test_dictionaries_are_sorted(self):
        en, ar = dictionaries()
        self.assertEqual(list(en), sorted(en))
        self.assertEqual(list(ar), sorted(ar))

    def test_no_pending_queue_is_left(self):
        self.assertFalse((RESOURCE / 'locales' / 'pending').exists())

    def test_log_exclusions_only_cover_server_log_texts(self):
        # the exclusion must not hide a player-visible key: every excluded literal sits in a
        # server file and is not passed to locale / L / notify
        for path in lua_files(('server',)):
            src = read(path)
            blanked = code_only(src)
            for kind, value, line, start in tokens(src):
                if kind != 'string' or not ARABIC.search(value):
                    continue
                before_line = blanked[max(0, start - 160):start].split('\n')[-1]
                if any(p.search(before_line) for p in LOG_ONLY):
                    self.assertNotRegex(before_line, r'(?:locale|L|Notify|notify)\(',
                                        '%s:%d' % (path.relative_to(RESOURCE), line))


AMBULANCE = RESOURCE.parent / 'w_medic'
DOTTED = re.compile(r"""['"]((?:info|error|success|text|prompt|menu|damage|body|states|progress|mail|label|"""
                    r"""blip|target|command|notify)\.[a-z_0-9.]+)['"]""")


def flatten(d, prefix=''):
    out = {}
    for k, v in d.items():
        if isinstance(v, dict):
            out.update(flatten(v, prefix + k + '.'))
        else:
            out[prefix + k] = v
    return out


@unittest.skipUnless((AMBULANCE / 'locales' / 'en.json').exists(), 'w_medic not checked out')
class AmbulanceLocaleTests(unittest.TestCase):
    def test_dotted_keys_exist_in_both_dictionaries(self):
        en = flatten(json.loads(read(AMBULANCE / 'locales' / 'en.json')))
        ar = flatten(json.loads(read(AMBULANCE / 'locales' / 'ar.json')))
        self.assertEqual(sorted(set(en) ^ set(ar)), [])
        used = {}
        for path in sorted(AMBULANCE.rglob('*.lua')):
            src = code_only(read(path), keep_strings=True)
            for m in re.finditer(r"""\blocale\(\s*['"]([^'"]+)['"]""", src):
                used.setdefault(m.group(1), str(path.relative_to(AMBULANCE)))
            for m in DOTTED.finditer(src):
                used.setdefault(m.group(1), str(path.relative_to(AMBULANCE)))
        self.assertGreater(len(used), 50)
        # a key ending in '_' is the prefix of one built in code ('jobs.err_' .. reason), not a key
        missing = sorted('%s (%s)' % (k, f) for k, f in used.items()
                         if not k.endswith('_') and (k not in en or k not in ar))
        self.assertEqual(missing, [])

    def test_cosmetic_surgery_keys(self):
        en = flatten(json.loads(read(AMBULANCE / 'locales' / 'en.json')))
        ar = flatten(json.loads(read(AMBULANCE / 'locales' / 'ar.json')))
        for key in ('text.surgery', 'prompt.cosmetic_surgery', 'error.surgery_unavailable'):
            self.assertIn(key, en)
            self.assertIn(key, ar)


if __name__ == '__main__':
    unittest.main()
