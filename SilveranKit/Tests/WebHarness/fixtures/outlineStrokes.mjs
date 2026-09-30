// Strokes whose outlines are pinned as golden numbers in both languages
// (inkStrokeShape.test.mjs and InkStrokeOutlineTests.swift).
export const OUTLINE_CASES = [
  { name: "line", size: 2.2, points: [[0, 0], [10, 0], [20, 0], [30, 0]] },
  {
    name: "pressure curve", size: 3,
    points: [[0, 0, 0.05], [4, 3, 0.15], [9, 5, 0.3], [15, 5.5, 0.5], [21, 4, 0.35], [26, 0, 0.1], [28, -6, 0.02]],
  },
  { name: "dot", size: 2.2, points: [[5, 5, 0.3]] },
  { name: "two points", size: 2, points: [[0, 0], [0, 12]] },
  { name: "jitter", size: 2.2, points: [[0, 0], [0.2, 0.1], [0.3, 0.3], [5, 0], [5.1, 0.2], [10, 5]] },
];
