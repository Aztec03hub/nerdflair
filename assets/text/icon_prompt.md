# Instructions for generating spinner verb phrases

The file `text/icons.txt` contains NerdFont icons. Each line has a single icon glyph followed by a space and a brief description, e.g.:
```
 beaker, flask
 bomb
 snowflake
```

For each icon, generate exactly 10 Claude Code "spinner verb" suggestions. Process every icon without skipping any.

## Output format

Output a numbered list that I can choose from. Option 0 should always be "regenerate more suggestions". We'll move iteratively through the list of icons until we're done. When a numbered suggestion is chosen by the user, append to the file text/spinners.txt starting with the icon itself, followed by two spaces, then the selected phrase.

## Style guidelines

Standard Claude Code spinner verbs look like this:

<verbs>
Thinking, Working, Clauding, Flibbertigibbeting, Discombobulating, Razzmatazzing, Lollygagging, Shenaniganing, Canoodling, Spelunking, Moonwalking, Beboppin', Sautéing, Flambéing, Prestidigitating, Hullaballooing, Tomfoolering, Whatchamacalliting
</verbs>

Go more creative and funny while staying firmly in the "nerd" theme — celebrating and lightly poking fun at the culture.

- Use present participle form for most phrases; exceptions are fine for well-known catchphrases or pop culture quotes
- Each phrase must be 7–40 characters (icon glyph not included)
- Lean heavily on sci-fi (TV, film, books) from the last century; also draw from CS and pop science
- Each phrase should relate to its icon — even a loose thematic or tonal connection counts
- Do not titleize the phrase

Here are a few examples corresponding to the icons above:
```
  Chugging an estus flask
  Dropping logic bombs
  Winter is coming
```
