# VQ-13 Projects (M8.T04 / M8.T05) — screens S-20 (project page), S-24 (sidebar with projects)

Bars: S-20 ≥ 4.0, S-24 ≥ 4.0 (scored in M9.T08). Capture light and dark at 1440×900.

1. Fresh container: `build/AntiChat.app/Contents/MacOS/AntiChat -ANTICHAT_DEV_CONTAINER /tmp/vq13`. Sidebar → Projects:
   empty state (`projects.empty`) + New project → `projects-empty`.
2. New project → sheet with name field and the 24-icon picker → `project-new`. Create "Ceramics" (icon paintbrush).
3. Project page: New chat in project ×3 (send one message each), Add files… → `fixtures/projects/small-3/*` plus
   two PDFs from `fixtures/intake/` (one still "Reading n%"), type instructions "Answer like a studio technician." →
   `project-page-light` / `project-page-dark`. The footnote reads "Changes apply to new chats in this project.";
   Project-only memory is off.
4. Sidebar: a Recents chat → ⋯ → Move to project › shows Ceramics, New project…, → `move-menu`; drag another Recents
   row onto the Ceramics row (row highlights) and drop: the chat leaves Recents and the count rises.
5. ⋯ → Delete project → dialog "Delete "Ceramics"?" / "What should happen to its 4 chats?" with
   [Cancel] [Keep chats] [Delete chats too] → `project-delete`.
6. Keyboard only: Tab through header, New chat in project, chats, files buttons, instructions, the memory switch;
   focus rings visible → `project-focus`.
7. (M8.T05) In a project chat ask a question answered by a file: citation pills with file + page → 
   `project-answer-citations`; click a pill → Quick Look at the page → `project-cite-quicklook`.
8. Linked folder: Link a folder… → a folder with 3 Markdown files; edit one in another app: its row goes
   "Reading n%" → "Ready" within a few seconds; delete one: its row disappears. Rename the folder: "The linked folder
   can't be found." [Locate…].
