"""WCClothing.actionList (client/clothing/states.lua): the rows the radial menu (w_wheel) draws.

Each row names its garment, so the wheel shows one picture per garment ("what I have on me"): the
rows of one garment share itemId, `category` is the worn category (a cloak under the poncho group),
`icon` / `iconUrl` its own clothing icon from the taxonomy, `name` its catalogue name as the store
writes it, `stateShort` the word for a non-default state. The body-part fix's states are read as
words: the game's raw state name ('base_coat_open_glove') is never shown.

Run: python3 -m unittest discover -s tests -p 'test_client_states_*.py'
"""
import re
import unittest

from test_client_states_support import make_states_client, lua_list

# the game's wearable-state lists, per worn item (the natives answer nothing in the fake client)
STATES = r'''
StateLists = {}
WCNative.clothing.wearableStates = function(hash, wearer) return StateLists[WCUtil.u32(hash)] end
function stateHash(n) return WCUtil.u32(GetHashKey(n)) end
function pick(category, model, variant) return WCCatalog.resolve('male', category, { model, variant }) end
'''

# what an old label looked like: a game state name, alone or after "<part>: "
RAW = re.compile(r'(^|[\s:])[a-z0-9]+_[a-z0-9_]+|^[a-z0-9_]+$')
CLOTH = '/web/build/tex/cloth/'


class WheelRowsTests(unittest.TestCase):
    def setUp(self):
        self.rt = make_states_client()
        self.rt.run(STATES)

    def rows(self):
        result = self.rt.eval('WCClothing.actionList()')
        self.assertEqual(result['status'], 'ok')
        return [{key: row[key] for key in row.keys()} for row in lua_list(result['rows'])]

    def dress(self, lua):
        self.rt.run('local a = WCState.appearance\n' + lua)

    def test_one_garment_shares_its_id_icon_and_catalogue_name(self):
        self.dress('''
            a.clothing.equipped.hats = pick('hats', 3, 1)
            a.clothing.equipped.shirts_full = pick('shirts_full', 1, 2)
            a.clothing.states = { sleeves = 'rolled' }
        ''')
        rows = self.rows()
        shirt = [r for r in rows if r['itemId'] == 'shirts_full']
        self.assertEqual([r['group'] for r in shirt], ['sleeves', 'collar', 'shirt'])
        for row in shirt:
            self.assertEqual(row['category'], 'shirts_full')
            self.assertEqual(row['icon'], 'shirt')
            self.assertTrue(row['iconUrl'].startswith('nui://'), row['iconUrl'])
            self.assertTrue(row['iconUrl'].endswith(CLOTH + 'shirt.png'), row['iconUrl'])
            self.assertEqual(row['name'], 'القميص 01 · 02')
            self.assertEqual(row['categoryLabel'], 'القميص')
            self.assertEqual(row['section'], 'الجزء العلوي')
            self.assertEqual(row['kind'], 'garment')
        # the rolled sleeves say so on the bubble; the collar at its usual state says nothing
        self.assertEqual({r['group']: r['stateShort'] for r in shirt},
                         {'sleeves': 'مشمّرة', 'collar': '', 'shirt': ''})
        hat = [r for r in rows if r['group'] == 'hat'][0]
        self.assertEqual((hat['itemId'], hat['icon'], hat['name'], hat['section']),
                         ('hats', 'hat', 'القبعة 03 · 01', 'الرأس'))

    def test_a_garment_taken_off_keeps_its_picture_and_no_state_word(self):
        self.dress("a.clothing.states = { hat = 'off' }")
        hat = [r for r in self.rows() if r['group'] == 'hat']
        self.assertEqual([(r['value'], r['current'], r['stateShort'], r['icon']) for r in hat],
                         [('on', 'off', '', 'hat')])

    def test_the_worn_category_names_the_picture_not_the_state_group(self):
        # a cloak is worn under the poncho group: the cloak's own picture and name
        self.dress("a.clothing.equipped.cloaks = 7778; a.clothing.equipped.loadouts = 7777")
        rows = {r['group']: r for r in self.rows()}
        self.assertEqual((rows['poncho']['category'], rows['poncho']['icon'], rows['poncho']['categoryLabel']),
                         ('cloaks', 'cloak', 'العباءة'))
        self.assertEqual((rows['loadout']['category'], rows['loadout']['icon']), ('loadouts', 'bandolier'))
        # a hash the catalogue does not know has no catalogue name (the wheel shows the category)
        self.assertEqual(rows['poncho']['name'], '')

    def test_body_states_are_words_never_the_game_name(self):
        self.dress('''
            StateLists[WCUtil.u32(a.body.upper)] = { stateHash('base'), stateHash('base_coat_open_glove'),
                stateHash('open_collar_rolled_sleeve_vest'), stateHash('dummy') }
        ''')
        body = [r for r in self.rows() if r['group'] == 'bodyUpper']
        labels = {r['value']: r['label'] for r in body}
        self.assertEqual(labels['base_coat_open_glove'], 'المعطف مفتوح، قفاز')
        self.assertEqual(labels['open_collar_rolled_sleeve_vest'], 'الياقة مفتوحة، أكمام مشمّرة، مع الصديري')
        # no known word: the body part's name and its place in the list
        self.assertRegex(labels['dummy'], r'^الجزء العلوي من الجسم \d\d$')
        for row in body:
            self.assertEqual((row['kind'], row['icon'], row['iconUrl'], row['itemId']), ('body', '', '', 'bodyUpper'))
            for key in ('label', 'item', 'name', 'categoryLabel', 'section', 'stateShort'):
                self.assertIsNone(RAW.search(row[key] or ''), '%s=%r' % (key, row[key]))


if __name__ == '__main__':
    unittest.main()
