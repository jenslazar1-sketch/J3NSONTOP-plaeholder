// Original ASCII skull designed for J3NSONTOP BIGGEST MULTITOOL MADE.
//
// Provenance: drawn from scratch with the mirror/placement script in
// `tool/skull/skull_design.py` (the ascii.co.uk reference page could not be
// reached to verify its reuse terms, so no third-party art is used).
//
// The skull is split into two fixed-width text layers that share the same
// column grid: the cranium (steady) and the jaw (animated). Stacking the jaw
// directly below the cranium reproduces the closed-mouth skull exactly.
//
// IMPORTANT: render with a monospaced font and ligatures disabled
// (see `J3Type.asciiFeatures`), otherwise sequences such as `|_|` or `|-|`
// may be merged into ligature glyphs and break alignment.

/// Width of the skull grid in character columns.
const int kSkullColumns = 41;

/// Cranium layer: rows 0..17. The last row holds the upper teeth.
const List<String> kSkullCranium = <String>[
  r"             _.--~~~~~~~--._",
  r"         _.-~'   '     ' , '~-._",
  r"      .-'   .             \ .   '-.",
  r"    .'   '                /    '   '.",
  r"  .'                       \_        '.",
  r" /    .                      \    .    \",
  r"|                                       |",
  r"|                                       |",
  r"|   .-~~~~~~-._           _.-~~~~~~-.   |",
  r"| .'           '-.     .-'           '. |",
  r"| |               \   /               | |",
  r"| |                | |                | |",
  r" \'.              .' '.              .'/",
  r"  \ '-._________.-'   '-._________.-' /",
  r"   '.              / \              .'",
  r"    '.            /_^_\            .'",
  r"      '-._______________________.-'",
  r"        | |_|_|_|_|_|_|_|_|_|_| |",
];

/// Jaw layer: lower teeth, mandible and chin. Drawn directly under the
/// cranium when the mouth is closed.
const List<String> kSkullJaw = <String>[
  r'        | |"|"|"|"|"|"|"|"|"|"| |',
  r"        | '-'-'-'-'-'-'-'-'-'-' |",
  r"        \                       /",
  r"         '.                   .'",
  r"           '-._____________.-'",
];

/// Eye socket centres in (column, row) grid units, used to place the glow.
const List<(double, double)> kSkullEyeCentres = <(double, double)>[
  (10.0, 10.6),
  (30.0, 10.6),
];

/// Hinge point of the jaw in grid units (the top centre of the jaw layer).
const (double, double) kSkullJawHinge = (20.5, 0.0);

/// A compact skull used for the rail logo, empty states and the easter egg.
const List<String> kMiniSkullCranium = <String>[
  r"   _.---._",
  r" .'       '.",
  r"| .-.   .-. |",
  r"| '-' ^ '-' |",
  r" '._|_|_|_.'",
];

const List<String> kMiniSkullJaw = <String>[
  r'   |"|"|"|',
  r"   '-----'",
];
