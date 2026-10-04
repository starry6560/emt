// Difficulty metrics from the spec 4-2, measured by exhaustive
// search. A budget cutoff is reported as unknown, never as a pass.
import 'dart:math' as math;

import 'package:emt/game/eye_logic.dart';
import 'quality.dart';
import 'renewal.dart';

class Difficulty {
  Difficulty({required this.status, required this.states, this.par, this.solution = const [],
    this.shortestCount, this.firstActions, this.orderFreedom, this.greedyTrap,
    this.legalFirst = 0, this.deadFirst = 0, this.unknownFirst = 0, this.lethalFirst = 0,
    this.maxChain = 0, this.present = const {}, this.active = const {}, this.unprovenElements = const {}});

  /// `solved` when a shortest solution within the tap limit was certified.
  final String status;
  final int states;
  final int? par;
  final List<int> solution;
  final double? shortestCount;
  /// Distinct first actions that start some shortest solution.
  final int? firstActions;
  /// Shortest solutions divided by the orderings of one solution's taps.
  final double? orderFreedom;
  /// Matching every visible pair first cannot clear within the limit.
  /// Null when the greedy search ran out of budget.
  final bool? greedyTrap;
  final int legalFirst, deadFirst, unknownFirst, lethalFirst;
  final int maxChain;
  final Set<String> present, active, unprovenElements;

  bool get solved => status == 'solved';

  /// This measurement with the element activity filled in.
  Difficulty withElements(Set<String> present, Set<String> active, Set<String> unproven) =>
      Difficulty(status: status, states: states, par: par, solution: solution,
          shortestCount: shortestCount, firstActions: firstActions, orderFreedom: orderFreedom,
          greedyTrap: greedyTrap, legalFirst: legalFirst, deadFirst: deadFirst,
          unknownFirst: unknownFirst, lethalFirst: lethalFirst, maxChain: maxChain,
          present: present, active: active, unprovenElements: unproven);
  /// Share of legal first actions that start a shortest solution.
  double? get correctShare => legalFirst == 0 || firstActions == null ? null : firstActions! / legalFirst;
  /// Share of legal first actions after which the limit can no longer be met.
  double? get deadEndRatio => legalFirst == 0 || unknownFirst > 0 ? null : deadFirst / legalFirst;
  /// Elements on the board that do not work in the solution (spec 5).
  Set<String> get decoys => present.difference(active).difference(unprovenElements);
  /// A ghost board whose every legal first action is immediately fatal.
  bool get allFirstLethal => legalFirst > 0 && lethalFirst == legalFirst;

  Map<String, Object?> toJson() => {
    'status': status, 'states': states, 'par': par,
    'shortestCount': shortestCount, 'firstActions': firstActions,
    'orderFreedom': orderFreedom == null ? null : (orderFreedom! * 10000).round() / 10000,
    'greedyTrap': greedyTrap,
    'legalFirst': legalFirst, 'deadFirst': deadFirst, 'unknownFirst': unknownFirst,
    'correctShare': correctShare == null ? null : (correctShare! * 1000).round() / 1000,
    'deadEndRatio': deadEndRatio == null ? null : (deadEndRatio! * 1000).round() / 1000,
    'lethalFirst': lethalFirst, 'maxChain': maxChain,
    'active': active.toList()..sort(), 'decoys': decoys.toList()..sort(),
    'unprovenElements': unprovenElements.toList()..sort(),
  };
}

/// Every state reachable within [maxDepth] taps, with each state's distance
/// to a win. One exploration answers the target, the first actions, the
/// solution count and every dead end (spec 4-2).
class StateGraph {
  StateGraph._(this.status, this.ids, this.children, this.distance);
  /// `complete` when every state within the depth was expanded.
  final String status;
  final Map<String, int> ids;
  /// (child id, action) per distinct child; failures and candy-short wins
  /// are dead ends and have no node.
  final List<List<(int, int)>> children;
  /// Taps to a win, or null when no win is reachable inside the graph.
  final List<int?> distance;
  bool get complete => status == 'complete';
  int get states => ids.length;
  int? get par => complete ? distance[0] : null;
}

StateGraph exploreGraph(EyeBoard start, int maxDepth, {int maxStates = 400000, Duration? budget}) {
  final timer = Stopwatch()..start();
  final ids = <String, int>{start.key: 0};
  final children = <List<(int, int)>>[[]];
  final wins = <int>[];
  if (start.won && start.candies.isEmpty) wins.add(0);
  var layer = wins.isEmpty ? [(0, start)] : <(int, EyeBoard)>[];
  String status = 'complete';
  for (var depth = 0; depth < maxDepth && layer.isNotEmpty; depth++) {
    final next = <(int, EyeBoard)>[];
    for (final (id, board) in layer) {
      var actedLinked = false;
      for (var move = 0; move < board.actionCount; move++) {
        if (!board.canAct(move)) continue;
        if (move < board.cr.length && board.cr[move].kind == CreatureKind.linked) {
          if (actedLinked) continue;
          actedLinked = true;
        }
        final child = board.clone()..tapDetailed(move);
        if (child.failed || (child.won && child.candies.isNotEmpty)) continue;
        final key = child.key;
        var childId = ids[key];
        if (childId == null) {
          if (ids.length >= maxStates) { status = 'stateLimit'; break; }
          childId = ids[key] = children.length;
          children.add([]);
          if (child.won) {
            wins.add(childId);
          } else {
            next.add((childId, child));
          }
        }
        final edges = children[id];
        if (!edges.any((e) => e.$1 == childId)) edges.add((childId, move));
      }
      if (status != 'complete') break;
      if (budget != null && timer.elapsed >= budget) { status = 'timeLimit'; break; }
    }
    if (status != 'complete') break;
    layer = next;
  }
  // Distances to a win over the reversed edges.
  final parents = List.generate(children.length, (_) => <int>[]);
  for (var id = 0; id < children.length; id++) {
    for (final (child, _) in children[id]) { parents[child].add(id); }
  }
  final distance = List<int?>.filled(children.length, null);
  final queue = <int>[];
  for (final w in wins) { distance[w] = 0; queue.add(w); }
  for (var head = 0; head < queue.length; head++) {
    final node = queue[head];
    for (final parent in parents[node]) {
      if (distance[parent] == null) { distance[parent] = distance[node]! + 1; queue.add(parent); }
    }
  }
  return StateGraph._(status, ids, children, distance);
}

/// Measures [board] against a tap [limit].
Difficulty measureDifficulty(EyeBoard board, {required int limit,
    int maxStates = 400000, Duration? budget, bool elements = true}) =>
    measureFromGraph(board, exploreGraph(board, limit, maxStates: maxStates, budget: budget),
        limit, maxStates: maxStates, budget: budget, elements: elements);

/// Measures [board] from a graph explored at least [limit] taps deep.
Difficulty measureFromGraph(EyeBoard board, StateGraph graph, int limit,
    {int maxStates = 400000, Duration? budget, bool elements = true}) {
  if (!graph.complete) return Difficulty(status: graph.status, states: graph.states);
  final par = graph.distance[0];
  if (par == null || par > limit) return Difficulty(status: 'unsolved', states: graph.states);
  final distance = graph.distance;

  // Shortest solutions follow edges that bring the win one tap closer.
  final ways = List<double?>.filled(distance.length, null);
  double count(int node) {
    if (distance[node] == 0) return 1;
    final known = ways[node];
    if (known != null) return known;
    var total = 0.0;
    for (final (child, _) in graph.children[node]) {
      if (distance[child] == distance[node]! - 1) total += count(child);
    }
    return ways[node] = total;
  }
  final shortest = count(0);
  final onPath = [for (final (child, action) in graph.children[0]) if (distance[child] == par - 1) (child, action)];
  final solution = <int>[];
  for (var node = 0; distance[node]! > 0;) {
    final (child, action) = graph.children[node].firstWhere((e) => distance[e.$1] == distance[node]! - 1);
    solution.add(action);
    node = child;
  }

  double logFactorial(int n) {
    var sum = 0.0;
    for (var i = 2; i <= n; i++) { sum += math.log(i); }
    return sum;
  }
  final taps = <int, int>{};
  for (final action in solution) { taps[action] = (taps[action] ?? 0) + 1; }
  var logOrderings = logFactorial(par);
  for (final n in taps.values) { logOrderings -= logFactorial(n); }
  final freedom = math.exp(math.log(shortest) - logOrderings);

  // Every legal first action, linked twins included. A child the graph does
  // not hold failed, or won with candy left.
  var legal = 0, dead = 0, lethal = 0;
  for (var a = 0; a < board.actionCount; a++) {
    if (!board.canAct(a)) continue;
    legal++;
    final child = board.clone()..tapDetailed(a);
    if (child.failed) lethal++;
    final id = graph.ids[child.key];
    final rest = id == null ? null : distance[id];
    if (rest == null || rest > limit - 1) dead++;
  }

  var maxChain = 0;
  final replay = board.clone();
  for (final action in solution) { maxChain = math.max(maxChain, replay.tapDetailed(action).length); }

  final measured = Difficulty(status: 'solved', states: graph.states, par: par, solution: solution,
      shortestCount: shortest, firstActions: onPath.length, orderFreedom: freedom,
      greedyTrap: _greedyTrap(board, limit, maxStates, budget),
      legalFirst: legal, deadFirst: dead, unknownFirst: 0, lethalFirst: lethal, maxChain: maxChain);
  return elements ? measureElements(board, measured, maxStates: maxStates, budget: budget) : measured;
}

/// Adds element activity (the costliest part: two searches per element) to
/// a solved measurement, so a generator can run it only on finalists.
Difficulty measureElements(EyeBoard board, Difficulty d, {int maxStates = 400000, Duration? budget}) {
  final present = mechanics(board)..remove('rock');
  final active = <String>{}, unproven = <String>{};
  for (final rule in present) {
    final evidence = ruleEvidence(board, d.par!, rule, maxStates: maxStates, budget: budget);
    if (evidence == null) {
      unproven.add(rule);
    } else if (evidence >= activeEvidence) {
      active.add(rule);
    }
  }
  return d.withElements(present, active, unproven);
}

/// A player who always takes a visible match when one exists, and otherwise
/// tries every move. True when that cannot clear within [limit].
bool? _greedyTrap(EyeBoard start, int limit, int maxStates, Duration? budget) {
  var layer = [start];
  final seen = <String>{start.key};
  final timer = Stopwatch()..start();
  for (var depth = 1; depth <= limit && layer.isNotEmpty; depth++) {
    final next = <EyeBoard>[];
    for (final board in layer) {
      final quiet = <EyeBoard>[], matching = <EyeBoard>[];
      for (var move = 0; move < board.actionCount; move++) {
        if (!board.canAct(move)) continue;
        if (budget != null && timer.elapsed >= budget) return null;
        final child = board.clone();
        (child.tapDetailed(move).every((wave) => wave.removed.isEmpty) ? quiet : matching).add(child);
      }
      for (final child in matching.isNotEmpty ? matching : quiet) {
        if (child.failed || (child.won && child.candies.isNotEmpty)) continue;
        if (child.won) return false;
        if (!seen.add(child.key)) continue;
        if (seen.length >= maxStates) return null;
        next.add(child);
      }
    }
    layer = next;
  }
  return true;
}
