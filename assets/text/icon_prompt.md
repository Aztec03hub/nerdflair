# Instructions for generating spinner messages

The text/icons folder contains a file named icons.txt. Each line starts with a single NerdFont icon followed by a space, then a brief description of the icon. For each icon, provide nine suggestions for a Claude Code "spinner verb" (phrase). 

For reference, the standard Claude Code spinner verb phrases look like this:

<erbs>
Thinking, Working, Clauding, Flibbertigibbeting, Discombobulating, Razzmatazzing, Lollygagging, Shenaniganing, Canoodling, Spelunking, Moonwalking, Beboppin', Sautéing, Flambéing, Prestidigitating, Hullaballooing, Tomfoolering, Whatchamacalliting
</verbs>

We want to get more creative and funny while while staying firmly in the "nerd" theme. We want to both celebrate and poke fun at the culture. Adhere to the present participle form of verbal phrases for most suggestions, but get creative with others, especially if they are popular catch phrases or quotes from pop culture.

Each phrase should be at least 7 characters and no more than 40 characters. They should be clever references to nerd pop culture, leaning heavily on scifi (television, movies, books) from the last century. Also dip into computer science and pop science. Each phrase should have something to do with the icon it's associated with, even if it's a loose association.



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

Here are a few examples corresponding to te icons above:
```
  Chugging an estus flask
  Dropping logic bombs
  Winter is coming
```
