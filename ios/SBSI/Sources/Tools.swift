/// Function tools the realtime model can call to control the glasses.
/// Add new glasses inputs/outputs here (see docs/ideas.md, "Glasses I/O as tools").
enum Tools {
  static let takePhoto = "take_photo"
  /// Only offered on the out-of-band proactive check, never in the main conversation.
  static let proactiveDecision = "proactive_decision"

  /// Forcing a function call gives reliable structured output; free-text JSON from the mini
  /// model came back empty or malformed (run 2, 2026-10-24).
  static let proactiveDefinition: [String: Any] = [
    "type": "function",
    "name": proactiveDecision,
    "description": "Report whether the guide should speak up right now without being asked.",
    "parameters": [
      "type": "object",
      "properties": [
        "speak": ["type": "boolean"],
        "say": ["type": "string", "description": "What to say if speak is true: one or two short sentences."],
      ],
      "required": ["speak"],
    ],
  ]

  static let definitions: [[String: Any]] = [
    [
      "type": "function",
      "name": takePhoto,
      "description": """
        Take a sharp, full-resolution photo with the glasses camera. The live video frames are \
        low-detail; use this when you need to read text, labels, part numbers, model plates or \
        small details, or to inspect something closely before giving a diagnosis. Also use it when \
        the user asks you to take a picture. Tell the user to hold still first.
        """,
      "parameters": [
        "type": "object",
        "properties": [
          "reason": ["type": "string", "description": "What you want to look at, in a few words."]
        ],
        "required": ["reason"],
      ],
    ]
  ]
}
