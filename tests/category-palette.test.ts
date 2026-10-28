import assert from "node:assert/strict";
import test from "node:test";
import { categoryPalette, nextCategoryColor } from "../src/profile/palette.js";

test("new categories take the first palette color not already in use", () => {
  assert.equal(nextCategoryColor([]), "#2A78D6");
  assert.equal(nextCategoryColor(["#2a78d6", "#AABBCC"]), "#EB6834");
  // A deleted category frees its color for the next one.
  assert.equal(nextCategoryColor(["#2A78D6", "#1BAF7A"]), "#EB6834");
});

test("palette colors cycle once every slot is taken", () => {
  assert.equal(nextCategoryColor([...categoryPalette]), "#2A78D6");
  assert.equal(nextCategoryColor([...categoryPalette, "#2A78D6"]), "#EB6834");
});
