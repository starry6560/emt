import 'dart:math' as math;

import 'package:emt/game/eye_logic.dart';

String kindName(CreatureKind kind) => switch (kind) {
  CreatureKind.normal => 'normal',
  CreatureKind.anchored => 'anchored',
  CreatureKind.spark => 'spark',
  CreatureKind.hopper => 'hopper',
  CreatureKind.eater || CreatureKind.sated => 'eater',
  CreatureKind.linked => 'linked',
  CreatureKind.beckoner => 'beckoner', CreatureKind.impatient => 'impatient',
  CreatureKind.horse => 'horse', CreatureKind.frog => 'frog',
};

Set<String> mechanics(EyeBoard board) => {
  for (final c in board.cr) if (c.kind != CreatureKind.normal) kindName(c.kind),
  if (board.rocks.isNotEmpty) 'rock',
  if (board.crumbs.isNotEmpty) 'cookie',
  if (board.gates.isNotEmpty) 'gate',
  if (board.mirrors.isNotEmpty) 'mirror',
  if (board.portals.isNotEmpty) 'portal',
  if (board.rotors.isNotEmpty) 'rotor',
  if(board.hills.isNotEmpty) 'hill', if(board.boxes.isNotEmpty) 'box',
  if(board.candies.isNotEmpty) 'candy', if(board.ghosts.isNotEmpty) 'ghost',
  if(board.vines.isNotEmpty) 'vine', if(board.lamps.isNotEmpty || board.lampDoors.isNotEmpty) 'lamp',
};

/// A behavioral trace deliberately omits terrain state. Removing a decorative
/// wall must not count as a different puzzle merely because the wall vanished.
String behaviorTrace(EyeBoard start, List<int> path) {
  final board = start.clone();
  final out = StringBuffer();
  out.write('initial:${board.pairs()}|');
  for (final move in path) {
    if (!board.canAct(move)) return '${out}invalid:$move';
    final rounds = board.tapDetailed(move);
    for (final wave in rounds) {
      out.write('${wave.pairs}/${wave.removed.toList()..sort()}/'
          '${wave.fed.toList()..sort()}/${wave.turned}/');
      for (final route in wave.routes) {
        out.write(route.map((p) => '${p.x},${p.y},${p.warp ? 1 : 0}').join(';'));
      }
      out.write('|');
    }
    out.write(board.cr.map((c) => '${c.x},${c.y},${c.d},${c.alive ? 1 : 0}').join(';'));
    out.write('\n');
  }
  return out.toString();
}

EyeBoard withoutTerrain(EyeBoard board, String type) => EyeBoard(
  w: board.w, h: board.h, cr: [for (final c in board.cr) c.copy()],
  rocks: type == 'rock' ? <int>{} : Set.of(board.rocks),
  crumbs: type == 'cookie' ? <int>{} : Set.of(board.crumbs),
  gates: type == 'gate' ? <int, bool>{} : Map.of(board.gates),
  mirrors: type == 'mirror' ? <int, bool>{} : Map.of(board.mirrors),
  portals: type == 'portal' ? <int, int>{} : Map.of(board.portals),
  rotors: Map.of(board.rotors), hills:Set.of(board.hills),boxes:Set.of(board.boxes),
  candies:Set.of(board.candies),ghosts:Set.of(board.ghosts),lamps:Map.of(board.lamps),
  lampDoors:Map.of(board.lampDoors),litColors:Set.of(board.litColors),vines:[for(final v in board.vines) v.copy()],
);

class Quality {
  const Quality(this.metrics, this.used, this.steps);
  final Map<String, Object> metrics;
  final Set<String> used;
  final List<Map<String, Object>> steps;
  double get score => metrics['difficultyScore'] as double;
  int get chain => metrics['maxChain'] as int;
}

Quality inspectSolution(EyeBoard initial, List<int> path, int explored) {
  final board = initial.clone();
  final used = <String>{};
  final steps = <Map<String, Object>>[];
  var maxChain = 0, simultaneous = 0, setup = 0, run = 0, maxSetup = 0;
  var hops = 0, meals = 0, turns = 0, broken = 0, reflections = 0, warps = 0;
  var choices = 0;
  var linkedTurns = 0, rotorTaps = 0, rotorPasses = 0;
  for (final move in path) {
    if (!board.canAct(move)) throw StateError('Solver supplied an illegal action: $move');
    final legal = [for (var i = 0; i < board.actionCount; i++) if (board.canAct(i)) i];
    choices += legal.length;
    final actor = move < board.cr.length ? board.cr[move] : null;
    final cell = board.actionCell(move);
    final x = cell % board.w, y = cell ~/ board.w;
    final action = actor == null ? 'swivel'
        : actor.kind == CreatureKind.hopper ? 'hop'
        : actor.kind == CreatureKind.linked ? 'linked' : 'rotate';
    if (action == 'swivel') { rotorTaps++; used.add('rotor'); }
    if (action == 'linked' && board.cr.where((c) => c.alive && c.kind == CreatureKind.linked).length >= 2) {
      linkedTurns++; used.add('linked');
    }
    if (action == 'hop') { hops++; used.add('hopper'); }
    final kinds = [for (final c in board.cr) c.kind];
    final rounds = board.tapDetailed(move);
    maxChain = math.max(maxChain, rounds.length);
    if (rounds.isEmpty) {
      setup++; run++; maxSetup = math.max(maxSetup, run);
    } else {
      run = 0;
    }
    for (final wave in rounds) {
      simultaneous = math.max(simultaneous, wave.pairs.length);
      meals += wave.fed.length;
      turns += wave.turned.length;
      broken += wave.brokenCrumbs.length;
      if (wave.fed.isNotEmpty) used.add('eater');
      if (wave.turned.isNotEmpty) used.add('spark');
      if (wave.turned.keys.where((i) => kinds[i] == CreatureKind.linked).length >= 2) {
        linkedTurns++; used.add('linked');
      }
      if (wave.removed.any((i) => kinds[i] == CreatureKind.anchored)) used.add('anchored');
      for (final route in wave.routes) {
        for (final point in route) {
          if (initial.mirrors.containsKey(point.y * board.w + point.x)) reflections++;
          if (initial.rotors.containsKey(point.y * board.w + point.x)) rotorPasses++;
          if (point.warp) warps++;
        }
      }
    }
    steps.add({
      'creature': move, 'x': x, 'y': y, 'action': action,
      'rounds': rounds.length,
      'removed': rounds.fold<int>(0, (sum, r) => sum + r.removed.length),
      'rowsAfter': board.toRows(),
    });
  }
  if (!board.won) throw StateError('A reported solution did not clear the board.');
  final trace = behaviorTrace(initial, path);
  for (final terrain in const ['rock', 'cookie', 'gate', 'mirror', 'portal']) {
    if (mechanics(initial).contains(terrain) &&
        behaviorTrace(withoutTerrain(initial, terrain), path) != trace) {
      used.add(terrain);
    }
  }
  final averageChoices = path.isEmpty ? 0.0 : choices / path.length;
  // This is a transparent ranking heuristic, not a measured player difficulty.
  final score = (path.length * 3.0 + maxSetup * 4.0 +
      math.log(averageChoices + 1) * 3 + used.length * 2.5 +
      math.log(explored + 1) * 1.2).clamp(0.0, 100.0).toDouble();
  final label = score < 22 ? 'intro' : score < 36 ? 'easy' : score < 52 ? 'medium'
      : score < 70 ? 'hard' : 'expert';
  return Quality({
    'difficultyScore': (score * 10).round() / 10,
    'difficultyBand': label,
    'par': path.length, 'maxChain': maxChain, 'maxSimultaneousPairs': simultaneous,
    'setupMoves': setup, 'longestSetupRun': maxSetup,
    'averageLegalChoices': (averageChoices * 100).round() / 100,
    'exploredStates': explored, 'hops': hops, 'meals': meals,
    'sparkTurns': turns, 'brokenCookies': broken,
    'linkedTurns': linkedTurns, 'rotorTaps': rotorTaps, 'rotorPasses': rotorPasses,
    'mirrorPasses': reflections, 'portalJumps': warps,
    'chainScore': maxChain * 4 + math.max(0, simultaneous - 1) * 3 + turns + broken,
  }, used, steps);
}

List<String> rotateRows(List<String> rows) {
  final h = rows.length, w = rows.first.length;
  final out = List.generate(w, (_) => List.filled(h, '.'));
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var symbol = rows[y][x];
      for (final chars in kCreatureChars.values) {
        final d = chars.indexOf(symbol);
        if (d >= 0) { symbol = chars[(d + 1) % 4]; break; }
      }
      if (rows[y][x] == '/') symbol = '\\';
      if (rows[y][x] == '\\') symbol = '/';
      if (rows[y][x] == '+') symbol = '=';
      if (rows[y][x] == '=') symbol = '+';
      out[x][h - 1 - y] = symbol;
    }
  }
  return out.map((r) => r.join()).toList();
}

List<String> _trim(List<String> rows) {
  // Empty border cells are playable space for hoppers; never trim those boards.
  if (rows.any((r) => r.split('').any(kCreatureChars[CreatureKind.hopper]!.contains))) return rows;
  var top = 0, bottom = rows.length - 1, left = 0, right = rows.first.length - 1;
  while (top < bottom && rows[top].split('').every((c) => c == '.')) { top++; }
  while (bottom > top && rows[bottom].split('').every((c) => c == '.')) { bottom--; }
  bool emptyColumn(int x) => [for (var y = top; y <= bottom; y++) rows[y][x]].every((c) => c == '.');
  while (left < right && emptyColumn(left)) { left++; }
  while (right > left && emptyColumn(right)) { right--; }
  var trimmed = [for (var y = top; y <= bottom; y++) rows[y].substring(left, right + 1)];
  // Distance is semantically relevant only to local effects and movement.
  // A normal/optical board with another empty row is not a new puzzle.
  final local = rows.any((r) => r.contains('*') ||
      r.split('').any(kCreatureChars[CreatureKind.spark]!.contains));
  if (!local) {
    trimmed = trimmed.where((r) => r.split('').any((c) => c != '.')).toList();
    final columns = [for (var x = 0; x < trimmed.first.length; x++)
      if (trimmed.any((r) => r[x] != '.')) x];
    trimmed = [for (final r in trimmed) [for (final x in columns) r[x]].join()];
  }
  return trimmed;
}

String _normalized(List<String> rows, bool layoutOnly) {
  final labels = <String, String>{};
  final out = <String>[];
  for (final row in _trim(rows)) {
    final line = StringBuffer();
    for (var x = 0; x < row.length; x++) {
      var c = row[x];
      if (int.tryParse(c) != null) {
        c = labels.putIfAbsent(c, () => '${labels.length}');
      } else if (layoutOnly) {
        if (c == '+' || c == '=') c = '+';
        for (final entry in kCreatureChars.entries) {
          if (entry.value.contains(c)) { c = '~${entry.key.index}'; break; }
        }
      }
      line.write('$c,');
    }
    out.add(line.toString());
  }
  return out.join('\n');
}

/// Horizontal reflection is deliberately a CONTENT equivalence even though
/// it reverses the chirality of clockwise actions and may change shortest par.
List<String> reflectRows(List<String> rows) => [
  for (final row in rows) [for (var x = row.length - 1; x >= 0; x--) (() {
    final c = row[x];
    for (final chars in kCreatureChars.values) {
      final d = chars.indexOf(c);
      if (d >= 0) return chars[const [0, 3, 2, 1][d]];
    }
    return switch (c) { '/' => '\\', '\\' => '/', '+' => '=', '=' => '+', _ => c };
  })()].join(),
];

/// Directions are erased for layout comparison; all eight dihedral transforms
/// are reviewed. This prevents filling a chapter by flipping a solved layout.
String canonicalKey(List<String> rows, {bool layoutOnly = false}) {
  var rotated = rows;
  final keys = <String>[];
  for (var i = 0; i < 4; i++) {
    keys.add(_normalized(rotated, layoutOnly));
    keys.add(_normalized(reflectRows(rotated), layoutOnly));
    rotated = rotateRows(rotated);
  }
  keys.sort();
  return keys.first;
}

class DiversityIndex {
  DiversityIndex(this.nearThreshold);
  final double nearThreshold;
  final Set<String> _exact = {}, _layouts = {};
  final List<Set<String>> _shapes = [];

  List<Set<String>> _shapeVariants(List<String> rows) {
    var rotated = rows;
    final variants = <List<String>>[];
    for (var turn = 0; turn < 4; turn++) {
      variants.add(rotated);
      variants.add(reflectRows(rotated));
      rotated = rotateRows(rotated);
    }
    return [for (final variant in variants) (() {
      final lines = _normalized(variant, true).split('\n');
      final tokens = <String>{};
      for (var y = 0; y < lines.length; y++) {
        final cells = lines[y].split(',');
        for (var x = 0; x < cells.length; x++) {
          if (cells[x].isNotEmpty && cells[x] != '.') tokens.add('$x:$y:${cells[x]}');
        }
      }
      // Board dimensions matter for hopping, even when the occupied cells match.
      if (mechanics(EyeBoard.parse(variant)).contains('hopper')) {
        tokens.add('bounds:${variant.first.length}:${variant.length}');
      }
      return tokens;
    })()];
  }

  String? rejectReason(List<String> rows) {
    if (_exact.contains(canonicalKey(rows))) return 'duplicate';
    if (_layouts.contains(canonicalKey(rows, layoutOnly: true))) return 'same_layout';
    if (nearThreshold >= 1) return null;
    final variants = _shapeVariants(rows);
    for (final previous in _shapes) {
      for (final a in variants) {
        if (math.min(a.length, previous.length) / math.max(a.length, previous.length) < nearThreshold) continue;
        final shared = a.intersection(previous).length;
        final union = a.length + previous.length - shared;
        if (union > 0 && shared / union >= nearThreshold) return 'near_duplicate';
      }
    }
    return null;
  }

  void add(List<String> rows) {
    _exact.add(canonicalKey(rows));
    _layouts.add(canonicalKey(rows, layoutOnly: true));
    _shapes.add(_shapeVariants(rows).first);
  }
}
