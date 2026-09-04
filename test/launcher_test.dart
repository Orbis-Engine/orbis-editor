import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/launcher/create_view.dart';
import 'package:orbis_editor/src/launcher/project.dart';
import 'package:orbis_editor/src/launcher/projects_view.dart';
import 'package:orbis_editor/src/theme/orbis_theme.dart';
import 'package:orbis_editor/src/widgets/controls.dart';
import 'package:path/path.dart' as p;

Widget host(Widget child) => MaterialApp(
      theme: orbisTheme(),
      home: Scaffold(body: child),
    );

Project project(String name, String directory, {Duration ago = Duration.zero}) =>
    Project(
      name: name,
      directory: directory,
      lastOpened: DateTime.now().subtract(ago),
    );

void main() {
  group('the projects list', () {
    testWidgets('invites you to make one when there are none', (tester) async {
      var created = false;
      await tester.pumpWidget(host(ProjectsView(
        loading: false,
        projects: const [],
        onOpen: (_) {},
        onForget: (_) {},
        onCreate: () => created = true,
      )));

      expect(find.text('No projects yet'), findsOneWidget);
      // Two ways to start: the header button and the empty state's own.
      expect(find.text('New project'), findsNWidgets(2));

      await tester.tap(find.text('No projects yet'));
      await tester.tap(find.byType(OrbisButton).last);
      await tester.pump();
      expect(created, isTrue);
    });

    testWidgets('shows a project with its path and when it was opened',
        (tester) async {
      await tester.pumpWidget(host(ProjectsView(
        loading: false,
        projects: [
          project('Sunset Valley', '/tmp/sunset', ago: const Duration(hours: 2)),
        ],
        onOpen: (_) {},
        onForget: (_) {},
        onCreate: () {},
      )));

      expect(find.text('Sunset Valley'), findsOneWidget);
      expect(find.text('/tmp/sunset'), findsOneWidget);
      expect(find.text('2h ago'), findsOneWidget);
      expect(find.text('1 recent'), findsOneWidget);
    });

    testWidgets('marks a project whose folder has gone', (tester) async {
      await tester.pumpWidget(host(ProjectsView(
        loading: false,
        projects: [project('Gone', '/tmp/definitely-not-here-9182')],
        onOpen: (_) {},
        onForget: (_) {},
        onCreate: () {},
      )));

      // Shown rather than hidden, so somebody who moved a folder sees why it
      // will not open instead of wondering where their work went.
      expect(find.text('moved'), findsOneWidget);
    });
  });

  group('creating a project', () {
    testWidgets('shows where the folder will land before making it',
        (tester) async {
      await tester.pumpWidget(host(CreateView(
        store: ProjectStore(),
        onCancel: () {},
        onCreated: (_) {},
        onFailed: (_, _) {},
      )));
      await tester.pumpAndSettle();

      // The default name, turned into the folder name it will become.
      expect(
        find.textContaining('untitled-project'),
        findsOneWidget,
        reason: 'a name is for people and a path is for filesystems, so the '
            'translation between them should not be a surprise',
      );
    });

    testWidgets('offers every template, with one chosen', (tester) async {
      await tester.pumpWidget(host(CreateView(
        store: ProjectStore(),
        onCancel: () {},
        onCreated: (_) {},
        onFailed: (_, _) {},
      )));
      await tester.pumpAndSettle();

      for (final template in ProjectTemplate.values) {
        expect(find.text(template.label), findsOneWidget);
      }
    });

    testWidgets('refuses a nameless project rather than making one',
        (tester) async {
      String? complaint;
      await tester.pumpWidget(host(CreateView(
        store: ProjectStore(),
        onCancel: () {},
        onCreated: (_) {},
        onFailed: (title, _) => complaint = title,
      )));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, '   ');
      await tester.tap(find.text('Create project'));
      await tester.pump();

      expect(complaint, 'A project needs a name');
    });
  });

  group('a project on disk', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('orbis_test'));
    tearDown(() => temp.deleteSync(recursive: true));

    test('is a folder with a project file, scenes and assets', () async {
      final store = ProjectStore();
      // Written directly rather than through create(), which also touches the
      // recents list and would need a platform directory this test has no
      // business creating.
      final directory = Directory(p.join(temp.path, 'my-game'))
        ..createSync(recursive: true);
      final created = Project(
        name: 'My Game',
        directory: directory.path,
        lastOpened: DateTime.now(),
      );
      File(p.join(directory.path, projectFileName))
          .writeAsStringSync(jsonEncode(created.toJson()));

      final reopened = store.open(directory.path);
      expect(reopened, isNotNull);
      expect(reopened!.name, 'My Game');
      expect(reopened.exists, isTrue);
    });

    test('a folder without a project file opens as nothing', () {
      expect(ProjectStore().open(temp.path), isNull);
    });

    test('a corrupt project file is refused, not half-read', () {
      File(p.join(temp.path, projectFileName)).writeAsStringSync('{not json');
      expect(ProjectStore().open(temp.path), isNull);
    });

    test('a path under home is shortened for display', () {
      final home = Platform.environment['HOME'];
      if (home == null) return;
      expect(
        project('X', p.join(home, 'dev', 'game')).displayPath,
        '~/dev/game',
      );
    });
  });
}
