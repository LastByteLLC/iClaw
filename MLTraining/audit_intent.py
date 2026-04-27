#!/usr/bin/env python3
"""
Audit intent classifier training data for mislabels, ambiguity, duplicates,
low-quality entries, and generator artifacts.
"""

import json
import os
from collections import defaultdict

FILES = [
    "intent_data_a.jsonl",
    "intent_data_b.jsonl",
    "intent_data_c.jsonl",
    "intent_data_d_hard.jsonl",
    "intent_data_e_boundaries.jsonl",
]

BASE = os.path.dirname(os.path.abspath(__file__))
OUT_PATH = os.path.join(BASE, "intent_audit.jsonl")

CAP = 500

# -----------------------------------------------------------------------
# Low-quality heuristics
# -----------------------------------------------------------------------

def is_cjk(ch: str) -> bool:
    cp = ord(ch)
    return (
        0x3040 <= cp <= 0x30FF  # Hiragana + Katakana
        or 0x4E00 <= cp <= 0x9FFF  # CJK Unified Ideographs
        or 0xAC00 <= cp <= 0xD7AF  # Hangul Syllables
        or 0x3400 <= cp <= 0x4DBF  # CJK Extension A
    )


def is_low_quality(text: str) -> bool:
    t = text.strip()
    if not t:
        return True
    # Single-char CJK tokens are full words — not low quality.
    if len(t) == 1:
        if is_cjk(t):
            return False
        return True
    if all(not c.isalnum() for c in t):
        return True
    return False


def is_all_caps_yelling(text: str) -> bool:
    """Text is primarily uppercase letters, not a tiny acronym."""
    t = text.strip()
    letters = [c for c in t if c.isalpha() and ord(c) < 128]  # latin letters only
    if len(letters) < 10:
        return False
    upper = sum(1 for c in letters if c.isupper())
    return upper / len(letters) >= 0.9


def has_severe_typo(text: str) -> bool:
    """Contains obvious/multiple nonsense typos."""
    tl = text.lower()
    typos = [
        "emal", "gaem", "plya", "paly", "enxt",
        "tmoorrow", "huor", "nwes", "shwo ", "shw file",
        "tothe just", "wheredo", "opne ", "exportthe",
        "tim eo'clock",
    ]
    return any(t in tl for t in typos)


# -----------------------------------------------------------------------
# Manually curated flags for intent_data_c (high-noise mined data)
# Map: canonical text string -> (suggested_label, issue_type)
# If issue_type is None, keep as-is (skip flagging).
# -----------------------------------------------------------------------

C_FLAGS = {
    # -------- wrong_label: should be conversation (opinion/advice/emotional) --------
    "What are the signs I should look for to know I'm stressed?": ("conversation", "wrong_label"),
    "Is there something to ease my anxiety right now?": ("conversation", "wrong_label"),
    "I’m really struggling to stay alert, something’s got to change!": ("conversation", "wrong_label"),
    "Relaxation methods": ("conversation", "wrong_label"),
    "Do you have any tips for maintaining a positive mindset while I’m enjoying some downtime at home?": ("conversation", "wrong_label"),
    "So, how can I keep my immune system on point while just chilling and trying to stay away from the outside world?": ("conversation", "wrong_label"),
    "How to be fit?": ("conversation", "wrong_label"),
    "I need health tips now.": ("conversation", "wrong_label"),
    "Need health tips now.": ("conversation", "wrong_label"),
    "I need health tips": ("conversation", "wrong_label"),
    "Ideas for mindful breathing exercises while I watch TV.": ("conversation", "wrong_label"),
    "What's the best snack for focus?": ("conversation", "wrong_label"),
    "What spices can I throw on my steak for extra flavor?": ("conversation", "wrong_label"),
    "What’s a good, healthy breakfast I can prep?": ("conversation", "wrong_label"),
    "Can stress cause real physical pain? Because I’m feeling it badly while driving and it’s freaking me out!": ("conversation", "wrong_label"),
    "Ugh, I’ve got to find a way to manage my study stress!": ("conversation", "wrong_label"),
    "What's a good way to relax while I'm at home?": ("conversation", "wrong_label"),
    "Every single burner on my stove is in use right now and I am so stressed trying to juggle everything properly!": ("conversation", "wrong_label"),
    "I had this wild idea to try out a completely different route home today; it could either be amazing or a disaster!": ("conversation", "wrong_label"),
    "Do you ever just want to dive into something random that makes you smile? I really need that right now!": ("conversation", "wrong_label"),
    "I’m lost on numbers": ("conversation", "wrong_label"),
    "This lag is driving me nuts!": ("conversation", "wrong_label"),
    "Why do I even bother with the clipboard? Every time I try to copy, it’s like it decides to ghost me!": ("conversation", "wrong_label"),
    "I thought the clipboard was supposed to make things easier, but now I can't copy anything right!": ("conversation", "wrong_label"),
    "The software is being super glitchy right now, and I seriously can’t deal with this while preparing for my exam!": ("conversation", "wrong_label"),
    "Why can't I get a simple translation for this complicated French phrase? It shouldn't be that hard!": ("conversation", "wrong_label"),
    "Can’t remember his email, ugh!": ("conversation", "wrong_label"),
    "Where’s my damn email?": ("conversation", "wrong_label"),
    "food ideas": ("conversation", "wrong_label"),
    "What’s a dish that nobody would ever think to make together? I want my dinner to be a total surprise tonight!": ("conversation", "wrong_label"),
    "I think it would be fun if we shared any random hobbies or interests that might surprise the team during this meeting!": ("conversation", "wrong_label"),
    "Is it just me, or would it be refreshing if we shared a random quote or two that inspires us in our work?": ("conversation", "wrong_label"),
    "How about a random idea?": ("conversation", "wrong_label"),
    "Can you share a random thought or idea with me?": ("conversation", "wrong_label"),
    "Can I get some randomness to spice up my drive?": ("conversation", "wrong_label"),
    "Dude, what’s some random stuff I can think about while driving?": ("conversation", "wrong_label"),
    "Random stuff to study right now?": ("conversation", "wrong_label"),
    "How about we lighten the mood with a random thought or two before diving into the serious stuff today?": ("conversation", "wrong_label"),
    "Why’s it so hard to understand?": ("conversation", "wrong_label"),
    "just Why’s it so hard to understand?": ("conversation", "wrong_label"),
    "Oh, could you help me plan a movie night this weekend?": ("conversation", "wrong_label"),
    "Hey, can you shoot me the recipe for those cookies?": ("conversation", "wrong_label"),
    "Is it time to sell stocks?": ("conversation", "wrong_label"),
    "What time should I take my lunch break to make sure I return in time for the afternoon session?": ("conversation", "wrong_label"),
    "What time should I set my alarm for tomorrow?": ("conversation", "wrong_label"),
    "Can you tell me when to check my cookies?": ("conversation", "wrong_label"),

    # -------- wrong_label: should be knowledge (factual/educational) --------
    "what's a black hole": ("knowledge", "wrong_label"),
    "whats a llama?": ("knowledge", "wrong_label"),
    "can you teach me about site reliability engineering?": ("knowledge", "wrong_label"),
    "can you i want to learn about urban planning?": ("knowledge", "wrong_label"),
    "can you teach me about autonomous vehicles?": ("knowledge", "wrong_label"),
    "can you teach me about synthetic biology?": ("knowledge", "wrong_label"),
    "can you deep dive into rockets?": ("knowledge", "wrong_label"),
    "can you deep dive into battery technology?": ("knowledge", "wrong_label"),
    "deep dive into programming languages": ("knowledge", "wrong_label"),
    "deep dive into DevOps practices": ("knowledge", "wrong_label"),
    "break down serverless architecture": ("knowledge", "wrong_label"),
    "research rockets": ("knowledge", "wrong_label"),
    "dig into GraphQL": ("knowledge", "wrong_label"),
    "can you investigate gig economy?": ("knowledge", "wrong_label"),
    "can you help me understand rust programming?": ("knowledge", "wrong_label"),
    "help me understand the difference between machine learning and deep learning": ("knowledge", "wrong_label"),
    "describe blockchain": ("knowledge", "wrong_label"),
    "tell me about Nvidia's history": ("knowledge", "wrong_label"),
    "help me with Shakespeare": ("knowledge", "wrong_label"),
    "Need help with French vocab.": ("knowledge", "wrong_label"),
    "major figures of the World War 1": ("knowledge", "wrong_label"),
    "list the landmarks for Moscow": ("knowledge", "wrong_label"),
    "career highlights of Mahatma Gandhi": ("knowledge", "wrong_label"),
    "list medal count for Usain Bolt": ("knowledge", "wrong_label"),
    "Shohei Ohtani batting average comparison with Roger Federer": ("knowledge", "wrong_label"),
    "compare nutritional content of banana and brown rice": ("knowledge", "wrong_label"),
    "head to head: Sony WF-1000XM5 vs Samsung Galaxy Buds": ("knowledge", "wrong_label"),
    "head to head: Subaru Outback vs Ford F-150": ("knowledge", "wrong_label"),
    "AirPods Pro compared to Bose QC Ultra storage": ("knowledge", "wrong_label"),
    "compare the tesla model 3 standard range plus and model y long range specs": ("knowledge", "wrong_label"),
    "compare the safety ratings of Toyota Camry vs Nissan Leaf!": ("knowledge", "wrong_label"),
    "compare government of Indonesia and Germany": ("knowledge", "wrong_label"),
    "so like list countries that are in the European Union": ("knowledge", "wrong_label"),
    "Dude, how many calories in 3 slices of pizza?": ("knowledge", "wrong_label"),
    "Chillin' on my couch, I can't stop thinking about the Renaissance. Like, what was all the fuss about art and science back then? Wikipedia’s gotta know!": ("knowledge", "wrong_label"),
    "um I need to understand more about quantum mechanics for this project; let’s check Wikipedia to get some reliable info.": ("knowledge", "wrong_label"),
    "I’m trying to expand my vocabulary and would love to know the definition of ephemeral while I’m at it.": ("knowledge", "wrong_label"),
    "I’ve come across this term ‘synergy’ a bunch of times while studying but I can’t quite get what it is, can you help?": ("knowledge", "wrong_label"),
    "Could you give an overview of how seasonal ingredients affect cooking styles and recipe selections throughout the year?": ("knowledge", "wrong_label"),
    "Could you look up some facts about the impact of social media on communication trends for our marketing strategy discussion?": ("knowledge", "wrong_label"),
    "How long do I need to simmer the sauce before it’s fully cooked and ready to be served with pasta?": ("knowledge", "wrong_label"),
    "so like How long till my chicken's done?": ("knowledge", "wrong_label"),
    "Is Facebook up or down?": ("knowledge", "wrong_label"),
    "Can you remind me how to roast veggies properly?": ("knowledge", "wrong_label"),

    # -------- wrong_label: should be meta (assistant question / troubleshoot) --------
    "Why isn’t my event showing up on the calendar?": ("meta", "wrong_label"),
    "Why am I not able to listen to the new podcast series I heard about? This tech stuff is so annoying when all I want to do is relax!": ("meta", "wrong_label"),
    "Why is the app hanging? I can’t afford delays!": ("meta", "wrong_label"),
    "My email’s acting up, fix it!": ("meta", "wrong_label"),
    "I can't find how to screenshot, this is frustrating!": ("meta", "wrong_label"),
    "This is ridiculous, my shortcut isn’t launching!": ("meta", "wrong_label"),
    "Shortcuts aren't working right now!": ("meta", "wrong_label"),
    "Is my system even working right now? This is urgent!": ("meta", "wrong_label"),
    "why isn’t it working?": ("meta", "wrong_label"),
    "I was wondering, can I color-code different types of events in my calendar to easily distinguish between work and personal items?": ("meta", "wrong_label"),
    "Hey, what's the quickest way to search?": ("meta", "wrong_label"),
    "What’s the quickest way to get to my research documents?": ("meta", "wrong_label"),

    # -------- generator_artifact (templated/broken phrasing) --------
    "can you i want the full story on?": (None, "generator_artifact"),
    "hey benefits and drawbacks of": (None, "generator_artifact"),
    "hey i'm curious about": (None, "generator_artifact"),
    "comprehensive overview of!": (None, "generator_artifact"),
    "can you comprehensive analysis of brain computer interfaces?": (None, "generator_artifact"),
    "taste the table values": (None, "generator_artifact"),
    "yank the capture card latency comparison": (None, "generator_artifact"),
    "squeeze the info out of this url": (None, "generator_artifact"),
    "catapult the data to a spreadsheet": (None, "generator_artifact"),
    "BIOPSY THE PAGE FOR THE KEY TABLE": (None, "generator_artifact"),
    "yank the throwing tool comparison": (None, "generator_artifact"),
    "so like Let’s listen to that podcast series on personal finance.": (None, "generator_artifact"),
    "so like Create event for biology exam prep session next week": (None, "generator_artifact"),
    "so like list countries that are in the European Union": ("knowledge", "wrong_label"),  # already above; skip
    "so my question is basically do I have anything on my calendar for next Wednesday": (None, "generator_artifact"),
    "bruh the table just extract it": (None, "generator_artifact"),
    "ok stock price of UNH": (None, "generator_artifact"),
    "ummm launch chrome I think": (None, "generator_artifact"),
    "hey start number slide": (None, "generator_artifact"),
    "hey tile merger": (None, "generator_artifact"),
    "hey box pushing game": (None, "generator_artifact"),
    "so like ": (None, "generator_artifact"),
    "como se dice...": (None, "generator_artifact"),
    "just Turn my voice into text": (None, "generator_artifact"),
    "um can you do some math for me 25 * 4": (None, "generator_artifact"),
    "please set a timer for one hour, i’m studying": (None, None),  # OK
    "exportthe just travel history log": (None, "generator_artifact"),
    "Can we navigate tothe just app manager for a sec?": (None, "generator_artifact"),
    "so like How long till my chicken's done?": ("knowledge", "wrong_label"),  # already above

    # -------- low_quality (all-caps, gibberish, severe typos) --------
    "WHAT'S RUNNING IN THE BACKGROUND": (None, "low_quality"),
    "HOW'S TESLA DOING???": (None, "low_quality"),
    "GIVE ME DAD'S NUMBER": (None, "low_quality"),
    "SWITCH OFF THE BEDROOM LIGHTS, I WANNA NAP.": (None, "low_quality"),
    "TIME FOR OBJECT TO FALL 100 METERS IGNORING AIR RESISTANCE": (None, "low_quality"),
    "UNIQUE ELEMENTS OF [1, 2, 2, 3, 3, 3, 4]": (None, "low_quality"),
    "TURN ON MY WEBCAM, THANKS!": (None, "low_quality"),
    "WHEN IS THANKSGIVING??": (None, "low_quality"),
    "I NEED TO NOTE DOWN WHEN TO START COOKING FOR THE POTLUCK.": (None, "low_quality"),
    "I WANNA TELL JAKE SOMETHING QUICK.": (None, "low_quality"),
    "WHAT'S THE TEMP??!": (None, "low_quality"),
    "SWITCH THE KETTLE ON, I’M MAKING TEA TOO!": (None, "low_quality"),
    "sliding box gaem": (None, "low_quality"),
    "i wanna plya": (None, "low_quality"),
    "i want to paly": (None, "low_quality"),
    "give me a gaem": (None, "low_quality"),
    "tim eo'clock": (None, "low_quality"),
    "what's enxt": (None, "low_quality"),
    "Show me my schedule for tmoorrow": (None, "low_quality"),
    "remind me 2day": (None, "low_quality"),
    "Could you shwo me directions to the library?": (None, "low_quality"),
    "shw file contents": (None, "low_quality"),
    "track PFE stock every huor": (None, "low_quality"),
    "So like, can you give me the deets on the current nwes? I’m kinda pressed for time!": (None, "low_quality"),
    "Get the camera ready, I want to document this emal": (None, "low_quality"),
    "opne document": (None, "low_quality"),
    "Wheredo exactly I see my hardware info?": (None, "low_quality"),
    "game": (None, "low_quality"),
    "diction?": (None, "low_quality"),

    # -------- ambiguous --------
    "Capture that": (None, "ambiguous"),
    "Hey, we're live on camera!": (None, "ambiguous"),
    "shot time": (None, "ambiguous"),
    "swipe the data from the page": (None, "ambiguous"),
    "grab the auto-complete suggestions??": (None, "ambiguous"),
    "Switch it up": (None, "ambiguous"),
    "just copy it": (None, "ambiguous"),
    "distract me please": (None, "ambiguous"),
    "curiosity spark": (None, "ambiguous"),
    "calculate": (None, "ambiguous"),
    "disk save": (None, "ambiguous"),
    "whats my oven temp?": (None, "ambiguous"),
    "quickly change": (None, "ambiguous"),
    "let’s groove": (None, "ambiguous"),
    "rush me some results": (None, "ambiguous"),
    "need a fun fact": (None, "ambiguous"),
    "What’s the scoop?": (None, "ambiguous"),
    "where's my stuff": (None, "ambiguous"),
    "export it": (None, "ambiguous"),
    "my monitors": (None, "ambiguous"),
    "how's it running?": (None, "ambiguous"),
    "Just let me send!": (None, "ambiguous"),
    "just give me the answer!": (None, "ambiguous"),
    "Tell me when the traffic will clear up!": (None, "ambiguous"),
    "Can someone please check their messages and reply ASAP?": (None, "ambiguous"),
    "time to drive to san diego": (None, "ambiguous"),
    "when's the deadline?": (None, "ambiguous"),
    "Time in five?": (None, "ambiguous"),
    "I need to find a time to discuss the project.": (None, "ambiguous"),
    "Could you kindly document what was discussed in this part?": (None, "ambiguous"),
    "Let's document this": (None, "ambiguous"),
    "Have to recall this": (None, "ambiguous"),
    "Bring up a random choice": (None, "ambiguous"),
    "Dude, I need this info in text!": (None, "ambiguous"),
    "got a word for it?": (None, "ambiguous"),
    "louder": (None, "ambiguous"),
    "um make it brighter": (None, "ambiguous"),
    "living room lights": (None, "ambiguous"),
    "clip it already!": (None, "ambiguous"),
    "I’ll snip this": (None, "ambiguous"),
    "clipboard it!": (None, "ambiguous"),
    "inspect document": (None, "ambiguous"),
    "file contents": (None, "ambiguous"),
    "text reader": (None, "ambiguous"),
    "text note": (None, "ambiguous"),
    "remove the one I just created": (None, "ambiguous"),
    "single reminder": (None, "ambiguous"),
    "Due date notes": (None, "ambiguous"),
    "look up fam": (None, "ambiguous"),
    "yo look this up online": (None, "ambiguous"),
    "yo pull that data": (None, "ambiguous"),
    "Oh no, timer!": (None, "ambiguous"),
    "Can we speed this up?": (None, "ambiguous"),
    "ok move ring": (None, "ambiguous"),
    "I really need to access my email!": (None, "ambiguous"),
    "Hey, when’s this meeting gonna end?": (None, "ambiguous"),
    "What time do I need to leave to be on time?": (None, "ambiguous"),
    "I don’t see any events for today": (None, "ambiguous"),
    "can you 4x4 sudoku?": (None, "ambiguous"),
    "I need to reach my coworker fast, hurry and find him!": (None, "ambiguous"),
    "Can you figure out 15% of the project budget for me?": (None, "ambiguous"),
    "I’m lost on numbers": ("conversation", "wrong_label"),  # already
}


def main():
    by_text = defaultdict(list)

    # Load all records.
    all_data = []
    for fname in FILES:
        path = os.path.join(BASE, fname)
        with open(path, "r", encoding="utf-8") as f:
            for i, line in enumerate(f, 1):
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                text = obj.get("text", "")
                label = obj.get("label", "")
                all_data.append((fname, i, text, label))
                by_text[text.strip().lower()].append((fname, label, text))

    total = len(all_data)
    flags = []
    seen = set()

    # Duplicate-conflict detection (same text, different labels across files).
    duplicate_conflicts = set()
    for text_key, entries in by_text.items():
        labels = set(e[1] for e in entries)
        if len(labels) > 1 and len(entries) > 1:
            duplicate_conflicts.add(text_key)

    # Walk through data, applying priority: curated > duplicate > quality heuristic.
    for fname, lineno, text, label in all_data:
        if len(flags) >= CAP:
            break

        # Curated C flags.
        if fname == "intent_data_c.jsonl" and text in C_FLAGS:
            suggested, issue = C_FLAGS[text]
            if issue is None:
                continue  # explicit "keep"
            rec = {
                "file": fname,
                "text": text,
                "original_label": label,
                "issue": issue,
            }
            if suggested and suggested != label:
                rec["suggested_label"] = suggested
            key = (fname, text)
            if key in seen:
                continue
            seen.add(key)
            flags.append(rec)
            continue

        # Duplicate conflicts.
        if text.strip().lower() in duplicate_conflicts:
            rec = {
                "file": fname,
                "text": text,
                "original_label": label,
                "issue": "duplicate_conflict",
            }
            flags.append(rec)
            continue

        # Generic quality checks.
        if is_low_quality(text) or is_all_caps_yelling(text) or has_severe_typo(text):
            key = (fname, text)
            if key in seen:
                continue
            seen.add(key)
            flags.append({
                "file": fname,
                "text": text,
                "original_label": label,
                "issue": "low_quality",
            })
            continue

    # Sort flags for readability - by file then by issue type.
    issue_order = {"wrong_label": 0, "ambiguous": 1, "duplicate_conflict": 2,
                   "low_quality": 3, "generator_artifact": 4}
    flags.sort(key=lambda r: (r["file"], issue_order.get(r["issue"], 99), r["text"]))

    # Write output.
    with open(OUT_PATH, "w", encoding="utf-8") as f:
        for rec in flags:
            out = {
                "file": rec["file"],
                "text": rec["text"],
                "original_label": rec["original_label"],
                "issue": rec["issue"],
            }
            if rec.get("suggested_label"):
                out["suggested_label"] = rec["suggested_label"]
            f.write(json.dumps(out, ensure_ascii=False) + "\n")

    # Summary.
    by_issue = defaultdict(int)
    by_orig = defaultdict(int)
    for rec in flags:
        by_issue[rec["issue"]] += 1
        by_orig[rec["original_label"]] += 1

    print("AUDIT_COMPLETE")
    print(f"Files scanned: {len(FILES)}")
    print(f"Total records scanned: {total}")
    print(f"Flagged: {len(flags)}")
    print("By issue type:")
    for k in ("wrong_label", "ambiguous", "duplicate_conflict", "low_quality", "generator_artifact"):
        print(f"  {k}: {by_issue.get(k, 0)}")
    print("By original label:")
    for k in ("tool_action", "knowledge", "conversation", "refinement", "meta"):
        print(f"  {k}: {by_orig.get(k, 0)}")


if __name__ == "__main__":
    main()
