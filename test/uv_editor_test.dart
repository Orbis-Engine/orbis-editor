import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_editor/src/editor/editor_shell.dart';
import 'package:orbis_editor/src/editor/mesh_panel.dart';
import 'package:orbis_editor/src/launcher/project.dart';
import 'package:orbis_editor/src/editor/scene.dart';
import 'package:orbis_editor/src/editor/uv_panel.dart';
import 'package:orbis_editor/src/editor/viewport.dart';
import 'package:orbis_editor/src/theme/orbis_theme.dart';
import 'package:orbis_mesh/orbis_mesh.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('orbis_uv');
    Directory('${root.path}/scenes').createSync(recursive: true);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> open(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(MaterialApp(
      theme: orbisTheme(),
      home: EditorShell(
        project: Project(
          name: 'Test',
          directory: root.path,
          lastOpened: DateTime(2026),
        ),
        onClose: () {},
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> addShape(WidgetTester tester, String kind) async {
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SubmenuButton, 'Shape'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.byType(MenuItemButton),
      matching: find.text(kind),
    ));
    await tester.pumpAndSettle();
  }

  SceneObject shapeIn(WidgetTester tester) {
    final viewport = tester.widget<SceneViewport>(find.byType(SceneViewport));
    return viewport.workspace.loaded!.scene!.objects
        .firstWhere((o) => o.kind == ObjectKind.shape);
  }

  /// Opens the coordinate panel through the View menu, which is how anybody
  /// else would.
  Future<void> openUvs(WidgetTester tester) async {
    // 'View' exactly: 'Viewport' is on screen too and contains it.
    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.byType(MenuItemButton),
      matching: find.text('UVs'),
    ));
    await tester.pumpAndSettle();
  }

  /// Into the geometry. G again would cycle the element mode on, so this is
  /// separate from selecting: a test that selects twice must not enter twice.
  Future<void> enterGeometry(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.pumpAndSettle();
  }

  Future<void> selectFaces(WidgetTester tester, List<int> which) async {
    final viewport = tester.widget<SceneViewport>(find.byType(SceneViewport));
    viewport.onSelectElements!(which.cast<Object>(), add: false);
    await tester.pumpAndSettle();
  }

  UvPanel panelIn(WidgetTester tester) =>
      tester.widget<UvPanel>(find.byType(UvPanel));

  testWidgets('the panel opens and says nothing is selected', (tester) async {
    await open(tester);
    await addShape(tester, 'Cube');
    await openUvs(tester);

    expect(find.byType(UvPanel), findsOneWidget);
    expect(find.textContaining('Select faces'), findsOneWidget);
  });

  testWidgets('a selected face is drawn and follows the rule', (tester) async {
    await open(tester);
    await addShape(tester, 'Cube');
    await openUvs(tester);
    await enterGeometry(tester);
    await selectFaces(tester, [0]);

    expect(find.textContaining('following the rule'), findsOneWidget);
    // And the rule's own numbers, because exactly one face is selected.
    expect(find.byType(UvRuleControls), findsOneWidget);
  });

  testWidgets('freezing turns the rule into coordinates', (tester) async {
    await open(tester);
    await addShape(tester, 'Cube');
    await openUvs(tester);
    await enterGeometry(tester);
    await selectFaces(tester, [0]);

    final was = shapeIn(tester).currentMesh!;
    final before = was.uvsOf(was.faces[0]);

    panelIn(tester).onAction(UvAction.freeze);
    await tester.pumpAndSettle();

    final mesh = shapeIn(tester).currentMesh!;
    expect(mesh.faces[0].uv.isManual, isTrue);
    expect(find.textContaining('drawn by hand'), findsOneWidget);
    // And says exactly what the rule was saying, or freezing would move the
    // texture the moment somebody reached for it.
    final now = mesh.uvsOf(mesh.faces[0]);
    for (var i = 0; i < before.length; i++) {
      expect(now[i].x, closeTo(before[i].x, 1e-9));
      expect(now[i].y, closeTo(before[i].y, 1e-9));
    }
  });

  testWidgets('dragging moves the coordinates, and is one step to undo',
      (tester) async {
    await open(tester);
    await addShape(tester, 'Cube');
    await openUvs(tester);
    await enterGeometry(tester);
    await selectFaces(tester, [0]);

    final panel = panelIn(tester);
    final was = shapeIn(tester).currentMesh!;
    final before = was.uvsOf(was.faces[0]).first.x;

    // A drag is many of these; the panel reports each frame.
    for (var i = 0; i < 4; i++) {
      panelIn(tester).onNudge(Vector2(0.1, 0));
      await tester.pump();
    }
    panel.onDone();
    await tester.pumpAndSettle();

    final moved = shapeIn(tester).currentMesh!;
    expect(moved.uvsOf(moved.faces[0]).first.x, closeTo(before + 0.4, 1e-9));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    final back = shapeIn(tester).currentMesh!;
    expect(back.uvsOf(back.faces[0]).first.x, closeTo(before, 1e-9),
        reason: 'the whole drag, not its last frame');
  });

  testWidgets('two presses of a button are two things to undo',
      (tester) async {
    await open(tester);
    await addShape(tester, 'Cube');
    await openUvs(tester);
    await enterGeometry(tester);
    await selectFaces(tester, [0, 1]);

    panelIn(tester).onAction(UvAction.box);
    await tester.pumpAndSettle();
    panelIn(tester).onAction(UvAction.fit);
    await tester.pumpAndSettle();

    final fitted = shapeIn(tester).currentMesh!;
    final box = fitted.uvBoundsOf(fitted.faces.take(2))!;
    expect(box.min.x, closeTo(0, 1e-9));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    // Back to the projection, not back to the beginning.
    final mesh = shapeIn(tester).currentMesh!;
    expect(mesh.faces[0].uv.isManual, isTrue);
    expect(mesh.uvBoundsOf(mesh.faces.take(2))!.min.x, isNot(closeTo(0, 1e-9)));
  });

  testWidgets('the rule controls only appear for a single face',
      (tester) async {
    await open(tester);
    await addShape(tester, 'Cube');
    await openUvs(tester);

    await enterGeometry(tester);
    await selectFaces(tester, [0, 1]);
    expect(find.byType(UvRuleControls), findsNothing,
        reason: 'two faces may not agree, and showing one of them lies');

    await selectFaces(tester, [0]);
    expect(find.byType(UvRuleControls), findsOneWidget);

    panelIn(tester).onAction(UvAction.freeze);
    await tester.pumpAndSettle();
    expect(find.byType(UvRuleControls), findsNothing,
        reason: 'a frozen face is not following a rule any more');
  });

  testWidgets('it says so when the wrong element mode is on', (tester) async {
    await open(tester);
    await addShape(tester, 'Cube');
    await openUvs(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.pumpAndSettle();

    expect(find.textContaining('belong to faces'), findsOneWidget);
  });

  group('exporting', () {
    Future<void> exportAs(WidgetTester tester, String format) async {
      final panel = tester.widget<MeshPanel>(find.byType(MeshPanel));
      panel.onFormat(
        MeshFormat.values.firstWhere((one) => one.label == format),
      );
      await tester.pumpAndSettle();
      tester.widget<MeshPanel>(find.byType(MeshPanel)).onExport();
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).last, 'steps');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Export'));
      await tester.pumpAndSettle();
    }

    testWidgets('OBJ writes the model and the library it names',
        (tester) async {
      await open(tester);
      await addShape(tester, 'Stairs');
      await exportAs(tester, 'OBJ');

      final folder = Directory('${root.path}/exports');
      expect(folder.existsSync(), isTrue);
      expect(File('${folder.path}/steps.obj').existsSync(), isTrue);

      final text = File('${folder.path}/steps.obj').readAsStringSync();
      expect(text, contains('o steps'));
      expect(text, contains('\nf '));
    });

    testWidgets('every format writes something readable', (tester) async {
      for (final format in ['glTF binary', 'STL', 'PLY']) {
        await open(tester);
        await addShape(tester, 'Cube');
        await exportAs(tester, format);
      }

      final written = Directory('${root.path}/exports')
          .listSync()
          .map((one) => one.path.split('/').last)
          .toList();
      expect(written, containsAll(['steps.glb', 'steps.stl', 'steps.ply']));
      for (final file in Directory('${root.path}/exports').listSync()) {
        expect((file as File).lengthSync(), greaterThan(80));
      }
    });
  });
}
