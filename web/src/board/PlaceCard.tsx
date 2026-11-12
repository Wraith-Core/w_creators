/* ════════════════════════════════════════════════════════════════════════════
 * w_creators · board/PlaceCard.tsx - one place as the builders' notebook (2026-11-12)
 *
 *   في العالم        the place told as sentences, one per spot, in the order a player meets them:
 *                    the service point (J), the NPC, where the player stands, the book (clothing), the chair
 *                    (barber). Each line says where it is in words («فالنتاين · 12 م منك», Lua's lib.place),
 *                    red «لم يُحدَّد بعد» when missing, and its buttons: put it (op place: the w_lib placer, the
 *                    board steps aside and comes back), pick a chair of the map, remove it (op clear)
 *   الأساس           name · town · the NPC's look by name · how near the player must be (three choices) · on / blip
 *   خيارات متقدمة    folded: the NPC model typed, the exact radius, the clothing profiles, the place's id and
 *                    every spot's coordinates
 * Stops: f:label f:town f:look f:reach f:enabled f:blip f:adv · a:npcText a:radius a:store a:pricing ·
 *        sp:<what>:place|pick|clear · sp:chair:model
 * ════════════════════════════════════════════════════════════════════════════ */

import type { ReactNode } from 'react';
import type { Nav } from './cursor';
import { Btn, Field, NumField, Stepper, Switch, type Message } from './fields';
import { cls, Txt, useI18n } from './i18n';
import { GlyphAim, GlyphCross, GlyphPin } from './icons';
import {
  fmtSpot, labelOk, LABEL_MAX, MODEL_MAX, modelOk, radiusOk, REACH, STORY, townOk, TOWN_MAX, withValue,
  type BoardData, type Form, type Place, type SpotKind, type StoryKind, type WhereMap,
} from './model';

/** op place's `what`: a spot, or `pickChair` (aim at a chair already in the map) */
export type PlaceWhat = SpotKind | 'pickChair';

interface Props {
  place: Place;
  form: Form;
  board: BoardData;
  where: WhereMap;
  nav: Nav;
  busy: boolean;
  adv: boolean;
  setAdv: (on: boolean) => void;
  chairModel: string;
  setChairModel: (m: string) => void;
  patch: (p: Partial<Form>) => void;
  /** `model`: the prop for a new chair (one of board.chairModels) */
  onPlace: (what: PlaceWhat, model?: string) => void;
  onClear: (what: SpotKind) => void;
}

function Glyph({ children }: { children: ReactNode }) {
  return <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">{children}</svg>;
}
const PinGlyph = () => <Glyph><path d="M12 21c-3.6-4.3-5.6-7.4-5.6-10.1a5.6 5.6 0 0 1 11.2 0c0 2.7-2 5.8-5.6 10.1z" /><circle cx="12" cy="10.6" r="1.9" /></Glyph>;

export default function PlaceCard({ place, form, board, where, nav, busy, adv, setAdv, chairModel, setChairModel, patch, onPlace, onClear }: Props) {
  const { t, has } = useI18n();
  const bad = (show: boolean): Message | undefined => (show ? { text: t('err.invalid'), level: 'error' } : undefined);
  const clothing = place.type === 'clothing';
  const words = where[place.id] ?? {};
  const modelName = (m: string) => (has(`model.${m}`) ? t(`model.${m}`) : m);

  /* ── the NPC's look by name (any typed model stays, by its own name) ── */
  const lookOptions = withValue(board.npcModels[place.type], form.npcModel).map((m) => ({ value: m, label: modelName(m) }));
  /* ── how near: three choices; a saved value that is none of them stays as «مخصصة» ── */
  const reach = form.radius ?? 2;
  const reachOptions = REACH.map((r) => ({ value: String(r), label: t(`reach.${r}`) }));
  if (!REACH.includes(reach)) reachOptions.push({ value: String(reach), label: t('reach.custom', String(reach)) });
  /* ── the profiles: an empty one (the store's default) stays choosable as «-» ── */
  const profile = (list: string[], value: string) => {
    const opts = withValue(list, value).map((v) => ({ value: v, label: v }));
    return value.trim() === '' || opts.length === 0 ? [{ value: '', label: '-' }, ...opts] : opts;
  };
  const storeOptions = profile(board.profiles.store, form.storeProfile);
  const pricingOptions = profile(board.profiles.pricing, form.pricingProfile);
  const chairOptions = board.chairModels.map((m, i) => ({ value: m, label: t('chair.n', i + 1) }));

  const isSet = (k: StoryKind) => (k === 'coords' ? place.coords !== null : place[k] !== null);
  const sentence = (k: StoryKind) => (k === 'npc' ? t(`say.npc.${place.type}`) : t(`say.${k}`));

  const line = (k: StoryKind, n: number) => {
    const set = isSet(k);
    const w = words[k];
    // only the service point is a must; an unset NPC / stand / book / chair is optional
    const whereText = set ? (w ? w.t : t('where.set')) : k === 'coords' ? t('where.none') : t('where.opt');
    const chairWorld = k === 'chair' && place.chair?.kind === 'world';
    return (
      <li key={k} className={cls('wcb-st', !set && (k === 'coords' ? 'is-bad' : 'is-opt'))}>
        <span className="wcb-st-n"><b>{n}</b></span>
        <div className="wcb-st-body">
          <span className="wcb-st-say"><Txt s={sentence(k)} /></span>
          {k === 'npc' && set && <span className="wcb-st-sub"><Txt s={modelName(form.npcModel)} /></span>}
          {k === 'chair' && set && <span className="wcb-st-sub">{chairWorld ? t('spot.chairWorld') : t('chair.prop')}</span>}
          <span className={cls('wcb-st-where', !set && (k === 'coords' ? 'is-miss' : 'is-opt'))}><PinGlyph /><Txt s={whereText} /></span>
          {k === 'chair' && chairOptions.length > 1 && (
            <div className="wcb-st-pick">
              <Stepper id="sp:chair:model" nav={nav} label={t('chair.look')} options={chairOptions} value={chairModel}
                onChange={setChairModel} />
            </div>
          )}
          <div className="wf-btns">
            {k === 'coords' ? (
              <Btn id="sp:coords:place" nav={nav} icon={<GlyphPin />} label={t('btn.placePoint')} disabled={busy}
                onClick={() => onPlace('npc')} />
            ) : (
              <Btn id={`sp:${k}:place`} nav={nav} icon={<GlyphPin />} label={t(`btn.put${k.charAt(0).toUpperCase()}${k.slice(1)}`)}
                disabled={busy} onClick={() => onPlace(k, k === 'chair' ? chairModel : undefined)} />
            )}
            {k === 'chair' && (
              <Btn id="sp:chair:pick" nav={nav} icon={<GlyphAim />} label={t('btn.pickChair')} disabled={busy}
                onClick={() => onPlace('pickChair')} />
            )}
            {k !== 'coords' && set && (
              <Btn id={`sp:${k}:clear`} nav={nav} quiet icon={<GlyphCross />} label={t('btn.clear')} disabled={busy}
                onClick={() => onClear(k)} />
            )}
          </div>
        </div>
      </li>
    );
  };

  return (
    <div className="wf-page is-scroll wcb-nb">
      <div className="wf-sec">{t('sec.world')}</div>
      <ul className="wcb-story">{STORY[place.type].map((k, i) => line(k, i + 1))}</ul>

      <div className="wf-sec">{t('sec.basic')}</div>
      <div className="wf-grid">
        <Field id="f:label" nav={nav} label={t('field.label')} value={form.label} maxLength={LABEL_MAX}
          onChange={(v) => patch({ label: v })} msg={bad(!labelOk(form.label))} />
        <Field id="f:town" nav={nav} label={t('field.town')} value={form.town} maxLength={TOWN_MAX}
          onChange={(v) => patch({ town: v })} msg={bad(!townOk(form.town))} />
        <Stepper id="f:look" nav={nav} label={t('f.look')} options={lookOptions} value={form.npcModel}
          locked={lookOptions.length < 2} onChange={(v) => patch({ npcModel: v })} />
        <Stepper id="f:reach" nav={nav} label={t('f.reach')} options={reachOptions} value={String(reach)}
          onChange={(v) => patch({ radius: Number(v) })} msg={bad(!radiusOk(form.radius))} />
      </div>
      <div className="wf-switches">
        <Switch id="f:enabled" nav={nav} label={t('field.enabled')} on={form.enabled} onToggle={() => patch({ enabled: !form.enabled })} />
        <Switch id="f:blip" nav={nav} label={t('field.blip')} on={form.blip} onToggle={() => patch({ blip: !form.blip })} />
      </div>

      <button type="button" ref={nav.reg('f:adv')} onMouseEnter={nav.hover('f:adv')}
        className={cls('wcb-fold', nav.here('f:adv') && 'is-here', adv && 'is-open')} aria-expanded={adv}
        onClick={() => setAdv(!adv)}>
        <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" strokeWidth="1.8" aria-hidden="true"><path d="M6 9l6 6 6-6" /></svg>
        <span>{t('sec.adv')}</span>
      </button>
      {adv && (
        <div className="wcb-adv">
          <div className="wf-grid">
            <Field id="a:npcText" nav={nav} label={t('a.model')} latin value={form.npcModel} maxLength={MODEL_MAX}
              onChange={(v) => patch({ npcModel: v.trim() })} msg={bad(!modelOk(form.npcModel))} />
            <NumField id="a:radius" nav={nav} label={t('field.radius')} value={form.radius}
              onChange={(n) => patch({ radius: n })} msg={bad(!radiusOk(form.radius))} />
            {clothing && (
              <Stepper id="a:store" nav={nav} label={t('field.storeProfile')} latin options={storeOptions} value={form.storeProfile}
                locked={storeOptions.length < 2} onChange={(v) => patch({ storeProfile: v })} />
            )}
            {clothing && (
              <Stepper id="a:pricing" nav={nav} label={t('field.pricingProfile')} latin options={pricingOptions} value={form.pricingProfile}
                locked={pricingOptions.length < 2} onChange={(v) => patch({ pricingProfile: v })} />
            )}
          </div>
          <dl className="wcb-coords">
            <div><dt>{t('adv.id')}</dt><dd><bdi dir="ltr">{place.id}</bdi></dd></div>
            {STORY[place.type].map((k) => {
              const s = k === 'coords' ? place.coords : place[k];
              return s ? (
                <div key={k}><dt>{t(`what.${k}`)}</dt><dd><bdi dir="ltr" className="wf-num">{fmtSpot(s)}{s.h !== undefined ? ` · ${Math.round(s.h)}°` : ''}</bdi></dd></div>
              ) : null;
            })}
          </dl>
        </div>
      )}
    </div>
  );
}
