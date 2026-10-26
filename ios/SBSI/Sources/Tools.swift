/// Function tools the realtime model can call to control the glasses.
/// Add new glasses inputs/outputs here (see docs/ideas.md, "Glasses I/O as tools").
enum Tools {
  static let takePhoto = "take_photo"
  static let endSession = "end_session"
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
        Take a photo with the glasses camera. The live video frames are low-detail; use this when you \
        need to read text, labels, part numbers or small details, or to inspect something closely before \
        a diagnosis. Also use it when the user asks you to take a picture. Default is a quick photo \
        (1080x1440, a few seconds). Use detail "full" (12 MP, 20 to 75 seconds, video paused) only when a \
        quick photo couldn't resolve the fine print AND the user has agreed to wait, or they ask for a \
        high-res photo. Each photo comes back with a high-detail analysis and on-device text recognition.
        """,
      "parameters": [
        "type": "object",
        "properties": [
          "reason": ["type": "string", "description": "What you want to look at, in a few words."],
          "detail": [
            "type": "string",
            "enum": ["full", "quick"],
            "description": "quick (default): 1080x1440 in ~2 s. full: 12 MP, 20-75 s, for fine print; ask the user first.",
          ],
          "zoom": [
            "type": "string",
            "enum": ["center", "top", "bottom", "left", "right", "top-left", "top-right", "bottom-left", "bottom-right"],
            "description": "Region of the photo to also send as a 2x zoom, where the detail is (default center: what the user is looking straight at).",
          ],
        ],
        "required": ["reason"],
      ],
    ],
    [
      "type": "function",
      "name": endSession,
      "description": "Stop the session (camera, microphone and connection) when the user says to end, stop or quit the session, or says goodbye. Don't claim the session ended without calling this.",
      "parameters": ["type": "object", "properties": [String: Any]()],
    ],
  ]
}
