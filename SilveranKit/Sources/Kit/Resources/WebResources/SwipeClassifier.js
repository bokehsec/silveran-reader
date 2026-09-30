/**
 * Swipe detection for page turns in curl mode (FoliateManager's swipe interceptors).
 *
 * A swipe is a horizontal flick that is clearly more horizontal than vertical: at least
 * `minDistance` px, or a shorter but fast flick. In Pencil mode (the Pencil has written in
 * this book) the thresholds are stricter, so only a deliberate swipe turns the page: a hand
 * shifting on the glass or a tap that slides a little while reaching for the writing does not.
 */

export const SWIPE_RULES = Object.freeze({
  minDistance: 30,
  fastDistance: 12,
  fastVelocity: 0.35, // px per ms
  directionRatio: 1.3,
});

export const PENCIL_MODE_SWIPE_RULES = Object.freeze({
  minDistance: 70,
  fastDistance: 40,
  fastVelocity: 0.6,
  directionRatio: 2,
});

/**
 * Classifies a completed touch as a page-turn swipe. Returns the visual
 * navigation direction ("left" = content moves right / goLeft), or null.
 */
export const classifySwipe = ({ dx, dy, dt }, rules = SWIPE_RULES) => {
  const ax = Math.abs(dx);
  const ay = Math.abs(dy);
  if (ax < rules.fastDistance || ax < ay * rules.directionRatio) return null;
  const velocity = dt > 0 ? ax / dt : 0;
  if (ax < rules.minDistance && velocity < rules.fastVelocity) return null;
  // Finger moving left reveals the page to the right, like the paginator's drag.
  return dx < 0 ? "right" : "left";
};
