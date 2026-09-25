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
//
// Coordinate conventions used by the constants below:
// * "cell" coordinates (eye centres): (c, r) names the character cell in
//   column c, row r; the cell's centre is at ((c + 0.5) * advance,
//   (r + 0.5) * lineHeight). Fractions address points between cells.
// * "grid" coordinates (hinges): (x, y) is measured from the top-left corner
//   of the layer in whole character advances / line heights, so x = 20.5 on
//   a 41-column grid is the exact horizontal centre.
// * Mouth spans are cell columns of the outermost mouth glyphs (inclusive).

/// Width of the skull grid in character columns.
const int kSkullColumns = 41;

/// Cranium layer: rows 0..17. The last row holds the upper teeth.
const List<String> kSkullCranium = <String>[
  r'             _.--~~~~~~~--._',
  r"         _.-~'   '     ' , '~-._",
  r"      .-'   .             \ .   '-.",
  r"    .'   '                /    '   '.",
  r"  .'                       \_        '.",
  r' /    .                      \    .    \',
  r'|                                       |',
  r'|                                       |',
  r'|   .-~~~~~~-._           _.-~~~~~~-.   |',
  r"| .'           '-.     .-'           '. |",
  r'| |               \   /               | |',
  r'| |                | |                | |',
  r" \'.              .' '.              .'/",
  r"  \ '-._________.-'   '-._________.-' /",
  r"   '.              / \              .'",
  r"    '.            /_^_\            .'",
  r"      '-._______________________.-'",
  r'        | |_|_|_|_|_|_|_|_|_|_| |',
];

/// Jaw layer: lower teeth, mandible and chin. Drawn directly under the
/// cranium when the mouth is closed.
const List<String> kSkullJaw = <String>[
  r'        | |"|"|"|"|"|"|"|"|"|"| |',
  r"        | '-'-'-'-'-'-'-'-'-'-' |",
  r'        \                       /',
  r"         '.                   .'",
  r"           '-._____________.-'",
];

/// Eye socket centres in cell coordinates (see the conventions above): the
/// sockets span columns 3..17 and 23..37, rows 8..13 of the cranium.
const List<(double, double)> kSkullEyeCentres = <(double, double)>[(10.0, 10.6), (30.0, 10.6)];

/// Hinge point of the jaw in grid coordinates relative to the jaw layer
/// (the top centre of the jaw layer).
const (double, double) kSkullJawHinge = (20.5, 0.0);

/// Columns of the outer mouth walls (`|` at columns 8 and 32 of the teeth
/// rows). The mouth cavity glow is painted between them.
const (int, int) kSkullMouthSpan = (8, 32);

/// Width of the mini skull grid in character columns.
const int kMiniSkullColumns = 13;

/// A compact skull used for the rail logo, empty states and the easter egg.
/// The upper teeth (`|_|_|_|`, columns 3..9) sit exactly above the lower
/// teeth (`|"|"|"|`, columns 3..9), mirroring the full skull's layering.
const List<String> kMiniSkullCranium = <String>[
  r'   _.---._',
  r" .'       '.",
  r'| .-.   .-. |',
  r"| '-' ^ '-' |",
  r" '.|_|_|_|.'",
];

const List<String> kMiniSkullJaw = <String>[r'   |"|"|"|', r"   '-----'"];

/// Mini skull eye centres in cell coordinates (between the `.-.` and `'-'`
/// rows, i.e. the middle of each small socket).
const List<(double, double)> kMiniSkullEyeCentres = <(double, double)>[(3.0, 2.5), (9.0, 2.5)];

/// Mini skull jaw hinge in grid coordinates relative to the jaw layer.
const (double, double) kMiniSkullJawHinge = (6.5, 0.0);

/// Columns of the mini skull's outer mouth walls.
const (int, int) kMiniSkullMouthSpan = (3, 9);
