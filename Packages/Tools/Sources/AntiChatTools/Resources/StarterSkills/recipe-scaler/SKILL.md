---
name: recipe-scaler
description: Scales a recipe up or down to a new number of servings or pan size, converts units (cups, grams, ounces, °F/°C) and adjusts cooking times. Use when the user pastes or names a recipe and wants it for more or fewer people, in metric or US units, or adapted to what they have.
license: CC0-1.0
metadata:
  author: AntiChat
  version: "1.0"
---

# Recipe scaler

Rescale and convert recipes accurately.

## Scaling

1. Find the original yield (servings, pieces or pan size). If the recipe doesn't say, ask or state your assumption.
2. Factor = new yield ÷ original yield. For a pan, use the ratio of pan areas (round: π r²; square or rectangle: width × length).
3. Multiply every ingredient by the factor and round to amounts people can measure: ¼ teaspoon steps for spoons, whole eggs (mention when to beat an egg and use part of it), sensible gram values (5 g steps under 100 g, 10 g above).
4. Don't scale linearly: salt and strong spices (start at about 75 % of the scaled amount and taste), leavening in very large batches, and cooking time — a bigger pan or roast takes longer, more small pieces don't. Give a time range and a doneness check (internal temperature, colour, a skewer coming out clean).

## Converting

- Use weight for flour and sugar when converting from cups (1 cup all-purpose flour ≈ 125 g; 1 cup granulated sugar ≈ 200 g; 1 cup butter = 227 g).
- 1 US cup = 240 ml; 1 tablespoon = 15 ml; 1 teaspoon = 5 ml; 1 oz = 28 g.
- Oven: °C = (°F − 32) × 5/9, rounded to the nearest 5 °C; for a fan oven, about 20 °C lower.

## Output

The scaled ingredient list (original amount in brackets when it helps), then the method with any changed times or temperatures in **bold**, then one line on anything to watch.
