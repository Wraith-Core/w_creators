"""WCIdentity (ARCHITECTURE.md §6.3)."""
import datetime
import unittest

from harness import Runtime


class IdentityTests(unittest.TestCase):
    def setUp(self):
        self.rt = Runtime().load_shared()
        self.name = self.rt.eval('function(s) return WCIdentity.validateName(s) end')
        self.dob = self.rt.eval('function(s) return WCIdentity.validateDob(s) end')

    def test_valid_names(self):
        for raw, cleaned in [('Arthur', 'Arthur'), ('  Dutch  ', 'Dutch'), ("O'Driscoll", "O'Driscoll"),
                             ('Van der  Linde', 'Van der Linde'), ('Anne-Marie', 'Anne-Marie'),
                             ('José', 'José'), ('Zoë', 'Zoë'), ('محمد', 'محمد'), ('عبد الله', 'عبد الله'),
                             ('Jo', 'Jo'), ('مُحَمَّد', 'مُحَمَّد'), ('a' * 25, 'a' * 25), ('ک' * 3, 'ک' * 3)]:
            ok, value = self.name(raw)
            self.assertTrue(ok, raw)
            self.assertEqual(value, cleaned)

    def test_invalid_names(self):
        for raw in ['', ' ', 'A', 'a' * 26, 'John3', 'R2D2', 'Bob!', 'Al_Capone', 'John😀', 'Jean.', '-Ann',
                    "Ann'", 'x×y', '١٢٣', 'ُمحمد', 'محمد ُ', '\xff', None, 42, 'Tab\there\x00']:
            ok, code = self.name(raw)
            self.assertFalse(ok, repr(raw))
            self.assertEqual(code, 'INVALID_NAME')
        # invalid UTF-8 bytes from Lua
        self.assertFalse(self.rt.eval('(WCIdentity.validateName("ab\\xc3"))'))

    def test_arabic_letter_count_is_characters_not_bytes(self):
        ok, _ = self.name('ب' * 25)
        self.assertTrue(ok)
        ok, _ = self.name('ب' * 26)
        self.assertFalse(ok)

    def test_dob_calendar(self):
        self.rt.run('Config.Characters.identity.referenceYear = 1899')
        ok, dob, age = self.dob('1870-02-28')
        self.assertTrue(ok)
        self.assertEqual((dob, age), ('1870-02-28', 29))
        self.assertTrue(self.dob('1872-02-29')[0])      # leap year
        self.assertFalse(self.dob('1870-02-29')[0])     # not a leap year
        self.assertFalse(self.dob('1800-02-29')[0])     # centuries are not leap years
        self.assertTrue(self.dob('1860-04-30')[0])
        self.assertFalse(self.dob('1860-04-31')[0])
        self.assertFalse(self.dob('1860-13-01')[0])
        self.assertFalse(self.dob('1860-00-10')[0])
        self.assertFalse(self.dob('1860-1-5')[0])
        self.assertFalse(self.dob('05/01/1860')[0])
        self.assertFalse(self.dob('1882-01-01')[0])     # 17 < minAge
        self.assertTrue(self.dob('1881-12-31')[0])      # 18
        self.assertFalse(self.dob('1808-01-01')[0])     # 91 > maxAge
        self.assertEqual(self.dob('garbage')[1], 'INVALID_DOB')
        self.assertFalse(self.dob(None)[0])

    def test_dob_against_the_real_date(self):
        self.rt.run('Config.Characters.identity.referenceYear = nil')
        today = datetime.date.today()
        born = today.replace(year=today.year - 30)
        ok, _, age = self.dob(born.isoformat())
        self.assertTrue(ok)
        self.assertEqual(age, 30)
        tomorrow = today + datetime.timedelta(days=1)
        try:
            eighteen = tomorrow.replace(year=tomorrow.year - 18)
        except ValueError:
            eighteen = tomorrow.replace(year=tomorrow.year - 18, day=28)
        self.assertFalse(self.dob(eighteen.isoformat())[0])  # turns 18 tomorrow

    def test_validate(self):
        self.rt.run('Config.Characters.identity.referenceYear = 1899')
        self.rt.run('ok, v = WCIdentity.validate({ firstname = " Sadie ", lastname = "Adler", dob = "1870-05-05", sex = "x" })')
        self.assertTrue(self.rt.eval('ok'))
        self.assertEqual(self.rt.py(self.rt.eval('v')), {'firstname': 'Sadie', 'lastname': 'Adler', 'dob': '1870-05-05', 'age': 29})
        self.assertEqual(self.rt.eval('select(2, WCIdentity.validate({ firstname = "S4die", lastname = "A", dob = "x" }))'), 'INVALID_NAME')
        self.assertEqual(self.rt.eval('select(2, WCIdentity.validate({ firstname = "Sadie", lastname = "Adler", dob = "x" }))'), 'INVALID_DOB')
        self.assertEqual(self.rt.eval('select(2, WCIdentity.validate("x"))'), 'INVALID_PAYLOAD')


if __name__ == '__main__':
    unittest.main()
