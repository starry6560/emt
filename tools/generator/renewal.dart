import 'dart:convert';
import 'dart:math';
import 'package:emt/game/eye_logic.dart';
import 'quality.dart';

const introductionRounds = <String,int>{
  'normal':1,'rock':6,'anchored':16,'cookie':26,'spark':38,'gate':51,
  'beckoner':63,'hopper':76,'candy':88,'eater':101,'impatient':113,
  'mirror':126,'lamp':134,'portal':142,'linked':151,'ghost':159,'vine':167,
  'hill':176,'horse':184,'frog':192,'box':201,'rotor':213,
};
const ruleFamilies = <String,Set<String>>{
  'rotation':{'beckoner','linked','spark','anchored'},
  'optics':{'mirror','rotor','portal','lamp','candy'},
  'movement':{'hopper','horse','frog','box','hill'},
  'time':{'gate','impatient','vine','ghost'},'parity':{'eater'},
};
const meaningfulPairs = [
  ['beckoner','hopper'],['ghost','anchored'],['lamp','gate'],['horse','hill'],
  ['frog','box'],['vine','spark'],['eater','hill'],
];
const renewalRules={'beckoner','impatient','horse','frog','hill','lamp','candy','vine','box','ghost'};

EyeBoard boardFromData(Map data) => EyeBoard.parse(List<String>.from(data['rows'] as List),
    heights:data['heights']==null?null:List<String>.from(data['heights'] as List),
    parameters:Map<String,dynamic>.from(data['parameters'] as Map? ?? const {}),
    rules:EyeRules.fromJson(data['rules']));

Map<String,Object> boardData(EyeBoard b) => {
  'encodingVersion':5,'rows':b.toRows(),
  'heights':[for(var y=0;y<b.h;y++) [for(var x=0;x<b.w;x++) b.hills.contains(y*b.w+x)?'^':'.'].join()],
  'parameters':{
    for(var i=0;i<b.cr.length;i++) if(b.cr[i].kind==CreatureKind.impatient)
      '${b.cPosition(i)}':{'patience':b.cr[i].patience},
    for(final e in b.lamps.entries) '${e.key}':{'color':e.value},
    for(final e in b.lampDoors.entries) '${e.key}':{'color':e.value},
    for(final v in b.vines) '${v.root}':{'direction':v.direction,'maxLength':v.maxLength},
  },
  if(b.rules!=EyeRules.none) 'rules':b.rules.toJson(),
};

/// Board-wide rule names (spec 1-3 to 1-5), as written in level files.
const boardRuleNames={'noTriangle','removalTurnsNeighbors','tapTurnsNeighbors'};

/// [start] with one element or one board-wide rule removed, for ablation.
EyeBoard withoutRule(EyeBoard start,String rule) {
  if(boardRuleNames.contains(rule)) {
    return boardFromData({...boardData(start),
      'rules':start.rules.toJson().where((name)=>name!=rule).toList()});
  }
  final b=start.clone();
  for(final c in b.cr) { if(kindName(c.kind)==rule) c.kind=CreatureKind.normal; }
  switch(rule) {
    case 'rock': b.rocks.clear();
    case 'cookie': b.crumbs.clear();
    case 'gate': b.gates.clear();
    case 'mirror': b.mirrors.clear();
    case 'portal': b.portals.clear();
    case 'rotor': b.rotors.clear();
    case 'hill': b.hills.clear();
    case 'box': b.boxes.clear();
    case 'candy': b.candies.clear();
    case 'ghost': b.ghosts.clear();
    case 'vine': b.vines.clear();
    case 'lamp': b.lamps.clear(); b.lampDoors.clear(); b.litColors.clear();
  }
  b.refreshLamps();
  return b;
}

class RenewalQuality {
  RenewalQuality(this.active,this.uncertain,this.reasons,this.metrics,this.ablations);
  final Set<String> active,uncertain;
  final List<String> reasons;
  final Map<String,Object?> metrics;
  final Map<String,Object?> ablations;
}

/// A rule whose removal keeps the minimum still works when at least this share
/// of one side's shortest solutions stops working: original solutions that
/// need the rule, or rule-free solutions that the rule blocks. Fixed at 20%
/// on 2026-10-04 (below it a player rarely meets the rule while solving);
/// do not tune it to change shortfall counts.
const activeEvidence=0.20;
const evidenceSamples=1000;

/// An interrupted search is unknown, never evidence that an element works.
RenewalQuality inspectRenewal(EyeBoard initial,List<int> path,{
    int maxStates=120000, Duration budget=const Duration(seconds:2)}) {
  final active=<String>{},uncertain=<String>{}, reasons=<String>[];
  final ablations=<String,Object?>{};
  final present=mechanics(initial)..remove('rock');
  final par=path.length;
  final random=Random(par);
  final original=shortestPaths(initial,par,maxStates:maxStates,timeLimit:budget);
  final originalPaths=original.paths(evidenceSamples,random);
  for(final rule in present.toList()..sort()) {
    final ablated=withoutRule(initial,rule);
    final result=shortestPaths(ablated,par,maxStates:maxStates,timeLimit:budget);
    final parChanged=(result.solved && result.par!=par) ||
        result.status==SearchStatus.exhausted || result.status==SearchStatus.depthLimit;
    double? needs,blocks;
    if(!parChanged && result.solved && original.solved) {
      needs=_notFinished(originalPaths,ablated);
      blocks=_notFinished(result.paths(evidenceSamples,random),initial);
    }
    final evidence=max(needs??0,blocks??0);
    final works=parChanged || evidence>=activeEvidence;
    if(works) {
      active.add(rule);
    } else if(!result.solved || !original.solved) {
      uncertain.add(rule);
    }
    ablations[rule]={'status':result.status.name,'par':result.par,'parChanged':parChanged,
      'paths':result.solved?result.total:null,'needs':needs,'blocks':blocks,'evidence':evidence,'active':works};
  }
  if(initial.cr.length/(initial.w*initial.h)>0.35) reasons.add('density');
  if(initial.w>8) reasons.add('width');
  if(active.length>5) reasons.add('more_than_five_rules');
  String names(Set<String> rules) => (rules.toList()..sort()).join(',');
  final inactive=present.difference(active).difference(uncertain).intersection(renewalRules);
  final unproven=uncertain.intersection(renewalRules);
  if(inactive.isNotEmpty) reasons.add('inactive:${names(inactive)}');
  if(unproven.isNotEmpty) reasons.add('unproven:${names(unproven)}');
  final b=initial.clone();
  var maxChain=0,setup=0,maxSetup=0,run=0;
  for(final action in path) {
    final waves=b.tapDetailed(action);
    if(waves.length>maxChain) maxChain=waves.length;
    if(waves.every((w)=>w.removed.isEmpty)) {setup++;run++;if(run>maxSetup)maxSetup=run;} else {run=0;}
  }
  final waits=waitingTaps(initial,path).length;
  if(maxChain>6) reasons.add('chain_over_six');
  if(path.isNotEmpty && waits/path.length>0.30) reasons.add('waiting_over_limit');
  var legal=0,lethal=0;
  for(var a=0;a<initial.actionCount;a++) {
    if(!initial.canAct(a)) continue;
    legal++;
    if((initial.clone()..tapDetailed(a)).failed) lethal++;
  }
  if(lethal*2>legal) reasons.add('lethal_first_actions');
  return RenewalQuality(active,uncertain,reasons,{
    'maxChain':maxChain,'setupMoves':setup,'longestSetupRun':maxSetup,
    'waitTaps':waits,'waitingRatio':path.isEmpty?0:waits/path.length,
    'legalFirstActions':legal,'lethalFirstActions':lethal,
    'friendDensity':initial.cr.length/(initial.w*initial.h),
    'shortestSolutionCount':original.solved?original.total:null,
  },ablations);
}

/// The [inspectRenewal] activity evidence for one rule, cheap enough for a
/// search loop: 1.0 when the minimum or solvability changes, otherwise the
/// larger of the needed and blocked shares. Null when a budget ran out.
double? ruleEvidence(EyeBoard initial,int par,String rule,{
    int maxStates=60000,Duration? budget,int samples=evidenceSamples}) {
  final ablated=withoutRule(initial,rule);
  final quick=searchBoard(ablated,maxDepth:par,maxStates:maxStates,timeLimit:budget);
  if(quick.status==SearchStatus.exhausted || quick.status==SearchStatus.depthLimit ||
      (quick.optimal && quick.path.length!=par)) return 1.0;
  if(!quick.optimal) return null;
  final original=shortestPaths(initial,par,maxStates:maxStates,timeLimit:budget);
  final result=shortestPaths(ablated,par,maxStates:maxStates,timeLimit:budget);
  if(!original.solved || !result.solved) return null;
  final random=Random(par);
  return max(_notFinished(original.paths(samples,random),ablated)??0,
      _notFinished(result.paths(samples,random),initial)??0);
}

double? _notFinished(List<List<int>> paths,EyeBoard on) => paths.isEmpty ? null :
    paths.where((p)=>!replayFinishes(on,p)).length/paths.length;

/// Every shortest solution as a layered DAG over distinct states. Two actions
/// reaching the same state from the same state count as one path.
class ShortestPaths {
  ShortestPaths(this.status,this.par,this.states,[this.edges=const [],this.counts=const [],this.wins=const []]);
  final SearchStatus status;
  final int? par;
  final int states;
  final List<List<(int,int)>> edges;
  final List<double> counts;
  final List<int> wins;
  bool get solved => status==SearchStatus.solved;
  double get total => wins.fold(0.0,(s,w)=>s+counts[w]);

  /// All paths when there are at most [n], otherwise [n] uniform samples.
  List<List<int>> paths(int n,Random random) {
    if(!solved) return const [];
    if(total<=n) {
      final out=<List<int>>[];
      void walk(int node,List<int> suffix) {
        if(node==0) {out.add(suffix.reversed.toList());return;}
        for(final (pred,action) in edges[node]) {walk(pred,[...suffix,action]);}
      }
      for(final w in wins) {walk(w,[]);}
      return out;
    }
    int pick(List<int> nodes) {
      var r=random.nextDouble()*nodes.fold(0.0,(s,x)=>s+counts[x]);
      for(final x in nodes) {r-=counts[x];if(r<=0)return x;}
      return nodes.last;
    }
    return [
      for(var i=0;i<n;i++) () {
        final reversed=<int>[];
        var node=pick(wins);
        while(node!=0) {
          final choices=edges[node];
          final pred=pick([for(final e in choices) e.$1]);
          reversed.add(choices.firstWhere((e)=>e.$1==pred).$2);
          node=pred;
        }
        return reversed.reversed.toList();
      }(),
    ];
  }
}

/// Same rules and statuses as [searchBoard], but finishes the winning layer
/// and counts every shortest path instead of stopping at the first.
ShortestPaths shortestPaths(EyeBoard start,int maxDepth,{int maxStates=400000,Duration? timeLimit}) {
  if(start.won && start.candies.isEmpty) return ShortestPaths(SearchStatus.solved,0,1,[[]],[1],[0]);
  final timer=Stopwatch()..start();
  final ids=<String,int>{start.key:0};
  final edges=<List<(int,int)>>[[]];
  final counts=<double>[1];
  var frontier=<(int,EyeBoard)>[(0,start)];
  for(var depth=0;depth<maxDepth;depth++) {
    final next=<(int,EyeBoard)>[];
    final firstNew=edges.length;
    for(final (id,board) in frontier) {
      var actedLinked=false;
      for(var move=0;move<board.actionCount;move++) {
        if(!board.canAct(move)) continue;
        if(move<board.cr.length && board.cr[move].kind==CreatureKind.linked) {
          if(actedLinked) continue;
          actedLinked=true;
        }
        final b=board.clone()..tapDetailed(move);
        if(b.failed || (b.won && b.candies.isNotEmpty)) continue;
        final key=b.key;
        final known=ids[key];
        if(known==null) {
          if(ids.length>=maxStates) return ShortestPaths(SearchStatus.stateLimit,null,ids.length);
          ids[key]=edges.length;
          edges.add([(id,move)]);
          counts.add(counts[id]);
          next.add((edges.length-1,b));
        } else if(known>=firstNew && edges[known].last.$1!=id) {
          edges[known].add((id,move));
          counts[known]+=counts[id];
        }
      }
      if(timeLimit!=null && timer.elapsed>=timeLimit) return ShortestPaths(SearchStatus.timeLimit,null,ids.length);
    }
    final wins=[for(final (id,b) in next) if(b.won) id];
    if(wins.isNotEmpty) return ShortestPaths(SearchStatus.solved,depth+1,ids.length,edges,counts,wins);
    if(next.isEmpty) return ShortestPaths(SearchStatus.exhausted,null,ids.length);
    frontier=next;
  }
  return ShortestPaths(SearchStatus.depthLimit,null,ids.length);
}

/// A tap is a wait when only the time passing with it matters: the same tap
/// with its own turn (or rotor toggle) undone still lets the rest of the
/// solution finish. Gates, Impatient counters, vines and ghosts still advance.
/// Without time elements this cannot happen in a shortest solution.
List<int> waitingTaps(EyeBoard initial,List<int> path) {
  final waits=<int>[];
  final b=initial.clone();
  for(var t=0;t<path.length;t++) {
    final timeOnly=_timeOnlyTap(b,path[t]);
    if(timeOnly!=null && replayFinishes(timeOnly,path.sublist(t+1))) waits.add(t);
    b.tapDetailed(path[t]);
  }
  return waits;
}

/// Hops, beckons and Impatient resets do more than turn, so they are never
/// treated as pure time.
EyeBoard? _timeOnlyTap(EyeBoard board,int action) {
  if(!board.canAct(action)) return null;
  final b=board.clone();
  if(action>=b.cr.length) {
    final cell=b.actionCell(action); b.rotors[cell]=!b.rotors[cell]!;
  } else {
    final kind=b.cr[action].kind;
    if(kind==CreatureKind.linked) {
      for(final c in b.cr) { if(c.alive && c.kind==CreatureKind.linked) c.d=(c.d+3)%4; }
    } else if(kind==CreatureKind.normal || kind==CreatureKind.horse || kind==CreatureKind.frog) {
      b.cr[action].d=(b.cr[action].d+3)%4;
    } else {
      return null;
    }
  }
  b.tapDetailed(action);
  return b;
}

/// True when [path] is playable from [board] and ends in a win with every
/// candy collected.
bool replayFinishes(EyeBoard board,List<int> path) =>
    replayOutcome(board,path)=='finished';

String replayOutcome(EyeBoard board,List<int> path) {
  final b=board.clone();
  for(final action in path) {
    if(!b.canAct(action)) return b.won?'wonEarly':'invalid';
    b.tapDetailed(action);
    if(b.failed) return 'failed';
  }
  if(!b.won) return 'unfinished';
  return b.candies.isEmpty?'finished':'candyLeft';
}

/// Translation, reflection and rotation comparisons include the height layer.
/// Layout comparison deliberately ignores timers, colors and actor directions.
String renewalCanonical(EyeBoard board,{bool layoutOnly=false}) {
  final tokens=<(int,int,String)>[];
  final rows=board.toRows();
  for(var y=0;y<board.h;y++) {
    for(var x=0;x<board.w;x++) {
      var c=rows[y][x];
      if(c=='.' && !board.hills.contains(y*board.w+x)) continue;
      if(layoutOnly) {
        for(final kind in kCreatureChars.entries) { if(kind.value.contains(c)) {c='@${kind.key.name}';break;} }
        if(c=='=' || c=='+') c='+';
      }
      tokens.add((x,y,'$c${board.hills.contains(y*board.w+x)?"~":""}'));
    }
  }
  final keys=<String>[];
  for(var flip=0;flip<2;flip++) {
    for(var rotation=0;rotation<4;rotation++) {
      final transformed=<(int,int,String)>[];
      for(final t in tokens) {
        var x=flip==0?t.$1:-t.$1,y=t.$2;
        var symbol=t.$3;
        // A layout key deliberately ignores direction and parameter changes:
        // changing a timer/color cannot turn a clone into a fresh layout.
        if(!layoutOnly) {
          for(final chars in kCreatureChars.values) {
            final d=chars.indexOf(symbol.replaceAll('~',''));
            if(d>=0) { symbol=chars[((flip==1?(4-d)%4:d)+rotation)%4]+(symbol.endsWith('~')?'~':'');break; }
          }
        }
        for(var turn=0;turn<rotation;turn++) {final old=x;x=-y;y=old;}
        transformed.add((x,y,symbol));
      }
      final minX=transformed.map((t)=>t.$1).reduce((a,b)=>a<b?a:b);
      final minY=transformed.map((t)=>t.$2).reduce((a,b)=>a<b?a:b);
      final values=[for(final t in transformed) '${t.$1-minX},${t.$2-minY}:${t.$3}']..sort();
      keys.add(jsonEncode(values));
    }
  }
  return (keys..sort()).first;
}
