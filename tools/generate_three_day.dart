// Run directly for profile 1, seed 0. GitHub's matrix sets DAILY_PROFILE and
// GEN_ATTEMPT to produce five profiles with four independent seeds each.
import 'dart:convert';
import 'dart:io';

import 'package:emt/game/eye_logic.dart';

import 'generate_campaign.dart' as campaign;
import 'generator/quality.dart';
import 'generator/renewal.dart';
import 'generator/three_day_plan.dart';

const outputDirectory = 'tools/generated/three_day';
const minimumCreatures = 8;
const maximumCreatures = 10;

class ThreeDayGenerator extends campaign.RoundGenerator {
  ThreeDayGenerator(this.profile) : super(profile.spec);
  final ThreeDayProfile profile;

  @override
  int get creatureCap => maximumCreatures;

  @override
  EyeBoard initialBoard() {
    while (true) {
      var board = super.initialBoard();
      var tries = 0;
      while (board.cr.length < minimumCreatures && tries++ < 30) {
        addPair(board);
      }
      if (board.cr.length < minimumCreatures) continue;
      // Each hungry Eater removes one extra friend before its final pair.
      // With an even initial population, an odd Eater count cannot clear.
      if (profile.specials.contains('eater') &&
          board.cr.where((c) => c.kind == CreatureKind.eater).length.isOdd &&
          !place(board, 'eater')) continue;
      board = boardFromData(boardData(board));
      unpair(board);
      return board;
    }
  }

  @override
  campaign.Evaluation evaluate(EyeBoard board) {
    final types = {for (final c in board.cr) kindName(c.kind)};
    final requiredTypes = {'normal', ...profile.specials};
    final reasons = <String>[
      if (board.cr.length < minimumCreatures || board.cr.length > maximumCreatures)
        'creature_count',
      if (types.length != 3 || !types.containsAll(requiredTypes)) 'creature_types',
      if (board.cr.where((c) => c.kind == CreatureKind.eater).length.isOdd) 'eater_parity',
      if (profile.specials.contains('linked') &&
          board.cr.where((c) => c.kind == CreatureKind.linked).length < 2) 'link_group_size',
      if (board.candies.isEmpty || board.candies.length > 2) 'candy_count',
      if (board.rocks.isEmpty || board.rocks.length > 4) 'rock_count',
      if (board.portals.length > 2 || board.mirrors.length > 2 ||
          board.rotors.length > 2 || board.boxes.length > 2 || board.crumbs.length > 3)
        'obstacle_count',
    ];
    if (reasons.isNotEmpty) return campaign.Evaluation(1e6, reasons: reasons);
    return super.evaluate(board);
  }
}

void main() {
  final number = int.tryParse(Platform.environment['DAILY_PROFILE'] ?? '') ?? 1;
  if (number < 1 || number > threeDayProfiles.length) {
    throw ArgumentError.value(number, 'DAILY_PROFILE', 'Expected 1 through 5');
  }
  final seed = campaign.attempt;
  if (seed < 0) throw ArgumentError.value(seed, 'GEN_ATTEMPT', 'Must be nonnegative');
  final profile = threeDayProfiles[number - 1];
  final result = ThreeDayGenerator(profile).run();
  final level = result['level'] as Map<String, Object?>?;
  if (level != null) {
    result['level'] = {
      ...level,
      'id': 'three-day-${number.toString().padLeft(3, '0')}',
      'kind': 'three_day',
      'title': profile.titleKo, 'titleEn': profile.titleEn,
      'tip': profile.tipKo, 'tipEn': profile.tipEn,
    };
  }
  result.addAll({
    'profile': number,
    'seed': seed,
    'contentRevision': 'three-day-20261008-v1',
    'scheduleTimeZone': 'Asia/Seoul',
    'opensAt': number == 1 ? '2026-10-08T00:00:00+09:00'
        : '2026-10-${(10 + (number - 2) * 3).toString().padLeft(2, '0')}T00:00:00+09:00',
    'closesAt': '2026-10-${(10 + (number - 1) * 3).toString().padLeft(2, '0')}T00:00:00+09:00',
    'selectionCriteria': {
      'minimumCreatures': minimumCreatures, 'maximumCreatures': maximumCreatures,
      'creatureTypes': ['normal', ...profile.specials],
      'requiredElements': profile.spec.required.toList()..sort(),
      'tapFloor': profile.floor,
    },
  });
  final directory = Directory(outputDirectory)..createSync(recursive: true);
  final file = File('${directory.path}/profile-$number-seed-$seed.json');
  file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(result));
  final metrics = result['metrics'] as Map?;
  stdout.writeln('profile=$number seed=$seed status=${result['status']} '
      'score=${result['score']} par=${level?['par']} '
      'seconds=${result['seconds']} evaluations=${result['evaluations']} '
      'correct=${metrics?['correctShare']} dead=${metrics?['deadEndRatio']} '
      'reasons=${result['reasons']} output=${file.path}');
}
