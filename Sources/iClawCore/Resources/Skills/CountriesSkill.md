# Countries Skill

A skill for retrieving factual information about countries using the free RestCountries API. Use the `webfetch` tool to query https://restcountries.com/v3.1/name/{country} for country-specific data.

For a single country lookup, use:
https://restcountries.com/v3.1/name/{country}?fields=name,capital,currencies,languages,flag,region,subregion,population,car,tld,timezones,continents,borders,idd,demonyms,fifa

For comparative queries across all countries, use:
https://restcountries.com/v3.1/all?fields=name,capital,currencies

Available fields include: name, capital, currencies, languages, flag (emoji), flags (image URLs), region, subregion, population, area, timezones, continents, borders, car (driving side), maps, idd (calling codes), tld (top-level domain), demonyms, gini, fifa.

Always present the flag emoji alongside the country name in your response. Parse the JSON response and present key facts clearly.

## Examples

- "What is the capital of France?"
- "What currency does Japan use?"
- "Which side of the road do they drive on in the UK?"
- "What's the population of Brazil?"
- "Tell me about Germany"
- "What languages are spoken in Switzerland?"
- "What is the flag of Canada?"
- "What's the calling code for Australia?"
- "What region is Nigeria in?"
- "What's the top-level domain for Iceland?"
- "Compare the currencies of France and Germany"
