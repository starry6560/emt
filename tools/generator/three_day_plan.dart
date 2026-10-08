import 'package:emt/game/eye_logic.dart';

import 'campaign_plan.dart';

/// Five independent puzzles; four GEN_ATTEMPT seeds are generated per profile.
class ThreeDayProfile {
  const ThreeDayProfile(this.number, this.specials, this.obstacle, this.floor,
      this.titleKo, this.titleEn, this.tipKo, this.tipEn);

  final int number;
  final Set<String> specials;
  final String obstacle;
  final int floor;
  final String titleKo, titleEn, tipKo, tipEn;

  RoundSpec get spec => RoundSpec(
    round: number,
    introduces: null,
    elements: {'rock', 'candy', obstacle, ...specials},
    // The Eater puzzle may award its candy along an already-required match.
    // Its certificate must still collect it; candy need not create a detour.
    required: {'rock', if (number != 3) 'candy', obstacle, ...specials},
    rules: const EyeRules(noTriangle: true),
    tapFloor: floor,
    slack: 2,
    minFirstChoices: 5,
    maxCorrectShare: 0.5,
    minDeadEndRatio: 0.25,
    trapRequired: false,
    decoyCap: number == 3 ? 1 : 0,
    maxWidth: 6,
    maxHeight: 6,
  );
}

const threeDayProfiles = [
  ThreeDayProfile(1, {'anchored', 'linked'}, 'mirror', 8,
      '거울 속 약속', 'Mirror Promise',
      '링크가 함께 돌아요. 거울 너머의 짝을 찾아보세요.',
      'Links turn together. Find a match through the mirror.'),
  ThreeDayProfile(2, {'beckoner', 'hopper'}, 'box', 8,
      '길을 열어줘', 'Clear the Way',
      '호퍼로 상자를 밀고 컨덕터로 방향을 바꿔보세요.',
      'Push a box with the Hopper, then change its direction with the Conductor.'),
  ThreeDayProfile(3, {'anchored', 'eater'}, 'cookie', 9,
      '한 입의 순서', 'One Bite at a Time',
      '이터가 먹을 짝과 쿠키벽을 깨는 순서를 정해보세요.',
      'Choose the Eater\'s first match and when to break the cookie wall.'),
  ThreeDayProfile(4, {'anchored', 'beckoner'}, 'portal', 9,
      '멀리서 건네는 손짓', 'A Wave from Afar',
      '웜홀 너머로 컨덕터의 손짓을 전해보세요.',
      'Send the Conductor\'s turn through a wormhole.'),
  ThreeDayProfile(5, {'linked', 'beckoner'}, 'rotor', 10,
      '함께 돌리는 시선', 'Turning Together',
      '링크와 컨덕터, 회전 거울의 조작 순서를 찾아보세요.',
      'Find the order for the Links, Conductor, and pivot mirror.'),
];
