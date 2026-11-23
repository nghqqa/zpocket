import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zpocket/core/quick_prompts.dart';
import 'package:zpocket/core/saved_artifacts_store.dart';
import 'package:zpocket/state/notify_core.dart';
import 'package:zpocket/notify/notification_service.dart';
import 'package:zpocket/ui/quick_prompts_sheet.dart';
import 'package:zpocket/ui/saved_artifacts_page.dart';

class _MemQuickPromptsStore extends QuickPromptsStore {
  List<String> _items = List<String>.from(QuickPromptsStore.defaultPrompts);

  @override
  Future<List<String>> load() async => List<String>.from(_items);

  @override
  Future<void> save(List<String> prompts) async {
    _items = List<String>.from(prompts);
  }
}

class _MemSavedArtifactsStore extends SavedArtifactsStore {
  final List<SavedArtifactEntry> _items = [];

  @override
  Future<List<SavedArtifactEntry>> list() async =>
      List<SavedArtifactEntry>.from(_items);

  @override
  Future<void> record({
    required String fileName,
    required String savedPath,
    required String mimeType,
    required int sizeBytes,
    String source = 'workspace',
  }) async {
    _items.insert(
      0,
      SavedArtifactEntry(
        id: 'id_${_items.length}',
        fileName: fileName,
        savedPath: savedPath,
        mimeType: mimeType,
        sizeBytes: sizeBytes,
        source: source,
        savedAtMs: 1700000000000,
      ),
    );
  }
}

class _CapturingBackend extends NotificationBackend {
  final List<List<NotifyNotificationAction>> shownActions = [];

  @override
  Future<void> cancel(int id) async {}

  @override
  Future<void> cancelAll() async {}

  @override
  Future<bool?> checkPermission() async => true;

  @override
  Future<bool> initialize() async => true;

  @override
  Future<bool> requestPermission() async => true;

  @override
  void setTapHandler(void Function(NotifyTapPayload payload)? handler) {}

  @override
  Future<List<NotifyActiveEntry>> activeNotifications() async => const [];

  @override
  Future<String?> launchPayload() async => null;

  @override
  Future<void> show(
    int id,
    String title,
    String body,
    String channel,
    String payload, {
    List<NotifyNotificationAction> actions = const [],
  }) async {
    shownActions.add(actions);
  }
}

void main() {
  group('QuickPromptsStore', () {
    test('loads defaults, adds, removes, and resets', () async {
      final tmp = await Directory.systemTemp.createTemp('zpocket_qp_');
      addTearDown(() => tmp.delete(recursive: true));
      final store = QuickPromptsStore(directoryProvider: () async => tmp);

      final initial = await store.load();
      expect(initial, QuickPromptsStore.defaultPrompts);

      final afterAdd = await store.add('只看测试失败原因');
      expect(afterAdd.first, '只看测试失败原因');
      expect(afterAdd.length, QuickPromptsStore.defaultPrompts.length + 1);

      final afterRemove = await store.removeAt(0);
      expect(afterRemove, QuickPromptsStore.defaultPrompts);

      await store.add('临时指令');
      final afterReset = await store.resetDefaults();
      expect(afterReset, QuickPromptsStore.defaultPrompts);
    });
  });

  group('SavedArtifactsStore', () {
    test('records, deduplicates, removes, and clears', () async {
      final tmp = await Directory.systemTemp.createTemp('zpocket_sa_');
      addTearDown(() => tmp.delete(recursive: true));
      final store = SavedArtifactsStore(directoryProvider: () async => tmp);

      expect(await store.list(), isEmpty);

      await store.record(
        fileName: 'report.pdf',
        savedPath: '/storage/emulated/0/Download/report.pdf',
        mimeType: 'application/pdf',
        sizeBytes: 2048,
      );
      await store.record(
        fileName: 'report.pdf',
        savedPath: '/storage/emulated/0/Download/report.pdf',
        mimeType: 'application/pdf',
        sizeBytes: 2048,
      );

      final list = await store.list();
      expect(list, hasLength(1));
      expect(list.first.fileName, 'report.pdf');
      expect(list.first.sizeBytes, 2048);

      final afterRemove = await store.remove(list.first.id);
      expect(afterRemove, isEmpty);

      await store.record(
        fileName: 'a.png',
        savedPath: '/tmp/a.png',
        mimeType: 'image/png',
        sizeBytes: 100,
      );
      await store.clear();
      expect(await store.list(), isEmpty);
    });
  });

  group('Widgets', () {
    testWidgets('showQuickPromptsSheet inserts tapped prompt', (tester) async {
      final store = _MemQuickPromptsStore();
      String? picked;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: ElevatedButton(
                onPressed: () => showQuickPromptsSheet(
                  ctx,
                  store: store,
                  onInsert: (v) => picked = v,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text(QuickPromptsStore.defaultPrompts.first), findsOneWidget);
      await tester.tap(find.text(QuickPromptsStore.defaultPrompts.first));
      await tester.pumpAndSettle();
      expect(picked, QuickPromptsStore.defaultPrompts.first);
    });

    testWidgets('SavedArtifactsPage displays recorded artifacts', (tester) async {
      final store = _MemSavedArtifactsStore();
      await store.record(
        fileName: 'build.apk',
        savedPath: '/storage/emulated/0/Download/ZPocket/build.apk',
        mimeType: 'application/vnd.android.package-archive',
        sizeBytes: 1024 * 1024,
      );

      await tester.pumpWidget(
        MaterialApp(home: SavedArtifactsPage(store: store)),
      );
      await tester.pumpAndSettle();

      expect(find.text('build.apk'), findsOneWidget);
      expect(find.textContaining('1.0 MB'), findsOneWidget);
    });
  });

  group('NotificationService RemoteInput', () {
    test('approval notification includes accept, decline, and decline_reply', () async {
      final backend = _CapturingBackend();
      final svc = NotificationService(backend: backend);
      await svc.init();
      await svc.post(
        const NotifyEvent(
          kind: NotifyEventKind.approvalPending,
          channel: NotifyChannel.approvals,
          deviceSid: 'dev-1',
          taskId: 'task-1',
          title: '允许执行命令？',
          detail: 'rm -rf build',
          atMs: 1000,
          interactionId: 'iid-1',
        ),
      );

      expect(backend.shownActions, hasLength(1));
      final actions = backend.shownActions.single;
      expect(actions.map((a) => a.id).toList(), ['accept', 'decline', 'decline_reply']);
      expect(actions[2].allowFreeFormInput, isTrue);
    });
  });
}
