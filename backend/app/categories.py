"""Expense categories for insights. Clients may send one; otherwise we guess from the description."""
import re

CATEGORIES = {
    "rent": "Rent",
    "utilities": "Utilities",
    "groceries": "Groceries",
    "food": "Food & dining",
    "help": "House help",
    "household": "Household",
    "transport": "Transport",
    "entertainment": "Entertainment",
    "other": "Other",
}

_RULES = [
    ("rent", r"\b(rent|deposit|maintenance|society)\b"),
    ("utilities", r"\b(wifi|wi-fi|internet|broadband|electric\w*|power|bill|gas|cylinder|water|dth|recharge|airtel|jio)\b"),
    ("groceries", r"\b(grocer\w*|milk|bread|eggs?|vegetables?|veggies|fruits?|zepto|blinkit|bigbasket|instamart|dmart|kirana)\b"),
    ("food", r"\b(swiggy|zomato|dinner|lunch|breakfast|pizza|biryani|food|cafe|restaurant|chai|coffee|takeaway)\b"),
    ("help", r"\b(maid|cook|cleaning|cleaner|helper|bai|driver|laundry|dhobi|ironing)\b"),
    ("household", r"\b(furniture|repair|plumber|electrician|detergent|toilet|kitchen|utensils?|bulb|curtain|mattress)\b"),
    ("transport", r"\b(uber|ola|rapido|cab|taxi|auto|petrol|fuel|metro|parking)\b"),
    ("entertainment", r"\b(netflix|prime|hotstar|spotify|movie|party|drinks|beer|games?)\b"),
]


def guess(description: str) -> str:
    d = description.lower()
    for cat, rx in _RULES:
        if re.search(rx, d):
            return cat
    return "other"


def normalize(cat: str | None, description: str) -> str:
    if cat and cat in CATEGORIES:
        return cat
    return guess(description)
