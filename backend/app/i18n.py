"""Server-side copy for pushes in English and Hindi (FR-18). Picked by users.locale."""

STRINGS = {
    "en": {
        "n1_title": "Looks right?",
        "n1_body": "{adder} added {desc} {amount}. Your share {share}. Looks right?",
        "n1_batch_title": "Review expenses",
        "n1_batch_body": "{adder} added {{n}} expenses. Review",
        "n2_title": "Got it?",
        "n2_body": "{payer} says they paid you {amount}. Got it?",
        "n3_title": "Coins today",
        "n3_body": "{n} of your expenses were confirmed today. +{coins} coins",
        "n4_title": "Settle up",
        "n4_body": "You owe {name} {amount}. Pay today for +{coins} coins",
        "n5_met": "Last week {group} confirmed {progress} expenses and hit the goal. This week's goal: {target}.",
        "n5_missed": "Last week was quiet. This week's goal: {target}. Anyone in the group can confirm in one tap.",
        "n6_title": "Coins ready",
        "n6_body": "You can redeem an INR {value} voucher",
        "n7_title": "Coins expiring",
        "n7_body": "{coins} coins expire on {date}",
        "n8_title": "New in your group",
        "n8_body": "{name} joined {group}",
        "dispute_title": "Expense needs a look",
        "dispute_body": "{name} says {desc} isn't right. Edit it and they can confirm again.",
        "reject_title": "Not received yet",
        "reject_body": "{name} hasn't received it yet. You can add a note.",
        "recurring_soon_title": "Coming up tomorrow",
        "recurring_soon": "{desc} ({amount}) will be added tomorrow.",
        "recurring_failed_title": "Couldn't add a recurring bill",
        "recurring_failed": "{desc} wasn't added: {reason}",
        "budget_title": "{label} budget",
        "budget_near": "{label} is at {spent} of {limit} this month.",
        "budget_over": "{label} went over budget: {spent} of {limit} this month.",
        "pay_remind_title": "Reminder from {name}",
        "pay_remind_body": "You owe {name} {amount} in {group}. Settle up when you can.",
    },
    "hi": {
        "n1_title": "सही है?",
        "n1_body": "{adder} ने {desc} {amount} जोड़ा। आपका हिस्सा {share}। सही है?",
        "n1_batch_title": "खर्च देखें",
        "n1_batch_body": "{adder} ने {{n}} खर्च जोड़े। देखें",
        "n2_title": "मिल गया?",
        "n2_body": "{payer} कह रहे हैं कि उन्होंने आपको {amount} दिए। मिल गया?",
        "n3_title": "आज के कॉइन",
        "n3_body": "आज आपके {n} खर्च कन्फ़र्म हुए। +{coins} कॉइन",
        "n4_title": "हिसाब बराबर करें",
        "n4_body": "आपको {name} को {amount} देने हैं। आज चुकाएं और +{coins} कॉइन पाएं",
        "n5_met": "पिछले हफ़्ते {group} ने {progress} खर्च कन्फ़र्म किए और लक्ष्य पूरा किया। इस हफ़्ते का लक्ष्य: {target}।",
        "n5_missed": "पिछला हफ़्ता शांत रहा। इस हफ़्ते का लक्ष्य: {target}। एक टैप में कन्फ़र्म करें।",
        "n6_title": "कॉइन तैयार",
        "n6_body": "आप INR {value} का वाउचर ले सकते हैं",
        "n7_title": "कॉइन की अवधि खत्म हो रही है",
        "n7_body": "{coins} कॉइन {date} को खत्म होंगे",
        "n8_title": "ग्रुप में नया सदस्य",
        "n8_body": "{name} {group} में शामिल हुए",
        "dispute_title": "खर्च दोबारा देखें",
        "dispute_body": "{name} के अनुसार {desc} सही नहीं है। बदलें, फिर वे दोबारा कन्फ़र्म कर सकते हैं।",
        "reject_title": "अभी नहीं मिला",
        "reject_body": "{name} को अभी पैसे नहीं मिले। आप नोट जोड़ सकते हैं।",
        "recurring_soon_title": "कल आने वाला",
        "recurring_soon": "{desc} ({amount}) कल जोड़ा जाएगा।",
        "recurring_failed_title": "दोहराया जाने वाला बिल नहीं जुड़ा",
        "recurring_failed": "{desc} नहीं जुड़ा: {reason}",
        "budget_title": "{label} बजट",
        "budget_near": "इस महीने {label} {limit} में से {spent} तक पहुंच गया।",
        "budget_over": "{label} बजट से ऊपर: इस महीने {limit} में से {spent}।",
        "pay_remind_title": "{name} की ओर से याद दिलाना",
        "pay_remind_body": "{group} में आपको {name} को {amount} देने हैं। जब हो सके चुका दें।",
    },
}


def t(locale: str | None, key: str, **kw) -> str:
    table = STRINGS.get(locale or "en", STRINGS["en"])
    template = table.get(key) or STRINGS["en"][key]
    return template.format(**kw)


def locale_of(conn, user_id) -> str:
    r = conn.execute("SELECT locale FROM users WHERE id=%s", (user_id,)).fetchone()
    return (r["locale"] if r else None) or "en"
