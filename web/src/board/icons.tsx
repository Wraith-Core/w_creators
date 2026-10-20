/* ════════════════════════════════════════════════════════════════════════════
 * w_creators · board/icons.tsx - the line icons, in the pause menu's manner (the board kit's kit/icons.tsx):
 * one 24-unit grid, one stroke, round ends, lines that wobble a little so they read as pen on paper.
 * ════════════════════════════════════════════════════════════════════════════ */

import type { ReactElement } from 'react';
import type { PlaceType } from './model';

const line = {
  viewBox: '0 0 24 24',
  fill: 'none',
  stroke: 'currentColor',
  strokeWidth: 1.5,
  strokeLinecap: 'round' as const,
  strokeLinejoin: 'round' as const,
  'aria-hidden': true,
};

const glyph = { ...line, className: 'wf-glyph' };

type IconProps = { className?: string };

/** A coat hanger: the clothing stores */
export function IconClothing({ className = 'wf-ico' }: IconProps) {
  return (
    <svg {...line} className={className}>
      <path d="M12.05 7.6c-.05-.85.6-1.15 1.05-1.6.45-.45.55-1.15.1-1.65-.5-.55-1.45-.55-1.95 0-.25.25-.35.55-.35.85" />
      <path d="M12.05 7.6 3.5 15.1c-.55.5-.25 1.25.5 1.25h16.05c.75 0 1.05-.75.5-1.25L12.05 7.6Z" />
    </svg>
  );
}

/** Open scissors: the barbers */
export function IconBarber({ className = 'wf-ico' }: IconProps) {
  return (
    <svg {...line} className={className}>
      <path d="M7.1 20.1c1.4 0 2.5-1.1 2.5-2.5s-1.1-2.5-2.5-2.5-2.5 1.1-2.5 2.5 1.1 2.5 2.5 2.5Z" />
      <path d="M16.95 20.05c1.4 0 2.5-1.1 2.5-2.5s-1.1-2.5-2.5-2.5-2.5 1.1-2.5 2.5 1.1 2.5 2.5 2.5Z" />
      <path d="M8.9 15.85 17.6 3.9M15.15 15.9 6.45 3.95" />
    </svg>
  );
}

/** A hand mirror: the cosmetic clinics */
export function IconSurgery({ className = 'wf-ico' }: IconProps) {
  return (
    <svg {...line} className={className}>
      <path d="M12.05 13.9c3.05 0 5.35-2.3 5.3-5.1-.05-2.8-2.4-5-5.35-4.95-2.95 0-5.3 2.25-5.25 5.05.05 2.8 2.35 5 5.3 5Z" />
      <path d="M11.95 13.95l.1 6.6" strokeWidth={2} />
      <path d="M9.6 6.9c.45-.85 1.25-1.35 2.2-1.45" strokeOpacity={0.7} />
    </svg>
  );
}

/** A two-door cupboard: the wardrobes */
export function IconWardrobe({ className = 'wf-ico' }: IconProps) {
  return (
    <svg {...line} className={className}>
      <path d="M5.1 20.4 5 3.7c4.65-.1 9.3-.1 13.95.05l-.05 16.6" />
      <path d="M12 3.8v16.55" />
      <path d="M10.2 11.9h.1M13.75 11.95h.1" strokeWidth={2.4} />
      <path d="M4.3 20.45c5.1-.1 10.25-.1 15.4.05" />
    </svg>
  );
}

export const TYPE_ICONS: Record<PlaceType, (p: IconProps) => ReactElement> = {
  clothing: IconClothing,
  barber: IconBarber,
  surgery: IconSurgery,
  wardrobe: IconWardrobe,
};

/** Enabled: a mark ticked inside its ring */
export function IconOn({ className = 'wf-row-state' }: IconProps) {
  return (
    <svg {...line} className={className}>
      <path d="M19.4 12.1c-.05 4.15-3.4 7.35-7.45 7.3-4.1-.05-7.35-3.4-7.3-7.45.05-4.1 3.4-7.35 7.45-7.3 4.05.05 7.35 3.4 7.3 7.45Z" />
      <path d="M8.6 12.3l2.35 2.3 4.6-5.05" strokeWidth={1.8} />
    </svg>
  );
}

/** Disabled: the ring alone, struck once */
export function IconOff({ className = 'wf-row-state' }: IconProps) {
  return (
    <svg {...line} className={className}>
      <path d="M19.4 12.1c-.05 4.15-3.4 7.35-7.45 7.3-4.1-.05-7.35-3.4-7.3-7.45.05-4.1 3.4-7.35 7.45-7.3 4.05.05 7.35 3.4 7.3 7.45Z" />
      <path d="M8.9 12.05l6.25-.1" strokeOpacity={0.7} />
    </svg>
  );
}

export function GlyphNext() {
  return (
    <svg {...glyph}>
      <path d="M9.1 4.9l7.2 7.05-7.15 7.1" strokeWidth={2} />
    </svg>
  );
}

export function GlyphPrev() {
  return (
    <svg {...glyph}>
      <path d="M14.9 4.9l-7.2 7.05 7.15 7.1" strokeWidth={2} />
    </svg>
  );
}

export function GlyphTick() {
  return (
    <svg {...glyph}>
      <path d="M4.9 12.6l4.45 4.35 9.8-10.1" strokeWidth={2.4} />
    </svg>
  );
}

/** Not there yet: a short dash */
export function GlyphDash() {
  return (
    <svg {...glyph}>
      <path d="M7.2 12.05l9.6-.1" strokeWidth={2} />
    </svg>
  );
}

export function GlyphCross() {
  return (
    <svg {...glyph}>
      <path d="M5.6 5.4l12.9 13.1M18.4 5.5L5.5 18.45" strokeWidth={2} />
    </svg>
  );
}

export function GlyphPlus() {
  return (
    <svg {...glyph}>
      <path d="M12.05 4.4l-.1 15.2M4.4 11.95l15.2.1" strokeWidth={2.2} />
    </svg>
  );
}

/** A pin standing in the ground: choose the place in the game */
export function GlyphPin() {
  return (
    <svg {...glyph}>
      <path d="M12.05 20.4c-3.3-4.15-5.4-7.2-5.35-9.85.05-3.05 2.45-5.35 5.4-5.3 2.9.05 5.25 2.4 5.2 5.4-.05 2.65-2.05 5.6-5.25 9.75Z" />
      <path d="M12.1 12.3c.95 0 1.7-.8 1.7-1.75 0-.95-.8-1.7-1.75-1.7-.95.02-1.7.8-1.68 1.75.02.95.78 1.7 1.73 1.7Z" />
    </svg>
  );
}

/** An eye on a ring: aim at something already in the map */
export function GlyphAim() {
  return (
    <svg {...glyph}>
      <path d="M12.05 18.9c3.8-.05 6.9-3.15 6.85-6.95-.05-3.8-3.15-6.9-6.95-6.85-3.8.05-6.9 3.15-6.85 6.95.05 3.8 3.15 6.9 6.95 6.85Z" />
      <path d="M12 2.9v3.2M12 17.9v3.2M2.9 12h3.2M17.9 12h3.2" />
      <path d="M12 12.9a.9.9 0 1 0 0-1.8.9.9 0 0 0 0 1.8Z" strokeWidth={1.8} />
    </svg>
  );
}
