# Research Skill

A skill for interactive research and learning through back-and-forth conversation. You must use the `Research` tool to search multiple web sources and Wikipedia, fetch and compile content, and return structured findings with citations.

The Research tool automatically follows a Reflexion loop: it searches, fetches multiple sources (minimum 3), evaluates whether the gathered information is sufficient, and refines its search if needed. All facts come from fetched sources — never from model knowledge. Citations are numbered inline and source links are provided as interactive chips.

When presenting research results, prioritize: (a) accuracy over breadth, (b) recent sources over old ones, (c) primary sources over secondary, (d) consensus views first, then notable dissent. Flag any conflicting information between sources. Invite the user to drill deeper into any subtopic.

For book-related research, the Open Library API is available at `https://openlibrary.org/search.json?q={query}&limit=5&fields=title,author_name,first_publish_year,edition_count,subject`. For movie/TV research, the IMDb API is available at `https://api.imdbapi.dev/v2/search/titles?query={query}&limit=5`. Use these as primary sources when the research topic involves books, films, or television.

## Examples

- "Research how mRNA vaccines work"
- "Help me understand quantum computing"
- "What's the current state of nuclear fusion research?"
- "Explain the pros and cons of microservices architecture"
- "I want to learn about the history of the Internet"
- "Research the latest findings on intermittent fasting"
- "Deep dive into how LLMs are trained"
- "What are the arguments for and against universal basic income?"
- "Help me understand CRISPR gene editing"
- "Research the best practices for system design interviews"
- "Explain blockchain consensus mechanisms"
- "What's the current research on sleep and productivity?"
