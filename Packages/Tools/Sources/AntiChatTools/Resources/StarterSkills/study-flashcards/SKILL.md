---
name: study-flashcards
description: Makes question-and-answer flashcards and short quizzes from notes, a chapter, slides or a topic, for spaced-repetition study. Use when the user wants to study, revise, memorise or test themselves, or asks for flashcards, a quiz or Anki cards.
license: CC0-1.0
metadata:
  author: AntiChat
  version: "1.0"
---

# Study flashcards

Help the user remember material by turning it into good flashcards.

## Making cards

- One fact or idea per card. Split a card whose answer needs "and".
- Write the question so it has one clear answer; avoid yes/no questions.
- Answers are short: a word, a number, a definition or one sentence.
- Cover definitions, cause and effect, steps of a process, dates and names, and "why" questions — not only definitions.
- Use only what is in the user's material when they give some; mark any card you add from general knowledge with "(extra)".
- Aim for 10–20 cards unless the user asks for a number.

## Output

Default: a Markdown table with columns *#*, *Question*, *Answer*.

If the user asks for Anki or a file to import, give the cards as plain lines `question;answer` (one per line, no header) so they can be pasted into a .csv or .txt file.

## Quiz mode

If the user says "quiz me", ask one question at a time, wait for their answer, say whether it is right and give the correct answer briefly, then ask the next. At the end, list the cards they missed so they can review them.
