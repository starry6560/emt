// Campaign generator for the spec. Each round is generated against
// its own targets (tools/generator/campaign_plan.dart) and written to
// tools/generated/campaign/round-NNN.json. App data is never touched here;
// assembling the campaign is a separate step.
//
//   dart tools/generate_campaign.dart 1 3 20      those rounds
//   dart tools/generate_campaign.dart 6-20        a range
//   dart tools/generate_campaign.dart 6-20 --redo also redo accepted rounds
// Rounds whose file is already accepted are skipped, so an interrupted run
// resumes where it stopped. GEN_WORKERS sets how many rounds run at once.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:emt/game/eye_logic.dart';
import 'generator/campaign_plan.dart';
import 'generator/difficulty.dart';
import 'generator/quality.dart';
import 'generator/renewal.dart';

const outputDirectory = 'tools/generated/campaign';
/// Rounds generated at once; set GEN_WORKERS to match the machine's cores.
int get workers => int.tryParse(Platform.environment['GEN_WORKERS'] ?? '') ?? 8;
/// Effort is counted in evaluated candidates so results do not depend on load.
const normalEvaluations = 6000;
const explanationEvaluations = 300;
/// One hour per round; a GitHub machine runs four rounds at a time for up to
/// six hours, so twenty machines cover the campaign.
const safetySeconds = 3600;
/// Candidates refined side by side; the worst is replaced by better children.
const population = 6;
/// Evaluations without a new best before the worse half is reseeded.
const reseedAfter = 150;
/// The quick target search rejects most candidates cheaply; only boards at
/// the floor get the full exploration.
/// More states per candidate means fewer candidates per hour; trials showed
/// that attempts, not this budget, limit which floors are reached.
const quickStates = 60000;
const measureStates = 300000;
/// Search cost grows about fourfold per friend, so boards stay small and
/// difficulty comes from the thinking metrics (spec 4-1).
const maxCreatures = 12;
/// Explanation rounds stay short (spec 3-2).
const explanationMaxTaps = 6;
/// Rounds 1–5 have no floor, but a one-tap board teaches nothing.
const openingMinTaps = 3;
const encoder = JsonEncoder.withIndent('  ');

const creatureElements = {'anchored', 'spark', 'hopper', 'eater', 'linked', 'beckoner',
  'impatient', 'horse', 'frog'};

const names = <String, (String, String)>{
  'normal': ('기본 규칙', 'Basics'), 'noTriangle': ('삼각관계 금지', 'No triangles'),
  'removalTurnsNeighbors': ('제거 시 이웃 회전', 'Removal turns neighbors'),
  'tapTurnsNeighbors': ('탭 시 이웃 회전', 'Taps turn neighbors'),
  'rock': ('바위', 'Rock'), 'anchored': ('고집이', 'Anchor'), 'cookie': ('쿠키벽', 'Cookie Wall'),
  'spark': ('찌릿이', 'Spark'), 'gate': ('박자문', 'Beat Gate'), 'beckoner': ('손짓이', 'Beckoner'),
  'hopper': ('폴짝이', 'Hopper'), 'candy': ('별사탕', 'Star Candy'), 'eater': ('먹보', 'Chomper'),
  'impatient': ('조급이', 'Impatient'), 'mirror': ('거울', 'Mirror'), 'lamp': ('눈길 램프', 'Gaze Lamp'),
  'portal': ('웜홀', 'Wormhole'), 'linked': ('연결이', 'Link'), 'ghost': ('유령', 'Ghost'),
  'vine': ('덩굴', 'Vine'), 'hill': ('언덕', 'Hill'), 'horse': ('말', 'Horse'), 'frog': ('개구리', 'Frog'),
  'box': ('나무 상자', 'Wooden Box'), 'rotor': ('회전 거울', 'Pivot Mirror'),
};

final _kinds = {for (final k in CreatureKind.values.where((k) => k != CreatureKind.sated)) kindName(k): k};

class Evaluation {
  Evaluation(this.score, {this.par, this.difficulty, this.reasons = const []});
  final double score;
  final int? par;
  final Difficulty? difficulty;
  final List<String> reasons;
  bool get accepted => score == 0;
}

class RoundGenerator {
  RoundGenerator(this.spec) : random = Random(spec.round * 7919 + 17);
  final RoundSpec spec;
  final Random random;

  int get floor => spec.explanation ? 1 : max(spec.tapFloor, spec.round <= 5 ? openingMinTaps : 0);
  int get maxDepth => spec.explanation ? explanationMaxTaps : floor + 8;
  int get creatureCap => min(maxCreatures, (spec.maxWidth * spec.maxHeight * 0.4).floor());

  T pick<T>(List<T> items) => items[random.nextInt(items.length)];

  List<int> empties(EyeBoard b) => [for (var p = 0; p < b.w * b.h; p++) if (b.emptyLanding(p, groundOnly: true)) p];

  int? cell(EyeBoard b) {
    final pool = empties(b);
    return pool.isEmpty ? null : pick(pool);
  }

  // ------------------------------------------------------------ board edits

  /// Two friends in one row or column with a clear line between them, so a
  /// new board starts out solvable and edits move it from there.
  bool addPair(EyeBoard b) {
    for (var attempt = 0; attempt < 30; attempt++) {
      final p = cell(b);
      if (p == null) return false;
      final d = random.nextInt(4);
      final line = <int>[];
      for (var q = b.step(p, d); q != null && b.emptyLanding(q, groundOnly: true); q = b.step(q, d)) {
        line.add(q);
      }
      if (line.isEmpty) continue;
      final q = pick(line);
      b.cr.add(Creature(x: p % b.w, y: p ~/ b.w, d: random.nextInt(4)));
      b.cr.add(Creature(x: q % b.w, y: q ~/ b.w, d: random.nextInt(4)));
      return true;
    }
    return false;
  }

  /// Cells that share a row or column with another friend, with a clear line
  /// between them: places where a friend gets more than one possible partner.
  List<int> alignedCells(EyeBoard b) {
    final out = <int>{};
    for (final c in b.cr.where((c) => c.alive)) {
      for (var d = 0; d < 4; d++) {
        for (var q = b.step(c.y * b.w + c.x, d); q != null && b.emptyLanding(q, groundOnly: true); q = b.step(q, d)) {
          out.add(q);
        }
      }
    }
    return out.toList();
  }

  /// Puts a friend between two friends that share a line, and its partner on
  /// the crossing line: the outer pair can only meet after the blocker leaves,
  /// so the order of play matters.
  bool addBlocker(EyeBoard b) {
    final alive = [for (final c in b.cr) if (c.alive) c];
    for (var attempt = 0; attempt < 30; attempt++) {
      if (alive.length < 2) return false;
      final a = pick(alive);
      final d = random.nextInt(4);
      final between = <int>[];
      var q = b.step(a.y * b.w + a.x, d);
      while (q != null && b.emptyLanding(q, groundOnly: true)) { between.add(q); q = b.step(q, d); }
      // The line must end on another friend for the blocker to sit between.
      if (q == null || between.isEmpty || !b.cr.any((c) => c.alive && c.y * b.w + c.x == q)) continue;
      final blocker = pick(between);
      final across = (d + 1 + 2 * random.nextInt(2)) % 4;
      final line = <int>[];
      for (var r = b.step(blocker, across); r != null && b.emptyLanding(r, groundOnly: true); r = b.step(r, across)) {
        line.add(r);
      }
      if (line.isEmpty) continue;
      final partner = pick(line);
      b.cr.add(Creature(x: blocker % b.w, y: blocker ~/ b.w, d: random.nextInt(4)));
      b.cr.add(Creature(x: partner % b.w, y: partner ~/ b.w, d: random.nextInt(4)));
      return true;
    }
    return false;
  }

  /// Turns one friend of every pair that already matches before play.
  void unpair(EyeBoard b) {
    for (var attempt = 0; attempt < 24; attempt++) {
      final pairs = b.pairs();
      if (pairs.isEmpty) return;
      final f = b.cr[pick(pairs.first)];
      f.d = (f.d + 1 + random.nextInt(3)) % 4;
    }
  }

  /// Adds one instance of [element] to [b] in place.
  bool place(EyeBoard b, String element) {
    final kind = _kinds[element];
    if (kind != null) {
      final normals = [for (var i = 0; i < b.cr.length; i++) if (b.cr[i].kind == CreatureKind.normal) i];
      if (normals.length < (element == 'linked' ? 2 : 1)) return false;
      normals.shuffle(random);
      b.cr[normals.first].kind = kind;
      if (element == 'linked') b.cr[normals[1]].kind = kind;
      if (element == 'impatient') {
        b.cr[normals.first].patience = 3 + random.nextInt(3);
        b.cr[normals.first].remaining = b.cr[normals.first].patience;
      }
      return true;
    }
    final p = cell(b);
    if (p == null) return false;
    switch (element) {
      case 'rock': b.rocks.add(p);
      case 'cookie': b.crumbs.add(p);
      case 'gate': b.gates[p] = random.nextBool();
      case 'mirror': b.mirrors[p] = random.nextBool();
      case 'rotor': b.rotors[p] = random.nextBool();
      case 'candy': b.candies.add(p);
      case 'box': b.boxes.add(p);
      case 'ghost': b.ghosts.add(p);
      case 'vine': b.vines.add(Vine(p, random.nextInt(4), maxLength: 2 + random.nextInt(3)));
      case 'hill':
        final spots = [for (var q = 0; q < b.w * b.h; q++) if (!b.hills.contains(q) && !b.terrainAt(q)) q];
        if (spots.isEmpty) return false;
        b.hills.add(pick(spots));
      case 'lamp':
        final color = random.nextInt(2);
        b.lamps[p] = color;
        final q = cell(b);
        if (q == null) return false;
        b.lampDoors[q] = color;
      case 'portal':
        var label = 0;
        while (b.portals.containsValue(label)) { label++; }
        if (label > 9) return false;
        b.portals[p] = label;
        final q = cell(b);
        if (q == null) return false;
        b.portals[q] = label;
      default:
        return false;
    }
    return true;
  }

  bool moveTerrain(EyeBoard b) {
    final sets = <Set<int>>[b.rocks, b.crumbs, b.candies, b.boxes, b.ghosts].where((s) => s.isNotEmpty).toList();
    final maps = <Map<int, Object>>[b.gates, b.mirrors, b.rotors, b.lamps, b.lampDoors, b.portals]
        .where((m) => m.isNotEmpty).toList();
    if (sets.isEmpty && maps.isEmpty) return false;
    final to = cell(b);
    if (to == null) return false;
    if (maps.isEmpty || (sets.isNotEmpty && random.nextBool())) {
      final set = pick(sets), from = pick(set.toList());
      set..remove(from)..add(to);
    } else {
      final map = pick(maps), from = pick(map.keys.toList());
      final value = map.remove(from)!;
      map[to] = value;
    }
    return true;
  }

  /// Mutates a copy of [source]; [keep] is never removed.
  EyeBoard? mutate(EyeBoard source, {String? keep}) {
    var b = source.clone();
    final count = 1 + random.nextInt(2);
    // An explanation board shows only the element it introduces.
    final introduced = spec.introduces;
    final allowed = spec.explanation
        ? [if (introduced != null && spec.elements.contains(introduced)) introduced]
        : (spec.elements.toList()..sort());
    for (var k = 0; k < count; k++) {
      final alive = [for (var i = 0; i < b.cr.length; i++) if (b.cr[i].alive) i];
      if (alive.isEmpty) return null;
      final ops = ['rotate', 'rotate', 'rotate', 'rotate', 'move', 'move', 'align', 'align',
        if (alive.length + 2 <= creatureCap) ...['addPair', 'addBlocker'],
        if (alive.length > 4) 'removePair',
        if (allowed.isNotEmpty) ...['addElement', 'removeElement', 'moveTerrain']];
      switch (pick(ops)) {
        case 'rotate':
          final i = pick(alive); b.cr[i].d = (b.cr[i].d + 1 + random.nextInt(3)) % 4;
        case 'move':
          final i = pick(alive), p = cell(b);
          if (p == null) return null;
          b.cr[i].x = p % b.w; b.cr[i].y = p ~/ b.w;
        case 'align':
          final i = pick(alive), spots = alignedCells(b);
          if (spots.isEmpty) return null;
          final p = pick(spots);
          b.cr[i].x = p % b.w; b.cr[i].y = p ~/ b.w;
        case 'addPair':
          if (!addPair(b)) return null;
        case 'addBlocker':
          if (!addBlocker(b)) return null;
        case 'removePair':
          final drop = (alive..shuffle(random)).take(2).toSet();
          final keepKind = keep == null ? null : _kinds[keep];
          if (keepKind != null && drop.any((i) => b.cr[i].kind == keepKind) &&
              b.cr.where((c) => c.kind == keepKind).length <= drop.where((i) => b.cr[i].kind == keepKind).length) {
            return null;
          }
          b = boardFromData({...boardData(b), 'rows': _withoutCreatures(b, drop)});
        case 'addElement':
          if (!place(b, pick(allowed))) return null;
        case 'removeElement':
          final present = (mechanics(b)..remove(keep)).toList();
          if (present.isEmpty) return null;
          b = withoutRule(b, pick(present));
        case 'moveTerrain':
          if (!moveTerrain(b)) return null;
      }
    }
    try {
      // Restores reading-order actor indices and validates the layout.
      final out = boardFromData(boardData(b));
      unpair(out);
      return out;
    } on FormatException {
      return null;
    } on RangeError {
      return null;
    }
  }

  List<String> _withoutCreatures(EyeBoard b, Set<int> drop) {
    final copy = b.clone();
    for (final i in drop) { copy.cr[i].alive = false; }
    return copy.toRows();
  }

  EyeBoard initialBoard() {
    final w = spec.explanation ? 4 + random.nextInt(2) : max(4, spec.maxWidth - random.nextInt(2));
    final h = spec.explanation ? 4 + random.nextInt(2) : max(4, spec.maxHeight - random.nextInt(2));
    var count = spec.explanation ? 2 + 2 * random.nextInt(2) : (floor ~/ 2 + 2);
    count = min(count + count % 2, creatureCap);
    final b = EyeBoard(w: w, h: h, rocks: {}, cr: [], rules: spec.rules);
    // Start from structure, not noise: plain pairs, then blockers that force
    // an order, then friends moved onto shared lines for rival partners.
    final blockers = spec.explanation ? 0 : random.nextInt(count ~/ 4 + 1);
    for (var i = 0; i < count - 2 * blockers; i += 2) { addPair(b); }
    for (var i = 0; i < blockers; i++) { if (!addBlocker(b)) addPair(b); }
    if (!spec.explanation) {
      for (var i = random.nextInt(3); i > 0; i--) {
        final spots = alignedCells(b);
        if (spots.isEmpty) break;
        final f = pick(b.cr), p = pick(spots);
        f.x = p % b.w; f.y = p ~/ b.w;
      }
    }
    final introduced = spec.introduces;
    if (introduced != null && spec.elements.contains(introduced)) place(b, introduced);
    if (!spec.explanation) {
      // A few elements to start with; edits add more. A board crowded with
      // every element introduced so far rarely starts out solvable.
      final elements = spec.elements.toList()..sort()..shuffle(random);
      for (final element in elements.take(random.nextInt(3))) { place(b, element); }
    }
    final out = boardFromData(boardData(b));
    unpair(out);
    return out;
  }

  // ------------------------------------------------------------ evaluation

  Evaluation evaluate(EyeBoard b) {
    if (b.won || b.pairs().isNotEmpty) return Evaluation(1e6, reasons: ['matches_before_play']);
    final kinds = mechanics(b)..remove('rock');
    if (kinds.length > 7) return Evaluation(1e6, reasons: ['more_than_seven_kinds']);
    final quick = searchBoard(b, maxDepth: maxDepth, maxStates: quickStates);
    if (!quick.optimal) return Evaluation(1e6, reasons: ['no_solution_within_${maxDepth}_or_${quick.status.name}']);
    final par = quick.path.length;
    if (par < floor) return Evaluation(10.0 * (floor - par), par: par, reasons: ['below_floor']);
    // One exploration to the tap limit serves every metric (spec 4-2).
    final graph = exploreGraph(b, spec.limitFor(par) ?? par, maxStates: measureStates);
    if (!graph.complete) return Evaluation(1e5, par: par, reasons: ['measure_${graph.status}']);
    return spec.explanation ? _explanationScore(b, par, graph) : _normalScore(b, par, graph);
  }

  Evaluation _explanationScore(EyeBoard b, int par, StateGraph graph) {
    final introduced = spec.introduces!;
    final reasons = <String>[];
    var score = 0.0;
    final present = mechanics(b)..remove('rock');
    if (introduced != 'normal') {
      final evidence = ruleEvidence(b, par, introduced, maxStates: measureStates);
      if (evidence == null || evidence < activeEvidence) {
        score += 50 * (1 - (evidence ?? 0) / activeEvidence);
        reasons.add('introduced_inactive');
      }
    }
    for (final element in present.difference({introduced})) {
      final evidence = ruleEvidence(b, par, element, maxStates: measureStates);
      if (evidence == null || evidence < activeEvidence) { score += 20; reasons.add('decoy:$element'); }
    }
    final difficulty = measureFromGraph(b, graph, par, maxStates: measureStates, elements: false);
    if (difficulty.maxChain > 6) { score += 30; reasons.add('chain_over_six'); }
    if (difficulty.allFirstLethal) { score += 50; reasons.add('all_first_lethal'); }
    return Evaluation(score, par: par, difficulty: difficulty, reasons: reasons);
  }

  Evaluation _normalScore(EyeBoard b, int par, StateGraph graph) {
    final limit = spec.limitFor(par) ?? par;
    var d = measureFromGraph(b, graph, limit, maxStates: measureStates, elements: false);
    if (!d.solved) return Evaluation(1e5, par: par, reasons: ['measure_${d.status}']);
    final reasons = <String>[];
    var score = 0.0;
    void miss(String reason, double cost) { score += cost; reasons.add(reason); }
    final minChoices = spec.minFirstChoices;
    if (minChoices != null && d.legalFirst < minChoices) miss('few_first_choices', 8.0 * (minChoices - d.legalFirst));
    final maxShare = spec.maxCorrectShare, share = d.correctShare;
    if (maxShare != null && share != null && share > maxShare) miss('correct_share', 40 * (share - maxShare));
    final minDead = spec.minDeadEndRatio;
    if (minDead != null) {
      final ratio = d.deadEndRatio;
      if (ratio == null) {
        miss('dead_end_unknown', 10);
      } else if (ratio < minDead) {
        miss('dead_ends', 40 * (minDead - ratio));
      }
    }
    if (spec.trapRequired && d.greedyTrap != true) miss('no_greedy_trap', 15);
    if (d.maxChain > 6) miss('chain_over_six', 30);
    if (d.allFirstLethal) miss('all_first_lethal', 50);
    // Element activity costs two searches per element; only finalists pay it.
    if (score == 0) {
      d = measureElements(b, d, maxStates: measureStates);
      if (d.decoys.length > spec.decoyCap) miss('decoys', 30.0 * (d.decoys.length - spec.decoyCap));
      if (d.unprovenElements.isNotEmpty) miss('unproven_elements', 20);
    }
    return Evaluation(score, par: par, difficulty: d, reasons: reasons);
  }

  // ------------------------------------------------------------ search

  Map<String, Object?> run() {
    final clock = Stopwatch()..start();
    final budget = spec.explanation ? explanationEvaluations : normalEvaluations;
    final introduced = spec.introduces;
    var evaluations = 0, attempts = 0, sinceBest = 0;
    (EyeBoard, Evaluation) fresh() {
      final board = initialBoard();
      evaluations++;
      return (board, evaluate(board));
    }
    final pool = [for (var i = 0; i < population; i++) fresh()];
    var best = pool.reduce((a, b) => a.$2.score <= b.$2.score ? a : b);
    while (!best.$2.accepted && evaluations < budget && attempts++ < budget * 20 &&
        clock.elapsed.inSeconds < safetySeconds) {
      // The better of two random members breeds.
      final x = pick(pool), y = pick(pool);
      final parent = x.$2.score <= y.$2.score ? x : y;
      final candidate = mutate(parent.$1, keep: introduced);
      if (candidate == null) continue;
      if (introduced != null && spec.elements.contains(introduced) &&
          !mechanics(candidate).contains(introduced)) continue;
      evaluations++;
      final e = evaluate(candidate);
      final worst = pool.reduce((a, b) => a.$2.score >= b.$2.score ? a : b);
      // A rare worse step keeps the pool from settling on one local optimum.
      if (e.score < worst.$2.score || random.nextDouble() < 0.02) {
        pool[pool.indexOf(worst)] = (candidate, e);
      }
      if (e.score < best.$2.score) {
        best = (candidate, e);
        sinceBest = 0;
      } else if (++sinceBest > reseedAfter) {
        pool.sort((a, b) => a.$2.score.compareTo(b.$2.score));
        for (var i = population ~/ 2; i < population; i++) { pool[i] = fresh(); }
        sinceBest = 0;
      }
    }
    final (board, evaluation) = best;
    return {
      'round': spec.round, 'status': evaluation.accepted ? 'accepted' : 'best_effort',
      'score': evaluation.score, 'reasons': evaluation.reasons, 'evaluations': evaluations,
      'seconds': clock.elapsed.inSeconds,
      'level': evaluation.par == null ? null : _level(board, evaluation),
      'metrics': evaluation.difficulty?.toJson(),
      'layout': renewalCanonical(board, layoutOnly: true),
    };
  }

  Map<String, Object?> _level(EyeBoard b, Evaluation e) {
    final round = spec.round;
    final solution = e.difficulty?.solution.isNotEmpty == true
        ? e.difficulty!.solution : searchBoard(b, maxDepth: e.par!).path;
    final introduced = spec.introduces;
    final steps = <Map<String, Object>>[];
    if (introduced != null) {
      final (ko, en) = names[introduced]!;
      steps.add(introduced == 'normal'
          ? {'ko': '친구를 눌러 돌려서 두 친구가 서로 마주 보게 하세요.',
             'en': 'Tap creatures to turn them until two face each other.'}
          : {'ko': '새 규칙: $ko. 물음표 가이드에서 자세히 볼 수 있어요.',
             'en': 'New rule: $en. Open the guide to see how it works.'});
      final first = b.actionCell(solution.first);
      steps.add({'x': first % b.w, 'y': first ~/ b.w,
        'ko': '빛나는 곳을 눌러 첫 행동을 해 보세요.', 'en': 'Tap the glowing cell to try the first action.'});
    }
    return {
      'id': 'r${round.toString().padLeft(3, '0')}', 'round': round,
      'kind': introduced == null ? 'normal' : 'explanation',
      if (introduced != null) 'introduces': introduced,
      ...boardData(b),
      'par': e.par, if (spec.limitFor(e.par!) != null) 'limit': spec.limitFor(e.par!),
      'solution': solution,
      'title': '스테이지 $round', 'titleEn': 'Stage $round',
      'tip': '시선과 다음 칸 표시를 살펴보고 순서를 정해 보세요.',
      'tipEn': 'Plan the order using the gazes and next-cell markers.',
      if (steps.isNotEmpty) 'steps': steps,
    };
  }
}

Map<String, Object?> generateRound(int round) => RoundGenerator(specFor(round)).run();

/// A top-level wrapper keeps the isolate closure from capturing main's state.
Future<Map<String, Object?>> runRound(int round) => Isolate.run(() => generateRound(round));

List<int> parseRounds(List<String> args) => [
  for (final arg in args)
    if (arg.contains('-'))
      for (var r = int.parse(arg.split('-').first); r <= int.parse(arg.split('-').last); r++) r
    else
      int.parse(arg),
];

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('Usage: dart tools/generate_campaign.dart <round|from-to> ...');
    exitCode = 64;
    return;
  }
  final redo = args.contains('--redo');
  final output = Directory(outputDirectory)..createSync(recursive: true);
  bool accepted(int round) {
    final file = File('${output.path}/round-${round.toString().padLeft(3, '0')}.json');
    if (!file.existsSync()) return false;
    try {
      return (jsonDecode(file.readAsStringSync()) as Map)['status'] == 'accepted';
    } on FormatException {
      return false;
    }
  }
  final requested = parseRounds([for (final a in args) if (!a.startsWith('--')) a]);
  final rounds = [for (final r in requested) if (redo || !accepted(r)) r];
  if (rounds.length < requested.length) {
    stdout.writeln('skipping ${requested.length - rounds.length} accepted rounds (use --redo to regenerate)');
  }
  final clock = Stopwatch()..start();
  var next = 0, done = 0;
  Future<void> worker() async {
    while (next < rounds.length) {
      final round = rounds[next++];
      final result = await runRound(round);
      File('${output.path}/round-${round.toString().padLeft(3, '0')}.json')
          .writeAsStringSync(encoder.convert(result));
      done++;
      final m = result['metrics'] as Map?;
      stdout.writeln('round $round: ${result['status']} score=${result['score']} '
          'par=${(result['level'] as Map?)?['par']} first=${m?['firstActions']}/${m?['legalFirst']} '
          'dead=${m?['deadEndRatio']} trap=${m?['greedyTrap']} decoys=${m?['decoys']} '
          'reasons=${(result['reasons'] as List).join(',')} '
          '(${result['evaluations']} evals, ${result['seconds']}s; $done/${rounds.length}, ${clock.elapsed.inSeconds}s)');
    }
  }
  await Future.wait([for (var w = 0; w < min(workers, rounds.length); w++) worker()]);
}
