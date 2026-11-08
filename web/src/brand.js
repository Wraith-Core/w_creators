// The masthead's wordmark. 1.1.0: it comes from the locales like every other word (payload.strings.brand,
// client/editor/editor.lua STRINGS.brand): "ريد ريفر · استوديو الشخصيات" in Arabic, the Latin mark in English.
// No fixed English text on the page any more.
export const brandOf = S => (S && S.brand) || '';
