// Pure game rules. No Flutter imports, so it is unit-testable and
// can run inside an isolate (hint solver).
//
// A tap rotates a creature, or moves a hopper. Reciprocal rays can reflect and
// teleport. Matches remove pairs (or feed an eater), then resolve local effects
// until no new pair remains. Rendering replays the captured routes and effects.

import 'dart:collection';
import 'dart:convert';

/// 0 up, 1 right, 2 down, 3 left (clockwise order, so +1 = rotate clockwise).
const List<int> kDx = [0, 1, 0, -1];
const List<int> kDy = [-1, 0, 1, 0];
const Map<String, int> kDirChar = {'^': 0, '>': 1, 'v': 2, '<': 3};
const List<String> kCharDir = ['^', '>', 'v', '<'];

enum CreatureKind { normal, anchored, spark, hopper, eater, sated, linked, beckoner, impatient, horse, frog }

const Map<CreatureKind, List<String>> kCreatureChars = {
  CreatureKind.normal: ['^', '>', 'v', '<'],
  CreatureKind.anchored: ['U', 'R', 'D', 'L'],
  CreatureKind.spark: ['u', 'r', 'd', 'l'],
  CreatureKind.hopper: ['n', 'e', 's', 'w'],
  CreatureKind.eater: ['N', 'E', 'S', 'W'],
  CreatureKind.sated: ['A', 'B', 'C', 'F'],
  CreatureKind.linked: ['h', 'i', 'j', 'k'],
  CreatureKind.beckoner: ['a', 'b', 'c', 'f'],
  CreatureKind.impatient: ['G', 'H', 'I', 'J'],
  CreatureKind.horse: ['M', 'O', 'P', 'Q'],
  CreatureKind.frog: ['t', 'x', 'y', 'z'],
};

/// Board-wide rules a level switches on (the spec 1-3 to 1-5).
/// Every rule is off by default, so older content keeps its original behavior.
class EyeRules {
  const EyeRules({this.noTriangle = false, this.removalTurnsNeighbors = false,
    this.tapTurnsNeighbors = false});

  /// B: a friend gazed at by two or more same-layer friends cannot match.
  final bool noTriangle;

  /// C: a removed friend turns its orthogonal neighbors clockwise; a spark
  /// turns them counter-clockwise instead, and opposite turns cancel.
  final bool removalTurnsNeighbors;

  /// D: a tap that turns the tapped friend itself also turns its orthogonal
  /// neighbors. Linked taps are exempt.
  final bool tapTurnsNeighbors;

  static const none = EyeRules();
  static const _names = ['noTriangle', 'removalTurnsNeighbors', 'tapTurnsNeighbors'];

  /// Reads the level-file form: a list of rule names, or null for none.
  factory EyeRules.fromJson(Object? data) {
    if (data == null) return none;
    final names = (data as List).cast<String>().toSet();
    final unknown = names.difference(_names.toSet());
    if (unknown.isNotEmpty) throw FormatException('Unknown board rules: ${unknown.join(', ')}');
    return EyeRules(noTriangle: names.contains('noTriangle'),
        removalTurnsNeighbors: names.contains('removalTurnsNeighbors'),
        tapTurnsNeighbors: names.contains('tapTurnsNeighbors'));
  }

  List<String> toJson() => [
    if (noTriangle) 'noTriangle',
    if (removalTurnsNeighbors) 'removalTurnsNeighbors',
    if (tapTurnsNeighbors) 'tapTurnsNeighbors',
  ];

  @override
  bool operator ==(Object other) => other is EyeRules && other.noTriangle == noTriangle &&
      other.removalTurnsNeighbors == removalTurnsNeighbors &&
      other.tapTurnsNeighbors == tapTurnsNeighbors;

  @override
  int get hashCode => Object.hash(noTriangle, removalTurnsNeighbors, tapTurnsNeighbors);
}

class Creature {
  Creature({required this.x, required this.y, required this.d, this.alive = true,
    this.kind = CreatureKind.normal, this.patience = 4, int? remaining})
      : remaining = remaining ?? patience;
  int patience, remaining;
  int x;
  int y;
  int d;
  bool alive;
  CreatureKind kind;
  bool get canTap => alive && kind != CreatureKind.anchored;

  Creature copy() => Creature(x: x, y: y, d: d, alive: alive, kind: kind,
      patience: patience, remaining: remaining);
}

class Vine {
  Vine(this.root, this.direction, {this.maxLength = 99, this.length = 0});
  final int root, direction, maxLength;
  int length;
  Vine copy() => Vine(root, direction, maxLength: maxLength, length: length);
}

/// Ordered, replayable changes, including waves without a matching pair.
class BoardEvent {
  const BoardEvent(this.kind, this.from, this.to, {this.actor = -1});
  final String kind;
  final int from, to, actor;
}

class BoardFrame {
  const BoardFrame(this.board, this.events, this.round);
  final EyeBoard board;
  final List<BoardEvent> events;
  final MatchRound? round;
}

class MatchRound {
  const MatchRound(this.pairs, this.brokenCrumbs, this.turned,
      {required this.removed, required this.fed, required this.routes});
  final List<List<int>> pairs;
  final Set<int> brokenCrumbs;
  final Map<int, int> turned;
  final Set<int> removed;
  final Set<int> fed;
  final List<List<SightPoint>> routes;
}

/// A cell on a ray. A warp point jumps from the preceding portal without
/// traversing the intervening board. Coordinates remain in board cells.
class SightPoint {
  const SightPoint(this.x, this.y, {this.warp = false});
  final int x, y;
  final bool warp;
}

/// What a creature's line of sight runs into.
enum SightHit { edge, rock, creature, crumb, gate, loop, lamp, box, vine, ghost }

class Sight {
  const Sight(this.free, this.hit, this.target, this.direction, this.route);

  /// Number of traversed non-actor cells (including optical terrain).
  final int free;
  final SightHit hit;

  /// Index of the creature that is seen, or -1.
  final int target;
  final int direction;
  final List<SightPoint> route;
}

class EyeBoard {
  EyeBoard({required this.w, required this.h, required this.rocks, required this.cr,
    Set<int>? crumbs, Map<int, bool>? gates, Map<int, bool>? mirrors,
    Map<int, int>? portals, Map<int, bool>? rotors, Set<int>? hills,
    Set<int>? boxes, Set<int>? candies, Set<int>? ghosts,
    Map<int, int>? lamps, Map<int, int>? lampDoors, Set<int>? litColors,
    List<Vine>? vines, this.failed = false, this.rules = EyeRules.none})
      : crumbs = crumbs ?? <int>{}, gates = gates ?? <int, bool>{},
        mirrors = mirrors ?? <int, bool>{}, portals = portals ?? <int, int>{},
        rotors = rotors ?? <int, bool>{}, hills = hills ?? <int>{},
        boxes = boxes ?? <int>{}, candies = candies ?? <int>{},
        ghosts = ghosts ?? <int>{}, lamps = lamps ?? <int, int>{},
        lampDoors = lampDoors ?? <int, int>{}, litColors = litColors ?? <int>{},
        vines = vines ?? <Vine>[];

  factory EyeBoard.parse(List<String> rows, {List<String>? heights,
      Map<String, dynamic>? parameters, EyeRules rules = EyeRules.none}) {
    if (rows.isEmpty || rows.first.isEmpty || rows.any((r) => r.length != rows.first.length)) {
      throw const FormatException('Level rows must form a non-empty rectangle.');
    }
    final h = rows.length;
    final w = rows.first.length;
    final rocks = <int>{};
    final cr = <Creature>[];
    final crumbs = <int>{};
    final gates = <int, bool>{};
    final mirrors = <int, bool>{};
    final rotors = <int, bool>{};
    final portals = <int, int>{};
    final hills = <int>{}, boxes = <int>{}, candies = <int>{}, ghosts = <int>{};
    final lamps = <int, int>{}, lampDoors = <int, int>{};
    final vines = <Vine>[];
    if (heights != null && (heights.length != h || heights.any((r) => r.length != w))) {
      throw const FormatException('Heights must match rows.');
    }
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final c = rows[y][x];
        final p = y * w + x;
        final config = Map<String, dynamic>.from(parameters?['$p'] as Map? ?? const {});
        if (heights != null && heights[y][x] == '^') hills.add(p);
        if (c == 'K') { boxes.add(p);
        } else if (c == 'g') { lamps[p] = config['color'] as int? ?? 0;
        } else if (c == 'm') { lampDoors[p] = config['color'] as int? ?? 0;
        } else if (c == 'o') { vines.add(Vine(p, config['direction'] as int? ?? 2,
            maxLength: config['maxLength'] as int? ?? 99));
        } else if (c == 'q') { candies.add(p);
        } else if (c == 'X') { ghosts.add(p);
        } else if (c == '#') {
          rocks.add(y * w + x);
        } else if (c == '*') {
          crumbs.add(y * w + x);
        } else if (c == '|' || c == ':') {
          gates[y * w + x] = c == ':';
        } else if (c == '/' || c == '\\') {
          mirrors[y * w + x] = c == '/';
        } else if (c == '+' || c == '=') {
          rotors[y * w + x] = c == '+';
        } else if (int.tryParse(c) != null) {
          portals[y * w + x] = int.parse(c);
        } else if (c != '.') {
          final matches = kCreatureChars.entries.where((e) => e.value.contains(c));
          if (matches.isEmpty) throw FormatException('Unknown level symbol: $c');
          final kind = matches.first;
          final patience = config['patience'] as int? ?? 4;
          if (kind.key == CreatureKind.impatient && (patience < 3 || patience > 5)) {
            throw const FormatException('Patience must be 3–5.');
          }
          cr.add(Creature(x: x, y: y, d: kind.value.indexOf(c), kind: kind.key, patience: patience));
        }
      }
    }
    for (final label in portals.values.toSet()) {
      if (portals.values.where((v) => v == label).length != 2) {
        throw FormatException('Portal $label must occur exactly twice.');
      }
    }
    final board = EyeBoard(w: w, h: h, rocks: rocks, cr: cr, crumbs: crumbs,
        gates: gates, mirrors: mirrors, portals: portals, rotors: rotors,
        hills: hills, boxes: boxes, candies: candies, ghosts: ghosts,
        lamps: lamps, lampDoors: lampDoors, vines: vines, rules: rules);
    if (hills.any((p) => board.terrainAt(p))) {
      throw const FormatException('Only friends and floor items may occupy hills.');
    }
    board.refreshLamps();
    return board;
  }

  final int w;
  final int h;
  final Set<int> rocks;
  final List<Creature> cr;
  final Set<int> crumbs;
  final Map<int, bool> gates; // true = open; toggles once per valid tap
  final Map<int, bool> mirrors; // true = /, false = backslash
  final Map<int, int> portals; // cell -> paired label; heading is preserved
  final Map<int, bool> rotors; // tappable mirrors: true = /, false = backslash
  final Set<int> hills, boxes, candies, ghosts, litColors;
  final Map<int, int> lamps, lampDoors;
  final List<Vine> vines;
  final EyeRules rules;
  bool failed;
  final List<BoardEvent> events = [];
  final List<BoardFrame> frames = [];
  bool get hasRenewal => hills.isNotEmpty || boxes.isNotEmpty || candies.isNotEmpty ||
      ghosts.isNotEmpty || lamps.isNotEmpty || lampDoors.isNotEmpty || vines.isNotEmpty ||
      cr.any((c) => c.kind.index >= CreatureKind.beckoner.index);
  bool elevated(int i) => hills.contains(cr[i].y * w + cr[i].x);
  Set<int> get vineCells => {for (final v in vines)
    for (var n = 0; n <= v.length; n++) v.root + n * (kDy[v.direction] * w + kDx[v.direction])};
  bool terrainAt(int p) => rocks.contains(p) || crumbs.contains(p) || gates.containsKey(p) ||
      mirrors.containsKey(p) || portals.containsKey(p) || rotors.containsKey(p) ||
      boxes.contains(p) || lamps.containsKey(p) || lampDoors.containsKey(p) ||
      vineCells.contains(p) || ghosts.contains(p);
  bool emptyLanding(int p, {bool groundOnly = false}) => p >= 0 && p < w * h &&
      (!groundOnly || !hills.contains(p)) && !terrainAt(p) &&
      !cr.any((c) => c.alive && c.y * w + c.x == p);
  int? step(int p, int d, [int distance = 1]) {
    final x = p % w + kDx[d] * distance, y = p ~/ w + kDy[d] * distance;
    return x < 0 || y < 0 || x >= w || y >= h ? null : y * w + x;
  }

  /// Creature indices never change when actors move or disappear. Terrain
  /// actions follow them in reading order and remain stable throughout a game.
  List<int> get rotorCells => rotors.keys.toList()..sort();
  int get actionCount => cr.length + rotors.length;
  int actionCell(int action) {
    if (action < 0 || action >= actionCount) {
      throw RangeError.range(action, 0, actionCount - 1, 'action');
    }
    if (action < cr.length) return cr[action].y * w + cr[action].x;
    return rotorCells[action - cr.length];
  }

  EyeBoard clone() => EyeBoard(w: w, h: h, rocks: Set.of(rocks),
      cr: [for (final c in cr) c.copy()], crumbs: Set.of(crumbs), gates: Map.of(gates),
      mirrors: Map.of(mirrors), portals: Map.of(portals), rotors: Map.of(rotors),
      hills: Set.of(hills), boxes: Set.of(boxes), candies: Set.of(candies),
      ghosts: Set.of(ghosts), lamps: Map.of(lamps), lampDoors: Map.of(lampDoors),
      litColors: Set.of(litColors), vines: [for (final v in vines) v.copy()], failed: failed,
      rules: rules);

  /// Flat int encoding so a board can cross an isolate boundary cheaply.
  /// Creature indices are preserved, so a solver path maps back 1:1.
  List<int> encode() => [
        -5,
        w,
        h,
        rocks.length,
        ...rocks,
        cr.length,
        for (final c in cr) ...[c.x, c.y, c.d, c.alive ? 1 : 0, c.kind.index],
        crumbs.length, ...crumbs,
        gates.length, for (final g in gates.entries) ...[g.key, g.value ? 1 : 0],
        mirrors.length, for (final m in mirrors.entries) ...[m.key, m.value ? 1 : 0],
        portals.length, for (final p in portals.entries) ...[p.key, p.value],
        rotors.length, for (final r in rotors.entries) ...[r.key, r.value ? 1 : 0],
        ...utf8.encode(jsonEncode({
          'hills': hills.toList(), 'boxes': boxes.toList(), 'candies': candies.toList(),
          'ghosts': ghosts.toList(), 'lamps': lamps.map((k,v) => MapEntry('$k',v)),
          'doors': lampDoors.map((k,v) => MapEntry('$k',v)), 'lit': litColors.toList(),
          'vines': [for (final v in vines) [v.root,v.direction,v.maxLength,v.length]],
          'patience': [for (final c in cr) [c.patience,c.remaining]], 'failed': failed,
          'rules': rules.toJson(),
        })),
      ];

  factory EyeBoard.decode(List<int> e) {
    final legacy = e.first >= 0;
    var k = legacy ? 0 : 1;
    final w = e[k++], h = e[k++];
    final nr = e[k++];
    final rocks = <int>{for (var i = 0; i < nr; i++) e[k + i]};
    k += nr;
    final nc = e[k++];
    final cr = <Creature>[];
    for (var i = 0; i < nc; i++) {
      cr.add(Creature(x: e[k], y: e[k + 1], d: e[k + 2], alive: e[k + 3] == 1,
          kind: legacy ? CreatureKind.normal : CreatureKind.values[e[k + 4]]));
      k += legacy ? 4 : 5;
    }
    final crumbs = <int>{};
    final gates = <int, bool>{};
    if (!legacy) {
      final count = e[k++];
      for (var i = 0; i < count; i++) { crumbs.add(e[k++]); }
      final gateCount = e[k++];
      for (var i = 0; i < gateCount; i++) {
        final position = e[k++];
        gates[position] = e[k++] == 1;
      }
    }
    final mirrors = <int, bool>{};
    final portals = <int, int>{};
    if (e.first <= -3) {
      final count = e[k++];
      for (var i = 0; i < count; i++) {
        final position = e[k++];
        mirrors[position] = e[k++] == 1;
      }
      final portalCount = e[k++];
      for (var i = 0; i < portalCount; i++) {
        final position = e[k++];
        portals[position] = e[k++];
      }
    }
    final rotors = <int, bool>{};
    if (e.first <= -4) {
      final count = e[k++];
      for (var i = 0; i < count; i++) {
        final position = e[k++];
        rotors[position] = e[k++] == 1;
      }
    }
    final data = e.first == -5
        ? jsonDecode(utf8.decode(e.sublist(k))) as Map<String,dynamic> : null;
    final board = EyeBoard(w: w, h: h, rocks: rocks, cr: cr, crumbs: crumbs,
        gates: gates, mirrors: mirrors, portals: portals, rotors: rotors,
        rules: EyeRules.fromJson(data?['rules']));
    if (data != null) {
      for (final entry in {'hills':board.hills,'boxes':board.boxes,
        'candies':board.candies,'ghosts':board.ghosts,'lit':board.litColors}.entries) {
        entry.value.addAll((data[entry.key] as List).cast<int>());
      }
      for (final entry in {'lamps':board.lamps,'doors':board.lampDoors}.entries) {
        (data[entry.key] as Map).forEach((key,value) { entry.value[int.parse(key as String)] = value as int; });
      }
      for (final v in data['vines'] as List) {
        board.vines.add(Vine(v[0] as int,v[1] as int,maxLength:v[2] as int,length:v[3] as int));
      }
      for (var i=0;i<cr.length;i++) {
        cr[i].patience=data['patience'][i][0] as int;
        cr[i].remaining=data['patience'][i][1] as int;
      }
      board.failed=data['failed'] as bool;
    }
    return board;
  }

  bool get won => !failed && cr.every((c) => !c.alive);
  int get aliveCount => cr.where((c) => c.alive).length;

  /// State within one level: positions, directions, appetite, cookies, gates,
  /// and the orientation of each tappable mirror.
  String get key {
    final walls = crumbs.toList()..sort();
    final doors = gates.keys.toList()..sort();
    return '${cr.map((c) => c.alive ? '${c.x},${c.y},${c.d},${c.kind.index}' : 'x').join(';')}'
        '/${walls.join(',')}/${doors.map((p) => gates[p]! ? '1' : '0').join()}'
        '/${rotorCells.map((p) => rotors[p]! ? '1' : '0').join()}'
        '/${cr.map((c) => c.remaining).join(',')}/${_sorted(boxes)}/${_sorted(ghosts)}'
        '/${_sorted(candies)}/${_sorted(litColors)}/${vines.map((v)=>v.length).join(',')}/$failed';
  }
  String _sorted(Set<int> values) => (values.toList()..sort()).join(',');

  /// Rows in the same text format the level file uses.
  List<String> toRows() {
    final g = List.generate(h, (_) => List.filled(w, '.'));
    for (final r in rocks) {
      g[r ~/ w][r % w] = '#';
    }
    for (final r in crumbs) { g[r ~/ w][r % w] = '*'; }
    for (final entry in gates.entries) {
      g[entry.key ~/ w][entry.key % w] = entry.value ? ':' : '|';
    }
    for (final entry in mirrors.entries) {
      g[entry.key ~/ w][entry.key % w] = entry.value ? '/' : '\\';
    }
    for (final entry in rotors.entries) {
      g[entry.key ~/ w][entry.key % w] = entry.value ? '+' : '=';
    }
    for (final entry in portals.entries) {
      g[entry.key ~/ w][entry.key % w] = '${entry.value}';
    }
    for (final entry in {'K':boxes,'q':candies,'X':ghosts,
      'g':lamps.keys.toSet(),'m':lampDoors.keys.toSet(),'o':vines.map((v)=>v.root).toSet()}.entries) {
      for (final p in entry.value) { g[p ~/ w][p % w] = entry.key; }
    }
    for (final c in cr) {
      if (c.alive) g[c.y][c.x] = kCreatureChars[c.kind]![c.d];
    }
    return [for (final row in g) row.join()];
  }

  /// Occupancy: -4 closed gate, -3 cookie, -2 rock, -1 empty, >=0 creature.
  /// [visible] lets the UI treat creatures that are still on screen as present.
  List<int> grid({List<bool>? visible, Set<int>? visibleCrumbs, Map<int, bool>? visibleGates}) {
    final g = List<int>.filled(w * h, -1);
    for (final r in rocks) {
      g[r] = -2;
    }
    for (final r in visibleCrumbs ?? crumbs) { g[r] = -3; }
    for (final entry in (visibleGates ?? gates).entries) {
      if (!entry.value) g[entry.key] = -4;
    }
    for (var i = 0; i < cr.length; i++) {
      final present = visible != null ? visible[i] : cr[i].alive;
      if (present) g[cr[i].y * w + cr[i].x] = i;
    }
    return g;
  }

  Sight sight(int i, List<int> g, {int? direction}) {
    final c = cr[i];
    var d = direction ?? c.d;
    var x = c.x, y = c.y, free = 0;
    final route = <SightPoint>[SightPoint(x, y)];
    final seen = <int>{};
    Sight finish(SightHit hit, [int target = -1]) => Sight(free, hit, target, d, route);
    while (true) {
      if (!seen.add((y * w + x) * 4 + d)) return finish(SightHit.loop);
      x += kDx[d];
      y += kDy[d];
      route.add(SightPoint(x, y));
      if (x < 0 || y < 0 || x >= w || y >= h) return finish(SightHit.edge);
      final position = y * w + x;
      final v = g[position];
      if (v == -2) return finish(SightHit.rock);
      if (!elevated(i)) {
        if (v == -3) return finish(SightHit.crumb);
        if (v == -4 || (lampDoors.containsKey(position) && !litColors.contains(lampDoors[position]))) return finish(SightHit.gate);
        if (lamps.containsKey(position)) return finish(SightHit.lamp);
        if (boxes.contains(position)) return finish(SightHit.box);
        if (vineCells.contains(position)) return finish(SightHit.vine);
        if (ghosts.contains(position)) return finish(SightHit.ghost);
      }
      if (v >= 0 && elevated(i) == elevated(v)) return finish(v == i ? SightHit.loop : SightHit.creature, v == i ? -1 : v);
      if (mirrors.containsKey(position) || rotors.containsKey(position)) {
        final slash = mirrors[position] ?? rotors[position]!;
        d = (slash ? const [1, 0, 3, 2] : const [3, 2, 1, 0])[d];
      } else if (portals.containsKey(position)) {
        final exit = portals.entries.firstWhere((p) => p.key != position && p.value == portals[position]).key;
        x = exit % w;
        y = exit ~/ w;
        route.add(SightPoint(x, y, warp: true));
      }
      free++;
    }
  }

  /// All mutually-gazing pairs among alive creatures, as [i, j] with i < j.
  /// Under [EyeRules.noTriangle] a friend gazed at by two or more friends of
  /// its own layer cannot match, even with a partner looking back.
  List<List<int>> pairs() {
    final g = grid();
    final sights = <int, Sight>{};
    final gazers = <int, int>{};
    for (var i = 0; i < cr.length; i++) {
      if (!cr[i].alive) continue;
      final s = sights[i] = sight(i, g);
      if (s.hit == SightHit.creature) gazers.update(s.target, (n) => n + 1, ifAbsent: () => 1);
    }
    final out = <List<int>>[];
    for (final MapEntry(key: i, value: s) in sights.entries) {
      if (s.hit != SightHit.creature) continue;
      final j = s.target;
      if (j <= i || cr[j].d != (s.direction + 2) % 4 || sights[j]?.target != i) continue;
      if (rules.noTriangle && ((gazers[i] ?? 0) > 1 || (gazers[j] ?? 0) > 1)) continue;
      out.add([i, j]);
    }
    return out;
  }

  /// Performs a manual action and resolves chains.
  /// Returns the removed pairs per round (empty when nothing vanished).
  List<List<List<int>>> tap(int i) {
    return [for (final round in tapDetailed(i)) round.pairs];
  }


  void refreshLamps() {
    // Nothing can light or go dark without a lamp; this runs on every chain
    // round, so the common lampless board skips the sight scan.
    if (lamps.isEmpty && litColors.isEmpty) return;
    final previous = Set<int>.of(litColors);
    litColors.clear();
    while (true) {
      final before = litColors.length;
      final g = grid();
      for (var i = 0; i < cr.length; i++) {
        if (!cr[i].alive || elevated(i)) continue;
        final ray = sight(i, g);
        if (ray.hit == SightHit.lamp) {
          final end = ray.route.last;
          litColors.add(lamps[end.y * w + end.x]!);
        }
      }
      if (before == litColors.length) break;
    }
    for (final color in previous.union(litColors)) {
      if (previous.contains(color) != litColors.contains(color)) {
        events.add(BoardEvent('lamp', color, litColors.contains(color) ? 1 : 0));
      }
    }
  }

  int? horseLanding(int i) {
    final c = cr[i], p = cPosition(i);
    final forward = step(p, c.d, 2);
    if (forward == null) return null;
    final landing = step(forward, (c.d + 1) % 4);
    return landing != null && emptyLanding(landing) ? landing : null;
  }

  int cPosition(int i) => cr[i].y * w + cr[i].x;

  /// Orthogonal neighbors; adjacency effects ignore layers.
  bool _adjacent(int a, int b) => (a % w - b % w).abs() + (a ~/ w - b ~/ w).abs() == 1;

  int? frogLanding(int i) {
    final c = cr[i];
    final front = step(cPosition(i), c.d);
    if (front == null || rocks.contains(front)) return null;
    if (emptyLanding(front)) return front;
    final sameFriend = cr.asMap().entries.any((e) => e.value.alive &&
        cPosition(e.key) == front && elevated(i) == elevated(e.key));
    final groundObstacle = !hills.contains(front) && terrainAt(front);
    if (!sameFriend && !groundObstacle) return null;
    final landing = step(front, c.d);
    return landing != null && emptyLanding(landing) ? landing : null;
  }

  bool canAct(int i) {
    if (i < 0 || i >= actionCount || won || failed) return false;
    if (i >= cr.length) return true;
    if (!cr[i].canTap) return false;
    final c = cr[i];
    if (c.kind == CreatureKind.beckoner) {
      final target = sight(i, grid()).target;
      return target >= 0 && cr[target].kind != CreatureKind.anchored;
    }
    if (c.kind != CreatureKind.hopper) return true;
    final next = step(cPosition(i), c.d);
    if (next == null || (!elevated(i) && hills.contains(next))) return false;
    if (boxes.contains(next)) {
      final destination = step(next, c.d);
      return destination != null && emptyLanding(destination, groundOnly: true);
    }
    return emptyLanding(next);
  }

  /// Next ghost cell, with the exact surveillance and tie breaking used by play.
  int ghostNext(int origin) {
    final g = grid();
    for (var i = 0; i < cr.length; i++) {
      if (!cr[i].alive || elevated(i)) continue;
      final ray = sight(i, g);
      if (ray.hit == SightHit.ghost && ray.route.last.y * w + ray.route.last.x == origin) return origin;
    }
    final targets = [for (var i=0;i<cr.length;i++) if (cr[i].alive && !elevated(i)) i];
    int distance(int i) => (cr[i].x-origin%w).abs()+(cr[i].y-origin~/w).abs();
    targets.sort((a,b) {
      final delta=distance(a).compareTo(distance(b));
      return delta != 0 ? delta : cPosition(a).compareTo(cPosition(b));
    });
    if (targets.isEmpty) return origin;
    final target=cr[targets.first];
    final dx=target.x-origin%w, dy=target.y-origin~/w;
    final d=dy.abs()>=dx.abs() ? (dy<0 ? 0:2) : (dx<0 ? 3:1);
    var next=step(origin,d);
    while (next != null) {
      if (ghosts.contains(next)) return origin;
      if (!hills.contains(next) && !terrainAt(next)) return next;
      next=step(next,d);
    }
    return origin;
  }

  /// Source positions are captured before any removal effect is applied.
  List<MatchRound> tapDetailed(int i, {bool captureFrames = false}) {
    events.clear();
    frames.clear();
    if (!canAct(i)) return [];
    final touched = <int>{}, jumped = <int>{};
    final rounds = <MatchRound>[];
    var eventCursor = 0;
    void capture([MatchRound? round]) {
      if (!captureFrames) return;
      frames.add(BoardFrame(clone(), List.of(events.skip(eventCursor)), round));
      eventCursor = events.length;
    }
    void move(int actor, int destination, String kind) {
      final from=cPosition(actor);
      cr[actor].x=destination%w; cr[actor].y=destination~/w;
      touched.add(actor);
      events.add(BoardEvent(kind,from,destination,actor:actor));
    }
    void turn(Set<int> actors, {Map<int,int>? output}) {
      if (actors.any((j)=>cr[j].kind==CreatureKind.linked)) {
        actors.addAll([for(var j=0;j<cr.length;j++) if(cr[j].alive && cr[j].kind==CreatureKind.linked) j]);
      }
      for(final j in actors) {
        if(!cr[j].alive || cr[j].kind==CreatureKind.anchored) continue;
        cr[j].d=(cr[j].d+1)%4;
        touched.add(j); output?[j]=cr[j].d;
        events.add(BoardEvent('turn',cPosition(j),cr[j].d,actor:j));
      }
    }
    if(i>=cr.length) {
      final cell=actionCell(i); rotors[cell]=!rotors[cell]!;
    } else if(cr[i].kind==CreatureKind.hopper) {
      final next=step(cPosition(i),cr[i].d)!;
      if(boxes.remove(next)) {
        final destination=step(next,cr[i].d)!;
        boxes.add(destination); events.add(BoardEvent('box',next,destination));
      }
      move(i,next,'hop');
    } else if(cr[i].kind==CreatureKind.beckoner) {
      turn({sight(i,grid()).target});
    } else {
      turn({i});
      // D: the tapped friend turned itself, so its neighbors turn with it.
      // A linked tap turns its group instead and leaves neighbors alone.
      if(rules.tapTurnsNeighbors && cr[i].kind!=CreatureKind.linked) {
        final origin=cPosition(i);
        turn({for(var j=0;j<cr.length;j++) if(j!=i && cr[j].alive && _adjacent(cPosition(j),origin)) j});
      }
    }
    for(final p in gates.keys.toList()) { gates[p]=!gates[p]!; }
    capture();

    void chains() {
      while(!failed) {
        refreshLamps();
        final matching=pairs(), occupancy=grid();
        final paired=matching.expand((p)=>p).toSet();
        final frogs=<int>{};
        final anyFrog=cr.any((c)=>c.alive && c.kind==CreatureKind.frog);
        for(var j=0;anyFrog && j<cr.length;j++) {
          if(!cr[j].alive) continue;
          final target=sight(j,occupancy).target;
          if(target>=0 && cr[target].kind==CreatureKind.frog &&
              !paired.contains(target) && !jumped.contains(target) && frogLanding(target)!=null) frogs.add(target);
        }
        if(matching.isEmpty && frogs.isEmpty) break;
        final positions=[for(var j=0;j<cr.length;j++) cPosition(j)];
        final routes=[for(final p in matching) sight(p.first,occupancy).route];
        final removed=<int>{}, fed=<int>{};
        for(final pair in matching) {
          final a=pair[0],b=pair[1];
          final hungryA=cr[a].kind==CreatureKind.eater, hungryB=cr[b].kind==CreatureKind.eater;
          if(hungryA!=hungryB) {
            final eater=hungryA?a:b; fed.add(eater); cr[eater].kind=CreatureKind.sated;
            removed.add(hungryA?b:a);
          } else { removed.addAll(pair); }
        }
        for(final route in routes) {
          for(final p in route) {
            final cell=p.y*w+p.x;
            if(candies.remove(cell)) events.add(BoardEvent('candy',cell,cell));
          }
        }
        for(final j in removed) { cr[j].alive=false; }
        final adjacent=_adjacent;
        final broken=crumbs.where((p)=>removed.any((j)=>adjacent(p,positions[j]))).toSet();
        final horses=[for(var j=0;j<cr.length;j++) if(cr[j].alive && cr[j].kind==CreatureKind.horse &&
          removed.any((k)=>adjacent(positions[j],positions[k]))) j]
          ..sort((a,b)=>positions[a].compareTo(positions[b]));
        // Without C only sparks signal, and repeated signals merge into one
        // clockwise turn. With C every removal signals; quarter turns are
        // summed per friend (spark -1, others +1), and the linked group counts
        // each removed source once.
        final signals=<int>{};
        final quarters=<int,int>{};
        final groupSources=<int,int>{};
        for(final j in removed) {
          final amount=cr[j].kind==CreatureKind.spark?-1:1;
          if(!rules.removalTurnsNeighbors && amount==1) continue;
          for(var k=0;k<cr.length;k++) {
            if(!cr[k].alive || cr[k].kind==CreatureKind.anchored || !adjacent(positions[j],positions[k])) continue;
            if(!rules.removalTurnsNeighbors) {
              signals.add(k);
            } else if(cr[k].kind==CreatureKind.linked) {
              groupSources[j]=amount;
            } else {
              quarters.update(k,(n)=>n+amount,ifAbsent:()=>amount);
            }
          }
        }
        final groupTurn=groupSources.values.fold(0,(a,b)=>a+b);
        if(groupTurn!=0) {
          for(var k=0;k<cr.length;k++) {
            if(cr[k].alive && cr[k].kind==CreatureKind.linked) quarters[k]=groupTurn;
          }
        }
        crumbs.removeAll(broken);
        for(final v in vines) {
          for(var n=0;n<=v.length;n++) {
            final cell=step(v.root,v.direction,n)!;
            if(removed.any((j)=>adjacent(cell,positions[j]))) {
              events.add(BoardEvent('vineCut',cell,step(v.root,v.direction,v.length)!));
              v.length=n==0?0:n-1; break;
            }
          }
        }
        for(final j in horses) {
          final landing=horseLanding(j);
          if(landing!=null) move(j,landing,'horse');
        }
        final turned=<int,int>{};
        turn(signals,output:turned);
        for(final MapEntry(key:k,value:q) in quarters.entries) {
          // A net of zero is no turn at all, so an Impatient counter keeps going.
          final steps=q%4;
          if(steps==0 || !cr[k].alive) continue;
          cr[k].d=(cr[k].d+steps)%4;
          touched.add(k); turned[k]=cr[k].d;
          events.add(BoardEvent('turn',cPosition(k),cr[k].d,actor:k));
        }
        final orderedFrogs=frogs.toList()..sort((a,b)=>positions[a].compareTo(positions[b]));
        for(final j in orderedFrogs) {
          if(!cr[j].alive) continue;
          final landing=frogLanding(j);
          if(landing!=null) { jumped.add(j); move(j,landing,'frog'); }
        }
        final round=MatchRound(matching,broken,turned,removed:removed,fed:fed,routes:routes);
        rounds.add(round);
        capture(round);
      }
    }
    chains();
    for(var j=0;j<cr.length;j++) {
      final c=cr[j];
      if(!c.alive || c.kind!=CreatureKind.impatient) continue;
      c.remaining=touched.contains(j)?c.patience:c.remaining-1;
      if(c.remaining==0) c.kind=CreatureKind.anchored;
      events.add(BoardEvent('patience',cPosition(j),c.remaining,actor:j));
    }
    for(final v in vines) {
      final next=step(v.root,v.direction,v.length+1);
      if(v.length<v.maxLength && next!=null && emptyLanding(next,groundOnly:true)) {
        v.length++; events.add(BoardEvent('vineGrow',v.root,next));
      }
    }
    // Surveillance sees the grown vines and the current fixed-point doors.
    refreshLamps();
    for(final origin in ghosts.toList()..sort()) {
      final next=ghostNext(origin);
      ghosts.remove(origin); ghosts.add(next);
      if(next!=origin) events.add(BoardEvent('ghost',origin,next));
      for(var j=0;j<cr.length;j++) {
        if(cr[j].alive && !elevated(j) && cPosition(j)==next) {
          cr[j].alive=false; failed=true;
          events.add(BoardEvent('failure',next,next,actor:j));
        }
      }
      if(failed) break;
    }
    capture();
    // Only vines and ghosts change sight lines after the action. Without them
    // the first chain pass already reached a fixed point.
    if(!failed && (vines.isNotEmpty || ghosts.isNotEmpty)) chains();
    capture();
    return rounds;
  }

}

class SolveResult {
  const SolveResult(this.par, this.path);
  final int par;
  final List<int> path;
}

enum SearchStatus { solved, exhausted, depthLimit, stateLimit, timeLimit }

class SearchResult {
  const SearchResult(this.status, this.path, this.explored);
  final SearchStatus status;
  final List<int> path;
  final int explored;

  /// Only a completed BFS solution proves the minimum number of taps.
  bool get optimal => status == SearchStatus.solved;
  int? get par => optimal ? path.length : null;
}

/// The single breadth-first search used by content certification and live
/// hints. It executes [EyeBoard.tapDetailed], including terrain actions. A
/// budget interruption never means that a board is unsolvable or optimal.
SearchResult searchBoard(EyeBoard start, {
  int maxDepth = 40,
  int maxStates = 600000,
  Duration? timeLimit,
  bool collectAllCandies = true,
}) {
  if (maxDepth < 0) throw ArgumentError.value(maxDepth, 'maxDepth');
  if (maxStates < 1) throw ArgumentError.value(maxStates, 'maxStates');
  if (timeLimit != null && timeLimit.isNegative) {
    throw ArgumentError.value(timeLimit, 'timeLimit');
  }
  if (start.won && (!collectAllCandies || start.candies.isEmpty)) return const SearchResult(SearchStatus.solved, [], 1);
  final timer = Stopwatch()..start();
  final seen = <String>{start.key};
  final parents = <(int, int)>[(-1, -1)];
  final queue = ListQueue<(EyeBoard, int, int)>()..add((start, 0, 0));
  var touchedDepthLimit = false;
  while (queue.isNotEmpty) {
    if (timeLimit != null && timer.elapsed >= timeLimit) {
      return SearchResult(SearchStatus.timeLimit, const [], seen.length);
    }
    final (board, parent, depth) = queue.removeFirst();
    if (depth >= maxDepth) {
      touchedDepthLimit = true;
      continue;
    }
    var actedLinked = false;
    for (var move = 0; move < board.actionCount; move++) {
      if (!board.canAct(move)) continue;
      if (move < board.cr.length && board.cr[move].kind == CreatureKind.linked) {
        // Every alive member produces the same state, so one is enough for
        // search. They remain independently tappable in the game interface.
        if (actedLinked) continue;
        actedLinked = true;
      }
      final next = board.clone()..tapDetailed(move);
      if (next.failed || (next.won && collectAllCandies && next.candies.isNotEmpty)) continue;
      final key = next.key;
      if (seen.contains(key)) continue;
      if (seen.length >= maxStates) {
        return SearchResult(SearchStatus.stateLimit, const [], seen.length);
      }
      seen.add(key);
      final index = parents.length;
      parents.add((parent, move));
      if (next.won) {
        final reversed = <int>[];
        var current = index;
        while (parents[current].$1 >= 0) {
          reversed.add(parents[current].$2);
          current = parents[current].$1;
        }
        return SearchResult(SearchStatus.solved, reversed.reversed.toList(), seen.length);
      }
      queue.add((next, index, depth + 1));
    }
  }
  return SearchResult(touchedDepthLimit ? SearchStatus.depthLimit : SearchStatus.exhausted,
      const [], seen.length);
}

/// Compatibility helper for callers that only need a certified solution.
/// A null result is inconclusive; use [searchBoard] to distinguish budgets
/// from an exhaustive proof that no solution exists.
SolveResult? solve(EyeBoard start, {int maxDepth = 18, int maxStates = 600000}) {
  final result = searchBoard(start, maxDepth: maxDepth, maxStates: maxStates);
  return result.optimal ? SolveResult(result.path.length, result.path) : null;
}

/// Isolate-friendly entry point: takes [EyeBoard.encode] output,
/// returns [par, ...path] or an empty list when no solution was certified.
/// Live UI must use [solveEncodedDetailed] so limits are not shown as failure.
List<int> solveEncoded(List<int> encoded) {
  final r = solve(EyeBoard.decode(encoded));
  if (r == null) return const [];
  return [r.par, ...r.path];
}

/// Isolate-safe, explicitly bounded hint request. No hint is charged and no
/// stuck warning should be shown for any of the three limit statuses.
Map<String, Object> solveEncodedDetailed(List<int> encoded) {
  final result = searchBoard(EyeBoard.decode(encoded),
      timeLimit: const Duration(seconds: 5));
  return {
    'status': result.status.name,
    'path': result.path,
    'explored': result.explored,
    'optimal': result.optimal,
    if (result.optimal) 'par': result.path.length,
  };
}
