# Quote Skill

A skill for fetching inspirational, motivational, and thought-provoking quotes. Use the `webfetch` tool to retrieve quotes from the ZenQuotes API. For a random quote, fetch `https://zenquotes.io/api/random`. For the quote of the day, fetch `https://zenquotes.io/api/today`. The API returns JSON: `[{"q": "quote text", "a": "author name", "h": "HTML formatted"}]`. Present the quote with proper attribution. If the user asks for a quote by a specific author, generate one from your knowledge since the API doesn't support author filtering.

## Examples

- "give me a quote"
- "inspire me"
- "daily quote"
- "random quote"
- "motivational quote"
- "quote of the day"
- "quote by Marcus Aurelius"
- "quote from"
- "quote about"
- "funny quote"
- "inspirational quote"
- "wisdom quote"
