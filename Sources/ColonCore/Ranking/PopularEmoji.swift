import Foundation

/// The most commonly sent emoji (roughly Unicode emoji-frequency order, plus chat staples such as
/// 🐐 🫡 🗿 💀). Always offered to Jev so semantic queries (`haha`, `yay`, `sus`, `ty`, `ded`, `bet`)
/// find good answers even when no keyword matches. Ids are `Emoji.id`; a test checks they all exist.
enum PopularEmoji {
    static let ids: [String] = [
        "joy", "heart", "rofl", "+1", "sob", "pray", "kissing_heart",
        "smiling_face_with_three_hearts", "heart_eyes", "blush", "tada", "grin", "two_hearts",
        "pleading_face", "sweat_smile", "fire", "relaxed", "facepalm", "hearts", "shrug",
        "roll_eyes", "laughing", "hugs", "wink", "birthday", "thinking", "clap",
        "slightly_smiling_face", "flushed", "partying_face", "sunglasses", "ok_hand",
        "purple_heart", "pensive", "muscle", "sparkles", "sparkling_heart", "eyes", "yum", "smirk",
        "cry", "point_right", "heartpulse", "weary", "100", "rose", "revolving_hearts", "balloon",
        "blue_heart", "smiley", "rage", "bouquet", "stuck_out_tongue_winking_eye", "see_no_evil",
        "crossed_fingers", "smile", "drooling_face", "raised_hands", "zany_face",
        "heavy_heart_exclamation", "grinning", "kiss", "skull", "goat", "saluting_face",
        "clown_face", "moyai", "rocket", "pizza", "beer", "skull_and_crossbones", "ghost",
        "melting_face", "smiling_face_with_tear", "face_exhaling", "heart_hands",
        "pinched_fingers", "brain", "money_with_wings", "x", "warning", "trophy", "people_hugging",
        "nerd_face", "-1", "face_with_peeking_eye", "point_down", "broken_heart", "relieved",
        "heartbeat", "star_struck", "upside_down_face", "grimacing", "scream", "sleeping",
        "hand_over_mouth", "neutral_face", "sun_with_face", "unamused", "innocent",
        "cherry_blossom", "smiling_imp", "notes", "v", "confetti_ball", "hot_face", "disappointed",
        "green_heart", "sunny", "black_heart", "moneybag", "kissing_closed_eyes", "crown", "gift",
        "boom", "raising_hand", "frowning_face", "expressionless", "woozy_face", "point_left",
        "hankey", "white_check_mark", "wave", "vomiting_face", "triumph", "nauseated_face",
        "star2", "exclamation", "disappointed_relieved", "rainbow", "yellow_heart",
        "stuck_out_tongue_closed_eyes", "tired_face", "astonished", "bangbang", "red_circle",
        "sunflower", "exploding_head", "woman_dancing", "fist_oncoming", "cursing_face", "runner",
        "confused", "eye", "zap", "coffee", "four_leaf_clover", "sweat_drops", "star", "butterfly",
        "raised_eyebrow", "hibiscus", "joy_cat", "metal", "tulip", "gift_heart", "zzz",
        "handshake", "rabbit", "sweat", "cupid", "beers", "worried", "persevere", "monocle_face",
        "angry", "cowboy_hat_face", "heart_eyes_cat", "crescent_moon", "stuck_out_tongue",
        "call_me_hand", "speak_no_evil", "money_mouth_face", "dart", "no_good", "ok_person",
        "sleepy", "yawning_face", "point_up_2", "no_mouth", "dog", "cat", "umbrella",
        "christmas_tree", "champagne", "clinking_glasses", "cake",
    ]
}
