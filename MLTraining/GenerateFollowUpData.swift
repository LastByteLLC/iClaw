#!/usr/bin/env swift

// GenerateFollowUpData.swift
// Generates training and validation data for the follow-up turn-pair classifier.
//
// Format: [PRIOR_TOOL:X] [PRIOR] prior_input [CURRENT] current_input
// Labels: continuation, refinement, drill_down, retry, pivot, meta
//
// Usage: swift GenerateFollowUpData.swift
// Run from the MLTraining/ directory.

import Foundation

// MARK: - Data Structures

struct TurnPair: Codable {
    let text: String
    let label: String
}

// MARK: - Template Definitions

/// Prior tool contexts with realistic inputs
let priorContexts: [(tool: String, inputs: [String])] = [
    ("weather", [
        "weather in Paris", "what's the forecast for Tokyo", "is it raining in London",
        "temperature in Chicago", "will it snow tomorrow", "weather forecast this weekend",
        "how cold is it outside", "humidity levels today", "do I need an umbrella",
    ]),
    ("time", [
        "what time is it in Tokyo", "current time in London", "time in New York",
        "what's the local time", "time zone for Sydney",
    ]),
    ("Stocks", [
        "AAPL stock price", "how is Tesla doing", "check MSFT stock",
        "stock quote for Amazon", "NVDA price",
    ]),
    ("email.read", [
        "check my email", "any new emails", "unread messages in my inbox",
        "emails from John", "search email for invoice",
    ]),
    ("email.compose", [
        "send an email to Sarah", "compose an email about the meeting",
        "draft an email to my boss", "email mom happy birthday",
    ]),
    ("nav.directions", [
        "directions to the airport", "how far to downtown", "navigate to Starbucks",
        "route to the grocery store", "eta to work",
    ]),
    ("news", [
        "latest news", "top headlines today", "what's happening in the world",
        "breaking news", "news about AI",
    ]),
    ("calculator", [
        "what's 42 times 19", "calculate 15% of 230", "square root of 144",
        "what is 100 divided by 7",
    ]),
    ("convert", [
        "convert 10 miles to kilometers", "100 fahrenheit in celsius",
        "how many cups in a gallon", "5 feet to meters",
    ]),
    ("text.translate", [
        "translate hello to Spanish", "how do you say goodbye in French",
        "translate thank you to Japanese", "what is dog in German",
    ]),
    ("text.define", [
        "define serendipity", "what does ephemeral mean",
        "definition of ubiquitous", "meaning of the word cacophony",
    ]),
    ("media.podcast", [
        "search for a podcast about history", "play the latest episode of the daily",
        "find a podcast on technology", "podcast recommendations",
    ]),
    ("search.research", [
        "research quantum computing", "deep dive into how compilers work",
        "help me understand distributed systems", "explain microservices",
    ]),
    ("search.web", [
        "google best restaurants nearby", "search for swift tutorials",
        "look up the capital of france", "search the web for hiking trails",
    ]),
    ("search.wiki", [
        "wikipedia article on black holes", "look up einstein on wikipedia",
        "tell me about the roman empire", "wiki page for photosynthesis",
    ]),
    ("system.app", [
        "open Safari", "launch Chrome", "switch to Finder",
        "open Xcode", "start Spotify",
    ]),
    ("timer", [
        "set a timer for 10 minutes", "start a 5 minute timer",
        "countdown 30 seconds", "timer 3 minutes",
    ]),
    ("random", [
        "roll a dice", "flip a coin", "random number between 1 and 100",
        "draw a card",
    ]),
    ("create", [
        "create an image of a sunset", "generate a picture of a cat",
        "draw me a dragon", "sketch a mountain landscape",
    ]),
    ("calendar.view", [
        "what day is christmas", "how many days until new years",
        "when is easter this year", "is 2028 a leap year",
    ]),
    ("calendar.search", [
        "what's on my calendar today", "do I have any meetings",
        "show my appointments", "any events tomorrow",
    ]),
    ("reminders.create", [
        "remind me to buy milk", "set a reminder for dentist tomorrow",
        "add to my todo list", "create a reminder",
    ]),
    ("contacts.view", [
        "find john's phone number", "look up sarah's email",
        "what's mom's address", "search contacts for dave",
    ]),
    ("messages.send", [
        "text mom I'll be home soon", "send a message to john",
        "imessage sarah about dinner", "tell dad I'm on my way",
    ]),
]

// MARK: - Continuation Templates

/// Same topic, new or additional parameter
let continuationCurrents: [(tool: String, inputs: [String])] = [
    ("weather", [
        "and London?", "what about Berlin?", "how about tomorrow?", "and in Chicago?",
        "New York?", "what about next week?", "and Sydney?", "Tokyo?", "and Madrid?",
        "how about this weekend?", "what about tonight?", "and in Seattle?",
        "Moscow?", "and Dubai?", "what about Wednesday?", "Rome?",
        "and for Thursday?", "San Francisco?", "what about LA?",
        // Bare temporal words — critical for follow-up detection without NER backing
        "tomorrow?", "today?", "tonight?", "this weekend?", "next week?",
        "Monday?", "Tuesday?", "Wednesday?", "Thursday?", "Friday?",
        "Saturday?", "Sunday?", "next month?", "this evening?",
    ]),
    ("time", [
        "and London?", "what about Tokyo?", "and New York?", "Sydney?",
        "Paris?", "what about Dubai?", "and Berlin?", "Seoul?",
        "and in Los Angeles?", "Mumbai?",
    ]),
    ("Stocks", [
        "and TSLA?", "what about Google?", "MSFT?", "and Amazon?",
        "how about NVDA?", "and Meta?", "check Netflix too",
        "$AMZN?", "what about Apple?",
    ]),
    ("email.read", [
        "and from Sarah?", "any from my boss?", "what about last week?",
        "and unread ones?", "from the marketing team?",
    ]),
    ("nav.directions", [
        "and to the mall?", "what about by walking?", "and from downtown?",
        "how about by transit?", "to the park instead?",
    ]),
    ("news", [
        "what about sports?", "and technology?", "any about politics?",
        "what about climate?", "and business news?", "health news?",
    ]),
    ("convert", [
        "and to miles?", "what about liters?", "and in pounds?",
        "to celsius?", "and gallons?",
    ]),
    ("text.translate", [
        "and in French?", "what about Japanese?", "and to German?",
        "in Korean?", "and Italian?", "to Arabic?",
    ]),
    ("media.podcast", [
        "what about true crime?", "and science podcasts?", "any about comedy?",
        "and tech podcasts?", "what about business?",
    ]),
    ("search.research", [
        "what about machine learning?", "and blockchain?",
        "how about edge computing?", "and cybersecurity?",
    ]),
    ("search.web", [
        "what about in Italian?", "and nearby?", "and reviews?",
        "what about prices?",
    ]),
    ("calendar.view", [
        "and July 4th?", "what about next year?", "and New Year's?",
        "how about 2027?", "tomorrow?", "next week?", "this weekend?",
        "Monday?", "next month?",
    ]),
    ("timer", [
        "and another for 5 minutes", "one more for 30 seconds",
        "how much time is left?", "how much time remaining?",
        "is the timer done?", "is it done yet?",
        "cancel the timer", "stop the timer", "pause it",
        "how long is left?", "check the timer",
        "time remaining?", "how many minutes left?",
        "extend it by 2 minutes", "add 5 more minutes",
    ]),
    ("random", [
        "roll again", "one more", "another one",
        "flip again", "roll once more",
    ]),
    ("create", [
        "now with mountains", "but at night", "make it blue",
        "add some clouds", "in watercolor style",
    ]),
]

// MARK: - Refinement Templates

/// Same tool, correcting/adjusting parameters
let refinementCurrents: [String] = [
    // Unit/format changes
    "in celsius", "in fahrenheit", "in metric", "in imperial",
    "in kilometers", "in miles", "in pounds", "in kilograms",
    // Time adjustments
    "no, tomorrow", "I meant next week", "for today instead",
    "no, this weekend", "I meant yesterday", "for Friday",
    // Quantity adjustments
    "make it 10", "no, 5 minutes", "change it to 30",
    "actually 100", "make that 15",
    // Corrections
    "no I meant Paris", "sorry, London", "I said Tokyo",
    "not that one, the other one", "I meant the first one",
    "actually New York", "change to Berlin",
    // Format/style adjustments
    "more detailed", "keep it brief", "just the summary",
    "give me more info", "shorter please", "more concise",
    "in a table", "as a list", "just the numbers",
    // Rate/price qualifiers — refinements for convert/stocks
    "using today's rate", "at current prices", "with today's exchange rate",
    "based on current rate", "at market price", "live rate",
    "at today's exchange rate", "with the latest rate",
]

// MARK: - Drill-Down Templates

/// Wants detail on a specific result
let drillDownCurrents: [String] = [
    // Ordinal references
    "read the first one", "open the second article", "tell me about the third one",
    "click on number 2", "the first result", "article #1",
    "show me the second one", "the third article", "open #3",
    "read article 1", "the 4th one", "number 5",
    // Specific detail requests
    "tell me more about that", "can you elaborate on that",
    "go deeper on that point", "expand on that",
    "what does that mean exactly", "give me more detail",
    "read that article", "open that link", "fetch that page",
    "summarize that one", "read it to me", "open it",
    "more details please", "explain that further",
    "what are the specifics", "break that down for me",
    // Reference to prior content
    "the one about AI", "the article about climate",
    "that result about python", "the one you just mentioned",
    "that headline about the economy",
]

// MARK: - Pivot Templates

/// Entirely new topic — unrelated to prior turn
let pivotCurrents: [(priorTool: String, inputs: [String])] = [
    ("weather", [
        "set a timer for 5 minutes", "what's 42 times 19", "open Safari",
        "translate hello to French", "define serendipity", "roll a dice",
        "check my email", "how many steps today", "play a podcast about history",
        "directions to the airport", "send a text to mom", "take a screenshot",
        "what's on my calendar", "create a reminder", "search for files named report",
        "turn up the volume", "stock price of apple", "convert 5 miles to km",
    ]),
    ("Stocks", [
        "what's the weather", "set a timer", "translate goodbye to Spanish",
        "open Chrome", "flip a coin", "read my email", "take a photo",
        "what day is Christmas", "remind me to buy milk", "write a haiku",
    ]),
    ("email.read", [
        "what time is it in Tokyo", "weather in London", "set a timer for 10 minutes",
        "directions to Starbucks", "play joe rogan podcast", "define ubiquitous",
        "roll a d20", "how much is 100 divided by 7", "open Xcode",
    ]),
    ("nav.directions", [
        "check my email", "what's the weather", "define entropy",
        "set timer 5 min", "stock price of Tesla", "flip a coin",
        "translate this to Italian", "take a screenshot", "battery percentage",
    ]),
    ("news", [
        "set a timer for 30 seconds", "weather in Paris", "open Safari",
        "what's 2 + 2", "translate hello to Korean", "define love",
        "roll a dice", "check my inbox", "how many steps today",
    ]),
    ("calculator", [
        "what's the weather", "open Chrome", "check my email",
        "set a timer", "translate to French", "stock price AAPL",
        "take a screenshot", "directions home", "play a podcast",
    ]),
    ("text.translate", [
        "weather in Tokyo", "check my email", "set a timer for 5 minutes",
        "open Safari", "roll a dice", "stock price of Apple",
        "directions to the mall", "define serendipity", "battery percentage",
    ]),
    ("timer", [
        "what's the weather", "check my email", "open Chrome",
        "translate hello", "define entropy", "roll a dice",
        "stock price MSFT", "directions home", "latest news",
    ]),
    ("media.podcast", [
        "weather in London", "what time is it", "set timer 5 min",
        "check my email", "open Safari", "calculate 15% of 200",
        "convert 10 km to miles", "define paradigm",
    ]),
    ("search.research", [
        "set a timer", "weather in Berlin", "check my inbox",
        "open Xcode", "flip a coin", "stock price of Google",
        "translate thanks to Japanese", "take a screenshot",
    ]),
    ("create", [
        "what time is it", "check my email", "weather in Tokyo",
        "define serendipity", "set a timer for 5 minutes", "stock price AAPL",
        "convert 100 fahrenheit", "latest news",
    ]),
    ("calendar.search", [
        "weather in Paris", "check my email", "open Safari",
        "set a timer", "translate hello", "define entropy",
    ]),
    ("messages.send", [
        "weather in London", "set timer 10 min", "check my email",
        "open Chrome", "directions to work", "stock price TSLA",
    ]),
]

// MARK: - Meta Templates

/// About the system itself
let metaCurrents: [String] = [
    "why did you use that tool", "how does that work",
    "what tools do you have", "can you do that differently",
    "why that answer", "explain your reasoning",
    "what other tools can you use", "how did you get that",
    "is that accurate", "are you sure about that",
    "what source did you use", "where did that come from",
    "can you do better",
    "how do you work", "what are your capabilities",
    "tell me about yourself", "what can you do",
    "is there a better way to do that", "why not a different approach",
    "how confident are you", "what's your accuracy",
    "can you explain step by step",
    "what model are you using", "are you an AI",
]

/// Tool-reflective meta questions — paired with specific prior tools
let metaToolReflective: [(priorTools: [String], inputs: [String])] = [
    (["calculator", "convert"], [
        "how did you calculate that", "walk me through that calculation",
        "explain the math", "what formula did you use",
        "show me the steps", "how did you get that number",
        "what method did you use for that", "break down the calculation",
        "why did you use that formula", "explain the conversion",
    ]),
    (["search.web", "search.wiki", "search.research"], [
        "how did you search for that", "what did you look up",
        "walk me through that search", "why did you use that source",
        "what search terms did you use", "how did you find that",
        "where did you search", "explain how you found that",
        "what database did you search", "why that search engine",
    ]),
    (["text.translate"], [
        "how did you translate that", "why that translation",
        "is that translation accurate", "explain the translation",
        "walk me through the translation", "what language model did you use for that",
        "are there alternative translations", "why did you pick that phrasing",
    ]),
    (["text.define"], [
        "how did you look that up", "what dictionary did you use",
        "where did that definition come from", "explain the etymology",
        "walk me through that definition",
    ]),
    (["weather"], [
        "how did you get that forecast", "what weather source did you use",
        "where does that data come from", "explain the forecast",
        "how accurate is that weather data", "what model is this forecast based on",
    ]),
    (["Stocks"], [
        "where did you get that stock price", "how did you look that up",
        "what source did you use for the price", "explain the stock data",
        "how current is that price", "where does that financial data come from",
    ]),
    (["nav.directions"], [
        "how did you get those directions", "what mapping service did you use",
        "explain the route", "why that route",
        "how did you calculate the distance",
    ]),
    (["media.podcast"], [
        "how did you find that podcast", "what did you search for",
        "explain how you found that", "where did you look for podcasts",
    ]),
    (["news"], [
        "where did you get that news", "what news source is that",
        "how did you find that article", "explain the source",
        "how current is that news",
    ]),
    (["timer"], [
        "how did you set that timer", "explain the timer",
        "what method did you use for that",
    ]),
    (["random"], [
        "how did you generate that", "what random method did you use",
        "is that truly random", "explain the randomness",
        "how did you roll that",
    ]),
    (["email.read", "email.compose"], [
        "how did you access my email", "what email client did you use",
        "explain how you read that", "how did you search my inbox",
    ]),
]

// MARK: - Retry Templates

/// User wants to re-execute the prior tool with the same/similar input
let retryCurrents: [String] = [
    // Core retry phrases — each should be distinctive enough for MaxEnt
    "try again", "retry", "do it again", "again", "one more time",
    "redo that", "do it over", "re-run that", "another attempt",
    "can you try that again", "try once more", "give it another shot",
    "let's try that again", "repeat that", "again please",
    "try that again", "run it again", "do that again", "once more",
    "go again",
    // Natural conversation variants for higher coverage
    "try it again", "could you try again", "please try again",
    "try one more time", "can you retry", "please retry that",
    "let's do that again", "let's try once more",
    "could you do that again", "would you try again",
    "mind trying again", "try it once more", "one more try",
    "another try please", "retry please", "let's retry",
    "do over", "start over", "try from scratch",
    "can you redo that", "please redo", "redo it",
    "that didn't work try again", "it failed try again",
    "that was wrong try again", "nope try again",
]

// MARK: - Generic Continuation Templates (tool-agnostic)

/// Short follow-up fragments that work as continuations for any tool
let genericContinuationCurrents: [String] = [
    "and what about tomorrow?", "how about next week?", "what about Monday?",
    "and for the weekend?", "and this evening?", "how about Friday?",
    "also for June?", "and yesterday?", "the same but for December",
    "what about the other one?", "and the alternative?", "the second option?",
    "same thing but bigger", "now in reverse", "the opposite?",
    "and for my wife?", "also for the kids?", "and for the team?",
    "what if it's raining?", "and at night?", "during the summer?",
    "but cheaper?", "a faster option?", "the closest one?",
    "compared to last time?", "versus the original?", "the updated version?",
]

// MARK: - Generic Pivot Templates (tool-agnostic)

/// Clearly unrelated new topics that work as pivots after any tool
let genericPivotCurrents: [String] = [
    "set a timer for 5 minutes", "what's 42 times 19", "open Safari",
    "translate hello to French", "define serendipity", "roll a dice",
    "check my email", "how many steps today", "play a podcast",
    "directions to the airport", "send a text to mom", "take a screenshot",
    "what's on my calendar", "create a reminder", "turn up the volume",
    "stock price of Apple", "convert 5 miles to km", "weather in Tokyo",
    "what time is it", "flip a coin", "read my inbox",
    "open Chrome", "battery percentage", "write a haiku about rain",
    "search for swift tutorials", "latest news", "draw me a dragon",
    "mute the sound", "dim the screen", "check disk space",
    "remind me to buy milk", "find john's phone number",
    "text dad I'm on my way", "run my morning shortcut",
    "what day is christmas", "how many days until new years",
    "wikipedia article on black holes", "create a new note",
    "read the file at ~/report.txt", "paste from clipboard",
    // Short 3-4 word commands — must not be misclassified as follow-ups
    "find nearby coffee shops", "find the nearest restaurant",
    "find nearby gas stations", "find nearby pharmacies",
    "search for python tutorials", "search for recipes",
    "set a timer", "translate hello to Spanish",
    "convert 100 miles", "define serendipity",
    "calculate 15% tip", "check my inbox",
]

/// Self-contained informational queries that are pivots even after related tools.
/// The classifier must learn that inputs with their OWN explicit topic are new
/// requests, not follow-ups — regardless of how "related" the domain feels.
/// Crossed with ALL prior tools (especially informational ones: news, wiki, research).
let topicSwitchPivotCurrents: [String] = [
    // History & civilizations
    "tell me about the Roman Empire",
    "tell me about ancient Egypt",
    "tell me about the Renaissance",
    "tell me about the Ottoman Empire",
    "tell me about the Viking Age",
    "what caused World War 1",
    "what caused the French Revolution",
    "how did the Cold War start",
    "who was Genghis Khan",
    "who was Cleopatra",
    "who invented the printing press",
    "who invented the telephone",
    "when was the Great Wall of China built",
    // Science & technology
    "explain how nuclear reactors work",
    "explain the theory of relativity",
    "explain photosynthesis",
    "explain how batteries work",
    "explain how airplanes fly",
    "how do vaccines work",
    "how does GPS work",
    "how do electric cars work",
    "how does the internet work",
    "how does a computer processor work",
    "how do solar panels work",
    "how does CRISPR gene editing work",
    "what is quantum computing",
    "what is machine learning",
    "what is blockchain technology",
    "what is dark matter",
    "what is the Fibonacci sequence",
    "what is string theory",
    "what is the greenhouse effect",
    "what is CERN",
    // Geography & nature
    "tell me about the Amazon rainforest",
    "tell me about Mount Everest",
    "tell me about the Sahara Desert",
    "tell me about the Mariana Trench",
    "what country has the largest population",
    "where is the deepest ocean",
    "how are diamonds formed",
    "how do volcanoes erupt",
    "what causes earthquakes",
    "what causes the northern lights",
    // Culture & society
    "tell me about the history of the internet",
    "tell me about the Olympic Games",
    "tell me about the United Nations",
    "how does the stock market work",
    "how does the electoral college work",
    "what is the European Union",
    "what is NATO",
    "who wrote Romeo and Juliet",
    "who painted the Mona Lisa",
    "what is the International Space Station",
    // Medicine & health
    "what is diabetes",
    "how does anesthesia work",
    "what causes cancer",
    "how does the immune system work",
    "what is MRNA technology",
    // Space & astronomy
    "tell me about black holes",
    "tell me about Mars",
    "how far away is the moon",
    "what is a neutron star",
    "how do rockets work",
    "what is the James Webb telescope",
    // "Tell me about" / "What is" / "How does" patterns with diverse topics
    "tell me about supply chain logistics",
    "tell me about the Silk Road",
    "tell me about the Hubble telescope",
    "what is inflation in economics",
    "what is the butterfly effect",
    "what is an aurora borealis",
    "how does wireless charging work",
    "how does a refrigerator work",
    "how does radar work",
    "how does 3D printing work",
    "how does a nuclear submarine work",
    "what are tectonic plates",
    "what is the Doppler effect",
    "what is a superconductor",
    "explain how DNA replication works",
    "explain the water cycle",
    "explain how the brain processes language",
    "explain how cryptography works",
    "explain the difference between RNA and DNA",
    "explain how transistors work",
]

/// Correction/negation patterns — the user rejects the prior interpretation.
/// These are ALWAYS pivots: the negation prefix signals the prior tool was wrong.
/// Trained as pivot so the classifier learns negation-initial structure = pivot.
let negationPivotCurrents: [String] = [
    "no, I want something else",
    "no, I meant the fruit",
    "no, I wanted the city in Texas",
    "no, search Wikipedia instead",
    "no, look that up on the web",
    "no, I need the calculator",
    "no, convert it instead",
    "not that, I want the weather",
    "not that one, the other tool",
    "actually I wanted news",
    "actually, translate it instead",
    "actually, I meant the stock price",
    "I meant the country not the person",
    "I meant the band not the city",
    "I meant the movie not the book",
    "wrong one, I need directions",
    "that's not what I asked, I want the timer",
    "nope, check my calendar instead",
    "instead, tell me the time",
    "instead, give me the definition",
    "I didn't ask for that, I want stock data",
    "I didn't want weather, I want news",
    "no, I want to know about the fruit not the company",
    "no, the country not the company",
    "actually, I want to know about the animal",
    "no, look up the person not the place",
    "not the stock, I want general information",
    "no, use a different tool for this",
    "wrong, I need a calculation",
    "I asked for a timer not the time",
]

/// Comparison patterns — the user wants the same tool to compare a new item
/// with the prior result. These are continuations, NOT pivots.
let comparisonContinuationCurrents: [String] = [
    "how does that compare to London?",
    "how does that compare to Google?",
    "how does that compare to yesterday?",
    "compare that to last week",
    "compare that to Paris",
    "compare that with Tokyo",
    "which is higher?",
    "which is better?",
    "which is cheaper?",
    "which one is bigger?",
    "is that more or less than Berlin?",
    "is that higher than Apple?",
    "is that warmer than New York?",
    "what about compared to Amazon?",
    "how is that versus the S&P 500?",
    "versus Microsoft?",
    "and how does that stack up against Tesla?",
    "now compare with the previous one",
    "is that more than before?",
    "which is the better deal?",
]

// MARK: - Data Generation

func formatPair(priorTool: String, priorInput: String, currentInput: String) -> String {
    "[PRIOR_TOOL:\(priorTool)] [PRIOR] \(priorInput) [CURRENT] \(currentInput)"
}

func generateData() -> [TurnPair] {
    var pairs: [TurnPair] = []

    // 1. Continuations — tool-specific follow-ups
    for continuation in continuationCurrents {
        let matchingPriors = priorContexts.filter { $0.tool == continuation.tool }
        for prior in matchingPriors {
            for priorInput in prior.inputs {
                for currentInput in continuation.inputs {
                    pairs.append(TurnPair(
                        text: formatPair(priorTool: prior.tool, priorInput: priorInput, currentInput: currentInput),
                        label: "continuation"
                    ))
                }
            }
        }
    }

    // 1b. Generic continuations — short follow-ups that work for any prior tool
    for prior in priorContexts {
        for priorInput in prior.inputs {
            for currentInput in genericContinuationCurrents {
                pairs.append(TurnPair(
                    text: formatPair(priorTool: prior.tool, priorInput: priorInput, currentInput: currentInput),
                    label: "continuation"
                ))
            }
        }
    }

    // 2. Refinements — same tool, parameter correction (tool-agnostic)
    for prior in priorContexts {
        for priorInput in prior.inputs {
            for currentInput in refinementCurrents {
                pairs.append(TurnPair(
                    text: formatPair(priorTool: prior.tool, priorInput: priorInput, currentInput: currentInput),
                    label: "refinement"
                ))
            }
        }
    }

    // 3. Drill-downs — detail on specific result (tool-agnostic)
    for prior in priorContexts {
        for priorInput in prior.inputs {
            for currentInput in drillDownCurrents {
                pairs.append(TurnPair(
                    text: formatPair(priorTool: prior.tool, priorInput: priorInput, currentInput: currentInput),
                    label: "drill_down"
                ))
            }
        }
    }

    // 4. Pivots — tool-specific topic changes
    for pivot in pivotCurrents {
        let matchingPriors = priorContexts.filter { $0.tool == pivot.priorTool }
        for prior in matchingPriors {
            for priorInput in prior.inputs {
                for currentInput in pivot.inputs {
                    pairs.append(TurnPair(
                        text: formatPair(priorTool: prior.tool, priorInput: priorInput, currentInput: currentInput),
                        label: "pivot"
                    ))
                }
            }
        }
    }

    // 4b. Generic pivots — clearly unrelated topics after any prior tool
    for prior in priorContexts {
        for priorInput in prior.inputs {
            for currentInput in genericPivotCurrents {
                // Skip if the pivot input matches the prior tool's domain
                // (e.g., don't create a "pivot" from weather to "weather in Tokyo")
                let priorDomain = prior.tool.components(separatedBy: ".").first ?? prior.tool
                let looksLikeSameDomain = currentInput.lowercased().contains(priorDomain)
                if !looksLikeSameDomain {
                    pairs.append(TurnPair(
                        text: formatPair(priorTool: prior.tool, priorInput: priorInput, currentInput: currentInput),
                        label: "pivot"
                    ))
                }
            }
        }
    }

    // 4c. Topic-switch pivots — self-contained informational queries that are
    // pivots even after related tools. These have their own explicit subject
    // ("tell me about X", "explain Y", "how does Z work") and should NOT be
    // classified as continuations of a prior informational tool.
    for prior in priorContexts {
        for priorInput in prior.inputs {
            for currentInput in topicSwitchPivotCurrents {
                pairs.append(TurnPair(
                    text: formatPair(priorTool: prior.tool, priorInput: priorInput, currentInput: currentInput),
                    label: "pivot"
                ))
            }
        }
    }

    // 4d. Negation pivots — corrections that reject the prior tool's interpretation
    for prior in priorContexts {
        for priorInput in prior.inputs {
            for currentInput in negationPivotCurrents {
                pairs.append(TurnPair(
                    text: formatPair(priorTool: prior.tool, priorInput: priorInput, currentInput: currentInput),
                    label: "pivot"
                ))
            }
        }
    }

    // 4e. Comparison continuations — "compare to X" uses the same tool
    for prior in priorContexts {
        for priorInput in prior.inputs {
            for currentInput in comparisonContinuationCurrents {
                pairs.append(TurnPair(
                    text: formatPair(priorTool: prior.tool, priorInput: priorInput, currentInput: currentInput),
                    label: "continuation"
                ))
            }
        }
    }

    // 5. Meta — about the system (tool-agnostic)
    for prior in priorContexts {
        for priorInput in prior.inputs {
            for currentInput in metaCurrents {
                pairs.append(TurnPair(
                    text: formatPair(priorTool: prior.tool, priorInput: priorInput, currentInput: currentInput),
                    label: "meta"
                ))
            }
        }
    }

    // 5b. Meta — tool-reflective questions paired with relevant prior tools
    for reflective in metaToolReflective {
        for toolName in reflective.priorTools {
            let matchingPriors = priorContexts.filter { $0.tool == toolName }
            for prior in matchingPriors {
                for priorInput in prior.inputs {
                    for currentInput in reflective.inputs {
                        pairs.append(TurnPair(
                            text: formatPair(priorTool: prior.tool, priorInput: priorInput, currentInput: currentInput),
                            label: "meta"
                        ))
                    }
                }
            }
        }
    }

    // 6. Retry — re-execute the prior tool with the same/similar input (tool-agnostic)
    for prior in priorContexts {
        for priorInput in prior.inputs {
            for currentInput in retryCurrents {
                pairs.append(TurnPair(
                    text: formatPair(priorTool: prior.tool, priorInput: priorInput, currentInput: currentInput),
                    label: "retry"
                ))
            }
        }
    }

    return pairs
}

// MARK: - Main

let separator = String(repeating: "=", count: 60)
print(separator)
print("Follow-Up Classifier Training Data Generator")
print(separator)

var allPairs = generateData()
print("Generated \(allPairs.count) raw pairs")

// Deduplicate
let uniqueTexts = Set(allPairs.map(\.text))
allPairs = Array(Set(allPairs.map(\.text)).compactMap { text in
    allPairs.first { $0.text == text }
})
print("After dedup: \(allPairs.count) unique pairs")

// Shuffle
allPairs.shuffle()

// Count per label
var labelCounts: [String: Int] = [:]
for pair in allPairs {
    labelCounts[pair.label, default: 0] += 1
}
print("\nLabel distribution:")
for (label, count) in labelCounts.sorted(by: { $0.key < $1.key }) {
    print("  \(label): \(count)")
}

// Balance: cap overrepresented labels
let targetMax = 5000
var balanced: [TurnPair] = []
var perLabelCount: [String: Int] = [:]
for pair in allPairs {
    let current = perLabelCount[pair.label, default: 0]
    if current < targetMax {
        balanced.append(pair)
        perLabelCount[pair.label] = current + 1
    }
}
allPairs = balanced

print("\nAfter balancing (max \(targetMax) per label):")
perLabelCount = [:]
for pair in allPairs {
    perLabelCount[pair.label, default: 0] += 1
}
for (label, count) in perLabelCount.sorted(by: { $0.key < $1.key }) {
    print("  \(label): \(count)")
}

// Split: 90% training, 10% validation
let splitIndex = Int(Double(allPairs.count) * 0.9)
let training = Array(allPairs[..<splitIndex])
let validation = Array(allPairs[splitIndex...])

print("\nTraining: \(training.count), Validation: \(validation.count)")

// Write files
let baseDir = FileManager.default.currentDirectoryPath
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]

let trainingData = try encoder.encode(training)
try trainingData.write(to: URL(fileURLWithPath: "\(baseDir)/followup_training.json"))

let validationData = try encoder.encode(validation)
try validationData.write(to: URL(fileURLWithPath: "\(baseDir)/followup_validation.json"))

print("\nWritten to:")
print("  \(baseDir)/followup_training.json")
print("  \(baseDir)/followup_validation.json")
print(separator)
