# Citation support labelling rubric

Each row: a SENTENCE from an AI answer that carries a citation, and the PASSAGE = the exact text of the cited
source(s) that the answering model was given (page extract or search-result snippet, prefixed "[n] title — site").
Judge ONLY against the passage, not your own knowledge, not the URL's live page.

Labels:
- supported   — every factual detail of the sentence (entities, numbers, dates, years, versions, qualifiers such as
                "about", "no later than", "projected", "latest", "first", superlatives, list items) is stated in the
                passage or follows directly and unambiguously from it. Paraphrase is fine.
- partial     — the core claim is in the passage but at least one detail is not: an extra list item/entity, a
                strengthened or changed qualifier, a number/year tied to a different thing or year, a recency claim
                ("latest", "next", "currently") the passage does not make, or the sentence says more than a snippet.
- unsupported — the main claim is not in the passage, or the passage contradicts it.
- n/a         — the row is not a claim (empty, a heading, pure boilerplate like "Here is a summary").

Output a CSV with columns: item,label,reason  (reason = a short quote from the passage, or what is missing).
Be strict: when in doubt between supported and partial, ask "could a careful reader verify EVERY detail from this
passage alone?" — if not, it is partial.
