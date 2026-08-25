// Head-to-head throughput probe: this codec vs parser.py on identical payloads.
// Not a port-wide claim — it measures the ONE component both languages share.
import 'package:aiko_services/src/codec/s_expression.dart';

const payloads = [
  '(process_frame (stream_id: 42 frame_id: 7) (image (width: 1920 height: 1080)))',
  '(add_message chat_1 nick 13:hello, world!)',
  '(state_update (topic: aiko/host/1/1/state count: 99 tags: (a b c)) 0:)',
];

void main(List<String> args) {
  final iters = args.isEmpty ? 200000 : int.parse(args[0]);
  // warm the JIT / AOT icaches
  for (var i = 0; i < 5000; i++) { for (final p in payloads) parse(p); }

  final swParse = Stopwatch()..start();
  for (var i = 0; i < iters; i++) { for (final p in payloads) parse(p); }
  swParse.stop();

  final parsed = [for (final p in payloads) parse(p)];
  final swGen = Stopwatch()..start();
  for (var i = 0; i < iters; i++) {
    for (final t in parsed) generate(t.$1, t.$2 as List<Object?>);
  }
  swGen.stop();

  final n = iters * payloads.length;
  print('dart parse   ${swParse.elapsedMicroseconds / n} us/msg  '
      '(${(n / (swParse.elapsedMicroseconds / 1e6)).round()} msg/s)');
  print('dart generate ${swGen.elapsedMicroseconds / n} us/msg  '
      '(${(n / (swGen.elapsedMicroseconds / 1e6)).round()} msg/s)');
}
