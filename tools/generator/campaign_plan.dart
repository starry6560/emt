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

class RoundSpec {
  const RoundSpec({required this.round, required this.introduces, required this.elements,
    required this.rules, required this.tapFloor, required this.slack,
    required this.minFirstChoices, required this.maxCorrectShare,
    required this.minDeadEndRatio, required this.trapRequired,
    required this.decoyCap, required this.maxWidth, required this.maxHeight});

  final int round;
  /// Element or rule shown by this explanation round, or null for a normal round.
  final String? introduces;
  /// Elements that may appear (rock and everything introduced so far).
  final Set<String> elements;
  final EyeRules rules;
  /// Minimum shortest-solution length (4-1); 0 for none.
  final int tapFloor;
  /// Extra taps on top of the target; null means no tap limit (1-2, 3-2).
  final int? slack;
  /// Targets from 4-3; null where the spec sets none. A player feels the
  /// chance that a random first tap is right, so the targets are shares of
  /// the legal first actions, with a minimum number of them.
  final int? minFirstChoices;
  final double? maxCorrectShare;
  final double? minDeadEndRatio;
  /// Peak rounds (multiples of five) must trap the greedy player.
  final bool trapRequired;
  /// Decoy element kinds allowed on the board (5).
  final int decoyCap;
  final int maxWidth, maxHeight;

  bool get explanation => introduces != null;
  bool get peak => round % 5 == 0;
  int? limitFor(int par) => slack == null ? null : par + slack!;
}

RoundSpec specFor(int round) {
  if (round < 1 || round > campaignRounds) throw RangeError.range(round, 1, campaignRounds, 'round');
  final introduced = {for (final e in introductions.entries) if (e.key <= round) e.value};
  final introduces = introductions[round];
  final explanation = introduces != null;
  final rules = EyeRules(noTriangle: introduced.contains('noTriangle'),
      removalTurnsNeighbors: introduced.contains('removalTurnsNeighbors'),
      tapTurnsNeighbors: introduced.contains('tapTurnsNeighbors'));
  final floor = explanation ? 0 : round <= 5 ? 0 : round <= 20 ? 8 : round <= 50 ? 10
      : round <= 100 ? 12 : round <= 200 ? 14 : 16;
  final slack = explanation ? null : round <= 20 ? 3 : round <= 100 ? 2 : 1;
  final targeted = !explanation && round > 5;
  final peak = round % 5 == 0;
  final (width, height) = round <= 5 ? (5, 5) : round <= 20 ? (6, 7) : round <= 50 ? (7, 8)
      : round <= 100 ? (8, 9) : round <= 200 ? (8, 10) : (8, 11);
  return RoundSpec(
    round: round, introduces: introduces,
    elements: introduced.difference(boardRules).difference({'normal'}),
    rules: rules, tapFloor: floor, slack: slack,
    minFirstChoices: !targeted ? null : round <= 50 ? 5 : round <= 150 ? 6 : 7,
    maxCorrectShare: !targeted ? null : peak
        ? (round <= 50 ? 1 / 3 : round <= 150 ? 0.25 : 0.20)
        : (round <= 50 ? 0.50 : round <= 150 ? 0.40 : 1 / 3),
    minDeadEndRatio: !targeted ? null : peak
        ? (round <= 50 ? 0.40 : 0.50)
        : (round <= 50 ? 0.25 : round <= 150 ? 0.30 : 0.35),
    trapRequired: targeted && round % 5 == 0,
    decoyCap: explanation ? 0 : round <= 75 ? 1 : round <= 200 ? 2 : 3,
    maxWidth: width, maxHeight: height,
  );
}

/// Campaign-wide share of normal rounds that must trap the greedy player
/// (4-3), checked over the whole campaign rather than per board.
double trapShareFor(int round) => round <= 50 ? 0 : round <= 150 ? 0.5 : 0.7;
