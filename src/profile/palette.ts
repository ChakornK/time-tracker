/**
 * The light-mode steps of the iOS categorical chart palette (`ChartPalette.categorical`), in slot order.
 * The app recognizes these values and swaps in each slot's dark-mode step, so keep the two lists in sync.
 */
export const categoryPalette = [
  "#2A78D6",
  "#EB6834",
  "#1BAF7A",
  "#EDA100",
  "#E87BA4",
  "#008300",
  "#6250D6",
  "#E34948",
] as const;

/** The first palette color none of `usedColors` takes, cycling through the palette once all are taken. */
export function nextCategoryColor(usedColors: string[]): string {
  const used = new Set(usedColors.map((color) => color.toUpperCase()));
  return categoryPalette.find((color) => !used.has(color)) ?? categoryPalette[usedColors.length % categoryPalette.length];
}
