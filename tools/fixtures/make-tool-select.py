#!/usr/bin/env python3
"""forty-tools.json + tool-select-200.jsonl (M7.T14, R-266 / AT-266): 40 tool definitions and 200 prompts with the
gold tool (or "none") for the load-when-needed selector.

  forty-tools.json  = the app's built-in tools (definitions dumped from the code by
                      `antichat-bench tool-select --dump-builtins <file>`, so descriptions and schemas are the shipped
                      ones; `create_video` (M5, not in the registry yet) is defined here) + scripted MCP servers
                      (function names as MCPToolProxy builds them: `<server>_<tool>`) + the four Composio meta tools
                      (descriptions/schemas from fixtures/web/mcp/composio-gmail-readonly.jsonl).
  tool-select-200   = one row per prompt: {"id","lang","prompt","gold","also"}; `gold` is a tool name or "none",
                      `also` lists other tools that are an equally right pick (e.g. Gmail work through Composio search
                      or execute). Selection is right when gold or one of `also` is offered; "none" is right when the
                      selector picks no tool (its top pick is empty).

Our own text (CC0), no personal data, seed 17, deterministic. Labels reviewed by an independent agent
(fixtures/prompts/SOURCES.md).

  python3 -I tools/fixtures/make-tool-select.py --builtins <dump.json> \\
      --tools-out <fixtures>/tools/forty-tools.json --prompts-out <fixtures>/prompts/tool-select-200.jsonl
"""
import argparse, json, random

BUILTINS = ["get_time", "web_search", "read_url", "create_image", "edit_image", "create_document", "create_spreadsheet",
            "export_table", "create_presentation", "create_chart", "query_data", "memory"]

VIDEO = {"name": "create_video", "description": "Create a short video clip from a text description, or animate a picture.",
         "parameters": {"type": "object", "properties": {"prompt": {"type": "string"}, "seconds": {"type": "integer"},
                                                          "image_ref": {"type": "string"}}, "required": ["prompt"]}}

def obj(props, required):
    return {"type": "object", "properties": {k: {"type": "string", "description": d} if d else {"type": "string"}
                                             for k, d in props.items()}, "required": required}

# (server, tool, description, properties, required)
MCP = [
    ("Team Chat", "search_messages", "Search the team's messages by words.", {"query": None}, ["query"]),
    ("Team Chat", "send_message", "Send a message to a channel.", {"channel": None, "text": None}, ["channel", "text"]),
    ("GitHub", "search_repositories", "Search GitHub repositories by name, topic or language.", {"query": None}, ["query"]),
    ("GitHub", "create_issue", "Open a new issue in a GitHub repository.", {"repo": "owner/name", "title": None, "body": None}, ["repo", "title"]),
    ("GitHub", "list_pull_requests", "List the open pull requests of a GitHub repository.", {"repo": "owner/name"}, ["repo"]),
    ("GitHub", "get_file_contents", "Read a file from a GitHub repository at a branch or commit.", {"repo": "owner/name", "path": None, "ref": None}, ["repo", "path"]),
    ("GitHub", "create_pull_request", "Open a pull request from one branch into another.", {"repo": "owner/name", "head": None, "base": None, "title": None}, ["repo", "head", "base", "title"]),
    ("Notion", "search", "Search pages and databases in the user's Notion workspace.", {"query": None}, ["query"]),
    ("Notion", "create_page", "Create a new Notion page with a title and content.", {"parent": None, "title": None, "content": None}, ["title"]),
    ("Notion", "append_block", "Add text to the end of an existing Notion page.", {"page_id": None, "text": None}, ["page_id", "text"]),
    ("Linear", "list_issues", "List Linear issues, filtered by team, assignee or state.", {"team": None, "assignee": None, "state": None}, []),
    ("Linear", "create_issue", "Create a Linear issue in a team with a title and description.", {"team": None, "title": None, "description": None}, ["team", "title"]),
    ("Linear", "update_issue", "Change a Linear issue's state, assignee or priority.", {"id": None, "state": None, "assignee": None, "priority": None}, ["id"]),
    ("Calendar", "list_events", "List the events on the user's calendar between two dates.", {"start": "ISO date", "end": "ISO date"}, ["start", "end"]),
    ("Calendar", "create_event", "Add an event to the user's calendar.", {"title": None, "start": "ISO date-time", "end": "ISO date-time", "attendees": None}, ["title", "start"]),
    ("Calendar", "find_free_time", "Find free time slots in the user's calendar for a meeting of a given length.", {"duration_minutes": None, "within_days": None}, ["duration_minutes"]),
    ("Drive", "search_files", "Search the user's cloud drive for files by name or content.", {"query": None}, ["query"]),
    ("Drive", "read_file", "Read the text of a file in the user's cloud drive.", {"file_id": None}, ["file_id"]),
    ("Weather", "get_forecast", "Get the weather forecast for a place for the next days.", {"location": None, "days": None}, ["location"]),
    ("Stripe", "list_payments", "List recent payments received in the Stripe account.", {"limit": None, "status": None}, []),
    ("Stripe", "create_invoice", "Create and send a Stripe invoice to a customer.", {"customer_email": None, "amount": None, "description": None}, ["customer_email", "amount"]),
    ("Maps", "search_places", "Find places such as restaurants, shops or museums near a location.", {"query": None, "near": None}, ["query"]),
    ("Maps", "get_directions", "Get travel directions and time between two places.", {"from": None, "to": None, "mode": "driving, walking, transit or cycling"}, ["from", "to"]),
]

def slug(s):
    out, word = [], ""
    for ch in s.lower():
        if ch.isascii() and ch.isalnum():
            word += ch
        elif word:
            out.append(word); word = ""
    if word: out.append(word)
    return "_".join(out)

def fn(server, tool):
    return f"{slug(server)}_{slug(tool)}"[:64]

def composio_tools():
    for line in open(COMPOSIO_FIXTURE):
        o = json.loads(line)
        if o.get("request", {}).get("method") == "tools/list":
            return [{"name": fn("Composio", t["name"]), "description": t["description"], "parameters": t["inputSchema"],
                     "kind": "composio"} for t in o["response"]["result"]["tools"]]
    raise SystemExit("composio tools/list not found")

G = lambda server, tool: fn(server, tool)
CSEARCH, CEXEC, CMANAGE = G("Composio", "COMPOSIO_SEARCH_TOOLS"), G("Composio", "COMPOSIO_MULTI_EXECUTE_TOOL"), G("Composio", "COMPOSIO_MANAGE_CONNECTIONS")

# (lang, prompt, gold, also)
ROWS = [
    # get_time
    ("en", "What time is it in Tokyo right now?", "get_time", []),
    ("en", "what's today's date", "get_time", []),
    ("en", "Is it already evening in New York?", "get_time", []),
    ("de", "Wie spät ist es gerade in Sydney?", "get_time", []),
    # web_search
    ("en", "Who won the Champions League final last night?", "web_search", []),
    ("en", "search the web for reviews of the new Framework laptop", "web_search", []),
    ("en", "What are the latest headlines about the EU AI Act?", "web_search", []),
    ("en", "current price of bitcoin?", "web_search", []),
    ("es", "¿Cuáles son las últimas noticias sobre la huelga de trenes en Francia?", "web_search", []),
    ("fr", "Cherche sur internet les horaires d'ouverture du musée d'Orsay", "web_search", []),
    # read_url
    ("en", "Summarize this article for me: https://example.org/blog/why-sleep-matters", "read_url", []),
    ("en", "What does the page at https://example.com/pricing say about the free plan?", "read_url", []),
    ("en", "read https://example.net/docs/install and tell me the steps for macOS", "read_url", []),
    ("nl", "Kun je deze pagina samenvatten? https://example.org/nieuws/klimaat", "read_url", []),
    # create_image
    ("en", "Draw a watercolor fox sleeping under a maple tree", "create_image", []),
    ("en", "make me a logo for a bakery called Crumbs, minimal, warm colors", "create_image", []),
    ("en", "Generate a photo-realistic picture of a red bicycle leaning on a brick wall", "create_image", []),
    ("de", "Erstelle ein Bild von einem Leuchtturm im Sturm", "create_image", []),
    ("pt", "Cria uma ilustração de um gato astronauta", "create_image", []),
    # edit_image
    ("en", "Remove the person in the background of my photo", "edit_image", []),
    ("en", "make the sky in this picture more dramatic and orange", "edit_image", []),
    ("en", "Change the color of the car in the image to dark green", "edit_image", []),
    ("es", "Quita el fondo de esta foto y déjalo blanco", "edit_image", []),
    # create_video
    ("en", "Make a short video of waves rolling onto a beach at sunset", "create_video", []),
    ("en", "animate this picture so the flag waves in the wind", "create_video", []),
    ("en", "Create a 5 second clip of snow falling over a quiet village", "create_video", []),
    ("fr", "Fais une courte vidéo d'un chat qui joue avec une pelote", "create_video", []),
    # create_document
    ("en", "Write my cover letter as a Word document I can download", "create_document", []),
    ("en", "Export these meeting notes as a PDF", "create_document", []),
    ("en", "Create a one-page handout about recycling rules as a PDF file", "create_document", []),
    ("de", "Erstelle mir ein Word-Dokument mit einer Einladung zum Sommerfest", "create_document", []),
    ("en", "put this recipe into a markdown file for me", "create_document", []),
    # create_spreadsheet
    ("en", "Make an Excel sheet to track my monthly expenses with a total row", "create_spreadsheet", []),
    ("en", "Create a CSV with the 10 largest cities in Europe and their populations", "create_spreadsheet", []),
    ("en", "I need a spreadsheet for a weekly workout plan", "create_spreadsheet", []),
    ("es", "Hazme una hoja de cálculo para controlar las horas de trabajo", "create_spreadsheet", []),
    # export_table
    ("en", "Save that query result as a CSV file", "export_table", ["create_spreadsheet"]),
    ("en", "Download the filtered table you just showed me as xlsx", "export_table", ["create_spreadsheet"]),
    ("en", "export the results of that last query to Excel", "export_table", ["create_spreadsheet"]),
    # create_presentation
    ("en", "Make a 6-slide deck about the history of the bicycle", "create_presentation", []),
    ("en", "Turn this outline into a PowerPoint presentation", "create_presentation", []),
    ("en", "Build slides for my team kickoff: goals, timeline, roles", "create_presentation", []),
    ("nl", "Maak een presentatie van vijf dia's over zonne-energie", "create_presentation", []),
    # create_chart
    ("en", "Plot a bar chart of these sales numbers: Jan 120, Feb 95, Mar 140", "create_chart", []),
    ("en", "Show me a line chart of the revenue by month from my spreadsheet", "create_chart", ["query_data"]),
    ("en", "make a pie chart of how I spend my week: work 40, sleep 56, other 72", "create_chart", []),
    ("de", "Zeichne ein Diagramm mit den Temperaturen der letzten Woche: 12, 14, 9, 11, 15", "create_chart", []),
    # query_data
    ("en", "In the attached sales.xlsx, which region had the highest revenue?", "query_data", []),
    ("en", "How many orders in the spreadsheet I attached were shipped late?", "query_data", []),
    ("en", "average order value per month in the attached csv", "query_data", []),
    ("es", "En la hoja que adjunté, ¿cuál es el producto más vendido?", "query_data", []),
    # memory
    ("en", "Remember that I'm allergic to peanuts", "memory", []),
    ("en", "please forget what I told you about my old job", "memory", []),
    ("en", "Note for the future: I prefer metric units", "memory", []),
    ("fr", "Souviens-toi que je suis végétarien", "memory", []),
    # team chat
    ("en", "Search our team chat for what Ana said about the launch date", "team_chat_search_messages", []),
    ("en", "find messages in the team chat that mention the budget", "team_chat_search_messages", []),
    ("en", "Post 'standup moved to 10am' in the general channel", "team_chat_send_message", []),
    ("en", "send a message to #design saying the mockups are ready", "team_chat_send_message", []),
    # github
    ("en", "Find popular GitHub repos for Swift markdown parsing", "github_search_repositories", []),
    ("en", "search github for rust web frameworks", "github_search_repositories", []),
    ("en", "Open an issue in acme/website: the contact form doesn't submit on Safari", "github_create_issue", []),
    ("en", "file a bug on GitHub in acme/app titled 'Crash on launch'", "github_create_issue", []),
    ("en", "Which pull requests are open in acme/website?", "github_list_pull_requests", []),
    ("en", "list PRs waiting for review on acme/api", "github_list_pull_requests", []),
    ("en", "Show me the README of acme/api on the main branch", "github_get_file_contents", []),
    ("en", "read src/config.yml from the acme/app repo", "github_get_file_contents", []),
    ("en", "Open a pull request in acme/app from feature/login into main", "github_create_pull_request", []),
    ("en", "create a PR merging fix-typos into develop on acme/docs", "github_create_pull_request", []),
    # notion
    ("en", "Search my Notion for the onboarding checklist", "notion_search", []),
    ("en", "find the page about Q3 goals in Notion", "notion_search", []),
    ("en", "Create a Notion page called 'Trip to Lisbon' with a packing list", "notion_create_page", []),
    ("en", "make a new page in Notion for tomorrow's meeting notes", "notion_create_page", []),
    ("en", "Add 'call the plumber' to the end of my Notion to-do page", "notion_append_block", ["notion_search"]),
    ("en", "append today's summary to the project log page in Notion", "notion_append_block", ["notion_search"]),
    # linear
    ("en", "What Linear issues are assigned to me?", "linear_list_issues", []),
    ("en", "show the open bugs for the mobile team in Linear", "linear_list_issues", []),
    ("en", "Create a Linear issue for the web team: dark mode toggle is broken", "linear_create_issue", []),
    ("en", "log a new ticket in Linear about slow search", "linear_create_issue", []),
    ("en", "Mark Linear issue WEB-142 as done", "linear_update_issue", []),
    ("en", "change the priority of ENG-77 in Linear to urgent", "linear_update_issue", []),
    # calendar
    ("en", "What's on my calendar tomorrow?", "calendar_list_events", []),
    ("en", "do I have any meetings on Friday afternoon", "calendar_list_events", []),
    ("de", "Welche Termine habe ich nächste Woche?", "calendar_list_events", []),
    ("en", "Add a dentist appointment to my calendar on Tuesday at 3pm", "calendar_create_event", []),
    ("en", "schedule lunch with Sam next Thursday at noon", "calendar_create_event", []),
    ("en", "Find a free hour in my calendar this week for a call", "calendar_find_free_time", []),
    ("en", "when am I free for 30 minutes in the next three days?", "calendar_find_free_time", []),
    # drive
    ("en", "Find the contract PDF in my drive", "drive_search_files", []),
    ("en", "search my cloud drive for the budget spreadsheet from last year", "drive_search_files", []),
    ("en", "Open the file 'Project plan' from my drive and summarize it", "drive_read_file", ["drive_search_files"]),
    ("en", "read the notes document in my drive with id 1a2b3c", "drive_read_file", []),
    # weather
    ("en", "What's the weather forecast for Berlin this weekend?", "weather_get_forecast", ["web_search"]),
    ("en", "will it rain in Amsterdam tomorrow", "weather_get_forecast", ["web_search"]),
    ("es", "¿Qué tiempo hará en Madrid el lunes?", "weather_get_forecast", ["web_search"]),
    # stripe
    ("en", "Show the payments we received in Stripe this week", "stripe_list_payments", []),
    ("en", "list failed Stripe payments", "stripe_list_payments", []),
    ("en", "Send an invoice for 450 euros to client@example.com via Stripe", "stripe_create_invoice", []),
    ("en", "bill jo@example.com 120 dollars for the design work", "stripe_create_invoice", []),
    # maps
    ("en", "Find a good ramen place near Shibuya station", "maps_search_places", ["web_search"]),
    ("en", "any pharmacies open near me in Utrecht?", "maps_search_places", ["web_search"]),
    ("en", "How long does it take to walk from the Eiffel Tower to the Louvre?", "maps_get_directions", ["web_search"]),
    ("en", "give me driving directions from Lyon to Geneva", "maps_get_directions", ["web_search"]),
    ("nl", "Hoe kom ik met het OV van Utrecht naar Leiden?", "maps_get_directions", ["web_search"]),
    # harder phrasings (no tool word, or another language)
    ("en", "is the Louvre open on Mondays these days?", "web_search", ["maps_search_places"]),
    ("en", "Who is the current prime minister of Japan?", "web_search", []),
    ("de", "Was gibt es Neues bei der Bundesliga?", "web_search", []),
    ("en", "Can you sketch a floor plan style drawing of a cozy studio apartment?", "create_image", []),
    ("en", "I want a poster image for our jazz night, art deco style", "create_image", []),
    ("en", "brighten this photo a bit, it's too dark", "edit_image", []),
    ("en", "I'd like a little clip of a paper boat floating down a stream", "create_video", []),
    ("en", "Give me my CV as a downloadable docx", "create_document", []),
    ("es", "Genera un PDF con el itinerario del viaje", "create_document", []),
    ("en", "Set up a budget table in xlsx with categories and monthly columns", "create_spreadsheet", []),
    ("en", "Prepare a slide deck for my grandmother's 80th birthday party", "create_presentation", []),
    ("en", "visualize this data as a scatter plot: (1,2) (2,4) (3,5) (4,4)", "create_chart", []),
    ("en", "From the sheet I uploaded, list customers who spent over 1000", "query_data", []),
    ("en", "Keep in mind that my daughter's name is Mia", "memory", []),
    ("de", "Merk dir bitte, dass ich in Köln wohne", "memory", []),
    ("en", "did anyone in the team chat ask about the holiday schedule?", "team_chat_search_messages", []),
    ("en", "let the #support channel know the outage is fixed", "team_chat_send_message", []),
    ("en", "Are there any open source repositories for parsing PDFs in Go?", "github_search_repositories", []),
    ("en", "report a bug in acme/cli: the --help flag prints nothing", "github_create_issue", []),
    ("en", "What changed in the open PRs on acme/web?", "github_list_pull_requests", []),
    ("en", "Look up our team wiki in Notion for the vacation policy", "notion_search", []),
    ("en", "Start a new Notion doc for the book club reading list", "notion_create_page", []),
    ("en", "What tickets is the backend team working on in Linear?", "linear_list_issues", []),
    ("en", "Assign WEB-88 to Priya in Linear", "linear_update_issue", []),
    ("en", "Put 'yoga class' on my calendar every Wednesday at 7", "calendar_create_event", []),
    ("en", "Am I busy on the morning of the 14th?", "calendar_list_events", ["calendar_find_free_time"]),
    ("es", "Busca en mi Drive el documento del contrato de alquiler", "drive_search_files", []),
    ("en", "Do I need an umbrella in London on Saturday?", "weather_get_forecast", ["web_search"]),
    ("en", "how much did customers pay us through Stripe yesterday", "stripe_list_payments", []),
    ("en", "What's the fastest way by train from Brussels to Cologne?", "maps_get_directions", ["web_search"]),
    ("en", "Find a vegan bakery around Prenzlauer Berg", "maps_search_places", ["web_search"]),
    ("en", "Reply to the latest email from Alex in my inbox and say I'll be late", CSEARCH, [CEXEC]),
    # composio
    ("en", "Send an email from my Gmail to Kim saying the report is attached", CSEARCH, [CEXEC]),
    ("en", "Check my Gmail for unread messages from the bank", CSEARCH, [CEXEC]),
    ("en", "Create a Trello card called 'Order new chairs' on my office board", CSEARCH, [CEXEC]),
    ("en", "add a task to Asana: renew the domain", CSEARCH, [CEXEC]),
    ("en", "Post a tweet saying our shop opens at 9 tomorrow", CSEARCH, [CEXEC]),
    ("en", "Connect my Dropbox account", CMANAGE, []),
    ("en", "is my Google Sheets account connected?", CMANAGE, [CSEARCH]),
    ("en", "link my HubSpot so you can use it", CMANAGE, []),
]

NONE = [
    ("en", "Explain how recursion works with a simple example"),
    ("en", "write a haiku about autumn rain"),
    ("en", "What's 15% of 84.50?"),
    ("en", "Translate 'good morning, how are you?' into Italian"),
    ("en", "Give me five tips for sleeping better"),
    ("en", "hi! how are you doing today?"),
    ("en", "thanks, that was helpful"),
    ("en", "What's the difference between a virus and a bacterium?"),
    ("en", "Help me write a polite reply declining a wedding invitation"),
    ("en", "Can you explain what a pull request is, in simple terms?"),
    ("en", "How do I write a good README for an open source project?"),
    ("en", "What makes a good presentation? General advice please"),
    ("en", "Why is the sky blue?"),
    ("en", "Suggest five names for a golden retriever puppy"),
    ("en", "Summarize the plot of Pride and Prejudice in three sentences"),
    ("en", "how do I center a div in CSS"),
    ("en", "Write a Python function that reverses a string"),
    ("en", "What should I pack for a weekend hiking trip?"),
    ("en", "Is it better to rent or buy a house? Give me the trade-offs"),
    ("en", "tell me a joke about cats"),
    ("en", "Rewrite this sentence to sound more formal: we gotta fix this asap"),
    ("en", "What are the main causes of the French Revolution?"),
    ("en", "How do spreadsheet formulas like VLOOKUP work?"),
    ("en", "Give me a 3-day meal plan for a vegetarian"),
    ("en", "what is a good way to learn chess as an adult"),
    ("en", "Explain the difference between weather and climate"),
    ("en", "Describe a calm morning routine in a short paragraph"),
    ("en", "How do I ask my manager for a raise?"),
    ("en", "write a limerick about a programmer"),
    ("en", "Which is heavier, a kilo of feathers or a kilo of steel?"),
    ("de", "Erkläre mir, wie ein Regenbogen entsteht"),
    ("de", "Schreib ein kurzes Gedicht über das Meer"),
    ("es", "¿Me das una receta fácil de tortilla de patatas?"),
    ("es", "Explícame qué es la fotosíntesis"),
    ("fr", "Donne-moi trois idées de cadeaux pour ma sœur"),
    ("fr", "Comment dit-on 'merci beaucoup' en japonais ?"),
    ("nl", "Wat is het verschil tussen een meer en een zee?"),
    ("nl", "Geef me tips om beter te leren voor een examen"),
    ("pt", "Explique o que é inflação de forma simples"),
    ("pt", "Escreve uma mensagem de aniversário para a minha avó"),
    ("en", "What does a product manager do?"),
    ("en", "how many legs does a spider have"),
    ("en", "Proofread: Their going to the park tomorow"),
    ("en", "Brainstorm ten blog post ideas about gardening"),
    ("en", "What is the capital of Australia?"),
    ("en", "Explain compound interest like I'm twelve"),
    ("en", "Can you help me plan a birthday party for a 7 year old?"),
    ("en", "good night!"),
    ("en", "What is a good stretching routine after running?"),
    ("en", "Explain what an API is to a non-programmer"),
    ("en", "Draft a short thank-you note to my neighbour for watering my plants"),
    ("en", "Which planets in our solar system have rings?"),
    ("en", "List some fun things to do on a rainy day indoors"),
    ("en", "How do I calculate the area of a circle?"),
    ("de", "Wie funktioniert ein Elektromotor?"),
    ("en", "Recommend three classic science fiction novels"),
]

COMPOSIO_FIXTURE = None

def main():
    global COMPOSIO_FIXTURE
    ap = argparse.ArgumentParser()
    ap.add_argument("--builtins", required=True, help="antichat-bench tool-select --dump-builtins output")
    ap.add_argument("--composio", required=True, help="fixtures/web/mcp/composio-gmail-readonly.jsonl")
    ap.add_argument("--tools-out", required=True)
    ap.add_argument("--prompts-out", required=True)
    a = ap.parse_args()
    COMPOSIO_FIXTURE = a.composio
    dumped = {t["name"]: t for t in json.load(open(a.builtins))}
    missing = [n for n in BUILTINS if n not in dumped]
    if missing:
        raise SystemExit(f"built-ins missing from the dump: {missing}")
    tools = [{"name": n, "description": dumped[n]["description"], "parameters": dumped[n]["parameters"], "kind": "builtin"}
             for n in BUILTINS]
    tools.append({**VIDEO, "kind": "builtin"})
    for server, tool, desc, props, req in MCP:
        tools.append({"name": fn(server, tool), "description": desc, "parameters": obj(props, req), "kind": "mcp",
                      "server": server})
    tools += composio_tools()
    names = [t["name"] for t in tools]
    assert len(tools) == 40 and len(set(names)) == 40, (len(tools), len(set(names)))
    rows = [(l, p, g, also) for l, p, g, also in ROWS] + [(l, p, "none", []) for l, p in NONE]
    for _, _, g, also in rows:
        assert g == "none" or g in names, g
        for x in also: assert x in names, x
    assert len(rows) == 200, len(rows)
    rng = random.Random(17)
    rng.shuffle(rows)
    with open(a.tools_out, "w") as f:
        json.dump(tools, f, indent=1, sort_keys=True)
        f.write("\n")
    with open(a.prompts_out, "w") as f:
        for i, (lang, prompt, gold, also) in enumerate(rows, 1):
            f.write(json.dumps({"id": f"ts-{i:03d}", "lang": lang, "prompt": prompt, "gold": gold, "also": also},
                               ensure_ascii=False, sort_keys=True) + "\n")
    print(f"tools {len(tools)}  prompts {len(rows)}  none {sum(1 for r in rows if r[2] == 'none')}")

if __name__ == "__main__":
    main()
