// Splits rounds across machines for the generator workflow. Rounds are dealt
// out in turn, so every machine gets early and late (slower) rounds alike.
//   dart tools/split_rounds.dart "1-300" 20   -> JSON list of round lists
import 'dart:convert';

import 'generate_campaign.dart' show parseRounds;

void main(List<String> args) {
  final rounds = parseRounds(args.first.split(RegExp(r'[\s,]+')).where((s) => s.isNotEmpty).toList());
  final machines = int.parse(args[1]).clamp(1, 20);
  final chunks = List.generate(machines, (_) => <int>[]);
  for (var i = 0; i < rounds.length; i++) { chunks[i % machines].add(rounds[i]); }
  print(jsonEncode([for (final c in chunks) if (c.isNotEmpty) c.join(' ')]));
}
