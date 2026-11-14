---
name: meeting-notes
description: Turns rough meeting notes, a transcript or a voice memo into clean minutes with decisions, action items (owner and due date) and open questions. Use when the user pastes notes or a transcript from a meeting, call or standup and wants a summary, minutes or a follow-up.
license: CC0-1.0
metadata:
  author: AntiChat
  version: "1.0"
---

# Meeting notes

Turn whatever the user gives you (bullet scraps, a transcript, a dictated memo) into minutes someone who missed the meeting can act on.

## Output

Use these sections, in this order, and leave out a section that would be empty:

1. **Summary** — two or three sentences: what the meeting was for and what came out of it.
2. **Decisions** — one bullet per decision, stated as a fact ("We ship the beta on 12 May").
3. **Action items** — a table with columns *Task*, *Owner*, *Due*. Write "—" when the notes don't say; never invent a name or a date.
4. **Open questions** — things raised but not settled, with who raised them if known.
5. **Next meeting** — only if a date, time or agenda was mentioned.

## Rules

- Keep the participants' own terms for products, projects and people.
- Merge repeated points; drop small talk and filler.
- If the notes contradict each other, say so under Open questions instead of picking one.
- Dates: keep what was said ("next Friday") and add the calendar date only when today's date makes it certain.
- If the user asks for a follow-up email, write it after the minutes: short greeting, the decisions, the action items, a closing line.
