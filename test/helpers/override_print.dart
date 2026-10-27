import 'dart:async';

Future<void> Function() overridePrint(void Function(List<String> printLogs) fn) {
  return () async {
    final printLogs = <String>[];
    final spec = ZoneSpecification(
      print: (_, __, ___, String msg) {
        printLogs.add(msg);
      },
    );

    return Zone.current.fork(specification: spec).run<void>(() => fn(printLogs));
  };
}
