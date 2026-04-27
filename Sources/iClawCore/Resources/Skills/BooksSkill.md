# Books Skill

A skill for looking up book information using the free Open Library API. Use the `webfetch` tool to query the API endpoints below.

**Search by title or general query:**
`https://openlibrary.org/search.json?q={query}&limit=5&fields=title,author_name,first_publish_year,edition_count,cover_i,key,subject,isbn,publisher,language`

**Search by author:**
`https://openlibrary.org/search.json?author={author}&limit=5&fields=title,author_name,first_publish_year,edition_count,cover_i,key,subject`

**Search by title specifically:**
`https://openlibrary.org/search.json?title={title}&limit=5&fields=title,author_name,first_publish_year,edition_count,cover_i,key,subject`

The response contains a `docs` array. Each doc includes: title, author_name (array), first_publish_year, edition_count, cover_i (cover image ID), key (work ID like /works/OL27448W), subject (array of topics), isbn (array), publisher (array), language (array of codes).

Cover images are available at: `https://covers.openlibrary.org/b/id/{cover_i}-M.jpg` (M for medium, S for small, L for large).

When presenting results, always include the title, author(s), first publication year, and number of editions. Mention notable subjects if available. For queries about a specific book, present the most relevant match prominently.

## Examples

- "Who wrote 1984?"
- "Tell me about the book Dune"
- "Books by Ursula K. Le Guin"
- "When was The Great Gatsby first published?"
- "Look up Sapiens by Yuval Noah Harari"
- "Find books about machine learning"
- "How many editions of Harry Potter are there?"
- "What is Project Hail Mary about?"
- "Book recommendations for sci-fi fans"
- "What has Stephen King written?"
- "Is The Hitchhiker's Guide to the Galaxy a series?"
- "Find books on stoic philosophy"
- "What year was To Kill a Mockingbird published?"
- "Books similar to Neuromancer"
- "Latest books by Brandon Sanderson"
