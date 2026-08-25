// Realistic traffic shape: command names and keywords repeat forever on a bus,
// but ids, counts and payload values vary per message. The fixed-payload bench
// flatters anything that exploits repetition, so measure against both.
import 'package:aiko_services/src/codec/s_expression.dart';

List<String> buildCorpus(int n) {
  var seed = 12345;
  int rnd(int m) => (seed = (seed * 1103515245 + 12345) & 0x3FFFFFFF) % m;
  return [
    for (var i = 0; i < n; i++)
      switch (rnd(4)) {
        0 => '(process_frame (stream_id: ${rnd(99999)} frame_id: ${rnd(99999)}) '
            '(image (width: ${rnd(4000)} height: ${rnd(4000)})))',
        1 => (() {
            final body = 'hello there number ${rnd(99999)}';
            return '(add_message chat_${rnd(500)} user_${rnd(9999)} '
                '${body.length}:$body)';
          })(),
        2 => '(state_update (topic: aiko/host/${rnd(99)}/${rnd(99)}/state '
            'count: ${rnd(99999)} tags: (a${rnd(50)} b${rnd(50)} c${rnd(50)})) 0:)',
        _ => '(discover ${rnd(99999)} topic_${rnd(200)} protocol_${rnd(20)})',
      }
  ];
}

void main(List<String> args) {
  final reps = args.isEmpty ? 40 : int.parse(args[0]);
  final corpus = buildCorpus(5000);
  for (var i = 0; i < 3; i++) { for (final p in corpus) {
    parse(p);
  } }

  final sw = Stopwatch()..start();
  for (var r = 0; r < reps; r++) { for (final p in corpus) {
    parse(p);
  } }
  sw.stop();
  final n = reps * corpus.length;
  print('realistic parse ${(sw.elapsedMicroseconds / n).toStringAsFixed(3)} us/msg '
      '(${(n / (sw.elapsedMicroseconds / 1e6)).round()} msg/s)');
}
