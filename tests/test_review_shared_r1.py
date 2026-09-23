"""Review round 1, area "shared": regression tests.

1. Stored dyes survive Config.Clothing.tints being disabled / narrowed (sanitize rules = false checks
   tints structurally; the live config governs new tints only).
2. sql/install.sql never pre-fills the migration ledger, so a pre-v3 database that imports it still
   gets the v3 columns.
3. Overlay groups never repeat their parent's label (Complexion > Complexion, Eyebrows > Eyebrows).
4. docs/NATIVES.md matches the code (Used-by cells, refresh count, resurrect handle, TESTING.md).
5. Config.Experimental comments do not promise behaviour no code implements.
"""
import json
import re
import unittest

from harness import RESOURCE, Runtime, read
from test_editor_lua import CLIENT
from test_server_core import server

TINT_SETUP = r'''
local a = S.default('male')
a.clothing.equipped.boots = a.clothing.equipped.boots or h('male', 'boots', 1)
a.clothing.tints.boots = { palette = 'metaped_tint_leather', tint0 = 3, tint1 = 4, tint2 = 5 }
rows['vorp:1'].appearance = json.encode(a)
stored = a
'''


WRITTEN_TINTS = r'''
return (function()
    for i = #FakeDB.queries, 1, -1 do
        local q = FakeDB.queries[i]
        if q.sql and q.sql:find('UPDATE') and q.sql:find('appearance') then
            for _, v in pairs(q.params or {}) do
                if type(v) == 'string' and v:sub(1, 1) == '{' and v:find('"clothing"') then
                    return v
                end
            end
        end
    end
end)()
'''


def written_tints(rt):
    """The clothing.tints of the appearance JSON in the last UPDATE the repository sent."""
    raw = rt.run(WRITTEN_TINTS)
    if raw is None:
        return None
    return json.loads(raw)['clothing'].get('tints') or {}


class StoredTintTests(unittest.TestCase):
    def setUp(self):
        self.rt = server()
        self.rt.run(TINT_SETUP)
        self.e = self.rt.eval

    def load_save(self):
        self.rt.run('''
            app, meta = WCAppearanceRepo.load('vorp:1')
            saveOk = WCAppearanceRepo.save('vorp:1', app)
        ''')
        self.assertTrue(self.e('saveOk'))
        return written_tints(self.rt)

    def test_disabled_tints_do_not_erase_a_stored_dye(self):
        self.rt.run('Config.Clothing.tints.enabled = false')
        tints = self.load_save()
        self.assertIsNotNone(tints)
        self.assertEqual(tints.get('boots'), {'palette': 'metaped_tint_leather', 'tint0': 3, 'tint1': 4, 'tint2': 5})
        self.assertFalse(self.e('meta.degraded'))
        self.assertEqual(self.e('app.clothing.tints.boots.palette'), 'metaped_tint_leather')

    def test_narrowed_palettes_do_not_erase_a_stored_dye(self):
        self.rt.run("Config.Clothing.tints.palettes.boots = { 'metaped_tint_generic_clean' }")
        tints = self.load_save()
        self.assertEqual(tints.get('boots', {}).get('palette'), 'metaped_tint_leather')
        self.rt.run("Config.Clothing.tints.palettes.boots = false")
        tints = self.load_save()
        self.assertEqual(tints.get('boots', {}).get('palette'), 'metaped_tint_leather')

    def test_stored_tints_are_still_checked_structurally(self):
        e = self.e
        self.assertTrue(e("WCCatalog.validStoredTint('boots', { palette = 'metaped_tint_leather', tint0 = 0, tint1 = 254, tint2 = 1 })"))
        self.assertFalse(e("WCCatalog.validStoredTint('boots', { palette = 'not_a_palette', tint0 = 0, tint1 = 0, tint2 = 0 })"))
        self.assertFalse(e("WCCatalog.validStoredTint('boots', { palette = 'metaped_tint_leather', tint0 = 255, tint1 = 0, tint2 = 0 })"))
        self.assertFalse(e("WCCatalog.validStoredTint('boots', { palette = 'metaped_tint_leather', tint0 = 1.5, tint1 = 0, tint2 = 0 })"))
        self.assertFalse(e("WCCatalog.validStoredTint('heads', { palette = 'metaped_tint_leather', tint0 = 0, tint1 = 0, tint2 = 0 })"))
        self.assertFalse(e("WCCatalog.validStoredTint('boots', nil)"))
        # A tint of an item that is not worn is still dropped.
        self.rt.run("local x = S.copy and S.copy(stored) or json.decode(json.encode(stored)) x.clothing.equipped.boots = nil "
                    "out = S.sanitize(x, { rules = false })")
        self.assertIsNone(e('out.clothing.tints.boots'))

    def test_new_edits_still_follow_the_live_config(self):
        self.rt.run('Config.Clothing.tints.enabled = false')
        e = self.e
        # The edit mode of sanitize (client-submitted appearances) applies the config.
        self.rt.run('edited = S.sanitize(stored)')
        self.assertIsNone(e('edited.clothing.tints.boots'))
        # WCCatalog.validTint (store plan, SetClothes, owned tints) refuses the tint.
        self.assertFalse(e("WCCatalog.validTint('boots', stored.clothing.tints.boots)"))
        # mergeSections: the saved item with its saved tint keeps it; a changed tint is refused.
        self.rt.run('kept = S.mergeSections(stored, stored, { clothing = true })')
        self.assertEqual(e('kept.clothing.tints.boots.tint0'), 3)
        self.rt.run('''
            draft = json.decode(json.encode(stored))
            draft.clothing.tints.boots.tint0 = 9
            changed = S.mergeSections(stored, draft, { clothing = true })
        ''')
        self.assertIsNone(e('changed.clothing.tints.boots'))
        # Enabled again, the same change goes through.
        self.rt.run('Config.Clothing.tints.enabled = true  changed = S.mergeSections(stored, draft, { clothing = true })')
        self.assertEqual(e('changed.clothing.tints.boots.tint0'), 9)

    def test_legacy_projection_and_normalize_keep_the_dye(self):
        self.rt.run('Config.Clothing.tints.enabled = false  n = S.normalize(json.encode(stored))')
        self.assertEqual(self.e('n.clothing.tints.boots.palette'), 'metaped_tint_leather')


class InstallSqlLedgerTests(unittest.TestCase):
    def test_install_sql_records_no_migration(self):
        sql = read(RESOURCE / 'sql' / 'install.sql')
        self.assertNotRegex(sql.upper(), r'INSERT\s+(IGNORE\s+)?INTO\s+`?W_CREATORS_MIGRATIONS')
        self.assertIn('CREATE TABLE IF NOT EXISTS `w_creators_migrations`', sql)

    def test_pre_v3_database_that_imported_install_sql_still_migrates(self):
        rt = Runtime().load_server_core()
        # A pre-v3 database after importing install.sql: CREATE TABLE IF NOT EXISTS left the pre-v3
        # tables as they were, the outfits table and an (empty) ledger were created.
        rt.run('''
            FakeDB.schema.characters_appearence = { id = true, charid = true, isMale = true, name = true, age = true,
                                                    faceFeatures = true, overlays = true, components = true }
            FakeDB.schema.w_creators_clothes = { id = true, charid = true, hash = true, category = true,
                                                 palette = true, tint0 = true, tint1 = true, tint2 = true }
            FakeDB.schema.w_creators_outfits = { id = true, charid = true, name = true, data = true,
                                                 created_at = true, updated_at = true }
            FakeDB.schema.w_creators_migrations = { id = true, applied_at = true }
            FakeDB.fireReady()
        ''')
        self.assertTrue(rt.eval('WCMigrations.ok'))
        for table, col in (('characters_appearence', 'appearance'), ('characters_appearence', 'appearance_version'),
                           ('characters_appearence', 'updated_at'), ('w_creators_clothes', 'source'),
                           ('w_creators_clothes', 'acquired_at')):
            self.assertTrue(rt.eval('WCMigrations.columnExists("%s", "%s")' % (table, col)), col)

    def test_fresh_install_sql_database_reruns_as_no_ops(self):
        rt = Runtime().load_server_core()
        rt.run('FakeDB.fireReady()')
        full = rt.py(rt.eval('FakeDB.schema'))
        rt2 = Runtime().load_server_core()
        rt2.g.FakeDB.schema = rt2.table({t: rt2.table(dict(c)) for t, c in full.items()})
        rt2.run('FakeDB.fireReady()')
        self.assertTrue(rt2.eval('WCMigrations.ok'))
        self.assertEqual(rt2.eval('FakeDB.count("ALTER TABLE")'), 0)


class OverlayLabelTests(unittest.TestCase):
    def setUp(self):
        self.rt = Runtime()
        self.rt.load_shared()
        self.rt.run(CLIENT)
        self.rt.load('client/editor/tree.lua', 'client/editor/editor.lua', 'client/editor/panel.lua')

    def repeated(self, sex):
        self.rt.eval("openEditor('creator', '%s', { identity = {} })" % sex)
        self.rt.run('''
            Repeats = {}
            local function walk(node, parentLabel)
                if node.kind == 'group' and parentLabel ~= nil and node.label == parentLabel then
                    Repeats[#Repeats + 1] = node.id
                end
                for _, c in ipairs(node.children or {}) do walk(c, node.kind == 'group' and node.label or nil) end
            end
            walk(lastPayload().tree, nil)
        ''')
        r = self.rt.eval('Repeats')
        return [r[i] for i in range(1, len(r) + 1)]

    def test_no_group_repeats_its_parents_label(self):
        for sex in ('male', 'female'):
            self.assertEqual(self.repeated(sex), [], sex)

    def test_new_labels_are_translated(self):
        en = json.loads(read(RESOURCE / 'locales' / 'en.json'))
        ar = json.loads(read(RESOURCE / 'locales' / 'ar.json'))
        for layer in ('complex', 'eyebrows'):
            label = self.rt.eval('WCOverlays.byId.%s.label' % layer)
            self.assertIn(label, en)
            self.assertIn(label, ar)
        self.assertNotEqual(en[self.rt.eval('WCOverlays.byId.complex.label')], en['البشرة'])
        self.assertNotEqual(en[self.rt.eval('WCOverlays.byId.eyebrows.label')], en['الحاجبان'])


class NativesDocTests(unittest.TestCase):
    def setUp(self):
        self.doc = read(RESOURCE / 'docs' / 'NATIVES.md')

    def row(self, wrapper):
        for line in self.doc.splitlines():
            if line.startswith('|') and wrapper in line:
                return line
        self.fail(wrapper)

    def lua_sources(self, exclude_natives=True):
        for path in sorted(RESOURCE.rglob('*.lua')):
            rel = path.relative_to(RESOURCE).as_posix()
            if 'node_modules' in rel or rel.startswith('tests/'):
                continue
            if exclude_natives and rel.startswith('client/natives/'):
                continue
            yield rel, read(path)

    def test_used_by_cells_match_the_callers(self):
        callers = [rel for rel, src in self.lua_sources() if 'placeOnGround' in src]
        self.assertEqual(callers, ['client/scene/scene.lua'])
        self.assertNotIn('spawn', self.row('WCNative.ped.placeOnGround').split('|')[5])
        for fn in ('applyShopItem', 'removeTag'):
            self.assertEqual([rel for rel, src in self.lua_sources() if 'WCNative.clothing.' + fn in src], [])
            cell = self.row('WCNative.clothing.' + fn).split('|')[5]
            self.assertIn('nothing', cell)
            self.assertNotIn('fallback of', cell)

    def test_refresh_count_and_resurrect_handle(self):
        header = read(RESOURCE / 'client' / 'appearance' / 'pipeline.lua').split('Appearance = {}')[0]
        self.assertIn('three', header)
        refresh = self.row('WCNative.ped.refresh(ped)')
        self.assertNotIn('once per apply', refresh)
        self.assertIn('three per full render', refresh)
        resurrect = self.row('WCNative.respawn.resurrect')
        self.assertNotIn('The ped handle changes', resurrect)
        self.assertIn('PlayerPedId()', resurrect)

    def test_testing_md_exists_for_every_reference(self):
        self.assertTrue((RESOURCE / 'docs' / 'TESTING.md').exists())
        arch = read(RESOURCE / 'docs' / 'ARCHITECTURE.md')
        listed = re.search(r'docs/\s+(.*?)\n\s+tests/', arch, re.S).group(1)
        for name in re.findall(r'[A-Z_]+\.md', listed):
            self.assertTrue((RESOURCE / 'docs' / name).exists(), name)

    def test_experimental_definition_names_the_dev_tools_gate(self):
        definition = self.row('| **Experimental** |')
        self.assertIn('Config.Admin.devTools', definition)


class ExperimentalConfigTests(unittest.TestCase):
    def test_flags_without_a_production_reader_say_so(self):
        cfg = read(RESOURCE / 'config' / 'main.lua')
        block = re.search(r'Config\.Experimental = \{(.*?)\n\}', cfg, re.S).group(1)
        self.assertNotIn('instead of by model', block)
        sources = {p.relative_to(RESOURCE).as_posix(): read(p) for p in RESOURCE.rglob('*.lua')
                   if not p.relative_to(RESOURCE).as_posix().startswith(('tests/', 'client/natives/', 'config/'))
                   and 'node_modules' not in p.as_posix()}
        for flag in re.findall(r'^\s+(\w+)\s*=\s*false,', block, re.M):
            readers = [rel for rel, src in sources.items() if 'Experimental.' + flag in src]
            comment = block.split(flag + ' =')[0].rsplit(',', 1)[-1]
            if readers:
                continue
            self.assertIn('no production path', comment, flag)


if __name__ == '__main__':
    unittest.main()
