# Movies Skill

A skill for looking up movie and TV show information using the free IMDb API. Use the `webfetch` tool to query the API endpoints below.

**Search by name:**
`https://api.imdbapi.dev/v2/search/titles?query={query}&limit=5`

Returns a list of matching titles. Each result includes: id, type, primaryTitle, startYear, primaryImage, and plot.

**Get full details by IMDb ID (e.g. tt1375666):**
`https://api.imdbapi.dev/v2/titles/{titleId}`

Returns: primaryTitle, originalTitle, type (MOVIE, TV_SERIES, etc.), startYear, endYear, runtimeSeconds, genres, rating (aggregateRating + voteCount), plot, directors, writers, stars, originCountries, spokenLanguages.

**Filtering titles:**
`https://api.imdbapi.dev/v2/titles?types=MOVIE&genres=comedy&minAggregateRating=7&sortBy=SORT_BY_POPULARITY&sortOrder=ASC&pageSize=5`

Supported types: MOVIE, TV_SERIES, TV_MINI_SERIES, TV_SPECIAL, TV_MOVIE, SHORT. Supported sorts: SORT_BY_POPULARITY, SORT_BY_RELEASE_DATE, SORT_BY_USER_RATING, SORT_BY_YEAR.

When presenting results, always include the title, year, rating (if available), and a brief plot summary. For TV series, mention the start and end years. Convert runtimeSeconds to hours and minutes.

## Examples

- "What's the rating of Inception?"
- "Tell me about the movie Interstellar"
- "Look up The Office TV show"
- "What year did Pulp Fiction come out?"
- "Find me sci-fi movies rated above 8"
- "Who directed The Godfather?"
- "What is the plot of Breaking Bad?"
- "Search for movies with Tom Hanks"
- "Top rated comedy movies"
- "Is there a sequel to Blade Runner?"
- "How long is the movie Oppenheimer?"
- "What genre is Stranger Things?"
- "Movie recommendations for tonight"
- "Best TV series of 2024"
- "Who stars in Dune?"
