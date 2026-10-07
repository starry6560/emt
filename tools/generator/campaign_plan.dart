// Per-round targets from the spec. Change the numbers here and in
// the spec together.
import 'package:emt/game/eye_logic.dart';

const campaignRounds = 300;

/// What each explanation round introduces (spec 2-4). Board-wide rules
/// use their level-file names; everything else is an element name.
const introductions = <int, String>{
  1: 'normal', 3: 'noTriangle', 6: 'rock', 16: 'anchored', 26: 'cookie',
  30: 'removalTurnsNeighbors', 38: 'spark', 51: 'gate', 63: 'beckoner',
  76: 'hopper', 80: 'tapTurnsNeighbors', 88: 'candy', 101: 'eater',
  113: 'impatient', 126: 'mirror', 134: 'lamp', 142: 'portal', 151: 'linked',
  159: 'ghost', 167: 'vine', 176: 'hill', 184: 'horse', 192: 'frog',
  201: 'box', 213: 'rotor',
};

const boardRules = {'noTriangle', 'removalTurnsNeighbors', 'tapTurnsNeighbors'};

/// Rounds after its introduction in which a new element must appear
/// (spec 2-5).
const practiceRounds = 12;

/// Elements that only work together with another one.
const elementNeeds = {'box': 'hopper'};

final List<Set<String>> _required = _planRequired();

/// Elements a normal round must show and put to work (spec 2-5): the
/// newest element through its practice rounds, joined after the first of
/// them by one older element, and two older elements once the practice is
/// over. Older elements take turns, least recently required first, so every
/// element keeps coming back and mixes with the others.
Set<String> requiredFor(int round) {
  if (round < 1 || round > campaignRounds) throw RangeError.range(round, 1, campaignRounds, 'round');
  return _required[round - 1];
}

List<Set<String>> _planRequired() {
  final elementIntros = {
    for (final e in introductions.entries)
      if (!boardRules.contains(e.value) && e.value != 'normal') e.value: e.key,
  };
  final lastRequired = {...elementIntros};
  return [
    for (var round = 1; round <= campaignRounds; round++)
      () {
        if (introductions.containsKey(round)) return const <String>{};
        final known = [for (final e in elementIntros.entries) if (e.value < round) e.key];
        if (known.isEmpty) return const <String>{};
        final newest = known.last;
        final since = round - elementIntros[newest]!;
        final practice = since <= practiceRounds;
        final required = <String>{if (practice) newest};
        final mix = !practice ? 2 : since == 1 ? 0 : 1;
        final older = known.where((e) => !required.contains(e)).toList()
          ..sort((a, b) {
            final byTurn = lastRequired[a]!.compareTo(lastRequired[b]!);
            return byTurn != 0 ? byTurn : elementIntros[a]!.compareTo(elementIntros[b]!);
          });
        required.addAll(older.take(mix));
        for (final e in required.toList()) {
          final need = elementNeeds[e];
          if (need != null) required.add(need);
        }
        for (final e in required) { lastRequired[e] = round; }
        return Set<String>.unmodifiable(required);
      }(),
  ];
}

/// Rounds the strict targets did not reach after three server runs; to
/// finish the campaign they take looser checks (spec 4-5, user
/// decision 2026-10-07): the floor two taps lower, no thinking targets, and
/// one working required element is enough.
const relaxedRounds = {
  29, 32, 35, 53, 55, 56, 57, 58, 59, 60, 62, 67, 68, 71, 72, 90, 92, 95, 97, 100, 103, 106, 110,
  120, 130, 131, 132, 136, 139, 144, 145, 150, 157, 161, 165, 168, 169, 175, 178, 179, 180, 181,
  182, 183, 188, 189, 190, 200, 202, 203, 204, 205, 206, 209, 210, 217, 218, 219, 220, 221, 225,
  227, 231, 232, 233, 235, 237, 239, 241, 243, 244, 245, 247, 248, 250, 252, 253, 254, 255, 259,
  260, 263, 265, 266, 270, 274, 276, 277, 281, 282, 283, 285, 287, 292, 293, 298,
};

/// How much lower a relaxed round's tap floor is.
const relaxedFloorDrop = 2;

class RoundSpec {
  const RoundSpec({required this.round, required this.introduces, required this.elements,
    required this.rules, required this.tapFloor, required this.slack,
    required this.minFirstChoices, required this.maxCorrectShare,
    required this.minDeadEndRatio, required this.trapRequired,
    this.decoyCap, required this.maxWidth, required this.maxHeight,
    this.required = const {}, this.requiredActive});

  final int round;
  /// Element or rule shown by this explanation round, or null for a normal round.
  final String? introduces;
  /// Elements that may appear (rock and everything introduced so far).
  final Set<String> elements;
  /// Elements that must appear and work on this board; see [requiredFor].
  final Set<String> required;
  /// How many of the measured required elements (all but rock) must work;
  /// null for all of them.
  final int? requiredActive;
  final EyeRules rules;
  /// Minimum shortest-solution length (4-1); 0 for none.
  final int tapFloor;
  /// Extra taps on top of the target that the 4-2 metrics explore; null for
  /// explanation rounds, which are measured at the target itself.
  final int? slack;
  /// Targets from 4-3; null where the spec sets none. A player feels the
  /// chance that a random first tap is right, so the targets are shares of
  /// the legal first actions, with a minimum number of them.
  final int? minFirstChoices;
  final double? maxCorrectShare;
  final double? minDeadEndRatio;
  /// Peak rounds (multiples of five) must trap the greedy player.
  final bool trapRequired;
  /// Decoy element kinds allowed on the board (5); null for no cap.
  final int? decoyCap;
  final int maxWidth, maxHeight;

  bool get explanation => introduces != null;
  bool get relaxed => requiredActive != null;
  /// Whether the required elements found working are enough.
  bool requiredWorking(Set<String> active) {
    final measured = required.difference({'rock'});
    final working = measured.intersection(active).length;
    return working >= (requiredActive == null ? measured.length : requiredActive!.clamp(0, measured.length));
  }
  bool get peak => round % 5 == 0;
  int? depthFor(int par) => slack == null ? null : par + slack!;
}

RoundSpec specFor(int round) {
  if (round < 1 || round > campaignRounds) throw RangeError.range(round, 1, campaignRounds, 'round');
  final introduced = {for (final e in introductions.entries) if (e.key <= round) e.value};
  final introduces = introductions[round];
  final explanation = introduces != null;
  final rules = EyeRules(noTriangle: introduced.contains('noTriangle'),
      removalTurnsNeighbors: introduced.contains('removalTurnsNeighbors'),
      tapTurnsNeighbors: introduced.contains('tapTurnsNeighbors'));
  final floor = explanation ? 0 : round <= 5 ? 0 : round <= 20 ? 7 : round <= 50 ? 9
      : round <= 100 ? 11 : round <= 200 ? 13 : 15;
  final slack = explanation ? null : round <= 20 ? 3 : round <= 100 ? 2 : 1;
  final relaxed = relaxedRounds.contains(round);
  final targeted = !explanation && round > 5 && !relaxed;
  final peak = round % 5 == 0;
  final (width, height) = round <= 5 ? (5, 5) : round <= 20 ? (6, 7) : round <= 50 ? (7, 8)
      : round <= 100 ? (8, 9) : round <= 200 ? (8, 10) : (8, 11);
  return RoundSpec(
    round: round, introduces: introduces,
    elements: introduced.difference(boardRules).difference({'normal'}),
    rules: rules, tapFloor: relaxed ? floor - relaxedFloorDrop : floor, slack: slack,
    minFirstChoices: !targeted ? null : round <= 50 ? 5 : round <= 150 ? 6 : 7,
    maxCorrectShare: !targeted ? null : peak
        ? (round <= 50 ? 0.40 : 0.25)
        : (round <= 50 ? 0.50 : round <= 150 ? 0.40 : 1 / 3),
    minDeadEndRatio: !targeted ? null : peak
        ? (round <= 50 ? 0.40 : 0.50)
        : (round <= 50 ? 0.25 : round <= 150 ? 0.30 : 0.35),
    trapRequired: targeted && round % 5 == 0,
    decoyCap: explanation ? 0 : null,
    maxWidth: width, maxHeight: height,
    required: requiredFor(round), requiredActive: relaxed ? 1 : null,
  );
}

/// Campaign-wide share of normal rounds that must trap the greedy player
/// (4-3), checked over the whole campaign rather than per board.
double trapShareFor(int round) => round <= 50 ? 0 : round <= 150 ? 0.5 : 0.7;
