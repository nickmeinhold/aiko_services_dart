import 'package:aiko_services/aiko_services.dart';
import 'package:test/test.dart';

void main() {
  group('exact filters', () {
    test('match themselves and nothing else', () {
      expect(topicFilterMatches('a/b/c', 'a/b/c'), isTrue);
      expect(topicFilterMatches('a/b/c', 'a/b/d'), isFalse);
      expect(topicFilterMatches('a/b/c', 'a/b'), isFalse);
      expect(topicFilterMatches('a/b/c', 'a/b/c/d'), isFalse);
    });
  });

  group('+ matches exactly one level', () {
    test('any content in that level', () {
      expect(topicFilterMatches('a/+/c', 'a/b/c'), isTrue);
      expect(topicFilterMatches('a/+/c', 'a/zzz/c'), isTrue);
      expect(topicFilterMatches('+/b/c', 'a/b/c'), isTrue);
      expect(topicFilterMatches('a/b/+', 'a/b/c'), isTrue);
    });

    test('including an EMPTY level, which is a legal topic level', () {
      // `a//b` has three levels, the middle one empty. Treating empty as absent
      // silently drops a topic the broker will happily deliver.
      expect(topicFilterMatches('a/+/b', 'a//b'), isTrue);
    });

    test('never more than one, and never fewer', () {
      // THE CASE THE REFERENCE GETS WRONG. process.py compares only the first
      // and last segments of a `+` filter, so all three of these match there.
      expect(topicFilterMatches('a/+/c', 'a/b/x/c'), isFalse);
      expect(topicFilterMatches('a/+/c', 'a/c'), isFalse);
      expect(topicFilterMatches('a/+/+/+/e', 'a/b/e'), isFalse);
    });

    test("the registrar's own filter is depth-exact", () {
      const stateFilter = 'aiko/+/+/+/state';
      expect(topicFilterMatches(stateFilter, 'aiko/host/17/0/state'), isTrue);
      expect(topicFilterMatches(stateFilter, 'aiko/host/17/3/state'), isTrue);
      // Same first and last segment, wrong depth: matched by the reference,
      // refused here.
      expect(topicFilterMatches(stateFilter, 'aiko/host/state'), isFalse);
      expect(topicFilterMatches(stateFilter, 'aiko/a/b/c/d/e/state'), isFalse);
      // Right depth, wrong tail.
      expect(topicFilterMatches(stateFilter, 'aiko/host/17/0/out'), isFalse);
    });
  });

  group('# matches this level and everything below', () {
    test('including the parent itself', () {
      // §4.7.1.2: `sport/#` matches `sport`. Easy to miss, and a registrar
      // watching `{ns}/#` would otherwise be deaf to `{ns}` itself.
      expect(topicFilterMatches('a/#', 'a'), isTrue);
      expect(topicFilterMatches('a/#', 'a/b'), isTrue);
      expect(topicFilterMatches('a/#', 'a/b/c/d'), isTrue);
    });

    test('but not a sibling', () {
      expect(topicFilterMatches('a/#', 'b'), isFalse);
      expect(topicFilterMatches('a/#', 'ab/c'), isFalse);
    });

    test(r'a bare # matches everything that is not $-prefixed', () {
      expect(topicFilterMatches('#', 'a'), isTrue);
      expect(topicFilterMatches('#', 'a/b/c'), isTrue);
    });

    test('a # that is not last cannot match, rather than throwing', () {
      // Malformed filters come from callers, not the wire — but a throw inside
      // a dispatch loop is a crash, and refusing to match is the honest answer.
      expect(topicFilterMatches('a/#/c', 'a/b/c'), isFalse);
    });
  });

  group(r'$-prefixed topics', () {
    test('are not reachable by a filter that STARTS with a wildcard', () {
      // §4.7.2. Without this a `#` subscription silently enrols the broker's
      // own telemetry, and a registrar would read mosquitto's internal tree as
      // island traffic.
      expect(topicFilterMatches('#', r'$SYS/broker/uptime'), isFalse);
      expect(
        topicFilterMatches('+/broker/uptime', r'$SYS/broker/uptime'),
        isFalse,
      );
    });

    test('are reachable when named explicitly', () {
      expect(topicFilterMatches(r'$SYS/#', r'$SYS/broker/uptime'), isTrue);
      expect(
        topicFilterMatches(r'$SYS/broker/+', r'$SYS/broker/uptime'),
        isTrue,
      );
    });
  });

  group('isTopicFilter', () {
    test('tells a filter from a topic', () {
      expect(isTopicFilter('a/+/c'), isTrue);
      expect(isTopicFilter('a/#'), isTrue);
      expect(isTopicFilter('a/b/c'), isFalse);
    });
  });
}
