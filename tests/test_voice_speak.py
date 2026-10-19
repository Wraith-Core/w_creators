"""The greet / antagonize relay (server/voice/speak.lua, 2026-10-19): the server picks the line, takes the
voice from the speaker's saved look (never from the client), tells only the players in range, and holds a
rate limit."""
import unittest

from harness import Runtime

SAID = '''(function()
    local out = {}
    for _, c in ipairs(Events.client) do
        if c.name == "w_creators:client:voiceSaid" then
            out[#out + 1] = { player = c.player, src = c.args[1], line = c.args[2], voice = c.args[3],
                              target = c.args[4], reply = c.args[5] }
        end
    end
    return out
end)()'''


class VoiceSpeakTests(unittest.TestCase):
    def setUp(self):
        self.rt = Runtime()
        self.rt.load_server_core()
        self.rt.load('config/voice.lua', 'server/voice/speak.lua')
        self.e = self.rt.eval
        self.rt.run('''Players[2] = { name = 'near', coords = vector3(10, 0, 0), bucket = 0 }
            Players[3] = { name = 'far', coords = vector3(200, 0, 0), bucket = 0 }
            local app = AppearanceSchema.default('female'); app.voice = 2
            WCSync.broadcast(1, app)
            Events.client = {}''')

    def said(self):
        return list(self.rt.py(self.e(SAID)).values())

    def speak(self, src, *args):
        self.rt.g.fireEvent('w_creators:server:voiceSpeak', src, *args)

    def test_a_greet_reaches_the_players_in_range_in_the_saved_voice(self):
        self.speak(1, 'greet', 55, False)
        said = self.said()
        self.assertEqual(sorted(s['player'] for s in said), [1, 2])          # 3 is 200 m away
        for s in said:
            self.assertEqual(s['src'], 1)
            self.assertEqual(s['voice'], '0859_A_F_M_CIV_POOR_WHITE_AGGRESSIVE_01')
            self.assertIn(s['line'], ('GREET_MALE', 'GREET_GENERAL_STRANGER', 'HOWS_IT_GOING'))
            self.assertIn(s['reply'], ('HOWS_IT_GOING', 'GREET_GENERAL_STRANGER'))
            self.assertEqual(s['target'], 55)
        self.assertEqual(len({s['line'] for s in said}), 1)                   # every player hears the same line

    def test_an_antagonize_to_a_woman_uses_the_female_lines(self):
        self.speak(1, 'antagonize', 0, True)
        for s in self.said():
            self.assertIn(s['line'], ('GENERIC_INSULT_MED_FEMALE', 'GENERIC_INSULT_HIGH_FEMALE', 'GENERIC_MOCK'))

    def test_an_unknown_kind_or_no_saved_look_says_nothing(self):
        self.speak(1, 'shout', 0, False)
        self.speak(2, 'greet', 0, False)                                      # player 2 has no saved look
        self.assertEqual(self.said(), [])

    def test_the_rate_limit_holds(self):
        self.speak(1, 'greet', 0, False)
        first = len(self.said())
        self.speak(1, 'greet', 0, False)
        self.assertEqual(len(self.said()), first)                             # within the cooldown: nothing
        self.rt.g.tick(3000)
        self.speak(1, 'greet', 0, False)
        self.assertEqual(len(self.said()), first * 2)


if __name__ == '__main__':
    unittest.main()
