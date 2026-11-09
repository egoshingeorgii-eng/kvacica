# Deck format

A deck is a JSON file you can import with ⌘O, paste with ⌘⇧V (File → Paste Deck), or have a chat create for you. Importing merges by `id`: new notes are added, existing ones are updated and keep their progress.

```json
{
  "version": 1,
  "notes": [
    {"id": "stric", "kind": "word", "cue": "дядя (брат отца)", "answer": "stric",
     "level": "A1", "topic": "Family", "cluster": "uncles-aunts"},
    {"id": "sad", "kind": "word", "cue": "сейчас", "answer": "sad", "accept": ["sada"]},
    {"id": "hleb", "kind": "word", "cue": "хлеб", "answer": "hleb",
     "forms": {"gen.sg": "hleba", "ins.sg": "hlebom"},
     "examples": [{"sr": "Kupio sam *hleba* u pekari.", "ru": "Я купил хлеба в пекарне."}]}
  ]
}
```

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | Stable unique id. Importing a note with an existing id updates it and keeps its progress. |
| `kind` | yes | `word` and `phrase` are studied both ways; `form` and `sentence` only Russian → Serbian. |
| `cue` | yes | The prompt, in Russian. |
| `answer` | yes | The Serbian answer, Latin script with č ć š ž đ. |
| `accept` | no | Other correct answers. |
| `info` | no | A note shown after answering. |
| `level` | no | `A1` … `C2`, default `A1`. |
| `topic` | no | One of the built-in topics (Phrases, Small words, Verbs, People & Jobs, Character & Feelings, Family, Body & Health, Food & Drink, Clothes, Shopping, Home, City & Travel, Nature & Weather, Free time, Language & Study, Time, Numbers & Colors, Opinions & Ideas, Grammar, Sentences). |
| `cluster` | no | Words that are easy to confuse share a cluster (2–6 words). |
| `forms` | no | Form table: nouns `nom.sg` … `loc.pl`; adjectives `f.gen`, `m.loc`, `comp`, `sup`; verbs `pres.1sg` … `pres.3pl`, `past.m.sg` … `past.n.pl`, `imp.2sg`, `imp.1pl`, `imp.2pl`. A second spelling after `/`. |
| `examples` | no | 1–5 sentences with the word marked by asterisks, exactly one per sentence. |

At the top level, `"delete": ["id", …]` removes notes with their history, `"examples": {"id": [...]}` and `"forms": {"id": {...}}` add sentences or forms to existing notes without touching anything else.
